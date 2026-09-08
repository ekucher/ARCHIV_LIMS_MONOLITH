Set-StrictMode -Version 2.0

# BRAVO.Configuration.Derivation — canonical derivation resolver (P0
# Configuration Foundation, PR B).
#
# Це ДОСЛІВНЕ (behavior-preserving) перенесення derivation-секції, яка
# сьогодні живе всередині BRAVO.config (рядки приблизно 608-1300:
# discovery, effective LIMS/Backup/SystemLog корені, sourcePaths,
# archiveDirs/archiveDefinitions, storageEffective/bazaSyncEffective,
# похідні листові поля backupMonitoring/schedulerSettings, шляхи
# інструментів/стану/логів). Мета — ОДИН canonical resolver, який
# викликають ОБИДВА шляхи (BRAVO.config present і BRAVO.config absent),
# а не дві незалежні копії derivation-логіки (docs/design/
# BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md, розділ 6.2 п.7).
#
# Залежність: Resolve-BRAVOEffectiveLimsRoot, Resolve-BRAVOInstallation
# Discovery, Resolve-BRAVOEffectiveBackupRoot, Resolve-
# BRAVOEffectiveSystemLogRoot, Get-BRAVOEffectiveStorageConfiguration,
# Get-BRAVOEffectiveSynchronizationConfiguration — усі з
# modules/BRAVO.Discovery.
#
# CI remediation (fresh-process defect, BRAVO_DATA_RESTORE_MATRIX_TEST.ps1):
# попередній коментар тут стверджував, що викликач (BRAVO_CONFIG_LOADER.ps1)
# "вже імпортує BRAVO.Discovery ПЕРЕД виконанням BRAVO.config/цієї функції"
# — це припущення НЕ тримається в реальному fresh-process execution path.
# BRAVO_CONFIG_LOADER.ps1 імпортує BRAVO.Discovery з-під ланцюжка
# dot-source, який виконується ВСЕРЕДИНІ SessionState модуля BRAVO.Archive
# (RootModule BRAVO.Archive.psm1 дот-сорсить BRAVO.Archive.Runtime.ps1,
# який дот-сорсить BRAVO_CONFIG_LOADER.ps1). PowerShell 5.1 Import-Module,
# викликаний із СЕРЕДИНИ чужого модуля (без -Global), імпортує залежність
# у ПРИВАТНИЙ SessionState цього викликача (BRAVO.Archive), а НЕ в global
# scope. Цей модуль (BRAVO.Configuration.Derivation) імпортується
# ОКРЕМИМ Import-Module-викликом (з BRAVO.config, теж усередині
# BRAVO.Archive scope) — тобто отримує СВІЙ ВЛАСНИЙ ізольований
# SessionState, який НЕ бачить приватний імпорт BRAVO.Discovery, зроблений
# іншим модулем. Функція нижче резолвить виклики лише проти власного
# SessionState модуля + справжнього global scope — жодного з них
# Discovery не займає, звідси "Resolve-BRAVOEffectiveLimsRoot is not
# recognized" у fresh child powershell.exe (BRAVO_SELF_TEST.ps1 це не
# ловив: self-test виконує цю функцію в іншому, спрощеному scope-ланцюжку,
# не через повний BRAVO_ARCHIV.ps1 -> BRAVO.Archive module -> BRAVO.config
# ланцюг). Тому цей модуль явно й детерміновано імпортує СВОЮ ВЛАСНУ
# залежність нижче — не покладаючись на випадковий caller scope.
$discoveryModulePathForDerivation = Join-Path -Path $PSScriptRoot -ChildPath '..\BRAVO.Discovery\BRAVO.Discovery.psd1'
Import-Module -Name $discoveryModulePathForDerivation -ErrorAction Stop
#
# Свідома зміна поведінки (докладно — design-документ, ТЗ Test 17): у
# поточному BRAVO.config sftpDirectories/backupMonitoring/
# schedulerSettings/restoreVerifySettings визначаються ПІЗНО (після
# storageEffective/bazaSyncEffective) і перевизначаються окремою
# "фазою 2" BRAVO.local.config В САМОМУУ КІНЦІ файла — тобто today
# local-override sftpDirectories НЕ встигає вплинути на вже обчислений
# bazaSyncEffective того самого завантаження (stale pre-merge derived
# value). Ця функція приймає ці блоки як RAW-параметри, ВЖЕ з
# застосованими overrides (виклик відбувається ПІСЛЯ повного merge,
# однією фазою) — derived-поля (BAZASync.Enabled тощо) тепер коректно
# відображають фінальне значення. Для чинного (незміненого) BRAVO.config
# це не змінює результат: перевизначення sftpDirectories через
# BRAVO.local.config — рідкісний edge case, не задокументований як
# навмисна залежність жодним відомим консьюмером.
function Resolve-BRAVOConfigurationDerivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$runtimeRoot,

        [Parameter(Mandatory = $true)][hashtable]$bravoSettings,
        [Parameter(Mandatory = $true)][hashtable]$credentialSettings,
        [Parameter(Mandatory = $true)][hashtable]$pathSettings,
        [Parameter(Mandatory = $true)][hashtable]$maintenanceSettings,
        [Parameter(Mandatory = $true)][hashtable]$componentSettings,

        # НЕ overridable через BRAVO.local.config (визначається в
        # BRAVO.config ПІСЛЯ фази overrides) — навмисно, щоб зберегти
        # контракт "discoverySettings не перевизначається" з
        # BRAVO.local.config.example.
        [Parameter(Mandatory = $true)][hashtable]$discoverySettings,

        [Parameter(Mandatory = $true)][hashtable]$sftpDirectories,

        # Raw-листові поля (уже з застосованими overrides) — функція
        # ДОДАЄ до них похідні поля (мутує той самий hashtable-об'єкт і
        # повертає результат у $global:*, як і сьогоднішній BRAVO.config).
        [Parameter(Mandatory = $true)][hashtable]$backupMonitoring,
        [Parameter(Mandatory = $true)][hashtable]$schedulerSettings,
        [Parameter(Mandatory = $true)][hashtable]$restoreVerifySettings
    )

    # credentialSettings.HelperPath/SetupScriptPath — похідні від
    # runtimeRoot шляхи runtime-ресурсів комплекту (не raw-configurable
    # значення). У BRAVO.config вони обчислювались inline одразу при
    # оголошенні $global:credentialSettings, ДО появи цього canonical
    # resolver-а — переносимо сюди, щоб no-config-шлях (BRAVO.config
    # відсутній) отримував той самий результат без другої копії цієї
    # логіки.
    $global:credentialSettings = $credentialSettings
    $global:credentialSettings.HelperPath = Join-Path $runtimeRoot "modules\BRAVO.Credentials\BRAVO.Credentials.psd1"
    $global:credentialSettings.SetupScriptPath = Join-Path $runtimeRoot "BRAVO_CREDENTIALS_SETUP.ps1"

    # maintenanceSettings.General.ObjectName/ArchivePrefix — той самий
    # клас: похідні від bravoSettings значення, обчислені inline при
    # оголошенні $global:maintenanceSettings у BRAVO.config, ДО появи
    # цього resolver-а. Це лише ПОЧАТКОВЕ/placeholder-значення:
    # Import-BRAVOInstitutionSettings (BRAVO.Credentials.psm1, викликана
    # entrypoint-ом одразу після Import-BravoConfiguration) перезаписує
    # обидва поля реальними даними з Credential Manager — але до ТОГО
    # моменту консюмери читають напряму (BRAVO.Maintenance.Runtime.ps1)
    # і під StrictMode впали б на відсутньому ключі без цього дефолту.
    if ($maintenanceSettings.Contains('General') -and $maintenanceSettings.General -is [hashtable]) {
        if ($bravoSettings.Contains('InstitutionName') -and $bravoSettings.Contains('InstitutionCode')) {
            $maintenanceSettings.General.ObjectName = "$($bravoSettings.InstitutionName) [$($bravoSettings.InstitutionCode)]"
        }
        if ($bravoSettings.Contains('ArchivePrefix')) {
            $maintenanceSettings.General.ArchivePrefix = [string]$bravoSettings.ArchivePrefix
        }
    }

    # =============================================
    # ШЛЯХИ ДО ДЖЕРЕЛ ДАНИХ
    # =============================================
    $global:scriptPath = $runtimeRoot

    # EffectiveLIMSRoot: explicit pathSettings.LIMSRoot або AUTO через
    # канонічну службу BRAVO (Name + DisplayName). Відсутність самої
    # служби при LIMSRoot="" НЕ throw тут ("service state != backup
    # policy") — LIMSRoot функціонально потрібен лише BRAVO_MAINTENANCE,
    # яка має власну явну перевірку одразу після Import-BravoConfiguration.
    $global:limsRootResult = Resolve-BRAVOEffectiveLimsRoot `
        -ConfiguredPath ([string]$pathSettings.LIMSRoot) `
        -BravoServiceName ([string]$maintenanceSettings.Services.BravoName) `
        -BravoDisplayName @($maintenanceSettings.Services.BravoDisplayName)
    $global:effectiveLimsRoot = [string]$limsRootResult.EffectivePath
    $global:LIMS_PATH = $global:effectiveLimsRoot
    $global:rootPath = $global:effectiveLimsRoot

    # =============================================
    # АВТОМАТИЧНИЙ DISCOVERY ДЖЕРЕЛ
    # =============================================
    # $discoverySettings прийшов як параметр (визначений у BRAVO.config
    # ПІСЛЯ фази overrides — не overridable, див. коментар параметра).
    $global:discoverySettings = $discoverySettings
    $global:bravoDiscoveryResult = Resolve-BRAVOInstallationDiscovery `
        -LimsRoot $rootPath `
        -DiscoverySettings $discoverySettings `
        -BravoServiceName ([string]$maintenanceSettings.Services.BravoName) `
        -BravoDisplayName @($maintenanceSettings.Services.BravoDisplayName) `
        -WebServiceCandidates @($maintenanceSettings.Services.BravoWebCandidates) `
        -ExchangeApiServiceName ([string]$maintenanceSettings.Services.ExchangeApiName)

    $global:bravoExchSourceCandidates = @(
        [string]$bravoDiscoveryResult.BRAVOEXCH_SOURCE |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $global:bravoExchSourceDirectory = $null
    foreach ($candidateDirectory in $bravoExchSourceCandidates) {
        if (-not (Test-Path -LiteralPath $candidateDirectory -PathType Container)) {
            continue
        }
        # BEXCH is a queue tree and can legitimately contain only empty
        # directories between exchanges. The canonical bravo.ini path plus an
        # existing directory is sufficient identity; requiring a current file
        # would disable backups exactly while the queue is idle.
        $global:bravoExchSourceDirectory = $candidateDirectory
        break
    }
    $bravoExchArchiveSource = if (
        -not [string]::IsNullOrWhiteSpace($bravoExchSourceDirectory)
    ) {
        Join-Path $bravoExchSourceDirectory "*"
    } else {
        $null
    }

    # Джерело істини — Resolve-BRAVOInstallationDiscovery (BAZA_WWW уже
    # обчислено вище): служба Apache2.4/Br-a-vo.web -> httpd.conf ->
    # DocumentRoot -> {DocumentRoot}\BAZA.
    $global:bazaWWWDetection = if (-not (
            [bool]$componentSettings.Synchronization.BAZA_WWW_SFTP -or
            [bool]$componentSettings.Synchronization.BAZA_WWW_LOCAL
        )) {
        [pscustomobject]@{
            Success = $false
            Source = $null
            ServiceName = $null
            ServiceDisplayName = $null
            ServiceExecutable = $null
            Reason = "синхронізацію BAZA WWW вимкнено в конфігурації"
            Presence = [string]$bravoDiscoveryResult.BAZA_WWW_Presence
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BAZA_WWW)) {
        [pscustomobject]@{
            Success = $true
            Source = [string]$bravoDiscoveryResult.BAZA_WWW
            ServiceName = [string]$bravoDiscoveryResult.WebServiceName
            ServiceDisplayName = [string]$bravoDiscoveryResult.WebServiceDisplayName
            ServiceExecutable = [string]$bravoDiscoveryResult.WebServiceExecutable
            Reason = $null
            Presence = [string]$bravoDiscoveryResult.BAZA_WWW_Presence
        }
    } else {
        [pscustomobject]@{
            Success = $false
            Source = $null
            ServiceName = $null
            ServiceDisplayName = $null
            ServiceExecutable = $null
            Reason = [string]$bravoDiscoveryResult.Reasons.BAZA_WWW
            Presence = [string]$bravoDiscoveryResult.BAZA_WWW_Presence
        }
    }

    $global:sourcePaths = @{
        Model = $(if ([string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.MODEL_SOURCE)) { $null } else { Join-Path ([string]$bravoDiscoveryResult.MODEL_SOURCE) "*" })
        Blog = $(if ([string]::IsNullOrWhiteSpace([string]$bravoDiscoveryResult.BLOG_SOURCE)) { $null } else { Join-Path ([string]$bravoDiscoveryResult.BLOG_SOURCE) "*" })
        BravoExch = $bravoExchArchiveSource
    }

    # =============================================
    # КАТАЛОГИ ПРИЗНАЧЕННЯ
    # =============================================
    $global:backupRootResult = Resolve-BRAVOEffectiveBackupRoot `
        -ConfiguredPath ([string]$pathSettings.BackupRoot) `
        -EffectiveLimsRoot $global:effectiveLimsRoot
    if ([string]$backupRootResult.Source -eq 'Error' -or
        [string]::IsNullOrWhiteSpace([string]$backupRootResult.EffectivePath)) {
        throw "Не вдалося визначити BackupRoot: $($backupRootResult.Reason)"
    }
    $global:backupRootPath = [string]$backupRootResult.EffectivePath

    $global:systemLogRootResult = Resolve-BRAVOEffectiveSystemLogRoot `
        -ConfiguredPath ([string]$pathSettings.SystemLogRoot) `
        -EffectiveLimsRoot $global:effectiveLimsRoot
    $global:systemLogRoot = [string]$systemLogRootResult.EffectivePath

    # RuntimeLogRoot — журнали САМИХ PowerShell-скриптів. ЗАВЖДИ
    # <RuntimeRoot>\LOGS, незалежно від LIMSRoot/SystemLogRoot/BackupRoot.
    $global:runtimeLogRoot = Join-Path $runtimeRoot "LOGS"
    $global:logPath = $global:runtimeLogRoot

    # Машинний стан — поруч з operation lock у %ProgramData%\BRAVO\State.
    $programDataRoot = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
        'C:\ProgramData'
    } else {
        [Environment]::ExpandEnvironmentVariables($env:ProgramData)
    }
    $global:stateRoot = Join-Path $programDataRoot 'BRAVO\State'

    # Operation lock — той самий %ProgramData%\BRAVO корінь, що й state.
    # Раніше обчислювався окремо, inline у самому BRAVO.config (ДО появи
    # цього canonical resolver-а) — переносимо сюди, бо це той самий клас
    # похідного (від programDataRoot), не raw-configurable значення, що й
    # stateRoot поруч, і no-config-шлях (BRAVO.config відсутній) потребує
    # того самого обчислення без другої копії цієї логіки.
    $global:operationLockSettings = @{
        Path = Join-Path $programDataRoot 'BRAVO\Locks\BRAVO_OPERATION.lock'
    }

    # Tools\ — runtime-залежності комплекту, лежать поруч зі скриптами
    # (RuntimeRoot).
    $global:toolsPath = Join-Path $runtimeRoot "Tools"
    $global:arcPath = Join-Path $toolsPath "7za.exe"
    $global:winSCPPath = Join-Path $toolsPath "WinSCP.com"
    $global:winSCPAssemblyPath = Join-Path $toolsPath "WinSCPnet.dll"

    $global:toolIntegritySettings = @{
        Mode = "Enforce"
        ManifestPath = Join-Path $toolsPath "TOOLS_MANIFEST.json"
    }

    # ЛОКАЛЬНІ КАТАЛОГИ ДЛЯ ЗБЕРІГАННЯ АРХІВІВ
    $global:archiveDirs = @{
        Model = [System.IO.Path]::Combine($backupRootPath, "MODEL")
        Blog = [System.IO.Path]::Combine($backupRootPath, "BLOG")
        BravoExch = [System.IO.Path]::Combine($backupRootPath, "BRAVOEXCH")
    }

    $global:bazaAppPaths = @{
        Source = [string]$bravoDiscoveryResult.BAZA_APP
        Destination = [System.IO.Path]::Combine($backupRootPath, "BAZA_APP")
    }
    $global:bazaWWWPaths = @{
        Source = [string]$bazaWWWDetection.Source
        Destination = [System.IO.Path]::Combine($backupRootPath, "BAZA_WWW")
    }

    # sftpDirectories — уже повністю raw-параметр (без похідних полів),
    # переданий з уже застосованими overrides. Проєкція в $global: для
    # сумісності з наявними консьюмерами.
    $global:sftpDirectories = $sftpDirectories

    # =============================================
    # ЕФЕКТИВНА КОНФІГУРАЦІЯ ЗОВНІШНІХ СХОВИЩ — ЄДИНЕ ДЖЕРЕЛО ПРАВДИ
    # =============================================
    $global:storageEffective = Get-BRAVOEffectiveStorageConfiguration `
        -ComponentSettings $componentSettings

    # =============================================
    # ЕФЕКТИВНА КОНФІГУРАЦІЯ СИНХРОНІЗАЦІЇ BAZA — ЄДИНЕ ДЖЕРЕЛО ПРАВДИ
    # =============================================
    $global:bazaSyncEffective = Get-BRAVOEffectiveSynchronizationConfiguration `
        -Synchronization $componentSettings.Synchronization `
        -GlobalSftpEnabled ([bool]$global:storageEffective.SFTP.Enabled) `
        -BazaAppSource ([string]$bazaAppPaths.Source) `
        -BazaWWWSource ([string]$bazaWWWPaths.Source) `
        -BazaWWWDetection $bazaWWWDetection `
        -SftpDirectories $sftpDirectories

    # БАЗОВІ ШЛЯХИ, ЯКІ ПЕРЕВІРЯЮТЬСЯ ЗАВЖДИ
    $global:baseRequiredPaths = @(
        @{Path=$logPath; Description="Каталог логiв"; CreateIfMissing=$true}
    )

    # ОПИСИ АРХІВІВ
    $global:archiveDefinitions = @(
        @{
            Type = "MODEL"
            Enabled = $componentSettings.Archive.MODEL
            NameTemplate = "{0}_{1}.mdz"
            Source = $sourcePaths.Model
            Destination = $archiveDirs.Model
        },
        @{
            Type = "BLOG"
            Enabled = $componentSettings.Archive.BLOG
            NameTemplate = "{0}_blog_{1}.mdz"
            Source = $sourcePaths.Blog
            Destination = $archiveDirs.Blog
        },
        @{
            Type = "BRAVOEXCH"
            Enabled = $componentSettings.Archive.BRAVOEXCH
            NameTemplate = "{0}_bravoexch_{1}.mdz"
            Source = $sourcePaths.BravoExch
            Destination = $archiveDirs.BravoExch
        }
    )

    # =============================================
    # МОНІТОРИНГ ЛОКАЛЬНИХ І ВІДДАЛЕНИХ РЕЗЕРВНИХ КОПІЙ
    # =============================================
    $global:backupHealthScriptPath = Join-Path $runtimeRoot "BRAVO_HEALTH.ps1"

    # $backupMonitoring прийшов як raw-параметр (усі листові поля з
    # BRAVO.local.config.example, з уже застосованими overrides) —
    # додаємо похідні поля (мирор bravoSettings/credentialSettings,
    # шляхи стану) в ТОЙ САМИЙ hashtable-об'єкт.
    $global:backupMonitoring = $backupMonitoring
    $global:backupMonitoring.InstitutionName = $bravoSettings.InstitutionName
    $global:backupMonitoring.InstitutionCode = $bravoSettings.InstitutionCode
    $global:backupMonitoring.NotificationProvider = $bravoSettings.NotificationProvider
    $global:backupMonitoring.NotificationMode = $bravoSettings.NotificationMode
    $global:backupMonitoring.NotificationCredentialTargets = $credentialSettings.Targets
    $global:backupMonitoring.NotificationRequestTimeoutSeconds = $bravoSettings.NotificationRequestTimeoutSeconds
    # Safe-default дублюється навмисно: BRAVO.config парситься до
    # гарантованого імпорту BRAVO.Notifications, тому не може покладатись
    # на дефолт усередині модуля.
    $global:backupMonitoring.NotificationRouting = if ($bravoSettings.Contains("NotificationRouting") -and
        $bravoSettings.NotificationRouting -is [hashtable]) {
        $bravoSettings.NotificationRouting
    } else {
        @{ SUCCESS = "general"; WARNING = "alerts"; ERROR = "alerts"; CRITICAL = "alerts" }
    }
    $global:backupMonitoring.AlertStatePath = Join-Path $stateRoot "BRAVO_ARCHIV_HEALTH_ALERT_STATE.json"
    $global:backupMonitoring.SuccessNotificationStatePath = Join-Path $stateRoot "BRAVO_HEALTH_SUCCESS_NOTIFICATION_STATE.json"
    $global:backupMonitoring.OperationalStatePath = Join-Path $stateRoot "BRAVO_HEALTH_OPERATIONAL_STATE.json"
    if ($global:backupMonitoring.Contains('SFTP') -and $global:backupMonitoring.SFTP -is [hashtable] -and
        $global:backupMonitoring.SFTP.Contains('BAZA') -and $global:backupMonitoring.SFTP.BAZA -is [hashtable]) {
        $global:backupMonitoring.SFTP.BAZA.StateRoot = $stateRoot
    }

    # =============================================
    # ПЛАНУВАЛЬНИК ЗАВДАНЬ WINDOWS
    # =============================================
    # $schedulerSettings прийшов як raw-параметр (з уже застосованими
    # overrides) — додаємо похідні поля (ScriptPath, Recovery.Enabled,
    # BAZASync.Enabled) у ТОЙ САМИЙ hashtable-об'єкт.
    $global:schedulerSettings = $schedulerSettings
    $global:schedulerSettings.PowerShellExecutable = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

    if ($global:schedulerSettings.Contains('Backup') -and $global:schedulerSettings.Backup -is [hashtable]) {
        $global:schedulerSettings.Backup.ScriptPath = Join-Path $runtimeRoot "BRAVO_ARCHIV.ps1"
    }
    if ($global:schedulerSettings.Contains('Maintenance') -and $global:schedulerSettings.Maintenance -is [hashtable]) {
        $global:schedulerSettings.Maintenance.ScriptPath = Join-Path $runtimeRoot "BRAVO_MAINTENANCE.ps1"
    }
    if ($global:schedulerSettings.Contains('Health') -and $global:schedulerSettings.Health -is [hashtable]) {
        $global:schedulerSettings.Health.ScriptPath = $backupHealthScriptPath
    }
    if ($global:schedulerSettings.Contains('Recovery') -and $global:schedulerSettings.Recovery -is [hashtable]) {
        # Recovery-завдання реєструється ЛИШЕ на серверах робочого часу
        # (Restore.BootRestoreMode="HoldServices"). Захисне читання
        # (Contains, а не пряме .BootRestoreMode): цей derivation-виклик
        # виконується ВСЕРЕДИНІ BRAVO.config, тобто ДО
        # Assert-BravoLoadedConfiguration (BRAVO_CONFIG_LOADER.ps1) —
        # canonical backfill відсутнього ключа для legacy-конфігів
        # спрацьовує лише ПІСЛЯ повного завантаження, а не тут. Безпечний
        # дефолт 'None' — той самий, що й built-in default і backfill.
        $effectiveBootRestoreMode = if ($maintenanceSettings.Contains('Restore') -and $maintenanceSettings.Restore -is [hashtable] -and
            $maintenanceSettings.Restore.Contains('BootRestoreMode')) {
            [string]$maintenanceSettings.Restore.BootRestoreMode
        } else {
            'None'
        }
        $global:schedulerSettings.Recovery.Enabled = ($effectiveBootRestoreMode -eq "HoldServices")
        $global:schedulerSettings.Recovery.ScriptPath = Join-Path $runtimeRoot "BRAVO_MAINTENANCE.ps1"
        $global:schedulerSettings.Recovery.StartupDelayMinutes = if ($maintenanceSettings.Contains('Restore') -and $maintenanceSettings.Restore -is [hashtable] -and
            $maintenanceSettings.Restore.Contains('StartupDelayMinutes')) {
            $maintenanceSettings.Restore.StartupDelayMinutes
        } else {
            0
        }
    }
    if ($global:schedulerSettings.Contains('BAZASync') -and $global:schedulerSettings.BAZASync -is [hashtable]) {
        # BAZASync — суто SFTP-синхронізація BAZA_APP/BAZA_WWW.
        # Enabled береться з канонічного $bazaSyncEffective (APP_SFTP OR
        # WWW_SFTP).
        $global:schedulerSettings.BAZASync.Enabled = $bazaSyncEffective.ScheduledSftpSyncRequired
        $global:schedulerSettings.BAZASync.ScriptPath = Join-Path $runtimeRoot "BRAVO_ARCHIV.ps1"
    }
    # Захисне читання (Contains, а не пряме .RestoreVerify): той самий
    # клас ризику, що й Recovery/BootRestoreMode вище — legacy site-
    # config (до появи RestoreVerify-завдання) може взагалі не мати цього
    # вузла в schedulerSettings, а canonical backfill (BRAVO_CONFIG_LOADER
    # .ps1, Assert-BravoLoadedConfiguration) спрацьовує лише ПІСЛЯ
    # повного завантаження, тобто вже після цього виклику.
    if ($global:schedulerSettings.Contains('RestoreVerify') -and
        $global:schedulerSettings.RestoreVerify -is [hashtable]) {
        $global:schedulerSettings.RestoreVerify.ScriptPath = Join-Path $runtimeRoot "BRAVO_RESTORE_TEST.ps1"
    }

    # Пороги перевірки відновлюваності — уже повністю raw-параметр.
    $global:restoreVerifySettings = $restoreVerifySettings
}

