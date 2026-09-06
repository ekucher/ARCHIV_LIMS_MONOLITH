[CmdletBinding()]
param(
    [switch]$KeepFixture,
    [int]$ComboTimeoutSeconds = 180,
    # Стабільний каталог для stdout/stderr кожної комбінації — поза
    # fixture-коренем (який прибирається в finally). LOGS\ уже
    # gitignored, тому це не засмічує репозиторій при ручному запуску;
    # CI завантажує цей каталог як артефакт при падінні job'а. Порожнє за
    # замовчуванням і resolved нижче в тілі скрипта: $PSScriptRoot
    # недоступний під час обчислення default-значень у param()-блоці.
    [string]$ComboLogDirectory
)

if ([string]::IsNullOrWhiteSpace($ComboLogDirectory)) {
    $ComboLogDirectory = Join-Path $PSScriptRoot 'LOGS\DataRestoreMatrixTest'
}

# Повністю себестоятний end-to-end матричний тест BRAVO_DATA_RESTORE
# (-Source Local): будує ізольований TEMP-sandbox (fixture BRAVO.config,
# синтетичні "live"-джерела компонентів, дві реальні генерації через
# справжній BRAVO_ARCHIV.ps1), прожинає курований набір комбінацій
# Component×Mode×outcome через окремі дочірні powershell.exe-процеси й
# звіряє файловий/стан-результат проти очікуваного контракту
# (BRAVO.ExitCodes). Запускається і вручну (елевована сесія), і в CI
# (job datarestore-matrix-test у .github/workflows/ci.yml). -Source SFTP
# поза обсягом (уже покрито unit-тестами BRAVO_SELF_TEST.ps1). Деталі
# проєктування: план сесії "synchronous-swinging-charm".
#
# Уся логіка фікстур/матриці/асертів — у modules\BRAVO.DataRestore.MatrixTest
# (канонічний власник відповідальності); цей файл — лише оркестрація.

$ErrorActionPreference = "Stop"

# UAC не автоматизується. Runtime.ps1 самопідвищується для будь-якого
# режиму, крім -ListGenerations (BRAVO.DataRestore.Runtime.ps1, перевірка
# IsInRole(Administrator)) — тому дочірні процеси мають успадкувати вже
# елевований токен. Власна спроба -Verb RunAs тут лише перенесла б ту саму
# проблему на рівень вище.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ПОМИЛКА: BRAVO_DATA_RESTORE_MATRIX_TEST.ps1 потребує елевованої сесії (Administrator) — запустіть PowerShell 'Від імені адміністратора' і повторіть." -ForegroundColor Red
    exit 36
}

