[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$TestAccess,
    [switch]$SendTestNotification,
    [switch]$InspectOnly,
    [switch]$NoElevation
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

$ErrorActionPreference = "Stop"
$scriptRoot = if ($PSCommandPath) {
    Split-Path -Path $PSCommandPath -Parent
} else {
    [Environment]::CurrentDirectory
}
$systemHelpersPath = Join-Path $scriptRoot 'modules\BRAVO.System\BRAVO.System.psd1'
if (-not (Test-Path -LiteralPath $systemHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль системних helpers: $systemHelpersPath"
}
Import-Module -Name $systemHelpersPath -ErrorAction Stop
# SID-based identity helpers (Test-BRAVOAccountIdentityEquivalent /
# ConvertTo-BRAVOAccountSidValue) — той самий механізм, що й у Installer:
# порівняння облікового запису завдання мовно-незалежно (локалізоване
# "СИСТЕМА" == SYSTEM == S-1-5-18).
$compatibilityHelpersPath = Join-Path $scriptRoot 'modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1'
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль сумісності: $compatibilityHelpersPath"
}
Import-Module -Name $compatibilityHelpersPath -ErrorAction Stop
# P0 Configuration Foundation (PR C): свідомий намір оператора фіксується
# ТУТ, на межі справжнього виклику скрипта, ДО підстановки auto-дефолту.
$configPathWasExplicit = $PSBoundParameters.ContainsKey('ConfigPath') -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot "BRAVO.config"
}





function Get-BRAVOTaskResultDescription {
    param([int64]$ResultCode)

    $unsigned = [Convert]::ToUInt32($ResultCode -band 0xffffffffL)
    switch ($unsigned) {
        0 { return "успішно" }
        0x00041300 { return "завдання готове до запуску" }
        0x00041301 { return "завдання зараз виконується" }
        0x00041302 { return "завдання вимкнено" }
        0x00041303 { return "завдання ще не запускалося" }
        0x00041306 { return "останній запуск завершено планувальником" }
        2147942402 { return "не знайдено файл у Action або config" }
        2147942405 { return "відмовлено в доступі" }
        2147942667 { return "некоректний робочий каталог" }
        2147943726 { return "помилка входу облікового запису" }
        2147750671 { return "для завдання не знайдено обліковий запис" }
        2147750687 { return "обмеження безпеки облікового запису" }
        default { return "невідомий код" }
    }
}

function Format-BRAVODiagnoseTaskNextRun {
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

function Set-BRAVOPrivateDirectoryAcl {
    param([string]$Path)

    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $none = [Security.AccessControl.PropagationFlags]::None
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
    foreach ($sidText in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $none,
            $allow
        )))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-BRAVOMappedNetworkDrive {
    # Заплановане завдання від NT AUTHORITY\SYSTEM не бачить дискових
    # підключень користувача: буква Z: існує лише в його інтерактивному
    # сеансі. Такий шлях у конфігурації працює під час ручного запуску й
    # мовчки зникає вночі — тому це FAIL, а не інформація.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^([A-Za-z]):[\\/]') {
        return $false
    }
    try {
        $driveInfo = New-Object System.IO.DriveInfo($Matches[1] + ":\")
        return ($driveInfo.DriveType -eq [System.IO.DriveType]::Network)
    } catch {
        return $false
    }
}

