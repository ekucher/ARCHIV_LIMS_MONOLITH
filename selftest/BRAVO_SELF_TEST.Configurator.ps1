# Домен-фрагмент self-test: BRAVO.Configurator backend
# (Schema/Model/Effective/Validation/Persistence) — GUI (Agent 4-7 з
# docs/design/BRAVO_CONFIGURATOR_DESIGN.md) поки не реалізовано, тут
# перевіряється лише backend-контракт.
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition, $script:failures.
#
# Ізоляція: жодна перевірка не читає й не пише реальний
# $root\BRAVO.local.config — лише тимчасові каталоги в %TEMP%, видалені у
# finally.
#
# Герметичність RuntimeRoot (CI-регресія, той самий клас, що
# selftest\BRAVO_SELF_TEST.ConfigLoader.ps1 вже документує для
# BackupRoot=""): Configurator.Effective копіює $RuntimeRoot\BRAVO.config
# У isolated ConfigRoot ВЕРБАТИМ, без жодного патчингу. Канонічний
# комплектний default LIMSRoot=""/BackupRoot="" (AUTO) на реальному
# production-сервері резолвиться через встановлену службу BRAVO; на
# GitHub runner (і будь-якій dev-машині без LIMS) AUTO-виявлення падає з
# "Не вдалося визначити BackupRoot" — жоден Configurator-виклик з
# порожнім/без-override candidate (у т.ч. ВСЕРЕДИНІ production
# Test-BRAVOConfiguratorCandidateOverrides, яка завжди рахує ВЛАСНИЙ
# DefaultConfig з -CandidateOverrides @{}) не може обійти цю залежність
# лише через overrides, передані САМИМ self-test-ом. Тому весь фрагмент
# передає RuntimeRoot = ІЗОЛЬОВАНА копія реального комплекту з ЄДИНОЮ
# зміною — явний LIMSRoot/BackupRoot замість AUTO (той самий text-replace
# прийом, що ConfigLoader.ps1), а не реальний $root.

$configuratorModuleRoot = Join-Path $root 'modules\BRAVO.Configurator'
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Schema.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Effective.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Model.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Validation.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Persistence.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Credentials.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Presets.psm1') -Force
Import-Module (Join-Path $configuratorModuleRoot 'BRAVO.Configurator.Preview.psm1') -Force

$configuratorFixtureRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_SELFTEST_RUNTIME_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorFixtureRuntimeRoot)
$configuratorFixtureLimsRoot = Join-Path $configuratorFixtureRuntimeRoot 'FIXTURE_LIMS'
$configuratorFixtureBackupRoot = Join-Path $configuratorFixtureRuntimeRoot 'FIXTURE_BACKUP'
[void][IO.Directory]::CreateDirectory($configuratorFixtureLimsRoot)
[void][IO.Directory]::CreateDirectory($configuratorFixtureBackupRoot)
Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination (Join-Path $configuratorFixtureRuntimeRoot 'BRAVO_CONFIG_LOADER.ps1') -Force
Copy-Item -LiteralPath (Join-Path $root 'VERSION.json') -Destination (Join-Path $configuratorFixtureRuntimeRoot 'VERSION.json') -Force
# Junction, не copy: modules\ — великий, реальні збірки викликів
# (Discovery/Compatibility) мають лишатися canonical-кодом репозиторію,
# не копією, що могла б непомітно розійтись.
$null = cmd.exe /c mklink /J "$configuratorFixtureRuntimeRoot\modules" "$root\modules" 2>&1
$configuratorKitConfigText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO.config'))
$configuratorLimsRootLiteralLine = '    LIMSRoot      = ""'
$configuratorBackupRootLiteralLine = '    BackupRoot    = ""'
if (-not $configuratorKitConfigText.Contains($configuratorLimsRootLiteralLine) -or
    -not $configuratorKitConfigText.Contains($configuratorBackupRootLiteralLine)) {
    throw "BRAVO_SELF_TEST.Configurator: у BRAVO.config не знайдено очікувані рядки LIMSRoot/BackupRoot — оновіть fixture під нову форму конфігурації"
}
$configuratorPatchedConfigText = $configuratorKitConfigText.
    Replace($configuratorLimsRootLiteralLine, "    LIMSRoot      = '$($configuratorFixtureLimsRoot.Replace("'", "''"))'").
    Replace($configuratorBackupRootLiteralLine, "    BackupRoot    = '$($configuratorFixtureBackupRoot.Replace("'", "''"))'")
[IO.File]::WriteAllText((Join-Path $configuratorFixtureRuntimeRoot 'BRAVO.config'), $configuratorPatchedConfigText, (New-Object System.Text.UTF8Encoding($false)))

# ===== Schema completeness (§3.4 задачі Configurator-а) =====
$configuratorSchemaResult = Test-BRAVOConfiguratorSchemaCompleteness -ExamplePath (Join-Path $root 'BRAVO.local.config.example')
Test-BRAVOCondition ($configuratorSchemaResult.IsComplete) `
    'Configurator: schema 1:1 з BRAVO.local.config.example' `
    ("ConfigurableTotal=$($configuratorSchemaResult.ConfigurableTotal) SchemaDescriptors=$($configuratorSchemaResult.SchemaDescriptors) " +
     "Missing=$($configuratorSchemaResult.MissingPaths -join ',') Orphan=$($configuratorSchemaResult.OrphanPaths -join ',') " +
     "Duplicate=$($configuratorSchemaResult.DuplicatePaths -join ',')")
Test-BRAVOCondition ($configuratorSchemaResult.ConfigurableTotal -gt 100) `
    'Configurator: schema каталог не порожній/тривіальний' `
    "ConfigurableTotal=$($configuratorSchemaResult.ConfigurableTotal) (очікувалось > 100)"

# R3-5 (PR #136, третє коло review): 5 нових log-lifecycle ключів мусять
# мати дескриптор правильного типу — без цього фіча лишається керованою
# лише прямим редагуванням BRAVO.config, недоступною з Configurator UI.
$configuratorLogLifecycleDescriptors = @(Get-BRAVOConfiguratorSchemaCatalog)
$configuratorExpectedLogLifecyclePaths = @{
    'maintenanceSettings.Retention.RawSourceGraceDays'  = 'Integer'
    'componentSettings.SFTP.MaintenanceLogUploadEnabled' = 'Boolean'
    'componentSettings.SFTP.ArchiveLogUploadEnabled'     = 'Boolean'
    'sftpDirectories.MaintenanceLog'                     = 'String'
    'sftpDirectories.ArchivLog'                          = 'String'
}
$configuratorLogLifecycleMismatches = New-Object System.Collections.Generic.List[string]
foreach ($expectedPath in $configuratorExpectedLogLifecyclePaths.Keys) {
    $matchingDescriptor = @($configuratorLogLifecycleDescriptors | Where-Object { $_.Path -eq $expectedPath })
    if ($matchingDescriptor.Count -ne 1) {
        $configuratorLogLifecycleMismatches.Add("$expectedPath : відсутній дескриптор (знайдено $($matchingDescriptor.Count))")
    } elseif ([string]$matchingDescriptor[0].Type -ne $configuratorExpectedLogLifecyclePaths[$expectedPath]) {
        $configuratorLogLifecycleMismatches.Add("$expectedPath : Type='$($matchingDescriptor[0].Type)', очікувалось '$($configuratorExpectedLogLifecyclePaths[$expectedPath])'")
    }
}
Test-BRAVOCondition ($configuratorLogLifecycleMismatches.Count -eq 0) `
    'Configurator/LogLifecycleSettingsHaveDescriptors' `
    "5 нових log-lifecycle ключів мають мати дескриптор коректного типу; розбіжності: $($configuratorLogLifecycleMismatches -join ' | ')"

# ===== Model: Default/Override/Effective/Dirty (§22.4-6 задачі) =====
$configuratorSchemaCatalog = Get-BRAVOConfiguratorSchemaCatalog
$configuratorDefaultConfig = Invoke-BRAVOConfiguratorEffectiveComputation -RuntimeRoot $configuratorFixtureRuntimeRoot -CandidateOverrides @{}

# 4: no override -> Effective=Default
$modelNoOverride = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}
$modelNoOverride = Update-BRAVOConfiguratorEffective -Model $modelNoOverride -RuntimeRoot $configuratorFixtureRuntimeRoot
$backupRootSettingNoOverride = @($modelNoOverride | Where-Object { $_.Path -eq 'pathSettings.BackupRoot' })
Test-BRAVOCondition ($backupRootSettingNoOverride.Count -eq 1 -and $backupRootSettingNoOverride[0].EffectiveValue -eq $backupRootSettingNoOverride[0].DefaultValue) `
    'Configurator Model: без override Effective=Default' `
    "Effective=$($backupRootSettingNoOverride[0].EffectiveValue) Default=$($backupRootSettingNoOverride[0].DefaultValue)"

# 5: explicit override -> Effective=Override
$modelWithOverride = Set-BRAVOConfiguratorOverride -Model $modelNoOverride -Path 'pathSettings.BackupRoot' -Value 'E:\SELFTEST_BACKUP_ROOT'
$modelWithOverride = Update-BRAVOConfiguratorEffective -Model $modelWithOverride -RuntimeRoot $configuratorFixtureRuntimeRoot
$backupRootSettingOverride = @($modelWithOverride | Where-Object { $_.Path -eq 'pathSettings.BackupRoot' })
Test-BRAVOCondition ($backupRootSettingOverride.Count -eq 1 -and $backupRootSettingOverride[0].EffectiveValue -eq 'E:\SELFTEST_BACKUP_ROOT' -and $backupRootSettingOverride[0].EffectiveSource -eq 'Override') `
    'Configurator Model: explicit override -> Effective=Override' `
    "Effective=$($backupRootSettingOverride[0].EffectiveValue) Source=$($backupRootSettingOverride[0].EffectiveSource)"

# 6: Default action removes override
$modelCleared = Clear-BRAVOConfiguratorOverride -Model $modelWithOverride -Path 'pathSettings.BackupRoot'
$backupRootSettingCleared = @($modelCleared | Where-Object { $_.Path -eq 'pathSettings.BackupRoot' })
Test-BRAVOCondition ($backupRootSettingCleared.Count -eq 1 -and -not $backupRootSettingCleared[0].OverridePresent) `
    'Configurator Model: "Використовувати default" видаляє override' `
    "OverridePresent=$($backupRootSettingCleared[0].OverridePresent)"

# ===== SFTP/SMB 5.2.2 master-switch semantics (P0.13 Scenario A-J; реальний
# canonical loader через Get-BRAVOEffectiveStorageConfiguration/
# Get-BRAVOEffectiveSynchronizationConfiguration, не reimplemented) =====

# Scenario A: SFTP.Enabled=true, ArchiveUpload raw=true -> Effective=true
$modelScenarioA = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $true
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioA = Update-BRAVOConfiguratorEffective -Model $modelScenarioA -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioA = @($modelScenarioA | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($settingScenarioA.Count -eq 1 -and [bool]$settingScenarioA[0].EffectiveValue -eq $true) `
    'Configurator 5.2.2 Scenario A: SFTP.Enabled=true + ArchiveUpload raw=true -> Effective=true' `
    "Effective=$($settingScenarioA[0].EffectiveValue)"

# Scenario B: SFTP.Enabled=false, ArchiveUpload raw=true -> Effective=false;
# Raw лишається true; DisabledReason присутній і посилається саме на
# componentSettings.SFTP.Enabled (canonical текст, не Configurator-вигадка).
$modelScenarioB = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioB = Update-BRAVOConfiguratorEffective -Model $modelScenarioB -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioB = @($modelScenarioB | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition (
    $settingScenarioB.Count -eq 1 -and
    [bool]$settingScenarioB[0].OverrideValue -eq $true -and
    [bool]$settingScenarioB[0].EffectiveValue -eq $false -and
    -not [string]::IsNullOrWhiteSpace([string]$settingScenarioB[0].DisabledReason) -and
    [string]$settingScenarioB[0].DisabledReason -match 'componentSettings\.SFTP\.Enabled'
) `
    'Configurator 5.2.2 Scenario B: SFTP.Enabled=false -> ArchiveUpload Effective=false, Raw=true, DisabledReason коректний' `
    "Raw=$($settingScenarioB[0].OverrideValue) Effective=$($settingScenarioB[0].EffectiveValue) DisabledReason=$($settingScenarioB[0].DisabledReason)"

# Scenario C: SFTP.Enabled=false, BAZA_APP_SFTP raw=true -> Effective=false
$modelScenarioC = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.Synchronization.BAZA_APP_SFTP' = $true
}
$modelScenarioC = Update-BRAVOConfiguratorEffective -Model $modelScenarioC -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioC = @($modelScenarioC | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_SFTP' })
Test-BRAVOCondition ($settingScenarioC.Count -eq 1 -and [bool]$settingScenarioC[0].OverrideValue -eq $true -and [bool]$settingScenarioC[0].EffectiveValue -eq $false) `
    'Configurator 5.2.2 Scenario C: SFTP.Enabled=false -> BAZA_APP_SFTP Effective=false (Raw=true збережено)' `
    "Raw=$($settingScenarioC[0].OverrideValue) Effective=$($settingScenarioC[0].EffectiveValue)"

# Scenario D: SFTP.Enabled=false, BAZA_WWW_SFTP raw=true -> Effective=false
$modelScenarioD = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.Synchronization.BAZA_WWW_SFTP' = $true
}
$modelScenarioD = Update-BRAVOConfiguratorEffective -Model $modelScenarioD -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioD = @($modelScenarioD | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
Test-BRAVOCondition ($settingScenarioD.Count -eq 1 -and [bool]$settingScenarioD[0].OverrideValue -eq $true -and [bool]$settingScenarioD[0].EffectiveValue -eq $false) `
    'Configurator 5.2.2 Scenario D: SFTP.Enabled=false -> BAZA_WWW_SFTP Effective=false (Raw=true збережено)' `
    "Raw=$($settingScenarioD[0].OverrideValue) Effective=$($settingScenarioD[0].EffectiveValue)"

# Scenario E: master re-enabled -> raw child value restored as effective
# БЕЗ повторного налаштування дочірнього прапорця (сам override
# ArchiveUpload=true лишається незмінним і всю сесію — лише master
# перемикається false->true).
$modelScenarioE = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $true
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioE = Update-BRAVOConfiguratorEffective -Model $modelScenarioE -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioE = @($modelScenarioE | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($settingScenarioE.Count -eq 1 -and [bool]$settingScenarioE[0].OverrideValue -eq $true -and [bool]$settingScenarioE[0].EffectiveValue -eq $true -and [string]::IsNullOrWhiteSpace([string]$settingScenarioE[0].DisabledReason)) `
    'Configurator 5.2.2 Scenario E: master повторно увімкнено -> Effective відновлено з Raw, без DisabledReason' `
    "Raw=$($settingScenarioE[0].OverrideValue) Effective=$($settingScenarioE[0].EffectiveValue) DisabledReason=$($settingScenarioE[0].DisabledReason)"

# Scenario F: SMB.Enabled=false, ArchiveCopy raw=true -> Effective=false
$modelScenarioF = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SMB.Enabled' = $false
    'componentSettings.SMB.ArchiveCopy' = $true
}
$modelScenarioF = Update-BRAVOConfiguratorEffective -Model $modelScenarioF -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioF = @($modelScenarioF | Where-Object { $_.Path -eq 'componentSettings.SMB.ArchiveCopy' })
Test-BRAVOCondition (
    $settingScenarioF.Count -eq 1 -and [bool]$settingScenarioF[0].OverrideValue -eq $true -and [bool]$settingScenarioF[0].EffectiveValue -eq $false -and
    [string]$settingScenarioF[0].DisabledReason -match 'componentSettings\.SMB\.Enabled'
) `
    'Configurator 5.2.2 Scenario F: SMB.Enabled=false -> ArchiveCopy Effective=false, DisabledReason коректний' `
    "Raw=$($settingScenarioF[0].OverrideValue) Effective=$($settingScenarioF[0].EffectiveValue) DisabledReason=$($settingScenarioF[0].DisabledReason)"

# Scenario G: SFTP disabled НЕ вимикає SMB (незалежні master-и)
$modelScenarioG = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.SMB.ArchiveCopy' = $true
}
$modelScenarioG = Update-BRAVOConfiguratorEffective -Model $modelScenarioG -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioG = @($modelScenarioG | Where-Object { $_.Path -eq 'componentSettings.SMB.ArchiveCopy' })
Test-BRAVOCondition ($settingScenarioG.Count -eq 1 -and [bool]$settingScenarioG[0].EffectiveValue -eq $true) `
    'Configurator 5.2.2 Scenario G: SFTP.Enabled=false НЕ вимикає SMB.ArchiveCopy' `
    "Effective=$($settingScenarioG[0].EffectiveValue)"

# Scenario H: SMB disabled НЕ вимикає SFTP (незалежні master-и)
$modelScenarioH = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SMB.Enabled' = $false
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioH = Update-BRAVOConfiguratorEffective -Model $modelScenarioH -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioH = @($modelScenarioH | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($settingScenarioH.Count -eq 1 -and [bool]$settingScenarioH[0].EffectiveValue -eq $true) `
    'Configurator 5.2.2 Scenario H: SMB.Enabled=false НЕ вимикає SFTP.ArchiveUpload' `
    "Effective=$($settingScenarioH[0].EffectiveValue)"

# Scenario I (Health isolation, §P0.6): backupMonitoring.SFTP.Enabled=false
# з операційним SFTP.Enabled=true НЕ повинно вимикати operational
# ArchiveUpload — Health-вимикач лишається у власному semantic domain.
$modelScenarioI = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'backupMonitoring.SFTP.Enabled' = $false
    'componentSettings.SFTP.Enabled' = $true
    'componentSettings.SFTP.ArchiveUpload' = $true
}
$modelScenarioI = Update-BRAVOConfiguratorEffective -Model $modelScenarioI -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioI = @($modelScenarioI | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($settingScenarioI.Count -eq 1 -and [bool]$settingScenarioI[0].EffectiveValue -eq $true -and [string]::IsNullOrWhiteSpace([string]$settingScenarioI[0].DisabledReason)) `
    'Configurator 5.2.2 Scenario I: backupMonitoring.SFTP.Enabled=false НЕ вимикає operational ArchiveUpload (Health isolation)' `
    "Effective=$($settingScenarioI[0].EffectiveValue) DisabledReason=$($settingScenarioI[0].DisabledReason)"

# Scenario J (Health isolation, §P0.6): backupMonitoring.SMB.Enabled=false
# з операційним SMB.Enabled=true НЕ повинно вимикати operational ArchiveCopy.
$modelScenarioJ = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'backupMonitoring.SMB.Enabled' = $false
    'componentSettings.SMB.Enabled' = $true
    'componentSettings.SMB.ArchiveCopy' = $true
}
$modelScenarioJ = Update-BRAVOConfiguratorEffective -Model $modelScenarioJ -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioJ = @($modelScenarioJ | Where-Object { $_.Path -eq 'componentSettings.SMB.ArchiveCopy' })
Test-BRAVOCondition ($settingScenarioJ.Count -eq 1 -and [bool]$settingScenarioJ[0].EffectiveValue -eq $true -and [string]::IsNullOrWhiteSpace([string]$settingScenarioJ[0].DisabledReason)) `
    'Configurator 5.2.2 Scenario J: backupMonitoring.SMB.Enabled=false НЕ вимикає operational ArchiveCopy (Health isolation)' `
    "Effective=$($settingScenarioJ[0].EffectiveValue) DisabledReason=$($settingScenarioJ[0].DisabledReason)"

# Scenario K: schema completeness (== canonical documented override paths,
# missing=0, stale=0) уже перевірено вище ($configuratorSchemaResult,
# IsComplete/MissingPaths/OrphanPaths) — не дублюємо ту саму перевірку.
Test-BRAVOCondition ($configuratorSchemaResult.IsComplete -and $configuratorSchemaResult.SchemaDescriptors -eq $configuratorSchemaResult.ConfigurableTotal) `
    'Configurator 5.2.2 Scenario K: descriptors == canonical documented paths (138), missing=0, stale=0' `
    "SchemaDescriptors=$($configuratorSchemaResult.SchemaDescriptors) ConfigurableTotal=$($configuratorSchemaResult.ConfigurableTotal)"

# ===== SMB.ArchiveCopy default (raw) лишається без override — Validation
# blocking-сценарій нижче (SMB.ArchiveCopy=true + порожній RootPath)
# перевіряє саме Raw override, не залежить від нового SMB.Enabled master —
# лишено без змін (P0.9: жодної нової залежності в дійсному runtime немає
# для smbSettings.RootPath).

# ===== Validation: SMB blocking ERROR + clean model zero-findings (§22.11-13 задачі) =====
$modelSmbInvalid = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SMB.ArchiveCopy' = $true
    'smbSettings.RootPath' = ''
}
$modelSmbInvalid = Update-BRAVOConfiguratorEffective -Model $modelSmbInvalid -RuntimeRoot $configuratorFixtureRuntimeRoot
$validationSmbInvalid = Invoke-BRAVOConfiguratorValidation -Model $modelSmbInvalid
Test-BRAVOCondition ($validationSmbInvalid.HasErrors -and $validationSmbInvalid.ErrorCount -eq 1) `
    'Configurator Validation: SMB.ArchiveCopy=true + порожній RootPath -> blocking ERROR' `
    "HasErrors=$($validationSmbInvalid.HasErrors) ErrorCount=$($validationSmbInvalid.ErrorCount)"

$validationClean = Invoke-BRAVOConfiguratorValidation -Model $modelNoOverride
Test-BRAVOCondition (-not $validationClean.HasErrors -and $validationClean.Findings.Count -eq 0) `
    'Configurator Validation: чиста модель без overrides -> 0 findings' `
    "HasErrors=$($validationClean.HasErrors) Findings=$($validationClean.Findings.Count)"

# ===== Persistence: 14-19 (§22 задачі) — ізольована production-директорія =====
$configuratorPersistScenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_PERSIST_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorPersistScenarioRoot)
try {
    # 14: candidate valid -> atomic apply (на порожній production-директорії)
    $persistBaselineEmpty = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineEmpty.Overrides
    $persistModel = Set-BRAVOConfiguratorOverride -Model $persistModel -Path 'consoleSettings.ConsoleLevel' -Value 'ERROR'
    $persistModel = Update-BRAVOConfiguratorEffective -Model $persistModel -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyValid = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineEmpty
    Test-BRAVOCondition ($persistApplyValid.Applied -and $persistApplyValid.Stage -eq 'Complete') `
        'Configurator Persistence: валідний candidate -> atomic apply' `
        "Applied=$($persistApplyValid.Applied) Stage=$($persistApplyValid.Stage) Reasons=$($persistApplyValid.Reasons -join '; ')"

    $persistContentAfterValid = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8

    # 15: candidate invalid -> production untouched
    $persistBaselineForInvalid = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistInvalidModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineForInvalid.Overrides
    $persistInvalidModel = Set-BRAVOConfiguratorOverride -Model $persistInvalidModel -Path 'componentSettings.SMB.ArchiveCopy' -Value $true
    $persistInvalidModel = Set-BRAVOConfiguratorOverride -Model $persistInvalidModel -Path 'smbSettings.RootPath' -Value ''
    $persistInvalidModel = Update-BRAVOConfiguratorEffective -Model $persistInvalidModel -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyInvalid = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistInvalidModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineForInvalid
    $persistContentAfterInvalidAttempt = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
    Test-BRAVOCondition ((-not $persistApplyInvalid.Applied) -and $persistApplyInvalid.Stage -eq 'Validation' -and $persistContentAfterInvalidAttempt -eq $persistContentAfterValid) `
        'Configurator Persistence: невалідний candidate -> production файл незмінний' `
        "Applied=$($persistApplyInvalid.Applied) Stage=$($persistApplyInvalid.Stage) FileUnchanged=$($persistContentAfterInvalidAttempt -eq $persistContentAfterValid)"

    # 16: baseline змінився паралельно -> STOP (race detection), без merge
    $staleBaselineForRace = $persistBaselineEmpty   # свідомо застарілий знімок (до кроку 14)
    $persistApplyRace = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $staleBaselineForRace
    Test-BRAVOCondition ((-not $persistApplyRace.Applied) -and $persistApplyRace.Stage -eq 'RaceDetection') `
        'Configurator Persistence: застарілий baseline -> STOP без merge/overwrite' `
        "Applied=$($persistApplyRace.Applied) Stage=$($persistApplyRace.Stage)"

    # 17: backup створюється перед replace
    Test-BRAVOCondition ($null -ne $persistApplyValid.BackupPath -or -not $persistBaselineEmpty.Present) `
        'Configurator Persistence: backup створюється, якщо існував попередній файл (тут — перший запис, backup не очікується)' `
        "BackupPath=$($persistApplyValid.BackupPath) ProductionWasPresent=$($persistBaselineEmpty.Present)"

    # 18: unknown/newer ключ (не в схемі) переживає roundtrip
    $persistBaselineForUnknown = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $mergedWithUnknown = @{}
    foreach ($existingKey in $persistBaselineForUnknown.Overrides.Keys) { $mergedWithUnknown[$existingKey] = $persistBaselineForUnknown.Overrides[$existingKey] }
    $mergedWithUnknown['maintenanceSettings.FutureFieldNotYetInSchema'] = 'preserve-me'
    [IO.File]::WriteAllText(
        (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config'),
        (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides $mergedWithUnknown),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $persistBaselineWithUnknown = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistModelWithUnknown = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineWithUnknown.Overrides
    $persistModelWithUnknown = Set-BRAVOConfiguratorOverride -Model $persistModelWithUnknown -Path 'progressSettings.Enabled' -Value $false
    $persistModelWithUnknown = Update-BRAVOConfiguratorEffective -Model $persistModelWithUnknown -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyWithUnknown = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModelWithUnknown -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineWithUnknown
    $persistContentWithUnknown = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
    Test-BRAVOCondition ($persistApplyWithUnknown.Applied -and $persistContentWithUnknown -match 'FutureFieldNotYetInSchema') `
        'Configurator Persistence: невідомий/newer ключ переживає roundtrip' `
        "Applied=$($persistApplyWithUnknown.Applied) UnknownKeyPresent=$($persistContentWithUnknown -match 'FutureFieldNotYetInSchema')"

    # 19: повторний Apply без реальних змін — ідемпотентний (той самий контент/хеш)
    $persistBaselineIdem = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistModelIdem = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineIdem.Overrides
    $persistModelIdem = Update-BRAVOConfiguratorEffective -Model $persistModelIdem -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyIdem = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModelIdem -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineIdem
    Test-BRAVOCondition ($persistApplyIdem.Applied -and $persistApplyIdem.NewHash -eq $persistBaselineIdem.BaselineHash) `
        'Configurator Persistence: повторний Apply без змін — ідемпотентний' `
        "Applied=$($persistApplyIdem.Applied) NewHash=$($persistApplyIdem.NewHash) BaselineHash=$($persistBaselineIdem.BaselineHash)"
    # 20 (P1-регресія за незалежним review): зламаний preserved/legacy
    # ключ (неіснуючий кореневий $global:) МУСИТЬ бути відхилений на
    # Validation-стадії, а не пройти Apply мовчки. До фіксу
    # Test-BRAVOConfiguratorCandidateOverrides прогоняв Effective лише
    # для schema-відомих Path (ConvertTo-BRAVOConfiguratorOverrideHashtable
    # мовчки відкидала цей ключ) — тепер Update-BRAVOConfiguratorEffective
    # викликається з -CandidateOverridesOverride $mergedOverrides (повний
    # набір), тому canonical loader реально бачить і відхиляє зламаний ключ.
    $persistBaselineForBrokenKey = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $mergedWithBrokenKey = @{}
    foreach ($existingKey in $persistBaselineForBrokenKey.Overrides.Keys) { $mergedWithBrokenKey[$existingKey] = $persistBaselineForBrokenKey.Overrides[$existingKey] }
    $mergedWithBrokenKey['thisRootDoesNotExist.BrokenLegacyField'] = 'x'
    [IO.File]::WriteAllText(
        (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config'),
        (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides $mergedWithBrokenKey),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $persistBaselineWithBrokenKey = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot
    $persistContentBeforeBrokenAttempt = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
    $persistModelForBrokenKey = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $persistBaselineWithBrokenKey.Overrides
    $persistModelForBrokenKey = Set-BRAVOConfiguratorOverride -Model $persistModelForBrokenKey -Path 'progressSettings.Enabled' -Value $true
    $persistModelForBrokenKey = Update-BRAVOConfiguratorEffective -Model $persistModelForBrokenKey -RuntimeRoot $configuratorFixtureRuntimeRoot
    $persistApplyBrokenKey = Invoke-BRAVOConfiguratorApply -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPersistScenarioRoot -Model $persistModelForBrokenKey -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $persistBaselineWithBrokenKey
    $persistContentAfterBrokenAttempt = Get-Content -LiteralPath (Join-Path $configuratorPersistScenarioRoot 'BRAVO.local.config') -Raw -Encoding UTF8
    Test-BRAVOCondition ((-not $persistApplyBrokenKey.Applied) -and $persistApplyBrokenKey.Stage -eq 'Validation' -and $persistContentAfterBrokenAttempt -eq $persistContentBeforeBrokenAttempt) `
        'Configurator Persistence: зламаний preserved-ключ (неіснуючий root) -> Apply відхилено на Validation, не записано' `
        "Applied=$($persistApplyBrokenKey.Applied) Stage=$($persistApplyBrokenKey.Stage) Reasons=$($persistApplyBrokenKey.Reasons -join '; ')"
} finally {
    Remove-Item -LiteralPath $configuratorPersistScenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== P2-A.7: hermetic Backup forced-failure (§Stage='Backup') =====
# Крок 11 (Copy-Item production -> .bak) провалюється, якщо WRITE у
# директорію заборонено ACL deny-rule для поточного користувача — на
# відміну від file-lock (AtomicReplace-тест нижче), READ джерела (і крок
# 10 race-check, і сам Copy-Item source-read) лишається доступним, тому
# збій ізольовано САМЕ на кроці 11, а не раніше. Реальна знахідка: до
# P2-A.7 backup Copy-Item НЕ мав власного try/catch взагалі — необроблений
# виняток пробив би Invoke-BRAVOConfiguratorApply наскрізь, порушуючи
# задокументований контракт "завжди повертає структурований результат".
$configuratorBackupFailureRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_BACKUPFAIL_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorBackupFailureRoot)
$backupFailureDenyRule = $null
$backupFailureAclApplied = $false
try {
    $backupFailureConfigPath = Join-Path $configuratorBackupFailureRoot 'BRAVO.local.config'
    [IO.File]::WriteAllText(
        $backupFailureConfigPath,
        (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides @{ 'consoleSettings.ConsoleLevel' = 'ERROR' }),
        (New-Object System.Text.UTF8Encoding($false)))
    $backupFailureBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorBackupFailureRoot
    $backupFailureContentBefore = Get-Content -LiteralPath $backupFailureConfigPath -Raw -Encoding UTF8
    $backupFailureModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $backupFailureBaseline.Overrides
    $backupFailureModel = Set-BRAVOConfiguratorOverride -Model $backupFailureModel -Path 'consoleSettings.ConsoleLevel' -Value 'WARN'
    $backupFailureModel = Update-BRAVOConfiguratorEffective -Model $backupFailureModel -RuntimeRoot $configuratorFixtureRuntimeRoot

    $backupFailureAcl = Get-Acl -Path $configuratorBackupFailureRoot
    $backupFailureIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $backupFailureDenyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $backupFailureIdentity, 'CreateFiles,Write', 'ContainerInherit,ObjectInherit', 'None', 'Deny')
    $backupFailureAcl.AddAccessRule($backupFailureDenyRule)
    Set-Acl -Path $configuratorBackupFailureRoot -AclObject $backupFailureAcl
    $backupFailureAclApplied = $true

    $persistApplyBackupFailure = Invoke-BRAVOConfiguratorApply `
        -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorBackupFailureRoot `
        -Model $backupFailureModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $backupFailureBaseline

    # ACL знімається ПЕРЕД читанням результату/cleanup, інакше Get-Content/
    # Remove-Item нижче так само впадуть на deny-write directory.
    if ($backupFailureAclApplied) {
        $backupFailureAclRestore = Get-Acl -Path $configuratorBackupFailureRoot
        $backupFailureAclRestore.RemoveAccessRule($backupFailureDenyRule) | Out-Null
        Set-Acl -Path $configuratorBackupFailureRoot -AclObject $backupFailureAclRestore
        $backupFailureAclApplied = $false
    }

    $backupFailureContentAfter = Get-Content -LiteralPath $backupFailureConfigPath -Raw -Encoding UTF8
    $backupFailureTempLeftovers = @(Get-ChildItem -LiteralPath $configuratorBackupFailureRoot -Filter 'BRAVO.local.config.tmp-*' -ErrorAction SilentlyContinue)
    $backupFailureBakFiles = @(Get-ChildItem -LiteralPath $configuratorBackupFailureRoot -Filter 'BRAVO.local.config.bak-*' -ErrorAction SilentlyContinue)
    Test-BRAVOCondition (
        (-not $persistApplyBackupFailure.Applied) -and
        $persistApplyBackupFailure.Stage -eq 'Backup' -and
        $backupFailureContentAfter -eq $backupFailureContentBefore -and
        $backupFailureTempLeftovers.Count -eq 0 -and
        $backupFailureBakFiles.Count -eq 0 -and
        $persistApplyBackupFailure.Reasons.Count -gt 0
    ) `
        'Configurator Persistence: forced Backup failure (ACL deny-write directory) -> Applied=false Stage=Backup, оригінал незмінний, AtomicReplace/PostApplyVerification НЕ виконувались' `
        ("Applied=$($persistApplyBackupFailure.Applied) Stage=$($persistApplyBackupFailure.Stage) " +
         "ContentUnchanged=$($backupFailureContentAfter -eq $backupFailureContentBefore) TempLeftovers=$($backupFailureTempLeftovers.Count) " +
         "BakFiles=$($backupFailureBakFiles.Count) Reasons=$($persistApplyBackupFailure.Reasons -join '; ')")
} finally {
    if ($backupFailureAclApplied -and $null -ne $backupFailureDenyRule) {
        try {
            $backupFailureAclCleanup = Get-Acl -Path $configuratorBackupFailureRoot
            $backupFailureAclCleanup.RemoveAccessRule($backupFailureDenyRule) | Out-Null
            Set-Acl -Path $configuratorBackupFailureRoot -AclObject $backupFailureAclCleanup
        } catch { }
    }
    Remove-Item -LiteralPath $configuratorBackupFailureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== P2-A.1: hermetic AtomicReplace forced-failure (§Stage='AtomicReplace') =====
# Crок 12 (Move-Item temp -> production) провалюється, якщо production-файл
# відкритий БЕЗ FileShare.Delete — реальний, детермінований, без потреби у
# test-only seam чи змінах Persistence-коду (перевірено окремим прототипом:
# Move-Item -Force дійсно кидає "Cannot create a file when that file already
# exists" на такому handle).
$configuratorAtomicReplaceRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_ATOMICREPLACE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorAtomicReplaceRoot)
try {
    $atomicReplaceConfigPath = Join-Path $configuratorAtomicReplaceRoot 'BRAVO.local.config'
    [IO.File]::WriteAllText(
        $atomicReplaceConfigPath,
        (ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides @{ 'consoleSettings.ConsoleLevel' = 'ERROR' }),
        (New-Object System.Text.UTF8Encoding($false)))
    $atomicReplaceBaseline = Get-BRAVOConfiguratorProductionOverrideState -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorAtomicReplaceRoot
    $atomicReplaceContentBefore = Get-Content -LiteralPath $atomicReplaceConfigPath -Raw -Encoding UTF8
    $atomicReplaceModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $atomicReplaceBaseline.Overrides
    $atomicReplaceModel = Set-BRAVOConfiguratorOverride -Model $atomicReplaceModel -Path 'consoleSettings.ConsoleLevel' -Value 'WARN'
    $atomicReplaceModel = Update-BRAVOConfiguratorEffective -Model $atomicReplaceModel -RuntimeRoot $configuratorFixtureRuntimeRoot

    $atomicReplaceLockStream = [System.IO.File]::Open(
        $atomicReplaceConfigPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $persistApplyAtomicReplaceFailure = Invoke-BRAVOConfiguratorApply `
            -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorAtomicReplaceRoot `
            -Model $atomicReplaceModel -SchemaCatalog $configuratorSchemaCatalog -ProductionBaseline $atomicReplaceBaseline
    } finally {
        $atomicReplaceLockStream.Close()
    }
    $atomicReplaceContentAfter = Get-Content -LiteralPath $atomicReplaceConfigPath -Raw -Encoding UTF8
    $atomicReplaceTempLeftovers = @(Get-ChildItem -LiteralPath $configuratorAtomicReplaceRoot -Filter 'BRAVO.local.config.tmp-*' -ErrorAction SilentlyContinue)
    Test-BRAVOCondition (
        (-not $persistApplyAtomicReplaceFailure.Applied) -and
        $persistApplyAtomicReplaceFailure.Stage -eq 'AtomicReplace' -and
        $atomicReplaceContentAfter -eq $atomicReplaceContentBefore -and
        $atomicReplaceTempLeftovers.Count -eq 0
    ) `
        'Configurator Persistence: forced AtomicReplace failure (locked production file) -> Applied=false, оригінал незмінний, temp прибрано' `
        ("Applied=$($persistApplyAtomicReplaceFailure.Applied) Stage=$($persistApplyAtomicReplaceFailure.Stage) " +
         "ContentUnchanged=$($atomicReplaceContentAfter -eq $atomicReplaceContentBefore) TempLeftovers=$($atomicReplaceTempLeftovers.Count) " +
         "Reasons=$($persistApplyAtomicReplaceFailure.Reasons -join '; ')")
} finally {
    Remove-Item -LiteralPath $configuratorAtomicReplaceRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== P2-A.2: PostApplyVerification forced-mismatch (§Stage='PostApplyVerification') =====
# Test-BRAVOConfiguratorPostApplyVerification винесено з Invoke-BRAVOConfiguratorApply
# (крок 13-14) саме для цього — hermetic виклик напряму з деліберативно
# зіпсованим "щойно записаним" файлом (canonical Read-BRAVOLocalConfigurationOverrides
# відхиляє $env:-звернення через CheckRestrictedLanguage), без залежності
# від таймінгу/race файлової системи.
$configuratorPostVerifyRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_POSTAPPLYVERIFY_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorPostVerifyRoot)
try {
    $postVerifyConfigPath = Join-Path $configuratorPostVerifyRoot 'BRAVO.local.config'
    $postVerifyBackupPath = "$postVerifyConfigPath.bak-selftest"
    $postVerifyOriginalContent = ConvertTo-BRAVOConfiguratorLocalConfigText -MergedOverrides @{ 'consoleSettings.ConsoleLevel' = 'ERROR' }
    [IO.File]::WriteAllText($postVerifyBackupPath, $postVerifyOriginalContent, (New-Object System.Text.UTF8Encoding($false)))
    # "Щойно записаний" файл — синтаксично неприпустимий (CheckRestrictedLanguage
    # відхилить $env: звернення) -> reload на кроці 13 гарантовано впаде.
    [IO.File]::WriteAllText($postVerifyConfigPath, "@{ 'x' = `$env:PATH }", (New-Object System.Text.UTF8Encoding($false)))

    $postVerifyResultWithBackup = Test-BRAVOConfiguratorPostApplyVerification `
        -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPostVerifyRoot `
        -ProductionConfigPath $postVerifyConfigPath -BackupPath $postVerifyBackupPath
    $postVerifyContentAfterRollback = Get-Content -LiteralPath $postVerifyConfigPath -Raw -Encoding UTF8
    Test-BRAVOCondition (
        ($null -ne $postVerifyResultWithBackup) -and
        (-not $postVerifyResultWithBackup.Applied) -and
        $postVerifyResultWithBackup.Stage -eq 'PostApplyVerification' -and
        $postVerifyContentAfterRollback -eq $postVerifyOriginalContent
    ) `
        'Configurator Persistence: forced PostApplyVerification mismatch (backup наявний) -> Applied=false, rollback з backup, фінальний стан = оригінал' `
        ("Applied=$($postVerifyResultWithBackup.Applied) Stage=$($postVerifyResultWithBackup.Stage) " +
         "RolledBackToOriginal=$($postVerifyContentAfterRollback -eq $postVerifyOriginalContent) " +
         "Reasons=$($postVerifyResultWithBackup.Reasons -join '; ')")

    # Без backup (симулює перший-у-житті запис, що самé виявився зіпсованим) ->
    # rollback видаляє файл, а не лишає невалідований production-стан.
    [IO.File]::WriteAllText($postVerifyConfigPath, "@{ 'x' = `$env:PATH }", (New-Object System.Text.UTF8Encoding($false)))
    $postVerifyResultNoBackup = Test-BRAVOConfiguratorPostApplyVerification `
        -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPostVerifyRoot `
        -ProductionConfigPath $postVerifyConfigPath
    $postVerifyFileRemainsAfterNoBackupRollback = Test-Path -LiteralPath $postVerifyConfigPath -PathType Leaf
    Test-BRAVOCondition (
        ($null -ne $postVerifyResultNoBackup) -and
        (-not $postVerifyResultNoBackup.Applied) -and
        $postVerifyResultNoBackup.Stage -eq 'PostApplyVerification' -and
        (-not $postVerifyFileRemainsAfterNoBackupRollback)
    ) `
        'Configurator Persistence: forced PostApplyVerification mismatch (без backup) -> Applied=false, rollback видаляє файл' `
        ("Applied=$($postVerifyResultNoBackup.Applied) Stage=$($postVerifyResultNoBackup.Stage) " +
         "FileRemains=$postVerifyFileRemainsAfterNoBackupRollback Reasons=$($postVerifyResultNoBackup.Reasons -join '; ')")

    # Успішна верифікація (валідний "щойно записаний" файл) -> $null,
    # Apply продовжує до Complete (те саме, що вже покривають тести 14/19 вище).
    [IO.File]::WriteAllText($postVerifyConfigPath, $postVerifyOriginalContent, (New-Object System.Text.UTF8Encoding($false)))
    $postVerifyResultSuccess = Test-BRAVOConfiguratorPostApplyVerification `
        -RuntimeRoot $configuratorFixtureRuntimeRoot -ProductionConfigDirectory $configuratorPostVerifyRoot `
        -ProductionConfigPath $postVerifyConfigPath -BackupPath $postVerifyBackupPath
    Test-BRAVOCondition ($null -eq $postVerifyResultSuccess) `
        'Configurator Persistence: PostApplyVerification успішна -> $null (Apply продовжує до Complete)' `
        "Result=$postVerifyResultSuccess"
} finally {
    Remove-Item -LiteralPath $configuratorPostVerifyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== 21 (P2-регресія за незалежним review): EffectiveSource для масивів =====
# Test-BRAVOConfiguratorValueEquality замінив '-eq' (element-wise для
# масивів зліва — завжди хибний 'Derived' навіть для дійсно рівних
# масивів) на справжнє глибоке порівняння.
# BravoDisplayName має 2 елементи в BRAVO.config default (@("BRAVO Service",
# "BRAVO Server")) — з ОДНИМ елементом '-eq' на масивах випадково давав
# truthy результат (element-wise match повертає непорожній масив), тому
# саме 2+-елементний масив реально демонструє баг/фікс.
$configuratorArrayPathForEquality = 'maintenanceSettings.Services.BravoDisplayName'
$modelArrayNoOverride = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}
$modelArrayNoOverride = Update-BRAVOConfiguratorEffective -Model $modelArrayNoOverride -RuntimeRoot $configuratorFixtureRuntimeRoot
$arraySettingNoOverride = @($modelArrayNoOverride | Where-Object { $_.Path -eq $configuratorArrayPathForEquality })
Test-BRAVOCondition ($arraySettingNoOverride.Count -eq 1 -and $arraySettingNoOverride[0].EffectiveSource -eq 'Default') `
    'Configurator Model: EffectiveSource для StringArray без override -> Default (не хибний Derived)' `
    "Path=$configuratorArrayPathForEquality EffectiveSource=$($arraySettingNoOverride[0].EffectiveSource) Effective=$($arraySettingNoOverride[0].EffectiveValue -join ',') Default=$($arraySettingNoOverride[0].DefaultValue -join ',')"

# ===== P1.1 незалежний review (2 P2-регресії) =====

# L: hashtable-значення у candidate -> ConvertTo-BRAVOConfiguratorPowerShellLiteral
# явно відхиляє (fail-closed), а не рекурсує до call-depth overflow.
$configuratorHashtableLiteralThrew = $false
$configuratorHashtableLiteralMessage = $null
try {
    [void](ConvertTo-BRAVOConfiguratorPowerShellLiteral -Value @{ Nested = 'value' })
} catch {
    $configuratorHashtableLiteralThrew = $true
    $configuratorHashtableLiteralMessage = $_.Exception.Message
}
Test-BRAVOCondition ($configuratorHashtableLiteralThrew -and $configuratorHashtableLiteralMessage -notmatch 'call depth overflow') `
    'Configurator Effective: hashtable-значення відхиляється явним винятком, не рекурсією до call depth overflow' `
    "Threw=$configuratorHashtableLiteralThrew Message=$configuratorHashtableLiteralMessage"

# M: BAZA_APP_SFTP raw=false + SFTP.Enabled=false -> DisabledReason НЕ
# приписується master-у (Effective=false спричинений власним raw-вибором
# оператора, а не глобальним вимикачем).
$modelScenarioM = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{
    'componentSettings.SFTP.Enabled' = $false
    'componentSettings.Synchronization.BAZA_APP_SFTP' = $false
}
$modelScenarioM = Update-BRAVOConfiguratorEffective -Model $modelScenarioM -RuntimeRoot $configuratorFixtureRuntimeRoot
$settingScenarioM = @($modelScenarioM | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_SFTP' })
Test-BRAVOCondition ($settingScenarioM.Count -eq 1 -and [bool]$settingScenarioM[0].EffectiveValue -eq $false -and [string]::IsNullOrWhiteSpace([string]$settingScenarioM[0].DisabledReason)) `
    'Configurator 5.2.2 Scenario M: BAZA_APP_SFTP raw=false + SFTP.Enabled=false -> DisabledReason НЕ приписується master-у (власний вибір оператора)' `
    "Effective=$($settingScenarioM[0].EffectiveValue) DisabledReason=$($settingScenarioM[0].DisabledReason)"

# ===== P1.7 Credentials: requirement-формула (детерміновано, без
# звернення до Credential Manager — CI-гермет) =====

# N: SFTP master OFF -> Required=false, незалежно від child-прапорців.
$credentialEffectiveSftpOff = [pscustomobject]@{
    storageEffective  = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $false; ArchiveUpload = $false; DisabledReason = 'SFTP глобально вимкнено (componentSettings.SFTP.Enabled = $false)' }
        SMB  = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $false; DisabledReason = $null }
    }
    bazaSyncEffective = [pscustomobject]@{ ScheduledSftpSyncRequired = $false }
    backupMonitoring  = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true }; SMB = [pscustomobject]@{ Enabled = $true } }
}
$credentialRequirementSftpOff = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveSftpOff
Test-BRAVOCondition (-not $credentialRequirementSftpOff.SFTP.Required) `
    'Configurator Credentials: SFTP master OFF -> SFTP credentials НЕ обов''язкові' `
    "Required=$($credentialRequirementSftpOff.SFTP.Required)"

