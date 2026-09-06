##########
# BravoSoft
# Author: Evgeniy Kucher
# Version metadata is loaded from VERSION.json through BRAVO_CONFIG_LOADER.ps1.
##########
#
# BRAVO_DATA_RESTORE — відновлення даних із резервної копії (roadmap: Етап 6,
# Disaster Restore Workflow). Розпаковує перевірену (manifest + SHA512 +
# 7-Zip integrity) COMPLETE generation або її окремий компонент:
#   OutOfPlace — у порожні підкаталоги вказаної оператором директорії
#                (<TargetPath>\MODEL|BLOG|BRAVOEXCH); production і служби
#                не змінюються;
#   InPlace    — у production-шляхи компонентів (джерела discovery) з повним
#                протоколом безпеки: знімок стану служб -> зупинка -> явне
#                типізоване підтвердження -> move-aside поточних даних у
#                <name>.prerestore_<ts> -> розпакування в порожній каталог ->
#                post-verify -> відновлення стану служб -> Health.
# Джерело архівів: Local (BackupRoot) або SFTP (завантаження у staging з
# повторною повною верифікацією).
#
# НЕ ПЛУТАТИ з "реставрацією моделі" (BRAVO_MAINTENANCE / задача
# BRAVO_RESTORE_RECOVERY): то планова перебудова моделі засобами bravocmd,
# а не відновлення даних із резервної копії.
#
# Інваріант безпеки: жоден файл ніколи не розпаковується поверх наявного —
# ціль завжди щойно створений порожній каталог; попередні InPlace-дані
# зберігаються поруч як .prerestore-копія і не видаляються автоматично.

param (
    [string]$ConfigPath,
    [bool]$ConfigPathWasExplicit = $false,
    [string]$GenerationId,
    [ValidateSet("MODEL", "BLOG", "BRAVOEXCH", "All")]
    [string]$Component = "All",
    [ValidateSet("OutOfPlace", "InPlace")]
    [string]$Mode = "OutOfPlace",
    [string]$TargetPath,
    [ValidateSet("Local", "SFTP")]
    [string]$Source = "Local",
    [string]$StagingPath,
    [switch]$ListGenerations,
    [switch]$Force,
    [switch]$SkipHealthCheck,
    [int]$TimeoutSeconds = 0,
    [switch]$NoPause,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$EntryScriptPath
)

$bravoScriptDirectory = $RuntimeRoot

# Спільні PowerShell-модулі runtime. BRAVO.ArchiveRuntime — заради
# Test-BRAVOWinSCPAvailable/Get-SanitizedWinSCPDiagnostic (режим -Source SFTP).
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveHelpers', 'BRAVO.Logging', 'BRAVO.Console', 'BRAVO.ExitCodes', 'BRAVO.ArchiveRuntime', 'BRAVO.System')) {
    $modulePath = Join-Path $bravoScriptDirectory "modules\$moduleName\$moduleName.psd1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Не знайдено спільний PowerShell-модуль: $modulePath"
    }
    Import-Module -Name $modulePath -ErrorAction Stop
}
Assert-BRAVOPowerShellCompatibility
[void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
$notificationHelpersPath = Join-Path $bravoScriptDirectory 'modules\BRAVO.Notifications\BRAVO.Notifications.psd1'
if (-not (Test-Path -LiteralPath $notificationHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль notifications: $notificationHelpersPath"
}
Import-Module -Name $notificationHelpersPath -ErrorAction Stop

# Test-BRAVODataRestoreGenerationIdFormat визначена ТУТ (а не серед інших
# функцій нижче за текстом файлу), бо потрібна ДО елевації — єдина
# канонічна реалізація застосовується і до значення, яке ще належить
# передати елевованому дочірньому процесу.
function Test-BRAVODataRestoreGenerationIdFormat {
    # Канонічний формат generationId: yyyyMMdd_HHmmss з опційним
    # collision-safe суфіксом _N. Єдина реалізація перевірки — той самий
    # контракт застосовується і до -GenerationId з командного рядка (до
    # елевації та після), і до generationId, прочитаного зі ЗМІСТУ
    # manifest-а (локального або, особливо, SFTP-завантаженого) ПЕРЕД тим,
    # як значення бере участь у Join-Path/створенні каталогів. Manifest —
    # недовірений вхід: без цієї перевірки шкідливе чи пошкоджене значення
    # generationId (напр. "..\..\Windows") могло б вивести обчислений шлях
    # за межі staging root.
    param([string]$GenerationId)
    if ([string]::IsNullOrWhiteSpace($GenerationId)) { return $false }
    $formatMatch = [regex]::Match($GenerationId, '^\d{8}_\d{6}(?:_(?<suffix>\d+))?$')
    if (-not $formatMatch.Success) { return $false }
    # Продюсер (Get-BRAVOCollisionSafeGenerationId, BRAVO.Archive.Runtime.ps1)
    # генерує суфікс лише обмеженим циклом [int] (0..MaxAttempts). Regex вище
    # НЕ обмежує кількість цифр, тому недовірене (особливо SFTP-manifest чи
    # remote-listing) ім'я на кшталт "..._2147483648" пройшло б формат, але
    # звалило б подальший [int]-каст у Get-BRAVODataRestoreGenerationIdSortKey
    # необробленим OverflowException. TryParse тут — non-throwing перевірка,
    # що значення взагалі влазить у той самий числовий тип, яким оперує
    # sort-key/продюсер; неприйнятний суфікс — це недопустимий формат, а не
    # crash.
    if ($formatMatch.Groups['suffix'].Success) {
        $parsedSuffix = 0
        if (-not [int]::TryParse(
                $formatMatch.Groups['suffix'].Value,
                [System.Globalization.NumberStyles]::None,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsedSuffix)) {
            return $false
        }
    }
    return $true
}

function Test-BRAVODataRestoreMinimumFreeSpaceGB {
    # Канонічна перевірка maintenanceSettings.Limits.MinimumFreeSpaceGB ПЕРЕД
    # тим, як значення бере участь у Test-BRAVODataRestoreFreeSpace як
    # резервний поріг. Від'ємний/нескінченний/NaN поріг зробив би перевірку
    # "$availableBytes - $requiredBytes -lt $floorBytes" хибно успішною:
    # з від'ємним $floorBytes том, на якому реально бракує місця, міг би
    # пройти preflight. Визначена ТУТ (до "try {" нижче), бо конфігурація
    # завантажується й перевіряється одразу на початку try-блоку. [double]-
    # каст (не string round-trip через культуру) — щоб числове значення з
    # JSON-конфігурації не залежало від поточної локалі виконання.
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Value,
        [Parameter(Mandatory = $true)][ref]$ValidatedGigabytes
    )
    $ValidatedGigabytes.Value = [double]0
    if ($null -eq $Value) { return $false }
    $parsedValue = $null
    try {
        $parsedValue = [double]$Value
    } catch {
        return $false
    }
    if ([double]::IsNaN($parsedValue) -or [double]::IsInfinity($parsedValue) -or $parsedValue -lt 0) {
        return $false
    }
    $ValidatedGigabytes.Value = $parsedValue
    return $true
}

function Test-BRAVODataRestoreFullyQualifiedWindowsPath {
    # PS 5.1-сумісна валідація "справді абсолютного" Windows-шляху (round-7
    # follow-up P2): [System.IO.Path]::IsPathRooted() вважає '\RESTORE_STAGING'
    # і 'C:RESTORE_STAGING' rooted, хоча обидва насправді ВІДНОСНІ —
    # 'C:RESTORE_STAGING' резолвиться відносно поточного робочого каталогу
    # ДИСКА C: (per-drive current directory, який зберігає процес), а
    # '\RESTORE_STAGING' — відносно кореня ПОТОЧНОГО диска (може не
    # збігатися з наміром оператора, особливо в елевованому дочірньому
    # процесі — саме той клас небезпеки, який round-7 уже закрив для
    # відносних шляхів без провідного роздільника).
    # [System.IO.Path]::IsPathFullyQualified() існує лише в .NET Core/5+,
    # недоступний у Windows PowerShell 5.1 (.NET Framework) — тому явна
    # перевірка на regex ДВОХ дозволених канонічних форм (позитивна
    # граматика — приймається ЛИШЕ те, що явно описано нижче, усе інше
    # відхиляється за замовчуванням):
    #   локальний диск: <Буква>:\ або <Буква>:/, одразу роздільник після ":"
    #   UNC:            \\сервер\ресурс з непорожнім ім'ям сервера й ресурсу
    #
    # P1 follow-up (review 4945915094): Win32 File Namespace ('\\?\...')
    # і Win32 Device Namespace ('\\.\...') префікси — включно з
    # device-wrapped UNC формою '\\?\UNC\сервер\ресурс\...' —
    # НАВМИСНО і БЕЗУМОВНО відхиляються ПЕРЕД позитивною граматикою
    # нижче, незалежно від того, що йде після префікса. Наївний UNC-
    # regex '^\\\\[^\\/]+\\[^\\/]+' трактує "?" чи "." як звичайний
    # "сервер" (односимвольний, без \ чи /) — тому '\\?\C:\LIMS\MODEL'
    # раніше проходив як "валідний UNC". Небезпека НЕ в самому прийнятті
    # рядка: [System.IO.Path]::GetFullPath() ЗБЕРІГАЄ ці префікси
    # дослівно (не нормалізує до звичайної форми диска/UNC), тому
    # лексичні перевірки перетину (Test-BRAVODataRestorePathEquals/
    # PathWithin у Test-BRAVODataRestoreStagingSafe) порівнюють рядки
    # '\\?\C:\LIMS\MODEL' і 'C:\LIMS\MODEL' як РІЗНІ шляхи, хоча
    # фізично це ОДНЕ Й ТЕ САМЕ розташування — namespace-псевдонім міг
    # би пройти перевірку "не перетинається із захищеним live-джерелом",
    # і подальше створення/рекурсивне очищення staging реально
    # торкнулося б production-даних через псевдонім.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '^\\\\[?.]\\') { return $false }
    if ($Value -match '^[A-Za-z]:[\\/]') { return $true }
    if ($Value -match '^\\\\[^\\/]+\\[^\\/]+') { return $true }
    return $false
}

function ConvertTo-BRAVODataRestoreElevationArgument {
    # Безпечна серіалізація ОДНОГО значення в ОДИН елемент командного рядка
    # для Start-Process -ArgumentList: масив рядків, переданий у
    # -ArgumentList, з'єднується у рядок командного рядка без додаткового
    # екранування з боку Start-Process. Без цього недовірене значення з
    # пробілом (напр. GenerationId "20260815_120000 -Force") дочірній
    # елевований процес зв'язав би як ДВА окремих аргументи — валідний
    # -GenerationId плюс впроваджений перемикач. Обгортання в лапки за
    # стандартним Win32/CommandLineToArgvW правилом (подвоєння backslash
    # перед лапкою чи в кінці рядка, екранування самих лапок) гарантує, що
    # одне батьківське значення завжди стає РІВНО одним дочірнім аргументом
    # незалежно від вмісту.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# Один зовнішній try/finally: exit усередині try гарантовано проходить крізь
# усі finally на своєму шляху, тому ручна пауза охоплює кожну точку виходу
# (той самий принцип, що BRAVO_MAINTENANCE).
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

# Елевація потрібна всім режимам, що виконують реальні дії (7-Zip у
# production-каталоги, керування службами, ACL). -ListGenerations — read-only
# перегляд і виконується без елевації (як BRAVO_RESTORE_TEST). SYSTEM не має
# інтерактивного UAC-сеансу, Start-Process -Verb RunAs там повертає 0x80070001.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isLocalSystem = $currentIdentity.User.Value -eq 'S-1-5-18'
if (-not $ListGenerations -and -not $isLocalSystem -and -not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # ДО побудови аргументів елевації: значення, ще не розщеплене ОС на
    # окремі argv-токени, або відповідає канонічному формату generationId,
    # або цілком відхиляється тут, ДО Start-Process. Перевірка ПІСЛЯ
    # елевації (нижче за текстом файлу) вже НЕ бачить впровадженого вмісту
    # — до того моменту рядок уже розщепив CreateProcess дочірнього
    # процесу.
    if (-not [string]::IsNullOrWhiteSpace($GenerationId) -and
        -not (Test-BRAVODataRestoreGenerationIdFormat -GenerationId $GenerationId)) {
        Write-Host "ПОМИЛКА: -GenerationId має недопустимий формат (yyyyMMdd_HHmmss, опційно з collision-safe суфіксом _N): '$GenerationId'" -ForegroundColor Red
        exit 30
    }
    $elevatedArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-BRAVODataRestoreElevationArgument -Value $EntryScriptPath))
    if (-not [string]::IsNullOrWhiteSpace($GenerationId)) { $elevatedArguments += @("-GenerationId", (ConvertTo-BRAVODataRestoreElevationArgument -Value $GenerationId)) }
    # Component/Mode/Source — типізовано обмежені [ValidateSet] у param()
    # цього ж скрипта: значення, що досягло цієї точки, вже гарантовано
    # належить фіксованому переліку без пробілів/спецсимволів.
    $elevatedArguments += @("-Component", $Component, "-Mode", $Mode, "-Source", $Source)
    if (-not [string]::IsNullOrWhiteSpace($TargetPath)) { $elevatedArguments += @("-TargetPath", (ConvertTo-BRAVODataRestoreElevationArgument -Value $TargetPath)) }
    if (-not [string]::IsNullOrWhiteSpace($StagingPath)) { $elevatedArguments += @("-StagingPath", (ConvertTo-BRAVODataRestoreElevationArgument -Value $StagingPath)) }
    if ($Force) { $elevatedArguments += "-Force" }
    if ($SkipHealthCheck) { $elevatedArguments += "-SkipHealthCheck" }
    if ($TimeoutSeconds -gt 0) { $elevatedArguments += @("-TimeoutSeconds", [string]$TimeoutSeconds) }
    if ($NoPause) { $elevatedArguments += "-NoPause" }
    # AUTO -> не вбудовувати -ConfigPath у relaunch: elevated-процес сам
    # повторить ту саму auto-derivation. EXPLICIT -> зберегти точний шлях
    # (свідомий намір оператора не повинен губитись при елевації).
    if ($configPathWasExplicit) {
        $elevatedArguments += @("-ConfigPath", (ConvertTo-BRAVODataRestoreElevationArgument -Value $ConfigPath))
    }
    $elevatedProcess = Start-Process powershell.exe -ArgumentList $elevatedArguments -Verb RunAs -Wait -PassThru
    Exit $elevatedProcess.ExitCode
}

# Примусово TLS 1.2 для webhook-сповіщень. Числове значення 3072 сумісне зі
# старими .NET/PowerShell, де ім'я Tls12 може бути відсутнім у переліку enum.
[Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
[Net.ServicePointManager]::Expect100Continue = $false

# ===== СТАН ПРОГОНУ =====
# Set-StrictMode успадковується від конфігураційного завантажувача, тому весь
# стан ініціалізується явно до першого читання.
$script:ScriptStartTime = [DateTime]::Now
$script:dataRestoreControlledAbort = $false
$script:dataRestoreAbortReason = $null
$script:flagInvalidConfiguration = $false
$script:flagCredentialsUnavailable = $false
$script:flagIntegrityTestFailed = $false
$script:flagHashValidationFailed = $false
$script:flagRestoreFailed = $false
$script:flagSftpFailed = $false
$script:flagInternalError = $false
$script:dataRestoreWarningCount = 0
$script:dataRestoreComponentResults = New-Object System.Collections.ArrayList
$script:dataRestoreOperationLock = $null
$script:dataRestoreOperationLockPath = $null
$script:dataRestoreServiceSnapshot = $null
$script:dataRestoreServicesStopped = $false
# true після успішного запису ownership-маркера зупинки служб цим прогоном
# (BRAVO_SERVICE_QUIESCENCE.json): чистити/позначати suppressed можна лише
# ВЛАСНИЙ маркер — чужий осиротілий опрацьовує Health-watchdog.
$script:dataRestoreQuiescenceMarkerWritten = $false
# true, якщо відкат (поточного компонента АБО раніше завершених) не
# гарантовано довершився — тоді live filesystem у невизначеному стані, і
# служби НЕ можна запускати поверх нього (див. фінальний finally нижче).
$script:dataRestoreRollbackIncomplete = $false
$script:dataRestoreHealthExitCode = $null
$script:dataRestoreSelectedGenerationId = $null
$script:dataRestoreStagingGenerationRoot = $null
$script:dataRestoreStagingKept = $false
$script:dataRestoreLogFile = $null
$script:dataRestoreSftpUrl = $null
$script:dataRestoreTemporaryRoot = $null
$script:archivePassword = $null

# ===== ЗАВАНТАЖЕННЯ НАЛАШТУВАНЬ =====
# P0 Configuration Foundation: BRAVO.config став опційним основним
# override-шаром — попередня жорстка "файл мусить існувати" перевірка
# (і Resolve-Path, який теж вимагав існування) дублювала те саме рішення,
# яке Import-BravoConfiguration тепер приймає коректно сама (auto-derived
# відсутній BRAVO.config -> canonical built-in defaults + BRAVO.local.
# config; явно вказаний відсутній -ConfigPath -> як і раніше, помилка,
# перехоплена нижче тим самим catch/exit 30).
try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $configRoot = Split-Path -Path $ConfigPath -Parent
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

    # Обов'язкові для відновлення значення конфігурації — усі з наявних
    # секцій, жодного нового ключа BRAVO.config цей runtime не вводить.
    $requiredScalarValues = @(
        @{ Name = 'operationLockSettings.Path'; Value = [string]$operationLockSettings.Path },
        @{ Name = 'backupRootPath (EffectiveBackupRoot)'; Value = [string]$backupRootPath },
        @{ Name = 'arcPath (Tools\7za.exe)'; Value = [string]$arcPath },
        @{ Name = 'toolsPath'; Value = [string]$toolsPath },
        @{ Name = 'runtimeLogRoot'; Value = [string]$global:runtimeLogRoot },
        @{ Name = 'maintenanceSettings.Services.BravoName'; Value = [string]$maintenanceSettings.Services.BravoName },
        @{ Name = 'maintenanceSettings.Services.ExchangeApiName'; Value = [string]$maintenanceSettings.Services.ExchangeApiName }
    )
    foreach ($requiredScalar in $requiredScalarValues) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredScalar.Value)) {
            throw "У конфігурації відсутній обов'язковий параметр '$($requiredScalar.Name)'"
        }
    }
    if ($null -eq $global:archiveDefinitions -or @($global:archiveDefinitions).Count -eq 0) {
        throw "У конфігурації відсутній обов'язковий параметр 'archiveDefinitions'"
    }
    if ($null -eq $maintenanceSettings.Limits -or $null -eq $maintenanceSettings.Limits.MinimumFreeSpaceGB) {
        throw "У конфігурації відсутній обов'язковий параметр 'maintenanceSettings.Limits.MinimumFreeSpaceGB'"
    }
    # Від'ємний/нескінченний/NaN поріг зробив би free-space preflight
    # (Test-BRAVODataRestoreFreeSpace) хибно успішним: перевірка
    # "$availableBytes - $requiredBytes -lt $floorBytes" з від'ємним
    # $floorBytes могла б пропустити том, на якому реально бракує місця.
    $parsedMinimumFreeSpaceGB = [double]0
    if (-not (Test-BRAVODataRestoreMinimumFreeSpaceGB -Value $maintenanceSettings.Limits.MinimumFreeSpaceGB -ValidatedGigabytes ([ref]$parsedMinimumFreeSpaceGB))) {
        throw "'maintenanceSettings.Limits.MinimumFreeSpaceGB' має бути невід'ємним скінченним числом: '$($maintenanceSettings.Limits.MinimumFreeSpaceGB)'"
    }
    if ($null -eq $global:progressSettings -or $null -eq $progressSettings.SevenZipTimeoutSeconds) {
        throw "У конфігурації відсутній обов'язковий параметр 'progressSettings.SevenZipTimeoutSeconds'"
    }
    if ($null -eq $global:schedulerSettings -or -not $schedulerSettings.Contains('OperationLockWaitMinutes')) {
        throw "У конфігурації відсутній обов'язковий параметр 'schedulerSettings.OperationLockWaitMinutes'"
    }
} catch {
    Write-Host "ПОМИЛКА читання конфігурації '$ConfigPath': $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -ForegroundColor Red
    exit 30
}

# Ефективні значення прогону.
$script:effectiveSevenZipTimeoutSeconds = if ($TimeoutSeconds -gt 0) {
    $TimeoutSeconds
} else {
    [int]$progressSettings.SevenZipTimeoutSeconds
}
$stagingRootPath = if ([string]::IsNullOrWhiteSpace($StagingPath)) {
    Join-Path $backupRootPath 'RESTORE_STAGING'
} else {
    # Абсолютність вимагається явно (round-7 P2, посилено follow-up P2):
    # на відміну від -TargetPath (Get-BRAVODataRestorePlan уже вимагає
    # IsPathRooted), -StagingPath раніше йшов напряму в GetFullPath без цієї
    # перевірки — відносне значення резолвилось відносно робочого каталогу
    # ЕЛЕВОВАНОГО процесу (типово системний/runtime каталог, не те, що
    # оператор мав на увазі), і SFTP-завантаження та рекурсивне очищення
    # generation відбувались би саме там. [System.IO.Path]::IsPathRooted()
    # САМ ПО СОБІ недостатній: він вважає диск-відносні ('C:RESTORE_STAGING')
    # і корінь-відносні ('\RESTORE_STAGING') значення "rooted", хоча обидва
    # фактично резолвяться відносно поточного (диска/елевованого процесу)
    # контексту — той самий клас небезпеки. Test-BRAVODataRestoreFullyQualifiedWindowsPath
    # приймає лише справді фіксовані форми (буква-диска:\ або UNC \\сервер\ресурс).
    # Некоректний/невирішуваний шлях тут МУСИТЬ класифікуватись як
    # InvalidConfiguration (exit 30), а не провалюватись у generic
    # catch-all InternalError (exit 90) нижче за файлом.
    $expandedStagingPath = [Environment]::ExpandEnvironmentVariables($StagingPath)
    if (-not (Test-BRAVODataRestoreFullyQualifiedWindowsPath -Value $expandedStagingPath)) {
        Write-Host "ПОМИЛКА: -StagingPath має бути повністю кваліфікованим шляхом (буква-диска:\ або UNC \\сервер\ресурс): $StagingPath" -ForegroundColor Red
        exit 30
    }
    try {
        [System.IO.Path]::GetFullPath($expandedStagingPath)
    } catch {
        Write-Host "ПОМИЛКА: -StagingPath некоректний: $($_.Exception.Message)" -ForegroundColor Red
        exit 30
    }
}
$serviceStartTimeoutSeconds = if ([int]$maintenanceSettings.Services.StartTimeoutSeconds -gt 0) {
    [int]$maintenanceSettings.Services.StartTimeoutSeconds
} else { 180 }
$serviceStopTimeoutSeconds = if ([int]$maintenanceSettings.Services.StopTimeoutSeconds -gt 0) {
    [int]$maintenanceSettings.Services.StopTimeoutSeconds
} else { 120 }
$servicePollIntervalSeconds = if ([int]$maintenanceSettings.Services.PollIntervalSeconds -gt 0) {
    [int]$maintenanceSettings.Services.PollIntervalSeconds
} else { 2 }
$runTimestamp = $script:ScriptStartTime.ToString('yyyyMMdd_HHmmss')

# ===== ЖУРНАЛ =====
$script:dataRestoreLogFile = Join-Path $global:runtimeLogRoot ("BRAVO_DATA_RESTORE_{0}_PID{1}.log" -f $runTimestamp, $PID)
Initialize-BRAVOLog -LogFile $script:dataRestoreLogFile -FileLevel 'INFO' -ConsoleLevel 'WARNING'

function Write-DataRestoreLog {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [string]$Level = 'INFO',
        [switch]$Console
    )
    Write-BRAVOLog -Message $Message -Level $Level -Component 'DATARESTORE' -Console:$Console
}

