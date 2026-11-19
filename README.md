# Ubuntu Server Autoinstall — dua cara

Folder ini berisi dua alat untuk membuat ISO Ubuntu Server yang terinstal
otomatis (unattended). Pilih salah satu.

## 1. `AutoinstallBuilder\` — aplikasi GUI (disarankan)

Aplikasi Windows dengan form: pilih ISO Ubuntu Server (22.04 / 24.04 / 26.04
dan LTS lain), isi hostname/username/password/SSH/disk, klik **Buat ISO**.

- Jalankan: `AutoinstallBuilder\Jalankan.bat`
- Panduan lengkap: `AutoinstallBuilder\README.md`
- Bisa juga via CLI: lihat README bagian 7.

Cocok kalau Anda ingin membuat beberapa ISO dengan data berbeda tanpa mengedit
file apa pun.

## 2. `autoinstall\` — skrip lama (satu konfigurasi tetap)

Kumpulan skrip PowerShell + `autoinstall.yaml` yang dipakai untuk membuat ISO
pertama (Ubuntu 26.04.1) dengan konfigurasi tetap:

```powershell
cd autoinstall
.\build-iso.ps1
```

Konfigurasi ada di `autoinstall\autoinstall.yaml`; ubah manual bila perlu.
Dokumentasi: `autoinstall\README.md`.

## Memakai di komputer lain (clone dari GitHub)

Aplikasi ini bisa dipakai di komputer Windows lain tanpa install apa pun, karena
`xorriso` sudah ikut di dalam repo (`AutoinstallBuilder\tools\xorriso`, total
repo ±9,8 MB, 23 file). Tidak ada path komputer pembuat yang tertanam di kode.

```bat
git clone https://github.com/ugikhariyanto/autoinstallubuntuserver.git
cd autoinstallubuntuserver\AutoinstallBuilder
Jalankan.bat
```

Prasyarat di komputer tujuan:

- **Windows 10/11 64-bit** (PowerShell 5.1 dan WinForms sudah bawaan).
- **Ruang disk kosong ±2x ukuran ISO** (±8 GB untuk ISO 3,8 GB).
- **ISO Ubuntu Server asli** milik sendiri — ISO tidak ikut di repo.

Yang perlu diperhatikan:

- **Jangan memisahkan** `UbuntuAutoinstallBuilder.ps1` dari folder `tools\`.
  Kalau terpisah, build berhenti dengan pesan "xorriso tidak ditemukan".
- **Antivirus / SmartScreen** bisa mengarantina `xorriso.exe` (biner pihak
  ketiga, tidak bertanda tangan). Kecualikan folder aplikasi bila itu terjadi.
- Kalau repo diunduh sebagai **ZIP** (bukan `git clone`), file bisa diblokir
  Windows: klik kanan ZIP → **Properties** → **Unblock** sebelum di-extract.
- Di komputer kantor dengan **kebijakan GPO** yang melarang skrip PowerShell,
  `-ExecutionPolicy Bypass` pun tidak menolong; perlu izin admin.
- **Windows 32-bit tidak didukung** (`xorriso.exe` 64-bit).
- Clone lama (sebelum riwayat commit ditulis ulang) perlu disegarkan:
  `git fetch origin && git reset --hard origin/main`.

Catatan: `autoinstall\tools\` sengaja tidak di-commit; skrip lama
`autoinstall\build-iso.ps1` akan mengunduh xorriso sendiri bila dijalankan.

## Hasil yang sudah ada

- `ubuntu-26.04.1-live-server-amd64-autoinstall.iso` — hasil build dengan skrip
  lama (sudah teruji instalasi penuh di VM).

Keduanya menghasilkan ISO yang sama jenisnya: USB hybrid (BIOS + UEFI), instal
tanpa interaksi, lalu mesin mati sendiri (`poweroff`).
