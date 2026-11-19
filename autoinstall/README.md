# Ubuntu Server 26.04.1 LTS — instalasi otomatis (autoinstall) untuk mini PC headless

Folder ini berisi konfigurasi + skrip untuk membuat ulang ISO instalasi Ubuntu Server
yang **langsung menginstal sendiri tanpa monitor/keyboard**.

```
ubuntuserver\
├─ ubuntu-26.04.1-live-server-amd64.iso              <- ISO asli (jangan diubah)
├─ ubuntu-26.04.1-live-server-amd64-autoinstall.iso  <- ISO HASIL (dipakai untuk USB)
└─ autoinstall\
   ├─ autoinstall.yaml      <- konfigurasi instalasi (user, hostname, disk, SSH, ...)
   ├─ hash-password.py      <- pembuat hash password SHA-512
   ├─ build-iso.ps1         <- skrip rebuild ISO setelah autoinstall.yaml diubah
   ├─ boot\grub\grub.cfg    <- grub.cfg ISO yang sudah ditambah parameter "autoinstall"
   ├─ boot\grub\loopback.cfg<- sama, untuk boot lewat Ventoy/GRUB
   └─ tools\xorriso\        <- xorriso (dipakai build-iso.ps1)
```

Ringkasan yang ditanam di ISO:

| Item | Nilai |
|---|---|
| Username | `ugik` |
| Password | `1234` (hash SHA-512) — **ganti setelah instalasi!** |
| Hostname | `home-server` |
| SSH | aktif (`openssh-server`), login password diizinkan |
| Jaringan | DHCP (default netplan, interface `en*`/`eth*`) |
| Disk | **seluruh disk terbesar dihapus**, skema `direct`: GPT + ESP + ext4 `/` |
| Locale / keyboard / TZ | `en_US.UTF-8` / `us` / `Asia/Jakarta` |
| Setelah selesai | **poweroff** (bukan reboot) supaya tidak menginstal ulang |

---

## 1. Tulis ISO ke USB

Gunakan ISO **hasil** (`...-autoinstall.iso`, 2.7 GB).

* **balenaEtcher** — pilih ISO → Flash. (paling aman, selalu menulis raw/DD)
* **Rufus** — pilih ISO, lalu saat muncul pilihan, pilih **"Write in DD Image mode"**
  (jangan ISO mode). ISO ini hybrid: BIOS + UEFI sama-sama bisa.
* **Ventoy** — cukup salin ISO ke partisi Ventoy, pilih dari menu Ventoy.
  (file `loopback.cfg` juga sudah dipatch, jadi autoinstall tetap jalan)

## 2. Proses instalasi (tanpa monitor)

1. Colok USB ke mini PC, nyalakan, pastikan boot dari USB (BIOS/UEFI).
2. Menu GRUB muncul 5 detik → entry **"Autoinstall Ubuntu Server 26.04.1 LTS"**
   otomatis dipilih.
3. Instalasi berjalan sendiri. Lama ±5–15 menit (tergantung internet & disk).
4. Selesai → mesin **mati sendiri**.
5. Cabut USB, nyalakan lagi. Sistem sudah siap dan SSH aktif.

> Jika mini PC punya Secure Boot: ISO Ubuntu ini sudah signed, jadi tetap bisa boot.

## 3. Cari IP mini PC

Karena DHCP, IP didapat otomatis. Cara menemukannya:

* Buka halaman admin router → daftar **DHCP clients** → cari hostname `home-server`.
* Dari Windows: `arp -a` (setelah ping broadcast), atau
  `nmap -sn 192.168.1.0/24` (kalau ada nmap) lalu cari yang MAC-nya baru.
* Kalau punya kabel serial/HDMI, console login: `ugik` / `1234`.

Lalu:

```powershell
ssh ugik@<ip-mini-pc>
```

## 4. Segera setelah instalasi (disarankan)

```bash
# 1. Ganti password lemah
passwd

# 2. Update sistem
sudo apt update && sudo apt full-upgrade -y

# 3. (opsional) akses via nama host tanpa tahu IP
sudo apt install -y avahi-daemon
# setelah itu bisa: ssh ugik@home-server.local

# 4. (opsional) firewall
sudo ufw allow OpenSSH && sudo ufw enable
```

Kalau punya SSH key, lebih aman:

