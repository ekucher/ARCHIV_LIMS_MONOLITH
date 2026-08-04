$script:runtimePath = Join-Path $PSScriptRoot 'BRAVO.Health.Runtime.ps1'
if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
    throw "BRAVO Health runtime not found: $script:runtimePath"
}

function Invoke-BRAVOHealthEntrypoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)

    try {
        & $script:runtimePath @Parameters | Out-Host
        return [int]$LASTEXITCODE
    } catch {
        # Той самий захист, що й у BRAVO.Archive.psm1: спрацьовує лише на
        # непередбаченій помилці, яку runtime не встиг обробити власним exit.
        Write-Error "Неочікувана помилка runtime Health: $($_.Exception.Message)"
        return 1
    }
}

function Invoke-BRAVOHealthCheck {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$ForceNotification,
        [switch]$NotifyOnSuccess,
        [switch]$NoSlack,
        [switch]$SkipIfBackupTaskRunning,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [string]$EntryScriptPath
    )

    if ([string]::IsNullOrWhiteSpace($EntryScriptPath)) {
        $EntryScriptPath = Join-Path $RuntimeRoot 'BRAVO_HEALTH.ps1'
    }
    $runtimeParameters = @{
        ConfigPath = $ConfigPath
        ForceNotification = $ForceNotification
        NotifyOnSuccess = $NotifyOnSuccess
        NoSlack = $NoSlack
        SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning
        NoPause = $true
        RuntimeRoot = $RuntimeRoot
        EntryScriptPath = $EntryScriptPath
    }

    try {
        # Dot-source only the private runtime definition. Its invocation guard
        # does not execute or exit when InvocationName is '.'.
        . $script:runtimePath @runtimeParameters
        return Invoke-BRAVOHealth `
            -ConfigPath $ConfigPath `
            -ForceNotification:$ForceNotification `
            -NotifyOnSuccess:$NotifyOnSuccess `
            -NoSlack:$NoSlack `
            -SkipIfBackupTaskRunning:$SkipIfBackupTaskRunning
    } finally {
        # Programmatic calls run in this module's persistent script scope.
        # Never retain plaintext SFTP credentials or an SMB credential there.
        $script:Login = $null
        $script:resolvedSftpHost = $null
        $script:sftpUrl = $null
        if ($null -ne $script:smbCredential) {
            try {
                if ($null -ne $script:smbCredential.Password) {
                    $script:smbCredential.Password.Dispose()
                }
            } catch {
                # Clearing the reference below is mandatory even if disposal
                # is not supported by the host's SecureString implementation.
            }
        }
        $script:smbCredential = $null
    }
}

Export-ModuleMember -Function @(
    'Invoke-BRAVOHealthEntrypoint',
    'Invoke-BRAVOHealthCheck'
)
