##########
# BravoSoft
# Author: Evgeniy Kucher
# Version metadata is loaded from VERSION.json through BRAVO_CONFIG_LOADER.ps1.
##########

param (
    [switch]$ForceRestore,
    [switch]$RunMissedRestoreOnly,
    [switch]$DisableSizeCheck,
    [switch]$EnableAllSlack,
    [switch]$DisableAllSlack,
    [ValidateSet("on", "off")]
    [string]$AutoShutdown,
    [Alias("ArchivLims")]
    [ValidateSet("on", "off")]
    [string]$ArchiveAfterMaintenance,
    [string]$ConfigPath,
    [switch]$NoPause,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$EntryScriptPath
)

$bravoScriptDirectory = $RuntimeRoot

# Спільні PowerShell-модулі runtime.
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveHelpers', 'BRAVO.Logging', 'BRAVO.Console', 'BRAVO.ExitCodes')) {
    $modulePath = Join-Path $bravoScriptDirectory "modules\$moduleName\$moduleName.psd1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Не знайдено спільний PowerShell-модуль: $modulePath"
    }
    Import-Module -Name $modulePath -ErrorAction Stop
}
Assert-BRAVOPowerShellCompatibility
[void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
$script:BRAVOCompatibility = Get-BRAVOCompatibilityInfo
$script:BRAVOPowerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
$script:BRAVOWindowsPatchLevel = Get-BRAVOWindowsPatchLevelRecommendation
$notificationHelpersPath = Join-Path $bravoScriptDirectory 'modules\BRAVO.Notifications\BRAVO.Notifications.psd1'
if (-not (Test-Path -LiteralPath $notificationHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль notifications: $notificationHelpersPath"
}
Import-Module -Name $notificationHelpersPath -ErrorAction Stop

# Пауза при ручному запуску мала охопити геть усі точки виходу нижче
# (їх багато, розкидані по всьому файлу), а не лише останню. exit
# всередині try ГАРАНТОВАНО проходить крізь усі finally на своєму шляху
# (перевірено емпірично, включно з вкладеними try/catch/finally) — тому
# один зовнішній try/finally навколо решти файлу безпечніше й надійніше,
# ніж вставляти виклик паузи перед кожним окремим exit.
try {

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass –Force

# За потреби запит на підвищення дозволу виконання скрипта. SYSTEM не має
# інтерактивного UAC-сеансу, а Start-Process -Verb RunAs там повертає 0x80070001.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isLocalSystem = $currentIdentity.User.Value -eq 'S-1-5-18'
If (-not $isLocalSystem -and -not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	$elevatedArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$EntryScriptPath`"")
	if ($ForceRestore) { $elevatedArguments += "-ForceRestore" }
	if ($RunMissedRestoreOnly) { $elevatedArguments += "-RunMissedRestoreOnly" }
	if ($DisableSizeCheck) { $elevatedArguments += "-DisableSizeCheck" }
	if ($EnableAllSlack) { $elevatedArguments += "-EnableAllSlack" }
	if ($DisableAllSlack) { $elevatedArguments += "-DisableAllSlack" }
	if ($PSBoundParameters.ContainsKey('AutoShutdown')) { $elevatedArguments += @("-AutoShutdown", $AutoShutdown) }
	if ($PSBoundParameters.ContainsKey('ArchiveAfterMaintenance')) {
        $elevatedArguments += @("-ArchiveAfterMaintenance", $ArchiveAfterMaintenance)
    }
    $elevatedArguments += @("-ConfigPath", "`"$ConfigPath`"")
	$elevatedProcess = Start-Process powershell.exe -ArgumentList $elevatedArguments -Verb RunAs -Wait -PassThru
	Exit $elevatedProcess.ExitCode
}

# Примусово використовуємо TLS 1.2. Числове значення 3072 сумісне зі старими
# .NET/PowerShell, у яких ім'я Tls12 може бути відсутнім у переліку enum.
[Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject(
    [Net.SecurityProtocolType],
    3072
)
[Net.ServicePointManager]::Expect100Continue = $false

# Очистка терміналу
Clear-Host

# Стан lock-а операції обслуговування. Exit-BRAVOMaintenanceOperationLock
# читає ці змінні у шляхах очищення, які можуть спрацювати ще до захоплення
# lock-а, а Set-StrictMode (успадкований від конфігураційного завантажувача)
# робить читання неоголошеної змінної помилкою.
$script:maintenanceOperationLock = $null
$script:maintenanceOperationLockPath = $null

# ===== ЗАВАНТАЖЕННЯ НАЛАШТУВАНЬ =====
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Host "ПОМИЛКА: Не знайдено конфігураційний файл: $ConfigPath" -ForegroundColor Red
    exit 30
}

try {
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $ConfigPath -Parent
    $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $ConfigPath
    $script:ScriptVersion = [string]$global:ScriptVersion
    $script:ScriptDate = [string]$global:ScriptDate
    $script:ScriptBuildId = [string]$global:ScriptBuildId

    if ($null -eq $credentialSettings -or
        $null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
        throw "вбудований Credential Manager недоступний"
    }
    [void](Import-BRAVOInstitutionSettings `
        -CredentialSettings $credentialSettings `
        -BravoSettings $bravoSettings)

    $MaintenanceConfig = $maintenanceSettings
    if ($null -eq $MaintenanceConfig) {
        throw "У BRAVO.config відсутня секція maintenanceSettings"
    }
    if ($null -eq $pathSettings -or
        [string]::IsNullOrWhiteSpace([string]$pathSettings.LIMSRoot) -or
        [string]::IsNullOrWhiteSpace([string]$pathSettings.ArchiveRoot)) {
        throw "У BRAVO.config відсутня або не заповнена секція pathSettings"
    }
} catch {
    Write-Host "ПОМИЛКА читання конфігурації '$ConfigPath': $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -ForegroundColor Red
    exit 30
}

$requiredConfigPaths = @(
    "General.ObjectName",
    "General.ArchivePrefix",
    "Services.BravoName",
    "Services.ExchangeApiName",
    "Restore.Day",
    "Restore.Time",
    "Restore.ArchivesKeepCount",
    "Retention.ArchiveDays",
    "Retention.LogDays",
    "Limits.MinimumFreeSpaceGB",
    "Limits.MaximumMdFileSizeGB",
    "Limits.MdFileSizeExclusions",
    "Automation.AutoShutdown",
    "Automation.ShutdownTimeoutSeconds",
    "Automation.ArchiveAfterMaintenance",
    "RangeIdMonitoring.Enabled",
    "RangeIdMonitoring.FilePath",
    "RangeIdMonitoring.ThresholdPercent",
    "RangeIdMonitoring.CheckDelaySeconds",
    "Archiver.Parameters",
    "Logging.Level"
)

foreach ($requiredPath in $requiredConfigPaths) {
    $currentNode = $MaintenanceConfig
    foreach ($segment in $requiredPath.Split('.')) {
        if ($currentNode -is [System.Collections.IDictionary]) {
            if (-not $currentNode.Contains($segment) -or $null -eq $currentNode[$segment]) {
                Write-Host "ПОМИЛКА: У конфігурації відсутній обов'язковий параметр '$requiredPath'" -ForegroundColor Red
                exit 30
            }
            $currentNode = $currentNode[$segment]
        } else {
            $property = $currentNode.PSObject.Properties[$segment]
            if ($null -eq $property -or $null -eq $property.Value) {
                Write-Host "ПОМИЛКА: У конфігурації відсутній обов'язковий параметр '$requiredPath'" -ForegroundColor Red
                exit 30
            }
            $currentNode = $property.Value
        }
    }
}

$script:ObjectName = [string]$MaintenanceConfig.General.ObjectName
$ArchivePrefix = [string]$MaintenanceConfig.General.ArchivePrefix
$ArchivePrefixRegex = [regex]::Escape($ArchivePrefix)
$BRAVO_WEB_DIR = [Environment]::ExpandEnvironmentVariables([string]$MaintenanceConfig.General.BravoWebDirectory)
$BravoServiceName = [string]$MaintenanceConfig.Services.BravoName
$BravoWebComponentEnabled = if ($MaintenanceConfig.Services -is [System.Collections.IDictionary] -and
    $MaintenanceConfig.Services.Contains("BravoWebEnabled")) {
    [System.Convert]::ToBoolean($MaintenanceConfig.Services.BravoWebEnabled)
} else {
    # Старі конфігурації без перемикача зберігають попередню поведінку.
    $true
}
$BravoWebServiceCandidates = @($MaintenanceConfig.Services.BravoWebCandidates | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
$ExchangAPIServiceName = [string]$MaintenanceConfig.Services.ExchangeApiName
$ServiceStartTimeoutSeconds = if ([int]$MaintenanceConfig.Services.StartTimeoutSeconds -gt 0) {
    [int]$MaintenanceConfig.Services.StartTimeoutSeconds
} else {
    180
}
$ServiceStopTimeoutSeconds = if ([int]$MaintenanceConfig.Services.StopTimeoutSeconds -gt 0) {
    [int]$MaintenanceConfig.Services.StopTimeoutSeconds
} else {
    120
}
$ServicePollIntervalSeconds = if ([int]$MaintenanceConfig.Services.PollIntervalSeconds -gt 0) {
    [int]$MaintenanceConfig.Services.PollIntervalSeconds
} else {
    2
}
$RestoreDay = [int]$MaintenanceConfig.Restore.Day
$RestoreTime = [string]$MaintenanceConfig.Restore.Time
$RESTORE_ARCHIVES_KEEP_COUNT = [int]$MaintenanceConfig.Restore.ArchivesKeepCount
$ARCHIVE_RETENTION_DAYS = [int]$MaintenanceConfig.Retention.ArchiveDays
$LOG_RETENTION_DAYS = [int]$MaintenanceConfig.Retention.LogDays
$FAILED_ARCHIVE_RETENTION_DAYS = if ($null -ne $MaintenanceConfig.Retention.FailedArchiveDays) {
    [math]::Max(1, [int]$MaintenanceConfig.Retention.FailedArchiveDays)
} else {
    30
}
$MIN_FREE_SPACE = [double]$MaintenanceConfig.Limits.MinimumFreeSpaceGB
$FREE_SPACE_EXCLUDED_DRIVES = @()
$invalidExcludedDrives = @()
$configuredExcludedDrives = if (
    $MaintenanceConfig.Limits -is [System.Collections.IDictionary] -and
    $MaintenanceConfig.Limits.Contains("ExcludedDrives")
) {
    @($MaintenanceConfig.Limits.ExcludedDrives)
} else {
    @()
}
foreach ($configuredDrive in $configuredExcludedDrives) {
    $normalizedDrive = ([string]$configuredDrive).Trim().TrimEnd('\').ToUpperInvariant()
    if ($normalizedDrive -match '^[A-Z]$') {
        $normalizedDrive += ":"
    }
    if ($normalizedDrive -notmatch '^[A-Z]:$') {
        $invalidExcludedDrives += [string]$configuredDrive
        continue
    }
    if ($FREE_SPACE_EXCLUDED_DRIVES -notcontains $normalizedDrive) {
        $FREE_SPACE_EXCLUDED_DRIVES += $normalizedDrive
    }
}
$MAX_MD_FILE_SIZE = [double]$MaintenanceConfig.Limits.MaximumMdFileSizeGB * 1GB
$MD_FILE_SIZE_EXCLUSIONS = @($MaintenanceConfig.Limits.MdFileSizeExclusions | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
$ShutdownTimeout = [int]$MaintenanceConfig.Automation.ShutdownTimeoutSeconds
$NotificationProvider = ([string]$bravoSettings.NotificationProvider).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($NotificationProvider)) {
    # Старі конфігурації без вибору каналу використовують Discord.
    $NotificationProvider = "discord"
}

$configuredNotificationMode = [string]$bravoSettings.NotificationMode
if ([string]::IsNullOrWhiteSpace($configuredNotificationMode)) {
    # Сумісність зі старим BRAVO.config.
    $configuredNotificationMode = [string]$bravoSettings.SlackMode
}
if ([string]::IsNullOrWhiteSpace($configuredNotificationMode) -and $MaintenanceConfig.Slack) {
    # Сумісність зі старим BRAVO.config.
    $configuredNotificationMode = [string]$MaintenanceConfig.Slack.Mode
}
$SlackMode = $configuredNotificationMode.ToLowerInvariant()

$NotificationRequestTimeoutSeconds = if ($null -ne $bravoSettings.NotificationRequestTimeoutSeconds) {
    [math]::Max(1, [int]$bravoSettings.NotificationRequestTimeoutSeconds)
} else {
    30
}
$NotificationProviderDisplayName = if ($NotificationProvider -eq "discord") { "Discord" } else { "Slack" }
$NotificationWebhookUrl = $null
$NotificationCredentialError = $null
if ($SlackMode -ne "none") {
    try {
        if ($null -eq $credentialSettings -or
            $null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
            throw "вбудований Credential Manager недоступний"
        }
        $notificationCredentialTarget = if ($NotificationProvider -eq "discord") {
            [string]$credentialSettings.Targets.DiscordWebhook
        } else {
            [string]$credentialSettings.Targets.SlackWebhook
        }
        if ([string]::IsNullOrWhiteSpace($notificationCredentialTarget)) {
            $notificationCredentialTarget = if ($NotificationProvider -eq "discord") {
                "BRAVO_DISCORD_URL"
            } else {
                "BRAVO_SLACK_URL"
            }
        }
        $NotificationWebhookUrl = Get-BRAVOCredentialSecret -Target $notificationCredentialTarget
        if ([string]::IsNullOrWhiteSpace($NotificationWebhookUrl)) {
            throw "запис Credential Manager '$notificationCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
    } catch {
        $NotificationCredentialError = Protect-BRAVOLogSecret -Text $_.Exception.Message
    }
}

$script:ArchivePassword = $null
$ArchiveCredentialError = $null
try {
    if ($null -eq $credentialSettings -or
        $null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
        throw "вбудований Credential Manager недоступний"
    }
    $archiveCredentialTarget = [string]$credentialSettings.Targets.ArchivePassword
    if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
        $archiveCredentialTarget = "BRAVO_7Z_PASSWORD"
    }
    if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
        throw "не вдалося визначити назву запису Credential Manager для пароля архівів"
    }
    $script:ArchivePassword = Get-BRAVOCredentialSecret -Target $archiveCredentialTarget
    if ([string]::IsNullOrWhiteSpace($script:ArchivePassword)) {
        throw "запис Credential Manager '$archiveCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    if ($script:ArchivePassword.IndexOfAny([char[]]"`r`n") -ge 0) {
        throw "пароль архівів не може містити символи нового рядка"
    }
} catch {
    $ArchiveCredentialError = Protect-BRAVOLogSecret -Text $_.Exception.Message
}

$RangeIdMonitoringEnabled = [System.Convert]::ToBoolean($MaintenanceConfig.RangeIdMonitoring.Enabled)
$RangeIdLogPath = [Environment]::ExpandEnvironmentVariables([string]$MaintenanceConfig.RangeIdMonitoring.FilePath)
$RangeIdThresholdPercent = [double]$MaintenanceConfig.RangeIdMonitoring.ThresholdPercent
$RangeIdCheckDelaySeconds = [int]$MaintenanceConfig.RangeIdMonitoring.CheckDelaySeconds
$arcCommonParams = @($MaintenanceConfig.Archiver.Parameters | ForEach-Object { [string]$_ })
$NativeCommandTimeoutSeconds = if (
    $null -ne $MaintenanceConfig.Archiver.CommandTimeoutSeconds
) {
    [math]::Max(1, [int]$MaintenanceConfig.Archiver.CommandTimeoutSeconds)
} else {
    14400
}
$SevenZipIntegrityTestTimeoutSeconds = if (
    $null -ne $MaintenanceConfig.Archiver.IntegrityTestTimeoutSeconds
) {
    [math]::Max(0, [int]$MaintenanceConfig.Archiver.IntegrityTestTimeoutSeconds)
} else {
    43200
}
$archivePasswordPresentInConfig = @($arcCommonParams | Where-Object { $_ -match '(?i)^-p' }).Count -gt 0
if (-not [string]::IsNullOrWhiteSpace($script:ArchivePassword)) {
    # -p без значення: пароль буде передано 7-Zip через stdin.
    $arcCommonParams += "-p"
}
$MoveRetryCount = if ($MaintenanceConfig.FileOperations -and
    $null -ne $MaintenanceConfig.FileOperations.MoveRetryCount) {
    [math]::Max(1, [int]$MaintenanceConfig.FileOperations.MoveRetryCount)
} else {
    3
}
$MoveRetryDelaySeconds = if ($MaintenanceConfig.FileOperations -and
    $null -ne $MaintenanceConfig.FileOperations.MoveRetryDelaySeconds) {
    [math]::Max(0, [int]$MaintenanceConfig.FileOperations.MoveRetryDelaySeconds)
} else {
    5
}
$script:LogLevel = ([string]$MaintenanceConfig.Logging.Level).ToUpperInvariant()

if (-not $PSBoundParameters.ContainsKey('AutoShutdown')) {
    $AutoShutdown = [string]$MaintenanceConfig.Automation.AutoShutdown
}
if (-not $PSBoundParameters.ContainsKey('ArchiveAfterMaintenance')) {
    $ArchiveAfterMaintenance = [string]$MaintenanceConfig.Automation.ArchiveAfterMaintenance
}

$parsedRestoreTime = [TimeSpan]::Zero
if ([string]::IsNullOrWhiteSpace($script:ObjectName) -or
    [string]::IsNullOrWhiteSpace($ArchivePrefix) -or
    [string]::IsNullOrWhiteSpace($BravoServiceName) -or
    ($BravoWebComponentEnabled -and [string]::IsNullOrWhiteSpace($BRAVO_WEB_DIR)) -or
    ($BravoWebComponentEnabled -and $BravoWebServiceCandidates.Count -eq 0) -or
    $RestoreDay -notin 1..7 -or
    -not [TimeSpan]::TryParse($RestoreTime, [ref]$parsedRestoreTime) -or
    $ARCHIVE_RETENTION_DAYS -lt 0 -or
    $LOG_RETENTION_DAYS -lt 0 -or
    $RESTORE_ARCHIVES_KEEP_COUNT -lt 0 -or
    $MIN_FREE_SPACE -lt 0 -or
    $MAX_MD_FILE_SIZE -le 0 -or
    $ShutdownTimeout -lt 0 -or
    $RangeIdThresholdPercent -lt 0 -or
    $RangeIdThresholdPercent -gt 100 -or
    $RangeIdCheckDelaySeconds -lt 0 -or
    $NotificationProvider -notin @("slack", "discord") -or
    $SlackMode -notin @("none", "errors_only", "all") -or
    $script:LogLevel -notin @("DEBUG", "INFO", "WARNING", "ERROR", "SUCCESS") -or
    $arcCommonParams.Count -eq 0) {
    Write-Host "ПОМИЛКА: BRAVO.config містить некоректні значення" -ForegroundColor Red
    exit 30
}

if ($invalidExcludedDrives.Count -gt 0) {
    Write-Host "ПОМИЛКА: Некоректні значення Limits.ExcludedDrives: $($invalidExcludedDrives -join ', ')" -ForegroundColor Red
    exit 30
}

if ($RangeIdMonitoringEnabled -and [string]::IsNullOrWhiteSpace($RangeIdLogPath)) {
    Write-Host "ПОМИЛКА: Для моніторингу діапазонів ID потрібно вказати RangeIdMonitoring.FilePath" -ForegroundColor Red
    exit 30
}

if ($archivePasswordPresentInConfig) {
    Write-Host "ПОМИЛКА: Видаліть параметр -p<пароль> із Maintenance.Archiver.Parameters у BRAVO.config. Пароль має зберігатися лише у Credential Manager." -ForegroundColor Red
    exit 30
}

if ([string]::IsNullOrWhiteSpace($script:ArchivePassword)) {
    $archiveCredentialDetails = if ($ArchiveCredentialError) { ": $ArchiveCredentialError" } else { "" }
    Write-Host "ПОМИЛКА: Не знайдено пароль архівів 7-Zip у Credential Manager$archiveCredentialDetails" -ForegroundColor Red
    exit 31
}

if ($SlackMode -ne "none" -and
    ([string]::IsNullOrWhiteSpace($NotificationWebhookUrl) -or
    -not $NotificationWebhookUrl.StartsWith("https://"))) {
    $credentialDetails = if ($NotificationCredentialError) { ": $NotificationCredentialError" } else { "" }
    Write-Host "ПОМИЛКА: Для каналу $NotificationProviderDisplayName не знайдено коректний HTTPS webhook у Credential Manager$credentialDetails" -ForegroundColor Red
    exit 31
}

# Автоматичне визначення служби Apache для BRAVO Web.
# Спочатку шукаємо службу за шляхом до httpd.exe, потім за відомими варіантами імен.
$BravoWebServiceName = $null
$BravoWebServiceDisplayName = $null
$BravoWebServiceMatchCount = 0
$ApacheServiceInfo = $null
$ApacheService = $null
$ExpectedApacheExecutable = if ($BravoWebComponentEnabled) {
    Join-Path $BRAVO_WEB_DIR "apache\bin\httpd.exe"
} else {
    $null
}
$WindowsServices = if ($BravoWebComponentEnabled) {
    try {
        @(Get-BRAVOWmiInstance -ClassName Win32_Service)
    } catch {
        @()
    }
} else {
    @()
}

$ApacheServiceMatches = @($WindowsServices | Where-Object {
    $pathName = [Environment]::ExpandEnvironmentVariables([string]$_.PathName).Trim()
    if ($pathName -match '^\s*"([^"]+)"') {
        $serviceExecutable = $matches[1]
    } elseif ($pathName -match '^\s*([^\s]+)') {
        $serviceExecutable = $matches[1]
    } else {
        $serviceExecutable = $null
    }

    $serviceExecutable -and ($serviceExecutable -ieq $ExpectedApacheExecutable)
})

if ($ApacheServiceMatches.Count -gt 0) {
    $BravoWebServiceMatchCount = $ApacheServiceMatches.Count

    # Якщо залишилися дублікати реєстрації, керуємо тією службою, яка фактично працює.
    $ApacheServiceInfo = $ApacheServiceMatches | Where-Object {
        $_.State -eq 'Running'
    } | Select-Object -First 1

    if (-not $ApacheServiceInfo) {
        foreach ($candidate in $BravoWebServiceCandidates) {
            $ApacheServiceInfo = $ApacheServiceMatches | Where-Object {
                $_.Name -ieq $candidate -or $_.DisplayName -ieq $candidate
            } | Select-Object -First 1

            if ($ApacheServiceInfo) { break }
        }
    }

    if (-not $ApacheServiceInfo) {
        $ApacheServiceInfo = $ApacheServiceMatches | Select-Object -First 1
    }
}

if (-not $ApacheServiceInfo) {
    foreach ($candidate in $BravoWebServiceCandidates) {
        $ApacheServiceInfo = $WindowsServices | Where-Object {
            $_.Name -ieq $candidate -or $_.DisplayName -ieq $candidate
        } | Select-Object -First 1

        if ($ApacheServiceInfo) { break }
    }
}

if ($ApacheServiceInfo) {
    $BravoWebServiceName = $ApacheServiceInfo.Name
    $BravoWebServiceDisplayName = $ApacheServiceInfo.DisplayName
    $ApacheService = Get-Service -Name $BravoWebServiceName -ErrorAction SilentlyContinue
}

if ($BravoWebComponentEnabled -and -not $ApacheService) {
    # Резервний пошук, якщо CIM недоступний.
    $InstalledServices = @(Get-Service -ErrorAction SilentlyContinue)
    foreach ($candidate in $BravoWebServiceCandidates) {
        $ApacheService = $InstalledServices | Where-Object {
            $_.Name -ieq $candidate -or $_.DisplayName -ieq $candidate
        } | Select-Object -First 1

        if ($ApacheService) {
            $BravoWebServiceName = $ApacheService.Name
            $BravoWebServiceDisplayName = $ApacheService.DisplayName
            break
        }
    }
}

$ApacheServiceExists = ($null -ne $ApacheService)
$BravoWebServiceDisabledBySystem = $false
if ($ApacheServiceExists) {
    $cimStartMode = if ($ApacheServiceInfo) { [string]$ApacheServiceInfo.StartMode } else { "" }
    $serviceStartType = [string]$ApacheService.StartType
    $BravoWebServiceDisabledBySystem = (
        $cimStartMode -ieq "Disabled" -or
        $serviceStartType -ieq "Disabled"
    )
}
$BravoWebMaintenanceEnabled = (
    $BravoWebComponentEnabled -and
    $ApacheServiceExists -and
    -not $BravoWebServiceDisabledBySystem
)

# Стан основних служб визначається до будь-яких дій з їх компонентами.
# Відсутня або системно відключена служба повністю вимикає свій компонент.
function Get-ConfiguredServiceState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    $serviceInfo = $null
    $startMode = ""

    if ($service) {
        try {
            $escapedName = $Name.Replace("'", "''")
            $serviceInfo = Get-BRAVOWmiInstance `
                -ClassName Win32_Service `
                -Filter "Name = '$escapedName'" |
                Select-Object -First 1
        } catch {
            $serviceInfo = $null
        }
        $startMode = if ($serviceInfo) {
            [string]$serviceInfo.StartMode
        } else {
            [string]$service.StartType
        }
    }

    [PSCustomObject]@{
        Service  = $service
        Exists   = ($null -ne $service)
        Disabled = ($startMode -ieq "Disabled")
        Enabled  = ($null -ne $service -and $startMode -ine "Disabled")
    }
}

function Invoke-ServiceStateChange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Running", "Stopped")]
        [string]$DesiredStatus,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [int]$PollIntervalSeconds = 2,

        [switch]$Force
    )

    $operationErrors = @()
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        $service.Refresh()
        if ([string]$service.Status -eq $DesiredStatus) {
            return [pscustomobject]@{
                Success = $true
                AlreadyInState = $true
                FinalStatus = [string]$service.Status
                Error = $null
            }
        }

        if ($DesiredStatus -eq "Running") {
            Start-Service `
                -Name $Name `
                -WarningAction SilentlyContinue `
                -ErrorAction SilentlyContinue `
                -ErrorVariable operationErrors
        } else {
            Stop-Service `
                -Name $Name `
                -Force:$Force `
                -WarningAction SilentlyContinue `
                -ErrorAction SilentlyContinue `
                -ErrorVariable operationErrors
        }

        $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
        $pollSeconds = [math]::Max(1, $PollIntervalSeconds)
        do {
            $service = Get-Service -Name $Name -ErrorAction Stop
            $service.Refresh()
            if ([string]$service.Status -eq $DesiredStatus) {
                return [pscustomobject]@{
                    Success = $true
                    AlreadyInState = $false
                    FinalStatus = [string]$service.Status
                    Error = $null
                }
            }
            if ((Get-Date) -ge $deadline) {
                break
            }
            Start-Sleep -Seconds $pollSeconds
        } while ($true)

        $operationErrorText = @($operationErrors | ForEach-Object {
            $_.Exception.Message
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        }) -join "; "
        $details = if ([string]::IsNullOrWhiteSpace($operationErrorText)) {
            "перевищено таймаут $TimeoutSeconds сек."
        } else {
            "$operationErrorText; після очікування $TimeoutSeconds сек. стан: $($service.Status)"
        }
        return [pscustomobject]@{
            Success = $false
            AlreadyInState = $false
            FinalStatus = [string]$service.Status
            Error = $details
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            AlreadyInState = $false
            FinalStatus = "Unknown"
            Error = $_.Exception.Message
        }
    }
}

$bravoServiceState = Get-ConfiguredServiceState -Name $BravoServiceName
$bravoService = $bravoServiceState.Service
$BravoServiceDisabledBySystem = $bravoServiceState.Disabled
$BravoMaintenanceEnabled = $bravoServiceState.Enabled

$exchangAPIServiceState = Get-ConfiguredServiceState -Name $ExchangAPIServiceName
$exchangAPIService = $exchangAPIServiceState.Service
$exchangAPIServiceDisabled = $exchangAPIServiceState.Disabled
$exchangAPIServiceEnabled = $exchangAPIServiceState.Enabled

# ===== ГЛОБАЛЬНІ ЗМІННІ (НЕ ЗМІНЮВАТИ) =====
$script:ScriptStartTime = [DateTime]::Now
$script:SlackMessageBuffer = New-Object 'System.Collections.Generic.List[string]'
$script:CriticalErrors = $false
$script:CriticalErrorsList = New-Object 'System.Collections.Generic.List[string]'
$script:criticalErrorOccurred = $false
# Лічильник WARNING для контракту кодів завершення: успіх без жодного
# попередження -> 0, успіх із попередженнями -> 10 (Resolve-BRAVOExitCode).
$script:BRAVOWarningCount = 0
# Уточнення категорії всередині $criticalErrorOccurred для операцій
# створення/відновлення локального архіву (40) і перевірки його цілісності
# (41) — решта відмов (сервіси, диск, файлове господарство, оркестрація
# BRAVO_ARCHIV) лишаються загальним бакетом 60, як і раніше.
$script:restoreArchiveFailed = $false
$script:restoreIntegrityFailed = $false

function Enter-BRAVOMaintenanceOperationLock {
    $lockPath = Join-Path $LOG_DIR "BRAVO_OPERATION.lock"
    try {
        $waitMinutes = if ($null -ne $schedulerSettings -and
            $schedulerSettings.Contains("OperationLockWaitMinutes")) {
            [math]::Max(0, [int]$schedulerSettings.OperationLockWaitMinutes)
        } else {
            0
        }
        $deadline = (Get-Date).AddMinutes($waitMinutes)
        $stream = $null
        $lastLockError = $null
        do {
            try {
                $stream = [System.IO.File]::Open(
                    $lockPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::None
                )
            } catch {
                $lastLockError = $_.Exception.Message
                if ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 30
                }
            }
        } while ($null -eq $stream -and (Get-Date) -lt $deadline)
        if ($null -eq $stream) {
            throw "lock не звільнився за $waitMinutes хв.: $lastLockError"
        }
        # JSON замість "Operation=...; PID=...; Started=..." (аудит P1.8):
        # той самий формат, що й у спільному lock з Archive.Runtime.ps1.
        $lockProcessStartTime = try {
            (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString("o")
        } catch {
            $null
        }
        $lockText = ([pscustomobject]@{
            pid = $PID
            processStartTime = $lockProcessStartTime
            hostname = [Environment]::MachineName
            operation = "Maintenance"
            startedAt = (Get-Date).ToString("o")
            packageVersion = [string]$script:ScriptVersion
            config = $ConfigPath
        } | ConvertTo-Json -Compress)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return [pscustomobject]@{
            Success = $true
            Stream = $stream
            Path = $lockPath
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Stream = $null
            Path = $lockPath
            Error = $_.Exception.Message
        }
    }
}

function Exit-BRAVOMaintenanceOperationLock {
    if ($script:maintenanceOperationLock) {
        $script:maintenanceOperationLock.Dispose()
        $script:maintenanceOperationLock = $null
    }
    if (-not [string]::IsNullOrWhiteSpace(
            [string]$script:maintenanceOperationLockPath
        ) -and
        (Test-Path -LiteralPath $script:maintenanceOperationLockPath -PathType Leaf)) {
        Remove-Item `
            -LiteralPath $script:maintenanceOperationLockPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
    $script:maintenanceOperationLockPath = $null
}

# Визначаємо режим повідомлень.
if ($DisableAllSlack) {
    $script:SlackMode = "none"
    Write-Host "Повідомлення: ВИМКНЕНО (none)" -ForegroundColor Yellow
} elseif ($EnableAllSlack) {
    $script:SlackMode = "all" 
    Write-Host "Повідомлення через ${NotificationProviderDisplayName}: УСІ ПОВІДОМЛЕННЯ (all)" -ForegroundColor Green
} else {
    $script:SlackMode = $SlackMode
}

# Визначаємо режим автоматичного вимкнення
# Якщо параметр передано через командний рядок - використовуємо його, інакше - значення з налаштувань
if ($PSBoundParameters.ContainsKey('AutoShutdown')) {
    # Використовуємо значення з параметра командного рядка
    $AutoShutdown = $AutoShutdown.ToLower()
} else {
    # Використовуємо значення з налаштувань
    $AutoShutdown = $AutoShutdown.ToLower()
}

if ($AutoShutdown -notin @("on", "off")) {
    Write-Host "ПОМИЛКА: Параметр AutoShutdown має бути 'on' або 'off'. Поточне значення: $AutoShutdown" -ForegroundColor Red
    exit 30
}

$script:EnableAutoShutdown = ($AutoShutdown -eq "on")

# ===== ПЕРЕВІРКА АВТОМАТИЧНОГО ЗАПУСКУ BRAVO_ARCHIV =====
# Якщо параметр передано через командний рядок - використовуємо його, інакше - значення з налаштувань
if ($PSBoundParameters.ContainsKey('ArchiveAfterMaintenance')) {
    # Використовуємо значення з параметра командного рядка
    $ArchiveAfterMaintenance = $ArchiveAfterMaintenance.ToLower()
} else {
    # Використовуємо значення з налаштувань
    $ArchiveAfterMaintenance = $ArchiveAfterMaintenance.ToLower()
}

if ($ArchiveAfterMaintenance -notin @("on", "off")) {
    Write-Host "ПОМИЛКА: Параметр ArchiveAfterMaintenance має бути 'on' або 'off'. Поточне значення: $ArchiveAfterMaintenance" -ForegroundColor Red
    exit 30
}

$script:EnableArchiveAfterMaintenance = ($ArchiveAfterMaintenance -eq "on")

# ===== ОПЕРАЦІЙНА КОНСОЛЬ =====
# Нумерація етапів: [1/9], [2/9], ... Ті самі елементи виводу, що в Archive
# і Health: заголовок, етапи, підсумок.
$script:BRAVOMaintenanceStepCurrent = 0
$script:BRAVOMaintenanceStepTotal = 0

function Initialize-BRAVOMaintenanceSteps {
    param([Parameter(Mandatory = $true)][int]$Total)

    $script:BRAVOMaintenanceStepCurrent = 0
    $script:BRAVOMaintenanceStepTotal = [Math]::Max(1, $Total)
}

# Статус етапу рахується від ЗРІЗУ лічильників перед блоком, а не від
# їхнього абсолютного значення: $script:criticalErrorOccurred накопичується
# до кінця запуску, тому без зрізу одна рання помилка пофарбувала б у
# червоне всі наступні етапи, які насправді відпрацювали.
function Get-BRAVOMaintenanceStepStatus {
    param(
        [bool]$CriticalBefore,
        [int]$WarningsBefore,
        [switch]$Skipped
    )

    if ($Skipped) {
        return 'SKIPPED'
    }
    if ($script:criticalErrorOccurred -and -not $CriticalBefore) {
        return 'ERROR'
    }
    if ($script:BRAVOWarningCount -gt $WarningsBefore) {
        return 'WARNING'
    }
    return 'OK'
}

function Write-BRAVOMaintenanceStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('OK', 'SKIPPED', 'WARNING', 'ERROR')]
        [string]$Status = 'OK',
        [string]$Details
    )

    $script:BRAVOMaintenanceStepCurrent++
    Write-BRAVOStepResult `
        -Current $script:BRAVOMaintenanceStepCurrent `
        -Total $script:BRAVOMaintenanceStepTotal `
        -Name $Name `
        -Status $Status `
        -Details $Details
}

# ===== ФУНКЦІЯ ЛОГУВАННЯ =====
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [int]$SeparatorLength = 100,
        [switch]$NoTimestamp
    )

    # Пароль архіву, webhook чи URL з обліковими даними можуть потрапити
    # сюди через повідомлення винятку — маскуємо перед виводом у консоль
    # чи запис у файл, до будь-якого з можливих виходів функції нижче.
    $Message = Protect-BRAVOLogSecret -Text $Message
    if ($Level -eq "WARNING") {
        $script:BRAVOWarningCount++
    }

    # Шкала спільна з BRAVO.Logging. SUCCESS свідомо НИЖЧЕ за WARNING:
    # у старій локальній шкалі (SUCCESS=4, ERROR=3) значення LogLevel="SUCCESS"
    # відсікало помилки й попередження, тобто найвища детальність ховала
    # рівно те, заради чого журнал читають.
    $logLevels = @{"TRACE"=0; "DEBUG"=1; "INFO"=2; "SUCCESS"=3; "WARNING"=4; "ERROR"=5; "FATAL"=6}

    # Отримуємо поточний рівень логування з глобальної змінної
    $currentLogLevel = if ($script:LogLevel -and $logLevels.ContainsKey($script:LogLevel)) {
        $logLevels[$script:LogLevel]
    } else {
        $logLevels["INFO"]
    }

    $messageLevel = if ($logLevels.ContainsKey($Level)) {
        $logLevels[$Level]
    } else {
        $logLevels["INFO"]
    }

    # Поріг консолі — окремий від файлового, з тієї самої секції BRAVO.config,
    # що й в Archive та Health.
    $consoleLevelName = if ($null -ne $consoleSettings.ConsoleLevel) {
        [string]$consoleSettings.ConsoleLevel
    } else {
        'WARNING'
    }
    $consoleThreshold = if ($logLevels.ContainsKey($consoleLevelName)) {
        $logLevels[$consoleLevelName]
    } else {
        $logLevels["WARNING"]
    }
    $normalizedLevel = if ($logLevels.ContainsKey($Level)) { $Level } else { 'INFO' }
    
    # Пропускаємо повідомлення нижчого рівня
    if ($messageLevel -lt $currentLogLevel) {
        return
    }
    
    # Роздільники й заголовки формували структуру старої консолі. Тепер її
    # задають етапи (Write-BRAVOMaintenanceStep), тому в консоль вони більше
    # не йдуть — але лишаються у файлі, щоб хронологія читалася як раніше.
    if ($Message -eq "=" -or $Message -eq "===") {
        Write-BRAVOMaintenanceLogFile -Entry ("=" * $SeparatorLength)
        return
    }

    if ($Message -match "^=== .* ===$") {
        Write-BRAVOMaintenanceLogFile -Entry $Message
        return
    }

    # Звичайні повідомлення
    if ($NoTimestamp) {
        $logEntry = $Message
        $consoleEntry = $Message
    } else {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        $consoleEntry = if ($consoleSettings.ShowTimestampsInConsole) {
            $logEntry
        } else {
            $Message
        }
    }

    if ($messageLevel -ge $consoleThreshold) {
        Write-BRAVOConsoleMessage -Message $consoleEntry -Level $normalizedLevel
    }

    Write-BRAVOMaintenanceLogFile -Entry $logEntry
}

# Виділено з Write-Log: запис у файл повторювався чотири рази, і в кожній
# копії помилка запису йшла в консоль власним Write-Host повз розмітку.
function Write-BRAVOMaintenanceLogFile {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Entry)

    try {
        if (-not (Test-Path $LOG_DIR)) {
            New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
        }
        $Entry | Out-File -FilePath $LOG_FILE -Append -Encoding UTF8
    } catch {
        # Не через Write-Log: журнал саме зараз недоступний, і рекурсія лише
        # поглибила б проблему.
        Write-BRAVOConsoleMessage `
            -Message "Помилка запису у файл логу: $($_.Exception.Message)" `
            -Level 'WARNING'
    }
}

# ===== ФУНКЦІЯ АВТОМАТИЧНОГО ВИМКНЕННЯ =====
function Invoke-AutoShutdown {
    param(
        [int]$Timeout = 120
    )
    
    Write-Log -Message "==="
    Write-Log -Message "=== АВТОМАТИЧНЕ ВИМКНЕННЯ СИСТЕМИ ==="

    try {
        # Команда вимкнення
        $shutdownCommand = "shutdown /s /t $Timeout /c `"Система буде вимкнена через $Timeout секунд через завершення обслуговування BravoSoft. Для скасування виконайте: shutdown /a`""
        
        Write-Log -Message "Ініціювання вимкнення системи..." -Level "INFO"
        
        # Запускаємо вимкнення
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $shutdownCommand" -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0) {
            Write-Log -Message "Система буде вимкнена через $Timeout секунд" -Level "SUCCESS"
            
            # Просте вікно підтвердження
            Add-Type -AssemblyName System.Windows.Forms
            
            $message = "Система буде вимкнена через $Timeout секунд через завершення обслуговування BravoSoft.`n`nБажаєте скасувати вимкнення?"
            $caption = "BravoSoft - Завершення обслуговування"
            $buttons = [System.Windows.Forms.MessageBoxButtons]::YesNo
            $icon = [System.Windows.Forms.MessageBoxIcon]::Question
            
            $result = [System.Windows.Forms.MessageBox]::Show($message, $caption, $buttons, $icon)
            
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log -Message "Користувач скасував вимкнення системи" -Level "INFO"
                
                # Скасовуємо вимкнення
                $cancelProcess = Start-Process "shutdown" -ArgumentList "/a" -Wait -PassThru -NoNewWindow
                
                if ($cancelProcess.ExitCode -eq 0) {
                    Write-Log -Message "Вимкнення успішно скасовано" -Level "SUCCESS"
                    [System.Windows.Forms.MessageBox]::Show("Вимкнення скасовано! Система продовжить роботу.", "BravoSoft", 
                        [System.Windows.Forms.MessageBoxButtons]::OK, 
                        [System.Windows.Forms.MessageBoxIcon]::Information)
                } else {
                    Write-Log -Message "Не вдалося скасувати вимкнення" -Level "ERROR"
                    [System.Windows.Forms.MessageBox]::Show("Не вдалося скасувати вимкнення. Спробуйте виконати команду вручну: shutdown /a", "Помилка", 
                        [System.Windows.Forms.MessageBoxButtons]::OK, 
                        [System.Windows.Forms.MessageBoxIcon]::Warning)
                }
            } else {
                Write-Log -Message "Користувач підтвердив вимкнення системи" -Level "INFO"
                [System.Windows.Forms.MessageBox]::Show("Система буде вимкнена через $Timeout секунд.", "BravoSoft", 
                    [System.Windows.Forms.MessageBoxButtons]::OK, 
                    [System.Windows.Forms.MessageBoxIcon]::Information)
            }
            
        } else {
            Write-Log -Message "Помилка ініціювання вимкнення системи. Код помилки: $($process.ExitCode)" -Level "ERROR"
        }
    }
    catch {
        Write-Log -Message "Помилка під час спроби вимкнення системи: $($_.Exception.Message)" -Level "ERROR"
    }
}

