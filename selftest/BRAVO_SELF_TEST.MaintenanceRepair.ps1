# Домен-фрагмент self-test: false-positive rollback після bravocmd repair +
# Discord HTTP 429 retry (fix/repair-rollback-false-positive-and-discord-429).
#
# Compare-FileSizes: реальна ізольована AST-екстракція runtime-функції
# (не симуляція) з двома РІЗНИМИ generic назвами моделі (TestProject,
# AnotherProject42) — жодна з них не lims/VetOffice, щоб виключити
# випадковий hardcode. Send-BRAVOWebhookNotification: реальна екстракція з
# BRAVO.Compatibility.psm1 із застабованим Invoke-WebRequest (перша спроба
# такого стабу в цьому репозиторії — прецеденту немає).
#
# Dot-sourced з кореневого BRAVO_SELF_TEST.ps1 — НЕ запускається напряму.
# Успадковує з викликача: $root, Test-BRAVOCondition,
# New-BRAVOSelfTestRuntimeModule, $script:failures.

$maintenanceRepairScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)

Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
Import-Module -Name (Join-Path $root "modules\BRAVO.Notifications\BRAVO.Notifications.psd1") -Force -ErrorAction Stop

# ============================================================
# MODEL-контракт: похідні MODEL_NAME/MAIN_MODEL_FILE, без hardcode.
# ============================================================
Test-BRAVOCondition `
    -Condition $maintenanceRepairScriptText.Contains(
        '$MODEL_NAME = Split-Path -Path $MODEL_PROJECT_PATH -Leaf'
    ) `
    -Name "Maintenance/ModelNameDerivedNotHardcoded" `
    -Failure "MODEL_NAME має бути похідним від MODEL_PROJECT_PATH (значення MODEL= з bravo.ini), а не hardcoded назвою проєкту"
Test-BRAVOCondition `
    -Condition $maintenanceRepairScriptText.Contains(
        '$MAIN_MODEL_FILE = "$MODEL_PROJECT_PATH.md"'
    ) `
    -Name "Maintenance/MainModelFileDerivedNotHardcoded" `
    -Failure "MAIN_MODEL_FILE має бути похідним (MODEL_PROJECT_PATH + '.md'), а не hardcoded шляхом на кшталт Model\lims.md/Model\VetOffice.md"
Test-BRAVOCondition `
    -Condition (
        -not ($maintenanceRepairScriptText -match '\$MODEL_NAME\s*=\s*"(?!.*MODEL_PROJECT_PATH)') -and
        -not ($maintenanceRepairScriptText -match '\$MAIN_MODEL_FILE\s*=\s*"(?!\$MODEL_PROJECT_PATH)')
    ) `
    -Name "Maintenance/NoHardcodedModelNameLiteral" `
    -Failure "MODEL_NAME/MAIN_MODEL_FILE не повинні мати альтернативного hardcoded присвоєння літералом"

# Split-Path/конкатенація — та сама семантика, що виробничий код, для двох
# РІЗНИХ generic назв (жодна не lims/VetOffice) — перевіряє відсутність
# cross-scenario bleed.
$modelContractScenarios = @(
    @{ Base = 'C:\Sandbox\Model\TestProject'; ExpectedName = 'TestProject'; ExpectedMain = 'C:\Sandbox\Model\TestProject.md' }
    @{ Base = 'E:\BRAVO\Model\AnotherProject42'; ExpectedName = 'AnotherProject42'; ExpectedMain = 'E:\BRAVO\Model\AnotherProject42.md' }
)
foreach ($scenario in $modelContractScenarios) {
    $derivedName = Split-Path -Path $scenario.Base -Leaf
    $derivedMain = "$($scenario.Base).md"
    Test-BRAVOCondition `
        -Condition ($derivedName -eq $scenario.ExpectedName -and $derivedMain -eq $scenario.ExpectedMain) `
        -Name "Maintenance/ModelContractDerivation[$($scenario.ExpectedName)]" `
        -Failure "MODEL_NAME/MAIN_MODEL_FILE для '$($scenario.Base)' мають бути '$($scenario.ExpectedName)'/'$($scenario.ExpectedMain)'; отримано '$derivedName'/'$derivedMain'"
}

# ============================================================
# Compare-FileSizes: RemovedByRepair vs CRITICAL класифікація.
# ============================================================
$compareFileSizesStubText = @'
function Write-Log {
    param($Message, [string]$Level = 'INFO')
    if ($null -eq (Get-Variable -Name BRAVOCapturedLogMessages -Scope Script -ErrorAction SilentlyContinue)) {
        $script:BRAVOCapturedLogMessages = New-Object System.Collections.ArrayList
    }
    [void]$script:BRAVOCapturedLogMessages.Add([string]$Message)
}
function Send-SlackAlert {
    param($Message, [switch]$IsCritical)
    if ($null -eq (Get-Variable -Name BRAVOCapturedAlerts -Scope Script -ErrorAction SilentlyContinue)) {
        $script:BRAVOCapturedAlerts = New-Object System.Collections.ArrayList
    }
    [void]$script:BRAVOCapturedAlerts.Add([string]$Message)
}
function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }
function Format-BRAVOUkrainianCount { BRAVO.Notifications\Format-BRAVOUkrainianCount @args }
function Format-BRAVONotificationListSummary { BRAVO.Notifications\Format-BRAVONotificationListSummary @args }
'@
$compareFileSizesModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($compareFileSizesStubText + "`n" + $maintenanceRepairScriptText) `
    -FunctionNames @('Write-Log', 'Send-SlackAlert', 'Get-BRAVOFiles', 'Format-FileSize', 'Get-BRAVOModelRelativePath', 'Format-BRAVOUkrainianCount', 'Format-BRAVONotificationListSummary', 'New-BRAVOCompareFileSizesResult', 'Compare-FileSizes')

function Invoke-BRAVOCompareFileSizesScenario {
    param(
        [Parameter(Mandatory = $true)][hashtable]$BeforeFiles,
        [Parameter(Mandatory = $true)][hashtable]$AfterFiles,
        [string]$MainModelRelativePath,
        # Реальний інцидент (ДНДІЛДВСЕ, 2026-08-25): bravo.ini MODEL= містить
        # шлях з іншим регістром (мала літера диска), ніж нормалізований
        # FullName від Get-ChildItem. Перемикач передає Compare-FileSizes
        # той самий каталог, але з повністю зміненим регістром рядка шляху —
        # Windows-резолюція шляху ідентична, відрізняється лише рядок.
        [switch]$InvertModelPathCase,
        # Settle-retry: юніт-сценарії детерміністичні, retry їм не потрібен —
        # 1 спроба без затримки, інакше кожен critical-сценарій чекав би
        # production-бюджет 12×15с. Окремі settle-регресії нижче передають
        # власні значення.
        [int]$MaxSettleAttempts = 1,
        [int]$SettleDelaySeconds = 0,
        # Відкладене створення файлу під час прогону (симуляція AV-затримки
        # видимості): ScriptBlock запускається Start-Job-ом ДО виклику
        # Compare-FileSizes і створює файл у $ScenarioRoot із паузою.
        [scriptblock]$DelayedFileJob
    )
    $scenarioRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("BRAVO_COMPAREFILESIZES_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($scenarioRoot)
    $effectiveModelPath = if ($InvertModelPathCase) {
        # ToLowerInvariant дає той самий каталог, але інший РЯДОК шляху:
        # літера диска й компоненти на кшталт Users/AppData/Temp стають
        # малими, тоді як enumeration у Compare-FileSizes (тепер прямий
        # [IO.DirectoryInfo]::EnumerateFiles) повертає FullName з фактичним
        # регістром дочірніх компонентів — регістровий розсинхрон кореня
        # лишається точною сигнатурою інциденту, яку канонічно знімає
        # Get-BRAVOModelRelativePath (OrdinalIgnoreCase).
        $scenarioRoot.ToLowerInvariant()
    } else {
        $scenarioRoot
    }
    try {
        foreach ($relativePath in $AfterFiles.Keys) {
            $fullPath = Join-Path $scenarioRoot $relativePath
            [void][IO.Directory]::CreateDirectory((Split-Path -Path $fullPath -Parent))
            $sizeBytes = [int64]$AfterFiles[$relativePath]
            [IO.File]::WriteAllBytes($fullPath, (New-Object byte[] $sizeBytes))
        }
        $beforeCsvPath = Join-Path $scenarioRoot '__before_sizes.csv'
        $beforeRows = @($BeforeFiles.Keys | ForEach-Object {
            [PSCustomObject]@{ RelativePath = $_; SizeBytes = [int64]$BeforeFiles[$_] }
        })
        $beforeRows | Export-Csv -Path $beforeCsvPath -NoTypeInformation -Encoding UTF8

        $delayedJob = $null
        if ($null -ne $DelayedFileJob) {
            $delayedJob = Start-Job -ScriptBlock $DelayedFileJob -ArgumentList $scenarioRoot
            # Холодний старт Start-Job (окремий powershell.exe) на
            # завантаженій машині може тривати довше за все retry-вікно —
            # реальний прогін показав старт job-а ПІСЛЯ завершення всіх
            # спроб. Тому job СПОЧАТКУ пише ready-маркер, а сценарій чекає
            # його ДО виклику Compare-FileSizes: гонка «cold start проти
            # retry-вікна» виключена, лишається лише детермінована
            # затримка появи файлу.
            $jobReadyMarker = Join-Path $scenarioRoot '__job_ready.marker'
            $jobReadyDeadline = (Get-Date).AddSeconds(60)
            while (-not (Test-Path -LiteralPath $jobReadyMarker) -and (Get-Date) -lt $jobReadyDeadline) {
                Start-Sleep -Milliseconds 200
            }
        }
        try {
            return & $compareFileSizesModule {
                param($BeforeFile, $ModelPath, $MainModelRelativePath, $MaxSettleAttempts, $SettleDelaySeconds)
                Set-StrictMode -Version Latest
                Compare-FileSizes -BeforeFile $BeforeFile -ModelPath $ModelPath -MinSizeBytes 2048 `
                    -MainModelRelativePath $MainModelRelativePath `
                    -MaxSettleAttempts $MaxSettleAttempts -SettleDelaySeconds $SettleDelaySeconds
            } $beforeCsvPath $effectiveModelPath $MainModelRelativePath $MaxSettleAttempts $SettleDelaySeconds
        } finally {
            if ($null -ne $delayedJob) {
                Wait-Job -Job $delayedJob -Timeout 30 | Out-Null
                Remove-Job -Job $delayedJob -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        if (Test-Path -LiteralPath $scenarioRoot) {
            Remove-Item -LiteralPath $scenarioRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- TestProject: 0 RemovedByRepair (нічого не зникло) -> НЕ критично.
$resultZeroRemoved = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultZeroRemoved.HasCriticalChanges -and $resultZeroRemoved.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesZeroRemovedByRepair" `
    -Failure "без жодного зниклого файлу HasCriticalChanges має бути false, RemovedByRepairCount=0"

