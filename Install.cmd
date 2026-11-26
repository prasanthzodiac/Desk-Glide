@echo off
rem Starts DeskGlide now and at every login (one Startup shortcut, no admin needed).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DeskGlide.ps1" -Install
if errorlevel 1 pause
