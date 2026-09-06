$script:runtimePath = Join-Path $PSScriptRoot 'BRAVO.Health.Runtime.ps1'
if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
    throw "BRAVO Health runtime not found: $script:runtimePath"
}

function Invoke-BRAVOHealthEntrypoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)

    # Публічна межа module API (та сама компенсація, що в
    # Invoke-BRAVOHealthCheck): зовнішній викликач, який передав явний
    # непорожній ConfigPath, але не знає нового ключа наміру, зберігає
    # explicit-семантику (fail-closed на відсутньому файлі). Root
    # entrypoints завжди кладуть ConfigPathWasExplicit у splat самі.
    if (-not $Parameters.ContainsKey('ConfigPathWasExplicit') -and
        $Parameters.ContainsKey('ConfigPath') -and
        -not [string]::IsNullOrWhiteSpace([string]$Parameters['ConfigPath'])) {
        $Parameters = $Parameters.Clone()
        $Parameters['ConfigPathWasExplicit'] = $true
    }

    try {
        & $script:runtimePath @Parameters | Out-Host
        return [int]$LASTEXITCODE
    } catch {
        # Той самий захист, що й у BRAVO.Archive.psm1: спрацьовує лише на
        # непередбаченій помилці, яку runtime не встиг обробити власним exit.
        Write-Error "Неочікувана помилка runtime Health: $($_.Exception.Message)"
        return 90
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
        [string]$EntryScriptPath,
        # ONE synchronization, ONE SyncResult (safety-review): якщо Archive
        # щойно виконав BAZA sync у ЦЬОМУ прогоні, Health переоцінює вже
        # готовий результат замість повторної синхронізації. Ключі —
        # 'BAZA_APP'/'BAZA_WWW', значення — SyncResult з BRAVO.BazaSync.
        [hashtable]$BazaSyncResults,
        # Намір оператора з СПРАВЖНЬОЇ межі виклику (root entrypoint
        # Archive) — прокидається в runtime без повторного вгадування.
        # Якщо викликач НЕ передав прапорець, намір виводиться з ЙОГО
        # власного виклику: це публічний module API, і програмний виклик
        # із явним -ConfigPath зберігає explicit-семантику (fail-closed на
        # відсутньому файлі) без знання про новий параметр — сумісність
        # контракту. Archive передає прапорець явно (AUTO -> $false).
        # Оголошений ОСТАННІМ: усі параметри, що існували до цього фіксу,
        # зберігають свої позиції для legacy positional-викликів.
        [bool]$ConfigPathWasExplicit = $false
    )

    if (-not $PSBoundParameters.ContainsKey('ConfigPathWasExplicit')) {
        $ConfigPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
            -not [string]::IsNullOrWhiteSpace($ConfigPath)
    }
    if ([string]::IsNullOrWhiteSpace($EntryScriptPath)) {
        $EntryScriptPath = Join-Path $RuntimeRoot 'BRAVO_HEALTH.ps1'
    }
    $runtimeParameters = @{
        ConfigPath = $ConfigPath
        ConfigPathWasExplicit = $ConfigPathWasExplicit
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
        # -SuppressHeader: цей шлях — виключно вбудований виклик Archive
        # (крок "Перевірка резервних копій"). Самостійний запуск
        # BRAVO_HEALTH.ps1 не проходить через Invoke-BRAVOHealthCheck
        # взагалі (він викликає Invoke-BRAVOHealth напряму, без цього
        # параметра) — заголовок там лишається.
        return Invoke-BRAVOHealth `
            -ConfigPath $ConfigPath `
            -ForceNotification:$ForceNotification `
            -NotifyOnSuccess:$NotifyOnSuccess `
            -NoSlack:$NoSlack `
            -BazaSyncResults $BazaSyncResults `
            -SkipIfBackupTaskRunning:$SkipIfBackupTaskRunning `
            -SuppressHeader
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
