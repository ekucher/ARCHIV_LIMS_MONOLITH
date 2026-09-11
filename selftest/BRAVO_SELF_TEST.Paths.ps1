# Домен-фрагмент self-test: Paths (LIMSRoot/BackupRoot/SystemLogRoot
# resolution, BRAVO.Discovery). Dot-sourced з кореневого BRAVO_SELF_TEST.ps1
# -- НЕ запускається напряму. Успадковує з викликача: $root,
# Test-BRAVOCondition, New-BRAVOSelfTestRuntimeModule, $script:failures.
#
# ПРИХОВАНІ ЗАЛЕЖНОСТІ (виявлені при розбитті, 2026-08-18): 2 external
# source-text змінні, вперше прочитані набагато раніше в монолітному файлі.
# Локальні перечитування нижче (той самий вміст файлу, immutable протягом
# self-test-прогону).
$archiveScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1"),
    [Text.Encoding]::UTF8
)
$maintenanceScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)

    # ===== АРХІТЕКТУРА ШЛЯХІВ: RuntimeRoot/LIMSRoot/SystemLogRoot/BackupRoot
    # (ТЗ «Рефакторинг архітектури шляхів BRAVO») =====
    Remove-Module -Name 'BRAVO.Discovery' -Force -ErrorAction SilentlyContinue
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Discovery\BRAVO.Discovery.psd1") -Force -ErrorAction Stop
    # P0 Configuration Foundation (PR B): derivation-виклики
    # (Resolve-BRAVOEffective*, runtimeLogRoot/stateRoot/archiveDirs
    # тощо) тепер живуть у canonical derivation resolver, не в самому
    # BRAVO.config — перевірки нижче читають об'єднаний текст обох
    # файлів (docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md).
    $bravoConfigTextForPaths = (
        [IO.File]::ReadAllText((Join-Path $root "BRAVO.config"), [Text.Encoding]::UTF8) +
        [Environment]::NewLine +
        [IO.File]::ReadAllText(
            (Join-Path $root 'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psm1'),
            [Text.Encoding]::UTF8
        )
    )

    $svcCanonical = @([pscustomobject]@{ Name='BRAVO'; DisplayName='BRAVO Service'; State='Stopped'; StartMode='Disabled'; PathName='"C:\LIMS\bravo.exe" -service' })
    $svcAmbiguous = @(
        [pscustomobject]@{ Name='BRAVO'; DisplayName='BRAVO Service'; State='Running'; StartMode='Auto'; PathName='"D:\LIMS\bravo.exe"' },
        [pscustomobject]@{ Name='BRAVO'; DisplayName='BRAVO Service'; State='Stopped'; StartMode='Manual'; PathName='"E:\LIMS\bravo.exe"' })

    # --- Paths/01: AUTO LIMSRoot зі служби (Disabled допустимо) ---
    $autoLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services $svcCanonical
    Test-BRAVOCondition `
        -Condition ([string]$autoLims.Source -eq 'ServiceDiscovery' -and [string]$autoLims.EffectivePath -eq 'C:\LIMS') `
        -Name "Paths/01-AutoLimsRootFromService" `
        -Failure "LIMSRoot='' має визначатись як каталог bravo.exe встановленої служби (Disabled — теж валідна identity)"

    # --- Paths/01b: AUTO LIMSRoot зі служби з DisplayName="BRAVO Server" ---
    # (реальний DEV-майданчик, 2026-08-24: деякі інсталятори BRAVO/LIMS
    # використовують саме це написання замість "BRAVO Service" — обидва
    # мають визнаватись канонічними за замовчуванням, без override).
    $svcBravoServer = @([pscustomobject]@{ Name='BRAVO'; DisplayName='BRAVO Server'; State='Running'; StartMode='Auto'; PathName='"C:\LIMS\bravo.exe"' })
    $autoLimsBravoServer = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services $svcBravoServer
    Test-BRAVOCondition `
        -Condition ([string]$autoLimsBravoServer.Source -eq 'ServiceDiscovery' -and [string]$autoLimsBravoServer.EffectivePath -eq 'C:\LIMS') `
        -Name "Paths/01b-AutoLimsRootFromServiceBravoServerDisplayName" `
        -Failure "служба BRAVO з DisplayName='BRAVO Server' (реальний DEV-варіант написання) має визнаватись канонічною за замовчуванням так само, як 'BRAVO Service'"

    # --- Paths/02: explicit LIMSRoot має пріоритет над службою ---
    $explicitLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath 'E:\CUSTOM_BRAVO' -Services $svcAmbiguous
    Test-BRAVOCondition `
        -Condition ([string]$explicitLims.Source -eq 'ExplicitConfig' -and [string]$explicitLims.EffectivePath -eq 'E:\CUSTOM_BRAVO') `
        -Name "Paths/02-ExplicitLimsRootWins" `
        -Failure "явний LIMSRoot має використовуватись точно й не перевизначатись service discovery"

    # --- Paths/03: відсутня служба -> fail-closed ---
    $noServiceLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services @()
    Test-BRAVOCondition `
        -Condition ([string]$noServiceLims.Source -eq 'Error' -and [string]::IsNullOrWhiteSpace([string]$noServiceLims.EffectivePath)) `
        -Name "Paths/03-NoServiceFailsClosed" `
        -Failure "LIMSRoot='' без служби BRAVO має давати керовану помилку, а не fallback на RuntimeRoot/ConfigRoot"

    # --- Paths/04: неоднозначна служба -> fail-closed ---
    $ambiguousLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services $svcAmbiguous
    Test-BRAVOCondition `
        -Condition ([string]$ambiguousLims.Source -eq 'Error' -and [string]::IsNullOrWhiteSpace([string]$ambiguousLims.EffectivePath)) `
        -Name "Paths/04-AmbiguousServiceFailsClosed" `
        -Failure "кілька служб BRAVO з різними виконуваними файлами при LIMSRoot='' мають давати помилку (fail-closed), а не first-match"

    # --- Paths/05: AUTO SystemLogRoot = <LIMSRoot>\ARCHIV\LOGS ---
    $autoSysLog = Resolve-BRAVOEffectiveSystemLogRoot -ConfiguredPath '' -EffectiveLimsRoot 'C:\LIMS'
    Test-BRAVOCondition `
        -Condition ([string]$autoSysLog.Source -eq 'AutoFromLIMSRoot' -and [string]$autoSysLog.EffectivePath -eq 'C:\LIMS\ARCHIV\LOGS') `
        -Name "Paths/05-AutoSystemLogRootFromLims" `
        -Failure "SystemLogRoot='' має давати <EffectiveLIMSRoot>\ARCHIV\LOGS"

    # --- Paths/06: explicit SystemLogRoot використовується точно ---
    $explicitSysLog = Resolve-BRAVOEffectiveSystemLogRoot -ConfiguredPath 'E:\BRAVO_SYSTEM_LOGS' -EffectiveLimsRoot 'C:\LIMS'
    Test-BRAVOCondition `
        -Condition ([string]$explicitSysLog.Source -eq 'ExplicitConfig' -and [string]$explicitSysLog.EffectivePath -eq 'E:\BRAVO_SYSTEM_LOGS') `
        -Name "Paths/06-ExplicitSystemLogRootExact" `
        -Failure "явний SystemLogRoot має використовуватись точно, без дописування ARCHIV\LOGS"

    # --- Paths/07: BRAVO.config — новий контракт pathSettings ---
    Test-BRAVOCondition `
        -Condition (
            [regex]::IsMatch($bravoConfigTextForPaths, '(?m)^\s*LIMSRoot\s*=') -and
            [regex]::IsMatch($bravoConfigTextForPaths, '(?m)^\s*SystemLogRoot\s*=') -and
            [regex]::IsMatch($bravoConfigTextForPaths, '(?m)^\s*BackupRoot\s*=') -and
            -not [regex]::IsMatch($bravoConfigTextForPaths, '(?m)^\s*ArchiveRoot\s*=') -and
            $bravoConfigTextForPaths.Contains('Resolve-BRAVOEffectiveLimsRoot') -and
            $bravoConfigTextForPaths.Contains('Resolve-BRAVOEffectiveSystemLogRoot') -and
            $bravoConfigTextForPaths.Contains('Resolve-BRAVOEffectiveBackupRoot')
        ) `
        -Name "Paths/07-ConfigContractHasNoArchiveRoot" `
        -Failure "pathSettings має містити LIMSRoot/SystemLogRoot/BackupRoot і викликати Resolve-BRAVOEffective* (Lims/SystemLog/Backup); ArchiveRoot має бути прибраний"

    # --- Paths/08: script logs = RuntimeRoot\LOGS; state = ProgramData\State ---
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigTextForPaths.Contains('$global:runtimeLogRoot = Join-Path $runtimeRoot "LOGS"') -and
            $bravoConfigTextForPaths.Contains('$global:logPath = $global:runtimeLogRoot') -and
            $bravoConfigTextForPaths.Contains("`$global:stateRoot = Join-Path `$programDataRoot 'BRAVO\State'") -and
            $bravoConfigTextForPaths.Contains('$global:systemLogRoot = [string]$systemLogRootResult.EffectivePath')
        ) `
        -Name "Paths/08-ScriptLogsRuntimeStateProgramData" `
        -Failure "логи скриптів мають бути RuntimeRoot\LOGS (logPath=runtimeLogRoot), стан — ProgramData\BRAVO\State, systemLogRoot — окремий"

    # --- Paths/09: Maintenance — Trace/exchangAPI/BravoWeb під SystemLogRoot,
    # власні логи під RuntimeLogRoot, стан під ProgramData\State ---
    Test-BRAVOCondition `
        -Condition (
            $maintenanceScriptText.Contains('$SYSTEM_LOG_ROOT = [string]$systemLogRoot') -and
            $maintenanceScriptText.Contains('$TRACE_DIR = Join-Path $SYSTEM_LOG_ROOT "Trace"') -and
            $maintenanceScriptText.Contains('$LOG_DIR = [string]$runtimeLogRoot') -and
            $maintenanceScriptText.Contains("Join-Path `$stateRoot 'BRAVO_RESTORE_STATE.json'") -and
            $maintenanceScriptText.Contains("Join-Path `$stateRoot 'BRAVO_TASK_EXECUTION_STATE.json'") -and
            $maintenanceScriptText -notmatch '\$ARCHIVE_ROOT'
        ) `
        -Name "Paths/09-MaintenanceSplitsRuntimeSystemState" `
        -Failure "Maintenance: Trace/exchangAPI/BravoWeb під SystemLogRoot, власні логи під RuntimeLogRoot, стан під ProgramData\State; ARCHIVE_ROOT прибрано"

    # --- Paths/10: Archive backup execution state -> ProgramData\State ---
    Test-BRAVOCondition `
        -Condition (
            $archiveScriptText.Contains("Join-Path `$stateRoot 'BRAVO_TASK_EXECUTION_STATE.json'") -and
            -not $archiveScriptText.Contains("Join-Path `$logPath 'BRAVO_TASK_EXECUTION_STATE.json'")
        ) `
        -Name "Paths/10-ArchiveStateInProgramData" `
        -Failure "Archive backup execution state має писатись у ProgramData\BRAVO\State, а не в каталог логів"

    # --- Paths/11: BackupRoot — BAZA_APP/BAZA_WWW роздільно ---
    Test-BRAVOCondition `
        -Condition (
            $bravoConfigTextForPaths.Contains('[System.IO.Path]::Combine($backupRootPath, "BAZA_APP")') -and
            $bravoConfigTextForPaths.Contains('[System.IO.Path]::Combine($backupRootPath, "BAZA_WWW")') -and
            $bravoConfigTextForPaths.Contains('[System.IO.Path]::Combine($backupRootPath, "MODEL")')
        ) `
        -Name "Paths/11-BackupRootBazaAppWwwDistinct" `
        -Failure "локальні призначення backup: BackupRoot\{MODEL,BLOG,BRAVOEXCH,BAZA_APP,BAZA_WWW}; BAZA_APP не має зватись просто BAZA"

    # --- Paths/12: AUTO BackupRoot = <EffectiveLIMSRoot>\ARCHIV ---
    $autoBackup = Resolve-BRAVOEffectiveBackupRoot -ConfiguredPath '' -EffectiveLimsRoot 'C:\LIMS'
    Test-BRAVOCondition `
        -Condition ([string]$autoBackup.Source -eq 'AutoFromLIMSRoot' -and [string]$autoBackup.EffectivePath -eq 'C:\LIMS\ARCHIV') `
        -Name "Paths/12-AutoBackupRootFromLims" `
        -Failure "BackupRoot='' має давати <EffectiveLIMSRoot>\ARCHIV із Source=AutoFromLIMSRoot"

    # --- Paths/13: explicit BackupRoot використовується точно ---
    $explicitBackup = Resolve-BRAVOEffectiveBackupRoot -ConfiguredPath 'E:\BACKUPS' -EffectiveLimsRoot 'C:\LIMS'
    Test-BRAVOCondition `
        -Condition ([string]$explicitBackup.Source -eq 'ExplicitConfig' -and [string]$explicitBackup.EffectivePath -eq 'E:\BACKUPS') `
        -Name "Paths/13-ExplicitBackupRootExact" `
        -Failure "явний BackupRoot має використовуватись точно, без дописування ARCHIV"

    # --- Paths/14: all-AUTO ланцюжок від синтетичної служби BRAVO ---
    # LIMSRoot=""/SystemLogRoot=""/BackupRoot="" + служба з bravo.exe у
    # C:\LIMS мають дати повний детермінований розклад коренів.
    $chainLims = Resolve-BRAVOEffectiveLimsRoot -ConfiguredPath '' -Services $svcCanonical
    $chainSysLog = Resolve-BRAVOEffectiveSystemLogRoot -ConfiguredPath '' -EffectiveLimsRoot ([string]$chainLims.EffectivePath)
    $chainBackup = Resolve-BRAVOEffectiveBackupRoot -ConfiguredPath '' -EffectiveLimsRoot ([string]$chainLims.EffectivePath)
    Test-BRAVOCondition `
        -Condition (
            [string]$chainLims.EffectivePath -eq 'C:\LIMS' -and
            [string]$chainSysLog.EffectivePath -eq 'C:\LIMS\ARCHIV\LOGS' -and
            [string]$chainBackup.EffectivePath -eq 'C:\LIMS\ARCHIV' -and
            [string]$chainLims.Source -eq 'ServiceDiscovery' -and
            [string]$chainSysLog.Source -eq 'AutoFromLIMSRoot' -and
            [string]$chainBackup.Source -eq 'AutoFromLIMSRoot'
        ) `
        -Name "Paths/14-AllAutoLayoutFromService" `
        -Failure "all-AUTO (усі три '') зі службою bravo.exe у C:\LIMS має дати LIMS=C:\LIMS, SystemLog=...\ARCHIV\LOGS, Backup=...\ARCHIV"

    # --- Paths/15: композиція шляху на відсутньому диску не кидає виняток ---
    # Резолвери мають будувати шлях через [IO.Path]::Combine, тому навіть корінь
    # на відсутньому диску (Q:) не має давати DriveNotFoundException під час
    # завантаження — недоступність виявляє write-probe у dry-run, а не резолвер.
    $qDrivePresent = [bool](Get-PSDrive -Name 'Q' -ErrorAction SilentlyContinue)
    $backupCompositionSafe = $false
    if (-not $qDrivePresent) {
        try {
            $qBackup = Resolve-BRAVOEffectiveBackupRoot -ConfiguredPath '' -EffectiveLimsRoot 'Q:\LIMS-NEW'
            $qModel = [System.IO.Path]::Combine([string]$qBackup.EffectivePath, 'MODEL')
            $backupCompositionSafe = ([string]$qBackup.EffectivePath -eq 'Q:\LIMS-NEW\ARCHIV' -and $qModel -eq 'Q:\LIMS-NEW\ARCHIV\MODEL')
        } catch { $backupCompositionSafe = $false }
    } else {
        # Диск Q: реально існує на цьому хості — сценарій "відсутній диск"
        # непридатний; тест не має сенсу тут провалювати.
        $backupCompositionSafe = $true
    }
    Test-BRAVOCondition `
        -Condition $backupCompositionSafe `
        -Name "Paths/15-BackupCompositionOnAbsentDriveDoesNotThrow" `
        -Failure "побудова BackupRoot і призначень на відсутньому диску (Q:) не має кидати DriveNotFoundException — лише [IO.Path]::Combine, без Join-Path"
