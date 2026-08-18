@echo off
setlocal
title MDD Sim Gateway

rem Map a \\wsl to a temporary drive so CMD has a valid current directory.
pushd "%~dp0" >nul
if errorlevel 1 (
  echo Could not open the MDD scripts directory.
  pause
  exit /b 1
)
set "SCRIPT_DIR=%CD%"

echo Starting MDD Sim Gateway. Bilingual Chinese | English diagnostics follow.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\start-mdd.ps1" -OpenBrowser
set "RESULT=%ERRORLEVEL%"
popd

if not "%RESULT%"=="0" (
  echo.
  echo Startup failed. Review the diagnostics above, then press any key to close.
  pause >nul
)
exit /b %RESULT%