# ===== ДОПОМІЖНІ ФУНКЦІЇ =====

# Функція форматування часу
function Format-Duration {
    param([TimeSpan]$duration)
    if ($duration.TotalHours -ge 1) {
        $hours = [math]::Floor($duration.TotalHours)
        $minutes = $duration.Minutes
        $seconds = $duration.Seconds
        return "$hours год. ${minutes}хв. ${seconds}сек."
    } elseif ($duration.TotalMinutes -ge 1) {
        return "$($duration.Minutes)хв. $($duration.Seconds)сек."
    } else {
        return "$($duration.Seconds) сек."
    }
}

# Перетворення числового дня в об'єкт DayOfWeek
$restoreDayMap = @{
    1 = [DayOfWeek]::Monday
    2 = [DayOfWeek]::Tuesday
    3 = [DayOfWeek]::Wednesday
    4 = [DayOfWeek]::Thursday
    5 = [DayOfWeek]::Friday
    6 = [DayOfWeek]::Saturday
    7 = [DayOfWeek]::Sunday
}
$RestoreDayOfWeek = $restoreDayMap[$RestoreDay]
$RestoreDayName = $RestoreDayOfWeek.ToString()

function Get-BRAVORestoreScheduledOccurrence {
    param([datetime]$Now = [datetime]::Now)

    $daysBack = (([int]$Now.DayOfWeek - [int]$RestoreDayOfWeek + 7) % 7)
    $candidate = $Now.Date.AddDays(-$daysBack).Add([TimeSpan]::Parse($RestoreTime))
    if ($candidate -gt $Now) { $candidate = $candidate.AddDays(-7) }
    return $candidate
}