# O: SFTP master ON + ArchiveUpload=true -> Required=true.
$credentialEffectiveSftpOn = [pscustomobject]@{
    storageEffective  = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $true; ArchiveUpload = $true; DisabledReason = $null }
        SMB  = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $false; DisabledReason = $null }
    }
    bazaSyncEffective = [pscustomobject]@{ ScheduledSftpSyncRequired = $false }
    backupMonitoring  = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $false }; SMB = [pscustomobject]@{ Enabled = $false } }
}
$credentialRequirementSftpOn = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveSftpOn
Test-BRAVOCondition ($credentialRequirementSftpOn.SFTP.Required) `
    'Configurator Credentials: SFTP operational (master ON + ArchiveUpload) -> credentials обов''язкові' `
    "Required=$($credentialRequirementSftpOn.SFTP.Required)"

# P: SMB master OFF (storageEffective.SMB.ArchiveCopy вже false за
# конструкцією резолвера) -> Required=false.
$credentialRequirementSmbOff = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveSftpOn
Test-BRAVOCondition (-not $credentialRequirementSmbOff.SMB.Required) `
    'Configurator Credentials: SMB.ArchiveCopy effective=false -> SMB credentials НЕ обов''язкові' `
    "Required=$($credentialRequirementSmbOff.SMB.Required)"

