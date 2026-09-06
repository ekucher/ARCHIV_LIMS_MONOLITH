[CmdletBinding()]
param(
    [string]$ConfigPath,

    # Add — лише створити новий запис; Update — лише змінити наявний;
    # Set — створити або змінити; Ensure — запросити лише відсутні записи;
    # Test — перевірити; Remove — видалити.
    [ValidateSet("Add", "Update", "Set", "Ensure", "Test", "Remove")]
    [string]$Action = "Set",

    [ValidateSet(
        "Required",
        "All",
        "SFTP",
        "SMB",
        "Slack",
        "Discord",
        "Slack.General",
        "Slack.Alerts",
        "Discord.General",
        "Discord.Alerts",
        "Archive",
        "Institution",
        "BRAVO_7Z_PASSWORD",
        "BRAVO_SFTP_LOGIN",
        "BRAVO_SFTP_PASSWORD",
        "BRAVO_SMB_LOGIN",
        "BRAVO_SMB_PASSWORD",
        "BRAVO_SLACK_GENERAL_URL",
        "BRAVO_SLACK_ALERTS_URL",
        "BRAVO_DISCORD_GENERAL_URL",
        "BRAVO_DISCORD_ALERTS_URL",
        "BRAVO_INSTITUTION_NAME",
        "BRAVO_INSTITUTION_CODE",
        "BRAVO_ARCHIVE_PREFIX"
    )]
    [string[]]$Component = @("All"),

    [ValidateSet("Both", "ScheduledTaskAccount", "CurrentUser")]
    [string]$StoreFor = "Both",

    [string]$ProtectedPayloadPath,

    [string]$ResultPath
)

