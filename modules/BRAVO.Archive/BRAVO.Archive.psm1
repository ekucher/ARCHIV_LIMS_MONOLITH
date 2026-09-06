$script:runtimePath = Join-Path $PSScriptRoot 'BRAVO.Archive.Runtime.ps1'
if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
    throw "BRAVO Archive runtime not found: $script:runtimePath"
}

function Invoke-BRAVOArchiveEntrypoint {
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
