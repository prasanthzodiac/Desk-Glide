@echo off
rem Stops DeskGlide, unmutes any app it muted and removes its Startup shortcut. Settings stay in %APPDATA%\DeskGlide.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DeskGlide.ps1" -Uninstall
if errorlevel 1 pause
