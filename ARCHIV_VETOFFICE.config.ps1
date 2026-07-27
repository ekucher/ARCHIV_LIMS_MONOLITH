# Файл конфігурації для ARCHIV_VETOFFICE.ps1
# Версія конфігурації: 1.6

param([string]$ConfigRoot)

if ([string]::IsNullOrWhiteSpace($ConfigRoot)) {
    $ConfigRoot = $PSScriptRoot
}

# =============================================
# ОСНОВНІ НАЛАШТУВАННЯ
# =============================================

# РІВЕНЬ ЛОГУВАННЯ
$global:LogLevel = "INFO"  # Можливі значення: "DEBUG", "INFO", "WARNING", "ERROR", "SUCCESS"

# НАЛАШТУВАННЯ АРХІВАЦІЇ
$global:archivePrefix = "vetcontrol_pnmgu_v2508"  # Префікс для імен архівів
$global:logRetentionDays = 31                     # Кількість днів зберігання лог-файлів
$global:archiveVersions = 31                      # Кількість версій архівів для зберігання
$global:enableArchiveDeletion = $true             # Увімкнути/вимкнути видалення старих архівів
$global:failedArchiveRetentionDays = 30           # Термін зберігання неповних/пошкоджених комплектів
$global:enableFailedArchiveDeletion = $true       # Окреме очищення непридатних комплектів після терміну
$global:enableSFTPUpload = $true                  # Увімкнути/вимкнути завантаження на SFTP сервер
$global:enableNetworkCopy = $true                 # Увімкнути/вимкнути копіювання в мережеву папку

# ВИКЛЮЧЕННЯ КОМПОНЕНТІВ АРХІВАЦІЇ
$global:excludeComponents = @{
    BAZA           = $false  # Вимкнути архівацію та синхронізацію BAZA
    BAZA_Network   = $false  # Вимкнути синхронізацію BAZA в мережу (окрема опція)
    VETOFFICE      = $false  # Вимкнути архівацію VETOFFICE (раніше MODEL)
    Blog           = $false  # Вимкнути архівацію Blog
}

# ВИВІД ІНФОРМАЦІЙНИХ СЕКЦІЙ
$global:showSystemInfo = $false      # Показувати інформацію про операційну систему
$global:showHardwareInfo = $false    # Показувати інформацію про апаратне забезпечення
$global:showPerformanceInfo = $false # Показувати поточне навантаження системи

# ПАРАМЕТРИ АРХІВАЦІЇ (для 7-Zip)
$global:archiveParams = "a -mmt -mx7 -r -y -ssw -scrcSHA256 -bb0 -aoa"
$global:archiveCreationTimeoutSeconds = 14400      # 4 години на створення одного архіву
$global:archiveIntegrityTestTimeoutSeconds = 14400 # 4 години; 0 = без обмеження
$global:sftpOperationTimeoutSeconds = 1800         # 30 хвилин на одну SFTP-операцію
$global:taskExecutionTimeLimitHours = 20           # Дві пари create + 7z t та передача

# Секрети не зберігаються у конфігурації. Заповніть Windows Credential
# Manager через BRAVO_CREDENTIALS_SETUP.cmd із параметром:
# -ConfigPath ".\ARCHIV_VETOFFICE.config.ps1"
$global:credentialSettings = @{
    HelperPath = Join-Path $ConfigRoot "BRAVO_CREDENTIALS.ps1"
    Targets = @{
        ArchivePassword = "VETOFFICE_7Z_PASSWORD"
        SFTPLogin = "VETOFFICE_SFTP_LOGIN"
        SFTPPassword = "VETOFFICE_SFTP_PASSWORD"
        SMBLogin = "VETOFFICE_SMB_LOGIN"
        SMBPassword = "VETOFFICE_SMB_PASSWORD"
        SlackWebhook = "VETOFFICE_SLACK_URL"
        DiscordWebhook = "VETOFFICE_DISCORD_URL"
    }
}

# =============================================
# НАЛАШТУВАННЯ SFTP
# =============================================

