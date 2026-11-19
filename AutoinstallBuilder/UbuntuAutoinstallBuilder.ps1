<#
.SYNOPSIS
    Aplikasi pembuat ISO Ubuntu Server "autoinstall" (instalasi tanpa interaksi).

.DESCRIPTION
    Ambil ISO Ubuntu Server resmi, isi data instalasi, lalu aplikasi membuat ISO
    baru yang saat di-boot langsung menginstal sendiri tanpa monitor/keyboard.

    Aplikasi TIDAK mengedit ISO asli. Yang dilakukan:
      1. Membaca file boot (/boot/grub/grub.cfg dan loopback.cfg) dari ISO asli.
      2. Menambahkan parameter kernel "autoinstall" pada entri boot.
      3. Membuat /autoinstall.yaml dari data yang Anda isi.
      4. Menyusun ISO baru dengan xorriso, mereproduksi layout boot asli
         (MBR/GRUB2, GPT, El Torito BIOS + UEFI, partisi ESP) supaya ISO tetap
         bisa di-flash ke USB dan boot di BIOS maupun UEFI.

.PARAMETER Cli
    Jalankan tanpa GUI (mode baris perintah).

.EXAMPLE
    .\UbuntuAutoinstallBuilder.ps1

.EXAMPLE
    .\UbuntuAutoinstallBuilder.ps1 -Cli -Source D:\ubuntu-server.iso `
        -Output C:\out\ubuntu-autoinstall.iso -Password 'rahasia123'
#>
[CmdletBinding()]
param(
    [switch]$Cli,
    [string]$Source,
    [string]$Output,
    [string]$Hostname = 'home-server',
    [string]$Username = 'ugik',
    [string]$Realname = 'ugik',
    [string]$Password,
    [string]$Locale = 'en_US.UTF-8',
    [string]$Keyboard = 'us',
    [string]$Timezone = 'Asia/Jakarta',
    [string]$StorageLayout = 'direct',
    [string]$Disk = 'largest',
    [string]$Shutdown = 'poweroff',
    [switch]$NoSsh,
    [switch]$NoNetplanFix,
    [switch]$NoVerify,
    [string[]]$Packages = @(),
    [string[]]$LateCommands = @(),
    [string[]]$EarlyCommands = @()
)

$ErrorActionPreference = 'Stop'
$script:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Xorriso = Join-Path $script:AppDir 'tools\xorriso\xorriso.exe'
$script:UiLog = $null
$script:StatusLabel = $null
$script:HasGui = $false

# ============================================================================
#  Utilitas umum
# ============================================================================
function Write-AppLog([string]$Message) {
    if ($script:UiLog) {
        $script:UiLog.AppendText($Message + "`r`n")
        if ($script:HasGui) { [System.Windows.Forms.Application]::DoEvents() }
    } else {
        Write-Host $Message
    }
}

function Set-Status([string]$Text) {
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Text
        if ($script:HasGui) { [System.Windows.Forms.Application]::DoEvents() }
    }
}

function To-Fwd([string]$Path) { return ([IO.Path]::GetFullPath($Path) -replace '\\', '/') }

function To-Cyg([string]$Path) {
    $f = To-Fwd $Path
    if ($f -match '^([A-Za-z]):/(.*)$') { return '/cygdrive/' + $matches[1].ToLower() + '/' + $matches[2] }
    return $f
}

# Memecah baris resep xorriso ("-boot_image any cat_path='/x'") menjadi token
# sebagaimana shell akan melakukannya: tanda kutip tunggal untuk mengelompokkan,
# lalu dihilangkan dari hasilnya.
function Split-XorrisoRecipe([string]$Line) {
    $tokens = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuote = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq [char]39) { $inQuote = -not $inQuote; continue }
        if (-not $inQuote -and [char]::IsWhiteSpace($ch)) {
            if ($current.Length -gt 0) {
                $tokens.Add($current.ToString())
                [void]$current.Clear()
            }
            continue
        }
        [void]$current.Append($ch)
    }
    if ($current.Length -gt 0) { $tokens.Add($current.ToString()) }
    return $tokens
}

function Invoke-Tool {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location).Path,
        [scriptblock]$Tick
    )
    $logFile = Join-Path $env:TEMP ('ububuild-' + [guid]::NewGuid().ToString('n') + '.log')

    # Start-Process menggabungkan array argumen dengan spasi tanpa menambahkan
    # tanda kutip, jadi argumen yang mengandung spasi harus dikutip sendiri.
    $quotedArgs = @()
    foreach ($item in $Arguments) {
        $text = "$item"
        if ($text -match '\s') { $quotedArgs += '"' + $text + '"' } else { $quotedArgs += $text }
    }

    $proc = Start-Process -FilePath $Exe -ArgumentList $quotedArgs -NoNewWindow -PassThru `
            -WorkingDirectory $WorkingDirectory `
            -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err"
    if ($Tick) {
        while (-not $proc.HasExited) {
            & $Tick
            Start-Sleep -Milliseconds 250
        }
    }
    $proc.WaitForExit()

    $text = @()
    if (Test-Path -LiteralPath $logFile)         { $text += Get-Content -LiteralPath $logFile }
    if (Test-Path -LiteralPath "$logFile.err")   { $text += Get-Content -LiteralPath "$logFile.err" }
    Remove-Item -LiteralPath $logFile, "$logFile.err" -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $text }
}

# Membaca label volume ISO, mis. "Ubuntu-Server 24.04.1 LTS amd64".
function Get-IsoLabel([string]$IsoPath) {
    try {
        $rep = Invoke-Tool -Exe $script:Xorriso -Arguments @('-indev', (To-Fwd $IsoPath), '-report_system_area', 'plain') -WorkingDirectory $script:AppDir
        foreach ($ln in $rep.Output) {
            if ($ln -match "Volume id\s*:\s*'([^']+)'") { return $matches[1] }
        }
    } catch { }
    return ''
}

# ============================================================================
#  Hash password SHA-512 crypt (implementasi murni PowerShell, tanpa Python)
# ============================================================================
function New-HashContext { return @{ Sha = [System.Security.Cryptography.SHA512]::Create() } }

function Add-HashBytes($Context, [byte[]]$Bytes) {
    if ($Bytes -and $Bytes.Length -gt 0) {
        [void]$Context.Sha.TransformBlock($Bytes, 0, $Bytes.Length, $null, 0)
    }
}

function Get-HashDigest($Context) {
    [void]$Context.Sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    $hash = $Context.Sha.Hash
    $Context.Sha.Dispose()
    return $hash
}

function ConvertTo-CryptBase64([int]$B2, [int]$B1, [int]$B0, [int]$Count) {
    $alphabet = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    $word = ($B2 -shl 16) -bor ($B1 -shl 8) -bor $B0
    $out = ''
    for ($j = 0; $j -lt $Count; $j++) {
        $out += $alphabet[$word -band 0x3f]
        $word = $word -shr 6
    }
    return $out
}

function ConvertTo-Sha512Crypt {
    param(
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Salt,
        [int]$Rounds = 5000
    )

    $key    = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $saltB  = [System.Text.Encoding]::UTF8.GetBytes($Salt)
    $keyLen = $key.Length

    $hctx = New-HashContext
    Add-HashBytes $hctx $key; Add-HashBytes $hctx $saltB; Add-HashBytes $hctx $key
    $B = Get-HashDigest $hctx

    $hctx = New-HashContext
    Add-HashBytes $hctx $key; Add-HashBytes $hctx $saltB
    $remain = $keyLen
    while ($remain -gt 0) {
        $take = [Math]::Min(64, $remain)
        Add-HashBytes $hctx $B[0..($take - 1)]
        $remain -= $take
    }
    $bits = $keyLen
    while ($bits -gt 0) {
        if ($bits -band 1) { Add-HashBytes $hctx $B } else { Add-HashBytes $hctx $key }
        $bits = $bits -shr 1
    }
    $A = Get-HashDigest $hctx

    $hctx = New-HashContext
    for ($k = 0; $k -lt $keyLen; $k++) { Add-HashBytes $hctx $key }
    $DP = Get-HashDigest $hctx
    $P = New-Object byte[] $keyLen
    for ($k = 0; $k -lt $keyLen; $k++) { $P[$k] = $DP[$k % 64] }

    $hctx = New-HashContext
    for ($k = 0; $k -lt (16 + [int]$A[0]); $k++) { Add-HashBytes $hctx $saltB }
    $DS = Get-HashDigest $hctx
    $S = New-Object byte[] $saltB.Length
    for ($k = 0; $k -lt $saltB.Length; $k++) { $S[$k] = $DS[$k % 64] }

    $current = $A
    for ($round = 0; $round -lt $Rounds; $round++) {
        $hctx = New-HashContext
        if ($round -band 1) { Add-HashBytes $hctx $P } else { Add-HashBytes $hctx $current }
        if (($round % 3) -ne 0) { Add-HashBytes $hctx $S }
        if (($round % 7) -ne 0) { Add-HashBytes $hctx $P }
        if ($round -band 1) { Add-HashBytes $hctx $current } else { Add-HashBytes $hctx $P }
        $current = Get-HashDigest $hctx
    }

    $order = @(
        @(0,21,42,4), @(22,43,1,4), @(44,2,23,4), @(3,24,45,4), @(25,46,4,4),
        @(47,5,26,4), @(6,27,48,4), @(28,49,7,4), @(50,8,29,4), @(9,30,51,4),
        @(31,52,10,4), @(53,11,32,4), @(12,33,54,4), @(34,55,13,4), @(56,14,35,4),
        @(15,36,57,4), @(37,58,16,4), @(59,17,38,4), @(18,39,60,4), @(40,61,19,4),
        @(62,20,41,4)
    )
    $sb = New-Object System.Text.StringBuilder
    foreach ($o in $order) {
        [void]$sb.Append((ConvertTo-CryptBase64 $current[$o[0]] $current[$o[1]] $current[$o[2]] $o[3]))
    }
    [void]$sb.Append((ConvertTo-CryptBase64 0 0 $current[63] 2))

    return '$6$' + $Salt + '$' + $sb.ToString()
}

function New-CryptSalt([int]$Length = 16) {
    $alphabet = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    $rng = New-Object System.Random
    $salt = ''
    for ($i = 0; $i -lt $Length; $i++) { $salt += $alphabet[$rng.Next($alphabet.Length)] }
    return $salt
}

# ============================================================================
#  Patch file boot + pembuatan autoinstall.yaml
# ============================================================================
function Update-BootConfigText([string]$Text) {
    $normalized = $Text -replace "`r`n", "`n"
    $result = foreach ($line in ($normalized -split "`n")) {
        $l = $line

        # Entri kernel: sisipkan "autoinstall" sebelum pemisah "---".
        if ($l -match '^(\s*linux\s+/casper/vmlinuz)(.*)$') {
            $head = $matches[1]
            $rest = $matches[2]
            if ($rest -notmatch '\bautoinstall\b') {
                $idx = $rest.IndexOf('---')
                if ($idx -ge 0) {
                    $rest = $rest.Substring(0, $idx).TrimEnd() + ' autoinstall ' + $rest.Substring($idx)
                } else {
                    $rest = $rest.TrimEnd() + ' autoinstall'
                }
            }
            $l = $head + $rest
        }
        # Timeout menu boot: 10 detik, cukup untuk boot otomatis.
        elseif ($l -match '^(\s*set\s+timeout=)\d+\s*$') {
            $l = $matches[1] + '10'
        }

        $l = $l -replace 'menuentry\s+"Try or Install Ubuntu Server"', 'menuentry "Autoinstall Ubuntu Server"'
        $l
    }
    return ($result -join "`n")
}