# Test-only deterministic failpoint для acceptance-тестів cross-component
# rollback (B20 і подібні). НЕ CLI-параметр, НЕ config-ключ, НЕ
# документована production-функція — активується виключно двома явними
# process environment variables, обидва мають точно збігтися. За
# відсутності/некоректності будь-якого з двох факторів — no-op, БЕЗ жодного
# side effect (файлова система/служби/мережа/config не торкаються).
#
# TWO-FACTOR guard (жодна змінна сама по собі недостатня):
#   BRAVO_DATARESTORE_TEST_HOOKS     — має дорівнювати РІВНО "ACCEPTANCE_ONLY"
#                                       (case-sensitive sentinel).
#   BRAVO_DATARESTORE_TEST_FAILPOINT — canonical форма "Point:Component",
#                                       напр. "AfterMoveAside:BAZA".
#
# Порівняння Point/Component — точна case-insensitive рівність (жодних
# wildcard/regex/substring/"All"). Викликається виключно з існуючого
# production pipeline у точці, де реальна помилка мала б статися
# природно — throw тут не створює окремого test-only rollback шляху:
# виняток летить у той самий catch, що обробляє й реальні відмови.
function Invoke-BRAVODataRestoreTestFailPoint {
    param(
        [Parameter(Mandatory = $true)][string]$Point,
        [Parameter(Mandatory = $true)][string]$Component
    )

    $hooksGuard = [string]$env:BRAVO_DATARESTORE_TEST_HOOKS
    if (-not [string]::Equals($hooksGuard, 'ACCEPTANCE_ONLY', [StringComparison]::Ordinal)) {
        return
    }

    $failPointRaw = [string]$env:BRAVO_DATARESTORE_TEST_FAILPOINT
    if ([string]::IsNullOrWhiteSpace($failPointRaw)) {
        return
    }

    $failPointParts = $failPointRaw -split ':', 2
    if ($failPointParts.Count -ne 2) {
        return
    }

    $configuredPoint = $failPointParts[0].Trim()
    $configuredComponent = $failPointParts[1].Trim()
    if ([string]::IsNullOrWhiteSpace($configuredPoint) -or [string]::IsNullOrWhiteSpace($configuredComponent)) {
        return
    }

    # Canonical allowlist: жоден Point/Component поза цим переліком не
    # активує failpoint, навіть якщо конфігурація точно збігається з
    # аргументами виклику. Це виключає випадкову активацію на
    # некалонічних значеннях (напр. синтетичний "BAZA", який раніше
    # використовувався у тестах, або майбутня точка, якої ще немає в
    # production pipeline).
    $canonicalPoints = @('AfterMoveAside')
    $canonicalComponents = @('MODEL', 'BLOG', 'BRAVOEXCH')
    $isCanonicalPoint = @($canonicalPoints | Where-Object {
        [string]::Equals($_, $configuredPoint, [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    $isCanonicalComponent = @($canonicalComponents | Where-Object {
        [string]::Equals($_, $configuredComponent, [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    if (-not $isCanonicalPoint -or -not $isCanonicalComponent) {
        return
    }

    if (-not [string]::Equals($configuredPoint, $Point, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    if (-not [string]::Equals($configuredComponent, $Component, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    throw "BRAVO_DATARESTORE_TEST_FAILPOINT: deterministic test-injected failure at $configuredPoint for component $configuredComponent"
}

# Контрольоване переривання пайплайна: виставляє категорію для контракту
# кодів завершення й кидає виняток, який головний catch розпізнає як
# заплановану зупинку (не InternalError). Використовується ПІСЛЯ захоплення
# lock — раніші відмови виходять літеральними exit 30/31/32, як у Maintenance.
function Stop-BRAVODataRestoreRun {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InvalidConfiguration', 'CredentialsUnavailable', 'IntegrityTestFailed', 'HashValidationFailed', 'RestoreFailed', 'SftpFailed')]
        [string]$Category,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    switch ($Category) {
        'InvalidConfiguration'  { $script:flagInvalidConfiguration = $true }
        'CredentialsUnavailable' { $script:flagCredentialsUnavailable = $true }
        'IntegrityTestFailed'   { $script:flagIntegrityTestFailed = $true }
        'HashValidationFailed'  { $script:flagHashValidationFailed = $true }
        'RestoreFailed'         { $script:flagRestoreFailed = $true }
        'SftpFailed'            { $script:flagSftpFailed = $true }
    }
    $script:dataRestoreControlledAbort = $true
    $script:dataRestoreAbortReason = $Reason
    Write-DataRestoreLog -Message "ЗУПИНКА ($Category): $Reason" -Level 'ERROR'
    throw "DATA_RESTORE_ABORT: $Reason"
}

function Test-BRAVODataRestorePathWithin {
    # Чи лежить Path строго всередині Directory (нормалізовані повні шляхи,
    # OrdinalIgnoreCase — NTFS нечутлива до регістру).
    param([string]$Path, [string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Directory)) {
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
        $directoryPrefix = $fullDirectory.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        return $fullPath.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        # Некоректний шлях безпечніше вважати "всередині" (заборонити), ніж дозволити.
        return $true
    }
}

function Test-BRAVODataRestorePathEquals {
    param([string]$First, [string]$Second)

    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {
        return $false
    }
    try {
        $firstFull = [System.IO.Path]::GetFullPath($First).TrimEnd('\', '/')
        $secondFull = [System.IO.Path]::GetFullPath($Second).TrimEnd('\', '/')
        return [string]::Equals($firstFull, $secondFull, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $true
    }
}

function Test-BRAVODataRestorePathHasReparseAncestor {
    # Test-BRAVODataRestorePathWithin/-PathEquals — лише лексична
    # нормалізація (GetFullPath): вони НЕ бачать, що каталог фізично є
    # junction/symlink/mount point на іншу ціль. Шлях-псевдонім (напр.
    # D:\RESTORE_LINK -> junction на C:\LIMS\BLOG) пройшов би обидві
    # перевірки, реально вказуючи всередину live production-дерева.
    # Надійне вирішення фізичної цілі reparse-точки в .NET Framework 4.x
    # (Windows PowerShell 5.1) вимагало б P/Invoke до
    # GetFinalPathNameByHandle; замість крихкого часткового парсера ця
    # перевірка — fail-closed (Option B): якщо сам шлях АБО будь-який
    # НАЯВНИЙ предок є reparse-точкою, шлях відхиляється як небезпечний
    # для запису/знищення незалежно від того, куди саме він фізично веде.
    # Компонент цілі, що ще НЕ існує (нормальний випадок — план вимагає
    # відсутності), не заважає перевірці: цикл підіймається до першого
    # НАЯВНОГО предка.
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        # Шлях, що не парситься — безпечніше відхилити.
        return $true
    }

    $current = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        try {
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return $true
                }
            }
        } catch {
            # Недоступний/аномальний стан предка (напр. permission denied,
            # broken reparse target) — безпечніше відхилити, ніж дозволити.
            return $true
        }
        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or
            [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
    return $false
}

function Get-BRAVODataRestoreGenerationIdSortKey {
    # Канонічний ключ хронологічного сортування generationId: timestamp
    # (yyyyMMdd_HHmmss) як [datetime] + collision-safe суфікс (_N, за
    # замовчуванням 0) як [int] — НЕ lexicographic порівняння рядка, де
    # "..._9" помилково сортується ПІСЛЯ "..._10". Некоректний формат
    # (не мало б статись після Test-BRAVODataRestoreGenerationIdFormat, але
    # fail-safe і тут) дає найстарший можливий ключ — програє будь-якому
    # валідному значенню, а не випадково виграє.
    param([Parameter(Mandatory = $true)][string]$GenerationId)

    $match = [regex]::Match($GenerationId, '^(?<ts>\d{8}_\d{6})(?:_(?<suffix>\d+))?$')
    if (-not $match.Success) {
        return [pscustomobject]@{ Timestamp = [datetime]::MinValue; Suffix = 0 }
    }
    $timestamp = try {
        [datetime]::ParseExact($match.Groups['ts'].Value, 'yyyyMMdd_HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        [datetime]::MinValue
    }
    # [int]::TryParse замість прямого [int]-касту: цю функцію може викликати
    # хтось напряму (не лише після Test-BRAVODataRestoreGenerationIdFormat),
    # а недовірений suffix поза Int32-діапазоном не повинен валити сортування
    # необробленим OverflowException — некоректний suffix трактується так
    # само fail-safe, як і некоректний формат вище (найстарший ключ).
    $suffix = 0
    if ($match.Groups['suffix'].Success -and
        -not [int]::TryParse(
            $match.Groups['suffix'].Value,
            [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$suffix)) {
        return [pscustomobject]@{ Timestamp = [datetime]::MinValue; Suffix = 0 }
    }
    return [pscustomobject]@{ Timestamp = $timestamp; Suffix = $suffix }
}

function Sort-BRAVODataRestoreManifestNamesByGenerationDescending {
    # Сортує ІМЕНА manifest-файлів (BRAVO_BACKUP_<generationId>.json) за
    # канонічним хронологічним ключем (timestamp DESC, suffix numeric
    # DESC), а не за лексикографічним порядком самого рядка імені файлу.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ManifestNames)

    return @($ManifestNames | ForEach-Object {
        $generationId = [IO.Path]::GetFileNameWithoutExtension($_) -replace '^BRAVO_BACKUP_', ''
        $sortKey = Get-BRAVODataRestoreGenerationIdSortKey -GenerationId $generationId
        [pscustomobject]@{ Name = $_; Timestamp = $sortKey.Timestamp; Suffix = $sortKey.Suffix }
    } | Sort-Object -Property @{Expression = 'Timestamp'; Descending = $true }, @{Expression = 'Suffix'; Descending = $true } |
        Select-Object -ExpandProperty Name)
}

function Test-BRAVODataRestoreArchiveSize {
    # Канонічна перевірка недовіреного component.ArchiveSize зі ЗМІСТУ
    # manifest-а (особливо SFTP-джерела) ПЕРЕД тим, як значення бере участь
    # у розрахунку вимог до вільного місця в staging. Без цієї перевірки
    # відсутнє/нульове/від'ємне значення пропускає або занижує free-space
    # preflight, і завантаження великого архіву може вичерпати staging-том
    # раніше, ніж спрацюють подальші hash/inventory перевірки.
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Value,
        [Parameter(Mandatory = $true)][ref]$ValidatedBytes
    )
    $ValidatedBytes.Value = [long]0
    if ($null -eq $Value) { return $false }
    # Скалярне значення (не масив/об'єкт/hashtable) — недовірений JSON може
    # містити довільну структуру замість числа.
    if (($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) -or
        $Value -is [pscustomobject] -or $Value -is [hashtable]) {
        return $false
    }
    $parsedBytes = [long]0
    if (-not [long]::TryParse(
            [string]$Value,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsedBytes)) {
        return $false
    }
    if ($parsedBytes -le 0) { return $false }
    $ValidatedBytes.Value = $parsedBytes
    return $true
}

function Test-BRAVODataRestoreAsciiPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return ($Path -match '^[\x20-\x7E]+$')
}

function Test-BRAVODataRestoreToolIntegrity {
    # Той самий Enforce/Warn-контракт, що Test-Compatibility у Archive:
    # runtime виконує 7za.exe/WinSCP.com від імені адміністратора, тому
    # перед запуском інструмент звіряється з version-controlled
    # TOOLS_MANIFEST.json.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ToolNames)

    $integrityMode = 'Enforce'
    $manifestPath = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.Mode)) {
            $integrityMode = [string]$toolIntegritySettings.Mode
        }
        $manifestPath = [string]$toolIntegritySettings.ManifestPath
    } catch {
        $manifestPath = $null
    }
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        $manifestPath = Join-Path $toolsPath 'TOOLS_MANIFEST.json'
    }

    $problems = @()
    $manifestTools = $null
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $problems += "маніфест інструментів не знайдено: $manifestPath"
    } else {
        try {
            $manifestDocument = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -ErrorAction Stop
            $manifestTools = $manifestDocument.tools
        } catch {
            $problems += "маніфест інструментів не прочитано: $($_.Exception.Message)"
        }
    }
    if ($null -ne $manifestTools) {
        foreach ($toolName in $ToolNames) {
            $toolPath = Join-Path $toolsPath $toolName
            $expectedProperty = $manifestTools.PSObject.Properties[$toolName]
            if ($null -eq $expectedProperty -or [string]::IsNullOrWhiteSpace([string]$expectedProperty.Value)) {
                $problems += "у TOOLS_MANIFEST.json немає еталонного хешу для $toolName"
                continue
            }
            if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
                $problems += "інструмент не знайдено: $toolPath"
                continue
            }
            $actualHash = (Get-BRAVOFileHash -Path $toolPath -Algorithm SHA256).Hash
            if (-not [string]::Equals($actualHash, [string]$expectedProperty.Value, [StringComparison]::OrdinalIgnoreCase)) {
                $problems += "хеш $toolName не збігається з TOOLS_MANIFEST.json (можлива підміна інструменту)"
            }
        }
    }
    return [pscustomobject]@{
        Mode = $integrityMode
        Problems = @($problems)
    }
}

function Enter-BRAVODataRestoreOperationLock {
    # Canonical machine-wide operation lock — той самий контракт і файл, що
    # Archive/Maintenance ($operationLockSettings.Path): активність визначає
    # ексклюзивний handle, а не існування файла; метадані лишаються після
    # завершення як остання діагностика.
    $lockPath = [string]$operationLockSettings.Path
    try {
        if ([string]::IsNullOrWhiteSpace($lockPath)) {
            throw 'operationLockSettings.Path не задано'
        }
        $lockDirectory = Split-Path -Path $lockPath -Parent
        if (-not (Test-Path -LiteralPath $lockDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $lockDirectory -Force -ErrorAction Stop)
        }
        $waitMinutes = [math]::Max(0, [int]$schedulerSettings.OperationLockWaitMinutes)
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
        # Від цього моменту $stream належить ЦІЙ функції, доки метадані не
        # записано успішно — власність переходить до викликача лише разом
        # з успішним return нижче. Якщо SetLength/Write/Flush провалиться
        # (напр. диск заповнено), відкритий handle МУСИТЬ бути звільнений
        # тут-таки: зовнішній catch знає лише повернути Success=false і не
        # має посилання на $stream, інакше machine-wide lock лишився б
        # захопленим до непередбачуваного GC і блокував би подальші
        # Archive/Maintenance/restore-прогони.
        try {
            $lockProcessStartTime = try {
                (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString("o")
            } catch {
                $null
            }
            $lockText = ([pscustomobject]@{
                pid = $PID
                processStartTime = $lockProcessStartTime
                hostname = [Environment]::MachineName
                operation = "DataRestore"
                startedAt = (Get-Date).ToString("o")
                packageVersion = [string]$script:ScriptVersion
                config = $ConfigPath
                generationId = $null
            } | ConvertTo-Json -Compress)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
            $stream.SetLength(0)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } catch {
            $stream.Dispose()
            throw
        }
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

function Exit-BRAVODataRestoreOperationLock {
    if ($script:dataRestoreOperationLock) {
        $script:dataRestoreOperationLock.Dispose()
        $script:dataRestoreOperationLock = $null
    }
    # Файл метаданих навмисно лишається: активність визначає лише handle.
    $script:dataRestoreOperationLockPath = $null
}

function Get-BRAVODataRestoreGenerationCandidates {
    # Швидкий огляд наявних generation для -ListGenerations і журналу:
    # прапорці manifest + фізична наявність артефактів + парсинг sidecar,
    # БЕЗ перерахунку SHA512 (не хешувати десятки ГБ на кожен перегляд —
    # повний перерахунок робить строгий gate перед фактичним відновленням).
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [int]$Limit = 25
    )

    $candidates = @()
    foreach ($manifestFile in @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $BackupRoot)) {
        try {
            $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json -ErrorAction Stop
        } catch {
            # Нечитабельний manifest не зникає мовчки з переліку: без цього
            # WARNING оператор у -ListGenerations взагалі не дізнався б, що
            # generation існує, але її manifest пошкоджено.
            Write-DataRestoreLog -Message "УВАГА: generation manifest пропущено (не прочитано): $($manifestFile.FullName) — $($_.Exception.Message)" -Level 'WARNING' -Console
            continue
        }
        $createdAt = $manifestFile.LastWriteTime
        foreach ($dateProperty in @('createdAt', 'startedAt')) {
            $property = $manifest.PSObject.Properties[$dateProperty]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                try { $createdAt = [datetime]$property.Value } catch {
                    # Нечитабельна дата в manifest не дискваліфікує generation:
                    # лишаємо LastWriteTime файлу як сортувальний fallback.
                }
                break
            }
        }
        $componentSummaries = @()
        $componentsProperty = $manifest.PSObject.Properties['components']
        if ($null -ne $componentsProperty -and $null -ne $componentsProperty.Value) {
            foreach ($componentProperty in @($componentsProperty.Value.PSObject.Properties)) {
                $state = $componentProperty.Value
                if (-not [bool]$state.Enabled) { continue }
                $summary = 'OK'
                if (-not ([bool]$state.CreateSuccess -and [bool]$state.IntegritySuccess -and [bool]$state.HashSuccess)) {
                    $summary = 'НЕПОВНИЙ'
                } elseif (-not ((Test-Path -LiteralPath ([string]$state.ArchivePath) -PathType Leaf) -and
                        (Test-Path -LiteralPath ([string]$state.HashPath) -PathType Leaf))) {
                    $summary = 'НЕМАЄ ФАЙЛІВ'
                } else {
                    try {
                        $sidecarText = ([IO.File]::ReadAllText([string]$state.HashPath)).Trim([char]0xFEFF).Trim()
                        $archiveLeafName = Split-Path ([string]$state.ArchivePath) -Leaf
                        if ($sidecarText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$' -or
                            $Matches.FileName -cne $archiveLeafName) {
                            $summary = 'SIDECAR?'
                        }
                    } catch {
                        $summary = 'SIDECAR?'
                    }
                }
                $componentSummaries += ("{0}:{1}" -f $componentProperty.Name, $summary)
            }
        }
        # Ім'я файлу vs generationId у ЗМІСТІ manifest-а — той самий
        # identity-контракт, що вже застосовується при виборі generation
        # (Get-BRAVORestoreGenerationManifest) і в SFTP-перегляді
        # (нижче за файлом): без цієї перевірки BRAVO_BACKUP_A.json з
        # JSON generationId=B показувався б як звичайний кандидат B, хоча
        # точний вибір -GenerationId B шукає САМЕ BRAVO_BACKUP_B.json і
        # не знайде його. Канонічний парсер імені файлу — спільний з
        # BRAVO.ArchiveHelpers (Get-BRAVOBackupManifestFilenameGenerationId),
        # а не окрема regex-копія в DataRestore.
        $filenameGenerationId = Get-BRAVOBackupManifestFilenameGenerationId -FileName $manifestFile.Name
        $jsonGenerationId = [string]$manifest.generationId
        $identityMismatch = [string]::IsNullOrWhiteSpace($filenameGenerationId) -or
            -not [string]::Equals($filenameGenerationId, $jsonGenerationId, [StringComparison]::Ordinal)
        $displayGenerationId = if ($identityMismatch) {
            $filenameLabel = if ([string]::IsNullOrWhiteSpace($filenameGenerationId)) { $manifestFile.Name } else { $filenameGenerationId }
            "$jsonGenerationId  (НЕЗБІЖНІСТЬ generationId: файл='$filenameLabel' JSON='$jsonGenerationId')"
        } else {
            $jsonGenerationId
        }
        $candidates += [pscustomobject]@{
            GenerationId = $displayGenerationId
            Status = [string]$manifest.status
            CreatedAt = $createdAt
            ComponentSummary = ($componentSummaries -join '  ')
        }
    }
    return @($candidates | Sort-Object CreatedAt -Descending | Select-Object -First ([math]::Max(1, $Limit)))
}

function Get-BRAVODataRestoreComponentSelection {
    # Перелік компонентів для відновлення: запитане ∩ увімкнене у manifest.
    # Явно запитаний компонент, якого немає або який вимкнено в manifest, —
    # керована відмова (RestoreFailed), а не мовчазний пропуск.
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$RequestedComponent
    )

    $componentsProperty = $Manifest.PSObject.Properties['components']
    if ($null -eq $componentsProperty -or $null -eq $componentsProperty.Value) {
        throw 'generation manifest не містить components'
    }
    $canonicalOrder = @('MODEL', 'BLOG', 'BRAVOEXCH')
    $enabledTypes = @()
    foreach ($canonicalType in $canonicalOrder) {
        $componentProperty = @($componentsProperty.Value.PSObject.Properties | Where-Object {
            [string]::Equals($_.Name, $canonicalType, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($componentProperty.Count -gt 0 -and [bool]$componentProperty[0].Value.Enabled) {
            $enabledTypes += $canonicalType
        }
    }
    if ($RequestedComponent -ne 'All') {
        if ($enabledTypes -notcontains $RequestedComponent) {
            throw "generation не містить увімкненого компонента $RequestedComponent"
        }
        return @($RequestedComponent)
    }
    if ($enabledTypes.Count -eq 0) {
        throw 'у generation немає жодного увімкненого archive-компонента'
    }
    return @($enabledTypes)
}

function Get-BRAVODataRestoreLiveSourceMap {
    # Канонічне обчислення live-джерела кожного компонента: пріоритет —
    # canonical discovery-каталог (RestoreTargetDirectories, existence-
    # independent, напр. bravoDiscoveryResult.BRAVOEXCH_SOURCE), fallback —
    # ArchiveDefinitions.Source-похідний каталог, коли ключ discovery
    # відсутній/порожній. Один канонічний власник — використовується і
    # плануванням (Get-BRAVODataRestorePlan), і staging-preflight
    # (Test-BRAVODataRestoreStagingSafe, виконується ДО будь-якого SFTP
    # filesystem-запису), щоб обидва місця бачили той самий набір
    # live-джерел без дублювання логіки виведення.
    param(
        [Parameter(Mandatory = $true)][object[]]$ArchiveDefinitions,
        [hashtable]$RestoreTargetDirectories
    )

    $liveSources = @{}
    foreach ($definition in $ArchiveDefinitions) {
        $definitionType = [string]$definition.Type
        $definitionSource = [string]$definition.Source
        $backupDerivedDirectory = if ([string]::IsNullOrWhiteSpace($definitionSource)) {
            $null
        } else {
            Split-Path $definitionSource -Parent
        }
        $canonicalTargetDirectory = if ($null -ne $RestoreTargetDirectories -and
            $RestoreTargetDirectories.ContainsKey($definitionType) -and
            -not [string]::IsNullOrWhiteSpace([string]$RestoreTargetDirectories[$definitionType])) {
            [string]$RestoreTargetDirectories[$definitionType]
        } else {
            $null
        }
        $liveSources[$definitionType] = if (-not [string]::IsNullOrWhiteSpace($canonicalTargetDirectory)) {
            $canonicalTargetDirectory
        } else {
            $backupDerivedDirectory
        }
    }
    return $liveSources
}

function Test-BRAVODataRestoreStagingSafe {
    # Preflight, що МУСИТЬ пройти ДО будь-якого SFTP filesystem-запису
    # (створення _manifests, завантаження generation-архівів). Без цієї
    # перевірки Invoke-BRAVODataRestoreSftpManifestFetch писав би у
    # StagingPath ДО того, як Get-BRAVODataRestorePlan (пізніший крок
    # pipeline) взагалі перевіряє шляхи — зловмисний/помилковий
    # -StagingPath, що дорівнює, містить чи вкладений у live
    # MODEL/BLOG/BRAVOEXCH, дав би змогу запис/подальше рекурсивне
    # очищення staging знищити production-дані ще до будь-якої перевірки.
    # Типовий (StagingPath не задано) staging НАВМИСНО лежить УСЕРЕДИНІ
    # BackupRoot (<BackupRoot>\RESTORE_STAGING) — це підтримувана поведінка
    # за замовчуванням, тому, на відміну від OutOfPlace -TargetPath,
    # BackupRoot тут НЕ у забороненому списку.
    param(
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRootPath,
        [Parameter(Mandatory = $true)][hashtable]$LiveSources
    )

    # Defense-in-depth (P1 follow-up, review 4945915094): усі перевірки
    # нижче — суто лексичні (GetFullPath) через
    # Test-BRAVODataRestorePathEquals/PathWithin. Win32 File/Device
    # Namespace префікси ('\\?\...', '\\.\...', включно з device-wrapped
    # UNC '\\?\UNC\сервер\ресурс\...') GetFullPath ЗБЕРІГАЄ дослівно
    # замість нормалізації до звичайної форми диска/UNC — тому '\\?\C:\LIMS\MODEL'
    # і 'C:\LIMS\MODEL' дають РІЗНІ рядки в порівнянні нижче, хоча
    # фізично це ОДНЕ Й ТЕ САМЕ розташування: staging під таким
    # namespace-псевдонімом пройшов би лексичну перевірку перетину, хоча
    # реально збігається із захищеним live-шляхом. Той самий canonical
    # валідатор, що й для -StagingPath на вході pipeline (не окрема
    # копія regex-політики) — виклик тут ловить БУДЬ-якого майбутнього/
    # іншого викликача цієї функції, що міг би обійти вхідну перевірку
    # -StagingPath.
    if (-not (Test-BRAVODataRestoreFullyQualifiedWindowsPath -Value $StagingRoot)) {
        return [pscustomobject]@{
            Success = $false
            Error = "staging-шлях не є підтримуваною повністю кваліфікованою формою (буква-диска:\ або звичайний UNC \\сервер\ресурс) — Windows device/file namespace префікси ('\\?\', '\\.\') заборонені: $StagingRoot"
        }
    }

    $protectedDirectories = @(
        @{ Name = 'RuntimeRoot'; Path = $RuntimeRootPath }
    )
    foreach ($liveSourceType in @($LiveSources.Keys)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$LiveSources[$liveSourceType])) {
            $protectedDirectories += @{ Name = "live-джерело $liveSourceType"; Path = [string]$LiveSources[$liveSourceType] }
        }
    }
    foreach ($protectedDirectory in $protectedDirectories) {
        if ((Test-BRAVODataRestorePathEquals -First $StagingRoot -Second $protectedDirectory.Path) -or
            (Test-BRAVODataRestorePathWithin -Path $StagingRoot -Directory $protectedDirectory.Path) -or
            (Test-BRAVODataRestorePathWithin -Path $protectedDirectory.Path -Directory $StagingRoot)) {
            return [pscustomobject]@{
                Success = $false
                Error = "staging-шлях перетинається з захищеним розташуванням ($($protectedDirectory.Name)): $($protectedDirectory.Path)"
            }
        }
    }
    if (Test-BRAVODataRestorePathHasReparseAncestor -Path $StagingRoot) {
        return [pscustomobject]@{
            Success = $false
            Error = "staging-шлях (або його наявний предок) є reparse-точкою (junction/symlink) — фізична ціль не може бути надійно перевірена: $StagingRoot"
        }
    }
    return [pscustomobject]@{ Success = $true; Error = $null }
}

function Get-BRAVODataRestorePlan {
    # План цілей відновлення: для кожного компонента — куди розпаковувати і
    # (для InPlace) куди зносити вбік поточні дані. Уся валідація шляхів
    # зосереджена тут; функція нічого не змінює на диску (unit-testable).
    param(
        [Parameter(Mandatory = $true)][string[]]$ComponentTypes,
        [Parameter(Mandatory = $true)][string]$RestoreMode,
        [string]$RequestedTargetPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRootPath,
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][object[]]$ArchiveDefinitions,
        # Canonical restore-target каталоги (Type -> шлях), НЕЗАЛЕЖНІ від
        # фізичної наявності: напр. bravoDiscoveryResult.BRAVOEXCH_SOURCE.
        # ArchiveDefinitions.Source для BRAVOEXCH навмисно existence-
        # qualified у BRAVO.config (порожній Source, коли черговий каталог
        # зараз відсутній — легітимний стан для idle-черги), але саме
        # ВІДСУТНІЙ production-каталог і є типовим disaster-restore
        # сценарієм: InPlace-ціль має братись із canonical discovery, а не
        # з backup-orientованого Source. Коли ключ відсутній/порожній —
        # fallback на ArchiveDefinitions.Source (стара поведінка).
        [hashtable]$RestoreTargetDirectories,
        [Parameter(Mandatory = $true)][string]$RunStamp
    )

    $liveSources = Get-BRAVODataRestoreLiveSourceMap `
        -ArchiveDefinitions $ArchiveDefinitions `
        -RestoreTargetDirectories $RestoreTargetDirectories

    $planComponents = @()
    if ($RestoreMode -eq 'OutOfPlace') {
        if ([string]::IsNullOrWhiteSpace($RequestedTargetPath)) {
            return [pscustomobject]@{ Success = $false; Error = 'для режиму OutOfPlace обов''язковий параметр -TargetPath'; TargetRoot = $null; Components = @() }
        }
        $expandedTarget = [Environment]::ExpandEnvironmentVariables($RequestedTargetPath)
        if (-not [System.IO.Path]::IsPathRooted($expandedTarget)) {
            return [pscustomobject]@{ Success = $false; Error = "-TargetPath має бути абсолютним шляхом: $RequestedTargetPath"; TargetRoot = $null; Components = @() }
        }
        try {
            $targetRoot = [System.IO.Path]::GetFullPath($expandedTarget)
        } catch {
            return [pscustomobject]@{ Success = $false; Error = "-TargetPath некоректний: $($_.Exception.Message)"; TargetRoot = $null; Components = @() }
        }
        if (Test-Path -LiteralPath $targetRoot -PathType Leaf) {
            return [pscustomobject]@{ Success = $false; Error = "-TargetPath вказує на файл, а не каталог: $targetRoot"; TargetRoot = $null; Components = @() }
        }
        # Лексична нормалізація (GetFullPath) вище не бачить, що
        # -TargetPath фізично є junction/symlink: перевірки нижче
        # порівнюють лише лексичний шлях і могли б пропустити ціль, що
        # насправді веде всередину live production-дерева.
        if (Test-BRAVODataRestorePathHasReparseAncestor -Path $targetRoot) {
            return [pscustomobject]@{ Success = $false; Error = "-TargetPath (або його наявний предок) є reparse-точкою (junction/symlink) — фізична ціль не може бути надійно перевірена: $targetRoot"; TargetRoot = $null; Components = @() }
        }
        # Заборонені цілі: комплект, резервні копії, staging, live-джерела —
        # у будь-який бік вкладеності. Відновлення ПОВЕРХ цих місць або
        # НАВКОЛО них зробило б retention/backup/runtime непередбачуваними.
        $forbiddenDirectories = @(
            @{ Name = 'BackupRoot'; Path = $BackupRoot },
            @{ Name = 'RuntimeRoot'; Path = $RuntimeRootPath },
            @{ Name = 'staging'; Path = $StagingRoot }
        )
        # УСІ discovered live-джерела (MODEL/BLOG/BRAVOEXCH), а не лише
        # запитаний -Component: ціль OutOfPlace не має права влучити навіть
        # у production-джерело компонента, який зараз НЕ відновлюється —
        # інакше відновлення MODEL могло б випадково знищити live BLOG.
        foreach ($liveSourceType in @($liveSources.Keys)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$liveSources[$liveSourceType])) {
                $forbiddenDirectories += @{ Name = "live-джерело $liveSourceType"; Path = [string]$liveSources[$liveSourceType] }
            }
        }
        foreach ($forbidden in $forbiddenDirectories) {
            if ((Test-BRAVODataRestorePathEquals -First $targetRoot -Second $forbidden.Path) -or
                (Test-BRAVODataRestorePathWithin -Path $targetRoot -Directory $forbidden.Path) -or
                (Test-BRAVODataRestorePathWithin -Path $forbidden.Path -Directory $targetRoot)) {
                return [pscustomobject]@{ Success = $false; Error = "-TargetPath перетинається з захищеним розташуванням ($($forbidden.Name)): $($forbidden.Path)"; TargetRoot = $null; Components = @() }
            }
        }
        foreach ($componentType in $ComponentTypes) {
            $componentTarget = Join-Path $targetRoot $componentType
            # Ціль компонента МУСИТЬ бути відсутньою (не лише "порожньою, якщо
            # існує"): якщо дозволити наперед існуючий ПОРОЖНІЙ каталог, run
            # не може відрізнити "каталог створив я" від "каталог належить
            # оператору" (напр. з власним ACL) у ТІЙ Ж САМІЙ точці, звідки
            # cleanup при відмові пізніше безумовно видаляв би target. Runtime
            # створює компонентний каталог сам і явно володіє ним — інакше
            # відмова компонента могла б знищити чужий, не створений цим
            # прогоном каталог.
            if (Test-Path -LiteralPath $componentTarget) {
                return [pscustomobject]@{ Success = $false; Error = "ціль компонента вже існує (має бути відсутньою — runtime створює її сам): $componentTarget"; TargetRoot = $null; Components = @() }
            }
            $planComponents += [pscustomobject]@{
                Type = $componentType
                LiveSourceDirectory = [string]$liveSources[$componentType]
                TargetDirectory = $componentTarget
                PrerestoreDirectory = $null
            }
        }
        return [pscustomobject]@{ Success = $true; Error = $null; TargetRoot = $targetRoot; Components = @($planComponents) }
    }

    # InPlace: -TargetPath заборонений (щоб оператор не міг ДУМАТИ, що керує
    # ціллю, коли нею керує discovery), джерело кожного компонента має бути
    # однозначно визначене — мовчазний fallback заборонений проєктом.
    if (-not [string]::IsNullOrWhiteSpace($RequestedTargetPath)) {
        return [pscustomobject]@{ Success = $false; Error = 'для режиму InPlace параметр -TargetPath заборонений: ціль визначає discovery (bravo.ini)'; TargetRoot = $null; Components = @() }
    }
    # Лексичні Test-BRAVODataRestorePathEquals/-PathWithin нижче (і
    # intersection-перевірка після цього циклу) не бачать junction/symlink-
    # аліасів. КОЖНЕ discovered live-джерело (не лише обране цим прогоном)
    # бере участь як межа безпеки в подальших перевірках — reparse-аліас на
    # будь-якому з них (обраному чи ні) міг би дати move-aside обраного
    # компонента фізично влучити в інший захищений каталог, лишаючись
    # лексично "непересічним" (напр. D:\LIMS_LINK\MODEL, де D:\LIMS_LINK —
    # junction на НЕобраний BLOG). Перевірка виконується ДО побудови
    # PrerestoreDirectory/TargetDirectory нижче.
    foreach ($liveSourceType in @($liveSources.Keys)) {
        $liveSourcePathForReparseCheck = [string]$liveSources[$liveSourceType]
        if ([string]::IsNullOrWhiteSpace($liveSourcePathForReparseCheck)) { continue }
        if (Test-BRAVODataRestorePathHasReparseAncestor -Path $liveSourcePathForReparseCheck) {
            return [pscustomobject]@{
                Success = $false
                Error = "live-джерело $liveSourceType ($liveSourcePathForReparseCheck) (або його наявний предок) є reparse-точкою (junction/symlink) — фізична ціль не може бути надійно перевірена: InPlace неможливий"
                TargetRoot = $null
                Components = @()
            }
        }
    }
    foreach ($componentType in $ComponentTypes) {
        $liveSource = [string]$liveSources[$componentType]
        if ([string]::IsNullOrWhiteSpace($liveSource)) {
            return [pscustomobject]@{ Success = $false; Error = "live-джерело компонента $componentType не визначено (bravo.ini/discovery) — InPlace неможливий"; TargetRoot = $null; Components = @() }
        }
        $prerestoreBase = "{0}.prerestore_{1}" -f $liveSource.TrimEnd('\', '/'), $RunStamp
        $prerestoreDirectory = $prerestoreBase
        $collisionIndex = 1
        while (Test-Path -LiteralPath $prerestoreDirectory) {
            $prerestoreDirectory = "{0}_{1}" -f $prerestoreBase, $collisionIndex
            $collisionIndex++
        }
        $planComponents += [pscustomobject]@{
            Type = $componentType
            LiveSourceDirectory = $liveSource
            TargetDirectory = $liveSource
            PrerestoreDirectory = $prerestoreDirectory
        }
    }
    # Кожне ОБРАНЕ live-джерело перевіряється проти УСІХ discovered
    # live-джерел ($liveSources), а не лише проти інших ОБРАНИХ компонентів:
    # коли -Component вибирає лише один компонент, цикл вище будує
    # $planComponents лише з нього, і попарна перевірка лише всередині
    # $planComponents не побачила б перетину з НЕобраним компонентом
    # (напр. обраний MODEL = C:\LIMS, необраний BLOG = C:\LIMS\BLOG).
    # Рівність/вкладеність у БУДЬ-ЯКУ сторону з будь-яким іншим discovered
    # компонентом однаково небезпечна: move-aside обраного компонента
    # знесе вбік чужий (можливо, необраний і тому взагалі не відновлюваний
    # цим прогоном) live-каталог.
    foreach ($planComponent in $planComponents) {
        $selectedDirectory = [string]$planComponent.LiveSourceDirectory
        foreach ($otherType in @($liveSources.Keys)) {
            if ($otherType -eq $planComponent.Type) { continue }
            $otherDirectory = [string]$liveSources[$otherType]
            if ([string]::IsNullOrWhiteSpace($otherDirectory)) { continue }
            if ((Test-BRAVODataRestorePathEquals -First $selectedDirectory -Second $otherDirectory) -or
                (Test-BRAVODataRestorePathWithin -Path $selectedDirectory -Directory $otherDirectory) -or
                (Test-BRAVODataRestorePathWithin -Path $otherDirectory -Directory $selectedDirectory)) {
                return [pscustomobject]@{
                    Success = $false
                    Error = "live-джерело компонента $($planComponent.Type) ($selectedDirectory) перетинається з live-джерелом $otherType ($otherDirectory) — InPlace неможливий: move-aside одного знищив би дані іншого (незалежно від того, чи $otherType обрано для відновлення)"
                    TargetRoot = $null
                    Components = @()
                }
            }
        }
        # Той самий інваріант, що вже діє для OutOfPlace: обраний InPlace
        # target (він же live-джерело) не може перетинатись з BackupRoot,
        # RuntimeRoot чи staging — інакше move-aside/rollback знищив би
        # комплект резервних копій, runtime чи проміжні дані відновлення.
        foreach ($forbidden in @(
            @{ Name = 'BackupRoot'; Path = $BackupRoot },
            @{ Name = 'RuntimeRoot'; Path = $RuntimeRootPath },
            @{ Name = 'staging'; Path = $StagingRoot }
        )) {
            if ((Test-BRAVODataRestorePathEquals -First $selectedDirectory -Second $forbidden.Path) -or
                (Test-BRAVODataRestorePathWithin -Path $selectedDirectory -Directory $forbidden.Path) -or
                (Test-BRAVODataRestorePathWithin -Path $forbidden.Path -Directory $selectedDirectory)) {
                return [pscustomobject]@{
                    Success = $false
                    Error = "live-джерело компонента $($planComponent.Type) ($selectedDirectory) перетинається з захищеним розташуванням ($($forbidden.Name)): $($forbidden.Path)"
                    TargetRoot = $null
                    Components = @()
                }
            }
        }
    }
    return [pscustomobject]@{ Success = $true; Error = $null; TargetRoot = $null; Components = @($planComponents) }
}

function Get-BRAVOSevenZipArchiveInventory {
    # Інвентаризація архіву БЕЗ розпакування: кількість файлів/каталогів і
    # сумарний нестиснутий розмір (free-space preflight + post-verify еталон).
    #
    # 5.3.0 (закритий борг CHANGELOG 5.2.0-dev.1): тонкий адаптер над
    # КАНОНІЧНОЮ Get-BRAVOSevenZipArchiveEntries (BRAVO.Compatibility) —
    # остання власна копія 7z-listing з legacy BOM-даючим
    # StandardInput.WriteLine(пароль) прибрана; пароль тепер іде через
    # BOM-free Write-BRAVOProcessInputText усередині канонічної функції,
    # тож нові (BOM-free) архіви читаються й під UTF-8-консоллю. Контракт
    # повернення {Success; FileCount; DirectoryCount;
    # TotalUncompressedBytes; Description} НЕЗМІННИЙ — його точно звіряє
    # post-verify Test-BRAVODataRestoreExtractionResult.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Пароль передається 7-Zip через redirected stdin канонічною Get-BRAVOSevenZipArchiveEntries (не в аргументи процесу) — той самий патерн, що Invoke-BRAVOSevenZipIntegrityTest.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZipPath,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$TimeoutSeconds = 43200
    )

    try {
        $listing = Get-BRAVOSevenZipArchiveEntries `
            -SevenZipPath $SevenZipPath `
            -ArchivePath $ArchivePath `
            -Password $Password `
            -TimeoutSeconds $TimeoutSeconds
        if (-not $listing.Success) {
            return [pscustomobject]@{
                Success = $false
                FileCount = 0
                DirectoryCount = 0
                TotalUncompressedBytes = [long]0
                Description = [string]$listing.Error
            }
        }

        $fileCount = 0
        $directoryCount = 0
        $totalBytes = [long]0
        foreach ($entry in @($listing.Entries)) {
            if ([bool]$entry.IsDirectory) {
                $directoryCount++
            } else {
                $fileCount++
                $totalBytes += [long]$entry.Size
            }
        }
        return [pscustomobject]@{
            Success = $true
            FileCount = $fileCount
            DirectoryCount = $directoryCount
            TotalUncompressedBytes = $totalBytes
            Description = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            FileCount = 0
            DirectoryCount = 0
            TotalUncompressedBytes = [long]0
            Description = $_.Exception.Message
        }
    }
}

function Test-BRAVODataRestoreFreeSpace {
    # Free-space preflight ДО будь-якої зміни на диску: агрегує вимоги по
    # томах, вимагає, щоб ПІСЛЯ відновлення лишався поріг
    # maintenanceSettings.Limits.MinimumFreeSpaceGB, і write-probe-ом
    # перевіряє фактичну можливість запису. UNC-цілі перевіряються лише
    # write-probe-ом (розмір вільного місця share надійно не визначається).
    param(
        [Parameter(Mandatory = $true)][object[]]$Requirements,
        [Parameter(Mandatory = $true)][double]$MinimumFreeGigabytes
    )

    $problems = @()
    $notes = @()
    $volumeRequiredBytes = @{}
    foreach ($requirement in $Requirements) {
        $targetDirectory = [string]$requirement.TargetDirectory
        try {
            $volumeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($targetDirectory))
        } catch {
            $problems += "некоректний шлях цілі: $targetDirectory"
            continue
        }
        if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
            $problems += "не визначено том для цілі: $targetDirectory"
            continue
        }
        if (-not $volumeRequiredBytes.ContainsKey($volumeRoot)) {
            $volumeRequiredBytes[$volumeRoot] = [long]0
        }
        $volumeRequiredBytes[$volumeRoot] = [long]$volumeRequiredBytes[$volumeRoot] + [long]$requirement.RequiredBytes
    }
    foreach ($volumeRoot in @($volumeRequiredBytes.Keys)) {
        if ($volumeRoot.StartsWith('\\')) {
            $notes += "том $volumeRoot — мережевий: перевірка вільного місця пропущена, лишається write-probe"
            continue
        }
        try {
            $driveInfo = New-Object System.IO.DriveInfo($volumeRoot)
            $availableBytes = [long]$driveInfo.AvailableFreeSpace
        } catch {
            $problems += "не вдалося визначити вільне місце тому ${volumeRoot}: $($_.Exception.Message)"
            continue
        }
        $requiredBytes = [long]$volumeRequiredBytes[$volumeRoot]
        $floorBytes = [long]($MinimumFreeGigabytes * 1GB)
        if (($availableBytes - $requiredBytes) -lt $floorBytes) {
            $problems += ("недостатньо місця на {0}: доступно {1}, потрібно {2} + резерв {3}" -f `
                $volumeRoot,
                (Format-BRAVOFileSize -Bytes $availableBytes),
                (Format-BRAVOFileSize -Bytes $requiredBytes),
                (Format-BRAVOFileSize -Bytes $floorBytes))
        }
    }
    foreach ($requirement in $Requirements) {
        # Optional ProbeDirectory: для InPlace TargetDirectory ВЖЕ існує як
        # live production-каталог (MODEL/BLOG/BRAVOEXCH), тому пробний файл
        # там писати не можна — служби ще працюють, оператор ще не
        # підтвердив відновлення, і watcher-и на production-дереві можуть
        # побачити транзієнтний файл. Викликач для InPlace передає
        # ProbeDirectory = батьківський каталог live-джерела; за
        # замовчуванням (OutOfPlace/staging) поведінка не змінюється.
        $requirementProbeDirectory = [string]$requirement.ProbeDirectory
        $probeDirectory = if (-not [string]::IsNullOrWhiteSpace($requirementProbeDirectory)) {
            $requirementProbeDirectory
        } else {
            [string]$requirement.TargetDirectory
        }
        try {
            $probeDirectory = [System.IO.Path]::GetFullPath($probeDirectory)
        } catch {
            continue
        }
        while (-not [string]::IsNullOrWhiteSpace($probeDirectory) -and
            -not (Test-Path -LiteralPath $probeDirectory -PathType Container)) {
            $probeDirectory = Split-Path -Path $probeDirectory -Parent
        }
        if ([string]::IsNullOrWhiteSpace($probeDirectory)) {
            $problems += "не знайдено жодного наявного батьківського каталогу для цілі: $($requirement.TargetDirectory)"
            continue
        }
        $probeFile = Join-Path $probeDirectory ("BRAVO_DATA_RESTORE_PROBE_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        try {
            [IO.File]::WriteAllText($probeFile, 'probe')
        } catch {
            $problems += "write-probe не пройдено для ${probeDirectory}: $($_.Exception.Message)"
        } finally {
            # Гарантована спроба прибрати probe навіть якщо запис вище
            # провалився частково (файл міг бути створений і залишений
            # порожнім) — інакше скасоване відновлення лишає слід у
            # (потенційно production) probe-каталозі.
            if (Test-Path -LiteralPath $probeFile -PathType Leaf) {
                try {
                    Remove-Item -LiteralPath $probeFile -Force -ErrorAction Stop
                } catch {
                    $problems += "write-probe файл не прибрано (${probeFile}): $($_.Exception.Message)"
                }
            }
        }
    }
    return [pscustomobject]@{
        Success = ($problems.Count -eq 0)
        Problems = @($problems)
        Notes = @($notes)
    }
}

function Set-BRAVODataRestoreCreatedDirectoryAcl {
    # ACL для щойно СТВОРЕНОГО нами out-of-place каталогу: лише SYSTEM,
    # Administrators і поточний обліковий запис — видобуті дані LIMS не
    # мають бути читабельні іншим користувачам машини (той самий патерн, що
    # RestoreDrill у BRAVO_RESTORE_TEST.ps1). ACL наявних каталогів не
    # змінюємо — вони належать операторові.
    param([Parameter(Mandatory = $true)][string]$Path)

    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $none = [Security.AccessControl.PropagationFlags]::None
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
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

function Copy-BRAVODataRestoreDirectoryAcl {
    # InPlace: свіжостворений каталог має успадкувати фактичні права
    # знесеного вбік попередника, а не права батьківського каталогу —
    # інакше служба BRAVO може втратити доступ до власної моделі.
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $sourceAcl = Get-Acl -LiteralPath $SourceDirectory
    Set-Acl -LiteralPath $DestinationDirectory -AclObject $sourceAcl
}

function Get-BRAVODataRestoreServiceSnapshot {
    # Знімок стану трьох керованих служб ДО будь-яких дій. Дзеркало підходу
    # Maintenance ($serviceWasRunning + Get-ConfiguredServiceState): відсутня
    # або системно відключена (Disabled) служба не керується взагалі.
    # BravoWeb резолвиться за списком кандидатів (Name або DisplayName) —
    # документований fallback-шлях самого Maintenance.
    param([Parameter(Mandatory = $true)][hashtable]$ServicesSettings)

    $resolveServiceState = {
        param([string]$ServiceName)
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        $startMode = ""
        if ($service) {
            try {
                $escapedName = $ServiceName.Replace("'", "''")
                $serviceInfo = Get-BRAVOWmiInstance `
                    -ClassName Win32_Service `
                    -Filter "Name = '$escapedName'" |
                    Select-Object -First 1
            } catch {
                $serviceInfo = $null
            }
            $startMode = if ($serviceInfo) { [string]$serviceInfo.StartMode } else { [string]$service.StartType }
        }
        [pscustomobject]@{
            Exists = ($null -ne $service)
            Disabled = ($startMode -ieq 'Disabled')
            Running = ($null -ne $service -and [string]$service.Status -eq 'Running')
            Status = if ($null -ne $service) { [string]$service.Status } else { $null }
        }
    }

    $bravoName = [string]$ServicesSettings.BravoName
    $exchangeName = [string]$ServicesSettings.ExchangeApiName
    $bravoWebEnabled = $true
    if ($ServicesSettings -is [System.Collections.IDictionary] -and $ServicesSettings.Contains('BravoWebEnabled')) {
        $bravoWebEnabled = [System.Convert]::ToBoolean($ServicesSettings.BravoWebEnabled)
    }
    $bravoWebName = $null
    if ($bravoWebEnabled) {
        $installedServices = @(Get-Service -ErrorAction SilentlyContinue)
        foreach ($candidate in @($ServicesSettings.BravoWebCandidates | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })) {
            $match = $installedServices | Where-Object {
                $_.Name -ieq $candidate -or $_.DisplayName -ieq $candidate
            } | Select-Object -First 1
            if ($match) { $bravoWebName = $match.Name; break }
        }
    }

    $entries = @()
    # Порядок елементів = порядок ЗУПИНКИ (BravoWeb -> exchangAPI -> BRAVO);
    # запуск виконується у зворотному порядку.
    foreach ($definition in @(
        @{ Key = 'BravoWeb'; Name = $bravoWebName; ComponentEnabled = $bravoWebEnabled; KillProcesses = @() },
        @{ Key = 'ExchangeApi'; Name = $exchangeName; ComponentEnabled = $true; KillProcesses = @() },
        @{ Key = 'Bravo'; Name = $bravoName; ComponentEnabled = $true; KillProcesses = @('Bis') }
    )) {
        $stateExists = $false
        $stateDisabled = $false
        $stateRunning = $false
        $stateStatus = $null
        if ($definition.ComponentEnabled -and -not [string]::IsNullOrWhiteSpace([string]$definition.Name)) {
            $state = & $resolveServiceState ([string]$definition.Name)
            $stateExists = [bool]$state.Exists
            $stateDisabled = [bool]$state.Disabled
            $stateRunning = [bool]$state.Running
            $stateStatus = [string]$state.Status
        }
        # Restart-intent policy (сьомий review): WasRunning (точний Running на
        # момент знімка) лишається як є для діагностичного відображення, але
        # НЕ визначає, чи відновлювати службу після restore — інакше служба,
        # що на момент знімка лише розпочала запуск (StartPending), назавжди
        # лишилась би Stopped (quiescence коректно зупиняє її перед move-aside,
        # але старий гейт restart "-not WasRunning" пропускав запуск назад).
        # Консервативна, задокументована політика:
        #   Running / StartPending -> намір "працювати", відновлюємо Running;
        #   Stopped / StopPending / Paused / ContinuePending / PausePending /
        #   будь-що інше -> НЕ відновлюємо (найближчий безпечний за
        #   замовчуванням стан лишається Stopped, а не вгадування).
        # StartupType служби ця політика НІКОЛИ не змінює.
        $shouldRestartAfterRestore = ($stateStatus -eq 'Running' -or $stateStatus -eq 'StartPending')
        $entries += [pscustomobject]@{
            Key = [string]$definition.Key
            Name = [string]$definition.Name
            Managed = ($definition.ComponentEnabled -and $stateExists -and -not $stateDisabled)
            WasRunning = $stateRunning
            InitialStatus = $stateStatus
            ShouldRestartAfterRestore = $shouldRestartAfterRestore
            KillProcesses = @($definition.KillProcesses)
        }
    }
    return @($entries)
}

function Invoke-BRAVODataRestoreServiceStateChange {
    # Дзеркало Invoke-ServiceStateChange (Maintenance): команда + очікування
    # фактичного стану з таймаутом, без довіри до проміжних помилок cmdlet.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("Running", "Stopped")][string]$DesiredStatus,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [int]$PollIntervalSeconds = 2,
        [switch]$Force
    )

    $operationErrors = @()
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        $service.Refresh()
        if ([string]$service.Status -eq $DesiredStatus) {
            return [pscustomobject]@{ Success = $true; AlreadyInState = $true; FinalStatus = [string]$service.Status; Error = $null }
        }
        if ($DesiredStatus -eq "Running") {
            Start-Service -Name $Name -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -ErrorVariable operationErrors
        } else {
            Stop-Service -Name $Name -Force:$Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -ErrorVariable operationErrors
        }
        $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
        $pollSeconds = [math]::Max(1, $PollIntervalSeconds)
        do {
            $service = Get-Service -Name $Name -ErrorAction Stop
            $service.Refresh()
            if ([string]$service.Status -eq $DesiredStatus) {
                return [pscustomobject]@{ Success = $true; AlreadyInState = $false; FinalStatus = [string]$service.Status; Error = $null }
            }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds $pollSeconds
        } while ($true)
        $operationErrorText = @($operationErrors | ForEach-Object { $_.Exception.Message } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "; "
        $details = if ([string]::IsNullOrWhiteSpace($operationErrorText)) {
            "перевищено таймаут $TimeoutSeconds сек."
        } else {
            "$operationErrorText; після очікування $TimeoutSeconds сек. стан: $($service.Status)"
        }
        return [pscustomobject]@{ Success = $false; AlreadyInState = $false; FinalStatus = [string]$service.Status; Error = $details }
    } catch {
        return [pscustomobject]@{ Success = $false; AlreadyInState = $false; FinalStatus = "Unknown"; Error = $_.Exception.Message }
    }
}

function Stop-BRAVODataRestoreServices {
    # Зупинка ВСІХ керованих служб незалежно від компонента: BRAVO тримає
    # MODEL і пише BLOG, exchangAPI пише BRAVOEXCH, BravoWeb роздає похідні
    # моделі дані — уніфікований протокол надійніший за мінімізацію для
    # рідкісної disaster-операції. Повертає перелік відмов (порожній = успіх).
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][int]$StopTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollIntervalSeconds
    )

    $failures = @()
    foreach ($entry in $Snapshot) {
        if (-not $entry.Managed) { continue }
        # KillProcesses тепер перевіряються ЗАВЖДИ, незалежно від того, чи
        # Windows-служба вже Stopped: orphan/вручну запущений процес (напр.
        # Bis.exe) може тримати MODEL/файлові handle-и незалежно від служби
        # — "служба вже Stopped" нічого не каже про такий процес.
        foreach ($processName in @($entry.KillProcesses)) {
            $lingeringProcess = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($lingeringProcess) {
                Write-DataRestoreLog -Message "Завершення процесу $processName ($($entry.Name))..." -Level 'INFO'
                $lingeringProcess | Stop-Process -Force
                Start-Sleep -Seconds 1
            }
        }
        # Обов'язок ЗУПИНКИ служби переоцінюється за ПОТОЧНИМ станом (запит
        # ПІСЛЯ спроби завершення процесів — термінація процесу могла
        # змінити стан пов'язаної служби), а не за WasRunning знімка:
        # WasRunning визначає лише діагностичне відображення знімка, тоді як
        # службу, що на знімку була Stopped/StartPending, але встигла чи
        # встигає перейти у Running до цього виклику (гонитва зі знімком),
        # усе одно потрібно зупинити — інакше вона могла б читати/писати у
        # дерево під час move-aside/розпакування. Get-Service тут — новий
        # запит, не кеш зі знімка.
        #
        # Служба вже позначена Managed=true знімком (існувала й не Disabled
        # на момент знімка). Якщо ПОВТОРНИЙ запит зараз повертає null АБО
        # кидає виняток (транзієнтна помилка SCM) — це зміна стану/
        # невизначеність, а НЕ доказ безпеки: fail-closed як провал тиші,
        # не мовчазний "continue" (round-7 P1: попередня поведінка трактувала
        # непроверену службу як тиху).
        $currentService = $null
        try {
            $currentService = Get-Service -Name $entry.Name -ErrorAction Stop
        } catch {
            $currentService = $null
        }
        if ($null -eq $currentService) {
            $failures += "не вдалося опитати поточний стан керованої служби $($entry.Name) (Get-Service повернув null/кинув виняток) — тиша не підтверджена"
            Write-DataRestoreLog -Message "ПОМИЛКА: не вдалося опитати поточний стан керованої служби $($entry.Name)" -Level 'ERROR'
            continue
        }
        $currentService.Refresh()
        if ([string]$currentService.Status -eq 'Stopped') { continue }
        Write-DataRestoreLog -Message "Зупинка служби $($entry.Name)..." -Level 'INFO'
        $stopResult = Invoke-BRAVODataRestoreServiceStateChange `
            -Name $entry.Name `
            -DesiredStatus Stopped `
            -TimeoutSeconds $StopTimeoutSeconds `
            -PollIntervalSeconds $PollIntervalSeconds `
            -Force
        if ($stopResult.Success) {
            Write-DataRestoreLog -Message "Службу $($entry.Name) зупинено" -Level 'SUCCESS'
        } else {
            $failures += "не вдалося зупинити $($entry.Name): $($stopResult.Error)"
            Write-DataRestoreLog -Message "ПОМИЛКА: не вдалося зупинити $($entry.Name): $($stopResult.Error)" -Level 'ERROR'
        }
    }
    return @($failures)
}

function Test-BRAVODataRestoreServicesAllStopped {
    # Фінальний бар'єр БЕЗПОСЕРЕДНЬО перед деструктивною дією (move-aside):
    # Stop-BRAVODataRestoreServices вище вже зупинила й дочекалась Stopped
    # для кожної керованої служби та завершила configured KillProcesses,
    # але між її return і цим викликом лишається вузьке вікно, у якому
    # служба теоретично могла перейти назад у нестабільний стан, а процес —
    # перезапуститись. Це НЕ спроба зупинки — лише re-query ОБОХ умов тиші
    # безпосередньо перед мутацією filesystem: (1) кожна керована служба —
    # Stopped (будь-який інший стан: Running, StartPending, StopPending,
    # Paused тощо — привід перервати прогін); (2) жоден configured
    # KillProcesses-процес не активний (перевіряється незалежно від стану
    # пов'язаної служби — орфан-процес не зникає разом зі "Stopped").
    param([Parameter(Mandatory = $true)][object[]]$Snapshot)

    $unsafeEntries = @()
    foreach ($entry in $Snapshot) {
        if (-not $entry.Managed) { continue }
        # Той самий fail-closed контракт, що й Stop-BRAVODataRestoreServices:
        # null/виняток для раніше Managed служби — невизначеність, а не доказ
        # Stopped, тож бар'єр МУСИТЬ додати unsafe-запис, а не мовчки
        # пропустити перевірку.
        $currentService = $null
        try {
            $currentService = Get-Service -Name $entry.Name -ErrorAction Stop
        } catch {
            $currentService = $null
        }
        if ($null -eq $currentService) {
            $unsafeEntries += "$($entry.Name): не вдалося опитати поточний стан (Get-Service повернув null/кинув виняток) — тиша не підтверджена"
        } else {
            $currentService.Refresh()
            if ([string]$currentService.Status -ne 'Stopped') {
                $unsafeEntries += "$($entry.Name) (поточний стан: $($currentService.Status))"
            }
        }
        foreach ($processName in @($entry.KillProcesses)) {
            if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
                $unsafeEntries += "процес $processName (пов'язаний із $($entry.Name)) усе ще активний"
            }
        }
    }
    return @($unsafeEntries)
}

function Invoke-BRAVODataRestoreQuiescence {
    # Єдина точка примусової тиші: re-stop будь-якої керованої служби, що
    # наразі не Stopped, термінація configured KillProcesses (незалежно від
    # стану служби), і фінальна re-query перевірка ОБОХ умов
    # (Test-BRAVODataRestoreServicesAllStopped). Викликається ОДИН РАЗ
    # перед підтвердженням InPlace, і ПОВТОРНО безпосередньо перед КОЖНИМ
    # деструктивним component-переходом (move-aside) у циклі нижче: MODEL
    # extraction може тривати довго, і watchdog/оператор/інший контролер
    # може перезапустити службу чи запустити процес між компонентами —
    # інваріант "усе тихо" мусить бути re-встановлений, а не перевірений
    # лише один раз на початку транзакції.
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][int]$StopTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollIntervalSeconds
    )

    $stopFailures = @(Stop-BRAVODataRestoreServices `
        -Snapshot $Snapshot `
        -StopTimeoutSeconds $StopTimeoutSeconds `
        -PollIntervalSeconds $PollIntervalSeconds)
    $barrierFailures = @(Test-BRAVODataRestoreServicesAllStopped -Snapshot $Snapshot)
    return @($stopFailures + $barrierFailures)
}

function Restore-BRAVODataRestoreServices {
    # Відновлення НАМІРУ (не сліпий запуск і не буквальний Running-знімок):
    # стартують лише ті служби, чий початковий стан означав намір "працювати"
    # (Running АБО StartPending — див. ShouldRestartAfterRestore у
    # Get-BRAVODataRestoreServiceSnapshot), у зворотному до зупинки порядку.
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][int]$StartTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollIntervalSeconds
    )

    $failures = @()
    $reversed = @($Snapshot)
    [array]::Reverse($reversed)
    foreach ($entry in $reversed) {
        if (-not $entry.Managed -or -not $entry.ShouldRestartAfterRestore) { continue }
        Write-DataRestoreLog -Message "Запуск служби $($entry.Name)..." -Level 'INFO'
        $startResult = Invoke-BRAVODataRestoreServiceStateChange `
            -Name $entry.Name `
            -DesiredStatus Running `
            -TimeoutSeconds $StartTimeoutSeconds `
            -PollIntervalSeconds $PollIntervalSeconds
        if ($startResult.Success) {
            Write-DataRestoreLog -Message "Службу $($entry.Name) запущено" -Level 'SUCCESS'
        } else {
            $failures += "не вдалося запустити $($entry.Name): $($startResult.Error)"
            Write-DataRestoreLog -Message "ПОМИЛКА: не вдалося запустити $($entry.Name): $($startResult.Error)" -Level 'ERROR'
        }
    }
    return @($failures)
}

function Request-BRAVODataRestoreConfirmation {
    # Типізоване підтвердження деструктивного InPlace: оператор має НАБРАТИ
    # GenerationId (сильніше за Y/N — вимагає прочитати план). -Force — обхід
    # для дистанційних runbook-ів; неінтерактивна сесія без -Force
    # відмовляється fail-closed.
    param(
        [Parameter(Mandatory = $true)][string]$GenerationIdToConfirm,
        [switch]$ForceConfirmation
    )

    if ($ForceConfirmation) {
        Write-DataRestoreLog -Message "Підтвердження пропущено параметром -Force (GenerationId $GenerationIdToConfirm)" -Level 'WARNING'
        return $true
    }
    $interactive = $true
    try {
        if (-not [Environment]::UserInteractive) { $interactive = $false }
    } catch {
        $interactive = $false
    }
    if (-not $interactive) {
        Write-DataRestoreLog -Message 'Неінтерактивна сесія без -Force: InPlace-відновлення відхилено' -Level 'ERROR'
        return $false
    }
    Write-BRAVOResultNote -Text ''
    Write-BRAVOResultNote -Text 'УВАГА: поточні production-дані буде знесено вбік (.prerestore) і замінено даними з резервної копії.'
    $typedValue = $null
    try {
        $typedValue = Read-Host "Для підтвердження введіть GenerationId ($GenerationIdToConfirm)"
    } catch {
        Write-DataRestoreLog -Message "Підтвердження недоступне в цьому хості: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
    if ([string]$typedValue -cne $GenerationIdToConfirm) {
        Write-DataRestoreLog -Message 'Введений GenerationId не збігається — відновлення скасовано оператором' -Level 'WARNING'
        return $false
    }
    Write-DataRestoreLog -Message "Оператор підтвердив InPlace-відновлення generation $GenerationIdToConfirm" -Level 'INFO'
    return $true
}

function Get-BRAVODataRestoreLockingProcessText {
    # Хто тримає дерево, якщо move-aside не вдався. Windows каже лише "file
    # is being used by another process" — Restart Manager (rstrtmgr.dll)
    # називає винуватця. Суто діагностична best-effort функція: реєструє
    # сам каталог + обмежену вибірку файлів (перші 200), ніколи не кидає
    # виняток і нічого не зупиняє.
    param([Parameter(Mandatory = $true)][string]$Directory)

    try {
        if (-not ('BRAVODataRestoreLockInspector' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class BRAVODataRestoreLockInspector
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

    public static List<string> GetHolders(string[] paths)
    {
        List<string> holders = new List<string>();
        uint sessionHandle;
        if (RmStartSession(out sessionHandle, 0, Guid.NewGuid().ToString()) != 0)
        {
            return holders;
        }
        try
        {
            if (RmRegisterResources(sessionHandle, (uint)paths.Length, paths, 0, null, 0, null) != 0)
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
                string holder = infos[i].strAppName + " (PID " + infos[i].Process.dwProcessId + ")";
                if (!string.IsNullOrEmpty(infos[i].strServiceShortName))
                {
                    holder += " [служба " + infos[i].strServiceShortName + "]";
                }
                if (!holders.Contains(holder))
                {
                    holders.Add(holder);
                }
            }
            return holders;
        }
        finally
        {
            RmEndSession(sessionHandle);
        }
    }
}
'@
        }
        $samplePaths = New-Object 'System.Collections.Generic.List[string]'
        $samplePaths.Add($Directory)
        foreach ($sampleFile in @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -First 200)) {
            $samplePaths.Add($sampleFile.FullName)
        }
        $holders = [BRAVODataRestoreLockInspector]::GetHolders($samplePaths.ToArray())
        if ($holders.Count -eq 0) {
            return 'власника не визначено (Restart Manager не побачив відкритих handle у вибірці файлів)'
        }
        return ($holders -join '; ')
    } catch {
        return "діагностика власників недоступна: $($_.Exception.Message)"
    }
}

function Invoke-BRAVODataRestoreMoveAside {
    # Safety-збереження поточних даних: атомарний rename у межах того самого
    # батьківського каталогу (той самий том). Провал rename — це fail-closed
    # ДОКАЗ, що щось іще тримає дерево: нічого не знищено, лише діагностика.
    param(
        [Parameter(Mandatory = $true)][string]$LiveDirectory,
        [Parameter(Mandatory = $true)][string]$PrerestoreDirectory
    )

    if (-not (Test-Path -LiteralPath $LiveDirectory -PathType Container)) {
        Write-DataRestoreLog -Message "Live-каталог відсутній ($LiveDirectory) — prerestore-копія не створюється (джерело знищено?)" -Level 'WARNING'
        return [pscustomobject]@{ Success = $true; Performed = $false; Error = $null }
    }
    try {
        [System.IO.Directory]::Move($LiveDirectory, $PrerestoreDirectory)
        Write-DataRestoreLog -Message "Поточні дані знесено вбік: $LiveDirectory -> $PrerestoreDirectory" -Level 'SUCCESS'
        return [pscustomobject]@{ Success = $true; Performed = $true; Error = $null }
    } catch {
        $holdersText = Get-BRAVODataRestoreLockingProcessText -Directory $LiveDirectory
        $message = "move-aside не вдався для ${LiveDirectory}: $($_.Exception.Message); ймовірні власники: $holdersText"
        Write-DataRestoreLog -Message "ПОМИЛКА: $message" -Level 'ERROR'
        return [pscustomobject]@{ Success = $false; Performed = $false; Error = $message }
    }
}

function Undo-BRAVODataRestoreMoveAside {
    # Rollback невдалого InPlace-відновлення: прибрати частково розпакований
    # свіжий каталог і повернути prerestore-копію на original ім'я.
    #
    # round-7 P2 (два окремі findings, виправлені разом у цій функції):
    #
    # 1. Каталог за LiveDirectory видаляється ЛИШЕ якщо ЦЕЙ ПРОГІН сам його
    #    створив (TargetCreatedByThisRun). Якщо unmanaged-процес/watchdog
    #    відновив live-каталог ПІСЛЯ move-aside, але New-Item без -Force
    #    (виклик вище) провалився через це — TargetCreatedByThisRun=false,
    #    і видаляти/перезаписувати чужий каталог заборонено: це стан, що
    #    вимагає ручного втручання, а не "часткового результату" цього
    #    прогону.
    #
    # 2. Manual-recovery повідомлення при провалі самого rollback залежить
    #    від MoveAsidePerformed. Коли live-каталог був ВІДСУТНІЙ ще до
    #    move-aside (типовий disaster-сценарій, особливо для BRAVOEXCH),
    #    MoveAsidePerformed=false і жодної prerestore-копії НІКОЛИ не
    #    існувало — повідомлення про "дані збережені у PrerestoreDirectory"
    #    і команда Rename-Item на неіснуючий шлях були б хибними й могли б
    #    змусити оператора шукати дані, яких ніколи не було.
    param(
        [Parameter(Mandatory = $true)][string]$LiveDirectory,
        [Parameter(Mandatory = $true)][string]$PrerestoreDirectory,
        [Parameter(Mandatory = $true)][bool]$MoveAsidePerformed,
        [Parameter(Mandatory = $true)][bool]$TargetCreatedByThisRun
    )

    try {
        if (Test-Path -LiteralPath $LiveDirectory -PathType Container) {
            if (-not $TargetCreatedByThisRun) {
                throw "за адресою $LiveDirectory існує каталог, якого цей прогін НЕ створював (з'явився після move-aside) — автоматичне видалення чи перезапис заборонено"
            }
            Remove-Item -LiteralPath $LiveDirectory -Recurse -Force -ErrorAction Stop
        }
        if ($MoveAsidePerformed) {
            [System.IO.Directory]::Move($PrerestoreDirectory, $LiveDirectory)
        }
        Write-DataRestoreLog -Message "Rollback виконано: $LiveDirectory повернуто до стану перед відновленням" -Level 'SUCCESS'
        return [pscustomobject]@{ Success = $true; Error = $null }
    } catch {
        # Найгірший сценарій: rollback теж не вдався.
        if ($MoveAsidePerformed) {
            # Оригінальні дані РЕАЛЬНО збережені у PrerestoreDirectory —
            # можна безпечно вказати точну ручну команду повернення.
            $manualCommand = "Rename-Item -LiteralPath `"$PrerestoreDirectory`" -NewName `"$(Split-Path $LiveDirectory -Leaf)`""
            $message = "rollback не вдався: $($_.Exception.Message). Дані збережені у $PrerestoreDirectory. Ручне повернення: $manualCommand"
        } else {
            # Live-каталог був відсутній ще ДО цього прогону — move-aside
            # нічого не переносив, prerestore-копії не існує. НЕ стверджуємо
            # протилежне й НЕ пропонуємо команду на неіснуючий шлях.
            $message = "rollback не вдався: $($_.Exception.Message). Live-каталог $LiveDirectory був відсутній ще ДО цього прогону (move-aside нічого не переносив) — жодної prerestore-копії не існує; перевірте поточний частковий стан $LiveDirectory вручну."
        }
        Write-DataRestoreLog -Message "КРИТИЧНО: $message" -Level 'ERROR'
        return [pscustomobject]@{ Success = $false; Error = $message }
    }
}

