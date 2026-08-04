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
