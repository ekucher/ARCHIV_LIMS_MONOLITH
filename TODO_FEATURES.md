# TODO FEATURES

Заплановані функціональні напрями BRAVO Archive. Цей файл фіксує рішення й критерії готовності, але не означає, що функції вже реалізовані або дозволені до production-розгортання.

## FEAT-001 — Config v2: package defaults + локальні overrides

**Статус:** planned  
**Пріоритет:** high  
**Залежності:** завершити поточний цикл Discovery; не змішувати з виправленнями source-of-truth.

### Мета

Відокремити версійовану конфігурацію продукту від налаштувань конкретної установи, щоб оновлення комплекту не перезаписувало production-параметри й не вимагало ручного merge великого виконуваного `BRAVO.config`.

### Цільова модель

- `BRAVO.defaults.psd1` — package defaults, входить до релізу та `RUNTIME_MANIFEST.json`.
- `%ProgramData%\BRAVO Archive\config\BRAVO.local.psd1` — лише локальні overrides, не входить до релізу й не містить секретів.
- Windows Credential Manager — єдине місце для секретів.
- Discovery result і baseline зберігаються як state, а не записуються в local config.
- Effective configuration формується в порядку: defaults → deep merge local overrides → schema validation → security invariants → discovery.

### Обов'язкові правила merge

- hashtable зливаються рекурсивно;
- scalar local override замінює default;
- масив local override повністю замінює default-масив;
- невідомий ключ або неправильний тип — fail-closed;
- `$null` дозволений лише для явно nullable-параметрів;
- критичні security-параметри не можна послабити звичайним local override.

### Сумісність і міграція

- loader перехідного періоду підтримує legacy `BRAVO.config` і config v2;
- `BRAVO_CONFIG_MIGRATE.ps1` переносить лише явно визначені site-specific поля;
- generated/discovered значення не повинні ставати постійними overrides;
- legacy config зберігається як backup і не видаляється автоматично;
- кожна міграція порівнює критичні effective values старого й нового форматів.

### Критерії готовності

- [ ] Додано модуль `BRAVO.Configuration`.
- [ ] Додано `BRAVO.defaults.psd1` і `BRAVO.local.example.psd1`.
- [ ] Реалізовано deterministic deep merge та schema validation.
- [ ] Config v2 завантажується як data-only формат без виконання довільного коду.
- [ ] Security invariants перевіряються після merge і блокують послаблення захисту.
- [ ] Legacy і config v2 дають еквівалентну effective configuration на контрольних фікстурах.
- [ ] Міграція має dry-run, backup і rollback.
- [ ] Self-test покриває unknown keys, type mismatch, array replacement, nullable values і security downgrade.
- [ ] `BRAVO_SETUP.ps1`, Archive, Health, Maintenance і Scheduler працюють з одним loader API.
- [ ] Документація містить точний шлях local config, ACL і процедуру відновлення.

### Не входить у перший PR

- автоматичне завантаження релізів;
- зміна Discovery-алгоритму;
- перейменування компонентів BAZA;
- зміна backup/retention поведінки;
- видалення legacy loader до завершення міграції всіх серверів.

---

## FEAT-002 — Атомарні версійовані релізи та rollback

**Статус:** planned  
**Пріоритет:** high  
**Залежності:** FEAT-001; стабільний release artifact; завершення branch/release policy.

### Мета

Виключити часткові оновлення, змішування модулів різних версій і ручну заміну файлів. Кожне оновлення має або повністю активувати перевірений deployment, або залишити попередній deployment активним.

### Цільова структура

```text
C:\Program Files\BRAVO Archive\
├── BRAVO_LAUNCHER.ps1
├── BRAVO_UPDATER.ps1
└── releases\
    ├── 4.4.2+08fd27a\
    └── 4.5.0+<build>\

C:\ProgramData\BRAVO Archive\
├── config\deployments\
├── state\active-deployment.json
├── state\update-journal.json
├── logs\
└── staging\
```

### Основні рішення