# --- TestProject: 1 сегментний файл прибрано repair -> RemovedByRepair=1,
# НЕ критично (це і є root cause фікса: bravocmd штатно перебудовує сегменти).
$resultOneRemoved = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultOneRemoved.HasCriticalChanges -and $resultOneRemoved.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesOneRemovedByRepairNotCritical" `
    -Failure "сегментний файл, прибраний repair-ом, НЕ повинен бути CRITICAL; отримано HasCriticalChanges=$($resultOneRemoved.HasCriticalChanges), RemovedByRepairCount=$($resultOneRemoved.RemovedByRepairCount)"

# --- AnotherProject42: N=3 сегментних файли прибрано repair -> RemovedByRepair=3.
$resultManyRemoved = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'AnotherProject42.md' = 500000; 'ASSORT.000' = 100000; 'ASSORT.002' = 100000; 'classifier.003' = 100000 } `
    -AfterFiles  @{ 'AnotherProject42.md' = 500000 } `
    -MainModelRelativePath 'AnotherProject42.md'
Test-BRAVOCondition `
    -Condition (-not $resultManyRemoved.HasCriticalChanges -and $resultManyRemoved.RemovedByRepairCount -eq 3) `
    -Name "Maintenance/CompareFileSizesManyRemovedByRepairNotCritical" `
    -Failure "три сегментних файли, прибрані repair-ом, НЕ повинні бути CRITICAL; отримано HasCriticalChanges=$($resultManyRemoved.HasCriticalChanges), RemovedByRepairCount=$($resultManyRemoved.RemovedByRepairCount)"

# --- AnotherProject42: існуючий (не основний) файл схлопнувся 50MB -> 2048b
# -> CRITICAL незалежно від назви файлу.
$resultCollapsed = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'AnotherProject42.md' = 500000; 'SAMPLE.000' = 52428800 } `
    -AfterFiles  @{ 'AnotherProject42.md' = 500000; 'SAMPLE.000' = 2048 } `
    -MainModelRelativePath 'AnotherProject42.md'
Test-BRAVOCondition `
    -Condition ($resultCollapsed.HasCriticalChanges -and @($resultCollapsed.CriticalFiles).Count -eq 1) `
    -Name "Maintenance/CompareFileSizesExistingFileCollapseCritical" `
    -Failure "файл, що схлопнувся з 50MB до 2048 байт, має лишатись CRITICAL незалежно від того, що це не основна модель"

# --- TestProject: основна модель ВІДСУТНЯ після repair -> CRITICAL.
$resultMainMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultMainMissing.HasCriticalChanges -and -not $resultMainMissing.MainModelValid) `
    -Name "Maintenance/CompareFileSizesMainModelMissingCritical" `
    -Failure "відсутність основної моделі після repair має бути CRITICAL (MainModelValid=false), навіть якщо MainModelRelativePath переданий"

# --- TestProject: основна модель <= 2048 байт після repair -> CRITICAL.
$resultMainTiny = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 100; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultMainTiny.HasCriticalChanges -and -not $resultMainTiny.MainModelValid) `
    -Name "Maintenance/CompareFileSizesMainModelTinyCritical" `
    -Failure "основна модель розміром <=2048 байт після repair має бути CRITICAL"

# --- AnotherProject42: каталог MODEL порожній після repair -> CRITICAL
# (defense-in-depth, окремо від per-file циклу).
$resultEmptyDirectory = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'AnotherProject42.md' = 500000; 'ASSORT.000' = 100000 } `
    -AfterFiles  @{} `
    -MainModelRelativePath 'AnotherProject42.md'
Test-BRAVOCondition `
    -Condition ($resultEmptyDirectory.HasCriticalChanges -and -not $resultEmptyDirectory.MainModelValid) `
    -Name "Maintenance/CompareFileSizesEmptyModelDirectoryCritical" `
    -Failure "порожній каталог MODEL після repair має бути CRITICAL незалежно від per-file порівняння"

# --- Fail-closed без MainModelRelativePath: будь-який зниклий файл лишається
# критичним (виклик, що не зміг визначити основну модель, не повинен
# випадково стати менш безпечним).
$resultNoMainModelKnown = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath $null
Test-BRAVOCondition `
    -Condition $resultNoMainModelKnown.HasCriticalChanges `
    -Name "Maintenance/CompareFileSizesFailClosedWithoutMainModelHint" `
    -Failure "без MainModelRelativePath (викликач не зміг визначити основну модель) будь-який зниклий файл має лишатись критичним — стара fail-closed поведінка"

# --- Hint передано, але його НЕМАЄ у before-CSV + зник сегментний файл ->
# строгий fallback: CRITICAL. Без fallback хибний hint мовчки перетворював
# би ВСІ зниклі файли на RemovedByRepair і знищена модель проходила б
# валідацію без rollback (F1).
$resultHintMismatchMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'OtherName.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'OtherName.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultHintMismatchMissing.HasCriticalChanges -and $resultHintMismatchMissing.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesHintNotInInventoryStrictFallback" `
    -Failure "hint, відсутній у before-інвентаризації, має вмикати строгий режим: зниклий файл = CRITICAL, а не RemovedByRepair; отримано HasCriticalChanges=$($resultHintMismatchMissing.HasCriticalChanges), RemovedByRepairCount=$($resultHintMismatchMissing.RemovedByRepairCount)"