function Read-BRAVORestoreState {
    $path = Join-Path $LOG_DIR 'BRAVO_RESTORE_STATE.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { Write-Log -Message "Не вдалося прочитати restore state: $($_.Exception.Message)" -Level 'WARNING'; return $null }
}

function Write-BRAVORestoreState {
    param([datetime]$ScheduledOccurrence, [string]$Status, [string]$Reason)
    $path = Join-Path $LOG_DIR 'BRAVO_RESTORE_STATE.json'
    $state = [pscustomobject]@{
        ScheduledOccurrence = $ScheduledOccurrence.ToString('o')
        Status = $Status
        Reason = $Reason
        UpdatedAt = ([datetime]::Now).ToString('o')
    }
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-BRAVOTaskExecutionState {
    $path = Join-Path $LOG_DIR 'BRAVO_TASK_EXECUTION_STATE.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @{ Maintenance = [string]$state.Maintenance; Backup = [string]$state.Backup }
    } catch { return @{} }
}

function Write-BRAVOTaskExecutionState {
    param([ValidateSet('Maintenance')][string]$TaskName)
    $path = Join-Path $LOG_DIR 'BRAVO_TASK_EXECUTION_STATE.json'
    $state = Get-BRAVOTaskExecutionState
    $state[$TaskName] = ([datetime]::Now).ToString('o')
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}



function New-MaintenanceNotificationMessage {
    param(
        [string]$Title,
        [string]$TitleEmoji,
        [timespan]$Duration,
        [string]$DurationLabel = "Тривалість виконання",
        [string[]]$StatusLines = @(),
        [string[]]$Details = @(),
        [string]$LogPath
    )

    $currentTime = Get-Date
    $ukrainianCulture = [System.Globalization.CultureInfo]::GetCultureInfo("uk-UA")
    $dateText = $currentTime.ToString("dd MMMM yyyy", $ukrainianCulture).Replace(" р.", "")
    $hostInformation = Get-HostInformation

    $lines = @(
        "$TitleEmoji *$Title*",
        ":derelict_house_building: Установа: $($script:ObjectName)",
        ":desktop_computer: Машина: $($hostInformation.MachineName)",
        ":globe_with_meridians: IP-адреси: $($hostInformation.LocalIP) | $($hostInformation.PublicIP)",
        ":spiral_calendar_pad: $dateText • $($currentTime.ToString('HH:mm:ss')) • :hourglass_flowing_sand: $(Format-Duration $Duration)",
        "🏷️ Версія BRAVO_MAINTENANCE: $($script:ScriptVersion) від $($script:ScriptDate) (build $(if ([string]::IsNullOrWhiteSpace($script:ScriptBuildId)) { 'невідома' } else { $script:ScriptBuildId }))"
    )

    $nonEmptyStatusLines = @($StatusLines | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($nonEmptyStatusLines.Count -gt 0) {
        $lines += ""
        $lines += $nonEmptyStatusLines
    }

    $detailLines = @()
    foreach ($detail in @($Details)) {
        foreach ($detailLine in ([string]$detail -split "\r?\n")) {
            # При копіюванні деякі клієнти додають коми до порожніх рядків.
            # Нормалізуємо їх і зберігаємо початкове маркування деталей.
            $trimmedDetail = $detailLine.Trim().TrimEnd(",").Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmedDetail)) {
                $detailLines += $trimmedDetail
            }
        }
    }
    if ($detailLines.Count -gt 0) {
        $lines += ""
        $lines += ":pushpin: Деталі подій:"
        $lines += $detailLines
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $lines += ""
        $lines += ":memo: Журнал обслуговування: $LogPath"
    }

    return $lines -join [Environment]::NewLine
}





