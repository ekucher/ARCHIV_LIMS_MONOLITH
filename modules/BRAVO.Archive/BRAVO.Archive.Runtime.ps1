##########
# BravoSoft
# Author: Evgeniy Kucher
# Скрипт для архівації та резервного копіювання даних BRAVO/LIMS
# Конфігурація винесена в окремий файл
##########

# Ручна синхронізація лише BAZA на SFTP:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\BRAVO_ARCHIV.ps1" -SyncBAZA -NoPause

param(
    [string]$ConfigPath,
    [switch]$SyncBAZA,
    [switch]$HealthCheckOnly,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$EntryScriptPath
)

$bravoScriptDirectory = $RuntimeRoot

# Спільні PowerShell-модулі runtime.
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveRuntime', 'BRAVO.Logging', 'BRAVO.Console')) {
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
$archiveHelpersPath = Join-Path $bravoScriptDirectory 'modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1'
if (-not (Test-Path -LiteralPath $archiveHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль archive helpers: $archiveHelpersPath"
}
Import-Module -Name $archiveHelpersPath -ErrorAction Stop



# Compatibility forwarding for callers that still use BRAVO_ARCHIV -HealthCheckOnly.
# New callers and Task Scheduler use BRAVO_HEALTH.ps1 directly.
if ($HealthCheckOnly) {
    $healthScriptPath = Join-Path $bravoScriptDirectory 'BRAVO_HEALTH.ps1'
    if (-not (Test-Path -LiteralPath $healthScriptPath -PathType Leaf)) {
        Write-Error "Не знайдено окремий health-скрипт: $healthScriptPath"
        exit 1
    }
    & $healthScriptPath `
        -ConfigPath $ConfigPath `
        -ForceNotification:$ForceNotification `
        -NotifyOnSuccess:$NotifyOnSuccess `
        -NoSlack:$NoSlack `
        -SkipIfBackupTaskRunning:$SkipIfBackupTaskRunning `
        -NoPause:$NoPause
    exit $LASTEXITCODE
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass –Force

# =============================================
# ЗАВАНТАЖЕННЯ КОНФІГУРАЦІЇ
# =============================================

# Перевірка наявності файлу конфігурації
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Host "ПОМИЛКА: Файл конфiгурацiї не знайдено: $ConfigPath" -ForegroundColor Red
    Write-Host "Створiть або налаштуйте файл BRAVO.config поруч зі скриптом." -ForegroundColor Yellow
    Exit 1
}

# Завантаження конфігурації
try {
    $loaderPath = Join-Path `
        -Path $bravoScriptDirectory `
        -ChildPath "BRAVO_CONFIG_LOADER.ps1"

    if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $loaderPath"
    }

    . $loaderPath

    Import-BravoConfiguration `
        -ConfigRoot $bravoScriptDirectory `
        -ConfigPath $ConfigPath

    $configPath = [string]$global:BravoConfigurationMetadata.ConfigPath
    Write-Host "Конфiгурацiю завантажено успiшно: $configPath" -ForegroundColor $logColors.SUCCESS
} catch {
    Write-Host "ПОМИЛКА: Не вдалося завантажити конфiгурацiю: $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}

# Запит на підвищення дозволу виконання скрипта
if ($requireAdministrator) {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    # Планувальник запускає робочі завдання від LocalSystem. У цьому
    # неінтерактивному сеансі UAC/RunAs недоступний, хоча SYSTEM має потрібні
    # системні права, тому не можна намагатися повторно підвищити процес.
    $isLocalSystem = $currentIdentity.User.Value -eq 'S-1-5-18'
    if (!$isLocalSystem -and !$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Потрiбнi права адмiнiстратора. Запит UAC..." -ForegroundColor $logColors.WARNING

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $elevationSettings.PowerShellExecutable
        $processInfo.Arguments = $elevationSettings.ArgumentsTemplate -f $EntryScriptPath, $configPath
        if ($NoPause) {
            $processInfo.Arguments += " -NoPause"
        }
        if ($SyncBAZA) {
            $processInfo.Arguments += " -SyncBAZA"
        }
        $processInfo.Verb = $elevationSettings.Verb
        $processInfo.WindowStyle = $elevationSettings.WindowStyle

        try {
            $elevatedProcess = [System.Diagnostics.Process]::Start($processInfo)
            $elevatedProcess.WaitForExit()
            Exit $elevatedProcess.ExitCode
        } catch {
            Write-Host "UAC запит вiдхилено або сталася помилка: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
            Write-Host "Запустiть PowerShell з правами адмiнiстратора вручну" -ForegroundColor $logColors.WARNING
            Exit 1
        }
    }
}

# =============================================
# ЗАВАНТАЖЕННЯ СЕКРЕТІВ З CREDENTIAL MANAGER
# =============================================

$script:Login = $null
$script:resolvedSftpHost = $null
$script:sftpUrl = $null
$script:logFile = $null
$script:archivePassword = $null
$script:smbCredential = $null
$script:credentialInitializationError = $null
$script:archiveCredentialInitializationError = $null
$script:smbCredentialInitializationError = $null
$script:institutionSettingsInitializationError = $null
$script:notificationWebhookUrl = $null
$script:notificationCredentialInitializationError = $null
$script:notificationProvider = ([string]$bravoSettings.NotificationProvider).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($script:notificationProvider)) {
    $script:notificationProvider = "discord"
}
$script:notificationMode = [string]$bravoSettings.NotificationMode
if ([string]::IsNullOrWhiteSpace($script:notificationMode)) {
    $script:notificationMode = [string]$bravoSettings.SlackMode
}
if ([string]::IsNullOrWhiteSpace($script:notificationMode)) {
    $script:notificationMode = "none"
}
$script:notificationMode = $script:notificationMode.ToLowerInvariant()
$script:notificationRequestTimeoutSeconds = if ($null -ne $bravoSettings.NotificationRequestTimeoutSeconds) {
    [math]::Max(1, [int]$bravoSettings.NotificationRequestTimeoutSeconds)
} else {
    30
}
$sftpCredentialRequired = $SyncBAZA -or
    [bool]$componentSettings.SFTP.ArchiveUpload -or
    [bool]$componentSettings.Synchronization.BAZASFTP -or
    [bool]$componentSettings.Synchronization.BAZAWWWSFTP
$smbCredentialRequired = -not $SyncBAZA -and
    [bool]$componentSettings.SMB.ArchiveCopy
$archiveCredentialRequired = -not $SyncBAZA -and (
    [bool]$componentSettings.Archive.MODEL -or
    [bool]$componentSettings.Archive.BLOG -or
    [bool]$componentSettings.Archive.BRAVOEXCH
)
$institutionSettingsRequired = (
    $null -ne $bravoSettings.InstitutionName -and
    $null -ne $bravoSettings.InstitutionCode -and
    $null -ne $bravoSettings.ArchivePrefix
)
$script:notificationProviderDisplayName = if ($script:notificationProvider -eq "discord") {
    "Discord"
} else {
    "Slack"
}
# -SyncBAZA can emit an alert about objects which will never be uploaded.
# Load its webhook too, but treat a missing webhook as a notification error,
# not as a reason to stop the synchronization itself.
$notificationCredentialRequired = $script:notificationMode -ne "none"
$credentialHelperLoaded = $false

if ($institutionSettingsRequired -or
    $sftpCredentialRequired -or
    $smbCredentialRequired -or
    $archiveCredentialRequired -or
    $notificationCredentialRequired) {
    try {
        if ($null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
            throw "вбудований Credential Manager недоступний"
        }
        $credentialHelperLoaded = $true
    } catch {
        if ($sftpCredentialRequired) {
            $script:credentialInitializationError = $_.Exception.Message
        }
        if ($archiveCredentialRequired) {
            $script:archiveCredentialInitializationError = $_.Exception.Message
        }
        if ($smbCredentialRequired) {
            $script:smbCredentialInitializationError = $_.Exception.Message
        }
        if ($institutionSettingsRequired) {
            $script:institutionSettingsInitializationError = $_.Exception.Message
        }
        if ($notificationCredentialRequired) {
            $script:notificationCredentialInitializationError = $_.Exception.Message
        }
    }
}

if ($credentialHelperLoaded) {
    try {
        [void](Import-BRAVOInstitutionSettings `
            -CredentialSettings $credentialSettings `
            -BravoSettings $bravoSettings)
    } catch {
        Write-Host "ПОМИЛКА: Некоректні локальні параметри установи у Credential Manager: $($_.Exception.Message)" `
            -ForegroundColor $logColors.ERROR
        exit 1
    }
} elseif ($institutionSettingsRequired) {
    Write-Host "ПОМИЛКА: Не вдалося завантажити локальні параметри установи: $($script:institutionSettingsInitializationError)" `
        -ForegroundColor $logColors.ERROR
    exit 1
}

if ($credentialHelperLoaded -and $archiveCredentialRequired) {
    try {
        $archiveCredentialTarget = [string]$credentialSettings.Targets.ArchivePassword
        if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
            $archiveCredentialTarget = "BRAVO_7Z_PASSWORD"
        }
        if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
            throw "не вдалося визначити назву запису Credential Manager для пароля архівів"
        }
        $script:archivePassword = Get-BRAVOCredentialSecret -Target $archiveCredentialTarget
        if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            throw "запис Credential Manager '$archiveCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
    } catch {
        $script:archiveCredentialInitializationError = $_.Exception.Message
    }
}

