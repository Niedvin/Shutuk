@echo off
REM Double-clickable wrapper: -ExecutionPolicy Bypass is what lets a downloaded .ps1 run.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
endlocal