function Undo-BRAVODataRestoreCompletedComponents {
    # Крос-компонентний rollback InPlace: якщо компонент N не відновився,
    # ВЖЕ відновлені компоненти цього ж прогону теж повертаються до стану
    # перед відновленням. Інакше production лишився б у змішаному стані —
    # MODEL з нової generation, BLOG зі старими даними, — а узгодженість
    # MODEL/BLOG/BRAVOEXCH між собою є передумовою працездатності LIMS.
    #
    # Порядок ЗВОРОТНИЙ до відновлення: останній відновлений відкочується
    # першим (дзеркало порядку зупинки/запуску служб).
    #
    # Відмова відкату одного компонента НЕ зупиняє відкат решти: кожен
    # компонент незалежний, і зупинка на першій помилці лишила б без
    # спроби ті, які ще можна врятувати. Усі відмови повертаються
    # викликачеві разом.
    #
    # Failures — структуровані записи (Type + Error), а не лише текст:
    # викликач мусить знати, ЯКОМУ саме компонентові виставити термінальний
    # статус ROLLBACK_FAILED, а не тільки що написати в журнал.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$CompletedComponents
    )

    $rolledBack = @()
    $failures = @()
    $reversed = @($CompletedComponents)
    [array]::Reverse($reversed)
    foreach ($completed in $reversed) {
        $componentType = [string]$completed.Type
        Write-DataRestoreLog -Message "Відкат раніше відновленого компонента $componentType (збій іншого компонента цього прогону)..." -Level 'WARNING'
        # TargetCreatedByThisRun завжди true тут: компонент потрапив у
        # $completedInPlaceComponents лише ПІСЛЯ успішного extraction/
        # verification у власну ціль цього прогону — за конструкцією її
        # створив саме цей прогін.
        $undoResult = Undo-BRAVODataRestoreMoveAside `
            -LiveDirectory ([string]$completed.LiveDirectory) `
            -PrerestoreDirectory ([string]$completed.PrerestoreDirectory) `
            -MoveAsidePerformed ([bool]$completed.MoveAsidePerformed) `
            -TargetCreatedByThisRun $true
        if ($undoResult.Success) {
            $rolledBack += $componentType
        } else {
            $failures += [pscustomobject]@{
                Type = $componentType
                Error = [string]$undoResult.Error
            }
        }
    }
    return [pscustomobject]@{
        RolledBack = @($rolledBack)
        Failures = @($failures)
    }
}

