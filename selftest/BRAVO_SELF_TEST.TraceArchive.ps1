# Домен-фрагмент self-test: TraceArchive — накопичувальний добовий
# Trace_YYYYMMDD.mdz (модель 5.2.0): backlog за датою З ІМЕНІ, план
# New/Duplicate/Conflict, транзакційне оновлення (.work + 7z t +
# re-inventory immutability + SHA512 + атомарна публікація). Сценарії
# ганяються на СПРАВЖНЬОМУ Tools\7za.exe (шифровані архіви): семантику `7za a` в шифрований архів
# стаби підтвердити не можуть, а помилка в ній коштує trace-історії.
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.
$traceArchiveScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)

    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.ArchiveHelpers\BRAVO.ArchiveHelpers.psd1") -Force -ErrorAction Stop

    # Стаби ПЕРЕД реальним текстом: FindAll бере ПЕРШЕ визначення, тому
    # логери/алерти Runtime підмінюються тихими заглушками (задокументована
    # пастка: стаб після реального тексту не спрацював би). Форвард-стаби
    # module-qualified: попередні домени self-test авто-імпортують власні
    # заглушки цих імен у глобальну сесію (New-Module-пастка), і без
    # кваліфікації ізольований модуль підхопив би чужий фейк замість
    # канонічної реалізації Compatibility/ArchiveHelpers.
    $traceArchiveStubText = @'
