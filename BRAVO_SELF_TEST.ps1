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

function New-BRAVOSelfTestRuntimeModule {
    param(
        [Parameter(Mandatory = $true)][string]$SourceText,
        [Parameter(Mandatory = $true)][string[]]$FunctionNames
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $SourceText,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw "не вдалося підготувати runtime-тести: $(
            ($errors | ForEach-Object { $_.Message }) -join ' | '
        )"
    }

    $definitions = @()
    foreach ($functionName in $FunctionNames) {
        $functionAst = @(
            $ast.FindAll(
                {
                    param($candidate)
                    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $candidate.Name -eq $functionName
                },
                $true
            )
        ) | Select-Object -First 1
        if ($null -eq $functionAst) {
            throw "функцію '$functionName' не знайдено для runtime-тесту"
        }
        $definitions += $functionAst.Extent.Text
    }

    return New-Module -ScriptBlock {
        param([string[]]$Definitions)
        foreach ($definition in $Definitions) {
            . ([scriptblock]::Create($definition))
        }
    } -ArgumentList (, $definitions)
}

try {
    Write-Host "BRAVO SELF-TEST (STATIC + RUNTIME)" -ForegroundColor Cyan
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

    $credentialSetupText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CREDENTIALS_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $credentialSetupText.Contains('-QuietConsole:$protectedWorkerMode') -and
            $credentialSetupText.Contains('if (-not $protectedWorkerMode)')
        ) `
        -Name "Credentials/SystemWorkerQuietConsole" `
        -Failure "SYSTEM worker Credential Manager не повинен виконувати Write-Host без консолі"

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

    $sevenZipRuntimeRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_7Z_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    $sevenZipCreateProcess = $null
    $sevenZipCreateCapture = $null
    $sevenZipRuntimePassed = $false
    $sevenZipRuntimeFailure = ""
    try {
        $sevenZipPath = Join-Path $root "Tools\7za.exe"
        if (-not (Test-Path -LiteralPath $sevenZipPath -PathType Leaf)) {
            throw "не знайдено Tools\7za.exe"
        }

        [void][IO.Directory]::CreateDirectory($sevenZipRuntimeRoot)
        $sevenZipInputPath = Join-Path $sevenZipRuntimeRoot "input.txt"
        $sevenZipArchivePath = Join-Path $sevenZipRuntimeRoot "archive.7z"
        $sevenZipTestPassword = "BRAVO-self-test-{0}" -f [guid]::NewGuid().ToString("N")
        [IO.File]::WriteAllText(
            $sevenZipInputPath,
            "BRAVO runtime test",
            [Text.Encoding]::UTF8
        )

        $sevenZipCreateInfo = New-Object Diagnostics.ProcessStartInfo
        $sevenZipCreateInfo.FileName = $sevenZipPath
        $sevenZipCreateInfo.Arguments = (
            "a -y -bb0 -p `"{0}`" `"{1}`"" -f
                $sevenZipArchivePath,
                $sevenZipInputPath
        )
        $sevenZipCreateInfo.RedirectStandardInput = $true
        $sevenZipCreateInfo.RedirectStandardOutput = $true
        $sevenZipCreateInfo.RedirectStandardError = $true
        $sevenZipCreateInfo.UseShellExecute = $false
        $sevenZipCreateInfo.CreateNoWindow = $true

        $sevenZipCreateProcess = New-Object Diagnostics.Process
        $sevenZipCreateProcess.StartInfo = $sevenZipCreateInfo
        $sevenZipCreateCapture = Start-BRAVOProcessOutputCapture `
            -Process $sevenZipCreateProcess
        $sevenZipCreateProcess.StandardInput.WriteLine($sevenZipTestPassword)
        $sevenZipCreateProcess.StandardInput.Close()
        $sevenZipCreateCompleted = $sevenZipCreateProcess.WaitForExit(30000)
        if (-not $sevenZipCreateCompleted) {
            $sevenZipCreateProcess.Kill()
            [void]$sevenZipCreateProcess.WaitForExit(5000)
        }
        [void](Complete-BRAVOProcessOutputCapture -Capture $sevenZipCreateCapture)
        $sevenZipCreateCapture = $null
        $sevenZipCreateExitCode = if ($sevenZipCreateProcess.HasExited) {
            [int]$sevenZipCreateProcess.ExitCode
        } else {
            $null
        }

        $sevenZipIntegrityResult = Invoke-BRAVOSevenZipIntegrityTest `
            -SevenZipPath $sevenZipPath `
            -ArchivePath $sevenZipArchivePath `
            -Password $sevenZipTestPassword `
            -TimeoutSeconds 30
        $sevenZipRuntimePassed = (
            $sevenZipCreateCompleted -and
            $sevenZipCreateExitCode -eq 0 -and
            $sevenZipIntegrityResult.Success -and
            -not $sevenZipCreateInfo.Arguments.Contains($sevenZipTestPassword)
        )
        if (-not $sevenZipRuntimePassed) {
            $sevenZipRuntimeFailure = (
                "create=$sevenZipCreateExitCode; " +
                "test=$($sevenZipIntegrityResult.ExitCode); " +
                "testError=$($sevenZipIntegrityResult.Error)"
            )
        }
    } catch {
        $sevenZipRuntimeFailure = $_.Exception.Message
    } finally {
        if ($null -ne $sevenZipCreateCapture) {
            try {
                [void](Complete-BRAVOProcessOutputCapture -Capture $sevenZipCreateCapture)
            } catch {}
        }
        if ($null -ne $sevenZipCreateProcess) {
            $sevenZipCreateProcess.Dispose()
        }
        if ([IO.Directory]::Exists($sevenZipRuntimeRoot)) {
            [IO.Directory]::Delete($sevenZipRuntimeRoot, $true)
        }
    }
    Test-BRAVOCondition `
        -Condition $sevenZipRuntimePassed `
        -Name "Runtime/SevenZipPasswordUsesStdin" `
        -Failure "створення/перевірка зашифрованого архіву через stdin не працює: $sevenZipRuntimeFailure"

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
        -Condition (
            -not [string]::IsNullOrWhiteSpace([string]$ScriptVersion) -and
            [string]$ScriptDate -match '^\d{4}-\d{2}-\d{2}$'
        ) `
        -Name "Version/BRAVO_ARCHIV" `
        -Failure "у BRAVO.config мають бути задані ScriptVersion і ScriptDate у форматі YYYY-MM-DD"
    Test-BRAVOCondition `
        -Condition ([string]$archiveParams -match '(?i)(^|\s)-ssw(\s|$)') `
        -Name "BackupAvailability/AllowOpenFiles" `
        -Failure "backup без зупинки служб має дозволяти читання відкритих файлів"
    $archiveScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_ARCHIV.ps1"),
        [Text.Encoding]::UTF8
    )
    $archiveRuntimeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $archiveScriptText `
        -FunctionNames @(
            "ConvertTo-NotificationLiteralText",
            "Split-DiscordNotificationText",
            "Test-BAZAPathBlockedByIncompatibleName",
            "Split-BAZAPendingFilesByCompatibility",
            "Get-BAZASynchronizationOutcome",
            "Get-BRAVOVSSSnapshotSourcePath",
            "Remove-BRAVOWinSCPSensitiveTemporaryScript",
            "Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts",
            "New-BRAVOWinSCPTemporaryScriptPath"
        )

    $literalSourceText = "Методика*виконання_вимірювань.pdf"
    $discordLiteralText = & $archiveRuntimeModule {
        param($Value)
        $script:NotificationProvider = "discord"
        ConvertTo-NotificationLiteralText -Text $Value
    } $literalSourceText
    $slackLiteralText = & $archiveRuntimeModule {
        param($Value)
        $script:NotificationProvider = "slack"
        ConvertTo-NotificationLiteralText -Text $Value
    } $literalSourceText
    Test-BRAVOCondition `
        -Condition (
            $discordLiteralText -eq "Методика\*виконання\_вимірювань.pdf" -and
            $slackLiteralText -eq $literalSourceText
        ) `
        -Name "Runtime/NotificationLiteralEscaping" `
        -Failure "Discord і Slack мають отримувати різне коректне екранування імені файла"

    $discordChunks = @(
        & $archiveRuntimeModule {
            param($Value)
            Split-DiscordNotificationText -Message $Value
        } (("_" * 1000) + "`r`n" + ("_" * 1598))
    )
    Test-BRAVOCondition `
        -Condition (
            $discordChunks.Count -gt 1 -and
            @($discordChunks | Where-Object { $_.Length -gt 1900 }).Count -eq 0
        ) `
        -Name "Runtime/DiscordLongMessageSplitting" `
        -Failure "кожна частина довгого Discord-повідомлення має бути не довшою за 1900 символів"

    $vssSourcePath = & $archiveRuntimeModule {
        Get-BRAVOVSSSnapshotSourcePath `
            -SourcePath "D:\LIMS\Model\*" `
            -DeviceObject "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy42"
    }
    Test-BRAVOCondition `
        -Condition (
            [string]$backupConsistency.Mode -eq "VSS" -and
            [string]$backupConsistency.SnapshotContext -eq "ClientAccessible" -and
            $vssSourcePath -eq "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy42\LIMS\Model\*"
        ) `
        -Name "Runtime/BackupUsesVSSSnapshotPath" `
        -Failure "щоденні архіви мають читатися з коректно побудованого VSS-шляху"

    $incompatibleIssue = [pscustomobject]@{
        Path = "C:\BAZA\несумісне-ім'я.pdf"
        IsDirectory = $false
    }
    $comparisonBefore = [pscustomobject]@{
        Success = $true
        PendingFiles = @(
            [pscustomobject]@{ Path = "C:\BAZA\звичайний.pdf" },
            [pscustomobject]@{ Path = $incompatibleIssue.Path }
        )
    }
    $comparisonAfter = [pscustomobject]@{
        Success = $true
        PendingFiles = @(
            [pscustomobject]@{ Path = $incompatibleIssue.Path }
        )
    }
    $degradedOutcome = & $archiveRuntimeModule {
        param($Before, $After, $Issue)
        Get-BAZASynchronizationOutcome `
            -WinSCPExitCode 0 `
            -ComparisonBefore $Before `
            -ComparisonAfter $After `
            -IncompatibleIssues @($Issue)
    } $comparisonBefore $comparisonAfter $incompatibleIssue
    Test-BRAVOCondition `
        -Condition (
            $degradedOutcome.IsComplete -and
            $degradedOutcome.IsDegraded -and
            -not $degradedOutcome.IsPartial -and
            $degradedOutcome.CompletedCount -eq 1 -and
            $degradedOutcome.RetryableRemainingCount -eq 0 -and
            $degradedOutcome.IncompatibleRemainingCount -eq 1
        ) `
        -Name "Runtime/BAZAIncompatibleNamesAreDegraded" `
        -Failure "залишок лише з несумісних імен має бути завершеним degraded-результатом без повтору"

    $protectedTemporaryScript = $null
    $temporaryScriptProtected = $false
    $temporaryScriptRemoved = $false
    try {
        $protectedTemporaryScript = & $archiveRuntimeModule {
            New-BRAVOWinSCPTemporaryScriptPath
        }
        $temporaryAcl = Get-Acl -LiteralPath $protectedTemporaryScript -ErrorAction Stop
        $allowedSidValues = @(
            $temporaryAcl.Access | ForEach-Object {
                try {
                    $_.IdentityReference.Translate(
                        [Security.Principal.SecurityIdentifier]
                    ).Value
                } catch {
                    [string]$_.IdentityReference
                }
            }
        )
        $currentSidValue = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $temporaryScriptProtected = (
            $temporaryAcl.AreAccessRulesProtected -and
            $allowedSidValues -contains $currentSidValue -and
            $allowedSidValues -contains "S-1-5-18" -and
            $allowedSidValues -contains "S-1-5-32-544"
        )
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($protectedTemporaryScript)) {
            & $archiveRuntimeModule {
                param($Path)
                Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $Path
            } $protectedTemporaryScript
            $temporaryScriptRemoved = -not (
                Test-Path -LiteralPath $protectedTemporaryScript
            )
        }
    }
    Test-BRAVOCondition `
        -Condition ($temporaryScriptProtected -and $temporaryScriptRemoved) `
        -Name "Runtime/ProtectedWinSCPTemporaryScript" `
        -Failure "WinSCP-файл має мати закритий ACL і гарантовано видалятися"

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
    $compatibilityScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_COMPATIBILITY.ps1"),
        [Text.Encoding]::UTF8
    )
    $vetOfficeScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "ARCHIV_VETOFFICE.ps1"),
        [Text.Encoding]::UTF8
    )
    $sevenZipPasswordInArgumentsPattern = '(?im)^.*(?:^|\s)-p(?:\$|"|\{).*(?:archivePassword|vetArchivePassword).*$'
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("RedirectStandardInput = `$true") -and
            $maintenanceScriptText.Contains("StandardInputText") -and
            $compatibilityScriptText.Contains("StandardInput.WriteLine(`$Password)") -and
            $vetOfficeScriptText.Contains("StandardInput.WriteLine(`$script:vetArchivePassword)") -and
            $archiveScriptText -notmatch '(?i)-p`"\{0\}`"' -and
            $maintenanceScriptText -notmatch '(?i)-p\$\(' -and
            $compatibilityScriptText -notmatch '(?i)-p`"\{0\}`"' -and
            $vetOfficeScriptText -notmatch '(?i)-p\$\(' -and
            $archiveScriptText -notmatch $sevenZipPasswordInArgumentsPattern -and
            $maintenanceScriptText -notmatch $sevenZipPasswordInArgumentsPattern -and
            $compatibilityScriptText -notmatch $sevenZipPasswordInArgumentsPattern -and
            $vetOfficeScriptText -notmatch $sevenZipPasswordInArgumentsPattern
        ) `
        -Name "Secrets/SevenZipPasswordUsesStdin" `
        -Failure "пароль 7-Zip не повинен потрапляти до командного рядка процесу"
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
            $maintenanceScriptText.Contains("СЛУЖБИ НЕ ЗАПУЩЕНІ ПЕРЕД MAINTENANCE") -and
            $maintenanceScriptText.Contains('$availableLength -= [Environment]::NewLine.Length')
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
        -Condition (
            $archiveScriptText.Contains("Send-BAZAIncompatibleNameAlert") -and
            $archiveScriptText.Contains("несумісних імен") -and
            $archiveScriptText.Contains("Select-Object -First 5") -and
            $archiveScriptText.Contains("Split-DiscordNotificationText -Message `$message") -and
            $archiveScriptText.Contains('$script:notificationWebhookUrl') -and
            $archiveScriptText.Contains('$script:notificationProvider') -and
            $archiveScriptText.Contains('$script:notificationRequestTimeoutSeconds')
        ) `
        -Name "Notifications/BAZAIncompatibleNames" `
        -Failure "несумісні з SFTP імена BAZA мають створювати одне стислий сповіщення"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('function ConvertTo-NotificationLiteralText') -and
            $archiveScriptText.Contains('.Replace("*", "\*")') -and
            -not $archiveScriptText.Contains('.Replace("*", "\\*")')
        ) `
        -Name "Notifications/DiscordFileNameEscaping" `
        -Failure "Discord escaping має використовувати одну зворотну риску, а не дві"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('IsDegraded') -and
            $archiveScriptText.Contains('IncompatibleRemainingCount') -and
            $archiveScriptText.Contains('Повторний запуск не потрібен')
        ) `
        -Name "SFTP/IncompatibleNamesDoNotRetryWholeBackup" `
        -Failure "несумісні імена BAZA не повинні викликати повтор усієї архівації"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("function New-BRAVOVSSSnapshot") -and
            $archiveScriptText.Contains("function Remove-BRAVOVSSSnapshot") -and
            $archiveScriptText.Contains('$vssSnapshot = New-BRAVOVSSSnapshot') -and
            $archiveScriptText.Contains('live-архівація заборонена')
        ) `
        -Name "BackupConsistency/VSSFailClosed" `
        -Failure "BRAVO_ARCHIV має архівувати VSS-знімок і не переходити до live-каталогу при помилці"
    $dryRunScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_DRY_RUN.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $dryRunScriptText.Contains('$backupConsistency.Mode') -and
            $dryRunScriptText.Contains('$backupConsistency.SnapshotContext') -and
            -not $dryRunScriptText.Contains('QuiesceForBackup')
        ) `
        -Name "BackupConsistency/DryRunReportsVSS" `
        -Failure "dry-run має показувати фактичний VSS-режим замість видаленого QuiesceForBackup"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('Format-HealthIssueFileName -Issue $Issue') -and
            $archiveScriptText.Contains('$($Issue.Reason)$(Format-HealthIssueFileName -Issue $Issue)')
        ) `
        -Name "Health/SFTPArchiveNameOnFailures" `
        -Failure "ім'я локального архіву має відображатися для всіх SFTP-помилок"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains('function New-BRAVOWinSCPTemporaryScriptPath') -and
            -not $archiveScriptText.Contains('GetTempFileName() + ".txt"')
        ) `
        -Name "SFTP/NoOrphanedTemporaryScripts" `
        -Failure "WinSCP не повинен залишати базові .tmp файли після кожного запуску"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("function Invoke-ManualBAZASFTPSynchronization") -and
            $archiveScriptText.Contains("Synchronization.BAZAWWWSFTP") -and
            $archiveScriptText.Contains("BAZA_APP / BAZA_WWW") -and
            $archiveScriptText.Contains("-SynchronizationOnly")
        ) `
        -Name "SFTP/ManualBAZAAppAndWww" `
        -Failure "-SyncBAZA має синхронізувати всі увімкнені BAZA_APP і BAZA_WWW"
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

    $cleanupScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "REMOVE_OLD_ARCHIV_LIMS.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $cleanupScriptText.Contains('$hadErrors = $true') -and
            $cleanupScriptText.Contains('exit 1') -and
            $cleanupScriptText.Contains('ЗАВЕРШЕННЯ ОЧИЩЕННЯ АРХІВІВ З ПОМИЛКАМИ')
        ) `
        -Name "Cleanup/FailureExitCode" `
        -Failure "окремий cleanup-скрипт має повертати ненульовий код після часткових помилок"

    $cleanupRuntimeRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_CLEANUP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $cleanupArchiveRoot = Join-Path $cleanupRuntimeRoot "archive"
        $cleanupLogRoot = Join-Path $cleanupRuntimeRoot "logs"
        [void][IO.Directory]::CreateDirectory($cleanupArchiveRoot)
        [void][IO.Directory]::CreateDirectory($cleanupLogRoot)
        $windowsPowerShell = Join-Path `
            -Path $env:SystemRoot `
            -ChildPath "System32\WindowsPowerShell\v1.0\powershell.exe"
        $cleanupScriptPath = Join-Path $root "REMOVE_OLD_ARCHIV_LIMS.ps1"

        & $windowsPowerShell `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $cleanupScriptPath `
            -ArchivePath $cleanupArchiveRoot `
            -Directories "MISSING" `
            -LogDirectory $cleanupLogRoot *> $null
        $cleanupFailureExitCode = $LASTEXITCODE

        [void][IO.Directory]::CreateDirectory((Join-Path $cleanupArchiveRoot "MODEL"))
        & $windowsPowerShell `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $cleanupScriptPath `
            -ArchivePath $cleanupArchiveRoot `
            -Directories "MODEL" `
            -LogDirectory $cleanupLogRoot *> $null
        $cleanupSuccessExitCode = $LASTEXITCODE

        Test-BRAVOCondition `
            -Condition (
                $cleanupFailureExitCode -eq 1 -and
                $cleanupSuccessExitCode -eq 0
            ) `
            -Name "Runtime/CleanupExitCodes" `
            -Failure "cleanup повернув коди failure=$cleanupFailureExitCode, success=$cleanupSuccessExitCode"
    } finally {
        if (Test-Path -LiteralPath $cleanupRuntimeRoot -PathType Container) {
            $resolvedCleanupRuntimeRoot = [IO.Path]::GetFullPath($cleanupRuntimeRoot)
            $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            if ($resolvedCleanupRuntimeRoot.StartsWith(
                    $temporaryRoot,
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                [IO.Path]::GetFileName($resolvedCleanupRuntimeRoot).StartsWith(
                    "BRAVO_CLEANUP_SELF_TEST_",
                    [StringComparison]::Ordinal
                )) {
                [IO.Directory]::Delete($resolvedCleanupRuntimeRoot, $true)
            }
        }
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
