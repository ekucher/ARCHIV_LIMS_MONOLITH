[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ValidateOnly
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

$tasksInstallConsoleModulePath = Join-Path $PSScriptRoot "modules\BRAVO.Console\BRAVO.Console.psd1"
Import-Module -Name $tasksInstallConsoleModulePath -ErrorAction Stop

$bravoScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Path $PSCommandPath -Parent
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

$compatibilityModulePath = Join-Path $bravoScriptDirectory "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1"
$systemModulePath = Join-Path $bravoScriptDirectory "modules\BRAVO.System\BRAVO.System.psd1"
if (-not (Test-Path -LiteralPath $compatibilityModulePath -PathType Leaf)) {
    Write-Error "Не знайдено модуль сумісності: $compatibilityModulePath"
    Complete-BRAVOHelperLog -ExitCode 1
}
try {
    $rollbackRecords = New-Object System.Collections.ArrayList
    $installationCommitted = $false
    # Обробник помилок читає $taskFolder, а присвоюється воно значно нижче.
    # Якщо збій стається раніше (наприклад, під час hardening ACL), StrictMode
    # кидає другу помилку прямо в catch і ховає справжню причину.
    $taskFolder = $null
    Import-Module -Name $compatibilityModulePath -ErrorAction Stop
    Import-Module -Name $systemModulePath -ErrorAction Stop
    Assert-BRAVOPowerShellCompatibility
    [void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
    $script:BRAVOCompatibility = Get-BRAVOCompatibilityInfo
    $script:BRAVOPowerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
} catch {
    Write-Error "Помилка сумісності: $($_.Exception.Message)"
    Complete-BRAVOHelperLog -ExitCode 1
}
if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
    Write-Warning $BRAVOPowerShellUpdate.Message
}
# Свіжість накопичувальних оновлень Windows — health-метрика, а не умова
# запуску. Її місце в BRAVO_HEALTH, який для цього й існує: тут вона лише
# додавала WARNING (а отже, ненульовий код завершення 10) до операції, на
# результат якої вік патчів не впливає жодним чином. Перевірки платформи
# (ОС, build, PowerShell, .NET, архітектура, API) лишаються на місці.
# P0 Configuration Foundation (PR C): свідомий намір оператора фіксується
# ТУТ, на межі справжнього виклику скрипта, ДО підстановки auto-дефолту —
# використовується і для Import-BravoConfiguration, і для рішення, чи
# вбудовувати -ConfigPath у Task Scheduler XML/UAC relaunch (Секція 6).
$configPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

$ErrorActionPreference = "Stop"



function Set-BRAVOProtectedRuntimeAcl {
    param([string]$RuntimeRoot)

    $resolvedRoot = (Resolve-Path -LiteralPath $RuntimeRoot).Path
    $resolvedUserProfile = [IO.Path]::GetFullPath(
        [Environment]::GetFolderPath("UserProfile")
    ).TrimEnd("\") + "\"
    if (($resolvedRoot.TrimEnd("\") + "\").StartsWith(
            $resolvedUserProfile,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (
            "SYSTEM-завдання не можна встановлювати з профілю користувача: " +
            "$resolvedRoot. Перенесіть runtime до захищеного каталогу, " +
            "наприклад C:\Program Files\BRAVO-Toolkit."
        )
    }
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $administrators = New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $system = New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
    $users = New-Object Security.Principal.SecurityIdentifier("S-1-5-32-545")

    # Захищаємо не тільки корінь: існуючі дочірні файли могли успадкувати
    # дозвіл запису до того, як комплект був перенесений у runtime. SYSTEM
    # запускає ці файли з ExecutionPolicy Bypass, тому кожен із них має
    # отримати власний закритий ACL.
    $runtimeItems = @($resolvedRoot) + @(
        Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse -ErrorAction Stop |
            ForEach-Object { $_.FullName }
    )
    foreach ($runtimeItem in $runtimeItems) {
        # Прапорці успадкування допустимі лише для каталогів. Для файлу
        # FileSystemAccessRule кидає "No flags can be set", через що весь
        # hardening ACL зривався на першому ж дочірньому файлі.
        $itemInheritance = if ([System.IO.Directory]::Exists($runtimeItem)) {
            $inheritance
        } else {
            [Security.AccessControl.InheritanceFlags]::None
        }
        # Навмисно НЕ читаємо існуючий ACL через Get-Acl: мета — повна заміна
        # на рівно 3 правила нижче, і читання/мутація старого DACL ламається
        # на реальних runtime-каталогах двома способами: "This access
        # control list is not in canonical form" (SetAccessRuleProtection на
        # успадкованому неканонічному DACL) і "Some or all identity
        # references could not be translated" (RemoveAccessRuleAll на
        # правилі з orphaned SID — видалений обліковий запис). Чистий
        # порожній security-descriptor не має старих правил, тож обидва
        # шляхи відмови неможливі, а кінцевий результат ідентичний.
        $acl = if ([System.IO.Directory]::Exists($runtimeItem)) {
            New-Object Security.AccessControl.DirectorySecurity
        } else {
            New-Object Security.AccessControl.FileSecurity
        }
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($administrators)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $administrators,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $itemInheritance,
            $propagation,
            $allow
        )))
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $system,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $itemInheritance,
            $propagation,
            $allow
        )))
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $users,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $itemInheritance,
            $propagation,
            $allow
        )))
        Set-Acl -LiteralPath $runtimeItem -AclObject $acl -ErrorAction Stop
    }

    Write-Host (
        "Runtime рекурсивно захищено ACL: $resolvedRoot; запис дозволений лише SYSTEM " +
        "і Administrators."
    ) -ForegroundColor Green
}

function Enable-BRAVOTaskSchedulerOperationalLog {
    $wevtutil = Join-Path $env:SystemRoot "System32\wevtutil.exe"
    if (-not (Test-Path -LiteralPath $wevtutil -PathType Leaf)) {
        Write-Warning "wevtutil.exe не знайдено; журнал Task Scheduler не увімкнено."
        return
    }
    & $wevtutil sl "Microsoft-Windows-TaskScheduler/Operational" /e:true
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Не вдалося увімкнути Task Scheduler Operational log."
    } else {
        Write-Host "Task Scheduler Operational log увімкнено." -ForegroundColor Green
    }
}



function ConvertTo-ScheduleTime {
    param(
        [string]$Value,
        [string]$SettingName
    )

    $parsedTime = [datetime]::MinValue
    $valid = [datetime]::TryParseExact(
        $Value,
        "HH:mm",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsedTime
    )
    if (-not $valid) {
        throw "$SettingName повинен мати формат HH:mm, наприклад 23:00"
    }

    return (Get-Date).Date.Add($parsedTime.TimeOfDay)
}