- release-каталог після встановлення незмінний;
- Планувальник запускає тільки стабільний `BRAVO_LAUNCHER.ps1`;
- launcher читає `active-deployment.json` і запускає entrypoint з абсолютними шляхами;
- deployment зв'язує точний release і точний config snapshot;
- pointer перемикається атомарною заміною малого JSON-файлу;
- rollback перемикає одночасно код і сумісний config snapshot;
- running process завершує роботу на тій версії, з якої стартував;
- updater не зупиняє BRAVO/Apache, а лише блокує старт нових BRAVO tasks і очікує завершення активних операцій.

### Транзакція оновлення

1. Preflight: права, mutex, вільне місце, поточний deployment.
2. Staging: розпакування package в унікальний каталог.
3. Verification: SHA-256, release manifest, runtime/tools manifests, VERSION.json.
4. Candidate validation: self-test, setup `-ValidateOnly`, dry-run, schema compatibility, credential access.
5. Pause: заборона нових BRAVO tasks без зупинки служб LIMS/Web.
6. Activation: фінальний release directory, config snapshot, атомарна заміна deployment pointer.
7. Post-check: dry-run і health через launcher.
8. Failure: автоматичне повернення попереднього deployment та фіксація failed candidate.

### Критерії готовності

- [ ] Додано мінімальний стабільний `BRAVO_LAUNCHER.ps1` без business logic.
- [ ] Усі scheduled tasks посилаються на launcher, а не на конкретний release-каталог.
- [ ] `active-deployment.json` містить release path, config snapshot, version, source commit, activation time і previous deployment.
- [ ] Активація deployment атомарна на одному NTFS-томі.
- [ ] Додано global mutex для updater і launcher-safe читання pointer.
- [ ] Додано staging, перевірку release artifact і fail-closed validation.
- [ ] Додано config snapshot для кожного deployment.
- [ ] Реалізовано `-Rollback` і `-ActivateDeployment`.
- [ ] Переривання живлення до pointer switch не змінює активну версію.
- [ ] Помилка post-activation health повертає попередній deployment.
- [ ] Update journal дозволяє діагностувати й відновити перервану транзакцію.
- [ ] Зберігаються активний, попередній і щонайменше один резервний успішний deployment.
- [ ] Failed deployments не видаляються до завершення діагностики або retention-періоду.
- [ ] Self-test покриває corrupt package, manifest mismatch, incompatible config schema, busy task, pointer corruption і rollback.
- [ ] Документовано ручне аварійне перемикання без запуску updater.

### Корінь довіри

Launcher і updater виконуються до runtime-перевірки конкретного релізу, тому мають бути мінімальними, захищеними ACL і в перспективі підписаними Authenticode. Release artifact повинен мати окрему контрольну суму та підписаний manifest.

### Не входить у перший PR

- автоматичне скачування з GitHub або іншого зовнішнього джерела;
- silent auto-update production-серверів;
- оновлення під час активного Archive/Maintenance;
- автоматичне видалення поточного або попереднього успішного deployment;
- зміна служб BRAVO, Apache або exchangAPI.

---

## FEAT-003 — Remote Fleet Telemetry over HTTPS/443

**Статус:** planned  
**Пріоритет:** high  
**Залежності:** базові етапи не залежать від FEAT-001/FEAT-002; передавання `deploymentId`, config schema/fingerprint та versioned config metadata інтегрується після FEAT-001/FEAT-002.

### Мета

Автоматично й централізовано відстежувати стан BRAVO Archive, Maintenance, Health і Windows Scheduled Tasks на всіх віддалених серверах, які знаходяться за NAT/Firewall і не можуть приймати вхідні підключення.

Цільова модель — **push telemetry самим сервером назовні через HTTPS/443**. На production-серверах не потрібні Zabbix Agent, WinRM, VPN або будь-який відкритий inbound-порт.

### Цільова схема

```text
Віддалений Windows Server
│
├── BRAVO runtime / Task Scheduler
├── BRAVO.Telemetry
├── локальний durable outbox
│
└── HTTPS POST :443
        ↓
BRAVO Telemetry Gateway
├── authentication / HMAC validation
├── PostgreSQL
├── heartbeat + overdue evaluator
├── Fleet Dashboard
└── інтеграція із Zabbix / notifications
```