function Invoke-NotificationWebhook {
    param([string]$Message)

    $notificationSeparator = (("━" * 36) -join "")
    $messageForWebhook = if ($Message.TrimStart().StartsWith($notificationSeparator)) {
        $Message
    } else {
        "$notificationSeparator`n$Message"
    }
    $outboundMessages = if ($NotificationProvider -eq "discord") {
        $discordMessage = ConvertTo-DiscordNotificationText -Message $messageForWebhook
        @(Split-DiscordNotificationText -Message $discordMessage)
    } else {
        @($messageForWebhook)
    }

    foreach ($outboundMessage in $outboundMessages) {
        # Інший код або завантажений модуль міг змінити глобальний протокол,
        # тому відновлюємо TLS 1.2 безпосередньо перед WebHook-запитом.
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject(
            [Net.SecurityProtocolType],
            3072
        )
        [Net.ServicePointManager]::Expect100Continue = $false

        $payload = if ($NotificationProvider -eq "discord") {
            @{
                content = $outboundMessage
                allowed_mentions = @{parse = @()}
            }
        } else {
            @{text = $outboundMessage}
        }
        $body = [System.Text.Encoding]::UTF8.GetBytes(
            ($payload | ConvertTo-BRAVOJson -Compress -Depth 5)
        )
        $request = [System.Net.WebRequest]::Create($NotificationWebhookUrl)
        $request.Method = "POST"
        $request.ContentType = "application/json; charset=utf-8"
        $request.ContentLength = $body.Length
        $request.Timeout = $NotificationRequestTimeoutSeconds * 1000
        $request.ReadWriteTimeout = $NotificationRequestTimeoutSeconds * 1000
        $request.ProtocolVersion = [Net.HttpVersion]::Version11
        $request.KeepAlive = $false
        $request.ServicePoint.Expect100Continue = $false

        $requestStream = $null
        $response = $null
        $reader = $null
        try {
            $requestStream = $request.GetRequestStream()
            $requestStream.Write($body, 0, $body.Length)
            $requestStream.Dispose()
            $requestStream = $null

            $response = $request.GetResponse()
            $reader = New-Object System.IO.StreamReader(
                $response.GetResponseStream(),
                [System.Text.Encoding]::UTF8
            )
            $responseText = $reader.ReadToEnd().Trim()

            if ($NotificationProvider -eq "slack" -and
                -not [string]::IsNullOrWhiteSpace($responseText) -and
                $responseText -ne "ok") {
                throw "Slack повернув неочікувану відповідь: $responseText"
            }
        } catch {
            $webhookError = $_.Exception.Message
            if ($webhookError -match "SSL/TLS|secure channel|защищенн|захищен") {
                throw "Не вдалося встановити TLS 1.2 з $NotificationProviderDisplayName. " +
                    "На Windows $([Environment]::OSVersion.Version) перевірте оновлення Schannel, " +
                    ".NET Framework і підтримку сучасних TLS-шифрів. Початкова помилка: $webhookError"
            }
            throw
        } finally {
            if ($requestStream) { $requestStream.Dispose() }
            if ($reader) { $reader.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}

# Функція підготовки повідомлень для вибраного каналу.
function Send-SlackAlert {
    param(
        [string]$Message,
        [switch]$IsCritical
    )
    
    # Перевірка режиму "none" - повне вимкнення всіх повідомлень
    if ($script:SlackMode -eq "none") {
        return
    }
    
    # Автоматично визначаємо критичність для помилок місця
    $isSpaceError = $Message -match (
        "Недостатньо вільного місця|не вистачає місця|" +
        "Помилка перевірки місця|Локальні диски типу Fixed|" +
        "Шлях .* не існує або недоступний"
    )
    
    if ($IsCritical -or $isSpaceError) {
        $script:CriticalErrors = $true
        $script:criticalErrorOccurred = $true
        
        # Для критичних помилок перевіряємо режим "errors_only" або "all"
        if ($script:SlackMode -eq "errors_only" -or $script:SlackMode -eq "all") {
            if ($isSpaceError) {
                # Для помилок місця - негайна відправка
                try {
                    $outboundMessage = New-MaintenanceNotificationMessage `
                        -Title "КРИТИЧНА ПОМИЛКА ОБСЛУГОВУВАННЯ" `
                        -TitleEmoji ":rotating_light:" `
                        -Duration ((Get-Date) - $script:ScriptStartTime) `
                        -Details @($Message) `
                        -LogPath $LOG_FILE
                    Invoke-NotificationWebhook -Message $outboundMessage
                    Write-Log "Критичне повідомлення (помилки місця) відправлено в $NotificationProviderDisplayName" -Level "INFO"
                }
                catch {
                    Write-Log "ПОМИЛКА негайної відправки: $($_.Exception.Message)" -Level "ERROR"
                }
            }
            else {
                # Для інших критичних помилок - додаємо до списку для групування
                $script:CriticalErrorsList.Add($Message)
            }
        }
    }
    else {
        # Відправляємо не-критичні повідомлення тільки в режимі "all"
        if ($script:SlackMode -ne "all") {
            return
        }
        
        $script:SlackMessageBuffer.Add($Message)
    }
}

function Send-InactiveServiceWarning {
    param([string[]]$ServiceDescriptions)

    $inactiveServices = @($ServiceDescriptions | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | Select-Object -Unique)
    if ($inactiveServices.Count -eq 0) {
        return
    }

    $serviceList = $inactiveServices -join ", "
    Write-Log -Message "До початку maintenance не запущені служби: $serviceList" -Level "WARNING"
    if ($script:SlackMode -eq "none") {
        Write-Log -Message "Сповіщення про зупинені служби вимкнено режимом none" -Level "INFO"
        return
    }

    try {
        $notificationMessage = New-MaintenanceNotificationMessage `
            -Title "СЛУЖБИ НЕ ЗАПУЩЕНІ ПЕРЕД MAINTENANCE" `
            -TitleEmoji ":warning:" `
            -Duration ((Get-Date) - $script:ScriptStartTime) `
            -Details @(
                "Служби: $serviceList",
                "Скрипт збереже початковий стан і не запускатиме ці служби автоматично."
            ) `
            -LogPath $LOG_FILE
        Invoke-NotificationWebhook -Message $notificationMessage
        Write-Log -Message "Сповіщення про зупинені служби відправлено в $NotificationProviderDisplayName" -Level "SUCCESS"
    } catch {
        Write-Log -Message "Не вдалося відправити сповіщення про зупинені служби: $($_.Exception.Message)" -Level "ERROR"
    }
}

# Перевірка заповнення діапазонів ID за даними служби BRAVO
function Test-RangeIdUsage {
    param(
        [string]$Path,
        [double]$ThresholdPercent
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $errorMessage = "Файл контролю діапазонів ID не знайдено: $Path"
        Write-Log $errorMessage -Level "WARNING"
        # Без вихідного файла неможливо підтвердити стан ID-інтервалів.
        # Критичний статус забезпечує сповіщення і в режимі errors_only.
        Send-SlackAlert -Message $errorMessage -IsCritical
        return
    }

    $rangeData = $null
    $readError = $null
    $detectedEncoding = $null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            try {
                $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
                $jsonText = $utf8Strict.GetString($bytes)
                $detectedEncoding = "UTF-8"
            } catch {
                $jsonText = [System.Text.Encoding]::GetEncoding(1251).GetString($bytes)
                $detectedEncoding = "Windows-1251"
            }

            $jsonText = $jsonText.TrimStart([char]0xFEFF)
            $rangeData = $jsonText | ConvertFrom-BRAVOJson
            $readError = $null
            break
        } catch {
            $readError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Seconds 1
            }
        }
    }

    if ($readError -or -not $rangeData) {
        Write-Log "Не вдалося прочитати файл контролю діапазонів ID '$Path': $($readError.Exception.Message)" -Level "WARNING"
        return
    }

    $rangeEntries = @()
    foreach ($sectionName in @("critical", "warning_client", "warning_server", "info")) {
        $section = $rangeData.PSObject.Properties[$sectionName]
        if ($section) {
            $rangeEntries += @($section.Value)
        }
    }

    $exceededRanges = @()
    $seenRanges = @{}
    foreach ($entry in $rangeEntries) {
        if ($null -eq $entry -or
            $null -eq $entry.PSObject.Properties['file'] -or
            $null -eq $entry.PSObject.Properties['filled']) {
            continue
        }

        try {
            $filledPercent = [System.Convert]::ToDouble($entry.filled, [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            Write-Log "Некоректне значення filled для '$($entry.file)' у файлі $Path" -Level "WARNING"
            continue
        }

        if ($filledPercent -gt $ThresholdPercent) {
            $rangeName = [string]$entry.file
            $rangeKey = "$rangeName|$filledPercent"
            if (-not $seenRanges.ContainsKey($rangeKey)) {
                $seenRanges[$rangeKey] = $true
                $exceededRanges += [PSCustomObject]@{
                    Name = $rangeName
                    Percent = $filledPercent
                }
            }
        }
    }

    if ($exceededRanges.Count -eq 0) {
        Write-Log "Діапазони ID не перевищують поріг $($ThresholdPercent)% (файл: $Path, кодування: $detectedEncoding)" -Level "INFO"
        return
    }

    $thresholdText = $ThresholdPercent.ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture)
    $alertLines = $exceededRanges |
        Sort-Object Percent -Descending |
        ForEach-Object {
            $percentText = $_.Percent.ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture)
            "- $($_.Name): ${percentText}%"
        }

    $sourceFileName = [System.IO.Path]::GetFileName($Path)
    $message = "Перевищено поріг використання діапазонів ID (${thresholdText}%):`n$($alertLines -join "`n")"
    $message += "`nФайл: $sourceFileName"
    if ($rangeData.time) {
        $message += "`nЧас оновлення даних: $($rangeData.time)"
    }

    Write-Log $message -Level "WARNING"
    Send-SlackAlert -Message $message -IsCritical
}

# Функція форматування виводу команд
function Format-CommandOutput {
    param([string]$Output)
    return "`n" + ($Output -replace "`r?`n", "`n    ") + "`n"
}

# Функція форматування розміру файлу
function Format-FileSize {
    param([long]$size)
    switch ($size) {
        { $_ -ge 1GB } { return "{0:N2} ГБ" -f ($size / 1GB) }
        { $_ -ge 1MB } { return "{0:N2} МБ" -f ($size / 1MB) }
        { $_ -ge 1KB } { return "{0:N2} КБ" -f ($size / 1KB) }
        default { return "$size байт" }
    }
}

# Функція переміщення файлів з послідовністю
function Move-WithSequence {
    param(
        [string]$sourcePath,
        [string]$destDir,
        [switch]$SkipIfEmpty
    )
    
    if (-not (Test-Path $sourcePath)) {
        Write-Log "Файл $([System.IO.Path]::GetFileName($sourcePath)) не знайдено" -Level "ERROR"
        return $false
    }
    
    $fileInfo = Get-Item $sourcePath
    if ($fileInfo.Length -eq 0 -and $SkipIfEmpty) {
        Write-Log "Пропущено порожній файл: $([System.IO.Path]::GetFileName($sourcePath))" -Level "INFO"
        return $false
    }
    
    New-Item -Path $destDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath)
    $fileExt = [System.IO.Path]::GetExtension($sourcePath)
    
    $existingFiles = Get-BRAVOFiles -Path $destDir -Filter "${fileName}_*$fileExt"
    $maxNumber = 0
    
    foreach ($file in $existingFiles) {
        $baseName = $file.BaseName
        if ($baseName -match "${fileName}_(\d{6})$") {
            $num = [int]$Matches[1]
            if ($num -gt $maxNumber) { $maxNumber = $num }
        }
    }

    $nextNumber = $maxNumber + 1

    if ($nextNumber -gt 999999) {
        Write-Log "Досягнуто максимальну кількість архівних файлів (999999) для $fileName" -Level "ERROR"
        return $false
    }

    $suffix = $nextNumber.ToString("000000")
    $newName = "${fileName}_${suffix}${fileExt}"
    $destPath = Join-Path -Path $destDir -ChildPath $newName

    for ($attempt = 1; $attempt -le $MoveRetryCount; $attempt++) {
        try {
            Move-Item -Path $sourcePath -Destination $destPath -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
                throw "файл призначення не створено"
            }
            Write-Log "Переміщено $([System.IO.Path]::GetFileName($sourcePath)) до $newName" -Level "SUCCESS"
            return $true
        }
        catch {
            if ($attempt -lt $MoveRetryCount) {
                Write-Log "Файл $([System.IO.Path]::GetFileName($sourcePath)) зайнятий або недоступний; повторна спроба $($attempt + 1) з $MoveRetryCount через $MoveRetryDelaySeconds сек." -Level "WARNING"
                if ($MoveRetryDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $MoveRetryDelaySeconds
                }
            } else {
                Write-Log "Не вдалося перемістити $([System.IO.Path]::GetFileName($sourcePath)) після $MoveRetryCount спроб: $($_.Exception.Message)" -Level "ERROR"
                $script:criticalErrorOccurred = $true
                return $false
            }
        }
    }

    return $false
}

# Функція порівняння розмірів файлів
function Compare-FileSizes {
    param(
        [string]$BeforeFile,
        [string]$ModelPath,
        [int]$MinSizeBytes = 2048
    )
    
    $criticalChanges = $false
    try {
        if (-not (Test-Path $BeforeFile)) {
            Write-Log "Файл з початковими розмірами не знайдено: $BeforeFile" -Level "ERROR"
            $script:criticalErrorOccurred = $true
            $script:restoreIntegrityFailed = $true
            return $true
        }

        $initialData = @(Import-Csv -Path $BeforeFile)
        if ($initialData.Count -eq 0) {
            Write-Log "Початковий список файлів MODEL порожній; цілісність після реставрації неможливо підтвердити" -Level "ERROR"
            $script:criticalErrorOccurred = $true
            $script:restoreIntegrityFailed = $true
            return $true
        }

        $criticalFiles = @()
        $currentLookup = @{}
        foreach ($file in @(Get-BRAVOFiles -Path $ModelPath -Recurse)) {
            $relativePath = $file.FullName.Replace($ModelPath, "").TrimStart('\')
            $currentLookup[$relativePath] = [long]$file.Length
        }

        # Перевіряємо початковий набір, а не лише поточні файли. Інакше повністю
        # видалений bravocmd.exe файл не потрапляв до результату порівняння.
        foreach ($item in $initialData) {
            $relativePath = [string]$item.RelativePath
            $initialSizeBytes = [long]$item.SizeBytes
            $currentSizeBytes = if ($currentLookup.ContainsKey($relativePath)) {
                [long]$currentLookup[$relativePath]
            } else {
                -1
            }
            $isMissing = $currentSizeBytes -lt 0
            $reductionPercent = if (-not $isMissing -and $initialSizeBytes -gt 0) {
                (($initialSizeBytes - $currentSizeBytes) / [double]$initialSizeBytes) * 100
            } else {
                100
            }
            $isCriticalReduction = (
                $initialSizeBytes -gt $MinSizeBytes -and
                $currentSizeBytes -lt $initialSizeBytes -and
                ($currentSizeBytes -le $MinSizeBytes -or $reductionPercent -ge 50)
            )

            if ($isMissing -or $isCriticalReduction) {
                $criticalFiles += [PSCustomObject]@{
                    File = $relativePath
                    BeforeSizeBytes = $initialSizeBytes
                    AfterSizeBytes = $currentSizeBytes
                    Missing = $isMissing
                }
                $criticalChanges = $true
            }
        }

        if ($criticalFiles.Count -gt 0) {
            $criticalMessage = "Знайдено $($criticalFiles.Count) файлів з критичною зміною розміру після реставрації:`n"
            foreach ($file in $criticalFiles) {
                $beforeFormatted = Format-FileSize $file.BeforeSizeBytes
                $afterFormatted = if ($file.Missing) { "ФАЙЛ ВІДСУТНІЙ" } else { Format-FileSize $file.AfterSizeBytes }
                $reductionPercent = if ($file.Missing -or $file.BeforeSizeBytes -le 0) {
                    100
                } else {
                    ($file.BeforeSizeBytes - $file.AfterSizeBytes) / $file.BeforeSizeBytes * 100
                }
                
                $criticalMessage += " - $($file.File):`n"
                $criticalMessage += "   Розмір до реставрації: $beforeFormatted ($($file.BeforeSizeBytes) байт)`n"
                $criticalMessage += "   Розмір після реставрації: $afterFormatted ($($file.AfterSizeBytes) байт)`n"
                $statusText = if ($file.Missing) { "ФАЙЛ ВИДАЛЕНО" } else { "РЕДУКЦІЯ" }
                $criticalMessage += "   Статус: ❌ $statusText (зменшено на $($reductionPercent.ToString('0.00'))%)`n"
            }
            
            Write-Log $criticalMessage -Level "ERROR"
            Send-SlackAlert -Message $criticalMessage -IsCritical
            $script:criticalErrorOccurred = $true
            $script:restoreIntegrityFailed = $true

            return $true
        } else {
            Write-Log "Відсутніх файлів або критичних зменшень розміру не знайдено" -Level "INFO"
            return $false
        }
    }
    catch {
        $errorMsg = "Помилка при порівнянні розмірів файлів: $_"
        Write-Log $errorMsg -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
        $script:restoreIntegrityFailed = $true
        # Неможливість довести цілісність MODEL є критичною подією. Повертаємо
        # $true, щоб викликач виконав відкат і не створив маркер успіху.
        return $true
    }
}

# Функція відновлення з архіву (для відкату при помилках)
function Restore-FromArchive {
    param(
        [string]$ArchivePath,
        [string]$Destination,
        $ARC_PATH
    )
    
    if (-not (Test-Path $ArchivePath)) {
        $errorMsg = "Архів для відновлення не знайдено: $ArchivePath"
        Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
        $script:restoreArchiveFailed = $true
        return 1
    }

    if (-not (Test-BRAVOMaintenanceSevenZipArchiveIntegrity `
            -SevenZipPath $ARC_PATH `
            -ArchivePath $ArchivePath)) {
        $errorMsg = "Відновлення скасовано: архів не пройшов перевірку цілісності 7-Zip: $ArchivePath"
        Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
        $script:restoreIntegrityFailed = $true
        return 2
    }

    $extractParams = @(
        'x',
        "-o$Destination",
        "-y",
        $ArchivePath
    )
    
    $exitCode = Invoke-CommandWithLog `
        -Command $ARC_PATH `
        -Arguments $extractParams `
        -Description "Відновлення моделі з архіву" `
        -StandardInputText $script:ArchivePassword
    
    if ($exitCode -eq 0) {
        Write-Log "Модель успішно відновлена з архіву: $([System.IO.Path]::GetFileName($ArchivePath))" -Level "SUCCESS"
    } else {
        $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $exitCode
        $errorMsg = "Не вдалося відновити модель з архіву! Код 7-Zip: $exitCode — $exitDescription"
        Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
        $script:restoreArchiveFailed = $true
    }

    return $exitCode
}

# Функція виконання команд з логуванням
function Invoke-CommandWithLog {
    param(
        [string]$Command,
        [array]$Arguments,
        [string]$Description,
        [int]$TimeoutSeconds = $NativeCommandTimeoutSeconds,
        [AllowNull()][string]$StandardInputText = $null
    )
    
    Write-Log "$Description..." -Level "INFO"
    $process = $null
    $outputCapture = $null
    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $Command
        $processInfo.Arguments = (
            @($Arguments | ForEach-Object {
                ConvertTo-BRAVOWindowsCommandLineArgument -Argument ([string]$_)
            }) -join " "
        )
        $processInfo.RedirectStandardInput = $null -ne $StandardInputText
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        if ($null -ne $StandardInputText) {
            $process.StandardInput.WriteLine($StandardInputText)
            $process.StandardInput.Close()
        }
        $timeoutMilliseconds = [int][math]::Min(
            [double][int]::MaxValue,
            [double][math]::Max(1, $TimeoutSeconds) * 1000
        )
        $completed = $process.WaitForExit($timeoutMilliseconds)
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                Write-Log "Не вдалося завершити процес після таймауту: $($_.Exception.Message)" -Level "WARNING"
            }
            if (-not $process.HasExited) {
                throw "${Description}: процес не завершився після таймауту"
            }
        }

        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $outputCapture = $null
        $output = @(
            [string]$capturedOutput.StandardOutput,
            [string]$capturedOutput.StandardError
        ) -join [Environment]::NewLine
        $exitCode = if ($completed) { [int]$process.ExitCode } else { 258 }
    } catch {
        $errorMsg = "ПОМИЛКА під час ${Description}: $($_.Exception.Message)"
        Write-Log $errorMsg -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
        $script:restoreArchiveFailed = $true
        return 258
    } finally {
        if ($null -ne $outputCapture) {
            try {
                [void](Complete-BRAVOProcessOutputCapture -Capture $outputCapture)
            } catch {
                # Дренаж потоків уже завершеного процесу. Виконується у
                # finally на шляху обробки помилки — початкова причина
                # важливіша, тому DEBUG, але без запису незрозуміло, чому
                # в лозі немає виводу 7-Zip.
                Write-BRAVOLog `
                    -Component 'MAINTENANCE' `
                    -Message "Не вдалося завершити збір виводу процесу: $($_.Exception.Message)" `
                    -Level "DEBUG"
            }
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    $formattedOutput = Format-CommandOutput -Output $output
    
    if ($exitCode -eq 0) {
        Write-Log "$Description успішно завершено" -Level "SUCCESS"
    } else {
        $errorMsg = "ПОМИЛКА під час $Description. Код: $exitCode"
        Write-Log $errorMsg -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
        $script:restoreArchiveFailed = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($formattedOutput)) {
        Write-Log "Деталі виконання:$formattedOutput" -Level "DEBUG"
    }
    
    return $exitCode
}

function Test-BRAVOMaintenanceSevenZipArchiveIntegrity {
    param(
        [string]$SevenZipPath,
        [string]$ArchivePath
    )

    $integrityValid = Test-SevenZipArchiveIntegrity `
        -SevenZipPath $SevenZipPath `
        -ArchivePath $ArchivePath `
        -Password $script:ArchivePassword `
        -TimeoutSeconds $SevenZipIntegrityTestTimeoutSeconds `
        -Logger { param($Message, $Level) Write-Log $Message -Level $Level }
    if (-not $integrityValid) {
        $script:criticalErrorOccurred = $true
        $script:restoreIntegrityFailed = $true
    }
    return $integrityValid
}

# Функція обробки лог-файлів
function Process-Logs {
    param(
        [string]$LogType,
        [string]$SourceDir,
        [string]$DestDir
    )
    
    if (-not (Test-Path $SourceDir)) {
        Write-Log "Директорія $SourceDir не знайдена. Обробка логів $LogType пропущена." -Level "ERROR"
        return
    }
    
    $logFiles = @(Get-BRAVOFiles -Path $SourceDir |
        Where-Object { $_.Length -gt 0 })
    
    if (-not $logFiles) {
        Write-Log "У директорії $SourceDir немає файлів логів для обробки ($LogType)." -Level "INFO"
        return
    }
    
    New-Item -Path $DestDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    
    foreach ($file in $logFiles) {
        [void](Move-WithSequence -sourcePath $file.FullName -destDir $DestDir -SkipIfEmpty)
    }
    Write-Log "Оброблено $($logFiles.Count) $LogType файлів" -Level "SUCCESS"
}

# Функція архівації старих даних
function Compress-OldData {
    param(
        [string]$ParentPath,
        [string]$ArchiveNamePrefix,
        [int]$RetentionDays,
        $arcCommonParams,
        $ARC_PATH
    )
    
    if (-not (Test-Path $ParentPath)) {
        Write-Log "Директорія $ParentPath не знайдена. Архівація пропущена." -Level "ERROR"
        return
    }
    
    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
    $oldDirs = @(
        Get-BRAVODirectories -Path $ParentPath |
            Where-Object {
                $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and
                $_.CreationTime -lt $cutoffDate
            } |
            Sort-Object Name
    )
    
    if (-not $oldDirs) {
        Write-Log "Немає старих директорій для архівації у $ParentPath" -Level "DEBUG"
        return
    }

    $archivedCount = 0
    $errorCount = 0
    $directoryIndex = 0
    Write-Log "Знайдено $($oldDirs.Count) старих директорій для архівації у $ParentPath" -Level "INFO"

    foreach ($dir in $oldDirs) {
        $directoryIndex++
        $dirName = $dir.Name
        $archiveName = "${ArchiveNamePrefix}_$dirName.mdz"
        $archivePath = Join-Path -Path $ParentPath -ChildPath $archiveName
        $progressPercent = [math]::Floor(($directoryIndex * 100.0) / [math]::Max(1, $oldDirs.Count))
        Write-Progress `
            -Id 20 `
            -Activity "BRAVO_MAINTENANCE — архівація старих даних" `
            -Status "$dirName ($directoryIndex з $($oldDirs.Count))" `
            -PercentComplete $progressPercent
        
        try {
            $arcArgs = $arcCommonParams + @("$archivePath", "$($dir.FullName)")
            $exitCode = Invoke-CommandWithLog `
                -Command $ARC_PATH `
                -Arguments $arcArgs `
                -Description "Архівація $dirName -> $archiveName" `
                -StandardInputText $script:ArchivePassword
            
            if ($exitCode -eq 0 -and
                (Test-BRAVOMaintenanceSevenZipArchiveIntegrity `
                    -SevenZipPath $ARC_PATH `
                    -ArchivePath $archivePath)) {
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                $archivedCount++
            } else {
                if ($exitCode -eq 0) {
                    Write-Log "Каталог $($dir.FullName) не видалено: створений архів не пройшов перевірку 7-Zip" -Level "ERROR"
                } else {
                    $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $exitCode
                    Write-Log "Каталог $($dir.FullName) не видалено: створення архіву завершилося кодом 7-Zip $exitCode — $exitDescription" -Level "ERROR"
                }
                $errorCount++
            }
        }
        catch {
            $errorCount++
            Write-Log "ПОМИЛКА при архівації ${dirName}: $($_.Exception.Message)" -Level "ERROR"
        }
    }
    Write-Progress -Id 20 -Activity "BRAVO_MAINTENANCE — архівація старих даних" -Completed
    
    if ($archivedCount -gt 0) {
        Write-Log "Архівовано $archivedCount директорій" -Level "SUCCESS"
    }
    if ($errorCount -gt 0) {
        $errorMsg = "Виникло $errorCount помилок під час архівації"
        Write-Log "$errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg
        $script:criticalErrorOccurred = $true
        $script:restoreArchiveFailed = $true
    }
}

# Функція видалення старих лог-файлів
function Remove-OldLogFiles {
    param(
        [string]$Path,
        [int]$RetentionDays
    )

    if (-not (Test-Path $Path)) {
        Write-Log "Директорія логів $Path не знайдена. Видалення пропущено." -Level "INFO"
        return
    }

    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
    # Включаємо журнали maintenance, застарілий формат, розміри файлів і маркери.
    $oldFiles = Get-BRAVOFiles -Path $Path |
        Where-Object { 
            $_.CreationTime -lt $cutoffDate -and 
            ($_.Name -like "BRAVO_MAINTENANCE_*.log" -or
             $_.Name -like "script_log_*.txt" -or
             $_.Name -like "file_sizes_*.csv" -or 
             $_.Name -like "restore_done_*.marker")
        }

    if (-not $oldFiles) {
        Write-Log "Немає старих лог-файлів для видалення у $Path" -Level "DEBUG"
        return
    }

    $deletedCount = 0
    $errorCount = 0

    foreach ($file in $oldFiles) {
        try {
            Remove-Item -Path $file.FullName -Force -ErrorAction Stop
            $deletedCount++
            Write-Log "Видалено лог-файл: $($file.Name)" -Level "SUCCESS"
        }
        catch {
            $errorCount++
            Write-Log "ПОМИЛКА при видаленні $($file.Name): $($_.Exception.Message)" -Level "ERROR"
        }
    }

    if ($deletedCount -gt 0) {
        Write-Log "Видалено $deletedCount старих лог-файлів" -Level "SUCCESS"
    }
    if ($errorCount -gt 0) {
        $errorMsg = "Виникло $errorCount помилок під час видалення лог-файлів"
        Write-Log "$errorMsg" -Level "ERROR"
    }
}

# Функція обробки старих даних
function Process-OldData {
    param(
        [string]$Path,
        [string]$ArchiveNamePrefix,
        [int]$RetentionDays,
        $arcCommonParams,
        $ARC_PATH
    )
    
    # Compress-OldData самостійно видаляє каталог лише після успішного
    # завершення 7-Zip. Повторне безумовне видалення тут неприпустиме:
    # воно знищувало саме ті каталоги, архівація яких завершилася помилкою.
    Compress-OldData -ParentPath $Path -ArchiveNamePrefix $ArchiveNamePrefix -RetentionDays $RetentionDays -arcCommonParams $arcCommonParams -ARC_PATH $ARC_PATH
}

# Функція видалення старих архівів реставрації (за кількістю версій)
function Remove-OldRestoreArchives {
    param(
        [string]$Path,
        [string]$ArchivePrefix,
        [int]$KeepCount = 2,
        [int]$InvalidRetentionDays = 30
    )

    if (-not (Test-Path $Path)) {
        Write-Log "Директорія архівів $Path не знайдена. Видалення пропущено." -Level "DEBUG"
        return
    }

    # Шаблони для пошуку основних архівів (без .sha512)
    $mainArchivePatterns = @(
        "${ArchivePrefix}_before_*.mdz",
        "${ArchivePrefix}_after_*.mdz"
    )

    # Збираємо основні архіви (без контрольних сум)
    $mainArchiveFiles = @($mainArchivePatterns | ForEach-Object {
        Get-ChildItem -Path $Path -Filter $_ -ErrorAction SilentlyContinue
    })

    if (-not $mainArchiveFiles -or $mainArchiveFiles.Count -eq 0) {
        Write-Log "Немає основних архівів реставрації для обробки у $Path" -Level "DEBUG"
        return
    }

    $archiveGroups = $mainArchiveFiles | Group-Object { 
        if ($_.Name -match "${ArchivePrefixRegex}_(before|after)_(\d{8}_\d{4})\.mdz") {
            $Matches[2]
        } else {
            $_.CreationTime.ToString("yyyyMMdd_HHmm")
        }
    }

    # До ліміту версій зараховуються лише сесії, що мають хоча б один
    # повністю перевірений архів. Неповна нова сесія не повинна витіснити
    # стару придатну точку відновлення.
    $validGroups = @()
    $invalidGroups = @()
    foreach ($group in $archiveGroups) {
        $validArchiveCount = 0
        foreach ($archive in @($group.Group)) {
            $hashPath = "$($archive.FullName).sha512"
            $archiveValid = $false
            try {
                if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
                    throw "відсутній hash-файл"
                }
                $hashText = ([System.IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
                if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
                    throw "некоректний формат hash-файлу"
                }
                if ($Matches.FileName -cne $archive.Name) {
                    throw "hash-файл належить іншому архіву"
                }
                $expectedHash = $Matches.Hash.ToUpperInvariant()
                $actualHash = Get-SHA512HashCompatible -FilePath $archive.FullName
                if ($actualHash -cne $expectedHash) {
                    throw "SHA512 не збігається"
                }
                if (-not (Test-BRAVOMaintenanceSevenZipArchiveIntegrity `
                        -SevenZipPath $ARC_PATH `
                        -ArchivePath $archive.FullName)) {
                    throw "перевірка 7z t не пройдена"
                }
                $archiveValid = $true
                $validArchiveCount++
            } catch {
                Write-Log "Архів реставрації не зараховано як точку відновлення: $($archive.Name) — $($_.Exception.Message)" -Level "WARNING"
            }
        }

        if ($validArchiveCount -gt 0) {
            $validGroups += $group
        } else {
            $invalidGroups += $group
        }
    }

    $sortedGroups = @($validGroups | Sort-Object Name -Descending)
    $groupsToKeep = @($sortedGroups | Select-Object -First $KeepCount)
    $groupsToDelete = @($sortedGroups | Select-Object -Skip $KeepCount)
    $invalidCutoff = (Get-Date).AddDays(-[math]::Max(1, $InvalidRetentionDays))
    $staleInvalidGroups = @(
        $invalidGroups | Where-Object {
            $newestInvalidFile = $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $null -ne $newestInvalidFile -and $newestInvalidFile.LastWriteTime -lt $invalidCutoff
        }
    )
    if ($staleInvalidGroups.Count -gt 0) {
        Write-Log "Видаляємо $($staleInvalidGroups.Count) непридатних сесій, старших за $InvalidRetentionDays днів" -Level "WARNING"
        $groupsToDelete = @($groupsToDelete) + @($staleInvalidGroups)
    }

    if ($groupsToDelete.Count -eq 0) {
        # Не виводимо повідомлення, якщо немає що видаляти
        return
    }

    Write-Log "Знайдено $($mainArchiveFiles.Count) архівів реставрації" -Level "INFO"
    Write-Log "Зберігаємо $($groupsToKeep.Count) найсвіжіших сесій архівів, видаляємо $($groupsToDelete.Count) найстаріших сесій" -Level "INFO"

    # Показуємо які сесії зберігаємо (тільки в режимі DEBUG)
    Write-Log "Сесії для збереження (найсвіжіші):" -Level "DEBUG"
    foreach ($group in $groupsToKeep) {
        $sessionTime = $group.Name
        $beforeCount = ($group.Group | Where-Object { $_.Name -like "*_before_*" }).Count
        $afterCount = ($group.Group | Where-Object { $_.Name -like "*_after_*" }).Count
        Write-Log "  - $sessionTime (before: $beforeCount, after: $afterCount)" -Level "DEBUG"
    }

    $deletedCount = 0
    $errorCount = 0

    # Видаляємо найстаріші сесії (всі файли пов'язані з цими сесіями)
    foreach ($group in $groupsToDelete) {
        $sessionTime = $group.Name
        Write-Log "Видалення сесії: $sessionTime ($($group.Count) файлів)..." -Level "INFO"
        
        # Видаляємо всі файли цієї сесії (основні архіви та контрольні суми)
        $sessionFiles = Get-ChildItem -Path $Path -ErrorAction SilentlyContinue | 
            Where-Object { 
                $_.Name -match "${ArchivePrefixRegex}_(before|after)_${sessionTime}" 
            }
        
        foreach ($file in $sessionFiles) {
            try {
                Write-Log "  Видалення: $($file.Name)..." -Level "DEBUG"
                Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                $deletedCount++
                Write-Log "  Старий архів видалено: $($file.Name)" -Level "SUCCESS"
            }
            catch {
                $errorCount++
                Write-Log "  ПОМИЛКА при видаленні $($file.Name): $($_.Exception.Message)" -Level "ERROR"
            }
        }
    }

    # Логуємо результати
    if ($deletedCount -gt 0) {
        Write-Log "Видалено $deletedCount файлів зі старих сесій архівів (збережено $KeepCount найсвіжіших сесій)" -Level "SUCCESS"
        
        # Показуємо що залишилось (тільки в режимі DEBUG)
        $remainingFiles = Get-ChildItem -Path $Path -Filter "${ArchivePrefix}_*" -ErrorAction SilentlyContinue
        if ($remainingFiles) {
            Write-Log "Залишилось архівів: $($remainingFiles.Count)" -Level "DEBUG"
            foreach ($file in $remainingFiles) {
                Write-Log "  - $($file.Name)" -Level "DEBUG"
            }
        }
    }
    
    if ($errorCount -gt 0) {
        $errorMsg = "Виникло $errorCount помилок під час видалення старих архівів"
        Write-Log "$errorMsg" -Level "ERROR"
    }
}

# ===== ФУНКЦІЯ ПЕРЕВІРКИ ВІЛЬНОГО МІСЦЯ =====
function Check-FreeSpace {
    param(
        [string]$ROOT_LIMS,
        [string[]]$ExcludedDrives = @()
    )
    
    Write-Log "Перевірка вільного місця на всіх локальних дисках..." -Level "DEBUG"
    
    try {
        if (-not (Test-Path $ROOT_LIMS)) {
            $errorMsg = "Шлях $ROOT_LIMS не існує або недоступний"
            Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
            # В режимі "none" не відправляємо повідомлення
            if ($script:SlackMode -ne "none") {
                Send-SlackAlert -Message $errorMsg -IsCritical
            }
            $script:criticalErrorOccurred = $true
            return $false
        }

        $localDrives = @(
            [System.IO.DriveInfo]::GetDrives() |
                Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed } |
                Sort-Object -Property Name
        )

        if ($localDrives.Count -eq 0) {
            $errorMsg = "Локальні диски типу Fixed не знайдено"
            Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
            if ($script:SlackMode -ne "none") {
                Send-SlackAlert -Message $errorMsg -IsCritical
            }
            $script:criticalErrorOccurred = $true
            return $false
        }

        $checkedDriveCount = 0
        $driveStatus = @()
        $spaceProblems = @()
        $minimumFreeSpaceBytes = $MIN_FREE_SPACE * 1GB

        foreach ($driveInfo in $localDrives) {
            $driveName = $driveInfo.Name.TrimEnd('\').ToUpperInvariant()

            if ($ExcludedDrives -contains $driveName) {
                Write-Log "Диск ${driveName} виключено з перевірки вільного місця" -Level "INFO"
                continue
            }

            $checkedDriveCount++

            if (-not $driveInfo.IsReady) {
                $problemText = "диск $driveName не готовий або недоступний"
                $spaceProblems += $problemText
                Write-Log $problemText -Level "ERROR"
                continue
            }

            $freeSpaceGB = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 2)
            $totalSpaceGB = [math]::Round($driveInfo.TotalSize / 1GB, 2)
            $driveStatus += "${driveName} ${freeSpaceGB} GB з ${totalSpaceGB} GB"

            Write-Log "Диск ${driveName}: доступно ${freeSpaceGB} GB з ${totalSpaceGB} GB (потрібно мінімум: ${MIN_FREE_SPACE} GB)" -Level "INFO"

            if ($driveInfo.AvailableFreeSpace -lt $minimumFreeSpaceBytes) {
                $spaceProblems += "диск ${driveName}: залишилось ${freeSpaceGB} GB, потрібно мінімум ${MIN_FREE_SPACE} GB"
            }
        }

        if ($checkedDriveCount -eq 0) {
            Write-Log "Усі локальні диски виключено з перевірки вільного місця" -Level "WARNING"
            return $true
        }

        if ($spaceProblems.Count -gt 0) {
            $errorMsg = "Недостатньо вільного місця або не вдалося перевірити локальні диски: $($spaceProblems -join '; ')"
            Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"

            if ($script:SlackMode -ne "none") {
                Send-SlackAlert -Message $errorMsg -IsCritical
            }

            $script:criticalErrorOccurred = $true
            return $false
        }

        $script:freeSpaceSummary = @($driveStatus)
        if ($script:SlackMode -eq "all") {
            $infoMsg = "Достатньо вільного місця на локальних дисках: $($driveStatus -join '; ') (мінімум ${MIN_FREE_SPACE} GB на кожному)"
            Send-SlackAlert -Message $infoMsg
        }

        return $true
    }
    catch {
        $errorMsg = "Помилка перевірки місця: $($_.Exception.Message)"
        Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
        # В режимі "none" не відправляємо повідомлення
        if ($script:SlackMode -ne "none") {
            Send-SlackAlert -Message $errorMsg -IsCritical
        }
        $script:criticalErrorOccurred = $true
        return $false
    }
}

# Функція перевірки контрольних сум архіву
function Get-SHA512HashCompatible {
    param([string]$FilePath)

    return (Get-BRAVOFileHash -Path $FilePath -Algorithm SHA512).Hash.ToUpperInvariant()
}

function Verify-Backup {
    param(
        [string]$ArchivePath
    )
    
    Write-Log "Перевірка контрольних сум архіву: $([System.IO.Path]::GetFileName($ArchivePath))" -Level "INFO"
    
    if (-not (Test-Path $ArchivePath)) {
        $errorMsg = "Архів не знайдено: $ArchivePath"
        Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
        $script:criticalErrorOccurred = $true
        $script:restoreIntegrityFailed = $true
        return $false
    }

    $shaFile = "$ArchivePath.sha512"
    $fileName = [System.IO.Path]::GetFileName($ArchivePath)
    $valid = $true

    try {
        # Генерація контрольної суми
        $hash = Get-SHA512HashCompatible -FilePath $ArchivePath
        "$hash *$fileName" | Out-File -FilePath $shaFile -Encoding ASCII
        
        # Повний шлях до архіву без зайвого розширення
        Write-Log "Контрольна сума архіву збережена для -> $ArchivePath" -Level "SUCCESS"
    }
    catch {
        Write-Log "ПОМИЛКА: Помилка перевірки архіву $fileName - $($_.Exception.Message)" -Level "ERROR"
        $valid = $false
    }

    return $valid
}

# Функція перевірки розмірів .md файлів
function Check-MdFileSizes {
    param(
        $MODEL_PATH,
        $MAX_MD_FILE_SIZE,
        [string[]]$ExcludePatterns = @()
    )
    
    Write-Log "==="
    Write-Log "=== ПЕРЕВІРКА РОЗМІРІВ .MD ФАЙЛІВ ==="
    Write-Log "Перевірка розмірів файлів .md..." -Level "INFO"
    
    # [IO.DirectoryInfo]::EnumerateFiles замість Get-ChildItem -Recurse: на
    # непатчених білдах Windows Server 2016 (RTM, без Cumulative Update)
    # рекурсивний PowerShell-провайдер FileSystemProvider.Dir падає з
    # AccessViolationException у clr.dll на великих деревах каталогів.
    # Пряме звернення до .NET минає цей шар і дає ті самі об'єкти FileInfo.
    $modelDirectoryInfo = New-Object System.IO.DirectoryInfo($MODEL_PATH)
    $oversizedFiles = @(
        $modelDirectoryInfo.EnumerateFiles('*.md', [System.IO.SearchOption]::AllDirectories) |
        Where-Object {
            # EnumerateFiles, на відміну від Get-ChildItem без -Force, не
            # пропускає приховані й системні файли — фільтруємо їх самі,
            # щоб не змінити поведінку.
            ($_.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) -eq 0 -and
            $_.Length -gt $MAX_MD_FILE_SIZE
        }
    )
    $largeFiles = @()
    $excludedFiles = @()

    foreach ($file in $oversizedFiles) {
        $relativePath = $file.FullName.Replace($MODEL_PATH, "").TrimStart('\')
        $isExcluded = $false

        foreach ($pattern in $ExcludePatterns) {
            $normalizedPattern = $pattern.Replace('/', '\')
            if ($file.Name -like $normalizedPattern -or
                $relativePath -like $normalizedPattern -or
                $file.FullName -like $normalizedPattern) {
                $isExcluded = $true
                break
            }
        }

        if ($isExcluded) {
            $excludedFiles += $relativePath
        } else {
            $largeFiles += $file
        }
    }

    if ($excludedFiles.Count -gt 0) {
        $excludedList = ($excludedFiles | ForEach-Object { "- $_" }) -join "`n"
        Write-Log "Виключено з контролю розміру $($excludedFiles.Count) файлів .md згідно з конфігурацією:`n$excludedList" -Level "DEBUG"
    }

    if ($largeFiles.Count -gt 0) {
        # Формуємо список файлів через StringBuilder
        $fileListBuilder = New-Object System.Text.StringBuilder
        foreach ($file in $largeFiles) {
            $sizeFormatted = Format-FileSize $file.Length
            $relativePath = $file.FullName.Replace($MODEL_PATH, "").TrimStart('\')
            [void]$fileListBuilder.AppendLine("- $relativePath : $sizeFormatted")
        }
        $fileList = $fileListBuilder.ToString()

        $message = "Знайдено $($largeFiles.Count) файлів .md, розмір яких перевищує $($MAX_MD_FILE_SIZE / 1MB) МБ:`n$fileList"
        Write-Log $message -Level "WARNING"
        Send-SlackAlert -Message $message -IsCritical
    } elseif ($oversizedFiles.Count -gt 0) {
        Write-Log "Усі великі файли .md виключені з контролю розміру налаштуваннями конфігурації." -Level "DEBUG"
    } else {
        Write-Log "Файли .md з розміром більше $($MAX_MD_FILE_SIZE / 1MB) МБ не знайдено." -Level "INFO"
    }
}

# Функція обробки логів ExchangAPI
function Move-ExchangAPILogs {
    param(
        [string]$sourcePath,
        [string]$destDir
    )
    
    if (-not (Test-Path $sourcePath)) {
        Write-Log "Файл $([System.IO.Path]::GetFileName($sourcePath)) не знайдено" -Level "ERROR"
        return
    }
    
    New-Item -Path $destDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    
    $destPath = Join-Path -Path $destDir -ChildPath ([System.IO.Path]::GetFileName($sourcePath))
    
    for ($attempt = 1; $attempt -le $MoveRetryCount; $attempt++) {
        try {
            Move-Item -Path $sourcePath -Destination $destPath -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
                throw "файл призначення не створено"
            }
            Write-Log "Переміщено $([System.IO.Path]::GetFileName($sourcePath)) до $destDir" -Level "SUCCESS"
            return $true
        }
        catch {
            if ($attempt -lt $MoveRetryCount) {
                Write-Log "Лог $([System.IO.Path]::GetFileName($sourcePath)) зайнятий або недоступний; повторна спроба $($attempt + 1) з $MoveRetryCount через $MoveRetryDelaySeconds сек." -Level "WARNING"
                if ($MoveRetryDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $MoveRetryDelaySeconds
                }
            } else {
                Write-Log "Не вдалося перемістити $([System.IO.Path]::GetFileName($sourcePath)) після $MoveRetryCount спроб: $($_.Exception.Message)" -Level "ERROR"
                $script:criticalErrorOccurred = $true
                return $false
            }
        }
    }

    return $false
}

# Функція для відправки фінального звіту
function Send-FinalReport {
    param(
        $LOG_FILE
    )
    
    # Перевірка режиму "none" - повне вимкнення
    if ($script:SlackMode -eq "none") {
        return
    }
    
    $elapsedTime = (Get-Date) - $script:ScriptStartTime
    $notificationMessage = ""
    $shouldSend = $false
    
    if ($script:CriticalErrorsList.Count -gt 0) {
        # Є критичні помилки - відправляємо в режимах "errors_only" та "all"
        $notificationMessage = New-MaintenanceNotificationMessage `
            -Title "КРИТИЧНІ ПОМИЛКИ ОБСЛУГОВУВАННЯ" `
            -TitleEmoji ":rotating_light:" `
            -Duration $elapsedTime `
            -Details @($script:CriticalErrorsList.ToArray()) `
            -LogPath $LOG_FILE
        $shouldSend = $true
    } 
    else {
        # Немає критичних помилок - відправляємо тільки в режимі "all"
        if ($script:SlackMode -eq "all") {
            $completedCheckLines = [System.Collections.Generic.List[string]]::new()
            $completedCheckLines.Add(":mag: Виконані перевірки та операції:")
            $ukrainianCulture = [System.Globalization.CultureInfo]::GetCultureInfo("uk-UA")
            $nextRestoreDate = $scheduledOccurrence.Date.AddDays(7)
            $maintenanceStartTime = [TimeSpan]::Parse([string]$schedulerSettings.Maintenance.DailyAt)
            $nextRestoreExecution = $nextRestoreDate.Add($maintenanceStartTime)
            $restoreScheduleText = $nextRestoreExecution.ToString("dddd, dd.MM.yyyy HH:mm", $ukrainianCulture)
            $lastRestoreTime = $restoreCompletedAt
            if ($null -eq $lastRestoreTime) {
                $lastRestoreMarker = @(Get-BRAVOFiles -Path $LOG_DIR -Filter "restore_done_*.marker" |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1)
                if ($lastRestoreMarker.Count -gt 0) {
                    $lastRestoreTime = [datetime]$lastRestoreMarker[0].LastWriteTime
                }
            }
            $lastRestoreText = if ($null -ne $lastRestoreTime) {
                $lastRestoreTime.ToString("dd.MM.yyyy HH:mm:ss", $ukrainianCulture)
            } elseif (-not $BravoMaintenanceEnabled) {
                "немає даних (компонент BRAVO вимкнено)"
            } else {
                "ще не виконувалася"
            }
            $completedCheckLines.Add(":arrows_counterclockwise: Реставрація — наступна: $restoreScheduleText (після $RestoreTime) • остання: $lastRestoreText")

            $mdLimitGb = [math]::Round(([double]$MAX_MD_FILE_SIZE / 1GB), 2)
            $mdSelectionCriterion = "понад $mdLimitGb ГБ"
            if ($MD_FILE_SIZE_EXCLUSIONS.Count -gt 0) {
                $mdSelectionCriterion += "; виключень за конфігурацією: $($MD_FILE_SIZE_EXCLUSIONS.Count)"
            }
            $mdCheckStatus = if ($BravoMaintenanceEnabled -and $CheckSize) {
                "пройдено (критерій: $mdSelectionCriterion)"
            } elseif (-not $BravoMaintenanceEnabled) {
                "вимкнено разом із компонентом BRAVO"
            } else {
                "вимкнено параметром запуску"
            }
            $completedCheckLines.Add(":page_facing_up: Перевірка розміру файлів .md — $mdCheckStatus")

            $rangeCheckStatus = if ($BravoMaintenanceEnabled -and $RangeIdMonitoringEnabled) {
                "пройдено"
            } elseif (-not $RangeIdMonitoringEnabled) {
                "вимкнено в конфігурації"
            } else {
                "вимкнено разом із компонентом BRAVO"
            }
            $completedCheckLines.Add(":bar_chart: Перевірка значень інтервалів ID — $rangeCheckStatus")

            $traceOutputStatus = if (-not $BravoMaintenanceEnabled) {
                "вимкнено разом із компонентом BRAVO"
            } elseif ($traceOutputProcessed) {
                "виконано: $traceOutputProcessedCount файл(ів) → $TRACE_ARCHIV_DIR"
            } else {
                "нових TraceSRV.out/.out файлів не знайдено"
            }
            $completedCheckLines.Add(":card_file_box: Архівування та обнулення трейс-файлів — $traceOutputStatus")
            if ($exchangAPILogsProcessedCount -gt 0) {
                $completedCheckLines.Add(":arrows_counterclockwise: Обробка логів exchangAPI — переміщено $exchangAPILogsProcessedCount з $exchangAPILogsFoundCount файл(ів) → $EXCHANGAPI_ARCHIV_DIR")
            }
            $webLogOperationDetails = [System.Collections.Generic.List[string]]::new()
            if ($webApacheLogsProcessedCount -gt 0) {
                $webLogOperationDetails.Add("Apache: $webApacheLogsProcessedCount файл(ів)")
            }
            if ($webWwwLogsProcessedCount -gt 0) {
                $webLogOperationDetails.Add("WWW: $webWwwLogsProcessedCount файл(ів)")
            }
            if ($webLogOperationDetails.Count -gt 0) {
                $completedCheckLines.Add(":globe_with_meridians: Обробка логів BRAVO Web — $($webLogOperationDetails -join '; ') → $BRAVO_WEB_DAILY_DIR")
            }
            $freeSpaceDetails = if ($script:freeSpaceSummary -and $script:freeSpaceSummary.Count -gt 0) {
                "$($script:freeSpaceSummary -join '; ') (мінімум: $MIN_FREE_SPACE GB)"
            } else {
                "усі перевірені диски відповідають мінімуму $MIN_FREE_SPACE GB"
            }
            $completedCheckLines.Add(":floppy_disk: Контроль вільного місця на дисках — пройдено: $freeSpaceDetails")

            $notificationMessage = New-MaintenanceNotificationMessage `
                -Title "ОБСЛУГОВУВАННЯ ЗАВЕРШЕНО УСПІШНО" `
                -TitleEmoji ":white_check_mark:" `
                -Duration $elapsedTime `
                -StatusLines @(
                    ":wrench: Регламентні операції завершено"
                ) `
                -Details @($completedCheckLines.ToArray()) `
                -LogPath $LOG_FILE
            $shouldSend = $true
        } else {
            # Режим "errors_only" - не відправляємо успішні повідомлення, просто виходимо
            return
        }
    }
    
    # Якщо повідомлення не повинно відправлятися - виходимо
    if (-not $shouldSend) {
        return
    }
    
    # Показуємо заголовок тільки якщо відправка дійсно відбувається
    Write-Log -Message "==="
    Write-Log -Message "=== ВІДПРАВКА ПОВІДОМЛЕННЯ ПРО ПОДІЮ ==="
    Write-Log -Message "Відправка повідомлення в $NotificationProviderDisplayName" -Level "INFO"
    
    try {
        Invoke-NotificationWebhook -Message $notificationMessage
        Write-Log -Message "Фінальне повідомлення відправлено в $NotificationProviderDisplayName" -Level "SUCCESS"
    }
    catch {
        $errorDetails = $_.Exception.Message
        if ($_.ErrorDetails) {
            $errorDetails += " | Response: " + $_.ErrorDetails
        }
        Write-Log -Message "ПОМИЛКА відправки фінального повідомлення: $errorDetails" -Level "ERROR"
    }
    
    Write-Log -Message "==="
}

# ===== ОСНОВНИЙ КОД СКРИПТУ =====

# Перевірити права адміна. LocalSystem є допустимим контекстом для завдання
# Планувальника, навіть якщо роль Administrators не відобразилась через UAC API.
if (-not $isLocalSystem -and -not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ЗАПУСТІТЬ СКРИПТ ВІД ІМЕНІ АДМІНІСТРАТОРА!" -ForegroundColor Red
    exit 90
}

# Перевірка версії PowerShell. Для PowerShell 3.0 використовується сумісна
# реалізація SHA512 та доступні в цій версії системні командлети.
if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host "ПОМИЛКА: Необхідна версія PowerShell 3.0 або вище. Поточна версія: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    exit 90
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "УВАГА: PowerShell $($PSVersionTable.PSVersion) — увімкнено режим сумісності." -ForegroundColor Yellow
}

# Перевірка архітектури ОС
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Host "ПОМИЛКА: Скрипт працює тільки на 64-бітних системах" -ForegroundColor Red
    exit 90
}

# Перевірка версії ОС. Environment.OSVersion без application manifest може
# повертати 6.2 навіть у новіших Windows, тому значення не використовується
# для вимоги Windows 8.1 / Server 2012 R2.
$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Major -lt 6 -or ($osVersion.Major -eq 6 -and $osVersion.Minor -lt 1)) {
    Write-Host "ПОМИЛКА: Необхідна Windows 7/Windows Server 2008 R2 або новіша версія" -ForegroundColor Red
    exit 90
}
if ($osVersion.Major -eq 6 -and $osVersion.Minor -lt 3) {
    Write-Host "УВАГА: Windows версії $osVersion — увімкнено сумісний режим роботи." -ForegroundColor Yellow
}

# Автоматична перевірка наявності директорії BRAVO_WEB
$ApacheEnabled = $false
if ($BravoWebMaintenanceEnabled -and (Test-Path $BRAVO_WEB_DIR)) {
    $Apache = "$BRAVO_WEB_DIR\apache\bin\httpd.exe"
    
    # Перевірка наявності Apache та лог-директорій
    $ApacheExists = Test-Path $Apache
    $ApacheLogsExist = (Test-Path "$BRAVO_WEB_DIR\apache\logs") -and (Test-Path "$BRAVO_WEB_DIR\www\log")
    $ApacheEnabled = $ApacheExists -and $ApacheLogsExist
    if (-not $ApacheEnabled) {
        Write-Host "Apache не знайдено або відсутні лог-директорії - обробка логів вимкнена"
    }
}

# Робочі шляхи беруться зі спільної секції pathSettings у BRAVO.config,
# а не з імені каталогу скрипта. Раніше тут була жорстка вимога "каталог
# скрипта має називатись буквально ARCHIV" — той самий крихкий здогад,
# що вже прибрано з ArchiveRoot (pathSettings): він працював лише
# випадково, коли комплект справді розгорнутий у теці з таким іменем, і
# блокував Maintenance у будь-якому іншому розташуванні (наприклад,
# git-чекаут з іменем репозиторію) без жодної реальної причини —
# ArchiveRoot/LIMSRoot і так явно задані нижче.
$ROOT_LIMS = [Environment]::ExpandEnvironmentVariables([string]$pathSettings.LIMSRoot)
$ARCHIVE_ROOT = [Environment]::ExpandEnvironmentVariables([string]$pathSettings.ArchiveRoot)
if ([string]::IsNullOrWhiteSpace($ROOT_LIMS) -or
    [string]::IsNullOrWhiteSpace($ARCHIVE_ROOT)) {
    Write-Host "ПОМИЛКА: У BRAVO.config не налаштовано pathSettings.LIMSRoot або pathSettings.ArchiveRoot" -ForegroundColor Red
    exit 30
}
# Похідні шляхи
$MODEL_PATH = "$ROOT_LIMS\Model"
$LOG_DIR = Join-Path $ARCHIVE_ROOT "LOGS"
$TRACE_DIR = Join-Path $ARCHIVE_ROOT "Trace"
$ARC_DIR = if ($archiveDirs -and
    -not [string]::IsNullOrWhiteSpace([string]$archiveDirs.Model)) {
    [string]$archiveDirs.Model
} else {
    Join-Path $ARCHIVE_ROOT "MODEL"
}
$ARC_PATH = Join-Path $ARCHIVE_ROOT "Tools\7za.exe"
$EXCHANGAPI_ARCHIV_DIR = Join-Path $ARCHIVE_ROOT "exchangAPI"

if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    $BRAVO_WEB_ARCHIV_DIR = Join-Path $ARCHIVE_ROOT "Br-a-vo.web"
    $APACHE_LOGS_DIR = "$BRAVO_WEB_DIR\apache\logs"
    $WWW_LOGS_DIR = "$BRAVO_WEB_DIR\www\log"
}

# Переконатися, що директорія логів існує
if (-not (Test-Path $LOG_DIR)) {
    try {
        New-Item -Path $LOG_DIR -ItemType Directory -Force | Out-Null
        Write-Host "Створено директорію для логів: $LOG_DIR" -ForegroundColor Green
    }
    catch {
        Write-Host "Не вдалося створити директорію для логів $LOG_DIR : $($_.Exception.Message)" -ForegroundColor Red
        exit 90
    }
}

# Ініціалізація дати
$currentDate = Get-Date
$NOW = $currentDate.ToString("yyyyMMdd_HHmm")
$YYYY = $currentDate.Year.ToString("0000")
$MM = $currentDate.Month.ToString("00")
$DD = $currentDate.Day.ToString("00")

# Похідні параметри
$isRestoreDay = ($currentDate.DayOfWeek -eq $RestoreDayOfWeek)
$restoreTimeSpan = [TimeSpan]::Parse($RestoreTime)
$isAfterRestoreTime = ($currentDate.TimeOfDay -ge $restoreTimeSpan)

# Визначаємо MARKER_FILE до використання в shouldRestore
$MARKER_FILE = "$LOG_DIR\restore_done_$YYYY$MM$DD.marker"

$scheduledOccurrence = Get-BRAVORestoreScheduledOccurrence -Now $currentDate
$scheduledMarkerFile = Join-Path $LOG_DIR ('restore_done_{0}.marker' -f $scheduledOccurrence.ToString('yyyyMMdd'))
$restoreState = Read-BRAVORestoreState
$scheduledSucceeded = (Test-Path -LiteralPath $scheduledMarkerFile) -or (
    $null -ne $restoreState -and
    [string]$restoreState.Status -eq 'Succeeded' -and
    [string]$restoreState.ScheduledOccurrence -eq $scheduledOccurrence.ToString('o')
)
$missedRestore = -not $scheduledSucceeded
$taskExecutionState = Get-BRAVOTaskExecutionState
function Test-BRAVOTaskWasMissed {
    param([string]$TaskName, [string]$ScheduledTime)
    $expected = $currentDate.Date.Add([TimeSpan]::Parse($ScheduledTime))
    if ($expected -gt $currentDate) { $expected = $expected.AddDays(-1) }
    [datetime]$lastSuccess = [datetime]::MinValue
    $hasLastSuccess = $false
    if ($taskExecutionState.ContainsKey($TaskName)) {
        $hasLastSuccess = [datetime]::TryParse(
            [string]$taskExecutionState[$TaskName],
            [ref]$lastSuccess
        )
    }
    return (-not $hasLastSuccess -or $lastSuccess -lt $expected)
}
$missedMaintenanceTask = Test-BRAVOTaskWasMissed -TaskName 'Maintenance' -ScheduledTime ([string]$schedulerSettings.Maintenance.DailyAt)
$missedBackupTask = Test-BRAVOTaskWasMissed -TaskName 'Backup' -ScheduledTime ([string]$schedulerSettings.Backup.DailyAt)
$missedDailyWork = $missedMaintenanceTask -or $missedBackupTask
$shouldRestore = $BravoMaintenanceEnabled -and ($ForceRestore -or ($RunMissedRestoreOnly -and $missedRestore) -or ($isRestoreDay -and $isAfterRestoreTime -and -not (Test-Path $MARKER_FILE)))
$restoreReason = if ($ForceRestore) { "Примусово" } elseif ($RunMissedRestoreOnly) { "Пропущений плановий слот $($scheduledOccurrence.ToString('yyyy-MM-dd HH:mm'))" } else { "$RestoreDayName, після $RestoreTime" }
$CheckSize = -not $DisableSizeCheck
if ($RunMissedRestoreOnly -and $missedDailyWork) {
    # Recovery завжди завершується актуальним backup після maintenance.
    $script:EnableArchiveAfterMaintenance = $true
}

# Похідні файлові шляхи
$ARCH_NAME1 = "${ArchivePrefix}_before_$NOW.mdz"
$ARCH_NAME2 = "${ArchivePrefix}_after_$NOW.mdz"
$LOG_FILE = "$LOG_DIR\BRAVO_MAINTENANCE_$NOW.log"
$SIZES_FILE = "$LOG_DIR\file_sizes_before_$NOW.csv"
$TRACE_ARCHIV_DIR = "$TRACE_DIR\$YYYY-$MM-$DD"
$freeSpaceExclusionsText = if ($FREE_SPACE_EXCLUDED_DRIVES.Count -gt 0) {
    $FREE_SPACE_EXCLUDED_DRIVES -join ", "
} else {
    "немає"
}

# ===== СТВОРЕННЯ НЕОБХІДНИХ ДИРЕКТОРІЙ =====
# ===== ПОЧАТОК ВИКОНАННЯ =====
$maintenanceConfiguredStepWidth = if ($null -ne $consoleSettings.StepWidth) {
    [int]$consoleSettings.StepWidth
} else {
    58
}
Initialize-BRAVOConsole -StepWidth $maintenanceConfiguredStepWidth
Initialize-BRAVOProgress `
    -Activity 'BRAVO MAINTENANCE' `
    -Enabled ([bool]$progressSettings.Enabled)

# Вимкнений у конфігурації блок не показуємо й не рахуємо — етап існує лише
# для того, що справді виконуватиметься (так само, як в Archive і Health).
#
$script:BRAVOMaintenanceCheckSizeStepEnabled = $BravoMaintenanceEnabled -and $CheckSize
# Реставрація показується лише тоді, коли вона справді виконуватиметься
# цього запуску: $shouldRestore уже враховує -ForceRestore, пропущений слот
# і збіг дня/часу з маркером. У решту днів рядка немає взагалі.
#
# Якщо реставрація запланована, але службу BRAVO не вдалося зупинити, етап
# усе одно друкується — як SKIPPED. Це не «не настав час», а заплановане
# й невиконане: рівно те, про що оператор мусить дізнатися.
$script:BRAVOMaintenanceRestoreStepEnabled = $shouldRestore
$script:BRAVOMaintenanceLogsStepEnabled = $BravoMaintenanceEnabled
$script:BRAVOMaintenanceArchiveStepEnabled = [bool]$script:EnableArchiveAfterMaintenance
# Вільне місце, директорії, зупинка служб, відновлення служб і очистка
# виконуються завжди.
Initialize-BRAVOMaintenanceSteps -Total (
    5 +
    $(if ($script:BRAVOMaintenanceCheckSizeStepEnabled) { 1 } else { 0 }) +
    $(if ($script:BRAVOMaintenanceRestoreStepEnabled) { 1 } else { 0 }) +
    $(if ($script:BRAVOMaintenanceLogsStepEnabled) { 1 } else { 0 }) +
    $(if ($script:BRAVOMaintenanceArchiveStepEnabled) { 1 } else { 0 })
)
Write-BRAVOHeader `
    -Title ("BRAVO MAINTENANCE {0}" -f $global:ScriptVersion) `
    -Institution ([string]$script:ObjectName) `
    -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
    -StartedAt $script:ScriptStartTime

Write-Log -Message "==="
Write-Log -Message "=== СИСТЕМА ОБСЛУГОВУВАННЯ BRAVOSOFT ЗАПУЩЕНА ==="
Write-Log -Message "=== УСТАНОВА: $($script:ObjectName) ==="
Write-Log -Message "==="
Write-Log -Message "Коренева директорія: $ROOT_LIMS" -NoTimestamp
Write-Log -Message "Конфігурація: $ConfigPath" -NoTimestamp
Write-Log -Message "Сумісність: Windows $($BRAVOCompatibility.WindowsVersion); PowerShell $($BRAVOCompatibility.PowerShellVersion); WMI=$($BRAVOCompatibility.WmiProvider); Hash=$($BRAVOCompatibility.FileHashProvider); Files=$($BRAVOCompatibility.ChildItemProvider)" -NoTimestamp
if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
    Write-Log -Message $BRAVOPowerShellUpdate.Message -Level "WARNING"
}
if ($BRAVOWindowsPatchLevel.IsUpdateRecommended) {
    Write-Log -Message $BRAVOWindowsPatchLevel.Message -Level "WARNING"
}
$script:BRAVOOSSupportTier = Get-BRAVOOSSupportTier
Write-Log -Message "Підтримка ОС: $($script:BRAVOOSSupportTier.Tier) — Windows $($script:BRAVOOSSupportTier.OperatingSystem) ($($script:BRAVOOSSupportTier.OperatingSystemVersion), build $($script:BRAVOOSSupportTier.Build)); PowerShell $($script:BRAVOOSSupportTier.PowerShellVersion); .NET release $($script:BRAVOOSSupportTier.DotNetRelease)" -NoTimestamp
if ($script:BRAVOOSSupportTier.Tier -eq "LegacyBestEffort") {
    Write-Log -Message $script:BRAVOOSSupportTier.Message -Level "WARNING"
} elseif ($script:BRAVOOSSupportTier.Tier -eq "Unsupported") {
    if ($env:BRAVO_ALLOW_UNSUPPORTED_OS -eq "1") {
        Write-Log -Message "$($script:BRAVOOSSupportTier.Message) Продовжено через BRAVO_ALLOW_UNSUPPORTED_OS=1." -Level "WARNING"
    } else {
        Write-Log -Message $script:BRAVOOSSupportTier.Message -Level "ERROR"
        exit (Resolve-BRAVOExitCode -InvalidConfiguration)
    }
}
$script:BRAVOToolIntegrity = Get-BRAVOToolIntegrityRecommendation `
    -ToolPaths @($arcPath, $winSCPPath, $winSCPAssemblyPath) `
    -ManifestPath (Join-Path $toolsPath "TOOLS_INTEGRITY.json")
if ($script:BRAVOToolIntegrity.HasIntegrityIssue) {
    Write-Log -Message $script:BRAVOToolIntegrity.Message -Level "WARNING"
}

# Еталонний version-controlled маніфест: на відміну від TOFU-лінії вище,
# здатний заблокувати запуск. Maintenance викликає архіватор і WinSCP,
# тому підмінений інструмент так само отримав би права SYSTEM.
$script:BRAVOToolManifestMode = 'Enforce'
$script:BRAVOToolManifestPath = Join-Path $toolsPath "TOOLS_MANIFEST.json"
if ($toolIntegritySettings -is [System.Collections.IDictionary]) {
    if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.Mode)) {
        $script:BRAVOToolManifestMode = [string]$toolIntegritySettings.Mode
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.ManifestPath)) {
        $script:BRAVOToolManifestPath = [string]$toolIntegritySettings.ManifestPath
    }
}
if ($script:BRAVOToolManifestMode -ne 'Enforce') {
    Write-Log -Message (
        "УВАГА: перевірку цілісності інструментів послаблено в конфігурації " +
        "(toolIntegritySettings.Mode = $($script:BRAVOToolManifestMode)). Підміна 7za/WinSCP НЕ заблокує запуск."
    ) -Level "WARNING"
}
$script:BRAVOToolManifest = Test-BRAVOToolManifestIntegrity `
    -ToolsDirectory $toolsPath `
    -ManifestPath $script:BRAVOToolManifestPath `
    -Mode $script:BRAVOToolManifestMode
if (-not $script:BRAVOToolManifest.IsValid) {
    $manifestLevel = if ($script:BRAVOToolManifest.ShouldBlock) { "ERROR" } else { "WARNING" }
    Write-Log -Message $script:BRAVOToolManifest.Message -Level $manifestLevel
    if ($script:BRAVOToolManifest.ShouldBlock) {
        exit (Resolve-BRAVOExitCode -ToolIntegrityViolation)
    }
} elseif (-not [string]::IsNullOrWhiteSpace([string]$script:BRAVOToolManifest.Message)) {
    Write-Log -Message $script:BRAVOToolManifest.Message -Level "WARNING"
}
Write-Log -Message "Перевірка вільного місця: усі локальні диски; виключення: $freeSpaceExclusionsText" -NoTimestamp
if ($BravoMaintenanceEnabled -and $RangeIdMonitoringEnabled) {
    Write-Log -Message "Контроль діапазонів ID: понад $($RangeIdThresholdPercent)% у $RangeIdLogPath" -NoTimestamp
}
Write-Log -Message "Дата: $($currentDate.ToString('yyyy-MM-dd'))" -NoTimestamp
Write-Log -Message "Час: $($currentDate.ToString('HH:mm:ss'))" -NoTimestamp
if ($RunMissedRestoreOnly -and -not $missedDailyWork) {
    Write-Log -Message "Recovery: пропущених Backup/Maintenance не знайдено; завершення без дій" -Level 'INFO'
    exit 0
}
Write-Log -Message "Повідомлення: $NotificationProviderDisplayName; режим $(switch ($script:SlackMode) {'none' {'ВИМКНЕНО'} 'errors_only' {'ЛИШЕ ПОМИЛКИ'} 'all' {'УСІ ПОВІДОМЛЕННЯ'}})" -NoTimestamp

# Показуємо статус автоматичного вимкнення тільки якщо воно УВІМКНЕНО
if ($script:EnableAutoShutdown) {
    Write-Log -Message "Автоматичне вимкнення: УВІМКНЕНО" -NoTimestamp
}

# Відображаємо стан компонента й результат автоматичного визначення служби Apache.
if (-not $BravoWebComponentEnabled) {
    Write-Log -Message "Компонент BRAVO Web: ВИМКНЕНО в конфiгурацiї" -NoTimestamp
} elseif ($BravoWebServiceDisabledBySystem) {
    Write-Log -Message "Компонент BRAVO Web: ВИМКНЕНО (служба $BravoWebServiceName має тип запуску Disabled)" -NoTimestamp
} elseif ($ApacheServiceExists) {
    Write-Log -Message "Служба BRAVO Web: $BravoWebServiceDisplayName [$BravoWebServiceName]" -NoTimestamp
    if ($BravoWebServiceMatchCount -gt 1) {
        Write-Log -Message "Знайдено $BravoWebServiceMatchCount служб для одного httpd.exe; обрано службу [$BravoWebServiceName] зі станом $($ApacheService.Status)" -Level "WARNING"
    }
    Write-Log -Message "Обробка веб-логів: $(if ($ApacheEnabled) {'Увімкнена'} else {'Вимкнена'})" -NoTimestamp
} else {
    Write-Log -Message "Службу Apache для BRAVO Web не знайдено" -Level "WARNING"
}

if ($BravoMaintenanceEnabled) {
    if ($isRestoreDay -and $isAfterRestoreTime -and (Test-Path $MARKER_FILE)) {
        Write-Log -Message "РЕСТАВРАЦІЯ СЬОГОДНІ ВЖЕ ВИКОНУВАЛАСЬ (знайдено маркер $([System.IO.Path]::GetFileName($MARKER_FILE)))" -Level "INFO"
    }

    Write-Log -Message "Реставрація моделі: $(if ($shouldRestore) {"АКТИВОВАНА ($restoreReason)"} else {"ВИМКНЕНА"})" -NoTimestamp
    Write-Log -Message "Перевірка розмірів файлів: $(if ($CheckSize) {'УВІМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log -Message "Умови: заданий день=$isRestoreDay, після $RestoreTime=$isAfterRestoreTime" -NoTimestamp
}
Write-Log -Message "==="
Write-Log -Message "=== ПЕРЕВІРКА ВІЛЬНОГО МІСЦЯ ==="
Write-BRAVOProgressPhase -Phase 'Перевірка вільного місця' -PercentComplete 5
$spaceCheckResult = Check-FreeSpace -ROOT_LIMS $ROOT_LIMS -ExcludedDrives $FREE_SPACE_EXCLUDED_DRIVES

# Перевірка критичних помилок після перевірки місця
if (-not $spaceCheckResult) {
    Write-BRAVOMaintenanceStep -Name 'Перевірка вільного місця' -Status 'ERROR' -Details 'недостатньо місця'
    Write-Log -Message "Критична помилка перевірки місця. Завершення скрипта." -Level "ERROR"
    Complete-BRAVOProgress
    exit 60
}
Write-BRAVOMaintenanceStep -Name 'Перевірка вільного місця' -Status 'OK'

# ===== СТВОРЕННЯ НЕОБХІДНИХ ДИРЕКТОРІЙ =====
# Перевіряємо, чи потрібно створювати будь-які директорії
$dirsToCreate = @()
if ($BravoMaintenanceEnabled) {
    $dirsToCreate += $TRACE_DIR, $ARC_DIR, $TRACE_ARCHIV_DIR
}
if ($exchangAPIServiceEnabled) {
    $dirsToCreate += $EXCHANGAPI_ARCHIV_DIR
}
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    $BRAVO_WEB_DAILY_DIR = "$BRAVO_WEB_ARCHIV_DIR\$YYYY-$MM-$DD"
    $dirsToCreate += $BRAVO_WEB_ARCHIV_DIR, $BRAVO_WEB_DAILY_DIR
}

# Перевіряємо, які директорії потрібно створити.
# @() обовʼязкове: Where-Object повертає один обʼєкт, а не масив, коли збіг
# рівно один, і тоді .Count під Set-StrictMode кидає PropertyNotFoundStrict.
$missingDirs = @($dirsToCreate | Where-Object { -not (Test-Path $_) })

if ($missingDirs.Count -gt 0 -or $script:criticalErrorOccurred) {
    Write-Log -Message "==="
    Write-Log -Message "=== СТВОРЕННЯ НЕОБХІДНИХ ДИРЕКТОРІЙ ==="

    $createdDirs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($dir in $dirsToCreate) {
        if (-not (Test-Path $dir)) {
            try {
                New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Log -Message "Створено директорію: $dir" -Level "SUCCESS"
                $createdDirs.Add($dir)
            }
            catch {
                $errorMsg = "Не вдалося створити директорію $dir : $($_.Exception.Message)"
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
            }
        }
    }

    # Показуємо повідомлення тільки якщо були створені директорії
    if ($createdDirs.Count -gt 0) {
        Write-Log -Message "Створено $($createdDirs.Count) директорій" -Level "SUCCESS"
    }
    Write-BRAVOMaintenanceStep `
        -Name 'Створення необхідних директорій' `
        -Status $(if ($script:criticalErrorOccurred) { 'ERROR' } else { 'OK' }) `
        -Details $(if ($createdDirs.Count -gt 0) { "створено: $($createdDirs.Count)" } else { $null })
} else {
    Write-BRAVOMaintenanceStep `
        -Name 'Створення необхідних директорій' `
        -Status 'SKIPPED' `
        -Details 'усі вже існують'
}

Write-BRAVOProgressPhase -Phase 'Зупинка служб' -PercentComplete 20
$maintenanceLockResult = Enter-BRAVOMaintenanceOperationLock
if (-not $maintenanceLockResult.Success) {
    Write-Log -Message (
        "Maintenance відкладено: BRAVO_ARCHIV або інший maintenance уже працює; " +
        "lock=$($maintenanceLockResult.Path); $($maintenanceLockResult.Error)"
    ) -Level "ERROR"
    Complete-BRAVOProgress
    exit 20
}
$script:maintenanceOperationLock = $maintenanceLockResult.Stream
$script:maintenanceOperationLockPath = $maintenanceLockResult.Path
$traceOutputProcessed = $false
$traceOutputProcessedCount = 0
$exchangAPILogsFoundCount = 0
$exchangAPILogsProcessedCount = 0
$webApacheLogsProcessedCount = 0
$webWwwLogsProcessedCount = 0
$restoreCompletedAt = $null

try {
$serviceWasRunning = @{
    Bravo = $BravoMaintenanceEnabled -and
        (Get-Service -Name $BravoServiceName -ErrorAction SilentlyContinue).Status -eq 'Running'
    ExchangeApi = $exchangAPIServiceEnabled -and
        (Get-Service -Name $ExchangAPIServiceName -ErrorAction SilentlyContinue).Status -eq 'Running'
    BravoWeb = $BravoWebMaintenanceEnabled -and
        (Get-Service -Name $BravoWebServiceName -ErrorAction SilentlyContinue).Status -eq 'Running'
}
if ($RunMissedRestoreOnly -and $missedDailyWork) {
    $runningServices = @()
    if ($serviceWasRunning.Bravo) { $runningServices += $BravoServiceName }
    if ($serviceWasRunning.ExchangeApi) { $runningServices += $ExchangAPIServiceName }
    if ($serviceWasRunning.BravoWeb) { $runningServices += $BravoWebServiceName }
    if ($runningServices.Count -gt 0) {
        $message = "Пропущена реставрація не виконана: уже працюють служби $($runningServices -join ', '). Recovery не зупиняє служби."
        Write-Log -Message $message -Level 'WARNING'
        Write-BRAVORestoreState -ScheduledOccurrence $scheduledOccurrence -Status 'Pending' -Reason $message
        Send-SlackAlert -Message $message -IsCritical
        exit 20
    }
}
$inactiveServicesAtStart = @()
if ($BravoMaintenanceEnabled -and -not $serviceWasRunning.Bravo) {
    $bravoInitialService = Get-Service -Name $BravoServiceName -ErrorAction SilentlyContinue
    $inactiveServicesAtStart += "$BravoServiceName ($($bravoInitialService.Status))"
}
if ($exchangAPIServiceEnabled -and -not $serviceWasRunning.ExchangeApi) {
    $exchangeInitialService = Get-Service -Name $ExchangAPIServiceName -ErrorAction SilentlyContinue
    $inactiveServicesAtStart += "$ExchangAPIServiceName ($($exchangeInitialService.Status))"
}
if ($BravoWebMaintenanceEnabled -and -not $serviceWasRunning.BravoWeb) {
    $bravoWebInitialService = Get-Service -Name $BravoWebServiceName -ErrorAction SilentlyContinue
    $inactiveServicesAtStart += "$BravoWebServiceName ($($bravoWebInitialService.Status))"
}
Send-InactiveServiceWarning -ServiceDescriptions $inactiveServicesAtStart

# Усі операції зі зупиненими службами захищені finally. Навіть необроблена
# помилка повинна повернути до роботи лише ті служби, які працювали на початку.
try {
    # ===== ЗУПИНКА СЛУЖБ =====
    if ($serviceWasRunning.Bravo -or $serviceWasRunning.ExchangeApi -or $serviceWasRunning.BravoWeb) {
        Write-Log -Message "==="
        Write-Log -Message "=== ЗУПИНКА СЛУЖБ ==="
    }

$stopServicesRequired = $serviceWasRunning.Bravo -or
    $serviceWasRunning.ExchangeApi -or
    $serviceWasRunning.BravoWeb
$stopServicesCriticalBefore = $script:criticalErrorOccurred
$stopServicesWarningsBefore = $script:BRAVOWarningCount

# 1. Зупинка BRAVO Web
if ($BravoWebMaintenanceEnabled) {
    try {
        $ApacheService = Get-Service -Name $BravoWebServiceName -ErrorAction Stop
        if ($ApacheService.Status -ne 'Stopped') {
            Write-Log -Message "Зупинка служби BRAVO Web ($BravoWebServiceName)..." -Level "INFO"
            $serviceResult = Invoke-ServiceStateChange `
                -Name $BravoWebServiceName `
                -DesiredStatus Stopped `
                -TimeoutSeconds $ServiceStopTimeoutSeconds `
                -PollIntervalSeconds $ServicePollIntervalSeconds `
                -Force
            if ($serviceResult.Success) {
                Write-Log -Message "Службу BRAVO Web успішно зупинено" -Level "SUCCESS"
            } else {
                throw $serviceResult.Error
            }
        } else {
            Write-Log -Message "Служба BRAVO Web вже зупинена - операція не потрібна" -Level "INFO"
        }
    } catch {
        $errorMsg = "Помилка при зупинці служби BRAVO Web ($BravoWebServiceName): $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
    }
}

