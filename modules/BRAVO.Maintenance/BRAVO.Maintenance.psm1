$script:runtimePath = Join-Path $PSScriptRoot 'BRAVO.Maintenance.Runtime.ps1'
if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
    throw "BRAVO Maintenance runtime not found: $script:runtimePath"
}

function Invoke-BRAVOMaintenanceEntrypoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)

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
