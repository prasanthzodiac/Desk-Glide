@echo off
rem Stops DeskGlide, unmutes any app it muted, removes its Startup shortcut and its app folder in %LOCALAPPDATA%\DeskGlide.
rem Settings stay in %APPDATA%\DeskGlide.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DeskGlide.ps1" -Uninstall
if errorlevel 1 pause