$modulePath = Join-Path $PSScriptRoot 'modules\BRAVO.DataRestore.MatrixTest\BRAVO.DataRestore.MatrixTest.psd1'
try {
    Import-Module -Name $modulePath -ErrorAction Stop
} catch {
    Write-Host "ПОМИЛКА: не вдалося завантажити modules\BRAVO.DataRestore.MatrixTest: $($_.Exception.Message)" -ForegroundColor Red
    exit 90
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "BRAVO_MATRIX_TEST_$([guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $fixtureRoot -Force -ErrorAction Stop)
Write-Host "Fixture root: $fixtureRoot"

# Belt-and-suspenders (план, розділ 7): підтвердити, що реальний
# production lock-файл не зачеплений цим прогоном — незалежно від
# гарантії Managed=false у fixture-конфігу. Знімок реальних служб береться
# нижче, після (легітимного, VSS-залежного) кроку генерації фікстур —
# див. коментар там.
$realLockPath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\Locks\BRAVO_OPERATION.lock'
$realLockTimestampBefore = if (Test-Path -LiteralPath $realLockPath -PathType Leaf) { (Get-Item -LiteralPath $realLockPath).LastWriteTimeUtc } else { $null }

# Ізоляція VersionState (SELFTEST-SAFETY-0 v1.4): fixture-діти нижче —
# справжні BRAVO_ARCHIV.ps1/BRAVO_DATA_RESTORE.ps1, чий runtime guard
# передає захардкожений machine-global шлях %ProgramData%\BRAVO\State\
# BRAVO_VERSION_STATE.json. Після SemVer-фіксу (#135) prerelease-версії
# ПИШУТЬ стан, тож без переспрямування тестовий прогін піднімав би
# production high-water mark і на сервері з установленим toolkit блокував
# би старіший production runtime як "відкат". Сесійний контекст (усі ТРИ
# змінні, контракт Resolve-BRAVOSelfTestIsolationContext) успадковується
# всіма дочірніми процесами матриці; guard застосовує його лише як місце
# зберігання — валідація версій виконується повністю. Root сесії обирає
# ЦЕЙ батьківський харнес рівно один раз (RUNNER_TEMP у CI, інакше TEMP).
$selfTestSessionId = [guid]::NewGuid().ToString('D')
$selfTestTempBase = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$selfTestSessionRoot = Join-Path $selfTestTempBase ("BRAVO_SELFTEST_$selfTestSessionId")
[void](New-Item -ItemType Directory -Path $selfTestSessionRoot -Force -ErrorAction Stop)
$selfTestPreviousEnvironment = @{
    'BRAVO_SELFTEST_SESSION_ID' = [Environment]::GetEnvironmentVariable('BRAVO_SELFTEST_SESSION_ID')
    'BRAVO_SELFTEST_ROOT' = [Environment]::GetEnvironmentVariable('BRAVO_SELFTEST_ROOT')
    'BRAVO_SELFTEST_VERSION_STATE_PATH' = [Environment]::GetEnvironmentVariable('BRAVO_SELFTEST_VERSION_STATE_PATH')
}
$env:BRAVO_SELFTEST_SESSION_ID = $selfTestSessionId
$env:BRAVO_SELFTEST_ROOT = $selfTestSessionRoot
$env:BRAVO_SELFTEST_VERSION_STATE_PATH = Join-Path $selfTestSessionRoot 'State\BRAVO_VERSION_STATE.json'

$aggregateExitCode = 1
try {
    $fixtureConfig = New-BRAVODataRestoreMatrixFixtureConfig -RepoRoot $PSScriptRoot -FixtureRoot $fixtureRoot -MinimumFreeSpaceGB 1
    $freeSpaceFixtureConfig = New-BRAVODataRestoreMatrixFixtureConfig -RepoRoot $PSScriptRoot -FixtureRoot $fixtureRoot -ConfigFileName 'BRAVO_FREESPACE.config' -MinimumFreeSpaceGB 999999999

    Write-Host "Генерація фікстур-архівів (реальний BRAVO_ARCHIV.ps1, дві генерації)..."
    $olderCanary = "GEN_A_$([guid]::NewGuid().ToString('N'))"
    $olderGenerationId = New-BRAVODataRestoreMatrixFixtureGeneration -RepoRoot $PSScriptRoot -FixtureConfig $fixtureConfig -CanaryValue $olderCanary
    # archiveTimestampFormat = yyyyMMdd_HHmmss (секундна точність) — пауза
    # гарантує різний GenerationId для другої генерації.
    Start-Sleep -Seconds 2
    $newerCanary = "GEN_B_$([guid]::NewGuid().ToString('N'))"
    $newerGenerationId = New-BRAVODataRestoreMatrixFixtureGeneration -RepoRoot $PSScriptRoot -FixtureConfig $fixtureConfig -CanaryValue $newerCanary
    Write-Host "Генерації готові: older=$olderGenerationId, newer=$newerGenerationId"

    $canaryByGeneration = @{ $olderGenerationId = $olderCanary; $newerGenerationId = $newerCanary }

    $outOfPlaceRoot = Join-Path $fixtureRoot 'OUTOFPLACE'
    [void](New-Item -ItemType Directory -Path $outOfPlaceRoot -Force -ErrorAction Stop)

    $combos = Get-BRAVODataRestoreMatrixComboDefinitions `
        -FixtureConfig $fixtureConfig `
        -FreeSpaceFixtureConfig $freeSpaceFixtureConfig `
        -NewerGenerationId $newerGenerationId `
        -OlderGenerationId $olderGenerationId `
        -OutOfPlaceRoot $outOfPlaceRoot

    # Знімок реальних служб береться ТУТ (не на самому початку скрипту):
    # генерація фікстур-архівів вище легітимно запускає VSS
    # (New-BRAVODataRestoreMatrixFixtureGeneration, узгоджено з
    # користувачем) — swprv/VSS штатно стартують/зупиняються під час цього
    # кроку. Перевірка нижче має ловити зміни СЛУЖБ САМЕ від DataRestore-
    # комбінацій, а не побічний ефект уже прийнятого VSS-кроку.
    $realServiceSnapshotBefore = @(Get-Service | Select-Object Name, Status)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($combo in $combos) {
        Write-Host "Виконання: $($combo.Name)..."
        # Live-каталоги переспоживаються послідовними комбінаціями: кожен
        # УСПІШНИЙ InPlace-прогін навмисно лишає власну постійну
        # .prerestore_* копію (задокументований інваріант). Знімок ДО цієї
        # конкретної комбінації дозволяє Assert відрізнити вже наявні
        # (легітимні) копії від нового orphan, який мав би лишити rollback.
        $prerestoreBefore = @{}
        foreach ($component in @('MODEL', 'BLOG', 'BRAVOEXCH')) {
            $liveDirectory = [string]$fixtureConfig.SourceDirectories[$component]
            $prerestoreBefore[$component] = @(
                Get-ChildItem -Path (Split-Path $liveDirectory -Parent) -Filter "$component.prerestore_*" -Directory -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name
            )
        }
        $comboResult = Invoke-BRAVODataRestoreMatrixCombo `
            -RepoRoot $PSScriptRoot `
            -ConfigPath ([string]$combo.ConfigPath) `
            -Arguments $combo.Arguments `
            -FailpointComponent $combo.FailpointComponent `
            -TimeoutSeconds $ComboTimeoutSeconds `
            -LogDirectory $ComboLogDirectory `
            -ComboName $combo.Name `
            -ProgramDataRoot $fixtureConfig.ProgramDataRoot `
            -DiscoverySettingsOverridePath $fixtureConfig.DiscoverySettingsOverridePath
        $assertion = Assert-BRAVODataRestoreMatrixComboResult `
            -Combo $combo `
            -Result $comboResult `
            -FixtureConfig $fixtureConfig `
            -CanaryByGeneration $canaryByGeneration `
            -PrerestoreDirectoriesBefore $prerestoreBefore
        $results.Add([pscustomobject]@{
            Name = $combo.Name
            ExitCode = $comboResult.ExitCode
            Passed = $assertion.Passed
            Reasons = $assertion.Reasons
        })
    }

    $aggregateExitCode = Write-BRAVODataRestoreMatrixSummary -Results $results.ToArray()

    # Фактична безпечна властивість — "DataRestore ніколи не зупиняв
    # реальну службу" (Managed=false у fixture-конфізі це гарантує на
    # рівні коду; тут — belt-and-suspenders підтвердження). Загальний
    # знімок УСІХ служб виявився ненадійним на реальних машинах (CI і
    # локально): demand/trigger-start служби ОС (DsmSvc, NgcSvc тощо)
    # самі стартують/зупиняються протягом кількох хвилин прогону з
    # причин, що не мають нічого спільного з цим скриптом — двічі
    # підтверджено в обидва боки на PR #44. DataRestore структурно не
    # може викликати Start-/Stop-Service на нічому, крім імен, явно
    # заданих у maintenanceSettings.Services/BravoWebCandidates (тут —
    # навмисно неіснуючих fixture-імен) — тому перевірка звужена саме до
    # реальних production-імен (значення за замовчуванням із самого
    # BRAVO.config), а не до кожної служби в системі.
    $watchedRealServiceNames = @('BRAVO', 'exchangAPI', 'BRAVOWeb', 'BRAVO Web', 'Br-a-vo.web', 'Apache2.4', 'Apache24', 'Apache')
    $realServiceSnapshotAfter = @(Get-Service | Where-Object { $watchedRealServiceNames -contains $_.Name } | Select-Object Name, Status)
    $beforeByName = @{}
    foreach ($entry in $realServiceSnapshotBefore) {
        if ($watchedRealServiceNames -contains $entry.Name) { $beforeByName[$entry.Name] = $entry.Status }
    }
    $stoppedDuringRun = @(
        foreach ($entry in $realServiceSnapshotAfter) {
            $priorStatus = $beforeByName[$entry.Name]
            if ($null -ne $priorStatus -and [string]$priorStatus -eq 'Running' -and [string]$entry.Status -ne 'Running') {
                $entry
            }
        }
    )
    if ($stoppedDuringRun.Count -gt 0) {
        Write-Host "УВАГА: реальна BRAVO-пов'язана Windows-служба зупинилась під час прогону (не мало статися):" -ForegroundColor Red
        $stoppedDuringRun | Format-Table | Out-String | Write-Host
        $aggregateExitCode = 1
    }
    $realLockTimestampAfter = if (Test-Path -LiteralPath $realLockPath -PathType Leaf) { (Get-Item -LiteralPath $realLockPath).LastWriteTimeUtc } else { $null }
    if ($realLockTimestampBefore -ne $realLockTimestampAfter) {
        Write-Host "УВАГА: реальний production operation lock ($realLockPath) змінився під час прогону (не мало статися)." -ForegroundColor Red
        $aggregateExitCode = 1
    }
} finally {
    # Відновлення process-env (не machine-wide): зовнішні значення
    # BRAVO_SELFTEST_*, якщо вони були, повертаються як є; відсутні —
    # лишаються відсутніми.
    foreach ($selfTestVariableName in $selfTestPreviousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($selfTestVariableName, $selfTestPreviousEnvironment[$selfTestVariableName])
    }
    if ($KeepFixture) {
        Write-Host "Fixture root збережено (-KeepFixture): $fixtureRoot"
        Write-Host "SelfTest session root збережено (-KeepFixture): $selfTestSessionRoot"
    } else {
        try {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "УВАГА: не вдалося прибрати fixture root $fixtureRoot : $($_.Exception.Message)" -ForegroundColor Yellow
        }
        try {
            Remove-Item -LiteralPath $selfTestSessionRoot -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "УВАГА: не вдалося прибрати session root $selfTestSessionRoot : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

exit $aggregateExitCode
