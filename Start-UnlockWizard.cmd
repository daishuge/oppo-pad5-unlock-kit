@echo off
setlocal EnableExtensions DisableDelayedExpansion

echo ================================================================
echo  ADVANCED PREVIEW - PLAN ONLY
echo  This launcher never supplies destructive authorization for you.
echo  It does not automatically run adb, fastboot, or a partition write.
echo ================================================================

set "SCRIPT=%~dp0Start-OPPOPad5Unlock.ps1"
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
