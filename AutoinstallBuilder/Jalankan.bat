@echo off
rem ===========================================================================
rem  Launcher Ubuntu Autoinstall ISO Builder (tanpa jendela hitam).
rem  Jika aplikasi tidak muncul, pakai Jalankan-Debug.bat untuk melihat error.
rem ===========================================================================
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0UbuntuAutoinstallBuilder.ps1"