$global:sftpHostName = "u295406-sub5.your-storagebox.de"                                  # Сервер SFTP
$global:sftpPort = 22
$global:sftpHostKey = "`"ssh-rsa 2048 3d:7b:6f:99:5f:68:53:21:73:15:f9:2e:6b:3a:9f:e3`""  # Ключ хоста SFTP

# =============================================
# НАЛАШТУВАННЯ МЕРЕЖЕВОЇ ПАПКИ (SAMBA)
# =============================================

$global:NetworkPath = "\\Synology1221\Bravo\"    # Базовий шлях до мережевої папки
$global:networkCopyConfig = @{
    Enabled = $enableNetworkCopy                 # Увімкнути/вимкнути копіювання в мережу
    NetworkPath = $NetworkPath                   # Шлях до мережевої папки
    Username = $null                             # Завантажується з Credential Manager
    Password = $null                             # Завантажується з Credential Manager
    MaxRetries = 3                               # Кількість спроб підключення
    RetryDelay = 5                               # Затримка між спробами (секунди)
}

# =============================================
# ШЛЯХИ ДО ДЖЕРЕЛ ДАНИХ
# =============================================

# Автоматичне визначення кореневого каталогу VETOFFICE
$global:scriptPath = $ConfigRoot                         # Шлях до каталогу скрипта
$global:VETOFFICE_PATH = Split-Path $scriptPath -Parent  # Батьківський каталог (корінь VETOFFICE)
$global:rootPath = $VETOFFICE_PATH                       # Кореневий шлях для архівації

# ДЖЕРЕЛА ДАНИХ ДЛЯ АРХІВАЦІЇ
$global:sourcePaths = @{
    Model = Join-Path $rootPath "Model\*"                # Шлях до каталогу Model
    Blog = Join-Path $rootPath "BLOG\*"                  # Шлях до каталогу Blog
}

# =============================================
# КАТАЛОГИ ПРИЗНАЧЕННЯ
# =============================================

$global:archivPath = Join-Path $rootPath "ARCHIV"        # Основний каталог для архівів
$global:toolsPath = Join-Path $archivPath "Tools"        # Каталог для інструментів (7-Zip, WinSCP)
$global:logPath = Join-Path $archivPath "LOGS"           # Каталог для лог-файлів

# КАТАЛОГИ ДЛЯ ЗБЕРІГАННЯ АРХІВІВ
$global:archiveDirs = @{
    Model = Join-Path $archivPath "VETOFFICE"            # Каталог для архівів VETOFFICE
    Blog = Join-Path $archivPath "BLOG"                  # Каталог для архівів Blog
}

# ШЛЯХИ ДЛЯ СИНХРОНІЗАЦІЇ BAZA
$global:bazaPaths = @{
    Source = "C:\Br-a-vo.web\www\BAZA"                   # Джерельна папка BAZA
    Destination_Local = Join-Path $archivPath "BAZA"     # Папка для локальної синхронізованої копії BAZA
    Destination_Network = Join-Path $NetworkPath "BAZA"  # Папка для мережевої синхронізованої копії BAZA
}

# =============================================
# НАЛАШТУВАННЯ SFTP КАТАЛОГІВ
# =============================================

$global:sftpDirectories = @{
    Model = "archiv"  # Віддалений каталог для архівів VETOFFICE
    Blog = "blog"     # Віддалений каталог для архівів Blog
}

# Мінімальні секції для BRAVO_CREDENTIALS_SETUP.ps1.
$global:componentSettings = @{
    Archive = @{ MODEL = -not $excludeComponents.VETOFFICE; BLOG = -not $excludeComponents.Blog; BRAVOEXCH = $false }
    Synchronization = @{ BAZALocal = -not $excludeComponents.BAZA; BAZASFTP = $false }
    SFTP = @{ ArchiveUpload = $enableSFTPUpload }
    SMB = @{ ArchiveCopy = $enableNetworkCopy }
}
$global:backupMonitoring = @{ SFTP = @{ Enabled = $false } }
$global:bravoSettings = @{ NotificationMode = "none"; NotificationProvider = "discord" }
$global:schedulerSettings = @{ RunAsUser = "SYSTEM"; LogonType = "ServiceAccount" }