# 2. Зупинка exchangAPI. Керування дозволене лише через встановлену
# Windows-службу, тип запуску якої не Disabled.
if ($exchangAPIServiceEnabled) {
    $serviceStatus = $exchangAPIService.Status
    if ($serviceStatus -eq 'Running') {
        Write-Log -Message "Зупинка служби $ExchangAPIServiceName..." -Level "INFO"
        $serviceResult = Invoke-ServiceStateChange `
            -Name $ExchangAPIServiceName `
            -DesiredStatus Stopped `
            -TimeoutSeconds $ServiceStopTimeoutSeconds `
            -PollIntervalSeconds $ServicePollIntervalSeconds `
            -Force
        if ($serviceResult.Success) {
            Write-Log -Message "Служба $ExchangAPIServiceName успішно зупинена" -Level "SUCCESS"
        } else {
            $errorMsg = "Не вдалося зупинити службу ${ExchangAPIServiceName}: $($serviceResult.Error)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
        }
    } else {
        Write-Log -Message "Служба $ExchangAPIServiceName вже зупинена" -Level "INFO"
    }
} elseif ($exchangAPIServiceDisabled) {
    Write-Log -Message "Служба $ExchangAPIServiceName має тип запуску Disabled - керування пропущено" -Level "INFO"
} else {
    Write-Log -Message "Службу $ExchangAPIServiceName не встановлено - керування пропущено" -Level "INFO"
}

# 3. Зупинка служби BRAVO
if ($BravoMaintenanceEnabled) {
    try {
        $serviceStatus = (Get-Service -Name $BravoServiceName).Status
        
        if ($serviceStatus -eq 'Running') {
            Write-Log -Message "Зупинка служби $BravoServiceName..." -Level "INFO"
            
            # Завершення додаткових процесів
            $processNames = @("Bis")
            foreach ($procName in $processNames) {
                $process = Get-Process -Name $procName -ErrorAction SilentlyContinue
                if ($process) {
                    Write-Log -Message "Завершення процесу $procName..." -Level "INFO"
                    $process | Stop-Process -Force
                    Start-Sleep -Seconds 1
                }
            }
            
            $serviceResult = Invoke-ServiceStateChange `
                -Name $BravoServiceName `
                -DesiredStatus Stopped `
                -TimeoutSeconds $ServiceStopTimeoutSeconds `
                -PollIntervalSeconds $ServicePollIntervalSeconds `
                -Force
            if ($serviceResult.Success) {
                Write-Log -Message "Служба $BravoServiceName успішно зупинена" -Level "SUCCESS"
            } else {
                $errorMsg = "$BravoServiceName не зупинився автоматично: $($serviceResult.Error)"
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
            }
        }
        else {
            Write-Log -Message "Служба $BravoServiceName вже зупинена" -Level "INFO"
        }
    } catch {
        $errorMsg = "Помилка при зупинці ${BravoServiceName}: $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
    }
} elseif ($BravoServiceDisabledBySystem) {
    Write-Log -Message "Служба $BravoServiceName має тип запуску Disabled - компонент BRAVO пропущено" -Level "INFO"
} else {
    Write-Log -Message "Службу $BravoServiceName не встановлено - компонент BRAVO пропущено" -Level "INFO"
}

