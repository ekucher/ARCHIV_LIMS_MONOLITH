[CmdletBinding()]
param(
    [string]$ConfigPath,

    [ValidateSet("Full", "Credentials", "Scheduler", "Test")]
    [string]$Action = "Full",

    [ValidateSet(
        "Required",
        "All",
        "SFTP",
        "SMB",
        "Slack",
        "Discord",
        "Archive",
        "Institution"
    )]
    [string]$CredentialComponent = "Required",

    [ValidateSet("Both", "ScheduledTaskAccount", "CurrentUser")]
    [string]$StoreFor = "Both",

    [switch]$ValidateOnly,
    [switch]$SkipAccessTest,
    [switch]$SkipTestNotification,
    [switch]$NoElevation
)

# Єдина точка налаштування BRAVO:
# 1. fail-closed preflight без production-операцій;
# 2. додавання/оновлення параметрів установи та секретів у Credential Manager;
# 3. перевірка читання записів для поточного користувача і task account;
# 4. перевірка/встановлення Планувальника;
# 5. read-only тестовий прогін і opt-in тестове сповіщення.

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-ProcessArgument {
    param([string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-ChildPowerShell {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments,
        [string]$StepName
    )

    Write-Host ""
    Write-Host "=== $StepName ===" -ForegroundColor Cyan
    $powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        throw "Windows PowerShell не знайдено: $powerShellPath"
    }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Скрипт не знайдено: $ScriptPath"
    }

    $childArguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $ScriptPath
    ) + @($Arguments)
    & $powerShellPath @childArguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$StepName завершився з кодом $exitCode"
    }
}

function Get-SetupConfiguration {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Файл конфігурації не знайдено: $Path"
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $configRoot = Split-Path $resolvedPath -Parent
    $configText = [IO.File]::ReadAllText($resolvedPath, [Text.Encoding]::UTF8)
    & ([scriptblock]::Create($configText)) -ConfigRoot $configRoot

    $credentialScript = if ($null -ne $credentialSettings -and
        -not [string]::IsNullOrWhiteSpace([string]$credentialSettings.SetupScriptPath)) {
        [string]$credentialSettings.SetupScriptPath
    } else {
        Join-Path $configRoot "BRAVO_CREDENTIALS_SETUP.ps1"
    }

    return [pscustomobject]@{
        ConfigPath = $resolvedPath
        Root = $configRoot
        CredentialScript = $credentialScript
        DryRunScript = Join-Path $configRoot "BRAVO_DRY_RUN.ps1"
        TaskInstallScript = Join-Path $configRoot "BRAVO_TASKS_INSTALL.ps1"
        TaskDiagnoseScript = Join-Path $configRoot "BRAVO_TASKS_DIAGNOSE.ps1"
        NotificationsEnabled = (
            ([string]$bravoSettings.NotificationMode).Trim().ToLowerInvariant() -ne "none"
        )
        HasFullSchedulerConfiguration = (
            $null -ne $schedulerSettings -and
            $null -ne $schedulerSettings.Backup -and
            $null -ne $schedulerSettings.Maintenance -and
            $null -ne $schedulerSettings.Health
        )
    }
}

function Restart-SetupElevated {
    param($SetupConfiguration)

    $argumentParts = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Quote-ProcessArgument $PSCommandPath),
        "-ConfigPath",
        (Quote-ProcessArgument $SetupConfiguration.ConfigPath),
        "-Action",
        $Action,
        "-StoreFor",
        $StoreFor,
        "-CredentialComponent"
    )
    $argumentParts += $CredentialComponent
    if ($ValidateOnly) {
        $argumentParts += "-ValidateOnly"
    }
    if ($SkipAccessTest) {
        $argumentParts += "-SkipAccessTest"
    }
    if ($SkipTestNotification) {
        $argumentParts += "-SkipTestNotification"
    }
    $argumentParts += "-NoElevation"

    $powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $process = Start-Process `
        -FilePath $powerShellPath `
        -ArgumentList ($argumentParts -join " ") `
        -Verb RunAs `
        -Wait `
        -PassThru `
        -WindowStyle Normal
    exit $process.ExitCode
}

