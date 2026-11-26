@echo off
rem Copies DeskGlide to %LOCALAPPDATA%\DeskGlide\app and starts it from there, now and at every login (no admin needed).
rem Unblock-File first: Windows marks downloaded files and would ask before running them.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0.' -File | Unblock-File"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DeskGlide.ps1" -Install
if errorlevel 1 pause