if ($credentialHelperLoaded -and $sftpCredentialRequired) {
    try {
        $sftpLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
        $sftpPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
        if ([string]::IsNullOrWhiteSpace($sftpLoginTarget)) {
            $sftpLoginTarget = "BRAVO_SFTP_LOGIN"
        }
        if ([string]::IsNullOrWhiteSpace($sftpPasswordTarget)) {
            $sftpPasswordTarget = "BRAVO_SFTP_PASSWORD"
        }

        $storedSftpLogin = Get-BRAVOCredentialSecret -Target $sftpLoginTarget
        $storedSftpPassword = Get-BRAVOCredentialSecret -Target $sftpPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSftpLogin)) {
            throw "запис Credential Manager '$sftpLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ([string]::IsNullOrWhiteSpace($storedSftpPassword)) {
            throw "запис Credential Manager '$sftpPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $script:Login = ([string]$storedSftpLogin).Trim()
        $legacySftpHostVariable = Get-Variable -Name 'sftpHost' -Scope Global -ErrorAction SilentlyContinue
        $configuredSftpHost = if ($null -ne $legacySftpHostVariable) { [string]$legacySftpHostVariable.Value } else { $null }
        $script:resolvedSftpHost = Resolve-BRAVOSftpHostName `
            -UserName $script:Login `
            -HostTemplate ([string]$sftpHostTemplate) `
            -FallbackHostName $configuredSftpHost
        $script:sftpUrl = New-BRAVOSftpUrl `
            -HostName $script:resolvedSftpHost `
            -Port ([int]$sftpPort) `
            -UserName $script:Login `
            -Password ([string]$storedSftpPassword)
        $storedSftpLogin = $null
        $storedSftpPassword = $null
    } catch {
        $script:credentialInitializationError = $_.Exception.Message
    }
}

if ($credentialHelperLoaded -and $smbCredentialRequired) {
    try {
        $smbLoginTarget = [string]$credentialSettings.Targets.SMBLogin
        $smbPasswordTarget = [string]$credentialSettings.Targets.SMBPassword
        if ([string]::IsNullOrWhiteSpace($smbLoginTarget)) {
            $smbLoginTarget = "BRAVO_SMB_LOGIN"
        }
        if ([string]::IsNullOrWhiteSpace($smbPasswordTarget)) {
            $smbPasswordTarget = "BRAVO_SMB_PASSWORD"
        }

        $storedSmbLogin = Get-BRAVOCredentialSecret -Target $smbLoginTarget
        $storedSmbPassword = Get-BRAVOCredentialSecret -Target $smbPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSmbLogin)) {
            throw "запис Credential Manager '$smbLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ([string]::IsNullOrWhiteSpace($storedSmbPassword)) {
            throw "запис Credential Manager '$smbPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $secureSmbPassword = ConvertTo-SecureString -String ([string]$storedSmbPassword) -AsPlainText -Force
        $script:smbCredential = New-Object System.Management.Automation.PSCredential(
            [string]$storedSmbLogin,
            $secureSmbPassword
        )
        $storedSmbLogin = $null
        $storedSmbPassword = $null
        $secureSmbPassword = $null
    } catch {
        $script:smbCredentialInitializationError = $_.Exception.Message
    }
}

if ($credentialHelperLoaded -and $notificationCredentialRequired) {
    try {
        if ($script:notificationProvider -notin @("slack", "discord")) {
            throw "невідомий канал повідомлень: $($script:notificationProvider)"
        }
        $notificationCredentialTarget = if ($script:notificationProvider -eq "discord") {
            [string]$credentialSettings.Targets.DiscordWebhook
        } else {
            [string]$credentialSettings.Targets.SlackWebhook
        }
        if ([string]::IsNullOrWhiteSpace($notificationCredentialTarget)) {
            $notificationCredentialTarget = if ($script:notificationProvider -eq "discord") {
                "BRAVO_DISCORD_URL"
            } else {
                "BRAVO_SLACK_URL"
            }
        }
        $script:notificationWebhookUrl = Get-BRAVOCredentialSecret -Target $notificationCredentialTarget
        if ([string]::IsNullOrWhiteSpace($script:notificationWebhookUrl)) {
            throw "запис Credential Manager '$notificationCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
    } catch {
        $script:notificationCredentialInitializationError = $_.Exception.Message
    }
}

# =============================================
# ІНІЦІАЛІЗАЦІЯ ЗМІННИХ З КОНФІГУРАЦІЇ
# =============================================

# РЕЖИМ СУМІСНОСТІ
$compatibilityMode = $false  # Автоматично визначається нижче

# =============================================
# НАЛАШТУВАННЯ КОНСОЛІ
# =============================================
$configuredOutputEncoding = [System.Text.Encoding]::GetEncoding($consoleSettings.OutputEncodingCodePage)
$global:OutputEncoding = $configuredOutputEncoding
try {
    [Console]::OutputEncoding = $configuredOutputEncoding
} catch {
    # Деякі PowerShell-hosts і запуски через Task Scheduler не мають
    # дійсного консольного дескриптора. Кодування зовнішніх команд уже
    # налаштовано через $OutputEncoding, тому роботу можна продовжити.
}
try {
    $Host.UI.RawUI.WindowTitle = $consoleSettings.WindowTitleTemplate -f $ScriptVersion
    $Host.UI.RawUI.BackgroundColor = $consoleSettings.BackgroundColor
    $Host.UI.RawUI.ForegroundColor = $consoleSettings.ForegroundColor
} catch {
    # RawUI може бути недоступним у неінтерактивному PowerShell-host.
}
if ($consoleSettings.ClearOnStart) {
    try {
        Clear-Host
    } catch {
        # Очищення екрана не є обов'язковим для роботи скрипта.
    }
}

# =============================================
# ФУНКЦІЇ ПЕРЕВІРКИ СУМІСНОСТІ
# =============================================

function Test-Compatibility {
    Write-Log "Перевiрка сумiсностi системи..." -Level "INFO"
    $compatibility = Get-BRAVOCompatibilityInfo
    $powerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
    $script:BRAVOCompatibility = $compatibility
    $script:BRAVOPowerShellUpdate = $powerShellUpdate

    $script:hasFileHash = $compatibility.FileHashProvider -eq "Get-FileHash"
    $script:hasNetConnection = $compatibility.NetworkProvider -eq "Test-NetConnection"
    $script:compatibilityMode = [bool]$compatibility.IsCompatibilityMode

    Write-Log "Windows: $($BRAVOCompatibility.WindowsVersion); PowerShell: $($BRAVOCompatibility.PowerShellVersion)" -Level "DEBUG"
    Write-Log "WMI: $($BRAVOCompatibility.WmiProvider); Hash: $($BRAVOCompatibility.FileHashProvider); Network: $($BRAVOCompatibility.NetworkProvider); Files: $($BRAVOCompatibility.ChildItemProvider)" -Level "DEBUG"

    if ($script:compatibilityMode) {
        Write-Log "Режим сумiсностi активний: несумiснi сучаснi API буде автоматично замiнено" -Level "INFO"
    } else {
        Write-Log "Стандартний режим" -Level "INFO"
    }
    if ($powerShellUpdate.IsUpdateRecommended) {
        Write-Log $powerShellUpdate.Message -Level "WARNING"
    }

    return $compatibility
}

function New-SHA512HashLegacy {
    param(
        [string]$FilePath,
        [string]$HashFilePath
    )
    
    Write-Log "Створення SHA512 хешу (сумiсний режим): $(Split-Path $FilePath -Leaf)"
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Файл не знайдено: $FilePath" -Level "ERROR"
        return $false
    }
    
    try {
        # Використовуємо .NET для створення хешу в сумiсному режимi
        $fileStream = [System.IO.File]::OpenRead($FilePath)
        $hasher = [System.Security.Cryptography.SHA512]::Create()
        $hashBytes = $hasher.ComputeHash($fileStream)
        $fileStream.Close()
        
        # Конвертуємо байти в hex-рядок
        $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
        $fileName = (Get-Item $FilePath).Name
        
        # Виправлення для PowerShell 3.0: використовуємо .NET метод замiсть Out-File з -NoNewline
        [System.IO.File]::WriteAllText($HashFilePath, "${hash} *${fileName}", [System.Text.Encoding]::GetEncoding($hashFileEncoding))
        
        Write-Log "Хеш створено (сумiсний режим): $HashFilePath" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Помилка створення хешу (сумiсний режим): $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($hasher) { $hasher.Dispose() }
    }
}

function Test-NetworkConnectionLegacy {
    try {
        Write-Log "Перевiрка мережевого з'єднання (сумiсний режим)..." -Level "DEBUG"
        
        # Альтернативнi методи перевiрки мережi
        $ping = New-Object System.Net.NetworkInformation.Ping
        $result = $ping.Send($networkCheckHost, $networkPingTimeoutMilliseconds)
        
        if ($result.Status -eq "Success") {
            Write-Log "Мережеве з'єднання доступне (сумiсний режим)" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Мережеве з'єднання недоступне (сумiсний режим)" -Level "ERROR"
            return $false
        }
    } catch {
        Write-Log "Помилка перевiрки мережевого з'єднання (сумiсний режим): $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# =============================================
# ДОПОМІЖНІ ФУНКЦІЇ
# =============================================

# Поточний компонент журналу. Секції головного потоку виставляють його, щоб
# записи потрапляли у правильну колонку [COMPONENT] без правки кожного виклику.
$script:BRAVOLogComponent = 'ARCHIVE'

function Set-BRAVOLogComponent {
    param([Parameter(Mandatory = $true)][string]$Component)

    $script:BRAVOLogComponent = $Component
}

# Тимчасовий шим сумісності зі старим Write-Log. Делегує у BRAVO.Logging,
# який сам вирішує, що потрапить у файл, а що — в консоль.
# Прибрати, коли всі виклики перейдуть на Write-BRAVOLog напряму.
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = $defaultLogLevel,
        [int]$SeparatorLength = $logSeparatorLength,
        [switch]$NoTimestamp,
        [switch]$FileOnly
    )

    $component = $script:BRAVOLogComponent

    # Роздільники й заголовки формували структуру старої консолі. Тепер її
    # задають етапи (Write-BRAVOStepResult), тому в консоль вони не йдуть,
    # але лишаються в журналі, щоб хронологія читалася як раніше.
    if ($Message -eq "=" -or $Message -eq "===") {
        Write-BRAVOLog `
            -Message ("=" * $SeparatorLength) `
            -Level 'INFO' `
            -Component $component `
            -NoConsole
        return
    }
    if ($Message -match "^=== .* ===$") {
        Write-BRAVOLog -Message $Message -Level 'INFO' -Component $component -NoConsole
        return
    }

    $normalizedLevel = if ([string]::IsNullOrWhiteSpace($Level)) {
        'INFO'
    } else {
        $Level.Trim().ToUpperInvariant()
    }
    if (@('TRACE', 'DEBUG', 'INFO', 'SUCCESS', 'WARNING', 'ERROR', 'FATAL') -notcontains $normalizedLevel) {
        $normalizedLevel = 'INFO'
    }

    if ($FileOnly) {
        Write-BRAVOLog -Message $Message -Level $normalizedLevel -Component $component -NoConsole
        return
    }
    Write-BRAVOLog -Message $Message -Level $normalizedLevel -Component $component
}

function Show-ScriptProgress {
    param(
        [string]$Status,
        [int]$PercentComplete = 0,
        [switch]$Completed
    )

    if (-not $progressSettings.Enabled -or -not $progressSettings.ShowOverallProgress) {
        return
    }

    if ($Completed) {
        Write-Progress -Id 1 -Activity $progressSettings.Activity -Completed
        return
    }

    $safePercent = [Math]::Max(0, [Math]::Min(100, $PercentComplete))
    Write-Progress -Id 1 -Activity $progressSettings.Activity -Status $Status -PercentComplete $safePercent
}

function Show-ItemProgress {
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Item,
        [int]$Current,
        [int]$Total,
        [switch]$Completed
    )

    if (-not $progressSettings.Enabled) {
        return
    }

    if ($Completed) {
        Write-Progress -Id $Id -Activity $Activity -Completed
        return
    }

    $safeTotal = [Math]::Max(1, $Total)
    $safeCurrent = [Math]::Max(0, [Math]::Min($safeTotal, $Current))
    $percent = [Math]::Floor(($safeCurrent * 100.0) / $safeTotal)
    $progressArguments = @{
        Id = $Id
        Activity = $Activity
        Status = "$Item ($safeCurrent з $safeTotal)"
        PercentComplete = $percent
    }
    if ($progressSettings.ShowOverallProgress) {
        $progressArguments.ParentId = 1
    }

    Write-Progress @progressArguments
}

function Show-RunningProgress {
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = -1,
        [switch]$Completed
    )

    if (-not $progressSettings.Enabled) {
        return
    }

    if ($Completed) {
        Write-Progress -Id $Id -Activity $Activity -Completed
        return
    }

    $safePercent = if ($PercentComplete -lt 0) {
        -1
    } else {
        [Math]::Max(0, [Math]::Min(100, $PercentComplete))
    }
    $progressArguments = @{
        Id = $Id
        Activity = $Activity
        Status = $Status
        PercentComplete = $safePercent
    }
    if ($progressSettings.ShowOverallProgress) {
        $progressArguments.ParentId = 1
    }

    Write-Progress @progressArguments
}

function Wait-ForManualExit {
    if ($NoPause -or -not $consoleSettings.PauseOnExit) {
        return
    }

    $prompt = [string]$consoleSettings.PausePrompt
    if ([string]::IsNullOrWhiteSpace($prompt)) {
        $prompt = "Натиснiть будь-яку клавiшу для закриття вiкна..."
    }

    Write-Host ""
    Write-Host $prompt -ForegroundColor $logColors.Progress
    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        # У хостах без RawUI очікуємо Enter; для -NonInteractive помилку ігноруємо.
        try {
            [void](Read-Host)
        } catch {
            Write-Log "Пауза завершення недоступна у цьому режимi PowerShell" -Level "DEBUG"
        }
    }
}

function Test-PathWithLog {
    param(
        [string]$Path,
        [string]$Description,
        [bool]$CreateIfMissing = $false
    )

    if (Test-Path $Path) {
        Write-Log "$Description знайдено: $Path" -Level "DEBUG"
        return $true
    } else {
        # Створення дозволяється лише для явно позначених каталогів призначення.
        if ($CreateIfMissing) {
            try {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
                Write-Log "$Description не знайдено, створено автоматично: $Path" -Level "SUCCESS"
                return $true
            } catch {
                Write-Log "$Description не знайдено i не вдалося створити: $Path" -Level "ERROR"
                return $false
            }
        } else {
            Write-Log "$Description не знайдено: $Path" -Level "ERROR"
            return $false
        }
    }
}

function Show-PathCheckSummary {
    param(
        [array]$CheckedPaths,
        [bool]$AllPathsExist
    )
    
    if ($AllPathsExist) {
        Write-Log "Всi необхiднi шляхи перевiрено успiшно" -Level "SUCCESS"
    } else {
        Write-Log "Знайдено помилки в шляхах - див. вище" -Level "ERROR"
    }
}

function Show-ArchiveCleanupSection {
    param([ref]$SectionShown)

    if (-not $SectionShown.Value) {
        Write-Log "==="
        Write-Log "=== ОЧИЩЕННЯ СТАРИХ АРХIВIВ ==="
        Show-ScriptProgress -Status "Очищення старих архiвiв" -PercentComplete 72
        $SectionShown.Value = $true
    }
}

function Remove-OldBackupSets {
    param(
        [string]$Path,
        [int]$RetentionDays,
        [string]$Component,
        [ref]$CleanupSectionShown
    )

    $failedArchiveDeletionEnabled = ($null -eq $enableFailedArchiveDeletion) -or [bool]$enableFailedArchiveDeletion
    if (-not $enableArchiveDeletion -and -not $failedArchiveDeletionEnabled) {
        return $true
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Log "Шлях архівів не знайдено: $Path" -Level "WARNING"
        return $false
    }

    try {
        $invalidRetentionDays = if ($null -ne $failedArchiveRetentionDays) {
            [math]::Max(1, [int]$failedArchiveRetentionDays)
        } else {
            30
        }
        $invalidCutoff = (Get-Date).AddDays(-$invalidRetentionDays)
        # Захист для старих конфігів без archiveRetentionDays: ніколи не
        # зменшуємо строк зберігання до одного дня через значення $null/0.
        $validRetentionDays = if ($RetentionDays -gt 0) {
            [int]$RetentionDays
        } else {
            183
        }
        $validCutoff = (Get-Date).AddDays(-$validRetentionDays)
        $validSets = @()
        foreach ($archive in @(Get-BRAVOFiles -Path $Path -Filter $archiveFileFilter)) {
            $hashPath = "$($archive.FullName)$hashFileExtension"
            $setValid = $false
            $invalidReason = ""
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
                $actualHash = (Get-BRAVOFileHash -Path $archive.FullName -Algorithm SHA512).Hash.ToUpperInvariant()
                if ($actualHash -cne $expectedHash) {
                    throw "SHA512 не збігається"
                }
                $setValid = $true
            } catch {
                $invalidReason = $_.Exception.Message
            }

            if ($setValid) {
                $validSets += [pscustomobject]@{
                    Archive = $archive
                    HashPath = $hashPath
                }
            } elseif ($failedArchiveDeletionEnabled -and $archive.LastWriteTime -lt $invalidCutoff) {
                Show-ArchiveCleanupSection -SectionShown $CleanupSectionShown
                Write-Log "Видалення непридатного комплекту ${Component}, старшого за $invalidRetentionDays днів: $($archive.Name) — $invalidReason" -Level "WARNING"
                Remove-Item -LiteralPath $archive.FullName -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
                    Remove-Item -LiteralPath $hashPath -Force -ErrorAction Stop
                }
            } else {
                Write-Log "Непридатний комплект збережено для діагностики: $($archive.Name) — $invalidReason" -Level "WARNING"
            }
        }
        $validSets = @($validSets | Sort-Object { $_.Archive.LastWriteTime } -Descending)

        foreach ($orphanHash in @(Get-BRAVOFiles -Path $Path -Filter "*$hashFileExtension")) {
            $archivePath = $orphanHash.FullName.Substring(0, $orphanHash.FullName.Length - $hashFileExtension.Length)
            if ($failedArchiveDeletionEnabled -and
                -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -and
                $orphanHash.LastWriteTime -lt $invalidCutoff) {
                Show-ArchiveCleanupSection -SectionShown $CleanupSectionShown
                Remove-Item -LiteralPath $orphanHash.FullName -Force -ErrorAction Stop
                Write-Log "Видалено застарілий hash-файл без архіву: $($orphanHash.Name)" -Level "WARNING"
            }
        }

        if (-not $enableArchiveDeletion) {
            return $true
        }

        # Зберігання коректних комплектів визначається календарним віком, а не
        # кількістю запусків: додатковий ручний бекап не скорочує строк зберігання.
        $setsToDelete = @($validSets | Where-Object {
            $_.Archive.LastWriteTime -lt $validCutoff
        })
        foreach ($set in $setsToDelete) {
            Show-ArchiveCleanupSection -SectionShown $CleanupSectionShown
            # Спочатку видаляється великий архів. Якщо видалення hash-файлу
            # не вдасться, залишиться лише безпечний сирота, а не архів без hash.
            Remove-Item -LiteralPath $set.Archive.FullName -Force -ErrorAction Stop
            try {
                Remove-Item -LiteralPath $set.HashPath -Force -ErrorAction Stop
            } catch {
                Write-Log "Архів видалено, але не вдалося видалити його hash-файл $($set.HashPath): $($_.Exception.Message)" -Level "WARNING"
            }
            Write-Log "Видалено комплект ${Component}, старший за $validRetentionDays днів: $($set.Archive.Name)" -Level "SUCCESS"
        }
        return $true
    } catch {
        Write-Log "Помилка очищення комплектів ${Component}: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Remove-OldLunchArchives {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string[]]$Directories,
        [int]$RetentionMonths = 2
    )

    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
        Write-Log "Каталог обідніх архівів не знайдено: $ArchiveRoot" -Level "ERROR"
        return $false
    }

    $resolvedArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
    $effectiveRetentionMonths = [Math]::Max(1, $RetentionMonths)
    $cutoff = (Get-Date).AddMonths(-$effectiveRetentionMonths)
    $failed = $false
    $deletedCount = 0

    Write-Log "==="
    Write-Log "=== ОЧИЩЕННЯ СТАРИХ ОБІДНІХ АРХІВІВ ==="
    Write-Log "Дата відсічення: $cutoff; маркер імені: _1300." -Level "INFO"

    foreach ($directory in @($Directories | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })) {
        $directoryPath = Join-Path -Path $resolvedArchiveRoot -ChildPath $directory
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            Write-Log "Каталог обідніх архівів не знайдено: $directoryPath" -Level "WARNING"
            $failed = $true
            continue
        }
        $resolvedDirectoryPath = (Resolve-Path -LiteralPath $directoryPath -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
        $archiveRootPrefix = $resolvedArchiveRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedDirectoryPath.StartsWith($archiveRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "Небезпечний каталог очищення поза ArchiveRoot пропущено: $directory" -Level "ERROR"
            $failed = $true
            continue
        }

        $directoryDeletedCount = 0
        $archiveSets = @{}
        foreach ($file in @(Get-BRAVOFiles -LiteralPath $resolvedDirectoryPath -Filter "*_1300.*")) {
            $setName = if ($file.Name -like "*.mdz.sha512") {
                $file.Name.Substring(0, $file.Name.Length - ".sha512".Length)
            } elseif ($file.Name -like "*.mdz") {
                $file.Name
            } else {
                continue
            }
            if (-not $archiveSets.ContainsKey($setName)) {
                $archiveSets[$setName] = @{}
            }
            if ($file.Name -like "*.mdz.sha512") {
                $archiveSets[$setName].Hash = $file
            } else {
                $archiveSets[$setName].Archive = $file
            }
        }

        foreach ($setName in @($archiveSets.Keys | Sort-Object)) {
            $archiveSet = $archiveSets[$setName]
            if (-not $archiveSet.ContainsKey("Archive") -or -not $archiveSet.ContainsKey("Hash")) {
                Write-Log "Неповний обідній комплект залишено без змін: $setName" -Level "WARNING"
                continue
            }
            $setLastWriteTime = (@(
                $archiveSet.Archive.LastWriteTime,
                $archiveSet.Hash.LastWriteTime
            ) | Measure-Object -Maximum).Maximum
            if ($setLastWriteTime -ge $cutoff) {
                continue
            }
            try {
                Remove-Item -LiteralPath $archiveSet.Archive.FullName -Force -ErrorAction Stop
                Remove-Item -LiteralPath $archiveSet.Hash.FullName -Force -ErrorAction Stop
                $directoryDeletedCount += 2
                $deletedCount += 2
                Write-Log "Видалено обідній комплект: $setName і $($archiveSet.Hash.Name)" -Level "SUCCESS"
            } catch {
                $failed = $true
                Write-Log "Не вдалося видалити обідній комплект ${setName}: $($_.Exception.Message)" -Level "ERROR"
            }
        }

        Write-Log "Каталог ${directory}: видалено $directoryDeletedCount обідніх файлів" -Level "INFO"
    }

    Write-Log "Усього видалено обідніх файлів: $deletedCount" -Level "INFO"
    return (-not $failed)
}



function Sync-Folders {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    
    Write-Log "Синхронiзацiя: $SourcePath -> $DestinationPath"
    
    if (-not (Test-Path $SourcePath)) {
        Write-Log "Джерельна папка не знайдена: $SourcePath" -Level "ERROR"
        return $false
    }
    
    try {
        # Створюємо цільову папку, якщо не існує
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Write-Log "Створено цiльову папку: $DestinationPath" -Level "SUCCESS"
        }
        
        # Виконуємо синхронізацію за допомогою Robocopy
        $effectiveRobocopyOptions = @($robocopyOptions)
        $showRobocopyProgress = $progressSettings.Enabled -and $progressSettings.ShowRobocopyOutput

        if ($showRobocopyProgress) {
            # /NP приховує відсотки, тому прибираємо його лише для режиму прогресу.
            $effectiveRobocopyOptions = @($effectiveRobocopyOptions | Where-Object { $_ -ine "/NP" })
            foreach ($progressOption in @($progressSettings.RobocopyProgressOptions)) {
                if (-not [string]::IsNullOrWhiteSpace($progressOption) -and
                    -not ($effectiveRobocopyOptions -icontains $progressOption)) {
                    $effectiveRobocopyOptions += $progressOption
                }
            }
        }

        $robocopyArgs = @("`"$SourcePath`"", "`"$DestinationPath`"") + $effectiveRobocopyOptions
        
        Write-Log "Виконання: robocopy $robocopyArgs" -Level "DEBUG"

        if ($showRobocopyProgress) {
            # Локалізований текст Robocopy використовує OEM-кодування і в деяких
            # PowerShell-hosts відображається пошкодженим. Вивід спрямовується у
            # NUL, а скрипт показує власний незалежний індикатор виконання.
            $progressRobocopyArgs = @($robocopyArgs) + @("/LOG:NUL")
            $process = Start-Process `
                -FilePath $robocopyPath `
                -ArgumentList $progressRobocopyArgs `
                -PassThru `
                -WindowStyle $robocopyWindowStyle
            $robocopyStarted = Get-Date
            do {
                $process.Refresh()
                $elapsed = [math]::Floor(((Get-Date) - $robocopyStarted).TotalSeconds)
                Show-RunningProgress `
                    -Id 3 `
                    -Activity "Robocopy — синхронiзацiя BAZA" `
                    -Status "Виконується, минуло $elapsed сек." `
                    -PercentComplete -1
                if (-not $process.HasExited) {
                    Start-Sleep -Milliseconds 500
                }
            } while (-not $process.HasExited)
            $process.WaitForExit()
            Show-RunningProgress -Id 3 -Activity "Robocopy — синхронiзацiя BAZA" -Completed
            $exitCode = $process.ExitCode
        } else {
            $process = Start-Process -FilePath $robocopyPath -ArgumentList $robocopyArgs -Wait -PassThru -WindowStyle $robocopyWindowStyle
            $exitCode = $process.ExitCode
        }
        
        # Коди виходу Robocopy: 0-7 = успіх, 8+ = помилка
        if ($exitCode -le $robocopyMaxSuccessExitCode) {
            Write-Log "Синхронiзацiя успiшна (код: $exitCode)" -Level "DEBUG"
            return $true
        } else {
            Write-Log "Помилка синхронiзацiї (код: $exitCode)" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Помилка синхронiзацiї: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# =============================================
# ФУНКЦІЇ АРХІВАЦІЇ
# =============================================



function Write-SevenZipFailureDiagnostics {
    param([string]$Operation, [string]$StandardOutput, [string]$StandardError)
    foreach ($line in @($StandardOutput, $StandardError)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log "${Operation}: $($line.Trim().Substring(0, [math]::Min(4000, $line.Trim().Length)))" -Level 'DEBUG'
        }
    }
}