function Write-Log { param($Message, [string]$Level = 'INFO') }
function Send-SlackAlert { param($Message, [switch]$IsCritical) }
function Test-SevenZipArchiveIntegrity { BRAVO.ArchiveHelpers\Test-SevenZipArchiveIntegrity @args }
function Get-BRAVOSevenZipArchiveEntries { BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries @args }
function Get-BRAVOSevenZipFileCrc { BRAVO.Compatibility\Get-BRAVOSevenZipFileCrc @args }
function Get-BRAVOSevenZipExitCodeDescription { BRAVO.Compatibility\Get-BRAVOSevenZipExitCodeDescription @args }
function Get-BRAVOFileHash { BRAVO.Compatibility\Get-BRAVOFileHash @args }
function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }
function ConvertTo-BRAVOWindowsCommandLineArgument { BRAVO.Compatibility\ConvertTo-BRAVOWindowsCommandLineArgument @args }
function Start-BRAVOProcessOutputCapture { BRAVO.Compatibility\Start-BRAVOProcessOutputCapture @args }
function Write-BRAVOProcessInputText { BRAVO.Compatibility\Write-BRAVOProcessInputText @args }
function Complete-BRAVOProcessOutputCapture { BRAVO.Compatibility\Complete-BRAVOProcessOutputCapture @args }
# Прозорий passthrough до реальної Get-BRAVODirectories з єдиним опційним
# test-only гаком (P2-2, PR #136 review): $script:taP2VanishAfterDiscoveryPath,
# коли встановлено, синхронно й детерміновано видаляє вказаний каталог
# ПІСЛЯ того, як реальна Get-BRAVODirectories вже повернула його як
# наявний candidate, але ДО того, як per-candidate EnumerateFileSystemInfos()
# встигає його відкрити — відтворює РЕАЛЬНУ гонитву "candidate зник між
# скануванням і enumeration" без потоків/сну (Deny-ACL емпірично не
# блокує enumerate для локального адміністратора в цьому середовищі,
# reparse-точки Get-BRAVODirectories взагалі відфільтровує на вході —
# обидва підходи перевірено окремими репро й відкинуто). Коли змінна не
# встановлена — поведінка ідентична реальній функції для решти тестів
# цього файлу (Get-BRAVOExpiredLogDateDirectories тощо).
function Get-BRAVODirectories {
    param([string]$Path, [string]$Filter = "*", [switch]$Recurse)
    $realResult = @(BRAVO.Compatibility\Get-BRAVODirectories -Path $Path -Filter $Filter -Recurse:$Recurse)
    if ($script:taP2VanishAfterDiscoveryPath -and (Test-Path -LiteralPath $script:taP2VanishAfterDiscoveryPath)) {
        Remove-Item -LiteralPath $script:taP2VanishAfterDiscoveryPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $realResult
}
'@
    $traceArchiveModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText ($traceArchiveStubText + "`n" + $traceArchiveScriptText) `
        -FunctionNames @(
            "Write-Log",
            "Send-SlackAlert",
            "Test-SevenZipArchiveIntegrity",
            "Get-BRAVOSevenZipArchiveEntries",
            "Get-BRAVOSevenZipFileCrc",
            "Get-BRAVOSevenZipExitCodeDescription",
            "Get-BRAVOFileHash",
            "Get-BRAVOFiles",
            "ConvertTo-BRAVOWindowsCommandLineArgument",
            "Start-BRAVOProcessOutputCapture",
            "Write-BRAVOProcessInputText",
            "Complete-BRAVOProcessOutputCapture",
            "Write-BRAVOLogRotationMessage",
            "Format-CommandOutput",
            "Invoke-CommandWithLog",
            "Get-BRAVODirectories",
            "Get-BRAVOTraceArchiveBacklog",
            "Get-BRAVOTraceArchiveUpdatePlan",
            "New-BRAVOTraceWorkArchivePath",
            "Remove-BRAVOTraceWorkArtifacts",
            "Clear-BRAVOTraceOrphanWorkArtifacts",
            "Write-BRAVOTraceArchiveSidecar",
            "Test-BRAVOTraceArchiveSidecarCurrent",
            "Update-BRAVOTraceDailyArchive",
            "Send-BRAVOTraceArchiveFile",
            "Send-BRAVOTraceArchive",
            "Send-BRAVOOwnLogFile",
            "Invoke-BRAVOTraceRemoteLogMigration",
            "Invoke-BRAVOLegacyModelArchiveLocalMigration",
            "Invoke-BRAVOTraceArchiveMaintenance",
            "Get-BRAVOEmptyLogDateDirectories",
            "Remove-BRAVOEmptyLogDateDirectories",
            "Get-BRAVOTraceGraceCompletionStatePath",
            "Read-BRAVOTraceGraceCompletionState",
            "Write-BRAVOTraceGraceCompletionState",
            "Test-BRAVOTraceGraceCompletionCurrent"
        )

    $traceArchive7za = Join-Path $root "Tools\7za.exe"
    $traceArchivePassword = 'trace-selftest-pass'
    # БЕЗ -mhe: другий запит пароля при add в mhe-архів нечитабельний з
    # redirected stdin (див. коментар в Update-BRAVOTraceDailyArchive).
    $traceArchiveAddParams = @('a', '-y', '-p')
    $traceArchiveTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_TRACE_ARCHIVE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        $taTrace = Join-Path $traceArchiveTestRoot "Trace"
        [void](New-Item -ItemType Directory -Path $taTrace -Force)

        function New-BRAVOTraceArchiveFixture {
            param([string]$Name, [string]$Content)
            $path = Join-Path $taTrace $Name
            [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
            return (Get-Item -LiteralPath $path)
        }

        # ===== Backlog: групування за датою З ІМЕНІ, oldest->newest,
        # legacy/сміття невидимі =====
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_20260820_110000.out' -Content 'srv-20 a')
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceBIS_20260820_110001.out' -Content 'bis-20 a')
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_20260821_090000.out' -Content 'srv-21 a')
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_1.out' -Content 'legacy sequence')
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_99999999_123456.out' -Content 'impossible date')
        [void](New-BRAVOTraceArchiveFixture -Name 'Trace_2026-08-20.mdz' -Content 'legacy mdz stub')
        [void](New-Item -ItemType Directory -Path (Join-Path $taTrace '2026-08-20') -Force)
        # Дата береться з імені, не з CreationTime: навмисно «чужий» час.
        (Get-Item -LiteralPath (Join-Path $taTrace 'TraceSRV_20260820_110000.out')).CreationTime = Get-Date -Date '2026-01-01 00:00:00'

        $taBacklog = & $traceArchiveModule { param($d) Get-BRAVOTraceArchiveBacklog -TraceDirectory $d } $taTrace
        Test-BRAVOCondition -Condition (
            @($taBacklog).Count -eq 2 -and
            [string]@($taBacklog)[0].DateKey -eq '20260820' -and
            [string]@($taBacklog)[1].DateKey -eq '20260821' -and
            @(@($taBacklog)[0].Files).Count -eq 2 -and
            [string]@($taBacklog)[0].ArchiveName -eq 'Trace_20260820.mdz' -and
            @(@($taBacklog) | ForEach-Object { @($_.Files) } | Where-Object { $_.Name -match '_1\.out$|99999999' }).Count -eq 0
        ) -Name 'TraceArchive/BacklogGroupsByNameDateOldestFirst' -Failure "backlog має дати 20260820(2 файли)+20260821 за іменами (не CreationTime), oldest-first; legacy _1.out і неможлива дата — невидимі; факт: $(@($taBacklog).Count) груп"

        # ===== Перший MDZ за дату: CREATED + 7zt + sidecar-формат =====
        $taGroup20 = @($taBacklog)[0]
        $taPlan1 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20 $traceArchive7za $traceArchivePassword
        $taUpdate1 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20 $taPlan1 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        $taSidecarText1 = if (Test-Path -LiteralPath $taGroup20.SidecarPath) { [IO.File]::ReadAllText($taGroup20.SidecarPath, [Text.Encoding]::UTF8) } else { '' }
        $taExpectedHash1 = if (Test-Path -LiteralPath $taGroup20.ArchivePath) { ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash).ToLowerInvariant() } else { 'no-archive' }
        Test-BRAVOCondition -Condition (
            [string]$taUpdate1.Status -eq 'CREATED' -and
            [int]$taUpdate1.AddedCount -eq 2 -and
            (Test-Path -LiteralPath $taGroup20.ArchivePath) -and
            $taSidecarText1 -ceq "$taExpectedHash1 *Trace_20260820.mdz" -and
            (BRAVO.ArchiveHelpers\Test-SevenZipArchiveIntegrity -SevenZipPath $traceArchive7za -ArchivePath $taGroup20.ArchivePath -Password $traceArchivePassword -TimeoutSeconds 600)
        ) -Name 'TraceArchive/FirstDailyArchiveCreatedWithSidecar' -Failure "перший запуск дати має дати CREATED(2), 7zt OK і sidecar '{hash} *Trace_20260820.mdz'; факт: $($taUpdate1.Status)/$($taUpdate1.Error)"

        # ===== Друге поповнення: UPDATED, старі entries immutable =====
        $taInventoryBefore = BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries -SevenZipPath $traceArchive7za -ArchivePath $taGroup20.ArchivePath -Password $traceArchivePassword
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_20260820_180000.out' -Content 'srv-20 evening, more content')
        $taBacklog2 = & $traceArchiveModule { param($d) Get-BRAVOTraceArchiveBacklog -TraceDirectory $d } $taTrace
        $taGroup20b = @($taBacklog2 | Where-Object { $_.DateKey -eq '20260820' })[0]
        $taPlan2 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20b $traceArchive7za $traceArchivePassword
        $taDiagLog = New-Object System.Collections.Generic.List[string]
        $taDiagLogger = { param($Message, $Level) [void]$taDiagLog.Add("[$Level] $Message") }.GetNewClosure()
        $taUpdate2 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p, $lg) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 -Logger $lg } $taGroup20b $taPlan2 $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taDiagLogger
        $taInventoryAfter = BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries -SevenZipPath $traceArchive7za -ArchivePath $taGroup20.ArchivePath -Password $traceArchivePassword
        $taOldPreserved = $true
        foreach ($oldEntry in @($taInventoryBefore.Entries)) {
            $afterMatch = @($taInventoryAfter.Entries | Where-Object { $_.Path -eq $oldEntry.Path -and [int64]$_.Size -eq [int64]$oldEntry.Size -and [string]$_.Crc -eq [string]$oldEntry.Crc })
            if (@($afterMatch).Count -ne 1) { $taOldPreserved = $false }
        }
        Test-BRAVOCondition -Condition (
            [string]$taUpdate2.Status -eq 'UPDATED' -and
            [int]$taUpdate2.AddedCount -eq 1 -and
            @($taPlan2.NewFiles).Count -eq 1 -and
            @($taPlan2.DuplicateFiles).Count -eq 2 -and
            $taOldPreserved -and
            @($taInventoryAfter.Entries).Count -eq 3
        ) -Name 'TraceArchive/SecondRunAppendsOnlyNewEntriesOldImmutable' -Failure "друге поповнення: UPDATED(+1), 2 дублікати skip, старі entries Path+Size+CRC незмінні, разом 3; факт: $($taUpdate2.Status) added=$($taUpdate2.AddedCount) entries=$(@($taInventoryAfter.Entries).Count) err=$($taUpdate2.Error) diag=$($taDiagLog -join ' // ')"

        # ===== Дублікат, що вже в архіві (слід «MDZ OK / SFTP FAIL»):
        # не додається повторно, архів байт-у-байт стабільний =====
        $taArchiveSizeBefore = (Get-Item -LiteralPath $taGroup20.ArchivePath).Length
        $taPlan3 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20b $traceArchive7za $traceArchivePassword
        $taUpdate3 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20b $taPlan3 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        Test-BRAVOCondition -Condition (
            [string]$taUpdate3.Status -eq 'UP_TO_DATE' -and
            @($taPlan3.NewFiles).Count -eq 0 -and
            @($taPlan3.DuplicateFiles).Count -eq 3 -and
            -not $taPlan3.HasConflicts -and
            (Get-Item -LiteralPath $taGroup20.ArchivePath).Length -eq $taArchiveSizeBefore
        ) -Name 'TraceArchive/DuplicateLocalFilesAreNotReAdded' -Failure "усі 3 локальні файли вже в архіві: план 0 нових/3 дублікати, UP_TO_DATE, розмір архіву незмінний; факт: $($taUpdate3.Status) new=$(@($taPlan3.NewFiles).Count) err=$($taUpdate3.Error) planErr=$($taPlan3.Error)"

        # ===== Restart-safe: зіпсований sidecar регенерується в UP_TO_DATE =====
        [IO.File]::WriteAllText($taGroup20.SidecarPath, 'garbage-sidecar', (New-Object Text.UTF8Encoding($false)))
        $taUpdate3b = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20b $taPlan3 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        $taSidecarText3b = [IO.File]::ReadAllText($taGroup20.SidecarPath, [Text.Encoding]::UTF8)
        $taExpectedHash3b = ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash).ToLowerInvariant()
        Test-BRAVOCondition -Condition (
            [string]$taUpdate3b.Status -eq 'UP_TO_DATE' -and
            $taSidecarText3b -ceq "$taExpectedHash3b *Trace_20260820.mdz"
        ) -Name 'TraceArchive/UpToDateRegeneratesStaleSidecar' -Failure "UP_TO_DATE-гілка має регенерувати невідповідний sidecar (restart-safe після збою між публікацією архіву і sidecar)"

        # ===== Конфлікт: те саме ім'я, інший контент -> FAILED, архів і
        # локальний файл недоторкані =====
        $taConflictPath = Join-Path $taTrace 'TraceSRV_20260820_110000.out'
        [IO.File]::WriteAllText($taConflictPath, 'srv-20 TAMPERED content xxxx', (New-Object Text.UTF8Encoding($false)))
        $taHashBeforeConflict = ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash)
        $taPlan4 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20b $traceArchive7za $traceArchivePassword
        $taUpdate4 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20b $taPlan4 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        Test-BRAVOCondition -Condition (
            $taPlan4.HasConflicts -and
            [string]$taUpdate4.Status -eq 'FAILED' -and
            ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash) -ceq $taHashBeforeConflict -and
            (Test-Path -LiteralPath $taConflictPath)
        ) -Name 'TraceArchive/NameCollisionWithDifferentContentFailsClosed' -Failure "однакове ім'я з іншим контентом: план Conflict, Update=FAILED, archived entry і локальний файл недоторкані"
        [IO.File]::WriteAllText($taConflictPath, 'srv-20 a', (New-Object Text.UTF8Encoding($false)))

        # ===== Збій 7za a: старий архів живий, work прибрано =====
        [void](New-BRAVOTraceArchiveFixture -Name 'TraceSRV_20260820_235500.out' -Content 'late srv entry')
        $taBacklog5 = & $traceArchiveModule { param($d) Get-BRAVOTraceArchiveBacklog -TraceDirectory $d } $taTrace
        $taGroup20c = @($taBacklog5 | Where-Object { $_.DateKey -eq '20260820' })[0]
        $taPlan5 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20c $traceArchive7za $traceArchivePassword
        $taUpdate5 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20c $taPlan5 $traceArchive7za @('a', '-y', '-invalid-switch!!', '-p') $traceArchivePassword
        $taWorkDir = Join-Path $taTrace '.work'
        $taWorkLeftovers = if (Test-Path -LiteralPath $taWorkDir) { @(Get-ChildItem -LiteralPath $taWorkDir -File) } else { @() }
        Test-BRAVOCondition -Condition (
            [string]$taUpdate5.Status -eq 'FAILED' -and
            ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash) -ceq $taHashBeforeConflict -and
            @($taWorkLeftovers).Count -eq 0 -and
            (Test-Path -LiteralPath (Join-Path $taTrace 'TraceSRV_20260820_235500.out'))
        ) -Name 'TraceArchive/SevenZipAddFailureKeepsPreviousArchive' -Failure "збій 7za a: FAILED, попередній архів байт-у-байт живий, .work прибрано, джерело лишилось; факт: $($taUpdate5.Status) leftovers=$(@($taWorkLeftovers).Count)"

        # ===== Tampered-верифікація: якщо «старий» entry нібито мав інший
        # CRC — публікація скасовується (immutability-гейт) =====
        $taTamperedPlan = [pscustomobject]@{
            ArchiveExists = $taPlan5.ArchiveExists
            ExistingEntries = @($taPlan5.ExistingEntries | ForEach-Object {
                [pscustomobject]@{ Path = $_.Path; Size = $_.Size; Crc = 'DEADBEEF'; IsDirectory = $_.IsDirectory }
            })
            NewFiles = $taPlan5.NewFiles
            DuplicateFiles = $taPlan5.DuplicateFiles
            ConflictFiles = @()
            HasConflicts = $false
            InventoryFailed = $false
            Error = $null
        }
        $taUpdate6 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20c $taTamperedPlan $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        Test-BRAVOCondition -Condition (
            [string]$taUpdate6.Status -eq 'FAILED' -and
            $taUpdate6.Error -like '*змінився*' -and
            ([string](BRAVO.Compatibility\Get-BRAVOFileHash -Path $taGroup20.ArchivePath -Algorithm SHA512).Hash) -ceq $taHashBeforeConflict
        ) -Name 'TraceArchive/PostUpdateImmutabilityCheckBlocksPublish' -Failure "розбіжність Size/CRC старого entry на контрольному inventory має скасувати публікацію (FAILED, архів попередньої версії живий)"

        # ===== Успішне поповнення після збою: без дублікатів =====
        $taPlan7 = & $traceArchiveModule { param($g, $z, $p) Get-BRAVOTraceArchiveUpdatePlan -BacklogGroup $g -SevenZipPath $z -ArchivePassword $p } $taGroup20c $traceArchive7za $traceArchivePassword
        $taUpdate7 = & $traceArchiveModule { param($g, $pl, $z, $ap, $p) Update-BRAVOTraceDailyArchive -BacklogGroup $g -Plan $pl -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 } $taGroup20c $taPlan7 $traceArchive7za $traceArchiveAddParams $traceArchivePassword
        $taInventoryFinal = BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries -SevenZipPath $traceArchive7za -ArchivePath $taGroup20.ArchivePath -Password $traceArchivePassword
        Test-BRAVOCondition -Condition (
            [string]$taUpdate7.Status -eq 'UPDATED' -and
            [int]$taUpdate7.AddedCount -eq 1 -and
            @($taInventoryFinal.Entries).Count -eq 4 -and
            @($taInventoryFinal.Entries | Group-Object Path | Where-Object { $_.Count -gt 1 }).Count -eq 0
        ) -Name 'TraceArchive/RetryAfterFailureAddsWithoutDuplicates' -Failure "повторний прогін після збою: додано рівно новий файл, жодного дубльованого entry (4 унікальні)"

        # ===== Orphan sweep: старий .partial прибирається, свіжий — ні =====
        [void](New-Item -ItemType Directory -Path $taWorkDir -Force)
        $taOrphanOld = Join-Path $taWorkDir 'Trace_20260819.deadbeef.partial.mdz'
        $taOrphanFresh = Join-Path $taWorkDir 'Trace_20260821.cafebabe.partial.mdz'
        [IO.File]::WriteAllText($taOrphanOld, 'old orphan')
        [IO.File]::WriteAllText($taOrphanFresh, 'fresh orphan')
        (Get-Item -LiteralPath $taOrphanOld).LastWriteTime = (Get-Date).AddHours(-72)
        $taSweptCount = & $traceArchiveModule { param($d) Clear-BRAVOTraceOrphanWorkArtifacts -TraceDirectory $d -RetentionHours 48 } $taTrace
        Test-BRAVOCondition -Condition (
            [int]$taSweptCount -eq 1 -and
            -not (Test-Path -LiteralPath $taOrphanOld) -and
            (Test-Path -LiteralPath $taOrphanFresh)
        ) -Name 'TraceArchive/OrphanWorkSweepRespectsRetention' -Failure "sweep має прибрати лише .partial старший за поріг (72h > 48h), свіжий лишити"
        Remove-Item -LiteralPath $taOrphanFresh -Force -ErrorAction SilentlyContinue

        # ===== SFTP-фаза: фейкова duck-typed сесія (New-BRAVOSelfTestFakeBazaSession
        # з BazaSync-домену — цей фрагмент dot-source-иться ПІСЛЯ нього) =====

        # --- Успішна публікація: .new -> verify -> звільнення -> rename -> verify ---
        $taSendLocalDir = Join-Path $traceArchiveTestRoot "send"
        [void](New-Item -ItemType Directory -Path $taSendLocalDir -Force)
        $taSendArchive = Join-Path $taSendLocalDir 'Trace_20260815.mdz'
        $taSendSidecar = "$taSendArchive.sha512"
        [IO.File]::WriteAllText($taSendArchive, ('m' * 300))
        [IO.File]::WriteAllText($taSendSidecar, ('s' * 140))
        $taSendSession = New-BRAVOSelfTestFakeBazaSession
        $taSendSession.State.RemoteSizes['/trace/Trace_20260815.mdz'] = [int64]111
        $taSendResult = & $traceArchiveModule { param($s, $a, $sc, $d) Send-BRAVOTraceArchive -Session $s -ArchivePath $a -SidecarPath $sc -RemoteDirectory $d } $taSendSession $taSendArchive $taSendSidecar 'trace'
        Test-BRAVOCondition -Condition (
            $taSendResult.Success -eq $true -and
            [int64]$taSendSession.State.RemoteSizes['/trace/Trace_20260815.mdz'] -eq 300 -and
            [int64]$taSendSession.State.RemoteSizes['/trace/Trace_20260815.mdz.sha512'] -eq 140 -and
            (@($taSendSession.State.PutFilesCalledFor) -contains '/trace/Trace_20260815.mdz.new') -and
            (@($taSendSession.State.MoveFileCalls) -contains '/trace/Trace_20260815.mdz.new -> /trace/Trace_20260815.mdz') -and
            (@($taSendSession.State.RemoveFilesCalls) -contains '/trace/Trace_20260815.mdz') -and
            [string]$taSendSession.State.LastResumeSupportState -eq 'On'
        ) -Name 'TraceArchive/SftpPublishGoesThroughVerifiedTempName' -Failure "успішна публікація: передача у .new (Resume=On), verify, звільнення старої версії, rename, фінальний розмір 300/140; факт: $($taSendResult.Error)"

        # --- РЕГРЕСІЯ (реальний DEV-LIMS): remote-каталог /trace/ не існував,
        # session.PutFiles його НЕ створює, і кожен прогін падав із
        # "Cannot create remote file '/trace/....new.filepart'. No such file
        # or directory" -> exit 60 обслуговування, яке відпрацювало. Каталог
        # має створюватись ДО передачі (канонічний рекурсивний creator
        # BRAVO.BazaSync), один раз на комплект. ---
        $taSendMissingDirArchive = Join-Path $taSendLocalDir 'Trace_20260817.mdz'
        $taSendMissingDirSidecar = "$taSendMissingDirArchive.sha512"
        [IO.File]::WriteAllText($taSendMissingDirArchive, ('m' * 210))
        [IO.File]::WriteAllText($taSendMissingDirSidecar, ('s' * 140))
        $taSendMissingDirSession = New-BRAVOSelfTestFakeBazaSession
        $taSendMissingDirResult = & $traceArchiveModule { param($s, $a, $sc, $d) Send-BRAVOTraceArchive -Session $s -ArchivePath $a -SidecarPath $sc -RemoteDirectory $d } $taSendMissingDirSession $taSendMissingDirArchive $taSendMissingDirSidecar 'trace/daily'
        Test-BRAVOCondition -Condition (
            $taSendMissingDirResult.Success -eq $true -and
            $taSendMissingDirSession.State.KnownRemoteDirs.Contains('/trace') -and
            $taSendMissingDirSession.State.KnownRemoteDirs.Contains('/trace/daily') -and
            [int64]$taSendMissingDirSession.State.RemoteSizes['/trace/daily/Trace_20260817.mdz'] -eq 210
        ) -Name 'TraceArchive/SftpCreatesMissingRemoteDirectoryBeforeUpload' -Failure "відсутній remote-каталог має створюватись рекурсивно ДО PutFiles (/trace, потім /trace/daily); факт: $($taSendMissingDirResult.Error)"

        # Каталог уже існує — жодного зайвого CreateDirectory.
        $taSendExistingDirSession = New-BRAVOSelfTestFakeBazaSession
        [void]$taSendExistingDirSession.State.KnownRemoteDirs.Add('/trace')
        [void](& $traceArchiveModule { param($s, $a, $sc, $d) Send-BRAVOTraceArchive -Session $s -ArchivePath $a -SidecarPath $sc -RemoteDirectory $d } $taSendExistingDirSession $taSendArchive $taSendSidecar 'trace')
        Test-BRAVOCondition -Condition (
            @($taSendExistingDirSession.State.KnownRemoteDirs).Count -eq 1
        ) -Name 'TraceArchive/SftpDoesNotRecreateExistingRemoteDirectory' -Failure "наявний remote-каталог не має створюватись повторно; факт каталогів: $(@($taSendExistingDirSession.State.KnownRemoteDirs) -join ', ')"

        # Збій створення каталогу — fail-open саме для SFTP: помилка етапу,
        # локальний архів і .out недоторкані, фінальне ім'я не зрушене.
        $taSendDirFailSession = New-BRAVOSelfTestFakeBazaSession
        $taSendDirFailSession | Add-Member -Force -MemberType ScriptMethod -Name CreateDirectory -Value {
            param($path)
            throw "simulated permission denied: $path"
        }
        $taSendDirFailResult = & $traceArchiveModule { param($s, $a, $sc, $d) Send-BRAVOTraceArchive -Session $s -ArchivePath $a -SidecarPath $sc -RemoteDirectory $d } $taSendDirFailSession $taSendArchive $taSendSidecar 'trace'
        Test-BRAVOCondition -Condition (
            $taSendDirFailResult.Success -eq $false -and
            @($taSendDirFailSession.State.PutFilesCalledFor).Count -eq 0 -and
            @($taSendDirFailSession.State.MoveFileCalls).Count -eq 0 -and
            @($taSendDirFailSession.State.RemoveFilesCalls).Count -eq 0 -and
            (Test-Path -LiteralPath $taSendArchive)
        ) -Name 'TraceArchive/SftpRemoteDirectoryFailureAbortsBeforeTransfer' -Failure "збій CreateDirectory має завершити передачу помилкою ДО PutFiles, не чіпаючи ані remote-фінал, ані локальний архів"

        # --- Обірвана передача (PutFiles fail): стара remote-версія жива, нічого не зрушено ---
        $taSendFailSession = New-BRAVOSelfTestFakeBazaSession -AllTransfersFail
        $taSendFailSession.State.RemoteSizes['/trace/Trace_20260815.mdz'] = [int64]111
        $taSendFailResult = & $traceArchiveModule { param($s, $a, $sc, $d) Send-BRAVOTraceArchive -Session $s -ArchivePath $a -SidecarPath $sc -RemoteDirectory $d } $taSendFailSession $taSendArchive $taSendSidecar 'trace'
        Test-BRAVOCondition -Condition (
            $taSendFailResult.Success -eq $false -and
            [int64]$taSendFailSession.State.RemoteSizes['/trace/Trace_20260815.mdz'] -eq 111 -and
            @($taSendFailSession.State.RemoveFilesCalls).Count -eq 0 -and
            @($taSendFailSession.State.MoveFileCalls).Count -eq 0
        ) -Name 'TraceArchive/SftpInterruptedTransferKeepsOldRemoteVersion' -Failure "збій передачі .new: стара remote-версія (111 байт) недоторкана, RemoveFiles/MoveFile не викликались"

        # --- Remote-верифікація .new не пройдена: публікація скасована ---
        $taSendBadSizeSession = New-BRAVOSelfTestFakeBazaSession
        $taSendBadSizeSession.State.RemoteSizes['/trace/Trace_20260815.mdz'] = [int64]111
        $taSendBadSizeSession | Add-Member -Force -MemberType ScriptMethod -Name GetFileInfo -Value {
            param($remotePath)
            return [pscustomobject]@{ Length = [int64]1 }
        }
        $taSendBadSizeResult = & $traceArchiveModule { param($s, $a, $sc, $d) Send-BRAVOTraceArchive -Session $s -ArchivePath $a -SidecarPath $sc -RemoteDirectory $d } $taSendBadSizeSession $taSendArchive $taSendSidecar 'trace'
        Test-BRAVOCondition -Condition (
            $taSendBadSizeResult.Success -eq $false -and
            [int64]$taSendBadSizeSession.State.RemoteSizes['/trace/Trace_20260815.mdz'] -eq 111 -and
            @($taSendBadSizeSession.State.RemoveFilesCalls).Count -eq 0
        ) -Name 'TraceArchive/SftpSizeMismatchAbortsBeforeTouchingFinal' -Failure "розбіжність розміру .new має скасувати публікацію ДО будь-якого дотику фінального імені (стара версія 111 байт жива)"

        # ===== Log-lifecycle P1: Send-BRAVOOwnLogFile (best-effort
        # вивантаження власного логу прогону / знімка range_id_log.json) =====

        # Успішна передача: remote-каталог створюється, файл публікується
        # через той самий verified-.new канал (Send-BRAVOTraceArchiveFile).
        $taOwnLogPath = Join-Path $taSendLocalDir 'BRAVO_MAINTENANCE_20260904_010203_PID42.log'
        [IO.File]::WriteAllText($taOwnLogPath, ('l' * 250))
        $taOwnLogSession = New-BRAVOSelfTestFakeBazaSession
        & $traceArchiveModule { param($s, $l, $d) Send-BRAVOOwnLogFile -Session $s -LocalLogPath $l -RemoteDirectory $d } $taOwnLogSession $taOwnLogPath 'logs/maintenance'
        Test-BRAVOCondition -Condition (
            [int64]$taOwnLogSession.State.RemoteSizes['/logs/maintenance/BRAVO_MAINTENANCE_20260904_010203_PID42.log'] -eq 250 -and
            $taOwnLogSession.State.KnownRemoteDirs.Contains('/logs/maintenance')
        ) -Name 'TraceArchive/OwnLogUploadPublishesFullLogToConfiguredDirectory' -Failure "власний лог має публікуватись у сконфігурований remote-каталог (з рекурсивним створенням) через verified-.new канал; факт: $(@($taOwnLogSession.State.RemoteSizes.Keys) -join ', ')"

        # RemoteFileName override: константне локальне ім'я (range_id_log.json)
        # публікується під унікальним remote-ім'ям з run-id.
        $taOwnRangeIdPath = Join-Path $taSendLocalDir 'range_id_log.json'
        [IO.File]::WriteAllText($taOwnRangeIdPath, '{"r":1}')
        $taOwnRangeIdSession = New-BRAVOSelfTestFakeBazaSession
        & $traceArchiveModule { param($s, $l, $d, $n) Send-BRAVOOwnLogFile -Session $s -LocalLogPath $l -RemoteDirectory $d -RemoteFileName $n } $taOwnRangeIdSession $taOwnRangeIdPath 'logs/maintenance' 'range_id_log_20260904_010203_PID42.json'
        Test-BRAVOCondition -Condition (
            $taOwnRangeIdSession.State.RemoteSizes.ContainsKey('/logs/maintenance/range_id_log_20260904_010203_PID42.json') -and
            -not $taOwnRangeIdSession.State.RemoteSizes.ContainsKey('/logs/maintenance/range_id_log.json')
        ) -Name 'TraceArchive/OwnLogUploadRemoteFileNameOverrideAvoidsOverwrite' -Failure "range_id-знімок має публікуватись під унікальним remote-ім'ям з run-id, а не під константним локальним ім'ям"

        # Відсутній локальний файл — тихий no-op без жодного remote-виклику.
        $taOwnMissingSession = New-BRAVOSelfTestFakeBazaSession
        & $traceArchiveModule { param($s, $l, $d) Send-BRAVOOwnLogFile -Session $s -LocalLogPath $l -RemoteDirectory $d } $taOwnMissingSession (Join-Path $taSendLocalDir 'NO_SUCH_LOG.log') 'logs/maintenance'
        Test-BRAVOCondition -Condition (
            @($taOwnMissingSession.State.PutFilesCalledFor).Count -eq 0 -and
            @($taOwnMissingSession.State.KnownRemoteDirs).Count -eq 0
        ) -Name 'TraceArchive/OwnLogUploadMissingLocalFileIsSilentNoOp' -Failure "відсутній локальний файл (напр., range_id_log.json ще не створено службою) — no-op без remote-викликів"

        # Збій передачі — WARNING усередині, БЕЗ винятку назовні
        # (best-effort: провал телеметрії ніколи не ламає прогін).
        $taOwnFailSession = New-BRAVOSelfTestFakeBazaSession -AllTransfersFail
        $taOwnFailThrew = $false
        try {
            & $traceArchiveModule { param($s, $l, $d) Send-BRAVOOwnLogFile -Session $s -LocalLogPath $l -RemoteDirectory $d } $taOwnFailSession $taOwnLogPath 'logs/maintenance'
        } catch {
            $taOwnFailThrew = $true
        }
        Test-BRAVOCondition -Condition (
            -not $taOwnFailThrew -and
            @($taOwnFailSession.State.MoveFileCalls).Count -eq 0
        ) -Name 'TraceArchive/OwnLogUploadFailureIsBestEffortNoThrow' -Failure "збій передачі власного логу не має кидати виняток назовні (лише WARNING) і не має чіпати remote-фінал"

        # --- Оркестратор e2e на фейковій SFTP: повний success видаляє .out,
        # локальний MDZ ЗАЛИШАЄТЬСЯ; SFTP fail зберігає все; retry без дублікатів ---
        $taOrch = Join-Path $traceArchiveTestRoot "orch\Trace"
        [void](New-Item -ItemType Directory -Path $taOrch -Force)
        $taOrchFile1 = Join-Path $taOrch 'TraceSRV_20260816_090000.out'
        [IO.File]::WriteAllText($taOrchFile1, 'orch srv morning')
        $taOrchFailSession = New-BRAVOSelfTestFakeBazaSession -AllTransfersFail
        $taOrchResult1 = & $traceArchiveModule { param($d, $z, $ap, $p, $s, $rd) Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 -Session $s -RemoteDirectory $rd } $taOrch $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taOrchFailSession 'trace'
        Test-BRAVOCondition -Condition (
            [int]$taOrchResult1.ArchivesUpdated -eq 1 -and
            [int]$taOrchResult1.Uploaded -eq 0 -and
            [int]$taOrchResult1.Errors -ge 1 -and
            [int]$taOrchResult1.SourcesDeleted -eq 0 -and
            (Test-Path -LiteralPath $taOrchFile1) -and
            (Test-Path -LiteralPath (Join-Path $taOrch 'Trace_20260816.mdz'))
        ) -Name 'TraceArchive/OrchestratorSftpFailureKeepsMdzAndSources' -Failure "SFTP-збій: локальний MDZ оновлено і ЗБЕРЕЖЕНО, .out збережено, нічого не видалено; факт: updated=$($taOrchResult1.ArchivesUpdated) deleted=$($taOrchResult1.SourcesDeleted)"

        $taOrchOkSession = New-BRAVOSelfTestFakeBazaSession
        $taOrchResult2 = & $traceArchiveModule { param($d, $z, $ap, $p, $s, $rd) Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 -Session $s -RemoteDirectory $rd } $taOrch $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taOrchOkSession 'trace'
        $taOrchInventory = BRAVO.Compatibility\Get-BRAVOSevenZipArchiveEntries -SevenZipPath $traceArchive7za -ArchivePath (Join-Path $taOrch 'Trace_20260816.mdz') -Password $traceArchivePassword
        Test-BRAVOCondition -Condition (
            [int]$taOrchResult2.Uploaded -eq 1 -and
            [int]$taOrchResult2.SourcesDeleted -eq 1 -and
            [int]$taOrchResult2.Errors -eq 0 -and
            [int]$taOrchResult2.ArchivesUpdated -eq 0 -and
            -not (Test-Path -LiteralPath $taOrchFile1) -and
            (Test-Path -LiteralPath (Join-Path $taOrch 'Trace_20260816.mdz')) -and
            (Test-Path -LiteralPath (Join-Path $taOrch 'Trace_20260816.mdz.sha512')) -and
            @($taOrchInventory.Entries).Count -eq 1 -and
            [int64]$taOrchOkSession.State.RemoteSizes['/trace/Trace_20260816.mdz'] -eq (Get-Item -LiteralPath (Join-Path $taOrch 'Trace_20260816.mdz')).Length
        ) -Name 'TraceArchive/OrchestratorRetryUploadsWithoutDuplicatesThenCleansSources' -Failure "retry після SFTP-збою: без повторного додавання (1 entry), upload+verify, .out видалено, локальний MDZ+sidecar ЗАЛИШЕНО; факт: uploaded=$($taOrchResult2.Uploaded) deleted=$($taOrchResult2.SourcesDeleted) errors=$($taOrchResult2.Errors)"

        # --- Session=$null: передача відкладена, .out збережені ---
        $taOrchDeferred = Join-Path $traceArchiveTestRoot "orch2\Trace"
        [void](New-Item -ItemType Directory -Path $taOrchDeferred -Force)
        $taOrchDeferredFile = Join-Path $taOrchDeferred 'TraceBIS_20260817_120000.out'
        [IO.File]::WriteAllText($taOrchDeferredFile, 'deferred bis')
        $taOrchResult3 = & $traceArchiveModule { param($d, $z, $ap, $p, $rd) Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 -Session $null -RemoteDirectory $rd } $taOrchDeferred $traceArchive7za $traceArchiveAddParams $traceArchivePassword 'trace'
        Test-BRAVOCondition -Condition (
            [int]$taOrchResult3.ArchivesUpdated -eq 1 -and
            [int]$taOrchResult3.UploadsDeferred -eq 1 -and
            [int]$taOrchResult3.SourcesDeleted -eq 0 -and
            (Test-Path -LiteralPath $taOrchDeferredFile) -and
            (Test-Path -LiteralPath (Join-Path $taOrchDeferred 'Trace_20260817.mdz'))
        ) -Name 'TraceArchive/OrchestratorWithoutSessionDefersUploadKeepsSources' -Failure "без SFTP-сесії: архів оновлюється локально, передача відкладена, .out збережені"

        # ===== P5 (2026-09): RawSourceRetentionDays grace-період =====
        # RawSourceRetentionDays=0 (дефолт, не передається явно) —
        # регресійний захист: точна попередня поведінка вже підтверджена
        # вище (OrchestratorRetryUploadsWithoutDuplicatesThenCleansSources
        # викликає БЕЗ -RawSourceRetentionDays і бачить SourcesDeleted=1).

        # --- N>0, джерело МОЛОДШЕ N днів: лишається локально попри повний success.
        $taGraceYoung = Join-Path $traceArchiveTestRoot "grace-young\Trace"
        [void](New-Item -ItemType Directory -Path $taGraceYoung -Force)
        $taGraceYoungFile = Join-Path $taGraceYoung 'TraceSRV_20260901_090000.out'
        [IO.File]::WriteAllText($taGraceYoungFile, 'grace young')
        (Get-Item -LiteralPath $taGraceYoungFile).LastWriteTime = (Get-Date).AddDays(-1)
        $taGraceYoungSession = New-BRAVOSelfTestFakeBazaSession
        $taGraceYoungResult = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace
        } $taGraceYoung $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taGraceYoungSession 'trace' 7
        Test-BRAVOCondition -Condition (
            [int]$taGraceYoungResult.Uploaded -eq 1 -and
            [int]$taGraceYoungResult.Errors -eq 0 -and
            [int]$taGraceYoungResult.SourcesDeleted -eq 0 -and
            [int]$taGraceYoungResult.SourcesRetainedForGrace -eq 1 -and
            (Test-Path -LiteralPath $taGraceYoungFile)
        ) -Name 'TraceArchive/RawSourceGraceRetainsYoungVerifiedSource' -Failure "джерело молодше grace-періоду має лишатись локально попри повний success (архів+SFTP+верифікація); факт: deleted=$($taGraceYoungResult.SourcesDeleted) retained=$($taGraceYoungResult.SourcesRetainedForGrace)"

        # --- N>0, джерело СТАРШЕ N днів: видаляється як завжди.
        $taGraceOld = Join-Path $traceArchiveTestRoot "grace-old\Trace"
        [void](New-Item -ItemType Directory -Path $taGraceOld -Force)
        $taGraceOldFile = Join-Path $taGraceOld 'TraceSRV_20260801_090000.out'
        [IO.File]::WriteAllText($taGraceOldFile, 'grace old')
        (Get-Item -LiteralPath $taGraceOldFile).LastWriteTime = (Get-Date).AddDays(-30)
        $taGraceOldSession = New-BRAVOSelfTestFakeBazaSession
        $taGraceOldResult = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace
        } $taGraceOld $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taGraceOldSession 'trace' 7
        Test-BRAVOCondition -Condition (
            [int]$taGraceOldResult.Uploaded -eq 1 -and
            [int]$taGraceOldResult.Errors -eq 0 -and
            [int]$taGraceOldResult.SourcesDeleted -eq 1 -and
            [int]$taGraceOldResult.SourcesRetainedForGrace -eq 0 -and
            -not (Test-Path -LiteralPath $taGraceOldFile)
        ) -Name 'TraceArchive/RawSourceGraceDeletesOldVerifiedSource' -Failure "джерело старше grace-періоду має видалятись як завжди, попри встановлений RawSourceRetentionDays; факт: deleted=$($taGraceOldResult.SourcesDeleted) retained=$($taGraceOldResult.SourcesRetainedForGrace)"

        # ===== PR #136 review (P2-7): persisted completion state для
        # RawSourceGraceDays — без нього КОЖЕН прогін під час grace-вікна
        # re-verify+re-upload той самий незмінний daily-архів. =====

        # --- A: незмінний архів+джерело -> другий прогін НЕ викликає SFTP взагалі.
        $taP7SkipDir = Join-Path $traceArchiveTestRoot "grace-completion-skip\Trace"
        [void](New-Item -ItemType Directory -Path $taP7SkipDir -Force)
        $taP7SkipFile = Join-Path $taP7SkipDir 'TraceSRV_20260901_090000.out'
        [IO.File]::WriteAllText($taP7SkipFile, 'grace completion skip')
        (Get-Item -LiteralPath $taP7SkipFile).LastWriteTime = (Get-Date).AddDays(-1)
        $taP7SkipStatePath = Join-Path $traceArchiveTestRoot 'grace-completion-skip\state.json'
        $taP7SkipSession1 = New-BRAVOSelfTestFakeBazaSession
        $taP7SkipResult1 = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace -GraceCompletionStatePath $statePath
        } $taP7SkipDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7SkipSession1 'trace' 7 $taP7SkipStatePath
        Test-BRAVOCondition -Condition (
            [int]$taP7SkipResult1.Uploaded -eq 1 -and
            [int]$taP7SkipResult1.SourcesRetainedForGrace -eq 1 -and
            @($taP7SkipSession1.State.PutFilesCalledFor).Count -eq 2 -and
            (Test-Path -LiteralPath $taP7SkipStatePath)
        ) -Name 'TraceArchive/GraceCompletionFirstRunUploadsAndPersistsState' -Failure "перший прогін має реально вивантажити і створити completion-state; факт: uploaded=$($taP7SkipResult1.Uploaded) putCalls=$(@($taP7SkipSession1.State.PutFilesCalledFor).Count) stateExists=$(Test-Path -LiteralPath $taP7SkipStatePath)"

        $taP7SkipSession2 = New-BRAVOSelfTestFakeBazaSession
        $taP7SkipResult2 = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace -GraceCompletionStatePath $statePath
        } $taP7SkipDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7SkipSession2 'trace' 7 $taP7SkipStatePath
        Test-BRAVOCondition -Condition (
            [int]$taP7SkipResult2.Uploaded -eq 0 -and
            [int]$taP7SkipResult2.Errors -eq 0 -and
            [int]$taP7SkipResult2.SourcesRetainedForGrace -eq 1 -and
            @($taP7SkipSession2.State.PutFilesCalledFor).Count -eq 0 -and
            (Test-Path -LiteralPath $taP7SkipFile)
        ) -Name 'TraceArchive/GraceCompletionSecondRunSkipsRepublishWhenUnchanged' -Failure "другий прогін без жодної зміни НЕ повинен викликати SFTP PutFiles знову; факт: uploaded=$($taP7SkipResult2.Uploaded) putCalls=$(@($taP7SkipSession2.State.PutFilesCalledFor).Count) errors=$($taP7SkipResult2.Errors)"

        # --- A2 (P2, PR #136 review r3943997861): пошкоджений/видалений
        # sidecar (.sha512) НЕ повинен трактуватись як "усе ще актуально" —
        # Test-BRAVOTraceGraceCompletionCurrent мусить перевіряти й sidecar,
        # інакше опублікований .mdz лишався б з "мертвим" .sha512 назавжди
        # (skip-шлях ніколи не викликає Update-BRAVOTraceDailyArchive, який
        # єдиний вміє полагодити sidecar через Test-BRAVOTraceArchiveSidecarCurrent).
        $taP7SidecarArchive = Get-ChildItem -LiteralPath $taP7SkipDir -Filter '*.mdz' | Select-Object -First 1
        [IO.File]::WriteAllText("$($taP7SidecarArchive.FullName).sha512", 'corrupted sidecar content')
        $taP7SkipSession3 = New-BRAVOSelfTestFakeBazaSession
        $taP7SkipResult3 = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace -GraceCompletionStatePath $statePath
        } $taP7SkipDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7SkipSession3 'trace' 7 $taP7SkipStatePath
        Test-BRAVOCondition -Condition (
            [int]$taP7SkipResult3.Uploaded -eq 1 -and
            [int]$taP7SkipResult3.Errors -eq 0 -and
            @($taP7SkipSession3.State.PutFilesCalledFor).Count -eq 2 -and
            (Test-BRAVOTraceArchiveSidecarCurrent -ArchivePath $taP7SidecarArchive.FullName -SidecarPath "$($taP7SidecarArchive.FullName).sha512")
        ) -Name 'TraceArchive/GraceCompletionCorruptedSidecarTriggersReprocessAndRepair' -Failure "пошкоджений sidecar має ЗАПУСТИТИ повторну обробку (і полагодити sidecar), а не помилковий skip; факт: uploaded=$($taP7SkipResult3.Uploaded) putCalls=$(@($taP7SkipSession3.State.PutFilesCalledFor).Count) errors=$($taP7SkipResult3.Errors)"

        # --- B: тампер stored-розміру в state -> reprocess (safe fallback), не помилковий skip.
        $taP7StaleDir = Join-Path $traceArchiveTestRoot "grace-completion-stale\Trace"
        [void](New-Item -ItemType Directory -Path $taP7StaleDir -Force)
        $taP7StaleFile = Join-Path $taP7StaleDir 'TraceSRV_20260902_090000.out'
        [IO.File]::WriteAllText($taP7StaleFile, 'grace completion stale')
        (Get-Item -LiteralPath $taP7StaleFile).LastWriteTime = (Get-Date).AddDays(-1)
        $taP7StaleStatePath = Join-Path $traceArchiveTestRoot 'grace-completion-stale\state.json'
        $taP7StaleSession1 = New-BRAVOSelfTestFakeBazaSession
        & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace -GraceCompletionStatePath $statePath
        } $taP7StaleDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7StaleSession1 'trace' 7 $taP7StaleStatePath | Out-Null
        # Зовнішнє тамперування stored-розміру джерела (симулює
        # розсинхронізований/застарілий маркер) — БЕЗ канонічного
        # Write-BRAVOTraceGraceCompletionState, навмисно "брудний" запис.
        $taP7StaleJson = Get-Content -LiteralPath $taP7StaleStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $taP7StaleJson.entries.'20260902'.sources[0].size = 999999
        [IO.File]::WriteAllText($taP7StaleStatePath, ($taP7StaleJson | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $taP7StaleSession2 = New-BRAVOSelfTestFakeBazaSession
        $taP7StaleResult2 = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace -GraceCompletionStatePath $statePath
        } $taP7StaleDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7StaleSession2 'trace' 7 $taP7StaleStatePath
        Test-BRAVOCondition -Condition (
            [int]$taP7StaleResult2.Uploaded -eq 1 -and
            [int]$taP7StaleResult2.Errors -eq 0 -and
            @($taP7StaleSession2.State.PutFilesCalledFor).Count -eq 2
        ) -Name 'TraceArchive/GraceCompletionMismatchedStateTriggersSafeReprocess' -Failure "розбіжність stored-розміру джерела з реальним файлом має ЗАПУСТИТИ повторну повну обробку (fail-safe), а не помилковий skip; факт: uploaded=$($taP7StaleResult2.Uploaded) putCalls=$(@($taP7StaleSession2.State.PutFilesCalledFor).Count)"

        # --- C: невідома/пошкоджена схема state -> fail-safe reprocess, без падіння.
        $taP7CorruptDir = Join-Path $traceArchiveTestRoot "grace-completion-corrupt\Trace"
        [void](New-Item -ItemType Directory -Path $taP7CorruptDir -Force)
        $taP7CorruptFile = Join-Path $taP7CorruptDir 'TraceSRV_20260903_090000.out'
        [IO.File]::WriteAllText($taP7CorruptFile, 'grace completion corrupt')
        (Get-Item -LiteralPath $taP7CorruptFile).LastWriteTime = (Get-Date).AddDays(-1)
        $taP7CorruptStatePath = Join-Path $traceArchiveTestRoot 'grace-completion-corrupt\state.json'
        [void](New-Item -ItemType Directory -Path (Split-Path -Path $taP7CorruptStatePath -Parent) -Force)
        [IO.File]::WriteAllText($taP7CorruptStatePath, '{ not valid json !!', (New-Object Text.UTF8Encoding($false)))
        $taP7CorruptSession = New-BRAVOSelfTestFakeBazaSession
        $taP7CorruptResult = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace -GraceCompletionStatePath $statePath
        } $taP7CorruptDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7CorruptSession 'trace' 7 $taP7CorruptStatePath
        Test-BRAVOCondition -Condition (
            [int]$taP7CorruptResult.Uploaded -eq 1 -and
            [int]$taP7CorruptResult.Errors -eq 0 -and
            @($taP7CorruptSession.State.PutFilesCalledFor).Count -eq 2
        ) -Name 'TraceArchive/GraceCompletionCorruptSchemaFailsSafeWithoutCrashing' -Failure "пошкоджений/невідомий schemaVersion state-файлу не повинен кидати виняток і має трактуватись як 'стану немає' (повна обробка); факт: uploaded=$($taP7CorruptResult.Uploaded) errors=$($taP7CorruptResult.Errors)"

        # --- D: завершення grace видаляє джерело БЕЗ повторного upload, і чистить state-запис.
        #
        # ВАЖЛИВО: тут НЕ можна повторно застосувати техніку "зістарити
        # LastWriteTime заднім числом" (як у RawSourceGraceDeletesOldVerifiedSource
        # вище) — Test-BRAVOTraceGraceCompletionCurrent коректно (за
        # дизайном P2-7) трактує БУДЬ-ЯКУ зміну LastWriteTimeUtc як зміну
        # identity джерела => недовіру до кешованого state => повну
        # повторну обробку (реальний upload). У продакшн-роботі
        # LastWriteTime джерела НІКОЛИ не змінюється — спливає лише
        # Get-Date. Тому тут grace-межу перетинаємо СПРАВЖНІМ плином
        # часу (Start-Sleep) при grace=1 день і початковому LastWriteTime,
        # виставленому щільно ПІД межею (день мінус 2с) — без жодної
        # подальшої мутації LastWriteTime.
        $taP7ExpireDir = Join-Path $traceArchiveTestRoot "grace-completion-expire\Trace"
        [void](New-Item -ItemType Directory -Path $taP7ExpireDir -Force)
        $taP7ExpireFile = Join-Path $taP7ExpireDir 'TraceSRV_20260904_090000.out'
        [IO.File]::WriteAllText($taP7ExpireFile, 'grace completion expire')
        (Get-Item -LiteralPath $taP7ExpireFile).LastWriteTime = (Get-Date).AddDays(-1).AddSeconds(2)
        $taP7ExpireStatePath = Join-Path $traceArchiveTestRoot 'grace-completion-expire\state.json'
        $taP7ExpireSession1 = New-BRAVOSelfTestFakeBazaSession
        $taP7ExpireResult1 = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace -GraceCompletionStatePath $statePath
        } $taP7ExpireDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7ExpireSession1 'trace' 1 $taP7ExpireStatePath
        Test-BRAVOCondition -Condition (
            [int]$taP7ExpireResult1.SourcesRetainedForGrace -eq 1 -and
            (Test-Path -LiteralPath $taP7ExpireFile)
        ) -Name 'TraceArchive/GraceCompletionExpirySetupRetainsWithinWindow' `
            -Failure "передумова тесту: джерело щільно під grace-межею має лишитись на цьому кроці; факт: retained=$($taP7ExpireResult1.SourcesRetainedForGrace) exists=$(Test-Path -LiteralPath $taP7ExpireFile)"
        # Реальний плин часу (не мутація LastWriteTime) переносить те саме
        # немодифіковане джерело за grace-межу (1 день).
        Start-Sleep -Seconds 3
        $taP7ExpireSession2 = New-BRAVOSelfTestFakeBazaSession
        $taP7ExpireResult2 = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $grace, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays $grace -GraceCompletionStatePath $statePath
        } $taP7ExpireDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7ExpireSession2 'trace' 1 $taP7ExpireStatePath
        $taP7ExpireJsonAfter = Get-Content -LiteralPath $taP7ExpireStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Test-BRAVOCondition -Condition (
            [int]$taP7ExpireResult2.SourcesDeleted -eq 1 -and
            [int]$taP7ExpireResult2.SourcesRetainedForGrace -eq 0 -and
            @($taP7ExpireSession2.State.PutFilesCalledFor).Count -eq 0 -and
            (-not (Test-Path -LiteralPath $taP7ExpireFile)) -and
            ($null -eq $taP7ExpireJsonAfter.entries.PSObject.Properties['20260904'])
        ) -Name 'TraceArchive/GraceCompletionExpiryDeletesWithoutReuploadAndClearsState' -Failure "завершення grace має видалити джерело БЕЗ повторного PutFiles і прибрати запис зі state; факт: deleted=$($taP7ExpireResult2.SourcesDeleted) putCalls=$(@($taP7ExpireSession2.State.PutFilesCalledFor).Count) stateHasEntry=$($null -ne $taP7ExpireJsonAfter.entries.PSObject.Properties['20260904'])"

        # --- E: RawSourceGraceDays=0 -> completion state НІКОЛИ не створюється (попередня поведінка).
        $taP7ZeroDir = Join-Path $traceArchiveTestRoot "grace-completion-zero\Trace"
        [void](New-Item -ItemType Directory -Path $taP7ZeroDir -Force)
        $taP7ZeroFile = Join-Path $taP7ZeroDir 'TraceSRV_20260905_090000.out'
        [IO.File]::WriteAllText($taP7ZeroFile, 'grace completion zero')
        (Get-Item -LiteralPath $taP7ZeroFile).LastWriteTime = (Get-Date).AddDays(-1)
        $taP7ZeroStatePath = Join-Path $traceArchiveTestRoot 'grace-completion-zero\state.json'
        $taP7ZeroSession = New-BRAVOSelfTestFakeBazaSession
        $taP7ZeroResult = & $traceArchiveModule {
            param($d, $z, $ap, $p, $s, $rd, $statePath)
            Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap `
                -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 `
                -Session $s -RemoteDirectory $rd -RawSourceRetentionDays 0 -GraceCompletionStatePath $statePath
        } $taP7ZeroDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taP7ZeroSession 'trace' $taP7ZeroStatePath
        Test-BRAVOCondition -Condition (
            [int]$taP7ZeroResult.SourcesDeleted -eq 1 -and
            -not (Test-Path -LiteralPath $taP7ZeroStatePath)
        ) -Name 'TraceArchive/GraceCompletionInertWhenRawSourceGraceDaysIsZero' -Failure "RawSourceRetentionDays=0 (дефолт) має видаляти джерело негайно, як раніше, і НІКОЛИ не створювати completion-state, навіть якщо шлях переданий; факт: deleted=$($taP7ZeroResult.SourcesDeleted) stateExists=$(Test-Path -LiteralPath $taP7ZeroStatePath)"

        # --- Legacy-конфіг без ключа: BRAVO_CONFIG_LOADER нормалізує в 0 (StrictMode-безпечно).
        Test-BRAVOCondition -Condition (
            $traceArchiveScriptText.Contains('$RAW_SOURCE_GRACE_DAYS = if ($MaintenanceConfig.Retention -is [System.Collections.IDictionary] -and') -and
            $traceArchiveScriptText.Contains('$MaintenanceConfig.Retention.Contains("RawSourceGraceDays")')
        ) -Name 'TraceArchive/RawSourceGraceDaysLegacyConfigDefaultsToZero' -Failure "RAW_SOURCE_GRACE_DAYS має захисно читатись через Contains-патерн (легасі-конфіг без ключа -> 0), а не прямим доступом під StrictMode"

        # ===== Узагальнений backlog: довільні basename (усі *.out) =====
        $taGenericBacklogDir = Join-Path $traceArchiveTestRoot "backlog-generic\Trace"
        [void](New-Item -ItemType Directory -Path $taGenericBacklogDir -Force)
        [IO.File]::WriteAllText((Join-Path $taGenericBacklogDir '!traceBIS_20260819_151200.out'), 'bang bis')
        [IO.File]::WriteAllText((Join-Path $taGenericBacklogDir 'TraceSRV2_20260819_152000.out'), 'srv2')
        [IO.File]::WriteAllText((Join-Path $taGenericBacklogDir 'TraceSRV_1.out'), 'legacy seq — не матчиться')
        $taGenericBacklog = & $traceArchiveModule { param($d) Get-BRAVOTraceArchiveBacklog -TraceDirectory $d } $taGenericBacklogDir
        Test-BRAVOCondition -Condition (
            @($taGenericBacklog).Count -eq 1 -and
            [string]$taGenericBacklog[0].DateKey -eq '20260819' -and
            [string]$taGenericBacklog[0].ArchiveName -eq 'Trace_20260819.mdz' -and
            @($taGenericBacklog[0].Files).Count -eq 2
        ) -Name 'TraceArchive/BacklogAcceptsArbitraryRotatedBasenames' -Failure "узагальнений патерн має захопити !traceBIS_/TraceSRV2_-ротовані файли (2 шт., одна дата) і далі ігнорувати legacy TraceSRV_1.out; отримано груп: $(@($taGenericBacklog).Count)"

        # ===== Backlog ByLastWriteTime (exchangAPI: оригінальні імена) =====
        $taExchangeBacklogDir = Join-Path $traceArchiveTestRoot "backlog-exchange\exchangAPI"
        [void](New-Item -ItemType Directory -Path $taExchangeBacklogDir -Force)
        [IO.File]::WriteAllText((Join-Path $taExchangeBacklogDir 'exchangAPI_2026-08-19_030001.log'), 'day one')
        (Get-Item -LiteralPath (Join-Path $taExchangeBacklogDir 'exchangAPI_2026-08-19_030001.log')).LastWriteTime = [datetime]'2026-08-19 03:00:01'
        [IO.File]::WriteAllText((Join-Path $taExchangeBacklogDir 'exchangAPI_2026-08-20_030002.log'), 'day two')
        (Get-Item -LiteralPath (Join-Path $taExchangeBacklogDir 'exchangAPI_2026-08-20_030002.log')).LastWriteTime = [datetime]'2026-08-20 03:00:02'
        [IO.File]::WriteAllText((Join-Path $taExchangeBacklogDir 'exchangAPI_20260818.mdz'), 'decoy archive')
        $taExchangeBacklog = & $traceArchiveModule { param($d) Get-BRAVOTraceArchiveBacklog -TraceDirectory $d -ArchiveNamePrefix 'exchangAPI' -GroupBy 'ByLastWriteTime' -FileFilter '*.log' } $taExchangeBacklogDir
        Test-BRAVOCondition -Condition (
            @($taExchangeBacklog).Count -eq 2 -and
            [string]$taExchangeBacklog[0].ArchiveName -eq 'exchangAPI_20260819.mdz' -and
            [string]$taExchangeBacklog[1].ArchiveName -eq 'exchangAPI_20260820.mdz' -and
            @($taExchangeBacklog[0].Files).Count -eq 1 -and
            [string]$taExchangeBacklog[0].Files[0].Name -eq 'exchangAPI_2026-08-19_030001.log'
        ) -Name 'TraceArchive/BacklogGroupsExchangeLogsByLastWriteDate' -Failure "ByLastWriteTime + '*.log' має дати 2 групи (за датою файла, oldest->newest) з архівами exchangAPI_YYYYMMDD.mdz і не захопити .mdz-decoy; отримано груп: $(@($taExchangeBacklog).Count)"

        # ===== e2e exchangAPI: движок пакує оригінальні імена, вантажить у
        # logs/exchangapi і видаляє джерела після верифікації =====
        $taExchangeSession = New-BRAVOSelfTestFakeBazaSession
        $taExchangeResult = & $traceArchiveModule { param($d, $z, $ap, $p, $s, $rd) Invoke-BRAVOTraceArchiveMaintenance -TraceDirectory $d -SevenZipPath $z -AddParameters $ap -ArchivePassword $p -CommandTimeoutSeconds 600 -IntegrityTimeoutSeconds 600 -Session $s -RemoteDirectory $rd -ComponentLabel 'exchangAPI' -ArchiveNamePrefix 'exchangAPI' -BacklogGroupBy 'ByLastWriteTime' -BacklogFileFilter '*.log' } $taExchangeBacklogDir $traceArchive7za $traceArchiveAddParams $traceArchivePassword $taExchangeSession 'logs/exchangapi'
        Test-BRAVOCondition -Condition (
            [int]$taExchangeResult.DatesProcessed -eq 2 -and
            [int]$taExchangeResult.ArchivesUpdated -eq 2 -and
            [int]$taExchangeResult.Uploaded -eq 2 -and
            [int]$taExchangeResult.Errors -eq 0 -and
            (Test-Path -LiteralPath (Join-Path $taExchangeBacklogDir 'exchangAPI_20260819.mdz')) -and
            (Test-Path -LiteralPath (Join-Path $taExchangeBacklogDir 'exchangAPI_20260820.mdz.sha512')) -and
            -not (Test-Path -LiteralPath (Join-Path $taExchangeBacklogDir 'exchangAPI_2026-08-19_030001.log')) -and
            $taExchangeSession.State.RemoteSizes.ContainsKey('/logs/exchangapi/exchangAPI_20260819.mdz') -and
            $taExchangeSession.State.RemoteSizes.ContainsKey('/logs/exchangapi/exchangAPI_20260820.mdz')
        ) -Name 'TraceArchive/ExchangeApiDailyArchivePipelineEndToEnd' -Failure "exchangAPI-конвеєр: 2 добові архіви створені, передані в /logs/exchangapi, джерельні .log видалені після верифікації; факт: dates=$($taExchangeResult.DatesProcessed) updated=$($taExchangeResult.ArchivesUpdated) uploaded=$($taExchangeResult.Uploaded) errors=$($taExchangeResult.Errors)"

        # ===== Міграція /trace -> /logs/trace: успіх + конфлікт + порожній =====
        $taMigrationSession = New-BRAVOSelfTestFakeBazaSession
        [void]$taMigrationSession.State.KnownRemoteDirs.Add('/trace')
        $taMigrationSession.State.RemoteSizes['/trace/Trace_20260810.mdz'] = [int64]111
        $taMigrationSession.State.RemoteSizes['/trace/Trace_20260810.mdz.sha512'] = [int64]148
        $taMigrationSession.State.RemoteSizes['/trace/unrelated.txt'] = [int64]5
        $taMigrationResult = & $traceArchiveModule { param($s) Invoke-BRAVOTraceRemoteLogMigration -Session $s -LegacyDirectory 'trace' -TargetDirectory 'logs/trace' } $taMigrationSession
        Test-BRAVOCondition -Condition (
            [int]$taMigrationResult.Attempted -eq 2 -and
            [int]$taMigrationResult.Moved -eq 2 -and
            [int]$taMigrationResult.Errors -eq 0 -and
            $taMigrationSession.State.RemoteSizes.ContainsKey('/logs/trace/Trace_20260810.mdz') -and
            $taMigrationSession.State.RemoteSizes.ContainsKey('/logs/trace/Trace_20260810.mdz.sha512') -and
            -not $taMigrationSession.State.RemoteSizes.ContainsKey('/trace/Trace_20260810.mdz') -and
            $taMigrationSession.State.RemoteSizes.ContainsKey('/trace/unrelated.txt')
        ) -Name 'TraceArchive/RemoteMigrationMovesArchivesWithVerify' -Failure "міграція має перенести .mdz+.sha512 (2 файли) у /logs/trace з верифікацією, не чіпаючи сторонній unrelated.txt; факт: attempted=$($taMigrationResult.Attempted) moved=$($taMigrationResult.Moved) errors=$($taMigrationResult.Errors)"

        $taMigrationConflictSession = New-BRAVOSelfTestFakeBazaSession
        [void]$taMigrationConflictSession.State.KnownRemoteDirs.Add('/trace')
        $taMigrationConflictSession.State.RemoteSizes['/trace/Trace_20260811.mdz'] = [int64]222
        $taMigrationConflictSession.State.RemoteSizes['/logs/trace/Trace_20260811.mdz'] = [int64]333
        $taMigrationConflictResult = & $traceArchiveModule { param($s) Invoke-BRAVOTraceRemoteLogMigration -Session $s -LegacyDirectory 'trace' -TargetDirectory 'logs/trace' } $taMigrationConflictSession
        Test-BRAVOCondition -Condition (
            [int]$taMigrationConflictResult.Conflicts -eq 1 -and
            [int]$taMigrationConflictResult.Errors -eq 1 -and
            [int]$taMigrationConflictResult.Moved -eq 0 -and
            [int64]$taMigrationConflictSession.State.RemoteSizes['/logs/trace/Trace_20260811.mdz'] -eq 333 -and
            $taMigrationConflictSession.State.RemoteSizes.ContainsKey('/trace/Trace_20260811.mdz')
        ) -Name 'TraceArchive/RemoteMigrationConflictFailsClosed' -Failure "конфлікт імені в цілі: ERROR без перезапису, legacy-файл на місці; факт: conflicts=$($taMigrationConflictResult.Conflicts) errors=$($taMigrationConflictResult.Errors) moved=$($taMigrationConflictResult.Moved)"

        $taMigrationEmptySession = New-BRAVOSelfTestFakeBazaSession
        $taMigrationEmptyResult = & $traceArchiveModule { param($s) Invoke-BRAVOTraceRemoteLogMigration -Session $s -LegacyDirectory 'trace' -TargetDirectory 'logs/trace' } $taMigrationEmptySession
        Test-BRAVOCondition -Condition (
            [int]$taMigrationEmptyResult.Attempted -eq 0 -and
            [int]$taMigrationEmptyResult.Errors -eq 0
        ) -Name 'TraceArchive/RemoteMigrationNoLegacyDirectoryIsNoop' -Failure "відсутній legacy-каталог /trace = no-op без помилок; факт: attempted=$($taMigrationEmptyResult.Attempted) errors=$($taMigrationEmptyResult.Errors)"

        # ===== Міграція legacy MODEL: archiv -> model, ConflictLevel WARNING =====
        # (5.2.1) Колізія імені при -ConflictLevel WARNING лишає файл на
        # місці БЕЗ Errors — актуальніша копія вже в цілі, статус прогону
        # не ескалюється (рішення власника; trace-семантика ERROR незмінна —
        # сценарій RemoteMigrationConflictFailsClosed вище).
        $taModelMigrationConflictSession = New-BRAVOSelfTestFakeBazaSession
        [void]$taModelMigrationConflictSession.State.KnownRemoteDirs.Add('/archiv')
        $taModelMigrationConflictSession.State.RemoteSizes['/archiv/MODEL_20260810_010000.mdz'] = [int64]444
        $taModelMigrationConflictSession.State.RemoteSizes['/archiv/MODEL_20260811_010000.mdz'] = [int64]555
        $taModelMigrationConflictSession.State.RemoteSizes['/model/MODEL_20260811_010000.mdz'] = [int64]666
        $taModelMigrationConflictResult = & $traceArchiveModule { param($s) Invoke-BRAVOTraceRemoteLogMigration -Session $s -LegacyDirectory 'archiv' -TargetDirectory 'model' -ConflictLevel 'WARNING' } $taModelMigrationConflictSession
        Test-BRAVOCondition -Condition (
            [int]$taModelMigrationConflictResult.Moved -eq 1 -and
            [int]$taModelMigrationConflictResult.Conflicts -eq 1 -and
            [int]$taModelMigrationConflictResult.Errors -eq 0 -and
            $taModelMigrationConflictSession.State.RemoteSizes.ContainsKey('/model/MODEL_20260810_010000.mdz') -and
            [int64]$taModelMigrationConflictSession.State.RemoteSizes['/model/MODEL_20260811_010000.mdz'] -eq 666 -and
            $taModelMigrationConflictSession.State.RemoteSizes.ContainsKey('/archiv/MODEL_20260811_010000.mdz')
        ) -Name 'TraceArchive/ModelRemoteMigrationConflictIsWarningNotError' -Failure "archiv->model з ConflictLevel WARNING: неконфліктний файл перенесено, колізія лишає обидві копії без Errors; факт: moved=$($taModelMigrationConflictResult.Moved) conflicts=$($taModelMigrationConflictResult.Conflicts) errors=$($taModelMigrationConflictResult.Errors)"

        # ===== Локальна міграція <BackupRoot>\ARCHIV\LIMS -> <BackupRoot>\MODEL =====
        $taLocalMigrationRoot = Join-Path ([IO.Path]::GetTempPath()) ("BRAVO_MODELMIG_SELF_TEST_{0}" -f [guid]::NewGuid().ToString('N'))
        try {
            $taLocalLegacy = Join-Path $taLocalMigrationRoot 'ARCHIV\LIMS'
            $taLocalTarget = Join-Path $taLocalMigrationRoot 'MODEL'
            [void][IO.Directory]::CreateDirectory($taLocalLegacy)
            [void][IO.Directory]::CreateDirectory($taLocalTarget)
            [IO.File]::WriteAllText((Join-Path $taLocalLegacy 'MODEL_20260810_010000.mdz'), 'legacy-a')
            [IO.File]::WriteAllText((Join-Path $taLocalLegacy 'MODEL_20260811_010000.mdz'), 'legacy-b')
            [IO.File]::WriteAllText((Join-Path $taLocalTarget 'MODEL_20260811_010000.mdz'), 'newer-copy')
            $taLocalMigrationResult = & $traceArchiveModule { param($l, $t) Invoke-BRAVOLegacyModelArchiveLocalMigration -LegacyDirectory $l -TargetDirectory $t } $taLocalLegacy $taLocalTarget
            Test-BRAVOCondition -Condition (
                [int]$taLocalMigrationResult.Moved -eq 1 -and
                [int]$taLocalMigrationResult.Conflicts -eq 1 -and
                [int]$taLocalMigrationResult.Errors -eq 0 -and
                (Test-Path (Join-Path $taLocalTarget 'MODEL_20260810_010000.mdz')) -and
                ([IO.File]::ReadAllText((Join-Path $taLocalTarget 'MODEL_20260811_010000.mdz')) -eq 'newer-copy') -and
                (Test-Path (Join-Path $taLocalLegacy 'MODEL_20260811_010000.mdz')) -and
                (Test-Path $taLocalLegacy)
            ) -Name 'TraceArchive/ModelLocalMigrationMovesAndPreservesConflicts' -Failure "локальна міграція: неконфліктний файл перенесено, колізія лишає ОБИДВІ копії без перезапису, непорожній legacy-каталог зберігається; факт: moved=$($taLocalMigrationResult.Moved) conflicts=$($taLocalMigrationResult.Conflicts) errors=$($taLocalMigrationResult.Errors)"

            # Другий прогін: конфліктний файл прибрано вручну -> каталоги
            # порожніють і видаляються (LIMS, потім батько ARCHIV).
            Remove-Item -LiteralPath (Join-Path $taLocalLegacy 'MODEL_20260811_010000.mdz') -Force
            $taLocalCleanupResult = & $traceArchiveModule { param($l, $t) Invoke-BRAVOLegacyModelArchiveLocalMigration -LegacyDirectory $l -TargetDirectory $t } $taLocalLegacy $taLocalTarget
            Test-BRAVOCondition -Condition (
                [int]$taLocalCleanupResult.Errors -eq 0 -and
                -not (Test-Path $taLocalLegacy) -and
                -not (Test-Path (Join-Path $taLocalMigrationRoot 'ARCHIV'))
            ) -Name 'TraceArchive/ModelLocalMigrationRemovesEmptiedLegacyDirs' -Failure "порожні legacy-каталоги LIMS і батько ARCHIV мають видалятись після повного переносу; факт: legacyExists=$(Test-Path $taLocalLegacy) archivExists=$(Test-Path (Join-Path $taLocalMigrationRoot 'ARCHIV'))"

            $taLocalNoopResult = & $traceArchiveModule { param($l, $t) Invoke-BRAVOLegacyModelArchiveLocalMigration -LegacyDirectory $l -TargetDirectory $t } $taLocalLegacy $taLocalTarget
            Test-BRAVOCondition -Condition (
                [int]$taLocalNoopResult.Attempted -eq 0 -and [int]$taLocalNoopResult.Errors -eq 0
            ) -Name 'TraceArchive/ModelLocalMigrationNoLegacyDirectoryIsNoop' -Failure "відсутній legacy-каталог = no-op без помилок; факт: attempted=$($taLocalNoopResult.Attempted) errors=$($taLocalNoopResult.Errors)"
        } finally {
            Remove-Item -LiteralPath $taLocalMigrationRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        # ===== Статичні контракти call-site'ів міграції MODEL у Maintenance =====
        Test-BRAVOCondition -Condition (
            $traceArchiveScriptText.Contains("[System.IO.Path]::Combine([string]`$backupRootPath, 'ARCHIV', 'LIMS')") -and
            $traceArchiveScriptText.Contains('Invoke-BRAVOLegacyModelArchiveLocalMigration') -and
            $traceArchiveScriptText.Contains("-LegacyDirectory 'archiv' ``") -and
            $traceArchiveScriptText.Contains('-TargetDirectory ([string]$sftpDirectories.MODEL) `') -and
            $traceArchiveScriptText.Contains("-ConflictLevel 'WARNING'")
        ) -Name 'TraceArchive/ModelLegacyMigrationWiredIntoMaintenance' -Failure "Maintenance має викликати локальну міграцію <BackupRoot>\ARCHIV\LIMS -> archiveDirs.Model і SFTP-міграцію archiv -> sftpDirectories.MODEL з ConflictLevel WARNING"

        # ===== Статичні гейти: dry-run PLAN-рядки + єдина реалізація =====
        $taDryRunText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_DRY_RUN.ps1'), [Text.Encoding]::UTF8)
        Test-BRAVOCondition -Condition (
            $taDryRunText.Contains('"Trace джерела"') -and
            $taDryRunText.Contains('would upload -> sftp:') -and
            $taDryRunText.Contains('would delete source .out after confirmed transfer') -and
            $taDryRunText.Contains("Get-BRAVOTraceArchiveBacklog") -and
            $taDryRunText.Contains('CompressedLogDeletionEnabled')
        ) -Name 'TraceArchive/DryRunPlansTracePipelineReadOnly' -Failure "BRAVO_DRY_RUN має PLAN-рядки Trace (джерела/would update/would upload/would delete) на КАНОНІЧНІЙ Get-BRAVOTraceArchiveBacklog і показує стан CompressedLogDeletionEnabled"

        # ===== Порожні legacy каталоги-дати видаляються негайно, незалежно
        # від віку; непорожні лишаються недоторканими для звичайного
        # age-gated Compress-OldData-шляху (регресія 2026-09, LIMS-TOP) =====
        $taEmptyDirRoot = Join-Path $traceArchiveTestRoot 'EmptyDirCleanup'
        [void](New-Item -ItemType Directory -Path $taEmptyDirRoot -Force)
        try {
            # 0 каталогів-дат: no-op, без помилок.
            $taEmptyNone = & $traceArchiveModule { param($p) Get-BRAVOEmptyLogDateDirectories -Path $p } $taEmptyDirRoot
            Test-BRAVOCondition -Condition (@($taEmptyNone).Count -eq 0) `
                -Name 'TraceArchive/EmptyDateDirNoneIsNoop' `
                -Failure "0 каталогів-дат має повертати порожній масив; отримано: $(@($taEmptyNone).Count)"

            # 1 порожній каталог-дата — з навмисно СВІЖИМ CreationTime, щоб
            # довести відсутність age-gate: видаляється незалежно від віку.
            $taEmptyFreshDir = Join-Path $taEmptyDirRoot '2026-09-01'
            [void](New-Item -ItemType Directory -Path $taEmptyFreshDir -Force)
            & $traceArchiveModule { param($p) Remove-BRAVOEmptyLogDateDirectories -Path $p -Label 'SelfTest' } $taEmptyDirRoot
            Test-BRAVOCondition -Condition (-not (Test-Path -LiteralPath $taEmptyFreshDir)) `
                -Name 'TraceArchive/EmptyDateDirDeletedRegardlessOfAge' `
                -Failure "порожній каталог-дата має видалятись негайно, незалежно від віку; факт: existst=$(Test-Path -LiteralPath $taEmptyFreshDir)"

            # 1 непорожній каталог-дата (молодий) — не чіпається.
            $taEmptyYoungNonEmptyDir = Join-Path $taEmptyDirRoot '2026-09-02'
            [void](New-Item -ItemType Directory -Path $taEmptyYoungNonEmptyDir -Force)
            [IO.File]::WriteAllText((Join-Path $taEmptyYoungNonEmptyDir 'traceBIS_000001.out'), 'stray', (New-Object Text.UTF8Encoding($false)))
            & $traceArchiveModule { param($p) Remove-BRAVOEmptyLogDateDirectories -Path $p -Label 'SelfTest' } $taEmptyDirRoot
            Test-BRAVOCondition -Condition (
                (Test-Path -LiteralPath $taEmptyYoungNonEmptyDir) -and
                (Test-Path -LiteralPath (Join-Path $taEmptyYoungNonEmptyDir 'traceBIS_000001.out'))
            ) -Name 'TraceArchive/NonEmptyYoungDateDirUntouched' `
                -Failure "непорожній молодий каталог-дата не повинен видалятись пустотним шляхом; факт: dirExists=$(Test-Path -LiteralPath $taEmptyYoungNonEmptyDir)"

            # 1 непорожній каталог-дата (старий, за retention) — теж не
            # чіпається пустотним шляхом; це завдання наявного
            # Get-BRAVOExpiredLogDateDirectories/Compress-OldData, без змін.
            $taEmptyOldNonEmptyDir = Join-Path $taEmptyDirRoot '2026-08-01'
            [void](New-Item -ItemType Directory -Path $taEmptyOldNonEmptyDir -Force)
            [IO.File]::WriteAllText((Join-Path $taEmptyOldNonEmptyDir 'traceBIS_000001.out'), 'stray-old', (New-Object Text.UTF8Encoding($false)))
            (Get-Item -LiteralPath $taEmptyOldNonEmptyDir).CreationTime = (Get-Date).AddDays(-30)
            & $traceArchiveModule { param($p) Remove-BRAVOEmptyLogDateDirectories -Path $p -Label 'SelfTest' } $taEmptyDirRoot
            $taEmptyOldExpired = & $traceArchiveModule { param($p) Get-BRAVOExpiredLogDateDirectories -Path $p -RetentionDays 14 } $taEmptyDirRoot
            Test-BRAVOCondition -Condition (
                (Test-Path -LiteralPath $taEmptyOldNonEmptyDir) -and
                @(@($taEmptyOldExpired) | Where-Object { $_.Name -eq '2026-08-01' }).Count -eq 1
            ) -Name 'TraceArchive/NonEmptyOldDateDirRemainsForAgeGatedPath' `
                -Failure "непорожній старий каталог-дата не повинен видалятись пустотним шляхом і має лишатись видимим для Get-BRAVOExpiredLogDateDirectories (Compress-OldData); факт: dirExists=$(Test-Path -LiteralPath $taEmptyOldNonEmptyDir)"
        } finally {
            Remove-Item -LiteralPath $taEmptyDirRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        # ===== PR #136 review (P2-2/P2-3): best-effort enumeration та
        # структурований cleanup-результат =====
        # EnumerateFileSystemInfos() може кинути виняток (ACL, зникнення
        # каталогу паралельним процесом) — БЕЗ per-candidate try/catch це
        # вилітало б з усього Get-BRAVOEmptyLogDateDirectories назовні й
        # перетворювало best-effort cleanup на critical failure всього
        # Maintenance. Два "реалістичних" підходи емпірично відкинуто
        # окремими репро на цьому середовищі self-test: Deny-ACL (навіть
        # Deny FullControl) НЕ блокує enumerate для локального
        # адміністратора тут, а reparse-точки (mklink /J)
        # Get-BRAVODirectories взагалі відфільтровує на вході (ніколи не
        # стають candidate). Натомість — $script:taP2VanishAfterDiscoveryPath
        # (гак у test-only Get-BRAVODirectories-стабі вище): синхронно й
        # детерміновано видаляє candidate ПІСЛЯ реального сканування
        # каталогу, але ДО per-candidate EnumerateFileSystemInfos() —
        # відтворює РЕАЛЬНИЙ DirectoryNotFoundException без потоків/сну.
        $taP2Root = Join-Path $traceArchiveTestRoot 'P2EnumerationSafety'
        [void](New-Item -ItemType Directory -Path $taP2Root -Force)
        $taP2VanishingDir = Join-Path $taP2Root '2026-09-03'
        $taP2ValidEmptyDir = Join-Path $taP2Root '2026-09-04'
        [void](New-Item -ItemType Directory -Path $taP2VanishingDir -Force)
        [void](New-Item -ItemType Directory -Path $taP2ValidEmptyDir -Force)
        try {
            # Get-BRAVOEmptyLogDateDirectories: candidate, що зникає між
            # скануванням і enumeration, НЕ потрапляє в результат
            # (непідтверджена порожнеча — не видаляти), валідний
            # candidate обробляється штатно.
            $taP2GetResult = @(& $traceArchiveModule {
                param($p, $l, $vanishPath)
                $script:taP2VanishAfterDiscoveryPath = $vanishPath
                try { Get-BRAVOEmptyLogDateDirectories -Path $p -Label $l }
                finally { $script:taP2VanishAfterDiscoveryPath = $null }
            } $taP2Root 'P2Test' $taP2VanishingDir)
            Test-BRAVOCondition -Condition (
                $taP2GetResult.Count -eq 1 -and
                $taP2GetResult[0].Name -eq '2026-09-04' -and
                (-not (Test-Path -LiteralPath $taP2VanishingDir))
            ) -Name 'TraceArchive/EmptyDateDirEnumerationErrorSkipsCandidateNotOthers' `
                -Failure "candidate, що зник між скануванням і enumeration, не повинен потрапляти в результат, а валідний порожній сусід — має; отримано: $($taP2GetResult.Name -join ', ')"

            # Відновлюємо candidate для наступного (Remove-) виклику —
            # той сам відтворює той самий сценарій зникнення заново.
            [void](New-Item -ItemType Directory -Path $taP2VanishingDir -Force)

            # Remove-BRAVOEmptyLogDateDirectories: структурований результат
            # (P2-3) — 1 валідний candidate видалено, зниклий/непідтверджений
            # не намагається видалятись повторно (і вже відсутній на диску).
            $taP2RemoveResult = & $traceArchiveModule {
                param($p, $l, $vanishPath)
                $script:taP2VanishAfterDiscoveryPath = $vanishPath
                try { Remove-BRAVOEmptyLogDateDirectories -Path $p -Label $l }
                finally { $script:taP2VanishAfterDiscoveryPath = $null }
            } $taP2Root 'P2Test' $taP2VanishingDir
            Test-BRAVOCondition -Condition (
                $taP2RemoveResult.CandidateCount -eq 1 -and
                $taP2RemoveResult.DeletedCount -eq 1 -and
                $taP2RemoveResult.DeletedPaths.Count -eq 1 -and
                (-not (Test-Path -LiteralPath $taP2ValidEmptyDir)) -and
                (-not (Test-Path -LiteralPath $taP2VanishingDir))
            ) -Name 'TraceArchive/RemoveEmptyDateDirReturnsStructuredResultAndSkipsUnconfirmed' `
                -Failure "структурований результат мусить показувати CandidateCount=1/DeletedCount=1 (лише валідний candidate); факт: Candidate=$($taP2RemoveResult.CandidateCount) Deleted=$($taP2RemoveResult.DeletedCount) vanishedExists=$(Test-Path -LiteralPath $taP2VanishingDir) validExists=$(Test-Path -LiteralPath $taP2ValidEmptyDir)"

            # P2-2/P2-3: повний структурований контракт розрізняє
            # DiscoveredCandidates (2: зниклий + валідний)/ConfirmedEmpty
            # (1)/Deleted (1)/EnumerationWarnings (1, зниклий)/
            # DeletionWarnings (0, видалення валідного пройшло без
            # помилок) — обидва типи warnings НЕ змішуються в один
            # недиференційований лічильник.
            Test-BRAVOCondition -Condition (
                $taP2RemoveResult.DiscoveredCandidates -eq 2 -and
                $taP2RemoveResult.ConfirmedEmpty -eq 1 -and
                $taP2RemoveResult.Deleted -eq 1 -and
                $taP2RemoveResult.EnumerationWarnings -eq 1 -and
                $taP2RemoveResult.DeletionWarnings -eq 0 -and
                $taP2RemoveResult.WarningCount -eq 1
            ) -Name 'TraceArchive/RemoveEmptyDateDirDistinguishesEnumerationFromDeletionWarnings' `
                -Failure "результат має розрізняти DiscoveredCandidates/ConfirmedEmpty/Deleted/EnumerationWarnings/DeletionWarnings; факт: Discovered=$($taP2RemoveResult.DiscoveredCandidates) Confirmed=$($taP2RemoveResult.ConfirmedEmpty) Deleted=$($taP2RemoveResult.Deleted) EnumWarn=$($taP2RemoveResult.EnumerationWarnings) DelWarn=$($taP2RemoveResult.DeletionWarnings)"
        } finally {
            Remove-Item -LiteralPath $taP2Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        # P2-3: якщо ЄДИНОЮ реальною роботою циклу очистки було видалення
        # вже спорожнілого legacy-каталогу-дати, підсумковий статус НЕ
        # повинен бути SKIPPED/«даних для очищення немає» — Maintenance
        # тепер враховує DeletedCount у $hasDataToClean і в Details.
        Test-BRAVOCondition -Condition (
            $traceArchiveScriptText.Contains('$emptyLogDateDirDeletedCount = 0') -and
            $traceArchiveScriptText -match (
                '(?s)\$hasDataToClean = \$hasDataToClean -or.*?\(\$emptyLogDateDirDeletedCount -gt 0\)'
            ) -and
            $traceArchiveScriptText.Contains("`$cleanupDetailParts += `"порожніх legacy-каталогів видалено: `$emptyLogDateDirDeletedCount`"")
        ) -Name 'TraceArchive/EmptyDateDirDeletionCountsTowardCleanupSummary' `
            -Failure 'Maintenance мусить враховувати DeletedCount видалення порожніх legacy-каталогів у $hasDataToClean і в тексті Details підсумку очистки — інакше цикл, що реально видалив каталоги, звітує SKIPPED'

        # P2-2/P2-3: обидва типи best-effort warnings (enumeration/
        # deletion) мають окремо потрапляти в текст Details підсумку
        # очистки — раніше $emptyLogDateDirWarningCount накопичувався,
        # але НІКОЛИ не показувався оператору.
        Test-BRAVOCondition -Condition (
            $traceArchiveScriptText.Contains('$emptyLogDateDirEnumerationWarningCount = 0') -and
            $traceArchiveScriptText.Contains('$emptyLogDateDirDeletionWarningCount = 0') -and
            $traceArchiveScriptText.Contains("`$cleanupDetailParts += `"не вдалося підтвердити порожнечу каталогів: `$emptyLogDateDirEnumerationWarningCount`"") -and
            $traceArchiveScriptText.Contains("`$cleanupDetailParts += `"не вдалося видалити порожні каталоги: `$emptyLogDateDirDeletionWarningCount`"")
        ) -Name 'TraceArchive/EmptyDateDirWarningsSurfacedInCleanupSummary' `
            -Failure 'Обидва типи best-effort warnings (enumeration/deletion) мають зʼявлятись у тексті Details підсумку очистки, а не лише мовчки накопичуватись'

        # Trace обробляється ВИКЛЮЧНО Maintenance: жодного окремого
        # Scheduled Task для Trace (ТЗ §43).
        $taTasksInstallText = [IO.File]::ReadAllText((Join-Path $root 'BRAVO_TASKS_INSTALL.ps1'), [Text.Encoding]::UTF8)
        Test-BRAVOCondition -Condition (
            $taTasksInstallText -notmatch '(?i)BRAVO_TRACE' -and
            $taTasksInstallText -notmatch '(?i)TRACE_ROTATE|TRACE_UPLOAD'
        ) -Name 'TraceArchive/NoDedicatedTraceScheduledTask' -Failure "BRAVO_TASKS_INSTALL не повинен створювати окремих Trace-тасків — Trace обробляє лише BRAVO_MAINTENANCE"
    } finally {
        if (-not [string]::IsNullOrWhiteSpace([string]$traceArchiveTestRoot) -and (Test-Path -LiteralPath $traceArchiveTestRoot)) {
            Remove-Item -LiteralPath $traceArchiveTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