function Get-BRAVODataRestoreRollbackStatusUpdates {
    # Переклад результату крос-відкату в термінальні статуси компонентів.
    # Винесено окремо від головного потоку, бо саме тут вирішується, що
    # оператор побачить у підсумку: компонент, відкат якого НЕ завершився,
    # не має лишатися RESTORED. Функція чиста (нічого не пише) — її можна
    # перевіряти тестом разом із фактичним станом файлової системи.
    param(
        [Parameter(Mandatory = $true)][object]$CrossRollbackResult,
        [Parameter(Mandatory = $true)][string]$FailedComponent
    )

    $updates = @()
    foreach ($rolledBackComponent in @($CrossRollbackResult.RolledBack)) {
        $updates += [pscustomobject]@{
            Component = [string]$rolledBackComponent
            Status = 'ROLLED_BACK'
            Detail = "відкочено до стану перед відновленням (збій компонента $FailedComponent)"
        }
    }
    foreach ($rollbackFailure in @($CrossRollbackResult.Failures)) {
        $updates += [pscustomobject]@{
            Component = [string]$rollbackFailure.Type
            Status = 'ROLLBACK_FAILED'
            Detail = ("відкат не завершено (збій компонента {0}): {1}" -f $FailedComponent, $rollbackFailure.Error)
        }
    }
    return @($updates)
}

function Format-BRAVODataRestoreRollbackFailureText {
    # Єдине місце форматування відмов відкату в текст (журнал, підсумкова
    # причина, сповіщення) — щоб оператор бачив однакове формулювання
    # скрізь, а не три різні варіанти того самого факту.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Failures
    )

    return @($Failures | ForEach-Object { "$($_.Type): $($_.Error)" })
}

