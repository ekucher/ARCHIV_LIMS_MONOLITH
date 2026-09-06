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
    [bool]$ConfigPathWasExplicit = $false,
    [switch]$NoPause,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$EntryScriptPath
)

$bravoScriptDirectory = $RuntimeRoot

# Спільні PowerShell-модулі runtime.
# BRAVO.Discovery тут явно, а не "його ж імпортує BRAVO_CONFIG_LOADER.ps1":
# ротація Trace й exchangAPI читає з нього Get-BRAVOServiceExecutablePath і
# ConvertTo-BRAVOIniPathValue, а покладатися на порядок чужих імпортів для
# власних залежностей — рівно та помилка, яку вже задокументовано в шапці
# самого BRAVO.Discovery.
# BRAVO.BazaSync — рівно заради канонічного рекурсивного creator'а
# remote-каталогів (New-BRAVOBazaRemoteDirectoryRecursive), який потрібен
# добовій Trace-передачі. Функція duck-typed по $Session і не пов'язана з
# BAZA-станом; сам імпорт побічних ефектів не має (тягне лише
# BRAVO.Compatibility і BRAVO.ArchiveRuntime, вже імпортовані тут).
# Архітектурний борг: префікс Baza в Trace-контексті — свідомий компроміс
# проти другої власної реалізації; нейтральний власник SFTP-примітивів —
# тема окремого рефактора.
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveHelpers', 'BRAVO.ArchiveRuntime', 'BRAVO.Logging', 'BRAVO.Console', 'BRAVO.ExitCodes', 'BRAVO.Discovery', 'BRAVO.System', 'BRAVO.BazaSync', 'BRAVO.Status')) {
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
# Свіжість накопичувальних оновлень Windows тут навмисно НЕ перевіряється:
# це health-метрика, а не умова виконання обслуговування. Її місце в
# BRAVO_HEALTH, який для цього й існує. Тут вона лише додавала WARNING (а
# отже, ненульовий код завершення 10) до операції, на результат якої вік
# патчів не впливає. Перевірки платформи (ОС, build, PowerShell, .NET,
# архітектура, API) лишаються вище й на місці.
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

# P0 Configuration Foundation: справжня межа виклику оператора — root
# entrypoint, і лише ВІН знає, чи -ConfigPath був реально переданий: сюди
# ConfigPath завжди приходить уже резолвленим і непорожнім, тому
# $PSBoundParameters тут відновити намір не може (acceptance-клас дефектів
# CF-17/AUTO-intent). Намір приймається явним -ConfigPathWasExplicit;
# додаткова перевірка порожнього шляху страхує від помилкового виклику з
# прапорцем без шляху (та сама семантика, що в Import-BravoConfiguration).
$configPathWasExplicit = $ConfigPathWasExplicit -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)
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
    # AUTO -> не вбудовувати -ConfigPath: elevated-процес сам повторить ту
    # саму auto-derivation проти свого RuntimeRoot. EXPLICIT -> зберегти
    # точний шлях (свідомий намір оператора не губиться при елевації).
    if ($configPathWasExplicit) {
        $elevatedArguments += @("-ConfigPath", "`"$ConfigPath`"")
    }
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

# P2-6 (PR #136 review): чи ОРГАНІЧНО дійшло виконання до точки, де раніше
# викликався Invoke-AutoShutdown (тобто жодна попередня операція в try не
# кинула необроблений виняток) — фактичний виклик shutdown.exe тепер
# відкладений до кінця скрипта (після best-effort вивантаження власних
# логів), а цей прапорець відтворює ТУ САМУ семантику "виняток раніше ->
# автовимкнення взагалі не намагається виконатись", яка діяла до
# рефактору. Ініціалізовано тут (а не лише в місці встановлення) з тієї ж
# причини, що lock-змінні вище: читається під Set-StrictMode навіть на
# шляхах дуже раннього виходу, де точка встановлення нижче не досягається.
$script:autoShutdownReachable = $false

# ===== ЗАВАНТАЖЕННЯ НАЛАШТУВАНЬ =====
# P0 Configuration Foundation: BRAVO.config став опційним основним
# override-шаром — попередня жорстка "файл мусить існувати" перевірка тут
# дублювала (і випереджала) те саме рішення, яке Import-BravoConfiguration
# приймає коректно сама: auto-derived відсутній BRAVO.config -> canonical
# built-in defaults + BRAVO.local.config; явно вказаний відсутній
# -ConfigPath -> як і раніше, помилка конфігурації (exit 30 через catch
# нижче). GetFullPath замість Resolve-Path — нормалізація шляху без вимоги
# існування файлу (той самий канон, що Archive/Health/DataRestore).
try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $configRoot = Split-Path -Path $ConfigPath -Parent
    # Завантажувач і modules\ беруться з КОМПЛЕКТУ, а не з каталогу
    # конфігурації: -ConfigPath може вказувати на C:\BRAVO\CONFIGS\SERVER1.config,
    # де немає ні BRAVO_CONFIG_LOADER.ps1, ні modules\.
    $configurationLoaderPath = Join-Path $bravoScriptDirectory 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $ConfigPath `
        -RuntimeRoot $bravoScriptDirectory `
        -ConfigPathWasExplicit:$configPathWasExplicit
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
        [string]::IsNullOrWhiteSpace([string]$effectiveLimsRoot) -or
        [string]::IsNullOrWhiteSpace([string]$systemLogRoot) -or
        [string]::IsNullOrWhiteSpace([string]$backupRootPath)) {
        throw "У BRAVO.config не вдалося визначити ефективні корені (EffectiveLIMSRoot/SystemLogRoot/BackupRoot)"
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
# Безпечне вікно АВТОМАТИЧНОЇ реставрації. Операція зупиняє служби BRAVO і
# монопольно тримає модель, тому випадковий запуск у робочий час
# неприпустимий. Вікно може перетинати північ (типово 21:00 -> 03:00).
# Конфігурації без цих ключів отримують типове вікно, а не цілодобовий
# дозвіл: відсутність явного обмеження не має означати "будь-коли".
# -ForceRestore вікном НЕ обмежується — це свідома дія оператора.
$RestoreWindowStart = if ($MaintenanceConfig.Restore -is [System.Collections.IDictionary] -and
    -not [string]::IsNullOrWhiteSpace([string]$MaintenanceConfig.Restore.WindowStart)) {
    [string]$MaintenanceConfig.Restore.WindowStart
} else {
    "21:00"
}
$RestoreWindowEnd = if ($MaintenanceConfig.Restore -is [System.Collections.IDictionary] -and
    -not [string]::IsNullOrWhiteSpace([string]$MaintenanceConfig.Restore.WindowEnd)) {
    [string]$MaintenanceConfig.Restore.WindowEnd
} else {
    "03:00"
}
$RESTORE_ARCHIVES_KEEP_COUNT = [int]$MaintenanceConfig.Restore.ArchivesKeepCount
$ARCHIVE_RETENTION_DAYS = [int]$MaintenanceConfig.Retention.ArchiveDays
$LOG_RETENTION_DAYS = [int]$MaintenanceConfig.Retention.LogDays
# Скільки днів зберігати вже стиснуті .mdz програмних журналів. Окрема
# політика від ArchiveDays: та відповідає за момент пакування каталогу-дати,
# ця — за момент видалення архіву. Старі конфігурації без ключа зберігають
# архіви за тим самим строком, що й службові журнали Maintenance.
$COMPRESSED_LOG_RETENTION_DAYS = if ($MaintenanceConfig.Retention -is [System.Collections.IDictionary] -and
    $MaintenanceConfig.Retention.Contains("CompressedLogDays") -and
    $null -ne $MaintenanceConfig.Retention.CompressedLogDays) {
    [math]::Max(1, [int]$MaintenanceConfig.Retention.CompressedLogDays)
} else {
    $LOG_RETENTION_DAYS
}
# 5.2.0: явний вимикач автоматичного видалення стиснутих .mdz за віком
# (включно з добовими Trace_YYYYMMDD.mdz). Типово $false — жоден .mdz не
# видаляється, доки оператор свідомо не ввімкне політику; CompressedLogDays
# діє лише разом із прапорцем. Дефолт для старих site-config гарантує
# конфіг-лоадер, тут — захисне читання тим самим Contains-патерном.
$COMPRESSED_LOG_DELETION_ENABLED = if ($MaintenanceConfig.Retention -is [System.Collections.IDictionary] -and
    $MaintenanceConfig.Retention.Contains("CompressedLogDeletionEnabled")) {
    [bool]$MaintenanceConfig.Retention.CompressedLogDeletionEnabled
} else {
    $false
}
$FAILED_ARCHIVE_RETENTION_DAYS = if ($null -ne $MaintenanceConfig.Retention.FailedArchiveDays) {
    [math]::Max(1, [int]$MaintenanceConfig.Retention.FailedArchiveDays)
} else {
    30
}
# P5 (2026-09): скільки днів понад LastWriteTime лишати локально ПОВНІСТЮ
# верифіковане джерело (.out/.log) після успішної архівації+SFTP, перш
# ніж видалити. 0 = точна попередня поведінка (видалення одразу, щойно
# безпечно). Той самий захисний Contains-патерн, що CompressedLogDays/
# CompressedLogDeletionEnabled вище — старі site-config без ключа
# зберігають поточну (негайну) поведінку без винятків.
$RAW_SOURCE_GRACE_DAYS = if ($MaintenanceConfig.Retention -is [System.Collections.IDictionary] -and
    $MaintenanceConfig.Retention.Contains("RawSourceGraceDays") -and
    $null -ne $MaintenanceConfig.Retention.RawSourceGraceDays) {
    [math]::Max(0, [int]$MaintenanceConfig.Retention.RawSourceGraceDays)
} else {
    0
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

# -EnableAllSlack/-DisableAllSlack обчислюється ТУТ, одразу після
# сирого конфігураційного значення, а не лише пізніше перед основною
# роботою: нижчий preflight (резолв route->webhook URL і валідація, що
# кожен REACHABLE маршрут дійсно налаштований) мусить бачити ЕФЕКТИВНИЙ
# режим. Раніше preflight резолвив/валідував лише той набір маршрутів,
# що досяжний за СИРИМ $SlackMode, а рантайм-споживачі (Send-SlackAlert,
# Send-InactiveServiceWarning, Send-FinalReport) вже читали
# $script:SlackMode ПІСЛЯ override — при NotificationMode=none/
# errors_only + -EnableAllSlack це лишало $script:NotificationWebhookUrls
# недорезолвленим для нового ефективного маршруту: кожен наступний send
# мовчки провалювався на відсутньому URL (Mandatory-параметр отримував
# $null), а сам прапорець ставав no-op. Єдине джерело істини для
# ЕФЕКТИВНОГО режиму — тут; банер-повідомлення нижче (де раніше й
# відбувалось саме це присвоєння) лише друкує вже обчислене значення.
$script:SlackMode = if ($DisableAllSlack) {
    "none"
} elseif ($EnableAllSlack) {
    "all"
} else {
    $SlackMode
}

$NotificationRequestTimeoutSeconds = if ($null -ne $bravoSettings.NotificationRequestTimeoutSeconds) {
    [math]::Max(1, [int]$bravoSettings.NotificationRequestTimeoutSeconds)
} else {
    30
}
$NotificationProviderDisplayName = if ($NotificationProvider -eq "discord") { "Discord" } else { "Slack" }

# Банер режиму повідомлень. Саме присвоєння $script:SlackMode уже
# зроблено вище (одразу після обчислення сирого $SlackMode) — preflight-
# резолв webhook-URL і його валідація мають бачити ефективний режим до
# цього моменту, тому логіка -DisableAllSlack/-EnableAllSlack там не
# дублюється, лише перевіряється тут для друку того самого банера.
if ($DisableAllSlack) {
    Write-Host "Повідомлення: ВИМКНЕНО (none)" -ForegroundColor Yellow
} elseif ($EnableAllSlack) {
    Write-Host "Повідомлення через ${NotificationProviderDisplayName}: УСІ ПОВІДОМЛЕННЯ (all)" -ForegroundColor Green
}

# Маршрутизація (GENERAL/ALERTS) і резолв webhook — виключно через
# централізований API BRAVO.Notifications; Maintenance сам канал не
# обирає. Гейт — ЕФЕКТИВНИЙ $script:SlackMode (уже враховує
# -DisableAllSlack/-EnableAllSlack, обчислений вище): резолвити routes
# за сирим $SlackMode тут було б помилкою — рантайм-споживачі нижче
# читають саме $script:SlackMode.
$script:NotificationWebhookUrls = @{}
$NotificationCredentialError = $null
if ($script:SlackMode -ne "none") {
    try {
        if ($null -eq $credentialSettings -or
            $null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
            throw "вбудований Credential Manager недоступний"
        }
        $reachableNotificationRoutes = @("alerts")
        if ($script:SlackMode -eq "all") {
            $reachableNotificationRoutes += "general"
        }
        foreach ($reachableRoute in $reachableNotificationRoutes) {
            try {
                $script:NotificationWebhookUrls[$reachableRoute] = Resolve-BRAVONotificationEndpoint `
                    -Provider $NotificationProvider `
                    -Route $reachableRoute `
                    -CredentialTargets $credentialSettings.Targets
            } catch {
                if (-not $NotificationCredentialError) {
                    $NotificationCredentialError = Protect-BRAVOLogSecret -Text $_.Exception.Message
                }
            }
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
$RangeIdLogPath = if ($RangeIdMonitoringEnabled) {
    Get-BRAVOSystemRangeIdLogPath
} else {
    $null
}
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
# Параметри 7-Zip для накопичувального добового Trace-архіву (модель
# 5.2.0): базові Archiver.Parameters (включно з успадкованим bare -p) без
#   'a'    — команда додається явно першою;
#   '-r'   — рекурсія небезпечна для точкових додавань (7-Zip трактує
#            імена як патерни і підтягнув би однойменні файли з підкаталогів);
#   '-aoa' — overwrite-режим суперечить immutable-контракту entries;
#   '-mhe' — шифрований заголовок вимагає ДРУГОГО вводу пароля при
#            додаванні в існуючий архів, і 7-Zip читає його не з
#            redirected stdin надійно (див. Update-BRAVOTraceDailyArchive).
$traceArchiveAddParams = @('a') + @($arcCommonParams | Where-Object {
    $_ -ne 'a' -and $_ -ne '-r' -and $_ -ne '-aoa' -and $_ -notmatch '^(?i)-mhe'
})
# Модель logs/: нові добові архіви йдуть у logs/trace та logs/exchangapi;
# legacy-каталог trace лишається лише джерелом одноразової автоміграції.
$traceSftpRemoteDirectory = [string]$sftpDirectories.TraceLogs
$traceLegacySftpRemoteDirectory = [string]$sftpDirectories.Trace
$exchangeApiSftpRemoteDirectory = [string]$sftpDirectories.ExchangeApiLogs
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

# Вікно може перетинати північ, тому це не звичайне порівняння діапазону:
# для 21:00->03:00 дозволені і 23:30, і 01:15, але не 12:00. Рівні межі
# трактуються як цілодобове вікно (обмеження фактично вимкнене).
function Test-BRAVORestoreTimeWindow {
    param(
        [Parameter(Mandatory = $true)][datetime]$Now,
        [Parameter(Mandatory = $true)][TimeSpan]$WindowStart,
        [Parameter(Mandatory = $true)][TimeSpan]$WindowEnd
    )

    if ($WindowStart -eq $WindowEnd) { return $true }
    $nowSpan = $Now.TimeOfDay
    if ($WindowStart -lt $WindowEnd) {
        return ($nowSpan -ge $WindowStart -and $nowSpan -lt $WindowEnd)
    }
    return ($nowSpan -ge $WindowStart -or $nowSpan -lt $WindowEnd)
}

# TOCTOU-бар'єр: $shouldRestore/$restoreWindowOpen обчислюються один раз, до
# Enter-BRAVOMaintenanceOperationLock (очікування до OperationLockWaitMinutes,
# типово 360 хв), зупинки служб і архівації моделі перед реставрацією. За цей
# час вікно могло закритися — стара перевірка НЕ є остаточним дозволом на
# деструктивний bravocmd.exe. Тому це окрема, injectable-за-часом функція:
# викликається ЗАНОВО безпосередньо перед входом у restore sequence і ще раз
# безпосередньо перед самим bravocmd.exe (два незалежних бар'єри, той самий
# критерій). -ForceRestore жодним із них не обмежується — свідома дія
# оператора. $NowProvider — єдина точка ін'єкції часу для self-test (не
# підміняє глобальний Get-Date).
function Test-BRAVORestoreExecutionStillAllowed {
    param(
        [Parameter(Mandatory = $true)][TimeSpan]$WindowStart,
        [Parameter(Mandatory = $true)][TimeSpan]$WindowEnd,
        [bool]$ForceRestore,
        [scriptblock]$NowProvider = { Get-Date }
    )
    if ($ForceRestore) { return $true }
    $now = & $NowProvider
    return Test-BRAVORestoreTimeWindow -Now $now -WindowStart $WindowStart -WindowEnd $WindowEnd
}

$parsedRestoreTime = [TimeSpan]::Zero
$parsedRestoreWindowStart = [TimeSpan]::Zero
$parsedRestoreWindowEnd = [TimeSpan]::Zero
if ([string]::IsNullOrWhiteSpace($script:ObjectName) -or
    [string]::IsNullOrWhiteSpace($ArchivePrefix) -or
    [string]::IsNullOrWhiteSpace($BravoServiceName) -or
    ($BravoWebComponentEnabled -and [string]::IsNullOrWhiteSpace($BRAVO_WEB_DIR)) -or
    ($BravoWebComponentEnabled -and $BravoWebServiceCandidates.Count -eq 0) -or
    $RestoreDay -notin 1..7 -or
    -not [TimeSpan]::TryParse($RestoreTime, [ref]$parsedRestoreTime) -or
    -not [TimeSpan]::TryParse($RestoreWindowStart, [ref]$parsedRestoreWindowStart) -or
    -not [TimeSpan]::TryParse($RestoreWindowEnd, [ref]$parsedRestoreWindowEnd) -or
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
    Write-Host "ПОМИЛКА: Не вдалося визначити системний шлях до файлу контролю діапазонів ID" -ForegroundColor Red
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

if ($script:SlackMode -ne "none") {
    # Перевіряються ті routes, що реально досяжні за ЕФЕКТИВНОГО
    # $script:SlackMode (уже враховує -DisableAllSlack/-EnableAllSlack) —
    # інакше ця перевірка мовчки пропускала б відсутній webhook саме
    # тоді, коли оператор явно попросив увімкнути повідомлення.
    $requiredNotificationRoutes = @("alerts")
    if ($script:SlackMode -eq "all") {
        $requiredNotificationRoutes += "general"
    }
    $notificationConfigurationValid = $true
    foreach ($requiredRoute in $requiredNotificationRoutes) {
        $requiredRouteUrl = [string]$script:NotificationWebhookUrls[$requiredRoute]
        if ([string]::IsNullOrWhiteSpace($requiredRouteUrl) -or -not $requiredRouteUrl.StartsWith("https://")) {
            $notificationConfigurationValid = $false
        }
    }
    if (-not $notificationConfigurationValid) {
        $credentialDetails = if ($NotificationCredentialError) { ": $NotificationCredentialError" } else { "" }
        Write-Host "ПОМИЛКА: Для каналу $NotificationProviderDisplayName не знайдено коректний HTTPS webhook у Credential Manager$credentialDetails" -ForegroundColor Red
        exit 31
    }
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
function Get-BRAVOBravoWebComponentPlan {
    [CmdletBinding()]
    param(
        [bool]$ComponentEnabled,
        [bool]$ServiceExists,
        [bool]$ServiceDisabled,
        [int]$ServiceMatchCount
    )

    $manageInstalledService = $ComponentEnabled -and $ServiceExists -and -not $ServiceDisabled
    return [pscustomobject]@{
        SilentlySkipped = $ComponentEnabled -and -not $ServiceExists
        ManageService = $manageInstalledService
        WarnDuplicateService = $ServiceExists -and $ServiceMatchCount -gt 1
        WarningCountDelta = 0
        # Legacy web data is part of the optional component: it is handled
        # only when BRAVO Web is enabled and an installed service identifies
        # the component. A disabled installed service still keeps its data.
        IncludeLegacyWebData = $ComponentEnabled -and $ServiceExists
    }
}

function Get-BRAVOOptionalServiceComponentPlan {
    [CmdletBinding()]
    param(
        [bool]$ServiceExists,
        [bool]$ServiceDisabled
    )

    return [pscustomobject]@{
        SilentlySkipped = -not $ServiceExists
        ManageService = $ServiceExists -and -not $ServiceDisabled
        IncludeLegacyData = $ServiceExists
    }
}

$bravoWebComponentPlan = Get-BRAVOBravoWebComponentPlan `
    -ComponentEnabled $BravoWebComponentEnabled `
    -ServiceExists $ApacheServiceExists `
    -ServiceDisabled $BravoWebServiceDisabledBySystem `
    -ServiceMatchCount $BravoWebServiceMatchCount
$BravoWebMaintenanceEnabled = [bool]$bravoWebComponentPlan.ManageService
$BravoWebLegacyDataEnabled = [bool]$bravoWebComponentPlan.IncludeLegacyWebData

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
$exchangeApiComponentPlan = Get-BRAVOOptionalServiceComponentPlan `
    -ServiceExists $exchangAPIServiceState.Exists `
    -ServiceDisabled $exchangAPIServiceDisabled
$exchangAPIServiceEnabled = [bool]$exchangeApiComponentPlan.ManageService
$exchangAPILegacyDataEnabled = [bool]$exchangeApiComponentPlan.IncludeLegacyData

# ===== ГЛОБАЛЬНІ ЗМІННІ (НЕ ЗМІНЮВАТИ) =====
$script:ScriptStartTime = [DateTime]::Now
$script:CriticalErrors = $false
$script:CriticalErrorsList = New-Object 'System.Collections.Generic.List[string]'
# Окрема черга для notification-only WARNING/ERROR (Send-SlackAlert
# -Severity без -IsCritical): CriticalErrorsList лишається виключно для
# фактичних execution-critical подій (-IsCritical/$isSpaceError), щоб
# Send-FinalReport не ескалював notification-severity WARNING до
# "КРИТИЧНІ ПОМИЛКИ ОБСЛУГОВУВАННЯ"/CRITICAL (review finding #2).
$script:NotificationAlertQueue = New-Object 'System.Collections.Generic.List[object]'
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
# Реставрація провалилась і знадобився (або мав знадобитися) відкат із
# before-архіву — окремо від restoreArchiveFailed (збій СТВОРЕННЯ архіву).
# Мапиться в RestoreFailed (43).
$script:restoreFailed = $false
# Чи доведено консистентність моделі після фази реставрації. Дефолт true:
# коли реставрації не було, або вона успішна/успішно відкочена — модель
# консистентна. false лише коли деструктив виконувався, а цілісність НЕ
# встановлено (відкат провалився або before-архів невалідний) — тоді служби
# НЕ піднімати (гейт нижче), fail-closed.
$script:modelIntegrityEstablished = $true

function Enter-BRAVOMaintenanceOperationLock {
    $lockPath = [string]$operationLockSettings.Path
    try {
        if ([string]::IsNullOrWhiteSpace($lockPath)) {
            throw 'operationLockSettings.Path не задано'
        }
        $lockDirectory = Split-Path -Path $lockPath -Parent
        if (-not (Test-Path -LiteralPath $lockDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $lockDirectory -Force -ErrorAction Stop)
        }
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
                # FileShare.Read (не .None): дозволяє чужому read-only peek
                # побачити, хто тримає lock, поки він ще активний — не
                # послаблює саму ексклюзивність, бо конкуруючий acquire
                # (той самий ReadWrite/Read виклик) усе одно провалиться
                # проти вже відкритого handle. Раніше .None робив holder-а
                # непрозорим навіть для власної діагностики очікування
                # (порт 127e7e4 з backup/local-developer-rc2-line).
                $stream = [System.IO.File]::Open(
                    $lockPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::Read
                )
            } catch {
                $lastLockError = $_.Exception.Message
                if ((Get-Date) -lt $deadline) {
                    # Оператор бачив лише мовчазний Start-Sleep до
                    # OperationLockWaitMinutes і жодного натяку, хто саме
                    # тримає lock, хоча holder уже пише в цей файл JSON із
                    # operation/pid/hostname/generationId (DEV-LIMS
                    # acceptance 2026-08-23). Читання — best-effort: holder
                    # тримає файл із FileShare.Read, тому в звичайному разі
                    # peek вдається; вузьке вікно між OpenOrCreate і Write
                    # лишається, і тоді просто немає що показати — це не
                    # привід перетворити діагностичний peek на ще одну
                    # причину провалити захоплення lock.
                    $holderDescription = "невідомо (lock ще не опубліковано або читання наразі неможливе)"
                    try {
                        $peekStream = [System.IO.File]::Open(
                            $lockPath,
                            [System.IO.FileMode]::Open,
                            [System.IO.FileAccess]::Read,
                            [System.IO.FileShare]::ReadWrite
                        )
                        try {
                            $peekReader = New-Object System.IO.StreamReader($peekStream, [System.Text.Encoding]::UTF8)
                            $peekText = $peekReader.ReadToEnd()
                        } finally {
                            $peekStream.Dispose()
                        }
                        if (-not [string]::IsNullOrWhiteSpace($peekText)) {
                            $holderInfo = $peekText | ConvertFrom-Json
                            $holderDescription = "operation=$($holderInfo.operation); pid=$($holderInfo.pid); hostname=$($holderInfo.hostname); startedAt=$($holderInfo.startedAt); generationId=$($holderInfo.generationId)"
                        }
                    } catch {
                        # Peek не вдався (гонка з holder-ом, тимчасова
                        # недоступність) — лишаємо дефолтний опис вище.
                    }
                    Write-Log "Очікую звільнення операційного lock ($lockPath); тримає: $holderDescription; залишилось $([math]::Max(0, [int]($deadline - (Get-Date)).TotalMinutes)) хв." -Level "INFO"
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
            generationId = $null
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
    # Stale metadata file is expected; only the exclusive handle indicates
    # that Archive or Maintenance is currently active.
    $script:maintenanceOperationLockPath = $null
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

# dev.14 (round 3): -NoPause керує ЛИШЕ тим, чи скрипт чекає на клавішу
# наприкінці (Wait-BRAVOManualExit) — це UX-перемикач, який адміністратор
# може передати вручну (наприклад, з CI чи скрипта), не перетворюючись від
# цього на "заплановане завдання". Режим у заголовку має відображати
# ФАКТИЧНЕ джерело запуску: SYSTEM (S-1-5-18, той самий SID, що вже
# визначає гілку елевації вище) — це SCHEDULED; будь-хто інший — MANUAL,
# незалежно від -NoPause. Pure-функція: жодного власного звернення до
# WindowsIdentity/WindowsPrincipal — SID завжди приходить від виклику
# (вже обчислений $currentIdentity.User.Value вище), щоб залишатися
# тестованою на детермінованих вхідних без реальної системної ідентичності.
function Get-BRAVOMaintenanceExecutionMode {
    param([Parameter(Mandatory = $true)][string]$UserSid)

    if ($UserSid -eq 'S-1-5-18') {
        return 'SCHEDULED'
    }
    return 'MANUAL'
}

# ===== ОПЕРАЦІЙНА КОНСОЛЬ =====
# Нумерація етапів: [1/8], [2/8], ... Ті самі елементи виводу, що в Archive
# і Health: заголовок, етапи, підсумок.
$script:BRAVOMaintenanceStepCurrent = 0
$script:BRAVOMaintenanceStepTotal = 0
$script:BRAVOMaintenanceLastStepTime = $null
# dev.14 (round 2): підсумкові лічильники operator console ("Кроків/
# Успішно/Попереджень/Пропущено/Помилок" у фінальному РЕЗУЛЬТАТ) — той
# самий підхід, що BRAVOHealthStepOkCount/.../BRAVOHealthStepErrorCount
# у BRAVO.Health.Runtime.ps1, лише з додатковим SKIPPED-лічильником
# (Maintenance, на відміну від Health, регулярно показує SKIPPED-кроки).
$script:BRAVOMaintenanceStepOkCount = 0
$script:BRAVOMaintenanceStepWarnCount = 0
$script:BRAVOMaintenanceStepSkippedCount = 0
$script:BRAVOMaintenanceStepFailCount = 0
# Журнал кроків (Name/Status/Details) — фактичний результат кожного етапу.
# Потрібен фінальному сповіщенню: раніше блок "Виконано" будувався суто з
# КОНФІГУРАЦІЙНИХ прапорців (компонент увімкнено -> ✅), тому збійний етап
# (напр. Trace) показувався зеленим, а оператор не бачив, що саме не так.
$script:BRAVOMaintenanceStepLog = New-Object System.Collections.Generic.List[object]

function Initialize-BRAVOMaintenanceSteps {
    param([Parameter(Mandatory = $true)][int]$Total)

    $script:BRAVOMaintenanceStepCurrent = 0
    $script:BRAVOMaintenanceStepTotal = [Math]::Max(1, $Total)
    $script:BRAVOMaintenanceLastStepTime = Get-Date
    $script:BRAVOMaintenanceStepOkCount = 0
    $script:BRAVOMaintenanceStepWarnCount = 0
    $script:BRAVOMaintenanceStepSkippedCount = 0
    $script:BRAVOMaintenanceStepFailCount = 0
    $script:BRAVOMaintenanceStepLog = New-Object System.Collections.Generic.List[object]
}

# Останній зафіксований статус етапу за іменем. Етап може звітувати кілька
# разів (напр. 'Обробка trace і логів' у різних гілках) — операторові
# важливий підсумковий стан, тому береться ОСТАННІЙ запис.
function Get-BRAVOMaintenanceStepOutcome {
    param([Parameter(Mandatory = $true)][string]$Name)

    for ($index = $script:BRAVOMaintenanceStepLog.Count - 1; $index -ge 0; $index--) {
        $entry = $script:BRAVOMaintenanceStepLog[$index]
        if ([string]$entry.Name -eq $Name) {
            return $entry
        }
    }
    return $null
}

# Статус етапу рахується від ЗРІЗУ лічильників перед блоком, а не від
# їхнього абсолютного значення: $script:criticalErrorOccurred накопичується
# до кінця запуску, тому без зрізу одна рання помилка пофарбувала б у
# червоне всі наступні етапи, які насправді відпрацювали.
#
# dev.14 (round 2): словник статусів operator console — рівно OK/SKIPPED/
# WARN/FAIL (docs/OPERATOR_CONSOLE_UX.md), без WARNING/ERROR/SUCCESS/PASS,
# щоб таблиця кроків Maintenance не змішувала кілька словників в одному
# прогоні.
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
        return 'FAIL'
    }
    if ($script:BRAVOWarningCount -gt $WarningsBefore) {
        return 'WARN'
    }
    return 'OK'
}

# dev.19 (виправлено): ЄДИНА канонічна точка числового exit-code —
# та сама пріоритетна політика (критичний > попередження > успіх, з
# розподілом critical на 40/41/60 через Resolve-BRAVOExitCode), яка
# раніше була inline-блоком нижче ($script:maintenanceRuntimeExitCode =
# if (...) {...}). Вона не дублюється — і "поточний знімок" для
# Send-FinalReport (виконується ВСЕРЕДИНІ зовнішнього try, ДО його catch
# — стан теоретично ще може змінитися до кінця try), і СПРАВЖНЄ фінальне
# значення (після catch, перед ЗАВЕРШЕННЯМ СКРИПТУ) отримують число
# через РІВНО цей виклик. Resolve-BRAVOExitCode лишається джерелом істини для самих
# кодів; тут лише те саме зведення трьох script-scope прапорців, що
# раніше було записане прямо в місці присвоєння.
function Get-BRAVOMaintenanceResolvedExitCode {
    if ($script:criticalErrorOccurred) {
        return Resolve-BRAVOExitCode `
            -LocalArchiveFailed:$script:restoreArchiveFailed `
            -IntegrityTestFailed:$script:restoreIntegrityFailed `
            -RestoreFailed:$script:restoreFailed `
            -MaintenanceFailed
    }
    if ($script:BRAVOWarningCount -gt 0) {
        return Resolve-BRAVOExitCode -HasWarnings
    }
    return 0
}

# dev.19 (виправлено): єдина канонічна точка "людський текст фінального
# статусу" — ЛОГ (=== СТАТУС: ... ===), консольне РЕЗУЛЬТАТ (поле
# "Статус") і фінальне success-повідомлення (Send-FinalReport) читають
# текст ЗВІДСИ. На відміну від першої версії dev.19, ця функція більше
# НЕ інспектує $script:criticalErrorOccurred/$script:BRAVOWarningCount
# самостійно (те була паралельна, хоч і узгоджена, класифікаційна
# політика) — вона класифікує РЕЗОЛЬВЛЕНИЙ числовий код через
# Get-BRAVOExitCodeName (BRAVO.ExitCodes, те саме джерело істини, що
# вже показує "Код завершення:" у РЕЗУЛЬТАТ нижче). default-гілка
# покриває 40/41/60 і будь-який інший неуспішний/не-warning код без
# перелічення кожного окремо. Реальний DEV-LIMS запуск: відсутній
# Range ID log (WARN-only, семантика НЕ змінена) -> exit 10
# (SuccessWithWarnings), але ЛОГ і фінальне повідомлення раніше
# незалежно показували "УСПІШНО" без жодної згадки про попередження.
function Get-BRAVOMaintenanceFinalStatus {
    param([Parameter(Mandatory = $true)][int]$ExitCode)

    switch (Get-BRAVOExitCodeName -Code $ExitCode) {
        'Success' {
            return [pscustomobject]@{
                Text = 'УСПІШНО'
                Color = [ConsoleColor]::Green
            }
        }
        'SuccessWithWarnings' {
            return [pscustomobject]@{
                Text = 'УСПІШНО З ПОПЕРЕДЖЕННЯМИ'
                Color = [ConsoleColor]::Yellow
            }
        }
        default {
            return [pscustomobject]@{
                Text = 'ПОМИЛКА'
                Color = [ConsoleColor]::Red
            }
        }
    }
}

# ЄДИНА канонічна точка обліку результату етапу — і лічильники підсумкового
# блоку РЕЗУЛЬТАТ, і журнал для фінального сповіщення. Викликається з ОБОХ
# рендерів: Write-BRAVOMaintenanceStep (пронумеровані [N/Total]) і
# Write-BRAVOMaintenanceOperation (ненумеровані операції).
#
# Реальний DEV-LIMS прогін 19:26 показав, чому облік мусить бути спільним:
# ненумеровані операції рендерилися прямо через Write-BRAVOOperationResult
# (BRAVO.Console), тому FAIL-операція "Trace: добовий архів і SFTP" не
# потрапляла ані в лічильники (підсумок брехав "Помилок: 0" при exit 60),
# ані в журнал (сповіщення показувало "✅ Trace" замість ❌ і зовсім не
# показувало рядок "Очистка").
#
# Нумератор $script:BRAVOMaintenanceStepCurrent тут НЕ чіпається свідомо:
# його інкрементує лише Write-BRAVOMaintenanceStep, інакше зсунеться
# нумерація [N/Total] пронумерованих кроків.
function Add-BRAVOMaintenanceStepOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('OK', 'SKIPPED', 'WARN', 'FAIL')]
        [string]$Status = 'OK',
        [string]$Details
    )

    switch ($Status) {
        'OK'      { $script:BRAVOMaintenanceStepOkCount++ }
        'WARN'    { $script:BRAVOMaintenanceStepWarnCount++ }
        'SKIPPED' { $script:BRAVOMaintenanceStepSkippedCount++ }
        'FAIL'    { $script:BRAVOMaintenanceStepFailCount++ }
    }
    # Той самий запис, що йде в консоль, зберігається для фінального
    # сповіщення (див. коментар біля BRAVOMaintenanceStepLog вище).
    [void]$script:BRAVOMaintenanceStepLog.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Details = [string]$Details
    })
}

# Ненумерована операція Maintenance (Trace-SFTP, Очистка, Міграція,
# Архівація, Автовимкнення): той самий консольний рендер, що й раніше
# (Write-BRAVOOperationResult з BRAVO.Console — спільна межа рендеру, яку
# використовують і Archive, і DataRestore, тому maintenance-специфічний
# облік у неї не вбудовується), плюс той самий облік, що в пронумерованих
# кроків.
function Write-BRAVOMaintenanceOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('OK', 'SKIPPED', 'WARN', 'FAIL')]
        [string]$Status = 'OK',
        [Nullable[timespan]]$Duration,
        [string]$Details
    )

    Add-BRAVOMaintenanceStepOutcome -Name $Name -Status $Status -Details $Details
    Write-BRAVOOperationResult -Name $Name -Status $Status -Duration $Duration -Details $Details
}

function Write-BRAVOMaintenanceStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('OK', 'SKIPPED', 'WARN', 'FAIL')]
        [string]$Status = 'OK',
        [string]$Details
    )

    $script:BRAVOMaintenanceStepCurrent++
    Add-BRAVOMaintenanceStepOutcome -Name $Name -Status $Status -Details $Details
    # Тривалість кроку — час від попереднього кроку (чи від Initialize, для
    # першого). Той самий підхід, що в Health: жоден із ~9 кроків не має
    # власного таймера, і додавати його кожному окремо — набагато більший
    # ризик регресії, ніж один спільний облік тут.
    $stepDuration = $null
    if ($null -ne $script:BRAVOMaintenanceLastStepTime) {
        $stepDuration = (Get-Date) - $script:BRAVOMaintenanceLastStepTime
    }
    $script:BRAVOMaintenanceLastStepTime = Get-Date
    Write-BRAVOStepResult `
        -Current $script:BRAVOMaintenanceStepCurrent `
        -Total $script:BRAVOMaintenanceStepTotal `
        -Name $Name `
        -Status $Status `
        -Duration $stepDuration

    # -Duration і -Details у Write-BRAVOStepResult взаємовиключні за
    # дизайном (перше вже зайняло рядок статусу) — тому Details, коли є,
    # друкується під рядком етапу окремим викликом.
    #
    # dev.14 (round 3): рівно 6 пробілів відступу, БЕЗ автоматичного
    # префіксу "Причина:"/"Деталі:" для жодного статусу (OK/WARN/FAIL/
    # SKIPPED) — сам колір/слово статусу в рядку етапу вище вже пояснює
    # severity, дублювати її текстовим підписом під деталлю не потрібно.
    # Write-BRAVOConsoleDetail — єдиний спільний рендерер із таким
    # відступом (Write-BRAVOStepDetail відступу не додає; Write-BRAVOSkipReason/
    # Write-BRAVOOperatorReason — не той стиль, що потрібен тут). Details
    # може бути багаторядковим (наприклад "причина:`nшлях") — Write-Host
    # додає відступ лише перед ПЕРШИМ рядком свого аргументу, тому кожен
    # рядок друкується окремим викликом, щоб відступ був однаковий на всіх.
    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        foreach ($detailLine in ($Details -split "`r?`n")) {
            Write-BRAVOConsoleDetail -Message $detailLine
        }
    }
}

# ===== ФУНКЦІЯ ЛОГУВАННЯ =====
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [int]$SeparatorLength = 100,
        [switch]$NoTimestamp,
        # dev.15: для повідомлень, які й так вже показані оператору іншим
        # шляхом (наприклад Details операційного кроку) — LOG-файл і
        # сповіщення (Send-SlackAlert викликається окремо, не звідси)
        # лишаються незмінними, друк у консоль пропускається. За
        # замовчуванням вимкнено — жоден існуючий виклик Write-Log не змінює
        # поведінку.
        [switch]$NoConsole,

        # Environmental-нагадування (застарілі оновлення ОС/PowerShell) —
        # це стан середовища, а не результат операції. Такий запис лишається
        # видимим як WARNING, але НЕ інкрементує лічильник попереджень:
        # інакше кожен успішний прогін на невідновленому сервері назавжди
        # завершувався б кодом 10 (SuccessWithWarnings) зі статусом ЧАСТКОВО,
        # поки адміністратор не встановить оновлення Windows.
        [switch]$Environmental
    )

    # Пароль архіву, webhook чи URL з обліковими даними можуть потрапити
    # сюди через повідомлення винятку — маскуємо перед виводом у консоль
    # чи запис у файл, до будь-якого з можливих виходів функції нижче.
    $Message = Protect-BRAVOLogSecret -Text $Message
    if ($Level -eq "WARNING" -and -not $Environmental) {
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
    # не йдуть.
    # dev.19: голий роздільник "==="/"=" БІЛЬШЕ НЕ пише окремий запис у
    # журнал (той самий підхід, що вже Archive dev.18). Реальний DEV-LIMS
    # лог показав рядки лише зі 100 символами "=" між звичайними секціями
    # — без жодної діагностичної цінності, бо кожен такий виклик стоїть
    # безпосередньо перед "=== ЗАГОЛОВОК ===", який і так фіксує ту саму
    # мить повним текстом. Застосовано однаково і до звичайних секцій, і
    # до початкового/фінального банера (той самий виклик, той самий
    # аргумент "===" — немає окремого "banner-only" шляху в коді; два
    # сусідні реальні заголовки банера ("СИСТЕМА ОБСЛУГОВУВАННЯ..."/
    # "УСТАНОВА: ...") лишаються чіткими і без обрамляючих "===" рядків).
    # Заголовки нижче (гілка "=== ... ===") лишаються повністю без змін.
    if ($Message -eq "=" -or $Message -eq "===") {
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

    if (-not $NoConsole -and $messageLevel -ge $consoleThreshold) {
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
                    # dev.16: оператор інтерактивно скасував УЖЕ заплановане
                    # вимкнення, і команда /a відпрацювала штатно — системного
                    # вимкнення не відбудеться. Відрізняється від "Failed"
                    # (сама scheduling-команда вище виконалась успішно).
                    return 'Cancelled'
                } else {
                    Write-Log -Message "Не вдалося скасувати вимкнення" -Level "ERROR"
                    [System.Windows.Forms.MessageBox]::Show("Не вдалося скасувати вимкнення. Спробуйте виконати команду вручну: shutdown /a", "Помилка",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning)
                    # Спроба скасування не вдалась — вимкнення лишається
                    # запланованим (shutdown-команда вище виконалась штатно),
                    # система фактично вимкнеться.
                    return 'Scheduled'
                }
            } else {
                Write-Log -Message "Користувач підтвердив вимкнення системи" -Level "INFO"
                [System.Windows.Forms.MessageBox]::Show("Система буде вимкнена через $Timeout секунд.", "BravoSoft",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information)
                return 'Scheduled'
            }
        } else {
            Write-Log -Message "Помилка ініціювання вимкнення системи. Код помилки: $($process.ExitCode)" -Level "ERROR"
            return 'Failed'
        }
    }
    catch {
        Write-Log -Message "Помилка під час спроби вимкнення системи: $($_.Exception.Message)" -Level "ERROR"
        return 'Failed'
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

function Write-BRAVOMaintenanceEarlyFailureSummary {
    param(
        [Parameter(Mandatory = $true)][datetime]$EndedAt,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )

    $duration = $EndedAt - $script:ScriptStartTime
    $finalStatus = Get-BRAVOMaintenanceFinalStatus -ExitCode $ExitCode

    Write-Log -Message "==="
    Write-Log -Message "=== СИСТЕМА ОБСЛУГОВУВАННЯ BRAVOSOFT ЗАВЕРШИЛА РОБОТУ ==="
    Write-Log -Message "=== УСТАНОВА: $($script:ObjectName) ==="
    Write-Log -Message "=== ЧАС ВИКОНАННЯ: $(Format-Duration $duration) ==="
    Write-Log -Message "=== СТАТУС: $($finalStatus.Text) ==="
    Write-Log -Message "==="

    Write-BRAVOFinalSummaryHeader `
        -Title 'BRAVO MAINTENANCE' `
        -Status $finalStatus.Text `
        -StatusColor $finalStatus.Color
    $earlySummaryFields = [ordered]@{
        'Статус' = $finalStatus.Text
        'Код завершення' = ("{0} — {1}" -f $ExitCode, (Get-BRAVOExitCodeName -Code $ExitCode))
        'Початок' = $script:ScriptStartTime.ToString('dd.MM.yyyy HH:mm:ss')
        'Завершення' = $EndedAt.ToString('dd.MM.yyyy HH:mm:ss')
        'Тривалість' = Format-BRAVODuration -Duration $duration
    }
    foreach ($field in $earlySummaryFields.GetEnumerator()) {
        if ($field.Key -eq 'Статус') {
            Write-BRAVOResultField -Label ([string]$field.Key) -Value ([string]$field.Value) -Color $finalStatus.Color
        } else {
            Write-BRAVOResultField -Label ([string]$field.Key) -Value ([string]$field.Value)
        }
    }
    Write-BRAVOResultBlankLine
    $earlySummaryCounters = [ordered]@{
        'Кроків' = $script:BRAVOMaintenanceStepCurrent
        'Успішно' = $script:BRAVOMaintenanceStepOkCount
        'Попереджень' = $script:BRAVOMaintenanceStepWarnCount
        'Пропущено' = $script:BRAVOMaintenanceStepSkippedCount
        'Помилок' = $script:BRAVOMaintenanceStepFailCount
    }
    foreach ($counter in $earlySummaryCounters.GetEnumerator()) {
        Write-BRAVOResultField -Label ([string]$counter.Key) -Value ([string]$counter.Value)
    }
    Write-BRAVOFinalSummaryFooter -LogFile $LOG_FILE
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
    $path = Join-Path $stateRoot 'BRAVO_RESTORE_STATE.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { Write-Log -Message "Не вдалося прочитати restore state: $($_.Exception.Message)" -Level 'WARNING'; return $null }
}

# Слот, покритий успішною ПРИМУСОВОЮ реставрацією (тижнева квота).
# Читається StrictMode-безпечно: стан, збережений попередньою версією,
# цього поля не має — відсутність означає "квота не спожита", тобто рівно
# попередню поведінку.
function Get-BRAVORestoreForcedCoveredSlot {
    param($State)

    if ($null -eq $State) { return $null }
    if ($null -eq $State.PSObject.Properties['ForcedRestoreCoversSlot']) { return $null }
    $raw = [string]$State.ForcedRestoreCoversSlot
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    [datetime]$parsed = [datetime]::MinValue
    if ([datetime]::TryParse(
            $raw,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# Чи спожита тижнева квота автоматичної реставрації успішною ПРИМУСОВОЮ.
# Успішний -ForceRestore записує ПОКРИТИЙ слот = наступний плановий
# (+7 днів) і НЕ закриває поточний плановий слот маркером/Status —
# тому «пропущений» МИНУЛИЙ слот лишається formally missed. Строга
# рівність (ForcedCoveredSlot -eq ScheduledOccurrence) через це давала
# подвійну реставрацію: примусова о 22:00, і того ж вечора звичайний
# прогін у вікні бачив missed-слот минулого тижня (< покритого) і
# запускав реставрацію ВДРУГЕ (реальний інцидент 2026-08-26). Правильна
# семантика «не частіше разу на тиждень»: покритий слот закриває СОБОЮ
# і всі попередні (<=). Наступний плановий слот (+7 днів після
# покритого) строго більший — квота знімається рівно вчасно, без
# межової помилки арифметики «різниця < 7 діб».
function Test-BRAVORestoreWeeklyQuotaConsumed {
    param(
        [AllowNull()]$ForcedCoveredSlot,
        [Parameter(Mandatory = $true)][datetime]$ScheduledOccurrence
    )

    if ($null -eq $ForcedCoveredSlot) { return $false }
    return ($ScheduledOccurrence -le [datetime]$ForcedCoveredSlot)
}

# Дата ОСТАННЬОЇ успішної реставрації — будь-якої, і планової, і
# примусової. Окреме поле потрібне тому, що оператору показується "остання:
# <дата>", а історичне джерело цієї дати (файли restore_done_*.marker)
# примусову реставрацію не бачить: маркер свідомо створюється лише
# автоматичним шляхом. Через це реальне повідомлення показувало "ще не
# виконувалася" через 20 хвилин після успішної примусової реставрації.
function Get-BRAVORestoreLastSuccessfulAt {
    param($State)

    if ($null -eq $State) { return $null }
    if ($null -eq $State.PSObject.Properties['LastSuccessfulRestoreAt']) { return $null }
    $raw = [string]$State.LastSuccessfulRestoreAt
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    [datetime]$parsed = [datetime]::MinValue
    if ([datetime]::TryParse(
            $raw,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# Результат успішної ПРИМУСОВОЇ реставрації: тижнева квота + дата останньої.
# ScheduledOccurrence/Status/Reason НЕ чіпаються — це принципово: примусова
# реставрація не закриває плановий слот (маркер і Status='Succeeded'
# лишаються за автоматичним шляхом), тому записати сюди поточний слот зі
# старим Status='Succeeded' не можна — $scheduledSucceeded помилково визнав
# би поточний слот виконаним.
function Write-BRAVORestoreForcedOutcome {
    param(
        [Parameter(Mandatory = $true)][datetime]$CoveredSlot,
        [Parameter(Mandatory = $true)][datetime]$CompletedAt
    )

    $path = Join-Path $stateRoot 'BRAVO_RESTORE_STATE.json'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $stateRoot -Force -ErrorAction Stop)
    }
    $existing = Read-BRAVORestoreState
    $state = [pscustomobject]@{
        ScheduledOccurrence = [string]$(if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['ScheduledOccurrence']) { $existing.ScheduledOccurrence } else { $null })
        Status = [string]$(if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['Status']) { $existing.Status } else { $null })
        Reason = [string]$(if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['Reason']) { $existing.Reason } else { $null })
        ForcedRestoreCoversSlot = $CoveredSlot.ToString('o')
        LastSuccessfulRestoreAt = $CompletedAt.ToString('o')
        UpdatedAt = ([datetime]::Now).ToString('o')
    }
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
}

function Write-BRAVORestoreState {
    param(
        [datetime]$ScheduledOccurrence,
        [string]$Status,
        [string]$Reason
    )
    $path = Join-Path $stateRoot 'BRAVO_RESTORE_STATE.json'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $stateRoot -Force -ErrorAction Stop)
    }
    # Файл перезаписується цілком, а функція викликається і зі статусом
    # 'Pending' (постановка слоту на паузу), і зі 'Succeeded'. Без цього
    # переносу будь-який із них тихо стер би тижневу квоту, і планова
    # реставрація виконалась би вдруге за тиждень.
    $existingRestoreState = Read-BRAVORestoreState
    $preservedForcedCoversSlot = Get-BRAVORestoreForcedCoveredSlot -State $existingRestoreState
    # Дата останньої успішної реставрації оновлюється САМЕ тут для
    # автоматичного шляху (Status='Succeeded'); при 'Pending' переноситься
    # попереднє значення. Примусовий шлях пише її через
    # Write-BRAVORestoreForcedOutcome.
    $lastSuccessfulRestoreAt = if ($Status -eq 'Succeeded') {
        [datetime]::Now
    } else {
        Get-BRAVORestoreLastSuccessfulAt -State $existingRestoreState
    }
    $state = [pscustomobject]@{
        ScheduledOccurrence = $ScheduledOccurrence.ToString('o')
        Status = $Status
        Reason = $Reason
        ForcedRestoreCoversSlot = $(if ($null -ne $preservedForcedCoversSlot) { ([datetime]$preservedForcedCoversSlot).ToString('o') } else { $null })
        LastSuccessfulRestoreAt = $(if ($null -ne $lastSuccessfulRestoreAt) { ([datetime]$lastSuccessfulRestoreAt).ToString('o') } else { $null })
        UpdatedAt = ([datetime]::Now).ToString('o')
    }
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-BRAVOTaskExecutionState {
    $path = Join-Path $stateRoot 'BRAVO_TASK_EXECUTION_STATE.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @{ Maintenance = [string]$state.Maintenance; Backup = [string]$state.Backup }
    } catch { return @{} }
}

function Write-BRAVOTaskExecutionState {
    param([ValidateSet('Maintenance')][string]$TaskName)
    $path = Join-Path $stateRoot 'BRAVO_TASK_EXECUTION_STATE.json'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $stateRoot -Force -ErrorAction Stop)
    }
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
        [string]$LogPath,

        # Явна канонічна NotificationSeverity. Якщо caller уже знає точну
        # severity (напр. Send-FinalReport для NotificationAlertQueue —
        # WARNING/ERROR/CRITICAL, review finding: notification-only
        # ERROR/CRITICAL не повинні "downgrade"-итись до WARNING лише
        # через спільний TitleEmoji ":warning:"), її треба передавати сюди
        # напряму — вона стає source of truth і inference з TitleEmoji/Title
        # нижче пропускається. Якщо не передано — поведінка ідентична
        # попередній (backward compatibility для наявних викликів).
        [ValidateSet("SUCCESS", "WARNING", "ERROR", "CRITICAL")]
        [string]$Severity
    )

    $hostInformation = Get-HostInformation
    # dev.19 (виправлено): ":warning:" перевіряється ПЕРШИМ. Раніше
    # "$Title -match 'УСПІШ'" мав пріоритет над TitleEmoji, тому
    # виклик Send-FinalReport з Title "... УСПІШНО З ПОПЕРЕДЖЕННЯМИ" і
    # TitleEmoji ":warning:" усе одно отримував би severity=SUCCESS
    # (Title і далі містить підрядок "УСПІШ") — суперечлива презентація:
    # ⚠️-іконка зовні, але "Дій не потрібно"/SUCCESS-набір рядків
    # усередині. Для трьох інших наявних викликів New-MaintenanceNotificationMessage
    # результат ідентичний обом порядкам (жоден не поєднує ":warning:" з
    # Title, що містить "УСПІШ").
    $severity = if ($Severity) {
        $Severity
    } elseif ($TitleEmoji -eq ":warning:") {
        "WARNING"
    } elseif ($TitleEmoji -eq ":white_check_mark:" -or $Title -match "УСПІШ") {
        "SUCCESS"
    } else {
        "CRITICAL"
    }
    $operation = if ($severity -eq "SUCCESS") {
        "BRAVO MAINTENANCE — УСПІШНО"
    } else {
        "BRAVO MAINTENANCE — ПОТРІБНА ДІЯ"
    }
    $detailsTextForAction = (@($Details) -join "`n")
    $actionText = if ($severity -eq "SUCCESS") {
        "Дій не потрібно"
    } elseif ($Title -match "місц|диск|space" -or $detailsTextForAction -match "Недостатньо вільного місця|залишилось .* потрібно мінімум") {
        "звільнити місце на проблемному диску або перевірити доступність дисків."
    } else {
        "перевірити журнал BRAVO_MAINTENANCE."
    }
    $buildIdText = if ([string]::IsNullOrWhiteSpace([string]$script:ScriptBuildId)) {
        "невідома"
    } else {
        [string]$script:ScriptBuildId
    }

    $resultLines = New-Object System.Collections.Generic.List[string]
    $nonEmptyStatusLines = @($StatusLines | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($nonEmptyStatusLines.Count -gt 0) {
        foreach ($line in $nonEmptyStatusLines) {
            $resultLines.Add([string]$line)
        }
    }

    $detailLines = New-Object System.Collections.Generic.List[string]
    foreach ($detail in @($Details)) {
        foreach ($detailLine in ([string]$detail -split "\r?\n")) {
            # При копіюванні деякі клієнти додають коми до порожніх рядків.
            # Нормалізуємо їх і зберігаємо початкове маркування деталей.
            $trimmedDetail = $detailLine.Trim().TrimEnd(",").Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmedDetail)) {
                $detailLines.Add($trimmedDetail)
            }
        }
    }
    if ($detailLines.Count -gt 0) {
        $spaceDetailRendered = $false
        foreach ($detailLine in $detailLines) {
            if ($severity -ne "SUCCESS" -and
                [string]$detailLine -match 'диск\s+([A-Z]:):?\s+залишилось\s+([0-9]+([.,][0-9]+)?)\s+GB,\s+потрібно мінімум\s+([0-9]+([.,][0-9]+)?)\s+GB') {
                $driveName = [string]$Matches[1]
                $freeGb = [double](([string]$Matches[2]).Replace(',', '.'))
                $minimumGb = [double](([string]$Matches[4]).Replace(',', '.'))
                $deficitGb = [math]::Round(($minimumGb - $freeGb), 2)
                $resultLines.Add(":x: Недостатньо вільного місця на диску $driveName")
                $resultLines.Add("Потрібна дія: звільнити щонайменше $deficitGb ГБ.")
                $resultLines.Add("")
                $resultLines.Add(":floppy_disk: $driveName")
                $resultLines.Add("Вільно: $freeGb ГБ")
                $resultLines.Add("Мінімум: $minimumGb ГБ")
                $resultLines.Add("Дефіцит: $deficitGb ГБ")
                $spaceDetailRendered = $true
            } elseif (-not $spaceDetailRendered) {
                $resultLines.Add($detailLine)
            }
        }
    }

    return New-BRAVOOperatorNotificationMessage `
        -Severity $severity `
        -Operation $operation `
        -ActionText $actionText `
        -InstitutionName ([string]$script:ObjectName) `
        -HostInformation $hostInformation `
        -ResultLines $resultLines.ToArray() `
        -Timestamp (Get-Date) `
        -Duration $Duration `
        -TimestampLabel "Перевірено" `
        -ProductName "BRAVO Maintenance" `
        -Version ([string]$script:ScriptVersion) `
        -BuildId $buildIdText `
        -LogPath $LogPath `
        -LogLabel "Журнал"
}

function Get-MaintenanceMinimumFreeSpaceLines {
    $minimumLine = $null
    $minimumFreeGb = $null
    foreach ($driveLine in @($script:freeSpaceSummary)) {
        if ([string]$driveLine -match '^([A-Z]:)\s+([0-9]+([.,][0-9]+)?)\s+GB') {
            $freeGb = [double](([string]$Matches[2]).Replace(',', '.'))
            if ($null -eq $minimumFreeGb -or $freeGb -lt $minimumFreeGb) {
                $minimumFreeGb = $freeGb
                $minimumLine = "$($Matches[1]) $freeGb ГБ"
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($minimumLine)) {
        return @(":floppy_disk: Мінімальний запас: немає даних")
    }
    return @(
        ":floppy_disk: Мінімальний запас:",
        $minimumLine,
        "Порогове значення: $MIN_FREE_SPACE ГБ"
    )
}

# Компактний однорядковий варіант того самого запасу — для згрупованого
# рядка "Вільне місце" у сповіщенні (три окремі рядки погано читалися на
# мобільних). Джерело даних те саме, що Get-MaintenanceMinimumFreeSpaceLines.
function Get-MaintenanceFreeSpaceInlineText {
    $minimumLine = $null
    $minimumFreeGb = $null
    foreach ($driveLine in @($script:freeSpaceSummary)) {
        if ([string]$driveLine -match '^([A-Z]:)\s+([0-9]+([.,][0-9]+)?)\s+GB') {
            $freeGb = [double](([string]$Matches[2]).Replace(',', '.'))
            if ($null -eq $minimumFreeGb -or $freeGb -lt $minimumFreeGb) {
                $minimumFreeGb = $freeGb
                $minimumLine = "$($Matches[1]) $freeGb ГБ"
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($minimumLine)) {
        return "запас: немає даних"
    }
    return ":floppy_disk: $minimumLine · поріг: $MIN_FREE_SPACE ГБ"
}

# Блок "Виконано"/"Проблеми" фінального сповіщення. Джерело істини —
# ФАКТИЧНІ статуси етапів ($script:BRAVOMaintenanceStepLog), а не
# конфігураційні прапорці: саме через прапорці збійний етап (Trace) раніше
# показувався ✅ і оператор не бачив причини попередження.
#
# SKIPPED-етапи не друкуються (компонент вимкнено/не планувався — це не
# результат). Для не-OK етапу деталь беремо з самого етапу (там причина),
# а не декоративний текст успіху.
function New-BRAVOMaintenanceCompletedLines {
    param(
        [string]$LastRestoreText,
        [string]$FreeSpaceInlineText,
        [string]$TraceCountText,
        [string]$ExchangeCountText
    )

    $statusEmoji = @{ 'OK' = ':white_check_mark:'; 'WARN' = ':warning:'; 'FAIL' = ':x:'; 'SKIPPED' = ':fast_forward:' }
    # Порядок = порядок виконання; Steps — імена етапів, що покривають пункт
    # (гірший статус серед них перемагає: FAIL > WARN > OK).
    $map = @(
        # ShowWhenSkipped: реставрація — головна операція Maintenance, і її
        # ПРОПУСК оператор мусить бачити разом із причиною (тижнева квота,
        # не плановий день, вікно закрилося). Реальне повідомлення прогону
        # 22:23 не містило про реставрацію ЖОДНОГО рядка саме тому, що
        # SKIPPED-етапи мовчки відкидались. Решта етапів залишаються
        # прихованими при SKIPPED — інакше блок засмічується "вимкнено".
        @{ Label = 'Реставрація'; Steps = @('Реставрація моделі'); OkDetail = 'за планом'; ShowWhenSkipped = $true }
        @{ Label = '.md-файли'; Steps = @('Перевірка розмірів .md'); OkDetail = 'перевірено' }
        @{ Label = 'Інтервали ID'; Steps = @('Контроль діапазонів ID'); OkDetail = 'у нормі' }
        @{ Label = 'Trace'; Steps = @('Обробка trace і логів', 'Trace: добовий архів і SFTP'); OkDetail = $null }
        @{ Label = 'Очистка'; Steps = @('Очистка старих даних/логів'); OkDetail = 'виконано' }
        @{ Label = 'Вільне місце'; Steps = @('Перевірка вільного місця'); OkDetail = 'достатньо' }
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $problems = New-Object System.Collections.Generic.List[string]
    $lines.Add("Виконано:")

    foreach ($item in $map) {
        $worst = $null
        # Етапи з ShowWhenSkipped показуються навіть коли пропущені —
        # окремим "найгіршим" кандидатом нижчого рангу, щоб реальний
        # OK/WARN/FAIL будь-якого з Steps завжди його перекривав.
        $showWhenSkipped = ($null -ne $item['ShowWhenSkipped']) -and [bool]$item['ShowWhenSkipped']
        $skippedFallback = $null
        foreach ($stepName in @($item.Steps)) {
            $outcome = Get-BRAVOMaintenanceStepOutcome -Name $stepName
            if ($null -eq $outcome) { continue }
            if ([string]$outcome.Status -eq 'SKIPPED') {
                if ($showWhenSkipped -and $null -eq $skippedFallback) { $skippedFallback = $outcome }
                continue
            }
            $rank = switch ([string]$outcome.Status) { 'FAIL' { 3 } 'WARN' { 2 } default { 1 } }
            $worstRank = if ($null -eq $worst) { 0 } else {
                switch ([string]$worst.Status) { 'FAIL' { 3 } 'WARN' { 2 } default { 1 } }
            }
            if ($rank -ge $worstRank) { $worst = $outcome }
        }
        if ($null -eq $worst) { $worst = $skippedFallback }
        if ($null -eq $worst) { continue }

        $status = [string]$worst.Status
        $detail = if ($status -eq 'OK') {
            switch ([string]$item.Label) {
                'Trace' { if ([string]::IsNullOrWhiteSpace($TraceCountText)) { 'оброблено' } else { "оброблено $TraceCountText" } }
                default { [string]$item.OkDetail }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$worst.Details)) {
            [string]$worst.Details
        } else {
            'перевірте журнал'
        }

        # Групування пов'язаних даних в один рядок (окремі рядки погано
        # читалися на мобільних).
        if ([string]$item.Label -eq 'Реставрація' -and -not [string]::IsNullOrWhiteSpace($LastRestoreText)) {
            $detail = "$detail · :arrows_counterclockwise: остання: $LastRestoreText"
        }
        if ([string]$item.Label -eq 'Вільне місце' -and -not [string]::IsNullOrWhiteSpace($FreeSpaceInlineText)) {
            $detail = "$detail · $FreeSpaceInlineText"
        }

        $emoji = [string]$statusEmoji[$status]
        $lines.Add("$emoji $($item.Label) — $detail")
    }

    if (-not [string]::IsNullOrWhiteSpace($ExchangeCountText)) {
        $lines.Add(":white_check_mark: exchangAPI — оброблено $ExchangeCountText")
    }

    # Проблемні етапи, яких НЕМАЄ у списку вище (зупинка/відновлення служб,
    # архівація після maintenance тощо) — щоб жодна причина попередження не
    # лишилась невидимою. Етапи зі списку не дублюються: вони вже показані
    # з ❌/⚠️ і причиною.
    # Hashtable, а не -contains над колекціями: під Set-StrictMode PS 5.1
    # порівняння List/масивів різних типів дає "Argument types do not match".
    $mappedStepNames = @{}
    foreach ($item in $map) {
        foreach ($stepName in @($item.Steps)) { $mappedStepNames[[string]$stepName] = $true }
    }
    $reportedProblemNames = @{}
    for ($logIndex = 0; $logIndex -lt $script:BRAVOMaintenanceStepLog.Count; $logIndex++) {
        $entry = $script:BRAVOMaintenanceStepLog[$logIndex]
        $entryStatus = [string]$entry.Status
        if ($entryStatus -ne 'FAIL' -and $entryStatus -ne 'WARN') { continue }
        $entryName = [string]$entry.Name
        if ($mappedStepNames.ContainsKey($entryName)) { continue }
        if ($reportedProblemNames.ContainsKey($entryName)) { continue }
        $reportedProblemNames[$entryName] = $true
        $entryDetail = if (-not [string]::IsNullOrWhiteSpace([string]$entry.Details)) {
            [string]$entry.Details
        } else {
            'перевірте журнал'
        }
        $problems.Add("$([string]$statusEmoji[$entryStatus]) $entryName — $entryDetail")
    }
    if ($problems.Count -gt 0) {
        # Порожні рядки рендерер сповіщення відкидає, тому заголовок блоку
        # виділяється власним маркером, а не відступом.
        $lines.Add(":mag: Також потребує уваги:")
        foreach ($problem in $problems) { $lines.Add($problem) }
    }
    return $lines.ToArray()
}





function Invoke-NotificationWebhook {
    param(
        [string]$Message,
        [Parameter(Mandatory = $true)][string]$WebhookUrl
    )

    try {
        $outboundMessages = ConvertTo-BRAVONotificationPayloadText -Provider $NotificationProvider -Message $Message
        Send-BRAVONotificationChunks `
            -Provider $NotificationProvider `
            -WebhookUrl $WebhookUrl `
            -MessageChunks $outboundMessages `
            -TimeoutSeconds $NotificationRequestTimeoutSeconds
    } catch {
        $webhookError = $_.Exception.Message
        if ($webhookError -match "SSL/TLS|secure channel|защищенн|захищен") {
            throw "Не вдалося встановити TLS 1.2 з $NotificationProviderDisplayName. " +
                "На Windows $([Environment]::OSVersion.Version) перевірте оновлення Schannel, " +
                ".NET Framework і підтримку сучасних TLS-шифрів. Початкова помилка: $webhookError"
        }
        throw
    }
}

# Функція підготовки повідомлень для вибраного каналу.
function Send-SlackAlert {
    param(
        [string]$Message,
        [switch]$IsCritical,
        # Необов'язковий параметр: NotificationSeverity (маршрутизація —
        # який канал, GENERAL чи ALERTS, і чи гарантована доставка в
        # errors_only) — ОКРЕМЕ поняття від OperationSeverity
        # ($script:criticalErrorOccurred, що керує exit code Maintenance).
        # Якщо -Severity не передано, поведінка ідентична попередній: severity
        # виводиться з -IsCritical/$isSpaceError, як і раніше. -Severity САМА
        # ПО СОБІ ніколи не встановлює $script:criticalErrorOccurred — це
        # й дозволяє гарантувати доставку в ALERTS під errors_only (напр.
        # Send-SlackAlert -Message $x -Severity WARNING, без -IsCritical),
        # не перетворюючи операцію на critical.
        [ValidateSet("SUCCESS", "WARNING", "ERROR", "CRITICAL")]
        [string]$Severity
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

    $effectiveSeverity = if ($Severity) {
        $Severity
    } elseif ($IsCritical -or $isSpaceError) {
        "CRITICAL"
    } else {
        "SUCCESS"
    }

    if ($IsCritical -or $isSpaceError) {
        # OperationSeverity ($script:criticalErrorOccurred) — керується
        # виключно -IsCritical/$isSpaceError, так само як і раніше;
        # -Severity на це НЕ впливає.
        $script:CriticalErrors = $true
        $script:criticalErrorOccurred = $true
    }

    if ($effectiveSeverity -eq "SUCCESS") {
        # 5.2.1: SUCCESS-гілка НЕ надсилає окремих повідомлень — покрокові
        # інформаційні статуси представлені підсумковим Send-FinalReport
        # (один звіт на прогін). Раніше тут стояв $script:SlackMessageBuffer,
        # який лише накопичував повідомлення і НІКОЛИ не читався (мовчазна
        # втрата) — буфер видалено; аудит показав, що 6 із 7 викликів цієї
        # гілки насправді були ERROR-сценаріями і переведені на -IsCritical.
        return
    }

    # WARNING/ERROR/CRITICAL: маршрутизація (GENERAL/ALERTS) — виключно
    # через централізований Resolve-BRAVONotificationRoute. Для викликів
    # без -Severity (effectiveSeverity=CRITICAL, виведений з -IsCritical/
    # $isSpaceError) це функціонально еквівалентно старій перевірці
    # "SlackMode -eq errors_only -or -eq all" (яка тут завжди була true,
    # оскільки mode=none вже вийшов на початку функції). Для нового шляху
    # -Severity WARNING/ERROR (без -IsCritical) це дозволяє гарантовану
    # доставку в ALERTS під errors_only без побічного впливу на
    # OperationSeverity вище.
    $notificationRoute = Resolve-BRAVONotificationRoute `
        -Severity $effectiveSeverity `
        -NotificationMode $script:SlackMode `
        -RoutingTable $bravoSettings.NotificationRouting
    if ($notificationRoute -eq "none") {
        return
    }

    if ($isSpaceError) {
        # Для помилок місця - негайна відправка (незмінно для legacy
        # -IsCritical/дефолтного шляху — effectiveSeverity=CRITICAL, той
        # самий Title/TitleEmoji, що й завжди). Якщо викликач явно передав
        # -Severity (WARNING/ERROR, без -IsCritical) для повідомлення, яке
        # ЗБІГАЄТЬСЯ з space-error регексом — Title/TitleEmoji/-Severity
        # узгоджені з effectiveSeverity, а не жорстко CRITICAL.
        $spaceErrorTitleEmoji = switch ($effectiveSeverity) {
            "WARNING" { ":warning:" }
            "ERROR" { ":x:" }
            default { ":rotating_light:" }
        }
        $spaceErrorTitle = if ($effectiveSeverity -eq "CRITICAL") {
            "КРИТИЧНА ПОМИЛКА ОБСЛУГОВУВАННЯ"
        } else {
            "ПОМИЛКА ОБСЛУГОВУВАННЯ"
        }
        try {
            $outboundMessage = New-MaintenanceNotificationMessage `
                -Title $spaceErrorTitle `
                -TitleEmoji $spaceErrorTitleEmoji `
                -Severity $effectiveSeverity `
                -Duration ((Get-Date) - $script:ScriptStartTime) `
                -Details @($Message) `
                -LogPath $LOG_FILE
            Invoke-NotificationWebhook -Message $outboundMessage -WebhookUrl $script:NotificationWebhookUrls[$notificationRoute]
            Write-Log "Критичне повідомлення (помилки місця) відправлено в $NotificationProviderDisplayName" -Level "INFO"
        }
        catch {
            Write-Log "ПОМИЛКА негайної відправки: $($_.Exception.Message)" -Level "ERROR"
        }
    }
    elseif ($IsCritical) {
        # Фактична execution-critical подія — та сама черга, що й раніше,
        # без жодної зміни (CriticalErrorsList лишається виключно для
        # -IsCritical, review finding #2).
        $script:CriticalErrorsList.Add($Message)
    }
    else {
        # Notification-only WARNING/ERROR (-Severity, без -IsCritical) —
        # окрема черга: NotificationSeverity лишається WARNING/ERROR аж до
        # Send-FinalReport, не "успадковує" CRITICAL-презентацію
        # CriticalErrorsList.
        $script:NotificationAlertQueue.Add([pscustomobject]@{
            Severity = $effectiveSeverity
            Message = $Message
        })
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
            -Severity "WARNING" `
            -Duration ((Get-Date) - $script:ScriptStartTime) `
            -Details @(
                "Служби: $serviceList",
                "Скрипт збереже початковий стан і не запускатиме ці служби автоматично."
            ) `
            -LogPath $LOG_FILE
        $notificationRoute = Resolve-BRAVONotificationRoute `
            -Severity "WARNING" `
            -NotificationMode $script:SlackMode `
            -RoutingTable $bravoSettings.NotificationRouting
        Invoke-NotificationWebhook -Message $notificationMessage -WebhookUrl $script:NotificationWebhookUrls[$notificationRoute]
        Write-Log -Message "Сповіщення про зупинені служби відправлено в $NotificationProviderDisplayName" -Level "SUCCESS"
    } catch {
        Write-Log -Message "Не вдалося відправити сповіщення про зупинені служби: $($_.Exception.Message)" -Level "ERROR"
    }
}

# Bounded-очікування появи файла контролю діапазонів ID після запуску
# служби BRAVO. Служба створює range_id_log.json асинхронно вже після
# старту, тому одразу після Start-Service (особливо перший старт після
# реставрації) файл може ще не існувати — одноразова перевірка давала
# false WARNING. Цикл жорстко обмежений дедлайном (без нескінченних
# циклів); проміжні стани — лише INFO (жодного WARNING звідси: фінальний
# WARNING за таймаутом формує Test-RangeIdUsage нижче, рівно один раз).
# Якщо файл уже існує — повертається одразу, без жодної затримки.
function Wait-BRAVORangeIdLogFile {
    param(
        [string]$Path,
        [int]$TimeoutSeconds,
        [int]$IntervalSeconds = 5
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return $true
    }
    if ($TimeoutSeconds -le 0) {
        return $false
    }

    Write-Log -Message "Файл контролю діапазонів ID ще не створено службою BRAVO; очікування до $TimeoutSeconds сек. (інтервал $IntervalSeconds сек.): $Path" -Level "INFO"
    $waitStartedAt = Get-Date
    $deadline = $waitStartedAt.AddSeconds($TimeoutSeconds)
    $interval = [Math]::Max(1, $IntervalSeconds)
    while ((Get-Date) -lt $deadline) {
        # TimeoutSeconds — справжня верхня межа: кожен sleep обмежується
        # залишком бюджету, інакше останній повний інтервал міг би
        # перевищити дедлайн на величину до IntervalSeconds.
        $remainingSeconds = ($deadline - (Get-Date)).TotalSeconds
        if ($remainingSeconds -le 0) { break }
        $sleepSeconds = [Math]::Min($interval, [Math]::Max(1, [int][Math]::Ceiling($remainingSeconds)))
        Start-Sleep -Seconds $sleepSeconds
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $waitedSeconds = [int][Math]::Ceiling(((Get-Date) - $waitStartedAt).TotalSeconds)
            Write-Log -Message "Файл контролю діапазонів ID з'явився через $waitedSeconds сек. після запуску BRAVO: $Path" -Level "INFO"
            return $true
        }
    }
    return $false
}

# Перевірка заповнення діапазонів ID за даними служби BRAVO
function Test-RangeIdUsage {
    param(
        [string]$Path,
        [double]$ThresholdPercent,
        # > 0 — call-site уже виконав bounded-очікування файла після запуску
        # служби BRAVO (Wait-BRAVORangeIdLogFile) і не дочекався; WARNING
        # тоді пояснює таймаут очікування, а не просто "не знайдено".
        [int]$WaitedForFileSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $missingLabel = if ($WaitedForFileSeconds -gt 0) {
            "Файл контролю діапазонів ID не з'явився протягом $WaitedForFileSeconds сек. після запуску BRAVO"
        } else {
            "Файл контролю діапазонів ID не знайдено"
        }
        $errorMessage = "${missingLabel}: $Path"
        # dev.15: -NoConsole — виклик кроку нижче й так друкує Reason як
        # Details під рядком [N/8] (WARN), тому голий Write-Log у консоль
        # був би тим самим повідомленням удруге. LOG-файл і сповіщення
        # (Send-SlackAlert -IsCritical, errors_only) лишаються незмінними.
        Write-Log $errorMessage -Level "WARNING" -NoConsole
        # Без вихідного файла неможливо підтвердити стан ID-інтервалів.
        # Критичний статус забезпечує сповіщення і в режимі errors_only.
        Send-SlackAlert -Message $errorMessage -IsCritical
        # Details під кроком — два рядки (мітка + шлях окремо), а не один
        # довгий рядок; LOG/Slack і далі отримують односрядковий $errorMessage.
        return [pscustomobject]@{
            HasIssue = $true
            Reason = "${missingLabel}:`n$Path"
        }
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
        $readErrorMessage = "Не вдалося прочитати файл контролю діапазонів ID '$Path': $($readError.Exception.Message)"
        Write-Log $readErrorMessage -Level "WARNING" -NoConsole
        return [pscustomobject]@{ HasIssue = $true; Reason = $readErrorMessage }
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
        return [pscustomobject]@{ HasIssue = $false; Reason = $null }
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

    # Повний перелік діапазонів — у журналі; операторський alert —
    # count + канонічна вибірка прикладів (compact notification).
    $rangeAlertCompactLines = @(
        "Перевищено поріг використання діапазонів ID (${thresholdText}%): $(Format-BRAVOUkrainianCount -Count $exceededRanges.Count -One 'діапазон' -Few 'діапазони' -Many 'діапазонів')."
        ''
    ) + @(Format-BRAVONotificationListSummary `
        -ExampleLines @($alertLines | ForEach-Object { ([string]$_).TrimStart('-', ' ') }) `
        -TotalCount $exceededRanges.Count `
        -RemainderNounOne 'діапазон' -RemainderNounFew 'діапазони' -RemainderNounMany 'діапазонів') + @(
        ''
        "Файл: $sourceFileName"
    )
    if ($rangeData.time) {
        $rangeAlertCompactLines += "Час оновлення даних: $($rangeData.time)"
    }

    Write-Log $message -Level "WARNING" -NoConsole
    Send-SlackAlert -Message ($rangeAlertCompactLines -join "`n") -IsCritical
    $exceededSummary = "перевищено поріг {0}%: {1}" -f $thresholdText, ($exceededRanges.Count)
    return [pscustomobject]@{ HasIssue = $true; Reason = $exceededSummary }
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

# ===== РОТАЦІЯ ПРОГРАМНИХ ЖУРНАЛІВ =====
# Спільний механізм для BRAVO Trace, exchangAPI, Apache і BRAVO Web
# application logs: одна нумерація, одна перевірка результату переміщення,
# один формат журналювання. Раніше кожен компонент мав власну копію циклу
# переміщення — і саме тому вони розійшлися в поведінці: exchangAPI
# перезаписував файл призначення (-Force з тим самим іменем), Trace
# нумерував як _000001, а джерела шукались за здогадками відносно LIMSRoot.
#
# Функції навмисно не читають ані script-scope змінні, ані Write-Log:
# retry-політика й журналювання приходять параметрами. Це те, що робить їх
# перевіряними в BRAVO_SELF_TEST.ps1 на справжніх файлах у тимчасовому
# каталозі, а не лише текстовим пошуком по вихідному коду.

function Write-BRAVOLogRotationMessage {
    param(
        [AllowNull()][scriptblock]$Logger,
        [string]$Message,
        [string]$Level = "INFO"
    )

    if ($null -ne $Logger) {
        # [void] обов'язковий: функції ротації повертають об'єкт-підсумок
        # через конвеєр, тому будь-який вихід журнального адаптера домішався
        # б до результату й перетворив підсумок на масив.
        [void](& $Logger $Message $Level)
    }
}

function Get-BRAVONextLogSequence {
    # MAX(існуючих) + 1, а НЕ перший вільний номер: пропуск у нумерації
    # (файл видалили вручну, каталог частково заархівували) не має
    # перевикористовуватись — інакше новий журнал отримає ім'я, яке в
    # історії вже означало іншу подію, і порядок імен перестане
    # відповідати порядку записів.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [Parameter(Mandatory = $true)][string]$BaseName,
        [string]$Extension = ""
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        return 1
    }

    # Regex.Escape обов'язковий з обох боків: і BaseName ("ssl_error",
    # "exchangAPI"), і Extension (".out") містять символи, які інакше
    # тлумачаться як метасимволи регулярного виразу.
    $sequencePattern = '^' + [regex]::Escape($BaseName) + '_(\d+)' + [regex]::Escape($Extension) + '$'
    $maxSequence = 0
    foreach ($existingFile in @(Get-BRAVOFiles -LiteralPath $DestinationDirectory)) {
        $sequenceMatch = [regex]::Match(
            $existingFile.Name,
            $sequencePattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $sequenceMatch.Success) {
            continue
        }
        $parsedSequence = 0
        # TryParse, а не [int]: номер із занадто довгих цифр (пошкоджене
        # ім'я) не повинен валити ротацію винятком переповнення.
        if (-not [int]::TryParse($sequenceMatch.Groups[1].Value, [ref]$parsedSequence)) {
            continue
        }
        if ($parsedSequence -gt $maxSequence) {
            $maxSequence = $parsedSequence
        }
    }
    return ($maxSequence + 1)
}

function Get-BRAVOFileLockingProcess {
    # Хто саме тримає файл. Windows повідомляє лише "The process cannot access
    # the file because it is being used by another process", не називаючи
    # винуватця — і оператор лишається без єдиного факту, потрібного для
    # рішення. Реальний випадок: невдала реставрація (bravocmd.exe) залишала
    # процес, який тримав TraceSRV.out, і ротація trace падала вже після того,
    # як служби були зупинені.
    #
    # Restart Manager (rstrtmgr.dll) — штатний API Windows саме для цього
    # питання; він лише ЧИТАЄ список і нічого не зупиняє. Функція суто
    # діагностична: будь-яка її помилка не має впливати на результат ротації,
    # тому вона ніколи не кидає виняток і повертає порожній масив, коли
    # визначити тримача не вдалося.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $lockingProcesses = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $lockingProcesses.ToArray()
    }

    try {
        if (-not ('BRAVOFileLockInspector' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class BRAVOFileLockInspector
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    private const int CCH_RM_MAX_APP_NAME = 255;
    private const int CCH_RM_MAX_SVC_NAME = 63;
    private const int ERROR_MORE_DATA = 234;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded,
        ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static List<string> GetHolders(string path)
    {
        List<string> holders = new List<string>();
        uint sessionHandle;
        if (RmStartSession(out sessionHandle, 0, Guid.NewGuid().ToString()) != 0)
        {
            return holders;
        }
        try
        {
            string[] resources = new string[] { path };
            if (RmRegisterResources(sessionHandle, (uint)resources.Length, resources, 0, null, 0, null) != 0)
            {
                return holders;
            }
            uint needed = 0;
            uint count = 0;
            uint reasons = 0;
            int result = RmGetList(sessionHandle, out needed, ref count, null, ref reasons);
            if (result != ERROR_MORE_DATA || needed == 0)
            {
                return holders;
            }
            RM_PROCESS_INFO[] infos = new RM_PROCESS_INFO[needed];
            count = needed;
            if (RmGetList(sessionHandle, out needed, ref count, infos, ref reasons) != 0)
            {
                return holders;
            }
            for (int i = 0; i < count; i++)
            {
                string name = infos[i].strAppName;
                try
                {
                    name = System.Diagnostics.Process.GetProcessById(infos[i].Process.dwProcessId).ProcessName;
                }
                catch
                {
                    // Процес міг завершитися між запитом і уточненням імені —
                    // тоді лишається ім'я, яке повернув Restart Manager.
                }
                string service = infos[i].strServiceShortName;
                if (!string.IsNullOrEmpty(service))
                {
                    holders.Add(name + " (PID " + infos[i].Process.dwProcessId + ", служба " + service + ")");
                }
                else
                {
                    holders.Add(name + " (PID " + infos[i].Process.dwProcessId + ")");
                }
            }
        }
        finally
        {
            RmEndSession(sessionHandle);
        }
        return holders;
    }
}
'@
        }
        foreach ($holder in [BRAVOFileLockInspector]::GetHolders($Path)) {
            if (-not [string]::IsNullOrWhiteSpace($holder)) {
                [void]$lockingProcesses.Add([string]$holder)
            }
        }
    } catch {
        # Restart Manager недоступний, компіляція не вдалася або доступ
        # обмежено. Це лише діагностика — мовчки віддаємо порожній результат,
        # а викликач напише, що тримача визначити не вдалося.
    }

    # .ToArray(), а не @($lockingProcesses): загортання порожнього
    # System.Collections.Generic.List[string]... тут безпечне, але масив
    # робить контракт функції однозначним для викликача під Set-StrictMode.
    return $lockingProcesses.ToArray()
}

function Move-BRAVOLogWithSequence {
    # Переміщення одного журналу в <DestinationDirectory>\<BaseName>_<N><Ext>.
    #
    # LogicalBaseName потрібен для exchangAPI: у джерелі лежать exchangAPI.log,
    # exchangAPI_1.log, exchangAPI_2.log — усі це один логічний журнал, і без
    # явного логічного імені другий із них перетворився б на exchangAPI_1_1.log.
    # Номер джерела ніколи не переноситься в призначення: там діє власна
    # нумерація каталогу-дати.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [string]$LogicalBaseName,
        # Лише для журналу: відносний підкаталог у дереві BRAVO Web, щоб
        # рядок читався як "API\request.log -> API\request_2.log", а не як
        # два однакові "request.log" з різних гілок.
        [string]$RelativeDirectory,
        # Політика імен призначення. 'Sequence' (типово) — історична
        # <Base>_<N><Ext> (exchangAPI/Apache/BravoWeb, семантика незмінна).
        # 'Timestamp' — Trace-модель 5.2.0: <Base>_<yyyyMMdd_HHmmss><Ext>;
        # колізія імені розв'язується наступною вільною секундою (без
        # -Force, без суфіксів _1/_copy).
        [ValidateSet('Sequence', 'Timestamp', 'Original')][string]$NamingPolicy = 'Sequence',
        # Лише для NamingPolicy='Timestamp': момент, з якого формується
        # ім'я. Типово — LastWriteTime джерела («дата даних»: ротований
        # уночі вчорашній trace потрапляє у вчорашній добовий архів, бо
        # дата MDZ визначається з імені ротованого файла).
        [Nullable[datetime]]$TimestampSource,
        [bool]$SkipIfEmpty = $true,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5,
        [AllowNull()][scriptblock]$Logger
    )

    $sourceName = [System.IO.Path]::GetFileName($SourcePath)
    $displayPrefix = if ([string]::IsNullOrWhiteSpace($RelativeDirectory)) {
        ""
    } else {
        ($RelativeDirectory.Trim('\', '/') + '\')
    }
    $attemptsUsed = 0
    $buildResult = {
        param(
            [string]$Status,
            [string]$DestinationName,
            [string]$DestinationPath,
            [int64]$SourceSize,
            [Nullable[int64]]$DestinationSize,
            [Nullable[int]]$Sequence,
            [string]$ErrorText
        )
        [pscustomobject]@{
            Status = $Status
            SourceName = $sourceName
            SourcePath = $SourcePath
            RelativeDirectory = $RelativeDirectory
            DestinationName = $DestinationName
            DestinationPath = $DestinationPath
            SourceSize = $SourceSize
            DestinationSize = $DestinationSize
            Sequence = $Sequence
            Attempts = $attemptsUsed
            Error = $ErrorText
        }
    }

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        return (& $buildResult 'MISSING' $null $null 0 $null $null "файл не знайдено")
    }

    $sourceItem = Get-Item -LiteralPath $SourcePath -ErrorAction SilentlyContinue
    if ($null -eq $sourceItem) {
        return (& $buildResult 'MISSING' $null $null 0 $null $null "файл не знайдено")
    }
    $originalLength = [int64]$sourceItem.Length
    if ($originalLength -eq 0 -and $SkipIfEmpty) {
        # Порожній файл лишається на місці: не переміщується, не видаляється,
        # не перейменовується і не займає номер у послідовності.
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "Файл порожній, ротацію пропущено: $SourcePath" `
            -Level "INFO"
        return (& $buildResult 'SKIPPED_EMPTY' $null $null 0 $null $null $null)
    }

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        try {
            [void](New-Item -Path $DestinationDirectory -ItemType Directory -Force -ErrorAction Stop)
        } catch {
            $createError = "не вдалося створити каталог призначення $DestinationDirectory : $($_.Exception.Message)"
            Write-BRAVOLogRotationMessage -Logger $Logger -Message "ПОМИЛКА: $createError" -Level "ERROR"
            return (& $buildResult 'ERROR' $null $null $originalLength $null $null $createError)
        }
    }

    $extension = [System.IO.Path]::GetExtension($sourceName)
    $baseName = if (-not [string]::IsNullOrWhiteSpace($LogicalBaseName)) {
        $LogicalBaseName
    } else {
        [System.IO.Path]::GetFileNameWithoutExtension($sourceName)
    }

    $attemptLimit = [math]::Max(1, $RetryCount)
    $lastError = $null
    for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
        $attemptsUsed = $attempt
        # Ім'я підбирається безпосередньо перед КОЖНОЮ спробою: між
        # обчисленням MAX+1 і самим Move файл із цим номером міг з'явитися
        # (паралельний запуск, ручне копіювання в каталог). Перезапис
        # існуючого журналу неприпустимий, тому -Force тут немає й не буде:
        # замість нього — новий номер.
        $destinationName = $null
        $destinationPath = $null
        $destinationSequence = $null
        $timestampBase = if ($NamingPolicy -eq 'Timestamp') {
            if ($null -ne $TimestampSource) { $TimestampSource } else { $sourceItem.LastWriteTime }
        } else {
            $null
        }
        if ($NamingPolicy -eq 'Original') {
            # Контракт оператора (exchangAPI): ім'я джерела зберігається ЯК Є,
            # без нумерації і timestamp-суфіксів. Колізія з наявним файлом
            # призначення — ПОМИЛКА (джерело лишається на місці, нічого не
            # перезаписується і не перейменовується) — fail-closed, бо
            # однакове ім'я з різним вмістом означало б втрату журналу.
            $candidateOriginalPath = Join-Path -Path $DestinationDirectory -ChildPath $sourceName
            if (Test-Path -LiteralPath $candidateOriginalPath) {
                $collisionError = "у каталозі призначення вже існує файл з ім'ям $sourceName — оригінальне ім'я зберегти неможливо, джерело залишено на місці"
                Write-BRAVOLogRotationMessage -Logger $Logger -Message "ПОМИЛКА: $collisionError" -Level "ERROR"
                return (& $buildResult 'ERROR' $sourceName $candidateOriginalPath $originalLength $null $null $collisionError)
            }
            $destinationName = $sourceName
            $destinationPath = $candidateOriginalPath
            $destinationSequence = $null
        }
        for ($nameAttempt = 1; ($nameAttempt -le 100) -and ($null -eq $destinationPath); $nameAttempt++) {
            if ($NamingPolicy -eq 'Timestamp') {
                # Колізія (два джерела з тим самим LastWriteTime, повторна
                # ротація в ту саму секунду) — наступна вільна секунда в
                # тому самому форматі; існуючий файл ніколи не перезаписується.
                $candidateStamp = $timestampBase.AddSeconds($nameAttempt - 1)
                $candidateName = '{0}_{1:yyyyMMdd_HHmmss}{2}' -f $baseName, $candidateStamp, $extension
                $candidateSequence = $null
            } else {
                $nextSequence = Get-BRAVONextLogSequence `
                    -DestinationDirectory $DestinationDirectory `
                    -BaseName $baseName `
                    -Extension $extension
                $candidateName = "${baseName}_${nextSequence}${extension}"
                $candidateSequence = [int]$nextSequence
            }
            $candidatePath = Join-Path -Path $DestinationDirectory -ChildPath $candidateName
            if (-not (Test-Path -LiteralPath $candidatePath)) {
                $destinationName = $candidateName
                $destinationPath = $candidatePath
                $destinationSequence = $candidateSequence
                break
            }
        }
        if ($null -eq $destinationPath) {
            $lastError = "не вдалося підібрати вільне ім'я для $sourceName у $DestinationDirectory"
            break
        }

        try {
            Move-Item -LiteralPath $SourcePath -Destination $destinationPath -ErrorAction Stop
            # Перевірка результату (а не лише відсутності винятку): джерело
            # зникло, призначення існує, розмір збігся. Move-Item мовчки
            # "успішний" при частковому переміщенні мережевого файлу — саме
            # тут це виявляється, доки джерело ще можна відновити.
            if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                throw "файл призначення $destinationName не створено"
            }
            if (Test-Path -LiteralPath $SourcePath) {
                throw "джерело $sourceName залишилося на місці після переміщення"
            }
            $movedItem = Get-Item -LiteralPath $destinationPath -ErrorAction Stop
            if ([int64]$movedItem.Length -ne $originalLength) {
                throw "розмір після переміщення ($($movedItem.Length) байт) не збігається з вихідним ($originalLength байт)"
            }
            Write-BRAVOLogRotationMessage `
                -Logger $Logger `
                -Message "Переміщено ${displayPrefix}${sourceName} -> ${displayPrefix}${destinationName}" `
                -Level "SUCCESS"
            return (& $buildResult 'MOVED' $destinationName $destinationPath $originalLength ([int64]$movedItem.Length) $destinationSequence $null)
        } catch {
            $lastError = $_.Exception.Message
            if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
                # Джерела вже немає — повторна спроба нічого не виправить,
                # лише замінить справжню причину на "файл не знайдено".
                break
            }
            if ($attempt -lt $attemptLimit) {
                Write-BRAVOLogRotationMessage `
                    -Logger $Logger `
                    -Message "Не вдалося перемістити ${displayPrefix}${sourceName} ($lastError); спроба $($attempt + 1) з ${attemptLimit} через $RetryDelaySeconds сек." `
                    -Level "WARNING"
                if ($RetryDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $RetryDelaySeconds
                }
            }
        }
    }

    # Тримача файлу з'ясовуємо РІВНО один раз — на фінальній відмові, а не в
    # кожній спробі: запит до Restart Manager коштує часу, а для рішення
    # оператора достатньо одного разу. Перевірка не залежить від тексту
    # системного повідомлення (він локалізований і покладатися на англійський
    # рядок не можна) — тому виконується завжди, поки джерело ще на місці.
    $lockingSuffix = ''
    if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
        $lockingProcesses = @(Get-BRAVOFileLockingProcess -Path $SourcePath)
        $lockingSuffix = if ($lockingProcesses.Count -gt 0) {
            "; файл утримує: $($lockingProcesses -join ', ')"
        } else {
            '; тримача файлу визначити не вдалося'
        }
    }
    Write-BRAVOLogRotationMessage `
        -Logger $Logger `
        -Message "ПОМИЛКА: не вдалося перемістити ${displayPrefix}${sourceName} до $DestinationDirectory після $attemptsUsed спроб: ${lastError}${lockingSuffix}" `
        -Level "ERROR"
    return (& $buildResult 'ERROR' $null $null $originalLength $null $null "${lastError}${lockingSuffix}")
}

function New-BRAVOLogRotationSummary {
    param(
        [string]$ComponentName,
        [int]$Found = 0,
        [int]$NonEmpty = 0,
        [int]$Moved = 0,
        [int]$Empty = 0,
        [int]$Missing = 0,
        [int]$Errors = 0,
        [string]$Note
    )

    [pscustomobject]@{
        ComponentName = $ComponentName
        Found = $Found
        NonEmpty = $NonEmpty
        Moved = $Moved
        Empty = $Empty
        Missing = $Missing
        # Пропущено = порожні + зниклі між discovery і переміщенням. Обидва
        # випадки не є помилкою, але й не є переміщенням — без окремого
        # лічильника "знайдено 5, переміщено 3" читалося б як утрата двох.
        Skipped = ($Empty + $Missing)
        Errors = $Errors
        Note = $Note
    }
}

function Get-BRAVOExchangeApiLogFiles {
    # Історично журнали exchangAPI траплялися під двома шаблонами імен, і
    # жоден із них не є надмножиною іншого в намірі: "exchangAPI_*.log" не
    # ловить поточний exchangAPI.log, а "exchangAPI*.log" писався не всюди.
    # Тому шукаємо за обома й ОБОВ'ЯЗКОВО дедуплікуємо за FullName —
    # exchangAPI_1.log відповідає обом, і без дедуплікації той самий
    # фізичний файл потрапив би в обробку двічі.
    #
    # Пошук лише по безпосередніх файлах каталогу: підкаталоги службі не
    # належать, і рекурсія тут означала б чужі журнали.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string[]]$Patterns = @("exchangAPI_*.log", "exchangAPI*.log")
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }

    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $uniqueFiles = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in @($Patterns)) {
        foreach ($file in @(Get-BRAVOFiles -LiteralPath $Directory -Filter $pattern)) {
            if ($seenPaths.Add([string]$file.FullName)) {
                $uniqueFiles.Add($file)
            }
        }
    }

    return @($uniqueFiles | Sort-Object -Property LastWriteTime, Name)
}

function Test-BRAVOIsTimestampedExchangeApiLogName {
    # exchangAPI (5.2.2): відрізняє вже унікальне джерельне ім'я
    # "<Base>_yyyy-MM-dd_HHmmss.log" (сучасний формат — timestamp сам собою є
    # частиною ідентичності/audit trail файла, той самий формат, що поточна
    # НЕ-legacy ротація exchangAPI зберігає через NamingPolicy='Original')
    # від старих sequence-стильних legacy-імен (exchangAPI.log/exchangAPI_1.log/
    # exchangAPI_2.log), які й далі проходять стару послідовну нумерацію під
    # час одноразової legacy-міграції нижче (Invoke-BRAVOLegacyLogMigration).
    # Виявлено на продакшені: sequence-гілка перейменовувала такі файли в
    # exchangAPI_N.log, знищуючи timestamp безповоротно.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    return [regex]::IsMatch(
        $Name,
        '^exchangAPI_\d{4}-\d{2}-\d{2}_\d{6}\.log$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-BRAVOApacheLogFiles {
    # Тільки журнали. У apache\logs поруч лежать httpd.pid, *.lock і
    # тимчасові файли: переміщення httpd.pid зупиненого Apache — це
    # службовий файл, який httpd очікує знайти на місці після старту.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$Filter = "*.log"
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }
    return @(Get-BRAVOFiles -LiteralPath $Directory -Filter $Filter |
        Sort-Object -Property LastWriteTime, Name)
}

function Get-BRAVOWebApplicationLogFiles {
    # На відміну від Apache, www\log має вкладені каталоги (API\,
    # Integration\API\ тощо), і в різних гілках трапляються файли з
    # однаковим іменем. Тому обхід рекурсивний, а разом із файлом
    # повертається його відносний каталог: сплющування дерева в один
    # каталог-дату склеїло б різні request.log в одну послідовність і
    # знищило б контекст походження.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$Filter = "*.log"
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }

    $rootFullPath = ([string](Get-Item -LiteralPath $Directory).FullName).TrimEnd('\', '/')
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-BRAVOFiles -LiteralPath $Directory -Filter $Filter -Recurse)) {
        $parentPath = ([string](Split-Path -Path $file.FullName -Parent)).TrimEnd('\', '/')
        $relativeDirectory = if ([string]::Equals($parentPath, $rootFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            ""
        } elseif ($parentPath.StartsWith($rootFullPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $parentPath.Substring($rootFullPath.Length + 1)
        } else {
            # Junction/симлінк вивів обхід за межі кореня — такий файл не
            # належить дереву журналів застосунку, і його відносний шлях
            # обчислити чесно неможливо.
            continue
        }
        $items.Add([pscustomobject]@{
            File = $file
            RelativeDirectory = $relativeDirectory
        })
    }

    return @($items | Sort-Object -Property @{ Expression = { $_.RelativeDirectory } }, @{ Expression = { $_.File.LastWriteTime } }, @{ Expression = { $_.File.Name } })
}

function Write-BRAVOLogRotationSummary {
    # Агрегований результат замість мовчазного пропуску (ТЗ §17):
    # оператор бачить усі чотири числа навіть тоді, коли переміщувати не
    # було чого — саме це відрізняє "нічого не знайдено" від "не дійшли".
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [AllowNull()][scriptblock]$Logger
    )

    $level = if ($Summary.Errors -gt 0) {
        "ERROR"
    } elseif ($Summary.Moved -gt 0) {
        "SUCCESS"
    } else {
        "INFO"
    }
    Write-BRAVOLogRotationMessage `
        -Logger $Logger `
        -Message ("{0}: знайдено: {1}, непорожніх: {2}, переміщено: {3}, порожніх: {4}, пропущено: {5}, помилок: {6}" -f `
            $Summary.ComponentName, $Summary.Found, $Summary.NonEmpty, $Summary.Moved,
            $Summary.Empty, $Summary.Skipped, $Summary.Errors) `
        -Level $level
}

function New-BRAVOLogRotationItem {
    # Одиниця роботи рушія ротації: фізичний файл + відносний підкаталог,
    # у який він має лягти всередині каталогу-дати. Для Trace/exchangAPI/
    # Apache відносний підкаталог завжди порожній, для BRAVO Web — шлях
    # усередині www\log.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RelativeDirectory = ""
    )

    [pscustomobject]@{
        Path = $Path
        RelativeDirectory = $RelativeDirectory
    }
}

function Invoke-BRAVOLogRotation {
    # Спільний рушій для всіх чотирьох компонентів. Три-чотири окремі майже
    # однакові функції (як пропонує ТЗ) розійшлися б так само, як розійшлися
    # старі Move-WithSequence/Move-ExchangAPILogs: різниця між компонентами
    # вичерпується списком файлів, логічним іменем і вкладеністю — усе інше
    # (нумерація, перевірка після Move, підсумок) має бути одним кодом.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [string]$LogicalBaseName,
        [ValidateSet('Sequence', 'Timestamp', 'Original')][string]$NamingPolicy = 'Sequence',
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5,
        [AllowNull()][scriptblock]$Logger
    )

    if (@($Items).Count -eq 0) {
        $emptySummary = New-BRAVOLogRotationSummary -ComponentName $ComponentName -Note 'файлів немає'
        Write-BRAVOLogRotationSummary -Summary $emptySummary -Logger $Logger
        return $emptySummary
    }

    $foundCount = 0
    $nonEmptyCount = 0
    $movedCount = 0
    $emptyCount = 0
    $missingCount = 0
    $errorCount = 0
    foreach ($item in @($Items)) {
        $foundCount++
        $relativeDirectory = [string]$item.RelativeDirectory
        # Кожен відносний підкаталог має власну послідовність: request_1.log
        # в API\ і request_1.log в Integration\API\ — різні журнали, і
        # спільна нумерація злила б їх в один ряд.
        $destinationDirectory = if ([string]::IsNullOrWhiteSpace($relativeDirectory)) {
            $DestinationRoot
        } else {
            Join-Path $DestinationRoot $relativeDirectory
        }

        $moveResult = Move-BRAVOLogWithSequence `
            -SourcePath ([string]$item.Path) `
            -DestinationDirectory $destinationDirectory `
            -LogicalBaseName $LogicalBaseName `
            -NamingPolicy $NamingPolicy `
            -RelativeDirectory $relativeDirectory `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -Logger $Logger
        switch ([string]$moveResult.Status) {
            'MOVED' { $nonEmptyCount++; $movedCount++ }
            'SKIPPED_EMPTY' { $emptyCount++ }
            'MISSING' { $missingCount++ }
            default { $nonEmptyCount++; $errorCount++ }
        }
    }

    $summary = New-BRAVOLogRotationSummary `
        -ComponentName $ComponentName `
        -Found $foundCount `
        -NonEmpty $nonEmptyCount `
        -Moved $movedCount `
        -Empty $emptyCount `
        -Missing $missingCount `
        -Errors $errorCount
    Write-BRAVOLogRotationSummary -Summary $summary -Logger $Logger
    return $summary
}

function Invoke-BRAVOTraceRotation {
    # BRAVO Trace — довільний перелік *.out-джерел
    # (Get-BRAVOInstallationTraceOutSources: скан кореня інсталяції +
    # SRV/BIS поза коренем). Імена призначення — Timestamp-політика
    # (<Name>_<yyyyMMdd_HHmmss>.out, ПЛОСКО у Trace\, без каталогів-дат) —
    # далі дата добового Trace_YYYYMMDD.mdz визначається саме з імені
    # ротованого файла.
    # Ані ненаналаштоване, ані відсутнє, ані порожнє джерело не є помилкою
    # обслуговування, і жодне з них не блокує ротацію другого джерела:
    # BRAVO міг просто не писати trace від минулого запуску.
    [CmdletBinding()]
    param(
        # @([pscustomobject]@{ Name='TraceSRV'; Path='...' },
        #   [pscustomobject]@{ Name='TraceBIS'; Path='' })
        # Порожній Path = джерело не налаштовано (INFO, не помилка).
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sources,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5,
        [AllowNull()][scriptblock]$Logger
    )

    $foundCount = 0
    $nonEmptyCount = 0
    $movedCount = 0
    $emptyCount = 0
    $missingCount = 0
    $errorCount = 0
    $notes = @()
    $results = @()
    foreach ($source in @($Sources)) {
        $sourceName = [string]$source.Name
        $sourcePath = [string]$source.Path
        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            Write-BRAVOLogRotationMessage `
                -Logger $Logger `
                -Message "BRAVO Trace: джерело $sourceName не налаштовано — пропущено" `
                -Level "INFO"
            $notes += "$sourceName не налаштовано"
            continue
        }
        $foundCount++
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            Write-BRAVOLogRotationMessage `
                -Logger $Logger `
                -Message "BRAVO Trace: файл $sourcePath ($sourceName) ще не створено — ротація не потрібна" `
                -Level "INFO"
            $missingCount++
            $notes += "$sourceName відсутній"
            continue
        }
        $moveResult = Move-BRAVOLogWithSequence `
            -SourcePath $sourcePath `
            -DestinationDirectory $DestinationDirectory `
            -LogicalBaseName $sourceName `
            -NamingPolicy 'Timestamp' `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -Logger $Logger
        $results += $moveResult
        switch ([string]$moveResult.Status) {
            'MOVED' { $nonEmptyCount++; $movedCount++ }
            'SKIPPED_EMPTY' { $emptyCount++ }
            'MISSING' { $missingCount++ }
            default { $nonEmptyCount++; $errorCount++ }
        }
    }

    $summary = New-BRAVOLogRotationSummary `
        -ComponentName 'Trace' `
        -Found $foundCount `
        -NonEmpty $nonEmptyCount `
        -Moved $movedCount `
        -Empty $emptyCount `
        -Missing $missingCount `
        -Errors $errorCount `
        -Note $(if (@($notes).Count -gt 0) { $notes -join '; ' } else { $null })
    Write-BRAVOLogRotationSummary -Summary $summary -Logger $Logger
    # Move-результати потрібні добовій MDZ-фазі та dry-run; summary-контракт
    # (Slack-рядок «Trace — оброблено N файлів») при цьому незмінний.
    Add-Member -InputObject $summary -MemberType NoteProperty -Name 'Results' -Value @($results) -Force
    return $summary
}

function Invoke-BRAVOExchangeApiLogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [string[]]$Patterns = @("exchangAPI_*.log", "exchangAPI*.log"),
        [string]$LogicalBaseName = "exchangAPI",
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5,
        [AllowNull()][scriptblock]$Logger
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "exchangAPI: робочий каталог $SourceDirectory не знайдено — ротація пропущена" `
            -Level "WARNING"
        return (New-BRAVOLogRotationSummary -ComponentName 'exchangAPI' -Note 'каталог джерела відсутній')
    }

    $sourceFiles = @(Get-BRAVOExchangeApiLogFiles -Directory $SourceDirectory -Patterns $Patterns)
    Write-BRAVOLogRotationMessage `
        -Logger $Logger `
        -Message "exchangAPI: унікальних файлів знайдено: $($sourceFiles.Count)" `
        -Level "INFO"
    # Контракт оператора: імена exchangAPI-логів зберігаються ЯК Є
    # (NamingPolicy 'Original', без exchangAPI_N.log), плоско в каталозі
    # призначення — далі добовий exchangAPI_YYYYMMDD.mdz групує їх за
    # LastWriteTime і після SFTP-верифікації джерела видаляються.
    return (Invoke-BRAVOLogRotation `
        -ComponentName 'exchangAPI' `
        -Items @($sourceFiles | ForEach-Object { New-BRAVOLogRotationItem -Path $_.FullName }) `
        -DestinationRoot $DestinationDirectory `
        -NamingPolicy 'Original' `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -Logger $Logger)
}

function Invoke-BRAVOApacheLogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [string]$Filter = "*.log",
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5,
        [AllowNull()][scriptblock]$Logger
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "Apache: каталог джерела $SourceDirectory не знайдено — ротація пропущена" `
            -Level "WARNING"
        return (New-BRAVOLogRotationSummary -ComponentName 'Apache' -Note 'каталог джерела відсутній')
    }

    $sourceFiles = @(Get-BRAVOApacheLogFiles -Directory $SourceDirectory -Filter $Filter)
    return (Invoke-BRAVOLogRotation `
        -ComponentName 'Apache' `
        -Items @($sourceFiles | ForEach-Object { New-BRAVOLogRotationItem -Path $_.FullName }) `
        -DestinationRoot $DestinationDirectory `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -Logger $Logger)
}

function Invoke-BRAVOWebApplicationLogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [string]$Filter = "*.log",
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5,
        [AllowNull()][scriptblock]$Logger
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "BravoWeb: каталог джерела $SourceDirectory не знайдено — ротація пропущена" `
            -Level "WARNING"
        return (New-BRAVOLogRotationSummary -ComponentName 'BravoWeb' -Note 'каталог джерела відсутній')
    }

    $sourceItems = @(Get-BRAVOWebApplicationLogFiles -Directory $SourceDirectory -Filter $Filter)
    return (Invoke-BRAVOLogRotation `
        -ComponentName 'BravoWeb' `
        -Items @($sourceItems | ForEach-Object {
            New-BRAVOLogRotationItem -Path $_.File.FullName -RelativeDirectory $_.RelativeDirectory
        }) `
        -DestinationRoot $DestinationDirectory `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -Logger $Logger)
}

function Get-BRAVOTraceConfiguration {
    # Runtime-контекст ротації Trace, який має бути відомий ДО зупинки
    # BRAVO (ТЗ §7): сам bravo.ini, значення [Debug] FILE і каталог
    # призначення. Джерело — Resolve-BRAVOInstallationDiscovery, той самий,
    # з якого вже беруться MODEL/BLOG: другого читача bravo.ini в комплекті
    # бути не повинно.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DiscoveryResult,
        [Parameter(Mandatory = $true)][string]$TraceRootDirectory,
        [Parameter(Mandatory = $true)][string]$DateFolderName
    )

    $iniPath = [string]$DiscoveryResult.BravoIniPath
    $tracePath = [string]$DiscoveryResult.TRACE_FILE
    $reason = [string]$DiscoveryResult.Reasons.TRACE_FILE
    $installationDirectory = [string]$DiscoveryResult.BRAVO_ROOT
    $outsideInstallation = [bool]$DiscoveryResult.TRACE_FILE_OUTSIDE_INSTALLATION

    if ([string]::IsNullOrWhiteSpace($tracePath)) {
        return [pscustomobject]@{
            IsValid = $false
            IniPath = $iniPath
            InstallationDirectory = $installationDirectory
            TracePath = $null
            DestinationDirectory = $null
            IsOutsideInstallation = $false
            Reason = $reason
        }
    }

    return [pscustomobject]@{
        IsValid = $true
        IniPath = $iniPath
        InstallationDirectory = $installationDirectory
        TracePath = $tracePath
        DestinationDirectory = (Join-Path $TraceRootDirectory $DateFolderName)
        IsOutsideInstallation = $outsideInstallation
        Reason = $reason
    }
}

# Перелік trace-джерел (*.out) для ротації. За фактичною розкладкою
# інсталяцій bravo.exe пише .out-файли (TraceSRV.out, traceBIS.out і їхні
# варіанти на кшталт TraceSRV2.out, traceBIS1.out, !TraceSRV.out) у корінь
# інсталяції — тому скануються ВСІ *.out цього каталогу (нерекурсивно),
# а не два фіксовані імені. Додатково включаються, якщо лежать ПОЗА
# коренем: SRV-шлях з bravo.ini [Debug] FILE і явний
# maintenanceSettings.Trace.BISSourcePath (порожньо/'off' — нічого
# додаткового: корінь і так покривається скануванням). Ім'я джерела =
# basename без розширення (ротація дасть <basename>_<ts>.out).
function Get-BRAVOInstallationTraceOutSources {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$InstallationRoot,
        [AllowNull()][AllowEmptyString()][string]$LimsRoot,
        [AllowNull()][AllowEmptyString()][string]$SrvTracePath,
        [AllowNull()][AllowEmptyString()][string]$ExplicitBisPath
    )

    $scanRoot = ''
    $scanRootReason = ''
    if (-not [string]::IsNullOrWhiteSpace($InstallationRoot)) {
        $scanRoot = $InstallationRoot
        $scanRootReason = 'корінь інсталяції bravo.exe (Discovery)'
    } elseif (-not [string]::IsNullOrWhiteSpace($LimsRoot)) {
        $scanRoot = $LimsRoot
        $scanRootReason = 'фолбек LIMSRoot: каталог інсталяції bravo.exe невизначений'
    } else {
        $scanRootReason = 'скан неможливий: невизначені і каталог інсталяції bravo.exe, і LIMSRoot'
    }

    $sources = New-Object System.Collections.Generic.List[object]
    $seenPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $seenNames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    $addSource = {
        param([string]$FullPath)
        if ([string]::IsNullOrWhiteSpace($FullPath)) { return }
        if (-not $seenPaths.Add($FullPath)) { return }
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FullPath)
        if ([string]::IsNullOrWhiteSpace($baseName)) { return }
        # Колізія логічних імен (однаковий basename з різних каталогів) —
        # унікалізуємо суфіксом, щоб ротовані <Name>_<ts>.out не змішувались.
        $candidateName = $baseName
        $suffix = 2
        while (-not $seenNames.Add($candidateName)) {
            $candidateName = "${baseName}_$suffix"
            $suffix++
        }
        [void]$sources.Add([pscustomobject]@{ Name = $candidateName; Path = $FullPath })
    }

    if (-not [string]::IsNullOrWhiteSpace($scanRoot) -and
        (Test-Path -LiteralPath $scanRoot -PathType Container)) {
        foreach ($outFile in @(Get-BRAVOFiles -LiteralPath $scanRoot -Filter '*.out' |
                Sort-Object -Property Name)) {
            & $addSource ([string]$outFile.FullName)
        }
    }

    foreach ($extraPath in @($SrvTracePath, $ExplicitBisPath)) {
        if ([string]::IsNullOrWhiteSpace($extraPath)) { continue }
        $trimmedExtra = $extraPath.Trim()
        if ([string]::Equals($trimmedExtra, 'off', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        & $addSource $trimmedExtra
    }

    return [pscustomobject]@{
        ScanRoot = $scanRoot
        ScanRootReason = $scanRootReason
        Sources = @($sources.ToArray())
    }
}

# ===== ДОБОВИЙ TRACE-АРХІВ (Trace_YYYYMMDD.mdz), МОДЕЛЬ 5.2.0 =====
# Ротовані timestamp-файли (TraceSRV_/TraceBIS_<yyyyMMdd>_<HHmmss>.out)
# пакуються в ОДИН накопичувальний архів на календарну дату в тому самому
# запуску Maintenance. Інваріанти: entries, що вже в архіві, — immutable
# (лише ADD нових; ніколи UPDATE/REPLACE/DELETE); попередня валідна
# локальна версія переживає будь-який збій оновлення (транзакційний .work
# + атомарна публікація); джерельні .out видаляються ЛИШЕ після повного
# ланцюга archive+integrity+SFTP+remote-verify (оркестратор нижче).
# Дата визначається З ІМЕНІ ротованого файла, не з CreationTime.

function Get-BRAVOTraceArchiveBacklog {
    # Скан УСІХ дат (backlog після минулих збоїв, не лише сьогодні),
    # oldest -> newest. Плоский перелік каталогу без рекурсії.
    # Два режими групування:
    #   ByName (Trace) — дата з timestamp-імені ротованого файла
    #     (<basename>_<yyyyMMdd>_<HHmmss>.out, basename довільний: скан
    #     усіх *.out кореня інсталяції дає й TraceSRV2, !traceBIS тощо);
    #     legacy (TraceSRV_1.out, каталоги-дати, Trace_YYYY-MM-DD.mdz)
    #     патерном не матчиться і не чіпається.
    #   ByLastWriteTime (exchangAPI) — файли зберігають ОРИГІНАЛЬНІ імена
    #     (контракт оператора: без перейменувань), тому дата групи
    #     береться з LastWriteTime файла.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TraceDirectory,
        [string]$FileNamePattern = '^(.+)_(\d{8})_(\d{6})\.out$',
        [string]$ArchiveNamePrefix = 'Trace',
        [ValidateSet('ByName', 'ByLastWriteTime')][string]$GroupBy = 'ByName',
        [string]$FileFilter = '*.out'
    )

    $groups = @{}
    if (-not (Test-Path -LiteralPath $TraceDirectory -PathType Container)) {
        return @()
    }
    foreach ($file in @(Get-BRAVOFiles -Path $TraceDirectory -Filter $FileFilter)) {
        $dateKey = $null
        if ($GroupBy -eq 'ByName') {
            if ($file.Name -notmatch $FileNamePattern) { continue }
            $dateKey = $matches[2]
            $parsedDate = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($dateKey, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                # Ім'я схоже на нове, але дата неможлива — не створювати
                # сміттєвий <Prefix>_99999999.mdz; файл лишається оператору.
                continue
            }
        } else {
            # ByLastWriteTime: артефакти самого конвеєра (<Prefix>_*.mdz,
            # sidecar, .work) відфільтровує $FileFilter викликача.
            $dateKey = $file.LastWriteTime.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
        }
        if (-not $groups.ContainsKey($dateKey)) {
            $groups[$dateKey] = New-Object System.Collections.Generic.List[object]
        }
        [void]$groups[$dateKey].Add($file)
    }

    $result = @()
    foreach ($dateKey in @($groups.Keys | Sort-Object)) {
        $archiveName = "${ArchiveNamePrefix}_${dateKey}.mdz"
        $archivePath = Join-Path $TraceDirectory $archiveName
        $result += [pscustomobject]@{
            DateKey = $dateKey
            ArchiveName = $archiveName
            ArchivePath = $archivePath
            SidecarPath = "$archivePath.sha512"
            Files = @($groups[$dateKey] | Sort-Object Name)
        }
    }
    return @($result)
}

function Get-BRAVOTraceArchiveUpdatePlan {
    # Класифікація кандидатів ДО формування аргументів 7-Zip — це
    # критичний інваріант: `7za a` мовчки ОНОВЛЮЄ однойменний entry, тому
    # в команду додавання потрапляють ВИКЛЮЧНО NewFiles.
    #   NewFiles       — імені немає в архіві (додати);
    #   DuplicateFiles — ім'я є і Size+CRC збігаються (нормальний слід
    #                    минулого «MDZ OK / SFTP FAIL»: не додавати, лише
    #                    повторити SFTP і потім прибрати джерело);
    #   ConflictFiles  — ім'я є, але контент інший (ПОМИЛКА: archived
    #                    entry недоторканий, локальний файл не видаляється).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'ArchivePassword',
        Justification = 'Пароль передається 7-Zip через redirected stdin (не в аргументи процесу); SecureString довелося б розгортати тут же — той самий контракт, що канонічні 7z-обгортки BRAVO.Compatibility.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$BacklogGroup,
        [Parameter(Mandatory = $true)][string]$SevenZipPath,
        [Parameter(Mandatory = $true)][string]$ArchivePassword,
        [int]$TimeoutSeconds = 3600,
        [AllowNull()][scriptblock]$Logger
    )

    $archiveExists = Test-Path -LiteralPath $BacklogGroup.ArchivePath -PathType Leaf
    $existingEntries = @()
    if ($archiveExists) {
        $inventory = Get-BRAVOSevenZipArchiveEntries `
            -SevenZipPath $SevenZipPath `
            -ArchivePath $BacklogGroup.ArchivePath `
            -Password $ArchivePassword `
            -TimeoutSeconds $TimeoutSeconds
        if (-not $inventory.Success) {
            Write-BRAVOLogRotationMessage -Logger $Logger `
                -Message "ПОМИЛКА: inventory $($BacklogGroup.ArchiveName) не вдався: $($inventory.Error)" -Level "ERROR"
            return [pscustomobject]@{
                ArchiveExists = $true; ExistingEntries = @(); NewFiles = @()
                DuplicateFiles = @(); ConflictFiles = @()
                HasConflicts = $false; InventoryFailed = $true
                Error = [string]$inventory.Error
            }
        }
        $existingEntries = @($inventory.Entries | Where-Object { -not $_.IsDirectory })
    }

    $entriesByName = @{}
    foreach ($entry in $existingEntries) {
        # 7za a з абсолютними шляхами файлів зберігає плоскі імена; про
        # всяк випадок нормалізуємо можливий підкаталог у Path.
        $entriesByName[[System.IO.Path]::GetFileName([string]$entry.Path)] = $entry
    }

    $newFiles = @()
    $duplicateFiles = @()
    $conflictFiles = @()
    foreach ($file in @($BacklogGroup.Files)) {
        if (-not $entriesByName.ContainsKey($file.Name)) {
            $newFiles += $file
            continue
        }
        $entry = $entriesByName[$file.Name]
        if ([int64]$entry.Size -ne [int64]$file.Length) {
            $conflictFiles += [pscustomobject]@{
                File = $file
                Reason = "розмір локального файла ($($file.Length) байт) не збігається з archived entry ($($entry.Size) байт)"
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Crc)) {
            # Legacy/порожній CRC в архіві — порівняння лише за розміром.
            Write-BRAVOLogRotationMessage -Logger $Logger `
                -Message "archived entry $($file.Name) без CRC — звірка лише за розміром" -Level "WARNING"
            $duplicateFiles += $file
            continue
        }
        $localCrc = Get-BRAVOSevenZipFileCrc -SevenZipPath $SevenZipPath -FilePath $file.FullName
        if (-not $localCrc.Success) {
            $conflictFiles += [pscustomobject]@{
                File = $file
                Reason = "не вдалося обчислити локальний CRC: $($localCrc.Error)"
            }
            continue
        }
        if ([string]$localCrc.Crc -ne [string]$entry.Crc) {
            $conflictFiles += [pscustomobject]@{
                File = $file
                Reason = "CRC локального файла ($($localCrc.Crc)) не збігається з archived entry ($($entry.Crc))"
            }
            continue
        }
        $duplicateFiles += $file
    }

    return [pscustomobject]@{
        ArchiveExists = $archiveExists
        ExistingEntries = @($existingEntries)
        NewFiles = @($newFiles)
        DuplicateFiles = @($duplicateFiles)
        ConflictFiles = @($conflictFiles)
        HasConflicts = (@($conflictFiles).Count -gt 0)
        InventoryFailed = $false
        Error = $null
    }
}

function New-BRAVOTraceWorkArchivePath {
    # Транзакційний робочий артефакт у <Trace>\.work — той самий
    # .work\<base>.<guid>.partial<ext> патерн, що в backup-конвеєрі
    # (New-BRAVOTemporaryArchivePath, BRAVO.Archive.Runtime) — Archive
    # Runtime не імпортується Maintenance-ом, тому патерн локально
    # віддзеркалено (~15 рядків; борг консолідації за канонічним власником
    # зафіксовано в CHANGELOG). Розташування всередині Trace\ гарантує той
    # самий том для атомарного [IO.File]::Replace.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TraceDirectory,
        [Parameter(Mandatory = $true)][string]$ArchiveName
    )

    $workDirectory = Join-Path $TraceDirectory '.work'
    if (-not (Test-Path -LiteralPath $workDirectory -PathType Container)) {
        [void](New-Item -Path $workDirectory -ItemType Directory -Force -ErrorAction Stop)
    }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ArchiveName)
    $extension = [System.IO.Path]::GetExtension($ArchiveName)
    $workName = '{0}.{1}.partial{2}' -f $baseName, ([guid]::NewGuid().ToString('N')), $extension
    return [pscustomobject]@{
        WorkDirectory = $workDirectory
        WorkArchivePath = (Join-Path $workDirectory $workName)
    }
}

function Remove-BRAVOTraceWorkArtifacts {
    # Best-effort прибирання work-артефактів після збою або публікації;
    # порожній .work прибирається, непорожній (чужі артефакти) — ні.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorkArchivePath)

    foreach ($artifact in @($WorkArchivePath, "$WorkArchivePath.sha512")) {
        if (Test-Path -LiteralPath $artifact -PathType Leaf) {
            Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
        }
    }
    $workDirectory = Split-Path -Path $WorkArchivePath -Parent
    if ((Test-Path -LiteralPath $workDirectory -PathType Container) -and
        @(Get-BRAVOFiles -Path $workDirectory).Count -eq 0) {
        Remove-Item -LiteralPath $workDirectory -Force -ErrorAction SilentlyContinue
    }
}

function Clear-BRAVOTraceOrphanWorkArtifacts {
    # Cross-run прибирання осиротілих .partial-артефактів (crash посеред
    # минулого оновлення) — аналог orphan sweep backup-конвеєра. Свіжі
    # артефакти не чіпаються (їх може тримати паралельний процес — хоча
    # операційний lock цього й не допускає, поріг лишається захисним).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TraceDirectory,
        [int]$RetentionHours = 48,
        [AllowNull()][scriptblock]$Logger
    )

    $workDirectory = Join-Path $TraceDirectory '.work'
    if (-not (Test-Path -LiteralPath $workDirectory -PathType Container)) { return 0 }
    $cutoff = (Get-Date).AddHours(-[math]::Max(1, $RetentionHours))
    $removed = 0
    foreach ($file in @(Get-BRAVOFiles -Path $workDirectory)) {
        if ($file.Name -notmatch '\.partial\.mdz(\.sha512)?$') { continue }
        if ($file.LastWriteTime -ge $cutoff) { continue }
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $file.FullName)) {
            $removed++
            Write-BRAVOLogRotationMessage -Logger $Logger `
                -Message "Прибрано осиротілий work-артефакт Trace: $($file.Name)" -Level "INFO"
        }
    }
    return $removed
}

function Write-BRAVOTraceArchiveSidecar {
    # Формат sidecar — точний стандарт backup-конвеєра
    # (Write-BRAVOFinalHashFile): "{sha512-lowercase} *{ім'я архіву}",
    # UTF-8 без BOM, без завершального переводу рядка.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$SidecarPath,
        # Ім'я, під яким архів БУДЕ опублікований: під час транзакційного
        # оновлення хеш рахується з .work-копії, але sidecar мусить
        # посилатися на фінальне Trace_YYYYMMDD.mdz, не на .partial-ім'я.
        [string]$ArchiveLeafName
    )

    $hashValue = ([string](Get-BRAVOFileHash -Path $ArchivePath -Algorithm SHA512).Hash).ToLowerInvariant()
    $archiveLeafName = if ([string]::IsNullOrWhiteSpace($ArchiveLeafName)) {
        [System.IO.Path]::GetFileName($ArchivePath)
    } else {
        $ArchiveLeafName
    }
    [System.IO.File]::WriteAllText(
        $SidecarPath,
        "$hashValue *$archiveLeafName",
        (New-Object System.Text.UTF8Encoding($false))
    )
    return $hashValue
}

function Test-BRAVOTraceArchiveSidecarCurrent {
    # true, якщо sidecar існує і відповідає фактичному архіву (ім'я+хеш).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$SidecarPath
    )

    if (-not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) { return $false }
    try {
        $sidecarText = [System.IO.File]::ReadAllText($SidecarPath, [System.Text.Encoding]::UTF8)
    } catch {
        return $false
    }
    if ($sidecarText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') { return $false }
    # $matches фіксується в локальні змінні ОДРАЗУ: наступні виклики
    # (Get-BRAVOFileHash) можуть виконати власний -match і перезаписати його.
    $sidecarHash = [string]$matches.Hash
    $sidecarFileName = [string]$matches.FileName
    if ($sidecarFileName -cne [System.IO.Path]::GetFileName($ArchivePath)) { return $false }
    $actualHash = ([string](Get-BRAVOFileHash -Path $ArchivePath -Algorithm SHA512).Hash).ToLowerInvariant()
    return $sidecarHash.ToLowerInvariant() -eq $actualHash
}

function Update-BRAVOTraceDailyArchive {
    # Транзакційне накопичувальне оновлення ОДНОГО добового архіву:
    #   copy існуючого -> .work partial (перший запуск дати — з нуля)
    #   -> 7za a ЛИШЕ NewFiles -> 7z t -> re-inventory (старі entries
    #   незмінні за Path+Size+CRC, нові присутні) -> SHA512 sidecar
    #   -> атомарна публікація ([IO.File]::Replace / Move-Item).
    # Будь-який збій до публікації лишає попередній валідний архів
    # недоторканим; work-артефакти прибираються.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'ArchivePassword',
        Justification = 'Пароль передається 7-Zip через redirected stdin (не в аргументи процесу); SecureString довелося б розгортати тут же — той самий контракт, що канонічні 7z-обгортки BRAVO.Compatibility.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$BacklogGroup,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$SevenZipPath,
        [Parameter(Mandatory = $true)][string[]]$AddParameters,
        [Parameter(Mandatory = $true)][string]$ArchivePassword,
        [int]$CommandTimeoutSeconds = 14400,
        [int]$IntegrityTimeoutSeconds = 43200,
        [AllowNull()][scriptblock]$Logger
    )

    $buildResult = {
        param([string]$Status, [int]$AddedCount, [string]$ErrorText)
        [pscustomobject]@{
            Status = $Status
            ArchivePath = [string]$BacklogGroup.ArchivePath
            SidecarPath = [string]$BacklogGroup.SidecarPath
            AddedCount = $AddedCount
            Error = $ErrorText
        }
    }

    if ($Plan.InventoryFailed) {
        return (& $buildResult 'FAILED' 0 "inventory існуючого архіву не вдався: $($Plan.Error)")
    }
    if ($Plan.HasConflicts) {
        $conflictText = (@($Plan.ConflictFiles | ForEach-Object { "$($_.File.Name): $($_.Reason)" }) -join '; ')
        return (& $buildResult 'FAILED' 0 "конфлікт імен з archived entries (перезапис заборонено): $conflictText")
    }

    if (@($Plan.NewFiles).Count -eq 0) {
        if ($Plan.ArchiveExists) {
            # Restart-safe: якщо минулий прогін опублікував архів, але впав
            # до/під час запису sidecar — доганяємо sidecar тут.
            if (-not (Test-BRAVOTraceArchiveSidecarCurrent -ArchivePath $BacklogGroup.ArchivePath -SidecarPath $BacklogGroup.SidecarPath)) {
                try {
                    [void](Write-BRAVOTraceArchiveSidecar -ArchivePath $BacklogGroup.ArchivePath -SidecarPath $BacklogGroup.SidecarPath)
                    Write-BRAVOLogRotationMessage -Logger $Logger `
                        -Message "SHA512 sidecar $($BacklogGroup.ArchiveName) регенеровано (був відсутній або застарілий)" -Level "WARNING"
                } catch {
                    return (& $buildResult 'FAILED' 0 "не вдалося регенерувати sidecar: $($_.Exception.Message)")
                }
            }
            return (& $buildResult 'UP_TO_DATE' 0 $null)
        }
        return (& $buildResult 'FAILED' 0 'немає ані нових файлів, ані існуючого архіву — порожня група (внутрішня помилка планування)')
    }

    $work = $null
    try {
        $work = New-BRAVOTraceWorkArchivePath `
            -TraceDirectory (Split-Path -Path $BacklogGroup.ArchivePath -Parent) `
            -ArchiveName $BacklogGroup.ArchiveName
    } catch {
        return (& $buildResult 'FAILED' 0 "не вдалося підготувати робочий каталог .work: $($_.Exception.Message)")
    }
    $workArchivePath = [string]$work.WorkArchivePath

    try {
        if ($Plan.ArchiveExists) {
            $existingItem = Get-Item -LiteralPath $BacklogGroup.ArchivePath -ErrorAction Stop
            Copy-Item -LiteralPath $BacklogGroup.ArchivePath -Destination $workArchivePath -ErrorAction Stop
            $workCopyItem = Get-Item -LiteralPath $workArchivePath -ErrorAction Stop
            if ([int64]$workCopyItem.Length -ne [int64]$existingItem.Length) {
                throw "розмір робочої копії ($($workCopyItem.Length)) не збігається з оригіналом ($($existingItem.Length))"
            }
        }

        # ЛИШЕ NewFiles: existing entry ніколи не потрапляє в команду
        # додавання (див. коментар Get-BRAVOTraceArchiveUpdatePlan).
        # AddParameters НЕ повинні містити -mhe: із шифрованим заголовком
        # `7za a` в існуючий архів запитує пароль ДВІЧІ, і другий запит він
        # читає не з redirected stdin надійно — на UTF-8-хості це давало
        # "Everything is Ok" з фактично биті архівом (характеризація
        # 2026-08-22). Без -mhe запит рівно один: заголовки добових
        # Trace-архівів нешифровані (імена видимі) — як і в усіх backup
        # .mdz продукту; вміст шифрований.
        $addArguments = @($AddParameters) + @($workArchivePath) + @($Plan.NewFiles | ForEach-Object { [string]$_.FullName })
        $addExitCode = Invoke-CommandWithLog `
            -Command $SevenZipPath `
            -Arguments $addArguments `
            -Description "Додавання $(@($Plan.NewFiles).Count) файл(ів) до $($BacklogGroup.ArchiveName)" `
            -TimeoutSeconds $CommandTimeoutSeconds `
            -StandardInputText $ArchivePassword
        if ($addExitCode -ne 0) {
            $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $addExitCode
            throw "7-Zip завершився кодом $addExitCode — $exitDescription"
        }

        $integrityValid = Test-SevenZipArchiveIntegrity `
            -SevenZipPath $SevenZipPath `
            -ArchivePath $workArchivePath `
            -Password $ArchivePassword `
            -TimeoutSeconds $IntegrityTimeoutSeconds `
            -Logger $Logger
        if (-not $integrityValid) {
            throw "оновлений архів не пройшов перевірку цілісності 7-Zip (7z t)"
        }

        # Верифікація immutability: усі старі entries присутні з тими
        # самими Path+Size+CRC; усі нові додано з правильним розміром.
        $verifyInventory = Get-BRAVOSevenZipArchiveEntries `
            -SevenZipPath $SevenZipPath `
            -ArchivePath $workArchivePath `
            -Password $ArchivePassword `
            -TimeoutSeconds $IntegrityTimeoutSeconds
        if (-not $verifyInventory.Success) {
            throw "контрольний inventory оновленого архіву не вдався: $($verifyInventory.Error)"
        }
        $verifiedByName = @{}
        foreach ($entry in @($verifyInventory.Entries | Where-Object { -not $_.IsDirectory })) {
            $verifiedByName[[System.IO.Path]::GetFileName([string]$entry.Path)] = $entry
        }
        foreach ($oldEntry in @($Plan.ExistingEntries)) {
            $oldName = [System.IO.Path]::GetFileName([string]$oldEntry.Path)
            if (-not $verifiedByName.ContainsKey($oldName)) {
                throw "старий entry '$oldName' зник після оновлення — публікацію скасовано"
            }
            $newEntry = $verifiedByName[$oldName]
            if ([int64]$newEntry.Size -ne [int64]$oldEntry.Size -or
                ([string]$newEntry.Crc) -ne ([string]$oldEntry.Crc)) {
                throw "старий entry '$oldName' змінився (Size/CRC) після оновлення — публікацію скасовано"
            }
        }
        foreach ($newFile in @($Plan.NewFiles)) {
            if (-not $verifiedByName.ContainsKey($newFile.Name)) {
                throw "новий файл '$($newFile.Name)' відсутній в оновленому архіві"
            }
            if ([int64]$verifiedByName[$newFile.Name].Size -ne [int64]$newFile.Length) {
                throw "новий entry '$($newFile.Name)' має неочікуваний розмір"
            }
        }

        # Хеш обчислюється з work-копії ДО публікації; вміст після
        # Replace/Move байт-у-байт той самий.
        $publishedHash = Write-BRAVOTraceArchiveSidecar `
            -ArchivePath $workArchivePath `
            -SidecarPath "$workArchivePath.sha512" `
            -ArchiveLeafName $BacklogGroup.ArchiveName

        $statusOnPublish = if ($Plan.ArchiveExists) { 'UPDATED' } else { 'CREATED' }
        if ($Plan.ArchiveExists) {
            try {
                # Атомарна заміна на тому самому томі (.work усередині Trace\).
                [System.IO.File]::Replace($workArchivePath, $BacklogGroup.ArchivePath, $null)
            } catch {
                # Fallback (нетипові FS без підтримки Replace): rename-стратегія;
                # попередня версія тримається як .bak до успішного Move.
                $backupPath = "$($BacklogGroup.ArchivePath).bak_$([guid]::NewGuid().ToString('N'))"
                Move-Item -LiteralPath $BacklogGroup.ArchivePath -Destination $backupPath -ErrorAction Stop
                try {
                    Move-Item -LiteralPath $workArchivePath -Destination $BacklogGroup.ArchivePath -ErrorAction Stop
                } catch {
                    Move-Item -LiteralPath $backupPath -Destination $BacklogGroup.ArchivePath -ErrorAction Stop
                    throw
                }
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            Move-Item -LiteralPath $workArchivePath -Destination $BacklogGroup.ArchivePath -ErrorAction Stop
        }
        # Sidecar публікується ПІСЛЯ архіву; збій тут доганяється
        # sidecar-регенерацією гілки UP_TO_DATE наступного прогону.
        Move-Item -LiteralPath "$workArchivePath.sha512" -Destination $BacklogGroup.SidecarPath -Force -ErrorAction Stop

        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "Добовий архів $($BacklogGroup.ArchiveName): $statusOnPublish, додано $(@($Plan.NewFiles).Count) файл(ів), SHA512 $publishedHash" -Level "SUCCESS"
        return (& $buildResult $statusOnPublish (@($Plan.NewFiles).Count) $null)
    } catch {
        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "ПОМИЛКА: оновлення $($BacklogGroup.ArchiveName) не вдалося: $($_.Exception.Message) — попередня версія архіву недоторкана" -Level "ERROR"
        return (& $buildResult 'FAILED' 0 $_.Exception.Message)
    } finally {
        Remove-BRAVOTraceWorkArtifacts -WorkArchivePath $workArchivePath
    }
}

function Send-BRAVOTraceArchiveFile {
    # Безпечна передача ОДНОГО файла з transactional publication: спочатку
    # ПОВНА передача у <ім'я>.new (Resume=On, .filepart усередині WinSCP),
    # верифікація розміру .new, і лише потім заміна фінального імені —
    # попередня валідна remote-версія не втрачається до підтвердження
    # нової. Duck-typed $Session (PutFiles/FileExists/GetFileInfo/
    # MoveFile/RemoveFiles) — той самий контракт, що BazaSync-двигун і
    # фейк-сесія self-test.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemoteFinalPath,
        [AllowNull()][scriptblock]$Logger
    )

    $localItem = Get-Item -LiteralPath $LocalPath -ErrorAction Stop
    $remoteTempPath = "$RemoteFinalPath.new"
    $transferOptions = New-Object WinSCP.TransferOptions
    $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
    $transferOptions.ResumeSupport.State = [WinSCP.TransferResumeSupportState]::On

    $transferResult = $Session.PutFiles($LocalPath, $remoteTempPath, $false, $transferOptions)
    if (-not $transferResult.IsSuccess) {
        $failureMessages = @(
            $transferResult.Transfers | Where-Object { $null -ne $_.Error } |
                ForEach-Object { [string]$_.Error.Message }
        )
        $detail = if ($failureMessages.Count -gt 0) { $failureMessages -join '; ' } else { 'невідома помилка передачі' }
        return [pscustomobject]@{ Success = $false; RemoteSize = $null; Error = "передача $remoteTempPath не вдалася: $detail" }
    }
    $tempInfo = $Session.GetFileInfo($remoteTempPath)
    if ($null -eq $tempInfo -or [int64]$tempInfo.Length -ne [int64]$localItem.Length) {
        return [pscustomobject]@{ Success = $false; RemoteSize = $null; Error = "remote розмір $remoteTempPath не збігається з локальним ($($localItem.Length) байт) — публікацію скасовано, попередня версія недоторкана" }
    }
    # Стара версія прибирається ЛИШЕ після верифікованого .new: SFTP-rename
    # не перезаписує ціль, тому шлях звільняється явним RemoveFiles.
    if ($Session.FileExists($RemoteFinalPath)) {
        $removeResult = $Session.RemoveFiles($RemoteFinalPath)
        if (-not $removeResult.IsSuccess) {
            return [pscustomobject]@{ Success = $false; RemoteSize = $null; Error = "не вдалося звільнити $RemoteFinalPath для публікації нової версії (верифікований .new залишено)" }
        }
    }
    $Session.MoveFile($remoteTempPath, $RemoteFinalPath)
    $finalInfo = $Session.GetFileInfo($RemoteFinalPath)
    if ($null -eq $finalInfo -or [int64]$finalInfo.Length -ne [int64]$localItem.Length) {
        return [pscustomobject]@{ Success = $false; RemoteSize = $null; Error = "фінальна верифікація $RemoteFinalPath не пройдена після публікації" }
    }
    Write-BRAVOLogRotationMessage -Logger $Logger `
        -Message "SFTP: $RemoteFinalPath опубліковано ($($localItem.Length) байт)" -Level "SUCCESS"
    return [pscustomobject]@{ Success = $true; RemoteSize = [int64]$finalInfo.Length; Error = $null }
}

function Send-BRAVOTraceArchive {
    # Комплект добового архіву: спочатку .mdz, потім .sha512 (sidecar
    # завжди відповідає вже опублікованому архіву; обрив між ними дає
    # застарілий sidecar, який наступний прогін просто перезаллє).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$SidecarPath,
        [Parameter(Mandatory = $true)][string]$RemoteDirectory,
        [AllowNull()][scriptblock]$Logger
    )

    try {
        $normalizedRemoteDirectory = ([string]$RemoteDirectory).Trim().Trim('/').Replace('\', '/')
        $remoteRoot = if ([string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) { '' } else { "/$normalizedRemoteDirectory" }
        $remoteArchivePath = "$remoteRoot/$([System.IO.Path]::GetFileName($ArchivePath))"
        # session.PutFiles НЕ створює відсутні remote-каталоги: реальний
        # DEV-LIMS прогін падав на кожному запуску з "Cannot create remote
        # file '/trace/Trace_YYYYMMDD.mdz.new.filepart'. No such file or
        # directory", бо /trace/ на сервері не існував — і це давало exit 60
        # обслуговування, яке насправді відпрацювало. Канонічний рекурсивний
        # creator уже є в BRAVO.BazaSync (duck-typed по $Session, толерантний
        # до гонки) — використовуємо його, а не другу власну реалізацію.
        # Викликається ОДИН раз на комплект, до обох передач.
        if (-not [string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) {
            New-BRAVOBazaRemoteDirectoryRecursive -Session $Session -RemoteDirectoryPath $normalizedRemoteDirectory
        }
        $archiveResult = Send-BRAVOTraceArchiveFile `
            -Session $Session `
            -LocalPath $ArchivePath `
            -RemoteFinalPath $remoteArchivePath `
            -Logger $Logger
        if (-not $archiveResult.Success) {
            return [pscustomobject]@{ Success = $false; RemoteArchivePath = $remoteArchivePath; RemoteSize = $null; Error = $archiveResult.Error }
        }
        $sidecarResult = Send-BRAVOTraceArchiveFile `
            -Session $Session `
            -LocalPath $SidecarPath `
            -RemoteFinalPath "$remoteRoot/$([System.IO.Path]::GetFileName($SidecarPath))" `
            -Logger $Logger
        if (-not $sidecarResult.Success) {
            return [pscustomobject]@{ Success = $false; RemoteArchivePath = $remoteArchivePath; RemoteSize = $null; Error = "архів опубліковано, але sidecar не передано: $($sidecarResult.Error)" }
        }
        return [pscustomobject]@{ Success = $true; RemoteArchivePath = $remoteArchivePath; RemoteSize = [int64]$archiveResult.RemoteSize; Error = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; RemoteArchivePath = $null; RemoteSize = $null; Error = $_.Exception.Message }
    }
}

function Connect-BRAVOOwnLogSftpSession {
    # Коротко-живуча SFTP-сесія для вивантаження власного логу наприкінці
    # прогону: Trace-сесія відкривається і закривається всередині фази
    # "TRACE: ДОБОВИЙ АРХІВ І SFTP" — задовго до фінального звіту, тому
    # ПОВНИЙ лог через неї передати неможливо. Той самий канонічний
    # bootstrap-ланцюг, що Trace-фаза (Credential Manager ->
    # Resolve-BRAVOSftpHostName -> New-BRAVOSftpUrl -> WinSCP .NET),
    # включно з обов'язковим SshHostKeyFingerprint — жодних послаблень
    # host-key-перевірки. Будь-який провал -> WARNING і $null: вивантаження
    # власного логу — другорядний/телеметричний ефект, ніколи не критичний.
    [CmdletBinding()]
    param()

    $ownLogSession = $null
    try {
        $ownLogLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
        $ownLogPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
        if ([string]::IsNullOrWhiteSpace($ownLogLoginTarget)) { $ownLogLoginTarget = 'BRAVO_SFTP_LOGIN' }
        if ([string]::IsNullOrWhiteSpace($ownLogPasswordTarget)) { $ownLogPasswordTarget = 'BRAVO_SFTP_PASSWORD' }
        $ownLogLogin = Get-BRAVOCredentialSecret -Target $ownLogLoginTarget
        $ownLogPassword = Get-BRAVOCredentialSecret -Target $ownLogPasswordTarget
        if ([string]::IsNullOrWhiteSpace($ownLogLogin) -or [string]::IsNullOrWhiteSpace($ownLogPassword)) {
            throw "записи Credential Manager '$ownLogLoginTarget'/'$ownLogPasswordTarget' недоступні"
        }
        $ownLogLogin = ([string]$ownLogLogin).Trim()
        $ownLogResolvedHost = Resolve-BRAVOSftpHostName `
            -UserName $ownLogLogin `
            -HostTemplate ([string]$sftpHostTemplate) `
            -FallbackHostName $(if ($null -ne (Get-Variable -Name 'sftpHost' -Scope Global -ErrorAction SilentlyContinue)) { [string](Get-Variable -Name 'sftpHost' -Scope Global).Value } else { $null })
        $ownLogSftpUrl = New-BRAVOSftpUrl `
            -HostName $ownLogResolvedHost `
            -Port ([int]$sftpPort) `
            -UserName $ownLogLogin `
            -Password ([string]$ownLogPassword)
        $ownLogPassword = $null
        $ownLogWinScpComponents = Get-BRAVOWinSCPDotNetComponents -WinSCPPath ([string]$winSCPPath)
        if ($null -eq $ownLogWinScpComponents) {
            throw 'WinSCP .NET-компоненти (WinSCPnet.dll + winscp.exe) не знайдено'
        }
        if ($null -eq ('WinSCP.Session' -as [type])) {
            Add-Type -Path $ownLogWinScpComponents.AssemblyPath -ErrorAction Stop
        }
        $ownLogSessionOptions = New-Object WinSCP.SessionOptions
        $ownLogSessionOptions.ParseUrl($ownLogSftpUrl)
        $ownLogSftpUrl = $null
        $ownLogSessionOptions.SshHostKeyFingerprint = ([string]$sftpHostKey).Trim().Trim('"')
        $ownLogSessionOptions.Timeout = [timespan]::FromSeconds([math]::Max(15, [int]$sftpConnectionTimeoutSeconds))
        $ownLogSession = New-Object WinSCP.Session
        $ownLogSession.ExecutablePath = $ownLogWinScpComponents.ExecutablePath
        $ownLogSession.Open($ownLogSessionOptions)
        return $ownLogSession
    } catch {
        if ($null -ne $ownLogSession) {
            try { $ownLogSession.Dispose() } catch {
                # Прибирання після провалу відкриття — початкова помилка
                # (WARNING нижче) важливіша за помилку Dispose.
            }
        }
        Write-Log "Власний лог: SFTP-сесію не відкрито: $($_.Exception.Message)" -Level "WARNING"
        return $null
    }
}

function Send-BRAVOOwnLogFile {
    # Best-effort вивантаження ОДНОГО власного файлу (live-лог прогону,
    # знімок range_id_log.json) на SFTP. Другорядний/телеметричний ефект:
    # провал — лише WARNING, ніколи не встановлює
    # $script:criticalErrorOccurred і не впливає на exit code.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$LocalLogPath,
        [Parameter(Mandatory = $true)][string]$RemoteDirectory,
        # Remote-ім'я за замовчуванням — локальне ім'я файлу; для файлів із
        # константним локальним ім'ям (range_id_log.json) передається
        # унікальне ім'я з run-id, щоб прогони не перезаписували один одного.
        [string]$RemoteFileName,
        [AllowNull()][scriptblock]$Logger
    )
    try {
        if (-not (Test-Path -LiteralPath $LocalLogPath -PathType Leaf)) { return }
        if ([string]::IsNullOrWhiteSpace($RemoteFileName)) {
            $RemoteFileName = [System.IO.Path]::GetFileName($LocalLogPath)
        }
        $normalizedRemoteDirectory = ([string]$RemoteDirectory).Trim().Trim('/').Replace('\', '/')
        $remoteRoot = if ([string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) { '' } else { "/$normalizedRemoteDirectory" }
        if (-not [string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) {
            New-BRAVOBazaRemoteDirectoryRecursive -Session $Session -RemoteDirectoryPath $normalizedRemoteDirectory
        }
        $ownLogResult = Send-BRAVOTraceArchiveFile `
            -Session $Session `
            -LocalPath $LocalLogPath `
            -RemoteFinalPath "$remoteRoot/$RemoteFileName" `
            -Logger $Logger
        if (-not $ownLogResult.Success) {
            Write-Log "Власний лог: передача $LocalLogPath не вдалася: $($ownLogResult.Error)" -Level "WARNING"
        }
    } catch {
        Write-Log "Власний лог: передача $LocalLogPath не вдалася: $($_.Exception.Message)" -Level "WARNING"
    }
}

# Одноразова (idempotent) автоміграція журнальних архівів на SFTP зі
# старого плаского каталогу (типово trace/) у нову структуру logs/
# (типово logs/trace/). Лише remote-move з верифікацією, БЕЗ видалень:
# файл або доведено з'явився в цілі і зник із джерела, або лишається в
# legacy до наступного прогону. Конфлікт імені в цілі — ERROR, нічого не
# перезаписується. Помилки видимі, але не блокують подальші передачі.
function Invoke-BRAVOTraceRemoteLogMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$LegacyDirectory,
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [AllowNull()][scriptblock]$Logger,
        # 5.2.1: рівень колізії імені в цільовому каталозі. 'ERROR' (дефолт,
        # семантика trace-міграції незмінна) рахує колізію в Errors;
        # 'WARNING' (міграція legacy archiv -> model, рішення власника)
        # лишає файл на місці з попередженням, без Errors — колізія там
        # означає, що АКТУАЛЬНІША копія вже в цілі, і це не привід для
        # критичного статусу прогону.
        [ValidateSet('ERROR', 'WARNING')][string]$ConflictLevel = 'ERROR'
    )

    $result = [pscustomobject]@{
        Attempted = 0
        Moved = 0
        Conflicts = 0
        Errors = 0
    }

    $legacyNormalized = ([string]$LegacyDirectory).Trim().Trim('/').Replace('\', '/')
    $targetNormalized = ([string]$TargetDirectory).Trim().Trim('/').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($legacyNormalized) -or
        [string]::IsNullOrWhiteSpace($targetNormalized) -or
        [string]::Equals($legacyNormalized, $targetNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $result
    }
    $legacyRoot = "/$legacyNormalized"
    $targetRoot = "/$targetNormalized"

    try {
        if (-not $Session.FileExists($legacyRoot)) {
            return $result
        }
        $legacyListing = $Session.ListDirectory($legacyRoot)
        $legacyArchiveFiles = @($legacyListing.Files | Where-Object {
            -not $_.IsDirectory -and $_.Name -match '\.mdz(\.sha512)?$'
        })
        if (@($legacyArchiveFiles).Count -eq 0) {
            return $result
        }

        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "Міграція SFTP: $legacyRoot -> $targetRoot — файлів до перенесення: $(@($legacyArchiveFiles).Count)" -Level "INFO"
        New-BRAVOBazaRemoteDirectoryRecursive -Session $Session -RemoteDirectoryPath $targetNormalized

        foreach ($legacyFile in $legacyArchiveFiles) {
            $result.Attempted++
            $sourcePath = "$legacyRoot/$($legacyFile.Name)"
            $targetPath = "$targetRoot/$($legacyFile.Name)"
            try {
                if ($Session.FileExists($targetPath)) {
                    $result.Conflicts++
                    if ($ConflictLevel -eq 'ERROR') {
                        $result.Errors++
                        Write-BRAVOLogRotationMessage -Logger $Logger `
                            -Message "ПОМИЛКА: міграція SFTP — у $targetRoot вже існує $($legacyFile.Name); файл залишено в $legacyRoot (нічого не перезаписано)" -Level "ERROR"
                    } else {
                        Write-BRAVOLogRotationMessage -Logger $Logger `
                            -Message "Міграція SFTP: у $targetRoot вже існує $($legacyFile.Name); файл залишено в $legacyRoot (нічого не перезаписано)" -Level "WARNING"
                    }
                    continue
                }
                $Session.MoveFile($sourcePath, $targetPath)
                if ($Session.FileExists($targetPath) -and -not $Session.FileExists($sourcePath)) {
                    $result.Moved++
                    Write-BRAVOLogRotationMessage -Logger $Logger `
                        -Message "Міграція SFTP: $($legacyFile.Name) -> $targetRoot" -Level "SUCCESS"
                } else {
                    $result.Errors++
                    Write-BRAVOLogRotationMessage -Logger $Logger `
                        -Message "ПОМИЛКА: міграція SFTP — стан $($legacyFile.Name) після MoveFile не підтверджено (ціль: $($Session.FileExists($targetPath)); джерело зникло: $(-not $Session.FileExists($sourcePath)))" -Level "ERROR"
                }
            } catch {
                $result.Errors++
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "ПОМИЛКА: міграція SFTP $($legacyFile.Name): $($_.Exception.Message) — файл залишено в $legacyRoot" -Level "ERROR"
            }
        }
        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "Міграція SFTP завершена: перенесено $($result.Moved) з $($result.Attempted); помилок: $($result.Errors)" `
            -Level $(if ([int]$result.Errors -gt 0) { 'WARNING' } else { 'SUCCESS' })
    } catch {
        $result.Errors++
        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "ПОМИЛКА: міграція SFTP $legacyRoot -> $targetRoot не виконана: $($_.Exception.Message)" -Level "ERROR"
    }
    return $result
}

function Invoke-BRAVOLegacyModelArchiveLocalMigration {
    # Одноразова (idempotent) міграція legacy-розкладки локальних архівів
    # MODEL: старий комплект (ARCHIV_LIMS-ера) писав архіви у
    # <BackupRoot>\ARCHIV\LIMS, поточний — у <BackupRoot>\MODEL. Переносимо
    # вміст пофайлово (той самий принцип, що SFTP-міграція trace/ вище):
    # НІЧОГО не перезаписуємо і не видаляємо — колізія імені лишає старий
    # файл на місці з WARNING (рішення власника 2026-08-26); невдалий
    # перенос (файл залочено) — WARNING, наступний нічний прогін повторить.
    # Порожній legacy-каталог (і його порожній батько ARCHIV) прибираються.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LegacyDirectory,
        [Parameter(Mandatory = $true)][string]$TargetDirectory
    )

    $result = [pscustomobject]@{
        Attempted = 0
        Moved = 0
        Conflicts = 0
        Errors = 0
    }

    try {
        if (-not (Test-Path -LiteralPath $LegacyDirectory -PathType Container)) {
            return $result
        }
        $legacyFiles = @((New-Object System.IO.DirectoryInfo($LegacyDirectory)).EnumerateFiles())
        if (@($legacyFiles).Count -gt 0) {
            Write-Log -Message ("Міграція legacy-архівів MODEL: $LegacyDirectory -> $TargetDirectory — " +
                "файлів до перенесення: $(@($legacyFiles).Count)") -Level "INFO"
            if (-not (Test-Path -LiteralPath $TargetDirectory -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $TargetDirectory -Force -ErrorAction Stop)
            }
            foreach ($legacyFile in $legacyFiles) {
                $result.Attempted++
                $targetPath = Join-Path $TargetDirectory $legacyFile.Name
                try {
                    if (Test-Path -LiteralPath $targetPath) {
                        $result.Conflicts++
                        Write-Log -Message ("Міграція legacy-архівів MODEL: у $TargetDirectory вже існує " +
                            "$($legacyFile.Name); файл залишено в $LegacyDirectory (нічого не перезаписано)") -Level "WARNING"
                        continue
                    }
                    [System.IO.File]::Move($legacyFile.FullName, $targetPath)
                    $result.Moved++
                } catch {
                    $result.Errors++
                    Write-Log -Message ("Міграція legacy-архівів MODEL: не вдалося перенести " +
                        "$($legacyFile.Name): $($_.Exception.Message) — файл залишено, наступний прогін повторить") -Level "WARNING"
                }
            }
            Write-Log -Message ("Міграція legacy-архівів MODEL завершена: перенесено $($result.Moved) з " +
                "$($result.Attempted); колізій: $($result.Conflicts); помилок: $($result.Errors)") `
                -Level $(if ([int]$result.Errors -gt 0 -or [int]$result.Conflicts -gt 0) { 'WARNING' } else { 'INFO' })
        }

        # Прибирання порожніх legacy-каталогів: спершу LIMS, потім батько
        # ARCHIV — лише коли вони СПРАВДІ порожні (жодних файлів і
        # підкаталогів; будь-який залишок робить прибирання неможливим і
        # видимим у лозі вище — нічого не видаляємо рекурсивно).
        $legacyDirectoryInfo = New-Object System.IO.DirectoryInfo($LegacyDirectory)
        if ($legacyDirectoryInfo.Exists -and
            @($legacyDirectoryInfo.EnumerateFileSystemInfos()).Count -eq 0) {
            $legacyDirectoryInfo.Delete()
            Write-Log -Message "Порожній legacy-каталог видалено: $LegacyDirectory" -Level "INFO"
            $legacyParent = $legacyDirectoryInfo.Parent
            if ($null -ne $legacyParent -and $legacyParent.Exists -and
                [string]::Equals($legacyParent.Name, 'ARCHIV', [System.StringComparison]::OrdinalIgnoreCase) -and
                @($legacyParent.EnumerateFileSystemInfos()).Count -eq 0) {
                $legacyParent.Delete()
                Write-Log -Message "Порожній legacy-каталог видалено: $($legacyParent.FullName)" -Level "INFO"
            }
        }
    } catch {
        $result.Errors++
        Write-Log -Message ("Міграція legacy-архівів MODEL не виконана: $($_.Exception.Message) — " +
            "наявні архіви не зачеплено, наступний прогін повторить") -Level "WARNING"
    }
    return $result
}

# ===== P2-7 (PR #136 review): persisted completion state для
# RawSourceGraceDays =====
# Без цього стану КОЖЕН Maintenance-прогін під час grace-вікна знову бачив
# grace-retained джерела в backlog (Get-BRAVOTraceArchiveBacklog сканує
# файли на диску, а не "чи вже опубліковано") -> повторний
# Update-BRAVOTraceDailyArchive + повторний Send-BRAVOTraceArchive
# незмінного архіву щодня, аж до кінця grace-вікна. Той самий
# self-contained підхід (CommonApplicationData\BRAVO\State, атомарний
# temp+File.Replace), що BRAVO_LEGACY_SWEEP_STATE.json вище — окремий файл
# на ComponentLabel (Trace/exchangAPI не діляться станом).
function Get-BRAVOTraceGraceCompletionStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ComponentLabel)

    $programDataRoot = [Environment]::GetFolderPath('CommonApplicationData')
    if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
        throw 'CommonApplicationData недоступний для grace-completion state'
    }
    $safeLabel = ([string]$ComponentLabel) -replace '[^A-Za-z0-9_-]', '_'
    return Join-Path $programDataRoot "BRAVO\State\BRAVO_TRACE_GRACE_COMPLETION_$safeLabel.json"
}

function Read-BRAVOTraceGraceCompletionState {
    # Порожній Hashtable = маркера немає АБО він нечитабельний/пошкоджений/
    # незнайомий schemaVersion. НАВМИСНО протилежний fail-напрям до Legacy
    # Sweep: там corrupt state -> не повторювати (одноразова зручність).
    # Тут corrupt/невідомий state -> ЗАВЖДИ реобробити дату повністю
    # (заново verify+upload) — краще зайва передача незмінного архіву, ніж
    # помилково пропущена реальна зміна джерела/архіву і, як наслідок,
    # видалення джерела, яке насправді розійшлося з опублікованим станом.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { return @{} }
    try {
        $raw = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed.PSObject.Properties['schemaVersion'] -or [int]$parsed.schemaVersion -ne 1) { return @{} }
        if ($null -eq $parsed.PSObject.Properties['entries']) { return @{} }
        $result = @{}
        foreach ($property in $parsed.entries.PSObject.Properties) {
            $result[$property.Name] = $property.Value
        }
        return $result
    } catch {
        return @{}
    }
}

function Write-BRAVOTraceGraceCompletionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Entries
    )

    $stateDirectory = Split-Path -Path $Path -Parent
    if (-not [IO.Directory]::Exists($stateDirectory)) {
        [void][IO.Directory]::CreateDirectory($stateDirectory)
    }
    $state = [ordered]@{
        schemaVersion = 1
        entries = $Entries
    }
    $temporaryStatePath = Join-Path $stateDirectory ('.BRAVO_TRACE_GRACE_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupStatePath = Join-Path $stateDirectory ('.BRAVO_TRACE_GRACE_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $stateReplaced = $false
    try {
        $json = $state | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporaryStatePath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) {
            # .NET Framework відхиляє null-backup у Replace — тому явний шлях.
            [IO.File]::Replace($temporaryStatePath, $Path, $backupStatePath)
            $stateReplaced = $true
        } else {
            [IO.File]::Move($temporaryStatePath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporaryStatePath)) {
            [IO.File]::Delete($temporaryStatePath)
        }
        if ($stateReplaced -and [IO.File]::Exists($backupStatePath)) {
            Remove-Item -LiteralPath $backupStatePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-BRAVOTraceGraceCompletionCurrent {
    # Ідентичність джерела НЕ лише ім'я файлу (вимога review): ім'я + Size +
    # LastWriteTimeUtc порівнюються для КОЖНОГО ще не видаленого джерела в
    # групі, плюс Size і SHA512 самого локального .mdz. Будь-яка
    # розбіжність (з'явився новий файл, розмір/час джерела змінився,
    # локальний архів перезаписано/зник) -> $false -> викликач повторює
    # повну верифікацію+передачу замість помилкового skip.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][array]$CurrentSources
    )

    if ($null -eq $Entry) { return $false }
    foreach ($requiredProperty in @('archiveSize', 'archiveHash', 'publishedNames', 'sources', 'verifiedAtUtc')) {
        if ($null -eq $Entry.PSObject.Properties[$requiredProperty]) { return $false }
    }
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { return $false }

    $storedSources = @($Entry.sources)
    if (@($CurrentSources).Count -ne $storedSources.Count) { return $false }
    for ($i = 0; $i -lt $storedSources.Count; $i++) {
        if ([string]$storedSources[$i].name -ne [string]$CurrentSources[$i].Name -or
            [int64]$storedSources[$i].size -ne [int64]$CurrentSources[$i].Size -or
            [string]$storedSources[$i].lastWriteTimeUtc -ne [string]$CurrentSources[$i].LastWriteTimeUtc) {
            return $false
        }
    }

    try {
        $currentArchiveInfo = Get-Item -LiteralPath $ArchivePath -ErrorAction Stop
        if ([int64]$currentArchiveInfo.Length -ne [int64]$Entry.archiveSize) { return $false }
        $currentHash = (Get-BRAVOFileHash -Path $ArchivePath -Algorithm SHA512).Hash
        if ([string]$currentHash -ne [string]$Entry.archiveHash) { return $false }
    } catch {
        return $false
    }
    return $true
}

function Invoke-BRAVOTraceArchiveMaintenance {
    # Оркестратор фази «добовий Trace-архів»: backlog (усі дати,
    # oldest->newest) -> per-date план -> транзакційний update -> SFTP ->
    # cleanup джерел. Джерельні .out (NewFiles І DuplicateFiles — сліди
    # минулого «MDZ OK / SFTP FAIL») видаляються ЛИШЕ коли для дати
    # одночасно: entry верифіковано в ОПУБЛІКОВАНОМУ архіві, 7z t OK,
    # SFTP Success, remote-верифікація OK. Session=$null (SFTP недоступний/
    # ненаналаштований) — архіви оновлюються, джерела НЕ видаляються,
    # передача відкладається на наступний прогін. Локальний .mdz тут не
    # видаляється НІКОЛИ (лише retention-політика з явним прапорцем).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'ArchivePassword',
        Justification = 'Пароль передається 7-Zip через redirected stdin (не в аргументи процесу); SecureString довелося б розгортати тут же — той самий контракт, що канонічні 7z-обгортки BRAVO.Compatibility.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TraceDirectory,
        [Parameter(Mandatory = $true)][string]$SevenZipPath,
        [Parameter(Mandatory = $true)][string[]]$AddParameters,
        [Parameter(Mandatory = $true)][string]$ArchivePassword,
        [int]$CommandTimeoutSeconds = 14400,
        [int]$IntegrityTimeoutSeconds = 43200,
        [AllowNull()]$Session,
        [string]$RemoteDirectory,
        # Той самий движок обслуговує і Trace (*.out, дата з timestamp-імені),
        # і exchangAPI (*.log з оригінальними іменами, дата з LastWriteTime).
        [string]$ComponentLabel = 'Trace',
        [string]$ArchiveNamePrefix = 'Trace',
        [ValidateSet('ByName', 'ByLastWriteTime')][string]$BacklogGroupBy = 'ByName',
        [string]$BacklogFileFilter = '*.out',
        # P5 (2026-09): grace-період локального зберігання ПОВНІСТЮ
        # верифікованого джерела понад момент його LastWriteTime. 0
        # (дефолт) = точна попередня поведінка — видалення одразу, щойно
        # безпечно (усі 4 умови success виконано), без винятків.
        # Відраховується від LastWriteTime файлу, а не від моменту
        # успішної архівації/вивантаження. Наслідок (задокументоване
        # обмеження, не недолік): якщо SFTP довго був недоступний і
        # накопичилась пачка старих файлів, після відновлення вони
        # видаляться одразу першим успішним циклом — не отримають
        # "свіжий" N-денний grace від моменту вивантаження.
        [int]$RawSourceRetentionDays = 0,
        # P2-7 (PR #136 review): шлях persisted completion-state
        # (Get-BRAVOTraceGraceCompletionStatePath), що дозволяє пропустити
        # повторний Update/Send/inventory-check для дати, яка вже
        # ПІДТВЕРДЖЕНО опублікована і жодне джерело в ній не змінилось.
        # Порожньо/не передано -> та сама поведінка, що й раніше (кожен
        # прогін re-verify, лише $RawSourceRetentionDays керує видаленням).
        [string]$GraceCompletionStatePath,
        [AllowNull()][scriptblock]$Logger
    )

    $result = [pscustomobject]@{
        DatesProcessed = 0
        ArchivesUpdated = 0
        Uploaded = 0
        SourcesDeleted = 0
        SourcesRetainedForGrace = 0
        Conflicts = 0
        Errors = 0
        UploadsDeferred = 0
    }

    [void](Clear-BRAVOTraceOrphanWorkArtifacts -TraceDirectory $TraceDirectory -Logger $Logger)

    # P2-7: grace-completion state читається/пишеться лише коли функція
    # реально в grace-режимі — RawSourceRetentionDays=0 (дефолт) лишає
    # $graceFeatureActive=$false і, відповідно, ЖОДНОГО читання/запису
    # стану чи зміни поведінки порівняно з попередньою версією.
    $graceFeatureActive = $RawSourceRetentionDays -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($GraceCompletionStatePath)
    $graceState = @{}
    $graceStateDirty = $false
    if ($graceFeatureActive) {
        $graceState = Read-BRAVOTraceGraceCompletionState -Path $GraceCompletionStatePath
    }

    $backlog = @(Get-BRAVOTraceArchiveBacklog `
        -TraceDirectory $TraceDirectory `
        -ArchiveNamePrefix $ArchiveNamePrefix `
        -GroupBy $BacklogGroupBy `
        -FileFilter $BacklogFileFilter)
    if (@($backlog).Count -eq 0) {
        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "${ComponentLabel}: ротованих файлів для добової архівації немає" -Level "INFO"
        # Нічого на диску — нічому й лишатись "pending grace" у стані.
        if ($graceFeatureActive -and $graceState.Count -gt 0) {
            try {
                Write-BRAVOTraceGraceCompletionState -Path $GraceCompletionStatePath -Entries @{}
            } catch {
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "${ComponentLabel}: не вдалося очистити grace-completion state: $($_.Exception.Message)" -Level "WARNING"
            }
        }
        return $result
    }

    foreach ($group in $backlog) {
        $result.DatesProcessed++
        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "${ComponentLabel}: дата $($group.DateKey) — файлів у черзі: $(@($group.Files).Count); архів: $($group.ArchiveName)" -Level "INFO"

        $plan = Get-BRAVOTraceArchiveUpdatePlan `
            -BacklogGroup $group `
            -SevenZipPath $SevenZipPath `
            -ArchivePassword $ArchivePassword `
            -TimeoutSeconds $IntegrityTimeoutSeconds `
            -Logger $Logger
        if ($plan.InventoryFailed) {
            $result.Errors++
            continue
        }
        if ($plan.HasConflicts) {
            $result.Conflicts += @($plan.ConflictFiles).Count
            $result.Errors++
            foreach ($conflict in @($plan.ConflictFiles)) {
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "ПОМИЛКА: $ComponentLabel-конфлікт $($conflict.File.Name): $($conflict.Reason) — archived entry і локальний файл недоторкані" -Level "ERROR"
            }
            continue
        }
        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "${ComponentLabel}: вже в архіві: $(@($plan.ExistingEntries).Count); нових: $(@($plan.NewFiles).Count); пропущено вже наявних: $(@($plan.DuplicateFiles).Count)" -Level "INFO"

        # P2-7: кандидати на grace-видалення — той самий набір, що й раніше
        # (NewFiles+DuplicateFiles), лише винесений в окрему змінну: тепер
        # використовується і для перевірки "чи можна пропустити republish",
        # і для самого циклу видалення нижче.
        $graceCandidates = @(@($plan.NewFiles) + @($plan.DuplicateFiles))
        $graceCurrentSnapshot = @($graceCandidates | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Size = [int64]$_.Length
                LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
            }
        } | Sort-Object Name)

        # $plan.NewFiles.Count -eq 0 — немає нічого нового додавати в архів;
        # разом із Test-BRAVOTraceGraceCompletionCurrent (незмінний
        # локальний .mdz за hash+size, той самий набір джерел за
        # ім'я+розмір+LastWriteTimeUtc) це доводить, що повторний
        # Update/Send/inventory-check для цієї дати НІЧОГО нового не дав би
        # порівняно з попереднім підтвердженим прогоном.
        $canSkipRepublish = $false
        $publishedNames = $null
        if ($graceFeatureActive -and $plan.NewFiles.Count -eq 0 -and $graceState.ContainsKey($group.DateKey)) {
            if (Test-BRAVOTraceGraceCompletionCurrent -Entry $graceState[$group.DateKey] -ArchivePath $group.ArchivePath -CurrentSources $graceCurrentSnapshot) {
                $canSkipRepublish = $true
                $publishedNames = @{}
                foreach ($storedName in @($graceState[$group.DateKey].publishedNames)) {
                    $publishedNames[[string]$storedName] = $true
                }
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "${ComponentLabel}: дата $($group.DateKey) — архів і джерела не змінились з попередньої підтвердженої публікації, повторна передача пропущена (grace)" -Level "INFO"
            }
        }

        if (-not $canSkipRepublish) {
            $update = Update-BRAVOTraceDailyArchive `
                -BacklogGroup $group `
                -Plan $plan `
                -SevenZipPath $SevenZipPath `
                -AddParameters $AddParameters `
                -ArchivePassword $ArchivePassword `
                -CommandTimeoutSeconds $CommandTimeoutSeconds `
                -IntegrityTimeoutSeconds $IntegrityTimeoutSeconds `
                -Logger $Logger
            if ([string]$update.Status -eq 'FAILED') {
                $result.Errors++
                continue
            }
            if ([string]$update.Status -in @('CREATED', 'UPDATED')) {
                $result.ArchivesUpdated++
            }

            if ($null -eq $Session) {
                $result.UploadsDeferred++
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "${ComponentLabel}: SFTP-сесія недоступна — передачу $($group.ArchiveName) відкладено; джерельні файли збережено для наступного прогону" -Level "WARNING"
                continue
            }

            $send = Send-BRAVOTraceArchive `
                -Session $Session `
                -ArchivePath $group.ArchivePath `
                -SidecarPath $group.SidecarPath `
                -RemoteDirectory $RemoteDirectory `
                -Logger $Logger
            if (-not $send.Success) {
                $result.Errors++
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "ПОМИЛКА: SFTP-передача $($group.ArchiveName) не вдалася: $($send.Error) — локальний архів і джерельні файли збережено, повтор наступним прогоном" -Level "ERROR"
                continue
            }
            $result.Uploaded++

            # Контрольний inventory ОПУБЛІКОВАНОГО архіву перед видаленням
            # джерел: видаляти можна лише те, що гарантовано в архіві.
            $publishedInventory = Get-BRAVOSevenZipArchiveEntries `
                -SevenZipPath $SevenZipPath `
                -ArchivePath $group.ArchivePath `
                -Password $ArchivePassword `
                -TimeoutSeconds $IntegrityTimeoutSeconds
            if (-not $publishedInventory.Success) {
                $result.Errors++
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "ПОМИЛКА: контрольний inventory $($group.ArchiveName) перед очищенням джерел не вдався: $($publishedInventory.Error) — джерельні файли збережено" -Level "ERROR"
                continue
            }
            $publishedNames = @{}
            foreach ($entry in @($publishedInventory.Entries | Where-Object { -not $_.IsDirectory })) {
                $publishedNames[[System.IO.Path]::GetFileName([string]$entry.Path)] = $true
            }
        }

        $graceRetainedThisGroup = New-Object System.Collections.Generic.List[object]
        foreach ($sourceFile in @($graceCandidates)) {
            if (-not $publishedNames.ContainsKey($sourceFile.Name)) {
                $result.Errors++
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "ПОМИЛКА: $($sourceFile.Name) відсутній в опублікованому архіві — джерело збережено" -Level "ERROR"
                continue
            }
            if ($RawSourceRetentionDays -gt 0 -and
                ((Get-Date) - $sourceFile.LastWriteTime) -lt [timespan]::FromDays($RawSourceRetentionDays)) {
                $result.SourcesRetainedForGrace++
                [void]$graceRetainedThisGroup.Add($sourceFile)
                # Оператору показується фактичний залишок grace-вікна від
                # LastWriteTime, а не повний $RawSourceRetentionDays — файл
                # міг пролежати частину вікна ще до цього прогону.
                $graceRemainingDays = [math]::Ceiling(
                    ([timespan]::FromDays($RawSourceRetentionDays) - ((Get-Date) - $sourceFile.LastWriteTime)).TotalDays
                )
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "${ComponentLabel}: $($sourceFile.Name) верифіковано, але лишено локально ще ~$graceRemainingDays дн. (grace-період $RawSourceRetentionDays дн. від останньої зміни)" -Level "INFO"
                continue
            }
            Remove-Item -LiteralPath $sourceFile.FullName -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $sourceFile.FullName) {
                $result.Errors++
                Write-BRAVOLogRotationMessage -Logger $Logger `
                    -Message "ПОМИЛКА: не вдалося видалити передане джерело $($sourceFile.Name)" -Level "ERROR"
            } else {
                $result.SourcesDeleted++
            }
        }

        # P2-7: після grace-видалення оновлюємо/чистимо completion-state
        # для ЦІЄЇ дати. Порожньо-retained -> нема чого відстежувати далі
        # (видалено остаточно або grace взагалі не застосовувався) —
        # запис прибирається. Ще є retained candidates І щойно пройшла
        # СПРАВЖНЯ (не-skip) верифікація+передача -> фіксуємо свіжий стан;
        # на skip-шляху стан уже актуальний, перезапис не потрібен.
        if ($graceFeatureActive) {
            if ($graceRetainedThisGroup.Count -eq 0) {
                if ($graceState.ContainsKey($group.DateKey)) {
                    $graceState.Remove($group.DateKey)
                    $graceStateDirty = $true
                }
            } elseif (-not $canSkipRepublish) {
                try {
                    $graceArchiveInfo = Get-Item -LiteralPath $group.ArchivePath -ErrorAction Stop
                    $graceArchiveHash = (Get-BRAVOFileHash -Path $group.ArchivePath -Algorithm SHA512).Hash
                    $graceState[$group.DateKey] = @{
                        archiveSize    = [int64]$graceArchiveInfo.Length
                        archiveHash    = [string]$graceArchiveHash
                        publishedNames = @($publishedNames.Keys)
                        sources        = @($graceRetainedThisGroup | ForEach-Object {
                            @{
                                name             = $_.Name
                                size             = [int64]$_.Length
                                lastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
                            }
                        } | Sort-Object { $_.name })
                        verifiedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    $graceStateDirty = $true
                } catch {
                    Write-BRAVOLogRotationMessage -Logger $Logger `
                        -Message "${ComponentLabel}: не вдалося зафіксувати grace-completion state для $($group.DateKey): $($_.Exception.Message) — наступний прогін повторить повну перевірку" -Level "WARNING"
                }
            }
        }

        Write-BRAVOLogRotationMessage -Logger $Logger `
            -Message "${ComponentLabel}: дата $($group.DateKey) завершена — видалено переданих джерел: $($result.SourcesDeleted); локальний MDZ: ЗАЛИШЕНО" -Level "SUCCESS"
    }

    if ($graceFeatureActive -and $graceStateDirty) {
        try {
            Write-BRAVOTraceGraceCompletionState -Path $GraceCompletionStatePath -Entries $graceState
        } catch {
            Write-BRAVOLogRotationMessage -Logger $Logger `
                -Message "${ComponentLabel}: не вдалося зберегти grace-completion state: $($_.Exception.Message)" -Level "WARNING"
        }
    }

    return $result
}


# ===== МІГРАЦІЯ СТАРОЇ СТРУКТУРИ ЖУРНАЛІВ =====
# До переїзду під <ArchiveRoot>\LOGS програмні журнали лежали у трьох
# каталогах кореня ArchiveRoot. Просто перестати туди писати недостатньо:
# накопичена історія (каталоги-дати й .mdz) залишилася б поза retention і
# поза очима оператора — тобто вічно займала б місце й ніколи не знайшлася б
# при розборі інциденту.
#
# Міграція навмисно ідемпотентна й неруйнівна: джерело видаляється лише
# після підтвердженого переміщення, часткова невдача лишає решту для
# наступного запуску, перезапис призначення неможливий у жодному випадку.

function Get-BRAVOLegacyLogMigrationPlan {
    # Пари "старий корінь -> новий корінь". Окремою функцією, щоб і
    # Maintenance, і self-тести бачили один і той самий список, а не дві
    # копії, які згодом розійдуться.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ArchiveRoot, [Parameter(Mandatory = $true)][string]$LogRoot)

    return @(
        [pscustomobject]@{
            ComponentName = 'Trace'
            LegacyPath = (Join-Path $ArchiveRoot 'Trace')
            DestinationPath = (Join-Path $LogRoot 'Trace')
            LogicalBaseName = $null
        },
        [pscustomobject]@{
            ComponentName = 'exchangAPI'
            LegacyPath = (Join-Path $ArchiveRoot 'exchangAPI')
            DestinationPath = (Join-Path $LogRoot 'exchangAPI')
            # У старому каталозі exchangAPI лежали ПЛОСКІ файли з іменами
            # джерела (exchangAPI_1.log). Логічне ім'я потрібне, щоб вони
            # влилися в ту саму послідовність, а не стали exchangAPI_1_1.log.
            LogicalBaseName = 'exchangAPI'
        },
        [pscustomobject]@{
            ComponentName = 'BravoWeb'
            LegacyPath = (Join-Path $ArchiveRoot 'Br-a-vo.web')
            DestinationPath = (Join-Path $LogRoot 'BravoWeb')
            LogicalBaseName = $null
        }
    )
}

function Get-BRAVOFreeMigrationPath {
    # Безконфліктне ім'я для файла, який НЕ є журналом (насамперед .mdz):
    # sequence engine тут не підходить, бо "Trace_2026-07-01.mdz" це не
    # <BaseName>_<N>.<ext>, а дата в імені. Тому — суфікс _migrated_N,
    # який ніколи не збігається з робочим форматом імен.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DestinationPath)

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        return $DestinationPath
    }
    $directory = Split-Path -Path $DestinationPath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($DestinationPath)
    $extension = [System.IO.Path]::GetExtension($DestinationPath)
    for ($suffix = 1; $suffix -le 1000; $suffix++) {
        $candidate = Join-Path $directory ("{0}_migrated_{1}{2}" -f $baseName, $suffix, $extension)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

function Move-BRAVOLegacyLogFile {
    # Один файл legacy -> нове дерево. Повертає $true лише тоді, коли
    # призначення реально існує, джерела вже немає і розміри збіглися:
    # видаляти щось на підставі "Move-Item не кинув винятку" — саме той
    # клас рішень, через який зникають архіви.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [AllowNull()][scriptblock]$Logger
    )

    $sourceItem = Get-Item -LiteralPath $SourcePath -ErrorAction SilentlyContinue
    if ($null -eq $sourceItem) {
        return $false
    }
    $sourceLength = [int64]$sourceItem.Length

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        try {
            [void](New-Item -Path $destinationDirectory -ItemType Directory -Force -ErrorAction Stop)
        } catch {
            Write-BRAVOLogRotationMessage `
                -Logger $Logger `
                -Message "ПОМИЛКА міграції: не вдалося створити каталог $destinationDirectory : $($_.Exception.Message)" `
                -Level "ERROR"
            return $false
        }
    }

    $freePath = Get-BRAVOFreeMigrationPath -DestinationPath $DestinationPath
    if ([string]::IsNullOrWhiteSpace($freePath)) {
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "ПОМИЛКА міграції: не вдалося підібрати вільне ім'я для $SourcePath у $destinationDirectory" `
            -Level "ERROR"
        return $false
    }

    try {
        Move-Item -LiteralPath $SourcePath -Destination $freePath -ErrorAction Stop
    } catch {
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "ПОМИЛКА міграції: $SourcePath -> $freePath : $($_.Exception.Message)" `
            -Level "ERROR"
        return $false
    }

    $movedItem = Get-Item -LiteralPath $freePath -ErrorAction SilentlyContinue
    if ($null -eq $movedItem -or
        (Test-Path -LiteralPath $SourcePath) -or
        [int64]$movedItem.Length -ne $sourceLength) {
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "ПОМИЛКА міграції: результат переміщення $SourcePath не підтверджено (призначення: $freePath)" `
            -Level "ERROR"
        return $false
    }

    Write-BRAVOLogRotationMessage `
        -Logger $Logger `
        -Message "Мігровано: $SourcePath -> $freePath" `
        -Level "SUCCESS"
    return $true
}

function Remove-BRAVOEmptyLegacyDirectory {
    # Порожні каталоги знизу вгору. Каталог із залишками не видаляється
    # НІКОЛИ: те, що не мігрувало, має дочекатися наступного запуску, а не
    # зникнути разом із текою.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][scriptblock]$Logger
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $true
    }
    foreach ($childDirectory in @(Get-BRAVODirectories -Path $Path)) {
        [void](Remove-BRAVOEmptyLegacyDirectory -Path $childDirectory.FullName -Logger $Logger)
    }
    $remaining = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -gt 0) {
        return $false
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    } catch {
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "Не вдалося видалити порожній legacy-каталог ${Path}: $($_.Exception.Message)" `
            -Level "WARNING"
        return $false
    }
}

function Invoke-BRAVOLegacyLogMigration {
    # Один legacy-корінь -> нове дерево.
    #
    # Правила розкладки:
    #   * усе, що лежить у підкаталогах, зберігає відносний шлях —
    #     каталоги-дати переїжджають як є;
    #   * .mdz у корені legacy переїжджає в корінь призначення (там на нього
    #     вже чекає retention стиснутих архівів);
    #   * решта файлів У КОРЕНІ legacy — це плоскі журнали старого формату
    #     (так їх складав колишній exchangAPI-код). Вони отримують каталог-дату
    #     за власним LastWriteTime і проходять через sequence engine, тобто
    #     одразу стають частиною нормального життєвого циклу, а не осідають
    #     назавжди поза межами будь-якої політики. Виняток (5.2.2):
    #     exchangAPI-файли, чиє ім'я вже унікальне (timestamped формат
    #     застосунку, exchangAPI_yyyy-MM-dd_HHmmss.log) — вони зберігають
    #     оригінальне ім'я плоско в корені призначення (Test-BRAVOIsTimestampedExchangeApiLogName),
    #     той самий контракт, що поточна НЕ-legacy ротація exchangAPI.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LegacyPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [string]$LogicalBaseName,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5,
        [AllowNull()][scriptblock]$Logger
    )

    $summary = [pscustomobject]@{
        LegacyPath = $LegacyPath
        DestinationPath = $DestinationPath
        Migrated = 0
        Failed = 0
        LegacyRemoved = $false
        Performed = $false
    }

    if (-not (Test-Path -LiteralPath $LegacyPath -PathType Container)) {
        return $summary
    }

    $legacyFullPath = ([string](Get-Item -LiteralPath $LegacyPath).FullName).TrimEnd('\', '/')
    $destinationFullPath = if (Test-Path -LiteralPath $DestinationPath -PathType Container) {
        ([string](Get-Item -LiteralPath $DestinationPath).FullName).TrimEnd('\', '/')
    } else {
        ([string]$DestinationPath).TrimEnd('\', '/')
    }
    if ([string]::Equals($legacyFullPath, $destinationFullPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $summary
    }

    $legacyFiles = @(Get-BRAVOFiles -LiteralPath $LegacyPath -Recurse -Force)
    if ($legacyFiles.Count -eq 0) {
        # Каталог порожній: лишилася сама тека від попереднього успішного
        # запуску — прибираємо й нічого не рахуємо як міграцію.
        $summary.LegacyRemoved = Remove-BRAVOEmptyLegacyDirectory -Path $LegacyPath -Logger $Logger
        return $summary
    }

    $summary.Performed = $true
    Write-BRAVOLogRotationMessage `
        -Logger $Logger `
        -Message "Міграція старого каталогу журналів: $LegacyPath -> $DestinationPath (файлів: $($legacyFiles.Count))" `
        -Level "INFO"

    $migratedCount = 0
    $failedCount = 0
    foreach ($legacyFile in $legacyFiles) {
        $parentPath = ([string](Split-Path -Path $legacyFile.FullName -Parent)).TrimEnd('\', '/')
        $isAtLegacyRoot = [string]::Equals($parentPath, $legacyFullPath, [StringComparison]::OrdinalIgnoreCase)
        $relativeDirectory = if ($isAtLegacyRoot) {
            ""
        } elseif ($parentPath.StartsWith($legacyFullPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $parentPath.Substring($legacyFullPath.Length + 1)
        } else {
            continue
        }

        $isLooseLogAtRoot = $isAtLegacyRoot -and
            ([string]$legacyFile.Extension) -ine '.mdz'
        if ($isLooseLogAtRoot) {
            # exchangAPI (5.2.2, продакшен-знахідка): джерело вже може мати
            # унікальне timestamped ім'я застосунку (exchangAPI_yyyy-MM-dd_
            # HHmmss.log) — sequence-гілка нижче знищила б timestamp,
            # перейменувавши файл у exchangAPI_N.log. Такі імена зберігаються
            # ЯК Є (NamingPolicy='Original', плоско в корінь призначення —
            # той самий контракт, що вже застосовує поточна НЕ-legacy
            # ротація, Invoke-BRAVOExchangeApiLogRotation). Старі sequence-
            # стильні legacy-імена (exchangAPI.log/exchangAPI_1.log) й далі
            # йдуть через попередню гілку нижче без змін.
            if (([string]$LogicalBaseName) -ieq 'exchangAPI' -and
                (Test-BRAVOIsTimestampedExchangeApiLogName -Name $legacyFile.Name)) {
                $originalMoveResult = Move-BRAVOLogWithSequence `
                    -SourcePath $legacyFile.FullName `
                    -DestinationDirectory $DestinationPath `
                    -NamingPolicy 'Original' `
                    -SkipIfEmpty $false `
                    -RetryCount $RetryCount `
                    -RetryDelaySeconds $RetryDelaySeconds `
                    -Logger $Logger
                if ([string]$originalMoveResult.Status -eq 'MOVED') {
                    $migratedCount++
                } else {
                    $failedCount++
                }
                continue
            }

            $dateFolder = $legacyFile.LastWriteTime.ToString('yyyy-MM-dd')
            $moveResult = Move-BRAVOLogWithSequence `
                -SourcePath $legacyFile.FullName `
                -DestinationDirectory (Join-Path $DestinationPath $dateFolder) `
                -LogicalBaseName $LogicalBaseName `
                -SkipIfEmpty $false `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds `
                -Logger $Logger
            if ([string]$moveResult.Status -eq 'MOVED') {
                $migratedCount++
            } else {
                $failedCount++
            }
            continue
        }

        $targetDirectory = if ([string]::IsNullOrWhiteSpace($relativeDirectory)) {
            $DestinationPath
        } else {
            Join-Path $DestinationPath $relativeDirectory
        }
        if (Move-BRAVOLegacyLogFile `
                -SourcePath $legacyFile.FullName `
                -DestinationPath (Join-Path $targetDirectory $legacyFile.Name) `
                -Logger $Logger) {
            $migratedCount++
        } else {
            $failedCount++
        }
    }

    $summary.Migrated = $migratedCount
    $summary.Failed = $failedCount

    if ($failedCount -eq 0) {
        $summary.LegacyRemoved = Remove-BRAVOEmptyLegacyDirectory -Path $LegacyPath -Logger $Logger
        if ($summary.LegacyRemoved) {
            Write-BRAVOLogRotationMessage `
                -Logger $Logger `
                -Message "Старий каталог видалено після підтвердженої міграції: $LegacyPath (перенесено файлів: $migratedCount)" `
                -Level "SUCCESS"
        } else {
            $migratedCountText = Format-BRAVOUkrainianCount -Count $migratedCount -One "файл" -Few "файли" -Many "файлів"
            Write-BRAVOLogRotationMessage `
                -Logger $Logger `
                -Message "Міграцію завершено ($migratedCountText), але каталог $LegacyPath не порожній — залишено без змін" `
                -Level "WARNING"
        }
    } else {
        Write-BRAVOLogRotationMessage `
            -Logger $Logger `
            -Message "Міграція неповна: перенесено $migratedCount, не вдалося $failedCount; $LegacyPath збережено для наступного запуску" `
            -Level "WARNING"
    }

    return $summary
}

function Remove-BRAVOExpiredCompressedLogs {
    # Retention стиснутих архівів — окрема політика від ArchiveDays.
    # ArchiveDays відповідає на питання "коли пакувати каталог-дату",
    # CompressedLogDays — "коли видаляти вже спакований .mdz". Змішувати їх
    # не можна: перше вимірюється тижнями, друге — місяцями, і спільне
    # число означало б або роздутий диск, або втрату історії.
    #
    # Фільтр строго за очікуваним іменем компонента: узагальнене "*.mdz"
    # у цьому ж дереві зачепило б чужі архіви, які сюди не належать.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ArchiveNamePrefix,
        [Parameter(Mandatory = $true)][int]$RetentionDays,
        [AllowNull()][scriptblock]$Logger
    )

    $result = [pscustomobject]@{
        Deleted = 0
        Failed = 0
        Candidates = 0
    }

    if ($RetentionDays -le 0 -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $result
    }

    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
    # Два формати дат: legacy YYYY-MM-DD (архіви каталогів-дат) і новий
    # компактний YYYYMMDD (добові Trace-архіви моделі 5.2.0) — обидва
    # підпадають під ту саму (явно ввімкнену) політику видалення за віком.
    $archivePattern = '^' + [regex]::Escape($ArchiveNamePrefix) + '_(\d{4}-\d{2}-\d{2}|\d{8})\.mdz$'
    foreach ($archiveFile in @(Get-BRAVOFiles -LiteralPath $Path -Filter "*.mdz")) {
        $archiveMatch = [regex]::Match($archiveFile.Name, $archivePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $archiveMatch.Success) {
            continue
        }
        # Вік визначається за датою В ІМЕНІ архіву, а не за LastWriteTime:
        # час файлу змінює будь-яке копіювання комплекту, а дата в імені —
        # це фактичний період, за який журнали були зібрані.
        [datetime]$archiveDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact(
                $archiveMatch.Groups[1].Value,
                [string[]]@('yyyy-MM-dd', 'yyyyMMdd'),
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$archiveDate)) {
            continue
        }
        $result.Candidates++
        if ($archiveDate -ge $cutoffDate) {
            continue
        }
        try {
            Remove-Item -LiteralPath $archiveFile.FullName -Force -ErrorAction Stop
            $result.Deleted++
            Write-BRAVOLogRotationMessage `
                -Logger $Logger `
                -Message "Видалено стиснутий журнал за retention ($RetentionDays дн.): $($archiveFile.Name)" `
                -Level "SUCCESS"
        } catch {
            $result.Failed++
            Write-BRAVOLogRotationMessage `
                -Logger $Logger `
                -Message "ПОМИЛКА видалення стиснутого журналу $($archiveFile.Name): $($_.Exception.Message)" `
                -Level "ERROR"
        }
    }

    return $result
}
function Resolve-BRAVOExchangeApiRuntimeDirectory {
    # Робочий каталог служби exchangAPI, а не глобальний LIMSRoot: журнали
    # лежать поруч із самим застосунком, і збіг цих двох шляхів — окремий
    # факт конкретної інсталяції, а не правило.
    #
    # Служба може бути обгорнута NSSM: тоді Win32_Service.PathName вказує на
    # nssm.exe (каталог самого NSSM, не застосунку), а справжні шляхи лежать
    # у HKLM\SYSTEM\CurrentControlSet\Services\<Name>\Parameters:
    # AppDirectory (робочий каталог) і Application (виконуваний файл).
    #
    # -ServiceInstance/-NssmParameters дозволяють self-test підставити
    # синтетичні значення замість WMI й реєстру — той самий injectable-
    # патерн, що вже застосований у BRAVO.Discovery (-Services).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [string]$FallbackDirectory,
        [object]$ServiceInstance,
        [hashtable]$NssmParameters
    )

    $buildResult = {
        param([string]$Directory, [string]$Reason)
        [pscustomobject]@{
            Directory = $Directory
            Reason = $Reason
        }
    }

    $servicePathName = $null
    if ($null -ne $ServiceInstance) {
        $servicePathName = [string]$ServiceInstance.PathName
    } else {
        try {
            $wmiService = @(
                Get-BRAVOWmiInstance -ClassName Win32_Service |
                    Where-Object { $_.Name -ieq $ServiceName }
            ) | Select-Object -First 1
            if ($null -ne $wmiService) {
                $servicePathName = [string]$wmiService.PathName
            }
        } catch {
            $servicePathName = $null
        }
    }

    $resolvedNssmParameters = $NssmParameters
    if ($null -eq $resolvedNssmParameters) {
        $resolvedNssmParameters = @{}
        $nssmRegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters"
        try {
            if (Test-Path -LiteralPath $nssmRegistryPath) {
                $nssmProperties = Get-ItemProperty -LiteralPath $nssmRegistryPath -ErrorAction Stop
                foreach ($parameterName in @('Application', 'AppDirectory')) {
                    if ($null -ne $nssmProperties.PSObject.Properties[$parameterName]) {
                        $resolvedNssmParameters[$parameterName] = [string]$nssmProperties.$parameterName
                    }
                }
            }
        } catch {
            # Немає доступу до гілки служби — не привід валити ротацію:
            # нижче лишаються PathName і явний fallback.
            $resolvedNssmParameters = @{}
        }
    }

    $nssmAppDirectory = if ($resolvedNssmParameters.ContainsKey('AppDirectory')) {
        ConvertTo-BRAVOIniPathValue -Value ([string]$resolvedNssmParameters['AppDirectory'])
    } else {
        $null
    }
    if (-not [string]::IsNullOrWhiteSpace($nssmAppDirectory)) {
        return (& $buildResult $nssmAppDirectory.TrimEnd('\', '/') "NSSM AppDirectory служби '$ServiceName'")
    }

    $nssmApplication = if ($resolvedNssmParameters.ContainsKey('Application')) {
        ConvertTo-BRAVOIniPathValue -Value ([string]$resolvedNssmParameters['Application'])
    } else {
        $null
    }
    if (-not [string]::IsNullOrWhiteSpace($nssmApplication)) {
        return (& $buildResult (Split-Path -Path $nssmApplication -Parent) "NSSM Application служби '$ServiceName': $nssmApplication")
    }

    if (-not [string]::IsNullOrWhiteSpace($servicePathName)) {
        $serviceExecutable = Get-BRAVOServiceExecutablePath -PathName $servicePathName
        if (-not [string]::IsNullOrWhiteSpace($serviceExecutable)) {
            return (& $buildResult (Split-Path -Path $serviceExecutable -Parent) "Win32_Service.PathName служби '$ServiceName': $serviceExecutable")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackDirectory)) {
        return (& $buildResult $FallbackDirectory "fallback: LIMSRoot (робочий каталог служби '$ServiceName' не визначено)")
    }
    return (& $buildResult $null "робочий каталог служби '$ServiceName' не визначено")
}

# Функція порівняння розмірів файлів
#
# Повертає структурований результат (не bool), щоб виклик і компактне
# сповіщення могли звітувати кількість без повторного обчислення:
#   HasCriticalChanges   — чи потрібен відкат
#   CriticalFiles         — file-level деталі критичних змін (для логу/алерту)
#   RemovedByRepairFiles  — файли, відсутні після repair, що НЕ є MAIN_MODEL_FILE
#   RemovedByRepairCount  — @() .Count вище (PS 5.1 collection semantics)
#   MainModelValid        — чи основна модель пройшла перевірку
#
# Єдине правило деривації відносного шляху файлу MODEL від кореня.
# Регістронезалежне (OrdinalIgnoreCase): $MODEL_PATH походить із bravo.ini
# і може мати інший регістр (напр. "d:\LIMS\Model"), ніж FullName від
# Get-ChildItem, який FileSystem-провайдер нормалізує ("D:\LIMS\Model\...").
# Ordinal String.Replace на такому розсинхроні мовчки НЕ зрізав корінь,
# ключі порівняння ставали абсолютними шляхами і ВСІ файли before-CSV
# оголошувались відсутніми — хибний CRITICAL + rollback (реальний інцидент
# ДНДІЛДВСЕ 2026-08-25, exit 43). Windows-шляхи регістронезалежні, тому
# OrdinalIgnoreCase тут коректний і не залежить від локалі ОС.
function Get-BRAVOModelRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$RootPath
    )
    $normalizedRoot = $RootPath.TrimEnd('\')
    if ($FullName.StartsWith($normalizedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullName.Substring($normalizedRoot.Length + 1)
    }
    if ([string]::Equals($FullName, $normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ''
    }
    # Шлях поза коренем (нетипово): повертаємо як є — абсолютний шлях
    # діагностично видимий у звітах і, як і раніше, не зіставиться з
    # відносними записами before-CSV (fail-closed).
    return $FullName
}

# -MainModelRelativePath звужує "відсутній файл = CRITICAL" лише до основної
# моделі. Сегментні файли (*.000, *.002, ...), яких bravocmd.exe штатно
# перебудовує/прибирає під час repair, самі по собі більше НЕ є критичними —
# лише RemovedByRepair-діагностикою. Якщо MainModelRelativePath не передано
# (викликач не зміг визначити основну модель), поведінка fail-closed —
# ЛЮБИЙ відсутній файл лишається критичним, як і раніше.
function New-BRAVOCompareFileSizesResult {
    param(
        [bool]$HasCriticalChanges,
        [array]$CriticalFiles = @(),
        [array]$RemovedByRepairFiles = @(),
        [bool]$MainModelValid = $true
    )
    return [PSCustomObject]@{
        HasCriticalChanges = $HasCriticalChanges
        CriticalFiles = @($CriticalFiles)
        RemovedByRepairFiles = @($RemovedByRepairFiles)
        RemovedByRepairCount = @($RemovedByRepairFiles).Count
        MainModelValid = $MainModelValid
    }
}

function Compare-FileSizes {
    param(
        [string]$BeforeFile,
        [string]$ModelPath,
        [int]$MinSizeBytes = 2048,
        [AllowNull()][string]$MainModelRelativePath = $null,
        # Settle-retry (порт 67f3ad3+e2c61e1 з backup/local-developer-rc2-line):
        # двічі підтверджено на реальному DEV-LIMS (2026-08-23/24, byte-точний
        # збіг розмірів на диску одразу після хибного rollback) — активний
        # антивірус із real-time захистом тримав щойно записані гігабайтні
        # .md залоченими одразу після bravocmd repair/екстракції, і
        # enumeration тихо пропускала залоченого кандидата. КАНОНІЧНИЙ фікс —
        # AV-виняток для каталогів LIMS Model/ARCHIV на сервері
        # (Add-MpPreference -ExclusionPath, див. OPERATIONS.md, код 43);
        # цей retry — лише другий рубіж (defense-in-depth) для серверів з
        # іншим/неналаштованим AV. 12×15с = 180с бюджет (розраховано під
        # сканування ~7 ГБ моделі) — мізерний на тлі
        # ExecutionTimeLimitHours=18 задачі Maintenance. Чистий прохід
        # завершується миттєво: retry вмикається ЛИШЕ коли перший прохід
        # знайшов критичні розбіжності. Fail-closed не послаблено: справжня
        # відсутність файлу після всіх спроб лишається критичною.
        # Параметризовано явно заради self-test (короткі значення в
        # детерміністичних сценаріях).
        [int]$MaxSettleAttempts = 12,
        [int]$SettleDelaySeconds = 15
    )

    try {
        if (-not (Test-Path $BeforeFile)) {
            Write-Log "Файл з початковими розмірами не знайдено: $BeforeFile" -Level "ERROR"
            $script:criticalErrorOccurred = $true
            $script:restoreIntegrityFailed = $true
            return New-BRAVOCompareFileSizesResult -HasCriticalChanges $true -MainModelValid $false
        }

        $initialData = @(Import-Csv -Path $BeforeFile)
        if ($initialData.Count -eq 0) {
            Write-Log "Початковий список файлів MODEL порожній; цілісність після реставрації неможливо підтвердити" -Level "ERROR"
            $script:criticalErrorOccurred = $true
            $script:restoreIntegrityFailed = $true
            return New-BRAVOCompareFileSizesResult -HasCriticalChanges $true -MainModelValid $false
        }

        # Fail-closed guard: hint передано, але його немає у before-CSV —
        # деривацію головної моделі не можна вважати достовірною (нетипове
        # MODEL= у bravo.ini, Hidden/System-атрибути на .md, розбіжність
        # шляхів). Мовчазне продовження перетворило б УСІ зниклі файли на
        # RemovedByRepair і пропустило б знищену модель без rollback.
        # Повертаємось до строгого legacy-режиму: будь-який відсутній файл
        # знову критичний.
        if (-not [string]::IsNullOrWhiteSpace($MainModelRelativePath)) {
            $hintFoundInInitial = $false
            foreach ($item in $initialData) {
                if ([string]$item.RelativePath -ieq $MainModelRelativePath) {
                    $hintFoundInInitial = $true
                    break
                }
            }
            if (-not $hintFoundInInitial) {
                Write-Log ("Головну модель '$MainModelRelativePath' не знайдено у початковій інвентаризації MODEL " +
                    "($(@($initialData).Count) файл(ів) у $BeforeFile); активовано строгий режим перевірки: " +
                    "будь-який відсутній файл вважається критичним") -Level "WARNING"
                $MainModelRelativePath = $null
            }
        }

        $criticalFiles = @()
        $removedByRepairFiles = @()
        $mainModelValid = $true
        $missingFileCount = 0
        $currentLookup = @{}
        for ($settleAttempt = 1; $settleAttempt -le $MaxSettleAttempts; $settleAttempt++) {
        # Кожна ітерація починається з чистого стану — включно з
        # $missingFileCount, який живить tripwire ПІСЛЯ циклу: накопичення
        # між спробами дало б хибний ERROR про розсинхрон шляхів.
        $criticalFiles = @()
        $removedByRepairFiles = @()
        $mainModelValid = $true
        $missingFileCount = 0
        $currentLookup = @{}
        # Пряма .NET enumeration замість Get-BRAVOFiles/Get-ChildItem -Recurse
        # (порт f7f6628): PowerShell-провайдер на великих/глибоких деревах з
        # -ErrorAction SilentlyContinue мовчки повертав НЕПОВНИЙ список —
        # реальний детермінований інцидент ДНДІЛДВСЕ 2026-08-24 (~364 «зниклі»
        # файли 4/4 рази, незалежно від settle-вікна, дані фізично цілі).
        # Той самий канонічний механізм, що вже використовують дві інші
        # enumeration-точки цього flow (Check-MdFileSizes і before-CSV
        # snapshot); Hidden/System-фільтр відтворює поведінку Get-ChildItem
        # без -Force, щоб набір файлів не змінився.
        $modelDirectoryInfo = New-Object System.IO.DirectoryInfo($ModelPath)
        foreach ($file in $modelDirectoryInfo.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)) {
            if (($file.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) -ne 0) {
                continue
            }
            $relativePath = Get-BRAVOModelRelativePath -FullName $file.FullName -RootPath $ModelPath
            $currentLookup[$relativePath] = [long]$file.Length
        }

        # Каталог MODEL повністю порожній після repair — критично незалежно
        # від того, що показує посегментне порівняння нижче (defense-in-depth
        # для випадку, коли before-CSV сам по собі валідний, але repair
        # знищив усе). Порожній каталог не самозцілюється — retry тут
        # зайвий, fail-closed негайно.
        if ($currentLookup.Count -eq 0) {
            $errorMsg = "Каталог MODEL порожній після реставрації: $ModelPath"
            Write-Log $errorMsg -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
            $script:restoreIntegrityFailed = $true
            return New-BRAVOCompareFileSizesResult -HasCriticalChanges $true -MainModelValid $false
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
            if ($isMissing) { $missingFileCount++ }
            $isMainModelFile = (
                -not [string]::IsNullOrWhiteSpace($MainModelRelativePath) -and
                $relativePath -ieq $MainModelRelativePath
            )
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
            # Fail-closed: без відомого MainModelRelativePath (викликач не
            # зміг визначити основну модель) будь-який відсутній файл лишається
            # критичним — стара поведінка. З відомим MainModelRelativePath
            # не критичним є зникнення ЛИШЕ транзитних артефактів bravocmd:
            #   *.NNN (тризначне розширення) — сегментні файли, які repair
            #     (mdrepair/db_remove/db_commit) штатно перебудовує;
            #   *.$$$ — тимчасові робочі файли bravocmd (пише перебудоване,
            #     потім перейменовує/видаляє). Їх наявність = залишок
            #     перерваного repair, а не дані; зникнення НЕ критичне.
            # .md (зокрема lims0.md/lims1.md — продовження основної моделі — чи
            # табличні DEPART.md), файли ієрархії (.h1/.h2) та будь-що інше при
            # зникненні — критична втрата даних, rollback-тригер.
            $isTransientRepairArtifact = $relativePath -match '(\.\d{3}$)|(\.\$\$\$$)'
            $isCriticalMissing = $isMissing -and (
                $isMainModelFile -or
                [string]::IsNullOrWhiteSpace($MainModelRelativePath) -or
                -not $isTransientRepairArtifact
            )

            if ($isMissing -and -not $isCriticalMissing) {
                $removedByRepairFiles += [PSCustomObject]@{
                    File = $relativePath
                    BeforeSizeBytes = $initialSizeBytes
                }
                continue
            }

            if ($isCriticalMissing -or $isCriticalReduction) {
                if ($isMainModelFile) {
                    $mainModelValid = $false
                }
                $criticalFiles += [PSCustomObject]@{
                    File = $relativePath
                    BeforeSizeBytes = $initialSizeBytes
                    AfterSizeBytes = $currentSizeBytes
                    Missing = $isMissing
                }
            }
        }

        # Чистий прохід — миттєвий вихід без жодної затримки; retry лише
        # коли знайдено критичні розбіжності (можливий AV-рейс видимості
        # щойно записаних файлів, див. коментар у param-блоці).
        if (@($criticalFiles).Count -eq 0 -or $settleAttempt -ge $MaxSettleAttempts) {
            break
        }
        Write-Log ("Знайдено $(@($criticalFiles).Count) критичних розбіжностей MODEL (спроба $settleAttempt з $MaxSettleAttempts); " +
            "можлива затримка видимості щойно записаних файлів (антивірус/кеш) — повторна перевірка через $SettleDelaySeconds с...") -Level "WARNING"
        Start-Sleep -Seconds $SettleDelaySeconds
        }

        # Діагностичний tripwire: каталог MODEL не порожній, але ЖОДЕН запис
        # before-CSV не зіставився з поточним вмістом. Реальна тотальна втрата
        # так не виглядає (тоді каталог порожній — окремий guard вище);
        # найімовірніша причина — розсинхрон деривації шляхів (корінь/регістр)
        # між writer-ом CSV і цим порівнянням. Поведінка НЕ послаблюється
        # (critical -> rollback лишається), лише правильна підказка оператору.
        if ($missingFileCount -eq @($initialData).Count -and $currentLookup.Count -gt 0) {
            Write-Log ("ЖОДЕН із $missingFileCount файлів before-CSV не знайдений у поточному вмісті MODEL, " +
                "хоча каталог містить $($currentLookup.Count) файл(ів). Це схоже не на втрату даних, а на " +
                "розсинхрон деривації відносних шляхів (корінь/регістр MODEL між before-CSV і порівнянням). " +
                "Перевірте значення MODEL= у bravo.ini і фактичний шлях каталогу.") -Level "ERROR"
        }

        if (@($removedByRepairFiles).Count -gt 0) {
            $removedSummary = "Repair видалив/перебудував $(@($removedByRepairFiles).Count) файл(ів) MODEL (не основна модель, критичним НЕ вважається):`n"
            foreach ($file in $removedByRepairFiles) {
                $removedSummary += " - $($file.File) (було: $(Format-FileSize $file.BeforeSizeBytes))`n"
            }
            Write-Log $removedSummary -Level "INFO"
        }

        if ($criticalFiles.Count -gt 0) {
            # Розділені представлення (compact notification):
            #   DetailedDiagnostic (4 рядки/файл, УСІ файли) -> Write-Log —
            #     авторитетна повна діагностика лишається в
            #     BRAVO_MAINTENANCE_*.log без жодних скорочень;
            #   OperatorSummary (count + до N прикладів + «…і ще N») ->
            #     Send-SlackAlert — операторський alert не повинен нести
            #     сотні рядків і перетворювати транспорт на переглядач
            #     журналу (реальний інцидент: 364 файли ≈ 1456 рядків →
            #     серія Discord-повідомлень). Шлях до журналу додає
            #     канонічний шаблон повідомлення (-LogPath у фінальному
            #     звіті), тут не дублюється.
            $criticalMessage = "Знайдено $($criticalFiles.Count) файлів з критичною зміною розміру після реставрації:`n"
            $criticalExampleLines = New-Object System.Collections.Generic.List[string]
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

                # Один файл = один короткий рядок для operator summary;
                # missing і редукція розрізняються (structured поля, без
                # повторного parsing тексту).
                [void]$criticalExampleLines.Add($(if ($file.Missing) {
                    "$($file.File) — файл відсутній (було $beforeFormatted)"
                } else {
                    "$($file.File) — $beforeFormatted → $afterFormatted (-$($reductionPercent.ToString('0.0'))%)"
                }))
            }

            $criticalAlertLines = @(
                "Знайдено $(Format-BRAVOUkrainianCount -Count $criticalFiles.Count -One 'файл' -Few 'файли' -Many 'файлів') з критичною зміною розміру після реставрації."
                ''
            ) + @(Format-BRAVONotificationListSummary `
                -ExampleLines $criticalExampleLines.ToArray() `
                -TotalCount $criticalFiles.Count) + @(
                ''
                'Повний перелік — у журналі BRAVO_MAINTENANCE.'
            )

            Write-Log $criticalMessage -Level "ERROR"
            Send-SlackAlert -Message ($criticalAlertLines -join "`n") -IsCritical
            $script:criticalErrorOccurred = $true
            $script:restoreIntegrityFailed = $true

            return New-BRAVOCompareFileSizesResult `
                -HasCriticalChanges $true `
                -CriticalFiles $criticalFiles `
                -RemovedByRepairFiles $removedByRepairFiles `
                -MainModelValid $mainModelValid
        } else {
            Write-Log "Критичних змін розміру не знайдено (RemovedByRepair: $(@($removedByRepairFiles).Count))" -Level "INFO"
            return New-BRAVOCompareFileSizesResult `
                -HasCriticalChanges $false `
                -RemovedByRepairFiles $removedByRepairFiles `
                -MainModelValid $mainModelValid
        }
    }
    catch {
        $errorMsg = "Помилка при порівнянні розмірів файлів: $_"
        Write-Log $errorMsg -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
        $script:restoreIntegrityFailed = $true
        # Неможливість довести цілісність MODEL є критичною подією. Повертаємо
        # HasCriticalChanges = $true, щоб викликач виконав відкат і не
        # створив маркер успіху.
        return New-BRAVOCompareFileSizesResult -HasCriticalChanges $true -MainModelValid $false
    }
}

# Функція відновлення з архіву (для відкату при помилках)
#
# -CleanDestinationFirst: перед розпакуванням очистити вміст каталогу
# призначення. Потрібно для відкату після перерваного bravocmd repair,
# який міг створити зайві (orphan) сегментні файли, відсутні в архіві:
# просте `7z x` їх би не прибрало. Очистка виконується ЛИШЕ ПІСЛЯ успішної
# перевірки цілісності before-архіву (нижче) — before-архів є єдиною копією
# для відкату, тому спорожняти модель, не переконавшись, що є з чого
# відновлюватись, заборонено (fail-closed).
function Restore-FromArchive {
    param(
        [string]$ArchivePath,
        [string]$Destination,
        $ARC_PATH,
        [switch]$CleanDestinationFirst
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

    if ($CleanDestinationFirst) {
        # before-архів щойно підтверджено вище — тепер безпечно спорожнити
        # каталог MODEL перед точним розпакуванням.
        if ([string]::IsNullOrWhiteSpace($Destination) -or
            -not (Test-Path -LiteralPath $Destination -PathType Container)) {
            $errorMsg = "Відкат скасовано: каталог MODEL для очистки не знайдено або не заданий: $Destination"
            Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
            $script:restoreArchiveFailed = $true
            return 3
        }
        try {
            foreach ($child in @(Get-ChildItem -LiteralPath $Destination -Force -ErrorAction Stop)) {
                Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
            }
            Write-Log "Каталог MODEL очищено перед відкатом: $Destination" -Level "INFO"
        } catch {
            $errorMsg = "Відкат скасовано: не вдалося очистити каталог MODEL перед розпакуванням: $($_.Exception.Message)"
            Write-Log "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
            $script:restoreArchiveFailed = $true
            return 3
        }
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

# Рішення відновлення після фази bravocmd repair — єдиний власник логіки
# «перевірити → за потреби відкотити» для ОБОХ шляхів (repair exit 0 та
# перерваний/провальний repair exit≠0). Раніше відкат викликався лише на
# шляху exit 0 з критичними змінами; перерваний bravocmd (exit≠0) лишав
# модель без перевірки й без відкату.
#
# Механізм перевірки розмірів тут — невідʼємна частина реставрації і
# виконується завжди (незалежно від окремого прапорця -DisableSizeCheck,
# що керує лише окремим кроком Check-MdFileSizes «.md > ліміт»).
#
# Рішення про відкат залежить ЛИШЕ від фактичного стану моделі
# (HasCriticalChanges), а не від коду виходу bravocmd:
#   - критичних змін немає  -> модель консистентна, відкат не потрібен
#     (навіть якщо bravocmd перервано — модель не постраждала);
#   - критичні зміни є       -> відкат із before-архіву (очистити→розпакувати)
#     і повторна перевірка.
# Повертає структурований результат; script-прапорці exit-коду/гейта
# служб виставляє викликач за цим результатом.
function Invoke-BRAVOModelRestoreRecovery {
    param(
        [int]$BravocmdExitCode,
        [Parameter(Mandatory = $true)][string]$BeforeFile,
        [Parameter(Mandatory = $true)][string]$ModelPath,
        [AllowNull()][string]$MainModelRelativePath = $null,
        [Parameter(Mandatory = $true)][string]$BeforeArchivePath,
        [Parameter(Mandatory = $true)]$ARC_PATH,
        [int]$MinSizeBytes = 2048
    )

    $compare = Compare-FileSizes `
        -BeforeFile $BeforeFile `
        -ModelPath $ModelPath `
        -MinSizeBytes $MinSizeBytes `
        -MainModelRelativePath $MainModelRelativePath

    $rollbackStatus = 'NONE'
    $integrityEstablished = -not $compare.HasCriticalChanges -and $compare.MainModelValid

    if ($compare.HasCriticalChanges) {
        Write-Log -Message "Виявлено критичні зміни моделі після repair — відкат із before-архіву..." -Level "WARNING"
        $rollbackExit = Restore-FromArchive `
            -ArchivePath $BeforeArchivePath `
            -Destination $ModelPath `
            -ARC_PATH $ARC_PATH `
            -CleanDestinationFirst
        if ($rollbackExit -eq 0) {
            # Відкат виконано — повторно доводимо, що модель тепер консистентна.
            $postRollback = Compare-FileSizes `
                -BeforeFile $BeforeFile `
                -ModelPath $ModelPath `
                -MinSizeBytes $MinSizeBytes `
                -MainModelRelativePath $MainModelRelativePath
            if (-not $postRollback.HasCriticalChanges -and $postRollback.MainModelValid) {
                Write-Log -Message "Модель успішно відновлена з before-архіву; консистентність підтверджено" -Level "SUCCESS"
                $rollbackStatus = 'SUCCESS'
                $integrityEstablished = $true
            } else {
                $errorMsg = "Відкат виконано, але модель усе одно не консистентна — потрібне ручне відновлення."
                Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                Send-SlackAlert -Message $errorMsg -IsCritical
                $script:criticalErrorOccurred = $true
                $script:restoreIntegrityFailed = $true
                $rollbackStatus = 'FAILED'
                $integrityEstablished = $false
            }
        } else {
            $errorMsg = "Відкат MODEL із before-архіву не виконано (код: $rollbackExit) — потрібне ручне відновлення."
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
            $rollbackStatus = 'FAILED'
            $integrityEstablished = $false
        }
    }

    return [PSCustomObject]@{
        IntegrityEstablished = $integrityEstablished
        RollbackStatus       = $rollbackStatus
        HasCriticalChanges   = $compare.HasCriticalChanges
        RemovedByRepairCount = $compare.RemovedByRepairCount
        CriticalCount        = @($compare.CriticalFiles).Count
        MainModelValid       = $compare.MainModelValid
    }
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
    $commandStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
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
            # UTF-8 без BOM через канонічний хелпер: під UTF-8-консоллю
            # WriteLine додав би BOM перед паролем (див. Write-BRAVOProcessInputText).
            Write-BRAVOProcessInputText -Process $process -Text $StandardInputText
        }
        $timeoutMilliseconds = [int][math]::Min(
            [double][int]::MaxValue,
            [double][math]::Max(1, $TimeoutSeconds) * 1000
        )
        # Живий підстатус (контракт docs/MANUAL_RUN_CONSOLE_UX.md): тривалі
        # native-операції (bravocmd-реставрація, 7-Zip архівації до/після)
        # раніше блокувались у суцільному WaitForExit(timeout) — оператор
        # бачив застиглу смугу без жодного підстатусу. Polling кожні 500 мс
        # оновлює прогрес канонічним running-рядком BRAVO.Console з НАЗВОЮ
        # поточної операції ("<Фаза> — <Опис операції> — Виконується N
        # сек."): багатохвилинний крок на кшталт "Реставрація моделі"
        # складається з кількох native-фаз (архівація до, bravocmd,
        # архівація після), і без $Description усі вони виглядали однаково
        # (звіт оператора з acceptance rc.12). Сумарний таймаут і
        # kill-семантика після нього не змінені.
        $waitDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($timeoutMilliseconds)
        $completed = $false
        while (-not $completed) {
            $completed = $process.WaitForExit(500)
            if ($completed) { break }
            Write-BRAVOProgressDetail -Detail (
                "$Description — " +
                (Format-BRAVORunningDetail -ElapsedSeconds ([int][math]::Floor($commandStopwatch.Elapsed.TotalSeconds)))
            )
            if ([DateTime]::UtcNow -ge $waitDeadlineUtc) { break }
        }
        Write-BRAVOProgressDetail -Detail ''
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
        $commandStopwatch.Stop()
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

    $commandStopwatch.Stop()
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

    # Структурований заголовок діагностики (Executable/Arguments/ExitCode/
    # Duration) — той самий канонічний хелпер обслуговує bravocmd.exe і всі
    # 7-Zip виклики цього файлу, тому це одне місце, а не дублювання per
    # caller. $StandardInputText (пароль архіву) сюди ніколи не потрапляє —
    # він іде через stdin, не через Arguments.
    $diagnosticsHeader = (
        "`n  Executable : $Command`n" +
        "  Arguments  : $($processInfo.Arguments)`n" +
        "  ExitCode   : $exitCode`n" +
        "  Duration   : $(Format-BRAVODuration -Duration $commandStopwatch.Elapsed)"
    )

    # На успіху це шум, на помилці — єдине джерело причини. Вивід
    # bravocmd/7-Zip писався в DEBUG, а промислові розгортання працюють
    # на INFO: коли реставрація впала з кодом 11153, у журналі лишився
    # сам код без жодного пояснення від інструмента.
    $outputLevel = if ($exitCode -eq 0) { "DEBUG" } else { "ERROR" }
    if (-not [string]::IsNullOrWhiteSpace($formattedOutput)) {
        Write-Log "Деталі виконання:$diagnosticsHeader`n`n  Output:$formattedOutput" -Level $outputLevel
    } else {
        Write-Log "Деталі виконання:$diagnosticsHeader" -Level $outputLevel
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
        Send-SlackAlert -Message $errorMsg -IsCritical
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
        # dev.16: явна array-матеріалізація через @(...) — під PowerShell
        # 5.1 + Set-StrictMode, коли Where-Object повертає рівно один
        # результат, pipeline віддає скалярний FileInfo замість масиву, і
        # .Count на ньому кидає "The property 'Count' cannot be found on
        # this object": підтверджено реальним acceptance-прогоном dev.15
        # на DEV-LIMS (виняток після [8/8], перехоплений fail-safe catch).
        $beforeCount = @($group.Group | Where-Object { $_.Name -like "*_before_*" }).Count
        $afterCount = @($group.Group | Where-Object { $_.Name -like "*_after_*" }).Count
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
        # dev.16: та сама scalar-Count проблема, що вище — Get-ChildItem
        # повертає одиничний FileInfo (не масив), коли залишається рівно
        # один файл; @(...) гарантує масив незалежно від кількості
        # результатів (0/1/N), тому .Count і foreach лишаються безпечними.
        $remainingFiles = @(
            Get-ChildItem -Path $Path -Filter "${ArchivePrefix}_*" -ErrorAction SilentlyContinue
        )
        if ($remainingFiles.Count -gt 0) {
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

        # Зведення по дисках потрапляє у фінальний звіт через
        # $script:freeSpaceSummary — окреме інформаційне повідомлення тут
        # ішло в мертвий буфер і ніколи не доставлялось (5.2.1: буфер
        # видалено разом із викликом).
        $script:freeSpaceSummary = @($driveStatus)

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
        $relativePath = Get-BRAVOModelRelativePath -FullName $file.FullName -RootPath $MODEL_PATH
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
            $relativePath = Get-BRAVOModelRelativePath -FullName $file.FullName -RootPath $MODEL_PATH
            [void]$fileListBuilder.AppendLine("- $relativePath : $sizeFormatted")
        }
        $fileList = $fileListBuilder.ToString()

        $message = "Знайдено $($largeFiles.Count) файлів .md, розмір яких перевищує $($MAX_MD_FILE_SIZE / 1MB) МБ:`n$fileList"
        # Повний перелік — у журналі; alert — count + вибірка (compact).
        $largeMdAlertLines = @(
            "Знайдено $(Format-BRAVOUkrainianCount -Count $largeFiles.Count -One 'файл' -Few 'файли' -Many 'файлів') .md, розмір яких перевищує $($MAX_MD_FILE_SIZE / 1MB) МБ."
            ''
        ) + @(Format-BRAVONotificationListSummary `
            -ExampleLines @($largeFiles | ForEach-Object {
                "$(Get-BRAVOModelRelativePath -FullName $_.FullName -RootPath $MODEL_PATH) : $(Format-FileSize $_.Length)"
            }) `
            -TotalCount $largeFiles.Count) + @(
            ''
            'Повний перелік — у журналі BRAVO_MAINTENANCE.'
        )
        Write-Log $message -Level "WARNING"
        Send-SlackAlert -Message ($largeMdAlertLines -join "`n") -IsCritical
    } elseif ($oversizedFiles.Count -gt 0) {
        Write-Log "Усі великі файли .md виключені з контролю розміру налаштуваннями конфігурації." -Level "DEBUG"
    } else {
        Write-Log "Файли .md з розміром більше $($MAX_MD_FILE_SIZE / 1MB) МБ не знайдено." -Level "INFO"
    }
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
    $notificationSeverity = "SUCCESS"

    if ($script:CriticalErrorsList.Count -gt 0) {
        # Є критичні помилки - відправляємо в режимах "errors_only" та "all"
        $notificationMessage = New-MaintenanceNotificationMessage `
            -Title "КРИТИЧНІ ПОМИЛКИ ОБСЛУГОВУВАННЯ" `
            -TitleEmoji ":rotating_light:" `
            -Severity "CRITICAL" `
            -Duration $elapsedTime `
            -Details @($script:CriticalErrorsList.ToArray()) `
            -LogPath $LOG_FILE
        $notificationSeverity = "CRITICAL"
        $shouldSend = $true
    }
    elseif ($script:NotificationAlertQueue.Count -gt 0) {
        # Notification-only WARNING/ERROR/CRITICAL (Send-SlackAlert
        # -Severity, без -IsCritical) — окрема гілка від справжніх
        # execution-critical подій (CriticalErrorsList) вище: жодна з них
        # не встановлює criticalErrorOccurred і не потрапляє в
        # CriticalErrorsList/execution exit code (review finding #2), але
        # CONTENT-severity в самому повідомленні має відповідати
        # НАЙВИЩІЙ severity у черзі (CRITICAL > ERROR > WARNING) — не
        # downgrade-итись до WARNING лише тому, що всі вони маршрутизуються
        # в один ALERTS-канал (review, повторна знахідка після 95c05d7).
        # Відправляється в режимах "errors_only" та "all" (WARNING/ERROR/
        # CRITICAL завжди -> ALERTS).
        $queuedSeverities = @($script:NotificationAlertQueue | ForEach-Object { [string]$_.Severity })
        $notificationSeverity = if ($queuedSeverities -contains "CRITICAL") {
            "CRITICAL"
        } elseif ($queuedSeverities -contains "ERROR") {
            "ERROR"
        } else {
            "WARNING"
        }
        # Title/TitleEmoji узгоджені з тією самою обчисленою
        # notificationSeverity (не окремий, розбіжний inference) —
        # New-MaintenanceNotificationMessage отримує -Severity явно, тому
        # TitleEmoji тут суто презентаційний і не впливає на content severity.
        $alertQueueTitleEmoji = switch ($notificationSeverity) {
            "CRITICAL" { ":rotating_light:" }
            "ERROR" { ":x:" }
            default { ":warning:" }
        }
        $alertQueueTitle = if ($notificationSeverity -eq "CRITICAL") {
            "BRAVO MAINTENANCE — ПОТРІБНА ДІЯ (CRITICAL)"
        } else {
            "BRAVO MAINTENANCE — ПОТРІБНА ДІЯ"
        }
        $notificationMessage = New-MaintenanceNotificationMessage `
            -Title $alertQueueTitle `
            -TitleEmoji $alertQueueTitleEmoji `
            -Severity $notificationSeverity `
            -Duration $elapsedTime `
            -Details @($script:NotificationAlertQueue | ForEach-Object { [string]$_.Message }) `
            -LogPath $LOG_FILE
        $shouldSend = $true
    }
    else {
        # Немає критичних помилок - відправляємо тільки в режимі "all"
        if ($script:SlackMode -eq "all") {
            $completedCheckLines = [System.Collections.Generic.List[string]]::new()
            $lastRestoreTime = $restoreCompletedAt
            # Персистована дата — джерело істини для ОБОХ шляхів: маркери
            # restore_done_*.marker бачать лише автоматичну реставрацію
            # (примусова їх свідомо не створює), тому реальне повідомлення
            # показувало "ще не виконувалася" через 20 хвилин після успішної
            # примусової. Маркери лишаються legacy-fallback для станів,
            # записаних попередніми версіями.
            if ($null -eq $lastRestoreTime) {
                $lastRestoreTime = Get-BRAVORestoreLastSuccessfulAt -State (Read-BRAVORestoreState)
            }
            if ($null -eq $lastRestoreTime) {
                $lastRestoreMarker = @(Get-BRAVOFiles -Path $LOG_DIR -Filter "restore_done_*.marker" |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1)
                if ($lastRestoreMarker.Count -gt 0) {
                    $lastRestoreTime = [datetime]$lastRestoreMarker[0].LastWriteTime
                }
            }
            $lastRestoreText = if ($null -ne $lastRestoreTime) {
                $lastRestoreTime.ToString("dd.MM.yyyy HH:mm")
            } elseif (-not $BravoMaintenanceEnabled) {
                "немає даних (компонент BRAVO вимкнено)"
            } else {
                "ще не виконувалася"
            }
            # Блок будується з ФАКТИЧНИХ статусів етапів (див.
            # New-BRAVOMaintenanceCompletedLines): збійний етап отримує ❌/⚠️
            # і причину, а не ✅ від самої лише наявності компонента.
            $traceCountText = if ($BravoMaintenanceEnabled -and $traceOutputProcessed) {
                Format-BRAVOUkrainianCount -Count $traceOutputProcessedCount -One "файл" -Few "файли" -Many "файлів"
            } else {
                $null
            }
            $exchangeCountText = if ($exchangAPILogsProcessedCount -gt 0) {
                Format-BRAVOUkrainianCount -Count $exchangAPILogsProcessedCount -One "файл" -Few "файли" -Many "файлів"
            } else {
                $null
            }
            foreach ($completedLine in @(New-BRAVOMaintenanceCompletedLines `
                    -LastRestoreText $lastRestoreText `
                    -FreeSpaceInlineText (Get-MaintenanceFreeSpaceInlineText) `
                    -TraceCountText $traceCountText `
                    -ExchangeCountText $exchangeCountText)) {
                $completedCheckLines.Add([string]$completedLine)
            }

            # dev.19 (виправлено): той самий канонічний
            # Get-BRAVOMaintenanceFinalStatus, що ЛОГ/консоль — раніше
            # Title завжди був "УСПІШНО" тут, навіть коли резолвиться
            # exit 10 (SuccessWithWarnings). Ця функція виконується
            # ВСЕРЕДИНІ зовнішнього try (Main, нижче), ДО його catch і ДО
            # фінального обчислення $script:maintenanceRuntimeExitCode
            # (після catch), тому тут беремо
            # "поточний знімок" через Get-BRAVOMaintenanceResolvedExitCode
            # — ТУ САМУ пріоритетну політику, не окрему копію; якщо після
            # цього виклику (напр. у Write-BRAVOTaskExecutionState чи
            # десь між ним і кінцем try) станеться необроблений виняток,
            # СПРАВЖНЄ $script:maintenanceRuntimeExitCode (обчислене
            # пізніше, після catch) може відрізнятися — і саме воно, а не
            # це повідомлення, керує процесним exit code.
            #
            # TitleEmoji тепер узгоджений із самим текстом (не завжди
            # ":white_check_mark:"): "УСПІШНО З ПОПЕРЕДЖЕННЯМИ" зі
            # ✅-іконкою була б суперечливою презентацією — канонічний
            # warning-маркер репозиторію ":warning:" (Send-InactiveServiceWarning
            # вище, той самий контракт). Це вимагало узгодити й порядок
            # перевірок severity всередині New-MaintenanceNotificationMessage
            # (нижче за визначенням) — інакше "$Title -match 'УСПІШ'"
            # все одно перебивав би ":warning:" і severity лишався б
            # SUCCESS всупереч TitleEmoji. Ця гілка ніколи не викликається
            # для critical-помилок (той шлях — окрема, вища за пріоритетом
            # гілка Send-FinalReport, не змінена); тому тут можливі лише
            # 'УСПІШНО'/'УСПІШНО З ПОПЕРЕДЖЕННЯМИ'.
            $maintenanceNotificationExitCodeSnapshot = Get-BRAVOMaintenanceResolvedExitCode
            $maintenanceNotificationStatus = Get-BRAVOMaintenanceFinalStatus -ExitCode $maintenanceNotificationExitCodeSnapshot
            # NotificationSeverity (маршрутизація) виводиться з ТОГО САМОГО
            # канонічного final status, що визначає TitleEmoji/текст
            # повідомлення — єдине джерело істини, щоб фактичний вміст
            # ("УСПІШНО З ПОПЕРЕДЖЕННЯМИ" + :warning:) і канал доставки
            # (GENERAL/ALERTS) ніколи не розходились (review finding #1).
            $maintenanceIsPureSuccess = $maintenanceNotificationStatus.Text -eq 'УСПІШНО'
            $maintenanceNotificationTitleEmoji = if ($maintenanceIsPureSuccess) {
                ':white_check_mark:'
            } else {
                ':warning:'
            }
            $notificationSeverity = if ($maintenanceIsPureSuccess) { "SUCCESS" } else { "WARNING" }
            $notificationMessage = New-MaintenanceNotificationMessage `
                -Title "BRAVO MAINTENANCE — $($maintenanceNotificationStatus.Text)" `
                -TitleEmoji $maintenanceNotificationTitleEmoji `
                -Severity $notificationSeverity `
                -Duration $elapsedTime `
                -StatusLines @() `
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

    $notificationRoute = Resolve-BRAVONotificationRoute `
        -Severity $notificationSeverity `
        -NotificationMode $script:SlackMode `
        -RoutingTable $bravoSettings.NotificationRouting
    try {
        Invoke-NotificationWebhook -Message $notificationMessage -WebhookUrl $script:NotificationWebhookUrls[$notificationRoute]
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
# Ефективні корені обчислює BRAVO.config: EffectiveLIMSRoot (explicit/AUTO),
# SystemLogRoot (системні журнали), runtimeLogRoot (журнали скриптів),
# stateRoot (машинний стан). Maintenance їх лише споживає.
$ROOT_LIMS = [string]$effectiveLimsRoot
$SYSTEM_LOG_ROOT = [string]$systemLogRoot
if ([string]::IsNullOrWhiteSpace($ROOT_LIMS) -or
    [string]::IsNullOrWhiteSpace($SYSTEM_LOG_ROOT)) {
    Write-Host "ПОМИЛКА: У BRAVO.config не визначено EffectiveLIMSRoot або SystemLogRoot" -ForegroundColor Red
    exit 30
}
# Похідні шляхи
# MODEL_PATH: джерело істини — Resolve-BRAVOInstallationDiscovery
# (bravoDiscoveryResult.MODEL_SOURCE, той самий, що вже читає Archive).
# Discovery сам деградує до "$ROOT_LIMS\Model", якщо bravo.ini недоступний
# — тому це не звужує сумісність, лише замінює локальний здогад на вже
# перевірене джерело: раніше LIMSRoot-відносний шлях завжди мав збігатися
# з реальним розташуванням MODEL випадково (лише коли LIMSRoot і справді
# вказує на корінь інсталяції), а на цій-таки машині вже не збігався.
$MODEL_PATH = if (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.MODEL_SOURCE)) {
    [string]$bravoDiscoveryResult.MODEL_SOURCE
} else {
    "$ROOT_LIMS\Model"
}
# Повний шлях до файлу проєкту (значення MODEL= з bravo.ini як є) — саме
# те, що приймає bravocmd.exe. Без bravo.ini (Discovery не дав значення)
# лишається старий здогад "$ROOT_LIMS\MODEL\lims".
$MODEL_PROJECT_PATH = if (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.MODEL_PROJECT_FILE)) {
    [string]$bravoDiscoveryResult.MODEL_PROJECT_FILE
} else {
    "$ROOT_LIMS\MODEL\lims"
}
# bravocmd.exe стоїть поруч із bravo.exe (BRAVO_ROOT), не обов'язково в
# LIMSRoot. Discovery НЕ деградує BRAVO_ROOT (без служби повертає $null з
# reason) — фолбек до LIMSRoot локальний, тут (той самий, що й раніше).
$BRAVOCMD_PATH = if (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BRAVO_ROOT)) {
    Join-Path ([string]$bravoDiscoveryResult.BRAVO_ROOT) "bravocmd.exe"
} else {
    "$ROOT_LIMS\bravocmd.exe"
}
# MODEL-контракт (тільки похідні значення, без hardcode назви проєкту):
#   MODEL_BASE_PATH == $MODEL_PROJECT_PATH (значення MODEL= з bravo.ini як є)
#   MODEL_DIRECTORY == $MODEL_PATH         (батьківський каталог MODEL_BASE_PATH)
# Обидва вже похідні від Discovery вище. MAIN_MODEL_FILE потрібен для
# post-repair валідації (hint для Compare-FileSizes нижче), MODEL_NAME —
# лише для діагностичного логу; bravocmd.exe як і раніше отримує
# $MODEL_PROJECT_PATH без жодних змін.
$MODEL_NAME = Split-Path -Path $MODEL_PROJECT_PATH -Leaf
$MAIN_MODEL_FILE = "$MODEL_PROJECT_PATH.md"
# Два різні корені (ТЗ RuntimeRoot/SystemLogRoot):
#   $LOG_DIR         — власні журнали Maintenance (BRAVO_MAINTENANCE_*.log,
#                      file_sizes_*.csv, restore_done_*.marker) — RuntimeRoot\LOGS.
#   $SYSTEM_LOG_ROOT — СИСТЕМНІ журнали BRAVO (Trace/exchangAPI/BravoWeb),
#                      кожен компонент у власній гілці.
# Їх навмисно не змішують: script-log retention і system-log retention —
# дві незалежні політики над двома різними каталогами.
$LOG_DIR = [string]$runtimeLogRoot
$TRACE_DIR = Join-Path $SYSTEM_LOG_ROOT "Trace"
$EXCHANGE_LOG_DIR = Join-Path $SYSTEM_LOG_ROOT "exchangAPI"
$BRAVOWEB_LOG_DIR = Join-Path $SYSTEM_LOG_ROOT "BravoWeb"
$APACHE_LOG_DIR = Join-Path $BRAVOWEB_LOG_DIR "Apache"
$BRAVOWEB_APP_LOG_DIR = Join-Path $BRAVOWEB_LOG_DIR "Application"
# Сам застосунок уже ротує свої журнали: у робочому каталозі одночасно
# лежать exchangAPI.log, exchangAPI_1.log, exchangAPI_2.log. Історично
# траплялися обидва шаблони імен, тому шукаємо за обома — з обов'язковою
# дедуплікацією за FullName усередині Get-BRAVOExchangeApiLogFiles: старий
# фільтр "exchangAPI_*.log" пропускав саме поточний файл (без номера), а
# сам по собі "exchangAPI*.log" не покриває історичних розгортань.
$EXCHANGAPI_LOG_FILTERS = @("exchangAPI_*.log", "exchangAPI*.log")
# Apache тримає в apache\logs не лише журнали: httpd.pid, *.lock і тимчасові
# файли — це службові файли, які httpd очікує знайти на місці після старту.
$APACHE_LOG_FILTER = "*.log"
$BRAVOWEB_APP_LOG_FILTER = "*.log"
# Каталог контрольних архівів MODEL (before/after реставрації) — той самий
# BackupRoot\MODEL, що й щоденні backup MODEL (archiveDirs.Model). Fallback
# лишається BackupRoot-відносним, а не ArchiveRoot-відносним.
$ARC_DIR = if ($archiveDirs -and
    -not [string]::IsNullOrWhiteSpace([string]$archiveDirs.Model)) {
    [string]$archiveDirs.Model
} else {
    Join-Path ([string]$backupRootPath) "MODEL"
}
# 7za.exe — runtime-залежність комплекту, тому джерело істини те саме, що й
# для Archive: $arcPath з BRAVO.config (RuntimeRoot\Tools). Раніше тут стояв
# власний Join-Path від ARCHIVE_ROOT — і на розгортанні, де архіви лежать не
# поруч зі скриптами, Maintenance шукав архіватор там, де його немає, тоді як
# Archive у тому самому запуску знаходив його правильно.
$ARC_PATH = if (-not [string]::IsNullOrWhiteSpace([string]$arcPath)) {
    [string]$arcPath
} else {
    Join-Path $bravoScriptDirectory "Tools\7za.exe"
}

if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
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
$maintenanceLogRunId = "{0}_PID{1}" -f $currentDate.ToString("yyyyMMdd_HHmmss"), $PID
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
$restoreWindowOpen = Test-BRAVORestoreTimeWindow `
    -Now $currentDate `
    -WindowStart $parsedRestoreWindowStart `
    -WindowEnd $parsedRestoreWindowEnd
# Перевірка узгодженості конфігурації: якщо Maintenance.DailyAt НЕ
# потрапляє у вікно Restore.WindowStart/WindowEnd, нічний прогін
# Maintenance не підхопить $missedRestoreDue — а на 24/7-профілі
# (Restore.BootRestoreMode="None", 5.2.0) це ЄДИНИЙ автоматичний шлях
# пропущеної реставрації (daily-тригер Recovery о WindowStart прибрано).
# Попередження нижче ($maintenanceDailyAtInsideRestoreWindow) тому
# важливіше, ніж раніше: розсинхрон DailyAt і вікна на 24/7-сервері
# означає, що пропущений слот не виконається автоматично взагалі.
$maintenanceDailyAtSpan = [TimeSpan]::Zero
$maintenanceDailyAtInsideRestoreWindow = [TimeSpan]::TryParse([string]$schedulerSettings.Maintenance.DailyAt, [ref]$maintenanceDailyAtSpan) -and
    (Test-BRAVORestoreTimeWindow -Now $currentDate.Date.Add($maintenanceDailyAtSpan) -WindowStart $parsedRestoreWindowStart -WindowEnd $parsedRestoreWindowEnd)
# Вікном обмежені АВТОМАТИЧНІ шляхи 24/7-профілю. Єдиний свідомий виняток —
# boot-recovery профілю робочого часу (Restore.BootRestoreMode=
# "HoldServices", див. $bootRestoreIgnoresWindow нижче): там реставрація
# зранку одразу після вмикання сервера — задумана поведінка, і клієнтів у
# програмі ще немає, бо служби (Automatic Delayed Start) утримуються
# зупиненими до її завершення.
$scheduledRestoreDue = $isRestoreDay -and $isAfterRestoreTime -and -not (Test-Path $MARKER_FILE)
# НЕ прив'язуємо до -RunMissedRestoreOnly: той прапорець позначає лише те,
# що цей конкретний прогін BRAVO_MAINTENANCE.ps1 стартував через
# Recovery-завдання (5.2.0: єдиний його тригер — boot, профіль робочого
# часу Restore.BootRestoreMode="HoldServices"). Автоматичних шляхів
# пропущеної реставрації два, за профілем: 24/7 — щонічний Maintenance
# (DailyAt у вікні реставрації); робочий час — boot-recovery одразу після
# старту сервера. $missedRestore сам по собі персистентний
# (BRAVO_RESTORE_STATE.json / маркер конкретного $scheduledOccurrence),
# тому перевірка на будь-якому з цих прогонів не створює дублювання.
$missedRestoreDue = $missedRestore
# Тижнева квота: АВТОМАТИЧНА реставрація виконується не частіше разу на
# тиждень, і успішна ПРИМУСОВА зараховується в цей самий тиждень. Успішний
# -ForceRestore записує слот, який він покриває (наступний плановий);
# квота вважається спожитою для поточного слоту, якщо він <= покритого
# (Test-BRAVORestoreWeeklyQuotaConsumed): це закриває і «пропущений»
# МИНУЛИЙ слот (строга рівність тут давала подвійну реставрацію в один
# вечір — інцидент 2026-08-26), і сам покритий; наступний слот (+7 днів)
# строго більший — квота знімається вчасно, без арифметики
# "різниця < 7 діб" з її межовою помилкою.
#
# Гейт стоїть саме на $automaticRestoreDue, а не всередині
# $scheduledSucceeded: $scheduledRestoreDue рахується від СЬОГОДНІШНЬОГО
# маркера, а не від персистованого стану, тому обійшов би правило в сам
# плановий день.
#
# -ForceRestore квотою НЕ обмежується (окремий диз'юнкт у $shouldRestore
# нижче): свідома дія оператора може повторюватись будь-скільки разів.
$forcedRestoreCoveredSlot = Get-BRAVORestoreForcedCoveredSlot -State $restoreState
$weeklyRestoreQuotaConsumed = Test-BRAVORestoreWeeklyQuotaConsumed `
    -ForcedCoveredSlot $forcedRestoreCoveredSlot `
    -ScheduledOccurrence $scheduledOccurrence
$automaticRestoreDue = ($scheduledRestoreDue -or $missedRestoreDue) -and -not $weeklyRestoreQuotaConsumed
# Профіль сервера РОБОЧОГО ЧАСУ (Restore.BootRestoreMode="HoldServices"):
# Recovery-прогін, запущений boot-тригером, ігнорує вікно реставрації —
# служби (Automatic Delayed Start) ще не запущені, клієнтів у програмі
# немає, і іншої нагоди виконати пропущений слот такий сервер не матиме
# (його вимикають до нічного вікна). На 24/7-профілі ("None")
# -RunMissedRestoreOnly поводиться як раніше — вікно обов'язкове.
$bootRestoreIgnoresWindow = $RunMissedRestoreOnly -and
    ([string]$maintenanceSettings.Restore.BootRestoreMode -eq 'HoldServices')
$restoreSkippedByWindow = $automaticRestoreDue -and -not $restoreWindowOpen -and -not $ForceRestore -and -not $bootRestoreIgnoresWindow
$shouldRestore = $BravoMaintenanceEnabled -and ($ForceRestore -or ($automaticRestoreDue -and ($restoreWindowOpen -or $bootRestoreIgnoresWindow)))
$restoreReason = if ($ForceRestore) { "Примусово" } elseif ($missedRestoreDue) { "Пропущений плановий слот $($scheduledOccurrence.ToString('yyyy-MM-dd HH:mm'))$(if ($bootRestoreIgnoresWindow -and -not $restoreWindowOpen) { ' (boot-recovery поза вікном, профіль робочого часу)' })" } else { "$RestoreDayName, після $RestoreTime" }
$CheckSize = -not $DisableSizeCheck
if ($RunMissedRestoreOnly -and $missedDailyWork) {
    # Recovery завжди завершується актуальним backup після maintenance.
    $script:EnableArchiveAfterMaintenance = $true
}

# Похідні файлові шляхи
$ARCH_NAME1 = "${ArchivePrefix}_before_$NOW.mdz"
$ARCH_NAME2 = "${ArchivePrefix}_after_$NOW.mdz"
$LOG_FILE = "$LOG_DIR\BRAVO_MAINTENANCE_$maintenanceLogRunId.log"
$SIZES_FILE = "$LOG_DIR\file_sizes_before_$NOW.csv"
# Каталог-дата спільний для всіх компонентів: нумерація журналів рахується
# в межах конкретної дати, тому TraceSRV_1.out існує і сьогодні, і вчора —
# у різних каталогах, без жодного зв'язку між номерами.
$LOG_DATE_FOLDER = "$YYYY-$MM-$DD"
$TRACE_ARCHIV_DIR = Join-Path $TRACE_DIR $LOG_DATE_FOLDER
$APACHE_DAILY_LOG_DIR = Join-Path $APACHE_LOG_DIR $LOG_DATE_FOLDER
$BRAVOWEB_APP_DAILY_LOG_DIR = Join-Path $BRAVOWEB_APP_LOG_DIR $LOG_DATE_FOLDER
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
# dev.14 (round 2): контроль діапазонів ID раніше не мав власного
# консольного кроку — Test-RangeIdUsage виконувалась мовчки для оператора
# (лише лог і Slack). Той самий "вимкнене — не рахується" принцип, що й
# решта опційних кроків вище.
$script:BRAVOMaintenanceRangeIdStepEnabled = $BravoMaintenanceEnabled -and $RangeIdMonitoringEnabled
# Міграція старої структури журналів — разова операція. Етап існує лише
# тоді, коли хоча б один legacy-каталог справді є на диску: на вже
# мігрованій інсталяції рядок "нічого не мігровано" щодня не потрібен.
$script:BRAVOMaintenanceLegacyMigrationPlan = @(
    Get-BRAVOLegacyLogMigrationPlan -ArchiveRoot (Split-Path -Path $SYSTEM_LOG_ROOT -Parent) -LogRoot $SYSTEM_LOG_ROOT |
        Where-Object {
            ($_.ComponentName -ne 'BravoWeb' -or $BravoWebLegacyDataEnabled) -and
                ($_.ComponentName -ne 'exchangAPI' -or $exchangAPILegacyDataEnabled) -and
                (Test-Path -LiteralPath $_.LegacyPath -PathType Container)
        }
)
$script:BRAVOMaintenanceMigrationStepEnabled = ($script:BRAVOMaintenanceLegacyMigrationPlan.Count -gt 0)
# dev.15: стабільний операційний цикл — РІВНО 8 кроків завжди рендеряться,
# номер кроку НІКОЛИ не пропускається (лише статус OK/WARN/FAIL/SKIPPED
# залежить від того, чи ввімкнена/потрібна дія цього прогону):
#   [1/8] Перевірка вільного місця
#   [2/8] Створення необхідних директорій
#   [3/8] Зупинка служб
#   [4/8] Перевірка розмірів .md
#   [5/8] Реставрація моделі
#   [6/8] Обробка trace і логів
#   [7/8] Відновлення стану служб
#   [8/8] Контроль діапазонів ID
# Раніше CheckSize/Restore/Logs/RangeId пропускали крок ЦІЛКОМ, коли
# вимкнені/не заплановані — номер зсувався, і на реальній інсталяції
# прогін міг "закінчитись" на [7/N] замість очікуваного останнього
# кроку. Total — буквальний літерал 8, НЕ вираз: Міграція старих
# журналів, Очистка старих даних і запуск BRAVO_ARCHIV — по-справжньому
# опційні операції поза цим затвердженим контрактом (detailed LOG,
# видимі в Плані операцій, але БЕЗ власного [N/8] і без виклику
# Write-BRAVOMaintenanceStep) — тому не додаються до Total.
Initialize-BRAVOMaintenanceSteps -Total 8
Write-BRAVOHeader `
    -Title ("BRAVO MAINTENANCE {0}" -f $global:ScriptVersion) `
    -Institution ([string]$bravoSettings.InstitutionName) `
    -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
    -Mode (Get-BRAVOMaintenanceExecutionMode -UserSid $currentIdentity.User.Value) `
    -StartedAt $script:ScriptStartTime

# AutoShutdown=on вимикає сервер ПІСЛЯ успішного завершення — оператор має
# побачити це до того, як почнеться виконання, а не дізнатися постфактум
# із логу (docs/OPERATOR_CONSOLE_UX.md §5, "критичний інваріант": скрипт
# може змінювати систему).
if ($script:EnableAutoShutdown) {
    Write-Host ''
    Write-Host 'УВАГА:' -ForegroundColor Yellow
    Write-Host '  Після успішного завершення сервер буде вимкнено.' -ForegroundColor Yellow
}

# План операцій: те саме "plan-first" правило, що вже застосовано в Dry
# Run/Setup — оператор бачить, ЩО саме виконуватиметься, ще до першого
# кроку. Джерело значень — ті самі прапорці, що вже визначають нумерацію
# кроків нижче (Initialize-BRAVOMaintenanceSteps), тому план і фактичне
# виконання не можуть розійтися.
$maintenancePlanEntries = [ordered]@{
    'Міграція старих журналів'        = [bool]$script:BRAVOMaintenanceMigrationStepEnabled
    # dev.14 (round 3): два окремі operator decisions, не один bool.
    # "Відновлення пропущених операцій" — чи активний цього прогону
    # механізм відновлення пропущеної роботи ($RunMissedRestoreOnly і
    # справді щось пропущено, $missedDailyWork) — та сама умова, що вище
    # (рядок ~3957) вмикає EnableArchiveAfterMaintenance для recovery, і
    # нижче (~4151, ~4467) керує іншими recovery-гілками; це ширше, ніж
    # сама реставрація моделі. "Реставрація моделі" — чи фактично
    # виконається крок реставрації в ЦЬОМУ прогоні ($shouldRestore:
    # -ForceRestore АБО ця сама missed-recovery умова, АБО плановий
    # день/час) — саме те, що показує крок [N/TOTAL] нижче.
    'Відновлення пропущених операцій' = [bool]($RunMissedRestoreOnly -and $missedDailyWork)
    'Перевірка розмірів'              = [bool]$script:BRAVOMaintenanceCheckSizeStepEnabled
    'Maintenance BRAVO'               = [bool]$BravoMaintenanceEnabled
    'Реставрація моделі'              = [bool]$script:BRAVOMaintenanceRestoreStepEnabled
    # dev.16: очистка не має власного on/off прапорця — політика
    # оцінюється КОЖЕН прогін (немає гілки, яка пропускає весь блок
    # "===== ОЧИСТКА СТАРИХ ДАНИХ ====="), тому це не UI-only "ТАК", а
    # буквальне відображення того, що секція завжди виконується. ТАК тут
    # означає "перевірку буде проведено", а не "щось буде видалено" —
    # порожній результат (немає застарілих даних) рендериться SKIPPED
    # на самій операції нижче, план про це не сигналить окремо.
    'Очистка старих даних/логів'      = $true
    'Архівація після maintenance'     = [bool]$script:BRAVOMaintenanceArchiveStepEnabled
    'Автоматичне вимкнення сервера'   = [bool]$script:EnableAutoShutdown
}
$maintenancePlanLabelWidth = (
    $maintenancePlanEntries.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum
).Maximum + 3
Write-Host ''
Write-Host 'План операцій:'
Write-Host ''
foreach ($planEntry in $maintenancePlanEntries.GetEnumerator()) {
    $planLabel = ("{0}:" -f $planEntry.Key).PadRight($maintenancePlanLabelWidth)
    $planValue = if ($planEntry.Value) { 'ТАК' } else { 'НІ' }
    Write-Host ("  {0}{1}" -f $planLabel, $planValue)
}
Write-Host ''
# dev.15: '='-роздільник (Write-BRAVOHeaderSeparator), не '-'
# (Write-BRAVOSeparator) — План операцій є продовженням того самого
# титульного блоку, що відкрив Write-BRAVOHeader вище, а не окремим
# блоком РЕЗУЛЬТАТ.
Write-BRAVOHeaderSeparator

Write-Log -Message "==="
Write-Log -Message "=== СИСТЕМА ОБСЛУГОВУВАННЯ BRAVOSOFT ЗАПУЩЕНА ==="
Write-Log -Message "=== УСТАНОВА: $($script:ObjectName) ==="
Write-Log -Message "==="
Write-Log -Message "Коренева директорія: $ROOT_LIMS" -NoTimestamp
Write-Log -Message "Конфігурація: $ConfigPath" -NoTimestamp
Write-Log -Message "Сумісність: Windows $($BRAVOCompatibility.WindowsVersion); PowerShell $($BRAVOCompatibility.PowerShellVersion); WMI=$($BRAVOCompatibility.WmiProvider); Hash=$($BRAVOCompatibility.FileHashProvider); Files=$($BRAVOCompatibility.ChildItemProvider)" -NoTimestamp
if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
    Write-Log -Message $BRAVOPowerShellUpdate.Message -Level "WARNING" -Environmental
}
$script:BRAVOOSSupportTier = Get-BRAVOOSSupportTier
Write-Log -Message "Підтримка ОС: $($script:BRAVOOSSupportTier.Tier) — Windows $($script:BRAVOOSSupportTier.OperatingSystem) ($($script:BRAVOOSSupportTier.OperatingSystemVersion), build $($script:BRAVOOSSupportTier.Build)); PowerShell $($script:BRAVOOSSupportTier.PowerShellVersion); .NET release $($script:BRAVOOSSupportTier.DotNetRelease)" -NoTimestamp
if ($script:BRAVOOSSupportTier.Tier -eq "LegacyBestEffort") {
    # Рівень INFO навмисно: legacy-tier — environmental-метрика, а не
    # результат обслуговування. WARNING тут інкрементував лічильник
    # попереджень, і КОЖЕН успішний прогін на Server 2012 R2/2016
    # завершувався кодом 10 (SuccessWithWarnings), а звіт ішов у канал
    # ALERTS замість GENERAL — хоча на maintenance рівень ОС не впливає.
    # Постійне нагадування про legacy-ОС — відповідальність BRAVO_HEALTH
    # (там воно лишається WARNING), той самий принцип, що вже застосовано
    # до віку Windows-оновлень (health-метрика, а не умова запуску — див.
    # BRAVO_TASKS_INSTALL.ps1).
    Write-Log -Message $script:BRAVOOSSupportTier.Message -Level "INFO"
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
    # Формулювання називає поріг контролю, а не поточний стан: старий текст
    # "понад N% у <файл>" читався так, ніби використання ВЖЕ перевищило поріг.
    Write-Log -Message "Контроль діапазонів ID: УВІМКНЕНО; поріг >$($RangeIdThresholdPercent)%; файл: $RangeIdLogPath" -NoTimestamp
}
Write-Log -Message "Дата: $($currentDate.ToString('yyyy-MM-dd'))" -NoTimestamp
Write-Log -Message "Час: $($currentDate.ToString('HH:mm:ss'))" -NoTimestamp
# $missedDailyWork (пропущений денний Backup/Maintenance) — не єдина причина
# продовжувати: якщо пропущено САМЕ реставрацію ($missedRestoreDue) і вона
# зараз здійсненна (вікно відкрите АБО boot-recovery профілю робочого часу,
# який вікно ігнорує), Recovery має дійти до звичайного кроку реставрації
# нижче, а не вийти без дій. Інакше — компактний no-op-вихід. Гілка
# «поза вікном» тепер можлива лише при РУЧНОМУ -RunMissedRestoreOnly на
# 24/7-профілі: Scheduler-Repetition 15-хвилинних повторів прибрано у
# 5.2.0, тому жодного «повторна спроба за N хв» тут більше немає.
$missedRestoreActionableNow = $missedRestoreDue -and ($restoreWindowOpen -or $bootRestoreIgnoresWindow)
if ($RunMissedRestoreOnly -and -not $missedDailyWork -and -not $missedRestoreActionableNow) {
    if ($missedRestoreDue) {
        Write-Log -Message "Recovery: пропущена реставрація поза вікном $RestoreWindowStart-$RestoreWindowEnd; вона виконається у вікні (плановим Maintenance) або запустіть -ForceRestore свідомо" -Level 'INFO'
    } else {
        Write-Log -Message "Recovery: пропущених Backup/Maintenance не знайдено; завершення без дій" -Level 'INFO'
    }
    # dev.16: раніше тут був голий "exit 0" без жодного підсумку —
    # оператор бачив заголовок і План операцій (вище), а потім одразу
    # "Натисніть будь-яку клавішу..." від зовнішнього finally, без
    # жодного результату. [1/8]...[8/8] свідомо НЕ запускаються: реальних
    # операцій цього прогону немає, фальшиві numbered steps ввели б в
    # оману (не основний 8-step run, окремий compact no-op summary).
    # Зовнішній try/finally (рядок ~55) все одно охоплює цей exit —
    # Wait-BRAVOManualExit спрацьовує так само, як і завжди.
    Complete-BRAVOProgress
    Write-BRAVOFinalSummaryHeader `
        -Title 'BRAVO MAINTENANCE' `
        -Status 'УСПІШНО' `
        -StatusColor Green
    Write-BRAVOResultField -Label 'Статус' -Value 'УСПІШНО' -Color Green
    Write-BRAVOResultField -Label 'Код завершення' -Value ("0 — {0}" -f (Get-BRAVOExitCodeName -Code 0))
    Write-BRAVOResultField -Label 'Результат' -Value 'Пропущених операцій не знайдено'
    Write-BRAVOFinalSummaryFooter -LogFile $LOG_FILE
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
    if ($bravoWebComponentPlan.WarnDuplicateService) {
        Write-Log -Message "Знайдено $BravoWebServiceMatchCount служб для одного httpd.exe; обрано службу [$BravoWebServiceName] зі станом $($ApacheService.Status)" -Level "WARNING"
    }
    Write-Log -Message "Обробка веб-логів: $(if ($ApacheEnabled) {'Увімкнена'} else {'Вимкнена'})" -NoTimestamp
}

if ($BravoMaintenanceEnabled) {
    if ($isRestoreDay -and $isAfterRestoreTime -and (Test-Path $MARKER_FILE)) {
        Write-Log -Message "РЕСТАВРАЦІЯ СЬОГОДНІ ВЖЕ ВИКОНУВАЛАСЬ (знайдено маркер $([System.IO.Path]::GetFileName($MARKER_FILE)))" -Level "INFO"
    }

    Write-Log -Message "Реставрація моделі: $(if ($shouldRestore) {"АКТИВОВАНА ($restoreReason)"} else {"ВИМКНЕНА"})" -NoTimestamp
    Write-Log -Message "Перевірка розмірів файлів: $(if ($CheckSize) {'УВІМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log -Message "Умови: заданий день=$isRestoreDay, після $RestoreTime=$isAfterRestoreTime; вікно $RestoreWindowStart-$RestoreWindowEnd=$restoreWindowOpen" -NoTimestamp
    # Пропуск за тижневою квотою — не тиха відмова: без цього рядка оператор
    # бачив би лише "ВИМКНЕНА" в плановий день і не мав би причини.
    # INFO, не WARNING: це штатне планове рішення, а не аномалія (той самий
    # принцип, що для -ForceRestore поза вікном нижче).
    if ($weeklyRestoreQuotaConsumed) {
        Write-Log -Message (
            "Планову реставрацію слоту $($scheduledOccurrence.ToString('yyyy-MM-dd HH:mm')) пропущено: " +
            "цього тижня вже виконано примусову реставрацію. Автоматична реставрація виконується " +
            "не частіше разу на тиждень; -ForceRestore обмежень не має."
        ) -Level "INFO"
    }
    # Пропуск через вікно — не тиха відмова: без цього рядка оператор бачив
    # би лише "ВИМКНЕНА" й не мав би причини.
    #
    # INFO, не WARNING (5.2.1; рішення власника після реального прогону
    # ТЕРНОПІЛЬСЬКА РДЛ 2026-08-26 16:42): ручний денний прогін Maintenance
    # поза вікном 21:00-03:00 — штатна ситуація, а не аномалія: пропущений
    # слот НЕ втрачається (його підхоплює нічний Maintenance у вікні на
    # 24/7-профілі або boot-Recovery на профілі робочого часу). WARNING тут
    # інкрементував BRAVOWarningCount -> severity WARNING -> exit 10 -> алерт
    # «ПОТРІБНА ДІЯ» при повністю зеленому списку етапів. Розсинхрон
    # конфігурації, за якого слот справді НЕ виконався б автоматично,
    # покриває окреме попередження $maintenanceDailyAtInsideRestoreWindow
    # нижче. Текст лишається в лозі повністю — змінюється лише рівень.
    if ($restoreSkippedByWindow) {
        Write-Log -Message (
            "Реставрацію пропущено: поточний час $($currentDate.ToString('HH:mm')) поза дозволеним вікном " +
            "$RestoreWindowStart-$RestoreWindowEnd. Слот буде підхоплено автоматично у вікні; " +
            "для позапланового запуску зараз використайте -ForceRestore."
        ) -Level "INFO"
    }
    if ($ForceRestore -and -not $restoreWindowOpen) {
        # INFO, не WARNING: це констатація СВІДОМОЇ дії оператора (він сам
        # передав -ForceRestore), а не аномалія. Будь-який WARNING інкрементує
        # $script:BRAVOWarningCount (Write-Log вище), а той піднімає severity
        # сповіщення й дає exit 10 (SuccessWithWarnings) — реальний DEV-LIMS
        # прогін 20:29 показав оператору жовте "ПОТРІБНА ДІЯ: перевірити
        # журнал" при повністю зеленому списку етапів, без жодної підказки,
        # що саме не так. Текст лишається в лозі повністю — змінюється лише
        # рівень, тобто участь у severity/exit-коді.
        #
        # (5.2.1) Сусідня гілка $restoreSkippedByWindow тепер теж INFO — той
        # самий клас хибного «ПОТРІБНА ДІЯ», підтверджений реальним денним
        # прогоном ТЕРНОПІЛЬСЬКА РДЛ; обґрунтування в коментарі тієї гілки.
        Write-Log -Message (
            "Примусова реставрація поза дозволеним вікном $RestoreWindowStart-$RestoreWindowEnd " +
            "(поточний час $($currentDate.ToString('HH:mm'))): служби BRAVO будуть зупинені."
        ) -Level "INFO"
    }
    if (-not $maintenanceDailyAtInsideRestoreWindow) {
        # INFO, не WARNING: Recovery-таск має власний daily trigger саме на
        # Restore.WindowStart (BRAVO_TASKS_INSTALL.ps1, New-BRAVOTaskDefinition),
        # тому підхоплення пропущеної реставрації НЕ втрачається через
        # розсинхронізацію Maintenance.DailyAt і вікна — лише не бере участі
        # цей конкретний нічний прогін.
        Write-Log -Message (
            "Maintenance.DailyAt ($($schedulerSettings.Maintenance.DailyAt)) поза вікном Restore " +
            "$RestoreWindowStart-${RestoreWindowEnd}: підхоплення пропущеної реставрації цим нічним " +
            "прогоном недоступне; використовується daily Recovery-тригер о $RestoreWindowStart і boot-recovery."
        ) -Level "INFO"
    }
}
# ===== ВИЯВЛЕННЯ ДЖЕРЕЛ ЖУРНАЛІВ =====
# Виконується ДО зупинки служб і до будь-якого переміщення: коли служби вже
# зупинені, з'ясовувати "а звідки взагалі брати trace" пізно — кожна секунда
# тут це простій BRAVO. Мовчазного пропуску немає: журнал показує і джерело,
# і призначення для кожного з чотирьох компонентів, навіть якщо джерела
# зараз немає.
Write-Log -Message "==="
Write-Log -Message "=== ДЖЕРЕЛА ЖУРНАЛІВ ==="

$traceConfiguration = $null
if ($BravoMaintenanceEnabled) {
    $traceConfiguration = Get-BRAVOTraceConfiguration `
        -DiscoveryResult $bravoDiscoveryResult `
        -TraceRootDirectory $TRACE_DIR `
        -DateFolderName $LOG_DATE_FOLDER
    $bravoIniDisplayPath = if ([string]::IsNullOrWhiteSpace($traceConfiguration.IniPath)) {
        "не знайдено"
    } else {
        $traceConfiguration.IniPath
    }
    Write-Log -Message "BRAVO INI: $bravoIniDisplayPath" -Level "INFO"
    Write-Log -Message "Каталог інсталяції BRAVO: $(if ([string]::IsNullOrWhiteSpace($traceConfiguration.InstallationDirectory)) { 'не визначено' } else { $traceConfiguration.InstallationDirectory })" -Level "INFO"
    if ($traceConfiguration.IsValid) {
        Write-Log -Message "BRAVO Trace [Debug]/FILE: $($traceConfiguration.TracePath)" -Level "INFO"
        Write-Log -Message "BRAVO Trace призначення: $($traceConfiguration.DestinationDirectory)" -Level "INFO"
        if ([bool]$traceConfiguration.IsOutsideInstallation) {
            Write-Log -Message "BRAVO Trace розташований поза каталогом інсталяції BRAVO ($($traceConfiguration.InstallationDirectory)): $($traceConfiguration.TracePath)" -Level "WARNING"
        }
    } else {
        # ТЗ §22: неможливість визначити trace — саме конфігураційна
        # помилка, а не інформаційне повідомлення. Обслуговування далі
        # виконується (реставрація важливіша за ротацію), але запуск
        # завершиться ненульовим кодом, а причина названа поіменно.
        $traceConfigurationError = (
            "Не вдалося визначити журнал BRAVO Trace: файл конфігурації bravo.ini, " +
            "секція [Debug], ключ FILE. Причина: $($traceConfiguration.Reason)"
        )
        Write-Log -Message "ПОМИЛКА: $traceConfigurationError" -Level "ERROR"
        Send-SlackAlert -Message $traceConfigurationError -IsCritical
        $script:criticalErrorOccurred = $true
    }
}

# Trace-модель: усі *.out з кореня інсталяції bravo.exe за прохід
# (Get-BRAVOInstallationTraceOutSources вище) + SRV з bravo.ini і явний
# BISSourcePath, якщо вони поза коренем. Порожній/'off' BISSourcePath —
# нічого додаткового (корінь покривається скануванням; rooted-валідність
# явного шляху гарантована конфіг-лоадером). Ротовані .out усіх джерел
# ідуть ПЛОСКО у Trace\ (timestamp-імена), каталоги-дати лишаються
# тільки за legacy-ланцюгом.
$traceOutSources = @()
if ($BravoMaintenanceEnabled) {
    $traceSrvPathForEnumeration = if ($null -ne $traceConfiguration -and $traceConfiguration.IsValid) {
        [string]$traceConfiguration.TracePath
    } else { '' }
    $traceOutEnumeration = Get-BRAVOInstallationTraceOutSources `
        -InstallationRoot ([string]$bravoDiscoveryResult.BRAVO_ROOT) `
        -LimsRoot $ROOT_LIMS `
        -SrvTracePath $traceSrvPathForEnumeration `
        -ExplicitBisPath ([string]$MaintenanceConfig.Trace.BISSourcePath)
    $traceOutSources = @($traceOutEnumeration.Sources)
    if ([string]::IsNullOrWhiteSpace([string]$traceOutEnumeration.ScanRoot)) {
        Write-Log -Message "BRAVO Trace *.out: $($traceOutEnumeration.ScanRootReason)" -Level "WARNING"
    } else {
        Write-Log -Message "BRAVO Trace *.out: скан $($traceOutEnumeration.ScanRoot) ($($traceOutEnumeration.ScanRootReason)) — джерел: $(@($traceOutSources).Count)" -Level "INFO"
        foreach ($traceOutSource in $traceOutSources) {
            Write-Log -Message "BRAVO Trace джерело: $($traceOutSource.Path)" -Level "INFO"
        }
    }
    Write-Log -Message "BRAVO Trace призначення ротації: $TRACE_DIR" -Level "INFO"
}

$exchangeApiRuntime = $null
if ($exchangAPIServiceEnabled) {
    $exchangeApiRuntime = Resolve-BRAVOExchangeApiRuntimeDirectory `
        -ServiceName $ExchangAPIServiceName `
        -FallbackDirectory $ROOT_LIMS
    Write-Log -Message "exchangAPI робочий каталог: $($exchangeApiRuntime.Directory) ($($exchangeApiRuntime.Reason))" -Level "INFO"
    Write-Log -Message "exchangAPI шаблони джерела: $($EXCHANGAPI_LOG_FILTERS -join '; ')" -Level "INFO"
    Write-Log -Message "exchangAPI призначення: $EXCHANGE_LOG_DIR (оригінальні імена; добовий exchangAPI_YYYYMMDD.mdz -> SFTP $exchangeApiSftpRemoteDirectory)" -Level "INFO"
}

if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    Write-Log -Message "Apache джерело: $APACHE_LOGS_DIR (фільтр: $APACHE_LOG_FILTER, без рекурсії)" -Level "INFO"
    Write-Log -Message "Apache призначення: $APACHE_DAILY_LOG_DIR" -Level "INFO"
    Write-Log -Message "BravoWeb корінь журналів: $WWW_LOGS_DIR (фільтр: $BRAVOWEB_APP_LOG_FILTER)" -Level "INFO"
    Write-Log -Message "BravoWeb рекурсивний обхід: увімкнено (відносна структура каталогів зберігається)" -Level "INFO"
    Write-Log -Message "BravoWeb призначення: $BRAVOWEB_APP_DAILY_LOG_DIR" -Level "INFO"
}

Write-Log -Message "==="
Write-Log -Message "=== ПЕРЕВІРКА ВІЛЬНОГО МІСЦЯ ==="
Write-BRAVOProgressPhase -Phase 'Перевірка вільного місця' -PercentComplete 5
$spaceCheckResult = Check-FreeSpace -ROOT_LIMS $ROOT_LIMS -ExcludedDrives $FREE_SPACE_EXCLUDED_DRIVES

# Перевірка критичних помилок після перевірки місця
if (-not $spaceCheckResult) {
    Write-BRAVOMaintenanceStep -Name 'Перевірка вільного місця' -Status 'FAIL' -Details 'недостатньо місця'
    Write-Log -Message "Критична помилка перевірки місця. Завершення скрипта." -Level "ERROR"
    $diskPreflightExitCode = Get-BRAVOMaintenanceResolvedExitCode
    $script:maintenanceRuntimeExitCode = $diskPreflightExitCode
    # Ранній вихід оминає фінальний блок — machine-readable статус (P2.1)
    # пишеться й тут, fail-soft (див. коментар у фінальному блоці).
    try {
        Write-BRAVOOperationStatus `
            -StateRoot $stateRoot `
            -Operation Maintenance `
            -ExitCode $diskPreflightExitCode `
            -ExitCodeName (Get-BRAVOExitCodeName -Code $diskPreflightExitCode) `
            -StartedAt $script:ScriptStartTime `
            -Details @{
                stepsTotal = [int]$script:BRAVOMaintenanceStepLog.Count
                stepsOk = [int]$script:BRAVOMaintenanceStepOkCount
                stepsWarning = [int]$script:BRAVOMaintenanceStepWarnCount
                stepsSkipped = [int]$script:BRAVOMaintenanceStepSkippedCount
                stepsError = [int]$script:BRAVOMaintenanceStepFailCount
                criticalErrorOccurred = [bool]$script:criticalErrorOccurred
            }
    } catch {
        Write-Log -Message "ПОПЕРЕДЖЕННЯ: не вдалося записати machine-readable status-файл Maintenance: $($_.Exception.Message)"
    }
    Write-BRAVOMaintenanceEarlyFailureSummary `
        -EndedAt (Get-Date) `
        -ExitCode $diskPreflightExitCode
    Complete-BRAVOProgress
    Wait-BRAVOManualExit -NoPause:$NoPause
    exit $diskPreflightExitCode
}
Write-BRAVOMaintenanceStep -Name 'Перевірка вільного місця' -Status 'OK'

# ===== СТВОРЕННЯ НЕОБХІДНИХ ДИРЕКТОРІЙ =====
# Перевіряємо, чи потрібно створювати будь-які директорії
$dirsToCreate = @()
if ($BravoMaintenanceEnabled) {
    $dirsToCreate += $ARC_DIR
    # Каталог-дата Trace створюється лише тоді, коли є що в нього класти:
    # без валідного [Debug]/FILE він був би порожньою теку-обіцянкою, яку
    # потім довелося б архівувати як "старі дані".
    if ($null -ne $traceConfiguration -and $traceConfiguration.IsValid) {
        $dirsToCreate += $TRACE_DIR, $TRACE_ARCHIV_DIR
    }
}
if ($exchangAPIServiceEnabled) {
    # Нова модель — плоский EXCHANGE_LOG_DIR (оригінальні імена + добовий
    # exchangAPI_YYYYMMDD.mdz); каталоги-дати більше не створюються
    # (legacy-каталоги обробляє лише retention/compress-ланцюг).
    $dirsToCreate += $EXCHANGE_LOG_DIR
}
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    $dirsToCreate += $BRAVOWEB_LOG_DIR, $APACHE_LOG_DIR, $APACHE_DAILY_LOG_DIR,
        $BRAVOWEB_APP_LOG_DIR, $BRAVOWEB_APP_DAILY_LOG_DIR
}

# Перевіряємо, які директорії потрібно створити.
# @() обовʼязкове: Where-Object повертає один обʼєкт, а не масив, коли збіг
# рівно один, і тоді .Count під Set-StrictMode кидає PropertyNotFoundStrict.
$missingDirs = @($dirsToCreate | Where-Object { -not (Test-Path $_) })

# dev.14 (round 2): консольний крок 'Створення необхідних директорій'
# друкується НИЖЧЕ, після lock — об'єднаний з ініціалізацією/міграцією
# MANIFESTS в один рядок оператора (Не створювати окремий шумний крок
# щодня). Тут лише виконання й накопичення результату; сам New-Item і
# позиція відносно lock не змінені.
$createdDirs = New-Object 'System.Collections.Generic.List[string]'
if ($missingDirs.Count -gt 0 -or $script:criticalErrorOccurred) {
    Write-Log -Message "==="
    Write-Log -Message "=== СТВОРЕННЯ НЕОБХІДНИХ ДИРЕКТОРІЙ ==="

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
}
$directoryCreationFailed = $script:criticalErrorOccurred

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

$bravoLogRotationLogger = { param($Message, $Level) Write-Log -Message $Message -Level $Level }

# ===== ІНІЦІАЛІЗАЦІЯ/МІГРАЦІЯ MANIFESTS (dev.14) =====
# Під lock, але ДО зупинки служб — та сама причина, що й міграція старих
# журналів нижче: не потребує зупинених служб. Ідемпотентно переносить
# legacy BRAVO_BACKUP_*.json з кореня BackupRoot у MANIFESTS\
# (BRAVO.ArchiveHelpers). Ніколи не блокує Maintenance — конфлікт (різні
# версії того самого generationId в корені й у MANIFESTS) чи помилка лишає
# legacy-файл на місці й лише пишеться у лог; наступний запуск повторить
# спробу. Консольний результат — не окремий крок, а деталь кроку
# 'Створення необхідних директорій' нижче: на вже мігрованій інсталяції
# тут щодня немає чого показувати оператору.
$manifestMigrationResult = Initialize-BRAVOBackupManifestStorage `
    -BackupRoot $backupRootPath `
    -Logger $bravoLogRotationLogger
if ($manifestMigrationResult.Errors.Count -gt 0) {
    foreach ($manifestMigrationError in $manifestMigrationResult.Errors) {
        Write-Log -Message "Міграція manifest-ів backup: $manifestMigrationError" -Level "WARNING"
    }
}
if ($manifestMigrationResult.Migrated.Count -gt 0 -or
    $manifestMigrationResult.Deduplicated.Count -gt 0 -or
    $manifestMigrationResult.Conflicts.Count -gt 0) {
    Write-Log -Message (
        "Міграція manifest-ів backup у MANIFESTS: перенесено " +
        "$($manifestMigrationResult.Migrated.Count); дедубльовано " +
        "$($manifestMigrationResult.Deduplicated.Count); конфліктів " +
        "$($manifestMigrationResult.Conflicts.Count)"
    ) -Level $(if ($manifestMigrationResult.Conflicts.Count -gt 0) { "WARNING" } else { "SUCCESS" })
}

# Об'єднаний консольний результат кроку 'Створення необхідних директорій':
# звичайне створення LOGS-каталогів (вище, до lock) + MANIFESTS init/
# migration (вище, після lock) — оператор бачить один рядок, а не два
# майже завжди порожніх кроки. FAIL має пріоритет (реальна відмова), потім
# WARN (конфлікт міграції — нічого не втрачено, але потребує уваги),
# інакше OK, інакше SKIPPED, коли жодна з двох дій нічого не зробила.
$directoryStepDetailParts = New-Object System.Collections.Generic.List[string]
if ($createdDirs.Count -gt 0) {
    $directoryStepDetailParts.Add("створено директорій: $($createdDirs.Count)")
}
if ($manifestMigrationResult.ManifestRootCreated) {
    $directoryStepDetailParts.Add("створено: $($manifestMigrationResult.ManifestRoot)")
}
if ($manifestMigrationResult.Migrated.Count -gt 0) {
    $directoryStepDetailParts.Add("перенесено manifest-ів: $($manifestMigrationResult.Migrated.Count)")
}
if ($manifestMigrationResult.Deduplicated.Count -gt 0) {
    $directoryStepDetailParts.Add("дедубльовано manifest-ів: $($manifestMigrationResult.Deduplicated.Count)")
}
if ($manifestMigrationResult.Conflicts.Count -gt 0) {
    $directoryStepDetailParts.Add("конфліктів manifest-ів: $($manifestMigrationResult.Conflicts.Count)")
}
if ($manifestMigrationResult.Errors.Count -gt 0) {
    $directoryStepDetailParts.Add("помилок міграції manifest-ів: $($manifestMigrationResult.Errors.Count)")
}

# dev.14 (round 3): manifest migration контракт лишається non-fatal/
# retryable (round 1) — FAIL тут означає лише РЕАЛЬНУ відмову створення
# LOGS-каталогів (директорія, потрібна Maintenance/трасуванню, не
# з'явилась). Конфлікт чи помилка міграції manifest-ів — WARN: нічого не
# втрачено (legacy-файл лишається на місці, наступний запуск повторить
# спробу), Maintenance через це не вважається failed.
$directoryStepStatus = if ($directoryCreationFailed) {
    'FAIL'
} elseif ($manifestMigrationResult.Conflicts.Count -gt 0 -or $manifestMigrationResult.Errors.Count -gt 0) {
    'WARN'
} elseif ($directoryStepDetailParts.Count -gt 0) {
    'OK'
} else {
    'SKIPPED'
}
if ($directoryStepStatus -eq 'SKIPPED') {
    Write-BRAVOMaintenanceStep `
        -Name 'Створення необхідних директорій' `
        -Status 'SKIPPED' `
        -Details 'усі вже існують'
} else {
    Write-BRAVOMaintenanceStep `
        -Name 'Створення необхідних директорій' `
        -Status $directoryStepStatus `
        -Details ($directoryStepDetailParts -join "`n")
}

# ===== МІГРАЦІЯ СТАРОЇ СТРУКТУРИ ЖУРНАЛІВ =====
# Під lock, але ДО зупинки служб: міграція торкається лише вже заархівованих
# журналів у ArchiveRoot, тримати заради неї BRAVO зупиненим не потрібно.
# Виконується перед ротацією, щоб нові файли лягали у вже впорядковане дерево.
$migrationOperationStartedAt = Get-Date
if ($script:BRAVOMaintenanceMigrationStepEnabled) {
    Write-Log -Message "==="
    Write-Log -Message "=== МІГРАЦІЯ СТАРОЇ СТРУКТУРИ ЖУРНАЛІВ ==="
    $migratedTotal = 0
    $migrationFailedTotal = 0
    foreach ($migrationEntry in $script:BRAVOMaintenanceLegacyMigrationPlan) {
        try {
            $migrationResult = Invoke-BRAVOLegacyLogMigration `
                -LegacyPath $migrationEntry.LegacyPath `
                -DestinationPath $migrationEntry.DestinationPath `
                -LogicalBaseName ([string]$migrationEntry.LogicalBaseName) `
                -RetryCount $MoveRetryCount `
                -RetryDelaySeconds $MoveRetryDelaySeconds `
                -Logger $bravoLogRotationLogger
            $migratedTotal += [int]$migrationResult.Migrated
            $migrationFailedTotal += [int]$migrationResult.Failed
        } catch {
            $migrationFailedTotal++
            Write-Log -Message "ПОМИЛКА міграції каталогу $($migrationEntry.LegacyPath): $($_.Exception.Message)" -Level "ERROR"
        }
    }
    # dev.15: міграція — опційна разова операція поза затвердженим [N/8]
    # контрактом (не numbered main step); підсумок лишається в LOG, без
    # Write-BRAVOMaintenanceStep і без власного номера кроку. Невдала
    # міграція не знищує нічого: джерело лишається на місці й переїде
    # наступного запуску, тому рівень лишається INFO (як і раніше — per-
    # directory помилки вище вже логуються окремо рівнем ERROR).
    Write-Log -Message $(if ($migratedTotal -gt 0 -or $migrationFailedTotal -gt 0) {
        "Міграція старої структури журналів завершена: перенесено $migratedTotal; не вдалося $migrationFailedTotal"
    } else {
        "Міграція старої структури журналів: нічого переносити"
    })
    # dev.16: та сама причина, що execution result нижче для Cleanup/
    # Archive/AutoShutdown — операція РЕАЛЬНО виконується щоразу, коли
    # увімкнена, але досі мала лише LOG-видимість. WARN, а не FAIL: невдала
    # міграція не критична (semantics вище незмінні — це той самий
    # $migrationFailedTotal, що вже керував рівнем LOG-повідомлення).
    Write-BRAVOMaintenanceOperation `
        -Name 'Міграція старих журналів' `
        -Status $(if ($migrationFailedTotal -gt 0) { 'WARN' } else { 'OK' }) `
        -Duration ((Get-Date) - $migrationOperationStartedAt) `
        -Details $(if ($migrationFailedTotal -gt 0) {
            "перенесено: $migratedTotal; не вдалося: $migrationFailedTotal"
        } elseif ($migratedTotal -gt 0) {
            "перенесено файлів: $migratedTotal"
        } else {
            "нічого переносити"
        })
} else {
    # dev.16: немає застарілих каталогів для міграції цього прогону —
    # той самий SKIPPED/'не заплановано на цей запуск' контраст, що вже
    # застосований до Restore/SizeCheck/Logs/RangeId.
    Write-BRAVOMaintenanceOperation `
        -Name 'Міграція старих журналів' `
        -Status 'SKIPPED' `
        -Duration ((Get-Date) - $migrationOperationStartedAt) `
        -Details 'не заплановано на цей запуск'
}

$traceOutputProcessed = $false
$traceOutputProcessedCount = 0
$exchangAPILogsFoundCount = 0
$exchangAPILogsProcessedCount = 0
$webApacheLogsProcessedCount = 0
$webWwwLogsProcessedCount = 0
$restoreCompletedAt = $null
# Чи запускала службу BRAVO САМЕ ця сесія maintenance (блок відновлення
# стану служб нижче). Одразу після такого старту range_id_log.json може ще
# не існувати (служба створює його асинхронно) — крок контролю діапазонів
# ID використовує прапорець, щоб дочекатися файла замість false WARNING.
$script:bravoServiceStartedThisRun = $false

try {
# StartPending рахується як «працювала»: служба, що саме стартує на
# момент знімка, все одно буде зупинена секцією нижче (вона зупиняє за
# ФАКТИЧНИМ станом), і без restart-intent лишилася б лежати після
# обслуговування; та сама семантика, що ShouldRestartAfterRestore у
# DataRestore.
$serviceWasRunning = @{
    Bravo = $BravoMaintenanceEnabled -and
        (Get-Service -Name $BravoServiceName -ErrorAction SilentlyContinue).Status -in @('Running', 'StartPending')
    ExchangeApi = $exchangAPIServiceEnabled -and
        (Get-Service -Name $ExchangAPIServiceName -ErrorAction SilentlyContinue).Status -in @('Running', 'StartPending')
    BravoWeb = $BravoWebMaintenanceEnabled -and
        (Get-Service -Name $BravoWebServiceName -ErrorAction SilentlyContinue).Status -in @('Running', 'StartPending')
}
# Профіль робочого часу (boot-recovery, $bootRestoreIgnoresWindow):
# «hold» — це ДЕТЕРМІНОВАНИЙ кінцевий стан (служби зупинені на час
# реставрації, запущені після неї), а НЕ знімок гонитви з Automatic
# (Delayed Start): службу, що ще НЕ встигла піднятися на момент знімка,
# SCM запустив би ПОСЕРЕД деструктивної фази реставрації, а після
# жорсткого переривання вона не мала б restart-intent у
# ownership-маркері. Тому кожна УВІМКНЕНА керована служба примусово
# трактується як «працювала»: зупинка нижче ідемпотентна (перевіряє
# фактичний стан), маркер покриває всі керовані служби, finally поверне
# все у Running.
if ($bootRestoreIgnoresWindow) {
    $serviceWasRunning.Bravo = $BravoMaintenanceEnabled
    $serviceWasRunning.ExchangeApi = $exchangAPIServiceEnabled
    $serviceWasRunning.BravoWeb = $BravoWebMaintenanceEnabled
}
# У boot-recovery профілю робочого часу ($bootRestoreIgnoresWindow) цей
# guard НЕ діє: прогін стартує одразу після boot, і якщо служби
# (Automatic Delayed Start) встигли піднятися раніше за задачу — зупинити
# їх негайно і є задачею утримання (клієнти ще не встигли зайти). На
# 24/7-профілі поведінка колишня: Recovery не зупиняє працюючі служби.
if ($RunMissedRestoreOnly -and $missedDailyWork -and -not $bootRestoreIgnoresWindow) {
    $runningServices = @()
    if ($serviceWasRunning.Bravo) { $runningServices += $BravoServiceName }
    if ($serviceWasRunning.ExchangeApi) { $runningServices += $ExchangAPIServiceName }
    if ($serviceWasRunning.BravoWeb) { $runningServices += $BravoWebServiceName }
    if ($runningServices.Count -gt 0) {
        # 'Pending' пишеться ЛИШЕ коли реставрація слоту реально ще не
        # виконана ($missedRestoreDue). Раніше state перезаписувався тут
        # БЕЗУМОВНО — і деградував уже записаний 'Succeeded' до
        # 'Pending', замовляючи ПОВТОРНУ реставрацію наступному прогону.
        # Реальний інцидент (production-сервер, 2026-08-20): Recovery-тик
        # 23:04 збігся з нічним BRAVO_ARCHIV (мітка Backup у
        # BRAVO_TASK_EXECUTION_STATE ще не оновлена -> хибний
        # $missedBackupTask -> ця гілка), guard затер Succeeded від 21:08
        # -> тик 23:18 виконав повну реставрацію слоту ВДРУГЕ за день.
        $message = if ($missedRestoreDue) {
            "Пропущена реставрація не виконана: уже працюють служби $($runningServices -join ', '). Recovery не зупиняє служби."
        } else {
            "Пропущені Backup/Maintenance не виконані: уже працюють служби $($runningServices -join ', '). Recovery не зупиняє служби. Реставрація слоту вже виконана раніше — її стан не змінюється."
        }
        Write-Log -Message $message -Level 'WARNING'
        if ($missedRestoreDue) {
            Write-BRAVORestoreState -ScheduledOccurrence $scheduledOccurrence -Status 'Pending' -Reason $message
        }
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

# Ownership-маркер зупинки служб — ПЕРЕД першою зупинкою. Якщо процес
# загине жорстко (kill/живлення) до finally, Health-watchdog за
# осиротілим маркером підніме РІВНО ці служби; ручні зупинки
# техпідтримки (без маркера) BRAVO не чіпає ніколи. Збій запису маркера
# абортує зупинку (fail-closed): без маркера аварія знову була б
# «мовчазною» — служби б лишились лежати без сліду власника.
$script:quiescenceMarkerWrittenThisRun = $false
# true = маркер зараз suppressed на час деструктивної фази реставрації
# (bravocmd) — див. Restore-BRAVOMaintenanceQuiescenceAutostart нижче.
$script:quiescenceMarkerSuppressedForRestore = $false
if ($stopServicesRequired) {
    $quiescenceServices = @()
    if ($serviceWasRunning.Bravo) { $quiescenceServices += @{ Name = $BravoServiceName; RestartIntent = $true } }
    if ($serviceWasRunning.ExchangeApi) { $quiescenceServices += @{ Name = $ExchangAPIServiceName; RestartIntent = $true } }
    if ($serviceWasRunning.BravoWeb) { $quiescenceServices += @{ Name = $BravoWebServiceName; RestartIntent = $true } }
    try {
        [void](Write-BRAVOServiceQuiescenceState `
            -Owner 'BRAVO_MAINTENANCE' `
            -Services $quiescenceServices `
            -LogFile ([string]$LOG_FILE))
        $script:quiescenceMarkerWrittenThisRun = $true
    } catch {
        $quiescenceMarkerError = "Не вдалося записати ownership-маркер зупинки служб — зупинку служб і обслуговування перервано (без маркера аварійне переривання лишило б служби зупиненими без автоматичного відновлення): $($_.Exception.Message)"
        Write-Log -Message $quiescenceMarkerError -Level 'ERROR'
        Send-SlackAlert -Message $quiescenceMarkerError -IsCritical
        throw $quiescenceMarkerError
    }
}

function Restore-BRAVOMaintenanceQuiescenceAutostart {
    # Зворотний бік suppressed-фази реставрації: модель знову
    # консистентна (успішний bravocmd без критичних змін АБО успішний
    # відкат з архіву перед реставрацією) — маркер перезаписується без
    # suppression, щоб при жорсткому перериванні РЕШТИ прогону watchdog
    # знову мав право підняти служби автоматично. Збій тут не фатальний:
    # suppressed-маркер безпечний (watchdog лише алертить), а graceful
    # finally і так стартує служби та прибере власний маркер.
    if (-not $script:quiescenceMarkerSuppressedForRestore) { return }
    try {
        [void](Write-BRAVOServiceQuiescenceState `
            -Owner 'BRAVO_MAINTENANCE' `
            -Services $quiescenceServices `
            -LogFile ([string]$LOG_FILE))
        $script:quiescenceMarkerSuppressedForRestore = $false
        Write-Log -Message "Ownership-маркер повернуто в режим автостарту: модель консистентна після фази реставрації" -Level "INFO"
    } catch {
        Write-Log -Message "Не вдалося зняти suppressed з ownership-маркера після фази реставрації: $($_.Exception.Message) — при жорсткому перериванні решти прогону watchdog лише алертитиме (без автостарту), мовчазної шкоди немає" -Level "WARNING"
    }
}

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
# dev.15: крок завжди рендериться (стабільна нумерація [N/8]) — SKIPPED
# 'вимкнено', коли перевірку розмірів вимкнено, а не пропуск номера кроку.
if ($script:BRAVOMaintenanceCheckSizeStepEnabled) {
    Check-MdFileSizes -MODEL_PATH $MODEL_PATH -MAX_MD_FILE_SIZE $MAX_MD_FILE_SIZE -ExcludePatterns $MD_FILE_SIZE_EXCLUSIONS
    Write-BRAVOMaintenanceStep `
        -Name 'Перевірка розмірів .md' `
        -Status (Get-BRAVOMaintenanceStepStatus `
            -CriticalBefore $checkSizeCriticalBefore `
            -WarningsBefore $checkSizeWarningsBefore)
} else {
    Write-BRAVOMaintenanceStep `
        -Name 'Перевірка розмірів .md' `
        -Status 'SKIPPED' `
        -Details 'вимкнено'
}

# ===== ОПЕРАЦІЇ ПІСЛЯ ЗУПИНКИ СЕРВІСІВ =====
Write-BRAVOProgressPhase -Phase 'Реставрація моделі' -PercentComplete 45
$restoreCriticalBefore = $script:criticalErrorOccurred
$restoreWarningsBefore = $script:BRAVOWarningCount
$restoreStepReported = $false
# Ініціалізується безумовно (не лише всередині бар'єрів нижче) — інакше під
# Set-StrictMode посилання на неї у fallback Details ('Реставрація моделі')
# кидає виняток, коли до бар'єрів узагалі не доходимо ($shouldRestore=false
# від самого початку, або службу BRAVO не вдалося зупинити).
$restorePostponedByWindowClosing = $false
# Знімок ДО restore-сесії — той самий безумовний-ініт ідіом, що вище: без
# цього снепшоту retention-гейт нижче (§9 задачі) не зможе відрізнити збій
# САМЕ цієї restore-сесії від збою якоїсь незалежної Trace-операції, що теж
# використовує ці два прапорці через Invoke-CommandWithLog.
$restoreArchiveFailedBefore = $script:restoreArchiveFailed
$restoreIntegrityFailedBefore = $script:restoreIntegrityFailed
$restoreSessionUnsafeForRetention = $false
# Компактні деталі кроку/сповіщення (task item 13) — безумовний-ініт, щоб
# Details нижче лишався валідним, навіть якщо repair цього циклу взагалі не
# запускався.
$restoreBravocmdExitCode = $null
$restoreRemovedByRepairCount = 0
$restoreCriticalCount = 0
$restoreRollbackStatus = 'NOT REQUIRED'
$restoreMainModelValid = $true
# true = реставрацію скасовано ДО bravocmd через збій переведення
# ownership-маркера в suppressed (fail-closed, критична помилка вже
# зарапортована в місці скасування).
$restoreAbortedBeforeDestructivePhase = $false
# Базові лічильники етапу «Обробка trace і логів» — до розгалуження за
# станом служби: підсумок етапу друкується в усіх гілках, зокрема й тоді,
# коли BRAVO зупинити не вдалося. Тут лише ІНІЦІАЛІЗАЦІЯ (щоб під
# Set-StrictMode змінні існували в кожній гілці рендеру); справжній зріз
# знімається безпосередньо перед фазою обробки логів — див. нижче.
$logsCriticalBefore = $script:criticalErrorOccurred
$logsWarningsBefore = $script:BRAVOWarningCount
$bravoStatus = if ($BravoMaintenanceEnabled) { (Get-Service -Name $BravoServiceName).Status } else { 'Unavailable' }
if ($BravoMaintenanceEnabled -and $bravoStatus -ne "Running") {
    # P0 TOCTOU barrier 1 (перед входом у restore sequence): $shouldRestore
    # обчислений задовго до цього місця (до Enter-BRAVOMaintenanceOperationLock,
    # тобто до OperationLockWaitMinutes очікування, і до зупинки служб вище)
    # — вікно могло вже закритися. Переоцінюємо ЗАРАЗ, а не довіряємо
    # старому знімку. Барʼєром не обмежуються -ForceRestore і boot-recovery
    # профілю робочого часу ($bootRestoreIgnoresWindow) — для них вікно не
    # є умовою легітимності операції.
    if ($shouldRestore -and -not $ForceRestore -and -not $bootRestoreIgnoresWindow -and
        -not (Test-BRAVORestoreExecutionStillAllowed `
            -WindowStart $parsedRestoreWindowStart -WindowEnd $parsedRestoreWindowEnd `
            -ForceRestore $ForceRestore)) {
        $restorePostponedByWindowClosing = $true
        $shouldRestore = $false
        Write-Log -Message (
            "Реставрацію відкладено: вікно $RestoreWindowStart-$RestoreWindowEnd закрилося під час " +
            "очікування lock/підготовки (заплановано було: $restoreReason). Плановий слот лишається " +
            "непозначеним як виконаний — наступний плановий Maintenance повторить спробу в межах вікна."
        ) -Level "WARNING"
    }
    if ($shouldRestore) {
        try {
            Write-Log -Message "==="
            Write-Log -Message "=== РЕСТАВРАЦІЯ МОДЕЛІ ==="
            Write-Log -Message "MODEL: base=$MODEL_PROJECT_PATH, directory=$MODEL_PATH, name=$MODEL_NAME, mainModelFile=$MAIN_MODEL_FILE" -Level "DEBUG"

            # before-CSV — невідʼємна частина реставрації: її self-валідація
            # (Compare-FileSizes нижче) виконується ЗАВЖДИ, незалежно від
            # окремого прапорця -DisableSizeCheck (той керує лише кроком
            # Check-MdFileSizes «.md > ліміт»). Без цього знімка перерваний/
            # провальний repair неможливо відрізнити від пошкодження.
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
                        RelativePath = Get-BRAVOModelRelativePath -FullName $_.FullName -RootPath $MODEL_PATH
                        SizeBytes = $_.Length
                    }
                }

            # Запис без BOM
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            $csvData = $initialSizes | ConvertTo-Csv -NoTypeInformation
            [System.IO.File]::WriteAllLines($SIZES_FILE, $csvData, $utf8NoBom)

            Write-Log -Message "Розміри файлів збережено: $SIZES_FILE" -Level "SUCCESS"

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

                # P0 TOCTOU barrier 2 (point-of-no-return): останній момент
                # перед ДЕСТРУКТИВНИМ bravocmd.exe. Barrier 1 (перед входом у
                # цю послідовність) не покриває час самої архівації моделі
                # перед реставрацією (7-Zip на великій моделі може тривати
                # довго) — вікно могло закритися саме тут. Барʼєром не
                # обмежуються -ForceRestore і boot-recovery профілю робочого
                # часу ($bootRestoreIgnoresWindow).
                if (-not $bootRestoreIgnoresWindow -and
                    -not (Test-BRAVORestoreExecutionStillAllowed `
                        -WindowStart $parsedRestoreWindowStart -WindowEnd $parsedRestoreWindowEnd `
                        -ForceRestore $ForceRestore)) {
                    $restorePostponedByWindowClosing = $true
                    $exitCode = $null
                    Write-Log -Message (
                        "Реставрацію скасовано безпосередньо перед bravocmd.exe: вікно " +
                        "$RestoreWindowStart-$RestoreWindowEnd закрилося під час архівації моделі перед " +
                        "реставрацією. bravocmd.exe НЕ викликано; архів перед реставрацією збережено: " +
                        "$beforeArchivePath. Плановий слот лишається непозначеним як виконаний — " +
                        "наступний плановий Maintenance повторить спробу в межах вікна."
                    ) -Level "WARNING"
                } else {
                    # Suppressed-фаза (quiescence): на час деструктивного
                    # bravocmd маркер перемикається в suppressed — якщо процес
                    # загине ЖОРСТКО посеред реставрації, Health-watchdog НЕ
                    # підніме служби поверх напіввідновленої моделі, а лише
                    # дасть CRITICAL-алерт про ручне відновлення (та сама
                    # семантика, що маркер DataRestore). Збій suppression =
                    # реставрація НЕ починається (fail-closed: модель ще не
                    # торкнута, збереження поточного стану безпечне).
                    $quiescenceSuppressionReady = $true
                    if ($script:quiescenceMarkerWrittenThisRun) {
                        try {
                            [void](Set-BRAVOServiceQuiescenceRestartSuppressed)
                            $script:quiescenceMarkerSuppressedForRestore = $true
                        } catch {
                            $quiescenceSuppressionReady = $false
                            $restoreAbortedBeforeDestructivePhase = $true
                            $exitCode = $null
                            $errorMsg = "Реставрацію скасовано перед bravocmd.exe: не вдалося перевести ownership-маркер у suppressed (жорстке переривання посеред реставрації призвело б до автостарту служб поверх напіввідновленої моделі): $($_.Exception.Message). Модель не торкнута; архів перед реставрацією збережено: $beforeArchivePath"
                            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
                            Send-SlackAlert -Message $errorMsg -IsCritical
                            $script:criticalErrorOccurred = $true
                            $script:restoreArchiveFailed = $true
                        }
                    }
                    if ($quiescenceSuppressionReady) {
                        # Виконання реставрації через bravocmd.exe (як в еталоні)
                        $restoreArgs = @("r", "null", $MODEL_PROJECT_PATH)
                        # Без суфікса продукту в описі: проєкт моделі може бути
                        # будь-яким (назва деривується з bravo.ini MODEL=), тож
                        # операторський підстатус показує фактичне ім'я моделі.
                        $exitCode = Invoke-CommandWithLog -Command $BRAVOCMD_PATH -Arguments $restoreArgs -Description "Виконання реставрації моделі ($MODEL_NAME)"
                        $restoreBravocmdExitCode = $exitCode
                    }
                }

                if ($restorePostponedByWindowClosing -or $restoreAbortedBeforeDestructivePhase) {
                    # bravocmd не викликаний (пауза через вікно — не помилка;
                    # скасування через suppression уже зарапортоване вище як
                    # критичне), маркер/state не пишуться, гілки exitCode
                    # -eq/-ne 0 нижче свідомо не виконуються (exitCode -eq
                    # $null для обох).
                } else {
                    # bravocmd викликано (не пауза/скасування): результат
                    # обробляє єдина функція відновлення, яка САМА вирішує, чи
                    # потрібен відкат — за фактичним станом моделі, а не лише за
                    # кодом виходу. Перерваний/провальний repair (exit≠0) тепер
                    # теж проходить перевірку й, за потреби, відкат (раніше він
                    # лишав модель без перевірки й без відкату).
                    $restoreBravocmdSucceeded = ($exitCode -eq 0)
                    if ($restoreBravocmdSucceeded) {
                        Write-Log -Message "bravocmd.exe завершено, код 0. Перевірка результату repair..." -Level "INFO"
                    } else {
                        Write-Log -Message "bravocmd.exe завершено з кодом $exitCode — реставрацію не підтверджено. Перевірка стану моделі..." -Level "WARNING"
                    }

                    # Hint головної моделі — від канонічного $MAIN_MODEL_FILE тим
                    # самим правилом Get-BRAVOModelRelativePath, що й writer
                    # before-CSV (покриває MODEL= у підкаталозі). Якщо .md не під
                    # $MODEL_PATH — hint не передаємо: строгий режим (будь-який
                    # відсутній файл критичний).
                    $mainModelRelativeHint = Get-BRAVOModelRelativePath -FullName $MAIN_MODEL_FILE -RootPath $MODEL_PATH
                    if ([string]::IsNullOrWhiteSpace($mainModelRelativeHint) -or
                        $mainModelRelativeHint -ieq $MAIN_MODEL_FILE) {
                        Write-Log -Message ("Головна модель '$MAIN_MODEL_FILE' не знаходиться в каталозі MODEL " +
                            "'$MODEL_PATH'; перевірка виконується у строгому режимі (будь-який відсутній файл критичний)") -Level "WARNING"
                        $mainModelRelativeHint = $null
                    }

                    # Механізм перевірки+відкату — невідʼємна частина реставрації,
                    # виконується завжди (незалежно від -DisableSizeCheck).
                    $recovery = Invoke-BRAVOModelRestoreRecovery `
                        -BravocmdExitCode $exitCode `
                        -BeforeFile $SIZES_FILE `
                        -ModelPath $MODEL_PATH `
                        -MainModelRelativePath $mainModelRelativeHint `
                        -BeforeArchivePath "$ARC_DIR\$ARCH_NAME1" `
                        -ARC_PATH $ARC_PATH `
                        -MinSizeBytes 2048
                    $restoreRemovedByRepairCount = $recovery.RemovedByRepairCount
                    $restoreCriticalCount = $recovery.CriticalCount
                    $restoreMainModelValid = $recovery.MainModelValid
                    $restoreRollbackStatus = $recovery.RollbackStatus
                    $script:modelIntegrityEstablished = $recovery.IntegrityEstablished

                    # Модель консистентна (repair ok / ціла після переривання /
                    # успішний відкат) — повертаємо watchdog право автостарту.
                    if ($recovery.IntegrityEstablished) {
                        Restore-BRAVOMaintenanceQuiescenceAutostart
                    }

                    # Справжній успіх лише коли bravocmd завершився 0 І модель
                    # консистентна БЕЗ відкату (repair дійсно вдався).
                    $restoreTrulySucceeded = (
                        $restoreBravocmdSucceeded -and
                        -not $recovery.HasCriticalChanges -and
                        $recovery.IntegrityEstablished
                    )

                    if ($restoreTrulySucceeded) {
                        $restoreCompletedAt = Get-Date
                        # Валідація пройдена — лише тепер репарацію можна
                        # вважати успішною.
                        $removedByRepairSuffix = if ($restoreRemovedByRepairCount -gt 0) {
                            " (repair прибрав $restoreRemovedByRepairCount сегментних файл(ів), критичних змін немає)"
                        } else {
                            ""
                        }
                        Write-Log -Message "Модель успішно відреставрована$removedByRepairSuffix" -Level "SUCCESS"

                        # Реставрація успішна, критичних змін немає — модель
                        # консистентна; повертаємо watchdog право автостарту
                        # ЩЕ ДО тривалої архівації після реставрації.
                        Restore-BRAVOMaintenanceQuiescenceAutostart
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
                        if ($afterArchiveReady -and -not $ForceRestore) {
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
                        } elseif ($afterArchiveReady -and $ForceRestore) {
                            # Примусова реставрація свідомо НЕ закриває плановий
                            # слот (маркер і Status='Succeeded' лишаються за
                            # автоматичним шляхом), але СПОЖИВАЄ тижневу квоту:
                            # модель уже реставрували, тож наступний плановий
                            # слот пропускається. Записуємо саме той слот, який
                            # покрито, — наступний після поточного.
                            $forcedCoversSlot = $scheduledOccurrence.AddDays(7)
                            Write-BRAVORestoreForcedOutcome -CoveredSlot $forcedCoversSlot -CompletedAt ([datetime]::Now)
                            Write-Log -Message (
                                "Примусова реставрація виконана успішно: плановий слот " +
                                "$($forcedCoversSlot.ToString('yyyy-MM-dd HH:mm')) буде пропущено " +
                                "(автоматична реставрація — не частіше разу на тиждень)."
                            ) -Level "INFO"
                        }
                    } else {
                        # Реставрація НЕ успішна: bravocmd перервано/впав, або
                        # repair дав критичні зміни (виконано/спробувано відкат).
                        # after-архів і маркер успіху НЕ створюються.
                        $script:restoreFailed = $true
                        $script:criticalErrorOccurred = $true
                        if ($recovery.IntegrityEstablished) {
                            # Модель консистентна (ціла після переривання або
                            # успішно відкочена) — служби можна піднімати.
                            # Категоризація коду виходу: це саме RestoreFailed
                            # (43), а не LocalArchiveFailed(40)/IntegrityTest(41).
                            # Ті два прапорці тут хибно виставлені як побічний
                            # ефект: Invoke-CommandWithLog ставить
                            # restoreArchiveFailed на будь-який ненульовий код
                            # (вбитий bravocmd), а Compare-FileSizes —
                            # restoreIntegrityFailed на первинних критичних
                            # змінах ДО відкату. Фінальний стан — відновлено й
                            # консистентно, тож скидаємо їх і лишаємо лише
                            # restoreFailed(43). before-архів створено успішно
                            # (інакше до цієї гілки не дійшли б), тож справжнього
                            # LocalArchiveFailed тут бути не може.
                            $script:restoreArchiveFailed = $false
                            $script:restoreIntegrityFailed = $false
                            $stateSuffix = if ($restoreRollbackStatus -eq 'SUCCESS') {
                                'модель відновлено з before-архіву'
                            } else {
                                'модель не постраждала'
                            }
                            Write-Log -Message "Реставрація не завершилась успішно (bravocmd exit=$restoreBravocmdExitCode, rollback=$restoreRollbackStatus); $stateSuffix. Архів до реставрації збережено: $ARC_DIR\$ARCH_NAME1. after-архів і маркер успіху не створюються." -Level "ERROR"
                            Send-SlackAlert -Message "Реставрація не завершилась успішно, але модель консистентна ($stateSuffix). Плановий слот не позначено виконаним." -IsCritical
                        } else {
                            # Цілісність НЕ встановлено (відкат провалився або
                            # before-архів невалідний) — служби НЕ піднімати
                            # (гейт нижче), потрібне ручне відновлення.
                            # CRITICAL-алерт уже надіслано у Invoke-BRAVOModelRestoreRecovery.
                            Write-Log -Message "Реставрація провалилась і цілісність моделі НЕ встановлено (rollback=$restoreRollbackStatus). Служби BRAVO не піднімаються — потрібне ручне відновлення з $ARC_DIR\$ARCH_NAME1." -Level "ERROR"
                        }
                    }
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
        # Retention-гейт (task item 9): знімок ДО/ПІСЛЯ (той самий ідіом, що
        # $restoreCriticalBefore/$restoreWarningsBefore вище) — а не сирі
        # поточні значення прапорців, бо ті самі два прапорці також
        # виставляє незалежна Trace-архівація через Invoke-CommandWithLog
        # (напр. рядок ~3315). Розширювати гейт на такі несуміжні збої не
        # потрібно — лише на збій САМЕ цієї restore-сесії.
        # Умова обчислюється всередині if ($shouldRestore) — додатковий
        # $shouldRestore тут завжди був true.
        $restoreSessionUnsafeForRetention = (
            ($script:restoreArchiveFailed -and -not $restoreArchiveFailedBefore) -or
            ($script:restoreIntegrityFailed -and -not $restoreIntegrityFailedBefore)
        )
        # Компактні деталі кроку (task item 13) — повний файловий список
        # лишається лише в Write-Log/Send-SlackAlert вище (authoritative log).
        $restoreStepDetails = $restoreReason
        if ($null -ne $restoreBravocmdExitCode) {
            $mainModelStatusText = if ($restoreMainModelValid) { 'OK' } else { 'FAIL' }
            $restoreStepDetails += (
                " | bravocmd exit=$restoreBravocmdExitCode | RemovedByRepair=$restoreRemovedByRepairCount " +
                "| Critical=$restoreCriticalCount | Rollback=$restoreRollbackStatus | MainModel=$mainModelStatusText"
            )
        }
        Write-BRAVOMaintenanceStep `
            -Name 'Реставрація моделі' `
            -Status (Get-BRAVOMaintenanceStepStatus `
                -CriticalBefore $restoreCriticalBefore `
                -WarningsBefore $restoreWarningsBefore) `
            -Details $restoreStepDetails
        $restoreStepReported = $true
    }

    # Обробка Trace належить лише до компонента основної служби BRAVO.
    #
    # Зріз лічильників пересвіжується САМЕ ТУТ, після завершення
    # реставрації: початкова ініціалізація вище знімається ДО неї, тому
    # критична помилка реставрації опинялася "новою" для цього етапу і
    # фарбувала його в FAIL. Реальний DEV-LIMS негативний прогін 19:48
    # (bravocmd вбито -> exit 43) показав [6/8] FAIL з деталями
    # "оброблено файлів: 2" — тобто етап відпрацював, а червоним був через
    # чужу помилку. Статус етапу мусить відображати ЙОГО ВЛАСНИЙ результат.
    $logsCriticalBefore = $script:criticalErrorOccurred
    $logsWarningsBefore = $script:BRAVOWarningCount
    Write-BRAVOProgressPhase -Phase 'Обробка trace і логів' -PercentComplete 60
    try {
        if ($BravoMaintenanceEnabled) {
            Write-Log -Message "==="
            Write-Log -Message "=== ОБРОБКА TRACE-ФАЙЛІВ ===" -Level "INFO"
            # SRV з невалідною конфігурацією вже прапорцьований критичною
            # помилкою у блоці джерел — тут він просто пропускається
            # (порожній Path), НЕ блокуючи ротацію BIS.
            # Джерела вже перелічені один раз у блоці "ДЖЕРЕЛА ЖУРНАЛІВ"
            # (скан усіх *.out кореня інсталяції + SRV/BIS поза коренем).
            # Порожній перелік — легальний стан (скан неможливий/файлів
            # немає): ротація сама віддасть підсумок "файлів немає".
            $traceRotationSummary = Invoke-BRAVOTraceRotation `
                -Sources @($traceOutSources) `
                -DestinationDirectory $TRACE_DIR `
                -RetryCount $MoveRetryCount `
                -RetryDelaySeconds $MoveRetryDelaySeconds `
                -Logger $bravoLogRotationLogger
            $traceOutputProcessedCount = [int]$traceRotationSummary.Moved
            $traceOutputProcessed = ($traceOutputProcessedCount -gt 0)
            if ([int]$traceRotationSummary.Errors -gt 0) {
                $script:criticalErrorOccurred = $true
            }
        }
    }
    catch {
        $errorMsg = "Помилка при обробці Trace-файлів: $($_.Exception.Message)"
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
        Send-SlackAlert -Message $errorMsg -IsCritical
        $script:criticalErrorOccurred = $true
    }
}
elseif ($BravoMaintenanceEnabled) {
    $errorMsg = "Сервіс $($BravoServiceName) все ще працює. Операції з файлами пропущено."
    Write-Log -Message $errorMsg -Level "ERROR"
    Send-SlackAlert -Message $errorMsg -IsCritical
    $script:criticalErrorOccurred = $true
}

# Компонент exchangAPI обробляється незалежно, але лише за наявності
# встановленої та не відключеної служби — і лише коли вона фактично
# зупинена: переміщувати журнал з-під працюючого застосунку означає або
# отримати відмову доступу, або відрізати частину записів.
if ($exchangAPIServiceEnabled) {
    $exchangAPIStatus = try {
        [string](Get-Service -Name $ExchangAPIServiceName -ErrorAction Stop).Status
    } catch {
        'Unknown'
    }
    if ($exchangAPIStatus -eq 'Stopped') {
        try {
            Write-Log "==="
            Write-Log -Message "=== ОБРОБКА ЛОГІВ EXCHANGAPI ===" -Level "INFO"
            # Плоске призначення (без каталогу-дати): нова модель зберігає
            # оригінальні імена і пакує їх у добовий exchangAPI_YYYYMMDD.mdz
            # тим самим движком, що Trace; legacy каталоги-дати не чіпаються.
            $exchangeRotationSummary = Invoke-BRAVOExchangeApiLogRotation `
                -SourceDirectory ([string]$exchangeApiRuntime.Directory) `
                -DestinationDirectory $EXCHANGE_LOG_DIR `
                -Patterns $EXCHANGAPI_LOG_FILTERS `
                -RetryCount $MoveRetryCount `
                -RetryDelaySeconds $MoveRetryDelaySeconds `
                -Logger $bravoLogRotationLogger
            $exchangAPILogsFoundCount = [int]$exchangeRotationSummary.Found
            $exchangAPILogsProcessedCount = [int]$exchangeRotationSummary.Moved
            if ([int]$exchangeRotationSummary.Errors -gt 0) {
                $script:criticalErrorOccurred = $true
            }
        } catch {
            $errorMsg = "Помилка при обробці логів exchangAPI: $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
        }
    } else {
        Write-Log -Message "Ротацію логів exchangAPI пропущено: службу $ExchangAPIServiceName не зупинено (стан: $exchangAPIStatus)" -Level "WARNING"
    }
}

# Компонент BRAVO Web обробляється лише за наявності активної служби,
# необхідних каталогів і фактично зупиненого Apache: httpd тримає
# access.log/error.log відкритими, доки працює.
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    $bravoWebStatus = try {
        [string](Get-Service -Name $BravoWebServiceName -ErrorAction Stop).Status
    } catch {
        'Unknown'
    }
    if ($bravoWebStatus -eq 'Stopped') {
        try {
            Write-Log "==="
            Write-Log -Message "=== ОБРОБКА ЛОГІВ APACHE ===" -Level "INFO"
            $apacheRotationSummary = Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $APACHE_LOGS_DIR `
                -DestinationDirectory $APACHE_DAILY_LOG_DIR `
                -Filter $APACHE_LOG_FILTER `
                -RetryCount $MoveRetryCount `
                -RetryDelaySeconds $MoveRetryDelaySeconds `
                -Logger $bravoLogRotationLogger
            $webApacheLogsProcessedCount = [int]$apacheRotationSummary.Moved

            Write-Log -Message "==="
            Write-Log -Message "=== ОБРОБКА ЛОГІВ BRAVO WEB APPLICATION ===" -Level "INFO"
            $webApplicationRotationSummary = Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $WWW_LOGS_DIR `
                -DestinationDirectory $BRAVOWEB_APP_DAILY_LOG_DIR `
                -Filter $BRAVOWEB_APP_LOG_FILTER `
                -RetryCount $MoveRetryCount `
                -RetryDelaySeconds $MoveRetryDelaySeconds `
                -Logger $bravoLogRotationLogger
            $webWwwLogsProcessedCount = [int]$webApplicationRotationSummary.Moved

            if ([int]$apacheRotationSummary.Errors -gt 0 -or
                [int]$webApplicationRotationSummary.Errors -gt 0) {
                $script:criticalErrorOccurred = $true
            }
        } catch {
            $errorMsg = "Помилка при обробці логів BRAVO Web: $($_.Exception.Message)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
        }
    } else {
        Write-Log -Message "Ротацію логів BRAVO Web пропущено: службу $BravoWebServiceName не зупинено (стан: $bravoWebStatus)" -Level "WARNING"
    }
}

# Реставрація моделі — стабільний крок [5/8], завжди рендериться, і має
# рендеритись ДО «Обробка trace і логів» [6/8] — той самий порядок, що в
# затвердженому operator contract, незалежно від того, чи справді
# виконувалась реставрація цього прогону. Сюди потрапляємо, якщо основна
# гілка (рядок ~4680, $shouldRestore) її не надрукувала — з трьох причин,
# які варто розрізняти в Details:
# - вікно закрилося під час очікування lock/підготовки (Barrier 1) — було
#   заплановано, безпечно відкладено, наступний daily Recovery повторить;
# - $shouldRestore було true, але службу BRAVO не вдалося зупинити —
#   заплановане й невиконане, а не «не настав час»;
# - $shouldRestore було false від самого початку — реставрація цього
#   прогону не планувалась взагалі (dev.15: раніше цей випадок не
#   рендерив крок взагалі, номер кроку "з'їдався").
# dev.15 (виправлення порядку): цей fallback раніше стояв ПІСЛЯ рендеру
# «Обробка trace і логів» нижче — коли $shouldRestore=false (типовий
# щоденний прогін без запланованої реставрації), Logs встигав зайняти
# номер [5/8], а Restore-SKIPPED зсувався на [6/8], міняючи затверджений
# порядок місцями. Переміщено вище рендеру Logs, щоб порядок номерів
# лишався стабільним у БУДЬ-якому сценарії.
if (-not $restoreStepReported) {
    Write-BRAVOMaintenanceStep `
        -Name 'Реставрація моделі' `
        -Status 'SKIPPED' `
        -Details $(
            if ($restorePostponedByWindowClosing) { 'вікно закрилося під час очікування lock/підготовки' }
            elseif ($shouldRestore) { 'службу BRAVO не було зупинено' }
            elseif ($weeklyRestoreQuotaConsumed) { 'цього тижня вже виконано примусову' }
            else { 'не заплановано на цей запуск' }
        )
}

# Підсумковий рядок етапу — поза блоком BRAVO Web. Раніше він стояв
# усередині нього, тому на інсталяції без Apache етап «Обробка trace і
# логів» щоразу друкувався як SKIPPED «службу BRAVO не було зупинено»,
# хоча trace і exchangAPI щойно успішно оброблені.
# dev.15: крок завжди рендериться (стабільна нумерація [N/8]); окремий
# SKIPPED 'вимкнено', коли компонент BRAVO взагалі вимкнено.
if (-not $script:BRAVOMaintenanceLogsStepEnabled) {
    Write-BRAVOMaintenanceStep `
        -Name 'Обробка trace і логів' `
        -Status 'SKIPPED' `
        -Details 'вимкнено'
} elseif ($bravoStatus -eq 'Running') {
    # Заплановане й невиконане, а не «не настав час»: службу BRAVO не
    # вдалося зупинити, тому жодного журналу не чіпали.
    Write-BRAVOMaintenanceStep `
        -Name 'Обробка trace і логів' `
        -Status 'SKIPPED' `
        -Details 'службу BRAVO не було зупинено'
} else {
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
}

} finally {
Write-BRAVOProgressPhase -Phase 'Відновлення стану служб' -PercentComplete 75
$restoreServicesCriticalBefore = $script:criticalErrorOccurred
$restoreServicesWarningsBefore = $script:BRAVOWarningCount
Write-Log -Message "==="
Write-Log -Message "=== ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ ==="
# Ownership-маркер можна прибрати лише коли ВСІ старти нижче успішні;
# інакше він лишається, і Health-watchdog доспробує підняти служби.
$serviceRestartFailed = $false

# Fail-closed гейт (інваріант 07): якщо після ДЕСТРУКТИВНОЇ фази реставрації
# цілісність моделі НЕ встановлено (перерваний repair без успішного відкату
# чи невалідний before-архів) — служби BRAVO НЕ піднімаємо, щоб не подавати
# неперевірену/пошкоджену модель. Маркер quiescence лишається suppressed
# ($serviceRestartFailed=$true нижче не дає його прибрати), тож Health-watchdog
# служби теж не підніме, лише алертитиме — до ручного відновлення оператором.
if (-not $script:modelIntegrityEstablished) {
    $errorMsg = "Служби BRAVO НЕ піднято: цілісність моделі не встановлено після перерваної реставрації — потрібне ручне відновлення з before-архіву ($ARC_DIR\$ARCH_NAME1)."
    Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
    Send-SlackAlert -Message $errorMsg -IsCritical
    $script:criticalErrorOccurred = $true
    $serviceRestartFailed = $true
}

# 1. Запуск служби BRAVO
try {
    if ($script:modelIntegrityEstablished -and $serviceWasRunning.Bravo -and (Get-Service -Name $BravoServiceName).Status -ne 'Running') {
        Write-Log -Message "Запуск служби $BravoServiceName..." -Level "INFO"
        $serviceResult = Invoke-ServiceStateChange `
            -Name $BravoServiceName `
            -DesiredStatus Running `
            -TimeoutSeconds $ServiceStartTimeoutSeconds `
            -PollIntervalSeconds $ServicePollIntervalSeconds
        if ($serviceResult.Success) {
            Write-Log -Message "Служба $BravoServiceName успішно запущена" -Level "SUCCESS"
            $script:bravoServiceStartedThisRun = $true
        } else {
            $errorMsg = "$BravoServiceName не запустився автоматично: $($serviceResult.Error)"
            Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
            Send-SlackAlert -Message $errorMsg -IsCritical
            $script:criticalErrorOccurred = $true
            $serviceRestartFailed = $true
        }
    }
} catch {
    $errorMsg = "Помилка при запуску ${BravoServiceName}: $($_.Exception.Message)"
    Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
    Send-SlackAlert -Message $errorMsg -IsCritical
    $script:criticalErrorOccurred = $true
    $serviceRestartFailed = $true
}

# Діагностика, не перевірка: BRAVO створює trace лише під час першої
# debug-події, тому його відсутність одразу після старту нормальна. Рядок
# у журналі потрібен лише для того, щоб при розборі інциденту було видно
# фактичний стан, а не доводилося здогадуватись. На exit code не впливає.
if ($BravoMaintenanceEnabled -and $null -ne $traceConfiguration -and $traceConfiguration.IsValid) {
    $traceRecreated = Test-Path -LiteralPath $traceConfiguration.TracePath -PathType Leaf
    Write-Log -Message (
        "BRAVO Trace після запуску служби: $(if ($traceRecreated) { 'створено заново' } else { 'ще не створено (очікувано до першої debug-події)' }) — $($traceConfiguration.TracePath)"
    ) -Level "INFO"
}

# 2. Запуск exchangAPI лише через встановлену та не відключену Windows-службу
# (не піднімаємо, якщо цілісність моделі не встановлено — той самий гейт).
if ($script:modelIntegrityEstablished -and $serviceWasRunning.ExchangeApi) {
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
        $serviceRestartFailed = $true
    }
}

# 3. Запуск BRAVO Web (виконується останнім; той самий гейт цілісності)
if ($script:modelIntegrityEstablished -and $serviceWasRunning.BravoWeb) {
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
        $serviceRestartFailed = $true
    }
}

# Ownership-маркер: прибираємо лише ВЛАСНИЙ (записаний цим прогоном) і
# лише після ПОВНОГО відновлення служб. Чужий/осиротілий маркер від
# попереднього аварійного прогону цей код не чіпає — його опрацьовує
# Health-watchdog. Частковий збій старту → маркер лишається.
if ($script:quiescenceMarkerWrittenThisRun -and -not $serviceRestartFailed) {
    try {
        # Clear захищений: видаляє лише маркер, записаний ЦИМ процесом
        # (pid+processStartTime). Якщо маркер перезаписав інший власник
        # (перетин з DataRestore) — повертає $false і не чіпає чужий.
        $quiescenceMarkerCleared = Clear-BRAVOServiceQuiescenceState
        if (-not $quiescenceMarkerCleared) {
            Write-Log -Message "Ownership-маркер зупинки служб не видалено: він уже належить іншому процесу (перетин власників) — залишено без змін" -Level "WARNING"
        }
    } catch {
        Write-Log -Message "Не вдалося прибрати ownership-маркер зупинки служб: $($_.Exception.Message) — Health-watchdog побачить осиротілий маркер і мовчазної шкоди не буде" -Level "WARNING"
    }
} elseif ($script:quiescenceMarkerWrittenThisRun) {
    Write-Log -Message "Ownership-маркер зупинки служб збережено: не всі служби запустились — Health-watchdog повторить спробу автоматично" -Level "WARNING"
}

Write-BRAVOMaintenanceStep `
    -Name 'Відновлення стану служб' `
    -Status (Get-BRAVOMaintenanceStepStatus `
        -CriticalBefore $restoreServicesCriticalBefore `
        -WarningsBefore $restoreServicesWarningsBefore)
}

# dev.15: усе від Range ID до Send-FinalReport раніше не мало жодного
# захисту від винятків — необроблена помилка будь-де в цьому діапазоні
# (Cleanup/Archive-launch/AutoShutdown/Send-FinalReport) пропускала решту
# зовнішнього try (4474) аж до фінального summary й одразу потрапляла у
# зовнішній finally (Wait-BRAVOManualExit, рядок ~5512) — оператор бачив
# останній надрукований крок і одразу "Натисніть будь-яку клавішу...",
# без жодного підсумку. Тепер будь-яка помилка тут логується/позначає
# criticalErrorOccurred, але виконання ГАРАНТОВАНО доходить до обчислення
# exit code і друку фінального summary нижче.
#
# dev.16: $script:currentMaintenanceOperation називає активну операцію
# цього діапазону для catch нижче — щоб повідомлення про необроблену
# помилку називало конкретну дію ("Помилка операції ..."), а не
# generic "Range ID/очистка/BRAVO_ARCHIV/AutoShutdown/фінальний звіт".
# Кожен подальший блок оновлює цю змінну перед своїм початком.
try {

$script:currentMaintenanceOperation = 'Контроль діапазонів ID'
if ($BravoMaintenanceEnabled -and $RangeIdMonitoringEnabled) {
    if ($RangeIdCheckDelaySeconds -gt 0) {
        Start-Sleep -Seconds $RangeIdCheckDelaySeconds
    }
    # dev.14 (round 3): відсутній/непрочитаний/перевищений Range ID —
    # non-blocking WARN, а не критична помилка Maintenance. Test-RangeIdUsage
    # усередині й далі викликає Send-SlackAlert -IsCritical — це навмисно
    # НЕ чіпаємо (delivery severity): -IsCritical гарантує, що сповіщення
    # дійде навіть у NotificationMode=errors_only, і ця частина поведінки
    # незмінна. Але Send-SlackAlert -IsCritical заразом ставить
    # $script:criticalErrorOccurred = $true — а ЦЕ вже execution severity
    # Maintenance (веде до "ПОМИЛКА"/exit 60). Ці два свідомо розв'язані:
    # снепшот/відкат нижче скасовує ЛИШЕ прапорець критичності, і ЛИШЕ якщо
    # саме цей виклик його підняв (якщо він уже був true до виклику —
    # від чогось іншого, — не займаємо його). CriticalErrorsList/сповіщення
    # errors_only Send-SlackAlert формує так само, як і раніше.
    # Якщо службу BRAVO запускав саме цей прогін, файл діапазонів ID може
    # ще не існувати — BRAVO створює його асинхронно після старту. Bounded-
    # очікування (до 30 сек., крок 5 сек.) застосовується ЛИШЕ коли файл
    # відсутній І службу запускали ми: звичайний прогін з наявним файлом не
    # отримує жодної затримки, а прогін без рестарту служби зберігає
    # негайний WARNING, як раніше. Якщо файл так і не з'явився —
    # Test-RangeIdUsage нижче формує рівно один WARNING з текстом таймауту.
    $rangeIdWaitTimeoutSeconds = if ($script:bravoServiceStartedThisRun) { 30 } else { 0 }
    $rangeIdFileAppeared = Wait-BRAVORangeIdLogFile `
        -Path $RangeIdLogPath `
        -TimeoutSeconds $rangeIdWaitTimeoutSeconds
    $rangeIdWaitedForFileSeconds = if (-not $rangeIdFileAppeared -and $rangeIdWaitTimeoutSeconds -gt 0) {
        $rangeIdWaitTimeoutSeconds
    } else {
        0
    }
    $rangeIdWarningsBefore = $script:BRAVOWarningCount
    $rangeIdCriticalBefore = $script:criticalErrorOccurred
    $rangeIdCheckResult = Test-RangeIdUsage -Path $RangeIdLogPath -ThresholdPercent $RangeIdThresholdPercent -WaitedForFileSeconds $rangeIdWaitedForFileSeconds
    $rangeIdHasWarning = $script:BRAVOWarningCount -gt $rangeIdWarningsBefore
    if (-not $rangeIdCriticalBefore -and $script:criticalErrorOccurred) {
        $script:criticalErrorOccurred = $false
    }
    $rangeIdDetail = if (-not $rangeIdHasWarning) {
        $null
    } elseif ($null -ne $rangeIdCheckResult -and -not [string]::IsNullOrWhiteSpace([string]$rangeIdCheckResult.Reason)) {
        [string]$rangeIdCheckResult.Reason
    } else {
        'перевірте лог для деталей'
    }
    Write-BRAVOMaintenanceStep `
        -Name 'Контроль діапазонів ID' `
        -Status $(if ($rangeIdHasWarning) { 'WARN' } else { 'OK' }) `
        -Details $rangeIdDetail
} else {
    # dev.15: крок завжди рендериться (стабільна нумерація [N/8]) — SKIPPED
    # 'вимкнено', коли компонент BRAVO або сам контроль діапазонів вимкнено.
    Write-BRAVOMaintenanceStep `
        -Name 'Контроль діапазонів ID' `
        -Status 'SKIPPED' `
        -Details 'вимкнено'
}

# ---------------------------------------------------------------------------
# Первинна (одноразова) очистка legacy-артефактів ери ARCHIV_LIMS-предка.
# Маркер-гейтована: виконується РІВНО один раз (перший прогін, де маркер
# ще відсутній), потім ПОСТІЙНО пропускається — на відміну від
# Remove-BRAVOEmptyLogDateDirectories (P2, щопрогінна, без стану), яка
# продовжує діяти завжди. Той самий атомарний GUID-tmp+[IO.File]::Replace
# патерн, що BRAVO_SERVICE_QUIESCENCE.json/BRAVO_VSS_OWNERSHIP.json
# (modules\BRAVO.System\BRAVO.System.psm1) — свідомо самодостатня (без
# залежності від Configuration.Derivation $stateRoot), як і той зразок.
# ---------------------------------------------------------------------------

function Get-BRAVOLegacySweepStatePath {
    $programDataRoot = [Environment]::GetFolderPath('CommonApplicationData')
    if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
        throw 'CommonApplicationData недоступний для legacy-sweep state'
    }
    return Join-Path $programDataRoot 'BRAVO\State\BRAVO_LEGACY_SWEEP_STATE.json'
}

function Write-BRAVOLegacySweepState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SweptBy
    )

    $stateDirectory = Split-Path -Path $Path -Parent
    if (-not [IO.Directory]::Exists($stateDirectory)) {
        [void][IO.Directory]::CreateDirectory($stateDirectory)
    }
    $state = [ordered]@{
        schemaVersion = 1
        sweptAt = (Get-Date).ToString('o')
        sweptBy = [string]$SweptBy
    }
    $temporaryStatePath = Join-Path $stateDirectory ('.BRAVO_LEGACY_SWEEP_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backupStatePath = Join-Path $stateDirectory ('.BRAVO_LEGACY_SWEEP_{0}.bak' -f [guid]::NewGuid().ToString('N'))
    $stateReplaced = $false
    try {
        $json = $state | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($temporaryStatePath, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) {
            # .NET Framework відхиляє null-backup у Replace — тому явний шлях.
            [IO.File]::Replace($temporaryStatePath, $Path, $backupStatePath)
            $stateReplaced = $true
        } else {
            [IO.File]::Move($temporaryStatePath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporaryStatePath)) {
            [IO.File]::Delete($temporaryStatePath)
        }
        if ($stateReplaced -and [IO.File]::Exists($backupStatePath)) {
            Remove-Item -LiteralPath $backupStatePath -Force -ErrorAction SilentlyContinue
        }
    }
    return $state
}

function Read-BRAVOLegacySweepState {
    # $null = маркера немає АБО він нечитабельний/пошкоджений/незнайомий
    # schemaVersion. Fail-closed: у ВСІХ цих випадках виклик-сайт трактує
    # це як "вже виметено" (пропустити sweep), НЕ як "повторити sweep" —
    # sweep є одноразовою зручністю очищення диска, не data-integrity
    # операцією; безпечніший режим відмови — не повторювати деструктивну
    # дію при сумніві в стані, а не ризикувати повторним sweep-ом
    # legacy-вмісту, який оператор міг навмисно відновити для інспекції.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        # Схема валідується всередині try: валідний JSON із нечисловим
        # schemaVersion (напр. "abc") кидав би на [int]-касті ПОЗА try —
        # помилковий record у консоль і повернення зіпсованого стану як
        # валідного (code-review 5c14a70, знахідка 1).
        if ($null -eq $state.PSObject.Properties['schemaVersion'] -or [int]$state.schemaVersion -ne 1) { return $null }
        if ($null -eq $state.PSObject.Properties['sweptAt'] -or [string]::IsNullOrWhiteSpace([string]$state.sweptAt)) { return $null }
    } catch {
        return $null
    }
    return $state
}

function Invoke-BRAVOLegacySweep {
    # Одноразове (маркер-гейтоване) best-effort очищення відомих legacy-
    # артефактів ери ARCHIV_LIMS-предка. Виконується ДО фаз Trace/
    # exchangAPI/BravoWeb (нижче), щоб їхнє перше після-оновлення
    # переміщення не наштовхувалось на застарілі сторонні файли. Ніколи
    # не чіпає нічого поза явно переліченими legacy-патернами; ніколи не
    # чіпає поточно-модельний вміст. Провал — WARNING-рівень, некритичний
    # (не встановлює $script:criticalErrorOccurred): це одноразова
    # зручність очищення диска, не операція, від якої залежить
    # коректність/цілісність даних.
    #
    # Непорожні legacy Trace-каталоги-дати СВІДОМО НЕ архівуються тут
    # bypass-ом віку — лишаються для звичайного age-gated
    # Compress-OldData-шляху (той самий принцип обережності, що й у
    # Get-BRAVOEmptyLogDateDirectories/P2): одноразовий bypass поза
    # протестованим Compress-OldData-контуром — саме той вузький виняток,
    # якого застерігають fail-closed-правила проєкту.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$TraceDir,
        [Parameter(Mandatory = $true)][string]$StateFilePath,
        [string]$SweptBy
    )

    # Розрізняємо "маркера ще не існувало" (безпечно замітати) від "файл
    # існує, але нечитабельний/пошкоджений" (fail-closed: пропустити, а НЕ
    # повторити sweep) — обидва Read-BRAVOLegacySweepState повертає як
    # $null, тому існування файлу перевіряємо окремо.
    $stateFileExisted = [IO.File]::Exists($StateFilePath)
    $state = Read-BRAVOLegacySweepState -Path $StateFilePath
    if ($null -ne $state) {
        Write-Log "Первинна очистка legacy-артефактів вже виконана $($state.sweptAt) — пропущено." -Level "DEBUG"
        return
    }
    if ($stateFileExisted) {
        Write-Log "Стан-маркер первинної очистки пошкоджений/нечитабельний — sweep пропущено (fail-closed). Для повторного запуску видаліть вручну: $StateFilePath" -Level "WARNING"
        return
    }
    Write-Log "=== ПЕРВИННА ОЧИСТКА LEGACY-АРТЕФАКТІВ (одноразово) ===" -Level "INFO"
    $removed = 0
    try {
        $legacyFiles = @(Get-BRAVOFiles -Path $LogDir | Where-Object {
            $_.Name -like 'script_log_*.txt' -or $_.Name -like 'ARCHIV_LIMS_*.log'
        })
        foreach ($f in $legacyFiles) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $removed++
            } catch {
                Write-Log "Legacy-очистка: не вдалося видалити $($f.Name): $($_.Exception.Message)" -Level "WARNING"
            }
        }
        $legacyDateDirs = @(Get-BRAVODirectories -Path $TraceDir | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' })
        foreach ($d in $legacyDateDirs) {
            $isEmpty = @((New-Object System.IO.DirectoryInfo($d.FullName)).EnumerateFileSystemInfos()).Count -eq 0
            if (-not $isEmpty) {
                Write-Log "Legacy-очистка: непорожній каталог-дата $($d.FullName) залишено для звичайної age-gated архівації." -Level "INFO"
                continue
            }
            try {
                (New-Object System.IO.DirectoryInfo($d.FullName)).Delete()
                $removed++
            } catch {
                Write-Log "Legacy-очистка: не вдалося видалити $($d.FullName): $($_.Exception.Message)" -Level "WARNING"
            }
        }
        Write-BRAVOLegacySweepState -Path $StateFilePath -SweptBy $SweptBy | Out-Null
        Write-Log "Первинна очистка завершена: видалено $removed об'єкт(ів)." -Level "SUCCESS"
    } catch {
        Write-Log "Первинна очистка legacy-артефактів не завершена: $($_.Exception.Message) — маркер НЕ записано, повтор наступним прогоном." -Level "WARNING"
    }
}

if ($BravoMaintenanceEnabled) {
    Invoke-BRAVOLegacySweep -LogDir $LOG_DIR -TraceDir $TRACE_DIR `
        -StateFilePath (Get-BRAVOLegacySweepStatePath) -SweptBy $script:ScriptVersion
}

# ===== TRACE: ДОБОВИЙ АРХІВ І SFTP =====
# Unnumbered операція ПІСЛЯ відновлення служб (Total=8 незмінний, як
# cleanup/archive/shutdown нижче): архівація і мережева передача не мають
# додавати ані секунди downtime — служби вже працюють, ротовані .out
# обробляються у фоні цього ж запуску. SFTP-збій тут не блокує решту
# Maintenance: файли лишаються, retry — наступним прогоном.
Write-BRAVOProgressPhase -Phase 'Trace: добовий архів і SFTP' -PercentComplete 84
# Одноразова (idempotent) міграція legacy-розкладки локальних архівів
# MODEL: <BackupRoot>\ARCHIV\LIMS -> <BackupRoot>\MODEL (старий комплект
# ARCHIV_LIMS-ери). Best-effort: помилки — WARNING, наступний нічний
# прогін повторить; функція no-op, коли legacy-каталогу немає (тобто на
# всіх уже мігрованих/нових серверах). Віддалена частина (archiv ->
# model) — нижче, у SFTP-сесії Trace-блоку.
$legacyModelLocalDirectory = [System.IO.Path]::Combine([string]$backupRootPath, 'ARCHIV', 'LIMS')
[void](Invoke-BRAVOLegacyModelArchiveLocalMigration `
    -LegacyDirectory $legacyModelLocalDirectory `
    -TargetDirectory ([string]$archiveDirs.Model))

$script:currentMaintenanceOperation = 'Trace: добовий архів і SFTP'
$traceArchiveOperationStartedAt = Get-Date
$traceArchiveCriticalBefore = $script:criticalErrorOccurred
$traceArchiveWarningsBefore = $script:BRAVOWarningCount
$traceArchiveOperationDetail = $null
if (-not $BravoMaintenanceEnabled) {
    Write-BRAVOMaintenanceOperation `
        -Name 'Trace: добовий архів і SFTP' `
        -Status 'SKIPPED' `
        -Duration ((Get-Date) - $traceArchiveOperationStartedAt) `
        -Details 'вимкнено'
} elseif ([string]::IsNullOrWhiteSpace($script:ArchivePassword)) {
    Write-Log -Message "Trace: добова архівація пропущена — пароль архівів недоступний ($ArchiveCredentialError)" -Level "WARNING"
    Write-BRAVOMaintenanceOperation `
        -Name 'Trace: добовий архів і SFTP' `
        -Status 'WARN' `
        -Duration ((Get-Date) - $traceArchiveOperationStartedAt) `
        -Details 'пароль архівів недоступний'
} else {
    $traceSftpSession = $null
    try {
        Write-Log -Message "==="
        Write-Log -Message "=== TRACE: ДОБОВИЙ АРХІВ І SFTP ===" -Level "INFO"
        # SFTP-сесія — той самий канонічний ланцюг, що standalone-інструменти
        # (Credential Manager -> Resolve-BRAVOSftpHostName -> New-BRAVOSftpUrl
        # -> WinSCP .NET). Недоступність креденшлів/WinSCP — НЕ критична:
        # архіви оновлюються локально, передача відкладається.
        #
        # componentSettings.SFTP.Enabled=false (5.2.2): цей блок раніше
        # не мав ЖОДНОГО SFTP-гейта й відкривав сесію щоночі незалежно від
        # конфігурації дестинацій. Тепер при глобально вимкненому SFTP
        # credential-читання і спроба WinSCP-з'єднання пропускаються
        # ПОВНІСТЮ (нуль Credential Manager, нуль WinSCP) — $traceSftpSession
        # лишається $null, і решта блоку (Invoke-BRAVOTraceArchiveMaintenance,
        # remote-міграції) деградує до локального режиму так само, як і при
        # недоступності SFTP з будь-якої іншої причини нижче; різниця лише
        # у рівні логу (INFO замість WARNING — це не збій, а свідома
        # конфігурація).
        if (-not [bool]$storageEffective.SFTP.Enabled) {
            Write-Log -Message ([string]$storageEffective.SFTP.DisabledReason) -Level "INFO"
        } else {
            try {
                $traceSftpLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
                $traceSftpPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
                if ([string]::IsNullOrWhiteSpace($traceSftpLoginTarget)) { $traceSftpLoginTarget = 'BRAVO_SFTP_LOGIN' }
                if ([string]::IsNullOrWhiteSpace($traceSftpPasswordTarget)) { $traceSftpPasswordTarget = 'BRAVO_SFTP_PASSWORD' }
                $traceSftpLogin = Get-BRAVOCredentialSecret -Target $traceSftpLoginTarget
                $traceSftpPassword = Get-BRAVOCredentialSecret -Target $traceSftpPasswordTarget
                if ([string]::IsNullOrWhiteSpace($traceSftpLogin) -or [string]::IsNullOrWhiteSpace($traceSftpPassword)) {
                    throw "записи Credential Manager '$traceSftpLoginTarget'/'$traceSftpPasswordTarget' недоступні"
                }
                $traceSftpLogin = ([string]$traceSftpLogin).Trim()
                $traceResolvedSftpHost = Resolve-BRAVOSftpHostName `
                    -UserName $traceSftpLogin `
                    -HostTemplate ([string]$sftpHostTemplate) `
                    -FallbackHostName $(if ($null -ne (Get-Variable -Name 'sftpHost' -Scope Global -ErrorAction SilentlyContinue)) { [string](Get-Variable -Name 'sftpHost' -Scope Global).Value } else { $null })
                $traceRepositorySftpUrl = New-BRAVOSftpUrl `
                    -HostName $traceResolvedSftpHost `
                    -Port ([int]$sftpPort) `
                    -UserName $traceSftpLogin `
                    -Password ([string]$traceSftpPassword)
                $traceSftpPassword = $null
                $traceWinScpComponents = Get-BRAVOWinSCPDotNetComponents -WinSCPPath ([string]$winSCPPath)
                if ($null -eq $traceWinScpComponents) {
                    throw 'WinSCP .NET-компоненти (WinSCPnet.dll + winscp.exe) не знайдено'
                }
                if ($null -eq ('WinSCP.Session' -as [type])) {
                    Add-Type -Path $traceWinScpComponents.AssemblyPath -ErrorAction Stop
                }
                $traceSessionOptions = New-Object WinSCP.SessionOptions
                $traceSessionOptions.ParseUrl($traceRepositorySftpUrl)
                $traceRepositorySftpUrl = $null
                $traceSessionOptions.SshHostKeyFingerprint = ([string]$sftpHostKey).Trim().Trim('"')
                $traceSessionOptions.Timeout = [timespan]::FromSeconds([math]::Max(15, [int]$sftpConnectionTimeoutSeconds))
                $traceSftpSession = New-Object WinSCP.Session
                $traceSftpSession.ExecutablePath = $traceWinScpComponents.ExecutablePath
                $traceSftpSession.Open($traceSessionOptions)
            } catch {
                if ($null -ne $traceSftpSession) {
                    try { $traceSftpSession.Dispose() } catch {
                        # Сесія так і не відкрилась; збій Dispose не значущий.
                    }
                }
                $traceSftpSession = $null
                Write-Log -Message "Trace: SFTP-сесія недоступна ($($_.Exception.Message)) — добові архіви оновлюються локально, передачу відкладено" -Level "WARNING"
            }
        }

        # Одноразова (idempotent) автоміграція legacy /trace -> /logs/trace:
        # виконується до передач, лише за живої сесії; помилки видимі, але
        # не блокують оновлення/передачу нових архівів.
        if ($null -ne $traceSftpSession) {
            $traceMigrationResult = Invoke-BRAVOTraceRemoteLogMigration `
                -Session $traceSftpSession `
                -LegacyDirectory $traceLegacySftpRemoteDirectory `
                -TargetDirectory $traceSftpRemoteDirectory `
                -Logger $bravoLogRotationLogger
            if ([int]$traceMigrationResult.Errors -gt 0) {
                $script:criticalErrorOccurred = $true
            }

            # Одноразова (idempotent) міграція legacy-архівів MODEL на SFTP:
            # archiv -> model (той самий канонічний механізм, що trace/ вище;
            # фільтр .mdz/.sha512 покриває архіви MODEL). ConflictLevel
            # WARNING (рішення власника): колізія означає, що актуальніша
            # копія вже в model — файл лишається в archiv без критичного
            # статусу. Помилки переносу логуються самою функцією рядками
            # «ПОМИЛКА: міграція SFTP...»; статус прогону свідомо НЕ
            # ескалюється (на відміну від trace-міграції вище): legacy-
            # перенос — best-effort і повториться наступної ночі.
            [void](Invoke-BRAVOTraceRemoteLogMigration `
                -Session $traceSftpSession `
                -LegacyDirectory 'archiv' `
                -TargetDirectory ([string]$sftpDirectories.MODEL) `
                -Logger $bravoLogRotationLogger `
                -ConflictLevel 'WARNING')
        }

        $traceMaintenanceResult = Invoke-BRAVOTraceArchiveMaintenance `
            -TraceDirectory $TRACE_DIR `
            -SevenZipPath $ARC_PATH `
            -AddParameters $traceArchiveAddParams `
            -ArchivePassword $script:ArchivePassword `
            -CommandTimeoutSeconds $NativeCommandTimeoutSeconds `
            -IntegrityTimeoutSeconds $SevenZipIntegrityTestTimeoutSeconds `
            -Session $traceSftpSession `
            -RemoteDirectory $traceSftpRemoteDirectory `
            -RawSourceRetentionDays $RAW_SOURCE_GRACE_DAYS `
            -GraceCompletionStatePath (Get-BRAVOTraceGraceCompletionStatePath -ComponentLabel 'Trace') `
            -Logger $bravoLogRotationLogger
        if ([int]$traceMaintenanceResult.Errors -gt 0) {
            $script:criticalErrorOccurred = $true
        }

        # exchangAPI: той самий движок добових архівів (оригінальні імена,
        # групування за LastWriteTime) — logs/exchangapi на SFTP.
        $exchangeArchiveMaintenanceResult = $null
        if ($exchangAPIServiceEnabled) {
            Write-Log -Message "==="
            Write-Log -Message "=== EXCHANGAPI: ДОБОВИЙ АРХІВ І SFTP ===" -Level "INFO"
            $exchangeArchiveMaintenanceResult = Invoke-BRAVOTraceArchiveMaintenance `
                -TraceDirectory $EXCHANGE_LOG_DIR `
                -SevenZipPath $ARC_PATH `
                -AddParameters $traceArchiveAddParams `
                -ArchivePassword $script:ArchivePassword `
                -CommandTimeoutSeconds $NativeCommandTimeoutSeconds `
                -IntegrityTimeoutSeconds $SevenZipIntegrityTestTimeoutSeconds `
                -Session $traceSftpSession `
                -RemoteDirectory $exchangeApiSftpRemoteDirectory `
                -ComponentLabel 'exchangAPI' `
                -ArchiveNamePrefix 'exchangAPI' `
                -BacklogGroupBy 'ByLastWriteTime' `
                -BacklogFileFilter '*.log' `
                -RawSourceRetentionDays $RAW_SOURCE_GRACE_DAYS `
                -GraceCompletionStatePath (Get-BRAVOTraceGraceCompletionStatePath -ComponentLabel 'exchangAPI') `
                -Logger $bravoLogRotationLogger
            if ([int]$exchangeArchiveMaintenanceResult.Errors -gt 0) {
                $script:criticalErrorOccurred = $true
            }
        }

        $traceArchiveOperationDetail = if (
            [int]$traceMaintenanceResult.DatesProcessed -eq 0 -and
            ($null -eq $exchangeArchiveMaintenanceResult -or [int]$exchangeArchiveMaintenanceResult.DatesProcessed -eq 0)
        ) {
            'файлів у черзі немає'
        } else {
            $traceDetailParts = @(
                "дат: $($traceMaintenanceResult.DatesProcessed)",
                "оновлено архівів: $($traceMaintenanceResult.ArchivesUpdated)",
                "передано на SFTP: $($traceMaintenanceResult.Uploaded)",
                "видалено переданих джерел: $($traceMaintenanceResult.SourcesDeleted)"
            )
            if ([int]$traceMaintenanceResult.UploadsDeferred -gt 0) {
                $traceDetailParts += "відкладено передач: $($traceMaintenanceResult.UploadsDeferred)"
            }
            if ([int]$traceMaintenanceResult.Conflicts -gt 0) {
                $traceDetailParts += "конфліктів: $($traceMaintenanceResult.Conflicts)"
            }
            if ($null -ne $exchangeArchiveMaintenanceResult -and [int]$exchangeArchiveMaintenanceResult.DatesProcessed -gt 0) {
                $traceDetailParts += "exchangAPI: дат $($exchangeArchiveMaintenanceResult.DatesProcessed), передано $($exchangeArchiveMaintenanceResult.Uploaded)"
            }
            $traceDetailParts -join '; '
        }
    } catch {
        $script:criticalErrorOccurred = $true
        $traceArchiveOperationDetail = $_.Exception.Message
        Write-Log -Message "ПОМИЛКА: Trace добовий архів/SFTP: $($_.Exception.Message)" -Level "ERROR"
        Send-SlackAlert -Message "Trace добовий архів/SFTP: $($_.Exception.Message)" -IsCritical
    } finally {
        if ($null -ne $traceSftpSession) {
            try { $traceSftpSession.Dispose() } catch {
                # Результат фази вже зафіксовано; збій Dispose не критичний.
            }
        }
    }
    Write-BRAVOMaintenanceOperation `
        -Name 'Trace: добовий архів і SFTP' `
        -Status (Get-BRAVOMaintenanceStepStatus `
            -CriticalBefore $traceArchiveCriticalBefore `
            -WarningsBefore $traceArchiveWarningsBefore) `
        -Duration ((Get-Date) - $traceArchiveOperationStartedAt) `
        -Details $traceArchiveOperationDetail
}

# ===== ОЧИСТКА СТАРИХ ДАНИХ =====
Write-BRAVOProgressPhase -Phase 'Очистка старих даних' -PercentComplete 88
# dev.16: точна атрибуція для outer fail-safe catch нижче (рядок ~5180) —
# якщо необроблена помилка станеться десь у Cleanup/Archive/AutoShutdown/
# фінальному звіті, catch називає САМЕ цю операцію, а не generic список.
$script:currentMaintenanceOperation = 'Очистка старих даних/логів'
$cleanupOperationStartedAt = Get-Date
$cleanupCriticalBefore = $script:criticalErrorOccurred
$cleanupWarningsBefore = $script:BRAVOWarningCount
# "Reported" — чи встиг цей блок надрукувати свій Write-BRAVOMaintenanceOperation
# до того, як (якщо) стався виняток: outer catch перевіряє прапорець, щоб
# не показати FAIL result двічі й не пропустити його, якщо виняток стався
# ДО власного рендеру блоку.
$script:cleanupOperationReported = $false

# Перевіряємо, чи є що очищати
$hasDataToClean = $false

# Сумарний результат Remove-BRAVOEmptyLogDateDirectories по всіх
# компонентах (P2-3): якщо єдиною реальною роботою циклу було видалення
# вже спорожнілих legacy-каталогів-дат, це МАЄ враховуватись у
# $hasDataToClean і підсумковому Details — інакше цикл, що реально
# прибрав каталоги з диска, звітував би SKIPPED/«даних для очищення
# немає».
$emptyLogDateDirDeletedCount = 0
$emptyLogDateDirWarningCount = 0
# EnumerationWarnings/DeletionWarnings окремо (P2-2/P2-3, PR #136 review):
# обидва типи warnings мусять бути видимі в підсумку очистки, не лише
# врахованими у сумарному $emptyLogDateDirWarningCount мовчки.
$emptyLogDateDirEnumerationWarningCount = 0
$emptyLogDateDirDeletionWarningCount = 0

# Каталоги-дати програмних журналів старші за retention. Перевіряються
# лише БЕЗПОСЕРЕДНІ дочірні каталоги кожної гілки (Get-BRAVODirectories
# без -Recurse) — обхід від <ArchiveRoot>\LOGS вниз зачепив би службові
# журнали самого Maintenance, які живуть на верхньому рівні.
function Get-BRAVOExpiredLogDateDirectories {
    param([string]$Path, [int]$RetentionDays)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    return @(Get-BRAVODirectories -Path $Path |
        Where-Object {
            $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.CreationTime -lt $cutoff
        })
}

# Порожні каталоги-дати — незалежно від віку: нема чого втрачати, тому
# без ARCHIVE_RETENTION_DAYS-gate. Регресія (2026-09, real-server LIMS-TOP):
# поточна ("5.2.0") модель Trace/exchangAPI/BravoWeb пише лише пласкі
# timestamped-файли — жоден чинний код більше не пише у каталоги-дати
# YYYY-MM-DD, тож щойно така тека спорожніла (увесь вміст архівовано),
# вона гарантовано вже НЕ отримає нового вмісту. Проте
# Get-BRAVOExpiredLogDateDirectories все одно чекала би повні
# ARCHIVE_RETENTION_DAYS (14) днів, перш ніж її прибрати — попри
# відсутність будь-яких даних, які можна втратити. Непорожні
# каталоги-дати лишаються завданням наявного age-gated Compress-OldData-
# шляху (Get-BRAVOExpiredLogDateDirectories вище) без змін.
function Get-BRAVOEmptyLogDateDirectories {
    # Enumeration — best-effort: candidate може зникнути між
    # Get-BRAVODirectories і EnumerateFileSystemInfos() (паралельний
    # видалювач/архіватор), або доступ може бути раптово заборонений
    # (ACL/антивірус). EnumerateFileSystemInfos() у такому разі кидає
    # виняток — БЕЗ per-candidate try/catch він вилітав би з усього
    # Where-Object-пайплайна назовні й перетворював чисто best-effort
    # cleanup на critical failure всього прогону Maintenance (P2-2).
    # Непідтверджену порожнечу трактуємо fail-safe: каталог НЕ
    # потрапляє в результат (і, відповідно, не видаляється нижче) —
    # краще пропустити цикл, ніж видалити каталог, що міг щойно
    # отримати новий вміст.
    # $DiscoveredCandidatesOut/$EnumerationWarningsOut (P2-2/P2-3, PR #136
    # review) — необовʼязкові [ref]-виходи для Remove-BRAVOEmptyLogDateDirectories,
    # щоб той міг звести повний структурований результат (скільки
    # каталогів-дат узагалі знайдено ДО спроби enumeration, і скільки з
    # них не вдалося підтвердити) без повторного сканування диска. Основний
    # (позиційний) контракт повернення — масив ПІДТВЕРДЖЕНО порожніх
    # каталогів — лишається незмінним для наявних викликів.
    param([string]$Path, [string]$Label, [ref]$DiscoveredCandidatesOut, [ref]$EnumerationWarningsOut)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ($DiscoveredCandidatesOut) { $DiscoveredCandidatesOut.Value = 0 }
        if ($EnumerationWarningsOut) { $EnumerationWarningsOut.Value = 0 }
        return @()
    }
    $labelPrefix = if ([string]::IsNullOrWhiteSpace($Label)) { '' } else { "${Label}: " }
    $candidates = @(Get-BRAVODirectories -Path $Path |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' })
    if ($DiscoveredCandidatesOut) { $DiscoveredCandidatesOut.Value = $candidates.Count }
    $emptyDirs = New-Object System.Collections.Generic.List[object]
    $enumerationWarnings = 0
    foreach ($candidate in $candidates) {
        try {
            if (@((New-Object System.IO.DirectoryInfo($candidate.FullName)).EnumerateFileSystemInfos()).Count -eq 0) {
                [void]$emptyDirs.Add($candidate)
            }
        } catch {
            Write-Log "${labelPrefix}не вдалося підтвердити порожнечу каталогу $($candidate.FullName): $($_.Exception.Message)" -Level "WARNING"
            $enumerationWarnings++
        }
    }
    if ($EnumerationWarningsOut) { $EnumerationWarningsOut.Value = $enumerationWarnings }
    # .ToArray(), а не @($emptyDirs): той самий PS 5.1 гейт, що
    # Get-BRAVOFileLockingProcesses вище — @() напряму на
    # System.Collections.Generic.List[T] кидає "Argument types do not
    # match" (емпірично відтворено, версія 5.1.26100.9168).
    return $emptyDirs.ToArray()
}

function Remove-BRAVOEmptyLogDateDirectories {
    # Best-effort негайне видалення порожніх каталогів-дат. Некритичний
    # ефект — провал видалення одного каталогу не зупиняє обробку решти
    # й не встановлює $script:criticalErrorOccurred (чиста зручність
    # очищення диска, не data-integrity операція).
    #
    # Повертає структурований результат (P2-3): виклик цієї функції —
    # єдина реальна робота, коли всі дані вже заархівовано і лишилися
    # тільки спорожнілі legacy-каталоги-дати; без цього результату
    # виклик обробляв candidates/Deleted мовчки, і підсумковий крок
    # очистки показував SKIPPED/«даних для очищення немає» попри
    # реальне видалення каталогів з диска.
    param([string]$Path, [string]$Label)

    $discoveredCandidates = 0
    $enumerationWarnings = 0
    $candidates = @(Get-BRAVOEmptyLogDateDirectories -Path $Path -Label $Label `
        -DiscoveredCandidatesOut ([ref]$discoveredCandidates) -EnumerationWarningsOut ([ref]$enumerationWarnings))
    $deleted = New-Object System.Collections.Generic.List[string]
    $deletionWarnings = 0
    foreach ($emptyDir in $candidates) {
        try {
            (New-Object System.IO.DirectoryInfo($emptyDir.FullName)).Delete()
            Write-Log "Порожній legacy-каталог ${Label} видалено: $($emptyDir.FullName)" -Level "INFO"
            [void]$deleted.Add($emptyDir.FullName)
        } catch {
            Write-Log "ПОМИЛКА видалення порожнього каталогу ${Label} $($emptyDir.FullName): $($_.Exception.Message)" -Level "WARNING"
            $deletionWarnings++
        }
    }
    # .ToArray(), а не @($deleted) — той самий PS 5.1 гейт, що вище.
    #
    # DiscoveredCandidates/ConfirmedEmpty/Deleted/EnumerationWarnings/
    # DeletionWarnings (P2-2/P2-3, PR #136 review) — розрізняють "скільки
    # каталогів-дат узагалі знайдено", "скільки з них підтверджено
    # порожніми" і "скільки видалено", а також ДВА типи warnings (не
    # вдалося підтвердити порожнечу vs не вдалося видалити) окремо, щоб
    # обидва типи можна було показати в підсумку очистки. CandidateCount/
    # DeletedCount/DeletedPaths/WarningCount лишаються для зворотної
    # сумісності з наявними викликами (WarningCount — сума обох типів).
    return [pscustomobject]@{
        DiscoveredCandidates = $discoveredCandidates
        ConfirmedEmpty       = $candidates.Count
        Deleted              = $deleted.Count
        EnumerationWarnings  = $enumerationWarnings
        DeletionWarnings     = $deletionWarnings
        CandidateCount       = $candidates.Count
        DeletedCount         = $deleted.Count
        DeletedPaths         = $deleted.ToArray()
        WarningCount         = $enumerationWarnings + $deletionWarnings
    }
}

# Перевірка даних основного компонента BRAVO
$traceOldDirs = @()
$traceOldLogs = @()
# dev.16: власна, окремо названа Main-scope змінна — НЕ $groupsToDelete
# (та назва зарезервована за function Remove-OldRestoreArchives, де вона
# локальна й враховує SHA512/7z-валідність та stale-invalid групи; тут —
# лише грубий candidate-count для Details нижче, без тієї валідації).
# Однакова назва в різних scope вводила б в оману, ніби це те саме
# значення.
$restoreArchiveDeleteCandidateGroups = @()
if ($BravoMaintenanceEnabled) {
    $emptyLogDateDirResult = Remove-BRAVOEmptyLogDateDirectories -Path $TRACE_DIR -Label 'Trace'
    $emptyLogDateDirDeletedCount += $emptyLogDateDirResult.DeletedCount
    $emptyLogDateDirWarningCount += $emptyLogDateDirResult.WarningCount
    $emptyLogDateDirEnumerationWarningCount += $emptyLogDateDirResult.EnumerationWarnings
    $emptyLogDateDirDeletionWarningCount += $emptyLogDateDirResult.DeletionWarnings
    $traceOldDirs = @(Get-BRAVOExpiredLogDateDirectories -Path $TRACE_DIR -RetentionDays $ARCHIVE_RETENTION_DAYS)
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
        $restoreArchiveDeleteCandidateGroups = @($sortedGroups | Select-Object -Skip $RESTORE_ARCHIVES_KEEP_COUNT)
        $hasDataToClean = $hasDataToClean -or ($restoreArchiveDeleteCandidateGroups.Count -gt 0)
    }
}

# Перевірка каталогів-дат exchangAPI лише для активного компонента
$exchangAPIOldDirs = @()
if ($exchangAPIServiceEnabled) {
    $emptyLogDateDirResult = Remove-BRAVOEmptyLogDateDirectories -Path $EXCHANGE_LOG_DIR -Label 'exchangAPI'
    $emptyLogDateDirDeletedCount += $emptyLogDateDirResult.DeletedCount
    $emptyLogDateDirWarningCount += $emptyLogDateDirResult.WarningCount
    $emptyLogDateDirEnumerationWarningCount += $emptyLogDateDirResult.EnumerationWarnings
    $emptyLogDateDirDeletionWarningCount += $emptyLogDateDirResult.DeletionWarnings
    $exchangAPIOldDirs = @(Get-BRAVOExpiredLogDateDirectories -Path $EXCHANGE_LOG_DIR -RetentionDays $ARCHIVE_RETENTION_DAYS)
}

# Перевірка BRAVO Web (якщо Apache встановлений). Apache і application
# logs — дві незалежні гілки з власними .mdz: змішувати їх в один архів
# означало б розпаковувати весь веб-компонент, щоб дістати один access.log.
$apacheOldDirs = @()
$bravoWebAppOldDirs = @()
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    $emptyLogDateDirResult = Remove-BRAVOEmptyLogDateDirectories -Path $APACHE_LOG_DIR -Label 'Apache'
    $emptyLogDateDirDeletedCount += $emptyLogDateDirResult.DeletedCount
    $emptyLogDateDirWarningCount += $emptyLogDateDirResult.WarningCount
    $emptyLogDateDirEnumerationWarningCount += $emptyLogDateDirResult.EnumerationWarnings
    $emptyLogDateDirDeletionWarningCount += $emptyLogDateDirResult.DeletionWarnings
    $emptyLogDateDirResult = Remove-BRAVOEmptyLogDateDirectories -Path $BRAVOWEB_APP_LOG_DIR -Label 'BravoWeb-App'
    $emptyLogDateDirDeletedCount += $emptyLogDateDirResult.DeletedCount
    $emptyLogDateDirWarningCount += $emptyLogDateDirResult.WarningCount
    $emptyLogDateDirEnumerationWarningCount += $emptyLogDateDirResult.EnumerationWarnings
    $emptyLogDateDirDeletionWarningCount += $emptyLogDateDirResult.DeletionWarnings
    $apacheOldDirs = @(Get-BRAVOExpiredLogDateDirectories -Path $APACHE_LOG_DIR -RetentionDays $ARCHIVE_RETENTION_DAYS)
    $bravoWebAppOldDirs = @(Get-BRAVOExpiredLogDateDirectories -Path $BRAVOWEB_APP_LOG_DIR -RetentionDays $ARCHIVE_RETENTION_DAYS)
}
# Каталоги-дати, що приїхали міграцією зі старого <ArchiveRoot>\Br-a-vo.web,
# лежать безпосередньо в LOGS\BravoWeb (тоді Apache і www\log ще не були
# розділені). Без окремого рядка вони лишилися б поза будь-яким retention.
$bravoWebLegacyOldDirs = @()
if ($BravoWebLegacyDataEnabled) {
    $emptyLogDateDirResult = Remove-BRAVOEmptyLogDateDirectories -Path $BRAVOWEB_LOG_DIR -Label 'BravoWeb-Legacy'
    $emptyLogDateDirDeletedCount += $emptyLogDateDirResult.DeletedCount
    $emptyLogDateDirWarningCount += $emptyLogDateDirResult.WarningCount
    $emptyLogDateDirEnumerationWarningCount += $emptyLogDateDirResult.EnumerationWarnings
    $emptyLogDateDirDeletionWarningCount += $emptyLogDateDirResult.DeletionWarnings
    $bravoWebLegacyOldDirs = @(Get-BRAVOExpiredLogDateDirectories -Path $BRAVOWEB_LOG_DIR -RetentionDays $ARCHIVE_RETENTION_DAYS)
}

# Стиснуті .mdz програмних журналів мають ВЛАСНИЙ строк зберігання
# (CompressedLogDays), незалежний від ArchiveDays: перший визначає, коли
# каталог-дата пакується, другий — коли спакований архів видаляється.
$compressedLogRetentionTargets = @()
if ($BravoMaintenanceEnabled) {
    $compressedLogRetentionTargets += [pscustomobject]@{ Path = $TRACE_DIR; Prefix = 'Trace' }
}
if ($exchangAPIServiceEnabled) {
    $compressedLogRetentionTargets += [pscustomobject]@{ Path = $EXCHANGE_LOG_DIR; Prefix = 'exchangAPI' }
}
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled) {
    $compressedLogRetentionTargets += [pscustomobject]@{ Path = $APACHE_LOG_DIR; Prefix = 'Apache' }
    $compressedLogRetentionTargets += [pscustomobject]@{ Path = $BRAVOWEB_APP_LOG_DIR; Prefix = 'BravoWeb' }
}
# Легасі-каталоги-дати, що переїхали в LOGS\BravoWeb безпосередньо (до
# розділення на Apache\ і Application\), пакуються з тим самим префіксом.
if ($BravoWebLegacyDataEnabled) {
    $compressedLogRetentionTargets += [pscustomobject]@{ Path = $BRAVOWEB_LOG_DIR; Prefix = 'BravoWeb' }
}

$expiredCompressedLogCount = 0
# Скан кандидатів виконується ЛИШЕ при явно ввімкненій політиці видалення
# стиснутих логів: із вимкненим прапорцем (типово) жоден .mdz не
# видаляється за віком — незалежно від CompressedLogDays.
if ($COMPRESSED_LOG_DELETION_ENABLED) {
    $compressedLogCutoff = (Get-Date).AddDays(-$COMPRESSED_LOG_RETENTION_DAYS)
    foreach ($compressedTarget in $compressedLogRetentionTargets) {
        if (-not (Test-Path -LiteralPath $compressedTarget.Path -PathType Container)) {
            continue
        }
        $archivePattern = '^' + [regex]::Escape([string]$compressedTarget.Prefix) + '_(\d{4}-\d{2}-\d{2}|\d{8})\.mdz$'
        foreach ($archiveFile in @(Get-BRAVOFiles -LiteralPath ([string]$compressedTarget.Path) -Filter "*.mdz")) {
            $archiveMatch = [regex]::Match($archiveFile.Name, $archivePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $archiveMatch.Success) { continue }
            [datetime]$archiveDate = [datetime]::MinValue
            if ([datetime]::TryParseExact(
                    $archiveMatch.Groups[1].Value,
                    [string[]]@('yyyy-MM-dd', 'yyyyMMdd'),
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$archiveDate) -and $archiveDate -lt $compressedLogCutoff) {
                $expiredCompressedLogCount++
            }
        }
    }
}

# Загальна перевірка наявності даних для очищення. $emptyLogDateDirDeletedCount
# (P2-3) враховано нарівні з age-gated кандидатами: видалення вже
# спорожнілих legacy-каталогів-дат — реальна робота циклу очистки, а не
# щось окреме від нього.
$hasDataToClean = $hasDataToClean -or
    ($traceOldDirs.Count -gt 0) -or
    ($traceOldLogs.Count -gt 0) -or
    ($exchangAPIOldDirs.Count -gt 0) -or
    ($apacheOldDirs.Count -gt 0) -or
    ($bravoWebAppOldDirs.Count -gt 0) -or
    ($bravoWebLegacyOldDirs.Count -gt 0) -or
    ($expiredCompressedLogCount -gt 0) -or
    ($emptyLogDateDirDeletedCount -gt 0)

# Якщо є дані для очищення - показуємо заголовок
if ($hasDataToClean) {
    Write-Log -Message "==="
    Write-Log -Message "=== ОЧИСТКА СТАРИХ ДАНИХ ==="
} else {
    # dev.15: очистка — progress phase поза затвердженим [N/8] контрактом
    # (не numbered main step); "немає чого видаляти" лишається лише в LOG.
    Write-Log -Message "Очистка старих даних: немає чого видаляти." -Level "DEBUG"
}

# Обробка Trace (тільки якщо є що обробляти)
if ($BravoMaintenanceEnabled -and $traceOldDirs.Count -gt 0) {
    Process-OldData -Path $TRACE_DIR -ArchiveNamePrefix "Trace" -RetentionDays $ARCHIVE_RETENTION_DAYS -arcCommonParams $arcCommonParams -ARC_PATH $ARC_PATH
}

# Обробка каталогів-дат exchangAPI
if ($exchangAPIServiceEnabled -and $exchangAPIOldDirs.Count -gt 0) {
    Process-OldData -Path $EXCHANGE_LOG_DIR -ArchiveNamePrefix "exchangAPI" -RetentionDays $ARCHIVE_RETENTION_DAYS -arcCommonParams $arcCommonParams -ARC_PATH $ARC_PATH
}

# Обробка логів BRAVO Web (лише якщо служба Apache встановлена і є дані)
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled -and $apacheOldDirs.Count -gt 0) {
    Process-OldData -Path $APACHE_LOG_DIR -ArchiveNamePrefix "Apache" -RetentionDays $ARCHIVE_RETENTION_DAYS -arcCommonParams $arcCommonParams -ARC_PATH $ARC_PATH
}
if ($BravoWebMaintenanceEnabled -and $ApacheEnabled -and $bravoWebAppOldDirs.Count -gt 0) {
    Process-OldData -Path $BRAVOWEB_APP_LOG_DIR -ArchiveNamePrefix "BravoWeb" -RetentionDays $ARCHIVE_RETENTION_DAYS -arcCommonParams $arcCommonParams -ARC_PATH $ARC_PATH
}
if ($BravoWebLegacyDataEnabled -and $bravoWebLegacyOldDirs.Count -gt 0) {
    Process-OldData -Path $BRAVOWEB_LOG_DIR -ArchiveNamePrefix "BravoWeb" -RetentionDays $ARCHIVE_RETENTION_DAYS -arcCommonParams $arcCommonParams -ARC_PATH $ARC_PATH
}

# Очистка службових журналів самого Maintenance — суворо верхній рівень
# <ArchiveRoot>\LOGS і суворо за whitelist імен. Ані -Recurse, ані
# узагальненого "*.log": і те, і те дотягнулося б до Trace\, exchangAPI\
# та BravoWeb\, тобто видаляло б програмні журнали за політикою, писаною
# для власних логів скрипта.
if ($BravoMaintenanceEnabled -and $traceOldLogs.Count -gt 0) {
    Remove-OldLogFiles -Path $LOG_DIR -RetentionDays $LOG_RETENTION_DAYS
}

# Видалення стиснутих журналів, старших за CompressedLogDays. Виконується
# ПІСЛЯ Process-OldData: спочатку сьогоднішні застарілі каталоги-дати стають
# архівами, і лише потім перевіряється вік самих архівів. Гейт
# CompressedLogDeletionEnabled — подвійний захист (скан вище вже нульовий
# при вимкненій політиці).
if ($COMPRESSED_LOG_DELETION_ENABLED -and $expiredCompressedLogCount -gt 0) {
    foreach ($compressedTarget in $compressedLogRetentionTargets) {
        [void](Remove-BRAVOExpiredCompressedLogs `
            -Path ([string]$compressedTarget.Path) `
            -ArchiveNamePrefix ([string]$compressedTarget.Prefix) `
            -RetentionDays $COMPRESSED_LOG_RETENTION_DAYS `
            -Logger $bravoLogRotationLogger)
    }
}

# Видалення старих архівів реставрації - тільки якщо є що видаляти І поточна
# restore-сесія (якщо вона була цього циклу) завершилась чисто успішно —
# інакше pruning під час аварійного run міг би зачепити щойно створені
# діагностичні before/after-архіви цієї ж сесії (task item 9).
if ($BravoMaintenanceEnabled -and $restoreArchiveDeleteCandidateGroups.Count -gt 0 -and -not $restoreSessionUnsafeForRetention) {
    Remove-OldRestoreArchives `
        -Path $ARC_DIR `
        -ArchivePrefix $ArchivePrefix `
        -KeepCount $RESTORE_ARCHIVES_KEEP_COUNT `
        -InvalidRetentionDays $FAILED_ARCHIVE_RETENTION_DAYS
} elseif ($restoreSessionUnsafeForRetention) {
    Write-Log -Message "Retention архівів реставрації пропущено: поточна restore-сесія завершилась помилкою або rollback." -Level "WARNING"
}

# dev.16: execution result очистки — unnumbered top-level операція (не
# [N/8], не рахується в Кроків/Успішно/Попереджень/Пропущено/Помилок).
# Статус — той самий before/after-снепшот, що вже керує 8 numbered
# кроками (Get-BRAVOMaintenanceStepStatus); SKIPPED, коли перевірка не
# знайшла нічого застарілого. Details — компактний агрегат КАНДИДАТІВ,
# знайдених вище (не "видалено": жодна з Process-OldData/Remove-*
# функцій не повертає структурованих success-лічильників, а вигадувати
# їх тут — не мета цього proходу); повний перелік файлів і будь-які
# індивідуальні збої лишаються тільки в LOG, як і раніше.
$cleanupOperationDirCandidateCount = $traceOldDirs.Count + $exchangAPIOldDirs.Count +
    $apacheOldDirs.Count + $bravoWebAppOldDirs.Count + $bravoWebLegacyOldDirs.Count
$cleanupOperationFileCandidateCount = $traceOldLogs.Count + $expiredCompressedLogCount
$cleanupOperationStatus = Get-BRAVOMaintenanceStepStatus `
    -CriticalBefore $cleanupCriticalBefore `
    -WarningsBefore $cleanupWarningsBefore `
    -Skipped:(-not $hasDataToClean)
$cleanupOperationDetails = if ($cleanupOperationStatus -eq 'SKIPPED') {
    'даних для очищення немає'
} elseif ($cleanupOperationStatus -eq 'WARN' -or $cleanupOperationStatus -eq 'FAIL') {
    'перевірте LOG для деталей'
} else {
    $cleanupDetailParts = @()
    if ($cleanupOperationDirCandidateCount -gt 0) {
        $cleanupDetailParts += "каталогів: $cleanupOperationDirCandidateCount"
    }
    if ($cleanupOperationFileCandidateCount -gt 0) {
        $cleanupDetailParts += "файлів: $cleanupOperationFileCandidateCount"
    }
    if ($restoreArchiveDeleteCandidateGroups.Count -gt 0) {
        $cleanupDetailParts += "сесій архівів реставрації: $($restoreArchiveDeleteCandidateGroups.Count)"
    }
    if ($emptyLogDateDirDeletedCount -gt 0) {
        $cleanupDetailParts += "порожніх legacy-каталогів видалено: $emptyLogDateDirDeletedCount"
    }
    # P2-2/P2-3 (PR #136 review): обидва типи best-effort warnings
    # (не вдалося підтвердити порожнечу / не вдалося видалити) мають
    # лишатись видимими оператору в підсумку очистки, а не лише
    # мовчки накопичуватись у $emptyLogDateDirWarningCount.
    if ($emptyLogDateDirEnumerationWarningCount -gt 0) {
        $cleanupDetailParts += "не вдалося підтвердити порожнечу каталогів: $emptyLogDateDirEnumerationWarningCount"
    }
    if ($emptyLogDateDirDeletionWarningCount -gt 0) {
        $cleanupDetailParts += "не вдалося видалити порожні каталоги: $emptyLogDateDirDeletionWarningCount"
    }
    if ($cleanupDetailParts.Count -gt 0) { $cleanupDetailParts -join '; ' } else { $null }
}
Write-BRAVOMaintenanceOperation `
    -Name 'Очистка старих даних/логів' `
    -Status $cleanupOperationStatus `
    -Duration ((Get-Date) - $cleanupOperationStartedAt) `
    -Details $cleanupOperationDetails
$script:cleanupOperationReported = $true

# ===== ЗАПУСК ДОДАТКОВОГО СКРИПТУ BRAVO_ARCHIV =====
Write-BRAVOProgressPhase -Phase 'Запуск BRAVO_ARCHIV' -PercentComplete 95
$script:currentMaintenanceOperation = 'Архівація після maintenance'
$archiveOperationStartedAt = Get-Date
$archiveCriticalBefore = $script:criticalErrorOccurred
$archiveWarningsBefore = $script:BRAVOWarningCount
$script:archiveOperationReported = $false
$archiveOperationDetail = $null
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

            # AUTO-намір: -ConfigPath вбудовується лише за explicit (той
            # самий гейт, що UAC-relaunch вище) — інакше дочірній Archive
            # трактував би auto-derived відсутній шлях як explicit і
            # завершувався configuration error замість власного AUTO.
            $archiveConfigArgumentText = if ($configPathWasExplicit) {
                " -ConfigPath `"$ConfigPath`""
            } else {
                ''
            }
            $archiveArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$bravoArchivePath`"$archiveConfigArgumentText -NoPause"
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
                $archiveOperationDetail = "BRAVO_ARCHIV завершився з кодом $($archivProcess.ExitCode)"
            }
        } else {
            Write-Log -Message "Скрипт BRAVO_ARCHIV.ps1 не знайдено за шляхом: $bravoArchivePath" -Level "ERROR"
            $script:criticalErrorOccurred = $true
            $archiveOperationDetail = "скрипт не знайдено: $bravoArchivePath"
        }
    }
    catch {
        Write-Log -Message "Помилка під час запуску скрипту BRAVO_ARCHIV.ps1: $($_.Exception.Message)" -Level "ERROR"
        $script:criticalErrorOccurred = $true
        $archiveOperationDetail = 'перевірте LOG для деталей'
    }
    # dev.16: execution result — unnumbered top-level операція (не [N/8],
    # не рахується в Кроків/Успішно/Попереджень/Пропущено/Помилок).
    # Дочірній процес/lock/exit-code semantics вище не змінені — лише
    # обгорнуті трекінгом статусу/тривалості для консолі.
    Write-BRAVOMaintenanceOperation `
        -Name 'Архівація після maintenance' `
        -Status (Get-BRAVOMaintenanceStepStatus `
            -CriticalBefore $archiveCriticalBefore `
            -WarningsBefore $archiveWarningsBefore) `
        -Duration ((Get-Date) - $archiveOperationStartedAt) `
        -Details $archiveOperationDetail
    $script:archiveOperationReported = $true
} else {
    # Лише у журнал: вимкнений компонент не займає рядка в консолі.
    Write-Log -Message "Запуск BRAVO_ARCHIV: вимкнено" -Level "DEBUG"
    Write-BRAVOMaintenanceOperation `
        -Name 'Архівація після maintenance' `
        -Status 'SKIPPED' `
        -Duration ((Get-Date) - $archiveOperationStartedAt) `
        -Details 'вимкнено'
    $script:archiveOperationReported = $true
}

# ===== НАМІР АВТОМАТИЧНОГО ВИМКНЕННЯ (лише позначка reachability) =====
# P2-6 (PR #136 review): раніше тут одразу викликався Invoke-AutoShutdown
# (сам shutdown.exe + інтерактивний діалог скасування). Це стартувало
# 60-секундний countdown вимкнення сервера ЗАДОВГО до того, як власний лог
# прогону взагалі почав вивантажуватись на SFTP (own-log upload — окремий
# блок далеко в кінці файлу, після фінального summary/footer) — реальний
# ризик: сервер вимикається посеред best-effort передачі логу. Фактичний
# виклик Invoke-AutoShutdown перенесено в самий кінець скрипта, ПІСЛЯ
# вивантаження й закриття SFTP-сесії, безпосередньо перед exit. Тут
# лишається лише $script:autoShutdownReachable = $true — доказ, що
# виконання дійшло до цієї точки try БЕЗ необробленого винятку (та сама
# семантика, що раніше: виняток у Cleanup/Archive й тоді пропускав спробу
# автовимкнення повністю, бо код нижче в try просто не виконувався).
$script:currentMaintenanceOperation = 'Автоматичне вимкнення сервера'
# $autoShutdownOperationStartedAt тут — лише страховка для Set-StrictMode:
# fallback-рендер у catch нижче (рядок з 'Автоматичне вимкнення сервера')
# читає цю змінну, якщо виняток стався РІВНО в цій точці (вкрай
# малоймовірно, самі присвоєння нижче не кидають). Реальний вимір
# тривалості — фреш Get-Date у відкладеному виклику в самому кінці файлу,
# ця точка лише перезаписується там.
$autoShutdownOperationStartedAt = Get-Date
$script:autoShutdownOperationReported = $false
$script:autoShutdownReachable = $true

# Відправляємо фінальний звіт
$script:currentMaintenanceOperation = 'Відправлення фінального звіту'
Send-FinalReport -LOG_FILE $LOG_FILE

if (-not $script:criticalErrorOccurred) {
    Write-BRAVOTaskExecutionState -TaskName 'Maintenance'
}

# Додаємо інформацію про статус відправки Slack
# if ($script:SlackMode -ne "none") {
    # Видаліть перевірку $slackReportSent, оскільки тепер функція нічого не повертає
#     Write-Log -Message "Фінальний звіт оброблено" -Level "INFO"
# }

} catch {
    # dev.15: див. коментар біля відкриття try вище — мета лише в тому,
    # щоб жодна необроблена помилка тут не "з'їла" код завершення й
    # фінальний summary нижче. Причина повністю потрапляє в LOG і в
    # errors_only-сповіщення (той самий Send-SlackAlert -IsCritical
    # контракт, що й решта критичних помилок Maintenance).
    #
    # СПОЧАТКУ безумовно позначаємо критичну помилку — до будь-яких
    # diagnostic дій нижче, які самі теоретично можуть кинути виняток.
    # Якщо цього не зробити першим, а Write-Log/Send-SlackAlert кинуть
    # власний exception, catch завершиться без встановленого прапорця, і
    # виконання все одно дійде до summary нижче, але зі стертим статусом
    # помилки.
    $script:criticalErrorOccurred = $true
    # dev.16: точна атрибуція замість generic "Range ID/очистка/
    # BRAVO_ARCHIV/AutoShutdown/фінальний звіт" — $script:currentMaintenanceOperation
    # оновлюється перед кожним блоком вище (Контроль діапазонів ID/
    # Очистка старих даних/логів/Архівація після maintenance/Автоматичне
    # вимкнення сервера/Відправлення фінального звіту), тому тут завжди
    # відома САМЕ активна на момент винятку операція.
    $errorMsg = "Помилка операції `"$($script:currentMaintenanceOperation)`": $($_.Exception.Message)"

    # Логування й сповіщення виконуються ІЗОЛЬОВАНО одне від одного: збій
    # будь-якого з них (наприклад, недоступний LOG-файл або мережева
    # помилка webhook) не повинен rethrow-нути й обійти обчислення exit
    # code/фінальний summary нижче.
    try {
        Write-Log -Message "ПОМИЛКА: $errorMsg" -Level "ERROR"
    } catch {
        # не rethrow: збій логування не повинен знищити finalization.
        # Свідомо не Write-Log/Send-SlackAlert/throw/exit/return тут — це
        # саме той збій, який ця гілка ізолює; лише прибирає порожній catch
        # (PSAvoidUsingEmptyCatchBlock) без нових side effects.
        $null = $_
    }
    try {
        Send-SlackAlert -Message $errorMsg -IsCritical
    } catch {
        # не rethrow: збій сповіщення не повинен знищити finalization.
        # Та сама причина, що вище — без Write-Log/Send-SlackAlert/throw/
        # exit/return.
        $null = $_
    }

    # dev.16: якщо виняток стався ВСЕРЕДИНІ операції з власним execution
    # result (Cleanup/Archive/AutoShutdown), її рядок так і не встиг
    # надрукуватись — оператор побачив би лише generic ПОМИЛКА без
    # result-рядка для конкретної операції. Друкуємо її FAIL РІВНО ОДИН
    # РАЗ тут, лише якщо вона ще не відзвітувала сама (прапорець
    # *Reported, встановлюється в кінці кожного блоку вище). Контроль
    # діапазонів ID — numbered [8/8] крок, тут не чіпаємо; Відправлення
    # фінального звіту — notification transport без власного
    # console-result (лише причина в $errorMsg вище).
    try {
        switch ($script:currentMaintenanceOperation) {
            'Очистка старих даних/логів' {
                if (-not $script:cleanupOperationReported) {
                    Write-BRAVOMaintenanceOperation `
                        -Name 'Очистка старих даних/логів' `
                        -Status 'FAIL' `
                        -Duration ((Get-Date) - $cleanupOperationStartedAt) `
                        -Details 'перевірте LOG для деталей'
                }
            }
            'Архівація після maintenance' {
                if (-not $script:archiveOperationReported) {
                    Write-BRAVOMaintenanceOperation `
                        -Name 'Архівація після maintenance' `
                        -Status 'FAIL' `
                        -Duration ((Get-Date) - $archiveOperationStartedAt) `
                        -Details 'перевірте LOG для деталей'
                }
            }
            'Автоматичне вимкнення сервера' {
                if (-not $script:autoShutdownOperationReported) {
                    Write-BRAVOMaintenanceOperation `
                        -Name 'Автоматичне вимкнення сервера' `
                        -Status 'FAIL' `
                        -Duration ((Get-Date) - $autoShutdownOperationStartedAt) `
                        -Details 'перевірте LOG для деталей'
                }
            }
        }
    } catch {
        # не rethrow: та сама ізоляція, що Write-Log/Send-SlackAlert вище —
        # навіть fallback-рендер не повинен знищити finalization.
        $null = $_
    }
}

# ===== ЗАВЕРШЕННЯ СКРИПТУ =====
# dev.19 (виправлено): $script:maintenanceRuntimeExitCode обчислюється
# ТУТ — одразу після закриття зовнішнього try/catch вище (усі бізнес-
# операції й fail-safe обробка, включно з випадком, коли сам catch щойно
# підняв criticalErrorOccurred, уже завершились) і ДО друку "=== СТАТУС:
# ... ===" нижче, а не після нього. У першій версії dev.19 ЛОГ-рядок
# СТАТУС друкувався РАНІШЕ цього обчислення, тому Get-BRAVOMaintenanceFinalStatus
# незалежно інспектував ті самі прапорці — паралельна, хоч і узгоджена,
# класифікаційна політика замість фактичного резолвленого коду.
# Get-BRAVOMaintenanceResolvedExitCode — ТА САМА пріоритетна політика
# (critical > warnings > success, 40/41/60 через Resolve-BRAVOExitCode),
# що раніше стояла inline нижче за друком РЕЗУЛЬТАТ; сама формула не
# змінена, лише піднята вище й винесена в один спільний виклик (той
# самий, що вже дає "поточний знімок" для Send-FinalReport вище).
$script:maintenanceRuntimeExitCode = Get-BRAVOMaintenanceResolvedExitCode

$maintenanceEndedAt = Get-Date
$totalTime = $maintenanceEndedAt - $script:ScriptStartTime

# Machine-readable status contract v1 (ROADMAP P2.1, BRAVO.Status):
# ПІСЛЯ резолву exit code, fail-soft — помилка запису лише логується і
# ніколи не змінює результат Maintenance (інваріант «telemetry не змінює
# exit code»).
try {
    Write-BRAVOOperationStatus `
        -StateRoot $stateRoot `
        -Operation Maintenance `
        -ExitCode $script:maintenanceRuntimeExitCode `
        -ExitCodeName (Get-BRAVOExitCodeName -Code $script:maintenanceRuntimeExitCode) `
        -StartedAt $script:ScriptStartTime `
        -FinishedAt $maintenanceEndedAt `
        -Details @{
            stepsTotal = [int]$script:BRAVOMaintenanceStepLog.Count
            stepsOk = [int]$script:BRAVOMaintenanceStepOkCount
            stepsWarning = [int]$script:BRAVOMaintenanceStepWarnCount
            stepsSkipped = [int]$script:BRAVOMaintenanceStepSkippedCount
            stepsError = [int]$script:BRAVOMaintenanceStepFailCount
            criticalErrorOccurred = [bool]$script:criticalErrorOccurred
        }
} catch {
    Write-Log -Message "ПОПЕРЕДЖЕННЯ: не вдалося записати machine-readable status-файл Maintenance: $($_.Exception.Message)"
}

# ФІНАЛЬНИЙ БЛОК ЗАВЕРШЕННЯ
Write-Log -Message "==="
Write-Log -Message "=== СИСТЕМА ОБСЛУГОВУВАННЯ BRAVOSOFT ЗАВЕРШИЛА РОБОТУ ==="
Write-Log -Message "=== УСТАНОВА: $($script:ObjectName) ==="
Write-Log -Message "=== ЧАС ВИКОНАННЯ: $(Format-Duration $totalTime) ==="
# dev.19 (виправлено): Get-BRAVOMaintenanceFinalStatus тепер приймає
# ВЖЕ резолвлений $script:maintenanceRuntimeExitCode (обчислений вище,
# до цього рядка) — не незалежну перевірку BRAVOWarningCount/
# criticalErrorOccurred.
Write-Log -Message "=== СТАТУС: $((Get-BRAVOMaintenanceFinalStatus -ExitCode $script:maintenanceRuntimeExitCode).Text) ==="
Write-Log -Message "==="

Complete-BRAVOProgress

# dev.19 (виправлено): раніше тут стояло inline-обчислення
# $script:maintenanceRuntimeExitCode (переміщено вище, до друку ЛОГ
# "=== СТАТУС ===" — Get-BRAVOMaintenanceResolvedExitCode, той самий
# принцип "обчислити ДО друку РЕЗУЛЬТАТ", що вже застосований в
# Archive/Health, лише тепер поширений і на ЛОГ). Операції створення/
# відновлення локального архіву й перевірки його цілісності виділені
# окремими прапорцями (restoreArchiveFailed/restoreIntegrityFailed,
# 19 точок) на 40/41; решта ~23 точок criticalErrorOccurred (сервіси,
# диск, файлове господарство, оркестрація BRAVO_ARCHIV) і далі
# схлопуються в загальний бакет 60. Resolve-BRAVOExitCode сам віддає
# пріоритет 40/41 над 60, якщо передані одночасно.
#
# dev.19 (виправлено): той самий резолвлений $script:maintenanceRuntimeExitCode
# і той самий Get-BRAVOMaintenanceFinalStatus, що ЛОГ вище — консоль і
# ЛОГ фізично не можуть розійтися, бо обидва читають ОДНЕ значення.
$maintenanceFinalStatus = Get-BRAVOMaintenanceFinalStatus -ExitCode $script:maintenanceRuntimeExitCode
$maintenanceSummaryResult = $maintenanceFinalStatus.Text
$maintenanceSummaryStatusColor = $maintenanceFinalStatus.Color
# dev.14 (round 3): окремий стиль заголовка підсумку для Maintenance —
# "BRAVO MAINTENANCE — СТАТУС" в одному рядку (Write-BRAVOFinalSummaryHeader,
# той самий =-роздільник, що заголовок прогону) — плюс окреме поле
# "Статус:" нижче, той самий текст "N — Назва", що Write-BRAVOResultHeader
# формував для "Код завершення" (BRAVO.ExitCodes, ніколи native tool code).
Write-BRAVOFinalSummaryHeader `
    -Title 'BRAVO MAINTENANCE' `
    -Status $maintenanceSummaryResult `
    -StatusColor $maintenanceSummaryStatusColor
Write-BRAVOResultField -Label 'Статус' -Value $maintenanceSummaryResult -Color $maintenanceSummaryStatusColor
$maintenanceExitCodeText = "{0} — {1}" -f $script:maintenanceRuntimeExitCode, (Get-BRAVOExitCodeName -Code $script:maintenanceRuntimeExitCode)
Write-BRAVOResultField -Label 'Код завершення' -Value $maintenanceExitCodeText
Write-BRAVOResultField -Label 'Початок' -Value $script:ScriptStartTime.ToString('dd.MM.yyyy HH:mm:ss')
Write-BRAVOResultField -Label 'Завершення' -Value $maintenanceEndedAt.ToString('dd.MM.yyyy HH:mm:ss')
Write-BRAVOResultField -Label 'Тривалість' -Value (Format-BRAVODuration -Duration $totalTime)
Write-BRAVOResultBlankLine
# dev.14 (round 2): той самий підхід, що Health (Перевірок/Успішно/
# Попереджень/Помилок, ConsoleUX/15-HealthSummaryCounters) — тут ще й
# Пропущено, бо, на відміну від Health, Maintenance регулярно показує
# SKIPPED-кроки. Лічильники накопичуються в Add-BRAVOMaintenanceStepOutcome
# — спільній точці обліку пронумерованих кроків І ненумерованих операцій.
#
# "Кроків" береться з довжини журналу етапів, а НЕ з нумератора
# $script:BRAVOMaintenanceStepCurrent: той рахує лише пронумеровані [N/8],
# тому після включення ненумерованих операцій в облік підсумок ставав
# арифметично неспроможним (реальний прогін 20:29 показав "Кроків: 8" при
# "Успішно: 9" + "Пропущено: 4").
Write-BRAVOResultField -Label 'Кроків' -Value ([string]$script:BRAVOMaintenanceStepLog.Count)
Write-BRAVOResultField -Label 'Успішно' -Value ([string]$script:BRAVOMaintenanceStepOkCount)
Write-BRAVOResultField -Label 'Попереджень' -Value ([string]$script:BRAVOMaintenanceStepWarnCount)
Write-BRAVOResultField -Label 'Пропущено' -Value ([string]$script:BRAVOMaintenanceStepSkippedCount)
Write-BRAVOResultField -Label 'Помилок' -Value ([string]$script:BRAVOMaintenanceStepFailCount)
# dev.14 (round 5): Maintenance/Архівація/Shutdown прибрано з compact
# operator summary — не входять у затверджений набір полів (Статус/Код
# завершення/Початок/Завершення/Тривалість/Кроків/Успішно/Попереджень/
# Пропущено/Помилок/Журнал). Ці факти вже видно в "Плані операцій" на
# початку прогону (Maintenance BRAVO/Архівація після maintenance/
# Автоматичне вимкнення сервера — ті самі прапорці) і в детальному
# LOG-файлі — тут вони лише дублювали б інформацію, а не додавали нову.
# dev.14 (round 4): парний до Write-BRAVOFinalSummaryHeader — мітка
# "Журнал" і шлях, закриваючий =-роздільник, той самий стиль, що заголовок
# прогону. Старий '-'-роздільник і довший підпис лишаються контрактом
# Archive/Health/інших — тут навмисно окрема функція, не той самий виклик.
Write-BRAVOFinalSummaryFooter -LogFile $LOG_FILE

# Вивантаження ВЛАСНОГО повного логу прогону (+ знімок range_id_log.json)
# на SFTP — opt-in (componentSettings.SFTP.MaintenanceLogUploadEnabled,
# дефолт $false). Розміщено ПІСЛЯ резолву $script:maintenanceRuntimeExitCode
# і фінального підсумку: провал передачі структурно не може змінити
# результат прогону (другорядний/телеметричний ефект). Trace-сесія на цей
# момент давно закрита, тому відкривається окрема коротко-живуча сесія.
if ([bool]$componentSettings.SFTP.MaintenanceLogUploadEnabled -and
    [bool]$storageEffective.SFTP.Enabled) {
    $ownLogUploadSession = $null
    try {
        $ownLogUploadSession = Connect-BRAVOOwnLogSftpSession
        if ($null -ne $ownLogUploadSession) {
            $ownLogRemoteDirectory = [string]$sftpDirectories.MaintenanceLog
            Send-BRAVOOwnLogFile `
                -Session $ownLogUploadSession `
                -LocalLogPath $LOG_FILE `
                -RemoteDirectory $ownLogRemoteDirectory `
                -Logger $null
            # range_id_log.json пише служба BRAVO (toolkit його лише читає) —
            # строго read-only знімок; локальне ім'я константне, тому remote-
            # ім'я суфіксується run-id, щоб прогони не перезаписували один
            # одного. Відсутній файл — тихий no-op (Send-BRAVOOwnLogFile).
            $ownRangeIdLogPath = Get-BRAVOSystemRangeIdLogPath
            if (-not [string]::IsNullOrWhiteSpace([string]$ownRangeIdLogPath)) {
                Send-BRAVOOwnLogFile `
                    -Session $ownLogUploadSession `
                    -LocalLogPath ([string]$ownRangeIdLogPath) `
                    -RemoteDirectory $ownLogRemoteDirectory `
                    -RemoteFileName ("range_id_log_{0}.json" -f $maintenanceLogRunId) `
                    -Logger $null
            }
        }
    } catch {
        Write-Log "Власний лог: вивантаження на SFTP не вдалося: $($_.Exception.Message)" -Level "WARNING"
    } finally {
        if ($null -ne $ownLogUploadSession) {
            try { $ownLogUploadSession.Dispose() } catch {
                # Best-effort закриття сесії — помилка Dispose тут уже ні на
                # що не впливає (лог передано або WARNING вже записано).
            }
        }
    }
}

# ===== ВИКЛИК ФУНКЦІЇ АВТОМАТИЧНОГО ВИМКНЕННЯ (P2-6: після SFTP-вивантаження) =====
# Свідомо ПІСЛЯ Send-BRAVOOwnLogFile/Dispose вище — фактичний shutdown.exe
# і 60-секундний countdown НЕ повинні стартувати до того, як власний лог
# уже завантажено (або спроба завершилась WARNING-ом). Помилка upload не
# скасовує дозволене вимкнення ($script:autoShutdownReachable і
# $script:EnableAutoShutdown нижче ніяк не залежать від результату
# upload-блоку вище). Помилка самого Invoke-AutoShutdown (внутрішній
# try/catch функції вже повертає 'Failed', зовнішній тут — друга лінія
# захисту) НЕ чіпає $script:maintenanceRuntimeExitCode: код завершення й
# фінальний summary вище вже резолвлені та надруковані незалежно від
# цього блоку.
if ($script:autoShutdownReachable) {
    $autoShutdownOperationStartedAt = Get-Date
    if ($script:EnableAutoShutdown) {
        # dev.16: Invoke-AutoShutdown повертає фінальний символьний стан
        # (Scheduled/Cancelled/Failed), не просто "чи команда планування
        # відпрацювала" — оператор має бачити РЕАЛЬНИЙ результат, включно з
        # інтерактивним скасуванням, а не тільки той факт, що виклик колись
        # відбувся. Сама логіка планування/діалогу/скасування не змінена.
        try {
            $autoShutdownOutcome = Invoke-AutoShutdown -Timeout $ShutdownTimeout
        } catch {
            Write-Log -Message "Помилка під час відкладеного виклику автовимкнення: $($_.Exception.Message)" -Level "ERROR"
            $autoShutdownOutcome = 'Failed'
        }
        Write-BRAVOMaintenanceOperation `
            -Name 'Автоматичне вимкнення сервера' `
            -Status $(switch ($autoShutdownOutcome) {
                'Scheduled' { 'OK' }
                'Cancelled' { 'SKIPPED' }
                default     { 'FAIL' }
            }) `
            -Duration ((Get-Date) - $autoShutdownOperationStartedAt) `
            -Details $(switch ($autoShutdownOutcome) {
                'Scheduled' { "заплановано через $ShutdownTimeout с" }
                'Cancelled' { 'скасовано користувачем' }
                default     { 'не вдалося ініціювати вимкнення — перевірте LOG' }
            })
    } else {
        # Мінімальне інформаційне повідомлення без заголовків
        Write-Log -Message "Автоматичне вимкнення: вимкнено" -Level "DEBUG"
        Write-BRAVOMaintenanceOperation `
            -Name 'Автоматичне вимкнення сервера' `
            -Status 'SKIPPED' `
            -Duration ((Get-Date) - $autoShutdownOperationStartedAt) `
            -Details 'вимкнено'
    }
    $script:autoShutdownOperationReported = $true
}
} finally {
    Exit-BRAVOMaintenanceOperationLock
}

exit $script:maintenanceRuntimeExitCode

} finally {
    # Закриває try, відкритий одразу після імпорту модулів. exit усередині
    # try проходить крізь finally перед тим, як процес справді завершиться
    # (перевірено емпірично) — тому це охоплює геть усі ~28 точок exit
    # вище, включно з рідко відвідуваними (config не знайдено, lock
    # зайнятий, tool integrity) — саме там, де оператору найпотрібніше
    # встигнути прочитати повідомлення до закриття вікна.
    Wait-BRAVOManualExit -NoPause:$NoPause
}
