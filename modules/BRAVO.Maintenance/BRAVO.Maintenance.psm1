$script:runtimePath = Join-Path $PSScriptRoot 'BRAVO.Maintenance.Runtime.ps1'
if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
    throw "BRAVO Maintenance runtime not found: $script:runtimePath"
}

function Invoke-BRAVOMaintenanceEntrypoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)

    & $script:runtimePath @Parameters | Out-Host
    return [int]$LASTEXITCODE
}

Export-ModuleMember -Function 'Invoke-BRAVOMaintenanceEntrypoint'
