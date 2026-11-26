@echo off
rem Stops DeskGlide and its Deskflow, unmutes any app it muted, removes its Startup shortcut and %LOCALAPPDATA%\DeskGlide.
rem Settings stay in %APPDATA%\DeskGlide.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DeskGlide.ps1" -Uninstall
if errorlevel 1 pause
