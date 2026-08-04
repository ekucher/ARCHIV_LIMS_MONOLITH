[CmdletBinding()]
param(
    [string]$ConfigPath
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
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
    $powerShellFiles = @(
        @(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1')
        @(Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') })
    )
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

    Remove-Module -Name 'BRAVO.Compatibility' -Force -ErrorAction SilentlyContinue
    $outputEncodingBeforeCompatibilityImport = $global:OutputEncoding
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Test-BRAVOCondition `
        -Condition ([object]::ReferenceEquals(
                $outputEncodingBeforeCompatibilityImport,
                $global:OutputEncoding
            )) `
        -Name "Compatibility/ImportHasNoConsoleSideEffects" `
        -Failure "імпорт Compatibility не повинен змінювати global OutputEncoding"
    $staleHotfix = [pscustomobject]@{ InstalledOn = (Get-Date).AddDays(-400) }
    $stalePatchLevel = Get-BRAVOWindowsPatchLevelRecommendation `
        -InstalledHotfixes @($staleHotfix) `
        -Now (Get-Date) `
        -StaleAfterDays 120
    $freshHotfix = [pscustomobject]@{ InstalledOn = (Get-Date).AddDays(-10) }
    $freshPatchLevel = Get-BRAVOWindowsPatchLevelRecommendation `
        -InstalledHotfixes @($freshHotfix) `
        -Now (Get-Date) `
        -StaleAfterDays 120
    $noDataPatchLevel = Get-BRAVOWindowsPatchLevelRecommendation `
        -InstalledHotfixes @() `
        -StaleAfterDays 120
    Test-BRAVOCondition `
        -Condition (
            $stalePatchLevel.IsUpdateRecommended -and
            $stalePatchLevel.DaysSinceLastUpdate -eq 400 -and
            -not [string]::IsNullOrWhiteSpace([string]$stalePatchLevel.Message) -and
            -not $freshPatchLevel.IsUpdateRecommended -and
            $null -eq $freshPatchLevel.Message -and
            $noDataPatchLevel.IsUpdateRecommended -and
            -not [string]::IsNullOrWhiteSpace([string]$noDataPatchLevel.Message)
        ) `
        -Name "Compatibility/WindowsPatchLevelRecommendation" `
        -Failure "рекомендація оновити Windows має спрацьовувати лише для застарілого рівня патчів і не хибити на свіжій системі"

    $toolIntegrityTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_TOOL_INTEGRITY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($toolIntegrityTestRoot)
        $toolIntegrityTool = Join-Path $toolIntegrityTestRoot "fake7za.exe"
        [IO.File]::WriteAllText($toolIntegrityTool, "original content", (New-Object Text.UTF8Encoding($false)))
        $toolIntegrityManifest = Join-Path $toolIntegrityTestRoot "TOOLS_INTEGRITY.json"

        $toolIntegrityFirstRun = Get-BRAVOToolIntegrityRecommendation `
            -ToolPaths @($toolIntegrityTool) `
            -ManifestPath $toolIntegrityManifest
        $toolIntegrityUnchangedRun = Get-BRAVOToolIntegrityRecommendation `
            -ToolPaths @($toolIntegrityTool) `
            -ManifestPath $toolIntegrityManifest
        [IO.File]::WriteAllText($toolIntegrityTool, "TAMPERED", (New-Object Text.UTF8Encoding($false)))
        $toolIntegrityTamperedRun = Get-BRAVOToolIntegrityRecommendation `
            -ToolPaths @($toolIntegrityTool) `
            -ManifestPath $toolIntegrityManifest
        $toolIntegrityMissingRun = Get-BRAVOToolIntegrityRecommendation `
            -ToolPaths @((Join-Path $toolIntegrityTestRoot "nonexistent.exe")) `
            -ManifestPath $toolIntegrityManifest

        Test-BRAVOCondition `
            -Condition (
                -not $toolIntegrityFirstRun.HasIntegrityIssue -and
                (Test-Path -LiteralPath $toolIntegrityManifest -PathType Leaf) -and
                -not $toolIntegrityUnchangedRun.HasIntegrityIssue -and
                $toolIntegrityTamperedRun.HasIntegrityIssue -and
                $toolIntegrityTamperedRun.MismatchedTools -contains "fake7za.exe" -and
                -not [string]::IsNullOrWhiteSpace([string]$toolIntegrityTamperedRun.Message) -and
                -not $toolIntegrityMissingRun.HasIntegrityIssue
            ) `
            -Name "Compatibility/ToolIntegrityRecommendation" `
            -Failure "перший запуск має тихо зафіксувати базову лінію (TOFU), підміна файлу — попередити, відсутній інструмент — не хибити"
    } finally {
        if (Test-Path -LiteralPath $toolIntegrityTestRoot -PathType Container) {
            [IO.Directory]::Delete($toolIntegrityTestRoot, $true)
        }
    }

    Remove-Module -Name 'BRAVO.Logging' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Logging\BRAVO.Logging.psd1") -Force -ErrorAction Stop
    $maskedSftpUrl = Protect-BRAVOLogSecret -Text "open sftp://bravouser:S3cr3tPass@sftp.example.org:22"
    $maskedSlackWebhook = Protect-BRAVOLogSecret -Text "https://hooks.slack.com/services/T000AAAA/B111BBBB/xxxTOKENxxxCCCC"
    $maskedDiscordWebhook = Protect-BRAVOLogSecret -Text "https://discord.com/api/webhooks/123456789/abcDEF-token_value"
    $maskedArchivePasswordLong = Protect-BRAVOLogSecret -Text "7za.exe a -password=SuperSecret archive.mdz"
    $maskedArchivePasswordShort = Protect-BRAVOLogSecret -Text "7za.exe t -pSecretPass123 archive.mdz"
    $unmaskedPathArgument = Protect-BRAVOLogSecret -Text "backup at -path C:\Some\Dir"
    Test-BRAVOCondition `
        -Condition (
            $maskedSftpUrl -eq "open sftp://bravouser:***@sftp.example.org:22" -and
            -not $maskedSlackWebhook.Contains("xxxTOKENxxxCCCC") -and
            $maskedSlackWebhook.Contains("hooks.slack.com/services/***") -and
            -not $maskedDiscordWebhook.Contains("abcDEF-token_value") -and
            $maskedDiscordWebhook.Contains("discord.com/api/webhooks/***") -and
            $maskedArchivePasswordLong -eq "7za.exe a -password=*** archive.mdz" -and
            $maskedArchivePasswordShort -eq "7za.exe t -p*** archive.mdz" -and
            $unmaskedPathArgument -eq "backup at -path C:\Some\Dir"
        ) `
        -Name "Logging/ProtectSecretMasksKnownShapes" `
        -Failure "Protect-BRAVOLogSecret має маскувати SFTP-паролі, Slack/Discord webhook-токени і паролі 7-Zip, не займаючи -path"
    $healthScriptTextForSecretMasking = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $maintenanceScriptTextForSecretMasking = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $healthScriptTextForSecretMasking.Contains("Protect-BRAVOLogSecret") -and
            $maintenanceScriptTextForSecretMasking.Contains("Protect-BRAVOLogSecret")
        ) `
        -Name "Runtime/HealthAndMaintenanceMaskSecretsInLogs" `
        -Failure "Write-HealthLog і Write-Log (Maintenance) мають маскувати секрети так само, як Write-BRAVOLog в Archive"

    Remove-Module -Name 'BRAVO.ExitCodes' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.ExitCodes\BRAVO.ExitCodes.psd1") -Force -ErrorAction Stop
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode) -eq 0 -and
            (Resolve-BRAVOExitCode -HasWarnings) -eq 10 -and
            (Resolve-BRAVOExitCode -LockBusy) -eq 20 -and
            (Resolve-BRAVOExitCode -InvalidConfiguration) -eq 30 -and
            (Resolve-BRAVOExitCode -CredentialsUnavailable) -eq 31 -and
            (Resolve-BRAVOExitCode -LocalArchiveFailed) -eq 40 -and
            (Resolve-BRAVOExitCode -IntegrityTestFailed) -eq 41 -and
            (Resolve-BRAVOExitCode -SftpFailed) -eq 50 -and
            (Resolve-BRAVOExitCode -SmbFailed) -eq 51 -and
            (Resolve-BRAVOExitCode -MaintenanceFailed) -eq 60 -and
            (Resolve-BRAVOExitCode -HealthCritical) -eq 70 -and
            (Resolve-BRAVOExitCode -InternalError) -eq 90
        ) `
        -Name "ExitCodes/ResolveSingleCategory" `
        -Failure "кожна окрема категорія відмови має повертати свій код із контракту"
    Test-BRAVOCondition `
        -Condition (
            (Resolve-BRAVOExitCode -SftpFailed -SmbFailed) -eq 50 -and
            (Resolve-BRAVOExitCode -LockBusy -InvalidConfiguration) -eq 20 -and
            (Resolve-BRAVOExitCode -InternalError -SftpFailed -HasWarnings) -eq 90 -and
            (Resolve-BRAVOExitCode -LocalArchiveFailed -IntegrityTestFailed) -eq 40 -and
            (Resolve-BRAVOExitCode -MaintenanceFailed -HealthCritical) -eq 60 -and
            (Resolve-BRAVOExitCode -InvalidConfiguration -CredentialsUnavailable) -eq 30
        ) `
        -Name "ExitCodes/ResolvePriorityOrder" `
        -Failure "при одночасних відмовах має перемагати найвищий пріоритет (lock>config>creds>local>integrity>sftp>smb>maintenance>health>warnings), InternalError — найвищий за все"
    Test-BRAVOCondition `
        -Condition (
            (Get-BRAVOExitCodeName -Code 0) -eq "Success" -and
            (Get-BRAVOExitCodeName -Code 50) -eq "SftpFailed" -and
            (Get-BRAVOExitCodeName -Code 999) -eq "Unknown(999)"
        ) `
        -Name "ExitCodes/GetExitCodeName" `
        -Failure "зворотний пошук назви коду має працювати для відомих і невідомих значень"
    $archiveRuntimeTextForExitCodes = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $maintenanceRuntimeTextForExitCodes = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $healthRuntimeTextForExitCodes = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForExitCodes.Contains("'BRAVO.ExitCodes'") -and
            $archiveRuntimeTextForExitCodes.Contains("Resolve-BRAVOExitCode") -and
            $maintenanceRuntimeTextForExitCodes.Contains("'BRAVO.ExitCodes'") -and
            $maintenanceRuntimeTextForExitCodes.Contains("Resolve-BRAVOExitCode") -and
            $healthRuntimeTextForExitCodes.Contains("'BRAVO.ExitCodes'") -and
            $healthRuntimeTextForExitCodes.Contains("Resolve-BRAVOExitCode")
        ) `
        -Name "Runtime/SharedExitCodeContract" `
        -Failure "Archive/Health/Maintenance мають підключати BRAVO.ExitCodes і формувати підсумковий код через Resolve-BRAVOExitCode"
    Test-BRAVOCondition `
        -Condition (
            -not ($archiveRuntimeTextForExitCodes -match 'processExitCode\s*=\s*2\b') -and
            -not ($maintenanceRuntimeTextForExitCodes -match '\bexit\s+2\b') -and
            -not ($maintenanceRuntimeTextForExitCodes -match '\bexit\s+1\b')
        ) `
        -Name "Runtime/NoLegacyAdHocExitCodes" `
        -Failure "старі ad-hoc коди (2 для lock, голий exit 1) мають бути повністю замінені контрактом BRAVO.ExitCodes"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceRuntimeTextForExitCodes.Contains('$script:restoreArchiveFailed') -and
            $maintenanceRuntimeTextForExitCodes.Contains('$script:restoreIntegrityFailed') -and
            $maintenanceRuntimeTextForExitCodes.Contains('-LocalArchiveFailed:$script:restoreArchiveFailed') -and
            $maintenanceRuntimeTextForExitCodes.Contains('-IntegrityTestFailed:$script:restoreIntegrityFailed') -and
            ([regex]::Matches($maintenanceRuntimeTextForExitCodes, [regex]::Escape('$script:restoreArchiveFailed = $true')).Count -eq 10) -and
            ([regex]::Matches($maintenanceRuntimeTextForExitCodes, [regex]::Escape('$script:restoreIntegrityFailed = $true')).Count -eq 9)
        ) `
        -Name "Runtime/MaintenanceDistinguishesArchiveVsIntegrityFailure" `
        -Failure "Maintenance має розрізняти локальну архівацію (40) і перевірку цілісності (41) відновлення, а не зводити все до 60"
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeTextForExitCodes -match
                "Set-BRAVOLogComponent -Component 'SUMMARY'\s*\r?\n\s*Write-Log `"Результат:"
        ) `
        -Name "Runtime/FinalSummaryUsesSummaryLogComponent" `
        -Failure "підсумковий рядок 'Результат:' має явно повертати компонент журналу на SUMMARY, інакше після виконаного health-check він хибно тегується [HEALTH], навіть якщо сам health-check пройшов успішно"

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
    $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    $loadedConfiguration = Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $resolvedConfig `
        -PassThru

    Test-BRAVOCondition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace([string]$loadedConfiguration.Version.PackageVersion) -and
            [string]$ScriptVersion -eq [string]$loadedConfiguration.Version.PackageVersion -and
            [string]$ScriptDate -eq [string]$loadedConfiguration.Version.ReleaseDate
        ) `
        -Name "Version/AuthoritativeLoader" `
        -Failure "VERSION.json має бути єдиним джерелом версії та releaseDate для ScriptVersion і ScriptDate"
    $moduleManifests = @(Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Recurse -Filter '*.psd1' -File)
    $moduleVersionsMatch = @($moduleManifests | Where-Object {
            [string](Test-ModuleManifest -Path $_.FullName -ErrorAction Stop).Version -ne
            [string]$loadedConfiguration.Version.PackageVersion
        }).Count -eq 0
    Test-BRAVOCondition `
        -Condition ($moduleManifests.Count -gt 0 -and $moduleVersionsMatch) `
        -Name "Version/ModuleManifests" `
        -Failure "ModuleVersion усіх manifests має відповідати packageVersion у VERSION.json"
    $archiveHelpersModulePath = Join-Path `
        $root `
        'modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1'
    Remove-Module -Name 'BRAVO.ArchiveHelpers' -Force -ErrorAction SilentlyContinue
    Import-Module -Name $archiveHelpersModulePath -Force -ErrorAction Stop
    $archiveHelperSmokeCompleted = $false
    try {
        $archiveHelperSmokeResult = Test-SevenZipArchiveIntegrity `
            -SevenZipPath (Join-Path $root '__MISSING_7Z__.exe') `
            -ArchivePath (Join-Path $root '__MISSING_ARCHIVE__.7z') `
            -Password 'self-test-placeholder' `
            -Logger { param($Message, $Level) }
        $archiveHelperSmokeCompleted = ($archiveHelperSmokeResult -eq $false)
    } catch {
        $archiveHelperSmokeCompleted = $false
    }
    Test-BRAVOCondition `
        -Condition $archiveHelperSmokeCompleted `
        -Name "Modules/ArchiveHelpersAreCallerIndependent" `
        -Failure "ArchiveHelpers мають виконуватися без приватних функцій caller-а"
    Test-BRAVOCondition `
        -Condition ([string]$archiveParams -match '(?i)(^|\s)-ssw(\s|$)') `
        -Name "BackupAvailability/AllowOpenFiles" `
        -Failure "backup без зупинки служб має дозволяти читання відкритих файлів"
    $archiveScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $healthScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $notificationScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Notifications\BRAVO.Notifications.psm1"),
        [Text.Encoding]::UTF8
    )
    $archiveLoaderCalls = @(
        [regex]::Matches(
            $archiveScriptText,
            'Import-BravoConfiguration\s+`?\s*-ConfigRoot\s+\$bravoScriptDirectory\s+`?\s*-ConfigPath\s+\$ConfigPath'
        )
    ).Count
    $healthLoaderCalls = @(
        [regex]::Matches(
            $healthScriptText,
            'Import-BravoConfiguration\s+`?\s*-ConfigRoot\s+\$bravoScriptDirectory\s+`?\s*-ConfigPath\s+\$ConfigPath'
        )
    ).Count
    Test-BRAVOCondition `
        -Condition ($archiveLoaderCalls -eq 1 -and $healthLoaderCalls -eq 1) `
        -Name "ConfigurationLoader/ArchiveAndHealthEntrypoints" `
        -Failure "BRAVO_ARCHIV і BRAVO_HEALTH повинні окремо завантажувати конфігурацію через loader"
    $archiveRuntimeModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($archiveScriptText + [Environment]::NewLine + $healthScriptText + [Environment]::NewLine + $notificationScriptText) `
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
        (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $compatibilityScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1"),
        [Text.Encoding]::UTF8
    )
    $sevenZipPasswordInArgumentsPattern = '(?im)^.*(?:^|\s)-p(?:\$|"|\{).*archivePassword.*$'
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("RedirectStandardInput = `$true") -and
            $maintenanceScriptText.Contains("StandardInputText") -and
            $compatibilityScriptText.Contains("StandardInput.WriteLine(`$Password)") -and
            $archiveScriptText -notmatch '(?i)-p`"\{0\}`"' -and
            $maintenanceScriptText -notmatch '(?i)-p\$\(' -and
            $compatibilityScriptText -notmatch '(?i)-p`"\{0\}`"' -and
            $archiveScriptText -notmatch $sevenZipPasswordInArgumentsPattern -and
            $maintenanceScriptText -notmatch $sevenZipPasswordInArgumentsPattern -and
            $compatibilityScriptText -notmatch $sevenZipPasswordInArgumentsPattern
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
            $maintenanceScriptText.Contains("BRAVO.Notifications") -and
            $notificationScriptText.Contains('$availableLength -= [Environment]::NewLine.Length')
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
            $healthScriptText.Contains('function Invoke-BRAVOHealth') -and
            $healthScriptText.Contains('[switch]$SkipIfBackupTaskRunning') -and
            $healthScriptText.Contains('SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning') -and
            $healthScriptText.Contains("BRAVO.Compatibility") -and
            $healthScriptText.Contains("BRAVO.Credentials") -and
            $healthScriptText.Contains("BRAVO.ArchiveRuntime") -and
            $schedulerSettings.Health.ScriptPath -eq (Join-Path $root 'BRAVO_HEALTH.ps1') -and
            -not $archiveScriptText.Contains('function Invoke-BRAVOEmbeddedHealth') -and
            $archiveScriptText.Contains('Invoke-BRAVOHealthCheck @healthParameters') -and
            -not $archiveScriptText.Contains('. $healthScriptPath')
        ) `
        -Name "Health/SeparateRuntime" `
        -Failure "health має бути окремим runtime-скриптом без дублювання compatibility і credentials коду в архіваторі"
    $healthModulePath = Join-Path $root 'modules\BRAVO.Health\BRAVO.Health.psd1'
    $healthModule = Import-Module `
        -Name $healthModulePath `
        -Force `
        -PassThru `
        -ErrorAction Stop
    # URL збирається з частин, щоб у файлі не було літерала у форматі
    # scheme://user:password@host: сканери секретів вважають такий рядок
    # реальними обліковими даними. Значення фіктивні, example.invalid —
    # зарезервований RFC 2606 домен; результат і поведінка тесту незмінні.
    $selfTestSftpUser = 'self-test-user'
    $selfTestSftpSecret = 'self-test-secret'
    $healthModule.SessionState.PSVariable.Set('Login', $selfTestSftpUser)
    $healthModule.SessionState.PSVariable.Set(
        'sftpUrl',
        ('sftp://{0}:{1}@example.invalid/' -f $selfTestSftpUser, $selfTestSftpSecret)
    )
    $missingHealthConfigPath = Join-Path $root '__BRAVO_SELF_TEST_MISSING_HEALTH_CONFIG__.config'
    $programmaticHealthResult = Invoke-BRAVOHealthCheck `
        -ConfigPath $missingHealthConfigPath `
        -RuntimeRoot $root `
        -EntryScriptPath (Join-Path $root 'BRAVO_HEALTH.ps1') `
        -ErrorAction Continue `
        2>$null
    Test-BRAVOCondition `
        -Condition ([string]$programmaticHealthResult.Status -eq 'ConfigurationError') `
        -Name "Health/ProgrammaticApiDoesNotExit" `
        -Failure "програмний Health API має повертати result object без завершення процесу"
    Test-BRAVOCondition `
        -Condition (
            $null -eq $healthModule.SessionState.PSVariable.GetValue('Login') -and
            $null -eq $healthModule.SessionState.PSVariable.GetValue('sftpUrl') -and
            $null -eq $healthModule.SessionState.PSVariable.GetValue('smbCredential')
        ) `
        -Name "Health/ProgrammaticApiClearsCredentialState" `
        -Failure "програмний Health API має очищати секретний module state навіть після ранньої помилки"
    Test-BRAVOCondition `
        -Condition (
            [bool]$backupMonitoring.CheckManagedServices -and
            $healthScriptText.Contains("Get-ManagedServiceHealthIssues") -and
            $healthScriptText.Contains('Kind = "Service"')
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
            $healthScriptText.Contains('function ConvertTo-NotificationLiteralText') -and
            $healthScriptText.Contains('.Replace("*", "\*")') -and
            -not $healthScriptText.Contains('.Replace("*", "\\*")')
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
            $healthScriptText.Contains('Format-HealthIssueFileName -Issue $Issue') -and
            $healthScriptText.Contains('$($Issue.Reason)$(Format-HealthIssueFileName -Issue $Issue)')
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
    $taskInstallScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_TASKS_INSTALL.ps1"),
        [Text.Encoding]::UTF8
    )
    $runtimeScopeChecks = @(
        [pscustomobject]@{
            Name = "Archive"
            Text = $archiveScriptText
            AllowedGlobalVariables = @(
                "BravoConfigurationMetadata",
                "LogLevel",
                "OutputEncoding",
                "ScriptDate",
                "ScriptVersion"
            )
            RequiredScriptVariables = @("Login", "resolvedSftpHost", "sftpUrl", "logFile")
        },
        [pscustomobject]@{
            Name = "Health"
            Text = $healthScriptText
            AllowedGlobalVariables = @(
                "BravoConfigurationMetadata",
                "ScriptDate",
                "ScriptVersion"
            )
            RequiredScriptVariables = @("Login", "resolvedSftpHost", "sftpUrl")
        },
        [pscustomobject]@{
            Name = "Maintenance"
            Text = $maintenanceScriptText
            AllowedGlobalVariables = @("ScriptDate", "ScriptVersion")
            RequiredScriptVariables = @("criticalErrorOccurred", "ScriptStartTime")
        }
    )
    foreach ($runtimeScopeCheck in $runtimeScopeChecks) {
        $globalVariables = @(
            [regex]::Matches(
                $runtimeScopeCheck.Text,
                '\$global:([A-Za-z_][A-Za-z0-9_]*)'
            ) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        )
        $unexpectedGlobalVariables = @(
            $globalVariables | Where-Object {
                $_ -notin $runtimeScopeCheck.AllowedGlobalVariables
            }
        )
        $missingScriptVariables = @(
            $runtimeScopeCheck.RequiredScriptVariables | Where-Object {
                -not $runtimeScopeCheck.Text.Contains('$script:' + $_)
            }
        )
        Test-BRAVOCondition `
            -Condition (
                $unexpectedGlobalVariables.Count -eq 0 -and
                $missingScriptVariables.Count -eq 0
            ) `
            -Name "RuntimeScope/$($runtimeScopeCheck.Name)" `
            -Failure (
                "runtime-стан $($runtimeScopeCheck.Name) має бути script-scoped; " +
                "неочікувані global: $($unexpectedGlobalVariables -join ', '); " +
                "відсутні script: $($missingScriptVariables -join ', ')"
            )
    }
    Test-BRAVOCondition `
        -Condition (
            [int]$schedulerSettings.Health.RepeatEveryMinutes -eq 240 -and
            -not $taskInstallScriptText.Contains('RepeatEveryMinutes = 240')
        ) `
        -Name "Scheduler/HealthScheduleIsConfigOwned" `
        -Failure "інсталятор не повинен змінювати інтервал health-check; джерелом правди є BRAVO.config"
    Test-BRAVOCondition `
        -Condition (
            $taskInstallScriptText.Contains('Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse') -and
            $taskInstallScriptText.Contains('foreach ($runtimeItem in $runtimeItems)')
        ) `
        -Name "Scheduler/ProtectedRuntimeRecursiveAcl" `
        -Failure "ACL hardening має застосовуватися до всіх наявних дочірніх файлів runtime"
    Test-BRAVOCondition `
        -Condition (
            $taskInstallScriptText.Contains('[System.IO.Directory]::Exists($runtimeItem)') -and
            $taskInstallScriptText.Contains('[Security.AccessControl.InheritanceFlags]::None')
        ) `
        -Name "Scheduler/AclInheritanceOnlyForContainers" `
        -Failure "прапорці успадкування ACL можна ставити лише каталогам, інакше файл дає 'No flags can be set'"

    # Функціональна регресія: попередня перевірка вище була суто текстовою й
    # проходила навіть тоді, коли hardening ACL падав на бойовому сервері.
    # Тут правило справді будується для каталогу та для файлу.
    # AddAccessRule працює над копією ACL у пам'яті й не потребує прав адміністратора.
    $aclProbeRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_ACL_PROBE_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($aclProbeRoot)
        $aclProbeFile = Join-Path $aclProbeRoot "probe.ps1"
        [IO.File]::WriteAllText($aclProbeFile, "# probe", (New-Object Text.UTF8Encoding($false)))
        $probeInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $probeSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
        $aclProbeFailure = $null
        foreach ($probeItem in @($aclProbeRoot, $aclProbeFile)) {
            $probeItemInheritance = if ([IO.Directory]::Exists($probeItem)) {
                $probeInheritance
            } else {
                [Security.AccessControl.InheritanceFlags]::None
            }
            try {
                $probeAcl = Get-Acl -LiteralPath $probeItem -ErrorAction Stop
                $probeAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    $probeSid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $probeItemInheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )))
            } catch {
                $aclProbeFailure = "$probeItem — $($_.Exception.Message)"
            }
        }
        Test-BRAVOCondition `
            -Condition ($null -eq $aclProbeFailure) `
            -Name "Scheduler/AclRuleAppliesToFilesAndFolders" `
            -Failure "правило ACL не будується: $aclProbeFailure"
    } finally {
        if (Test-Path -LiteralPath $aclProbeRoot -PathType Container) {
            [IO.Directory]::Delete($aclProbeRoot, $true)
        }
    }

    Test-BRAVOCondition `
        -Condition ($taskInstallScriptText -match '(?s)\$installationCommitted\s*=\s*\$false.*?\$taskFolder\s*=\s*\$null') `
        -Name "Scheduler/RollbackStateInitialized" `
        -Failure 'обробник помилок читає $taskFolder, тому його треба ініціалізувати до основного try'
    foreach ($utility in @(
            [pscustomobject]@{ Name = "BRAVO_SETUP.ps1"; Path = "BRAVO_SETUP.ps1" },
            [pscustomobject]@{ Name = "BRAVO_DRY_RUN.ps1"; Path = "BRAVO_DRY_RUN.ps1" },
            [pscustomobject]@{ Name = "BRAVO_HEALTH.ps1"; Path = "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1" },
            [pscustomobject]@{ Name = "BRAVO_TASKS_DIAGNOSE.ps1"; Path = "BRAVO_TASKS_DIAGNOSE.ps1" },
            [pscustomobject]@{ Name = "BRAVO_TASKS_UNINSTALL.ps1"; Path = "BRAVO_TASKS_UNINSTALL.ps1" },
            [pscustomobject]@{ Name = "BRAVO_CREDENTIALS_SETUP.ps1"; Path = "BRAVO_CREDENTIALS_SETUP.ps1" },
            [pscustomobject]@{ Name = "BRAVO_TASKS_INSTALL.ps1"; Path = "BRAVO_TASKS_INSTALL.ps1" }
        )) {
        $utilityText = [IO.File]::ReadAllText(
            (Join-Path $root $utility.Path),
            [Text.Encoding]::UTF8
        )
        Test-BRAVOCondition `
            -Condition ($utilityText.Contains('BRAVO_CONFIG_LOADER.ps1') -and
                $utilityText.Contains('Import-BravoConfiguration')) `
            -Name "ConfigurationLoader/$($utility.Name)" `
            -Failure "BRAVO-утиліта має використовувати спільний BRAVO_CONFIG_LOADER.ps1"
    }
    $credentialsSetupText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CREDENTIALS_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (-not $credentialsSetupText.Contains('function Import-BRAVOConfiguration')) `
        -Name "ConfigurationLoader/CredentialsSetupNoNameCollision" `
        -Failure "локальний wrapper credentials-утиліти не повинен збігатися за ім'ям із Import-BravoConfiguration"

    $legacyEntryPoints = @(
        'ARCHIV_VETOFFICE.ps1',
        'ARCHIV_VETOFFICE.config.ps1',
        'ARCHIV_VETOFFICE.cmd'
    )
    Test-BRAVOCondition `
        -Condition (-not ($legacyEntryPoints | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf })) `
        -Name "Legacy/VetOfficeRemoved" `
        -Failure "legacy VETOFFICE entrypoints не мають повертатися до runtime"
    $legacyCommandWrappers = @(Get-ChildItem -LiteralPath $root -File -Filter 'BRAVO_*.cmd')
    Test-BRAVOCondition `
        -Condition ($legacyCommandWrappers.Count -eq 0) `
        -Name "Legacy/CommandWrappersRemoved" `
        -Failure "BRAVO .cmd-обгортки не мають повертатися до runtime"

    foreach ($runtimeFile in @(
            "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1",
            "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"
        )) {
        $text = [IO.File]::ReadAllText(
            (Join-Path $root $runtimeFile),
            [Text.Encoding]::UTF8
        )
        Test-BRAVOCondition `
            -Condition ($text.Contains("BRAVO_OPERATION.lock")) `
            -Name "SharedLock/$runtimeFile" `
            -Failure "скрипт не використовує BRAVO_OPERATION.lock"
    }

    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("`$isLocalSystem = `$currentIdentity.User.Value -eq 'S-1-5-18'") -and
            $archiveScriptText.Contains('!$isLocalSystem -and !$currentPrincipal.IsInRole') -and
            $maintenanceScriptText.Contains("`$isLocalSystem = `$currentIdentity.User.Value -eq 'S-1-5-18'") -and
            $maintenanceScriptText.Contains('-not $isLocalSystem -and -not $currentPrincipal.IsInRole')
        ) `
        -Name "Scheduler/SystemDoesNotInvokeUac" `
        -Failure "SYSTEM-завдання не повинні викликати інтерактивний UAC/RunAs"

    Test-BRAVOCondition `
        -Condition (
            -not $archiveScriptText.Contains('BEGIN BRAVO EMBEDDED RUNTIME LIBRARIES') -and
            -not $maintenanceScriptText.Contains('BEGIN BRAVO EMBEDDED RUNTIME LIBRARIES') -and
            $archiveScriptText.Contains("BRAVO.Compatibility") -and
            $archiveScriptText.Contains("BRAVO.Credentials") -and
            $archiveScriptText.Contains("BRAVO.ArchiveRuntime") -and
            $maintenanceScriptText.Contains("BRAVO.Compatibility") -and
            $maintenanceScriptText.Contains("BRAVO.Credentials")
        ) `
        -Name "Runtime/SharedCompatibilityAndCredentials" `
        -Failure "archive та maintenance мають використовувати спільні compatibility/credentials замість вбудованих копій"
    $healthScriptTextForPatchLevel = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.Health\BRAVO.Health.Runtime.ps1"),
        [Text.Encoding]::UTF8
    )
    $credentialsSetupTextForPatchLevel = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_CREDENTIALS_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    $tasksInstallTextForPatchLevel = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_TASKS_INSTALL.ps1"),
        [Text.Encoding]::UTF8
    )
    $tasksUninstallTextForPatchLevel = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_TASKS_UNINSTALL.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            $maintenanceScriptText.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            $healthScriptTextForPatchLevel.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            $credentialsSetupTextForPatchLevel.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            $tasksInstallTextForPatchLevel.Contains("Get-BRAVOWindowsPatchLevelRecommendation") -and
            $tasksUninstallTextForPatchLevel.Contains("Get-BRAVOWindowsPatchLevelRecommendation")
        ) `
        -Name "Runtime/SharedWindowsPatchLevelRecommendation" `
        -Failure "усі точки входу мають попереджати про застарілий рівень оновлень Windows"
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Get-BRAVOToolIntegrityRecommendation") -and
            $maintenanceScriptText.Contains("Get-BRAVOToolIntegrityRecommendation") -and
            $healthScriptTextForPatchLevel.Contains("Get-BRAVOToolIntegrityRecommendation")
        ) `
        -Name "Runtime/SharedToolIntegrityRecommendation" `
        -Failure "Archive/Health/Maintenance мають перевіряти цілісність Tools (7za.exe/WinSCP) через спільну функцію"
    $archiveRuntimeText = [IO.File]::ReadAllText(
        (Join-Path $root "modules\BRAVO.ArchiveRuntime\BRAVO.ArchiveRuntime.psm1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeText.Contains('Get-BRAVOWmiInstance -ClassName Win32_Process') -and
            -not $archiveRuntimeText.Contains('Get-CimInstance -ClassName Win32_Process') -and
            -not $archiveRuntimeText.Contains('function Start-BRAVOProcessOutputCapture') -and
            -not $archiveRuntimeText.Contains('function Complete-BRAVOProcessOutputCapture')
        ) `
        -Name "Runtime/WinSCPProcessCheckCompatibility" `
        -Failure "SFTP runtime має використовувати WMI/CIM fallback і не дублювати process-capture функції"
    Test-BRAVOCondition `
        -Condition (
            $archiveRuntimeText.Contains('function Get-BRAVOWinSCPDotNetComponents') -and
            -not $archiveScriptText.Contains('function Get-WinSCPDotNetComponents') -and
            -not $healthScriptText.Contains('function Get-WinSCPDotNetComponents')
        ) `
        -Name "Runtime/SharedWinSCPDotNetDiscovery" `
        -Failure "пошук WinSCP .NET components має мати одну реалізацію у BRAVO.ArchiveRuntime"
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains('BRAVO.ArchiveHelpers') -and
            $maintenanceScriptText.Contains('function Test-BRAVOMaintenanceSevenZipArchiveIntegrity') -and
            -not $maintenanceScriptText.Contains('function Test-SevenZipArchiveIntegrity')
        ) `
        -Name "Runtime/SharedSevenZipIntegrityHelper" `
        -Failure "Maintenance має використовувати спільну перевірку 7-Zip з ArchiveHelpers"
    $setupScriptText = [IO.File]::ReadAllText(
        (Join-Path $root "BRAVO_SETUP.ps1"),
        [Text.Encoding]::UTF8
    )
    Test-BRAVOCondition `
        -Condition ($setupScriptText.Contains('$requiresAdministrator = (-not $ValidateOnly) -and (')) `
        -Name "Setup/ValidateOnlyDoesNotRequireUac" `
        -Failure "BRAVO_SETUP -ValidateOnly не повинен вимагати UAC"

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
