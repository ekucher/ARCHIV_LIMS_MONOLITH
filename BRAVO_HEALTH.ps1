[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause
)

$modulePath = Join-Path $PSScriptRoot 'modules\BRAVO.Health\BRAVO.Health.psd1'
Import-Module -Name $modulePath -ErrorAction Stop
$parameters = @{
    ConfigPath = $ConfigPath; ForceNotification = $ForceNotification
    NotifyOnSuccess = $NotifyOnSuccess; NoSlack = $NoSlack
    SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning; NoPause = $NoPause
    RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}
exit (Invoke-BRAVOHealthEntrypoint -Parameters $parameters)
