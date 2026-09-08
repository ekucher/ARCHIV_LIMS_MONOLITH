# BRAVO_SELF_TEST.MaintenanceOwnLog.ps1 — R3-1/R3-3 (PR #136, третє коло
# review): гарантований, ідемпотентний epilogue вивантаження власного
# логу Maintenance (Invoke-BRAVOMaintenanceOwnLogUpload) + atomic snapshot
# для range_id_log.json.
#
# Увесь top-level скрипт-файл (BRAVO_MAINTENANCE.ps1 runtime) не
# запускається тут повністю (реальні служби/VSS/BAZA) — замість цього:
# (1) справжній функціональний тест Invoke-BRAVOMaintenanceOwnLogUpload у
# ізоляції (стаб SFTP-transport), включно з ідемпотентністю й snapshot-
# TOCTOU-безпекою; (2) структурні перевірки, що підтверджують РІВНО ДВА
# call site (щасливий шлях перед AutoShutdown + зовнішній finally) — той
# самий прийом, що BRAVO_SELF_TEST.Archive.ps1 використовує для
# Invoke-BRAVOArchiveOwnLogUpload.

Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop

$maintenanceOwnLogScriptPath = Join-Path $root 'modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1'
$maintenanceOwnLogScriptText = [IO.File]::ReadAllText($maintenanceOwnLogScriptPath, [Text.Encoding]::UTF8)

# ============================================================
# Структурні перевірки (текстова інспекція production-джерела)
# ============================================================

$maintenanceOwnLogBareCallSites = @([regex]::Matches($maintenanceOwnLogScriptText, '(?m)^\s*Invoke-BRAVOMaintenanceOwnLogUpload\s*$'))
Test-BRAVOCondition ($maintenanceOwnLogBareCallSites.Count -eq 2) `
    'Maintenance/OwnLogUploadHasExactlyTwoCallSites' `
    "очікувано рівно 2 «голих» виклики Invoke-BRAVOMaintenanceOwnLogUpload (щасливий шлях + зовнішній finally); факт: $($maintenanceOwnLogBareCallSites.Count)"

# Call site №2 має бути МІЖ останнім "} finally {" файлу і фінальним
# Wait-BRAVOManualExit — тобто в ЗОВНІШНЬОМУ finally, що обгортає ввесь
# файл (а не у внутрішньому, що звільняє lock).
$maintenanceOwnLogLastFinallyIndex = $maintenanceOwnLogScriptText.LastIndexOf('} finally {')
$maintenanceOwnLogManualExitIndex = $maintenanceOwnLogScriptText.IndexOf('Wait-BRAVOManualExit', $maintenanceOwnLogLastFinallyIndex)
$maintenanceOwnLogSecondCallIndex = $maintenanceOwnLogScriptText.LastIndexOf('Invoke-BRAVOMaintenanceOwnLogUpload')
Test-BRAVOCondition (
    $maintenanceOwnLogLastFinallyIndex -ge 0 -and $maintenanceOwnLogManualExitIndex -gt $maintenanceOwnLogLastFinallyIndex -and
    $maintenanceOwnLogSecondCallIndex -gt $maintenanceOwnLogLastFinallyIndex -and $maintenanceOwnLogSecondCallIndex -lt $maintenanceOwnLogManualExitIndex
) -Name 'Maintenance/OwnLogUploadSecondCallSiteInOutermostFinallyBeforeManualExit' `
    -Failure "другий call site має бути в ЗОВНІШНЬОМУ finally, ПЕРЕД Wait-BRAVOManualExit"

# Call site №1 має передувати блоку AutoShutdown (зберігає P2-6 ordering:
# upload СТРОГО до shutdown на щасливому шляху).
$maintenanceOwnLogFirstCallIndex = $maintenanceOwnLogScriptText.IndexOf('Invoke-BRAVOMaintenanceOwnLogUpload')
$maintenanceOwnLogAutoShutdownIndex = $maintenanceOwnLogScriptText.IndexOf('ВИКЛИК ФУНКЦІЇ АВТОМАТИЧНОГО ВИМКНЕННЯ')
Test-BRAVOCondition (
    $maintenanceOwnLogFirstCallIndex -ge 0 -and $maintenanceOwnLogAutoShutdownIndex -gt $maintenanceOwnLogFirstCallIndex
) -Name 'Maintenance/OwnLogUploadFirstCallSitePrecedesAutoShutdown' `
    -Failure "перший call site (щасливий шлях) має передувати блоку AutoShutdown — зберігає вже закритий P2-6 ordering"

