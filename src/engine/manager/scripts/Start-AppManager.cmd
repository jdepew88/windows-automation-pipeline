@echo off
rem Starts the Windows Deployment Builder Application Manager from this folder (no installation).
rem It runs as you, on this computer only (127.0.0.1); close its window to stop it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0AppManager.ps1" %*
