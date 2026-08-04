##########
# BravoSoft
# Read-only health monitoring for BRAVO backups and managed services.
# This file is intentionally the single runtime owner of health functionality.
##########

param(
    [string]$ConfigPath,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$EntryScriptPath
)
function Invoke-BRAVOHealth {
    param(
        [string]$ConfigPath,
        [switch]$ForceNotification,
        [switch]$NotifyOnSuccess,
        [switch]$NoSlack,
        [switch]$SkipIfBackupTaskRunning
    )

function Complete-BRAVOHealthResult {
    param([Parameter(Mandatory = $true)]$Result)
    return $Result
}

$bravoScriptDirectory = $RuntimeRoot

# Health використовує спільні модулі, а не копії з архіватора.
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveRuntime', 'BRAVO.Logging', 'BRAVO.ExitCodes')) {
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

try {
    Enable-BRAVOTls12
} catch {
    # Health-check зможе виконати локальні перевірки навіть тоді, коли
    # TLS 1.2 не підтримується системним .NET/Schannel.
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

$healthCheckStarted = Get-Date
$script:healthLatestArchives = @{}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    Write-Error "Файл конфігурації не знайдено: $ConfigPath"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "ConfigurationError"
        IssueCount = 0
        Notification = "NotSent"
    })
}

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

    $ConfigPath = [string]$global:BravoConfigurationMetadata.ConfigPath
    if ($null -ne $credentialSettings) {
        [void](Import-BRAVOInstitutionSettings `
            -CredentialSettings $credentialSettings `
            -BravoSettings $bravoSettings)
    }
} catch {
    Write-Error "Не вдалося завантажити конфігурацію: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "ConfigurationError"
        IssueCount = 0
        Notification = "NotSent"
    })
}

function Test-BRAVOSettingEnabled {
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($null -eq $Value) {
        return $false
    }

    # Не використовуємо пряме [bool]"false": у PowerShell будь-який
    # непорожній рядок перетворюється на $true.
    return ([string]$Value).Trim() -match '^(?i:true|1|yes|on)$'
}

$bazaLocalHealthEnabled = Test-BRAVOSettingEnabled `
    -Value $componentSettings.Synchronization.BAZALocal
$bazaSFTPHealthEnabled = Test-BRAVOSettingEnabled `
    -Value $componentSettings.Synchronization.BAZASFTP
$bazaWWWSFTPHealthEnabled = Test-BRAVOSettingEnabled `
    -Value $componentSettings.Synchronization.BAZAWWWSFTP

$healthLogTimestamp = $healthCheckStarted.ToString($logFileDateFormat)
$healthLogName = $backupMonitoring.LogFileNameTemplate -f $healthLogTimestamp
$healthLogFile = Join-Path $logPath $healthLogName

$credentialHelperLoaded = $false
$credentialHelperError = $null
$notificationCredentialError = $null
$sftpCredentialError = $null
$smbCredentialError = $null
$script:smbCredential = $null
# Лічильник WARNING для контракту кодів завершення: успіх без жодного
# попередження -> 0, успіх із попередженнями -> 10 (Resolve-BRAVOExitCode).
# Ініціалізується тут явно, а не лише в Write-HealthLog — інакше перше ж
# читання під Set-StrictMode впало б, якщо жодного попередження не було.
$script:BRAVOWarningCount = 0
# Кеш каталогу тимчасових файлів WinSCP. Get-BRAVOHealthTemporaryRoot читає
# його ще до першого присвоєння, а Set-StrictMode (успадкований від
# конфігураційного завантажувача) робить читання неоголошеної змінної помилкою.
$script:bravoHealthTemporaryRoot = $null
try {
    if ($null -eq $credentialSettings -or $null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
        throw 'вбудований Credential Manager недоступний'
    }
    $credentialHelperLoaded = $true
} catch {
    $credentialHelperError = $_.Exception.Message
}

$NotificationProvider = ([string]$backupMonitoring.NotificationProvider).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($NotificationProvider)) {
    $NotificationProvider = "discord"
}
$NotificationMode = [string]$backupMonitoring.NotificationMode
if ([string]::IsNullOrWhiteSpace($NotificationMode)) {
    # Сумісність зі старим BRAVO.config.
    $NotificationMode = [string]$backupMonitoring.SlackMode
}
$NotificationMode = $NotificationMode.ToLowerInvariant()
$NotificationWebhookUrl = $null
$notificationCredentialTarget = if ($NotificationProvider -eq "discord") {
    [string]$backupMonitoring.NotificationCredentialTargets.DiscordWebhook
} else {
    [string]$backupMonitoring.NotificationCredentialTargets.SlackWebhook
}
if ([string]::IsNullOrWhiteSpace($notificationCredentialTarget)) {
    $notificationCredentialTarget = if ($NotificationProvider -eq "discord") {
        "BRAVO_DISCORD_URL"
    } else {
        "BRAVO_SLACK_URL"
    }
}
if ($NotificationMode -ne "none" -and $credentialHelperLoaded) {
    try {
        if ([string]::IsNullOrWhiteSpace($notificationCredentialTarget)) {
            throw "не налаштовано назву Credential Manager для $NotificationProvider"
        }
        $NotificationWebhookUrl = Get-BRAVOCredentialSecret -Target $notificationCredentialTarget
        if ([string]::IsNullOrWhiteSpace($NotificationWebhookUrl)) {
            throw "запис Credential Manager '$notificationCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
    } catch {
        $notificationCredentialError = $_.Exception.Message
    }
} elseif ($NotificationMode -ne "none") {
    $notificationCredentialError = $credentialHelperError
}

$script:Login = $null
$script:resolvedSftpHost = $null
$script:sftpUrl = $null
$sftpCredentialRequired = [bool]$backupMonitoring.SFTP.Enabled -and
    (([bool]$backupMonitoring.SFTP.CheckArchiveUploads -and [bool]$componentSettings.SFTP.ArchiveUpload) -or
    ([bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
    ($bazaSFTPHealthEnabled -or $bazaWWWSFTPHealthEnabled)))
if ($sftpCredentialRequired -and $credentialHelperLoaded) {
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
        $sftpCredentialError = $_.Exception.Message
    }
} elseif ($sftpCredentialRequired) {
    $sftpCredentialError = $credentialHelperError
}

$smbCredentialRequired = [bool]$backupMonitoring.SMB.Enabled -and
    [bool]$backupMonitoring.SMB.CheckArchiveCopies -and
    [bool]$componentSettings.SMB.ArchiveCopy
if ($smbCredentialRequired -and $credentialHelperLoaded) {
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
        $smbCredentialError = $_.Exception.Message
    }
} elseif ($smbCredentialRequired) {
    $smbCredentialError = $credentialHelperError
}

$NotificationRequestTimeoutSeconds = if ($null -ne $backupMonitoring.NotificationRequestTimeoutSeconds) {
    [math]::Max(1, [int]$backupMonitoring.NotificationRequestTimeoutSeconds)
} elseif ($null -ne $backupMonitoring.SlackRequestTimeoutSeconds) {
    [math]::Max(1, [int]$backupMonitoring.SlackRequestTimeoutSeconds)
} else {
    30
}
$NotificationProviderDisplayName = if ($NotificationProvider -eq "discord") { "Discord" } else { "Slack" }

function Write-HealthLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    # SFTP URL із паролем, webhook чи інший секрет можуть потрапити сюди
    # через повідомлення винятку WinSCP/Invoke-WebRequest — маскуємо перед
    # тим, як щось піде в консоль чи файл.
    $Message = Protect-BRAVOLogSecret -Text $Message
    if ($Level -eq "WARNING") {
        $script:BRAVOWarningCount++
    }

    $timestamp = Get-Date -Format $logTimestampFormat
    $entry = "[$timestamp] [$Level] $Message"
    $consoleEntry = if ($consoleSettings.ShowTimestampsInConsole) {
        $entry
    } else {
        "[$Level] $Message"
    }
    Write-Host $consoleEntry

    try {
        if (-not (Test-Path -Path $logPath -PathType Container)) {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        $entry | Out-File -FilePath $healthLogFile -Append -Encoding $logFileEncoding
    } catch {
        Write-Host "Не вдалося записати health-check лог: $($_.Exception.Message)"
    }
}







function Format-FileSize {
    param([Nullable[long]]$Bytes)

    if ($null -eq $Bytes) {
        return "немає даних"
    }

    if ($Bytes -ge 1TB) {
        return "$([math]::Round($Bytes / 1TB, 2)) ТБ"
    }
    if ($Bytes -ge 1GB) {
        return "$([math]::Round($Bytes / 1GB, 2)) ГБ"
    }
    if ($Bytes -ge 1MB) {
        return "$([math]::Round($Bytes / 1MB, 2)) МБ"
    }
    if ($Bytes -ge 1KB) {
        return "$([math]::Round($Bytes / 1KB, 2)) КБ"
    }
    return "$Bytes Б"
}

function Format-BackupAge {
    param([object]$LastWriteTime)

    if ($null -eq $LastWriteTime) {
        return "немає даних"
    }

    $age = (Get-Date) - [datetime]$LastWriteTime
    if ($age.TotalMinutes -lt 0) {
        return "0 хв."
    }
    if ($age.TotalHours -lt 1) {
        return "$([math]::Floor($age.TotalMinutes)) хв."
    }

    $hours = [math]::Floor($age.TotalHours)
    return "$hours год. $($age.Minutes) хв."
}

function Get-FileSHA512 {
    param([string]$Path)

    $stream = $null
    $hasher = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $hasher = [System.Security.Cryptography.SHA512]::Create()
        $hashBytes = $hasher.ComputeHash($stream)
        return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
    } finally {
        if ($stream) {
            $stream.Dispose()
        }
        if ($hasher) {
            $hasher.Dispose()
        }
    }
}

function Get-ExpectedArchiveSHA512 {
    param(
        [string]$HashPath,
        [string]$ArchiveName
    )

    $hashText = (Read-BRAVOTextFile -Path $HashPath).Trim([char]0xFEFF).Trim()
    if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
        throw "hash-файл має некоректний формат"
    }
    if ($Matches.FileName -cne $ArchiveName) {
        throw "hash-файл належить іншому архіву"
    }
    return $Matches.Hash.ToLowerInvariant()
}

function Test-BackupCandidate {
    param([System.IO.FileInfo]$Archive)

    $hashPath = "$($Archive.FullName)$hashFileExtension"
    if (-not (Test-Path -Path $hashPath -PathType Leaf)) {
        return [pscustomobject]@{
            Valid = $false
            Reason = "відсутній hash-файл"
        }
    }

    try {
        $hashText = [System.IO.File]::ReadAllText($hashPath).Trim([char]0xFEFF).Trim()
    } catch {
        return [pscustomobject]@{
            Valid = $false
            Reason = "не вдалося прочитати hash-файл: $($_.Exception.Message)"
        }
    }

    if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
        return [pscustomobject]@{
            Valid = $false
            Reason = "hash-файл має некоректний формат"
        }
    }

    if ($Matches.FileName -ne $Archive.Name) {
        return [pscustomobject]@{
            Valid = $false
            Reason = "hash-файл належить іншому архіву"
        }
    }

    if ($backupMonitoring.VerifyFileHash) {
        try {
            $actualHash = Get-FileSHA512 -Path $Archive.FullName
        } catch {
            return [pscustomobject]@{
                Valid = $false
                Reason = "не вдалося обчислити SHA512: $($_.Exception.Message)"
            }
        }

        if ($actualHash -ne $Matches.Hash.ToLowerInvariant()) {
            return [pscustomobject]@{
                Valid = $false
                Reason = "SHA512 архіву не збігається"
            }
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Reason = ""
    }
}

function Test-ArchiveFileName {
    param(
        [string]$FileName,
        [hashtable]$ArchiveDefinition
    )

    # Ім'я має точно відповідати шаблону, який використовує BRAVO_ARCHIV.ps1.
    # Завдяки цьому архіви BRAVO_MAINTENANCE.ps1 з частинами _before_ та _after_
    # не потрапляють до кандидатів health-check.
    $timestampToken = "__BRAVO_ARCHIVE_TIMESTAMP__"
    try {
        $nameWithToken = [string]$ArchiveDefinition.NameTemplate -f $archivePrefix, $timestampToken
    } catch {
        return $false
    }

    $escapedName = [regex]::Escape($nameWithToken)
    $escapedToken = [regex]::Escape($timestampToken)
    $namePattern = "^$($escapedName.Replace($escapedToken, '(?<Timestamp>.+)'))$"
    $nameMatch = [regex]::Match(
        $FileName,
        $namePattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $nameMatch.Success) {
        return $false
    }

    $parsedTimestamp = [datetime]::MinValue
    return [datetime]::TryParseExact(
        $nameMatch.Groups["Timestamp"].Value,
        $archiveTimestampFormat,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsedTimestamp
    )
}

function Get-LocalBackupState {
    param([hashtable]$ArchiveDefinition)

    $candidateLimit = [math]::Max(1, [int]$backupMonitoring.CandidateLimit)
    $candidates = @()
    if (Test-Path -Path $ArchiveDefinition.Destination -PathType Container) {
        $candidates = @(
            Get-BRAVOFiles -Path $ArchiveDefinition.Destination -Filter $archiveFileFilter |
                Where-Object { Test-ArchiveFileName -FileName $_.Name -ArchiveDefinition $ArchiveDefinition } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First $candidateLimit
        )
    }

    $newestValidArchive = $null
    foreach ($candidate in $candidates) {
        $candidateResult = Test-BackupCandidate -Archive $candidate
        if ($candidateResult.Valid) {
            $newestValidArchive = $candidate
            break
        }
    }

    return [pscustomobject]@{
        Candidates = $candidates
        NewestValidArchive = $newestValidArchive
    }
}

function Get-BackupHealthIssues {
    $issues = @()
    $enabledArchiveDefinitions = @($archiveDefinitions | Where-Object { $_.Enabled })
    $maximumAge = [timespan]::FromHours([double]$backupMonitoring.MaxBackupAgeHours)

    foreach ($archiveDefinition in $enabledArchiveDefinitions) {
        $localState = Get-LocalBackupState -ArchiveDefinition $archiveDefinition
        $candidates = @($localState.Candidates)

        if ($candidates.Count -eq 0) {
            $expectedArchiveName = [string]$archiveDefinition.NameTemplate -f $archivePrefix, $archiveTimestampFormat
            $issues += [pscustomobject]@{
                Kind = "LocalBackup"
                Component = $archiveDefinition.Type
                Reason = "резервну копію не знайдено"
                FileName = "не знайдено ($expectedArchiveName)"
                LastWriteTime = $null
                SizeBytes = $null
            }
            continue
        }

        $newestValidArchive = $localState.NewestValidArchive

        if ($null -eq $newestValidArchive) {
            $newestCandidate = $candidates[0]
            $newestCandidateResult = Test-BackupCandidate -Archive $newestCandidate
            $issues += [pscustomobject]@{
                Kind = "LocalBackup"
                Component = $archiveDefinition.Type
                Reason = "немає коректної резервної копії: $($newestCandidateResult.Reason)"
                FileName = $newestCandidate.Name
                LastWriteTime = $newestCandidate.LastWriteTime
                SizeBytes = $newestCandidate.Length
            }
            continue
        }

        $backupAge = $healthCheckStarted - $newestValidArchive.LastWriteTime
        if ($backupAge -gt $maximumAge) {
            $newerInvalidCount = @($candidates | Where-Object { $_.LastWriteTime -gt $newestValidArchive.LastWriteTime }).Count
            $reason = "остання коректна копія старша за $($backupMonitoring.MaxBackupAgeHours) год."
            if ($newerInvalidCount -gt 0) {
                $reason += "; новіші файли не пройшли перевірку"
            }

            $issues += [pscustomobject]@{
                Kind = "LocalBackup"
                Component = $archiveDefinition.Type
                Reason = $reason
                FileName = $newestValidArchive.Name
                LastWriteTime = $newestValidArchive.LastWriteTime
                SizeBytes = $newestValidArchive.Length
            }
        } else {
            $script:healthLatestArchives[$archiveDefinition.Type] = [pscustomobject]@{
                Name = $newestValidArchive.Name
                SizeBytes = [long]$newestValidArchive.Length
            }
            Write-HealthLog "Бекап $($archiveDefinition.Type) справний: $($newestValidArchive.Name), вік $(Format-BackupAge $newestValidArchive.LastWriteTime), розмір $(Format-FileSize $newestValidArchive.Length)" -Level "SUCCESS"
        }
    }

    return @($issues)
}

function Get-BAZALocalHealthIssues {
    if (-not $bazaLocalHealthEnabled) {
        return @()
    }

    $sourcePath = [string]$bazaPaths.Source
    $destinationPath = [string]$bazaPaths.Destination
    $issueBase = @{
        Kind = "LocalSynchronization"
        Component = "Локальна BAZA"
        FileName = "каталог BAZA"
        LastWriteTime = $null
        SizeBytes = $null
        DifferenceCount = $null
        Details = @()
        Source = $sourcePath
        Location = $destinationPath
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        return @([pscustomobject]($issueBase + @{
            Reason = "джерельний каталог BAZA не знайдено"
        }))
    }

    if ([bool]$synchronizationSafety.RequireNonEmptyBAZASource) {
        $firstSourceFile = Get-BRAVOFiles `
            -LiteralPath $sourcePath `
            -Recurse `
            -Force `
            |
            Select-Object -First 1
        if ($null -eq $firstSourceFile) {
            return @([pscustomobject]($issueBase + @{
                Reason = "джерельний каталог BAZA порожній"
            }))
        }
    }

    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
        return @([pscustomobject]($issueBase + @{
            Reason = "локальну копію BAZA не знайдено"
        }))
    }

    $robocopyCommand = Get-Command -Name $robocopyPath -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $robocopyCommand) {
        return @([pscustomobject]($issueBase + @{
            Reason = "robocopy не знайдено; локальну BAZA не перевірено"
        }))
    }

    $process = $null
    try {
        # /L гарантує read-only перевірку. /E відповідає режиму, який
        # BRAVO_ARCHIV.ps1 використовує для локальної копії BAZA.
        $arguments = @(
            "`"$sourcePath`"",
            "`"$destinationPath`"",
            "/E",
            "/L",
            "/R:0",
            "/W:0",
            "/XJ",
            "/NFL",
            "/NDL",
            "/NJH",
            "/NJS",
            "/NP",
            "/LOG:NUL"
        )
        $process = Start-Process `
            -FilePath $robocopyCommand.Source `
            -ArgumentList $arguments `
            -PassThru `
            -WindowStyle Hidden

        $timeoutSeconds = [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                Write-HealthLog "Не вдалося завершити robocopy після таймауту: $($_.Exception.Message)" -Level "DEBUG"
            }
            return @([pscustomobject]($issueBase + @{
                Reason = "перевищено таймаут локальної перевірки BAZA ($timeoutSeconds сек.)"
            }))
        }

        $exitCode = [int]$process.ExitCode
        if (($exitCode -band 24) -ne 0) {
            return @([pscustomobject]($issueBase + @{
                Reason = "robocopy не зміг порівняти каталоги (код: $exitCode)"
                ExitCode = $exitCode
            }))
        }

        # 1 = є файли для копіювання, 4 = є невідповідності.
        # Біт 2 (зайві файли у призначенні) не є помилкою, бо робоча
        # синхронізація використовує /E, а не /MIR.
        if (($exitCode -band 5) -ne 0) {
            return @([pscustomobject]($issueBase + @{
                Reason = "локальна копія BAZA неактуальна"
                ExitCode = $exitCode
            }))
        }

        Write-HealthLog "Локальна BAZA справна: $sourcePath відповідає $destinationPath" -Level "SUCCESS"
        return @()
    } catch {
        return @([pscustomobject]($issueBase + @{
            Reason = "не вдалося порівняти локальну BAZA: $($_.Exception.Message)"
        }))
    } finally {
        if ($process) {
            $process.Dispose()
        }
    }
}

function Normalize-SFTPPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "/"
    }

    $normalized = $Path.Replace("\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "/"
    }
    return "/$normalized"
}

function Test-BRAVOPathWithinDirectory {
    param(
        [string]$Path,
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        [string]::IsNullOrWhiteSpace($Directory)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
        $directoryPrefix = $fullDirectory.TrimEnd("\", "/") +
            [System.IO.Path]::DirectorySeparatorChar
        return $fullPath.StartsWith(
            $directoryPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        return $false
    }
}

function Test-BRAVOAsciiPath {
    param([string]$Path)

    return (
        -not [string]::IsNullOrWhiteSpace($Path) -and
        $Path -notmatch '[^\x00-\x7F]'
    )
}

function Get-BRAVOHealthTemporaryRoot {
    if (-not [string]::IsNullOrWhiteSpace(
            [string]$script:bravoHealthTemporaryRoot
        ) -and
        (Test-Path `
            -LiteralPath $script:bravoHealthTemporaryRoot `
            -PathType Container)) {
        return $script:bravoHealthTemporaryRoot
    }

    $candidateRoots = @(
        (Join-Path $bravoScriptDirectory "TEMP")
    )
    $commonApplicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData
    )
    if (-not [string]::IsNullOrWhiteSpace($commonApplicationData)) {
        $candidateRoots += Join-Path $commonApplicationData "BRAVO\TEMP"
    }
    $systemTemporaryRoot = [System.IO.Path]::GetTempPath()
    if (Test-BRAVOAsciiPath -Path $systemTemporaryRoot) {
        $candidateRoots += Join-Path $systemTemporaryRoot "BRAVO"
    }

    $creationErrors = @()
    foreach ($candidateRoot in @($candidateRoots | Select-Object -Unique)) {
        if (-not (Test-BRAVOAsciiPath -Path $candidateRoot)) {
            continue
        }
        try {
            if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) {
                New-Item `
                    -ItemType Directory `
                    -Path $candidateRoot `
                    -Force `
                    -ErrorAction Stop |
                    Out-Null
            }
            $resolvedRoot = (Resolve-Path `
                -LiteralPath $candidateRoot `
                -ErrorAction Stop).Path
            if (Test-BRAVOAsciiPath -Path $resolvedRoot) {
                $script:bravoHealthTemporaryRoot = $resolvedRoot
                return $resolvedRoot
            }
        } catch {
            $creationErrors += "$candidateRoot`: $($_.Exception.Message)"
        }
    }

    $details = if ($creationErrors.Count -gt 0) {
        "; " + ($creationErrors -join "; ")
    } else {
        ""
    }
    throw (
        "не знайдено доступного ASCII-каталогу для тимчасових файлів " +
        "WinSCP$details"
    )
}

function Remove-BRAVOHealthTemporaryDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $leafName = Split-Path -Path $fullPath -Leaf
        $allowedRoots = @(
            [System.IO.Path]::GetTempPath()
        )
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$script:bravoHealthTemporaryRoot
            )) {
            $allowedRoots += $script:bravoHealthTemporaryRoot
        }
        $isWithinAllowedRoot = $false
        foreach ($allowedRoot in @($allowedRoots | Select-Object -Unique)) {
            if (Test-BRAVOPathWithinDirectory `
                -Path $fullPath `
                -Directory $allowedRoot) {
                $isWithinAllowedRoot = $true
                break
            }
        }
        $isSafeTarget = (
            $isWithinAllowedRoot -and
            $leafName -match '^BRAVO_HEALTH_[0-9a-f]{32}$'
        )
        if (-not $isSafeTarget) {
            Write-HealthLog "Пропущено очищення неочікуваного тимчасового шляху: $fullPath" -Level "WARNING"
            return
        }
        if ([System.IO.Directory]::Exists($fullPath)) {
            [System.IO.Directory]::Delete($fullPath, $true)
        }
    } catch {
        Write-HealthLog "Не вдалося очистити тимчасовий каталог health-check: $($_.Exception.Message)" -Level "WARNING"
    }
}