try {
    $scriptDirectory = if ($PSCommandPath) {
        Split-Path $PSCommandPath -Parent
    } else {
        [Environment]::CurrentDirectory
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $scriptDirectory "BRAVO.config"
    }
    $setup = Get-SetupConfiguration -Path $ConfigPath

    $credentialWorkRequested = $Action -in @("Full", "Credentials")
    $schedulerWorkRequested = $Action -in @("Full", "Scheduler")
    $requiresAdministrator = (
        (-not $ValidateOnly -and $schedulerWorkRequested) -or
        ($credentialWorkRequested -and $StoreFor -in @("Both", "ScheduledTaskAccount"))
    )
    if ($requiresAdministrator -and -not (Test-IsAdministrator)) {
        if ($NoElevation) {
            throw "потрібні права адміністратора, але автоматичне підвищення вимкнено"
        }
        Write-Host "Для Credential Manager task account і Планувальника потрібні права адміністратора. Запит UAC..." `
            -ForegroundColor Yellow
        Restart-SetupElevated -SetupConfiguration $setup
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " BRAVO — КОМПЛЕКСНЕ НАЛАШТУВАННЯ" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Config: $($setup.ConfigPath)"
    Write-Host "Режим: $Action$(if ($ValidateOnly) { ' (лише перевірка)' } else { '' })"

    # Preflight не читає секрети й ніколи не робить мережеві або production-операції.
    Invoke-ChildPowerShell `
        -ScriptPath $setup.DryRunScript `
        -Arguments @("-ConfigPath", $setup.ConfigPath, "-SkipCredentials") `
        -StepName "1/5. Локальний preflight / симуляція"

    if ($credentialWorkRequested) {
        if (-not $ValidateOnly) {
            $credentialArguments = @(
                "-ConfigPath", $setup.ConfigPath,
                "-Action", "Ensure",
                "-StoreFor", $StoreFor,
                "-Component"
            ) + @($CredentialComponent)
            Invoke-ChildPowerShell `
                -ScriptPath $setup.CredentialScript `
                -Arguments $credentialArguments `
                -StepName "2/5. Додавання або оновлення Credential Manager"
        } else {
            Write-Host ""
            Write-Host "=== 2/5. Credential Manager ===" -ForegroundColor Cyan
            Write-Host "[ПЕРЕВІРКА] Записи не створюються і не змінюються." -ForegroundColor Yellow
        }
    }

    # У режимах Full/Credentials перевіряється запитаний scope. У Test/Scheduler
    # перевіряємо стандартний безпечний набір Required для обох облікових записів.
    if ($Action -in @("Full", "Credentials", "Scheduler", "Test")) {
        $testComponents = if ($credentialWorkRequested) {
            @($CredentialComponent)
        } else {
            @("Required")
        }
        $testStore = if ($credentialWorkRequested) { $StoreFor } else { "Both" }
        $credentialTestArguments = @(
            "-ConfigPath", $setup.ConfigPath,
            "-Action", "Test",
            "-StoreFor", $testStore,
            "-Component"
        ) + $testComponents
        Invoke-ChildPowerShell `
            -ScriptPath $setup.CredentialScript `
            -Arguments $credentialTestArguments `
            -StepName "3/5. Перевірка читання Credential Manager"
    }

    if ($schedulerWorkRequested -or $Action -eq "Test") {
        if (-not $setup.HasFullSchedulerConfiguration) {
            if ($schedulerWorkRequested) {
                throw "цей config не містить повної schedulerSettings для BRAVO_TASKS_INSTALL.ps1"
            }
            Write-Warning "Перевірку Планувальника пропущено: config не містить повної schedulerSettings."
        } else {
            Invoke-ChildPowerShell `
                -ScriptPath $setup.TaskInstallScript `
                -Arguments @("-ConfigPath", $setup.ConfigPath, "-ValidateOnly") `
                -StepName "4/5. Валідація Планувальника завдань"

            if ($schedulerWorkRequested -and -not $ValidateOnly) {
                Invoke-ChildPowerShell `
                    -ScriptPath $setup.TaskInstallScript `
                    -Arguments @("-ConfigPath", $setup.ConfigPath) `
                    -StepName "4/5. Встановлення/оновлення Планувальника завдань"
            }
        }
    }

    $dryRunArguments = @("-ConfigPath", $setup.ConfigPath)
    if (-not $SkipAccessTest) {
        $dryRunArguments += "-TestAccess"
    }
    if (-not $ValidateOnly -and
        -not $SkipAccessTest -and
        -not $SkipTestNotification -and
        $setup.NotificationsEnabled) {
        $dryRunArguments += "-SendTestNotification"
    }
    if ($schedulerWorkRequested -and
        -not $ValidateOnly -and
        $setup.HasFullSchedulerConfiguration) {
        Invoke-ChildPowerShell `
            -ScriptPath $setup.TaskDiagnoseScript `
            -Arguments $dryRunArguments `
            -StepName "5/5. SYSTEM dry-run і діагностика Планувальника"
    } else {
        if ($schedulerWorkRequested -and
            -not $ValidateOnly -and
            $setup.HasFullSchedulerConfiguration) {
            $dryRunArguments += "-RequireScheduledTasks"
        }
        Invoke-ChildPowerShell `
            -ScriptPath $setup.DryRunScript `
            -Arguments $dryRunArguments `
            -StepName "5/5. Фінальний безпечний тестовий прогін"
    }

    Write-Host ""
    Write-Host "Комплексне налаштування завершено успішно." -ForegroundColor Green
    if ($ValidateOnly) {
        Write-Host "Секрети й завдання не змінювалися; production-операції не запускалися." `
            -ForegroundColor Green
    } else {
        Write-Host "Production-операції архівації/копіювання/видалення не запускалися." `
            -ForegroundColor Green
    }
    exit 0
} catch {
    Write-Host ""
    Write-Host "ПОМИЛКА НАЛАШТУВАННЯ: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Подальші етапи зупинено (fail-closed)." -ForegroundColor Yellow
    exit 1
}
