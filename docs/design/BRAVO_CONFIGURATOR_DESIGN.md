# BRAVO Configurator — заморозка архітектури (Agent 0)

> Статус (оновлено): architecture freeze (§1-9) завершено, і весь описаний
> цикл реалізовано й змерджено в `developer`: PR #112 (P0 backend), PR #113
> (P1 UI/Presets/Credentials/Preview), PR #114 (WinForms closure-scope fix),
> PR #115 (P2-A reliability/UX correctness), PR #116 (P2-B responsive/DPI/
> accessibility), PR #117 (preset/BAZA-local addendum). `BRAVO_CONFIGURATOR.ps1`
> і `modules/BRAVO.Configurator/*` існують у `developer` (див. CHANGELOG.md,
> розділ «Не випущено (developer)», запис про `BRAVO_CONFIGURATOR.ps1`).
>
> **IMPLEMENTATION MERGED.** Описаний тут implementation scope (backend,
> UI, Presets, Credentials, Preview, responsive/DPI-safe WinForms) змерджено
> в `developer`. Відповідні implementation PR містять зафіксовані
> automated/headless (`selftest\BRAVO_SELF_TEST.ConfiguratorUI.ps1` та
> суміжні), launch-smoke та static-analysis (`PSScriptAnalyzer`) перевірки
> там, де вони були застосовні — це НЕ універсальний claim, що кожен PR
> #112–#117 окремо пройшов ідентичний набір перевірок; таке per-PR
> підтвердження не встановлювалось.
>
> **MANUAL / INTERACTIVE ACCEPTANCE — НЕ ПІДТВЕРДЖЕНО.** Merge implementation
> сам по собі НЕ доводить, що пізніші manual/interactive acceptance-кроки
> виконано. §12.6 нижче явно фіксує **NOT EXECUTED** у сесії PR #116
> (P2-B): інтерактивний click-through (Tab-навігація, Boolean tri-state
> через реальний UI, invalid-input-повідомлення, Preview-resize, F1/Ctrl+F
> наживо), візуальна перевірка кирилиці/clipping/scrollbars, і DPI
> 100/125/150% матриця. Перевірено (`git log --oneline --merges`,
> `CHANGELOG.md`, увесь `docs/**`) — жодного пізнішого PR або запису з
> фактичним evidence цих manual/DPI-кроків не знайдено; їх завершення
> **не варто вважати доведеним** без окремого owner-підтвердженого
> acceptance-запису.
>
> Розділи нижче (початково §9 "Відкрите питання для власника перед стартом
> Agent 1-6", і end-of-§12.6 "STOP після звіту, без merge") збережено як
> historical design-gate record того, що обговорювалось/вирішувалось на
> кожному етапі; в частині "implementation merged" вони більше не
> відображають поточний production-стан (backend/UI/Presets/Credentials/
> Preview вже змерджені), але в частині "manual/DPI acceptance NOT
> EXECUTED" (§12.6) вони лишаються актуальними — цей пробіл не закрито.

Статус (первинний): **DRAFT — architecture freeze для перегляду перед
стартом Agent 1-6.**
Гілка: `feat/bravo-configurator` (первинно базована на `origin/developer` @
`9d0ece8`; перебазована на `origin/developer` @ `0e63fdc` після інтеграції
`hotfix/5.2.2` — PR #111, "P0 reconciliation after 5.2.2" нижче, §2).
Не чіпає `master`/RC-гілки; не змінює production runtime.

## 1. Канонічне джерело істини (verified, не припущення)

- **`BRAVO.config`** (1288 рядків) — canonical defaults. Виконується як PowerShell
  script з `param(ConfigRoot, RuntimeRoot)`; містить ~50 `$global:*Settings`
  блоків, частина з яких — **похідні** (`effectiveLimsRoot`, `bazaSyncEffective`,
  `archiveDirs`, `sourcePaths`, `bazaAppPaths`, `bazaWWWPaths`, `archiveDefinitions`
  тощо), а не configurable input.
- **`BRAVO.local.config`** — data-only hashtable `'dot.path' = value`, завантажується
  `Read-BRAVOLocalConfigurationOverrides` (`BRAVO_CONFIG_LOADER.ps1:276`) через
  `[scriptblock]::CheckRestrictedLanguage([],[],$false)` — **виконуваний код
  відхиляється на рівні мови**, не лише конвенцією.
- **Канонічний перелік дозволених override-шляхів = сам
  `BRAVO.local.config.example`** (коментований, повний каталог) — це
  **єдине джерело істини** для Configurator schema inventory, не окрема
  ручна таблиця. Верифіковано скриптом (не вручну): **136 документованих
  override-ключів** (`CONFIGURABLE_TOTAL=136`, включно з кореневими
  скалярами без крапки в шляху — `logRetentionDays`, `sftpPort`,
  `LogLevel` тощо — які початковий grep без урахування single-segment
  ключів пропускав). `BRAVO.Configurator.Schema.psd1` містить рівно **138**
  дескрипторів, 1:1 з цим переліком (перевірено
  `Test-BRAVOConfiguratorSchemaCompleteness`, §4) — **136 базових + 2**,
  додані при P0 reconciliation after 5.2.2 (§2.1):
  `componentSettings.SFTP.Enabled`, `componentSettings.SMB.Enabled`.
- **Двофазне застосування overrides** (`BRAVO_CONFIG_LOADER.ps1:323`,
  `Invoke-BRAVOLocalConfigurationOverridePhase`) — критична семантика,
  яку Configurator **зобов'язаний** відтворювати, а не ігнорувати:
  - Фаза 1 (первинні поля: `bravoSettings`, `pathSettings`,
    `maintenanceSettings`, `componentSettings`, sftp/smb-скаляри) —
    застосовується ДО деривацій.
  - Фаза 2 (пізні блоки: `sftpDirectories`, `backupMonitoring`,
    `schedulerSettings`) — фінальні значення; похідні поля з інших
    полів **не переобчислюються** заново.
  - Проміжні вузли шляху не створюються — невідомий/помилковий шлях
    = помилка конфігурації в лоадері (typo-safety вбудований у сам
    контракт, Configurator має цю ж перевірку успадкувати, не дублювати).
- Заборонені для override (явно в шаблоні): похідні блоки (`sourcePaths`,
  `archiveDirs`, `bazaAppPaths`, `bazaWWWPaths`, `archiveDefinitions`),
  `discoverySettings`, `toolIntegritySettings`, runtime-шляхи
  (`ScriptPath`/`HelperPath`). Schema-inventory (Agent 1) повинен
  класифікувати ці шляхи як `ReadOnly=$true`/non-configurable, не як
  "забуті" — вони показуються в Effective view, але без editor control.

## 2. Canonical effective-resolver — стан на момент першого написання і після 5.2.2

**Історичний контекст (правильно на момент першого написання цього
документа, вже НЕ правильно після інтеграції `hotfix/5.2.2` — див. §2.1
нижче).** На `origin/developer` (до 5.2.2) **не існувало** централізованої
чистої функції на кшталт `Get-BRAVOEffectiveStorageConfiguration` для
SFTP/SMB master-child семантики. `Get-BRAVOEffectiveSynchronizationConfiguration`
(`BRAVO.Discovery.psm1:1340`) покривала лише BAZA sync-флаги, без жодного
глобального SFTP/SMB master-switch (той просто не існував як
конфігураційний контракт). Master/child логіка обчислювалась inline і
незалежно в кількох runtime-файлах: `BRAVO_DRY_RUN.ps1`,
`BRAVO_CREDENTIALS_SETUP.ps1`, `modules/BRAVO.Archive/BRAVO.Archive.Runtime.ps1`,
`modules/BRAVO.Health/BRAVO.Health.Runtime.ps1`.

Розділ 10 задачі прямо забороняє "вигадувати dependency semantics у GUI" і
вимагає canonical resolver. Централізація цієї логіки в новий
`Get-BRAVOEffective*` API була визнана окремим, ризикованим, cross-cutting
рефакторингом, який не варто змішувати з фіче-роботою Configurator
(`06-release-lifecycle.md`, "Do not combine broad refactoring with
unrelated features").

### 2.1. P0 reconciliation after 5.2.2 — resolver тепер існує

`hotfix/5.2.2` (інтегровано в `developer` через PR #111, комміт `0e63fdc`)
додав саме той canonical resolver, відсутність якого документована вище:

- `Get-BRAVOEffectiveStorageConfiguration` (`modules/BRAVO.Discovery/BRAVO.Discovery.psm1`) —
  згортає `componentSettings.SFTP.Enabled`/`SMB.Enabled` (нові global
  master-switches) з дочірніми прапорцями (`ArchiveUpload`/`ArchiveCopy`)
  ОДИН раз, включно з `DisabledReason`. Викликається з `BRAVO.config` в
  `$global:storageEffective` — **єдине джерело правди**, яке Archive,
  Health, Maintenance, Dry Run і Credentials Setup споживають напряму, не
  повторюючи "master AND child" самостійно.
- `Get-BRAVOEffectiveSynchronizationConfiguration` отримала параметр
  `-GlobalSftpEnabled` — `BAZA_APP_SFTP`/`BAZA_WWW_SFTP` тепер ТЕЖ гейтяться
  цим самим SFTP-master-ом.

**Технічний висновок (P0.7, не автоматичний рефакторинг "бо resolver тепер
є"):** повний Effective config (усі 138 шляхів, не лише SFTP/SMB) досі
вимагає прогону справжнього `Import-BravoConfiguration` — новий resolver
покриває лише вузьку підмножину (2 master-switches + 4 залежні поля), не
замінює потребу дочірньо-процесного механізму §2.2 нижче. **Мінімальний, а
не широкий рефакторинг:** дочірній процес тепер ДОДАТКОВО захоплює
`$global:storageEffective`/`$global:bazaSyncEffective` (раніше не
захоплювались), і Model-шар (`Resolve-BRAVOConfiguratorGatedEffective`,
`BRAVO.Configurator.Model.psm1`) читає EffectiveValue/DisabledReason для 4
master-gated шляхів (`SFTP.ArchiveUpload`, `SMB.ArchiveCopy`,
`Synchronization.BAZA_APP_SFTP`, `Synchronization.BAZA_WWW_SFTP`) з цих
canonical структур, а не з `$componentSettings` (завжди RAW). Жодна
master AND child арифметика не переізобретена в Configurator — лише "де в
canonical-виводі шукати правильне значення для цього Path".
`Import-BravoConfiguration` (child-процес) лишається канонічним
механізмом отримання ПОВНОГО effective config — рішення §2.2 нижче
залишається чинним.

### 2.2. Прийняте архітектурне рішення (уникає і дублювання, і небезпечного рефакторингу)

**Effective-value computation у Configurator = реальний прогін canonical
`BRAVO_CONFIG_LOADER.ps1` (`Import-BravoConfiguration`) в ізольованому
child-процесі проти кандидатної конфігурації**, а не переізобретення
resolver-ів у GUI. Той самий патерн (`Invoke-BRAVOAcceptanceChildProcess`),
що вже перевірений у `tools/acceptance/BRAVO_RC_ACCEPTANCE.ps1` для
non-destructive виконання реального RC runtime проти synthetic fixture.

Наслідок: `BRAVO.Configurator.Effective.psm1` **не містить бізнес-семантики
залежностей** — лише: (1) серіалізує candidate override-набір у тимчасовий
`BRAVO.local.config`, (2) запускає `BRAVO_CONFIG_LOADER.ps1` дочірнім
процесом проти synthetic `ConfigRoot`/`RuntimeRoot` (як і сам production
runtime), (3) серіалізує результуючі `$global:*Settings` назад у JSON,
(4) diff проти Default і проти попереднього Effective — виключно
презентаційна логіка. Це задовольняє "one canonical implementation policy"
без нового пререквізит-рефакторингу продакшн-модулів і без другого
незалежного config-engine.

Ціна рішення: кожен recompute Effective — реальний child-процес (~секунди,
не мілісекунди). Прийнятно для інтерактивного Preview/Apply, неприйнятно
для live-перерахунку "на кожен keystroke" — UI повинен дебаунсити
recompute (наприклад, на blur/commit поля, не on-change).

## 3. Модульні межі (freeze)

```text
BRAVO_CONFIGURATOR.ps1                    — тонкий entry point (bootstrap → GUI/CLI dispatch)

modules/BRAVO.Configurator/
  BRAVO.Configurator.psd1                 — module manifest, реекспорт публічного API
  BRAVO.Configurator.Schema.psd1          — data-only descriptor catalog (120+ leaf paths)
  BRAVO.Configurator.Schema.psm1          — schema completeness self-test helpers
  BRAVO.Configurator.Model.psm1           — Setting/Model: Default|Override|Effective|Dirty
  BRAVO.Configurator.Effective.psm1       — child-process canonical loader invocation (§2)
  BRAVO.Configurator.Validation.psm1      — semantic INFO/WARNING/ERROR, no I/O
  BRAVO.Configurator.Persistence.psm1     — baseline-hash, atomic apply, rollback
  BRAVO.Configurator.Presets.psd1         — preset definitions (data-only)
  BRAVO.Configurator.Presets.psm1         — preset application onto Model
  BRAVO.Configurator.Credentials.psm1     — Credential Manager status adapter (Agent 6)
  BRAVO.Configurator.UI.psm1              — WinForms shell, schema-driven controls
```

Залежність напрямку: `BRAVO_CONFIGURATOR.ps1 → UI → {Presets, Credentials} →
Model → {Schema, Effective, Validation} → Persistence`. UI ніколи не читає
`BRAVO.local.config` напряму — лише через Model. Жоден модуль Configurator
не є новим "Common/Utils" dumping-ground — кожен має один чіткий контракт
нижче.

## 4. Schema descriptor contract (Agent 1)

```powershell
@{
    Path        = 'componentSettings.SFTP.Enabled'   # exact BRAVO.local.config.example dot-path
    Group       = 'Storage'                            # навігаційна секція 1-10 (§6 задачі)
    Section     = 'SFTP'
    Label       = 'Увімкнути SFTP'                      # людська назва
    Description = '...'                                 # з коментаря BRAVO.config/example
    Type        = 'Boolean'                             # Boolean|String|Integer|Number|Enum|Time|Path|UNCPath|StringArray|NumberArray
    Phase       = 1                                      # 1 або 2 — з CONFIG_LOADER override-фаз
    Advanced    = $false
    ReadOnly    = $false                                 # true для похідних/discovery/toolIntegrity шляхів
    Secret      = $false
    AllowedValues = $null                                # для Enum
    Order       = 10
}
```

Джерело `Description`/`Label` — коментарі над відповідним ключем у
`BRAVO.local.config.example`/`BRAVO.config`; не вигадувати нові формулювання,
що суперечать існуючій документації.

## 5. Контракт Model API (Agent 2)

Одна `Setting` (immutable snapshot + explicit mutation function, без
прихованого стану):

```text
Get-BRAVOConfiguratorModel -SchemaCatalog -DefaultConfig -LocalOverrides
    -> Model[]  (Path, Metadata, DefaultValue, OverridePresent, OverrideValue,
                 EffectiveValue, Source, DisabledReason, ValidationState,
                 DependencyState, Dirty)
                 # DisabledReason (P0.8, 5.2.2): canonical причина Raw !=
                 # Effective для 4 master-gated шляхів
                 # (SFTP.ArchiveUpload/SMB.ArchiveCopy/BAZA_APP_SFTP/
                 # BAZA_WWW_SFTP) — читається напряму з
                 # storageEffective.SFTP/SMB.DisabledReason (§2.1), не
                 # генерується Configurator-ом; $null для решти шляхів.

Set-BRAVOConfiguratorOverride -Model -Path -Value   -> Model'  (Dirty=$true)
Clear-BRAVOConfiguratorOverride -Model -Path        -> Model'  (OverridePresent=$false)
Update-BRAVOConfiguratorEffective -Model            -> Model'  (перераховує §2 child-процесом; batched, не per-keystroke)
```

## 6. Persistence-транзакція (Agent 3)

15-крокова pipeline із задачі §5.2: Load → baseline hash → candidate (temp,
зі збереженням невідомих/newer ключів — §5.1) → parse
(CheckRestrictedLanguage, canonical loader) → schema validation →
dependency validation (canonical `Import-BravoConfiguration` через §2
child-process-механізм — подвійно слугує і Effective preview, і pre-apply
валідацією) → re-check baseline hash (race detection) → backup → atomic
replace (`Move-Item`/tmp+rename у тій самій директорії, не in-place write)
→ reload → verify → report. Baseline hash mismatch між Load і Apply =
**STOP**, без merge/overwrite.

### Кроки 8-9 (BRAVO_CONFIG_TEST / BRAVO_DRY_RUN) — НЕ blocking gate (verified finding)

Фактичний прогін показав, що обидва production-entrypoint-и непридатні як
сліпий exit-code gate для ізольованого candidate:
`BRAVO_CONFIG_TEST.ps1` жорстко фіксує `-ConfigRoot=$PSScriptRoot`, і
canonical security-guard `Test-BravoLegacyConfiguration`
(`BRAVO_CONFIG_LOADER.ps1:181`) навмисно відхиляє `-ConfigPath` поза цим
ConfigRoot (CODE!=DATA захист, не обходиться). `BRAVO_DRY_RUN.ps1` технічно
сумісний з ізольованим candidate, але його exit-code змішує config-
семантику з REAL_SERVER-залежними перевірками (Scheduled Tasks, служби) —
на dev-хості чи до `BRAVO_TASKS_INSTALL.ps1` він системно FAIL незалежно
від коректності candidate-конфігурації (той самий клас проблеми, що
вимагав окремого циклу category-aware allow-listing в
`tools/acceptance/BRAVO_RC_ACCEPTANCE.ps1` в іншій гілці — не
імпровізується тут без такого ж циклу верифікації). Кроки 6-7 (canonical
loader через Effective/Validation) уже покривають config-семантичну
валідацію без цього ризику; повний BRAVO_DRY_RUN -SkipCredentials лишається
можливим МАЙБУТНІМ інформаційним (не блокуючим) pre-apply звітом у UI.

### P0.3 (Iteration 2, незалежний review): "gap" між Configurator-валідацією і BRAVO_CONFIG_TEST закритий за конструкцією — доведено, не припущено

Independent review (Iteration 2, P0.1) підняв питання: якщо Кроки 8-9 не
блокують Apply, чи не бракує GUI Apply "еквівалентної canonical blocking
валідації", яку має `BRAVO_CONFIG_TEST.ps1`? Відповідь встановлена читанням
коду й emпіричним прогоном, не інтерпретацією:

`BRAVO_CONFIG_TEST.ps1` (весь файл — 89 рядків) не містить власної
валідаційної логіки. Він робить рівно один виклик:
`Import-BravoConfiguration -ConfigRoot $scriptRoot -ConfigPath $ConfigPath -PassThru`
і транслює будь-який виняток у ненульовий exit code; уся семантика
"валідно/невалідно" (restricted-language parse, unknown-key fail-closed
check `BRAVO_CONFIG_LOADER.ps1:758-767`, `Test-BravoLegacyConfiguration`
guard) належить самій `Import-BravoConfiguration`, не entrypoint-у навколо
неї.

`BRAVO.Configurator.Effective::Invoke-BRAVOConfiguratorEffectiveComputation`
викликає **ту саму** функцію з тим самим контрактом:
`Import-BravoConfiguration -ConfigRoot $isolatedRoot -RuntimeRoot $RuntimeRoot -PassThru`
(незалежний `-ConfigRoot`/`-RuntimeRoot` — параметр, спеціально
призначений саме для "конфіг в іншому каталозі, ніж modules\" — легітимне
використання, не обхід guard-а: `Test-BravoLegacyConfiguration` вимагає
лише щоб `ConfigPath` був під `ConfigRoot`, і обидва виклики це
задовольняють). Після P1-фіксу independent review (`Test-BRAVOConfiguratorCandidateOverrides`
тепер прогонить Effective із ПОВНИМ `$MergedOverrides`, а не
schema-відфільтрованою проєкцією) Configurator реально виконує ідентичний
canonical виклик на ідентичному candidate ДО Apply.

Емпірично підтверджено (не лише прочитано код): свідомо зламаний
candidate (`thisRootDoesNotExist.BrokenLegacyField`) прогнаний через (a)
реальний `BRAVO_CONFIG_TEST.ps1` в ізольованому fixture і (b) через
`Test-BRAVOConfiguratorCandidateOverrides` — обидва відхиляють з
ІДЕНТИЧНИМ повідомленням, що походить з ОДНОГО throw-сайту
(`BRAVO_CONFIG_LOADER.ps1:764`, "не вдалося застосувати ключ(і)"). Той
самий сценарій закріплено як self-test regression (scenario 20,
`selftest\BRAVO_SELF_TEST.Configurator.ps1`).

**Висновок:** Option A ("reusable validation API, спільна для
BRAVO_CONFIG_TEST і Configurator") вже виконана за конструкцією —
`Import-BravoConfiguration` і Є тим спільним canonical validation API;
`BRAVO_CONFIG_TEST.ps1` ніколи не мав окремої логіки, яку требa було б
"еквівалентно" відтворювати. Жодної зміни в production
`BRAVO_CONFIG_TEST.ps1`/`BRAVO_CONFIG_LOADER.ps1` не знадобилося й не
виконано. Єдине, чого Configurator НЕ відтворює (і навмисно) — це
REAL_SERVER-залежна частина `BRAVO_DRY_RUN.ps1` (Scheduled Tasks/служби),
яка вже задокументована вище як окрема, свідомо не-config перевірка.
Позначку "Configurator Apply = DEVELOPMENT ONLY" знято для
config-семантичної валідації; вона й далі відсутня для REAL_SERVER-класу
перевірок, які ніколи не були частиною Apply-контракту цього backend-а.

## 7. Мапа навігації UI

Приймається без змін навігаційна структура з §6 задачі (10 груп: Загальні /
Шляхи та дані / Компоненти / Maintenance / Storage / Health / Scheduler /
Console-Logging / Credentials / Effective configuration) — узгоджується з
138-key inventory (§1, після P0 reconciliation).

## 8. План тестування (Agent 7)

Мінімум із §22 вихідного документа, плюс: **regression test для §2 Effective
child-process механізму** — canonical loader, викликаний Configurator-ом,
має повертати той самий результат, що і production
`BRAVO_ARCHIV.ps1`/`BRAVO_DRY_RUN.ps1` на ідентичному fixture
(характеризаційний тест, не дублюючий reimplementation).

## 9. Відкрите питання для власника перед стартом Agent 1-6

Обсяг цієї задачі (§18-22 вихідного документа: ~9 модулів, WinForms UI,
persistence, presets, credentials-адаптер, повний test suite, docs) —
багатоденний обсяг роботи. Architecture freeze (цей документ) завершено;
перед масовим кодуванням потрібне рішення власника про темп/розбивку
подальшої роботи на окремі review-порції (Agent 1+2+3 backend спочатку,
або паралельний запуск усіх — впливає на розмір і кількість наступних
PR-ів згідно §20 задачі). **Вирішено: backend спочатку (P0, завершено й
merged), UI/Presets/Credentials/Preview — окрема ітерація (P1, цей
розділ).**

## 10. P1 — UI/Presets/Credentials/Preview architecture

### 10.1. Model/UI межа

UI НІКОЛИ не читає `$global:*Settings` чи будь-яку canonical runtime-
структуру напряму — виключно через `BRAVO.Configurator.Model` API
(`Setting[]`: Path/Metadata/DefaultValue/OverridePresent/OverrideValue/
EffectiveValue/EffectiveSource/DisabledReason/ValidationState/
DependencyState/Dirty). Кожна зміна в UI — виклик
`Set-BRAVOConfiguratorOverride`/`Clear-BRAVOConfiguratorOverride`, що
повертає НОВИЙ масив-модель (immutable snapshot); UI зберігає лише
поточний знімок у власному стані форми. Жоден UI control не пише файл
напряму — єдиний шлях до диска: `Invoke-BRAVOConfiguratorApply`.

`BRAVO.Configurator.UI` (`modules/BRAVO.Configurator/BRAVO.Configurator.UI.psm1`)
розділяє WinForms-специфічний код (побудова Form/TreeView/Controls) від
чистих, headless-тестованих функцій без жодного `System.Windows.Forms`-
типу в сигнатурі: `Get-BRAVOConfiguratorUIReachablePaths` (coverage-доказ:
кожен Path зі схеми потрапляє в UI механічно, не через хардкод-форму),
`Get-BRAVOConfiguratorUIFilteredSettings` (All/Changed/Active/Problems/
Advanced), `Get-BRAVOConfiguratorUISearchMatches` (пошук за Path/Label/
Description/Group), `Get-BRAVOConfiguratorUICategoryTree` (Group/Section
зі схеми — не хардкоджена структура). Це дозволяє self-test-у перевірити
UI-логіку в CI без інтерактивного desktop/ShowDialog().

### 10.2. Presets (`BRAVO.Configurator.Presets`)

Чисті model-трансформації — `Invoke-BRAVOConfiguratorPreset -Model -PresetName`
повертає НОВИЙ Model[], торкаючись ЛИШЕ `componentSettings.SFTP.Enabled`/
`componentSettings.SMB.Enabled` (master-switches; ніколи дочірніх
прапорців — вони лишаються тим, чим були, канонічний master AND child
контракт сам вирішує ефективну поведінку). `Current`/`Manual` — no-op.
Жоден preset не пише файл; результат іде через звичайний
Update-BRAVOConfiguratorEffective -> Preview -> Apply той самий шлях, що
й ручне редагування.

### 10.3. Credentials (`BRAVO.Configurator.Credentials`)

Секрети НІКОЛИ не входять у Configurator model (сьогодні жоден
schema-дескриптор не має `Secret=$true`). Requirement-формула
(`Get-BRAVOConfiguratorCredentialRequirement`) обчислюється з canonical
`storageEffective`/`bazaSyncEffective`/`backupMonitoring` структур —
ідентична вирazу в `BRAVO_CREDENTIALS_SETUP.ps1::Resolve-RequestedComponents`.
Ця формула НЕ винесена в спільну canonical функцію: `BRAVO_CREDENTIALS_SETUP.ps1`
є executing entrypoint-скриптом (param() -> function defs -> top-level
try{} з реальними записами/інтерактивними запитами), НЕ importable
module — dot-source для "лише функцій" фактично запустив би повний
credential setup flow. Це задокументована, вузька, обґрунтована виключна
дублювання (не "вигадана" семантика — той самий вираз, з тих самих
canonical джерел), а не нова незалежна політика.

Found/Missing статус (`Invoke-BRAVOConfiguratorCredentialCheck`) — РЕАЛЬНИЙ
non-destructive прогін `BRAVO_CREDENTIALS_SETUP.ps1 -Action Test -Component X`
дочірнім процесом (canonical exit-code контракт: 0=знайдено, 1=Missing/
Error) — без жодного незалежного читання Windows Credential Manager чи
дублювання target-name resolution. "Налаштувати"
(`Invoke-BRAVOConfiguratorCredentialSetup`) запускає той самий скрипт
`-Action Ensure` інтерактивно в тій самій консолі — Configurator ніколи
не бачить, не збирає й не передає секрет.

### 10.4. Preview (`BRAVO.Configurator.Preview`)

`Get-BRAVOConfiguratorPreview -ModelBefore -ModelAfter [-RequirementStateBefore] [-RequirementStateAfter]`
— чистий diff двох уже обчислених Model[] (і опційно двох Credential-
знімків): RawChanges (OverridePresent/OverrideValue), EffectiveChanges
(EffectiveValue + DisabledReason), CredentialChanges (Required
before/after), Warnings/BlockingErrors (з `Invoke-BRAVOConfiguratorValidation`
над ModelAfter). Жодної I/O, жодної canonical-логіки — лише порівняння.
Explicit фільтр `Metadata.Secret=$true` (сьогодні завжди порожній набір,
але явний, не покладений на випадковість поточного стану схеми).

### 10.5. Canonical candidate validation gate (P1.2)

**Вже закритий за конструкцією, без додаткової роботи** — той самий
висновок, що §6 "P0.3" вище: `Test-BRAVOConfiguratorCandidateOverrides`
(Persistence, кроки 4-7) прогонить candidate через справжній
`Import-BravoConfiguration` (canonical loader) ПЕРЕД будь-яким записом —
`Apply` кнопка НЕ потребує додаткового disable/gate понад те, що
Validation вже блокує (`HasBlockingErrors`). Жодного окремого
`BRAVO_CONFIG_TEST.ps1`/`BRAVO_DRY_RUN.ps1` виклику не додано — той самий
обґрунтований вибір, що P0.3, лишається чинним.

### 10.6. E2E Apply flow і конфлікт паралельної зміни

```
Launch -> Get-BRAVOConfiguratorProductionOverrideState (baseline)
       -> Get-BRAVOConfiguratorSchemaCatalog
       -> Get-BRAVOConfiguratorModel (Default + поточні overrides)
       -> Update-BRAVOConfiguratorEffective
       -> [оператор редагує / застосовує preset]
       -> Invoke-BRAVOConfiguratorValidation (Apply вимкнено, якщо HasBlockingErrors)
       -> Get-BRAVOConfiguratorPreview (RawChanges/EffectiveChanges/CredentialChanges/Warnings/BlockingErrors)
       -> [оператор підтверджує]
       -> Invoke-BRAVOConfiguratorApply
            (re-check baseline hash -> RaceDetection STOP, якщо змінився;
             backup -> atomic replace -> reload -> verify)
       -> reload production state + перерахувати Effective для UI
```

Race: якщо `Invoke-BRAVOConfiguratorApply` повертає `Stage='RaceDetection'`,
UI показує: "BRAVO.local.config was changed by another process. Your
changes were NOT written. Reload configuration before applying your
changes." — без auto-merge; оператор явно перезавантажує (заново
Get-BRAVOConfiguratorProductionOverrideState + перебудова моделі).
`Invoke-BRAVOConfiguratorApply` НІКОЛИ не кидає виняток (P1.1-фікс:
Serialization-стадія теж повертає структурований `Applied=$false`) — UI
завжди отримує предбачуваний `{Applied, Stage, Reasons}`, не try/catch
навколо непередбачуваного винятку.

## 11. P2-A — Reliability & UX correctness

Пост-P1-стабілізаційний цикл (закриття P0/P1 стабілізації, PR #113/#114,
`developer`@`8bd022a`). Мета — correctness/reliability gaps, знайдені під
час P1-стабілізації, ДО будь-якого косметичного P2-B redesign (High DPI,
1024x768, keyboard navigation тощо — окрема майбутня ітерація).

### 11.1. AtomicReplace / PostApplyVerification — hermetic failure-injection

Обидва `Stage`-и вже мали production-контракт (P1-фікс: fail-closed,
автоматичний rollback для PostApplyVerification) — бракувало лише
targeted regression-тесту, що реально форсує кожен збій.

- **AtomicReplace**: жодного test-only seam не знадобилось — `Move-Item
  -Force` (крок 12) реально провалюється, якщо production-файл відкритий
  handle-ом БЕЗ `FileShare.Delete` (Windows rename-семантика); self-test
  відкриває такий handle перед `Invoke-BRAVOConfiguratorApply` і закриває
  його в `finally`. Детерміновано, без залежності від таймінгу.

  **Реальна знахідка (не гіпотетична)**: цей тест ПАДАВ під повним
  `BRAVO_SELF_TEST.ps1` (хоча проходив в ізольованому фокусованому
  прогоні) — `Move-Item`/`Copy-Item` у кроках 11-12 не мали явного
  `-ErrorAction Stop`, тому успадковували `$ErrorActionPreference`
  ВИКЛИКАЧА; коли ambient-значення виявлялось `'Continue'` (витік з
  іншого доменного фрагмента self-test-а в тому самому процесі —
  попередня, окрема, вже наявна крихкість, не в межах цього P2-A циклу),
  файлова `IOException` НЕ termінувала `try`, `catch` ніколи не
  спрацьовував, і `Invoke-BRAVOConfiguratorApply` МОВЧКИ повертав
  `Applied=$true, Stage='Complete'`, хоча запис фізично НЕ відбувся —
  §07 BRAVO Runtime Safety Invariants fail-closed порушення. Root-cause
  фікс: явний `-ErrorAction Stop` на кожному load-bearing файловому
  cmdlet-виклику в кроках 11-12 (backup `Copy-Item`, `Move-Item`) — крок
  11 (backup) тепер має власний structured `Stage='Backup'` провал,
  раніше взагалі не мав власного try/catch. Той самий клас дефекту
  знайдено й виправлено в PostApplyVerification rollback-шляху
  (`Copy-Item` відновлення з backup, §11.1 нижче) і в
  `BRAVO.Configurator.Effective::New-BRAVOConfiguratorIsolatedConfigRoot`
  (менш критично — гірша діагностика, не хибний success). Підтверджено
  повторним прогоном фокусованого self-test-у під явним
  `$ErrorActionPreference='Continue'` (відтворює умову збою) — PASS
  після фіксу.
- **PostApplyVerification**: кроки 13-14 (reload + rollback-on-failure)
  винесено з `Invoke-BRAVOConfiguratorApply` в окрему публічну функцію
  `Test-BRAVOConfiguratorPostApplyVerification` (той самий контракт, той
  самий текст повідомлень — чиста екстракція, не зміна поведінки). Це
  дозволяє self-test-у викликати верифікацію напряму на деліберативно
  зіпсованому "щойно записаному" файлі (canonical `CheckRestrictedLanguage`
  відхиляє `$env:`-звернення), без залежності від race-вікна файлової
  системи. Повертає `$null` при успіху, або
  `[pscustomobject]@{ Applied=$false; Stage='PostApplyVerification'; Reasons; BackupPath }`
  при провалі — `Invoke-BRAVOConfiguratorApply` лишається тонким
  викликачем цієї функції.

### 11.2. Dirty — справжній diff, не подієвий прапорець

**Знайдений P3 (P1-стабілізація): "phantom Dirty"** — `Model[].Dirty`
виставлявся `$true` в `Set-/Clear-BRAVOConfiguratorOverride` і ніколи не
скидався назад, тому статус "Є незбережені зміни" лишався правдивим
назавжди навіть після edit → revert до оригінального значення.

**Фікс**: нова canonical чиста функція
`Test-BRAVOConfiguratorModelDirty -Model -BaselineOverrides`
(`BRAVO.Configurator.Model.psm1`) — порівнює поточний
`OverridePresent`/`OverrideValue` КОЖНОГО schema-запису з
`$BaselineOverrides` (той самий hashtable, що
`Get-BRAVOConfiguratorProductionOverrideState.Overrides` повертає при
Load/Reload/успішному Apply — вже існуючий знімок, що Persistence
використовував для race detection). `OverridePresent` сам по собі — частина
diff (не лише значення): "false override" ніколи не еквівалентний
"відсутньому override". Масиви порівнюються поелементно через уже наявний
`Test-BRAVOConfiguratorValueEquality` (та сама функція, що `EffectiveSource`
використовує). `Model[].Dirty`-поле саме по собі лишилось у формі моделі
(вже expected shape для існуючих споживачів), але статус-бар UI
(`Get-BRAVOConfiguratorUIDirtyState`, private, `BRAVO.Configurator.UI.psm1`)
тепер делегує до `Test-BRAVOConfiguratorModelDirty` проти
`$State.ProductionBaseline.Overrides`, а не до застарілого прапорця.

### 11.3. Exit-семантика — рішення: KEEP exit 0 + structured result

Configurator — інтерактивний desktop-інструмент, не scheduled SYSTEM-
завдання (див. коментар на початку `BRAVO_CONFIGURATOR.ps1`) і НЕ
учасник canonical `BRAVO.ExitCodes`-контракту сьогодні; жоден
automation-caller не розрізняє exit-код Configurator-а. Введення нових OS
exit-кодів без жодного реального споживача суперечило б
"Do not invent... exit-code semantics" і мінімальному обсягу зміни.

Замість цього `Show-BRAVOConfiguratorMainForm` повертає структурований
рядок-результат — `'Applied'` / `'Cancelled'` / `'NoChanges'` — викликачу,
через `Get-BRAVOConfiguratorSessionOutcome` (Model.psm1, чиста функція,
покрита headless-тестами).

**Correction (після початкового P2-A.4):** перша версія оцінювала
Cancelled/NoChanges проти *первинного* baseline сесії
(`InitialBaselineOverrides`, знімок на момент Launch) і давала Applied
абсолютний пріоритет над будь-яким подальшим diff. Це давало два хибні
результати: (1) `Launch A -> зовнішня зміна на диску -> Reload -> Close
без edits` повертав `Cancelled`, хоча `ProductionBaseline` уже оновлено
Reload-ом і незбережених змін немає; (2) `Apply успішний (baseline ->
B) -> подальший edit -> Close без повторного Apply` повертав `Applied`,
приховуючи реальні незбережені зміни, які оператор фактично відкинув.

Виправлений контракт оцінює diff проти **поточного**
`$state.ProductionBaseline.Overrides` (той самий canonical знімок, що
race detection у Persistence і status-bar/close-confirmation Dirty вже
використовують — оновлюється Load/Reload і кожним успішним Apply), з
пріоритетом:

```text
currentDirty = Test-BRAVOConfiguratorModelDirty(Model, ProductionBaseline.Overrides)

if currentDirty:      Cancelled   # незбережений diff на момент закриття
elif AnyApplySucceeded: Applied   # принаймні один Apply відбувся, diff відсутній
else:                  NoChanges
```

`InitialBaselineOverrides` видалено зі `$state` — окремого знімка
первинного baseline сесії більше не потрібно.

`BRAVO_CONFIGURATOR.ps1` виводить відповідний текст оператору й лишає
`exit 0` для всіх трьох — це навмисно, не недогляд.

### 11.4. Reset setting / Reset section

Reset одного setting уже існував як побічний ефект зняття
override-checkbox у рядку (`Clear-BRAVOConfiguratorOverride` — §1.3:
"Використовувати default" видаляє override, не матеріалізує `False`).
Формалізовано під явним ім'ям — `Reset-BRAVOConfiguratorSetting` (тонка
обгортка над `Clear-BRAVOConfiguratorOverride`, той самий контракт).

Reset секції (bulk-операція, якої раніше не було) —
`Reset-BRAVOConfiguratorSection -Model -Group -Section`: скидає ЛИШЕ
overrides settings цієї конкретної `Metadata.Group`/`Metadata.Section`
пари; інші секції та будь-який preserved unknown/newer ключ (Model про
нього нічого не знає — persist йде через
`Merge-BRAVOConfiguratorCandidateOverrides`, не через Model) лишаються
незмінними. UI: кнопка "Скинути секцію" в нижній панелі, активна лише
коли в дереві категорій обрано КОНКРЕТНУ секцію (не групу цілком), з
підтвердженням через `MessageBox`, якщо в секції дійсно є активні
override.

### 11.5. Temp-cleanup diagnostics — DEFERRED (без зміни production-коду)

`Remove-Item ... -ErrorAction SilentlyContinue` для GUID-ізольованих temp-
директорій (Persistence/Effective) лишається без diagnostic-логування.
Canonical logging-інфраструктура існує в репозиторії (`BRAVO.Logging`),
але Configurator НЕ ініціалізує її сьогодні (немає `Initialize-BRAVOLog`
у `BRAVO_CONFIGURATOR.ps1` — інтерактивний desktop-інструмент, не
scheduled-завдання з власним LOGS-каталогом). Додавання повного
`Initialize-/Complete-BRAVOLog` життєвого циклу навколо всієї інтерактивної
сесії заради діагностики best-effort cleanup — непропорційний ризик
(нова залежність, новий log-файл, нове failure-mode) для non-blocking
знахідки. Лишається ACCEPTED/DEFERRED (той самий disposition, що
P1-стабілізація вже зафіксувала) до появи canonical UI-рівня
diagnostic-механізму, придатного для Configurator без цього overhead.

### 11.6. Launch-smoke harness

`ci/acceptance/Test-BRAVOConfiguratorLaunch.ps1` — детермінований,
НЕ-CI-gate local acceptance-скрипт (поруч з `ci/Test-BRAVO*.ps1` gate-
скриптами, але в окремій `acceptance/` підпапці — щоб не виглядати як
блокуючий gate; canonical `Tools/` (WinSCP/7-Zip бінарники,
`TOOLS_MANIFEST.json`) навмисно НЕ використано — інша, security-чутлива
відповідальність, не місце для тестового скрипта). Покриває те, що
`selftest\BRAVO_SELF_TEST.Configurator*.ps1` навмисно НІКОЛИ не покриває —
обидва фрагменти headless, ніколи не конструюють `System.Windows.Forms.Form`,
саме цей розрив пропустив P1 `GetNewClosure()`-дефект повз 1572 self-test
PASS. Запускає `BRAVO_CONFIGURATOR.ps1` реальним дочірнім процесом проти
ІЗОЛЬОВАНОЇ `-ConfigPath` (порожня тимчасова директорія — реальний
production `BRAVO.local.config`/Credential Manager не читається/пишеться;
`$RuntimeRoot`, модулі й `RUNTIME_MANIFEST.json` лишаються справжнім
комплектом — саме їх цілісність перевіряється), чекає N секунд,
підтверджує, що процес живий (дійшов до блокуючого `ShowDialog()` без
винятку), інакше зчитує stdout/stderr і повертає FAIL, потім гарантовано
`Kill()`-ить процес. Навмисно НЕ призначений як блокуючий GitHub-hosted
Windows CI gate (non-interactive/non-windowing сесія може поводитись
непередбачувано для реального WinForms `Form`) — лише документований
local acceptance-крок для реальної десктопної Windows-сесії.

## 12. P2-B — Responsive WinForms UX, DPI, keyboard/context help

Гілка `feat/bravo-configurator-p2b-ux` від `origin/developer @ db8d955`
(merge PR #115). Мета — UX/visual hardening `BRAVO.Configurator.UI`
БЕЗ жодної зміни Schema/Effective/Persistence/Presets/Credentials/Dirty/
session-outcome/fail-closed контракту (§§1-11 вище лишаються чинними без
змін). Увесь код лишається в `BRAVO.Configurator.UI.psm1`/`.psd1` і
`selftest\BRAVO_SELF_TEST.ConfiguratorUI.ps1` — інші `BRAVO.Configurator.*`
модулі не торкались.

### 12.1. Responsive layout

Fixed-layout борг (`$form.Width=1150`/`Height=780`, `$rowPanel.Width=700`,
абсолютні `Point(x,y)` у top/bottom toolbar-ах, `SplitterDistance=220/620`
без урахування реального розміру) прибрано. Замінено на:

- **Головна форма**: `TableLayoutPanel`/`FlowLayoutPanel` з
  `Dock`/`AutoSize`/`WrapContents` для top-toolbar (2 рядки: пошук/
  фільтр/пресет; креденшели) і bottom-панелі (статус | дії, `FlowLayoutPanel`
  з `WrapContents=$true`).
- **Рядок налаштування**: `TableLayoutPanel` 3 responsive-колонки
  (38%/37%/25%: override+label | editor | status) замість фіксованих
  `Width=700`/`Point(275,2)`/`Point(545,5)`. `AutoEllipsis` на
  checkbox/status — довгі українські підписи не виштовхують сусідні
  контролі за межі рядка; underlying Model-дані не обрізаються, лише
  візуальний текст.
- **Splitter-и**: `Panel1MinSize`/`Panel2MinSize` + чиста
  `Get-BRAVOConfiguratorUIClampedSplitterDistance` (headless-тестована) —
  `SplitterDistance` ніколи не призначається поза легальним діапазоном.
  Реальний launch-крash (`SplitterDistance must be between Panel1MinSize
  and Width - Panel2MinSize`), спричинений призначенням `Panel1MinSize`/
  `Panel2MinSize` одразу після `New-Object SplitContainer` (до
  Dock-розміщення, коли контрол ще має дефолтний малий розмір) — знайдено
  й виправлено через реальний прогін `ci\acceptance\Test-BRAVOConfiguratorLaunch.ps1`
  (headless self-test цього патерну принципово не ловить — той самий
  клас розриву, що P1 `GetNewClosure()`-дефект, §11.6). MinSize тепер
  встановлюється ПІСЛЯ `$form.Controls.Add($mainSplit)`, коли `ClientSize`
  вже відповідає реальному стартовому розміру форми.
- **Компактний режим**: `Get-BRAVOConfiguratorUILayoutMode` (чиста,
  headless-тестована; поріг 1000px) визначає Wide/Compact; у Compact
  `rightSplit.Orientation` перемикається з `Vertical` (Details праворуч)
  на `Horizontal` (Details під Settings) — Option A з §13 задачі,
  той самий `SplitContainer`, лише зміна орієнтації, без перебудови
  контролів.

### 12.2. Startup-розмір і DPI

`Get-BRAVOConfiguratorUIStartupSize` (чиста функція) затискає стартовий
розмір і головної форми, і Preview-діалогу до `Screen.WorkingArea` —
ніколи не відкриває вікно більше за реальний робочий простір екрана;
respectує практичний мінімум (1000×650 для головної форми) лише якщо
робоча область це дозволяє. `AutoScaleMode=Dpi` — framework-рівень DPI-
масштабування (.NET Framework/WinForms), сумісний з Windows PowerShell
5.1. `Application.SetHighDpiMode`/PerMonitorV2-специфічний P/Invoke
НЕ використано (недоступно чи недоцільно для цього рантайму — рішення
свідоме, не недогляд).

**DPI acceptance-матриця (100%/125%/150%) — NOT EXECUTED** у цій сесії
(немає доступу до реального багатодисплейного/масштабованого Windows-
хоста в середовищі розробки). Структурні/headless-тести (`LayoutMode`,
`StartupSize`, `ClampedSplitterDistance`) виконано; реальна візуальна
DPI-перевірка потребує окремого acceptance-кроку на реальній Windows-
сесії з іншим масштабуванням.

### 12.3. Keyboard, context help, tooltips, accessibility

- `Ctrl+F` — фокус пошуку; `F1` — фокус Details, якщо обрано
  налаштування, інакше `Get-BRAVOConfiguratorUIGeneralHelpText`; `F5`/`Esc`
  викликають `PerformClick()` на існуючих `reloadButton`/`cancelButton` —
  ТОЙ САМИЙ обробник, що й кнопка (dirty-discard confirmation не
  обходиться жодним шляхом). Головна форма й далі НЕ має
  `AcceptButton=Apply`.
- Details-текст уніфіковано через чисту `Get-BRAVOConfiguratorUISettingHelpText`
  (операторський зміст — Назва/Опис/Поточний стан/Default/Local
  override/Effective/Effective source/Disabled reason — перед технічними
  Path/Group/Section/Type/Advanced); той самий текст обслуговує і
  Details-панель, і F1.
- Один спільний `System.Windows.Forms.ToolTip` (не по одному на рядок)
  для search/filter/preset/credential/action-кнопок і override-checkbox/
  status-мітки в кожному рядку.
- `AccessibleName`/`AccessibleDescription` на ключових контролах
  (search/filter/category tree/settings area/details/action-кнопки/
  credential-кнопки/override-checkbox/editor/status).
- Фільтр `All/Changed/Active/Problems/Advanced` — backend Id незмінний;
  `Get-BRAVOConfiguratorUIFilterOptions` додає українську
  `DisplayMember`-проєкцію (Усі/Змінені/Активні/Проблеми/Розширені),
  `ComboBox.ValueMember='Id'` — filtering і далі керується Id, не
  відображуваним текстом.
- Статус (`Помилки: N Попередження: N Інфо: N`) і статус-мітка рядка
  (`EffectiveSource [*]` + tooltip з `DisabledReason`) лишаються
  текстовими; колір — додатковий, не єдиний носій сенсу.

### 12.4. Preview-діалог

`Show-BRAVOConfiguratorUIPreviewDialog` тепер resizable
(`MinimumSize`, стартовий розмір через ту саму `Get-BRAVOConfiguratorUIStartupSize`,
затиснутий до `WorkingArea` власника — `Screen.FromControl($Owner)`,
переданого явно з головної форми), `WordWrap=$false`+`ScrollBars=Both`
для технічного diff-тексту (довгі шляхи лишаються інспектованими через
горизонтальний скрол). `AcceptButton`/`CancelButton` і blocking-error
gate на кнопці підтвердження — без змін семантики.

### 12.5. Тести й регресія

`selftest\BRAVO_SELF_TEST.ConfiguratorUI.ps1` доповнено headless-тестами
для `Get-BRAVOConfiguratorUILayoutMode`/`-UIFilterOptions`/
`-UISettingHelpText`/`-UIGeneralHelpText`/`-UIStartupSize`/
`-UIClampedSplitterDistance` (breakpoint-межа, клампінг у нормальному й
межовому випадку, WorkingArea-пріоритет над Min) + точкова статична
регресія проти повторного внесення конкретних fixed-layout літералів
(`$rowPanel.Width=700`, `$form.Width=1150`, `$form.Height=780`) —
не блокує довільне використання `.Width` деінде.

### 12.6. Візуальна/DPI/click-through перевірка — межі цієї сесії

Реально виконано в цій сесії: headless self-test (усі
`ConfiguratorUI`-перевірки, включно з новими P2-B), `PSScriptAnalyzer`
(0 знахідок), і реальний `ci\acceptance\Test-BRAVOConfiguratorLaunch.ps1`
(процес доходить до блокуючого `ShowDialog()` без винятку, 0 orphans) —
саме цей крок і виявив реальний `SplitterDistance`-дефект вище.

**NOT EXECUTED** у цій сесії: інтерактивний click-through (Tab-навігація,
Boolean tri-state через реальний UI, invalid-input-повідомлення,
Preview-resize, F1/Ctrl+F наживо), візуальна перевірка кирилиці/
clipping/scrollbars, і DPI 100/125/150% матриця — вимагають реальної
інтерактивної Windows-desktop-сесії з відповідним обладнанням/
масштабуванням, недоступної в середовищі, де виконувалась ця робота.
Ці кроки лишаються обов'язковим наступним acceptance-кроком перед
рішенням про merge (§39-40 задачі P2-B: STOP після звіту, без merge).
