$script:runtimePath = Join-Path $PSScriptRoot 'BRAVO.Archive.Runtime.ps1'
if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
    throw "BRAVO Archive runtime not found: $script:runtimePath"
}

function Invoke-BRAVOArchiveEntrypoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)

    try {
        & $script:runtimePath @Parameters | Out-Host
        return [int]$LASTEXITCODE
    } catch {
        # Runtime завершується явним Exit у штатних сценаріях (успіх і
        # оброблена помилка), тому цей catch спрацьовує лише на справді
        # непередбаченій помилці, кинутій повторно з зовнішнього try/catch
        # runtime. Без цієї обгортки виняток проривався б крізь return і
        # процес завершувався б генеричним кодом самого PowerShell, а не
        # керованим значенням.
        Write-Error "Неочікувана помилка runtime Archive: $($_.Exception.Message)"
        return 90
    }
}

Export-ModuleMember -Function 'Invoke-BRAVOArchiveEntrypoint'
