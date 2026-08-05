# RELEASE_POLICY.md

## 1. Призначення документа

Цей документ визначає політику розробки, тестування та випуску релізів у
репозиторії `ARCHIV_LIMS_MONOLITH`.

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
`Version/PackageVersionMatchesBranchPolicy` — що суфікс відповідає гілці.
Повна версія пакета завжди береться з `VERSION.json`, а не з маніфестів
модулів.

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
  "product": "BRAVO Archive",
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
  "product": "BRAVO Archive",
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
  "product": "BRAVO Archive",
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
git tag -a v4.5.0-dev.1 -m "BRAVO Archive 4.5.0-dev.1"
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
git tag -a v4.5.0-rc.1 -m "BRAVO Archive 4.5.0-rc.1"
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
git tag -a v4.5.0 -m "BRAVO Archive 4.5.0"
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

Технічний стан на сьогодні: branch protection **не ввімкнено** —
required status checks на приватному репозиторії потребують GitHub Pro.
Тому CI показує статус, але не блокує merge; дотримання цього розділу
поки що ручне (`RELEASE_CHECKLIST.md`, розділ 2).

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
git tag -a v4.5.0 -m "BRAVO Archive 4.5.0"
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
master:    4.4.2   (stable)
developer: 4.5.0-dev.1 (development)
```

`4.5.0` — minor-цикл: у `developer` заплановано автоматичний discovery
джерел архівації (нова функціональність зі збереженням сумісності), тому
відкрито `4.5.0-dev.1`, а не `4.4.3-dev.1`.