$protectedWorkerMode = -not [string]::IsNullOrWhiteSpace($ProtectedPayloadPath)
$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog `
    -ScriptPath $PSCommandPath `
    -ConfigPath $ConfigPath `
    -QuietConsole:$protectedWorkerMode

# Лише для нового неінтерактивного заголовка/РЕЗУЛЬТАТ нижче — інтерактивне
# меню (Show-BRAVOCredentialMenu) лишається на власному Clear-Host-банері,
# не мігрується (докладніше — коментар біля використання).
$credentialsConsoleModulePath = Join-Path $PSScriptRoot "modules\BRAVO.Console\BRAVO.Console.psd1"
Import-Module -Name $credentialsConsoleModulePath -ErrorAction Stop

$interactiveMenuRequested = (
    -not $PSBoundParameters.ContainsKey("Action") -and
    -not $PSBoundParameters.ContainsKey("Component") -and
    [string]::IsNullOrWhiteSpace($ProtectedPayloadPath)
)
$storeForWasSpecified = $PSBoundParameters.ContainsKey("StoreFor")

# Пауза перед закриттям вікна — лише для окремого інтерактивного запуску
# (подвійний клік / ручний запуск меню), щоб оператор устиг прочитати
# РЕЗУЛЬТАТ. НЕ спрацьовує у worker-режимі (-ProtectedPayloadPath), при
# неінтерактивному CLI (-Action/-Component) — там $interactiveMenuRequested
# = $false — і в неінтерактивному хості (redirected stdin), щоб не підвісити
# батьківський процес чи Планувальник. Той самий самодостатній ідіом паузи,
# що Wait-BRAVOEarlyManualExit у BRAVO_MAINTENANCE/BRAVO_ARCHIV. Делегує до
# канонічного Complete-BRAVOHelperLog (яка й викликає exit) — цей файл
# єдиний, хто загортає її в паузу, тому спільний helper-модуль не чіпаємо.
function Complete-BRAVOCredentialSetup {
    param([Parameter(Mandatory = $true)][int]$ExitCode)
    if ($interactiveMenuRequested) {
        $canPause = $false
        try {
            $canPause = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        } catch {
            $canPause = $false
        }
        if ($canPause) {
            Write-Host ""
            Write-Host "Натиснiть будь-яку клавiшу для закриття вiкна..." -ForegroundColor Cyan
            try {
                [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            } catch {
                try {
                    [void](Read-Host)
                } catch {
                    # Немає способу почекати на ввід (нетиповий хост) — не привід падати.
                }
            }
        }
    }
    Complete-BRAVOHelperLog -ExitCode $ExitCode
}

$bravoScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Path $PSCommandPath -Parent
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

$compatibilityModulePath = Join-Path $bravoScriptDirectory "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1"
$systemModulePath = Join-Path $bravoScriptDirectory "modules\BRAVO.System\BRAVO.System.psd1"
if (-not (Test-Path -LiteralPath $compatibilityModulePath -PathType Leaf)) {
    Write-Error "Не знайдено модуль сумісності: $compatibilityModulePath"
    Complete-BRAVOCredentialSetup -ExitCode 1
}
try {
    Import-Module -Name $compatibilityModulePath -ErrorAction Stop
    Import-Module -Name $systemModulePath -ErrorAction Stop
    Assert-BRAVOPowerShellCompatibility
    [void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
    $script:BRAVOPowerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
} catch {
    Write-Error "Помилка сумісності: $($_.Exception.Message)"
    Complete-BRAVOCredentialSetup -ExitCode 1
}
if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
    Write-Warning $BRAVOPowerShellUpdate.Message
}
# Свіжість накопичувальних оновлень Windows — health-метрика, а не умова
# запуску. Її місце в BRAVO_HEALTH, який для цього й існує: тут вона лише
# додавала WARNING (а отже, ненульовий код завершення 10) до операції, на
# результат якої вік патчів не впливає жодним чином. Перевірки платформи
# (ОС, build, PowerShell, .NET, архітектура, API) лишаються на місці.
# P0 Configuration Foundation (PR C): свідомий намір оператора фіксується
# ТУТ, на межі справжнього виклику скрипта, ДО підстановки auto-дефолту.
$configPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

$ErrorActionPreference = "Stop"



function Test-IsSystemIdentity {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18"
}

function Get-BRAVOCredentialSetupConfiguration {
    param(
        [string]$Path,
        [switch]$PathWasExplicit
    )

    # P0 Configuration Foundation: BRAVO.config став опційним основним
    # override-шаром — попередня жорстка "файл мусить існувати" перевірка
    # (і Resolve-Path, який теж вимагав існування) дублювала те саме
    # рішення, яке Import-BravoConfiguration тепер приймає коректно сама.
    # GetFullPath (а не Resolve-Path) нормалізує шлях без вимоги існування.
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $root = Split-Path -Path $resolvedPath -Parent
    $configurationLoaderPath = Join-Path $bravoScriptDirectory 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration -ConfigRoot $root -ConfigPath $resolvedPath -RuntimeRoot $bravoScriptDirectory -ConfigPathWasExplicit:$PathWasExplicit

    if ($null -eq $credentialSettings -or
        [string]::IsNullOrWhiteSpace([string]$credentialSettings.HelperPath) -or
        -not (Test-Path -LiteralPath $credentialSettings.HelperPath -PathType Leaf)) {
        throw "Не знайдено модуль BRAVO.Credentials: $($credentialSettings.HelperPath)"
    }

    return $resolvedPath
}

function Resolve-RequestedComponents {
    $resolved = New-Object System.Collections.ArrayList

    foreach ($requestedComponent in $Component) {
        switch ($requestedComponent) {
            "Required" {
                if ($null -ne $bravoSettings.InstitutionName -and
                    $null -ne $bravoSettings.InstitutionCode -and
                    $null -ne $bravoSettings.ArchivePrefix -and
                    -not $resolved.Contains("Institution")) {
                    [void]$resolved.Add("Institution")
                }
                if (-not $resolved.Contains("Archive")) {
                    [void]$resolved.Add("Archive")
                }

                # componentSettings.SFTP.Enabled (5.2.2): master AND child
                # через canonical effective-шар. Фікс латентного 5.2.1-бага:
                # формула пропускала BAZA_WWW_SFTP (сервер лише з
                # WWW-синхронізацією не вважав SFTP-креденшели
                # обов'язковими) — $bazaSyncEffective.ScheduledSftpSyncRequired
                # покриває APP+WWW разом, той самий канонічний вираз, що
                # Archive/Health.
                $sftpRequired = [bool]$storageEffective.SFTP.Enabled -and (
                    [bool]$storageEffective.SFTP.ArchiveUpload -or
                    [bool]$bazaSyncEffective.ScheduledSftpSyncRequired -or
                    [bool]$backupMonitoring.SFTP.Enabled
                )
                if ($sftpRequired -and -not $resolved.Contains("SFTP")) {
                    [void]$resolved.Add("SFTP")
                }

                $smbRequired = [bool]$storageEffective.SMB.ArchiveCopy
                if ($smbRequired -and -not $resolved.Contains("SMB")) {
                    [void]$resolved.Add("SMB")
                }

                $notificationMode = ([string]$bravoSettings.NotificationMode).ToLowerInvariant()
                if ($notificationMode -ne "none") {
                    $configuredProvider = ([string]$bravoSettings.NotificationProvider).ToLowerInvariant()
                    $providerPrefix = if ($configuredProvider -eq "slack") { "Slack" } else { "Discord" }

                    # ALERTS потрібен завжди, доки NotificationMode != none
                    # (WARNING/ERROR/CRITICAL завжди туди маршрутизуються).
                    $alertsComponent = "$providerPrefix.Alerts"
                    if (-not $resolved.Contains($alertsComponent)) {
                        [void]$resolved.Add($alertsComponent)
                    }

                    # GENERAL потрібен лише коли SUCCESS реально туди
                    # доходить — тобто лише в режимі "all" (у errors_only
                    # SUCCESS завжди придушується).
                    if ($notificationMode -eq "all") {
                        $generalComponent = "$providerPrefix.General"
                        if (-not $resolved.Contains($generalComponent)) {
                            [void]$resolved.Add($generalComponent)
                        }
                    }
                }
            }
            "All" {
                # 5.2.1: legacy provider-wide групи "Slack"/"Discord"
                # виведені з контракту — обидва провайдери покривають
                # канальні General/Alerts записи нижче.
                $allNames = @(
                    "Archive", "SFTP", "SMB",
                    "Slack.General", "Slack.Alerts",
                    "Discord.General", "Discord.Alerts"
                )
                if ($null -ne $bravoSettings.InstitutionName -and
                    $null -ne $bravoSettings.InstitutionCode -and
                    $null -ne $bravoSettings.ArchivePrefix) {
                    $allNames = @("Institution") + $allNames
                }
                foreach ($name in $allNames) {
                    if (-not $resolved.Contains($name)) {
                        [void]$resolved.Add($name)
                    }
                }
            }
            default {
                if (-not $resolved.Contains($requestedComponent)) {
                    [void]$resolved.Add($requestedComponent)
                }
            }
        }
    }

    return $resolved.ToArray()
}

function Get-CredentialTarget {
    param([string]$Name)

    switch ($Name) {
        "SFTPLogin" { return $(if ($credentialSettings.Targets.SFTPLogin) { [string]$credentialSettings.Targets.SFTPLogin } else { "BRAVO_SFTP_LOGIN" }) }
        "SFTPPassword" { return $(if ($credentialSettings.Targets.SFTPPassword) { [string]$credentialSettings.Targets.SFTPPassword } else { "BRAVO_SFTP_PASSWORD" }) }
        "SMBLogin" { return $(if ($credentialSettings.Targets.SMBLogin) { [string]$credentialSettings.Targets.SMBLogin } else { "BRAVO_SMB_LOGIN" }) }
        "SMBPassword" { return $(if ($credentialSettings.Targets.SMBPassword) { [string]$credentialSettings.Targets.SMBPassword } else { "BRAVO_SMB_PASSWORD" }) }
        "Slack.General" { return $(if ($credentialSettings.Targets.SlackWebhookGeneral) { [string]$credentialSettings.Targets.SlackWebhookGeneral } else { "BRAVO_SLACK_GENERAL_URL" }) }
        "Slack.Alerts" { return $(if ($credentialSettings.Targets.SlackWebhookAlerts) { [string]$credentialSettings.Targets.SlackWebhookAlerts } else { "BRAVO_SLACK_ALERTS_URL" }) }
        "Discord.General" { return $(if ($credentialSettings.Targets.DiscordWebhookGeneral) { [string]$credentialSettings.Targets.DiscordWebhookGeneral } else { "BRAVO_DISCORD_GENERAL_URL" }) }
        "Discord.Alerts" { return $(if ($credentialSettings.Targets.DiscordWebhookAlerts) { [string]$credentialSettings.Targets.DiscordWebhookAlerts } else { "BRAVO_DISCORD_ALERTS_URL" }) }
        "Archive" { return $(if ($credentialSettings.Targets.ArchivePassword) { [string]$credentialSettings.Targets.ArchivePassword } else { "BRAVO_7Z_PASSWORD" }) }
        "InstitutionName" { return $(if ($credentialSettings.Targets.InstitutionName) { [string]$credentialSettings.Targets.InstitutionName } else { "BRAVO_INSTITUTION_NAME" }) }
        "InstitutionCode" { return $(if ($credentialSettings.Targets.InstitutionCode) { [string]$credentialSettings.Targets.InstitutionCode } else { "BRAVO_INSTITUTION_CODE" }) }
        "ArchivePrefix" { return $(if ($credentialSettings.Targets.ArchivePrefix) { [string]$credentialSettings.Targets.ArchivePrefix } else { "BRAVO_ARCHIVE_PREFIX" }) }
        default { throw "Невідомий компонент секрету: $Name" }
    }
}

function Get-CredentialDescriptors {
    param([string[]]$Names)

    $descriptors = New-Object System.Collections.ArrayList
    foreach ($name in $Names) {
        switch ($name) {
            "Institution" {
                foreach ($institutionDescriptor in @(
                    [pscustomobject]@{
                        Component = "BRAVO_INSTITUTION_NAME"
                        Target = Get-CredentialTarget -Name "InstitutionName"
                        Prompt = "Назва установи"
                        InputMode = "Text"
                        Validation = "InstitutionName"
                    },
                    [pscustomobject]@{
                        Component = "BRAVO_INSTITUTION_CODE"
                        Target = Get-CredentialTarget -Name "InstitutionCode"
                        Prompt = "Код установи"
                        InputMode = "Text"
                        Validation = "InstitutionCode"
                    },
                    [pscustomobject]@{
                        Component = "BRAVO_ARCHIVE_PREFIX"
                        Target = Get-CredentialTarget -Name "ArchivePrefix"
                        Prompt = "Префікс імен архівів"
                        InputMode = "Text"
                        Validation = "ArchivePrefix"
                    }
                )) {
                    [void]$descriptors.Add($institutionDescriptor)
                }
            }
            "SFTP" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SFTP_LOGIN"
                    Target = Get-CredentialTarget -Name "SFTPLogin"
                    Prompt = "SFTP логін"
                })
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SFTP_PASSWORD"
                    Target = Get-CredentialTarget -Name "SFTPPassword"
                    Prompt = "SFTP пароль"
                })
            }
            "SMB" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SMB_LOGIN"
                    Target = Get-CredentialTarget -Name "SMBLogin"
                    Prompt = "NAS/SMB логін (наприклад DOMAIN\user або NAS\user)"
                })
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SMB_PASSWORD"
                    Target = Get-CredentialTarget -Name "SMBPassword"
                    Prompt = "NAS/SMB пароль"
                })
            }
            "Slack" {
                # 5.2.1: логічна група "Slack" тепер означає ОБИДВА канальні
                # записи (GENERAL + ALERTS); legacy provider-wide webhook
                # виведений з контракту.
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "Slack.General"
                    Target = Get-CredentialTarget -Name "Slack.General"
                    Prompt = "Slack webhook — загальні повідомлення"
                })
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "Slack.Alerts"
                    Target = Get-CredentialTarget -Name "Slack.Alerts"
                    Prompt = "Slack webhook — проблеми та аварії"
                })
            }
            "Discord" {
                # 5.2.1: логічна група "Discord" тепер означає ОБИДВА
                # канальні записи (GENERAL + ALERTS); legacy provider-wide
                # webhook виведений з контракту.
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "Discord.General"
                    Target = Get-CredentialTarget -Name "Discord.General"
                    Prompt = "Discord webhook — загальні повідомлення"
                })
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "Discord.Alerts"
                    Target = Get-CredentialTarget -Name "Discord.Alerts"
                    Prompt = "Discord webhook — проблеми та аварії"
                })
            }
            "Slack.General" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "Slack.General"
                    Target = Get-CredentialTarget -Name "Slack.General"
                    Prompt = "Slack webhook — загальні повідомлення"
                })
            }
            "Slack.Alerts" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "Slack.Alerts"
                    Target = Get-CredentialTarget -Name "Slack.Alerts"
                    Prompt = "Slack webhook — проблеми та аварії"
                })
            }
            "Discord.General" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "Discord.General"
                    Target = Get-CredentialTarget -Name "Discord.General"
                    Prompt = "Discord webhook — загальні повідомлення"
                })
            }
            "Discord.Alerts" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "Discord.Alerts"
                    Target = Get-CredentialTarget -Name "Discord.Alerts"
                    Prompt = "Discord webhook — проблеми та аварії"
                })
            }
            "Archive" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_7Z_PASSWORD"
                    Target = Get-CredentialTarget -Name "Archive"
                    Prompt = "Пароль архівів 7-Zip (без префікса -p)"
                })
            }
            "BRAVO_7Z_PASSWORD" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_7Z_PASSWORD"
                    Target = Get-CredentialTarget -Name "Archive"
                    Prompt = "Пароль архівів 7-Zip (без префікса -p)"
                })
            }
            "BRAVO_SFTP_LOGIN" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SFTP_LOGIN"
                    Target = Get-CredentialTarget -Name "SFTPLogin"
                    Prompt = "SFTP логін"
                })
            }
            "BRAVO_SFTP_PASSWORD" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SFTP_PASSWORD"
                    Target = Get-CredentialTarget -Name "SFTPPassword"
                    Prompt = "SFTP пароль"
                })
            }
            "BRAVO_SMB_LOGIN" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SMB_LOGIN"
                    Target = Get-CredentialTarget -Name "SMBLogin"
                    Prompt = "NAS/SMB логін (наприклад DOMAIN\user або NAS\user)"
                })
            }
            "BRAVO_SMB_PASSWORD" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SMB_PASSWORD"
                    Target = Get-CredentialTarget -Name "SMBPassword"
                    Prompt = "NAS/SMB пароль"
                })
            }
            "BRAVO_SLACK_GENERAL_URL" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SLACK_GENERAL_URL"
                    Target = Get-CredentialTarget -Name "Slack.General"
                    Prompt = "Slack webhook — загальні повідомлення"
                })
            }
            "BRAVO_SLACK_ALERTS_URL" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SLACK_ALERTS_URL"
                    Target = Get-CredentialTarget -Name "Slack.Alerts"
                    Prompt = "Slack webhook — проблеми та аварії"
                })
            }
            "BRAVO_DISCORD_GENERAL_URL" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_DISCORD_GENERAL_URL"
                    Target = Get-CredentialTarget -Name "Discord.General"
                    Prompt = "Discord webhook — загальні повідомлення"
                })
            }
            "BRAVO_DISCORD_ALERTS_URL" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_DISCORD_ALERTS_URL"
                    Target = Get-CredentialTarget -Name "Discord.Alerts"
                    Prompt = "Discord webhook — проблеми та аварії"
                })
            }
            "BRAVO_INSTITUTION_NAME" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_INSTITUTION_NAME"
                    Target = Get-CredentialTarget -Name "InstitutionName"
                    Prompt = "Назва установи"
                    InputMode = "Text"
                    Validation = "InstitutionName"
                })
            }
            "BRAVO_INSTITUTION_CODE" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_INSTITUTION_CODE"
                    Target = Get-CredentialTarget -Name "InstitutionCode"
                    Prompt = "Код установи"
                    InputMode = "Text"
                    Validation = "InstitutionCode"
                })
            }
            "BRAVO_ARCHIVE_PREFIX" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_ARCHIVE_PREFIX"
                    Target = Get-CredentialTarget -Name "ArchivePrefix"
                    Prompt = "Префікс імен архівів"
                    InputMode = "Text"
                    Validation = "ArchivePrefix"
                })
            }
        }
    }

    # Якщо одночасно вказано групу та окремий запис із цієї групи,
    # операція над одним target виконується лише один раз.
    $uniqueDescriptors = New-Object System.Collections.ArrayList
    $seenTargets = @()
    foreach ($descriptor in $descriptors) {
        if ($seenTargets -contains [string]$descriptor.Target) {
            continue
        }
        $seenTargets += [string]$descriptor.Target
        [void]$uniqueDescriptors.Add($descriptor)
    }
    return $uniqueDescriptors.ToArray()
}

function Protect-SecureStringForLocalMachine {
    param([Security.SecureString]$SecureValue)

    Add-Type -AssemblyName System.Security
    $plainPointer = [IntPtr]::Zero
    $plainBytes = $null
    try {
        $plainPointer = [Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($SecureValue)
        $plainBytes = New-Object byte[] ($SecureValue.Length * 2)
        [Runtime.InteropServices.Marshal]::Copy($plainPointer, $plainBytes, 0, $plainBytes.Length)
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        try {
            return [Convert]::ToBase64String($protectedBytes)
        } finally {
            [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        }
    } finally {
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
        if ($plainPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($plainPointer)
        }
    }
}

function Unprotect-LocalMachineSecret {
    param([string]$ProtectedValue)

    Add-Type -AssemblyName System.Security
    $protectedBytes = [Convert]::FromBase64String($ProtectedValue)
    $plainBytes = $null
    try {
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        if (($plainBytes.Length % 2) -ne 0) {
            throw "Пошкоджені захищені дані секрету"
        }

        $secureValue = New-Object Security.SecureString
        for ($index = 0; $index -lt $plainBytes.Length; $index += 2) {
            $characterCode = [int]$plainBytes[$index] -bor ([int]$plainBytes[$index + 1] -shl 8)
            $secureValue.AppendChar([char]$characterCode)
        }
        $secureValue.MakeReadOnly()
        return $secureValue
    } finally {
        [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    }
}

function Read-SecretEntries {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Секрет щойно введений оператором у консолі й одразу записується в Credential Manager; SecureString — формат зберігання, а не джерело.')]
    param([string[]]$Names)

    # Оператор має бачити, що набирає: помилку в значенні (зайвий пробіл, не
    # та розкладка) за зірочками не видно, і вона спливає пізніше як відмова
    # автентифікації SFTP — далеко від місця, де її припустилися.
    #
    # Відкритий ввід дозволений ЛИШЕ тоді, коли доведено, що значення не
    # осяде в журналі: helper-лог — це дослівний Start-Transcript, тому
    # (1) власний transcript цього процесу має піддаватися паузі (перевіряє
    # canary у Test-BRAVOHelperLogSuspensionEffective — не припущення про
    # версію PowerShell, а фактична перевірка на цьому хості), і
    # (2) батьківський BRAVO_SETUP має підтвердити, що зупинив СВІЙ transcript,
    # інакше він захопить наш стрім у свій лог.
    # Не виконано хоч одну умову -> fail-closed: ввід лишається прихованим.
    $parentLogSuspended = ($env:BRAVO_PARENT_LOG_SUSPENDED -eq '1')
    $plainInputAllowed = $parentLogSuspended -and (Test-BRAVOHelperLogSuspensionEffective)
    if (-not $plainInputAllowed) {
        Write-Host (
            "Ввід лишається прихованим: не підтверджено, що значення не потрапить у журнал."
        ) -ForegroundColor DarkGray
    }

    $entries = New-Object System.Collections.ArrayList
    $logSuspended = $false
    if ($plainInputAllowed) {
        $logSuspended = Suspend-BRAVOHelperLog
        if (-not $logSuspended) {
            # Canary щойно казав, що пауза працює, а вона не спрацювала —
            # довіряємо фактові, а не попередній перевірці.
            $plainInputAllowed = $false
        }
    }
    try {
    foreach ($descriptor in @(Get-CredentialDescriptors -Names $Names)) {
        if ([string]::IsNullOrWhiteSpace([string]$descriptor.Target)) {
            throw "Для $($descriptor.Component) не налаштовано назву запису Credential Manager"
        }

        $secret = if ($plainInputAllowed) {
            $plainValue = Read-Host ([string]$descriptor.Prompt)
            # Валідація застосовується лише там, де для значення взагалі є
            # предметне правило (назва/код установи, префікс). Для паролів і
            # webhook-ів такого правила немає — там єдина осмислена перевірка
            # (непорожність) виконується нижче, спільно для всіх гілок.
            $normalizedValue = if ([string]::IsNullOrWhiteSpace([string]$descriptor.Validation)) {
                [string]$plainValue
            } else {
                Test-BRAVOInstitutionSettingValue `
                    -Name ([string]$descriptor.Validation) `
                    -Value ([string]$plainValue)
            }
            try {
                ConvertTo-SecureString -String $normalizedValue -AsPlainText -Force
            } finally {
                $plainValue = $null
                $normalizedValue = $null
            }
        } elseif ([string]$descriptor.InputMode -eq "Text") {
            $plainValue = Read-Host ([string]$descriptor.Prompt)
            $normalizedValue = Test-BRAVOInstitutionSettingValue `
                -Name ([string]$descriptor.Validation) `
                -Value ([string]$plainValue)
            try {
                ConvertTo-SecureString -String $normalizedValue -AsPlainText -Force
            } finally {
                $plainValue = $null
                $normalizedValue = $null
            }
        } else {
            Read-Host ([string]$descriptor.Prompt) -AsSecureString
        }
        if ($null -eq $secret -or $secret.Length -eq 0) {
            throw "$($descriptor.Prompt) не може бути порожнім"
        }

        [void]$entries.Add([pscustomobject]@{
            Component = [string]$descriptor.Component
            Target = [string]$descriptor.Target
            UserName = [string]$descriptor.Component
            SecureSecret = $secret
        })
    }
    } finally {
        # finally обов'язковий: без нього виняток під час вводу лишив би
        # журнал вимкненим до кінця процесу, і решта кроків не записалась би.
        if ($logSuspended) {
            [void](Resume-BRAVOHelperLog)
        }
    }
    return $entries.ToArray()
}

function New-OperationEntries {
    param([string[]]$Names)

    return @(Get-CredentialDescriptors -Names $Names | ForEach-Object {
        [pscustomobject]@{
            Component = [string]$_.Component
            Target = [string]$_.Target
            UserName = ""
            SecureSecret = $null
        }
    })
}

function Copy-OperationEntries {
    param([object[]]$Entries)

    return @($Entries | ForEach-Object {
        $secureSecretCopy = if ($null -ne $_.SecureSecret) {
            $_.SecureSecret.Copy()
        } else {
            $null
        }
        [pscustomobject]@{
            Component = [string]$_.Component
            Target = [string]$_.Target
            UserName = [string]$_.UserName
            SecureSecret = $secureSecretCopy
        }
    })
}

function Clear-OperationEntries {
    param([object[]]$Entries)

    foreach ($entry in @($Entries)) {
        if ($null -ne $entry.SecureSecret) {
            $entry.SecureSecret.Dispose()
            $entry.SecureSecret = $null
        }
    }
}

function Set-OperationResultScope {
    param(
        [object[]]$Results,
        [string]$Scope
    )

    foreach ($result in @($Results)) {
        $result | Add-Member -MemberType NoteProperty -Name Scope -Value $Scope -Force
    }
    return @($Results)
}

function Invoke-CredentialOperations {
    param(
        [string]$Operation,
        [object[]]$Entries
    )

    $results = New-Object System.Collections.ArrayList
    foreach ($entry in $Entries) {
        try {
            switch ($Operation) {
                "Add" {
                    $storedCredential = Get-BRAVOCredential -Target ([string]$entry.Target)
                    if ($null -ne $storedCredential) {
                        $storedCredential = $null
                        throw "запис '$($entry.Target)' уже існує; використайте -Action Update або Set"
                    }
                    Set-BRAVOCredential `
                        -Target ([string]$entry.Target) `
                        -UserName ([string]$entry.UserName) `
                        -Secret $entry.SecureSecret
                    $status = "Added"
                }
                "Update" {
                    $storedCredential = Get-BRAVOCredential -Target ([string]$entry.Target)
                    if ($null -eq $storedCredential) {
                        throw "запис '$($entry.Target)' не знайдено; використайте -Action Add або Set"
                    }
                    $storedCredential = $null
                    Set-BRAVOCredential `
                        -Target ([string]$entry.Target) `
                        -UserName ([string]$entry.UserName) `
                        -Secret $entry.SecureSecret
                    $status = "Updated"
                }
                "Set" {
                    $storedCredential = Get-BRAVOCredential -Target ([string]$entry.Target)
                    $status = if ($null -eq $storedCredential) { "Added" } else { "Updated" }
                    $storedCredential = $null
                    Set-BRAVOCredential `
                        -Target ([string]$entry.Target) `
                        -UserName ([string]$entry.UserName) `
                        -Secret $entry.SecureSecret
                }
                "Test" {
                    $storedCredential = Get-BRAVOCredential -Target ([string]$entry.Target)
                    $status = if ($null -ne $storedCredential -and
                        -not [string]::IsNullOrWhiteSpace([string]$storedCredential.Secret)) {
                        "Found"
                    } else {
                        "Missing"
                    }
                    if ($status -eq "Found") {
                        $institutionSettingName = switch ([string]$entry.Component) {
                            "BRAVO_INSTITUTION_NAME" { "InstitutionName" }
                            "BRAVO_INSTITUTION_CODE" { "InstitutionCode" }
                            "BRAVO_ARCHIVE_PREFIX" { "ArchivePrefix" }
                            default { $null }
                        }
                        if ($institutionSettingName) {
                            [void](Test-BRAVOInstitutionSettingValue `
                                -Name $institutionSettingName `
                                -Value ([string]$storedCredential.Secret))
                        }
                    }
                    $storedCredential = $null
                }
                "Remove" {
                    $removed = Remove-BRAVOCredential -Target ([string]$entry.Target)
                    $status = if ($removed) { "Removed" } else { "Missing" }
                }
            }

            [void]$results.Add([pscustomobject]@{
                Component = [string]$entry.Component
                Target = [string]$entry.Target
                Status = $status
                Error = $null
            })
        } catch {
            [void]$results.Add([pscustomobject]@{
                Component = [string]$entry.Component
                Target = [string]$entry.Target
                Status = "Error"
                Error = $_.Exception.Message
            })
        } finally {
            if ($null -ne $entry.SecureSecret) {
                $entry.SecureSecret.Dispose()
            }
        }
    }
    return $results.ToArray()
}