# Q: SMB operational (ArchiveCopy effective=true) -> Required=true.
$credentialEffectiveSmbOn = [pscustomobject]@{
    storageEffective  = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $false; ArchiveUpload = $false; DisabledReason = $null }
        SMB  = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $true; DisabledReason = $null }
    }
    bazaSyncEffective = [pscustomobject]@{ ScheduledSftpSyncRequired = $false }
    backupMonitoring  = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $false }; SMB = [pscustomobject]@{ Enabled = $false } }
}
$credentialRequirementSmbOn = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveSmbOn
Test-BRAVOCondition ($credentialRequirementSmbOn.SMB.Required) `
    'Configurator Credentials: SMB operational (ArchiveCopy effective=true) -> credentials обов''язкові' `
    "Required=$($credentialRequirementSmbOn.SMB.Required)"

# R: Health-only SFTP monitoring (backupMonitoring.SFTP.Enabled=true) з
# master ON, без ArchiveUpload/BAZA sync -> все одно Required=true (Health
# monitoring сам по собі законна причина потребувати креденшели, доки
# master увімкнений) — canonical формула, не Configurator-вигадка.
$credentialEffectiveHealthOnly = [pscustomobject]@{
    storageEffective  = [pscustomobject]@{
        SFTP = [pscustomobject]@{ Enabled = $true; ArchiveUpload = $false; DisabledReason = $null }
        SMB  = [pscustomobject]@{ Enabled = $true; ArchiveCopy = $false; DisabledReason = $null }
    }
    bazaSyncEffective = [pscustomobject]@{ ScheduledSftpSyncRequired = $false }
    backupMonitoring  = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $true }; SMB = [pscustomobject]@{ Enabled = $false } }
}
$credentialRequirementHealthOnly = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $credentialEffectiveHealthOnly
Test-BRAVOCondition ($credentialRequirementHealthOnly.SFTP.Required) `
    'Configurator Credentials: SFTP Health-моніторинг увімкнено (master ON) -> credentials обов''язкові (навіть без ArchiveUpload/BAZA sync)' `
    "Required=$($credentialRequirementHealthOnly.SFTP.Required)"

