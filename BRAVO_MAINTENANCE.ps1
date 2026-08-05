[CmdletBinding()]
param(
    [switch]$ForceRestore,
    [switch]$RunMissedRestoreOnly,
    [switch]$DisableSizeCheck,
    [switch]$EnableAllSlack,
    [switch]$DisableAllSlack,
    [ValidateSet('on', 'off')][string]$AutoShutdown,
    [Alias('ArchivLims')][ValidateSet('on', 'off')][string]$ArchiveAfterMaintenance,
    [string]$ConfigPath
)

# Аудит P2 — див. коментар у BRAVO_ARCHIV.ps1: цілісність комплекту
# перевіряється до Import-Module самодостатнім guard-ом.
$runtimeGuardPath = Join-Path $PSScriptRoot 'BRAVO_RUNTIME_GUARD.ps1'
if (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf) {
    . $runtimeGuardPath
    $runtimeIntegrityMode = if ($env:BRAVO_RUNTIME_INTEGRITY_MODE -eq 'Warn') { 'Warn' } else { 'Enforce' }
    $runtimeIntegrity = Test-BRAVORuntimeManifestIntegrity `
        -RuntimeRoot $PSScriptRoot `
        -ManifestPath (Join-Path $PSScriptRoot 'RUNTIME_MANIFEST.json') `
        -Mode $runtimeIntegrityMode
    if (-not $runtimeIntegrity.IsValid) {
        Write-Host $runtimeIntegrity.Message -ForegroundColor Red
        if ($runtimeIntegrity.ShouldBlock) { exit 33 }
    }
} else {
    Write-Host "КРИТИЧНА ПОМИЛКА: відсутній BRAVO_RUNTIME_GUARD.ps1 — цілісність комплекту не підтверджена" -ForegroundColor Red
    exit 33
}

$modulePath = Join-Path $PSScriptRoot 'modules\BRAVO.Maintenance\BRAVO.Maintenance.psd1'
try {
    Import-Module -Name $modulePath -ErrorAction Stop
} catch {
    # Див. коментар у BRAVO_ARCHIV.ps1 — контракт кодів завершення має
    # діяти навіть при пошкодженому розгортанні. 90 = InternalError.
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модуль $modulePath : $($_.Exception.Message)" -ForegroundColor Red
    exit 90
}
$parameters = @{
    ForceRestore = $ForceRestore; RunMissedRestoreOnly = $RunMissedRestoreOnly
    DisableSizeCheck = $DisableSizeCheck; EnableAllSlack = $EnableAllSlack
    DisableAllSlack = $DisableAllSlack; ConfigPath = $ConfigPath
    RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}
if ($PSBoundParameters.ContainsKey('AutoShutdown')) { $parameters.AutoShutdown = $AutoShutdown }
if ($PSBoundParameters.ContainsKey('ArchiveAfterMaintenance')) { $parameters.ArchiveAfterMaintenance = $ArchiveAfterMaintenance }
exit (Invoke-BRAVOMaintenanceEntrypoint -Parameters $parameters)
