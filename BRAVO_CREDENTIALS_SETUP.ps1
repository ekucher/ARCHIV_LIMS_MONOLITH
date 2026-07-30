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
        "Archive",
        "Institution",
        "BRAVO_7Z_PASSWORD",
        "BRAVO_SFTP_LOGIN",
        "BRAVO_SFTP_PASSWORD",
        "BRAVO_SMB_LOGIN",
        "BRAVO_SMB_PASSWORD",
        "BRAVO_SLACK_URL",
        "BRAVO_DISCORD_URL",
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
$helperLoggingPath = Join-Path $PSScriptRoot "BRAVO_HELPER_LOGGING.ps1"
. $helperLoggingPath
$null = Start-BRAVOHelperLog `
    -ScriptPath $PSCommandPath `
    -ConfigPath $ConfigPath `
    -QuietConsole:$protectedWorkerMode

$interactiveMenuRequested = (
    -not $PSBoundParameters.ContainsKey("Action") -and
    -not $PSBoundParameters.ContainsKey("Component") -and
    [string]::IsNullOrWhiteSpace($ProtectedPayloadPath)
)
$storeForWasSpecified = $PSBoundParameters.ContainsKey("StoreFor")

$bravoScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Path $PSCommandPath -Parent
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

$compatibilityModulePath = Join-Path $bravoScriptDirectory "BRAVO_COMPATIBILITY.ps1"
if (-not (Test-Path -LiteralPath $compatibilityModulePath -PathType Leaf)) {
    Write-Error "Не знайдено модуль сумісності: $compatibilityModulePath"
    Complete-BRAVOHelperLog -ExitCode 1
}
try {
    . $compatibilityModulePath
} catch {
    Write-Error "Помилка сумісності: $($_.Exception.Message)"
    Complete-BRAVOHelperLog -ExitCode 1
}
if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
    Write-Warning $BRAVOPowerShellUpdate.Message
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsSystemIdentity {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18"
}

function Import-BRAVOConfiguration {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Файл конфігурації не знайдено: $Path"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $root = Split-Path -Path $resolvedPath -Parent
    $text = [IO.File]::ReadAllText($resolvedPath, [Text.Encoding]::UTF8)
    & ([scriptblock]::Create($text)) -ConfigRoot $root

    if ($null -eq $credentialSettings -or
        [string]::IsNullOrWhiteSpace([string]$credentialSettings.HelperPath) -or
        -not (Test-Path -LiteralPath $credentialSettings.HelperPath -PathType Leaf)) {
        throw "Не знайдено BRAVO_CREDENTIALS.ps1: $($credentialSettings.HelperPath)"
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

                $sftpRequired = [bool]$componentSettings.SFTP.ArchiveUpload -or
                    [bool]$componentSettings.Synchronization.BAZASFTP -or
                    [bool]$backupMonitoring.SFTP.Enabled
                if ($sftpRequired -and -not $resolved.Contains("SFTP")) {
                    [void]$resolved.Add("SFTP")
                }

                $smbRequired = [bool]$componentSettings.SMB.ArchiveCopy
                if ($smbRequired -and -not $resolved.Contains("SMB")) {
                    [void]$resolved.Add("SMB")
                }

                $notificationMode = ([string]$bravoSettings.NotificationMode).ToLowerInvariant()
                if ($notificationMode -ne "none") {
                    $configuredProvider = ([string]$bravoSettings.NotificationProvider).ToLowerInvariant()
                    $providerComponent = if ($configuredProvider -eq "slack") {
                        "Slack"
                    } else {
                        "Discord"
                    }
                    if (-not $resolved.Contains($providerComponent)) {
                        [void]$resolved.Add($providerComponent)
                    }
                }
            }
            "All" {
                $allNames = @("Archive", "SFTP", "SMB", "Slack", "Discord")
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
        "Slack" { return $(if ($credentialSettings.Targets.SlackWebhook) { [string]$credentialSettings.Targets.SlackWebhook } else { "BRAVO_SLACK_URL" }) }
        "Discord" { return $(if ($credentialSettings.Targets.DiscordWebhook) { [string]$credentialSettings.Targets.DiscordWebhook } else { "BRAVO_DISCORD_URL" }) }
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
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SLACK_URL"
                    Target = Get-CredentialTarget -Name "Slack"
                    Prompt = "Slack webhook URL"
                })
            }
            "Discord" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_DISCORD_URL"
                    Target = Get-CredentialTarget -Name "Discord"
                    Prompt = "Discord webhook URL"
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
            "BRAVO_SLACK_URL" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_SLACK_URL"
                    Target = Get-CredentialTarget -Name "Slack"
                    Prompt = "Slack webhook URL"
                })
            }
            "BRAVO_DISCORD_URL" {
                [void]$descriptors.Add([pscustomobject]@{
                    Component = "BRAVO_DISCORD_URL"
                    Target = Get-CredentialTarget -Name "Discord"
                    Prompt = "Discord webhook URL"
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
    param([string[]]$Names)

    $entries = New-Object System.Collections.ArrayList
    foreach ($descriptor in @(Get-CredentialDescriptors -Names $Names)) {
        if ([string]::IsNullOrWhiteSpace([string]$descriptor.Target)) {
            throw "Для $($descriptor.Component) не налаштовано назву запису Credential Manager"
        }

        $secret = if ([string]$descriptor.InputMode -eq "Text") {
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
        [pscustomobject]@{ Number = 14; Value = "BRAVO_SLACK_URL"; Label = "BRAVO_SLACK_URL" },
        [pscustomobject]@{ Number = 15; Value = "BRAVO_DISCORD_URL"; Label = "BRAVO_DISCORD_URL" },
        [pscustomobject]@{ Number = 16; Value = "BRAVO_INSTITUTION_NAME"; Label = "BRAVO_INSTITUTION_NAME" },
        [pscustomobject]@{ Number = 17; Value = "BRAVO_INSTITUTION_CODE"; Label = "BRAVO_INSTITUTION_CODE" },
        [pscustomobject]@{ Number = 18; Value = "BRAVO_ARCHIVE_PREFIX"; Label = "BRAVO_ARCHIVE_PREFIX" }
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
                -AllowedValues @(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18)
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
        $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
            "-File `"$PSCommandPath`" -ConfigPath `"$ResolvedConfigPath`" " +
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
    $resolvedConfigPath = Import-BRAVOConfiguration -Path $ConfigPath
    . $credentialSettings.HelperPath

    if (-not [string]::IsNullOrWhiteSpace($ProtectedPayloadPath)) {
        if ([string]::IsNullOrWhiteSpace($ResultPath)) {
            throw "Для worker-режиму не вказано ResultPath"
        }
        Invoke-ProtectedPayloadWorker -PayloadPath $ProtectedPayloadPath -WorkerResultPath $ResultPath
        Complete-BRAVOHelperLog -ExitCode 0
    }

    if ($interactiveMenuRequested) {
        $menuSelection = Show-BRAVOCredentialMenu `
            -InitialStoreFor $StoreFor `
            -AskForStore (-not $storeForWasSpecified)
        if ($null -eq $menuSelection) {
            Write-Host "Роботу завершено без змін." -ForegroundColor Yellow
            Complete-BRAVOHelperLog -ExitCode 0
        }
        $Action = [string]$menuSelection.Action
        $Component = @([string]$menuSelection.Component)
        $StoreFor = [string]$menuSelection.StoreFor
    }

    $requestedComponents = @(Resolve-RequestedComponents)
    if ($requestedComponents.Count -eq 0) {
        Write-Host "Немає секретів, необхідних для увімкнених компонентів." -ForegroundColor Yellow
        Complete-BRAVOHelperLog -ExitCode 0
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
        $elevationArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
            "-ConfigPath `"$resolvedConfigPath`" -Action $Action -StoreFor $StoreFor " +
            "-Component $componentArguments"
        $process = Start-Process `
            -FilePath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -ArgumentList $elevationArguments `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -WindowStyle Normal
        Write-Host "Налаштування Credential Manager завершено з кодом $($process.ExitCode)."
        Complete-BRAVOHelperLog -ExitCode $process.ExitCode
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
            Complete-BRAVOHelperLog -ExitCode 1
        }
        $missingComponents = @(
            $availabilityResults |
                Where-Object { $_.Status -eq "Missing" } |
                Select-Object -ExpandProperty Component -Unique
        )
        if ($missingComponents.Count -eq 0) {
            Write-Host "Усі запитані записи вже наявні. Значення не змінювалися." -ForegroundColor Green
            Complete-BRAVOHelperLog -ExitCode 0
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
        $operationResults = @(Invoke-AsSystem -ResolvedConfigPath $resolvedConfigPath -Operation $Action -Entries $operationEntries)
    } else {
        Write-Host "Сховище для облікового запису: $currentIdentity"
        $operationResults = @(
            Invoke-CredentialOperationsTransactional `
                -Operation $Action `
                -Entries $operationEntries
        )
    }
    Write-OperationResults -Results $operationResults

    if (@($operationResults | Where-Object { $_.Status -in @("Error", "Missing") }).Count -gt 0) {
        Complete-BRAVOHelperLog -ExitCode 1
    }
    Complete-BRAVOHelperLog -ExitCode 0
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
    Complete-BRAVOHelperLog -ExitCode 1
}
