# Canonical descriptor catalog для BRAVO Configurator.
#
# Джерело істини для Path/Type/Phase/Group — коментарі й закоментовані
# приклади в BRAVO.local.config.example (кожен Path тут має бути
# EXACT-збігом з дозволеним dot-шляхом у прикладі; повний ролловер
# перевіряється Test-BRAVOConfiguratorSchemaCompleteness).
#
# Справжній module-маніфест (RootModule/ModuleVersion/GUID) — не голий
# @{ Descriptors = ... }: BRAVO_SELF_TEST.ps1 (Version/ModuleManifests)
# прогонить Test-ModuleManifest по КОЖНОМУ *.psd1 під modules\, а
# Test-ModuleManifest відхиляє будь-які members поза фіксованим списком
# (Descriptors серед них немає). Каталог дескрипторів тому лежить у
# PrivateData — єдиному member-і, куди дозволено класти довільні дані —
# а не на верхньому рівні. Import-PowerShellDataFile лишається без змін
# (як і раніше, без виконання коду); Get-BRAVOConfiguratorSchemaCatalog
# читає $catalogData.PrivateData.Descriptors.
@{
    RootModule = 'BRAVO.Configurator.Schema.psm1'
    ModuleVersion = '5.3.0'
    GUID = 'e5a7b6c4-0f5e-4c0e-af6c-5e6f7081a2b3'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-BRAVOConfiguratorSchemaCatalog', 'Get-BRAVOConfiguratorDocumentedOverridePaths', 'Test-BRAVOConfiguratorSchemaCompleteness')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
    PrivateData = @{
    Descriptors = @(
        # ===== General / Установа (bravoSettings) — фаза 1 =====
        @{ Path = 'bravoSettings.InstitutionName'; Group = 'General'; Section = 'Institution'; Label = 'Назва установи'; Description = 'Fallback-значення до BRAVO_SETUP.ps1; після налаштування пріоритет має Windows Credential Manager.'; Type = 'String'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'bravoSettings.InstitutionCode'; Group = 'General'; Section = 'Institution'; Label = 'Код установи'; Description = 'Fallback-значення до BRAVO_SETUP.ps1.'; Type = 'String'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'bravoSettings.ArchivePrefix'; Group = 'General'; Section = 'Institution'; Label = 'Префікс архівів'; Description = 'Fallback-значення до BRAVO_SETUP.ps1.'; Type = 'String'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'bravoSettings.NotificationProvider'; Group = 'General'; Section = 'Notifications'; Label = 'Постачальник сповіщень'; Description = 'discord | slack.'; Type = 'Enum'; AllowedValues = @('discord', 'slack'); Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'bravoSettings.NotificationMode'; Group = 'General'; Section = 'Notifications'; Label = 'Режим сповіщень'; Description = 'none | errors_only | all.'; Type = 'Enum'; AllowedValues = @('none', 'errors_only', 'all'); Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'bravoSettings.NotificationRequestTimeoutSeconds'; Group = 'General'; Section = 'Notifications'; Label = 'Таймаут запиту сповіщення (с)'; Description = 'Таймаут HTTP-запиту до Discord/Slack webhook.'; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 60 }
        @{ Path = 'bravoSettings.NotificationRouting.SUCCESS'; Group = 'General'; Section = 'Notifications'; Label = 'Маршрут: SUCCESS'; Description = 'Канал (general|alerts) для рівня SUCCESS.'; Type = 'Enum'; AllowedValues = @('general', 'alerts'); Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 70 }
        @{ Path = 'bravoSettings.NotificationRouting.WARNING'; Group = 'General'; Section = 'Notifications'; Label = 'Маршрут: WARNING'; Description = 'Канал (general|alerts) для рівня WARNING.'; Type = 'Enum'; AllowedValues = @('general', 'alerts'); Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 80 }
        @{ Path = 'bravoSettings.NotificationRouting.ERROR'; Group = 'General'; Section = 'Notifications'; Label = 'Маршрут: ERROR'; Description = 'Канал (general|alerts) для рівня ERROR.'; Type = 'Enum'; AllowedValues = @('general', 'alerts'); Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 90 }
        @{ Path = 'bravoSettings.NotificationRouting.CRITICAL'; Group = 'General'; Section = 'Notifications'; Label = 'Маршрут: CRITICAL'; Description = 'Канал (general|alerts) для рівня CRITICAL.'; Type = 'Enum'; AllowedValues = @('general', 'alerts'); Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 100 }

        # ===== General / Credential Manager target names (credentialSettings.Targets) — фаза 1 =====
        @{ Path = 'credentialSettings.Targets.SFTPLogin'; Group = 'Credentials'; Section = 'Targets'; Label = 'Ім''я запису: SFTP логін'; Description = 'Назва запису Windows Credential Manager (не сам секрет). Рідко потрібно перевизначати.'; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'credentialSettings.Targets.SFTPPassword'; Group = 'Credentials'; Section = 'Targets'; Label = 'Ім''я запису: SFTP пароль'; Description = 'Назва запису Windows Credential Manager (не сам секрет).'; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'credentialSettings.Targets.DiscordWebhookGeneral'; Group = 'Credentials'; Section = 'Targets'; Label = 'Ім''я запису: Discord webhook (general)'; Description = 'Назва запису Windows Credential Manager (не сам секрет).'; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'credentialSettings.Targets.DiscordWebhookAlerts'; Group = 'Credentials'; Section = 'Targets'; Label = 'Ім''я запису: Discord webhook (alerts)'; Description = 'Назва запису Windows Credential Manager (не сам секрет).'; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'credentialSettings.Targets.SlackWebhookGeneral'; Group = 'Credentials'; Section = 'Targets'; Label = 'Ім''я запису: Slack webhook (general)'; Description = 'Назва запису Windows Credential Manager (не сам секрет).'; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'credentialSettings.Targets.SlackWebhookAlerts'; Group = 'Credentials'; Section = 'Targets'; Label = 'Ім''я запису: Slack webhook (alerts)'; Description = 'Назва запису Windows Credential Manager (не сам секрет).'; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 60 }

        # ===== General / Host info =====
        @{ Path = 'hostInformationSettings.PublicIPLookupEnabled'; Group = 'General'; Section = 'HostInfo'; Label = 'Показувати публічну IP у сповіщеннях'; Description = 'Увімкнено за замовчуванням (рішення власника 2026-08-30, замінює попередній P1.10-дефолт): запит до зовнішнього сервісу розкриває факт і час запуску backup. Вимкніть, якщо ця зовнішня залежність небажана.'; Type = 'Boolean'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'hostInformationSettings.PublicIPLookupTimeoutSeconds'; Group = 'General'; Section = 'HostInfo'; Label = 'Таймаут запиту публічної IP (с)'; Description = 'Діє лише якщо PublicIPLookupEnabled=true.'; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 20 }

        # ===== Paths (pathSettings) — фаза 1 =====
        @{ Path = 'pathSettings.LIMSRoot'; Group = 'Paths'; Section = 'Data'; Label = 'LIMSRoot'; Description = '"" = AUTO через встановлену службу BRAVO; непорожнє = точний абсолютний шлях.'; Type = 'Path'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'pathSettings.SystemLogRoot'; Group = 'Paths'; Section = 'Data'; Label = 'SystemLogRoot'; Description = '"" = <EffectiveLIMSRoot>\ARCHIV\LOGS.'; Type = 'Path'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'pathSettings.BackupRoot'; Group = 'Paths'; Section = 'Data'; Label = 'BackupRoot'; Description = '"" = AUTO -> <EffectiveLIMSRoot>\ARCHIV. Найтиповіший override.'; Type = 'Path'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }

        # ===== Maintenance / Services =====
        @{ Path = 'maintenanceSettings.Services.BravoDisplayName'; Group = 'Maintenance'; Section = 'Services'; Label = 'Можливі DisplayName служби BRAVO'; Description = 'Додавайте до списку, не замінюйте дефолтні значення двома.'; Type = 'StringArray'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'maintenanceSettings.Services.BravoWebEnabled'; Group = 'Maintenance'; Section = 'Services'; Label = 'BravoWeb увімкнено'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'maintenanceSettings.Services.ExchangeApiName'; Group = 'Maintenance'; Section = 'Services'; Label = 'Ім''я служби exchangAPI'; Description = ''; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'maintenanceSettings.Services.StartTimeoutSeconds'; Group = 'Maintenance'; Section = 'Services'; Label = 'Таймаут старту служби (с)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'maintenanceSettings.Services.StopTimeoutSeconds'; Group = 'Maintenance'; Section = 'Services'; Label = 'Таймаут зупинки служби (с)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }

        # ===== Maintenance / Restore =====
        @{ Path = 'maintenanceSettings.Restore.Day'; Group = 'Maintenance'; Section = 'Restore'; Label = 'День планової реставрації'; Description = '1=Пн ... 7=Нд.'; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'maintenanceSettings.Restore.Time'; Group = 'Maintenance'; Section = 'Restore'; Label = 'Час планової реставрації'; Description = 'HH:mm.'; Type = 'Time'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'maintenanceSettings.Restore.WindowStart'; Group = 'Maintenance'; Section = 'Restore'; Label = 'Початок безпечного вікна'; Description = 'Може перетинати північ.'; Type = 'Time'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'maintenanceSettings.Restore.WindowEnd'; Group = 'Maintenance'; Section = 'Restore'; Label = 'Кінець безпечного вікна'; Description = 'Може перетинати північ.'; Type = 'Time'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'maintenanceSettings.Restore.ArchivesKeepCount'; Group = 'Maintenance'; Section = 'Restore'; Label = 'К-сть архівів для reserve'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'maintenanceSettings.Restore.BootRestoreMode'; Group = 'Maintenance'; Section = 'Restore'; Label = 'Профіль сервера'; Description = 'None (24/7) | HoldServices (робочий час, boot-recovery з утриманням служб). Протягується в schedulerSettings.Recovery.Enabled — не перевизначайте Recovery.Enabled напряму.'; Type = 'Enum'; AllowedValues = @('None', 'HoldServices'); Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 60 }
        @{ Path = 'maintenanceSettings.Restore.StartupDelayMinutes'; Group = 'Maintenance'; Section = 'Restore'; Label = 'Затримка старту (хв)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 70 }

        # ===== Maintenance / Retention =====
        @{ Path = 'maintenanceSettings.Retention.ArchiveDays'; Group = 'Maintenance'; Section = 'Retention'; Label = 'Retention архівів обслуговування (дні)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'maintenanceSettings.Retention.LogDays'; Group = 'Maintenance'; Section = 'Retention'; Label = 'Retention журналів (дні)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'maintenanceSettings.Retention.CompressedLogDeletionEnabled'; Group = 'Maintenance'; Section = 'Retention'; Label = 'Видаляти стиснуті журнали'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'maintenanceSettings.Retention.CompressedLogDays'; Group = 'Maintenance'; Section = 'Retention'; Label = 'Retention стиснутих журналів (дні)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'maintenanceSettings.Retention.FailedArchiveDays'; Group = 'Maintenance'; Section = 'Retention'; Label = 'Retention невдалих архівів (дні)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 50 }
        # PR #136 (log-lifecycle P5): 0 = точна попередня поведінка
        # (видалення сирого джерела одразу після успішної архівації+SFTP);
        # N>0 лишає верифіковане джерело локально ще N днів понад
        # LastWriteTime, перш ніж видалити.
        @{ Path = 'maintenanceSettings.Retention.RawSourceGraceDays'; Group = 'Maintenance'; Section = 'Retention'; Label = 'Grace-період сирих джерел (дні)'; Description = 'Скільки днів понад LastWriteTime лишати локально ПОВНІСТЮ верифіковане (архів+SFTP+перевірка) джерело Trace/exchangAPI перед видаленням. 0 (типово) — видалення одразу, щойно безпечно.'; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 60 }

        # ===== Maintenance / Trace =====
        @{ Path = 'maintenanceSettings.Trace.BISSourcePath'; Group = 'Maintenance'; Section = 'Trace'; Label = 'Друге trace-джерело (TraceBIS.out)'; Description = '"" = AUTO; ''off'' = вимкнено; шлях = явно.'; Type = 'Path'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 10 }

        # ===== Maintenance / Limits =====
        @{ Path = 'maintenanceSettings.Limits.MinimumFreeSpaceGB'; Group = 'Maintenance'; Section = 'Limits'; Label = 'Мінімум вільного місця (ГБ)'; Description = ''; Type = 'Number'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'maintenanceSettings.Limits.ExcludedDrives'; Group = 'Maintenance'; Section = 'Limits'; Label = 'Диски, виключені з перевірки місця'; Description = 'Формати: "D:", "E", "F:\".'; Type = 'StringArray'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'maintenanceSettings.Limits.MaximumMdFileSizeGB'; Group = 'Maintenance'; Section = 'Limits'; Label = 'Максимальний розмір .md (ГБ)'; Description = ''; Type = 'Number'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'maintenanceSettings.Limits.MdFileSizeExclusions'; Group = 'Maintenance'; Section = 'Limits'; Label = 'Виключення з перевірки розміру .md'; Description = ''; Type = 'StringArray'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'maintenanceSettings.Limits.EstimatedSpaceMarginPercent'; Group = 'Maintenance'; Section = 'Limits'; Label = 'Запас оцінки місця (%)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }

        # ===== Maintenance / Automation =====
        @{ Path = 'maintenanceSettings.Automation.AutoShutdown'; Group = 'Maintenance'; Section = 'Automation'; Label = 'Авто-вимкнення після обслуговування'; Description = ''; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'maintenanceSettings.Automation.ArchiveAfterMaintenance'; Group = 'Maintenance'; Section = 'Automation'; Label = 'Архівація після обслуговування'; Description = ''; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 20 }

        # ===== Maintenance / Range ID =====
        @{ Path = 'maintenanceSettings.RangeIdMonitoring.Enabled'; Group = 'Maintenance'; Section = 'RangeId'; Label = 'Моніторинг діапазонів ID увімкнено'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'maintenanceSettings.RangeIdMonitoring.ThresholdPercent'; Group = 'Maintenance'; Section = 'RangeId'; Label = 'Поріг попередження (%)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }

        # ===== Maintenance / 7-Zip =====
        @{ Path = 'maintenanceSettings.Archiver.CommandTimeoutSeconds'; Group = 'Maintenance'; Section = 'SevenZip'; Label = 'Таймаут 7-Zip команди (с)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'maintenanceSettings.Logging.Level'; Group = 'Maintenance'; Section = 'SevenZip'; Label = 'Рівень логування обслуговування'; Description = ''; Type = 'Enum'; AllowedValues = @('TRACE', 'DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'); Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 20 }

        # ===== Components (componentSettings) — фаза 1 =====
        @{ Path = 'componentSettings.Archive.MODEL'; Group = 'Components'; Section = 'Archive'; Label = 'Архівація MODEL'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'componentSettings.Archive.BLOG'; Group = 'Components'; Section = 'Archive'; Label = 'Архівація BLOG'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'componentSettings.Archive.BRAVOEXCH'; Group = 'Components'; Section = 'Archive'; Label = 'Архівація BRAVOEXCH'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'componentSettings.Synchronization.BAZA_APP_LOCAL'; Group = 'Components'; Section = 'Synchronization'; Label = 'BAZA APP → Local'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'componentSettings.Synchronization.BAZA_APP_SFTP'; Group = 'Components'; Section = 'Synchronization'; Label = 'BAZA APP → SFTP'; Description = 'Raw-прапорець; фактичне значення залежить від componentSettings.SFTP.Enabled (master).'; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'componentSettings.Synchronization.BAZA_WWW_SFTP'; Group = 'Components'; Section = 'Synchronization'; Label = 'BAZA WWW → SFTP'; Description = 'Вмикайте свідомо (див. коментар у BRAVO.config). Raw-прапорець; ефективне значення залежить від SFTP.Enabled (master).'; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 60 }
        @{ Path = 'componentSettings.Synchronization.BAZA_WWW_LOCAL'; Group = 'Components'; Section = 'Synchronization'; Label = 'BAZA WWW → Local'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 70 }
        # 5.2.2: глобальні master-switches зовнішніх сховищ. $false вимикає
        # ВСІ автоматичні мережеві операції відповідного destination
        # (архіви, BAZA-синхронізацію, Health-моніторинг, Dry Run проби) і
        # знімає вимогу креденшелів — дочірні прапорці (ArchiveUpload/
        # ArchiveCopy/BAZA_*_SFTP) НЕ мутуються; повторне ввімкнення
        # відновлює попередню effective-поведінку без переналаштування.
        # Відсутній ключ (legacy-конфіг 5.2.1 і старіші) = $true.
        @{ Path = 'componentSettings.SFTP.Enabled'; Group = 'Components'; Section = 'SFTP'; Label = 'SFTP глобально увімкнено'; Description = 'Master-switch (5.2.2): $false вимикає ArchiveUpload, BAZA_APP_SFTP, BAZA_WWW_SFTP, Health SFTP-перевірки і SFTP-креденшели — без зміни їх raw-значень.'; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 70 }
        @{ Path = 'componentSettings.SFTP.ArchiveUpload'; Group = 'Components'; Section = 'SFTP'; Label = 'Завантажувати архіви на SFTP'; Description = 'Raw-прапорець дитини; ефективне значення залежить від componentSettings.SFTP.Enabled (master, окремий документований override-шлях вище).'; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 80 }
        # PR #136 (log-lifecycle P1): opt-in вивантаження ВЛАСНИХ
        # операційних логів BRAVO наприкінці прогону. $false (дефолт) —
        # нова вихідна SFTP-поведінка не вмикається мовчки на існуючих
        # розгортаннях. Провал передачі — завжди лише WARNING.
        @{ Path = 'componentSettings.SFTP.MaintenanceLogUploadEnabled'; Group = 'Components'; Section = 'SFTP'; Label = 'Вивантажувати лог Maintenance на SFTP'; Description = 'Opt-in вивантаження власного логу прогону BRAVO_MAINTENANCE (+ знімок range_id_log.json) у sftpDirectories.MaintenanceLog. Провал передачі не впливає на результат прогону.'; Type = 'Boolean'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 90 }
        @{ Path = 'componentSettings.SFTP.ArchiveLogUploadEnabled'; Group = 'Components'; Section = 'SFTP'; Label = 'Вивантажувати лог Archive на SFTP'; Description = 'Opt-in вивантаження власного логу прогону BRAVO_ARCHIV у sftpDirectories.ArchivLog. Провал передачі не впливає на результат прогону.'; Type = 'Boolean'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 100 }
        @{ Path = 'componentSettings.SMB.Enabled'; Group = 'Components'; Section = 'SMB'; Label = 'SMB глобально увімкнено'; Description = 'Master-switch (5.2.2): $false вимикає ArchiveCopy і SMB-креденшелі — без зміни raw-значення. Незалежний від SFTP.Enabled.'; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 85 }
        @{ Path = 'componentSettings.SMB.ArchiveCopy'; Group = 'Components'; Section = 'SMB'; Label = 'Копіювати архіви на SMB'; Description = 'Raw-прапорець дитини; ефективне значення залежить від componentSettings.SMB.Enabled (master, окремий документований override-шлях вище).'; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 90 }

        # ===== Console / Progress / Logs — фаза 1 =====
        @{ Path = 'consoleSettings.ConsoleLevel'; Group = 'Console'; Section = 'Console'; Label = 'Рівень консолі'; Description = 'TRACE..FATAL.'; Type = 'Enum'; AllowedValues = @('TRACE', 'DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'); Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'consoleSettings.FileLevel'; Group = 'Console'; Section = 'Console'; Label = 'Рівень файлового логу'; Description = 'TRACE..FATAL.'; Type = 'Enum'; AllowedValues = @('TRACE', 'DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'); Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'consoleSettings.PauseOnExit'; Group = 'Console'; Section = 'Console'; Label = 'Пауза при виході'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'progressSettings.Enabled'; Group = 'Console'; Section = 'Progress'; Label = 'Прогрес-бар увімкнено'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'progressSettings.SevenZipTimeoutSeconds'; Group = 'Console'; Section = 'Progress'; Label = 'Таймаут прогресу 7-Zip (с)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'LogLevel'; Group = 'Console'; Section = 'Console'; Label = 'Кореневий LogLevel'; Description = ''; Type = 'Enum'; AllowedValues = @('TRACE', 'DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'); Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 60 }

        # ===== Storage / Local (скаляри) — фаза 1 =====
        @{ Path = 'logRetentionDays'; Group = 'Storage'; Section = 'Local'; Label = 'Retention логів скриптів (дні)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'archiveRetentionDays'; Group = 'Storage'; Section = 'Local'; Label = 'Retention коректних архівів (дні)'; Description = 'Діє при enableArchiveDeletion=true.'; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'enableArchiveDeletion'; Group = 'Storage'; Section = 'Local'; Label = 'Видаляти старі архіви'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'minimumRetainedVerifiedBackups'; Group = 'Storage'; Section = 'Local'; Label = 'Мінімум перевірених копій'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'failedArchiveRetentionDays'; Group = 'Storage'; Section = 'Local'; Label = 'Retention невдалих архівів (дні)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'enableFailedArchiveDeletion'; Group = 'Storage'; Section = 'Local'; Label = 'Видаляти невдалі архіви'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 60 }
        @{ Path = 'enableOrphanTempCleanup'; Group = 'Storage'; Section = 'Local'; Label = 'Прибирати orphan temp-файли'; Description = ''; Type = 'Boolean'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 70 }
        @{ Path = 'orphanTempRetentionHours'; Group = 'Storage'; Section = 'Local'; Label = 'Retention orphan temp (год)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 80 }
        @{ Path = 'enableLunchArchiveCleanup'; Group = 'Storage'; Section = 'Local'; Label = 'Разове очищення legacy-каталогу'; Description = 'Сумісність зі старими інсталяціями.'; Type = 'Boolean'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 90 }
        @{ Path = 'lunchArchiveCleanupPath'; Group = 'Storage'; Section = 'Local'; Label = 'Шлях legacy-каталогу архівів'; Description = ''; Type = 'Path'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 100 }
        @{ Path = 'lunchArchiveRetentionMonths'; Group = 'Storage'; Section = 'Local'; Label = 'Retention legacy-каталогу (міс)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 110 }

        # ===== Storage / VSS-консистентність — фаза 1 =====
        @{ Path = 'backupConsistency.Mode'; Group = 'Storage'; Section = 'Consistency'; Label = 'Режим консистентності'; Description = 'VSS | Direct.'; Type = 'Enum'; AllowedValues = @('VSS', 'Direct'); Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'backupConsistency.SnapshotContext'; Group = 'Storage'; Section = 'Consistency'; Label = 'VSS SnapshotContext'; Description = ''; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 20 }

        # ===== Storage / SFTP (скаляри) — фаза 1 =====
        @{ Path = 'sftpHostTemplate'; Group = 'Storage'; Section = 'SFTP'; Label = 'Шаблон хоста SFTP'; Description = '{0} = логін зі сховища credentials.'; Type = 'String'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'sftpPort'; Group = 'Storage'; Section = 'SFTP'; Label = 'Порт SFTP'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'sftpHostKey'; Group = 'Storage'; Section = 'SFTP'; Label = 'SSH host-key (pinning)'; Description = 'Обов''язковий; значення з панелі провайдера. Security-critical — не accept-any-host-key.'; Type = 'String'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'sftpConnectionTimeoutSeconds'; Group = 'Storage'; Section = 'SFTP'; Label = 'Таймаут з''єднання SFTP (с)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 40 }

        # ===== Storage / SFTP каталоги (sftpDirectories) — фаза 2 =====
        @{ Path = 'sftpDirectories.MODEL'; Group = 'Storage'; Section = 'SFTP'; Label = 'SFTP каталог: MODEL'; Description = ''; Type = 'String'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'sftpDirectories.Blog'; Group = 'Storage'; Section = 'SFTP'; Label = 'SFTP каталог: Blog'; Description = ''; Type = 'String'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 60 }
        @{ Path = 'sftpDirectories.BravoExch'; Group = 'Storage'; Section = 'SFTP'; Label = 'SFTP каталог: BravoExch'; Description = ''; Type = 'String'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 70 }
        @{ Path = 'sftpDirectories.Manifest'; Group = 'Storage'; Section = 'SFTP'; Label = 'SFTP каталог: Manifest'; Description = ''; Type = 'String'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 80 }
        @{ Path = 'sftpDirectories.TraceLogs'; Group = 'Storage'; Section = 'SFTP'; Label = 'SFTP каталог: TraceLogs'; Description = ''; Type = 'String'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 90 }
        @{ Path = 'sftpDirectories.ExchangeApiLogs'; Group = 'Storage'; Section = 'SFTP'; Label = 'SFTP каталог: ExchangeApiLogs'; Description = 'Ключі BAZA/BAZAWWW не документовані для override — ефективна BAZA-конфігурація обчислюється до фази 2.'; Type = 'String'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 100 }
        # PR #136 (log-lifecycle P1): каталоги власних логів — діють лише
        # разом з componentSettings.SFTP.MaintenanceLogUploadEnabled/
        # ArchiveLogUploadEnabled (Components/SFTP вище).
        @{ Path = 'sftpDirectories.MaintenanceLog'; Group = 'Storage'; Section = 'SFTP'; Label = 'SFTP каталог: MaintenanceLog'; Description = 'Власні логи BRAVO_MAINTENANCE (+ знімки range_id_log) — opt-in, діє лише при componentSettings.SFTP.MaintenanceLogUploadEnabled=true.'; Type = 'String'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 110 }
        @{ Path = 'sftpDirectories.ArchivLog'; Group = 'Storage'; Section = 'SFTP'; Label = 'SFTP каталог: ArchivLog'; Description = 'Власні логи BRAVO_ARCHIV — opt-in, діє лише при componentSettings.SFTP.ArchiveLogUploadEnabled=true.'; Type = 'String'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 120 }

        # ===== Storage / SMB (smbSettings) — фаза 1 =====
        @{ Path = 'smbSettings.RootPath'; Group = 'Storage'; Section = 'SMB'; Label = 'Кореневий шлях SMB'; Description = 'UNC-шлях, напр. \\host\share\BRAVO.'; Type = 'UNCPath'; Phase = 1; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'smbSettings.Directories.MODEL'; Group = 'Storage'; Section = 'SMB'; Label = 'SMB каталог: MODEL'; Description = ''; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'smbSettings.Directories.BLOG'; Group = 'Storage'; Section = 'SMB'; Label = 'SMB каталог: BLOG'; Description = ''; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'smbSettings.Directories.BRAVOEXCH'; Group = 'Storage'; Section = 'SMB'; Label = 'SMB каталог: BRAVOEXCH'; Description = ''; Type = 'String'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'smbSettings.CopyBufferSizeMB'; Group = 'Storage'; Section = 'SMB'; Label = 'Розмір буфера копіювання (МБ)'; Description = ''; Type = 'Integer'; Phase = 1; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }

        # ===== Health (backupMonitoring) — фаза 2, загальні =====
        @{ Path = 'backupMonitoring.Enabled'; Group = 'Health'; Section = 'General'; Label = 'Health-моніторинг увімкнено'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'backupMonitoring.RunAfterBackup'; Group = 'Health'; Section = 'General'; Label = 'Запускати health після backup'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'backupMonitoring.CheckManagedServices'; Group = 'Health'; Section = 'General'; Label = 'Перевіряти керовані служби'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'backupMonitoring.MaxBackupAgeHours'; Group = 'Health'; Section = 'General'; Label = 'Максимальний вік backup (год)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'backupMonitoring.VerifyFileHash'; Group = 'Health'; Section = 'General'; Label = 'Перевіряти хеш файлів'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'backupMonitoring.NotifyOnSuccessAfterBackup'; Group = 'Health'; Section = 'General'; Label = 'Сповіщати про success після backup'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 60 }
        @{ Path = 'backupMonitoring.RepeatAlertAfterHours'; Group = 'Health'; Section = 'General'; Label = 'Дедуп критичних сповіщень (год)'; Description = '0 = надсилати щоцикл.'; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 70 }
        @{ Path = 'backupMonitoring.SuccessDedupMinutes'; Group = 'Health'; Section = 'General'; Label = 'Дедуп success-звітів (хв)'; Description = '0 = вимкнено; post-backup звіт не дедупиться.'; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 80 }

        # ===== Health / SFTP =====
        @{ Path = 'backupMonitoring.SFTP.Enabled'; Group = 'Health'; Section = 'SFTP'; Label = 'SFTP-перевірки увімкнено'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'backupMonitoring.SFTP.CheckArchiveUploads'; Group = 'Health'; Section = 'SFTP'; Label = 'Перевіряти завантаження архівів'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'backupMonitoring.SFTP.CheckBAZASynchronization'; Group = 'Health'; Section = 'SFTP'; Label = 'Перевіряти BAZA-синхронізацію'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'backupMonitoring.SFTP.VerifyRemoteArchiveHash'; Group = 'Health'; Section = 'SFTP'; Label = 'Перевіряти хеш віддаленого архіву'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'backupMonitoring.SFTP.RequireServerSideArchiveHash'; Group = 'Health'; Section = 'SFTP'; Label = 'Вимагати server-side хеш'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'backupMonitoring.SFTP.RemoteBackupMaxAgeHours'; Group = 'Health'; Section = 'SFTP'; Label = 'Максимальний вік remote backup (год)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 60 }
        @{ Path = 'backupMonitoring.SFTP.OperationTimeoutSeconds'; Group = 'Health'; Section = 'SFTP'; Label = 'Таймаут SFTP-операції (с)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 70 }
        @{ Path = 'backupMonitoring.SFTP.SynchronizationTimeoutSeconds'; Group = 'Health'; Section = 'SFTP'; Label = 'Таймаут синхронізації SFTP (с)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 80 }
        @{ Path = 'backupMonitoring.SFTP.BAZAPendingAlertAfterHours'; Group = 'Health'; Section = 'SFTP'; Label = 'BAZA pending alert (год)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 90 }

        # ===== Health / BAZA append-only двигун =====
        @{ Path = 'backupMonitoring.SFTP.BAZA.Mode'; Group = 'Health'; Section = 'BAZA'; Label = 'Режим BAZA-синхронізації'; Description = 'IncrementalAppendOnly | Legacy.'; Type = 'Enum'; AllowedValues = @('IncrementalAppendOnly', 'Legacy'); Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'backupMonitoring.SFTP.BAZA.SynchronizeBeforeHealth'; Group = 'Health'; Section = 'BAZA'; Label = 'Синхронізувати перед health'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'backupMonitoring.SFTP.BAZA.FastHealthEnabled'; Group = 'Health'; Section = 'BAZA'; Label = 'Швидкий health-режим'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'backupMonitoring.SFTP.BAZA.FullAuditEnabled'; Group = 'Health'; Section = 'BAZA'; Label = 'Повний аудит увімкнено'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'backupMonitoring.SFTP.BAZA.FullAuditEveryDays'; Group = 'Health'; Section = 'BAZA'; Label = 'Періодичність повного аудиту (дні)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold'; Group = 'Health'; Section = 'BAZA'; Label = 'Поріг авто-архівування мутацій'; Description = '0 = жорсткий блок будь-якої мутації; кіт-дефолт 25. Явне рішення власника (07-bravo-runtime-invariants.md) — не послаблювати без такого ж усвідомленого рішення.'; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 60 }

        # ===== Health / SMB =====
        @{ Path = 'backupMonitoring.SMB.Enabled'; Group = 'Health'; Section = 'SMB'; Label = 'SMB-перевірки увімкнено'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'backupMonitoring.SMB.RemoteBackupMaxAgeHours'; Group = 'Health'; Section = 'SMB'; Label = 'Максимальний вік remote backup SMB (год)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }

        # ===== Health / SizeSanity =====
        @{ Path = 'backupMonitoring.SizeSanity.Enabled'; Group = 'Health'; Section = 'SizeSanity'; Label = 'Sanity-перевірка розміру увімкнена'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'backupMonitoring.SizeSanity.HistoryCount'; Group = 'Health'; Section = 'SizeSanity'; Label = 'Розмір історії порівняння'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'backupMonitoring.SizeSanity.MaxSizeDropPercent'; Group = 'Health'; Section = 'SizeSanity'; Label = 'Максимальне падіння розміру (%)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 30 }

        # ===== Scheduler (schedulerSettings) — фаза 2 =====
        @{ Path = 'schedulerSettings.StartWhenAvailable'; Group = 'Scheduler'; Section = 'General'; Label = 'Запускати при першій нагоді (пропущені)'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 10 }
        @{ Path = 'schedulerSettings.WakeToRun'; Group = 'Scheduler'; Section = 'General'; Label = 'Прокидати комп''ютер для запуску'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 20 }
        @{ Path = 'schedulerSettings.OperationLockWaitMinutes'; Group = 'Scheduler'; Section = 'General'; Label = 'Очікування operation lock (хв)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 30 }
        @{ Path = 'schedulerSettings.Backup.Enabled'; Group = 'Scheduler'; Section = 'Backup'; Label = 'Задача Backup увімкнена'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 40 }
        @{ Path = 'schedulerSettings.Backup.DailyAt'; Group = 'Scheduler'; Section = 'Backup'; Label = 'Час щоденного запуску Backup'; Description = 'HH:mm, локальний час сервера.'; Type = 'Time'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 50 }
        @{ Path = 'schedulerSettings.Backup.ExecutionTimeLimitHours'; Group = 'Scheduler'; Section = 'Backup'; Label = 'Ліміт виконання Backup (год)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 60 }
        @{ Path = 'schedulerSettings.Maintenance.Enabled'; Group = 'Scheduler'; Section = 'Maintenance'; Label = 'Задача Maintenance увімкнена'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 70 }
        @{ Path = 'schedulerSettings.Maintenance.DailyAt'; Group = 'Scheduler'; Section = 'Maintenance'; Label = 'Час щоденного запуску Maintenance'; Description = 'HH:mm.'; Type = 'Time'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 80 }
        @{ Path = 'schedulerSettings.Health.Enabled'; Group = 'Scheduler'; Section = 'Health'; Label = 'Задача Health увімкнена'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 90 }
        @{ Path = 'schedulerSettings.Health.StartAt'; Group = 'Scheduler'; Section = 'Health'; Label = 'Час старту Health'; Description = 'HH:mm.'; Type = 'Time'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 100 }
        @{ Path = 'schedulerSettings.Health.RepeatEveryMinutes'; Group = 'Scheduler'; Section = 'Health'; Label = 'Повтор Health кожні (хв)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 110 }
        @{ Path = 'schedulerSettings.Health.SkipIfBackupTaskRunning'; Group = 'Scheduler'; Section = 'Health'; Label = 'Пропускати, якщо Backup виконується'; Description = ''; Type = 'Boolean'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 120 }
        @{ Path = 'schedulerSettings.Health.BusyWaitMinutes'; Group = 'Scheduler'; Section = 'Health'; Label = 'Очікування при зайнятості (хв)'; Description = '0 = негайне відкладення при зайнятій архівації.'; Type = 'Integer'; Phase = 2; Advanced = $true; ReadOnly = $false; Secret = $false; Order = 130 }
        @{ Path = 'schedulerSettings.BAZASync.StartAt'; Group = 'Scheduler'; Section = 'BAZASync'; Label = 'Час старту BAZA Sync'; Description = 'HH:mm.'; Type = 'Time'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 140 }
        @{ Path = 'schedulerSettings.BAZASync.RepeatEveryHours'; Group = 'Scheduler'; Section = 'BAZASync'; Label = 'Повтор BAZA Sync кожні (год)'; Description = ''; Type = 'Integer'; Phase = 2; Advanced = $false; ReadOnly = $false; Secret = $false; Order = 150 }
    )
    }
}
