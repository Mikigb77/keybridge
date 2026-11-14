@echo off
rem KeyBridge: give the Bluetooth adapter back to Windows.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\Stop-KeyBridge.ps1"
