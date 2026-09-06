# RELEASE_POLICY.md

## 1. Призначення документа

Цей документ визначає політику розробки, тестування та випуску релізів у
репозиторії `BRAVO-Toolkit`.

Основні цілі:

- відокремити розробку та тестування від production-релізів;
- не допускати потрапляння неперевіреного коду в `master`;
- забезпечити однозначне розрізнення development і production-пакетів;
- формалізувати перевірку релізів на реальних серверах;
- зробити процес випуску відтворюваним і контрольованим.

Практичний бік цих правил (що саме перевірити перед тегуванням) —
`RELEASE_CHECKLIST.md`. Цей документ відповідає на питання «яка версія
де дозволена», чек-лист — на питання «що зробити перед випуском».

---

## 2. Основні гілки

У репозиторії використовуються дві постійні гілки:

- `developer` — розробка, інтеграція, тестування та prerelease-релізи;
- `master` — лише перевірені production-релізи.

### 2.1. Гілка `developer`

Гілка `developer` використовується для:

- розробки нових функцій;
- виправлення помилок;
- security-виправлень;
- інтеграції змін;
- запуску автоматичних тестів;
- формування тестових релізів;
- перевірки на тестових і пілотних серверах.

У `developer` дозволені лише prerelease-версії:

```text
X.Y.Z-dev.N
X.Y.Z-rc.N
```

Приклади:

```text
4.5.0-dev.1
4.5.0-dev.2
4.5.0-rc.1
4.5.0-rc.2
```

У `developer` заборонено публікувати stable-релізи без prerelease-суфікса.

### 2.2. Гілка `master`

Гілка `master` використовується лише для production-релізів.

У `master` дозволено публікувати тільки код, який:

1. пройшов розробку та CI у `developer`;
2. був опублікований як prerelease;
3. пройшов тестування на реальному сервері;
4. успішно виконав основні production-операції;
5. не має відомих блокуючих дефектів;
6. схвалений для production-використання.

У `master` дозволені лише stable-версії:

```text
X.Y.Z
```

Приклади:

```text
4.4.2
4.5.0
4.5.1
```

У `master` заборонені версії:

```text
4.5.0-dev.1
4.5.0-rc.1
```

---

## 3. Політика версій

Проєкт використовує Semantic Versioning:

```text
MAJOR.MINOR.PATCH
```

де:

- `MAJOR` — несумісні зміни;
- `MINOR` — нова функціональність зі збереженням сумісності;
- `PATCH` — сумісні виправлення.

Для development-релізів використовуються prerelease-суфікси.

### 3.1. Development-версії

Формат:

```text
X.Y.Z-dev.N
```

Використовуються для:

- активної розробки;
- внутрішнього тестування;
- ранньої перевірки змін;
- пакетів, які ще не готові до тестування як кандидат у production.

Приклад:

```text
4.5.0-dev.1
4.5.0-dev.2
4.5.0-dev.3
```

### 3.2. Release Candidate

Формат:

```text
X.Y.Z-rc.N
```

Release Candidate використовується для пакета, який:

- функціонально завершений;
- пройшов CI;
- пройшов self-test;
- готовий до перевірки на реальному сервері;
- не повинен отримувати нові функції.

Після створення RC дозволені лише:

- виправлення дефектів;
- виправлення документації;
- виправлення manifest-файлів;
- виправлення тестів;
- зміни, необхідні для успішного production-тестування.

Приклад:

```text
4.5.0-rc.1
4.5.0-rc.2
```

### 3.3. Stable-версії

Формат:

```text
X.Y.Z
```

Stable-реліз створюється лише шляхом promotion перевіреного RC.

Приклад:

```text
4.5.0-rc.2 -> 4.5.0
```

Stable-реліз не повинен містити нових функціональних змін порівняно з
останнім перевіреним RC.

Допустимі лише release-зміни:

- видалення prerelease-суфікса;
- зміна `releaseChannel`;
- оновлення `releaseDate`;
- оновлення `buildId`;
- оновлення `sourceCommit`;
- оновлення `CHANGELOG.md`;
- оновлення release metadata;
- перегенерація manifest-файлів.

### 3.4. `ModuleVersion` і prerelease-суфікс

`ModuleVersion` у `modules\*\*.psd1` — це тип `[System.Version]`, який не
приймає prerelease-суфікса, а `New-ModuleManifest` у Windows PowerShell
5.1 не має параметра `-Prerelease` (перевірено на цільовій платформі).
Тому діє таке правило:

