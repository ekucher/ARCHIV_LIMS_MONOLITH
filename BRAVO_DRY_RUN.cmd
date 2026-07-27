@echo off
setlocal
set "BRAVO_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%BRAVO_POWERSHELL%" (
    echo ERROR: Windows PowerShell not found: %BRAVO_POWERSHELL%
    exit /b 9009
)
"%BRAVO_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BRAVO_DRY_RUN.ps1" %*
set "BRAVO_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %BRAVO_EXIT_CODE%