function ConvertTo-WinSCPScriptArgument {
    param([string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-CompactWinSCPError {
    param(
        [string]$Text,
        [int]$MaximumLength = 300
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "немає деталей"
    }
    if ($Text -match '(?i)Server refused to start a shell/command') {
        return "SFTP-сервер забороняє серверний checksum/shell"
    }

    $compact = ($Text -replace '(?i)Authentication log.*$', '') -replace '\s+', ' '
    $compact = $compact.Trim(" ", ";", ".")
    $safeMaximumLength = [math]::Max(40, $MaximumLength)
    if ($compact.Length -gt $safeMaximumLength) {
        return $compact.Substring(0, $safeMaximumLength - 3) + "..."
    }
    return $compact
}

function Test-SFTPHealthConfiguration {
    param(
        [bool]$CheckArchives,
        [bool]$CheckBAZA,
        [bool]$CheckBAZAWWW
    )

    $errors = @()
    if (-not [string]::IsNullOrWhiteSpace($sftpCredentialError)) {
        $errors += $sftpCredentialError
    }
    if ([string]::IsNullOrWhiteSpace($Login)) {
        $errors += "не завантажено SFTP логін з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace($sftpUrl) -or -not $sftpUrl.StartsWith("sftp://")) {
        $errors += "не вдалося сформувати SFTP URL із захищених облікових даних"
    }
    if ([string]::IsNullOrWhiteSpace($sftpHostKey)) {
        $errors += "не встановлено SFTP host key"
    }
    if ([string]::IsNullOrWhiteSpace($winSCPPath) -or -not (Test-Path -Path $winSCPPath -PathType Leaf)) {
        $errors += "не знайдено WinSCP"
    }
    if ([int]$backupMonitoring.SFTP.OperationTimeoutSeconds -le 0) {
        $errors += "таймаут SFTP-перевірки повинен бути більшим за 0"
    }

    if ($CheckArchives) {
        if ([double]$backupMonitoring.SFTP.RemoteBackupMaxAgeHours -le 0) {
            $errors += "максимальний вік віддаленого бекапу повинен бути більшим за 0"
        }
        foreach ($archiveDefinition in @($archiveDefinitions | Where-Object { $_.Enabled })) {
            if (-not $sftpDirectories.ContainsKey($archiveDefinition.Type) -or
                [string]::IsNullOrWhiteSpace($sftpDirectories[$archiveDefinition.Type])) {
                $errors += "не встановлено SFTP каталог для $($archiveDefinition.Type)"
            }
        }
    }

    if ($CheckBAZA -and
        (-not $sftpDirectories.ContainsKey("BAZA") -or [string]::IsNullOrWhiteSpace($sftpDirectories.BAZA))) {
        $errors += "не встановлено SFTP каталог для BAZA"
    }
    if ($CheckBAZAWWW -and
        (-not $sftpDirectories.ContainsKey("BAZAWWW") -or
        [string]::IsNullOrWhiteSpace($sftpDirectories.BAZAWWW))) {
        $errors += "не встановлено SFTP каталог для BAZA WWW"
    }
    $checkFolderSynchronization = $CheckBAZA -or $CheckBAZAWWW
    if ($checkFolderSynchronization -and
        ([string]::IsNullOrWhiteSpace($backupMonitoring.SFTP.BAZAPreviewOptions) -or
        $backupMonitoring.SFTP.BAZAPreviewOptions -notmatch '(?i)(^|\s)-preview(\s|$)')) {
        $errors += "BAZAPreviewOptions обов'язково повинен містити -preview"
    }
    if ($checkFolderSynchronization -and
        [string]$backupMonitoring.SFTP.BAZAPreviewOptions -match '(?i)(^|\s)-delete(\s|$)') {
        $errors += "опція -delete заборонена для BAZA: віддалені файли мають зберігатися для відновлення"
    }
    if ($checkFolderSynchronization -and
        [string]$sftpSynchronizationOptions -match '(?i)(^|\s)-delete(\s|$)') {
        $errors += "sftpSynchronizationOptions містить заборонену опцію -delete для BAZA"
    }
    if ($checkFolderSynchronization -and
        [int]$backupMonitoring.SFTP.DifferenceDetailLimit -le 0) {
        $errors += "ліміт деталей SFTP-розбіжностей повинен бути більшим за 0"
    }
    return [pscustomobject]@{
        Valid = $errors.Count -eq 0
        Errors = @($errors)
    }
}

function Get-SFTPRemoteArchiveChecksumResults {
    param([object[]]$ArchiveChecks)

    $results = @{}
    foreach ($archiveCheck in @($ArchiveChecks)) {
        $results[$archiveCheck.LocalArchive.FullName] = [pscustomobject]@{
            Success = $false
            Hash = $null
            Algorithm = $null
            Error = "перевірку контрольної суми не виконано"
        }
    }

    $components = Get-BRAVOWinSCPDotNetComponents `
        -WinSCPAssemblyPath ([string]$winSCPAssemblyPath) `
        -WinSCPPath ([string]$winSCPPath)
    if ($null -eq $components) {
        Write-HealthLog (
            "WinSCPnet.dll + WinSCP.exe недоступні; " +
            "контрольні суми SFTP перевіряються через WinSCP.com"
        ) -Level "INFO"
        return Get-SFTPRemoteArchiveChecksumResultsViaCli -ArchiveChecks $ArchiveChecks
    }

    $session = $null
    $serverChecksumUnavailable = $false
    try {
        if (-not ("WinSCP.Session" -as [type])) {
            Add-Type -Path $components.AssemblyPath -ErrorAction Stop
        }
        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.ParseUrl($sftpUrl)
        $sessionOptions.SshHostKeyFingerprint = ([string]$sftpHostKey).Trim().Trim('"')
        $sessionOptions.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds)
        )

        $session = New-Object WinSCP.Session
        $session.ExecutablePath = $components.ExecutablePath
        $session.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        )
        $session.Open($sessionOptions)

        foreach ($archiveCheck in @($ArchiveChecks)) {
            $key = $archiveCheck.LocalArchive.FullName
            if ($serverChecksumUnavailable) {
                $results[$key].Error =
                    "SFTP-сервер забороняє серверний checksum/shell"
                continue
            }
            $remoteArchivePath = "{0}/{1}" -f `
                $archiveCheck.RemoteDirectory.TrimEnd('/'), `
                $archiveCheck.LocalArchive.Name
            $algorithmErrors = @()
            foreach ($algorithm in @("sha-512", "sha-256")) {
                try {
                    $checksumBytes = $session.CalculateFileChecksum($algorithm, $remoteArchivePath)
                    $results[$key] = [pscustomobject]@{
                        Success = $true
                        Hash = [System.BitConverter]::ToString($checksumBytes).Replace("-", "").ToLowerInvariant()
                        Algorithm = $algorithm
                        Error = $null
                    }
                    break
                } catch {
                    $algorithmError = $_.Exception.Message
                    $algorithmErrors += "${algorithm}: $algorithmError"
                    if ($algorithmError -match '(?i)Server refused to start a shell/command') {
                        $serverChecksumUnavailable = $true
                        break
                    }
                }
            }
            if (-not $results[$key].Success) {
                $results[$key] = [pscustomobject]@{
                    Success = $false
                    Hash = $null
                    Algorithm = $null
                    Error = $algorithmErrors -join "; "
                }
            }
        }
    } catch {
        foreach ($archiveCheck in @($ArchiveChecks)) {
            $key = $archiveCheck.LocalArchive.FullName
            if (-not $results[$key].Success) {
                $results[$key].Error = $_.Exception.Message
            }
        }
    } finally {
        if ($session) {
            $session.Dispose()
        }
    }

    $failedChecks = @(
        $ArchiveChecks |
            Where-Object { -not $results[$_.LocalArchive.FullName].Success }
    )
    if ($failedChecks.Count -gt 0 -and $serverChecksumUnavailable) {
        Write-HealthLog (
            "SFTP-сервер не підтримує серверний checksum; " +
            "перевірка архівів продовжується через віддалені .sha512"
        ) -Level "INFO"
    } elseif ($failedChecks.Count -gt 0) {
        Write-HealthLog (
            "Для $($failedChecks.Count) SFTP-архівів перевірка через WinSCP .NET " +
            "не вдалася; використовується WinSCP.com"
        ) -Level "WARNING"
        $cliResults = Get-SFTPRemoteArchiveChecksumResultsViaCli `
            -ArchiveChecks $failedChecks
        foreach ($archiveCheck in $failedChecks) {
            $key = $archiveCheck.LocalArchive.FullName
            if ($cliResults[$key].Success) {
                $results[$key] = $cliResults[$key]
            } else {
                $dotNetError = [string]$results[$key].Error
                $cliError = [string]$cliResults[$key].Error
                $results[$key].Error =
                    ".NET: $dotNetError; WinSCP.com: $cliError"
            }
        }
    }

    return $results
}

function Invoke-WinSCPHealthSession {
    param([string[]]$Commands)

    $temporaryName = "BRAVO_ARCHIV_HEALTH_$([guid]::NewGuid().ToString('N'))"
    # WinSCP-командний файл може навмисно використовувати ASCII для сумісності
    # зі старими версіями клієнта. Тому всі вставлені в нього локальні шляхи,
    # а також службові файли сеансу тримаємо в гарантовано ASCII-каталозі.
    $temporaryRoot = Get-BRAVOHealthTemporaryRoot
    $temporaryScriptPath = Join-Path $temporaryRoot "$temporaryName.txt"
    $temporaryXmlPath = Join-Path $temporaryRoot "$temporaryName.xml"
    $process = $null

    try {
        $scriptLines = @(
            "option batch continue",
            "option confirm off",
            "open $sftpUrl -hostkey=$sftpHostKey -timeout=$sftpConnectionTimeoutSeconds"
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
            throw (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "SFTP health-check")
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process

        $timeoutSeconds = [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        $completed = $process.WaitForExit($timeoutSeconds * 1000)
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                Write-HealthLog "Не вдалося завершити WinSCP після таймауту: $($_.Exception.Message)" -Level "DEBUG"
            }
            if ($null -ne $outputCapture) {
                [void](Complete-BRAVOProcessOutputCapture -Capture $outputCapture)
                $outputCapture = $null
            }
            throw "перевищено таймаут SFTP-перевірки ($timeoutSeconds сек.)"
        }

        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError

        if (-not (Test-Path -Path $temporaryXmlPath -PathType Leaf)) {
            throw "WinSCP не створив XML-журнал (код: $($process.ExitCode))"
        }

        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.Load($temporaryXmlPath)
        } catch {
            throw "не вдалося прочитати XML-журнал WinSCP: $($_.Exception.Message)"
        }

        if ($process.ExitCode -ne 0) {
            Write-HealthLog "WinSCP health-check завершився з кодом $($process.ExitCode); аналізуємо доступні XML-результати" -Level "WARNING"
        }

        return [pscustomobject]@{
            Success = $true
            ExitCode = $process.ExitCode
            Xml = $xml
            Output = $output
            ErrorOutput = $errorOutput
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
        foreach ($temporaryPath in @($temporaryScriptPath, $temporaryXmlPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
        if ($process) {
            $process.Dispose()
        }
    }
}

function New-WinSCPNamespaceManager {
    param([System.Xml.XmlDocument]$Xml)

    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $namespaceManager.AddNamespace("w", "http://winscp.net/schema/session/1.0")
    return ,$namespaceManager
}

function Get-WinSCPXmlFailureText {
    param(
        [System.Xml.XmlDocument]$Xml,
        [int]$MaximumMessages = 5
    )

    if ($null -eq $Xml) {
        return ""
    }

    $namespaceManager = New-WinSCPNamespaceManager -Xml $Xml
    $messages = @(
        $Xml.SelectNodes("//w:failure/w:message", $namespaceManager) |
            ForEach-Object { ([string]$_.InnerText).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique -First ([math]::Max(1, $MaximumMessages))
    )
    return $messages -join "; "
}

function Get-SFTPRemoteArchiveChecksumResultsViaCli {
    param([object[]]$ArchiveChecks)

    $results = @{}
    $errorsByKey = @{}
    foreach ($archiveCheck in @($ArchiveChecks)) {
        $key = $archiveCheck.LocalArchive.FullName
        $results[$key] = [pscustomobject]@{
            Success = $false
            Hash = $null
            Algorithm = $null
            Error = "WinSCP.com не повернув контрольну суму"
        }
        $errorsByKey[$key] = @()
    }

    # SHA512 є основним алгоритмом. SHA256 запускається другим окремим
    # проходом лише для тих серверів/файлів, де SHA512 недоступний.
    foreach ($algorithm in @("sha-512", "sha-256")) {
        $pendingChecks = @(
            $ArchiveChecks |
                Where-Object { -not $results[$_.LocalArchive.FullName].Success }
        )
        if ($pendingChecks.Count -eq 0) {
            break
        }

        $commands = @(
            $pendingChecks |
                ForEach-Object {
                    $remoteArchivePath = "{0}/{1}" -f `
                        $_.RemoteDirectory.TrimEnd('/'), `
                        $_.LocalArchive.Name
                    "checksum $algorithm $(ConvertTo-WinSCPScriptArgument $remoteArchivePath)"
                }
        )
        $sessionResult = Invoke-WinSCPHealthSession -Commands $commands
        if (-not $sessionResult.Success) {
            foreach ($archiveCheck in $pendingChecks) {
                $key = $archiveCheck.LocalArchive.FullName
                $errorsByKey[$key] += "${algorithm}: $($sessionResult.Error)"
            }
            continue
        }

        $namespaceManager = New-WinSCPNamespaceManager -Xml $sessionResult.Xml
        $checksumNodes = @(
            $sessionResult.Xml.SelectNodes("//w:checksum", $namespaceManager)
        )
        $failureText = Get-WinSCPXmlFailureText -Xml $sessionResult.Xml
        $serverCommandUnavailable = (
            $algorithm -eq "sha-512" -and
            $failureText -match '(?i)Server refused to start a shell/command'
        )
        $expectedLength = if ($algorithm -eq "sha-512") { 128 } else { 64 }

        foreach ($archiveCheck in $pendingChecks) {
            $key = $archiveCheck.LocalArchive.FullName
            $remoteArchivePath = Normalize-SFTPPath (
                "{0}/{1}" -f `
                    $archiveCheck.RemoteDirectory.TrimEnd('/'), `
                    $archiveCheck.LocalArchive.Name
            )
            $matchingNode = @(
                $checksumNodes |
                    Where-Object {
                        $fileNode = $_.SelectSingleNode("w:filename", $namespaceManager)
                        $algorithmNode = $_.SelectSingleNode("w:algorithm", $namespaceManager)
                        $resultNode = $_.SelectSingleNode("w:result", $namespaceManager)
                        $fileNode -and
                            $algorithmNode -and
                            $resultNode -and
                            $resultNode.GetAttribute("success") -eq "true" -and
                            (Normalize-SFTPPath ($fileNode.GetAttribute("value"))) -ceq $remoteArchivePath -and
                            $algorithmNode.GetAttribute("value") -ieq $algorithm
                    } |
                    Select-Object -First 1
            )
            if ($matchingNode.Count -eq 0) {
                $errorText = if (-not [string]::IsNullOrWhiteSpace($failureText)) {
                    $failureText
                } else {
                    "контрольну суму не повернуто (код: $($sessionResult.ExitCode))"
                }
                $errorsByKey[$key] += "${algorithm}: $errorText"
                continue
            }

            $hashNode = $matchingNode[0].SelectSingleNode(
                "w:checksum",
                $namespaceManager
            )
            $hashValue = if ($hashNode) {
                $hashNode.GetAttribute("value").Replace("-", "").ToLowerInvariant()
            } else {
                ""
            }
            if ($hashValue -notmatch "^[0-9a-f]{$expectedLength}$") {
                $errorsByKey[$key] += "${algorithm}: WinSCP.com повернув некоректний формат контрольної суми"
                continue
            }

            $results[$key] = [pscustomobject]@{
                Success = $true
                Hash = $hashValue
                Algorithm = $algorithm
                Error = $null
            }
        }

        if ($serverCommandUnavailable) {
            # Коли хостинг повністю забороняє запуск shell/command, повторна
            # спроба з іншим алгоритмом завершиться тією самою помилкою.
            break
        }
    }

    foreach ($archiveCheck in @($ArchiveChecks)) {
        $key = $archiveCheck.LocalArchive.FullName
        if (-not $results[$key].Success) {
            $errorParts = @($errorsByKey[$key] | Select-Object -Unique)
            $results[$key].Error = if ($errorParts.Count -gt 0) {
                $errorParts -join "; "
            } else {
                "WinSCP.com не повернув підтримувану SHA512/SHA256 контрольну суму"
            }
        }
    }

    return $results
}

function Get-WinSCPRemoteListings {
    param([System.Xml.XmlDocument]$Xml)

    $namespaceManager = New-WinSCPNamespaceManager -Xml $Xml
    $listings = @()

    foreach ($listingNode in @($Xml.SelectNodes("//w:ls", $namespaceManager))) {
        $destinationNode = $listingNode.SelectSingleNode("w:destination", $namespaceManager)
        $resultNode = $listingNode.SelectSingleNode("w:result", $namespaceManager)
        $files = @()

        foreach ($fileNode in @($listingNode.SelectNodes("w:files/w:file", $namespaceManager))) {
            $nameNode = $fileNode.SelectSingleNode("w:filename", $namespaceManager)
            $typeNode = $fileNode.SelectSingleNode("w:type", $namespaceManager)
            $sizeNode = $fileNode.SelectSingleNode("w:size", $namespaceManager)
            $modificationNode = $fileNode.SelectSingleNode("w:modification", $namespaceManager)
            $lastWriteTime = $null

            if ($modificationNode -and -not [string]::IsNullOrWhiteSpace($modificationNode.GetAttribute("value"))) {
                try {
                    $lastWriteTime = [datetimeoffset]::Parse(
                        $modificationNode.GetAttribute("value"),
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind
                    ).LocalDateTime
                } catch {
                    $lastWriteTime = $null
                }
            }

            $size = $null
            if ($sizeNode -and $sizeNode.GetAttribute("value") -match '^\d+$') {
                $size = [long]$sizeNode.GetAttribute("value")
            }

            $files += [pscustomobject]@{
                Name = if ($nameNode) { $nameNode.GetAttribute("value") } else { "" }
                Type = if ($typeNode) { $typeNode.GetAttribute("value") } else { "" }
                SizeBytes = $size
                LastWriteTime = $lastWriteTime
            }
        }

        $listings += [pscustomobject]@{
            Destination = if ($destinationNode) { Normalize-SFTPPath $destinationNode.GetAttribute("value") } else { "/" }
            Success = $resultNode -and $resultNode.GetAttribute("success") -eq "true"
            Files = @($files)
        }
    }

    return @($listings)
}

function Get-WinSCPRemoteDownloads {
    param([System.Xml.XmlDocument]$Xml)

    $namespaceManager = New-WinSCPNamespaceManager -Xml $Xml
    $downloads = @()
    foreach ($downloadNode in @(
        $Xml.SelectNodes("//w:download", $namespaceManager)
    )) {
        $fileNode = $downloadNode.SelectSingleNode("w:filename", $namespaceManager)
        $destinationNode = $downloadNode.SelectSingleNode(
            "w:destination",
            $namespaceManager
        )
        $resultNode = $downloadNode.SelectSingleNode("w:result", $namespaceManager)
        $messages = if ($resultNode) {
            @(
                $resultNode.SelectNodes("w:message", $namespaceManager) |
                    ForEach-Object { ([string]$_.InnerText).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        } else {
            @()
        }

        $downloads += [pscustomobject]@{
            RemotePath = if ($fileNode) {
                Normalize-SFTPPath ($fileNode.GetAttribute("value"))
            } else {
                ""
            }
            LocalPath = if ($destinationNode) {
                [Environment]::ExpandEnvironmentVariables(
                    $destinationNode.GetAttribute("value")
                )
            } else {
                ""
            }
            Success = $resultNode -and
                $resultNode.GetAttribute("success") -eq "true"
            Error = $messages -join "; "
        }
    }
    return @($downloads)
}

function Resolve-DownloadedRemoteHashPath {
    param(
        [object]$ArchiveCheck,
        [object[]]$Downloads
    )

    $remoteHashPath = Normalize-SFTPPath (
        "{0}/{1}{2}" -f `
            $ArchiveCheck.RemoteDirectory.TrimEnd('/'), `
            $ArchiveCheck.LocalArchive.Name, `
            $hashFileExtension
    )
    $download = @(
        $Downloads |
            Where-Object { $_.RemotePath -ceq $remoteHashPath } |
            Select-Object -Last 1
    )

    $candidatePaths = @()
    if ($download.Count -gt 0 -and $download[0].Success) {
        $candidatePaths += [string]$download[0].LocalPath
    }
    $candidatePaths += [string]$ArchiveCheck.RemoteHashDownloadPath

    foreach ($candidatePath in @(
        $candidatePaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )) {
        if ((Test-BRAVOPathWithinDirectory `
                -Path $candidatePath `
                -Directory $ArchiveCheck.RemoteHashDownloadDirectory) -and
            (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            return [pscustomobject]@{
                Path = (Resolve-Path -LiteralPath $candidatePath).Path
                Error = $null
            }
        }
    }

    # Старі версії WinSCP можуть застосувати operation mask і повернути інше
    # ім'я призначення. Каталог унікальний для одного sidecar, тому безпечно
    # знайти фактично створений файл у його межах.
    $createdFiles = if (Test-Path `
        -LiteralPath $ArchiveCheck.RemoteHashDownloadDirectory `
        -PathType Container) {
        @(
            Get-ChildItem `
                -LiteralPath $ArchiveCheck.RemoteHashDownloadDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    -not $_.PSIsContainer -and
                    $_.Name -ceq "$($ArchiveCheck.LocalArchive.Name)$hashFileExtension"
                }
        )
    } else {
        @()
    }
    if ($createdFiles.Count -eq 1 -and
        (Test-BRAVOPathWithinDirectory `
            -Path $createdFiles[0].FullName `
            -Directory $ArchiveCheck.RemoteHashDownloadDirectory)) {
        return [pscustomobject]@{
            Path = $createdFiles[0].FullName
            Error = $null
        }
    }

    $downloadError = if ($download.Count -eq 0) {
        "XML-журнал WinSCP не містить операції download для $remoteHashPath"
    } elseif (-not $download[0].Success) {
        if ([string]::IsNullOrWhiteSpace([string]$download[0].Error)) {
            "WinSCP позначив download як невдалий"
        } else {
            [string]$download[0].Error
        }
    } else {
        "WinSCP повідомив успішний download, але локальний файл не знайдено; destination=$($download[0].LocalPath)"
    }
    return [pscustomobject]@{
        Path = $null
        Error = $downloadError
    }
}

function Test-SFTPArchiveCopy {
    param(
        [hashtable]$ArchiveDefinition,
        [object]$LocalArchive,
        [object]$RemoteListing,
        [string]$RemoteDirectory,
        [string]$DownloadedRemoteHashPath,
        [object]$RemoteArchiveChecksumResult
    )

    $remotePath = Normalize-SFTPPath $RemoteDirectory
    if ($null -eq $RemoteListing -or -not $RemoteListing.Success) {
        return [pscustomobject]@{
            Kind = "SFTPArchive"
            Component = "SFTP $($ArchiveDefinition.Type)"
            Reason = "не вдалося прочитати віддалений каталог"
            FileName = $LocalArchive.Name
            LastWriteTime = $null
            SizeBytes = $null
            ExpectedSizeBytes = [long]$LocalArchive.Length
            ActualSizeBytes = $null
            Location = $remotePath
        }
    }

    $remoteArchive = @($RemoteListing.Files | Where-Object { $_.Name -ceq $LocalArchive.Name -and $_.Type -ne "d" } | Select-Object -First 1)
    $remoteHashName = "$($LocalArchive.Name)$hashFileExtension"
    $remoteHash = @($RemoteListing.Files | Where-Object { $_.Name -ceq $remoteHashName -and $_.Type -ne "d" } | Select-Object -First 1)
    $problems = @()
    $remoteArchiveHashVerified = $false
    $remoteHashSidecarVerified = $false

    if ($remoteArchive.Count -eq 0) {
        $problems += "архів відсутній"
    } elseif ($null -eq $remoteArchive[0].SizeBytes -or [long]$remoteArchive[0].SizeBytes -ne [long]$LocalArchive.Length) {
        $problems += "розмір архіву не збігається"
    }

    $localHashPath = "$($LocalArchive.FullName)$hashFileExtension"
    $localHashSize = if (Test-Path -Path $localHashPath -PathType Leaf) {
        [long](Get-Item -Path $localHashPath).Length
    } else {
        $null
    }

    if ($remoteHash.Count -eq 0) {
        $problems += "hash-файл відсутній"
    } elseif ($null -ne $localHashSize -and
        ($null -eq $remoteHash[0].SizeBytes -or [long]$remoteHash[0].SizeBytes -ne $localHashSize)) {
        $problems += "розмір hash-файлу не збігається"
    } elseif ([string]::IsNullOrWhiteSpace($DownloadedRemoteHashPath) -or
        -not (Test-Path -LiteralPath $DownloadedRemoteHashPath -PathType Leaf)) {
        $problems += "не вдалося прочитати віддалений hash-файл"
    } else {
        try {
            $localHashText = (Read-BRAVOTextFile -Path $localHashPath).Trim()
            $remoteHashText = (Read-BRAVOTextFile -Path $DownloadedRemoteHashPath).Trim()
            if ($localHashText -cne $remoteHashText) {
                $problems += "вміст hash-файлу не збігається"
            } else {
                $remoteHashSidecarVerified = $true
            }
        } catch {
            $problems += "не вдалося порівняти вміст hash-файлу"
        }
    }

    $verifyRemoteHash = if ($null -eq $backupMonitoring.SFTP.VerifyRemoteArchiveHash) {
        $true
    } else {
        Test-BRAVOSettingEnabled -Value $backupMonitoring.SFTP.VerifyRemoteArchiveHash
    }
    if ($verifyRemoteHash -and $remoteArchive.Count -gt 0 -and
        $null -ne $remoteArchive[0].SizeBytes -and
        [long]$remoteArchive[0].SizeBytes -eq [long]$LocalArchive.Length) {
        try {
            if ($null -eq $RemoteArchiveChecksumResult -or
                -not $RemoteArchiveChecksumResult.Success) {
                $checksumError = if ($null -ne $RemoteArchiveChecksumResult) {
                    [string]$RemoteArchiveChecksumResult.Error
                } else {
                    "немає результату"
                }
                $requireServerSideHash = (
                    $null -ne $backupMonitoring.SFTP.RequireServerSideArchiveHash -and
                    (Test-BRAVOSettingEnabled `
                        -Value $backupMonitoring.SFTP.RequireServerSideArchiveHash)
                )
                if ($remoteHashSidecarVerified -and -not $requireServerSideHash) {
                    Write-HealthLog (
                        "SFTP $($ArchiveDefinition.Type): серверний SHA архіву недоступний; " +
                        "використано повний збіг віддаленого hash-файлу"
                    ) -Level "WARNING"
                } else {
                    $problems += (
                        "не вдалося обчислити контрольну суму віддаленого архіву: " +
                        (Get-CompactWinSCPError -Text $checksumError)
                    )
                }
            } else {
                $checksumAlgorithm = [string]$RemoteArchiveChecksumResult.Algorithm
                $expectedArchiveHash = if ($checksumAlgorithm -eq "sha-512") {
                    Get-ExpectedArchiveSHA512 `
                        -HashPath $localHashPath `
                        -ArchiveName $LocalArchive.Name
                } elseif ($checksumAlgorithm -eq "sha-256") {
                    (Get-BRAVOFileHash -Path $LocalArchive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                } else {
                    throw "непідтримуваний алгоритм віддаленої контрольної суми: $checksumAlgorithm"
                }
                if ([string]$RemoteArchiveChecksumResult.Hash -cne $expectedArchiveHash) {
                    $problems += "$checksumAlgorithm віддаленого архіву не збігається"
                } else {
                    $remoteArchiveHashVerified = $true
                }
            }
        } catch {
            $problems += "не вдалося перевірити SHA512 віддаленого архіву: $($_.Exception.Message)"
        }
    }

    if ($remoteArchiveHashVerified -and
        $problems -contains "не вдалося прочитати віддалений hash-файл") {
        # Повна серверна контрольна сума архіву сильніша за повторне читання
        # текстового sidecar-файлу. Сам sidecar при цьому вже знайдено та
        # перевірено за розміром.
        $problems = @(
            $problems |
                Where-Object {
                    $_ -cne "не вдалося прочитати віддалений hash-файл"
                }
        )
        Write-HealthLog (
            "SFTP $($ArchiveDefinition.Type): віддалений hash-файл не завантажено, " +
            "але SHA віддаленого архіву успішно перевірено"
        ) -Level "WARNING"
    }

    $remoteLastWriteTime = if ($remoteArchive.Count -gt 0) { $remoteArchive[0].LastWriteTime } else { $null }
    if ($null -ne $remoteLastWriteTime) {
        $remoteAge = $healthCheckStarted - [datetime]$remoteLastWriteTime
        if ($remoteAge.TotalHours -gt [double]$backupMonitoring.SFTP.RemoteBackupMaxAgeHours) {
            $problems += "віддалена копія старша за $($backupMonitoring.SFTP.RemoteBackupMaxAgeHours) год."
        }
    }

    if ($problems.Count -eq 0) {
        Write-HealthLog "SFTP $($ArchiveDefinition.Type) справний: $($LocalArchive.Name), каталог $remotePath, розмір $(Format-FileSize $LocalArchive.Length)" -Level "SUCCESS"
        return
    }

    return [pscustomobject]@{
        Kind = "SFTPArchive"
        Component = "SFTP $($ArchiveDefinition.Type)"
        Reason = $problems -join "; "
        FileName = $LocalArchive.Name
        LastWriteTime = $remoteLastWriteTime
        SizeBytes = if ($remoteArchive.Count -gt 0) { $remoteArchive[0].SizeBytes } else { $null }
        ExpectedSizeBytes = [long]$LocalArchive.Length
        ActualSizeBytes = if ($remoteArchive.Count -gt 0) { $remoteArchive[0].SizeBytes } else { $null }
        Location = $remotePath
    }
}

