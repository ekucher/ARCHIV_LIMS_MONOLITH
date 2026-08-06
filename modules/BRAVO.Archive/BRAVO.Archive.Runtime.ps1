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
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveRuntime', 'BRAVO.Logging', 'BRAVO.Console', 'BRAVO.ExitCodes')) {
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
    Write-Host "ПОМИЛКА: Не вдалося завантажити конфiгурацiю: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -ForegroundColor Red
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
    [bool]$componentSettings.Synchronization.BAZA_APP_SFTP -or
    [bool]$componentSettings.Synchronization.BAZA_WWW_SFTP
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
        # Маскується одразу при захопленні (а не лише при виведенні), щоб
        # жодне подальше читання цих script-scope змінних — консоль, лог,
        # повідомлення — не могло випадково пропустити секрет, який .NET
        # інколи вбудовує прямо в текст виключення Credential Manager.
        $sanitizedCredentialError = Protect-BRAVOLogSecret -Text $_.Exception.Message
        if ($sftpCredentialRequired) {
            $script:credentialInitializationError = $sanitizedCredentialError
        }
        if ($archiveCredentialRequired) {
            $script:archiveCredentialInitializationError = $sanitizedCredentialError
        }
        if ($smbCredentialRequired) {
            $script:smbCredentialInitializationError = $sanitizedCredentialError
        }
        if ($institutionSettingsRequired) {
            $script:institutionSettingsInitializationError = $sanitizedCredentialError
        }
        if ($notificationCredentialRequired) {
            $script:notificationCredentialInitializationError = $sanitizedCredentialError
        }
    }
}

# Ручний запуск (не через Планувальник) з відсутнiми обов'язковими
# обліковими даними — пропонуємо налаштувати їх зараз (лише для
# ПОТОЧНОГО користувача) замiсть того, щоб просто впасти з помилкою й
# змусити шукати окремий скрипт. -StoreFor CurrentUser навмисно: обліковi
# данi облiкового запису запланованого завдання (SYSTEM) налаштовуються
# окремо й свiдомо через BRAVO_SETUP.ps1/BRAVO_CREDENTIALS_SETUP.ps1
# -StoreFor ScheduledTaskAccount — тут ми їх не чіпаємо.
#
# -NoPause і перевірки нижче — той самий "чи це людина за клавіатурою"
# сигнал, що вже охороняє Wait-BRAVOManualExit: SYSTEM-завдання завжди
# передає -NoPause, а IsInputRedirected ловить дочірні процеси
# автоматизації (самотест, CI), які успадкували консоль батьківського
# процесу, але не мають кому відповідати на Read-Host.
if ($credentialHelperLoaded -and -not $NoPause -and
    ($archiveCredentialRequired -or $sftpCredentialRequired)) {
    $missingRequiredCredentialTargets = New-Object System.Collections.Generic.List[string]
    if ($archiveCredentialRequired) {
        $checkTarget = [string]$credentialSettings.Targets.ArchivePassword
        if ([string]::IsNullOrWhiteSpace($checkTarget)) { $checkTarget = "BRAVO_7Z_PASSWORD" }
        if ([string]::IsNullOrWhiteSpace((Get-BRAVOCredentialSecret -Target $checkTarget))) {
            [void]$missingRequiredCredentialTargets.Add($checkTarget)
        }
    }
    if ($sftpCredentialRequired) {
        $checkLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
        if ([string]::IsNullOrWhiteSpace($checkLoginTarget)) { $checkLoginTarget = "BRAVO_SFTP_LOGIN" }
        $checkPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
        if ([string]::IsNullOrWhiteSpace($checkPasswordTarget)) { $checkPasswordTarget = "BRAVO_SFTP_PASSWORD" }
        if ([string]::IsNullOrWhiteSpace((Get-BRAVOCredentialSecret -Target $checkLoginTarget))) {
            [void]$missingRequiredCredentialTargets.Add($checkLoginTarget)
        }
        if ([string]::IsNullOrWhiteSpace((Get-BRAVOCredentialSecret -Target $checkPasswordTarget))) {
            [void]$missingRequiredCredentialTargets.Add($checkPasswordTarget)
        }
    }

    if ($missingRequiredCredentialTargets.Count -gt 0) {
        $isRealInteractiveSession = $false
        try {
            $isRealInteractiveSession = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        } catch {
            $isRealInteractiveSession = $false
        }
        if ($isRealInteractiveSession) {
            Write-Host ""
            Write-Host "Вiдсутнi обов'язковi облiковi данi: $($missingRequiredCredentialTargets -join ', ')" -ForegroundColor $logColors.WARNING
            Write-Host "Запускаю налаштування для поточного користувача ($([Security.Principal.WindowsIdentity]::GetCurrent().Name))..." -ForegroundColor $logColors.WARNING
            $credentialsSetupPath = Join-Path $bravoScriptDirectory 'BRAVO_CREDENTIALS_SETUP.ps1'
            if (Test-Path -LiteralPath $credentialsSetupPath -PathType Leaf) {
                # Окремий процес, не dot-source/&: BRAVO_CREDENTIALS_SETUP.ps1
                # сам виконує повне завантаження BRAVO.config і перезаписав
                # би глобальний стан (pathSettings, componentSettings тощо)
                # цього процесу — ізоляція важливіша за швидкість запуску.
                & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                    -File $credentialsSetupPath `
                    -ConfigPath $ConfigPath `
                    -Action Ensure `
                    -Component Required `
                    -StoreFor CurrentUser
            } else {
                Write-Host "Не знайдено BRAVO_CREDENTIALS_SETUP.ps1 — налаштуйте облiковi данi вручну." -ForegroundColor $logColors.WARNING
            }
        }
    }
}

if ($credentialHelperLoaded) {
    try {
        [void](Import-BRAVOInstitutionSettings `
            -CredentialSettings $credentialSettings `
            -BravoSettings $bravoSettings)
    } catch {
        Write-Host "ПОМИЛКА: Некоректні локальні параметри установи у Credential Manager: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" `
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
        $script:archiveCredentialInitializationError = Protect-BRAVOLogSecret -Text $_.Exception.Message
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
        $script:credentialInitializationError = Protect-BRAVOLogSecret -Text $_.Exception.Message
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
        # SecureString, не рядок: далі потрібен лише PSCredential, тому
        # плейнтекст пароля SMB не створюється взагалі (аудит #5).
        $storedSmbPassword = Get-BRAVOCredentialSecureSecret -Target $smbPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSmbLogin)) {
            throw "запис Credential Manager '$smbLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ($null -eq $storedSmbPassword -or $storedSmbPassword.Length -eq 0) {
            throw "запис Credential Manager '$smbPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $script:smbCredential = New-BRAVOSecureCredential `
            -UserName ([string]$storedSmbLogin) `
            -SecureSecret $storedSmbPassword
        $storedSmbLogin = $null
        $storedSmbPassword = $null
    } catch {
        $script:smbCredentialInitializationError = Protect-BRAVOLogSecret -Text $_.Exception.Message
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
        $script:notificationCredentialInitializationError = Protect-BRAVOLogSecret -Text $_.Exception.Message
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
    Write-BRAVOLog -Component 'STARTUP' -Message "Перевiрка сумiсностi системи..." -Level "INFO"
    $compatibility = Get-BRAVOCompatibilityInfo
    $powerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
    $windowsPatchLevel = Get-BRAVOWindowsPatchLevelRecommendation
    $script:BRAVOCompatibility = $compatibility
    $script:BRAVOPowerShellUpdate = $powerShellUpdate
    $script:BRAVOWindowsPatchLevel = $windowsPatchLevel

    $script:hasFileHash = $compatibility.FileHashProvider -eq "Get-FileHash"
    $script:hasNetConnection = $compatibility.NetworkProvider -eq "Test-NetConnection"
    $script:compatibilityMode = [bool]$compatibility.IsCompatibilityMode

    Write-BRAVOLog -Component 'STARTUP' -Message "Windows: $($BRAVOCompatibility.WindowsVersion); PowerShell: $($BRAVOCompatibility.PowerShellVersion)" -Level "DEBUG"
    Write-BRAVOLog -Component 'STARTUP' -Message "WMI: $($BRAVOCompatibility.WmiProvider); Hash: $($BRAVOCompatibility.FileHashProvider); Network: $($BRAVOCompatibility.NetworkProvider); Files: $($BRAVOCompatibility.ChildItemProvider)" -Level "DEBUG"

    if ($script:compatibilityMode) {
        Write-BRAVOLog -Component 'STARTUP' -Message "Режим сумiсностi активний: несумiснi сучаснi API буде автоматично замiнено" -Level "INFO"
    } else {
        Write-BRAVOLog -Component 'STARTUP' -Message "Стандартний режим" -Level "INFO"
    }
    if ($powerShellUpdate.IsUpdateRecommended) {
        Write-BRAVOLog -Component 'STARTUP' -Message $powerShellUpdate.Message -Level "WARNING"
    }
    if ($windowsPatchLevel.IsUpdateRecommended) {
        Write-BRAVOLog -Component 'STARTUP' -Message $windowsPatchLevel.Message -Level "WARNING"
    }

    $osSupportTier = Get-BRAVOOSSupportTier
    $script:BRAVOOSSupportTier = $osSupportTier
    Write-BRAVOLog -Component 'STARTUP' -Message "Підтримка ОС: $($osSupportTier.Tier) — Windows $($osSupportTier.OperatingSystem) ($($osSupportTier.OperatingSystemVersion), build $($osSupportTier.Build)); PowerShell $($osSupportTier.PowerShellVersion); .NET release $($osSupportTier.DotNetRelease)" -Level "INFO"
    if ($osSupportTier.Tier -eq "LegacyBestEffort") {
        Write-BRAVOLog -Component 'STARTUP' -Message $osSupportTier.Message -Level "WARNING"
    } elseif ($osSupportTier.Tier -eq "Unsupported") {
        if ($env:BRAVO_ALLOW_UNSUPPORTED_OS -eq "1") {
            Write-BRAVOLog -Component 'STARTUP' -Message "$($osSupportTier.Message) Продовжено через BRAVO_ALLOW_UNSUPPORTED_OS=1." -Level "WARNING"
        } else {
            Write-BRAVOLog -Component 'STARTUP' -Message $osSupportTier.Message -Level "ERROR"
            exit (Resolve-BRAVOExitCode -InvalidConfiguration)
        }
    }

    # $arcPath/$winSCPPath/$winSCPAssemblyPath доступні лише після
    # Import-BravoConfiguration, тому цю перевірку не можна винести у
    # ранній preinit разом із двома вище.
    $toolIntegrity = Get-BRAVOToolIntegrityRecommendation `
        -ToolPaths @($arcPath, $winSCPPath, $winSCPAssemblyPath) `
        -ManifestPath (Join-Path $toolsPath "TOOLS_INTEGRITY.json")
    $script:BRAVOToolIntegrity = $toolIntegrity
    if ($toolIntegrity.HasIntegrityIssue) {
        Write-BRAVOLog -Component 'STARTUP' -Message $toolIntegrity.Message -Level "WARNING"
    }

    # Еталонний маніфест (version-controlled) — на відміну від
    # TOFU-базової лінії вище, він здатний ЗАБЛОКУВАТИ запуск. Це
    # найважливіша перевірка старту: заплановане завдання виконується від
    # NT AUTHORITY\SYSTEM, тому підмінений 7za.exe/WinSCP.com отримав би
    # найвищі права в системі.
    $manifestMode = 'Enforce'
    $manifestPath = Join-Path $toolsPath "TOOLS_MANIFEST.json"
    if ($toolIntegritySettings -is [System.Collections.IDictionary]) {
        if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.Mode)) {
            $manifestMode = [string]$toolIntegritySettings.Mode
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.ManifestPath)) {
            $manifestPath = [string]$toolIntegritySettings.ManifestPath
        }
    }

    # BRAVO.config не входить до RUNTIME_MANIFEST.json (він
    # сервер-специфічний, спільного еталонного хешу не існує), тому
    # послаблення захисту через один рядок конфігурації має бути
    # принаймні гучним у лозі, а не тихим.
    if ($manifestMode -ne 'Enforce') {
        Write-BRAVOLog -Component 'STARTUP' -Message (
            "УВАГА: перевірку цілісності інструментів послаблено в конфігурації " +
            "(toolIntegritySettings.Mode = $manifestMode). Підміна 7za/WinSCP НЕ заблокує запуск. " +
            "Це тимчасовий режим міграції, не для постійної експлуатації."
        ) -Level "WARNING"
    }

    $script:BRAVOToolManifest = Test-BRAVOToolManifestIntegrity `
        -ToolsDirectory $toolsPath `
        -ManifestPath $manifestPath `
        -Mode $manifestMode

    if (-not $script:BRAVOToolManifest.IsValid) {
        $manifestLevel = if ($script:BRAVOToolManifest.ShouldBlock) { "ERROR" } else { "WARNING" }
        Write-BRAVOLog -Component 'STARTUP' -Message $script:BRAVOToolManifest.Message -Level $manifestLevel

        if ($script:BRAVOToolManifest.ShouldBlock) {
            Send-ToolIntegrityAlert -Result $script:BRAVOToolManifest
            exit (Resolve-BRAVOExitCode -ToolIntegrityViolation)
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$script:BRAVOToolManifest.Message)) {
        Write-BRAVOLog -Component 'STARTUP' -Message $script:BRAVOToolManifest.Message -Level "WARNING"
    }

    return $compatibility
}

function Send-ToolIntegrityAlert {
    param([Parameter(Mandatory = $true)]$Result)

    # Критичне сповіщення надсилається незалежно від NotifyOnSuccess та
    # інших "тихих" режимів: це подія безпеки, а не рутинний статус
    # backup. Єдине, що її придушує, — явно вимкнені сповіщення
    # (-NoSlack / notificationMode = none) або ненастроєний webhook.
    if ($NoSlack -or $script:notificationMode -eq "none") {
        Write-BRAVOLog -Component 'STARTUP' -Message "Критичне сповіщення про цілісність інструментів не відправлено: сповіщення вимкнено параметрами запуску або конфігурацією" -Level "WARNING"
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:notificationWebhookUrl)) {
        Write-BRAVOLog -Component 'STARTUP' -Message "Критичне сповіщення про цілісність інструментів не відправлено: webhook не налаштовано" -Level "WARNING"
        return
    }

    try {
        $hostInformation = Get-HostInformation
        $alertText = @(
            ":rotating_light: КРИТИЧНО: порушено цілісність інструментів BRAVO",
            "Сервер: $($hostInformation.MachineName) (IP: $($hostInformation.LocalIP))",
            "Час: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "",
            [string]$Result.Message,
            "",
            "Архівацію НЕ виконано (код завершення 32)."
        ) -join "`n"

        # Discord потребує власного форматування й обмежений довжиною
        # повідомлення; Slack приймає текст як є.
        $outboundMessages = if ($script:notificationProvider -eq "discord") {
            @(Split-DiscordNotificationText -Message (ConvertTo-DiscordNotificationText -Message $alertText))
        } else {
            @($alertText)
        }
        foreach ($outboundMessage in $outboundMessages) {
            Send-BRAVOWebhookNotification `
                -Provider $script:notificationProvider `
                -WebhookUrl $script:notificationWebhookUrl `
                -Message $outboundMessage `
                -TimeoutSeconds $script:notificationRequestTimeoutSeconds
        }
        Write-BRAVOLog -Component 'STARTUP' -Message "Критичне сповіщення про цілісність інструментів відправлено у $($script:notificationProviderDisplayName)" -Level "SUCCESS"
    } catch {
        # Неможливість сповістити не змінює рішення блокувати запуск.
        Write-BRAVOLog -Component 'STARTUP' -Message "Не вдалося відправити критичне сповіщення про цілісність інструментів: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)" -Level "ERROR"
    }
}