```text
VERSION.json  packageVersion = 4.5.0-dev.1
modules\*.psd1 ModuleVersion  = 4.5.0
```

`ModuleVersion` дорівнює **базовій частині** `packageVersion` (без
суфікса). Самотест `Version/ModuleManifests` перевіряє саме це, а
`Version/DeveloperBranchCarriesPrereleaseVersion` — що суфікс
відповідає гілці. Повна версія пакета завжди береться з `VERSION.json`,
а не з маніфестів модулів.

З цього правила випливає **свідоме обмеження release contract BRAVO**:
BRAVO використовує Semantic Versioning `X.Y.Z`, але через цільову
платформу Windows PowerShell 5.1 базова частина `packageVersion` має
бути представима типом `System.Version`, оскільки той самий `X.Y.Z`
записується як `ModuleVersion` у `*.psd1`. Тобто кожен із
MAJOR/MINOR/PATCH не перевищує `2147483647` (`Int32.MaxValue`).
Синтаксично коректний, але непредставимий core (наприклад
`2147483648.0.0`) — **непідтримувана** `packageVersion`: її відхиляє і
`ci\Test-BRAVOReleasePolicy.ps1` (до порівняння `ModuleVersion`, однією
root-cause помилкою), і runtime guard кожного entrypoint (fail-closed
malformed-шлях захисту від відкату).

Обмеження стосується лише MAJOR/MINOR/PATCH. Числовий
prerelease-ідентифікатор `N` у `-dev.N` / `-rc.N` **не** обмежується
розміром `Int32`: він валідується за SemVer і порівнюється як число
довільної довжини.

---

## 4. Вимога різних версій у `developer` та `master`

Гілки `developer` і `master` не повинні тривалий час містити однакову
версію пакета.

Нормальний стан:

```text
master:    4.4.2
developer: 4.5.0-dev.1
```

Після promotion:

```text
master:    4.5.0
developer: 4.5.1-dev.1
```

Якщо після merge гілки тимчасово містять однаковий код, у `developer`
необхідно одразу відкрити наступний development-цикл та змінити версію.

Для patch-циклу:

```text
master:    4.5.0
developer: 4.5.1-dev.1
```

Для minor-циклу:

```text
master:    4.5.0
developer: 4.6.0-dev.1
```

Однакова версія в обох гілках ускладнює визначення походження пакета та
створює ризик випадкового встановлення тестового комплекту на
production-сервер.

---

## 5. `VERSION.json`

### 5.1. Приклад для `developer`

Development-реліз:

```json
{
  "product": "BRAVO-Toolkit",
  "packageVersion": "4.5.0-dev.1",
  "configSchemaVersion": 1,
  "stateSchemaVersion": 1,
  "updaterVersion": "1.0.0",
  "releaseDate": "2026-08-05",
  "releaseChannel": "development",
  "buildId": "abcdef1",
  "sourceCommit": "abcdef1234567890abcdef1234567890abcdef12"
}
```

Release Candidate:

```json
{
  "product": "BRAVO-Toolkit",
  "packageVersion": "4.5.0-rc.1",
  "configSchemaVersion": 1,
  "stateSchemaVersion": 1,
  "updaterVersion": "1.0.0",
  "releaseDate": "2026-08-05",
  "releaseChannel": "prerelease",
  "buildId": "abcdef1",
  "sourceCommit": "abcdef1234567890abcdef1234567890abcdef12"
}
```

### 5.2. Приклад для `master`

```json
{
  "product": "BRAVO-Toolkit",
  "packageVersion": "4.5.0",
  "configSchemaVersion": 1,
  "stateSchemaVersion": 1,
  "updaterVersion": "1.0.0",
  "releaseDate": "2026-08-05",
  "releaseChannel": "stable",
  "buildId": "1234567",
  "sourceCommit": "1234567890abcdef1234567890abcdef12345678"
}
```

### 5.3. Обов'язкові правила

Для `developer`:

```text
packageVersion = X.Y.Z-dev.N або X.Y.Z-rc.N
releaseChannel = development або prerelease
```

Для `master`:

```text
packageVersion = X.Y.Z
releaseChannel = stable
```

Канал релізу повинен бути записаний у самому пакеті.

Не можна покладатися лише на `.git/HEAD`, оскільки production-комплект
може бути:

- завантажений як ZIP;
- скопійований на сервер без `.git`;
- розгорнутий через файловий архів;
- переданий через SFTP або SMB.

### 5.4. Чому канал знову зберігається в пакеті (AUD-016)

