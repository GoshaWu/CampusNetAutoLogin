@echo off
title 自动登录校园网
set "SCRIPT=%~dp0CampusNetAutoLogin.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT%"
