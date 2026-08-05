[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause
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

$modulePath = Join-Path $PSScriptRoot 'modules\BRAVO.Health\BRAVO.Health.psd1'
try {
    Import-Module -Name $modulePath -ErrorAction Stop
} catch {
    # Див. коментар у BRAVO_ARCHIV.ps1 — контракт кодів завершення має
    # діяти навіть при пошкодженому розгортанні. 90 = InternalError.
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модуль $modulePath : $($_.Exception.Message)" -ForegroundColor Red
    exit 90
}
$parameters = @{
    ConfigPath = $ConfigPath; ForceNotification = $ForceNotification
    NotifyOnSuccess = $NotifyOnSuccess; NoSlack = $NoSlack
    SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning; NoPause = $NoPause
    RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}
exit (Invoke-BRAVOHealthEntrypoint -Parameters $parameters)