function Get-CredentialOperationSnapshots {
    param([object[]]$Entries)

    return @($Entries | ForEach-Object {
        $stored = Get-BRAVOCredential -Target ([string]$_.Target)
        [pscustomobject]@{
            Component = [string]$_.Component
            Target = [string]$_.Target
            Existed = $null -ne $stored
            UserName = if ($null -ne $stored) { [string]$stored.UserName } else { "" }
            Secret = if ($null -ne $stored) { [string]$stored.Secret } else { $null }
        }
    })
}

function Restore-CredentialOperationSnapshots {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Rollback раніше збереженого запису Credential Manager — секрет уже походив звідти.')]
    param([object[]]$Snapshots)

    $restoreErrors = New-Object System.Collections.ArrayList
    foreach ($snapshot in $Snapshots) {
        try {
            if ($snapshot.Existed) {
                $secureSecret = ConvertTo-SecureString `
                    -String ([string]$snapshot.Secret) `
                    -AsPlainText `
                    -Force
                try {
                    Set-BRAVOCredential `
                        -Target ([string]$snapshot.Target) `
                        -UserName ([string]$snapshot.UserName) `
                        -Secret $secureSecret
                } finally {
                    $secureSecret.Dispose()
                }
            } else {
                [void](Remove-BRAVOCredential -Target ([string]$snapshot.Target))
            }
        } catch {
            [void]$restoreErrors.Add([pscustomobject]@{
                Component = [string]$snapshot.Component
                Target = [string]$snapshot.Target
                Status = "Error"
                Error = "rollback не виконано: $($_.Exception.Message)"
            })
        }
    }
    return $restoreErrors.ToArray()
}

