# ============================================================
# R3-4 (PR #136, третє коло review): canonical SFTP-required предикат
# ============================================================
# Test-BRAVOSftpCredentialsRequired (modules\BRAVO.Configuration\
# BRAVO.Configuration.Derivation.psm1) — ЄДИНА формула "чи потрібні SFTP-
# креденшелі", яку тепер спільно викликають BRAVO_DRY_RUN.ps1 (двічі),
# BRAVO_CREDENTIALS_SETUP.ps1 (Resolve-RequestedComponents) і
# BRAVO.Configurator.Credentials.psm1 (Get-BRAVOConfiguratorCredentialRequirement).
# Реальний, вже імпортований production-модуль — жодних stub/fixture не
# потрібно, функція чиста (лише булеві параметри, без I/O).

Import-Module -Name (Join-Path $root `
    'modules\BRAVO.Configuration\BRAVO.Configuration.Derivation.psd1') -ErrorAction Stop

function Invoke-BRAVOSelfTestSftpCredentialsRequiredScenario {
    param(
        [bool]$SftpEnabled = $true,
        [bool]$ArchiveUploadEnabled = $false,
        [bool]$MaintenanceLogUploadEnabled = $false,
        [bool]$ArchiveLogUploadEnabled = $false,
        [bool]$ScheduledSftpSyncRequired = $false,
        [bool]$BackupMonitoringSftpEnabled = $false
    )
    return Test-BRAVOSftpCredentialsRequired `
        -SftpEnabled $SftpEnabled `
        -ArchiveUploadEnabled $ArchiveUploadEnabled `
        -MaintenanceLogUploadEnabled $MaintenanceLogUploadEnabled `
        -ArchiveLogUploadEnabled $ArchiveLogUploadEnabled `
        -ScheduledSftpSyncRequired $ScheduledSftpSyncRequired `
        -BackupMonitoringSftpEnabled $BackupMonitoringSftpEnabled
}

# (a) Усе вимкнено -> SFTP не потрібен.
Test-BRAVOCondition -Condition (
    (Invoke-BRAVOSelfTestSftpCredentialsRequiredScenario) -eq $false
) -Name 'SftpCredentialsRequired/AllDisabledMeansNotRequired' `
    -Failure "усі дочірні прапорці вимкнено -> SFTP не має вимагатись"

# (b) Master SFTP.Enabled=false нейтралізує геть усе, навіть якщо дочірні прапорці true.
Test-BRAVOCondition -Condition (
    (Invoke-BRAVOSelfTestSftpCredentialsRequiredScenario -SftpEnabled $false `
        -ArchiveUploadEnabled $true -MaintenanceLogUploadEnabled $true -ArchiveLogUploadEnabled $true `
        -ScheduledSftpSyncRequired $true -BackupMonitoringSftpEnabled $true) -eq $false
) -Name 'SftpCredentialsRequired/MasterDisabledOverridesAllChildFlags' `
    -Failure "SftpEnabled=`$false має нейтралізувати геть усі дочірні прапорці"

# (c) Лише ArchiveUpload -> required (пре-існуюча поведінка).
Test-BRAVOCondition -Condition (
    (Invoke-BRAVOSelfTestSftpCredentialsRequiredScenario -ArchiveUploadEnabled $true) -eq $true
) -Name 'SftpCredentialsRequired/ArchiveUploadAloneRequires' `
    -Failure "лише ArchiveUpload=`$true має вимагати SFTP"

# (d) Лише ScheduledSftpSyncRequired -> required (пре-існуюча поведінка).
Test-BRAVOCondition -Condition (
    (Invoke-BRAVOSelfTestSftpCredentialsRequiredScenario -ScheduledSftpSyncRequired $true) -eq $true
) -Name 'SftpCredentialsRequired/ScheduledSftpSyncAloneRequires' `
    -Failure "лише ScheduledSftpSyncRequired=`$true має вимагати SFTP"

# (e) Лише backupMonitoring.SFTP.Enabled -> required (пре-існуюча поведінка).
Test-BRAVOCondition -Condition (
    (Invoke-BRAVOSelfTestSftpCredentialsRequiredScenario -BackupMonitoringSftpEnabled $true) -eq $true
) -Name 'SftpCredentialsRequired/BackupMonitoringAloneRequires' `
    -Failure "лише backupMonitoring.SFTP.Enabled=`$true має вимагати SFTP"

# (f) Round-3 review сценарій: ЛИШЕ MaintenanceLogUploadEnabled -> required
# (до фіксу канонічний вираз пропускав цей тумблер повністю).
Test-BRAVOCondition -Condition (
    (Invoke-BRAVOSelfTestSftpCredentialsRequiredScenario -MaintenanceLogUploadEnabled $true) -eq $true
) -Name 'SftpCredentialsRequired/MaintenanceLogUploadAloneRequires' `
    -Failure "лише MaintenanceLogUploadEnabled=`$true (усе інше вимкнено, зокрема ArchiveUpload) МАЄ вимагати SFTP-креденшелі — саме цей сценарій пропускав старий inline-вираз"

# (g) Round-3 review сценарій: ЛИШЕ ArchiveLogUploadEnabled -> required.
Test-BRAVOCondition -Condition (
    (Invoke-BRAVOSelfTestSftpCredentialsRequiredScenario -ArchiveLogUploadEnabled $true) -eq $true
) -Name 'SftpCredentialsRequired/ArchiveLogUploadAloneRequires' `
    -Failure "лише ArchiveLogUploadEnabled=`$true (усе інше вимкнено, зокрема ArchiveUpload) МАЄ вимагати SFTP-креденшелі — саме цей сценарій пропускав старий inline-вираз"

# (h) Структурний regression-тест: усі 4 виклик-площини (BRAVO_DRY_RUN.ps1
# x2, BRAVO_CREDENTIALS_SETUP.ps1, BRAVO.Configurator.Credentials.psm1)
# дійсно викликають canonical функцію, а не власну копію виразу.
$sftpPredicateCallSiteFiles = @(
    (Join-Path $root 'BRAVO_DRY_RUN.ps1'),
    (Join-Path $root 'BRAVO_CREDENTIALS_SETUP.ps1'),
    (Join-Path $root 'modules\BRAVO.Configurator\BRAVO.Configurator.Credentials.psm1')
)
$sftpPredicateCallSiteCounts = @($sftpPredicateCallSiteFiles | ForEach-Object {
    $fileText = [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8)
    # '= Test-BRAVOSftpCredentialsRequired `' — реальний виклик з
    # backtick-продовженням; коментарі, що згадують ім'я функції
    # прозою, цього патерну не мають.
    ([regex]::Matches($fileText, '=\s*Test-BRAVOSftpCredentialsRequired\s*`')).Count
})
Test-BRAVOCondition -Condition (
    $sftpPredicateCallSiteCounts.Count -eq 3 -and
    $sftpPredicateCallSiteCounts[0] -eq 2 -and
    $sftpPredicateCallSiteCounts[1] -eq 1 -and
    $sftpPredicateCallSiteCounts[2] -eq 1
) -Name 'SftpCredentialsRequired/AllFourCallSitesUseCanonicalFunction' `
    -Failure "очікувано: BRAVO_DRY_RUN.ps1=2, BRAVO_CREDENTIALS_SETUP.ps1=1, BRAVO.Configurator.Credentials.psm1=1 виклики Test-BRAVOSftpCredentialsRequired; факт: $($sftpPredicateCallSiteCounts -join ',')"