function Test-BRAVODirectoryContainsFiles {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Container)) {
        # Невідомий або недоступний каталог не можна безпечно ігнорувати.
        return $true
    }
    try {
        return @(
            Get-ChildItem `
                -LiteralPath $Path `
                -Recurse `
                -Force `
                -ErrorAction Stop |
                Where-Object { -not $_.PSIsContainer } |
                Select-Object -First 1
        ).Count -gt 0
    } catch {
        return $true
    }
}

function Get-BAZACloudPendingDifferences {
    param([object[]]$Differences)

    # Накопичувальна хмара не видаляє додаткові віддалені об'єкти.
    # Водночас UploadUpdate є реальною невиконаною передачею: у хмарі
    # зберігається застаріла версія локального файла.
    return @(
        $Differences |
            Where-Object {
                $isPendingUpload = $_.RawAction -in @(
                    "UploadNew",
                    "UploadUpdate",
                    "UploadPending"
                )
                $isIgnorableEmptyDirectory = (
                    $_.IsDirectory -and
                    $_.RawAction -in @("UploadNew", "UploadPending") -and
                    -not (Test-BRAVODirectoryContainsFiles -Path $_.Path)
                )
                $isPendingUpload -and -not $isIgnorableEmptyDirectory
            }
    )
}

function Get-BAZAPendingAlertAfterHours {
    $configuredValue = if (
        $null -ne $backupMonitoring.SFTP -and
        $backupMonitoring.SFTP.Contains("BAZAPendingAlertAfterHours")
    ) {
        [double]$backupMonitoring.SFTP.BAZAPendingAlertAfterHours
    } else {
        26
    }
    return [math]::Max(0, $configuredValue)
}

function Test-BAZAPendingSynchronizationOverdue {
    param([object]$PreviewSummary)

    $alertAfterHours = Get-BAZAPendingAlertAfterHours
    if ($null -eq $PreviewSummary.OldestLastWriteTime) {
        # Порівняння без часу (наприклад, лише каталог) не можна безпечно
        # вважати новою штатною чергою.
        return $true
    }
    $pendingAge = $healthCheckStarted - [datetime]$PreviewSummary.OldestLastWriteTime
    return $pendingAge.TotalHours -ge $alertAfterHours
}

