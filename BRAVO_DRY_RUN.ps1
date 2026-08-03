[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$TestAccess,
    [switch]$SendTestNotification,
    [switch]$SkipCredentials,
    [switch]$RequireScheduledTasks,
    [switch]$AsJson,
    [string]$ResultPath
)

$helperLoggingPath = Join-Path $PSScriptRoot "BRAVO_HELPER_LOGGING.ps1"
. $helperLoggingPath
$null = Start-BRAVOHelperLog `
    -ScriptPath $PSCommandPath `
    -ConfigPath $ConfigPath `
    -QuietConsole:$AsJson

# Безпечна симуляція BRAVO/VETOFFICE:
# - не створює архіви та каталоги;
# - не копіює, не синхронізує і не видаляє файли;
# - не змінює служби або Планувальник завдань;
# - надсилає тестове Slack/Discord повідомлення лише з -SendTestNotification.
# -TestAccess виконує лише read-only мережеві перевірки.

$ErrorActionPreference = "Stop"
$script:dryRunResults = New-Object System.Collections.ArrayList

function Add-DryRunResult {
    param(
        [ValidateSet("PASS", "WARN", "FAIL", "PLAN")]
        [string]$Status,
        [string]$Category,
        [string]$Name,
        [string]$Detail
    )

    [void]$script:dryRunResults.Add([pscustomobject]@{
        Status = $Status
        Category = $Category
        Name = $Name
        Detail = $Detail
    })
}

function Test-SettingEnabled {
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($null -eq $Value) {
        return $false
    }
    return ([string]$Value).Trim().ToLowerInvariant() -in @(
        "1", "true", "yes", "on", "enabled"
    )
}

function Get-ConfiguredTarget {
    param(
        [string]$PropertyName,
        [string]$DefaultValue
    )

    $configuredValue = $null
    if ($null -ne $credentialSettings -and
        $null -ne $credentialSettings.Targets) {
        $configuredValue = [string]$credentialSettings.Targets[$PropertyName]
    }
    if ([string]::IsNullOrWhiteSpace($configuredValue)) {
        return $DefaultValue
    }
    return $configuredValue
}

function Get-RequiredCredentialDescriptors {
    $descriptors = New-Object System.Collections.ArrayList

    if ($null -ne $bravoSettings.InstitutionName -and
        $null -ne $bravoSettings.InstitutionCode -and
        $null -ne $bravoSettings.ArchivePrefix) {
        [void]$descriptors.Add([pscustomobject]@{
            Name = "Назва установи"
            Target = Get-ConfiguredTarget "InstitutionName" "BRAVO_INSTITUTION_NAME"
            Kind = "InstitutionName"
        })
        [void]$descriptors.Add([pscustomobject]@{
            Name = "Код установи"
            Target = Get-ConfiguredTarget "InstitutionCode" "BRAVO_INSTITUTION_CODE"
            Kind = "InstitutionCode"
        })
        [void]$descriptors.Add([pscustomobject]@{
            Name = "Префікс архівів"
            Target = Get-ConfiguredTarget "ArchivePrefix" "BRAVO_ARCHIVE_PREFIX"
            Kind = "ArchivePrefix"
        })
    }

    $archiveEnabled = $true
    if ($null -ne $componentSettings -and $null -ne $componentSettings.Archive) {
        $archiveEnabled = Test-SettingEnabled $componentSettings.Archive.MODEL
        $archiveEnabled = $archiveEnabled -or
            (Test-SettingEnabled $componentSettings.Archive.BLOG)
        $archiveEnabled = $archiveEnabled -or
            (Test-SettingEnabled $componentSettings.Archive.BRAVOEXCH)
    }
    if ($archiveEnabled) {
        [void]$descriptors.Add([pscustomobject]@{
            Name = "Пароль архівів"
            Target = Get-ConfiguredTarget "ArchivePassword" "BRAVO_7Z_PASSWORD"
            Kind = "Archive"
        })
    }

    $sftpEnabled = (Test-SettingEnabled $componentSettings.SFTP.ArchiveUpload) -or
        (Test-SettingEnabled $componentSettings.Synchronization.BAZASFTP) -or
        (Test-SettingEnabled $componentSettings.Synchronization.BAZAWWWSFTP) -or
        (Test-SettingEnabled $backupMonitoring.SFTP.Enabled)
    if ($sftpEnabled) {
        [void]$descriptors.Add([pscustomobject]@{
            Name = "SFTP логін"
            Target = Get-ConfiguredTarget "SFTPLogin" "BRAVO_SFTP_LOGIN"
            Kind = "SFTPLogin"
        })
        [void]$descriptors.Add([pscustomobject]@{
            Name = "SFTP пароль"
            Target = Get-ConfiguredTarget "SFTPPassword" "BRAVO_SFTP_PASSWORD"
            Kind = "SFTPPassword"
        })
    }

    $smbEnabled = Test-SettingEnabled $componentSettings.SMB.ArchiveCopy
    if ($smbEnabled) {
        [void]$descriptors.Add([pscustomobject]@{
            Name = "SMB логін"
            Target = Get-ConfiguredTarget "SMBLogin" "BRAVO_SMB_LOGIN"
            Kind = "SMBLogin"
        })
        [void]$descriptors.Add([pscustomobject]@{
            Name = "SMB пароль"
            Target = Get-ConfiguredTarget "SMBPassword" "BRAVO_SMB_PASSWORD"
            Kind = "SMBPassword"
        })
    }

    $notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
    if ($notificationMode -ne "none") {
        $provider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
        if ($provider -eq "slack") {
            [void]$descriptors.Add([pscustomobject]@{
                Name = "Slack webhook"
                Target = Get-ConfiguredTarget "SlackWebhook" "BRAVO_SLACK_URL"
                Kind = "Webhook"
            })
        } else {
            [void]$descriptors.Add([pscustomobject]@{
                Name = "Discord webhook"
                Target = Get-ConfiguredTarget "DiscordWebhook" "BRAVO_DISCORD_URL"
                Kind = "Webhook"
            })
        }
    }

    return $descriptors.ToArray()
}

function Get-SourceDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded.EndsWith("\*") -or $expanded.EndsWith("/*")) {
        return $expanded.Substring(0, $expanded.Length - 2)
    }
    return $expanded
}

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            throw "тайм-аут $TimeoutMilliseconds мс"
        }
        $client.EndConnect($asyncResult)
        return $true
    } finally {
        $client.Close()
    }
}

function Send-TestWebhookNotification {
    param(
        [string]$Provider,
        [string]$WebhookUrl,
        [string]$ConfigFileName
    )

    $normalizedProvider = $Provider.Trim().ToLowerInvariant()
    if ($normalizedProvider -notin @("slack", "discord")) {
        throw "невідомий notification provider: $Provider"
    }
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        throw "webhook відсутній у Credential Manager"
    }

    $uri = New-Object Uri($WebhookUrl)
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne "https") {
        throw "webhook повинен бути абсолютним HTTPS URL"
    }

    $institution = ([string]$bravoSettings.InstitutionName).Trim()
    $institutionCode = ([string]$bravoSettings.InstitutionCode).Trim()
    $objectText = if (-not [string]::IsNullOrWhiteSpace($institutionCode)) {
        "$institution [$institutionCode]".Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($institution)) {
        $institution
    } else {
        "BRAVO"
    }
    $message = @(
        "✅ BRAVO — тестове сповіщення"
        "Об'єкт: $objectText"
        "Комп'ютер: $env:COMPUTERNAME"
        "Config: $ConfigFileName"
        "Час: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        "🏷️ Версія BRAVO_DRY_RUN: $ScriptVersion від $ScriptDate"
        "Credential Manager і надсилання webhook працюють."
        "Production-операції архівації, копіювання та видалення не запускалися."
    ) -join "`n"

    $payload = if ($normalizedProvider -eq "discord") {
        @{
            content = $message
            allowed_mentions = @{parse = @()}
        }
    } else {
        @{text = $message}
    }
    $body = [Text.Encoding]::UTF8.GetBytes(
        ($payload | ConvertTo-Json -Compress -Depth 5)
    )
    $timeoutSeconds = if (
        [int]$bravoSettings.NotificationRequestTimeoutSeconds -gt 0
    ) {
        [int]$bravoSettings.NotificationRequestTimeoutSeconds
    } else {
        30
    }

    # Windows 7 / Server 2008 R2 потребують явного ввімкнення TLS 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject(
        [Net.SecurityProtocolType],
        3072
    )
    [Net.ServicePointManager]::Expect100Continue = $false

    $request = [Net.WebRequest]::Create($uri)
    $request.Method = "POST"
    $request.ContentType = "application/json; charset=utf-8"
    $request.ContentLength = $body.Length
    $request.Timeout = $timeoutSeconds * 1000
    $request.ReadWriteTimeout = $timeoutSeconds * 1000
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
        $statusCode = [int]$response.StatusCode
        $reader = New-Object IO.StreamReader(
            $response.GetResponseStream(),
            [Text.Encoding]::UTF8
        )
        $responseText = $reader.ReadToEnd().Trim()

        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            throw "$normalizedProvider повернув HTTP $statusCode"
        }
        if ($normalizedProvider -eq "slack" -and
            -not [string]::IsNullOrWhiteSpace($responseText) -and
            $responseText -ne "ok") {
            throw "Slack повернув неочікувану відповідь: $responseText"
        }
        return "$normalizedProvider прийняв тестове повідомлення; HTTP $statusCode"
    } catch [Net.WebException] {
        $webException = $_.Exception
        $statusText = "невідомий HTTP-статус"
        $responseText = ""
        $errorResponse = $webException.Response
        if ($null -ne $errorResponse) {
            try {
                if ($errorResponse.StatusCode) {
                    $statusText = "$([int]$errorResponse.StatusCode) $($errorResponse.StatusDescription)"
                }
                $errorReader = New-Object IO.StreamReader(
                    $errorResponse.GetResponseStream(),
                    [Text.Encoding]::UTF8
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
            throw "Webhook HTTP ${statusText}: $($webException.Message)"
        }
        throw "Webhook HTTP ${statusText}: $responseText"
    } finally {
        if ($requestStream) { $requestStream.Dispose() }
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Resolve-SftpHost {
    param([string]$Login)

    if (-not [string]::IsNullOrWhiteSpace([string]$sftpHostTemplate)) {
        return ([string]$sftpHostTemplate) -f $Login
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$sftpHostName)) {
        return [string]$sftpHostName
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$sftpHost)) {
        return [string]$sftpHost
    }
    throw "SFTP host не налаштовано"
}

function Get-WinSCPComponents {
    $assemblyCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPAssemblyPath)) {
        $assemblyCandidates += [string]$winSCPAssemblyPath
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
        $assemblyCandidates += Join-Path (Split-Path $winSCPPath -Parent) "WinSCPnet.dll"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$toolsPath)) {
        $assemblyCandidates += Join-Path $toolsPath "WinSCPnet.dll"
    }
    if (${env:ProgramFiles(x86)}) {
        $assemblyCandidates += Join-Path ${env:ProgramFiles(x86)} "WinSCP\WinSCPnet.dll"
    }
    if ($env:ProgramFiles) {
        $assemblyCandidates += Join-Path $env:ProgramFiles "WinSCP\WinSCPnet.dll"
    }

    foreach ($assemblyPath in @($assemblyCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            continue
        }
        $executableCandidates = @(
            (Join-Path (Split-Path $assemblyPath -Parent) "WinSCP.exe")
        )
        if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
            $configuredDirectory = Split-Path $winSCPPath -Parent
            $executableCandidates += Join-Path $configuredDirectory "WinSCP.exe"
        }
        $executable = @(
            $executableCandidates |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
        )
        if ($executable.Count -gt 0) {
            return [pscustomobject]@{
                Assembly = $assemblyPath
                Executable = [string]$executable[0]
            }
        }
    }
    return $null
}

