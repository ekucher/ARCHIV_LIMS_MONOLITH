# BRAVO_SELF_TEST.Archive.ps1 — BRAVO.Archive.Runtime.ps1 (P2-1/P2-5, PR
# #136 review): рекурсивне впорядкування SFTP-каталогів перед mkdir і
# єдиний call site вивантаження власного логу (успіх / контрольований
# ранній return / фатальний крах / вимкнена опція).
#
# Main() — це вся orchestration-функція BRAVO_ARCHIV (реальний backup,
# VSS, BAZA-синхронізація тощо) і не запускається тут повністю: замість
# цього нижче — (1) справжній функціональний тест чистої функції
# впорядкування каталогів, (2) справжній функціональний тест
# Invoke-BRAVOArchiveOwnLogUpload у ізоляції (стаб SFTP-transport), і
# (3) структурні перевірки, що підтверджують РІВНО ОДИН call site в
# `finally` (а не в хвості Main()/catch) — так само, як інші domain-
# фрагменти цього self-test-у роблять для контрактів, які нереально
# відтворити без повного продакшн-оточення.

$archiveScriptPath = Join-Path $root 'modules\BRAVO.Archive\BRAVO.Archive.Runtime.ps1'
$archiveScriptText = [IO.File]::ReadAllText($archiveScriptPath, [Text.Encoding]::UTF8)

# ============================================================
# P2-1: Get-BRAVOSFTPOrderedDirectorySegments — чисте розгортання у
# батьківські сегменти + впорядкування за глибиною (WinSCP mkdir не
# рекурсивний).
# ============================================================

$archiveOrderingModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText $archiveScriptText `
    -FunctionNames @("Get-BRAVOSFTPOrderedDirectorySegments")

# 1) Один вкладений шлях: /logs має йти ПЕРЕД /logs/archiv.
$archiveOrderSingle = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('/logs/archiv'))
Test-BRAVOCondition -Condition (
    $archiveOrderSingle.Count -eq 2 -and
    $archiveOrderSingle[0] -eq '/logs' -and
    $archiveOrderSingle[1] -eq '/logs/archiv'
) -Name 'Archive/SftpDirOrderingParentBeforeChild' `
    -Failure "/logs має бути ПЕРЕД /logs/archiv; отримано: $($archiveOrderSingle -join ', ')"

# 2) Кілька вкладених сегментів: /a/b/c/d -> 4 елементи, зростаюча глибина.
$archiveOrderDeep = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('/a/b/c/d'))
Test-BRAVOCondition -Condition (
    $archiveOrderDeep.Count -eq 4 -and
    ($archiveOrderDeep -join ',') -eq '/a,/a/b,/a/b/c,/a/b/c/d'
) -Name 'Archive/SftpDirOrderingMultipleNestedSegments' `
    -Failure "усі 4 батьківські сегменти мають йти в порядку зростання глибини; отримано: $($archiveOrderDeep -join ', ')"

# 3) Кілька незалежних запитів з частково спільними сегментами —
# дедуплікація і стабільний порядок (спершу коротші, потім алфавітно).
$archiveOrderMulti = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('/logs/archiv', '/logs/model', '/logs'))
Test-BRAVOCondition -Condition (
    $archiveOrderMulti.Count -eq 3 -and
    $archiveOrderMulti[0] -eq '/logs' -and
    @($archiveOrderMulti[1], $archiveOrderMulti[2]) -contains '/logs/archiv' -and
    @($archiveOrderMulti[1], $archiveOrderMulti[2]) -contains '/logs/model'
) -Name 'Archive/SftpDirOrderingDeduplicatesSharedParent' `
    -Failure "спільний батьківський /logs має зʼявитись рівно раз і першим; отримано: $($archiveOrderMulti -join ', ')"

# 4) "Батько вже наявний" / "повний шлях уже наявний" — сама функція не
# знає про стан сервера (це відповідальність WinSCP `option batch
# continue`, нижче структурний тест на це); тут перевіряємо лише, що
# ПОВТОРНИЙ запит того самого шляху не породжує дублікатів у списку.
$archiveOrderRepeat = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('/logs', '/logs', '/logs/archiv'))
Test-BRAVOCondition -Condition (
    $archiveOrderRepeat.Count -eq 2
) -Name 'Archive/SftpDirOrderingIdempotentOnRepeatedPath' `
    -Failure "повторний запит уже присутнього каталогу не повинен дублювати сегмент; отримано: $($archiveOrderRepeat -join ', ')"

# 5) Порожній/whitespace вхід ігнорується без винятку.
$archiveOrderEmpty = @(& $archiveOrderingModule { param($d) Get-BRAVOSFTPOrderedDirectorySegments -Directories $d } @('', '  ', $null))
Test-BRAVOCondition -Condition (
    $archiveOrderEmpty.Count -eq 0
) -Name 'Archive/SftpDirOrderingIgnoresBlankInput' `
    -Failure "порожні/blank запити не повинні породжувати сегменти; отримано: $($archiveOrderEmpty -join ', ')"