function Format-YamlString([string]$Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function New-AutoinstallYaml {
    param([hashtable]$Cfg)

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('# ==========================================================================')
    $L.Add('#  Konfigurasi autoinstall - dibuat otomatis oleh Ubuntu Autoinstall Builder')
    $L.Add('#  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $L.Add('# ==========================================================================')
    $L.Add('version: 1')
    $L.Add('')
    $L.Add('locale: ' + $Cfg.Locale)
    $L.Add('keyboard:')
    $L.Add('  layout: ' + $Cfg.Keyboard)
    $L.Add('timezone: ' + $Cfg.Timezone)
    $L.Add('')
    $L.Add('# --- Akun utama (password disimpan sebagai hash SHA-512 crypt) -------------')
    $L.Add('identity:')
    $L.Add('  realname: ' + (Format-YamlString $Cfg.Realname))
    $L.Add('  username: ' + (Format-YamlString $Cfg.Username))
    $L.Add('  hostname: ' + (Format-YamlString $Cfg.Hostname))
    $L.Add('  password: "' + $Cfg.PasswordHash + '"')
    $L.Add('')

    if ($Cfg.Ssh) {
        $L.Add('# --- SSH ------------------------------------------------------------------')
        $L.Add('ssh:')
        $L.Add('  install-server: true')
        $L.Add('  allow-pw: ' + $(if ($Cfg.SshPassword) { 'true' } else { 'false' }))
        $L.Add('')
    }

    $L.Add('# --- Penyimpanan ----------------------------------------------------------')
    $L.Add('storage:')
    $L.Add('  layout:')
    $L.Add('    name: ' + $Cfg.StorageLayout)
    $L.Add('    match:')
    if ($Cfg.Disk -like '/dev/*') {
        $L.Add('      path: ' + $Cfg.Disk)
    } else {
        $L.Add('      size: ' + $Cfg.Disk)
    }
    $L.Add('')

    $L.Add('# --- Setelah instalasi selesai -------------------------------------------')
    $L.Add('shutdown: ' + $Cfg.Shutdown)
    $L.Add('')

    $early = @()
    if ($Cfg.NetplanFix) {
        $early += "bash -c 'if [ -x /usr/sbin/netplan ]; then mv /usr/sbin/netplan /usr/sbin/netplan.real; { echo ""#!/bin/sh""; echo ""exit 0""; } > /usr/sbin/netplan; chmod 755 /usr/sbin/netplan; fi'"
    }
    foreach ($e in @($Cfg.EarlyCommands)) { if ($e.Trim()) { $early += $e.Trim() } }

    if ($early.Count -gt 0) {
        $L.Add('# --- Sebelum konfigurasi diterapkan (hanya menyentuh live session) --------')
        if ($Cfg.NetplanFix) {
            $L.Add('# `netplan apply` di live session bisa gagal (D-Bus time-out) dan itu FATAL')
            $L.Add('# dalam mode autoinstall. Skrip di bawah mengganti netplan live session')
            $L.Add('# dengan no-op; netplan sistem terpasang tetap ditulis normal oleh subiquity.')
        }
        $L.Add('early-commands:')
        foreach ($e in $early) { $L.Add('  - ' + $e) }
        $L.Add('')
    }

    $pkgs = @()
    foreach ($p in @($Cfg.Packages)) {
        foreach ($part in ("$p" -split ',')) {
            $pp = $part.Trim()
            if ($pp) { $pkgs += $pp }
        }
    }
    if ($pkgs.Count -gt 0) {
        $L.Add('# --- Paket tambahan -------------------------------------------------------')
        $L.Add('packages:')
        foreach ($p in $pkgs) { $L.Add('  - ' + $p) }
        $L.Add('')
    }

    $late = @()
    if ($Cfg.Ssh) {
        $late += 'bash -c ''mkdir -p /target/etc/ssh/sshd_config.d && printf "%s\n" "PasswordAuthentication yes" > /target/etc/ssh/sshd_config.d/99-autoinstall.conf'''
        $late += 'chmod 644 /target/etc/ssh/sshd_config.d/99-autoinstall.conf'
        $late += 'curtin in-target -- systemctl enable ssh'
    }
    foreach ($a in @($Cfg.LateCommands)) { if ($a.Trim()) { $late += $a.Trim() } }

    if ($late.Count -gt 0) {
        $L.Add('late-commands:')
        foreach ($a in $late) { $L.Add('  - ' + $a) }
        $L.Add('')
    }

    $L.Add('# Simpan log instalasi ke disk target bila terjadi kegagalan.')
    $L.Add('error-commands:')
    $L.Add('  - bash -c ''tar -czf /target/var/log/installer-logs.tar.gz /var/log/installer 2>/dev/null || true''')
    $L.Add('')

    return ($L -join "`n")
}

# ============================================================================
#  Validasi konfigurasi
# ============================================================================
function Test-Config {
    param([hashtable]$Cfg)
    $errors = @()

    if (-not $Cfg.Source) {
        $errors += 'ISO sumber belum dipilih.'
    } elseif (-not (Test-Path -LiteralPath $Cfg.Source)) {
        $errors += "File ISO sumber tidak ditemukan: $($Cfg.Source)"
    } elseif ($Cfg.Source -notmatch '\.iso$') {
        $errors += 'File ISO sumber harus berekstensi .iso.'
    }

    if (-not $Cfg.Output) {
        $errors += 'Lokasi ISO hasil belum diisi.'
    } elseif ($Cfg.Output -notmatch '\.iso$') {
        $errors += 'Nama ISO hasil harus berekstensi .iso.'
    } elseif ($Cfg.Source -and ([IO.Path]::GetFullPath($Cfg.Output) -eq [IO.Path]::GetFullPath($Cfg.Source))) {
        $errors += 'ISO hasil tidak boleh menimpa ISO sumber.'
    }

    if (-not $Cfg.Hostname -or $Cfg.Hostname -notmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$') {
        $errors += 'Hostname tidak valid. Gunakan huruf kecil, angka, dan tanda minus (contoh: home-server).'
    }
    if (-not $Cfg.Username -or $Cfg.Username -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        $errors += 'Username tidak valid. Gunakan huruf kecil/angka, diawali huruf (contoh: ugik).'
    }
    if (-not $Cfg.Realname) {
        $errors += 'Nama lengkap belum diisi.'
    }
    if (-not $Cfg.Password) {
        $errors += 'Password belum diisi.'
    } elseif ($Cfg.Password -ne $Cfg.Confirm) {
        $errors += 'Konfirmasi password tidak sama.'
    }
    if ($Cfg.Locale -notmatch '^[A-Za-z0-9_.@-]+$') {
        $errors += 'Locale tidak valid (contoh: en_US.UTF-8).'
    }
    if ($Cfg.Keyboard -notmatch '^[A-Za-z0-9_-]+$') {
        $errors += 'Layout keyboard tidak valid (contoh: us).'
    }
    if ($Cfg.Timezone -notmatch '^[A-Za-z0-9_+\-/]+$') {
        $errors += 'Timezone tidak valid (contoh: Asia/Jakarta).'
    }
    if ($Cfg.StorageLayout -notin @('direct', 'lvm', 'zfs')) {
        $errors += 'Layout penyimpanan harus direct, lvm, atau zfs.'
    }
    if ($Cfg.Disk -notmatch '^(largest|smallest|/dev/[A-Za-z0-9/_.-]+)$') {
        $errors += 'Disk target: isi "largest", "smallest", atau path seperti /dev/nvme0n1.'
    }
    if ($Cfg.Shutdown -notin @('poweroff', 'reboot')) {
        $errors += 'Aksi setelah instalasi harus poweroff atau reboot.'
    }
    foreach ($p in @($Cfg.Packages)) {
        foreach ($part in ("$p" -split ',')) {
            $pp = $part.Trim()
            if ($pp -and $pp -notmatch '^[a-z0-9][a-z0-9.+-]*$') {
                $errors += "Nama paket tidak valid: $pp"
            }
        }
    }

    return $errors
}

# ============================================================================
#  Proses pembuatan ISO
# ============================================================================
function Build-AutoinstallIso {
    param([hashtable]$Cfg)

    if (-not (Test-Path -LiteralPath $script:Xorriso)) {
        throw "xorriso tidak ditemukan: $($script:Xorriso). Pastikan folder 'tools' ikut tersalin."
    }

    $src = [IO.Path]::GetFullPath($Cfg.Source)
    $out = [IO.Path]::GetFullPath($Cfg.Output)
    $outDir = Split-Path -Parent $out
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    Write-AppLog 'Menghitung hash password (SHA-512 crypt)...'
    Set-Status 'Menghitung hash password...'
    $Cfg.PasswordHash = ConvertTo-Sha512Crypt -Password $Cfg.Password -Salt (New-CryptSalt)

    $work = Join-Path $env:TEMP ('ububuild-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'boot\grub') | Out-Null

    try {
        # ---- 0. Deteksi ISO ----------------------------------------------------
        Write-AppLog 'Membaca ISO sumber...'
        Set-Status 'Membaca ISO...'
        $label = Get-IsoLabel $src
        if ($label) { Write-AppLog ('  ISO: ' + $label) }
        else { Write-AppLog '  ISO: (label tidak terbaca)' }

        # ---- 1. Ekstrak file boot dari ISO asli --------------------------------
        Write-AppLog 'Mengekstrak file boot dari ISO sumber...'
        Set-Status 'Mengekstrak file boot...'
        $grubPath     = Join-Path $work 'boot\grub\grub.cfg'
        $loopbackPath = Join-Path $work 'boot\grub\loopback.cfg'

        Invoke-Tool -Exe $script:Xorriso -Arguments @(
            '-indev', (To-Fwd $src), '-osirrox', 'on',
            '-extract', '/boot/grub/grub.cfg',     (To-Cyg $grubPath),
            '-extract', '/boot/grub/loopback.cfg', (To-Cyg $loopbackPath)
        ) -WorkingDirectory $work | Out-Null

        if (-not (Test-Path -LiteralPath $grubPath)) {
            throw 'ISO sumber tidak memiliki /boot/grub/grub.cfg. Pastikan ini ISO Ubuntu Server resmi.'
        }
        $hasLoopback = Test-Path -LiteralPath $loopbackPath

        # File hasil ekstrak dari ISO bersifat read-only; izinkan ditimpa.
        (Get-Item -LiteralPath $grubPath).IsReadOnly = $false
        if ($hasLoopback) { (Get-Item -LiteralPath $loopbackPath).IsReadOnly = $false }

        # ---- 2. Patch entri boot ------------------------------------------------
        $grubText = Update-BootConfigText (Get-Content -LiteralPath $grubPath -Raw)
        [IO.File]::WriteAllText($grubPath, $grubText, (New-Object System.Text.UTF8Encoding($false)))

        if ($hasLoopback) {
            $loopText = Update-BootConfigText (Get-Content -LiteralPath $loopbackPath -Raw)
            [IO.File]::WriteAllText($loopbackPath, $loopText, (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-AppLog '  entri boot: "autoinstall" ditambahkan.'

        # ---- 3. Tulis autoinstall.yaml -----------------------------------------
        $yaml = New-AutoinstallYaml $Cfg
        $yamlPath = Join-Path $work 'autoinstall.yaml'
        [IO.File]::WriteAllText($yamlPath, $yaml, (New-Object System.Text.UTF8Encoding($false)))
        Write-AppLog '  autoinstall.yaml dibuat.'

        # ---- 4. Baca resep layout boot dari ISO asli ---------------------------
        Write-AppLog 'Membaca layout boot ISO sumber...'
        Set-Status 'Membaca layout boot...'
        $report = Invoke-Tool -Exe $script:Xorriso -Arguments @('-indev', (To-Fwd $src), '-report_system_area', 'cmd') -WorkingDirectory $work
        $bootCmds = @($report.Output |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^-(boot_image|append_partition)\s' })

        if ($bootCmds.Count -lt 3) {
            $report.Output | Select-Object -Last 15 | ForEach-Object { Write-AppLog ('  ' + $_) }
            throw 'Gagal membaca layout boot dari ISO sumber. ISO mungkin rusak atau bukan ISO Ubuntu Server resmi.'
        }
        $srcFwd = To-Fwd $src
        $srcCyg = To-Cyg $src
        $recipe = @($bootCmds | ForEach-Object { $_.Replace($srcFwd, $srcCyg) })

        $bootArgs = @()
        foreach ($line in $recipe) { $bootArgs += @(Split-XorrisoRecipe $line) }
        Write-AppLog ('  {0} perintah layout boot terbaca.' -f $bootCmds.Count)

        # ---- 5. Susun ISO baru --------------------------------------------------
        $maps = @('-map', 'boot/grub/grub.cfg', '/boot/grub/grub.cfg')
        if ($hasLoopback) { $maps += @('-map', 'boot/grub/loopback.cfg', '/boot/grub/loopback.cfg') }
        $maps += @('-map', 'autoinstall.yaml', '/autoinstall.yaml')

        if (Test-Path -LiteralPath $out) {
            Write-AppLog 'Menghapus ISO hasil yang lama...'
            Remove-Item -LiteralPath $out -Force
        }

        $xorArgs = @('-indev', (To-Fwd $src), '-outdev', (To-Fwd $out), '-overwrite', 'on') +
            $bootArgs + $maps + @('-commit', '-end')

        Write-AppLog ''
        Write-AppLog 'Membangun ISO (beberapa menit, tergantung kecepatan disk)...'
        $started = Get-Date
        $tick = {
            $elapsed = ((Get-Date) - $started).TotalSeconds
            Set-Status ('Membangun ISO... {0:N0} detik' -f $elapsed)
        }
        $build = Invoke-Tool -Exe $script:Xorriso -Arguments $xorArgs -WorkingDirectory $work -Tick $tick

        $failure = @($build.Output | Where-Object { $_ -match 'xorriso : FAILURE|xorriso : aborting|SORRY' })
        if (-not (Test-Path -LiteralPath $out) -or $failure.Count -gt 0) {
            $build.Output | Select-Object -Last 25 | ForEach-Object { Write-AppLog ('  ' + $_) }
            throw 'xorriso gagal membuat ISO. Lihat log di atas.'
        }

        $info = Get-Item -LiteralPath $out
        Write-AppLog ''
        Write-AppLog ('Selesai: {0} ({1:N2} GB)' -f $info.FullName, ($info.Length / 1GB))

        # ---- 6. Verifikasi (opsional) -------------------------------------------
        if ($Cfg.Verify) {
            Write-AppLog ''
            Write-AppLog 'Verifikasi ISO hasil:'
            Set-Status 'Verifikasi ISO hasil...'

            $verify = Invoke-Tool -Exe $script:Xorriso -Arguments @(
                '-indev', (To-Fwd $out), '-report_el_torito', 'plain', '-report_system_area', 'plain'
            ) -WorkingDirectory $work
            $verify.Output |
                Where-Object { $_ -match 'Boot record|El Torito boot img|GPT start and size|Volume id' } |
                ForEach-Object { Write-AppLog ('  ' + $_.Trim()) }

            $esps = @($verify.Output | Where-Object { $_ -match 'El Torito boot img\s*:' })
            if ($esps.Count -lt 2) {
                Write-AppLog '  PERINGATAN: entri El Torito BIOS/UEFI tidak lengkap.'
            } else {
                Write-AppLog '  OK: entri boot BIOS + UEFI ada.'
            }

            $isoSectors = [int64]($info.Length / 512)
            $imageSectors = 0
            foreach ($ln in $verify.Output) {
                if ($ln -match '^ISO image size/512\s*:\s*(\d+)') { $imageSectors = [int64]$matches[1]; break }
            }
            $esp = $verify.Output | Where-Object { $_ -match 'El Torito boot img\s*:\s*2' } | Select-Object -First 1
            if ($imageSectors -gt 0 -and $esp) {
                $parts = ($esp -split '\s+') | Where-Object { $_ -ne '' }
                $espLba = [int64]$parts[-1]
                $espStart = $espLba * 4
                $gpt2 = $verify.Output | Where-Object { $_ -match 'GPT start and size\s*:\s*2\s' } | Select-Object -First 1
                if ($gpt2) {
                    $g = (($gpt2 -split ':')[1].Trim() -split '\s+')
                    if ([int64]$g[1] -eq $espStart) {
                        Write-AppLog ('  OK: partisi ESP GPT cocok dengan image UEFI (sector {0:N0}).' -f $espStart)
                    } else {
                        Write-AppLog ('  PERINGATAN: GPT ESP ({0:N0}) != El Torito UEFI ({1:N0}).' -f [int64]$g[1], $espStart)
                    }
                }
                if ($isoSectors -ge $imageSectors) {
                    Write-AppLog ('  OK: ukuran ISO ({0:N0} sector) >= image ({1:N0} sector).' -f $isoSectors, $imageSectors)
                } else {
                    Write-AppLog '  PERINGATAN: ukuran ISO lebih kecil dari isi image.'
                }
            }

            # Isi ISO: pastikan autoinstall.yaml & entri boot hasil patch benar.
            $checkYaml = Join-Path $work 'check-autoinstall.yaml'
            $checkGrub = Join-Path $work 'check-grub.cfg'
            Invoke-Tool -Exe $script:Xorriso -Arguments @(
                '-indev', (To-Fwd $out), '-osirrox', 'on',
                '-extract', '/autoinstall.yaml',      (To-Cyg $checkYaml),
                '-extract', '/boot/grub/grub.cfg',    (To-Cyg $checkGrub)
            ) -WorkingDirectory $work | Out-Null

            if ((Test-Path -LiteralPath $checkYaml) -and
                ((Get-FileHash -LiteralPath $checkYaml).Hash -eq (Get-FileHash -LiteralPath $yamlPath).Hash)) {
                Write-AppLog '  OK: /autoinstall.yaml di dalam ISO sesuai.'
            } else {
                Write-AppLog '  PERINGATAN: /autoinstall.yaml di dalam ISO tidak dapat diverifikasi.'
            }
            if ((Test-Path -LiteralPath $checkGrub) -and
                (Select-String -LiteralPath $checkGrub -Pattern 'autoinstall' -Quiet)) {
                Write-AppLog '  OK: parameter "autoinstall" ada di /boot/grub/grub.cfg.'
            } else {
                Write-AppLog '  PERINGATAN: parameter "autoinstall" tidak ditemukan di grub.cfg ISO hasil.'
            }
        }

        Write-AppLog ''
        Write-AppLog ('Ukuran : {0:N2} GB' -f ($info.Length / 1GB))
        Write-AppLog ('SHA256 : ' + (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash)
        Write-AppLog ''
        Write-AppLog 'SELESAI. Flash ISO hasil ke USB (Rufus mode DD / balenaEtcher / Ventoy).'
        Set-Status 'Selesai.'
        return $out
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
#  Mode CLI (tanpa GUI)
# ============================================================================
if ($Cli) {
    if (-not $Source -or -not $Output -or -not $Password) {
        Write-Host 'Pemakaian: UbuntuAutoinstallBuilder.ps1 -Cli -Source <iso> -Output <iso> -Password <password>'
        Write-Host '  (opsional: -Hostname -Username -Realname -Locale -Keyboard -Timezone -StorageLayout -Disk -Shutdown -NoSsh -NoNetplanFix -NoVerify)'
        exit 2
    }

    $cfg = @{
        Source        = $Source
        Output        = $Output
        Hostname      = $Hostname
        Username      = $Username
        Realname      = $Realname
        Password      = $Password
        Confirm       = $Password
        Locale        = $Locale
        Keyboard      = $Keyboard
        Timezone      = $Timezone
        StorageLayout = $StorageLayout
        Disk          = $Disk
        Shutdown      = $Shutdown
        Ssh           = (-not $NoSsh)
        SshPassword   = $true
        NetplanFix    = (-not $NoNetplanFix)
        Verify        = (-not $NoVerify)
        Packages      = $Packages
        LateCommands  = $LateCommands
        EarlyCommands = $EarlyCommands
    }

    $problems = Test-Config $cfg
    if ($problems.Count -gt 0) {
        $problems | ForEach-Object { Write-Host "ERROR: $_" }
        exit 1
    }

    try {
        [void](Build-AutoinstallIso -Cfg $cfg)
        exit 0
    } catch {
        Write-Host "GAGAL: $($_.Exception.Message)"
        exit 1
    }
}

# ============================================================================
#  GUI (Windows Forms)
# ============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:HasGui = $true

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Ubuntu Autoinstall ISO Builder'
$form.Size = New-Object System.Drawing.Size(790, 742)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function New-UiLabel([string]$Text, [int]$X, [int]$Y, [int]$W = 145) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($W, 20)
    return $lbl
}

function New-UiHint([string]$Text, [int]$X, [int]$Y, [int]$W) {
    $lbl = New-UiLabel $Text $X $Y $W
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(105, 105, 105)
    return $lbl
}

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 12)
$tabs.Size = New-Object System.Drawing.Size(748, 590)

$tabBasic = New-Object System.Windows.Forms.TabPage
$tabBasic.Text = 'Konfigurasi'
$tabBasic.Padding = New-Object System.Windows.Forms.Padding(3)

$tabAdvanced = New-Object System.Windows.Forms.TabPage
$tabAdvanced.Text = 'Lanjutan'

$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = 'Log'

# ---------------------------------------------------------------- tab dasar --
$grpIo = New-Object System.Windows.Forms.GroupBox
$grpIo.Text = 'Sumber & hasil'
$grpIo.Location = New-Object System.Drawing.Point(8, 8)
$grpIo.Size = New-Object System.Drawing.Size(724, 126)

$txtIso = New-Object System.Windows.Forms.TextBox
$txtIso.Location = New-Object System.Drawing.Point(12, 40)
$txtIso.Size = New-Object System.Drawing.Size(584, 23)

$btnIso = New-Object System.Windows.Forms.Button
$btnIso.Text = 'Pilih...'
$btnIso.Location = New-Object System.Drawing.Point(602, 38)
$btnIso.Size = New-Object System.Drawing.Size(108, 26)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(12, 92)
$txtOut.Size = New-Object System.Drawing.Size(584, 23)

$btnOut = New-Object System.Windows.Forms.Button
$btnOut.Text = 'Simpan ke...'
$btnOut.Location = New-Object System.Drawing.Point(602, 90)
$btnOut.Size = New-Object System.Drawing.Size(108, 26)

$grpIo.Controls.AddRange(@(
    (New-UiLabel 'ISO sumber (ISO Ubuntu Server asli)' 12 20 420),
    $txtIso, $btnIso,
    (New-UiLabel 'ISO hasil yang akan dibuat' 12 72 420),
    $txtOut, $btnOut
))

$grpId = New-Object System.Windows.Forms.GroupBox
$grpId.Text = 'Akun & identitas'
$grpId.Location = New-Object System.Drawing.Point(8, 140)
$grpId.Size = New-Object System.Drawing.Size(724, 200)

$txtRealname = New-Object System.Windows.Forms.TextBox
$txtRealname.Location = New-Object System.Drawing.Point(168, 20)
$txtRealname.Size = New-Object System.Drawing.Size(250, 23)

$txtHostname = New-Object System.Windows.Forms.TextBox
$txtHostname.Location = New-Object System.Drawing.Point(168, 50)
$txtHostname.Size = New-Object System.Drawing.Size(250, 23)

$txtUsername = New-Object System.Windows.Forms.TextBox
$txtUsername.Location = New-Object System.Drawing.Point(168, 80)
$txtUsername.Size = New-Object System.Drawing.Size(250, 23)

$txtPassword = New-Object System.Windows.Forms.TextBox
$txtPassword.Location = New-Object System.Drawing.Point(168, 110)
$txtPassword.Size = New-Object System.Drawing.Size(250, 23)
$txtPassword.UseSystemPasswordChar = $true

$txtPassword2 = New-Object System.Windows.Forms.TextBox
$txtPassword2.Location = New-Object System.Drawing.Point(168, 140)
$txtPassword2.Size = New-Object System.Drawing.Size(250, 23)
$txtPassword2.UseSystemPasswordChar = $true

$chkShowPw = New-Object System.Windows.Forms.CheckBox
$chkShowPw.Text = 'Tampilkan password'
$chkShowPw.Location = New-Object System.Drawing.Point(428, 108)
$chkShowPw.Size = New-Object System.Drawing.Size(160, 22)

$lblStrength = New-Object System.Windows.Forms.Label
$lblStrength.Location = New-Object System.Drawing.Point(168, 168)
$lblStrength.Size = New-Object System.Drawing.Size(420, 20)
$lblStrength.Text = ''

$grpId.Controls.AddRange(@(
    (New-UiLabel 'Nama lengkap' 12 24),
    $txtRealname,
    (New-UiLabel 'Hostname' 12 54),
    $txtHostname,
    (New-UiLabel 'Username' 12 84),
    $txtUsername,
    (New-UiLabel 'Password' 12 114),
    $txtPassword,
    (New-UiLabel 'Konfirmasi password' 12 144),
    $txtPassword2,
    $chkShowPw,
    $lblStrength,
    (New-UiHint 'harus sama dengan password di atas' 428 140 240),
    (New-UiHint 'contoh: home-server' 428 54 200),
    (New-UiHint 'huruf kecil, angka, minus' 428 84 220)
))

$grpSys = New-Object System.Windows.Forms.GroupBox
$grpSys.Text = 'Sistem & penyimpanan'
$grpSys.Location = New-Object System.Drawing.Point(8, 346)
$grpSys.Size = New-Object System.Drawing.Size(724, 200)

$cmbLocale = New-Object System.Windows.Forms.ComboBox
$cmbLocale.Location = New-Object System.Drawing.Point(168, 20)
$cmbLocale.Size = New-Object System.Drawing.Size(250, 23)
$cmbLocale.DropDownStyle = 'DropDown'
[void]$cmbLocale.Items.AddRange(@('en_US.UTF-8', 'en_GB.UTF-8', 'id_ID.UTF-8', 'C.UTF-8'))
$cmbLocale.Text = 'en_US.UTF-8'

$cmbKeyboard = New-Object System.Windows.Forms.ComboBox
$cmbKeyboard.Location = New-Object System.Drawing.Point(168, 50)
$cmbKeyboard.Size = New-Object System.Drawing.Size(150, 23)
$cmbKeyboard.DropDownStyle = 'DropDown'
[void]$cmbKeyboard.Items.AddRange(@('us', 'gb', 'de', 'fr', 'id', 'jp'))
$cmbKeyboard.Text = 'us'

$cmbTimezone = New-Object System.Windows.Forms.ComboBox
$cmbTimezone.Location = New-Object System.Drawing.Point(168, 80)
$cmbTimezone.Size = New-Object System.Drawing.Size(250, 23)
$cmbTimezone.DropDownStyle = 'DropDown'
[void]$cmbTimezone.Items.AddRange(@('Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura', 'Asia/Singapore', 'UTC', 'Etc/UTC'))
$cmbTimezone.Text = 'Asia/Jakarta'

$cmbLayout = New-Object System.Windows.Forms.ComboBox
$cmbLayout.Location = New-Object System.Drawing.Point(168, 110)
$cmbLayout.Size = New-Object System.Drawing.Size(150, 23)
$cmbLayout.DropDownStyle = 'DropDownList'
[void]$cmbLayout.Items.AddRange(@('direct', 'lvm', 'zfs'))
$cmbLayout.SelectedIndex = 0

$txtDisk = New-Object System.Windows.Forms.TextBox
$txtDisk.Location = New-Object System.Drawing.Point(168, 140)
$txtDisk.Size = New-Object System.Drawing.Size(250, 23)
$txtDisk.Text = 'largest'

$cmbShutdown = New-Object System.Windows.Forms.ComboBox
$cmbShutdown.Location = New-Object System.Drawing.Point(168, 168)
$cmbShutdown.Size = New-Object System.Drawing.Size(150, 23)
$cmbShutdown.DropDownStyle = 'DropDownList'
[void]$cmbShutdown.Items.AddRange(@('poweroff', 'reboot'))
$cmbShutdown.SelectedIndex = 0

$grpSys.Controls.AddRange(@(
    (New-UiLabel 'Locale' 12 24),
    $cmbLocale,
    (New-UiLabel 'Keyboard' 12 54),
    $cmbKeyboard,
    (New-UiLabel 'Timezone' 12 84),
    $cmbTimezone,
    (New-UiLabel 'Layout disk' 12 114),
    $cmbLayout,
    (New-UiLabel 'Disk target' 12 144),
    $txtDisk,
    (New-UiLabel 'Setelah instalasi' 12 172),
    $cmbShutdown,
    (New-UiHint '"largest" = disk terbesar, atau /dev/nvme0n1' 428 144 280)
))

$tabBasic.Controls.AddRange(@($grpIo, $grpId, $grpSys))

# ------------------------------------------------------------- tab lanjutan --
$chkSsh = New-Object System.Windows.Forms.CheckBox
$chkSsh.Text = 'Pasang OpenSSH server'
$chkSsh.Location = New-Object System.Drawing.Point(14, 16)
$chkSsh.Size = New-Object System.Drawing.Size(300, 22)
$chkSsh.Checked = $true

$chkSshPw = New-Object System.Windows.Forms.CheckBox
$chkSshPw.Text = 'Izinkan login SSH dengan password'
$chkSshPw.Location = New-Object System.Drawing.Point(34, 42)
$chkSshPw.Size = New-Object System.Drawing.Size(320, 22)
$chkSshPw.Checked = $true

$chkNetplan = New-Object System.Windows.Forms.CheckBox
$chkNetplan.Text = 'Workaround netplan di live session (disarankan, terutama untuk VM)'
$chkNetplan.Location = New-Object System.Drawing.Point(14, 72)
$chkNetplan.Size = New-Object System.Drawing.Size(520, 22)
$chkNetplan.Checked = $true

$lblNetplan = New-Object System.Windows.Forms.Label
$lblNetplan.Location = New-Object System.Drawing.Point(34, 94)
$lblNetplan.Size = New-Object System.Drawing.Size(690, 34)
$lblNetplan.ForeColor = [System.Drawing.Color]::FromArgb(105, 105, 105)
$lblNetplan.Text = 'Mengganti /usr/sbin/netplan di live session dengan no-op. Hanya menyentuh live session; netplan sistem terpasang tetap ditulis normal. Tanpa ini, kegagalan "netplan apply" bisa membatalkan instalasi.'

$chkVerify = New-Object System.Windows.Forms.CheckBox
$chkVerify.Text = 'Verifikasi ISO hasil setelah dibuat (disarankan)'
$chkVerify.Location = New-Object System.Drawing.Point(14, 136)
$chkVerify.Size = New-Object System.Drawing.Size(400, 22)
$chkVerify.Checked = $true

$grpPkg = New-Object System.Windows.Forms.GroupBox
$grpPkg.Text = 'Paket tambahan (satu per baris, opsional)'
$grpPkg.Location = New-Object System.Drawing.Point(14, 166)
$grpPkg.Size = New-Object System.Drawing.Size(350, 160)

$txtPackages = New-Object System.Windows.Forms.TextBox
$txtPackages.Multiline = $true
$txtPackages.ScrollBars = 'Vertical'
$txtPackages.Location = New-Object System.Drawing.Point(10, 22)
$txtPackages.Size = New-Object System.Drawing.Size(330, 128)
$grpPkg.Controls.Add($txtPackages)

$grpLate = New-Object System.Windows.Forms.GroupBox
$grpLate.Text = 'late-commands tambahan (satu per baris, opsional)'
$grpLate.Location = New-Object System.Drawing.Point(376, 166)
$grpLate.Size = New-Object System.Drawing.Size(352, 160)

$txtLate = New-Object System.Windows.Forms.TextBox
$txtLate.Multiline = $true
$txtLate.ScrollBars = 'Vertical'
$txtLate.Location = New-Object System.Drawing.Point(10, 22)
$txtLate.Size = New-Object System.Drawing.Size(332, 128)
$txtLate.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$grpLate.Controls.Add($txtLate)

$grpEarly = New-Object System.Windows.Forms.GroupBox
$grpEarly.Text = 'early-commands tambahan (satu per baris, opsional)'
$grpEarly.Location = New-Object System.Drawing.Point(14, 336)
$grpEarly.Size = New-Object System.Drawing.Size(714, 150)

$txtEarly = New-Object System.Windows.Forms.TextBox
$txtEarly.Multiline = $true
$txtEarly.ScrollBars = 'Vertical'
$txtEarly.Location = New-Object System.Drawing.Point(10, 22)
$txtEarly.Size = New-Object System.Drawing.Size(694, 118)
$txtEarly.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$grpEarly.Controls.Add($txtEarly)

$tabAdvanced.Controls.AddRange(@(
    $chkSsh, $chkSshPw, $chkNetplan, $lblNetplan, $chkVerify,
    $grpPkg, $grpLate, $grpEarly
))

# ------------------------------------------------------------------- tab log --
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Dock = 'Fill'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
$txtLog.ForeColor = [System.Drawing.Color]::Gainsboro
$txtLog.WordWrap = $false
$tabLog.Controls.Add($txtLog)

$tabs.TabPages.AddRange(@($tabBasic, $tabAdvanced, $tabLog))
$form.Controls.Add($tabs)

# ------------------------------------------------------------------- tombol --
$btnBuild = New-Object System.Windows.Forms.Button
$btnBuild.Text = 'Buat ISO'
$btnBuild.Location = New-Object System.Drawing.Point(12, 612)
$btnBuild.Size = New-Object System.Drawing.Size(150, 34)
$btnBuild.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Buka folder hasil'
$btnOpen.Location = New-Object System.Drawing.Point(170, 612)
$btnOpen.Size = New-Object System.Drawing.Size(140, 34)
$btnOpen.Enabled = $false

$btnSaveProfile = New-Object System.Windows.Forms.Button
$btnSaveProfile.Text = 'Simpan profil'
$btnSaveProfile.Location = New-Object System.Drawing.Point(318, 612)
$btnSaveProfile.Size = New-Object System.Drawing.Size(120, 30)

$btnLoadProfile = New-Object System.Windows.Forms.Button
$btnLoadProfile.Text = 'Muat profil'
$btnLoadProfile.Location = New-Object System.Drawing.Point(444, 612)
$btnLoadProfile.Size = New-Object System.Drawing.Size(120, 30)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Siap.'
$lblStatus.Location = New-Object System.Drawing.Point(572, 620)
$lblStatus.Size = New-Object System.Drawing.Size(188, 20)
$lblStatus.AutoEllipsis = $true
$script:StatusLabel = $lblStatus
$script:UiLog = $txtLog

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(12, 656)
$progress.Size = New-Object System.Drawing.Size(748, 14)
$progress.Style = 'Marquee'
$progress.MarqueeAnimationSpeed = 0
$progress.Visible = $false

$form.Controls.AddRange(@($btnBuild, $btnOpen, $btnSaveProfile, $btnLoadProfile, $lblStatus, $progress))

# ------------------------------------------------------------- helper form UI --
function Set-OutputDefault {
    if ($txtIso.Text.Trim()) {
        $dir = Split-Path -Parent $txtIso.Text.Trim()
        $base = [IO.Path]::GetFileNameWithoutExtension($txtIso.Text.Trim())
        $base = $base -replace '-autoinstall$', ''
        $txtOut.Text = Join-Path $dir ($base + '-autoinstall.iso')
    }
}

function Update-IsoDescription {
    $iso = $txtIso.Text.Trim()
    $label = ''
    if ($iso -and (Test-Path -LiteralPath $iso)) { $label = Get-IsoLabel $iso }
    if ($label) {
        $grpIo.Text = 'Sumber & hasil  -  terdeteksi: ' + $label
    } else {
        $grpIo.Text = 'Sumber & hasil'
    }
}

function Update-PasswordStrength {
    $pw = $txtPassword.Text
    if (-not $pw) { $lblStrength.Text = ''; return }
    if ($pw.Length -ge 12) {
        $lblStrength.Text = 'Kekuatan: kuat'
        $lblStrength.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
    } elseif ($pw.Length -ge 8) {
        $lblStrength.Text = 'Kekuatan: sedang'
        $lblStrength.ForeColor = [System.Drawing.Color]::FromArgb(170, 110, 0)
    } else {
        $lblStrength.Text = 'Kekuatan: LEMAH - password mudah ditebak (tetap boleh dipakai)'
        $lblStrength.ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0)
    }
}

function Get-ConfigFromForm {
    $lines = { param($box) @($box.Lines | Where-Object { $_.Trim() }) }
    return @{
        Source        = $txtIso.Text.Trim()
        Output        = $txtOut.Text.Trim()
        Hostname      = $txtHostname.Text.Trim()
        Username      = $txtUsername.Text.Trim()
        Realname      = $txtRealname.Text.Trim()
        Password      = $txtPassword.Text
        Confirm       = $txtPassword2.Text
        Locale        = $cmbLocale.Text.Trim()
        Keyboard      = $cmbKeyboard.Text.Trim()
        Timezone      = $cmbTimezone.Text.Trim()
        StorageLayout = "$($cmbLayout.SelectedItem)"
        Disk          = $txtDisk.Text.Trim()
        Shutdown      = "$($cmbShutdown.SelectedItem)"
        Ssh           = $chkSsh.Checked
        SshPassword   = $chkSshPw.Checked
        NetplanFix    = $chkNetplan.Checked
        Verify        = $chkVerify.Checked
        Packages      = (& $lines $txtPackages)
        LateCommands  = (& $lines $txtLate)
        EarlyCommands = (& $lines $txtEarly)
    }
}

# ------------------------------------------------------------------ event UI --
$btnIso.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Pilih ISO Ubuntu Server asli'
    $dlg.Filter = 'File ISO (*.iso)|*.iso'
    if ($txtIso.Text.Trim()) { $dlg.InitialDirectory = Split-Path -Parent $txtIso.Text.Trim() }
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtIso.Text = $dlg.FileName
        Set-OutputDefault
        Update-IsoDescription
    }
})

$btnOut.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = 'Simpan ISO hasil sebagai'
    $dlg.Filter = 'File ISO (*.iso)|*.iso'
    $dlg.FileName = [IO.Path]::GetFileName($txtOut.Text)
    if ($txtOut.Text.Trim()) { $dlg.InitialDirectory = Split-Path -Parent $txtOut.Text.Trim() }
    if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.FileName }
})

$txtPassword.Add_TextChanged({ Update-PasswordStrength })

$chkShowPw.Add_CheckedChanged({
    $show = $chkShowPw.Checked
    $txtPassword.UseSystemPasswordChar = -not $show
    $txtPassword2.UseSystemPasswordChar = -not $show
})

$chkSsh.Add_CheckedChanged({ $chkSshPw.Enabled = $chkSsh.Checked })

$btnBuild.Add_Click({
    $cfg = Get-ConfigFromForm
    $problems = Test-Config $cfg
    if ($problems.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(($problems -join "`n`n"), 'Periksa data',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    if ((Test-Path -LiteralPath $cfg.Output) -and
        [System.Windows.Forms.MessageBox]::Show(
            "File ISO hasil sudah ada:`n$($cfg.Output)`n`nGanti (timpa)?",
            'Konfirmasi', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question) -ne 'Yes') {
        return
    }

    $txtLog.Clear()
    $tabs.SelectedTab = $tabLog
    $btnBuild.Enabled = $false
    $btnLoadProfile.Enabled = $false
    $btnSaveProfile.Enabled = $false
    $progress.Visible = $true
    $progress.MarqueeAnimationSpeed = 30
    $lblStatus.Text = 'Memulai...'
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $result = Build-AutoinstallIso -Cfg $cfg
        $btnOpen.Enabled = $true
        $btnOpen.Tag = $result
        [void][System.Windows.Forms.MessageBox]::Show(
            "ISO berhasil dibuat:`n$result`n`nFlash ke USB dengan Rufus (mode DD), balenaEtcher, atau Ventoy.",
            'Selesai', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
    } catch {
        Set-Status 'Gagal.'
        Write-AppLog ''
        Write-AppLog ('GAGAL: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Gagal membuat ISO.`n`n" + $_.Exception.Message + "`n`nLihat tab Log untuk detail."),
            'Gagal', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    } finally {
        $btnBuild.Enabled = $true
        $btnLoadProfile.Enabled = $true
        $btnSaveProfile.Enabled = $true
        $progress.MarqueeAnimationSpeed = 0
        $progress.Visible = $false
    }
})

$btnOpen.Add_Click({
    $target = $btnOpen.Tag
    if ($target -and (Test-Path -LiteralPath $target)) {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $target + '"')
    }
})

$btnSaveProfile.Add_Click({
    $dir = Join-Path $script:AppDir 'profiles'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = 'Simpan profil'
    $dlg.Filter = 'Profil JSON (*.json)|*.json'
    $dlg.InitialDirectory = $dir
    $dlg.FileName = 'profil.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }

    $cfg = Get-ConfigFromForm
    $profile = [ordered]@{
        iso        = $cfg.Source
        out        = $cfg.Output
        realname   = $cfg.Realname
        hostname   = $cfg.Hostname
        username   = $cfg.Username
        locale     = $cfg.Locale
        keyboard   = $cfg.Keyboard
        timezone   = $cfg.Timezone
        layout     = $cfg.StorageLayout
        disk       = $cfg.Disk
        shutdown   = $cfg.Shutdown
        ssh        = $cfg.Ssh
        sshpw      = $cfg.SshPassword
        netplanfix = $cfg.NetplanFix
        verify     = $cfg.Verify
        packages   = @($cfg.Packages)
        late       = @($cfg.LateCommands)
        early      = @($cfg.EarlyCommands)
    }
    ($profile | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $dlg.FileName -Encoding UTF8
    Set-Status 'Profil disimpan.'
})

$btnLoadProfile.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Muat profil'
    $dlg.Filter = 'Profil JSON (*.json)|*.json'
    $dlg.InitialDirectory = (Join-Path $script:AppDir 'profiles')
    if ($dlg.ShowDialog() -ne 'OK') { return }

    try {
        $p = Get-Content -LiteralPath $dlg.FileName -Raw | ConvertFrom-Json
        if ($p.iso)        { $txtIso.Text = $p.iso }
        if ($p.out)        { $txtOut.Text = $p.out }
        if ($p.realname)   { $txtRealname.Text = $p.realname }
        if ($p.hostname)   { $txtHostname.Text = $p.hostname }
        if ($p.username)   { $txtUsername.Text = $p.username }
        if ($p.locale)     { $cmbLocale.Text = $p.locale }
        if ($p.keyboard)   { $cmbKeyboard.Text = $p.keyboard }
        if ($p.timezone)   { $cmbTimezone.Text = $p.timezone }
        if ($p.layout)     { $cmbLayout.SelectedItem = $p.layout }
        if ($p.disk)       { $txtDisk.Text = $p.disk }
        if ($p.shutdown)   { $cmbShutdown.SelectedItem = $p.shutdown }
        $chkSsh.Checked = [bool]$p.ssh
        $chkSshPw.Checked = [bool]$p.sshpw
        $chkNetplan.Checked = [bool]$p.netplanfix
        $chkVerify.Checked = [bool]$p.verify
        $txtPackages.Text = (@($p.packages) -join "`r`n")
        $txtLate.Text = (@($p.late) -join "`r`n")
        $txtEarly.Text = (@($p.early) -join "`r`n")
        Set-Status 'Profil dimuat (password tidak ikut disimpan).'
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(("Gagal memuat profil: " + $_.Exception.Message), 'Profil',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

# ------------------------------------------------------------------- startup --
# Isi nilai awal yang memudahkan (bisa diubah semua).
$txtRealname.Text = 'ugik'
$txtHostname.Text = 'home-server'
$txtUsername.Text = 'ugik'

# Cari ISO Ubuntu Server di folder induk aplikasi ini.
try {
    $parentDir = Split-Path -Parent $script:AppDir
    $guesses = @(Get-ChildItem -LiteralPath $parentDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'autoinstall' -and $_.Name -match 'ubuntu' } |
        Sort-Object Name -Descending)
    if ($guesses.Count -gt 0) {
        $txtIso.Text = $guesses[0].FullName
        Set-OutputDefault
    }
} catch { }

$form.Add_Shown({ Update-IsoDescription })

Write-AppLog 'Ubuntu Autoinstall ISO Builder siap.'
Write-AppLog 'Isi data di tab "Konfigurasi" dan "Lanjutan", lalu klik "Buat ISO".'
Write-AppLog ''

[void]$form.ShowDialog()