Write-BRAVOMaintenanceStep `
    -Name 'Зупинка служб' `
    -Status (Get-BRAVOMaintenanceStepStatus `
        -CriticalBefore $stopServicesCriticalBefore `
        -WarningsBefore $stopServicesWarningsBefore `
        -Skipped:(-not $stopServicesRequired))

# ===== ПЕРЕВІРКА РОЗМІРІВ ФАЙЛІВ .md =====
Write-BRAVOProgressPhase -Phase 'Перевірка розмірів .md' -PercentComplete 35
$checkSizeCriticalBefore = $script:criticalErrorOccurred
$checkSizeWarningsBefore = $script:BRAVOWarningCount
if ($script:BRAVOMaintenanceCheckSizeStepEnabled) {
    Check-MdFileSizes -MODEL_PATH $MODEL_PATH -MAX_MD_FILE_SIZE $MAX_MD_FILE_SIZE -ExcludePatterns $MD_FILE_SIZE_EXCLUSIONS
    Write-BRAVOMaintenanceStep `
        -Name 'Перевірка розмірів .md' `
        -Status (Get-BRAVOMaintenanceStepStatus `
            -CriticalBefore $checkSizeCriticalBefore `
            -WarningsBefore $checkSizeWarningsBefore)
}

# ===== ОПЕРАЦІЇ ПІСЛЯ ЗУПИНКИ СЕРВІСІВ =====
Write-BRAVOProgressPhase -Phase 'Реставрація моделі' -PercentComplete 45
$restoreCriticalBefore = $script:criticalErrorOccurred
$restoreWarningsBefore = $script:BRAVOWarningCount
$restoreStepReported = $false
$logsStepReported = $false
$bravoStatus = if ($BravoMaintenanceEnabled) { (Get-Service -Name $BravoServiceName).Status } else { 'Unavailable' }
if ($BravoMaintenanceEnabled -and $bravoStatus -ne "Running") {
    if ($shouldRestore) {
        try {
            Write-Log -Message "==="
            Write-Log -Message "=== РЕСТАВРАЦІЯ МОДЕЛІ ==="
            
            if ($CheckSize) {
                Write-Log -Message "Збереження розмірів файлів перед реставрацією..." -Level "INFO"
                # Той самий обхід провайдерного шару PowerShell, що й у
                # Check-MdFileSizes. EnumerateFiles не пропускає приховані й
                # системні файли, тому фільтруємо їх самі — Get-BRAVOFiles
                # без -Force теж їх виключав.
                $modelSizeDirectoryInfo = New-Object System.IO.DirectoryInfo($MODEL_PATH)
                $initialSizes = $modelSizeDirectoryInfo.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories) |
                    Where-Object {
                        ($_.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) -eq 0
                    } |
                    ForEach-Object {
                        [PSCustomObject]@{
                            RelativePath = $_.FullName.Replace($MODEL_PATH, "").TrimStart('\')
                            SizeBytes = $_.Length
                        }
                    }
                
                # Запис без BOM
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                $csvData = $initialSizes | ConvertTo-Csv -NoTypeInformation
                [System.IO.File]::WriteAllLines($SIZES_FILE, $csvData, $utf8NoBom)
                
                Write-Log -Message "Розміри файлів збережено: $SIZES_FILE" -Level "SUCCESS"
            }
            
            # Архівація перед реставрацією
            $beforeArchivePath = Join-Path $ARC_DIR $ARCH_NAME1
            $beforeHashPath = "$beforeArchivePath.sha512"
            if (Test-Path -LiteralPath $beforeHashPath -PathType Leaf) {
                Remove-Item -LiteralPath $beforeHashPath -Force -ErrorAction Stop
                Write-Log "Видалено попередній hash-файл перед повторним створенням архіву: $beforeHashPath" -Level "WARNING"
            }
            $arcArgs = $arcCommonParams + @($beforeArchivePath, "$MODEL_PATH\*")
            $exitCode = Invoke-CommandWithLog `
                -Command $ARC_PATH `
                -Arguments $arcArgs `
                -Description "Архівація моделі перед реставрацією" `
                -StandardInputText $script:ArchivePassword
            
            if ($exitCode -ne 0) {
                $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $exitCode
                $errorMsg = "Архівація моделі перед реставрацією не вдалася! Код 7-Zip: $exitCode — $exitDescription. Реставрація скасована."
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
                $script:restoreArchiveFailed = $true
            } elseif (-not (Test-BRAVOMaintenanceSevenZipArchiveIntegrity `
                    -SevenZipPath $ARC_PATH `
                    -ArchivePath $beforeArchivePath)) {
                $errorMsg = "Архів моделі перед реставрацією не пройшов перевірку 7-Zip. Реставрація скасована. Архів залишено для діагностики: $beforeArchivePath"
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
                $script:restoreIntegrityFailed = $true
            } elseif (-not (Verify-Backup -ArchivePath $beforeArchivePath)) {
                $errorMsg = "Не вдалося створити SHA512 для перевіреного архіву перед реставрацією. Реставрація скасована: $beforeArchivePath"
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
                $script:restoreIntegrityFailed = $true
            } else {
                Write-Log -Message "Архів моделі перед реставрацією створено та перевірено -> $beforeArchivePath" -Level "SUCCESS"
                
                # Виконання реставрації через bravocmd.exe (як в еталоні)
                $restoreArgs = @("r", "null", "$ROOT_LIMS\MODEL\lims")
                $exitCode = Invoke-CommandWithLog -Command "$ROOT_LIMS\bravocmd.exe" -Arguments $restoreArgs -Description "Виконання реставрації моделі LIMS"
                
                if ($exitCode -eq 0) {
                    $restoreCompletedAt = Get-Date
                    Write-Log -Message "Модель успішно відреставрована" -Level "SUCCESS"
                    
                    # Архівація після реставрації ВИКОНУЄТЬСЯ З УМОВАМИ
                    $restoreRequired = $false
                    $createMarker = $true
                    
                    if ($CheckSize) {
                        Write-Log -Message "Порівняння розмірів файлів..." -Level "INFO"
                        $criticalChanges = Compare-FileSizes -BeforeFile $SIZES_FILE -ModelPath $MODEL_PATH -MinSizeBytes 2048
                        
                        if ($criticalChanges) {
                            Write-Log -Message "УВАГА: Виявлено критичні зміни розмірів файлів!" -Level "WARNING"
                            Write-Log -Message "Відновлення моделі з архіву перед реставрацією..." -Level "INFO"
                            
                            # З моменту виявлення пошкодження будь-який результат
                            # відкату блокує after-архів і маркер успішної реставрації.
                            $restoreRequired = $true
                            $createMarker = $false
                            $exitCode = Restore-FromArchive -ArchivePath "$ARC_DIR\$ARCH_NAME1" -Destination $MODEL_PATH -ARC_PATH $ARC_PATH
                            if ($exitCode -eq 0) {
                                Write-Log -Message "Модель успішно відновлена з архіву перед реставрації" -Level "SUCCESS"
                            } else {
                                $errorMsg = "Відкат MODEL після критичних змін не виконано (код: $exitCode). Архівацію після реставрації та маркер успіху заблоковано."
                                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                                Send-SlackAlert -Message $errorMsg -IsCritical
                                $script:criticalErrorOccurred = $true
                                $script:restoreArchiveFailed = $true
                            }
                        }
                    }
                    
                    # Виконуємо архівацію після реставрації ЛИШЕ якщо не було критичних змін
                    if (-not $restoreRequired) {
                        $afterArchivePath = Join-Path $ARC_DIR $ARCH_NAME2
                        $afterHashPath = "$afterArchivePath.sha512"
                        if (Test-Path -LiteralPath $afterHashPath -PathType Leaf) {
                            Remove-Item -LiteralPath $afterHashPath -Force -ErrorAction Stop
                            Write-Log "Видалено попередній hash-файл перед повторним створенням архіву: $afterHashPath" -Level "WARNING"
                        }
                        $arcArgs = $arcCommonParams + @($afterArchivePath, "$MODEL_PATH\*")
                        $exitCode = Invoke-CommandWithLog `
                            -Command $ARC_PATH `
                            -Arguments $arcArgs `
                            -Description "Архівація моделі після реставрації" `
                            -StandardInputText $script:ArchivePassword
                        $afterArchiveReady = (
                            $exitCode -eq 0 -and
                            (Test-BRAVOMaintenanceSevenZipArchiveIntegrity `
                                -SevenZipPath $ARC_PATH `
                                -ArchivePath $afterArchivePath) -and
                            (Verify-Backup -ArchivePath $afterArchivePath)
                        )
                        if ($afterArchiveReady) {
                            Write-Log -Message "Архів моделі після реставрації створено та перевірено -> $afterArchivePath" -Level "SUCCESS"
                        } else {
                            $failureDetail = if ($exitCode -eq 0) {
                                "створення завершилося кодом 0, але перевірка 7z t або SHA512 не пройдена"
                            } else {
                                $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $exitCode
                                "код 7-Zip: $exitCode — $exitDescription"
                            }
                            $errorMsg = "Архів моделі після реставрації не готовий: $failureDetail. Маркер успішної реставрації не створено."
                            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                            Send-SlackAlert -Message $errorMsg -IsCritical
                            $script:criticalErrorOccurred = $true
                            $script:restoreArchiveFailed = $true
                        }
                        
                        # Створення маркера ЛИШЕ при успішній реставрації без критичних змін
                        if ($afterArchiveReady -and $createMarker -and -not $ForceRestore) {
                            $temporaryMarkerFile = "$MARKER_FILE.tmp"
                            $markerEncoding = New-Object System.Text.UTF8Encoding($false)
                            [System.IO.File]::WriteAllText(
                                $temporaryMarkerFile,
                                "Реставрація виконана $NOW`r`n",
                                $markerEncoding
                            )
                            Move-Item `
                                -LiteralPath $temporaryMarkerFile `
                                -Destination $MARKER_FILE `
                                -Force `
                                -ErrorAction Stop
                            Write-BRAVORestoreState -ScheduledOccurrence $scheduledOccurrence -Status 'Succeeded' -Reason $restoreReason
                            Write-Log -Message "Створено маркерний файл: $MARKER_FILE" -Level "SUCCESS"
                        }
                    } else {
                        Write-Log -Message "Архівація після реставрації ПРОПУЩЕНА через критичні зміни" -Level "WARNING"
                    }
                } else {
                    $errorMsg = "Реставрація моделі через bravocmd.exe не виконана. Код завершення: $exitCode. Архів до реставрації збережено: $ARC_DIR\$ARCH_NAME1"
                    Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                    Send-SlackAlert -Message $errorMsg -IsCritical
                    $script:criticalErrorOccurred = $true
                    $script:restoreArchiveFailed = $true
                }
            }
        }
        catch {
            $errorMsg = "Критична помилка під час реставрації: $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
            $script:restoreArchiveFailed = $true
        }
        Write-BRAVOMaintenanceStep `
            -Name 'Реставрація моделі' `
            -Status (Get-BRAVOMaintenanceStepStatus `
                -CriticalBefore $restoreCriticalBefore `
                -WarningsBefore $restoreWarningsBefore) `
            -Details $restoreReason
        $restoreStepReported = $true
    }

    # Обробка Trace належить лише до компонента основної служби BRAVO.
    Write-BRAVOProgressPhase -Phase 'Обробка trace і логів' -PercentComplete 60
    $logsCriticalBefore = $script:criticalErrorOccurred
    $logsWarningsBefore = $script:BRAVOWarningCount
    try {
        $outFiles = Get-ChildItem -Path "$ROOT_LIMS" -Filter "*.out" -ErrorAction SilentlyContinue
        if ($outFiles) {
            Write-Log -Message "==="
            Write-Log -Message "=== ОБРОБКА TRACE-ФАЙЛІВ ===" -Level "INFO"
            $movedTraceCount = 0
            foreach ($file in $outFiles) {
                if (Move-WithSequence -sourcePath $file.FullName -destDir $TRACE_ARCHIV_DIR -SkipIfEmpty) {
                    $movedTraceCount++
                }
            }
            if ($movedTraceCount -gt 0) {
                $traceOutputProcessed = $true
                $traceOutputProcessedCount = $movedTraceCount
                Write-Log -Message "Оброблено $movedTraceCount з $($outFiles.Count) trace-файлів" -Level "SUCCESS"
            }
            if ($movedTraceCount -lt $outFiles.Count) {
                Write-Log -Message "Не переміщено $($outFiles.Count - $movedTraceCount) з $($outFiles.Count) trace-файлів" -Level "WARNING"
            }
        }
    }
    catch {
        $errorMsg = "Помилка при обробці Trace-файлів: $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg
        $script:criticalErrorOccurred = $true
    }
}
elseif ($BravoMaintenanceEnabled) {
    $errorMsg = "Сервіс $($BravoServiceName) все ще працює. Операції з файлами пропущено."
    Write-Log -Message $errorMsg -Level "ERROR"
    Send-SlackAlert -Message $errorMsg
    $script:criticalErrorOccurred = $true
}