function Clear-CredentialOperationSnapshots {
    param([object[]]$Snapshots)
    foreach ($snapshot in @($Snapshots)) {
        $snapshot.Secret = $null
    }
}

function Invoke-CredentialOperationsTransactional {
    param(
        [string]$Operation,
        [object[]]$Entries
    )

    if ($Operation -eq "Test") {
        return @(Invoke-CredentialOperations -Operation $Operation -Entries $Entries)
    }
    $snapshots = @(Get-CredentialOperationSnapshots -Entries $Entries)
    $results = @(Invoke-CredentialOperations -Operation $Operation -Entries $Entries)
    if (@($results | Where-Object { $_.Status -eq "Error" }).Count -gt 0) {
        $results += @(Restore-CredentialOperationSnapshots -Snapshots $snapshots)
    }
    Clear-CredentialOperationSnapshots -Snapshots $snapshots
    return $results
}

function Write-OperationResults {
    param([object[]]$Results)

    foreach ($result in $Results) {
        $color = switch ($result.Status) {
            { $_ -in @("Added", "Updated", "Stored", "Found", "Removed") } { "Green"; break }
            "Missing" { "Yellow"; break }
            default { "Red" }
        }
        $scopePrefix = if ($result.Scope) { "[$($result.Scope)] " } else { "" }
        $message = "$scopePrefix$($result.Component): $($result.Status) [$($result.Target)]"
        if ($result.Error) {
            $message += " — $($result.Error)"
        }
        Write-Host $message -ForegroundColor $color
    }
}

