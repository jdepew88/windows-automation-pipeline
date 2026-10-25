@echo off
rem Test stand-in for winget.exe (see FakeWinGet.ps1). Installs nothing.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FakeWinGet.ps1" %*
exit /b %ERRORLEVEL%