# Компонент exchangAPI обробляється незалежно, але лише за наявності
# встановленої та не відключеної служби.
if ($exchangAPIServiceEnabled) {
    try {
        $exchangAPILogs = Get-ChildItem -Path "$ROOT_LIMS" -Filter "exchangAPI_*.log" -ErrorAction SilentlyContinue
        if ($exchangAPILogs) {
            $exchangAPILogsFoundCount = @($exchangAPILogs).Count
            Write-Log "==="
            Write-Log -Message "=== ОБРОБКА ЛОГІВ EXCHANGAPI ===" -Level "INFO"
            foreach ($file in $exchangAPILogs) {
                if (Move-ExchangAPILogs -sourcePath $file.FullName -destDir $EXCHANGAPI_ARCHIV_DIR) {
                    $exchangAPILogsProcessedCount++
                }
            }
            if ($exchangAPILogsProcessedCount -gt 0) {
                Write-Log -Message "Оброблено $exchangAPILogsProcessedCount з $exchangAPILogsFoundCount лог-файлів exchangAPI" -Level "SUCCESS"
            }
            if ($exchangAPILogsProcessedCount -lt $exchangAPILogsFoundCount) {
                Write-Log -Message "Не переміщено $($exchangAPILogsFoundCount - $exchangAPILogsProcessedCount) з $exchangAPILogsFoundCount лог-файлів exchangAPI" -Level "WARNING"
            }
        }
    } catch {
        $errorMsg = "Помилка при обробці логів exchangAPI: $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg
        $script:criticalErrorOccurred = $true
    }
}

