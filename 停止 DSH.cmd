@echo off
chcp 65001 >nul
title Stop DSH
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-launcher.ps1" -Stop
if errorlevel 1 (
  echo.
  echo [!] Stop failed. Press any key to close.
  pause >nul
)