function New-SHA512HashLegacy {
    param(
        [string]$FilePath,
        [string]$HashFilePath
    )
    
    Write-BRAVOLog -Component 'HASH' -Message "Створення SHA512 хешу (сумiсний режим): $(Split-Path $FilePath -Leaf)"
    
    if (-not (Test-Path $FilePath)) {
        Write-BRAVOLog -Component 'HASH' -Message "Файл не знайдено: $FilePath" -Level "ERROR"
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
        
        Write-BRAVOLog -Component 'HASH' -Message "Хеш створено (сумiсний режим): $HashFilePath" -Level "SUCCESS"
        return $true
    } catch {
        Write-BRAVOLog -Component 'HASH' -Message "Помилка створення хешу (сумiсний режим): $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($hasher) { $hasher.Dispose() }
    }
}

function Test-NetworkConnectionLegacy {
    try {
        Write-BRAVOLog -Component 'NETWORK' -Message "Перевiрка мережевого з'єднання (сумiсний режим)..." -Level "DEBUG"
        
        # Альтернативнi методи перевiрки мережi
        $ping = New-Object System.Net.NetworkInformation.Ping
        $result = $ping.Send($networkCheckHost, $networkPingTimeoutMilliseconds)
        
        if ($result.Status -eq "Success") {
            Write-BRAVOLog -Component 'NETWORK' -Message "Мережеве з'єднання доступне (сумiсний режим)" -Level "SUCCESS"
            return $true
        } else {
            Write-BRAVOLog -Component 'NETWORK' -Message "Мережеве з'єднання недоступне (сумiсний режим)" -Level "ERROR"
            return $false
        }
    } catch {
        Write-BRAVOLog -Component 'NETWORK' -Message "Помилка перевiрки мережевого з'єднання (сумiсний режим): $($_.Exception.Message)" -Level "ERROR"
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

# Main — лінійний оркестратор, поділений заголовками "=== СЕКЦІЯ ===".
# Заголовок уже несе семантику етапу, тому компонент виводиться з нього:
# так усі записи секції потрапляють у потрібну колонку без правки викликів.
# Порядок перевірок важливий: "СИНХРОНIЗАЦIЯ BAZA НА SFTP" має дати SFTP,
# а не BAZA. У текстах співіснують кирилична 'І' та латинська 'I'.
function Resolve-BRAVOLogComponentFromHeader {
    param([Parameter(Mandatory = $true)][string]$Header)

    switch -regex ($Header) {
        'SFTP|BAZA_APP'                 { return 'SFTP' }
        'SMB|NAS'                       { return 'SMB' }
        '(?i)АРХ[IІ]ВАЦ[IІ]Я'           { return 'ARCHIVE' }
        '(?i)ХЕШУ'                      { return 'HASH' }
        '(?i)ЛОГ[IІ]В'                  { return 'CLEANUP' }
        '(?i)ШЛЯХ[IІ]В'                 { return 'PATHS' }
        '(?i)ПАРОЛЯ'                    { return 'CREDENTIALS' }
        '(?i)УЗГОДЖЕНОСТ[IІ]'           { return 'VSS' }
        '(?i)СУМ[IІ]СНОСТ[IІ]'          { return 'STARTUP' }
        '(?i)РЕЗЕРВНИХ КОП[IІ]Й'        { return 'HEALTH' }
        '(?i)ЗАВЕРШЕННЯ РОБОТИ'         { return 'SUMMARY' }
        '(?i)ПОЧАТОК РОБОТИ|ОПЦ[IІ]Ї'   { return 'STARTUP' }
        '(?i)BAZA'                      { return 'BAZA' }
    }
    return 'ARCHIVE'
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
        $component = Resolve-BRAVOLogComponentFromHeader -Header $Message
        Set-BRAVOLogComponent -Component $component
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

# Усі три історичні хелпери прогресу тепер малюють одну смугу
# (BRAVO.Console). Раніше загальна й покомпонентна смуги дублювали одна одну,
# а індикатор 7-Zip додавав третій вкладений рівень.
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
        Complete-BRAVOProgress
        return
    }

    Write-BRAVOProgressPhase -Phase $Status -PercentComplete $PercentComplete
}

# Покомпонентна смуга повністю дублювала загальну ("MODEL (1 з 3)" в обох),
# тому вона більше нічого не малює. Сигнатуру збережено, щоб не правити
# десятки викликів у бізнес-логіці.
function Show-ItemProgress {
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Item,
        [int]$Current,
        [int]$Total,
        [switch]$Completed
    )

    return
}

# Нумерація етапів операційної консолі: [1/6], [2/6], ...
# Загальна кількість рахується на старті за увімкненими компонентами, тому
# вимкнений SFTP чи NAS не створює порожніх етапів.
$script:BRAVOStepCurrent = 0
$script:BRAVOStepTotal = 0

function Initialize-BRAVOArchiveSteps {
    param([Parameter(Mandatory = $true)][int]$Total)

    $script:BRAVOStepCurrent = 0
    $script:BRAVOStepTotal = [Math]::Max(1, $Total)
}