function Test-TaskName {
    param(
        [string]$TaskName,
        [string]$SettingName
    )

    if ([string]::IsNullOrWhiteSpace($TaskName) -or $TaskName -match '[\\/]') {
        throw "$SettingName має некоректне ім'я завдання"
    }
}

function Ensure-ScheduledTaskFolder {
    param(
        $TaskService,
        [string]$TaskPath
    )

    if ($TaskPath -eq "\") {
        return $TaskService.GetFolder("\")
    }

    $currentFolder = $TaskService.GetFolder("\")

    foreach ($segment in $TaskPath.Trim("\").Split("\")) {
        try {
            $currentFolder = $currentFolder.GetFolder($segment)
        } catch {
            $currentFolder = $currentFolder.CreateFolder($segment, $null)
        }
    }
    return $currentFolder
}

function Get-BRAVOScheduledTaskFolder {
    param(
        $TaskService,
        [string]$TaskPath
    )

    $comPath = if ($TaskPath -eq "\") {
        "\"
    } else {
        $TaskPath.TrimEnd("\")
    }
    try {
        return $TaskService.GetFolder($comPath)
    } catch {
        return $null
    }
}

function Get-BRAVORegisteredTask {
    param(
        $TaskFolder,
        [string]$TaskName
    )

    if ($null -eq $TaskFolder) {
        return $null
    }
    try {
        return $TaskFolder.GetTask($TaskName)
    } catch {
        return $null
    }
}

function ConvertTo-BRAVOMultipleInstancesPolicy {
    param([string]$Value)

    switch ($Value) {
        "Parallel" { return 0 }
        "Queue" { return 1 }
        "IgnoreNew" { return 2 }
        "StopExisting" { return 3 }
        default { throw "Некоректне значення schedulerSettings.MultipleInstances: $Value" }
    }
}

# ConvertTo-BRAVOSchedulerLogonType і Get-BRAVOExpectedSchedulerPrincipal
# перенесено до модуля BRAVO.System: Installer застосовує expected principal
# під час створення, а Diagnose перевіряє проти НЬОГО ж — спільне правило.

function New-BRAVOTaskDefinition {
    param(
        $TaskService,
        [hashtable]$TaskSettings,
        [ValidateSet("Backup", "Maintenance", "Health", "Recovery", "BAZASync", "RestoreVerify")]
        [string]$TaskType,
        [string]$ResolvedConfigPath,

        # P0 Configuration Foundation (PR C, Секція 6): AUTO-інсталяція
        # (оператор НЕ передав -ConfigPath) НЕ повинна вбудовувати
        # -ConfigPath у заплановане завдання — інакше майбутнє
        # додавання/видалення BRAVO.config на цьому сервері вимагало б
        # переінсталяції задач, і auto-задача мовчки ставала б explicit.
        # Кожен запуск задачі сам виконує ту саму AUTO-резолюцію, що й
        # цей інсталятор (entrypoint без -ConfigPath -> Import-BravoConfiguration
        # сама визначає no-config/legacy-primary шлях). EXPLICIT-інсталяція
        # (оператор свідомо передав -ConfigPath, зокрема зовнішній
        # ConfigRoot != RuntimeRoot) зберігає точний шлях у задачі.
        [bool]$ConfigPathWasExplicit
    )

    # Task Scheduler 2.0 COM API доступний починаючи з Windows Vista/7 і
    # не залежить від модуля ScheduledTasks, якого немає у Windows 7.
    $definition = $TaskService.NewTask(0)
    $definition.RegistrationInfo.Description = [string]$TaskSettings.Description

    $definition.Settings.Enabled = $true
    # Recovery окремо від інших task types: StartWhenAvailable=true, а не
    # глобальний schedulerSettings.StartWhenAvailable (типово false).
    # Історично це страхувало пропущений daily-тик; з 5.2.0 Recovery має
    # лише boot-trigger, на який StartWhenAvailable семантично не впливає
    # (це властивість «пропущений запланований момент», а не подієвий
    # тригер) — значення збережено як нешкідливе і сумісне з майбутніми
    # розкладовими тригерами, якщо вони колись повернуться.
    $definition.Settings.StartWhenAvailable = if ($TaskType -eq "Recovery") {
        $true
    } else {
        [bool]$schedulerSettings.StartWhenAvailable
    }
    $definition.Settings.WakeToRun = [bool]$schedulerSettings.WakeToRun
    $definition.Settings.Hidden = [bool]$schedulerSettings.Hidden
    $definition.Settings.DisallowStartIfOnBatteries =
        -not [bool]$schedulerSettings.AllowStartIfOnBatteries
    $definition.Settings.StopIfGoingOnBatteries =
        -not [bool]$schedulerSettings.DontStopIfGoingOnBatteries
    $definition.Settings.MultipleInstances = ConvertTo-BRAVOMultipleInstancesPolicy `
        -Value ([string]$schedulerSettings.MultipleInstances)
    $definition.Settings.ExecutionTimeLimit = [System.Xml.XmlConvert]::ToString(
        [timespan]::FromHours([double]$TaskSettings.ExecutionTimeLimitHours)
    )
    if ([int]$schedulerSettings.RestartCount -gt 0) {
        $definition.Settings.RestartCount = [int]$schedulerSettings.RestartCount
        $definition.Settings.RestartInterval = [System.Xml.XmlConvert]::ToString(
            [timespan]::FromMinutes([int]$schedulerSettings.RestartIntervalMinutes)
        )
    }

    # Один канонічний розрахунок principal (BRAVO.System). Diagnose перевіряє
    # фактичне визначення проти цих самих значень.
    $expectedPrincipal = Get-BRAVOExpectedSchedulerPrincipal -SchedulerSettings $schedulerSettings
    $logonType = $expectedPrincipal.LogonType
    $definition.Principal.UserId = $expectedPrincipal.UserId
    $definition.Principal.LogonType = $expectedPrincipal.LogonType
    $definition.Principal.RunLevel = $expectedPrincipal.RunLevel

    $triggerTime = if ($TaskType -eq "Health" -or $TaskType -eq "BAZASync") {
        ConvertTo-ScheduleTime `
            -Value $TaskSettings.StartAt `
            -SettingName "$TaskType.StartAt"
    } elseif ($TaskType -eq "Recovery") {
        $null
    } elseif ($TaskType -eq "RestoreVerify") {
        ConvertTo-ScheduleTime -Value $TaskSettings.At -SettingName "$TaskType.At"
    } else {
        ConvertTo-ScheduleTime -Value $TaskSettings.DailyAt -SettingName "$TaskType.DailyAt"
    }
    # Recovery-завдання (5.2.0) існує ЛИШЕ на серверах робочого часу
    # (Restore.BootRestoreMode="HoldServices" -> Scheduler.Recovery.Enabled;
    # на 24/7-профілі "None" завдання вимикається інсталятором, а пропущений
    # слот підхоплює щонічне Maintenance у вікні реставрації). Тому тут воно
    # має рівно ОДИН boot-trigger БЕЗ Repetition: реставрація виконується
    # одразу після старту сервера, поки служби (Automatic Delayed Start) ще
    # не запущені; повтор невдалої спроби — наступний старт сервера.
    # Раніший дизайн (daily-trigger о WindowStart + boot-Repetition
    # 15 хв/8 год) прибрано: на production-сервері BRAVO 2026-08-20 repetition-хвіст будив
    # завдання кожні 15 хв ще довго після успішної реставрації.
    if ($TaskType -eq "Recovery") {
        $trigger = $definition.Triggers.Create(8) # TASK_TRIGGER_BOOT
        $delayMinutes = [math]::Max(0, [int]$TaskSettings.StartupDelayMinutes)
        if ($delayMinutes -gt 0) {
            $trigger.Delay = [System.Xml.XmlConvert]::ToString(
                [timespan]::FromMinutes($delayMinutes)
            )
        }
        $trigger.Enabled = $true
    } elseif ($TaskType -eq "RestoreVerify") {
        # Щотижневий restore drill (P1.1): один weekly-тригер. DaysOfWeek —
        # канонічний bitmask ConvertTo-BRAVODaysOfWeekMask (BRAVO.System),
        # той самий розрахунок використовує Diagnose.
        $trigger = $definition.Triggers.Create(3) # TASK_TRIGGER_WEEKLY
        $trigger.StartBoundary = $triggerTime.ToString("yyyy-MM-dd'T'HH:mm:ss")
        $trigger.Enabled = $true
        $trigger.WeeksInterval = 1
        $trigger.DaysOfWeek = ConvertTo-BRAVODaysOfWeekMask -DayOfWeek ([string]$TaskSettings.WeeklyOn)
    } else {
        $trigger = $definition.Triggers.Create(2) # TASK_TRIGGER_DAILY
        $trigger.StartBoundary = $triggerTime.ToString("yyyy-MM-dd'T'HH:mm:ss")
        $trigger.Enabled = $true
        $trigger.DaysInterval = 1
    }

    if ($TaskType -eq "Health") {
        $trigger.Repetition.Interval = [System.Xml.XmlConvert]::ToString(
            [timespan]::FromMinutes([int]$TaskSettings.RepeatEveryMinutes)
        )
        $trigger.Repetition.Duration = "P1D"
        $trigger.Repetition.StopAtDurationEnd = $false
    }
    if ($TaskType -eq "BAZASync") {
        $trigger.Repetition.Interval = [System.Xml.XmlConvert]::ToString(
            [timespan]::FromHours([int]$TaskSettings.RepeatEveryHours)
        )
        $trigger.Repetition.Duration = "P1D"
        $trigger.Repetition.StopAtDurationEnd = $false
    }
    $scriptPath = (Resolve-Path -Path $TaskSettings.ScriptPath).Path
    $actionArguments = "-NoLogo -NoProfile -NonInteractive"
    $actionArguments += " -WindowStyle $($schedulerSettings.WindowStyle)"
    $actionArguments += " -ExecutionPolicy Bypass"
    $actionArguments += " -File `"$scriptPath`""
    if ($ConfigPathWasExplicit) {
        $actionArguments += " -ConfigPath `"$ResolvedConfigPath`""
    }
    # -NoPause — безумовно, для КОЖНОГО типу завдання, а не вибірково за
    # типом. Заплановане завдання ніколи не повинно чекати на клавішу: це
    # зупинило б автоматизацію назавжди, без жодного індикатора для
    # моніторингу. Раніше Recovery і Maintenance не отримували -NoPause
    # взагалі — байдуже, доки в самих скриптах не було паузи; ця
    # безумовна форма унеможливлює саме такий тип прогалини надалі.
    $actionArguments += " -NoPause"
    if ($TaskType -eq "Health") {
        $actionArguments += " -NotifyOnSuccess"
        if ($TaskSettings.SkipIfBackupTaskRunning) {
            $actionArguments += " -SkipIfBackupTaskRunning"
        }
    }
    if ($TaskType -eq "Recovery") {
        $actionArguments += " -RunMissedRestoreOnly"
    }
    if ($TaskType -eq "BAZASync") {
        $actionArguments += " -SyncBAZA"
    }
    if ($TaskType -eq "RestoreVerify") {
        # Щотижневе SUCCESS-підтвердження в GENERAL (рішення власника,
        # 2026-08-26): «тиша» не відрізняється від «задача мертва».
        $actionArguments += " -NotifyOnSuccess"
    }
    $action = $definition.Actions.Create(0) # TASK_ACTION_EXEC
    $action.Path = [string]$schedulerSettings.PowerShellExecutable
    $action.Arguments = $actionArguments
    $action.WorkingDirectory = Split-Path -Path $scriptPath -Parent

    # Присвоєння XmlText іншому COM-об'єкту змушує Task Scheduler
    # перевірити XML без реєстрації завдання.
    $validatedDefinition = $TaskService.NewTask(0)
    $validatedDefinition.XmlText = $definition.XmlText

    return [pscustomobject]@{
        Definition = $validatedDefinition
        LogonType = $expectedPrincipal.LogonType
        UserId = $expectedPrincipal.UserId
    }
}

function Format-BRAVOInstalledTaskSummaryNextRun {
    param(
        [ValidateSet("Backup", "Maintenance", "Health", "Recovery", "BAZASync", "RestoreVerify")]
        [string]$TaskType,
        $TaskSettings,
        $NextRunTime
    )

    $nextRunArguments = @{
        TaskType = $TaskType
        NextRunTime = $NextRunTime
    }
    if ($TaskType -eq "Recovery") {
        $nextRunArguments.StartupDelayMinutes = [int]$TaskSettings.StartupDelayMinutes
    }

    return Format-BRAVOSchedulerNextRun @nextRunArguments
}

function Test-SchedulerConfiguration {
    param([string]$ResolvedConfigPath)

    if ($null -eq $schedulerSettings) {
        throw "У конфігурації відсутній schedulerSettings"
    }
    if ($null -eq $credentialSettings -or
        [string]::IsNullOrWhiteSpace([string]$credentialSettings.HelperPath) -or
        -not (Test-Path -LiteralPath $credentialSettings.HelperPath -PathType Leaf)) {
        throw "Не знайдено модуль Credential Manager: $($credentialSettings.HelperPath)"
    }
    # RuntimeRoot — каталог КОМПЛЕКТУ (звідки запущено Installer), а не каталог
    # конфігурації: модулі є runtime-ресурсами й лежать поруч зі скриптами.
    # $global:runtimeRoot публікує завантажувач із -RuntimeRoot $bravoScriptDirectory.
    $runtimeRoot = [string]$global:runtimeRoot
    $requiredModuleNames = @(
        'BRAVO.Compatibility',
        'BRAVO.Credentials',
        'BRAVO.Notifications',
        'BRAVO.ArchiveHelpers',
        'BRAVO.ArchiveRuntime',
        'BRAVO.Archive',
        'BRAVO.Health',
        'BRAVO.Maintenance',
        'BRAVO.HelperLogging',
        'BRAVO.System',
        'BRAVO.RestoreVerify',
        'BRAVO.Status'
    )
    foreach ($moduleName in $requiredModuleNames) {
        $manifestPath = Join-Path $runtimeRoot "modules\$moduleName\$moduleName.psd1"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Не знайдено required PowerShell-модуль: $manifestPath"
        }
        try {
            Import-Module -Name $manifestPath -DisableNameChecking -ErrorAction Stop
        } catch {
            throw "Не вдалося імпортувати required PowerShell-модуль '$moduleName': $($_.Exception.Message)"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$credentialSettings.SetupScriptPath) -or
        -not (Test-Path -LiteralPath $credentialSettings.SetupScriptPath -PathType Leaf)) {
        throw "Не знайдено скрипт налаштування секретів: $($credentialSettings.SetupScriptPath)"
    }
    if (-not (Test-Path -Path $schedulerSettings.PowerShellExecutable -PathType Leaf)) {
        throw "PowerShellExecutable не знайдено: $($schedulerSettings.PowerShellExecutable)"
    }
    $validWindowStyles = @("Normal", "Minimized", "Maximized", "Hidden")
    if (-not ($validWindowStyles -icontains [string]$schedulerSettings.WindowStyle)) {
        throw "Некоректне schedulerSettings.WindowStyle. Дозволено: Normal, Minimized, Maximized або Hidden"
    }

    $configuredLogonType = [string]$schedulerSettings.LogonType
    if ($configuredLogonType -notin @("ServiceAccount", "Interactive")) {
        throw "Підтримуються лише schedulerSettings.LogonType: ServiceAccount або Interactive"
    }
    if ($configuredLogonType -eq "ServiceAccount") {
        $supportedAccounts = @(
            "SYSTEM",
            "NT AUTHORITY\SYSTEM",
            "LOCALSERVICE",
            "NT AUTHORITY\LOCAL SERVICE",
            "NETWORKSERVICE",
            "NT AUTHORITY\NETWORK SERVICE"
        )
        if (-not ($supportedAccounts -icontains [string]$schedulerSettings.RunAsUser)) {
            throw "Для LogonType=ServiceAccount потрібно вказати системний обліковий запис"
        }
    } elseif ([string]::IsNullOrWhiteSpace([string]$schedulerSettings.RunAsUser)) {
        throw "Для LogonType=Interactive потрібно вказати RunAsUser"
    }

    $validMultipleInstances = @("Parallel", "Queue", "IgnoreNew", "StopExisting")
    if (-not ($validMultipleInstances -icontains [string]$schedulerSettings.MultipleInstances)) {
        throw "Некоректне значення schedulerSettings.MultipleInstances"
    }
    if ($schedulerSettings.Contains("OperationLockWaitMinutes") -and
        ([int]$schedulerSettings.OperationLockWaitMinutes -lt 0 -or
         [int]$schedulerSettings.OperationLockWaitMinutes -gt 1440)) {
        throw "OperationLockWaitMinutes повинен бути в межах від 0 до 1440"
    }
    if ([int]$schedulerSettings.RestartCount -lt 0) {
        throw "RestartCount не може бути від'ємним"
    }
    if ([int]$schedulerSettings.RestartCount -gt 0 -and
        [int]$schedulerSettings.RestartIntervalMinutes -le 0) {
        throw "RestartIntervalMinutes повинен бути більшим за 0"
    }

    Test-TaskName -TaskName $schedulerSettings.Backup.TaskName -SettingName "Backup.TaskName"
    Test-TaskName -TaskName $schedulerSettings.Maintenance.TaskName -SettingName "Maintenance.TaskName"
    Test-TaskName -TaskName $schedulerSettings.Health.TaskName -SettingName "Health.TaskName"
    Test-TaskName -TaskName $schedulerSettings.Recovery.TaskName -SettingName "Recovery.TaskName"
    Test-TaskName -TaskName $schedulerSettings.BAZASync.TaskName -SettingName "BAZASync.TaskName"
    Test-TaskName -TaskName $schedulerSettings.RestoreVerify.TaskName -SettingName "RestoreVerify.TaskName"
    $taskNames = @(
        [string]$schedulerSettings.Backup.TaskName,
        [string]$schedulerSettings.Maintenance.TaskName,
        [string]$schedulerSettings.Health.TaskName,
        [string]$schedulerSettings.Recovery.TaskName,
        [string]$schedulerSettings.BAZASync.TaskName,
        [string]$schedulerSettings.RestoreVerify.TaskName
    )
    if (@($taskNames | Select-Object -Unique).Count -ne $taskNames.Count) {
        throw "Імена Backup, Maintenance, Health, Recovery, BAZASync і RestoreVerify завдань повинні відрізнятися"
    }

    foreach ($taskSettings in @(
        $schedulerSettings.Backup,
        $schedulerSettings.Maintenance,
        $schedulerSettings.Health,
        $schedulerSettings.Recovery,
        $schedulerSettings.BAZASync,
        $schedulerSettings.RestoreVerify
    )) {
        if ($taskSettings.Enabled -and -not (Test-Path -Path $taskSettings.ScriptPath -PathType Leaf)) {
            throw "Скрипт завдання не знайдено: $($taskSettings.ScriptPath)"
        }
        if ($taskSettings.Enabled -and [double]$taskSettings.ExecutionTimeLimitHours -le 0) {
            throw "ExecutionTimeLimitHours повинен бути більшим за 0"
        }
    }
    if ($schedulerSettings.Backup.Enabled) {
        [void](ConvertTo-ScheduleTime -Value $schedulerSettings.Backup.DailyAt -SettingName "Backup.DailyAt")
    }
    if ($schedulerSettings.Maintenance.Enabled) {
        [void](ConvertTo-ScheduleTime -Value $schedulerSettings.Maintenance.DailyAt -SettingName "Maintenance.DailyAt")
    }
    if ($schedulerSettings.Health.Enabled) {
        [void](ConvertTo-ScheduleTime -Value $schedulerSettings.Health.StartAt -SettingName "Health.StartAt")
        if ([int]$schedulerSettings.Health.RepeatEveryMinutes -lt 1 -or
            [int]$schedulerSettings.Health.RepeatEveryMinutes -gt 1440) {
            throw "Health.RepeatEveryMinutes повинен бути в межах від 1 до 1440"
        }
    }
    if ($schedulerSettings.BAZASync.Enabled) {
        [void](ConvertTo-ScheduleTime `
            -Value $schedulerSettings.BAZASync.StartAt `
            -SettingName "BAZASync.StartAt")
        if ([int]$schedulerSettings.BAZASync.RepeatEveryHours -lt 1 -or
            [int]$schedulerSettings.BAZASync.RepeatEveryHours -gt 24) {
            throw "BAZASync.RepeatEveryHours повинен бути в межах від 1 до 24"
        }
    }
    if ($schedulerSettings.Recovery.Enabled -and
        [int]$schedulerSettings.Recovery.StartupDelayMinutes -lt 0) {
        throw "Recovery.StartupDelayMinutes не може бути від'ємним"
    }
    if ($schedulerSettings.RestoreVerify.Enabled) {
        [void](ConvertTo-ScheduleTime `
            -Value $schedulerSettings.RestoreVerify.At `
            -SettingName "RestoreVerify.At")
        # Канонічний конвертер (BRAVO.System) кидає на невідомій назві дня —
        # невалідний розклад ловиться тут, а не під час створення тригера.
        [void](ConvertTo-BRAVODaysOfWeekMask -DayOfWeek ([string]$schedulerSettings.RestoreVerify.WeeklyOn))
    }

    # P1 (safety-review): BRAVO_MAINTENANCE/BRAVO_RESTORE_RECOVERY реально
    # керують службою й ротацією системних журналів — якщо вони увімкнені, а
    # effectiveLimsRoot/systemLogRoot не резолвляться, реєстрація завдання
    # гарантовано створює завдання, приречене на негайний exit 30 при
    # КОЖНОМУ запуску (BRAVO_MAINTENANCE.ps1 має власну guard-перевірку
    # одразу після Import-BravoConfiguration). BRAVO_SETUP вже захищений
    # своїм першим DryRun-preflight (той самий Get-BRAVOTaskRootReadinessResults),
    # але цей скрипт можна викликати напряму, в обхід Setup — тому перевірка
    # МАЄ стояти й тут, а не лише в DryRun. Спільна функція (BRAVO.System,
    # уже імпортована вище) — та сама, що BRAVO_DRY_RUN.ps1, щоб правило не
    # розходилось між ними.
    #
    # НЕ throw на BackupRoot тут: BRAVO.config уже безумовно throw-ить на
    # нього під час Import-BravoConfiguration (виконання не дійшло б навіть
    # до цієї функції, якби BackupRoot не резолвився) — дублювати цю
    # перевірку нема сенсу. Backup/Health/BAZASync НЕ вимагають LIMSRoot/
    # SystemLogRoot (service state != backup policy) — їх реєстрація
    # лишається дозволеною незалежно від цих коренів.
    $maintenanceTaskEnabled = [bool]$schedulerSettings.Maintenance.Enabled
    $recoveryTaskEnabled = [bool]$schedulerSettings.Recovery.Enabled
    if ($maintenanceTaskEnabled -or $recoveryTaskEnabled) {
        $taskRootReadiness = Get-BRAVOTaskRootReadinessResults `
            -BackupRootSource ([string]$global:backupRootResult.Source) `
            -BackupRootValue ([string]$global:backupRootPath) `
            -BackupRootReason ([string]$global:backupRootResult.Reason) `
            -LimsRootSource ([string]$global:limsRootResult.Source) `
            -LimsRootValue ([string]$global:effectiveLimsRoot) `
            -LimsRootReason ([string]$global:limsRootResult.Reason) `
            -SystemLogRootSource ([string]$global:systemLogRootResult.Source) `
            -SystemLogRootValue ([string]$global:systemLogRoot) `
            -SystemLogRootReason ([string]$global:systemLogRootResult.Reason) `
            -MaintenanceTaskEnabled $maintenanceTaskEnabled `
            -RecoveryTaskEnabled $recoveryTaskEnabled
        $blockingRootFailures = @(
            $taskRootReadiness | Where-Object {
                $_.Status -eq 'FAIL' -and ($_.Label -like 'LIMSRoot*' -or $_.Label -like 'SystemLogRoot*')
            }
        )
        if ($blockingRootFailures.Count -gt 0) {
            throw (
                "Реєстрацію Maintenance/Recovery заблоковано — обов'язковий корінь не визначено: " +
                (($blockingRootFailures | ForEach-Object { "$($_.Label): $($_.Detail)" }) -join ' | ')
            )
        }
    }

}

# P0 Configuration Foundation: BRAVO.config став опційним основним
# override-шаром — попередні жорсткі "файл мусить існувати" перевірки тут
# (і в Test-SchedulerConfiguration вище, і Resolve-Path, який теж вимагав
# існування) дублювали те саме рішення, яке Import-BravoConfiguration
# тепер приймає коректно сама. schedulerSettings/credentialSettings.
# HelperPath/SetupScriptPath повністю заповнюються canonical дефолтами +
# derivation незалежно від наявності BRAVO.config — Test-SchedulerConfiguration
# і далі валідно перевіряє РЕАЛЬНІ шляхи runtime-ресурсів на диску, лише не
# наявність самого BRAVO.config. $ResolvedConfigPath, вбудований у аргументи
# запланованого завдання (New-BRAVOTaskDefinition), за відсутності
# BRAVO.config дорівнюватиме auto-derived шляху (ConfigRoot\BRAVO.config) —
# той самий шлях, який завантажувач під час майбутнього запуску завдання
# коректно розпізнає як no-config (synthetic) сценарій, а не помилку.
# GetFullPath (а не Resolve-Path) нормалізує шлях без вимоги існування.
$resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
try {
    $configRoot = Split-Path -Path $resolvedConfigPath -Parent
    $configurationLoaderPath = Join-Path $bravoScriptDirectory 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $resolvedConfigPath `
        -RuntimeRoot $bravoScriptDirectory `
        -ConfigPathWasExplicit:$configPathWasExplicit

    # schedulerSettings.BAZASync (разом із його .Enabled) визначає BRAVO.config
    # через канонічний $bazaSyncEffective (BAZA_APP_SFTP OR BAZA_WWW_SFTP).
    # Installer більше НЕ синтезує цей вузол і не звужує його лише до
    # BAZA_APP_SFTP: інакше валідна пара BAZA_APP_SFTP=$false/BAZA_WWW_SFTP=$true
    # мовчки лишала б BAZA_WWW без запланованої синхронізації, а Diagnose (який
    # читає config напряму) не бачив би BAZASync взагалі.

    # Розклад є єдиним джерелом правди у BRAVO.config. Інсталятор не має
    # непомітно змінювати періодичність health-check під час реєстрації задач.

    Initialize-BRAVOConsole
    Initialize-BRAVOProgress -Enabled $false
    Write-BRAVOHeader `
        -Title ("BRAVO Tasks Setup {0}" -f $global:ScriptVersion) `
        -Institution ([string]$bravoSettings.InstitutionName) `
        -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
        -Mode $(if ($ValidateOnly) { 'VALIDATE' } else { 'INSTALL' })
    $script:BRAVOTasksInstallStepTotal = 5
    $script:BRAVOTasksInstallStepCurrent = 0
    function Write-BRAVOTasksInstallStep {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [ValidateSet('OK', 'SKIPPED', 'WARNING', 'ERROR')][string]$Status = 'OK',
            [string]$Details
        )
        $script:BRAVOTasksInstallStepCurrent++
        Write-BRAVOStepResult `
            -Current $script:BRAVOTasksInstallStepCurrent `
            -Total $script:BRAVOTasksInstallStepTotal `
            -Name $Name `
            -Status $Status
        if (-not [string]::IsNullOrWhiteSpace($Details)) {
            if ($Status -eq 'SKIPPED') {
                Write-BRAVOSkipReason -Reason $Details
            } elseif ($Status -in @('WARNING', 'ERROR')) {
                Write-BRAVOOperatorReason -Reason $Details
            } else {
                Write-BRAVOStepDetail -Message $Details
            }
        }
    }

    $taskPath = ConvertTo-BRAVOTaskPath -TaskPath $schedulerSettings.TaskPath
    Test-SchedulerConfiguration -ResolvedConfigPath $resolvedConfigPath
    $taskService = New-Object -ComObject "Schedule.Service"
    $taskService.Connect()
} catch {
    Write-Error "Помилка конфігурації планувальника: $($_.Exception.Message)"
    Complete-BRAVOHelperLog -ExitCode 1
}

if (-not $ValidateOnly -and -not (Test-IsAdministrator)) {
    Write-Host "Потрібні права адміністратора. Відкривається запит UAC..." -ForegroundColor Yellow
    # P0 Configuration Foundation (PR C, Секція 6): зберігаємо operator
    # intent при UAC relaunch — AUTO (оператор НЕ передав -ConfigPath) не
    # повинен ставати EXPLICIT лише тому, що elevated-процес отримує
    # передані аргументи. Без цього no-config-інсталяція втратила б
    # AUTO-намір одразу після першого UAC-запиту.
    $elevationArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($configPathWasExplicit) {
        $elevationArguments += " -ConfigPath `"$resolvedConfigPath`""
    }
    try {
        $elevatedProcess = Start-Process `
            -FilePath $schedulerSettings.PowerShellExecutable `
            -ArgumentList $elevationArguments `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -WindowStyle Normal
        Complete-BRAVOHelperLog -ExitCode $elevatedProcess.ExitCode
    } catch {
        Write-Error "Не вдалося отримати права адміністратора: $($_.Exception.Message)"
        Complete-BRAVOHelperLog -ExitCode 1
    }
}

try {
    Write-Host "API планувальника: Task Scheduler 2.0 COM (Windows 7+); доступні сучасні API: $($BRAVOCompatibility.TaskSchedulerProvider)" -ForegroundColor DarkGray
    $taskPlans = @(
        [pscustomobject]@{ Type = "Backup"; Settings = $schedulerSettings.Backup },
        [pscustomobject]@{ Type = "Maintenance"; Settings = $schedulerSettings.Maintenance },
        [pscustomobject]@{ Type = "Health"; Settings = $schedulerSettings.Health },
        [pscustomobject]@{ Type = "Recovery"; Settings = $schedulerSettings.Recovery },
        [pscustomobject]@{ Type = "BAZASync"; Settings = $schedulerSettings.BAZASync },
        [pscustomobject]@{ Type = "RestoreVerify"; Settings = $schedulerSettings.RestoreVerify }
    )

    $requireProtectedRuntime = (
        $schedulerSettings.Contains("RequireProtectedRuntime") -and
        [System.Convert]::ToBoolean($schedulerSettings.RequireProtectedRuntime)
    )
    # ACL hardening застосовується до RuntimeRoot (каталог, який SYSTEM
    # виконує), а не до каталогу конфігурації. Раніше тут стояло
    # Split-Path $resolvedConfigPath, тому при -ConfigPath з іншого каталогу
    # захищався б не той каталог.
    $runtimeRoot = [string]$global:runtimeRoot
    if ($requireProtectedRuntime) {
        $profileRoot = [IO.Path]::GetFullPath(
            [Environment]::GetFolderPath("UserProfile")
        ).TrimEnd("\") + "\"
        if (($runtimeRoot.TrimEnd("\") + "\").StartsWith(
                $profileRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            $unsafeRuntimeMessage = (
                "SYSTEM runtime розташований у профілі користувача: " +
                "$runtimeRoot. Фактична інсталяція буде відхилена; " +
                "перенесіть комплект до C:\Program Files\BRAVO-Toolkit."
            )
            if ($ValidateOnly) {
                Write-Warning $unsafeRuntimeMessage
            } else {
                throw $unsafeRuntimeMessage
            }
        }
    }
    if ($ValidateOnly) {
        if ($requireProtectedRuntime) {
            Write-BRAVOTasksInstallStep -Name 'Захист runtime ACL' -Status SKIPPED -Details "лише перевірка: $runtimeRoot"
        } else {
            Write-BRAVOTasksInstallStep -Name 'Захист runtime ACL' -Status SKIPPED -Details 'лише перевірка'
        }
        Write-BRAVOTasksInstallStep -Name 'Task Scheduler Operational log' -Status SKIPPED -Details 'лише перевірка'
    } else {
        if ($requireProtectedRuntime) {
            Set-BRAVOProtectedRuntimeAcl -RuntimeRoot $runtimeRoot
            Write-BRAVOTasksInstallStep -Name 'Захист runtime ACL' -Status OK
        } else {
            Write-BRAVOTasksInstallStep -Name 'Захист runtime ACL' -Status WARNING -Details 'RequireProtectedRuntime=false: SYSTEM виконуватиме файли без автоматичного hardening ACL.'
        }
        Enable-BRAVOTaskSchedulerOperationalLog
        Write-BRAVOTasksInstallStep -Name 'Task Scheduler Operational log' -Status OK
    }

    # Start type керованих служб — частина профілю Restore.BootRestoreMode
    # (BRAVO.config): HoldServices -> Automatic (Delayed Start), щоб
    # Recovery-boot-завдання встигло виконати пропущену реставрацію до
    # старту служб; None -> повернення звичайного Automatic лише зі стану
    # delayed-auto. Канонічна реалізація — BRAVO.System
    # (Set-BRAVOBootRestoreServiceStartType); Manual/Disabled не чіпаються.
    $bootRestoreHoldServices = ([string]$maintenanceSettings.Restore.BootRestoreMode -eq 'HoldServices')
    $bootRestoreServiceNames = @(
        [string]$maintenanceSettings.Services.BravoName
        [string]$maintenanceSettings.Services.ExchangeApiName
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $startTypeResults = Set-BRAVOBootRestoreServiceStartType `
        -ServiceNames $bootRestoreServiceNames `
        -HoldServices $bootRestoreHoldServices `
        -ValidateOnly:$ValidateOnly
    $startTypeFailures = @($startTypeResults | Where-Object { -not $_.Success })
    $startTypeChanges = @($startTypeResults | Where-Object { $_.Action -in @('SetDelayedAuto', 'SetAuto') })
    $startTypeDetailsText = ($startTypeResults | ForEach-Object {
        $delayedText = if ($_.DelayedAutoStart) { 'delayed-auto' } else { [string]$_.StartType }
        "{0}: {1} ({2})" -f $_.Name, $delayedText, $_.Action
    }) -join '; '
    if ($ValidateOnly) {
        Write-BRAVOTasksInstallStep -Name 'Start type служб (BootRestoreMode)' -Status SKIPPED -Details "лише перевірка: $startTypeDetailsText"
    } elseif ($startTypeFailures.Count -gt 0) {
        # Невдала зміна start type ламає гарантію «клієнти не зайдуть до
        # реставрації» у HoldServices-профілі — це помилка інсталяції.
        throw "Не вдалося змінити start type служб: $(($startTypeFailures | ForEach-Object { "$($_.Name): $($_.Details)" }) -join '; ')"
    } elseif ($startTypeChanges.Count -gt 0) {
        Write-BRAVOTasksInstallStep -Name 'Start type служб (BootRestoreMode)' -Status OK -Details $startTypeDetailsText
    } else {
        Write-BRAVOTasksInstallStep -Name 'Start type служб (BootRestoreMode)' -Status OK -Details "змін не потрібно: $startTypeDetailsText"
    }

    $taskFolder = Get-BRAVOScheduledTaskFolder -TaskService $taskService -TaskPath $taskPath
    if (-not $ValidateOnly -and @($taskPlans | Where-Object { $_.Settings.Enabled }).Count -gt 0) {
        $taskFolder = Ensure-ScheduledTaskFolder -TaskService $taskService -TaskPath $taskPath
    }

    # Банер-перед-циклом (той самий патерн, що Setup для дочірніх процесів):
    # кожен запис завдання друкує власний "[ПЕРЕВІРКА]"/"встановлено" рядок
    # усередині цього кроку, тому "OK" з'являється ПІСЛЯ них, а не ковтає їх.
    $script:BRAVOTasksInstallStepCurrent++
    Write-Host ("[{0}/{1}] Створення завдань" -f $script:BRAVOTasksInstallStepCurrent, $script:BRAVOTasksInstallStepTotal) -ForegroundColor Cyan
    $taskSummaries = New-Object System.Collections.Generic.List[object]
    foreach ($taskPlan in $taskPlans) {
        $taskSettings = $taskPlan.Settings
        $taskName = [string]$taskSettings.TaskName
        $existingTaskBeforeChange = Get-BRAVORegisteredTask `
            -TaskFolder $taskFolder `
            -TaskName $taskName
        if (-not $ValidateOnly) {
            [void]$rollbackRecords.Add([pscustomobject]@{
                TaskName = $taskName
                Existed = $null -ne $existingTaskBeforeChange
                Xml = if ($null -ne $existingTaskBeforeChange) {
                    [string]$existingTaskBeforeChange.Xml
                } else {
                    $null
                }
                Enabled = if ($null -ne $existingTaskBeforeChange) {
                    [bool]$existingTaskBeforeChange.Enabled
                } else {
                    $false
                }
            })
        }

        if (-not $taskSettings.Enabled) {
            $existingTask = $existingTaskBeforeChange
            if ($existingTask) {
                if ($ValidateOnly) {
                    Write-Host "[ПЕРЕВІРКА] Завдання буде вимкнено: $taskPath$taskName" -ForegroundColor Yellow
                } else {
                    $existingTask.Enabled = $false
                    Write-Host "Завдання вимкнено: $taskPath$taskName" -ForegroundColor Yellow
                }
                $taskSummaries.Add([pscustomobject]@{
                    Name = $taskName
                    Status = if ($ValidateOnly) { 'БУДЕ ВИМКНЕНО' } else { 'DISABLED' }
                    Account = $null
                    NextRun = $null
                })
            } else {
                Write-Host "Завдання вимкнено в конфігурації: $taskPath$taskName" -ForegroundColor DarkGray
            }
            continue
        }

        $definition = New-BRAVOTaskDefinition `
            -TaskService $taskService `
            -TaskSettings $taskSettings `
            -TaskType $taskPlan.Type `
            -ResolvedConfigPath $resolvedConfigPath `
            -ConfigPathWasExplicit $configPathWasExplicit

        if ($ValidateOnly) {
            $scheduleText = if ($taskPlan.Type -eq "Backup" -or $taskPlan.Type -eq "Maintenance") {
                "щодня о $($taskSettings.DailyAt)"
            } elseif ($taskPlan.Type -eq "Recovery") {
                "після старту сервера (затримка $($taskSettings.StartupDelayMinutes) хв.; профіль робочого часу)"
            } elseif ($taskPlan.Type -eq "BAZASync") {
                "кожні $($taskSettings.RepeatEveryHours) год., починаючи з $($taskSettings.StartAt)"
            } elseif ($taskPlan.Type -eq "RestoreVerify") {
                "щотижня ($($taskSettings.WeeklyOn)) о $($taskSettings.At)"
            } else {
                if (([int]$taskSettings.RepeatEveryMinutes % 60) -eq 0) {
                    "кожні $([int]$taskSettings.RepeatEveryMinutes / 60) год., починаючи з $($taskSettings.StartAt)"
                } else {
                    "кожні $($taskSettings.RepeatEveryMinutes) хв., починаючи з $($taskSettings.StartAt)"
                }
            }
            Write-Host "[ПЕРЕВІРКА] $taskPath$taskName — $scheduleText" -ForegroundColor Cyan
            $taskSummaries.Add([pscustomobject]@{
                Name = $taskName
                Status = 'БУДЕ ВСТАНОВЛЕНО'
                Account = [string]$schedulerSettings.RunAsUser
                NextRun = $scheduleText
            })
            continue
        }

        # TASK_CREATE_OR_UPDATE = 6. Пароль не потрібний для InteractiveToken
        # та вбудованих ServiceAccount.
        $registeredTask = $taskFolder.RegisterTaskDefinition(
            $taskName,
            $definition.Definition,
            6,
            $definition.UserId,
            $null,
            $definition.LogonType,
            $null
        )
        $registeredTask = $taskFolder.GetTask($taskName)
        if ($null -eq $registeredTask -or -not $registeredTask.Enabled) {
            throw "Task Scheduler не підтвердив активну реєстрацію '$taskPath$taskName'"
        }
        $actualTaskUser = [string]$registeredTask.Definition.Principal.UserId
        if (-not (Test-BRAVOAccountIdentityEquivalent `
                -ExpectedAccount ([string]$schedulerSettings.RunAsUser) `
                -ActualAccount $actualTaskUser)) {
            $expectedTaskSid = ConvertTo-BRAVOAccountSidValue `
                -AccountName ([string]$schedulerSettings.RunAsUser)
            $actualTaskSid = ConvertTo-BRAVOAccountSidValue `
                -AccountName $actualTaskUser
            throw (
                "Завдання '$taskPath$taskName' зареєстровано для " +
                "'$actualTaskUser' (SID='$actualTaskSid') замість " +
                "'$($schedulerSettings.RunAsUser)' (SID='$expectedTaskSid')"
            )
        }
        Write-Host "Завдання встановлено: $($registeredTask.Path)" -ForegroundColor Green
        $nextRunRaw = try { $registeredTask.NextRunTime } catch { $null }
        $nextRunText = Format-BRAVOInstalledTaskSummaryNextRun `
            -TaskType $taskPlan.Type `
            -TaskSettings $taskSettings `
            -NextRunTime $nextRunRaw
        $taskSummaries.Add([pscustomobject]@{
            Name = $taskName
            Status = if ($null -eq $existingTaskBeforeChange) { 'INSTALLED' } else { 'UPDATED' }
            Account = $actualTaskUser
            NextRun = $nextRunText
        })
    }

    $installationCommitted = $true

    if (-not $ValidateOnly -and
        $schedulerSettings.LegacyTaskPath -and $schedulerSettings.LegacyTaskNames) {
        $legacyTaskPath = ConvertTo-BRAVOTaskPath -TaskPath ([string]$schedulerSettings.LegacyTaskPath)
        $legacyFolder = Get-BRAVOScheduledTaskFolder `
            -TaskService $taskService `
            -TaskPath $legacyTaskPath
        foreach ($legacyTaskName in @($schedulerSettings.LegacyTaskNames)) {
            $legacyTask = Get-BRAVORegisteredTask `
                -TaskFolder $legacyFolder `
                -TaskName ([string]$legacyTaskName)
            if (-not $legacyTask) {
                continue
            }
            if ([int]$legacyTask.State -eq 4) {
                Write-Host "Старе завдання зараз виконується і залишене без змін: $legacyTaskPath$legacyTaskName" -ForegroundColor Yellow
                continue
            }
            try {
                $legacyFolder.DeleteTask([string]$legacyTaskName, 0)
                Write-Host "Старе завдання видалено після міграції: $legacyTaskPath$legacyTaskName" -ForegroundColor Yellow
            } catch {
                Write-Warning "Нове завдання вже встановлено, але старе '$legacyTaskPath$legacyTaskName' не видалено: $($_.Exception.Message)"
            }
        }
    }
    Write-BRAVOTasksInstallStep -Name 'Перевірка конфігурації' -Status OK -Details $(
        if ($ValidateOnly) { 'Конфігурація планувальника коректна. Системні зміни не виконувалися.' }
        else { 'Налаштування планувальника BRAVO завершено.' }
    )

    if ($taskSummaries.Count -gt 0) {
        Write-BRAVOResultBlankLine
        Write-Host 'Завдання:'
        foreach ($taskSummary in $taskSummaries) {
            Write-BRAVOResultBlankLine
            Write-Host ("  {0}" -f $taskSummary.Name)
            $taskStatusColor = switch ($taskSummary.Status) {
                { $_ -in @('INSTALLED', 'UPDATED') } { [ConsoleColor]::Green }
                'БУДЕ ВСТАНОВЛЕНО' { [ConsoleColor]::Cyan }
                default { [ConsoleColor]::Yellow }
            }
            Write-Host '    Статус:       ' -NoNewline
            Write-Host $taskSummary.Status -ForegroundColor $taskStatusColor
            if (-not [string]::IsNullOrWhiteSpace($taskSummary.Account)) {
                Write-Host ("    Обліковий:    {0}" -f $taskSummary.Account)
            }
            if (-not [string]::IsNullOrWhiteSpace($taskSummary.NextRun)) {
                Write-Host ("    Наступний:    {0}" -f $taskSummary.NextRun)
            }
        }
    }

    $installedCount = @($taskSummaries | Where-Object { $_.Status -eq 'INSTALLED' }).Count
    $updatedCount = @($taskSummaries | Where-Object { $_.Status -eq 'UPDATED' }).Count
    $plannedCount = @($taskSummaries | Where-Object { $_.Status -in @('БУДЕ ВСТАНОВЛЕНО', 'БУДЕ ВИМКНЕНО') }).Count

    Write-BRAVOResultBlankLine
    Write-BRAVOSeparator
    Write-Host ' РЕЗУЛЬТАТ'
    Write-BRAVOSeparator
    Write-BRAVOResultField -Label 'Статус' -Value 'УСПІШНО' -Color ([ConsoleColor]::Green)
    if ($ValidateOnly) {
        Write-BRAVOResultField -Label 'Заплановано' -Value ([string]$plannedCount)
    } else {
        Write-BRAVOResultField -Label 'Встановлено' -Value ([string]$installedCount)
        Write-BRAVOResultField -Label 'Оновлено' -Value ([string]$updatedCount)
        Write-BRAVOResultField -Label 'Помилок' -Value '0'
    }
    Write-BRAVOSeparator
    Complete-BRAVOHelperLog -ExitCode 0
} catch {
    if (-not $ValidateOnly -and
        -not $installationCommitted -and
        $null -ne $taskFolder -and
        $rollbackRecords.Count -gt 0) {
        Write-Warning "Помилка інсталяції; відновлення попередніх визначень завдань..."
        $recordsToRestore = @($rollbackRecords)
        [array]::Reverse($recordsToRestore)
        foreach ($record in $recordsToRestore) {
            try {
                if ($record.Existed) {
                    $restoredTask = $taskFolder.RegisterTask(
                        [string]$record.TaskName,
                        [string]$record.Xml,
                        6,
                        $null,
                        $null,
                        0,
                        $null
                    )
                    $restoredTask.Enabled = [bool]$record.Enabled
                } else {
                    $newTask = Get-BRAVORegisteredTask `
                        -TaskFolder $taskFolder `
                        -TaskName ([string]$record.TaskName)
                    if ($null -ne $newTask) {
                        $taskFolder.DeleteTask([string]$record.TaskName, 0)
                    }
                }
            } catch {
                Write-Warning "Rollback '$($record.TaskName)' не завершено: $($_.Exception.Message)"
            }
        }
    }
    Write-BRAVOResultBlankLine
    Write-BRAVOSeparator
    Write-Host ' РЕЗУЛЬТАТ'
    Write-BRAVOSeparator
    Write-BRAVOResultField -Label 'Статус' -Value 'ПОМИЛКА' -Color ([ConsoleColor]::Red)
    Write-BRAVOResultField -Label 'Причина' -Value $_.Exception.Message
    Write-BRAVOSeparator
    Write-Error "Не вдалося налаштувати завдання: $($_.Exception.Message)"
    Complete-BRAVOHelperLog -ExitCode 1
}