function Test-BRAVOScheduledTaskDefinition {
    # Перевірка ФАКТИЧНО зареєстрованого визначення, а не того, що мав би
    # створити інсталятор: завдання могли відредагувати вручну в оснастці,
    # і саме розбіжність між "як встановлювали" і "як зараз" пояснює нічні
    # відмови, яких не видно в жодному лозі.
    param(
        [string]$TaskType,
        $RegisteredTask,
        [hashtable]$TaskSettings,
        [string]$ExpectedConfigPath,
        # P0 Configuration Foundation (PR C, Секція 6): AUTO-встановлені
        # завдання НЕ повинні мати -ConfigPath у аргументах взагалі (див.
        # New-BRAVOTaskDefinition) — тому "правильний" стан для AUTO
        # означає ВІДСУТНІСТЬ токена, а не його наявність із будь-яким
        # значенням. $false тут — дефолт, що відповідає найпоширенішому
        # (AUTO) сценарію; викликач передає $true лише коли оператор
        # свідомо встановлював через -ConfigPath.
        [bool]$ConfigPathWasExplicit,
        [string]$ExpectedExecutable,
        [string[]]$RequiredArgumentTokens,
        [Parameter(Mandatory = $true)][string]$ExpectedAccount,
        [Parameter(Mandatory = $true)][int]$ExpectedLogonType,
        [Parameter(Mandatory = $true)][int]$ExpectedRunLevel
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $definition = $RegisteredTask.Definition

    if (-not [bool]$RegisteredTask.Enabled) {
        $problems.Add("завдання вимкнено (Enabled=false)")
    }

    $principal = $definition.Principal
    $userId = [string]$principal.UserId
    # Порівняння за SID, а не за текстом: на локалізованій Windows Task
    # Scheduler повертає локалізовану назву ("СИСТЕМА"), яка мовно-незалежно
    # відповідає SYSTEM/S-1-5-18. Очікуваний акаунт береться з effective
    # schedulerSettings (той самий, який застосував Installer), а не хардкодиться.
    if (-not (Test-BRAVOAccountIdentityEquivalent `
            -ExpectedAccount $ExpectedAccount `
            -ActualAccount $userId)) {
        $expectedSid = ConvertTo-BRAVOAccountSidValue -AccountName $ExpectedAccount
        $actualSid = ConvertTo-BRAVOAccountSidValue -AccountName $userId
        $problems.Add(
            "Principal.UserId='$userId' (SID='$actualSid'), очікується " +
            "'$ExpectedAccount' (SID='$expectedSid')"
        )
    }
    if ([int]$principal.LogonType -ne $ExpectedLogonType) {
        $problems.Add("LogonType=$($principal.LogonType), очікується $ExpectedLogonType")
    }
    if ([int]$principal.RunLevel -ne $ExpectedRunLevel) {
        $problems.Add("RunLevel=$($principal.RunLevel), очікується $ExpectedRunLevel")
    }

    $executionTimeLimit = [string]$definition.Settings.ExecutionTimeLimit
    if ([string]::IsNullOrWhiteSpace($executionTimeLimit) -or $executionTimeLimit -eq "PT0S") {
        $problems.Add("ExecutionTimeLimit не задано")
    }

    $actions = @($definition.Actions)
    if ($actions.Count -eq 0) {
        $problems.Add("у завданні немає жодної дії")
    }
    foreach ($action in $actions) {
        $actionPath = [string]$action.Path
        if (-not (Test-Path -LiteralPath $actionPath -PathType Leaf)) {
            $problems.Add("Action executable не знайдено: $actionPath")
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedExecutable) -and
            -not [string]::Equals(
                [IO.Path]::GetFullPath($actionPath),
                [IO.Path]::GetFullPath($ExpectedExecutable),
                [StringComparison]::OrdinalIgnoreCase)) {
            $problems.Add("Action.Path='$actionPath', у конфігурації '$ExpectedExecutable'")
        }

        $arguments = [string]$action.Arguments
        foreach ($token in @($RequiredArgumentTokens)) {
            if ($arguments -notlike "*$token*") {
                $problems.Add("в аргументах немає '$token'")
            }
        }

        $scriptPath = if (-not [string]::IsNullOrWhiteSpace([string]$TaskSettings.ScriptPath)) {
            [IO.Path]::GetFullPath([string]$TaskSettings.ScriptPath)
        } else {
            $null
        }
        if (-not [string]::IsNullOrWhiteSpace($scriptPath)) {
            if ($arguments -notlike "*-File `"$scriptPath`"*") {
                $problems.Add("-File не вказує на $scriptPath")
            }
            $expectedWorkingDirectory = Split-Path -Path $scriptPath -Parent
            $workingDirectory = [string]$action.WorkingDirectory
            if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
                $problems.Add("WorkingDirectory не задано (очікується $expectedWorkingDirectory)")
            } elseif (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
                $problems.Add("WorkingDirectory не знайдено: $workingDirectory")
            } elseif (-not [string]::Equals(
                    ([IO.Path]::GetFullPath($workingDirectory)).TrimEnd('\'),
                    $expectedWorkingDirectory.TrimEnd('\'),
                    [StringComparison]::OrdinalIgnoreCase)) {
                $problems.Add("WorkingDirectory='$workingDirectory', очікується '$expectedWorkingDirectory'")
            }
        }
        # P0 Configuration Foundation (PR C, Секція 6): AUTO/EXPLICIT
        # семантика симетрична New-BRAVOTaskDefinition — EXPLICIT вимагає
        # ТОЧНИЙ -ConfigPath, AUTO вимагає його ПОВНУ ВІДСУТНІСТЬ (не лише
        # "не перевіряємо"): застаріле завдання, встановлене до цього
        # фіксу (або відредаговане вручну), де AUTO-намір мав би НЕ мати
        # -ConfigPath, але фактично має — це реальна розбіжність "як
        # встановлювали" vs "як зараз", яку Diagnose існує саме для того,
        # щоб виявляти.
        if ($ConfigPathWasExplicit) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedConfigPath) -and
                $arguments -notlike "*-ConfigPath `"$ExpectedConfigPath`"*") {
                $problems.Add("-ConfigPath не вказує на $ExpectedConfigPath (EXPLICIT-режим)")
            }
        } elseif ($arguments -like "*-ConfigPath *") {
            $problems.Add("AUTO-режим (оператор не передавав -ConfigPath при інсталяції) не повинен мати -ConfigPath у аргументах завдання, але він присутній")
        }
        if (Test-BRAVOMappedNetworkDrive -Path $actionPath) {
            $problems.Add("Action.Path на підключеному мережевому диску: $actionPath — використайте UNC \\server\share\...")
        }
    }

    # RestoreVerify — єдиний weekly-тип: перевіряємо, що фактичний тригер
    # справді щотижневий і день збігається з конфігурацією. Маска — той
    # самий канонічний ConvertTo-BRAVODaysOfWeekMask (BRAVO.System), яким
    # Installer створює тригер: Diagnose не може розійтися з ним у правилах.
    if ($TaskType -eq 'RestoreVerify') {
        $weeklyTriggers = @(@($definition.Triggers) | Where-Object { [int]$_.Type -eq 3 })
        if ($weeklyTriggers.Count -eq 0) {
            $problems.Add("немає жодного weekly-тригера (TASK_TRIGGER_WEEKLY)")
        } else {
            $expectedDaysMask = ConvertTo-BRAVODaysOfWeekMask -DayOfWeek ([string]$TaskSettings.WeeklyOn)
            $actualDaysMask = [int]$weeklyTriggers[0].DaysOfWeek
            if ($actualDaysMask -ne $expectedDaysMask) {
                $problems.Add("DaysOfWeek=$actualDaysMask, очікується $expectedDaysMask ($($TaskSettings.WeeklyOn))")
            }
        }
    }

    return $problems.ToArray()
}