# --- Hint відсутній у before-CSV, але ЖОДЕН файл не зник -> НЕ критично
# (строгий fallback сам по собі не породжує false-positive).
$resultHintMismatchNothingMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'OtherName.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'OtherName.md' = 500000; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultHintMismatchNothingMissing.HasCriticalChanges) `
    -Name "Maintenance/CompareFileSizesHintNotInInventoryNoFalsePositive" `
    -Failure "строгий fallback через хибний hint не повинен давати CRITICAL, коли жоден файл не зник і розміри не змінилися"

# --- Реальна сигнатура інциденту (звіт оператора): .md ІСНУЄ, але
# обнулений (0 байт) -> CRITICAL, MainModelValid=false (isCriticalReduction:
# current 0 <= 2048 при initial > 2048).
$resultMainZeroed = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 0; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultMainZeroed.HasCriticalChanges -and -not $resultMainZeroed.MainModelValid) `
    -Name "Maintenance/CompareFileSizesMainModelZeroedCritical" `
    -Failure "обнулена основна модель (0 байт, файл існує) має бути CRITICAL з MainModelValid=false — фактична сигнатура реального пошкодження"

# --- MODEL= у підкаталозі: hint із відносним підшляхом збігається з
# RelativePath before-CSV -> зниклий сегмент лишається RemovedByRepair,
# НЕ критичний (нова деривація від MAIN_MODEL_FILE, а не "$MODEL_NAME.md").
$resultSubdirHint = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'sub\TestProject.md' = 500000; 'sub\ACT.000' = 100000 } `
    -AfterFiles  @{ 'sub\TestProject.md' = 500000 } `
    -MainModelRelativePath 'sub\TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultSubdirHint.HasCriticalChanges -and $resultSubdirHint.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesSubdirectoryHintMatches" `
    -Failure "hint з підкаталогом ('sub\TestProject.md') має збігатися з RelativePath before-CSV: зниклий сегмент = RemovedByRepair, не CRITICAL; отримано HasCriticalChanges=$($resultSubdirHint.HasCriticalChanges), RemovedByRepairCount=$($resultSubdirHint.RemovedByRepairCount)"

# --- Реальна сигнатура провальної реставрації (звіт оператора): .md був
# ~2GB, після repair став 2KB -> CRITICAL, MainModelValid=false. Ловиться
# обома правилами незалежно: current <= MinSizeBytes(2048) і редукція >=50%.
# 2GB перевіряє також [long]-семантику розмірів (понад [int32]::MaxValue).
$resultMainCollapsed2Gb = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 2147483648; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 2048; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultMainCollapsed2Gb.HasCriticalChanges -and -not $resultMainCollapsed2Gb.MainModelValid) `
    -Name "Maintenance/CompareFileSizesMainModel2GbCollapsedTo2KbCritical" `
    -Failure "основна модель 2GB, що схлопнулась до 2KB після repair, має бути CRITICAL з MainModelValid=false — фактична сигнатура провальної реставрації; отримано HasCriticalChanges=$($resultMainCollapsed2Gb.HasCriticalChanges), MainModelValid=$($resultMainCollapsed2Gb.MainModelValid)"

# --- Та сама сигнатура для НЕ-main файлу > 1GB (звіт оператора: таке
# трапляється і з іншими великими файлами, не лише основною моделлю):
# 1.5GB -> 2KB -> CRITICAL незалежно від імені файлу.
$resultNonMainCollapsed1Gb = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'PROCRSRCH.md' = 1610612736 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'PROCRSRCH.md' = 2048 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultNonMainCollapsed1Gb.HasCriticalChanges -and @($resultNonMainCollapsed1Gb.CriticalFiles).Count -eq 1) `
    -Name "Maintenance/CompareFileSizesNonMainOver1GbCollapsedTo2KbCritical" `
    -Failure "не-main файл >1GB, що схлопнувся до 2KB після repair, має бути CRITICAL незалежно від імені; отримано HasCriticalChanges=$($resultNonMainCollapsed1Gb.HasCriticalChanges), CriticalFiles=$(@($resultNonMainCollapsed1Gb.CriticalFiles).Count)"

# --- Зниклий НЕ-main .md при коректному hint -> CRITICAL. За трасуванням
# реального bravocmd repair перебудовуються лише сегментні файли (.NNN);
# .md ніколи не видаляються. lims0.md/lims1.md — продовження основної
# моделі, табличні DEPART.md тощо — дані; їхнє зникнення = втрата даних.
$resultNonMainMdMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'TestProject0.md' = 300000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultNonMainMdMissing.HasCriticalChanges -and $resultNonMainMdMissing.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesNonMainMdMissingCritical" `
    -Failure "зниклий не-main .md (TestProject0.md — продовження моделі) має бути CRITICAL, не RemovedByRepair; отримано HasCriticalChanges=$($resultNonMainMdMissing.HasCriticalChanges), RemovedByRepairCount=$($resultNonMainMdMissing.RemovedByRepairCount)"

# --- Зниклий файл ієрархії (.h1) при коректному hint -> CRITICAL.
$resultHierMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'TestProject.h1' = 50000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultHierMissing.HasCriticalChanges -and $resultHierMissing.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesHierarchyFileMissingCritical" `
    -Failure "зниклий файл ієрархії (.h1) має бути CRITICAL, не RemovedByRepair"

# --- Змішаний кейс: зник сегмент .000 (штатно) І зник DEPART.md (втрата
# даних) -> CRITICAL, при цьому сегмент коректно лишається у RemovedByRepair.
$resultMixedMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'AnotherProject42.md' = 500000; 'DEPART.md' = 200000; 'ASSORT.000' = 100000 } `
    -AfterFiles  @{ 'AnotherProject42.md' = 500000 } `
    -MainModelRelativePath 'AnotherProject42.md'
Test-BRAVOCondition `
    -Condition ($resultMixedMissing.HasCriticalChanges -and $resultMixedMissing.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesMixedMissingSegmentAndMd" `
    -Failure "змішаний кейс: DEPART.md = CRITICAL, ASSORT.000 = RemovedByRepair(1); отримано HasCriticalChanges=$($resultMixedMissing.HasCriticalChanges), RemovedByRepairCount=$($resultMixedMissing.RemovedByRepairCount)"