function Test-BRAVODataRestoreExtractionResult {
    # Post-restore verification: фактична кількість файлів і сумарний розмір
    # у цілі мають ТОЧНО збігтися з інвентаризацією архіву (7za l -slt).
    # Каталоги — лише довідково: 7z відтворює їх і як entries, і як батьків
    # файлів, тому їхня кількість не є стабільним еталоном.
    param(
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][object]$Inventory
    )

    $extractedFiles = @(Get-ChildItem -LiteralPath $TargetDirectory -Recurse -File -Force -ErrorAction SilentlyContinue)
    $extractedByteSum = [long]0
    foreach ($extractedFile in $extractedFiles) {
        $extractedByteSum += [long]$extractedFile.Length
    }
    $problems = @()
    if ($extractedFiles.Count -ne [int]$Inventory.FileCount) {
        $problems += "кількість файлів не збігається: розпаковано $($extractedFiles.Count), в архіві $($Inventory.FileCount)"
    }
    if ($extractedByteSum -ne [long]$Inventory.TotalUncompressedBytes) {
        $problems += ("сумарний розмір не збігається: розпаковано {0}, в архіві {1}" -f `
            (Format-BRAVOFileSize -Bytes $extractedByteSum),
            (Format-BRAVOFileSize -Bytes ([long]$Inventory.TotalUncompressedBytes)))
    }
    if ($extractedFiles.Count -eq 0 -and [int]$Inventory.FileCount -gt 0) {
        $problems += 'ціль порожня після розпакування'
    }
    return [pscustomobject]@{
        Success = ($problems.Count -eq 0)
        FileCount = $extractedFiles.Count
        ByteCount = $extractedByteSum
        Problems = @($problems)
    }
}

function Add-BRAVODataRestoreComponentResult {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentType,
        # RESTORED       — компонент реально лишився відновленим;
        # ROLLED_BACK    — попередній стан успішно повернуто;
        # ROLLBACK_FAILED— відкат розпочато й НЕ завершено: кінцевий стан
        #                  каталогу не можна вважати гарантовано відновленим,
        #                  потрібне ручне втручання (OPERATIONS.md, код 43);
        # FAILED         — відновлення компонента не вдалося;
        # NOT_RUN        — черга до компонента не дійшла.
        [Parameter(Mandatory = $true)][ValidateSet('RESTORED', 'ROLLED_BACK', 'ROLLBACK_FAILED', 'FAILED', 'NOT_RUN')][string]$Status,
        [string]$TargetDirectory,
        [string]$PrerestoreDirectory,
        [int]$FileCount = 0,
        [long]$ByteCount = 0,
        [Nullable[double]]$DurationSeconds,
        [string]$Detail
    )

    [void]$script:dataRestoreComponentResults.Add([pscustomobject]@{
        Component = $ComponentType
        Status = $Status
        TargetDirectory = $TargetDirectory
        PrerestoreDirectory = $PrerestoreDirectory
        FileCount = $FileCount
        ByteCount = $ByteCount
        DurationSeconds = $DurationSeconds
        Detail = $Detail
    })
}

# ===== SFTP-ДЖЕРЕЛО =====

function Get-BRAVODataRestoreTemporaryRoot {
    # ASCII-безпечний каталог для командних/XML-файлів WinSCP (той самий
    # принцип, що Get-BRAVOHealthTemporaryRoot: командний файл WinSCP може
    # використовувати ASCII-кодування, тому службові шляхи сеансу тримаємо
    # в гарантовано ASCII-каталозі).
    if (-not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreTemporaryRoot) -and
        (Test-Path -LiteralPath $script:dataRestoreTemporaryRoot -PathType Container)) {
        return $script:dataRestoreTemporaryRoot
    }
    $candidateRoots = @((Join-Path $bravoScriptDirectory 'TEMP'))
    $commonApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($commonApplicationData)) {
        $candidateRoots += Join-Path $commonApplicationData 'BRAVO\TEMP'
    }
    $systemTemporaryRoot = [System.IO.Path]::GetTempPath()
    if (Test-BRAVODataRestoreAsciiPath -Path $systemTemporaryRoot) {
        $candidateRoots += Join-Path $systemTemporaryRoot 'BRAVO'
    }
    foreach ($candidateRoot in @($candidateRoots | Select-Object -Unique)) {
        if (-not (Test-BRAVODataRestoreAsciiPath -Path $candidateRoot)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $candidateRoot -Force -ErrorAction Stop)
            }
            $script:dataRestoreTemporaryRoot = $candidateRoot
            return $candidateRoot
        } catch {
            continue
        }
    }
    throw 'не знайдено ASCII-безпечного тимчасового каталогу для WinSCP-сеансу'
}

function Initialize-BRAVODataRestoreSftpCredentials {
    # Той самий шлях, що Health: Credential Manager -> Resolve-BRAVOSftpHostName
    # -> New-BRAVOSftpUrl. Секрети не потрапляють ні в аргументи, ні в журнал.
    $sftpLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
    $sftpPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
    if ([string]::IsNullOrWhiteSpace($sftpLoginTarget)) { $sftpLoginTarget = 'BRAVO_SFTP_LOGIN' }
    if ([string]::IsNullOrWhiteSpace($sftpPasswordTarget)) { $sftpPasswordTarget = 'BRAVO_SFTP_PASSWORD' }
    $storedSftpLogin = Get-BRAVOCredentialSecret -Target $sftpLoginTarget
    $storedSftpPassword = Get-BRAVOCredentialSecret -Target $sftpPasswordTarget
    if ([string]::IsNullOrWhiteSpace($storedSftpLogin)) {
        throw "запис Credential Manager '$sftpLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    if ([string]::IsNullOrWhiteSpace($storedSftpPassword)) {
        throw "запис Credential Manager '$sftpPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    $sftpLogin = ([string]$storedSftpLogin).Trim()
    $legacySftpHostVariable = Get-Variable -Name 'sftpHost' -Scope Global -ErrorAction SilentlyContinue
    $configuredSftpHost = if ($null -ne $legacySftpHostVariable) { [string]$legacySftpHostVariable.Value } else { $null }
    $resolvedSftpHost = Resolve-BRAVOSftpHostName `
        -UserName $sftpLogin `
        -HostTemplate ([string]$sftpHostTemplate) `
        -FallbackHostName $configuredSftpHost
    $script:dataRestoreSftpUrl = New-BRAVOSftpUrl `
        -HostName $resolvedSftpHost `
        -Port ([int]$sftpPort) `
        -UserName $sftpLogin `
        -Password ([string]$storedSftpPassword)
    $storedSftpLogin = $null
    $storedSftpPassword = $null
}

function Invoke-BRAVODataRestoreWinSCPScript {
    # Параметризоване дзеркало Invoke-WinSCPHealthSession: тимчасовий
    # командний файл + /xmllog, таймаут із kill, розбір XML. Вивід
    # санітизується у джерелі (Get-SanitizedWinSCPDiagnostic).
    param(
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    # Командний файл містить SFTP URL з обліковими даними (open ...) —
    # створюється через canonical New-BRAVOWinSCPTemporaryScriptPath
    # (BRAVO.ArchiveRuntime, той самий helper, що Archive), яка одразу
    # накладає protected DACL (лише поточний обліковий запис/SYSTEM/
    # Administrators) у момент створення файлу — без вікна, коли файл
    # існує з успадкованими правами каталогу (Get-BRAVODataRestoreTemporaryRoot
    # може fallback-нути у %TEMP%\BRAVO, для запланованого завдання це
    # C:\Windows\Temp, доступний значно ширшому колу). XML-журнал секретів
    # не містить — лишається у звичайному ASCII-безпечному temp-каталозі.
    $temporaryName = "BRAVO_DATA_RESTORE_$([guid]::NewGuid().ToString('N'))"
    $temporaryRoot = Get-BRAVODataRestoreTemporaryRoot
    $temporaryXmlPath = Join-Path $temporaryRoot "$temporaryName.xml"
    $temporaryScriptPath = $null
    $process = $null
    $outputCapture = $null
    try {
        $temporaryScriptPath = New-BRAVOWinSCPTemporaryScriptPath
        $scriptLines = @(
            "option batch continue",
            "option confirm off",
            "open $script:dataRestoreSftpUrl -hostkey=$sftpHostKey -timeout=$sftpConnectionTimeoutSeconds"
        )
        $scriptLines += @($Commands)
        $scriptLines += "exit"
        $scriptEncoding = [System.Text.Encoding]::GetEncoding($winSCPScriptEncoding)
        [System.IO.File]::WriteAllLines($temporaryScriptPath, $scriptLines, $scriptEncoding)

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $winSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /xmllog=`"$temporaryXmlPath`" /xmlgroups /script=`"$temporaryScriptPath`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $winSCPPath
        if (-not $winSCPAvailability.Available) {
            throw (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "SFTP-відновлення")
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $completed = $process.WaitForExit([math]::Max(1, $TimeoutSeconds) * 1000)
        if (-not $completed) {
            try { $process.Kill(); [void]$process.WaitForExit(5000) } catch {
                # Kill процесу, що вже завершився сам, кидає InvalidOperation —
                # результат той самий (процес мертвий), логувати нічого.
            }
            if ($null -ne $outputCapture) {
                [void](Complete-BRAVOProcessOutputCapture -Capture $outputCapture)
                $outputCapture = $null
            }
            throw "перевищено таймаут SFTP-операції ($TimeoutSeconds сек.)"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $outputCapture = $null
        if (-not (Test-Path -LiteralPath $temporaryXmlPath -PathType Leaf)) {
            throw "WinSCP не створив XML-журнал (код: $($process.ExitCode))"
        }
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($temporaryXmlPath)
        if ($process.ExitCode -ne 0) {
            Write-DataRestoreLog -Message "WinSCP завершився з кодом $($process.ExitCode); аналізуємо доступні XML-результати" -Level 'WARNING'
        }
        return [pscustomobject]@{
            Success = $true
            ExitCode = $process.ExitCode
            Xml = $xml
            Output = Get-SanitizedWinSCPDiagnostic -Text ([string]$capturedOutput.StandardOutput)
            ErrorOutput = Get-SanitizedWinSCPDiagnostic -Text ([string]$capturedOutput.StandardError)
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            ExitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { $null }
            Xml = $null
            Output = ""
            ErrorOutput = ""
            Error = $_.Exception.Message
        }
    } finally {
        if ($null -ne $outputCapture) {
            try { [void](Complete-BRAVOProcessOutputCapture -Capture $outputCapture) } catch {
                # Cleanup-гілка після помилки: збій закриття capture не має
                # маскувати первинний exception, який зараз летить нагору.
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($temporaryScriptPath)) {
            try {
                Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $temporaryScriptPath
            } catch {
                Write-DataRestoreLog -Message "Не вдалося прибрати тимчасовий WinSCP-скрипт з обліковими даними ($temporaryScriptPath): $($_.Exception.Message). Видаліть файл вручну." -Level 'WARNING'
            }
        }
        foreach ($temporaryPath in @($temporaryXmlPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
        if ($process) { $process.Dispose() }
    }
}

function New-BRAVODataRestoreWinSCPNamespaceManager {
    param([System.Xml.XmlDocument]$Xml)

    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $namespaceManager.AddNamespace("w", "http://winscp.net/schema/session/1.0")
    return ,$namespaceManager
}

function Get-BRAVODataRestoreWinSCPListingNames {
    # Імена файлів з усіх ls-результатів XML-журналу WinSCP.
    param([System.Xml.XmlDocument]$Xml)

    $names = @()
    if ($null -eq $Xml) { return @() }
    $namespaceManager = New-BRAVODataRestoreWinSCPNamespaceManager -Xml $Xml
    foreach ($listingNode in @($Xml.SelectNodes("//w:ls", $namespaceManager))) {
        foreach ($fileNode in @($listingNode.SelectNodes("w:files/w:file", $namespaceManager))) {
            $nameNode = $fileNode.SelectSingleNode("w:filename", $namespaceManager)
            if ($nameNode) { $names += [string]$nameNode.GetAttribute("value") }
        }
    }
    return @($names)
}

function Test-BRAVODataRestoreWinSCPListingSucceeded {
    # Invoke-BRAVODataRestoreWinSCPScript навмисно повертає Success=true,
    # якщо XML-журнал існує, НАВІТЬ коли сам WinSCP.com завершився з
    # ненульовим кодом (per-operation результати живуть у самому журналі —
    # той самий контракт, що вже перевіряється для download через
    # Get-BRAVODataRestoreWinSCPDownloads). Для ls-лістингу без цієї
    # перевірки перерваний/частковий перелік manifest-ів міг би мовчазно
    # приховати найновіші файли — автоматичний вибір довірився б неповному
    # списку і обрав би старішу generation. Fail-closed: відсутність
    # жодного <ls>-результату або хоча б один result success!=true —
    # трактується як невдала операція лістингу.
    param([System.Xml.XmlDocument]$Xml)

    if ($null -eq $Xml) { return $false }
    $namespaceManager = New-BRAVODataRestoreWinSCPNamespaceManager -Xml $Xml
    $listingNodes = @($Xml.SelectNodes("//w:ls", $namespaceManager))
    if ($listingNodes.Count -eq 0) { return $false }
    foreach ($listingNode in $listingNodes) {
        $resultNode = $listingNode.SelectSingleNode("w:result", $namespaceManager)
        if ($null -eq $resultNode -or $resultNode.GetAttribute("success") -ne "true") {
            return $false
        }
    }
    return $true
}

function Get-BRAVODataRestoreWinSCPDownloads {
    param([System.Xml.XmlDocument]$Xml)

    $downloads = @()
    if ($null -eq $Xml) { return @() }
    $namespaceManager = New-BRAVODataRestoreWinSCPNamespaceManager -Xml $Xml
    foreach ($downloadNode in @($Xml.SelectNodes("//w:download", $namespaceManager))) {
        $fileNode = $downloadNode.SelectSingleNode("w:filename", $namespaceManager)
        $resultNode = $downloadNode.SelectSingleNode("w:result", $namespaceManager)
        $messages = if ($resultNode) {
            @($resultNode.SelectNodes("w:message", $namespaceManager) |
                ForEach-Object { ([string]$_.InnerText).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } else {
            @()
        }
        $downloads += [pscustomobject]@{
            RemotePath = if ($fileNode) { [string]$fileNode.GetAttribute("value") } else { "" }
            Success = ($resultNode -and $resultNode.GetAttribute("success") -eq "true")
            Error = ($messages -join "; ")
        }
    }
    return @($downloads)
}

function Get-BRAVODataRestoreSftpDirectoryForComponent {
    param([Parameter(Mandatory = $true)][string]$ComponentType)

    switch ($ComponentType) {
        'MODEL' { return [string]$sftpDirectories.MODEL }
        'BLOG' { return [string]$sftpDirectories.Blog }
        'BRAVOEXCH' { return [string]$sftpDirectories.BravoExch }
    }
    throw "невідомий компонент для SFTP: $ComponentType"
}

function Get-BRAVODataRestoreSftpOperationTimeoutSeconds {
    $operationTimeout = 1800
    try {
        if ($null -ne $backupMonitoring -and $null -ne $backupMonitoring.SFTP -and
            [int]$backupMonitoring.SFTP.OperationTimeoutSeconds -gt 0) {
            $operationTimeout = [int]$backupMonitoring.SFTP.OperationTimeoutSeconds
        }
    } catch {
        # Некоректне значення в конфігурації — тихий fallback на дефолт:
        # той самий контракт читання SFTP-таймаутів, що в Health/Archive.
    }
    return $operationTimeout
}

function Get-BRAVODataRestoreSftpTransferTimeoutSeconds {
    # Повне завантаження великих архівів — окремий, суттєво більший таймаут
    # (той самий поділ, що OperationTimeoutSeconds/SynchronizationTimeoutSeconds
    # у Health/Archive).
    $transferTimeout = 14400
    try {
        if ($null -ne $backupMonitoring -and $null -ne $backupMonitoring.SFTP -and
            [int]$backupMonitoring.SFTP.SynchronizationTimeoutSeconds -gt 0) {
            $transferTimeout = [int]$backupMonitoring.SFTP.SynchronizationTimeoutSeconds
        }
    } catch {
        # Некоректне значення в конфігурації — тихий fallback на дефолт:
        # той самий контракт читання SFTP-таймаутів, що в Health/Archive.
    }
    return $transferTimeout
}

function Invoke-BRAVODataRestoreSftpManifestFetch {
    # Вибір і завантаження generation manifest-а з SFTP у staging. Manifest
    # НІКОЛИ не потрапляє в <BackupRoot>\MANIFESTS — локальні listing/retention
    # не повинні бачити чужу generation як свою.
    param(
        [Parameter(Mandatory = $true)][string]$StagingManifestDirectory,
        [string]$RequestedGenerationId
    )

    if (-not (Test-Path -LiteralPath $StagingManifestDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $StagingManifestDirectory -Force -ErrorAction Stop)
    }
    $remoteManifestDirectory = [string]$sftpDirectories.Manifest
    if ([string]::IsNullOrWhiteSpace($remoteManifestDirectory)) {
        throw 'sftpDirectories.Manifest не задано в конфігурації'
    }
    $operationTimeout = Get-BRAVODataRestoreSftpOperationTimeoutSeconds

    $isExplicitRequest = -not [string]::IsNullOrWhiteSpace($RequestedGenerationId)
    $candidateBatches = @()
    if ($isExplicitRequest) {
        $candidateBatches = @(, @("BRAVO_BACKUP_{0}.json" -f $RequestedGenerationId))
    } else {
        $listingSession = Invoke-BRAVODataRestoreWinSCPScript `
            -Commands @("ls `"$remoteManifestDirectory`"") `
            -TimeoutSeconds $operationTimeout
        if (-not $listingSession.Success) {
            throw "не вдалося отримати перелік manifest-ів з SFTP: $($listingSession.Error)"
        }
        # Invoke-BRAVODataRestoreWinSCPScript Success=true не гарантує, що
        # сама ls-операція завершилась успішно (той самий контракт, що вже
        # перевіряється для download): перерваний/частковий лістинг міг би
        # мовчазно приховати найновіші manifest-и і призвести до вибору
        # старішої generation.
        if (-not (Test-BRAVODataRestoreWinSCPListingSucceeded -Xml $listingSession.Xml)) {
            throw 'перелік manifest-ів з SFTP не підтверджено (ls-операція не позначена як успішна в XML-журналі WinSCP)'
        }
        $allManifestNames = @(Sort-BRAVODataRestoreManifestNamesByGenerationDescending -ManifestNames @(
            Get-BRAVODataRestoreWinSCPListingNames -Xml $listingSession.Xml |
                Where-Object { $_ -match '^BRAVO_BACKUP_\d{8}_\d{6}(?:_\d+)?\.json$' }))
        if ($allManifestNames.Count -eq 0) {
            throw "на SFTP ($remoteManifestDirectory) не знайдено жодного generation manifest"
        }
        # Батчами по 10 (замість жорсткого Select-Object -First 10) — корисне
        # для мережевої ефективності, але БЕЗ обмеження коректності: якщо
        # серед перших 10 немає жодного COMPLETE, пошук продовжується на
        # наступних батчах, доки не переглянуто всі кандидати або не
        # знайдено найновіший COMPLETE.
        $manifestBatchSize = 10
        for ($batchStart = 0; $batchStart -lt $allManifestNames.Count; $batchStart += $manifestBatchSize) {
            $batchEnd = [math]::Min($batchStart + $manifestBatchSize, $allManifestNames.Count) - 1
            $candidateBatches += , @($allManifestNames[$batchStart..$batchEnd])
        }
    }

    $selected = $null
    foreach ($manifestNameBatch in $candidateBatches) {
        $getCommands = @()
        foreach ($manifestName in $manifestNameBatch) {
            $localManifestPath = Join-Path $StagingManifestDirectory $manifestName
            if (Test-Path -LiteralPath $localManifestPath) {
                Remove-Item -LiteralPath $localManifestPath -Force -ErrorAction SilentlyContinue
            }
            $getCommands += "get `"$remoteManifestDirectory/$manifestName`" `"$localManifestPath`""
        }
        $downloadSession = Invoke-BRAVODataRestoreWinSCPScript `
            -Commands $getCommands `
            -TimeoutSeconds $operationTimeout
        if (-not $downloadSession.Success) {
            throw "не вдалося завантажити manifest-и з SFTP: $($downloadSession.Error)"
        }

        # Invoke-BRAVODataRestoreWinSCPScript навмисно повертає Success=true,
        # якщо WinSCP.com завершився з ненульовим кодом, але XML-журнал
        # усе одно існує (per-operation результати в самому журналі) — тому
        # тут ОБОВ'ЯЗКОВО перевіряється кожен per-download результат.
        # Без цього transient збій завантаження НАЙНОВІШОГО manifest-а в
        # батчі міг би мовчазно "провалитись" до старішого COMPLETE:
        # restore тихо понизився б до застарілої generation через мережеву
        # помилку, а не явну відмову.
        $downloadResults = @(Get-BRAVODataRestoreWinSCPDownloads -Xml $downloadSession.Xml)
        foreach ($manifestName in $manifestNameBatch) {
            $matchingDownload = @($downloadResults | Where-Object {
                ([string]$_.RemotePath) -like "*$manifestName"
            } | Select-Object -First 1)
            if ($matchingDownload.Count -eq 0 -or -not [bool]$matchingDownload[0].Success) {
                $downloadFailureDetail = if ($matchingDownload.Count -gt 0) { [string]$matchingDownload[0].Error } else { 'відсутній результат завантаження в XML-журналі' }
                throw "завантаження manifest-а '$manifestName' з SFTP не підтверджено: $downloadFailureDetail"
            }
        }

        # Найновіший COMPLETE серед завантажених у цьому батчі (або точно запитаний).
        $candidates = @()
        foreach ($manifestName in $manifestNameBatch) {
            $localManifestPath = Join-Path $StagingManifestDirectory $manifestName
            if (-not (Test-Path -LiteralPath $localManifestPath -PathType Leaf)) { continue }
            try {
                $manifest = [IO.File]::ReadAllText($localManifestPath) | ConvertFrom-Json -ErrorAction Stop
            } catch {
                # Той самий принцип, що в canonical селекторі: fail-closed
                # пропуск нечитабельного manifest-а правильний, але мовчазним
                # бути не може — інакше авто-вибір тихо падає на старішу
                # generation без сліду в лозі.
                Write-DataRestoreLog -Message "УВАГА: завантажений SFTP-manifest пропущено (не прочитано): $localManifestPath — $($_.Exception.Message)" -Level 'WARNING' -Console
                continue
            }
            if ([string]$manifest.status -ne 'COMPLETE') { continue }
            # Identity invariant (той самий контракт, що canonical
            # Get-BRAVORestoreGenerationManifest для Local): ім'я файлу і
            # generationId усередині JSON мають ТОЧНО збігатись — інакше
            # пошкоджений/підмінений SFTP-manifest міг би змусити відновити
            # generation, вказану лише в JSON.
            $filenameGenerationId = [IO.Path]::GetFileNameWithoutExtension($manifestName) -replace '^BRAVO_BACKUP_', ''
            $jsonGenerationId = [string]$manifest.generationId
            if ([string]::IsNullOrWhiteSpace($jsonGenerationId) -or
                $jsonGenerationId -notmatch '^\d{8}_\d{6}(?:_\d+)?$' -or
                -not [string]::Equals($filenameGenerationId, $jsonGenerationId, [StringComparison]::Ordinal)) {
                if ($isExplicitRequest) {
                    throw "manifest '$manifestName' не пройшов перевірку ідентичності: ім'я файлу вказує generation '$filenameGenerationId', а вміст JSON — '$jsonGenerationId'"
                }
                Write-DataRestoreLog -Message "УВАГА: завантажений SFTP-manifest пропущено (identity mismatch): $localManifestPath — ім'я файлу вказує generation '$filenameGenerationId', а вміст JSON — '$jsonGenerationId'" -Level 'WARNING' -Console
                continue
            }
            $candidates += [pscustomobject]@{
                Manifest = $manifest
                ManifestPath = $localManifestPath
                Name = $manifestName
            }
        }
        $selected = $null
        foreach ($orderedCandidateName in @(Sort-BRAVODataRestoreManifestNamesByGenerationDescending -ManifestNames @($candidates | Select-Object -ExpandProperty Name))) {
            $selected = @($candidates | Where-Object { $_.Name -eq $orderedCandidateName }) | Select-Object -First 1
            if ($null -ne $selected) { break }
        }
        if ($null -ne $selected) { break }
    }
    if ($null -eq $selected) {
        if ($isExplicitRequest) {
            throw "COMPLETE generation '$RequestedGenerationId' не знайдено на SFTP"
        }
        throw 'серед завантажених manifest-ів немає жодного COMPLETE'
    }
    return $selected
}

function Invoke-BRAVODataRestoreSftpArchiveFetch {
    # Завантаження .mdz + .sha512 обраних компонентів у staging з
    # resumesupport. Імена файлів беруться ЛИШЕ як basename із manifest
    # (шляхи origin-сервера недовірені відносно нашої файлової системи).
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string[]]$ComponentTypes,
        [Parameter(Mandatory = $true)][string]$StagingGenerationRoot
    )

    $componentsProperty = $Manifest.PSObject.Properties['components']
    $stagedPaths = @{}
    $transferTimeout = Get-BRAVODataRestoreSftpTransferTimeoutSeconds
    foreach ($componentType in $ComponentTypes) {
        $componentProperty = @($componentsProperty.Value.PSObject.Properties | Where-Object {
            [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($componentProperty.Count -eq 0) {
            throw "manifest не містить component $componentType"
        }
        $componentState = $componentProperty[0].Value
        $archiveFileName = [System.IO.Path]::GetFileName([string]$componentState.ArchivePath)
        if ([string]::IsNullOrWhiteSpace($archiveFileName) -or
            $archiveFileName -notmatch '^[^\\/:*?"<>|]+\.mdz$') {
            throw "manifest містить підозріле ім'я архіву для ${componentType}: '$archiveFileName'"
        }
        $remoteDirectory = Get-BRAVODataRestoreSftpDirectoryForComponent -ComponentType $componentType
        $componentStagingDirectory = Join-Path $StagingGenerationRoot $componentType
        if (-not (Test-Path -LiteralPath $componentStagingDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $componentStagingDirectory -Force -ErrorAction Stop)
        }
        # Стейлові часткові завантаження попередніх спроб.
        foreach ($stalePartial in @(Get-ChildItem -LiteralPath $componentStagingDirectory -Filter '*.filepart' -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $stalePartial.FullName -Force -ErrorAction SilentlyContinue
        }
        $localArchivePath = Join-Path $componentStagingDirectory $archiveFileName
        $localHashPath = "$localArchivePath$hashFileExtension"
        $downloadSession = Invoke-BRAVODataRestoreWinSCPScript `
            -Commands @(
                "get -resumesupport=on `"$remoteDirectory/$archiveFileName`" `"$localArchivePath`"",
                "get `"$remoteDirectory/$archiveFileName$hashFileExtension`" `"$localHashPath`""
            ) `
            -TimeoutSeconds $transferTimeout
        if (-not $downloadSession.Success) {
            throw "не вдалося завантажити $componentType з SFTP: $($downloadSession.Error)"
        }
        $downloadFailures = @(Get-BRAVODataRestoreWinSCPDownloads -Xml $downloadSession.Xml |
            Where-Object { -not $_.Success })
        if ($downloadFailures.Count -gt 0) {
            $failureText = @($downloadFailures | ForEach-Object { "$($_.RemotePath): $($_.Error)" }) -join '; '
            throw "SFTP-завантаження $componentType завершилося з помилками: $failureText"
        }
        if (-not (Test-Path -LiteralPath $localArchivePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $localHashPath -PathType Leaf)) {
            throw "після завантаження $componentType відсутній архів або sidecar у staging"
        }
        # Фактичний розмір завантаженого файлу мусить ТОЧНО збігатися з
        # валідованим ArchiveSize із manifest-а: WinSCP може повідомити
        # "успіх" при частковому/пошкодженому transfer-і, а сам ArchiveSize —
        # недовірене поле, тому теж проходить ту саму канонічну перевірку
        # перед порівнянням. SHA512/integrity-перевірка нижче лишається
        # обов'язковою і НЕ замінюється цим size-check-ом.
        $validatedArchiveSizeBytes = [long]0
        if (-not (Test-BRAVODataRestoreArchiveSize -Value $componentState.ArchiveSize -ValidatedBytes ([ref]$validatedArchiveSizeBytes))) {
            throw "manifest містить некоректний ArchiveSize для компонента ${componentType}: '$($componentState.ArchiveSize)'"
        }
        $actualArchiveSizeBytes = [long](Get-Item -LiteralPath $localArchivePath).Length
        if ($actualArchiveSizeBytes -ne $validatedArchiveSizeBytes) {
            throw "завантажений розмір архіву $componentType ($actualArchiveSizeBytes байт) не збігається з ArchiveSize у manifest ($validatedArchiveSizeBytes байт)"
        }
        $stagedPaths[$componentType] = [pscustomobject]@{
            ArchivePath = $localArchivePath
            HashPath = $localHashPath
        }
        Write-DataRestoreLog -Message "Завантажено з SFTP: $archiveFileName + sidecar -> $componentStagingDirectory" -Level 'SUCCESS'
    }
    return $stagedPaths
}

function ConvertTo-BRAVODataRestoreStagedManifest {
    # Глибока копія manifest-а з переписаними на staging шляхами артефактів —
    # далі весь pipeline (строгий gate включно) працює source-agnostic.
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][hashtable]$StagedPaths
    )

    $clone = $Manifest | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    foreach ($componentType in @($StagedPaths.Keys)) {
        $componentProperty = @($clone.components.PSObject.Properties | Where-Object {
            [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($componentProperty.Count -eq 0) { continue }
        $componentProperty[0].Value.ArchivePath = [string]$StagedPaths[$componentType].ArchivePath
        $componentProperty[0].Value.HashPath = [string]$StagedPaths[$componentType].HashPath
    }
    return $clone
}

# Get-BRAVODataRestoreValidatedArtifactLeafName і
# ConvertTo-BRAVODataRestoreRebasedLocalManifest (round-7 P2) промоутнуті
# в modules\BRAVO.ArchiveHelpers як Get-BRAVOVerifiedArtifactLeafName і
# ConvertTo-BRAVORebasedLocalGenerationManifest (post-round-7 follow-up
# P2, review 4945879933) — BRAVO_RESTORE_TEST.ps1 не мав доступу до цих
# приватних функцій цього runtime (окремий елевований дочірній процес),
# тому pre-restore drill і реальне відновлення застосовували РІЗНУ
# rebasing-політику для relocated local repository. Один canonical
# implementation тепер спільний для обох споживачів через уже імпортований
# нижче BRAVO.ArchiveHelpers.

function Invoke-BRAVODataRestorePostHealth {
    # Health після InPlace-відновлення — дочірнім процесом (той самий
    # прецедент, що запуск BRAVO_ARCHIV із Maintenance), ПІСЛЯ звільнення
    # operation lock: Health інспектує спільний lock і деградує перевірки
    # служб, поки той утримується.
    $healthScriptPath = [string]$global:backupHealthScriptPath
    if ([string]::IsNullOrWhiteSpace($healthScriptPath) -or
        -not (Test-Path -LiteralPath $healthScriptPath -PathType Leaf)) {
        Write-DataRestoreLog -Message "BRAVO_HEALTH.ps1 не знайдено ($healthScriptPath) — post-restore Health пропущено" -Level 'WARNING'
        return $null
    }
    try {
        Write-DataRestoreLog -Message 'Запуск post-restore BRAVO_HEALTH...' -Level 'INFO'
        # AUTO-намір: -ConfigPath вбудовується лише за explicit — інакше
        # дочірній Health трактував би auto-derived відсутній шлях як
        # explicit і кожен AUTO no-config restore давав би хибне
        # Health-попередження замість реальної перевірки.
        $healthConfigArgumentText = if ($configPathWasExplicit) {
            " -ConfigPath `"$ConfigPath`""
        } else {
            ''
        }
        $healthArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$healthScriptPath`"$healthConfigArgumentText -NoPause"
        $healthProcess = Start-Process -FilePath $schedulerSettings.PowerShellExecutable `
            -ArgumentList $healthArguments `
            -Wait `
            -PassThru `
            -NoNewWindow
        Write-DataRestoreLog -Message "BRAVO_HEALTH завершився з кодом $($healthProcess.ExitCode)" -Level 'INFO'
        return [int]$healthProcess.ExitCode
    } catch {
        Write-DataRestoreLog -Message "Не вдалося запустити post-restore Health: $($_.Exception.Message)" -Level 'WARNING'
        return $null
    }
}

function Send-BRAVODataRestoreNotification {
    # Webhook-сповіщення оператору. Збій сповіщення ніколи не змінює
    # результат відновлення — лише WARNING у журналі.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('SUCCESS', 'WARNING', 'CRITICAL')][string]$Severity,
        [Parameter(Mandatory = $true)][string[]]$ResultLines,
        [string]$ActionText
    )

    try {
        $notificationProvider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
        if ($notificationProvider -ne 'discord' -and $notificationProvider -ne 'slack') {
            $notificationProvider = 'discord'
        }
        $notificationRouting = $null
        $notificationCredentialTargets = $credentialSettings.Targets
        $notificationTimeoutSeconds = 30
        if ($null -ne $backupMonitoring) {
            if ($backupMonitoring.NotificationRouting -is [hashtable]) {
                $notificationRouting = $backupMonitoring.NotificationRouting
            }
            if ($backupMonitoring.NotificationCredentialTargets -is [hashtable]) {
                $notificationCredentialTargets = $backupMonitoring.NotificationCredentialTargets
            }
            if ([int]$backupMonitoring.NotificationRequestTimeoutSeconds -gt 0) {
                $notificationTimeoutSeconds = [int]$backupMonitoring.NotificationRequestTimeoutSeconds
            }
        }
        # Рішення «слати чи ні» вже ухвалене на call-site (включно з
        # DataRestore-специфічним SUCCESS для InPlace навіть під
        # errors_only), тому routing викликається в режимі 'all' і вирішує
        # лише канал доставки (GENERAL/ALERTS).
        $notificationRoute = Resolve-BRAVONotificationRoute `
            -Severity $Severity `
            -NotificationMode 'all' `
            -RoutingTable $notificationRouting
        try {
            $webhookUrl = Resolve-BRAVONotificationEndpoint `
                -Provider $notificationProvider `
                -Route $notificationRoute `
                -CredentialTargets $notificationCredentialTargets
        } catch {
            Write-DataRestoreLog -Message "Webhook для '$notificationProvider/$notificationRoute' не налаштовано — сповіщення пропущено" -Level 'WARNING'
            return
        }
        $message = New-BRAVOOperatorNotificationMessage `
            -Severity $Severity `
            -Operation 'BRAVO DATA RESTORE — ВІДНОВЛЕННЯ ДАНИХ' `
            -ActionText $ActionText `
            -InstitutionName ([string]$bravoSettings.InstitutionName) `
            -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
            -HostInformation (Get-HostInformation) `
            -ResultLines $ResultLines `
            -Timestamp (Get-Date) `
            -ProductName 'BRAVO Data Restore' `
            -Version ([string]$script:ScriptVersion) `
            -BuildId ([string]$script:ScriptBuildId) `
            -LogPath ([string]$script:dataRestoreLogFile)
        $messageChunks = ConvertTo-BRAVONotificationPayloadText `
            -Provider $notificationProvider `
            -Message $message
        Send-BRAVONotificationChunks `
            -Provider $notificationProvider `
            -WebhookUrl $webhookUrl `
            -MessageChunks $messageChunks `
            -TimeoutSeconds $notificationTimeoutSeconds
    } catch {
        $script:dataRestoreWarningCount++
        Write-DataRestoreLog -Message "Не вдалося надіслати сповіщення: $($_.Exception.Message)" -Level 'WARNING'
    }
}

# ===== ГОЛОВНИЙ ПОТІК =====

Initialize-BRAVOConsole
Initialize-BRAVOProgress -Enabled $false
$headerModeText = if ($ListGenerations) {
    'LIST GENERATIONS / READ-ONLY'
} elseif ($Mode -eq 'InPlace') {
    "IN-PLACE PRODUCTION RESTORE ($Source)"
} else {
    "OUT-OF-PLACE RESTORE ($Source)"
}
Write-BRAVOHeader `
    -Title ("BRAVO Data Restore {0}" -f $script:ScriptVersion) `
    -Institution ([string]$bravoSettings.InstitutionName) `
    -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
    -Mode $headerModeText
Write-DataRestoreLog -Message "BRAVO Data Restore $script:ScriptVersion (build $script:ScriptBuildId): Mode=$Mode, Source=$Source, Component=$Component, GenerationId='$GenerationId', ListGenerations=$ListGenerations" -Level 'INFO'

# Ранні інваріанти параметрів — до lock і будь-яких дій.
if (-not [string]::IsNullOrWhiteSpace($GenerationId) -and
    -not (Test-BRAVODataRestoreGenerationIdFormat -GenerationId $GenerationId)) {
    Write-Host "ПОМИЛКА: GenerationId має формат yyyyMMdd_HHmmss (або collision-safe variant): '$GenerationId'" -ForegroundColor Red
    Write-DataRestoreLog -Message "Некоректний GenerationId: '$GenerationId'" -Level 'ERROR'
    exit 30
}
if (-not $ListGenerations) {
    if ($Mode -eq 'OutOfPlace' -and [string]::IsNullOrWhiteSpace($TargetPath)) {
        Write-Host "ПОМИЛКА: для режиму OutOfPlace обов'язковий параметр -TargetPath (порожня або нова директорія)" -ForegroundColor Red
        Write-DataRestoreLog -Message 'OutOfPlace без -TargetPath — відхилено' -Level 'ERROR'
        exit 30
    }
    if ($Mode -eq 'InPlace' -and -not [string]::IsNullOrWhiteSpace($TargetPath)) {
        Write-Host "ПОМИЛКА: для режиму InPlace параметр -TargetPath заборонений — ціль визначає discovery (bravo.ini)" -ForegroundColor Red
        Write-DataRestoreLog -Message 'InPlace із -TargetPath — відхилено' -Level 'ERROR'
        exit 30
    }
}

# Цілісність інструментів перед їх запуском від імені адміністратора —
# лише тих, що реально будуть запущені для ЦІЄЇ операції. -ListGenerations
# — read-only перегляд (Local: файлова система/JSON, без 7-Zip; SFTP:
# лише WinSCP-лістинг) — вимога 7za.exe заблокувала б перегляд наявних
# backup-ів саме тоді, коли інструмент розпакування потребує ремонту.
$requiredTools = @()
if (-not $ListGenerations) { $requiredTools += '7za.exe' }
if ($Source -eq 'SFTP') { $requiredTools += 'WinSCP.com' }
$toolIntegrity = Test-BRAVODataRestoreToolIntegrity -ToolNames $requiredTools
if (@($toolIntegrity.Problems).Count -gt 0) {
    foreach ($toolProblem in $toolIntegrity.Problems) {
        Write-DataRestoreLog -Message "Цілісність інструментів: $toolProblem" -Level 'ERROR' -Console
    }
    if ([string]$toolIntegrity.Mode -ine 'Warn') {
        Write-Host 'ПОМИЛКА: перевірка цілісності інструментів (Tools\) не пройдена — запуск заблоковано' -ForegroundColor Red
        exit 32
    }
    $script:dataRestoreWarningCount++
}

# Canonical restore-target каталоги (незалежні від фізичної наявності) —
# той самий bravoDiscoveryResult, що вже формує ArchiveDefinitions.Source,
# але без existence-якісного фільтра BRAVOEXCH (BRAVO.config): для InPlace
# саме відсутній production-каталог і є типовим disaster-restore
# сценарієм. Обчислено РАНО (до режиму перегляду й staging-preflight
# нижче, і до кроку 3 основного pipeline), щоб УСІ місця — включно з
# read-only -ListGenerations -Source SFTP — бачили той самий набір
# live-джерел без повторного виведення.
$restoreTargetDirectories = @{
    MODEL = [string]$global:bravoDiscoveryResult.MODEL_SOURCE
    BLOG = [string]$global:bravoDiscoveryResult.BLOG_SOURCE
    BRAVOEXCH = [string]$global:bravoDiscoveryResult.BRAVOEXCH_SOURCE
}
$dataRestoreStagingLiveSources = Get-BRAVODataRestoreLiveSourceMap `
    -ArchiveDefinitions @($global:archiveDefinitions) `
    -RestoreTargetDirectories $restoreTargetDirectories

# ===== РЕЖИМ ПЕРЕГЛЯДУ =====
if ($ListGenerations) {
    if ($Source -eq 'Local') {
        $listCandidates = @()
        try {
            $listCandidates = @(Get-BRAVODataRestoreGenerationCandidates -BackupRoot $backupRootPath -Limit 25)
        } catch {
            Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
            exit 43
        }
        Write-BRAVOResultSection -Title "Доступні generation (BackupRoot: $backupRootPath)"
        if ($listCandidates.Count -eq 0) {
            Write-BRAVOResultNote -Text '  (жодного generation manifest не знайдено)'
        }
        foreach ($listCandidate in $listCandidates) {
            Write-BRAVOResultNote -Text ("  {0}  {1,-10}  {2:yyyy-MM-dd HH:mm}  {3}" -f `
                $listCandidate.GenerationId, $listCandidate.Status, $listCandidate.CreatedAt, $listCandidate.ComponentSummary)
        }
        Write-BRAVOResultNote -Text ''
        Write-BRAVOResultNote -Text 'Відновлюються лише COMPLETE generation; повна SHA512-верифікація виконується перед фактичним відновленням.'
        exit 0
    }
    # SFTP-перегляд: завантажуємо до 10 найновіших manifest-ів у тимчасовий
    # staging-підкаталог і показуємо їхній стан.
    try {
        Initialize-BRAVOCredentialManager
        Initialize-BRAVODataRestoreSftpCredentials
    } catch {
        Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
        exit 31
    }
    # Той самий staging-preflight, що захищає нормальний SFTP restore-потік
    # нижче за pipeline — без нього read-only "-ListGenerations -Source
    # SFTP" міг би все одно писати/рекурсивно очищати "_list_<guid>"
    # всередині live MODEL/BLOG/BRAVOEXCH чи RuntimeRoot ще ДО будь-якої
    # перевірки шляхів.
    $listStagingSafety = Test-BRAVODataRestoreStagingSafe `
        -StagingRoot $stagingRootPath `
        -RuntimeRootPath $bravoScriptDirectory `
        -LiveSources $dataRestoreStagingLiveSources
    if (-not $listStagingSafety.Success) {
        Write-Host "ПОМИЛКА: $($listStagingSafety.Error)" -ForegroundColor Red
        Write-DataRestoreLog -Message "Staging preflight (ListGenerations): $($listStagingSafety.Error)" -Level 'ERROR'
        exit 30
    }
    $listStagingDirectory = Join-Path $stagingRootPath ("_list_{0}" -f ([guid]::NewGuid().ToString('N')))
    try {
        [void](New-Item -ItemType Directory -Path $listStagingDirectory -Force -ErrorAction Stop)
        $remoteManifestDirectory = [string]$sftpDirectories.Manifest
        $listingSession = Invoke-BRAVODataRestoreWinSCPScript `
            -Commands @("ls `"$remoteManifestDirectory`"") `
            -TimeoutSeconds (Get-BRAVODataRestoreSftpOperationTimeoutSeconds)
        if (-not $listingSession.Success) {
            throw "не вдалося отримати перелік manifest-ів з SFTP: $($listingSession.Error)"
        }
        # Той самий контракт, що вже застосовується для вибору generation
        # (Invoke-BRAVODataRestoreSftpManifestFetch): Success=true від
        # Invoke-BRAVODataRestoreWinSCPScript НЕ гарантує, що сама ls-операція
        # завершилась успішно — без цієї перевірки перерваний/частковий
        # лістинг міг би мовчазно показати оператору неповний inventory як
        # нібито повний перелік доступних generation.
        if (-not (Test-BRAVODataRestoreWinSCPListingSucceeded -Xml $listingSession.Xml)) {
            throw 'перелік manifest-ів з SFTP не підтверджено (ls-операція не позначена як успішна в XML-журналі WinSCP)'
        }
        $remoteManifestNames = @(Sort-BRAVODataRestoreManifestNamesByGenerationDescending -ManifestNames @(
            Get-BRAVODataRestoreWinSCPListingNames -Xml $listingSession.Xml |
                Where-Object { $_ -match '^BRAVO_BACKUP_\d{8}_\d{6}(?:_\d+)?\.json$' }) |
            Select-Object -First 10)
        Write-BRAVOResultSection -Title "Доступні generation на SFTP ($remoteManifestDirectory)"
        if ($remoteManifestNames.Count -eq 0) {
            Write-BRAVOResultNote -Text '  (жодного generation manifest не знайдено)'
            if ([int]$listingSession.ExitCode -ne 0) {
                Write-BRAVOResultNote -Text '  Примітка: WinSCP повернув помилку listing — можливо, віддаленого каталогу manifests не існує.'
            }
        } else {
            $listGetCommands = @()
            foreach ($remoteManifestName in $remoteManifestNames) {
                $listGetCommands += "get `"$remoteManifestDirectory/$remoteManifestName`" `"$(Join-Path $listStagingDirectory $remoteManifestName)`""
            }
            $listDownloadSession = Invoke-BRAVODataRestoreWinSCPScript `
                -Commands $listGetCommands `
                -TimeoutSeconds (Get-BRAVODataRestoreSftpOperationTimeoutSeconds)
            if (-not $listDownloadSession.Success) {
                throw "не вдалося завантажити manifest-и: $($listDownloadSession.Error)"
            }
            # Per-download результати з XML-журналу (той самий контракт, що
            # вже застосовується для вибору generation): один частково
            # завантажений manifest у батчі не повинен мовчазно показуватись
            # як "(не прочитано)" поруч із рештою, ніби це звичайний
            # нечитабельний файл, а не наслідок збою transfer-у.
            $listDownloadResults = @(Get-BRAVODataRestoreWinSCPDownloads -Xml $listDownloadSession.Xml)
            foreach ($remoteManifestName in $remoteManifestNames) {
                $localListManifestPath = Join-Path $listStagingDirectory $remoteManifestName
                $matchingListDownload = @($listDownloadResults | Where-Object {
                    ([string]$_.RemotePath) -like "*$remoteManifestName"
                } | Select-Object -First 1)
                if ($matchingListDownload.Count -eq 0 -or -not [bool]$matchingListDownload[0].Success) {
                    Write-BRAVOResultNote -Text "  $remoteManifestName  (ЗАВАНТАЖЕННЯ НЕ ПІДТВЕРДЖЕНО)"
                    continue
                }
                $listLine = "  $remoteManifestName"
                if (Test-Path -LiteralPath $localListManifestPath -PathType Leaf) {
                    try {
                        $listManifest = [IO.File]::ReadAllText($localListManifestPath) | ConvertFrom-Json -ErrorAction Stop
                        # Ім'я файлу vs generationId у ЗМІСТІ manifest-а — той
                        # самий identity-контракт, що вже застосовується при
                        # виборі generation (Get-BRAVORestoreGenerationManifest):
                        # розбіжність не повинна показуватись оператору як
                        # звичайний валідний запис переліку.
                        $filenameGenerationId = [IO.Path]::GetFileNameWithoutExtension($remoteManifestName) -replace '^BRAVO_BACKUP_', ''
                        if (-not [string]::Equals($filenameGenerationId, [string]$listManifest.generationId, [StringComparison]::Ordinal)) {
                            $listLine = "  $remoteManifestName  (НЕЗБІЖНІСТЬ generationId: файл='$filenameGenerationId' JSON='$([string]$listManifest.generationId)')"
                        } else {
                            $listLine = ("  {0}  {1,-10}" -f [string]$listManifest.generationId, [string]$listManifest.status)
                        }
                    } catch {
                        $listLine = "  $remoteManifestName  (не прочитано)"
                    }
                }
                Write-BRAVOResultNote -Text $listLine
            }
        }
        Write-BRAVOResultNote -Text ''
        Write-BRAVOResultNote -Text 'Перелік показує стан за manifest; артефакти верифікуються повністю після завантаження.'
        exit 0
    } catch {
        Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
        exit 50
    } finally {
        if (Test-Path -LiteralPath $listStagingDirectory) {
            Remove-Item -LiteralPath $listStagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===== CREDENTIALS =====
try {
    Initialize-BRAVOCredentialManager
    $archiveCredentialTarget = [string]$credentialSettings.Targets.ArchivePassword
    if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
        $archiveCredentialTarget = 'BRAVO_7Z_PASSWORD'
    }
    $script:archivePassword = Get-BRAVOCredentialSecret -Target $archiveCredentialTarget
    if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
        throw "пароль архіву не знайдено в Credential Manager (target '$archiveCredentialTarget') для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    }
    if ($Source -eq 'SFTP') {
        Initialize-BRAVODataRestoreSftpCredentials
    }
} catch {
    Write-Host "ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
    Write-DataRestoreLog -Message "Credentials: $($_.Exception.Message)" -Level 'ERROR'
    exit 31
}

# WinSCP-скрипт використовує ASCII-кодування (config) — локальні шляхи
# staging мусять бути ASCII, інакше командний файл їх спотворить.
if ($Source -eq 'SFTP' -and
    ([string]$winSCPScriptEncoding) -ieq 'ASCII' -and
    -not (Test-BRAVODataRestoreAsciiPath -Path $stagingRootPath)) {
    Write-Host "ПОМИЛКА: staging-шлях містить не-ASCII символи ($stagingRootPath); задайте -StagingPath з ASCII-шляхом" -ForegroundColor Red
    Write-DataRestoreLog -Message "Не-ASCII staging для ASCII WinSCP-скрипта: $stagingRootPath" -Level 'ERROR'
    exit 30
}

# Staging-preflight МУСИТЬ пройти ДО будь-якого SFTP filesystem-запису
# (нижче за pipeline: вибір generation для Source=SFTP створює
# _manifests і завантажує через WinSCP ДО того, як Get-BRAVODataRestorePlan
# взагалі перевіряє шляхи). Без цієї перевірки зловмисний/помилковий
# -StagingPath, що перетинається з live MODEL/BLOG/BRAVOEXCH, дав би змогу
# запис/подальше рекурсивне очищення staging знищити production-дані ще до
# першої перевірки плану. ($dataRestoreStagingLiveSources обчислено раніше
# — той самий live-source map, що вже перевірив -ListGenerations -Source
# SFTP вище.)
if ($Source -eq 'SFTP') {
    $stagingSafety = Test-BRAVODataRestoreStagingSafe `
        -StagingRoot $stagingRootPath `
        -RuntimeRootPath $bravoScriptDirectory `
        -LiveSources $dataRestoreStagingLiveSources
    if (-not $stagingSafety.Success) {
        Write-Host "ПОМИЛКА: $($stagingSafety.Error)" -ForegroundColor Red
        Write-DataRestoreLog -Message "Staging preflight: $($stagingSafety.Error)" -Level 'ERROR'
        exit 30
    }
}

# ===== OPERATION LOCK =====
$lockAcquisition = Enter-BRAVODataRestoreOperationLock
if (-not $lockAcquisition.Success) {
    Write-Host "Пропущено: інша операція BRAVO вже виконується ($($lockAcquisition.Error))" -ForegroundColor Yellow
    Write-DataRestoreLog -Message "Operation lock зайнятий: $($lockAcquisition.Error)" -Level 'WARNING'
    exit 20
}
$script:dataRestoreOperationLock = $lockAcquisition.Stream
$script:dataRestoreOperationLockPath = $lockAcquisition.Path
Write-DataRestoreLog -Message "Operation lock захоплено: $($lockAcquisition.Path)" -Level 'INFO'

# ===== ОСНОВНИЙ PIPELINE =====
$selectedManifest = $null
$componentTypes = @()
$restorePlan = $null
$componentArtifacts = @{}
$componentInventories = @{}
try {
    try {
        # --- 1. Вибір generation ---
        $stageStartedAt = Get-Date
        if ($Source -eq 'Local') {
            $selectedGeneration = $null
            try {
                $selectedGeneration = Get-BRAVORestoreGenerationManifest `
                    -BackupRoot $backupRootPath `
                    -RequestedGenerationId $GenerationId
            } catch {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason $_.Exception.Message
            }
            # Аномалії fail-closed-пропуску під час автоматичного вибору
            # (нечитабельний manifest / identity mismatch) мають бути видимі
            # оператору: тихий пропуск означав би непомічене відновлення
            # старішої generation.
            foreach ($skippedManifest in @($selectedGeneration.SkippedManifests)) {
                Write-DataRestoreLog -Message "УВАГА: manifest пропущено під час вибору generation: $($skippedManifest.ManifestPath) — $($skippedManifest.Reason)" -Level 'WARNING' -Console
            }
            $selectedManifest = $selectedGeneration.Manifest
        } else {
            $script:dataRestoreStagingGenerationRoot = $null
            $stagingManifestDirectory = Join-Path $stagingRootPath '_manifests'
            $sftpSelected = $null
            try {
                $sftpSelected = Invoke-BRAVODataRestoreSftpManifestFetch `
                    -StagingManifestDirectory $stagingManifestDirectory `
                    -RequestedGenerationId $GenerationId
            } catch {
                Stop-BRAVODataRestoreRun -Category SftpFailed -Reason $_.Exception.Message
            }
            $selectedManifest = $sftpSelected.Manifest
        }
        $script:dataRestoreSelectedGenerationId = [string]$selectedManifest.generationId
        if ([string]::IsNullOrWhiteSpace($script:dataRestoreSelectedGenerationId)) {
            Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason 'обраний manifest не містить generationId'
        }
        # generationId зі ЗМІСТУ manifest-а — недовірений вхід (особливо для
        # Source=SFTP, де manifest завантажується із зовнішнього хоста): перш
        # ніж значення бере участь у Join-Path для staging-каталогу нижче,
        # воно мусить пройти той самий канонічний формат, що й -GenerationId.
        if (-not (Test-BRAVODataRestoreGenerationIdFormat -GenerationId $script:dataRestoreSelectedGenerationId)) {
            Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "generationId з manifest-а має недопустимий формат: '$($script:dataRestoreSelectedGenerationId)'"
        }
        Write-BRAVOOperationResult `
            -Name 'Вибір generation' `
            -Status 'OK' `
            -Duration ((Get-Date) - $stageStartedAt) `
            -Details $script:dataRestoreSelectedGenerationId
        Write-DataRestoreLog -Message "Обрано generation $script:dataRestoreSelectedGenerationId (Source=$Source)" -Level 'INFO'

        # --- 2. Компоненти ---
        try {
            $componentTypes = @(Get-BRAVODataRestoreComponentSelection `
                -Manifest $selectedManifest `
                -RequestedComponent $Component)
        } catch {
            Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason $_.Exception.Message
        }
        foreach ($componentType in $componentTypes) {
            Add-BRAVODataRestoreComponentResult -ComponentType $componentType -Status 'NOT_RUN' -Detail 'очікує'
        }

        # --- 3. План цілей ---
        $restorePlan = Get-BRAVODataRestorePlan `
            -ComponentTypes $componentTypes `
            -RestoreMode $Mode `
            -RequestedTargetPath $TargetPath `
            -BackupRoot $backupRootPath `
            -RuntimeRootPath $bravoScriptDirectory `
            -StagingRoot $stagingRootPath `
            -ArchiveDefinitions @($global:archiveDefinitions) `
            -RestoreTargetDirectories $restoreTargetDirectories `
            -RunStamp $runTimestamp
        if (-not $restorePlan.Success) {
            Stop-BRAVODataRestoreRun -Category InvalidConfiguration -Reason $restorePlan.Error
        }

        # --- 4. SFTP: staging free-space + завантаження артефактів ---
        if ($Source -eq 'SFTP') {
            $stagingRequirements = @()
            $componentsPropertyForSizes = $selectedManifest.PSObject.Properties['components']
            foreach ($componentType in $componentTypes) {
                $componentStateForSize = @($componentsPropertyForSizes.Value.PSObject.Properties | Where-Object {
                    [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)[0].Value
                # ArchiveSize зі ЗМІСТУ manifest-а — недовірений вхід (SFTP):
                # відсутнє/нульове/від'ємне/нечислове значення відхиляємо
                # ДО того, як воно занизить free-space preflight.
                $validatedArchiveSizeBytes = [long]0
                if (-not (Test-BRAVODataRestoreArchiveSize -Value $componentStateForSize.ArchiveSize -ValidatedBytes ([ref]$validatedArchiveSizeBytes))) {
                    Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "manifest містить некоректний ArchiveSize для компонента ${componentType}: '$($componentStateForSize.ArchiveSize)'"
                }
                $stagingRequirements += [pscustomobject]@{
                    TargetDirectory = Join-Path (Join-Path $stagingRootPath $script:dataRestoreSelectedGenerationId) $componentType
                    RequiredBytes = $validatedArchiveSizeBytes
                    # Staging-каталог — не live production-джерело (на
                    # відміну від InPlace TargetDirectory), тому явного
                    # ProbeDirectory не потрібно: Test-BRAVODataRestoreFreeSpace
                    # сам піднімається до найближчого наявного батьківського
                    # каталогу, коли TargetDirectory ще не створено. Властивість
                    # усе одно МАЄ бути оголошена — Set-StrictMode успадковується
                    # від конфігураційного завантажувача, і звернення до
                    # невідомої властивості pscustomobject кидає
                    # PropertyNotFoundException (це й був корінь дефекту B4).
                    ProbeDirectory = $null
                }
            }
            $stagingSpaceCheck = Test-BRAVODataRestoreFreeSpace `
                -Requirements $stagingRequirements `
                -MinimumFreeGigabytes ([double]$maintenanceSettings.Limits.MinimumFreeSpaceGB)
            foreach ($stagingSpaceNote in $stagingSpaceCheck.Notes) {
                Write-DataRestoreLog -Message "Staging free-space: $stagingSpaceNote" -Level 'INFO'
            }
            if (-not $stagingSpaceCheck.Success) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason ("staging: " + ($stagingSpaceCheck.Problems -join '; '))
            }
            $script:dataRestoreStagingGenerationRoot = Join-Path $stagingRootPath $script:dataRestoreSelectedGenerationId
            # Defense-in-depth поверх формат-перевірки generationId вище:
            # обчислений шлях мусить фізично лежати всередині staging root
            # (canonical containment-перевірка, той самий Test-BRAVODataRestorePathWithin,
            # що й для OutOfPlace -TargetPath).
            if (-not (Test-BRAVODataRestorePathWithin -Path $script:dataRestoreStagingGenerationRoot -Directory $stagingRootPath)) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "обчислений staging-шлях generation виходить за межі staging root: $($script:dataRestoreStagingGenerationRoot)"
            }
            $stageStartedAt = Get-Date
            $stagedPaths = $null
            try {
                $stagedPaths = Invoke-BRAVODataRestoreSftpArchiveFetch `
                    -Manifest $selectedManifest `
                    -ComponentTypes $componentTypes `
                    -StagingGenerationRoot $script:dataRestoreStagingGenerationRoot
            } catch {
                $script:dataRestoreStagingKept = $true
                Stop-BRAVODataRestoreRun -Category SftpFailed -Reason $_.Exception.Message
            }
            Write-BRAVOOperationResult `
                -Name 'Завантаження з SFTP' `
                -Status 'OK' `
                -Duration ((Get-Date) - $stageStartedAt)
            $selectedManifest = ConvertTo-BRAVODataRestoreStagedManifest `
                -Manifest $selectedManifest `
                -StagedPaths $stagedPaths
        } else {
            # Local (round-7 P2, canonical implementation promoted до
            # BRAVO.ArchiveHelpers у post-round-7 follow-up): та сама
            # ідея, що ConvertTo-BRAVODataRestoreStagedManifest для SFTP —
            # переписати ArchivePath/HashPath на canonical каталог
            # компонента ДО строгого gate нижче, щоб репозиторій резервних
            # копій, скопійований/змонтований під іншим диском/коренем,
            # лишався придатним для відновлення. Той самий
            # ConvertTo-BRAVORebasedLocalGenerationManifest використовує й
            # BRAVO_RESTORE_TEST.ps1 (pre-restore drill) — одна rebasing-
            # політика для обох споживачів generation-manifest.
            $selectedManifest = ConvertTo-BRAVORebasedLocalGenerationManifest `
                -Manifest $selectedManifest `
                -ComponentTypes $componentTypes `
                -ArchiveDefinitions @($global:archiveDefinitions)
        }

        # --- 5. Строгий gate по кожному компоненту ---
        $componentsProperty = $selectedManifest.PSObject.Properties['components']
        foreach ($componentType in $componentTypes) {
            $stageStartedAt = Get-Date
            $componentState = @($componentsProperty.Value.PSObject.Properties | Where-Object {
                [string]::Equals($_.Name, $componentType, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)[0].Value

            # 5a. Прапорці manifest і фізична наявність — категорія RestoreFailed
            # (неповна generation), окремо від хеш-проблем.
            if (-not ([bool]$componentState.Enabled -and [bool]$componentState.CreateSuccess -and
                    [bool]$componentState.IntegritySuccess -and [bool]$componentState.HashSuccess)) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component $componentType не має COMPLETE archive/integrity/SHA512 state у manifest"
            }
            $manifestArchivePath = [string]$componentState.ArchivePath
            $manifestHashPath = [string]$componentState.HashPath
            if (-not (Test-Path -LiteralPath $manifestArchivePath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $manifestHashPath -PathType Leaf)) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component ${componentType}: архів або sidecar відсутні ($manifestArchivePath)"
            }
            # 5b. Manifest-шляхи — недовірений вхід: для Local вони мусять
            # лежати в межах BackupRoot (захист від path traversal). Для SFTP
            # шляхи вже переписані на наш власний staging.
            $artifactContainmentRoot = if ($Source -eq 'Local') { $backupRootPath } else { $script:dataRestoreStagingGenerationRoot }
            foreach ($artifactPath in @($manifestArchivePath, $manifestHashPath)) {
                if (-not (Test-BRAVODataRestorePathWithin -Path $artifactPath -Directory $artifactContainmentRoot)) {
                    Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component ${componentType}: артефакт поза межами довіреного кореня ($artifactPath)"
                }
            }
            # 5c. Спільний строгий gate (sidecar + фактичний SHA512). Після
            # пре-перевірок вище будь-яка його відмова — саме хеш-клас (42).
            $verifiedArchive = $null
            $componentNameTemplate = [string]@($global:archiveDefinitions | Where-Object {
                [string]::Equals([string]$_.Type, $componentType, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1).NameTemplate
            # Canonical каталог цього Component: для Local — production
            # Destination з BRAVO.config (те саме джерело істини, куди
            # Archive реально пише); для SFTP — per-component підкаталог
            # staging generation root, куди Invoke-BRAVODataRestoreSftpArchiveFetch
            # завантажив саме цей компонент (ArchivePath у $selectedManifest
            # уже переписаний на staging через ConvertTo-BRAVODataRestoreStagedManifest).
            $componentExpectedDirectory = if ($Source -eq 'Local') {
                [string]@($global:archiveDefinitions | Where-Object {
                    [string]::Equals([string]$_.Type, $componentType, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1).Destination
            } else {
                Join-Path $script:dataRestoreStagingGenerationRoot $componentType
            }
            try {
                $verifiedArchive = Get-BRAVOVerifiedGenerationArchive `
                    -Manifest $selectedManifest `
                    -Component $componentType `
                    -NameTemplate $componentNameTemplate `
                    -ComponentDirectory $componentExpectedDirectory
            } catch {
                Stop-BRAVODataRestoreRun -Category HashValidationFailed -Reason $_.Exception.Message
            }
            # 5d. Крос-перевірка sidecar проти хешу, записаного в manifest.
            $manifestRecordedHash = [string]$componentState.SHA512
            if (-not [string]::IsNullOrWhiteSpace($manifestRecordedHash)) {
                $sidecarText = ([IO.File]::ReadAllText($manifestHashPath)).Trim([char]0xFEFF).Trim()
                if ($sidecarText -match '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
                    if ($Matches.Hash.ToUpperInvariant() -cne $manifestRecordedHash.ToUpperInvariant()) {
                        Stop-BRAVODataRestoreRun -Category HashValidationFailed -Reason "component ${componentType}: SHA512 у sidecar і в manifest не збігаються"
                    }
                }
            }
            # 5e. 7-Zip integrity.
            $integrityOk = Test-SevenZipArchiveIntegrity `
                -SevenZipPath $arcPath `
                -ArchivePath $verifiedArchive.FullName `
                -Password $script:archivePassword `
                -TimeoutSeconds $script:effectiveSevenZipTimeoutSeconds `
                -Logger { param($m, $l) Write-DataRestoreLog -Message $m -Level $l }
            if (-not $integrityOk) {
                Stop-BRAVODataRestoreRun -Category IntegrityTestFailed -Reason "component ${componentType}: 7za t (перевірка цілісності) не пройдено"
            }
            $componentArtifacts[$componentType] = $verifiedArchive
            Write-BRAVOOperationResult `
                -Name "Перевірка $componentType" `
                -Status 'OK' `
                -Duration ((Get-Date) - $stageStartedAt) `
                -Details $verifiedArchive.Name
        }

        # --- 6. Інвентаризація архівів ---
        $stageStartedAt = Get-Date
        foreach ($componentType in $componentTypes) {
            $inventory = Get-BRAVOSevenZipArchiveInventory `
                -SevenZipPath $arcPath `
                -ArchivePath $componentArtifacts[$componentType].FullName `
                -Password $script:archivePassword `
                -TimeoutSeconds $script:effectiveSevenZipTimeoutSeconds
            if (-not $inventory.Success) {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component ${componentType}: інвентаризація архіву не вдалася ($($inventory.Description))"
            }
            $componentInventories[$componentType] = $inventory
            Write-DataRestoreLog -Message ("Інвентаризація {0}: файлів {1}, каталогів {2}, обсяг {3}" -f `
                $componentType, $inventory.FileCount, $inventory.DirectoryCount,
                (Format-BRAVOFileSize -Bytes ([long]$inventory.TotalUncompressedBytes))) -Level 'INFO'
        }
        Write-BRAVOOperationResult `
            -Name 'Інвентаризація архівів' `
            -Status 'OK' `
            -Duration ((Get-Date) - $stageStartedAt)

        # --- 7. Free-space preflight цілей ---
        $stageStartedAt = Get-Date
        $targetRequirements = @()
        foreach ($planComponent in $restorePlan.Components) {
            $requirementProbeDirectory = $null
            if ($Mode -eq 'InPlace') {
                # InPlace TargetDirectory === live production-каталог (ще
                # існує, служби ще працюють, оператор ще не підтвердив) —
                # write-probe туди не пишемо; пробуємо батьківський каталог.
                $requirementProbeDirectory = Split-Path -Path ([string]$planComponent.TargetDirectory) -Parent
            }
            $targetRequirements += [pscustomobject]@{
                TargetDirectory = [string]$planComponent.TargetDirectory
                RequiredBytes = [long]$componentInventories[[string]$planComponent.Type].TotalUncompressedBytes
                ProbeDirectory = $requirementProbeDirectory
            }
        }
        $targetSpaceCheck = Test-BRAVODataRestoreFreeSpace `
            -Requirements $targetRequirements `
            -MinimumFreeGigabytes ([double]$maintenanceSettings.Limits.MinimumFreeSpaceGB)
        foreach ($spaceNote in $targetSpaceCheck.Notes) {
            Write-DataRestoreLog -Message "Free-space: $spaceNote" -Level 'INFO'
        }
        if (-not $targetSpaceCheck.Success) {
            Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason ($targetSpaceCheck.Problems -join '; ')
        }
        Write-BRAVOOperationResult `
            -Name 'Перевірка вільного місця' `
            -Status 'OK' `
            -Duration ((Get-Date) - $stageStartedAt)

        # --- 8. План відновлення (друк) + InPlace-специфіка ---
        Write-BRAVOResultSection -Title 'План відновлення'
        Write-BRAVOResultNote -Text ("  Generation: {0}" -f $script:dataRestoreSelectedGenerationId)
        foreach ($planComponent in $restorePlan.Components) {
            $planInventory = $componentInventories[[string]$planComponent.Type]
            Write-BRAVOResultNote -Text ("  {0}: {1} файлів, {2} -> {3}" -f `
                $planComponent.Type, $planInventory.FileCount,
                (Format-BRAVOFileSize -Bytes ([long]$planInventory.TotalUncompressedBytes)),
                $planComponent.TargetDirectory)
            if (-not [string]::IsNullOrWhiteSpace([string]$planComponent.PrerestoreDirectory)) {
                Write-BRAVOResultNote -Text ("      поточні дані -> {0}" -f $planComponent.PrerestoreDirectory)
            }
        }

        if ($Mode -eq 'InPlace') {
            # Наявні .prerestore-копії попередніх відновлень — видимі, не мовчазні.
            foreach ($planComponent in $restorePlan.Components) {
                $liveParent = Split-Path ([string]$planComponent.LiveSourceDirectory) -Parent
                $liveLeaf = Split-Path ([string]$planComponent.LiveSourceDirectory) -Leaf
                if (-not [string]::IsNullOrWhiteSpace($liveParent) -and (Test-Path -LiteralPath $liveParent -PathType Container)) {
                    foreach ($existingPrerestore in @(Get-ChildItem -LiteralPath $liveParent -Directory -Filter "$liveLeaf.prerestore_*" -ErrorAction SilentlyContinue)) {
                        Write-BRAVOResultNote -Text ("      наявна попередня копія: {0} (від {1:yyyy-MM-dd HH:mm})" -f $existingPrerestore.FullName, $existingPrerestore.LastWriteTime)
                    }
                }
            }
            # Знімок стану служб.
            $stageStartedAt = Get-Date
            $script:dataRestoreServiceSnapshot = Get-BRAVODataRestoreServiceSnapshot `
                -ServicesSettings $maintenanceSettings.Services
            # Два РІЗНІ набори (round-7 follow-up P2 — не плутати їх):
            #   $managedServicesForQuiescence — ВСІ Managed-служби: саме на
            #     них діє примусова Stopped-квієсценція нижче, і вона
            #     повторно перевіряє ПОТОЧНИЙ стан (а не WasRunning зі
            #     знімка) — initially-Stopped служба, що встигла запуститись
            #     до квієсценції, так само буде зупинена (гонитву це вже
            #     закрито раніше). Стара назва "$servicesToStop" з фільтром
            #     "WasRunning" оманливо натякала, що квієсценція торкається
            #     лише службу, яка вже працювала на момент знімка.
            #   $servicesWithRestartIntent — підмножина Managed, де
            #     ShouldRestartAfterRestore=true (Running АБО StartPending на
            #     момент знімка) — саме ці служби буде запущено назад після
            #     restore, незалежно від літерального WasRunning.
            $managedServicesForQuiescence = @($script:dataRestoreServiceSnapshot | Where-Object { $_.Managed })
            $servicesWithRestartIntent = @($script:dataRestoreServiceSnapshot | Where-Object { $_.Managed -and $_.ShouldRestartAfterRestore })
            Write-BRAVOResultNote -Text ("  Керовані служби (підлягають примусовій зупинці): {0}" -f $(if ($managedServicesForQuiescence.Count -gt 0) { @($managedServicesForQuiescence | ForEach-Object { $_.Name }) -join ', ' } else { 'немає' }))
            Write-BRAVOResultNote -Text ("  Намір відновлення після restore (Running/StartPending на момент знімка): {0}" -f $(if ($servicesWithRestartIntent.Count -gt 0) { @($servicesWithRestartIntent | ForEach-Object { $_.Name }) -join ', ' } else { 'немає' }))
            # Аудиторський запис у ФАЙЛ ЛОГУ (не лише консоль), ДО move-aside
            # (round-7 follow-up P2): якщо процес переривається (kill/BSOD/
            # закриття PowerShell) до фінального finally-кроку запуску служб,
            # автоматичний restart-крок може НІКОЛИ не виконатись. Оператор
            # МУСИТЬ мати змогу відновити restart-intent саме з ЛОГУ цього
            # конкретного перерваного прогону — не з ефемерного in-memory
            # ShouldRestartAfterRestore і не вгадуванням з поточного стану
            # служб після перезавантаження (те й інше вже заборонено
            # OPERATIONS.md для .prerestore_* вибору з тієї ж причини).
            foreach ($snapshotEntry in $managedServicesForQuiescence) {
                $auditInitialStatus = if ([string]::IsNullOrWhiteSpace([string]$snapshotEntry.InitialStatus)) { 'Unknown' } else { [string]$snapshotEntry.InitialStatus }
                $auditRestartIntent = if ($snapshotEntry.ShouldRestartAfterRestore) { 'YES' } else { 'NO' }
                Write-DataRestoreLog -Message ("Знімок служби {0}: initial={1}, restart-after-recovery={2}" -f $snapshotEntry.Name, $auditInitialStatus, $auditRestartIntent)
            }
            Write-BRAVOOperationResult `
                -Name 'Знімок стану служб' `
                -Status 'OK' `
                -Duration ((Get-Date) - $stageStartedAt)

            # Підтвердження — після повного плану, до першої деструктивної дії.
            if (-not (Request-BRAVODataRestoreConfirmation `
                    -GenerationIdToConfirm $script:dataRestoreSelectedGenerationId `
                    -ForceConfirmation:$Force)) {
                Stop-BRAVODataRestoreRun -Category InvalidConfiguration -Reason 'підтвердження оператора не отримано — відновлення скасовано, жодних змін не виконано'
            }

            # Зупинка служб + процесів (Invoke-BRAVODataRestoreQuiescence:
            # зупинка/термінація + фінальний бар'єр в одному виклику — той
            # самий композит повторно викликається перед КОЖНИМ компонентом
            # у циклі нижче).
            $stageStartedAt = Get-Date
            $script:dataRestoreServicesStopped = $true
            # Ownership-маркер зупинки служб — ПЕРЕД quiescence (та сама
            # консервативна семантика, що й прапорець вище). Пишуться лише
            # служби з наміром відновлення (ShouldRestartAfterRestore).
            # Маркер ОДРАЗУ -RestartSuppressed: якщо цей процес загине
            # ЖОРСТКО (kill/BSOD/живлення) посеред деструктивної фази, live
            # filesystem лишиться в невизначеному стані, і Health-watchdog
            # НЕ МАЄ права автостартувати служби поверх нього (це зруйнувало
            # б fail-closed гарантію finally-гілки нижче) — він лише
            # алертитиме CRITICAL про потребу ручного відновлення.
            # Restart-intent для оператора продубльовано в лог-файлі цього
            # прогону (аудиторський запис вище). Збій запису = аборт
            # (fail-closed). Якщо намір відновлення порожній (жодна керована
            # служба не працювала на момент знімка — типово для тестових/
            # ізольованих прогонів), маркер не потрібен: без нього watchdog
            # і так ніколи не діє.
            if ($servicesWithRestartIntent.Count -gt 0) {
                try {
                    [void](Write-BRAVOServiceQuiescenceState `
                        -Owner 'BRAVO_DATA_RESTORE' `
                        -Services @($servicesWithRestartIntent | ForEach-Object {
                            @{ Name = [string]$_.Name; RestartIntent = $true }
                        }) `
                        -LogFile ([string]$script:dataRestoreLogFile) `
                        -RestartSuppressed)
                    $script:dataRestoreQuiescenceMarkerWritten = $true
                } catch {
                    Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "не вдалося записати ownership-маркер зупинки служб (без нього аварійне переривання лишило б служби зупиненими «мовчазно», без сліду власника і CRITICAL-алерту Health): $($_.Exception.Message)"
                }
            }
            $quiescenceFailures = Invoke-BRAVODataRestoreQuiescence `
                -Snapshot $script:dataRestoreServiceSnapshot `
                -StopTimeoutSeconds $serviceStopTimeoutSeconds `
                -PollIntervalSeconds $servicePollIntervalSeconds
            if (@($quiescenceFailures).Count -gt 0) {
                Write-BRAVOOperationResult -Name 'Зупинка служб' -Status 'FAIL' -Duration ((Get-Date) - $stageStartedAt)
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason ($quiescenceFailures -join '; ')
            }
            Write-BRAVOOperationResult `
                -Name 'Зупинка служб' `
                -Status $(if ($managedServicesForQuiescence.Count -gt 0) { 'OK' } else { 'SKIPPED' }) `
                -Duration ((Get-Date) - $stageStartedAt)
        }

        # --- 9. Відновлення по компонентах (fail-fast) ---
        # Успішно відновлені InPlace-компоненти цього прогону: потрібні, щоб
        # при збої наступного компонента повернути production до узгодженого
        # стану (крос-компонентний rollback), а не лишити суміш generation.
        $completedInPlaceComponents = New-Object System.Collections.ArrayList
        $createdTargetRoot = $false
        if ($Mode -eq 'OutOfPlace' -and -not (Test-Path -LiteralPath $restorePlan.TargetRoot -PathType Container)) {
            # БЕЗ -Force: якщо TargetRoot з'явився паралельно (інший
            # процес/оператор) у вузькому вікні між Test-Path вище і цим
            # викликом, New-Item провалюється замість мовчазного прийняття
            # наявного каталогу як "щойно створеного цим прогоном" — з
            # -Force цей прогін позначив би чужий каталог $createdTargetRoot
            # =true й пізніше міг би замінити його ACL чи рекурсивно
            # видалити при провалі захисного ACL, знищивши файли, які
            # з'явилися там від іншого власника. $createdTargetRoot
            # встановлюється в true ЛИШЕ після підтвердженого успішного
            # створення нижче.
            try {
                [void](New-Item -ItemType Directory -Path $restorePlan.TargetRoot -ErrorAction Stop)
            } catch {
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "ціль out-of-place кореня з'явилася між плануванням і створенням (не створено цим прогоном): $($restorePlan.TargetRoot) ($($_.Exception.Message))"
            }
            $createdTargetRoot = $true
            try {
                Set-BRAVODataRestoreCreatedDirectoryAcl -Path $restorePlan.TargetRoot
            } catch {
                # Захисний ACL — ЄДИНИЙ контроль конфіденційності для щойно
                # створеного out-of-place кореня (видобуті LIMS-дані інакше
                # лишаються лише з успадкованими, потенційно широкодоступними
                # правами каталогу). Провал не може бути WARNING із
                # продовженням extraction — це fail-open. Прибираємо ЛИШЕ
                # щойно створений цим прогоном (ще порожній, $createdTargetRoot=true)
                # корінь — ніколи наявний оператор-owned каталог.
                $aclFailureReason = $_.Exception.Message
                try {
                    if (Test-Path -LiteralPath $restorePlan.TargetRoot) {
                        Remove-Item -LiteralPath $restorePlan.TargetRoot -Recurse -Force -ErrorAction Stop
                    }
                } catch {
                    $aclFailureReason = "$aclFailureReason; додатково не вдалося прибрати щойно створений незахищений корінь $($restorePlan.TargetRoot): $($_.Exception.Message)"
                }
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "захисний ACL для нового out-of-place кореня не застосовано: $aclFailureReason"
            }
        }
        foreach ($planComponent in $restorePlan.Components) {
            $componentType = [string]$planComponent.Type
            $componentStartedAt = Get-Date
            $moveAsidePerformed = $false
            # Транзакція компонента вважається "armed" ЛИШЕ після підтвердженого
            # move-aside Success=true — незалежно від Performed (Performed=false
            # ще й тоді, коли live-джерела не існувало, і transaction все одно
            # володіє щойно створеною ціллю). Якщо move-aside сам провалився
            # (Success=false), TargetDirectory для InPlace === оригінальний
            # live-каталог, який на цей момент навіть НЕ торкався — catch-гілка
            # нижче не має права видаляти його як "частковий результат".
            $moveAsideArmed = $false
            # OutOfPlace: cleanup при відмові компонента має право видалити
            # ЛИШЕ target-каталог, який СТВОРИВ цей прогін (New-Item нижче),
            # а не будь-який каталог, що опинився за цим шляхом — інакше
            # відмова компонента могла б знищити operator-owned каталог
            # (власний ACL/файли), який з'явився за цим шляхом уже ПІСЛЯ
            # планування (TOCTOU-вікно між Get-BRAVODataRestorePlan і цим
            # моментом).
            $outOfPlaceTargetCreatedByThisRun = $false
            # InPlace-дзеркало тієї самої гарантії володіння: якщо
            # unmanaged-процес/watchdog відновить live-каталог ПІСЛЯ
            # move-aside, але ДО створення цілі нижче, цей прогін не має
            # права ані розпаковувати поверх нього (fresh-empty-target
            # інваріант), ані пізніше видаляти його як "частковий
            # результат" під час rollback — round-7 P2.
            $inPlaceTargetCreatedByThisRun = $false
            try {
                if ($Mode -eq 'InPlace') {
                    # Re-встановлення інваріанту тиші БЕЗПОСЕРЕДНЬО перед
                    # move-aside ЦЬОГО компонента (не лише один раз на
                    # початку транзакції): для багатокомпонентного
                    # відновлення MODEL extraction може тривати довго, і
                    # служба/процес могли повернутись у активний стан до
                    # того, як черга дійде до BLOG/BRAVOEXCH. Виняток летить
                    # у той самий catch, що й реальні відмови move-aside —
                    # без окремого test-only шляху.
                    $componentQuiescenceFailures = Invoke-BRAVODataRestoreQuiescence `
                        -Snapshot $script:dataRestoreServiceSnapshot `
                        -StopTimeoutSeconds $serviceStopTimeoutSeconds `
                        -PollIntervalSeconds $servicePollIntervalSeconds
                    if (@($componentQuiescenceFailures).Count -gt 0) {
                        throw ("тиша служб/процесів не підтверджена перед компонентом ${componentType}: " + ($componentQuiescenceFailures -join '; '))
                    }
                    $moveAsideResult = Invoke-BRAVODataRestoreMoveAside `
                        -LiveDirectory $planComponent.LiveSourceDirectory `
                        -PrerestoreDirectory $planComponent.PrerestoreDirectory
                    if (-not $moveAsideResult.Success) {
                        throw $moveAsideResult.Error
                    }
                    $moveAsideArmed = $true
                    $moveAsidePerformed = [bool]$moveAsideResult.Performed
                    # Test-only deterministic failpoint (B20 acceptance):
                    # ПІСЛЯ підтвердженого move-aside SUCCESS (компонент уже
                    # мутований), ДО створення цільового каталогу й
                    # extraction. No-op у будь-якому production/normal
                    # test-запуску — див. Invoke-BRAVODataRestoreTestFailPoint.
                    Invoke-BRAVODataRestoreTestFailPoint -Point 'AfterMoveAside' -Component $componentType
                }
                # Свіжий порожній каталог цілі — нічого не перезаписується
                # за конструкцією.
                if ($Mode -eq 'OutOfPlace') {
                    # Повторна (race-safe) перевірка відсутності безпосередньо
                    # перед створенням: план вимагав відсутності цілі, але між
                    # плануванням і цим моментом каталог міг з'явитися (інший
                    # процес/оператор) — тоді ми НЕ можемо претендувати на
                    # володіння ним і мусимо відмовити компонент, а не мовчки
                    # extract-ити в чужий каталог чи пізніше видалити його.
                    if (Test-Path -LiteralPath $planComponent.TargetDirectory) {
                        throw "ціль компонента з'явилася між плануванням і відновленням (не створено цим прогоном): $($planComponent.TargetDirectory)"
                    }
                    [void](New-Item -ItemType Directory -Path $planComponent.TargetDirectory -ErrorAction Stop)
                    $outOfPlaceTargetCreatedByThisRun = $true
                } else {
                    # InPlace, БЕЗ -Force (round-7 P2): якщо unmanaged-процес
                    # чи watchdog відновив live-каталог ПІСЛЯ підтвердженого
                    # move-aside (наприклад, служба чи сторонній моніторинг
                    # відтворили порожню робочу директорію), New-Item без
                    # -Force провалюється замість мовчазного прийняття цього
                    # чужого каталогу — extraction ніколи не пише поверх
                    # даних, які цей прогін не створював, і $inPlaceTargetCreatedByThisRun
                    # лишається false, тож catch нижче не видалить/не
                    # перезапише його як "власний частковий результат".
                    [void](New-Item -ItemType Directory -Path $planComponent.TargetDirectory -ErrorAction Stop)
                    $inPlaceTargetCreatedByThisRun = $true
                }
                if ($Mode -eq 'InPlace' -and $moveAsidePerformed) {
                    # ACL знесеного попередника (не батьківського каталогу)
                    # — це production access control (напр. обліковий запис
                    # служби BRAVO). Провал переносу ACL раніше зводився до
                    # WARNING і extraction продовжувалась у каталог із лише
                    # успадкованими правами — служба могла піднятись, не
                    # маючи доступу до власних відновлених даних. Тепер це
                    # трактується як відмова компонента: throw летить у той
                    # самий catch нижче, що й будь-яка інша відмова
                    # (existing rollback/cross-component rollback), без
                    # окремого ACL-only rollback шляху.
                    try {
                        Copy-BRAVODataRestoreDirectoryAcl `
                            -SourceDirectory $planComponent.PrerestoreDirectory `
                            -DestinationDirectory $planComponent.TargetDirectory
                    } catch {
                        throw "перенесення ACL на $($planComponent.TargetDirectory) не вдалося: $($_.Exception.Message)"
                    }
                }
                $extractionResult = Invoke-BRAVOSevenZipExtraction `
                    -SevenZipPath $arcPath `
                    -ArchivePath $componentArtifacts[$componentType].FullName `
                    -Password $script:archivePassword `
                    -ExtractDirectory $planComponent.TargetDirectory `
                    -TimeoutSeconds $script:effectiveSevenZipTimeoutSeconds
                if (-not $extractionResult.Success) {
                    throw "розпакування не вдалося: $($extractionResult.Description)"
                }
                $verification = Test-BRAVODataRestoreExtractionResult `
                    -TargetDirectory $planComponent.TargetDirectory `
                    -Inventory $componentInventories[$componentType]
                if (-not $verification.Success) {
                    throw "post-verify не пройдено: $($verification.Problems -join '; ')"
                }
                $componentDurationSeconds = ((Get-Date) - $componentStartedAt).TotalSeconds
                $existingResult = @($script:dataRestoreComponentResults | Where-Object { $_.Component -eq $componentType })[0]
                [void]$script:dataRestoreComponentResults.Remove($existingResult)
                Add-BRAVODataRestoreComponentResult `
                    -ComponentType $componentType `
                    -Status 'RESTORED' `
                    -TargetDirectory $planComponent.TargetDirectory `
                    -PrerestoreDirectory $(if ($moveAsidePerformed) { $planComponent.PrerestoreDirectory } else { $null }) `
                    -FileCount $verification.FileCount `
                    -ByteCount $verification.ByteCount `
                    -DurationSeconds $componentDurationSeconds `
                    -Detail 'відновлено й перевірено'
                Write-BRAVOOperationResult `
                    -Name "Відновлення $componentType" `
                    -Status 'OK' `
                    -Duration ((Get-Date) - $componentStartedAt) `
                    -Details ("файлів: {0}, обсяг: {1}" -f $verification.FileCount, (Format-BRAVOFileSize -Bytes $verification.ByteCount))
                Write-DataRestoreLog -Message ("Компонент {0} відновлено: {1} файлів, {2} -> {3}" -f `
                    $componentType, $verification.FileCount,
                    (Format-BRAVOFileSize -Bytes $verification.ByteCount),
                    $planComponent.TargetDirectory) -Level 'SUCCESS'
                if ($Mode -eq 'InPlace') {
                    [void]$completedInPlaceComponents.Add([pscustomobject]@{
                        Type = $componentType
                        LiveDirectory = [string]$planComponent.TargetDirectory
                        PrerestoreDirectory = [string]$planComponent.PrerestoreDirectory
                        MoveAsidePerformed = $moveAsidePerformed
                    })
                }
            } catch {
                $componentFailureReason = $_.Exception.Message
                $currentComponentStatus = 'FAILED'
                $currentComponentPrerestoreDirectory = $null
                # Rollback: InPlace повертає prerestore-копію; OutOfPlace
                # прибирає частково розпакований підкаталог, який створили ми.
                if ($Mode -eq 'InPlace') {
                    if ($moveAsideArmed) {
                        $rollback = Undo-BRAVODataRestoreMoveAside `
                            -LiveDirectory $planComponent.TargetDirectory `
                            -PrerestoreDirectory $planComponent.PrerestoreDirectory `
                            -MoveAsidePerformed $moveAsidePerformed `
                            -TargetCreatedByThisRun $inPlaceTargetCreatedByThisRun
                        if (-not $rollback.Success) {
                            $componentFailureReason = "$componentFailureReason; $($rollback.Error)"
                            # Rollback самого компонента не завершився: копія
                            # лишається на місці (Undo-BRAVODataRestoreMoveAside
                            # нічого не видаляє при власному провалі) — статус
                            # має явно відрізнятись від "FAILED, чисто відкочено",
                            # інакше оператор не побачить, що потрібне ручне
                            # втручання саме для ЦЬОГО компонента.
                            $currentComponentStatus = 'ROLLBACK_FAILED'
                            $currentComponentPrerestoreDirectory = $planComponent.PrerestoreDirectory
                            $script:dataRestoreRollbackIncomplete = $true
                            Send-BRAVODataRestoreNotification `
                                -Severity 'CRITICAL' `
                                -ResultLines @("Rollback компонента $componentType не вдався", [string]$rollback.Error) `
                                -ActionText 'негайно перевірити стан каталогів компонента вручну.'
                        }
                    } else {
                        # Move-aside сам провалився ДО будь-якої мутації —
                        # оригінальний live-каталог не торкався, видаляти
                        # чи повертати нічого не потрібно.
                        Write-DataRestoreLog -Message "Move-aside компонента $componentType не вдався до жодної мутації файлової системи — оригінальні дані незмінені, відкат поточного компонента не потрібен." -Level 'WARNING'
                    }
                    # Крос-компонентний rollback: production не можна лишати
                    # зі змішаними generation (частина компонентів з backup,
                    # частина — зі старими даними), тому вже відновлені
                    # компоненти цього прогону теж повертаються назад.
                    if ($completedInPlaceComponents.Count -gt 0) {
                        $crossRollback = Undo-BRAVODataRestoreCompletedComponents `
                            -CompletedComponents @($completedInPlaceComponents.ToArray())
                        # ROLLED_BACK / ROLLBACK_FAILED: компонент, відкат якого
                        # НЕ завершився, не можна лишати зі статусом RESTORED —
                        # його каталог не є гарантовано ані новим, ані попереднім
                        # станом. Для ROLLBACK_FAILED зберігаємо PrerestoreDirectory:
                        # копія лишилась на місці й потрібна для ручного повернення.
                        foreach ($statusUpdate in @(Get-BRAVODataRestoreRollbackStatusUpdates `
                                -CrossRollbackResult $crossRollback `
                                -FailedComponent $componentType)) {
                            $previousResult = @($script:dataRestoreComponentResults |
                                Where-Object { $_.Component -eq $statusUpdate.Component })[0]
                            $preservedPrerestoreDirectory = $null
                            if ($null -ne $previousResult) {
                                if ([string]$statusUpdate.Status -eq 'ROLLBACK_FAILED') {
                                    $preservedPrerestoreDirectory = [string]$previousResult.PrerestoreDirectory
                                }
                                [void]$script:dataRestoreComponentResults.Remove($previousResult)
                            }
                            Add-BRAVODataRestoreComponentResult `
                                -ComponentType ([string]$statusUpdate.Component) `
                                -Status ([string]$statusUpdate.Status) `
                                -PrerestoreDirectory $preservedPrerestoreDirectory `
                                -Detail ([string]$statusUpdate.Detail)
                        }
                        if (@($crossRollback.Failures).Count -gt 0) {
                            $crossRollbackFailureText = @(Format-BRAVODataRestoreRollbackFailureText -Failures @($crossRollback.Failures))
                            $componentFailureReason = "$componentFailureReason; $($crossRollbackFailureText -join '; ')"
                            $script:dataRestoreRollbackIncomplete = $true
                            Send-BRAVODataRestoreNotification `
                                -Severity 'CRITICAL' `
                                -ResultLines (@('Відкат раніше відновлених компонентів не завершився') + $crossRollbackFailureText) `
                                -ActionText 'негайно перевірити стан каталогів компонентів вручну — production може бути у змішаному стані.'
                        }
                        [void]$completedInPlaceComponents.Clear()
                    }
                } else {
                    # Видаляємо ЛИШЕ каталог, який СТВОРИВ цей прогін
                    # (outOfPlaceTargetCreatedByThisRun): наперед існуючий
                    # (operator-owned) каталог за цим шляхом сюди дійти не
                    # може — планування вимагає його відсутності, а якщо він
                    # з'явився пізніше, New-Item вище вже кинув виняток ДО
                    # встановлення прапорця, і виконання сюди не дійшло б із
                    # $outOfPlaceTargetCreatedByThisRun = $true.
                    if ($outOfPlaceTargetCreatedByThisRun) {
                        try {
                            if (Test-Path -LiteralPath $planComponent.TargetDirectory) {
                                Remove-Item -LiteralPath $planComponent.TargetDirectory -Recurse -Force -ErrorAction Stop
                            }
                        } catch {
                            $script:dataRestoreWarningCount++
                            Write-DataRestoreLog -Message "Не вдалося прибрати частковий результат $($planComponent.TargetDirectory): $($_.Exception.Message)" -Level 'WARNING'
                        }
                    }
                }
                $existingResult = @($script:dataRestoreComponentResults | Where-Object { $_.Component -eq $componentType })[0]
                [void]$script:dataRestoreComponentResults.Remove($existingResult)
                Add-BRAVODataRestoreComponentResult `
                    -ComponentType $componentType `
                    -Status $currentComponentStatus `
                    -TargetDirectory $planComponent.TargetDirectory `
                    -PrerestoreDirectory $currentComponentPrerestoreDirectory `
                    -DurationSeconds ((Get-Date) - $componentStartedAt).TotalSeconds `
                    -Detail $componentFailureReason
                Write-BRAVOOperationResult `
                    -Name "Відновлення $componentType" `
                    -Status 'FAIL' `
                    -Duration ((Get-Date) - $componentStartedAt) `
                    -Details $componentFailureReason
                Stop-BRAVODataRestoreRun -Category RestoreFailed -Reason "component ${componentType}: $componentFailureReason"
            }
        }

        # --- 10. SFTP staging: успіх -> прибрати ---
        if ($Source -eq 'SFTP' -and -not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreStagingGenerationRoot)) {
            try {
                if (Test-Path -LiteralPath $script:dataRestoreStagingGenerationRoot) {
                    Remove-Item -LiteralPath $script:dataRestoreStagingGenerationRoot -Recurse -Force -ErrorAction Stop
                }
                $script:dataRestoreStagingKept = $false
            } catch {
                $script:dataRestoreStagingKept = $true
                $script:dataRestoreWarningCount++
                Write-DataRestoreLog -Message "Не вдалося прибрати staging $($script:dataRestoreStagingGenerationRoot): $($_.Exception.Message)" -Level 'WARNING'
            }
        }
    } catch {
        if (-not $script:dataRestoreControlledAbort) {
            $script:flagInternalError = $true
            Write-DataRestoreLog -Message "НЕОЧІКУВАНА ПОМИЛКА: $($_.Exception.Message)" -Level 'ERROR' -Console
            Write-DataRestoreLog -Message ([string]$_.ScriptStackTrace) -Level 'DEBUG'
        }
        if ($Source -eq 'SFTP' -and -not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreStagingGenerationRoot) -and
            (Test-Path -LiteralPath $script:dataRestoreStagingGenerationRoot)) {
            # Невдалий прогін лишає staging для діагностики/повтору (resume).
            $script:dataRestoreStagingKept = $true
        }
    } finally {
        # Відновлення стану служб — гарантовано, навіть після необробленої
        # помилки: запускаються лише ті, що працювали на момент знімка.
        #
        # ВИНЯТОК: якщо rollback (поточного компонента або раніше
        # завершених) не гарантовано довершився, live filesystem у
        # невизначеному стані — каталог може бути відсутній або містити
        # лише часткову extraction, а відновлювані дані лежать окремо в
        # prerestore-копії. Запускати служби поверх цього не можна: BRAVO
        # чи Exchange можуть ініціалізуватись/записати в цей каталог ДО
        # того, як оператор виконає задокументоване ручне відновлення.
        # Наразі немає надійного відображення компонент->служба, тому
        # безпечніше лишити ВСІ служби зі знімка зупиненими, а не запускати
        # частину.
        if ($script:dataRestoreRollbackIncomplete) {
            $script:flagRestoreFailed = $true
            if ([string]::IsNullOrWhiteSpace([string]$script:dataRestoreAbortReason)) {
                $script:dataRestoreAbortReason = 'відкат не гарантовано довершився — служби навмисно залишено зупиненими, потрібне ручне відновлення (OPERATIONS.md, код 43)'
            }
            Write-DataRestoreLog -Message 'Служби НАВМИСНО залишено зупиненими: відкат не гарантовано довершився, live filesystem у невизначеному стані. Потрібне ручне відновлення перед запуском служб.' -Level 'ERROR' -Console
            Write-BRAVOOperationResult -Name 'Відновлення стану служб' -Status 'SKIPPED' -Details 'служби навмисно залишено зупиненими через незавершений rollback — ручне відновлення обов''язкове'
            # Ownership-маркер НЕ видаляється: Health-watchdog побачить його,
            # НЕ стартуватиме служби (маркер suppressed від самого створення —
            # автостарт зруйнував би fail-closed гарантію вище) і алертитиме
            # про потребу ручного втручання, доки оператор не розбереться.
            # Set нижче — ідемпотентний захисний повтор suppression (діє лише
            # на власний маркер цього процесу).
            if ($script:dataRestoreQuiescenceMarkerWritten) {
                try {
                    [void](Set-BRAVOServiceQuiescenceRestartSuppressed)
                } catch {
                    Write-DataRestoreLog -Message "Не вдалося підтвердити suppressed на ownership-маркері: $($_.Exception.Message)" -Level 'WARNING'
                }
            }
        } elseif ($script:dataRestoreServicesStopped -and $null -ne $script:dataRestoreServiceSnapshot) {
            $restoreServicesStartedAt = Get-Date
            $startFailures = Restore-BRAVODataRestoreServices `
                -Snapshot $script:dataRestoreServiceSnapshot `
                -StartTimeoutSeconds $serviceStartTimeoutSeconds `
                -PollIntervalSeconds $servicePollIntervalSeconds
            if (@($startFailures).Count -gt 0) {
                # Дані могли бути відновлені, але production не працює —
                # операційно це невдале відновлення (43), не warning.
                $script:flagRestoreFailed = $true
                if ([string]::IsNullOrWhiteSpace([string]$script:dataRestoreAbortReason)) {
                    $script:dataRestoreAbortReason = ($startFailures -join '; ')
                }
                Write-BRAVOOperationResult -Name 'Відновлення стану служб' -Status 'FAIL' -Duration ((Get-Date) - $restoreServicesStartedAt) -Details ($startFailures -join '; ')
            } else {
                Write-BRAVOOperationResult -Name 'Відновлення стану служб' -Status 'OK' -Duration ((Get-Date) - $restoreServicesStartedAt)
                # Повне відновлення служб — ВЛАСНИЙ ownership-маркер більше
                # не потрібен. Частковий збій вище лишає suppressed-маркер:
                # Health-watchdog НЕ стартуватиме (DataRestore-маркер завжди
                # suppressed), але алертитиме про потребу ручного втручання.
                # Clear захищений: чужий маркер (перетин власників) не
                # видаляється — тоді повертає $false.
                if ($script:dataRestoreQuiescenceMarkerWritten) {
                    try {
                        $quiescenceMarkerCleared = Clear-BRAVOServiceQuiescenceState
                        if (-not $quiescenceMarkerCleared) {
                            Write-DataRestoreLog -Message 'Ownership-маркер зупинки служб не видалено: він уже належить іншому процесу (перетин власників) — залишено без змін' -Level 'WARNING'
                        }
                    } catch {
                        Write-DataRestoreLog -Message "Не вдалося прибрати ownership-маркер зупинки служб: $($_.Exception.Message) — Health-watchdog побачить осиротілий маркер, мовчазної шкоди немає" -Level 'WARNING'
                    }
                }
            }
        }
    }
} finally {
    Exit-BRAVODataRestoreOperationLock
}

# ===== POST-RESTORE HEALTH (лише успішний InPlace) =====
$anyFailure = ($script:flagInternalError -or $script:flagInvalidConfiguration -or
    $script:flagCredentialsUnavailable -or $script:flagIntegrityTestFailed -or
    $script:flagHashValidationFailed -or $script:flagRestoreFailed -or $script:flagSftpFailed)
if ($Mode -eq 'InPlace' -and -not $anyFailure -and -not $SkipHealthCheck) {
    $healthStartedAt = Get-Date
    $script:dataRestoreHealthExitCode = Invoke-BRAVODataRestorePostHealth
    if ($null -eq $script:dataRestoreHealthExitCode) {
        $script:dataRestoreWarningCount++
        Write-BRAVOOperationResult -Name 'Health після відновлення' -Status 'WARN' -Duration ((Get-Date) - $healthStartedAt) -Details 'не вдалося запустити'
    } elseif ([int]$script:dataRestoreHealthExitCode -ne 0) {
        # Ненульовий Health одразу після старту служб — попередження (служби
        # можуть ще прогріватися), НЕ підстава оголошувати відновлення
        # невдалим і не 70: детальна діагностика — у журналі самого Health.
        $script:dataRestoreWarningCount++
        Write-BRAVOOperationResult -Name 'Health після відновлення' -Status 'WARN' -Duration ((Get-Date) - $healthStartedAt) -Details ("код {0} — {1}" -f $script:dataRestoreHealthExitCode, (Get-BRAVOExitCodeName -Code ([int]$script:dataRestoreHealthExitCode)))
    } else {
        Write-BRAVOOperationResult -Name 'Health після відновлення' -Status 'OK' -Duration ((Get-Date) - $healthStartedAt)
    }
}

# ===== КОД ЗАВЕРШЕННЯ + ПІДСУМОК =====
# Код обчислюється ОДИН раз, до друку підсумку — журнал і консоль не можуть
# розійтися (той самий принцип, що Archive/Health/Maintenance).
$dataRestoreExitCode = Resolve-BRAVOExitCode `
    -InternalError:$script:flagInternalError `
    -InvalidConfiguration:$script:flagInvalidConfiguration `
    -CredentialsUnavailable:$script:flagCredentialsUnavailable `
    -IntegrityTestFailed:$script:flagIntegrityTestFailed `
    -HashValidationFailed:$script:flagHashValidationFailed `
    -RestoreFailed:$script:flagRestoreFailed `
    -SftpFailed:$script:flagSftpFailed `
    -HasWarnings:($script:dataRestoreWarningCount -gt 0)

$summaryStatus = if ($dataRestoreExitCode -eq 0) {
    'УСПІШНО'
} elseif ($dataRestoreExitCode -eq 10) {
    'УСПІШНО З ПОПЕРЕДЖЕННЯМИ'
} else {
    'ПОМИЛКА'
}
$summaryStatusColor = switch ($summaryStatus) {
    'УСПІШНО' { [ConsoleColor]::Green }
    'УСПІШНО З ПОПЕРЕДЖЕННЯМИ' { [ConsoleColor]::Yellow }
    default { [ConsoleColor]::Red }
}
Write-BRAVOResultHeader `
    -Status $summaryStatus `
    -StatusColor $summaryStatusColor `
    -ExitCode $dataRestoreExitCode `
    -ExitCodeName (Get-BRAVOExitCodeName -Code $dataRestoreExitCode) `
    -Reason $script:dataRestoreAbortReason
Write-BRAVOResultField -Label 'Режим' -Value $(if ($Mode -eq 'InPlace') { 'InPlace (production)' } else { "OutOfPlace ($TargetPath)" })
Write-BRAVOResultField -Label 'Джерело' -Value $Source
Write-BRAVOResultField -Label 'GenerationId' -Value $(if ([string]::IsNullOrWhiteSpace([string]$script:dataRestoreSelectedGenerationId)) { 'не вибрано' } else { [string]$script:dataRestoreSelectedGenerationId })
Write-BRAVOResultField -Label 'Початок' -Value $script:ScriptStartTime.ToString('yyyy-MM-dd HH:mm:ss')
Write-BRAVOResultField -Label 'Завершення' -Value ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))
Write-BRAVOResultField -Label 'Тривалість' -Value (Format-BRAVODuration -Duration ([DateTime]::Now - $script:ScriptStartTime))
if ($null -ne $script:dataRestoreHealthExitCode) {
    Write-BRAVOResultField -Label 'Health' -Value ("{0} — {1}" -f $script:dataRestoreHealthExitCode, (Get-BRAVOExitCodeName -Code ([int]$script:dataRestoreHealthExitCode)))
}
if (@($script:dataRestoreComponentResults).Count -gt 0) {
    Write-BRAVOResultSection -Title 'Компоненти'
    foreach ($componentResult in $script:dataRestoreComponentResults) {
        $componentStatusText = switch ([string]$componentResult.Status) {
            'RESTORED' { 'ВІДНОВЛЕНО' }
            'ROLLED_BACK' { 'ВІДКОЧЕНО' }
            'ROLLBACK_FAILED' { 'ПОМИЛКА ВІДКАТУ' }
            'FAILED' { 'ПОМИЛКА' }
            default { 'НЕ ВИКОНУВАВСЯ' }
        }
        $componentLine = "  {0}: {1}" -f $componentResult.Component, $componentStatusText
        if ([string]$componentResult.Status -eq 'RESTORED') {
            $componentLine += (" ({0} файлів, {1}) -> {2}" -f $componentResult.FileCount,
                (Format-BRAVOFileSize -Bytes ([long]$componentResult.ByteCount)), $componentResult.TargetDirectory)
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$componentResult.Detail)) {
            $componentLine += (" — {0}" -f $componentResult.Detail)
        }
        Write-BRAVOResultNote -Text $componentLine
    }
}
# Успішно відкочені компоненти сюди НЕ потрапляють: їхню prerestore-копію
# вже повернуто на оригінальне ім'я, і надрукований шлях більше не існує.
# ROLLBACK_FAILED, навпаки, лишається: копія на місці й саме вона потрібна
# для ручного повернення.
$prerestoreDirectories = @($script:dataRestoreComponentResults |
    Where-Object {
        [string]$_.Status -ne 'ROLLED_BACK' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.PrerestoreDirectory)
    } |
    ForEach-Object { [string]$_.PrerestoreDirectory })