Раніше `releaseChannel` зберігався однаковим на обох гілках
(`"stable"`), а реальне значення виводилось із `.git/HEAD`
(`Resolve-BRAVOReleaseChannelFromGit`). Причина була конкретна: кожен
merge `developer` → `master` вимагав ручного follow-up commit, і
fast-forward двічі мовчки протягнув значення не в ту гілку.

Ця політика усуває саму причину інакше: `developer` і `master` більше
ніколи не містять однакового `VERSION.json` (розділ 4), тому
fast-forward між ними неможливий — promotion завжди явна зміна версії й
каналу. А замість людської дисципліни, яка тоді підвела, працює
механічний gate `ci\Test-BRAVOReleasePolicy.ps1`: невідповідність гілки,
версії та каналу валить CI.

`Resolve-BRAVOReleaseChannelFromGit` залишається — але вже не як джерело
значення, а як перехресна перевірка: якщо поруч є `.git` і гілка
суперечить записаному каналу, CI червоніє. Джерело істини — `VERSION.json`
(розділ 5.3).

---

## 6. Стандартний workflow розробки

### 6.1. Створення робочої гілки

Рекомендовані типи тимчасових гілок:

```text
feature/*
fix/*
security/*
docs/*
refactor/*
```

Приклади:

```text
feature/add-archive-validation
fix/winscp-timeout
security/credential-hardening
docs/release-policy
```

Гілки створюються від актуальної `developer`:

```bash
git switch developer
git pull --ff-only origin developer
git switch -c feature/add-archive-validation
```

### 6.2. Merge змін

Допустимий маршрут:

```text
feature/*  -> developer
fix/*      -> developer
security/* -> developer
docs/*     -> developer
```

Заборонений маршрут:

```text
feature/* -> master
fix/*     -> master
```

Усі звичайні зміни мають пройти через `developer`.

---

## 7. Development release flow

### 7.1. Початок нового циклу

Після production-релізу:

```bash
git switch developer
git merge --ff-only master
```

Після цього версія змінюється на наступну development-версію.

Приклад:

```text
master:    4.5.0
developer: 4.5.1-dev.1
```

або:

```text
master:    4.5.0
developer: 4.6.0-dev.1
```

### 7.2. Створення development-релізу

Перед створенням `dev`-релізу необхідно:

- оновити `VERSION.json`;
- синхронізувати всі `ModuleVersion` (розділ 3.4);
- оновити заголовки документації;
- оновити `CHANGELOG.md`;
- перегенерувати manifest-файли;
- запустити CI;
- запустити `BRAVO_SELF_TEST.ps1`.

Тег:

```bash
git tag -a v4.5.0-dev.1 -m "BRAVO-Toolkit 4.5.0-dev.1"
git push origin v4.5.0-dev.1
```

GitHub Release має бути позначений як:

```text
Pre-release: true
Latest release: false
```

---

## 8. Release Candidate flow

RC створюється після завершення функціональної розробки.

Приклад переходу:

```text
4.5.0-dev.3 -> 4.5.0-rc.1
```

Перед створенням RC необхідно:

- завершити функціональні зміни;
- закрити блокуючі дефекти;
- пройти всі автоматичні тести;
- пройти перевірку `BRAVO_SETUP.ps1 -ValidateOnly`;
- пройти `BRAVO_DRY_RUN.ps1`;
- перевірити актуальність manifest-файлів;
- оновити документацію;
- підготувати release notes.

Тег:

```bash
git tag -a v4.5.0-rc.1 -m "BRAVO-Toolkit 4.5.0-rc.1"
git push origin v4.5.0-rc.1
```

GitHub Release:

```text
Pre-release: true
Latest release: false
```

---

## 9. Перевірка RC на реальних серверах

Перед promotion у `master` RC повинен пройти перевірку щонайменше на
одному реальному сервері.

Для критичних змін рекомендується перевірка на кількох серверах із
різними конфігураціями.

### 9.1. Обов'язкові перевірки

Необхідно перевірити:

- інсталяцію або оновлення через `BRAVO_SETUP.ps1`;
- `BRAVO_SETUP.ps1 -ValidateOnly`;
- `BRAVO_DRY_RUN.ps1`;
- реальну архівацію;
- створення локальних архівів;
- перевірку архівів через 7-Zip;
- передавання на SFTP;
- копіювання на SMB/NAS, якщо компонент увімкнений;
- health-check;
- maintenance;
- запуск завдань від `SYSTEM`;
- відсутність секретів у журналах;
- коректність кодів завершення;
- коректність сповіщень;
- сумісність із цільовою Windows та Windows PowerShell 5.1;
- restore test, якщо зміни стосуються резервного копіювання або
  відновлення.

