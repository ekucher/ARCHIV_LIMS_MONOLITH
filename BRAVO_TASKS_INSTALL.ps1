[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ValidateOnly
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

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
            "наприклад C:\LIMS\ARCHIV."
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
        $acl = Get-Acl -LiteralPath $runtimeItem -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($administrators)
        foreach ($rule in @($acl.Access)) {
            [void]$acl.RemoveAccessRuleAll($rule)
        }
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

function ConvertTo-BRAVOLogonType {
    param([string]$Value)

    switch ($Value) {
        "Interactive" { return 3 }    # TASK_LOGON_INTERACTIVE_TOKEN
        "ServiceAccount" { return 5 } # TASK_LOGON_SERVICE_ACCOUNT
        default { throw "Непідтримуваний LogonType: $Value" }
    }
}

function New-BRAVOTaskDefinition {
    param(
        $TaskService,
        [hashtable]$TaskSettings,
        [ValidateSet("Backup", "Maintenance", "Health", "Recovery", "BAZASync")]
        [string]$TaskType,
        [string]$ResolvedConfigPath
    )

    # Task Scheduler 2.0 COM API доступний починаючи з Windows Vista/7 і
    # не залежить від модуля ScheduledTasks, якого немає у Windows 7.
    $definition = $TaskService.NewTask(0)
    $definition.RegistrationInfo.Description = [string]$TaskSettings.Description

    $definition.Settings.Enabled = $true
    $definition.Settings.StartWhenAvailable = [bool]$schedulerSettings.StartWhenAvailable
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

    $logonType = ConvertTo-BRAVOLogonType -Value ([string]$schedulerSettings.LogonType)
    $definition.Principal.UserId = [string]$schedulerSettings.RunAsUser
    $definition.Principal.LogonType = $logonType
    $definition.Principal.RunLevel = 1 # TASK_RUNLEVEL_HIGHEST

    $triggerTime = if ($TaskType -eq "Health" -or $TaskType -eq "BAZASync") {
        ConvertTo-ScheduleTime `
            -Value $TaskSettings.StartAt `
            -SettingName "$TaskType.StartAt"
    } elseif ($TaskType -eq "Recovery") {
        $null
    } else {
        ConvertTo-ScheduleTime -Value $TaskSettings.DailyAt -SettingName "$TaskType.DailyAt"
    }
    if ($TaskType -eq "Recovery") {
        $trigger = $definition.Triggers.Create(8) # TASK_TRIGGER_BOOT
        $delayMinutes = [math]::Max(0, [int]$TaskSettings.StartupDelayMinutes)
        if ($delayMinutes -gt 0) {
            $trigger.Delay = [System.Xml.XmlConvert]::ToString(
                [timespan]::FromMinutes($delayMinutes)
            )
        }
        $trigger.Enabled = $true
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
    if ($TaskType -eq "Recovery") {
        $trigger.Repetition.Interval = [System.Xml.XmlConvert]::ToString(
            [timespan]::FromMinutes([int]$TaskSettings.RetryEveryMinutes)
        )
        $trigger.Repetition.Duration = [System.Xml.XmlConvert]::ToString(
            [timespan]::FromHours([double]$TaskSettings.RetryDurationHours)
        )
        $trigger.Repetition.StopAtDurationEnd = $false
    }

    $scriptPath = (Resolve-Path -Path $TaskSettings.ScriptPath).Path
    $actionArguments = "-NoLogo -NoProfile -NonInteractive"
    $actionArguments += " -WindowStyle $($schedulerSettings.WindowStyle)"
    $actionArguments += " -ExecutionPolicy Bypass"
    $actionArguments += " -File `"$scriptPath`""
    $actionArguments += " -ConfigPath `"$ResolvedConfigPath`""
    if ($TaskType -eq "Health") {
        $actionArguments += " -NotifyOnSuccess -NoPause"
        if ($TaskSettings.SkipIfBackupTaskRunning) {
            $actionArguments += " -SkipIfBackupTaskRunning"
        }
    }
    if ($TaskType -eq "Recovery") {
        $actionArguments += " -RunMissedRestoreOnly"
    }
    if ($TaskType -eq "Backup") {
        $actionArguments += " -NoPause"
    }
    if ($TaskType -eq "BAZASync") {
        $actionArguments += " -SyncBAZA -NoPause"
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
        LogonType = $logonType
        UserId = [string]$schedulerSettings.RunAsUser
    }
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
    $runtimeRoot = Split-Path -Path $ResolvedConfigPath -Parent
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
        'BRAVO.System'
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
    $taskNames = @(
        [string]$schedulerSettings.Backup.TaskName,
        [string]$schedulerSettings.Maintenance.TaskName,
        [string]$schedulerSettings.Health.TaskName,
        [string]$schedulerSettings.Recovery.TaskName,
        [string]$schedulerSettings.BAZASync.TaskName
    )
    if (@($taskNames | Select-Object -Unique).Count -ne $taskNames.Count) {
        throw "Імена Backup, Maintenance, Health, Recovery і BAZASync завдань повинні відрізнятися"
    }

    foreach ($taskSettings in @(
        $schedulerSettings.Backup,
        $schedulerSettings.Maintenance,
        $schedulerSettings.Health,
        $schedulerSettings.Recovery,
        $schedulerSettings.BAZASync
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
    if ($schedulerSettings.Recovery.Enabled -and
        ([int]$schedulerSettings.Recovery.RetryEveryMinutes -lt 1 -or
         [int]$schedulerSettings.Recovery.RetryDurationHours -lt 1)) {
        throw "Recovery retry має мати інтервал і тривалість не менше 1"
    }
    if (-not (Test-Path -Path $ResolvedConfigPath -PathType Leaf)) {
        throw "Файл конфігурації не знайдено"
    }
}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    Write-Error "Файл конфігурації не знайдено: $ConfigPath"
    Complete-BRAVOHelperLog -ExitCode 1
}

$resolvedConfigPath = (Resolve-Path -Path $ConfigPath).Path
try {
    $configRoot = Split-Path -Path $resolvedConfigPath -Parent
    $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration `
        -ConfigRoot $configRoot `
        -ConfigPath $resolvedConfigPath

    $bazaSftpEnabled = $false
    if ($null -ne $componentSettings -and
        $null -ne $componentSettings.Synchronization) {
        $bazaSftpEnabled = [System.Convert]::ToBoolean(
            $componentSettings.Synchronization.BAZASFTP
        )
    }

    if (-not $schedulerSettings.Contains("BAZASync")) {
        $schedulerSettings.BAZASync = @{
            Enabled = $bazaSftpEnabled
            TaskName = "BRAVO BAZA Synchronization"
            Description = "Синхронізація BAZA_APP із хмарним SFTP кожні 4 години"
            ScriptPath = [string]$schedulerSettings.Backup.ScriptPath
            StartAt = "00:00"
            RepeatEveryHours = 4
            ExecutionTimeLimitHours = 2
        }
    } else {
        # BAZA Sync не повинен запускатися, якщо SFTP-синхронізацію BAZA
        # вимкнено у componentSettings.Synchronization.BAZASFTP.
        $schedulerSettings.BAZASync.Enabled = (
            [System.Convert]::ToBoolean($schedulerSettings.BAZASync.Enabled) -and
            $bazaSftpEnabled
        )
    }

    # Розклад є єдиним джерелом правди у BRAVO.config. Інсталятор не має
    # непомітно змінювати періодичність health-check під час реєстрації задач.

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
    $elevationArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$resolvedConfigPath`""
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
        [pscustomobject]@{ Type = "BAZASync"; Settings = $schedulerSettings.BAZASync }
    )

    $requireProtectedRuntime = (
        $schedulerSettings.Contains("RequireProtectedRuntime") -and
        [System.Convert]::ToBoolean($schedulerSettings.RequireProtectedRuntime)
    )
    $runtimeRoot = Split-Path -Path $resolvedConfigPath -Parent
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
                "перенесіть комплект до C:\LIMS\ARCHIV."
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
            Write-Host "[ПЕРЕВІРКА] Перед інсталяцією буде захищено ACL runtime: $runtimeRoot" -ForegroundColor Cyan
        }
    } else {
        if ($requireProtectedRuntime) {
            Set-BRAVOProtectedRuntimeAcl -RuntimeRoot $runtimeRoot
        } else {
            Write-Warning "RequireProtectedRuntime=false: SYSTEM виконуватиме файли без автоматичного hardening ACL."
        }
        Enable-BRAVOTaskSchedulerOperationalLog
    }

    $taskFolder = Get-BRAVOScheduledTaskFolder -TaskService $taskService -TaskPath $taskPath
    if (-not $ValidateOnly -and @($taskPlans | Where-Object { $_.Settings.Enabled }).Count -gt 0) {
        $taskFolder = Ensure-ScheduledTaskFolder -TaskService $taskService -TaskPath $taskPath
    }

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
            } else {
                Write-Host "Завдання вимкнено в конфігурації: $taskPath$taskName" -ForegroundColor DarkGray
            }
            continue
        }

        $definition = New-BRAVOTaskDefinition `
            -TaskService $taskService `
            -TaskSettings $taskSettings `
            -TaskType $taskPlan.Type `
            -ResolvedConfigPath $resolvedConfigPath

        if ($ValidateOnly) {
            $scheduleText = if ($taskPlan.Type -eq "Backup" -or $taskPlan.Type -eq "Maintenance") {
                "щодня о $($taskSettings.DailyAt)"
            } elseif ($taskPlan.Type -eq "Recovery") {
                "після старту сервера; затримка $($taskSettings.StartupDelayMinutes) хв."
            } elseif ($taskPlan.Type -eq "BAZASync") {
                "кожні $($taskSettings.RepeatEveryHours) год., починаючи з $($taskSettings.StartAt)"
            } else {
                if (([int]$taskSettings.RepeatEveryMinutes % 60) -eq 0) {
                    "кожні $([int]$taskSettings.RepeatEveryMinutes / 60) год., починаючи з $($taskSettings.StartAt)"
                } else {
                    "кожні $($taskSettings.RepeatEveryMinutes) хв., починаючи з $($taskSettings.StartAt)"
                }
            }
            Write-Host "[ПЕРЕВІРКА] $taskPath$taskName — $scheduleText" -ForegroundColor Cyan
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
    }

    $installationCommitted = $true

    if ($ValidateOnly) {
        Write-Host "Конфігурація планувальника коректна. Системні зміни не виконувалися." -ForegroundColor Green
    } else {
        if ($schedulerSettings.LegacyTaskPath -and $schedulerSettings.LegacyTaskNames) {
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
        Write-Host "Налаштування планувальника BRAVO завершено." -ForegroundColor Green
    }
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
    Write-Error "Не вдалося налаштувати завдання: $($_.Exception.Message)"
    Complete-BRAVOHelperLog -ExitCode 1
}
