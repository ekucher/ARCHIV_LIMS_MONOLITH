$script:runtimePath = Join-Path $PSScriptRoot 'BRAVO.Maintenance.Runtime.ps1'
if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
    throw "BRAVO Maintenance runtime not found: $script:runtimePath"
}

function Invoke-BRAVOMaintenanceEntrypoint {
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
        # непередбаченій помилці, яку runtime не встиг обробити власним Exit.
        Write-Error "Неочікувана помилка runtime Maintenance: $($_.Exception.Message)"
        return 90
    }
}

Export-ModuleMember -Function 'Invoke-BRAVOMaintenanceEntrypoint'
