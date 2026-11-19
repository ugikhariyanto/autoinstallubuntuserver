# Ubuntu Autoinstall ISO Builder

Aplikasi Windows (GUI) untuk membuat ISO **Ubuntu Server autoinstall**: ISO yang
saat di-boot langsung menginstal sendiri tanpa monitor, keyboard, atau klik
apa pun.

Anda cukup memilih ISO Ubuntu Server **asli** (belum dimodifikasi), mengisi data
instalasi, lalu klik **Buat ISO**. Aplikasi menghasilkan ISO baru; ISO asli tidak
pernah diubah.

Mendukung **Ubuntu Server LTS 22.04, 24.04, 26.04**, dan umumnya semua rilis
yang memakai installer Subiquity (autoinstall). Layout boot dibaca langsung dari
ISO yang Anda pilih, jadi tidak terikat satu versi tertentu.

---

## 1. Kebutuhan

- Windows 10/11 **64-bit** (PowerShell 5.1 dan WinForms sudah tersedia bawaan).
- Ruang disk kosong minimal **2x ukuran ISO** (ISO sumber + ISO hasil); untuk ISO
  3,8 GB sediakan ±8 GB agar tidak gagal di tengah proses.
- ISO Ubuntu Server asli, misalnya:
  - `ubuntu-24.04.5-live-server-amd64.iso`
  - `ubuntu-26.04.1-live-server-amd64.iso`
- Tidak perlu Python, tidak perlu WSL, tidak perlu Linux.
- Tidak perlu internet saat build (xorriso sudah disertakan di `tools\xorriso`).

`xorriso` sudah disertakan di folder `tools\xorriso` (versi 1.5.6, 64-bit).