function Test-BRAVOLocalAbsoluteDriveLetterPath {
    # Внутрішній helper (не exported): true лише для локального,
    # absolute, drive-letter Windows-шляху ('C:\...' / 'C:/...').
    # Свідомо відхиляє UNC ('\\server\share', '\\?\UNC\...'),
    # forward-slash UNC ('//server/share'), відносні шляхи та
    # будь-що з схемою URI (http:, file: тощо) — жоден із них не
    # відповідає патерну "рівно одна літера + ':' + роздільник"
    # на позиції 0..1 рядка.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CandidatePath
    )
    return [bool]($CandidatePath -match '^[A-Za-z]:[\\/]')
}

function Assert-BRAVODiscoverySettingsTestOverride {
    # Внутрішній helper (не exported через .psd1 — production API цього
    # не потребує): two-factor, fail-closed gate для discovery test-seam.
    #
    # TEST-ONLY. DataRestore Matrix E2E fixture. Process-local (env var
    # на конкретному дочірньому powershell.exe, встановлена виключно
    # через ProcessStartInfo.EnvironmentVariables — див.
    # modules/BRAVO.DataRestore.MatrixTest). НЕ supported site
    # configuration, НЕ заміна BRAVO.local.config, НЕ документований
    # production override.
    #
    # Контракт (P1 security hardening, CI remediation #129):
    #   1. $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH порожній/відсутній
    #      -> $null (canonical discovery, без жодної додаткової перевірки;
    #      сам по собі $env:BRAVO_DATARESTORE_TEST_HOOKS нічого не активує).
    #   2. Інакше — ОБИДВА фактори обов'язкові, і будь-яке порушення дає
    #      THROW (fail-closed), а не мовчазний fallback на canonical:
    #        a. $env:BRAVO_DATARESTORE_TEST_HOOKS РІВНО 'ACCEPTANCE_ONLY'
    #           (той самий sentinel і той самий ordinal/case-sensitive
    #           контракт, що вже canonical у
    #           modules/BRAVO.DataRestore/BRAVO.DataRestore.Runtime.ps1);
    #        b. шлях — local absolute drive-letter .psd1 (не relative,
    #           не UNC, не URI, правильне розширення), існуючий regular
    #           file;
    #        c. Import-PowerShellDataFile (PS 5.1-сумісно; НЕ
    #           ConvertFrom-Json -AsHashtable) парситься без винятку;
    #        d. результат проходить сувору schema-валідацію (top-level
    #           keys, Sources keys, типи значень, локальність будь-яких
    #           вкладених filesystem-шляхів).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $overridePath = $env:BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH
    if ([string]::IsNullOrWhiteSpace($overridePath)) {
        return $null
    }

    $hooksGuard = [string]$env:BRAVO_DATARESTORE_TEST_HOOKS
    if (-not [string]::Equals($hooksGuard, 'ACCEPTANCE_ONLY', [System.StringComparison]::Ordinal)) {
        throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH заданий, але BRAVO_DATARESTORE_TEST_HOOKS != 'ACCEPTANCE_ONLY' (two-factor test-only seam; production discovery override без обох sentinel-факторів заборонено, fail-closed)."
    }

    if (-not (Test-BRAVOLocalAbsoluteDriveLetterPath -CandidatePath $overridePath)) {
        throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH має бути локальним absolute drive-letter шляхом (^[A-Za-z]:[\\/]) — UNC/network/relative/URI відхилено, fail-closed. Отримано: '$overridePath'."
    }
    if ($overridePath -notmatch '\.psd1$') {
        throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH має вказувати на .psd1-файл, fail-closed. Отримано: '$overridePath'."
    }

    $fullPath = [System.IO.Path]::GetFullPath($overridePath)
    if (-not (Test-BRAVOLocalAbsoluteDriveLetterPath -CandidatePath $fullPath) -or
        $fullPath -notmatch '\.psd1$') {
        throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH після канонізації шляху більше не є локальним drive-letter .psd1-шляхом, fail-closed. Отримано: '$overridePath'."
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH вказує на неіснуючий/не-файл шлях, fail-closed. Отримано: '$fullPath'."
    }

    try {
        $overrideData = Import-PowerShellDataFile -LiteralPath $fullPath -ErrorAction Stop
    } catch {
        throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH вказує на .psd1, який не вдалось розпарсити (Import-PowerShellDataFile), fail-closed. Помилка: $($_.Exception.Message)"
    }
    if ($null -eq $overrideData -or -not ($overrideData -is [hashtable])) {
        throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH .psd1 має повертати верхньорівневий hashtable (@{ ... }), fail-closed."
    }

    $allowedTopLevelKeys = @('BravoIniPath', 'BravoRoot', 'WebRoot', 'Sources')
    foreach ($key in $overrideData.Keys) {
        if ($allowedTopLevelKeys -notcontains $key) {
            throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH .psd1 містить невідомий top-level ключ '$key', fail-closed. Дозволено лише: $($allowedTopLevelKeys -join ',')."
        }
    }

    foreach ($scalarKey in @('BravoIniPath', 'BravoRoot', 'WebRoot')) {
        if (-not $overrideData.Contains($scalarKey)) { continue }
        $value = $overrideData[$scalarKey]
        if ($null -ne $value -and -not ($value -is [string])) {
            throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH .psd1: '$scalarKey' має бути `$null або string, fail-closed. Отримано тип: $($value.GetType().FullName)."
        }
        if ($value -is [string] -and -not [string]::IsNullOrEmpty($value) -and
            -not (Test-BRAVOLocalAbsoluteDriveLetterPath -CandidatePath $value)) {
            throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH .psd1: '$scalarKey' має бути локальним absolute drive-letter шляхом, fail-closed. Отримано: '$value'."
        }
    }

    if ($overrideData.Contains('Sources')) {
        $sourcesValue = $overrideData['Sources']
        if ($null -ne $sourcesValue -and -not ($sourcesValue -is [hashtable])) {
            throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH .psd1: 'Sources' має бути hashtable (або `$null), fail-closed."
        }
        if ($sourcesValue -is [hashtable]) {
            $allowedSourceKeys = @('MODEL', 'BLOG', 'BRAVOEXCH', 'BAZA_APP', 'BAZA_WWW', 'BACKUP_ROOT')
            foreach ($sourceKey in $sourcesValue.Keys) {
                if ($allowedSourceKeys -notcontains $sourceKey) {
                    throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH .psd1: невідомий Sources-ключ '$sourceKey', fail-closed. Дозволено лише: $($allowedSourceKeys -join ',')."
                }
                $sourceValue = $sourcesValue[$sourceKey]
                if ($null -ne $sourceValue -and -not ($sourceValue -is [string])) {
                    throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH .psd1: Sources.$sourceKey має бути `$null або string, fail-closed. Отримано тип: $($sourceValue.GetType().FullName)."
                }
                if ($sourceValue -is [string] -and -not [string]::IsNullOrEmpty($sourceValue) -and
                    -not (Test-BRAVOLocalAbsoluteDriveLetterPath -CandidatePath $sourceValue)) {
                    throw "BRAVO_DISCOVERY_SETTINGS_OVERRIDE_PATH .psd1: Sources.$sourceKey має бути локальним absolute drive-letter шляхом, fail-closed. Отримано: '$sourceValue'."
                }
            }
        }
    }

    return $overrideData
}

function Get-BRAVOCanonicalDiscoverySettings {
    # Канонічна, фіксована (НЕ raw-configurable) структура discoverySettings
    # — той самий літерал, який BRAVO.config визначає інлайн (навмисно
    # ПІСЛЯ фази local-overrides, щоб спроба перевизначити 'discoverySettings.*'
    # через BRAVO.local.config провалювалась fail-closed, а не мовчки
    # ігнорувалась). Винесено сюди як ОДНЕ джерело, яким користуються ОБИДВА
    # шляхи (BRAVO.config present і absent) — без цього no-config-шлях мав би
    # тримати другу незалежну копію цього самого літералу.
    #
    # CI remediation (BRAVO_DATA_RESTORE_MATRIX_TEST.ps1, E2E fixture):
    # раніше self-test обходив цю фіксацію через function global:
    # Get-BRAVOCanonicalDiscoverySettings (function-shadowing). Емпірично
    # підтверджено, що цей прийом НЕ переноситься на MatrixTest — там
    # викликач (Resolve-BRAVOConfigurationDerivation) виконується
    # всередині приватного SessionState модуля BRAVO.Archive (повний
    # ланцюг BRAVO_ARCHIV.ps1 -> BRAVO.Archive module -> BRAVO_CONFIG_
    # LOADER.ps1), тому global-scope shadow, визначена в дочірньому
    # процесі ДО імпорту BRAVO.Archive, програє module-приватному
    # імпорту (мінімальний ізольований repro підтвердив: семантичного
    # шляху до global-shadow тут просто немає). Замість розширення
    # Import-Module до -Global (ширший blast radius на ВСІ entrypoints)
    # — вузький, явно gate-ований, two-factor, fail-closed env-var seam
    # (Assert-BRAVODiscoverySettingsTestOverride вище), того самого
    # класу, що вже прийнятий у цьому репозиторії для
    # BRAVO_DATARESTORE_TEST_HOOKS/BRAVO_DATARESTORE_TEST_FAILPOINT
    # (modules/BRAVO.DataRestore.MatrixTest): без встановленої змінної —
    # поведінка на 100% незмінна (canonical fixed-літерал нижче, як і
    # раніше). TEST-ONLY, не supported production configuration.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $override = Assert-BRAVODiscoverySettingsTestOverride
    if ($null -ne $override) {
        return $override
    }

    return @{
        BravoIniPath = $null
        BravoRoot = $null
        WebRoot = $null
        Sources = @{
            MODEL = $null
            BLOG = $null
            BRAVOEXCH = $null
            BAZA_APP = $null
            BAZA_WWW = $null
            BACKUP_ROOT = $null
        }
    }
}

# R3-4 (PR #136, третє коло review): ЄДИНА canonical "чи потрібні SFTP-
# креденшели" формула. До цього фіксу ідентичний вираз (SFTP.Enabled AND
# (ArchiveUpload OR ScheduledSftpSyncRequired OR backupMonitoring.SFTP.Enabled))
# був незалежно продубльований у BRAVO_DRY_RUN.ps1 (двічі),
# BRAVO_CREDENTIALS_SETUP.ps1 (Resolve-RequestedComponents) і
# BRAVO.Configurator.Credentials.psm1 (Get-BRAVOConfiguratorCredentialRequirement) —
# жодне з чотирьох місць не враховувало нові own-log upload тумблери,
# додані окремо в componentSettings.SFTP. Тепер усі чотири викликають цю
# функцію замість власної копії виразу.
function Test-BRAVOSftpCredentialsRequired {
    <#
    .SYNOPSIS
        Canonical предикат "чи потрібні SFTP-креденшелі" за поточною
        Effective-топологією.
    .DESCRIPTION
        Master-вимикач AND будь-яка з дестинацій/фіч, що фактично
        використовують SFTP: ArchiveUpload, MaintenanceLogUploadEnabled,
        ArchiveLogUploadEnabled (обидва — opt-in вивантаження власних
        логів, PR #136), запланована BAZA-синхронізація або Health SFTP-
        моніторинг.
        Приймає ВЖЕ нормалізовані булеві значення (а не сирі config-
        об'єкти) навмисно: різні виклик-площини історично по-різному
        приводять "чи увімкнено" до bool (BRAVO_DRY_RUN.ps1 —
        толерантний Test-SettingEnabled для рядкових значень;
        BRAVO_CREDENTIALS_SETUP.ps1/Configurator — прямий [bool] на вже
        canonical-нормалізованих Effective-полях). Ця функція centralize
        лише КОМБІНАТОРИКУ (яка саме дестинація вимагає SFTP), а не
        політику приведення типів кожного виклик-площини — так кожен
        caller зберігає свій уже перевірений спосіб нормалізації.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$SftpEnabled,
        [Parameter(Mandatory = $true)][bool]$ArchiveUploadEnabled,
        [Parameter(Mandatory = $true)][bool]$MaintenanceLogUploadEnabled,
        [Parameter(Mandatory = $true)][bool]$ArchiveLogUploadEnabled,
        [Parameter(Mandatory = $true)][bool]$ScheduledSftpSyncRequired,
        [Parameter(Mandatory = $true)][bool]$BackupMonitoringSftpEnabled
    )

    return $SftpEnabled -and (
        $ArchiveUploadEnabled -or
        $MaintenanceLogUploadEnabled -or
        $ArchiveLogUploadEnabled -or
        $ScheduledSftpSyncRequired -or
        $BackupMonitoringSftpEnabled
    )
}