# S: смоук-тест реального (non-mutating) прогону -Action Test через
# Invoke-BRAVOConfiguratorCredentialCheck — НЕ прив'язується до
# конкретного Found/Missing (CI-runner може не мати credential), лише
# перевіряє, що виклик повертає валідний статус без винятку.
$configuratorCredentialCheckResult = Invoke-BRAVOConfiguratorCredentialCheck -RuntimeRoot $root -Component 'SFTP' -TimeoutSeconds 30
Test-BRAVOCondition ($configuratorCredentialCheckResult.Status -in @('Found', 'Missing', 'Error')) `
    'Configurator Credentials: Invoke-BRAVOConfiguratorCredentialCheck повертає валідний статус без винятку (CI-гермет, не прив''язано до Found/Missing)' `
    "Status=$($configuratorCredentialCheckResult.Status) ExitCode=$($configuratorCredentialCheckResult.ExitCode) Reason=$($configuratorCredentialCheckResult.Reason)"

# ===== P1.6 Presets: чисті model-трансформації (не пишуть файл) =====

$configuratorPresetBaseModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}
# Навмисний unrelated override ДО preset — має пережити будь-який preset.
$configuratorPresetBaseModel = Set-BRAVOConfiguratorOverride -Model $configuratorPresetBaseModel -Path 'consoleSettings.ConsoleLevel' -Value 'ERROR'

# T: LocalOnly -> SFTP.Enabled=false, SMB.Enabled=false.
$configuratorPresetLocalOnly = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'LocalOnly'
$configuratorPresetLocalOnlySftp = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.SFTP.Enabled' })
$configuratorPresetLocalOnlySmb = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.SMB.Enabled' })
Test-BRAVOCondition ($configuratorPresetLocalOnlySftp.Count -eq 1 -and [bool]$configuratorPresetLocalOnlySftp[0].OverrideValue -eq $false -and [bool]$configuratorPresetLocalOnlySmb[0].OverrideValue -eq $false) `
    'Configurator Presets: LocalOnly -> SFTP.Enabled=false, SMB.Enabled=false' `
    "SFTP=$($configuratorPresetLocalOnlySftp[0].OverrideValue) SMB=$($configuratorPresetLocalOnlySmb[0].OverrideValue)"

# U: unrelated override (consoleSettings.ConsoleLevel) переживає preset.
$configuratorPresetLocalOnlyConsole = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'consoleSettings.ConsoleLevel' })
Test-BRAVOCondition ($configuratorPresetLocalOnlyConsole.Count -eq 1 -and [string]$configuratorPresetLocalOnlyConsole[0].OverrideValue -eq 'ERROR') `
    'Configurator Presets: preset не стирає unrelated override (consoleSettings.ConsoleLevel)' `
    "ConsoleLevel=$($configuratorPresetLocalOnlyConsole[0].OverrideValue)"

