[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$GenerationId,
    [ValidateSet("MODEL", "BLOG", "BRAVOEXCH", "All")]
    [string]$Component = "All",
    [ValidateSet("OutOfPlace", "InPlace")]
    [string]$Mode = "OutOfPlace",
    [string]$TargetPath,
    [ValidateSet("Local", "SFTP")]
    [string]$Source = "Local",
    [string]$StagingPath,
    [switch]$ListGenerations,
    [switch]$Force,
    [switch]$SkipHealthCheck,
    [int]$TimeoutSeconds = 0,
    [switch]$NoPause
)

# Пауза перед закриттям вікна тут навмисно самодостатня (без BRAVO.Console)
# — з тієї ж причини, що й guard нижче: цілісність ще не підтверджена,
# тому нічого зі свого коду довіряти зарано. Дублюється ідентично в
# BRAVO_ARCHIV.ps1, BRAVO_HEALTH.ps1 і BRAVO_MAINTENANCE.ps1, як і сам
# guard-блок.
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

# Цілісність комплекту перевіряється ДО Import-Module — інакше довелося б
# виконати той самий код, який ще не перевірено. Guard самодостатній (лише
# .NET, без модулів BRAVO) саме тому. Режим типово Enforce;
# BRAVO_RUNTIME_INTEGRITY_MODE=Warn — аварійний шлях відновлення,
# задокументований у SECURITY.md.

# P0 Configuration Foundation: свідомий намір оператора фіксується ТУТ —
# на єдиній справжній межі виклику оператора — ДО auto-деривації нижче, і
# передається в runtime явним параметром: після реасайну $ConfigPath на
# effective-шлях жодна пізніша перевірка $PSBoundParameters відновити
# намір уже не може.
$configPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)

# Effective ConfigPath визначається ОДИН раз, до будь-якої перевірки, і далі
# використовується всюди: guard, завантажувач, дочірні скрипти.
$effectiveConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $PSScriptRoot 'BRAVO.config'
} else {
    [Environment]::ExpandEnvironmentVariables($ConfigPath)
}
try {
    $effectiveConfigPath = [System.IO.Path]::GetFullPath($effectiveConfigPath)
} catch {
    # Некоректний шлях НЕ обробляється тут виходом: перевірка цілісності
    # комплекту (код 33) мусить лишатись найпершим бар'єром. Далі це
    # значення відхилить або сам guard, або завантажувач (код 30).
    $effectiveConfigPath = [string]$effectiveConfigPath
}
$ConfigPath = $effectiveConfigPath

# Параметри runtime фіксуються ДО dot-source guard: BRAVO_RUNTIME_GUARD.ps1
# має власний top-level param-блок ($RuntimeRoot/$ManifestPath/$Mode='Enforce'),
# який при dot-source виконується в НАШОМУ скоупі й перезаписує однойменні
# змінні — зокрема $Mode цього скрипта значенням 'Enforce'. Інші entrypoint
# (ARCHIV/HEALTH/MAINTENANCE) не мають параметрів із такими іменами, тому
# колізія проявляється лише тут.
$parameters = @{
    ConfigPath = $ConfigPath; ConfigPathWasExplicit = $configPathWasExplicit
    GenerationId = $GenerationId; Component = $Component
    Mode = $Mode; TargetPath = $TargetPath; Source = $Source; StagingPath = $StagingPath
    ListGenerations = $ListGenerations; Force = $Force; SkipHealthCheck = $SkipHealthCheck
    TimeoutSeconds = $TimeoutSeconds
    NoPause = $NoPause; RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}

$runtimeGuardPath = Join-Path $PSScriptRoot 'BRAVO_RUNTIME_GUARD.ps1'
if (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf) {
    # Fail-closed: guard не завантажився — не запускаємось (та сама
    # поведінка, що в BRAVO_ARCHIV.ps1).
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
    # перемикачі безпеки в ньому перевіряються окремо.
    $securitySettings = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath $effectiveConfigPath `
        -Mode $runtimeIntegrityMode
    if (-not $securitySettings.IsValid) {
        $securityColor = if ($securitySettings.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $securitySettings.Message -ForegroundColor $securityColor
        if ($securitySettings.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 34 }
    }

    # Старіший комплект проходить усі перевірки вище — разом із
    # вразливостями, які відтоді закрили.
    $versionState = Test-BRAVOVersionDowngrade `
        -RuntimeRoot $PSScriptRoot `
        -StatePath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\State\BRAVO_VERSION_STATE.json') `
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

$modulePath = Join-Path $PSScriptRoot 'modules\BRAVO.DataRestore\BRAVO.DataRestore.psd1'
try {
    Import-Module -Name $modulePath -ErrorAction Stop
} catch {
    # Пошкоджене/часткове розгортання не повинно завершувати процес
    # довільним кодом виключення PowerShell — контракт кодів завершення
    # (BRAVO.ExitCodes) обіцяє категоризований результат навіть у цьому
    # сценарії. 90 = InternalError, хардкод навмисний: сам модуль
    # BRAVO.ExitCodes може бути недоступний саме через цю ж причину.
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модуль $modulePath : $($_.Exception.Message)" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 90
}
exit (Invoke-BRAVODataRestoreEntrypoint -Parameters $parameters)