$rollbackFailedComponents = @($script:dataRestoreComponentResults |
    Where-Object { [string]$_.Status -eq 'ROLLBACK_FAILED' } |
    ForEach-Object { [string]$_.Component })
if ($prerestoreDirectories.Count -gt 0) {
    Write-BRAVOResultSection -Title 'Prerestore-копії (попередні дані)'
    foreach ($prerestoreDirectory in $prerestoreDirectories) {
        Write-BRAVOResultNote -Text "  $prerestoreDirectory"
    }
    Write-BRAVOResultNote -Text '  Копії не видаляються автоматично: після підтвердження працездатності видаліть їх вручну.'
    if ($rollbackFailedComponents.Count -gt 0) {
        Write-BRAVOResultNote -Text ("  УВАГА: відкат не завершено для {0} — стан цих каталогів не гарантований." -f ($rollbackFailedComponents -join ', '))
        Write-BRAVOResultNote -Text '  Не видаляйте їхні prerestore-копії: поверніть дані вручну за OPERATIONS.md, розділ коду 43.'
    }
}
if ($script:dataRestoreStagingKept -and -not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreStagingGenerationRoot)) {
    Write-BRAVOResultNote -Text ''
    Write-BRAVOResultNote -Text ("Staging збережено для діагностики/повтору: {0}" -f $script:dataRestoreStagingGenerationRoot)
}
if ($Mode -eq 'OutOfPlace' -and $dataRestoreExitCode -le 10) {
    Write-BRAVOResultNote -Text ''
    Write-BRAVOResultNote -Text 'Production-дані не змінювались.'
}
Write-BRAVOResultFooter -LogFile $script:dataRestoreLogFile