> **Penting:** jangan memisahkan `UbuntuAutoinstallBuilder.ps1` dari folder
> `tools\`. Aplikasi mencari xorriso relatif terhadap lokasi skrip; kalau folder
> `tools` tidak ada, build berhenti dengan pesan
> `xorriso tidak ditemukan: ... Pastikan folder 'tools' ikut tersalin.`

> **Antivirus / SmartScreen:** `xorriso.exe` adalah biner pihak ketiga yang
> tidak bertanda tangan, kadang dikarantina. Jika build gagal dengan pesan
> xorriso hilang padahal file ada, kecualikan folder aplikasi di antivirus.

---

## 2. Menjalankan

Klik dua kali **`Jalankan.bat`**.

Jika aplikasi tidak muncul, jalankan **`Jalankan-Debug.bat`** supaya pesan error
terlihat di jendela konsol.

---

## 3. Mengisi data

### Tab "Konfigurasi"

| Isian | Keterangan |
|---|---|
| **ISO sumber** | Pilih ISO Ubuntu Server asli. Nama versi terdeteksi muncul di judul grup. |
| **ISO hasil** | Otomatis diisi (`...-autoinstall.iso`), bisa diganti. |
| **Nama lengkap** | Nama tampilan akun (boleh berspasi). |
| **Hostname** | Nama komputer di jaringan, contoh `home-server`. Huruf kecil, angka, minus. |
| **Username** | Akun yang dibuat, contoh `ugik`. |
| **Password** | Password akun (disimpan sebagai hash SHA-512, bukan teks biasa). |
| **Konfirmasi password** | Harus sama. |
| **Locale** | Contoh `en_US.UTF-8`, `id_ID.UTF-8`. |
| **Keyboard** | Contoh `us`. |
| **Timezone** | Contoh `Asia/Jakarta`. |
| **Layout disk** | `direct` (paling sederhana), `lvm`, atau `zfs`. |
| **Disk target** | `largest` = otomatis pilih disk terbesar (USB installer tidak akan terpilih), atau path seperti `/dev/nvme0n1`. |
| **Setelah instalasi** | `poweroff` (matikan, disarankan) atau `reboot`. |

> **Catatan disk:** `largest` adalah pilihan aman untuk mini PC dengan satu
> disk. Jika mesin punya beberapa disk dan Anda ingin menentukannya, isi path
> disk (lihat daftar disk dengan `lsblk` di Live session).

### Tab "Lanjutan"

| Opsi | Keterangan |
|---|---|
| **Pasang OpenSSH server** | Menginstal `openssh-server` dan mengaktifkannya. |
| **Izinkan login SSH dengan password** | Menulis `PasswordAuthentication yes` di sistem hasil instalasi. |
| **Workaround netplan di live session** | Lihat bagian 6. Biarkan tercentang. |
| **Verifikasi ISO hasil** | Memeriksa layout boot (BIOS+UEFI), partisi ESP, dan isi file setelah build. |
| **Paket tambahan** | Satu paket per baris, contoh `curl`, `htop`. |
| **late-commands / early-commands tambahan** | Perintah shell tambahan bila perlu (opsional). |

Klik **Buat ISO**. Proses berjalan beberapa menit (menyalin ~3 GB). Setelah
selesai muncul ringkasan, SHA256, dan tombol buka folder hasil.

**Simpan profil / Muat profil** menyimpan semua isian (kecuali password) ke file
JSON supaya bisa dipakai ulang.

---

## 4. Memakai ISO hasil

1. Flash ISO hasil ke USB:
   - **Rufus** → pilih ISO → mode **DD** (bukan ISO mode), atau
   - **balenaEtcher**, atau
   - **Ventoy** (copy file ISO apa adanya).
2. Colok USB ke mesin target, nyalakan, pilih boot dari USB.
3. Jangan sentuh apa pun. Installer berjalan otomatis:
   partisi → salin sistem → pasang bootloader → konfigurasi SSH → selesai.
4. Di akhir, mesin **mati sendiri** (`poweroff`). Cabut USB, nyalakan lagi.
5. Cari IP mesin di daftar klien DHCP router (hostname sesuai isian), lalu:
   `ssh username@IP`.

> Password lemah tetap diterima installer. Segera ganti setelah login dengan
> perintah `passwd`.

---

## 5. Cara kerja (singkat)

1. Membaca `/boot/grub/grub.cfg` dan `/boot/grub/loopback.cfg` dari ISO sumber.
2. Menambahkan parameter kernel `autoinstall` pada setiap entri `linux
   /casper/vmlinuz` (dan memperpendek timeout menu boot menjadi 10 detik).
3. Membuat `/autoinstall.yaml` dari isian Anda (akun, SSH, storage, dll).
4. Menyusun ISO baru dengan `xorriso`, dengan **mereproduksi layout boot ISO
   sumber** (`-report_system_area cmd`): MBR/GRUB2, GPT, El Torito BIOS + UEFI,
   dan partisi ESP. Karena resepnya diambil dari ISO sumber, ISO 22.04/24.04/26.04
   tetap bootable di BIOS maupun UEFI tanpa penyesuaian khusus.

Hasil akhirnya adalah USB hybrid yang bisa boot di mode BIOS lama maupun UEFI.

---

## 6. Workaround netplan (kenapa perlu?)

Di live session installer, `netplan apply` kadang gagal dengan
`Call failed: Connection timed out` (masalah D-Bus ke `systemd-networkd`,
sering terjadi di VM/QEMU). Dalam mode autoinstall, kegagalan itu **membatalkan
seluruh instalasi**.

Opsi **Workaround netplan** menambahkan `early-commands` yang mengganti
`/usr/sbin/netplan` di **live session** dengan skrip no-op. Ini tidak
memengaruhi sistem yang terpasang: konfigurasi netplan target tetap ditulis
subiquity dari model instalasi, dan sudah terbukti mendapat DHCP normal.

Jika Anda ingin konfigurasi yang benar-benar default, hilangkan centang opsi ini.

---

## 7. Mode baris perintah (opsional)

```powershell
cd C:\path\ke\AutoinstallBuilder
powershell -NoProfile -ExecutionPolicy Bypass -File .\UbuntuAutoinstallBuilder.ps1 -Cli `
  -Source "D:\ubuntu-24.04.5-live-server-amd64.iso" `
  -Output "D:\ubuntu-24.04.5-autoinstall.iso" `
  -Hostname home-server -Username ugik -Realname "Ugik" -Password "rahasia123" `
  -Timezone Asia/Jakarta -Locale en_US.UTF-8 -Keyboard us `
  -StorageLayout direct -Disk largest -Shutdown poweroff `
  -Packages "curl,htop"
