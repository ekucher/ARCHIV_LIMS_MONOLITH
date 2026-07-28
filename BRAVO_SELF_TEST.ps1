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
    $insecureWebhookRejected = $false
    try {
        Send-BRAVOWebhookNotification `
            -Provider "slack" `
            -WebhookUrl "http://127.0.0.1/test" `
            -Message "test"
    } catch {
        $insecureWebhookRejected = $_.Exception.Message -match "HTTPS"
    }
    Test-BRAVOCondition `
        -Condition $insecureWebhookRejected `
        -Name "Notifications/RejectInsecureWebhook" `
        -Failure "спільний webhook-клієнт повинен відхиляти HTTP до мережевого запиту"
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
        -Condition ([string]$ScriptVersion -eq "4.1.0") `
        -Name "Version/BRAVO_ARCHIV" `
        -Failure "очікується 4.1.0, отримано '$ScriptVersion'"
    Test-BRAVOCondition `
        -Condition ([string]$archiveParams -match '(?i)(^|\s)-ssw(\s|$)') `
        -Name "BackupAvailability/AllowOpenFiles" `
        -Failure "backup без зупинки служб має дозволяти читання відкритих файлів"
    $archiveScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_ARCHIV.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Write-SevenZipFailureDiagnostics") -and
            $archiveScriptText.Contains('Operation "Дiагностика 7-Zip create"')
        ) `
        -Name "BackupDiagnostics/SevenZipFailureOutput" `
        -Failure "помилка створення 7-Zip має записувати діагностичний вивід у лог"
    Test-BRAVOCondition `
        -Condition (
            -not $archiveScriptText.Contains("Send-BRAVOArchiveInactiveServiceWarning")
        ) `
        -Name "Services/ArchiveDoesNotRequireRunningServices" `
        -Failure "архівація не повинна вважати штатно зупинені служби помилкою"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText -notmatch '(?m)^\s*Stop-Service\b' -and
            $archiveScriptText -notmatch '(?m)^\s*Start-Service\b' -and
            -not $archiveScriptText.Contains("Stop-BRAVOArchiveSourceServices") -and
            -not $archiveScriptText.Contains("Start-BRAVOArchiveSourceServices")
        ) `
        -Name "Services/ArchiveReadOnly" `
        -Failure "BRAVO_ARCHIV не повинен зупиняти або запускати Windows-служби"
    $maintenanceScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_MAINTENANCE.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains('$temporaryMarkerFile') -and
            $maintenanceScriptText.Contains('System.Text.UTF8Encoding($false)') -and
            $maintenanceScriptText.Contains('Move-Item')
        ) `
        -Name "Maintenance/AtomicUtf8RestoreMarker" `
        -Failure "маркер успішної реставрації має атомарно записуватися у UTF-8"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains("Send-InactiveServiceWarning") -and
            $maintenanceScriptText.Contains("СЛУЖБИ НЕ ЗАПУЩЕНІ ПЕРЕД MAINTENANCE")
        ) `
        -Name "Notifications/MaintenanceInactiveServices" `
        -Failure "maintenance має негайно сповіщати про початково зупинені служби"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains("RunMissedRestoreOnly") -and
            $maintenanceScriptText.Contains("BRAVO_RESTORE_STATE.json") -and
            $maintenanceScriptText.Contains("Get-BRAVORestoreScheduledOccurrence") -and
            $maintenanceScriptText.Contains('$runningServices')
        ) `
        -Name "Maintenance/MissedRestoreRecoveryState" `
        -Failure "recovery має зберігати state та перевіряти всі запущені служби до зупинки"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Invoke-BRAVOEmbeddedHealth') -and
            $archiveScriptText.Contains('[switch]$HealthCheckOnly') -and
            $archiveScriptText.Contains('[switch]$SkipIfBackupTaskRunning') -and
            $archiveScriptText.Contains('SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning') -and
            $schedulerSettings.Health.ScriptPath -eq (Join-Path $root 'BRAVO_ARCHIV.ps1')
        ) `
        -Name "Health/EmbeddedArchiveMode" `
        -Failure "health-режим має бути вбудований у BRAVO_ARCHIV.ps1 і використовуватись планувальником"
    Test-BRAVOCondition `
        -Condition (
            [bool]$backupMonitoring.CheckManagedServices -and
            $archiveScriptText.Contains("Get-ManagedServiceHealthIssues") -and
            $archiveScriptText.Contains('Kind = "Service"')
        ) `
        -Name "Notifications/HealthInactiveServices" `
        -Failure "health-check має виявляти встановлені не-Disabled служби поза operation lock"
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
            "BRAVO_MAINTENANCE.ps1"
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
    $taskInstallerText = [IO.File]::ReadAllText($taskInstaller, [Text.Encoding]::UTF8)
    Test-BRAVOCondition `
        -Condition (
            $taskInstallerText.Contains("TASK_TRIGGER_BOOT") -and
            $taskInstallerText.Contains("schedulerSettings.Recovery") -and
            $taskInstallerText.Contains("RetryEveryMinutes")
        ) `
        -Name "Scheduler/MissedRestoreStartupTask" `
        -Failure "для пропущеної реставрації потрібне startup-завдання"
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
