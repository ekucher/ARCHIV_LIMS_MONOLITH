# Changelog

## Не випущено (developer)

- **SELF_TEST: fail-fast structural preflight і diagnostic timing
  telemetry (PR #138)** — рання fail-closed structural перевірка
  (runtime manifest integrity, обов'язкові manifest-файли, синтаксис
  production `*.Runtime.ps1`, критичний JSON) на bootstrap-межі, до
  імпорту manifest-covered helper-модулів; bootstrap integrity-scan
  збої тепер контрольований fail-closed шлях замість uncontrolled
  exception; Phase 0 short-circuit зупиняє доменні тести при провалі
  структурної перевірки. Додано diagnostic timing telemetry: total
  wall-clock (заморожується одразу після закриття останнього suite
  span, до рендерингу звіту), per-suite wall-clock, `Root (inline)`
  wall-clock, assertion interval telemetry, Top 20 найдовших
  assertion-інтервалів — вимірювання/діагностика, не оптимізація
  швидкості; `SELF_TEST` не пришвидшився внаслідок цього PR
  (P1 SELF_TEST performance optimization лишається окремим відкритим
  пунктом, `ROADMAP.md` P1.5). Розширено framework-регресії для
  bootstrap integrity, tampered manifest-covered helper, invalid
  bootstrap manifest, Phase 0 gate, fixture setup/cleanup провалів
  (включно з ACL/access-denied cleanup-станами — раніше
  `[IO.Directory]::Exists`-precheck хибно звітував `Success=$true` на
  недоступному через ACL каталозі без спроби видалення — і TEMP-
  незалежним fixture setup через `[IO.Path]::GetTempPath()`
  всередині guarded `try`). Final validation: `PASS: 1893, FAIL: 0,
  Exit: 0, Total wall-clock: 00:07:57.113`. Змерджено squash-комітом
  `57b16cba77ea4f30fa4464a9be2d8bfa122c132a`.

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

Стабільний реліз hotfix-лінії 5.2.1, промотований з прийнятого
`5.2.1-rc.9` (тег `v5.2.1-rc.9`, stamp `f99134d`) плюс додаткові
фікси/фічі нижче, наскрізно валідований через production acceptance
на preview-збірці `BRAVO-Toolkit-5.2.1-rc.10-preview-6737485.zip`
(знімок `6737485`, sha256
`8c70324596fa55a805877e767529d77d9ff4db9472f2626ae2e749bc27692155`):
Runtime Guard 82/82, SELF-TEST 1447/0, реальний Archive (MODEL/BLOG/
BRAVOEXCH + SFTP), синхронізація BAZA_APP/BAZA_WWW, доставка
CurrentUser/SYSTEM-сповіщень, retry-safe Recovery, BusyWait з 60-хв
перекриттям, CurrentUser/SYSTEM запис стану.

- **ФІКС P0 (self-test/health, ізоляція процесу): осиротіла службова
  функція-хелпер SELF-TEST могла затінювати production `Get-Service`/
  `Start-Service`/`Stop-Service`/`Get-CimInstance`/`Get-WmiObject` до
  кінця життя процесу.** `BRAVO_SELF_TEST.ps1` будує одноразові
  динамічні модулі/функції, щоб симулювати стани сервісів для своїх
  fixtures; прогалина в очищенні могла залишити одну з них затінювати
  реальний cmdlet у скоупі викликача після завершення SELF-TEST. У
  довгоживучому процесі (наприклад, хості запланованого завдання, що
  запускає SELF-TEST, а потім Health в одній сесії) це мовчки
  перетворювало реальні перевірки сервісів Health на замоковані
  результати. Новий реєстр володіння
  (`$script:BRAVOSelfTestOwnedRuntimeModules`) відстежує кожен
  динамічний модуль/функцію, що створює SELF-TEST;
  `Clear-BRAVOSelfTestOwnedRuntimeModules` видаляє їх усі перед
  поверненням SELF-TEST, виконується безумовно після
  верхньорівневого try/catch, перед обчисленням exit-коду. Пʼять
  нових fail-loud регресійних тестів підтверджують, що
  `Get-Service`/`Start-Service`/`Stop-Service` знову резолвляться в
  `Microsoft.PowerShell.Management`, і що жоден модуль/функція,
  володіні SELF-TEST, не лишаються експортованими після повного
  прогону. Повторно валідовано в тому ж процесі проти зібраного
  ZIP-артефакту (PID незмінний до/після SELF-TEST).
- **ФІЧА (health, сповіщення): семантична дедуплікація SUCCESS-звітів
  з retry-safe життєвим циклом Recovery.** Здоровий прогін Health
  тепер надсилає щонайбільше одне SUCCESS-сповіщення з дубльованим
  вмістом за вікно `backupMonitoring.SuccessDedupMinutes` (kit
  default `1380` = 23 год, один зелений звіт на день; вбудовані
  post-backup звіти та `-ForceNotification` завжди обходять
  дедуплікацію; `0` вимикає її). Recovery з нездорового стану ніколи
  не дедуплікується: новий прапорець операційного стану
  `RecoveryPending` виставляється в момент, коли Health стає
  нездоровим, і скидається лише після того, як SUCCESS-сповіщення
  Recovery дійсно доставлене — невдала доставка зберігає
  `RecoveryPending`, тож наступний здоровий прогін повторює спробу
  звіту про відновлення замість мовчазної дедуплікації.
- **ФІКС (health/scheduler): kit default
  `schedulerSettings.Health.BusyWaitMinutes` `20` -> `60`.** Production
  acceptance показав, що вікно блокування запланованого BAZASync може
  перевищувати 20 хвилин; Health тепер чекає до 60 хвилин, поки
  звільниться блокування archive, перш ніж відкласти прогін (діапазон
  завантажувача незмінний `0..90`, явний `0` усе ще вимикає
  очікування).
- **ФІЧА (discovery): виявлення BAZA_WWW на основі Apache з явним
  контрактом присутності Present/Absent/Ambiguous/Error.**
  `Test-BRAVOBazaWwwInstallation` валідує резолвнутого кандидата
  `<DocumentRoot>\BAZA` (реальна директорія, не reparse
  point/symlink, непорожня) перед тим, як прийняти його; явний
  override `discoverySettings.Sources.BAZA_WWW` усе ще має пріоритет
  і fail closed (видимий `Error`, без мовчазного fallback) при
  невалідному override, узгоджено з чинною політикою виявлення
  `BravoRoot`.
- **ЛАМКА МІГРАЦІЯ СПОВІЩЕНЬ: legacy provider-wide webhook-и
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

Докази real-server production acceptance: local Git/provenance PASS,
production regression sweep PASS (повний перелік гейтів — в
acceptance handoff). Незакритих блокуючих знахідок немає.

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

Стабільний реліз лінії 5.2.0, промотований (лише метадані) з
прийнятого кандидата 5.2.0-rc.13: rc-мітка `0247ac3` (sourceCommit
`12e6370`), артефакт BRAVO-Toolkit-5.2.0-rc.13.zip sha256
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

- Нова модель обробки Trace (щоденний накопичувальний архів): TraceSRV.out
  і новий опціональний TraceBIS.out (явний
  maintenanceSettings.Trace.BISSourcePath — надійного джерела
  авто-виявлення для BIS не існує) обробляються ВИКЛЮЧНО через
  BRAVO_MAINTENANCE (ручні та заплановані прогони діляться одним
  пайплайном; розмір файлу ніколи не є тригером). Ротація, поки
  служби зупинені, дає плоский
  Trace\<Name>_<yyyyMMdd_HHmmss>.out (колізія бере наступну вільну
  секунду, ніколи не перезаписує; движок послідовності для
  exchangAPI/Apache/BravoWeb побайтово ідентичний через новий
  параметр -NamingPolicy). Після відновлення служб ненумерована
  фаза оновлює рівно ОДИН Trace_YYYYMMDD.mdz на календарну дату (дата
  з ІМЕНІ ротованого файлу, бэклог від найстарішого серед дат):
  спершу інвентаризація (новий Compatibility експортує
  Get-BRAVOSevenZipArchiveEntries / Get-BRAVOSevenZipFileCrc), у 7za
  передаються лише НОВІ файли (наявні записи незмінні й перевіряються
  за Path+Size+CRC перед публікацією), транзакційне оновлення
  .work-partial із 7z t + SHA512-sidecar + атомарна публікація
  (невдале оновлення ніколи не торкається попереднього валідного
  архіву), потім SFTP у новий sftpDirectories.Trace («trace») через
  перевірений <name>.new перед заміною попередньої віддаленої версії;
  ротовані .out видаляються лише після повного ланцюжка
  archive+integrity+SFTP+remote-verify, а невдалий SFTP просто
  відкладається до наступного прогону без дубльованих записів.
  Локальний щоденний .mdz НІКОЛИ не видаляється пайплайном — лише
  новим явним Retention.CompressedLogDeletionEnabled (за замовчуванням
  $false: жоден стиснутий журнал .mdz, включно з legacy
  Trace_YYYY-MM-DD.mdz, не видаляється за віком, поки оператор не
  увімкне опцію; CompressedLogDays застосовується лише з цим
  прапорцем). Заголовки архіву Trace навмисно НЕ -mhe шифруються
  (так само, як backup .mdz): із зашифрованими заголовками 7za
  запитує пароль двічі при додаванні і ненадійно читає другий
  запит із перенаправленого stdin. Dry-run отримує read-only рядки
  PLAN (джерела, буде створено/оновлено, кількість у черзі, буде
  вивантажено, буде видалено), що перевикористовують канонічну
  функцію бэклогу через AST-екстракцію. Legacy директорії/архіви за
  датами лишаються недоторканими й продовжують через наявний ланцюжок
  ArchiveDays. Новий домен селфтесту TraceArchive (18 сценаріїв на
  реальних Tools 7za + фейковій SFTP-сесії) плюс гейти
  ротації/retention/dry-run.
- Фікс (латентний, знайдений при характеризації Trace): паролі
  7-Zip, що передавались через Process.StandardInput.WriteLine, мали
  BOM-префікс на UTF-8 консольних хостах (chcp 65001) — архіви
  створювались «успішно» з пошкодженим ефективним паролем. Новий
  канонічний Write-BRAVOProcessInputText (UTF-8 без BOM через
  BaseStream) тепер використовують усі 7z-обгортки Compatibility та
  Maintenance Invoke-CommandWithLog; гейт
  Secrets/SevenZipPasswordUsesStdin тепер вимагає цей хелпер. Нотатка
  про борг: приватний Get-BRAVOSevenZipArchiveInventory
  BRAVO.DataRestore (лише лічильники) варто перевести на новий
  канонічний Get-BRAVOSevenZipArchiveEntries в циклі декомпозиції
  DataRestore.

Відкриває наступний цикл розробки на developer після стабільного
релізу 5.1.0 (за RELEASE_POLICY.md розділ 11: синхронізація з master
після промоції, потім негайний prerelease-бамп, щоб обидві гілки
ніколи не несли однаковий packageVersion). Запланований фокус (з
зафіксованого боргу циклу 5.1.0): дедуплікація копій політики
service-lifecycle / operation-lock / WinSCP-сесії / ASCII-temp-root
та декомпозиція BRAVO.DataRestore Runtime.ps1.

- Новий операторський інструмент BRAVO_BAZA_RECONCILE.ps1 (guarded
  entrypoint) + експорти BRAVO.BazaSync Get-BRAVOBazaMutationReport /
  Invoke-BRAVOBazaMutationReconciliation: розвʼязання порушень
  append-only мутації однією командою (реальний інцидент 2026-08-21:
  п'ять ЗВТ PDF легітимно перегенеровані в застосунку BRAVO).
  -ListOnly показує стару (state/cloud) versus нову (local) версії з
  датою вивантаження та підказкою верифікації через TraceSRV.out;
  -Accept/-AcceptAll перейменовує стару віддалену версію в
  *.replaced_<date> (лише перейменування, ніколи не видалення) і
  видаляє запис стану під блокуванням синхронізації компонента, щоб
  наступний запланований цикл вивантажив нову версію; невдале
  перейменування зберігає запис стану (fail-closed). MutationPolicy="Fail"
  без змін — автоматична політика перезапису навмисно НЕ надається
  (ransomware мовчки поширився б у хмару). OPERATIONS отримує runbook
  розвʼязання мутацій, включно з уроками ручного fallback (хештаблиця
  Files з ключем RelativePath; I/O стану строго через [IO.File]::
  UTF-8 — сирі Get-Content/Set-Content псують кириличні ключі;
  саме лише видалення ключів перетворює блок на REMOTE_CONFLICT).
- Текст проблеми watchdog для suppressed-маркера стиснуто до однієї
  причини + однієї дії + лога власника («перерване відновлення —
  потрібне РУЧНЕ втручання за кодом 43 (автостарт заборонено); лог:
  <шлях>»); внутрішній жаргон restartSuppressed і потрійне
  повторення лишаються лише в детальному рядку логу Health.
- Компактні операторські алерти (запит оператора з польового тесту
  DEV-LIMS): сповіщення про проблему Health показує повний Reason
  проблеми рівно один раз (у своєму тематичному розділі) — блок
  причини в заголовку тепер містить лише компактний список
  компонентів (до 4 імен) замість дублювання повного тексту першої
  проблеми, а зайвий рядок списку компонентів :package: видалено.
  Проблеми watchdog несуть власний ActionText («виконати ручне
  відновлення служб (OPERATIONS.md, код 43)» / «перевірити причину
  аварійного переривання <owner>» / «запустити служби вручну та
  перевірити ownership-маркер») замість зламаного загального шаблону
  «запустити або перевірити службу Служби після аварії <owner>»;
  прості проблеми служб зберігають старий шаблон.
- Config loader: ефективна конфігурація тепер завжди несе
  maintenanceSettings.Restore.BootRestoreMode — legacy-конфіг сайту
  (5.0/5.1) без нового ключа отримує безпечний default 'None' (24/7).
  Раніше BRAVO_TASKS_INSTALL (і будь-який інший прямий споживач)
  падав під StrictMode з «property 'BootRestoreMode' cannot be found»,
  попри власне попередження завантажувача «застарілий ключ
  ігнорується» (реальний кейс: конфіг сайту DEV-LIMS часів rc.4).
  Регресійний тест
  ConfigurationLoader/MissingBootRestoreModeDefaultsToNone будує
  legacy-подібний fixture і валідує як default завантажувача, так і
  прогін інсталятора.
- Self-test: тимчасові директорії тепер створюються під
  [IO.Path]::GetTempPath() замість сирого $env:TEMP. На серверах, де
  сесійна змінна TEMP несе коротку 8.3-форму профілю
  (C:\Users\E980D~1.KUC\..., реальний кейс: DEV-LIMS / Server 2022),
  Remove-Item -LiteralPath у Windows PowerShell 5.1 падає на
  короткому сегменті з PSArgumentException і зупиняв увесь прогін
  self-test у блоці environment-preflight.
- Посилення quiescence-watchdog (review F4/F5): watchdog запускає
  лише служби з канонічного managed-набору, резолвнутого з
  maintenanceSettings.Services (включно з резолвнутими кандидатами
  BravoWeb) — запис маркера поза цим набором відхиляється з ERROR-
  алертом, а маркер зберігається (fail-safe: недоступна конфігурація
  дає порожній набір і повну відмову), тож підкладений/відредагований
  маркер більше не може змусити SYSTEM-Health запустити довільну
  службу. BRAVO_SETUP тепер посилює ACL кореня машинного стану
  (`Protect-BRAVOMachineStateRoot`, новий експорт BRAVO.System):
  `%ProgramData%\BRAVO\State` отримує вимкнене успадкування з
  FullControl лише для SYSTEM і Administrators; ValidateOnly та
  прогони без підвищення прав звітують про відповідність, нічого не
  змінюючи. Звітування watchdog більше не рахує вже запущену службу
  як «відновлену» — оператор бачить реальний масштаб інциденту.

- CI: розділено імена перевірок для push- і pull_request-подій (jobs
  поза контекстом pull_request отримують суфікс « (push)»). Під час
  промоції stable 5.1.0 один і той самий head SHA ніс зелений PR-
  прогін і задокументований навмисно червоний push-прогін під
  однаковими іменами перевірок, тож branch protection master
  рахував обидва і блокував merge («2 of 5 required status checks are
  failing»), змушуючи до тимчасового обходу enforce_admins. Обов'язкові
  перевірки тепер постачаються виключно прогоном pull_request
  (merge-preview); push-прогони зберігають повне покриття, включно з
  гейтом release-policy для контексту гілки, під суфіксованими
  іменами. Логіка кроків не змінилась.
- Маркер володіння service quiescence + Health watchdog: Maintenance
  та DataRestore тепер пишуть атомарний маркер володіння
  (`%ProgramData%\BRAVO\State\BRAVO_SERVICE_QUIESCENCE.json`, той
  самий патерн, що й стан володіння VSS) ПЕРЕД зупинкою managed-служб
  (невдалий запис маркера скасовує зупинку — fail-closed) і очищає
  його лише після успішного перезапуску всіх служб. Запланований
  прогін BRAVO_HEALTH отримує вузький, задокументований виняток зі
  своєї read-only політики: якщо процес-власник маркера мертвий
  (перевірка живості pid+processStartTime, повторне використання PID
  виключене) і restartSuppressed=false, Health запускає саме ті
  служби, що перелічені в маркері, та надсилає алерт; suppressed-
  маркер або ручна зупинка без маркера ніколи не запускаються
  автоматично. DataRestore завжди пише свій маркер у suppressed-
  режимі (жорстке вбивство процесу посеред відновлення лишає живу
  файлову систему у невизначеному стані, тож watchdog лише піднімає
  CRITICAL-алерт про ручне відновлення й ніколи не автостартує поверх
  нього); Clear/Suppress захищені власником (pid+processStartTime), а
  watchdog перечитує маркер перед дією (TOCTOU-захист), тож
  перекривні власники не можуть видалити маркери один одного; Read
  валідує всі обов'язкові поля маркера і повертає null для частково
  відредагованих маркерів замість падіння всього прогону Health під
  StrictMode. Новий домен self-test
  `selftest/BRAVO_SELF_TEST.ServiceQuiescence.ps1`; нові експорти
  BRAVO.System (Write/Read/Clear/Suppress стану quiescence,
  Test-BRAVOProcessAlive). Див. OPERATIONS.md «Аварійне відновлення
  служб (ownership-маркер)».
- Виправлено дефект подвійного відновлення (реальний інцидент на
  production-сервері BRAVO, 2026-08-20): гілка guard Recovery для
  пропущеної денної роботи з уже запущеними службами (exit 20) без
  умов перезаписувала BRAVO_RESTORE_STATE.json на Pending, деградуючи
  стан Succeeded вже виконаного відновлення — наступний 15-хвилинний
  тік Recovery потім виконував повне відновлення моделі вдруге за той
  самий день. Тригером була гонитва з нічним прогоном BRAVO_ARCHIV
  (його позначка виконання Backup ще не була записана, поки він
  тривав, що давало хибний вердикт про пропущений Backup). Pending
  тепер записується лише коли слот відновлення дійсно ще належний;
  завершений стан відновлення ніколи не деградує. Регресійний тест
  Maintenance/RecoveryGuardNeverDegradesSucceededRestoreState.
- Legacy-рівень ОС (Server 2012 R2/2016) тепер інформаційний в
  операційних прогонах: BRAVO_ARCHIV і BRAVO_MAINTENANCE логують
  повідомлення про рівень підтримки LegacyBestEffort як INFO замість
  WARNING. Раніше кожен успішний прогін на такому сервері завершувався
  кодом 10 (SuccessWithWarnings), а його звіт маршрутизувався в канал
  ALERTS, хоча рівень ОС не впливає на саму операцію. BRAVO_HEALTH
  зберігає WARNING як канонічний власник екологічних метрик (той самий
  принцип уже застосовано до віку оновлень Windows), а рівень
  Unsupported, як і раніше, блокує прогони.
- ROADMAP: задокументовано P3.2a — BRAVO_UPDATE.ps1, ініційоване
  оператором оновлення сервера (поетапне завантаження + SHA-256 +
  гейт config diff + in-place mirror + гейти guard/scheduler/setup +
  журнал оновлень + auto-rollback), заплановано на цей цикл; мовчазне
  авто-оновлення лишається архітектурно забороненим до повного P3.2/P4.
- Редизайн пропущеного відновлення (профілі серверів). Новий ключ
  конфігурації maintenanceSettings.Restore.BootRestoreMode замінює
  RunMissedOnStartup (завантажувач попереджає про застарілий ключ):
  - «None» (default, сервер 24/7): завдання BRAVO_RESTORE_RECOVERY
    більше не реєструється (наявне вимикається інсталятором);
    пропущений слот відновлення підхоплює наступний нічний
    BRAVO_MAINTENANCE (23:55) всередині вікна відновлення — раніше
    його натомість запускав окремий денний тригер Recovery о 21:00.
  - «HoldServices» (робочо-годинний сервер, що вимикається вночі й
    ніколи не бачить вікна відновлення): інсталятор перемикає
    BRAVO/exchangAPI на Automatic (Delayed Start) (нова канонічна
    функція BRAVO.System Set-BRAVOBootRestoreServiceStartType —
    єдине місце в комплекті, що змінює типи запуску служб) і реєструє
    Recovery з одним boot-тригером (затримка 0, без повторень). При
    старті сервера пропущене відновлення виконується ПОЗА вікном,
    поки служби утримуються зупиненими, тож клієнти не можуть увійти
    в застосунок до заміни моделі; fail-open — якщо завдання не
    виконається, відкладений автостарт піднімає служби.
  - Колишнє повторення boot-тригера (15 хв протягом 8 год) видалено:
    на production-сервері BRAVO (2026-08-20) його хвіст продовжував
    будити завдання кожні 15 хвилин ще довго після успішного
    відновлення.
  - Інтеграція quiescence (review після ребейзу): деструктивна фаза
    відновлення моделі (bravocmd) тепер виконується під suppressed-
    маркером володіння — жорстке вбивство посеред відновлення змушує
    Health watchdog підняти CRITICAL-алерт про ручне відновлення
    замість автозапуску служб поверх напіввідновленої моделі (невдача
    suppression скасовує відновлення перед bravocmd, fail-closed;
    маркер повертається в режим автостарту, щойно модель знову
    консистентна). Boot-профіль HoldServices примусово вводить кожну
    увімкнену managed-службу в обсяг stop/marker/restart незалежно
    від гонитви старту з відкладеним автостартом, а знімок служб
    тепер рахує StartPending як запущену в усіх профілях.

## 5.1.0 — 2026-08-20

Стабільний реліз лінії 5.1.0, промотований (лише метадані) з
прийнятого кандидата 5.1.0-rc.4: коміт deploy/stamp `219c55b`
(sourceCommit `d90c3c2`), артефакт BRAVO-Toolkit-5.1.0-rc.4.zip sha256
`a825415c4275b8585c3b8896d655766545edfab2514902889229b80f096ca6b9`,
push CI-прогін 32346213433 SUCCESS (self-test, матриця DataRestore
E2E, PSScriptAnalyzer, parser/BOM/JSON, gitleaks).

Real-server acceptance: повний прогін DEV-LIMS 2026-08-20 (11:18–13:42),
документ-доказ
`docs/BRAVO_DATA_RESTORE_RC4_DEVLIMS_ACCEPTANCE_20260820.md` (гілка
`evidence/219c55b-rc4-devlims-acceptance-pass`, коміт `8efb95e`). Усі
сценарії runbook PASS: Setup/Archive/Health, B4+B17 (реальне
відновлення з SFTP-джерела), B15, B16 (включно з бонусним fail-closed
переривання через брак вільного місця), B19 та B20 (детерміновані
rollback за failpoint, включно з cross-component), B21 (чисте
переривання SFTP exit-50 без жодної живої мутації), B22 (конкуренція
operation-lock). Маршрутизація severity сповіщень підтверджена наживо
в обох напрямках: SUCCESS -> GENERAL, WARNING/CRITICAL -> ALERTS.

Ключові зміни з часів stable 5.0.2:

- BRAVO_DATA_RESTORE: production-entrypoint відновлення даних +
  modules/BRAVO.DataRestore (джерело Local/SFTP, InPlace/OutOfPlace,
  move-aside копії `.prerestore_*`, детермінований cross-component
  rollback, код завершення 43 RestoreFailed, інтеграція operation-lock,
  post-restore Health, self-тести та CI E2E-матриця) — див. розділ
  кандидата rc.2 нижче.
- Маршрутизація severity сповіщень (GENERAL/ALERTS) перенесена в лінію
  5.1.0 (розділ rc.3) і розширена на сповіщення DataRestore (розділ
  rc.4, PR #62).

## 5.1.0-rc.4 — 2026-08-20 (candidate, ACCEPTED 2026-08-20 — released as 5.1.0)

Четвертий кандидат релізу лінії 5.1.0. Відкритий тому, що прогін
acceptance DEV-LIMS для rc.3 виявив, що сповіщення BRAVO_DATA_RESTORE
досі йшли через legacy-єдиний webhook без маршрутизації severity:
звіт про FAILED restore (exit 43) потрапляв у канал GENERAL замість
ALERTS. Не регресія (DataRestore не існує в 5.0.x, а перенесення
PR #39 охоплювало лише Archive/Health/Maintenance), але проєкт вирішив
виправити це зараз, а не документувати як відоме обмеження. Це
функціональна зміна runtime, тож частковий доказ acceptance rc.3
відкидається: **rc.4 вимагає нового повного прогону acceptance
DEV-LIMS** перед будь-якою промоцією в stable.

- Сповіщення DataRestore маршрутизовано через канонічний ланцюжок
  BRAVO.Notifications (PR #62): Resolve-BRAVONotificationRoute
  (рішення send/no-send лишаються на місцях виклику; маршрутизація
  лише обирає канал — рівно два канали: SUCCESS -> GENERAL,
  WARNING/CRITICAL -> ALERTS), Resolve-BRAVONotificationEndpoint
  (канальні цілі Credential Manager з тим самим legacy-webhook
  fallback, що й в інших відправників), чанкування Discord і
  налаштований NotificationRequestTimeoutSeconds. Додано чотири
  регресійні self-тести; Notifications/DiscordMentionsRemainDisabled
  розширено на DataRestore.
## 5.1.0-rc.3 — 2026-08-20 (candidate, NOT accepted)

Третій кандидат релізу лінії 5.1.0. Відкритий тому, що review
ідентичності релізу під час (перерваної) промоції rc.2 у stable
виявив, що кандидату бракує фічі маршрутизації severity сповіщень
(канали GENERAL/ALERTS), наявної в stable 5.0.x: PR #39 історично
потрапив у master напряму, оминувши developer. rc.3 переносить цю
фічу в лінію 5.1.0 через рецензований merge master->developer, разом
із запізнілою синхронізацією метаданих розділів hotfix 5.0.1/5.0.2.
Це функціональна зміна runtime, тож повний PASS acceptance DEV-LIMS,
зафіксований для rc.2 (кандидат 10e9973,
docs/BRAVO_DATA_RESTORE_RC2_DEVLIMS_ACCEPTANCE_20260819_PASS.md),
більше не покриває runtime: **rc.3 вимагає нового прогону acceptance**
перед будь-якою промоцією в stable.

- Перенесено маршрутизацію severity сповіщень (PR #39 + його фікс
  override для 5.0.1, вже наявний у формі developer): маршрутизація
  severity -> канал GENERAL/ALERTS централізована в
  BRAVO.Notifications (Resolve-BRAVONotificationRoute /
  Resolve-BRAVONotificationEndpoint / Send-BRAVONotification),
  канальні цілі Credential Manager (BRAVO_DISCORD_GENERAL_URL /
  BRAVO_DISCORD_ALERTS_URL і пара Slack) з автоматичним fallback на
  legacy-єдиний webhook, ключ конфігурації NotificationRouting,
  відправники Archive/Health/Maintenance перевʼязані через
  канонічний API, компоненти credentials-setup та операторська
  документація.

## 5.1.0-rc.2 — 2026-08-14 (candidate, NOT accepted)

Другий кандидат релізу лінії 5.1.0. На відміну від типового RC, rc.2
несе функціональне доповнення: завершення BRAVO_DATA_RESTORE, яке
проєкт вирішив постачати всередині stable 5.1.0. Через цю
функціональну зміну доказ acceptance 5.1.0-rc.1 більше не покриває
runtime: **rc.2 вимагає нового повного прогону acceptance** (включно з
реальним acceptance відновлення DEV-LIMS) перед будь-якою промоцією в
stable. Цей кандидат ЩЕ НЕ прийнятий. Попередня локальна,
неопублікована промоція stable 5.1.0, зроблена з rc.1 (коміт
`ac07f55`), замінена і не повинна бути запушена, змерджена, тегована
чи релізована; розділ «5.1.0» нижче описує саме ту неопубліковану
промоцію, і stable 5.1.0 буде повторно промотовано з прийнятого rc.2.

- Новий entrypoint `BRAVO_DATA_RESTORE.ps1` (тонка оркестрація над
  новим доменним модулем `modules/BRAVO.DataRestore`): реальне
  відновлення даних компонентів MODEL/BLOG/BRAVOEXCH з перевіреного
  покоління backup у стані COMPLETE — out-of-place за замовчуванням,
  in-place з move-aside і rollback, локальне BackupRoot або джерело
  SFTP, інвентаризаційний режим `-ListGenerations`. Виконує той самий
  ланцюжок guard цілісності runtime перед `Import-Module`, що й інші
  entrypoint-и.
- Вибір покоління та покомпонентна верифікація
  (`Get-BRAVORestoreGenerationManifest`,
  `Get-BRAVOVerifiedGenerationArchive`) перенесені з
  `BRAVO_RESTORE_TEST.ps1` у `modules/BRAVO.ArchiveHelpers` як єдиний
  канонічний селектор/гейт, спільний для drill-відновлення і реального
  відновлення; скрипт drill тепер викликає спільні функції замість
  локальних копій (без зміни поведінки).
- Новий код завершення `43 RestoreFailed` у `modules/BRAVO.ExitCodes`:
  збій самої операції відновлення. Специфічніші причини archive
  зберігають пріоритет (41 IntegrityTestFailed, 42
  HashValidationFailed переважають 43); 43 переважає 50 SftpFailed і
  попередження.
- In-place-відновлення тепер відкочує **весь прогін**, а не лише
  компонент, що впав. Раніше збій на другому чи третьому компоненті
  лишав production у змішаному стані: раніші компоненти вже замінені
  з покоління backup, решта — досі на старих даних — неконсистентний
  набір MODEL/BLOG/BRAVOEXCH. Компоненти, відновлені раніше в тому ж
  прогоні, тепер повертаються у зворотному порядку до стану до
  відновлення й звітуються як `ВІДКОЧЕНО` (`ROLLED_BACK`); невдача
  відкату одного компонента не зупиняє відкат інших і піднімає
  CRITICAL-сповіщення з точною командою ручного відновлення.
  Компонент, чий відкат не завершився, ніколи не лишається у звіті як
  відновлений: він отримує термінальний статус `ПОМИЛКА ВІДКАТУ`
  (`ROLLBACK_FAILED`) із конкретною причиною збою, зберігає свою копію
  `.prerestore_*` у списку для ручного відновлення, а прогін усе одно
  завершується з `43 RestoreFailed`. Жодна копія `.prerestore_*`
  ніколи не видаляється автоматично.
- Self-test розширено, щоб покрити новий entrypoint (guard перед
  import, показ build-id, профіль пріоритету exit-коду, спільне
  володіння селектором відновлення) і, поведінково, саму логіку
  відновлення: захисти шляхів, вибір компонентів, планування цілі
  (відхилення захищеної локації й непорожньої цілі, цілі виявлення
  in-place), preflight вільного місця, пост-екстракційну верифікацію
  та cross-component rollback, включно зі шляхом часткового збою.
- Операторська документація: `OPERATIONS.md` отримує розділ runbook
  для коду завершення `43`, включно з кроками відновлення для
  перерваного посеред виконання restore (вбитий процес, перезавантаження,
  BSOD), коли служби лишаються зупиненими, а жива директорія може бути
  відсутньою; `README.md` документує робочий процес відновлення
  (розділ 6.2) та його інваріанти.

Стабільний production-реліз, промотований з верифікованого кандидата
`5.1.0-rc.1` (прийнятий HEAD `852a0b9`, CI-прогін 31755546128 SUCCESS,
вердикт real-server acceptance PROMOTE). Кандидат пройшов повний
Windows CI-конвеєр і real-server acceptance на Windows PowerShell 5.1,
включно з real-SFTP acceptance BAZA за всіма 10 сценаріями (DEV-LIMS,
2026-08-13 — див. `docs/BAZA_SFTP_ACCEPTANCE.md` розділ 13). Ця
промоція не містить жодних функціональних змін runtime відносно
прийнятого кандидата: вона прибирає prerelease-суфікс, встановлює
канал stable-релізу, оновлює заголовки операторської документації й
регенерує маніфест цілісності runtime. Жодна схема конфігурації, схема
стану, ціль credential, формат archive, default retention, протокол
передачі чи контракт підтримуваної ОС не змінились під час промоції.

## 5.1.0-dev.1 — 2026-08-12

Відкриває наступний цикл розробки поверх стабільної бази 5.0.0
(`master` змерджено в `developer`). Мінорна версія: цей цикл уже несе
нову функціональність (Retention Safety Invariants), а не лише фікси.
Схема конфігурації, схема стану, ціль облікових даних, формат архіву,
протокол передачі та контракт підтримуваних ОС не змінились. Типова
мінімальна кількість збережених верифікованих генерацій дійсно
змінилася (1 -> 2, див. Retention Safety Invariants нижче).

- Автоматичне відновлення (restore recovery) тепер гарантує щоденну
  повторну спробу всередині налаштованого вікна
  `Restore.WindowStart`/`WindowEnd` незалежно від `Maintenance.DailyAt`
  чи перезавантажень сервера. Запланована задача `Recovery` отримує
  другий, щоденний тригер на `Restore.WindowStart` у тому самому
  визначенні задачі (та сама дія `-RunMissedRestoreOnly`, що й у
  наявного тригера на завантаження) — раніше існувала лише повторна
  спроба, запущена завантаженням (15 хв протягом 8 годин), тож сервер,
  що залишався увімкненим з `Maintenance.DailyAt` поза вікном
  відновлення, міг нескінченно пропускати пропущене відновлення.
  Повідомлення в логах про Maintenance.DailyAt поза вікном більше не
  стверджує, що щоденний шлях втрачено, і знижене з `WARNING` до
  `INFO`. Сама задача `Recovery` тепер завжди реєструється
  (`Scheduler.Recovery.Enabled` більше не прив'язана до
  `Restore.RunMissedOnStartup`): щоденний тригер безумовний, а
  `Restore.RunMissedOnStartup` тепер лише керує тим, чи створюється
  додатковий тригер на завантаження — раніше встановлення `false`
  вимикало щоденну страхувальну мережу разом з повторною спробою на
  завантаження.
- Автоматичне відновлення тепер повторно валідує
  `Restore.WindowStart`/`WindowEnd` безпосередньо перед деструктивним
  викликом `bravocmd.exe`, а не лише один раз на початку запуску.
  `$shouldRestore` обчислювався до `Enter-BRAVOMaintenanceOperationLock`
  (до `OperationLockWaitMinutes`, типово 360 хв), зупинки служби та
  архіву перед відновленням — вікно могло закритися під час цього
  очікування, і стара перевірка ніколи не була фінальною
  авторизацією. Два бар'єри (перед входом у послідовність відновлення
  та безпосередньо перед `bravocmd.exe`) викликають ту саму перевірку
  `Test-BRAVORestoreExecutionStillAllowed`; вікно, що закривається між
  ними, тепер відкладає відновлення (чіткий `WARNING`, без виклику
  `bravocmd.exe`, без запису маркера успіху/стану, запланований слот
  залишається придатним для повторної спроби) замість того, щоб
  виконатись поза вікном. `-ForceRestore` не зазнає впливу жодного з
  бар'єрів.
- `Remove-BRAVOOrphanedTemporaryArchiveArtifacts` (очищення осиротілих
  `.work\*.partial*`, введене у 5.0.0) більше не використовує
  `Test-Path` для перевірки існування `.work`. `Test-Path` не може бути
  fail-visible для чистої локальної відмови ACL access-denied на
  наявному каталозі — `.NET Directory.Exists` (яку використовує
  файловий провайдер) навмисно поглинає `UnauthorizedAccessException` і
  повертає `$false`, що невідрізниме від "не існує". Перевірку
  існування тепер згорнуто в той самий виклик `Get-ChildItem`, що вже
  перелічує файли `.partial*`, класифікований за типом винятку:
  `ItemNotFoundException`/`DirectoryNotFoundException` — це безпечний
  пропуск, усе інше (`UnauthorizedAccessException`, `IOException`,
  помилки провайдера/мережі) позначає операцію як невдалу та логує
  `ERROR`.
- Щоденний тригер `Recovery` тепер має `StartWhenAvailable=true` (усі
  інші типи задач зберігають глобальне типове значення `false`): якщо
  тригер пропущено через те, що сервер спав/був офлайн, Task Scheduler
  надолужує його щойно сервер стає доступним, замість очікування
  наступного запланованого моменту. Це безпечно лише завдяки двом
  TOCTOU-бар'єрам вище — пізнє надолуження, що потрапляє поза вікно,
  тепер коректно нічого не робить.
- Retention Safety Invariants: збереження генерацій з урахуванням
  генерацій (generation-aware backup retention) тепер також вимітає
  осиротілі тимчасові артефакти архіву `.work\*.partial*`, залишені
  вбитим процесом, підвищує типову мінімальну кількість збережених
  верифікованих генерацій з 1 до 2 та видає один рядок аудиту retention
  на запуск (кількість оцінених/захищених/видалених).
- Стан виконання служби Windows (`Running`/`Stopped`/`Disabled`/не
  встановлена) більше не може блокувати backup — лише операції, що
  дійсно потребують зупиненої служби (деструктивне відновлення, інші
  деструктивні операції MODEL, ротація відкритого лога застосунку),
  можуть залежати від нього; це тепер задокументований архітектурний
  контракт (`OPERATIONS.md`, "Стан служб не визначає політику backup").
  `Find-BRAVOServiceByCandidates` (використовується виявленням шляху
  інсталяції для `BRAVO_ROOT`, `WEB_ROOT`/`BAZA_WWW`) раніше виключав
  будь-яку службу зі `StartMode=Disabled`, змішуючи "адміністративно
  вимкнено" з "не встановлено": служба BRAVO Web/Apache у стані
  `Disabled` робила backup `BAZA_WWW` (і SFTP, і локальну
  синхронізацію) мовчки нерозв'язним, навіть якщо її каталог
  `DocumentRoot` лишався повністю читабельним на диску — блокування за
  станом служби без жодної реальної помилки файлової системи.
  Виключення `Disabled` видалено; стан служби більше не впливає на
  ідентичність шляху (той самий принцип, який `Resolve-BRAVOEffectiveLimsRoot`
  уже документував для `LIMSRoot`), а збіг у стані `Disabled` тепер
  додає лише діагностичну примітку `[УВАГА: служба має тип запуску
  Disabled]` до причин `BRAVO_ROOT`/`WEB_ROOT` замість провалу
  виявлення. Коли служба BRAVO Web/Apache справді відсутня (не просто
  вимкнена) і не налаштовано перевизначення
  `discoverySettings.Sources.BAZA_WWW`/`.WebRoot`, причина невдачі
  виявлення `BAZA_WWW` тепер явно повідомляє, що службу не вдалося
  знайти (раніше — висяче, незрозуміле "BAZA_WWW не визначено: ") —
  контрольована відмова "джерело невідоме", ніколи не сформульована як
  відмова через політику стану служби. Звичайна генерація backup
  (MODEL/BLOG/BRAVOEXCH, джерело лише `bravo.ini`), backup MODEL до/після
  відновлення та `ArchiveAfterMaintenance` вже й раніше не залежали від
  стану служби; перевірено й підтверджено новим регресійним покриттям.
- Закрито другий, глибший випадок того самого інваріанта: `BRAVO.config`
  викликав `Resolve-BRAVOEffectiveLimsRoot` для `pathSettings.LIMSRoot`
  (типово `""` = AUTO від служби BRAVO) і одразу робив `throw`, коли
  служба була відсутня — ще до того, як `Resolve-BRAVOInstallationDiscovery`
  (MODEL/BLOG/BRAVOEXCH) взагалі запускався. Тест на рівні
  production-завантажувача (що керує реальним `Import-BravoConfiguration`
  + `BRAVO.config`, а не безпосередньо helper-ом Discovery) це
  підтвердив: за відсутньої служби BRAVO, цілком валідного канонічного
  `bravo.ini` та явного `BackupRoot` завантаження конфігурації все одно
  провалювалося лише через перевірку LIMSRoot. Розв'язання
  `LIMSRoot`/`SystemLogRoot` більше не кидає виняток усередині самого
  `BRAVO.config`; тепер кожен споживач сам вирішує свою критичність.
  `BRAVO_ARCHIV` не *вимагає* `LIMSRoot`/`SystemLogRoot` (MODEL/BLOG/
  BRAVOEXCH походять лише з `bravo.ini`, `BackupRoot` має власне
  незалежне явне-або-AUTO розв'язання з власним `Error`/throw) —
  `$rootPath` технічно все ще читається для інформаційного рядка лога та
  як резервний варіант sanity-перевірки free-space-preflight, але ніколи
  не блокує результат backup. `BRAVO_HEALTH` взагалі не читає жодне з
  цих значень — вона вже вимагає лише `BackupRoot`. `BRAVO_MAINTENANCE`
  не зазнає впливу: у неї вже була власна явна, незалежна перевірка
  (`effectiveLimsRoot`/`systemLogRoot`/`backupRootPath` непорожні, інакше
  `exit 30`) одразу після завантаження конфігурації, тож fail-closed
  поведінка Maintenance, коли їй дійсно потрібен корінь інсталяції,
  незмінна — тепер захищена регресійним тестом
  (`ProductionConfig/MaintenanceOwnLimsRootGuardStillBlocks`), щоб її не
  можна було мовчки послабити пізніше. Два пов'язані приховані баги,
  обидва виявлені лише тестуванням реального шляху завантаження
  конфігурації (а не helper-а Discovery ізольовано): невикористовуваний
  параметр `-LimsRoot` у `Resolve-BRAVOInstallationDiscovery` був
  `Mandatory`, тож передача тепер легітимно порожнього `$rootPath` кидала
  помилку прив'язки параметра замість продовження роботи — виправлено
  прибиранням `Mandatory` з параметра, який тіло функції взагалі не
  читає; і free-space-preflight Archive передавав той самий потенційно
  порожній `$rootPath` як `-RootPath` у `Get-BRAVOArchiveFreeSpaceResult`,
  чий власний sanity-виклик `Test-Path` кидає виняток на порожньому
  рядку — виправлено переходом на `$runtimeRoot` (завжди валідний), коли
  `$rootPath` порожній; сама перевірка free-space уже оцінює кожен
  фіксований диск незалежно від `-RootPath`, тож поведінка free-space не
  змінюється.
- Регресійне покриття: реальні тести `Schedule.Service` через COM
  доводять, що задача `Recovery` реєструє тригери на завантаження+
  щоденний, коли `RunMissedOnStartup=true`, лише щоденний (задача
  все одно зареєстрована, не вимкнена), коли `false`, і
  `StartWhenAvailable=true` лише для `Recovery`; поведінковий тест з
  ін'єктованим постачальником часу доводить, що TOCTOU-переперевірка
  блокує автоматичне відновлення після закриття вікна, при цьому
  дозволяючи `-ForceRestore`; структурні тести доводять, що обидва
  бар'єри розташовані саме там, де мають бути, перед деструктивним
  викликом; чотири поведінкові випадки очищення осиротілих файлів
  покривають відсутній `.work` (безпечний випадок), access-denied та
  окремий тип помилки вводу-виводу, плюс структурний тест, що доводить,
  що `Test-Path` більше взагалі не викликається; композитний тест
  доводить, що пошкоджена найновіша генерація backup не може витіснити
  старішу верифіковано-валідну генерацію з набору, захищеного retention.
  Незалежність від стану служби має два рівні покриття, названі
  відповідно до того, що вони реально доводять: `Discovery/BackupSourcesResolveWhenBravo*`
  та `Discovery/BazaWWWResolvesWhenApache*` — це поведінкові тести
  самого `Resolve-BRAVOInstallationDiscovery` (усі три стани служб
  BRAVO/BravoWeb однаково розв'язують `BRAVO_ROOT`/`MODEL`/`BLOG`/
  `BRAVOEXCH`/`BAZA_APP`/`BAZA_WWW`, `BAZA_WWW` — з того самого
  `httpd.conf` у кожному випадку) — попередній раунд цих тестів мав
  назву `Backup/WorksWhenBravoService*`, що вводило в оману, натякаючи
  на покриття виконання там, де насправді було лише покриття
  виявлення; перейменовано. Ще два тести на рівні Discovery окремо
  покривають випадок дійсно відсутньої служби на відміну від
  "вимкненої" (явне перевизначення все одно розв'язує `BAZA_WWW`; без
  перевизначення — контрольована відмова "джерело не знайдено", а не
  повідомлення про відмову за станом служби), і один доводить, що
  `MODEL`/`BLOG`/`BRAVOEXCH` все одно розв'язуються з `bravo.ini`, коли
  служба BRAVO повністю відсутня. Окрім виявлення, три справді
  поведінкові тести (`Backup/ArchiveInvokedWhenBravoService*`) керують
  реальним потоком керування Invoke-BRAVOComponentBackup — його власна
  атомарна оркестрація create/hash/verify/publish виконується без
  заглушок; заглушені лише примітиви архіву/хешу (`New-Archive`,
  `New-SHA512Hash`, `Get-BRAVOFileHash`, `Write-BRAVOFinalHashFile`) —
  від виявленого джерела до опублікованого архіву на диску, по одному
  разу на кожен стан служби BRAVO, підтверджуючи, що архіватор дійсно
  викликається (це доводить лічильник викликів) і що архів дійсно
  існує незалежно від стану служби. Третій рівень (`ProductionConfig/*`)
  іде ще на крок глибше: дев'ять тестів керують реальним
  `Import-BravoConfiguration` над реальним текстом `BRAVO.config`
  (цільова, перевірена regex-підстановка лише конкретних значень
  конфігурації — та сама техніка, яку `Version/AuthoritativeLoader` уже
  застосовував для `LIMSRoot`), з `Get-CimInstance`/`Get-WmiObject`,
  затіненими на глобальному рівні для детермінованого керування
  наявністю служби (єдина надійна точка перехоплення через межу
  модуля — власні функції BRAVO так затінити не можна, кожен модуль
  зберігає власний стан сесії, але сторонні cmdlet-и розв'язуються
  через ланцюжок областей видимості викликача). Ці тести доводять
  наскрізно: BRAVO відсутній + канонічний `bravo.ini` + явний
  `BackupRoot` досягає готового `archiveDefinitions[MODEL].Source`;
  BRAVO відсутній + явні перевизначення джерела працюють взагалі без
  `bravo.ini`; BRAVO відсутній + жодного джерела будь-якого типу —
  fail-closed з причиною "джерело невідоме", ніколи не за станом
  служби; ті самі два контрастні результати для `BAZA_WWW` за
  відсутнього Apache; і Running/Stopped/Disabled лишаються незмінними
  через увесь завантажувач, а не лише через helper Discovery.
  Структурні тести (чітко позначені як такі, не поведінкові) окремо
  доводять, що виклики архіву до/після відновлення та рішення про
  запуск `ArchiveAfterMaintenance` не містять повторної перевірки
  статусу служби; справжній поведінковий тест виклику для останнього
  визнано непрактичним без реструктуризації монолітного верхньорівневого
  потоку `BRAVO_MAINTENANCE.ps1` у викличну функцію суто заради
  тестованості.
- Закрито три пост-фіксні регресії, виявлені під час ревʼю фіксу LIMSRoot
  вище. `BRAVO_DRY_RUN.ps1` безумовно повідомляв `PASS` для
  `LIMSRoot`/`SystemLogRoot` навіть коли значення не було розв'язано
  (`Source -eq 'Error'`), що приховало б справжню проблему готовності
  `BRAVO_MAINTENANCE`/`BRAVO_RESTORE_RECOVERY` за зеленим результатом.
  Нова `Get-BRAVODryRunRootReadinessResults` (чиста, покрита
  unit-тестами) тепер повідомляє: нерозв'язаний `BackupRoot` завжди
  `FAIL` (обов'язковий для `BRAVO_ARCHIV`/`BRAVO_ARCHIV_HEALTH`);
  нерозв'язаний `LIMSRoot`/`SystemLogRoot` — це `WARN`, коли
  `Maintenance`/`Recovery` обидва вимкнені в `schedulerSettings`
  (контекст лише Archive — backup лишається дозволеним), і `FAIL`, коли
  хоча б один увімкнений (вони дійсно потребують кореня, а власний
  загальний вердикт готовності `BRAVO_DRY_RUN.ps1` уже перетворюється на
  "НЕ ГОТОВО" за будь-якого `FAIL`, тож самого цього достатньо, щоб
  явно позначити Maintenance/Recovery як не готові, не торкаючись
  `BRAVO_TASKS_INSTALL.ps1`, чия робота — реєстрація задач, а не
  готовність рантайму).
  По-друге, `[System.IO.Path]::Combine($SystemLogRoot, 'Trace')` (і
  еквівалент для необов'язкових каталогів логів exchangAPI/BravoWeb)
  мовчки повертав *відносний* шлях, коли `$SystemLogRoot` порожній,
  замість того, щоб кинути виняток або повернути порожнє значення —
  подальша write-проба створила б випадковий `.\Trace` у поточному
  каталозі процесу. `Get-BRAVODryRunOptionalComponentPlan` і ціль
  `SystemLog\Trace` тепер обидва захищені перевіркою непорожнього
  `SystemLogRoot`. По-третє, `Test-BRAVOFileSystemWriteAccess` створював
  відсутні цільові каталоги в рамках своєї проби готовності, але ніколи
  їх не видаляв, що суперечило власному задокументованому контракту Dry
  Run "не створює каталоги"; тепер він видаляє створений ним каталог,
  якщо той лишається порожнім після видалення пробного файлу (каталог з
  чужим вмістом, залишеним чимось іншим, ніколи не чіпається). Також
  перейменовано коментар `Get-BRAVODryRunConfiguredServiceState`, який
  усе ще стверджував, що Discovery "навмисно" виключає служби `Disabled`
  — після фіксу вище це вже неправда. Регресійне покриття: `DryRun/
  UnresolvedBackupRootIsAlwaysFail`, `DryRun/
  UnresolvedLimsRootIsWarnWhenMaintenanceRecoveryDisabled`, `DryRun/
  UnresolvedLimsRootIsFailWhenMaintenanceEnabled`, `DryRun/
  UnresolvedLimsRootIsFailWhenRecoveryEnabled`, `DryRun/
  ResolvedRootsAreAlwaysPass` (усі поведінкові, проти виокремленої
  чистої функції); `DryRun/EmptySystemLogRootProducesNoRelativeWriteTargets`
  (поведінковий, доводить, що відносна ціль запису ніколи не
  утворюється) та `Runtime/08-WriteProbeCleansUpEmptyCreatedDirectory`
  (поведінковий, доводить, що проба видаляє створений нею каталог, коли
  підтверджено, що він порожній). Ще два закривають решту прогалин
  покриття, виявлених у тому самому раунді ревʼю:
  `ProductionConfig/BravoAbsentCanonicalAutoDiscoveredIniWorks` керує
  реальним production-завантажувачем з `$env:SystemRoot`, спрямованим
  на fixture-файл `SysWOW64\bravo.ini`, і *без* перевизначення
  `discoverySettings.BravoIniPath`, доводячи, що звичайне канонічне
  автовиявлення працює, а не лише шлях з явним перевизначенням, який
  використовували всі інші тести `ProductionConfig/*` (покриття
  x86/`System32` вимагало б, щоб `BRAVO.config` явно передавав
  `-Is64BitOperatingSystem`, чого він не робить — поза межами без зміни
  production-коду); і `Backup/ArchiveInvokedWhenBravoServiceAbsent`
  розширює поведінковий ланцюжок `Backup/
  ArchiveInvokedWhenBravoService{Running,Stopped,Disabled}`
  (production-завантажувач -> `archiveDefinitions[MODEL].Source` ->
  `Invoke-BRAVOComponentBackup` -> опублікований архів) на випадок
  дійсно відсутньої служби, який перейменований
  `ProductionConfig/BravoAbsentIniSourcesPrepareArchiveDefinition`
  доводив лише до готовності `archiveDefinitions`, а не саме виконання
  backup.
- Синхронізацію/верифікацію BAZA_APP/BAZA_WWW перебудовано навколо
  інкрементного, append-only-обізнаного движка (новий модуль
  `BRAVO.BazaSync`), що замінює порівняння повного дерева
  `synchronize`/`synchronize -preview` на кожному циклі для цього
  конкретного навантаження (>50 ГБ, сотні тисяч файлів, файли ніколи не
  змінюються після надходження, віддалений `-delete` ніколи не
  використовується). Стара вартість вимірювалась *кількістю* операцій
  listing/stat/compare, а не переданими байтами, і саме вона була
  джерелом хибнопозитивних алертів Health для легітимно нових файлів,
  що з'явилися між sync і health-check. Основний інваріант:
  `SYNC -> VERIFY -> HEALTH RESULT`, а не "Health знаходить нові локальні
  файли -> алерт". Кожен цикл синхронізації (`CycleId`) один раз робить
  знімок локального каталогу (`Cutoff`); файли, присутні в цьому знімку,
  належать циклу, файли, що з'явилися після — `NewAfterCutoff`, завжди
  `INFO`, ніколи не алерт Health, незалежно від того, скільки часу минуло
  з завершення циклу. Збережений посегментно (per-component) індекс
  (`%ProgramData%\BRAVO\State\BAZA\<Component>.state.json`, налаштовується
  через `BAZA.StateRoot`; явно *не* Durable Operation Journal, який
  залишається нереалізованим) записує RelativePath/Size/LastWriteTimeUtc/
  UploadedUtc/Verified для кожного вже підтверджено переданого файлу;
  файл з `Verified=true` і незмінним локальним розміром не потребує
  жодних віддалених викликів на наступних циклах (`AlreadyVerified`) —
  `LastWriteTime` завжди лише підказка для оптимізації, ніколи не єдина
  ознака коректності, тож новий файл зі старою міткою часу все одно
  буде виявлений. Записи стану атомарні (тимчасовий файл +
  `[IO.File]::Replace`, за тим самим шаблоном, що й наявний
  `Save-BRAVOVSSOwnershipState`); аварійне завершення посеред завантаження
  залишає файл у стані `Verified=false`, і він повторюється, ніколи не
  позначається успішним мовчки. Зміна розміру вже `Verified`-файлу — це
  порушення append-only-інваріанта (мутація): `BAZA.MutationPolicy =
  "Fail"` (типово) блокує мовчазне повторне завантаження і замість цього
  повідомляє `Status=MUTATION_VIOLATION` з попереднім/поточним розміром
  та міткою часу. Відсутність/пошкодження/невідповідність схеми стану
  ніколи не призводить до мовчазної довіри до старих файлів
  (`Status=STATE_INVALID`) — потрібна повна реконсиляція. Перший запуск
  узгоджує наявне SFTP-дерево через один дорогий Full Audit (повторно
  використовуючи наявний механізм `Get-BAZASFTPComparison`/WinSCP
  `CompareDirectories` через чистий адаптер,
  `ConvertTo-BRAVOBazaFullAuditResult`, замість дублювання), який
  заповнює вже відповідні файли як верифіковані без повторного
  завантаження; Full Audit також періодично перезапускається
  (`BAZA.FullAuditEveryDays`, типово 7, або `-ForceFullAudit`), щоб
  вловити дрейф, який чисто інкрементний план сам по собі не бачить
  (наприклад, раніше верифікований файл, вручну видалений на віддаленій
  стороні, виявляється і повторно ставиться в чергу на завантаження) —
  ніколи не на кожному циклі. Bootstrap/Full Audit — виключна
  відповідальність `BRAVO_ARCHIV` (він завжди запускається першим за
  розкладом); окремий запуск `BRAVO_HEALTH.ps1` без наявного стану
  зупиняється до будь-якого планування/завантаження з контрольованим
  `Status=STATE_NOT_INITIALIZED` і нульовою кількістю викликів передачі
  замість мовчазного повторного завантаження всього (посилено записом
  про глибоке ревʼю нижче). `BRAVO_HEALTH` тепер синхронізує BAZA перед
  оцінкою (`BAZA.SynchronizeBeforeHealth`, типово `true`): якщо
  `BRAVO_ARCHIV` уже отримав `SyncResult` у тому самому запуску, він
  повторно використовується як є (без другої синхронізації —
  `Invoke-BRAVOBazaComponentSyncSession` — це та сама спільна точка
  входу сесії/синхронізації/чекпойнта, яку використовують обидва
  викликачі); окремий запуск Health без свіжого результату сам виконує
  рівно одну синхронізацію перед оцінкою, ніколи не алерт на основі
  застарілого порівняння. Fast Health
  (`Get-BRAVOBazaFastHealthResult`) оцінює лише вже обчислений
  `SyncResult` — без нового віддаленого порівняння — і відрізняє
  звичайні нові дані (`NewAfterCutoff`, лише інформаційно) від
  справді невдалої/незавершеної синхронізації (`Failed`/
  `PendingWithinCutoff` > 0, алерт з деталями циклу/виявлено/
  завантажено/невдало) та незавершеної синхронізації
  (`ERROR`/`STATE_INVALID`, алерт, що повідомляє про незавершену
  синхронізацію, ніколи "не вистачає N файлів"). Невеликий віддалений
  чекпойнт (`/baza_app/.bravo-sync.json`, лише метадані — без облікових
  даних) публікується лише як останній крок успішної синхронізації;
  невдалий/частковий цикл ніколи його не публікує. Конкурентність:
  файлове блокування на компонент (`<StateRoot>\BAZA\<Component>.sync.lock`,
  fail-fast, без циклу повторних спроб) — другий, безумовний бар'єр
  навколо секції читання-модифікації-запису стану, незалежний від
  наявної координації `SkipIfBackupTaskRunning`/`BRAVO_OPERATION.lock`,
  яка вже утримує звичайний запланований окремий запуск Health від
  перетину з `BRAVO_ARCHIV`; справжній конфлікт блокування повертає
  `Status=SKIPPED_CONCURRENT` (Health зважує його щодо свіжості
  останнього успішного циклу — див. запис про глибоке ревʼю нижче),
  тоді як збої інфраструктури блокування (ACL/шлях/введення-виведення) —
  це справжній `ERROR`, ніколи не замаскований під конкурентність. Новий
  блок конфігурації `backupMonitoring.SFTP.BAZA` (`Mode` — типово
  `"IncrementalAppendOnly"`, будь-яке інше значення повністю зберігає
  попередні незмінні шляхи коду `Sync-FolderToSFTP`/
  `Invoke-WinSCPBAZAComparison`; `SynchronizeBeforeHealth`;
  `FastHealthEnabled`; `FullAuditEnabled`; `FullAuditEveryDays`;
  `MutationPolicy`; `StateRoot`) інтерпретується рівно в одному місці
  (`Get-BRAVOBazaSettingsEffective`, `Get-BRAVOBazaSyncModeEffective`,
  `Test-BRAVOBazaIncrementalModeEnabled`, усі в уже спільному модулі
  `BRAVO.ArchiveRuntime`), яке викликають `BRAVO_ARCHIV`, `BRAVO_HEALTH`
  та `BRAVO_DRY_RUN` — закриваючи реальну невідповідність, виявлену під
  час цієї роботи, коли `BRAVO_ARCHIV` уже поважав перевизначення
  `BAZA.StateRoot`, а окрема резервна синхронізація `BRAVO_HEALTH` —
  ні, що змусило б їх писати/читати два різні файли стану для того
  самого компонента, якби це налаштування колись змінили з типового.
  `BRAVO_DRY_RUN.ps1` повідомляє режим BAZA, шлях стану, читабельність
  стану, останній успішний цикл, останній Full Audit та наступний
  запланований Full Audit виключно читанням збереженого стану — він
  ніколи не відкриває SFTP-сесію і не виконує синхронізацію. Це не
  початок Durable Operation Journal — збережений тут стан є вузьким
  індексом, обмеженим лише оптимізацією/надійністю синхронізації BAZA.
- Посилення `BRAVO.BazaSync` для усунення виробничих прогалин після
  незалежного глибокого ревʼю, що закрило кожну знахідку перед
  виведенням у production. (P1) Відсутній стан без авторизації
  bootstrap тепер зупиняється *до* планувальника з
  `Status=STATE_NOT_INITIALIZED` і гарантованим нулем викликів
  завантаження — раніше окремий запуск Health на свіжій інсталяції
  провалювався в план, де кожен локальний файл виглядав новим і міг
  спробувати завантажити повне дерево 50+ ГБ. (P1) Fast Health
  перейшов з чорного списку статусів на білий список успіху: лише
  `Status=COMPLETE` може досягти звичайної здорової оцінки;
  `INCOMPLETE` (наприклад, збій збереження стану *після* того, як усі
  завантаження вже успішні, що раніше провалювалось у "хмарна копія
  актуальна", бо `Failed=0`), `ERROR`, `STATE_INVALID`,
  `STATE_NOT_INITIALIZED`, `MUTATION_VIOLATION` і будь-який
  невідомий/майбутній статус тепер fail visible, ніколи не "відкрито".
  (P1) `Enter-BRAVOBazaSyncLock` тепер класифікує збої: лише справжнє
  порушення спільного доступу (Win32 `ERROR_SHARING_VIOLATION`) — це
  `Busy` → `SKIPPED_CONCURRENT`; access-denied/ACL, збої створення
  каталогу стану, невалідні шляхи та загальні помилки вводу-виводу — це
  `Error` → `Status=ERROR` і проблема Health — раніше кожен виняток
  блокування маскувався як "інший процес синхронізується". (P1)
  Пошкоджений/непідтримуваний за схемою стан тепер дійсно відновлюваний,
  але лише на шляху Archive (`-BootstrapIfNeeded` + `FullAuditProvider`):
  спочатку виконується Full Audit, і лише в разі успіху пошкоджений файл
  поміщається в карантин поруч з канонічним шляхом
  (`<Component>.state.corrupt.<timestamp>.json`), а свіжий стан
  будується виключно з результату аудиту (уже відповідні віддалені
  файли позначаються верифікованими, завантажуються лише файли,
  відсутні на віддаленій стороні); невдалий аудит залишає докази
  пошкодження недоторканими, не довіряє жодним файлам, нічого не
  завантажує і чесно повертає `STATE_INVALID`. Окремий Health зберігає
  попередню безпечну поведінку (`STATE_INVALID`, нуль завантажень,
  алерт, файл недоторканий). (P2) Контракт конфігурації тепер
  примусовий, а не мовчки ігнорується: `BAZA.SynchronizeBeforeHealth =
  $false` або `BAZA.FastHealthEnabled = $false` у поєднанні з `Mode =
  "IncrementalAppendOnly"` відхиляється під час валідації конфігурації
  з практичною помилкою, що вказує на `Mode = "Legacy"` як явний шлях
  до старої поведінки (`BRAVO_DRY_RUN` повідомляє про це як обмежений
  FAIL для секції BAZA, не перериваючи непов'язані перевірки). (P2)
  Віддалений чекпойнт тепер публікується через тимчасове віддалене
  імʼя (завантаження в `.bravo-sync.json.tmp-<guid>`, потім явна
  заміна — див. запис раунду 2 нижче), і його результат більше не
  відкидається: `CheckpointAttempted`/`CheckpointPublished`/
  `CheckpointError` тепер живуть у SyncResult, а збій публікації на
  інакше успішному циклі — це `WARNING` (телеметрія лише на запис для
  оператора — production Health ніколи не читає віддалений чекпойнт
  назад, і документація більше не стверджує, що читає). (P2) Невдалий
  періодичний Full Audit більше не зникає безслідно:
  `FullAuditAttempted`/`FullAuditSucceeded`/`FullAuditError`/
  `LastFullAuditUtc` тепер видно в SyncResult, і синхронізація-успішна-
  але-аудит-невдалий — це щонайменше `WARNING`, ніколи не мовчазне
  "повністю верифіковано". (P2) Застаріла перевірка сумісності імен
  файлів SFTP (ліміти в *байтах* UTF-8 на сегмент шляху — з раунду 2:
  246 для імен файлів, 255 для каталогів) тепер застосовується до
  кандидатів на інкрементне завантаження (O(кандидатів), суто локально,
  без сканування віддаленого дерева, нуль віддалених викликів для
  несумісного файлу): файл пропускається з явним записом
  `IncompatibleFiles`, що називає точний відносний шлях і причину, а
  Health піднімає `CRITICAL` — закриваючи раніше задокументовану
  залишкову прогалину. Посилення `SKIPPED_CONCURRENT`: "інший процес
  активний" більше не є доказом актуальності хмарної копії — Health
  зважує це щодо збереженого `LastSuccessfulSyncUtc` (свіжий протягом
  24 год → `INFO`/відкладено; застарілий або ніколи не успішний →
  `WARNING`), і звичайне повідомлення "хмарна копія актуальна" для
  такого випадку ніколи не формується. ~48 нових поведінкових
  самотестів покривають усе вищезазначене через реальний шлях
  планувальника/синхронізації (без потреби у WinSCP-сесії), включно зі
  структурними гарантіями відсутності видалення (без
  `SynchronizeDirectories`, `RemoveFiles` торкається лише власних
  артефактів чекпойнта движка, кожен `PutFiles` передає `remove=$false`).
- Посилення `BRAVO.BazaSync`, раунд 2 (фінальні знахідки ревʼю перед
  виведенням у production). (P1) Несумісні імена SFTP більше не дають
  успішного циклу: раніше пропущений несумісний кандидат залишав
  `Failed=0`, цикл ставав `COMPLETE`, `LastSuccessfulSyncUtc`
  просувався, і "успішний" віддалений чекпойнт міг бути опублікований,
  хоча дані свідомо не були передані. Такий цикл тепер завершується
  явним `Status=INCOMPATIBLE_NAME`: провенанс успішного циклу
  (`LastCycleId`/`LastSuccessfulSyncUtc`) не просувається, чекпойнт не
  публікується (і бар'єр на рівні сесії, і сама
  `Write-BRAVOBazaRemoteCheckpoint` відмовляють результатам, відмінним
  від `COMPLETE`), Health лишається `CRITICAL` з точними шляхами
  порушників, а сумісні кандидати того самого циклу все одно
  завантажуються і фіксуються в стані нормально (`BRAVO_ARCHIV` уже
  трактує будь-який статус, відмінний від `COMPLETE`, як
  несинхронізований компонент). (P1) Відновлено справжню legacy-семантику
  ResumeSupport: цільове завантаження тепер явно встановлює
  `TransferOptions.ResumeSupport.State = On` (замість покладання на
  типовий поріг розміру WinSCP), а ліміт валідатора імені файлу —
  246 байтів UTF-8 (255 − 9 байтів для суфікса `.filepart`, який WinSCP
  додає під час відновлюваних передач; для каталогів лишається 255) —
  саме та пара, яку legacy-шлях завжди використовував з
  `-resumesupport=on`. Раніше імʼя довжиною 247–255 байтів проходило
  валідацію і провалювалося б посеред передачі; resume support свідомо
  не вимикається, щоб відвоювати ці 9 байтів. (P2) Заміна чекпойнта
  тепер працює після першого циклу: `Session.MoveFile` не може
  портативно перезаписати наявну ціль на SFTP, тож починаючи з другого
  циклу кожна публікація провалювалася б. Тепер потік публікації —
  завантаження у тимчасовий файл, явний `RemoveFiles` наявного
  канонічного чекпойнта (телеметрія у власності движка — ніколи не
  дані), потім перейменування. Це навмисно задокументовано як
  неатомарне: читач може на мить побачити відсутність чекпойнта під час
  заміни, але ніколи частково записаний; фейкова сесія самотестів тепер
  моделює збій rename-target-exists, щоб будь-який код, що покладається
  на перезапис через перейменування, провалювався в тестах, а не в
  production. (P2) Виявлення мутацій тепер відповідає власному
  заявленому контракту: `Verified`-шлях, у якого змінився розмір АБО
  `LastWriteTimeUtc`, — це `MUTATION_VIOLATION` за `MutationPolicy =
  "Fail"` (раніше порівнювався лише розмір, тож append-only файл,
  перезаписаний з тим самим розміром, але новою mtime, мовчки зберігав
  довірений пропуск). Швидкий шлях порівняння рядків зберігає незмінною
  вартість плану для 100 тис. файлів; нерозбірні історичні мітки часу
  fail visible як мутація, а не мовчки довіряються. Це все ще не
  виявлення лише за міткою часу: шлях, відсутній у стані, лишається NEW
  і завантажується незалежно від його мітки часу. 15 нових поведінкових
  самотестів; усі інваріанти раунду 1 (нуль завантажень при
  STATE_NOT_INITIALIZED, реконсиляція пошкодженого стану лише на
  Archive, Busy-vs-Error блокування, білий список успіху Fast Health,
  відсутність повного `CompareDirectories` на звичайних циклах,
  відсутність `-delete`) повторно перевірені наявним набором тестів.
- Посилення `BRAVO.BazaSync`, раунд 3 (незалежне пост-ревʼю перед
  прийняттям у production). (P1) IncrementalAppendOnly більше не може
  мовчки перезаписати вже наявний віддалений файл BAZA: типове значення
  `TransferOptions.OverwriteMode` WinSCP — `Overwrite`, а цільове
  завантаження не мало попередньої перевірки самого віддаленого файлу,
  тож кандидат, ще не `Verified` у локальному стані, чий віддалений
  шлях уже існував (найважливіше — вікно аварії: віддалений `PutFiles`
  успішний → `Save-BRAVOBazaState` провалився → наступний цикл знову
  бачить кандидата), був би повторно завантажений поверх наявного
  незмінного файлу. Кожен кандидат `ToUpload` тепер спочатку отримує
  один цільовий `FileExists`: віддалений файл відсутній → звичайне
  завантаження; віддалений файл присутній з тим самим розміром →
  відновлено без жодного виклику `PutFiles`, зафіксовано `Verified=true`
  і пораховано як `RecoveredRemote` (цикл може бути `COMPLETE`);
  віддалений файл присутній з іншим розміром → явний
  `Status=REMOTE_CONFLICT` з `RelativePath`/`LocalSize`/`RemoteSize` для
  кожного конфлікту, нуль `PutFiles` для цього кандидата, без
  просування провенансу успішного циклу, без публікації чекпойнта,
  Health `CRITICAL` з точним шляхом та обома розмірами. Перезапис
  ніколи не є типовою політикою — будь-яка майбутня підтримка перезапису
  мала б бути окремою, явно названою політикою оператора. Записи
  Verified/TrustedSkip взагалі не отримують віддаленого пошуку, зберігаючи
  профіль вартості 100000-verified-плюс-10-кандидатів (без
  `CompareDirectories`, без `synchronize -preview`, без повного
  сканування дерева). (P2) Результат `RemoveFiles` заміни чекпойнта
  більше не відкидається: WinSCP повідомляє про збої видалення окремих
  файлів у результаті операції без кидання винятку, тож невдале
  видалення тепер дає `CheckpointPublished=false` (WARNING; попередній
  чекпойнт лишається неушкодженим) замість заявлення про успішну
  заміну. (P2) `Update-BRAVOBazaSyncResultNewAfterCutoff` тепер також
  враховує локальну діагностику NewAfterCutoff для циклів
  `INCOMPATIBLE_NAME` та `REMOTE_CONFLICT` (стан зберігається в обох
  випадках). (P2) Коли порушення мутації та несумісні імена (та/або
  віддалені конфлікти) співіснують в одному циклі, Fast Health виводить
  кожну непорожню категорію в тому самому запуску — одна лишається
  основним Status/Message, інші зʼявляються в Info, замість того, щоб
  бути виявленими лише на наступному циклі. 14 нових поведінкових
  самотестів, включно з прийняттям відновлення після аварії
  (`CrashAfterRemoteUploadBeforeStateCommitDoesNotReupload`) і доказами
  обмеження області віддаленого пошуку.
- Посилення `BRAVO.BazaSync`, раунд 4 (незалежне пост-ревʼю взаємодії
  Full Audit × AlreadyRemote). (P1) Вердикт очікування (pending) Full
  Audit поточного циклу тепер перекриває загальне відновлення
  AlreadyRemote за однаковим розміром. Production Full Audit порівнює з
  `-criteria=time,size` і повідомляє і `UploadNew`, і `UploadUpdate`,
  але `ConvertTo-BRAVOBazaFullAuditResult` зводив усе до "вже
  відповідає" і втрачав очікувану дію — тож файл, явно позначений
  аудитом як `UploadUpdate` (той самий розмір, інша mtime на
  віддаленій стороні), проваливсь би через планувальник до
  попередньої перевірки кандидата з раунду 3, збігся б за розміром,
  був би "відновлений" як `AlreadyRemote`/`Verified` і мовчки скасував
  би власну знахідку дрейфу аудиту (та сама вада застосовувалась і до
  bootstrap-заповнення очікуваних-але-однакових-за-розміром віддалених
  файлів). Адаптер тепер зберігає `PendingItems`
  (`RelativePath`/`Action`/`Reason`); цикл синхронізації тримає мапу
  очікування поточного аудиту, і будь-який очікуваний кандидат
  виключається із загального відновлення: віддалений файл відсутній →
  звичайне завантаження + верифікація; віддалений файл присутній →
  явний `Status=AUDIT_DRIFT` з Action/Reason аудиту та локальним/
  віддаленим розмірами, нуль `PutFiles`, ніколи не перезапис, без
  просування провенансу успішного циклу, без чекпойнта, Health
  `CRITICAL` з назвою шляху, дії та обох розмірів. `LastFullAuditUtc`
  все одно просувається на такому циклі (сам аудит успішно завершився
  і знайшов дрейф — свіжість аудиту не є успіхом синхронізації і
  навмисно не змішується з `LastSuccessfulSyncUtc`). Починаючи з раунду
  5 вердикт зберігається по шляху (див. запис раунду 5 нижче), а не
  обмежується лише циклом аудиту; жодних додаткових віддалених
  сканувань не додається. Коли жоден поточний аудит не позначає
  кандидата, відновлення після аварії за однаковим розміром продовжує
  працювати без змін. (P2) `NewAfterCutoff` тепер справді означає
  "після cutoff": належність визначається знімком циклу (легковаговим
  списком `CutoffSnapshotRelativePaths` у SyncResult) замість "відсутній
  у збереженому стані" — кандидати до cutoff, навмисно не збережені в
  стані (несумісні імена, віддалені конфлікти, дрейф аудиту, невдалі/
  очікувані), більше не помилково зараховуються як нові, тоді як файл,
  доданий після знімка з заднім числом у `LastWriteTime`, все одно
  зараховується (мітки часу ніколи не є тестом належності); попереднє
  очікування з раунду 3 відповідно скориговано. (P2) Тепер
  задокументовано припущення про єдиного автора запису: `FileExists →
  PutFiles` не є розподіленою атомарною операцією, а блокування BAZA —
  загальномашинне, тож IncrementalAppendOnly вимагає рівно одного
  автора запису на керований віддалений корінь BAZA; перевірка
  існування цілі додатково повторюється безпосередньо перед
  `PutFiles` (після підготовки віддаленого каталогу), щоб мінімізувати
  вікно TOCTOU, і жодної абсолютної розподіленої гарантії
  відсутності перезапису не заявляється. 13 нових/оновлених
  поведінкових самотестів.
- Посилення `BRAVO.BazaSync`, раунд 5 (фінальне ревʼю прийняття у
  production). (P1) `AUDIT_DRIFT` тепер липкий (sticky) між циклами.
  Раунд 4 тримав мапу очікування аудиту лише в пам'яті для циклу, в
  якому виконувався аудит, тож після циклу `AUDIT_DRIFT` збережений
  стан ніс лише `Verified=false` — наступний звичайний інкрементний
  цикл (без власного аудиту) бачив звичайного неверифікованого
  кандидата, знаходив віддалений шлях наявним з відповідним розміром і
  загально-відновлював його до `Verified=true`, дозволяючи
  `COMPLETE`/здоровий цикл, хоча нічого не змінилося з моменту, коли
  авторитетний аудит повідомив про дрейф (вікно хибно-зеленого стану
  до наступного періодичного аудиту, явно визначене як неприйнятне).
  Результат `AUDIT_DRIFT` тепер зберігає мінімальний блокувальник по
  шляху всередині запису стану файлу (`BlockReason="AuditDrift"`,
  `AuditAction`, `AuditReason`, `AuditDetectedUtc` — початковий час
  виявлення зберігається при повторних зустрічах; збереження/читання
  файлу стану передає додаткові поля запису без змін, тож без
  підвищення версії схеми). Кожна перевірка кандидата на фазі
  завантаження тепер звіряється і з мапою аудиту поточного циклу, і зі
  збереженим блокувальником: заблокований шлях з наявним віддаленим
  файлом лишається `AUDIT_DRIFT` (нуль `PutFiles`, без просування
  провенансу, без чекпойнта, Health `CRITICAL`) на кожному наступному
  звичайному циклі. Блокувальник знімається лише позитивним
  розв'язанням: пізніший Full Audit, що підтверджує відповідність
  шляху, повторно заповнює чистий запис `Verified=true`, або зникнення
  віддаленого файлу з подальшим успішним цільовим
  завантаженням+верифікацією; самого лише збігу розміру ніколи
  недостатньо для зняття блокування — це саме та ознака, яку аудит уже
  довів недостатньою. Bootstrap і реконсиляція пошкодженого стану
  зберігають той самий блокувальник (очікуваний аудитом шлях ніколи не
  лишається відсутнім у стані там, де наступний цикл міг би
  загально-відновити його). Звичайні неверифіковані/очікувані записи не
  несуть блокувальника, тож відновлення після аварії з раунду 3
  (успішне завантаження/невдале збереження стану → `AlreadyRemote` за
  однаковим розміром) зберігається і повторно перевірене. (P2)
  `NewAfterCutoff` тепер розрізняє валідний порожній знімок від
  недоступного: `CutoffSnapshotRelativePaths` — це `$null`, коли жодний
  знімок не було зроблено (лише тоді застосовується legacy-резервний
  варіант зі збереженого стану), і `@()` для справді порожнього
  каталогу на момент cutoff — порожній знімок є авторитетним, тож файл,
  що (повторно) з'являється після нього, зараховується як новий, навіть
  якщо старіший збережений стан усе ще про нього пам'ятає. 12 нових
  поведінкових самотестів.
- Посилення `BRAVO.BazaSync`, раунд 6 (ревʼю прийняття у production
  шляхів збою липкого блокувальника). (P1) Збережений блокувальник
  AuditDrift більше не зникає разом зі своїм локальним шляхом:
  планувальник ітерує лише знімок, тож заблокований запис, чий
  локальний файл зник, ніколи не перевірявся — цикл міг стати
  `COMPLETE`/здоровим і опублікувати чекпойнт, поки авторитетний
  вердикт аудиту лишався нерозв'язаним (зникнення локального файлу — не
  позитивне розв'язання). Кожен цикл тепер додатково сканує вже
  завантажений стан (суто локально, без віддалених викликів) на
  предмет блокувальників AuditDrift, відсутніх у поточному знімку, і
  виводить їх як записи `AUDIT_DRIFT` з `LocalMissing=$true` та точним
  відносним шляхом: цикл лишається не-COMPLETE, провенанс не
  просувається, чекпойнт не публікується, Health лишається `CRITICAL`,
  блокувальник зберігається, і пізніший Full Audit не знімає його
  мовчки лише тому, що джерело зникло (відновлений локальний шлях
  лишається заблокованим, доки не буде дійсно розв'язаний). (P1) Перехід
  довіри Full Audit тепер переживає невдале фінальне збереження стану
  завдяки вузькому write-ahead-маркеру (`AuditReconciliationPending` у
  стані компонента — навмисно не загальнопроєктний Durable Journal).
  Перед аудитом, що змінює довіру, маркер атомарно зберігається; якщо
  це збереження провалюється, аудит взагалі не запускається
  (контрольована помилка). Маркер знімається в пам'яті лише після
  інтеграції результатів аудиту і потрапляє на диск лише з успішним
  фінальним збереженням — тож аварія чи збій збереження між аудитом і
  фінальним збереженням залишає маркер на диску, і раніше небезпечне
  вікно (атомарне збереження зберігало стару довіру `Verified=true`,
  яку аудит щойно відкликав у пам'яті, дозволяючи наступному циклу
  повернути її в здоровий стан через TrustedSkip) тепер fail closed:
  окремий Health повертає `RECONCILIATION_REQUIRED` (CRITICAL, нуль
  завантажень, нуль TrustedSkip старих записів Verified), а наступний
  запуск `BRAVO_ARCHIV` примусово повторно запускає реконсиляцію Full
  Audit, знімаючи маркер лише після власного успішного фінального
  збереження. Звичайні цикли без аудиту ніколи не пишуть маркер, тож
  прості збої збереження стану при завантаженні зберігають свою
  дешеву семантику `INCOMPLETE`, а прийняття відновлення після аварії з
  раунду 3 (`CrashAfterRemoteUploadBeforeStateCommitDoesNotReupload`)
  перемодельоване як звичайний сценарій циклу, який воно завжди й
  описувало, і все ще проходить. 14 нових поведінкових самотестів.
- Фікс першого блокера real-SFTP acceptance (DEV-LIMS, сценарій 1):
  `BRAVO_ARCHIV` аварійно завершувався з exit 90 (`The term 'if' is not
  recognized…`) ще до того, як фаза синхронізації BAZA взагалі
  запускалась. `Invoke-BRAVOBazaIncrementalSync` обчислював тайм-аут
  операції як `[int]( if … )` — усередині звичайних дужок `if`
  парситься як КОМАНДА з назвою "if" (цілком валідно для AST-парсера,
  CI та будь-якого синтаксичного гейта) і провалюється лише в
  runtime з CommandNotFoundException. Набір самотестів навмисно ніколи
  не виконує цю функцію звʼязування (вона відкриває реальну WinSCP-
  сесію; усе, що нижче, тестується через ін'єктовані фейкові сесії),
  тож перше виконання за весь час відбулося на реальному сервері.
  Виправлено на `[int]$( if … )`. Постійний захист для всього
  бандла тепер закриває весь клас проблем:
  `Diagnostics/NoKeywordParsedAsCommand` парсить кожен production-скрипт
  і провалюється на будь-якому `CommandAst`, чиє ім'я команди — це
  ключове слово оператора, яке ніколи не може бути легітимною командою
  (`if`/`elseif`/`else`/`switch`/`while`/`do`/`try`/`catch`/`finally`/`until`;
  `foreach`/`where` навмисно виключені як валідні псевдоніми
  конвеєра) — цей захист упіймав би баг ще на момент коміту.
- Фікс другого дефекту, видимого в тому самому лозі DEV-LIMS acceptance:
  рядок аудиту retention на запуск друкував буквальні плейсхолдери
  `{0}/{1}/{2}` у своїй першій половині (`Аудит retention: generation
  оцінено={0}; …`) — `-f` звʼязується тісніше за `+`, тож форматувався
  лише другий конкатенований рядок. Конкатенацію взято в дужки; другий
  захист для всього бандла (`Diagnostics/NoHalfFormattedStringConcatenation`)
  тепер провалюється на будь-якому виразі `+`, чий правий операнд — це
  формат `-f`, тоді як ліва сторона все ще містить невідформатовані
  плейсхолдери `{N}`.
- Фікс третього блокера real-SFTP acceptance (DEV-LIMS, сценарій 1,
  повторна спроба): після фіксу if-як-команда фаза BAZA стартувала, але
  зависала нескінченно — голі інтерактивні запрошення `winscp>`
  протікали в консоль оператора, породжені процеси WinSCP сиділи на
  ~0% CPU, а лог зупинявся на заголовку секції синхронізації BAZA.
  Корінна причина: `Invoke-BRAVOBazaIncrementalSync` передавав
  бандловий `$winSCPPath` (`Tools\WinSCP.com`, консольний CLI-стаб,
  який використовують legacy-потоки) напряму в `Session.ExecutablePath`,
  тоді як .NET-збірка WinSCP вимагає `winscp.exe` — зі стабом `.com`
  дочірній процес запускає інтерактивну консоль, і рукостискання сесії
  ніколи не завершується. З'єднання тепер розв'язує ту саму пару
  dll+exe, яку завжди використовував legacy-код
  `Get-BAZASFTPComparison` (`Get-BRAVOWinSCPDotNetComponents`), з
  контрольованим `ERROR` SyncResult, коли сумісної пари не знайдено, а
  `Invoke-BRAVOBazaComponentSyncSession` отримав захист
  defense-in-depth: ExecutablePath, що вказує на `WinSCP.com`, тепер
  швидко провалюється з пояснювальним `ERROR` замість зависання.
  Додано поведінкові + структурні тести
  (`ComStubExecutableFailsFastInsteadOfHanging`,
  `ArchiveWiringResolvesRealWinSCPExeForEngine`).
- Фікс четвертого блокера real-SFTP acceptance (DEV-LIMS, 2026-08-13,
  повторна спроба сценарію 1 після фіксу winscp.exe). Факти запуску:
  архіви MODEL/BLOG/BRAVOEXCH 3/3, генерація COMPLETE, VSS OK,
  завантаження архіву по SFTP OK, .NET-сесія WinSCP досягла реального
  шляху BAZA Full Audit — потім інкрементний `BAZA_APP` завершився
  `ERROR` з `CommandNotFoundException: Get-BAZASFTPComparison`,
  піднятим зсередини `FullAuditProvider`, Health після backup —
  `CRITICAL`, exit 50 `SftpFailed`; сценарій 1 ще НЕ PASS. Корінна
  причина (емпірично відтворена на Windows PowerShell 5.1):
  `.GetNewClosure()` привʼязує scriptblock провайдера до нового
  динамічного модуля — захоплені змінні копіюються, але пошук імені
  команди для приватної (на рівні script-scope, неекспортованої)
  `Get-BAZASFTPComparison` рантайму там не розв'язується, тож провайдер
  провалився на першому ж реальному виклику через межу модуля
  `BRAVO.BazaSync`. Провайдер тепер будується
  `New-BRAVOBazaArchiveFullAuditProvider`, яка захоплює явні посилання
  `Get-Command` FunctionInfo для ОБОХ викликів (`Get-BAZASFTPComparison`
  та `ConvertTo-BRAVOBazaFullAuditResult` — вкладений імпорт модуля
  може бути так само невидимим з динамічного модуля) і викликає їх
  через оператор виклику, а URL/host key/шляхи приймає як явні
  захоплені параметри замість динамічних пошуків у script-scope;
  `Get-BAZASFTPComparison` лишається приватною. Вузька межа обробки
  помилок у движку тепер нормалізує виняток провайдера в структурований
  збій аудиту (`Success=$false`, точна причина в `FullAuditError`)
  замість загальної помилки сесії; порядок write-ahead
  `AuditReconciliationPending` не змінився, тож невдалий запуск
  DEV-LIMS коректно залишив маркер fail-closed на диску, і наступний
  запуск Archive примусово реконсилює. Нові поведінкові тести:
  production-провайдер створюється всередині модуля з приватним
  фейковим порівнянням і виконується через межу модуля
  (`FullAuditProviderCrossesModuleBoundary`), тіло замикання захищене
  від повернення до голих приватних пошуків команд, а ланцюжок
  відновлення маркера очікування повторно перевірений наскрізно з
  межею production-провайдера
  (`PendingMarkerRecoveryWorksWithProductionProviderBoundary`).
- Фікс п'ятої знахідки real-SFTP acceptance (DEV-LIMS, 2026-08-13):
  окрема резервна синхронізація BAZA в `BRAVO.Health.Runtime` передавала
  сирий бандловий `$winSCPPath` (`Tools\WinSCP.com`) у `-WinSCPExecutablePath`
  движка — той самий дефект, що й блокер acceptance #3, у другому місці
  з'єднання. Зазвичай він ніколи не виконується (Health повторно
  використовує SyncResult, наданий Archive), і проявився лише тоді,
  коли збій автентифікації SFTP змусив Archive пропустити фазу BAZA,
  спрямувавши Health після backup на резервний шлях — де захист
  defense-in-depth з раунду 3 упіймав стаб `.com` у production і швидко
  провалився з точним повідомленням про усунення замість зависання.
  З'єднання Health тепер розв'язує ту саму пару dll+exe через
  `Get-BRAVOWinSCPDotNetComponents` (контрольований `ERROR` SyncResult,
  коли сумісної пари не існує), дзеркалюючи фікс Archive. Новий
  структурний тест для з'єднання гілки Health плюс захист для всього
  бандла (`Diagnostics/NoRawWinSCPComPathPassedToEngine`), що забороняє
  передавати сирий `$winSCPPath` у `-WinSCPExecutablePath` будь-де — той
  самий дефект з'явився у двох незалежних місцях виклику, тож клас
  тепер закритий для всього бандла.
- Уніфіковано консольний прогрес для багатопідкрокових стадій у
  `BRAVO_ARCHIV` (рефакторинг лише UI — семантика backup/VSS/SFTP/
  BAZA/retention не змінилася). Нові канонічні helper-и в
  `BRAVO.Console` (`Format-BRAVOSubstepPhase`, `Format-BRAVOElapsedText`,
  `Format-BRAVORunningDetail`) замінюють спеціальні рядки фази/минулого
  часу, розкидані по рантайму. Завантаження архіву на SFTP тепер показує
  підкроки на рівні компонента (`Завантаження MODEL на SFTP (1 з 3)` з
  уже відомим розміром локального файлу як деталлю) замість однієї
  загальної фази — `mdz`+`sha512` компонента є одним видимим підкроком,
  а маніфест — окремою короткою фазою, тож видимий оператору лічильник
  лишається `(1 з 3)`, а не `(1 з 7)`; копіювання NAS/SMB отримало ті
  самі фази на рівні компонента; фаза SHA512 несе свою позицію
  компонента. Формулювання рядка виконання уніфіковано до
  `Виконується 7 сек.` / `Виконується 1 хв. 24 сек.` (змішаний варіант
  `Виконується, минуло …` прибрано всюди) у циклах моніторингу 7-Zip,
  Robocopy, завантаження WinSCP та legacy-синхронізації.
  Задокументовано в `docs/MANUAL_RUN_CONSOLE_UX.md`; 6 нових самотестів
  покривають формати helper-ів і з'єднання компонент-а-не-файлів.
- Maintenance більше не видає хибний `WARNING`, коли `range_id_log.json`
  перевіряється за кілька секунд після того, як сам цей запуск запустив
  службу BRAVO (спостережено на прийомному запуску DEV-LIMS одразу
  після повного відновлення моделі: служба запущена о 00:09:24,
  попередження о 00:09:26, файл знову присутній через кілька хвилин —
  служба створює файл асинхронно після запуску). Крок `[8/8]` (range-ID)
  тепер чекає на файл з обмеженою кількістю повторних спроб (до 30 с,
  інтервал 5 с, цикл з обмеженим дедлайном) — але ЛИШЕ коли файл
  відсутній І службу BRAVO запустив саме цей запуск; звичайний запуск з
  наявним файлом не отримує жодної додаткової затримки, а запуск, що
  ніколи не торкався служби, зберігає негайне попередження, як і
  раніше. Проміжні стани логуються на рівні `INFO`; якщо файл так і не
  з'явився, рівно один `WARNING` пояснює тайм-аут очікування запуску
  (`Файл контролю діапазонів ID не з'явився протягом 30 сек. після
  запуску BRAVO`) замість загального "не знайдено". Підсумковий рядок
  запуску також переформульовано — `Контроль діапазонів ID: УВІМКНЕНО;
  поріг >80%; файл: …` — бо старе `понад 80% у …` читалося так, ніби
  використання вже перевищило поріг, тоді як воно лише описувало поріг
  моніторингу. Оцінка порогу, формат `range_id_log.json`, планування
  відновлення та семантика лише-WARN-серйозності не змінилися. Нові
  поведінкові самотести покривають шляхи без затримки/із запізнілим
  файлом/тайм-аутом плюс структурні захисти (єдиний фінальний
  `WARNING`, очікування, обумовлене прапорцем запуску служби, відсутність
  резервних шляхів). `TimeoutSeconds` — справжня верхня межа: кожен sleep
  обмежується залишковим бюджетом (`min(interval, remaining)`), тож
  цикл ніколи не може перевищити дедлайн на повний додатковий інтервал
  — семантика дедлайну регресійно протестована детерміновано з фейковим
  годинником (`Timeout=13/Interval=5` має спати рівно `5,5,3`).

## 5.0.2 — 2026-08-19

Стабільний hotfix-реліз, промотований з верифікованого кандидата
`5.0.2-rc.1` (RELEASE_POLICY.md §12; прийнятий HEAD `26de54e`, прогін
CI 32228324024 SUCCESS — self-test, PSScriptAnalyzer, parser/BOM/JSON,
gitleaks усі зелені). Жодних функціональних змін рантайму відносно
прийнятого кандидата: ця промоція прибирає суфікс prerelease, встановлює
стабільний release channel, оновлює заголовки операторської документації
та регенерує маніфест цілісності рантайму.

Real-server acceptance (§12.1) на первісно постраждалому production-
сервері (єдиний Fixed-диск, 2026-08-19): `BRAVO_DRY_RUN.ps1`, включно з
`-TestAccess`, завершився з 58 PASS / 0 WARN / 0 FAIL, і повний запуск
`BRAVO_ARCHIV.ps1` завершився успішно — нова діагностика дисків
залогувала точно той профіль, що раніше призводив до аварії (один
Fixed-диск C:, 177.45 ГБ вільно), free-space-preflight пройшов без
жодного винятку, генерація `20260819_121141` досягла COMPLETE (3 з 3
архівів з верифікованими SHA512-sidecar-файлами), 7 з 7 файлів
завантажено на SFTP, BAZA_APP повністю синхронізована, health-check
повідомив, що всі backup актуальні. Той самий сервер узагалі не
створював backup на 5.0.x до цього фіксу.

Hotfix-кандидат (RELEASE_POLICY.md §12) для production-інциденту,
спостереженого 2026-08-19: на будь-якому сервері з рівно ОДНИМ локальним
Fixed-диском free-space-preflight Archive провалювався на кожному
запуску з "The property 'Count' cannot be found on this object" і
блокував увесь нічний цикл архівування з exit 40 -- хибнопозитивне
блокування без реальної нестачі місця (звітний сервер мав 177 ГБ
вільно проти порогу в 20 ГБ). Постраждалі релізи: 5.0.0, 5.0.0-rc.1 та
5.0.1 -- кожне розгортання лінії 5.0.x на сервері з одним диском узагалі
не створювало backup.

- Виправлено `Get-BRAVOArchiveFreeSpaceResult` у
  `modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1`: список дисків
  будувався як `$localDrives = if (...) { @(...) } else { @(...) }`; у
  Windows PowerShell 5.1 блок if/else, використаний як вираз, розгортає
  результат з одним елементом назад у скаляр при виході -- незважаючи
  на власний `@()` кожної гілки -- і подальший `$localDrives.Count`
  кидає `PropertyNotFoundException` під `Set-StrictMode -Version 2.0`
  (яку `BRAVO_CONFIG_LOADER.ps1` застосовує на кожному production-
  запуску). Фікс обгортає весь вираз if/else в один зовнішній `@()`
  — єдину форму, що надійно зберігає масивність для 0/1/N елементів.
  Відтворено детерміновано до фіксу і повторно перевірено після.
- Додано безумовне діагностичне логування на початку секції
  free-space: кожен виявлений диск (усі значення `DriveType`, не лише
  Fixed) тепер логується з типом/готовністю/форматом/вільним/загальним
  об'ємом ще до запуску самої перевірки, тож будь-який майбутній збій
  залишає в лозі точно те, що бачила система, а не лише повідомлення
  про виняток.
- Додано регресійний самотест
  `Archive/FreeSpaceSingleFixedDriveSurvivesStrictMode`, який викликає
  реальну функцію з рівно одним ін'єктованим Fixed-диском під явним
  `Set-StrictMode -Version 2.0` -- наявний раніше тест з одним диском не
  міг це виявити, бо оснастка самотестів інакше не запускається на
  production-рівні StrictMode.

Взято cherry-pick з верифікованого фіксу `developer` (`274b514`, прогін
CI зелений). Жодних інших функціональних змін відносно 5.0.1.

## 5.0.1 — 2026-08-18

Стабільний hotfix-реліз, промотований з верифікованого кандидата
`5.0.1-rc.1` (RELEASE_POLICY.md §12; прийнятий HEAD `69bf6ff`, прогін
CI 32115265892 SUCCESS — self-test, PSScriptAnalyzer, parser/BOM/JSON,
gitleaks усі зелені). Жодних функціональних змін рантайму відносно
прийнятого кандидата: ця промоція прибирає суфікс prerelease,
встановлює стабільний release channel, оновлює заголовки операторської
документації та регенерує маніфест цілісності рантайму.

Докази валідації для базового фіксу: `BRAVO_SELF_TEST.ps1` PASSED
(763 перевірки, 0 FAIL) і локально, і в CI; підтверджено, що нове
регресійне покриття дійсно вловлює первісний дефект — тимчасовим
повторним внесенням його (сирий `$SlackMode` замість ефективного
`$script:SlackMode` в одному з двох преflight-гейтів webhook) і
спостереженням очікуваного, конкретного збою самотесту, з подальшим
відкатом. `BRAVO_DRY_RUN.ps1 -TestAccess` підтвердив реальний доступ
запис/читання/видалення до всіх production-шляхів архіву/логів
(RuntimeRoot, BackupRoot, SystemLogRoot, MODEL/BLOG/BRAVOEXCH +
`.work`, ProgramData lock/state); знахідки щодо SFTP і стану
планувальника в тому запуску відображають виконання поза
production-контекстом облікового запису задачі `SYSTEM` і не є доказом
регресії в цьому фіксі. `BRAVO_RESTORE_TEST.ps1` не зміг завершитися в
середовищі валідації (на цьому хості не було доступного маніфесту
генерації `COMPLETE` — його спеціальні локальні backup не були
створені повним циклом `BRAVO_ARCHIV.ps1`); цей фікс не торкається
логіки відновлення, але цілісність відновлення для цього циклу
лишається інакше неперевіреною поза статичним/поведінковим покриттям
self-test і має бути підтверджена на реальному сервері згідно з
RELEASE_POLICY.md §9, якщо це вже не покрито прийняттям попереднього
циклу.

Цей hotfix усуває регресію доставки сповіщень, внесену маршрутизацією
webhook на основі серйозності GENERAL/ALERTS у 5.0.0.

- Виправлено `-EnableAllSlack`/`-DisableAllSlack` у
  `BRAVO_MAINTENANCE.ps1`: ефективне перевизначення режиму сповіщень
  застосовувалося до `$script:SlackMode` вже після того, як preflight
  маршрутів webhook GENERAL/ALERTS розв'язав (і провалідував) лише
  маршрути, досяжні за режимом до перевизначення. Коли `NotificationMode`
  у `BRAVO.config` було встановлено як `none` або `errors_only`,
  `-EnableAllSlack` мовчки ставав no-op: кожна спроба сповіщення шукала
  маршрут, який preflight ніколи не розв'язував, отримувала `$null`
  URL webhook і мовчки провалювалася в навколишньому `try/catch`.
  Ефективний режим тепер обчислюється один раз, одразу після сирого
  налаштованого значення, і послідовно використовується і розв'язанням/
  валідацією preflight, і всіма відправниками рантайму.
- Видалено мертвий, дубльований блок розв'язання webhook-сповіщень,
  залишений у `modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1` після
  міграції 5.0.0 на централізований конвеєр доставки
  `BRAVO.Notifications` — жоден відправник не читав його результат; він
  лише виконував зайвий пошук у Credential Manager на кожному запуску
  Archive.
- Додано `.claude` до шаблону винятків runtime-manifest/guard
  (`ci\Update-BRAVORuntimeManifest.ps1`, `BRAVO_RUNTIME_GUARD.ps1`), за
  зразком наявних винятків `.git`/`.vscode`/`local-backups` — оснастка
  сесії AI-асистента, не частина поставленого рантайму.

## 5.0.0 — 2026-08-11

Стабільний продакшн-реліз, промотований з верифікованого кандидата
5.0.0-rc.1. Кандидат пройшов повний Windows CI pipeline і перевірки на
реальному сервері на Windows Server 2022 / Windows PowerShell 5.1: генерацію
архіву та валідацію 7-Zip, публікацію SHA512, вивантаження по SFTP,
перевірку стану (health-check), обслуговування (maintenance) та сповіщення.
Під час промоції не змінювались ані схема конфігурації, ані схема стану,
ані ціль облікових даних, ані формат архіву, ані типове значення retention,
ані протокол передачі, ані контракт підтримуваних ОС.

- Archive тепер виконує ту саму преперевірку вільного місця на фіксованих
  дисках, що й Maintenance, перш ніж очищення, локальна синхронізація, VSS
  або генерація архіву зможуть змінити стан. Використовує
  `Limits.MinimumFreeSpaceGB` і `Limits.ExcludedDrives`, звітує по кожному
  перевіреному диску, зупиняється з канонічним кодом виходу локального
  архіву `40` і рендерить звичайний фінальний підсумок про невдачу замість
  завершення без результату для оператора.
- Невдала преперевірка вільного місця в Archive тепер надсилає одне
  негайне `CRITICAL`-сповіщення в Discord/Slack у режимі `errors_only` або
  `all`. Повідомлення вказує уражений диск, вільне/загальне місце,
  налаштований поріг, необхідну дію, шлях до журналу та код виходу.
  `NotificationMode=none` і `-NoSlack` залишаються визначальними; помилка
  вебхука логується з захищеними секретами і ніколи не замінює основний
  код виходу.
- Стан володіння VSS і маніфести генерацій тепер записуються через
  тимчасові файли й атомарно замінюються сумісними з Windows PowerShell
  5.1/.NET Framework легальними шляхами резервних копій. Невдала заміна
  зберігає попередній валідний стан/маніфест і очищає тимчасові файли
  резервних копій.
- Публікація архіву тепер fail-closed, якщо не вдається записати фінальний
  сайдкар `.sha512`. Вже перенесений архів і будь-який частковий сайдкар
  відкочуються, опубліковані шляхи/поля хешу очищаються, а збій
  класифікується як `PUBLISH`/exit `40`, а не вводить в оману як помилка
  валідації хешу.
- Фіналізація генерації тепер відбувається до обчислення коду виходу та
  підсумку для оператора. Неможливість зберегти фінальний стан
  передачі/health позначає прогін як невдалий. Об'єкти результату також
  несуть стабільні поля збою, скалярні лічильники успіху StrictMode-safe,
  а шляхи знімків ініціалізуються по компонентах, щоб застарілі значення
  не просочувалися у виключну (exception) гілку.
- Завершення Maintenance через нестачу диска тепер рендерить стандартний
  фінальний підсумок, використовує обчислений код виходу BRAVO, поважає
  `-NoPause` і записує унікальні імена журналів секунда-та-PID. Типовий
  запланований день реставрації тепер явно неділя (`7`).
- Вузько необхідний допуск `ExecutionPolicy Bypass` для згенерованих
  ручних launcher'ів задокументовано й обмежено `BRAVO_SETUP.ps1`; усі
  інші перевірки заборонених патернів залишаються блокуючими.
- `modules/BRAVO.Notifications/BRAVO.Notifications.psd1` тепер містить
  необхідний за політикою репозиторію UTF-8 BOM. Чистий чекаут у GitHub
  Actions раніше провалював і явний BOM-гейт, і self-test на Windows
  PowerShell 5.1, хоча локальні перевірки парсера й runtime на
  розробницькому хості проходили.
- Додано регресійне покриття для політики вільного місця та сповіщень,
  порядку преперевірок, атомарної заміни стану, невдалої публікації
  SHA512, фіналізації маніфесту, мапінгу стадій збою, обробки результату
  під StrictMode, ранніх підсумків/іменування журналів/типового розкладу
  Maintenance, а також політики launcher'ів. `RUNTIME_MANIFEST.json`
  перегенеровано з фінальних файлів RC.

## 5.0.0-dev.19 — 2026-08-11

Мінімальний реліз спостережуваності/коректності, за результатами двох
реальних acceptance-прогонів DEV-LIMS для 5.0.0-dev.18, з раундом ревʼю,
застосованим перед релізом, який замінив початковий, усе ще незалежний
дизайн класифікації статусу на такий, що споживає фактичний обчислений
код виходу BRAVO (див. перші два пункти нижче). Чотири точкові фікси —
не змінено семантику backup, restore, VSS, SHA512, retention, MANIFESTS,
transfer, маршрутизації сповіщень, `NotificationMode`, планувальника чи
числових кодів виходу; семантика "лише попередження" для відсутнього
файлу Range ID незмінна.

- Фінальний людиночитний статус Maintenance (журнальний рядок
  `=== СТАТУС: ... ===`, поле "Статус" у консольному `РЕЗУЛЬТАТ` і
  сповіщення Discord/Slack у гілці успіху/попереджень) тепер походить
  з ТОГО САМОГО обчисленого коду виходу BRAVO, з яким процес фактично
  завершується, — а не з незалежної повторної перевірки
  `$script:criticalErrorOccurred`/`$script:BRAVOWarningCount`.
  `Get-BRAVOMaintenanceResolvedExitCode` — єдине місце, де живе політика
  пріоритетів (critical > warnings > success, 40/41/60 через
  `Resolve-BRAVOExitCode`); `Get-BRAVOMaintenanceFinalStatus
  -ExitCode <resolved code>` — чиста функція, що класифікує це число
  через `Get-BRAVOExitCodeName` (`Success`/`SuccessWithWarnings`/
  будь-що інше) у текст/колір — вона більше не перевіряє ці два прапори
  самостійно. Обчислення коду виходу також перенесено раніше: тепер
  воно виконується одразу після закриття зовнішнього try/catch (усі
  бізнес-операції та fail-safe-обробка, включно з установленням
  прапора critical у самому catch, вже завершені) і до запису
  журнального рядка `=== СТАТУС ===`, а не після нього, як у першому
  варіанті цього фіксу, — тож журнал більше не може прочитати значення,
  обчислене з іншого, раннішого знімку, ніж фактичний код виходу
  процесу. Сповіщення `Send-FinalReport` виконується ще раніше
  (всередині try, до його catch), тож воно бере власний знімок через
  той самий канонічний resolver; якщо пізніше необроблений виняток
  змінює результат, саме реальний, пізніше обчислений
  `$script:maintenanceRuntimeExitCode` — а не це сповіщення — визначає
  код виходу процесу, точно як раніше. Реальний прогін із відсутнім
  журналом Range ID (існуючий шлях `Test-RangeIdUsage` лише з
  `WARNING` — незмінний) обчислив код виходу 10
  (`SuccessWithWarnings`), але журнал/консоль/сповіщення казали
  `УСПІШНО` без жодної згадки про попередження; тепер вони кажуть
  `УСПІШНО З
  ПОПЕРЕДЖЕННЯМИ` (консоль раніше казала `ЧАСТКОВО` для цього ж
  стану). `ПОМИЛКА` (будь-який з 40/41/60 або будь-який інший код
  не-успіху/не-попередження) і простий `УСПІШНО` незмінні.
- Сповіщення про попередження більше не поєднує іконку ✅ з "Дій не
  потрібно" — класифікація серйозності в `New-MaintenanceNotificationMessage`
  тепер перевіряє свій канонічний маркер `:warning:` раніше за збіг
  тексту `Title` з "УСПІШ" (раніше текстовий збіг завжди перемагав,
  тож `Title` з відтінком попередження та явним емодзі `:warning:`
  все одно класифікувався як SUCCESS). Відрендерене сповіщення для
  попереджень тепер показує `:warning: BRAVO MAINTENANCE — ПОТРІБНА ДІЯ` /
  "Потрібна дія: перевірити журнал BRAVO_MAINTENANCE." — наявне в
  репозиторії формулювання для серйозності "попередження" (ті самі два
  фіксовані рядки, які вже видає інша точка виклику з `:warning:`-емодзі,
  `Send-InactiveServiceWarning`), а не буквальний текст `Title`. Простий
  успіх не постраждав (як і раніше `:white_check_mark:` / "Дій не
  потрібно"); маршрутизація, `NotificationMode`, `allowed_mentions`,
  таймаут і механіка доставки незмінні.
- Голі роздільники `"==="` у runtime-журналі Maintenance — власна,
  окрема реалізація `Write-Log`/`Write-BRAVOMaintenanceLogFile`
  Maintenance, не спільна з фіксом Archive у dev.18 — більше не пишуть
  запис у журнал. Корінна причина: `Write-BRAVOMaintenanceLogFile
  -Entry ("=" * $SeparatorLength)` будував буквальний 100-символьний
  рядок `====...====` без жодної діагностичної цінності, завжди
  безпосередньо поруч зі справжнім викликом `"=== HEADING ==="`, який
  вже логує ту саму мить повним текстом. Застосовано уніфіковано до
  кожної точки виклику голого `"==="`, включно з банерами
  початку/кінця — той самий виклик, той самий аргумент `"==="`, без
  окремого шляху коду "лише для банера" в джерелі. Змістовні записи
  `=== HEADING ===` (ДЖЕРЕЛА ЖУРНАЛІВ, ПЕРЕВІРКА ВІЛЬНОГО МІСЦЯ,
  ЗУПИНКА СЛУЖБ, ПЕРЕВІРКА РОЗМІРІВ .MD ФАЙЛІВ, РЕСТАВРАЦІЯ МОДЕЛІ,
  ОБРОБКА TRACE-ФАЙЛІВ, ОБРОБКА ЛОГІВ EXCHANGAPI, ВІДНОВЛЕННЯ
  ПОЧАТКОВОГО СТАНУ СЛУЖБ, ОЧИСТКА СТАРИХ ДАНИХ, ВІДПРАВКА ПОВІДОМЛЕННЯ
  ПРО ПОДІЮ, і обидва банерні заголовки) цілком незмінні.
- Діагностичний журнальний рядок VSS в Archive ("Узгодженість архівів:
  ...") тепер фактично коректний. Раніше він казав "окремий
  VSS-знімок для кожного компонента", тоді як runtime завжди створював
  рівно один VSS Snapshot Set на генерацію (`New-BRAVOVSSSnapshotSet`),
  спільний для кожного увімкненого компонента (MODEL/BLOG/BRAVOEXCH) —
  ту саму термінологію вже використовує `BRAVO_DRY_RUN.ps1`. Це було
  позначено як відома, свідомо відкладена проблема в записі changelog
  для dev.18 вище; тут вона виправлена. Лише текст — створення/очищення
  VSS, `SnapshotContext`, `SnapshotSetId`, виявлення томів, час життя
  знімку та семантика генерації незмінні.
- Заголовок `=== СТВОРЕННЯ ХЕШУ <компонент> ===` в Archive тепер
  друкується безпосередньо перед першою дією генерації хешу
  (`New-SHA512Hash`), всередині самого `Invoke-BRAVOComponentBackup`,
  а не в `Main` після того, як увесь бекап компонента (створення +
  хеш + перевірка + публікація) вже завершився. Журнал реального
  прогону показував, що заголовок зʼявляється після роботи, яку він
  описує. Єдина точка виклику (`Invoke-BRAVOComponentBackup`, всередині
  циклу `foreach ($archive in $readyArchives)`) означає, що фікс
  застосовується уніфіковано до кожного увімкненого компонента без
  дублювання на компонент. Перенесення заголовка заразом виправляє й
  атрибуцію компонента журналу: `Resolve-BRAVOLogComponentFromHeader`/
  `Set-BRAVOLogComponent` тепер
  перемикають `$script:BRAVOLogComponent` на `HASH` до, а не після
  роботи з хешем. Обчислення SHA512, ім'я/кодування сайдкара,
  перевірка цілісності, публікація архіву, правила generation-COMPLETE
  та порядок передачі незмінні.
- Тести: 20 нових перевірок — `Maintenance/Exit0RendersSuccess` /
  `Exit10RendersSuccessWithWarnings` / `Exit40RendersFailure` /
  `Exit41RendersFailure` / `Exit60RendersFailure` (функціональні
  виклики реального, ізольованого `Get-BRAVOMaintenanceFinalStatus
  -ExitCode`, по одному на кожен код, який Maintenance фактично може
  видати); `Maintenance/FinalStatusConsumesResolvedExitCode` (AST-доказ,
  що тіло `Get-BRAVOMaintenanceFinalStatus` ніколи не звертається до
  `$script:criticalErrorOccurred`/`$script:BRAVOWarningCount`,
  `Get-BRAVOMaintenanceResolvedExitCode` дійсно викликає
  `Resolve-BRAVOExitCode`, а присвоєння LOG/console у джерелі
  відбуваються ПІСЛЯ єдиного присвоєння
  `$script:maintenanceRuntimeExitCode` — реальний потік даних, а не
  просто сусідній текст); `Maintenance/FinalStatusDoesNotCallIndependentWarningPolicy`
  (буквальний рядок `УСПІШНО З ПОПЕРЕДЖЕННЯМИ` існує в джерелі рівно
  один раз, а хелпер викликається рівно з трьох точок-споживачів);
  `Maintenance/WarningsNotificationUsesWarningMarkerNotSuccess` /
  `PureSuccessNotificationUnaffectedBySeverityReorder` (реальні,
  ізольовані виклики `New-MaintenanceNotificationMessage`, що
  підтверджують фікс узгодженості ✅/⚠️ + тексту операції/дії, і що він
  не змінює рендер простого успіху); `Maintenance/RangeIdMissingRemainsWarningOnly`
  (гілка відсутнього файлу в `Test-RangeIdUsage` незмінна: один
  `Test-Path`, жодного `New-Item`, рівень `WARNING`);
  `Maintenance/SectionSeparatorsDoNotEmitBareLogRecords` /
  `SectionHeadingsRemainLogged` / `RuntimeLogHasNoRedundantSeparatorOnlySections`
  (структурний доказ гілки голого роздільника плюс реальний
  функціональний прогін через власний `Write-Log` Maintenance у
  тимчасовий файл); `Archive/VssDiagnosticDescribesSingleGenerationSnapshotSet`
  / `VssDiagnosticDoesNotClaimPerComponentSnapshots` /
  `VssBehaviorCodeUnchangedByDiagnosticFix` (AST-доказ кількості
  викликів, що `New-BRAVOVSSSnapshotSet`/`Remove-BRAVOVSSSnapshotSet`
  незмінні); `Archive/HashHeadingPrecedesHashWork` /
  `HashHeadingPrecedesHashWorkForAllEnabledComponents` /
  `HashLogsUseHashComponentAfterHeading` /
  `HashBusinessCallsRemainUnchanged` (AST-доказ порядку джерела плюс
  реальний функціональний прогін, що підтверджує тег компонента HASH).
  Два наявні тести оновлено на місці: `Maintenance/FinalSummarySuccess`
  (dev.14, стверджував тепер уже витіснене формулювання
  `ЧАСТКОВО`/незалежний `elseif`) і `ConsoleUX/21-ExitCodeComputedBeforeRender`
  (dev.16, його якірний текст Maintenance відповідав старому вбудованому
  присвоєнню коду виходу); два тести порядку джерела
  (`Maintenance/FinalSummaryOccursBeforeManualPause`,
  `Maintenance/PostOperationsPrecedeFinalSummary`, обидва dev.15)
  автоматично підхопили той самий новий якір, оскільки повторно
  використовують спільну індексну змінну. Повний набір: 713/713.

## 5.0.0-dev.18 — 2026-08-10

Мінімальний реліз коректності операторського потоку/спостережуваності,
за результатами реального ручного прогону DEV-LIMS `BRAVO_ARCHIV`
5.0.0-dev.17. Три повʼязані дефекти, вузько обмежені — не змінено
семантику backup, VSS, retention-policy, MANIFESTS, transfer,
сповіщень, планувальника чи коду виходу. (Окрема, вже відома
фактологічна проблема формулювання VSS-діагностики — "Узгодженість
архівів: окремий VSS-знімок для кожного компонента", тоді як runtime
фактично використовує один Snapshot Set на генерацію — свідомо **не**
вирішується тут; вона буде опрацьована окремо.)

- Ручні операторські запуски Archive/Health/Maintenance більше не
  пропускають налаштовану паузу перед виходом лише тому, що stdin
  повідомляється як перенаправлений, коли доступна придатна
  інтерактивна консоль. Заголовок реального прогону коректно казав
  `MANUAL`, але вікно закривалося одразу після фінального RESULT
  замість очікування — `Wait-BRAVOManualExit` (`BRAVO.Console`,
  спільний для всіх трьох runtime) трактував
  `[Console]::IsInputRedirected` як незалежну, безумовну причину
  пропустити паузу, ще до того, як `$Host.UI.RawUI.ReadKey(...)`
  (який читає буфер введення консолі напряму і не залежить від
  перенаправлення stdin) взагалі отримував шанс виконатися. `-NoPause`
  залишається визначальним обходом паузи для планових/автоматизованих
  запусків (`BRAVO_TASKS_INSTALL.ps1` додає його до кожного
  запланованого завдання; дочірній запуск Maintenance→Archive та
  self-test обидва вже використовують його явно), а
  `consoleSettings.PauseOnExit = $false` залишається явним
  конфігураційним обходом — жодне з двох не змінилося. `RawUI.ReadKey`
  залишається основним, `Read-Host` залишається його резервним
  варіантом для ISE/неконсольного середовища.
- Очищення старих журналів Archive (`Очищення старих журналів`) і
  очищення генерацій резервних копій (`Очищення старих backup
  generation`) тепер беруть участь у тій самій динамічній
  пронумерованій послідовності `[N/M]`, що й будь-яка інша видима для
  оператора операція Archive, замість рендеру як непронумерованих
  рядків поза канонічною послідовністю. Очищення старих журналів
  завжди оцінюється і завжди займає один крок; очищення генерацій
  займає один крок лише коли справджується наявний вираз увімкнення
  (`enableArchiveDeletion -or enableFailedArchiveDeletion -or
  enableLunchArchiveCleanup` — незмінний), і жодного кроку, коли
  повністю вимкнено. Динамічний `Total` кроків і записи `План
  операцій:` вже керувалися тими самими прапорами й не потребували
  семантичних змін — лише сам виклик рендеру двох операцій очищення
  (`Write-BRAVOOperationResult` → `Write-BRAVOArchiveStep`). Порядок
  виконання незмінний — змінюється лише те, який рендерер використовує
  кожен виклик.
- Порожні структуровані записи runtime-журналу Archive, що
  використовувалися лише як візуальні роздільники секцій
  (`timestamp [INFO] [COMPONENT]` з порожнім Message — по одному на
  кожен перехід секції: STARTUP, CREDENTIALS, VSS, SFTP-ARCHIVE,
  PATHS, ARCHIVE, HASH, BAZA_APP, SUMMARY, ...), більше не видаються.
  Корінна причина: голий роздільник `"==="` (завжди безпосередньо
  поруч зі справжнім викликом `"=== HEADING ==="`, який вже логує ту
  саму мить і компонент повним текстом) будував свій журнальний рядок
  як `"=" * $SeparatorLength`, а типове значення `$SeparatorLength`
  розв'язувалося в порожній рядок у цьому шляху виклику. Замість того
  щоб далі переслідувати це розв'язання, гілка голого роздільника у
  `Write-Log`-обгортці Archive тепер просто взагалі не записує запис
  у журнал — сусідній заголовок вже несе інформацію про перехід
  секції, тож жодна діагностична цінність не втрачається. Змістовні
  записи `=== HEADING ===` (`=== ОПЦІЇ СКРИПТА ===`, `=== АРХІВАЦІЯ
  MODEL ===`, `=== ЗАВЕРШЕННЯ РОБОТИ СКРИПТА ===` тощо) цілком
  незмінні. Формат timestamp/рівня/компонента, шляхи файлів журналу,
  retention і консольні пороги не зачеплені; спільний `BRAVO.Logging`
  не модифікувався.
- Тести: ~19 нових/оновлених перевірок — `Console/ManualExit*`
  (функціональний обхід NoPause і PauseOnExit=false через реальні,
  неблокуючі виклики `Wait-BRAVOManualExit`; структурний доказ, що
  `IsInputRedirected` більше не є самостійною попередньою перевіркою,
  тоді як `UserInteractive` залишається такою; резервний варіант
  RawUI/Read-Host незмінний), `Archive/ManualModeAndPauseUseSameNoPauseContract`
  (Archive/Health/Maintenance усі делегують спільному хелперу, без
  дублювання `RawUI.ReadKey`), `Archive/*CleanupUsesNumberedStep*` /
  `DynamicTotalIncludesCleanupOperations` /
  `PlanAndCleanupStepsShareEnablementSemantics` /
  `CleanupNoWorkRendersSkipped` /
  `CleanupOperationsNoLongerUseUnnumberedRenderer`, і
  `Logging/RuntimeLogHasNoEmptyStructuredRecords` (реальний
  функціональний прогін через `Write-Log` Archive і `BRAVO.Logging` у
  тимчасовий файл, що стверджує відсутність фізичного рядка з порожнім
  Message), а також `Archive/SectionSeparatorsDoNotEmitEmptyLogEvents`
  / `SectionHeadingsRemainLogged`. Два наявні тести dev.16
  (`Archive/LogCleanupIsUnnumberedOperation`,
  `Archive/BackupRetentionCleanupAggregatesSubCleanup`) і один
  Console-тест dev.16 (`ConsoleUX/13-RedirectedNonInteractiveSkipsWait`)
  оновлено на місці, оскільки їхні твердження кодували саме тепер
  виправлену поведінку (непронумерований рендерер /
  IsInputRedirected-як-блокер). Повний набір: 693/693.

Нотатка: `BRAVO.Maintenance.Runtime.ps1` має власну, окрему копію того
самого патерну голого роздільника `"==="` (`Write-BRAVOMaintenanceLogFile
-Entry ("=" * $SeparatorLength)`), яка може мати той самий дефект. Її
свідомо залишено незачепленою тут — поза межами цього орієнтованого на
Archive релізу ("не змінювати бізнес-логіку Maintenance"); варта
окремого подальшого розгляду.

## 5.0.0-dev.17 — 2026-08-10

Мінімальний фікс коректності поверх dev.16, за результатами реального
acceptance-прогону DEV-LIMS (генерація `20260810_185725`, резервна
копія ~18:57 за місцевим часом сервера). Health підтвердив `OK` для
всіх компонентів і SFTP для цієї генерації — але успішне сповіщення
Discord показувало `🕒 Остання резервна копія: 10.08.2026 15:57` поруч
із коректним `⏳ Вік копії: 5 хв.`. Вибір генерації, обчислення віку
резервної копії та нормалізація UTC — усе було коректним; лише
людиночитний абсолютний timestamp був неправильним — він рендерив
внутрішньо нормалізоване значення UTC (`15:57`) так, ніби воно було
місцевим часом сервера (`18:57`).

- `Get-BRAVOHealthLatestBackupSummary` (`BRAVO.Health.Runtime.ps1`):
  `TimestampText` тепер конвертує UTC-timestamp у місцевий час
  (`.ToLocalTime()`) безпосередньо перед форматуванням — внутрішня
  модель, `AgeText` (як і раніше `Format-BackupAge`/`Get-BRAVOUtcAge`
  на сирому значенні UTC) і вибір генерації незмінні. Це єдина точка,
  з якої обидва конструктори сповіщень — успіху (`Остання резервна
  копія`) і проблеми (`Остання успішна резервна копія`) — читають
  `TimestampText`, тож обидва виправляються однією зміною — без
  дублювання логіки конвертації часового поясу.
- Семантика `createdAt`/`startedAt` маніфесту, `ConvertTo-BRAVOUtcDateTime`,
  вибір генерації резервної копії, `MaxBackupAgeHours`, retention,
  життєвий цикл MANIFESTS, формат архіву, VSS, SFTP/SMB, синхронізація
  BAZA, логіка PASS/WARN/FAIL Health, маршрутизація/режим сповіщень і
  коди виходу — усе незмінне.
- Тести: `Health/LatestBackupTimestampRendersLocalTime` (функціональний
  — відтворює точні цифри DEV-LIMS через `[datetime]::SpecifyKind`,
  незалежний від часового поясу, без жорстко закодованого UTC+3),
  `Health/BackupAgeStillUsesUtcSemantics` (підтверджує, що `AgeText`
  не постраждав), `Health/SuccessAndProblemNotificationsReuseLatestBackupTimestamp`
  (підтверджує, що обидва конструктори сповіщень поділяють одну точку
  конвертації).
  Повний набір: 679/679.

## 5.0.0-dev.16 — 2026-08-10

Мінімальний фікс надійності PowerShell 5.1 / `Set-StrictMode` поверх
опублікованого dev.15: без зміни операторської консолі/UX, без зміни
політики MANIFESTS/retention/бізнес-семантики.

Реальний acceptance dev.15 на DEV-LIMS підтвердив `[1/8]`..`[8/8]`,
рядок `[5/8]` Restore `SKIPPED`, одноразовий рендер `[8/8]` Range ID
і друк фінального підсумку перед ручною паузою — усе як задумано. Але
після `[8/8]` очищення викинуло `The property 'Count' cannot be found
on this object. Verify that the property exists.` Fail-safe catch з
dev.15 (блок фіналізації, введений у dev.15) коректно перетворив це
на критичний прогін (exit 60) і все одно надрукував фінальний підсумок
— саме та поведінка, для якої він був побудований — але сам базовий
виняток тепер виправлено в корені.

- `Remove-OldRestoreArchives`: два конвеєри `Where-Object`, які можуть
  легітимно повернути рівно один збіг (`$beforeCount`/`$afterCount` —
  кількість архівів до/після для збереженої сесії restore), тепер
  матеріалізують свій результат як масив через `@(...)` перед `.Count`.
  Під PowerShell 5.1 з активним `Set-StrictMode` (успадкованим від
  завантажувача конфігурації, за наявною конвенцією проєкту — див.
  прецедент `PropertyNotFoundStrict`, вже виправлений для
  `$missingDirs` у тому самому файлі) конвеєр з одним результатом
  повертає скалярний обʼєкт замість колекції, і `.Count` на цьому
  скалярі викидає саме спостережену помилку. Той самий фікс застосовано
  до `$remainingFiles` (діагностичний список "що залишилося" після
  видалення), який мав ідентичну форму `Get-ChildItem` +
  незагорнутий `.Count`.
- Обсяг: перевірено лише `Remove-OldRestoreArchives`, і лише ці дві
  точки виклику потребували фіксу — кожен інший `.Count` у цій функції
  вже був загорнутий у масив при присвоєнні (`$mainArchiveFiles`,
  `$sortedGroups`, `$groupsToKeep`, `$groupsToDelete`,
  `$staleInvalidGroups`), а `$group.Count` (`GroupInfo.Count` від
  `Group-Object`) — це реальна, завжди безпечна властивість, залишена
  незачепленою. Без наскрізної перевірки по всьому репозиторію.
- Fail-safe фіналізація з dev.15 (зовнішній `try/catch` навколо
  Range ID / очищення / `BRAVO_ARCHIV` / auto-shutdown / фінального
  звіту, непорожні тіла swallow-catch) незмінна — вона вже коректно
  виконала свою роботу для цього конкретного реального винятку й
  залишається запобіжником для будь-якого майбутнього.
- Тести: 4 нові ізольовані регресійні перевірки для
  `Remove-OldRestoreArchives` (реальна функція через AST-екстракцію,
  синтетичні TEMP-директорії — ніколи продакшн-шляхи DEV-LIMS —
  виконувані під реальним `Set-StrictMode
  -Version Latest` всередині виклику, що відтворюють точну умову
  збою, а не симулюють її): одноелементний підрахунок `before`/`after`
  зчитується назад як `1` без винятку, один залишений файл після
  видалення не викидає виняток, а весь виклик завершується коректно під
  strict mode з результатом конвеєра з одного елемента.

**Прохід підвищення операторської видимості** (все ще dev.16,
неопубліковано): закриває прогалину, де чотири верхньорівневі операції
`BRAVO_MAINTENANCE.ps1`, які насправді виконуються кожного разу, не
мали жодного результату виконання в консолі — лише в LOG. Затверджений
контракт `[1/8]`..`[8/8]`, `Initialize-BRAVOMaintenanceSteps -Total 8`
(буквально), MANIFESTS і семантика retention — усе незмінне; жодна з
чотирьох не отримує номер `[N/8]` і не торкається лічильників кроків.

- `Write-BRAVOOperationResult` (нова, `BRAVO.Console`): той самий
  контракт вирівнювання/статусу/тривалості/деталей, що й рендерер
  пронумерованих кроків, мінус префікс `[N/TOTAL]` (натомість відступ
  6 пробілів) і без торкання лічильників кроків — для верхньорівневих
  операцій, які реальні, але свідомо поза пронумерованим контрактом.
- Міграція застарілих журналів, очищення старих даних, запуск
  `BRAVO_ARCHIV.ps1` та планування auto-shutdown тепер кожен друкує
  рядок результату `SKIPPED`/`OK`/`WARN`/`FAIL` (з короткою причиною
  `-Details` у разі попередження/збою) у своїй наявній позиції
  виконання — міграція продовжує виконуватися між створенням
  директорій та зупинкою служб, очищення/архів/shutdown продовжують
  виконуватись після `[8/8]`. `Invoke-AutoShutdown` тепер повертає
  символічний фінальний стан — `Scheduled`/`Cancelled`/`Failed` —
  замість простого булевого значення, тож консольний рядок відображає
  те, що фактично сталося (включно з тим, коли оператор інтерактивно
  скасовує вже заплановане вимкнення), а не лише "команду було
  видано." Інтерактивний діалог підтвердження/скасування та сама
  команда вимкнення незмінні.
- `План операцій:` отримав `Очистка старих даних/логів` (завжди
  `ТАК` — перевірка виконується безумовно при кожному запуску, для
  неї немає прапора увімкнення/вимкнення; прогін без застарілих даних
  все одно рендерить `SKIPPED` на самій операції).
- Точна атрибуція збою: `$script:currentMaintenanceOperation`
  встановлюється перед Range ID / очищенням / архівом / auto-shutdown
  / фінальним звітом, тож fail-safe catch з dev.15 тепер логує
  "Помилка операції ...<назва операції>..." замість загального списку
  "Range ID/очистка/BRAVO_ARCHIV/AutoShutdown/фінальний звіт". Якщо
  виняток стався всередині операції, яка має власний рядок результату
  і цей рядок так і не надрукувався, catch друкує її `FAIL` рівно один
  раз (прапор `*Reported` на кожну операцію запобігає подвійному
  друку).
- Шлях відновлення `RunMissedRestoreOnly` без жодного очікуваного
  завдання більше не завершується голим `exit 0` без жодного
  підсумку: тепер він спершу друкує компактний підсумок `BRAVO
  MAINTENANCE — УСПІШНО` / `Код завершення` / `Результат` / `Журнал`
  (все ще без `[1/8]`..`[8/8]` — реальної роботи цього прогону немає)
  перед тим самим зовнішнім `finally` → `Wait-BRAVOManualExit`, що й
  усі інші шляхи виходу.
- Тести: 21 нова перевірка (монтаж/порядок плану, непронумерований
  рендер кожної операції та гілки SKIPPED/OK/WARN/FAIL, ізоляція
  тотал/лічильника кроків, порядок рендеру після `[8/8]` і перед
  фінальним підсумком, точна атрибуція збою, одноразовий друк при
  збої та підсумок no-op відновлення) — усі через перевірку
  джерела/AST або прямі виклики реального, без побічних ефектів
  `Write-BRAVOOperationResult`, ніколи запуском реального `Main()`
  чи реального `Invoke-AutoShutdown` (який би видав справжню команду
  `shutdown`). Два наявні тести dev.15
  (`Maintenance/FinalSummaryOccursBeforeManualPause`,
  `Maintenance/FinalSummaryContainsOnlyApprovedFields`) мали свій
  пошук джерела обмежений початком після маркера зовнішнього try,
  оскільки `Write-BRAVOFinalSummaryHeader`/`Footer` тепер також
  з'являються один раз, раніше, у новому підсумку шляху відновлення —
  обидва досі проходять незмінно.

**Прохід підвищення операторської видимості Archive/Health** (все ще
dev.16, неопубліковано): розширює той самий контракт пронумерованих
кроків/непронумерованих операцій на `BRAVO_ARCHIV.ps1` і
`BRAVO_HEALTH.ps1`, щоб реальні верхньорівневі операції та перевірки
перестали бути лише в LOG. Формат backup, період retention, життєвий
цикл MANIFESTS, протокол SFTP/SMB, маршрутизація сповіщень і семантика
коду виходу не змінюються.

- `Write-BRAVOPlan` (нова, `BRAVO.Console`): спільний рендерер `План
  операцій:`/`План перевірок:` для Archive і Health, що відповідає
  макету/стилю плану Maintenance (сам Maintenance зберігає власний
  наявний рендер, незачепленим) — обидва тепер рендерять через нього
  замість власного сирого `Write-Host` — у Health такого взагалі немає
  (`Console/HealthRendersNoRawWriteHost`).
- Archive: `План операцій:` тепер відображає ті самі ефективні
  прапори, що керують динамічним `Total` кроків (локальна синхронізація
  BAZA_APP/BAZA_WWW, компоненти на архів, передачі SFTP/SMB, очищення
  журналів/retention, post-backup Health). Локальна синхронізація
  BAZA_APP/BAZA_WWW кожна отримує власний пронумерований крок, коли
  увімкнена. `Перевірка шляхів` тепер рендериться строго після
  завершення і перевірок існування шляхів, і преперевірки доступу
  запис/читання SYSTEM — раніше вона рендерила `OK` одразу після
  перевірок існування, до того як преперевірка все ще могла скасувати
  прогін. Очищення старих журналів (`Remove-OldLogsByAge`) і очищення
  retention генерацій резервних копій (`Remove-BRAVOExpiredBackupGenerations`
  + `Remove-OldLunchArchives`, агреговані в одну операцію, а не один
  рядок на внутрішній фільтр) тепер обидва друкують рядки
  `Write-BRAVOOperationResult`; retention рендерить `OK` з фактичним
  агрегованим лічильником видалень лише коли щось справді було
  видалено, інакше `SKIPPED` — без вигаданих лічильників. `-SyncBAZA`
  (окремий, лише-SFTP потік ручної синхронізації) підтверджено
  ізольованим: його власні `Initialize-BRAVOArchiveSteps`/кроки
  виконуються і роблять `return` до нового шляху коду Plan/Total.
- Health: окремі (standalone) запуски (не вбудовані в Archive) тепер
  показують `План перевірок:` перед першою перевіркою. Комбіновані
  кроки `BAZA (локальна копія)` і `SFTP` розділені на незалежні
  динамічні кроки — `BAZA_APP (локальна копія)`/`BAZA_WWW (локальна
  копія)` і `SFTP: резервні копії`/`SFTP: BAZA_APP`/`SFTP: BAZA_WWW` —
  кожен гейтується власним прапором увімкнення і рахується в `Total`
  рівно один раз; `Get-SFTPHealthIssues` як і раніше виконує одну
  сесію WinSCP на виклик, її вже повернений список проблем
  партиціонується за наявним полем `Component`, а спільний збій
  передумови зʼєднання приєднується до кожного увімкненого кроку SFTP
  (логується один раз, а не на кожен крок). `Керовані служби`/
  `Локальні резервні копії` залишаються одиночними кроками, але
  отримують компактний рядок деталей `служби: ...`/`компоненти: ...`,
  побудований з наявних полів `Location`/`Component` проблем.
  Динамічний `Total` тепер буквальна сума прапорів, що гейтують рендер
  кожного кроку (`Health/StepTotalMatchesVisibleEnabledChecks`);
  інваріант off-by-one сповіщення `Complete-BRAVOHealthResult`,
  вбудований шлях (`-SuppressHeader`) і
  `$script:BRAVOHealthSftpStepEnabled` (все ще споживаний футером
  окремого підсумку) — усе незмінне.
- Виправлено реальний баг, внесений під час додавання лічильників
  видалень retention-очищення: параметри типу `[ref]` у PowerShell
  назавжди обмежують тип змінної для решти функції, тож однойменний
  (без урахування регістру) локальний лічильник мовчки повторно
  загортається у новий `PSReference` при кожному присвоєнні замість
  того, щоб залишатися простим `int`. Наявний `$deletedCount` у
  `Remove-OldLunchArchives` зіткнувся з першим чернетковим варіантом
  нового вихідного параметра `[ref]$DeletedCount`, через що
  `$deletedCount += 2` викидав би виняток, і кожне реальне, успішне
  видалення lunch-архіву реєструвалося б як перехоплений збій.
  Перейменовано обидва нові вихідні параметри
  (`RemovedGenerationCount`/`RemovedFileCount`), щоб уникнути будь-якого
  зіткнення без урахування регістру; перевірено ізольованим репро до
  і після.
- Maintenance: перейменовано змінну на рівні `Main`, яка дублювала
  власну локальну `$groupsToDelete` функції `Remove-OldRestoreArchives`
  під іншим, непов'язаним обчисленням (лише кількість кандидатів для
  консольного `Details`, а не рішення retention функції з урахуванням
  валідності) на `$restoreArchiveDeleteCandidateGroups`, щоб усунути
  заплутаний патерн однакового імені/різного скоупу.
  `Invoke-AutoShutdown` підтверджено має рівно одну продакшн-точку
  виклику (підраховано через AST).
- Тести: ~30 нових перевірок у Archive, Health і Maintenance (план
  відображає ефективні компоненти, незалежні кроки BAZA local/SFTP,
  порядок кроку шляхів, очищення журналів/retention SKIPPED-проти-OK,
  ізоляція `-SyncBAZA`, вбудований Health залишається одним кроком,
  точний збіг динамічного Total Health, вбудований Health пригнічує
  Plan/підсумок, рендер Scheduled/Cancelled/Failed AutoShutdown і
  єдина точка виклику, ізоляція обсягу очищення). Повний набір:
  674/674.

## 5.0.0-dev.15 — 2026-08-10

Стабілізує контракт кроків операторської консолі `BRAVO_MAINTENANCE.ps1`,
введений у dev.14, і робить фіналізацію в кінці прогону стійкою до
пізнього винятку. Без зміни вмісту архіву, 7-Zip, SHA512, VSS, шляхів
SFTP/SMB, облікових даних, маршрутизації сповіщень, порогів Health,
логіки віку резервної копії чи формули коду виходу.

- **Стабільний контракт із 8 кроків.** `Initialize-BRAVOMaintenanceSteps`
  тепер приймає буквальний `-Total 8`, ніколи обчислений вираз.
  Затверджений операторський контракт — саме `[1/8]` Перевірка
  вільного місця, `[2/8]` Створення необхідних директорій, `[3/8]`
  Зупинка служб, `[4/8]` Перевірка розмірів `.md`, `[5/8]` Реставрація
  моделі, `[6/8]` Обробка trace і логів, `[7/8]` Відновлення стану
  служб, `[8/8]` Контроль діапазонів ID — усі вісім завжди рендеряться
  в цьому фіксованому порядку на кожному прогоні; вимкнений/
  незапланований крок рендерить `SKIPPED` на своєму власному
  постійному номері замість зсуву нумерації наступних кроків.
- Міграція застарілої структури журналів, очищення старих даних і
  запуск `BRAVO_ARCHIV.ps1` підтверджено непронумеровані: кожен
  залишається операцією лише-в-детальному-LOG / видимою в Плані
  операцій і більше не викликає `Write-BRAVOMaintenanceStep`, тож
  ніколи не може роздути кількість кроків понад 8.
- Виправлено дефект порядку, коли за відсутності запланованої на цей
  прогін реставрації (типовий щоденний випадок) `[6/8]` Обробка trace
  і логів рендерився *перед* рядком `[5/8]` Реставрація моделі
  `SKIPPED`, міняючи місцями два номери відносно затвердженого
  контракту. Тепер запасний варіант реставрації завжди рендериться
  першим, незалежно від сценарію.
- **Fail-safe фіналізація в кінці прогону.** Блок Range ID / очищення /
  `BRAVO_ARCHIV` / auto-shutdown / фінального звіту тепер виконується
  всередині `try/catch`: будь-який необроблений виняток там
  перехоплюється, все одно позначає прогін критичним, і виконання все
  одно доходить до обчислення коду виходу та фінального підсумку
  `BRAVO MAINTENANCE — <СТАТУС>`, замість того щоб стрибнути прямо
  повз нього до `Wait-BRAVOManualExit` без жодного друкованого
  підсумку взагалі. Всередині catch `criticalErrorOccurred`
  встановлюється безумовно першим, а виклики діагностичного
  логування/сповіщень кожен загорнутий у власний ізольований,
  такий, що не перекидає виняток далі, `try/catch` (кожне тіло catch
  явно відкидає перехоплену помилку через `$null = $_` — жодного
  `Write-Log`/`Send-SlackAlert`/`throw`/`exit`/`return` всередині),
  тож збій запису журналу чи надсилання сповіщення Slack не може сам
  проковтнути підсумок.
- `Write-Log` отримав опційний перемикач `-NoConsole` (файл журналу
  та сповіщення не постраждали; поведінка жодної наявної точки
  виклику не змінюється). `Test-RangeIdUsage` використовує його для
  трьох попереджень, які вже показуються оператору через `-Details`
  кроку `[8/8]`, тож відсутній/нечитаний/понад-порогом
  `range_id_log.json` більше не друкується двічі. Відсутній файл
  тепер звітує деталь у два рядки (мітка, потім шлях) замість одного
  довгого рядка.
- Блок `План операцій:` тепер закривається тим самим роздільником `=`
  (`Write-BRAVOHeaderSeparator`, новий у `BRAVO.Console`), що обрамляє
  заголовок прогону, замість роздільника `-`, який використовував
  непов'язаний стиль блоку `РЕЗУЛЬТАТ`.
- Тести: 15 нових регресійних перевірок, що покривають фіксований
  тотал 8 кроків (на рівні AST, відхиляє динамічний `-Total`),
  рендер `SKIPPED` кожного вимкненого кроку, порядок кроків
  Restore/Logs, шлях fail-safe catch (включно з симульованим збоєм
  логування/сповіщення всередині нього), поведінку одноразового
  консольного рендеру та багаторядкової деталі Range ID, і стиль
  роздільника плану — усі через ізольовану екстракцію джерела/AST,
  ніколи запуском реального `Main()` у `BRAVO_MAINTENANCE.ps1`.

## 5.0.0-dev.14 — 2026-08-09

Мінімальна структурно-метаданева зміна поверх dev.13: маніфести генерацій
резервного копіювання (`BRAVO_BACKUP_<GenerationId>.json`) тепер зберігаються
у виділеному місці `<BackupRoot>\MANIFESTS\`, окремо від операційних логів
(`LOGS\`) та тимчасових runtime-даних (`TEMP\`). Жодних змін у вмісті архіву,
7-Zip, SHA512, VSS, SFTP/SMB, облікових даних, сповіщень, порогах
Health, логіці віку резервних копій, семантиці кодів завершення чи
контракті підвищення прав dev.13.

- `modules\BRAVO.ArchiveHelpers`: три нові централізовані хелпери —
  `Get-BRAVOBackupManifestRoot` (єдине джерело істини для фізичного шляху,
  `<BackupRoot>\MANIFESTS`), `Get-BRAVOBackupGenerationManifestFiles`
  (читач із пріоритетом MANIFESTS та нерекурсивним фолбеком на legacy-корінь,
  дедуплікація за GenerationId з пріоритетом MANIFESTS), та
  `Initialize-BRAVOBackupManifestStorage` (ідемпотентна, нерекурсивна
  міграція legacy-маніфестів кореня у `MANIFESTS\`: ідентичні файли
  дедуплікуються за SHA256, конфліктуючі файли ніколи не перезаписуються і
  не видаляються — обидва зберігаються, а WARNING називає GenerationId).
- `Write-BRAVOBackupGenerationManifest` (`BRAVO.Archive.Runtime.ps1`) тепер
  записує нові маніфести напряму в `MANIFESTS\`, створюючи каталог при
  першому використанні.
- `Remove-BRAVOExpiredBackupGenerations` (ретеншн), `Get-BackupHealthIssues`
  (`BRAVO_HEALTH.ps1`) та `Get-BRAVORestoreGenerationManifest`
  (`BRAVO_RESTORE_TEST.ps1`) тепер усі виявляють маніфести через
  централізований читач замість незалежного дублювання того самого виклику
  `Get-BRAVOFiles -Filter 'BRAVO_BACKUP_*.json'`. `BRAVO_HEALTH.ps1`
  залишається строго read-only — він ніколи не мігрує й не пише.
- `BRAVO_MAINTENANCE.ps1` виконує міграцію один раз за виклик, під тим самим
  operation lock, що й наявна міграція legacy-структури логів, і ніколи не
  валить запуск: помилка чи конфлікт міграції логуються лише як WARNING.
- `Get-BRAVOBackupGenerationManifestPhysicalFiles` (новий): ретеншн тепер
  видаляє *кожну* фізичну копію маніфесту генерації (`MANIFESTS\`,
  і, якщо ще не мігровано, legacy-корінь `BackupRoot`) коли ця генерація
  прострочена, замість лише однієї копії, яку читач з пріоритетом MANIFESTS
  обрав для рішення про видалення. Раніше конфліктуючий legacy-дублікат міг
  пережити видалення генерації й "воскресити" її метадані на наступному
  запуску через legacy-фолбек читача. Новий хелпер визначає кандидатів за
  збігом імені файлу серед реальних, вже перелічених файлів — він ніколи не
  будує шлях файлової системи з недовіреного рядка `generationId`,
  зчитаного з JSON маніфесту, тож сфабрикований `generationId` не може
  бути використаний для path traversal.
- `BRAVO_MAINTENANCE.ps1` UX консолі оператора: приймає той самий
  контракт кроку `[N/TOTAL] Назва... STATUS mm:ss`, що й Archive/Health, зі
  специфічним для Maintenance словником `OK`/`WARN`/`FAIL`/`SKIPPED`
  (перейменовано з `OK`/`WARNING`/`ERROR`/`SKIPPED`, лише консольне
  відображення — рівні логів і семантика кодів завершення не змінюються).
  Ініціалізація/міграція MANIFESTS тепер згорнута в деталь наявного кроку
  "Створення необхідних директорій" замість окремого рядка, тож steady-state
  запуск не показує нічого нового. "Контроль діапазонів ID" вперше отримує
  власний крок (раніше виконувався мовчки, лише лог/Slack); відсутній або
  нечитабельний `range_id_log.json` показується як `WARN` на консолі —
  наявна поведінка `Send-SlackAlert -IsCritical`/коду завершення для цього
  стану не змінюється. Рядок попереднього перегляду плану для кроку
  відновлення перейменовано на "Реставрація моделі" відповідно до фактичної
  назви кроку (раніше "Відновлення пропущених операцій", той самий базовий
  прапорець), і додано рядок "Контроль діапазонів ID", щоб план не міг
  розходитися з тим, що фактично виконується. Фінальний блок `РЕЗУЛЬТАТ`
  отримує Початок/Завершення та розбивку Кроків/Успішно/Попереджень/
  Пропущено/Помилок, дзеркалячи наявні лічильники підсумку
  `BRAVO_HEALTH.ps1`.
- Регресійні тести: 18 перевірок `ManifestStorage/*`, що покривають
  резолюцію кореня, розміщення при записі, пріоритет/фолбек/нерекурсивність
  читача та міграцію; ще 2 (`RetentionDeletesBothPhysicalManifestCopies`,
  `DeletedGenerationCannotReappearViaLegacyFallback`), що покривають фікс
  очищення ретеншну; 23 нові перевірки `Maintenance/*`, що покривають
  заголовок, зв'язування плану, формат/словник/тривалість кроку, згорнутий
  крок каталогу/MANIFESTS, крок Range ID та фінальний підсумок — усі через
  ізольовану екстракцію функцій або статичні перевірки джерела, ніколи через
  запуск реального `BRAVO_MAINTENANCE.ps1` `Main()`.
- Документація: README.md §2/§12 та OPERATIONS.md документують поділ
  сховища на три частини та поведінку оновлення/міграції, яку оператори
  побачать у журналі Maintenance.

Виправлення коректності/UX (раунд 3):
- `Get-BRAVOBackupManifestFilenameGenerationId` (новий): ретеншн тепер
  вимагає, щоб generationId, закодований у фізичному імені файлу маніфесту,
  збігався з generationId усередині його JSON-вмісту, перш ніж довіряти
  цьому маніфесту для будь-якого рішення про видалення. Невідповідність
  (пошкодження чи підробка) повністю виключає запис з ретеншну — вона більше
  не може спричинити видалення власних артефактів або, через фікс
  фізичного очищення раунду 2, метаданих сторонньої генерації, яку випадково
  назвав JSON.
- `Get-BRAVOMaintenanceExecutionMode` (новий, чистий: приймає лише SID):
  режим MANUAL/SCHEDULED заголовка Maintenance більше не залежить від
  `-NoPause` (перемикача лише для UX, який оператор може передати вручну).
  Тепер він відображає фактичного викликача: SYSTEM (S-1-5-18) — це
  SCHEDULED, будь-хто інший — MANUAL.
- Попередній перегляд плану: відновлено `Відновлення пропущених операцій`
  (стан механізму відновлення пропущених операцій: `-RunMissedRestoreOnly`
  та фактична пропущена робота) як окремий рядок, відмінний від
  `Реставрація моделі` (чи справді запуститься крок відновлення моделі цим
  викликом). Ці два були об'єднані в один рядок; рядок Range ID видалено з
  плану (сам крок не постраждав).
- Range ID: відсутній/нечитабельний `range_id_log.json` більше не робить
  увесь запуск Maintenance `MaintenanceFailed`. `Send-SlackAlert
  -IsCritical` усе ще спрацьовує (доставка сповіщень у режимі
  `errors_only` не змінюється); лише побічний ефект
  `criticalErrorOccurred` для цього конкретного виклику скасовано, і лише
  коли ніщо інше його вже не встановило.
- Виправлено мапінг статусу кроку міграції: конфлікт або помилка міграції
  маніфестів тепер мапиться на `WARN` (відповідно до неаварійного/
  повторюваного контракту з раунду 1), а не на `FAIL`. `FAIL`
  зарезервовано для реальної помилки створення каталогу.
- Деталі кроку (`Write-BRAVOMaintenanceStep`) більше не додають префікс
  "Причина:" до тексту WARN/FAIL -- кожен статус (OK/WARN/FAIL/SKIPPED)
  тепер рендериться через той самий простий, з відступом 6 пробілів,
  `Write-BRAVOConsoleDetail`.
- `Write-BRAVOFinalSummaryHeader` (новий, `BRAVO.Console`): фінальний
  підсумок Maintenance тепер відкривається з "BRAVO MAINTENANCE — <СТАТУС>"
  у тому самому стилі роздільника `=`, що й власний заголовок запуску,
  замість загального блоку " РЕЗУЛЬТАТ". Archive/Health/інші викликачі
  продовжують незмінно використовувати `Write-BRAVOResultHeader`. Поле
  "Попереджень" підсумку звітується рівно один раз (лічильник на рівні
  кроків, відповідно до наявної конвенції лічильника Health), не
  дублюючись проти окремого глобального лічильника попереджень.
- Ще 26 регресійних тестів: режим виконання (3), семантика плану (1),
  розв'язання серйозності Range ID (3), ідентичність імені файлу/JSON
  ретеншну (3), і 7 перевірок "точного рендерингу"
  (заголовок/план/крок/попередження-Range-ID/підсумок x3), що засвідчують
  фактичний рендерений макет -- роздільники, вирівнювання міток, словник
  статусів, відсутність "Причина:", відсутність дубльованого "Попереджень"
  -- а не лише наявність тексту в джерелі.

Фінальне шліфування (раунд 4):
- `Write-BRAVOFinalSummaryFooter` (новий, `BRAVO.Console`, парний з
  `Write-BRAVOFinalSummaryHeader`): підсумок Maintenance тепер закривається
  "Журнал:" + шлях до логу на власному рядку + закриваючий роздільник
  `=`, у стилі заголовка запуску, замість "Детальний журнал:" +
  роздільника `-` від `Write-BRAVOResultFooter`. Archive/Health
  продовжують незмінно використовувати `Write-BRAVOResultFooter`.
- Згорнутий крок "Створення необхідних директорій" (створення каталогу +
  ініціалізація/міграція MANIFESTS) тепер рендерить кілька деталей як окремі
  рядки з відступом 6 пробілів, а не об'єднані через `; `.
- Ще 1 регресійний тест
  (`Maintenance/DirectoryDetailsRenderAsSeparateLines`); три тести
  рендерингу підсумку тепер також засвідчують макет футера (`Журнал:`
  рівно один раз, шлях до логу на наступному рядку, закриваючий роздільник,
  відсутність `Детальний журнал:`/роздільника `-`).

Обрізання компактного підсумку (раунд 5):
- Поля `Maintenance`/`Архівація`/`Shutdown` більше не друкуються у
  фінальному компактному підсумку для оператора -- вони не входили до
  затвердженого набору полів (Статус/Код завершення/Початок/Завершення/
  Тривалість/Кроків/Успішно/Попереджень/Пропущено/Помилок/Журнал) і
  дублювали те, що блок "План операцій" уже показує на початку запуску.
- Ще 1 регресійний тест
  (`Maintenance/FinalSummaryContainsOnlyApprovedFields`) читає реальний
  блок джерела фінального підсумку в `BRAVO.Maintenance.Runtime.ps1` і
  засвідчує, що він містить точно затверджені поля, і жодного з видалених
  чи старого контракту `Write-BRAVOResultFooter`/"Детальний журнал"/
  " РЕЗУЛЬТАТ".

## 5.0.0-dev.13 — 2026-08-09

Мінімальний фікс надійності поверх UX-фіксів dev.12: ручні запуски
`BRAVO_HEALTH.ps1` без прав адміністратора більше не подають помилку
локальних прав доступу як збій SFTP.

- `BRAVO_HEALTH.ps1` тепер визначає стан підвищення прав
  (Administrator/SYSTEM/Standard) перед будь-якою роботою. Ручний
  інтерактивний запуск без підвищення прав самостійно перезапускається
  через `Start-Process -Verb RunAs` (UAC), передаючи реальні
  `$PSBoundParameters` (ConfigPath, NoPause, NotifyOnSuccess, NoSlack,
  ForceNotification, SkipIfBackupTaskRunning) як детерміновано побудований,
  коректно екранований список аргументів, після чого завершується з кодом
  завершення підвищеного дочірнього процесу. SYSTEM (заплановане завдання)
  та вже підвищена консоль не постраждали — жодного перезапуску, жодного
  UAC, поведінка така сама, як у dev.12. Скасований запит UAC друкує чітке
  повідомлення замість сирого stack trace.
- Виявлення неінтерактивності більше не покладається лише на
  `[Environment]::UserInteractive`/`[Console]::IsInputRedirected`
  (жоден з них фактично не доводить, що PowerShell отримав
  `-NonInteractive`). Точка входу тепер додатково читає власний argv
  процесу через вбудований API .NET Framework
  `[Environment]::GetCommandLineArgs()` — уже розпарсений, сумісний з
  Windows PowerShell 5.1 і, що важливо, зовсім не має залежності від
  CIM/WMI — і виконує точний (не підрядковий/`-like`) збіг для окремого
  елемента `-NonInteractive`, тож не дає хибний збіг з текстом усередині
  значення `-ConfigPath` чи шляху до файлу. Явний `-NonInteractive`
  перекриває сесію, що інакше виглядала б інтерактивною, і швидко завершує
  роботу (exit 36), ніколи не намагаючись викликати UAC.
- `BRAVO.Health.Runtime.ps1` тепер перевіряє доступ на запис до кореневих
  каталогів runtime LOGS і TEMP перед будь-якою реальною перевіркою здоров'я
  (сервіси/локальні резервні копії/SFTP/SMB). Раніше локальний
  `AccessDenied` на цих шляхах виринав аж глибоко всередині створення
  тимчасового каталогу етапу SFTP і хибно класифікувався як
  `ERROR SFTP` / `SftpVerified=False`. При збої preflight жодна реальна
  перевірка не запускається, і оператор бачить чесне повідомлення про
  середовище/права доступу (ніколи "SFTP недоступний"), надіслане як
  сповіщення, якщо налаштовано. Збій класифікується: лише
  `UnauthorizedAccessException` (будь-де в ланцюжку винятків) вважається
  проблемою прав доступу; інші I/O-збої (переповнений диск, `PathTooLong`,
  пошкоджена файлова система, ...) звітуються як загальна проблема
  середовища і не радять оператору запускати від імені адміністратора. Це
  діє навіть коли каталог runtime TEMP ще не існує: типізований виняток від
  невдалого створення каталогу тепер зберігається наскрізно (як
  `InnerException`) замість того, щоб бути сплющеним у звичайний текст
  перед класифікацією.
- Нові коди завершення в `modules\BRAVO.ExitCodes`, задокументовані в
  таблицях кодів завершення README.md: `36 = PrivilegeRequired` для
  випадку з правами доступу вище (також використовується шляхами
  скасування-UAC/швидкого-завершення-при-неінтерактивності точки входу), і
  `37 = EnvironmentUnavailable` для випадку середовища/I/O без прав
  доступу. `70 = HealthCritical` зберігає своє наявне значення — реальний
  збій перевірки здоров'я, який справді відбувся.
- Якщо сам лог перевірки здоров'я не вдалося створити/записати,
  сповіщення про середовище та консольний підсумок більше не стверджують
  про шлях до логу, якого не існує.
- `Write-HealthLog` більше не заповнює консоль тим самим попередженням
  "не вдалося записати health-check лог" на кожному з десятків викликів у
  запуску, коли файл логу став незаписним — тепер попереджає один раз і
  припиняє повторні спроби запису до кінця цього запуску.
- ACL кореня runtime ніде не послаблюється цією зміною — фікс полягає в
  підвищенні прав за потреби, а не в ширшому доступі на запис для звичайних
  користувачів.
- `BRAVO_ARCHIV.ps1`/`BRAVO_MAINTENANCE.ps1` вже мали власне, простіше
  самопідвищення прав SYSTEM/Administrator (що існувало до цієї зміни) і не
  були тут зачеплені. На відміну від нового шлюзу Health, жоден з них не
  розрізняє інтерактивність від неінтерактивності перед спробою
  `-Verb RunAs`, і Maintenance не має спеціальної обробки скасованого
  запиту UAC — відзначено як можливий подальший крок, тут не виправлено.

## 5.0.0-dev.12 — 2026-08-09

Мінімальний UX-фікс поверх уніфікації сповіщень оператора з dev.11.

- Рядки статусу компонента/призначення (BLOG/BRAVOEXCH/MODEL, Local, SFTP,
  BAZA_APP/BAZA_WWW, SMB) тепер спочатку показують статус
  (`✅ 📦 NAME — detail`) через новий спільний хелпер
  `Format-BRAVOOperatorStatusLine`, замість доповнення назви компонента
  фіксованими пробілами перед іконкою статусу. Discord і Slack рендерять
  пропорційним шрифтом, тому вирівнювання пробілами ніколи не працювало
  правильно й ламалося по-різному залежно від довжини назви компонента.
- `BRAVO_DRY_RUN.ps1 -SendTestNotification` тепер конвертує тестове
  повідомлення Discord через той самий контракт
  `ConvertTo-DiscordNotificationText`, що й Archive/Health/Maintenance,
  замість надсилання сирих токенів `:emoji:` до вебхука Discord. Slack не
  постраждав — Slack розпізнає `:shortcode:` нативно.
- Жодних змін у бізнес-логіці PASS/WARN/FAIL, семантиці
  архіву/VSS/ретеншну/SFTP, кодах завершення чи поведінці NotificationMode.

## 5.0.0-dev.11 — 2026-08-09

UX сповіщень оператора уніфіковано між Slack і Discord.

- Додано спільні презентаційні хелпери `BRAVO.Notifications` для заголовків
  серйозності, блоків установи/хоста/публічної IP, рядків версії/збірки,
  посилань на лог, тривалостей та української плюралізації кількості файлів.
- Успішні сповіщення Health тепер використовують `Остання резервна копія`,
  опускають повні імена файлів архіву і показують компактний статус
  компонента/призначення. Попереджувальні/помилкові сповіщення Health
  використовують `Остання успішна резервна копія` і ставлять конкретну дію
  перед метаданими сервера.
- Попередження про довгі імена BAZA_APP/BAZA_WWW тепер пояснюють, що
  пропущено лише проблемні файли, показують фактичне/ліміт/перевищення в
  байтах UTF-8, і включають не більше трьох прикладів у Slack/Discord,
  зберігаючи повний список у логах.
- Успішні сповіщення Maintenance компактні, уникають неоднозначного тексту
  про планування відновлення, показують лише мінімальний вільний диск при
  успіху, і показують деталі дефіциту диска при збоях через нестачу місця.
- Тестові/відновлювальні/безпекові сповіщення тепер використовують той самий
  конверт оператора, зберігаючи NotificationMode, розбиття на частини в
  Discord та вимкнені згадки.

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

Рефакторинг резервного копіювання з урахуванням генерацій. ЗМІНА ПОВЕДІНКИ
(сумісність): Health/Restore тепер вимагають маніфест генерації `COMPLETE`,
небезпечні фолбеки виявлення відхиляються, а записуваний стан машини більше
не живе під кодом.

- MODEL, BLOG і BRAVOEXCH архівуються з одного VSS Snapshot Set з одним
  `GenerationId`. Джерела на одному томі поділяють одну тіньову копію;
  багатотомні джерела залишаються в одному наборі. Збій VSS не виконує
  жодної реальної роботи з архівування.
- Локальна публікація атомарна й без перезапису: `.work` -> створення
  7-Zip -> `7z t` -> створення SHA512 -> реальне порівняння SHA512 ->
  фінальний `.mdz` і sidecar. Наявні валідні резервні копії й хеші ніколи
  не видаляються першими.
- `BRAVO_BACKUP_<GenerationId>.json` фіксує стан знімка, тома та компонента,
  результати передачі та результат Health. Health оцінює найновішу генерацію
  `COMPLETE`; Restore Test обирає одну генерацію автоматично або через
  `-GenerationId`, тож компоненти з різних запусків не можуть змішатися.
- Архітектуру шляхів розділено на чотири незалежні корені: **RuntimeRoot**
  (комплект + `Tools\` + версійовані маніфести + логи скриптів
  `<RuntimeRoot>\LOGS`), **LIMSRoot**, **SystemLogRoot** та **BackupRoot**.
  `pathSettings.ArchiveRoot` видалено як production-концепцію.
  - `LIMSRoot=""` автоматично виявляє канонічний сервіс BRAVO (Name +
    DisplayName); Disabled — валідна ідентичність; відсутні або неоднозначні
    сервіси fail closed; явний `LIMSRoot` завжди перемагає.
  - `SystemLogRoot=""` резолвиться в `<EffectiveLIMSRoot>\ARCHIV\LOGS`;
    явне значення використовується точно. Trace/exchangAPI/BravoWeb живуть
    тут.
  - `BackupRoot=""` резолвиться в `<EffectiveLIMSRoot>\ARCHIV`; явне
    значення використовується точно. Усі три корені порожні — це типовий
    all-AUTO layout, тож постачальний `pathSettings` не містить шляхів,
    специфічних для машини.
  - Логи виконання PowerShell-скриптів завжди в `<RuntimeRoot>\LOGS`
    (хелпери: `<RuntimeRoot>\LOGS\HELPERS`), ніколи в data-корені.
  - Стан машини (`BRAVO_TASK_EXECUTION_STATE.json`,
    `BRAVO_ARCHIV_HEALTH_ALERT_STATE.json`, стан restore/version/VSS) та
    operation lock живуть під `%ProgramData%\BRAVO\{State,Locks}`.
  - Локальні призначення резервного копіювання —
    `BackupRoot\{MODEL,BLOG,BRAVOEXCH,BAZA_APP,BAZA_WWW}` — копія додатку
    це `BAZA_APP`, не `BAZA`.
  - Ретеншн логів скриптів, системних логів і резервних копій — три
    незалежні політики над трьома окремими коренями. Tools і маніфести
    резолвяться з RuntimeRoot; effective ConfigPath зберігається через
    guard, loader, runtime та заплановані завдання. `BRAVO_CONFIG_TEST` /
    `BRAVO_DRY_RUN` / `BRAVO_TASKS_DIAGNOSE` звітують налаштовані проти
    ефективних коренів і перевіряють їх під SYSTEM.
- Канонічний `bravo.ini` — це `%SystemRoot%\SysWOW64\bravo.ini` на x64 і
  `%SystemRoot%\System32\bravo.ini` на x86. Відсутній сервіс/INI/ключ тепер
  контрольовано валить; мовчазні фолбеки `LIMSRoot\Model`, `BLOG`,
  `bravoexch` та BRAVO_ROOT видалено.
- Production та dry-run виконують реальні перевірки читання джерела SYSTEM
  та create/write/read/delete. Archive і Maintenance поділяють
  `C:\ProgramData\BRAVO\Locks\BRAVO_OPERATION.lock`; логи виконання
  включають секунди та PID.
- SFTP використовує фактично налаштований endpoint, без передумови
  `google.com`.
  Завантаження Archive, BAZA_APP і BAZA_WWW мають окремі об'єкти результату,
  кроки консолі та діагностику; наявне порівняння WinSCP post-sync
  збережено.
- Збої створення, цілісності `7z t` та SHA512 розрізняються; збій SHA512 —
  це код завершення `42`. Свіжість Windows Update залишається лише для
  Health. Локальна генерація `COMPLETE` залишається complete, коли
  SFTP/SMB зазнає збою.
- Ретеншн працює за маніфестом генерації, захищає поточну та мінімальну
  кількість верифікованих повних генерацій, і застосовує окремий ретеншн до
  неповних/невдалих генерацій. Віддалені копії отримують маніфест генерації.
- Очищення VSS при жорсткому завершенні зберігає точні Shadow ID, що
  належать BRAVO, у `C:\ProgramData\BRAVO\State\BRAVO_VSS_OWNERSHIP.json`;
  наступний власник machine-wide lock видаляє лише ці ID. Сторонній/
  пошкоджений стан і невдале точне видалення за ID зберігаються і fail
  closed.
- Health тепер перевіряє той самий operation lock ProgramData, що
  використовують Archive і Maintenance, замість застарілого маркера,
  відносного до ArchiveRoot.

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