```powershell
# di Windows
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh ugik@<ip> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

---

## 5. Mengubah konfigurasi lalu rebuild ISO

Semua pengaturan ada di `autoinstall\autoinstall.yaml`. Contoh yang sering diubah:

```yaml
identity:
  username: ugik
  hostname: home-server
  password: "$6$..."        # lihat cara ganti password di bawah

ssh:
  install-server: true
  allow-pw: true

storage:
  layout:
    name: direct            # atau "lvm"
    match:
      size: largest         # atau serial: XYZ, path: /dev/nvme0n1, dll
```

Rebuild:

```powershell
cd autoinstall
.\build-iso.ps1
```

### Ganti password

```powershell
cd autoinstall
python hash-password.py
```

Tempel hasil `$6$...` ke `identity.password` di `autoinstall.yaml`, lalu `.\build-iso.ps1`.

### Tambah paket / perintah pasca-instalasi

Tambahkan di `autoinstall.yaml`:

```yaml
packages:
  - curl
  - htop
  - vim
```

```yaml
late-commands:
  - curtin in-target -- systemctl enable --now some-service
```

> Catatan: `packages:` butuh mirror apt yang bisa diakses **selama instalasi**.
> Kalau mini PC tanpa internet, cukup andalkan paket bawaan ISO.

---

## 6. Kalau instalasi gagal

Installer menulis log ke `/var/log/installer/` di sistem live. Karena headless:

* `autoinstall.yaml` sudah menyiapkan `error-commands` yang menyalin log ke disk target
  (kalau `/target` sempat ter-mount): `/var/log/installer-logs.tar.gz`.
* Cara termudah saat debug: colok monitor sekali ke mini PC.
* Baris kernel `console=ttyS0,115200n8` **sengaja tidak dipakai**. Kalau mini PC punya
  port serial, tambahkan sendiri di `boot\grub\grub.cfg` lalu rebuild.
* Penyebab umum: disk tidak terdeteksi (mode SATA/RAID di BIOS), tidak ada internet
  saat `packages:`/`updates: security`, atau `autoinstall.yaml` tidak valid
  (cek indentasi YAML).

### Catatan: `netplan apply` gagal di live session

Pada sebagian lingkungan (mis. QEMU), `netplan apply` di sistem live bisa gagal dengan
`Call failed: Connection timed out` (D-Bus ke `systemd-networkd`). Dalam mode
autoinstall, Subiquity menganggap kegagalan itu **fatal** dan berhenti di shell —
padahal jaringannya sendiri sudah jalan (DHCP dari casper).

Karena itu `autoinstall.yaml` punya `early-commands` yang menonaktifkan `netplan`
**hanya di live session**:

```yaml
early-commands:
  - bash -c 'if [ -x /usr/sbin/netplan ]; then mv /usr/sbin/netplan /usr/sbin/netplan.real; ... fi'
```

Yang perlu diketahui:

* Ini tidak menyentuh `/target`; netplan asli tetap terpasang di sistem hasil instalasi.
* Konfigurasi jaringan sistem hasil instalasi tetap ditulis dari model Subiquity
  (`/etc/netplan/00-installer-config.yaml`, DHCP) — bukan dari hasil `netplan apply`.
* Kalau Anda ingin mengembalikan perilaku asli, hapus blok `early-commands` tersebut.

## 7. Catatan teknis

* ISO asli: Ubuntu Server 26.04.1 LTS amd64, boot record
  `El Torito + MBR protective-msdos-label + grub2-mbr + GPT` (hybrid BIOS/UEFI).
* Rebuild memakai `xorriso` dengan resep layout yang dilaporkan sendiri oleh ISO asli
  (`-report_system_area cmd`), sehingga MBR, GPT, ESP (appended partition), dan entri
  El Torito BIOS+UEFI identik dengan aslinya.
* Perubahan di dalam ISO:
  * `/autoinstall.yaml` (baru) — dikenali Subiquity sebagai autoinstall dari media instalasi.
  * `/boot/grub/grub.cfg` — ditambah parameter kernel `autoinstall`.
  * `/boot/grub/loopback.cfg` — idem (untuk Ventoy).
* Cmdline kernel: `autoinstall` saja, tanpa opsi console tambahan, supaya installer
  tetap memakai layar/VGA (tty1) sebagai console utama seperti ISO aslinya.
