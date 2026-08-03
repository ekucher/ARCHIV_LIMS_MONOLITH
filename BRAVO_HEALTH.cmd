@echo off
setlocal
set "BRAVO_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%BRAVO_POWERSHELL%" (
    echo ERROR: Windows PowerShell not found: %BRAVO_POWERSHELL%
    exit /b 9009
)
"%BRAVO_POWERSHELL%" -NoLogo -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 3) { exit 3 }"
if errorlevel 1 (
    echo ERROR: BRAVO requires Windows PowerShell 3.0 or newer.
    echo On Windows 7 install Windows Management Framework 3.0 or newer; WMF 5.1 is recommended.
    exit /b 3
)
"%BRAVO_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BRAVO_HEALTH.ps1" %*
set "BRAVO_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %BRAVO_EXIT_CODE%
