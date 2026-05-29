@echo off
setlocal
set "TARGET=%~dp0scripts\start-launcher.ps1"
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -OpenBrowser %*
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -OpenBrowser %*
)
endlocal