function Write-BRAVOArchiveStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('OK', 'SKIPPED', 'WARNING', 'ERROR')]
        [string]$Status = 'OK',
        [string]$Details
    )

    $script:BRAVOStepCurrent++
    Write-BRAVOStepResult `
        -Current $script:BRAVOStepCurrent `
        -Total $script:BRAVOStepTotal `
        -Name $Name `
        -Status $Status `
        -Details $Details
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

    # Деталь операції дописується до поточної фази на тій самій смузі, тому
    # завершення операції лише прибирає деталь, а не гасить увесь індикатор.
    if ($Completed) {
        Write-BRAVOProgressDetail -Detail ''
        return
    }

    Write-BRAVOProgressDetail -Detail $Status
}

function Wait-ForManualExit {
    # Спільна реалізація — modules\BRAVO.Console\BRAVO.Console.psm1. Той
    # самий механізм (RawUI.ReadKey з фолбеком на Read-Host для ISE) тепер
    # використовують і Health, і Maintenance; тут лишається тонка обгортка
    # заради стабільності єдиного виклику нижче (рядок ~4230).
    Wait-BRAVOManualExit -NoPause:$NoPause
}

function Test-PathWithLog {
    param(
        [string]$Path,
        [string]$Description,
        [bool]$CreateIfMissing = $false
    )

    if (Test-Path $Path) {
        Write-BRAVOLog -Component 'PATHS' -Message "$Description знайдено: $Path" -Level "DEBUG"
        return $true
    } else {
        # Створення дозволяється лише для явно позначених каталогів призначення.
        if ($CreateIfMissing) {
            try {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
                Write-BRAVOLog -Component 'PATHS' -Message "$Description не знайдено, створено автоматично: $Path" -Level "SUCCESS"
                return $true
            } catch {
                Write-BRAVOLog -Component 'PATHS' -Message "$Description не знайдено i не вдалося створити: $Path" -Level "ERROR"
                return $false
            }
        } else {
            Write-BRAVOLog -Component 'PATHS' -Message "$Description не знайдено: $Path" -Level "ERROR"
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
        Write-BRAVOLog -Component 'PATHS' -Message "Всi необхiднi шляхи перевiрено успiшно" -Level "SUCCESS"
    } else {
        Write-BRAVOLog -Component 'PATHS' -Message "Знайдено помилки в шляхах - див. вище" -Level "ERROR"
    }
}

function Show-ArchiveCleanupSection {
    param([ref]$SectionShown)

    if (-not $SectionShown.Value) {
        Write-BRAVOLog -Component 'CLEANUP' -Message "==="
        Write-BRAVOLog -Component 'CLEANUP' -Message "=== ОЧИЩЕННЯ СТАРИХ АРХIВIВ ==="
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
        Write-BRAVOLog -Component 'CLEANUP' -Message "Шлях архівів не знайдено: $Path" -Level "WARNING"
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
                Write-BRAVOLog -Component 'CLEANUP' -Message "Видалення непридатного комплекту ${Component}, старшого за $invalidRetentionDays днів: $($archive.Name) — $invalidReason" -Level "WARNING"
                Remove-Item -LiteralPath $archive.FullName -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
                    Remove-Item -LiteralPath $hashPath -Force -ErrorAction Stop
                }
            } else {
                Write-BRAVOLog -Component 'CLEANUP' -Message "Непридатний комплект збережено для діагностики: $($archive.Name) — $invalidReason" -Level "WARNING"
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
                Write-BRAVOLog -Component 'CLEANUP' -Message "Видалено застарілий hash-файл без архіву: $($orphanHash.Name)" -Level "WARNING"
            }
        }

        if (-not $enableArchiveDeletion) {
            return $true
        }

        # Зберігання коректних комплектів визначається календарним віком, а не
        # кількістю запусків: додатковий ручний бекап не скорочує строк зберігання.
        #
        # Інваріант (аудит P1.7): retention, прив'язаний лише до днів, міг
        # видалити останні перевірені покоління після серії невдалих backup,
        # якщо всі valid-комплекти виявлялись старшими за cutoff. $validSets
        # уже відсортовано за спаданням LastWriteTime (найновіші перші), тому
        # Select-Object -Skip лишає N найновіших недоторканими незалежно від
        # їхнього віку.
        $minimumRetainedCount = if ($null -ne $minimumRetainedVerifiedBackups -and
            [int]$minimumRetainedVerifiedBackups -gt 0) {
            [int]$minimumRetainedVerifiedBackups
        } else {
            1
        }
        $protectedSets = @($validSets | Select-Object -First $minimumRetainedCount)
        $deletionCandidates = @($validSets | Select-Object -Skip $minimumRetainedCount)
        $protectedFromExpiry = @($protectedSets | Where-Object {
            $_.Archive.LastWriteTime -lt $validCutoff
        })
        foreach ($protectedSet in $protectedFromExpiry) {
            Write-BRAVOLog -Component 'CLEANUP' -Message "Комплект ${Component} старший за $validRetentionDays днів, але збережений — це одна з останніх $minimumRetainedCount перевірених копій: $($protectedSet.Archive.Name)" -Level "WARNING"
        }
        $setsToDelete = @($deletionCandidates | Where-Object {
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
                Write-BRAVOLog -Component 'CLEANUP' -Message "Архів видалено, але не вдалося видалити його hash-файл $($set.HashPath): $($_.Exception.Message)" -Level "WARNING"
            }
            Write-BRAVOLog -Component 'CLEANUP' -Message "Видалено комплект ${Component}, старший за $validRetentionDays днів: $($set.Archive.Name)" -Level "SUCCESS"
        }
        return $true
    } catch {
        Write-BRAVOLog -Component 'CLEANUP' -Message "Помилка очищення комплектів ${Component}: $($_.Exception.Message)" -Level "ERROR"
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
        Write-BRAVOLog -Component 'CLEANUP' -Message "Каталог обідніх архівів не знайдено: $ArchiveRoot" -Level "ERROR"
        return $false
    }

    $resolvedArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
    $effectiveRetentionMonths = [Math]::Max(1, $RetentionMonths)
    $cutoff = (Get-Date).AddMonths(-$effectiveRetentionMonths)
    $failed = $false
    $deletedCount = 0

    Write-BRAVOLog -Component 'CLEANUP' -Message "==="
    Write-BRAVOLog -Component 'CLEANUP' -Message "=== ОЧИЩЕННЯ СТАРИХ ОБІДНІХ АРХІВІВ ==="
    Write-BRAVOLog -Component 'CLEANUP' -Message "Дата відсічення: $cutoff; маркер імені: _1300." -Level "INFO"

    foreach ($directory in @($Directories | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })) {
        $directoryPath = Join-Path -Path $resolvedArchiveRoot -ChildPath $directory
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            Write-BRAVOLog -Component 'CLEANUP' -Message "Каталог обідніх архівів не знайдено: $directoryPath" -Level "WARNING"
            $failed = $true
            continue
        }
        $resolvedDirectoryPath = (Resolve-Path -LiteralPath $directoryPath -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
        $archiveRootPrefix = $resolvedArchiveRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedDirectoryPath.StartsWith($archiveRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Write-BRAVOLog -Component 'CLEANUP' -Message "Небезпечний каталог очищення поза ArchiveRoot пропущено: $directory" -Level "ERROR"
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
                Write-BRAVOLog -Component 'CLEANUP' -Message "Неповний обідній комплект залишено без змін: $setName" -Level "WARNING"
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
                Write-BRAVOLog -Component 'CLEANUP' -Message "Видалено обідній комплект: $setName і $($archiveSet.Hash.Name)" -Level "SUCCESS"
            } catch {
                $failed = $true
                Write-BRAVOLog -Component 'CLEANUP' -Message "Не вдалося видалити обідній комплект ${setName}: $($_.Exception.Message)" -Level "ERROR"
            }
        }

        Write-BRAVOLog -Component 'CLEANUP' -Message "Каталог ${directory}: видалено $directoryDeletedCount обідніх файлів" -Level "INFO"
    }

    Write-BRAVOLog -Component 'CLEANUP' -Message "Усього видалено обідніх файлів: $deletedCount" -Level "INFO"
    return (-not $failed)
}



function Sync-Folders {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    
    Write-BRAVOLog -Component 'BAZA' -Message "Синхронiзацiя: $SourcePath -> $DestinationPath"
    
    if (-not (Test-Path $SourcePath)) {
        Write-BRAVOLog -Component 'BAZA' -Message "Джерельна папка не знайдена: $SourcePath" -Level "ERROR"
        return $false
    }
    
    try {
        # Створюємо цільову папку, якщо не існує
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Write-BRAVOLog -Component 'BAZA' -Message "Створено цiльову папку: $DestinationPath" -Level "SUCCESS"
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
        
        Write-BRAVOLog -Component 'BAZA' -Message "Виконання: robocopy $robocopyArgs" -Level "DEBUG"

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
            Write-BRAVOLog -Component 'BAZA' -Message "Синхронiзацiя успiшна (код: $exitCode)" -Level "DEBUG"
            return $true
        } else {
            Write-BRAVOLog -Component 'BAZA' -Message "Помилка синхронiзацiї (код: $exitCode)" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-BRAVOLog -Component 'BAZA' -Message "Помилка синхронiзацiї: $($_.Exception.Message)" -Level "ERROR"
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
            Write-BRAVOLog -Component 'ARCHIVE' -Message "${Operation}: $($line.Trim().Substring(0, [math]::Min(4000, $line.Trim().Length)))" -Level 'DEBUG'
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

    # Явне квотування обох шляхів усередині рядка, який отримує cmd.exe /c
    # — $linkPath (%TEMP%) і $target (VSS DeviceObject) на практиці не
    # містять пробілів, але без лапок cmd.exe розбив би аргумент на кілька
    # токенів, якби це колись змінилось (інший профіль/мапований диск).
    $quotedLinkPath = '"' + $linkPath + '"'
    $quotedTarget = '"' + $target + '"'
    $mklinkOutput = & cmd.exe /c mklink /d $quotedLinkPath $quotedTarget 2>&1
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
        Write-BRAVOLog -Component 'VSS' -Message "Не вдалося прибрати символiчне посилання на VSS-знiмок: $LinkPath ($($_.Exception.Message))" -Level "WARNING"
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
        Write-BRAVOLog -Component 'VSS' -Message "Створення VSS-знімка тому $volumeRoot для узгодженої архівації" -Level "INFO"
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
        Write-BRAVOLog -Component 'VSS' -Message "VSS-знімок створено: $shadowId" -Level "SUCCESS"
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
        Write-BRAVOLog -Component 'VSS' -Message "Не вдалося прибрати символiчне посилання на VSS-знiмок $($Snapshot.Id): $($_.Exception.Message)" -Level "WARNING"
    }

    try {
        $deleteResult = $Snapshot.WmiObject.Delete()
        if ($null -ne $deleteResult -and [int]$deleteResult.ReturnValue -ne 0) {
            $returnCode = [int]$deleteResult.ReturnValue
            $description = Get-BRAVOVSSReturnCodeDescription -ReturnCode $returnCode
            Write-BRAVOLog -Component 'VSS' -Message "Не вдалося видалити VSS-знімок $($Snapshot.Id): код $returnCode ($description)" -Level "ERROR"
            return $false
        }
        Write-BRAVOLog -Component 'VSS' -Message "VSS-знімок видалено: $($Snapshot.Id)" -Level "SUCCESS"
        return $true
    } catch {
        Write-BRAVOLog -Component 'VSS' -Message "Не вдалося видалити VSS-знімок $($Snapshot.Id): $($_.Exception.Message)" -Level "ERROR"
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
    
    Write-BRAVOLog -Component 'ARCHIVE' -Message "Створення архiву: $ArchiveName"
    
    $archiveDir = Split-Path $ArchivePath -Parent
    if (-not (Test-Path $archiveDir)) {
        try {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Каталог створено: $archiveDir" -Level "SUCCESS"
        } catch {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка при створеннi каталогу: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }
    
    if (-not (Test-Path $SourcePath)) {
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Джерело не знайдено: $SourcePath" -Level "ERROR"
        return $false
    }
    
    $fullArchivePath = Join-Path $ArchivePath $ArchiveName
    
    try {
        if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Пароль архiву не завантажено з Windows Credential Manager" -Level "ERROR"
            return $false
        }
        if ($script:archivePassword.IndexOfAny([char[]]"`r`n") -ge 0) {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Пароль архiву не може мiстити символи нового рядка" -Level "ERROR"
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
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Видалено попереднiй hash-файл перед повторним створенням архiву: $staleHashPath" -Level "WARNING"
        }

        # -p без значення вмикає шифрування і читає пароль зі stdin.
        $arguments = "$effectiveArcParams -p `"$fullArchivePath`" `"$SourcePath`""
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Команда: $ArcPath $arguments (пароль передається через stdin)" -Level "DEBUG"
        
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
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Архiвацiю перервано: перевищено таймаут $archiveTimeoutSeconds сек.: $ArchiveName" -Level "ERROR"
            if (Test-Path -LiteralPath $fullArchivePath -PathType Leaf) {
                Remove-Item -LiteralPath $fullArchivePath -Force -ErrorAction SilentlyContinue
                Write-BRAVOLog -Component 'ARCHIVE' -Message "Неповний архiв видалено: $fullArchivePath" -Level "WARNING"
            }
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Архiв створено; виконується контроль цiлiсностi: $fullArchivePath" -Level "INFO"
            if (Test-SevenZipArchiveIntegrity `
                -SevenZipPath $ArcPath `
                -ArchivePath $fullArchivePath `
                -Password $script:archivePassword `
                -TimeoutSeconds $integrityTestTimeoutSeconds `
                -Logger { param($Message, $Level) Write-BRAVOLog -Component 'ARCHIVE' -Message $Message -Level $Level }) {
                Write-BRAVOLog -Component 'ARCHIVE' -Message "Архiв створено та перевiрено: $fullArchivePath" -Level "SUCCESS"
                return $true
            }
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Пошкоджений або неперевiрений архiв залишено для дiагностики; hash i передача не виконуватимуться: $fullArchivePath" -Level "ERROR"
            return $false
        } else {
            $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $process.ExitCode
            Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка архiвацiї 7-Zip (код: $($process.ExitCode) — $exitDescription): $fullArchivePath" -Level "ERROR"
            Write-SevenZipFailureDiagnostics -Operation "Дiагностика 7-Zip create" -StandardOutput $standardOutput -StandardError $errorOutput
            if ($showSevenZipProgress) {
                if (-not [string]::IsNullOrWhiteSpace($lastSevenZipOutput)) {
                    Write-BRAVOLog -Component 'ARCHIVE' -Message "Останнiй вивiд 7-Zip: $lastSevenZipOutput" -Level "DEBUG"
                }
                if (-not [string]::IsNullOrWhiteSpace($errorOutput)) {
                    Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка 7-Zip: $errorOutput" -Level "DEBUG"
                }
            } else {
                Write-BRAVOLog -Component 'ARCHIVE' -Message "Деталi: $errorOutput" -Level "DEBUG"
            }
            return $false
        }
    } catch {
        Write-BRAVOLog -Component 'ARCHIVE' -Message "Помилка архiвацiї: $($_.Exception.Message)" -Level "ERROR"
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
        Write-BRAVOLog -Component 'HASH' -Message "Створення SHA512 хешу: $(Split-Path $FilePath -Leaf)"
        
        if (-not (Test-Path $FilePath)) {
            Write-BRAVOLog -Component 'HASH' -Message "Файл не знайдено: $FilePath" -Level "ERROR"
            return $false
        }
        
        try {
            # Використовуємо стандартний метод, якщо доступний
            if ($script:hasFileHash) {
                $hash = (Get-BRAVOFileHash -Path $FilePath -Algorithm SHA512).Hash.ToLower()
                Write-BRAVOLog -Component 'HASH' -Message "Хеш створено (стандартний метод): $HashFilePath" -Level "SUCCESS"
            } else {
                # Використовуємо сумісний метод
                return New-SHA512HashLegacy -FilePath $FilePath -HashFilePath $HashFilePath
            }
            
            $fileName = (Get-Item $FilePath).Name
            
            # Виправлення для PowerShell 4.0: використовуємо .NET метод замість Out-File з -NoNewline
            [System.IO.File]::WriteAllText($HashFilePath, "${hash} *${fileName}", [System.Text.Encoding]::GetEncoding($hashFileEncoding))
            
            return $true
        } catch {
            Write-BRAVOLog -Component 'HASH' -Message "Помилка створення хешу: $($_.Exception.Message)" -Level "ERROR"
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

    if ($BAZAOnly -or $componentSettings.Synchronization.BAZA_APP_SFTP) {
        if (-not $sftpDirectories.ContainsKey("BAZA") -or [string]::IsNullOrWhiteSpace($sftpDirectories.BAZA)) {
            $configurationErrors += "не встановлено SFTP каталог для BAZA"
        }
    }
    if ($componentSettings.Synchronization.BAZA_WWW_SFTP) {
        if (-not $sftpDirectories.ContainsKey("BAZAWWW") -or
            [string]::IsNullOrWhiteSpace($sftpDirectories.BAZAWWW)) {
            $configurationErrors += "не встановлено SFTP каталог для BAZA WWW"
        }
    }
    if ($BAZAOnly -or
        $componentSettings.Synchronization.BAZA_APP_SFTP -or
        $componentSettings.Synchronization.BAZA_WWW_SFTP) {
        if ([string]$sftpSynchronizationOptions -match '(?i)(^|\s)-delete(\s|$)') {
            $configurationErrors += "опція -delete заборонена для BAZA: віддалені файли мають зберігатися для відновлення"
        }
    }

    if ($configurationErrors.Count -gt 0) {
        foreach ($configurationError in $configurationErrors) {
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка конфiгурацiї SFTP: $configurationError" -Level "ERROR"
        }
        return $false
    }

    Write-BRAVOLog -Component 'SFTP' -Message "Доступ до SFTP налаштовано коректно" -Level "SUCCESS"
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
            Write-BRAVOLog -Component 'SMB' -Message "Помилка конфігурації NAS/SMB: $configurationError" -Level "ERROR"
        }
        return $false
    }

    Write-BRAVOLog -Component 'SMB' -Message "Доступ до NAS/SMB налаштовано коректно" -Level "SUCCESS"
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
        Write-BRAVOLog -Component 'SMB' -Message "Помилка копіювання на NAS/SMB: $($_.Exception.Message)" -Level "ERROR"
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
        Write-BRAVOLog -Component 'SMB' -Message "Підключення до NAS/SMB успішне: $($smbSettings.RootPath)" -Level "SUCCESS"

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
            Write-BRAVOLog -Component 'SMB' -Message "Копіювання на NAS/SMB: $copyFileName -> $($copyItem.DestinationDirectory)"
            if (Copy-FileToSMBWithProgress `
                -SourcePath $copyItem.SourcePath `
                -DestinationPath $destinationPath `
                -Component $copyItem.Component) {
                $copySuccess++
                Write-BRAVOLog -Component 'SMB' -Message "Файл успішно скопійовано на NAS/SMB: $copyFileName" -Level "SUCCESS"
            }
        }
    } catch {
        Write-BRAVOLog -Component 'SMB' -Message "Помилка NAS/SMB: $($_.Exception.Message)" -Level "ERROR"
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
        Write-BRAVOLog -Component 'NETWORK' -Message "Перевiрка мережевого з'єднання..." -Level "DEBUG"
        
        $connection = Test-BRAVOTcpConnection `
            -ComputerName $networkCheckHost `
            -Port $networkCheckPort `
            -TimeoutMilliseconds $networkPingTimeoutMilliseconds
        if ($connection) {
            Write-BRAVOLog -Component 'NETWORK' -Message "Мережеве з'єднання доступне ($($BRAVOCompatibility.NetworkProvider))" -Level "SUCCESS"
            return $true
        } else {
            Write-BRAVOLog -Component 'NETWORK' -Message "Мережеве з'єднання недоступне" -Level "ERROR"
            return $false
        }
    } catch {
        Write-BRAVOLog -Component 'NETWORK' -Message "Помилка перевiрки мережевого з'єднання: $($_.Exception.Message)" -Level "ERROR"
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
    # WinSCP script містить URL з обліковими даними, тому файл створюється
    # ОДРАЗУ з фінальним DACL — доступ лише поточному користувачу, SYSTEM і
    # Administrators.
    #
    # ЧОМУ НЕ "створити, потім Set-Acl" (аудит Low #9): між створенням файлу
    # й накладанням ACL файл існує з успадкованими від %TEMP% правами. Для
    # запланованого завдання %TEMP% — це C:\Windows\Temp, куди має доступ
    # значно ширше коло. Порожній файл у цьому вікні секрету ще не містить,
    # але Windows перевіряє права в момент ВІДКРИТТЯ дескриптора, а не при
    # кожному читанні: відкритий у цьому вікні дескриптор переживе зміну ACL
    # і прочитає облікові дані, які запише сюди викликач. Передача
    # FileSecurity у конструктор FileStream прибирає вікно повністю — файл
    # ніколи не існує з успадкованими правами.
    Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $temporaryPath = Join-Path `
        -Path $temporaryRoot `
        -ChildPath ("BRAVO_WinSCP_{0}.txt" -f [guid]::NewGuid().ToString("N"))

    # DACL будується ДО створення файлу.
    $security = New-Object System.Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
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
        [void]$security.AddAccessRule($rule)
    }

    $stream = $null
    try {
        $stream = New-Object `
            -TypeName System.IO.FileStream `
            -ArgumentList @(
                $temporaryPath,
                [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write,
                [IO.FileShare]::None,
                4096,
                [IO.FileOptions]::None,
                $security
            )
        $stream.Dispose()
        $stream = $null

        return $temporaryPath
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            try {
                Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $temporaryPath
            } catch {
                # WARNING, а не мовчазний пропуск: цей файл містить облікові
                # дані SFTP. Якщо його не вдалося затерти й видалити, секрет
                # лишився в %TEMP% — оператор має про це дізнатися саме
                # зараз, а не під час розслідування витоку.
                Write-BRAVOLog `
                    -Component 'SFTP' `
                    -Message "Не вдалося прибрати тимчасовий WinSCP-скрипт з обліковими даними ($temporaryPath): $($_.Exception.Message). Видаліть файл вручну." `
                    -Level "WARNING"
            }
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
    
    Write-BRAVOLog -Component 'SFTP' -Message "Перевiрка пiдключення до SFTP сервера" -Level "DEBUG"
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
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
            Write-BRAVOLog -Component 'SFTP' -Message (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "перевірка SFTP-з'єднання") -Level "ERROR"
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
            } catch {
                # Процес міг завершитися сам між WaitForExit і Kill().
                # Причина таймауту важливіша за невдале завершення, тому
                # тут DEBUG — але слід лишається: без нього незрозуміло,
                # чи WinSCP досі висить у пам'яті.
                Write-BRAVOLog `
                    -Component 'SFTP' `
                    -Message "Не вдалося завершити процес WinSCP після таймауту: $($_.Exception.Message)" `
                    -Level "DEBUG"
            }
            throw "перевищено таймаут перевірки SFTP-з'єднання"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        
        if ($process.ExitCode -eq 0) {
            Write-BRAVOLog -Component 'SFTP' -Message "Пiдключення до SFTP сервера успiшне" -Level "SUCCESS"
            return $true
        } else {
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка пiдключення до SFTP сервера (код: $($process.ExitCode))" -Level "ERROR"
            Write-BRAVOLog -Component 'SFTP' -Message "Вивiд: $(Get-SanitizedWinSCPDiagnostic -Text $output)" -Level "DEBUG"
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка: $(Get-SanitizedWinSCPDiagnostic -Text $errorOutput)" -Level "DEBUG"
            return $false
        }

    } finally {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {
            # Див. пояснення вище: файл містить облікові дані SFTP.
            Write-BRAVOLog `
                -Component 'SFTP' `
                -Message "Не вдалося прибрати тимчасовий WinSCP-скрипт з обліковими даними ($tempScript): $($_.Exception.Message). Видаліть файл вручну." `
                -Level "WARNING"
        }
    }
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

            # $difference.Local — це WinSCP.RemoteFileInfo (навіть для
            # локальної сторони порівняння), а не System.IO.FileInfo:
            # .FullName на ньому немає взагалі, лише .FileName (те саме
            # WinSCP CompareDirectories API, що вже коректно працює через
            # $side.FileName у Health.Runtime.ps1). Під Set-StrictMode
            # звернення до .FullName тут падало ще ДО порівняння з
            # порожнім рядком — реальний випадок: щойно створений на SFTP
            # каталог /baza_app зробив цю гілку вперше досяжною (раніше
            # порівняння саме падало на "каталог не знайдено" раніше, ніж
            # доходило сюди).
            $localItem = $difference.Local
            $localItemPath = if ($null -ne $localItem) {
                $fileNameProperty = $localItem.PSObject.Properties['FileName']
                if ($null -ne $fileNameProperty -and $null -ne $fileNameProperty.Value) {
                    [string]$fileNameProperty.Value
                } else {
                    ""
                }
            } else {
                ""
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
        Write-BRAVOLog -Component 'SFTP' -Message "Аудит $ComponentName $stageText не виконано: $($Comparison.Error)" -Level "WARNING"
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
        Write-BRAVOLog -Component 'SFTP' -Message "Аудит $ComponentName ${stageText}: усi локальнi файли синхронiзованi" -Level "SUCCESS"
        return
    }

    $summaryLevel = if ($Stage -eq "Before") {
        "INFO"
    } elseif ($retryablePendingFiles.Count -eq 0 -and $incompatiblePendingFiles.Count -gt 0) {
        "WARNING"
    } else {
        "ERROR"
    }
    Write-BRAVOLog -Component 'SFTP' -Message "Аудит $ComponentName ${stageText}: очiкують передачi: $($pendingFiles.Count) (вiдсутнi у хмарi: $missingCount; потребують оновлення: $updateCount; несумісні імена: $($incompatiblePendingFiles.Count))" -Level $summaryLevel
    foreach ($pendingFile in $retryablePendingFiles) {
        $itemType = if ($pendingFile.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        $sizeText = if ($null -ne $pendingFile.SizeBytes) {
            "; байт: $($pendingFile.SizeBytes)"
        } else {
            ""
        }
        # -FileOnly не існує на Write-BRAVOLog — це параметр локального шиму
        # Write-Log (транслює його в -NoConsole). Реальний випадок: 374
        # елементи в аудиті BAZA вперше зробили цей цикл досяжним і
        # негайно провалили весь runtime помилкою "A parameter cannot be
        # found that matches parameter name 'FileOnly'" — раніше сюди
        # взагалі не доходило через попередні два краші того самого аудиту.
        Write-BRAVOLog -Component 'SFTP' -Message "AUDIT $ComponentName $stageText [$itemType] [$($pendingFile.Reason)] $($pendingFile.Path)$sizeText" -Level $summaryLevel -NoConsole
    }
    foreach ($pendingFile in $incompatiblePendingFiles) {
        Write-BRAVOLog -Component 'SFTP' -Message "AUDIT $ComponentName $stageText [ПРОПУЩЕНО: НЕСУМІСНЕ ІМ'Я] $($pendingFile.Path)" -Level "WARNING" -NoConsole
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
        Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося перевiрити сумiснiсть iмен $ComponentName з SFTP: $($CompatibilityResult.Error)" -Level "WARNING"
        return
    }

    $issues = @($CompatibilityResult.Issues)
    if ($issues.Count -eq 0) {
        Write-BRAVOLog -Component 'SFTP' -Message "Перевiрка iмен ${ComponentName}: несумiсних iз SFTP iмен не знайдено" -Level "SUCCESS"
        return
    }

    Write-BRAVOLog -Component 'SFTP' -Message "Перевiрка iмен ${ComponentName}: знайдено несумiсних iмен: $($issues.Count). Цi об'єкти буде пропущено; потрiбне скорочення локальних iмен" -Level "ERROR"
    foreach ($issue in $issues) {
        $itemType = if ($issue.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        Write-BRAVOLog -Component 'SFTP' -Message "AUDIT $ComponentName НЕСУМIСНЕ IМ'Я [$itemType] [довжина: $($issue.CharacterCount) символів; $($issue.Utf8ByteCount)/$($issue.MaximumUtf8Bytes) UTF-8 байт] $($issue.Path)" -Level "ERROR" -NoConsole
    }

    # Notification failures must never stop the actual SFTP synchronization.
    try {
        Send-BAZAIncompatibleNameAlert -Issues $issues -ComponentName $ComponentName
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося підготувати сповіщення про несумісні імена ${ComponentName}: $($_.Exception.Message)" -Level "ERROR"
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
        Write-BRAVOLog -Component 'SFTP' -Message "Сповіщення про несумісні імена $ComponentName вимкнено параметрами запуску або конфігурацією" -Level "INFO"
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:notificationWebhookUrl)) {
        Write-BRAVOLog -Component 'SFTP' -Message (
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
    } catch {
        # Локальна IP-адреса потрібна лише для тексту сповіщення — без неї
        # воно надійде без цього рядка. DNS-запит до власного імені падає
        # на серверах із нестандартною мережевою конфігурацією, тому DEBUG:
        # це не проблема backup, але діагностика "чому в сповіщенні немає
        # IP" інакше впирається в порожнечу.
        Write-BRAVOLog `
            -Component 'NOTIFY' `
            -Message "Не вдалося визначити локальну IP-адресу: $($_.Exception.Message)" `
            -Level "DEBUG"
    }
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
        Write-BRAVOLog -Component 'SFTP' -Message "Сповіщення про $($Issues.Count) несумісних імен $ComponentName відправлено у $($script:notificationProviderDisplayName)$chunkText" -Level "SUCCESS"
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося відправити сповіщення про несумісні імена $ComponentName у $($script:notificationProviderDisplayName): $($_.Exception.Message)" -Level "ERROR"
    }
}

function Initialize-BRAVOSFTPRemoteDirectories {
    # Створює відсутні кореневі каталоги на SFTP (model/blog/bravoexch/
    # baza_app/...) одним пакетним викликом WinSCP, перед тим як
    # Send-FileViaWinSCP/Sync-FolderToSFTP спробують передати щось
    # усередину них. Реальний випадок: WinSCP явно повідомляв "Error
    # listing directory '/baza_app'. No such file or directory" — сам
    # каталог просто ніколи не створювався на сервері.
    #
    # option batch continue навмисно: mkdir на вже наявному каталозі
    # повертає помилку (а після першого успішного запуску каталоги вже
    # існують щоразу), і Sync-FolderToSFTP окремо документує, що це
    # звело б підсумковий $process.ExitCode до 1 навіть у режимі continue.
    # Тому цей виклик — best-effort і НІКОЛИ не є джерелом істини про
    # успіх/невдачу: реальний результат передачі перевіряють окремі
    # виклики Send-FileViaWinSCP/Sync-FolderToSFTP після нього, які на
    # це не зважають.
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey,
        [string[]]$RemoteDirectories
    )

    $normalizedDirectories = @(
        $RemoteDirectories |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { "/" + $_.Replace("\", "/").Trim("/") } |
            Where-Object { $_ -ne "/" } |
            Select-Object -Unique
    )
    if ($normalizedDirectories.Count -eq 0) {
        return
    }
    if (-not (Test-Path -Path $WinSCPPath -PathType Leaf)) {
        Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не знайдено: $WinSCPPath" -Level "WARNING"
        return
    }

    Write-BRAVOLog -Component 'SFTP' -Message "Перевiрка/створення потрiбних каталогiв на SFTP: $($normalizedDirectories -join ', ')"

    $mkdirCommands = ($normalizedDirectories | ForEach-Object { "mkdir `"$_`"" }) -join [Environment]::NewLine
    $winscpCommand = @"
option batch continue
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
$mkdirCommands
exit
"@

    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force

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
            Write-BRAVOLog -Component 'SFTP' -Message (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "створення каталогiв на SFTP") -Level "WARNING"
            return
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $operationTimeoutSeconds = [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        if (-not $process.WaitForExit($operationTimeoutSeconds * 1000)) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося завершити WinSCP пiсля таймауту створення каталогiв: $($_.Exception.Message)" -Level "WARNING"
            }
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $safeOutput = Get-SanitizedWinSCPDiagnostic -Text $capturedOutput.StandardOutput
        if (-not [string]::IsNullOrWhiteSpace($safeOutput)) {
            Write-BRAVOLog -Component 'SFTP' -Message "WinSCP вивiд (створення каталогiв): $safeOutput" -Level "DEBUG"
        }
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Помилка пiд час створення каталогiв на SFTP: $($_.Exception.Message)" -Level "WARNING"
    } finally {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося видалити тимчасовий скрипт: $($_.Exception.Message)" -Level "WARNING"
        }
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
    
    Write-BRAVOLog -Component 'SFTP' -Message "Завантаження через WinSCP: $(Split-Path $LocalFilePath -Leaf) -> $RemoteDirectory"
    
    if (-not (Test-Path $LocalFilePath)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Файл не знайдено: $LocalFilePath" -Level "ERROR"
        return $false
    }
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
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
        Write-BRAVOLog -Component 'SFTP' -Message "Створено тимчасовий скрипт WinSCP: $tempScript" -Level "DEBUG"
        
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
        Write-BRAVOLog -Component 'SFTP' -Message "Запуск WinSCP..." -Level "DEBUG"
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-BRAVOLog -Component 'SFTP' -Message (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "передача $transferFileName") -Level "ERROR"
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
                    Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося завершити WinSCP після таймауту: $($_.Exception.Message)" -Level "WARNING"
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
            Write-BRAVOLog -Component 'SFTP' -Message "WinSCP вивiд: $safeOutput" -Level "DEBUG"
        }
        if ($transferTimedOut) {
            Write-BRAVOLog -Component 'SFTP' -Message "Передача WinSCP перевищила таймаут $operationTimeoutSeconds сек.: $transferFileName" -Level "ERROR"
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-BRAVOLog -Component 'SFTP' -Message "Файл успiшно завантажено: $(Split-Path $LocalFilePath -Leaf)" -Level "SUCCESS"
            return $true
        } else {
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка завантаження (код: $($process.ExitCode)): $(Split-Path $LocalFilePath -Leaf)" -Level "ERROR"
            if (-not [string]::IsNullOrEmpty($safeOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "Вивiд WinSCP: $safeOutput" -Level "DEBUG"
            }
            if (-not [string]::IsNullOrEmpty($safeErrorOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "Помилка WinSCP: $safeErrorOutput" -Level "DEBUG"
            }
            return $false
        }
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Помилка пiд час завантаження через WinSCP: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($showWinSCPProgress) {
            Show-RunningProgress -Id 11 -Activity $transferActivity -Completed
        }
        # Очищаємо тимчасовий файл із конфіденційними даними.
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
            Write-BRAVOLog -Component 'SFTP' -Message "Тимчасовий скрипт видалено: $tempScript" -Level "DEBUG"
        } catch {
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося видалити тимчасовий скрипт: $($_.Exception.Message)" -Level "WARNING"
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

    Write-BRAVOLog -Component 'SFTP' -Message "Синхронiзацiя каталогу через WinSCP: $LocalDirectory -> $remotePath"

    if (-not (Test-Path -Path $LocalDirectory -PathType Container)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Локальний каталог не знайдено: $LocalDirectory" -Level "ERROR"
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
            Write-BRAVOLog -Component 'SFTP' -Message "SFTP-синхронiзацiю $ComponentName заблоковано: локальний каталог порожнiй або недоступний" -Level "ERROR"
            return $false
        }
    }

    if (-not (Test-Path -Path $WinSCPPath -PathType Leaf)) {
        Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
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
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося встановити UTF-8 для виводу WinSCP: $($_.Exception.Message)" -Level "DEBUG"
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-BRAVOLog -Component 'SFTP' -Message (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "синхронізація $ComponentName") -Level "ERROR"
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
        Write-BRAVOLog -Component 'SFTP' -Message (
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
                    Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося завершити WinSCP після таймауту синхронізації ${ComponentName}: $($_.Exception.Message)" -Level "WARNING"
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
            Write-BRAVOLog -Component 'SFTP' -Message "WinSCP вивiд синхронiзацiї ${ComponentName}: $sanitizedOutput" -Level "DEBUG"
        }
        if ($syncTimedOut) {
            Write-BRAVOLog -Component 'SFTP' -Message "Синхронізація $ComponentName перевищила таймаут $operationTimeoutSeconds сек." -Level "ERROR"
            Write-BRAVOLog -Component 'SFTP' -Message "Повторний запуск продовжить передачу файлів із використанням WinSCP resumesupport" -Level "INFO"
            return $false
        }

        $winSCPExitCode = $process.ExitCode
        if ($winSCPExitCode -ne 0) {
            Write-BRAVOLog -Component 'SFTP' -Message "Помилка SFTP-синхронiзацiї $ComponentName (код: $winSCPExitCode)" -Level "ERROR"
            if (-not [string]::IsNullOrWhiteSpace($sanitizedOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "Дiагностика WinSCP (stdout): $sanitizedOutput" -Level "ERROR"
            }
            if (-not [string]::IsNullOrWhiteSpace($sanitizedErrorOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "Дiагностика WinSCP (stderr): $sanitizedErrorOutput" -Level "ERROR"
            }
            if ([string]::IsNullOrWhiteSpace($sanitizedOutput) -and
                [string]::IsNullOrWhiteSpace($sanitizedErrorOutput)) {
                Write-BRAVOLog -Component 'SFTP' -Message "WinSCP не повернув тексту помилки; перевiрте права доступу до $remotePath" -Level "ERROR"
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
            Write-BRAVOLog -Component 'SFTP' -Message "Не вдалося пiдтвердити результат синхронiзацiї $ComponentName повторним порiвнянням; результат вважається помилкою" -Level "ERROR"
            return $false
        }

        if ($null -ne $syncOutcome.CompletedCount) {
            $resultLevel = if ($syncOutcome.IsComplete -and -not $syncOutcome.IsDegraded) {
                "SUCCESS"
            } else {
                "WARNING"
            }
            Write-BRAVOLog -Component 'SFTP' -Message "Результат ${ComponentName}: передано або оновлено сумісних об'єктiв: $($syncOutcome.CompletedCount); залишилося несинхронiзованих: $($syncOutcome.RemainingCount)" -Level $resultLevel
        }

        if ($syncOutcome.IsComplete) {
            if ($syncOutcome.IsDegraded) {
                Write-BRAVOLog -Component 'SFTP' -Message "Каталог $ComponentName синхронізовано для всіх сумісних імен; $($syncOutcome.IncompatibleRemainingCount) об'єктів пропущено через незмінювані несумісні імена. Повторний запуск не потрібен." -Level "WARNING"
            } else {
                Write-BRAVOLog -Component 'SFTP' -Message "Каталог $ComponentName повнiстю синхронiзовано з $remotePath" -Level "SUCCESS"
            }
            return $true
        }

        if ($winSCPExitCode -eq 0 -and $syncOutcome.IsPartial) {
            Write-BRAVOLog -Component 'SFTP' -Message "WinSCP повернув код 0, але синхронiзацiя $ComponentName часткова: залишилося об'єктiв: $($syncOutcome.RemainingCount)" -Level "ERROR"
        }
        return $false
    } catch {
        Write-BRAVOLog -Component 'SFTP' -Message "Помилка пiд час SFTP-синхронiзацiї ${ComponentName}: $($_.Exception.Message)" -Level "ERROR"
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
        } catch {
            # Файл містить облікові дані SFTP — його залишок у %TEMP% це
            # витік, а не дрібниця прибирання.
            Write-BRAVOLog `
                -Component 'SFTP' `
                -Message "Не вдалося прибрати тимчасовий WinSCP-скрипт з обліковими даними ($tempScript): $($_.Exception.Message). Видаліть файл вручну." `
                -Level "WARNING"
        }
    }
}

function Invoke-ManualBAZASFTPSynchronization {
    Write-BRAVOLog -Component 'SFTP' -Message "==="
    Write-BRAVOLog -Component 'SFTP' -Message "=== РУЧНА СИНХРОНIЗАЦIЯ BAZA_APP / BAZA_WWW НА SFTP ==="
    Write-BRAVOLog -Component 'SFTP' -Message "Режим -SyncBAZA: синхронізуються всі увімкнені BAZA_APP/BAZA_WWW; архiвацiю, очищення архiвiв, NAS/SMB та health-check пропущено" -Level "INFO"
    Show-ScriptProgress -Status "Ручна синхронiзацiя BAZA_APP / BAZA_WWW на SFTP" -PercentComplete 20

    $syncTargets = @()
    $sourceConfigurationFailed = $false
    if ([bool]$componentSettings.Synchronization.BAZA_APP_SFTP) {
        if (Test-PathWithLog -Path $bazaAppPaths.Source -Description "Каталог BAZA_APP" -CreateIfMissing $false) {
            $syncTargets += [pscustomobject]@{
                Name = "BAZA_APP"
                Source = [string]$bazaAppPaths.Source
                Destination = [string]$sftpDirectories.BAZA
            }
        } else {
            $sourceConfigurationFailed = $true
            Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронізацію BAZA_APP пропущено: локальний каталог недоступний" -Level "ERROR"
        }
    }
    if ([bool]$componentSettings.Synchronization.BAZA_WWW_SFTP) {
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
            Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронізацію BAZA_WWW пропущено: $detectionReason" -Level "ERROR"
        }
    }
    if ($syncTargets.Count -eq 0) {
        Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронізацію скасовано: BAZA_APP_SFTP і BAZA_WWW_SFTP вимкнені або їхні джерела недоступні" -Level "ERROR"
        return $false
    }

    if (-not (Test-SFTPConfig -SynchronizationOnly)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено через помилки конфiгурацiї SFTP" -Level "ERROR"
        return $false
    }

    Show-ScriptProgress -Status "Перевiрка з'єднання з SFTP" -PercentComplete 35
    if (-not (Test-NetworkConnection)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено: мережеве з'єднання недоступне" -Level "ERROR"
        return $false
    }

    if (-not (Test-SFTPConnection `
        -WinSCPPath $winSCPPath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey)) {
        Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено: не вдалося пiдключитися до SFTP" -Level "ERROR"
        return $false
    }

    Initialize-BRAVOSFTPRemoteDirectories `
        -WinSCPPath $winSCPPath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey `
        -RemoteDirectories @($syncTargets | ForEach-Object { [string]$_.Destination })

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
            Write-BRAVOLog -Component 'SFTP' -Message "Ручну синхронiзацiю $($syncTarget.Name) на SFTP завершено успiшно" -Level "SUCCESS"
        } else {
            $syncFailed = $true
            Write-BRAVOLog -Component 'SFTP' -Message "Ручна синхронiзацiя $($syncTarget.Name) на SFTP завершилася з помилкою" -Level "ERROR"
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
        # JSON замість "PID=...; Started=..." (аудит P1.8): processStartTime і
        # hostname дають змогу відрізнити той самий PID, перевикористаний
        # іншим процесом після перезавантаження, від справді активного
        # BRAVO_ARCHIV, а operation — з якого runtime взято спільний lock
        # (його ділять Archive і Maintenance).
        $lockProcessStartTime = try {
            (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString("o")
        } catch {
            $null
        }
        $lockText = ([pscustomobject]@{
            pid = $PID
            processStartTime = $lockProcessStartTime
            hostname = [Environment]::MachineName
            operation = "Archive"
            startedAt = (Get-Date).ToString("o")
            packageVersion = [string]$ScriptVersion
            config = $configPath
        } | ConvertTo-Json -Compress)
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
        } catch {
            # Пошкоджений файл стану не зупиняє запуск — він перезапишеться
            # нижче. Але мовчазне ігнорування означало, що стан попереднього
            # запуску тихо зникає, і "Maintenance ніколи не виконувався"
            # виглядало як факт, а не як втрачений запис.
            Write-BRAVOLog `
                -Component 'STATE' `
                -Message "Не вдалося прочитати попередній стан завдань ($path): $($_.Exception.Message). Стан буде перезаписано." `
                -Level "DEBUG"
        }
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
        'WARNING'
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
    Initialize-BRAVOProgress `
        -Activity ([string]$progressSettings.Activity) `
        -Enabled ([bool]$progressSettings.Enabled)
    # Консольна половина журналу теж має йти через BRAVO.Console: інакше
    # WARNING із бізнес-логіки допишеться у хвіст відкритого рядка етапу
    # ("[3/7] BLOG......... " без переводу рядка) і зламає розмітку.
    Set-BRAVOLogConsoleWriter -Writer {
        param($Message, $Level)
        Write-BRAVOConsoleMessage -Message $Message -Level $Level
    }
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
        $script:processExitCode = Resolve-BRAVOExitCode -LockBusy
        return
    }
    $script:archiveProcessLock = $processLockResult.Stream
    $script:archiveProcessLockPath = $processLockResult.Path

    $enabledArchives = @($archiveDefinitions | Where-Object { $_.Enabled })
    $readyArchives = @()
    $results = @{}
    $bazaAppLocalSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_APP_LOCAL
    $bazaAppSFTPSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_APP_SFTP
    $bazaWWWSFTPSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_WWW_SFTP
    $bazaWWWLocalSyncEnabled = [bool]$componentSettings.Synchronization.BAZA_WWW_LOCAL
    $sftpArchiveUploadEnabled = [bool]$componentSettings.SFTP.ArchiveUpload
    $smbArchiveCopyEnabled = [bool]$componentSettings.SMB.ArchiveCopy
    $sftpTransferEnabled = (
        $sftpArchiveUploadEnabled -or
        $bazaAppSFTPSyncEnabled -or
        $bazaWWWSFTPSyncEnabled
    )
    $operationFailed = $false

    # Етапи консолі: середовище + шляхи + по одному на компонент, далі —
    # лише ті передавання й перевірки, що справді увімкнені в конфігурації.
    $healthCheckEnabled = (
        [bool]$backupMonitoring.Enabled -and [bool]$backupMonitoring.RunAfterBackup
    )
    Initialize-BRAVOArchiveSteps -Total (
        2 +
        $enabledArchives.Count +
        $(if ($sftpTransferEnabled) { 1 } else { 0 }) +
        $(if ($smbArchiveCopyEnabled) { 1 } else { 0 }) +
        $(if ($healthCheckEnabled) { 1 } else { 0 })
    )

    Show-ScriptProgress -Status "Iнiцiалiзацiя" -PercentComplete 2
    
    Write-Log "==="
    Write-Log "=== ПОЧАТОК РОБОТИ СКРИПТА BRAVO_ARCHIV v.$ScriptVersion ==="
    Write-Log "Файл конфiгурацiї: $configPath" -Level "INFO"
    
    # Перевірка сумісності
    Write-Log "==="
    Write-Log "=== ПЕРЕВIРКА СУМIСНОСТI СИСТЕМИ ==="
    Show-ScriptProgress -Status "Перевiрка сумiсностi" -PercentComplete 5
    # Test-Compatibility сама логує знайдені проблеми; повернене значення
    # тут навмисно не використовується (раніше присвоювалось у змінну,
    # яку ніхто не читав).
    [void](Test-Compatibility)

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
        # -SyncBAZA — це суто SFTP-операція за визначенням.
        $script:processExitCode = if ($manualSyncSuccess) { 0 } else { Resolve-BRAVOExitCode -SftpFailed }
        Show-ScriptProgress -Status "Завершено" -PercentComplete 100
        Complete-BRAVOProgress

        # Ручна синхронізація завершується до етапів, тому підсумок тут
        # окремий: інакше в консолі не лишилося б жодного зворотного звʼязку.
        $manualSyncStatistics = Get-BRAVOLogStatistics
        $manualSyncMetrics = New-Object System.Collections.Specialized.OrderedDictionary
        $manualSyncMetrics.Add('Операція', 'Ручна синхронізація BAZA_APP / BAZA_WWW')
        $manualSyncMetrics.Add('Попереджень', [string]$manualSyncStatistics.Warnings)
        $manualSyncMetrics.Add('Помилок', [string]$manualSyncStatistics.Errors)
        Write-BRAVOSummary `
            -Result $(if ($manualSyncSuccess) { 'УСПІШНО' } else { 'ПОМИЛКА' }) `
            -Duration $manualSyncDuration `
            -Metrics $manualSyncMetrics `
            -LogFile $script:logFile
        return
    }
    
    # Використовуємо NoTimestamp для інформаційного блоку
    Write-Log "==="
    Write-Log "=== ОПЦIЇ СКРИПТА ==="
    Write-Log "Версiя та дата скрипта: $ScriptVersion вiд $ScriptDate" -NoTimestamp
    Write-Log "Збірка (build): $(if ([string]::IsNullOrWhiteSpace([string]$ScriptBuildId)) { 'невідома' } else { [string]$ScriptBuildId })" -NoTimestamp
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
    # Джерело показуємо для кожного увiмкненого компонента — інакше з
    # самого лише "УВIМКНЕНО" не видно, який саме каталог реально обрано
    # автоматичним discovery (bravo.ini) чи легасі-евристикою (BRAVOEXCH).
    if ([bool]$componentSettings.Archive.MODEL) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.MODEL_SOURCE)) {
            Write-Log "Джерело MODEL: $($bravoDiscoveryResult.MODEL_SOURCE) ($($bravoDiscoveryResult.Reasons.MODEL))" -NoTimestamp
        } else {
            Write-Log "Джерело MODEL не визначено: $($bravoDiscoveryResult.Reasons.MODEL)" -Level "ERROR" -NoTimestamp
        }
    }
    if ([bool]$componentSettings.Archive.BLOG) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BLOG_SOURCE)) {
            Write-Log "Джерело BLOG: $($bravoDiscoveryResult.BLOG_SOURCE) ($($bravoDiscoveryResult.Reasons.BLOG))" -NoTimestamp
        } else {
            Write-Log "Джерело BLOG не визначено: $($bravoDiscoveryResult.Reasons.BLOG)" -Level "ERROR" -NoTimestamp
        }
    }
    if ([bool]$componentSettings.Archive.BRAVOEXCH) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bravoExchSourceDirectory)) {
            Write-Log "Джерело BRAVOEXCH: $bravoExchSourceDirectory (вибрано автоматично)" -NoTimestamp
        } else {
            Write-Log "Джерело BRAVOEXCH не знайдено: жоден із каталогів не існує або не містить файлів: $($bravoExchSourceCandidates -join '; ')" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Локальна синхронiзацiя BAZA APP: $(if ($bazaAppLocalSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    if ($bazaAppLocalSyncEnabled) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bazaAppPaths.Source)) {
            Write-Log "Джерело BAZA APP: $($bazaAppPaths.Source) ($($bravoDiscoveryResult.Reasons.BAZA_APP))" -NoTimestamp
        } else {
            Write-Log "Джерело BAZA APP не визначено: $($bravoDiscoveryResult.Reasons.BAZA_APP)" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Завантаження архiвiв на SFTP: $(if ($sftpArchiveUploadEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA APP на SFTP: $(if ($bazaAppSFTPSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA WWW на SFTP: $(if ($bazaWWWSFTPSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Локальна синхронiзацiя BAZA WWW: $(if ($bazaWWWLocalSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    if ($bazaWWWSFTPSyncEnabled -or $bazaWWWLocalSyncEnabled) {
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
    # Етап 1 підсумовує все, що перевірялося до цього: сумісність, пароль,
    # узгодженість, конфігурацію передавання та очищення старих логів.
    $environmentValid = (
        $archiveCredentialValid -and
        $archiveConsistencyValid -and
        $sftpConfigurationValid -and
        $smbConfigurationValid
    )
    Write-BRAVOArchiveStep `
        -Name "Перевірка середовища" `
        -Status $(if ($environmentValid) { 'OK' } else { 'WARNING' })

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

    $bazaAppSourceAvailable = $true
    $bazaAppDestinationAvailable = $true
    if ($bazaAppLocalSyncEnabled -or $bazaAppSFTPSyncEnabled) {
        $bazaAppSourceAvailable = Test-PathWithLog `
            -Path $bazaAppPaths.Source `
            -Description "Каталог BAZA APP" `
            -CreateIfMissing $false
    }
    if ($bazaAppLocalSyncEnabled) {
        $bazaAppDestinationAvailable = Test-PathWithLog `
            -Path $bazaAppPaths.Destination `
            -Description "Каталог архiву BAZA APP" `
            -CreateIfMissing $true
    }
    $bazaWWWSourceAvailable = $true
    $bazaWWWDestinationAvailable = $true
    if ($bazaWWWSFTPSyncEnabled -or $bazaWWWLocalSyncEnabled) {
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
    if ($bazaWWWLocalSyncEnabled) {
        $bazaWWWDestinationAvailable = Test-PathWithLog `
            -Path $bazaWWWPaths.Destination `
            -Description "Каталог архiву BAZA WWW" `
            -CreateIfMissing $true
    }

    $allPathsExist = (
        $basePathsAvailable -and
        $readyArchives.Count -eq $enabledArchives.Count -and
        $bazaAppSourceAvailable -and
        $bazaAppDestinationAvailable -and
        $bazaWWWSourceAvailable -and
        $bazaWWWDestinationAvailable
    )
    Show-PathCheckSummary -CheckedPaths $requiredPaths -AllPathsExist $allPathsExist
    Write-BRAVOArchiveStep `
        -Name "Перевірка шляхів" `
        -Status $(if ($allPathsExist) { 'OK' } else { 'ERROR' }) `
        -Details $(if ($allPathsExist) { '' } else { 'Частина шляхів недоступна; деталі у журналі.' })

    # Синхронізація BAZA APP
    if ($bazaAppLocalSyncEnabled -and $bazaAppSourceAvailable -and $bazaAppDestinationAvailable) {
        Show-ScriptProgress -Status "Локальна синхронiзацiя BAZA APP" -PercentComplete 20
        Write-Log "==="
        Write-Log "=== СИНХРОНIЗАЦIЯ BAZA APP ==="
        $syncSuccess = Sync-Folders -SourcePath $bazaAppPaths.Source -DestinationPath $bazaAppPaths.Destination

        if ($syncSuccess) {
            Write-Log "Синхронiзацiя BAZA APP успiшна" -Level "SUCCESS"
        } else {
            Write-Log "Помилка синхронiзацiї BAZA APP - архiвацiя може бути неповною" -Level "WARNING"
            $operationFailed = $true
        }
    } elseif ($bazaAppLocalSyncEnabled) {
        Write-Log "Локальну синхронiзацiю BAZA APP пропущено через помилку шляху" -Level "ERROR"
        $operationFailed = $true
    } else {
        Write-Log "Локальну синхронiзацiю BAZA APP вимкнено в конфiгурацiї" -Level "INFO"
    }

    # Синхронізація BAZA WWW (локальна копія)
    if ($bazaWWWLocalSyncEnabled -and $bazaWWWSourceAvailable -and $bazaWWWDestinationAvailable) {
        Show-ScriptProgress -Status "Локальна синхронiзацiя BAZA WWW" -PercentComplete 20
        Write-Log "==="
        Write-Log "=== СИНХРОНIЗАЦIЯ BAZA WWW ==="
        $syncSuccess = Sync-Folders -SourcePath $bazaWWWPaths.Source -DestinationPath $bazaWWWPaths.Destination

        if ($syncSuccess) {
            Write-Log "Синхронiзацiя BAZA WWW успiшна" -Level "SUCCESS"
        } else {
            Write-Log "Помилка синхронiзацiї BAZA WWW - архiвацiя може бути неповною" -Level "WARNING"
            $operationFailed = $true
        }
    } elseif ($bazaWWWLocalSyncEnabled) {
        Write-Log "Локальну синхронiзацiю BAZA WWW пропущено через помилку шляху" -Level "ERROR"
        $operationFailed = $true
    } else {
        Write-Log "Локальну синхронiзацiю BAZA WWW вимкнено в конфiгурацiї" -Level "INFO"
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
        $archiveStepStarted = Get-Date
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

        # Розмір і тривалість показуємо в консолі коротко; повні шляхи,
        # аргументи 7-Zip і його вивід лишаються в журналі.
        $archiveStepDuration = (Get-Date) - $archiveStepStarted
        $archiveStepDetails = $archiveStepDuration.ToString($durationFormat)
        $sizeAnomalyResult = $null
        if ($success) {
            $createdArchivePath = Join-Path $archive.Destination $archiveName
            if (Test-Path -LiteralPath $createdArchivePath -PathType Leaf) {
                $createdArchiveSize = (Get-Item -LiteralPath $createdArchivePath).Length
                $archiveStepDetails = "{0} / {1}" -f
                    (Format-BRAVOFileSize -Bytes $createdArchiveSize),
                    $archiveStepDuration.ToString($durationFormat)

                # AUD-008 (аудит P1.6): sanity-check обсягу — технічно
                # валідний архів все одно може бути підозріло малим через
                # неправильне джерело чи зламані permissions. Не блокує
                # (лишає ArchiveSuccess/HashSuccess як є), лише сигналізує.
                if ($hashSuccess -and
                    [bool]$backupMonitoring.SizeSanity.Enabled) {
                    try {
                        $sizeAnomalyResult = Test-BRAVOBackupSizeAnomaly `
                            -NewArchiveBytes $createdArchiveSize `
                            -HistoryDirectory $archive.Destination `
                            -ArchiveFilter $archiveFileFilter `
                            -HashFileExtension $hashFileExtension `
                            -ExcludeArchivePath $createdArchivePath `
                            -HistoryCount ([int]$backupMonitoring.SizeSanity.HistoryCount) `
                            -MinimumBytes ([int64]$backupMonitoring.SizeSanity.MinimumBytes) `
                            -MaxSizeDropPercent ([int]$backupMonitoring.SizeSanity.MaxSizeDropPercent)
                        if ([bool]$sizeAnomalyResult.IsAnomaly) {
                            Write-Log "Підозрілий розмір архіву $($archive.Type): $($sizeAnomalyResult.Reason)" -Level "WARNING"
                        }
                    } catch {
                        Write-Log "Не вдалося виконати sanity-check обсягу для $($archive.Type): $($_.Exception.Message)" -Level "WARNING"
                    }
                }
                $results[$archive.Type].Bytes = $createdArchiveSize
                $results[$archive.Type].SizeAnomaly = $sizeAnomalyResult
            }
        }
        $archiveStepStatus = if (-not $success) {
            'ERROR'
        } elseif (-not $hashSuccess) {
            'WARNING'
        } elseif ($null -ne $sizeAnomalyResult -and [bool]$sizeAnomalyResult.IsAnomaly) {
            'WARNING'
        } else {
            'OK'
        }
        if ($null -ne $sizeAnomalyResult -and [bool]$sizeAnomalyResult.IsAnomaly) {
            $archiveStepDetails = "$archiveStepDetails — $($sizeAnomalyResult.Reason)"
        }
        Write-BRAVOArchiveStep `
            -Name ("Архівація {0}" -f $archive.Type) `
            -Status $archiveStepStatus `
            -Details $archiveStepDetails
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
    # Статус етапу визначаємо за приростом кількості ERROR у журналі: прапорець
    # $operationFailed накопичується з попередніх фаз і показав би збій навіть
    # тоді, коли саме передавання пройшло успішно.
    $errorsBeforeSftp = (Get-BRAVOLogStatistics).Errors
    # Читається у фінальному резолвері коду виходу незалежно від того, чи
    # передача на SFTP взагалі увімкнена — інакше змінна лишається
    # неоголошеною, коли компонент вимкнено, і StrictMode кидає виняток.
    $sftpStepFailed = $false
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
            $requiredSFTPDirectories = @()
            if ($sftpArchiveUploadEnabled) {
                $requiredSFTPDirectories += @(
                    $enabledArchives | ForEach-Object { [string]$sftpDirectories[$_.Type] }
                )
            }
            if ($bazaAppSFTPSyncEnabled) {
                $requiredSFTPDirectories += [string]$sftpDirectories.BAZA
            }
            if ($bazaWWWSFTPSyncEnabled) {
                $requiredSFTPDirectories += [string]$sftpDirectories.BAZAWWW
            }
            Initialize-BRAVOSFTPRemoteDirectories `
                -WinSCPPath $winSCPPath `
                -RepositorySFTPUrl $sftpUrl `
                -HostKey $sftpHostKey `
                -RemoteDirectories $requiredSFTPDirectories

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

            if ($bazaAppSFTPSyncEnabled -and $bazaAppSourceAvailable) {
                Show-ScriptProgress -Status "Синхронiзацiя BAZA APP на SFTP" -PercentComplete 90
                Write-Log "==="
                Write-Log "=== СИНХРОНIЗАЦIЯ BAZA APP НА SFTP ==="
                $bazaAppSFTPSync = Sync-FolderToSFTP -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey -LocalDirectory $bazaAppPaths.Source -RemoteDirectory $sftpDirectories.BAZA
                if (-not $bazaAppSFTPSync) {
                    Write-Log "Каталог BAZA APP не вдалося синхронiзувати з SFTP" -Level "WARNING"
                    $operationFailed = $true
                }
            } elseif ($bazaAppSFTPSyncEnabled) {
                Write-Log "Синхронiзацiю BAZA APP на SFTP пропущено через помилку локального шляху" -Level "ERROR"
                $operationFailed = $true
            } else {
                Write-Log "Синхронiзацiю BAZA APP на SFTP вимкнено в конфiгурацiї" -Level "INFO"
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
    if ($sftpTransferEnabled) {
        $sftpStepFailed = (Get-BRAVOLogStatistics).Errors -gt $errorsBeforeSftp
        Write-BRAVOArchiveStep `
            -Name "Передача архівів на SFTP" `
            -Status $(if ($sftpStepFailed) { 'ERROR' } else { 'OK' }) `
            -Details $(if ($sftpStepFailed) { 'Деталі записано у журнал.' } else { '' })
    }

    # Копіювання успішно створених архівів та hash-файлів на NAS/SMB
    $errorsBeforeSmb = (Get-BRAVOLogStatistics).Errors
    # Той самий захист, що й для $sftpStepFailed вище.
    $smbStepFailed = $false
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
    if ($smbArchiveCopyEnabled) {
        $smbStepFailed = (Get-BRAVOLogStatistics).Errors -gt $errorsBeforeSmb
        Write-BRAVOArchiveStep `
            -Name "Копіювання архівів на NAS/SMB" `
            -Status $(if ($smbStepFailed) { 'ERROR' } else { 'OK' }) `
            -Details $(if ($smbStepFailed) { 'Деталі записано у журнал.' } else { '' })
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

    $errorsBeforeHealth = (Get-BRAVOLogStatistics).Errors
    # Читається у фінальному резолвері коду виходу нижче незалежно від того,
    # чи здійснювалась перевірка health-check.
    $healthCriticalFailure = $false
    if ($healthCheckEnabled) {
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
                    "Disabled" {
                        # Сам Health вважає це безпечним станом (вимкнено в
                        # конфігурації) і завершується з exit 0 — Archive не
                        # повинен трактувати чужий "вимкнено" як власну відмову.
                        Write-Log "Health-check вимкнено в конфігурації" -Level "INFO"
                    }
                    "Deferred" {
                        # Аналогічно: відкладено через паралельне завдання чи
                        # зайнятий lock — це не відмова, а штатне пропускання.
                        Write-Log "Health-check відкладено: інше завдання вже виконується" -Level "INFO"
                    }
                    "Critical" {
                        Write-Log "Health-check: знайдено проблем: $($healthCheckResult.IssueCount); повідомлення: $($healthCheckResult.Notification)" -Level "ERROR"
                        $operationFailed = $true
                        $healthCriticalFailure = $true
                    }
                    "NotificationError" {
                        Write-Log "Health-check завершився, але повідомлення не вiдправлено: $($healthCheckResult.Error)" -Level "ERROR"
                        $operationFailed = $true
                        $healthCriticalFailure = $true
                    }
                    default {
                        Write-Log "Health-check завершився зі статусом: $($healthCheckResult.Status)" -Level "WARNING"
                        $operationFailed = $true
                        $healthCriticalFailure = $true
                    }
                }
        } catch {
            Write-Log "Помилка запуску окремого health-check: $($_.Exception.Message)" -Level "ERROR"
            $operationFailed = $true
            $healthCriticalFailure = $true
        }
    }

    if ($healthCheckEnabled) {
        $healthStepFailed = (Get-BRAVOLogStatistics).Errors -gt $errorsBeforeHealth
        Write-BRAVOArchiveStep `
            -Name "Перевірка резервних копій" `
            -Status $(if ($healthStepFailed) { 'ERROR' } else { 'OK' }) `
            -Details $(if ($healthStepFailed) { 'Деталі записано у журнал.' } else { '' })
    }

    # Секція health-check (якщо вона виконувалась) залишає компонент журналу
    # на "HEALTH" — без явного повернення на "SUMMARY" підсумковий рядок
    # хибно тегувався б [HEALTH] навіть тоді, коли сам health-check пройшов
    # успішно, а $operationFailed стало $true через щось раніше (наприклад
    # провалену перевірку цілісності архіву).
    Set-BRAVOLogComponent -Component 'SUMMARY'
    Write-Log "Результат: $(if ($operationFailed) {'ПОМИЛКА'} else {'УСПIШНО'})" -NoTimestamp
    Write-Log "==="
    if (-not $operationFailed) {
        Write-BRAVOBackupExecutionState
    }
    Show-ScriptProgress -Status "Завершено" -PercentComplete 100
    Complete-BRAVOProgress

    # Фінальний підсумок операційної консолі.
    $logStatistics = Get-BRAVOLogStatistics
    $summaryResult = if ($operationFailed) {
        if ($successCount -gt 0) { 'ЧАСТКОВО' } else { 'ПОМИЛКА' }
    } else {
        'УСПІШНО'
    }
    $summaryMetrics = New-Object System.Collections.Specialized.OrderedDictionary
    $summaryMetrics.Add('Архівів створено', ("{0} з {1}" -f $successCount, $totalCount))
    if ($sftpTransferEnabled) {
        $summaryMetrics.Add('Передача на SFTP', $(if ($sftpStepFailed) { 'з помилками' } else { 'виконано' }))
    }
    if ($smbArchiveCopyEnabled) {
        $summaryMetrics.Add('Копіювання на NAS/SMB', $(if ($smbStepFailed) { 'з помилками' } else { 'виконано' }))
    }
    $summaryMetrics.Add('Попереджень', [string]$logStatistics.Warnings)
    $summaryMetrics.Add('Помилок', [string]$logStatistics.Errors)
    Write-BRAVOSummary `
        -Result $summaryResult `
        -Duration $duration `
        -Metrics $summaryMetrics `
        -LogFile $script:logFile
    if ($operationFailed) {
        # Один раз, тут, читаємо вже наявний стан секцій Main і визначаємо
        # найпріоритетнішу категорію відмови — жодна з ~26 точок
        # $operationFailed = $true вище не редагувалась.
        $anyLocalArchiveFailed = @(
            $results.Values | Where-Object { -not $_.ArchiveSuccess }
        ).Count -gt 0
        $anyIntegrityTestFailed = @(
            $results.Values | Where-Object { $_.ArchiveSuccess -and -not $_.HashSuccess }
        ).Count -gt 0
        $script:processExitCode = Resolve-BRAVOExitCode `
            -InvalidConfiguration:(-not $sftpConfigurationValid -or -not $smbConfigurationValid -or -not $archiveConsistencyValid) `
            -CredentialsUnavailable:(-not $archiveCredentialValid) `
            -LocalArchiveFailed:$anyLocalArchiveFailed `
            -IntegrityTestFailed:$anyIntegrityTestFailed `
            -SftpFailed:([bool]$sftpStepFailed) `
            -SmbFailed:([bool]$smbStepFailed) `
            -HealthCritical:$healthCriticalFailure
    } elseif ($logStatistics.Warnings -gt 0) {
        $script:processExitCode = Resolve-BRAVOExitCode -HasWarnings
    }
}

# Запуск головної функції
$script:processExitCode = 0
$script:archiveProcessLock = $null
$script:archiveProcessLockPath = $null
try {
    Main
} catch {
    # Значення тут здебільшого символічне: throw нижче не дає скрипту дійти
    # до власного Exit, і саме .psm1-обгортка (try/catch навколо виклику
    # runtime, коміт 1ba0bbb) визначає код, що реально побачить процес —
    # вона так само повертає 90. Лишаємо узгодженим із контрактом.
    $script:processExitCode = 90
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
