@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-ReleaseNotes.ps1" %*