# --- Зниклий .$$$ (тимчасовий робочий файл bravocmd, залишок перерваного
# repair) -> RemovedByRepair, НЕ критично: як і .NNN-сегменти, це транзитний
# артефакт, а не дані. Інакше orphan .$$$ давав би false-positive rollback.
$resultTempMissing = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'KZPpat.$$$' = 155273552 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition (-not $resultTempMissing.HasCriticalChanges -and $resultTempMissing.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesTempDollarFileNotCritical" `
    -Failure "зниклий .`$`$`$ (temp bravocmd) має бути RemovedByRepair, не CRITICAL; отримано HasCriticalChanges=$($resultTempMissing.HasCriticalChanges), RemovedByRepairCount=$($resultTempMissing.RemovedByRepairCount)"

# --- Змішаний: зник .$$$ (temp, не критично) + зник .md (дані, критично)
# -> CRITICAL, а .$$$ лишається у RemovedByRepair.
$resultTempAndMd = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'DEPART.md' = 200000; 'KZPpat.$$$' = 148000000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
Test-BRAVOCondition `
    -Condition ($resultTempAndMd.HasCriticalChanges -and $resultTempAndMd.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesTempDollarPlusMdMixed" `
    -Failure "змішаний: DEPART.md = CRITICAL, KZPpat.`$`$`$ = RemovedByRepair(1); отримано HasCriticalChanges=$($resultTempAndMd.HasCriticalChanges), RemovedByRepairCount=$($resultTempAndMd.RemovedByRepairCount)"

# --- Регресія реального інциденту (ДНДІЛДВСЕ, 2026-08-25, exit 43):
# bravo.ini MODEL= з малою літерою диска ("d:\LIMS\Model"), Get-ChildItem
# нормалізує FullName до "D:\...", ordinal Replace НЕ зрізав корінь, ключі
# lookup ставали абсолютними шляхами і ВСІ 546 файлів before-CSV оголошувались
# відсутніми (364 CRITICAL + 182 RemovedByRepair) навіть одразу після
# успішного rollback. Той самий каталог, змінено лише регістр рядка шляху ->
# нічого не зникло -> НЕ критично.
$resultRootCaseMismatch = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md' `
    -InvertModelPathCase
Test-BRAVOCondition `
    -Condition (-not $resultRootCaseMismatch.HasCriticalChanges -and $resultRootCaseMismatch.RemovedByRepairCount -eq 0) `
    -Name "Maintenance/CompareFileSizesRootCaseInsensitive" `
    -Failure "ModelPath з іншим регістром (той самий каталог) не повинен перетворювати всі файли на 'відсутні': HasCriticalChanges має бути false; отримано HasCriticalChanges=$($resultRootCaseMismatch.HasCriticalChanges), RemovedByRepairCount=$($resultRootCaseMismatch.RemovedByRepairCount), CriticalFiles=$(@($resultRootCaseMismatch.CriticalFiles).Count)"

# --- Той самий регістровий розсинхрон + штатно зниклий сегмент: класифікація
# RemovedByRepair/critical має працювати ідентично незалежно від регістру кореня.
$resultRootCaseMismatchSegment = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md' `
    -InvertModelPathCase
Test-BRAVOCondition `
    -Condition (-not $resultRootCaseMismatchSegment.HasCriticalChanges -and $resultRootCaseMismatchSegment.RemovedByRepairCount -eq 1) `
    -Name "Maintenance/CompareFileSizesRootCaseInsensitiveSegmentRemoved" `
    -Failure "при регістровому розсинхроні кореня зниклий сегмент .000 має класифікуватись RemovedByRepair(1), не CRITICAL; отримано HasCriticalChanges=$($resultRootCaseMismatchSegment.HasCriticalChanges), RemovedByRepairCount=$($resultRootCaseMismatchSegment.RemovedByRepairCount)"

# --- Юніт-контракт Get-BRAVOModelRelativePath: регістронезалежний зріз
# кореня, точний збіг -> '', шлях поза коренем -> без змін (fail-closed).
$relativePathScenarios = @(
    @{ FullName = 'D:\LIMS\Model\ACT.md';       Root = 'd:\lims\model';    Expected = 'ACT.md';        Label = 'CaseInsensitiveRoot' }
    @{ FullName = 'D:\LIMS\Model\sub\x.000';    Root = 'D:\LIMS\Model';    Expected = 'sub\x.000';     Label = 'Subdirectory' }
    @{ FullName = 'D:\LIMS\Model';              Root = 'd:\LIMS\MODEL\';   Expected = '';              Label = 'ExactRootMatch' }
    @{ FullName = 'E:\Other\file.md';           Root = 'D:\LIMS\Model';    Expected = 'E:\Other\file.md'; Label = 'OutsideRootUnchanged' }
    @{ FullName = 'D:\LIMS\ModelBackup\a.md';   Root = 'D:\LIMS\Model';    Expected = 'D:\LIMS\ModelBackup\a.md'; Label = 'PrefixNotComponentBoundary' }
)
foreach ($scenario in $relativePathScenarios) {
    $derived = & $compareFileSizesModule {
        param($FullName, $RootPath)
        Get-BRAVOModelRelativePath -FullName $FullName -RootPath $RootPath
    } $scenario.FullName $scenario.Root
    Test-BRAVOCondition `
        -Condition ($derived -ceq $scenario.Expected) `
        -Name "Maintenance/ModelRelativePath[$($scenario.Label)]" `
        -Failure "Get-BRAVOModelRelativePath('$($scenario.FullName)', '$($scenario.Root)') має повернути '$($scenario.Expected)'; отримано '$derived'"
}

# ============================================================
# Compact notification: операторський alert = count + ≤5 прикладів;
# повна діагностика (4 рядки/файл) лишається ТІЛЬКИ в журналі.
# Реальний інцидент: сотні critical-файлів → 4×N рядків у транспорт →
# серія Discord-повідомлень. Contract: one event -> one notification.
# ============================================================
function Get-BRAVOCompareCaptured {
    param([Parameter(Mandatory = $true)][ValidateSet('Alerts', 'Logs')][string]$Kind)
    return @(& $compareFileSizesModule {
        param($Which)
        if ($Which -eq 'Alerts') {
            if ($null -eq (Get-Variable -Name BRAVOCapturedAlerts -Scope Script -ErrorAction SilentlyContinue)) { @() } else { @($script:BRAVOCapturedAlerts) }
        } else {
            if ($null -eq (Get-Variable -Name BRAVOCapturedLogMessages -Scope Script -ErrorAction SilentlyContinue)) { @() } else { @($script:BRAVOCapturedLogMessages) }
        }
    } $Kind)
}
function Clear-BRAVOCompareCaptured {
    & $compareFileSizesModule {
        $script:BRAVOCapturedAlerts = New-Object System.Collections.ArrayList
        $script:BRAVOCapturedLogMessages = New-Object System.Collections.ArrayList
    }
}

# --- 341 critical: рівно ОДИН alert, компактний; повний список у лозі ---
$compactBefore = @{ 'TestProject.md' = 500000 }
for ($compactIndex = 1; $compactIndex -le 341; $compactIndex++) {
    $compactBefore[('F{0:000}.md' -f $compactIndex)] = 10000
}
Clear-BRAVOCompareCaptured
$compact341 = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles $compactBefore `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md'
$compact341Alerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
$compact341Logs = @(Get-BRAVOCompareCaptured -Kind Logs)
$compact341DetailedLog = @($compact341Logs | Where-Object { $_ -like '*Розмір до реставрації*' } | Select-Object -First 1)
Test-BRAVOCondition `
    -Condition (
        $compact341.HasCriticalChanges -and
        @($compact341Alerts).Count -eq 1 -and
        $compact341Alerts[0].Contains('341 файл') -and
        $compact341Alerts[0].Contains('…і ще 336 файлів.') -and
        $compact341Alerts[0].Length -lt 1800 -and
        -not $compact341Alerts[0].Contains('Розмір до реставрації') -and
        (@($compact341Alerts[0] -split "`n" | Where-Object { $_ -like '• *' }).Count -eq 5) -and
        @($compact341DetailedLog).Count -eq 1 -and
        $compact341DetailedLog[0].Contains('F001.md') -and
        $compact341DetailedLog[0].Contains('F341.md') -and
        $compact341DetailedLog[0].Contains('Розмір до реставрації')
    ) `
    -Name "Maintenance/CompactAlert341FilesOneNotificationFullLog" `
    -Failure "341 critical: рівно 1 alert (<1800 симв., '341 файл', '…і ще 336 файлів.', 5 прикладів, БЕЗ 'Розмір до реставрації'); повний список (F001..F341 + деталі) лишається в лозі; факт: alerts=$(@($compact341Alerts).Count), len=$(if (@($compact341Alerts).Count) { $compact341Alerts[0].Length } else { 0 })"

# --- 3 critical (<=5): усі показані, БЕЗ '…і ще' ---
Clear-BRAVOCompareCaptured
[void](Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'A.md' = 9000; 'B.md' = 9000; 'C.md' = 9000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md')
$compact3Alerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
Test-BRAVOCondition `
    -Condition (
        @($compact3Alerts).Count -eq 1 -and
        $compact3Alerts[0].Contains('3 файли') -and
        (@($compact3Alerts[0] -split "`n" | Where-Object { $_ -like '• *' }).Count -eq 3) -and
        -not $compact3Alerts[0].Contains('і ще')
    ) `
    -Name "Maintenance/CompactAlertThreeFilesShowsAllNoRemainder" `
    -Failure "3 critical: усі 3 приклади, без '…і ще'; факт: $(if (@($compact3Alerts).Count) { $compact3Alerts[0] } else { 'alert відсутній' })"

# --- 6 critical: 5 прикладів + '…і ще 1 файл.' ---
Clear-BRAVOCompareCaptured
[void](Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'A.md' = 9000; 'B.md' = 9000; 'C.md' = 9000; 'D.md' = 9000; 'E.md' = 9000; 'G.md' = 9000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md')
$compact6Alerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
Test-BRAVOCondition `
    -Condition (
        @($compact6Alerts).Count -eq 1 -and
        (@($compact6Alerts[0] -split "`n" | Where-Object { $_ -like '• *' }).Count -eq 5) -and
        $compact6Alerts[0].Contains('…і ще 1 файл.')
    ) `
    -Name "Maintenance/CompactAlertSixFilesShowsFivePlusRemainder" `
    -Failure "6 critical: 5 прикладів + '…і ще 1 файл.'; факт: $(if (@($compact6Alerts).Count) { $compact6Alerts[0] } else { 'alert відсутній' })"

