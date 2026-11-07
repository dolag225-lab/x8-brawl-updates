@echo off
rem X8 Brawl launcher: quick update check (skipped after a few seconds if offline), then starts X8Brawl.exe.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" -Launch