```

Opsi lain: `-NoSsh`, `-NoNetplanFix`, `-NoVerify`, `-NoSsh` dsb.

---

## 8. Jika ada masalah

| Gejala | Penyebab / solusi |
|---|---|
| Aplikasi tidak muncul | Jalankan `Jalankan-Debug.bat`; biasanya ExecutionPolicy. |
| "ISO sumber tidak memiliki /boot/grub/grub.cfg" | Bukan ISO Ubuntu Server (mungkin Desktop atau ISO rusak). |
| Build gagal, log menyebut xorriso | Pastikan folder `tools\xorriso` tidak terpisah dari skrip; cek ruang disk. |
| Instalasi berhenti di prompt/akhir | Cek layar (bila ada) atau log; penyebab umum: disk target tidak cocok, atau `netplan apply` tanpa workaround. |
| Mesin tidak boot dari USB | Flash ulang dengan Rufus mode **DD**; pastikan Secure Boot tidak menghalangi (ISO Ubuntu ditandatangani, umumnya aman). |
| SSH tidak bisa login | Pastikan opsi SSH tercentang; cek `/etc/ssh/sshd_config.d/99-autoinstall.conf` di sistem hasil. |
| Skrip ditolak walau sudah `-ExecutionPolicy Bypass` | Komputer memakai kebijakan GPO/AppLocker yang mematikan skrip. Perlu izin admin. |
| `xorriso.exe` hilang / diblokir setelah extract ZIP | File dari internet ditandai Windows. Klik kanan ZIP → Properties → **Unblock**, lalu extract ulang; atau pakai `git clone`. |
| xorriso tidak bisa jalan sama sekali | Pastikan Windows 64-bit; biner yang disertakan adalah 64-bit. |

---

## 9. Struktur folder

```
AutoinstallBuilder\
├─ Jalankan.bat                  launcher (tanpa jendela hitam)
├─ Jalankan-Debug.bat            launcher dengan konsol untuk melihat error
├─ UbuntuAutoinstallBuilder.ps1  aplikasi (GUI + CLI)
├─ tools\xorriso\               xorriso 1.5.6 (sudah disertakan)
└─ profiles\                    profil tersimpan (dibuat saat Simpan Profil)
```

---

## 10. Catatan keamanan

- Password tidak pernah disimpan dalam bentuk teks di ISO; hanya hash SHA-512
  (`$6$...`). Namun password tetap tersimpan plaintext di memori selama proses
  build dan di profil bila Anda mengetiknya (profil tidak menyimpan password).
- Password lemah (mis. `1234`) tetap diterima. Gunakan hanya di jaringan
  terpercaya dan segera ganti setelah instalasi.
- Server hasil instalasi memakai DHCP dan mengizinkan login SSH password sesuai
  pilihan Anda. Sesuaikan firewall/router bila perlu.

---

## 11. Memakai di komputer lain (clone dari GitHub)

Repo: `https://github.com/ugikhariyanto/autoinstallubuntuserver`

```bat
git clone https://github.com/ugikhariyanto/autoinstallubuntuserver.git
cd autoinstallubuntuserver\AutoinstallBuilder
Jalankan.bat
```

Hasil clone berisi 23 file (±9,8 MB) termasuk `tools\xorriso` lengkap dengan
DLL-nya, jadi tidak ada unduhan tambahan saat build. Tidak ada path absolut
komputer pembuat yang tertanam di skrip; semua path diambil dari dialog.

### Yang sudah diuji dari hasil clone

| Bagian | Status |
|---|---|
| xorriso bawaan repo berjalan | OK (GNU xorriso 1.5.6, 64-bit) |
| Skrip di-parse PowerShell | OK |
| Hash password SHA-512 terhadap vektor resmi | OK |
| Baca ISO 24.04 + ekstrak `grub.cfg` | OK |
| Patch parameter `autoinstall` | OK |
| Resep boot 24.04 (20 baris / 61 token) | OK, tanpa error "not a known command" |
| GUI terbentuk (3 tab) | OK |

### Kondisi yang harus dipenuhi

1. Windows 10/11 64-bit, PowerShell 5.1 (bawaan).
2. Ruang disk ±8 GB untuk ISO 3,8 GB.
3. ISO Ubuntu Server asli tersedia sendiri (tidak ikut repo karena `*.iso`
   di-`gitignore`).
4. Folder `tools\` tetap satu paket dengan skrip.

### Yang bisa menggagalkan (bukan bug aplikasi)

| Risiko | Gejala | Solusi |
|---|---|---|
| Antivirus / SmartScreen | `xorriso.exe` dikarantina | Kecualikan folder aplikasi, atau izinkan file |
| Unduh sebagai ZIP | File diblokir Windows | Klik kanan ZIP → Properties → **Unblock**, lalu extract |
| GPO/AppLocker kantor | Skrip PowerShell ditolak | Minta admin mengizinkan eksekusi skrip |
| Windows 32-bit | xorriso tidak jalan | Gunakan Windows 64-bit |
| Disk hampir penuh | Build gagal saat menulis ISO (`xorriso` kehabisan ruang) | Sediakan ±8 GB kosong |
| Clone lama (riwayat sudah ditulis ulang) | `git pull` bentrok | `git fetch origin && git reset --hard origin/main` |

### Kalau terjadi error

Jalankan `Jalankan-Debug.bat`, lalu lihat tab **Log**. Pesan errornya spesifik
(nama file, path, atau perintah xorriso yang ditolak), sehingga mudah dilacak.
