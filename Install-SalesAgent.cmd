@echo off
rem Sales Agent - double-click to install or update. Runs Install-SalesAgent.ps1 with PowerShell 7.
setlocal
cd /d "%~dp0"
where pwsh >nul 2>nul
if errorlevel 1 (
  if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PATH=%ProgramFiles%\PowerShell\7;%PATH%"
  ) else (
    echo PowerShell 7 is required to install Sales Agent.
    choice /C YN /M "Install PowerShell 7 now with winget"
    if errorlevel 2 goto :nopwsh
    winget install --id Microsoft.PowerShell -e --accept-package-agreements --accept-source-agreements
    set "PATH=%ProgramFiles%\PowerShell\7;%PATH%"
  )
)
where pwsh >nul 2>nul
if errorlevel 1 goto :nopwsh
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-SalesAgent.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%

:nopwsh
echo Install PowerShell 7 from https://aka.ms/powershell and run this file again.
pause
exit /b 1
