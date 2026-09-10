# BRAVO-Toolkit — дорожня карта

Цей документ визначає актуальний порядок розвитку BRAVO-Toolkit. Детальні технічні design notes для окремих великих функцій залишаються в `TODO_FEATURES.md`; `ROADMAP.md` є канонічним джерелом пріоритетів і послідовності реалізації.

## Принципи планування

- Спочатку усуваються відомі production-ризики й прогалини release-процесу, потім додаються нові функції.
- Backup вважається надійним лише тоді, коли його регулярно перевірено реальним restore drill.
- Компрометація одного LIMS-сервера не повинна давати можливість знищити всю історію резервних копій.
- Root `BRAVO_*.ps1` залишаються thin entrypoints; нова доменна логіка належить `modules/BRAVO.<Domain>/`.
- Telemetry/monitoring не повинні змінювати exit code або результат Archive/Health/Maintenance/Restore.
- Auto-update не реалізується раніше, ніж існують стабільний release artifact, перевірка цілісності, atomic activation і rollback.

## Актуальні технічні обмеження

### Автентифікація SFTP

Production SFTP для Hetzner Storage Box залишається password-based. Перехід на public-key authentication не є поточним завданням, оскільки використовуване сховище в цьому deployment-профілі працює з парольною автентифікацією.

Найближчі роботи в цій області обмежуються посиленням існуючої моделі:

- host-key pinning залишається обов'язковим;
- credentials зберігаються у Windows Credential Manager;
- секрети не записуються в config/logs;
- зберігається мінімально необхідний доступ SFTP-акаунта;
- окремо опрацьовується захист remote backup history від масового видалення/шифрування.

Public-key authentication можна переглянути пізніше, якщо зміниться backend або з'явиться сумісний режим без погіршення операційної підтримки.

### Authenticode / підписані релізи

Authenticode, підписані git tags і криптографічно підписаний release manifest не входять до найближчого плану. До них повертаємось, якщо реалізація не потребує істотних додаткових витрат, окремої складної PKI або значного операційного навантаження.

До того часу основними контролями цілісності лишаються:

- `RUNTIME_MANIFEST.json`;
- `TOOLS_MANIFEST.json`;
- CI;
- PSScriptAnalyzer security rules;
- gitleaks;
- release policy;
- provenance через `VERSION.json.sourceCommit`/`buildId`.

## P0 — стабілізація й production safety

### P0.1 — Завершити hotfix 5.0.1

**Статус (2026-08-25): цикл закрито.** PR #45 (`hotfix/5.0.1`) злито,
stable `5.0.1` випущено 2026-08-18 (тег `v5.0.1`, CHANGELOG §5.0.1) і
синхронізовано назад у `developer`. Формального real-server acceptance
саме PR #45 у репозиторії не зафіксовано (промоція спиралась на
CI + повний self-test із regression-доказом); notification
routing/override поведінку повторно підтверджено real-server
acceptance циклу 5.1.0 (rc.2/rc.4 PASS).

Поточний production-дефект notification override має бути закритий до нових feature-релізів.

Критерії завершення:

- [ ] PR #45 проходить real-server acceptance. *(не зафіксовано окремо;
      покрито опосередковано acceptance 5.1.0-rc.2/rc.4)*
- [ ] Перевірено `NotificationMode=none/errors_only/all` з `-EnableAllSlack`/`-DisableAllSlack`. *(окремий протокол відсутній)*
- [ ] Перевірено GENERAL/ALERTS routing і credential fallback. *(routing підтверджено acceptance 5.1.0-rc.4)*
- [ ] Перевірено Maintenance final report і критичні alerts. *(окремий протокол відсутній)*
- [x] `5.0.1-rc.1` промотовано у stable `5.0.1` без функціональних змін після acceptance.
- [x] Hotfix синхронізовано назад у `developer`.

### P0.2 — Закрити release governance

Мета — унеможливити повторення прямого feature merge у `master` в обхід RC/acceptance.