# Функція ніде не присвоює $script:maintenanceRuntimeExitCode — вивантаження
# власного логу НІКОЛИ не змінює первинний результат прогону.
$maintenanceOwnLogFunctionMatch = [regex]::Match($maintenanceOwnLogScriptText,
    '(?s)function Invoke-BRAVOMaintenanceOwnLogUpload \{.*?\n\}\r?\n')
Test-BRAVOCondition (
    $maintenanceOwnLogFunctionMatch.Success -and
    $maintenanceOwnLogFunctionMatch.Value -notmatch '\$script:maintenanceRuntimeExitCode\s*='
) -Name 'Maintenance/OwnLogUploadNeverAssignsRuntimeExitCode' `
    -Failure "Invoke-BRAVOMaintenanceOwnLogUpload не повинна ніде присвоювати `$script:maintenanceRuntimeExitCode"

# ============================================================
# Функціональні тести Invoke-BRAVOMaintenanceOwnLogUpload в ізоляції
# ============================================================

$maintenanceOwnLogStub = @'
function Write-Log { param([string]$Message,[string]$Level="INFO") }
function Get-BRAVOFileHash {
    param([string]$Path, [string]$Algorithm = "SHA512")
    if ($script:maintOwnLogTestState.MutateLiveFileAfterHash -and
        (Test-Path -LiteralPath $script:maintOwnLogTestState.MutateLiveFileAfterHash -PathType Leaf)) {
        [IO.File]::WriteAllText($script:maintOwnLogTestState.MutateLiveFileAfterHash, 'mutated-by-concurrent-service')
    }
    return BRAVO.Compatibility\Get-BRAVOFileHash -Path $Path -Algorithm $Algorithm
}
function Connect-BRAVOOwnLogSftpSession {
    $script:maintOwnLogTestState.ConnectCalls++
    if ($script:maintOwnLogTestState.ConnectShouldReturnNull) { return $null }
    if ($script:maintOwnLogTestState.ConnectShouldThrow) { throw "simulated connect failure" }
    return [pscustomobject]@{ IsFake = $true }
}
function Send-BRAVOOwnLogFile {
    param($Session, [string]$LocalLogPath, [string]$RemoteDirectory, [string]$RemoteFileName, $Logger)
    $script:maintOwnLogTestState.SendCalls++
    [void]$script:maintOwnLogTestState.SendCallPaths.Add($LocalLogPath)
    $content = if (Test-Path -LiteralPath $LocalLogPath -PathType Leaf) { [IO.File]::ReadAllText($LocalLogPath) } else { $null }
    [void]$script:maintOwnLogTestState.SendCallContents.Add($content)
    if ($script:maintOwnLogTestState.SendShouldThrow) { throw "simulated send failure" }
}
function Get-BRAVOSystemRangeIdLogPath {
    return $script:maintOwnLogTestState.RangeIdLogPath
}
'@
$maintenanceOwnLogFunctionNames = @("Write-Log", "Get-BRAVOFileHash", "Connect-BRAVOOwnLogSftpSession",
    "Send-BRAVOOwnLogFile", "Get-BRAVOSystemRangeIdLogPath", "Invoke-BRAVOMaintenanceOwnLogUpload")
$maintenanceOwnLogCombinedSource = $maintenanceOwnLogStub + "`n" + $maintenanceOwnLogScriptText
$maintenanceOwnLogModule = New-BRAVOSelfTestRuntimeModule -SourceText $maintenanceOwnLogCombinedSource -FunctionNames $maintenanceOwnLogFunctionNames

$maintenanceOwnLogTestRoot = Join-Path $env:TEMP "BRAVOSelfTest_MaintenanceOwnLog_$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $maintenanceOwnLogTestRoot -Force)
$maintenanceOwnLogFile = Join-Path $maintenanceOwnLogTestRoot 'run.log'
[IO.File]::WriteAllText($maintenanceOwnLogFile, 'maintenance log contents')

function Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario {
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [bool]$Enabled = $true,
        [bool]$SftpEnabled = $true,
        [bool]$DefineConfig = $true,
        [string]$LogFilePath,
        [string]$RangeIdLogPath = '',
        [string]$MutateLiveFileAfterHash = '',
        [bool]$ConnectShouldReturnNull = $false,
        [bool]$ConnectShouldThrow = $false,
        [bool]$SendShouldThrow = $false,
        [int]$InvokeTimes = 1
    )
    & $Module {
        param($enabled, $sftpEnabled, $defineConfig, $logFilePath, $rangeIdLogPath,
            $mutateLiveFileAfterHash, $connectShouldReturnNull, $connectShouldThrow, $sendShouldThrow, $invokeTimes)
        $script:maintOwnLogTestState = [pscustomobject]@{
            ConnectCalls             = 0
            SendCalls                = 0
            SendCallPaths            = (New-Object System.Collections.Generic.List[string])
            SendCallContents         = (New-Object System.Collections.Generic.List[object])
            RangeIdLogPath           = $rangeIdLogPath
            MutateLiveFileAfterHash  = $mutateLiveFileAfterHash
            ConnectShouldReturnNull  = $connectShouldReturnNull
            ConnectShouldThrow       = $connectShouldThrow
            SendShouldThrow          = $sendShouldThrow
        }
        if ($defineConfig) {
            # Той самий Global-scope контракт, що Complete-BRAVOConfigurationLoad
            # реально використовує (R3-1 mirrors P1-fix для Archive).
            $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ MaintenanceLogUploadEnabled = $enabled } }
            $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $sftpEnabled } }
            $script:sftpDirectories = [pscustomobject]@{ MaintenanceLog = 'logs/maintenance' }
            $script:LOG_FILE = $logFilePath
            $script:maintenanceLogRunId = 'selftest_run_id'
        } else {
            Remove-Variable -Name componentSettings -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name storageEffective -Scope Global -ErrorAction SilentlyContinue
        }
        $script:maintenanceOwnLogUploadAttempted = $false
        for ($i = 0; $i -lt $invokeTimes; $i++) {
            Invoke-BRAVOMaintenanceOwnLogUpload
        }
        # ПРИМІТКА (PS 5.1): @(List[object]) кидає "Argument types do not
        # match" для System.Collections.Generic.List[object] (навіть
        # непорожнього) — відомий квирк унарного @()-оператора для
        # object-типізованих generic-колекцій під Windows PowerShell 5.1.
        # .ToArray() — безпечний канонічний спосіб розгортання тут.
        [pscustomobject]@{
            ConnectCalls     = $script:maintOwnLogTestState.ConnectCalls
            SendCalls        = $script:maintOwnLogTestState.SendCalls
            SendCallPaths    = $script:maintOwnLogTestState.SendCallPaths.ToArray()
            SendCallContents = $script:maintOwnLogTestState.SendCallContents.ToArray()
        }
    } $Enabled $SftpEnabled $DefineConfig $LogFilePath $RangeIdLogPath `
        $MutateLiveFileAfterHash $ConnectShouldReturnNull $ConnectShouldThrow $SendShouldThrow $InvokeTimes
}

# (a) Тумблер вимкнений (дефолт) -> 0 спроб вивантаження.
$maintOwnLogDisabled = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $false -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogDisabled.ConnectCalls -eq 0 -and $maintOwnLogDisabled.SendCalls -eq 0
) -Name 'Maintenance/OwnLogUploadDisabledMakesZeroAttempts' `
    -Failure "MaintenanceLogUploadEnabled=`$false має пропускати вивантаження без жодної спроби; факт: connect=$($maintOwnLogDisabled.ConnectCalls) send=$($maintOwnLogDisabled.SendCalls)"

# (b) Увімкнено, БЕЗ range_id_log.json -> рівно 1 спроба (лише основний лог).
$maintOwnLogEnabledNoRangeId = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogEnabledNoRangeId.ConnectCalls -eq 1 -and $maintOwnLogEnabledNoRangeId.SendCalls -eq 1
) -Name 'Maintenance/OwnLogUploadEnabledWithoutRangeIdMakesExactlyOneAttempt' `
    -Failure "увімкнено, без range_id_log.json -> рівно 1 передача (основний лог); факт: connect=$($maintOwnLogEnabledNoRangeId.ConnectCalls) send=$($maintOwnLogEnabledNoRangeId.SendCalls)"

# (c) Крах ДО завантаження конфігурації -> тихий no-op, БЕЗ винятку.
$maintOwnLogNoConfig = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -DefineConfig $false -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogNoConfig.ConnectCalls -eq 0 -and $maintOwnLogNoConfig.SendCalls -eq 0
) -Name 'Maintenance/OwnLogUploadMissingConfigIsSilentNoOpNotThrow' `
    -Failure "крах до завантаження конфігурації не повинен кидати виняток назовні"

