[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$NoPause
)

# Тонкий entrypoint: жодної бізнес-логіки тут — лише guard, imports,
# виклик UI. Уся логіка живе в modules\BRAVO.Configurator\*.
#
# Configurator — інтерактивний desktop-інструмент оператора, не
# scheduled SYSTEM-завдання: elevation-gate (як у BRAVO_HEALTH.ps1 dev.13)
# тут навмисно відсутній — не потребує підвищених прав для читання й
# запису production BRAVO.local.config у власному каталозі встановлення.

function Wait-BRAVOEarlyManualExit {
    # Ідентично іншим entrypoint-ам (див. коментар у BRAVO_ARCHIV.ps1) —
    # дублюється свідомо, не виносилось у спільний модуль.
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

# ===== Runtime/tool integrity guard (той самий 3-перевірковий контракт,
# що BRAVO_HEALTH.ps1/BRAVO_ARCHIV.ps1/... — не дублюється як нова
# політика, лише як той самий guard-блок, що кожен entrypoint несе
# незалежно) =====
$runtimeGuardPath = Join-Path $PSScriptRoot 'BRAVO_RUNTIME_GUARD.ps1'
if (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf) {
    try {
        . $runtimeGuardPath
    } catch {
        Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити BRAVO_RUNTIME_GUARD.ps1: $($_.Exception.Message)" -ForegroundColor Red
        Wait-BRAVOEarlyManualExit -NoPause:$NoPause
        exit 33
    }
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

    $effectiveConfigPathForGuard = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Join-Path $PSScriptRoot 'BRAVO.config'
    } else {
        [string]$ConfigPath
    }
    $securitySettings = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath $effectiveConfigPathForGuard `
        -Mode $runtimeIntegrityMode
    if (-not $securitySettings.IsValid) {
        $securityColor = if ($securitySettings.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $securitySettings.Message -ForegroundColor $securityColor
        if ($securitySettings.ShouldBlock) { Wait-BRAVOEarlyManualExit -NoPause:$NoPause; exit 34 }
    }

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

# ===== Imports (порядок відповідає залежностям — Schema/Effective перші,
# UI останнім) =====
try {
    $configuratorModuleRoot = Join-Path $PSScriptRoot 'modules\BRAVO.Configurator'
    # R3-4 (PR #136, третє коло review): BRAVO.Configurator.Credentials
    # тепер викликає canonical Test-BRAVOSftpCredentialsRequired з
    # BRAVO.Configuration.Derivation — Invoke-BRAVOConfiguratorEffectiveComputation
    # обчислює Effective у ІЗОЛЬОВАНОМУ дочірньому процесі (там модуль
    # завантажується окремо), тому тут, у сесії самого Configurator-а,
    # потрібен явний імпорт для власного виклику.
    Import-Module (Join-Path $PSScriptRoot 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Schema.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Effective.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Model.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Validation.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Persistence.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Credentials.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Presets.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Preview.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.UI.psm1') -Force -ErrorAction Stop
} catch {
    Write-Host "КРИТИЧНА ПОМИЛКА: не вдалося завантажити модулі Configurator-а: $($_.Exception.Message)" -ForegroundColor Red
    Wait-BRAVOEarlyManualExit -NoPause:$NoPause
    exit 1
}

$configuratorRuntimeRoot = $PSScriptRoot
$configuratorProductionConfigDirectory = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $PSScriptRoot
} else {
    Split-Path -Path $ConfigPath -Parent
}

try {
    # P2-A.4: exit-семантика — свідомо exit 0 для всіх трьох нормальних
    # завершень (Applied/Cancelled/NoChanges); жоден automation-caller
    # сьогодні не розрізняє їх за OS exit-кодом (Configurator —
    # інтерактивний desktop-інструмент, не scheduled-завдання під
    # BRAVO.ExitCodes). Результат лише виводиться операторові для
    # інформації.
    $configuratorOutcome = Show-BRAVOConfiguratorMainForm `
        -RuntimeRoot $configuratorRuntimeRoot `
        -ProductionConfigDirectory $configuratorProductionConfigDirectory
    $outcomeText = switch ($configuratorOutcome) {
        'Applied'   { 'Зміни застосовано.' }
        'Cancelled' { 'Закрито без застосування незбережених змін.' }
        default     { 'Закрито без змін.' }
    }
    Write-Host $outcomeText -ForegroundColor Cyan
    $exitCode = 0
} catch {
    Write-Host "ПОМИЛКА Configurator: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}

Wait-BRAVOEarlyManualExit -NoPause:$NoPause
exit $exitCode
