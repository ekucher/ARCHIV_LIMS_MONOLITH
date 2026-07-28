[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ValidateOnly,
    [switch]$StopRunningTasks
)

$helperLoggingPath = Join-Path $PSScriptRoot "BRAVO_HELPER_LOGGING.ps1"
. $helperLoggingPath
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

$bravoScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Path $PSCommandPath -Parent
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

$compatibilityModulePath = Join-Path $bravoScriptDirectory "BRAVO_COMPATIBILITY.ps1"
if (-not (Test-Path -LiteralPath $compatibilityModulePath -PathType Leaf)) {
    Write-Error "Не знайдено модуль сумісності: $compatibilityModulePath"
    Complete-BRAVOHelperLog -ExitCode 1
}
try {
    . $compatibilityModulePath
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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Normalize-TaskPath {
    param([string]$TaskPath)

    if ([string]::IsNullOrWhiteSpace($TaskPath)) {
        throw "schedulerSettings.TaskPath не налаштовано"
    }

    $trimmed = $TaskPath.Trim().Trim("\")
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return "\"
    }
    if ($trimmed -match '[/:*?"<>|]' -or $trimmed -match '(^|\\)\.\.?($|\\)') {
        throw "Некоректний TaskPath: $TaskPath"
    }
    return "\$trimmed\"
}

function Remove-TaskFolderIfEmpty {
    param([string]$TaskPath)

    if ($TaskPath -eq "\") {
        return
    }

    $service = New-Object -ComObject "Schedule.Service"
    $service.Connect()

    try {
        $folder = $service.GetFolder($TaskPath.TrimEnd("\"))
    } catch {
        return
    }

    if ($folder.GetTasks(0).Count -gt 0 -or $folder.GetFolders(0).Count -gt 0) {
        Write-Host "Каталог планувальника не порожній і залишений без змін: $TaskPath" -ForegroundColor Yellow
        return
    }

    $segments = @($TaskPath.Trim("\").Split("\"))
    $folderName = $segments[-1]
    $parentPath = if ($segments.Count -le 1) {
        "\"
    } else {
        "\" + (($segments[0..($segments.Count - 2)]) -join "\") + "\"
    }

    $parentFolder = $service.GetFolder($parentPath)
    $parentFolder.DeleteFolder($folderName, 0)
    Write-Host "Порожній каталог планувальника видалено: $TaskPath" -ForegroundColor Green
}

function Get-BRAVOTaskStateName {
    param([int]$State)

    switch ($State) {
        0 { return "UNKNOWN" }
        1 { return "DISABLED" }
        2 { return "QUEUED" }
        3 { return "READY" }
        4 { return "RUNNING" }
        default { return [string]$State }
    }
}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    Write-Error "Файл конфігурації не знайдено: $ConfigPath"
    Complete-BRAVOHelperLog -ExitCode 1
}

$resolvedConfigPath = (Resolve-Path -Path $ConfigPath).Path
try {
    $configRoot = Split-Path -Path $resolvedConfigPath -Parent
    $configText = [System.IO.File]::ReadAllText($resolvedConfigPath, [System.Text.Encoding]::UTF8)
    $configScript = [scriptblock]::Create($configText)
    & $configScript -ConfigRoot $configRoot
    $taskService = New-Object -ComObject "Schedule.Service"
    $taskService.Connect()
    $taskPath = Normalize-TaskPath -TaskPath $schedulerSettings.TaskPath
    $taskNames = @(
        [string]$schedulerSettings.Backup.TaskName,
        [string]$schedulerSettings.Maintenance.TaskName,
        [string]$schedulerSettings.Health.TaskName,
        [string]$schedulerSettings.Recovery.TaskName
    )
    if ($taskNames.Count -ne 4 -or
        @($taskNames | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -match '[\\/]' }).Count -gt 0) {
        throw "У конфігурації вказано некоректні імена завдань"
    }
    if (-not (Test-Path -Path $schedulerSettings.PowerShellExecutable -PathType Leaf)) {
        throw "PowerShellExecutable не знайдено"
    }
    $taskTargets = @(
        $taskNames | ForEach-Object {
            [pscustomobject]@{ TaskPath = $taskPath; TaskName = [string]$_ }
        }
    )
    if ($schedulerSettings.LegacyTaskPath -and $schedulerSettings.LegacyTaskNames) {
        $legacyTaskPath = Normalize-TaskPath -TaskPath ([string]$schedulerSettings.LegacyTaskPath)
        $taskTargets += @(
            $schedulerSettings.LegacyTaskNames | ForEach-Object {
                [pscustomobject]@{ TaskPath = $legacyTaskPath; TaskName = [string]$_ }
            }
        )
    }
} catch {
    Write-Error "Помилка конфігурації планувальника: $($_.Exception.Message)"
    Complete-BRAVOHelperLog -ExitCode 1
}

if (-not $ValidateOnly -and -not (Test-IsAdministrator)) {
    Write-Host "Потрібні права адміністратора. Відкривається запит UAC..." -ForegroundColor Yellow
    $elevationArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$resolvedConfigPath`""
    if ($StopRunningTasks) {
        $elevationArguments += " -StopRunningTasks"
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
    $existingTasks = @()
    foreach ($taskTarget in $taskTargets) {
        $folder = $null
        $task = $null
        try {
            $folderPath = if ($taskTarget.TaskPath -eq "\") {
                "\"
            } else {
                $taskTarget.TaskPath.TrimEnd("\")
            }
            $folder = $taskService.GetFolder($folderPath)
            $task = $folder.GetTask($taskTarget.TaskName)
        } catch {
            $task = $null
        }
        if ($task) {
            $existingTasks += [pscustomobject]@{
                Task = $task
                Folder = $folder
                TaskPath = [string]$taskTarget.TaskPath
                TaskName = [string]$taskTarget.TaskName
            }
        } else {
            Write-Host "Завдання не знайдено: $($taskTarget.TaskPath)$($taskTarget.TaskName)" -ForegroundColor DarkGray
        }
    }

    $runningTasks = @($existingTasks | Where-Object { [int]$_.Task.State -eq 4 })

    if ($ValidateOnly) {
        foreach ($taskRecord in $existingTasks) {
            $stateText = Get-BRAVOTaskStateName -State ([int]$taskRecord.Task.State)
            Write-Host "[ПЕРЕВІРКА] Буде видалено: $($taskRecord.TaskPath)$($taskRecord.TaskName) — $stateText" -ForegroundColor Cyan
        }
        if ($runningTasks.Count -gt 0) {
            Write-Host "Запущені завдання без -StopRunningTasks видалятися не будуть." -ForegroundColor Yellow
        }
        Write-Host "Системні зміни не виконувалися." -ForegroundColor Green
        Complete-BRAVOHelperLog -ExitCode 0
    }

    if ($runningTasks.Count -gt 0 -and -not $StopRunningTasks) {
        $runningNames = ($runningTasks | ForEach-Object {
            "$($_.TaskPath)$($_.TaskName)"
        }) -join ", "
        throw "Завдання зараз виконуються: $runningNames. Дочекайтеся завершення або явно використайте -StopRunningTasks"
    }

    if ($StopRunningTasks) {
        foreach ($taskRecord in $runningTasks) {
            $taskRecord.Task.Stop(0)
            Write-Host "Виконання завдання зупинено: $($taskRecord.TaskPath)$($taskRecord.TaskName)" -ForegroundColor Yellow
        }
    }

    foreach ($taskRecord in $existingTasks) {
        $taskRecord.Folder.DeleteTask($taskRecord.TaskName, 0)
        Write-Host "Завдання видалено: $($taskRecord.TaskPath)$($taskRecord.TaskName)" -ForegroundColor Green
    }

    Remove-TaskFolderIfEmpty -TaskPath $taskPath
    if ($legacyTaskPath) {
        Remove-TaskFolderIfEmpty -TaskPath $legacyTaskPath
    }
    Write-Host "Видалення завдань BRAVO завершено." -ForegroundColor Green
    Complete-BRAVOHelperLog -ExitCode 0
} catch {
    Write-Error "Не вдалося видалити завдання: $($_.Exception.Message)"
    Complete-BRAVOHelperLog -ExitCode 1
}
