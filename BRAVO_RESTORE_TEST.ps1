[CmdletBinding()]
param(
    [string]$ConfigPath,

    [ValidateSet("MODEL", "BLOG", "BRAVOEXCH", "All")]
    [string]$Component = "All",

    [int]$MinimumFileCount = 1,
    [int]$TimeoutSeconds = 3600,
    [string]$ResultPath,
    [switch]$AsJson,
    [switch]$SkipNotification,
    [switch]$NoElevation
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog `
    -ScriptPath $PSCommandPath `
    -ConfigPath $ConfigPath `
    -QuietConsole:$AsJson

# AUD-004 (аудит P0.4): restore drill. Читабельний і навіть SHA512/7za-
# перевірений архів НЕ доводить, що він відновлюється — лише що байти не
# пошкоджені. Цей скрипт бере найновіший локальний backup із коректним
# hash-sidecar для кожного увімкненого компонента (MODEL/BLOG/BRAVOEXCH),
# розпаковує його в ІЗОЛЬОВАНИЙ тимчасовий каталог (не production-шлях),
# рахує розпаковані файли/каталоги проти мінімального порогу, прибирає за
# собою і повертає JSON-результат + опційне сповіщення. Це read-only
# діагностика: не видаляє, не переміщує й не змінює жоден існуючий backup.

$ErrorActionPreference = "Stop"
$script:restoreDrillResults = New-Object System.Collections.ArrayList

function Add-RestoreDrillResult {
    param(
        [ValidateSet("PASS", "WARN", "FAIL")]
        [string]$Status,
        [string]$Component,
        [string]$ArchiveName,
        [Nullable[double]]$DurationSeconds,
        [int]$ExtractedFileCount = 0,
        [int]$ExtractedDirectoryCount = 0,
        [string]$Detail
    )

    [void]$script:restoreDrillResults.Add([pscustomobject]@{
        Status = $Status
        Component = $Component
        ArchiveName = $ArchiveName
        DurationSeconds = $DurationSeconds
        ExtractedFileCount = $ExtractedFileCount
        ExtractedDirectoryCount = $ExtractedDirectoryCount
        Detail = $Detail
        CheckedAt = (Get-Date).ToString("o")
    })
}

function Set-BRAVORestoreDrillDirectoryAcl {
    # Той самий патерн, що BRAVO_TASKS_DIAGNOSE.ps1 використовує для своїх
    # ізольованих робочих каталогів: лише SYSTEM і Administrators.
    param([string]$Path)

    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $none = [Security.AccessControl.PropagationFlags]::None
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
    # SYSTEM + Administrators (як у BRAVO_TASKS_DIAGNOSE.ps1) — захист
    # видобутих даних LIMS від інших користувачів машини. На відміну від
    # TASKS_DIAGNOSE, цей скрипт НЕ вимагає елевації (read-only diagnostic,
    # той самий підхід, що BRAVO_DRY_RUN.ps1), тому явно додаємо SID
    # поточного облікового запису — інакше неелевований адміністратор
    # (в групі Administrators, але без UAC split-token) втрачає доступ до
    # щойно створеного каталогу.
    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $accessSids = @("S-1-5-18", "S-1-5-32-544") + @([string]$currentUserSid) | Select-Object -Unique
    foreach ($sidText in $accessSids) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $none,
            $allow
        )))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Find-BRAVOLatestVerifiedArchive {
    # Найновіший *.mdz у каталозі, чий .sha512-sidecar існує й збігається
    # з фактичним хешем файлу — той самий алгоритм, що Remove-OldBackupSets
    # (BRAVO.Archive.Runtime.ps1) використовує для визначення "валідного"
    # набору при retention, лише тут беремо найсвіжіший, а не всі.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$ArchiveFilter,
        [Parameter(Mandatory = $true)][string]$HashFileExtension
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $null
    }
    $candidates = @(Get-BRAVOFiles -Path $Directory -Filter $ArchiveFilter |
        Sort-Object -Property LastWriteTime -Descending)
    foreach ($candidate in $candidates) {
        $hashPath = "$($candidate.FullName)$HashFileExtension"
        try {
            if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
                continue
            }
            $hashText = ([System.IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
            if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
                continue
            }
            if ($Matches.FileName -cne $candidate.Name) {
                continue
            }
            $expectedHash = $Matches.Hash.ToUpperInvariant()
            $actualHash = (Get-BRAVOFileHash -Path $candidate.FullName -Algorithm SHA512).Hash.ToUpperInvariant()
            if ($actualHash -cne $expectedHash) {
                continue
            }
            return $candidate
        } catch {
            continue
        }
    }
    return $null
}

try {
    $scriptDirectory = if ($PSCommandPath) {
        Split-Path $PSCommandPath -Parent
    } else {
        [Environment]::CurrentDirectory
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $scriptDirectory "BRAVO.config"
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "файл конфігурації не знайдено: $ConfigPath"
    }
    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path $resolvedConfigPath -Parent

    foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ExitCodes')) {
        $modulePath = Join-Path $configRoot "modules\$moduleName\$moduleName.psd1"
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Не знайдено спільний PowerShell-модуль: $modulePath"
        }
        Import-Module -Name $modulePath -ErrorAction Stop
    }
    $archiveHelpersPath = Join-Path $configRoot 'modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1'
    if (-not (Test-Path -LiteralPath $archiveHelpersPath -PathType Leaf)) {
        throw "Не знайдено PowerShell-модуль archive helpers: $archiveHelpersPath"
    }
    Import-Module -Name $archiveHelpersPath -ErrorAction Stop

    $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Не знайдено BRAVO_CONFIG_LOADER.ps1: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration -ConfigRoot $configRoot -ConfigPath $resolvedConfigPath

    if ([string]::IsNullOrWhiteSpace([string]$arcPath) -or
        -not (Test-Path -LiteralPath $arcPath -PathType Leaf)) {
        throw "7za.exe не знайдено: $arcPath"
    }

    $archiveCredentialTarget = [string]$credentialSettings.Targets.ArchivePassword
    if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
        $archiveCredentialTarget = "BRAVO_7Z_PASSWORD"
    }
    Initialize-BRAVOCredentialManager
    $archivePassword = Get-BRAVOCredentialSecret -Target $archiveCredentialTarget
    if ([string]::IsNullOrWhiteSpace($archivePassword)) {
        throw "пароль архіву не знайдено в Credential Manager (target '$archiveCredentialTarget') для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }

    $componentsToCheck = @($global:archiveDefinitions | Where-Object {
        [bool]$_.Enabled -and
        ($Component -eq "All" -or [string]$_.Type -eq $Component)
    })

    if ($componentsToCheck.Count -eq 0) {
        Add-RestoreDrillResult WARN $Component $null $null 0 0 (
            "жодного увімкненого компонента для перевірки (Component='$Component')"
        )
    }

    $drillRoot = Join-Path ([Environment]::GetFolderPath("CommonApplicationData")) "BRAVO\RestoreDrill"
    if (-not (Test-Path -LiteralPath $drillRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $drillRoot -Force)
    }

    foreach ($archiveDefinition in $componentsToCheck) {
        $componentName = [string]$archiveDefinition.Type
        $destinationDir = [string]$archiveDefinition.Destination
        $latestArchive = Find-BRAVOLatestVerifiedArchive `
            -Directory $destinationDir `
            -ArchiveFilter $global:archiveFileFilter `
            -HashFileExtension $global:hashFileExtension

        if ($null -eq $latestArchive) {
            Add-RestoreDrillResult WARN $componentName $null $null 0 0 (
                "жодного backup із коректним .sha512 не знайдено в '$destinationDir' — restore drill неможливий"
            )
            continue
        }

        $workingDirectory = Join-Path $drillRoot ([guid]::NewGuid().ToString("N"))
        $startedAt = Get-Date
        try {
            [void](New-Item -ItemType Directory -Path $workingDirectory -Force)
            Set-BRAVORestoreDrillDirectoryAcl -Path $workingDirectory

            $integrityOk = Test-SevenZipArchiveIntegrity `
                -SevenZipPath $arcPath `
                -ArchivePath $latestArchive.FullName `
                -Password $archivePassword `
                -TimeoutSeconds $TimeoutSeconds
            if (-not $integrityOk) {
                Add-RestoreDrillResult FAIL $componentName $latestArchive.Name (
                    ((Get-Date) - $startedAt).TotalSeconds
                ) 0 0 "7za t (перевірка цілісності) не пройдено"
                continue
            }

            $extractionResult = Invoke-BRAVOSevenZipExtraction `
                -SevenZipPath $arcPath `
                -ArchivePath $latestArchive.FullName `
                -Password $archivePassword `
                -ExtractDirectory $workingDirectory `
                -TimeoutSeconds $TimeoutSeconds
            if (-not $extractionResult.Success) {
                Add-RestoreDrillResult FAIL $componentName $latestArchive.Name (
                    ((Get-Date) - $startedAt).TotalSeconds
                ) 0 0 "розпакування не вдалося: $($extractionResult.Description)"
                continue
            }

            $extractedFiles = @(Get-ChildItem -LiteralPath $workingDirectory -Recurse -File -ErrorAction SilentlyContinue)
            $extractedDirectories = @(Get-ChildItem -LiteralPath $workingDirectory -Recurse -Directory -ErrorAction SilentlyContinue)
            $durationSeconds = ((Get-Date) - $startedAt).TotalSeconds

            if ($extractedFiles.Count -lt $MinimumFileCount) {
                Add-RestoreDrillResult FAIL $componentName $latestArchive.Name $durationSeconds `
                    $extractedFiles.Count $extractedDirectories.Count (
                    "розпаковано лише $($extractedFiles.Count) файл(ів), очікувалося щонайменше $MinimumFileCount — можлива архівація не того джерела"
                )
            } else {
                Add-RestoreDrillResult PASS $componentName $latestArchive.Name $durationSeconds `
                    $extractedFiles.Count $extractedDirectories.Count (
                    "успішно розпаковано й перевірено"
                )
            }
        } catch {
            Add-RestoreDrillResult FAIL $componentName $latestArchive.Name (
                ((Get-Date) - $startedAt).TotalSeconds
            ) 0 0 $_.Exception.Message
        } finally {
            if (Test-Path -LiteralPath $workingDirectory) {
                Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $SkipNotification) {
        $notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
        $failCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "FAIL" }).Count
        $warnCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "WARN" }).Count
        if ($notificationMode -ne "none" -and ($failCount -gt 0 -or $warnCount -gt 0)) {
            try {
                $notificationProvider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
                if ($notificationProvider -ne "discord" -and $notificationProvider -ne "slack") {
                    $notificationProvider = "discord"
                }
                $webhookTarget = if ($notificationProvider -eq "discord") {
                    [string]$credentialSettings.Targets.DiscordWebhook
                } else {
                    [string]$credentialSettings.Targets.SlackWebhook
                }
                $webhookUrl = Get-BRAVOCredentialSecret -Target $webhookTarget
                if (-not [string]::IsNullOrWhiteSpace($webhookUrl)) {
                    $summaryLines = @($script:restoreDrillResults | ForEach-Object {
                        "[$($_.Status)] $($_.Component): $($_.Detail)"
                    })
                    $message = (
                        "🧪 BRAVO RESTORE DRILL — $($env:COMPUTERNAME)`n" +
                        "FAIL: $failCount, WARN: $warnCount`n" +
                        ($summaryLines -join "`n")
                    )
                    Send-BRAVOWebhookNotification `
                        -Provider $notificationProvider `
                        -WebhookUrl $webhookUrl `
                        -Message $message
                }
            } catch {
                Add-RestoreDrillResult WARN "Сповіщення" $null $null 0 0 $_.Exception.Message
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $jsonResult = $script:restoreDrillResults | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($ResultPath, $jsonResult, (New-Object System.Text.UTF8Encoding($false)))
    }

    if ($AsJson) {
        $script:restoreDrillResults | ConvertTo-Json -Depth 5 | Write-Output
    } else {
        foreach ($result in $script:restoreDrillResults) {
            $color = switch ($result.Status) {
                "PASS" { "Green" }
                "WARN" { "Yellow" }
                "FAIL" { "Red" }
                default { "White" }
            }
            Write-Host "[$($result.Status)] $($result.Component) $($result.ArchiveName): $($result.Detail)" -ForegroundColor $color
        }
    }

    $failureCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "FAIL" }).Count
    $warningCount = @($script:restoreDrillResults | Where-Object { $_.Status -eq "WARN" }).Count
    $exitCode = Resolve-BRAVOExitCode `
        -IntegrityTestFailed:($failureCount -gt 0) `
        -HasWarnings:($warningCount -gt 0 -and $failureCount -eq 0)
    Complete-BRAVOHelperLog -ExitCode $exitCode
} catch {
    Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
    $fatalExitCode = if ($null -ne (Get-Command -Name Resolve-BRAVOExitCode -ErrorAction SilentlyContinue)) {
        Resolve-BRAVOExitCode -InternalError
    } else {
        90
    }
    Complete-BRAVOHelperLog -ExitCode $fatalExitCode
}