# V: LocalPlusSFTPAndSMB -> обидва master=true.
$configuratorPresetBoth = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'LocalPlusSFTPAndSMB'
$configuratorPresetBothSftp = @($configuratorPresetBoth | Where-Object { $_.Path -eq 'componentSettings.SFTP.Enabled' })
$configuratorPresetBothSmb = @($configuratorPresetBoth | Where-Object { $_.Path -eq 'componentSettings.SMB.Enabled' })
Test-BRAVOCondition ([bool]$configuratorPresetBothSftp[0].OverrideValue -eq $true -and [bool]$configuratorPresetBothSmb[0].OverrideValue -eq $true) `
    'Configurator Presets: LocalPlusSFTPAndSMB -> SFTP.Enabled=true, SMB.Enabled=true' `
    "SFTP=$($configuratorPresetBothSftp[0].OverrideValue) SMB=$($configuratorPresetBothSmb[0].OverrideValue)"

# W: idempotent — повторне застосування того самого preset дає той самий результат.
$configuratorPresetLocalOnlyTwice = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetLocalOnly -PresetName 'LocalOnly'
$configuratorPresetLocalOnlyTwiceSftp = @($configuratorPresetLocalOnlyTwice | Where-Object { $_.Path -eq 'componentSettings.SFTP.Enabled' })
Test-BRAVOCondition ([bool]$configuratorPresetLocalOnlyTwiceSftp[0].OverrideValue -eq $false) `
    'Configurator Presets: повторне застосування LocalOnly — ідемпотентне' `
    "SFTP=$($configuratorPresetLocalOnlyTwiceSftp[0].OverrideValue)"

# X: master OFF (preset) не втрачає раніше виставлений child raw override
# — той самий master/child контракт, що ручне редагування.
$configuratorPresetChildBase = Set-BRAVOConfiguratorOverride -Model $configuratorPresetBaseModel -Path 'componentSettings.SFTP.ArchiveUpload' -Value $true
$configuratorPresetChildAfterLocalOnly = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetChildBase -PresetName 'LocalOnly'
$configuratorPresetChildSetting = @($configuratorPresetChildAfterLocalOnly | Where-Object { $_.Path -eq 'componentSettings.SFTP.ArchiveUpload' })
Test-BRAVOCondition ($configuratorPresetChildSetting.Count -eq 1 -and [bool]$configuratorPresetChildSetting[0].OverrideValue -eq $true) `
    'Configurator Presets: LocalOnly НЕ стирає child raw override (ArchiveUpload лишається true, лише Effective зміниться)' `
    "ArchiveUpload Raw=$($configuratorPresetChildSetting[0].OverrideValue)"

# Y: Current/Manual — no-op, жодне override-значення не змінюється
# (порівняння за вмістом, не за object reference — PowerShell типізоване
# [array]-параметр-зв'язування не гарантує той самий фізичний масив).
$configuratorPresetCurrent = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'Current'
$configuratorPresetCurrentConsole = @($configuratorPresetCurrent | Where-Object { $_.Path -eq 'consoleSettings.ConsoleLevel' })
$configuratorPresetCurrentSftp = @($configuratorPresetCurrent | Where-Object { $_.Path -eq 'componentSettings.SFTP.Enabled' })
Test-BRAVOCondition (
    $configuratorPresetCurrent.Count -eq $configuratorPresetBaseModel.Count -and
    [string]$configuratorPresetCurrentConsole[0].OverrideValue -eq 'ERROR' -and
    -not $configuratorPresetCurrentSftp[0].OverridePresent
) `
    'Configurator Presets: Current — no-op (жодне override-значення не змінюється)' `
    "Count=$($configuratorPresetCurrent.Count)/$($configuratorPresetBaseModel.Count) Console=$($configuratorPresetCurrentConsole[0].OverrideValue) SftpOverridePresent=$($configuratorPresetCurrentSftp[0].OverridePresent)"

# ===== feat/bravo-configurator-preset-baza-local: BAZA_*_LOCAL/BAZA_*_SFTP
# preset-контракт (§ user-approved manual acceptance follow-up, item 13) =====

# AC2: LocalOnly -> BAZA_APP_LOCAL=true, BAZA_WWW_LOCAL=true ("усі
# локальні опції увімкнено", коли SFTP/SMB глобально вимкнені).
$configuratorPresetLocalOnlyBazaAppLocal = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_LOCAL' })
$configuratorPresetLocalOnlyBazaWwwLocal = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_LOCAL' })
Test-BRAVOCondition (
    $configuratorPresetLocalOnlyBazaAppLocal.Count -eq 1 -and [bool]$configuratorPresetLocalOnlyBazaAppLocal[0].OverrideValue -eq $true -and
    $configuratorPresetLocalOnlyBazaWwwLocal.Count -eq 1 -and [bool]$configuratorPresetLocalOnlyBazaWwwLocal[0].OverrideValue -eq $true
) `
    'Configurator Presets: LocalOnly -> BAZA_APP_LOCAL=true, BAZA_WWW_LOCAL=true' `
    "BAZA_APP_LOCAL=$($configuratorPresetLocalOnlyBazaAppLocal[0].OverrideValue) BAZA_WWW_LOCAL=$($configuratorPresetLocalOnlyBazaWwwLocal[0].OverrideValue)"