### 9.2. Мінімальний протокол перевірки

Для кожного тестового сервера потрібно зафіксувати:

```text
Server:
OS:
PowerShell:
Previous version:
Tested version:
Install/update result:
ValidateOnly result:
Dry-run result:
Archive result:
SFTP result:
SMB result:
Health result:
Maintenance result:
Restore test result:
Detected issues:
Decision:
```

### 9.3. Критерії готовності

RC готовий до promotion, якщо:

- усі обов'язкові перевірки пройдені;
- немає блокуючих дефектів;
- немає security-регресій;
- немає втрати backup-файлів;
- немає пошкодження конфігурації;
- немає помилок під час запуску від `SYSTEM`;
- немає некоректної роботи після оновлення;
- документація відповідає фактичній поведінці.

---

## 10. Promotion у `master`

Production-реліз створюється лише з перевіреного RC.

Приклад:

```text
developer: 4.5.0-rc.2
master:    4.5.0
```

### 10.1. Дозволені зміни під час promotion

Під час promotion дозволено:

- змінити `4.5.0-rc.2` на `4.5.0`;
- встановити `releaseChannel: stable`;
- оновити `releaseDate`;
- оновити `buildId`;
- оновити `sourceCommit`;
- оновити release notes;
- оновити `CHANGELOG.md`;
- перегенерувати `RUNTIME_MANIFEST.json`;
- перегенерувати інші manifest-файли, які залежать від release metadata.

Під час promotion заборонено:

- додавати нові функції;
- змінювати бізнес-логіку;
- виконувати не протестований refactoring;
- додавати нові залежності;
- виправляти сторонні дефекти без повторного RC-тестування.

Якщо під час підготовки stable-релізу потрібна функціональна зміна,
необхідно:

1. повернути зміну в `developer`;
2. створити новий RC;
3. повторити тестування;
4. лише після цього виконати promotion.

### 10.2. Merge у `master`

Рекомендований маршрут:

```text
developer -> master
```

Merge виконується лише через Pull Request.

Після merge:

```bash
git switch master
git pull --ff-only origin master
git tag -a v4.5.0 -m "BRAVO-Toolkit 4.5.0"
git push origin v4.5.0
```

GitHub Release:

```text
Pre-release: false
Latest release: true
```

---

## 11. Дії після production-релізу

Після публікації stable-релізу необхідно:

1. переконатися, що тег `vX.Y.Z` вказує на правильний commit;
2. переконатися, що GitHub Release не позначений як Pre-release;
3. перевірити release artifact;
4. перевірити `VERSION.json` у завантаженому пакеті;
5. синхронізувати `developer` із `master`;
6. відкрити наступний development-цикл;
7. змінити версію в `developer` на наступну prerelease-версію.

Приклад:

```text
master:    4.5.0
developer: 4.5.1-dev.1
```

---

## 12. Hotfix flow

Hotfix використовується лише для критичних production-проблем.

Приклади:

- production-реліз не запускається;
- архівації не створюються;
- backup пошкоджуються;
- виникла security-вразливість;
- не працює критичне передавання;
- оновлення блокує роботу реального сервера.

### 12.1. Створення hotfix

Hotfix-гілка створюється від `master`:

```bash
git switch master
git pull --ff-only origin master
git switch -c hotfix/4.5.1
```

Версія для тестування:

```text
4.5.1-rc.1
```

Hotfix також повинен пройти:

- CI;
- self-test;
- dry-run;
- реальні серверні перевірки;
- RC-етап.

Після перевірки:

```text
4.5.1-rc.1 -> 4.5.1
```

### 12.2. Обов'язкова синхронізація

Після merge hotfix у `master` ті самі зміни необхідно перенести в
`developer`.

Допустимі варіанти:

```bash
git switch developer
git merge master
```

або selective cherry-pick, якщо `developer` вже суттєво випереджає
`master`.

Hotfix не можна залишати лише в `master`, інакше наступний
production-реліз може повторно повернути вже виправлений дефект.

---

## 13. Branch protection

### 13.1. `master`

Для `master` рекомендуються:

