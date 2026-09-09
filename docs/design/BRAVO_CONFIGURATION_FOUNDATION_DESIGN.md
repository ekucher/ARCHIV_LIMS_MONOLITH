# BRAVO Configuration Foundation — architecture gate (P0)

> Статус (оновлено): PR A = PR #127 `feature/config-foundation`
> (canonical defaults + merge engine) — merged. PR B = PR #128
> `feature/config-foundation-derivation` (`BRAVO_CONFIG_LOADER.ps1`
> snapshot-виконання, `-ConfigPath` explicit/auto-intent, security
> invariant re-validation, Configurator `DefaultValue` adapter) —
> merged. PR C = PR #129 `feature/config-foundation-pr-c` (прибирання
> дублюючого derivation/two-phase-override коду з `BRAVO.config`,
> AUTO/EXPLICIT-контракт для Task Scheduler/`BRAVO_SETUP.ps1`/
> Configurator, security-blind-spot fix для `BRAVO.local.config`,
> install/update preservation) — merged. Усі три в `developer` (див.
> CHANGELOG.md, розділ «Не випущено (developer)», запис «P0
> Configuration Foundation»).
> **P0 Configuration Foundation вважається завершеним.** Розділи нижче
> лишаються як історичний запис прийнятого architecture-рішення
> (7 питань gate, source matrix, обґрунтування розбиття на PR A/B/C) —
> не переписані заднім числом під фактичну реалізацію; де реалізація
> відрізнялась від плану, це задокументовано в CHANGELOG.md. Наступний
> етап (фінальний DATA-only формат `BRAVO.config`, `configSchemaVersion`
> 2, безпечний non-executing parser для основного файла) НЕ входить у
> цей gate і НЕ завершений — статус і Definition of Done дивіться в
> `docs/design/BRAVO_CONFIGURATION_V2_COMPLETION.md`.

## 0. Контекст

Джерело завдання: "P0 Configuration Foundation" (feature-запит власника,
2026-09-02). Мета — щоб BRAVO міг побудувати повну штатну конфігурацію без
`BRAVO.config`, з precedence `DEFAULT < BRAVO.config < BRAVO.local.config`, і
щоб derivation/discovery виконувались після merge, а не до нього.

Це документ архітектурного gate, який ТЗ вимагає пройти ПЕРЕД
implementation (розділ 6.2 "Обов'язковий architecture gate для legacy
BRAVO.config") і зафіксувати рішення про розбиття на кілька PR (розділ 26
"Scope split rule"), якщо чесна реалізація повної precedence в одному PR
неможлива без надмірного blast radius.

## 1. Інвентаризація (розділ 2 ТЗ) — ключові факти з поточного `developer`

- `BRAVO.config` (1318 рядків) — виконуваний PowerShell-скрипт із
  `param(ConfigRoot, RuntimeRoot)`. Він одночасно:
  1. визначає raw-значення (літеральні hashtable-блоки:
     `bravoSettings`, `credentialSettings`, `hostInformationSettings`,
     `pathSettings`, `maintenanceSettings`, `componentSettings`,
     `synchronizationSafety`, `consoleSettings`, `progressSettings`,
     лог-скаляри, архівні скаляри, `backupConsistency`,
     `operationLockSettings`, robocopy/sftp/`smbSettings`,
     `sftpDirectories`, `backupMonitoring`, `schedulerSettings`,
     `restoreVerifySettings`);
  2. викликає `Invoke-BRAVOLocalConfigurationOverridePhase` у ДВОХ точках
     (рядок ~602 — фаза 1, одразу після первинних raw-блоків, ДО
     деривації; рядок ~1314 — фаза 2, наприкінці, для пізніх блоків) —
     тобто **вже сьогодні** local overrides застосовуються ДО derivation,
     що дуже допомагає новій архітектурі;
  3. викликає канонічні derivation-функції з `modules/BRAVO.Discovery` та
     інших модулів: `Resolve-BRAVOEffectiveLimsRoot`,
     `Resolve-BRAVOInstallationDiscovery`,
     `Resolve-BRAVOEffectiveBackupRoot`,
     `Resolve-BRAVOEffectiveSystemLogRoot`,
     `Get-BRAVOEffectiveStorageConfiguration`,
     `Get-BRAVOEffectiveSynchronizationConfiguration` — derivation-логіка
     **вже винесена** у канонічні функції; `BRAVO.config` лише
     ОРКЕСТРУЄ їх виклик з raw-значеннями.