# ============================================================
# P2-1 (структурні): "проміжний mkdir провалився"/"batch continue" і
# host-key pinning не послаблені. Реальний провал одного mkdir у
# середині пакетного WinSCP-скрипта без живого SFTP-сервера
# невідтворюваний детерміновано в self-test — контракт, що такий провал
# НЕ зупиняє решту пакета (а сама передача даних усе одно перевіряється
# окремо після), гарантує саме "option batch continue" перед mkdir-
# командами; це вже наявна поведінка (не змінена цим PR) — тест фіксує
# контракт, а не додає нову.
# ============================================================

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '(?s)option batch continue\r?\noption confirm off\r?\nopen \$RepositorySFTPUrl -hostkey=\$HostKey.*?\$mkdirCommands'
) -Name 'Archive/SftpMkdirBatchContinuesPastIntermediateFailure' `
    -Failure "'option batch continue' має передувати mkdir-командам, щоб провал одного сегмента (уже наявний/проміжний) не зупиняв решту пакета"

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '-hostkey=\$HostKey' -and
    $archiveScriptText -notmatch '(?i)accept.?any.?host.?key|AcceptAny|-hostkey=\*'
) -Name 'Archive/SftpMkdirPreservesHostKeyPinning' `
    -Failure "рекурсивне створення каталогів не повинно послаблювати обов'язкове SSH host-key pinning"

# ============================================================
# P2-5: Invoke-BRAVOArchiveOwnLogUpload — функціональна ізоляція
# (тумблер/відсутня конфігурація/помилка transport), плюс структурні
# перевірки єдиного call site.
# ============================================================

$archiveOwnLogStub = @'
function Write-BRAVOLog { param([string]$Component, [string]$Message, [string]$Level = "INFO") }
function Initialize-BRAVOSFTPRemoteDirectories {
    param([string]$WinSCPPath, [string]$RepositorySFTPUrl, [string]$HostKey, [string[]]$RemoteDirectories)
    $script:archiveOwnLogTestState.InitDirCalls++
}
function Send-FileViaWinSCP {
    param([string]$WinSCPPath, [string]$RepositorySFTPUrl, [string]$HostKey, [string]$LocalFilePath, [string]$RemoteDirectory)
    $script:archiveOwnLogTestState.SendCalls++
    if ($script:archiveOwnLogTestState.SendShouldThrow) {
        throw "simulated SFTP transport failure"
    }
    return $script:archiveOwnLogTestState.SendReturnValue
}
'@
$archiveOwnLogFunctionNames = @("Write-BRAVOLog", "Initialize-BRAVOSFTPRemoteDirectories", "Send-FileViaWinSCP", "Invoke-BRAVOArchiveOwnLogUpload")
$archiveOwnLogCombinedSource = $archiveOwnLogStub + "`n" + $archiveScriptText
$archiveOwnLogModule = New-BRAVOSelfTestRuntimeModule -SourceText $archiveOwnLogCombinedSource -FunctionNames $archiveOwnLogFunctionNames

$archiveOwnLogTestRoot = Join-Path $env:TEMP "BRAVOSelfTest_ArchiveOwnLog_$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $archiveOwnLogTestRoot -Force)
$archiveOwnLogFile = Join-Path $archiveOwnLogTestRoot 'run.log'
[IO.File]::WriteAllText($archiveOwnLogFile, 'log contents')

function Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario {
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [bool]$Enabled = $true,
        [bool]$SftpEnabled = $true,
        [bool]$DefineConfig = $true,
        [bool]$SendShouldThrow = $false,
        [bool]$SendReturnValue = $true,
        [string]$LogFilePath
    )
    & $Module {
        param($enabled, $sftpEnabled, $defineConfig, $sendShouldThrow, $sendReturnValue, $logFilePath)
        $script:archiveOwnLogTestState = [pscustomobject]@{
            InitDirCalls    = 0
            SendCalls       = 0
            SendShouldThrow = $sendShouldThrow
            SendReturnValue = $sendReturnValue
        }
        if ($defineConfig) {
            # P1 (PR #136 review, r3943997859): у реальному прогоні
            # Complete-BRAVOConfigurationLoad проєктує componentSettings/
            # storageEffective ЛИШЕ у $global: (ніколи у script-scope) —
            # фікстура повинна відтворювати саме це, інакше тест мовчки
            # перевіряв код, якого немає в production.
            $global:componentSettings = [pscustomobject]@{ SFTP = [pscustomobject]@{ ArchiveLogUploadEnabled = $enabled } }
            $global:storageEffective = [pscustomobject]@{ SFTP = [pscustomobject]@{ Enabled = $sftpEnabled } }
            $script:sftpUrl = 'sftp://selftest@127.0.0.1/'
            $script:sftpHostKey = 'ssh-rsa 2048 aa:bb:cc'
            $script:winSCPPath = 'C:\Windows\System32\cmd.exe'
            $script:sftpDirectories = [pscustomobject]@{ ArchivLog = 'logs/archiv' }
            $script:logFile = $logFilePath
        } else {
            Remove-Variable -Name componentSettings -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name storageEffective -Scope Global -ErrorAction SilentlyContinue
        }
        $script:processExitCodeBefore = 42
        $script:processExitCode = 42
        Invoke-BRAVOArchiveOwnLogUpload
        [pscustomobject]@{
            InitDirCalls      = $script:archiveOwnLogTestState.InitDirCalls
            SendCalls         = $script:archiveOwnLogTestState.SendCalls
            ProcessExitCode   = $script:processExitCode
        }
    } $Enabled $SftpEnabled $DefineConfig $SendShouldThrow $SendReturnValue $LogFilePath
}

# (a) Тумблер вимкнений (дефолт) -> 0 спроб вивантаження.
$archiveOwnLogDisabled = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -Enabled $false -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogDisabled.InitDirCalls -eq 0 -and
    $archiveOwnLogDisabled.SendCalls -eq 0
) -Name 'Archive/OwnLogUploadDisabledMakesZeroAttempts' `
    -Failure "ArchiveLogUploadEnabled=`$false має пропускати вивантаження без жодної спроби; факт: init=$($archiveOwnLogDisabled.InitDirCalls) send=$($archiveOwnLogDisabled.SendCalls)"

# (b) Тумблер увімкнений, повна конфігурація -> рівно 1 спроба вивантаження.
$archiveOwnLogEnabled = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -Enabled $true -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogEnabled.InitDirCalls -eq 1 -and
    $archiveOwnLogEnabled.SendCalls -eq 1
) -Name 'Archive/OwnLogUploadEnabledMakesExactlyOneAttempt' `
    -Failure "ArchiveLogUploadEnabled=`$true з повною конфігурацією має вивантажити РІВНО ОДИН раз; факт: init=$($archiveOwnLogEnabled.InitDirCalls) send=$($archiveOwnLogEnabled.SendCalls)"

# (c) Найранніший крах — componentSettings/storageEffective ще не існують
# (симулює крах ДО завантаження конфігурації) -> тихий no-op, БЕЗ винятку.
$archiveOwnLogNoConfig = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -DefineConfig $false -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogNoConfig.InitDirCalls -eq 0 -and
    $archiveOwnLogNoConfig.SendCalls -eq 0
) -Name 'Archive/OwnLogUploadMissingConfigIsSilentNoOpNotThrow' `
    -Failure "крах до завантаження конфігурації не повинен кидати виняток назовні — має трактуватись як 'нічого вивантажувати'"

# (d) Transport кидає виняток -> best-effort: не кидає далі,
# $script:processExitCode лишається незмінним (телеметрія власного логу
# ніколи не змінює первинний результат прогону).
$archiveOwnLogSendFails = Invoke-BRAVOSelfTestArchiveOwnLogUploadScenario -Module $archiveOwnLogModule -Enabled $true -SendShouldThrow $true -LogFilePath $archiveOwnLogFile
Test-BRAVOCondition -Condition (
    $archiveOwnLogSendFails.SendCalls -eq 1 -and
    $archiveOwnLogSendFails.ProcessExitCode -eq 42
) -Name 'Archive/OwnLogUploadTransportFailureNeverChangesExitCode' `
    -Failure "збій transport під час вивантаження власного логу не повинен змінювати `$script:processExitCode (первинний результат прогону); факт: exitCode=$($archiveOwnLogSendFails.ProcessExitCode)"

Remove-Item -LiteralPath $archiveOwnLogTestRoot -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# P2-5 (структурні): РІВНО ОДИН call site — у зовнішньому `finally`, а
# НЕ в хвості Main() і НЕ в catch. Це саме контракт, який покриває
# сценарії "успіх", "контрольований ранній return" (Main має 5 таких
# return, кожен з власним footer/summary ПЕРЕД return) і "фатальний
# крах" — з чистого тексту функції їх не відрізнити без повного
# продакшн-запуску Main(), тому перевіряється структурно.
# ============================================================