function Get-BRAVOVSSSnapshotSourcePath {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DeviceObject
    )

    $normalizedSourcePath = $SourcePath.Replace("/", "\")
    $volumeRoot = [IO.Path]::GetPathRoot($normalizedSourcePath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        $volumeRoot -notmatch '^[A-Za-z]:\\$') {
        throw "VSS підтримує лише локальний шлях із літерою диска: $SourcePath"
    }
    if ([string]::IsNullOrWhiteSpace($DeviceObject)) {
        throw "VSS не повернув шлях DeviceObject для джерела: $SourcePath"
    }

    $snapshotRoot = $DeviceObject.TrimEnd([char[]]"\/")
    $relativePath = $normalizedSourcePath.Substring($volumeRoot.Length).TrimStart([char[]]"\/")
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return "$snapshotRoot\"
    }
    return "$snapshotRoot\$relativePath"
}

function Get-BRAVOVSSReturnCodeDescription {
    param([int]$ReturnCode)

    $descriptions = @{
        0 = "успішно"
        1 = "доступ заборонено"
        2 = "некоректний аргумент"
        3 = "том не знайдено"
        4 = "том не підтримує VSS"
        5 = "контекст VSS не підтримується"
        6 = "недостатньо місця для shadow copy"
        7 = "том зайнятий"
        8 = "досягнуто максимальну кількість shadow copies"
        9 = "вже виконується інша операція shadow copy"
        10 = "VSS provider відхилив операцію"
        11 = "VSS provider не зареєстрований"
        12 = "помилка VSS provider"
        13 = "невідома помилка VSS"
    }
    if ($descriptions.ContainsKey($ReturnCode)) {
        return $descriptions[$ReturnCode]
    }
    return "невідома помилка VSS"
}

function New-BRAVOVSSSnapshotLink {
    param([Parameter(Mandatory = $true)][string]$DeviceObject)

    # .NET/PowerShell (Test-Path, Get-ChildItem, 7-Zip тощо) не вміють
    # напряму читати "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN\" —
    # це не звичайний шлях файлової системи. Каталогове симлінк-посилання
    # (той самий прийом, що й diskshadow.exe EXPOSE) робить вміст знімка
    # доступним через звичайний шлях.
    $linkPath = Join-Path ([System.IO.Path]::GetTempPath()) ("BRAVO_VSS_" + [guid]::NewGuid().ToString("N"))
    $target = $DeviceObject.TrimEnd("\", "/") + "\"

    $mklinkOutput = & cmd.exe /c mklink /d $linkPath $target 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $linkPath)) {
        throw "Не вдалося створити символiчне посилання на VSS-знiмок ($target): $mklinkOutput"
    }
    return $linkPath
}

function Remove-BRAVOVSSSnapshotLink {
    param([string]$LinkPath)

    if ([string]::IsNullOrWhiteSpace($LinkPath)) {
        return
    }
    # Directory.Delete(recursive=$false) знімає лише сам reparse-point і не
    # торкається вмісту знімка. Перевірка через Test-Path тут не годиться:
    # для висячого посилання (знімок уже зник) вона дає $false, і сміттєвий
    # каталог залишався б у %TEMP% назавжди.
    try {
        [System.IO.Directory]::Delete($LinkPath, $false)
    } catch [System.IO.DirectoryNotFoundException] {
        # Посилання вже прибрано — нічого робити.
    } catch {
        Write-Log "Не вдалося прибрати символiчне посилання на VSS-знiмок: $LinkPath ($($_.Exception.Message))" -Level "WARNING"
    }
}

