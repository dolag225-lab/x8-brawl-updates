@echo off
rem X8 Brawl: download the latest patch (only the changed files). Safe to run any time the game is closed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"

