# Домен-фрагмент self-test: LogRotation (ротація/міграція/retention
# журналів, ТЗ §80-§103, 27 сценаріїв на СПРАВЖНІХ файлах у тимчасовому
# каталозі) разом із суміжними доменами тієї самої rotation-фікстури:
# RangeId/* (WOW64-контракт range_id_log.json), BravoWeb/* і
# OptionalComponents/* (плани optional-компонентів на синтетичних
# службах). Увесь блок живе в ОДНОМУ спільному try/finally
# ($rotationTestRoot) і переноситься цілим -- вирізання середини try
# розірвало б cleanup-семантику. Dot-sourced з кореневого
# BRAVO_SELF_TEST.ps1 -- НЕ запускається напряму. Успадковує з викликача:
# $root, Test-BRAVOCondition, New-BRAVOSelfTestRuntimeModule,
# $script:failures.
#
# ЕКСПОРТОВАНА ЗАЛЕЖНІСТЬ: $logRotationModule, створений тут, ДАЛІ
# використовується в моноліті ПІСЛЯ цього фрагмента (Maintenance
# lock-probe тести). Dot-sourcing виконується в скоупі викликача, тому
# змінна переживає фрагмент -- не перетворюйте цей файл на функцію чи
# окремий scope без міграції тих споживачів.
#
# ПРИХОВАНА ЗАЛЕЖНІСТЬ: $maintenanceScriptText -- локальне перечитування
# (той самий вміст файлу, immutable протягом self-test-прогону).
$maintenanceScriptText = [IO.File]::ReadAllText(
    (Join-Path $root "modules\BRAVO.Maintenance\BRAVO.Maintenance.Runtime.ps1"),
    [Text.Encoding]::UTF8
)

    # ===== РОТАЦІЯ, МІГРАЦІЯ ТА RETENTION ЖУРНАЛІВ: 27 сценаріїв
    # (ТЗ «Production-grade ротація, міграція, архівація та retention
    # логів BRAVO», §80-§102) =====
    # Перевіряються на СПРАВЖНІХ файлах у тимчасовому каталозі, а не лише
    # текстовим пошуком: нумерація, відсутність перезапису, звірка розміру
    # після Move й ідемпотентність міграції — саме те, чого текстова
    # перевірка підтвердити не може, а помилка в чому коштує журналів.
    #
    # Жоден сценарій не керує реальними службами (ТЗ §103): усе, що
    # стосується BRAVO/Apache/exchangAPI, перевіряється на синтетичних
    # об'єктах служб і на файлах у тимчасовому каталозі.
    Import-Module -Name (Join-Path $root "modules\BRAVO.Compatibility\BRAVO.Compatibility.psd1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $root "modules\BRAVO.Discovery\BRAVO.Discovery.psd1") -Force -ErrorAction Stop

    $logRotationModule = New-BRAVOSelfTestRuntimeModule `
        -SourceText $maintenanceScriptText `
        -FunctionNames @(
            "Write-BRAVOLogRotationMessage",
            "Get-BRAVONextLogSequence",
            # Move-BRAVOLogWithSequence викликає її на фінальній відмові, тому
            # без неї синтетичний модуль ротації впав би на CommandNotFound.
            "Get-BRAVOFileLockingProcess",
            "Move-BRAVOLogWithSequence",
            "New-BRAVOLogRotationSummary",
            "Get-BRAVOExchangeApiLogFiles",
            "Test-BRAVOIsTimestampedExchangeApiLogName",
            "Get-BRAVOApacheLogFiles",
            "Get-BRAVOWebApplicationLogFiles",
            "Write-BRAVOLogRotationSummary",
            "New-BRAVOLogRotationItem",
            "Invoke-BRAVOLogRotation",
            "Invoke-BRAVOTraceRotation",
            "Get-BRAVOInstallationTraceOutSources",
            "Invoke-BRAVOExchangeApiLogRotation",
            "Invoke-BRAVOApacheLogRotation",
            "Invoke-BRAVOWebApplicationLogRotation",
            "Get-BRAVOBravoWebComponentPlan",
            "Get-BRAVOOptionalServiceComponentPlan",
            "Get-BRAVOTraceConfiguration",
            "Get-BRAVOLegacyLogMigrationPlan",
            "Get-BRAVOFreeMigrationPath",
            "Move-BRAVOLegacyLogFile",
            "Remove-BRAVOEmptyLegacyDirectory",
            "Invoke-BRAVOLegacyLogMigration",
            "Remove-BRAVOExpiredCompressedLogs",
            "Resolve-BRAVOExchangeApiRuntimeDirectory"
        )

    $rotationTestRoot = Join-Path `
        -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ("BRAVO_LOG_ROTATION_SELF_TEST_{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($rotationTestRoot)
        $rotationLogMessages = New-Object System.Collections.Generic.List[string]
        $rotationLogger = {
            param($Message, $Level)
            $rotationLogMessages.Add("[$Level] $Message")
        }

        function New-BRAVOLogRotationFixture {
            param(
                [string]$Directory,
                [string]$Name,
                [string]$Content = "log",
                [Nullable[datetime]]$LastWriteTime
            )

            [void][IO.Directory]::CreateDirectory($Directory)
            $path = Join-Path $Directory $Name
            [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
            if ($null -ne $LastWriteTime) {
                (Get-Item -LiteralPath $path).LastWriteTime = [datetime]$LastWriteTime
            }
            return $path
        }

        function Get-BRAVOLogRotationNames {
            param([string]$Directory)
            return @(
                Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name |
                    Sort-Object
            )
        }

        function Test-BRAVOLogRotationWarned {
            param([object]$Messages)
            return (@($Messages | Where-Object { $_.StartsWith("[WARNING]") }).Count -gt 0)
        }

        function New-BRAVOSyntheticBravoService {
            param([string]$ExecutablePath)
            return [pscustomobject]@{
                Name = "BRAVO"
                DisplayName = "BRAVO Service"
                State = "Running"
                StartMode = "Auto"
                PathName = ('"{0}" -k runservice' -f $ExecutablePath)
            }
        }

        function Invoke-BRAVORotationHelper {
            param([scriptblock]$Body, [object[]]$Arguments = @())
            return (& $logRotationModule $Body @Arguments)
        }

        # --- Test 1/2: bravo.ini визначається виключно архітектурою ОС ---
        $iniPathOnX64 = Get-BRAVOSystemBravoIniPath -SystemRoot "C:\WindowsTest" -Is64BitOperatingSystem $true
        $iniPathOnX86 = Get-BRAVOSystemBravoIniPath -SystemRoot "C:\WindowsTest" -Is64BitOperatingSystem $false
        Test-BRAVOCondition `
            -Condition ($iniPathOnX64 -eq "C:\WindowsTest\SysWOW64\bravo.ini") `
            -Name "LogRotation/01-BravoIniPathOnX64" `
            -Failure "на 64-бітній ОС очікуваний bravo.ini — рівно %SystemRoot%\SysWOW64\bravo.ini"
        Test-BRAVOCondition `
            -Condition ($iniPathOnX86 -eq "C:\WindowsTest\System32\bravo.ini") `
            -Name "LogRotation/02-BravoIniPathOnX86" `
            -Failure "на 32-бітній ОС очікуваний bravo.ini — рівно %SystemRoot%\System32\bravo.ini"

        $absentBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $true `
                -ServiceExists $false `
                -ServiceDisabled $false `
                -ServiceMatchCount 0
        }
        Test-BRAVOCondition `
            -Condition $absentBravoWebPlan.SilentlySkipped `
            -Name "BravoWeb/AbsentServiceIsSilentlySkipped" `
            -Failure "увімкнений, але не встановлений BRAVO Web має пропускатись без warning/error"
        Test-BRAVOCondition `
            -Condition ($absentBravoWebPlan.WarningCountDelta -eq 0) `
            -Name "BravoWeb/AbsentServiceDoesNotIncrementWarningCount" `
            -Failure "відсутня Apache/BRAVO Web служба не повинна змінювати лічильник WARNING"
        Test-BRAVOCondition `
            -Condition (
                -not $absentBravoWebPlan.ManageService -and
                -not $absentBravoWebPlan.IncludeLegacyWebData
            ) `
            -Name "BravoWeb/AbsentServiceDoesNotScheduleWebActions" `
            -Failure "відсутній BRAVO Web не повинен планувати service, migration, retention або web-log дії"
        $presentBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $true `
                -ServiceExists $true `
                -ServiceDisabled $false `
                -ServiceMatchCount 1
        }
        Test-BRAVOCondition `
            -Condition (
                -not $presentBravoWebPlan.SilentlySkipped -and
                $presentBravoWebPlan.ManageService -and
                $presentBravoWebPlan.IncludeLegacyWebData -and
                -not $presentBravoWebPlan.WarnDuplicateService
            ) `
            -Name "BravoWeb/PresentServicePreservesMaintenance" `
            -Failure "встановлений активний BRAVO Web має зберегти service і log maintenance"
        $duplicateBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $true `
                -ServiceExists $true `
                -ServiceDisabled $false `
                -ServiceMatchCount 2
        }
        Test-BRAVOCondition `
            -Condition $duplicateBravoWebPlan.WarnDuplicateService `
            -Name "BravoWeb/DuplicateServiceStillWarns" `
            -Failure "кілька служб для одного httpd.exe мають зберегти existing WARNING"
        $disabledBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $true `
                -ServiceExists $true `
                -ServiceDisabled $true `
                -ServiceMatchCount 1
        }
        $disabledAndAbsentBravoWebPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOBravoWebComponentPlan `
                -ComponentEnabled $false `
                -ServiceExists $false `
                -ServiceDisabled $false `
                -ServiceMatchCount 0
        }
        Test-BRAVOCondition `
            -Condition (
                $disabledBravoWebPlan.IncludeLegacyWebData -and
                -not $disabledBravoWebPlan.ManageService -and
                -not $disabledAndAbsentBravoWebPlan.IncludeLegacyWebData
            ) `
            -Name "BravoWeb/DisabledAndAbsentDoesNotProcessLegacyData" `
            -Failure "legacy web дані допустимі лише для встановленого BRAVO Web, навіть якщо його службу Disabled"
        Test-BRAVOCondition `
            -Condition (
                -not $absentBravoWebPlan.IncludeLegacyWebData -and
                -not $disabledAndAbsentBravoWebPlan.IncludeLegacyWebData
            ) `
            -Name "BravoWeb/LegacyDirectoryDoesNotActivateAbsentOrDisabledComponent" `
            -Failure "залишений Br-a-vo.web не повинен активувати absent або вимкнений у конфігурації BRAVO Web"

        $absentExchangeApiPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOOptionalServiceComponentPlan -ServiceExists $false -ServiceDisabled $false
        }
        Test-BRAVOCondition `
            -Condition $absentExchangeApiPlan.SilentlySkipped `
            -Name "OptionalComponents/ExchangeApiAbsentIsSilentlySkipped" `
            -Failure "відсутній exchangAPI має бути optional-компонентом без повідомлень"
        Test-BRAVOCondition `
            -Condition (-not $absentExchangeApiPlan.ManageService) `
            -Name "OptionalComponents/ExchangeApiAbsentDoesNotIncrementWarningCount" `
            -Failure "відсутній exchangAPI не повинен планувати warning-producing service actions"
        Test-BRAVOCondition `
            -Condition (
                -not $absentExchangeApiPlan.ManageService -and
                -not $absentExchangeApiPlan.IncludeLegacyData
            ) `
            -Name "OptionalComponents/ExchangeApiAbsentDoesNotScheduleActions" `
            -Failure "відсутній exchangAPI не повинен планувати runtime, log, retention або service дії"
        Test-BRAVOCondition `
            -Condition (-not $absentExchangeApiPlan.IncludeLegacyData) `
            -Name "OptionalComponents/ExchangeApiAbsentDoesNotMigrateLegacyLogs" `
            -Failure "залишений legacy каталог exchangAPI не активує відсутній компонент"
        $presentExchangeApiPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOOptionalServiceComponentPlan -ServiceExists $true -ServiceDisabled $false
        }
        Test-BRAVOCondition `
            -Condition ($presentExchangeApiPlan.ManageService -and $presentExchangeApiPlan.IncludeLegacyData) `
            -Name "OptionalComponents/ExchangeApiPresentPreservesMaintenance" `
            -Failure "встановлений активний exchangAPI має зберегти наявну maintenance поведінку"
        $disabledExchangeApiPlan = Invoke-BRAVORotationHelper {
            Get-BRAVOOptionalServiceComponentPlan -ServiceExists $true -ServiceDisabled $true
        }
        Test-BRAVOCondition `
            -Condition (-not $disabledExchangeApiPlan.SilentlySkipped -and -not $disabledExchangeApiPlan.ManageService -and $disabledExchangeApiPlan.IncludeLegacyData) `
            -Name "OptionalComponents/ExchangeApiDisabledIsNotTreatedAsAbsent" `
            -Failure "встановлений Disabled exchangAPI має лишатись відмінним від відсутньої служби"
        Test-BRAVOCondition `
            -Condition (-not $absentExchangeApiPlan.IncludeLegacyData) `
            -Name "OptionalComponents/LegacyDirectoryDoesNotActivateAbsentComponent" `
            -Failure "залишений каталог exchangAPI не повинен активувати відсутній optional-компонент"

        . (Join-Path $root 'selftest\BRAVO_SELF_TEST.ManualLaunchers.ps1')

        # range_id_log.json має той самий WOW64-контракт, що й bravo.ini:
        # один системний каталог, жодного fallback до LIMSRoot або legacy
        # RangeIdMonitoring.FilePath.
        $rangeIdPathOnX64 = Get-BRAVOSystemRangeIdLogPath `
            -SystemRoot "C:\WindowsTest" `
            -Is64BitOperatingSystem $true
        $rangeIdPathOnX86 = Get-BRAVOSystemRangeIdLogPath `
            -SystemRoot "C:\WindowsTest" `
            -Is64BitOperatingSystem $false
        Test-BRAVOCondition `
            -Condition ($rangeIdPathOnX64 -eq "C:\WindowsTest\SysWOW64\range_id_log.json") `
            -Name "RangeId/01-SystemPathOnX64" `
            -Failure "на 64-бітній ОС range_id_log.json має визначатись рівно в %SystemRoot%\SysWOW64"
        Test-BRAVOCondition `
            -Condition ($rangeIdPathOnX86 -eq "C:\WindowsTest\System32\range_id_log.json") `
            -Name "RangeId/02-SystemPathOnX86" `
            -Failure "на 32-бітній ОС range_id_log.json має визначатись рівно в %SystemRoot%\System32"
        Test-BRAVOCondition `
            -Condition (
                (Split-Path -Parent $rangeIdPathOnX64) -eq
                    (Get-BRAVOSystemDirectoryPath -SystemRoot "C:\WindowsTest" -Is64BitOperatingSystem $true) -and
                (Split-Path -Parent $rangeIdPathOnX86) -eq
                    (Get-BRAVOSystemDirectoryPath -SystemRoot "C:\WindowsTest" -Is64BitOperatingSystem $false) -and
                (Split-Path -Parent $iniPathOnX64) -eq (Split-Path -Parent $rangeIdPathOnX64) -and
                (Split-Path -Parent $iniPathOnX86) -eq (Split-Path -Parent $rangeIdPathOnX86)
            ) `
            -Name "RangeId/03-UsesSameSystemDirectoryContractAsBravoIni" `
            -Failure "bravo.ini і range_id_log.json мають використовувати один системний каталог для кожної архітектури ОС"
        $syntheticLimsRoot = Join-Path $rotationTestRoot "RangeIdLimsRoot"
        $limsRangeIdPath = Join-Path $syntheticLimsRoot "range_id_log.json"
        [void](New-BRAVOLogRotationFixture -Directory $syntheticLimsRoot -Name "range_id_log.json" -Content '{}')
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $limsRangeIdPath -PathType Leaf) -and
                $rangeIdPathOnX64 -ne $limsRangeIdPath -and
                $rangeIdPathOnX64 -notlike "$syntheticLimsRoot\*"
            ) `
            -Name "RangeId/04-LimsRootIsNeverFallback" `
            -Failure "існування range_id_log.json у LIMSRoot не може підміняти системний шлях"
        $legacyConfiguredRangeIdPath = "D:\LIMS\range_id_log.json"
        Test-BRAVOCondition `
            -Condition (
                $rangeIdPathOnX64 -ne $legacyConfiguredRangeIdPath -and
                $maintenanceScriptText.Contains('Get-BRAVOSystemRangeIdLogPath') -and
                -not $maintenanceScriptText.Contains('RangeIdMonitoring.FilePath')
            ) `
            -Name "RangeId/05-LegacyConfiguredFilePathDoesNotOverrideSystemPath" `
            -Failure "legacy RangeIdMonitoring.FilePath може лишатись у локальному config для сумісності, але не має визначати шлях runtime"
        $rangeIdUsageModule = New-BRAVOSelfTestRuntimeModule `
            -SourceText $maintenanceScriptText `
            -FunctionNames @('Test-RangeIdUsage')
        $missingSystemRangeIdWarning = & $rangeIdUsageModule {
            param($Path)
            $messages = New-Object System.Collections.Generic.List[string]
            function Write-Log {
                param($Message, $Level, [switch]$NoTimestamp, [switch]$NoConsole)
                # NoTimestamp/NoConsole — дзеркалять реальну сигнатуру,
                # тілу не потрібні (лише Message/Level фіксуються);
                # consumed через $null =, без нового PSReviewUnusedParameter.
                $null = $NoTimestamp
                $null = $NoConsole
                $messages.Add("[$Level] $Message")
            }
            function Send-SlackAlert { param($Message, [switch]$IsCritical) }
            Test-RangeIdUsage -Path $Path -ThresholdPercent 80
            return @($messages)
        } $rangeIdPathOnX64
        Test-BRAVOCondition `
            -Condition (
                @($missingSystemRangeIdWarning | Where-Object {
                    $_ -eq "[WARNING] Файл контролю діапазонів ID не знайдено: $rangeIdPathOnX64"
                }).Count -eq 1
            ) `
            -Name "RangeId/06-MissingSystemFileProducesWarning" `
            -Failure "відсутній authoritative системний range_id_log.json має давати WARNING з фактичним шляхом без пошуку копій"

        # --- Test 3: відсутній bravo.ini -> помилка з назвою шляху, без
        # мовчазного fallback на каталог поруч із bravo.exe ---
        $test3SystemRoot = Join-Path $rotationTestRoot "test03\Windows"
        [void][IO.Directory]::CreateDirectory((Join-Path $test3SystemRoot "SysWOW64"))
        $test3InstallDirectory = Join-Path $rotationTestRoot "test03\LIMS"
        [void](New-BRAVOLogRotationFixture -Directory $test3InstallDirectory -Name "bravo.exe" -Content "exe")
        # Пастка: поруч із bravo.exe лежить ЧУЖИЙ bravo.ini з іншим trace.
        [void](New-BRAVOLogRotationFixture `
            -Directory $test3InstallDirectory `
            -Name "bravo.ini" `
            -Content "[Debug]`r`nFILE=D:\WRONG\wrong.out`r`n")
        $test3Discovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $test3InstallDirectory `
            -Services @(New-BRAVOSyntheticBravoService -ExecutablePath (Join-Path $test3InstallDirectory "bravo.exe")) `
            -SystemRoot $test3SystemRoot `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                [string]::IsNullOrWhiteSpace([string]$test3Discovery.BravoIniPath) -and
                [string]$test3Discovery.Reasons.BravoIniPath -like "*SysWOW64\bravo.ini*" -and
                [string]::IsNullOrWhiteSpace([string]$test3Discovery.TRACE_FILE)
            ) `
            -Name "LogRotation/03-NoFallbackToBravoExeDirectory" `
            -Failure "за відсутності bravo.ini у системному каталозі має бути помилка з назвою перевіреного шляху, а не мовчазне читання чужого bravo.ini поруч із bravo.exe"

        # --- Test 4: відносний [Debug]/FILE резолвиться від каталогу
        # інсталяції BRAVO ---
        $test4SystemRoot = Join-Path $rotationTestRoot "test04\Windows"
        $test4InstallDirectory = Join-Path $rotationTestRoot "test04\LIMS-NEW"
        [void](New-BRAVOLogRotationFixture -Directory $test4InstallDirectory -Name "bravo.exe" -Content "exe")
        [void](New-BRAVOLogRotationFixture `
            -Directory (Join-Path $test4SystemRoot "SysWOW64") `
            -Name "bravo.ini" `
            -Content "[model]`r`nMODEL=D:\LIMS\MODEL\lims`r`n[Debug]`r`nFILE= `"TraceSRV.out`" `r`n")
        $test4Discovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $test4InstallDirectory `
            -Services @(New-BRAVOSyntheticBravoService -ExecutablePath (Join-Path $test4InstallDirectory "bravo.exe")) `
            -SystemRoot $test4SystemRoot `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                [string]$test4Discovery.TRACE_FILE -eq (Join-Path $test4InstallDirectory "TraceSRV.out") -and
                -not [bool]$test4Discovery.TRACE_FILE_OUTSIDE_INSTALLATION
            ) `
            -Name "LogRotation/04-RelativeTraceResolvedAgainstInstallation" `
            -Failure "відносний [Debug]/FILE має резолвитись від каталогу інсталяції BRAVO (не від CWD, ArchiveRoot чи SysWOW64), із trim і знятими лапками"

        # --- Test 5: trace поза каталогом інсталяції позначається ---
        $test5SystemRoot = Join-Path $rotationTestRoot "test05\Windows"
        $test5InstallDirectory = Join-Path $rotationTestRoot "test05\LIMS-NEW"
        $test5OutsidePath = Join-Path $rotationTestRoot "test05\Elsewhere\BravoDebug.log"
        [void](New-BRAVOLogRotationFixture -Directory $test5InstallDirectory -Name "bravo.exe" -Content "exe")
        [void](New-BRAVOLogRotationFixture `
            -Directory (Join-Path $test5SystemRoot "SysWOW64") `
            -Name "bravo.ini" `
            -Content "[Debug]`r`nFILE=$test5OutsidePath`r`n")
        $test5Discovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $test5InstallDirectory `
            -Services @(New-BRAVOSyntheticBravoService -ExecutablePath (Join-Path $test5InstallDirectory "bravo.exe")) `
            -SystemRoot $test5SystemRoot `
            -Is64BitOperatingSystem $true
        Test-BRAVOCondition `
            -Condition (
                [string]$test5Discovery.TRACE_FILE -eq $test5OutsidePath -and
                [bool]$test5Discovery.TRACE_FILE_OUTSIDE_INSTALLATION
            ) `
            -Name "LogRotation/05-TraceOutsideInstallationIsFlagged" `
            -Failure "trace поза каталогом інсталяції BRAVO має бути позначений у діагностиці, але не втрачений"

        # --- Test 6: [Debug] без FILE -> помилка з назвами bravo.ini/[Debug]/FILE ---
        $test6SystemRoot = Join-Path $rotationTestRoot "test06\Windows"
        [void](New-BRAVOLogRotationFixture `
            -Directory (Join-Path $test6SystemRoot "SysWOW64") `
            -Name "bravo.ini" `
            -Content "[model]`r`nMODEL=D:\LIMS\MODEL\lims`r`n[Debug]`r`n")
        $test6Discovery = Resolve-BRAVOInstallationDiscovery `
            -LimsRoot $rotationTestRoot `
            -Services @() `
            -SystemRoot $test6SystemRoot `
            -Is64BitOperatingSystem $true
        $test6Configuration = Invoke-BRAVORotationHelper -Body {
            param($DiscoveryResult, $TraceRoot, $DateFolder)
            Get-BRAVOTraceConfiguration `
                -DiscoveryResult $DiscoveryResult `
                -TraceRootDirectory $TraceRoot `
                -DateFolderName $DateFolder
        } -Arguments @($test6Discovery, (Join-Path $rotationTestRoot "test06\Trace"), "2026-08-08")
        $test6Reason = [string]$test6Configuration.Reason
        Test-BRAVOCondition `
            -Condition (
                -not [bool]$test6Configuration.IsValid -and
                $test6Reason.Contains("bravo.ini") -and
                $test6Reason.Contains("[Debug]") -and
                $test6Reason.Contains("FILE")
            ) `
            -Name "LogRotation/06-MissingDebugFileIsConfigurationError" `
            -Failure "без ключа FILE у секції [Debug] має бути помилка конфігурації, у якій названо і bravo.ini, і [Debug], і FILE"

        # --- Test 7: Trace 5.2.0 — timestamp-ім'я з LastWriteTime джерела,
        # legacy sequence-файли в призначенні не заважають і не чіпаються ---
        $test7Source = Join-Path $rotationTestRoot "test07\src"
        $test7Destination = Join-Path $rotationTestRoot "test07\dst"
        foreach ($existingName in @("TraceSRV_1.out", "TraceSRV_2.out", "TraceSRV_5.out")) {
            [void](New-BRAVOLogRotationFixture -Directory $test7Destination -Name $existingName)
        }
        $test7TracePath = New-BRAVOLogRotationFixture -Directory $test7Source -Name "TraceSRV.out" -Content "trace"
        $test7Stamp = Get-Date -Date '2026-08-19 18:30:05'
        (Get-Item -LiteralPath $test7TracePath).LastWriteTime = $test7Stamp
        $test7Summary = Invoke-BRAVORotationHelper -Body {
            param($TracePath, $Destination, $Logger)
            Invoke-BRAVOTraceRotation `
                -Sources @([pscustomobject]@{ Name = 'TraceSRV'; Path = $TracePath }) `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test7TracePath, $test7Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test7Destination "TraceSRV_20260819_183005.out")) -and
                [int]$test7Summary.Moved -eq 1 -and
                (Test-Path -LiteralPath (Join-Path $test7Destination "TraceSRV_5.out")) -and
                $null -eq @($test7Summary.Results)[0].Sequence
            ) `
            -Name "LogRotation/07-TraceTimestampNameFromLastWriteTime" `
            -Failure "Trace має отримати ім'я TraceSRV_<yyyyMMdd_HHmmss>.out з LastWriteTime джерела, legacy _N-файли неторкнуті, Sequence у результаті `$null"

        # --- Test 7b: колізія timestamp -> наступна вільна секунда, без overwrite ---
        $test7bSource = Join-Path $rotationTestRoot "test07b\src"
        $test7bCollisionPath = Join-Path $test7Destination "TraceSRV_20260819_183005.out"
        $test7bCollisionSizeBefore = (Get-Item -LiteralPath $test7bCollisionPath).Length
        $test7bTracePath = New-BRAVOLogRotationFixture -Directory $test7bSource -Name "TraceSRV.out" -Content "trace-second-run-longer"
        (Get-Item -LiteralPath $test7bTracePath).LastWriteTime = $test7Stamp
        $test7bSummary = Invoke-BRAVORotationHelper -Body {
            param($TracePath, $Destination, $Logger)
            Invoke-BRAVOTraceRotation `
                -Sources @([pscustomobject]@{ Name = 'TraceSRV'; Path = $TracePath }) `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test7bTracePath, $test7Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test7bSummary.Moved -eq 1 -and
                (Test-Path -LiteralPath (Join-Path $test7Destination "TraceSRV_20260819_183006.out")) -and
                (Get-Item -LiteralPath $test7bCollisionPath).Length -eq $test7bCollisionSizeBefore
            ) `
            -Name "LogRotation/07b-TraceTimestampCollisionTakesNextSecond" `
            -Failure "колізія timestamp-імені має розв'язуватися наступною вільною секундою (183006), існуючий файл не перезаписується"

        # --- Test 8: порожній Trace лишається в джерелі ---
        $test8Source = Join-Path $rotationTestRoot "test08\src"
        $test8Destination = Join-Path $rotationTestRoot "test08\dst"
        $test8TracePath = New-BRAVOLogRotationFixture -Directory $test8Source -Name "TraceSRV.out" -Content ""
        $test8Summary = Invoke-BRAVORotationHelper -Body {
            param($TracePath, $Destination, $Logger)
            Invoke-BRAVOTraceRotation `
                -Sources @([pscustomobject]@{ Name = 'TraceSRV'; Path = $TracePath }) `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test8TracePath, $test8Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath $test8TracePath) -and
                [int]$test8Summary.Empty -eq 1 -and
                [int]$test8Summary.Moved -eq 0 -and
                [int]$test8Summary.Errors -eq 0 -and
                @(Get-BRAVOLogRotationNames -Directory $test8Destination).Count -eq 0
            ) `
            -Name "LogRotation/08-EmptyTraceRemainsInSource" `
            -Failure "порожній trace не переміщується, не видаляється й не створює файл призначення"

        # --- Test 9: відсутній Trace -> діагностика без фейкового файла ---
        $rotationLogMessages.Clear()
        $test9Destination = Join-Path $rotationTestRoot "test09\dst"
        $test9TracePath = Join-Path $rotationTestRoot "test09\src\TraceSRV.out"
        $test9Summary = Invoke-BRAVORotationHelper -Body {
            param($TracePath, $Destination, $Logger)
            Invoke-BRAVOTraceRotation `
                -Sources @(
                    [pscustomobject]@{ Name = 'TraceSRV'; Path = $TracePath }
                    [pscustomobject]@{ Name = 'TraceBIS'; Path = '' }
                ) `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test9TracePath, $test9Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test9Summary.Errors -eq 0 -and
                [int]$test9Summary.Moved -eq 0 -and
                -not (Test-Path -LiteralPath $test9TracePath) -and
                @($rotationLogMessages | Where-Object { $_ -like "*ще не створено*" }).Count -gt 0 -and
                @($rotationLogMessages | Where-Object { $_ -like "*TraceBIS*не налаштовано*" }).Count -gt 0
            ) `
            -Name "LogRotation/09-AbsentTraceIsDiagnosticOnly" `
            -Failure "відсутній trace дає діагностичне повідомлення (не помилку, без фейкового джерела), а неналаштований BIS — окремий INFO-пропуск"

        # --- Test 9b: недоступний SRV не блокує ротацію BIS (і навпаки) ---
        $test9bSource = Join-Path $rotationTestRoot "test09b\src"
        $test9bDestination = Join-Path $rotationTestRoot "test09b\dst"
        $test9bBisPath = New-BRAVOLogRotationFixture -Directory $test9bSource -Name "TraceBIS.out" -Content "bis data"
        (Get-Item -LiteralPath $test9bBisPath).LastWriteTime = Get-Date -Date '2026-08-19 11:00:00'
        $test9bSummary = Invoke-BRAVORotationHelper -Body {
            param($BisPath, $Destination, $Logger)
            Invoke-BRAVOTraceRotation `
                -Sources @(
                    [pscustomobject]@{ Name = 'TraceSRV'; Path = '' }
                    [pscustomobject]@{ Name = 'TraceBIS'; Path = $BisPath }
                ) `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test9bBisPath, $test9bDestination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test9bSummary.Moved -eq 1 -and
                [int]$test9bSummary.Errors -eq 0 -and
                (Test-Path -LiteralPath (Join-Path $test9bDestination "TraceBIS_20260819_110000.out"))
            ) `
            -Name "LogRotation/09b-UnavailableSrvDoesNotBlockBis" `
            -Failure "ненаналаштований/невалідний SRV не має блокувати ротацію BIS: TraceBIS_<ts>.out мусить з'явитися без помилок"

        # --- Test 9c: скан усіх *.out кореня інсталяції (нова модель) ---
        # Реальний лістинг сервера: TraceSRV.out, traceBIS.out, !TraceSRV.out,
        # TraceSRV2.out, traceBIS1.out — усе має стати джерелами; не-.out не
        # захоплюється; SRV-шлях з bravo.ini, що збігається з файлом кореня
        # ІНШИМ регістром, дедуплікується (OrdinalIgnoreCase — той самий
        # клас, що інцидент Compare-FileSizes).
        $test9cRoot = Join-Path $rotationTestRoot "test9c\install"
        foreach ($outName in @('TraceSRV.out', 'traceBIS.out', '!TraceSRV.out', 'TraceSRV2.out', 'traceBIS1.out')) {
            [void](New-BRAVOLogRotationFixture -Directory $test9cRoot -Name $outName -Content "data")
        }
        [void](New-BRAVOLogRotationFixture -Directory $test9cRoot -Name 'decoy.log' -Content "not-out")
        $test9cEnumeration = Invoke-BRAVORotationHelper -Body {
            param($Root)
            Get-BRAVOInstallationTraceOutSources `
                -InstallationRoot $Root `
                -LimsRoot 'C:\Unused' `
                -SrvTracePath (Join-Path $Root.ToLowerInvariant() 'TRACESRV.OUT') `
                -ExplicitBisPath ''
        } -Arguments @($test9cRoot)
        $test9cNames = @($test9cEnumeration.Sources | ForEach-Object { $_.Name })
        Test-BRAVOCondition `
            -Condition (
                @($test9cEnumeration.Sources).Count -eq 5 -and
                ($test9cNames -contains '!TraceSRV') -and
                ($test9cNames -contains 'TraceSRV2') -and
                ($test9cNames -contains 'traceBIS1') -and
                -not ($test9cNames -contains 'decoy')
            ) `
            -Name "LogRotation/09c-AllOutFilesEnumeratedFromInstallationRoot" `
            -Failure "скан кореня має дати 5 *.out-джерел (включно з !TraceSRV/TraceSRV2/traceBIS1), без не-.out і без дубліката SRV з іншим регістром; отримано: $($test9cNames -join ', ')"

        # --- Test 9d: фолбек LIMSRoot + додаткове BIS-джерело поза коренем;
        # 'off' не дає додаткового джерела; колізія basename -> суфікс _2 ---
        $test9dLims = Join-Path $rotationTestRoot "test9d\lims"
        [void](New-BRAVOLogRotationFixture -Directory $test9dLims -Name 'TraceSRV.out' -Content "srv")
        $test9dExternal = Join-Path $rotationTestRoot "test9d\external"
        $test9dExternalBis = New-BRAVOLogRotationFixture -Directory $test9dExternal -Name 'TraceSRV.out' -Content "external-with-same-basename"
        $test9dEnumeration = Invoke-BRAVORotationHelper -Body {
            param($Lims, $ExternalBis)
            Get-BRAVOInstallationTraceOutSources `
                -InstallationRoot '' `
                -LimsRoot $Lims `
                -SrvTracePath '' `
                -ExplicitBisPath $ExternalBis
        } -Arguments @($test9dLims, $test9dExternalBis)
        $test9dOffEnumeration = Invoke-BRAVORotationHelper -Body {
            param($Lims)
            Get-BRAVOInstallationTraceOutSources `
                -InstallationRoot '' `
                -LimsRoot $Lims `
                -SrvTracePath '' `
                -ExplicitBisPath 'off'
        } -Arguments @($test9dLims)
        $test9dNames = @($test9dEnumeration.Sources | ForEach-Object { $_.Name })
        Test-BRAVOCondition `
            -Condition (
                @($test9dEnumeration.Sources).Count -eq 2 -and
                ($test9dNames -contains 'TraceSRV') -and
                ($test9dNames -contains 'TraceSRV_2') -and
                [string]$test9dEnumeration.ScanRoot -eq $test9dLims -and
                @($test9dOffEnumeration.Sources).Count -eq 1
            ) `
            -Name "LogRotation/09d-FallbackLimsRootAndBasenameCollisionSuffix" `
            -Failure "фолбек LIMSRoot має сканувати LIMS-корінь; зовнішнє BIS-джерело з тим самим basename отримує ім'я TraceSRV_2; 'off' не додає джерела; отримано: $($test9dNames -join ', '); off-джерел: $(@($test9dOffEnumeration.Sources).Count)"

        # --- Test 9e: NamingPolicy 'Original' — ім'я зберігається як є;
        # колізія в цілі -> ERROR, джерело лишається на місці ---
        $test9eSource = Join-Path $rotationTestRoot "test9e\src"
        $test9eDestination = Join-Path $rotationTestRoot "test9e\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test9eSource -Name 'exchangAPI_2026-08-25_222302.log' -Content "payload-one")
        $rotationLogMessages.Clear()
        $test9eSummary = Invoke-BRAVORotationHelper -Body {
            param($SourcePath, $Destination, $Logger)
            Invoke-BRAVOLogRotation `
                -ComponentName 'exchangAPI' `
                -Items @((New-BRAVOLogRotationItem -Path $SourcePath)) `
                -DestinationRoot $Destination `
                -NamingPolicy 'Original' `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @((Join-Path $test9eSource 'exchangAPI_2026-08-25_222302.log'), $test9eDestination, $rotationLogger)
        $test9eCollisionSource = New-BRAVOLogRotationFixture -Directory $test9eSource -Name 'exchangAPI_2026-08-25_222302.log' -Content "payload-two-different"
        $test9eCollisionSummary = Invoke-BRAVORotationHelper -Body {
            param($SourcePath, $Destination, $Logger)
            Invoke-BRAVOLogRotation `
                -ComponentName 'exchangAPI' `
                -Items @((New-BRAVOLogRotationItem -Path $SourcePath)) `
                -DestinationRoot $Destination `
                -NamingPolicy 'Original' `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test9eCollisionSource, $test9eDestination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test9eSummary.Moved -eq 1 -and
                (Test-Path -LiteralPath (Join-Path $test9eDestination 'exchangAPI_2026-08-25_222302.log')) -and
                -not (Test-Path -LiteralPath (Join-Path $test9eDestination 'exchangAPI_2026-08-25_222302_1.log')) -and
                [int]$test9eCollisionSummary.Errors -eq 1 -and
                [int]$test9eCollisionSummary.Moved -eq 0 -and
                (Test-Path -LiteralPath $test9eCollisionSource) -and
                (Get-Content -LiteralPath (Join-Path $test9eDestination 'exchangAPI_2026-08-25_222302.log') -Raw) -eq 'payload-one'
            ) `
            -Name "LogRotation/09e-OriginalNamingPolicyKeepsNameAndFailsClosedOnCollision" `
            -Failure "Original-політика має зберегти ім'я без суфіксів; колізія = ERROR, джерело на місці, ціль не перезаписана; отримано Moved=$($test9eSummary.Moved), collision Errors=$($test9eCollisionSummary.Errors), Moved=$($test9eCollisionSummary.Moved)"

        # --- Test 10: обидва шаблони exchangAPI + дедуплікація за FullName ---
        $test10Source = Join-Path $rotationTestRoot "test10\src"
        foreach ($sourceName in @("exchangAPI.log", "exchangAPI_1.log", "exchangAPI_2.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test10Source -Name $sourceName -Content "x")
        }
        $test10Files = @(Invoke-BRAVORotationHelper -Body {
            param($Directory)
            Get-BRAVOExchangeApiLogFiles -Directory $Directory -Patterns @("exchangAPI_*.log", "exchangAPI*.log")
        } -Arguments @($test10Source))
        Test-BRAVOCondition `
            -Condition (
                $test10Files.Count -eq 3 -and
                @($test10Files | Select-Object -ExpandProperty FullName -Unique).Count -eq 3
            ) `
            -Name "LogRotation/10-ExchangeApiDualPatternDeduplicated" `
            -Failure "exchangAPI шукається за обома шаблонами, але exchangAPI_1.log відповідає обом — після merge має лишитись 3 унікальні файли, а не 5"

        # --- Test 11: номер джерела exchangAPI ігнорується ---
        $test11Source = Join-Path $rotationTestRoot "test11\src"
        $test11Destination = Join-Path $rotationTestRoot "test11\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test11Source -Name "exchangAPI_25.log" -Content "x")
        foreach ($existingName in @("exchangAPI_1.log", "exchangAPI_2.log", "exchangAPI_9.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test11Destination -Name $existingName)
        }
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOExchangeApiLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test11Source, $test11Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test11Destination "exchangAPI_25.log")) -and
                -not (Test-Path -LiteralPath (Join-Path $test11Destination "exchangAPI_10.log")) -and
                -not (Test-Path -LiteralPath (Join-Path $test11Destination "exchangAPI_25_1.log")) -and
                (Test-Path -LiteralPath (Join-Path $test11Destination "exchangAPI_9.log"))
            ) `
            -Name "LogRotation/11-ExchangeApiOriginalNamePreserved" `
            -Failure "нова модель: exchangAPI_25.log має зберегти ОРИГІНАЛЬНЕ ім'я (без перенумерації MAX+1 і без суфіксів), наявні файли призначення недоторкані"

        # --- Test 12: кілька файлів exchangAPI у стабільному порядку ---
        $test12Source = Join-Path $rotationTestRoot "test12\src"
        $test12Destination = Join-Path $rotationTestRoot "test12\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test12Source -Name "exchangAPI.log" -Content "first" -LastWriteTime ([datetime]"2026-08-08T10:00:00"))
        [void](New-BRAVOLogRotationFixture -Directory $test12Source -Name "exchangAPI_1.log" -Content "second" -LastWriteTime ([datetime]"2026-08-08T11:00:00"))
        [void](New-BRAVOLogRotationFixture -Directory $test12Source -Name "exchangAPI_error.log" -Content "third" -LastWriteTime ([datetime]"2026-08-08T12:00:00"))
        foreach ($existingName in @("exchangAPI_1.log", "exchangAPI_2.log", "exchangAPI_5.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test12Destination -Name $existingName)
        }
        $test12Summary = Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOExchangeApiLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test12Source, $test12Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test12Summary.Moved -eq 2 -and
                [int]$test12Summary.Errors -eq 1 -and
                [IO.File]::ReadAllText((Join-Path $test12Destination "exchangAPI.log")) -eq "first" -and
                [IO.File]::ReadAllText((Join-Path $test12Destination "exchangAPI_error.log")) -eq "third" -and
                [IO.File]::ReadAllText((Join-Path $test12Source "exchangAPI_1.log")) -eq "second" -and
                [IO.File]::ReadAllText((Join-Path $test12Destination "exchangAPI_1.log")) -ne "second"
            ) `
            -Name "LogRotation/12-ExchangeApiOriginalNamesWithCollisionFailClosed" `
            -Failure "нова модель: exchangAPI.log/exchangAPI_error.log переміщуються з оригінальними іменами; exchangAPI_1.log конфліктує з наявним у призначенні -> ERROR, джерело на місці, ціль не перезаписана; отримано Moved=$($test12Summary.Moved), Errors=$($test12Summary.Errors)"

        # --- Test 13: Apache бере лише журнали й не заходить у підкаталоги ---
        $test13Source = Join-Path $rotationTestRoot "test13\src"
        $test13Destination = Join-Path $rotationTestRoot "test13\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "access.log" -Content "a")
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "error.log" -Content "e")
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "httpd.pid" -Content "1234")
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "worker.lock" -Content "l")
        [void](New-BRAVOLogRotationFixture -Directory $test13Source -Name "temp.tmp" -Content "t")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test13Source "old") -Name "nested.log" -Content "n")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test13Source, $test13Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                ((Get-BRAVOLogRotationNames -Directory $test13Destination) -join ",") -eq "access_1.log,error_1.log" -and
                ((Get-BRAVOLogRotationNames -Directory $test13Source) -join ",") -eq "httpd.pid,temp.tmp,worker.lock" -and
                (Test-Path -LiteralPath (Join-Path $test13Source "old\nested.log"))
            ) `
            -Name "LogRotation/13-ApacheFiltersServiceFilesAndStaysFlat" `
            -Failure "Apache має брати лише *.log безпосередньо з apache\logs: httpd.pid/*.lock/*.tmp і вкладені каталоги лишаються недоторканими"

        # --- Test 14: незалежні послідовності Apache і пропуски в нумерації ---
        $test14Source = Join-Path $rotationTestRoot "test14\src"
        $test14Destination = Join-Path $rotationTestRoot "test14\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test14Source -Name "access.log" -Content "a")
        [void](New-BRAVOLogRotationFixture -Directory $test14Source -Name "error.log" -Content "e")
        [void](New-BRAVOLogRotationFixture -Directory $test14Source -Name "ssl_error.log" -Content "s")
        foreach ($existingName in @("access_1.log", "access_3.log", "access_10.log", "error_1.log", "error_9.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test14Destination -Name $existingName)
        }
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test14Source, $test14Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test14Destination "access_11.log")) -and
                (Test-Path -LiteralPath (Join-Path $test14Destination "error_10.log")) -and
                (Test-Path -LiteralPath (Join-Path $test14Destination "ssl_error_1.log"))
            ) `
            -Name "LogRotation/14-IndependentSequencesAndGapsNeverReused" `
            -Failure "кожне ім'я має власну послідовність, а пропуски не перевикористовуються: access->_11 (числове порівняння), error->_10, ssl_error->_1"

        # --- Test 15: BRAVO Web зберігає відносну структуру каталогів ---
        $test15Source = Join-Path $rotationTestRoot "test15\src"
        $test15Destination = Join-Path $rotationTestRoot "test15\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test15Source -Name "bravoexec.log" -Content "b")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test15Source "API") -Name "request.log" -Content "api")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test15Source "Integration\API") -Name "request.log" -Content "integration")
        $test15Summary = Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test15Source, $test15Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test15Summary.Moved -eq 3 -and
                (Test-Path -LiteralPath (Join-Path $test15Destination "bravoexec_1.log")) -and
                [IO.File]::ReadAllText((Join-Path $test15Destination "API\request_1.log")) -eq "api" -and
                [IO.File]::ReadAllText((Join-Path $test15Destination "Integration\API\request_1.log")) -eq "integration"
            ) `
            -Name "LogRotation/15-BravoWebRecursivePreservesStructure" `
            -Failure "www\log обходиться рекурсивно зі збереженням відносної структури: однакові імена в різних гілках не повинні колізувати"

        # --- Test 16: незалежна послідовність у кожному підкаталозі ---
        $test16Source = Join-Path $rotationTestRoot "test16\src"
        $test16Destination = Join-Path $rotationTestRoot "test16\dst"
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test16Source "API") -Name "request.log" -Content "api")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test16Source "Integration\API") -Name "request.log" -Content "integration")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test16Destination "API") -Name "request_1.log" -Content "old-api")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test16Destination "API") -Name "request_2.log" -Content "old-api-2")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test16Source, $test16Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                [IO.File]::ReadAllText((Join-Path $test16Destination "API\request_3.log")) -eq "api" -and
                [IO.File]::ReadAllText((Join-Path $test16Destination "Integration\API\request_1.log")) -eq "integration" -and
                [IO.File]::ReadAllText((Join-Path $test16Destination "API\request_1.log")) -eq "old-api"
            ) `
            -Name "LogRotation/16-SequencePerRelativeDirectory" `
            -Failure "послідовність рахується окремо для кожного відносного каталогу призначення: API\request_3.log і Integration\API\request_1.log"

        # --- Test 17: порожній application log лишається в джерелі ---
        $test17Source = Join-Path $rotationTestRoot "test17\src"
        $test17Destination = Join-Path $rotationTestRoot "test17\dst"
        $test17EmptyPath = New-BRAVOLogRotationFixture -Directory $test17Source -Name "errornum.log" -Content ""
        $test17Summary = Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test17Source, $test17Destination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test17Summary.Empty -eq 1 -and
                [int]$test17Summary.Moved -eq 0 -and
                [int]$test17Summary.Errors -eq 0 -and
                (Test-Path -LiteralPath $test17EmptyPath)
            ) `
            -Name "LogRotation/17-EmptyApplicationLogSkipped" `
            -Failure "порожній application log лишається в джерелі, не отримує номера й не є помилкою"

        # --- Test 18: жодного перезапису наявного журналу ---
        $test18Source = Join-Path $rotationTestRoot "test18\src"
        $test18Destination = Join-Path $rotationTestRoot "test18\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test18Source -Name "access.log" -Content "new-content")
        [void](New-BRAVOLogRotationFixture -Directory $test18Destination -Name "access_1.log" -Content "must-survive")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test18Source, $test18Destination, $rotationLogger))
        $moveWithSequenceBody = [regex]::Match(
            $maintenanceScriptText,
            '(?s)function Move-BRAVOLogWithSequence \{.*?\r?\n\}'
        )
        Test-BRAVOCondition `
            -Condition (
                [IO.File]::ReadAllText((Join-Path $test18Destination "access_1.log")) -eq "must-survive" -and
                [IO.File]::ReadAllText((Join-Path $test18Destination "access_2.log")) -eq "new-content" -and
                $moveWithSequenceBody.Success -and
                $moveWithSequenceBody.Value -notmatch 'Move-Item[^\r\n]*-Force'
            ) `
            -Name "LogRotation/18-NoOverwriteOfExistingLog" `
            -Failure "наявний файл призначення не можна перезаписувати: потрібен новий MAX+1 і жодного Move-Item -Force"

        # --- Test 19: структурований результат і перевірка після move ---
        $test19Source = Join-Path $rotationTestRoot "test19\src"
        $test19Destination = Join-Path $rotationTestRoot "test19\dst"
        $test19Content = "payload-0123456789"
        $test19SourcePath = New-BRAVOLogRotationFixture -Directory $test19Source -Name "firm.log" -Content $test19Content
        [void](New-BRAVOLogRotationFixture -Directory $test19Destination -Name "firm_4.log")
        $test19Result = Invoke-BRAVORotationHelper -Body {
            param($SourcePath, $Destination, $Logger)
            Move-BRAVOLogWithSequence `
                -SourcePath $SourcePath `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test19SourcePath, $test19Destination, $rotationLogger)
        $test19ExpectedSize = [Text.Encoding]::UTF8.GetByteCount($test19Content)
        Test-BRAVOCondition `
            -Condition (
                [string]$test19Result.Status -eq "MOVED" -and
                [int]$test19Result.Sequence -eq 5 -and
                [int]$test19Result.Attempts -eq 1 -and
                [int64]$test19Result.SourceSize -eq $test19ExpectedSize -and
                [int64]$test19Result.DestinationSize -eq $test19ExpectedSize -and
                -not (Test-Path -LiteralPath $test19SourcePath) -and
                (Test-Path -LiteralPath ([string]$test19Result.DestinationPath))
            ) `
            -Name "LogRotation/19-StructuredResultAndPostMoveValidation" `
            -Failure "результат move має містити Status/Sequence/Attempts/SourceSize/DestinationSize, а сам move — підтверджуватись відсутністю джерела, наявністю призначення й збігом розміру"

        # --- Test 20: журнал показує початкове й кінцеве ім'я, зокрема з підкаталогом ---
        $rotationLogMessages.Clear()
        $test20Source = Join-Path $rotationTestRoot "test20\src"
        $test20Destination = Join-Path $rotationTestRoot "test20\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test20Source -Name "exchangAPI_2.log" -Content "x")
        foreach ($existingName in @("exchangAPI_1.log", "exchangAPI_5.log")) {
            [void](New-BRAVOLogRotationFixture -Directory $test20Destination -Name $existingName)
        }
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOExchangeApiLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test20Source, $test20Destination, $rotationLogger))
        $test20NestedSource = Join-Path $rotationTestRoot "test20\web"
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test20NestedSource "API") -Name "request.log" -Content "api")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOWebApplicationLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test20NestedSource, (Join-Path $rotationTestRoot "test20\webdst"), $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                @($rotationLogMessages | Where-Object {
                    $_ -eq "[SUCCESS] Переміщено exchangAPI_2.log -> exchangAPI_2.log"
                }).Count -eq 1 -and
                @($rotationLogMessages | Where-Object {
                    $_ -eq "[SUCCESS] Переміщено API\request.log -> API\request_1.log"
                }).Count -eq 1
            ) `
            -Name "LogRotation/20-MoveLogShowsBothNames" `
            -Failure "успішне переміщення має показувати початкове І кінцеве ім'я, а для вкладених журналів — разом із відносним каталогом"

        # --- Test 21: агрегована статистика компонента ---
        $rotationLogMessages.Clear()
        $test21Source = Join-Path $rotationTestRoot "test21\src"
        $test21Destination = Join-Path $rotationTestRoot "test21\dst"
        [void](New-BRAVOLogRotationFixture -Directory $test21Source -Name "access.log" -Content "a")
        [void](New-BRAVOLogRotationFixture -Directory $test21Source -Name "error.log" -Content "")
        [void](Invoke-BRAVORotationHelper -Body {
            param($Source, $Destination, $Logger)
            Invoke-BRAVOApacheLogRotation `
                -SourceDirectory $Source `
                -DestinationDirectory $Destination `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test21Source, $test21Destination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                @($rotationLogMessages | Where-Object {
                    $_ -eq "[SUCCESS] Apache: знайдено: 2, непорожніх: 1, переміщено: 1, порожніх: 1, пропущено: 1, помилок: 0"
                }).Count -eq 1
            ) `
            -Name "LogRotation/21-AggregatedSummaryIsLogged" `
            -Failure "кожен компонент має завершуватись агрегованим рядком «знайдено/непорожніх/переміщено/порожніх/пропущено/помилок»"

        # --- Test 22: робочий каталог exchangAPI (NSSM і Win32_Service) ---
        $test22NssmResult = Invoke-BRAVORotationHelper -Body {
            param($ServiceInstance, $NssmParameters)
            Resolve-BRAVOExchangeApiRuntimeDirectory `
                -ServiceName "exchangAPI" `
                -FallbackDirectory "D:\LIMS-FALLBACK" `
                -ServiceInstance $ServiceInstance `
                -NssmParameters $NssmParameters
        } -Arguments @(
            [pscustomobject]@{ PathName = '"C:\nssm\nssm.exe"' },
            @{ Application = "C:\LIMS\exchangAPI.exe"; AppDirectory = "C:\LIMS\" }
        )
        $test22ServiceResult = Invoke-BRAVORotationHelper -Body {
            param($ServiceInstance, $NssmParameters)
            Resolve-BRAVOExchangeApiRuntimeDirectory `
                -ServiceName "exchangAPI" `
                -FallbackDirectory "D:\LIMS-FALLBACK" `
                -ServiceInstance $ServiceInstance `
                -NssmParameters $NssmParameters
        } -Arguments @(
            [pscustomobject]@{ PathName = '"C:\LIMS\exchangAPI.exe" -k runservice' },
            @{}
        )
        $test22FallbackResult = Invoke-BRAVORotationHelper -Body {
            param($ServiceInstance, $NssmParameters)
            Resolve-BRAVOExchangeApiRuntimeDirectory `
                -ServiceName "exchangAPI" `
                -FallbackDirectory "D:\LIMS-FALLBACK" `
                -ServiceInstance $ServiceInstance `
                -NssmParameters $NssmParameters
        } -Arguments @([pscustomobject]@{ PathName = "" }, @{})
        Test-BRAVOCondition `
            -Condition (
                [string]$test22NssmResult.Directory -eq "C:\LIMS" -and
                [string]$test22ServiceResult.Directory -eq "C:\LIMS" -and
                [string]$test22FallbackResult.Directory -eq "D:\LIMS-FALLBACK" -and
                ([string]$test22FallbackResult.Reason).Contains("fallback")
            ) `
            -Name "LogRotation/22-ExchangeApiRuntimeDirectoryResolution" `
            -Failure "робочий каталог exchangAPI: NSSM AppDirectory має пріоритет, інакше Win32_Service.PathName, і лише потім явно позначений fallback"

        # --- Test 23: міграція legacy-каталогів, ідемпотентна ---
        $test23ArchiveRoot = Join-Path $rotationTestRoot "test23\ARCHIV"
        $test23LogRoot = Join-Path $test23ArchiveRoot "LOGS"
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test23ArchiveRoot "Trace\2026-07-01") -Name "TraceSRV_000001.out" -Content "old-trace")
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test23ArchiveRoot "Trace") -Name "Trace_2026-06-01.mdz" -Content "archive")
        [void](New-BRAVOLogRotationFixture `
            -Directory (Join-Path $test23ArchiveRoot "exchangAPI") `
            -Name "exchangAPI_3.log" `
            -Content "legacy-loose" `
            -LastWriteTime ([datetime]"2026-07-05T09:00:00"))
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test23ArchiveRoot "Br-a-vo.web\2026-07-02") -Name "access_000001.log" -Content "web")
        $test23Plan = @(Invoke-BRAVORotationHelper -Body {
            param($ArchiveRoot, $LogRoot)
            Get-BRAVOLegacyLogMigrationPlan -ArchiveRoot $ArchiveRoot -LogRoot $LogRoot
        } -Arguments @($test23ArchiveRoot, $test23LogRoot))
        foreach ($migrationPass in @(1, 2)) {
            foreach ($planEntry in $test23Plan) {
                [void](Invoke-BRAVORotationHelper -Body {
                    param($Entry, $Logger)
                    Invoke-BRAVOLegacyLogMigration `
                        -LegacyPath $Entry.LegacyPath `
                        -DestinationPath $Entry.DestinationPath `
                        -LogicalBaseName ([string]$Entry.LogicalBaseName) `
                        -RetryCount 1 `
                        -RetryDelaySeconds 0 `
                        -Logger $Logger
                } -Arguments @($planEntry, $rotationLogger))
            }
        }
        $test23MigratedFiles = @(
            Get-ChildItem -LiteralPath $test23LogRoot -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name |
                Sort-Object
        )
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test23LogRoot "Trace\2026-07-01\TraceSRV_000001.out")) -and
                (Test-Path -LiteralPath (Join-Path $test23LogRoot "Trace\Trace_2026-06-01.mdz")) -and
                (Test-Path -LiteralPath (Join-Path $test23LogRoot "exchangAPI\2026-07-05\exchangAPI_1.log")) -and
                (Test-Path -LiteralPath (Join-Path $test23LogRoot "BravoWeb\2026-07-02\access_000001.log")) -and
                -not (Test-Path -LiteralPath (Join-Path $test23ArchiveRoot "Trace")) -and
                -not (Test-Path -LiteralPath (Join-Path $test23ArchiveRoot "exchangAPI")) -and
                -not (Test-Path -LiteralPath (Join-Path $test23ArchiveRoot "Br-a-vo.web")) -and
                $test23MigratedFiles.Count -eq 4
            ) `
            -Name "LogRotation/23-LegacyMigrationIsIdempotent" `
            -Failure "legacy-каталоги мають мігрувати під LOGS зі збереженням структури (плоскі журнали — у каталог-дату за LastWriteTime), а повторний запуск не повинен створювати дублікатів"

        # --- Test 24: часткова невдача міграції зберігає джерело ---
        $test24ArchiveRoot = Join-Path $rotationTestRoot "test24\ARCHIV"
        $test24LogRoot = Join-Path $test24ArchiveRoot "LOGS"
        $test24LegacyPath = Join-Path $test24ArchiveRoot "Trace"
        [void](New-BRAVOLogRotationFixture -Directory (Join-Path $test24LegacyPath "2026-07-01") -Name "TraceSRV_1.out" -Content "movable")
        $test24LockedPath = New-BRAVOLogRotationFixture -Directory (Join-Path $test24LegacyPath "2026-07-01") -Name "TraceSRV_2.out" -Content "locked"
        $test24LockStream = [IO.File]::Open($test24LockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $test24Result = Invoke-BRAVORotationHelper -Body {
                param($LegacyPath, $DestinationPath, $Logger)
                Invoke-BRAVOLegacyLogMigration `
                    -LegacyPath $LegacyPath `
                    -DestinationPath $DestinationPath `
                    -RetryCount 1 `
                    -RetryDelaySeconds 0 `
                    -Logger $Logger
            } -Arguments @($test24LegacyPath, (Join-Path $test24LogRoot "Trace"), $rotationLogger)
        } finally {
            $test24LockStream.Dispose()
        }
        Test-BRAVOCondition `
            -Condition (
                [int]$test24Result.Failed -ge 1 -and
                [int]$test24Result.Migrated -ge 1 -and
                -not [bool]$test24Result.LegacyRemoved -and
                (Test-Path -LiteralPath $test24LockedPath) -and
                (Test-Path -LiteralPath (Join-Path $test24LogRoot "Trace\2026-07-01\TraceSRV_1.out"))
            ) `
            -Name "LogRotation/24-PartialMigrationRetainsSource" `
            -Failure "при частковій невдачі міграції невдалий файл і legacy-каталог мають лишитись для наступного запуску, а успішні — залишитись мігрованими"

        # --- Test 24a: продакшен-знахідка — timestamped exchangAPI legacy-ім'я
        # зберігається БЕЗ перейменування у sequence-стиль ---
        $test24aArchiveRoot = Join-Path $rotationTestRoot "test24a\ARCHIV"
        $test24aLegacyPath = Join-Path $test24aArchiveRoot "exchangAPI"
        $test24aDestination = Join-Path $test24aArchiveRoot "LOGS\exchangAPI"
        [void](New-BRAVOLogRotationFixture -Directory $test24aLegacyPath -Name "exchangAPI_2026-05-18_235930.log" -Content "timestamped-payload")
        $test24aResult = Invoke-BRAVORotationHelper -Body {
            param($LegacyPath, $DestinationPath, $Logger)
            Invoke-BRAVOLegacyLogMigration `
                -LegacyPath $LegacyPath `
                -DestinationPath $DestinationPath `
                -LogicalBaseName 'exchangAPI' `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test24aLegacyPath, $test24aDestination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test24aResult.Migrated -eq 1 -and
                [int]$test24aResult.Failed -eq 0 -and
                (Test-Path -LiteralPath (Join-Path $test24aDestination "exchangAPI_2026-05-18_235930.log")) -and
                -not (Test-Path -LiteralPath (Join-Path $test24aDestination "exchangAPI_1.log")) -and
                -not (Test-Path -LiteralPath $test24aLegacyPath)
            ) `
            -Name "LogRotation/LegacyExchangeApiTimestampNamePreserved" `
            -Failure "timestamped legacy exchangAPI-файл має мігрувати з ТИМ САМИМ іменем (exchangAPI_2026-05-18_235930.log), а не перетворитись на exchangAPI_1.log"

        # --- Test 24b: кілька timestamped-файлів — кожен зберігає власне ім'я ---
        $test24bArchiveRoot = Join-Path $rotationTestRoot "test24b\ARCHIV"
        $test24bLegacyPath = Join-Path $test24bArchiveRoot "exchangAPI"
        $test24bDestination = Join-Path $test24bArchiveRoot "LOGS\exchangAPI"
        $test24bNames = @(
            "exchangAPI_2025-08-18_211452.log",
            "exchangAPI_2026-05-18_235930.log",
            "exchangAPI_2026-05-19_010000.log"
        )
        foreach ($test24bName in $test24bNames) {
            [void](New-BRAVOLogRotationFixture -Directory $test24bLegacyPath -Name $test24bName -Content $test24bName)
        }
        $test24bResult = Invoke-BRAVORotationHelper -Body {
            param($LegacyPath, $DestinationPath, $Logger)
            Invoke-BRAVOLegacyLogMigration `
                -LegacyPath $LegacyPath `
                -DestinationPath $DestinationPath `
                -LogicalBaseName 'exchangAPI' `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test24bLegacyPath, $test24bDestination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test24bResult.Migrated -eq 3 -and
                [int]$test24bResult.Failed -eq 0 -and
                (@($test24bNames | ForEach-Object {
                    Test-Path -LiteralPath (Join-Path $test24bDestination $_)
                }) -notcontains $false) -and
                (@(Get-ChildItem -LiteralPath $test24bDestination -File).Count -eq 3)
            ) `
            -Name "LogRotation/LegacyExchangeApiMultipleTimestampNamesPreserved" `
            -Failure "усі три timestamped legacy-файли мають мігрувати кожен під власним оригінальним іменем, без взаємних колізій чи перенумерації"

        # --- Test 24c: timestamped-гілка не використовує sequence engine
        # (немає каталогу-дати, немає _N-нумерації) ---
        $test24cArchiveRoot = Join-Path $rotationTestRoot "test24c\ARCHIV"
        $test24cLegacyPath = Join-Path $test24cArchiveRoot "exchangAPI"
        $test24cDestination = Join-Path $test24cArchiveRoot "LOGS\exchangAPI"
        [void](New-BRAVOLogRotationFixture `
            -Directory $test24cLegacyPath `
            -Name "exchangAPI_2026-05-18_235930.log" `
            -Content "x" `
            -LastWriteTime ([datetime]"2026-05-18T23:59:30"))
        [void](Invoke-BRAVORotationHelper -Body {
            param($LegacyPath, $DestinationPath, $Logger)
            Invoke-BRAVOLegacyLogMigration `
                -LegacyPath $LegacyPath `
                -DestinationPath $DestinationPath `
                -LogicalBaseName 'exchangAPI' `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test24cLegacyPath, $test24cDestination, $rotationLogger))
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test24cDestination "exchangAPI_2026-05-18_235930.log")) -and
                -not (Test-Path -LiteralPath (Join-Path $test24cDestination "2026-05-18")) -and
                (@(Get-ChildItem -LiteralPath $test24cDestination -Directory -ErrorAction SilentlyContinue).Count -eq 0)
            ) `
            -Name "LogRotation/LegacyExchangeApiTimestampMigrationDoesNotUseSequence" `
            -Failure "timestamped exchangAPI-файл має лягти ПЛОСКО в корінь призначення (той самий контракт, що й поточна НЕ-legacy ротація) — без каталогу-дати за LastWriteTime і без sequence engine"

        # --- Test 24d: вміст/розмір не змінюються при міграції ---
        $test24dArchiveRoot = Join-Path $rotationTestRoot "test24d\ARCHIV"
        $test24dLegacyPath = Join-Path $test24dArchiveRoot "exchangAPI"
        $test24dDestination = Join-Path $test24dArchiveRoot "LOGS\exchangAPI"
        $test24dSourcePath = New-BRAVOLogRotationFixture -Directory $test24dLegacyPath -Name "exchangAPI_2026-05-18_235930.log" -Content "byte-identical-payload-12345"
        $test24dSourceHash = (Get-FileHash -LiteralPath $test24dSourcePath -Algorithm SHA256).Hash
        [void](Invoke-BRAVORotationHelper -Body {
            param($LegacyPath, $DestinationPath, $Logger)
            Invoke-BRAVOLegacyLogMigration `
                -LegacyPath $LegacyPath `
                -DestinationPath $DestinationPath `
                -LogicalBaseName 'exchangAPI' `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test24dLegacyPath, $test24dDestination, $rotationLogger))
        $test24dDestinationPath = Join-Path $test24dDestination "exchangAPI_2026-05-18_235930.log"
        $test24dDestinationHash = if (Test-Path -LiteralPath $test24dDestinationPath) {
            (Get-FileHash -LiteralPath $test24dDestinationPath -Algorithm SHA256).Hash
        } else { $null }
        Test-BRAVOCondition `
            -Condition (
                $null -ne $test24dDestinationHash -and
                $test24dDestinationHash -eq $test24dSourceHash
            ) `
            -Name "LogRotation/LegacyExchangeApiTimestampContentPreserved" `
            -Failure "SHA256 timestamped exchangAPI-файла до і після міграції має збігатися — очікувано $test24dSourceHash, отримано $test24dDestinationHash"

        # --- Test 24e: колізія імені у призначенні -> fail-closed, без
        # перезапису й без перейменування джерела ---
        $test24eArchiveRoot = Join-Path $rotationTestRoot "test24e\ARCHIV"
        $test24eLegacyPath = Join-Path $test24eArchiveRoot "exchangAPI"
        $test24eDestination = Join-Path $test24eArchiveRoot "LOGS\exchangAPI"
        $test24eSourcePath = New-BRAVOLogRotationFixture -Directory $test24eLegacyPath -Name "exchangAPI_2026-05-18_235930.log" -Content "source-content"
        [void](New-BRAVOLogRotationFixture -Directory $test24eDestination -Name "exchangAPI_2026-05-18_235930.log" -Content "already-there")
        $test24eResult = Invoke-BRAVORotationHelper -Body {
            param($LegacyPath, $DestinationPath, $Logger)
            Invoke-BRAVOLegacyLogMigration `
                -LegacyPath $LegacyPath `
                -DestinationPath $DestinationPath `
                -LogicalBaseName 'exchangAPI' `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test24eLegacyPath, $test24eDestination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test24eResult.Failed -eq 1 -and
                [int]$test24eResult.Migrated -eq 0 -and
                (Test-Path -LiteralPath $test24eSourcePath) -and
                (Get-Content -LiteralPath $test24eSourcePath -Raw) -eq 'source-content' -and
                (Get-Content -LiteralPath (Join-Path $test24eDestination "exchangAPI_2026-05-18_235930.log") -Raw) -eq 'already-there' -and
                -not (Test-Path -LiteralPath (Join-Path $test24eDestination "exchangAPI_2026-05-18_235930_1.log"))
            ) `
            -Name "LogRotation/LegacyExchangeApiTimestampCollisionFailsClosed" `
            -Failure "колізія імені при міграції timestamped exchangAPI-файла має завершитись ПОМИЛКОЮ: джерело на місці, ціль не перезаписана, жодного _1-суфікса не згенеровано"

        # --- Test 24f: повторний запуск міграції ідемпотентний ---
        $test24fArchiveRoot = Join-Path $rotationTestRoot "test24f\ARCHIV"
        $test24fLegacyPath = Join-Path $test24fArchiveRoot "exchangAPI"
        $test24fDestination = Join-Path $test24fArchiveRoot "LOGS\exchangAPI"
        [void](New-BRAVOLogRotationFixture -Directory $test24fLegacyPath -Name "exchangAPI_2026-05-18_235930.log" -Content "idempotent-payload")
        foreach ($migrationPass in @(1, 2)) {
            [void](Invoke-BRAVORotationHelper -Body {
                param($LegacyPath, $DestinationPath, $Logger)
                Invoke-BRAVOLegacyLogMigration `
                    -LegacyPath $LegacyPath `
                    -DestinationPath $DestinationPath `
                    -LogicalBaseName 'exchangAPI' `
                    -RetryCount 1 `
                    -RetryDelaySeconds 0 `
                    -Logger $Logger
            } -Arguments @($test24fLegacyPath, $test24fDestination, $rotationLogger))
        }
        Test-BRAVOCondition `
            -Condition (
                (Test-Path -LiteralPath (Join-Path $test24fDestination "exchangAPI_2026-05-18_235930.log")) -and
                (@(Get-ChildItem -LiteralPath $test24fDestination -File).Count -eq 1) -and
                -not (Test-Path -LiteralPath $test24fLegacyPath)
            ) `
            -Name "LogRotation/LegacyExchangeApiTimestampMigrationIdempotent" `
            -Failure "повторний запуск міграції над тим самим legacy-деревом не повинен створювати дублікатів чи _migrated_N-варіантів — перший прогін уже переніс і прибрав джерело"

        # --- Test 24g: старі sequence-стильні legacy-імена й далі мігрують
        # через попередню (незмінену) поведінку — сумісність збережена ---
        $test24gArchiveRoot = Join-Path $rotationTestRoot "test24g\ARCHIV"
        $test24gLegacyPath = Join-Path $test24gArchiveRoot "exchangAPI"
        $test24gDestination = Join-Path $test24gArchiveRoot "LOGS\exchangAPI"
        [void](New-BRAVOLogRotationFixture `
            -Directory $test24gLegacyPath `
            -Name "exchangAPI_3.log" `
            -Content "old-sequence-style" `
            -LastWriteTime ([datetime]"2026-07-05T09:00:00"))
        $test24gResult = Invoke-BRAVORotationHelper -Body {
            param($LegacyPath, $DestinationPath, $Logger)
            Invoke-BRAVOLegacyLogMigration `
                -LegacyPath $LegacyPath `
                -DestinationPath $DestinationPath `
                -LogicalBaseName 'exchangAPI' `
                -RetryCount 1 `
                -RetryDelaySeconds 0 `
                -Logger $Logger
        } -Arguments @($test24gLegacyPath, $test24gDestination, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test24gResult.Migrated -eq 1 -and
                (Test-Path -LiteralPath (Join-Path $test24gDestination "2026-07-05\exchangAPI_1.log"))
            ) `
            -Name "LogRotation/LegacyExchangeApiOldSequenceCompatibility" `
            -Failure "стара поведінка для СПРАВЖНІХ legacy sequence-імен (exchangAPI_3.log) має лишитись незмінною: каталог-дата за LastWriteTime + sequence engine (exchangAPI_1.log), той самий контракт, що LogRotation/23"

        # --- Test 24h: детектор timestamped-імені узгоджений з тим, які
        # файли поточна (НЕ-legacy) ротація exchangAPI взагалі вважає своїми ---
        $test24hPositive = @(
            "exchangAPI_2026-05-18_235930.log",
            "exchangAPI_2025-08-18_211452.log",
            "exchangAPI_2026-01-01_000000.log"
        )
        $test24hNegative = @(
            "exchangAPI.log",
            "exchangAPI_1.log",
            "exchangAPI_25.log",
            "exchangAPI_2026-05-18_235930.mdz",
            "exchangAPI_2026-5-18_235930.log",
            "Trace_2026-05-18_235930.log",
            "exchangAPI_20260518_235930.log"
        )
        $test24hPositiveResults = @($test24hPositive | ForEach-Object {
            Invoke-BRAVORotationHelper -Body {
                param($Name) Test-BRAVOIsTimestampedExchangeApiLogName -Name $Name
            } -Arguments @($_)
        })
        $test24hNegativeResults = @($test24hNegative | ForEach-Object {
            Invoke-BRAVORotationHelper -Body {
                param($Name) Test-BRAVOIsTimestampedExchangeApiLogName -Name $Name
            } -Arguments @($_)
        })
        Test-BRAVOCondition `
            -Condition (
                ($test24hPositiveResults -notcontains $false) -and
                ($test24hNegativeResults -notcontains $true)
            ) `
            -Name "LogRotation/ExchangeApiNormalAndLegacyNamingContractMatch" `
            -Failure "Test-BRAVOIsTimestampedExchangeApiLogName має розпізнавати рівно формат <Base>_yyyy-MM-dd_HHmmss.log (той, що пише сучасний застосунок і зберігає поточна НЕ-legacy ротація) і відхиляти старі sequence-імена, .mdz, чужі компоненти та формати, що не збігаються буквально"

        # --- Test 25: CompressedLogDays — окрема політика для .mdz ---
        $test25Path = Join-Path $rotationTestRoot "test25\Trace"
        $test25FreshDate = (Get-Date).AddDays(-100).ToString("yyyy-MM-dd")
        $test25ExpiredDate = (Get-Date).AddDays(-200).ToString("yyyy-MM-dd")
        [void](New-BRAVOLogRotationFixture -Directory $test25Path -Name "Trace_$test25FreshDate.mdz" -Content "fresh")
        [void](New-BRAVOLogRotationFixture -Directory $test25Path -Name "Trace_$test25ExpiredDate.mdz" -Content "expired")
        [void](New-BRAVOLogRotationFixture -Directory $test25Path -Name "Apache_$test25ExpiredDate.mdz" -Content "foreign")
        [void](New-BRAVOLogRotationFixture -Directory $test25Path -Name "Trace_backup.mdz" -Content "no-date")
        $test25Result = Invoke-BRAVORotationHelper -Body {
            param($Path, $Logger)
            Remove-BRAVOExpiredCompressedLogs `
                -Path $Path `
                -ArchiveNamePrefix "Trace" `
                -RetentionDays 180 `
                -Logger $Logger
        } -Arguments @($test25Path, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test25Result.Deleted -eq 1 -and
                (Test-Path -LiteralPath (Join-Path $test25Path "Trace_$test25FreshDate.mdz")) -and
                -not (Test-Path -LiteralPath (Join-Path $test25Path "Trace_$test25ExpiredDate.mdz")) -and
                (Test-Path -LiteralPath (Join-Path $test25Path "Apache_$test25ExpiredDate.mdz")) -and
                (Test-Path -LiteralPath (Join-Path $test25Path "Trace_backup.mdz"))
            ) `
            -Name "LogRotation/25-CompressedLogDaysRetention" `
            -Failure "CompressedLogDays видаляє лише .mdz власного компонента, старші за строк: 100-денний лишається, 200-денний видаляється, чужі й недатовані архіви не чіпаються"

        # --- Test 25b: обидва формати дат (legacy YYYY-MM-DD і новий
        # Trace_YYYYMMDD 5.2.0) підпадають під ту саму retention-політику ---
        $test25bPath = Join-Path $rotationTestRoot "test25b\Trace"
        $test25bExpiredCompact = (Get-Date).AddDays(-200).ToString("yyyyMMdd")
        $test25bFreshCompact = (Get-Date).AddDays(-100).ToString("yyyyMMdd")
        [void](New-BRAVOLogRotationFixture -Directory $test25bPath -Name "Trace_$test25bExpiredCompact.mdz" -Content "expired-compact")
        [void](New-BRAVOLogRotationFixture -Directory $test25bPath -Name "Trace_$test25bFreshCompact.mdz" -Content "fresh-compact")
        [void](New-BRAVOLogRotationFixture -Directory $test25bPath -Name "Trace_$test25ExpiredDate.mdz" -Content "expired-legacy")
        $test25bResult = Invoke-BRAVORotationHelper -Body {
            param($Path, $Logger)
            Remove-BRAVOExpiredCompressedLogs `
                -Path $Path `
                -ArchiveNamePrefix "Trace" `
                -RetentionDays 180 `
                -Logger $Logger
        } -Arguments @($test25bPath, $rotationLogger)
        Test-BRAVOCondition `
            -Condition (
                [int]$test25bResult.Deleted -eq 2 -and
                -not (Test-Path -LiteralPath (Join-Path $test25bPath "Trace_$test25bExpiredCompact.mdz")) -and
                -not (Test-Path -LiteralPath (Join-Path $test25bPath "Trace_$test25ExpiredDate.mdz")) -and
                (Test-Path -LiteralPath (Join-Path $test25bPath "Trace_$test25bFreshCompact.mdz"))
            ) `
            -Name "LogRotation/25b-BothMdzDateFormatsShareRetentionPolicy" `
            -Failure "прострочені Trace_YYYYMMDD.mdz і Trace_YYYY-MM-DD.mdz видаляються однією політикою, свіжий компактний лишається"

        # --- Test 25c: CompressedLogDeletionEnabled гейтує і скан, і виклик
        # (типово `$false — жоден .mdz не видаляється за віком) ---
        Test-BRAVOCondition `
            -Condition (
                $maintenanceScriptText.Contains('if ($COMPRESSED_LOG_DELETION_ENABLED) {') -and
                $maintenanceScriptText.Contains('if ($COMPRESSED_LOG_DELETION_ENABLED -and $expiredCompressedLogCount -gt 0) {') -and
                $maintenanceScriptText.Contains('$MaintenanceConfig.Retention.Contains("CompressedLogDeletionEnabled")')
            ) `
            -Name "LogRotation/25c-CompressedLogDeletionRequiresExplicitFlag" `
            -Failure "видалення стиснутих .mdz за віком має бути двічі гейтоване CompressedLogDeletionEnabled (скан кандидатів + виклик), із захисним Contains-читанням конфіга"

        # --- Test 26: цільова структура, конфігурація і нерекурсивний cleanup ---
        $removeOldLogFilesBody = [regex]::Match(
            $maintenanceScriptText,
            '(?s)function Remove-OldLogFiles \{.*?\r?\n\}'
        )
        $removeOldLogFilesCallTargets = @(
            [regex]::Matches($maintenanceScriptText, 'Remove-OldLogFiles -Path (\$\w+)') |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -ne '$LOG_DIR' }
        )
        $bravoConfigTextForRetention = [IO.File]::ReadAllText($resolvedConfig, [Text.Encoding]::UTF8)
        Test-BRAVOCondition `
            -Condition (
                $maintenanceScriptText.Contains('$TRACE_DIR = Join-Path $SYSTEM_LOG_ROOT "Trace"') -and
                $maintenanceScriptText.Contains('$EXCHANGE_LOG_DIR = Join-Path $SYSTEM_LOG_ROOT "exchangAPI"') -and
                $maintenanceScriptText.Contains('$APACHE_LOG_DIR = Join-Path $BRAVOWEB_LOG_DIR "Apache"') -and
                $maintenanceScriptText.Contains('$BRAVOWEB_APP_LOG_DIR = Join-Path $BRAVOWEB_LOG_DIR "Application"') -and
                $bravoConfigTextForRetention -match 'CompressedLogDays\s*=\s*\d+' -and
                $maintenanceScriptText.Contains('$COMPRESSED_LOG_RETENTION_DAYS') -and
                $removeOldLogFilesBody.Success -and
                $removeOldLogFilesBody.Value -notmatch '-Recurse' -and
                $removeOldLogFilesBody.Value.Contains('BRAVO_MAINTENANCE_*.log') -and
                $removeOldLogFilesBody.Value -notmatch '"\*\.log"' -and
                $removeOldLogFilesCallTargets.Count -eq 0
            ) `
            -Name "LogRotation/26-LayoutRetentionSettingsAndNonRecursiveCleanup" `
            -Failure "структура LOGS\{Trace,exchangAPI,BravoWeb\{Apache,Application}}, окремий CompressedLogDays у BRAVO.config і нерекурсивне whitelist-очищення тільки верхнього рівня LOGS"

        # --- Test 27: відновлення служб не залежить від помилок ротації ---
        # Реальні служби не чіпаємо (ТЗ §103) — перевіряємо структуру:
        # уся ротація живе всередині try, а запуск служб — у finally, тому
        # жодна помилка ротації не може залишити production зупиненим.
        $serviceRestoreBlockIndex = $maintenanceScriptText.IndexOf('=== ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ ===')
        $finallyIndex = $maintenanceScriptText.LastIndexOf('} finally {', $serviceRestoreBlockIndex)
        $rotationIndex = $maintenanceScriptText.IndexOf('=== ОБРОБКА TRACE-ФАЙЛІВ ===')
        Test-BRAVOCondition `
            -Condition (
                $serviceRestoreBlockIndex -gt 0 -and
                $finallyIndex -gt 0 -and
                $rotationIndex -gt 0 -and
                $rotationIndex -lt $finallyIndex -and
                $maintenanceScriptText.Contains('$serviceWasRunning') -and
                $maintenanceScriptText.Contains('if ($serviceWasRunning.ExchangeApi) {') -and
                $maintenanceScriptText.Contains('if ($serviceWasRunning.BravoWeb) {')
            ) `
            -Name "LogRotation/27-ServiceRestorationIsIndependentOfRotation" `
            -Failure "ротація має виконуватись усередині try, а відновлення служб — у finally за збереженим початковим станом: помилка ротації не може залишити служби зупиненими"
    } finally {
        if (Test-Path -LiteralPath $rotationTestRoot) {
            Remove-Item -LiteralPath $rotationTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
