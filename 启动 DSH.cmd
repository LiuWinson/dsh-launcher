@echo off
chcp 65001 >nul
title DSH Launcher
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-launcher.ps1" %*
if errorlevel 1 (
  echo.
  echo [!] Launcher failed. Press any key to close.
  pause >nul
)
