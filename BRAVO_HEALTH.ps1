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
