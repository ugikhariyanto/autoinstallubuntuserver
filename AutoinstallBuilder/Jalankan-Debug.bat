@echo off
rem ===========================================================================
rem  Launcher debug: jendela konsol tetap terbuka supaya pesan error terlihat.
rem ===========================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0UbuntuAutoinstallBuilder.ps1"
if errorlevel 1 pause
