[CmdletBinding()]
param(
    [string]$ConfigPath
)

$helperLoggingPath = Join-Path $PSScriptRoot "BRAVO_HELPER_LOGGING.ps1"
. $helperLoggingPath
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

$ErrorActionPreference = "Stop"
$root = if ($PSCommandPath) {
    Split-Path -Path $PSCommandPath -Parent
} else {
    [Environment]::CurrentDirectory
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root "BRAVO.config"
}
$script:failures = New-Object System.Collections.ArrayList

function Test-BRAVOCondition {
    param(
        [bool]$Condition,
        [string]$Name,
        [string]$Failure
    )
    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] ${Name}: $Failure" -ForegroundColor Red
        [void]$script:failures.Add("$Name — $Failure")
    }
}

try {
    Write-Host "BRAVO STATIC SELF-TEST" -ForegroundColor Cyan
    $powerShellFiles = @(Get-ChildItem -LiteralPath $root -Filter "*.ps1" -File)
    foreach ($file in $powerShellFiles) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$errors
        )
        Test-BRAVOCondition `
            -Condition ($errors.Count -eq 0) `
            -Name "Parser/$($file.Name)" `
            -Failure (($errors | ForEach-Object { $_.Message }) -join " | ")
    }

    $helperEntryPoints = @(
        "BRAVO_SETUP.ps1",
        "BRAVO_DRY_RUN.ps1",
        "BRAVO_CREDENTIALS_SETUP.ps1",
        "BRAVO_TASKS_INSTALL.ps1",
        "BRAVO_TASKS_UNINSTALL.ps1",
        "BRAVO_TASKS_DIAGNOSE.ps1",
        "BRAVO_SELF_TEST.ps1"
    )
    foreach ($fileName in $helperEntryPoints) {
        $helperText = [IO.File]::ReadAllText(
            (Join-Path $root $fileName),
            [Text.Encoding]::UTF8
        )
        Test-BRAVOCondition `
            -Condition (
                $helperText.Contains("Start-BRAVOHelperLog") -and
                $helperText.Contains("Complete-BRAVOHelperLog")
            ) `
            -Name "HelperLogging/$fileName" `
            -Failure "допоміжний скрипт не підключає повний цикл журналювання"
    }

    . (Join-Path $root "BRAVO_COMPATIBILITY.ps1")
    Test-BRAVOCondition `
        -Condition (Test-BRAVOAccountIdentityEquivalent `
            -ExpectedAccount "SYSTEM" `
            -ActualAccount "S-1-5-18") `
        -Name "Scheduler/SystemSidEquivalent" `
        -Failure "SYSTEM повинен відповідати мовно-незалежному SID S-1-5-18"
    $localizedSystemAccount = (
        New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
    ).Translate([Security.Principal.NTAccount]).Value
    Test-BRAVOCondition `
        -Condition (Test-BRAVOAccountIdentityEquivalent `
            -ExpectedAccount "SYSTEM" `
            -ActualAccount $localizedSystemAccount) `
        -Name "Scheduler/LocalizedSystemEquivalent" `
        -Failure "SYSTEM не розпізнано через локалізоване ім'я '$localizedSystemAccount'"
    Test-BRAVOCondition `
        -Condition (-not (Test-BRAVOAccountIdentityEquivalent `
            -ExpectedAccount "SYSTEM" `
            -ActualAccount "S-1-5-20")) `
        -Name "Scheduler/SystemSidMismatch" `
        -Failure "SYSTEM не повинен збігатися з NETWORK SERVICE"

    $resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $resolvedConfig -Parent
    $configText = [IO.File]::ReadAllText($resolvedConfig, [Text.Encoding]::UTF8)
    & ([scriptblock]::Create($configText)) -ConfigRoot $configRoot

    Test-BRAVOCondition `
        -Condition ([string]$ScriptVersion -eq "4.0.0") `
        -Name "Version/BRAVO_ARCHIV" `
        -Failure "очікується 4.0.0, отримано '$ScriptVersion'"
    Test-BRAVOCondition `
        -Condition (-not ([string]$archiveParams -match '(?i)(^|\s)-ssw(\s|$)')) `
        -Name "BackupConsistency/NoSSW" `
        -Failure "щоденний backup не повинен дозволяти читання відкритих файлів"
    Test-BRAVOCondition `
        -Condition ([bool]$maintenanceSettings.Services.QuiesceForBackup) `
        -Name "BackupConsistency/QuiesceServices" `
        -Failure "QuiesceForBackup має бути увімкнено"
    Test-BRAVOCondition `
        -Condition ([int]$schedulerSettings.OperationLockWaitMinutes -gt 0) `
        -Name "Scheduler/OperationLockWait" `
        -Failure "очікування спільного lock має бути більше нуля"
    Test-BRAVOCondition `
        -Condition ([bool]$schedulerSettings.RequireProtectedRuntime) `
        -Name "Scheduler/ProtectedRuntime" `
        -Failure "RequireProtectedRuntime має бути увімкнено"

    foreach ($fileName in @(
            "BRAVO_ARCHIV.ps1",
            "BRAVO_MAINTENANCE.ps1",
            "BRAVO_ARCHIV_HEALTH.ps1"
        )) {
        $text = [IO.File]::ReadAllText(
            (Join-Path $root $fileName),
            [Text.Encoding]::UTF8
        )
        Test-BRAVOCondition `
            -Condition ($text.Contains("BRAVO_OPERATION.lock")) `
            -Name "SharedLock/$fileName" `
            -Failure "скрипт не використовує BRAVO_OPERATION.lock"
    }

    $taskInstaller = Join-Path $root "BRAVO_TASKS_INSTALL.ps1"
    & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $taskInstaller `
        -ConfigPath $resolvedConfig `
        -ValidateOnly
    Test-BRAVOCondition `
        -Condition ($LASTEXITCODE -eq 0) `
        -Name "Scheduler/ValidateOnly" `
        -Failure "BRAVO_TASKS_INSTALL повернув код $LASTEXITCODE"
} catch {
    [void]$script:failures.Add($_.Exception.Message)
    Write-Host "[FAIL] Fatal: $($_.Exception.Message)" -ForegroundColor Red
}

if ($script:failures.Count -gt 0) {
    Write-Host "SELF-TEST FAILED: $($script:failures.Count)" -ForegroundColor Red
    Complete-BRAVOHelperLog -ExitCode 1
}
Write-Host "SELF-TEST PASSED" -ForegroundColor Green
Complete-BRAVOHelperLog -ExitCode 0