# (d) Transport кидає виняток -> best-effort, не пробрасывает далі.
$maintOwnLogSendFails = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -SendShouldThrow $true -LogFilePath $maintenanceOwnLogFile
Test-BRAVOCondition (
    $maintOwnLogSendFails.SendCalls -eq 1
) -Name 'Maintenance/OwnLogUploadTransportFailureCaughtNotPropagated' `
    -Failure "провал передачі не повинен кидати виняток назовні; факт: send=$($maintOwnLogSendFails.SendCalls)"

# (e) R3-1: ідемпотентність — виклик функції ДВІЧІ в одному прогоні (симулює
# call site №1 + call site №2 на щасливому шляху) -> лише ОДНА реальна спроба.
$maintOwnLogIdempotent = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule -Enabled $true -LogFilePath $maintenanceOwnLogFile -InvokeTimes 2
Test-BRAVOCondition (
    $maintOwnLogIdempotent.ConnectCalls -eq 1 -and $maintOwnLogIdempotent.SendCalls -eq 1
) -Name 'Maintenance/OwnLogUploadIdempotentAcrossTwoCallSites' `
    -Failure "виклик двічі (call site №1 + №2) має дати РІВНО одну реальну спробу; факт: connect=$($maintOwnLogIdempotent.ConnectCalls) send=$($maintOwnLogIdempotent.SendCalls)"

# (f) R3-3: snapshot — range_id_log.json вивантажується ЗІ SNAPSHOT-шляху,
# НЕ з живого шляху, і знімок прибирається після завершення.
$maintOwnLogRangeIdFile = Join-Path $maintenanceOwnLogTestRoot 'range_id_log.json'
[IO.File]::WriteAllText($maintOwnLogRangeIdFile, 'original-range-id-content')
$maintOwnLogSnapshotResult = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule `
    -Enabled $true -LogFilePath $maintenanceOwnLogFile -RangeIdLogPath $maintOwnLogRangeIdFile
Test-BRAVOCondition (
    $maintOwnLogSnapshotResult.SendCalls -eq 2 -and
    $maintOwnLogSnapshotResult.SendCallPaths[1] -ne $maintOwnLogRangeIdFile -and
    -not (Test-Path -LiteralPath $maintOwnLogSnapshotResult.SendCallPaths[1])
) -Name 'Maintenance/OwnLogUploadRangeIdSnapshotUsesTemporaryCopyAndCleansUp' `
    -Failure "range_id_log.json має вивантажуватись ЗІ SNAPSHOT-шляху (не з живого), і знімок має бути прибраний після; факт: sendCalls=$($maintOwnLogSnapshotResult.SendCalls) snapshotPath=$($maintOwnLogSnapshotResult.SendCallPaths[1]) stillExists=$(Test-Path -LiteralPath $maintOwnLogSnapshotResult.SendCallPaths[1])"

# (g) R3-3 (найважливіший тест, буквальна вимога review): живий
# range_id_log.json МІНЯЄТЬСЯ між моментом снімку і фактичною передачею
# (симулює конкурентний запис служби BRAVO) -> вивантажений вміст
# лишається ОРИГІНАЛЬНИМ (снятим ДО мутації), а не пошкодженим/змішаним.
[IO.File]::WriteAllText($maintOwnLogRangeIdFile, 'original-range-id-content')
$maintOwnLogRaceResult = Invoke-BRAVOSelfTestMaintenanceOwnLogUploadScenario -Module $maintenanceOwnLogModule `
    -Enabled $true -LogFilePath $maintenanceOwnLogFile -RangeIdLogPath $maintOwnLogRangeIdFile `
    -MutateLiveFileAfterHash $maintOwnLogRangeIdFile
$maintOwnLogLiveContentAfter = [IO.File]::ReadAllText($maintOwnLogRangeIdFile)
Test-BRAVOCondition (
    $maintOwnLogRaceResult.SendCalls -eq 2 -and
    [string]$maintOwnLogRaceResult.SendCallContents[1] -eq 'original-range-id-content' -and
    $maintOwnLogLiveContentAfter -eq 'mutated-by-concurrent-service'
) -Name 'Maintenance/OwnLogUploadRangeIdSnapshotSurvivesConcurrentLiveFileMutation' `
    -Failure "живий файл змінився ПІСЛЯ снімку (симуляція служби BRAVO) — вивантажений вміст має лишитись ОРИГІНАЛЬНИМ (знятим до мутації); факт: sendCalls=$($maintOwnLogRaceResult.SendCalls) uploadedContent='$([string]$maintOwnLogRaceResult.SendCallContents[1])' liveContentAfter='$maintOwnLogLiveContentAfter'"

Remove-Item -LiteralPath $maintenanceOwnLogTestRoot -Recurse -Force -ErrorAction SilentlyContinue