### Контракт повідомлень

Мінімальний набір подій:

- `heartbeat` — періодичний стан сервера і scheduled tasks;
- `task.started` — BRAVO task фактично почав виконання;
- `task.finished` — task завершився з точним BRAVO exit code, duration і component results.

`task.finished` використовує існуючий формальний контракт `BRAVO.ExitCodes`; окрема паралельна класифікація помилок не створюється.

Кожне повідомлення має містити щонайменше:

- `schemaVersion`;
- `messageId` (UUID, глобально унікальний);
- `sentAt`;
- стабільний `serverId`;
- institution code/name;
- hostname;
- тип події;
- package version/build, коли доступно;
- task id/name/state;
- `exitCode` / `exitName` для завершених task;
- timestamps і duration;
- безпечні component results без секретів.

### Heartbeat і контроль відсутності запусків

Окреме Scheduled Task `BRAVO_TELEMETRY_HEARTBEAT` запускається орієнтовно кожні 5 хвилин і передає:

- поточний стан Task Scheduler;
- enabled/disabled;
- `LastRunTime`;
- `NextRunTime`;
- `LastTaskResult`;
- поточну BRAVO package version;
- стан локальної telemetry queue.

Початкові пороги централізованої оцінки:

- `ONLINE` — heartbeat не старший 10 хвилин;
- `STALE` — 10–15 хвилин;
- `OFFLINE/TELEMETRY_UNAVAILABLE` — понад 15 хвилин.

Для кожного task окремо контролюється `last successful run age`, а не лише останній exit code. Завдання вважається overdue, коли останній успішний запуск старший за його очікуваний інтервал + tolerance.

### Durable outbox і гарантована доставка

Telemetry не відправляється за принципом fire-and-forget.

```text
%ProgramData%\BRAVO\Telemetry\
├── Outbox\
├── State\
└── Logs\
```

Правила:

1. Event спочатку атомарно записується в локальний `Outbox`.
2. Після цього виконується HTTPS POST.
3. Після підтвердженого `200/202` event вилучається з active outbox або переноситься в sent/history відповідно до retention policy.
4. При network/TLS/API failure event залишається для retry.
5. Heartbeat/retry task повторно відправляє старі events у визначеному порядку.
6. Gateway використовує `messageId` як idempotency key та не створює дублікати при повторній доставці.
7. Outbox має bounded retention/size і не може безмежно заповнювати системний диск.

### Критичний принцип ізоляції

**Недоступність Telemetry Gateway ніколи не змінює бізнес-результат Archive/Health/Maintenance.**

Наприклад, успішний backup залишається `Success (0)`, навіть якщо HTTPS telemetry не відправилася. Telemetry failure записується окремо й event залишається в outbox. Моніторинг не має права перетворити успішний backup на failed backup.

### Ідентифікація сервера

Hostname не використовується як єдиний ідентифікатор.

Стабільний `serverId` формується з institution code та незмінного machine identity, наприклад Windows `MachineGuid` або окремого UUID, створеного під час enrollment:

```text
<InstitutionCode>-<MachineIdentity>
```

Hostname, IP, OS version і display name зберігаються як mutable metadata.

### Автентифікація та підпис

Кожен сервер має власний telemetry secret у Windows Credential Manager. Один глобальний ключ для всіх установ заборонений.

Запит містить:

```text
X-BRAVO-Server-ID
X-BRAVO-Timestamp
X-BRAVO-Message-ID
X-BRAVO-Signature
```

Підпис — HMAC-SHA256 від канонічного набору `serverId + timestamp + messageId + SHA256(body)`.

Gateway перевіряє:

- відомий `serverId`;
- HMAC;
- допустиме timestamp window;
- replay через `messageId`;
- JSON schema;
- максимальний request size;
- дозволений event type.

Ключі серверів ротуються незалежно.

### Заборонені telemetry-дані

Ніколи не передавати:

- SFTP/SMB/archive passwords;
- webhook URLs або tokens;
- private keys;
- WinSCP command line із credentials;
- повний конфіг із secret-bearing полями;
- raw logs без окремого контрольованого механізму.

### Центральний Telemetry Gateway