# Фінальний РЕЗУЛЬТАТ неінтерактивного шляху (docs/OPERATOR_CONSOLE_UX.md
# §8) — Credentials UX ніколи не показує значення секрету: тут, як і в
# Write-OperationResults вище, друкуються лише Component/Target (назва
# запису Credential Manager, не сам секрет)/Status/Scope.
function Write-BRAVOCredentialResultBlock {
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        [Parameter(Mandatory = $true)][string]$Action
    )

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $scopeLabelFor = {
        param($scopeValue)
        if ([string]$scopeValue -eq $currentIdentity) { return 'Поточний користувач' }
        if ([string]$scopeValue -eq 'SYSTEM') { return 'NT AUTHORITY\SYSTEM' }
        return [string]$scopeValue
    }

    # Групування за Scope у порядку появи — той самий порядок, у якому
    # $operationResults уже збирає Set-OperationResultScope (спершу
    # поточний користувач, потім SYSTEM).
    $scopeOrder = New-Object System.Collections.Generic.List[string]
    $scopeGroups = @{}
    foreach ($result in $Results) {
        $scopeKey = [string]$result.Scope
        if (-not $scopeGroups.ContainsKey($scopeKey)) {
            $scopeGroups[$scopeKey] = New-Object System.Collections.Generic.List[object]
            $scopeOrder.Add($scopeKey)
        }
        $scopeGroups[$scopeKey].Add($result)
    }

    Write-Host ''
    Write-Host 'Credential Manager:'
    foreach ($scopeKey in $scopeOrder) {
        # Set-OperationResultScope викликається лише тоді, коли справді
        # опитується більше одного scope (Both/SYSTEM-worker) — при
        # -StoreFor CurrentUser/ScheduledTaskAccount окремо .Scope на
        # результатах узагалі немає, і підзаголовок групи був би порожнім.
        if (-not [string]::IsNullOrWhiteSpace($scopeKey)) {
            Write-BRAVOResultBlankLine
            Write-Host ("  {0}" -f (& $scopeLabelFor $scopeKey))
        }
        foreach ($result in $scopeGroups[$scopeKey]) {
            $entryLabel = [string]$result.Target
            if ([string]::IsNullOrWhiteSpace($entryLabel)) {
                $entryLabel = [string]$result.Component
            }
            $dots = '.' * [math]::Max(1, 34 - $entryLabel.Length)
            $entryColor = switch ($result.Status) {
                { $_ -in @('Added', 'Updated', 'Stored', 'Found', 'Removed') } { [ConsoleColor]::Green }
                'Missing' { [ConsoleColor]::Yellow }
                default { [ConsoleColor]::Red }
            }
            Write-Host ("    {0} {1} " -f $entryLabel, $dots) -NoNewline
            Write-Host ([string]$result.Status).ToUpperInvariant() -ForegroundColor $entryColor
            if ($result.Error) {
                Write-BRAVOConsoleDetail -Message $result.Error -Color ([ConsoleColor]::Red)
            }
        }
    }

    $successCount = @($Results | Where-Object { $_.Status -in @('Added', 'Updated', 'Stored', 'Found', 'Removed') }).Count
    $missingCount = @($Results | Where-Object { $_.Status -eq 'Missing' }).Count
    $errorCount = @($Results | Where-Object { $_.Status -eq 'Error' }).Count
    $credentialStatus = if ($errorCount -gt 0) {
        'ПОМИЛКА'
    } elseif ($missingCount -gt 0) {
        'ПОТРЕБУЄ УВАГИ'
    } else {
        'УСПІШНО'
    }
    $credentialStatusColor = switch ($credentialStatus) {
        'УСПІШНО' { [ConsoleColor]::Green }
        'ПОТРЕБУЄ УВАГИ' { [ConsoleColor]::Yellow }
        default { [ConsoleColor]::Red }
    }

    Write-BRAVOResultBlankLine
    Write-BRAVOSeparator
    Write-Host ' РЕЗУЛЬТАТ'
    Write-BRAVOSeparator
    Write-BRAVOResultField -Label 'Статус' -Value $credentialStatus -Color $credentialStatusColor
    if ($Action -eq 'Test') {
        Write-BRAVOResultField -Label 'Знайдено' -Value ([string]$successCount)
        Write-BRAVOResultField -Label 'Відсутні' -Value ([string]$missingCount)
    } else {
        Write-BRAVOResultField -Label 'Успішно' -Value ([string]$successCount)
        if ($missingCount -gt 0) {
            Write-BRAVOResultField -Label 'Відсутні' -Value ([string]$missingCount)
        }
    }
    if ($errorCount -gt 0) {
        Write-BRAVOResultField -Label 'Помилок' -Value ([string]$errorCount)
    }
    if ($missingCount -gt 0) {
        Write-BRAVOResultBlankLine
        Write-Host 'Відсутній запис:'
        foreach ($result in @($Results | Where-Object { $_.Status -eq 'Missing' })) {
            if ([string]::IsNullOrWhiteSpace([string]$result.Scope)) {
                Write-Host ("  {0}" -f $result.Target)
            } else {
                Write-Host ("  {0} -> {1}" -f (& $scopeLabelFor $result.Scope), $result.Target)
            }
        }
    }
    Write-BRAVOSeparator
}

function Read-BRAVOMenuNumber {
    param(
        [string]$Prompt,
        [int[]]$AllowedValues
    )

    while ($true) {
        $rawValue = Read-Host $Prompt
        $number = 0
        if ([int]::TryParse($rawValue, [ref]$number) -and
            $AllowedValues -contains $number) {
            return $number
        }
        Write-Host "Некоректний вибір. Введіть номер пункту меню." -ForegroundColor Yellow
    }
}