# Компонент BRAVO Web обробляється лише за наявності активної служби
# та необхідних каталогів.
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    try {
        $apacheLogFiles = @(Get-BRAVOFiles -Path $APACHE_LOGS_DIR |
            Where-Object { $_.Length -gt 0 })
        if ($apacheLogFiles) {
            Write-Log "==="
            Write-Log -Message "=== ОБРОБКА ЛОГІВ APACHE ===" -Level "INFO"
            foreach ($file in $apacheLogFiles) {
                if (Move-WithSequence -sourcePath $file.FullName -destDir $BRAVO_WEB_DAILY_DIR -SkipIfEmpty) {
                    $webApacheLogsProcessedCount++
                }
            }
            Write-Log -Message "Оброблено $webApacheLogsProcessedCount з $($apacheLogFiles.Count) Apache файлів" -Level "SUCCESS"
        }

        $wwwLogFiles = @(Get-BRAVOFiles -Path $WWW_LOGS_DIR |
            Where-Object { $_.Length -gt 0 })
        if ($wwwLogFiles) {
            Write-Log -Message "==="
            Write-Log -Message "=== ОБРОБКА ЛОГІВ WWW ===" -Level "INFO"
            foreach ($file in $wwwLogFiles) {
                if (Move-WithSequence -sourcePath $file.FullName -destDir $BRAVO_WEB_DAILY_DIR -SkipIfEmpty) {
                    $webWwwLogsProcessedCount++
                }
            }
            Write-Log -Message "Оброблено $webWwwLogsProcessedCount з $($wwwLogFiles.Count) WWW файлів" -Level "SUCCESS"
        }
    } catch {
        $errorMsg = "Помилка при обробці логів BRAVO Web: $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg
        $script:criticalErrorOccurred = $true
    }

    $processedLogCounts = $traceOutputProcessedCount +
        $exchangAPILogsProcessedCount +
        $webApacheLogsProcessedCount +
        $webWwwLogsProcessedCount
    Write-BRAVOMaintenanceStep `
        -Name 'Обробка trace і логів' `
        -Status (Get-BRAVOMaintenanceStepStatus `
            -CriticalBefore $logsCriticalBefore `
            -WarningsBefore $logsWarningsBefore) `
        -Details $(if ($processedLogCounts -gt 0) { "оброблено файлів: $processedLogCounts" } else { $null })
    $logsStepReported = $true
}

# Реставрація й обробка логів виконуються лише при зупиненій службі BRAVO.
# Кожен прапорець окремий: спільний давав би подвійний рядок «Обробка trace
# і логів» у найзвичайнішому випадку — служба зупинена, реставрація сьогодні
# не запланована.
#
# Сюди потрапляємо, лише якщо етап був порахований, але його гілка не
# відпрацювала — тобто службу BRAVO не вдалося зупинити. Це не «не настав
# час» (такий запуск взагалі не рахує реставрацію), а заплановане й
# невиконане, тому рядок обов'язковий.
if ($script:BRAVOMaintenanceRestoreStepEnabled -and -not $restoreStepReported) {
    Write-BRAVOMaintenanceStep `
        -Name 'Реставрація моделі' `
        -Status 'SKIPPED' `
        -Details 'службу BRAVO не було зупинено'
}
if ($script:BRAVOMaintenanceLogsStepEnabled -and -not $logsStepReported) {
    Write-BRAVOMaintenanceStep `
        -Name 'Обробка trace і логів' `
        -Status 'SKIPPED' `
        -Details 'службу BRAVO не було зупинено'
}

} finally {
Write-BRAVOProgressPhase -Phase 'Відновлення стану служб' -PercentComplete 75
$restoreServicesCriticalBefore = $script:criticalErrorOccurred
$restoreServicesWarningsBefore = $script:BRAVOWarningCount
Write-Log -Message "==="
Write-Log -Message "=== ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ ==="

# 1. Запуск служби BRAVO
try {
    if ($serviceWasRunning.Bravo -and (Get-Service -Name $BravoServiceName).Status -ne 'Running') {
        Write-Log -Message "Запуск служби $BravoServiceName..." -Level "INFO"
        $serviceResult = Invoke-ServiceStateChange `
            -Name $BravoServiceName `
            -DesiredStatus Running `
            -TimeoutSeconds $ServiceStartTimeoutSeconds `
            -PollIntervalSeconds $ServicePollIntervalSeconds
        if ($serviceResult.Success) {
            Write-Log -Message "Служба $BravoServiceName успішно запущена" -Level "SUCCESS"
        } else {
            $errorMsg = "$BravoServiceName не запустився автоматично: $($serviceResult.Error)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
        }
    }
} catch {
    $errorMsg = "Помилка при запуску ${BravoServiceName}: $($_.Exception.Message)"
    Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
    Send-SlackAlert -Message $errorMsg -IsCritical
    $script:criticalErrorOccurred = $true
}

# 2. Запуск exchangAPI лише через встановлену та не відключену Windows-службу
if ($serviceWasRunning.ExchangeApi) {
    try {
        $serviceStatus = (Get-Service -Name $ExchangAPIServiceName -ErrorAction Stop).Status
        if ($serviceStatus -ne 'Running') {
            Write-Log -Message "Запуск служби $ExchangAPIServiceName..." -Level "INFO"
            $serviceResult = Invoke-ServiceStateChange `
                -Name $ExchangAPIServiceName `
                -DesiredStatus Running `
                -TimeoutSeconds $ServiceStartTimeoutSeconds `
                -PollIntervalSeconds $ServicePollIntervalSeconds
            if ($serviceResult.Success) {
                Write-Log -Message "Служба $ExchangAPIServiceName успішно запущена" -Level "SUCCESS"
            } else {
                throw $serviceResult.Error
            }
        } else {
            Write-Log -Message "Служба $ExchangAPIServiceName вже запущена" -Level "INFO"
        }
    } catch {
        $errorMsg = "Помилка при запуску служби ${ExchangAPIServiceName}: $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
    }
}

# 3. Запуск BRAVO Web (виконується останнім)
if ($serviceWasRunning.BravoWeb) {
    try {
        $ApacheService = Get-Service -Name $BravoWebServiceName -ErrorAction Stop
        if ($ApacheService.Status -ne 'Running') {
            Write-Log -Message "Запуск служби BRAVO Web ($BravoWebServiceName)..." -Level "INFO"
            $serviceResult = Invoke-ServiceStateChange `
                -Name $BravoWebServiceName `
                -DesiredStatus Running `
                -TimeoutSeconds $ServiceStartTimeoutSeconds `
                -PollIntervalSeconds $ServicePollIntervalSeconds
            if ($serviceResult.Success) {
                Write-Log -Message "Службу BRAVO Web успішно запущено" -Level "SUCCESS"
            } else {
                throw $serviceResult.Error
            }
        } else {
            Write-Log -Message "Служба BRAVO Web вже запущена - операція не потрібна" -Level "INFO"
        }
    } catch {
        $errorMsg = "Помилка при запуску служби BRAVO Web ($BravoWebServiceName): $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
    }
}

Write-BRAVOMaintenanceStep `
    -Name 'Відновлення стану служб' `
    -Status (Get-BRAVOMaintenanceStepStatus `
        -CriticalBefore $restoreServicesCriticalBefore `
        -WarningsBefore $restoreServicesWarningsBefore)
}

if ($BravoMaintenanceEnabled -and $RangeIdMonitoringEnabled) {
    if ($RangeIdCheckDelaySeconds -gt 0) {
        Start-Sleep -Seconds $RangeIdCheckDelaySeconds
    }
    Test-RangeIdUsage -Path $RangeIdLogPath -ThresholdPercent $RangeIdThresholdPercent
}

# ===== ОЧИСТКА СТАРИХ ДАНИХ =====
Write-BRAVOProgressPhase -Phase 'Очистка старих даних' -PercentComplete 88
$cleanupCriticalBefore = $script:criticalErrorOccurred
$cleanupWarningsBefore = $script:BRAVOWarningCount

# Перевіряємо, чи є що очищати
$hasDataToClean = $false

# Перевірка даних основного компонента BRAVO
$traceOldDirs = @()
$traceOldLogs = @()
$groupsToDelete = @()
if ($BravoMaintenanceEnabled) {
    $traceOldDirs = @(Get-BRAVODirectories -Path $TRACE_DIR |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.CreationTime -lt (Get-Date).AddDays(-$ARCHIVE_RETENTION_DAYS) })
    $traceOldLogs = @(Get-BRAVOFiles -Path $LOG_DIR |
        Where-Object {
            $_.CreationTime -lt (Get-Date).AddDays(-$LOG_RETENTION_DAYS) -and
            ($_.Name -like "BRAVO_MAINTENANCE_*.log" -or
             $_.Name -like "script_log_*.txt" -or
             $_.Name -like "file_sizes_*.csv" -or
             $_.Name -like "restore_done_*.marker")
        })

    $mainArchivePatterns = @("${ArchivePrefix}_before_*.mdz", "${ArchivePrefix}_after_*.mdz")
    $mainArchiveFiles = @($mainArchivePatterns | ForEach-Object {
        Get-ChildItem -Path $ARC_DIR -Filter $_ -ErrorAction SilentlyContinue
    })

    if ($mainArchiveFiles.Count -gt 0) {
        $archiveGroups = $mainArchiveFiles | Group-Object {
            if ($_.Name -match "${ArchivePrefixRegex}_(before|after)_(\d{8}_\d{4})\.mdz") {
                $Matches[2]
            } else {
                $_.CreationTime.ToString("yyyyMMdd_HHmm")
            }
        }
        $sortedGroups = $archiveGroups | Sort-Object Name -Descending
        $groupsToDelete = @($sortedGroups | Select-Object -Skip $RESTORE_ARCHIVES_KEEP_COUNT)
        $hasDataToClean = $hasDataToClean -or ($groupsToDelete.Count -gt 0)
    }
}

# Перевірка логів exchangAPI лише для активного компонента
$exchangAPIOldLogs = @()
if ($exchangAPIServiceEnabled) {
    $exchangAPIOldLogs = @(Get-BRAVOFiles -Path $EXCHANGAPI_ARCHIV_DIR |
        Where-Object {
            $_.CreationTime -lt (Get-Date).AddDays(-$LOG_RETENTION_DAYS) -and
            $_.Name -like "exchangAPI_*.log"
        })
}

# Перевірка Br-a-vo.web (якщо Apache встановлений)
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    $bravoWebOldDirs = @(Get-BRAVODirectories -Path $BRAVO_WEB_ARCHIV_DIR |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.CreationTime -lt (Get-Date).AddDays(-$ARCHIVE_RETENTION_DAYS) })
    $hasDataToClean = $hasDataToClean -or ($bravoWebOldDirs.Count -gt 0)
}

# Загальна перевірка наявності даних для очищення
$hasDataToClean = $hasDataToClean -or ($traceOldDirs.Count -gt 0) -or ($traceOldLogs.Count -gt 0) -or ($exchangAPIOldLogs.Count -gt 0)

# Якщо є дані для очищення - показуємо заголовок
if ($hasDataToClean) {
    Write-Log -Message "==="
    Write-Log -Message "=== ОЧИСТКА СТАРИХ ДАНИХ ==="
}

# Обробка Trace (тільки якщо є що обробляти)
if ($BravoMaintenanceEnabled -and ($traceOldDirs.Count -gt 0 -or $traceOldLogs.Count -gt 0)) {
    Process-OldData -Path $TRACE_DIR -ArchiveNamePrefix "Trace" -RetentionDays $ARCHIVE_RETENTION_DAYS -arcCommonParams $arcCommonParams -ARC_PATH $ARC_PATH
}

# Обробка логів Br-a-vo.web (лише якщо служба Apache встановлена і є дані)
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled -and $bravoWebOldDirs.Count -gt 0) {
    Process-OldData -Path $BRAVO_WEB_ARCHIV_DIR -ArchiveNamePrefix "WebLogs" -RetentionDays $ARCHIVE_RETENTION_DAYS -arcCommonParams $arcCommonParams -ARC_PATH $ARC_PATH
}

# Очистка старих лог-файлів (всіх типів) - тільки якщо є що видаляти
if ($BravoMaintenanceEnabled -and $traceOldLogs.Count -gt 0) {
    Remove-OldLogFiles -Path $LOG_DIR -RetentionDays $LOG_RETENTION_DAYS
}

# Видалення старих архівів реставрації - тільки якщо є що видаляти
if ($BravoMaintenanceEnabled -and $groupsToDelete.Count -gt 0) {
    Remove-OldRestoreArchives `
        -Path $ARC_DIR `
        -ArchivePrefix $ArchivePrefix `
        -KeepCount $RESTORE_ARCHIVES_KEEP_COUNT `
        -InvalidRetentionDays $FAILED_ARCHIVE_RETENTION_DAYS
}

# Видалення старих логів exchangAPI - тільки якщо є що видаляти
if ($exchangAPIServiceEnabled -and $exchangAPIOldLogs.Count -gt 0) {
    Remove-OldLogFiles -Path $EXCHANGAPI_ARCHIV_DIR -RetentionDays $LOG_RETENTION_DAYS
}

Write-BRAVOMaintenanceStep `
    -Name 'Очистка старих даних' `
    -Status (Get-BRAVOMaintenanceStepStatus `
        -CriticalBefore $cleanupCriticalBefore `
        -WarningsBefore $cleanupWarningsBefore `
        -Skipped:(-not $hasDataToClean)) `
    -Details $(if (-not $hasDataToClean) { 'немає чого видаляти' } else { $null })

# ===== ЗАПУСК ДОДАТКОВОГО СКРИПТУ BRAVO_ARCHIV =====
Write-BRAVOProgressPhase -Phase 'Запуск BRAVO_ARCHIV' -PercentComplete 95
$archiveCriticalBefore = $script:criticalErrorOccurred
$archiveWarningsBefore = $script:BRAVOWarningCount
if ($script:EnableArchiveAfterMaintenance) {
    # Дочірній BRAVO_ARCHIV сам захоплює той самий lock. Перед передачею
    # керування звільняємо maintenance-lock; служби вже повернуті до
    # початкового стану блоком finally вище.
    Exit-BRAVOMaintenanceOperationLock
    Write-Log -Message "==="
    Write-Log -Message "=== ЗАПУСК СКРИПТУ BRAVO_ARCHIV ==="

    try {
        $bravoArchivePath = [string]$schedulerSettings.Backup.ScriptPath
        
        if (Test-Path -LiteralPath $bravoArchivePath -PathType Leaf) {
            Write-Log -Message "Запуск скрипту BRAVO_ARCHIV.ps1..." -Level "INFO"

            $archiveArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$bravoArchivePath`" -ConfigPath `"$ConfigPath`" -NoPause"
            $archivProcess = Start-Process -FilePath $schedulerSettings.PowerShellExecutable `
                -ArgumentList $archiveArguments `
                -Wait `
                -PassThru `
                -NoNewWindow
            
            if ($archivProcess.ExitCode -eq 0) {
                Write-Log -Message "Скрипт BRAVO_ARCHIV.ps1 успішно виконано" -Level "SUCCESS"
            } else {
                Write-Log -Message "Скрипт BRAVO_ARCHIV.ps1 завершено з кодом помилки: $($archivProcess.ExitCode)" -Level "ERROR"
                $script:criticalErrorOccurred = $true
            }
        } else {
            Write-Log -Message "Скрипт BRAVO_ARCHIV.ps1 не знайдено за шляхом: $bravoArchivePath" -Level "ERROR"
            $script:criticalErrorOccurred = $true
        }
    }
    catch {
        Write-Log -Message "Помилка під час запуску скрипту BRAVO_ARCHIV.ps1: $($_.Exception.Message)" -Level "ERROR"
        $script:criticalErrorOccurred = $true
    }
    Write-BRAVOMaintenanceStep `
        -Name 'Запуск BRAVO_ARCHIV' `
        -Status (Get-BRAVOMaintenanceStepStatus `
            -CriticalBefore $archiveCriticalBefore `
            -WarningsBefore $archiveWarningsBefore)
} else {
    # Лише у журнал: вимкнений компонент не займає рядка в консолі.
    Write-Log -Message "Запуск BRAVO_ARCHIV: вимкнено" -Level "DEBUG"
}

# ===== ВИКЛИК ФУНКЦІЇ АВТОМАТИЧНОГО ВИМКНЕННЯ =====
if ($script:EnableAutoShutdown) {
    Invoke-AutoShutdown -Timeout $ShutdownTimeout
} else {
    # Мінімальне інформаційне повідомлення без заголовків
    Write-Log -Message "Автоматичне вимкнення: вимкнено" -Level "DEBUG"
}

# Відправляємо фінальний звіт
Send-FinalReport -LOG_FILE $LOG_FILE

if (-not $script:criticalErrorOccurred) {
    Write-BRAVOTaskExecutionState -TaskName 'Maintenance'
}

# Додаємо інформацію про статус відправки Slack
# if ($script:SlackMode -ne "none") {
    # Видаліть перевірку $slackReportSent, оскільки тепер функція нічого не повертає
#     Write-Log -Message "Фінальний звіт оброблено" -Level "INFO"
# }

# ===== ЗАВЕРШЕННЯ СКРИПТУ =====
$totalTime = (Get-Date) - $script:ScriptStartTime

# ФІНАЛЬНИЙ БЛОК ЗАВЕРШЕННЯ
Write-Log -Message "==="
Write-Log -Message "=== СИСТЕМА ОБСЛУГОВУВАННЯ BRAVOSOFT ЗАВЕРШИЛА РОБОТУ ==="
Write-Log -Message "=== УСТАНОВА: $($script:ObjectName) ==="
Write-Log -Message "=== ЧАС ВИКОНАННЯ: $(Format-Duration $totalTime) ==="
Write-Log -Message "=== СТАТУС: $(if ($script:criticalErrorOccurred) {'З ПОМИЛКАМИ'} else {'УСПІШНО'}) ==="
Write-Log -Message "==="

Complete-BRAVOProgress
$maintenanceMetrics = New-Object System.Collections.Specialized.OrderedDictionary
$maintenanceMetrics.Add('Попереджень', $script:BRAVOWarningCount)
$maintenanceMetrics.Add('Установа', [string]$script:ObjectName)
# ЧАСТКОВО, а не ПОМИЛКА, за самих лише попереджень: обслуговування
# відпрацювало, але щось потребує уваги. ПОМИЛКА лишається за критичним
# збоєм — тим самим, що дає ненульовий код завершення.
$maintenanceSummaryResult = if ($script:criticalErrorOccurred) {
    'ПОМИЛКА'
} elseif ($script:BRAVOWarningCount -gt 0) {
    'ЧАСТКОВО'
} else {
    'УСПІШНО'
}
Write-BRAVOSummary `
    -Result $maintenanceSummaryResult `
    -Duration $totalTime `
    -Metrics $maintenanceMetrics `
    -LogFile $LOG_FILE
} finally {
    Exit-BRAVOMaintenanceOperationLock
}

# Операції створення/відновлення локального архіву й перевірки його
# цілісності виділені окремими прапорцями (restoreArchiveFailed/
# restoreIntegrityFailed, 19 точок) на 40/41; решта ~23 точок
# criticalErrorOccurred (сервіси, диск, файлове господарство, оркестрація
# BRAVO_ARCHIV) і далі схлопуються в загальний бакет 60. Resolve-BRAVOExitCode
# сам віддає пріоритет 40/41 над 60, якщо передані одночасно.
if ($script:criticalErrorOccurred) {
    exit (Resolve-BRAVOExitCode `
        -LocalArchiveFailed:$script:restoreArchiveFailed `
        -IntegrityTestFailed:$script:restoreIntegrityFailed `
        -MaintenanceFailed)
} elseif ($script:BRAVOWarningCount -gt 0) {
    exit (Resolve-BRAVOExitCode -HasWarnings)
} else {
    exit 0
}

} finally {
    # Закриває try, відкритий одразу після імпорту модулів. exit усередині
    # try проходить крізь finally перед тим, як процес справді завершиться
    # (перевірено емпірично) — тому це охоплює геть усі ~28 точок exit
    # вище, включно з рідко відвідуваними (config не знайдено, lock
    # зайнятий, tool integrity) — саме там, де оператору найпотрібніше
    # встигнути прочитати повідомлення до закриття вікна.
    Wait-BRAVOManualExit -NoPause:$NoPause
}
