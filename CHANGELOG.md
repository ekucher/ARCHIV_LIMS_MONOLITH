# Changelog

## Не випущено (developer)

- **Тест-ізоляція VersionState (SELFTEST-SAFETY-0 v1.4)** — сесійний
  кортеж із трьох env-змінних `BRAVO_SELFTEST_SESSION_ID` (GUID) +
  `BRAVO_SELFTEST_ROOT` (абсолютний локальний шлях з basename рівно
  `BRAVO_SELFTEST_<GUID>`) + `BRAVO_SELFTEST_VERSION_STATE_PATH` (рівно
  `<ROOT>\State\BRAVO_VERSION_STATE.json`) переспрямовує ЛИШЕ місце
  зберігання стану (`Resolve-BRAVOSelfTestIsolationContext` +
  `Test-BRAVOVersionDowngrade`); уся валідація версій/відкату виконується
  без змін. Це внутрішній regression-test seam, не production-налаштування
  і не security boundary. Рівно два валідні режими: без жодної змінної —
  канонічна production-поведінка (machine-global
  `%ProgramData%\BRAVO\State\`); повний валідний кортеж — ізольований
  sandbox. Частковий або некоректний кортеж (не-GUID, невідповідний
  basename, відносний шлях, traversal, sibling-префікс, UNC, reparse
  point/junction на ROOT чи `State`) — fail closed (`IsValid=false`,
  `ShouldBlock=true`) БЕЗ відкату до production-шляху; перевірка
  виконується ДО будь-якого читання/запису стану. Причина: fixture-діти
  `BRAVO_DATA_RESTORE_MATRIX_TEST.ps1` (справжні
  `BRAVO_ARCHIV`/`BRAVO_DATA_RESTORE`) після SemVer-фіксу #135 писали
  production high-water mark — на сервері з установленим toolkit це
  блокувало б старіший production runtime як "відкат" (знахідка
  real-server acceptance 2026-09-05). Matrix-test і self-test створюють
  одну сесію на прогін (`RUNNER_TEMP`/TEMP) і виставляють кортеж навколо
  fixture-запусків справжніх VersionState-consumer-ів (`BRAVO_ARCHIV`,
  `BRAVO_DATA_RESTORE`, dry-run summary), process-env, відновлення у
  `finally`. Ізоляція застосована лише там, де процес дійсно підключає
  `BRAVO_RUNTIME_GUARD.ps1` і викликає `Test-BRAVOVersionDowngrade`.
  Review-нотатка: перша версія цієї зміни додавала передачу кортежу
  через USER → SYSTEM у `Invoke-AsSystem`
  (`BRAVO_CREDENTIALS_SETUP.ps1`) — прибрано після review, бо цей SYSTEM
  worker не підключає `BRAVO_RUNTIME_GUARD.ps1` і не читає/пише
  `BRAVO_VERSION_STATE.json`, тож ізолювати там було нічого; сам
  переданий механізм (одноразовий згенерований launcher-скрипт) також
  містив дефект повторної PowerShell-інтерпретації вже сформованого
  рядка аргументів, що ламало шляхи із символом `$` чи зворотною
  скісною лапкою. `Invoke-AsSystem` знову використовує рівно історичну
  пряму команду без жодного launcher-а.

- **P0 Configuration Foundation (PR B/C)** — `BRAVO.config` став опційним
  primary override-шаром замість обов'язкового джерела конфігурації:
  precedence тепер `DEFAULT < BRAVO.config (опційно) < BRAVO.local.config`,
  повністю через один canonical pipeline
  (`Complete-BRAVOConfigurationLoad`/`Import-BravoConfiguration`, немає
  окремого config-present/config-absent коду). Дизайн-рішення й обґрунтування
  розбиття на PR A/B/C — `docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md`.
  - **Явний/AUTO намір оператора для `-ConfigPath`**: кожен entrypoint
    (`BRAVO_ARCHIV`/`BRAVO_MAINTENANCE`/`BRAVO_HEALTH`/`BRAVO_SETUP`/
    `BRAVO_TASKS_INSTALL`/`BRAVO_TASKS_DIAGNOSE`/`BRAVO_TASKS_UNINSTALL`/
    `BRAVO_CONFIG_TEST`) тепер фіксує, чи оператор реально передав
    `-ConfigPath` (`$PSBoundParameters.ContainsKey(...)`), ДО auto-дефолту,
    і передає цей намір явно в `Import-BravoConfiguration
    -ConfigPathWasExplicit`. AUTO + відсутній `BRAVO.config` — легітимний
    built-in-only/local-only шлях (не помилка). EXPLICIT + відсутній файл —
    як і раніше, помилка конфігурації.
  - **Task Scheduler (`BRAVO_TASKS_INSTALL/DIAGNOSE/UNINSTALL.ps1`)**:
    генеровані завдання й UAC-relaunch більше не вбудовують `-ConfigPath` у
    Arguments завдання при AUTO-режимі (кожен запуск завдання сам виконує ту
    саму AUTO-резолюцію проти свого `RuntimeRoot`) — вбудовується лише при
    EXPLICIT. Механічно доведено реальною інспекцією `ITaskDefinition.Actions
    [0].Arguments` (COM API), не лише `-ValidateOnly` exit-кодом.
  - **`BRAVO_SETUP.ps1`**: `Get-SetupConfiguration`/`Restart-SetupElevated`/
    manual `.cmd`-launcher-и (`BRAVO_ARCHIV.cmd`, `BRAVO_MAINTENANCE.cmd`,
    `BRAVO_MAINTENANCE_FORCE_RESTORE.cmd`) отримали той самий AUTO/EXPLICIT
    контракт; AUTO-launcher більше не вимагає фізичного `BRAVO.config` для
    генерації і не вбудовує `-ConfigPath` у згенерований `.cmd`-текст
    (mechanical proof — hermetic-тест читає реальний вміст `.cmd`).
  - **Configurator**: `BRAVO.Configurator.Effective.psm1` більше не падає,
    якщо в `RuntimeRoot` немає `BRAVO.config` (раніше — жорсткий throw);
    попутно виправлено застарілий опис `PublicIPLookupEnabled` у
    Configurator-схемі (стверджував "вимкнено за замовчуванням (P1.10)",
    хоча дефолт — `$true` уже з 2026-08-30, див. запис нижче).
  - **Security**: новий `Test-BRAVOEffectiveSecurityInvariants`
    (`BRAVO_CONFIG_LOADER.ps1`) перевіряє ПОСТ-merge ефективні
    `backupConsistency.Mode`/`toolIntegritySettings.Mode` одразу після
    завантаження конфігурації — закриває сліпу зону, де pre-trust guard
    (`BRAVO_RUNTIME_GUARD.ps1`) бачив лише текст `BRAVO.config`, а
    `BRAVO.local.config` міг послабити захист непоміченим. Поважає
    `BRAVO_RUNTIME_INTEGRITY_MODE`/`BRAVO_ALLOW_WEAKENED_SECURITY` (той
    самий контракт, що й existing guard).
  - **`BRAVO.config`**: 3 літеральні значення синхронізовано з canonical
    built-in дефолтами (задокументовано в `Get-BRAVODefaultConfiguration`
    як свідомі відхилення до цього PR): `maintenanceSettings.Limits.
    ExcludedDrives` `@('F:\')` → `@()`, `lunchArchiveCleanupPath`
    `"E:\Archiv"` → `""`, `smbSettings.RootPath` — placeholder → `""`.
    Мechanically перевірено (0 розбіжностей) постійним self-test.
  - **`BRAVO.local.config`** тепер у `.gitignore` (site-специфічний шар, не
    частина release-артефакту) — розділ "10. Оновлення в установі"
    `README.md` переписано: заміна комплекту більше не вимагає ручного
    перенесення значень у новий `BRAVO.config` при кожному оновленні.
  - Формальний characterization-тест паритету (`ci\
    Test-BRAVOConfigFoundationParity.ps1`, dev/CI-інструмент, не частина
    hermetic self-test): для ідентичного `BRAVO.local.config` над повним
    effective graph (76 `$global:*`-змінних) PR B (`feature/config-
    foundation-derivation`) і PR C дають ідентичний результат — 0
    нерегламентованих відмінностей.
  - Відомий, НЕ виправлений у цьому PR блокер: `BRAVO_CONFIG_INTEGRATE.ps1`
    (одноразовий міграційний інструмент під дуже старий inline-config
    патерн) наразі завжди падає проти поточного thin-entrypoint +
    `.Runtime.ps1` коду — застаріле вже до цього PR, потребує окремого
    рішення (fix/retire).

- Явне рішення власника (2026-08-30): `maintenanceSettings.Restore.Time` у
  `BRAVO.config` тепер `"21:00"` за замовчуванням (раніше `"03:00"`).
  `Restore.Day = 7` (неділя) лишається без змін. `"21:00"` збігається з
  `Restore.WindowStart`, тож на 24/7-системах (`BootRestoreMode = "None"`,
  дефолт) планова реставрація отримує повний запас вікна (21:00-03:00) на
  завершення, замість запуску практично на межі `WindowEnd`.

- Явне рішення власника (2026-08-30): `hostInformationSettings.PublicIPLookupEnabled`
  у `BRAVO.config` тепер `$true` за замовчуванням — замінює попередній
  P1.10-дефолт (`$false`). `Get-HostInformation` знову свідомо звертається
  до `api.ipify.org`/`checkip.amazonaws.com`, і публічна IP-адреса хоста
  показується в Slack/Discord-сповіщеннях. Fail-safe код-дефолт (коли
  `BRAVO.config` не завантажено) синхронізовано в `BRAVO.Notifications.psm1`
  (`$lookupEnabled = $true`). Хто потребує колишньої P1.10-поведінки (без
  зовнішнього запиту) — вимикає `PublicIPLookupEnabled = $false` явно в
  `BRAVO.local.config`.

- Додано `BRAVO_CONFIGURATOR.ps1` — інтерактивний GUI-редактор
  `BRAVO.local.config` (`modules/BRAVO.Configurator`: Schema/Model/Effective/
  Validation/Persistence/Presets/Credentials/Preview/UI). Schema-driven форма
  з усіма 138 override-ключами (1:1 з `BRAVO.local.config.example`),
  обчислення ефективної конфігурації через ізольований child-процес,
  атомарне застосування (timestamped+GUID backup, hash-verify, автоматичний
  rollback при провалі верифікації), responsive/DPI-safe WinForms UI з
  keyboard-навігацією. Пройшов цикл P0 (backend) → P1 (UI/Presets/
  Credentials/Preview) → P2-A (reliability/UX correctness) → P2-B
  (responsive/DPI/accessibility) з незалежними рев'ю на кожному етапі
  (`docs/design/BRAVO_CONFIGURATOR_DESIGN.md`). Раніше був відсутній у
  README.md/CHANGELOG.md, хоча код і self-test-покриття (1000+483 рядки)
  вже існували — цей запис і оновлення README.md закривають цю прогалину.
  `BRAVO.config` (canonical-дефолти) редагується, як і раніше, вручну.

- Регресійний тест `Scheduler/AclRuleAppliesToFilesAndFolders` перероблено з
  суто in-memory перевірки (`Get-Acl`+`AddAccessRule`, ніколи не викликала
  `Set-Acl`) на реальний функціональний проб, що застосовує from-scratch
  `DirectorySecurity`/`FileSecurity`-патерн `Set-BRAVOProtectedRuntimeAcl`
  через `Set-Acl` на тимчасовий каталог+файл і звіряє результат через
  `Get-Acl`. Попередня версія тесту проходила навіть тоді, коли hardening
  ACL падав на бойовому сервері (code-review 2026-08-31).

- Задокументовано обмеження (2026-09-02, реальний real-server acceptance
  прогін): `diskshadow.exe` не гарантований на клієнтських Windows 10/11
  (підтверджено відсутнім на 2 машинах), тоді як на Windows Server він
  штатний. BRAVO вимагає `diskshadow.exe` лише коли джерела архіву
  (`MODEL`/`BLOG`/`BRAVOEXCH`) розташовані на кількох різних томах —
  інакше `BRAVO_DRY_RUN.ps1`/`BRAVO_SETUP.ps1` fail-closed зупиняються на
  `[FAIL] VSS`. Це навмисна поведінка (не послаблюється), задокументована
  в `README.md` §1 і `OPERATIONS.md` §"`40`" з порадою звести джерела на
  один том, якщо `diskshadow.exe` недоступний.

- Додано `ci\acceptance\Test-BRAVOVSSSingleVolumeAcceptance.ps1` —
  real-server acceptance-скрипт для перевірки фіксу вище: запускає
  канонічний `BRAVO_DRY_RUN.ps1` як дочірній процес і звіряє, що всі
  джерела архіву на одному томі та категорія `VSS` — `PASS`. Призначений
  запускати на цільовому сервері після фізичного перенесення джерел на
  один том.

> Примітка: розділи 5.2.2-* нижче перенесено з `hotfix/5.2.2` (гілка, відгалужена від релізу v5.2.1) під час інтеграції у `developer`; вони стоять вище за датою запису, хоча `developer` вже пройшов через цикл 5.3.0 — функціонал 5.2.2 тепер частина поточної лінії розробки.

## 5.2.2 — 2026-08-31

Stable promotion від прийнятого `5.2.2-rc.2` (нижче) — real-server acceptance
на SRV_WORK (тому самому сервері, де раніше падав ACL-баг): `BRAVO_SETUP.ps1`
[1/5] Захист runtime ACL — OK; idempotent повторний `BRAVO_TASKS_INSTALL.ps1`;
перший повний `BRAVO_ARCHIV.ps1` (MODEL/BLOG/BRAVOEXCH, VSS, SHA512, SFTP) —
COMPLETE generation; `BRAVO_HEALTH.ps1` після нього — 0 errors. Release-
metadata-only зміни відносно прийнятого rc.2: `VERSION.json` (packageVersion
`5.2.2-rc.2` → `5.2.2`, releaseChannel `prerelease` → `stable`),
README.md/BRAVO_SETUP.md заголовки, цей розділ CHANGELOG, RUNTIME_MANIFEST.json
регенеровано. Жодних функціональних runtime-змін відносно прийнятого rc.2.

## 5.2.2-rc.2 — 2026-08-30

Hotfix-кандидат: rc.1 + вузький ACL-фікс, знайдений і підтверджений на
реальному сервері SRV_WORK (не через self-test, через фактичний запуск
`BRAVO_SETUP` на встановленій копії).

- **FIX (scheduler, runtime ACL):** `BRAVO_TASKS_INSTALL.ps1` падав двома
  різними .NET-винятками при захисті runtime ACL — "This access control
  list is not in canonical form" і "Some or all identity references could
  not be translated" (orphaned SID). Причина: `Set-BRAVOProtectedRuntimeAcl`
  читав існуючий ACL через `Get-Acl` і намагався прибрати з нього старі
  правила замість повної заміни. Тепер ACL будується з чистого
  `New-Object DirectorySecurity/FileSecurity` — той самий кінцевий
  результат (Administrators/SYSTEM FullControl, Users ReadAndExecute), без
  залежності від стану попереднього ACL. Регресійний self-test:
  `Scheduler/ProtectedRuntimeAclDoesNotMutateExistingDacl`.
- **FIX (self-test, супутня знахідка):** `Scheduler/RecoveryEnabledMissingRootsFailsValidation`
  хибно падав через жорсткий CRLF-перенос ПОСЕРЕД слова у форматованому
  виводі дочірнього non-interactive `powershell.exe` (ширина консолі) —
  нормалізовано в `Invoke-BRAVOSelfTestTaskInstallValidateOnly`. Не
  впливає на production-поведінку `BRAVO_TASKS_INSTALL.ps1`.

Локальні гейти: повний `BRAVO_SELF_TEST.ps1` (1477 PASS / 0 FAIL).
Real-server acceptance для rc.2 — окремий крок, ще не проводився.

## 5.2.2-rc.1 — 2026-08-29 (superseded by rc.2)

Release-metadata-only promotion of `5.2.2-dev.1` (нижче) до Release
Candidate: `packageVersion`/`releaseChannel` bump per `RELEASE_POLICY.md`
розділ 8, без функціональних runtime-змін відносно implementation-коміту
`a5eec35` (`feat(storage): add global SFTP and SMB controls for 5.2.2`).
Локальні гейти: повний `BRAVO_SELF_TEST.ps1` (1476 PASS / 0 FAIL), Parser,
PSScriptAnalyzer, ForbiddenPattern, Runtime Manifest, Tools Manifest,
ReleasePolicy — усі PASS. Real-server acceptance ще не проводився —
обов'язковий перед промоцією в stable (SFTP ON/OFF × SMB ON/OFF та
exchangAPI legacy-міграція на ізольованій fixture).

## 5.2.2-dev.1 (hotfix/5.2.2, у розробці)

### Додано
- Глобальні master-switches зовнішніх сховищ: `componentSettings.SFTP.Enabled`
  та `componentSettings.SMB.Enabled` (відсутній ключ у legacy-конфігах = `$true`).
  `Enabled = $false` вимикає всі автоматичні мережеві операції відповідного
  destination (архіви, BAZA, Health, Maintenance, Dry Run проби) без зміни
  дочірніх налаштувань; повторне ввімкнення відновлює попередню effective-поведінку.
  Local-only режим (обидва `$false`) — підтримувана production-конфігурація.

### Виправлено
- `BRAVO_CREDENTIALS_SETUP.ps1`: формула обов'язковості SFTP-креденшелів не
  враховувала `componentSettings.Synchronization.BAZA_WWW_SFTP` — сервер лише з
  WWW-синхронізацією не вважав SFTP-креденшели обов'язковими.
- `BRAVO_ARCHIV.ps1 -SyncBAZA` при глобально вимкненому SFTP завершується
  чистим SKIPPED з кодом 0 (раніше конфігурація без жодної SFTP-цілі давала
  помилковий exit 50).
- `modules/BRAVO.Maintenance/BRAVO.Maintenance.Runtime.ps1`:
  `Invoke-BRAVOLegacyLogMigration` більше не знищує timestamp у вже
  унікальному джерельному імені exchangAPI-журналу
  (`exchangAPI_yyyy-MM-dd_HHmmss.log`) під час одноразової legacy-міграції —
  раніше такий файл перейменовувався в `exchangAPI_N.log` через sequence-
  гілку, призначену лише для старих sequence-стильних legacy-імен
  (`exchangAPI.log`/`exchangAPI_1.log`). Виявлено на продакшені. Новий
  `Test-BRAVOIsTimestampedExchangeApiLogName` розпізнає timestamped-формат і
  скеровує такі файли через `NamingPolicy='Original'` (той самий контракт,
  що вже застосовує поточна не-legacy ротація exchangAPI): ім'я зберігається
  точно, колізія імені в призначенні — fail-closed (без перезапису, без
  перейменування джерела). Старі sequence-стильні legacy-імена й далі
  проходять через незмінену послідовну нумерацію.

---

## 5.3.0-dev.2 — 2026-09-02

Повернення `developer` у development-канал поверх тегованого
`5.3.0-rc.1` (тег `v5.3.0-rc.1` лишається незмінним, pending
acceptance — не rejected, не promoted). Причина: власник доручив
почати P0 Configuration Foundation (нове canonical джерело built-in
raw defaults, `BRAVO.config` як optional override, precedence
`DEFAULT < BRAVO.config < BRAVO.local.config`, discovery/derivation
після merge) — це feature/architecture-робота, яку `RELEASE_POLICY.md`
§3.2 прямо забороняє вносити в заморожений RC («не повинен отримувати
нові функції»). Замість маскування feature під fix відкрито новий
prerelease-цикл. Лише метадані версії в цьому коміті: VERSION.json
5.3.0-dev.2/development, заголовки README/BRAVO_SETUP, RELEASE_POLICY
§20 (ModuleVersion `*.psd1` не змінюється — базова частина версії
лишається `5.3.0`). Наступний кандидат цього циклу (rc.2) успадкує
весь зафіксований scope dev.1 (P1.1 `BRAVO_RESTORE_VERIFY`, P2.1
status contract, FIX-пакет deferred-боргів 5.2.0) плюс P0
Configuration Foundation.

---

## 5.3.0-rc.1 — 2026-08-26 (candidate, pending acceptance)

Перший кандидат циклу 5.3.0. Кандидат = `5.3.0-dev.1` (розділ нижче:
P1.1 `BRAVO_RESTORE_VERIFY`, P2.1 machine-readable status contract,
FIX-пакет deferred-боргів 5.2.0). Runtime-зміни в цьому bump відсутні —
лише версійні метадані.

Scope real-server acceptance rc.1 (уся нова поверхня циклу):

- повторний запуск `BRAVO_TASKS_INSTALL.ps1` → задача
  `BRAVO_RESTORE_VERIFY` (weekly, Сб 04:00) зареєстрована;
  `BRAVO_TASKS_DIAGNOSE.ps1` зелений (включно з weekly-тригером);
- прогін drill (ручний `schtasks /Run \BRAVO\BRAVO_RESTORE_VERIFY` або
  суботній слот): консоль SCHEDULED-режиму, стан
  `BRAVO_RESTORE_VERIFY_STATE.json`, SUCCESS-повідомлення в GENERAL;
- Health: крок «Відновлюваність (restore drill)» (до першого прогону —
  нагадування, після — вік верифікації);
- файли `%ProgramData%\BRAVO\State\STATUS\BRAVO_STATUS_<Operation>.json`
  від SYSTEM-задач (Archive/Health/Maintenance/RestoreVerify) після
  нічного циклу;
- lock-wait: за конкуренції Archive/Maintenance у лозі видно, хто
  тримає lock;
- Compare-FileSizes: недільна реставрація без false-positive (нова
  enumeration + settle-retry), tripwire мовчить;
- dry-run `-SendTestNotification`: тестове повідомлення в GENERAL;
- `BRAVO_TASKS_UNINSTALL.ps1` (на тестовому сервері): видаляє й
  BAZASync-задачу.

Зміст кандидата (накопичено в developer після dev.1):

- **FIX-пакет (deferred debts циклу 5.2.0):** п'ять відкладених
  runtime/операційних боргів одним PR (окремі коміти):
  1. *Lock-wait діагностика* (порт `127e7e4` з
     `backup/local-developer-rc2-line`): обидва власники спільного
     `BRAVO_OPERATION.lock` (Archive/Maintenance) кожні 30 с очікування
     логують, ХТО тримає lock (operation/pid/hostname/startedAt/
     generationId) і залишок часу; handle власника з `FileShare.Read`
     (peek можливий, ексклюзивність не слабшає).
  2. *Compare-FileSizes* (порт `67f3ad3`+`e2c61e1`+`f7f6628` у
     переписане в 5.2.0 тіло): пряма
     `[IO.DirectoryInfo]::EnumerateFiles`-enumeration з Hidden/System-
     фільтром замість ненадійного `Get-ChildItem -Recurse`
     (детермінований інцидент ДНДІЛДВСЕ ~364 «зниклих» файлів) +
     settle-retry 12×15с ЛИШЕ при знайдених критичних розбіжностях
     (AV-race видимості; канонічний фікс — AV-виняток, runbook у
     OPERATIONS.md код 43); tripwire розсинхрону шляхів виконується
     один раз після retry-циклу; fail-closed не послаблено (регресії
     SettleRetry* — реальний файл через Start-Job).
  3. *BOM-міграція `Get-BRAVOSevenZipArchiveInventory`* (DataRestore):
     тонкий адаптер над канонічною `Get-BRAVOSevenZipArchiveEntries` —
     остання точка legacy `StandardInput.WriteLine(пароль)` прибрана;
     контракт повернення незмінний; гейт
     `Secrets/SevenZipPasswordUsesStdin` розширено на DataRestore.
  4. *Dry-run тестове повідомлення* — у GENERAL (SUCCESS-семантика)
     замість ALERTS; SETUP/TASKS_DIAGNOSE успадковують.
  5. *TASKS_UNINSTALL* — видаляє й задачу BAZASync (історичний пропуск
     переліку деінсталяції).

- **FEATURE (P2.1, status contract): machine-readable статус останніх
  прогонів.** Новий тонкий модуль `BRAVO.Status` (schemaVersion 1) —
  канонічний власник контракту: Archive, Health, Maintenance і
  RestoreVerify після обчислення exit code атомарно пишуть
  `%ProgramData%\BRAVO\State\STATUS\BRAVO_STATUS_<Operation>.json`
  (спільне ядро: host/packageVersion/operation/status/exitCode/
  exitCodeName/startedAt/finishedAt/durationSeconds + операційні
  `details`; Health додатково несе lastCompleteGeneration/
  lastRestoreVerifiedAt/localVerified/sftpVerified/smbVerified/
  runtimeIntegrity/toolIntegrity — ескіз ROADMAP P2.1). Інваріанти:
  fail-soft (помилка запису лише WARNING-лог, ніколи не змінює exit
  code/результат операції — покрито самотестами CallSiteIsFailSoft для
  всіх 4 call-site'ів), status = проєкція exitCode (0=OK, 10=WARNINGS,
  інше=ERROR; деривація в одному місці), жодних secret-bearing значень
  (самотест), fail-closed читання невідомої schemaVersion. Archive
  пише статус і при фатальному краху (ERROR/90 best-effort); Maintenance
  — і на ранньому виході disk-preflight; вбудований у Archive
  Health-виклик статус НЕ пише (не перезаписує самостійний прогін).
  Транспорт/моніторинг (Zabbix/outbox, P2.2) свідомо не входить —
  контракт локальний. Регресії: `selftest\BRAVO_SELF_TEST.Status.ps1`.

- **FEATURE (P1.1, restore verification): планова перевірка
  відновлюваності `BRAVO_RESTORE_VERIFY`.** Новий тип задачі Планувальника
  `RestoreVerify` (weekly-тригер, типово Сб 04:00;
  `schedulerSettings.RestoreVerify` з loader-дефолтами для legacy-конфігів)
  запускає наявний `BRAVO_RESTORE_TEST.ps1 -NoPause -NotifyOnSuccess` —
  без другої копії drill-логіки. Новий тонкий модуль `BRAVO.RestoreVerify`
  володіє станом `%ProgramData%\BRAVO\State\BRAVO_RESTORE_VERIFY_STATE.json`
  (атомарний запис; `LastVerifiedAt` оновлюється лише повністю чистим
  прогоном — 0 FAIL і 0 WARN) і health-оцінкою віку. Новий Health-крок
  «Відновлюваність (restore drill)»: ERROR при FAIL останнього drill,
  пошкодженому стані або віці понад
  `restoreVerifySettings.MaxVerificationAgeHours` (типово 216 год);
  відсутній стан після оновлення — лише нагадування. `BRAVO_RESTORE_TEST`
  додатково отримав runtime guard (33/34/35, паритет з рештою
  entrypoint-ів — стосується й ручних запусків), bounded cleanup
  покинутих drill-каталогів (>7 діб, ≤10 за прогін), канонічний
  notification-маршрут (FAIL→CRITICAL/WARN→WARNING в ALERTS,
  SUCCESS→GENERAL за `-NotifyOnSuccess`) і `MinimumFileCount` з
  конфігурації. Канонічний `ConvertTo-BRAVODaysOfWeekMask` (BRAVO.System)
  спільний для Installer/Diagnose; `BRAVO_TASKS_DIAGNOSE` перевіряє
  weekly-тригер і аргументи, `BRAVO_TASKS_UNINSTALL` видаляє задачу.
  Регресії: `selftest\BRAVO_SELF_TEST.RestoreVerify.ps1` (state roundtrip,
  політика LastVerifiedAt, health-таблиця, mask, контракти, legacy-loader
  probe). Real-server acceptance розкладу — окремим прогоном. Exit-контракт
  drill незмінний (0/10/41/90).

---

## 5.3.0-dev.1 — 2026-08-26

Відкриття наступного циклу розробки після stable-релізу 5.2.0
(RELEASE_POLICY §11: негайний prerelease-bump, щоб `developer` і
`master` не несли однакову версію). Лише метадані версії: VERSION.json
5.3.0-dev.1/development, ModuleVersion усіх 17 `modules\*\*.psd1` →
5.3.0, заголовки README/BRAVO_SETUP, RELEASE_POLICY §20.

Записаний борг/план циклу 5.3.0 (пріоритети власника: P1 → P2 → далі):

- **P1 — Scheduled Restore Verification** *(виконано в dev.1,
  `BRAVO_RESTORE_VERIFY`)*.
- **P2 — Machine-readable Status Contract v1** *(виконано в dev.1,
  `BRAVO.Status`)*.
- Відкладені runtime-фікси: settle/AV/enumeration Compare-FileSizes
  (збережені в `backup/local-developer-rc2-line`), `127e7e4`
  lock-wait diagnostics. *(Виконано в dev.1 — пакет deferred-фіксів
  нижче.)*
- P2-знахідка acceptance: dry-run тест-повідомлення завжди в ALERTS.
  *(Виконано в dev.1 — тест іде в GENERAL.)*
- P3.2a (`BRAVO_UPDATE.ps1`), M1 (`WinSCP.uk` у TOOLS_MANIFEST після
  підтвердження походження), M3 — відкриті. BOM known-issue
  `Get-BRAVOSevenZipArchiveInventory` *(виконано в dev.1 — міграція на
  канонічну `Get-BRAVOSevenZipArchiveEntries`)*.
- Гігієна: видалення ~15+ злитих remote-гілок циклу 5.2.0 — відкрито.

---

## 5.2.1 — 2026-08-29

Stable release of the 5.2.1 hotfix line, promoted from accepted
`5.2.1-rc.9` (tag `v5.2.1-rc.9`, stamp `f99134d`) plus the additional
fixes/features below, validated end-to-end via production acceptance
on preview build `BRAVO-Toolkit-5.2.1-rc.10-preview-6737485.zip`
(snapshot `6737485`, sha256
`8c70324596fa55a805877e767529d77d9ff4db9472f2626ae2e749bc27692155`):
Runtime Guard 82/82, SELF-TEST 1447/0, real Archive (MODEL/BLOG/
BRAVOEXCH + SFTP), BAZA_APP/BAZA_WWW sync, CurrentUser/SYSTEM
notification delivery, retry-safe Recovery, BusyWait 60-min overlap,
CurrentUser/SYSTEM state writes.

- **FIX P0 (self-test/health, process isolation): orphaned SELF-TEST
  service-helper function could shadow production `Get-Service`/
  `Start-Service`/`Stop-Service`/`Get-CimInstance`/`Get-WmiObject` for
  the rest of the process.** `BRAVO_SELF_TEST.ps1` builds throwaway
  dynamic modules/functions to simulate service states for its
  fixtures; a cleanup gap could leave one of these shadowing the real
  cmdlet in the caller's scope after SELF-TEST returned. In a
  long-lived process (e.g. a scheduled task host that runs SELF-TEST
  and then Health in the same session) this silently turned real
  Health service checks into mocked results. New ownership registry
  (`$script:BRAVOSelfTestOwnedRuntimeModules`) tracks every dynamic
  module/function SELF-TEST creates; `Clear-BRAVOSelfTestOwnedRuntimeModules`
  removes them all before SELF-TEST returns, run unconditionally after
  the top-level try/catch, before the exit code is computed. Five new
  fail-loud regression tests confirm `Get-Service`/`Start-Service`/
  `Stop-Service` resolve back to `Microsoft.PowerShell.Management` and
  that no SELF-TEST-owned module/function remains exported after a
  full run. Re-validated same-process against the built ZIP artifact
  (PID unchanged before/after SELF-TEST).
- **FEATURE (health, notification): semantic SUCCESS-report deduplication
  with retry-safe Recovery lifecycle.** A healthy Health run now sends
  at most one duplicate-content SUCCESS notification per
  `backupMonitoring.SuccessDedupMinutes` window (kit default `1380` =
  23h, one green report per day; embedded post-backup reports and
  `-ForceNotification` always bypass dedup; `0` disables it). Recovery
  from an unhealthy state is never deduplicated: a new
  `RecoveryPending` operational-state flag is set the moment Health
  goes unhealthy and is cleared only after a Recovery SUCCESS
  notification is actually delivered — a failed delivery preserves
  `RecoveryPending` so the next healthy run retries the recovery
  report instead of silently deduplicating it.
- **FIX (health/scheduler): `schedulerSettings.Health.BusyWaitMinutes`
  kit default `20` -> `60`.** Production acceptance showed the
  scheduled BAZASync lock window can exceed 20 minutes; Health now
  waits up to 60 minutes for the archive lock to clear before
  deferring (loader range unchanged at `0..90`, explicit `0` still
  disables waiting).
- **FEATURE (discovery): BAZA_WWW Apache-based discovery with an
  explicit Present/Absent/Ambiguous/Error presence contract.**
  `Test-BRAVOBazaWwwInstallation` validates the resolved
  `<DocumentRoot>\BAZA` candidate (real directory, not a reparse
  point/symlink, non-empty) before accepting it; explicit
  `discoverySettings.Sources.BAZA_WWW` override still takes priority
  and fails closed (visible `Error`, no silent fallback) on an
  invalid override, matching existing `BravoRoot` discovery policy.
- **BREAKING NOTIFICATION MIGRATION: legacy provider-wide webhook-и
  `BRAVO_DISCORD_URL` та `BRAVO_SLACK_URL` більше не підтримуються.**
  Кожен канал резолвиться виключно через route-специфічні credentials
  (`BRAVO_DISCORD_GENERAL_URL`/`BRAVO_DISCORD_ALERTS_URL`,
  `BRAVO_SLACK_GENERAL_URL`/`BRAVO_SLACK_ALERTS_URL`) без provider-wide
  fallback і без fallback між каналами. Обов'язкова topology:
  `errors_only` -> ALERTS; `all` -> GENERAL + ALERTS; `none` -> нічого.
  Перед оновленням (або після міграційної помилки Dry Run/Setup)
  налаштуйте канальні записи для CurrentUser і SYSTEM:
  `.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Discord -StoreFor Both`
  (аналогічно `-Component Slack`). Старі записи ігноруються і не
  видаляються автоматично. Також: `BRAVO_RESTORE_TEST` переведено на
  канонічний notification-конвеєр; новий opt-in інтеграційний тест
  реальної доставки `BRAVO_NOTIFICATION_TEST.ps1`; у Maintenance
  видалено мертвий `SlackMessageBuffer` (6 error-повідомлень, що мовчки
  губились, тепер доставляються через ALERTS).

Real-server production acceptance evidence: local Git/provenance PASS,
production regression sweep PASS (see acceptance handoff for full gate
list). No outstanding blocking findings.

---

## 5.2.1-rc.9 — 2026-08-27 (hotfix candidate, pending acceptance)

Кандидат = rc.8 + фікс систематичного пропуску денних health-прогонів
(доведено логами ДНДІЛДВСЕ 25-27.08.2026) + повний каталог
`BRAVO.local.config.example`:

- **FIX (health/scheduler): денний слот health-прогону систематично
  з'їдався BAZASync.** Синхронізація (`BRAVO_ARCHIV -SyncBAZA`, кожні
  4 год о `:00`) тримає lock архівації ~16-17 хв і накривала слот
  Health `00:15`: кожен денний прогін відкладався без повтору, зелені
  звіти йшли лише з нічного post-backup Health. Двошарово:
  (1) kit-дефолт `schedulerSettings.Health.StartAt` `00:15` -> `00:30`
  (набуває чинності після повторного `BRAVO_TASKS_INSTALL.ps1`);
  (2) новий ключ `schedulerSettings.Health.BusyWaitMinutes` (kit 20;
  loader-нормалізація: legacy без ключа -> 20, некоректне значення ->
  Warning + 20, явний `0` = стара поведінка) — при зайнятій архівації
  Health обмежено чекає звільнення (повторна перевірка сигналів кожні
  30 с) і відкладається лише після вичерпання ліміту. Регресії:
  `Health/BusyBackupBoundedWaitBeforeDeferral`,
  `ConfigLoader/HealthBusyWait*` (3 сценарії).
- **Повний каталог `BRAVO.local.config.example`**: 132 підтримувані
  override-ключі по блоках/фазах, перевірені loader-ом; свідомо без
  `discoverySettings` і `sftpDirectories.BAZA/BAZAWWW` (споживаються до
  фази 2).

Acceptance rc.9 додатково включає: re-run `BRAVO_TASKS_INSTALL`
(тригер Health 00:30), зелений звіт із денного слота, сценарій
очікування (ручний Health під час активної синхронізації -> INFO
«зачекає» -> звіт після звільнення lock).

---

## 5.2.1-rc.8 — 2026-08-27 (hotfix candidate, pending acceptance)

Кандидат = rc.7 + фікс хибного ERROR у сповіщенні про несумісні імена
(знайдено аналізом acceptance-логів ХРДЛ 27.08: rc.5/rc.6 -SyncBAZA):

- **FIX (notifications): одно-chunk результат
  `ConvertTo-BRAVONotificationPayloadText` втрачав масивність.**
  `return @(...)` PowerShell 5.1 розгортає в скаляр-[string] на виході
  з функції; наступний `.Count` в Archive Runtime під
  `Set-StrictMode 2.0` кидав `PropertyNotFoundException` — у лог падав
  ERROR «Не вдалося відправити сповіщення про несумісні імена
  BAZA_APP», хоча webhook на той момент уже був доставлений
  (`Send-BRAVONotificationChunks` виконується до `.Count`). Канонічний
  фікс у конверторі (unary comma: `return ,@(...)`) — масив
  гарантовано для будь-якої кількості chunk-ів, усі викликачі
  (Archive/Health/Maintenance/DataRestore/`Send-BRAVONotification`
  `ChunkCount`) отримують коректний `.Count`. Дефект існував з 5.2.0
  (не регресія hotfix-лінії). Регресія
  `Notifications/PayloadTextSingleChunkKeepsArrayness`: пре-фікс
  репродукція на rc.7 відтворила точний серверний виняток; після
  фіксу — масив із Count=1.

- **FIX (self-test, CI): local-config сценарій `FileAbsentIsNoop`
  залежав від середовища прогону.** CI «Release artifact» на тегу
  v5.2.1-rc.7 упав: без `BRAVO.local.config` копія комплектного
  `BRAVO.config` виконувалась із дефолтом `BackupRoot=""` (AUTO →
  `<EffectiveLIMSRoot>\ARCHIV`), а на GitHub runner немає інсталяції
  LIMS → «Не вдалося визначити BackupRoot»; stderr дочірнього процесу
  під `$ErrorActionPreference='Stop'` валив увесь self-test як
  `[FAIL] Fatal` (на dev/серверах LIMS є, тому локально зелено).
  Сценарії тепер герметичні: у копію конфігурації запікається явний
  `BackupRoot` (окремий від override-каталогу — фаза-1 сценарій
  відтепер доводить пріоритет override над явним значенням), а
  дочірні probe-процеси загорнуто в try/catch (майбутній збій — чистий
  FAIL сценарію з причиною, не Fatal-крах прогону). Дефект лише у
  валідаційному інструментарії; runtime-поведінка rc.7 коректна.

Acceptance rc.8 (додатково до rc.7): на інсталяції з несумісними
іменами BAZA (напр., ХРДЛ) прогнати `-SyncBAZA` → у лозі SUCCESS
«Сповіщення про N несумісних імен … відправлено», без ERROR
«Не вдалося відправити…: Не удается найти свойство "Count"».

---

## 5.2.1-rc.7 — 2026-08-27 (hotfix candidate, NOT accepted — superseded by rc.8)

Кандидат = rc.6 + локальні site-overrides конфігурації (запит власника:
«втомився кожного разу виправляти конфіг на нетипових інсталяціях»):

- **FEATURE (config): `BRAVO.local.config` — site-відмінності, що
  переживають оновлення комплекту.** Опційний data-only файл поряд з
  effective `BRAVO.config` (шаблон `BRAVO.local.config.example` у
  комплекті): hashtable «dot-шлях → значення». Loader читає його до
  виконання конфігурації; `BRAVO.config` застосовує overrides у двох
  канонічних фазах — після первинних блоків (перевизначений
  `pathSettings.BackupRoot` коректно протягується в archiveDirs/
  discovery/scheduler; `Restore.BootRestoreMode` → `Recovery.Enabled`)
  і наприкінці (пізні leaf-блоки: `backupMonitoring`, `sftpDirectories`,
  `schedulerSettings`). Безпека/надійність: виконуваний код у файлі
  відхиляється (`CheckRestrictedLanguage`, лише літеральні дані);
  невідомий dot-шлях = помилка конфігурації (опечатки не мовчать);
  застосовані ключі — у `BravoConfigurationMetadata.LocalConfigOverrides`.
  4 регресії в ConfigLoader-фрагменті (обидві фази з деривацією,
  typo fail-closed, code-rejection, no-op без файла). Документація:
  BRAVO_SETUP.md.

Acceptance rc.7 (додатково до rc.6): на нетиповій інсталяції створити
`BRAVO.local.config` (напр., `pathSettings.BackupRoot`), оновити
комплект → налаштування діють без редагування `BRAVO.config`; ключ з
опечаткою → зрозуміла помилка конфігурації.

---

## 5.2.1-rc.6 — 2026-08-27 (hotfix candidate, NOT accepted — superseded by rc.7)

Кандидат = rc.5 + свідома зміна дефолту порогу авто-архівування BAZA
(реальний алерт ДНДІЛДВСЕ 23:00: 18 легітимних мутацій PDF-звітів →
CRITICAL «ПОТРІБНА ДІЯ», хоча механізм auto-archive існує з 5.2.0, але
був вимкнений дефолтом 0):

- **CONFIG (BAZA, рішення власника 2026-08-27):**
  `backupMonitoring.SFTP.BAZA.AutoArchiveMutationThreshold` у комплекті
  тепер `25` (було `0` = вимкнено). Мутації ≤ 25 за цикл на компонент
  авто-архівуються rename-preserve (`*.replaced_*`, нічого не
  втрачається) з інформаційним Health-повідомленням; > 25 — незмінний
  жорсткий блок/CRITICAL. Runtime-код не змінювався (механізм наявний з
  5.2.0). Site-config'и БЕЗ ключа і далі отримують fail-closed `0`
  (fallback loader-а незмінний) — нове значення діє лише там, де
  розгорнуто конфіг комплекту або ключ задано явно. Документацію
  (OPERATIONS/THREAT_MODEL/README/конфіг-коментар) синхронізовано;
  залишковий ризик per-cycle порогу зафіксовано там само.

Acceptance rc.6 (додатково до rc.5): на ДНДІЛДВСЕ після оновлення
конфіга — наступний цикл авто-архівує ≤25 мутацій (INFO, без
«ПОТРІБНА ДІЯ»), старі remote-версії з суфіксом `.replaced_*`.

---

## 5.2.1-rc.5 — 2026-08-26 (hotfix candidate, NOT accepted — superseded by rc.6)

Кандидат = rc.4 + фікс хибного CRITICAL при зайнятому WinSCP (реальний
алерт SERV_HRDL_1/ХЕРСОНСЬКА РДЛ 23:03: «Запуск WinSCP для SFTP
health-check заблоковано: виявлено активний WinSCP.com»):

- **FIX (health, операторський UX): зайнятий WinSCP = відкладення, а не
  CRITICAL.** `Get-SFTPHealthIssues` тепер pre-check-ом перевіряє
  доступність WinSCP до мережевих кроків: якщо інша BRAVO-передача ще
  тримає WinSCP.com — SFTP-перевірка відкладається (WARNING у лозі з
  PID і підказкою, кроки SFTP — SKIPPED, `SftpVerified` не
  підтверджується), наступний health-прогін перевірить знову. Гонковий
  випадок після pre-check лишається ERROR (друга лінія захисту).

Acceptance rc.5 (додатково до rc.4): health-прогін під час активної
передачі → ЧАСТКОВО/exit 10, жовте сповіщення «відкладено», кроки SFTP
SKIPPED; без конкуренції — звичайна повна перевірка.

---

## 5.2.1-rc.4 — 2026-08-26 (hotfix candidate, NOT accepted — superseded by rc.5)

Кандидат = rc.3 + фікс накопичення diskshadow metadata-.cab (реальний
звіт SERVER-01/Тернопіль: файли `NN-DD.MM.YYYY-HH_--_SERVER-01.cab` у
`C:\Program Files\BRAVO-Toolkit` після кожної багатотомної архівації):

- **FIX (archive/VSS): metadata-.cab diskshadow — у TEMP і прибирається.**
  Сценарій diskshadow.exe не задавав `SET METADATA`, тому VSS writer
  metadata `.cab` з автоіменем писався в робочий каталог планової
  задачі (= каталог комплекту) і ніколи не прибирався. BRAVO ці
  метадані не використовує (контекст `NOWRITERS`): тепер `SET METADATA`
  вказує в TEMP, файл видаляється у finally разом зі сценарієм, а
  наявні legacy-.cab цього хоста в каталозі комплекту best-effort
  зачищаються перед створенням набору. Контракт
  `BackupConsistency/VSSDiskshadowMetadataGoesToTempAndIsCleaned`.

Acceptance rc.4 (додатково до rc.3): після багатотомної архівації в
каталозі комплекту немає нових `*_--_*.cab`, старі зникли.

---

## 5.2.1-rc.3 — 2026-08-26 (hotfix candidate, NOT accepted — superseded by rc.4)

Кандидат = rc.2 + одноразова міграція legacy-розкладки архівів MODEL
(запит власника: старі сервери ARCHIV_LIMS-ери тримають архіви у
`<BackupRoot>\ARCHIV\LIMS` локально і в `archiv` на SFTP):

- **FEATURE (maintenance): міграція legacy-архівів MODEL.** Щонічний
  Maintenance best-effort переносить вміст `<BackupRoot>\ARCHIV\LIMS` →
  `<BackupRoot>\MODEL` (пофайлово, без перезаписів/видалень; колізія
  імені — WARNING, старий файл лишається; спорожнілі `LIMS` і батько
  `ARCHIV` прибираються) і `archiv` → `model` на SFTP (канонічний
  механізм trace-міграції, `.mdz`/`.sha512`; колізія — WARNING без
  критичного статусу). Idempotent: після повного переносу — no-op.

Acceptance rc.3 (додатково до сценаріїв rc.2): на legacy-сервері після
нічного Maintenance — архіви з `ARCHIV\LIMS` у `MODEL`, з `archiv` у
`model`; порожні legacy-каталоги зникли; retention/Health бачать повну
історію.

---

## 5.2.1-rc.2 — 2026-08-26 (hotfix candidate, NOT accepted — superseded by rc.3)

Hotfix-кандидат лінії 5.2.x = rc.1 + другий операторський фікс,
відтворений власником на тому самому сервері (Тернопіль):

- **FIX (dry-run, операторський UX):** тестове повідомлення
  `-SendTestNotification` надходило в ALERTS замість GENERAL —
  порядок резолвінгу маршрутів у `Test-DryRunWebhookCredential` клав
  ALERTS-webhook у слот надсилання. Тепер `('general','alerts')`:
  SUCCESS-семантика тесту → GENERAL; fallback на legacy provider-wide
  webhook/alerts збережено; `BRAVO_SETUP` і `BRAVO_TASKS_DIAGNOSE`
  успадковують (шлють через dry-run). Той самий фікс уже в лінії 5.3.0
  (developer); сюди перенесений cherry-pick-ом.

Acceptance rc.2: обидва сценарії — (1) денний ручний прогін
`BRAVO_MAINTENANCE.ps1` поза вікном → УСПІШНО/exit 0, SUCCESS у
GENERAL, рядок пропуску `[INFO]`; (2) `BRAVO_DRY_RUN.ps1 -TestAccess
-SendTestNotification` → тестове повідомлення в GENERAL.

---

## 5.2.1-rc.1 — 2026-08-26 (hotfix candidate, NOT accepted — superseded by rc.2)

Hotfix-кандидат лінії 5.2.x (гілка `hotfix/5.2.1` від stable 5.2.0).
На перевірці rc.1 власник відтворив другу хибну маршрутизацію (dry-run
тест в ALERTS) — кандидата одразу замінено rc.2 вище. Одна вузька зміна:

- **FIX (maintenance, операторський UX):** «Реставрацію пропущено: ...
  поза дозволеним вікном» — рівень WARNING → INFO (реальний денний
  ручний прогін ТЕРНОПІЛЬСЬКА РДЛ 2026-08-26: хибний алерт
  «ПОТРІБНА ДІЯ» з exit 10 при повністю зеленому прогоні; рішення
  власника — це штатна поведінка, слот не втрачається: підхоплюється
  нічним Maintenance у вікні або boot-Recovery). Текст у лозі доповнено
  поясненням про автоматичне підхоплення. Розсинхрон конфігурації, за
  якого слот справді не виконався б, і далі дає окреме попередження
  (`maintenanceDailyAtInsideRestoreWindow`). Той самий клас, що вже
  виправлена в 5.2.0 гілка `-ForceRestore` поза вікном.

Acceptance: ручний денний прогін `BRAVO_MAINTENANCE.ps1` поза вікном →
консоль/алерт УСПІШНО (SUCCESS у GENERAL), exit 0, рядок про пропуск —
`[INFO]` у журналі.

Після прийняття той самий фікс синхронізується в `developer`
(лінія 5.3.0) — обов'язкова синхронізація hotfix, RELEASE_POLICY §12.2.

---

## 5.2.0 — 2026-08-26

Stable release of the 5.2.0 line, promoted (metadata-only) from the
accepted 5.2.0-rc.13 candidate: rc stamp `0247ac3` (sourceCommit
`12e6370`), artifact BRAVO-Toolkit-5.2.0-rc.13.zip sha256
`6eac9695ed6053e7156ff843d8b4aed8522b4627d65c95bace1bc3de5a42af22`.

Real-server acceptance rc.13: PASS 2026-08-26 (`LIMS`/ДНДІЛДВСЕ —
повний maintenance-цикл з реставрацією, logs pipeline v2, компактні
алерти, негативний сценарій forced+normal без повторної реставрації)
плюс A2-encoding протокол (RELEASE_CHECKLIST §1.1) PASS в обох
консольних контекстах (інтерактивно CP65001, SYSTEM CP866). Зведений
evidence: `docs/BRAVO_520_RC13_ACCEPTANCE_EVIDENCE_20260826.md`
(PR #100). Ланцюг кандидатів циклу: rc.8 (ACCEPTED, restore) →
rc.9–rc.12 (замінені без окремого acceptance) → rc.13 (фінальний).

Дерево stable додатково до rc.13 містить лише non-runtime зміни:
acceptance-evidence документ (PR #100) і governance-hardening
(PR #101, нижче) — runtime functional diff проти прийнятого rc.13
порожній.

- **GOVERNANCE (release process, P0): repository identity у гейті
  промоції master + branch protection.** `ci\Test-BRAVOMasterMergePolicy.ps1`
  тепер перевіряє не лише ім'я head-гілки (`developer`/`hotfix/*`), а й
  repository identity джерела PR (екстрагована `Test-BRAVOMasterMergeSource`:
  head-репозиторій мусить збігатися з base; fork з однойменною гілкою —
  FAIL; невизначений head-репозиторій — fail-closed FAIL). Identity
  береться з `GITHUB_EVENT_PATH` (`pull_request.head.repo.full_name`) /
  `GITHUB_REPOSITORY`; нові параметри `-HeadRepository`/`-BaseRepository`
  для локального запуску. Регресії в
  `selftest\BRAVO_SELF_TEST.Governance.ps1`: 8 сценаріїв джерела
  (same/fork/feature/unknown) + 2 додаткові версійні
  (`5.2.1>5.2.0`, `5.3.0>5.2.9`). Фактичний GitHub-стан приведено до
  політики: branch protection увімкнено для `developer` (PR-only, ті
  самі required checks, що на `master`, заборона force push/видалення,
  `enforce_admins`); документацію (`RELEASE_POLICY.md` §13,
  `RELEASE_CHECKLIST.md`, `ROADMAP.md` P0.2) синхронізовано з фактичним
  станом — застарілі твердження «branch protection потребує GitHub Pro»
  прибрано (репозиторій публічний). Runtime-код не змінювався.

---

## 5.2.0-rc.13 — 2026-08-26 (candidate, ACCEPTED 2026-08-26 — released as 5.2.0)

Фінальний кандидат циклу 5.2.0 перед stable. Кандидат = `5.2.0-rc.12`
(нижче; на acceptance зафіксовано UX-зауваження до прогресу
реставрації — закрито UX-фіксом нижче, PR #98). Acceptance rc.13
покриває всю накопичену нову поверхню rc.9-rc.13.

- **UX (operator console, maintenance): підетапи у прогресі тривалих
  native-операцій + назва моделі без прив'язки до продукту.** Звіт
  оператора з acceptance rc.12: 19-хвилинний крок «Реставрація моделі»
  показував один суцільний підстатус «Виконується N сек.» без розбивки
  на фази (архівація до ~7 хв → bravocmd ~5 хв → архівація після
  ~7 хв). Polling-цикл `Invoke-CommandWithLog` тепер включає
  `-Description` операції у running-рядок: «Реставрація моделі —
  Архівація моделі перед реставрацією — Виконується 7 сек.» — це
  автоматично охоплює всі native-виклики Maintenance. Опис
  bravocmd-фази змінено з «Виконання реставрації моделі LIMS» на
  «Виконання реставрації моделі (<ім'я проєкту>)»: проєкт моделі може
  бути будь-яким (ім'я деривується з `bravo.ini MODEL=`), суфікс
  продукту прибрано. Регресія
  `RestoreSynthetic/InvokeCommandWithLogEmitsRunningDetail` оновлена
  під формат «<Опис> — Виконується …».

---

## 5.2.0-rc.12 — 2026-08-26 (candidate, pending acceptance)

Фінальний кандидат циклу 5.2.0 перед stable. Кандидат = `5.2.0-rc.11`
(нижче; на acceptance 2026-08-26 виявлено дефект подвійної реставрації
після `-ForceRestore` — виправлено FIX-ом нижче, PR #96). Acceptance
rc.12 покриває всю накопичену нову поверхню rc.9-rc.12: повний
maintenance-цикл (скан усіх `*.out`, exchangAPI-mdz, автостворення
`logs/*`, WinSCP MoveFile-міграція `trace/`), компактні алерти,
відсутність повторної реставрації після forced+normal в один вечір +
A2-encoding протокол (RELEASE_CHECKLIST §1.1).

- **FIX (maintenance, restore scheduling): подвійна реставрація після
  `-ForceRestore` в один вечір.** Реальний інцидент (2026-08-26,
  acceptance rc.11): успішна примусова реставрація, а наступний
  ЗВИЧАЙНИЙ прогін того ж вечора запустив реставрацію вдруге. Причина:
  успішний `-ForceRestore` свідомо не закриває плановий слот
  маркером/Status (це за автоматичним шляхом) і записує квоту як
  ПОКРИТИЙ НАСТУПНИЙ слот (+7 днів), а перевірка квоти порівнювала
  покритий слот із поточним СТРОГОЮ РІВНІСТЮ — «пропущений» МИНУЛИЙ
  слот (менший за покритий) лишався незадоволеним і тригерив
  missed-гілку повторної реставрації у відкритому вікні.

  Фікс: нова `Test-BRAVORestoreWeeklyQuotaConsumed` — квота спожита,
  коли поточний слот **<=** покритого (закриває і пропущений минулий,
  і сам покритий); наступний слот (+7 днів) строго більший — квота
  знімається рівно вчасно, без межової помилки арифметики
  «різниця < 7 діб». Семантика «-ForceRestore не обмежений квотою» і
  «forced не закриває плановий слот» не змінені; даних інцидент не
  зачепив (друга реставрація пройшла повний безпечний ланцюг —
  лише зайвий downtime).

  Регресія: `Maintenance/WeeklyQuotaConsumed[MissedPastSlotCovered
  (incident)/CoveredSlotItself/NextWeekSlotNotCovered/
  LegacyStateWithoutQuota]` — реальна функція через AST-екстракцію в
  наявному quota-harness.

---

## 5.2.0-rc.11 — 2026-08-26 (candidate, pending acceptance)

Фінальний кандидат циклу 5.2.0 перед stable. Кандидат = `5.2.0-rc.10`
(нижче; acceptance не проводився — одразу замінено цим кандидатом) +
компактні Maintenance-алерти з глобальним payload guard-ом (PR #94,
нижче). Acceptance rc.11 покриває всю накопичену нову поверхню
rc.9-rc.11: повний maintenance-цикл (скан усіх `*.out`, exchangAPI-mdz,
автостворення `logs/*`, WinSCP MoveFile-міграція `trace/`), компактні
алерти + A2-encoding протокол (RELEASE_CHECKLIST §1.1).

- **UX (operator notifications): компактні Maintenance-алерти + глобальний
  payload guard.** Реальний клас інциденту: сотні critical-файлів після
  перевірки реставрації давали alert на 4×N рядків (341 файл ≈ 55 тис.
  символів), який Discord дробив на серію повідомлень, а Slack (без
  chunking взагалі) міг відхилити цілком — транспорт фактично працював
  переглядачем журналу.
  - Розділені представлення у трьох Maintenance-сайтах
    (`Compare-FileSizes` critical-файли; пороги діапазонів ID; великі
    `.md`): повна діагностика (4 рядки/файл, УСІ елементи) — як і раніше
    лише у `BRAVO_MAINTENANCE_*.log`; операторський alert — загальна
    кількість + до 5 прикладів (один файл = один короткий рядок; missing
    і редукція розрізняються зі structured-полів: «файл відсутній (було
    X)» / «X → Y (-Z%)») + «…і ще N» + вказівка на журнал. Семантика
    виявлення/severity/rollback не змінена.
  - Новий канонічний `Format-BRAVONotificationListSummary`
    (`BRAVO.Notifications`): «Приклади: • … …і ще N файл(ів).»;
    константа максимуму прикладів (5) — в одному місці; «…і ще 0»
    структурно неможливе.
  - Новий `Limit-BRAVONotificationPayload` + вбудова в
    `ConvertTo-BRAVONotificationPayloadText`: транспорт-агностичний safe
    limit 1800 символів (свідомо менший за фізичні ліміти
    Discord-chunk 1900/Slack) — «одна подія → одне повідомлення» на обох
    транспортах; обрізання по межі рядка, явний suffix «⚠️ Повідомлення
    скорочено…», рядок журналу (`:memo:`/`📝`) зберігається після
    suffix; факт truncation логуються Write-Warning з
    Original/FinalLength (без секретів). Discord-split лишається
    defense-in-depth під guard-лімітом; business-logic Maintenance
    транспортних лімітів не знає.

  Регресії (pre-fix RED продемонстровано: старий alert 341 файла =
  55 308 символів): `Maintenance/CompactAlert341FilesOneNotificationFullLog`
  (рівно 1 alert <1800, «…і ще 336 файлів.», повний список у лозі),
  `CompactAlertThreeFilesShowsAllNoRemainder`,
  `CompactAlertSixFilesShowsFivePlusRemainder`,
  `CompactAlertDistinguishesMissingVsReduction`,
  `CompactAlertHandlesUnicodeAndNestedPaths` (`#\`, кирилиця, пробіли);
  `Notifications/ListSummaryCountsAndRemainder`,
  `ListSummaryHandlesUnicodeAndPaths`,
  `PayloadGuardTruncatesSlackToSingleMessage`,
  `PayloadGuardYieldsSingleDiscordChunk`,
  `PayloadGuardLeavesSmallMessagesUntouched`;
  `DiscordChunkingStillWorks` збережено як defense-in-depth-юніт.

---

## 5.2.0-rc.10 — 2026-08-25 (candidate, pending acceptance)

Фінальний кандидат циклу 5.2.0 перед stable. Кандидат = `5.2.0-rc.9`
(нижче; acceptance rc.9 не проводився — одразу замінено цим кандидатом)
+ ci-hardening промоції (PR #92) + актуалізація release-документації
(PR #91). Acceptance rc.10 покриває всю нову поверхню rc.9/rc.10:
повний maintenance-цикл (скан усіх `*.out`, exchangAPI-mdz,
автостворення `logs/*`, WinSCP MoveFile-міграція `trace/`) +
A2-encoding протокол (RELEASE_CHECKLIST §1.1).

- **CI (release governance, підготовка до 5.2.0 stable): семантичний
  гейт версії промоції + виключення artifacts\ з генератора маніфесту.**
  - `ci/Test-BRAVOMasterMergePolicy.ps1`: нова
    `Test-BRAVOStableVersionPromotion` — PR у `master` приймається лише
    зі STABLE-версією `X.Y.Z` (prerelease-суфікс = порушення) і лише
    коли вона семантично БІЛЬША за поточну master-версію
    (`[version]`-порівняння; стара перевірка «нерівність рядків»
    пропускала downgrade і prerelease — ROADMAP P0.2). Нечитабельний
    master-VERSION.json — fail-closed.
  - `ci/Update-BRAVORuntimeManifest.ps1`: каталог `artifacts\` додано у
    виключення enumeration. Збірник артефакту навмисно лишає
    `artifacts\release\staging` (повну копію комплекту для self-test), і
    `-Apply` після локальної збірки вносив у маніфест ~85 дублікатів
    staging-файлів, яких немає на сервері → RUNTIME_GUARD exit 33
    (двічі спіймано в циклі 5.2.0-rc — раніше рятувало лише ручне
    видалення staging перед перерахунком).

  Регресії: `ReleasePolicy/StableVersionPromotion[7 сценаріїв]`
  (справжня функція з ci-скрипта через AST-екстракцію: genuine increase,
  семантичне-не-лексичне 5.10>5.9, prerelease/same/downgrade/
  unparsable-master — відхилені) і
  `ReleasePolicy/RuntimeManifestGeneratorExcludesArtifacts`.

---

## 5.2.0-rc.9 — 2026-08-25 (candidate, pending acceptance)

Кандидат = прийнятий `5.2.0-rc.8` (нижче; acceptance реставрації пройдено
на сервері інциденту) + logs pipeline v2 (PR #89) + живий підстатус
консолі Maintenance (PR #88). Обидві зміни потребують real-server
acceptance: нові SFTP-каталоги `logs/*`, WinSCP MoveFile-міграція,
повний maintenance-цикл із реальними `*.out`-варіантами.

- **FEATURE (operations, logs pipeline v2): усі `*.out` за прохід,
  exchangAPI-архіви на SFTP, нова структура `logs/`.** Запит власника за
  лістингом реального сервера: у корені інсталяції накопичуються
  `!TraceSRV.out` (214MB), `traceBIS1.out`, `TraceSRV2.out` тощо, які
  модель «два налаштовані файли» ніколи не підбирала; exchangAPI-логи
  перейменовувались у `exchangAPI_N.log` і не потрапляли на SFTP.

  **Свідомі зміни поведінки (рішення власника):**
  - Ротація trace тепер захоплює **кожен `*.out` з кореня інсталяції
    bravo.exe** (нова `Get-BRAVOInstallationTraceOutSources`: Discovery
    `BRAVO_ROOT`, фолбек LIMSRoot; SRV з `bravo.ini` і явний
    `Trace.BISSourcePath` — додаткові джерела, якщо поза коренем; дедуп
    шляхів OrdinalIgnoreCase; порожній/`'off'` BISSourcePath = нічого
    додаткового). Backlog добового архіву узагальнено до довільних
    basename (`^(.+)_(\d{8})_(\d{6})\.out$`); legacy-імена як і раніше
    не чіпаються.
  - **exchangAPI: оригінальні імена без перейменувань** (нова
    `NamingPolicy 'Original'` у спільному рушії ротації; колізія імені в
    призначенні = ПОМИЛКА fail-closed, джерело лишається). Плоске
    призначення `LOGS\exchangAPI` без каталогів-дат; добовий
    `exchangAPI_YYYYMMDD.mdz` тим САМИМ движком, що Trace
    (`Invoke-BRAVOTraceArchiveMaintenance` параметризовано:
    ComponentLabel/ArchiveNamePrefix/GroupBy=ByLastWriteTime/FileFilter),
    з тим самим ланцюгом 7z t → SHA512 → SFTP → видалення джерел лише
    після повної верифікації.
  - **SFTP-структура:** нові каталоги `sftpDirectories.TraceLogs`
    (`logs/trace`) і `sftpDirectories.ExchangeApiLogs`
    (`logs/exchangapi`); compat — legacy-конфіги без ключів отримують
    дефолти в лоадері. Наявні архіви зі старого `trace/` **одноразово
    (idempotent) мігруються** remote-move'ом з верифікацією
    (`Invoke-BRAVOTraceRemoteLogMigration`): без видалень, конфлікт
    імені = ERROR без перезапису, помилки видимі й не блокують нові
    передачі.

  Регресії: `LogRotation/09c-09e` (скан кореня, фолбек/дедуп/колізія
  basename, Original-політика), оновлені `11/12/20` під новий
  exchangAPI-контракт (колізія fail-closed),
  `TraceArchive/BacklogAcceptsArbitraryRotatedBasenames`,
  `BacklogGroupsExchangeLogsByLastWriteDate`,
  `ExchangeApiDailyArchivePipelineEndToEnd` (справжній 7za + fake SFTP),
  `RemoteMigration*` (успіх/конфлікт/no-op). Повний `BRAVO_SELF_TEST.ps1`
  PASSED. Потрібен real-server acceptance (нові SFTP-каталоги, WinSCP
  MoveFile-міграція, повний maintenance-цикл).

- **UX (operator console, maintenance): живий підстатус тривалих
  native-операцій.** Звіт оператора: під час реставрації моделі
  прогрес-смуга `BRAVO_MAINTENANCE` стояла без жодного підстатусу —
  `Invoke-CommandWithLog` блокувався в суцільному `WaitForExit(timeout)`
  на весь час роботи bravocmd/7-Zip. Тепер очікування — polling кожні
  500 мс з оновленням прогресу канонічним running-рядком `BRAVO.Console`
  (`<Фаза> — Виконується N сек.`, `Format-BRAVORunningDetail` — той
  самий, що в Archive), після завершення detail скидається. Охоплює всі
  native-виклики Maintenance через `Invoke-CommandWithLog`: реставрацію
  bravocmd і 7-Zip архівації до/після. Сумарний таймаут і kill-семантика
  не змінені. Регресія:
  `RestoreSynthetic/InvokeCommandWithLogEmitsRunningDetail` (червоний до
  зміни: `ticks=0`; зелений після).

---

## 5.2.0-rc.8 — 2026-08-25 (candidate, acceptance passed)

**UPD (2026-08-25 22:03-22:24): real-server acceptance реставрації
ПРОЙДЕНО на сервері інциденту** (`LIMS`/ДНДІЛДВСЕ, `BRAVO_MAINTENANCE
-ForceRestore`): `[5/8] Реставрація моделі OK 19:22 — bravocmd exit=0 |
RemovedByRepair=0 | Critical=0 | Rollback=NONE | MainModel=OK`; фінал
УСПІШНО/exit 0, служби відновлено автоматично, Trace-pipeline (добовий
архів + SFTP) теж пройшов. Днем раніше той самий сервер на rc.7-коді
давав 364 хибні «критичні зміни» і rollback=FAILED (exit 43).

Кандидат = зміст прийнятого `v5.2.0-rc.7` (`5.2.0-rc.5` + розрахункова
перевірка вільного місця з floor-override; повний end-to-end acceptance
2026-08-25 на `WIN-42Q5558LQC9`) + `fix(maintenance)` нижче (PR #86).
Перший формальний build із гілки `developer` після злиття PR #83/#84:
rc.6/rc.7 збирались з інтеграційної гілки `rc6-merge`, функціональний
runtime-diff `developer` проти `v5.2.0-rc.7` до PR #86 був порожній.
FEATURE-запис про розрахункову перевірку місця (нижче) вже пройшов
acceptance у складі rc.7; новий у цьому кандидаті — лише FIX.

- **FIX (data-integrity, restore/maintenance): хибний тотальний провал
  перевірки цілісності моделі після repair через регістр шляху MODEL.**
  Реальний інцидент (ДНДІЛДВСЕ, 2026-08-25, exit 43): `bravocmd r`
  завершується успішно, але `Compare-FileSizes` оголошував УСІ файли
  before-CSV відсутніми (364 CRITICAL + 182 RemovedByRepair) і після
  успішного відкату повторна перевірка знову провалювалась —
  `rollback=FAILED`, служби не піднімались, хоча дані на диску цілі.
  Причина: `bravo.ini MODEL=` на сервері містить шлях з іншим регістром
  (мала літера диска, `d:\LIMS\Model`), before-CSV пишеться через .NET
  `EnumerateFiles` (зберігає регістр переданого кореня), а поточний вміст
  читається через `Get-BRAVOFiles`/`Get-ChildItem` (провайдер нормалізує
  `D:\...`); ordinal `String.Replace` не зрізав корінь — ключі порівняння
  ставали абсолютними шляхами і не збігались із відносними записами CSV.

  Виправлення: нова канонічна `Get-BRAVOModelRelativePath`
  (`modules/BRAVO.Maintenance/BRAVO.Maintenance.Runtime.ps1`) —
  регістронезалежний (OrdinalIgnoreCase, культуро-незалежний) зріз кореня;
  мігровано всі 5 місць патерну `FullName.Replace($MODEL_PATH...)` (lookup
  у `Compare-FileSizes` — сам баг; writer before-CSV, деривація hint
  головної моделі, два місця `Check-MdFileSizes` — hardening того самого
  патерну). Fail-closed поведінка не послаблена: шлях поза коренем
  повертається як є і, як і раніше, не зіставляється. Додатковий
  діагностичний tripwire: якщо жоден запис before-CSV не зіставився, а
  каталог MODEL не порожній — явний ERROR про ймовірний розсинхрон
  деривації шляхів (корінь/регістр), а не «втрату даних»; блокування і
  rollback лишаються незмінними.

  Регресія: `Maintenance/CompareFileSizesRootCaseInsensitive`,
  `Maintenance/CompareFileSizesRootCaseInsensitiveSegmentRemoved`
  (той самий каталог, змінений лише регістр рядка ModelPath) — червоні до
  фіксу, зелені після; `Maintenance/ModelRelativePath[...]` — юніт-контракт
  helper'а (регістр, підкаталог, точний збіг, поза коренем, межа
  компонента `Model` vs `ModelBackup`). Повний `BRAVO_SELF_TEST.ps1`
  PASSED. Потрібен real-server acceptance реставрації саме на сервері
  інциденту (Task Scheduler + bravocmd) — CI його не замінює.

- **FEATURE (data-integrity, archive preflight): розрахункова перевірка
  вільного місця понад фіксований поріг.** `Maintenance.Limits.
  MinimumFreeSpaceGB` (типово 20) — загальний захист від переповнення
  диска ОС на КОЖНОМУ локальному Fixed-диску, не оцінка того, скільки
  місця реально потребує НАЙБЛИЖЧИЙ backup. Джерела MODEL/BLOG/BRAVOEXCH
  ростуть з часом: сервер може мати вільного місця більше за фіксований
  поріг, але менше, ніж потрібно для нового архіву — 7-Zip/VSS падає
  посеред роботи, хоча стара preflight-перевірка проходила `OK`.

  Новий `Get-BRAVOArchiveEstimatedSpaceRequirement`
  (`modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1`), викликається в
  тому самому кроці "Перевірка вільного місця" одразу після фіксованого
  порогу: для кожного увімкненого компонента бере розмір ОСТАННЬОГО
  hash-підтвердженого валідного архіву (`Get-BRAVOValidArchiveSizeHistory`,
  `BRAVO.ArchiveHelpers` — той самий канонічний reader, що вже
  використовує `SizeSanity` для виявлення підозріло малих архівів) і
  додає запас на зростання (`Maintenance.Limits.
  EstimatedSpaceMarginPercent`, типово 25%). Компоненти на тому самому
  фізичному диску сумуються в один розрахунок (інакше можна двічі
  "витратити" те саме вільне місце). Компонент без валідної історії
  (перший запуск, bootstrap) свідомо пропускається з оцінки — не блокує
  прогін.

  `EstimatedSpaceMarginPercent` — опційний ключ (compat: старі
  `BRAVO.config` без нього отримують дефолт `25` у коді завантаження,
  не лише в шаблоні файлу).

  **UPD (2026-08-25, реальний acceptance):** оператор зафіксував
  протилежний до початкового сценарій — сервер із `19.38 GB` вільних
  проти фіксованого порогу `20 GB` блокував архівацію, хоча розрахункова
  потреба для MODEL/BLOG/BRAVOEXCH становила лише `0.2 GB`. Новий
  `Merge-BRAVOArchiveSpaceCheckResults` тепер знижує провал фіксованого
  порогу до `WARNING` (не блокує), коли розрахункова оцінка для ТОГО
  САМОГО диска реально порахована і показує достатність. Виправдання —
  строго по-диску: інший диск без жодного оціненого компонента
  (bootstrap чи взагалі не бере участі в backup) лишається під
  фіксованим порогом без послаблень, а недостатність за самою
  розрахунковою оцінкою й далі блокує незалежно від floor-статусу.

  Новий self-test: `Archive/EstimatedSpaceUsesLastValidArchiveHistoryPlusMargin`,
  `Archive/EstimatedSpaceFailsWhenBelowRequirement`,
  `Archive/EstimatedSpaceSkipsComponentWithoutHistory`,
  `Archive/EstimatedSpaceGroupsComponentsOnSameDrive`,
  `Archive/MergeSpaceResultsOverridesFloorWhenEstimateCoversDrive`,
  `Archive/MergeSpaceResultsKeepsFloorBlockingWithoutEstimate`,
  `Archive/MergeSpaceResultsKeepsFloorBlockingWhenEstimateAlsoInsufficient`,
  `Archive/MergeSpaceResultsEstimatedFailureBlocksEvenWhenFloorPasses`,
  `Archive/MergeSpaceResultsAppliesOverridePerDriveIndependently`,
  `Archive/EstimatedSpacePreflightWiredIntoFreeSpaceCheck`. Регресію
  підтверджено вручну двічі (спершу запас/групування, потім сама
  override-умова тимчасово прибиралися з коду — щоразу відповідні тести
  почервоніли, решта лишились зеленими; відновлено).

---

## 5.2.0-rc.5 — 2026-08-25 (candidate, acceptance passed)

Кандидат = `5.2.0-rc.4` (нижче) + три cherry-picked фікси з локальної гілки
`developer`, перевірені на відсутність дублювання з уже прийнятими
origin-змінами. Acceptance пройдено на двох реальних серверах:
`SERV_HRDL_1` (ХЕРСОНСЬКА РДЛ, rc.4) і `WIN-44OBNQ3R3OB` (МИКОЛАЇВСЬКА
РДЛ, rc.5) — повний `BRAVO_SELF_TEST.ps1` PASSED, `BRAVO_DRY_RUN.ps1
-TestAccess` без жодного FAIL, `BRAVO_TASKS_INSTALL.ps1 -ValidateOnly`
успішний.

- **UX/DIAGNOSTICS: діагностичне збагачення помилки завантаження
  `BRAVO.config`.** На реальному DEV-майданчику (2026-08-24, Windows NT
  6.2.9200 / PowerShell 3.0 — `Get-BRAVOOSSupportTier` класифікує
  PowerShell <4.0 як `Unsupported` незалежно від ОС) виконання
  `BRAVO.config` під час `Import-BravoConfiguration` завершувалось голою
  `.NET NullReferenceException` ("Ссылка на объект не указывает на
  экземпляр объекта") без жодного натяку на причину — блокувало
  `BRAVO_SETUP.ps1`, `BRAVO_SELF_TEST.ps1` і `BRAVO_DRY_RUN.ps1`
  однаково (усі entrypoint-и зрештою проходять через ту саму спільну
  точку завантаження конфігурації). `Get-BRAVOOSSupportTier`
  (`BRAVO.Compatibility`) — уже канонічне джерело цієї класифікації
  (використовують `Maintenance`/`Health`/`Archive`), але викликається
  лише ПІСЛЯ успішного завантаження конфігурації — тобто жодного шансу
  спрацювати раніше за цей крах не було. `Import-BravoConfiguration`
  тепер, лише в catch-блоці навколо виконання `BRAVO.config`, викликає
  той самий канонічний `Get-BRAVOOSSupportTier` і за наявності
  непідтримуваного середовища додає його `.Message` до кинутої помилки —
  оригінальна причина ніколи не губиться, і збагачення саме не може
  замаскувати первинну помилку новою (мовчазний fallback, якщо модуль
  `BRAVO.Compatibility` теж недоступний). На `Supported`-середовищах
  повідомлення не змінюється. Backport сумісності з PowerShell 3.0 НЕ
  виконано (нижче задокументованого baseline 5.1) — рекомендація й далі
  «оновіть Windows Management Framework».

- **FIX (data-integrity discovery): службу BRAVO з DisplayName="BRAVO
  Server" не визнавали канонічною.** Реальний DEV-майданчик
  (2026-08-24): служба Windows `BRAVO` встановлена й запущена
  (`Get-Service BRAVO` -> `Running`), але `Import-BravoConfiguration`
  усе одно падав на "Не вдалося визначити BackupRoot: ... вимагає
  визначеного EffectiveLIMSRoot". Причина — `DisplayName` реальної
  служби виявився `"BRAVO Server"`, тоді як Discovery (навмисний
  строгий захист від хибного співставлення із чужим сервісом: Name ТА
  DisplayName одночасно) очікував рівно `"BRAVO Service"`. Обидва
  написання — реальні варіанти інсталяторів BRAVO/LIMS, не помилка
  цього конкретного сервера. `Resolve-BRAVOEffectiveLimsRoot` і
  `Resolve-BRAVOInstallationDiscovery` тепер приймають `-BravoDisplayName`
  як масив (дефолт `@("BRAVO Service", "BRAVO Server")`) — точний збіг
  з БУДЬ-ЯКИМ значенням зі списку, а не одне жорстко задане значення.
  Це НЕ послаблення identity-перевірки: збіг і далі точний
  (case-insensitive `-eq`, не substring/regex/wildcard), просто список
  канонічних варіантів написання розширено з одного до двох.
  `maintenanceSettings.Services.BravoDisplayName` у `BRAVO.config` —
  тепер `@("BRAVO Service", "BRAVO Server")`; якщо на вашому сервері
  DisplayName служби інший за обидва — додайте третім елементом
  (перевірте `Get-Service BRAVO | Select DisplayName`), не замінюйте
  список. Новий self-test:
  `Discovery/BravoServerDisplayNameAcceptedAsCanonical` і
  `Paths/01b-AutoLimsRootFromServiceBravoServerDisplayName`.

- **FIX: `BRAVO_DRY_RUN.ps1` падав удруге, ховаючи первинну причину.**
  Реальний DEV-майданчик (2026-08-24): після коректно спійманої "Не
  вдалося завантажити BRAVO.config" (єдиний try/catch dry-run, вище)
  `Write-DryRunOutput` мала намалювати звичайний `[FAIL] Dry-run/
  Фатальна помилка` — але замість цього процес падав із `Переменная
  "$global:ScriptVersion" не может быть получена, так как она не
  установлена` (`VariableIsUndefined`), ховаючи вже сформований,
  зрозумілий діагноз за новою незрозумілою помилкою.
  `BRAVO_CONFIG_LOADER.ps1` (dot-sourced) вмикає `Set-StrictMode
  -Version 2.0` у ТОМУ Ж scope (dot-source зливає scope викликача) —
  якщо `Import-BravoConfiguration` провалюється ДО рядка, що створює
  `$global:ScriptVersion`, змінна не існує взагалі (не `$null`), і
  `if ($global:ScriptVersion)` під strict mode кидає
  `VariableIsUndefined` навіть у такому "безпечному" контексті. Сусідній
  рядок для `$bravoSettings` уже коректно захищений через `Get-Variable
  -ErrorAction SilentlyContinue` — `$global:ScriptVersion` використовував
  інший, вразливий патерн. Виправлено тим самим захищеним патерном.
  Новий self-test `ConfigLoader/DryRunFailsClosedOnConfigLoadFailure` +
  `ConfigLoader/DryRunDoesNotCrashOnUnsetScriptVersion` — реальний
  дочірній процес `BRAVO_DRY_RUN.ps1` із синтетично провальним
  `BRAVO.config`.

- FIX (ci): `ci\Test-BRAVOForbiddenPattern.ps1` не мав у allowlist
  `BRAVO_SELF_TEST.ConfigLoader.ps1` для навмисного ізольованого
  дочірнього `powershell.exe -ExecutionPolicy Bypass` (той самий патерн,
  що вже allowlisted для `Governance.ps1`/`ManualLaunchers.ps1`) —
  виявлено CI на PR #83, не при первинному локальному коміті фіксу.

## 5.2.0-rc.4 — 2026-08-24 (candidate, acceptance passed)

- FIX (реліз-автоматизація): `release-artifact` workflow створював чернетку
  релізу для dev/RC **без прапорця `--prerelease`**
  (`.github/workflows/release-artifact.yml`, крок «Прикріплення до GitHub
  Release»). Через це кандидат публікувався як звичайний реліз і ставав
  «Latest release» — тобто оператор, який заходить по останню версію, бачив
  би неприйнятий RC замість stable. Це прямо суперечить `RELEASE_POLICY.md`
  розділ 16 (dev/RC → `Pre-release: true`, `Latest release: false`).
  Виявлено на чернетці `v5.2.0-rc.1`, яка досі висить із `prerelease: false`.

  Тег тепер класифікується за суфіксом (`-dev.` / `-rc.`), і для таких
  релізів додається `--prerelease`. Прапорець виставляється і наявному
  релізу через `gh release edit`, бо чернетка могла бути створена ще до
  цього фіксу або вручну. `--latest=false` свідомо НЕ використовується:
  GitHub і так виключає pre-release із Latest, а цей прапорець підтримують
  не всі версії `gh` — зайва несумісність зламала б workflow сильніше, ніж
  початковий дефект.

  Ремонт наявного релізу виконується ПЕРЕД вивантаженням асетів, а саме
  вивантаження отримало `--clobber`. Інакше шлях ремонту не працював би саме
  там, де потрібен: реліз, створений попереднім прогоном, уже несе ті самі
  три асети, тому `gh release upload` падає і крок завершується ще до
  `gh release edit`. Заміна асетів безпечна — до цього кроку доходить лише
  артефакт, що пройшов обидва integrity-маніфести, `BRAVO_RUNTIME_GUARD` і
  повний self-test.

  Self-тест `Release/ArtifactWorkflowMarksPrerelease` — перший у репозиторії
  тест на вміст workflow; він фіксує і прапорець, і порядок кроків.
  Перевірено регресійно: на коді до фіксу падає.

- **TESTING: `ManualLaunchers/*` self-test падав на кириличних Windows-
  установках.** Реальний DEV-майданчик (2026-08-24, обліковий запис
  "Администратор") показав `[FAIL] Manual launcher не підтримує не-ASCII
  шлях: ...\AppData\Local\Temp\...` — фікстура будувала свій тимчасовий
  корінь через `[IO.Path]::GetTempPath()` (`%TEMP%`), який на
  локалізованих Windows-установках наслідує кириличне імʼя профілю
  користувача. `New-BRAVOManualLauncherContent` (`BRAVO_SETUP.ps1`)
  навмисно й коректно відхиляє не-ASCII шляхи (відомі проблеми
  кодування `cmd.exe` для `.cmd`-launcher-ів) — сама production-логіка
  тут без дефекту, проблема лише в тому, що self-test-фікстура
  успадковувала не-ASCII базовий шлях НЕ навмисно, ламаючи навіть
  сценарії, які не мають нічого спільного з ASCII-перевіркою. Виправлено:
  фікстура тепер визначає, чи `%TEMP%` не-ASCII, і в такому разі
  використовує `%SystemRoot%\Temp` (не залежить від локалізованого
  імені користувача) — той самий явний, навмисний non-ASCII-сценарій
  (`ManualLaunchers/NonAsciiEmbeddedPathFailsClosed`) і далі перевіряє
  реальне відхилення, лише тепер від контрольованого ASCII-базису.
  Впливає лише на self-test; жодної зміни production-коду чи політики
  ASCII-перевірки launcher-ів.

---

## 5.2.0-rc.3 — 2026-08-24 (candidate, pending acceptance)

Кандидат зі стабілізаційними виправленнями за логами реального сервера
(`SERV_HRDL_1`, 2026-08-24) і двома змінами поведінки на запит власника.
Нових функцій немає — усе нижче або виправляє дефект, або змінює рівень/
видимість уже наявної поведінки (розділ 3.2 `RELEASE_POLICY.md`).

Нумерація: `5.2.0-rc.2` (build `84627f1`, 2026-08-23) існував лише як
локальна збірка на DEV-сервері і НЕ публікувався в `origin` — тега й
GitHub Release для нього немає. Щоб номер версії на сервері не збігався з
іншим за змістом кодом, наступний кандидат — `rc.3`.

Ключове для оператора: до цього кандидата на серверах, де джерела
generation лежать на різних томах, щоденні резервні копії **не
створювались узагалі** — див. перший запис нижче.

- ЗМІНА ПОВЕДІНКИ (UX інсталяції): під час `BRAVO_SETUP`/
  `BRAVO_CREDENTIALS_SETUP` оператор тепер бачить те, що набирає — усі поля,
  включно з паролями (7-Zip, SFTP, SMB) і Slack/Discord webhook-URL. Раніше
  все, крім назви/коду установи й префікса архівів, вводилось під зірочками
  (`Read-Host -AsSecureString`), тому помилку в значенні (зайвий пробіл, не та
  розкладка) не було видно, і вона спливала пізніше як відмова автентифікації
  SFTP або `[FAIL]` у dry-run — далеко від місця, де її припустилися.

  **Значення при цьому не потрапляють у власні логи BRAVO.** Helper-логи —
  дослівний `Start-Transcript`, тому ввід виконується у вікні з паузою
  transcript, і пауза знімається у `finally`. Нові функції
  `Suspend-BRAVOHelperLog` / `Resume-BRAVOHelperLog` /
  `Test-BRAVOHelperLogSuspensionEffective` (`modules/BRAVO.HelperLogging`).

  Механізм **fail-closed** і не покладається на припущення про версію
  PowerShell: перед першим запитом canary-перевірка друкує унікальний маркер
  у вікні паузи й перечитує файл логу. Якщо маркер знайдено (пауза на цьому
  хості не працює) або якщо батьківський `BRAVO_SETUP` не підтвердив, що
  зупинив свій transcript (`BRAVO_PARENT_LOG_SUSPENDED=1`) — ввід лишається
  прихованим рівно як раніше, і оператор бачить пояснення в консолі.
  Батьківська пауза обов'язкова окремо: лог `BRAVO_SETUP` захоплює стрім
  дочірнього процесу.

  Валідація значення тепер застосовується лише там, де для нього є предметне
  правило (назва/код установи, префікс) — для паролів і webhook-ів такого
  правила немає, тож лишається спільна перевірка на непорожність. Збережені
  значення НЕ перевалідовуються, тому оновлення не ламає наявні інсталяції.

  Чого це не закриває (детально — `SECURITY.md`, розділ 3): групову політику
  «PowerShell Transcription» (окремий системний лог поза контролем BRAVO),
  scrollback консолі та запис екрана, і втрату фрагмента логу, якщо процес
  аварійно завершиться під час паузи.

- FIX (архівація, критично): багатотомний VSS Snapshot Set більше не
  падає на успішно створеному наборі. На серверах, де джерела generation
  лежать на різних томах (типово `MODEL`/`BLOG` на `D:`, `BRAVOEXCH` на
  `C:`), `New-BRAVOVSSDiskshadowSnapshotSet`
  (`modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1`) завершувався
  помилкою `VSS SNAPSHOT SET FAILED: diskshadow.exe повернув код 4`, після
  чого архівація MODEL/BLOG/BRAVOEXCH скасовувалась (`опубліковано 0 з 3`),
  generation manifest не створювався, а наступний health-check доповідав
  `не знайдено жодного COMPLETE generation manifest` і три `SFTP ...:
  component відсутній у verified COMPLETE local generation`. Тобто щоденні
  резервні копії на таких серверах не створювались узагалі. Три причини,
  усі виправлені:
  1. **Подвійний запуск `diskshadow.exe`.** Після
     `Start-BRAVOProcessOutputCapture` (який САМ запускає процес) стояв ще
     й `[void]$process.Start()`. Instance-метод `Process.Start()` спершу
     робить `Close()` поточного процесу і запускає новий, тому набір
     створював перший `diskshadow.exe`, а `WaitForExit`/`ExitCode` бралися
     вже від другого — звідси код `4` при повністю успішному виводі в тому
     ж повідомленні про помилку. Зайвий `Start()` прибрано; це єдиний
     виклик у комплекті, який його мав.
  2. **Сценарій без `EXIT`.** `diskshadow.exe` доходив до кінця файлу
     сценарію як до несподіваного завершення інтерактивної сесії і
     повертав ненульовий код навіть при успішному `CREATE`. Додано
     фінальний `EXIT`.
  3. **Розбір виводу залежав від мови ОС.** Ідентифікатор набору шукався
     регулярним виразом по англійському тексту `Shadow copy set ID:`,
     якого немає ні в локалізованому виводі (`Windows Server 2022` з
     російським/українським мовним пакетом), ні, власне, в англійському
     (`diskshadow.exe` друкує `Shadow copy set:` і `%VSS_SHADOW_SET%`).
     Тепер `Get-BRAVOVSSDiskshadowSetIdFromOutput` бере GUID із рядка з
     ASCII-alias-ом `VSS_SHADOW_SET` (alias-и не перекладаються), а
     `Get-BRAVOVSSDiskshadowSetIdFromWmi` слугує резервом: єдиний `SetID`
     серед shadow copies на потрібних томах, яких не було до запуску.

- FIX (архівація, ресурси): невдалий багатотомний VSS-набір більше не
  лишає на сервері persistent shadow copies. Контекст
  `SET CONTEXT PERSISTENT NOWRITERS` означає, що знімки не звільняються
  самі, а старий cleanup спрацьовував лише коли `SetID` вдалося розібрати
  з виводу — тобто саме в тому сценарії, який падав, не спрацьовував
  ніколи. Кожен невдалий запуск (щодня, за розкладом) лишав по знімку на
  кожен том, які назавжди тримали місце в тіньовому сховищі. Новий
  `Remove-BRAVOVSSDiskshadowOrphanedShadow` прибирає знімки, яких не було
  до запуску і які лежать на наших томах, незалежно від того, чи вдалося
  визначити `SetID`; чужі знімки (створені іншим ПЗ або наявні до старту)
  свідомо не чіпаються.
  **Дія оператора:** знімки, залишені попередніми версіями, треба
  прибрати вручну одноразово — `vssadmin list shadows` і
  `vssadmin delete shadows /shadow={ID}` для тих, що належать BRAVO.

- FIX (діагностика): вивід `diskshadow.exe` читається в OEM-кодуванні
  консолі (`StandardOutputEncoding`/`StandardErrorEncoding`). Раніше
  повідомлення про помилку потрапляло в лог нечитабельними символами саме
  тоді, коли діагностика найпотрібніша. На коректність розбору це не
  впливає — він спирається лише на ASCII-alias і GUID-и.

- ЗМІНА ПОВЕДІНКИ (exit code): нагадування про застарілі оновлення Windows
  і PowerShell більше не знижують результат успішного прогону. Ці записи
  лишаються видимими як `[WARNING]`, але позначені новим прапорцем
  `-Environmental` (`Write-BRAVOLog`, `Write-HealthLog`, `Write-Log`) і не
  інкрементують лічильник попереджень. Раніше сервер із невстановленими
  оновленнями (у реальному інциденті — 1109 днів) НАЗАВЖДИ отримував
  `exit 10` (`SuccessWithWarnings`) і статус `ЧАСТКОВО` на кожному
  успішному Health/Archive/Maintenance — стан середовища підмінював собою
  результат операції. Це та сама причина, з якої legacy-tier ОС уже
  логується як INFO в Archive/Maintenance; тут обрано `-Environmental`,
  щоб зберегти видимість нагадування як попередження. `-Environmental`
  свідомо НЕ впливає на помилки: прапорець знімає лише вагу попередження,
  а не приховує відмову. Рівень WARNING для legacy-tier у `BRAVO_HEALTH`
  не змінено — це окреме, раніше прийняте рішення
  (`Runtime/LegacyOSTierIsInformationalInOperationalRuns`).
  Якщо ваш моніторинг очікував код `10` як сигнал про непропатчену ОС —
  оновіть цю логіку: рівень оновлень більше НЕ впливає на код завершення.

- ЗМІНА ПОВЕДІНКИ (dry-run більше не суто read-only): відсутній SFTP-каталог
  призначення тепер створюється, а не блокує інсталяцію.
  `Test-SftpReadOnlyAccess` перейменовано на `Test-SftpDestinationAccess` і
  отримало прапорець `-CreateMissingDirectories`; `BRAVO_DRY_RUN.ps1`
  викликає його з цим прапорцем при `-TestAccess`. Підстава: `BRAVO_ARCHIV`
  усе одно створює ці каталоги при першому запуску
  (`Initialize-BRAVOSFTPRemoteDirectories`), тому старе повідомлення
  «Dry Run не створює каталоги» описувало неіснуюче обмеження продукту й
  давало глухий кут: `BRAVO_SETUP` зупинявся fail-closed на ненульовому коді
  dry-run, а перший архівний запуск, який створив би каталог, через це ніколи
  не настав (реальний випадок: `/baza_app`). Створення підтверджується
  повторним `FileExists`, а не відсутністю винятку; невдале створення й далі
  дає `[FAIL]`. Рядок результату `SFTP / Read-only доступ` перейменовано на
  `SFTP / Доступ` — попередня назва вже не описувала поведінку.

- FIX (dry-run, критично для інсталяції): перевірка webhook у
  `BRAVO_DRY_RUN.ps1` більше не вимагає legacy-запису `BRAVO_DISCORD_URL` /
  `BRAVO_SLACK_URL`. Runtime резолвить webhook через
  `Resolve-BRAVONotificationEndpoint` (route-специфічний
  `BRAVO_DISCORD_ALERTS_URL`/`BRAVO_DISCORD_GENERAL_URL` → legacy
  provider-wide → жорсткий літерал), а dry-run перевіряв ЛИШЕ legacy-запис.
  На сервері, налаштованому на route-специфічні webhook-и (саме так їх пише
  `BRAVO_CREDENTIALS_SETUP.ps1`), сповіщення фактично працювали, але dry-run
  звітував `запис 'BRAVO_DISCORD_URL' відсутній або порожній`, а
  `BRAVO_SETUP.ps1` зупинявся fail-closed з `СТАТУС: ПОМИЛКА` —
  інсталяція не завершувалась на цілком робочій конфігурації. Тепер dry-run
  викликає той самий канонічний `Resolve-BRAVONotificationEndpoint` для обох
  маршрутів (`alerts`, `general`) замість власної паралельної політики.
  Backward compatibility збережено: інсталяція лише з legacy
  `BRAVO_DISCORD_URL` і далі проходить, а повна відсутність webhook і далі
  дає `[FAIL]`.

- FIX (dry-run, діагностика): порожній Discord/Slack webhook у перевірці
  доступності (`BRAVO_DRY_RUN.ps1`, гілка `-TestAccess`) більше не
  показується оператору сирим текстом .NET-винятку
  (`Недопустимый URI: URI пуст.`), а дає ту саму канонічну причину
  `webhook відсутній у Credential Manager`, що й решта перевірок webhook.
  Поведінка перевірки не змінюється — це лишається `[FAIL]`.

- Self-тести: додано `BackupConsistency/VSSDiskshadowSetIdIsLocaleIndependent`
  (локалізований та англійський вивід, WMI-резерв, cleanup без розібраного
  `SetID`) і `BackupConsistency/VSSDiskshadowRunsExactlyOnce` (сценарій
  завершується `EXIT`, процес запускається лише через
  `Start-BRAVOProcessOutputCapture`, немає прив'язки до англомовного
  тексту виводу). Багатотомна гілка `diskshadow` до цього не мала жодного
  покриття — тому дефект і не ловився.

---

## 5.2.0-rc.1 — 2026-08-23 (candidate, pending acceptance)

RC stabilization на основі `5.2.0-dev.1` (нижче). Без нових функцій —
лише вузько-скоуповий compatibility-фікс (B2) і документальне
приведення scope у відповідність (PR #78, PR #79):

- B2: legacy BOM-у-паролі fallback для 7-Zip архівів (нижче).
- Health-alert дедуп: типовий `RepeatAlertAfterHours` змінено `6` → `0`
  (нижче).
- P3.2a (`BRAVO_UPDATE.ps1`) перенесено на `5.3.0` — 0 змін коду в цьому
  циклі.
- M3 (великий рефакторинг: service-lifecycle/operation-lock/WinSCP-session
  dedup, декомпозиція `BRAVO.DataRestore.Runtime.ps1`) відкладено на
  наступний цикл — не входить у RC stabilization.
- M1 (`WinSCP.uk` у `TOOLS_MANIFEST.json`) відкладено на `5.3.0` —
  походження файла неможливо незалежно верифікувати з репозиторію.
- B3: `SECURITY.md`/`README.md`/`BRAVO.config`/`OPERATIONS.md` синхронізовано
  з фактичною поведінкою (Recovery task Disabled не Deleted, watchdog/
  quiescence виняток, `BRAVO_BAZA_RECONCILE.ps1` в README, SFTP `trace/`
  upgrade-примітка).

Детальні рішення — `RELEASE_POLICY.md` §20.

### Upgrade notes (5.1.0 → 5.2.0)

Обов'язково прочитати перед оновленням production-серверів:

- **Recovery scheduled task.** На 24/7-серверах (`Restore.BootRestoreMode
  = "None"`, типово) інсталятор більше не видаляє раніше зареєстроване
  Recovery-завдання — він його **вимикає** (`Enabled = $false`). Завдання
  лишається видимим у Планувальнику зі статусом Disabled, а не зникає.
  Якщо ваш моніторинг/аудит очікував повної відсутності завдання —
  оновіть очікування на "Disabled", не "відсутнє".
- **`.mdz` retention.** `Retention.CompressedLogDeletionEnabled` (default
  `$false`) означає, що стиснуті `.mdz`-журнали, включно з legacy
  `Trace_YYYY-MM-DD.mdz`, **більше не видаляються автоматично за віком**,
  доки оператор явно не увімкне прапорець і `CompressedLogDays`. Це
  свідомий вибір безпеки (архіви не зникають самі), але має прямий
  наслідок — ризик росту використання локального диска на серверах із
  давньою історією `.mdz`; перевірте вільне місце і за потреби увімкніть
  retention явно.
- **SFTP `trace/`.** Trace-архіви (`Trace_YYYYMMDD.mdz`) тепер
  завантажуються в окремий SFTP-каталог `trace/`
  (`$global:sftpDirectories.Trace`), якого не існувало раніше. Перед
  оновленням переконайтесь, що каталог існує (або буде створений) на
  SFTP/Storage Box, і що обліковий запис BRAVO має права запису й
  достатню квоту під нього — так само, як для `baza_app`/`model`.
- **Legacy OS (Windows Server 2012/2012 R2/2016, best-effort tier).**
  `BRAVO_ARCHIV`/`BRAVO_MAINTENANCE` більше не завершуються кодом `10`
  (`SuccessWithWarnings`) і не маршрутизують успішний звіт у канал
  ALERTS лише через legacy-tier ОС — повідомлення тепер INFO, exit code
  `0`, звіт іде в GENERAL. Це змінює operator/monitoring контракт: якщо
  ваш моніторинг фільтрував/очікував код `10` як сигнал про legacy-ОС,
  оновіть цю логіку — рівень ОС більше НЕ впливає на код завершення
  успішної операції. `BRAVO_HEALTH.ps1` і далі показує WARNING про
  legacy-tier як окрему, постійну environmental-метрику (не змінилось).
- **Health-alert дедуп (`RepeatAlertAfterHours`).** Типовий дефолт
  змінено `6` → `0`: дедуп повторного ідентичного CRITICAL/WARNING
  health-alert **вимкнено за замовчуванням** — сповіщення про проблему
  тепер надходить щоцикл, поки проблема триває, навіть якщо вона
  ідентична попередній. Раніше однакове повідомлення пригнічувалось на
  6 годин (`Test-AlertSuppressed`/`Save-AlertState`,
  `modules/BRAVO.Health/BRAVO.Health.Runtime.ps1`), через що повторний
  той самий alert міг мовчати до 6 год., і оператор бачив лише перше
  сповіщення інциденту. SUCCESS-звіт ("ВСЕ СПРАВНО") дедупу ніколи не
  підлягав і цією зміною не зачіпається — він і раніше надсилався щоцикл.
  Якщо ваш моніторинг покладався на природне придушення дублікатів
  (наприклад, щоб не заспамити канал під час тривалого відомого
  інциденту) — поверніть `RepeatAlertAfterHours` на потрібне значення
  вручну в `BRAVO.config`.

- FIX (сумісність, B2): додано legacy BOM-у-паролі fallback для
  читання архівів, створених версіями BRAVO до 5.2.0. До 5.2.0 пароль
  7-Zip писався в stdin через `Process.StandardInput.WriteLine`, який
  під UTF-8-консоллю (`chcp 65001`) мовчки додавав BOM (U+FEFF) ПЕРЕД
  паролем — такі архіви ефективно зашифровані паролем `U+FEFF<пароль>`.
  Новий BOM-free запис (`Write-BRAVOProcessInputText`, впроваджено в
  циклі dev.1) більше не відкриває їх нормальним паролем — без цього
  фіксу читання/відновлення legacy-backup під UTF-8-хостом провалилось
  би з "невірний пароль" на справді валідному архіві.
  `Invoke-BRAVOSevenZipIntegrityTest`/`Invoke-BRAVOSevenZipExtraction`
  (`modules/BRAVO.Compatibility`) тепер: (1) звичайна спроба з
  нормальним паролем; (2) якщо невдача класифікована як password-failure
  (новий `Test-BRAVOSevenZipPasswordFailure` — розпізнає stderr-патерни
  7-Zip, емпірично перевірені на bundled `Tools\7za.exe`: "Wrong
  password"/"Data Error in encrypted file" -> кандидат, "Cannot open
  the file as archive"/"Unexpected end of archive"/"cannot find the
  file specified"/"Access is denied" -> НЕ кандидат, жодного fallback)
  — рівно ОДНА повторна спроба з `U+FEFF + пароль`; (3) успіх другої
  спроби позначається `LegacyBomPasswordFallbackUsed=$true` і `Warning`
  з рекомендацією створити новий backup поточною версією; (4) невдача
  обох спроб повертає ПЕРШУ (нормальну) причину відмови — без
  прихованої другої спроби. `Get-BRAVOSevenZipArchiveEntries` (listing)
  свідомо НЕ отримав fallback: заголовки Trace-архівів завжди
  нешифровані (без `-mhe`), тому listing не декриптує вміст і не
  залежить від правильності пароля — гілка ніколи б не спрацювала.
  Реалізація rename-безпечна щодо існуючих викликачів: обидві публічні
  функції зберегли сигнатуру, старий однопрохідний код виділено в
  приватні `*Core`-версії (без функціональних змін), обгорнуті новою
  retry-логікою.

- НОВА ОПЦІЯ (BAZA, опційна, вимкнена за замовчуванням): `backupMonitoring.
  SFTP.BAZA.AutoArchiveMutationThreshold` (`BRAVO.config`, default `0`) для
  розгортань із великою кількістю незалежних майданчиків клієнтів, де
  ручний обхід кожного сервера при кожній легітимній append-only мутації
  (типово — застосунок перегенерував кілька документів, як в інциденті
  21.08.2026) не масштабується. При `N > 0`: якщо мутацій за один цикл на
  компонент не більше `N`, синхронізація автоматично виконує ту саму
  rename-preserve операцію, що ручний `BRAVO_BAZA_RECONCILE.ps1 -AcceptAll`
  (стара remote-версія → `*.replaced_<дата>`, нічого не видаляється, стан
  очищається, нову версію заливає наступний плановий цикл) — без
  підтвердження оператора для кожного циклу. Новий `SyncResult.Status =
  'MUTATION_AUTO_ARCHIVED'`; Health показує це як INFO (не CRITICAL/
  ПОТРІБНА ДІЯ). Понад поріг `N` за цикл — поведінка НЕ змінюється:
  жорсткий блок, `MUTATION_VIOLATION`, CRITICAL, ручний
  `BRAVO_BAZA_RECONCILE.ps1`. Реалізація повторно використовує канонічну
  rename/state-логіку `Invoke-BRAVOBazaMutationReconciliation` через нове
  спільне лок-вільне ядро `Invoke-BRAVOBazaMutationAcceptanceCore`
  (`modules/BRAVO.BazaSync/BRAVO.BazaSync.psm1`) — без другої паралельної
  архівної політики. За замовчуванням (`0`, вимкнено) поведінка всіх
  існуючих і нових інсталяцій ідентична попередній: `MutationPolicy="Fail"`
  без auto-overwrite лишається default. Свідомо прийнятий залишковий
  ризик (без сукупного добового/тижневого ліміту, лише per-cycle поріг)
  задокументовано в `OPERATIONS.md`/`THREAT_MODEL.md`.

- ЗМІНА ПОВЕДІНКИ (планувальник реставрації): АВТОМАТИЧНА реставрація
  виконується не частіше ніж раз на тиждень, і успішна ПРИМУСОВА
  (`-ForceRestore`) зараховується в той самий тижневий інтервал —
  наступний плановий слот пропускається. Раніше захист був лише
  «раз на добу» (маркер `restore_done_<дата>.marker` за сьогоднішньою
  датою), тому `-ForceRestore` у вівторок не заважав плановій реставрації
  в неділю — модель реставрувалась двічі за 5 днів.
  Реалізація: успішна примусова реставрація записує в
  `BRAVO_RESTORE_STATE.json` нове поле `ForcedRestoreCoversSlot` —
  НАСТУПНИЙ плановий слот, який вона покриває; гейт стоїть на
  `$automaticRestoreDue`. Модель детермінована (порівняння слотів, а не
  арифметика «різниця < 7 діб»), тому планова реставрація о 03:20 не
  блокує наступну о 03:00 рівно через тиждень.
  `-ForceRestore` обмежень не має і може виконуватись будь-скільки разів;
  провалена/перервана примусова реставрація квоту НЕ споживає.
  Примусова реставрація, як і раніше, НЕ закриває сам плановий слот
  (маркер і `Status='Succeeded'` лишаються за автоматичним шляхом).
  Стан, збережений попередньою версією, поля не має — поведінка як раніше;
  записи `Status='Pending'`/`'Succeeded'` квоту зберігають.
  Пропуск логується як INFO із зазначенням слоту й причини.

- ЗМІНА ПОВЕДІНКИ (операторський підсумок): рядки «Кроків/Успішно/
  Попереджень/Пропущено/Помилок» у фінальному блоці РЕЗУЛЬТАТ тепер
  враховують і ненумеровані операції (Trace-SFTP, Очистка, Міграція,
  Архівація, Автовимкнення), а не лише пронумеровані `[N/8]`. Раніше
  вони рендерилися прямо через `Write-BRAVOOperationResult`, який не
  веде ані лічильники, ані журнал етапів, тому реальний прогін показував
  «Помилок: 0» при exit 60 через збійну SFTP-передачу Trace, а
  Discord-повідомлення показувало `✅ Trace` замість `❌` і зовсім не
  містило рядка «Очистка» та блоку «Проблеми». Нумерація `[N/8]` і
  `Total=8` не змінилися.
- ЗМІНА ПОВЕДІНКИ (exit-код): примусова реставрація поза дозволеним вікном
  (`-ForceRestore`) логується як INFO, а не WARNING. Це констатація свідомої
  дії оператора, а не аномалія, але будь-який WARNING піднімав severity
  сповіщення й давав exit 10 (SuccessWithWarnings) — оператор отримував
  жовте «ПОТРІБНА ДІЯ: перевірити журнал» при повністю успішному прогоні
  без жодної підказки, що саме не так. Текст у журналі не змінився.
  Протилежна ситуація — «Реставрацію пропущено … поза дозволеним вікном»
  (заплановане не виконано) — свідомо лишається WARNING.
- Виправлено хибну атрибуцію збою: зріз лічильників етапу «Обробка trace
  і логів» знімався ДО реставрації, тому критична помилка реставрації
  фарбувала наступний етап у FAIL, хоча той відпрацював. Зріз тепер
  береться безпосередньо перед фазою обробки логів — статус етапу
  відображає його власний результат.
- Добова Trace-передача створює відсутній віддалений SFTP-каталог
  рекурсивно перед завантаженням (канонічний `New-BRAVOBazaRemoteDirectoryRecursive`
  з BRAVO.BazaSync). Раніше `session.PutFiles` не створював каталог, і
  за відсутнього `/trace/` на сервері кожен прогін падав із
  «Cannot create remote file '...new.filepart'. No such file or
  directory», даючи exit 60 обслуговуванню, яке насправді відпрацювало.
  Збій створення каталогу лишається fail-open саме для SFTP: помилка
  етапу, локальний архів і джерельні `.out` збережені, повтор наступним
  прогоном.

- Post-repair валідація: тимчасові робочі файли bravocmd `*.$$$` (як і
  сегментні `*.NNN`) більше не вважаються критичними при зникненні —
  це транзитні артефакти repair, а не дані. Раніше orphan `*.$$$`
  (залишок перерваного repair) спричиняв би false-positive rollback на
  кожному наступному прогоні.
- Fail-closed відкат при провалі/перериванні реставрації + гейт рестарту
  служб. Раніше відкат із before-архіву виконувався лише коли bravocmd
  завершувався кодом 0 і Compare-FileSizes знаходив критичні зміни;
  перерваний/провальний repair (exit≠0) лишав модель без перевірки й без
  відкату, а служби BRAVO піднімалися поверх неперевіреної моделі.
  Тепер обидва шляхи проходять єдину функцію Invoke-BRAVOModelRestoreRecovery:
  рішення про відкат приймається за фактичним станом моделі (не за кодом
  виходу); відкат виконується у режимі «очистити→розпакувати» (прибирає
  orphan-сегменти перерваного repair) лише після підтвердження цілісності
  before-архіву; після відкату модель повторно валідується. Рестарт служб
  (BRAVO/exchangAPI/BRAVO Web) гейтований на встановленій цілісності моделі —
  якщо її не доведено (відкат провалився / before-архів невалідний), служби
  НЕ піднімаються, quiescence-маркер лишається suppressed, надсилається
  CRITICAL «потрібне ручне відновлення». Провал реставрації з відкатом тепер
  має власний exit-код RestoreFailed (43), окремо від збою створення архіву
  (40) і перевірки цілісності (41).
- ЗМІНА ПОВЕДІНКИ: механізм перевірки розмірів реставрації (знімок before-CSV
  і Compare-FileSizes після repair) став невідʼємною частиною реставрації і
  виконується ЗАВЖДИ, незалежно від -DisableSizeCheck. Прапорець
  -DisableSizeCheck / CheckSize тепер керує ЛИШЕ окремим кроком
  Check-MdFileSizes («.md > ліміт»), а не самоперевіркою реставрації.

## 5.2.0-dev.1 — 2026-08-20

- New Trace processing model (daily accumulating archive): TraceSRV.out
  and the new optional TraceBIS.out (explicit
  maintenanceSettings.Trace.BISSourcePath — no reliable auto-discovery
  source exists for BIS) are handled EXCLUSIVELY by BRAVO_MAINTENANCE
  (manual and scheduled runs share one pipeline; file size is never a
  trigger). Rotation while services are stopped produces flat
  Trace\<Name>_<yyyyMMdd_HHmmss>.out (collision takes the next free
  second, never overwrites; the sequence engine for
  exchangAPI/Apache/BravoWeb is byte-identical via the new
  -NamingPolicy parameter). After service restoration an unnumbered
  phase updates exactly ONE Trace_YYYYMMDD.mdz per calendar date (date
  from the rotated file NAME, oldest-first backlog across dates):
  inventory first (new Compatibility exports
  Get-BRAVOSevenZipArchiveEntries / Get-BRAVOSevenZipFileCrc), only
  NEW files are passed to 7za (existing entries are immutable and
  verified by Path+Size+CRC before publish), transactional
  .work-partial update with 7z t + SHA512 sidecar + atomic publish
  (a failed update never touches the previous valid archive), then
  SFTP into the new sftpDirectories.Trace ("trace") via verified
  <name>.new before replacing the previous remote version; rotated
  .out are deleted only after the full
  archive+integrity+SFTP+remote-verify chain, and a failed SFTP just
  defers to the next run without duplicate entries. The local daily
  .mdz is NEVER deleted by the pipeline — only by the new explicit
  Retention.CompressedLogDeletionEnabled (default $false: no
  compressed log .mdz, including legacy Trace_YYYY-MM-DD.mdz, is
  age-deleted until the operator opts in; CompressedLogDays applies
  only with the flag). Trace archive headers are deliberately not
  -mhe encrypted (same as backup .mdz): with encrypted headers 7za
  requests the password twice on append and does not reliably read
  the second prompt from redirected stdin. Dry-run gains read-only
  PLAN lines (sources, would create/update, queued count, would
  upload, would delete) reusing the canonical backlog function via
  AST extraction. Legacy date-directories/archives remain untouched
  and continue through the existing ArchiveDays chain. New selftest
  domain TraceArchive (18 scenarios on the real Tools 7za + fake SFTP
  session) plus rotation/retention/dry-run gates.
- Fix (latent, found by Trace characterization): 7-Zip passwords fed
  via Process.StandardInput.WriteLine were BOM-prefixed on UTF-8
  console hosts (chcp 65001) — archives were created "successfully"
  with a corrupted effective password. New canonical
  Write-BRAVOProcessInputText (BOM-free UTF-8 via BaseStream) is used
  by all Compatibility 7z wrappers and Maintenance
  Invoke-CommandWithLog; the Secrets/SevenZipPasswordUsesStdin gate
  now requires the helper. Debt note: BRAVO.DataRestore's private
  Get-BRAVOSevenZipArchiveInventory (counters-only) should migrate to
  the new canonical Get-BRAVOSevenZipArchiveEntries in the DataRestore
  decomposition cycle.

Opens the next development cycle on developer after the 5.1.0 stable
release (per RELEASE_POLICY.md section 11: post-promotion sync with
master, then immediate prerelease bump so both branches never carry the
same packageVersion). Planned focus (from the recorded 5.1.0-cycle
debt): deduplication of service-lifecycle / operation-lock /
WinSCP-session / ASCII-temp-root policy copies and BRAVO.DataRestore
Runtime.ps1 decomposition.

- New operator tool BRAVO_BAZA_RECONCILE.ps1 (guarded entrypoint) +
  BRAVO.BazaSync exports Get-BRAVOBazaMutationReport /
  Invoke-BRAVOBazaMutationReconciliation: one-command resolution of
  append-only mutation violations (real incident 2026-08-21: five
  ЗВТ PDFs legitimately regenerated in the BRAVO application).
  -ListOnly shows old (state/cloud) vs new (local) versions with the
  upload date and a TraceSRV.out verification hint; -Accept/-AcceptAll
  renames the old remote version to *.replaced_<date> (rename-only,
  never delete) and removes the state entry under the component sync
  lock, so the next scheduled cycle uploads the new version; a rename
  failure keeps the state entry (fail-closed). MutationPolicy="Fail"
  is unchanged — an automatic overwrite policy is deliberately NOT
  provided (ransomware would silently propagate to the cloud).
  OPERATIONS gains a mutation-resolution runbook including the manual
  fallback lessons (hashtable Files keyed by RelativePath; state I/O
  strictly via [IO.File]:: UTF-8 — raw Get-Content/Set-Content mangle
  Cyrillic keys; deleting keys alone just converts the block into
  REMOTE_CONFLICT).
- The suppressed-marker watchdog issue text is compacted to one cause
  + one action + the owner log ("перерване відновлення — потрібне
  РУЧНЕ втручання за кодом 43 (автостарт заборонено); лог: <шлях>");
  the internal restartSuppressed jargon and the triple restatement
  stay only in the detailed Health log line.
- Compact operator alerts (operator request from the DEV-LIMS field
  test): the Health problem notification shows the full issue Reason
  exactly once (in its thematic section) — the header reason block now
  carries only a compact component list (up to 4 names) instead of
  duplicating the first issue's full text, and the redundant
  :package: component-list line is removed. Watchdog issues carry
  their own ActionText ("виконати ручне відновлення служб (OPERATIONS.md,
  код 43)" / "перевірити причину аварійного переривання <owner>" /
  "запустити служби вручну та перевірити ownership-маркер") instead of
  the broken generic template "запустити або перевірити службу Служби
  після аварії <owner>"; plain service issues keep the old template.
- Config loader: an effective configuration now always carries
  maintenanceSettings.Restore.BootRestoreMode — a legacy site config
  (5.0/5.1) without the new key gets the safe 'None' (24/7) default.
  Previously BRAVO_TASKS_INSTALL (and any other direct consumer)
  crashed under StrictMode with "property 'BootRestoreMode' cannot be
  found" despite the loader's own "the stale key is ignored" warning
  (real case: DEV-LIMS site config from the rc.4 era). Regression test
  ConfigurationLoader/MissingBootRestoreModeDefaultsToNone builds a
  legacy-shaped fixture and validates both the loader default and the
  installer run.
- Self-test: temporary directories are created under
  [IO.Path]::GetTempPath() instead of raw $env:TEMP. On servers where
  the session TEMP variable carries the 8.3 short profile form
  (C:\Users\E980D~1.KUC\..., real case: DEV-LIMS / Server 2022),
  Remove-Item -LiteralPath in Windows PowerShell 5.1 fails on the
  short segment with PSArgumentException and aborted the whole
  self-test run in the environment-preflight block.
- Quiescence watchdog hardening (review F4/F5): the watchdog starts
  only services from the canonical managed set resolved from
  maintenanceSettings.Services (including resolved BravoWeb
  candidates) — a marker entry outside that set is refused with an
  ERROR alert and the marker is kept (fail-safe: unavailable
  configuration yields an empty set and a full refusal), so a
  planted/edited marker can no longer make SYSTEM-Health start an
  arbitrary service. BRAVO_SETUP now hardens the machine state root
  ACL (`Protect-BRAVOMachineStateRoot`, new BRAVO.System export):
  `%ProgramData%\BRAVO\State` gets inheritance disabled with
  FullControl only for SYSTEM and Administrators; ValidateOnly and
  non-elevated runs report compliance without changing anything.
  Watchdog reporting no longer counts an already-running service as
  "recovered" — the operator sees the actual incident scope.

- CI: push- and pull_request-event check names split (jobs get a
  " (push)" suffix outside pull_request context). During the 5.1.0
  stable promotion the same head SHA carried a green PR run and the
  documented intentionally-red push run under identical check names,
  so master branch protection counted both and blocked the merge
  ("2 of 5 required status checks are failing"), forcing a temporary
  enforce_admins bypass. Required checks are now supplied exclusively
  by the pull_request (merge-preview) run; push runs keep full
  coverage, including the branch-context release-policy gate, under
  suffixed names. No step logic changed.
- Service quiescence ownership marker + Health watchdog: Maintenance
  and DataRestore now write an atomic ownership marker
  (`%ProgramData%\BRAVO\State\BRAVO_SERVICE_QUIESCENCE.json`, same
  pattern as the VSS ownership state) BEFORE stopping managed services
  (marker write failure aborts the stop — fail-closed) and clear it
  only after all services restarted successfully. The scheduled
  BRAVO_HEALTH run gains a narrow, documented exception to its
  read-only policy: if the marker's owner process is dead
  (pid+processStartTime liveness check, PID reuse excluded) and
  restartSuppressed=false, Health starts exactly the services listed
  in the marker and alerts; a suppressed marker or a manual stop
  without a marker is never auto-started. DataRestore always writes
  its marker suppressed (a hard kill mid-restore leaves the live
  filesystem in an undefined state, so the watchdog only raises a
  CRITICAL manual-recovery alert and never auto-starts over it);
  Clear/Suppress are owner-guarded (pid+processStartTime) and the
  watchdog re-reads the marker before acting (TOCTOU guard), so
  overlapping owners cannot delete each other's markers; Read
  validates all required marker fields and returns null for
  partially edited markers instead of failing the whole Health run
  under StrictMode. New self-test domain
  `selftest/BRAVO_SELF_TEST.ServiceQuiescence.ps1`; new
  BRAVO.System exports (Write/Read/Clear/Suppress quiescence state,
  Test-BRAVOProcessAlive). See OPERATIONS.md «Аварійне відновлення
  служб (ownership-маркер)».
- Fixed a double-restore defect (real incident on a production BRAVO
  server, 2026-08-20): the Recovery guard branch for missed daily work
  with services already running (exit 20) unconditionally overwrote
  BRAVO_RESTORE_STATE.json with Pending, degrading the Succeeded state
  of an already-performed restore — the next 15-minute Recovery tick
  then executed the full model restore a second time in the same day.
  The trigger was a race with the nightly BRAVO_ARCHIV run (its Backup
  execution mark not yet written while it was still running produced a
  false missed-Backup verdict). Pending is now written only when the
  restore slot is genuinely still due; a completed restore state is
  never degraded. Regression test
  Maintenance/RecoveryGuardNeverDegradesSucceededRestoreState.
- Legacy OS tier (Server 2012 R2/2016) is informational in operational
  runs: BRAVO_ARCHIV and BRAVO_MAINTENANCE now log the LegacyBestEffort
  support-tier message as INFO instead of WARNING. Previously every
  successful run on such a server exited with code 10
  (SuccessWithWarnings) and its report was routed to the ALERTS channel,
  although the OS tier has no effect on the operation itself.
  BRAVO_HEALTH keeps the WARNING as the canonical owner of environmental
  metrics (same principle already applied to Windows update age), and
  the Unsupported tier still blocks runs as before.
- ROADMAP: P3.2a documented — BRAVO_UPDATE.ps1, operator-triggered
  server update (staged download + SHA-256 + config diff gate +
  in-place mirror + guard/scheduler/setup gates + update journal +
  auto-rollback), planned for this cycle; silent auto-update remains
  architecturally forbidden until full P3.2/P4.
- Missed-restore redesign (server profiles). New config key
  maintenanceSettings.Restore.BootRestoreMode replaces
  RunMissedOnStartup (loader warns about the stale key):
  - "None" (default, 24/7 server): the BRAVO_RESTORE_RECOVERY task is
    no longer registered (an existing one is disabled by the
    installer); a missed restore slot is picked up by the next nightly
    BRAVO_MAINTENANCE (23:55) inside the restore window — previously a
    separate Recovery daily trigger ran it at 21:00 instead.
  - "HoldServices" (work-hours server that is powered off at night and
    never sees the restore window): the installer switches
    BRAVO/exchangAPI to Automatic (Delayed Start) (new canonical
    BRAVO.System function Set-BRAVOBootRestoreServiceStartType — the
    only place in the kit that changes service start types) and
    registers Recovery with a single boot trigger (delay 0, no
    repetition). At server startup the missed restore runs OUTSIDE the
    window while the services are held stopped, so clients cannot
    enter the application before the model is replaced; fail-open —
    if the task does not run, delayed auto-start brings services up.
  - The former boot-trigger repetition (15 min for 8 h) is removed: on
    a production BRAVO server (2026-08-20) its tail kept waking the task every 15 minutes
    long after the restore had succeeded.
  - Quiescence integration (post-rebase review): the destructive model
    restore phase (bravocmd) now runs under a suppressed ownership
    marker — a hard kill mid-restore makes the Health watchdog raise a
    CRITICAL manual-recovery alert instead of auto-starting services
    over a half-restored model (suppression failure aborts the restore
    before bravocmd, fail-closed; the marker returns to auto-start mode
    once the model is consistent again). The boot HoldServices profile
    forces every enabled managed service into the stop/marker/restart
    scope regardless of the boot race with delayed auto-start, and the
    service snapshot now counts StartPending as running in all
    profiles.

## 5.1.0 — 2026-08-20

Stable release of the 5.1.0 line, promoted (metadata-only) from the
accepted 5.1.0-rc.4 candidate: deploy/stamp commit `219c55b`
(sourceCommit `d90c3c2`), artifact BRAVO-Toolkit-5.1.0-rc.4.zip sha256
`a825415c4275b8585c3b8896d655766545edfab2514902889229b80f096ca6b9`,
push CI run 32346213433 SUCCESS (self-test, DataRestore E2E matrix,
PSScriptAnalyzer, parser/BOM/JSON, gitleaks).

Real-server acceptance: full DEV-LIMS run 2026-08-20 (11:18–13:42),
evidence document
`docs/BRAVO_DATA_RESTORE_RC4_DEVLIMS_ACCEPTANCE_20260820.md` (branch
`evidence/219c55b-rc4-devlims-acceptance-pass`, commit `8efb95e`). All
runbook scenarios PASS: Setup/Archive/Health, B4+B17 (real SFTP-source
restore), B15, B16 (incl. a bonus fail-closed free-space abort), B19
and B20 (deterministic failpoint rollbacks, incl. cross-component),
B21 (clean exit-50 SFTP abort with zero live mutation), B22
(operation-lock contention). Notification severity routing confirmed
live in both directions: SUCCESS -> GENERAL, WARNING/CRITICAL ->
ALERTS.

Headline changes since stable 5.0.2:

- BRAVO_DATA_RESTORE: production data-restore entrypoint +
  modules/BRAVO.DataRestore (Local/SFTP source, InPlace/OutOfPlace,
  move-aside `.prerestore_*` copies, deterministic cross-component
  rollback, exit code 43 RestoreFailed, operation-lock integration,
  post-restore Health, self-tests and a CI E2E matrix) — see the rc.2
  candidate section below.
- Notification severity routing (GENERAL/ALERTS) ported into the 5.1.0
  line (rc.3 section) and extended to DataRestore notifications (rc.4
  section, PR #62).

## 5.1.0-rc.4 — 2026-08-20 (candidate, ACCEPTED 2026-08-20 — released as 5.1.0)

Fourth release candidate of the 5.1.0 line. Opened because the rc.3
DEV-LIMS acceptance run found that BRAVO_DATA_RESTORE notifications
still went through the legacy single webhook without severity routing:
a FAILED restore report (exit 43) landed in the GENERAL channel instead
of ALERTS. Not a regression (DataRestore does not exist in 5.0.x and
the PR #39 port covered Archive/Health/Maintenance only), but the
project decided to fix it now rather than document it as a known
limitation. This is a functional runtime change, so the partial rc.3
acceptance evidence is discarded: **rc.4 requires a new full DEV-LIMS
acceptance run** before any stable promotion.

- DataRestore notifications routed through the canonical
  BRAVO.Notifications chain (PR #62): Resolve-BRAVONotificationRoute
  (send/no-send decisions stay at call-sites; routing selects the
  channel only — exactly two channels: SUCCESS -> GENERAL,
  WARNING/CRITICAL -> ALERTS), Resolve-BRAVONotificationEndpoint
  (per-channel Credential Manager targets with the same legacy-webhook
  fallback as other senders), Discord chunking and the configured
  NotificationRequestTimeoutSeconds. Four regression self-tests added;
  Notifications/DiscordMentionsRemainDisabled extended to DataRestore.
## 5.1.0-rc.3 — 2026-08-20 (candidate, NOT accepted)

Third release candidate of the 5.1.0 line. Opened because a
release-identity review during the (aborted) rc.2 stable promotion
found that the candidate lacked the notification severity-routing
feature (GENERAL/ALERTS channels) present in stable 5.0.x: PR #39 had
historically entered master directly, bypassing developer. rc.3 ports
that feature into the 5.1.0 line via a reviewed master->developer
merge, together with the overdue metadata sync of the 5.0.1/5.0.2
hotfix sections. This is a functional runtime change, so the full
DEV-LIMS acceptance PASS recorded for rc.2 (candidate 10e9973,
docs/BRAVO_DATA_RESTORE_RC2_DEVLIMS_ACCEPTANCE_20260819_PASS.md) no
longer covers the runtime: **rc.3 requires a new acceptance run**
before any stable promotion.

- Ported notification severity routing (PR #39 + its 5.0.1 override
  fix, already present in developer form): severity -> GENERAL/ALERTS
  channel routing centralized in BRAVO.Notifications
  (Resolve-BRAVONotificationRoute / Resolve-BRAVONotificationEndpoint /
  Send-BRAVONotification), per-channel Credential Manager targets
  (BRAVO_DISCORD_GENERAL_URL / BRAVO_DISCORD_ALERTS_URL and the Slack
  pair) with automatic fallback to the legacy single webhook,
  NotificationRouting config key, Archive/Health/Maintenance senders
  rewired through the canonical API, credentials-setup components and
  operator documentation.

## 5.1.0-rc.2 — 2026-08-14 (candidate, NOT accepted)

Second release candidate of the 5.1.0 line. Unlike a typical RC, rc.2
carries a functional addition: completion of BRAVO_DATA_RESTORE, which
the project decided to ship inside stable 5.1.0. Because of this
functional change, the 5.1.0-rc.1 acceptance evidence no longer covers
the runtime: **rc.2 requires a new full acceptance run** (including the
real DEV-LIMS restore acceptance) before any stable promotion. This
candidate has NOT been accepted yet. The earlier local, unpublished
5.1.0 stable promotion produced from rc.1 (commit `ac07f55`) is
superseded and must not be pushed, merged, tagged, or released; the
"5.1.0" section below describes that unpublished promotion and stable
5.1.0 will be re-promoted from an accepted rc.2.

- New `BRAVO_DATA_RESTORE.ps1` entrypoint (thin orchestration over the
  new `modules/BRAVO.DataRestore` domain module): real data restore of
  MODEL/BLOG/BRAVOEXCH components from a verified COMPLETE backup
  generation — out-of-place by default, in-place with move-aside and
  rollback, local BackupRoot or SFTP source, `-ListGenerations`
  inventory mode. Runs the same runtime-integrity guard chain before
  `Import-Module` as the other entrypoints.
- Generation selection and per-component verification
  (`Get-BRAVORestoreGenerationManifest`,
  `Get-BRAVOVerifiedGenerationArchive`) promoted from
  `BRAVO_RESTORE_TEST.ps1` into `modules/BRAVO.ArchiveHelpers` as the
  single canonical selector/gate shared by the restore drill and the
  real restore; the drill script now calls the shared functions instead
  of local copies (no behavior change).
- New exit code `43 RestoreFailed` in `modules/BRAVO.ExitCodes`: failure
  of the restore operation itself. More specific archive causes keep
  priority (41 IntegrityTestFailed, 42 HashValidationFailed win over
  43); 43 wins over 50 SftpFailed and warnings.
- In-place restore now rolls back the **whole run**, not just the failing
  component. Previously a failure on the second or third component left
  production mixed: earlier components already replaced from the backup
  generation, the rest still on their old data — an inconsistent
  MODEL/BLOG/BRAVOEXCH set. Components restored earlier in the same run
  are now moved back to their pre-restore state in reverse order and
  reported as `ВІДКОЧЕНО` (`ROLLED_BACK`); a failure to roll back one
  component does not stop the rollback of the others and raises a CRITICAL
  notification with the exact manual recovery command. A component whose
  rollback did not complete is never left reported as restored: it gets the
  terminal status `ПОМИЛКА ВІДКАТУ` (`ROLLBACK_FAILED`) carrying the
  concrete failure reason, keeps its `.prerestore_*` copy listed for manual
  recovery, and the run still exits `43 RestoreFailed`. No `.prerestore_*`
  copy is ever deleted automatically.
- Self-test extended to cover the new entrypoint (guard-before-import,
  build-id surfacing, exit-code priority profile, shared restore
  selector ownership) and, behaviourally, the restore logic itself:
  path guards, component selection, target planning (protected-location
  and non-empty-target rejection, in-place discovery targets), free-space
  preflight, post-extraction verification, and cross-component rollback
  including the partial-failure path.
- Operator documentation: `OPERATIONS.md` gains an exit code `43` runbook
  section, including recovery steps for a restore interrupted mid-flight
  (process killed, reboot, BSOD) where services stay stopped and the live
  directory may be missing; `README.md` documents the restore workflow
  (section 6.2) and its invariants.

Stable production release promoted from the verified `5.1.0-rc.1`
candidate (accepted HEAD `852a0b9`, CI run 31755546128 SUCCESS,
real-server acceptance verdict PROMOTE). The candidate passed the
complete Windows CI pipeline and real-server acceptance on Windows
PowerShell 5.1, including real-SFTP BAZA acceptance across all 10
scenarios (DEV-LIMS, 2026-08-13 — see `docs/BAZA_SFTP_ACCEPTANCE.md`
section 13). This promotion contains no functional runtime changes
relative to the accepted candidate: it removes the prerelease suffix,
sets the stable release channel, updates operator documentation
headers, and regenerates the runtime integrity manifest. No
configuration schema, state schema, credential target, archive format,
retention default, transfer protocol, or supported-OS contract changed
during promotion.

## 5.1.0-dev.1 — 2026-08-12

Opens the next development cycle on top of the 5.0.0 stable baseline
(`master` merged into `developer`). Minor version: this cycle already
carries new functionality (Retention Safety Invariants), not only fixes.
No configuration schema, state schema, credential target, archive format,
transfer protocol, or supported-OS contract changed. The default minimum
retained verified generations did change (1 -> 2, see Retention Safety
Invariants below).

- Automatic restore recovery now guarantees a daily retry inside the
  configured `Restore.WindowStart`/`WindowEnd` window regardless of
  `Maintenance.DailyAt` or server reboots. The `Recovery` scheduled task
  gains a second, daily trigger at `Restore.WindowStart` on the same task
  definition (same `-RunMissedRestoreOnly` action as the existing
  boot trigger) — previously only a boot-triggered retry (15 min for 8
  hours) existed, so a server that stayed up with `Maintenance.DailyAt`
  outside the restore window could skip a missed restore indefinitely.
  The Maintenance.DailyAt-outside-window log message no longer claims the
  daily path is lost and is downgraded from `WARNING` to `INFO`. The
  `Recovery` task itself is now always registered (`Scheduler.Recovery.Enabled`
  is no longer tied to `Restore.RunMissedOnStartup`): the daily trigger is
  unconditional, and `Restore.RunMissedOnStartup` now only controls whether
  the additional boot trigger is also created — previously setting it to
  `false` disabled the daily safety net along with the boot retry.
- Automatic restore now re-validates `Restore.WindowStart`/`WindowEnd`
  immediately before the destructive `bravocmd.exe` call, not only once at
  the start of the run. `$shouldRestore` was computed before
  `Enter-BRAVOMaintenanceOperationLock` (up to `OperationLockWaitMinutes`,
  360 min by default), service stop, and the before-restore archive — the
  window could close during that wait and the old check was never a final
  authorization. Two barriers (before entering the restore sequence, and
  immediately before `bravocmd.exe`) call the same `Test-BRAVORestoreExecutionStillAllowed`
  check; a window that closes in between now postpones the restore (clear
  `WARNING`, no `bravocmd.exe` call, no success marker/state write, the
  scheduled slot stays retryable) instead of running past the window.
  `-ForceRestore` is unaffected by either barrier.
- `Remove-BRAVOOrphanedTemporaryArchiveArtifacts` (orphaned `.work\*.partial*`
  cleanup, introduced in 5.0.0) no longer uses `Test-Path` to check whether
  `.work` exists. `Test-Path` cannot be fail-visible for a pure local ACL
  access-denied on an existing directory — `.NET Directory.Exists` (which
  the filesystem provider uses) swallows `UnauthorizedAccessException` by
  design and returns `$false`, indistinguishable from "doesn't exist." The
  existence check is now folded into the same `Get-ChildItem` call that
  already enumerates `.partial*` files, classified by exception type:
  `ItemNotFoundException`/`DirectoryNotFoundException` is a benign skip,
  anything else (`UnauthorizedAccessException`, `IOException`, provider/
  network errors) marks the operation failed and logs `ERROR`.
- `Recovery`'s daily trigger now has `StartWhenAvailable=true` (every other
  task type keeps the global default of `false`): if the trigger is missed
  because the server was asleep/offline, Task Scheduler catches it up as
  soon as the server is available again, instead of waiting for the next
  scheduled occurrence. Safe only because of the two TOCTOU barriers above
  — a late catch-up that lands outside the window now correctly no-ops.
- Retention Safety Invariants: generation-aware backup retention now also
  sweeps orphaned `.work\*.partial*` temporary archive artifacts left behind
  by a killed process, raises the default minimum retained verified
  generations from 1 to 2, and emits a single per-run retention audit log
  line (evaluated/protected/deleted counts).
- Windows service run-state (`Running`/`Stopped`/`Disabled`/not installed)
  can no longer gate backup — only the operations that genuinely require a
  stopped service (destructive restore, other destructive MODEL operations,
  open application-log rotation) may depend on it; this is now a documented
  architectural contract (`OPERATIONS.md`, "Стан служб не визначає політику
  backup"). `Find-BRAVOServiceByCandidates` (used by installation-path
  discovery for `BRAVO_ROOT`, `WEB_ROOT`/`BAZA_WWW`) previously excluded any
  service with `StartMode=Disabled`, conflating "administratively disabled"
  with "not installed": a `Disabled` BRAVO Web/Apache service made
  `BAZA_WWW` backup (both SFTP and local synchronization) silently
  unresolvable even though its `DocumentRoot` directory remained fully
  readable on disk — a service-state gate with no underlying filesystem
  error. The `Disabled` exclusion is removed; service state no longer
  affects path identity (the same principle `Resolve-BRAVOEffectiveLimsRoot`
  already documented for `LIMSRoot`), and a `Disabled` match now appends a
  diagnostic-only `[УВАГА: служба має тип запуску Disabled]` note to
  `BRAVO_ROOT`/`WEB_ROOT` reasons instead of failing discovery. When the
  BRAVO Web/Apache service is genuinely absent (not just disabled) and no
  `discoverySettings.Sources.BAZA_WWW`/`.WebRoot` override is configured,
  `BAZA_WWW`'s discovery-failure reason now explicitly says the service
  could not be found (previously a dangling, unexplained "BAZA_WWW не
  визначено: ") — a controlled "source unknown" failure, never phrased as
  a service-state policy denial. Regular backup generation (MODEL/BLOG/
  BRAVOEXCH, sourced only from `bravo.ini`), pre-/post-restore MODEL
  backups, and `ArchiveAfterMaintenance` were already service-state
  independent; audited and confirmed with new regression coverage.
- Closed a second, deeper instance of the same invariant: `BRAVO.config`
  called `Resolve-BRAVOEffectiveLimsRoot` for `pathSettings.LIMSRoot`
  (default `""` = AUTO from the BRAVO service) and `throw`n immediately
  when the service was absent — before `Resolve-BRAVOInstallationDiscovery`
  (MODEL/BLOG/BRAVOEXCH) ever ran. A production-loader-level test (driving
  the real `Import-BravoConfiguration` + `BRAVO.config`, not the Discovery
  helper directly) confirmed this: with the BRAVO service absent, a
  perfectly valid canonical `bravo.ini`, and an explicit `BackupRoot`,
  config loading still failed on the LIMSRoot check alone. `LIMSRoot`/
  `SystemLogRoot` resolution no longer throws inside `BRAVO.config` itself;
  each consumer now decides its own criticality. `BRAVO_ARCHIV` does not
  *require* `LIMSRoot`/`SystemLogRoot` (MODEL/BLOG/BRAVOEXCH come only from
  `bravo.ini`, `BackupRoot` has its own independent explicit-or-AUTO
  resolution with its own `Error`/throw) — `$rootPath` is still technically
  read for an informational log line and as a free-space-preflight sanity
  fallback, it just never gates the backup result. `BRAVO_HEALTH` reads
  neither value at all — it already only requires `BackupRoot`. `BRAVO_MAINTENANCE`
  is unaffected: it already had its own explicit, independent guard
  (`effectiveLimsRoot`/`systemLogRoot`/`backupRootPath` non-empty, `exit 30`
  otherwise) immediately after loading configuration, so Maintenance's
  fail-closed behavior when it genuinely needs the installation root is
  unchanged — now protected by a regression test
  (`ProductionConfig/MaintenanceOwnLimsRootGuardStillBlocks`) so it cannot
  be silently weakened later. Two related latent bugs, both surfaced only
  by testing the real config-loader path (not the Discovery helper in
  isolation): `Resolve-BRAVOInstallationDiscovery`'s unused `-LimsRoot`
  parameter was `Mandatory`, so passing the now-legitimately-empty
  `$rootPath` threw a parameter-binding error instead of proceeding — fixed
  by dropping `Mandatory` from a parameter the function body never reads;
  and Archive's free-space preflight passed the same possibly-empty
  `$rootPath` as `-RootPath` to `Get-BRAVOArchiveFreeSpaceResult`, whose own
  sanity `Test-Path` throws on an empty string — fixed by falling back to
  `$runtimeRoot` (always valid) when `$rootPath` is empty; the free-space
  check itself already evaluates every fixed drive regardless of
  `-RootPath`, so this changes no free-space behavior.
- Regression coverage: real COM `Schedule.Service` tests prove the
  `Recovery` task registers boot+daily triggers when `RunMissedOnStartup=true`,
  daily-only (task still registered, not disabled) when `false`, and
  `StartWhenAvailable=true` only for `Recovery`; a behavioral test with an
  injectable time provider proves the TOCTOU re-check blocks automatic
  restore once the window has passed while still allowing `-ForceRestore`;
  structural tests prove both barriers sit exactly where they must, ahead
  of the destructive call; four behavioral orphan-sweep cases cover
  missing `.work` (benign), access-denied, and a distinct I/O failure type,
  plus a structural test proving `Test-Path` is no longer called at all;
  a composite test proves a corrupted newest backup generation cannot
  evict an older verified-valid one from the retention-protected set.
  Service-state independence has two coverage layers, named to match what
  each actually proves: `Discovery/BackupSourcesResolveWhenBravo*` and
  `Discovery/BazaWWWResolvesWhenApache*` are behavioral tests of
  `Resolve-BRAVOInstallationDiscovery` alone (all three BRAVO/BravoWeb
  service states resolve `BRAVO_ROOT`/`MODEL`/`BLOG`/`BRAVOEXCH`/
  `BAZA_APP`/`BAZA_WWW` identically, `BAZA_WWW` from the same `httpd.conf`
  in every case) — an earlier round of these tests was named
  `Backup/WorksWhenBravoService*`, which misleadingly implied execution
  coverage for what was actually discovery-only coverage; renamed. Two more
  Discovery-level tests cover the service-genuinely-absent case distinctly
  from "disabled" (explicit override still resolves `BAZA_WWW`; no override
  gives a controlled "source not found" failure, not a service-denial
  message), and one proves `MODEL`/`BLOG`/`BRAVOEXCH` still resolve from
  `bravo.ini` with the BRAVO service entirely absent. Beyond discovery,
  three genuinely behavioral tests (`Backup/ArchiveInvokedWhenBravoService*`)
  drive the real Invoke-BRAVOComponentBackup control flow — its own atomic
  create/hash/verify/publish orchestration is exercised unmocked; only the
  archive/hash primitives (`New-Archive`, `New-SHA512Hash`,
  `Get-BRAVOFileHash`, `Write-BRAVOFinalHashFile`) are stubbed — from a
  discovered source through to a published archive on disk, once per BRAVO
  service state, confirming the archiver is actually invoked (a call
  counter proves it) and the archive actually exists regardless of service
  state. A third layer (`ProductionConfig/*`) goes one level deeper still:
  nine tests drive the real `Import-BravoConfiguration` against the real
  `BRAVO.config` text (targeted, verified regex substitution of specific
  config values only — the same technique `Version/AuthoritativeLoader`
  already used for `LIMSRoot`), with `Get-CimInstance`/`Get-WmiObject`
  shadowed at global scope to control service presence deterministically
  (the only reliable interception point across a module boundary — BRAVO's
  own functions cannot be shadowed that way, each module keeps its own
  session state, but foreign cmdlets resolve through the caller's scope
  chain). These prove, end to end: BRAVO absent + canonical `bravo.ini` +
  explicit `BackupRoot` reaches a ready `archiveDefinitions[MODEL].Source`;
  BRAVO absent + explicit source overrides work with no `bravo.ini` at all;
  BRAVO absent + no source of any kind fails closed with a "source unknown"
  reason, never a service-state one; the same two contrasting outcomes for
  Apache-absent `BAZA_WWW`; and Running/Stopped/Disabled remain unchanged
  through the full loader, not just the Discovery helper. Structural tests
  (clearly labeled as such, not behavioral) separately prove the
  pre-/post-restore archive calls and the `ArchiveAfterMaintenance` launch
  decision contain no service-status re-check; a true behavioral invocation
  test for the latter was judged impractical without restructuring
  `BRAVO_MAINTENANCE.ps1`'s monolithic top-level flow into a callable
  function purely for testability.
- Closed three post-fix regressions surfaced by review of the LIMSRoot fix
  above. `BRAVO_DRY_RUN.ps1` unconditionally reported `PASS` for
  `LIMSRoot`/`SystemLogRoot` even when unresolved (`Source -eq 'Error'`),
  which would have hidden a genuine `BRAVO_MAINTENANCE`/
  `BRAVO_RESTORE_RECOVERY` readiness problem behind a green result. New
  `Get-BRAVODryRunRootReadinessResults` (pure, unit-tested) now reports:
  `BackupRoot` unresolved is always `FAIL` (mandatory for
  `BRAVO_ARCHIV`/`BRAVO_ARCHIV_HEALTH`); `LIMSRoot`/`SystemLogRoot`
  unresolved is `WARN` when `Maintenance`/`Recovery` are both disabled in
  `schedulerSettings` (Archive-only context — backup stays allowed) and
  `FAIL` when either is enabled (they genuinely need the root, and
  `BRAVO_DRY_RUN.ps1`'s own overall readiness verdict already turns "НЕ
  ГОТОВО" on any `FAIL`, so this alone makes Maintenance/Recovery
  explicitly not-ready without touching `BRAVO_TASKS_INSTALL.ps1`, whose
  job is task registration, not runtime readiness).
  Second, `[System.IO.Path]::Combine($SystemLogRoot, 'Trace')` (and the
  equivalent for the optional exchangAPI/BravoWeb log directories) silently
  returns a *relative* path when `$SystemLogRoot` is empty instead of
  throwing or returning empty — the subsequent write-probe would have
  created a stray `.\Trace` in the process's current directory.
  `Get-BRAVODryRunOptionalComponentPlan` and the `SystemLog\Trace` target
  are now both guarded on a non-empty `SystemLogRoot`. Third,
  `Test-BRAVOFileSystemWriteAccess` created missing destination directories
  as part of its readiness probe but never removed them, contradicting Dry
  Run's own documented "does not create directories" contract; it now
  removes a directory it created if the directory is still empty once the
  probe file is deleted (a directory with unrelated content left in it by
  something else is never touched). Also renamed
  `Get-BRAVODryRunConfiguredServiceState`'s comment, which still claimed
  Discovery "deliberately" excludes `Disabled` services — no longer true
  after the fix above. Regression coverage: `DryRun/
  UnresolvedBackupRootIsAlwaysFail`, `DryRun/
  UnresolvedLimsRootIsWarnWhenMaintenanceRecoveryDisabled`, `DryRun/
  UnresolvedLimsRootIsFailWhenMaintenanceEnabled`, `DryRun/
  UnresolvedLimsRootIsFailWhenRecoveryEnabled`, `DryRun/
  ResolvedRootsAreAlwaysPass` (all behavioral, against the extracted pure
  function); `DryRun/EmptySystemLogRootProducesNoRelativeWriteTargets`
  (behavioral, proves no relative write target is ever produced) and
  `Runtime/08-WriteProbeCleansUpEmptyCreatedDirectory` (behavioral, proves
  the probe removes a directory it created once it's confirmed empty).
  Two more close the remaining coverage gaps this same review round
  flagged: `ProductionConfig/BravoAbsentCanonicalAutoDiscoveredIniWorks`
  drives the real production loader with `$env:SystemRoot` pointed at a
  fixture `SysWOW64\bravo.ini` and *no* `discoverySettings.BravoIniPath`
  override, proving ordinary canonical auto-discovery works, not only the
  explicit-override path every other `ProductionConfig/*` test used
  (x86/`System32` coverage would need `BRAVO.config` to pass
  `-Is64BitOperatingSystem` through explicitly, which it does not — out of
  scope without a production change); and `Backup/
  ArchiveInvokedWhenBravoServiceAbsent` extends the `Backup/
  ArchiveInvokedWhenBravoService{Running,Stopped,Disabled}` behavioral
  chain (production loader -> `archiveDefinitions[MODEL].Source` ->
  `Invoke-BRAVOComponentBackup` -> published archive) to the
  service-genuinely-absent case, which the renamed `ProductionConfig/
  BravoAbsentIniSourcesPrepareArchiveDefinition` only proved up to
  `archiveDefinitions` being ready, not backup execution itself.
- BAZA_APP/BAZA_WWW synchronization/verification rearchitected around an
  incremental, append-only-aware engine (new `BRAVO.BazaSync` module),
  replacing full-tree `synchronize`/`synchronize -preview` comparisons on
  every cycle for this specific (>50 GB, hundreds of thousands of files,
  files never modified after arrival, remote `-delete` never used) workload.
  The old cost was listing/stat/compare operation *count*, not bytes
  transferred, and it was the source of false-positive Health alerts for
  legitimately new files that appeared between sync and health-check.
  Core invariant: `SYNC -> VERIFY -> HEALTH RESULT`, not "Health finds new
  local files -> alert". Each sync cycle (`CycleId`) snapshots the local
  directory once (the `Cutoff`); files present in that snapshot belong to
  the cycle, files appearing after it are `NewAfterCutoff` — always `INFO`,
  never a Health alert, regardless of how long ago the cycle finished. A
  persisted per-component index (`%ProgramData%\BRAVO\State\BAZA\
  <Component>.state.json`, `BAZA.StateRoot`-configurable; explicitly *not*
  a Durable Operation Journal, which remains unstarted) records
  RelativePath/Size/LastWriteTimeUtc/UploadedUtc/Verified per file already
  confirmed transferred; a file with `Verified=true` and an unchanged local
  size needs zero remote calls on subsequent cycles (`AlreadyVerified`) —
  `LastWriteTime` is only ever an optimization hint, never the sole
  correctness signal, so a new file with an old timestamp is still
  discovered. State writes are atomic (temp file + `[IO.File]::Replace`,
  matching the existing `Save-BRAVOVSSOwnershipState` pattern); a crash mid-
  upload leaves the file `Verified=false` and it is retried, never silently
  marked successful. A size change on an already-`Verified` file is an
  append-only invariant violation (mutation): `BAZA.MutationPolicy = "Fail"`
  (default) blocks it from silent re-upload and reports
  `Status=MUTATION_VIOLATION` with the previous/current size and timestamp
  instead. State absent/corrupt/schema-mismatched never causes old files to
  be silently trusted (`Status=STATE_INVALID`) — it requires a full
  reconciliation. First run reconciles the existing SFTP tree via one
  expensive Full Audit (reusing the existing `Get-BAZASFTPComparison`/WinSCP
  `CompareDirectories` mechanism through a pure adapter,
  `ConvertTo-BRAVOBazaFullAuditResult`, rather than duplicating it) that
  seeds already-matching files as verified without re-uploading them;
  Full Audit also re-runs periodically (`BAZA.FullAuditEveryDays`, default
  7, or `-ForceFullAudit`) to catch drift a pure incremental plan cannot see
  on its own (e.g. a previously-verified file manually deleted on the
  remote side is detected and re-queued for upload) — never on every cycle.
  Bootstrap/Full Audit is `BRAVO_ARCHIV`'s exclusive responsibility (it
  always runs first on schedule); a standalone `BRAVO_HEALTH.ps1` with no
  state yet stops before any planning/upload with a controlled
  `Status=STATE_NOT_INITIALIZED` and zero transfer invocations instead of
  silently re-uploading everything (hardened by the deep-review entry
  below). `BRAVO_HEALTH` now synchronizes BAZA before evaluating it
  (`BAZA.SynchronizeBeforeHealth`, default `true`): if `BRAVO_ARCHIV` already
  produced a `SyncResult` in the same run it is reused as-is (no second
  sync — `Invoke-BRAVOBazaComponentSyncSession` is the one shared
  session/sync/checkpoint entry point both callers use); a standalone Health
  run with no fresh result performs exactly one sync itself before
  evaluating, never a stale-comparison-first alert. Fast Health
  (`Get-BRAVOBazaFastHealthResult`) evaluates only the already-computed
  `SyncResult` — no new remote comparison — and distinguishes normal new
  data (`NewAfterCutoff`, info-only) from a genuinely failed/incomplete
  sync (`Failed`/`PendingWithinCutoff` > 0, alert with cycle/discovered/
  uploaded/failed detail) from sync-not-completed
  (`ERROR`/`STATE_INVALID`, alert stating synchronization did not complete,
  never "N files missing"). A small remote checkpoint
  (`/baza_app/.bravo-sync.json`, metadata only — no credentials) is
  published as the last step of a successful sync only; a failed/partial
  cycle never publishes one. Concurrency: a per-component file lock
  (`<StateRoot>\BAZA\<Component>.sync.lock`, fail-fast, no retry loop) is a
  second, unconditional barrier around the state read-modify-write section,
  independent of the existing `SkipIfBackupTaskRunning`/
  `BRAVO_OPERATION.lock` coordination that already keeps a normally
  scheduled standalone Health run from overlapping `BRAVO_ARCHIV`; a
  genuine lock-contention conflict returns `Status=SKIPPED_CONCURRENT`
  (weighed by Health against last-successful-cycle freshness — see the
  deep-review entry below), while lock infrastructure failures
  (ACL/path/I-O) are a real `ERROR`, never masked as concurrency. New `backupMonitoring.SFTP.BAZA` config block (`Mode` — default
  `"IncrementalAppendOnly"`, any other value fully preserves the previous
  `Sync-FolderToSFTP`/`Invoke-WinSCPBAZAComparison` code paths unchanged;
  `SynchronizeBeforeHealth`; `FastHealthEnabled`; `FullAuditEnabled`;
  `FullAuditEveryDays`; `MutationPolicy`; `StateRoot`) is interpreted from
  exactly one place (`Get-BRAVOBazaSettingsEffective`,
  `Get-BRAVOBazaSyncModeEffective`, `Test-BRAVOBazaIncrementalModeEnabled`,
  all in the already-shared `BRAVO.ArchiveRuntime` module) that
  `BRAVO_ARCHIV`, `BRAVO_HEALTH`, and `BRAVO_DRY_RUN` all call — closing a
  real inconsistency found during this work, where `BRAVO_ARCHIV` already
  respected a `BAZA.StateRoot` override but `BRAVO_HEALTH`'s standalone
  fallback sync did not, which would have made the two write/read two
  different state files for the same component if that setting were ever
  changed from its default. `BRAVO_DRY_RUN.ps1` reports BAZA mode, state
  path, state readability, last successful cycle, last Full Audit, and next
  scheduled Full Audit purely by reading persisted state — it never opens
  an SFTP session or performs a sync. This is not the start of a Durable
  Operation Journal — the persisted state here is a narrow index scoped
  only to BAZA synchronization optimization/reliability.
- `BRAVO.BazaSync` production-gap hardening after an independent deep
  review, closing every finding before production rollout. (P1) A missing
  state without bootstrap authorization now stops *before* the planner with
  `Status=STATE_NOT_INITIALIZED` and a guaranteed zero upload invocations —
  previously a standalone Health run on a fresh install fell through to a
  plan where every local file looked new and could attempt to upload the
  complete 50+ GB tree. (P1) Fast Health switched from a status blacklist
  to a success whitelist: only `Status=COMPLETE` can reach the normal
  healthy evaluation; `INCOMPLETE` (e.g. state-save failure *after* all
  uploads succeeded, which previously fell through to "cloud copy current"
  because `Failed=0`), `ERROR`, `STATE_INVALID`, `STATE_NOT_INITIALIZED`,
  `MUTATION_VIOLATION`, and any unknown/future status fail visible, never
  open. (P1) `Enter-BRAVOBazaSyncLock` now classifies failures: only a
  genuine sharing violation (Win32 `ERROR_SHARING_VIOLATION`) is `Busy` →
  `SKIPPED_CONCURRENT`; access-denied/ACL, state-directory-creation
  failures, invalid paths, and generic I/O errors are `Error` →
  `Status=ERROR` and a Health issue — previously every lock exception was
  masked as "another process is syncing". (P1) Corrupt/unsupported-schema
  state is now genuinely recoverable, but only on the Archive path
  (`-BootstrapIfNeeded` + `FullAuditProvider`): Full Audit runs first, and
  only on success the corrupt file is quarantined beside the canonical
  path (`<Component>.state.corrupt.<timestamp>.json`) and a fresh state is
  built exclusively from the audit result (already-matching remote files
  seeded verified, only remote-missing files uploaded); a failed audit
  leaves the corrupt evidence untouched, trusts no files, uploads nothing,
  and honestly returns `STATE_INVALID`. Standalone Health keeps the
  previous safe behavior (`STATE_INVALID`, zero uploads, alert, file
  untouched). (P2) The config contract is now enforced instead of silently
  ignored: `BAZA.SynchronizeBeforeHealth = $false` or
  `BAZA.FastHealthEnabled = $false` combined with
  `Mode = "IncrementalAppendOnly"` is rejected at configuration validation
  with an actionable error pointing to `Mode = "Legacy"` as the explicit
  path to the old behavior (`BRAVO_DRY_RUN` reports this as a scoped FAIL
  for the BAZA section without aborting unrelated checks). (P2) The remote
  checkpoint is published via a temporary remote name (upload to
  `.bravo-sync.json.tmp-<guid>`, then an explicit replace — see the
  round-2 entry below) and its outcome is no longer discarded:
  `CheckpointAttempted`/`CheckpointPublished`/`CheckpointError` live on the
  SyncResult, and a publish failure on an otherwise-successful cycle is a
  `WARNING` (write-only operator telemetry — production Health never reads
  the remote checkpoint back, and docs no longer claim it does). (P2) A
  failed periodic Full Audit no longer disappears:
  `FullAuditAttempted`/`FullAuditSucceeded`/`FullAuditError`/`LastFullAuditUtc`
  are surfaced on the SyncResult and sync-succeeded-but-audit-failed is at
  least a `WARNING`, never silently "fully verified". (P2) Legacy SFTP
  filename-compatibility checking (UTF-8 *byte* limits per path segment —
  since round 2: 246 for file names, 255 for directories) now applies to
  incremental upload candidates (O(candidates), purely local, no
  remote tree scan, zero remote calls for an incompatible file): the file
  is skipped with an explicit `IncompatibleFiles` entry naming the exact
  relative path and reason, and Health raises `CRITICAL` — closing the
  previously documented residual gap. `SKIPPED_CONCURRENT` hardening:
  "another process is active" is no longer proof the cloud copy is current —
  Health weighs it against the persisted `LastSuccessfulSyncUtc` (fresh
  within 24 h → `INFO`/deferred; stale or never succeeded → `WARNING`), and
  the normal "хмарна копія актуальна" message is never produced for it.
  ~48 new behavioral self-tests cover all of the above through the real
  planner/synchronization path (no WinSCP session needed), including
  structural no-delete guarantees (no `SynchronizeDirectories`,
  `RemoveFiles` only ever touches the engine's own checkpoint artifacts,
  every `PutFiles` passes `remove=$false`).
- `BRAVO.BazaSync` hardening round 2 (final pre-rollout review findings).
  (P1) Incompatible SFTP names no longer produce a successful cycle:
  previously a skipped incompatible candidate left `Failed=0`, the cycle
  became `COMPLETE`, `LastSuccessfulSyncUtc` advanced and a "successful"
  remote checkpoint could be published even though data was knowingly not
  transferred. Such a cycle now ends with an explicit
  `Status=INCOMPATIBLE_NAME`: successful-cycle provenance
  (`LastCycleId`/`LastSuccessfulSyncUtc`) does not advance, no checkpoint
  is published (both the session-level gate and
  `Write-BRAVOBazaRemoteCheckpoint` itself refuse non-`COMPLETE` results),
  Health stays `CRITICAL` with the exact offending paths, and compatible
  candidates of the same cycle still upload and commit to state normally
  (`BRAVO_ARCHIV` already treats any non-`COMPLETE` status as a
  not-synchronized component). (P1) Real legacy ResumeSupport semantics
  restored: the targeted upload now explicitly sets
  `TransferOptions.ResumeSupport.State = On` (instead of relying on
  WinSCP's size-threshold default), and the filename validator's file-name
  limit is 246 UTF-8 bytes (255 − 9 bytes for the `.filepart` suffix
  WinSCP appends during resumable transfers; directories remain 255) —
  the exact pair the legacy path has always used with `-resumesupport=on`.
  Previously a 247–255-byte name passed validation and would fail
  mid-transfer; resume support is deliberately not disabled to win those
  9 bytes back. (P2) Checkpoint replacement now works after the first
  cycle: `Session.MoveFile` cannot portably overwrite an existing target
  on SFTP, so from the second cycle on every publish would have failed.
  The publish flow is now upload-to-temp, explicit `RemoveFiles` of the
  existing canonical checkpoint (engine-owned telemetry only — never data),
  then rename. This is deliberately documented as non-atomic: a reader may
  briefly observe the checkpoint absent during replacement, but never a
  partially written one; the self-test fake session now models the
  rename-target-exists failure so any code relying on rename-overwrite
  fails in tests rather than in production. (P2) Mutation detection now
  matches its own stated contract: a `Verified` path whose size OR
  `LastWriteTimeUtc` changed is a `MUTATION_VIOLATION` under
  `MutationPolicy = "Fail"` (previously only size was compared, so an
  append-only file rewritten with identical size but a new mtime silently
  kept its trusted skip). String-equality fast path keeps the 100k-file
  plan cost unchanged; unparseable historical timestamps fail visible as
  mutation rather than being silently trusted. This is still not
  timestamp-only discovery: a path absent from state remains NEW and
  uploads regardless of its timestamp. 15 new behavioral self-tests; all
  round-1 invariants (STATE_NOT_INITIALIZED zero-upload, Archive-only
  corrupt-state reconciliation, lock Busy-vs-Error, Fast Health success
  whitelist, no full `CompareDirectories` on normal cycles, no `-delete`)
  re-verified by the existing suite.
- `BRAVO.BazaSync` hardening round 3 (independent post-review before
  production acceptance). (P1) IncrementalAppendOnly can no longer
  silently overwrite an already existing remote BAZA file: WinSCP's
  `TransferOptions.OverwriteMode` defaults to `Overwrite` and the targeted
  upload had no pre-upload check of the remote file itself, so a candidate
  not yet `Verified` in local state whose remote path already existed
  (most importantly the crash window: remote `PutFiles` succeeded →
  `Save-BRAVOBazaState` failed → next cycle re-sees the candidate) would
  be re-uploaded over the existing immutable file. Each `ToUpload`
  candidate now gets one targeted `FileExists` first: remote absent →
  normal upload; remote present with the same size → recovered without
  any `PutFiles` call, committed `Verified=true` and counted as
  `RecoveredRemote` (the cycle can be `COMPLETE`); remote present with a
  different size → explicit `Status=REMOTE_CONFLICT` with
  `RelativePath`/`LocalSize`/`RemoteSize` per conflict, zero `PutFiles`
  for that candidate, no successful-cycle provenance advance, no
  checkpoint publication, Health `CRITICAL` naming the exact path and
  both sizes. Overwriting is never a default policy — any future
  overwrite support would have to be a separate, explicitly named
  operator policy. Verified/TrustedSkip entries get no remote lookup at
  all, preserving the 100000-verified-plus-10-candidates cost profile (no
  `CompareDirectories`, no `synchronize -preview`, no full tree scan).
  (P2) The checkpoint-replacement `RemoveFiles` result is no longer
  discarded: WinSCP reports per-file removal failures in the operation
  result without throwing, so a failed removal now yields
  `CheckpointPublished=false` (WARNING; the previous checkpoint stays
  intact) instead of claiming a successful replacement.
  (P2) `Update-BRAVOBazaSyncResultNewAfterCutoff` now also counts the
  local-only NewAfterCutoff diagnostic for `INCOMPATIBLE_NAME` and
  `REMOTE_CONFLICT` cycles (state is saved in both). (P2) When mutation
  violations and incompatible names (and/or remote conflicts) coexist in
  one cycle, Fast Health surfaces every non-empty category in the same
  run — one remains the primary Status/Message, the others appear in
  Info instead of being discovered only on the next cycle. 14 new
  behavioral self-tests, including the crash-recovery acceptance
  (`CrashAfterRemoteUploadBeforeStateCommitDoesNotReupload`) and
  remote-lookup scoping proofs.
- `BRAVO.BazaSync` hardening round 4 (independent post-review of the
  Full Audit × AlreadyRemote interaction). (P1) A current-cycle Full
  Audit pending verdict now overrides generic same-size AlreadyRemote
  recovery. Production Full Audit compares with `-criteria=time,size`
  and reports both `UploadNew` and `UploadUpdate`, but
  `ConvertTo-BRAVOBazaFullAuditResult` reduced everything to
  "already matching" and lost the pending action — so a file the audit
  explicitly flagged as `UploadUpdate` (same size, different mtime on
  the remote) would fall through the planner to the round-3 candidate
  precheck, match by size, be "recovered" as `AlreadyRemote`/`Verified`
  and silently cancel the audit's own drift finding (the same flaw
  applied to bootstrap seeding of pending-but-size-matching remote
  files). The adapter now preserves `PendingItems`
  (`RelativePath`/`Action`/`Reason`); the synchronization cycle keeps a
  current-audit pending map, and any pending candidate is excluded from
  generic recovery: remote absent → normal upload + verification;
  remote present → explicit `Status=AUDIT_DRIFT` carrying the audit
  Action/Reason and local/remote sizes, zero `PutFiles`, never an
  overwrite, no successful-cycle provenance advance, no checkpoint,
  Health `CRITICAL` naming the path, action and both sizes.
  `LastFullAuditUtc` still advances on such a cycle (the audit itself
  completed successfully and found drift — audit freshness is not
  synchronization success and is deliberately not conflated with
  `LastSuccessfulSyncUtc`). Since round 5 the verdict is persisted per path (see the round-5
  entry below) rather than scoped to the audit cycle only; no extra
  remote scans are introduced. When no current
  audit flags the candidate, same-size crash recovery keeps working
  unchanged. (P2) `NewAfterCutoff` now means actually-after-cutoff:
  membership is decided by the cycle snapshot (a lightweight
  `CutoffSnapshotRelativePaths` list on the SyncResult) instead of
  "absent from persisted state" — pre-cutoff candidates deliberately
  not stored in state (incompatible names, remote conflicts, audit
  drift, failed/pending) are no longer miscounted as new, while a file
  added after the snapshot with a backdated `LastWriteTime` still
  counts (timestamps are never the membership test); the previous
  round-3 expectation was corrected accordingly. (P2) The single-writer
  assumption is now documented: `FileExists → PutFiles` is not a
  distributed atomic operation and the BAZA lock is machine-wide, so
  IncrementalAppendOnly requires exactly one writer per managed BAZA
  remote root; the target-existence check is additionally repeated
  immediately before `PutFiles` (after remote directory preparation) to
  minimize the TOCTOU window, and no absolute distributed no-overwrite
  guarantee is claimed. 13 new/updated behavioral self-tests.
- `BRAVO.BazaSync` hardening round 5 (final production-acceptance
  review). (P1) `AUDIT_DRIFT` is now sticky across cycles. Round 4 kept
  the audit pending map only in memory for the cycle the audit ran in,
  so after an `AUDIT_DRIFT` cycle the persisted state carried only
  `Verified=false` — the next plain incremental cycle (no audit of its
  own) saw an ordinary unverified candidate, found the remote path
  existing with a matching size and generic-recovered it to
  `Verified=true`, allowing a `COMPLETE`/healthy cycle even though
  nothing changed since the authoritative audit reported drift (a
  false-green window until the next periodic audit, explicitly called
  out as unacceptable). An `AUDIT_DRIFT` outcome now persists a minimal
  per-path blocker inside the file's state entry
  (`BlockReason="AuditDrift"`, `AuditAction`, `AuditReason`,
  `AuditDetectedUtc` — the original detection time is preserved on
  re-encounters; the state file's Save/Read pass extra entry fields
  through unchanged, so no schema bump). Every upload-phase candidate
  check now consults both the current-cycle audit map and the persisted
  blocker: a blocked path with the remote still present stays
  `AUDIT_DRIFT` (zero `PutFiles`, no provenance advance, no checkpoint,
  Health `CRITICAL`) on every subsequent normal cycle. The blocker is
  cleared only by positive resolution: a later Full Audit confirming
  the path as matching re-seeds a clean `Verified=true` entry, or the
  remote file disappearing followed by a successful targeted
  upload+verification; a mere size match never clears it — that is
  precisely the evidence the audit already proved insufficient.
  Bootstrap and corrupt-state reconciliation persist the same blocker
  (an audit-pending path is never left absent from state where the next
  cycle could generic-recover it). Ordinary unverified/pending entries
  carry no blocker, so round-3 crash recovery
  (upload-succeeded/state-save-failed → same-size `AlreadyRemote`)
  is preserved and re-verified. (P2) `NewAfterCutoff` now distinguishes
  a valid empty snapshot from an unavailable one:
  `CutoffSnapshotRelativePaths` is `$null` when no snapshot was
  captured (only then does the legacy persisted-state fallback apply)
  and `@()` for a genuinely empty directory at cutoff — an empty
  snapshot is authoritative, so a file (re)appearing after it counts as
  new even if an older persisted state still remembers it. 12 new
  behavioral self-tests.
- `BRAVO.BazaSync` hardening round 6 (production-acceptance review of
  the sticky-blocker failure paths). (P1) A persisted AuditDrift blocker
  no longer disappears with its local path: the planner iterates only
  the snapshot, so a blocked entry whose local file vanished was never
  inspected — the cycle could go `COMPLETE`/healthy and publish a
  checkpoint while the authoritative audit verdict stayed unresolved
  (local disappearance is not a positive resolution). Every cycle now
  additionally scans the already-loaded state (purely local, no remote
  calls) for AuditDrift blockers absent from the current snapshot and
  surfaces them as `AUDIT_DRIFT` entries with `LocalMissing=$true` and
  the exact relative path: the cycle stays non-COMPLETE, provenance
  does not advance, no checkpoint publishes, Health stays `CRITICAL`,
  the blocker is retained, and a later Full Audit does not silently
  clear it merely because the source is gone (a restored local path
  remains blocked until genuinely resolved). (P1) A Full Audit trust
  transition now survives a failed final state save via a narrow
  write-ahead marker (`AuditReconciliationPending` in the component
  state — deliberately not a project-wide Durable Journal). Before a
  trust-changing audit the marker is atomically persisted; if that
  persistence fails the audit does not run at all (controlled error).
  The marker is cleared in memory only after integrating audit results
  and reaches disk only with the successful final save — so a crash or
  save failure between the audit and the final save leaves the marker
  on disk, and the previously dangerous window (atomic save preserved
  the old `Verified=true` trust the audit had just revoked in memory,
  letting the next cycle TrustedSkip it back to healthy) is now fail
  closed: standalone Health returns `RECONCILIATION_REQUIRED`
  (CRITICAL, zero uploads, zero TrustedSkip of old Verified entries)
  and the next `BRAVO_ARCHIV` run force-reruns the Full Audit
  reconciliation, clearing the marker only after its own successful
  final save. Ordinary non-audit cycles never write the marker, so
  plain upload state-save failures keep their cheap `INCOMPLETE`
  semantics, and the round-3 crash-recovery acceptance
  (`CrashAfterRemoteUploadBeforeStateCommitDoesNotReupload`) is
  re-modeled as the ordinary-cycle scenario it always described and
  still passes. 14 new behavioral self-tests.
- Fix the first real-SFTP acceptance blocker (DEV-LIMS, scenario 1):
  `BRAVO_ARCHIV` crashed with exit 90 (`The term 'if' is not
  recognized…`) before the BAZA sync phase ever ran.
  `Invoke-BRAVOBazaIncrementalSync` computed its operation timeout as
  `[int]( if … )` — inside plain parentheses `if` parses as a COMMAND
  named "if" (perfectly valid to the AST parser, CI and every syntax
  gate) and only fails at runtime with CommandNotFoundException. The
  self-test suite never executes this wiring function by design (it
  opens a real WinSCP session; everything below it is tested through
  injected fake sessions), so the first execution ever was the real
  server. Fixed to `[int]$( if … )`. A permanent whole-bundle guard now
  closes the entire class: `Diagnostics/NoKeywordParsedAsCommand` parses
  every production script and fails on any `CommandAst` whose command
  name is a statement keyword that can never be a legitimate command
  (`if`/`elseif`/`else`/`switch`/`while`/`do`/`try`/`catch`/`finally`/`until`;
  `foreach`/`where` deliberately excluded as valid pipeline aliases) —
  this guard would have caught the bug at commit time.
- Fix a second defect visible in the same DEV-LIMS acceptance log: the
  per-run retention audit line printed literal `{0}/{1}/{2}` placeholders
  for its first half (`Аудит retention: generation оцінено={0}; …`) —
  `-f` binds tighter than `+`, so only the second concatenated string was
  formatted. Parenthesized the concatenation; a second whole-bundle
  guard (`Diagnostics/NoHalfFormattedStringConcatenation`) now fails on
  any `+` expression whose right operand is a `-f` format while the left
  side still contains unformatted `{N}` placeholders.
- Fix the third real-SFTP acceptance blocker (DEV-LIMS, scenario 1
  retry): after the if-as-command fix the BAZA phase started but hung
  indefinitely — bare interactive `winscp>` prompts leaked to the
  operator console, spawned WinSCP processes sat at ~0 CPU and the log
  stopped at the BAZA sync section header. Root cause:
  `Invoke-BRAVOBazaIncrementalSync` passed the bundle's `$winSCPPath`
  (`Tools\WinSCP.com`, the console CLI stub used by legacy flows)
  straight into `Session.ExecutablePath`, while the WinSCP .NET assembly
  requires `winscp.exe` — with the `.com` stub the child starts an
  interactive console and the session handshake never completes. The
  wiring now resolves the same dll+exe pair the legacy
  `Get-BAZASFTPComparison` has always used
  (`Get-BRAVOWinSCPDotNetComponents`), with a controlled `ERROR`
  SyncResult when no compatible pair is found, and
  `Invoke-BRAVOBazaComponentSyncSession` gained a defense-in-depth
  guard: an ExecutablePath pointing at `WinSCP.com` fails fast with an
  explanatory `ERROR` instead of hanging. Behavioral + structural tests
  added (`ComStubExecutableFailsFastInsteadOfHanging`,
  `ArchiveWiringResolvesRealWinSCPExeForEngine`).
- Fix the fourth real-SFTP acceptance blocker (DEV-LIMS, 2026-08-13,
  scenario 1 retry after the winscp.exe fix). Run facts: MODEL/BLOG/
  BRAVOEXCH archives 3/3, generation COMPLETE, VSS OK, archive SFTP
  upload OK, the WinSCP .NET session reached the real BAZA Full Audit
  path — then `BAZA_APP` incremental ended `ERROR` with
  `CommandNotFoundException: Get-BAZASFTPComparison` raised from inside
  `FullAuditProvider`, post-backup Health `CRITICAL`, exit 50
  `SftpFailed`; scenario 1 is NOT yet PASS. Root cause (reproduced
  empirically on Windows PowerShell 5.1): `.GetNewClosure()` binds the
  provider scriptblock to a new dynamic module — captured variables are
  copied, but command-name lookup of the runtime's private (script-
  scope, non-exported) `Get-BAZASFTPComparison` does not resolve there,
  so the provider failed on its first-ever real invocation across the
  `BRAVO.BazaSync` module boundary. The provider is now built by
  `New-BRAVOBazaArchiveFullAuditProvider`, which captures explicit
  `Get-Command` FunctionInfo references for BOTH calls
  (`Get-BAZASFTPComparison` and `ConvertTo-BRAVOBazaFullAuditResult` —
  a nested module import can be equally invisible from a dynamic
  module) and invokes them via the call operator, and takes URL/host
  key/paths as explicit captured parameters instead of dynamic
  script-scope lookups; `Get-BAZASFTPComparison` stays private. A
  narrow error boundary in the engine now normalizes a provider
  exception into a structured audit failure (`Success=$false`,
  exact cause in `FullAuditError`) instead of a generic session error;
  the write-ahead `AuditReconciliationPending` order is unchanged, so
  the failed DEV-LIMS run correctly left the marker fail-closed on disk
  and the next Archive run force-reconciles. New behavioral tests: the
  production provider is created inside a module with a private fake
  comparison and executed across the module boundary
  (`FullAuditProviderCrossesModuleBoundary`), the closure body is
  guarded against returning to bare private command lookups, and the
  pending-marker recovery chain is re-verified end-to-end with the
  production provider boundary
  (`PendingMarkerRecoveryWorksWithProductionProviderBoundary`).
- Fix the fifth real-SFTP acceptance finding (DEV-LIMS, 2026-08-13):
  the standalone-fallback BAZA sync in `BRAVO.Health.Runtime` passed the
  raw bundle `$winSCPPath` (`Tools\WinSCP.com`) into the engine's
  `-WinSCPExecutablePath` — the same defect as acceptance blocker #3,
  in the second wiring call site. It normally never executes (Health
  reuses the Archive-provided SyncResult), and surfaced only when an
  SFTP authentication failure made Archive skip the BAZA phase, sending
  post-backup Health down its fallback path — where the round-3
  defense-in-depth guard caught the `.com` stub in production and
  failed fast with the exact remediation message instead of hanging.
  The Health wiring now resolves the same dll+exe pair via
  `Get-BRAVOWinSCPDotNetComponents` (controlled `ERROR` SyncResult when
  no compatible pair exists), mirroring the Archive fix. New structural
  test for the Health branch wiring plus a whole-bundle guard
  (`Diagnostics/NoRawWinSCPComPathPassedToEngine`) that forbids passing
  raw `$winSCPPath` into `-WinSCPExecutablePath` anywhere — the same
  defect appeared in two independent call sites, so the class is now
  closed bundle-wide.
- Unified console progress for multi-substep stages in `BRAVO_ARCHIV`
  (UI-only refactor — no backup/VSS/SFTP/BAZA/retention semantics
  changed). New canonical helpers in `BRAVO.Console`
  (`Format-BRAVOSubstepPhase`, `Format-BRAVOElapsedText`,
  `Format-BRAVORunningDetail`) replace ad-hoc phase/elapsed strings
  scattered across the runtime. SFTP archive upload now shows
  component-level substeps (`Завантаження MODEL на SFTP (1 з 3)` with
  the already-known local file size as detail) instead of one generic
  phase — `mdz`+`sha512` of a component are one visible substep and the
  manifest is a separate short phase, so the operator-visible count
  stays `(1 з 3)` rather than `(1 з 7)`; NAS/SMB copy gained the same
  component-level phases; the SHA512 phase carries its component
  position. The running-line wording is unified to `Виконується 7 сек.`
  / `Виконується 1 хв. 24 сек.` (the mixed `Виконується, минуло …`
  variant is removed everywhere) across the 7-Zip, Robocopy, WinSCP
  upload and legacy-sync monitor loops. Documented in
  `docs/MANUAL_RUN_CONSOLE_UX.md`; 6 new self-tests cover the helper
  formats and the component-not-files wiring.
- Maintenance no longer emits a false `WARNING` when
  `range_id_log.json` is checked seconds after this run itself started
  the BRAVO service (observed on the DEV-LIMS acceptance run right after
  a full model restore: service started at 00:09:24, warning at
  00:09:26, file present again minutes later — the service creates the
  file asynchronously after startup). The `[8/8]` range-ID step now
  waits for the file with a bounded retry (up to 30 s, 5 s interval,
  deadline-limited loop) — but ONLY when the file is missing AND the
  BRAVO service was started by this very run; a normal run with the
  file present gets zero added delay, and a run that never touched the
  service keeps the immediate warning as before. Intermediate states
  are logged at `INFO`; if the file still hasn't appeared, exactly one
  `WARNING` explains the startup-wait timeout
  (`Файл контролю діапазонів ID не з'явився протягом 30 сек. після
  запуску BRAVO`) instead of the generic "not found". The startup
  summary line is also reworded — `Контроль діапазонів ID: УВІМКНЕНО;
  поріг >80%; файл: …` — because the old `понад 80% у …` read as if
  usage had already exceeded the threshold, when it only described the
  monitoring threshold. Threshold evaluation, `range_id_log.json`
  format, restore scheduling and WARN-only severity semantics are
  unchanged. New behavioral self-tests cover the no-delay/late-file/
  timeout paths plus structural guards (single final `WARNING`, wait
  gated on the service-start flag, no fallback paths). `TimeoutSeconds`
  is a true upper bound: each sleep is clamped to the remaining budget
  (`min(interval, remaining)`), so the loop can never overshoot the
  deadline by a full extra interval — deadline semantics are
  regression-tested deterministically with a fake clock
  (`Timeout=13/Interval=5` must sleep exactly `5,5,3`).

## 5.0.2 — 2026-08-19

Stable hotfix release promoted from the verified `5.0.2-rc.1` candidate
(RELEASE_POLICY.md §12; accepted HEAD `26de54e`, CI run 32228324024
SUCCESS — self-test, PSScriptAnalyzer, parser/BOM/JSON, gitleaks all
green). No functional runtime changes relative to the accepted
candidate: this promotion removes the prerelease suffix, sets the
stable release channel, updates operator documentation headers, and
regenerates the runtime integrity manifest.

Real-server acceptance (§12.1) on the originally affected production
server (single Fixed drive, 2026-08-19): `BRAVO_DRY_RUN.ps1` including
`-TestAccess` finished 58 PASS / 0 WARN / 0 FAIL, and a full
`BRAVO_ARCHIV.ps1` run completed successfully — the new drive
diagnostics logged the exact previously-crashing profile (one Fixed
drive C:, 177.45 GB free), the free-space preflight passed without any
exception, generation `20260819_121141` reached COMPLETE (3 of 3
archives with verified SHA512 sidecars), 7 of 7 files uploaded to SFTP,
BAZA_APP fully synchronized, health-check reported all backups current.
The same server had produced no backups at all on 5.0.x before this
fix.

Hotfix candidate (RELEASE_POLICY.md §12) for a production incident
observed on 2026-08-19: on any server with exactly ONE local Fixed
drive, the Archive free-space preflight failed every run with
"The property 'Count' cannot be found on this object" and blocked the
entire nightly archive cycle with exit 40 -- a false-positive block
with no real space shortage (the reporting server had 177 GB free
against a 20 GB threshold). Affected releases: 5.0.0, 5.0.0-rc.1 and
5.0.1 -- every deployment of the 5.0.x line on a single-drive server
produced no backups at all.

- Fixed `Get-BRAVOArchiveFreeSpaceResult` in
  `modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1`: the drive list was
  built as `$localDrives = if (...) { @(...) } else { @(...) }`; in
  Windows PowerShell 5.1 an if/else block used as an expression unwraps
  a single-element result back to a scalar on exit -- despite each
  branch's own `@()` -- and the subsequent `$localDrives.Count` throws
  `PropertyNotFoundException` under `Set-StrictMode -Version 2.0`
  (applied by `BRAVO_CONFIG_LOADER.ps1` on every production run).
  The fix wraps the whole if/else expression in a single outer `@()`,
  the only shape that reliably preserves array-ness for 0/1/N elements.
  Reproduced deterministically before the fix and re-verified after.
- Added unconditional diagnostic logging at the start of the
  free-space section: every detected drive (all `DriveType` values,
  not only Fixed) is now logged with type/readiness/format/free/total
  before the check itself runs, so any future failure leaves the log
  showing exactly what the system saw instead of only an exception
  message.
- Added regression self-test
  `Archive/FreeSpaceSingleFixedDriveSurvivesStrictMode`, which invokes
  the real function with exactly one injected Fixed drive under an
  explicit `Set-StrictMode -Version 2.0` -- the pre-existing
  single-drive test could not catch this because the self-test harness
  does not otherwise run at the production StrictMode level.

Cherry-picked from the verified `developer` fix (`274b514`, CI run
green). No other functional changes relative to 5.0.1.

## 5.0.1 — 2026-08-18

Stable hotfix release promoted from the verified `5.0.1-rc.1` candidate
(RELEASE_POLICY.md §12; accepted HEAD `69bf6ff`, CI run 32115265892
SUCCESS — self-test, PSScriptAnalyzer, parser/BOM/JSON, gitleaks all
green). No functional runtime changes relative to the accepted
candidate: this promotion removes the prerelease suffix, sets the
stable release channel, updates operator documentation headers, and
regenerates the runtime integrity manifest.

Validation evidence for the underlying fix: `BRAVO_SELF_TEST.ps1`
PASSED (763 checks, 0 FAIL) both locally and in CI; the new regression
coverage was confirmed to actually catch the original defect by
temporarily reintroducing it (raw `$SlackMode` instead of the effective
`$script:SlackMode` in one of the two webhook preflight gates) and
observing the expected, specific self-test failure, then reverting.
`BRAVO_DRY_RUN.ps1 -TestAccess` confirmed real write/read/delete access
to all production archive/log paths (RuntimeRoot, BackupRoot,
SystemLogRoot, MODEL/BLOG/BRAVOEXCH + `.work`, ProgramData
lock/state); the SFTP and scheduler-state findings in that run reflect
running outside the production `SYSTEM` task-account context and are
not evidence of a regression in this fix. `BRAVO_RESTORE_TEST.ps1`
could not complete in the validation environment (no `COMPLETE`
generation manifest available on that host — its ad hoc local backups
were not produced by a full `BRAVO_ARCHIV.ps1` cycle); this fix does
not touch restore logic, but restore integrity for this cycle remains
otherwise unverified beyond self-test's static/behavioral coverage and
should be confirmed on a real server per RELEASE_POLICY.md §9 if not
already covered by a prior cycle's acceptance.

This hotfix addresses a notification-delivery regression introduced by
the 5.0.0 GENERAL/ALERTS severity-based webhook routing.

- Fixed `-EnableAllSlack`/`-DisableAllSlack` in `BRAVO_MAINTENANCE.ps1`:
  the effective notification mode override was applied to `$script:SlackMode`
  after the GENERAL/ALERTS webhook-route preflight had already resolved
  (and validated) only the routes reachable under the pre-override mode.
  With `NotificationMode` set to `none` or `errors_only` in `BRAVO.config`,
  `-EnableAllSlack` silently became a no-op: every notification attempt
  looked up a route the preflight never resolved, got a `$null` webhook URL,
  and failed silently in the surrounding `try/catch`. The effective mode is
  now computed once, immediately after the raw configured value, and used
  consistently by both the preflight resolution/validation and all runtime
  senders.
- Removed a dead, duplicate notification-webhook resolution block left
  behind in `modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1` by the 5.0.0
  migration to the centralized `BRAVO.Notifications` delivery pipeline — no
  sender read its result; it only performed a redundant Credential Manager
  lookup on every Archive startup.
- Added `.claude` to the runtime-manifest/guard exclusion pattern
  (`ci\Update-BRAVORuntimeManifest.ps1`, `BRAVO_RUNTIME_GUARD.ps1`),
  matching the existing `.git`/`.vscode`/`local-backups` exclusions — AI
  assistant session tooling, not part of the shipped runtime.

## 5.0.0 — 2026-08-11

Stable production release promoted from the verified 5.0.0-rc.1 candidate.
The candidate passed the complete Windows CI pipeline and real-server checks
on Windows Server 2022 / Windows PowerShell 5.1: archive generation and 7-Zip
validation, SHA512 publication, SFTP upload, health-check, maintenance and
notifications. No configuration schema, state schema, credential target,
archive format, retention default, transfer protocol, or supported-OS contract
changed during promotion.

- Archive now performs the same fixed-drive free-space preflight as
  Maintenance before cleanup, local synchronization, VSS, or archive
  generation can mutate state. It uses `Limits.MinimumFreeSpaceGB` and
  `Limits.ExcludedDrives`, reports every checked drive, stops with the
  canonical local-archive exit code `40`, and renders a normal final failure
  summary instead of ending without an operator result.
- A failed Archive free-space preflight now sends one immediate `CRITICAL`
  Discord/Slack notification in `errors_only` or `all` mode. The message
  identifies the affected drive, free/total space, configured threshold,
  action required, log path and exit code. `NotificationMode=none` and
  `-NoSlack` remain authoritative; webhook failure is logged with protected
  secrets and never replaces the primary exit code.
- VSS ownership state and generation manifests are now written through
  temporary files and atomically replaced with legal backup paths compatible
  with Windows PowerShell 5.1/.NET Framework. A failed replacement preserves
  the previous valid state/manifest and cleans temporary backup files.
- Archive publication is fail-closed when the final `.sha512` sidecar cannot
  be written. The already moved archive and any partial sidecar are rolled
  back, published paths/hash fields are cleared, and the failure is classified
  as `PUBLISH`/exit `40` rather than a misleading hash-validation failure.
- Generation finalization now occurs before exit-code calculation and the
  operator summary. Failure to persist the final transfer/health state marks
  the run failed. Result objects also carry stable failure fields, scalar
  success counts are StrictMode-safe, and snapshot paths are initialized per
  component so stale values cannot leak into an exception path.
- Maintenance low-disk termination now renders the standard final summary,
  uses the resolved BRAVO exit code, respects `-NoPause`, and writes unique
  second-and-PID log names. The default scheduled restore day is explicitly
  Sunday (`7`).
- The narrowly required `ExecutionPolicy Bypass` allowance for generated
  manual launchers is documented and scoped to `BRAVO_SETUP.ps1`; all other
  forbidden-pattern checks remain blocking.
- `modules/BRAVO.Notifications/BRAVO.Notifications.psd1` now carries the
  repository-required UTF-8 BOM. A clean GitHub Actions checkout previously
  failed both the explicit BOM gate and the Windows PowerShell 5.1 self-test,
  even though local parser and runtime checks passed on the development host.
- Regression coverage was added for free-space policy and notifications,
  preflight ordering, atomic state replacement, failed SHA512 publication,
  manifest finalization, failure-stage mapping, StrictMode result handling,
  Maintenance early summaries/log naming/default schedule, and launcher
  policy. `RUNTIME_MANIFEST.json` is regenerated from the final RC files.

## 5.0.0-dev.19 — 2026-08-11

Minimal observability/correctness release, from two real DEV-LIMS
acceptance runs of 5.0.0-dev.18, with a review pass applied before
release that replaced an initial, still-independent status-classification
design with one that consumes the actual resolved BRAVO exit code (see
the first two bullets below). Four focused fixes — no backup, restore,
VSS, SHA512, retention, MANIFESTS, transfer, notification routing,
`NotificationMode`, scheduler, or exit-code numerical semantics
changed; Range ID missing-file warning-only semantics untouched.

- Maintenance's final human-readable status (log `=== СТАТУС: ... ===`,
  console `РЕЗУЛЬТАТ` "Статус" field, and the success/warnings-branch
  Discord/Slack notification) now derives from the SAME resolved BRAVO
  exit code that the process actually exits with — not from an
  independent re-check of `$script:criticalErrorOccurred`/
  `$script:BRAVOWarningCount`. `Get-BRAVOMaintenanceResolvedExitCode`
  is the one place that priority policy (critical > warnings > success,
  40/41/60 via `Resolve-BRAVOExitCode`) lives; `Get-BRAVOMaintenanceFinalStatus
  -ExitCode <resolved code>` is a pure function that classifies that
  number via `Get-BRAVOExitCodeName` (`Success`/`SuccessWithWarnings`/
  anything else) into text/color — it no longer inspects the two flags
  itself. The exit-code resolution was also moved earlier: it now runs
  immediately after the outer try/catch closes (all business operations
  and fail-safe handling, including the catch's own critical-flag set,
  have already completed) and before the LOG `=== СТАТУС ===` line is
  written, not after it as in the first cut of this fix — so the LOG
  can no longer read a value computed from a different, earlier
  snapshot than the process's actual exit code. `Send-FinalReport`'s
  notification runs earlier still (inside the try, before its catch),
  so it takes its own snapshot through the same canonical resolver;
  if a later unhandled exception changes the outcome, the real,
  later-computed `$script:maintenanceRuntimeExitCode` — not this
  notification — governs the process exit code, exactly as before. A
  real run with a missing Range ID log (`Test-RangeIdUsage`'s existing
  `WARNING`-only path — unchanged) resolved exit code 10
  (`SuccessWithWarnings`), but the LOG/console/notification all said
  `УСПІШНО` with no mention of the warning; they now say `УСПІШНО З
  ПОПЕРЕДЖЕННЯМИ` (the console previously said `ЧАСТКОВО` for the same
  condition). `ПОМИЛКА` (any of 40/41/60, or any other non-success/
  non-warning code) and plain `УСПІШНО` are unchanged.
- The warnings notification no longer pairs a ✅ icon with "Дій не
  потрібно" (no action needed) — `New-MaintenanceNotificationMessage`'s
  severity classification now checks its canonical `:warning:` marker
  before the `Title`-text "УСПІШ" match (previously the text match
  always won, so a warnings-flavored Title with an explicit `:warning:`
  emoji still classified as SUCCESS). The rendered notification for
  warnings now shows `:warning: BRAVO MAINTENANCE — ПОТРІБНА ДІЯ` /
  "Потрібна дія: перевірити журнал BRAVO_MAINTENANCE." — the repository's
  existing warning-severity wording (same two fixed strings the other
  `:warning:`-emoji call site, `Send-InactiveServiceWarning`, already
  produces), not literal Title text. Plain success is unaffected (still
  `:white_check_mark:` / "Дій не потрібно"); routing, `NotificationMode`,
  `allowed_mentions`, timeout, and delivery mechanics are untouched.
- Maintenance runtime-log bare `"==="` separators — Maintenance's own,
  separate `Write-Log`/`Write-BRAVOMaintenanceLogFile` implementation,
  not shared with Archive's dev.18 fix — no longer write a log record.
  Root cause: `Write-BRAVOMaintenanceLogFile -Entry ("=" * $SeparatorLength)`
  built a literal 100-character `====...====` row with zero diagnostic
  value, always immediately adjacent to a real `"=== HEADING ==="` call
  that already logs the same moment with full text. Applied uniformly
  to every bare `"==="` call site, including the start/end banners —
  the same call, same `"==="` argument, with no separate "banner-only"
  code path in the source. Meaningful `=== HEADING ===` records
  (ДЖЕРЕЛА ЖУРНАЛІВ, ПЕРЕВІРКА ВІЛЬНОГО МІСЦЯ, ЗУПИНКА СЛУЖБ, ПЕРЕВІРКА
  РОЗМІРІВ .MD ФАЙЛІВ, РЕСТАВРАЦІЯ МОДЕЛІ, ОБРОБКА TRACE-ФАЙЛІВ, ОБРОБКА
  ЛОГІВ EXCHANGAPI, ВІДНОВЛЕННЯ ПОЧАТКОВОГО СТАНУ СЛУЖБ, ОЧИСТКА СТАРИХ
  ДАНИХ, ВІДПРАВКА ПОВІДОМЛЕННЯ ПРО ПОДІЮ, and both banner headings)
  are completely unchanged.
- Archive's VSS diagnostic log line ("Узгодженість архівів: ...") is
  now factually correct. It said "окремий VSS-знімок для кожного
  компонента" (a separate snapshot per component), while the runtime
  has always created exactly one VSS Snapshot Set per generation
  (`New-BRAVOVSSSnapshotSet`), shared by every enabled component
  (MODEL/BLOG/BRAVOEXCH) — the same terminology `BRAVO_DRY_RUN.ps1`
  already uses. This was flagged as a known, deliberately-deferred
  issue in the dev.18 changelog entry above; it is fixed here. Text
  only — VSS creation/cleanup, `SnapshotContext`, `SnapshotSetId`,
  volume discovery, snapshot lifetime, and generation semantics are
  unchanged.
- Archive's `=== СТВОРЕННЯ ХЕШУ <компонент> ===` heading now prints
  immediately before the first hash-generation action
  (`New-SHA512Hash`), inside `Invoke-BRAVOComponentBackup` itself,
  instead of in `Main` after the entire component backup (create +
  hash + verify + publish) had already finished. A real run's log
  showed the heading appearing after the work it described. The single
  call site (`Invoke-BRAVOComponentBackup`, inside the `foreach
  ($archive in $readyArchives)` loop) means the fix applies uniformly
  to every enabled component without per-component duplication. Moving
  the heading also fixes log component attribution for free:
  `Resolve-BRAVOLogComponentFromHeader`/`Set-BRAVOLogComponent` now
  switch `$script:BRAVOLogComponent` to `HASH` before, rather than
  after, the hash work. SHA512 computation, sidecar filename/encoding,
  integrity verification, archive publication, generation-COMPLETE
  rules, and transfer ordering are unchanged.
- Tests: 20 new checks — `Maintenance/Exit0RendersSuccess` /
  `Exit10RendersSuccessWithWarnings` / `Exit40RendersFailure` /
  `Exit41RendersFailure` / `Exit60RendersFailure` (functional calls to
  the real, isolated `Get-BRAVOMaintenanceFinalStatus -ExitCode`, one
  per code Maintenance can actually produce); `Maintenance/FinalStatusConsumesResolvedExitCode`
  (AST proof `Get-BRAVOMaintenanceFinalStatus`'s own body never
  references `$script:criticalErrorOccurred`/`$script:BRAVOWarningCount`,
  `Get-BRAVOMaintenanceResolvedExitCode` genuinely calls
  `Resolve-BRAVOExitCode`, and the LOG/console assignments occur in
  source AFTER `$script:maintenanceRuntimeExitCode`'s one assignment —
  actual data flow, not just co-located text); `Maintenance/FinalStatusDoesNotCallIndependentWarningPolicy`
  (the `УСПІШНО З ПОПЕРЕДЖЕННЯМИ` literal exists exactly once in the
  source, and the helper is called from exactly its three consuming
  sites); `Maintenance/WarningsNotificationUsesWarningMarkerNotSuccess`
  / `PureSuccessNotificationUnaffectedBySeverityReorder` (real,
  isolated `New-MaintenanceNotificationMessage` calls confirming the
  ✅/⚠️ + operation/action-text consistency fix, and that it leaves the
  plain-success rendering unchanged); `Maintenance/RangeIdMissingRemainsWarningOnly`
  (`Test-RangeIdUsage`'s missing-file branch untouched: one `Test-Path`,
  no `New-Item`, `WARNING`-level); `Maintenance/SectionSeparatorsDoNotEmitBareLogRecords`
  / `SectionHeadingsRemainLogged` / `RuntimeLogHasNoRedundantSeparatorOnlySections`
  (structural proof of the bare-separator branch plus a real functional
  round-trip through Maintenance's own `Write-Log` into a temp file);
  `Archive/VssDiagnosticDescribesSingleGenerationSnapshotSet` /
  `VssDiagnosticDoesNotClaimPerComponentSnapshots` /
  `VssBehaviorCodeUnchangedByDiagnosticFix` (AST call-count proof that
  `New-BRAVOVSSSnapshotSet`/`Remove-BRAVOVSSSnapshotSet` are untouched);
  `Archive/HashHeadingPrecedesHashWork` /
  `HashHeadingPrecedesHashWorkForAllEnabledComponents` /
  `HashLogsUseHashComponentAfterHeading` /
  `HashBusinessCallsRemainUnchanged` (AST source-order proof plus a
  real functional round-trip confirming the HASH component tag). Two
  pre-existing tests were updated in place: `Maintenance/FinalSummarySuccess`
  (dev.14, asserted the now-superseded `ЧАСТКОВО`/independent `elseif`
  wording) and `ConsoleUX/21-ExitCodeComputedBeforeRender` (dev.16,
  its Maintenance anchor text matched the old inline exit-code
  assignment); two source-order tests (`Maintenance/FinalSummaryOccursBeforeManualPause`,
  `Maintenance/PostOperationsPrecedeFinalSummary`, both dev.15) picked
  up the same new anchor automatically since they reuse the shared
  index variable. Full suite: 713/713.

## 5.0.0-dev.18 — 2026-08-10

Minimal operator-flow/observability correctness release, from a real
manual DEV-LIMS `BRAVO_ARCHIV` 5.0.0-dev.17 run. Three related defects,
tightly scoped — no backup, VSS, retention-policy, MANIFESTS, transfer,
notification, scheduler, or exit-code semantics changed. (A separate,
already-known factual VSS diagnostic-wording issue — "Узгодженість
архівів: окремий VSS-знімок для кожного компонента", while the runtime
actually uses one Snapshot Set per generation — is intentionally **not**
addressed here; it will be handled separately.)

- Manual Archive/Health/Maintenance operator executions no longer skip
  the configured exit pause solely because stdin is reported as
  redirected when a usable interactive console exists. The real run's
  header correctly said `MANUAL`, but the window closed immediately
  after the final RESULT instead of waiting — `Wait-BRAVOManualExit`
  (`BRAVO.Console`, shared by all three runtimes) treated
  `[Console]::IsInputRedirected` as an independent, unconditional
  reason to skip the pause, before `$Host.UI.RawUI.ReadKey(...)` (which
  reads the console input buffer directly and does not depend on
  stdin redirection) ever got a chance to run. `-NoPause` remains the
  authoritative scheduled/automation pause bypass (`BRAVO_TASKS_INSTALL.ps1`
  adds it to every scheduled task; the Maintenance→Archive child launch
  and the self-test both already use it explicitly), and
  `consoleSettings.PauseOnExit = $false` remains the explicit
  configuration bypass — neither changed. `RawUI.ReadKey` stays
  primary, `Read-Host` stays its ISE/non-console fallback.
- Archive old-log cleanup (`Очищення старих журналів`) and
  backup-generation cleanup (`Очищення старих backup generation`) now
  participate in the same dynamic `[N/M]` numbered-step sequence as
  every other operator-visible Archive operation, instead of rendering
  as unnumbered rows outside the canonical sequence. Old-log cleanup is
  always evaluated and always occupies one step; generation cleanup
  occupies one step only when the existing enablement expression
  (`enableArchiveDeletion -or enableFailedArchiveDeletion -or
  enableLunchArchiveCleanup` — unchanged) is true, and no step at all
  when fully disabled. The dynamic step `Total` and the `План операцій:`
  entries were already driven by the same flags and needed no semantic
  change, only the two cleanup operations' own render call
  (`Write-BRAVOOperationResult` → `Write-BRAVOArchiveStep`). Execution
  order is unchanged — only which renderer each call uses.
- Empty structured Archive runtime-log records used only as visual
  section separators (`timestamp [INFO] [COMPONENT]` with a blank
  Message — one per section transition: STARTUP, CREDENTIALS, VSS,
  SFTP-ARCHIVE, PATHS, ARCHIVE, HASH, BAZA_APP, SUMMARY, ...) are no
  longer emitted. Root cause: the bare `"==="` separator (always
  immediately adjacent to a real `"=== HEADING ==="` call, which
  already logs the same moment and component with full text) built its
  log line as `"=" * $SeparatorLength`, and the `$SeparatorLength`
  default resolved to an empty string in this call path. Rather than
  chase that resolution further, the bare-separator branch of Archive's
  `Write-Log` shim now simply does not write a log record at all — the
  adjacent heading already carries the section-transition information,
  so no diagnostic value is lost. Meaningful `=== HEADING ===` records
  (`=== ОПЦІЇ СКРИПТА ===`, `=== АРХІВАЦІЯ MODEL ===`, `=== ЗАВЕРШЕННЯ
  РОБОТИ СКРИПТА ===`, etc.) are completely unchanged. Timestamp/level/
  component format, log file paths, retention, and console thresholds
  are untouched; shared `BRAVO.Logging` was not modified.
- Tests: ~19 new/updated checks — `Console/ManualExit*` (NoPause and
  PauseOnExit=false bypass functionally via real, non-blocking calls to
  `Wait-BRAVOManualExit`; structural proof `IsInputRedirected` is no
  longer a standalone pre-check while `UserInteractive` remains one;
  RawUI/Read-Host fallback intact), `Archive/ManualModeAndPauseUseSameNoPauseContract`
  (Archive/Health/Maintenance all delegate to the one shared helper, no
  duplicated `RawUI.ReadKey`), `Archive/*CleanupUsesNumberedStep*` /
  `DynamicTotalIncludesCleanupOperations` / `PlanAndCleanupStepsShareEnablementSemantics`
  / `CleanupNoWorkRendersSkipped` / `CleanupOperationsNoLongerUseUnnumberedRenderer`,
  and `Logging/RuntimeLogHasNoEmptyStructuredRecords` (a real functional
  round-trip through Archive's `Write-Log` and `BRAVO.Logging` into a
  temp file, asserting no physical line has an empty Message) plus
  `Archive/SectionSeparatorsDoNotEmitEmptyLogEvents` /
  `SectionHeadingsRemainLogged`. Two pre-existing dev.16 tests
  (`Archive/LogCleanupIsUnnumberedOperation`, `Archive/BackupRetentionCleanupAggregatesSubCleanup`)
  and one dev.16 Console test (`ConsoleUX/13-RedirectedNonInteractiveSkipsWait`)
  were updated in place, since their assertions encoded exactly the
  now-corrected (unnumbered renderer / IsInputRedirected-as-blocker)
  behavior. Full suite: 693/693.

Note: `BRAVO.Maintenance.Runtime.ps1` has its own, separate copy of the
same bare-`"==="`-separator pattern (`Write-BRAVOMaintenanceLogFile
-Entry ("=" * $SeparatorLength)`), which may have the same defect. It
was deliberately left untouched here — out of scope for this
Archive-focused release ("do not change Maintenance business logic");
worth a follow-up look separately.

## 5.0.0-dev.17 — 2026-08-10

Minimal correctness fix on top of dev.16, from a real DEV-LIMS
acceptance run (generation `20260810_185725`, backup ~18:57 local
server time). Health confirmed all components and SFTP `OK` for that
generation — but the Discord success notification showed `🕒 Остання
резервна копія: 10.08.2026 15:57` next to a correct `⏳ Вік копії: 5
хв.`. Generation selection, backup-age calculation, and UTC
normalization were all correct; only the human-readable absolute
timestamp was wrong — it rendered the internally normalized UTC value
(`15:57`) as if it were the server's local time (`18:57`).

- `Get-BRAVOHealthLatestBackupSummary` (`BRAVO.Health.Runtime.ps1`):
  `TimestampText` now converts the UTC timestamp to local time
  (`.ToLocalTime()`) immediately before formatting — the internal
  model, `AgeText` (still `Format-BackupAge`/`Get-BRAVOUtcAge` on the
  raw UTC value), and generation selection are all unchanged. This is
  the single point both the success (`Остання резервна копія`) and
  problem (`Остання успішна резервна копія`) notification builders
  read `TimestampText` from, so both are fixed by the one change — no
  duplicated timezone-conversion logic.
- Manifest `createdAt`/`startedAt` semantics, `ConvertTo-BRAVOUtcDateTime`,
  backup generation selection, `MaxBackupAgeHours`, retention, MANIFESTS
  lifecycle, archive format, VSS, SFTP/SMB, BAZA synchronization, Health
  PASS/WARN/FAIL logic, notification routing/mode, and exit codes are
  all unchanged.
- Tests: `Health/LatestBackupTimestampRendersLocalTime` (functional —
  reproduces the exact DEV-LIMS numbers via `[datetime]::SpecifyKind`,
  timezone-independent, no hardcoded UTC+3),
  `Health/BackupAgeStillUsesUtcSemantics` (confirms `AgeText` is
  unaffected), `Health/SuccessAndProblemNotificationsReuseLatestBackupTimestamp`
  (confirms both notification builders share the one conversion point).
  Full suite: 679/679.

## 5.0.0-dev.16 — 2026-08-10

Minimal PowerShell 5.1 / `Set-StrictMode` reliability fix on top of the
published dev.15: no operator-console/UX change, no MANIFESTS/retention
policy/business-semantics change.

Real DEV-LIMS dev.15 acceptance confirmed `[1/8]`..`[8/8]`, the `[5/8]`
Restore `SKIPPED` line, the `[8/8]` Range ID single-render, and the final
summary printing before the manual pause — all as designed. But after
`[8/8]`, cleanup threw `The property 'Count' cannot be found on this
object. Verify that the property exists.` The dev.15 fail-safe catch
(finalization block introduced in dev.15) correctly turned this into a
critical run (exit 60) and still printed the final summary — exactly the
behavior it was built for — but the underlying exception itself is now
fixed at its root cause.

- `Remove-OldRestoreArchives`: two `Where-Object` pipelines that can
  legitimately return exactly one match (`$beforeCount`/`$afterCount`, the
  before/after archive count for a kept restore session) now materialize
  their result as an array via `@(...)` before `.Count`. Under
  PowerShell 5.1 with `Set-StrictMode` active (inherited from the
  configuration loader, per existing project convention — see the
  `PropertyNotFoundStrict` precedent already fixed for `$missingDirs` in
  the same file), a single-result pipeline returns a scalar object instead
  of a collection, and `.Count` on that scalar throws exactly the observed
  error. Same fix applied to `$remainingFiles` (the post-deletion "what's
  left" debug listing), which had the identical `Get-ChildItem` +
  unwrapped `.Count` shape.
- Scope: only `Remove-OldRestoreArchives` was audited and only these two
  call sites needed the fix — every other `.Count` in that function was
  already array-wrapped at assignment (`$mainArchiveFiles`, `$sortedGroups`,
  `$groupsToKeep`, `$groupsToDelete`, `$staleInvalidGroups`), and
  `$group.Count` (a `Group-Object` `GroupInfo.Count`) is a real, always-safe
  property left untouched. No repository-wide sweep.
- The dev.15 fail-safe finalization (outer `try/catch` around Range ID /
  cleanup / `BRAVO_ARCHIV` / auto-shutdown / final-report, non-empty
  swallow-catch bodies) is unchanged — it already did its job correctly
  for this exact real-world exception and stays as the safety net for any
  future one.
- Tests: 4 new isolated regression checks for `Remove-OldRestoreArchives`
  (real function via AST extraction, synthetic TEMP directories — never
  production DEV-LIMS paths — running under a real `Set-StrictMode
  -Version Latest` inside the invocation, reproducing the exact failure
  condition rather than simulating it): a single-result `before`/`after`
  count each reads back as `1` without throwing, a single remaining file
  after deletion doesn't throw, and the whole call completes cleanly under
  strict mode with a single-item pipeline result.

**Operator-visibility pass** (still dev.16, unpublished): closes the gap
where four top-level `BRAVO_MAINTENANCE.ps1` operations that really run
every time had no console execution result — LOG-only. The approved
`[1/8]`..`[8/8]` contract, `Initialize-BRAVOMaintenanceSteps -Total 8`
(literal), MANIFESTS, and retention semantics are all unchanged; none of
the four gets a `[N/8]` number or touches the step counters.

- `Write-BRAVOOperationResult` (new, `BRAVO.Console`): the same
  alignment/status/duration/details contract as the numbered-step
  renderer, minus the `[N/TOTAL]` prefix (6-space indent instead) and
  without touching step counters — for top-level operations that are
  real but intentionally outside the numbered contract.
- Legacy log migration, old-data cleanup, the `BRAVO_ARCHIV.ps1` launch,
  and auto-shutdown scheduling each now print a `SKIPPED`/`OK`/`WARN`/
  `FAIL` result line (with a short `-Details` reason on warning/failure),
  in their existing execution position — migration keeps running between
  directory creation and service stop, cleanup/archive/shutdown keep
  running after `[8/8]`. `Invoke-AutoShutdown` now returns a symbolic
  final state — `Scheduled`/`Cancelled`/`Failed` — instead of a plain
  boolean, so the console line reflects what actually happened
  (including the operator interactively cancelling an already-scheduled
  shutdown) rather than only "the command was issued." The interactive
  confirm/cancel dialog and the shutdown command itself are untouched.
- `План операцій:` gained `Очистка старих даних/логів` (always `ТАК` —
  the check runs unconditionally every invocation, there is no on/off
  flag for it; a run with nothing stale still renders `SKIPPED` on the
  operation itself).
- Exact failure attribution: `$script:currentMaintenanceOperation` is set
  before Range ID / cleanup / archive / auto-shutdown / final-report, so
  the dev.15 fail-safe catch now logs "Помилка операції ...<operation
  name>..." instead of the generic "Range ID/очистка/BRAVO_ARCHIV/
  AutoShutdown/фінальний звіт" list. If the exception happened inside an
  operation that has its own result line and that line never printed, the
  catch prints its `FAIL` exactly once (a `*Reported` flag per operation
  prevents a double print).
- The `RunMissedRestoreOnly`-with-nothing-pending recovery path no longer
  exits with a bare `exit 0` and no summary at all: it now prints a
  compact `BRAVO MAINTENANCE — УСПІШНО` / `Код завершення` / `Результат`
  / `Журнал` summary first (still no `[1/8]`..`[8/8]` — there is no real
  work this run) before the same outer `finally` → `Wait-BRAVOManualExit`
  as every other exit path.
- Tests: 21 new checks (plan wiring/order, each operation's unnumbered
  render and SKIPPED/OK/WARN/FAIL branches, step-total/counter isolation,
  render ordering after `[8/8]` and before the final summary, exact
  failure attribution, single-print-on-failure, and the recovery no-op
  summary) — all via source/AST inspection or direct calls to the real,
  side-effect-free `Write-BRAVOOperationResult`, never by running the
  real `Main()` or the real `Invoke-AutoShutdown` (which would issue an
  actual `shutdown` command). Two pre-existing dev.15 tests
  (`Maintenance/FinalSummaryOccursBeforeManualPause`,
  `Maintenance/FinalSummaryContainsOnlyApprovedFields`) had their source
  search bounded to start after the outer-try marker, since
  `Write-BRAVOFinalSummaryHeader`/`Footer` now also appear once, earlier,
  in the new recovery-path summary — both still pass unchanged.

**Archive/Health operator-visibility pass** (still dev.16, unpublished):
extends the same numbered-step/unnumbered-operation contract to
`BRAVO_ARCHIV.ps1` and `BRAVO_HEALTH.ps1` so real top-level operations
and checks stop being LOG-only. No backup format, retention period,
MANIFESTS lifecycle, SFTP/SMB protocol, notification routing, or
exit-code semantics change.

- `Write-BRAVOPlan` (new, `BRAVO.Console`): shared `План операцій:`/
  `План перевірок:` renderer for Archive and Health, matching the
  Maintenance plan layout/style (Maintenance itself keeps its own
  existing render, untouched) — both now render through it instead of
  their own raw `Write-Host` — Health has none at all (`Console/
  HealthRendersNoRawWriteHost`).
- Archive: `План операцій:` now reflects the same effective flags that
  drive the dynamic step `Total` (BAZA_APP/BAZA_WWW local sync,
  per-archive components, SFTP/SMB transfers, log/retention cleanup,
  post-backup Health). Local BAZA_APP/BAZA_WWW synchronization each get
  their own numbered step when enabled. `Перевірка шляхів` now renders
  strictly after both the path-existence checks and the SYSTEM write/
  read access preflight complete — previously it rendered `OK` right
  after the existence checks, before the preflight could still cancel
  the run. Old-log cleanup (`Remove-OldLogsByAge`) and backup-generation
  retention cleanup (`Remove-BRAVOExpiredBackupGenerations` +
  `Remove-OldLunchArchives`, aggregated into one operation, not one row
  per internal filter) both now print `Write-BRAVOOperationResult` lines;
  retention renders `OK` with a factual delete-count aggregate only when
  something was actually removed, `SKIPPED` otherwise — no invented
  counts. `-SyncBAZA` (a separate, SFTP-only manual-sync flow) is
  confirmed isolated: its own `Initialize-BRAVOArchiveSteps`/steps run
  and `return` before the new Plan/Total code path.
- Health: standalone runs (not embedded in Archive) now show a `План
  перевірок:` before the first check. The combined `BAZA (локальна
  копія)` and `SFTP` steps are split into independent dynamic steps —
  `BAZA_APP (локальна копія)`/`BAZA_WWW (локальна копія)` and `SFTP:
  резервні копії`/`SFTP: BAZA_APP`/`SFTP: BAZA_WWW` — each gated by its
  own enable flag and counted in `Total` exactly once;
  `Get-SFTPHealthIssues` still runs a single WinSCP session per call, its
  already-returned issue list is partitioned by the existing `Component`
  field, and a shared connection-prerequisite failure attaches to every
  enabled SFTP step (logged once, not once per step). `Керовані
  служби`/`Локальні резервні копії` stay single steps but gain a compact
  `служби: ...`/`компоненти: ...` detail line built from the issues'
  existing `Location`/`Component` fields. Dynamic `Total` is now the
  literal sum of the flags gating each step render
  (`Health/StepTotalMatchesVisibleEnabledChecks`); the
  `Complete-BRAVOHealthResult` notification off-by-one invariant, the
  embedded (`-SuppressHeader`) path, and `$script:BRAVOHealthSftpStepEnabled`
  (still consumed by the standalone summary footer) are all unchanged.
- Fixed a real bug introduced while adding the retention-cleanup delete
  counters: `[ref]`-typed parameters permanently type-constrain the
  variable for the rest of the function in PowerShell, so a same-named
  (case-insensitively) local counter silently gets re-wrapped into a new
  `PSReference` on every assignment instead of staying a plain `int`.
  `Remove-OldLunchArchives`'s pre-existing `$deletedCount` collided with
  the first draft of its new `[ref]$DeletedCount` output parameter,
  which would have made `$deletedCount += 2` throw and every real,
  successful lunch-archive deletion register as a caught failure.
  Renamed both new output parameters (`RemovedGenerationCount`/
  `RemovedFileCount`) to avoid any case-insensitive collision; verified
  with an isolated repro before and after.
- Maintenance: renamed a `Main`-scope variable that duplicated
  `Remove-OldRestoreArchives`'s own local `$groupsToDelete` under a
  different, unrelated computation (candidate count for console
  `Details` only, not the function's validity-aware retention decision)
  to `$restoreArchiveDeleteCandidateGroups`, to remove the confusing
  same-name/different-scope pattern. `Invoke-AutoShutdown` confirmed to
  have exactly one production call site (AST-counted).
- Tests: ~30 new checks across Archive, Health, and Maintenance (Plan
  reflects effective components, BAZA local/SFTP independent steps,
  path-step ordering, log/retention cleanup SKIPPED-vs-OK, `-SyncBAZA`
  isolation, embedded Health stays one step, Health dynamic-Total exact
  match, embedded Health suppresses Plan/summary, AutoShutdown
  Scheduled/Cancelled/Failed rendering and single-call-site, cleanup
  scope isolation). Full suite: 674/674.

## 5.0.0-dev.15 — 2026-08-10

Stabilizes the `BRAVO_MAINTENANCE.ps1` operator console step contract
introduced in dev.14 and makes end-of-run finalization resilient to a late
exception. No change to archive contents, 7-Zip, SHA512, VSS, SFTP/SMB
paths, credentials, notification routing, Health thresholds, backup-age
logic, or the exit-code formula.

- **Stable 8-step contract.** `Initialize-BRAVOMaintenanceSteps` now takes a
  literal `-Total 8`, never a computed expression. The approved operator
  contract is exactly `[1/8]` Перевірка вільного місця, `[2/8]` Створення
  необхідних директорій, `[3/8]` Зупинка служб, `[4/8]` Перевірка розмірів
  `.md`, `[5/8]` Реставрація моделі, `[6/8]` Обробка trace і логів, `[7/8]`
  Відновлення стану служб, `[8/8]` Контроль діапазонів ID — all eight always
  render, in this fixed order, on every run; a disabled/not-scheduled step
  renders `SKIPPED` on its own permanent number instead of shifting the
  numbering of the steps after it.
- Legacy log-structure migration, old-data cleanup, and the `BRAVO_ARCHIV.ps1`
  launch are confirmed non-numbered: each stays a detailed-LOG-only /
  Плану-операцій-visible operation and no longer calls
  `Write-BRAVOMaintenanceStep`, so it can never inflate the step count past 8.
- Fixed an ordering defect where, whenever a restore was not scheduled for
  the run (the common daily case), `[6/8]` Обробка trace і логів rendered
  *before* the `[5/8]` Реставрація моделі `SKIPPED` line, swapping the two
  numbers relative to the approved contract. The restore fallback now always
  renders first, regardless of scenario.
- **Fail-safe end-of-run finalization.** The Range ID / cleanup /
  `BRAVO_ARCHIV` / auto-shutdown / final-report block now runs inside a
  `try/catch`: any unhandled exception there is caught, still marks the run
  critical, and execution still reaches exit-code calculation and the final
  `BRAVO MAINTENANCE — <СТАТУС>` summary, instead of jumping straight past it
  to `Wait-BRAVOManualExit` with no summary printed at all. Inside the catch,
  `criticalErrorOccurred` is set unconditionally first, and the diagnostic
  logging/notification calls are each wrapped in their own isolated,
  non-rethrowing `try/catch` (each catch body explicitly discards the
  caught error via `$null = $_` — no `Write-Log`/`Send-SlackAlert`/`throw`/
  `exit`/`return` inside it) so a failure writing the log or sending the
  Slack alert cannot itself swallow the summary.
- `Write-Log` gained an opt-in `-NoConsole` switch (log file and
  notifications unaffected; no existing call site's behavior changes).
  `Test-RangeIdUsage` uses it for the three warnings that are already shown
  to the operator via the `[8/8]` step's `-Details`, so a missing/unreadable/
  over-threshold `range_id_log.json` no longer prints twice. A missing file
  now reports a two-line detail (label, then path) instead of one long line.
- The `План операцій:` block now closes with the same `=`-separator
  (`Write-BRAVOHeaderSeparator`, new in `BRAVO.Console`) that frames the run
  header, instead of the `-`-separator used by the unrelated `РЕЗУЛЬТАТ`
  block style.
- Tests: 15 new regression checks covering the fixed 8-step total (AST-level,
  rejects a dynamic `-Total`), each disabled step's `SKIPPED` render, the
  Restore/Logs step order, the fail-safe catch path (including simulated
  logging/notification failure inside it), the Range ID single-console-render
  and multiline-detail behavior, and the plan separator style — all via
  isolated source/AST extraction, never by running the real
  `BRAVO_MAINTENANCE.ps1` `Main()`.

## 5.0.0-dev.14 — 2026-08-09

Minimal structural/metadata change on top of dev.13: backup generation
manifests (`BRAVO_BACKUP_<GenerationId>.json`) now live in a dedicated
`<BackupRoot>\MANIFESTS\` storage location, separate from operational logs
(`LOGS\`) and disposable runtime data (`TEMP\`). No change to archive
contents, 7-Zip, SHA512, VSS, SFTP/SMB, credentials, notifications, Health
thresholds, backup-age logic, exit-code semantics, or the dev.13 elevation
contract.

- `modules\BRAVO.ArchiveHelpers`: three new centralized helpers —
  `Get-BRAVOBackupManifestRoot` (single source of truth for the physical
  path, `<BackupRoot>\MANIFESTS`), `Get-BRAVOBackupGenerationManifestFiles`
  (MANIFESTS-first reader with a non-recursive legacy-root fallback, dedup
  by GenerationId with MANIFESTS priority), and
  `Initialize-BRAVOBackupManifestStorage` (idempotent, non-recursive
  migration of legacy root manifests into `MANIFESTS\`: identical files are
  deduplicated by SHA256, conflicting files are never overwritten or
  deleted — both are preserved and a WARNING names the GenerationId).
- `Write-BRAVOBackupGenerationManifest` (`BRAVO.Archive.Runtime.ps1`) now
  writes new manifests directly into `MANIFESTS\`, creating the directory
  on first use.
- `Remove-BRAVOExpiredBackupGenerations` (retention), `Get-BackupHealthIssues`
  (`BRAVO_HEALTH.ps1`) and `Get-BRAVORestoreGenerationManifest`
  (`BRAVO_RESTORE_TEST.ps1`) all now discover manifests through the
  centralized reader instead of independently duplicating the same
  `Get-BRAVOFiles -Filter 'BRAVO_BACKUP_*.json'` call. `BRAVO_HEALTH.ps1`
  stays strictly read-only — it never migrates or writes.
- `BRAVO_MAINTENANCE.ps1` runs the migration once per invocation, under the
  same operation lock as the existing legacy-log-structure migration, and
  never fails the run: a migration error or conflict is logged as a
  WARNING only.
- `Get-BRAVOBackupGenerationManifestPhysicalFiles` (new): retention now
  deletes *every* physical copy of a generation's manifest (`MANIFESTS\`
  and, if still unmigrated, the legacy `BackupRoot` root) when that
  generation is expired, instead of only the one copy the MANIFESTS-first
  reader picked for the deletion decision. Previously a conflicting legacy
  duplicate could survive a generation's deletion and "resurrect" its
  metadata on the next run through the reader's legacy fallback. The new
  helper resolves candidates by filename match against real, already-
  enumerated files — it never builds a filesystem path from the untrusted
  `generationId` string read out of manifest JSON, so a crafted
  `generationId` cannot be used for path traversal.
- `BRAVO_MAINTENANCE.ps1` operator console UX: adopts the same
  `[N/TOTAL] Назва... STATUS mm:ss` step contract as Archive/Health, with
  a Maintenance-specific `OK`/`WARN`/`FAIL`/`SKIPPED` vocabulary (renamed
  from `OK`/`WARNING`/`ERROR`/`SKIPPED`, console-display only — log levels
  and exit-code semantics are unchanged). MANIFESTS init/migration is now
  folded into the existing "Створення необхідних директорій" step's detail
  instead of its own line, so a steady-state run shows nothing new.
  "Контроль діапазонів ID" gets its own step for the first time (it
  previously ran silently, log/Slack only); a missing or unreadable
  `range_id_log.json` shows as `WARN` on the console — the existing
  `Send-SlackAlert -IsCritical`/exit-code behavior for that condition is
  unchanged. The plan-preview line for the restore step is renamed
  "Реставрація моделі" to match the step's actual name (previously
  "Відновлення пропущених операцій", same underlying flag), and a
  "Контроль діапазонів ID" line was added so the plan can't diverge from
  what actually runs. The final `РЕЗУЛЬТАТ` block gains Початок/Завершення
  and a Кроків/Успішно/Попереджень/Пропущено/Помилок breakdown, mirroring
  `BRAVO_HEALTH.ps1`'s existing summary counters.
- Regression tests: 18 `ManifestStorage/*` checks covering root
  resolution, writer placement, reader priority/fallback/non-recursion,
  and migration; 2 more (`RetentionDeletesBothPhysicalManifestCopies`,
  `DeletedGenerationCannotReappearViaLegacyFallback`) covering the
  retention cleanup fix; 23 new `Maintenance/*` checks covering the header,
  plan wiring, step format/vocabulary/duration, the folded-in directory/
  MANIFESTS step, the Range ID step, and the final summary — all via
  isolated function extraction or static source checks, never by running
  the real `BRAVO_MAINTENANCE.ps1` `Main()`.
- Docs: README.md §2/§12 and OPERATIONS.md document the three-part storage
  split and the upgrade/migration behavior operators will see in the
  Maintenance log.

Correctness/UX follow-up (round 3):
- `Get-BRAVOBackupManifestFilenameGenerationId` (new): retention now
  requires the generationId encoded in a manifest's physical filename to
  match the generationId inside its JSON content before trusting that
  manifest for any deletion decision. A mismatch (corruption or tampering)
  excludes the record from retention entirely -- it can no longer cause
  deletion of its own artifacts or, via the round-2 physical-cleanup fix,
  of an unrelated generation's metadata that the JSON happened to name.
- `Get-BRAVOMaintenanceExecutionMode` (new, pure: takes only a SID):
  the Maintenance header's MANUAL/SCHEDULED mode no longer depends on
  `-NoPause` (a UX-only switch an operator can pass manually). It now
  reflects the actual caller: SYSTEM (S-1-5-18) is SCHEDULED, anyone else
  is MANUAL.
- Plan preview: restored `Відновлення пропущених операцій` (state of the
  missed-operation-recovery mechanism: `-RunMissedRestoreOnly` and actual
  missed work) as its own line, distinct from `Реставрація моделі` (will
  the model-restore step actually run this invocation). The two had been
  collapsed into one line; removed the Range ID line from the plan (the
  step itself is unaffected).
- Range ID: a missing/unreadable `range_id_log.json` no longer makes the
  whole Maintenance run `MaintenanceFailed`. `Send-SlackAlert -IsCritical`
  still fires (notification delivery in `errors_only` mode is unchanged);
  only its `criticalErrorOccurred` side effect is reverted for this one
  call, and only when nothing else had already set it.
- Migration step status mapping corrected: a manifest-migration conflict
  or error now maps to `WARN` (matching the non-fatal/retryable contract
  from round 1), not `FAIL`. `FAIL` is reserved for a real directory-
  creation failure.
- Step details (`Write-BRAVOMaintenanceStep`) no longer prefix WARN/FAIL
  text with "Причина:" -- every status (OK/WARN/FAIL/SKIPPED) now renders
  through the same plain, 6-space-indented `Write-BRAVOConsoleDetail`.
- `Write-BRAVOFinalSummaryHeader` (new, `BRAVO.Console`): Maintenance's
  final summary now opens with "BRAVO MAINTENANCE — <СТАТУС>" under the
  same `=`-separator style as the run's own header, instead of the
  generic " РЕЗУЛЬТАТ" block. Archive/Health/other callers keep using
  `Write-BRAVOResultHeader` unchanged. The summary's "Попереджень" field
  is reported exactly once (the step-level tally, matching Health's
  existing counter convention), not duplicated against the separate
  global warning count.
- 26 more regression tests: execution-mode (3), plan semantics (1), Range
  ID severity decoupling (3), retention filename/JSON identity (3), and
  7 "exact render" checks (header/plan/step/Range-ID-warning/summary x3)
  that assert actual rendered layout -- separators, label alignment,
  status vocabulary, absence of "Причина:", no duplicated "Попереджень"
  -- not just source-text presence.

Final polish (round 4):
- `Write-BRAVOFinalSummaryFooter` (new, `BRAVO.Console`, pairs with
  `Write-BRAVOFinalSummaryHeader`): Maintenance's summary now closes with
  "Журнал:" + the log path on its own line + a closing `=`-separator,
  matching the run header's style, instead of `Write-BRAVOResultFooter`'s
  "Детальний журнал:" + `-`-separator. Archive/Health keep
  `Write-BRAVOResultFooter` unchanged.
- The folded-in "Створення необхідних директорій" step (directory
  creation + MANIFESTS init/migration) now renders multiple detail facts
  as separate 6-space-indented lines, not joined with `; `.
- 1 more regression test (`Maintenance/DirectoryDetailsRenderAsSeparateLines`);
  the three summary-render tests now also assert the footer layout
  (`Журнал:` exactly once, log path on the next line, closing separator,
  absence of `Детальний журнал:`/`-`-separator).

Compact summary trim (round 5):
- The `Maintenance`/`Архівація`/`Shutdown` fields are no longer printed in
  the final compact operator summary -- they weren't part of the approved
  field set (Статус/Код завершення/Початок/Завершення/Тривалість/Кроків/
  Успішно/Попереджень/Пропущено/Помилок/Журнал) and duplicated what the
  "План операцій" block already shows at the start of the run.
- 1 more regression test (`Maintenance/FinalSummaryContainsOnlyApprovedFields`)
  reads the real final-summary source block in `BRAVO.Maintenance.Runtime.ps1`
  and asserts it contains exactly the approved fields and neither the
  removed ones nor the old `Write-BRAVOResultFooter`/"Детальний журнал"/
  " РЕЗУЛЬТАТ" contract.

## 5.0.0-dev.13 — 2026-08-09

Minimal reliability fix on top of the dev.12 UX fixes: manual `BRAVO_HEALTH.ps1`
runs without administrator rights no longer misreport a local permission
failure as an SFTP outage.

- `BRAVO_HEALTH.ps1` now detects elevation state (Administrator/SYSTEM/
  Standard) before doing any work. A manual interactive run without
  elevation self-relaunches through `Start-Process -Verb RunAs` (UAC),
  propagating the real `$PSBoundParameters` (ConfigPath, NoPause,
  NotifyOnSuccess, NoSlack, ForceNotification, SkipIfBackupTaskRunning) as a
  deterministically built, correctly quoted argument list, then exits with
  the elevated child's exit code. SYSTEM (scheduled task) and an
  already-elevated console are unaffected — no relaunch, no UAC, same
  behavior as dev.12. A cancelled UAC prompt prints a clear message instead
  of a raw stack trace.
- Non-interactive detection no longer relies solely on
  `[Environment]::UserInteractive`/`[Console]::IsInputRedirected` (neither
  actually proves PowerShell received `-NonInteractive`). The entrypoint now
  additionally reads its own process argv via the built-in .NET Framework
  API `[Environment]::GetCommandLineArgs()` — already parsed, Windows
  PowerShell 5.1-compatible, and, importantly, has no CIM/WMI dependency at
  all — and does an exact (not substring/`-like`) match for a standalone
  `-NonInteractive` element, so it does not false-match text inside
  `-ConfigPath`'s value or a file path. An explicit `-NonInteractive`
  overrides an otherwise-interactive-looking session and fails fast (exit
  36) without ever attempting UAC.
- `BRAVO.Health.Runtime.ps1` now probes write access to the runtime LOGS and
  TEMP roots before any real health check (services/local backups/SFTP/SMB).
  Previously a local `AccessDenied` on those paths only surfaced deep inside
  the SFTP stage's temporary-directory creation and was misclassified as
  `ERROR SFTP` / `SftpVerified=False`. On a preflight failure, none of the
  real checks run, and the operator sees an honest environment/privilege
  message (never "SFTP недоступний"), sent as a notification if configured.
  The failure is classified: only `UnauthorizedAccessException` (anywhere in
  the exception chain) is treated as a privilege problem; other I/O failures
  (disk full, `PathTooLong`, a broken filesystem, ...) are reported as a
  generic environment problem and do not tell the operator to run as
  administrator. This holds even when the runtime TEMP directory does not
  exist yet: the typed exception from a failed directory creation is now
  preserved end to end (as an `InnerException`) instead of being flattened
  to plain text before classification.
- New exit codes in `modules\BRAVO.ExitCodes`, documented in README.md's
  exit-code tables: `36 = PrivilegeRequired` for the privilege case above
  (also used by the entrypoint's UAC-cancel/non-interactive-fail-fast
  paths), and `37 = EnvironmentUnavailable` for the non-privilege
  environment/I/O case. `70 = HealthCritical` keeps its existing meaning —
  a real health-check failure that actually ran.
- If the health-check log itself could not be created/written, the
  environment notification and the console summary no longer claim a log
  path that does not exist.
- `Write-HealthLog` no longer floods the console with the same "не вдалося
  записати health-check лог" warning on every one of the dozens of calls in
  a run once the log file has become unwritable — it now warns once and
  stops retrying the write for the rest of that run.
- ACL of the runtime root is not weakened anywhere by this change — the fix
  is elevation on demand, not broader write access for regular users.
- `BRAVO_ARCHIV.ps1`/`BRAVO_MAINTENANCE.ps1` already had their own, simpler
  SYSTEM/Administrator self-elevation (predating this change) and were not
  touched here. Unlike the new Health gate, neither distinguishes
  interactive from non-interactive before attempting `-Verb RunAs`, and
  Maintenance has no dedicated handling for a cancelled UAC prompt — noted
  as a possible follow-up, not fixed here.

## 5.0.0-dev.12 — 2026-08-09

Minimal UX fix on top of the dev.11 operator notification unification.

- Component/destination status rows (BLOG/BRAVOEXCH/MODEL, Local, SFTP,
  BAZA_APP/BAZA_WWW, SMB) are now status-first (`✅ 📦 NAME — detail`) via the
  new shared `Format-BRAVOOperatorStatusLine` helper, instead of padding the
  component name with fixed spaces before the status icon. Discord and Slack
  render with a proportional font, so space-padding never aligned and broke
  differently depending on component name length.
- `BRAVO_DRY_RUN.ps1 -SendTestNotification` now converts the Discord test
  message through the same `ConvertTo-DiscordNotificationText` contract as
  Archive/Health/Maintenance, instead of sending raw `:emoji:` tokens to the
  Discord webhook. Slack is unaffected — Slack resolves `:shortcode:` natively.
- No changes to PASS/WARN/FAIL business logic, archive/VSS/retention/SFTP
  semantics, exit codes, or NotificationMode behavior.

## 5.0.0-dev.11 — 2026-08-09

Operator notification UX is unified across Slack and Discord.

- Added shared `BRAVO.Notifications` presentation helpers for severity headers,
  institution/host/public-IP blocks, version/build lines, log references,
  durations and Ukrainian file-count pluralization.
- Health success notifications now use `Остання резервна копія`, omit full
  archive filenames, and show compact component/destination status. Health
  warning/error notifications use `Остання успішна резервна копія` and put the
  concrete action before server metadata.
- BAZA_APP/BAZA_WWW long-name warnings now explain that only problematic files
  were skipped, show UTF-8 byte actual/limit/overflow, and include at most
  three examples in Slack/Discord while keeping the full list in logs.
- Maintenance success notifications are compact, avoid ambiguous restore
  scheduling text, show only the minimum free-space disk in success, and show
  disk deficit details for low-space failures.
- Test/restore/security notifications now use the same operator envelope while
  preserving NotificationMode, Discord chunking and disabled mentions.

## 5.0.0-dev.2 — 2026-08-09

Виправлення, виявлені під час тестового розгортання 5.0.0-dev.1. Централізовано
effective-конфігурацію: Setup, Dry Run, Task Installer, Task Diagnose і
production runtime тепер користуються однаковими правилами.

- Перевірка облікового запису запланованих завдань — за SID
  (`Test-BRAVOAccountIdentityEquivalent`), а не за текстом. Локалізована назва
  Task Scheduler ("СИСТЕМА") мовно-незалежно дорівнює `SYSTEM`/`S-1-5-18`, тому
  правильно встановлене завдання більше не отримує false FAIL і не валить Setup.
- `Test-BRAVOScheduledTaskDefinition` перевіряє визначення проти EFFECTIVE
  `schedulerSettings` (акаунт/LogonType/RunLevel через новий
  `Get-BRAVOExpectedSchedulerPrincipal`), а не проти хардкоду SYSTEM/5/Highest:
  прийняте Installer-ом визначення не оголошується invalid у Diagnose.
- Завершено розділення RuntimeRoot / ConfigRoot. Скрипти-завдання, Dry Run,
  модулі та ACL-hardening резолвяться з RuntimeRoot (каталог комплекту), а не з
  каталогу конфігурації; `-ConfigPath` лишається зовнішнім. RuntimeRoot більше
  не виводиться через `Split-Path $ConfigPath`.
- Новий канонічний `Get-BRAVOEffectiveSynchronizationConfiguration` (публікується
  як `$bazaSyncEffective`): чи потрібне BAZASync-завдання (`BAZA_APP_SFTP -or
  BAZA_WWW_SFTP`), які BAZA-джерела обов'язкові, які SFTP-каталоги потрібні.
  Валідна пара `BAZA_APP_SFTP=$false`/`BAZA_WWW_SFTP=$true` тепер вмикає
  заплановану синхронізацію; `BAZASync` визначено в `BRAVO.config`, тому Diagnose
  його більше не пропускає.
- Dry Run валідує джерело КОЖНОГО увімкненого BAZA-компонента (LOCAL і SFTP): без
  джерела — `FAIL` і ненульовий exit, а не `ГОТОВО ДО ЗАПУСКУ`. У `-TestAccess`
  Dry Run стат-ить кожен увімкнений SFTP-каталог призначення (`/baza_app`,
  `/baza_www`) через `FileExists`; відсутній — `FAIL` (каталоги не створюються).
- `BAZA_WWW_SFTP` за замовчуванням `$false` (узгоджено з коментарем і
  документацією): сервери без BRAVO Web більше не блокуються увімкненим прапорцем
  із невизначеним джерелом.
- Recovery (boot-тригер) показує «після наступного старту Windows (+затримка)»
  замість sentinel `30.12.1899`; `LastTaskResult` подається як історія
  виконання, окремо від валідації поточного визначення.
- Провенанс версії: `ci\Update-BRAVOVersionStamp.ps1` відхиляє stamp на брудній
  копії; self-test `Version/StampConsistency` перевіряє `buildId` як префікс
  `sourceCommit`; RELEASE_CHECKLIST документує «розгортати тег, а не проміжний
  коміт коду».

## 5.0.0-dev.1 — 2026-08-08

Generation-aware backup refactor. Compatibility changes are intentional:
Health/Restore now require a `COMPLETE` generation manifest, unsafe discovery
fallbacks are rejected, and writable machine state no longer lives under code.

- MODEL, BLOG and BRAVOEXCH are archived from one VSS Snapshot Set with one
  `GenerationId`. Same-volume sources share one shadow copy; multi-volume
  sources remain in the same set. VSS failure performs zero live archive work.
- Local publication is atomic and no-overwrite: `.work` -> 7-Zip create ->
  `7z t` -> SHA512 creation -> real SHA512 comparison -> final `.mdz` and
  sidecar. Existing valid backups and hashes are never removed first.
- `BRAVO_BACKUP_<GenerationId>.json` records snapshot, volume and component
  state, transfer results and Health result. Health evaluates the latest
  `COMPLETE` generation; Restore Test selects one generation automatically or
  through `-GenerationId`, so components from different runs cannot be mixed.
- Path architecture split into four independent roots: **RuntimeRoot**
  (complect + `Tools\` + version-controlled manifests + script logs
  `<RuntimeRoot>\LOGS`), **LIMSRoot**, **SystemLogRoot** and **BackupRoot**.
  `pathSettings.ArchiveRoot` is removed as a production concept.
  - `LIMSRoot=""` auto-discovers the canonical BRAVO service (Name +
    DisplayName); Disabled is a valid identity; missing or ambiguous services
    fail closed; explicit `LIMSRoot` always wins.
  - `SystemLogRoot=""` resolves to `<EffectiveLIMSRoot>\ARCHIV\LOGS`; an
    explicit value is used exactly. Trace/exchangAPI/BravoWeb live here.
  - `BackupRoot=""` resolves to `<EffectiveLIMSRoot>\ARCHIV`; an explicit value
    is used exactly. All three roots empty is the default all-AUTO layout, so
    the shipped `pathSettings` carries no machine-specific paths.
  - PowerShell script execution logs are always `<RuntimeRoot>\LOGS`
    (helpers: `<RuntimeRoot>\LOGS\HELPERS`), never a data root.
  - Machine state (`BRAVO_TASK_EXECUTION_STATE.json`,
    `BRAVO_ARCHIV_HEALTH_ALERT_STATE.json`, restore/version/VSS state) and the
    operation lock live under `%ProgramData%\BRAVO\{State,Locks}`.
  - Local backup destinations are `BackupRoot\{MODEL,BLOG,BRAVOEXCH,BAZA_APP,
    BAZA_WWW}` — the app copy is `BAZA_APP`, not `BAZA`.
  - Script-log, system-log and backup retention are three independent
    policies over three separate roots. Tools and manifests resolve from
    RuntimeRoot; effective ConfigPath is preserved through guard, loader,
    runtime and scheduled tasks. `BRAVO_CONFIG_TEST` / `BRAVO_DRY_RUN` /
    `BRAVO_TASKS_DIAGNOSE` report configured vs effective roots and probe them
    under SYSTEM.
- Canonical `bravo.ini` is `%SystemRoot%\SysWOW64\bravo.ini` on x64 and
  `%SystemRoot%\System32\bravo.ini` on x86. Missing service/INI/key now fails
  controlled; silent `LIMSRoot\Model`, `BLOG`, `bravoexch` and BRAVO_ROOT
  fallbacks were removed.
- Production and dry-run perform real SYSTEM source-read and
  create/write/read/delete probes. Archive and Maintenance share
  `C:\ProgramData\BRAVO\Locks\BRAVO_OPERATION.lock`; execution logs include
  seconds and PID.
- SFTP uses the actual configured endpoint, with no `google.com` prerequisite.
  Archive upload, BAZA_APP and BAZA_WWW have separate result objects, console
  steps and diagnostics; existing WinSCP post-sync comparison is preserved.
- Create, `7z t` integrity and SHA512 failures are distinct; SHA512 failure is
  exit code `42`. Windows Update freshness remains Health-only. A local
  `COMPLETE` generation stays complete when SFTP/SMB fails.
- Retention works by generation manifest, protects current and the minimum
  number of verified complete generations, and applies separate retention to
  incomplete/failed generations. Remote copies receive the generation manifest.
- Hard-termination VSS cleanup persists exact BRAVO-owned Shadow IDs in
  `C:\ProgramData\BRAVO\State\BRAVO_VSS_OWNERSHIP.json`; the next
  machine-wide lock owner removes only those IDs. Foreign/corrupt state and
  failed exact-ID deletion are retained and fail closed.
- Health now checks the same ProgramData operation lock used by Archive and
  Maintenance instead of the obsolete ArchiveRoot-relative marker.

## 4.5.0-dev.3 — 2026-08-08

CODE IS NOT DATA. Комплект, LIMS, операційні журнали й резервні копії стали
чотирма незалежними поняттями, а не наслідками фізичного розташування одне
одного. Разом із цим — фактична перевірка прав SYSTEM замість припущень.

- **`RuntimeRoot`, `LIMSRoot`, `ArchiveRoot`, `BackupRoot` розділені.**
  Раніше `LIMSRoot` обчислювався як «каталог на рівень вище комплекту», а
  `ArchiveRoot` — як «каталог самого комплекту». Це працювало лише тоді,
  коли комплект випадково лежав усередині LIMS. Для комплекту в `C:\BRAVO`
  ті самі формули давали `LIMSRoot = "C:\"` і `ArchiveRoot = "C:\BRAVO"` —
  тобто журнали писалися б у каталог із виконуваним кодом, а джерелом LIMS
  вважався б корінь системного диска.

  Тепер три корені задаються в `BRAVO.config` явно; порожнє, відносне або
  некоректне значення — помилка конфігурації з назвою параметра
  (`Resolve-BravoDataRoot`), а не мовчазний здогад. Значення проходять
  зняття лапок, `ExpandEnvironmentVariables` і нормалізацію, і не залежать
  ані від поточного каталогу процесу, ані від `$PSScriptRoot`, ані від
  каталогу, з якого Планувальник запустив завдання.

  `RuntimeRoot` передається в завантажувач окремим параметром, тому
  `-ConfigPath C:\BRAVO\CONFIGS\SERVER1.config` більше не змушує шукати
  `modules\` і `VERSION.json` поруч із конфігурацією.

- **`Tools\` переїхали до `RuntimeRoot`.** `7za.exe`, `WinSCP.com`,
  `WinSCP.exe`, `WinSCPnet.dll` — це виконувані залежності комплекту під
  захистом маніфесту, а не дані бекапу. Доти, доки вони лежали в
  `ArchiveRoot`, перенесення архівів на інший диск тягнуло за собою
  перенесення виконуваного коду, а `ArchiveRoot` доводилося захищати ACL
  так само суворо, як сам комплект. Заразом Maintenance перестав шукати
  архіватор власним `Join-Path $ARCHIVE_ROOT "Tools\7za.exe"`: тепер
  джерело те саме, що в Archive.

- **Effective ConfigPath використовується всюди.** `-ConfigPath` тепер
  розкривається, нормалізується й нормалізованим іде в перевірку
  перемикачів безпеки, завантажувач і дочірні скрипти. Раніше
  `Test-BRAVORuntimeSecuritySettings` завжди читав
  `$PSScriptRoot\BRAVO.config` — тобто запуск із власною конфігурацією
  проходив перевірку ЧУЖОГО файлу, а та, за якою скрипт реально працював,
  лишалася неперевіреною. Порядок бар'єрів збережено: перевірка цілісності
  комплекту (код 33) лишається найпершою.

- **Діагностика завдань покриває всі production-завдання, включно з
  BAZASync.** Він був єдиним, чия неправильна реєстрація виявлялася б лише
  з відсутності даних у хмарі. Для кожного завдання перевіряється фактично
  зареєстроване визначення: `SYSTEM` / `ServiceAccount` / `Highest`,
  `Action.Path` = налаштований `powershell.exe`, наявність `-NoProfile`,
  `-NonInteractive`, `-ExecutionPolicy Bypass`, правильні `-File` і
  `-ConfigPath`, `WorkingDirectory` = каталог скрипта, ненульовий
  `ExecutionTimeLimit`, а також task-специфічні перемикачі (`-NoPause`,
  `-RunMissedRestoreOnly`, `-SyncBAZA`, `-NotifyOnSuccess`).

- **SYSTEM preflight перевіряє права по-справжньому.** Замість `Test-Path`
  виконується повний probe: створити → записати відомі байти → прочитати
  назад → видалити. Наявність каталогу нічого не гарантує: ACL може
  дозволяти перелічення й забороняти запис саме для SYSTEM, і тоді ротація
  падає вже на production. Перевіряються читання `RuntimeRoot`,
  `ConfigPath`, `modules\`, `Tools\`, `LIMSRoot`, `bravo.ini` і запис
  `ArchiveRoot`, `BackupRoot`, `LOGS\` та всіх каталогів призначення
  ротації.

- **Буква підключеного мережевого диска більше не може бути
  production-залежністю.** `Z:\BRAVO` існує лише в інтерактивному сеансі
  користувача: під SYSTEM такий шлях працює вручну й мовчки зникає вночі.
  І діагностика завдань, і dry-run позначають це помилкою й рекомендують
  UNC `\\server\share\...`.

- **Свіжість оновлень Windows лишилась тільки в `BRAVO_HEALTH`.** Це
  health-метрика, а не умова виконання: в Archive, Maintenance, Recovery,
  Tasks Install/Uninstall і Credentials Setup вона лише додавала WARNING
  (а з ним ненульовий код завершення) до операції, на результат якої вік
  патчів не впливає. Перевірки платформи — ОС, build, PowerShell, .NET,
  архітектура, API — лишились на місці всюди.

- Закрито 10 сценаріями `Runtime/01…10` у `BRAVO_SELF_TEST.ps1`, зокрема
  probe запису на справжніх тимчасових каталогах. Жоден сценарій не керує
  реальними службами й не змінює production-дані.

## 4.5.0-dev.2 — 2026-08-08

Ротація, міграція, архівація та retention програмних журналів доведені до
production-grade рівня. Зміна функціональна: змінюються розкладка журналів
на диску, discovery джерел, семантика нумерації та політики зберігання —
саме тому версія пакета підвищена, а не залишена попередньою.

- **`bravo.ini` шукається рівно за одним шляхом, визначеним архітектурою
  ОС.** `%SystemRoot%\SysWOW64\bravo.ini` на x64, `%SystemRoot%\System32\bravo.ini`
  на x86 — і жодного fallback. Раніше, якщо системного файлу не було,
  Discovery читав `bravo.ini` поруч із `bravo.exe`. На машині, де є обидва,
  це означало тиху роботу за чужою конфігурацією: Maintenance ротував би
  trace, якого служба не пише. Тепер відсутність файлу — керована помилка з
  назвою перевіреного шляху.

- **Відносний `[Debug]/FILE` резолвиться від каталогу інсталяції BRAVO.**
  `FILE=TraceSRV.out` при `D:\LIMS-NEW\bravo.exe` означає
  `D:\LIMS-NEW\TraceSRV.out` — не поточний каталог процесу, не ArchiveRoot і
  не `SysWOW64`, де лежить сам `bravo.ini`. Trace поза каталогом інсталяції
  не блокується (шлях може вести на окремий диск свідомо), але позначається
  окремим WARNING: це розбіжність між конфігурацією й очікуванням, яку
  оператор має побачити в журналі, а не з'ясовувати під час інциденту.

- **`exchangAPI`: обидва історичні шаблони імен + обов'язкова
  дедуплікація.** Пошук іде і за `exchangAPI_*.log`, і за `exchangAPI*.log`:
  перший не ловить поточний `exchangAPI.log`, другий писався не на всіх
  розгортаннях. `exchangAPI_1.log` відповідає обом, тому після злиття
  результатів виконується дедуплікація за `FullName` — інакше той самий
  фізичний файл обробився б двічі.

- **Apache: тільки журнали.** Фільтр `*.log` замість «усі файли каталогу».
  `httpd.pid`, `*.lock` і тимчасові файли — службові: Apache очікує знайти
  їх на місці після старту, а не в архіві за вчорашню дату.

- **BRAVO Web application logs обходяться рекурсивно зі збереженням
  структури.** `www\log` має вкладені каталоги (`API\`, `Integration\API\`),
  і в різних гілках трапляються однакові імена. Сплющування в один
  каталог-дату злило б різні `request.log` в одну послідовність і знищило б
  контекст походження, тому відносний шлях зберігається, а нумерація
  рахується окремо для кожного відносного каталогу:
  `API\request_1.log` та `Integration\API\request_1.log` незалежні.

- **Автоматична міграція старої структури.** `<ArchiveRoot>\Trace`,
  `<ArchiveRoot>\exchangAPI` і `<ArchiveRoot>\Br-a-vo.web` переїжджають під
  `<ArchiveRoot>\LOGS\...`. Просто перестати туди писати було замало:
  накопичена історія залишилася б поза будь-яким retention і поза очима
  оператора. Міграція ідемпотентна й неруйнівна — джерело видаляється лише
  після підтвердженого переміщення (призначення існує, джерела немає,
  розмір збігся), часткова невдача лишає решту для наступного запуску, а
  перезапис призначення неможливий. Плоскі журнали старого формату
  отримують каталог-дату за власним `LastWriteTime` і проходять через той
  самий sequence engine, тобто одразу стають частиною нормального циклу.

- **`CompressedLogDays` — окрема політика зберігання `.mdz`.**
  `ArchiveDays` відповідає на питання «коли пакувати каталог-дату»,
  `CompressedLogDays` — «коли видаляти вже спакований архів». Змішувати їх
  не можна: перше вимірюється тижнями, друге — місяцями, і спільне число
  означало б або роздутий диск, або втрату історії. Вік архіву рахується за
  датою в його імені, а не за `LastWriteTime`: час файлу змінює будь-яке
  копіювання комплекту. Видаляються лише архіви очікуваного формату свого
  компонента — жодного узагальненого `*.mdz`.

- **Структурований результат переміщення.** `Move-BRAVOLogWithSequence`
  повертає `Status/SourcePath/DestinationPath/SourceSize/DestinationSize/
  Sequence/Attempts/Error` — те саме джерело і для журналу, і для підсумку,
  і для тестів. Агрегована статистика компонента розширена до
  `знайдено / непорожніх / переміщено / порожніх / пропущено / помилок`.

- **Порожній журнал лишається в джерелі** — не переміщується, не
  видаляється, не перейменовується і не займає номер у послідовності.
  Відсутній trace — діагностичне повідомлення, не помилка: BRAVO створює
  його лише під час першої debug-події. Після запуску служби в журнал
  додано інформаційний рядок про те, чи trace з'явився заново; на код
  завершення це не впливає.

- Закрито 27 сценаріями `LogRotation/01…27` у `BRAVO_SELF_TEST.ps1` — на
  справжніх файлах у тимчасовому каталозі. Жоден сценарій не керує
  реальними службами: усе, що стосується BRAVO/Apache/exchangAPI,
  перевіряється на синтетичних об'єктах служб і файлових фікстурах.

## 4.5.0-dev.1 — 2026-08-05

Перший development-реліз циклу `4.5.0`. Відкриває нову модель гілок і
версій, описану в `RELEASE_POLICY.md`.

- **Ротація програмних журналів переписана: детерміноване джерело,
  детермінована нумерація, жодного перезапису.** До цієї зміни кожен із
  чотирьох компонентів шукав свої журнали власною здогадкою, і кожен
  помилявся по-своєму.

  BRAVO Trace шукався як `*.out` у `LIMSRoot` — хоча точний шлях і назву
  задає сам BRAVO в `bravo.ini`, секція `[Debug]`, ключ `FILE`. Тепер це
  єдине джерело істини: `Resolve-BRAVOInstallationDiscovery` віддає
  `TRACE_FILE` (з trim, зняттям лапок, розкриттям `%ENV%` і перевіркою,
  що шлях абсолютний), а `BRAVO.config` цей параметр не дублює —
  конфігурація trace належить BRAVO, не Maintenance. Неможливість
  визначити `[Debug]/FILE` — помилка конфігурації з поіменно названими
  `bravo.ini`, `[Debug]` і `FILE`, а не мовчазний пропуск.

  `exchangAPI` шукався фільтром `exchangAPI_*.log` відносно `LIMSRoot` —
  тобто пропускав поточний `exchangAPI.log` (єдиний, що існує завжди) і
  дивився не туди, де служба насправді працює. Джерело — фактичний
  робочий каталог служби: `Win32_Service.PathName`, а для служб під NSSM
  — `AppDirectory`/`Application` з гілки `Parameters` (де `PathName`
  вказує на сам `nssm.exe`). Файли `exchangAPI.log`, `exchangAPI_1.log`,
  `exchangAPI_2.log` тепер належать одній логічній послідовності, тому
  `exchangAPI_1.log` стає `exchangAPI_3.log`, а не `exchangAPI_1_1.log`.

  Apache і BRAVO Web application logs розділені структурно: `apache\logs`
  і `www\log` більше не змішуються в один каталог-дату.

  Усі програмні журнали переїхали під `<ArchiveRoot>\LOGS`:
  `Trace\`, `exchangAPI\`, `BravoWeb\Apache\`, `BravoWeb\Application\` —
  замість трьох окремих каталогів у корені `ArchiveRoot`.

- **`Move-WithSequence`/`Move-ExchangAPILogs` замінені спільним
  механізмом.** Дві майже однакові копії циклу переміщення розійшлися в
  поведінці рівно там, де це коштує даних: `Move-ExchangAPILogs`
  переміщував файл під тим самим іменем з `-Force`, тобто мовчки
  перезаписував уже наявний журнал у призначенні, а `Move-WithSequence`
  нумерував як `_000001` і після невдалої архівації повертався до вже
  використаних номерів.

  Тепер один `Move-BRAVOLogWithSequence`: номер — `MAX(наявних) + 1` у
  межах каталогу-дати (пропуски не перевикористовуються), ім'я
  підбирається безпосередньо перед кожною спробою (файл міг з'явитися між
  обчисленням і `Move`), `-Force` немає взагалі, а після переміщення
  звіряються три факти одночасно: джерела немає, призначення існує,
  розмір збігся з вихідним. Порожній файл не переміщується і не є
  помилкою. Кожен компонент завершується агрегованим рядком
  `знайдено / переміщено / порожніх / помилок`, а успішне переміщення
  показує обидва імені (`exchangAPI_2.log -> exchangAPI_6.log`).

- **Джерела журналів визначаються ДО зупинки служб.** Окремий блок
  `=== ДЖЕРЕЛА ЖУРНАЛІВ ===` друкує `bravo.ini`, `[Debug]/FILE`, робочий
  каталог `exchangAPI` і всі чотири каталоги призначення ще до того, як
  BRAVO зупинено: з'ясовувати «а звідки взагалі брати trace» під час
  простою служби — найдорожчий момент для цього питання. Журнали кожного
  компонента переміщуються лише після фактичного `Stopped` його служби.

- **Retention програмних журналів відокремлено від службового.**
  `Process-OldData` тепер викликається для кожної гілки окремо
  (`Trace`/`exchangAPI`/`Apache`/`BravoWeb`), каталог-дата видаляється
  лише після коду `0` і успішного `7z t`, а `Remove-OldLogFiles`
  лишається нерекурсивним whitelist-очищенням виключно верхнього рівня
  `LOGS\`. Заразом прибрано мертвий виклик `Remove-OldLogFiles` для
  каталогу `exchangAPI`: його whitelist ніколи не містив `exchangAPI_*.log`,
  тому старі журнали exchangAPI не видалялися взагалі.

- **Виправлено рядок етапу «Обробка trace і логів».** Він друкувався
  всередині блоку BRAVO Web, тому на інсталяції без Apache щоразу
  показував `SKIPPED — службу BRAVO не було зупинено`, хоча trace і
  exchangAPI щойно оброблені успішно.

- Закрито 21 сценарієм `LogRotation/01…21` у `BRAVO_SELF_TEST.ps1` —
  на справжніх файлах у тимчасовому каталозі, а не текстовим пошуком:
  нумерація, стабільний порядок джерела, незалежні послідовності для
  кожного `BaseName`, збереження наявного файлу призначення, звірка
  розміру після `Move`, NSSM-каталог і fallback.

- **`RELEASE_POLICY.md`.** Що дозволено випускати з кожної гілки:
  `developer` — лише `X.Y.Z-dev.N` / `X.Y.Z-rc.N`, `master` — лише
  `X.Y.Z`; гілки ніколи не несуть однакової версії; stable виникає лише
  promotion перевіреного RC, без нових функцій. Чек-лист відповідає на
  питання «що зробити перед випуском», політика — «що взагалі дозволено
  випускати звідси».

- **`releaseChannel` повернувся у `VERSION.json`.** AUD-016 колись
  вивів його з `.git/HEAD`, бо ручна синхронізація між гілками двічі
  підвела на fast-forward merge. Але розгорнутий на сервері комплект
  приходить ZIP-ом, копіюванням, SFTP або SMB — `.git` там немає взагалі,
  і канал нізвідки взяти. Причину AUD-016 усунуто інакше: гілки більше
  не можуть містити однакову версію, тому fast-forward між ними
  неможливий, а замість людської дисципліни працює механічний gate.

  `Resolve-BRAVOReleaseChannelFromGit` лишилась — уже не як джерело
  значення, а як перехресна перевірка (`ReleaseChannelMatchesGit`).

- **`ci\Test-BRAVOReleasePolicy.ps1` + крок CI.** Stable-версія на
  `developer` або `-dev`/`-rc` на `master` тепер валить CI, а не їде на
  сервер непоміченою. Перевіряє також `ModuleVersion`, наявність версії
  в `CHANGELOG.md` і заголовки `README.md` / `BRAVO_SETUP.md`. У Pull
  Request гілка береться з цільової (`GITHUB_BASE_REF`): promotion
  `developer` → `master` несе вже stable-версію і має перевірятись
  правилами `master`.

- **`ModuleVersion` = базова частина версії.** `ModuleVersion` це
  `[System.Version]` — prerelease-суфікса він не приймає, а
  `New-ModuleManifest` у Windows PowerShell 5.1 не має `-Prerelease`
  (перевірено на цільовій платформі). Тому маніфести модулів несуть
  `4.5.0`, а повна версія пакета (`4.5.0-dev.1`) завжди береться з
  `VERSION.json`.

- Закрито тестами `Version/DeveloperBranchCarriesPrereleaseVersion`,
  `Version/ReleaseChannelStoredInPackage`, `Version/ModuleManifests`,
  `Documentation/ReleasePolicyExists`,
  `Documentation/ReleasePolicyCoversVersionModel`,
  `ReleasePolicy/CiGateEnforcesBranchVersionChannel`.

- **Ручний запуск не через Планувальник тепер чекає на клавішу — в усіх
  трьох runtime, а не лише в Archive.** `BRAVO_ARCHIV.ps1` уже мав робочу
  паузу (`RawUI.ReadKey` з фолбеком на `Read-Host` для ISE);
  `BRAVO_HEALTH.ps1` приймав `-NoPause`, але ніде його не використовував
  — Health ніколи не чекав; `BRAVO_MAINTENANCE.ps1` не мав ні параметра,
  ні паузи взагалі. Обидва тепер працюють так само, як Archive.

  Спільна реалізація — `Wait-BRAVOManualExit` (`BRAVO.Console`) — не
  спрацьовує без явного дозволу: `-NoPause`, вимкнений `PauseOnExit` у
  `BRAVO.config`, `[Environment]::UserInteractive = $false` (сесія 0,
  де й виконуються SYSTEM-завдання) чи перенаправлений stdin — кожна з
  цих причин самостійно скасовує очікування. Для 6 ранніх `exit`
  guard-блоку (до `Import-Module`, коли жоден модуль BRAVO ще не
  довірений) — самодостатній інлайн-варіант без залежності від модулів,
  за тим самим принципом, що й сам guard.

  `Maintenance.Runtime.ps1` має майже 30 точок `exit`, розкиданих по
  всьому файлу. Замість редагування кожної — один зовнішній
  `try/finally`: `exit` усередині `try` гарантовано проходить крізь усі
  `finally` на своєму шляху, перш ніж процес завершиться (властивість
  PowerShell, перевірено емпірично, включно з вкладеними
  `try/catch/finally`), тому один `finally` на весь файл охоплює їх усі.

  Попутно знайдено й закрито реальну прогалину: `BRAVO_TASKS_INSTALL.ps1`
  додавав `-NoPause` вибірково за типом завдання — `Recovery` і
  `Maintenance` (нічний, найризикованіший) його не отримували взагалі.
  Не мало наслідків, доки в цих runtime не було паузи; після цієї зміни
  було б реальним ризиком зависання нічної автоматизації. Тепер
  `-NoPause` додається безумовно для кожного типу.

- Закрито тестами `Console/WaitManualExitChecksNoPauseFirst`,
  `Console/WaitManualExitNoPauseReturnsImmediately`,
  `Console/EarlyGuardExitsPauseBeforeClosing`,
  `Console/HealthPausesOnEveryExitPath`,
  `Console/MaintenancePausesOnEveryExitPath`,
  `Console/MaintenanceAcceptsNoPauseParameter`,
  `Console/EntrypointsForwardNoPauseToRuntime`,
  `Scheduler/EveryTaskTypeGetsNoPauseUnconditionally`.

- **Discovery: уточнене джерело істини для служби BRAVO — за прямою
  вказівкою користувача.** Три виправлення:

  1. **Ідентифікація служби BRAVO** — тепер Service name ТА Display name
     одночасно (`"BRAVO"` і `"BRAVO Service"`), а не будь-яке з них
     окремо. Сторонній сервіс із випадково схожим ім'ям більше не
     проходить як BRAVO.

  2. **`bravo.ini` шукається в системному каталозі Windows**
     (`%SystemRoot%\SysWOW64` на 64-бітній ОС, `\System32` на 32-бітній),
     а не поруч із `bravo.exe`, як вважалось раніше. Причина —
     WOW64 File System Redirector: BRAVO 32-бітний, і коли він пише в
     "System32", 64-бітна Windows прозоро перенаправляє це в SysWOW64;
     64-бітний PowerShell (типово для запланованих завдань), звертаючись
     до "System32" напряму, бачить каталог без редиректу — і файлу там
     просто немає. Підтверджено буквально: на машині розробки він
     справді лежить у `SysWOW64`, і початкова версія тестів це
     випадково довела, підхопивши реальний файл замість фікстури.
     Старий шлях (поруч із `bravo.exe`) лишився вторинним fallback.

  3. **`BACKUP_ROOT`** — каталог збереження бекапів тепер визначається як
     підкаталог `ARCHIV` усередині шляху встановлення служби BRAVO, а не
     LIMSRoot-відносний шлях. `BRAVO.config` використовує це значення як
     дефолт `pathSettings.BackupRoot`, лише якщо адміністратор не змінив
     `BackupRoot` вручну — override ніколи не перезаписується мовчки,
     той самий принцип, що й для решти discovery-полів.

  Закрито тестами `Discovery/BravoServiceRequiresNameAndDisplayNameMatch`,
  `Discovery/SystemDirectoryIsPrimaryBravoIniSource`,
  `Discovery/Win32UsesSystem32NotSysWOW64`,
  `Discovery/FallsBackNextToExecutableWhenSystemIniMissing`,
  `Discovery/BackupRootDerivedFromBravoRoot`,
  `Discovery/BackupRootOverrideWins`,
  `Discovery/ConfigUsesStrictBravoIdentityAndBackupRoot`.

  (Поле переймено на `BACKUP_ROOT` уже в цьому циклі — `ARCHIV_ROOT`
  збігалося з уже наявним `pathSettings.ArchiveRoot`, геть іншим
  поняттям: каталогом самого скрипта, де лежать `Tools\`/`LOGS\`.)

- **`Tools\TOOLS_MANIFEST.json` — маніфест переїхав у той самий
  каталог, що й самі утиліти.** Раніше шукався поруч зі скриптом
  (`$archivPath\TOOLS_MANIFEST.json`), окремо від `Tools\`, де
  фактично лежать `7za.exe`/`WinSCP.*`. Тепер — `Tools\TOOLS_MANIFEST.json`,
  узгоджено з `TOOLS_INTEGRITY.json` (TOFU-базова лінія), який завжди
  був там. Оновлено всюди: `BRAVO.config`, fallback-значення в усіх
  трьох runtime, `ci\Update-BRAVOToolsManifest.ps1`,
  `ci\Update-BRAVORuntimeManifest.ps1` (сам маніфест теж
  version-controlled і входить у `RUNTIME_MANIFEST.json` — довелось
  оновити шлях і там, інакше він випав би з перевірки цілісності
  мовчки), `README.md`, `SECURITY.md`.

  Закрито тестами `ToolManifest/ManifestPathIsInsideToolsDirectory`,
  `ToolManifest/ManifestFileLivesInsideTools`.

- **`pathSettings.ArchiveRoot` дефолтився в обчислений здогад, а не в
  каталог самого скрипта — корінь того, чому маніфест "губився".**
  Раніше: `Join-Path (Split-Path -Parent $ConfigRoot) "ARCHIV"` —
  «піднятись на рівень вище й зайти в підкаталог, що зветься буквально
  ARCHIV». Працювало лише випадково, коли комплект розгорнутий у теці з
  таким іменем. Запущений з git-чекауту (інша назва теки — наприклад,
  `ARCHIV_LIMS_MONOLITH`) — обчислення тихо вказувало на каталог, якого
  не існує, і `Tools\TOOLS_MANIFEST.json` "губився", хоча фізично лежав
  поруч зі скриптом. Тепер — `$ConfigRoot` напряму.

  Той самий недолік був і в `Resolve-BRAVOInstallationDiscovery`:
  legacy-fallback для `BACKUP_ROOT` (коли служби BRAVO не знайдено)
  теж комбінував `LIMSRoot + "ARCHIV"` — друга здогадка поверх першої,
  і гірша за власний дефолт `BRAVO.config`. Тепер у цьому випадку
  `BACKUP_ROOT` лишається порожнім, і перемагає дефолт `ArchiveRoot`.

  Закрито тестами `Discovery/ArchiveRootDefaultsToScriptDirectory`,
  `Discovery/BackupRootStaysEmptyWithoutRealService`.

- **Ручний запуск `BRAVO_ARCHIV.ps1` з відсутніми обов'язковими
  обліковими даними тепер сам пропонує їх налаштувати**, замість того
  щоб просто впасти з помилкою `Не вдалося завантажити пароль архiвiв`
  і змусити шукати окремий скрипт. Якщо запуск інтерактивний (не
  `-NoPause`, реальна консоль — та сама перевірка
  `[Environment]::UserInteractive -and -not [Console]::IsInputRedirected`,
  що вже охороняє паузу перед закриттям) і не вистачає `BRAVO_7Z_PASSWORD`
  та/або `BRAVO_SFTP_LOGIN`/`BRAVO_SFTP_PASSWORD` (останні — лише якщо
  компонент їх справді потребує), автоматично запускається
  `BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Required
  -StoreFor CurrentUser` окремим процесом (ізольовано, щоб не
  перезаписати глобальний стан поточного запуску) — і лише для
  поточного користувача; обліковий запис запланованого завдання
  (`-StoreFor ScheduledTaskAccount`) як і раніше налаштовується окремо
  через `BRAVO_SETUP.ps1`/`BRAVO_CREDENTIALS_SETUP.ps1`.

  Закрито тестами `Console/ArchiveOffersCredentialSetupOnlyWhenInteractive`,
  `Console/ArchiveCredentialSetupUsesEnsureAndCurrentUserOnly`,
  `Console/ArchiveCredentialSetupRunsAsIsolatedProcess`.

- **Лог-файл тепер показує обране джерело для MODEL/BLOG/BAZA**, а не
  лише "УВIМКНЕНО"/"ВИМКНЕНО" як раніше. Секція `=== ОПЦIЇ СКРИПТА ===`
  для кожного увімкненого компонента додатково виводить рядок
  `Джерело <TYPE>: <шлях> (<причина>)`, де причина береться з
  `bravoDiscoveryResult.Reasons` (наприклад, `bravo.ini [model]
  MODEL=D:\LIMS-NEW\Model\lims` або `legacy fallback: ...`) — той самий
  формат, що вже показує `BRAVO_SETUP.ps1 -ValidateOnly`. Якщо джерело
  не вдалось визначити — `ERROR`-рядок з тією ж причиною замість
  мовчазного `null`. BRAVOEXCH і BAZA WWW це вже мали (окремі блоки),
  тепер симетрично й для MODEL/BLOG/BAZA.

  Закрито тестами `Console/ArchiveLogsModelSource`,
  `Console/ArchiveLogsBlogSource`, `Console/ArchiveLogsBazaLocalSource`.

- **Health падав із "The property 'ActionCounts' cannot be found on
  this object" щоразу, коли синхронізація BAZA на SFTP увімкнена, а
  локальний каталог BAZA відсутній.** Той самий клас бага, що вже
  ловив AUD (`Get-AlertFingerprint` і `DifferenceCount` для `Kind =
  "Service"`), але в іншому полі й інших місцях: лише ОДИН з чотирьох
  способів побудови проблеми `"SFTPSynchronization"`
  (`Get-SFTPHealthIssues`, гілка "у хмарі відсутні...") насправді
  встановлює `ActionCounts`. Три інших ("не вдалося визначити локальне
  джерело", "локальний каталог не знайдено", "не вдалося порівняти
  каталоги") — ні, а консольний журнал і `Format-CompactSFTPIssue`
  зверталися до `$healthIssue.ActionCounts`/`$Issue.ActionCounts`
  напряму навіть усередині `if ($null -ne ...)` — під `Set-StrictMode`
  це падає ще до самого порівняння. Archive (де Health викликається
  in-process) ловив це як повну відмову health-check замість звичайної
  проблеми в звіті — оператор не отримував жодної тривоги.

  Новий `Get-BRAVOHealthIssueActionCounts` (той самий підхід, що вже
  має `Get-BRAVOHealthIssueField`: `PSObject.Properties['ActionCounts']`
  замість прямої крапки) замінив усі небезпечні звернення в обох
  місцях. Перевірено живим прогоном `BRAVO_HEALTH.ps1` за тих самих
  умов, що й реальний збій: третя проблема тепер коректно потрапляє у
  звіт (`SFTP BAZA: локальний каталог BAZA не знайдено; ...; типи
  розбіжностей: немає даних`) замість краху всього health-check.

  Закрито тестом `Health/SFTPSynchronizationToleratesMissingActionCounts`.

- **`BAZA_APP` шукався поруч із `LIMSRoot`, а не поруч із реальним
  `MODEL`/`BLOG` з `bravo.ini`.** `BAZA` не має власного ключа в
  `bravo.ini`, тому `BAZA_APP` завжди виводився як `<BRAVO_ROOT>\BAZA`
  — а `BRAVO_ROOT`, коли Windows-службу BRAVO не знайдено (типова
  dev/test-машина без встановленої служби, лише з конфігом), деградує
  до `LIMSRoot`-фолбеку. Реальний випадок: `bravo.ini` знайдено
  (системний каталог Windows не залежить від служби), `MODEL`/`BLOG` з
  нього коректно вказували на `D:\LIMS-NEW\...`, а `BAZA_APP` усе одно
  шукався в `C:\Users\...\Documents\BAZA` — зовсім іншому місці.

  Тепер, коли `MODEL` або `BLOG` вже взято з `bravo.ini`, `BAZA_APP`
  виводиться як сусідній каталог у тому самому корені інсталяції
  (`Split-Path -Parent` від `MODEL_SOURCE`/`BLOG_SOURCE`) — і лише
  якщо жоден з них з `bravo.ini` не прийшов, лишається старий
  `<BRAVO_ROOT>\BAZA` fallback.

  Закрито тестом
  `Discovery/BazaAppFollowsIniInstallationRootNotBravoRootFallback`.

- **SFTP: скрипт тепер сам створює відсутні кореневі каталоги**
  (`model`/`blog`/`bravoexch`/`baza_app`/...) замість того, щоб просто
  падати. Реальний випадок: WinSCP явно повідомляв `Error listing
  directory '/baza_app'. No such file or directory` — жоден із
  каталогів на сервері ще не існував, і кожна передача (як окремих
  файлів, так і синхронізація BAZA) провалювалася кодом 1.

  Новий `Initialize-BRAVOSFTPRemoteDirectories` викликається одним
  пакетним WinSCP-скриптом одразу після підтвердженого з'єднання, перед
  Send-FileViaWinSCP/Sync-FolderToSFTP — і в автоматичному потоці, і в
  ручній `-SyncBAZA`. `option batch continue` навмисно: `mkdir` на вже
  наявному каталозі повертає помилку (а після першого успішного запуску
  каталоги вже існують щоразу), тому виклик — best-effort і ніколи не є
  джерелом істини про успіх; реальний результат перевіряють окремі
  виклики передачі, які на це не зважають.

  Це оголило два раніше недосяжні StrictMode-баги в самій `Sync-FolderToSFTP`
  (аудит BAZA до цього завжди падав на "каталог не знайдено" ще до того,
  як доходило до цього коду):
  - `Get-BAZASFTPComparison` читав ім'я локального елемента порівняння
    через `.FullName` — а `$difference.Local` з WinSCP `CompareDirectories`
    це `WinSCP.RemoteFileInfo` (навіть для локальної сторони), а не
    `System.IO.FileInfo`: такої властивості там немає взагалі, лише
    `.FileName` (той самий API, що вже коректно працює через
    `$side.FileName` у `BRAVO.Health.Runtime.ps1`).
  - `Write-BAZASFTPComparisonAudit`/`Write-BAZARemoteNameCompatibilityAudit`
    викликали `Write-BRAVOLog -FileOnly` — цей перемикач існує лише на
    локальному шимі `Write-Log` (транслює його в `-NoConsole`), а сам
    `Write-BRAVOLog` такого параметра не має і падає з
    `InputValidationError`.

  Перевірено живим прогоном на реальному SFTP (Hetzner Storage Box):
  до фіксів — 0 з 6 файлів; після mkdir-фіксу — 6 з 6 файлів, але аудит
  BAZA падав на `.FullName`; після `.FileName`-фіксу — падав на
  `-FileOnly` при спробі залогувати 374 елементи аудиту; після всіх
  трьох фіксів разом — `374 з 374` файлів BAZA синхронізовано,
  `Каталог BAZA повнiстю синхронiзовано з /baza_app`.

  Закрито тестами `Console/ArchiveEnsuresSFTPDirectoriesBeforeTransfer`,
  `Console/BazaComparisonReadsFileNameSafely`,
  `Console/BazaAuditUsesNoConsoleNotFileOnly`.

- **Власний прогрес-бокс `Test-NetConnection` ("Attempting TCP connect",
  "Waiting for response") усе одно з'являвся в консолі поверх кроків
  BRAVO**, хоча мав бути прихованим. `Test-BRAVOTcpConnection` уже
  придушував його через `$ProgressPreference = 'SilentlyContinue'`, але
  локальне присвоєння (без `$global:`) ненадійне для цього конкретного
  командлета — відомий нюанс Windows PowerShell 5.1, коли сам
  `Test-NetConnection` не завжди резолвить preference-змінну лише з
  локального scope виклику.

  Тепер тимчасово підміняється ГЛОБАЛЬНЕ `$ProgressPreference`
  (з гарантованим відновленням попереднього значення в `finally`) —
  саме так, як і задумувалося коментарем, що вже існував у коді.

  Закрито тестом `Compatibility/TcpConnectionSuppressesGlobalProgress`.

- **`BRAVO_ARCHIV.ps1` друкував ПОВНИЙ заголовок Health усередині
  власного кроку "Перевірка резервних копій"** — "BRAVO HEALTH X.X.X /
  Установа / Початок" виглядало як друга незалежна програма всередині
  виводу Archive, з власною версією й міткою часу, хоча це один
  прогін. Реальний випадок (скріншот користувача): "дублювання
  зявляється при запуску BRAVO_ARCHIV.ps1 + BRAVO_HEALTH.ps1 — у
  кожного свої заголовки та етапи".

  `Invoke-BRAVOHealth` отримав новий `-SuppressHeader`, який передається
  лише зі шляху `Invoke-BRAVOHealthCheck` (`BRAVO.Health.psm1`) —
  вбудований виклик з Archive. Самостійний запуск `BRAVO_HEALTH.ps1`
  проходить іншим шляхом (без цього параметра), тому там заголовок
  лишається без змін. `Write-BRAVOHeader` (BRAVO.Console) отримав
  `-SuppressText`: приховує сам текст заголовка, але зберігає
  резервування порожніх рядків під прогрес-бар — без цього перші рядки
  вбудованого Health-звіту ризикували опинитися під смугою.

  Закрито тестом `Console/EmbeddedHealthSuppressesDuplicateHeader`.

- **Уніфіковано вбудований звіт Health усередині `BRAVO_ARCHIV.ps1`** —
  прибирання заголовка (див. вище) закрило лише частину проблеми
  (реальний скріншот користувача, зроблений після цього): вбудований
  виклик усе одно друкував ВЛАСНУ покрокову нумерацію `[N/5]` поряд із
  нумерацією Archive `[N/7]`, ВЛАСНИЙ підсумок (`Результат`/
  `Тривалість`/.../`Детальний журнал`) поряд із підсумком Archive —
  фактично два незалежні звіти замість одного. Плюс `SFTP MODEL:
  серверний SHA архіву недоступний; використано повний збіг
  віддаленого hash-файлу` показувалось як WARNING, хоча перевірка все
  одно успішна (просто іншим методом).

  `Write-BRAVOHealthStep` тепер пропускає власний друк `[N/5]` при
  `-SuppressHeader`, не збиваючи внутрішній лічильник кроків (від нього
  залежить нумерація кроку "Сповіщення"). `Complete-BRAVOHealthResult`
  придушує власний `Write-BRAVOSummary` — `Complete-BRAVOProgress`
  (очищення прогрес-бару) лишається безумовним. Фолбек на `.sha512`
  тепер логується як INFO, а не WARNING: перевірка успішна, це нотатка
  про метод, а не привід для уваги оператора. Разом з попереднім
  прибиранням заголовка вбудований виклик тепер показує лише те, що
  справді потрібно: значущі "Проблема ..." деталі (якщо є) і ОДИН
  підсумок Archive з ОДНИМ посиланням на лог-файл.

  Закрито тестами `Health/EmbeddedCallSuppressesStepNumbering`,
  `Health/EmbeddedCallSuppressesOwnSummary`,
  `Health/ServerSideHashFallbackIsInfoNotWarning`.

- **Зайвий порожній розрив між `[6/7]` і `[7/7]` усередині
  `BRAVO_ARCHIV.ps1`** — після прибирання заголовка й підсумку Health
  (див. вище) лишався фіксований блок із 6 порожніх рядків
  (`BRAVOConsoleProgressReservedLines`), який раніше захищав текст
  заголовка Health від накладання прогрес-бару. Без самого тексту
  захищати вже нічого, а блок лишався видимим розривом навіть тоді,
  коли Health не знаходила жодної проблеми для показу (реальний
  скріншот користувача). `Write-BRAVOHeader -SuppressText` тепер
  пропускає ввесь вивід одразу — і текст, і резервування рядків.

- **`BAZA_WWW` (бекап `{DocumentRoot}\BAZA` встановленого Apache) тепер
  визначається автоматично, а не задається вручну.** `Resolve-BRAVOInstallationDiscovery`
  шукає службу Apache2.4/Br-a-vo.web (той самий канал кандидатів, що й
  раніше), знаходить її `httpd.exe`, читає `<ServerRoot>\conf\httpd.conf`
  новим парсером `Get-BRAVOApacheDocumentRoot` і бере `DocumentRoot`
  звідти — а не вгадує його з розташування `apache\`. Синхронізація
  вмикається лише тоді, коли служба справді встановлена і `DocumentRoot`
  вдалось прочитати; каталог на SFTP лишається `baza_www`, без змін.
  `BRAVO.config` більше не містить окремої логіки пошуку (видалено
  ~130-рядковий `Find-BRAVOWebBAZASource` з обходом предків і евристикою
  "перша непорожня папка") — тепер це тонкий адаптер над результатом
  Discovery.

  Попутно знайдено й виправлено реальний баг, який виявився лише на
  живій машині з дійсно встановленою службою Apache: `BRAVO.Discovery`
  викликає `Get-BRAVOWmiInstance` (з `BRAVO.Compatibility`), не
  імпортувавши цей модуль сам — і те, що виклик модуля-споживача
  (наприклад, `BRAVO.Health.Runtime.ps1`) імпортує `BRAVO.Compatibility`
  РАНІШЕ, не робить її функції видимими всередині чужого модуля: кожен
  PowerShell-модуль має власний session state. Через це `WEB_ROOT` і
  `BAZA_WWW` мовчки лишались порожніми на машині з реально запущеною
  службою `Br-a-vo.web`, хоча той самий пошук служби прекрасно
  спрацьовував поза модулем. Виправлено додаванням явного
  `Import-Module BRAVO.Compatibility` на початку `BRAVO.Discovery.psm1`
  — той самий патерн, що вже застосовано в `BRAVO.Notifications`,
  `BRAVO.ArchiveRuntime`, `BRAVO.ArchiveHelpers`.

  Закрито тестами `Discovery/ApacheDocumentRootParserReadsQuotedForwardSlashPath`,
  `Discovery/ApacheDocumentRootParserIgnoresCommentedDirective`,
  `Discovery/BazaWwwUsesHttpdConfDocumentRoot`. Підтверджено живим
  прогоном `BRAVO_HEALTH.ps1` на машині з реальною службою
  `Br-a-vo.web`: `WEB_ROOT`, `HttpdConfPath`, `BAZA_WWW` заповнюються
  коректно зі справжнього `httpd.conf`.

- **Визначення BAZA обмежено рівно чотирма незалежними значеннями:
  `BAZA_APP_SFTP`, `BAZA_WWW_SFTP`, `BAZA_APP_LOCAL`, `BAZA_WWW_LOCAL`.**
  Раніше `componentSettings.Synchronization` називав ці прапорці
  `BAZALocal`/`BAZASFTP`/`BAZAWWWSFTP` — бареве `BAZA` без суфікса
  означало "APP", що легко сплутати з `BAZA WWW` при читанні коду чи
  конфігурації. Перейменовано наскрізно (`BRAVO.config`, `BRAVO.Archive`,
  `BRAVO.Health`, `BRAVO_DRY_RUN.ps1`, `BRAVO_SETUP.ps1`,
  `BRAVO_CREDENTIALS_SETUP.ps1`, `BRAVO_TASKS_INSTALL.ps1`) разом із
  похідними змінними (`bazaAppLocalSyncEnabled` тощо) і текстом логів
  ("Синхронiзацiя BAZA APP на SFTP" замість голого "BAZA"). Discovery-поля
  (`BAZA_APP`/`BAZA_WWW` — шляхи-джерела, не прапорці) і каталоги на SFTP
  (`baza_app`/`baza_www`) не чіпались — вони й так уже однозначні.

  **`BAZA_WWW_LOCAL` — нова функція**, а не просто перейменування: локальна
  копія `BAZA_WWW` (`{DocumentRoot}\BAZA` встановленого Apache/Br-a-vo.web)
  у каталог `BackupRoot\BAZA_WWW`, точно за тим самим принципом, що вже
  давно робить `BAZA_APP_LOCAL` (`Sync-Folders` через robocopy). За
  замовчуванням вимкнено (`$false`), як і `BAZA_APP_LOCAL`. Health отримав
  той самий read-only `robocopy /L` контроль актуальності, що вже був для
  `BAZA_APP_LOCAL` (спільна `Get-BAZALocalSyncHealthIssues`, раніше
  `Get-BAZALocalHealthIssues`, з новим параметром `-Label`).

  Закрито тестами `Discovery/ConfigDefinesExactlyFourBazaSyncFlags`,
  `Discovery/ArchiveReadsExactlyFourBazaSyncFlags`,
  `Console/ArchiveSyncsBazaWwwLocally`, `Health/BazaWwwLocalHealthCheckWired`.

- **`BRAVO_MAINTENANCE.ps1` відмовлявся запускатись, якщо каталог скрипта
  назвався не буквально `ARCHIV`.** Той самий крихкий здогад, що вже
  прибрано з `ArchiveRoot` (`pathSettings`, дивись запис нижче в цьому ж
  циклі) — і так само працював лише випадково, коли комплект розгорнутий
  саме в теці з таким іменем. Будь-яке інше розташування (наприклад,
  git-чекаут з іменем репозиторію) блокувало Maintenance повідомленням
  "Скрипт має запускатись лише з папки ARCHIV!" (код `90`) без жодної
  реальної причини — `ArchiveRoot`/`LIMSRoot` і так явно задаються
  окремо в `pathSettings`. Перевірку прибрано; жодне інше місце в
  комплекті на неї не покладалось.

- **`BRAVO_MAINTENANCE.ps1` мовчки пропускав до 3 із 7 етапів, коли
  `LIMSRoot` не вказує на реальний корінь LIMS-інсталяції.** `Check-MdFileSizes`
  сканував `$MODEL_PATH = "$ROOT_LIMS\Model"` — той самий крихкий
  LIMSRoot-відносний здогад, що вже прибрано з `MODEL_SOURCE` в Archive.
  Коли реальний каталог MODEL не збігався з цим здогадом (`LIMSRoot`
  вказував не на корінь інсталяції), `EnumerateFiles` кидав
  `DirectoryNotFoundException`, який ніхто не ловив аж до
  `Invoke-BRAVOMaintenanceEntrypoint`: `finally`-блоки встигали відновити
  служби й показати "Натисніть будь-яку клавішу", але етапи "Реставрація
  моделі"/"Обробка trace і логів"/"Очистка" пропускались мовчки, без
  видимої помилки в консолі (лише after-the-fact `Write-Error`, після
  натискання клавіші).

  Той самий здогад використовувала й **реставрація моделі через
  `bravocmd.exe`** (`$ROOT_LIMS\MODEL\lims`) та шлях до самого
  `bravocmd.exe` (`$ROOT_LIMS\bravocmd.exe`) — деструктивна операція, яка
  на нетиповій структурі диска так само вказувала б у порожнечу.

  Усі три джерела істини — `bravoDiscoveryResult.MODEL_SOURCE`,
  `.MODEL_PROJECT_FILE` (точне значення `MODEL=` з `bravo.ini`, те, що
  приймає `bravocmd.exe`) і `.BRAVO_ROOT` (каталог `bravo.exe`, де
  логічно лежить і `bravocmd.exe`) — з тим самим фолбеком на старий
  LIMSRoot-відносний шлях, коли Discovery нічого не знайшов (bravo.ini чи
  служба відсутні), тому поведінка на типовому розгортанні не змінюється.

  Перевірка: живий прогін на машині, де раніше падало на кроці
  "Перевірка розмірів .md" — тепер усі 7 етапів показуються й
  завершуються, результат УСПІШНО.

- **Заголовок `BRAVO_MAINTENANCE.ps1` дублював код установи:**
  "Установа: Тестова установа [0000000] [0000000]". `Write-BRAVOHeader`
  сам додає `[InstitutionCode]` до `-Institution`, а Maintenance передавав
  туди вже складений `$script:ObjectName` (`"$InstitutionName [$InstitutionCode]"`,
  той самий рядок, що йде в Slack/лог-підсумок) — замість самої лише
  назви, як роблять Archive і Health. Виправлено на `bravoSettings.InstitutionName`,
  узгоджено з обома іншими runtime. Підтверджено живим прогоном.

- **Консольний підсумок `BRAVO_MAINTENANCE.ps1` теж повторював установу**
  окремим рядком "Установа: ..." після "Попереджень: 0" — зайве, коли та
  сама інформація вже показана в заголовку рядком вище. Ні Archive, ні
  Health установу в підсумку не дублюють. Прибрано.

## 4.4.2 — 2026-08-05

Виправлення за результатами першого тестового розгортання на реальному
сервері. Обидва дефекти — не в тому, що BRAVO робить, а в тому, що він
**показує**: перевірка готовності звітувала «все гаразд» там, де запуск
би не відбувся, а діагностика виводила результат нечитабельним.

- **`BRAVO_DRY_RUN.ps1` не перевіряв цілісність комплекту.** Він звітував
  «помилок — 0» на комплекті, у `Tools\` якого лежали залишки старого
  розкладання; кожен запуск за розкладом на тому ж комплекті завершився б
  кодом `33`, бо entrypoint кличе guard, а dry-run — ні.

  Перевірка готовності, яка не перевіряє того, що перевіряє сам запуск,
  дає хибну впевненість — а це найгірше, що вона може зробити. Тепер
  dry-run виконує ті самі три перевірки (`33`, `34`, `35`), причому
  `Test-BRAVOVersionDowngrade` — з `-NoWrite`: dry-run не має права
  фіксувати розгортання, якого ще не було.

  Закрито тестами `DryRun/VerifiesRuntimeIntegrity` і
  `DryRun/DoesNotRecordVersionState`.

- **`OPERATIONS.md`:** два розділи за реальними симптомами цього
  розгортання — «сторонні скрипти в комплекті» (код `33`, найчастіша
  причина на свіжому сервері, з прямою забороною «узаконювати» знахідку
  оновленням маніфесту на сервері) і «Цей хост невідомий» для SFTP (це
  DNS та ім'я, що будується з логіна й шаблону, а не автентифікація).

- **Результат SYSTEM dry-run у `BRAVO_TASKS_DIAGNOSE.ps1` друкувався одним
  нечитабельним рядком.** `ConvertFrom-Json` у Windows PowerShell 5.1
  віддає JSON-масив **одним об'єктом**, не розгортаючи його в конвеєр, тому
  `@(... | ConvertFrom-Json)` давало масив із єдиного елемента-масиву: цикл
  виконувався один раз, `$result.Status` ставав `System.Object[]`, і весь
  звіт злипався у `[PASS PASS FAIL ...] Конфігурація Скрипти ...: шлях шлях`.

  Саме цей вивід читають, коли треба зрозуміти, чому завдання від `SYSTEM`
  не працює. Виявлено на тестовому сервері.

  Закрито двома тестами: функціональним (обидві форми, з перевіркою що
  хибна справді згортає) і AST-сканером усіх скриптів комплекту. Сканер
  саме по AST, а не підрядком, щоб не ловити власні пояснювальні коментарі.

## 4.4.1 — 2026-08-05

Патч безпеки, знайдений першим же тестовим розгортанням 4.4.0. Ставте
на сервер саме цю версію, а не 4.4.0.

- **Незавантажуваний `BRAVO_RUNTIME_GUARD.ps1` більше не вимикає весь шар
  цілісності.** `Test-Path` підтверджував лише наявність файлу. Якщо
  dot-source не виконувався — `ExecutionPolicy AllSigned` без підпису,
  синтаксична помилка, блокування файлу — entrypoint мовчки йшов далі:
  усі три перевірки (`33`, `34`, `35`) падали з `CommandNotFound`, не
  зупиняючи запуск, і справа доходила до `Import-Module`.

  Тобто найдешевшим способом обійти перевірку цілісності було не
  підбирати SHA-256, а зробити guard непрацездатним. Тепер dot-source
  обгорнуто в `try/catch`, а наявність усіх трьох функцій підтверджується
  через `Get-Command`; будь-який збій — код `33` до завантаження модулів.
  Виявлено під час тестового розгортання 4.4.0 на сервері з `AllSigned`.

  Закрито двома тестами: статичним (`try/catch` + `Get-Command` у всіх
  трьох entrypoint) і функціональним — справжній entrypoint поруч із
  guard-ом, що не парситься, мусить завершитись кодом `33`. До
  виправлення той самий сценарій давав `90`, тобто прохід повз перевірки.

- **`OPERATIONS.md`:** окремий розділ для `33` під `ExecutionPolicy
  AllSigned`. Це не атака, а політика виконання: заплановані завдання
  працюють (`-ExecutionPolicy Bypass`), ручний запуск із консолі — ні.
  Прямо сказано, чого робити не можна: знижувати політику машини заради
  зручності.

## 4.4.0 — 2026-08-05

Реліз для тестового розгортання. Основне — єдиний стиль операційної
консолі для всіх трьох runtime; дорогою закрито зовнішнє рев'ю, кілька
пунктів аудиту й два дефекти, через які моніторинг мовчав.

**Перед першим запуском на сервері:** `BRAVO_MAINTENANCE.ps1` цієї версії
жодного разу не виконувався наскрізь — його логування, шкала рівнів і
структура виводу змінені й перевірені статично, самотестом і на стенді,
але не живим прогоном. Перший запуск має бути ручним і під наглядом, не
за розкладом: Maintenance зупиняє служби LIMS, реставрує модель і
видаляє дані.

- **Єдиний стиль відображення для всіх трьох runtime.** `BRAVO.Console`
  існував і робив саме те, що треба — заголовок, нумеровані етапи
  `[1/7] Назва.....OK`, сталі кольори статусів, одна смуга прогресу,
  підсумок, — але користувався ним лише Archive. Health вивалював в
  консоль кожен запис журналу суцільним потоком `[LEVEL] текст` без
  жодного кольору; Maintenance малював `=== ЗАГОЛОВОК ===` і власну
  палітру. Оператор бачив три різні програми.

  Health і Maintenance переведено на `BRAVO.Console`: заголовок, етапи,
  підсумок із метриками. Вимкнений у конфігурації компонент не показуємо
  й не рахуємо — знаменник обчислюється за увімкненими, як це від
  початку робив Archive. Вимкнені BAZA, NAS/SMB і сповіщення дають
  `[1/4]…[4/4]`, а не `[1/7]…[7/7]` із трьома порожніми рядками.
  Реставрація моделі показується лише тоді, коли справді виконуватиметься
  цього запуску; якщо вона була запланована, але службу BRAVO не вдалося
  зупинити, рядок лишається — це не «не настав час», а заплановане й
  невиконане. У Health підсумок друкується з
  `Complete-BRAVOHealthResult`, через яку проходить кожен зі шляхів
  виходу, тому нова гілка не може лишитися без підсумку.

  Консольна половина журналу теж тепер іде через `BRAVO.Console`
  (`Set-BRAVOLogConsoleWriter`): `WARNING` із бізнес-логіки дописувався
  у хвіст відкритого рядка етапу й ламав розмітку рівно тоді, коли
  щось пішло не так. Це callback, а не залежність: журналювання —
  нижчий шар і має працювати там, де консолі немає взагалі.

  З підсумку Health прибрано метрики вимкнених призначень: рядок
  `NAS/SMB: True` читався як «перевірено й усе гаразд», хоча перевірки
  не було взагалі.

  Заголовок тепер зсуває вміст під смугу прогресу: у класичному хості
  `Write-Progress` малюється поверх верхніх рядків вікна й повертає їх
  лише на `-Completed`, через що заголовок і перші етапи були невидимі
  протягом усього запуску.

- **Health падав із кодом `90` щоразу, коли лежала керована служба.**
  Об'єкт проблеми `Kind = "Service"` не несе полів `DifferenceCount` і
  `ActionCounts`, а `Get-AlertFingerprint` читав їх у всіх проблем без
  розбору. Під `Set-StrictMode` це помилка, тому runtime завершувався
  внутрішньою помилкою **замість того, щоб надіслати тривогу**: рівно
  той тип мовчазного моніторингу, проти якого існує Health. Поля тепер
  читаються через `Get-BRAVOHealthIssueField`.

- **`LogLevel = "SUCCESS"` приховував помилки в Maintenance.** У
  локальній шкалі рівнів `SUCCESS=4` стояв вище за `ERROR=3`, тому
  найвища детальність відсікала саме помилки й попередження. Шкалу
  приведено до тієї, що в `BRAVO.Logging`, де `SUCCESS` свідомо нижче
  за `WARNING`. Ту саму пастку `BRAVO.Logging` виправив раніше — тут
  вона лишалася в копії.

- **`THREAT_MODEL.md` приведено у відповідність до коду.** Документ
  описував як відкриті три ризики, які код уже закрив: послаблення
  перемикачів безпеки в `BRAVO.config` (код `34`), відкат версії
  (код `35`) і секрет як звичайний .NET `string`. Модель загроз, що
  перебільшує ризик, шкодить не менше за ту, що применшує — власник
  ухвалює інфраструктурні рішення саме за її списком пріоритетів.

  Перероблено розділи 3 (`BRAVO.config` як AST, умови блокування,
  `BRAVO_ALLOW_WEAKENED_SECURITY`), 4 (`SecureString`-ланцюг і чесна межа:
  SFTP URL і пароль 7-Zip лишаються незанулюваними рядками), 7 (перевірка
  `34` стежить за перемикачами, не за самим призначенням), 8 (стан у
  `LOGS\BRAVO_VERSION_STATE.json`, `BRAVO_ALLOW_DOWNGRADE`, і прямо
  сказано, що це захист від помилкового відкату, не від зловмисного —
  файл стану лежить на тому самому сервері) і 11 (перелік пріоритетів
  перебудовано, закриті пункти винесено окремо).

  Дрейф закрито тестами `Documentation/ThreatModelReflectsImplementedControls`
  і `Documentation/ThreatModelHasNoStaleResidualRisk`.

- **Аудит #5: секрет із Credential Manager більше не матеріалізується як
  звичайний рядок.** `StoredCredential.Secret` тепер `SecureString`. У
  .NET рядок незмінний, тому його неможливо занулити — копія пароля
  лишалась у керованій купі до збирання сміття, і кожне читання
  створювало ще одну, а Archive/Health/Maintenance читають облікові дані
  кілька разів за запуск.

  Декодування blob'а йде в `char[]` (масив можна очистити) з посимвольним
  додаванням у `SecureString`; масив байтів і масив символів зануляються
  у `finally`. Повного відкритого пароля не існує в керованій пам'яті на
  жодному кроці читання.

  **SMB-шлях плейнтексту не створює взагалі:** новий
  `New-BRAVOSecureCredential` будує `PSCredential` напряму з
  `SecureString`. Раніше пароль SMB ставав рядком лише для того, щоб
  одразу перетворитись назад.

  `ConvertFrom-BRAVOSecureSecret` — єдина точка перетворення в
  плейнтекст, із детермінованим зануленням проміжного BSTR
  (`ZeroFreeBSTR`). `Get-BRAVOCredentialSecret` збережено без зміни
  сигнатури, щоб не переписувати 19 місць runtime одним махом.

  **Чесна межа задокументована в SECURITY.md:** рядок, повернутий із
  точки перетворення, лишається незанулюваним. Зміна прибирає зайві
  копії й робить кожне перетворення видимим, але не усуває плейнтекст як
  такий — WinSCP приймає URL `sftp://user:pass@host`, а 7-Zip пароль
  через stdin. Повне усунення потребує SFTP-автентифікації ключем.

  Покрито `Secrets/CredentialSecretIsSecureString`,
  `SecureSecretRoundTrip` (кирилиця й спецсимволи — C# декодує байти
  вручну), `SecureCredentialSkipsPlainText`,
  `SmbPasswordNeverBecomesPlainText`.

- **Літерали, що виглядають як облікові дані, прибрані з тестових
  фікстур.** У тесті `Protect-BRAVOLogSecret` лежали sftp-URL із паролем,
  повні Slack/Discord webhook-URL із токенами й паролі 7-Zip — записані
  літералами. Значення вигадані, але для сканера це справжні секрети:
  саме через них GitGuardian періодично піднімав інциденти, які
  доводилось закривати вручну.

  Альтернатива «додати виняток сканеру» гірша: виняток глушить і
  справжній витік у тому самому файлі. Тому фікстури тепер збираються з
  частин у рантаймі, а перевірки звіряються зі змінними — маскування
  тестується так само строго.

  Самотест `Secrets/NoCredentialShapedLiterals` не дає їм повернутись.
  Перевіряються лише **строкові літерали з AST**: коментарі й
  документація свідомо поза межами, бо там форма URL з обліковими даними
  потрібна, щоб пояснити, що саме маскується. Плейсхолдерами вважаються
  узагальнені слова (`pass`, `password`), маска `***`, підстановка
  формату `{0}` і посилання на змінну — останнє обов'язкове, бо
  `New-BRAVOSftpUrl` будує саме такий рядок із `${escapedPassword}`, і
  перша версія перевірки на цьому робочому коді спіткнулась.

- **Аудит Low #10: `Get-BRAVOWinSCPBusyMessage` формував текст в обхід
  єдиної точки санітизації.** Її результат іде у `Write-BRAVOLog`
  (Archive) і в `throw` (Health) — тобто в журнал і в сповіщення, — тоді
  як `Get-SanitizedWinSCPDiagnostic` застосовувалась лише до
  stdout/stderr WinSCP.

  Сьогодні витікати нема чому: в `$Availability.Processes` лежать самі
  `ProcessId`. Але `$Availability.Error` — це вільний текст із
  `$_.Exception.Message`, а найприроднішим розширенням діагностики «який
  саме WinSCP зараз працює» є `CommandLine` з `Win32_Process`, у якому
  лежить `sftp://user:password@host`. Тоді повідомлення про зайнятість
  стало б місцем витоку пароля в журнал і Slack/Discord.

  Тепер обидві гілки повідомлення проходять спільну санітизацію.
  Покрито двома самотестами: `Secrets/WinSCPBusyMessageIsSanitized`
  (пароль у `sftp://` і в `-password=` замаскований) і
  `Secrets/WinSCPBusyMessageKeepsDiagnostics` (PID і назва операції
  лишаються читабельними — інакше санітизацію почнуть обходити).

  На цьому закрито всі три Low-зауваження початкового аудиту (#8, #9,
  #10).

- **Аудит Low #9: вікно між створенням тимчасового WinSCP-файла й
  накладанням ACL.** `New-BRAVOWinSCPTemporaryScriptPath` створювала файл
  через `[IO.File]::Open`, а потім захищала його через `Set-Acl` —
  попри коментар, який стверджував, що файл створюється «атомарно».

  У вікні між цими двома діями файл існує з успадкованими від `%TEMP%`
  правами. Для запланованого завдання `%TEMP%` — це `C:\Windows\Temp`,
  куди має доступ значно ширше коло. Порожній файл секрету ще не
  містить, але **Windows перевіряє права в момент відкриття
  дескриптора, а не при кожному читанні**: відкритий у цьому вікні
  дескриптор переживає зміну ACL і прочитає облікові дані SFTP, які
  запише туди викликач.

  Тепер DACL будується ДО створення й передається у конструктор
  `System.IO.FileStream` разом із `FileSecurity` — файл ніколи не існує
  з успадкованими правами, вікна немає взагалі.

  Наявний функціональний тест `Runtime/ProtectedWinSCPTemporaryScript`
  посилено (жодного успадкованого правила, жодного зайвого SID), але
  сам по собі він цю ваду не ловить: **результат в обох схемах
  однаковий**, різниця лише у вікні. Регресійна перевірка це
  підтвердила — під час повернення старої схеми функціональний тест
  лишився зеленим. Тому додано статичний
  `SFTP/TemporaryScriptCreatedWithFinalAcl`, який вимагає `FileSecurity`
  у конструкторі `FileStream` і забороняє виклики `Set-Acl`/`Get-Acl` у
  цій функції. Виклики шукаються в AST, а не пошуком підрядка: текст
  функції містить слово `Set-Acl` у коментарі, що пояснює її
  відсутність.

- **Аудит Low #8: порожні `catch {}` ковтали діагностику.** У комплекті
  було 35 порожніх `catch`, з них 11 — без жодного пояснення. Проблема
  не в тому, що блок порожній (частина з них законна: прибирання у
  `finally`, де початкова помилка важливіша), а в тому, що він **мовчить
  без причини** — саме тоді, коли діагностика потрібна найбільше.

  Три з них були не діагностичною, а **безпековою** проблемою:
  `Remove-BRAVOWinSCPSensitiveTemporaryScript` затирає й видаляє
  тимчасовий WinSCP-скрипт, який містить облікові дані SFTP. Мовчазна
  помилка означала, що файл із секретом лишається в `%TEMP%`, і ніхто
  про це не дізнається. Тепер — `WARNING` з іменем файлу, який треба
  видалити вручну.

  Решта отримала `DEBUG` (завершення процесу після таймауту, DNS-запит
  локальної IP для сповіщення, читання попереднього стану завдань,
  дренаж потоків) або `Write-Warning` (невидалене тимчасове завдання
  Планувальника — наступний запуск діагностики впав би на імені, що вже
  існує). У `BRAVO.Compatibility` логування свідомо не додано: це
  найнижчий шар, він завантажується до `BRAVO.Logging` і навмисно не має
  від нього залежності — тепер це записано в самому `catch`, а не
  мається на увазі.

  Самотест `Diagnostics/NoSilentEmptyCatch` вимагає, щоб кожен порожній
  `catch` у production-комплекті або логував, або **всередині блоку**
  пояснював, чому логування тут недоречне.

- **Захист від відкату на старішу версію (новий код завершення `35`).**
  Четвертий залишковий ризик із THREAT_MODEL §11. Усі наявні перевірки
  звіряють комплект із його **власним** маніфестом — старий, внутрішньо
  узгоджений комплект проходить їх бездоганно, разом із вразливостями,
  які відтоді закрили, і без перевірок, яких у ньому ще не існувало.
  Найпростіший спосіб вимкнути `Enforce` — не ламати його, а розгорнути
  версію, де його ще не було.

  Сервер запам'ятовує найвищу версію, яку на ньому запускали
  (`LOGS\BRAVO_VERSION_STATE.json`: `highestVersion`, `sourceCommit`,
  `recordedAt`), і відмовляється виконувати старішу. Свідомий відкат —
  через `BRAVO_ALLOW_DOWNGRADE=1`.

  Файл стану навмисно НЕ поводиться як маніфест: пошкоджений або
  відсутній — не блокує. Він не є еталоном довіри, і його втрата не
  мусить зупиняти backup; наступний успішний запуск запише його наново.
  Ручний запуск `BRAVO_RUNTIME_GUARD.ps1` перевіряє версію з `-NoWrite`,
  щоб діагностика не змінювала стан, який вона перевіряє.

  Чесна межа задокументована в SECURITY.md і OPERATIONS.md: той, хто має
  права підмінити комплект, зазвичай має права й видалити файл стану.
  Перевірка робить відкат помітним і таким, що потребує ще однієї
  свідомої дії; проти випадкового відкату вона працює повністю.

  Покрито `VersionState/*` (8 тестів, включно з повним циклом запису на
  диск) і `ExitCodes/VersionDowngradePriority`.

- **Захист перемикачів безпеки в `BRAVO.config` (новий код завершення
  `34`).** THREAT_MODEL §11 називав це третім залишковим ризиком; окремо
  виявилось, що коментар у `BRAVO_RUNTIME_GUARD.ps1` уже посилався на
  `Test-BRAVORuntimeSecuritySettings` як на наявну перевірку — функції не
  існувало. Документація обіцяла захист, якого не було.

  `BRAVO.config` навмисно не входить до `RUNTIME_MANIFEST.json`: він
  різний на кожному сервері, спільного еталонного хешу не існує. Через це
  він лишався єдиним файлом комплекту, який можна змінити без сліду — а в
  ньому є перемикачі, що вимикають решту захисту:
  `toolIntegritySettings.Mode = "Warn"` (підмінений `7za.exe` більше не
  блокує) і `backupConsistency.Mode ≠ "VSS"` (архів без VSS-знімка).
  Рядок у текстовому файлі коштує дешевше за підміну бінарника.

  Значення читаються **розбором AST** (`[Parser]::ParseFile`), без
  виконання: завантажити `BRAVO.config` означало б виконати довільний
  PowerShell-код ще до перевірки. Послаблення лишається можливим, але
  вимагає двох дій у двох різних місцях — правки конфігурації й
  `BRAVO_ALLOW_WEAKENED_SECURITY=1`, за зразком уже наявного
  `BRAVO_ALLOW_UNSUPPORTED_OS`. Друга дія лишає слід поза комплектом.

  Обхід через обчислюване значення (`$m = "Warn"; Mode = $m`) статично не
  підтверджується й тому блокує так само — інакше він був би дешевшим за
  пряме послаблення.

  Код `34` у контракті стоїть нижче за `33` (там факт підміни), але вище
  за `32` і `20`: доки перемикачі вимкнені, будь-який успіх нижче
  означає менше, ніж здається. Покрито `ConfigSecurity/*` (8 тестів) і
  `ExitCodes/SecuritySettingsWeakenedPriority`.

  Під час розробки функціональний тест виявив дефект, якого не було б
  видно в рев'ю: `return ,@()` віддає порожній масив як один елемент, і
  зайве `@()` на місці виклику робило з нього масив із порожнім рядком —
  конфігурація, яка взагалі не згадує ці налаштування, помилково
  вважалася послабленою. Обидва місця тепер із поясненням у коді.

- Зовнішнє рев'ю 2026-08-05, P2: [OPERATIONS.md](OPERATIONS.md) —
  операторський runbook. README пояснює, як налаштувати; матриця в
  розділі 12 — де шукати причину. Не було документа, який відповідає на
  питання «зламалось, які дії зараз». Кожен із 12 кодів завершення
  (`20`–`90`) отримав розділ за структурою: симптом, що означає, **чого
  не робити**, команди діагностики, безпечне виправлення, умова
  ескалації. Плюс сценарії поза кодами: розбіжність контекстів
  `SYSTEM`/адміністратора, оновлення `7za`/WinSCP, помилка Discovery,
  ransomware, відновлення на чистий сервер.

  Розділ «чого не робити» — не оформлення, а суть документа. Найдорожча
  помилка в історії репозиторію (порада видалити `TOOLS_INTEGRITY.json`)
  належала саме до цієї категорії, для якої не існувало місця в
  документації. Тому в runbook зафіксовані як заборони: не видаляти
  маніфест і не оновлювати його на сервері (`32`/`33`), не підганяти
  `sftpHostKey` під те, що прийшло по мережі (`50`), не видаляти
  пошкоджений архів — він навмисно лишається для діагностики (`41`), не
  «лікувати» health ручним запуском Archive (`70`), не запускати
  Archive і Maintenance при підозрі на ransomware — вони перезапишуть і
  видалять те, що ще вціліло.

  Покрито самотестами `Documentation/OperationsRunbook*` (наявність,
  повнота за кодами завершення, наявність «чого не робити» щонайменше у
  8 сценаріях, критичні сценарії поза кодами, заборона поради видалити
  маніфест).

- Зовнішнє рев'ю 2026-08-05, P1 «документація не встигає за кодом»:
  - **README описував застарілу модель довіри до `Tools/`.** Розділ 1
    досі подавав trust-on-first-use як основний контроль і радив
    «видаліть `TOOLS_INTEGRITY.json`, щоб прийняти нову базову лінію»,
    хоча код уже блокував запуск за `TOOLS_MANIFEST.json` (код `32`).
    Ризик не теоретичний: адміністратор, який після security-алерту
    сумлінно виконає застарілу інструкцію, власноруч легітимізує
    підмінений бінарник. Розділ переписано під фактичну модель
    (`Enforce`, сторонні DLL, заборона автостворення маніфесту);
    `TOOLS_INTEGRITY.json` лишився описаним, але явно позначений як
    додатковий шар виявлення дрейфу, а не еталон. Охороняється
    самотестами `Documentation/ReadmeDescribesManifestToolTrust` і
    `ReadmeNeverAdvisesDeletingManifest` — другий забороняє будь-яку
    пораду видалити маніфест цілісності.
  - **`SECURITY.md` містив `[заповнити]` замість контакту й SLA.**
    Політика без строків не є політикою. Розділ 2 заповнено конкретним
    каналом (приватний репозиторій — Issue з міткою `security` або
    власник; Security Advisory, якщо репозиторій стане публічним) і
    таблицею строків: підтвердження 2 робочі дні, первинна оцінка 5,
    виправлення критичної вразливості 7–14 календарних днів. Самотест
    `Documentation/SecurityPolicyHasNoPlaceholders` не дає заглушці
    повернутись. Це скасовує свідоме рішення версії 4.2.0 лишити
    заглушки як є.

## 4.3.0 — 2026-08-04

- Аудит P3/P4/P5:
  - **P3.** Усі сторонні GitHub Actions зафіксовані на повний commit SHA
    замість рухомого тега (`@v4` можна переписати, 40-символьний SHA —
    ні). Версія PSScriptAnalyzer закріплена через `-RequiredVersion`,
    інакше нове правило ламає CI без жодної зміни коду. Охороняється
    самотестами `StaticAnalysis/ActionsPinnedToCommitSha` і
    `AnalyzerVersionPinned`.
  - **P4.** `VERSION.json.sourceCommit` — повний 40-символьний git-hash.
    Короткий `buildId` не давав однозначної відповіді, який саме код
    розгорнуто: короткі hash збігаються й погано шукаються в історії.
    `ci\Update-BRAVOVersionStamp.ps1` проставляє обидва поля, зберігаючи
    форматування файлу (`ConvertTo-Json` у PowerShell 5.1 переформатовує
    весь файл і вже ламав самотест).
  - **P5.** [THREAT_MODEL.md](THREAT_MODEL.md) — 9 сценаріїв
    (компрометація адміністратора, підміна Tools і runtime, витік
    credentials, ransomware, VSS, підміна призначення, rollback,
    паралельні запуски), кожен із явним розділом залишкового ризику.
    Найбільший незакритий — ransomware на SFTP-призначення: воно
    доступне на запис тими самими обліковими даними, немає
    immutable-сховища. Самотест вимагає наявності розділу залишкового
    ризику, щоб модель не перетворилась на рекламу.
  - `.gitleaks.toml`: SHA-256 у маніфестах цілісності — не секрети.
    Виняток навмисно вузький (`condition = "AND"`): лише 64-hex, лише в
    двох файлах маніфестів.

- Аудит P2: цілісність усього PowerShell-комплекту, а не лише `Tools/`.
  - `RUNTIME_MANIFEST.json` (version-controlled) — еталонні SHA-256 54
    файлів: `.ps1`, `.psm1`, `.psd1`, `VERSION.json`,
    `TOOLS_MANIFEST.json`.
  - `BRAVO_RUNTIME_GUARD.ps1` — перевірка виконується **до**
    `Import-Module`, тому guard навмисно самодостатній (лише .NET, без
    жодного модуля BRAVO): інакше довелося б завантажити модуль, щоб
    перевірити модулі. Усі три entrypoint dot-source-ять його першим і
    завершуються кодом `33` (`RuntimeIntegrityViolation`).
  - Блокує змінений хеш, відсутній файл і **підкинутий сторонній
    `.ps1`/`.psm1`** — останній може бути dot-source-нутий або
    підхоплений як модуль. Відсутній чи пошкоджений маніфест — теж
    відмова.
  - `ci\Update-BRAVORuntimeManifest.ps1` — оновлення на робочій станції;
    CI-крок «Integrity manifests are current» не дасть змержити
    застарілий маніфест (інакше свіжий комплект заблокував би сам себе).
  - `BRAVO.config` навмисно поза маніфестом (сервер-специфічний), але
    послаблення захисту через нього тепер гучне: усі три runtime пишуть
    `WARNING`, якщо `toolIntegritySettings.Mode` не `Enforce`.
  - Чесні межі задокументовані в `SECURITY.md` 4.1: сам guard і
    entrypoint уже виконуються на момент перевірки — повне закриття
    потребує Authenticode-підпису (P0.3, не реалізовано).

- Рев'ю попереднього кроку виявило дві прогалини в захисті `Tools/` —
  обидві виправлено:
  - **Health більше не запускає інструменти, цілісність яких не
    підтверджена.** Попереднє рішення («Health read-only, тому не
    блокуємо») було обґрунтоване хибно: небезпечний не запис на SFTP, а
    сам запуск `WinSCP.com` / завантаження `WinSCPnet.dll` — підмінений
    бінарник виконує довільний код з правами `SYSTEM` незалежно від
    того, що робить Health. Тепер `Test-SFTPHealthConfiguration`
    пропускає всю SFTP-гілку (єдиний шлях до `Tools/` у Health), а сам
    Health завершується кодом `32`. Локальні перевірки (служби, диски,
    вік копій) інструментів не запускають і виконуються далі.
  - **Сторонній `.exe`/`.dll`/`.com` у `Tools/` тепер блокує запуск** у
    режимі `Enforce`, а не лише повідомляється. Причина — DLL
    side-loading: підміняти `WinSCP.exe` не обов'язково, достатньо
    підкласти DLL з відповідним іменем у той самий каталог, і жоден хеш
    у маніфесті не зміниться. Самотест
    `ToolManifest/UnknownExecutableIsReportedNotBlocking`, який
    закріплював стару поведінку, замінено на
    `ToolManifest/UnknownExecutableBlocksInEnforce` і
    `ToolManifest/UnknownDllBlocksInEnforceWarnsInWarn`.

- Аудит P1 (найнебезпечніший сценарій: підмінений інструмент запускається
  від `NT AUTHORITY\SYSTEM`): цілісність `Tools/` тепер БЛОКУЄ запуск, а
  не лише попереджає.
  - Новий version-controlled `TOOLS_MANIFEST.json` — еталонні SHA-256
    усіх семи виконуваних файлів `Tools/` (не лише `.exe`: підміна
    `7za.dll` не менш небезпечна). Потрапляє на сервер разом з
    комплектом і проходить код-рев'ю як звичайна зміна.
  - `Test-BRAVOToolManifestIntegrity` (`BRAVO.Compatibility`): режим
    `Enforce` (типово) зупиняє Archive і Maintenance з кодом `32`
    (`ToolIntegrityViolation`) і надсилає критичне сповіщення; Health
    як read-only діагностика звітує рівнем `ERROR`, не блокуючи себе.
    Режим `Warn` (`$global:toolIntegritySettings.Mode`) лишає стару
    поведінку для міграції.
  - Маніфест **ніколи** не створюється й не оновлюється автоматично.
    Відсутній, порожній чи пошкоджений маніфест у `Enforce` — теж
    відмова: інакше найпростішим обходом було б просто видалити еталон.
  - Сторонній `.exe`/`.dll`/`.com` у `Tools/` повідомляється окремо, але
    не блокує запуск (може взагалі не використовуватись).
  - `ci\Update-BRAVOToolsManifest.ps1` — оновлення еталона на робочій
    станції; без `-Apply` лише показує розбіжності.
  - Новий код завершення `32` має пріоритет вище за `LockBusy`, щоб
    подія безпеки не губилась у Планувальнику як буденне «зайнято».
  - 11 нових самотестів (`ToolManifest/*`, `Runtime/ToolManifest*`,
    `ExitCodes/ToolIntegrityViolationPriority`), включно з перевіркою,
    що маніфест у репозиторії відповідає реальним `Tools/` — інакше
    свіжий комплект заблокував би сам себе на першому запуску.

- Аудит P1 (PSScriptAnalyzer майже не блокував небезпечні патерни):
  CI блокував лише `Severity=Error`, а `PSAvoidUsingInvokeExpression`,
  `PSAvoidUsingConvertToSecureStringWithPlainText`,
  `PSAvoidUsingUsernameAndPasswordParams` та інші виключались
  **глобально** — тобто новий небезпечний код у будь-якому файлі теж
  мовчки проходив CI.
  - Новий `PSScriptAnalyzerSettings.psd1`: явний блокуючий
    security-набір (`IncludeRules`) + інформаційний прохід для решти.
  - Глобальні `-ExcludeRule` для security-правил прибрані. Натомість
    11 точкових `SuppressMessageAttribute` із `Justification` біля
    конкретних функцій (плюс 3 для хибних спрацювань правила на
    параметрах, чия назва містить «Credential», але які не є секретом).
  - `New-BRAVOPlainTextCredential` (`BRAVO.Credentials`) — блок
    `ConvertTo-SecureString` + `New-Object PSCredential` був
    продубльований у Archive- і Health-runtime; тепер це одна функція з
    одним точковим виключенням замість двох розсіяних.
  - Новий CI-крок «Заборонені патерни»: `Invoke-Expression`/`iex`,
    мережеве завантаження коду (`DownloadString`/`Net.WebClient`),
    секрет у `-ArgumentList`, `ExecutionPolicy Bypass` поза allowlist
    із шести файлів, де він легітимний. Коментарі ігноруються.
  - PSScriptAnalyzer тепер обходить файли поодинці: окремі правила
    здатні кинути `NullReferenceException` на конкретному файлі й
    обірвати весь аналіз, замаскувавши решту знахідок.
  - Побічно виправлено знайдене цим набором: `clear` → `Clear-Host` і
    `$x -ne $null` → `$null -ne $x` (Maintenance), два мертвих
    присвоєння (`$compatibilityIssues` в Archive, `$pendingAge` в
    Health).
  - Самотест: `StaticAnalysis/SecurityRulesAreBlocking`,
    `StaticAnalysis/NoGlobalSecurityRuleExclusions` та ще три —
    охороняють від повернення глобальних виключень.

- Внутрішній код-рев'ю, рефакторинг: `Get-SanitizedWinSCPDiagnostic`
  (маскування паролю/host key у діагностиці WinSCP.com) перенесено зі
  `BRAVO.Archive.Runtime.ps1` у спільний `BRAVO.ArchiveRuntime` — раніше
  функція була продубльована лише в Archive, а `Invoke-WinSCPHealthSession`
  (`BRAVO.Health.Runtime.ps1`) повертав `Output`/`ErrorOutput` без
  санітизації взагалі; тепер обидва runtime використовують одну спільну
  реалізацію, і Health-сесія санітизує результат одразу в джерелі.
- Внутрішній код-рев'ю (не з формального аудиту, точкові виправлення):
  - `Enter-BRAVOWinSCPProcessLock` (`BRAVO.ArchiveRuntime`) тепер приймає
    явний параметр `-LogPath` замість мовчазного покладання на
    `$global:logPath` — якщо модуль колись імпортується до ініціалізації
    конфігу, функція явно повертає помилку замість створення lock-файлу
    у непередбачуваному відносному шляху.
  - `Get-HostInformation` (`BRAVO.Notifications`) логує `WARNING`, якщо
    `$global:hostInformationSettings` взагалі не ініціалізовано — раніше
    public IP lookup тихо трактувався як вимкнений без жодного сліду.
  - `New-BRAVOVSSSnapshotLink` (`BRAVO.Archive.Runtime.ps1`): шляхи для
    `cmd.exe /c mklink` тепер явно квотуються.
  - `BRAVO_ARCHIV.ps1`/`BRAVO_HEALTH.ps1`/`BRAVO_MAINTENANCE.ps1`:
    невдалий `Import-Module` на старті (пошкоджене розгортання) тепер
    завершує процес кодом `90` (`InternalError`) замість довільного
    коду виключення PowerShell — дотримання контракту кодів завершення
    навіть на найранішому етапі entrypoint.

- AUD-001 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P0.1): доданий CI —
  `.github/workflows/ci.yml`, `windows-latest` (проєкт цільово Windows
  PowerShell 5.1, не PowerShell 7 — між ними вже траплялись реальні
  поведінкові розбіжності в цьому репозиторії, тому раннер саме
  Windows, кроки через `shell: powershell`). Запускається на кожен
  push і PR у `master`/`developer`: парсинг усіх `.ps1`/`.psm1`/`.psd1`,
  UTF-8 BOM (обов'язковий для PowerShell-файлів, заборонений для
  `.md`), валідність JSON, `PSScriptAnalyzer` (блокує на
  `Severity=Error`, `Warning`/`Information` — інформаційно, кілька
  правил навмисно виключено як такі, що суперечать усталеній
  архітектурі — `PSAvoidUsingWriteHost`/`PSAvoidGlobalVars`), повний
  `BRAVO_SELF_TEST.ps1`, сканування секретів (`gitleaks`, окрема
  Linux-джоба).

  **Явно НЕ зроблено:** GitHub branch protection (required status
  checks, заборона прямого push у `master`) — CI лише показує статус,
  технічно ще не блокує merge, доки власник репозиторію не ввімкне це
  вручну в налаштуваннях GitHub. `SECURITY.md`/`RELEASE_CHECKLIST.md`
  оновлені, щоб чесно відображати цей проміжний стан.

- AUD-016 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md: усунено структурну
  причину повторюваного бага з `releaseChannel`. Раніше значення
  зберігалося як буквальний рядок, що вручну підтримувався різним на
  `master` (`"stable"`) і `developer` (`"development"`) — кожен merge
  `developer` → `master` вимагав окремого follow-up commit; у цій самій
  сесії fast-forward-мержі двічі мовчки протягували значення не в той
  бік (спочатку `"development"` на `master` після мержу PR, потім
  `"stable"` назад на `developer` після виправлення).

  `VERSION.json.releaseChannel` тепер — нейтральний fallback
  (`"stable"`), **однаковий на обох гілках**. Реальний channel визначає
  новий `Resolve-BRAVOReleaseChannelFromGit` (`BRAVO_CONFIG_LOADER.ps1`)
  напряму з `.git/HEAD` (без виклику `git.exe`): `master`/`main` →
  `stable`, `developer` → `development`, будь-яка інша гілка, detached
  HEAD або відсутній `.git` (розгорнутий production-сервер) — fallback
  на статичне значення з `VERSION.json`. Новий `ReleaseChannelSource`
  (`git-branch`/`VERSION.json`/`legacy`) у метаданих версії показує,
  звідки взято ефективне значення.

  Додано self-test `Version/ReleaseChannelResolvedFromGitBranch`
  (`Resolve-BRAVOReleaseChannelFromGit` із синтетичним `.git/HEAD`),
  `Version/DeveloperBranchResolvesToDevelopmentViaGit`,
  `Version/StaticReleaseChannelIsNeutralFallback`.

  Під час розробки виявлено ще один класичний PowerShell-гачок:
  непереданий параметр типу `[string]` дефолтить у `""`, а не `$null` —
  перевірка `if ($null -eq $GitHeadContent)` для визначення "чи викликач
  передав -GitHeadContent явно" завжди була `$false`, тому функція
  ніколи не читала реальний `.git/HEAD`. Виправлено через
  `$PSBoundParameters.ContainsKey('GitHeadContent')`.

- AUD-008 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P1.6): sanity-check
  обсягу backup. Технічно валідний архів (7za test + SHA512 збігається)
  все одно може бути підозріло малим через неправильне джерело, зламані
  permissions чи неповний VSS exposure. Нові
  `Test-BRAVOBackupSizeAnomaly`/`Get-BRAVOValidArchiveSizeHistory`
  (`modules\BRAVO.ArchiveHelpers`) порівнюють розмір щойно створеного
  архіву з медіаною останніх валідних (hash-підтверджених) архівів того
  самого компонента; новий `backupMonitoring.SizeSanity` у `BRAVO.config`
  (`Enabled`/`HistoryCount`/`MinimumBytes`/`MaxSizeDropPercent`).
  Перший backup компонента (без історії) не вважається аномалією.
  Виявлена аномалія НЕ блокує backup — лише `WARNING` у журналі й статус
  кроку `Архівація <компонент>` підвищується до `WARNING`, що потрапляє в
  лічильник попереджень і Slack/Discord-сповіщення.

- AUD-004 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P0.4): доданий restore
  drill — `BRAVO_RESTORE_TEST.ps1`. Читабельний і навіть SHA-512/7za-
  перевірений архів доводить лише незмінність байтів, не відновлюваність
  системи; новий скрипт бере найновіший локальний backup із коректним
  `.sha512` для кожного увімкненого компонента (`MODEL`/`BLOG`/`BRAVOEXCH`,
  `-Component` для одного або всіх), запускає `7za t` (перевикористано
  `Test-SevenZipArchiveIntegrity`), розпаковує в ІЗОЛЬОВАНИЙ тимчасовий
  каталог (не production-шлях, ACL SYSTEM+Administrators+поточний
  користувач, видаляється одразу після перевірки — навіть при помилці,
  через `finally`), звіряє кількість розпакованих файлів проти
  `-MinimumFileCount` і повертає контрактний exit code (`0`/`10`/`41`)
  та машинно-читаний JSON (`-ResultPath`/`-AsJson`). Сповіщення в
  Slack/Discord — лише при `WARN`/`FAIL`, якщо не задано
  `-SkipNotification`. Read-only діагностика: не видаляє, не переміщує й
  не змінює жоден існуючий backup, елевація не потрібна.

  Новий спільний компонент `Invoke-BRAVOSevenZipExtraction`
  (`modules\BRAVO.Compatibility`) — розпакування архіву, дзеркалить уже
  наявний `Invoke-BRAVOSevenZipIntegrityTest` (той самий
  ProcessStartInfo/stdin-пароль патерн, пароль ніколи не потрапляє до
  командного рядка чи логів).

  Restore drill НЕ входить до типового набору завдань
  `BRAVO_TASKS_INSTALL.ps1` — рекомендовано (розділ 6.1 README.md)
  додати окреме щотижневе/щомісячне завдання Планувальника вручну.

- AUD-007 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P1.1/P1.2): захист від
  неоднозначного й дрейфового discovery. `Resolve-BRAVOInstallationDiscovery`
  тепер позначає `Ambiguous.BravoRoot`/`Ambiguous.WebRoot`, якщо знайдено
  кілька служб BRAVO/Apache із РІЗНИМИ виконуваними файлами (ознака
  stale/дублюючої інсталяції) — `Test-BRAVODiscoveryResult` блокує
  валідацію для будь-якого увімкненого компонента, що залежить від
  неоднозначного кореня. Додано `Save-BRAVODiscoveryBaseline` і
  `Compare-BRAVODiscoveryBaseline`: `BRAVO_SETUP.ps1 -ValidateOnly`
  порівнює поточний discovery-результат зі збереженим
  `LOGS\DISCOVERY_BASELINE.json` (поза git) і повідомляє про дрейф
  джерел відносно останнього підтвердженого запуску (лише попередження,
  не блокує); новий switch `-ConfirmDiscoveryBaseline` явно фіксує
  поточний результат як baseline.

  Під час розробки виявлено й виправлено реальний баг у самому модулі
  `BRAVO.Discovery`: ідіома `return ,@($collection.ToArray())`
  (застосована раніше для фіксу розгортання 1-елементного масиву в
  скаляр під Set-StrictMode -Version 2.0 на Windows PowerShell 5.1) при
  ПОРОЖНІЙ колекції створює масив з ОДНИМ елементом-порожнім-масивом, а
  не порожній масив — той самий клас бага, лише в інший бік. Спроба
  виправити через `Write-Output -NoEnumerate` натомість ламала виклики,
  де результат додатково обгортається `@(...)` на боці клієнта
  (подвійне обгортання). Остаточне рішення: звичайний `return
  $collection.ToArray()` у `Test-BRAVODiscoveryResult` і
  `Compare-BRAVODiscoveryBaseline`, а всі точки виклику (в
  `BRAVO_SETUP.ps1` і `BRAVO_SELF_TEST.ps1`) уніфіковано завжди
  обгортають виклик `@(...)` — єдиний послідовний контракт, який
  коректно повертає масив для 0, 1 і N елементів незалежно від стилю
  виклику.

- AUD-017 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md: виправлено застарілий
  рядок у `SECURITY.md` (розділ 8), який стверджував, що
  `RELEASE_CHECKLIST.md` "наразі не існує" — файл вже доданий раніше
  (P2.6). Розділ 8 тепер лише чесно перелічує те, що справді ще не
  реалізовано (threat model, CI/CD gate, SFTP/SMB key auth,
  `AppLocker`/`WDAC`/`gMSA`), без згадки вже виконаних пунктів.
  Контакт і SLA в розділі 2 (`[заповнити]`) свідомо лишені як є —
  власник репозиторію ще не надав реальні значення.

- CLAUDE_CODE_TZ_ARCHIV_LIMS_MONOLITH.md: визначення джерел резервного
  копіювання (`MODEL`, `BLOG`, `BRAVOEXCH`, `BAZA_APP`, `BAZA_WWW`,
  `BRAVO_ROOT`, `WEB_ROOT`) тепер відбувається автоматично на основі
  активної інсталяції BRAVO (служба `BRAVO`, служба Apache, файл
  `bravo.ini`), з повним ручним перевизначенням через
  `$global:discoverySettings` у `BRAVO.config`. Новий модуль
  `modules\BRAVO.Discovery\` (`Get-BRAVOServiceExecutablePath`,
  `Find-BRAVOServiceByCandidates`, `ConvertFrom-BRAVOIniFile`,
  `Resolve-BRAVOInstallationDiscovery`, `Test-BRAVODiscoveryResult`)
  реалізує пріоритетний ланцюг: явний override → значення з `bravo.ini`
  → попередня LIMSRoot-відносна поведінка (legacy fallback) — 100%
  зворотної сумісності для інсталяцій без служби BRAVO/Apache або без
  `bravo.ini`. Слабка евристика `Find-BRAVOExchSourceDirectory`
  (фіксований список кандидатів) замінена: значення з `bravo.ini`
  (`BEXCH=`) тепер має найвищий пріоритет, а старі жорстко задані
  кандидати (`exchangAPI`, `bravoexch`, `C:\bravoexch`) лишаються лише як
  запасний варіант. `Archive.Runtime.ps1`/`Health.Runtime.ps1`/
  `Maintenance.Runtime.ps1` не змінювались — вони читають ті самі
  глобальні змінні (`$global:sourcePaths`, `$global:bazaPaths` тощо), які
  тепер заповнюються результатом discovery замість прямих обчислень.

  `BRAVO_SETUP.ps1 -ValidateOnly` виводить новий розділ
  `=== DISCOVERY ДЖЕРЕЛ ===` (знайдені служби, шлях `bravo.ini`, кожне
  джерело з поясненням походження значення) і викликає
  `Test-BRAVODiscoveryResult` для перевірки увімкнених джерел і
  каталогів призначення — без аварійного завершення самого wizard.
  `BRAVO.config` свідомо НЕ виконує жорстку валідацію (throw) при
  звичайному завантаженні: увімкнені за замовчуванням компоненти
  (`MODEL`/`BLOG`/`BRAVOEXCH`) на сервері без реальної інсталяції LIMS
  зламали б кожен виклик `Import-BravoConfiguration`, включно з
  `BRAVO_SELF_TEST.ps1`.

  Додано self-test `Discovery/IniParserHandlesRealBravoIniFormat`,
  `Discovery/ResolvesFromServiceAndIniWithoutOverride`,
  `Discovery/ExplicitOverrideWinsAndIsNeverReplaced`,
  `Discovery/LegacyFallbackWhenNoServiceFound`,
  `Discovery/ValidationDetectsMissingEnabledSourceOnly`,
  `Discovery/WiredIntoConfigLoaderAndSetup`.

  Під час розробки `Test-BRAVODiscoveryResult` спершу повертав масив
  помилок через `return @($errors)`, що на Windows PowerShell 5.1 і
  `Set-StrictMode -Version 2.0` розгортається пайплайном у скаляр при
  рівно одному елементі — виклик `.Count` на такому скалярі (рядку) падав
  з `PropertyNotFoundStrict`, бо `String` не має `.Count` до PowerShell 7.
  Виправлено уніарною комою (`return ,@($errors.ToArray())`), що
  гарантує повернення масиву незалежно від кількості елементів.

## 4.2.13 — 2026-08-04

- P2.7 з плану виправлень: виправлено дрібні зауваження документації.
  README.md більше не має дубльованого рядка-заглушки `BRAVO_*.ps1` у
  дереві каталогів (розділ 2) — дерево тепер перелічує реальні файли
  комплекту, включно з `SECURITY.md`/`RELEASE_CHECKLIST.md`/`VERSION.json`
  і каталогом `modules`. Додано матрицю діагностики за кодом завершення
  (розділ 12): для кожного коду (`20`–`90`) — найімовірніша причина і де
  саме в журналі шукати деталі, доповнює вже наявну таблицю значень
  кодів і `LastTaskResult` Task Scheduler. Пункти аудиту про lifecycle
  `.partial`, manifest архіву й restore drill свідомо НЕ додано до
  README — ці функції ще не реалізовані (P1.4/P1.5/P0.5), документувати
  їх як наявні означало б написати неправду; прогалини вже чесно
  перелічені в `SECURITY.md`/`RELEASE_CHECKLIST.md`. Опис підтримуваних
  версій ОС і чітке розділення development/stable вже було зроблено
  раніше (P0.4/P0.6) — цей пункт лише перевірено, без змін.

  Під час розробки матриці власний новий self-test спершу хибно падав
  через несподіваний артефакт: у PowerShell зворотна лапка `` ` `` є
  символом екранування навіть у звичайному подвійному рядку, тому
  `"| `31` |"` тихо перетворювалось на `"| 31 |"` (без лапок) ще на
  етапі парсингу — Contains-перевірка порівнювала вже спотворений
  рядок і завжди повертала false. Виправлено переходом на одинарні
  лапки для цього шаблону.

- P2.6 з плану виправлень: додано `RELEASE_CHECKLIST.md`. Розділ 1 —
  пункти, які реально виконуються сьогодні й частина яких уже забезпечена
  self-test (`Version/ModuleManifests`, `Version/BuildIdSurfacedInRuntimes`,
  `Version/StableBranchNotDevelopmentChannel`). Розділ 2 — свідомо окремо
  винесені рекомендації аудиту, які в цьому репозиторії ще не
  автоматизовано (PSScriptAnalyzer, secret scanning, підписаний release
  manifest, restore drill тощо) — не позначені чекбоксами обов'язкового
  виконання, щоб чек-лист не створював хибного враження виконаної роботи.
  Додано self-test `Documentation/ReleaseChecklistExists` і
  `Documentation/ReleaseChecklistCoversRequiredSteps`.

- P2.4 з плану виправлень: додано `SECURITY.md` — підтримувані версії
  (продукт і ОС/PowerShell), порядок повідомлення про вразливості, модель
  секретів (Credential Manager, `Protect-BRAVOLogSecret`, очищення
  script-scope змінних), модель довіри до Tools (TOFU, чесно
  задокументовані відсутні Authenticode/Fail-режим/підписані завдання),
  модель ACL, обмеження Credential Manager (прив'язка до облікового
  запису, відсутність gMSA), політика оновлення. Документ описує
  фактичний поточний стан, включно з відомими незакритими прогалинами —
  не видає заплановане за вже реалізоване. Секції SLA/контакту для
  повідомлення про вразливості лишено як явний placeholder для власника
  репозиторію. Додано self-test `Documentation/SecurityMdExists` і
  `Documentation/SecurityMdCoversRequiredSections`.

- P1.6 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`): Health
  тепер окремо повертає `LocalVerified`/`SftpVerified`/`SmbVerified` у
  result object (усі 7 гілок `return Complete-BRAVOHealthResult`), а не
  лише агрегований `Status`/`IssueCount` — зовнішній моніторинг більше не
  втрачає деталізацію "локальні копії в порядку, а SFTP деградував" за
  єдиним `Status = "Critical"`. Кожен напрямок обчислюється незалежним
  викликом (`Get-BackupHealthIssues`/`Get-BAZALocalHealthIssues`/
  `Get-SFTPHealthIssues`/`Get-SMBHealthIssues`) — жоден не перериває
  виконання інших при відмові, тому сам механізм перевірок не
  редагувався, лише додано `Get-BRAVOHealthDestinationSummary`, яка
  зводить уже наявні незалежні списки issues у три прапорці. Додано
  self-test `Health/DestinationSummaryAlgorithm` (функціональний, на
  синтетичних issues) і `Health/DestinationSummaryWiredIntoAllResults`
  (текстовий, підтверджує підключення до всіх 7 місць повернення).

- P1.8 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `BRAVO_OPERATION.lock` (спільний exclusive-lock Archive/Maintenance)
  тепер містить структуровані JSON-метадані замість голого
  `"PID=...; Started=...; Config=..."`: `pid`, `processStartTime`
  (реальний час старту процесу з `Get-Process`, не лише PID — відрізняє
  той самий PID, перевикористаний після перезавантаження сервера, від
  справді активного запуску), `hostname`, `operation`
  (`Archive`/`Maintenance`), `startedAt`, `packageVersion`, `config`.
  Сам механізм lock не змінено — це вже реальний ексклюзивний файловий
  handle (`FileShare.None`), який Windows звільняє автоматично при
  аварійному завершенні процесу, тому окремої перевірки "живий PID перед
  видаленням stale lock" не було потрібно, на відміну від класичних
  PID-файлів. Додано self-test `Scheduler/OperationLockMetadata`.

- P1.9 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  катастрофи ErrorRecord навколо завантаження `BRAVO.config` і читання
  Credential Manager (SFTP/SMB/архів/webhook) в Archive/Health/Maintenance
  друкували `$_.Exception.Message` через `Write-Host`/`Write-Error`
  напряму в консоль, минаючи єдину точку масковки секретів
  (`Write-Log`/`Write-BRAVOLog`/`Write-HealthLog`, яка вже маскує
  `Protect-BRAVOLogSecret`). Тепер ці catch-блоки маскують повідомлення
  винятку одразу при захопленні — так безпечним лишається кожне подальше
  читання відповідних script-scope змінних (`credentialInitializationError`,
  `archiveCredentialInitializationError`, `smbCredentialInitializationError`,
  `notificationCredentialInitializationError`,
  `ArchiveCredentialError`/`NotificationCredentialError` у Maintenance), а
  не лише перший вивід. Додано self-test
  `Runtime/CredentialAndConfigErrorsMaskedAtCapture`.

- P1.10 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `hostInformationSettings.PublicIPLookupEnabled` у `BRAVO.config` тепер
  `$false` за замовчуванням — раніше кожен запуск Health/Maintenance
  звертався до `api.ipify.org`/`checkip.amazonaws.com`, зайвої зовнішньої
  залежності, яка розкриває стороннім сервісам факт і час запуску backup.
  Внутрішній fallback у `Get-HostInformation` (`BRAVO.Notifications`) на
  випадок відсутньої конфігурації узгоджено з тим самим `$false`. Якщо
  вимкнено, `Get-HostInformation` не робить жодного мережевого запиту й
  одразу повертає `PublicIP = "вимкнено"`. Додано self-test
  `Notifications/PublicIPLookupDisabledByDefault`.

- P0.4 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  формалізовано мінімально підтримувану ОС трьома рівнями — Supported
  (Windows Server 2019+, Windows 10/11, PowerShell 5.1), Legacy best-effort
  (Server 2012 R2, Server 2016, без гарантій) і Unsupported (Windows 7,
  Server 2008 R2, PowerShell 3.0). Раніше README декларував єдиний
  розмитий baseline "Windows 7 / Server 2008 R2 або новіша", без жодної
  різниці в поведінці між дуже старою й сучасною системою. Нова
  `Get-BRAVOOSSupportTier` (`BRAVO.Compatibility`) визначає рівень при
  кожному запуску Archive/Health/Maintenance і завжди пише в журнал точну
  версію ОС, build, PowerShell і .NET, незалежно від рівня. `Legacy
  best-effort` лише попереджає; `Unsupported` блокує production-запуск
  (код `30`, `InvalidConfiguration`) — продовжити свідомо можна лише через
  явний override `BRAVO_ALLOW_UNSUPPORTED_OS=1` в середовищі процесу.
  Для Health, яка може викликатися програмно через dot-source
  (`Invoke-BRAVOHealthCheck`), заборона повертається як звичайний
  `Status = "ConfigurationError"`, а не через `exit`, щоб не завершувати
  процес виклика́ча. Додано функціональні self-test на синтетичних
  Win32_OperatingSystem-подібних даних (Get-BRAVOOSSupportTier не можна
  протестувати на реальній іншій ОС) і текстову перевірку підключення
  guard-у в усі три runtime.

- P1.7 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `Remove-OldBackupSets` більше не може видалити останню перевірену
  копію компонента. Раніше retention був прив'язаний лише до календарного
  віку (`archiveRetentionDays`) — серія невдалих backup, після якої всі
  ще валідні (SHA512 збігається) комплекти виявились старшими за retention,
  могла видалити їх усі й лишити компонент без жодної придатної копії.
  Новий `BRAVO.config`-параметр `minimumRetainedVerifiedBackups`
  (за замовчуванням `1`) захищає N найновіших перевірених комплектів від
  видалення незалежно від віку; список кандидатів на видалення будується
  через `Select-Object -Skip $minimumRetainedCount` на вже відсортованому
  за спаданням часу списку. Додано текстову перевірку self-test, що
  підтверджує підключення механізму в реальний код, і окрему функціональну
  перевірку алгоритму відбору на синтетичних даних (Archive.Runtime.ps1
  безумовно запускає `Main` при dot-source, тому саму функцію в self-test
  безпечно викликати не можна).

- Упорядковано release channels (P0.6 з плану виправлень
  `ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`): `VERSION.json.releaseChannel`
  тепер відповідає гілці — `development` на `developer`, `stable` на
  `master`. Додано self-test `Version/StableBranchNotDevelopmentChannel`,
  який визначає поточну git-гілку і забороняє `releaseChannel=development`
  на `master`/`main`; перевірка м'яко пропускається, якщо `.git`
  недоступний (розгорнутий release-пакет без клону репозиторію). У
  README задокументовано відповідність гілка → канал.

- Повторний аудит (`ARCHIV_LIMS_MONOLITH_REPEAT_AUDIT.md`, P1) вказав: після
  релізного коміту `v.4.2.12` у код внесено суттєві зміни (StrictMode-фікси,
  VSS exposure, ACL runtime, нове логування, маскування секретів, integrity
  preflight, формальна модель exit code, класифікація restore errors,
  виправлення тегів журналу), але `VERSION.json` і всі 13 module manifests
  продовжували показувати `4.2.12` — дві збірки з однаковим номером версії
  могли мати різний код і різну поведінку.
- `VERSION.json` отримав нове обов'язкове для нових релізів (але не для
  вже розгорнутих старих копій) поле `buildId` — короткий git-hash коміту,
  з якого зібрано випуск. `Get-BravoVersionMetadata`
  (`BRAVO_CONFIG_LOADER.ps1`) читає його як необов'язкову властивість,
  щоб оновлення поверх старішого `VERSION.json` без `buildId` не ламалось.
  Значення прокидається як `$global:ScriptBuildId`, той самий шаблон, що
  вже використовувався для `ScriptVersion`/`ScriptDate`.
- Archive, Health і Maintenance тепер показують build ID у консолі/журналі
  та в Slack/Discord-сповіщеннях поруч з версією й датою (`Версiя та дата
  скрипта: 4.2.13 вiд 2026-08-04` + окремий рядок `Збірка (build): ...` в
  Archive; `(build ...)` у сповіщеннях Health і Maintenance).
- `ModuleVersion` усіх 13 module manifests і версія в заголовках `README.md`
  та `BRAVO_SETUP.md` синхронізовано з `VERSION.json` (`4.2.13`).
- Додано self-test `Version/BuildIdSurfacedInRuntimes` (build ID справді
  прокидається у всі три runtime) і розширено `Version/AuthoritativeLoader`
  перевіркою, що `ScriptBuildId` відповідає `buildId` у `VERSION.json`.

## 4.2.12 — 2026-08-03

- Виправлено хибне тегування підсумкового рядка `Результат:` у
  `BRAVO_ARCHIV`: заголовок секції health-check (`=== ПЕРЕВІРКА СТАНУ
  РЕЗЕРВНИХ КОПІЙ ===`) виставляв компонент журналу на `HEALTH` і нічого не
  повертало його назад на `SUMMARY`, тому фінальний рядок з результатом
  усього запуску потрапляв у лог під тегом `[HEALTH]` навіть тоді, коли
  сам health-check пройшов успішно, а `ПОМИЛКА` була викликана чимось
  іншим (наприклад провалом перевірки цілісності одного з архівів). Тепер
  `Set-BRAVOLogComponent -Component 'SUMMARY'` явно виставляється перед
  цим рядком.

- Формальний контракт кодів завершення (`modules/BRAVO.ExitCodes`): замість
  `0`/`1` Archive, Health і Maintenance тепер повертають одне з `0`
  (успішно), `10` (успішно з попередженнями), `20` (пропущено — lock
  зайнятий), `30` (некоректна конфігурація), `31` (немає credentials),
  `40` (помилка локальної архівації), `41` (не підтверджено цілісність),
  `50` (SFTP failed), `51` (SMB failed), `60` (Maintenance failed), `70`
  (Health critical), `90` (внутрішня непередбачена помилка). Дозволяє
  зовнішньому моніторингу (Task Scheduler history, Zabbix) розрізняти
  причину збою, а не лише факт його наявності. При одночасних відмовах
  переможець визначається пріоритетом (lock > config > creds > local
  archive > integrity > SFTP > SMB > maintenance > health > warnings).
  Заразом узгоджено: Archive більше не трактує статуси Health `Disabled`/
  `Deferred` як власну відмову — сам Health вважає їх безпечними. Maintenance
  також розрізняє `40`/`41` для власних операцій відновлення: помилка
  створення/розпакування локального архіву (`Restore-FromArchive`, попередній/
  контрольний архів навколо відновлення) повертає `40`, а провал 7-Zip test /
  SHA512-звірки чи розбіжність розміру файлів — `41`; решта відмов Maintenance
  (сервіси, диск, файлове господарство, оркестрація BRAVO_ARCHIV) лишаються
  спільним `60`, як і раніше.
- Runtime Archive, Health і Maintenance та спільні бібліотеки перенесено до
  versioned PowerShell-модулів у каталозі `modules`; task-entrypoint-и залишено
  тонкими стабільними wrappers.
- `BRAVO.ArchiveHelpers` отримав явний logger callback і більше не залежить від
  приватного `Write-Log` caller-а; додано runtime smoke-test цієї межі модуля.
- Програмний Health API гарантовано очищає SFTP/SMB credential state у `finally`.
- Пошук WinSCP .NET components і перевірку цілісності 7-Zip централізовано у
  спільних модулях без дубльованих реалізацій у domain runtime.
- Процедуру оновлення змінено на атомарну заміну всього комплекту разом із
  каталогом `modules`; опис передачі пароля 7-Zip синхронізовано з реалізацією.
- Виправлено конфігурацію SFTP, яка падала на кожному запуску: `$sftpHost`
  ніде не присвоюється, а централізований завантажувач конфігурації привніс
  `Set-StrictMode`, тому звернення до неоголошеної змінної стало помилкою.
  Archive, Health і dry-run тепер читають legacy-змінні через `Get-Variable`.
- Тим самим способом полагоджено legacy-гілки `$archiveVersions` (строк
  зберігання архівів) і `$networkCopyConfig` (шлях SMB у dry-run): раніше вони
  не могли спрацювати й обривали відповідну перевірку.
- VSS-архівація більше не передає 7-Zip шлях `\\?\GLOBALROOT\Device\...`,
  який .NET не читає: знімок експонується через каталогове символічне
  посилання, що прибирається разом зі знімком.
- Завантажувач конфігурації читає `VERSION.json` і `BRAVO.config` явно як
  UTF-8, попереджає про розбіжність версій між ними і вимагає, щоб файл
  конфігурації лежав усередині каталогу конфігурації.
- Версію в `README.md` і `BRAVO_SETUP.md` синхронізовано з `VERSION.json`.
- Прибрано `REMOVE_OLD_ARCHIV_LIMS.ps1` разом із блоком `Cleanup/*` у
  самотесті, який безумовно читав цей файл і через це падав.
- Виправлено аудит P1 (ненадійний `$LASTEXITCODE`): у `Archive.Runtime.ps1`
  повторний `throw` усередині `catch { $script:processExitCode = 1; throw }`
  ніколи не доходив до власного `Exit` runtime, і код виходу процесу
  визначала загальна поведінка PowerShell на необроблену помилку, а не
  керована логіка BRAVO. Усі три `.psm1`-обгортки (Archive/Maintenance/
  Health) тепер викликають runtime у `try/catch`: на непередбаченому
  винятку повертається керована `1` (пізніше синхронізовано з новим
  контрактом exit code — див. вище), повідомлення виводиться через
  `Write-Error`.
- Маскування секретів (`Protect-BRAVOLogSecret`) поширено з Archive також
  на Health (`Write-HealthLog`) і Maintenance (`Write-Log`): раніше вони
  писали повідомлення без маскування, і виняток WinSCP чи webhook-запиту
  міг потрапити в лог/консоль разом з обліковими даними. Заразом
  виправлено дві прогалини самого `Protect-BRAVOLogSecret`: Slack/Discord
  webhook URL не маскувались зовсім, а коротка форма пароля 7-Zip (`-p`)
  повторно "з'їдала" вже замасковане правило `-password=***`.
- Додано integrity preflight для інструментів у `Tools`
  (`7za.exe`, `WinSCP.com`, `WinSCPnet.dll`): `Get-BRAVOToolIntegrityRecommendation`
  (`BRAVO.Compatibility`) за моделлю trust-on-first-use на першому запуску
  фіксує SHA-256 кожного наявного інструмента в `Tools\TOOLS_INTEGRITY.json`,
  а на кожному наступному звіряє і лише попереджає при розбіжності —
  виконання свідомо не блокується, підміна файлу могла бути легітимним
  оновленням. Підключено в Archive/Health/Maintenance поруч із наявними
  рекомендаціями про PowerShell і Windows.

## 4.2.11 — 2026-08-03

- `BRAVO_SETUP -ValidateOnly` більше не запитує UAC: режим виконує лише
  read-only перевірки.

## 4.2.10 — 2026-08-03

- WinSCP process lock інтегровано у спільний compatibility runtime; прибрано
  дубльовані `Start/Complete-BRAVOProcessOutputCapture` з SFTP runtime.

## 4.2.9 — 2026-08-03

- Standalone `BRAVO_HEALTH` підключає SFTP runtime з перевіркою активного
  WinSCP та process lock, тому SFTP health-check не залежить від архіватора.

## 4.2.8 — 2026-08-03

- Інтервал health-check тепер визначається лише `BRAVO.config` (240 хвилин);
  інсталятор Планувальника більше не змінює його неявно.
- Перевірка активного WinSCP використовує спільний WMI/CIM fallback і працює
  на підтримуваних старих версіях Windows PowerShell.

## 4.2.7 — 2026-08-03

- Health-перевірку винесено з `BRAVO_ARCHIV.ps1` у самостійний
  `BRAVO_HEALTH.ps1`; Планувальник запускає його напряму.
- `BRAVO_ARCHIV` після backup викликає спільний health runtime, а застарілий
  параметр `-HealthCheckOnly` лише сумісно перенаправляє до нового скрипта.
- Health runtime підключає `BRAVO_COMPATIBILITY.ps1` і
  `BRAVO_CREDENTIALS.ps1`, не дублюючи їхню функціональність.
- `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE` також переведено зі вбудованих копій
  compatibility/credentials на спільні файли. Специфічний WinSCP lock
  архіватора винесено до `BRAVO_ARCHIV_RUNTIME.ps1`.

## 4.2.6 — 2026-08-03

- Планувальні завдання `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE`, запущені від
  `SYSTEM`, більше не намагаються відкрити інтерактивний UAC (`RunAs`). Це
  усуває код результату Планувальника `0x80070001` / `2147942401`.
- Додано регресійну перевірку, що обидва сценарії розпізнають SID LocalSystem
  `S-1-5-18` і не запускають UAC у цьому контексті.

## 4.2.5 — 2026-08-03

- Runtime ACL тепер застосовується рекурсивно до наявних файлів і папок перед
  реєстрацією SYSTEM-завдань.
- Усі BRAVO-утиліти використовують спільний loader конфігурації; VETOFFICE
  залишається окремим legacy-шляхом.
- Усунуто колізію імен у credentials-утиліті з функцією loader-а PowerShell.
- Версію та дату релізу централізовано у `VERSION.json`; усунено розбіжність
  документації з фактичною періодичністю health-check.

## 4.2.4 — 2026-08-03

- Виправлено виклики централізованого завантажувача конфігурації в обох
  entrypoint-ах `BRAVO_ARCHIV.ps1`: тепер вони передають обов'язковий
  параметр `-ConfigRoot`.
- `BRAVO_TASKS_INSTALL.ps1` і `BRAVO_SELF_TEST.ps1` переведено на спільний
  `BRAVO_CONFIG_LOADER.ps1`; додано регресійну перевірку контракту loader-а.
- Прибрано хибне попередження про розбіжність версій, коли legacy-версія в
  `BRAVO.config` навмисно відсутня.

## 4.2.1 — 2026-07-30

### Узгодженість резервних копій

- Щоденні архіви `MODEL`, `BLOG` і `BRAVOEXCH` тепер створюються з окремих
  моментальних VSS-знімків локальних томів у контексті `ClientAccessible`.
- `BRAVO_ARCHIV` не зупиняє служби під час backup. Якщо VSS-знімок створити
  неможливо, компонент завершується з помилкою без небезпечного переходу до
  архівації live-каталогу.
- Після штатного завершення або обробленої помилки компонента VSS-знімок
  видаляється у `finally`; окремо обробляються та журналюються коди помилок
  створення й очищення VSS.
- У `BRAVO.config` додано обов'язковий блок `backupConsistency`; self-test
  перевіряє режим `VSS`, контекст і побудову шляху `GLOBALROOT`.

### SFTP-синхронізація BAZA

- Режим `-SyncBAZA` синхронізує всі увімкнені джерела `BAZA_APP` і
  `BAZA_WWW`, окремо перевіряє їхні локальні шляхи та повертає загальний
  результат виконання.
- Webhook Slack/Discord завантажується також у режимі `-SyncBAZA`; виправлено
  ситуацію, коли налаштований webhook ставав порожнім через область видимості
  змінної.
- Несумісні з обмеженням WinSCP імена визначаються до синхронізації за
  фактичною довжиною UTF-8. Сумісні файли передаються, а несумісний залишок
  класифікується як завершений `degraded`-результат без марного повтору всього
  backup.
- Аудит до й після синхронізації розділяє передані, retryable та несумісні
  об'єкти; журнал пояснює, коли повторний запуск не потрібен.
- Сповіщення про несумісні імена містить установу, машину, IP-адреси, версію,
  час, ліміт WinSCP, п'ять читабельних прикладів і шлях до повного журналу.
- Імена в Discord екрануються як literal text і виводяться кожне з нового
  рядка без злиття через Markdown. Довгі повідомлення розбиваються на частини
  до 1900 символів.
- Виправлено граничний підрахунок Windows `CRLF`: двосимвольне перенесення
  рядка більше не створює Discord-повідомлення довжиною 1901 символ.

### Health-звіти

- У локальних і хмарних секціях health-звіту показується ім'я останнього
  архіву разом із віком і розміром.
- Ім'я локального еталонного архіву додається не лише до простроченої
  SFTP-копії, а й до повідомлень про відсутній файл, невідповідний розмір та
  інші помилки віддаленої копії.
- Символи Markdown у назвах файлів екрануються лише для Discord; Slack
  отримує початкове ім'я без зайвих зворотних рисок.

### Захист секретів і тимчасових файлів

- Пароль 7-Zip більше не додається до командного рядка процесу. Створення,
  перевірка та розпакування архівів передають пароль через `stdin` у
  `BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`, `ARCHIV_VETOFFICE` і спільному модулі
  сумісності.
- Заборонено лише паролі з символами нового рядка; подвійні лапки більше не
  потребують вставлення або маскування в process arguments.
- Тимчасові WinSCP-скрипти `BRAVO_ARCHIV` і `ARCHIV_VETOFFICE` створюються
  атомарно з GUID-іменами та захищеним ACL лише для поточного користувача,
  `SYSTEM` і `Administrators`.
- Перед видаленням конфіденційний тимчасовий файл очищується. Шлях
  перевіряється на належність системному temp-каталогу, а застарілі файли
  прибираються під час наступного запуску.
- SYSTEM-worker налаштування Credential Manager працює без `Write-Host`, коли
  немає інтерактивної консолі.

### Maintenance, setup і очищення

- Журнал maintenance має однозначне ім'я
  `BRAVO_MAINTENANCE_yyyyMMdd_HHmm.log`; очищення журналів підтримує новий і
  попередній формати назв.
- Планову реставрацію перенесено із середи `00:20` на неділю `03:00`;
  startup-recovery пропущеного запуску збережено.
- `BRAVO_SETUP.ps1` очікує підтвердження перед закриттям інтерактивного вікна;
  для автоматизованого запуску додано `-NoPause`, який зберігається після UAC
  elevation.
- Додано кероване очищення повних пар обідніх архівів `_1300.mdz` і
  `.sha512` за календарним віком. Очищення вимкнене за замовчуванням,
  перевіряє containment каталогу та не видаляє неповні комплекти.
- Додано окремий `REMOVE_OLD_ARCHIV_LIMS.ps1` із підтримкою `-WhatIf`,
  параметрами шляху, каталогів, строку зберігання й каталогу журналів.
  Часткові помилки, відсутні або небезпечні каталоги повертають exit code `1`;
  успішне виконання повертає `0`.

### Перевірки та документація

- `BRAVO_SELF_TEST` розширено зі статичного аналізу до static + runtime:
  фактично створюється й перевіряється зашифрований 7-Zip-архів із паролем
  через `stdin`.
- Додано runtime-перевірки Discord escaping і chunking, degraded-результату
  BAZA, VSS-шляху, ACL та видалення WinSCP-файлів, а також exit codes
  cleanup-скрипта.
- Статичні перевірки блокують повернення пароля 7-Zip до process arguments,
  live-архівацію без VSS, повторне використання небезпечних temp-файлів та
  втрату імен архівів у health-звіті.
- Dry-run, README і setup-документацію синхронізовано з VSS-вимогами, новими
  параметрами та єдиною версією `4.2.1`; згадку видаленого
  `QuiesceForBackup` прибрано з preflight-звіту.

## 4.2.0 — 2026-07-30

- Єдина версія та дата релізу зберігаються у `BRAVO.config` і додаються до повідомлень архівації, обслуговування та dry-run.
- Health-звіт показує лише увімкнені компоненти резервного копіювання, включно з окремими каталогами `BAZA_APP` і `BAZA_WWW`.
- Коректні комплекти резервних копій очищуються за календарним віком; типовий строк — 183 дні.
- Додано атомарне блокування запусків WinSCP та повідомлення про несумісні імена BAZA.

## 4.9.2 — 2026-07-27

- `BRAVO_ARCHIV` більше не зупиняє і не запускає Windows-служби за жодних
  налаштувань: він лише читає їхній стан, пише його в журнал і надсилає
  попередження, якщо служба не працює.
- Видалено `QuiesceForBackup`, функції керування службами та блок
  stop/start навколо створення архівів. Керування службами залишається лише у
  `BRAVO_MAINTENANCE`.
- Self-test перевіряє відсутність `Stop-Service`, `Start-Service` і колишніх
  функцій керування службами у `BRAVO_ARCHIV`.
- Версія конфігурації: 4.9.2; BRAVO_ARCHIV: 4.0.2;
  BRAVO_MAINTENANCE: 1.7.1.

## 4.9.1 — 2026-07-27

- `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE` до зупинки служб перевіряють їхній
  початковий стан та негайно надсилають одне зведене попередження у Slack/Discord,
  якщо одна або кілька керованих служб не працюють.
- Погодинний `BRAVO_ARCHIV_HEALTH` також контролює встановлені служби з типом
  запуску, відмінним від `Disabled`; активний operation lock запобігає хибним
  тривогам під час штатного backup/maintenance.
- Негайне попередження основних скриптів надсилається також у режимі
  `errors_only`, але саме по собі не змінює їхній exit code: початково зупинені
  служби не запускаються автоматично після backup/maintenance.
- Додано спільний HTTPS webhook-клієнт і статичні self-test перевірки цього сценарію.
- Версія конфігурації: 4.9.1; BRAVO_ARCHIV: 4.0.1;
  BRAVO_MAINTENANCE: 1.7.1.

## 4.9.0 — 2026-07-27

- Marker успішної реставрації MODEL тепер створюється атомарно в UTF-8 без BOM
  замість системного ANSI-кодування Windows PowerShell.
- При code `1+` або таймауті 7-Zip журнал архівації тепер записує останні
  діагностичні рядки stdout/stderr на рівні `ERROR`, незалежно від `LogLevel`;
  пароль архіву маскується.
- Перевірка principal Планувальника тепер порівнює вбудовані service accounts
  за SID, тому локалізовані назви на кшталт `СИСТЕМА` коректно розпізнаються
  як `SYSTEM` (`S-1-5-18`) і не спричиняють помилковий rollback.
- Допоміжні setup, dry-run, credentials, scheduler і self-test скрипти
  отримали окремі transcript-журнали у `LOGS\HELPERS`, фінальний exit code,
  31-денний retention і fallback до `%TEMP%`, якщо runtime недоступний.
- Додано кореневий `README.md` з єдиним маршрутом першої інсталяції,
  оновлення, dry-run, налаштування Credential Manager, Планувальника,
  діагностики запуску від `SYSTEM` і окремими командами VETOFFICE.
- Додано спільний `BRAVO_OPERATION.lock` для взаємного виключення backup і
  maintenance; конфліктуюче завдання очікує lock до шести годин.
- Щоденна архівація зупиняє лише служби, які працювали, створює та перевіряє
  локальні архіви, після чого гарантовано повертає початковий стан служб.
- Для щоденного backup вилучено `-ssw`: відкритий стороннім процесом файл
  спричиняє fail-closed помилку замість потенційно неузгодженого архіву.
- Credential setup отримав режим `Ensure`; повторний setup не перезаписує
  наявні секрети та параметри установи.
- Операції Credential Manager і реєстрація завдань отримали rollback при
  частковій помилці.
- Додано `BRAVO_TASKS_DIAGNOSE.ps1/.cmd`: перевірка реєстрації, action,
  working directory, `LastTaskResult` і dry-run від `NT AUTHORITY\SYSTEM`.
- Setup після встановлення Планувальника перевіряє SFTP, SMB, Credential
  Manager і тестове повідомлення від task account.
- Інсталятор вмикає Task Scheduler Operational log, захищає runtime ACL і
  відмовляється створювати SYSTEM-завдання з профілю користувача.
- Версія конфігурації: 4.9; BRAVO_ARCHIV: 4.0.0;
  BRAVO_MAINTENANCE: 1.7.0.
