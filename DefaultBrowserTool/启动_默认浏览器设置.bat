@echo off
chcp 65001 >nul
title 绿色版浏览器 默认浏览器设置工具
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SetDefaultBrowser.ps1"
if %errorlevel% neq 0 (
  echo.
  echo 脚本执行出现异常，请查看上方错误信息。
  pause
)
