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
    [switch]$NoElevation,
    [switch]$NoPause
)

$helperLoggingPath = Join-Path $PSScriptRoot "modules\BRAVO.HelperLogging\BRAVO.HelperLogging.psd1"
Import-Module -Name $helperLoggingPath -ErrorAction Stop
$null = Start-BRAVOHelperLog -ScriptPath $PSCommandPath -ConfigPath $ConfigPath

# Єдина точка налаштування BRAVO:
# 1. fail-closed preflight без production-операцій;
# 2. додавання/оновлення параметрів установи та секретів у Credential Manager;
# 3. перевірка читання записів для поточного користувача і task account;
# 4. перевірка/встановлення Планувальника;
# 5. read-only тестовий прогін і opt-in тестове сповіщення.

$ErrorActionPreference = "Stop"



function Wait-BRAVOSetupCompletion {
    if ($NoPause -or -not [Environment]::UserInteractive) {
        return
    }

    try {
        if ([Console]::IsInputRedirected) {
            return
        }
        [void](Read-Host "Натисніть Enter для завершення")
    } catch {
        # Фонові, перенаправлені або non-interactive запуски не повинні
        # завершуватися помилкою лише через відсутність консолі.
    }
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
    $configurationLoaderPath = Join-Path $configRoot 'BRAVO_CONFIG_LOADER.ps1'
    if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $configurationLoaderPath"
    }
    . $configurationLoaderPath
    Import-BravoConfiguration -ConfigRoot $configRoot -ConfigPath $resolvedPath

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
        (ConvertTo-BRAVOProcessArgument $PSCommandPath),
        "-ConfigPath",
        (ConvertTo-BRAVOProcessArgument $SetupConfiguration.ConfigPath),
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
    if ($NoPause) {
        $argumentParts += "-NoPause"
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
    Complete-BRAVOHelperLog -ExitCode $process.ExitCode
}

try {
    $scriptDirectory = if ($PSCommandPath) {
        Split-Path $PSCommandPath -Parent
    } else {
        [Environment]::CurrentDirectory
    }
    Import-Module -Name (Join-Path $scriptDirectory 'modules\BRAVO.System\BRAVO.System.psd1') -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $scriptDirectory "BRAVO.config"
    }
    $setup = Get-SetupConfiguration -Path $ConfigPath

    $credentialWorkRequested = $Action -in @("Full", "Credentials")
    $schedulerWorkRequested = $Action -in @("Full", "Scheduler")
    # ValidateOnly виконує лише read-only перевірки й не повинен відкривати UAC.
    $requiresAdministrator = (-not $ValidateOnly) -and (
        $schedulerWorkRequested -or
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
    Wait-BRAVOSetupCompletion
    Complete-BRAVOHelperLog -ExitCode 0
} catch {
    Write-Host ""
    Write-Host "ПОМИЛКА НАЛАШТУВАННЯ: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Подальші етапи зупинено (fail-closed)." -ForegroundColor Yellow
    Wait-BRAVOSetupCompletion
    Complete-BRAVOHelperLog -ExitCode 1
}