function Test-SftpReadOnlyAccess {
    param(
        [string]$Login,
        [string]$Password
    )

    $hostName = Resolve-SftpHost -Login $Login
    $port = if ([int]$sftpPort -gt 0) { [int]$sftpPort } else { 22 }
    [void](Test-TcpPort -HostName $hostName -Port $port)

    $components = Get-WinSCPComponents
    if ($null -eq $components) {
        throw "для authenticated test не знайдено пару WinSCPnet.dll + WinSCP.exe"
    }

    Add-Type -Path $components.Assembly
    $session = New-Object WinSCP.Session
    try {
        $session.ExecutablePath = $components.Executable
        $options = New-Object WinSCP.SessionOptions
        $options.Protocol = [WinSCP.Protocol]::Sftp
        $options.HostName = $hostName
        $options.PortNumber = $port
        $options.UserName = $Login
        $options.Password = $Password
        $options.SshHostKeyFingerprint = ([string]$sftpHostKey).Trim().Trim('"')
        $session.Open($options)
        [void]$session.ListDirectory(".")
        return "$hostName`:$port — автентифікація і читання каталогу успішні"
    } finally {
        $session.Dispose()
    }
}

function Test-SmbReadOnlyAccess {
    param(
        [string]$RootPath,
        [string]$Login,
        [string]$Password
    )

    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not $RootPath.StartsWith("\\")) {
        throw "SMB RootPath повинен бути UNC-шляхом"
    }
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object Management.Automation.PSCredential($Login, $securePassword)
    $driveName = "BRV" + ([guid]::NewGuid().ToString("N").Substring(0, 5))
    try {
        [void](New-PSDrive -Name $driveName -PSProvider FileSystem -Root $RootPath -Credential $credential -Scope Script)
        [void](Get-ChildItem -LiteralPath "${driveName}:\" -Force -ErrorAction Stop | Select-Object -First 1)
        return "$RootPath — автентифікація і читання каталогу успішні"
    } finally {
        Remove-PSDrive -Name $driveName -Scope Script -Force -ErrorAction SilentlyContinue
        $securePassword.Dispose()
    }
}