function Show-BRAVOCredentialMenu {
    param(
        [string]$InitialStoreFor,
        [bool]$AskForStore
    )

    $actionItems = @(
        [pscustomobject]@{ Number = 1; Value = "Add"; Label = "Додати новий запис" },
        [pscustomobject]@{ Number = 2; Value = "Update"; Label = "Змінити наявний запис" },
        [pscustomobject]@{ Number = 3; Value = "Set"; Label = "Додати або змінити запис" },
        [pscustomobject]@{ Number = 4; Value = "Test"; Label = "Перевірити наявність запису" },
        [pscustomobject]@{ Number = 5; Value = "Remove"; Label = "Видалити запис" }
    )
    $targetItems = @(
        [pscustomobject]@{ Number = 1; Value = "Required"; Label = "Лише записи для увімкнених компонентів" },
        [pscustomobject]@{ Number = 2; Value = "All"; Label = "Усі записи" },
        [pscustomobject]@{ Number = 3; Value = "Institution"; Label = "Установа, код і префікс архівів" },
        [pscustomobject]@{ Number = 4; Value = "Archive"; Label = "Архіви 7-Zip" },
        [pscustomobject]@{ Number = 5; Value = "SFTP"; Label = "SFTP — логін і пароль" },
        [pscustomobject]@{ Number = 6; Value = "SMB"; Label = "NAS/SMB — логін і пароль" },
        [pscustomobject]@{ Number = 7; Value = "Slack"; Label = "Slack WebHook" },
        [pscustomobject]@{ Number = 8; Value = "Discord"; Label = "Discord WebHook" },
        [pscustomobject]@{ Number = 9; Value = "BRAVO_7Z_PASSWORD"; Label = "BRAVO_7Z_PASSWORD" },
        [pscustomobject]@{ Number = 10; Value = "BRAVO_SFTP_LOGIN"; Label = "BRAVO_SFTP_LOGIN" },
        [pscustomobject]@{ Number = 11; Value = "BRAVO_SFTP_PASSWORD"; Label = "BRAVO_SFTP_PASSWORD" },
        [pscustomobject]@{ Number = 12; Value = "BRAVO_SMB_LOGIN"; Label = "BRAVO_SMB_LOGIN" },
        [pscustomobject]@{ Number = 13; Value = "BRAVO_SMB_PASSWORD"; Label = "BRAVO_SMB_PASSWORD" },
        [pscustomobject]@{ Number = 14; Value = "BRAVO_INSTITUTION_NAME"; Label = "BRAVO_INSTITUTION_NAME" },
        [pscustomobject]@{ Number = 15; Value = "BRAVO_INSTITUTION_CODE"; Label = "BRAVO_INSTITUTION_CODE" },
        [pscustomobject]@{ Number = 16; Value = "BRAVO_ARCHIVE_PREFIX"; Label = "BRAVO_ARCHIVE_PREFIX" },
        [pscustomobject]@{ Number = 17; Value = "Slack.General"; Label = "Slack webhook — загальні повідомлення" },
        [pscustomobject]@{ Number = 18; Value = "Slack.Alerts"; Label = "Slack webhook — проблеми та аварії" },
        [pscustomobject]@{ Number = 19; Value = "Discord.General"; Label = "Discord webhook — загальні повідомлення" },
        [pscustomobject]@{ Number = 20; Value = "Discord.Alerts"; Label = "Discord webhook — проблеми та аварії" }
    )

    :ActionMenu while ($true) {
        try {
            Clear-Host
        } catch {
            # Не всі PowerShell-hosts підтримують очищення консолі.
        }
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host " BRAVO — КЕРУВАННЯ WINDOWS CREDENTIAL MANAGER" -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host "Виберіть операцію:" -ForegroundColor White
        foreach ($item in $actionItems) {
            Write-Host (" {0}. {1}" -f $item.Number, $item.Label)
        }
        Write-Host " 0. Вихід"

        $actionNumber = Read-BRAVOMenuNumber `
            -Prompt "Операція" `
            -AllowedValues @(0, 1, 2, 3, 4, 5)
        if ($actionNumber -eq 0) {
            return $null
        }
        $selectedAction = @($actionItems | Where-Object { $_.Number -eq $actionNumber })[0]

        :TargetMenu while ($true) {
            Write-Host ""
            Write-Host "Виберіть групу або окремий запис:" -ForegroundColor White
            foreach ($item in $targetItems) {
                Write-Host (" {0}. {1}" -f $item.Number, $item.Label)
            }
            Write-Host " 0. Назад"

            $targetNumber = Read-BRAVOMenuNumber `
                -Prompt "Запис" `
                -AllowedValues @(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20)
            if ($targetNumber -eq 0) {
                continue ActionMenu
            }
            $selectedTarget = @($targetItems | Where-Object { $_.Number -eq $targetNumber })[0]
            $selectedStore = $InitialStoreFor

            if ($AskForStore) {
                Write-Host ""
                Write-Host "Виберіть сховище облікових даних:" -ForegroundColor White
                Write-Host " 1. Поточний користувач"
                Write-Host " 2. Обліковий запис Планувальника: $($schedulerSettings.RunAsUser)"
                Write-Host " 3. Обидва сховища (рекомендовано)"
                Write-Host " 0. Назад"
                $storeNumber = Read-BRAVOMenuNumber `
                    -Prompt "Сховище" `
                    -AllowedValues @(0, 1, 2, 3)
                if ($storeNumber -eq 0) {
                    continue TargetMenu
                }
                $selectedStore = switch ($storeNumber) {
                    1 { "CurrentUser" }
                    2 { "ScheduledTaskAccount" }
                    3 { "Both" }
                }
            }

            Write-Host ""
            Write-Host "Операція: $($selectedAction.Label)" -ForegroundColor Cyan
            Write-Host "Запис: $($selectedTarget.Label)" -ForegroundColor Cyan
            Write-Host "Сховище: $selectedStore" -ForegroundColor Cyan

            if ($selectedAction.Value -eq "Remove") {
                Write-Host "УВАГА: вибрані записи буде видалено з Credential Manager." -ForegroundColor Red
                $confirmation = Read-Host "Для підтвердження введіть DELETE"
                if ($confirmation -cne "DELETE") {
                    Write-Host "Видалення скасовано." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue TargetMenu
                }
            }

            return [pscustomobject]@{
                Action = [string]$selectedAction.Value
                Component = [string]$selectedTarget.Value
                StoreFor = [string]$selectedStore
            }
        }
    }
}

