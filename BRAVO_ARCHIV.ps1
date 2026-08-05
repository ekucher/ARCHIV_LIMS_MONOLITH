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

# Аудит P2: цілісність комплекту перевіряється ДО Import-Module —
# інакше довелося б виконати той самий код, який ще не перевірено.
# Guard самодостатній (лише .NET, без модулів BRAVO) саме тому.
# Режим типово Enforce; BRAVO_RUNTIME_INTEGRITY_MODE=Warn — аварійний
# шлях відновлення, задокументований у SECURITY.md. Він не додає нового
# вектора атаки: хто може змінити змінні середовища запланованого
# завдання, той уже має права підмінити й сам маніфест.
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

    # Маніфест підтверджує, що файли комплекту ті самі. BRAVO.config до
    # нього навмисно не входить (він різний на кожному сервері), тому
    # перемикачі безпеки в ньому перевіряються окремо — інакше рядок у
    # конфігурації лишався б найдешевшим способом тихо вимкнути захист.
    $securitySettings = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath (Join-Path $PSScriptRoot 'BRAVO.config') `
        -Mode $runtimeIntegrityMode
    if (-not $securitySettings.IsValid) {
        $securityColor = if ($securitySettings.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $securitySettings.Message -ForegroundColor $securityColor
        if ($securitySettings.ShouldBlock) { exit 34 }
    }

    # Старіший комплект проходить усі перевірки вище — разом із
    # вразливостями, які відтоді закрили. Найпростіший спосіб вимкнути
    # Enforce — не зламати його, а розгорнути версію, де його не було.
    $versionState = Test-BRAVOVersionDowngrade `
        -RuntimeRoot $PSScriptRoot `
        -StatePath (Join-Path $PSScriptRoot 'LOGS\BRAVO_VERSION_STATE.json') `
        -Mode $runtimeIntegrityMode
    if (-not $versionState.IsValid) {
        $versionColor = if ($versionState.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $versionState.Message -ForegroundColor $versionColor
        if ($versionState.ShouldBlock) { exit 35 }
    }
} else {
    Write-Host "КРИТИЧНА ПОМИЛКА: відсутній BRAVO_RUNTIME_GUARD.ps1 — цілісність комплекту не підтверджена" -ForegroundColor Red
    exit 33
}

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
