# Домен-фрагмент self-test: BRAVO_CONFIG_LOADER.ps1 — Import-BravoConfiguration,
# зокрема діагностичне збагачення повідомлення про помилку виконання
# BRAVO.config (fix 2026-08-24: реальний DEV-майданчик на Windows NT
# 6.2.9200 / PowerShell 3.0 — Get-BRAVOOSSupportTier класифікує PowerShell
# <4.0 як "Unsupported" — отримав голу .NET NullReferenceException без
# жодного натяку на причину замість зрозумілого повідомлення).
#
# Реальна PowerShell 3.0-система тут не відтворюється (крихко/нереалістично
# підміняти $PSVersionTable під час прогону) — перевіряється сам механізм
# збагачення на реальному оточенні прогону (Supported на CI/dev-машинах):
# оригінальна причина помилки не губиться, і hint не з'являється там, де
# оточення й так Supported.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.

$configLoaderPath = Join-Path $root 'BRAVO_CONFIG_LOADER.ps1'
$configLoaderScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIG_LOADER_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($configLoaderScenarioRoot)
try {
    $syntheticConfigPath = Join-Path $configLoaderScenarioRoot 'BRAVO.config'
    # Мінімальний легітимний param(ConfigRoot)-контракт (Import-BravoConfiguration
    # компілює вміст як scriptblock і викликає з -ConfigRoot/-RuntimeRoot),
    # який одразу кидає синтетичну помилку — імітує будь-який реальний збій
    # усередині виконання BRAVO.config (незалежно від конкретної причини).
    [IO.File]::WriteAllText(
        $syntheticConfigPath,
        "param(`$ConfigRoot, `$RuntimeRoot)`nthrow 'BRAVO_SELF_TEST_SYNTHETIC_CONFIG_FAILURE'",
        (New-Object System.Text.UTF8Encoding $false)
    )

    # Окремий дочірній процес: Import-BravoConfiguration встановлює
    # $global:ScriptVersion/$global:BravoConfigurationMetadata та інший
    # глобальний стан, який небезпечно змішувати з рештою self-test-прогону
    # в тому самому процесі.
    $childOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command @"
`$ErrorActionPreference = 'Stop'
try {
    . '$configLoaderPath'
    Import-BravoConfiguration -ConfigRoot '$configLoaderScenarioRoot' -ConfigPath '$syntheticConfigPath' -RuntimeRoot '$root'
    Write-Output 'NO_ERROR_THROWN'
} catch {
    Write-Output `$_.Exception.Message
}
"@ 2>&1 | Out-String

    $configLoaderErrorMessage = [string]$childOutput

    Test-BRAVOCondition `
        -Condition $configLoaderErrorMessage.Contains('BRAVO_SELF_TEST_SYNTHETIC_CONFIG_FAILURE') `
        -Name "ConfigLoader/OriginalExceptionMessageNotLost" `
        -Failure "діагностичне збагачення повідомлення про помилку BRAVO.config не повинне губити оригінальну причину; отримано: $configLoaderErrorMessage"
    Test-BRAVOCondition `
        -Condition $configLoaderErrorMessage.Contains("Не вдалося завантажити BRAVO.config") `
        -Name "ConfigLoader/ErrorMessageContractPreserved" `
        -Failure "префікс повідомлення 'Не вдалося завантажити BRAVO.config' має зберігатися незалежно від збагачення"
    # На середовищі, де реально виконується self-test (CI/dev, Supported-tier),
    # hint про Unsupported/LegacyBestEffort зʼявлятися не повинен — це і є
    # мовчазна поведінка для Supported-оточення, яку описує коментар у коді.
    Test-BRAVOCondition `
        -Condition (
            -not $configLoaderErrorMessage.Contains('Unsupported') -and
            -not $configLoaderErrorMessage.Contains('LegacyBestEffort')
        ) `
        -Name "ConfigLoader/NoHintOnSupportedEnvironment" `
        -Failure "на Supported-оточенні (де реально виконується self-test) hint про непідтримуване середовище не повинен зʼявлятися; отримано: $configLoaderErrorMessage"
} finally {
    Remove-Item -LiteralPath $configLoaderScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- BRAVO_DRY_RUN.ps1: коли Import-BravoConfiguration провалюється (той
# самий синтетичний BRAVO.config, що й вище), Write-DryRunOutput усе одно
# має намалювати заголовок і звичайний [FAIL] запис "Dry-run/Фатальна
# помилка" — а не впасти вдруге з окремою, ще заплутанішою помилкою.
# Реальний DEV-майданчик (2026-08-24): "if ($global:ScriptVersion)" під
# Set-StrictMode 2.0 (успадкованим від dot-sourced BRAVO_CONFIG_LOADER.ps1)
# кидав VariableIsUndefined, коли конфігурація не завантажилась ДО того, як
# змінна взагалі створювалась — ховаючи первинну причину.
$dryRunPath = Join-Path $root 'BRAVO_DRY_RUN.ps1'
$dryRunScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_DRY_RUN_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($dryRunScenarioRoot)
# Ізоляція VersionState (SELFTEST-SAFETY-0 v1.4): дочірній BRAVO_DRY_RUN
# читає (з -NoWrite) machine-global BRAVO_VERSION_STATE.json — сесійний
# scope робить дитину незалежною від стану хоста.
$dryRunIsolationPrevious = Enter-BRAVOSelfTestIsolationScope
try {
    $dryRunSyntheticConfigPath = Join-Path $dryRunScenarioRoot 'BRAVO.config'
    [IO.File]::WriteAllText(
        $dryRunSyntheticConfigPath,
        "param(`$ConfigRoot, `$RuntimeRoot)`nthrow 'BRAVO_SELF_TEST_SYNTHETIC_CONFIG_FAILURE'",
        (New-Object System.Text.UTF8Encoding $false)
    )
    $dryRunChildOutput = [string](
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $dryRunPath -ConfigPath $dryRunSyntheticConfigPath 2>&1 | Out-String
    )
    $dryRunExitCode = $LASTEXITCODE

    Test-BRAVOCondition `
        -Condition ($dryRunExitCode -eq 1) `
        -Name "ConfigLoader/DryRunFailsClosedOnConfigLoadFailure" `
        -Failure "BRAVO_DRY_RUN.ps1 з непридатним BRAVO.config має завершитись кодом 1 (звичайний FAIL-контракт dry-run), а не впасти неопрацьованим виключенням; отримано exit code $dryRunExitCode, вивід: $dryRunChildOutput"
    Test-BRAVOCondition `
        -Condition (-not $dryRunChildOutput.Contains('VariableIsUndefined')) `
        -Name "ConfigLoader/DryRunDoesNotCrashOnUnsetScriptVersion" `
        -Failure "Write-DryRunOutput не повинен падати з VariableIsUndefined, коли `$global:ScriptVersion ще не створено через провал завантаження конфігурації; отримано: $dryRunChildOutput"
} finally {
    Exit-BRAVOSelfTestIsolationScope -PreviousValues $dryRunIsolationPrevious
    Remove-Item -LiteralPath $dryRunScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# BRAVO.local.config (5.2.1): локальні site-overrides, що переживають
# оновлення комплекту. Кожен сценарій — ізольований дочірній
# powershell.exe (Import-BravoConfiguration змінює глобальний стан).
# ============================================================
$localCfgScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_LOCALCFG_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($localCfgScenarioRoot)
    $localCfgBackupDir = Join-Path $localCfgScenarioRoot 'SITE_BACKUP'
    [void][IO.Directory]::CreateDirectory($localCfgBackupDir)
    # Герметичність (CI-провал v5.2.1-rc.7): комплектний дефолт
    # BackupRoot="" означає AUTO -> <EffectiveLIMSRoot>\ARCHIV, і на
    # машині БЕЗ інсталяції LIMS (GitHub runner) BRAVO.config кидає
    # «Не вдалося визначити BackupRoot» — сценарій без overrides
    # (FileAbsentIsNoop) залежав від середовища прогону. Запікаємо в
    # копію конфігурації явний BackupRoot (ОКРЕМИЙ від SITE_BACKUP
    # каталог: фаза-1 сценарій саме доводить, що override з
    # BRAVO.local.config перемагає явне значення з BRAVO.config).
    $localCfgDefaultBackupDir = Join-Path $localCfgScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($localCfgDefaultBackupDir)
    $localCfgKitConfigText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
    $localCfgBackupRootLiteralLine = '    BackupRoot    = ""'
    if (-not $localCfgKitConfigText.Contains($localCfgBackupRootLiteralLine)) {
        throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$localCfgBackupRootLiteralLine' — оновіть підготовку local-config сценаріїв під нову форму конфігурації"
    }
    [IO.File]::WriteAllText(
        (Join-Path $localCfgScenarioRoot 'BRAVO.config'),
        $localCfgKitConfigText.Replace(
            $localCfgBackupRootLiteralLine,
            "    BackupRoot    = '$($localCfgDefaultBackupDir.Replace("'", "''"))'"
        ),
        (New-Object System.Text.UTF8Encoding $false)
    )
    $localCfgOverridePath = Join-Path $localCfgScenarioRoot 'BRAVO.local.config'
    $localCfgBackupLiteral = $localCfgBackupDir.Replace("'", "''")

    # --- Фаза 1 + фаза 2 + деривації: BackupRoot протягується в archiveDirs,
    # BootRestoreMode -> Recovery.Enabled, пізній поріг BAZA, скаляр.
    [IO.File]::WriteAllText($localCfgOverridePath, (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$localCfgBackupLiteral'`r`n" +
        "    'maintenanceSettings.Restore.BootRestoreMode' = 'HoldServices'`r`n" +
        "    'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold' = 77`r`n" +
        "    'sftpHostTemplate' = '{0}.selftest-example.test'`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $localCfgProbe = & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
            "Set-StrictMode -Version 2.0; " +
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
            "'{0}|{1}|{2}|{3}|{4}' -f [string]`$global:archiveDirs.Model, " +
            "[string]`$global:maintenanceSettings.Restore.BootRestoreMode, " +
            "[string]`$global:schedulerSettings.Recovery.Enabled, " +
            "[string]`$global:backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold, " +
            "(@(`$global:BravoConfigurationMetadata.LocalConfigOverrides).Count) " +
            "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
        ) 2>&1
    $localCfgProbeLast = ([string](@($localCfgProbe)[-1])).Trim()
    Test-BRAVOCondition `
        -Condition ($localCfgProbeLast -eq "$localCfgBackupDir\MODEL|HoldServices|True|77|4") `
        -Name "ConfigLoader/LocalOverridesApplyAcrossBothPhasesWithDerivations" `
        -Failure "BRAVO.local.config має перевизначати первинні поля ДО деривацій (BackupRoot -> archiveDirs.Model; BootRestoreMode -> Recovery.Enabled=True) і пізні leaf-поля (поріг BAZA=77), з обліком у metadata (4 ключі); отримано: '$localCfgProbeLast'"

    # --- Опечатка в dot-шляху -> помилка конфігурації (не мовчазне ігнорування).
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ 'pathSettings.NoSuchKeyRoot.Sub' = 'x' }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgTypoProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW' }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($localCfgTypoProbe.Contains('THREW') -and -not $localCfgTypoProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/LocalOverrideUnknownKeyFailsClosed" `
        -Failure "невідомий dot-шлях у BRAVO.local.config мусить давати помилку конфігурації (конфіг, що бреше, гірший за помилку); отримано: $localCfgTypoProbe"

    # --- Виконуваний код у файлі -> відхилення (data-only контракт).
    [IO.File]::WriteAllText($localCfgOverridePath,
        "@{ 'pathSettings.BackupRoot' = (Get-Date).ToString() }",
        (New-Object System.Text.UTF8Encoding $false))
    $localCfgCodeProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "try { [void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); 'NO-THROW' } catch { 'THREW' }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($localCfgCodeProbe.Contains('THREW') -and -not $localCfgCodeProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/LocalOverrideRejectsExecutableCode" `
        -Failure "BRAVO.local.config — data-only: файл із виконуваним кодом мусить відхилятись (CheckRestrictedLanguage); отримано: $localCfgCodeProbe"

    # --- Без файла -> штатне завантаження, metadata порожній.
    Remove-Item -LiteralPath $localCfgOverridePath -Force
    $localCfgAbsentProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command (
                "try { " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$localCfgScenarioRoot' -RuntimeRoot '$root'); " +
                "'OK ' + (@(`$global:BravoConfigurationMetadata.LocalConfigOverrides).Count) " +
                "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
            ) 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($localCfgAbsentProbe.Contains('OK 0')) `
        -Name "ConfigLoader/LocalOverrideFileAbsentIsNoop" `
        -Failure "відсутній BRAVO.local.config = штатне завантаження без overrides; отримано: $localCfgAbsentProbe"
} finally {
    Remove-Item -LiteralPath $localCfgScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# schedulerSettings.Health.BusyWaitMinutes (5.2.1): loader-нормалізація
# ліміту очікування зайнятої архівації перед відкладенням health-прогону.
# Кожен сценарій — ізольований дочірній powershell.exe (Import-BravoConfiguration
# змінює глобальний стан); конфіг герметизовано явним BackupRoot (та сама
# CI-пастка, що й у local-config сценаріях вище).
# ============================================================
$busyWaitScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_BUSYWAIT_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($busyWaitScenarioRoot)
    $busyWaitBackupDir = Join-Path $busyWaitScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($busyWaitBackupDir)
    $busyWaitKitText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
    $busyWaitBackupRootLine = '    BackupRoot    = ""'
    $busyWaitKeyLine = '        BusyWaitMinutes = 60'
    foreach ($busyWaitRequiredLine in @($busyWaitBackupRootLine, $busyWaitKeyLine)) {
        if (-not $busyWaitKitText.Contains($busyWaitRequiredLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$busyWaitRequiredLine' — оновіть підготовку BusyWaitMinutes-сценаріїв під нову форму конфігурації"
        }
    }
    $busyWaitHermeticText = $busyWaitKitText.Replace(
        $busyWaitBackupRootLine,
        "    BackupRoot    = '$($busyWaitBackupDir.Replace("'", "''"))'"
    )
    $busyWaitProbeCommand = (
        "try { " +
        "Set-StrictMode -Version 2.0; " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$busyWaitScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'VALUE=' + [string]`$global:schedulerSettings.Health.BusyWaitMinutes " +
        "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
    )
    $busyWaitCases = @(
        @{
            Name = 'ConfigLoader/HealthBusyWaitLegacyConfigGetsCanonicalDefault'
            ConfigText = $busyWaitHermeticText.Replace("$busyWaitKeyLine`r`n", '')
            Expected = 'VALUE=60'
            Failure = 'legacy-конфіг без schedulerSettings.Health.BusyWaitMinutes мусить отримувати канонічний loader-дефолт 60 (компат-нормалізація, без Warning)'
        },
        @{
            Name = 'ConfigLoader/HealthBusyWaitExplicitZeroIsPreserved'
            ConfigText = $busyWaitHermeticText.Replace($busyWaitKeyLine, '        BusyWaitMinutes = 0')
            Expected = 'VALUE=0'
            Failure = 'явний BusyWaitMinutes = 0 (стара поведінка: негайне відкладення) мусить зберігатись, а не затиратись дефолтом'
        },
        @{
            Name = 'ConfigLoader/HealthBusyWaitInvalidValueFallsBackToDefault'
            ConfigText = $busyWaitHermeticText.Replace($busyWaitKeyLine, "        BusyWaitMinutes = 'abc'")
            Expected = 'VALUE=60'
            Failure = "нечислове/поза-діапазонне BusyWaitMinutes мусить нормалізуватись до канонічних 60 хв (з Warning), а не протікати в runtime як рядок"
        }
    )
    foreach ($busyWaitCase in $busyWaitCases) {
        [IO.File]::WriteAllText(
            (Join-Path $busyWaitScenarioRoot 'BRAVO.config'),
            [string]$busyWaitCase.ConfigText,
            (New-Object System.Text.UTF8Encoding $false)
        )
        $busyWaitProbe = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $busyWaitProbeCommand 2>&1 | Out-String
        )
        Test-BRAVOCondition `
            -Condition ($busyWaitProbe.Contains([string]$busyWaitCase.Expected)) `
            -Name ([string]$busyWaitCase.Name) `
            -Failure "$($busyWaitCase.Failure); отримано: $busyWaitProbe"
    }
} finally {
    Remove-Item -LiteralPath $busyWaitScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# backupMonitoring.SuccessDedupMinutes (5.2.1): loader-нормалізація вікна
# дедуплікації зелених success-звітів + деривація SuccessNotificationStatePath
# для legacy-конфігів. Той самий герметичний патерн, що й BusyWaitMinutes вище.
# ============================================================
$successDedupScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_SUCCESSDEDUP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($successDedupScenarioRoot)
    $successDedupBackupDir = Join-Path $successDedupScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($successDedupBackupDir)
    $successDedupKitText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
    $successDedupBackupRootLine = '    BackupRoot    = ""'
    $successDedupKeyLine = '    SuccessDedupMinutes = 1380'
    # P0 Configuration Foundation (PR B): SuccessNotificationStatePath і
    # OperationalStatePath більше не raw-літерали в BRAVO.config — це
    # безумовно похідні поля, які тепер завжди обчислює
    # Resolve-BRAVOConfigurationDerivation (modules/BRAVO.Configuration/
    # BRAVO.Configuration.Derivation.psm1), а не сам BRAVO.config. Форма
    # рядків тепер інша ($global:backupMonitoring.X = ..., без 4-
    # пробільного raw-hashtable відступу) — і, оскільки поле обчислюється
    # безумовно (не за raw-ключем), .Replace(...) на цих двох рядках у
    # $successDedupHermeticText нижче — навмисний no-op (більше нема що
    # прибирати з BRAVO.config): деривація й так виробляє шлях незалежно
    # від вмісту raw-конфігу, тому "legacy" і "поточний" сценарії для цих
    # двох конкретних полів тепер еквівалентні.
    $successDedupStatePathLine = '    SuccessNotificationStatePath = Join-Path $stateRoot "BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json"'
    $operationalStatePathLine = '    OperationalStatePath = Join-Path $stateRoot "BRAVO_HEALTH_OPERATIONAL_STATE.json"'
    $successDedupDerivationText = [IO.File]::ReadAllText(
        (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psm1'))
    foreach ($successDedupRequiredLine in @($successDedupBackupRootLine, $successDedupKeyLine)) {
        if (-not $successDedupKitText.Contains($successDedupRequiredLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$successDedupRequiredLine' — оновіть підготовку SuccessDedup-сценаріїв під нову форму конфігурації"
        }
    }
    foreach ($successDedupDerivedLine in @(
        '$global:backupMonitoring.SuccessNotificationStatePath = Join-Path $stateRoot "BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json"',
        '$global:backupMonitoring.OperationalStatePath = Join-Path $stateRoot "BRAVO_HEALTH_OPERATIONAL_STATE.json"'
    )) {
        if (-not $successDedupDerivationText.Contains($successDedupDerivedLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.Configuration.Derivation.psm1 не знайдено рядок '$successDedupDerivedLine' — оновіть підготовку SuccessDedup-сценаріїв під нову форму деривації"
        }
    }
    $successDedupHermeticText = $successDedupKitText.Replace(
        $successDedupBackupRootLine,
        "    BackupRoot    = '$($successDedupBackupDir.Replace("'", "''"))'"
    )
    $successDedupProbeCommand = (
        "try { " +
        "Set-StrictMode -Version 2.0; " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$successDedupScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'VALUE=' + [string]`$global:backupMonitoring.SuccessDedupMinutes + ';PATH=' + [string]`$global:backupMonitoring.SuccessNotificationStatePath + ';OPPATH=' + [string]`$global:backupMonitoring.OperationalStatePath " +
        "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
    )
    $successDedupCases = @(
        @{
            Name = 'ConfigLoader/HealthSuccessDedupLegacyConfigGetsCanonicalDefault'
            ConfigText = $successDedupHermeticText.Replace("$successDedupKeyLine`r`n", '').Replace("$successDedupStatePathLine`r`n", '')
            Expected = 'VALUE=1380;PATH='
            Failure = 'legacy-конфіг без backupMonitoring.SuccessDedupMinutes мусить отримувати канонічний loader-дефолт 1380 (компат-нормалізація, без Warning)'
        },
        @{
            Name = 'ConfigLoader/HealthSuccessDedupLegacyStatePathDerivedFromAlertState'
            ConfigText = $successDedupHermeticText.Replace("$successDedupKeyLine`r`n", '').Replace("$successDedupStatePathLine`r`n", '')
            Expected = 'BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json'
            Failure = 'legacy-конфіг без SuccessNotificationStatePath мусить отримувати шлях, деривований від каталогу AlertStatePath'
        },
        @{
            Name = 'ConfigLoader/HealthOperationalStatePathDerivedForLegacyConfig'
            ConfigText = $successDedupHermeticText.Replace("$operationalStatePathLine`r`n", '')
            Expected = 'BRAVO_HEALTH_OPERATIONAL_STATE.json'
            Failure = 'legacy-конфіг без OperationalStatePath мусить отримувати шлях операційного recovery-стану, деривований від каталогу AlertStatePath'
        },
        @{
            Name = 'ConfigLoader/HealthSuccessDedupExplicitZeroIsPreserved'
            ConfigText = $successDedupHermeticText.Replace($successDedupKeyLine, '    SuccessDedupMinutes = 0')
            Expected = 'VALUE=0;'
            Failure = 'явний SuccessDedupMinutes = 0 (дедуп вимкнено, стара поведінка) мусить зберігатись, а не затиратись дефолтом'
        },
        @{
            Name = 'ConfigLoader/HealthSuccessDedupInvalidValueFallsBackToDefault'
            ConfigText = $successDedupHermeticText.Replace($successDedupKeyLine, "    SuccessDedupMinutes = 'abc'")
            Expected = 'VALUE=1380;'
            Failure = "нечислове/поза-діапазонне SuccessDedupMinutes мусить нормалізуватись до канонічних 1380 хв (з Warning), а не протікати в runtime як рядок"
        }
    )
    foreach ($successDedupCase in $successDedupCases) {
        [IO.File]::WriteAllText(
            (Join-Path $successDedupScenarioRoot 'BRAVO.config'),
            [string]$successDedupCase.ConfigText,
            (New-Object System.Text.UTF8Encoding $false)
        )
        $successDedupProbe = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $successDedupProbeCommand 2>&1 | Out-String
        )
        Test-BRAVOCondition `
            -Condition ($successDedupProbe.Contains([string]$successDedupCase.Expected)) `
            -Name ([string]$successDedupCase.Name) `
            -Failure "$($successDedupCase.Failure); отримано: $successDedupProbe"
    }
} finally {
    Remove-Item -LiteralPath $successDedupScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}
# ============================================================
# componentSettings.SFTP.Enabled / SMB.Enabled (5.2.2): глобальні
# master-вимикачі зовнішніх сховищ. Loader-нормалізація (відсутній ключ =
# $true), strict-bool валідація (не-bool = канонічна помилка), raw vs
# effective розділення і узгодження bazaSyncEffective/BAZASync.
# Кожен сценарій — ізольований дочірній powershell.exe.
# ============================================================
$storageSwitchScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_STORAGESW_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($storageSwitchScenarioRoot)
    $storageSwitchBackupDir = Join-Path $storageSwitchScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($storageSwitchBackupDir)
    $storageSwitchKitText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
    $storageSwitchBackupRootLine = '    BackupRoot    = ""'
    $storageSwitchSftpBlock = "    SFTP = @{`r`n        Enabled = `$true`r`n        ArchiveUpload = `$true`r`n    }"
    $storageSwitchSmbBlock = "    SMB = @{`r`n        Enabled = `$true"
    foreach ($storageSwitchRequiredLine in @($storageSwitchBackupRootLine, $storageSwitchSftpBlock, $storageSwitchSmbBlock)) {
        if (-not $storageSwitchKitText.Contains($storageSwitchRequiredLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено фрагмент '$storageSwitchRequiredLine' — оновіть підготовку storage-switch сценаріїв під нову форму конфігурації"
        }
    }
    $storageSwitchHermeticText = $storageSwitchKitText.Replace(
        $storageSwitchBackupRootLine,
        "    BackupRoot    = '$($storageSwitchBackupDir.Replace("'", "''"))'"
    )
    # Probe: effective-значення, raw-збереження і узгодження деривацій в
    # одному рядку — щоб кожен кейс перевірявся атомарно.
    $storageSwitchProbeCommand = (
        "try { " +
        "Set-StrictMode -Version 2.0; " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$storageSwitchScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'SFTPEN=' + [string]`$global:storageEffective.SFTP.Enabled + " +
        "';SFTPUP=' + [string]`$global:storageEffective.SFTP.ArchiveUpload + " +
        "';SMBEN=' + [string]`$global:storageEffective.SMB.Enabled + " +
        "';SMBCP=' + [string]`$global:storageEffective.SMB.ArchiveCopy + " +
        "';RAWUP=' + [string]`$global:componentSettings.SFTP.ArchiveUpload + " +
        "';SCHED=' + [string]`$global:schedulerSettings.BAZASync.Enabled + " +
        "';REQ=' + [string]`$global:bazaSyncEffective.ScheduledSftpSyncRequired " +
        "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
    )
    $storageSwitchCases = @(
        @{
            Name = 'ConfigLoader/StorageSwitchLegacyConfigDefaultsToEnabled'
            ConfigText = $storageSwitchHermeticText.Replace("        Enabled = `$true`r`n", '')
            LocalOverride = $null
            Expected = 'SFTPEN=True;SFTPUP=True;SMBEN=True'
            Failure = 'legacy-конфіг без componentSettings.SFTP.Enabled/SMB.Enabled мусить трактуватись як увімкнений (поведінка 5.2.1 зберігається)'
        },
        @{
            Name = 'ConfigLoader/StorageSwitchSftpDisabledKeepsRawChildAndDropsEffective'
            ConfigText = $storageSwitchHermeticText.Replace(
                $storageSwitchSftpBlock,
                "    SFTP = @{`r`n        Enabled = `$false`r`n        ArchiveUpload = `$true`r`n    }"
            )
            LocalOverride = $null
            Expected = 'SFTPEN=False;SFTPUP=False;SMBEN=True;SMBCP=False;RAWUP=True;SCHED=False;REQ=False'
            Failure = 'SFTP.Enabled=$false мусить занулити effective ArchiveUpload/BAZASync (SCHED/REQ=False), зберігши raw ArchiveUpload=$true; SMB незалежний'
        },
        @{
            Name = 'ConfigLoader/StorageSwitchInvalidValueIsCanonicalConfigError'
            ConfigText = $storageSwitchHermeticText.Replace(
                $storageSwitchSftpBlock,
                "    SFTP = @{`r`n        Enabled = 'yes'`r`n        ArchiveUpload = `$true`r`n    }"
            )
            LocalOverride = $null
            Expected = 'CHILD-ERROR:'
            ExpectedAlso = 'componentSettings.SFTP.Enabled'
            Failure = "не-bool значення Enabled мусить давати канонічну помилку конфігурації (fail-closed), а не тихе приведення"
        },
        @{
            Name = 'ConfigLoader/StorageSwitchLocalOverrideDisablesBothPhase1'
            ConfigText = $storageSwitchHermeticText
            LocalOverride = (
                "@{`r`n" +
                "    'componentSettings.SFTP.Enabled' = `$false`r`n" +
                "    'componentSettings.SMB.Enabled' = `$false`r`n" +
                "}`r`n"
            )
            Expected = 'SFTPEN=False;SFTPUP=False;SMBEN=False;SMBCP=False;RAWUP=True;SCHED=False;REQ=False'
            Failure = 'BRAVO.local.config override обох master-вимикачів (фаза 1, до деривацій) мусить давати local-only режим без зміни raw-прапорців'
        },
        @{
            Name = 'ConfigLoader/StorageSwitchReEnableRestoresEffectiveState'
            ConfigText = $storageSwitchHermeticText
            LocalOverride = $null
            Expected = 'SFTPEN=True;SFTPUP=True;SMBEN=True;SMBCP=False;RAWUP=True;SCHED=True;REQ=True'
            Failure = 'повернення Enabled=$true (комплектний дефолт) мусить відновлювати effective-поведінку 5.2.1 без ручної зміни дочірніх прапорців'
        }
    )
    $storageSwitchLocalConfigPath = Join-Path $storageSwitchScenarioRoot 'BRAVO.local.config'
    foreach ($storageSwitchCase in $storageSwitchCases) {
        [IO.File]::WriteAllText(
            (Join-Path $storageSwitchScenarioRoot 'BRAVO.config'),
            [string]$storageSwitchCase.ConfigText,
            (New-Object System.Text.UTF8Encoding $false)
        )
        if ($null -ne $storageSwitchCase.LocalOverride) {
            [IO.File]::WriteAllText($storageSwitchLocalConfigPath, [string]$storageSwitchCase.LocalOverride, (New-Object System.Text.UTF8Encoding $false))
        } elseif (Test-Path -LiteralPath $storageSwitchLocalConfigPath) {
            Remove-Item -LiteralPath $storageSwitchLocalConfigPath -Force
        }
        $storageSwitchProbe = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $storageSwitchProbeCommand 2>&1 | Out-String
        )
        $storageSwitchMatched = $storageSwitchProbe.Contains([string]$storageSwitchCase.Expected)
        if ($storageSwitchMatched -and $storageSwitchCase.Contains('ExpectedAlso')) {
            $storageSwitchMatched = $storageSwitchProbe.Contains([string]$storageSwitchCase.ExpectedAlso)
        }
        Test-BRAVOCondition `
            -Condition $storageSwitchMatched `
            -Name ([string]$storageSwitchCase.Name) `
            -Failure "$($storageSwitchCase.Failure); отримано: $storageSwitchProbe"
    }
} finally {
    Remove-Item -LiteralPath $storageSwitchScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# P0 Configuration Foundation (PR C): BRAVO.config став опційним основним
# override-шаром. Import-BravoSyntheticConfiguration (canonical defaults +
# Resolve-BRAVORawConfiguration + Resolve-BRAVOConfigurationDerivation) —
# той самий derivation-резолвер, що й legacy-шлях, без BRAVO.config-файлу.
# Кожен сценарій — ізольований дочірній powershell.exe; BackupRoot
# передається через BRAVO.local.config (герметичність на машині без LIMS,
# той самий патерн, що й у сценаріях вище).
# ============================================================
$noConfigScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_NOCONFIG_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    [void][IO.Directory]::CreateDirectory($noConfigScenarioRoot)
    $noConfigBackupDir = Join-Path $noConfigScenarioRoot 'SITE_DEFAULT'
    [void][IO.Directory]::CreateDirectory($noConfigBackupDir)
    $noConfigBackupLiteral = $noConfigBackupDir.Replace("'", "''")
    $noConfigLocalOverridePath = Join-Path $noConfigScenarioRoot 'BRAVO.local.config'
    [IO.File]::WriteAllText($noConfigLocalOverridePath, (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$noConfigBackupLiteral'`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))

    # --- Немає BRAVO.config за auto-derived шляхом -> НЕ помилка: canonical
    # дефолти + BRAVO.local.config, Format=synthetic-no-config. Регресія для
    # двох дірок, знайдених живим тестуванням реального entrypoint-а:
    # credentialSettings.HelperPath/SetupScriptPath і
    # maintenanceSettings.General.ObjectName/ArchivePrefix обчислювались
    # inline в raw-блоці BRAVO.config ДО появи derivation-резолвера й були
    # пропущені під час PR B екстракції.
    $noConfigProbeCommand = (
        "try { " +
        "Set-StrictMode -Version 2.0; " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$noConfigScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'FORMAT=' + [string]`$global:BravoConfigurationMetadata.Format + " +
        "';INST=' + [string]`$global:bravoSettings.InstitutionName + " +
        "';HELPER=' + [string]`$global:credentialSettings.HelperPath + " +
        "';SETUP=' + [string]`$global:credentialSettings.SetupScriptPath + " +
        "';OBJNAME=' + [string]`$global:maintenanceSettings.General.ObjectName + " +
        "';ARCHPFX=' + [string]`$global:maintenanceSettings.General.ArchivePrefix + " +
        "';LOCKPATH=' + [string]`$global:operationLockSettings.Path " +
        "} catch { 'CHILD-ERROR: ' + `$_.Exception.Message }"
    )
    # Захоплення виводу дочірнього процесу з кирилицею (InstitutionName/
    # ObjectName) потребує явного UTF-8 OutputEncoding — інакше системна
    # кодова сторінка ламає багатобайтові послідовності (той самий
    # відомий пастка, що й у local-only SFTP/SMB сценарії BRAVO_SELF_TEST.ps1).
    $noConfigPreviousOutputEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $noConfigProbe = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $noConfigProbeCommand 2>&1 | Out-String
        )
    } finally {
        [Console]::OutputEncoding = $noConfigPreviousOutputEncoding
    }
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('FORMAT=synthetic-no-config') `
        -Name "ConfigLoader/NoConfigAutoDerivedPathSucceedsAsSynthetic" `
        -Failure "auto-derived шлях (ConfigRoot\BRAVO.config), що не існує, мусить завантажуватись як synthetic-no-config, а не кидати помилку; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('INST=УСТАНОВА') `
        -Name "ConfigLoader/NoConfigCanonicalDefaultsApplied" `
        -Failure "synthetic-шлях мусить давати canonical дефолт bravoSettings.InstitutionName з Get-BRAVODefaultConfiguration; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition (
            $noConfigProbe.Contains('HELPER=') -and -not $noConfigProbe.Contains('HELPER=;') -and
            $noConfigProbe.Contains('BRAVO.Credentials.psd1')
        ) `
        -Name "ConfigLoader/NoConfigCredentialSettingsHelperPathDerived" `
        -Failure "synthetic-шлях мусить обчислювати credentialSettings.HelperPath (раніше — StrictMode-крах у реальному entrypoint-і); отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition (
            $noConfigProbe.Contains('SETUP=') -and
            $noConfigProbe.Contains('BRAVO_CREDENTIALS_SETUP.ps1')
        ) `
        -Name "ConfigLoader/NoConfigCredentialSettingsSetupScriptPathDerived" `
        -Failure "synthetic-шлях мусить обчислювати credentialSettings.SetupScriptPath; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('OBJNAME=УСТАНОВА [00000000]') `
        -Name "ConfigLoader/NoConfigMaintenanceGeneralObjectNameDerived" `
        -Failure "synthetic-шлях мусить обчислювати maintenanceSettings.General.ObjectName з canonical bravoSettings; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('ARCHPFX=lab_v2412') `
        -Name "ConfigLoader/NoConfigMaintenanceGeneralArchivePrefixDerived" `
        -Failure "synthetic-шлях мусить обчислювати maintenanceSettings.General.ArchivePrefix з canonical bravoSettings; отримано: $noConfigProbe"
    Test-BRAVOCondition `
        -Condition $noConfigProbe.Contains('BRAVO_OPERATION.lock') `
        -Name "ConfigLoader/NoConfigOperationLockSettingsDerived" `
        -Failure "synthetic-шлях мусить обчислювати operationLockSettings.Path так само, як legacy-шлях; отримано: $noConfigProbe"

    # --- Явний -ConfigPath на неіснуючий файл лишається помилкою (свідомий
    # намір != auto-похідна відсутність). -ConfigPathWasExplicit тепер
    # ЄДИНЕ джерело правди (Секція 2 PR C) — caller (тут: сам probe,
    # симулюючи справжній entrypoint) обчислює намір зі свого власного
    # $PSBoundParameters і передає його явно; loader більше НЕ вгадує
    # намір за збігом/відмінністю шляху.
    $noConfigExplicitMissingPath = Join-Path $noConfigScenarioRoot 'BRAVO_EXPLICIT_MISSING.config'
    $noConfigExplicitProbeCommand = (
        "try { " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$noConfigScenarioRoot' -ConfigPath '$noConfigExplicitMissingPath' -RuntimeRoot '$root' -ConfigPathWasExplicit 3>`$null); " +
        "'NO-THROW'" +
        "} catch { 'THREW: ' + `$_.Exception.Message }"
    )
    $noConfigExplicitProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $noConfigExplicitProbeCommand 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($noConfigExplicitProbe.Contains('THREW:') -and -not $noConfigExplicitProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/NoConfigExplicitMissingConfigPathStillThrows" `
        -Failure "явно вказаний -ConfigPath на неіснуючий файл мусить лишатись помилкою конфігурації навіть після появи no-config шляху; отримано: $noConfigExplicitProbe"

    # ============================================================
    # P0 Configuration Foundation (PR C, Секція 2): повна регресійна
    # матриця explicit-vs-auto intent — включно з Test 5, що ловить
    # дефект СТАРОЇ (незакомiченої) евристики "resolved == auto-derived":
    # оператор, що явно набрав РІВНО той самий шлях, який auto-derivation
    # синтезувала б сама, все одно мав намір "цей файл МУСИТЬ існувати".
    # -ConfigPathWasExplicit — незалежний від значення шляху прапорець.
    # ============================================================
    $intentMatrixExternalRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_INTENTMATRIX_EXTERNAL_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($intentMatrixExternalRoot)
        $intentMatrixExternalConfigPath = Join-Path $intentMatrixExternalRoot 'CUSTOM_SITE1.config'
        # Мінімальний легітимний BRAVO.config: лише BackupRoot (герметичність,
        # той самий CI-пастка коментар, що й у сценаріях вище) — решта з
        # canonical defaults через $global:bravoSettings/... блоки-заглушки
        # реального BRAVO.config тут не потрібні, оскільки цей probe лише
        # перевіряє факт PASS/ERROR завантаження, не effective-значення.
        $intentMatrixKitText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
        $intentMatrixBackupDir = Join-Path $intentMatrixExternalRoot 'SITE_BACKUP'
        [void][IO.Directory]::CreateDirectory($intentMatrixBackupDir)
        $intentMatrixBackupRootLine = '    BackupRoot    = ""'
        if (-not $intentMatrixKitText.Contains($intentMatrixBackupRootLine)) {
            throw "BRAVO_SELF_TEST.ConfigLoader: у BRAVO.config не знайдено рядок '$intentMatrixBackupRootLine' — оновіть підготовку intent-matrix сценаріїв під нову форму конфігурації"
        }
        [IO.File]::WriteAllText(
            $intentMatrixExternalConfigPath,
            $intentMatrixKitText.Replace(
                $intentMatrixBackupRootLine,
                "    BackupRoot    = '$($intentMatrixBackupDir.Replace("'", "''"))'"
            ),
            (New-Object System.Text.UTF8Encoding $false)
        )
        $intentMatrixDefaultCandidatePath = Join-Path $noConfigScenarioRoot 'BRAVO.config'

        $intentMatrixCases = @(
            @{
                Name = 'ConfigLoader/IntentMatrix2ExplicitExternalExistingPasses'
                ConfigRoot = $intentMatrixExternalRoot
                ConfigPathArg = $intentMatrixExternalConfigPath
                Explicit = $true
                ExpectThrow = $false
                Failure = 'Test 2: explicit external existing -> PASS'
            },
            @{
                Name = 'ConfigLoader/IntentMatrix3ExplicitExternalMissingErrors'
                ConfigRoot = $intentMatrixExternalRoot
                ConfigPathArg = (Join-Path $intentMatrixExternalRoot 'MISSING_SITE.config')
                Explicit = $true
                ExpectThrow = $true
                Failure = 'Test 3: explicit external missing -> ERROR'
            },
            @{
                Name = 'ConfigLoader/IntentMatrix4ExplicitDefaultCandidateExistingPasses'
                ConfigRoot = $noConfigScenarioRoot
                ConfigPathArg = $intentMatrixDefaultCandidatePath
                Explicit = $true
                ExpectThrow = $false
                # Потребує реального BRAVO.config за default-шляхом у
                # noConfigScenarioRoot — записується лише на час цього case.
                RequiresDefaultCandidateFile = $true
                Failure = 'Test 4: explicit default-candidate existing -> PASS'
            },
            @{
                Name = 'ConfigLoader/IntentMatrix5ExplicitDefaultCandidateMissingErrors'
                ConfigRoot = $noConfigScenarioRoot
                ConfigPathArg = $intentMatrixDefaultCandidatePath
                Explicit = $true
                ExpectThrow = $true
                Failure = 'Test 5 (КРИТИЧНИЙ — ловить дефект path-equality евристики): explicit шлях, що ТЕКСТОВО збігається з auto-похідним default-candidate, але фізично відсутній -> ERROR, не тихий no-config fallback'
            },
            @{
                Name = 'ConfigLoader/IntentMatrix6WhitespaceConfigPathIsNotOperatorIntent'
                ConfigRoot = $noConfigScenarioRoot
                ConfigPathArg = '   '
                Explicit = $true
                ExpectThrow = $false
                Failure = 'Test 6: -ConfigPathWasExplicit разом із null/whitespace -ConfigPath не є свідомим наміром -> AUTO (canonical дефолти), не помилка'
            }
        )
        foreach ($intentMatrixCase in $intentMatrixCases) {
            if ($intentMatrixCase.Contains('RequiresDefaultCandidateFile') -and $intentMatrixCase.RequiresDefaultCandidateFile) {
                [IO.File]::Copy($intentMatrixExternalConfigPath, $intentMatrixDefaultCandidatePath, $true)
            } elseif (Test-Path -LiteralPath $intentMatrixDefaultCandidatePath -PathType Leaf) {
                Remove-Item -LiteralPath $intentMatrixDefaultCandidatePath -Force
            }
            $intentMatrixExplicitArg = if ($intentMatrixCase.Explicit) { '-ConfigPathWasExplicit' } else { '' }
            $intentMatrixProbeCommand = (
                "try { " +
                ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
                "[void](Import-BravoConfiguration -ConfigRoot '$($intentMatrixCase.ConfigRoot)' -ConfigPath '$($intentMatrixCase.ConfigPathArg)' -RuntimeRoot '$root' $intentMatrixExplicitArg 3>`$null); " +
                "'NO-THROW'" +
                "} catch { 'THREW' }"
            )
            $intentMatrixProbe = [string](
                & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $intentMatrixProbeCommand 2>&1 | Out-String
            )
            $intentMatrixThrew = $intentMatrixProbe.Contains('THREW') -and -not $intentMatrixProbe.Contains('NO-THROW')
            Test-BRAVOCondition `
                -Condition ($intentMatrixThrew -eq [bool]$intentMatrixCase.ExpectThrow) `
                -Name ([string]$intentMatrixCase.Name) `
                -Failure "$($intentMatrixCase.Failure); очікувалось ExpectThrow=$($intentMatrixCase.ExpectThrow), отримано THREW=$intentMatrixThrew, вивід: $intentMatrixProbe"
        }
        if (Test-Path -LiteralPath $intentMatrixDefaultCandidatePath -PathType Leaf) {
            Remove-Item -LiteralPath $intentMatrixDefaultCandidatePath -Force
        }
    } finally {
        Remove-Item -LiteralPath $intentMatrixExternalRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Невідомий dot-шлях у BRAVO.local.config у no-config режимі так
    # само fail-closed, як і в legacy-шляху (Resolve-BRAVORawConfiguration
    # через ConvertTo-BRAVONestedOverride кидає на невідомому top-level
    # ключі одним проходом до злиття).
    [IO.File]::WriteAllText($noConfigLocalOverridePath, (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$noConfigBackupLiteral'`r`n" +
        "    'noSuchTopLevelKey.Sub' = 'x'`r`n" +
        "}`r`n"
    ), (New-Object System.Text.UTF8Encoding $false))
    $noConfigTypoProbeCommand = (
        "try { " +
        ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
        "[void](Import-BravoConfiguration -ConfigRoot '$noConfigScenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
        "'NO-THROW'" +
        "} catch { 'THREW'" +
        " }"
    )
    $noConfigTypoProbe = [string](
        & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $noConfigTypoProbeCommand 2>&1 | Out-String
    )
    Test-BRAVOCondition `
        -Condition ($noConfigTypoProbe.Contains('THREW') -and -not $noConfigTypoProbe.Contains('NO-THROW')) `
        -Name "ConfigLoader/NoConfigLocalOverrideUnknownKeyFailsClosed" `
        -Failure "невідомий top-level dot-шлях у BRAVO.local.config за no-config шляху мусить fail-closed так само, як legacy-шлях; отримано: $noConfigTypoProbe"
} finally {
    Remove-Item -LiteralPath $noConfigScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# P0 Configuration Foundation (PR C, Секція 4): МЕХАНІЧНИЙ parity-тест —
# ОДИН і той самий BRAVO.local.config має давати ОДНАКОВИЙ accept/reject
# результат і ОДНАКОВЕ ефективне raw-значення незалежно від того, чи
# присутній BRAVO.config (legacy primary), чи ні (synthetic). До Секції 3
# config-present-шлях ішов через окремий, м'якший
# Invoke-BRAVOLocalConfigurationOverridePhase (дозволяв НОВИЙ leaf у ВЖЕ
# існуючому hashtable-вузлі), а config-absent — одразу через строгіший
# ConvertTo-BRAVONestedOverride (вимагав, щоб і сам leaf уже існував у
# Get-BRAVODefaultConfiguration) — те саме BRAVO.local.config давало
# різний результат залежно від шляху (задокументований дефект, знайдений
# на review). Тепер обидва шляхи йдуть через ОДИН
# Complete-BRAVOConfigurationLoad -> ConvertTo-BRAVONestedOverride виклик
# з ОДНИМ контрактом (батьківські сегменти мають існувати; для
# багатосегментних шляхів сам leaf форвард-сумісно НЕ мусить вже
# існувати) — цей тест доводить збіг результату механічно на РЕАЛЬНОМУ
# loader-виклику для обох шляхів, а не як припущення з архітектури.
# ============================================================
$parityBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_PARITY_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($parityBackupRootDir)
$parityBackupRootLiteral = $parityBackupRootDir.Replace("'", "''")

function New-BRAVOConfigLoaderParityProbe {
    param(
        [Parameter(Mandatory = $true)][bool]$WithPrimary,
        [Parameter(Mandatory = $true)][string]$LocalConfigBody
    )
    $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) (
        "BRAVO_PARITY_{0}_{1}" -f $(if ($WithPrimary) { 'PRIMARY' } else { 'NOCONFIG' }), [guid]::NewGuid().ToString('N')
    )
    [void][IO.Directory]::CreateDirectory($scenarioRoot)
    try {
        if ($WithPrimary) {
            $primaryText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'), [Text.Encoding]::UTF8)
            [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.config'), $primaryText, (New-Object System.Text.UTF8Encoding($false)))
        }
        [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.local.config'), $LocalConfigBody, (New-Object System.Text.UTF8Encoding($false)))
        $probeCommand = (
            "try { " +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$scenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
            "'RESULT:BackupRoot=' + [string]`$global:pathSettings.BackupRoot + " +
            "';FutureField=' + [string]`$global:maintenanceSettings.FutureFieldNotYetInSchema" +
            "} catch { 'THREW: ' + `$_.Exception.Message }"
        )
        $probeOutput = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probeCommand 2>&1 | Out-String
        )
        return $probeOutput.Trim()
    } finally {
        Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    # --- Parity 1: відомий override (pathSettings.BackupRoot) +
    # forward-compat новий leaf (maintenanceSettings.FutureFieldNotYetInSchema,
    # відсутній у Get-BRAVODefaultConfiguration, але maintenanceSettings —
    # реальний hashtable-вузол) МАЄ пережити roundtrip і дати ОДНАКОВЕ
    # значення в ОБОХ режимах.
    $parityForwardCompatBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$parityBackupRootLiteral'`r`n" +
        "    'maintenanceSettings.FutureFieldNotYetInSchema' = 'preserve-me'`r`n" +
        "}`r`n"
    )
    $parityNoConfigResult = New-BRAVOConfigLoaderParityProbe -WithPrimary $false -LocalConfigBody $parityForwardCompatBody
    $parityPrimaryResult = New-BRAVOConfigLoaderParityProbe -WithPrimary $true -LocalConfigBody $parityForwardCompatBody
    $parityForwardCompatExpected = "RESULT:BackupRoot=$parityBackupRootDir;FutureField=preserve-me"
    Test-BRAVOCondition `
        -Condition (
            $parityNoConfigResult -eq $parityForwardCompatExpected -and
            $parityPrimaryResult -eq $parityForwardCompatExpected
        ) `
        -Name "ConfigLoader/LocalOverrideParityForwardCompatLeaf" `
        -Failure "той самий BRAVO.local.config (відомий override + forward-compat новий leaf) має дати ОДНАКОВИЙ результат у config-present і config-absent; noConfig='$parityNoConfigResult' primary='$parityPrimaryResult' очікувалось='$parityForwardCompatExpected'"

    # --- Parity 2: генуїнно невідомий TOP-LEVEL ключ МАЄ fail-closed
    # ОДНАКОВО в ОБОХ режимах (typo-захист не повинен розійтися).
    $parityUnknownTopLevelBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$parityBackupRootLiteral'`r`n" +
        "    'noSuchTopLevelKey.Sub' = 'x'`r`n" +
        "}`r`n"
    )
    $parityNoConfigUnknownResult = New-BRAVOConfigLoaderParityProbe -WithPrimary $false -LocalConfigBody $parityUnknownTopLevelBody
    $parityPrimaryUnknownResult = New-BRAVOConfigLoaderParityProbe -WithPrimary $true -LocalConfigBody $parityUnknownTopLevelBody
    Test-BRAVOCondition `
        -Condition (
            $parityNoConfigUnknownResult.StartsWith('THREW') -and
            $parityPrimaryUnknownResult.StartsWith('THREW')
        ) `
        -Name "ConfigLoader/LocalOverrideParityUnknownTopLevelKeyBothFail" `
        -Failure "генуїнно невідомий top-level ключ у BRAVO.local.config має fail-closed ОДНАКОВО в config-present і config-absent; noConfig='$parityNoConfigUnknownResult' primary='$parityPrimaryUnknownResult'"
} finally {
    Remove-Item -LiteralPath $parityBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# P0 Configuration Foundation (PR C, Секція 5.4): ФІНАЛЬНА post-merge
# перевірка безпеки (Test-BRAVOEffectiveSecurityInvariants,
# BRAVO_CONFIG_LOADER.ps1) — BRAVO.local.config НЕ повинен мати змогу
# обійти pre-trust guard (BRAVO_RUNTIME_GUARD.ps1 бачить лише текст
# BRAVO.config, не BRAVO.local.config). Обов'язкові тести з ТЗ:
# BRAVO.config відсутній + BRAVO.local.config послаблює захист -> BLOCK;
# те саме в config-present режимі теж має блокувати.
# ============================================================
$secDowngradeBackupRootDir = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_SECDOWNGRADE_BACKUP_{0}" -f [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($secDowngradeBackupRootDir)
$secDowngradeBackupRootLiteral = $secDowngradeBackupRootDir.Replace("'", "''")

function New-BRAVOConfigLoaderSecurityDowngradeProbe {
    param(
        [Parameter(Mandatory = $true)][bool]$WithPrimary,
        [Parameter(Mandatory = $true)][string]$LocalConfigBody,
        [string]$AllowWeakenedEnvValue = ''
    )
    $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) (
        "BRAVO_SECDOWNGRADE_{0}_{1}" -f $(if ($WithPrimary) { 'PRIMARY' } else { 'NOCONFIG' }), [guid]::NewGuid().ToString('N')
    )
    [void][IO.Directory]::CreateDirectory($scenarioRoot)
    try {
        if ($WithPrimary) {
            $primaryText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'), [Text.Encoding]::UTF8)
            [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.config'), $primaryText, (New-Object System.Text.UTF8Encoding($false)))
        }
        [IO.File]::WriteAllText((Join-Path $scenarioRoot 'BRAVO.local.config'), $LocalConfigBody, (New-Object System.Text.UTF8Encoding($false)))
        $envPrefix = if (-not [string]::IsNullOrWhiteSpace($AllowWeakenedEnvValue)) {
            "`$env:BRAVO_ALLOW_WEAKENED_SECURITY = '$AllowWeakenedEnvValue'; "
        } else {
            ''
        }
        $probeCommand = (
            "try { $envPrefix" +
            ". '$root\BRAVO_CONFIG_LOADER.ps1'; " +
            "[void](Import-BravoConfiguration -ConfigRoot '$scenarioRoot' -RuntimeRoot '$root' 3>`$null); " +
            "'RESULT:Mode=' + [string]`$global:backupConsistency.Mode" +
            "} catch { 'THREW: ' + `$_.Exception.Message }"
        )
        $probeOutput = [string](
            & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
                -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probeCommand 2>&1 | Out-String
        )
        return $probeOutput.Trim()
    } finally {
        Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    $secDowngradeBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$secDowngradeBackupRootLiteral'`r`n" +
        "    'backupConsistency.Mode' = 'Direct'`r`n" +
        "}`r`n"
    )

    # --- Test 5.4a: BRAVO.config ВІДСУТНІЙ, BRAVO.local.config послаблює
    # backupConsistency.Mode -> МАЄ БЛОКУВАТИ (pre-trust guard нічого не
    # бачить, бо BRAVO.config відсутній — саме тому цей post-merge
    # gate обов'язковий).
    $secDowngradeNoConfigResult = New-BRAVOConfigLoaderSecurityDowngradeProbe -WithPrimary $false -LocalConfigBody $secDowngradeBody
    Test-BRAVOCondition `
        -Condition (
            $secDowngradeNoConfigResult.StartsWith('THREW') -and
            $secDowngradeNoConfigResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ')
        ) `
        -Name "ConfigLoader/SecurityDowngradeViaLocalConfigBlockedNoConfig" `
        -Failure "BRAVO.config відсутній + BRAVO.local.config встановлює backupConsistency.Mode='Direct' -> МАЄ БЛОКУВАТИ; отримано: $secDowngradeNoConfigResult"

    # --- Test 5.4b: те саме, але BRAVO.config ПРИСУТНІЙ (з коректним
    # VSS) — local override все одно перекриває його на ефективному рівні
    # -> МАЄ БЛОКУВАТИ так само (не лише no-config-режим).
    $secDowngradePrimaryResult = New-BRAVOConfigLoaderSecurityDowngradeProbe -WithPrimary $true -LocalConfigBody $secDowngradeBody
    Test-BRAVOCondition `
        -Condition (
            $secDowngradePrimaryResult.StartsWith('THREW') -and
            $secDowngradePrimaryResult.Contains('ПОСЛАБЛЮЄ ЗАХИСТ')
        ) `
        -Name "ConfigLoader/SecurityDowngradeViaLocalConfigBlockedWithPrimary" `
        -Failure "BRAVO.config присутній (VSS) + BRAVO.local.config встановлює backupConsistency.Mode='Direct' -> МАЄ БЛОКУВАТИ; отримано: $secDowngradePrimaryResult"

    # --- Test 5.4c: свідомий override (BRAVO_ALLOW_WEAKENED_SECURITY=1)
    # дозволяє послаблення й через BRAVO.local.config так само, як через
    # BRAVO.config — без цього оператор мав би обхідний шлях лише для
    # одного з двох джерел.
    $secDowngradeOverrideResult = New-BRAVOConfigLoaderSecurityDowngradeProbe `
        -WithPrimary $false -LocalConfigBody $secDowngradeBody -AllowWeakenedEnvValue '1'
    Test-BRAVOCondition `
        -Condition ($secDowngradeOverrideResult -eq 'RESULT:Mode=Direct') `
        -Name "ConfigLoader/SecurityDowngradeViaLocalConfigAllowedWithExplicitOverride" `
        -Failure "BRAVO_ALLOW_WEAKENED_SECURITY=1 має дозволяти послаблення через BRAVO.local.config (з видимим слідом), а не блокувати; отримано: $secDowngradeOverrideResult"

    # --- Test 5.4d (sanity): local override, що НЕ послаблює захист
    # (явний коректний 'VSS'), не повинен ставати хибним блоком.
    $secDowngradeSafeBody = (
        "@{`r`n" +
        "    'pathSettings.BackupRoot' = '$secDowngradeBackupRootLiteral'`r`n" +
        "    'backupConsistency.Mode' = 'VSS'`r`n" +
        "}`r`n"
    )
    $secDowngradeSafeResult = New-BRAVOConfigLoaderSecurityDowngradeProbe -WithPrimary $false -LocalConfigBody $secDowngradeSafeBody
    Test-BRAVOCondition `
        -Condition ($secDowngradeSafeResult -eq 'RESULT:Mode=VSS') `
        -Name "ConfigLoader/SecurityInvariantDoesNotFalsePositiveOnSafeLocalOverride" `
        -Failure "BRAVO.local.config з коректним backupConsistency.Mode='VSS' не повинен блокуватись; отримано: $secDowngradeSafeResult"
} finally {
    Remove-Item -LiteralPath $secDowngradeBackupRootDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# P0 Configuration Foundation (PR C, Секція 5.5): МЕХАНІЧНИЙ доказ, що
# pre-trust AST-правила (BRAVO_RUNTIME_GUARD.ps1, статичний текст
# BRAVO.config) і post-merge effective-правила
# (Test-BRAVOEffectiveSecurityInvariants, BRAVO_CONFIG_LOADER.ps1,
# ефективні $global:-значення) перевіряють ОДНАКОВІ очікувані значення
# для ОДНИХ і тих самих налаштувань — не два незалежні набори правил,
# що можуть розійтися мовчки. Це НЕ той самий код (різні механізми:
# AST-літерал до Import-Module vs. ефективне значення після повного
# мержу) — тому перевіряється текстова присутність тих самих
# Variable/Key/Expected-трійок в обох файлах, а не спільний виклик.
# ============================================================
$guardTextForParity = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_RUNTIME_GUARD.ps1'), [Text.Encoding]::UTF8)
$loaderTextForSecurityParity = [IO.File]::ReadAllText($configLoaderPath, [Text.Encoding]::UTF8)
Test-BRAVOCondition `
    -Condition (
        $guardTextForParity.Contains("Variable = 'toolIntegritySettings'") -and
        $guardTextForParity.Contains("Expected = 'Enforce'") -and
        $guardTextForParity.Contains("Variable = 'backupConsistency'") -and
        $guardTextForParity.Contains("Expected = 'VSS'") -and
        $loaderTextForSecurityParity.Contains('$global:toolIntegritySettings.Mode') -and
        $loaderTextForSecurityParity.Contains("'Enforce', [System.StringComparison]::OrdinalIgnoreCase") -and
        $loaderTextForSecurityParity.Contains('$global:backupConsistency.Mode') -and
        $loaderTextForSecurityParity.Contains("'VSS', [System.StringComparison]::OrdinalIgnoreCase")
    ) `
    -Name "ConfigLoader/SecurityRuleParityGuardVsEffectiveCheck" `
    -Failure "pre-trust guard (BRAVO_RUNTIME_GUARD.ps1) і post-merge effective-перевірка (BRAVO_CONFIG_LOADER.ps1) мають перевіряти ОДНАКОВІ Expected-значення (toolIntegritySettings.Mode='Enforce', backupConsistency.Mode='VSS') — розбіжність тут означає, що два набори правил розійшлися"

# ============================================================
# P0 Configuration Foundation (PR C, owner-checkpoint п.6): МЕХАНІЧНИЙ
# доказ, що committed репозиторний BRAVO.config (legacy primary, що
# сьогодні реально розгортається як shipped-конфіг) НЕ дублює жодного
# canonical product-default ІНШИМ значенням — інакше звичайний
# config-present запуск мовчки повертав би старий/environment-specific
# "default" (напр. maintenanceSettings.Limits.ExcludedDrives=@('F:\'))
# замість справжнього canonical @(), і built-in defaults НЕ були б
# єдиним джерелом істини на практиці (лише в ще не підключеному
# no-config-шляху). Порівнює raw-знімок ПОВНОГО виконання committed
# BRAVO.config (той самий allowlist-механізм, що
# Import-BravoLegacyPrimaryConfiguration) проти Get-BRAVODefaultConfiguration
# по КОЖНОМУ allowlisted top-level ключу рекурсивно. Навмисні винятки —
# лише ті, що явно задокументовані в самому Get-BRAVODefaultConfiguration
# docstring (наразі: ExcludedDrives, lunchArchiveCleanupPath,
# smbSettings.RootPath — синхронізовані з дефолтом 2026-09, коментар
# лишається як історія рішення).
# ============================================================
function Compare-BRAVOConfigurationGraphForParity {
    # Приймає накопичувач ЯВНО (той самий List[string]-об'єкт по всій
    # рекурсії) замість повернення масиву через `return` — рекурсивний
    # `return ,@(...)` на кожному рівні вкладеності виявився ненадійним
    # (порожні "diff"-рядки в self-test-виводі: PowerShell-семантика
    # розгортання масиву на межі pipeline при захопленні результату
    # РЕКУРСИВНОГО виклику через `@(...)` неоднозначна для вкладених
    # comma-обгорнутих масивів). Явний спільний List уникає цього класу
    # проблем повністю.
    param($Actual, $Expected, [string]$Path, [System.Collections.Generic.List[string]]$Diffs)
    if ($Actual -is [hashtable] -and $Expected -is [hashtable]) {
        $allKeys = @(@($Actual.Keys) + @($Expected.Keys) | Select-Object -Unique)
        foreach ($key in $allKeys) {
            if (-not $Actual.Contains($key)) { [void]$Diffs.Add("$Path.$key : відсутнє в BRAVO.config"); continue }
            if (-not $Expected.Contains($key)) { [void]$Diffs.Add("$Path.$key : відсутнє в canonical default"); continue }
            Compare-BRAVOConfigurationGraphForParity -Actual $Actual[$key] -Expected $Expected[$key] -Path "$Path.$key" -Diffs $Diffs
        }
        return
    }
    $actualText = if ($Actual -is [array]) { ($Actual -join ',') } else { [string]$Actual }
    $expectedText = if ($Expected -is [array]) { ($Expected -join ',') } else { [string]$Expected }
    if ($actualText -ne $expectedText) {
        [void]$Diffs.Add("$Path : BRAVO.config='$actualText' canonical default='$expectedText'")
    }
}

$parityDefaultConfiguration = Get-BRAVODefaultConfiguration
$committedConfigProbeCommand = (
    "Import-Module -Name '$root\modules\BRAVO.Configuration\BRAVO.Configuration.psd1' -ErrorAction Stop; " +
    "`$default = Get-BRAVODefaultConfiguration; " +
    "`$sb = [scriptblock]::Create([IO.File]::ReadAllText('$($root.Replace("'", "''"))\BRAVO.config', [Text.Encoding]::UTF8)); " +
    "& `$sb -ConfigRoot '$($root.Replace("'", "''"))' -RuntimeRoot '$($root.Replace("'", "''"))'; " +
    "`$primaryRaw = @{}; " +
    "foreach (`$k in @(`$default.Keys)) { `$v = Get-Variable -Name `$k -Scope Global -ErrorAction SilentlyContinue; if (`$null -ne `$v -and `$null -ne `$v.Value) { `$primaryRaw[`$k] = `$v.Value } }; " +
    "ConvertTo-Json -InputObject `$primaryRaw -Depth 20 -Compress"
)
$committedConfigProbeOutput = [string](
    & (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $committedConfigProbeCommand 2>&1 | Out-String
)

function ConvertFrom-BRAVOParityPSCustomObject {
    param($InputObject)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $h[$prop.Name] = ConvertFrom-BRAVOParityPSCustomObject -InputObject $prop.Value
        }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return ,@($InputObject | ForEach-Object { ConvertFrom-BRAVOParityPSCustomObject -InputObject $_ })
    }
    return $InputObject
}

$parityDiffs = $null
$parityParseFailed = $false
try {
    $committedRawParsed = $committedConfigProbeOutput.Trim() | ConvertFrom-Json
    $committedRawHashtable = ConvertFrom-BRAVOParityPSCustomObject -InputObject $committedRawParsed
    $parityDiffsList = New-Object System.Collections.Generic.List[string]
    foreach ($topKey in ($committedRawHashtable.Keys | Sort-Object)) {
        if (-not $parityDefaultConfiguration.Contains($topKey)) { continue }
        Compare-BRAVOConfigurationGraphForParity `
            -Actual $committedRawHashtable[$topKey] -Expected $parityDefaultConfiguration[$topKey] `
            -Path $topKey -Diffs $parityDiffsList
    }
    $parityDiffs = @($parityDiffsList.ToArray())
} catch {
    $parityParseFailed = $true
}

Test-BRAVOCondition `
    -Condition (-not $parityParseFailed -and @($parityDiffs).Count -eq 0) `
    -Name "ConfigLoader/CommittedBravoConfigMatchesCanonicalDefaults" `
    -Failure "committed BRAVO.config НЕ повинен мовчки дублювати canonical product-default ІНШИМ значенням (built-in defaults мають бути єдиним джерелом істини навіть у config-present режимі); parseFailed=$parityParseFailed diffs: $(if ($null -ne $parityDiffs) { $parityDiffs -join ' | ' } else { '(none captured)' })"

# P0 Configuration Foundation (PR C, Секція 9): BRAVO.local.config —
# site-specific override-шар (LIMSRoot/BackupRoot/розклад/креденшел-таргети
# для конкретного сервера) — не повинен потрапити в git при ручному запуску
# з робочої копії репозиторію (той самий клас ризику, що WinSCP.ini). Текстова
# перевірка .gitignore (не `git check-ignore`): self-test виконується і на
# розгорнутих у клієнта комплектах без .git — git-залежна перевірка там
# просто мовчки не спрацювала б.
$gitignorePath = Join-Path $root '.gitignore'
$gitignoreLines = if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
    @(Get-Content -LiteralPath $gitignorePath -Encoding UTF8 | ForEach-Object { $_.Trim() })
} else {
    @()
}
Test-BRAVOCondition `
    -Condition ($gitignoreLines -contains 'BRAVO.local.config') `
    -Name 'ConfigLoader/LocalConfigIsGitignored' `
    -Failure 'BRAVO.local.config (site-specific override-шар) мусить бути в .gitignore окремим рядком — інакше ручний git-запуск із робочої копії міг би закомітити site-дані'