- заборонити прямі push;
- дозволяти зміни лише через Pull Request;
- вимагати успішний CI;
- вимагати проходження всіх required checks;
- заборонити force push;
- заборонити видалення гілки;
- вимагати актуальну гілку перед merge;
- обмежити merge лише дозволеним користувачам;
- заборонити merge з `feature/*` напряму;
- дозволяти production promotion лише з `developer` або `hotfix/*`.

### 13.2. `developer`

Для `developer` рекомендуються:

- заборонити force push;
- заборонити видалення гілки;
- вимагати CI для Pull Request;
- дозволити merge робочих гілок;
- не дозволяти stable-версії.

Технічний стан (перевірено 2026-08-26, репозиторій публічний —
branch protection доступний без платного плану): protection
**увімкнено** для обох гілок.

- `master`: зміни лише через Pull Request; required checks
  «Parser / BOM / JSON», «PSScriptAnalyzer», «BRAVO_SELF_TEST.ps1»,
  «Secret scanning (gitleaks)», «GitGuardian Security Checks»
  (strict — гілка мусить бути актуальною); force push і видалення
  гілки заборонені; `enforce_admins` увімкнено (обхід адміністратором
  заблоковано — прецедент merge PR #61 у вікні промоції 5.1.0 більше
  технічно неможливий).
- `developer`: зміни лише через Pull Request; ті самі required
  checks (без strict-вимоги актуальності гілки); force push і
  видалення заборонені; `enforce_admins` увімкнено.

Дозволене джерело промоції в `master` (`developer`/`hotfix/*` з
ЦЬОГО репозиторію, а не fork з однойменною гілкою) і семантичне
підняття stable-версії додатково контролює CI-гейт
`ci\Test-BRAVOMasterMergePolicy.ps1` (крок у required check
«Parser / BOM / JSON»), тож порушення політики блокує merge
технічно, а не лише процедурно.

---

## 14. CI-політика версій

CI повинен перевіряти гілку та значення `VERSION.json`.

Реалізація — `ci\Test-BRAVOReleasePolicy.ps1`, крок «Release policy
(branch / version / channel)» у `.github/workflows/ci.yml`. Той самий
скрипт можна запустити локально перед комітом:

```powershell
.\ci\Test-BRAVOReleasePolicy.ps1
```

### 14.1. Для `developer`

Обов'язкові умови:

```text
packageVersion matches:
^\d+\.\d+\.\d+-(dev|rc)\.\d+$

releaseChannel is:
development або prerelease
```

### 14.2. Для `master`

Обов'язкові умови:

```text
packageVersion matches:
^\d+\.\d+\.\d+$

releaseChannel is:
stable
```

### 14.3. Додаткові перевірки

CI також повинен перевіряти:

- відповідність `ModuleVersion` (базова частина версії, розділ 3.4);
- відповідність заголовків документації;
- наявність версії в `CHANGELOG.md`;
- актуальність `RUNTIME_MANIFEST.json`;
- актуальність `TOOLS_MANIFEST.json`;
- коректність JSON;
- відсутність заборонених секретів;
- успішний `BRAVO_SELF_TEST.ps1`;
- успішний PSScriptAnalyzer;
- відсутність stable-версії в `developer`;
- відсутність prerelease-версії в `master`.

---

## 15. Політика тегів

### 15.1. Development

```text
vX.Y.Z-dev.N
```

Приклад:

```text
v4.5.0-dev.1
```

### 15.2. Release Candidate

```text
vX.Y.Z-rc.N
```

Приклад:

```text
v4.5.0-rc.2
```

### 15.3. Stable

```text
vX.Y.Z
```

Приклад:

```text
v4.5.0
```

Теги повинні бути анотованими:

```bash
git tag -a v4.5.0 -m "BRAVO-Toolkit 4.5.0"
```

Перезапис опублікованих тегів заборонений.

---

## 16. Політика GitHub Releases

### Development та RC

```text
Pre-release: true
Latest release: false
```

### Stable

```text
Pre-release: false
Latest release: true
```

Stable-реліз повинен містити:

- номер версії;
- короткий опис;
- список ключових змін;
- список виправлень;
- відомі обмеження;
- інструкцію з оновлення;
- відомості про перевірений RC;
- перелік перевірених середовищ;
- checksum release artifact, якщо artifact публікується.

---

## 17. Матриця дозволених операцій

| Операція | `developer` | `master` |
|---|---:|---:|
| Розробка функцій | Так | Ні |
| Виправлення звичайних дефектів | Так | Ні |
| Security-виправлення | Так | Лише через hotfix |
| Development release | Так | Ні |
| RC release | Так | Ні |
| Stable release | Ні | Так |
| Тестування на реальному сервері | Так | Ні |
| Прямий push | Небажано | Заборонено |
| Merge `feature/*` | Так | Ні |
| Merge `developer` | Не застосовується | Так |
| Force push | Заборонено | Заборонено |

