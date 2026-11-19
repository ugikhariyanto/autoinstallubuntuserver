<#
.SYNOPSIS
    Rebuild ISO Ubuntu Server menjadi versi autoinstall (unattended).

.DESCRIPTION
    Mengambil ISO asli, lalu:
      * mengganti  /boot/grub/grub.cfg        -> menambah parameter "autoinstall"
      * mengganti  /boot/grub/loopback.cfg    -> idem (untuk boot via Ventoy/GRUB)
      * menambah   /autoinstall.yaml          -> konfigurasi instalasi otomatis

    Layout boot asli (MBR/grub2 + GPT + El Torito BIOS & UEFI + ESP appended
    partition) direproduksi persis seperti yang dilaporkan oleh
    "xorriso -report_system_area cmd", supaya ISO tetap bootable sebagai USB
    hybrid (BIOS maupun UEFI).

.PARAMETER Iso
    ISO sumber (default: ISO Ubuntu di folder induk).

.PARAMETER Out
    Nama ISO hasil (default: ...-autoinstall.iso di folder induk).

.EXAMPLE
    .\build-iso.ps1
#>
[CmdletBinding()]
param(
    [string]$Iso,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$parent = Split-Path -Parent $here
if (-not $Iso) { $Iso = Join-Path $parent 'ubuntu-26.04.1-live-server-amd64.iso' }
if (-not $Out) { $Out = Join-Path $parent 'ubuntu-26.04.1-live-server-amd64-autoinstall.iso' }

if (-not (Test-Path -LiteralPath $Iso)) { throw "ISO sumber tidak ditemukan: $Iso" }
if (Test-Path -LiteralPath $Out) { Write-Host "Menghapus output lama: $Out"; Remove-Item -LiteralPath $Out -Force }

# --- Helper: format path untuk build Cygwin dari xorriso --------------------
# Argumen file (termasuk di dalam spesifikasi --interval:imported_iso:...)
# harus memakai gaya "/cygdrive/c/...", sedangkan -indev/-outdev menerima "C:/...".
function To-Fwd([string]$p) { return ([IO.Path]::GetFullPath($p) -replace '\\', '/') }
function To-Cyg([string]$p) {
    $f = To-Fwd $p
    if ($f -match '^([A-Za-z]):/(.*)$') { return '/cygdrive/' + $matches[1].ToLower() + '/' + $matches[2] }
    return $f
}

# --- Helper: jalankan program, tangkap stdout+stderr ke file -----------------
function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory = (Get-Location).Path)
    $log = Join-Path $env:TEMP ("ububuild-" + [guid]::NewGuid().ToString('n') + ".log")
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
         -WorkingDirectory $WorkingDirectory `
         -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $text = @()
    if (Test-Path -LiteralPath $log)     { $text += Get-Content -LiteralPath $log }
    if (Test-Path -LiteralPath "$log.err") { $text += Get-Content -LiteralPath "$log.err" }
    Remove-Item -LiteralPath $log, "$log.err" -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $text }
}

# --- 1. Siapkan xorriso -----------------------------------------------------
$xorr = Join-Path $here 'tools\xorriso\xorriso.exe'
if (-not (Test-Path -LiteralPath $xorr)) {
    $tools = Join-Path $here 'tools'
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    $zip = Join-Path $tools 'xorriso-win32.zip'
    $url = 'https://github.com/dEajL3kA/xorriso-win32/releases/download/2026-02-25/xorriso-win32.2026-02-25.zip'
    Write-Host "Mengunduh xorriso dari GitHub..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tools 'xorriso') -Force
    Remove-Item -LiteralPath $zip -Force
}
if (-not (Test-Path -LiteralPath $xorr)) { throw "xorriso tidak tersedia: $xorr" }

# --- 2. Baca "resep" layout boot dari ISO asli ------------------------------
# xorriso bisa melaporkan sendiri perintah yang dibutuhkan untuk mereproduksi
# MBR, GPT, appended ESP partition, dan entri El Torito (BIOS + UEFI).
Write-Host "Membaca layout boot ISO asli..."
$rep = Invoke-Tool -Exe $xorr -Arguments @('-indev', (To-Fwd $Iso), '-report_system_area', 'cmd') -WorkingDirectory $here
$bootCmds = @($rep.Output |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -match '^-(boot_image|append_partition)\s' })

if ($bootCmds.Count -lt 5) {
    $rep.Output | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
    throw "Gagal membaca layout boot dari ISO sumber."
}

$cyg = To-Cyg $Iso
$fwd = To-Fwd $Iso
$bootCmds = @($bootCmds | ForEach-Object { $_.Replace($fwd, $cyg) })

# --- 3. Bangun ISO baru -----------------------------------------------------
# -indev/-outdev : salin seluruh isi ISO, lalu ganti/tambah beberapa file
# -map <rel> <p> : file sumber harus path relatif (keterbatasan build Cygwin)
$xorArgs = @('-indev', (To-Fwd $Iso), '-outdev', (To-Fwd $Out), '-overwrite', 'on') +
    $bootCmds +
    @(
        '-map', 'boot/grub/grub.cfg',     '/boot/grub/grub.cfg',
        '-map', 'boot/grub/loopback.cfg', '/boot/grub/loopback.cfg',
        '-map', 'autoinstall.yaml',       '/autoinstall.yaml',
        '-commit',
        '-end'
    )

Write-Host "Membangun ISO (~2.8 GB, butuh beberapa menit)..."
$r = Invoke-Tool -Exe $xorr -Arguments $xorArgs -WorkingDirectory $here
$r.Output | Where-Object { $_ -match 'FAILURE|SORRY|Cannot|refus' } | ForEach-Object { Write-Host $_ }
if (-not (Test-Path -LiteralPath $Out) -or ($r.Output | Where-Object { $_ -match 'xorriso : FAILURE|xorriso : aborting' })) {
    $r.Output | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    throw "xorriso gagal membuat ISO"
}

$info = Get-Item -LiteralPath $Out
Write-Host ""
Write-Host ("Selesai: {0} ({1:N2} GB)" -f $info.FullName, ($info.Length / 1GB))

# --- 4. Verifikasi ----------------------------------------------------------
Write-Host ""
Write-Host "Verifikasi layout boot ISO hasil:"
$v = Invoke-Tool -Exe $xorr -Arguments @('-indev', (To-Fwd $Out), '-report_el_torito', 'plain', '-report_system_area', 'plain') -WorkingDirectory $here
$v.Output | Where-Object { $_ -match 'Boot record|El Torito boot img|Partition offset|GPT partition name|GPT start and size|Volume id' } |
    ForEach-Object { Write-Host $_ }

# --- 5. Cek konsistensi: ukuran file vs ujung partisi GPT -------------------
$isize = [int64]($v.Output | Where-Object { $_ -match '^ISO image size/512' } | ForEach-Object { ($_ -split ':')[1].Trim() } | Select-Object -First 1)
$esp = $v.Output | Where-Object { $_ -match 'El Torito boot img\s*:\s*2' } | Select-Object -First 1
if ($isize -gt 0 -and $esp) {
    $parts = ($esp -split '\s+') | Where-Object { $_ -ne '' }
    $lba = [int64]$parts[-1]          # kolom terakhir = LBA (blok 2048 B)
    $espStartSectors = $lba * 4       # -> sector 512 B
    $gpt2 = $v.Output | Where-Object { $_ -match 'GPT start and size\s*:\s*2\s' } | Select-Object -First 1
    if ($gpt2) {
        $g = (($gpt2 -split ':')[1].Trim() -split '\s+')
        $gptStart = [int64]$g[1]   # [0] = nomor partisi, [1] = start, [2] = size
        if ($gptStart -eq $espStartSectors) {
            Write-Host ("OK: partisi ESP GPT cocok dengan image UEFI El Torito (sector {0})." -f $gptStart)
        } else {
            Write-Host ("PERINGATAN: GPT ESP ({0}) != El Torito UEFI ({1})" -f $gptStart, $espStartSectors)
        }
    }
    if ($isize -le ($info.Length / 512)) {
        Write-Host ("OK: ukuran ISO ({0:N0} sector) >= ukuran image ({1:N0} sector)." -f ($info.Length / 512), $isize)
    }
}