- `BRAVO_CONFIG_LOADER.ps1` (`Import-BravoConfiguration`) сьогодні вимагає,
  щоб файл `BRAVO.config` існував (`$ConfigPath = Join-Path
  $resolvedConfigRoot 'BRAVO.config'`, потім виконує його — відсутність
  файлу є помилкою).
- `Read-BRAVOLocalConfigurationOverrides` + `BRAVO.local.config` вже існують,
  data-only (`CheckRestrictedLanguage` з порожніми allow-list), fail-closed,
  dot-path формат — **canonical local override контракт з 5.2.1, не
  чіпається цим PR**.
- `BRAVO.local.config.example` документує ТОЧНИЙ канонічний перелік
  overridable dot-path'ів по двох фазах і явно забороняє перевизначати
  похідні блоки: `sourcePaths`, `archiveDirs`, `bazaAppPaths`,
  `bazaWWWPaths`, `archiveDefinitions`, `discoverySettings`,
  `toolIntegritySettings`, шляхи типу `HelperPath`/`ScriptPath`. Це є
  authoritative межа "raw vs derived" — цей PR її не розширює і не звужує.
- Виявлена документована суперечність (ТЗ розділ 5, підтверджено):
  `maintenanceSettings.Limits.ExcludedDrives` = `@('F:\')`, хоча коментар
  поруч стверджує "За замовчуванням виключень немає". `F:\` —
  environment-specific значення конкретного розгортання, яке НЕ повинно
  бути built-in-дефолтом продукту.

## 2. Конфігураційна source matrix (витяг; повний перелік — 1:1 з
`BRAVO.local.config.example`, обидві фази)

| Path / блок | Поточне джерело | Raw/Derived | Overrideable | Security-critical | Target source (цей PR) |
|---|---|---|---|---|---|
| `bravoSettings.*` | `BRAVO.config` | Raw | Yes | No (крім `NotificationRouting` — не secrets) | `Get-BRAVODefaultConfiguration` |
| `credentialSettings.Targets.*` | `BRAVO.config` | Raw (назви записів Credential Manager, не значення) | Yes | Ні (це імена, не секрети) | `Get-BRAVODefaultConfiguration` |
| `credentialSettings.HelperPath/SetupScriptPath` | `BRAVO.config` (`Join-Path $runtimeRoot ...`) | **Derived** (RuntimeRoot) | No | No | залишається деривацією (не в цьому PR) |
| `hostInformationSettings.*` | `BRAVO.config` | Raw | Yes | Так (зовнішній HTTP-запит toggle) | `Get-BRAVODefaultConfiguration` |
| `pathSettings.*` | `BRAVO.config` | Raw (`""`=AUTO) | Yes | No | `Get-BRAVODefaultConfiguration` |
| `maintenanceSettings.*` (Services/Restore/Retention/Trace/Limits/Automation/RangeIdMonitoring/Archiver/FileOperations/Logging) | `BRAVO.config` | Raw | Yes | Частково (`Restore.BootRestoreMode` впливає на safety) | `Get-BRAVODefaultConfiguration` |
| `maintenanceSettings.Limits.ExcludedDrives` | `BRAVO.config` (`@('F:\')`, коментар суперечить) | Raw | Yes | No | **`@()`** — виправлений built-in дефолт (розділ 5 ТЗ) |
| `componentSettings.*` | `BRAVO.config` | Raw | Yes | Так (SFTP/SMB `Enabled` — master gate) | `Get-BRAVODefaultConfiguration` |
| `synchronizationSafety.*` | `BRAVO.config` | Raw | Ні (немає в example, але поле існує) | Так (anti-ransomware guard) | `Get-BRAVODefaultConfiguration` (включено як built-in raw) |
| `consoleSettings.*`, `progressSettings.*` | `BRAVO.config` | Raw | Yes | No | `Get-BRAVODefaultConfiguration` |
| `LogLevel`, лог-скаляри | `BRAVO.config` | Raw | Частково | No | `Get-BRAVODefaultConfiguration` |
| `backupConsistency.*` | `BRAVO.config` | Raw | Yes | Так (VSS/Direct — data-integrity) | `Get-BRAVODefaultConfiguration` |
| `operationLockSettings.Path` | `BRAVO.config` (`Join-Path $env:ProgramData ...`) | **Derived** | No | No | залишається деривацією |
| robocopy*/sftp-скаляри/`smbSettings.*` | `BRAVO.config` | Raw | Yes | Так (`sftpHostKey` — host-key pinning, розділ 03-security.md) | `Get-BRAVODefaultConfiguration` |
| `sftpDirectories.*` | `BRAVO.config` (фаза 2) | Raw | Yes | No | `Get-BRAVODefaultConfiguration` |
| `toolIntegritySettings.*` | `BRAVO.config` (`Join-Path $toolsPath ...`) | **Derived** | No | Так | залишається деривацією |
| `backupMonitoring.*` (крім шляхів стану) | `BRAVO.config` (фаза 2) | Raw | Yes | Частково (`BAZA.MutationPolicy`, `AutoArchiveMutationThreshold` — append-only invariant, `07-bravo-runtime-invariants.md`) | `Get-BRAVODefaultConfiguration` |
| `backupMonitoring.SFTP.BAZA.StateRoot`, `*StatePath` | `BRAVO.config` (`Join-Path $stateRoot ...`) | **Derived** | No | No | залишається деривацією |
| `schedulerSettings.*` (крім `*.ScriptPath`, `Recovery.Enabled`, `Recovery.StartupDelayMinutes`, `BAZASync.Enabled`) | `BRAVO.config` (фаза 2) | Raw | Yes | No | `Get-BRAVODefaultConfiguration` |
| `schedulerSettings.*.ScriptPath`, `Recovery.Enabled/StartupDelayMinutes`, `BAZASync.Enabled` | `BRAVO.config` | **Derived** (з RuntimeRoot або з інших raw-полів) | No (документовано в example: "перевизначайте first-order поле") | No | залишається деривацією |
| `restoreVerifySettings.*` | `BRAVO.config` | Raw | Yes (не в example, але існуючий leaf) | No | `Get-BRAVODefaultConfiguration` |
| `sourcePaths`, `archiveDirs`, `bazaAppPaths`, `bazaWWWPaths`, `archiveDefinitions`, `discoverySettings`, `effectiveLimsRoot`, `storageEffective`, `bazaSyncEffective` | `BRAVO.config` (виклики canonical resolver-функцій) | Derived | No | Так (шляхи джерел/призначення) | без змін — канонічні resolver-функції в `BRAVO.Discovery`/тощо, викликаються ПІСЛЯ raw-merge (без змін порядку в цьому PR — сьогодні вже так) |

Повний перелік (усі листові поля обох фаз) веде
`BRAVO.local.config.example` — цей PR НЕ вводить нову класифікацію
raw/derived, а лише переносить існуючі raw-значення в окреме
canonical-джерело.

## 3. Відповіді на 7 питань architecture gate (розділ 6.2 ТЗ)

1. **Як з existing `BRAVO.config` отримуються raw override values?**
   У цьому PR (PR A) — ніяк: `BRAVO.config` не читається новим модулем
   узагалі. `modules/BRAVO.Configuration` дає лише built-in defaults і
   generic merge/precedence engine, незалежні від того, звідки саме
   візьмуться "primary overrides". PR B має захопити ці значення,
   виконавши `BRAVO.config` в ізольованому scope і знявши знімок ЛИШЕ
   його raw-блоків (перелічених у §2 як "Raw"), ігноруючи все, що він
   обчислює після рядка ~608 (discovery/derivation) — ці похідні
   результати НІКОЛИ не читаються, канонічний resolver перераховує їх
   заново з фінального merged raw config.
2. **Як уникнути залежності від його derived outputs?** — Дивись (1):
   похідні `$global:*`, які `BRAVO.config` встановлює
   (`effectiveLimsRoot`, `storageEffective`, `archiveDefinitions` тощо),
   у PR B просто НЕ читаються зі снапшоту; вони перераховуються заново
   викликом тих самих канонічних resolver-функцій, що й сьогодні,
   але один раз, у loader, після повного raw-merge.
3. **Як не виконати discovery двічі або в неправильному порядку?** —
   Легасі `BRAVO.config`, якщо в ньому вручну не прибрано derivation-код
   (стара копія на диску), технічно виконає СВОЮ копію discovery під час
   снапшот-запуску (для отримання власних raw-блоків) — це не помилка
   (ідемпотентно, read-only проби), але зайва робота. Канонічний
   derivation виконується РІВНО ОДИН РАЗ — у loader, після merge, і саме
   його результат стає Effective Configuration. Нові/оновлені шаблони
   `BRAVO.config` (після PR B) матимуть derivation-блоки видалені —
   подвійного виконання не буде взагалі.
4. **Як підтримуються старі `BRAVO.config` без нових ключів?** —
   Merge-engine (цей PR) не вимагає, щоб primary-overrides містили ВСІ
   ключі: відсутній ключ = built-in default використовується як є
   (Test 21 ТЗ). Це вже природна властивість `Merge-BRAVOConfiguration`.
5. **Як розрізняється старий executable формат від майбутнього
   declarative?** — У PR A/B формат не змінюється: `BRAVO.config`
   лишається виконуваним PowerShell (без format-versioning) —
   декларативний формат explicitly НЕ входить у це рішення (розділ 6.3
   ТЗ: якщо чесна precedence вимагає format migration, потрібен окремий
   checkpoint). Тут це не потрібно: снапшот-підхід (2)-(3) дає правдиву
   precedence БЕЗ зміни формату файлу.
6. **Як не втратити site customization на старих інсталяціях?** —
   Снапшот-підхід читає буквально ті самі `$global:*`, які сайт
   налаштував у своєму `BRAVO.config` (явні значення перемагають built-in
   defaults через `Merge-BRAVOConfiguration`) — жодна існуюча
   кастомізація не втрачається.
7. **Як не створити два незалежні effective pipeline (config-present vs
   config-absent)?** — Обидва режими (PR B) проходять через ОДИН
   виклик canonical resolver: `defaults [merge] primary-snapshot-or-empty
   [merge] local-overrides -> raw merged -> derivation (той самий виклик
   незалежно від Present/Absent) -> Effective Configuration`. Різниця
   лише в тому, чи є непорожній primary-шар для merge — не в тому, яка
   гілка коду виконується.

## 4. Рішення про розбиття (розділ 26 ТЗ)

Повна реалізація одним PR (canonical defaults + snapshot-based primary
capture + переписаний loader без mandatory `BRAVO.config` + Configurator
DefaultValue adapter + security-invariant integration + 25
regression-тестів + real-server acceptance checklist) має надто великий
blast radius для одного review-циклу і суперечить принципу "мінімальний
повний зворотно-сумісний крок" (`.claude/CLAUDE.md`, "Minimal scope of
change"). Тому:

- **PR A (цей PR):** `modules/BRAVO.Configuration` — canonical
  `Get-BRAVODefaultConfiguration` (built-in raw defaults, включно з
  виправленням `ExcludedDrives = @()`), `Merge-BRAVOConfiguration`
  (generic deep-merge: hashtable-рекурсія, array replace, scalar replace,
  explicit `@()`, no mutation, immutability/deep-clone), `ConvertTo-
  BRAVONestedOverride` (dot-path -> nested, fail-closed на невідомий
  шлях — той самий контракт, що вже має `Invoke-
  BRAVOLocalConfigurationOverridePhase`, але застосовний ДО існування
  `$global:*`), `Resolve-BRAVORawConfiguration` (об'єднує три шари).
  **Жодних змін до `BRAVO_CONFIG_LOADER.ps1`, `BRAVO.config` чи
  entrypoint-ів немає** — це самодостатній, повністю протестований
  building block, який ще нікуди не підключено (тому не може зламати
  жодну поточну поведінку).
- **PR B (не в цьому PR):** підключення `BRAVO.Configuration` у
  `BRAVO_CONFIG_LOADER.ps1` — снапшот-виконання `BRAVO.config` в
  ізольованому scope, `-ConfigPath` explicit/auto-intent контракт
  (розділ 7 ТЗ), `RuntimeRoot != ConfigRoot` незалежність (розділ 9),
  автоматична відсутність `BRAVO.config` = normal path, security
  invariant re-validation (розділ 14), Configurator `DefaultValue`
  adapter (розділ 15.2).
- **PR C (не в цьому PR):** прибирання дублюючого derivation-коду з
  канонічного шаблону `BRAVO.config` (щоб нові інсталяції не виконували
  derivation двічі), documented compatibility policy для дуже старих
  config, install/update preservation tests (розділ 18), real-server
  acceptance matrix (розділ 24).

Кожен проміжний стан лишається internally consistent: після PR A
жодна виробнича поведінка не змінюється (модуль існує, але нічим не
використовується); PR B — перший PR, що реально вмикає "BRAVO працює
без BRAVO.config"; PR C закриває залишковий технічний борг (подвійний
discovery для legacy-файлів, install-path перевірки).
