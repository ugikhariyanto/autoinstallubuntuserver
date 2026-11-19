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

## Hasil yang sudah ada

- `ubuntu-26.04.1-live-server-amd64-autoinstall.iso` — hasil build dengan skrip
  lama (sudah teruji instalasi penuh di VM).

Keduanya menghasilkan ISO yang sama jenisnya: USB hybrid (BIOS + UEFI), instal
tanpa interaksi, lalu mesin mati sendiri (`poweroff`).
