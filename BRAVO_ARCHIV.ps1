[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SyncBAZA,
    [switch]$HealthCheckOnly,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause
)

$modulePath = Join-Path $PSScriptRoot 'modules\BRAVO.Archive\BRAVO.Archive.psd1'
Import-Module -Name $modulePath -ErrorAction Stop
$parameters = @{
    ConfigPath = $ConfigPath; SyncBAZA = $SyncBAZA; HealthCheckOnly = $HealthCheckOnly
    ForceNotification = $ForceNotification; NotifyOnSuccess = $NotifyOnSuccess
    NoSlack = $NoSlack; SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning
    NoPause = $NoPause; RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}
exit (Invoke-BRAVOArchiveEntrypoint -Parameters $parameters)