function Invoke-WinSCPBAZAComparisonViaCli {
    param(
        [string]$LocalPath,
        [string]$RemotePath
    )

    try {
        $previewOptions = [string]$backupMonitoring.SFTP.BAZAPreviewOptions
        $previewOptions = (
            $previewOptions -replace '(?i)(^|\s)-delete(?=\s|$)', ' '
        ).Trim()
        if ($previewOptions -notmatch '(?i)(^|\s)-preview(\s|$)') {
            $previewOptions = "-preview $previewOptions".Trim()
        }

        $command = "synchronize remote $previewOptions {0} {1}" -f `
            (ConvertTo-WinSCPScriptArgument $LocalPath), `
            (ConvertTo-WinSCPScriptArgument $RemotePath)
        $sessionResult = Invoke-WinSCPHealthSession -Commands @($command)
        if (-not $sessionResult.Success) {
            throw [string]$sessionResult.Error
        }

        $failureText = Get-WinSCPXmlFailureText -Xml $sessionResult.Xml
        if (-not [string]::IsNullOrWhiteSpace($failureText)) {
            throw $failureText
        }
        if ($sessionResult.ExitCode -ne 0) {
            throw "WinSCP.com завершив preview BAZA з кодом $($sessionResult.ExitCode)"
        }

        $namespaceManager = New-WinSCPNamespaceManager -Xml $sessionResult.Xml
        $differences = @()
        $localRoot = [System.IO.Path]::GetFullPath($LocalPath).TrimEnd("\")
        $normalizedRemoteRoot = (Normalize-SFTPPath $RemotePath).TrimEnd("/")

        foreach ($uploadNode in @(
            $sessionResult.Xml.SelectNodes("//w:upload", $namespaceManager)
        )) {
            $resultNode = $uploadNode.SelectSingleNode("w:result", $namespaceManager)
            if ($resultNode -and $resultNode.GetAttribute("success") -ne "true") {
                continue
            }

            $fileNode = $uploadNode.SelectSingleNode("w:filename", $namespaceManager)
            $destinationNode = $uploadNode.SelectSingleNode("w:destination", $namespaceManager)
            $sizeNode = $uploadNode.SelectSingleNode("w:size", $namespaceManager)
            $localFilePath = if ($fileNode) {
                [string]$fileNode.GetAttribute("value")
            } else {
                ""
            }
            $displayPath = if (
                -not [string]::IsNullOrWhiteSpace($localFilePath) -and
                $localFilePath.StartsWith(
                    "$localRoot\",
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $localFilePath.Substring($localRoot.Length + 1)
            } elseif ($destinationNode) {
                $remoteDestination = Normalize-SFTPPath (
                    $destinationNode.GetAttribute("value")
                )
                $remoteDestination.Substring(
                    [math]::Min(
                        $remoteDestination.Length,
                        $normalizedRemoteRoot.Length
                    )
                ).TrimStart("/")
            } else {
                "невідомий файл"
            }

            $localItem = if (
                -not [string]::IsNullOrWhiteSpace($localFilePath) -and
                (Test-Path -LiteralPath $localFilePath -PathType Leaf)
            ) {
                Get-Item -LiteralPath $localFilePath
            } else {
                $null
            }
            $sizeBytes = if ($sizeNode -and
                $sizeNode.GetAttribute("value") -match '^\d+$') {
                [long]$sizeNode.GetAttribute("value")
            } elseif ($null -ne $localItem) {
                [long]$localItem.Length
            } else {
                $null
            }

            $differences += [pscustomobject]@{
                RawAction = "UploadPending"
                Action = "передати"
                Path = $displayPath
                IsDirectory = $false
                SizeBytes = $sizeBytes
                LastWriteTime = if ($null -ne $localItem) {
                    $localItem.LastWriteTime
                } else {
                    $null
                }
            }
        }

        foreach ($directoryNode in @(
            $sessionResult.Xml.SelectNodes("//w:mkdir", $namespaceManager)
        )) {
            $resultNode = $directoryNode.SelectSingleNode("w:result", $namespaceManager)
            if ($resultNode -and $resultNode.GetAttribute("success") -ne "true") {
                continue
            }
            $fileNode = $directoryNode.SelectSingleNode("w:filename", $namespaceManager)
            $remoteDirectory = if ($fileNode) {
                Normalize-SFTPPath ($fileNode.GetAttribute("value"))
            } else {
                ""
            }
            $displayPath = if (
                -not [string]::IsNullOrWhiteSpace($remoteDirectory) -and
                $remoteDirectory.StartsWith(
                    "$normalizedRemoteRoot/",
                    [System.StringComparison]::Ordinal
                )
            ) {
                $remoteDirectory.Substring($normalizedRemoteRoot.Length + 1)
            } else {
                $remoteDirectory.TrimStart("/")
            }
            $localDirectoryPath = Join-Path `
                $localRoot `
                ($displayPath.Replace("/", "\"))
            if (-not (Test-BRAVODirectoryContainsFiles `
                -Path $localDirectoryPath)) {
                continue
            }

            $differences += [pscustomobject]@{
                RawAction = "UploadPending"
                Action = "створити папку"
                Path = $displayPath
                IsDirectory = $true
                SizeBytes = $null
                LastWriteTime = $null
            }
        }

        $knownSizes = @($differences | Where-Object { $null -ne $_.SizeBytes })
        $knownTimes = @(
            $differences |
                Where-Object { $null -ne $_.LastWriteTime } |
                Sort-Object LastWriteTime
        )
        $detailLimit = [math]::Max(
            1,
            [int]$backupMonitoring.SFTP.DifferenceDetailLimit
        )
        $details = @(
            $differences |
                Select-Object -First $detailLimit |
                ForEach-Object { "потребує передачі: $($_.Path)" }
        )

        return [pscustomobject]@{
            Success = $true
            Error = $null
            DifferenceCount = $differences.Count
            SizeBytes = if ($knownSizes.Count -gt 0) {
                [long](($knownSizes | Measure-Object -Property SizeBytes -Sum).Sum)
            } else {
                $null
            }
            OldestLastWriteTime = if ($knownTimes.Count -gt 0) {
                $knownTimes[0].LastWriteTime
            } else {
                $null
            }
            ActionCounts = [pscustomobject]@{
                New = 0
                Updated = 0
                RemoteExtra = 0
                Other = $differences.Count
            }
            IgnoredActionCounts = [pscustomobject]@{
                Updated = 0
                RemoteExtra = 0
                Other = 0
            }
            Details = @($details)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
            DifferenceCount = $null
            SizeBytes = $null
            OldestLastWriteTime = $null
            ActionCounts = $null
            IgnoredActionCounts = $null
            Details = @()
        }
    }
}

function Invoke-WinSCPBAZAComparison {
    param(
        [string]$LocalPath,
        [string]$RemotePath
    )

    $components = Get-BRAVOWinSCPDotNetComponents `
        -WinSCPAssemblyPath ([string]$winSCPAssemblyPath) `
        -WinSCPPath ([string]$winSCPPath)
    if ($null -eq $components) {
        Write-HealthLog (
            "WinSCPnet.dll + WinSCP.exe недоступні; " +
            "BAZA порівнюється через WinSCP.com synchronize -preview"
        ) -Level "INFO"
        return Invoke-WinSCPBAZAComparisonViaCli `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath
    }

    $session = $null
    try {
        if (-not ("WinSCP.Session" -as [type])) {
            Add-Type -Path $components.AssemblyPath -ErrorAction Stop
        }

        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.ParseUrl($sftpUrl)
        $sessionOptions.SshHostKeyFingerprint = ([string]$sftpHostKey).Trim().Trim('"')
        $sessionOptions.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds)
        )

        $session = New-Object WinSCP.Session
        $session.ExecutablePath = $components.ExecutablePath
        $session.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        )
        $session.Open($sessionOptions)

        $previewOptions = [string]$backupMonitoring.SFTP.BAZAPreviewOptions
        # Накопичувальна хмара: віддалені файли, яких уже немає локально,
        # не видаляються і не вважаються розбіжностями.
        $removeFiles = $false
        $mirror = $previewOptions -match '(?i)(^|\s)-mirror(\s|$)'
        $criteria = [WinSCP.SynchronizationCriteria]::Time
        $criteriaMatch = [regex]::Match(
            $previewOptions,
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

        # CompareDirectories є read-only еквівалентом synchronize -preview
        # і повертає структуровану колекцію запланованих змін.
        $comparison = @(
            $session.CompareDirectories(
                [WinSCP.SynchronizationMode]::Remote,
                $LocalPath,
                $RemotePath,
                $removeFiles,
                $mirror,
                $criteria,
                $null
            )
        )

        $allDifferences = @()
        foreach ($difference in $comparison) {
            $side = if ($null -ne $difference.Local) {
                $difference.Local
            } else {
                $difference.Remote
            }
            $actionText = switch ([string]$difference.Action) {
                "UploadNew" { "додати" }
                "UploadUpdate" { "оновити" }
                "DeleteRemote" { "видалити віддалений" }
                default { [string]$difference.Action }
            }
            $allDifferences += [pscustomobject]@{
                RawAction = [string]$difference.Action
                Action = $actionText
                Path = if ($null -ne $side) { [string]$side.FileName } else { "невідомий файл" }
                IsDirectory = [bool]$difference.IsDirectory
                SizeBytes = if ($null -ne $side -and -not $difference.IsDirectory) {
                    [long]$side.Length
                } else {
                    $null
                }
                LastWriteTime = if ($null -ne $side) { $side.LastWriteTime } else { $null }
            }
        }

        $pendingDifferences = @(
            Get-BAZACloudPendingDifferences -Differences $allDifferences
        )
        $knownSizes = @($pendingDifferences | Where-Object { $null -ne $_.SizeBytes })
        $knownTimes = @(
            $pendingDifferences |
                Where-Object { $null -ne $_.LastWriteTime } |
                Sort-Object LastWriteTime
        )
        $detailLimit = [math]::Max(1, [int]$backupMonitoring.SFTP.DifferenceDetailLimit)
        $details = @(
            $pendingDifferences |
                Select-Object -First $detailLimit |
                ForEach-Object {
                    $detailAction = if ($_.RawAction -eq "UploadUpdate") {
                        "потребує оновлення у хмарі"
                    } else {
                        "відсутній у хмарі"
                    }
                    "${detailAction}: $($_.Path)"
                }
        )
        $actionCounts = [pscustomobject]@{
            New = @($pendingDifferences | Where-Object { $_.RawAction -eq "UploadNew" }).Count
            Updated = @($pendingDifferences | Where-Object { $_.RawAction -eq "UploadUpdate" }).Count
            RemoteExtra = 0
            Other = 0
        }
        $ignoredActionCounts = [pscustomobject]@{
            Updated = 0
            RemoteExtra = @($allDifferences | Where-Object { $_.RawAction -eq "DeleteRemote" }).Count
            Other = @($allDifferences | Where-Object {
                $_.RawAction -notin @("UploadNew", "UploadUpdate", "DeleteRemote")
            }).Count
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            DifferenceCount = $pendingDifferences.Count
            SizeBytes = if ($knownSizes.Count -gt 0) {
                [long](($knownSizes | Measure-Object -Property SizeBytes -Sum).Sum)
            } else {
                $null
            }
            OldestLastWriteTime = if ($knownTimes.Count -gt 0) {
                $knownTimes[0].LastWriteTime
            } else {
                $null
            }
            ActionCounts = $actionCounts
            IgnoredActionCounts = $ignoredActionCounts
            Details = @($details)
        }
    } catch {
        $dotNetError = $_.Exception.Message
        Write-HealthLog (
            "Порівняння BAZA через WinSCP .NET не вдалося: $dotNetError; " +
            "використовується WinSCP.com"
        ) -Level "WARNING"
        $fallbackResult = Invoke-WinSCPBAZAComparisonViaCli `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath
        if (-not $fallbackResult.Success) {
            $fallbackResult.Error =
                ".NET: $dotNetError; WinSCP.com: $($fallbackResult.Error)"
        }
        return $fallbackResult
    } finally {
        if ($session) {
            $session.Dispose()
        }
    }
}

function Get-SFTPHealthIssues {
    $issues = @()
    if (-not $backupMonitoring.SFTP.Enabled) {
        Write-HealthLog "Незалежну SFTP-перевірку вимкнено в конфігурації" -Level "INFO"
        return @()
    }

    $checkArchives = [bool]$backupMonitoring.SFTP.CheckArchiveUploads -and
        [bool]$componentSettings.SFTP.ArchiveUpload
    $checkBAZA = [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaSFTPHealthEnabled
    $checkBAZAWWW = [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled

    if (-not $checkArchives -and -not $checkBAZA -and -not $checkBAZAWWW) {
        Write-HealthLog "SFTP health-check не потрібний: компоненти віддаленої передачі вимкнено" -Level "INFO"
        return @()
    }

    $configurationResult = Test-SFTPHealthConfiguration `
        -CheckArchives $checkArchives `
        -CheckBAZA $checkBAZA `
        -CheckBAZAWWW $checkBAZAWWW
    if (-not $configurationResult.Valid) {
        return @([pscustomobject]@{
            Kind = "SFTPConnection"
            Component = "SFTP"
            Reason = "перевірку не виконано: $($configurationResult.Errors -join '; ')"
            FileName = "немає даних"
            LastWriteTime = $null
            SizeBytes = $null
            Location = "/"
        })
    }

    if ($checkArchives) {
        $archiveChecks = @()
        $healthTemporaryRoot = Get-BRAVOHealthTemporaryRoot
        foreach ($archiveDefinition in @($archiveDefinitions | Where-Object { $_.Enabled })) {
            $localState = Get-LocalBackupState -ArchiveDefinition $archiveDefinition
            if ($null -eq $localState.NewestValidArchive) {
                Write-HealthLog "SFTP $($archiveDefinition.Type) пропущено: немає коректної локальної копії для порівняння" -Level "WARNING"
                continue
            }

            $remoteDirectory = Normalize-SFTPPath $sftpDirectories[$archiveDefinition.Type]
            $archiveChecks += [pscustomobject]@{
                Definition = $archiveDefinition
                LocalArchive = $localState.NewestValidArchive
                RemoteDirectory = $remoteDirectory
                RemoteHashDownloadDirectory = Join-Path `
                    $healthTemporaryRoot `
                    ("BRAVO_HEALTH_{0}" -f [guid]::NewGuid().ToString("N"))
                RemoteHashDownloadPath = $null
            }
            $archiveChecks[-1].RemoteHashDownloadPath = Join-Path `
                $archiveChecks[-1].RemoteHashDownloadDirectory `
                "$($localState.NewestValidArchive.Name)$hashFileExtension"
        }

        if ($archiveChecks.Count -gt 0) {
            $verifySFTPRemoteHash = if ($null -eq $backupMonitoring.SFTP.VerifyRemoteArchiveHash) {
                $true
            } else {
                Test-BRAVOSettingEnabled -Value $backupMonitoring.SFTP.VerifyRemoteArchiveHash
            }
            $remoteArchiveChecksumResults = if ($verifySFTPRemoteHash) {
                Get-SFTPRemoteArchiveChecksumResults -ArchiveChecks $archiveChecks
            } else {
                @{}
            }
            $archiveCommands = @($archiveChecks | ForEach-Object {
                if (-not (Test-Path -LiteralPath $_.RemoteHashDownloadDirectory -PathType Container)) {
                    New-Item `
                        -ItemType Directory `
                        -Path $_.RemoteHashDownloadDirectory `
                        -Force |
                        Out-Null
                }
                "ls $(ConvertTo-WinSCPScriptArgument $_.RemoteDirectory)"
                $remoteHashPath = "{0}/{1}{2}" -f `
                    $_.RemoteDirectory.TrimEnd('/'), `
                    $_.LocalArchive.Name, `
                    $hashFileExtension
                # lcd + get без локального аргументу уникає неоднозначного
                # розбору quoted Windows-шляху, що завершується "\".
                "lcd $(ConvertTo-WinSCPScriptArgument $_.RemoteHashDownloadDirectory)"
                "get $(ConvertTo-WinSCPScriptArgument $remoteHashPath)"
            })
            try {
                $archiveSession = Invoke-WinSCPHealthSession -Commands $archiveCommands

                if (-not $archiveSession.Success) {
                $issues += [pscustomobject]@{
                    Kind = "SFTPConnection"
                    Component = "SFTP архіви"
                    Reason = "не вдалося виконати віддалену перевірку: $($archiveSession.Error)"
                    FileName = "немає даних"
                    LastWriteTime = $null
                    SizeBytes = $null
                    Location = "/"
                }
                } else {
                    $remoteListings = @(Get-WinSCPRemoteListings -Xml $archiveSession.Xml)
                    $remoteDownloads = @(Get-WinSCPRemoteDownloads -Xml $archiveSession.Xml)
                    if ($remoteListings.Count -eq 0 -and $archiveSession.ExitCode -ne 0) {
                    $issues += [pscustomobject]@{
                        Kind = "SFTPConnection"
                        Component = "SFTP архіви"
                        Reason = "з'єднання або читання каталогів завершилося з кодом $($archiveSession.ExitCode)"
                        FileName = "немає даних"
                        LastWriteTime = $null
                        SizeBytes = $null
                        Location = "/"
                    }
                    } else {
                        foreach ($archiveCheck in $archiveChecks) {
                        $remoteListing = @(
                            $remoteListings |
                                Where-Object { $_.Destination -ceq $archiveCheck.RemoteDirectory } |
                                Select-Object -First 1
                        )
                            $downloadedHash = Resolve-DownloadedRemoteHashPath `
                                -ArchiveCheck $archiveCheck `
                                -Downloads $remoteDownloads
                            if ([string]::IsNullOrWhiteSpace([string]$downloadedHash.Path)) {
                                Write-HealthLog (
                                    "SFTP $($archiveCheck.Definition.Type): " +
                                    "не вдалося отримати віддалений hash-файл: " +
                                    $downloadedHash.Error
                                ) -Level "WARNING"
                            }
                            $archiveIssue = Test-SFTPArchiveCopy `
                                -ArchiveDefinition $archiveCheck.Definition `
                                -LocalArchive $archiveCheck.LocalArchive `
                                -RemoteListing $(if ($remoteListing.Count -gt 0) { $remoteListing[0] } else { $null }) `
                                -RemoteDirectory $archiveCheck.RemoteDirectory `
                                -DownloadedRemoteHashPath $downloadedHash.Path `
                                -RemoteArchiveChecksumResult $remoteArchiveChecksumResults[$archiveCheck.LocalArchive.FullName]
                            if ($null -ne $archiveIssue) {
                                $issues += $archiveIssue
                            }
                        }
                    }
                }
            } finally {
                foreach ($archiveCheck in $archiveChecks) {
                    Remove-BRAVOHealthTemporaryDirectory `
                        -Path $archiveCheck.RemoteHashDownloadDirectory
                }
            }
        }
    }

    $folderSynchronizationChecks = @()
    if ($checkBAZA) {
        $folderSynchronizationChecks += [pscustomobject]@{
            Name = "BAZA"
            Component = "SFTP BAZA"
            LocalPath = [string]$bazaPaths.Source
            RemotePath = Normalize-SFTPPath $sftpDirectories.BAZA
            DetectionError = $null
        }
    }
    if ($checkBAZAWWW) {
        $folderSynchronizationChecks += [pscustomobject]@{
            Name = "BAZA WWW"
            Component = "SFTP BAZA WWW"
            LocalPath = [string]$bazaWWWPaths.Source
            RemotePath = Normalize-SFTPPath $sftpDirectories.BAZAWWW
            DetectionError = if ($bazaWWWDetection.Success) {
                $null
            } else {
                [string]$bazaWWWDetection.Reason
            }
        }
    }

    foreach ($folderCheck in $folderSynchronizationChecks) {
        if (-not [string]::IsNullOrWhiteSpace($folderCheck.DetectionError)) {
            $issues += [pscustomobject]@{
                Kind = "SFTPSynchronization"
                Component = $folderCheck.Component
                Reason = "не вдалося визначити локальне джерело: $($folderCheck.DetectionError)"
                FileName = "немає даних"
                LastWriteTime = $null
                SizeBytes = $null
                DifferenceCount = $null
                Details = @()
                Location = $folderCheck.RemotePath
            }
        } elseif (-not (Test-Path `
            -LiteralPath $folderCheck.LocalPath `
            -PathType Container)) {
            $issues += [pscustomobject]@{
                Kind = "SFTPSynchronization"
                Component = $folderCheck.Component
                Reason = "локальний каталог $($folderCheck.Name) не знайдено"
                FileName = "немає даних"
                LastWriteTime = $null
                SizeBytes = $null
                DifferenceCount = $null
                Details = @()
                Location = $folderCheck.RemotePath
            }
        } else {
            $previewSummary = Invoke-WinSCPBAZAComparison `
                -LocalPath $folderCheck.LocalPath `
                -RemotePath $folderCheck.RemotePath

            if (-not $previewSummary.Success) {
                $issues += [pscustomobject]@{
                    Kind = "SFTPSynchronization"
                    Component = $folderCheck.Component
                    Reason = "не вдалося порівняти каталоги: $($previewSummary.Error)"
                    FileName = "немає даних"
                    LastWriteTime = $null
                    SizeBytes = $null
                    DifferenceCount = $null
                    Details = @()
                    Location = $folderCheck.RemotePath
                }
            } elseif ($previewSummary.DifferenceCount -gt 0) {
                if (-not (Test-BAZAPendingSynchronizationOverdue -PreviewSummary $previewSummary)) {
                    $pendingAge = $healthCheckStarted - [datetime]$previewSummary.OldestLastWriteTime
                    Write-HealthLog (
                        "SFTP $($folderCheck.Name): штатна черга передачі " +
                        "$($previewSummary.DifferenceCount) об'єктів, найстаріший вік " +
                        "$(Format-BackupAge $previewSummary.OldestLastWriteTime); " +
                        "alert після $(Get-BAZAPendingAlertAfterHours) год."
                    ) -Level "INFO"
                } else {
                    $issues += [pscustomobject]@{
                    Kind = "SFTPSynchronization"
                    Component = $folderCheck.Component
                    Reason = "у хмарі відсутні або потребують оновлення локальні файли/папки"
                    FileName = if ($previewSummary.Details.Count -gt 0) { $previewSummary.Details -join "; " } else { "немає деталей" }
                    LastWriteTime = $previewSummary.OldestLastWriteTime
                    SizeBytes = $previewSummary.SizeBytes
                    DifferenceCount = $previewSummary.DifferenceCount
                    ActionCounts = $previewSummary.ActionCounts
                    Details = @($previewSummary.Details)
                    Location = $folderCheck.RemotePath
                }
                }
            } else {
                $ignoredRemoteExtraCount = if ($null -ne $previewSummary.IgnoredActionCounts) {
                    [int]$previewSummary.IgnoredActionCounts.RemoteExtra
                } else {
                    0
                }
                Write-HealthLog "SFTP $($folderCheck.Name) справний: усі локальні файли та папки актуальні у $($folderCheck.RemotePath); додаткових об'єктів у хмарі проігноровано: $ignoredRemoteExtraCount" -Level "SUCCESS"
            }
        }
    }

    return @($issues)
}

function Test-SMBHealthConfiguration {
    $errors = @()
    if (-not [string]::IsNullOrWhiteSpace($smbCredentialError)) {
        $errors += $smbCredentialError
    }
    if ($null -eq $script:smbCredential) {
        $errors += "не завантажено NAS/SMB облікові дані з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace([string]$smbSettings.RootPath) -or
        [string]$smbSettings.RootPath -notmatch '^\\\\[^\\]+\\[^\\]+') {
        $errors += "smbSettings.RootPath повинен бути UNC-шляхом виду \\server\share"
    }
    if ([double]$backupMonitoring.SMB.RemoteBackupMaxAgeHours -le 0) {
        $errors += "максимальний вік NAS/SMB-копії повинен бути більшим за 0"
    }

    foreach ($archiveDefinition in @($archiveDefinitions | Where-Object { $_.Enabled })) {
        if ($null -eq $smbSettings.Directories -or
            -not $smbSettings.Directories.ContainsKey($archiveDefinition.Type) -or
            [string]::IsNullOrWhiteSpace([string]$smbSettings.Directories[$archiveDefinition.Type])) {
            $errors += "не встановлено NAS/SMB каталог для $($archiveDefinition.Type)"
        }
    }

    return [pscustomobject]@{
        Valid = $errors.Count -eq 0
        Errors = @($errors)
    }
}

function New-BRAVOSMBHealthDrive {
    $driveName = "BRAVOSMBHEALTH$PID"
    Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
    try {
        return New-PSDrive `
            -Name $driveName `
            -PSProvider FileSystem `
            -Root ([string]$smbSettings.RootPath) `
            -Credential $script:smbCredential `
            -Scope Script `
            -ErrorAction Stop
    } catch {
        throw "не вдалося підключитися до '$($smbSettings.RootPath)': $($_.Exception.Message)"
    }
}

function Get-SMBHealthIssues {
    $issues = @()
    if (-not [bool]$backupMonitoring.SMB.Enabled) {
        Write-HealthLog "Незалежну NAS/SMB-перевірку вимкнено в конфігурації" -Level "INFO"
        return @()
    }
    if (-not [bool]$backupMonitoring.SMB.CheckArchiveCopies -or
        -not [bool]$componentSettings.SMB.ArchiveCopy) {
        Write-HealthLog "NAS/SMB health-check не потрібний: копіювання архівів вимкнено" -Level "INFO"
        return @()
    }

    $configurationResult = Test-SMBHealthConfiguration
    if (-not $configurationResult.Valid) {
        return @([pscustomobject]@{
            Kind = "SMBConnection"
            Component = "NAS/SMB"
            Reason = "перевірку не виконано: $($configurationResult.Errors -join '; ')"
            FileName = "немає даних"
            LastWriteTime = $null
            SizeBytes = $null
            ExpectedSizeBytes = $null
            ActualSizeBytes = $null
            Location = [string]$smbSettings.RootPath
        })
    }

    $drive = $null
    try {
        $drive = New-BRAVOSMBHealthDrive
        foreach ($archiveDefinition in @($archiveDefinitions | Where-Object { $_.Enabled })) {
            $localState = Get-LocalBackupState -ArchiveDefinition $archiveDefinition
            $localArchive = $localState.NewestValidArchive
            if ($null -eq $localArchive) {
                Write-HealthLog "NAS/SMB $($archiveDefinition.Type) пропущено: немає коректної локальної копії для порівняння" -Level "WARNING"
                continue
            }

            $remoteDirectory = Join-Path `
                ([string]$smbSettings.RootPath) `
                ([string]$smbSettings.Directories[$archiveDefinition.Type])
            $remoteArchivePath = Join-Path $remoteDirectory $localArchive.Name
            $remoteHashPath = "$remoteArchivePath$hashFileExtension"
            $localHashPath = "$($localArchive.FullName)$hashFileExtension"
            $localHashSize = if (Test-Path -LiteralPath $localHashPath -PathType Leaf) {
                [long](Get-Item -LiteralPath $localHashPath).Length
            } else {
                $null
            }
            $remoteArchive = if (Test-Path -LiteralPath $remoteArchivePath -PathType Leaf) {
                Get-Item -LiteralPath $remoteArchivePath
            } else {
                $null
            }
            $remoteHash = if (Test-Path -LiteralPath $remoteHashPath -PathType Leaf) {
                Get-Item -LiteralPath $remoteHashPath
            } else {
                $null
            }
            $problems = @()

            if ($null -eq $remoteArchive) {
                $problems += "архів відсутній"
            } elseif ([long]$remoteArchive.Length -ne [long]$localArchive.Length) {
                $problems += "розмір архіву не збігається"
            }
            if ($null -eq $remoteHash) {
                $problems += "hash-файл відсутній"
            } elseif ($null -ne $localHashSize -and [long]$remoteHash.Length -ne $localHashSize) {
                $problems += "розмір hash-файлу не збігається"
            } else {
                try {
                    $localHashText = (Read-BRAVOTextFile -Path $localHashPath).Trim()
                    $remoteHashText = (Read-BRAVOTextFile -Path $remoteHashPath).Trim()
                    if ($localHashText -cne $remoteHashText) {
                        $problems += "вміст hash-файлу не збігається"
                    }
                } catch {
                    $problems += "не вдалося порівняти вміст hash-файлу"
                }
            }

            $verifyRemoteHash = if ($null -eq $backupMonitoring.SMB.VerifyRemoteArchiveHash) {
                $true
            } else {
                Test-BRAVOSettingEnabled -Value $backupMonitoring.SMB.VerifyRemoteArchiveHash
            }
            if ($verifyRemoteHash -and $null -ne $remoteArchive -and
                [long]$remoteArchive.Length -eq [long]$localArchive.Length) {
                try {
                    $expectedArchiveHash = Get-ExpectedArchiveSHA512 `
                        -HashPath $localHashPath `
                        -ArchiveName $localArchive.Name
                    $remoteArchiveHash = Get-FileSHA512 -Path $remoteArchivePath
                    if ($remoteArchiveHash -cne $expectedArchiveHash) {
                        $problems += "SHA512 віддаленого архіву не збігається"
                    }
                } catch {
                    $problems += "не вдалося перевірити SHA512 віддаленого архіву: $($_.Exception.Message)"
                }
            }

            $remoteLastWriteTime = if ($remoteArchive) { $remoteArchive.LastWriteTime } else { $null }
            if ($null -ne $remoteLastWriteTime -and
                ($healthCheckStarted - $remoteLastWriteTime).TotalHours -gt
                [double]$backupMonitoring.SMB.RemoteBackupMaxAgeHours) {
                $problems += "віддалена копія старша за $($backupMonitoring.SMB.RemoteBackupMaxAgeHours) год."
            }

            if ($problems.Count -eq 0) {
                Write-HealthLog "NAS/SMB $($archiveDefinition.Type) справний: $($localArchive.Name), каталог $remoteDirectory, розмір $(Format-FileSize $localArchive.Length)" -Level "SUCCESS"
                continue
            }

            $issues += [pscustomobject]@{
                Kind = "SMBArchive"
                Component = "NAS/SMB $($archiveDefinition.Type)"
                Reason = $problems -join "; "
                FileName = $localArchive.Name
                LastWriteTime = $remoteLastWriteTime
                SizeBytes = if ($remoteArchive) { [long]$remoteArchive.Length } else { $null }
                ExpectedSizeBytes = [long]$localArchive.Length
                ActualSizeBytes = if ($remoteArchive) { [long]$remoteArchive.Length } else { $null }
                Location = $remoteDirectory
            }
        }
    } catch {
        $issues += [pscustomobject]@{
            Kind = "SMBConnection"
            Component = "NAS/SMB"
            Reason = $_.Exception.Message
            FileName = "немає даних"
            LastWriteTime = $null
            SizeBytes = $null
            ExpectedSizeBytes = $null
            ActualSizeBytes = $null
            Location = [string]$smbSettings.RootPath
        }
    } finally {
        if ($drive) {
            Remove-PSDrive -Name $drive.Name -Force -ErrorAction SilentlyContinue
        }
    }

    return @($issues)
}

function Get-EnabledBackupComponentNames {
    $componentNames = @()
    if ($bazaLocalHealthEnabled -or $bazaSFTPHealthEnabled) {
        $componentNames += "BAZA_APP"
    }
    if ($bazaWWWSFTPHealthEnabled) {
        $componentNames += "BAZA_WWW"
    }
    $componentNames += @(
        $archiveDefinitions |
            Where-Object { $_.Enabled } |
            ForEach-Object { $_.Type }
    )

    # Порядок у повідомленні не залежить від порядку archiveDefinitions.
    # Невідомі майбутні компоненти додаються наприкінці, а не губляться.
    $preferredOrder = @("BAZA_APP", "BAZA_WWW", "BLOG", "BRAVOEXCH", "MODEL")
    $orderedNames = @($preferredOrder | Where-Object { $componentNames -contains $_ })
    $orderedNames += @($componentNames | Where-Object { $_ -notin $preferredOrder })
    return @($orderedNames | Select-Object -Unique)
}

function Get-ManagedServiceHealthIssues {
    $checkManagedServices = if ($backupMonitoring.Contains("CheckManagedServices")) {
        Test-BRAVOSettingEnabled -Value $backupMonitoring.CheckManagedServices
    } else {
        $true
    }
    if (-not $checkManagedServices -or
        $null -eq $maintenanceSettings -or
        $null -eq $maintenanceSettings.Services) {
        return @()
    }

    $services = New-Object System.Collections.ArrayList
    $addService = {
        param([object]$Service)

        if ($null -ne $Service -and
            @($services | Where-Object { $_.Name -ieq $Service.Name }).Count -eq 0) {
            [void]$services.Add($Service)
        }
    }

    foreach ($serviceName in @(
            [string]$maintenanceSettings.Services.BravoName,
            [string]$maintenanceSettings.Services.ExchangeApiName
        )) {
        if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
            & $addService (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)
        }
    }

    if (Test-BRAVOSettingEnabled -Value $maintenanceSettings.Services.BravoWebEnabled) {
        foreach ($candidate in @($maintenanceSettings.Services.BravoWebCandidates)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
                continue
            }
            $webService = Get-Service -Name ([string]$candidate) -ErrorAction SilentlyContinue
            if ($null -eq $webService) {
                $webService = Get-Service -DisplayName ([string]$candidate) -ErrorAction SilentlyContinue
            }
            if ($null -ne $webService) {
                & $addService $webService
                break
            }
        }
    }

    $startModeByName = @{}
    try {
        foreach ($serviceInfo in @(Get-BRAVOWmiInstance -ClassName Win32_Service)) {
            $startModeByName[[string]$serviceInfo.Name] = [string]$serviceInfo.StartMode
        }
    } catch {
        Write-HealthLog "Не вдалося прочитати типи запуску служб: $($_.Exception.Message)" -Level "WARNING"
    }

    $issues = @()
    foreach ($service in @($services)) {
        $startMode = [string]$service.StartType
        if ([string]::IsNullOrWhiteSpace($startMode) -and
            $startModeByName.ContainsKey([string]$service.Name)) {
            $startMode = [string]$startModeByName[[string]$service.Name]
        }
        if ($startMode -ieq "Disabled") {
            Write-HealthLog "Перевірку служби $($service.Name) пропущено: тип запуску Disabled" -Level "INFO"
            continue
        }

        $service.Refresh()
        if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
            Write-HealthLog "Служба $($service.Name) працює" -Level "SUCCESS"
            continue
        }
        $issues += [pscustomobject]@{
            Kind = "Service"
            Component = "Служба $($service.Name)"
            Reason = "не запущена (стан: $($service.Status))"
            FileName = ""
            LastWriteTime = $null
            Location = [string]$service.Name
            SizeBytes = $null
            Details = @()
        }
    }
    return @($issues)
}

function Get-HealthIssueComponentName {
    param([object]$Issue)

    $name = [string]$Issue.Component
    if ($name -eq "SFTP архіви") {
        return "SFTP"
    }
    $name = $name -replace '^(SFTP|NAS/SMB|Локальна)\s+', ''
    if ($name -match '\bBAZA WWW\b') {
        return "BAZA WWW"
    }
    if ($name -match '\bBAZA\b') {
        return "BAZA"
    }
    return $name
}

function ConvertTo-NotificationLiteralText {
    param([AllowEmptyString()][string]$Text)

    # Slack does not require Discord Markdown escaping. In PowerShell a
    # backslash is literal, so use "\*" (one slash), not "\\*".
    $literalText = [string]$Text
    if ($NotificationProvider -ne "discord") {
        return $literalText
    }
    $literalText = $literalText.Replace("\", "\\")
    $literalText = $literalText.Replace("*", "\*")
    $literalText = $literalText.Replace("_", "\_")
    $literalText = $literalText.Replace("~", "\~")
    $literalText = $literalText.Replace("|", "\|")
    $literalText = $literalText.Replace(">", "\>")
    return $literalText
}

function Format-HealthIssueFileName {
    param([object]$Issue)

    if ([string]::IsNullOrWhiteSpace([string]$Issue.FileName)) {
        return ""
    }
    return " • файл: $(ConvertTo-NotificationLiteralText -Text ([string]$Issue.FileName))"
}

function Format-CompactLocalIssue {
    param([object]$Issue)

    $componentName = Get-HealthIssueComponentName -Issue $Issue
    if ($Issue.Kind -eq "LocalSynchronization") {
        $exitCodeText = if ($null -ne $Issue.ExitCode) {
            " • robocopy: $($Issue.ExitCode)"
        } else {
            ""
        }
        return ":warning: $componentName — $($Issue.Reason)$exitCodeText"
    }

    if ($Issue.Reason -match '^остання коректна копія старша за ') {
        return ":warning: $componentName — прострочено: $(Format-BackupAge $Issue.LastWriteTime) • $(Format-FileSize $Issue.SizeBytes)$(Format-HealthIssueFileName -Issue $Issue)"
    }

    $fileText = Format-HealthIssueFileName -Issue $Issue
    return ":x: $componentName — $($Issue.Reason)$fileText"
}

function Format-CompactSFTPIssue {
    param([object]$Issue)

    $componentName = Get-HealthIssueComponentName -Issue $Issue
    switch ($Issue.Kind) {
        "SFTPArchive" {
            $expectedSize = $Issue.ExpectedSizeBytes
            $actualSize = $Issue.ActualSizeBytes
            $fileExists = $null -ne $actualSize
            $sizeMatches = $fileExists -and
                $null -ne $expectedSize -and
                [long]$actualSize -eq [long]$expectedSize
            $ageOnly = $Issue.Reason -match '^віддалена копія старша за [\d.,]+ год\.$'

            if ($sizeMatches -and $ageOnly) {
                return ":warning: $componentName — файл є, розмір збігається ($(Format-FileSize $actualSize)), але прострочений: $(Format-BackupAge $Issue.LastWriteTime)$(Format-HealthIssueFileName -Issue $Issue)"
            }
            if (-not $fileExists) {
                return ":x: $componentName — $($Issue.Reason)$(Format-HealthIssueFileName -Issue $Issue)"
            }
            if ($null -ne $expectedSize -and -not $sizeMatches) {
                return ":x: $componentName — $($Issue.Reason) • очікується $(Format-FileSize $expectedSize), у хмарі $(Format-FileSize $actualSize)$(Format-HealthIssueFileName -Issue $Issue)"
            }
            return ":warning: $componentName — файл є ($(Format-FileSize $actualSize)) • $($Issue.Reason)$(Format-HealthIssueFileName -Issue $Issue)"
        }
        "SFTPSynchronization" {
            if ($Issue.Reason -eq "у хмарі відсутні або потребують оновлення локальні файли/папки") {
                $missingText = if ($null -eq $Issue.DifferenceCount) {
                    "немає даних"
                } else {
                    [string]$Issue.DifferenceCount
                }
                $sizeText = if ($null -ne $Issue.SizeBytes) {
                    " • $(Format-FileSize $Issue.SizeBytes)"
                } else {
                    ""
                }
                $actionText = ""
                if ($null -ne $Issue.ActionCounts) {
                    $actionParts = @()
                    if ([int]$Issue.ActionCounts.New -gt 0) {
                        $actionParts += "відсутніх: $($Issue.ActionCounts.New)"
                    }
                    if ([int]$Issue.ActionCounts.Updated -gt 0) {
                        $actionParts += "застарілих: $($Issue.ActionCounts.Updated)"
                    }
                    if ($actionParts.Count -gt 0) {
                        $actionText = " ($($actionParts -join '; '))"
                    }
                }
                return ":warning: $componentName — локальні дані очікують передачі у хмару: $missingText$actionText$sizeText"
            }

            $differenceText = if ($null -eq $Issue.DifferenceCount) {
                "немає даних"
            } else {
                [string]$Issue.DifferenceCount
            }
            $actionParts = @()
            if ($null -ne $Issue.ActionCounts) {
                if ([int]$Issue.ActionCounts.New -gt 0) {
                    $actionParts += "нових: $($Issue.ActionCounts.New)"
                }
                if ([int]$Issue.ActionCounts.Updated -gt 0) {
                    $actionParts += "змінених: $($Issue.ActionCounts.Updated)"
                }
                if ([int]$Issue.ActionCounts.RemoteExtra -gt 0) {
                    $actionParts += "зайвих у хмарі: $($Issue.ActionCounts.RemoteExtra)"
                }
                if ([int]$Issue.ActionCounts.Other -gt 0) {
                    $actionParts += "очікують передачі: $($Issue.ActionCounts.Other)"
                }
            }
            $actionText = if ($actionParts.Count -gt 0) {
                " ($($actionParts -join '; '))"
            } else {
                ""
            }
            $sizeText = if ($null -ne $Issue.SizeBytes) {
                " • $(Format-FileSize $Issue.SizeBytes)"
            } else {
                ""
            }
            return ":warning: $componentName — $($Issue.Reason) • розбіжностей: $differenceText$actionText$sizeText"
        }
        default {
            return ":x: $componentName — $($Issue.Reason)"
        }
    }
}

function Format-CompactSMBIssue {
    param([object]$Issue)

    $componentName = Get-HealthIssueComponentName -Issue $Issue
    if ($Issue.Kind -eq "SMBArchive") {
        $actualSizeText = if ($null -ne $Issue.ActualSizeBytes) {
            " • $(Format-FileSize $Issue.ActualSizeBytes)"
        } else {
            ""
        }
        return ":warning: $componentName — $($Issue.Reason)$actualSizeText"
    }
    return ":x: $componentName — $($Issue.Reason)"
}

function New-SlackAlertMessage {
    param(
        [array]$Issues,
        [timespan]$Duration
    )

    $ukrainianCulture = [System.Globalization.CultureInfo]::GetCultureInfo("uk-UA")
    $dateText = $healthCheckStarted.ToString("dd MMMM yyyy", $ukrainianCulture).Replace(" р.", "")
    $durationSeconds = [math]::Max(0, [math]::Round($Duration.TotalSeconds))
    $hostInformation = Get-HostInformation
    $archiveVersionText = [string]$global:ScriptVersion
    $archiveScriptDateText = [string]$global:ScriptDate
    $archiveBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$global:ScriptBuildId)) {
        "невідома"
    } else {
        [string]$global:ScriptBuildId
    }
    $problemComponentNames = @()
    foreach ($issue in $Issues) {
        $componentName = Get-HealthIssueComponentName -Issue $issue
        if ($problemComponentNames -notcontains $componentName) {
            $problemComponentNames += $componentName
        }
    }
    $localIssues = @($Issues | Where-Object {
        $_.Kind -in @("LocalBackup", "LocalSynchronization")
    })
    $serviceIssues = @($Issues | Where-Object { $_.Kind -eq "Service" })
    $sftpIssues = @($Issues | Where-Object {
        $_.Kind -in @("SFTPArchive", "SFTPSynchronization", "SFTPConnection")
    })
    $smbIssues = @($Issues | Where-Object {
        $_.Kind -in @("SMBArchive", "SMBConnection")
    })
    $knownKinds = @(
        "LocalBackup",
        "LocalSynchronization",
        "Service",
        "SFTPArchive",
        "SFTPSynchronization",
        "SFTPConnection",
        "SMBArchive",
        "SMBConnection"
    )
    $otherIssues = @($Issues | Where-Object { $_.Kind -notin $knownKinds })

    $alertTitle = if ($serviceIssues.Count -gt 0 -and $serviceIssues.Count -eq $Issues.Count) {
        "СЛУЖБИ BRAVO ПОТРЕБУЮТЬ УВАГИ"
    } else {
        "BRAVO ПОТРЕБУЄ УВАГИ"
    }
    $lines = @(
        ":rotating_light: *$alertTitle*",
        ":derelict_house_building: $($backupMonitoring.InstitutionName) [$($backupMonitoring.InstitutionCode)]",
        ":desktop_computer: $($hostInformation.MachineName) • $($hostInformation.LocalIP) | $($hostInformation.PublicIP)",
        ":clock3: $dateText, $($healthCheckStarted.ToString('HH:mm:ss')) • $durationSeconds сек.",
        "🏷️ Версія BRAVO_ARCHIV: $archiveVersionText від $archiveScriptDateText (build $archiveBuildIdText)",
        ":pushpin: Проблемних компонентів: $($problemComponentNames.Count) • перевірок: $($Issues.Count)",
        "",
        ":package: $($problemComponentNames -join ', ')"
    )

    if ($serviceIssues.Count -gt 0) {
        $lines += ""
        $lines += ":gear: *СЛУЖБИ*"
        foreach ($issue in $serviceIssues) {
            $lines += ":x: $($issue.Component) — $($issue.Reason)"
        }
    }

    if ($localIssues.Count -gt 0) {
        $lines += ""
        $lines += ":floppy_disk: *ЛОКАЛЬНІ БЕКАПИ*"
        foreach ($issue in $localIssues) {
            $lines += Format-CompactLocalIssue -Issue $issue
        }
    }

    if ($sftpIssues.Count -gt 0) {
        $lines += ""
        $lines += ":cloud: *БЕКАПИ У ХМАРІ*"
        foreach ($issue in $sftpIssues) {
            $lines += Format-CompactSFTPIssue -Issue $issue
        }
    }

    if ($smbIssues.Count -gt 0) {
        $lines += ""
        $lines += ":minidisc: *NAS/SMB*"
        foreach ($issue in $smbIssues) {
            $lines += Format-CompactSMBIssue -Issue $issue
        }
    }

    if ($otherIssues.Count -gt 0) {
        $lines += ""
        $lines += ":warning: *ІНШІ ПОМИЛКИ*"
        foreach ($issue in $otherIssues) {
            $lines += ":x: $($issue.Component) — $($issue.Reason)"
        }
    }

    $bazaLocalHealthy = $bazaLocalHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "Локальна BAZA"
        }).Count -eq 0
    $bazaSFTPHealthy = [bool]$backupMonitoring.SFTP.Enabled -and
        [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaSFTPHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "SFTP BAZA" -or $_.Kind -eq "SFTPConnection"
        }).Count -eq 0
    if ($bazaLocalHealthy -or $bazaSFTPHealthy) {
        $lines += ""
        if ($bazaLocalHealthy -and $bazaSFTPHealthy) {
            $lines += ":white_check_mark: *BAZA_APP* — локальна копія та SFTP актуальні"
        } elseif ($bazaLocalHealthy) {
            $lines += ":white_check_mark: *BAZA_APP* — локальна копія актуальна"
        } else {
            $lines += ":white_check_mark: *BAZA_APP* — SFTP актуальна"
        }
    }
    $bazaWWWSFTPHealthy = [bool]$backupMonitoring.SFTP.Enabled -and
        [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "SFTP BAZA WWW" -or
            $_.Kind -eq "SFTPConnection"
        }).Count -eq 0
    if ($bazaWWWSFTPHealthy) {
        $lines += ""
        $lines += ":white_check_mark: *BAZA_WWW* — SFTP актуальна"
    }

    $lines += ""
    $lines += ":memo: Журнал: $healthLogFile"
    return $lines -join [Environment]::NewLine
}

function Get-BRAVOHealthDestinationSummary {
    # Аудит P1.6: раніше health-check повертав лише один агрегований
    # Status/IssueCount — зовнішній моніторинг не міг побачити "локальні
    # копії в порядку, а SFTP деградував" окремо від "усе зламано разом".
    # Кожен вхідний масив уже й так є результатом незалежного виклику
    # (Get-BackupHealthIssues/Get-BAZALocalHealthIssues/Get-SFTPHealthIssues/
    # Get-SMBHealthIssues) — жоден з них не перериває виконання інших при
    # відмові, тому тут лишається тільки звести їх у три прапорці, а не
    # виправляти саму послідовність перевірок.
    [CmdletBinding()]
    param(
        [array]$LocalIssues = @(),
        [array]$BazaLocalIssues = @(),
        [array]$SftpIssues = @(),
        [array]$SmbIssues = @()
    )

    return [pscustomobject]@{
        LocalVerified = (@($LocalIssues) + @($BazaLocalIssues)).Count -eq 0
        SftpVerified = @($SftpIssues).Count -eq 0
        SmbVerified = @($SmbIssues).Count -eq 0
    }
}

function New-SlackSuccessMessage {
    param([timespan]$Duration)

    $ukrainianCulture = [System.Globalization.CultureInfo]::GetCultureInfo("uk-UA")
    $dateText = $healthCheckStarted.ToString("dd MMMM yyyy", $ukrainianCulture).Replace(" р.", "")
    $durationSeconds = [math]::Max(0, [math]::Round($Duration.TotalSeconds))
    $enabledNames = @(Get-EnabledBackupComponentNames)
    $enabledComponentsText = if ($enabledNames.Count -gt 0) {
        $enabledNames -join ', '
    } else {
        'немає'
    }
    $hostInformation = Get-HostInformation
    $archiveVersionText = [string]$global:ScriptVersion
    $archiveScriptDateText = [string]$global:ScriptDate
    $archiveBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$global:ScriptBuildId)) {
        "невідома"
    } else {
        [string]$global:ScriptBuildId
    }

    $lines = @(
        ":white_check_mark: *РЕЗЕРВНІ КОПІЇ АКТУАЛЬНІ*",
        ":derelict_house_building: Установа: $($backupMonitoring.InstitutionName) [$($backupMonitoring.InstitutionCode)]",
        ":desktop_computer: Машина: $($hostInformation.MachineName)",
        ":globe_with_meridians: IP-адреси: $($hostInformation.LocalIP) | $($hostInformation.PublicIP)",
        ":spiral_calendar_pad: Дата: $dateText",
        ":alarm_clock: Час: $($healthCheckStarted.ToString('HH:mm:ss'))",
        ":hourglass_flowing_sand: Тривалість перевірки: $durationSeconds сек.",
        "🏷️ Версія BRAVO_ARCHIV: $archiveVersionText від $archiveScriptDateText (build $archiveBuildIdText)",
        ":package: Увімкнені компоненти для бекапу: $enabledComponentsText",
        "",
        ":floppy_disk: Локальні архіви та hash-файли актуальні"
    )

    $latestArchiveLines = @(
        $archiveDefinitions |
            Where-Object { $_.Enabled } |
            ForEach-Object {
                $archiveInfo = $script:healthLatestArchives[$_.Type]
                $archiveName = if ($null -ne $archiveInfo) { [string]$archiveInfo.Name } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($archiveName)) {
                    $archiveSizeText = Format-FileSize -Bytes ([long]$archiveInfo.SizeBytes)
                    "• $($_.Type): $archiveName ($archiveSizeText)"
                }
            }
    )
    if ($latestArchiveLines.Count -gt 0) {
        $lines += ":package: Останні локальні архіви:"
        $lines += $latestArchiveLines
    }

    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckArchiveUploads -and
        $componentSettings.SFTP.ArchiveUpload) {
        $lines += ":cloud: Архіви у хмарі актуальні"
    }
    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaSFTPHealthEnabled) {
        $lines += ":arrows_counterclockwise: Синхронізація BAZA_APP з хмарою актуальна"
    }
    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled) {
        $lines += ":arrows_counterclockwise: Синхронізація BAZA_WWW з хмарою актуальна"
    }
    if ($bazaLocalHealthEnabled) {
        $lines += ":arrows_counterclockwise: Локальна копія BAZA_APP актуальна"
    }
    if ($backupMonitoring.SMB.Enabled -and
        $backupMonitoring.SMB.CheckArchiveCopies -and
        $componentSettings.SMB.ArchiveCopy) {
        $lines += ":minidisc: Архіви на NAS/SMB актуальні"
    }

    $lines += ""
    $lines += ":memo: Журнал перевірки: $healthLogFile"
    return $lines -join [Environment]::NewLine
}

function Get-AlertFingerprint {
    param([array]$Issues)

    $source = "compact-alert-v3`n" + (($Issues | ForEach-Object {
        if ($_.Kind -eq "SFTPSynchronization" -and
            $_.Reason -eq "у хмарі відсутні або потребують оновлення локальні файли/папки") {
            # Розмір черги BAZA природно змінюється щогодини. Він не має
            # створювати новий fingerprint та обходити RepeatAlertAfterHours.
            "$($_.Kind)|$($_.Component)|$($_.Reason)|$($_.Location)"
        } else {
            "$($_.Kind)|$($_.Component)|$($_.Reason)|$($_.FileName)|$($_.LastWriteTime)|$($_.Location)|$($_.DifferenceCount)|$($_.ExpectedSizeBytes)|$($_.ActualSizeBytes)|$($_.ActionCounts.New)|$($_.ActionCounts.Updated)|$($_.ActionCounts.RemoteExtra)|$($_.ActionCounts.Other)"
        }
    }) -join "`n")

    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($source)
        return [System.BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }
}

function Test-AlertSuppressed {
    param([string]$Fingerprint)

    if ($ForceNotification -or -not (Test-Path -Path $backupMonitoring.AlertStatePath -PathType Leaf)) {
        return $false
    }

    try {
        $state = Read-BRAVOTextFile -Path $backupMonitoring.AlertStatePath |
            ConvertFrom-BRAVOJson
        $lastSent = [datetime]::Parse(
            $state.LastSentUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        $timeSinceLastAlert = [datetime]::UtcNow - $lastSent.ToUniversalTime()
        return $state.Fingerprint -eq $Fingerprint -and
            $timeSinceLastAlert.TotalHours -lt [double]$backupMonitoring.RepeatAlertAfterHours
    } catch {
        Write-HealthLog "Не вдалося прочитати стан попереднього сповіщення: $($_.Exception.Message)" -Level "WARNING"
        return $false
    }
}

function Save-AlertState {
    param([string]$Fingerprint)

    $stateDirectory = Split-Path $backupMonitoring.AlertStatePath -Parent
    if (-not (Test-Path -Path $stateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $state = @{
        Fingerprint = $Fingerprint
        LastSentUtc = [datetime]::UtcNow.ToString("o")
    } | ConvertTo-BRAVOJson

    $temporaryStatePath = "$($backupMonitoring.AlertStatePath).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryStatePath,
            $state,
            [System.Text.Encoding]::UTF8
        )
        Move-Item -LiteralPath $temporaryStatePath -Destination $backupMonitoring.AlertStatePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryStatePath) {
            Remove-Item -LiteralPath $temporaryStatePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-AlertState {
    if (-not (Test-Path -LiteralPath $backupMonitoring.AlertStatePath -PathType Leaf)) {
        return
    }
    try {
        Remove-Item -LiteralPath $backupMonitoring.AlertStatePath -Force -ErrorAction Stop
        Write-HealthLog "Стан попередньої аварії очищено після успішної перевірки" -Level "INFO"
    } catch {
        # Неможливість очистити suppression-state не робить резервні копії
        # несправними, але має бути видимою у журналі.
        Write-HealthLog "Не вдалося очистити стан попереднього сповіщення: $($_.Exception.Message)" -Level "WARNING"
    }
}

function Send-SlackAlert {
    param([string]$Message)

    if ($NotificationProvider -notin @("slack", "discord")) {
        throw "Невідомий канал повідомлень: $NotificationProvider"
    }
    if ([string]::IsNullOrWhiteSpace($NotificationWebhookUrl) -or
        -not $NotificationWebhookUrl.StartsWith("https://")) {
        throw "Webhook для $NotificationProviderDisplayName не налаштовано або він не використовує HTTPS"
    }

    try {
        Enable-BRAVOTls12
    } catch {
        Write-HealthLog "Не вдалося примусово увімкнути TLS 1.2: $($_.Exception.Message)" -Level "DEBUG"
    }

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
            $reader.Dispose()
            $reader = $null
            $response.Dispose()
            $response = $null

            if ($NotificationProvider -eq "slack" -and
                -not [string]::IsNullOrWhiteSpace($responseText) -and
                $responseText -ne "ok") {
                throw "Slack повернув неочікувану відповідь: $responseText"
            }
        } catch [System.Net.WebException] {
            $webException = $_.Exception
            $statusText = "невідомий HTTP-статус"
            $responseText = ""
            $errorResponse = $webException.Response

            if ($null -ne $errorResponse) {
                try {
                    if ($errorResponse.StatusCode) {
                        $statusText = "$([int]$errorResponse.StatusCode) $($errorResponse.StatusDescription)"
                    }
                    $errorReader = New-Object System.IO.StreamReader(
                        $errorResponse.GetResponseStream(),
                        [System.Text.Encoding]::UTF8
                    )
                    try {
                        $responseText = $errorReader.ReadToEnd().Trim()
                    } finally {
                        $errorReader.Dispose()
                    }
                } catch {
                    $responseText = ""
                }
            }

            if ([string]::IsNullOrWhiteSpace($responseText)) {
                throw "$NotificationProviderDisplayName HTTP ${statusText}: $($webException.Message)"
            }
            throw "$NotificationProviderDisplayName HTTP ${statusText}: $responseText"
        } finally {
            if ($requestStream) { $requestStream.Dispose() }
            if ($reader) { $reader.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}

function Test-BRAVOArchiveProcessLockActive {
    $lockPath = Join-Path $logPath "BRAVO_OPERATION.lock"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        return $false
    }

    $lockStream = $null
    try {
        $lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        return $false
    } catch {
        return $true
    } finally {
        if ($lockStream) {
            $lockStream.Dispose()
        }
    }
}

if (-not $backupMonitoring.Enabled) {
    Write-HealthLog "Моніторинг резервних копій вимкнено в конфігурації" -Level "INFO"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Disabled"
        IssueCount = 0
        Notification = "NotSent"
        LogPath = $healthLogFile
    })
}

if ($NotificationProvider -notin @("slack", "discord") -or
    $NotificationMode -notin @("none", "errors_only", "all") -or
    ($NotificationMode -ne "none" -and
    ([string]::IsNullOrWhiteSpace($NotificationWebhookUrl) -or
    -not $NotificationWebhookUrl.StartsWith("https://")))) {
    $credentialDetails = if ($notificationCredentialError) { ": $notificationCredentialError" } else { "" }
    Write-HealthLog "Некоректно налаштовано канал повідомлень або його webhook у Credential Manager$credentialDetails" -Level "ERROR"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "ConfigurationError"
        IssueCount = 0
        Notification = "NotSent"
        LogPath = $healthLogFile
    })
}

if ($SkipIfBackupTaskRunning) {
    try {
        $backupTaskState = Get-BRAVOScheduledTaskState `
            -TaskPath ([string]$schedulerSettings.TaskPath) `
            -TaskName ([string]$schedulerSettings.Backup.TaskName)
        Write-HealthLog "Перевірка стану завдання архівації: $($backupTaskState.Provider)" -Level "DEBUG"

        $archiveProcessLockActive = Test-BRAVOArchiveProcessLockActive
        if ($backupTaskState.IsRunning -or $archiveProcessLockActive) {
            $runningIndicator = if (
                $backupTaskState.IsRunning -and $archiveProcessLockActive
            ) {
                "стан завдання та блокування процесу"
            } elseif ($backupTaskState.IsRunning) {
                "стан завдання"
            } else {
                "блокування процесу"
            }
            Write-HealthLog "Health-check відкладено: архівація зараз виконується ($runningIndicator)" -Level "INFO"
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "Deferred"
                IssueCount = 0
                Notification = "NotRequired"
                LogPath = $healthLogFile
            })
        }
    } catch {
        Write-HealthLog "Не вдалося перевірити стан завдання архівації; health-check продовжується: $($_.Exception.Message)" -Level "WARNING"
    }
}

Write-HealthLog "Конфігурація: $ConfigPath"
Write-HealthLog "Сумісність: Windows $($BRAVOCompatibility.WindowsVersion); PowerShell $($BRAVOCompatibility.PowerShellVersion); WMI=$($BRAVOCompatibility.WmiProvider); JSON=$($BRAVOCompatibility.JsonProvider); завдання=$($BRAVOCompatibility.TaskSchedulerProvider)"
Write-HealthLog "Каталог резервних копій: $backupRootPath"
if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
    Write-HealthLog $BRAVOPowerShellUpdate.Message -Level "WARNING"
}
if ($BRAVOWindowsPatchLevel.IsUpdateRecommended) {
    Write-HealthLog $BRAVOWindowsPatchLevel.Message -Level "WARNING"
}
$script:BRAVOOSSupportTier = Get-BRAVOOSSupportTier
Write-HealthLog "Підтримка ОС: $($script:BRAVOOSSupportTier.Tier) — Windows $($script:BRAVOOSSupportTier.OperatingSystem) ($($script:BRAVOOSSupportTier.OperatingSystemVersion), build $($script:BRAVOOSSupportTier.Build)); PowerShell $($script:BRAVOOSSupportTier.PowerShellVersion); .NET release $($script:BRAVOOSSupportTier.DotNetRelease)"
if ($script:BRAVOOSSupportTier.Tier -eq "LegacyBestEffort") {
    Write-HealthLog $script:BRAVOOSSupportTier.Message -Level "WARNING"
} elseif ($script:BRAVOOSSupportTier.Tier -eq "Unsupported") {
    if ($env:BRAVO_ALLOW_UNSUPPORTED_OS -eq "1") {
        Write-HealthLog "$($script:BRAVOOSSupportTier.Message) Продовжено через BRAVO_ALLOW_UNSUPPORTED_OS=1." -Level "WARNING"
    } else {
        Write-HealthLog $script:BRAVOOSSupportTier.Message -Level "ERROR"
        return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
            Status = "ConfigurationError"
            IssueCount = 0
            Notification = "NotRequired"
            LogPath = $healthLogFile
            Error = $script:BRAVOOSSupportTier.Message
        })
    }
}
$script:BRAVOToolIntegrity = Get-BRAVOToolIntegrityRecommendation `
    -ToolPaths @($arcPath, $winSCPPath, $winSCPAssemblyPath) `
    -ManifestPath (Join-Path $toolsPath "TOOLS_INTEGRITY.json")
if ($script:BRAVOToolIntegrity.HasIntegrityIssue) {
    Write-HealthLog $script:BRAVOToolIntegrity.Message -Level "WARNING"
}
$bazaLocalMode = if ($bazaLocalHealthEnabled) { "увімкнено" } else { "вимкнено" }
$bazaSFTPMode = if ($bazaSFTPHealthEnabled) { "увімкнено" } else { "вимкнено" }
$bazaWWWSFTPMode = if ($bazaWWWSFTPHealthEnabled) { "увімкнено" } else { "вимкнено" }
Write-HealthLog "Перевірка BAZA: локальна копія = $bazaLocalMode; SFTP = $bazaSFTPMode; BAZA WWW SFTP = $bazaWWWSFTPMode"
if ($bazaWWWSFTPHealthEnabled) {
    if ($bazaWWWDetection.Success) {
        Write-HealthLog (
            "BAZA WWW визначено через службу $($bazaWWWDetection.ServiceName): " +
            $bazaWWWPaths.Source
        ) -Level "INFO"
    } else {
        Write-HealthLog "BAZA WWW не визначено: $($bazaWWWDetection.Reason)" -Level "WARNING"
    }
}
Write-HealthLog "Початок перевірки резервних копій за останні $($backupMonitoring.MaxBackupAgeHours) год."
$serviceHealthIssues = @(Get-ManagedServiceHealthIssues)
$localHealthIssues = @(Get-BackupHealthIssues)
$bazaLocalHealthIssues = if ($bazaLocalHealthEnabled) {
    @(Get-BAZALocalHealthIssues)
} else {
    Write-HealthLog "Локальну перевірку BAZA пропущено: componentSettings.Synchronization.BAZALocal = `$false"
    @()
}
$sftpHealthIssues = @(Get-SFTPHealthIssues)
$smbHealthIssues = @(Get-SMBHealthIssues)
$healthIssues = @($serviceHealthIssues) + @($localHealthIssues) + @($bazaLocalHealthIssues) + @($sftpHealthIssues) + @($smbHealthIssues)
$destinationSummary = Get-BRAVOHealthDestinationSummary `
    -LocalIssues $localHealthIssues `
    -BazaLocalIssues $bazaLocalHealthIssues `
    -SftpIssues $sftpHealthIssues `
    -SmbIssues $smbHealthIssues

if ($healthIssues.Count -eq 0) {
    Write-HealthLog "Усі керовані служби працюють, а локальні, SFTP та NAS/SMB-компоненти мають актуальні резервні копії" -Level "SUCCESS"
    Clear-AlertState

    $sendSuccessNotification = (
        ($NotifyOnSuccess -or $ForceNotification) -and
        -not $NoSlack -and
        $NotificationMode -eq "all"
    )
    if ($sendSuccessNotification) {
        $healthDuration = (Get-Date) - $healthCheckStarted
        $successMessage = New-SlackSuccessMessage -Duration $healthDuration
        try {
            Send-SlackAlert -Message $successMessage
            Write-HealthLog "Успішний звіт відправлено у $NotificationProviderDisplayName" -Level "SUCCESS"
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "Healthy"
                IssueCount = 0
                Notification = "Sent"
                LogPath = $healthLogFile
                LocalVerified = $destinationSummary.LocalVerified
                SftpVerified = $destinationSummary.SftpVerified
                SmbVerified = $destinationSummary.SmbVerified
            })
        } catch {
            Write-HealthLog "Не вдалося відправити успішний звіт у ${NotificationProviderDisplayName}: $($_.Exception.Message)" -Level "ERROR"
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "NotificationError"
                IssueCount = 0
                Notification = "Failed"
                LogPath = $healthLogFile
                Error = $_.Exception.Message
                LocalVerified = $destinationSummary.LocalVerified
                SftpVerified = $destinationSummary.SftpVerified
                SmbVerified = $destinationSummary.SmbVerified
            })
        }
    }

    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Healthy"
        IssueCount = 0
        Notification = "NotRequired"
        LogPath = $healthLogFile
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
}