# AC3: LocalOnly НЕ виставляє override для BAZA_*_SFTP (master і так
# вимкнений — child raw цих двох шляхів лишається незмінним/відсутнім).
$configuratorPresetLocalOnlyBazaAppSftp = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_SFTP' })
$configuratorPresetLocalOnlyBazaWwwSftp = @($configuratorPresetLocalOnly | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
Test-BRAVOCondition (
    -not $configuratorPresetLocalOnlyBazaAppSftp[0].OverridePresent -and
    -not $configuratorPresetLocalOnlyBazaWwwSftp[0].OverridePresent
) `
    'Configurator Presets: LocalOnly НЕ виставляє override для BAZA_APP_SFTP/BAZA_WWW_SFTP' `
    "AppSftpOverridePresent=$($configuratorPresetLocalOnlyBazaAppSftp[0].OverridePresent) WwwSftpOverridePresent=$($configuratorPresetLocalOnlyBazaWwwSftp[0].OverridePresent)"

# AC4: LocalPlusSMB регресія (критичний негативний тест) — застосування
# LocalPlusSMB до моделі з ПОПЕРЕДНЬО виставленими BAZA-override НЕ
# змінює їх. Немає BAZA-over-SMB transport у кодовій базі — вимкнення
# BAZA_*_LOCAL тут осиротило б BAZA без жодного каналу синхронізації.
$configuratorPresetSmbBazaBase = Set-BRAVOConfiguratorOverride -Model $configuratorPresetBaseModel -Path 'componentSettings.Synchronization.BAZA_APP_LOCAL' -Value $true
$configuratorPresetSmbBazaBase = Set-BRAVOConfiguratorOverride -Model $configuratorPresetSmbBazaBase -Path 'componentSettings.Synchronization.BAZA_WWW_SFTP' -Value $true
$configuratorPresetLocalPlusSmb = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetSmbBazaBase -PresetName 'LocalPlusSMB'
$configuratorPresetLocalPlusSmbBazaAppLocal = @($configuratorPresetLocalPlusSmb | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_LOCAL' })
$configuratorPresetLocalPlusSmbBazaWwwSftp = @($configuratorPresetLocalPlusSmb | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
Test-BRAVOCondition (
    [bool]$configuratorPresetLocalPlusSmbBazaAppLocal[0].OverrideValue -eq $true -and
    [bool]$configuratorPresetLocalPlusSmbBazaWwwSftp[0].OverrideValue -eq $true
) `
    'Configurator Presets: LocalPlusSMB НЕ змінює раніше виставлені BAZA-overrides (немає BAZA-over-SMB каналу)' `
    "BAZA_APP_LOCAL=$($configuratorPresetLocalPlusSmbBazaAppLocal[0].OverrideValue) BAZA_WWW_SFTP=$($configuratorPresetLocalPlusSmbBazaWwwSftp[0].OverrideValue)"

# AC5: LocalPlusSFTP / LocalPlusSFTPAndSMB -> BAZA_APP_LOCAL=false,
# BAZA_APP_SFTP=true, BAZA_WWW_LOCAL=false, BAZA_WWW_SFTP=true.
# BAZA_WWW_SFTP форсується true РАЗОМ з BAZA_WWW_LOCAL=false навмисно
# (schema default BAZA_WWW_SFTP=$false, "вмикайте свідомо" — без цього
# форсування WWW-компонент лишився б без жодного каналу синхронізації).
foreach ($bazaPresetName in @('LocalPlusSFTP', 'LocalPlusSFTPAndSMB')) {
    $configuratorPresetBazaResult = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName $bazaPresetName
    $bazaAppLocal = @($configuratorPresetBazaResult | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_LOCAL' })
    $bazaAppSftp  = @($configuratorPresetBazaResult | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_SFTP' })
    $bazaWwwLocal = @($configuratorPresetBazaResult | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_LOCAL' })
    $bazaWwwSftp  = @($configuratorPresetBazaResult | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
    Test-BRAVOCondition (
        [bool]$bazaAppLocal[0].OverrideValue -eq $false -and [bool]$bazaAppSftp[0].OverrideValue -eq $true -and
        [bool]$bazaWwwLocal[0].OverrideValue -eq $false -and [bool]$bazaWwwSftp[0].OverrideValue -eq $true
    ) `
        "Configurator Presets: $bazaPresetName -> BAZA_APP_LOCAL=false, BAZA_APP_SFTP=true, BAZA_WWW_LOCAL=false, BAZA_WWW_SFTP=true" `
        "AppLocal=$($bazaAppLocal[0].OverrideValue) AppSftp=$($bazaAppSftp[0].OverrideValue) WwwLocal=$($bazaWwwLocal[0].OverrideValue) WwwSftp=$($bazaWwwSftp[0].OverrideValue)"
}

# AC6: ідемпотентність — той самий патерн, що тест W, тепер для BAZA-шляхів.
$configuratorPresetLocalOnlyTwiceBaza = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetLocalOnly -PresetName 'LocalOnly'
$configuratorPresetLocalOnlyTwiceBazaAppLocal = @($configuratorPresetLocalOnlyTwiceBaza | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_APP_LOCAL' })
$configuratorPresetLocalOnlyTwiceBazaWwwLocal = @($configuratorPresetLocalOnlyTwiceBaza | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_LOCAL' })
Test-BRAVOCondition (
    [bool]$configuratorPresetLocalOnlyTwiceBazaAppLocal[0].OverrideValue -eq $true -and
    [bool]$configuratorPresetLocalOnlyTwiceBazaWwwLocal[0].OverrideValue -eq $true
) `
    'Configurator Presets: повторне застосування LocalOnly — ідемпотентне і для BAZA_*_LOCAL' `
    "BAZA_APP_LOCAL=$($configuratorPresetLocalOnlyTwiceBazaAppLocal[0].OverrideValue) BAZA_WWW_LOCAL=$($configuratorPresetLocalOnlyTwiceBazaWwwLocal[0].OverrideValue)"

$configuratorPresetSftpBothTwiceBaza = Invoke-BRAVOConfiguratorPreset -Model (Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'LocalPlusSFTPAndSMB') -PresetName 'LocalPlusSFTPAndSMB'
$configuratorPresetSftpBothTwiceBazaWwwSftp = @($configuratorPresetSftpBothTwiceBaza | Where-Object { $_.Path -eq 'componentSettings.Synchronization.BAZA_WWW_SFTP' })
Test-BRAVOCondition ([bool]$configuratorPresetSftpBothTwiceBazaWwwSftp[0].OverrideValue -eq $true) `
    'Configurator Presets: повторне застосування LocalPlusSFTPAndSMB — ідемпотентне для BAZA_WWW_SFTP' `
    "BAZA_WWW_SFTP=$($configuratorPresetSftpBothTwiceBazaWwwSftp[0].OverrideValue)"

# ===== P1.8 Preview: семантичний diff =====

$configuratorPreviewBefore = Update-BRAVOConfiguratorEffective -Model $configuratorPresetBaseModel -RuntimeRoot $configuratorFixtureRuntimeRoot
$configuratorPresetForPreview = Invoke-BRAVOConfiguratorPreset -Model $configuratorPresetBaseModel -PresetName 'LocalOnly'
$configuratorPreviewAfter = Update-BRAVOConfiguratorEffective -Model $configuratorPresetForPreview -RuntimeRoot $configuratorFixtureRuntimeRoot
$configuratorPreviewResult = Get-BRAVOConfiguratorPreview -ModelBefore $configuratorPreviewBefore -ModelAfter $configuratorPreviewAfter

# Z: Raw diff містить рівно 4 зміни для LocalOnly (2 master-switch +
# BAZA_APP_LOCAL/BAZA_WWW_LOCAL — feat/bravo-configurator-preset-baza-local).
$configuratorPreviewRawPaths = @($configuratorPreviewResult.RawChanges | ForEach-Object { $_.Path } | Sort-Object)
Test-BRAVOCondition (@(Compare-Object $configuratorPreviewRawPaths @(
    'componentSettings.SFTP.Enabled',
    'componentSettings.SMB.Enabled',
    'componentSettings.Synchronization.BAZA_APP_LOCAL',
    'componentSettings.Synchronization.BAZA_WWW_LOCAL'
)).Count -eq 0) `
    'Configurator Preview: Raw diff = рівно 4 зміни для LocalOnly (2 master-switch + 2 BAZA_*_LOCAL)' `
    "RawChanges=$($configuratorPreviewRawPaths -join ',')"

# AA: Effective diff НЕ порожній (SFTP/SMB вимкнення реально змінює
# ефективну поведінку принаймні одного залежного поля).
Test-BRAVOCondition ($configuratorPreviewResult.EffectiveChanges.Count -gt 0) `
    'Configurator Preview: Effective diff непорожній для LocalOnly preset' `
    "EffectiveChanges=$($configuratorPreviewResult.EffectiveChanges.Count)"

# AB: HasBlockingErrors коректно відображає чисту (без ERROR) модель.
Test-BRAVOCondition (-not $configuratorPreviewResult.HasBlockingErrors) `
    'Configurator Preview: HasBlockingErrors=false для валідної LocalOnly-моделі' `
    "HasBlockingErrors=$($configuratorPreviewResult.HasBlockingErrors)"

# AC: Preview без реальних змін (той самий Before/After) -> HasChanges=false.
$configuratorPreviewNoChangeResult = Get-BRAVOConfiguratorPreview -ModelBefore $configuratorPreviewBefore -ModelAfter $configuratorPreviewBefore
Test-BRAVOCondition (-not $configuratorPreviewNoChangeResult.HasChanges) `
    'Configurator Preview: Before==After -> HasChanges=false' `
    "HasChanges=$($configuratorPreviewNoChangeResult.HasChanges)"

# ===== P2-A.3: справжній diff-based Dirty (Test-BRAVOConfiguratorModelDirty) —
# заміна подієвого Model[].Dirty прапорця, який лишався $true назавжди
# після edit -> revert до оригіналу (P3 "phantom Dirty", P1-стабілізація). =====

$dirtyArrayPath = 'maintenanceSettings.Services.BravoDisplayName'
$dirtyStringPath = 'consoleSettings.ConsoleLevel'

# AD: чиста модель без overrides проти порожнього baseline -> Dirty=false
$dirtyModelClean = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides @{}
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelClean -BaselineOverrides @{})) `
    'Configurator Dirty: чиста модель проти порожнього baseline -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelClean -BaselineOverrides @{})"

# AE: edit -> Dirty=true
$dirtyModelEdited = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyStringPath -Value 'ERROR'
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelEdited -BaselineOverrides @{}) `
    'Configurator Dirty: edit -> true' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelEdited -BaselineOverrides @{})"

# AF: edit -> revert (Clear, повертає до "без override", яким і був baseline) -> Dirty=false
$dirtyModelReverted = Clear-BRAVOConfiguratorOverride -Model $dirtyModelEdited -Path $dirtyStringPath
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelReverted -BaselineOverrides @{})) `
    'Configurator Dirty: edit -> revert (Clear) до оригіналу -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelReverted -BaselineOverrides @{})"

# AG: edit значенням, рівним поточному Default, все одно Dirty=true, якщо
# baseline не мав override (OverridePresent сам по собі — частина diff,
# не лише значення) — "false override" != "absent override".
$dirtyDefaultConsoleLevel = ($dirtyModelClean | Where-Object { $_.Path -eq $dirtyStringPath })[0].DefaultValue
$dirtyModelSameAsDefault = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyStringPath -Value $dirtyDefaultConsoleLevel
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelSameAsDefault -BaselineOverrides @{}) `
    'Configurator Dirty: явний override == Default value, але baseline не мав override -> true (OverridePresent частина diff)' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelSameAsDefault -BaselineOverrides @{}) OverrideValue=$dirtyDefaultConsoleLevel Default=$dirtyDefaultConsoleLevel"

# AH: baseline МАВ override -> модель побудована з нього -> false; Clear -> true
# ("clear override" != "absent baseline" — реальна зміна, якщо baseline був present)
$dirtyBaselineWithOverride = @{ $dirtyStringPath = 'WARN' }
$dirtyModelFromBaseline = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $dirtyBaselineWithOverride
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelFromBaseline -BaselineOverrides $dirtyBaselineWithOverride)) `
    'Configurator Dirty: модель побудована з baseline -> false (щойно Load/Reload)' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelFromBaseline -BaselineOverrides $dirtyBaselineWithOverride)"
$dirtyModelClearedFromBaseline = Clear-BRAVOConfiguratorOverride -Model $dirtyModelFromBaseline -Path $dirtyStringPath
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelClearedFromBaseline -BaselineOverrides $dirtyBaselineWithOverride) `
    'Configurator Dirty: baseline мав override, Clear прибирає його -> true' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelClearedFromBaseline -BaselineOverrides $dirtyBaselineWithOverride)"

# AI: false override != absent override (Boolean-специфічний випадок)
$dirtyBooleanPath = 'componentSettings.SFTP.ArchiveUpload'
$dirtyModelFalseOverride = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyBooleanPath -Value $false
Test-BRAVOCondition (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelFalseOverride -BaselineOverrides @{}) `
    'Configurator Dirty: явний override=false проти відсутнього baseline -> true (false != absent)' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelFalseOverride -BaselineOverrides @{})"

# AJ: масив — той самий порядок елементів, що baseline -> Dirty=false; інший порядок -> true
$dirtyArrayDefault = @(($dirtyModelClean | Where-Object { $_.Path -eq $dirtyArrayPath })[0].DefaultValue)
$dirtyBaselineWithArray = @{ $dirtyArrayPath = $dirtyArrayDefault }
$dirtyModelArraySameOrder = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $dirtyBaselineWithArray
Test-BRAVOCondition (-not (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelArraySameOrder -BaselineOverrides $dirtyBaselineWithArray)) `
    'Configurator Dirty: масив, той самий порядок що baseline -> false' `
    "Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelArraySameOrder -BaselineOverrides $dirtyBaselineWithArray)"
$dirtyArrayReversedList = $dirtyArrayDefault.Clone()
[array]::Reverse($dirtyArrayReversedList)
$dirtyModelArrayReordered = Set-BRAVOConfiguratorOverride -Model $dirtyModelArraySameOrder -Path $dirtyArrayPath -Value $dirtyArrayReversedList
Test-BRAVOCondition (
    ($dirtyArrayReversedList.Count -lt 2) -or (Test-BRAVOConfiguratorModelDirty -Model $dirtyModelArrayReordered -BaselineOverrides $dirtyBaselineWithArray)
) `
    'Configurator Dirty: масив з іншим порядком елементів проти baseline -> true' `
    "ArrayCount=$($dirtyArrayReversedList.Count) Dirty=$(Test-BRAVOConfiguratorModelDirty -Model $dirtyModelArrayReordered -BaselineOverrides $dirtyBaselineWithArray)"

# AK: Reset-BRAVOConfiguratorSetting — еквівалентний Clear (Boolean повертається
# до Default, а не матеріалізується як False).
$dirtyModelForResetSetting = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyBooleanPath -Value $false
$dirtyModelAfterResetSetting = Reset-BRAVOConfiguratorSetting -Model $dirtyModelForResetSetting -Path $dirtyBooleanPath
$dirtyResetSettingRow = @($dirtyModelAfterResetSetting | Where-Object { $_.Path -eq $dirtyBooleanPath })
Test-BRAVOCondition ($dirtyResetSettingRow.Count -eq 1 -and -not [bool]$dirtyResetSettingRow[0].OverridePresent) `
    'Configurator Reset setting: Reset-BRAVOConfiguratorSetting прибирає override (Default, не False)' `
    "OverridePresent=$($dirtyResetSettingRow[0].OverridePresent)"

# AL: Reset-BRAVOConfiguratorSection — скидає лише settings ЦІЄЇ Group/Section,
# інші секції та невідомі ключі не постраждали.
$dirtyResetSectionTarget = @($dirtyModelClean | Where-Object { -not [bool]$_.Metadata.ReadOnly })[0]
$dirtyResetSectionGroup = [string]$dirtyResetSectionTarget.Metadata.Group
$dirtyResetSectionSection = [string]$dirtyResetSectionTarget.Metadata.Section
$dirtyResetSectionOtherCandidate = @($dirtyModelClean | Where-Object {
    ([string]$_.Metadata.Group -ne $dirtyResetSectionGroup -or [string]$_.Metadata.Section -ne $dirtyResetSectionSection) -and -not [bool]$_.Metadata.ReadOnly
})
$dirtyResetSectionOtherPath = if ($dirtyResetSectionOtherCandidate.Count -gt 0) { [string]$dirtyResetSectionOtherCandidate[0].Path } else { $null }
$dirtyModelBeforeSectionReset = Set-BRAVOConfiguratorOverride -Model $dirtyModelClean -Path $dirtyResetSectionTarget.Path -Value $dirtyResetSectionTarget.DefaultValue
if (-not [string]::IsNullOrWhiteSpace($dirtyResetSectionOtherPath)) {
    $otherPathDescriptor = @($dirtyModelClean | Where-Object { $_.Path -eq $dirtyResetSectionOtherPath })[0]
    $dirtyModelBeforeSectionReset = Set-BRAVOConfiguratorOverride -Model $dirtyModelBeforeSectionReset -Path $dirtyResetSectionOtherPath -Value $otherPathDescriptor.DefaultValue
}
$dirtyModelAfterSectionReset = Reset-BRAVOConfiguratorSection -Model $dirtyModelBeforeSectionReset -Group $dirtyResetSectionGroup -Section $dirtyResetSectionSection
$dirtyTargetRowAfterReset = @($dirtyModelAfterSectionReset | Where-Object { $_.Path -eq $dirtyResetSectionTarget.Path })[0]
$dirtyOtherRowAfterReset = if (-not [string]::IsNullOrWhiteSpace($dirtyResetSectionOtherPath)) {
    @($dirtyModelAfterSectionReset | Where-Object { $_.Path -eq $dirtyResetSectionOtherPath })[0]
} else { $null }
Test-BRAVOCondition (
    (-not [bool]$dirtyTargetRowAfterReset.OverridePresent) -and
    ($null -eq $dirtyOtherRowAfterReset -or [bool]$dirtyOtherRowAfterReset.OverridePresent)
) `
    'Configurator Reset section: скидає лише обрану Group/Section, інші секції не постраждали' `
    "TargetOverridePresent=$($dirtyTargetRowAfterReset.OverridePresent) OtherPath=$dirtyResetSectionOtherPath OtherOverridePresent=$($dirtyOtherRowAfterReset.OverridePresent)"

# AM: Get-BRAVOConfiguratorSessionOutcome — P2-A.4 correction. Session
# outcome оцінюється проти ПОТОЧНОГО ProductionBaseline (не первинного
# baseline сесії): Cancelled переважає над Applied, коли на момент
# закриття лишився незбережений diff проти поточного baseline.

# Test 1 — порожня сесія (baseline A, model A, жодного Apply) -> NoChanges
$outcomeBaselineA = @{ $dirtyStringPath = 'WARN' }
$outcomeModelA = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $outcomeBaselineA
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelA -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false) -eq 'NoChanges') `
    'Configurator SessionOutcome: порожня сесія -> NoChanges' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelA -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false)"

