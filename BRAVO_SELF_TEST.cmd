@echo off
setlocal
set "BRAVO_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%BRAVO_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BRAVO_SELF_TEST.ps1" %*
set "BRAVO_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %BRAVO_EXIT_CODE%