function New-BRAVOVSSSnapshot {
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    $normalizedSourcePath = $SourcePath.Replace("/", "\")
    $volumeRoot = [IO.Path]::GetPathRoot($normalizedSourcePath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        $volumeRoot -notmatch '^[A-Za-z]:\\$') {
        throw "Не вдалося визначити локальний том VSS для джерела: $SourcePath"
    }

    $snapshotContext = [string]$backupConsistency.SnapshotContext
    if ([string]::IsNullOrWhiteSpace($snapshotContext)) {
        $snapshotContext = "ClientAccessible"
    }

    $shadowId = $null
    $snapshotLinkPath = $null
    try {
        Write-Log "Створення VSS-знімка тому $volumeRoot для узгодженої архівації" -Level "INFO"
        $shadowClass = [wmiclass]"\\.\root\cimv2:Win32_ShadowCopy"
        $createResult = $shadowClass.Create($volumeRoot, $snapshotContext)
        if ($null -eq $createResult) {
            throw "Win32_ShadowCopy.Create не повернув результат"
        }

        $returnCode = [int]$createResult.ReturnValue
        if ($returnCode -ne 0) {
            $description = Get-BRAVOVSSReturnCodeDescription -ReturnCode $returnCode
            throw "Win32_ShadowCopy.Create повернув код $returnCode ($description)"
        }

        $shadowId = [string]$createResult.ShadowID
        if ([string]::IsNullOrWhiteSpace($shadowId)) {
            throw "VSS не повернув ідентифікатор створеного знімка"
        }

        $escapedShadowId = $shadowId.Replace("'", "''")
        $shadow = Get-WmiObject `
            -Namespace "root\cimv2" `
            -Class "Win32_ShadowCopy" `
            -Filter ("ID='{0}'" -f $escapedShadowId) `
            -ErrorAction Stop |
            Select-Object -First 1
        if ($null -eq $shadow -or [string]::IsNullOrWhiteSpace([string]$shadow.DeviceObject)) {
            throw "створений VSS-знімок $shadowId не знайдено"
        }

        $snapshotLinkPath = New-BRAVOVSSSnapshotLink -DeviceObject ([string]$shadow.DeviceObject)
        $snapshotSourcePath = Get-BRAVOVSSSnapshotSourcePath `
            -SourcePath $SourcePath `
            -DeviceObject $snapshotLinkPath
        Write-Log "VSS-знімок створено: $shadowId" -Level "SUCCESS"
        return [pscustomobject]@{
            Id = $shadowId
            VolumeRoot = $volumeRoot
            DeviceObject = [string]$shadow.DeviceObject
            LinkPath = $snapshotLinkPath
            SourcePath = $snapshotSourcePath
            WmiObject = $shadow
        }
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($snapshotLinkPath)) {
            try {
                Remove-BRAVOVSSSnapshotLink -LinkPath $snapshotLinkPath
            } catch {
                # Основна помилка створення VSS важливіша за помилку best-effort cleanup.
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($shadowId)) {
            try {
                $escapedShadowId = $shadowId.Replace("'", "''")
                $orphanedShadow = Get-WmiObject `
                    -Namespace "root\cimv2" `
                    -Class "Win32_ShadowCopy" `
                    -Filter ("ID='{0}'" -f $escapedShadowId) `
                    -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($null -ne $orphanedShadow) {
                    $null = $orphanedShadow.Delete()
                }
            } catch {
                # Основна помилка створення VSS важливіша за помилку best-effort cleanup.
            }
        }
        throw
    }
}

function Remove-BRAVOVSSSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    try {
        Remove-BRAVOVSSSnapshotLink -LinkPath $Snapshot.LinkPath
    } catch {
        Write-Log "Не вдалося прибрати символiчне посилання на VSS-знiмок $($Snapshot.Id): $($_.Exception.Message)" -Level "WARNING"
    }

    try {
        $deleteResult = $Snapshot.WmiObject.Delete()
        if ($null -ne $deleteResult -and [int]$deleteResult.ReturnValue -ne 0) {
            $returnCode = [int]$deleteResult.ReturnValue
            $description = Get-BRAVOVSSReturnCodeDescription -ReturnCode $returnCode
            Write-Log "Не вдалося видалити VSS-знімок $($Snapshot.Id): код $returnCode ($description)" -Level "ERROR"
            return $false
        }
        Write-Log "VSS-знімок видалено: $($Snapshot.Id)" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Не вдалося видалити VSS-знімок $($Snapshot.Id): $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function New-Archive {
    param(
        [string]$SourcePath,
        [string]$ArchivePath,
        [string]$ArchiveName,
        [string]$ArcPath,
        [string]$ArcParams
    )
    
    Write-Log "Створення архiву: $ArchiveName"
    
    $archiveDir = Split-Path $ArchivePath -Parent
    if (-not (Test-Path $archiveDir)) {
        try {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
            Write-Log "Каталог створено: $archiveDir" -Level "SUCCESS"
        } catch {
            Write-Log "Помилка при створеннi каталогу: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }
    
    if (-not (Test-Path $SourcePath)) {
        Write-Log "Джерело не знайдено: $SourcePath" -Level "ERROR"
        return $false
    }
    
    $fullArchivePath = Join-Path $ArchivePath $ArchiveName
    
    try {
        if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            Write-Log "Пароль архiву не завантажено з Windows Credential Manager" -Level "ERROR"
            return $false
        }
        if ($script:archivePassword.IndexOfAny([char[]]"`r`n") -ge 0) {
            Write-Log "Пароль архiву не може мiстити символи нового рядка" -Level "ERROR"
            return $false
        }

        $effectiveArcParams = $ArcParams
        $showSevenZipProgress = $progressSettings.Enabled -and $progressSettings.ShowSevenZipOutput
        $integrityTestTimeoutSeconds = if (
            $null -ne $progressSettings.SevenZipTestTimeoutSeconds
        ) {
            [math]::Max(0, [int]$progressSettings.SevenZipTestTimeoutSeconds)
        } else {
            43200
        }

        $staleHashPath = "$fullArchivePath$hashFileExtension"
        if (Test-Path -LiteralPath $staleHashPath -PathType Leaf) {
            Remove-Item -LiteralPath $staleHashPath -Force -ErrorAction Stop
            Write-Log "Видалено попереднiй hash-файл перед повторним створенням архiву: $staleHashPath" -Level "WARNING"
        }

        # -p без значення вмикає шифрування і читає пароль зі stdin.
        $arguments = "$effectiveArcParams -p `"$fullArchivePath`" `"$SourcePath`""
        Write-Log "Команда: $ArcPath $arguments (пароль передається через stdin)" -Level "DEBUG"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $ArcPath
        $processInfo.Arguments = $arguments
        $processInfo.RedirectStandardInput = $true
        # Потоки завжди перенаправляються, щоб технічний вивід 7-Zip не
        # дублював журнал. Власний індикатор показує час і поточний розмір.
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        # Сучасні ОС використовують ReadToEndAsync, Windows 7/.NET 4.0 —
        # сумісний подієвий механізм зі спільного модуля.
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $process.StandardInput.WriteLine($script:archivePassword)
        $process.StandardInput.Close()
        $sevenZipProgressId = 2
        $progressActivity = "7-Zip — $ArchiveName"
        $archiveStarted = Get-Date
        $archiveTimeoutSeconds = if ($null -ne $progressSettings.SevenZipTimeoutSeconds) {
            [math]::Max(0, [int]$progressSettings.SevenZipTimeoutSeconds)
        } else {
            43200
        }
        $archiveTimedOut = $false

        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $archiveStarted).TotalSeconds)
            if ($showSevenZipProgress) {
                $currentSizeText = "очiкування створення файла"
                if (Test-Path -LiteralPath $fullArchivePath -PathType Leaf) {
                    $currentArchiveLength = (Get-Item -LiteralPath $fullArchivePath).Length
                    $currentSizeText = "поточний розмiр: {0:N1} МБ" -f ($currentArchiveLength / 1MB)
                }
                Show-RunningProgress `
                    -Id $sevenZipProgressId `
                    -Activity $progressActivity `
                    -Status "Виконується $elapsedSeconds сек.; $currentSizeText" `
                    -PercentComplete -1
            }

            if ($archiveTimeoutSeconds -gt 0 -and $elapsedSeconds -ge $archiveTimeoutSeconds) {
                $archiveTimedOut = $true
                try {
                    $process.Kill()
                } catch {
                    # Процес міг завершитися між перевіркою таймауту та Kill().
                }
                break
            }
        }

        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "7-Zip не завершився протягом 5 секунд після спроби примусового завершення"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $standardOutput = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        if ($showSevenZipProgress) {
            Show-RunningProgress -Id $sevenZipProgressId -Activity $progressActivity -Completed
        }
        $lastSevenZipOutput = @($standardOutput -split "\r?\n" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Last 1)

        if ($archiveTimedOut) {
            Write-Log "Архiвацiю перервано: перевищено таймаут $archiveTimeoutSeconds сек.: $ArchiveName" -Level "ERROR"
            if (Test-Path -LiteralPath $fullArchivePath -PathType Leaf) {
                Remove-Item -LiteralPath $fullArchivePath -Force -ErrorAction SilentlyContinue
                Write-Log "Неповний архiв видалено: $fullArchivePath" -Level "WARNING"
            }
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Архiв створено; виконується контроль цiлiсностi: $fullArchivePath" -Level "INFO"
            if (Test-SevenZipArchiveIntegrity `
                -SevenZipPath $ArcPath `
                -ArchivePath $fullArchivePath `
                -Password $script:archivePassword `
                -TimeoutSeconds $integrityTestTimeoutSeconds `
                -Logger { param($Message, $Level) Write-Log $Message -Level $Level }) {
                Write-Log "Архiв створено та перевiрено: $fullArchivePath" -Level "SUCCESS"
                return $true
            }
            Write-Log "Пошкоджений або неперевiрений архiв залишено для дiагностики; hash i передача не виконуватимуться: $fullArchivePath" -Level "ERROR"
            return $false
        } else {
            $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $process.ExitCode
            Write-Log "Помилка архiвацiї 7-Zip (код: $($process.ExitCode) — $exitDescription): $fullArchivePath" -Level "ERROR"
            Write-SevenZipFailureDiagnostics -Operation "Дiагностика 7-Zip create" -StandardOutput $standardOutput -StandardError $errorOutput
            if ($showSevenZipProgress) {
                if (-not [string]::IsNullOrWhiteSpace($lastSevenZipOutput)) {
                    Write-Log "Останнiй вивiд 7-Zip: $lastSevenZipOutput" -Level "DEBUG"
                }
                if (-not [string]::IsNullOrWhiteSpace($errorOutput)) {
                    Write-Log "Помилка 7-Zip: $errorOutput" -Level "DEBUG"
                }
            } else {
                Write-Log "Деталi: $errorOutput" -Level "DEBUG"
            }
            return $false
        }
    } catch {
        Write-Log "Помилка архiвацiї: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function New-SHA512Hash {
    param(
        [string]$FilePath,
        [string]$HashFilePath
    )
    
    if ($script:compatibilityMode) {
        # У режимі сумісності використовуємо тільки сумісну функцію
        return New-SHA512HashLegacy -FilePath $FilePath -HashFilePath $HashFilePath
    } else {
        Write-Log "Створення SHA512 хешу: $(Split-Path $FilePath -Leaf)"
        
        if (-not (Test-Path $FilePath)) {
            Write-Log "Файл не знайдено: $FilePath" -Level "ERROR"
            return $false
        }
        
        try {
            # Використовуємо стандартний метод, якщо доступний
            if ($script:hasFileHash) {
                $hash = (Get-BRAVOFileHash -Path $FilePath -Algorithm SHA512).Hash.ToLower()
                Write-Log "Хеш створено (стандартний метод): $HashFilePath" -Level "SUCCESS"
            } else {
                # Використовуємо сумісний метод
                return New-SHA512HashLegacy -FilePath $FilePath -HashFilePath $HashFilePath
            }
            
            $fileName = (Get-Item $FilePath).Name
            
            # Виправлення для PowerShell 4.0: використовуємо .NET метод замість Out-File з -NoNewline
            [System.IO.File]::WriteAllText($HashFilePath, "${hash} *${fileName}", [System.Text.Encoding]::GetEncoding($hashFileEncoding))
            
            return $true
        } catch {
            Write-Log "Помилка створення хешу: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }
}

# =============================================
# ФУНКЦІЇ МЕРЕЖІ ТА SFTP
# =============================================

function Test-SFTPConfig {
    param(
        [switch]$BAZAOnly,
        [switch]$SynchronizationOnly
    )

    $configurationErrors = @()

    if (-not [string]::IsNullOrWhiteSpace($script:credentialInitializationError)) {
        $configurationErrors += $script:credentialInitializationError
    }
    if ([string]::IsNullOrWhiteSpace($Login)) {
        $configurationErrors += "не завантажено SFTP логiн з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace($sftpUrl) -or -not $sftpUrl.StartsWith("sftp://")) {
        $configurationErrors += "не вдалося сформувати SFTP URL із захищених облікових даних"
    }
    if ([string]::IsNullOrWhiteSpace($sftpHostKey)) {
        $configurationErrors += "не встановлено SFTP host key"
    }
    if ([string]::IsNullOrWhiteSpace($winSCPPath) -or -not (Test-Path -Path $winSCPPath -PathType Leaf)) {
        $configurationErrors += "не знайдено WinSCP: $winSCPPath"
    }

    if (-not $BAZAOnly -and -not $SynchronizationOnly -and $componentSettings.SFTP.ArchiveUpload) {
        foreach ($archive in ($archiveDefinitions | Where-Object { $_.Enabled })) {
            if (-not $sftpDirectories.ContainsKey($archive.Type) -or [string]::IsNullOrWhiteSpace($sftpDirectories[$archive.Type])) {
                $configurationErrors += "не встановлено SFTP каталог для архiву $($archive.Type)"
            }
        }
    }

    if ($BAZAOnly -or $componentSettings.Synchronization.BAZASFTP) {
        if (-not $sftpDirectories.ContainsKey("BAZA") -or [string]::IsNullOrWhiteSpace($sftpDirectories.BAZA)) {
            $configurationErrors += "не встановлено SFTP каталог для BAZA"
        }
    }
    if ($componentSettings.Synchronization.BAZAWWWSFTP) {
        if (-not $sftpDirectories.ContainsKey("BAZAWWW") -or
            [string]::IsNullOrWhiteSpace($sftpDirectories.BAZAWWW)) {
            $configurationErrors += "не встановлено SFTP каталог для BAZA WWW"
        }
    }
    if ($BAZAOnly -or
        $componentSettings.Synchronization.BAZASFTP -or
        $componentSettings.Synchronization.BAZAWWWSFTP) {
        if ([string]$sftpSynchronizationOptions -match '(?i)(^|\s)-delete(\s|$)') {
            $configurationErrors += "опція -delete заборонена для BAZA: віддалені файли мають зберігатися для відновлення"
        }
    }

    if ($configurationErrors.Count -gt 0) {
        foreach ($configurationError in $configurationErrors) {
            Write-Log "Помилка конфiгурацiї SFTP: $configurationError" -Level "ERROR"
        }
        return $false
    }

    Write-Log "Доступ до SFTP налаштовано коректно" -Level "SUCCESS"
    return $true
}

function Test-SMBConfig {
    $configurationErrors = @()

    if (-not [string]::IsNullOrWhiteSpace($script:smbCredentialInitializationError)) {
        $configurationErrors += $script:smbCredentialInitializationError
    }
    if ($null -eq $script:smbCredential) {
        $configurationErrors += "не завантажено NAS/SMB облікові дані з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace([string]$smbSettings.RootPath) -or
        [string]$smbSettings.RootPath -notmatch '^\\\\[^\\]+\\[^\\]+') {
        $configurationErrors += "smbSettings.RootPath повинен бути UNC-шляхом виду \\server\share"
    }
    if ([int]$smbSettings.CopyBufferSizeMB -le 0) {
        $configurationErrors += "smbSettings.CopyBufferSizeMB повинен бути більшим за 0"
    }

    foreach ($archive in @($archiveDefinitions | Where-Object { $_.Enabled })) {
        if ($null -eq $smbSettings.Directories -or
            -not $smbSettings.Directories.ContainsKey($archive.Type) -or
            [string]::IsNullOrWhiteSpace([string]$smbSettings.Directories[$archive.Type])) {
            $configurationErrors += "не встановлено NAS/SMB каталог для архіву $($archive.Type)"
        }
    }

    if ($configurationErrors.Count -gt 0) {
        foreach ($configurationError in $configurationErrors) {
            Write-Log "Помилка конфігурації NAS/SMB: $configurationError" -Level "ERROR"
        }
        return $false
    }

    Write-Log "Доступ до NAS/SMB налаштовано коректно" -Level "SUCCESS"
    return $true
}

function New-BRAVOSMBDrive {
    $driveName = "BRAVOSMB$PID"
    Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue

    try {
        $drive = New-PSDrive `
            -Name $driveName `
            -PSProvider FileSystem `
            -Root ([string]$smbSettings.RootPath) `
            -Credential $script:smbCredential `
            -Scope Script `
            -ErrorAction Stop
        return $drive
    } catch {
        throw "не вдалося підключитися до '$($smbSettings.RootPath)': $($_.Exception.Message)"
    }
}

function Copy-FileToSMBWithProgress {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Component
    )

    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceFile = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
        $bufferSize = [math]::Max(1, [int]$smbSettings.CopyBufferSizeMB) * 1MB
        $buffer = New-Object byte[] $bufferSize
        $sourceStream = New-Object System.IO.FileStream(
            $sourceFile.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read,
            $bufferSize,
            [System.IO.FileOptions]::SequentialScan
        )
        $destinationStream = New-Object System.IO.FileStream(
            $DestinationPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            $bufferSize,
            [System.IO.FileOptions]::SequentialScan
        )

        $copiedBytes = [long]0
        while (($readBytes = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $destinationStream.Write($buffer, 0, $readBytes)
            $copiedBytes += $readBytes
            if ($progressSettings.Enabled -and $sourceFile.Length -gt 0) {
                $percent = [math]::Min(100, [math]::Floor(($copiedBytes * 100.0) / $sourceFile.Length))
                Show-RunningProgress `
                    -Id 4 `
                    -Activity "NAS/SMB — копіювання $Component" `
                    -Status "$($sourceFile.Name): $percent%" `
                    -PercentComplete $percent
            }
        }
        $destinationStream.Flush()
        $destinationStream.Dispose()
        $destinationStream = $null
        [System.IO.File]::SetLastWriteTimeUtc($DestinationPath, $sourceFile.LastWriteTimeUtc)

        $destinationFile = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
        if ([long]$destinationFile.Length -ne [long]$sourceFile.Length) {
            throw "розмір скопійованого файлу не збігається"
        }
        return $true
    } catch {
        if ($destinationStream) {
            $destinationStream.Dispose()
            $destinationStream = $null
        }
        if ($sourceStream) {
            $sourceStream.Dispose()
            $sourceStream = $null
        }
        Write-Log "Помилка копіювання на NAS/SMB: $($_.Exception.Message)" -Level "ERROR"
        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    } finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
        if ($progressSettings.Enabled) {
            Show-RunningProgress -Id 4 -Activity "NAS/SMB — копіювання" -Completed
        }
    }
}

function Copy-ArchivesToSMB {
    param([hashtable]$ArchiveResults)

    $drive = $null
    $copySuccess = 0
    $copyQueue = @()

    foreach ($archive in @($archiveDefinitions | Where-Object { $_.Enabled })) {
        if (-not $ArchiveResults.ContainsKey($archive.Type) -or
            -not $ArchiveResults[$archive.Type].ArchiveSuccess -or
            -not $ArchiveResults[$archive.Type].HashSuccess) {
            continue
        }

        $destinationDirectory = Join-Path `
            ([string]$smbSettings.RootPath) `
            ([string]$smbSettings.Directories[$archive.Type])
        foreach ($sourcePath in @(
            [string]$ArchiveResults[$archive.Type].ArchivePath,
            [string]$ArchiveResults[$archive.Type].HashPath
        )) {
            $copyQueue += [pscustomobject]@{
                SourcePath = $sourcePath
                DestinationDirectory = $destinationDirectory
                Component = [string]$archive.Type
            }
        }
    }

    $copyTotal = $copyQueue.Count
    if ($copyTotal -eq 0) {
        return [pscustomobject]@{
            Total = 0
            Success = 0
        }
    }

    try {
        $drive = New-BRAVOSMBDrive
        Write-Log "Підключення до NAS/SMB успішне: $($smbSettings.RootPath)" -Level "SUCCESS"

        $copyIndex = 0
        foreach ($copyItem in $copyQueue) {
            $copyIndex++
            $copyFileName = Split-Path $copyItem.SourcePath -Leaf
            Show-ItemProgress `
                -Id 14 `
                -Activity "BRAVO_ARCHIV — копіювання на NAS/SMB" `
                -Item $copyFileName `
                -Current $copyIndex `
                -Total $copyTotal

            if (-not (Test-Path -LiteralPath $copyItem.DestinationDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $copyItem.DestinationDirectory -Force -ErrorAction Stop | Out-Null
            }

            $destinationPath = Join-Path $copyItem.DestinationDirectory $copyFileName
            Write-Log "Копіювання на NAS/SMB: $copyFileName -> $($copyItem.DestinationDirectory)"
            if (Copy-FileToSMBWithProgress `
                -SourcePath $copyItem.SourcePath `
                -DestinationPath $destinationPath `
                -Component $copyItem.Component) {
                $copySuccess++
                Write-Log "Файл успішно скопійовано на NAS/SMB: $copyFileName" -Level "SUCCESS"
            }
        }
    } catch {
        Write-Log "Помилка NAS/SMB: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        Show-ItemProgress -Id 14 -Activity "BRAVO_ARCHIV — копіювання на NAS/SMB" -Completed
        if ($drive) {
            Remove-PSDrive -Name $drive.Name -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        Total = $copyTotal
        Success = $copySuccess
    }
}

function Test-NetworkConnection {
    try {
        Write-Log "Перевiрка мережевого з'єднання..." -Level "DEBUG"
        
        $connection = Test-BRAVOTcpConnection `
            -ComputerName $networkCheckHost `
            -Port $networkCheckPort `
            -TimeoutMilliseconds $networkPingTimeoutMilliseconds
        if ($connection) {
            Write-Log "Мережеве з'єднання доступне ($($BRAVOCompatibility.NetworkProvider))" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Мережеве з'єднання недоступне" -Level "ERROR"
            return $false
        }
    } catch {
        Write-Log "Помилка перевiрки мережевого з'єднання: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Remove-BRAVOWinSCPSensitiveTemporaryScript {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]"\/")
    $fullPath = [IO.Path]::GetFullPath($Path)
    $expectedPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar
    $fileName = [IO.Path]::GetFileName($fullPath)
    if (-not $fullPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $fileName -notmatch '^BRAVO_WinSCP_[0-9a-f]{32}\.txt$') {
        throw "відхилено небезпечний шлях тимчасового WinSCP-файла: $Path"
    }

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        # Спершу прибираємо вміст із доступного файлового запису, потім файл.
        [IO.File]::WriteAllText($fullPath, "", [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    }
}

function Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts {
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $staleBefore = (Get-Date).AddDays(-1)
    foreach ($file in @(
            Get-ChildItem `
                -LiteralPath $temporaryRoot `
                -Filter "BRAVO_WinSCP_*.txt" `
                -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $staleBefore }
        )) {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $file.FullName
        } catch {
            # Файл іншого облікового запису може мати закритий ACL.
        }
    }
}

function New-BRAVOWinSCPTemporaryScriptPath {
    # WinSCP script містить URL з обліковими даними. Створюємо файл атомарно
    # та залишаємо доступ лише поточному користувачу, SYSTEM і Administrators.
    Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $temporaryPath = Join-Path `
        -Path $temporaryRoot `
        -ChildPath ("BRAVO_WinSCP_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        $stream = $null

        $acl = Get-Acl -LiteralPath $temporaryPath -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existingRule in @($acl.Access)) {
            [void]$acl.RemoveAccessRuleAll($existingRule)
        }

        $uniqueSids = @{}
        foreach ($sid in @(
                [Security.Principal.WindowsIdentity]::GetCurrent().User,
                (New-Object Security.Principal.SecurityIdentifier("S-1-5-18")),
                (New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544"))
            )) {
            if ($null -eq $sid -or $uniqueSids.ContainsKey($sid.Value)) {
                continue
            }
            $uniqueSids[$sid.Value] = $true
            $rule = New-Object `
                -TypeName System.Security.AccessControl.FileSystemAccessRule `
                -ArgumentList @(
                    $sid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    [Security.AccessControl.AccessControlType]::Allow
                )
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $temporaryPath -AclObject $acl -ErrorAction Stop
        return $temporaryPath
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            try {
                Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $temporaryPath
            } catch {}
        }
        throw
    }
}

function Test-SFTPConnection {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey
    )
    
    Write-Log "Перевiрка пiдключення до SFTP сервера" -Level "DEBUG"
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-Log "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }
    
    $testCommand = @"
option batch abort
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
ls
exit
"@
    
    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    try {
        $testCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-Log (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "перевірка SFTP-з'єднання") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $completed = $process.WaitForExit(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds + 30) * 1000
        )
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {}
            throw "перевищено таймаут перевірки SFTP-з'єднання"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Пiдключення до SFTP сервера успiшне" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Помилка пiдключення до SFTP сервера (код: $($process.ExitCode))" -Level "ERROR"
            Write-Log "Вивiд: $(Get-SanitizedWinSCPDiagnostic -Text $output)" -Level "DEBUG"
            Write-Log "Помилка: $(Get-SanitizedWinSCPDiagnostic -Text $errorOutput)" -Level "DEBUG"
            return $false
        }

    } finally {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {}
    }
}

function Get-SanitizedWinSCPDiagnostic {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaximumLines = 80
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $sanitized = $Text
    $sanitized = $sanitized -replace '(?i)(sftp://)[^@\s]+@', '$1***@'
    $sanitized = $sanitized -replace '(?i)(-password=)(?:"[^"]*"|\S+)', '$1***'
    $lines = @(
        $sanitized -split '\r?\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $safeMaximumLines = [math]::Max(1, $MaximumLines)
    if ($lines.Count -gt $safeMaximumLines) {
        $omittedCount = $lines.Count - $safeMaximumLines
        $lines = @(
            "... пропущено рядкiв WinSCP: $omittedCount ..."
            $lines | Select-Object -Last $safeMaximumLines
        )
    }

    return ($lines -join [Environment]::NewLine)
}

function Get-BAZASFTPComparison {
    param(
        [string]$LocalPath,
        [string]$RemotePath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey
    )

    $components = Get-BRAVOWinSCPDotNetComponents `
        -WinSCPAssemblyPath ([string]$winSCPAssemblyPath) `
        -WinSCPPath ([string]$winSCPPath)
    if ($null -eq $components) {
        return [pscustomobject]@{
            Success = $false
            Error = "не знайдено сумісну пару WinSCPnet.dll та WinSCP.exe"
            PendingFiles = @()
        }
    }

    $session = $null
    try {
        if ($null -eq ("WinSCP.Session" -as [type])) {
            Add-Type -Path $components.AssemblyPath -ErrorAction Stop
        }

        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.ParseUrl($RepositorySFTPUrl)
        $sessionOptions.SshHostKeyFingerprint = ([string]$HostKey).Trim().Trim('"')
        $sessionOptions.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds)
        )

        $session = New-Object WinSCP.Session
        $session.ExecutablePath = $components.ExecutablePath
        $session.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        )
        $session.Open($sessionOptions)

        $mirror = [string]$sftpSynchronizationOptions -match '(?i)(^|\s)-mirror(\s|$)'
        $criteria = [WinSCP.SynchronizationCriteria]::Time
        $criteriaMatch = [regex]::Match(
            [string]$sftpSynchronizationOptions,
            '(?i)(^|\s)-criteria=(?<Value>[^\s]+)'
        )
        if ($criteriaMatch.Success) {
            $criteria = [WinSCP.SynchronizationCriteria]::None
            foreach ($criterion in $criteriaMatch.Groups["Value"].Value.Split(",")) {
                switch ($criterion.ToLowerInvariant()) {
                    "time" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Time
                    }
                    "size" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Size
                    }
                    "checksum" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Checksum
                    }
                }
            }
        }

        # removeFiles = false: додаткові файли у накопичувальній хмарі
        # не видаляються і не потрапляють до списку очікуваних передач.
        $comparison = @(
            $session.CompareDirectories(
                [WinSCP.SynchronizationMode]::Remote,
                $LocalPath,
                $RemotePath,
                $false,
                $mirror,
                $criteria,
                $null
            )
        )

        $pendingFiles = @()
        foreach ($difference in $comparison) {
            $rawAction = [string]$difference.Action
            if ($rawAction -notin @("UploadNew", "UploadUpdate")) {
                continue
            }

            $localItem = $difference.Local
            $localItemPath = if ($null -ne $localItem) {
                [string]$localItem.FullName
            } else {
                ""
            }
            if ([string]::IsNullOrWhiteSpace($localItemPath) -and $null -ne $localItem) {
                $localItemPath = [string]$localItem.FileName
            }
            if (-not [string]::IsNullOrWhiteSpace($localItemPath) -and
                -not [IO.Path]::IsPathRooted($localItemPath)) {
                $localItemPath = Join-Path -Path $LocalPath -ChildPath $localItemPath
            }
            $pendingFiles += [pscustomobject]@{
                Action = $rawAction
                Reason = if ($rawAction -eq "UploadNew") {
                    "відсутній у хмарі"
                } else {
                    "потребує оновлення у хмарі"
                }
                Path = if (-not [string]::IsNullOrWhiteSpace($localItemPath)) {
                    $localItemPath
                } else {
                    "невідомий локальний шлях"
                }
                IsDirectory = [bool]$difference.IsDirectory
                SizeBytes = if ($null -ne $localItem -and -not $difference.IsDirectory) {
                    [long]$localItem.Length
                } else {
                    $null
                }
            }
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            PendingFiles = @($pendingFiles)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
            PendingFiles = @()
        }
    } finally {
        if ($session) {
            $session.Dispose()
        }
    }
}

function Write-BAZASFTPComparisonAudit {
    param(
        [object]$Comparison,
        [ValidateSet("Before", "After")]
        [string]$Stage,
        [string]$ComponentName = "BAZA",
        [object[]]$IncompatibleIssues = @()
    )

    $stageText = if ($Stage -eq "Before") {
        "ДО СИНХРОНIЗАЦIЇ"
    } else {
        "ПIСЛЯ СИНХРОНIЗАЦIЇ"
    }

    if (-not $Comparison.Success) {
        Write-Log "Аудит $ComponentName $stageText не виконано: $($Comparison.Error)" -Level "WARNING"
        return
    }

    $pendingFiles = @($Comparison.PendingFiles)
    $pendingSplit = Split-BAZAPendingFilesByCompatibility `
        -PendingFiles $pendingFiles `
        -IncompatibleIssues $IncompatibleIssues
    $retryablePendingFiles = @($pendingSplit.Retryable)
    $incompatiblePendingFiles = @($pendingSplit.Incompatible)
    $missingCount = @($pendingFiles | Where-Object { $_.Action -eq "UploadNew" }).Count
    $updateCount = @($pendingFiles | Where-Object { $_.Action -eq "UploadUpdate" }).Count
    if ($pendingFiles.Count -eq 0) {
        Write-Log "Аудит $ComponentName ${stageText}: усi локальнi файли синхронiзованi" -Level "SUCCESS"
        return
    }

    $summaryLevel = if ($Stage -eq "Before") {
        "INFO"
    } elseif ($retryablePendingFiles.Count -eq 0 -and $incompatiblePendingFiles.Count -gt 0) {
        "WARNING"
    } else {
        "ERROR"
    }
    Write-Log "Аудит $ComponentName ${stageText}: очiкують передачi: $($pendingFiles.Count) (вiдсутнi у хмарi: $missingCount; потребують оновлення: $updateCount; несумісні імена: $($incompatiblePendingFiles.Count))" -Level $summaryLevel
    foreach ($pendingFile in $retryablePendingFiles) {
        $itemType = if ($pendingFile.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        $sizeText = if ($null -ne $pendingFile.SizeBytes) {
            "; байт: $($pendingFile.SizeBytes)"
        } else {
            ""
        }
        Write-Log "AUDIT $ComponentName $stageText [$itemType] [$($pendingFile.Reason)] $($pendingFile.Path)$sizeText" -Level $summaryLevel -FileOnly
    }
    foreach ($pendingFile in $incompatiblePendingFiles) {
        Write-Log "AUDIT $ComponentName $stageText [ПРОПУЩЕНО: НЕСУМІСНЕ ІМ'Я] $($pendingFile.Path)" -Level "WARNING" -FileOnly
    }
}

function Test-BAZAPathBlockedByIncompatibleName {
    param(
        [string]$CandidatePath,
        [object[]]$IncompatibleIssues = @()
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        return $false
    }
    try {
        $candidateFullPath = [IO.Path]::GetFullPath($CandidatePath).TrimEnd([char[]]"\\/")
    } catch {
        return $false
    }

    foreach ($issue in @($IncompatibleIssues)) {
        try {
            $issueFullPath = [IO.Path]::GetFullPath([string]$issue.Path).TrimEnd([char[]]"\\/")
        } catch {
            continue
        }
        if ($candidateFullPath.Equals($issueFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ([bool]$issue.IsDirectory) {
            $issuePrefix = $issueFullPath + [IO.Path]::DirectorySeparatorChar
            if ($candidateFullPath.StartsWith($issuePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Split-BAZAPendingFilesByCompatibility {
    param(
        [object[]]$PendingFiles = @(),
        [object[]]$IncompatibleIssues = @()
    )

    $retryable = @()
    $incompatible = @()
    foreach ($pendingFile in @($PendingFiles)) {
        if (Test-BAZAPathBlockedByIncompatibleName `
            -CandidatePath ([string]$pendingFile.Path) `
            -IncompatibleIssues $IncompatibleIssues) {
            $incompatible += $pendingFile
        } else {
            $retryable += $pendingFile
        }
    }
    return [pscustomobject]@{
        Retryable = @($retryable)
        Incompatible = @($incompatible)
    }
}

function Get-BAZASynchronizationOutcome {
    param(
        [int]$WinSCPExitCode,
        [object]$ComparisonBefore,
        [object]$ComparisonAfter,
        [object[]]$IncompatibleIssues = @()
    )

    $verificationSucceeded = $null -ne $ComparisonAfter -and $ComparisonAfter.Success
    $afterSplit = if ($verificationSucceeded) {
        Split-BAZAPendingFilesByCompatibility `
            -PendingFiles @($ComparisonAfter.PendingFiles) `
            -IncompatibleIssues $IncompatibleIssues
    } else {
        $null
    }
    $beforeSplit = if ($null -ne $ComparisonBefore -and $ComparisonBefore.Success) {
        Split-BAZAPendingFilesByCompatibility `
            -PendingFiles @($ComparisonBefore.PendingFiles) `
            -IncompatibleIssues $IncompatibleIssues
    } else {
        $null
    }
    $remainingCount = if ($verificationSucceeded) {
        @($ComparisonAfter.PendingFiles).Count
    } else {
        $null
    }
    $retryableRemainingCount = if ($verificationSucceeded) {
        @($afterSplit.Retryable).Count
    } else {
        $null
    }
    $incompatibleRemainingCount = if ($verificationSucceeded) {
        @($afterSplit.Incompatible).Count
    } else {
        $null
    }
    $beforeCount = if ($null -ne $ComparisonBefore -and $ComparisonBefore.Success) {
        @($ComparisonBefore.PendingFiles).Count
    } else {
        $null
    }
    $completedCount = if ($null -ne $beforeSplit -and $null -ne $afterSplit) {
        [math]::Max(0, @($beforeSplit.Retryable).Count - @($afterSplit.Retryable).Count)
    } else {
        $null
    }

    return [pscustomobject]@{
        VerificationSucceeded = $verificationSucceeded
        ExitCode = $WinSCPExitCode
        BeforeCount = $beforeCount
        CompletedCount = $completedCount
        RemainingCount = $remainingCount
        RetryableRemainingCount = $retryableRemainingCount
        IncompatibleRemainingCount = $incompatibleRemainingCount
        IsComplete = (
            $WinSCPExitCode -eq 0 -and
            $verificationSucceeded -and
            $retryableRemainingCount -eq 0
        )
        IsDegraded = (
            $WinSCPExitCode -eq 0 -and
            $verificationSucceeded -and
            $retryableRemainingCount -eq 0 -and
            $incompatibleRemainingCount -gt 0
        )
        IsPartial = (
            $verificationSucceeded -and
            $retryableRemainingCount -gt 0
        )
    }
}

function Get-BAZARemoteNameCompatibilityIssues {
    param(
        [string]$LocalPath,
        [int]$MaximumFileUtf8Bytes = 255,
        [int]$MaximumDirectoryUtf8Bytes = 255
    )

    $issues = @()
    try {
        $localItems = @(
            Get-ChildItem `
                -LiteralPath $LocalPath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        )
        foreach ($localItem in $localItems) {
            $utf8ByteCount = [System.Text.Encoding]::UTF8.GetByteCount($localItem.Name)
            $maximumUtf8Bytes = if ($localItem.PSIsContainer) {
                $MaximumDirectoryUtf8Bytes
            } else {
                $MaximumFileUtf8Bytes
            }
            if ($utf8ByteCount -le $maximumUtf8Bytes) {
                continue
            }

            $issues += [pscustomobject]@{
                Path = $localItem.FullName
                Name = $localItem.Name
                IsDirectory = [bool]$localItem.PSIsContainer
                CharacterCount = $localItem.Name.Length
                Utf8ByteCount = $utf8ByteCount
                MaximumUtf8Bytes = $maximumUtf8Bytes
                Reason = "ім'я довше за допустимі $maximumUtf8Bytes байт у UTF-8"
            }
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            Issues = @($issues)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
            Issues = @()
        }
    }
}

function Write-BAZARemoteNameCompatibilityAudit {
    param(
        [object]$CompatibilityResult,
        [string]$ComponentName = "BAZA"
    )

    if (-not $CompatibilityResult.Success) {
        Write-Log "Не вдалося перевiрити сумiснiсть iмен $ComponentName з SFTP: $($CompatibilityResult.Error)" -Level "WARNING"
        return
    }

    $issues = @($CompatibilityResult.Issues)
    if ($issues.Count -eq 0) {
        Write-Log "Перевiрка iмен ${ComponentName}: несумiсних iз SFTP iмен не знайдено" -Level "SUCCESS"
        return
    }

    Write-Log "Перевiрка iмен ${ComponentName}: знайдено несумiсних iмен: $($issues.Count). Цi об'єкти буде пропущено; потрiбне скорочення локальних iмен" -Level "ERROR"
    foreach ($issue in $issues) {
        $itemType = if ($issue.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        Write-Log "AUDIT $ComponentName НЕСУМIСНЕ IМ'Я [$itemType] [довжина: $($issue.CharacterCount) символів; $($issue.Utf8ByteCount)/$($issue.MaximumUtf8Bytes) UTF-8 байт] $($issue.Path)" -Level "ERROR" -FileOnly
    }

    # Notification failures must never stop the actual SFTP synchronization.
    try {
        Send-BAZAIncompatibleNameAlert -Issues $issues -ComponentName $ComponentName
    } catch {
        Write-Log "Не вдалося підготувати сповіщення про несумісні імена ${ComponentName}: $($_.Exception.Message)" -Level "ERROR"
    }
}

function global:Split-DiscordNotificationText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateRange(100, 2000)]
        [int]$MaximumLength = 1900
    )

    $chunks = New-Object 'System.Collections.Generic.List[string]'

    if ($null -eq $Message) {
        $Message = ""
    }

    if ($Message.Length -eq 0) {
        $chunks.Add("")
        return $chunks.ToArray()
    }

    $normalizedMessage = $Message -replace "`r`n", "`n"
    $normalizedMessage = $normalizedMessage -replace "`r", "`n"

    $currentChunk = New-Object System.Text.StringBuilder

    foreach ($line in ($normalizedMessage -split "`n", 0, "SimpleMatch")) {
        $remainingLine = [string]$line

        do {
            $newlineLength = if ($currentChunk.Length -gt 0) {
                1
            }
            else {
                0
            }

            $availableLength = (
                $MaximumLength -
                $currentChunk.Length -
                $newlineLength
            )

            if ($availableLength -le 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
                continue
            }

            if ($currentChunk.Length -gt 0) {
                [void]$currentChunk.Append("`n")
            }

            $partLength = [Math]::Min(
                $availableLength,
                $remainingLine.Length
            )

            if ($partLength -gt 0) {
                [void]$currentChunk.Append(
                    $remainingLine.Substring(0, $partLength)
                )

                $remainingLine = $remainingLine.Substring($partLength)
            }
            else {
                $remainingLine = ""
            }

            if ($remainingLine.Length -gt 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
            }
        }
        while ($remainingLine.Length -gt 0)
    }

    if ($currentChunk.Length -gt 0 -or $chunks.Count -eq 0) {
        $chunks.Add($currentChunk.ToString())
    }

    return $chunks.ToArray()
}

function Send-BAZAIncompatibleNameAlert {
    param(
        [object[]]$Issues,
        [string]$ComponentName = "BAZA"
    )

    if ($NoSlack -or $script:notificationMode -eq "none") {
        Write-Log "Сповіщення про несумісні імена $ComponentName вимкнено параметрами запуску або конфігурацією" -Level "INFO"
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:notificationWebhookUrl)) {
        Write-Log (
            "Сповіщення про несумісні імена $ComponentName не відправлено: " +
            "webhook для $($script:notificationProviderDisplayName) не налаштовано"
        ) -Level "INFO"
        return
    }

    $examples = @(
        $Issues |
            Select-Object -First 5 |
            ForEach-Object {
                $itemType = if ($_.IsDirectory) { "каталог" } else { "файл" }
                $displayName = [string]$_.Name
                if ($displayName.Length -gt 180) {
                    $displayName = $displayName.Substring(0, 177) + "..."
                }

                # The health formatter lives in a different function scope.
                # Keep this standalone mode self-contained and only apply
                # Markdown escaping when the selected provider is Discord.
                if ($script:notificationProvider -eq "discord") {
                    $displayName = $displayName.Replace("\", "\\")
                    $displayName = $displayName.Replace("*", "\*")
                    $displayName = $displayName.Replace("_", "\_")
                    $displayName = $displayName.Replace("~", "\~")
                    $displayName = $displayName.Replace("|", "\|")
                    $displayName = $displayName.Replace(">", "\>")
                }
                (
                    "• $itemType [довжина: $($_.CharacterCount) символів; " +
                    "$($_.Utf8ByteCount)/$($_.MaximumUtf8Bytes) UTF-8 байт]:`n  " +
                    $displayName
                )
            }
    )
    $examplesText = $examples -join "`n"
    $machineName = [Environment]::MachineName
    $localIpAddresses = @()
    try {
        $localIpAddresses = @(
            [System.Net.Dns]::GetHostAddresses($machineName) |
                Where-Object {
                    $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                    -not [System.Net.IPAddress]::IsLoopback($_) -and
                    -not $_.ToString().StartsWith("169.254.")
                } |
                ForEach-Object { $_.ToString() } |
                Sort-Object -Unique
        )
    } catch {}
    $localIpText = if ($localIpAddresses.Count -gt 0) {
        $localIpAddresses -join " | "
    } else {
        "недоступні"
    }
    $notificationTime = (Get-Date).ToString("dd.MM.yyyy HH:mm:ss")
    $archiveVersionText = [string]$global:ScriptVersion
    $archiveScriptDateText = [string]$global:ScriptDate
    $logFilePath = if (-not [string]::IsNullOrWhiteSpace([string]$script:logFile)) {
        [string]$script:logFile
    } else {
        "журнал BRAVO_ARCHIV"
    }
    $message = @"
🚨 SFTP-СИНХРОНІЗАЦІЯ $ComponentName ПОТРЕБУЄ УВАГИ
🏚️ Установа: $($backupMonitoring.InstitutionName) [$($backupMonitoring.InstitutionCode)]
🖥️ Машина: $machineName
🌐 IP-адреси: $localIpText
🕒 Час: $notificationTime
🏷️ Версія BRAVO_ARCHIV: $archiveVersionText від $archiveScriptDateText

Знайдено несумісних імен: $($Issues.Count). Ці об'єкти не буде передано у хмару, доки локальні імена не буде скорочено.
Довжину показано в символах; технічний ліміт WinSCP — $($Issues[0].MaximumUtf8Bytes) UTF-8 байт.
Приклади:
$examplesText
📝 Повний перелік: $logFilePath
"@

    try {
        $outboundMessages = if ($script:notificationProvider -eq "discord") {
            @(Split-DiscordNotificationText -Message $message)
        } else {
            @($message)
        }
        foreach ($outboundMessage in $outboundMessages) {
            Send-BRAVOWebhookNotification `
                -Provider $script:notificationProvider `
                -WebhookUrl $script:notificationWebhookUrl `
                -Message $outboundMessage `
                -TimeoutSeconds $script:notificationRequestTimeoutSeconds
        }
        $chunkText = if ($outboundMessages.Count -gt 1) {
            " частинами: $($outboundMessages.Count)"
        } else {
            ""
        }
        Write-Log "Сповіщення про $($Issues.Count) несумісних імен $ComponentName відправлено у $($script:notificationProviderDisplayName)$chunkText" -Level "SUCCESS"
    } catch {
        Write-Log "Не вдалося відправити сповіщення про несумісні імена $ComponentName у $($script:notificationProviderDisplayName): $($_.Exception.Message)" -Level "ERROR"
    }
}

function Send-FileViaWinSCP {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey,
        [string]$LocalFilePath,
        [string]$RemoteDirectory
    )
    
    Write-Log "Завантаження через WinSCP: $(Split-Path $LocalFilePath -Leaf) -> $RemoteDirectory"
    
    if (-not (Test-Path $LocalFilePath)) {
        Write-Log "Файл не знайдено: $LocalFilePath" -Level "ERROR"
        return $false
    }
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-Log "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }
    
    # Створюємо тимчасовий скрипт для WinSCP
    $winscpCommand = @"
option batch abort
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
cd /$RemoteDirectory
put "$LocalFilePath"
exit
"@
    
    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    $showWinSCPProgress = $progressSettings.Enabled -and $progressSettings.ShowWinSCPOutput
    $transferFileName = Split-Path $LocalFilePath -Leaf
    $transferActivity = "WinSCP — передача $transferFileName"
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force
        Write-Log "Створено тимчасовий скрипт WinSCP: $tempScript" -Level "DEBUG"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        # Вивід WinSCP завжди перехоплюється, щоб він не дублював журнал у консолі.
        # Замість нього показується єдиний індикатор Write-Progress.
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        Write-Log "Запуск WinSCP..." -Level "DEBUG"
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-Log (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "передача $transferFileName") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $transferStarted = Get-Date
        $operationTimeoutSeconds = [math]::Max(
            1,
            [int]$backupMonitoring.SFTP.OperationTimeoutSeconds
        )
        $transferTimedOut = $false
        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $transferStarted).TotalSeconds)
            if ($showWinSCPProgress) {
                Show-RunningProgress `
                    -Id 11 `
                    -Activity $transferActivity `
                    -Status "Виконується, минуло $elapsedSeconds сек."
            }
            if ($elapsedSeconds -ge $operationTimeoutSeconds) {
                $transferTimedOut = $true
                try {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                } catch {
                    Write-Log "Не вдалося завершити WinSCP після таймауту: $($_.Exception.Message)" -Level "WARNING"
                }
                break
            }
        }
        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "WinSCP не завершився після таймауту передачі"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        $safeOutput = Get-SanitizedWinSCPDiagnostic -Text $output
        $safeErrorOutput = Get-SanitizedWinSCPDiagnostic -Text $errorOutput
        
        if (-not [string]::IsNullOrWhiteSpace($safeOutput)) {
            Write-Log "WinSCP вивiд: $safeOutput" -Level "DEBUG"
        }
        if ($transferTimedOut) {
            Write-Log "Передача WinSCP перевищила таймаут $operationTimeoutSeconds сек.: $transferFileName" -Level "ERROR"
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Файл успiшно завантажено: $(Split-Path $LocalFilePath -Leaf)" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Помилка завантаження (код: $($process.ExitCode)): $(Split-Path $LocalFilePath -Leaf)" -Level "ERROR"
            if (-not [string]::IsNullOrEmpty($safeOutput)) {
                Write-Log "Вивiд WinSCP: $safeOutput" -Level "DEBUG"
            }
            if (-not [string]::IsNullOrEmpty($safeErrorOutput)) {
                Write-Log "Помилка WinSCP: $safeErrorOutput" -Level "DEBUG"
            }
            return $false
        }
    } catch {
        Write-Log "Помилка пiд час завантаження через WinSCP: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($showWinSCPProgress) {
            Show-RunningProgress -Id 11 -Activity $transferActivity -Completed
        }
        # Очищаємо тимчасовий файл із конфіденційними даними.
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
            Write-Log "Тимчасовий скрипт видалено: $tempScript" -Level "DEBUG"
        } catch {
            Write-Log "Не вдалося видалити тимчасовий скрипт: $($_.Exception.Message)" -Level "WARNING"
        }
    }
}

function Sync-FolderToSFTP {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey,
        [string]$LocalDirectory,
        [string]$RemoteDirectory,
        [string]$ComponentName = "BAZA"
    )

    $normalizedRemoteDirectory = $RemoteDirectory.Replace("\", "/").Trim("/")
    $remotePath = if ([string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) {
        "/"
    } else {
        "/$normalizedRemoteDirectory"
    }

    Write-Log "Синхронiзацiя каталогу через WinSCP: $LocalDirectory -> $remotePath"

    if (-not (Test-Path -Path $LocalDirectory -PathType Container)) {
        Write-Log "Локальний каталог не знайдено: $LocalDirectory" -Level "ERROR"
        return $false
    }

    if ($synchronizationSafety.RequireNonEmptyBAZASource) {
        $firstSourceFile = Get-BRAVOFiles `
            -LiteralPath $LocalDirectory `
            -Recurse `
            -Force `
            |
            Select-Object -First 1
        if ($null -eq $firstSourceFile) {
            Write-Log "SFTP-синхронiзацiю $ComponentName заблоковано: локальний каталог порожнiй або недоступний" -Level "ERROR"
            return $false
        }
    }

    if (-not (Test-Path -Path $WinSCPPath -PathType Leaf)) {
        Write-Log "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }

    $fileNameUtf8Limit = if (
        [string]$sftpSynchronizationOptions -match '(?i)(^|\s)-resumesupport=on(\s|$)'
    ) {
        # WinSCP додає ".filepart" (9 UTF-8 байт) до тимчасового імені.
        246
    } else {
        255
    }
    $nameCompatibility = Get-BAZARemoteNameCompatibilityIssues `
        -LocalPath $LocalDirectory `
        -MaximumFileUtf8Bytes $fileNameUtf8Limit `
        -MaximumDirectoryUtf8Bytes 255
    Write-BAZARemoteNameCompatibilityAudit `
        -CompatibilityResult $nameCompatibility `
        -ComponentName $ComponentName

    $comparisonBefore = Get-BAZASFTPComparison `
        -LocalPath $LocalDirectory `
        -RemotePath $remotePath `
        -RepositorySFTPUrl $RepositorySFTPUrl `
        -HostKey $HostKey
    Write-BAZASFTPComparisonAudit `
        -Comparison $comparisonBefore `
        -Stage "Before" `
        -ComponentName $ComponentName `
        -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })

    # Кореневий каталог синхронізації має бути попередньо створений на SFTP.
    # Не виконуємо mkdir: WinSCP повертає код 1, якщо каталог уже існує,
    # навіть коли option batch continue дозволяє перейти до синхронізації.
    # stat однозначно перевіряє каталог і не створює хибної помилки.
    $winscpCommand = @"
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
option batch abort
stat "$remotePath"
option batch continue
synchronize remote $sftpSynchronizationOptions "$LocalDirectory" "$remotePath"
exit
"@

    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    $showWinSCPProgress = $progressSettings.Enabled -and $progressSettings.ShowWinSCPOutput
    $syncActivity = "WinSCP — синхронiзацiя $ComponentName"
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        try {
            # WinSCP.com використовує UTF-8 для перенаправленого виводу.
            # Явне декодування запобігає появі тексту виду "╨..." у журналі.
            $winSCPUtf8Encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
            $processInfo.StandardOutputEncoding = $winSCPUtf8Encoding
            $processInfo.StandardErrorEncoding = $winSCPUtf8Encoding
        } catch {
            Write-Log "Не вдалося встановити UTF-8 для виводу WinSCP: $($_.Exception.Message)" -Level "DEBUG"
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-Log (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "синхронізація $ComponentName") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $syncStarted = Get-Date
        $configuredSynchronizationTimeout = [int](
            $backupMonitoring.SFTP.SynchronizationTimeoutSeconds
        )
        $operationTimeoutSeconds = if (
            $configuredSynchronizationTimeout -gt 0
        ) {
            $configuredSynchronizationTimeout
        } else {
            # Сумісність зі старими BRAVO.config.
            [math]::Max(
                1,
                [int]$backupMonitoring.SFTP.OperationTimeoutSeconds
            )
        }
        Write-Log (
            "Таймаут синхронiзацiї ${ComponentName}: " +
            "$operationTimeoutSeconds сек."
        ) -Level "INFO"
        $syncTimedOut = $false
        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $syncStarted).TotalSeconds)
            if ($showWinSCPProgress) {
                Show-RunningProgress `
                    -Id 12 `
                    -Activity $syncActivity `
                    -Status "Виконується, минуло $elapsedSeconds сек."
            }
            if ($elapsedSeconds -ge $operationTimeoutSeconds) {
                $syncTimedOut = $true
                try {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                } catch {
                    Write-Log "Не вдалося завершити WinSCP після таймауту синхронізації ${ComponentName}: $($_.Exception.Message)" -Level "WARNING"
                }
                break
            }
        }
        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "WinSCP не завершився після таймауту синхронізації $ComponentName"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        $sanitizedOutput = Get-SanitizedWinSCPDiagnostic -Text $output
        $sanitizedErrorOutput = Get-SanitizedWinSCPDiagnostic -Text $errorOutput

        if (-not [string]::IsNullOrWhiteSpace($sanitizedOutput)) {
            Write-Log "WinSCP вивiд синхронiзацiї ${ComponentName}: $sanitizedOutput" -Level "DEBUG"
        }
        if ($syncTimedOut) {
            Write-Log "Синхронізація $ComponentName перевищила таймаут $operationTimeoutSeconds сек." -Level "ERROR"
            Write-Log "Повторний запуск продовжить передачу файлів із використанням WinSCP resumesupport" -Level "INFO"
            return $false
        }

        $winSCPExitCode = $process.ExitCode
        if ($winSCPExitCode -ne 0) {
            Write-Log "Помилка SFTP-синхронiзацiї $ComponentName (код: $winSCPExitCode)" -Level "ERROR"
            if (-not [string]::IsNullOrWhiteSpace($sanitizedOutput)) {
                Write-Log "Дiагностика WinSCP (stdout): $sanitizedOutput" -Level "ERROR"
            }
            if (-not [string]::IsNullOrWhiteSpace($sanitizedErrorOutput)) {
                Write-Log "Дiагностика WinSCP (stderr): $sanitizedErrorOutput" -Level "ERROR"
            }
            if ([string]::IsNullOrWhiteSpace($sanitizedOutput) -and
                [string]::IsNullOrWhiteSpace($sanitizedErrorOutput)) {
                Write-Log "WinSCP не повернув тексту помилки; перевiрте права доступу до $remotePath" -Level "ERROR"
            }
        }

        # option batch continue може повернути код 0, навіть якщо окремі файли
        # були пропущені. Тому остаточний результат визначає лише повторне
        # read-only порівняння локального каталогу з хмарою.
        $comparisonAfter = Get-BAZASFTPComparison `
            -LocalPath $LocalDirectory `
            -RemotePath $remotePath `
            -RepositorySFTPUrl $RepositorySFTPUrl `
            -HostKey $HostKey
        Write-BAZASFTPComparisonAudit `
            -Comparison $comparisonAfter `
            -Stage "After" `
            -ComponentName $ComponentName `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })

        $syncOutcome = Get-BAZASynchronizationOutcome `
            -WinSCPExitCode $winSCPExitCode `
            -ComparisonBefore $comparisonBefore `
            -ComparisonAfter $comparisonAfter `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })

        if (-not $syncOutcome.VerificationSucceeded) {
            Write-Log "Не вдалося пiдтвердити результат синхронiзацiї $ComponentName повторним порiвнянням; результат вважається помилкою" -Level "ERROR"
            return $false
        }

        if ($null -ne $syncOutcome.CompletedCount) {
            $resultLevel = if ($syncOutcome.IsComplete -and -not $syncOutcome.IsDegraded) {
                "SUCCESS"
            } else {
                "WARNING"
            }
            Write-Log "Результат ${ComponentName}: передано або оновлено сумісних об'єктiв: $($syncOutcome.CompletedCount); залишилося несинхронiзованих: $($syncOutcome.RemainingCount)" -Level $resultLevel
        }

        if ($syncOutcome.IsComplete) {
            if ($syncOutcome.IsDegraded) {
                Write-Log "Каталог $ComponentName синхронізовано для всіх сумісних імен; $($syncOutcome.IncompatibleRemainingCount) об'єктів пропущено через незмінювані несумісні імена. Повторний запуск не потрібен." -Level "WARNING"
            } else {
                Write-Log "Каталог $ComponentName повнiстю синхронiзовано з $remotePath" -Level "SUCCESS"
            }
            return $true
        }

        if ($winSCPExitCode -eq 0 -and $syncOutcome.IsPartial) {
            Write-Log "WinSCP повернув код 0, але синхронiзацiя $ComponentName часткова: залишилося об'єктiв: $($syncOutcome.RemainingCount)" -Level "ERROR"
        }
        return $false
    } catch {
        Write-Log "Помилка пiд час SFTP-синхронiзацiї ${ComponentName}: $($_.Exception.Message)" -Level "ERROR"
        $comparisonAfterException = Get-BAZASFTPComparison `
            -LocalPath $LocalDirectory `
            -RemotePath $remotePath `
            -RepositorySFTPUrl $RepositorySFTPUrl `
            -HostKey $HostKey
        Write-BAZASFTPComparisonAudit `
            -Comparison $comparisonAfterException `
            -Stage "After" `
            -ComponentName $ComponentName `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })
        return $false
    } finally {
        if ($showWinSCPProgress) {
            Show-RunningProgress -Id 12 -Activity $syncActivity -Completed
        }
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {}
    }
}

function Invoke-ManualBAZASFTPSynchronization {
    Write-Log "==="
    Write-Log "=== РУЧНА СИНХРОНIЗАЦIЯ BAZA_APP / BAZA_WWW НА SFTP ==="
    Write-Log "Режим -SyncBAZA: синхронізуються всі увімкнені BAZA_APP/BAZA_WWW; архiвацiю, очищення архiвiв, NAS/SMB та health-check пропущено" -Level "INFO"
    Show-ScriptProgress -Status "Ручна синхронiзацiя BAZA_APP / BAZA_WWW на SFTP" -PercentComplete 20

    $syncTargets = @()
    $sourceConfigurationFailed = $false
    if ([bool]$componentSettings.Synchronization.BAZASFTP) {
        if (Test-PathWithLog -Path $bazaPaths.Source -Description "Каталог BAZA_APP" -CreateIfMissing $false) {
            $syncTargets += [pscustomobject]@{
                Name = "BAZA_APP"
                Source = [string]$bazaPaths.Source
                Destination = [string]$sftpDirectories.BAZA
            }
        } else {
            $sourceConfigurationFailed = $true
            Write-Log "Ручну синхронізацію BAZA_APP пропущено: локальний каталог недоступний" -Level "ERROR"
        }
    }
    if ([bool]$componentSettings.Synchronization.BAZAWWWSFTP) {
        if ($bazaWWWDetection.Success -and
            -not [string]::IsNullOrWhiteSpace([string]$bazaWWWPaths.Source) -and
            (Test-PathWithLog -Path $bazaWWWPaths.Source -Description "Каталог BAZA_WWW" -CreateIfMissing $false)) {
            $syncTargets += [pscustomobject]@{
                Name = "BAZA_WWW"
                Source = [string]$bazaWWWPaths.Source
                Destination = [string]$sftpDirectories.BAZAWWW
            }
        } else {
            $sourceConfigurationFailed = $true
            $detectionReason = if ($bazaWWWDetection.Success) { "локальний каталог недоступний" } else { [string]$bazaWWWDetection.Reason }
            Write-Log "Ручну синхронізацію BAZA_WWW пропущено: $detectionReason" -Level "ERROR"
        }
    }
    if ($syncTargets.Count -eq 0) {
        Write-Log "Ручну синхронізацію скасовано: BAZASFTP і BAZAWWWSFTP вимкнені або їхні джерела недоступні" -Level "ERROR"
        return $false
    }

    if (-not (Test-SFTPConfig -SynchronizationOnly)) {
        Write-Log "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено через помилки конфiгурацiї SFTP" -Level "ERROR"
        return $false
    }

    Show-ScriptProgress -Status "Перевiрка з'єднання з SFTP" -PercentComplete 35
    if (-not (Test-NetworkConnection)) {
        Write-Log "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено: мережеве з'єднання недоступне" -Level "ERROR"
        return $false
    }

    if (-not (Test-SFTPConnection `
        -WinSCPPath $winSCPPath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey)) {
        Write-Log "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено: не вдалося пiдключитися до SFTP" -Level "ERROR"
        return $false
    }

    $syncFailed = $sourceConfigurationFailed
    $syncIndex = 0
    foreach ($syncTarget in $syncTargets) {
        $syncIndex++
        $progressPercent = 55 + [math]::Floor(($syncIndex - 1) * 35 / [math]::Max(1, $syncTargets.Count))
        Show-ScriptProgress -Status "Синхронiзацiя $($syncTarget.Name) на SFTP" -PercentComplete $progressPercent
        $syncSuccess = Sync-FolderToSFTP `
            -WinSCPPath $winSCPPath `
            -RepositorySFTPUrl $sftpUrl `
            -HostKey $sftpHostKey `
            -LocalDirectory $syncTarget.Source `
            -RemoteDirectory $syncTarget.Destination `
            -ComponentName $syncTarget.Name
        if ($syncSuccess) {
            Write-Log "Ручну синхронiзацiю $($syncTarget.Name) на SFTP завершено успiшно" -Level "SUCCESS"
        } else {
            $syncFailed = $true
            Write-Log "Ручна синхронiзацiя $($syncTarget.Name) на SFTP завершилася з помилкою" -Level "ERROR"
        }
    }

    return (-not $syncFailed)
}