# --- missing vs редукція: різні короткі формати (structured, без parsing) ---
Clear-BRAVOCompareCaptured
[void](Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'GONE.md' = 2048000; 'DATABASE.md' = 1000000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000; 'DATABASE.md' = 200000 } `
    -MainModelRelativePath 'TestProject.md')
$compactKindAlerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
Test-BRAVOCondition `
    -Condition (
        @($compactKindAlerts).Count -eq 1 -and
        $compactKindAlerts[0] -match 'GONE\.md — файл відсутній \(було ' -and
        $compactKindAlerts[0] -match 'DATABASE\.md — .+ → .+ \(-80[,.]0%\)'
    ) `
    -Name "Maintenance/CompactAlertDistinguishesMissingVsReduction" `
    -Failure "missing -> 'файл відсутній (було ...)'; редукція 1000000->200000 -> '<before> → <after> (-80,0%)'; факт: $(if (@($compactKindAlerts).Count) { $compactKindAlerts[0] } else { 'alert відсутній' })"

# --- Unicode/вкладені шляхи/пробіли не ламають compact-формат ---
Clear-BRAVOCompareCaptured
[void](Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; '#\tbl\antib41.csv' = 9000; 'Eqv\ЗВТ_13-80.pdf' = 9000; 'Folder With Spaces\Test.md' = 9000; 'Довідники\Аналіз №1.md' = 9000 } `
    -AfterFiles  @{ 'TestProject.md' = 500000 } `
    -MainModelRelativePath 'TestProject.md')
$compactUnicodeAlerts = @(Get-BRAVOCompareCaptured -Kind Alerts)
Test-BRAVOCondition `
    -Condition (
        @($compactUnicodeAlerts).Count -eq 1 -and
        $compactUnicodeAlerts[0].Contains('#\tbl\antib41.csv — файл відсутній') -and
        $compactUnicodeAlerts[0].Contains('Eqv\ЗВТ_13-80.pdf — файл відсутній') -and
        $compactUnicodeAlerts[0].Contains('Folder With Spaces\Test.md — файл відсутній') -and
        $compactUnicodeAlerts[0].Contains('Довідники\Аналіз №1.md — файл відсутній')
    ) `
    -Name "Maintenance/CompactAlertHandlesUnicodeAndNestedPaths" `
    -Failure "compact-формат має коректно нести #\, кирилицю, пробіли і вкладені шляхи; факт: $(if (@($compactUnicodeAlerts).Count) { $compactUnicodeAlerts[0] } else { 'alert відсутній' })"

# --- Викликач деривує hint від MAIN_MODEL_FILE тим самим канонічним правилом
# Get-BRAVOModelRelativePath, що й writer before-CSV та lookup у
# Compare-FileSizes, а не здогадом "$MODEL_NAME.md" і не ordinal Replace
# (регістрочутливий Replace — корінь інциденту ДНДІЛДВСЕ 2026-08-25).
Test-BRAVOCondition `
    -Condition (
        $maintenanceRepairScriptText.Contains(
            '$mainModelRelativeHint = Get-BRAVOModelRelativePath -FullName $MAIN_MODEL_FILE -RootPath $MODEL_PATH'
        ) -and
        $maintenanceRepairScriptText.Contains('-MainModelRelativePath $mainModelRelativeHint') -and
        -not $maintenanceRepairScriptText.Contains('-MainModelRelativePath "$MODEL_NAME.md"') -and
        -not $maintenanceRepairScriptText.Contains('.Replace($MODEL_PATH, "").TrimStart') -and
        -not $maintenanceRepairScriptText.Contains('.Replace($ModelPath, "").TrimStart')
    ) `
    -Name "Maintenance/MainModelHintDerivedFromMainModelFile" `
    -Failure "hint/writer/lookup мають деривувати відносний шлях канонічним Get-BRAVOModelRelativePath (регістронезалежно), без залишків ordinal Replace+TrimStart і без здогаду `"`$MODEL_NAME.md`""

# --- Settle-retry (порт 67f3ad3/f7f6628 з backup/local-developer-rc2-line):
# транзитно «невидимий» файл (симуляція AV-затримки видимості щойно
# записаних .md) з'являється на диску ПІД ЧАС retry-вікна — Compare-FileSizes
# має відновитись без critical. Файл створюється окремим процесом
# (Start-Job), бо enumeration тепер прямий .NET-виклик і не мокабельний.
$settleRecoveredResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md' `
    -MaxSettleAttempts 20 -SettleDelaySeconds 2 `
    -DelayedFileJob {
        param($ScenarioRoot)
        # Ready-маркер ПЕРШИМ (harness чекає його до старту compare) —
        # див. коментар у Invoke-BRAVOCompareFileSizesScenario. Файл
        # з'являється через 2 с після маркера — гарантовано всередині
        # retry-вікна 20×2с.
        [IO.File]::WriteAllText((Join-Path $ScenarioRoot '__job_ready.marker'), 'ready')
        Start-Sleep -Seconds 2
        [IO.File]::WriteAllBytes((Join-Path $ScenarioRoot 'TestProject.md'), (New-Object byte[] 500000))
    }
Test-BRAVOCondition `
    -Condition (-not $settleRecoveredResult.HasCriticalChanges -and $settleRecoveredResult.MainModelValid) `
    -Name "Maintenance/CompareFileSizesSettleRetryRecoversTransientlyMissingFile" `
    -Failure "файл, що став видимим у settle-вікні, не повинен лишати CRITICAL; отримано HasCriticalChanges=$($settleRecoveredResult.HasCriticalChanges), MainModelValid=$($settleRecoveredResult.MainModelValid)"

# --- Settle-retry НЕ послаблює fail-closed: справді відсутня основна модель
# лишається критичною після всіх спроб.
$settleStillCriticalResult = Invoke-BRAVOCompareFileSizesScenario `
    -BeforeFiles @{ 'TestProject.md' = 500000; 'ACT.000' = 100000 } `
    -AfterFiles  @{ 'ACT.000' = 100000 } `
    -MainModelRelativePath 'TestProject.md' `
    -MaxSettleAttempts 2 -SettleDelaySeconds 0
Test-BRAVOCondition `
    -Condition ($settleStillCriticalResult.HasCriticalChanges -and -not $settleStillCriticalResult.MainModelValid) `
    -Name "Maintenance/CompareFileSizesSettleRetryStillCriticalWhenGenuinelyMissing" `
    -Failure "справді відсутній файл після всіх settle-спроб мусить лишатися CRITICAL (fail-closed не послаблено); отримано HasCriticalChanges=$($settleStillCriticalResult.HasCriticalChanges)"

# ============================================================
# Discord HTTP 429: обмежений retry з пріоритетом на Retry-After.
#
# УВАГА (пастка, реально спіймана 2026-08-26): New-Module у
# New-BRAVOSelfTestRuntimeModule авто-імпортує dynamic module у СЕСІЮ,
# тому фейкові Invoke-WebRequest і Start-Sleep звідси стають видимими
# ГЛОБАЛЬНО після цієї секції — зокрема Start-Sleep перетворюється на
# no-op лічильник. Будь-які нові сценарії, що покладаються на РЕАЛЬНИЙ
# Start-Sleep/мережу (напр. settle-retry Compare-FileSizes вище),
# додавайте ПЕРЕД цією секцією.
# ============================================================
$compatibilityScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psm1"),
    [Text.Encoding]::UTF8
)
$webhookStubText = @'
function New-BRAVOFake429Exception {
    param([string]$RetryAfter)
    $fakeHeaders = @{ 'Retry-After' = $RetryAfter }
    $fakeResponse = [PSCustomObject]@{ StatusCode = 429; Headers = $fakeHeaders }
    $exception = New-Object System.Exception('429 Too Many Requests (fake)')
    Add-Member -InputObject $exception -MemberType NoteProperty -Name Response -Value $fakeResponse -Force
    return $exception
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [string]$Method,
        [string]$ContentType,
        $Body,
        [int]$TimeoutSec,
        [switch]$UseBasicParsing
    )
    $script:BRAVOFakeWebRequestCallCount++
    if ($script:BRAVOFakeWebRequestCallCount -le $script:BRAVOFakeWebRequest429Count) {
        throw (New-BRAVOFake429Exception -RetryAfter $script:BRAVOFakeWebRequestRetryAfter)
    }
    return [PSCustomObject]@{ StatusCode = 200; Content = '' }
}
function Start-Sleep {
    param([long]$Milliseconds = 0, [long]$Seconds = 0)
    $script:BRAVOFakeSleepTotalMs += $Milliseconds + ($Seconds * 1000)
}
'@
$webhookModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($webhookStubText + "`n" + $compatibilityScriptText) `
    -FunctionNames @('New-BRAVOFake429Exception', 'Invoke-WebRequest', 'Start-Sleep', 'Enable-BRAVOTls12', 'Send-BRAVOWebhookNotification')