function Write-DryRunOutput {
    if ($AsJson -or -not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $json = $script:dryRunResults.ToArray() | ConvertTo-Json -Depth 5
        if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
            $resolvedResultDirectory = Split-Path -Path $ResultPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($resolvedResultDirectory) -and
                -not (Test-Path -LiteralPath $resolvedResultDirectory -PathType Container)) {
                throw "Каталог ResultPath не існує: $resolvedResultDirectory"
            }
            [IO.File]::WriteAllText(
                $ResultPath,
                [string]$json,
                (New-Object Text.UTF8Encoding($false))
            )
        }
        if ($AsJson) {
            $json
        }
        return
    }

    Write-Host ""
    Write-Host "BRAVO — БЕЗПЕЧНИЙ ТЕСТОВИЙ ПРОГІН" -ForegroundColor Cyan
    Write-Host "Жодні production-операції не виконувалися." -ForegroundColor DarkGray
    foreach ($result in $script:dryRunResults) {
        $color = switch ($result.Status) {
            "PASS" { "Green" }
            "WARN" { "Yellow" }
            "FAIL" { "Red" }
            default { "Cyan" }
        }
        Write-Host ("[{0}] {1} / {2}: {3}" -f
            $result.Status, $result.Category, $result.Name, $result.Detail) `
            -ForegroundColor $color
    }

    $failures = @($script:dryRunResults | Where-Object { $_.Status -eq "FAIL" }).Count
    $warnings = @($script:dryRunResults | Where-Object { $_.Status -eq "WARN" }).Count
    Write-Host ""
    Write-Host "Підсумок: помилок — $failures; попереджень — $warnings." `
        -ForegroundColor $(if ($failures -gt 0) { "Red" } elseif ($warnings -gt 0) { "Yellow" } else { "Green" })
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
    $isVetOfficeConfiguration = (
        (Split-Path $resolvedConfigPath -Leaf) -ieq "ARCHIV_VETOFFICE.config.ps1"
    )
    if ($isVetOfficeConfiguration) {
        # VETOFFICE — окремий legacy-комплект із власним форматом config.
        $configText = [IO.File]::ReadAllText($resolvedConfigPath, [Text.Encoding]::UTF8)
        & ([scriptblock]::Create($configText)) -ConfigRoot $configRoot
    } else {
        $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
        if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
            throw "Configuration loader not found: $configurationLoaderPath"
        }
        . $configurationLoaderPath
        Import-BravoConfiguration -ConfigRoot $configRoot -ConfigPath $resolvedConfigPath
    }
    Add-DryRunResult PASS "Конфігурація" "Завантаження" $resolvedConfigPath

    $requiredScriptNames = if ($isVetOfficeConfiguration) {
        @("ARCHIV_VETOFFICE.ps1")
    } else {
        @(
            "BRAVO_ARCHIV.ps1",
            "BRAVO_MAINTENANCE.ps1"
        )
    }
    foreach ($scriptName in $requiredScriptNames) {
        $scriptFile = Join-Path $configRoot $scriptName
        if (Test-Path -LiteralPath $scriptFile -PathType Leaf) {
            Add-DryRunResult PASS "Скрипти" $scriptName $scriptFile
        } else {
            Add-DryRunResult FAIL "Скрипти" $scriptName "файл відсутній: $scriptFile"
        }
    }

    $archiverPath = if (-not [string]::IsNullOrWhiteSpace([string]$arcPath)) {
        [string]$arcPath
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$toolsPath)) {
        Join-Path $toolsPath "7za.exe"
    } else {
        $null
    }
    if ($archiverPath -and (Test-Path -LiteralPath $archiverPath -PathType Leaf)) {
        Add-DryRunResult PASS "Інструменти" "7-Zip" $archiverPath
    } else {
        Add-DryRunResult FAIL "Інструменти" "7-Zip" "не знайдено: $archiverPath"
    }

    $sftpConfigured = (Test-SettingEnabled $componentSettings.SFTP.ArchiveUpload) -or
        (Test-SettingEnabled $componentSettings.Synchronization.BAZASFTP) -or
        (Test-SettingEnabled $componentSettings.Synchronization.BAZAWWWSFTP) -or
        (Test-SettingEnabled $backupMonitoring.SFTP.Enabled)
    if ($sftpConfigured) {
        $configuredWinSCPPath = if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
            [string]$winSCPPath
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$toolsPath)) {
            Join-Path $toolsPath "WinSCP.com"
        } else {
            $null
        }
        if ($configuredWinSCPPath -and
            (Test-Path -LiteralPath $configuredWinSCPPath -PathType Leaf)) {
            Add-DryRunResult PASS "Інструменти" "WinSCP CLI" $configuredWinSCPPath
        } else {
            Add-DryRunResult FAIL "Інструменти" "WinSCP CLI" (
                "не знайдено: $configuredWinSCPPath"
            )
        }
    }

    if (Test-SettingEnabled $componentSettings.Synchronization.BAZALocal) {
        $robocopyExecutable = if (
            [string]::IsNullOrWhiteSpace([string]$robocopyPath)
        ) {
            "robocopy.exe"
        } else {
            [string]$robocopyPath
        }
        $robocopyCommand = Get-Command $robocopyExecutable -ErrorAction SilentlyContinue
        if ($null -ne $robocopyCommand) {
            Add-DryRunResult PASS "Інструменти" "Robocopy" ([string]$robocopyCommand.Path)
        } else {
            Add-DryRunResult FAIL "Інструменти" "Robocopy" (
                "команду '$robocopyExecutable' не знайдено"
            )
        }
    }

    $enabledArchiveCount = 0
    foreach ($definition in @($archiveDefinitions)) {
        if (-not (Test-SettingEnabled $definition.Enabled)) {
            continue
        }
        $enabledArchiveCount++
        $sourceDirectory = Get-SourceDirectory ([string]$definition.Source)
        if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
            Add-DryRunResult PASS "Джерело" ([string]$definition.Type) $sourceDirectory
        } else {
            Add-DryRunResult FAIL "Джерело" ([string]$definition.Type) "каталог відсутній: $sourceDirectory"
        }
        Add-DryRunResult PLAN "Архівація" ([string]$definition.Type) (
            "створення архіву в '$($definition.Destination)' і SHA sidecar"
        )
    }
    if ($enabledArchiveCount -eq 0 -and $null -ne $sourcePaths) {
        foreach ($entry in $sourcePaths.GetEnumerator()) {
            $sourceDirectory = Get-SourceDirectory ([string]$entry.Value)
            if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
                Add-DryRunResult PASS "Джерело" ([string]$entry.Key) $sourceDirectory
            } else {
                Add-DryRunResult FAIL "Джерело" ([string]$entry.Key) "каталог відсутній: $sourceDirectory"
            }
            Add-DryRunResult PLAN "Архівація" ([string]$entry.Key) "створення архіву (симуляція)"
        }
    }

    if (Test-SettingEnabled $componentSettings.Synchronization.BAZALocal) {
        $bazaSource = Get-SourceDirectory ([string]$bazaPaths.Source)
        $bazaDestination = if (-not [string]::IsNullOrWhiteSpace([string]$bazaPaths.Destination)) {
            [string]$bazaPaths.Destination
        } else {
            [string]$bazaPaths.Destination_Local
        }
        if (Test-Path -LiteralPath $bazaSource -PathType Container) {
            Add-DryRunResult PASS "Джерело" "BAZA" $bazaSource
        } else {
            Add-DryRunResult FAIL "Джерело" "BAZA" "каталог відсутній: $bazaSource"
        }
        Add-DryRunResult PLAN "Синхронізація" "BAZA local" (
            "'$bazaSource' -> '$bazaDestination'"
        )
    }
    if (Test-SettingEnabled $componentSettings.Synchronization.BAZASFTP) {
        Add-DryRunResult PLAN "Синхронізація" "BAZA SFTP" (
            "'$($bazaPaths.Source)' -> '/$($sftpDirectories.BAZA)' без -delete"
        )
    }
    if (Test-SettingEnabled $componentSettings.Synchronization.BAZAWWWSFTP) {
        Add-DryRunResult PLAN "Синхронізація" "BAZA WWW SFTP" (
            "'$($bazaWWWPaths.Source)' -> '/$($sftpDirectories.BAZAWWW)' без -delete"
        )
    }

    if ($null -ne $maintenanceSettings) {
        $serviceNames = @([string]$maintenanceSettings.Services.BravoName)
        if (Test-SettingEnabled $maintenanceSettings.Services.BravoWebEnabled) {
            $serviceNames += "BRAVO Web/Apache (автовизначення)"
        }
        if (-not [string]::IsNullOrWhiteSpace(
            [string]$maintenanceSettings.Services.ExchangeApiName
        )) {
            $serviceNames += [string]$maintenanceSettings.Services.ExchangeApiName
        }
        Add-DryRunResult PLAN "Maintenance" "Служби" (
            "контрольована зупинка/запуск: $($serviceNames -join ', '); у dry-run стан не змінювався"
        )
        Add-DryRunResult PLAN "Backup" "Узгодженість джерел" (
            "режим=$($backupConsistency.Mode); " +
            "контекст=$($backupConsistency.SnapshotContext); " +
            "окремий VSS-знімок для кожного архіву; " +
            "спільний BRAVO_OPERATION.lock; очікування до " +
            "$($schedulerSettings.OperationLockWaitMinutes) хв.; служби не змінювалися"
        )
        Add-DryRunResult PLAN "Maintenance" "Відновлення MODEL" (
            "день=$($maintenanceSettings.Restore.Day); час=$($maintenanceSettings.Restore.Time); " +
            "контрольні архіви до/після; відновлення не запускалося"
        )
        Add-DryRunResult PLAN "Maintenance" "Retention" (
            "архіви старші $($maintenanceSettings.Retention.ArchiveDays) дн.; " +
            "логи старші $($maintenanceSettings.Retention.LogDays) дн.; " +
            "failed-архіви старші $($maintenanceSettings.Retention.FailedArchiveDays) дн.; " +
            "нічого не видалено"
        )
        if (Test-SettingEnabled $maintenanceSettings.RangeIdMonitoring.Enabled) {
            Add-DryRunResult PLAN "Maintenance" "Range ID" (
                "read-only перевірка '$($maintenanceSettings.RangeIdMonitoring.FilePath)' " +
                "при $($maintenanceSettings.RangeIdMonitoring.ThresholdPercent)%"
            )
        }
        Add-DryRunResult PLAN "Maintenance" "Shutdown" (
            "AutoShutdown=$($maintenanceSettings.Automation.AutoShutdown); вимкнення ПК не запускалося"
        )
        Add-DryRunResult PLAN "Maintenance" "Архів після maintenance" (
            "ArchiveAfterMaintenance=$($maintenanceSettings.Automation.ArchiveAfterMaintenance); " +
            "BRAVO_ARCHIV.ps1 не запускався"
        )
    } else {
        Add-DryRunResult PLAN "Retention" "Архіви" (
            "enableArchiveDeletion=$enableArchiveDeletion; retentionDays=$archiveRetentionDays; " +
            "failedRetentionDays=$failedArchiveRetentionDays; нічого не видалено"
        )
        Add-DryRunResult PLAN "Retention" "Логи" (
            "logRetentionDays=$logRetentionDays; нічого не видалено"
        )
    }

    if ($null -ne $backupMonitoring -and
        (Test-SettingEnabled $backupMonitoring.Enabled)) {
        Add-DryRunResult PLAN "Health" "Перевірка резервних копій" (
            "локальна/SFTP/SMB перевірка описана config; вбудований HealthCheckOnly не запускався"
        )
    }

    $notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
    if ($notificationMode -ne "none") {
        $notificationPlan = if ($SendTestNotification) {
            "буде надіслано одне явно позначене тестове повідомлення"
        } else {
            "повідомлення не надсилатиметься без -SendTestNotification"
        }
        Add-DryRunResult PLAN "Сповіщення" ([string]$bravoSettings.NotificationProvider) (
            "режим=$notificationMode; $notificationPlan"
        )
    }

    $requiredCredentials = @()
    $credentialValues = @{}
    if (-not $SkipCredentials) {
        if ($null -eq $credentialSettings -or
            [string]::IsNullOrWhiteSpace([string]$credentialSettings.HelperPath) -or
            -not (Test-Path -LiteralPath $credentialSettings.HelperPath -PathType Leaf)) {
            Add-DryRunResult FAIL "Credential Manager" "Модуль" "BRAVO_CREDENTIALS.ps1 не знайдено"
        } else {
            . $credentialSettings.HelperPath
            try {
                $institutionImportResults = @(Import-BRAVOInstitutionSettings `
                    -CredentialSettings $credentialSettings `
                    -BravoSettings $bravoSettings)
                foreach ($institutionResult in $institutionImportResults) {
                    $sourceStatus = if (
                        $institutionResult.Source -eq "CredentialManager"
                    ) {
                        "PASS"
                    } else {
                        "WARN"
                    }
                    Add-DryRunResult $sourceStatus "Параметри установи" (
                        [string]$institutionResult.Name
                    ) (
                        "джерело=$($institutionResult.Source); target='$($institutionResult.Target)'"
                    )
                }
                Add-DryRunResult PASS "Параметри установи" "Ефективні значення" (
                    "$($bravoSettings.InstitutionName) [$($bravoSettings.InstitutionCode)]; " +
                    "ArchivePrefix=$($bravoSettings.ArchivePrefix)"
                )
            } catch {
                Add-DryRunResult FAIL "Параметри установи" "Застосування" $_.Exception.Message
            }
            $requiredCredentials = @(Get-RequiredCredentialDescriptors)
            foreach ($descriptor in $requiredCredentials) {
                try {
                    $secret = Get-BRAVOCredentialSecret -Target $descriptor.Target
                    if ([string]::IsNullOrWhiteSpace($secret)) {
                        Add-DryRunResult FAIL "Credential Manager" $descriptor.Name (
                            "запис '$($descriptor.Target)' відсутній або порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
                        )
                    } else {
                        $credentialValues[$descriptor.Kind] = $secret
                        Add-DryRunResult PASS "Credential Manager" $descriptor.Name (
                            "запис '$($descriptor.Target)' доступний для поточного облікового запису"
                        )
                    }
                } catch {
                    Add-DryRunResult FAIL "Credential Manager" $descriptor.Name $_.Exception.Message
                }
            }
        }
    } else {
        Add-DryRunResult WARN "Credential Manager" "Перевірка" "пропущено параметром -SkipCredentials"
    }

    $sftpRequired = $sftpConfigured
    if ($sftpRequired) {
        Add-DryRunResult PLAN "SFTP" "Передача" "upload/synchronize не запускалися"
        if ($TestAccess -and $credentialValues.SFTPLogin -and $credentialValues.SFTPPassword) {
            try {
                $detail = Test-SftpReadOnlyAccess `
                    -Login ([string]$credentialValues.SFTPLogin) `
                    -Password ([string]$credentialValues.SFTPPassword)
                Add-DryRunResult PASS "SFTP" "Read-only доступ" $detail
            } catch {
                Add-DryRunResult FAIL "SFTP" "Read-only доступ" $_.Exception.Message
            }
        } elseif (-not $TestAccess) {
            Add-DryRunResult WARN "SFTP" "Read-only доступ" "не перевірявся; використайте -TestAccess"
        }
    }

    if (Test-SettingEnabled $componentSettings.SMB.ArchiveCopy) {
        $smbRoot = if (-not [string]::IsNullOrWhiteSpace([string]$smbSettings.RootPath)) {
            [string]$smbSettings.RootPath
        } else {
            [string]$networkCopyConfig.NetworkPath
        }
        Add-DryRunResult PLAN "SMB" "Копіювання" "копіювання до '$smbRoot' не запускалося"
        if ($TestAccess -and $credentialValues.SMBLogin -and $credentialValues.SMBPassword) {
            try {
                $detail = Test-SmbReadOnlyAccess `
                    -RootPath $smbRoot `
                    -Login ([string]$credentialValues.SMBLogin) `
                    -Password ([string]$credentialValues.SMBPassword)
                Add-DryRunResult PASS "SMB" "Read-only доступ" $detail
            } catch {
                Add-DryRunResult FAIL "SMB" "Read-only доступ" $_.Exception.Message
            }
        } elseif (-not $TestAccess) {
            Add-DryRunResult WARN "SMB" "Read-only доступ" "не перевірявся; використайте -TestAccess"
        }
    }

    if ($null -ne $schedulerSettings -and $null -ne $schedulerSettings.Backup) {
        $taskFolder = $null
        $taskServiceError = $null
        try {
            $taskService = New-Object -ComObject "Schedule.Service"
            $taskService.Connect()
            $taskPath = ([string]$schedulerSettings.TaskPath).TrimEnd("\")
            if ([string]::IsNullOrWhiteSpace($taskPath)) {
                $taskPath = "\"
            }
            $taskFolder = $taskService.GetFolder($taskPath)
        } catch {
            $taskServiceError = $_.Exception.Message
        }

        foreach ($taskName in @("Backup", "Maintenance", "Health")) {
            $task = $schedulerSettings[$taskName]
            if ($null -eq $task) {
                continue
            }
            $enabledText = if (Test-SettingEnabled $task.Enabled) { "увімкнено" } else { "вимкнено" }
            $timeText = if ($taskName -eq "Health") {
                "$($task.StartAt), кожні $($task.RepeatEveryMinutes) хв."
            } else {
                [string]$task.DailyAt
            }
            Add-DryRunResult PLAN "Планувальник" $taskName (
                "$enabledText; $($schedulerSettings.TaskPath)$($task.TaskName); $timeText; запуск від $($schedulerSettings.RunAsUser)"
            )

            if (Test-SettingEnabled $task.Enabled) {
                $registeredTask = $null
                if ($null -ne $taskFolder) {
                    try {
                        $registeredTask = $taskFolder.GetTask([string]$task.TaskName)
                    } catch {
                        $registeredTask = $null
                    }
                }
                if ($null -ne $registeredTask) {
                    $registeredState = switch ([int]$registeredTask.State) {
                        1 { "Disabled" }
                        2 { "Queued" }
                        3 { "Ready" }
                        4 { "Running" }
                        default { "Unknown" }
                    }
                    Add-DryRunResult PASS "Планувальник" "$taskName registration" (
                        "завдання зареєстровано; state=$registeredState; enabled=$($registeredTask.Enabled)"
                    )
                } else {
                    $missingStatus = if ($RequireScheduledTasks) { "FAIL" } else { "WARN" }
                    $missingDetail = if ($taskServiceError) {
                        "стан не вдалося прочитати: $taskServiceError"
                    } else {
                        "увімкнене в config завдання ще не зареєстровано"
                    }
                    Add-DryRunResult $missingStatus "Планувальник" "$taskName registration" $missingDetail
                }
            }
        }
    } else {
        Add-DryRunResult WARN "Планувальник" "Конфігурація" (
            "у цьому config немає повної schedulerSettings; інсталяція BRAVO_TASKS_INSTALL.ps1 недоступна"
        )
    }

    if ($TestAccess) {
        foreach ($webhook in @($requiredCredentials | Where-Object { $_.Kind -eq "Webhook" })) {
            $webhookValue = [string]$credentialValues.Webhook
            try {
                $uri = New-Object Uri($webhookValue)
                if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne "https") {
                    throw "webhook повинен бути абсолютним HTTPS URL"
                }
                [void](Test-TcpPort -HostName $uri.DnsSafeHost -Port 443)
                Add-DryRunResult PASS "Сповіщення" $webhook.Name (
                    "$($uri.DnsSafeHost):443 доступний; повідомлення не надсилалося"
                )
            } catch {
                Add-DryRunResult FAIL "Сповіщення" $webhook.Name $_.Exception.Message
            }
        }
    }

    if ($SendTestNotification) {
        $notificationMode = ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant()
        $notificationProvider = ([string]$bravoSettings.NotificationProvider).Trim().ToLowerInvariant()
        if ($notificationMode -eq "none") {
            Add-DryRunResult FAIL "Сповіщення" "Тестове повідомлення" (
                "NotificationMode=none; webhook не налаштований як активний компонент"
            )
        } elseif ([string]::IsNullOrWhiteSpace([string]$credentialValues.Webhook)) {
            Add-DryRunResult FAIL "Сповіщення" "Тестове повідомлення" (
                "webhook не вдалося прочитати з Credential Manager"
            )
        } else {
            try {
                $sendResult = Send-TestWebhookNotification `
                    -Provider $notificationProvider `
                    -WebhookUrl ([string]$credentialValues.Webhook) `
                    -ConfigFileName (Split-Path $resolvedConfigPath -Leaf)
                Add-DryRunResult PASS "Сповіщення" "Тестове повідомлення" $sendResult
            } catch {
                Add-DryRunResult FAIL "Сповіщення" "Тестове повідомлення" $_.Exception.Message
            }
        }
    }
} catch {
    Add-DryRunResult FAIL "Dry-run" "Фатальна помилка" $_.Exception.Message
}

Write-DryRunOutput
$failureCount = @($script:dryRunResults | Where-Object { $_.Status -eq "FAIL" }).Count
if ($failureCount -gt 0) {
    Complete-BRAVOHelperLog -ExitCode 1
}
Complete-BRAVOHelperLog -ExitCode 0