foreach ($healthIssue in $healthIssues) {
    switch ($healthIssue.Kind) {
        "Service" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason)" -Level "ERROR"
        }
        "SFTPArchive" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); файл: $($healthIssue.FileName); фактичний розмір: $(Format-FileSize $healthIssue.ActualSizeBytes)" -Level "ERROR"
        }
        "SFTPSynchronization" {
            if ($healthIssue.Reason -eq "у хмарі відсутні або потребують оновлення локальні файли/папки") {
                $pendingParts = @()
                if ([int]$healthIssue.ActionCounts.New -gt 0) {
                    $pendingParts += "відсутніх: $($healthIssue.ActionCounts.New)"
                }
                if ([int]$healthIssue.ActionCounts.Updated -gt 0) {
                    $pendingParts += "застарілих: $($healthIssue.ActionCounts.Updated)"
                }
                if ([int]$healthIssue.ActionCounts.Other -gt 0) {
                    $pendingParts += "без окремої класифікації: $($healthIssue.ActionCounts.Other)"
                }
                $pendingSummary = if ($pendingParts.Count -gt 0) {
                    $pendingParts -join ", "
                } else {
                    "типи не визначено"
                }
                Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); очікують передачі: $($healthIssue.DifferenceCount) ($pendingSummary); розмір: $(Format-FileSize $healthIssue.SizeBytes)" -Level "ERROR"
            } else {
                $actionSummary = if ($null -ne $healthIssue.ActionCounts) {
                    "нових: $($healthIssue.ActionCounts.New), змінених: $($healthIssue.ActionCounts.Updated), зайвих у хмарі: $($healthIssue.ActionCounts.RemoteExtra), очікують передачі: $($healthIssue.ActionCounts.Other)"
                } else {
                    "типи розбіжностей: немає даних"
                }
                Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); розбіжностей: $($healthIssue.DifferenceCount) ($actionSummary); розмір: $(Format-FileSize $healthIssue.SizeBytes)" -Level "ERROR"
            }
            if ($healthIssue.Details -and $healthIssue.Details.Count -gt 0) {
                Write-HealthLog "Деталі $($healthIssue.Component): $($healthIssue.Details -join '; ')" -Level "ERROR"
            }
        }
        "LocalSynchronization" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); джерело: $($healthIssue.Source); локальна копія: $($healthIssue.Location); код robocopy: $($healthIssue.ExitCode)" -Level "ERROR"
        }
        "SFTPConnection" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason)" -Level "ERROR"
        }
        "SMBArchive" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); файл: $($healthIssue.FileName); фактичний розмір: $(Format-FileSize $healthIssue.ActualSizeBytes)" -Level "ERROR"
        }
        "SMBConnection" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason)" -Level "ERROR"
        }
        default {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); файл: $($healthIssue.FileName); вік: $(Format-BackupAge $healthIssue.LastWriteTime); розмір: $(Format-FileSize $healthIssue.SizeBytes)" -Level "ERROR"
        }
    }
}

