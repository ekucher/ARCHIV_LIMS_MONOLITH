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
Import-Module -Name $modulePath -ErrorAction Stop
$parameters = @{
    ForceRestore = $ForceRestore; RunMissedRestoreOnly = $RunMissedRestoreOnly
    DisableSizeCheck = $DisableSizeCheck; EnableAllSlack = $EnableAllSlack
    DisableAllSlack = $DisableAllSlack; ConfigPath = $ConfigPath
    RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}
if ($PSBoundParameters.ContainsKey('AutoShutdown')) { $parameters.AutoShutdown = $AutoShutdown }
if ($PSBoundParameters.ContainsKey('ArchiveAfterMaintenance')) { $parameters.ArchiveAfterMaintenance = $ArchiveAfterMaintenance }
exit (Invoke-BRAVOMaintenanceEntrypoint -Parameters $parameters)
