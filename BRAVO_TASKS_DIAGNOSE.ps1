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
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "config не знайдено: $ConfigPath"
    }
    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $resolvedConfigPath -Parent
    $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration -ConfigRoot $configRoot -ConfigPath $resolvedConfigPath

    if (-not $InspectOnly -and
        [string]$schedulerSettings.RunAsUser -in @("SYSTEM", "NT AUTHORITY\SYSTEM")) {
        $profileRoot = [IO.Path]::GetFullPath(
            [Environment]::GetFolderPath("UserProfile")
        ).TrimEnd("\") + "\"
        if (($configRoot.TrimEnd("\") + "\").StartsWith(
                $profileRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw (
                "SYSTEM dry-run не запускається з профілю користувача: " +
                "$configRoot. Перенесіть runtime до C:\LIMS\ARCHIV."
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
            (ConvertTo-BRAVOProcessArgument $PSCommandPath),
            "-ConfigPath",
            (ConvertTo-BRAVOProcessArgument $resolvedConfigPath)
        )
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
    $dryRunPath = Join-Path $configRoot "BRAVO_DRY_RUN.ps1"
    if (-not (Test-Path -LiteralPath $dryRunPath -PathType Leaf)) {
        throw "dry-run не знайдено: $dryRunPath"
    }

    $taskService = New-Object -ComObject "Schedule.Service"
    $taskService.Connect()
    $taskFolder = Get-BRAVOTaskFolder `
        -Service $taskService `
        -TaskPath ([string]$schedulerSettings.TaskPath)

    Write-Host ""
    Write-Host "=== ДІАГНОСТИКА ПОСТІЙНИХ ЗАВДАНЬ ===" -ForegroundColor Cyan
    $registrationFailed = $false
    foreach ($taskType in @("Backup", "Maintenance", "Health", "Recovery")) {
        $settings = $schedulerSettings[$taskType]
        if ($null -eq $settings -or -not [bool]$settings.Enabled) {
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
        $color = if ($lastResult -in @(0, 0x00041300, 0x00041301, 0x00041303)) {
            "Green"
        } else {
            "Yellow"
        }
        Write-Host (
            "[INFO] $($registeredTask.Path): enabled=$($registeredTask.Enabled); " +
            "state=$($registeredTask.State); last=0x$($lastResult.ToString('X8')) ($description); " +
            "lastRun=$($registeredTask.LastRunTime); nextRun=$($registeredTask.NextRunTime)"
        ) -ForegroundColor $color

        foreach ($action in @($registeredTask.Definition.Actions)) {
            if (-not (Test-Path -LiteralPath ([string]$action.Path) -PathType Leaf)) {
                Write-Host "[FAIL] Action executable не знайдено: $($action.Path)" -ForegroundColor Red
                $registrationFailed = $true
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$action.WorkingDirectory) -and
                -not (Test-Path -LiteralPath ([string]$action.WorkingDirectory) -PathType Container)) {
                Write-Host "[FAIL] WorkingDirectory не знайдено: $($action.WorkingDirectory)" -ForegroundColor Red
                $registrationFailed = $true
            }
        }
    }

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
            (ConvertTo-BRAVOProcessArgument $dryRunPath),
            "-ConfigPath",
            (ConvertTo-BRAVOProcessArgument $resolvedConfigPath),
            "-RequireScheduledTasks",
            "-ResultPath",
            (ConvertTo-BRAVOProcessArgument $resultPath)
        )
        if ($TestAccess) { $argumentParts += "-TestAccess" }
        if ($SendTestNotification) { $argumentParts += "-SendTestNotification" }
        $action.Arguments = $argumentParts -join " "
        $action.WorkingDirectory = $configRoot

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