**Статус (2026-08-26): закрито.** PR #46 злито
(`ci/Test-BRAVOMasterMergePolicy.ps1` працює в CI). PR #92 додав
семантичне порівняння stable-версій (`Test-BRAVOStableVersionPromotion`
з регресіями, включно з кейсом `5.10.0 > 5.9.0`). Гілка
`hardening/release-governance` додала перевірку repository identity
(`Test-BRAVOMasterMergeSource`: PR у `master` приймається лише з
`developer`/`hotfix/*` ЦЬОГО репозиторію; fork з однойменною гілкою —
FAIL; невідомий head-репозиторій — fail-closed). Репозиторій став
публічним, тож branch protection доступний без GitHub Pro: увімкнено
для `master` і `developer` (PR-only, required checks, заборона force
push/видалення, `enforce_admins` — admin-обхід на кшталт прецеденту
PR #61 у вікні промоції 5.1.0 технічно заблоковано). Фактична
конфігурація — `RELEASE_POLICY.md`, розділ 13.

Критерії завершення:

- [x] PR #46 доведено до merge після виправлення всіх review findings.
- [x] Gate перевіряє дозволене джерело PR (`developer` або `hotfix/*`) і repository identity.
- [x] Gate вимагає семантичне збільшення stable version, а не лише нерівність рядків. *(PR #92)*
- [x] `master` не приймає feature/fix PR напряму. *(CI-гейт + branch protection з `enforce_admins`)*
- [x] Branch/repository settings максимально обмежують direct push, force push і випадковий merge настільки, наскільки це дозволяє поточний GitHub plan. *(branch protection увімкнено на `master` і `developer`, 2026-08-26)*

### P0.3 — Захист remote backup history

Це головний залишковий ризик для даних. Компрометація LIMS-сервера або його SFTP credentials не повинна дозволяти знищити всі історичні копії.

Цільовий напрям:

- окремити створення нової backup generation від права масового видалення історії;
- використовувати server-side snapshots/versioning/immutable policy там, де це підтримує storage backend;
- або організувати pull-based/second-copy процес із системи, credentials якої відсутні на LIMS-сервері;
- перевіряти, що retention не може знищити останню незалежну recoverable copy.

Критерії завершення:

- [x] Обрано конкретну схему для Hetzner Storage Box/вторинного сховища:
      вбудовані Hetzner Storage Box Snapshots (20 знімків, щоденно
      о 05:00 UTC, керовані окремо через Hetzner Robot — credentials,
      відсутні на LIMS-сервері й у Credential Manager). Другий,
      pull-based/offline шар (окрема система з окремими credentials)
      свідомо відкладено на P1.3 — снапшоти вже закривають найгостріший
      сценарій розділу 5 `THREAT_MODEL.md` самостійно.
- [x] Задокументовано threat model і recovery procedure —
      `THREAT_MODEL.md` розділ 5 (мітигація/залишковий ризик) і
      розділ 12 (Recovery procedure).
- [x] Проведено тест: компрометований/видалений primary backup не знищує незалежну історичну копію.
      **Виконано 2026-08-19** на живому Hetzner Storage Box: снапшот-каталоги
      доступні read-only через SFTP (`/.zfs/snapshot/<name>/...`), файли з
      них відновлюються копіюванням без деструктивного повного Restore
      snapshot у Robot (повний Restore навмисно НЕ виконувався — він
      відкотив би весь бокс і видалив новіші снапшоти).

## P1 — доказова відновлюваність і deployment quality

### P1.1 — Автоматичний scheduled Restore Drill

**Статус (2026-08-26, цикл 5.3.0): реалізовано** (гілка
`feature/restore-verify`): задача `BRAVO_RESTORE_VERIFY` (weekly-тригер,
типово Сб 04:00, `schedulerSettings.RestoreVerify`) запускає наявний
`BRAVO_RESTORE_TEST.ps1 -NoPause -NotifyOnSuccess`; стан у
`%ProgramData%\BRAVO\State\BRAVO_RESTORE_VERIFY_STATE.json`
(модуль `BRAVO.RestoreVerify`, атомарний запис, `LastVerifiedAt`
оновлюється лише повністю чистим прогоном); Health-крок
«Відновлюваність (restore drill)» оцінює вік проти
`restoreVerifySettings.MaxVerificationAgeHours` (типово 216 год).
Drill отримав runtime guard і bounded cleanup покинутих drill-каталогів.
Real-server acceptance розкладу/нотифікацій — окремим прогоном.

`BRAVO_RESTORE_TEST.ps1` став штатним елементом експлуатації, а не ручною процедурою.

Цільова поведінка:

```text
останній COMPLETE generation
        ↓
ізольований restore
        ↓
7z/hash/manifest validation
        ↓
file-count/size sanity
        ↓
cleanup
        ↓
machine-readable result + notification
```

Критерії завершення:

- [x] Додано окремий scheduler task `BRAVO_RESTORE_VERIFY`.
- [x] Розклад задається конфігурацією (`RestoreVerify.WeeklyOn/At`); типовий інтервал — щотижня (Сб 04:00).
- [x] Restore drill не торкається production paths і не зупиняє служби. *(незмінна властивість BRAVO_RESTORE_TEST)*
- [x] Є stable exit code/result contract. *(0/10/41/90 + JSON `-ResultPath`/`-AsJson` — без змін; + state-файл)*
- [x] Health може показати вік останньої успішної restore verification. *(крок «Відновлюваність (restore drill)»)*
- [x] Failure піднімає WARNING/CRITICAL залежно від причини. *(WARN→WARNING, FAIL→CRITICAL в ALERTS; SUCCESS→GENERAL для scheduled)*
- [x] Є bounded cleanup тимчасових restore artifacts. *(сироти >7 діб, ≤10 за прогін)*

### P1.2 — Стабільний release-артефакт

Мета — перестати трактувати довільний checkout/набір файлів як release package.

Мінімальний artifact:

```text
BRAVO-Toolkit-X.Y.Z.zip
BRAVO-Toolkit-X.Y.Z.zip.sha256
release-manifest.json
```

**Статус (2026-08-25): закрито.** Реалізовано
`.github/workflows/release-artifact.yml` +
`ci/New-BRAVOReleaseArtifact.ps1`: збірка з конкретного git ref із
провенанс-гейтом (`sourceCommit` має бути повним hash), `*.zip.sha256`,
`release-manifest.json` (product/version/sourceCommit/files+hashes),
повний self-test із розпакованого артефакту перед публікацією; процедура
отримання/перевірки описана в `BRAVO_SETUP.md`, розділ «Отримання
комплекту (release artifact)».

Критерії завершення:

- [x] Artifact збирається автоматично з конкретного release commit/tag.
- [x] SHA-256 перевіряється до deployment.
- [x] Manifest містить product, version, sourceCommit і список файлів/хешів.
- [x] Artifact проходить CI/self-test перед публікацією.
- [x] Документація оновлення посилається на artifact, а не на ручне копіювання випадкового checkout.

Підпис artifact/manifest є optional future hardening, не blocker для цього етапу.

### P1.3 — Життєвий цикл backup / розділення retention

Мета — зменшити blast radius credentials, якими користується Archive.

Напрями:

- BRAVO створює нові generations;
- destructive retention виконується окремим authority/process там, де це технічно можливо;
- останні verified generations мають незалежний захист від помилкового або зловмисного видалення.

Цей пункт може бути реалізований разом із P0.3, якщо storage architecture дозволяє.

### P1.4 — SELF_TEST fail-fast structural validation і timing telemetry

**Статус: DONE** (PR #138, змерджено в `developer` 2026-09-09, squash
commit `57b16cba77ea4f30fa4464a9be2d8bfa122c132a`).

Реалізовано:

- рання fail-closed structural preflight (runtime manifest integrity,
  обов'язкові manifest-файли, синтаксис production `*.Runtime.ps1`,
  критичний JSON) на bootstrap-межі, до імпорту manifest-covered
  helper-модулів;
- контрольований (не uncontrolled exception) fail-closed шлях для
  bootstrap integrity-scan збоїв;
- Phase 0 short-circuit: структурний провал зупиняє доменні тести й
  виходить через стандартний report-шлях;
- diagnostic timing telemetry: total wall-clock, per-suite wall-clock,
  `Root (inline)` wall-clock, assertion interval telemetry, Top 20
  найдовших assertion-інтервалів;
- framework-регресії для bootstrap integrity, tampered manifest-covered
  helper, invalid bootstrap manifest, Phase 0 short-circuit, fixture
  setup/cleanup провалів (включно з ACL/access-denied cleanup-станами
  і TEMP-незалежним fixture setup через `[IO.Path]::GetTempPath()`).

Final validation evidence: `PASS: 1893, FAIL: 0, Exit: 0, Total
wall-clock: 00:07:57.113`.

**Важливо:** ця telemetry — вимірювання/діагностика, НЕ P1
performance optimization. `SELF_TEST` не став суттєво швидшим
внаслідок цього PR; він лише отримав інструменти для вимірювання, де
саме витрачається час. Проблема довгого `SELF_TEST` (P1.5 нижче)
залишається відкритою.

### P1.5 — Оптимізація продуктивності SELF_TEST

**Статус: TODO / PLANNED.** Окремо від P1.4 (яка додала лише
вимірювання, не пришвидшення).

Можливі напрями (жоден ще не реалізований):

- AST/text caching для повторюваних parse-операцій;
- `-Suite` / `-Affected` — вибіркове виконання підмножини тестів;
- оптимізація runtime child-process smoke-test фікстур;
- декомпозиція кореневого `BRAVO_SELF_TEST.ps1` на менші одиниці
  виконання без втрати hermetic-гарантій;
- скорочення/видалення непотрібних `Start-Sleep`-очікувань там, де
  timing telemetry (P1.4) підтверджує, що вони не потрібні;
- безпечний паралелізм там, де fixture-ізоляція це дозволяє.

Використовувати timing telemetry з P1.4 (per-suite wall-clock, Top 20
найдовших assertion-інтервалів) як evidence base для пріоритизації
цієї роботи, а не здогадки.

## P2 — централізована експлуатація

### P2.1 — Машинозчитуваний health/status-контракт

**Статус (2026-08-26, цикл 5.3.0): реалізовано** (гілка
`feature/status-contract`): модуль `modules/BRAVO.Status/` — канонічний
власник контракту; кожна з чотирьох операцій після обчислення exit code
атомарно пише `%ProgramData%\BRAVO\State\STATUS\BRAVO_STATUS_<Operation>.json`
(fail-soft: помилка запису ніколи не змінює результат операції).
Спільне ядро схеми + `details` per-operation; поля
`lastCompleteGeneration`/`lastRestoreVerifiedAt`/`*Verified`/
`runtimeIntegrity`/`toolIntegrity` з ескізу нижче живуть у `details`
Health-файла. Транспорт/моніторинг поверх файлів — P2.2 (свідомо не
входить у v1 за рішенням власника: «моніторинг поки не робимо,
укріплюємо основу»).

Уніфікувати JSON-result для Archive, Health, Maintenance і Restore Verification.

Мінімальні поля:

```json
{
  "schemaVersion": 1,
  "host": "...",
  "packageVersion": "...",
  "operation": "Health",
  "status": "OK",
  "exitCode": 0,
  "lastCompleteGeneration": "...",
  "lastRestoreVerifiedAt": "...",
  "localVerified": true,
  "sftpVerified": true,
  "smbVerified": true,
  "runtimeIntegrity": "OK",
  "toolIntegrity": "OK"
}
```

Критерії завершення:

- [x] Один versioned schema для machine consumers. *(BRAVO.Status, schemaVersion 1)*
- [x] Жодних secret-bearing values. *(контракт + самотест Status/NoSecretBearingFields)*
- [x] Exit codes лишаються canonical source of failure class. *(status — проєкція exitCode; fail-soft самотести CallSiteIsFailSoft)*
- [x] JSON можна використовувати Zabbix/telemetry без парсингу console text. *(4 файли в `STATUS\`; сама інтеграція — P2.2)*

### P2.2 — Віддалена телеметрія парку серверів

Продовжити FEAT-003 із `TODO_FEATURES.md`, але після появи стабільного локального machine-readable contract.

Порядок:

1. schema + server identity;
2. durable outbox;
3. heartbeat і Task Scheduler inspection;
4. HTTPS/443 + per-server HMAC;
5. gateway + PostgreSQL + idempotency;
6. task.started/task.finished;
7. stale/offline/overdue evaluation;
8. fleet dashboard / Zabbix integration.

Telemetry залишається outbound-only і не перетворюється на remote-command channel.

## P3 — configuration і lifecycle automation

### P3.1 — Config v2

**Статус: Foundation completed; final declarative Config v2 completion
pending.**

FEAT-001 із `TODO_FEATURES.md` залишається важливим, але не випереджає production safety та restore verification.

Ціль: package defaults + site-local data-only overrides + deterministic schema validation + legacy migration.

**P0 Configuration Foundation — DONE** (змерджено в `developer`):
canonical built-in defaults, deterministic deep merge (array replace,
явний `@()` — валідний override, `Limits.ExcludedDrives` дефолт —
`@()`), опційний `BRAVO.config`, `-ConfigPath` AUTO/EXPLICIT-контракт,
derivation після merge, post-merge security-invariant re-validation,
restricted-language `BRAVO.local.config` (dot-шлях → значення):
`CheckRestrictedLanguage` з порожніми command/variable allow-lists
блокує виклики cmdlet/функцій і посилання на недозволені змінні до
виконання, але це НЕ робить граматику суто літеральною — restricted-
language граматика PowerShell усе ще допускає окремі вирази
(наприклад, арифметичні/range-вирази), а сам validated `ScriptBlock`
усе ще ВИКОНУЄТЬСЯ (`& $scriptBlock`), тож будь-який дозволений вираз
обчислюється, а не лише екстрактується як літерал — це не те саме, що
non-executing AST-only parser (цільовий Config v2 контракт нижче,
деталі — `docs/design/BRAVO_CONFIGURATION_V2_COMPLETION.md`).
Precedence сьогодні: `DEFAULT <
BRAVO.config (опційно) < BRAVO.local.config (опційно)`. Деталі —
`docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md`.

**Config v2 — IN PROGRESS / не завершено.** `BRAVO.config` сам
залишається виконуваним PowerShell-скриптом (не DATA-only),
`VERSION.json.configSchemaVersion` = `1`, файл `BRAVO.config.local`
(цільова v2-назва) у runtime ще не існує. Повний перелік
залишкових gaps, target architecture, safe declarative parser
requirement, schema v2, migration і DoD regression matrix —
`docs/design/BRAVO_CONFIGURATION_V2_COMPLETION.md`.

Починати наступний PR-цикл після стабілізації P0/P1, якщо ручний merge `BRAVO.config` продовжує створювати реальний операційний ризик.

### P3.2 — Атомарний версійований deployment / rollback

FEAT-002 реалізується після stable release artifact і, бажано, Config v2.

Порядок:

1. stable launcher;
2. versioned release directories;
3. deployment pointer;
4. staging + validation;
5. atomic activation;
6. automatic rollback;
7. update journal;
8. лише після цього — можливість auto-download/auto-update.

Silent auto-update production серверів до завершення цих етапів заборонений архітектурно.

### P3.2a — BRAVO_UPDATE.ps1: operator-triggered оновлення (перенесено на 5.3.0)

**Не реалізовується у 5.2.0.** Раніше запланований на цикл 5.2.0, але
перенесений на `5.3.0`: це окремий функціональний цикл із новою
поверхнею атаки (download release-артефакта з GitHub, перевірка
цілісності отриманого артефакта, staging, `robocopy /MIR` у runtime,
partial-update semantics, rollback, recovery після перерваного update,
trust/integrity guarantees) — кожен пункт вимагає власного acceptance,
який не повинен блокувати вже готовий 5.2.0 scope (виправлення
production-інцидентів циклу dev.1). У коді 5.2.0 щодо P3.2a — нуль змін;
`BRAVO_UPDATE.ps1` і `modules/BRAVO.Update/` реалізуються окремим циклом.

Проміжний етап P3.2 (закриває його кроки staging + validation +
rollback у спрощеній формі), запланований на цикл 5.2.0. Автоматизує
рівно те, що виконувалось вручну при оновленні парку до v5.1.0
(production-сервер BRAVO, 2026-08-20), разом із виявленими там граблями.

Форма: thin entrypoint `BRAVO_UPDATE.ps1` + домен-модуль
`modules/BRAVO.Update/`. Запуск — ЛИШЕ явною командою оператора на
сервері (elevated); жодного scheduled-тригера і жодного silent-режиму.

Обов'язкові кроки одного прогону:

1. TLS 1.2 примусово (legacy-сервери 2016 не мають його дефолтом);
2. завантаження артефакта GitHub Release за явним тегом (`-Tag vX.Y.Z`,
   без "latest" за замовчуванням) + звірка SHA-256 з `.zip.sha256`;
3. staged-розпакування в тимчасовий каталог, НЕ в runtime;
4. диф `BRAVO.config` поточного комплекту зі staged: змінені ЗНАЧЕННЯ
   (не коментарі/нові дефолти) -> STOP з переліком, оновлення
   продовжується тільки після явного підтвердження перенесення;
5. preflight: жодне завдання `\BRAVO\` не Running;
6. backup поточного комплекту копіюванням у `<runtime>.old_<ver>`
   (Rename-Item каталогу runtime НЕМОЖЛИВИЙ — ACL-захист
   BRAVO_TASKS_INSTALL забороняє його навіть адміністратору; спроба
   rename+move кладе новий комплект УСЕРЕДИНУ старого і блокує нічні
   завдання guard-ом з кодом 33);
7. дзеркалення staged у runtime НА МІСЦІ (robocopy /MIR з виключенням
   LOGS) — шлях, ACL і визначення завдань Планувальника не змінюються;
8. гейти після заміни: VERSION.json = очікуваний тег; Runtime Guard
   exit 0; `BRAVO_SETUP -Action Scheduler` (нові завдання версії);
   `BRAVO_SETUP -Action Test` без FAIL;
9. update journal: запис (стара/нова версія, тег, sha256, оператор,
   результати гейтів) у machine state;
10. автоматичний відкат із backup-копії при провалі будь-якого гейта
    8 (дзеркалення назад тим самим механізмом), зі збереженням логів
    невдалої спроби.

Свідомо НЕ входить у P3.2a (лишається за повним P3.2/P4):
versioned-каталоги з deployment pointer, atomic activation,
auto-download за розкладом, будь-який silent-режим, підпис артефактів.
Довіра до артефакта в P3.2a = TLS до GitHub + SHA-256 з того самого
каналу — прийнятно для операції, яку ініціює і спостерігає оператор,
недостатньо для автономної.

## P4 — опційне посилення захисту

Виконувати лише після основних operational задач або коли з'явиться дешевий/простий шлях реалізації:

- Authenticode для PowerShell;
- signed release manifest;
- signed git tags;
- SFTP public-key authentication для backend, який це підтримує;
- інші supply-chain controls, що потребують окремої PKI/сертифікатів.

Ці пункти не повинні блокувати P0–P3.

## Рекомендована послідовність

```text
1. acceptance/stable для hotfix 5.0.1
2. gate управління релізами master/release governance
3. захист історії віддалених резервних копій
4. плановий Restore Drill
5. stable release ZIP + SHA-256 + маніфест
6. розділення повноважень retention
7. машинозчитуваний контракт статусу
8. віддалена телеметрія парку серверів / інтеграція Zabbix
9. Config v2
10. атомарний deployment + rollback
11. auto-update
12. опційне підписання / посилення захисту public-key
```

## Що не є поточним пріоритетом

- загальний refactoring без конкретного defect/security/testability benefit;
- microservice-style дроблення PowerShell-модулів;
- SFTP public-key migration для Hetzner Storage Box;
- Authenticode лише заради формальної наявності підпису;
- remote command execution через telemetry gateway;
- auto-update до появи atomic rollback і перевіреного release artifact.
