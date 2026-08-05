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

# Пауза перед закриттям вікна тут навмисно самодостатня (без BRAVO.Console)
# — з тієї ж причини, що й guard нижче: цілісність ще не підтверджена,
# тому нічого зі свого коду довіряти зарано. Дублюється ідентично в
# BRAVO_HEALTH.ps1 і BRAVO_MAINTENANCE.ps1, як і сам guard-блок.
function Wait-BRAVOEarlyManualExit {
    param([switch]$NoPause)
    if ($NoPause) { return }
    try {
        if (-not [Environment]::UserInteractive) { return }
        if ([Console]::IsInputRedirected) { return }
    } catch {
        return
    }
    Write-Host ""
    Write-Host "Натиснiть будь-яку клавiшу для закриття вiкна..." -ForegroundColor Cyan
    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        try {
            [void](Read-Host)
        } catch {
            # Немає жодного способу почекати на ввід (нетиповий хост) — це не привід завершити скрипт помилкою.
        }
    }
}

# Аудит P2: цілісність комплекту перевіряється ДО Import-Module —
# інакше довелося б виконати той самий код, який ще не перевірено.
# Guard самодостатній (лише .NET, без модулів BRAVO) саме тому.
# Режим типово Enforce; BRAVO_RUNTIME_INTEGRITY_MODE=Warn — аварійний
# шлях відновлення, задокументований у SECURITY.md. Він не додає нового
# вектора атаки: хто може змінити змінні середовища запланованого
# завдання, той уже має права підмінити й сам маніфест.
$runtimeGuardPath = Join-Path $PSScriptRoot 'BRAVO_RUNTIME_GUARD.ps1'
if (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf) {
    # Наявності файлу недостатньо: dot-source може не виконатися взагалі —
    # ExecutionPolicy AllSigned без підпису, синтаксична помилка, блокування
    # файлу. Раніше в цьому випадку скрипт мовчки йшов далі, а всі три
    # перевірки нижче падали з CommandNotFound і НЕ зупиняли запуск —
    # тобто найдешевшим способом вимкнути захист було не підібрати хеші, а
    # зробити guard незавантажуваним. Fail-closed: не завантажився — не
    # запускаємось.
    try {
        . $runtimeGuardPath
    } catch {
        Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити BRAVO_RUNTIME_GUARD.ps1: $($_.Exception.Message)" -ForegroundColor Red
        Wait-BRAVOEarlyManualExit -NoPause:$NoPause
        exit 33
    }
    # Окрема перевірка, бо помилка dot-source не завжди переривальна:
    # guard міг «завантажитись» і не оголосити жодної функції.
    foreach ($guardFunction in @(
        'Test-BRAVORuntimeManifestIntegrity',
        'Test-BRAVORuntimeSecuritySettings',
        'Test-BRAVOVersionDowngrade'
    )) {
        if (-not (Get-Command -Name $guardFunction -CommandType Function -ErrorAction SilentlyContinue)) {
            Write-Host "КРИТИЧНА ПОМИЛКА: BRAVO_RUNTIME_GUARD.ps1 не оголосив $guardFunction — цілісність комплекту не підтверджена" -ForegroundColor Red
            Wait-BRAVOEarlyManualExit -NoPause:$NoPause
            exit 33
        }
    }
    $runtimeIntegrityMode = if ($env:BRAVO_RUNTIME_INTEGRITY_MODE -eq 'Warn') { 'Warn' } else { 'Enforce' }
    $runtimeIntegrity = Test-BRAVORuntimeManifestIntegrity `
        -RuntimeRoot $PSScriptRoot `
        -ManifestPath (Join-Path $PSScriptRoot 'RUNTIME_MANIFEST.json') `
        -Mode $runtimeIntegrityMode
    if (-not $runtimeIntegrity.IsValid) {
        Write-Host $runtimeIntegrity.Message -ForegroundColor Red
        if ($runtimeIntegrity.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 33 }
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
        if ($securitySettings.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 34 }
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
        if ($versionState.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 35 }
    }
} else {
    Write-Host "КРИТИЧНА ПОМИЛКА: відсутній BRAVO_RUNTIME_GUARD.ps1 — цілісність комплекту не підтверджена" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
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
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 90
}
$parameters = @{
    ConfigPath = $ConfigPath; SyncBAZA = $SyncBAZA; HealthCheckOnly = $HealthCheckOnly
    ForceNotification = $ForceNotification; NotifyOnSuccess = $NotifyOnSuccess
    NoSlack = $NoSlack; SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning
    NoPause = $NoPause; RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}
exit (Invoke-BRAVOArchiveEntrypoint -Parameters $parameters)