function Get-BRAVOTaskFolder {
    param($Service, [string]$TaskPath)
    $comPath = if ($TaskPath -eq "\") { "\" } else { $TaskPath.TrimEnd("\") }
    try {
        return $Service.GetFolder($comPath)
    } catch {
        return $null
    }
}

try {
    # P0 Configuration Foundation: BRAVO.config став опційним основним
    # override-шаром — попередня жорстка "файл мусить існувати" перевірка
    # (і Resolve-Path, який теж вимагав існування) дублювала те саме
    # рішення, яке Import-BravoConfiguration тепер приймає коректно сама.
    # GetFullPath (а не Resolve-Path) нормалізує шлях без вимоги існування.
    $resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $configRoot = Split-Path -Path $resolvedConfigPath -Parent
    $configurationLoaderPath = Join-Path $scriptRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $resolvedConfigPath `
        -RuntimeRoot $scriptRoot `
        -ConfigPathWasExplicit:$configPathWasExplicit

    if (-not $InspectOnly -and
        (ConvertTo-BRAVOAccountSidValue -AccountName ([string]$schedulerSettings.RunAsUser)) -eq 'S-1-5-18') {
        # Перевіряється розташування КОМПЛЕКТУ, а не каталогу конфігурації:
        # саме комплект виконується від SYSTEM, і саме він має лежати в
        # захищеному каталозі. Конфігурація може лежати де завгодно.
        $profileRoot = [IO.Path]::GetFullPath(
            [Environment]::GetFolderPath("UserProfile")
        ).TrimEnd("\") + "\"
        if (($scriptRoot.TrimEnd("\") + "\").StartsWith(
                $profileRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw (
                "SYSTEM dry-run не запускається з профілю користувача: $scriptRoot. " +
                "Заплановані завдання виконуються від NT AUTHORITY\SYSTEM, а каталог " +
                "профілю не є для нього захищеним розташуванням. Перенесіть комплект " +
                "у локальний захищений каталог — наприклад C:\Program Files\BRAVO-Toolkit, C:\ProgramData\BRAVO " +
                "або D:\BRAVO_RUNTIME (ACL: SYSTEM/Administrators — FullControl, " +
                "Users — ReadAndExecute). Корені даних (LIMSRoot/SystemLogRoot/BackupRoot) " +
                "переносити не потрібно: вони задаються в BRAVO.config незалежно."
            )
        }
    }

    if (-not $InspectOnly -and -not (Test-IsAdministrator)) {
        if ($NoElevation) {
            throw "для SYSTEM dry-run потрібні права адміністратора"
        }
        $arguments = @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            (ConvertTo-BRAVOProcessArgument $PSCommandPath)
        )
        # P0 Configuration Foundation (PR C, Секція 6): зберігаємо той
        # самий AUTO/EXPLICIT намір при власному UAC relaunch Diagnose-а.
        if ($configPathWasExplicit) {
            $arguments += "-ConfigPath"
            $arguments += (ConvertTo-BRAVOProcessArgument $resolvedConfigPath)
        }
        if ($TestAccess) { $arguments += "-TestAccess" }
        if ($SendTestNotification) { $arguments += "-SendTestNotification" }
        $process = Start-Process `
            -FilePath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -ArgumentList $arguments `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -WindowStyle Normal
        Complete-BRAVOHelperLog -ExitCode $process.ExitCode
    }

    if ($null -eq $schedulerSettings) {
        throw "у config відсутній schedulerSettings"
    }
    # Dry Run — runtime-ресурс комплекту, тому береться з RuntimeRoot ($scriptRoot),
    # а не з каталогу конфігурації (config може бути переданий через -ConfigPath
    # з іншого місця).
    $dryRunPath = Join-Path $scriptRoot "BRAVO_DRY_RUN.ps1"
    if (-not (Test-Path -LiteralPath $dryRunPath -PathType Leaf)) {
        throw "dry-run не знайдено: $dryRunPath"
    }

    $taskService = New-Object -ComObject "Schedule.Service"
    $taskService.Connect()
    $taskFolder = Get-BRAVOTaskFolder `
        -Service $taskService `
        -TaskPath ([string]$schedulerSettings.TaskPath)

    Write-Host ""
    Write-Host "=== КОРЕНІ ШЛЯХІВ ===" -ForegroundColor Cyan
    $pathRootsFailed = $false
    $diagnosticRoots = [ordered]@{
        'RuntimeRoot'      = $scriptRoot
        'RuntimeLogRoot'   = [string]$global:runtimeLogRoot
        'ConfigPath'       = $resolvedConfigPath
        'EffectiveLIMSRoot' = [string]$global:effectiveLimsRoot
        'SystemLogRoot'    = [string]$global:systemLogRoot
        'BackupRoot'       = [string]$global:backupRootPath
        'StateRoot'        = [string]$global:stateRoot
    }
    foreach ($rootEntry in $diagnosticRoots.GetEnumerator()) {
        if (Test-BRAVOMappedNetworkDrive -Path ([string]$rootEntry.Value)) {
            Write-Host (
                "[FAIL] $($rootEntry.Key): $($rootEntry.Value) — підключений мережевий диск. " +
                "SYSTEM не бачить дискових підключень користувача; використайте UNC \\server\share\..."
            ) -ForegroundColor Red
            $pathRootsFailed = $true
        } else {
            Write-Host "[INFO] $($rootEntry.Key): $($rootEntry.Value)" -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "=== ДІАГНОСТИКА ПОСТІЙНИХ ЗАВДАНЬ ===" -ForegroundColor Cyan
    $registrationFailed = $pathRootsFailed
    # BAZASync входить у перелік нарівні з рештою: раніше він був єдиним
    # production-завданням поза діагностикою, тобто єдиним, чия неправильна
    # реєстрація виявлялася б лише з відсутності даних у хмарі.
    $taskArgumentExpectations = @{
        Backup        = @('-NoPause')
        Maintenance   = @('-NoPause')
        Health        = @('-NoPause', '-NotifyOnSuccess')
        Recovery      = @('-NoPause', '-RunMissedRestoreOnly')
        BAZASync      = @('-NoPause', '-SyncBAZA')
        RestoreVerify = @('-NoPause', '-NotifyOnSuccess')
    }
    foreach ($taskType in @("Backup", "Maintenance", "Health", "Recovery", "BAZASync", "RestoreVerify")) {
        $settings = $schedulerSettings[$taskType]
        if ($null -eq $settings -or -not [bool]$settings.Enabled) {
            Write-Host "[SKIP] ${taskType}: вимкнено в конфігурації" -ForegroundColor Gray
            continue
        }
        $registeredTask = $null
        if ($null -ne $taskFolder) {
            try {
                $registeredTask = $taskFolder.GetTask([string]$settings.TaskName)
            } catch {
                $registeredTask = $null
            }
        }
        if ($null -eq $registeredTask) {
            Write-Host "[FAIL] ${taskType}: завдання не зареєстровано" -ForegroundColor Red
            $registrationFailed = $true
            continue
        }

        $lastResult = [Convert]::ToUInt32(
            ([int64]$registeredTask.LastTaskResult) -band 0xffffffffL
        )
        $description = Get-BRAVOTaskResultDescription -ResultCode $lastResult
        $lastResultIsBenign = $lastResult -in @(0, 0x00041300, 0x00041301, 0x00041303)
        $color = if ($lastResultIsBenign) { "Green" } else { "Yellow" }
        # Recovery — boot-тригер: NextRunTime повертає sentinel 30.12.1899.
        # LastRunTime для завдання, що ще не запускалося, — так само sentinel.
        $nextRunRaw = try { $registeredTask.NextRunTime } catch { $null }
        $nextRunText = Format-BRAVODiagnoseTaskNextRun `
            -TaskType $taskType `
            -TaskSettings $settings `
            -NextRunTime $nextRunRaw
        $lastRunRaw = try { $registeredTask.LastRunTime } catch { $null }
        $lastRunText = if ($lastRunRaw -is [datetime] -and $lastRunRaw.Year -gt 1900) {
            $lastRunRaw.ToString('dd.MM.yyyy HH:mm')
        } else {
            'ще не запускалося'
        }
        Write-Host (
            "[INFO] $($registeredTask.Path): enabled=$($registeredTask.Enabled); " +
            "state=$($registeredTask.State); last=0x$($lastResult.ToString('X8')) ($description); " +
            "lastRun=$lastRunText; nextRun=$nextRunText"
        ) -ForegroundColor $color

        $requiredTokens = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy Bypass')
        if ($taskArgumentExpectations.ContainsKey($taskType)) {
            $requiredTokens += $taskArgumentExpectations[$taskType]
        }
        if ($taskType -eq 'Health' -and [bool]$settings.SkipIfBackupTaskRunning) {
            $requiredTokens += '-SkipIfBackupTaskRunning'
        }
        # Expected principal — той самий канонічний розрахунок, що застосовує
        # Installer. Diagnose перевіряє фактичне визначення проти НЬОГО, а не
        # проти жорстко прописаних SYSTEM/5/1.
        $expectedPrincipal = Get-BRAVOExpectedSchedulerPrincipal -SchedulerSettings $schedulerSettings
        $definitionProblems = @(Test-BRAVOScheduledTaskDefinition `
            -TaskType $taskType `
            -RegisteredTask $registeredTask `
            -TaskSettings $settings `
            -ExpectedConfigPath $resolvedConfigPath `
            -ConfigPathWasExplicit $configPathWasExplicit `
            -ExpectedExecutable ([string]$schedulerSettings.PowerShellExecutable) `
            -RequiredArgumentTokens $requiredTokens `
            -ExpectedAccount $expectedPrincipal.UserId `
            -ExpectedLogonType $expectedPrincipal.LogonType `
            -ExpectedRunLevel $expectedPrincipal.RunLevel)
        if ($definitionProblems.Count -eq 0) {
            Write-Host (
                "[PASS] ${taskType}: визначення завдання відповідає конфігурації " +
                "(акаунт '$($expectedPrincipal.UserId)' / LogonType=$($expectedPrincipal.LogonType) / RunLevel=$($expectedPrincipal.RunLevel))"
            ) -ForegroundColor Green
            # Definition validation і execution history — РІЗНІ поняття. Якщо
            # поточне визначення правильне, але останній РЕЗУЛЬТАТ ненульовий,
            # це історія попереднього запуску (можливо, до цього оновлення
            # definition), а не помилка поточної конфігурації.
            if (-not $lastResultIsBenign) {
                Write-Host (
                    "[INFO] ${taskType}: last=0x$($lastResult.ToString('X8')) ($description) — " +
                    "результат ОСТАННЬОГО виконання, а не перевірка поточного визначення " +
                    "(яке щойно пройшло). Якщо definition змінювали, дочекайтеся наступного запуску."
                ) -ForegroundColor DarkGray
            }
        } else {
            foreach ($problem in $definitionProblems) {
                Write-Host "[FAIL] ${taskType}: $problem" -ForegroundColor Red
            }
            $registrationFailed = $true
        }
    }
    Write-Host (
        "[INFO] MultipleInstances=$($schedulerSettings.MultipleInstances): за політикою IgnoreNew " +
        "новий тригер ПРОПУСКАЄТЬСЯ, якщо попередній екземпляр ще виконується."
    ) -ForegroundColor Gray

    if ($InspectOnly) {
        if ($registrationFailed) {
            Complete-BRAVOHelperLog -ExitCode 1
        }
        Write-Host "Реєстрацію постійних завдань перевірено." -ForegroundColor Green
        Complete-BRAVOHelperLog -ExitCode 0
    }

    Write-Host ""
    Write-Host "=== END-TO-END DRY-RUN ВІД NT AUTHORITY\SYSTEM ===" -ForegroundColor Cyan
    $diagnosticRoot = Join-Path (
        [Environment]::GetFolderPath("CommonApplicationData")
    ) "BRAVO\TaskDiagnostics"
    if (-not (Test-Path -LiteralPath $diagnosticRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $diagnosticRoot -Force | Out-Null
    }
    $workingDirectory = Join-Path $diagnosticRoot ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    Set-BRAVOPrivateDirectoryAcl -Path $workingDirectory
    $resultPath = Join-Path $workingDirectory "dry-run.json"
    $temporaryTaskName = "BRAVO_SYSTEM_DRY_RUN_" + ([guid]::NewGuid().ToString("N"))
    $rootTaskFolder = $taskService.GetFolder("\")

    try {
        $definition = $taskService.NewTask(0)
        $definition.RegistrationInfo.Description = "Temporary BRAVO SYSTEM dry-run"
        $definition.Principal.UserId = "SYSTEM"
        $definition.Principal.LogonType = 5
        $definition.Principal.RunLevel = 1
        $definition.Settings.Enabled = $true
        $definition.Settings.ExecutionTimeLimit = "PT10M"
        $definition.Settings.DisallowStartIfOnBatteries = $false
        $definition.Settings.StopIfGoingOnBatteries = $false
        $action = $definition.Actions.Create(0)
        $action.Path = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $argumentParts = @(
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            (ConvertTo-BRAVOProcessArgument $dryRunPath)
        )
        # P0 Configuration Foundation (PR C, Секція 6): тимчасове SYSTEM
        # dry-run завдання має відтворювати ТОЙ САМИЙ AUTO/EXPLICIT намір,
        # що й реальні встановлені завдання — інакше діагностика
        # перевіряла б інший сценарій, ніж той, що реально встановлено.
        if ($configPathWasExplicit) {
            $argumentParts += "-ConfigPath"
            $argumentParts += (ConvertTo-BRAVOProcessArgument $resolvedConfigPath)
        }
        $argumentParts += "-RequireScheduledTasks"
        $argumentParts += "-ResultPath"
        $argumentParts += (ConvertTo-BRAVOProcessArgument $resultPath)
        if ($TestAccess) { $argumentParts += "-TestAccess" }
        if ($SendTestNotification) { $argumentParts += "-SendTestNotification" }
        $action.Arguments = $argumentParts -join " "
        # WorkingDirectory тимчасового SYSTEM dry-run — RuntimeRoot (де лежить
        # BRAVO_DRY_RUN.ps1 і modules), а не каталог конфігурації.
        $action.WorkingDirectory = $scriptRoot

        $temporaryTask = $rootTaskFolder.RegisterTaskDefinition(
            $temporaryTaskName,
            $definition,
            6,
            "SYSTEM",
            $null,
            5,
            $null
        )
        [void]$temporaryTask.Run($null)

        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline -and
            -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            $temporaryTask = $rootTaskFolder.GetTask($temporaryTaskName)
            $lastResult = [Convert]::ToUInt32(
                ([int64]$temporaryTask.LastTaskResult) -band 0xffffffffL
            )
            throw (
                "SYSTEM dry-run не створив результат; state=$($temporaryTask.State); " +
                "last=0x$($lastResult.ToString('X8')) " +
                "($(Get-BRAVOTaskResultDescription $lastResult))"
            )
        }

        # ConvertFrom-Json у Windows PowerShell 5.1 віддає JSON-масив ОДНИМ
        # об'єктом, не розгортаючи його в конвеєр. Через це @(... | ConvertFrom-Json)
        # давало масив з єдиного елемента-масиву: цикл нижче виконувався один
        # раз, а $result.Status ставав System.Object[] і друкувався як
        # "[PASS PASS FAIL ...] Конфігурація Скрипти ...: шлях шлях шлях" —
        # увесь результат SYSTEM dry-run в одному нечитабельному рядку.
        # Присвоєння у змінну перед @() зберігає розгортання.
        $parsedResults = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
        $results = @($parsedResults)
        foreach ($result in $results) {
            $color = switch ([string]$result.Status) {
                "PASS" { "Green" }
                "FAIL" { "Red" }
                "WARN" { "Yellow" }
                default { "Gray" }
            }
            Write-Host (
                "[$($result.Status)] $($result.Category) / $($result.Name): $($result.Detail)"
            ) -ForegroundColor $color
        }
        $dryRunFailed = @($results | Where-Object { $_.Status -eq "FAIL" }).Count -gt 0
    } finally {
        try {
            $temporaryTask = $rootTaskFolder.GetTask($temporaryTaskName)
            if ([int]$temporaryTask.State -eq 4) {
                $temporaryTask.Stop(0)
            }
            $rootTaskFolder.DeleteTask($temporaryTaskName, 0)
        } catch {
            # Тимчасове завдання створюється лише для перевірки доступу від
            # SYSTEM. Якщо його не вдалося прибрати, воно лишається в
            # Планувальнику й наступний запуск діагностики впаде на
            # створенні завдання з тим самим іменем — тому попереджаємо
            # явно, з іменем, яке треба видалити вручну.
            Write-Warning (
                "Не вдалося видалити тимчасове завдання '$temporaryTaskName': " +
                "$($_.Exception.Message). Видаліть його вручну в Планувальнику завдань."
            )
        }
        if (Test-Path -LiteralPath $workingDirectory -PathType Container) {
            Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($registrationFailed -or $dryRunFailed) {
        Complete-BRAVOHelperLog -ExitCode 1
    }
    Write-Host "Завдання і доступ від SYSTEM перевірено успішно." -ForegroundColor Green
    Complete-BRAVOHelperLog -ExitCode 0
} catch {
    Write-Host "ПОМИЛКА ДІАГНОСТИКИ: $($_.Exception.Message)" -ForegroundColor Red
    Complete-BRAVOHelperLog -ExitCode 1
}