$archiveMainBodyMatch = [Text.RegularExpressions.Regex]::Match(
    $archiveScriptText, '(?s)^function Main \{.*?\n\}\r?\n', [Text.RegularExpressions.RegexOptions]::Multiline)
Test-BRAVOCondition -Condition (
    $archiveMainBodyMatch.Success -and
    ($archiveMainBodyMatch.Value -notmatch 'Invoke-BRAVOArchiveOwnLogUpload')
) -Name 'Archive/OwnLogUploadNotCalledFromMainTail' `
    -Failure "хвіст Main() НЕ повинен містити прямий виклик Invoke-BRAVOArchiveOwnLogUpload — інакше 5 контрольованих ранніх return усередині Main() пропускали б вивантаження логу"

# НЕ через lazy regex '\} catch \{.*?' від початку файлу: Invoke-
# BRAVOArchiveOwnLogUpload сам містить кілька "} catch {" (власні
# ізольовані try/catch) розташовані РАНІШЕ у файлі, ніж реальний
# фатальний catch у хвості скрипта — lazy-квантифікатор захоплював би
# ВЕСЬ текст від першого-ліпшого "} catch {" аж до реального "} finally
# {", неминуче поглинаючи саме визначення Invoke-BRAVOArchiveOwnLogUpload
# і даючи хибний FAIL. Натомість шукаємо унікальний маркер реального
# фатального catch ($fatalErrorRecord = $_, зустрічається рівно раз).
$archiveFatalCatchStartIndex = $archiveScriptText.IndexOf('$fatalErrorRecord = $_')
$archiveFatalCatchFinallyIndex = if ($archiveFatalCatchStartIndex -ge 0) {
    $archiveScriptText.IndexOf('} finally {', $archiveFatalCatchStartIndex)
} else { -1 }
$archiveFatalCatchBlockText = if ($archiveFatalCatchStartIndex -ge 0 -and $archiveFatalCatchFinallyIndex -gt $archiveFatalCatchStartIndex) {
    $archiveScriptText.Substring($archiveFatalCatchStartIndex, $archiveFatalCatchFinallyIndex - $archiveFatalCatchStartIndex)
} else { '' }
Test-BRAVOCondition -Condition (
    $archiveFatalCatchStartIndex -ge 0 -and
    $archiveFatalCatchFinallyIndex -gt $archiveFatalCatchStartIndex -and
    ($archiveFatalCatchBlockText -notmatch 'Invoke-BRAVOArchiveOwnLogUpload')
) -Name 'Archive/OwnLogUploadNotCalledFromFatalCatch' `
    -Failure "фатальний catch НЕ повинен окремо викликати Invoke-BRAVOArchiveOwnLogUpload — єдиний call site тепер у finally, інакше можливе подвійне вивантаження"

Test-BRAVOCondition -Condition (
    ([Text.RegularExpressions.Regex]::Matches($archiveScriptText, 'Invoke-BRAVOArchiveOwnLogUpload\s*$', [Text.RegularExpressions.RegexOptions]::Multiline)).Count -eq 1
) -Name 'Archive/OwnLogUploadHasExactlyOneCallSite' `
    -Failure "у всьому скрипті має бути РІВНО ОДИН виклик Invoke-BRAVOArchiveOwnLogUpload (в finally) — жодного дубльованого call site"

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '(?s)\} finally \{[^\}]*?Invoke-BRAVOArchiveOwnLogUpload'
) -Name 'Archive/OwnLogUploadCallSiteIsInFinallyBlock' `
    -Failure "єдиний call site Invoke-BRAVOArchiveOwnLogUpload має бути у finally — виконується для БУДЬ-ЯКОГО виходу з try (успіх/ранній return/необроблений виняток), рівно один раз"

Test-BRAVOCondition -Condition (
    $archiveScriptText -match '(?s)\} finally \{\s*(#[^\r\n]*\r?\n\s*)*Invoke-BRAVOArchiveOwnLogUpload\r?\n\s*if \(\$script:archiveProcessLock\)'
) -Name 'Archive/OwnLogUploadPrecedesLockDisposalInFinally' `
    -Failure "вивантаження власного логу має відбуватись ДО dispose lock-файлу/Wait-ForManualExit у finally"

Test-BRAVOCondition -Condition (
    ([Text.RegularExpressions.Regex]::Match($archiveScriptText, '(?s)function Invoke-BRAVOArchiveOwnLogUpload \{.*?\n\}\r?\n')).Value -notmatch '\$script:processExitCode\s*='
) -Name 'Archive/OwnLogUploadNeverAssignsProcessExitCode' `
    -Failure "Invoke-BRAVOArchiveOwnLogUpload — другорядний/телеметричний ефект і не повинен присвоювати `$script:processExitCode"