function Invoke-BRAVOWebhook429Scenario {
    param(
        [int]$FailCount,
        [string]$RetryAfter
    )
    return & $webhookModule {
        param($FailCount, $RetryAfter)
        Set-StrictMode -Version Latest
        $script:BRAVOFakeWebRequestCallCount = 0
        $script:BRAVOFakeWebRequest429Count = $FailCount
        $script:BRAVOFakeWebRequestRetryAfter = $RetryAfter
        $script:BRAVOFakeSleepTotalMs = [long]0
        $threw = $false
        $errorMessage = $null
        try {
            Send-BRAVOWebhookNotification -Provider "discord" -WebhookUrl "https://discord.example.invalid/webhook" -Message "test"
        } catch {
            $threw = $true
            $errorMessage = $_.Exception.Message
        }
        [PSCustomObject]@{
            Threw = $threw
            ErrorMessage = $errorMessage
            CallCount = $script:BRAVOFakeWebRequestCallCount
            SleepTotalMs = $script:BRAVOFakeSleepTotalMs
        }
    } $FailCount $RetryAfter
}

# --- 429 один раз, потім успіх -> рівно 2 спроби, БЕЗ помилки.
$webhookRetrySuccess = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '0'
Test-BRAVOCondition `
    -Condition (-not $webhookRetrySuccess.Threw -and $webhookRetrySuccess.CallCount -eq 2) `
    -Name "Notifications/Discord429RetryThenSuccess" `
    -Failure "429 з Retry-After на першій спробі має призвести до рівно 2 викликів Invoke-WebRequest без помилки; отримано Threw=$($webhookRetrySuccess.Threw) '$($webhookRetrySuccess.ErrorMessage)', CallCount=$($webhookRetrySuccess.CallCount)"

# --- 429 постійно -> обмежена невдача (макс. 4 спроби, без нескінченного
# retry), помилка прокидається виклику і ЯВНО називає rate limit та
# кількість спроб (діагностика для оператора, а не генерична помилка).
$webhookRetryExhaustedResult = Invoke-BRAVOWebhook429Scenario -FailCount 99 -RetryAfter '0'
Test-BRAVOCondition `
    -Condition ($webhookRetryExhaustedResult.Threw -and $webhookRetryExhaustedResult.CallCount -eq 4) `
    -Name "Notifications/Discord429RetryBoundedNoInfiniteLoop" `
    -Failure "постійний 429 має призвести до РІВНО 4 спроб сумарно (без нескінченного retry) і помилка має прокидатись виклику; отримано Threw=$($webhookRetryExhaustedResult.Threw), CallCount=$($webhookRetryExhaustedResult.CallCount)"
Test-BRAVOCondition `
    -Condition ($webhookRetryExhaustedResult.ErrorMessage -match '429' -and $webhookRetryExhaustedResult.ErrorMessage -match '4\s*спроб') `
    -Name "Notifications/Discord429ExhaustionErrorNamesRateLimitAndAttempts" `
    -Failure "помилка після вичерпання ретраїв має містити '429' і кількість спроб; отримано: '$($webhookRetryExhaustedResult.ErrorMessage)'"

# --- Великий серверний Retry-After (Cloudflare-фронт Discord повертає і
# 1800с) має обмежуватись капом 30с: сумарний сон = 30.25с, а не 30 хвилин
# синхронного сну під час зупинених служб BRAVO. Кап заодно виключає
# OverflowException у [int]-конвертації мілісекунд.
$webhookLargeRetryAfter = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '1800'
Test-BRAVOCondition `
    -Condition (-not $webhookLargeRetryAfter.Threw -and $webhookLargeRetryAfter.SleepTotalMs -eq 30250) `
    -Name "Notifications/DiscordLargeRetryAfterCappedAt30s" `
    -Failure "Retry-After=1800 має капатись до 30с (сон 30250мс з буфером 0.25с); отримано Threw=$($webhookLargeRetryAfter.Threw), SleepTotalMs=$($webhookLargeRetryAfter.SleepTotalMs)"

# --- Дробовий Retry-After "1.5" парситься через InvariantCulture (крапка
# як десятковий роздільник) незалежно від локалі хоста: сон 1.75с, а не
# фолбек 1с+0.25 через невдалий culture-залежний парсинг.
$webhookFractionalRetryAfter = Invoke-BRAVOWebhook429Scenario -FailCount 1 -RetryAfter '1.5'
Test-BRAVOCondition `
    -Condition (-not $webhookFractionalRetryAfter.Threw -and $webhookFractionalRetryAfter.SleepTotalMs -eq 1750) `
    -Name "Notifications/DiscordFractionalRetryAfterInvariantCulture" `
    -Failure "Retry-After='1.5' має давати сон 1750мс (InvariantCulture-парсинг), а не фолбек 1250мс; отримано SleepTotalMs=$($webhookFractionalRetryAfter.SleepTotalMs)"
Test-BRAVOCondition `
    -Condition $compatibilityScriptText.Contains('[Globalization.CultureInfo]::InvariantCulture') `
    -Name "Notifications/DiscordRetryAfterParseUsesInvariantCulture" `
    -Failure "парсинг Retry-After має використовувати InvariantCulture-перевантаження TryParse (culture-залежне на uk-UA не парсить '1.5')"

