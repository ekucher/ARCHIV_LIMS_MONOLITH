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
    [switch]$NoPause
)

$bravoScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Path $PSCommandPath -Parent
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

$compatibilityModulePath = Join-Path $bravoScriptDirectory "BRAVO_COMPATIBILITY.ps1"
if (-not (Test-Path -LiteralPath $compatibilityModulePath -PathType Leaf)) {
    Write-Host "ПОМИЛКА: Не знайдено модуль сумісності: $compatibilityModulePath" -ForegroundColor Red
    exit 1
}
try {
    . $compatibilityModulePath
} catch {
    Write-Host "ПОМИЛКА сумісності: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
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
    $configPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $configPath -Parent
    $configText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    $configScript = [scriptblock]::Create($configText)
    & $configScript -ConfigRoot $configRoot

    Write-Host "Конфiгурацiю завантажено успiшно: $configPath" -ForegroundColor $logColors.SUCCESS
} catch {
    Write-Host "ПОМИЛКА: Не вдалося завантажити конфiгурацiю: $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}

# Запит на підвищення дозволу виконання скрипта
if ($requireAdministrator) {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Потрiбнi права адмiнiстратора. Запит UAC..." -ForegroundColor $logColors.WARNING

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $elevationSettings.PowerShellExecutable
        $processInfo.Arguments = $elevationSettings.ArgumentsTemplate -f $PSCommandPath, $configPath
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

$global:Login = $null
$global:sftpUrl = $null
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
$notificationCredentialRequired = -not $SyncBAZA -and
    $script:notificationMode -ne "none"
$credentialHelperLoaded = $false

if ($institutionSettingsRequired -or
    $sftpCredentialRequired -or
    $smbCredentialRequired -or
    $archiveCredentialRequired -or
    $notificationCredentialRequired) {
    try {
        if ([string]::IsNullOrWhiteSpace([string]$credentialSettings.HelperPath) -or
            -not (Test-Path -LiteralPath $credentialSettings.HelperPath -PathType Leaf)) {
            throw "не знайдено модуль Credential Manager: $($credentialSettings.HelperPath)"
        }

        . $credentialSettings.HelperPath
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

        $global:Login = ([string]$storedSftpLogin).Trim()
        $configuredSftpHost = [string]$sftpHost
        $global:sftpHost = Resolve-BRAVOSftpHostName `
            -UserName $global:Login `
            -HostTemplate ([string]$sftpHostTemplate) `
            -FallbackHostName $configuredSftpHost
        $global:sftpUrl = New-BRAVOSftpUrl `
            -HostName $global:sftpHost `
            -Port ([int]$sftpPort) `
            -UserName $global:Login `
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

    $script:hasFileHash = $BRAVOCompatibility.FileHashProvider -eq "Get-FileHash"
    $script:hasNetConnection = $BRAVOCompatibility.NetworkProvider -eq "Test-NetConnection"
    $script:compatibilityMode = [bool]$BRAVOCompatibility.IsCompatibilityMode

    Write-Log "Windows: $($BRAVOCompatibility.WindowsVersion); PowerShell: $($BRAVOCompatibility.PowerShellVersion)" -Level "DEBUG"
    Write-Log "WMI: $($BRAVOCompatibility.WmiProvider); Hash: $($BRAVOCompatibility.FileHashProvider); Network: $($BRAVOCompatibility.NetworkProvider); Files: $($BRAVOCompatibility.ChildItemProvider)" -Level "DEBUG"

    if ($script:compatibilityMode) {
        Write-Log "Режим сумiсностi активний: несумiснi сучаснi API буде автоматично замiнено" -Level "INFO"
    } else {
        Write-Log "Стандартний режим" -Level "INFO"
    }
    if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
        Write-Log $BRAVOPowerShellUpdate.Message -Level "WARNING"
    }

    return $BRAVOCompatibility
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

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = $defaultLogLevel,
        [int]$SeparatorLength = $logSeparatorLength,
        [switch]$NoTimestamp,  # Новий параметр для вiдключення timestamp
        [switch]$FileOnly
    )
    
    # Отримуємо поточний рівень логування з глобальної змінної
    $currentLogLevel = if ($global:LogLevel -and $logLevels.ContainsKey($global:LogLevel)) { 
        $logLevels[$global:LogLevel] 
    } else { 
        $logLevels[$defaultLogLevel]
    }
    
    $messageLevel = if ($logLevels.ContainsKey($Level)) { 
        $logLevels[$Level] 
    } else { 
        $logLevels[$defaultLogLevel]
    }
    
    # Пропускаємо повідомлення нижчого рівня
    # FileOnly використовується для обов'язкового файлового аудиту:
    # такі записи зберігаються незалежно від поточного рівня журналу.
    if ($messageLevel -lt $currentLogLevel -and -not $FileOnly) {
        return
    }
    
    # Обробка спеціальних повідомлень-роздільників
    if ($Message -eq "=" -or $Message -eq "===") {
        # Генеруємо роздільник з вказаною кількістю знаків
        $separator = "=" * $SeparatorLength
        Write-Host $separator -ForegroundColor $logColors.Default
        try {
            if (-not (Test-Path $logPath)) {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
            }
            $separator | Out-File -FilePath $global:logFile -Append -Encoding $logFileEncoding
        } catch {
            Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
        }
        return
    }
    
    # Обробка заголовків
    if ($Message -match "^=== .* ===$") {
        # Для заголовків виводимо без timestamp та рівня
        Write-Host $Message -ForegroundColor $logColors.Header
        try {
            if (-not (Test-Path $logPath)) {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
            }
            $Message | Out-File -FilePath $global:logFile -Append -Encoding $logFileEncoding
        } catch {
            Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
        }
        return
    }
    
    # Звичайні повідомлення
    if ($NoTimestamp) {
        # Повідомлення без timestamp (для інформаційних блоків)
        $logEntry = $Message
        if (-not $FileOnly) {
            Write-Host $logEntry -ForegroundColor $logColors.Default
        }
    } else {
        # Звичайні повідомлення з timestamp
        $timestamp = Get-Date -Format $logTimestampFormat
        $logEntry = "[$timestamp] [$Level] $Message"
        $consoleEntry = if ($consoleSettings.ShowTimestampsInConsole) {
            $logEntry
        } else {
            "[$Level] $Message"
        }
        
        if (-not $FileOnly) {
            switch ($Level) {
                "SUCCESS" { Write-Host $consoleEntry -ForegroundColor $logColors.SUCCESS }
                "ERROR"   { Write-Host $consoleEntry -ForegroundColor $logColors.ERROR }
                "WARNING" { Write-Host $consoleEntry -ForegroundColor $logColors.WARNING }
                "DEBUG"   { Write-Host $consoleEntry -ForegroundColor $logColors.DEBUG }
                default   { Write-Host $consoleEntry -ForegroundColor $logColors.Default }
            }
        }
    }
    
    try {
        if (-not (Test-Path $logPath)) {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        $logEntry | Out-File -FilePath $global:logFile -Append -Encoding $logFileEncoding
    } catch {
        Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
    }
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

function Remove-OldBackupSets {
    param(
        [string]$Path,
        [int]$KeepCount,
        [string]$Component
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
                Remove-Item -LiteralPath $orphanHash.FullName -Force -ErrorAction Stop
                Write-Log "Видалено застарілий hash-файл без архіву: $($orphanHash.Name)" -Level "WARNING"
            }
        }

        if (-not $enableArchiveDeletion) {
            return $true
        }

        $setsToDelete = @($validSets | Select-Object -Skip $KeepCount)
        foreach ($set in $setsToDelete) {
            # Спочатку видаляється великий архів. Якщо видалення hash-файлу
            # не вдасться, залишиться лише безпечний сирота, а не архів без hash.
            Remove-Item -LiteralPath $set.Archive.FullName -Force -ErrorAction Stop
            try {
                Remove-Item -LiteralPath $set.HashPath -Force -ErrorAction Stop
            } catch {
                Write-Log "Архів видалено, але не вдалося видалити його hash-файл $($set.HashPath): $($_.Exception.Message)" -Level "WARNING"
            }
            Write-Log "Видалено комплект ${Component}: $($set.Archive.Name)" -Level "SUCCESS"
        }
        return $true
    } catch {
        Write-Log "Помилка очищення комплектів ${Component}: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Remove-OldLogsByAge {
    param(
        [string]$Path,
        [string]$Filter,
        [int]$RetentionDays
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $failed = $false
    foreach ($file in @(Get-BRAVOFiles -Path $Path -Filter $Filter |
        Where-Object { $_.LastWriteTime -lt $cutoff })) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-Log "Видалено старий лог: $($file.Name)" -Level "SUCCESS"
        } catch {
            $failed = $true
            Write-Log "Не вдалося видалити лог $($file.Name): $($_.Exception.Message)" -Level "ERROR"
        }
    }
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
    param(
        [string]$Operation,
        [string]$StandardOutput,
        [string]$StandardError,
        [int]$MaximumLines = 30
    )

    $diagnosticLines = @(
        @($StandardError, $StandardOutput) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ -split '\r?\n' } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object {
                $line = ([string]$_).TrimEnd()
                if ($line.Length -gt 1000) {
                    $line.Substring(0, 1000) + "... [обрізано]"
                } else {
                    $line
                }
            } |
            Select-Object -Last ([math]::Max(1, $MaximumLines))
    )

    if ($diagnosticLines.Count -eq 0) {
        Write-Log "$Operation не повернув діагностичного тексту" -Level "WARNING"
        return
    }

    $diagnosticText = $diagnosticLines -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace([string]$script:archivePassword)) {
        $diagnosticText = $diagnosticText.Replace(
            [string]$script:archivePassword,
            "********"
        )
    }
    Write-Log "${Operation}: $diagnosticText" -Level "ERROR"
}

function Test-SevenZipArchiveIntegrity {
    param(
        [string]$SevenZipPath,
        [string]$ArchivePath,
        [string]$Password,
        [int]$TimeoutSeconds = 43200
    )

    Write-Log "Перевiрка цiлiсностi 7-Zip: $(Split-Path $ArchivePath -Leaf)"
    $testResult = Invoke-BRAVOSevenZipIntegrityTest `
        -SevenZipPath $SevenZipPath `
        -ArchivePath $ArchivePath `
        -Password $Password `
        -TimeoutSeconds $TimeoutSeconds

    $exitCodeText = if ($null -eq $testResult.ExitCode) {
        "немає"
    } else {
        [string]$testResult.ExitCode
    }
    if ($testResult.Success) {
        Write-Log "Цiлiснiсть архiву пiдтверджено 7-Zip (код: 0): $ArchivePath" -Level "SUCCESS"
        return $true
    }

    Write-Log "Перевiрка цiлiсностi 7-Zip не пройдена (код: $exitCodeText — $($testResult.Description)): $ArchivePath" -Level "ERROR"
    Write-SevenZipFailureDiagnostics `
        -Operation "Дiагностика 7-Zip test" `
        -StandardOutput ([string]$testResult.StandardOutput) `
        -StandardError ([string]$testResult.StandardError)
    return $false
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
        if ($script:archivePassword.Contains('"')) {
            Write-Log "Пароль архiву мiстить непiдтримуваний символ подвiйних лапок" -Level "ERROR"
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

        $archivePasswordArgument = "-p`"$($script:archivePassword)`""
        $arguments = "$effectiveArcParams $archivePasswordArgument `"$fullArchivePath`" `"$SourcePath`""
        $safeArguments = "$effectiveArcParams -p******** `"$fullArchivePath`" `"$SourcePath`""
        Write-Log "Команда: $ArcPath $safeArguments" -Level "DEBUG"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $ArcPath
        $processInfo.Arguments = $arguments
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
        if ($archiveTimedOut) {
            Write-Log "Архiвацiю перервано: перевищено таймаут $archiveTimeoutSeconds сек.: $ArchiveName" -Level "ERROR"
            Write-SevenZipFailureDiagnostics `
                -Operation "Дiагностика 7-Zip create" `
                -StandardOutput ([string]$standardOutput) `
                -StandardError ([string]$errorOutput)
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
                -TimeoutSeconds $integrityTestTimeoutSeconds) {
                Write-Log "Архiв створено та перевiрено: $fullArchivePath" -Level "SUCCESS"
                return $true
            }
            Write-Log "Пошкоджений або неперевiрений архiв залишено для дiагностики; hash i передача не виконуватимуться: $fullArchivePath" -Level "ERROR"
            return $false
        } else {
            $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $process.ExitCode
            Write-Log "Помилка архiвацiї 7-Zip (код: $($process.ExitCode) — $exitDescription): $fullArchivePath" -Level "ERROR"
            Write-SevenZipFailureDiagnostics `
                -Operation "Дiагностика 7-Zip create" `
                -StandardOutput ([string]$standardOutput) `
                -StandardError ([string]$errorOutput)
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
    param([switch]$BAZAOnly)

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

    if (-not $BAZAOnly -and $componentSettings.SFTP.ArchiveUpload) {
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
    
    $tempScript = [System.IO.Path]::GetTempFileName() + ".txt"
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
        if (Test-Path $tempScript) {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
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

function Get-WinSCPDotNetComponents {
    if ($null -ne $script:WinSCPDotNetComponents) {
        return $script:WinSCPDotNetComponents
    }

    $assemblyCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPAssemblyPath)) {
        $assemblyCandidates += [string]$winSCPAssemblyPath
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
        $assemblyCandidates += Join-Path (Split-Path -Path $winSCPPath -Parent) "WinSCPnet.dll"
    }

    foreach ($assemblyPath in @($assemblyCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            continue
        }

        $executablePath = Join-Path (Split-Path -Path $assemblyPath -Parent) "WinSCP.exe"
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            continue
        }

        $script:WinSCPDotNetComponents = [pscustomobject]@{
            AssemblyPath = (Resolve-Path -LiteralPath $assemblyPath).Path
            ExecutablePath = (Resolve-Path -LiteralPath $executablePath).Path
        }
        return $script:WinSCPDotNetComponents
    }

    return $null
}

function Get-BAZASFTPComparison {
    param(
        [string]$LocalPath,
        [string]$RemotePath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey
    )

    $components = Get-WinSCPDotNetComponents
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
            $pendingFiles += [pscustomobject]@{
                Action = $rawAction
                Reason = if ($rawAction -eq "UploadNew") {
                    "відсутній у хмарі"
                } else {
                    "потребує оновлення у хмарі"
                }
                Path = if ($null -ne $localItem) {
                    [string]$localItem.FileName
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
        [string]$ComponentName = "BAZA"
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
    $missingCount = @($pendingFiles | Where-Object { $_.Action -eq "UploadNew" }).Count
    $updateCount = @($pendingFiles | Where-Object { $_.Action -eq "UploadUpdate" }).Count
    if ($pendingFiles.Count -eq 0) {
        Write-Log "Аудит $ComponentName ${stageText}: усi локальнi файли синхронiзованi" -Level "SUCCESS"
        return
    }

    $summaryLevel = if ($Stage -eq "Before") { "INFO" } else { "ERROR" }
    Write-Log "Аудит $ComponentName ${stageText}: очiкують передачi: $($pendingFiles.Count) (вiдсутнi у хмарi: $missingCount; потребують оновлення: $updateCount)" -Level $summaryLevel
    foreach ($pendingFile in $pendingFiles) {
        $itemType = if ($pendingFile.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        $sizeText = if ($null -ne $pendingFile.SizeBytes) {
            "; байт: $($pendingFile.SizeBytes)"
        } else {
            ""
        }
        Write-Log "AUDIT $ComponentName $stageText [$itemType] [$($pendingFile.Reason)] $($pendingFile.Path)$sizeText" -Level $summaryLevel -FileOnly
    }
}

function Get-BAZASynchronizationOutcome {
    param(
        [int]$WinSCPExitCode,
        [object]$ComparisonBefore,
        [object]$ComparisonAfter
    )

    $verificationSucceeded = $null -ne $ComparisonAfter -and $ComparisonAfter.Success
    $remainingCount = if ($verificationSucceeded) {
        @($ComparisonAfter.PendingFiles).Count
    } else {
        $null
    }
    $beforeCount = if ($null -ne $ComparisonBefore -and $ComparisonBefore.Success) {
        @($ComparisonBefore.PendingFiles).Count
    } else {
        $null
    }
    $completedCount = if ($null -ne $beforeCount -and $null -ne $remainingCount) {
        [math]::Max(0, $beforeCount - $remainingCount)
    } else {
        $null
    }

    return [pscustomobject]@{
        VerificationSucceeded = $verificationSucceeded
        ExitCode = $WinSCPExitCode
        BeforeCount = $beforeCount
        CompletedCount = $completedCount
        RemainingCount = $remainingCount
        IsComplete = (
            $WinSCPExitCode -eq 0 -and
            $verificationSucceeded -and
            $remainingCount -eq 0
        )
        IsPartial = (
            $verificationSucceeded -and
            $remainingCount -gt 0
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
        Write-Log "AUDIT $ComponentName НЕСУМIСНЕ IМ'Я [$itemType] [$($issue.Utf8ByteCount)/$($issue.MaximumUtf8Bytes) UTF-8 байт] $($issue.Path)" -Level "ERROR" -FileOnly
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
    
    $tempScript = [System.IO.Path]::GetTempFileName() + ".txt"
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
        # Очищаємо тимчасовий файл
        if (Test-Path $tempScript) {
            try {
                Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
                Write-Log "Тимчасовий скрипт видалено: $tempScript" -Level "DEBUG"
            } catch {
                Write-Log "Не вдалося видалити тимчасовий скрипт: $($_.Exception.Message)" -Level "WARNING"
            }
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
        -ComponentName $ComponentName

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

    $tempScript = [System.IO.Path]::GetTempFileName() + ".txt"
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
            -ComponentName $ComponentName

        $syncOutcome = Get-BAZASynchronizationOutcome `
            -WinSCPExitCode $winSCPExitCode `
            -ComparisonBefore $comparisonBefore `
            -ComparisonAfter $comparisonAfter

        if (-not $syncOutcome.VerificationSucceeded) {
            Write-Log "Не вдалося пiдтвердити результат синхронiзацiї $ComponentName повторним порiвнянням; результат вважається помилкою" -Level "ERROR"
            return $false
        }

        if ($null -ne $syncOutcome.CompletedCount) {
            $resultLevel = if ($syncOutcome.IsComplete) {
                "SUCCESS"
            } else {
                "WARNING"
            }
            Write-Log "Результат ${ComponentName}: передано або оновлено об'єктiв: $($syncOutcome.CompletedCount); залишилося несинхронiзованих: $($syncOutcome.RemainingCount)" -Level $resultLevel
        }

        if ($syncOutcome.IsComplete) {
            Write-Log "Каталог $ComponentName повнiстю синхронiзовано з $remotePath" -Level "SUCCESS"
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
            -ComponentName $ComponentName
        return $false
    } finally {
        if ($showWinSCPProgress) {
            Show-RunningProgress -Id 12 -Activity $syncActivity -Completed
        }
        if (Test-Path $tempScript) {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ManualBAZASFTPSynchronization {
    Write-Log "==="
    Write-Log "=== РУЧНА СИНХРОНIЗАЦIЯ BAZA НА SFTP ==="
    Write-Log "Режим -SyncBAZA: архiвацiю, очищення архiвiв, NAS/SMB та health-check пропущено" -Level "INFO"
    Show-ScriptProgress -Status "Ручна синхронiзацiя BAZA на SFTP" -PercentComplete 20

    if (-not (Test-SFTPConfig -BAZAOnly)) {
        Write-Log "Ручну синхронiзацiю BAZA зупинено через помилки конфiгурацiї SFTP" -Level "ERROR"
        return $false
    }

    if (-not (Test-PathWithLog `
        -Path $bazaPaths.Source `
        -Description "Каталог BAZA" `
        -CreateIfMissing $false)) {
        Write-Log "Ручну синхронiзацiю BAZA зупинено: локальний каталог недоступний" -Level "ERROR"
        return $false
    }

    Show-ScriptProgress -Status "Перевiрка з'єднання з SFTP" -PercentComplete 35
    if (-not (Test-NetworkConnection)) {
        Write-Log "Ручну синхронiзацiю BAZA зупинено: мережеве з'єднання недоступне" -Level "ERROR"
        return $false
    }

    if (-not (Test-SFTPConnection `
        -WinSCPPath $winSCPPath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey)) {
        Write-Log "Ручну синхронiзацiю BAZA зупинено: не вдалося пiдключитися до SFTP" -Level "ERROR"
        return $false
    }

    Show-ScriptProgress -Status "Синхронiзацiя BAZA на SFTP" -PercentComplete 55
    $syncSuccess = Sync-FolderToSFTP `
        -WinSCPPath $winSCPPath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey `
        -LocalDirectory $bazaPaths.Source `
        -RemoteDirectory $sftpDirectories.BAZA

    if ($syncSuccess) {
        Write-Log "Ручну синхронiзацiю BAZA на SFTP завершено успiшно" -Level "SUCCESS"
        return $true
    }

    Write-Log "Ручна синхронiзацiя BAZA на SFTP завершилася з помилкою" -Level "ERROR"
    return $false
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

function Get-BRAVOArchiveServiceCandidates {
    $services = New-Object System.Collections.ArrayList
    if ($null -eq $maintenanceSettings -or $null -eq $maintenanceSettings.Services) {
        return @()
    }

    if ([System.Convert]::ToBoolean($maintenanceSettings.Services.BravoWebEnabled)) {
        foreach ($candidate in @($maintenanceSettings.Services.BravoWebCandidates)) {
            $service = Get-Service -Name ([string]$candidate) -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                $service = Get-Service -DisplayName ([string]$candidate) -ErrorAction SilentlyContinue
            }
            if ($null -ne $service) {
                [void]$services.Add($service)
                break
            }
        }
    }

    foreach ($serviceName in @(
            [string]$maintenanceSettings.Services.ExchangeApiName,
            [string]$maintenanceSettings.Services.BravoName
        )) {
        if ([string]::IsNullOrWhiteSpace($serviceName)) {
            continue
        }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service -and
            @($services | Where-Object { $_.Name -ieq $service.Name }).Count -eq 0) {
            [void]$services.Add($service)
        }
    }
    return $services.ToArray()
}

function Stop-BRAVOArchiveSourceServices {
    $quiesceEnabled = (
        $null -ne $maintenanceSettings -and
        $null -ne $maintenanceSettings.Services -and
        $maintenanceSettings.Services.Contains("QuiesceForBackup") -and
        [System.Convert]::ToBoolean($maintenanceSettings.Services.QuiesceForBackup)
    )
    if (-not $quiesceEnabled) {
        Write-Log "Узгоджений backup: зупинку служб вимкнено в config" -Level "WARNING"
        return [pscustomobject]@{ Success = $true; StoppedServices = @() }
    }

    $stopTimeoutSeconds = [math]::Max(
        1,
        [int]$maintenanceSettings.Services.StopTimeoutSeconds
    )
    $stoppedServices = New-Object System.Collections.ArrayList
    try {
        $serviceCandidates = @(Get-BRAVOArchiveServiceCandidates)
        $inactiveServices = @(
            foreach ($service in $serviceCandidates) {
                $service.Refresh()
                if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
                    "$($service.Name) ($($service.Status))"
                }
            }
        )
        Send-BRAVOArchiveInactiveServiceWarning -ServiceDescriptions $inactiveServices

        foreach ($service in $serviceCandidates) {
            $service.Refresh()
            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
                Write-Log "Служба $($service.Name) не працювала; стан не змінюється" -Level "WARNING"
                continue
            }

            Write-Log "Зупинка служби $($service.Name) для узгодженого backup..." -Level "INFO"
            [void]$stoppedServices.Add($service.Name)
            Stop-Service -Name $service.Name -Force -ErrorAction Stop
            $service.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [timespan]::FromSeconds($stopTimeoutSeconds)
            )
            Write-Log "Службу $($service.Name) зупинено" -Level "SUCCESS"
        }
        return [pscustomobject]@{
            Success = $true
            StoppedServices = $stoppedServices.ToArray()
        }
    } catch {
        Write-Log "Не вдалося зупинити служби для узгодженого backup: $($_.Exception.Message)" -Level "ERROR"
        [void](Start-BRAVOArchiveSourceServices -ServiceNames $stoppedServices.ToArray())
        return [pscustomobject]@{
            Success = $false
            StoppedServices = @()
        }
    }
}

function Send-BRAVOArchiveInactiveServiceWarning {
    param([string[]]$ServiceDescriptions)

    $inactiveServices = @($ServiceDescriptions | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | Select-Object -Unique)
    if ($inactiveServices.Count -eq 0) {
        return
    }

    $serviceList = $inactiveServices -join ", "
    Write-Log "До початку backup не запущені служби: $serviceList" -Level "WARNING"
    if ($script:notificationMode -eq "none") {
        Write-Log "Сповіщення про зупинені служби вимкнено режимом none" -Level "INFO"
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($script:notificationCredentialInitializationError)) {
        Write-Log (
            "Не вдалося відправити сповіщення про зупинені служби: " +
            $script:notificationCredentialInitializationError
        ) -Level "ERROR"
        return
    }

    $institutionName = [string]$bravoSettings.InstitutionName
    $institutionCode = [string]$bravoSettings.InstitutionCode
    $message = @(
        "⚠️ СЛУЖБИ НЕ ЗАПУЩЕНІ ПЕРЕД BACKUP",
        "Установа: $institutionName [$institutionCode]",
        "Сервер: $env:COMPUTERNAME",
        "Служби: $serviceList",
        "Скрипт збереже початковий стан і не запускатиме ці служби автоматично.",
        "Час: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    ) -join [Environment]::NewLine

    try {
        Send-BRAVOWebhookNotification `
            -Provider $script:notificationProvider `
            -WebhookUrl $script:notificationWebhookUrl `
            -Message $message `
            -TimeoutSeconds $script:notificationRequestTimeoutSeconds
        Write-Log "Сповіщення про зупинені служби відправлено у $($script:notificationProvider)" -Level "SUCCESS"
    } catch {
        Write-Log "Не вдалося відправити сповіщення про зупинені служби: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Start-BRAVOArchiveSourceServices {
    param([string[]]$ServiceNames)

    $startTimeoutSeconds = [math]::Max(
        1,
        [int]$maintenanceSettings.Services.StartTimeoutSeconds
    )
    $success = $true
    $servicesToStart = @($ServiceNames)
    [array]::Reverse($servicesToStart)
    foreach ($serviceName in $servicesToStart) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            $service.Refresh()
            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
                Write-Log "Відновлення служби $serviceName після локальної архівації..." -Level "INFO"
                Start-Service -Name $serviceName -ErrorAction Stop
                $service.WaitForStatus(
                    [System.ServiceProcess.ServiceControllerStatus]::Running,
                    [timespan]::FromSeconds($startTimeoutSeconds)
                )
            }
            Write-Log "Служба $serviceName працює" -Level "SUCCESS"
        } catch {
            Write-Log "Не вдалося відновити службу ${serviceName}: $($_.Exception.Message)" -Level "ERROR"
            $success = $false
        }
    }
    return $success
}

# =============================================
# ОСНОВНА ЛОГІКА
# =============================================

function Main {
    # Ініціалізація
    $scriptStartTime = Get-Date
    $now = $scriptStartTime.ToString($archiveTimestampFormat)
    $logTimestamp = $scriptStartTime.ToString($logFileDateFormat)
    $global:logFile = Join-Path $logPath ($logFileNameTemplate -f $logTimestamp)
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
        Write-Log "=== ЗАВЕРШЕННЯ РУЧНОЇ СИНХРОНIЗАЦIЇ BAZA ==="
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
    Write-Log "Видалення старих архiвiв: $(if ($enableArchiveDeletion) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
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
    
    Write-Log "==="
    Write-Log "=== ОЧИЩЕННЯ СТАРИХ ЛОГIВ ==="
    Show-ScriptProgress -Status "Очищення старих логiв" -PercentComplete 12
    if (-not (Remove-OldLogsByAge -Path $logPath -Filter $logFileFilter -RetentionDays $logRetentionDays)) {
        $operationFailed = $true
    }
    
    # Перевірка шляхів
    Write-Log "==="
    Write-Log "=== ПЕРЕВIРКА НЕОБХIДНИХ ШЛЯХIВ ==="
    Show-ScriptProgress -Status "Перевiрка необхiдних шляхiв" -PercentComplete 15
    $requiredPaths = @($baseRequiredPaths)
    $archiveToolAvailable = $archiveCredentialValid

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

    $archiveServiceState = [pscustomobject]@{ Success = $true; StoppedServices = @() }
    if ($readyArchives.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ПІДГОТОВКА УЗГОДЖЕНОГО BACKUP ==="
        $archiveServiceState = Stop-BRAVOArchiveSourceServices
    }
    try {
        if (-not $archiveServiceState.Success) {
            Write-Log "Локальну архівацію скасовано: джерела не вдалося перевести в узгоджений стан" -Level "ERROR"
            $operationFailed = $true
        } else {
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
                $success = New-Archive -SourcePath $archive.Source -ArchivePath $archive.Destination -ArchiveName $archiveName -ArcPath $arcPath -ArcParams $archiveParams

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
        }
    } finally {
        if (-not (Start-BRAVOArchiveSourceServices -ServiceNames $archiveServiceState.StoppedServices)) {
            $operationFailed = $true
        }
    }
    Show-ItemProgress -Id 10 -Activity "BRAVO_ARCHIV — архiвацiя компонентiв" -Completed
    
    # Видалення старих архівів
    Show-ScriptProgress -Status "Очищення старих архiвiв" -PercentComplete 72
    Write-Log "==="
    Write-Log "=== ОЧИЩЕННЯ СТАРИХ АРХIВIВ ==="
    if (-not $enableArchiveDeletion) {
        Write-Log "Видалення старих архiвiв вимкнено в налаштуваннях" -Level "INFO"
    } else {
        foreach ($archive in $enabledArchives) {
            if (-not (Remove-OldBackupSets -Path $archive.Destination -KeepCount $archiveVersions -Component $archive.Type)) {
                $operationFailed = $true
            }
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
                Show-ScriptProgress -Status "Завантаження архiвiв на SFTP" -PercentComplete 82
                Write-Log "==="
                Write-Log "=== ЗАВАНТАЖЕННЯ АРХIВIВ НА SFTP ==="
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

        if (Test-Path -Path $backupHealthScriptPath -PathType Leaf) {
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
                $healthCheckResult = & $backupHealthScriptPath @healthParameters
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
                Write-Log "Помилка запуску health-check: $($_.Exception.Message)" -Level "ERROR"
                $operationFailed = $true
            }
        } else {
            Write-Log "Health-check скрипт не знайдено: $backupHealthScriptPath" -Level "ERROR"
            $operationFailed = $true
        }
    }

    Write-Log "Результат: $(if ($operationFailed) {'ПОМИЛКА'} else {'УСПIШНО'})" -NoTimestamp
    Write-Log "==="
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