Мінімальні логічні компоненти:

```text
POST /api/v1/telemetry
server registry
authentication / HMAC verification
message deduplication
PostgreSQL persistence
heartbeat evaluator
task overdue evaluator
alert/event integration
fleet status API/dashboard
```

Мінімальні сутності даних:

```text
servers
heartbeats
task_runs
task_state
telemetry_messages
```

Gateway є єдиною точкою інтеграції із Zabbix/Discord/Slack або іншими централізованими системами. Віддалені Windows-сервери не отримують credentials до Zabbix API та не підключаються безпосередньо до внутрішньої monitoring infrastructure.

### Критерії готовності

- [ ] Додано модуль `BRAVO.Telemetry` без залежності від Zabbix Agent.
- [ ] Реалізовано versioned JSON telemetry schema.
- [ ] Реалізовано стабільний `serverId` та enrollment/bootstrap процедуру.
- [ ] Реалізовано локальний durable outbox з atomic write, retry, dedup і bounded retention.
- [ ] Реалізовано HTTPS client через стандартний TCP/443.
- [ ] Реалізовано per-server HMAC authentication із ключами у Windows Credential Manager.
- [ ] Реалізовано `heartbeat` із Task Scheduler state.
- [ ] Heartbeat працює незалежно від Archive/Maintenance runtime.
- [ ] Реалізовано `task.started` та `task.finished` для Archive/Health/Maintenance.
- [ ] `task.finished` передає формальний BRAVO exit code і duration.
- [ ] Недоступний gateway не змінює exit code основного BRAVO task.
- [ ] Gateway приймає повторні повідомлення idempotently за `messageId`.
- [ ] Gateway визначає ONLINE/STALE/OFFLINE та overdue task.
- [ ] Gateway зберігає історію task runs і поточний fleet state.
- [ ] Є централізований огляд institution → server → tasks → last success → version.
- [ ] Security tests покривають invalid HMAC, replay, stale timestamp, malformed JSON, oversized request і unknown server.
- [ ] Self-test перевіряє offline queue, retry, duplicate delivery і відсутність secret-bearing полів.
- [ ] Документовано disaster mode: gateway недоступний тривалий час, outbox full/retention, clock drift і key rotation.

### Не входить у перший PR

- повний Fleet Dashboard;
- Zabbix/Discord/Slack integration;
- remote command execution;
- remote script/update deployment;
- передавання raw logs;
- автоматичне керування сервером із gateway;
- зміна firewall/inbound rules на клієнтських Windows Server.

### Межі безпеки

FEAT-003 є **telemetry-only outbound channel**. Він не повинен непомітно перетворитися на канал віддаленого адміністрування. Будь-яка майбутня функція remote command/update потребує окремої threat model, окремого feature та окремого authorization protocol.

---

## Рекомендована послідовність реалізації

### FEAT-001 / FEAT-002

1. `BRAVO.Configuration`: defaults/local і legacy compatibility без зміни runtime-поведінки.
2. Config schema v2, міграція та regression tests.
3. Stable launcher і переведення Планувальника.
4. Versioned release directories та deployment pointer.
5. Manual package updater: staging, validation, activation, rollback.
6. Release ZIP, checksums, signed manifest і документація production rollout.

FEAT-002 не починається до стабілізації FEAT-001, оскільки без config snapshot rollback коду може активувати несумісну конфігурацію.

### FEAT-003

1. Telemetry schema + threat model + server identity.
2. Локальний durable outbox і retry без мережевої залежності runtime.
3. Heartbeat + Task Scheduler inspection.
4. HTTPS/443 client + per-server HMAC.
5. Мінімальний Telemetry Gateway + PostgreSQL + dedup.
6. `task.started` / `task.finished` інтеграція з BRAVO ExitCodes.
7. Offline/stale/overdue evaluator.
8. Fleet Dashboard і централізовані notifications/integrations.
9. Після FEAT-001/FEAT-002 — додати deployment ID, config schema/fingerprint і versioned deployment metadata.

Перші етапи FEAT-003 можуть розроблятися паралельно з FEAT-001. Кожний етап оформлюється окремим PR.