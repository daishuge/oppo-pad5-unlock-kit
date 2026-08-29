@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "SCRIPT=%~dp0Check-OPPOPad5.ps1"
where pwsh.exe >nul 2>nul
if errorlevel 1 goto windows_powershell

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RESULT=%ERRORLEVEL%"
goto finish

:windows_powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RESULT=%ERRORLEVEL%"

:finish
if "%~1"=="" if not "%OPPO_UNLOCK_NO_PAUSE%"=="1" pause
exit /b %RESULT%
