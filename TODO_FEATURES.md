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

## Рекомендована послідовність реалізації

1. `BRAVO.Configuration`: defaults/local і legacy compatibility без зміни runtime-поведінки.
2. Config schema v2, міграція та regression tests.
3. Stable launcher і переведення Планувальника.
4. Versioned release directories та deployment pointer.
5. Manual package updater: staging, validation, activation, rollback.
6. Release ZIP, checksums, signed manifest і документація production rollout.

Кожний етап оформлюється окремим PR. FEAT-002 не починається до стабілізації FEAT-001, оскільки без config snapshot rollback коду може активувати несумісну конфігурацію.