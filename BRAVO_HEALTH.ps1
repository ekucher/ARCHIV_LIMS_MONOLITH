[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause
)

# Пауза перед закриттям вікна тут навмисно самодостатня — див. коментар
# у BRAVO_ARCHIV.ps1. Дублюється ідентично в трьох entrypoint-ах, як і
# сам guard-блок нижче.
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

# dev.13: ручний запуск без elevation не мав права запису в D:\BRAVO\LOGS/TEMP
# (акаунт бачив каталоги — їх створив SYSTEM — але не міг у них писати). Ця
# локальна AccessDenied спливала лише глибоко всередині SFTP-етапу й помилково
# ставала "SFTP недоступний". Нижче — рання, чисто функціональна (без побічних
# ефектів, окрім самого self-relaunch) elevation-модель: SYSTEM і вже elevated
# Administrator проходять без змін; ручний non-elevated interactive запуск
# перезапускає себе через UAC; non-interactive non-elevated (щось запустило
# скрипт від імені звичайного акаунта поза Task Scheduler) провалюється
# одразу, без спроби показати UAC.
#
# Кожна функція тестована окремо (BRAVO_SELF_TEST.ps1, Health/Elevation*) із
# синтетичними вхідними даними — жодна не читає WindowsIdentity/консоль сама,
# це робить лише виклик нижче.
function Get-BRAVOHealthElevationState {
    param(
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][bool]$IsAdministratorRole
    )

    # SID, а не ім'я/локалізація — той самий підхід, що вже перевіряє
    # обліковий запис запланованих завдань (Test-BRAVOAccountIdentityEquivalent).
    # SYSTEM (S-1-5-18) технічно й так проходить IsInRole(Administrator) —
    # UAC не розщеплює його токен — але окрема гілка тут явно документує
    # намір "SYSTEM ніколи не бачить UAC" замість покладатись на побічний
    # ефект перевірки ролі.
    if ([string]::Equals($UserSid, 'S-1-5-18', [StringComparison]::OrdinalIgnoreCase)) {
        return 'System'
    }
    if ($IsAdministratorRole) {
        return 'Administrator'
    }
    return 'Standard'
}

function Test-BRAVOHealthManualInteractiveSession {
    param(
        [Parameter(Mandatory = $true)][bool]$UserInteractive,
        [Parameter(Mandatory = $true)][bool]$InputRedirected
    )

    # Той самий сигнал, що вже приймає рішення в Wait-BRAVOEarlyManualExit
    # вище: SYSTEM-завдання Планувальника виконуються в неінтерактивній
    # window station (UserInteractive=$false), а -NonInteractive/перенаправлений
    # stdin теж не повинні відкривати UAC.
    return ($UserInteractive -and -not $InputRedirected)
}

function Get-BRAVOHealthElevationAction {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('System', 'Administrator', 'Standard')]
        [string]$ElevationState,
        [Parameter(Mandatory = $true)][bool]$IsManualInteractiveSession,
        # dev.13 correctness pass: [Environment]::UserInteractive/
        # [Console]::IsInputRedirected НЕ доводять, що powershell.exe
        # отримав -NonInteractive — обидва описують Windows-сесію/stdin, а
        # не сам PowerShell-прапорець. Явний -NonInteractive у власному
        # command line (Test-BRAVOHealthExplicitNonInteractive) перекриває
        # "виглядає interactive" і форсує FailFast.
        [bool]$IsExplicitNonInteractive
    )

    if ($ElevationState -in @('System', 'Administrator')) { return 'Proceed' }
    if ($IsManualInteractiveSession -and -not $IsExplicitNonInteractive) { return 'Relaunch' }
    return 'FailFast'
}

