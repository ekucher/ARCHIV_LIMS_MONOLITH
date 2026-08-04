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
try {
    Import-Module -Name $modulePath -ErrorAction Stop
} catch {
    # Пошкоджене/часткове розгортання (відсутній .psd1 тощо) не повинно
    # завершувати процес довільним кодом виключення PowerShell — контракт
    # кодів завершення (BRAVO.ExitCodes) обіцяє категоризований результат
    # для моніторингу Task Scheduler/Zabbix навіть у цьому сценарії.
    # 90 = InternalError, хардкод навмисний: сам модуль BRAVO.ExitCodes
    # може бути недоступний саме через цю ж причину.
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модуль $modulePath : $($_.Exception.Message)" -ForegroundColor Red
    exit 90
}
$parameters = @{
    ConfigPath = $ConfigPath; SyncBAZA = $SyncBAZA; HealthCheckOnly = $HealthCheckOnly
    ForceNotification = $ForceNotification; NotifyOnSuccess = $NotifyOnSuccess
    NoSlack = $NoSlack; SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning
    NoPause = $NoPause; RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}
exit (Invoke-BRAVOArchiveEntrypoint -Parameters $parameters)