---

## 18. Приклад повного циклу

Поточний production:

```text
master: 4.4.2
```

Початок розробки:

```text
developer: 4.5.0-dev.1
```

Наступні development-релізи:

```text
4.5.0-dev.2
4.5.0-dev.3
```

Перший кандидат:

```text
4.5.0-rc.1
```

Після виправлень:

```text
4.5.0-rc.2
```

Після реальної серверної перевірки:

```text
master: 4.5.0
```

Після promotion:

```text
developer: 4.5.1-dev.1
```

---

## 19. Короткі обов'язкові правила

1. `developer` — лише розробка, тести та prerelease.
2. `master` — лише перевірені production-релізи.
3. `developer` і `master` мають різні версії.
4. Stable-реліз створюється лише з перевіреного RC.
5. Нові функції не додаються під час promotion.
6. Кожен RC перевіряється на реальному сервері.
7. Прямі push у `master` заборонені.
8. Hotfix обов'язково повертається в `developer`.
9. Development і RC GitHub Releases позначаються як Pre-release.
10. Stable GitHub Release позначається як Latest release.
11. Канал релізу зберігається у `VERSION.json`.
12. Не можна визначати канал лише через `.git/HEAD`.

---

## 20. Поточний стан

```text
master:    5.2.0       (stable, тег v5.2.0 = stamp b76a5ac,
           merge PR #102 = 477f166; metadata-only промоція
           2026-08-26 з прийнятого 5.2.0-rc.13)
developer: 5.3.0-dev.2 (development; 5.3.0-rc.1 залишається tagged
           candidate (v5.3.0-rc.1), pending acceptance, immutable —
           цикл 5.3.0 повернуто в development за явним рішенням
           власника, щоб внести P0 Configuration Foundation
           (feature-робота; §3.2 забороняє нові функції в RC).
           Наступний кандидат циклу (rc.2) включатиме й dev.1
           (P1.1 BRAVO_RESTORE_VERIFY + P2.1 status contract +
           FIX-пакет deferred-боргів), і новий P0 Configuration
           Foundation)
```

Дерево stable 5.2.0 = прийнятий `v5.2.0-rc.13` (stamp `0247ac3`,
sourceCommit `12e6370`) + non-runtime доповнення: acceptance-evidence
документ (PR #100) і governance-hardening PR #101 (repository identity
у гейті промоції master, регресії, branch protection `developer`,
синхронізація release-документації) — runtime functional diff проти
прийнятого rc.13 порожній.

Хронологія RC-циклу 5.2.0 (2026-08-24/25):