# --- Non-429 помилка НЕ ретраїться (rethrow одразу, без затримки).
$webhookNon429Result = & $webhookModule {
    Set-StrictMode -Version Latest
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $Method, $ContentType, $Body, $TimeoutSec, [switch]$UseBasicParsing)
        throw (New-Object System.Net.WebException('DNS resolution failed (fake, not 429)'))
    }
    $threw = $false
    try {
        Send-BRAVOWebhookNotification -Provider "discord" -WebhookUrl "https://discord.example.invalid/webhook" -Message "test"
    } catch {
        $threw = $true
    }
    $threw
}
Test-BRAVOCondition `
    -Condition $webhookNon429Result `
    -Name "Notifications/DiscordNon429NotRetried" `
    -Failure "помилка, що НЕ є 429, має прокидатись одразу без retry-циклу"

# ============================================================
# Invoke-BRAVOLegacySweep: одноразове маркер-гейтоване очищення
# legacy-артефактів ери ARCHIV_LIMS-предка (регресія 2026-09, LIMS-TOP).
# ============================================================
# Get-BRAVODirectories з опційним test-only гаком
# $script:legacySweepVanishAfterDiscoveryPath (R4-2, PR #136 review, 4-е
# коло) — той самий прийом, що $script:taP2VanishAfterDiscoveryPath у
# BRAVO_SELF_TEST.TraceArchive.ps1: синхронно й детерміновано видаляє
# вказаний candidate ПІСЛЯ реального сканування каталогу, але ДО
# per-candidate EnumerateFileSystemInfos() — відтворює РЕАЛЬНИЙ
# DirectoryNotFoundException для ОДНОГО candidate без потоків/сну.
$legacySweepStubText = @'
function Write-Log { param($Message, [string]$Level = 'INFO') }
function Get-BRAVOFiles { BRAVO.Compatibility\Get-BRAVOFiles @args }
function Get-BRAVODirectories {
    param([string]$Path, [string]$Filter = "*", [switch]$Recurse)
    $realResult = @(BRAVO.Compatibility\Get-BRAVODirectories -Path $Path -Filter $Filter -Recurse:$Recurse)
    if ($script:legacySweepVanishAfterDiscoveryPath -and (Test-Path -LiteralPath $script:legacySweepVanishAfterDiscoveryPath)) {
        Remove-Item -LiteralPath $script:legacySweepVanishAfterDiscoveryPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $realResult
}
'@
$legacySweepModule = New-BRAVOSelfTestRuntimeModule `
    -SourceText ($legacySweepStubText + "`n" + $maintenanceRepairScriptText) `
    -FunctionNames @(
        'Write-Log',
        'Get-BRAVOFiles',
        'Get-BRAVODirectories',
        'Get-BRAVOCanonicalBackupRootIdentity',
        'Get-BRAVOEmptyLogDateDirectories',
        'Remove-BRAVOEmptyLogDateDirectories',
        'Get-BRAVOLegacySweepStatePath',
        'Write-BRAVOLegacySweepState',
        'Read-BRAVOLegacySweepState',
        'Invoke-BRAVOLegacySweep'
    )

$legacySweepRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_LEGACY_SWEEP_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    $legacySweepLogDir = Join-Path $legacySweepRoot 'LOGS'
    $legacySweepTraceDir = Join-Path $legacySweepRoot 'LOGS\Trace'
    [void](New-Item -ItemType Directory -Path $legacySweepLogDir -Force)
    [void](New-Item -ItemType Directory -Path $legacySweepTraceDir -Force)
    $legacySweepStatePath = Join-Path $legacySweepRoot 'State\BRAVO_LEGACY_SWEEP_STATE.json'
    $legacySweepBackupRootA = Join-Path $legacySweepRoot 'BackupRootA'

    # --- (a) Немає стану + legacy-артефакти присутні -> виметено, маркер записано.
    [IO.File]::WriteAllText((Join-Path $legacySweepLogDir 'script_log_20260830_2355.txt'), 'legacy', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $legacySweepLogDir 'ARCHIV_LIMS_20260902_1510.log'), 'legacy', (New-Object Text.UTF8Encoding($false)))
    $legacySweepEmptyDir = Join-Path $legacySweepTraceDir '2026-08-23'
    [void](New-Item -ItemType Directory -Path $legacySweepEmptyDir -Force)
    $legacySweepNonEmptyDir = Join-Path $legacySweepTraceDir '2026-08-19'
    [void](New-Item -ItemType Directory -Path $legacySweepNonEmptyDir -Force)
    [IO.File]::WriteAllText((Join-Path $legacySweepNonEmptyDir 'traceBIS_000001.out'), 'stray', (New-Object Text.UTF8Encoding($false)))

    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $legacySweepLogDir $legacySweepTraceDir $legacySweepStatePath $legacySweepBackupRootA

    Test-BRAVOCondition -Condition (
        -not (Test-Path -LiteralPath (Join-Path $legacySweepLogDir 'script_log_20260830_2355.txt')) -and
        -not (Test-Path -LiteralPath (Join-Path $legacySweepLogDir 'ARCHIV_LIMS_20260902_1510.log')) -and
        -not (Test-Path -LiteralPath $legacySweepEmptyDir) -and
        (Test-Path -LiteralPath $legacySweepNonEmptyDir) -and
        (Test-Path -LiteralPath (Join-Path $legacySweepNonEmptyDir 'traceBIS_000001.out')) -and
        (Test-Path -LiteralPath $legacySweepStatePath)
    ) -Name 'Maintenance/LegacySweepFirstRunSweepsKnownArtifactsOnly' `
        -Failure "перший прогін має видалити script_log_*.txt/ARCHIV_LIMS_*.log і ПОРОЖНІЙ каталог-дату, залишити НЕПОРОЖНІЙ каталог-дату і записати маркер стану"

    # --- (b) Маркер присутній -> sweep пропущено, навіть якщо legacy-артефакти знову з'явились.
    [IO.File]::WriteAllText((Join-Path $legacySweepLogDir 'script_log_20260901_0000.txt'), 'reappeared', (New-Object Text.UTF8Encoding($false)))
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $legacySweepLogDir $legacySweepTraceDir $legacySweepStatePath $legacySweepBackupRootA
    Test-BRAVOCondition -Condition (
        Test-Path -LiteralPath (Join-Path $legacySweepLogDir 'script_log_20260901_0000.txt')
    ) -Name 'Maintenance/LegacySweepSkippedWhenMarkerPresent' `
        -Failure "з наявним маркером sweep має бути пропущений навіть якщо legacy-артефакт знову з'явився"

    # --- (c) Пошкоджений/нечитабельний стан -> трактується як "вже виметено" (пропуск), без деструкції.
    [IO.File]::WriteAllText($legacySweepStatePath, 'not-valid-json{{{', (New-Object Text.UTF8Encoding($false)))
    $legacySweepCorruptRead = & $legacySweepModule { param($p) Read-BRAVOLegacySweepState -Path $p } $legacySweepStatePath
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $legacySweepLogDir $legacySweepTraceDir $legacySweepStatePath $legacySweepBackupRootA
    Test-BRAVOCondition -Condition (
        $null -eq $legacySweepCorruptRead -and
        (Test-Path -LiteralPath (Join-Path $legacySweepLogDir 'script_log_20260901_0000.txt'))
    ) -Name 'Maintenance/LegacySweepCorruptStateTreatedAsAlreadySwept' `
        -Failure "пошкоджений стан-файл має трактуватись як 'вже виметено' (fail-closed skip), Read має повернути `$null, жодної деструктивної дії"

    # --- (d) Валідний JSON, але нечислова schemaVersion — регресія
    # code-review 5c14a70: [int]-каст поза try кидав помилковий record і
    # повертав зіпсований стан як валідний. Має бути $null (пошкоджений),
    # тихо, без error-record.
    [IO.File]::WriteAllText($legacySweepStatePath, '{"schemaVersion": "abc", "sweptAt": "2026-09-04T00:00:00Z"}', (New-Object Text.UTF8Encoding($false)))
    $legacySweepBadSchemaOutput = @(
        & $legacySweepModule { param($p) Read-BRAVOLegacySweepState -Path $p } $legacySweepStatePath 2>&1
    )
    $legacySweepBadSchemaErrors = @(
        $legacySweepBadSchemaOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
    )
    $legacySweepBadSchemaValues = @(
        $legacySweepBadSchemaOutput | Where-Object {
            $_ -isnot [System.Management.Automation.ErrorRecord] -and $null -ne $_
        }
    )
    Test-BRAVOCondition -Condition (
        $legacySweepBadSchemaValues.Count -eq 0 -and
        $legacySweepBadSchemaErrors.Count -eq 0
    ) -Name 'Maintenance/LegacySweepNonNumericSchemaVersionIsCorruptState' `
        -Failure "валідний JSON із нечисловою schemaVersion має трактуватись як пошкоджений стан (`$null) без error-record; факт: values=$($legacySweepBadSchemaValues.Count), errors=$($legacySweepBadSchemaErrors.Count)"
} finally {
    if (Test-Path -LiteralPath $legacySweepRoot) {
        Remove-Item -LiteralPath $legacySweepRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ===== R4-2 (PR #136 review, 4-е коло): провал enumeration для ОДНОГО
# candidate не зупиняє обробку інших і не веде до видалення
# непідтвердженого каталогу; структурований результат розрізняє
# DiscoveredCandidates/ConfirmedEmpty/Deleted/EnumerationWarnings/
# DeletionWarnings. Invoke-BRAVOLegacySweep тепер повертає результат
# КАНОНІЧНОЇ Remove-BRAVOEmptyLogDateDirectories замість власного
# паралельного enumeration-циклу. =====
$legacySweepP2Root = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_LEGACY_SWEEP_P2_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    $p2LogDir = Join-Path $legacySweepP2Root 'LOGS'
    $p2TraceDir = Join-Path $legacySweepP2Root 'LOGS\Trace'
    [void](New-Item -ItemType Directory -Path $p2LogDir -Force)
    [void](New-Item -ItemType Directory -Path $p2TraceDir -Force)
    $p2StatePath = Join-Path $legacySweepP2Root 'State\BRAVO_LEGACY_SWEEP_STATE.json'
    $p2BackupRoot = Join-Path $legacySweepP2Root 'BackupRoot'
    $p2VanishingDir = Join-Path $p2TraceDir '2026-09-01'
    $p2ValidEmptyDir = Join-Path $p2TraceDir '2026-09-02'
    [void](New-Item -ItemType Directory -Path $p2VanishingDir -Force)
    [void](New-Item -ItemType Directory -Path $p2ValidEmptyDir -Force)

    $p2Result = & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root, $VanishPath)
        $script:legacySweepVanishAfterDiscoveryPath = $VanishPath
        try { Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' }
        finally { $script:legacySweepVanishAfterDiscoveryPath = $null }
    } $p2LogDir $p2TraceDir $p2StatePath $p2BackupRoot $p2VanishingDir

    Test-BRAVOCondition -Condition (
        $null -ne $p2Result -and
        $p2Result.DiscoveredCandidates -eq 2 -and
        $p2Result.ConfirmedEmpty -eq 1 -and
        $p2Result.Deleted -eq 1 -and
        $p2Result.EnumerationWarnings -eq 1 -and
        $p2Result.DeletionWarnings -eq 0 -and
        (-not (Test-Path -LiteralPath $p2ValidEmptyDir)) -and
        (Test-Path -LiteralPath $p2StatePath)
    ) -Name 'Maintenance/LegacySweepEnumerationFailureIsolatedPerCandidate' `
        -Failure ("провал enumeration для ОДНОГО candidate не повинен зупиняти обробку іншого; факт: " + `
            "discovered=$($p2Result.DiscoveredCandidates), confirmedEmpty=$($p2Result.ConfirmedEmpty), " + `
            "deleted=$($p2Result.Deleted), enumWarn=$($p2Result.EnumerationWarnings), delWarn=$($p2Result.DeletionWarnings)")
} finally {
    if (Test-Path -LiteralPath $legacySweepP2Root) {
        Remove-Item -LiteralPath $legacySweepP2Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ===== R4-4 (PR #136 review, 4-е коло): legacy-sweep маркер прив'язаний
# до BackupRoot — зміна кореня тригерить повторний sweep; той самий
# корінь в іншому лексичному форматі — ні; corrupt/unknown стан і провал
# атомарного запису лишаються fail-safe незалежно від кореня. =====
$legacySweepRootScopeRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("BRAVO_LEGACY_SWEEP_ROOTSCOPE_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
try {
    $rsLogDir = Join-Path $legacySweepRootScopeRoot 'LOGS'
    $rsTraceDir = Join-Path $legacySweepRootScopeRoot 'LOGS\Trace'
    [void](New-Item -ItemType Directory -Path $rsLogDir -Force)
    [void](New-Item -ItemType Directory -Path $rsTraceDir -Force)
    $rsStatePath = Join-Path $legacySweepRootScopeRoot 'State\BRAVO_LEGACY_SWEEP_STATE.json'
    $rsBackupRootA = Join-Path $legacySweepRootScopeRoot 'BackupRootA'
    $rsBackupRootB = Join-Path $legacySweepRootScopeRoot 'BackupRootB'

    # --- (i) Перший sweep для root A.
    [IO.File]::WriteAllText((Join-Path $rsLogDir 'script_log_20260901_0100.txt'), 'legacy', (New-Object Text.UTF8Encoding($false)))
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootA
    Test-BRAVOCondition -Condition (
        -not (Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0100.txt')) -and
        (Test-Path -LiteralPath $rsStatePath)
    ) -Name 'Maintenance/LegacySweepRootScopeFirstSweepForRootA' `
        -Failure "перший sweep для root A має видалити legacy-артефакт і записати маркер"

    # --- (ii) Повторний прогін для root A -> пропущено.
    [IO.File]::WriteAllText((Join-Path $rsLogDir 'script_log_20260901_0200.txt'), 'reappeared', (New-Object Text.UTF8Encoding($false)))
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootA
    Test-BRAVOCondition -Condition (
        Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0200.txt')
    ) -Name 'Maintenance/LegacySweepRootScopeRepeatForSameRootSkipped' `
        -Failure "повторний прогін для того самого root A має бути пропущений"

    # --- (iii) Той самий root A, лише в іншому лексичному форматі
    # (інший регістр + кінцевий '\') -> НЕ тригерить повторний sweep.
    $rsBackupRootAAltFormat = $rsBackupRootA.ToUpperInvariant() + '\'
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootAAltFormat
    Test-BRAVOCondition -Condition (
        Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0200.txt')
    ) -Name 'Maintenance/LegacySweepRootScopePathFormatChangeWithoutCanonicalChangeNotResweep' `
        -Failure "зміна лексичного формату (регістр/кінцевий '\') того самого root A не повинна тригерити повторний sweep"

    # --- (iv) Зміна на root B -> повторний sweep для нового кореня.
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootB
    Test-BRAVOCondition -Condition (
        -not (Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0200.txt'))
    ) -Name 'Maintenance/LegacySweepRootScopeChangeToRootBTriggersResweep' `
        -Failure "зміна BackupRoot на root B має тригерити повторний sweep для нового кореня"

    # --- (v) corrupt/unknown стан fail-safe пропускає sweep незалежно
    # від переданого BackupRoot (той самий принцип, що (c)/(d) вище).
    [IO.File]::WriteAllText($rsStatePath, 'not-valid-json{{{', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $rsLogDir 'script_log_20260901_0300.txt'), 'reappeared-corrupt', (New-Object Text.UTF8Encoding($false)))
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootB
    Test-BRAVOCondition -Condition (
        Test-Path -LiteralPath (Join-Path $rsLogDir 'script_log_20260901_0300.txt')
    ) -Name 'Maintenance/LegacySweepRootScopeCorruptStateFailsSafeRegardlessOfRoot' `
        -Failure "пошкоджений стан-файл має fail-closed пропустити sweep незалежно від переданого BackupRoot"

    # --- (vi) Провал атомарного запису НЕ знищує попередній валідний
    # маркер. Спершу відновлюємо валідний маркер для root B, тоді
    # блокуємо ЦІЛЬОВИЙ файл маркера (відкритий FileStream без
    # FileShare.Write/Delete) так, щоб [IO.File]::Replace у
    # Write-BRAVOLegacySweepState кинув виняток під час спроби sweep для
    # НОВОГО root C — попередній валідний маркер (для root B) має
    # лишитись читабельним і байт-у-байт незмінним.
    Remove-Item -LiteralPath $rsStatePath -Force -ErrorAction SilentlyContinue
    & $legacySweepModule {
        param($LogDir, $TraceDir, $StatePath, $Root)
        Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
    } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootB
    $rsPriorValidStateBytes = [IO.File]::ReadAllBytes($rsStatePath)

    [IO.File]::WriteAllText((Join-Path $rsLogDir 'script_log_20260901_0400.txt'), 'triggers-resweep-for-root-c', (New-Object Text.UTF8Encoding($false)))
    $rsBackupRootC = Join-Path $legacySweepRootScopeRoot 'BackupRootC'
    $rsLockStream = New-Object IO.FileStream($rsStatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        & $legacySweepModule {
            param($LogDir, $TraceDir, $StatePath, $Root)
            Invoke-BRAVOLegacySweep -LogDir $LogDir -TraceDir $TraceDir -StateFilePath $StatePath -BackupRoot $Root -SweptBy '5.3.0-dev.2-selftest' | Out-Null
        } $rsLogDir $rsTraceDir $rsStatePath $rsBackupRootC
    } finally {
        $rsLockStream.Close()
    }
    $rsPostFailureStateBytes = [IO.File]::ReadAllBytes($rsStatePath)
    # Примітка: сам legacy-файл-тригер ОЧІКУВАНО видаляється до спроби
    # запису маркера (та сама поведінка, що й наявний P2 partial-failure
    # шлях: успішно видалені об'єкти при повторному прогоні просто не
    # будуть знайдені знову) — атомарність тут гарантується ЛИШЕ для
    # самого стан-файлу маркера, не для вже виконаної sweep-роботи.
    Test-BRAVOCondition -Condition (
        (Test-Path -LiteralPath $rsStatePath) -and
        ([System.Convert]::ToBase64String($rsPriorValidStateBytes) -eq [System.Convert]::ToBase64String($rsPostFailureStateBytes))
    ) -Name 'Maintenance/LegacySweepRootScopeAtomicWriteFailurePreservesPriorValidState' `
        -Failure "провал атомарного запису маркера (заблокований цільовий файл) не повинен знищувати/змінювати попередній валідний стан-файл"
} finally {
    if (Test-Path -LiteralPath $legacySweepRootScopeRoot) {
        Remove-Item -LiteralPath $legacySweepRootScopeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