function Set-PrivateDirectoryAcl {
    param([string]$Path)

    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
    $administratorsSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($sid in @($currentUserSid, $systemSid, $administratorsSid)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-AsSystem {
    param(
        [string]$ResolvedConfigPath,
        # Намір оператора зі справжньої межі виклику скрипта: AUTO ->
        # worker НЕ отримує -ConfigPath і сам виконує ту саму
        # auto-derivation проти каталогу $PSCommandPath (той самий
        # комплект); EXPLICIT -> точний шлях зберігається. Безумовний
        # -ConfigPath перетворював легітимний AUTO no-config на
        # explicit-missing і валив worker fail-closed (acceptance CF-17).
        [bool]$ConfigPathWasExplicit = $false,
        [string]$Operation,
        [object[]]$Entries
    )

    $setupRoot = Join-Path ([Environment]::GetFolderPath("CommonApplicationData")) "BRAVO\CredentialSetup"
    if (-not (Test-Path -LiteralPath $setupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $setupRoot -Force | Out-Null
    }

    $operationId = [guid]::NewGuid().ToString("N")
    $workingDirectory = Join-Path $setupRoot $operationId
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    Set-PrivateDirectoryAcl -Path $workingDirectory

    $payloadPath = Join-Path $workingDirectory "payload.json"
    $workerResultPath = Join-Path $workingDirectory "result.json"
    $taskName = "BRAVO_CREDENTIAL_SETUP_$operationId"
    $taskService = New-Object -ComObject "Schedule.Service"
    $taskService.Connect()
    $rootTaskFolder = $taskService.GetFolder("\")

    try {
        $payloadEntries = @($Entries | ForEach-Object {
            $protectedSecret = if ($Operation -in @("Add", "Update", "Set")) {
                Protect-SecureStringForLocalMachine -SecureValue $_.SecureSecret
            } else {
                $null
            }
            if ($null -ne $_.SecureSecret) {
                $_.SecureSecret.Dispose()
                $_.SecureSecret = $null
            }
            [pscustomobject]@{
                Component = $_.Component
                Target = $_.Target
                UserName = $_.UserName
                ProtectedSecret = $protectedSecret
            }
        })
        $payload = @{
            Action = $Operation
            Entries = $payloadEntries
        } | ConvertTo-BRAVOJson -Depth 6
        [IO.File]::WriteAllText($payloadPath, $payload, [Text.Encoding]::UTF8)

        $powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $workerConfigArgumentText = if ($ConfigPathWasExplicit) {
            " -ConfigPath `"$ResolvedConfigPath`""
        } else {
            ""
        }
        $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
            "-File `"$PSCommandPath`"$workerConfigArgumentText " +
            "-ProtectedPayloadPath `"$payloadPath`" -ResultPath `"$workerResultPath`""
        $taskDefinition = $taskService.NewTask(0)
        $taskDefinition.RegistrationInfo.Description = "BRAVO temporary credential worker"
        $taskDefinition.Principal.UserId = "SYSTEM"
        $taskDefinition.Principal.LogonType = 5 # TASK_LOGON_SERVICE_ACCOUNT
        $taskDefinition.Principal.RunLevel = 1 # TASK_RUNLEVEL_HIGHEST
        $taskDefinition.Settings.Enabled = $true
        $taskDefinition.Settings.ExecutionTimeLimit = "PT2M"
        $taskDefinition.Settings.DisallowStartIfOnBatteries = $false
        $taskDefinition.Settings.StopIfGoingOnBatteries = $false
        $taskAction = $taskDefinition.Actions.Create(0) # TASK_ACTION_EXEC
        $taskAction.Path = $powerShellPath
        $taskAction.Arguments = $arguments
        $taskAction.WorkingDirectory = Split-Path -Path $PSCommandPath -Parent

        $registeredTask = $rootTaskFolder.RegisterTaskDefinition(
            $taskName,
            $taskDefinition,
            6,
            "SYSTEM",
            $null,
            5,
            $null
        )
        [void]$registeredTask.Run($null)

        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $workerResultPath -PathType Leaf)) {
            Start-Sleep -Milliseconds 250
        }
        if (-not (Test-Path -LiteralPath $workerResultPath -PathType Leaf)) {
            throw "SYSTEM worker не завершив налаштування протягом 60 секунд"
        }

        $workerResponse = Read-BRAVOTextFile -Path $workerResultPath |
            ConvertFrom-BRAVOJson
        if ($workerResponse.FatalError) {
            throw [string]$workerResponse.FatalError
        }
        return @($workerResponse.Results)
    } finally {
        try {
            $rootTaskFolder.DeleteTask($taskName, 0)
        } catch {
            # Тимчасове завдання могло не встигнути зареєструватися.
        }
        foreach ($temporaryFile in @($payloadPath, $workerResultPath)) {
            if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $workingDirectory -PathType Container) {
            Remove-Item -LiteralPath $workingDirectory -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ProtectedPayloadWorker {
    param(
        [string]$PayloadPath,
        [string]$WorkerResultPath
    )

    $response = @{
        Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Results = @()
        FatalError = $null
    }
    try {
        $payload = Read-BRAVOTextFile -Path $PayloadPath |
            ConvertFrom-BRAVOJson
        $workerEntries = @($payload.Entries | ForEach-Object {
            $secureSecret = if ($payload.Action -in @("Add", "Update", "Set")) {
                Unprotect-LocalMachineSecret -ProtectedValue ([string]$_.ProtectedSecret)
            } else {
                $null
            }
            [pscustomobject]@{
                Component = [string]$_.Component
                Target = [string]$_.Target
                UserName = [string]$_.UserName
                SecureSecret = $secureSecret
            }
        })
        $response.Results = @(
            Invoke-CredentialOperationsTransactional `
                -Operation ([string]$payload.Action) `
                -Entries $workerEntries
        )
    } catch {
        $response.FatalError = $_.Exception.Message
    }
    $temporaryResultPath = "$WorkerResultPath.tmp"
    [IO.File]::WriteAllText(
        $temporaryResultPath,
        ($response | ConvertTo-BRAVOJson -Depth 6),
        [Text.Encoding]::UTF8
    )
    Move-Item -LiteralPath $temporaryResultPath -Destination $WorkerResultPath -Force
}

try {
    $resolvedConfigPath = Get-BRAVOCredentialSetupConfiguration -Path $ConfigPath -PathWasExplicit:$configPathWasExplicit
    Import-Module -Name $credentialSettings.HelperPath -ErrorAction Stop

    if (-not [string]::IsNullOrWhiteSpace($ProtectedPayloadPath)) {
        if ([string]::IsNullOrWhiteSpace($ResultPath)) {
            throw "Для worker-режиму не вказано ResultPath"
        }
        Invoke-ProtectedPayloadWorker -PayloadPath $ProtectedPayloadPath -WorkerResultPath $ResultPath
        Complete-BRAVOCredentialSetup -ExitCode 0
    }

    if ($interactiveMenuRequested) {
        $menuSelection = Show-BRAVOCredentialMenu `
            -InitialStoreFor $StoreFor `
            -AskForStore (-not $storeForWasSpecified)
        if ($null -eq $menuSelection) {
            Write-Host "Роботу завершено без змін." -ForegroundColor Yellow
            Complete-BRAVOCredentialSetup -ExitCode 0
        }
        $Action = [string]$menuSelection.Action
        $Component = @([string]$menuSelection.Component)
        $StoreFor = [string]$menuSelection.StoreFor
    } elseif (-not $protectedWorkerMode) {
        # Заголовок лише для неінтерактивного (CLI-параметри) шляху —
        # інтерактивне меню вище малює власний Clear-Host-банер, а worker-
        # режим (ProtectedPayloadPath) не повинен друкувати нічого зайвого
        # у stdout, який батьківський процес парсить як JSON.
        Initialize-BRAVOConsole
        Initialize-BRAVOProgress -Enabled $false
        Write-BRAVOHeader `
            -Title ("BRAVO Credentials Setup {0}" -f $global:ScriptVersion) `
            -Mode ([string]$Action).ToUpperInvariant()
    }

    $requestedComponents = @(Resolve-RequestedComponents)
    if ($requestedComponents.Count -eq 0) {
        Write-Host "Немає секретів, необхідних для увімкнених компонентів." -ForegroundColor Yellow
        Complete-BRAVOCredentialSetup -ExitCode 0
    }

    $scheduledAccount = [string]$schedulerSettings.RunAsUser
    $systemStoreRequested = $StoreFor -in @("Both", "ScheduledTaskAccount")
    $currentUserStoreRequested = $StoreFor -in @("Both", "CurrentUser")
    $useSystemWorker = $systemStoreRequested -and
        $scheduledAccount -in @("SYSTEM", "NT AUTHORITY\SYSTEM") -and
        -not (Test-IsSystemIdentity)

    if ($useSystemWorker) {
        $configDirectory = Split-Path -Path $resolvedConfigPath -Parent
        $profileRoot = [IO.Path]::GetFullPath(
            [Environment]::GetFolderPath("UserProfile")
        ).TrimEnd("\") + "\"
        if (($configDirectory.TrimEnd("\") + "\").StartsWith(
                $profileRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw (
                "SYSTEM credential worker не запускається з профілю " +
                "користувача: $configDirectory. Перенесіть runtime до " +
                "C:\LIMS\ARCHIV або іншого захищеного каталогу."
            )
        }
    }

    if ($systemStoreRequested -and
        $scheduledAccount -notin @("SYSTEM", "NT AUTHORITY\SYSTEM") -and
        $scheduledAccount -ine [Security.Principal.WindowsIdentity]::GetCurrent().Name) {
        throw "Автоматичний запис підтримує SYSTEM або поточного користувача. Планувальник налаштовано для '$scheduledAccount'."
    }

    if ($useSystemWorker -and -not (Test-IsAdministrator)) {
        $componentArguments = ($Component | ForEach-Object { "`"$_`"" }) -join " "
        # AUTO -> elevated-процес сам повторює auto-derivation; EXPLICIT ->
        # точний шлях оператора зберігається (acceptance CF-17, той самий
        # контракт, що BRAVO_SETUP ConfigPathArgument).
        $elevationConfigArgumentText = if ($configPathWasExplicit) {
            "-ConfigPath `"$resolvedConfigPath`" "
        } else {
            ""
        }
        $elevationArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
            "$elevationConfigArgumentText-Action $Action -StoreFor $StoreFor " +
            "-Component $componentArguments"
        $process = Start-Process `
            -FilePath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -ArgumentList $elevationArguments `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -WindowStyle Normal
        Write-Host "Налаштування Credential Manager завершено з кодом $($process.ExitCode)."
        Complete-BRAVOCredentialSetup -ExitCode $process.ExitCode
    }

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($Action -eq "Ensure") {
        Write-Host "Перевірка наявних записів перед додаванням відсутніх..." -ForegroundColor Cyan
        $availabilityResults = @()
        if ($currentUserStoreRequested) {
            $currentAvailability = @(
                Invoke-CredentialOperations `
                    -Operation "Test" `
                    -Entries (New-OperationEntries -Names $requestedComponents)
            )
            $availabilityResults += @(
                Set-OperationResultScope `
                    -Results $currentAvailability `
                    -Scope $currentIdentity
            )
        }
        if ($useSystemWorker) {
            $systemAvailability = @(
                Invoke-AsSystem `
                    -ResolvedConfigPath $resolvedConfigPath `
                    -ConfigPathWasExplicit $configPathWasExplicit `
                    -Operation "Test" `
                    -Entries (New-OperationEntries -Names $requestedComponents)
            )
            $availabilityResults += @(
                Set-OperationResultScope `
                    -Results $systemAvailability `
                    -Scope "SYSTEM"
            )
        } elseif ($systemStoreRequested -and -not $currentUserStoreRequested) {
            $systemAvailability = @(
                Invoke-CredentialOperations `
                    -Operation "Test" `
                    -Entries (New-OperationEntries -Names $requestedComponents)
            )
            $availabilityResults += @(
                Set-OperationResultScope `
                    -Results $systemAvailability `
                    -Scope $currentIdentity
            )
        }

        Write-OperationResults -Results $availabilityResults
        if (@($availabilityResults | Where-Object { $_.Status -eq "Error" }).Count -gt 0) {
            Complete-BRAVOCredentialSetup -ExitCode 1
        }
        $missingComponents = @(
            $availabilityResults |
                Where-Object { $_.Status -eq "Missing" } |
                Select-Object -ExpandProperty Component -Unique
        )
        if ($missingComponents.Count -eq 0) {
            Write-Host "Усі запитані записи вже наявні. Значення не змінювалися." -ForegroundColor Green
            Complete-BRAVOCredentialSetup -ExitCode 0
        }

        Write-Host (
            "Буде запитано лише відсутні компоненти: " +
            ($missingComponents -join ", ")
        ) -ForegroundColor Yellow
        $requestedComponents = $missingComponents
        # Якщо запис відсутній лише в одному scope, нове значення записується
        # в обидва запитані scope, щоб вони знову були узгодженими.
        $Action = "Set"
    }

    $operationEntries = if ($Action -in @("Add", "Update", "Set")) {
        @(Read-SecretEntries -Names $requestedComponents)
    } else {
        @(New-OperationEntries -Names $requestedComponents)
    }

    if ($useSystemWorker -and $currentUserStoreRequested) {
        Write-Host "Сховища для облікових записів: $currentIdentity та NT AUTHORITY\SYSTEM"
        $currentUserEntries = @(Copy-OperationEntries -Entries $operationEntries)
        $systemEntries = @(Copy-OperationEntries -Entries $operationEntries)
        Clear-OperationEntries -Entries $operationEntries

        $currentUserSnapshots = if ($Action -eq "Test") {
            @()
        } else {
            @(Get-CredentialOperationSnapshots -Entries $currentUserEntries)
        }
        $currentUserResults = @(
            Invoke-CredentialOperationsTransactional `
                -Operation $Action `
                -Entries $currentUserEntries
        )
        $currentUserResults = @(Set-OperationResultScope -Results $currentUserResults -Scope $currentIdentity)
        if (@($currentUserResults | Where-Object { $_.Status -eq "Error" }).Count -gt 0) {
            Clear-OperationEntries -Entries $systemEntries
            $systemResults = @([pscustomobject]@{
                Component = "SYSTEM"
                Target = ""
                Status = "Error"
                Error = "операцію не розпочато через помилку поточного сховища"
                Scope = "SYSTEM"
            })
        } else {
            $systemResults = @(
                Invoke-AsSystem `
                    -ResolvedConfigPath $resolvedConfigPath `
                    -ConfigPathWasExplicit $configPathWasExplicit `
                    -Operation $Action `
                    -Entries $systemEntries
            )
            $systemResults = @(Set-OperationResultScope -Results $systemResults -Scope "SYSTEM")
            if ($Action -ne "Test" -and
                @($systemResults | Where-Object { $_.Status -eq "Error" }).Count -gt 0) {
                $rollbackResults = @(
                    Restore-CredentialOperationSnapshots `
                        -Snapshots $currentUserSnapshots
                )
                if ($rollbackResults.Count -gt 0) {
                    $currentUserResults += @(
                        Set-OperationResultScope `
                            -Results $rollbackResults `
                            -Scope $currentIdentity
                    )
                } else {
                    Write-Host "Поточне сховище повернуто до стану перед операцією." -ForegroundColor Yellow
                }
            }
        }
        Clear-CredentialOperationSnapshots -Snapshots $currentUserSnapshots
        $operationResults = @($currentUserResults) + @($systemResults)
    } elseif ($useSystemWorker) {
        Write-Host "Сховище для облікового запису: NT AUTHORITY\SYSTEM"
        $operationResults = @(Invoke-AsSystem -ResolvedConfigPath $resolvedConfigPath -ConfigPathWasExplicit $configPathWasExplicit -Operation $Action -Entries $operationEntries)
    } else {
        Write-Host "Сховище для облікового запису: $currentIdentity"
        $operationResults = @(
            Invoke-CredentialOperationsTransactional `
                -Operation $Action `
                -Entries $operationEntries
        )
    }
    Write-BRAVOCredentialResultBlock -Results $operationResults -Action $Action

    # "Missing" є невдачею лише для Test (перевірка наявності запису).
    # Remove ідемпотентний: видалення вже-відсутнього запису дає статус
    # "Missing", але це не помилка — інакше повторний "Видалити всі"
    # хибно завершувався кодом 1 і піднімав "ПОТРІБНА ДІЯ". Для
    # Add/Update/Set/Ensure статусу "Missing" не буває; скрізь, крім Test,
    # невдачею лишається тільки "Error".
    $failureStatuses = if ($Action -eq "Test") { @("Error", "Missing") } else { @("Error") }
    if (@($operationResults | Where-Object { $_.Status -in $failureStatuses }).Count -gt 0) {
        Complete-BRAVOCredentialSetup -ExitCode 1
    }
    Complete-BRAVOCredentialSetup -ExitCode 0
} catch {
    if (-not [string]::IsNullOrWhiteSpace($ProtectedPayloadPath) -and
        -not [string]::IsNullOrWhiteSpace($ResultPath)) {
        try {
            $failureResponse = @{
                Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                Results = @()
                FatalError = $_.Exception.Message
            } | ConvertTo-BRAVOJson -Depth 4
            $temporaryFailurePath = "$ResultPath.tmp"
            [IO.File]::WriteAllText($temporaryFailurePath, $failureResponse, [Text.Encoding]::UTF8)
            Move-Item -LiteralPath $temporaryFailurePath -Destination $ResultPath -Force
        } catch {
            # Батьківський процес за таймаутом повідомить про збій worker.
        }
    }
    if (-not $protectedWorkerMode) {
        Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
    }
    Complete-BRAVOCredentialSetup -ExitCode 1
}