# ===== СПОВІЩЕННЯ =====
# none — ніколи; errors_only — відмови/попередження + успішний InPlace
# (production-відновлення заслуговує запису); all — усе.
$notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
if ($notificationMode -ne 'none') {
    $notificationLines = @("Режим: $Mode, джерело: $Source, generation: $($script:dataRestoreSelectedGenerationId)")
    foreach ($componentResult in $script:dataRestoreComponentResults) {
        $notificationLines += ("{0}: {1}{2}" -f $componentResult.Component, $componentResult.Status,
            $(if ([string]::IsNullOrWhiteSpace([string]$componentResult.Detail)) { '' } else { " — $($componentResult.Detail)" }))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:dataRestoreAbortReason)) {
        $notificationLines += "Причина: $script:dataRestoreAbortReason"
    }
    if ($dataRestoreExitCode -ge 20) {
        Send-BRAVODataRestoreNotification `
            -Severity 'CRITICAL' `
            -ResultLines $notificationLines `
            -ActionText 'перевірити журнал відновлення даних.'
    } elseif ($dataRestoreExitCode -eq 10) {
        Send-BRAVODataRestoreNotification `
            -Severity 'WARNING' `
            -ResultLines $notificationLines `
            -ActionText 'переглянути попередження в журналі відновлення даних.'
    } elseif ($Mode -eq 'InPlace' -or $notificationMode -eq 'all') {
        Send-BRAVODataRestoreNotification `
            -Severity 'SUCCESS' `
            -ResultLines $notificationLines
    }
}

Write-DataRestoreLog -Message "Завершення з кодом $dataRestoreExitCode ($(Get-BRAVOExitCodeName -Code $dataRestoreExitCode))" -Level 'INFO'
exit $dataRestoreExitCode

} finally {
    Wait-BRAVOManualExit -NoPause:$NoPause
}
