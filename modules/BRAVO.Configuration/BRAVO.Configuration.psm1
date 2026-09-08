Set-StrictMode -Version 2.0

# BRAVO.Configuration — canonical built-in raw defaults + generic
# hashtable merge/precedence engine (P0 Configuration Foundation, PR A).
#
# Область цього модуля (docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md):
#   - Get-BRAVODefaultConfiguration: ОДНЕ canonical джерело built-in raw
#     defaults (те, що сьогодні жорстко закодоване у верхніх raw-блоках
#     BRAVO.config — bravoSettings, pathSettings, maintenanceSettings
#     тощо), БЕЗ derivation (discovery, effective-* корені,
#     archiveDefinitions/archiveDirs/sourcePaths, runtime-шляхи, шляхи
#     стану — усе це лишається обчислюватись канонічними resolver-
#     функціями окремо, як і сьогодні).
#   - Merge-BRAVOConfiguration: generic рекурсивний deep-merge для двох
#     raw-графів (hashtable-рекурсія, array replace, scalar replace,
#     explicit @() підтримується, жодної мутації вхідних об'єктів).
#   - ConvertTo-BRAVONestedOverride: перетворює flat dot-path hashtable
#     (формат BRAVO.local.config) на nested-граф, fail-closed на шлях,
#     якого немає в referenced-графі (типова опечатка).
#   - Resolve-BRAVORawConfiguration: застосовує precedence
#     DEFAULT < primary < local.
#
# Цей модуль НІКУДИ ще не підключений (BRAVO_CONFIG_LOADER.ps1,
# BRAVO.config, entrypoints — без змін): це самодостатній, повністю
# протестований building block. Підключення — окремий подальший PR.

function Copy-BRAVOConfigurationGraphDeep {
    # Приватний helper: глибоке клонування графу з hashtable/array/scalar.
    # Потрібен, щоб Get-BRAVODefaultConfiguration повертав НЕЗАЛЕЖНИЙ
    # об'єкт при кожному виклику (жоден mutable reference не спільний між
    # незалежними завантаженнями — вимога "no cross-load leakage").
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        $clone = @{}
        foreach ($key in @($InputObject.Keys)) {
            $clone[$key] = Copy-BRAVOConfigurationGraphDeep -InputObject $InputObject[$key]
        }
        return $clone
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += , (Copy-BRAVOConfigurationGraphDeep -InputObject $item)
        }
        # ',' зберігає це масивом навіть при 0/1 елементі (PowerShell 5.1
        # unwrap-семантика одноелементних колекцій — .claude/rules/powershell.md).
        return , $items
    }

    # Scalar (string/int/double/bool/enum/...) — незмінний тип, копіювання
    # посилання безпечне.
    return $InputObject
}