function Enter-BRAVOArchiveProcessLock {
    # Спільний lock для BRAVO_ARCHIV і BRAVO_MAINTENANCE. Він не дозволяє
    # maintenance зупиняти служби або змінювати джерела під час backup.
    $lockPath = Join-Path $logPath "BRAVO_OPERATION.lock"
    try {
        if (-not (Test-Path -LiteralPath $logPath -PathType Container)) {
            New-Item `
                -ItemType Directory `
                -Path $logPath `
                -Force `
                -ErrorAction Stop |
                Out-Null
        }
        $waitMinutes = if ($null -ne $schedulerSettings -and
            $schedulerSettings.Contains("OperationLockWaitMinutes")) {
            [math]::Max(0, [int]$schedulerSettings.OperationLockWaitMinutes)
        } else {
            0
        }
        $deadline = (Get-Date).AddMinutes($waitMinutes)
        $lockStream = $null
        $lastLockError = $null
        do {
            try {
                $lockStream = [System.IO.File]::Open(
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
        } while ($null -eq $lockStream -and (Get-Date) -lt $deadline)
        if ($null -eq $lockStream) {
            throw "lock не звільнився за $waitMinutes хв.: $lastLockError"
        }
        $lockText = (
            "PID={0}; Started={1}; Config={2}" -f
            $PID,
            (Get-Date).ToString("o"),
            $configPath
        )
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
        $lockStream.SetLength(0)
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        $lockStream.Flush()

        return [pscustomobject]@{
            Success = $true
            Stream = $lockStream
            Path = $lockPath
            Error = $null
        }
    } catch {
        if ($lockStream) {
            $lockStream.Dispose()
        }
        return [pscustomobject]@{
            Success = $false
            Stream = $null
            Path = $lockPath
            Error = $_.Exception.Message
        }
    }
}

# =============================================
# ОСНОВНА ЛОГІКА
# =============================================

function Write-BRAVOBackupExecutionState {
    $path = Join-Path $logPath 'BRAVO_TASK_EXECUTION_STATE.json'
    $state = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $previous = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $state.Maintenance = [string]$previous.Maintenance
            $state.Backup = [string]$previous.Backup
        } catch {}
    }
    $state.Backup = ([datetime]::Now).ToString('o')
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Main {
    # Ініціалізація
    $scriptStartTime = Get-Date
    $now = $scriptStartTime.ToString($archiveTimestampFormat)
    $logTimestamp = $scriptStartTime.ToString($logFileDateFormat)
    $script:logFile = Join-Path $logPath ($logFileNameTemplate -f $logTimestamp)

    # Журнал і консоль — два незалежні канали з власними порогами.
    $configuredFileLevel = if ($null -ne $consoleSettings.FileLevel) {
        [string]$consoleSettings.FileLevel
    } else {
        'INFO'
    }
    $configuredConsoleLevel = if ($null -ne $consoleSettings.ConsoleLevel) {
        [string]$consoleSettings.ConsoleLevel
    } else {
        'SUCCESS'
    }
    $configuredStepWidth = if ($null -ne $consoleSettings.StepWidth) {
        [int]$consoleSettings.StepWidth
    } else {
        58
    }
    [void](Initialize-BRAVOLog `
        -LogFile $script:logFile `
        -FileLevel $configuredFileLevel `
        -ConsoleLevel $configuredConsoleLevel)
    Initialize-BRAVOConsole -StepWidth $configuredStepWidth
    Write-BRAVOHeader `
        -Title ("BRAVO ARCHIVE {0}" -f $ScriptVersion) `
        -Institution ([string]$bravoSettings.InstitutionName) `
        -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
        -StartedAt $scriptStartTime

    $processLockResult = Enter-BRAVOArchiveProcessLock
    if (-not $processLockResult.Success) {
        Write-Log (
            "Запуск скасовано: інший екземпляр BRAVO_ARCHIV уже працює " +
            "або файл блокування недоступний: $($processLockResult.Error)"
        ) -Level "ERROR"
        $script:processExitCode = 2
        return
    }
    $script:archiveProcessLock = $processLockResult.Stream
    $script:archiveProcessLockPath = $processLockResult.Path

    $enabledArchives = @($archiveDefinitions | Where-Object { $_.Enabled })
    $readyArchives = @()
    $results = @{}
    $bazaLocalSyncEnabled = [bool]$componentSettings.Synchronization.BAZALocal
    $bazaSFTPSyncEnabled = [bool]$componentSettings.Synchronization.BAZASFTP
    $bazaWWWSFTPSyncEnabled = [bool]$componentSettings.Synchronization.BAZAWWWSFTP
    $sftpArchiveUploadEnabled = [bool]$componentSettings.SFTP.ArchiveUpload
    $smbArchiveCopyEnabled = [bool]$componentSettings.SMB.ArchiveCopy
    $sftpTransferEnabled = (
        $sftpArchiveUploadEnabled -or
        $bazaSFTPSyncEnabled -or
        $bazaWWWSFTPSyncEnabled
    )
    $operationFailed = $false
    Show-ScriptProgress -Status "Iнiцiалiзацiя" -PercentComplete 2
    
    Write-Log "==="
    Write-Log "=== ПОЧАТОК РОБОТИ СКРИПТА BRAVO_ARCHIV v.$ScriptVersion ==="
    Write-Log "Файл конфiгурацiї: $configPath" -Level "INFO"
    
    # Перевірка сумісності
    Write-Log "==="
    Write-Log "=== ПЕРЕВIРКА СУМIСНОСТI СИСТЕМИ ==="
    Show-ScriptProgress -Status "Перевiрка сумiсностi" -PercentComplete 5
    $compatibilityIssues = Test-Compatibility

    if ($SyncBAZA) {
        $manualSyncStarted = Get-Date
        $manualSyncSuccess = Invoke-ManualBAZASFTPSynchronization
        $manualSyncFinished = Get-Date
        $manualSyncDuration = $manualSyncFinished - $manualSyncStarted

        Write-Log "==="
        Write-Log "=== ЗАВЕРШЕННЯ РУЧНОЇ СИНХРОНIЗАЦIЇ BAZA_APP / BAZA_WWW ==="
        Write-Log "Результат: $(if ($manualSyncSuccess) {'УСПIШНО'} else {'ПОМИЛКА'})" -NoTimestamp
        Write-Log "Тривалiсть: $($manualSyncDuration.ToString($durationFormat))" -NoTimestamp
        Write-Log "Лог-файл: $logFile" -NoTimestamp
        $script:processExitCode = if ($manualSyncSuccess) { 0 } else { 1 }
        Show-ScriptProgress -Status "Завершено" -PercentComplete 100
        return
    }
    
    # Використовуємо NoTimestamp для інформаційного блоку
    Write-Log "==="
    Write-Log "=== ОПЦIЇ СКРИПТА ==="
    Write-Log "Версiя та дата скрипта: $ScriptVersion вiд $ScriptDate" -NoTimestamp
    Write-Log "Час початку: $($scriptStartTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Кореневий каталог: $rootPath" -NoTimestamp
    Write-Log "Каталог резервних копiй: $backupRootPath" -NoTimestamp
    Write-Log "Режим логування: $LogLevel" -NoTimestamp
    Write-Log "Режим сумiсностi: $(if ($compatibilityMode) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Видалення коректних архiвiв за строком зберігання: $(if ($enableArchiveDeletion) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Очищення неповних/пошкоджених комплектів після $failedArchiveRetentionDays днів: $(if ($enableFailedArchiveDeletion) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Очищення обідніх архівів (_1300.): $(if ($enableLunchArchiveCleanup) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Узгодженість щоденних архівів: $([string]$backupConsistency.Mode)" -NoTimestamp
    foreach ($archive in $archiveDefinitions) {
        Write-Log "Архiвацiя $($archive.Type): $(if ($archive.Enabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    }
    if ([bool]$componentSettings.Archive.BRAVOEXCH) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bravoExchSourceDirectory)) {
            Write-Log "Джерело BRAVOEXCH: $bravoExchSourceDirectory (вибрано автоматично)" -NoTimestamp
        } else {
            Write-Log "Джерело BRAVOEXCH не знайдено: жоден із каталогів не існує або не містить файлів: $($bravoExchSourceCandidates -join '; ')" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Локальна синхронiзацiя BAZA: $(if ($bazaLocalSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Завантаження архiвiв на SFTP: $(if ($sftpArchiveUploadEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA на SFTP: $(if ($bazaSFTPSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA WWW на SFTP: $(if ($bazaWWWSFTPSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    if ($bazaWWWSFTPSyncEnabled) {
        if ($bazaWWWDetection.Success) {
            Write-Log (
                "Джерело BAZA WWW: $($bazaWWWPaths.Source); " +
                "служба: $($bazaWWWDetection.ServiceName); " +
                "executable: $($bazaWWWDetection.ServiceExecutable)"
            ) -NoTimestamp
        } else {
            Write-Log "Джерело BAZA WWW не визначено: $($bazaWWWDetection.Reason)" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Копіювання архівів на NAS/SMB: $(if ($smbArchiveCopyEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp

    $archiveCredentialValid = $true
    if ($enabledArchives.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА ПАРОЛЯ АРХIВIВ ==="
        if (-not [string]::IsNullOrWhiteSpace($script:archiveCredentialInitializationError)) {
            Write-Log "Не вдалося завантажити пароль архiвiв: $($script:archiveCredentialInitializationError)" -Level "ERROR"
            $archiveCredentialValid = $false
        } elseif ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            Write-Log "Пароль архiвiв вiдсутнiй у Windows Credential Manager" -Level "ERROR"
            $archiveCredentialValid = $false
        } elseif ($archiveParams -match '(?i)(^|\s)-p(?=\S|\s|$)') {
            Write-Log "Видалiть параметр -p<пароль> з archiveParams у BRAVO.config: пароль має зберiгатися лише у Credential Manager" -Level "ERROR"
            $archiveCredentialValid = $false
        } else {
            Write-Log "Пароль архiвiв завантажено з Windows Credential Manager" -Level "SUCCESS"
        }
    }

    $archiveConsistencyValid = $true
    if ($enabledArchives.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА УЗГОДЖЕНОСТI АРХIВIВ ==="
        $consistencyMode = [string]$backupConsistency.Mode
        $snapshotContext = [string]$backupConsistency.SnapshotContext
        if ($consistencyMode -ne "VSS") {
            Write-Log "backupConsistency.Mode повинен мати значення VSS; live-архівація заборонена" -Level "ERROR"
            $archiveConsistencyValid = $false
        } elseif ($snapshotContext -ne "ClientAccessible") {
            Write-Log "backupConsistency.SnapshotContext повинен мати значення ClientAccessible" -Level "ERROR"
            $archiveConsistencyValid = $false
        } else {
            Write-Log "Узгодженість архівів: окремий VSS-знімок для кожного компонента" -Level "SUCCESS"
        }
    }

    # Перевіряємо налаштування SFTP лише для увімкнених компонентів передачі
    $sftpConfigurationValid = $true
    if ($sftpTransferEnabled) {
        Show-ScriptProgress -Status "Перевiрка конфiгурацiї SFTP" -PercentComplete 10
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА КОНФIГУРАЦIЇ SFTP ==="
        $sftpConfigurationValid = Test-SFTPConfig
        if (-not $sftpConfigurationValid) {
            Write-Log "SFTP-компоненти буде пропущено; локальна архiвацiя продовжиться" -Level "WARNING"
            $operationFailed = $true
        }
    } else {
        Write-Log "Перевiрка SFTP не потрiбна: усi компоненти передачi вимкнено" -Level "INFO"
    }

    $smbConfigurationValid = $true
    if ($smbArchiveCopyEnabled) {
        Show-ScriptProgress -Status "Перевірка конфігурації NAS/SMB" -PercentComplete 11
        Write-Log "==="
        Write-Log "=== ПЕРЕВІРКА КОНФІГУРАЦІЇ NAS/SMB ==="
        $smbConfigurationValid = Test-SMBConfig
        if (-not $smbConfigurationValid) {
            Write-Log "Копіювання на NAS/SMB буде пропущено; локальна архівація продовжиться" -Level "WARNING"
            $operationFailed = $true
        }
    } else {
        Write-Log "Перевірка NAS/SMB не потрібна: компонент вимкнено" -Level "INFO"
    }
    
    $oldLogsToRemove = @()
    if (Test-Path -LiteralPath $logPath -PathType Container) {
        $logRetentionCutoff = (Get-Date).AddDays(-$logRetentionDays)
        $oldLogsToRemove = @(Get-BRAVOFiles -Path $logPath -Filter $logFileFilter |
            Where-Object { $_.LastWriteTime -lt $logRetentionCutoff })
    } else {
        Write-Log "Шлях журналів не знайдено: $logPath" -Level "ERROR"
        $operationFailed = $true
    }

    if ($oldLogsToRemove.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ОЧИЩЕННЯ СТАРИХ ЛОГIВ ==="
        Show-ScriptProgress -Status "Очищення старих логiв" -PercentComplete 12
        if (-not (Remove-OldLogsByAge `
                -Path $logPath `
                -Filter $logFileFilter `
                -RetentionDays $logRetentionDays `
                -Logger { param($Message, $Level) Write-Log $Message -Level $Level })) {
            $operationFailed = $true
        }
    }
    
    # Перевірка шляхів
    Write-Log "==="
    Write-Log "=== ПЕРЕВIРКА НЕОБХIДНИХ ШЛЯХIВ ==="
    Show-ScriptProgress -Status "Перевiрка необхiдних шляхiв" -PercentComplete 15
    $requiredPaths = @($baseRequiredPaths)
    $archiveToolAvailable = $archiveCredentialValid -and $archiveConsistencyValid

    if ($enabledArchives.Count -gt 0) {
        $requiredPaths += @{Path=$arcPath; Description="7-Zip"; CreateIfMissing=$false}
    }

    $basePathsAvailable = $true
    foreach ($item in $requiredPaths) {
        if (-not (Test-PathWithLog `
            -Path $item.Path `
            -Description $item.Description `
            -CreateIfMissing ([bool]$item.CreateIfMissing))) {
            $basePathsAvailable = $false
            if ($item.Path -eq $arcPath) {
                $archiveToolAvailable = $false
            }
        }
    }

    foreach ($archive in $enabledArchives) {
        $sourceAvailable = Test-PathWithLog `
            -Path $archive.Source `
            -Description "Джерело архiву $($archive.Type) мiстить данi" `
            -CreateIfMissing $false
        $destinationAvailable = Test-PathWithLog `
            -Path $archive.Destination `
            -Description "Каталог архiву $($archive.Type)" `
            -CreateIfMissing $true

        if ($archiveToolAvailable -and $sourceAvailable -and $destinationAvailable) {
            $readyArchives += $archive
        } else {
            $results[$archive.Type] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
            }
            Write-Log "Компонент $($archive.Type) пропущено через помилку налаштувань, шляху або вiдсутнi данi" -Level "ERROR"
            $operationFailed = $true
        }
    }

    $bazaSourceAvailable = $true
    $bazaDestinationAvailable = $true
    if ($bazaLocalSyncEnabled -or $bazaSFTPSyncEnabled) {
        $bazaSourceAvailable = Test-PathWithLog `
            -Path $bazaPaths.Source `
            -Description "Каталог BAZA" `
            -CreateIfMissing $false
    }
    if ($bazaLocalSyncEnabled) {
        $bazaDestinationAvailable = Test-PathWithLog `
            -Path $bazaPaths.Destination `
            -Description "Каталог архiву BAZA" `
            -CreateIfMissing $true
    }
    $bazaWWWSourceAvailable = $true
    if ($bazaWWWSFTPSyncEnabled) {
        if ($bazaWWWDetection.Success -and
            -not [string]::IsNullOrWhiteSpace([string]$bazaWWWPaths.Source)) {
            $bazaWWWSourceAvailable = Test-PathWithLog `
                -Path $bazaWWWPaths.Source `
                -Description "Каталог BAZA WWW" `
                -CreateIfMissing $false
        } else {
            Write-Log "Каталог BAZA WWW недоступний: $($bazaWWWDetection.Reason)" -Level "ERROR"
            $bazaWWWSourceAvailable = $false
        }
    }

    $allPathsExist = (
        $basePathsAvailable -and
        $readyArchives.Count -eq $enabledArchives.Count -and
        $bazaSourceAvailable -and
        $bazaDestinationAvailable -and
        $bazaWWWSourceAvailable
    )
    Show-PathCheckSummary -CheckedPaths $requiredPaths -AllPathsExist $allPathsExist
    
    # Синхронізація BAZA
    if ($bazaLocalSyncEnabled -and $bazaSourceAvailable -and $bazaDestinationAvailable) {
        Show-ScriptProgress -Status "Локальна синхронiзацiя BAZA" -PercentComplete 20
        Write-Log "==="
        Write-Log "=== СИНХРОНIЗАЦIЯ BAZA ==="
        $syncSuccess = Sync-Folders -SourcePath $bazaPaths.Source -DestinationPath $bazaPaths.Destination

        if ($syncSuccess) {
            Write-Log "Синхронiзацiя BAZA успiшна" -Level "SUCCESS"
        } else {
            Write-Log "Помилка синхронiзацiї BAZA - архiвацiя може бути неповною" -Level "WARNING"
            $operationFailed = $true
        }
    } elseif ($bazaLocalSyncEnabled) {
        Write-Log "Локальну синхронiзацiю BAZA пропущено через помилку шляху" -Level "ERROR"
        $operationFailed = $true
    } else {
        Write-Log "Локальну синхронiзацiю BAZA вимкнено в конфiгурацiї" -Level "INFO"
    }
    
    # Створення архівів
    $archiveIndex = 0

    foreach ($archive in $readyArchives) {
        $archiveIndex++
        $archiveProgress = 30 + [Math]::Floor((($archiveIndex - 1) / [Math]::Max(1, $readyArchives.Count)) * 40)
        Show-ScriptProgress -Status "Архiвацiя $($archive.Type) ($archiveIndex з $($readyArchives.Count))" -PercentComplete $archiveProgress
        Show-ItemProgress `
            -Id 10 `
            -Activity "BRAVO_ARCHIV — архiвацiя компонентiв" `
            -Item $archive.Type `
            -Current $archiveIndex `
            -Total $readyArchives.Count
        $archiveName = $archive.NameTemplate -f $archivePrefix, $now
        Write-Log "==="
        Write-Log "=== АРХIВАЦIЯ $($archive.Type) ==="
        $success = $false
        $vssSnapshot = $null
        try {
            $vssSnapshot = New-BRAVOVSSSnapshot -SourcePath $archive.Source
            $success = New-Archive `
                -SourcePath $vssSnapshot.SourcePath `
                -ArchivePath $archive.Destination `
                -ArchiveName $archiveName `
                -ArcPath $arcPath `
                -ArcParams $archiveParams
        } catch {
            Write-Log "Не вдалося виконати узгоджену VSS-архівацію $($archive.Type): $($_.Exception.Message)" -Level "ERROR"
            $success = $false
        } finally {
            if ($null -ne $vssSnapshot) {
                if (-not (Remove-BRAVOVSSSnapshot -Snapshot $vssSnapshot)) {
                    $operationFailed = $true
                }
            }
        }
        
        if ($success) {
            Write-Log "==="
            Write-Log "=== СТВОРЕННЯ ХЕШУ $($archive.Type) ==="
            $hashProgress = [Math]::Min(69, $archiveProgress + 8)
            Show-ScriptProgress -Status "Створення SHA512 для $($archive.Type)" -PercentComplete $hashProgress
            $archivePath = Join-Path $archive.Destination $archiveName
            $hashPath = "$archivePath$hashFileExtension"
            $hashSuccess = New-SHA512Hash -FilePath $archivePath -HashFilePath $hashPath
            
            $results[$archive.Type] = @{
                ArchivePath = $archivePath
                HashPath = $hashPath
                ArchiveSuccess = $success
                HashSuccess = $hashSuccess
            }
        } else {
            $results[$archive.Type] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
            }
        }
    }
    Show-ItemProgress -Id 10 -Activity "BRAVO_ARCHIV — архiвацiя компонентiв" -Completed
    
    # Видалення старих архівів: розділ логу з'являється лише перед фактичним видаленням.
    if ($enableArchiveDeletion) {
        $effectiveArchiveRetentionDays = 183
        # archiveVersions є лише у старих конфігах, тому читаємо його безпечно:
        # пряме звернення до неоголошеної змінної переривало б цю гілку.
        $legacyArchiveVersionsVariable = Get-Variable -Name 'archiveVersions' -Scope Global -ErrorAction SilentlyContinue
        $legacyArchiveVersions = if ($null -ne $legacyArchiveVersionsVariable) { $legacyArchiveVersionsVariable.Value } else { $null }
        try {
            if ($null -ne $archiveRetentionDays -and [int]$archiveRetentionDays -gt 0) {
                $effectiveArchiveRetentionDays = [int]$archiveRetentionDays
            } elseif ($null -ne $legacyArchiveVersions -and [int]$legacyArchiveVersions -gt 0) {
                # Сумісність із конфігами до archiveRetentionDays. Значення
                # archiveVersions використовуємо як строк у днях лише під час міграції.
                $effectiveArchiveRetentionDays = [int]$legacyArchiveVersions
                Write-Log "Застарілий archiveVersions=$effectiveArchiveRetentionDays застосовано як строк зберігання у днях; перенесіть значення до archiveRetentionDays" -Level "WARNING"
            } else {
                Write-Log "archiveRetentionDays відсутній або некоректний; для безпеки застосовано $effectiveArchiveRetentionDays днів" -Level "WARNING"
            }
        } catch {
            Write-Log "archiveRetentionDays не вдалося прочитати; для безпеки застосовано $effectiveArchiveRetentionDays днів" -Level "WARNING"
        }
        $archiveCleanupSectionShown = $false
        foreach ($archive in $enabledArchives) {
            if (-not (Remove-OldBackupSets -Path $archive.Destination -RetentionDays $effectiveArchiveRetentionDays -Component $archive.Type -CleanupSectionShown ([ref]$archiveCleanupSectionShown))) {
                $operationFailed = $true
            }
        }
    }

    if ($enableLunchArchiveCleanup) {
        $effectiveLunchArchiveRetentionMonths = 2
        try {
            if ($null -ne $lunchArchiveRetentionMonths -and [int]$lunchArchiveRetentionMonths -gt 0) {
                $effectiveLunchArchiveRetentionMonths = [int]$lunchArchiveRetentionMonths
            } else {
                Write-Log "lunchArchiveRetentionMonths відсутній або некоректний; для безпеки застосовано $effectiveLunchArchiveRetentionMonths місяці" -Level "WARNING"
            }
        } catch {
            Write-Log "lunchArchiveRetentionMonths не вдалося прочитати; для безпеки застосовано $effectiveLunchArchiveRetentionMonths місяці" -Level "WARNING"
        }

        $lunchArchiveDirectories = @($lunchArchiveCleanupDirectories | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
        if ([string]::IsNullOrWhiteSpace([string]$lunchArchiveCleanupPath) -or $lunchArchiveDirectories.Count -eq 0) {
            Write-Log "Очищення обідніх архівів увімкнено, але lunchArchiveCleanupPath або lunchArchiveCleanupDirectories не налаштовано" -Level "ERROR"
            $operationFailed = $true
        } elseif (-not (Remove-OldLunchArchives `
            -ArchiveRoot $lunchArchiveCleanupPath `
            -Directories $lunchArchiveDirectories `
            -RetentionMonths $effectiveLunchArchiveRetentionMonths)) {
            $operationFailed = $true
        }
    }
    
    # Передача на SFTP
    if ($sftpTransferEnabled) {
        Show-ScriptProgress -Status "Перевiрка з'єднання з SFTP" -PercentComplete 78
        if (-not $sftpConfigurationValid) {
            Write-Log "Передачу на SFTP пропущено через помилки конфiгурацiї" -Level "ERROR"
            $operationFailed = $true
        } elseif (-not (Test-NetworkConnection)) {
            Write-Log "Мережеве з'єднання недоступне - пропускаємо передачу на SFTP" -Level "ERROR"
            $operationFailed = $true
        } elseif (-not (Test-SFTPConnection -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey)) {
            Write-Log "Помилка пiдключення до SFTP - пропускаємо передачу" -Level "ERROR"
            $operationFailed = $true
        } else {
            if ($sftpArchiveUploadEnabled) {
                $uploadSuccess = 0
                $uploadQueue = @()

                # Формуємо чергу у стабільному порядку компонентів, щоб відсоток
                # і лічильник файлів не змінювали порядок між запусками.
                foreach ($archive in $enabledArchives) {
                    $archiveType = $archive.Type
                    if ($results.ContainsKey($archiveType) -and
                        $results[$archiveType].ArchiveSuccess -and
                        $results[$archiveType].HashSuccess) {
                        $uploadQueue += [pscustomobject]@{
                            LocalPath = [string]$results[$archiveType].ArchivePath
                            RemoteDirectory = [string]$sftpDirectories[$archiveType]
                        }
                        $uploadQueue += [pscustomobject]@{
                            LocalPath = [string]$results[$archiveType].HashPath
                            RemoteDirectory = [string]$sftpDirectories[$archiveType]
                        }
                    }
                }

                $uploadTotal = $uploadQueue.Count
                if ($uploadTotal -gt 0) {
                    Show-ScriptProgress -Status "Завантаження архiвiв на SFTP" -PercentComplete 82
                    Write-Log "==="
                    Write-Log "=== ЗАВАНТАЖЕННЯ АРХIВIВ НА SFTP ==="
                }
                $uploadIndex = 0
                foreach ($uploadItem in $uploadQueue) {
                    $uploadIndex++
                    $uploadFileName = Split-Path $uploadItem.LocalPath -Leaf
                    Show-ItemProgress `
                        -Id 13 `
                        -Activity "BRAVO_ARCHIV — завантаження на SFTP" `
                        -Item $uploadFileName `
                        -Current $uploadIndex `
                        -Total $uploadTotal
                    $fileUploaded = Send-FileViaWinSCP `
                        -WinSCPPath $winSCPPath `
                        -RepositorySFTPUrl $sftpUrl `
                        -HostKey $sftpHostKey `
                        -LocalFilePath $uploadItem.LocalPath `
                        -RemoteDirectory $uploadItem.RemoteDirectory
                    if ($fileUploaded) {
                        $uploadSuccess++
                    }
                }
                Show-ItemProgress -Id 13 -Activity "BRAVO_ARCHIV — завантаження на SFTP" -Completed

                if ($uploadTotal -gt 0) {
                    $uploadLevel = if ($uploadSuccess -eq $uploadTotal) { "SUCCESS" } else { "ERROR" }
                    Write-Log "Завантажено $uploadSuccess з $uploadTotal файлiв на SFTP" -Level $uploadLevel
                    if ($uploadSuccess -ne $uploadTotal) {
                        $operationFailed = $true
                    }
                } else {
                    Write-Log "Немає успiшно створених архiвiв для завантаження на SFTP" -Level "WARNING"
                    if ($enabledArchives.Count -gt 0) {
                        $operationFailed = $true
                    }
                }
            } else {
                Write-Log "Завантаження архiвiв на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }

            if ($bazaSFTPSyncEnabled -and $bazaSourceAvailable) {
                Show-ScriptProgress -Status "Синхронiзацiя BAZA на SFTP" -PercentComplete 90
                Write-Log "==="
                Write-Log "=== СИНХРОНIЗАЦIЯ BAZA НА SFTP ==="
                $bazaSFTPSync = Sync-FolderToSFTP -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey -LocalDirectory $bazaPaths.Source -RemoteDirectory $sftpDirectories.BAZA
                if (-not $bazaSFTPSync) {
                    Write-Log "Каталог BAZA не вдалося синхронiзувати з SFTP" -Level "WARNING"
                    $operationFailed = $true
                }
            } elseif ($bazaSFTPSyncEnabled) {
                Write-Log "Синхронiзацiю BAZA на SFTP пропущено через помилку локального шляху" -Level "ERROR"
                $operationFailed = $true
            } else {
                Write-Log "Синхронiзацiю BAZA на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }

            if ($bazaWWWSFTPSyncEnabled -and $bazaWWWSourceAvailable) {
                Show-ScriptProgress -Status "Синхронiзацiя BAZA WWW на SFTP" -PercentComplete 91
                Write-Log "==="
                Write-Log "=== СИНХРОНIЗАЦIЯ BAZA WWW НА SFTP ==="
                $bazaWWWSFTPSync = Sync-FolderToSFTP `
                    -WinSCPPath $winSCPPath `
                    -RepositorySFTPUrl $sftpUrl `
                    -HostKey $sftpHostKey `
                    -LocalDirectory $bazaWWWPaths.Source `
                    -RemoteDirectory $sftpDirectories.BAZAWWW `
                    -ComponentName "BAZA WWW"
                if (-not $bazaWWWSFTPSync) {
                    Write-Log "Каталог BAZA WWW не вдалося синхронiзувати з SFTP" -Level "WARNING"
                    $operationFailed = $true
                }
            } elseif ($bazaWWWSFTPSyncEnabled) {
                Write-Log "Синхронiзацiю BAZA WWW на SFTP пропущено через помилку автоматичного визначення шляху" -Level "ERROR"
                $operationFailed = $true
            } else {
                Write-Log "Синхронiзацiю BAZA WWW на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }
        }
    } else {
        Write-Log "Усi компоненти передачi на SFTP вимкнено в конфiгурацiї" -Level "INFO"
    }

    # Копіювання успішно створених архівів та hash-файлів на NAS/SMB
    if ($smbArchiveCopyEnabled) {
        Show-ScriptProgress -Status "Копіювання архівів на NAS/SMB" -PercentComplete 92
        Write-Log "==="
        Write-Log "=== КОПІЮВАННЯ АРХІВІВ НА NAS/SMB ==="
        if (-not $smbConfigurationValid) {
            Write-Log "Копіювання на NAS/SMB пропущено через помилки конфігурації" -Level "ERROR"
            $operationFailed = $true
        } else {
            $smbCopyResult = Copy-ArchivesToSMB -ArchiveResults $results
            if ($smbCopyResult.Total -eq 0) {
                Write-Log "Немає успішно створених архівів для копіювання на NAS/SMB" -Level "WARNING"
                if ($enabledArchives.Count -gt 0) {
                    $operationFailed = $true
                }
            } elseif ($smbCopyResult.Success -eq $smbCopyResult.Total) {
                Write-Log "Скопійовано $($smbCopyResult.Success) з $($smbCopyResult.Total) файлів на NAS/SMB" -Level "SUCCESS"
            } else {
                Write-Log "Скопійовано $($smbCopyResult.Success) з $($smbCopyResult.Total) файлів на NAS/SMB" -Level "ERROR"
                $operationFailed = $true
            }
        }
    } else {
        Write-Log "Копіювання архівів на NAS/SMB вимкнено в конфігурації" -Level "INFO"
    }
    
    # Завершення
    $scriptEndTime = Get-Date
    $duration = $scriptEndTime - $scriptStartTime
    
    Write-Log "==="
    Write-Log "=== ЗАВЕРШЕННЯ РОБОТИ СКРИПТА ==="
    Write-Log "Час початку: $($scriptStartTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Час завершення: $($scriptEndTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Тривалiсть: $($duration.ToString($durationFormat))" -NoTimestamp
    
    # Підсумок
    $successCount = ($results.Values | Where-Object { $_.ArchiveSuccess }).Count
    $totalCount = $results.Count
    if ($readyArchives.Count -ne $enabledArchives.Count -or
        @($results.Values | Where-Object {
            -not $_.ArchiveSuccess -or -not $_.HashSuccess
        }).Count -gt 0) {
        $operationFailed = $true
    }
    
    Write-Log "Створено архiвiв: $successCount з $totalCount" -NoTimestamp
    Write-Log "Лог-файл: $logFile" -NoTimestamp

    if ($backupMonitoring.Enabled -and $backupMonitoring.RunAfterBackup) {
        Show-ScriptProgress -Status "Перевiрка стану резервних копiй" -PercentComplete 96
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА СТАНУ РЕЗЕРВНИХ КОПIЙ ==="

        try {
                $healthParameters = @{
                    ConfigPath = $configPath
                }
                $backupNotificationMode = [string]$backupMonitoring.NotificationMode
                if ([string]::IsNullOrWhiteSpace($backupNotificationMode)) {
                    $backupNotificationMode = [string]$backupMonitoring.SlackMode
                }
                if ($backupMonitoring.NotifyOnSuccessAfterBackup -and
                    $backupNotificationMode.ToLowerInvariant() -eq "all") {
                    $healthParameters.NotifyOnSuccess = $true
                }
                $healthModulePath = Join-Path $bravoScriptDirectory 'modules\BRAVO.Health\BRAVO.Health.psd1'
                if (-not (Test-Path -LiteralPath $healthModulePath -PathType Leaf)) {
                    throw "Не знайдено модуль health-check: $healthModulePath"
                }
                Import-Module -Name $healthModulePath -ErrorAction Stop
                $healthParameters.RuntimeRoot = $bravoScriptDirectory
                $healthParameters.EntryScriptPath = Join-Path $bravoScriptDirectory 'BRAVO_HEALTH.ps1'
                $healthCheckResult = Invoke-BRAVOHealthCheck @healthParameters
                switch ($healthCheckResult.Status) {
                    "Healthy" {
                        Write-Log "Health-check: усi резервнi копiї актуальнi; повідомлення: $($healthCheckResult.Notification)" -Level "SUCCESS"
                    }
                    "Critical" {
                        Write-Log "Health-check: знайдено проблем: $($healthCheckResult.IssueCount); повідомлення: $($healthCheckResult.Notification)" -Level "ERROR"
                        $operationFailed = $true
                    }
                    "NotificationError" {
                        Write-Log "Health-check завершився, але повідомлення не вiдправлено: $($healthCheckResult.Error)" -Level "ERROR"
                        $operationFailed = $true
                    }
                    default {
                        Write-Log "Health-check завершився зі статусом: $($healthCheckResult.Status)" -Level "WARNING"
                        $operationFailed = $true
                    }
                }
        } catch {
            Write-Log "Помилка запуску окремого health-check: $($_.Exception.Message)" -Level "ERROR"
            $operationFailed = $true
        }
    }

    Write-Log "Результат: $(if ($operationFailed) {'ПОМИЛКА'} else {'УСПIШНО'})" -NoTimestamp
    Write-Log "==="
    if (-not $operationFailed) {
        Write-BRAVOBackupExecutionState
    }
    Show-ScriptProgress -Status "Завершено" -PercentComplete 100
    if ($operationFailed) {
        $script:processExitCode = 1
    }
}

# Запуск головної функції
$script:processExitCode = 0
$script:archiveProcessLock = $null
$script:archiveProcessLockPath = $null
try {
    Main
} catch {
    $script:processExitCode = 1
    throw
} finally {
    if ($script:archiveProcessLock) {
        $script:archiveProcessLock.Dispose()
        $script:archiveProcessLock = $null
    }
    if (-not [string]::IsNullOrWhiteSpace(
            [string]$script:archiveProcessLockPath
        ) -and
        (Test-Path -LiteralPath $script:archiveProcessLockPath -PathType Leaf)) {
        Remove-Item `
            -LiteralPath $script:archiveProcessLockPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if ($script:smbCredential -and $script:smbCredential.Password) {
        $script:smbCredential.Password.Dispose()
        $script:smbCredential = $null
    }
    Show-ScriptProgress -Completed
    Wait-ForManualExit
}

if ($script:processExitCode -ne 0) {
    Exit $script:processExitCode
}
Exit 0