# correctness pass: [Environment]::GetCommandLineArgs() — вбудований
# .NET Framework API (Windows PowerShell 5.1-сумісний, без CIM/WMI) —
# повертає ВЖЕ розпарсений argv поточного процесу (перевірено емпірично:
# ArgumentList Start-Process з лапками округлює одним елементом навіть
# значення з пробілами й навіть коли те значення містить підрядок
# "-NonInteractive" — .NET сам коректно розбирає лапки). Тому власного
# токенізатора не потрібно: приймаємо вже готовий string[] і шукаємо
# ТОЧНИЙ (не substring/-like) токен, щоб не зловити "-NonInteractive"
# усередині значення -ConfigPath чи шляху до файлу.
function Test-BRAVOHealthExplicitNonInteractive {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Argv)

    foreach ($token in $Argv) {
        if ([string]::Equals($token, '-NonInteractive', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# Детерміноване формування командного рядка для self-relaunch — БЕЗ
# $MyInvocation.Line (вразливе до пробілів/лапок і передає лише те, що
# користувач ввів дослівно, а не те, що реально прив'язалося до параметрів).
# Джерело — $PSBoundParameters: лише параметри, які користувач справді
# вказав, кожен свій тип (switch/string) обробляється явно.
function New-BRAVOHealthRelaunchArgumentList {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$BoundParameters,
        # Уже розрезолвлений абсолютний -ConfigPath. Start-Process -Verb RunAs
        # запускає дочірній процес зі своїм робочим каталогом (не завжди
        # той самий, що в батька) — відносний шлях там означав би інший файл.
        [string]$ResolvedConfigPath
    )

    # Start-Process -ArgumentList (string[]) НЕ квотує самостійно елементи,
    # що містять пробіли — перевірено емпірично: "C:\Program Files\..."
    # без лапок розпадається на кілька окремих argv в дочірньому процесі.
    # Тому шлях до скрипта й -ConfigPath беруться в лапки явно тут, а не
    # покладаючись на Start-Process.
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('-NoLogo')
    $arguments.Add('-NoProfile')
    $arguments.Add('-ExecutionPolicy')
    $arguments.Add('Bypass')
    $arguments.Add('-File')
    $arguments.Add('"' + $ScriptPath + '"')

    if (-not [string]::IsNullOrWhiteSpace($ResolvedConfigPath)) {
        $arguments.Add('-ConfigPath')
        $arguments.Add('"' + $ResolvedConfigPath + '"')
    } elseif ($BoundParameters.ContainsKey('ConfigPath') -and
        -not [string]::IsNullOrWhiteSpace([string]$BoundParameters['ConfigPath'])) {
        $arguments.Add('-ConfigPath')
        $arguments.Add('"' + [string]$BoundParameters['ConfigPath'] + '"')
    }

    # Лише реально задані switch-параметри — невказаний -NoPause на
    # батьківському виклику не повинен з'явитися в дочірньому: elevated
    # console тоді поводиться так само, як звичайний ручний запуск
    # (чекає на клавішу), а не мовчки закривається.
    foreach ($switchName in @(
        'ForceNotification', 'NotifyOnSuccess', 'NoSlack',
        'SkipIfBackupTaskRunning', 'NoPause'
    )) {
        if (-not $BoundParameters.ContainsKey($switchName)) { continue }
        $switchValue = $BoundParameters[$switchName]
        $isSet = if ($switchValue -is [System.Management.Automation.SwitchParameter]) {
            $switchValue.IsPresent
        } else {
            [bool]$switchValue
        }
        if ($isSet) { $arguments.Add("-$switchName") }
    }

    return $arguments.ToArray()
}

# Start-Process -Verb RunAs на "Cancel" у діалозі UAC кидає Win32Exception
# з NativeErrorCode 1223 (ERROR_CANCELLED), інколи загорнутий в іншу
# exception. Розпізнаємо це конкретно, щоб показати чітке повідомлення
# замість сирого stack trace.
function Test-BRAVOHealthElevationCancelled {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $currentException = $ErrorRecord.Exception
    while ($null -ne $currentException) {
        if ($currentException -is [System.ComponentModel.Win32Exception] -and
            $currentException.NativeErrorCode -eq 1223) {
            return $true
        }
        $currentException = $currentException.InnerException
    }
    return $false
}

# Аудит P2 — див. коментар у BRAVO_ARCHIV.ps1: цілісність комплекту
# перевіряється до Import-Module самодостатнім guard-ом.

# P0 Configuration Foundation: свідомий намір оператора фіксується ТУТ —
# на єдиній справжній межі виклику оператора — ДО auto-деривації нижче, і
# передається в runtime явним параметром: після реасайну $ConfigPath на
# effective-шлях жодна пізніша перевірка $PSBoundParameters відновити
# намір уже не може.
$configPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)

# Effective ConfigPath визначається ОДИН раз, до будь-якої перевірки, і далі
# використовується всюди: guard, завантажувач, дочірні скрипти. Раніше
# перемикачі безпеки перевірялись у "$PSScriptRoot\BRAVO.config" незалежно
# від -ConfigPath — тобто запуск із власною конфігурацією проходив перевірку
# ЧУЖОГО файлу: та, за якою реально працює скрипт, лишалась неперевіреною.
$effectiveConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $PSScriptRoot 'BRAVO.config'
} else {
    [Environment]::ExpandEnvironmentVariables($ConfigPath)
}
try {
    $effectiveConfigPath = [System.IO.Path]::GetFullPath($effectiveConfigPath)
} catch {
    # Некоректний шлях НЕ обробляється тут виходом: перевірка цілісності
    # комплекту (код 33) мусить лишатись найпершим бар'єром, інакше запуск
    # із заздалегідь зіпсованим -ConfigPath дозволяв би обійти guard.
    # Далі це значення відхилить або сам guard, або завантажувач (код 30).
    $effectiveConfigPath = [string]$effectiveConfigPath
}
$ConfigPath = $effectiveConfigPath

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
        -ConfigPath $effectiveConfigPath `
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

# dev.13: elevation gate. Комплект уже підтверджено цілим (перевірки вище) —
# тепер вирішуємо, чи можемо ми взагалі писати в LOGS/TEMP цього запуску.
# СЮДИ, а не пізніше: після Import-Module/Invoke-BRAVOHealthEntrypoint Health
# уже виконався б, і self-relaunch означав би подвійний прогін.
$currentWindowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentWindowsPrincipal = New-Object Security.Principal.WindowsPrincipal($currentWindowsIdentity)
$healthElevationState = Get-BRAVOHealthElevationState `
    -UserSid $currentWindowsIdentity.User.Value `
    -IsAdministratorRole ([bool]$currentWindowsPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator))

if ($healthElevationState -eq 'Standard') {
    $healthIsManualInteractiveSession = Test-BRAVOHealthManualInteractiveSession `
        -UserInteractive ([bool][Environment]::UserInteractive) `
        -InputRedirected ([bool][Console]::IsInputRedirected)

    # correctness pass: [Environment]::UserInteractive/[Console]::IsInputRedirected
    # не доводять -NonInteractive — читаємо ВЛАСНИЙ argv через вбудований
    # .NET Framework API [Environment]::GetCommandLineArgs() (Windows
    # PowerShell 5.1-сумісний, жодної залежності від CIM/WMI/Win32_Process:
    # перевірено емпірично, що це вже розпарсений string[] — powershell.exe
    # разом з усіма своїми перемикачами, включно з -NonInteractive, якщо
    # він був заданий; значення в лапках із пробілами лишаються одним
    # елементом). Немає зовнішнього виклику, який міг би не спрацювати —
    # try/catch тут не потрібен.
    $healthIsExplicitNonInteractive = Test-BRAVOHealthExplicitNonInteractive `
        -Argv ([Environment]::GetCommandLineArgs())

    $healthElevationAction = Get-BRAVOHealthElevationAction `
        -ElevationState $healthElevationState `
        -IsManualInteractiveSession $healthIsManualInteractiveSession `
        -IsExplicitNonInteractive $healthIsExplicitNonInteractive

    if ($healthElevationAction -eq 'FailFast') {
        # Заплановане завдання завжди виконується від SYSTEM (elevated за
        # визначенням) — цю гілку може дійсно спричинити лише non-interactive
        # запуск від звичайного акаунта поза Планувальником. UAC тут
        # НЕ показуємо: немає інтерактивної сесії, яка могла б на нього
        # відповісти. 36 = PrivilegeRequired (modules\BRAVO.ExitCodes).
        Write-Host "КРИТИЧНА ПОМИЛКА: BRAVO HEALTH запущено без прав адміністратора в non-interactive режимі." -ForegroundColor Red
        Write-Host "Автоматичне підвищення прав (UAC) недоступне без інтерактивної сесії." -ForegroundColor Red
        Write-Host "Запустіть від імені адміністратора вручну або через заплановане завдання SYSTEM." -ForegroundColor Red
        Wait-BRAVOEarlyManualExit -NoPause:$NoPause
        exit 36
    }

    if ($healthElevationAction -eq 'Relaunch') {
        Write-Host "BRAVO HEALTH потребує прав адміністратора для ручного запуску." -ForegroundColor Yellow
        Write-Host "Запит підвищення прав (UAC)..." -ForegroundColor Yellow
        $powerShellExecutablePath = Join-Path $PSHOME 'powershell.exe'
        # AUTO -> без -ConfigPath у дочірньому argv (elevated-процес сам
        # повторює auto-derivation); EXPLICIT -> точний резолвлений шлях.
        $relaunchResolvedConfigPath = if ($configPathWasExplicit) { $effectiveConfigPath } else { $null }
        $relaunchArgumentList = New-BRAVOHealthRelaunchArgumentList `
            -ScriptPath $PSCommandPath `
            -BoundParameters $PSBoundParameters `
            -ResolvedConfigPath $relaunchResolvedConfigPath
        try {
            # -Wait -PassThru: батько блокується до завершення elevated
            # дочірнього процесу і повертає рівно його exit code — Health
            # виконується ОДИН раз, у дочірньому процесі.
            $elevatedHealthProcess = Start-Process `
                -FilePath $powerShellExecutablePath `
                -ArgumentList $relaunchArgumentList `
                -Verb RunAs `
                -WorkingDirectory $PSScriptRoot `
                -Wait `
                -PassThru `
                -ErrorAction Stop
            exit [int]$elevatedHealthProcess.ExitCode
        } catch {
            if (Test-BRAVOHealthElevationCancelled -ErrorRecord $_) {
                Write-Host ""
                Write-Host "BRAVO HEALTH потребує прав адміністратора для ручного запуску." -ForegroundColor Red
                Write-Host "Підвищення прав скасовано користувачем." -ForegroundColor Red
            } else {
                Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося запросити підвищення прав: $($_.Exception.Message)" -ForegroundColor Red
            }
            Wait-BRAVOEarlyManualExit -NoPause:$NoPause
            exit 36
        }
    }
}
# 'Proceed' (SYSTEM або вже elevated Administrator) — виконання продовжується
# нижче без жодної зміни поведінки, точно як до dev.13.

$modulePath = Join-Path $PSScriptRoot 'modules\BRAVO.Health\BRAVO.Health.psd1'
try {
    Import-Module -Name $modulePath -ErrorAction Stop
} catch {
    # Див. коментар у BRAVO_ARCHIV.ps1 — контракт кодів завершення має
    # діяти навіть при пошкодженому розгортанні. 90 = InternalError.
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модуль $modulePath : $($_.Exception.Message)" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 90
}
$parameters = @{
    ConfigPath = $ConfigPath; ConfigPathWasExplicit = $configPathWasExplicit
    ForceNotification = $ForceNotification
    NotifyOnSuccess = $NotifyOnSuccess; NoSlack = $NoSlack
    SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning; NoPause = $NoPause
    RuntimeRoot = $PSScriptRoot; EntryScriptPath = $PSCommandPath
}
exit (Invoke-BRAVOHealthEntrypoint -Parameters $parameters)