function Get-BRAVODefaultConfiguration {
    # Канонічні built-in raw defaults. Один-в-один mapping на dot-path
    # контракт BRAVO.local.config.example (обидві фази), З ВИНЯТКОМ
    # полів, які є derivation (RuntimeRoot/ProgramData/StateRoot-залежні
    # шляхи; повний перелік і обґрунтування — design-документ §2).
    #
    # Навмисні відхилення від поточних літеральних значень BRAVO.config
    # (задокументовані рішення власника/ТЗ, а не випадкова розбіжність):
    #   - maintenanceSettings.Limits.ExcludedDrives: "@('F:\')" -> "@()".
    #     Коментар у BRAVO.config стверджує "за замовчуванням виключень
    #     немає" — фактичне значення суперечило власному коментарю.
    #     "F:\" — параметр конкретного розгортання, не product-default.
    #   - lunchArchiveCleanupPath, smbSettings.RootPath: "" замість
    #     placeholder-шляхів ("E:\Archiv", "\\NAS-SERVER\BRAVO_BACKUP") —
    #     обидві функції типово вимкнені (enableLunchArchiveCleanup=$false,
    #     SMB.ArchiveCopy=$false), тож порожнє значення функціонально
    #     ідентичне і не вводить environment-specific шлях як product-
    #     default (ТЗ розділ 25/26: "не додавати як universal built-ins
    #     ... конкретний NAS/UNC ... E:\Archiv").
    #   - sftpHostTemplate/sftpHostKey лишені як є: це не ідентифікатор
    #     конкретного клієнтського Storage Box (той підставляється як
    #     {0} із Credential Manager під час runtime), а загальний шаблон
    #     домену провайдера — вже сьогоднішній product-default.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $defaults = @{
        bravoSettings = @{
            InstitutionName = "УСТАНОВА"
            InstitutionCode = "00000000"
            ArchivePrefix = "lab_v2412"
            NotificationProvider = "discord"
            NotificationMode = "all"
            NotificationRequestTimeoutSeconds = 30
            NotificationRouting = @{
                SUCCESS  = "general"
                WARNING  = "alerts"
                ERROR    = "alerts"
                CRITICAL = "alerts"
            }
        }

        credentialSettings = @{
            Targets = @{
                SFTPLogin = "BRAVO_SFTP_LOGIN"
                SFTPPassword = "BRAVO_SFTP_PASSWORD"
                SMBLogin = "BRAVO_SMB_LOGIN"
                SMBPassword = "BRAVO_SMB_PASSWORD"
                SlackWebhookGeneral = "BRAVO_SLACK_GENERAL_URL"
                SlackWebhookAlerts = "BRAVO_SLACK_ALERTS_URL"
                DiscordWebhookGeneral = "BRAVO_DISCORD_GENERAL_URL"
                DiscordWebhookAlerts = "BRAVO_DISCORD_ALERTS_URL"
                ArchivePassword = "BRAVO_7Z_PASSWORD"
                InstitutionName = "BRAVO_INSTITUTION_NAME"
                InstitutionCode = "BRAVO_INSTITUTION_CODE"
                ArchivePrefix = "BRAVO_ARCHIVE_PREFIX"
            }
        }

        hostInformationSettings = @{
            PublicIPLookupEnabled = $true
            PublicIPLookupUrls = @(
                "https://api.ipify.org",
                "https://checkip.amazonaws.com"
            )
            PublicIPLookupTimeoutSeconds = 5
        }

        pathSettings = @{
            LIMSRoot      = ""
            SystemLogRoot = ""
            BackupRoot    = ""
        }

        maintenanceSettings = @{
            General = @{
                BravoWebDirectory = "C:\Br-a-vo.web"
            }
            Services = @{
                BravoName = "BRAVO"
                BravoDisplayName = @("BRAVO Service", "BRAVO Server")
                BravoWebEnabled = $true
                BravoWebCandidates = @(
                    "BRAVOWeb",
                    "BRAVO Web",
                    "Br-a-vo.web",
                    "Apache2.4",
                    "Apache24",
                    "Apache"
                )
                ExchangeApiName = "exchangAPI"
                StartTimeoutSeconds = 180
                StopTimeoutSeconds = 120
                PollIntervalSeconds = 2
            }
            Restore = @{
                Day = 7
                Time = "21:00"
                WindowStart = "21:00"
                WindowEnd = "03:00"
                ArchivesKeepCount = 1
                BootRestoreMode = "None"
                StartupDelayMinutes = 0
            }
            Retention = @{
                ArchiveDays = 14
                LogDays = 180
                CompressedLogDeletionEnabled = $false
                CompressedLogDays = 180
                FailedArchiveDays = 30
                RawSourceGraceDays = 0
            }
            Trace = @{
                BISSourcePath = ""
            }
            Limits = @{
                MinimumFreeSpaceGB = 20
                # Розділ 5 ТЗ: канонічний built-in дефолт — жоден диск не
                # виключається. "F:\" (попереднє значення BRAVO.config)
                # був environment-specific параметром конкретного
                # розгортання, а не product-default.
                ExcludedDrives = @()
                MaximumMdFileSizeGB = 1.5
                MdFileSizeExclusions = @("KZPpatArc.md")
                EstimatedSpaceMarginPercent = 25
            }
            Automation = @{
                AutoShutdown = "off"
                ShutdownTimeoutSeconds = 60
                ArchiveAfterMaintenance = "off"
            }
            RangeIdMonitoring = @{
                Enabled = $true
                ThresholdPercent = 80
                CheckDelaySeconds = 2
            }
            Archiver = @{
                CommandTimeoutSeconds = 14400
                IntegrityTestTimeoutSeconds = 14400
                Parameters = @(
                    "a", "-mmt4", "-mx5", "-r", "-y", "-ssw", "-bb0", "-scrcSHA512", "-aoa"
                )
            }
            FileOperations = @{
                MoveRetryCount = 3
                MoveRetryDelaySeconds = 5
            }
            Logging = @{
                Level = "INFO"
            }
        }

        componentSettings = @{
            Archive = @{
                MODEL = $true
                BLOG = $true
                BRAVOEXCH = $true
            }
            Synchronization = @{
                BAZA_APP_LOCAL = $false
                BAZA_APP_SFTP = $true
                BAZA_WWW_SFTP = $false
                BAZA_WWW_LOCAL = $false
            }
            SFTP = @{
                Enabled = $true
                ArchiveUpload = $true
                MaintenanceLogUploadEnabled = $false
                ArchiveLogUploadEnabled = $false
            }
            SMB = @{
                Enabled = $true
                ArchiveCopy = $false
            }
        }

        synchronizationSafety = @{
            RequireNonEmptyBAZASource = $true
        }

        requireAdministrator = $true

        elevationSettings = @{
            PowerShellExecutable = "powershell.exe"
            ArgumentsTemplate = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"'
            Verb = "runas"
            WindowStyle = "Normal"
        }

        consoleSettings = @{
            OutputEncodingCodePage = 65001
            WindowTitleTemplate = "СКРИПТ АРХIВАЦIЇ LIMS v.{0}"
            BackgroundColor = "Black"
            ForegroundColor = "White"
            ClearOnStart = $true
            ShowTimestampsInConsole = $false
            PauseOnExit = $true
            PausePrompt = "Натиснiть будь-яку клавiшу для закриття вiкна..."
            ConsoleLevel = "WARNING"
            FileLevel = "INFO"
            StepWidth = 58
        }

        progressSettings = @{
            Enabled = $true
            ShowOverallProgress = $true
            ShowSevenZipOutput = $true
            ShowRobocopyOutput = $true
            ShowWinSCPOutput = $true
            SevenZipProgressSwitch = ""
            SevenZipTimeoutSeconds = 14400
            SevenZipTestTimeoutSeconds = 14400
            RobocopyProgressOptions = @("/ETA")
            Activity = "BRAVO_ARCHIV — резервне копіювання"
        }

        LogLevel = "INFO"
        defaultLogLevel = "INFO"
        logLevels = @{
            DEBUG = 0
            INFO = 1
            WARNING = 2
            ERROR = 3
            SUCCESS = 4
        }
        logSeparatorLength = 100
        logTimestampFormat = "yyyy-MM-dd HH:mm:ss"
        durationFormat = "hh\:mm\:ss"
        logFileDateFormat = "yyyyMMdd_HHmmss"
        logFileNameTemplate = "BRAVO_ARCHIV_{0}_PID{1}.log"
        logFileFilter = "BRAVO_ARCHIV_*.log"
        logFileEncoding = "UTF8"
        logColors = @{
            Default = "White"
            Header = "Yellow"
            SUCCESS = "Green"
            ERROR = "Red"
            WARNING = "Yellow"
            DEBUG = "Gray"
            Progress = "Cyan"
        }

        logRetentionDays = 31
        archiveRetentionDays = 183
        enableArchiveDeletion = $false
        minimumRetainedVerifiedBackups = 2
        failedArchiveRetentionDays = 30
        enableFailedArchiveDeletion = $true
        enableOrphanTempCleanup = $true
        orphanTempRetentionHours = 48
        enableLunchArchiveCleanup = $false
        lunchArchiveCleanupPath = ""
        lunchArchiveCleanupDirectories = @("MODEL", "BLOG", "BRAVOEXCH")
        lunchArchiveRetentionMonths = 2

        archiveTimestampFormat = "yyyyMMdd_HHmmss"
        archiveFileFilter = "*.mdz"
        hashFileFilter = "*.sha512"
        hashFileExtension = ".sha512"
        hashFileEncoding = "utf-8"

        archiveParams = "a -mmt -mx6 -r -y -ssw -scrcSHA512 -bb0 -aoa"

        backupConsistency = @{
            Mode = "VSS"
            SnapshotContext = "ClientAccessible"
        }

        robocopyPath = "robocopy.exe"
        robocopyOptions = @("/E", "/R:3", "/W:5", "/TBD", "/NP", "/MT:8")
        robocopyMaxSuccessExitCode = 7
        robocopyWindowStyle = "Hidden"

        sftpHostTemplate = "{0}.your-storagebox.de"
        sftpPort = 22
        sftpHostKey = "`"ssh-rsa 2048 3d:7b:6f:99:5f:68:53:21:73:15:f9:2e:6b:3a:9f:e3`""
        sftpConnectionTimeoutSeconds = 30
        winSCPScriptEncoding = "ASCII"
        winSCPIniPath = "nul"
        sftpSynchronizationOptions = "-mirror -criteria=time,size -transfer=binary -resumesupport=on"

        smbSettings = @{
            RootPath = ""
            Directories = @{
                MODEL = "model"
                BLOG = "blog"
                BRAVOEXCH = "bravoexch"
            }
            CopyBufferSizeMB = 4
        }

        sftpDirectories = @{
            MODEL = "model"
            Blog = "blog"
            BravoExch = "bravoexch"
            BAZA = "baza_app"
            BAZAWWW = "baza_www"
            Manifest = "manifests"
            Trace = "trace"
            TraceLogs = "logs/trace"
            ExchangeApiLogs = "logs/exchangapi"
            MaintenanceLog = "logs/maintenance"
            ArchivLog = "logs/archiv"
        }

        backupMonitoring = @{
            Enabled = $true
            RunAfterBackup = $true
            CheckManagedServices = $true
            MaxBackupAgeHours = 24
            CandidateLimit = 10
            VerifyFileHash = $true
            SFTP = @{
                Enabled = $true
                CheckArchiveUploads = $true
                CheckBAZASynchronization = $true
                VerifyRemoteArchiveHash = $true
                RequireServerSideArchiveHash = $false
                RemoteBackupMaxAgeHours = 24
                OperationTimeoutSeconds = 1800
                SynchronizationTimeoutSeconds = 14400
                BAZAPreviewOptions = "-preview -mirror -criteria=time,size"
                DifferenceDetailLimit = 10
                BAZAPendingAlertAfterHours = 26
                BAZA = @{
                    Mode = "IncrementalAppendOnly"
                    SynchronizeBeforeHealth = $true
                    FastHealthEnabled = $true
                    FullAuditEnabled = $true
                    FullAuditEveryDays = 7
                    MutationPolicy = "Fail"
                    AutoArchiveMutationThreshold = 25
                }
            }
            SMB = @{
                Enabled = $true
                CheckArchiveCopies = $true
                VerifyRemoteArchiveHash = $true
                RemoteBackupMaxAgeHours = 24
            }
            SizeSanity = @{
                Enabled = $true
                HistoryCount = 5
                MinimumBytes = 1024
                MaxSizeDropPercent = 50
            }
            NotifyOnSuccessAfterBackup = $true
            RepeatAlertAfterHours = 0
            SuccessDedupMinutes = 1380
            LogFileNameTemplate = "BRAVO_ARCHIV_HEALTH_{0}.log"
        }

        schedulerSettings = @{
            TaskPath = "\BRAVO\"
            LegacyTaskPath = "\ARCHIV_LIMS\"
            LegacyTaskNames = @("ARCHIV_LIMS_BACKUP", "ARCHIV_LIMS_HEALTH")
            WindowStyle = "Hidden"
            RunAsUser = "SYSTEM"
            LogonType = "ServiceAccount"
            StartWhenAvailable = $false
            WakeToRun = $false
            Hidden = $true
            AllowStartIfOnBatteries = $true
            DontStopIfGoingOnBatteries = $true
            RestartCount = 3
            RestartIntervalMinutes = 15
            MultipleInstances = "IgnoreNew"
            OperationLockWaitMinutes = 360
            RequireProtectedRuntime = $true
            Backup = @{
                Enabled = $true
                TaskName = "BRAVO_ARCHIV"
                Description = "Щоденна архівація та передача резервних копій BRAVO"
                DailyAt = "23:00"
                ExecutionTimeLimitHours = 30
            }
            Maintenance = @{
                Enabled = $true
                TaskName = "BRAVO_MAINTENANCE"
                Description = "Щоденне обслуговування служб і даних BRAVO"
                DailyAt = "23:55"
                ExecutionTimeLimitHours = 18
            }
            Health = @{
                Enabled = $true
                TaskName = "BRAVO_ARCHIV_HEALTH"
                Description = "Перевірка локальних, SFTP і SMB резервних копій BRAVO кожні 240 хвилин"
                StartAt = "00:30"
                RepeatEveryMinutes = 240
                ExecutionTimeLimitHours = 2
                SkipIfBackupTaskRunning = $true
                BusyWaitMinutes = 60
            }
            Recovery = @{
                TaskName = "BRAVO_RESTORE_RECOVERY"
                Description = "Підхоплення пропущеної планової реставрації моделі одразу після старту сервера (профіль робочого часу)"
                ExecutionTimeLimitHours = 18
            }
            BAZASync = @{
                TaskName = "BRAVO BAZA Synchronization"
                Description = "Синхронізація BAZA_APP/BAZA_WWW із хмарним SFTP кожні 4 години"
                StartAt = "00:00"
                RepeatEveryHours = 4
                ExecutionTimeLimitHours = 2
            }
            RestoreVerify = @{
                Enabled = $true
                TaskName = "BRAVO_RESTORE_VERIFY"
                Description = "Щотижнева перевірка відновлюваності резервних копій (restore drill)"
                WeeklyOn = "Saturday"
                At = "04:00"
                ExecutionTimeLimitHours = 4
            }
        }

        restoreVerifySettings = @{
            MinimumFileCount = 1
            MaxVerificationAgeHours = 216
        }
    }

    return $defaults
}

function Merge-BRAVOConfiguration {
    # Generic рекурсивний deep-merge двох raw-графів.
    #   - hashtable + hashtable -> рекурсивне злиття по ключах.
    #   - масив в Override ПОВНІСТЮ замінює масив у Base (без конкатенації).
    #     Явний порожній масив @() у Override теж є валідною заміною
    #     (Test 7 ТЗ) — розрізняється через $Override.Contains($key),
    #     а не через "чи значення falsy".
    #   - scalar в Override повністю замінює scalar у Base.
    #   - Base і Override НІКОЛИ не мутуються (повертається новий граф).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Base,
        [Parameter(Mandatory = $true)][hashtable]$Override
    )

    $result = Copy-BRAVOConfigurationGraphDeep -InputObject $Base

    foreach ($key in @($Override.Keys)) {
        $overrideValue = $Override[$key]

        if ($result.Contains($key) -and
            $result[$key] -is [hashtable] -and
            $overrideValue -is [hashtable]) {
            $result[$key] = Merge-BRAVOConfiguration -Base $result[$key] -Override $overrideValue
            continue
        }

        # Скаляр, масив (у т.ч. явний @()) або hashtable-override на
        # non-hashtable base — override повністю замінює значення. Клон,
        # щоб результат не тримав спільне посилання на вхідний $Override.
        $result[$key] = Copy-BRAVOConfigurationGraphDeep -InputObject $overrideValue
    }

    return $result
}

function ConvertTo-BRAVONestedOverride {
    # Перетворює flat dot-path hashtable (формат BRAVO.local.config:
    # 'maintenanceSettings.Limits.ExcludedDrives' = @()) на nested-граф,
    # придатний для Merge-BRAVOConfiguration.
    #
    # Fail-closed на невідомий шлях: кожен сегмент, окрім останнього,
    # повинен існувати як hashtable-вузол у $ReferenceConfiguration (типово
    # — Get-BRAVODefaultConfiguration), інакше опечатка мовчки створила б
    # новий, ніколи не консультований вузол.
    #
    # P0 Configuration Foundation (PR C, Секція 4): ОДИН canonical контракт
    # для ОБОХ шляхів (config-present і config-absent) — раніше
    # config-present-шлях проходив через окремий, м'якший
    # Invoke-BRAVOLocalConfigurationOverridePhase (дозволяв НОВИЙ leaf у
    # ВЖЕ існуючому hashtable-вузлі), а config-absent-шлях уже тоді йшов
    # через цю функцію з вимогою, щоб і LEAF також існував у
    # $ReferenceConfiguration — те саме BRAVO.local.config давало різний
    # accept/reject результат залежно від наявності BRAVO.config
    # (задокументований дефект, знайдений на review). Той функцію тепер
    # прибрано (єдиний pipeline, Complete-BRAVOConfigurationLoad) — щоб не
    # втратити forward-compat-сумісність, яку вона забезпечувала
    # (новіший BRAVO.local.config.example/Configurator може містити ключ,
    # ще не описаний у схемі цієї версії toolkit — такий ключ МАЄ
    # пережити roundtrip, а не відкидати весь local-override файл),
    # багатосегментний шлях більше НЕ вимагає, щоб сам LEAF вже існував —
    # лише щоб БАТЬКІВСЬКИЙ вузол (усі сегменти, крім останнього) був
    # реальним hashtable-вузлом канонічної конфігурації. Односегментний
    # (без крапки) шлях — це сам top-level ключ: тут requirement
    # лишається строгим, бо "новий top-level raw-блок" — це вже зміна
    # формату конфігурації, а не forward-compat-лист усередині відомого
    # блоку.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$DotPathOverrides,
        [Parameter(Mandatory = $true)][hashtable]$ReferenceConfiguration
    )

    $nested = @{}
    $unknownPaths = New-Object System.Collections.Generic.List[string]

    foreach ($dotPath in @($DotPathOverrides.Keys)) {
        if ([string]::IsNullOrWhiteSpace([string]$dotPath)) {
            throw "ConvertTo-BRAVONestedOverride: порожній dot-path ключ неприпустимий."
        }

        $segments = @(([string]$dotPath) -split '\.')
        $referenceNode = $ReferenceConfiguration
        $pathIsKnown = $true

        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            $segment = $segments[$i]
            if ($referenceNode -is [hashtable] -and $referenceNode.Contains($segment)) {
                $referenceNode = $referenceNode[$segment]
            } else {
                $pathIsKnown = $false
                break
            }
        }

        $leafSegment = $segments[$segments.Count - 1]
        if ($pathIsKnown -and $segments.Count -eq 1 -and -not (
                $referenceNode -is [hashtable] -and $referenceNode.Contains($leafSegment)
            )) {
            $pathIsKnown = $false
        }
        # Багатосегментний шлях: сам leaf не мусить уже існувати
        # (forward-compat, див. коментар вище) — але батьківський вузол
        # МАЄ бути реальним hashtable-вузлом (не масив/скаляр/$null), щоб
        # $targetNode[$leafSegment]= нижче не створював структуру поза
        # канонічною формою.
        if ($pathIsKnown -and $segments.Count -gt 1 -and -not ($referenceNode -is [hashtable])) {
            $pathIsKnown = $false
        }

        if (-not $pathIsKnown) {
            [void]$unknownPaths.Add([string]$dotPath)
            continue
        }

        $targetNode = $nested
        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            $segment = $segments[$i]
            if (-not ($targetNode.Contains($segment) -and $targetNode[$segment] -is [hashtable])) {
                $targetNode[$segment] = @{}
            }
            $targetNode = $targetNode[$segment]
        }
        $targetNode[$leafSegment] = Copy-BRAVOConfigurationGraphDeep -InputObject $DotPathOverrides[$dotPath]
    }

    if ($unknownPaths.Count -gt 0) {
        throw ("Невідомий(і) ключ(і) конфігурації (опечатка або поле не є " +
            "raw-configurable): {0}" -f ($unknownPaths -join ', '))
    }

    return $nested
}

function Resolve-BRAVORawConfiguration {
    # Реалізує precedence "DEFAULT < BRAVO.config < BRAVO.local.config" на
    # рівні raw-графа (без discovery/derivation — ті виконуються окремо,
    # після виклику цієї функції, канонічними resolver-функціями).
    #
    #   -DefaultConfiguration : Get-BRAVODefaultConfiguration (або сумісний граф).
    #   -PrimaryOverrides      : nested hashtable (снапшот raw-блоків
    #                            BRAVO.config) або $null, якщо файл відсутній.
    #   -LocalOverrides        : flat dot-path hashtable (формат
    #                            BRAVO.local.config, Overrides властивість
    #                            Read-BRAVOLocalConfigurationOverrides) або
    #                            $null, якщо файл відсутній.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$DefaultConfiguration,
        [AllowNull()][hashtable]$PrimaryOverrides,
        [AllowNull()][hashtable]$LocalOverrides
    )

    $merged = Copy-BRAVOConfigurationGraphDeep -InputObject $DefaultConfiguration

    if ($null -ne $PrimaryOverrides -and $PrimaryOverrides.Count -gt 0) {
        $merged = Merge-BRAVOConfiguration -Base $merged -Override $PrimaryOverrides
    }

    if ($null -ne $LocalOverrides -and $LocalOverrides.Count -gt 0) {
        $localNested = ConvertTo-BRAVONestedOverride -DotPathOverrides $LocalOverrides -ReferenceConfiguration $merged
        $merged = Merge-BRAVOConfiguration -Base $merged -Override $localNested
    }

    return $merged
}