$healthDuration = (Get-Date) - $healthCheckStarted
$slackMessage = New-SlackAlertMessage -Issues $healthIssues -Duration $healthDuration
$alertFingerprint = Get-AlertFingerprint -Issues $healthIssues

if ($NoSlack -or $NotificationMode -eq "none") {
    $disabledReason = if ($NoSlack) { "параметром -NoSlack" } else { "режимом none" }
    Write-HealthLog "Відправлення повідомлення вимкнено $disabledReason" -Level "WARNING"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Critical"
        IssueCount = $healthIssues.Count
        Notification = "Disabled"
        LogPath = $healthLogFile
        Message = $slackMessage
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
}

if (Test-AlertSuppressed -Fingerprint $alertFingerprint) {
    Write-HealthLog "Повторне однакове сповіщення тимчасово пригнічено" -Level "INFO"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Critical"
        IssueCount = $healthIssues.Count
        Notification = "Suppressed"
        LogPath = $healthLogFile
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
}

try {
    Send-SlackAlert -Message $slackMessage
    Save-AlertState -Fingerprint $alertFingerprint
    Write-HealthLog "Критичне повідомлення успішно відправлено у $NotificationProviderDisplayName" -Level "SUCCESS"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Critical"
        IssueCount = $healthIssues.Count
        Notification = "Sent"
        LogPath = $healthLogFile
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
} catch {
    Write-HealthLog "Не вдалося відправити повідомлення у ${NotificationProviderDisplayName}: $($_.Exception.Message)" -Level "ERROR"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "NotificationError"
        IssueCount = $healthIssues.Count
        Notification = "Failed"
        LogPath = $healthLogFile
        Error = $_.Exception.Message
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
}

}
# END BRAVO HEALTH RUNTIME
if ($MyInvocation.InvocationName -ne '.') {
    $healthParameters = @{
        ConfigPath = $ConfigPath
        ForceNotification = $ForceNotification
        NotifyOnSuccess = $NotifyOnSuccess
        NoSlack = $NoSlack
        SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning
    }
    $healthResult = Invoke-BRAVOHealth @healthParameters
    # Deferred — це саме "пропущено через lock/уже виконується інше завдання"
    # у сенсі загального контракту кодів, тому окремий код 20, а не 0/1.
    # Skipped ніколи фактично не породжується цим runtime (мертва гілка),
    # лишена як безпечний fallback на успіх.
    $exitCode = switch ([string]$healthResult.Status) {
        'Healthy'            { 0 }
        'Skipped'            { 0 }
        'Disabled'           { 0 }
        'Deferred'           { Resolve-BRAVOExitCode -LockBusy }
        'ConfigurationError' { Resolve-BRAVOExitCode -InvalidConfiguration }
        'Critical'           { Resolve-BRAVOExitCode -HealthCritical }
        'NotificationError'  { Resolve-BRAVOExitCode -HealthCritical }
        default              { Resolve-BRAVOExitCode -HealthCritical }
    }
    if ($exitCode -eq 0 -and $script:BRAVOWarningCount -gt 0) {
        $exitCode = Resolve-BRAVOExitCode -HasWarnings
    }
    exit $exitCode
}