- `v5.2.0-rc.4`/`v5.2.0-rc.5` (лінія PR #83) — повний real-server
  acceptance PASS (`SERV_HRDL_1`, `WIN-44OBNQ3R3OB`).
- `v5.2.0-rc.6` — acceptance FAIL (фіксований поріг місця блокував
  backup); `v5.2.0-rc.7` (rc.5 + PR #84: розрахункова перевірка
  вільного місця з floor-override) — повний end-to-end acceptance PASS
  2026-08-25 (`WIN-42Q5558LQC9`: backup MODEL/BLOG/BRAVOEXCH,
  SFTP 7/7, Health OK).
- `v5.2.0-rc.8` (rc.7 + PR #86: регістронезалежна деривація відносних
  шляхів MODEL у Compare-FileSizes; закриває інцидент exit 43) —
  **acceptance реставрації PASS** 2026-08-25 22:03-22:24 на сервері
  інциденту (`LIMS`/ДНДІЛДВСЕ, `-ForceRestore`: bravocmd exit 0,
  Critical=0, Rollback=NONE, служби відновлено, Trace-pipeline OK).
- `v5.2.0-rc.9` (rc.8 + PR #88: живий підстатус консолі Maintenance +
  PR #89: logs pipeline v2 — усі `*.out` з кореня інсталяції,
  exchangAPI-архіви з оригінальними іменами на SFTP, структура
  `logs/trace`/`logs/exchangapi` з одноразовою автоміграцією `trace/`)
  — acceptance НЕ проводився: кандидата одразу замінено rc.10.
- `v5.2.0-rc.10` (rc.9 + PR #91: актуалізація release-документації +
  PR #92: семантичний гейт версії промоції в master і виключення
  `artifacts\` з генератора runtime-маніфесту) — acceptance НЕ
  проводився: кандидата одразу замінено rc.11.
- `v5.2.0-rc.11` (rc.10 + PR #94: компактні Maintenance-алерти —
  count + ≤5 прикладів замість повних діагностичних списків, повна
  діагностика лише в журналі — і глобальний payload guard notification-
  шару: safe limit 1800, одна подія → одне повідомлення на обох
  транспортах) — на acceptance 2026-08-26 виявлено дефект подвійної
  реставрації (нижче): кандидата замінено rc.12.
- `v5.2.0-rc.12` (rc.11 + PR #96: фікс подвійної реставрації після
  `-ForceRestore` — тижнева квота тепер покриває і «пропущений»
  минулий слот, `Test-BRAVORestoreWeeklyQuotaConsumed` з <= замість
  строгої рівності) — на acceptance зафіксовано UX-зауваження до
  прогресу реставрації: кандидата замінено rc.13.
- `v5.2.0-rc.13` (rc.12 + PR #98: підетапи у прогресі тривалих
  native-операцій — «<Фаза> — <Опис операції> — Виконується N сек.»;
  опис bravocmd-фази без прив'язки до продукту, з фактичним ім'ям
  проєкту моделі) — **фінальний кандидат циклу; acceptance PASS
  2026-08-26**: повний maintenance-цикл нової поверхні rc.9-rc.13 на
  двох реальних серверах (ДНДІЛДВСЕ Server 2022 / Львівська РДЛ,
  включно з хостом Server 2016 LegacyBestEffort) — перша бойова WinSCP
  MoveFile-міграція `trace/`→`logs/trace` 4/4, автостворення `logs/*`,
  скан реальних `*.out`-варіантів, компактні алерти, forced+normal
  реставрація в один вечір БЕЗ повтору; A2-encoding протокол
  (RELEASE_CHECKLIST §1.1) PASS в обох консольних контекстах
  (інтерактивно CP65001, SYSTEM CP866). Зведений evidence:
  `docs/BRAVO_520_RC13_ACCEPTANCE_EVIDENCE_20260826.md`.

Перенесено на 5.3.0 (додатково до P3.2a/M1/M3 нижче): три відкладені
Compare-FileSizes-фікси з локальної незапушеної гілки розробника
(settle-retry, AV-вікно 12×15с, надійна enumeration; збережено в
`backup/local-developer-rc2-line`) — механічний cherry-pick неможливий
(функцію двічі переписано в 5.2.0: main-model/сегменти,
регістронезалежні шляхи), а acceptance rc.8 на сервері інциденту
пройшов без settle-логіки; залишковий ризик — клас «антивірус тримає
файли MODEL одразу після bravocmd» на серверах з іншим AV. Там само
збережено `127e7e4` (діагностика очікування operation-lock) — кандидат
5.3.0. Решта локальних комітів тієї гілки верифіковано редундантні
(зміст уже в developer іншими комітами).

Stable `5.1.0` промотовано 2026-08-20 з прийнятого `5.1.0-rc.4`
(stamp `219c55b`, sourceCommit `d90c3c2`) після ПОВНОГО DEV-LIMS
acceptance того ж дня (evidence
`docs/BRAVO_DATA_RESTORE_RC4_DEVLIMS_ACCEPTANCE_20260820.md`, гілка
`evidence/219c55b-rc4-devlims-acceptance-pass`). Шлях циклу:
rc.1 (інвалідовано фічею DATA_RESTORE) → rc.2 (acceptance PASS, але
промоцію скасовано: виявлено відсутність порту severity-routing
PR #39) → rc.3 (порт routing; на acceptance виявлено, що DataRestore
шле повз routing) → rc.4 (фікс PR #62; повний acceptance PASS) →
stable 5.1.0.

Цикл `5.2.0-dev.1` відкрито одразу після промоції (розділ 11).
Записаний борг циклу: дедуплікація service-lifecycle / operation-lock /
WinSCP-session / ASCII-temp-root політик, декомпозиція
BRAVO.DataRestore Runtime.ps1, реалізація P3.2a (BRAVO_UPDATE.ps1).
Розведення імен push- та PR-checks у CI — ВИКОНАНО в dev.1 (під час
промоційного вікна 5.1.0 однойменний червоний push-run блокував
required checks гілки master, merge PR #61 виконано admin-обходом;
тепер required-контексти постачає лише pull_request-прогін, push-прогони
мають суфікс " (push)").

### Підготовка `5.2.0-rc.1` — рішення про scope (docs-only, без функціональних змін коду)

- **P3.2a (`BRAVO_UPDATE.ps1`) перенесено на `5.3.0`** (див.
  `ROADMAP.md` §P3.2a). Не входить у RC stabilization: нова поверхня
  атаки (download/staging/robocopy MIR/rollback/recovery), потребує
  власного acceptance, який не повинен блокувати вже готовий scope
  5.2.0. У коді 5.2.0 щодо P3.2a — нуль змін.
- **M3 (великий рефакторинг) не виконується у RC stabilization
  5.2.0.** Це стосується боргу циклу вище (dedup service-lifecycle/
  operation-lock/WinSCP-session, декомпозиція
  `BRAVO.DataRestore.Runtime.ps1`, перенесення Trace pipeline між
  модулями) і будь-якого іншого великого structural refactoring без
  конкретного production-дефекту — переноситься на наступний цикл
  (переважно `5.3.0`).
- **M1 (`WinSCP.uk` у `TOOLS_MANIFEST.json`) відкладено на `5.3.0`.**
  Bundled `WinSCP.exe` підтверджено версії `6.5.6.16502`
  (`FileVersionInfo`), що відповідає заявленому `WinSCP.uk`. Однак сам
  `WinSCP.uk` — не PE-файл із version resource, тому його версію/
  походження неможливо незалежно верифікувати з самого репозиторію.
  Генератор `ci/Update-BRAVOToolsManifest.ps1` і далі покриває лише
  `.exe/.dll/.com`; розширення allow-list на `.uk` і додавання
  `WinSCP.uk` у `TOOLS_MANIFEST.json` — окрема задача 5.3.0 після
  підтвердження походження файла.
- **Known issue (не блокер 5.2.0):** приватна
  `Get-BRAVOSevenZipArchiveInventory`
  (`modules/BRAVO.DataRestore/BRAVO.DataRestore.Runtime.ps1`) досі
  пише пароль у stdin через старий `Process.StandardInput.WriteLine`
  (BOM-даючий під UTF-8-консоллю), не мігрована на канонічний
  BOM-free `Write-BRAVOProcessInputText`. Функція й далі коректно
  читає СТАРІ (pre-5.2.0) архіви, але за певних умов консолі може НЕ
  прочитати НОВІ архіви (створені вже без BOM) під час free-space
  preflight реставрації. Мітигація зафіксована як борг циклу
  декомпозиції DataRestore (CHANGELOG, розділ dev.1) — не виправляється
  окремо в 5.2.0, щоб не змішувати вузько-скоуповий B2-фікс (легітимний
  compatibility-фікс) із частковою міграцією дублюючої реалізації
  (M3-подібний refactoring-ризик). *(Закрито в циклі 5.3.0: inventory
  став тонким адаптером над канонічною `Get-BRAVOSevenZipArchiveEntries`;
  гейт `Secrets/SevenZipPasswordUsesStdin` розширено на DataRestore.)*

### Функціональна зміна дефолту під час DEV-LIMS acceptance `5.2.0-rc.1`

- **`RepeatAlertAfterHours` (health-alert дедуп): дефолт `6` → `0`.**
  Виявлено під час реального DEV-LIMS acceptance (ДНДІЛДВСЕ,
  2026-08-23): при увімкненому `AutoArchiveMutationThreshold` оператор
  спостерігав лише перше сповіщення про `MUTATION_VIOLATION`, повторний
  ідентичний alert протягом наступних до 6 год. мовчав
  (`Test-AlertSuppressed`, `modules/BRAVO.Health/BRAVO.Health.Runtime.ps1`).
  Свідоме рішення: дедуп для alert-рівня (WARNING/ERROR/CRITICAL)
  вимикається за замовчуванням — кожен цикл, поки проблема триває,
  надсилає сповіщення заново, навіть якщо воно ідентичне попередньому.
  SUCCESS-звіт дедупу ніколи не підлягав (окрема гілка коду без
  fingerprint-перевірки) і цією зміною не зачіпається. Це функціональна
  зміна поведінки за замовчуванням (не docs-only), свідомо застосована
  до `5.2.0-rc.1` до завершення acceptance і публікації тега/artifact —
  вимагає перестемпування (`buildId`/`sourceCommit`/`RUNTIME_MANIFEST`)
  перед тегуванням. Деталі — `CHANGELOG.md` (`## 5.2.0-rc.1`, Upgrade
  notes).