# Test 2 — edit, потім revert точно до baseline A, без Apply -> NoChanges
$outcomeModelEdited = Set-BRAVOConfiguratorOverride -Model $outcomeModelA -Path $dirtyBooleanPath -Value $true
$outcomeModelReverted = Reset-BRAVOConfiguratorSetting -Model $outcomeModelEdited -Path $dirtyBooleanPath
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelReverted -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false) -eq 'NoChanges') `
    'Configurator SessionOutcome: edit -> revert -> NoChanges' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelReverted -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false)"

# Test 3 — незбережений edit, без Apply -> Cancelled
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelEdited -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false) -eq 'Cancelled') `
    'Configurator SessionOutcome: незбережений edit -> Cancelled' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelEdited -ProductionBaseline $outcomeBaselineA -AnyApplySucceeded $false)"

# Test 4 — успішний Apply: ProductionBaseline оновлено до B, Model = B -> Applied
$outcomeBaselineB = @{ $dirtyStringPath = 'WARN'; $dirtyBooleanPath = $true }
$outcomeModelB = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorDefaultConfig -LocalOverrides $outcomeBaselineB
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelB -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true) -eq 'Applied') `
    'Configurator SessionOutcome: успішний Apply, без подальших змін -> Applied' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelB -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true)"

# Test 5 — Apply(B) відбувся, потім НОВИЙ незбережений edit (C != B) -> Cancelled
#   (regression для дефекту: AnyApplySucceeded раніше мав абсолютний
#   пріоритет і хибно приховував ці подальші незбережені зміни)
$outcomeModelC = Set-BRAVOConfiguratorOverride -Model $outcomeModelB -Path $dirtyArrayPath -Value @('changed-after-apply')
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelC -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true) -eq 'Cancelled') `
    'Configurator SessionOutcome: Apply + подальший незбережений edit -> Cancelled (не Applied)' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelC -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true)"

# Test 6 — Apply(B) відбувся, потім edit, потім revert точно до B -> Applied
$outcomeModelCReverted = Reset-BRAVOConfiguratorSetting -Model $outcomeModelC -Path $dirtyArrayPath
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelCReverted -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true) -eq 'Applied') `
    'Configurator SessionOutcome: Apply + edit -> revert до B -> Applied' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelCReverted -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $true)"

# Test 7 — Launch(A) -> зовнішня модифікація на диску -> B -> Reload
#   (ProductionBaseline і Model обидва оновлені до B) -> Close без edits
#   -> NoChanges. Це головний regression для дефекту InitialBaselineOverrides
#   (B != первинний baseline A хибно давав Cancelled).
Test-BRAVOCondition ((Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelB -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $false) -eq 'NoChanges') `
    'Configurator SessionOutcome: Reload після зовнішньої зміни, без edits -> NoChanges' `
    "Outcome=$(Get-BRAVOConfiguratorSessionOutcome -Model $outcomeModelB -ProductionBaseline $outcomeBaselineB -AnyApplySucceeded $false)"

# ===== P0 Configuration Foundation (PR C, Секція 8): Configurator без
# фізичного BRAVO.config (built-in-only + BRAVO.local.config-only шлях) —
# та сама герметична модель fixture, що вище, але БЕЗ BRAVO.config
# взагалі: LIMSRoot/BackupRoot надаються через CandidateOverrides (=
# кандидатний BRAVO.local.config, який New-BRAVOConfiguratorIsolatedConfigRoot
# і так уже пише), а не через патчений primary-шар. Доводить: (1)
# Invoke-BRAVOConfiguratorEffectiveComputation більше НЕ вимагає фізичного
# BRAVO.config (раніше — жорсткий throw); (2) DefaultValue для
# hostInformationSettings.PublicIPLookupEnabled узгоджений із дійсним
# canonical дефолтом ($true, рішення власника 2026-08-30) — не застарілим
# P1.10-текстом схеми (drift, знайдений і виправлений у Секції 8). =====
$configuratorNoConfigRuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_CONFIGURATOR_SELFTEST_NOCONFIG_{0}" -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configuratorNoConfigRuntimeRoot)
try {
    $configuratorNoConfigLimsRoot = Join-Path $configuratorNoConfigRuntimeRoot 'FIXTURE_LIMS'
    $configuratorNoConfigBackupRoot = Join-Path $configuratorNoConfigRuntimeRoot 'FIXTURE_BACKUP'
    [void][IO.Directory]::CreateDirectory($configuratorNoConfigLimsRoot)
    [void][IO.Directory]::CreateDirectory($configuratorNoConfigBackupRoot)
    Copy-Item -LiteralPath (Join-Path $root 'BRAVO_CONFIG_LOADER.ps1') -Destination (Join-Path $configuratorNoConfigRuntimeRoot 'BRAVO_CONFIG_LOADER.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $root 'VERSION.json') -Destination (Join-Path $configuratorNoConfigRuntimeRoot 'VERSION.json') -Force
    $null = cmd.exe /c mklink /J "$configuratorNoConfigRuntimeRoot\modules" "$root\modules" 2>&1
    # Свідомо НЕ копіюємо BRAVO.config — це і є предмет перевірки.
    Test-BRAVOCondition (-not (Test-Path -LiteralPath (Join-Path $configuratorNoConfigRuntimeRoot 'BRAVO.config') -PathType Leaf)) `
        'Configurator no-config fixture: BRAVO.config справді відсутній (self-test setup guard)' `
        'fixture RuntimeRoot несподівано містить BRAVO.config'

    $configuratorNoConfigDefault = $null
    $configuratorNoConfigComputationFailed = $false
    $configuratorNoConfigComputationMessage = ''
    try {
        $configuratorNoConfigDefault = Invoke-BRAVOConfiguratorEffectiveComputation `
            -RuntimeRoot $configuratorNoConfigRuntimeRoot `
            -CandidateOverrides @{
                'pathSettings.LIMSRoot' = $configuratorNoConfigLimsRoot
                'pathSettings.BackupRoot' = $configuratorNoConfigBackupRoot
            }
    } catch {
        $configuratorNoConfigComputationFailed = $true
        $configuratorNoConfigComputationMessage = $_.Exception.Message
    }
    Test-BRAVOCondition (-not $configuratorNoConfigComputationFailed) `
        'Configurator Effective: без фізичного BRAVO.config обчислення НЕ падає (built-in-only + local-only шлях)' `
        "Помилка: $configuratorNoConfigComputationMessage"

    if (-not $configuratorNoConfigComputationFailed) {
        Test-BRAVOCondition (
            [bool]$configuratorNoConfigDefault.hostInformationSettings.PublicIPLookupEnabled -eq $true
        ) `
            'Configurator no-config Default: PublicIPLookupEnabled узгоджений із canonical дефолтом ($true, рішення власника 2026-08-30, не застарілий P1.10=false)' `
            "Отримано: $($configuratorNoConfigDefault.hostInformationSettings.PublicIPLookupEnabled)"

        $configuratorNoConfigModel = Get-BRAVOConfiguratorModel -SchemaCatalog $configuratorSchemaCatalog -DefaultConfig $configuratorNoConfigDefault -LocalOverrides @{}
        $configuratorNoConfigPublicIpSetting = @($configuratorNoConfigModel | Where-Object { $_.Path -eq 'hostInformationSettings.PublicIPLookupEnabled' })
        Test-BRAVOCondition (
            $configuratorNoConfigPublicIpSetting.Count -eq 1 -and
            [bool]$configuratorNoConfigPublicIpSetting[0].DefaultValue -eq $true
        ) `
            'Configurator no-config Model: DefaultValue-колонка (не лише сирий Effective-знімок) теж узгоджена з canonical дефолтом' `
            "DefaultValue=$($configuratorNoConfigPublicIpSetting[0].DefaultValue)"
    }
} finally {
    Remove-Item -LiteralPath $configuratorNoConfigRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ===== Прибирання fixture RuntimeRoot (герметичність, див. коментар на
# початку файлу). Remove-Item на директорію-junction видаляє лише сам
# reparse point, не рекурсує в реальний modules\ репозиторію. =====
Remove-Item -LiteralPath $configuratorFixtureRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
