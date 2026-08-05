# BRAVO 4.3.0 — архівація, обслуговування та контроль резервних копій

Цей комплект автоматизує:

- архівацію `MODEL`, `BLOG` і `BRAVOEXCH`;
- локальну та SFTP-синхронізацію `BAZA`;
- копіювання архівів на SFTP і, за потреби, SMB/NAS;
- обслуговування служб BRAVO;
- перевірку локальних, SFTP і SMB-копій;
- сповіщення у Slack або Discord;
- створення й діагностику завдань Планувальника Windows.

Для звичайного встановлення не потрібно запускати всі скрипти окремо. Основна
точка входу — **`.\BRAVO_SETUP.ps1`**.

> **Важливо:** production-комплект для завдань від `SYSTEM` не можна запускати з
> `Desktop`, `Documents`, `Downloads` або іншого каталогу профілю користувача.
> Рекомендоване розташування — `C:\LIMS\ARCHIV`. Каталог зі скриптами має
> називатися саме `ARCHIV`.

## Швидкий вибір команди

| Що потрібно зробити | Команда |
|---|---|
| Перша інсталяція або повне оновлення | `.\BRAVO_SETUP.ps1` |
| Перевірити все без постійних змін | `.\BRAVO_SETUP.ps1 -ValidateOnly` |
| Симулювати production-операції | `.\BRAVO_DRY_RUN.ps1` |
| Перевірити реєстрацію завдань без UAC | `.\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly` |
| Перевірити завдання та доступ від `SYSTEM` | `.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess` |
| Оновити лише параметри установи | `.\BRAVO_SETUP.ps1 -Action Credentials -CredentialComponent Institution` |
| Запустити архівацію вручну | `.\BRAVO_ARCHIV.ps1 -NoPause` |
| Запустити обслуговування вручну | `.\BRAVO_MAINTENANCE.ps1` |
| Запустити health-check вручну | `.\BRAVO_HEALTH.ps1` |
| Перевірити, що backup реально відновлюється | `.\BRAVO_RESTORE_TEST.ps1` |
| Виконати тести коду | `.\BRAVO_SELF_TEST.ps1` |

Усі команди в цій інструкції потрібно виконувати з каталогу `ARCHIV`. Для
інсталяції, зміни Credential Manager для `SYSTEM` і Планувальника відкрийте
`cmd.exe` або PowerShell **від імені адміністратора**.

## 1. Системні вимоги

- 64-бітна Windows для повного сценарію обслуговування;
- локальні права адміністратора для встановлення завдань і керування службами;
- доступний VSS на локальних томах із `MODEL`, `BLOG` і `BRAVOEXCH`;
- доступ до SFTP через TCP 22, якщо SFTP-компоненти ввімкнені;
- доступ до Slack/Discord через HTTPS 443, якщо сповіщення ввімкнені;
- доступ до потрібного UNC-шляху, якщо SMB/NAS ввімкнений.

### Підтримувані версії Windows

| Рівень | Системи |
|---|---|
| **Supported** | Windows Server 2019+, Windows 10/11, Windows PowerShell 5.1 |
| **Legacy best-effort** | Windows Server 2012 R2, Windows Server 2016 (без гарантій) |
| **Unsupported** | Windows 7, Windows Server 2008 R2, PowerShell 3.0 |

Archive, Health і Maintenance визначають рівень при кожному запуску
(`Get-BRAVOOSSupportTier`, `modules\BRAVO.Compatibility`) і завжди пишуть у
журнал точну версію ОС, build, PowerShell і .NET — незалежно від рівня. На
`Legacy best-effort` запуск лише попереджає. На `Unsupported` production-запуск
**блокується** (код завершення `30`) — щоб продовжити свідомо, встановіть
змінну середовища `BRAVO_ALLOW_UNSUPPORTED_OS=1` перед запуском. Мінімальна
версія PowerShell для самого запуску скрипта — 3.0 (нижче кидає помилку
одразу, `Assert-BRAVOPowerShellCompatibility`); 3.0 сама по собі вже входить
до Unsupported і потребує того самого override.

У каталозі `ARCHIV\Tools` мають бути:

| Файл | Для чого потрібен |
|---|---|
| `7za.exe` | Створення та повна перевірка архівів |
| `WinSCP.com` | Production-передача і синхронізація SFTP |
| `WinSCPnet.dll` | Автентифікований read-only тест SFTP |
| `WinSCP.exe` | Працює в парі з `WinSCPnet.dll` під час тесту доступу |

Еталон цілісності інструментів — `TOOLS_MANIFEST.json` у корені комплекту:
version-controlled файл із SHA-256 **усіх** виконуваних файлів `Tools\`
(включно з `7za.dll`, `7zxa.dll`, `DragExt64.dll`, які тягне за собою
7-Zip). Перед кожним запуском Archive/Health/Maintenance звіряють каталог
із маніфестом, і в режимі `Enforce` (типовий,
`$global:toolIntegritySettings.Mode` у `BRAVO.config`) **блокують роботу**
з кодом завершення `32`, якщо:

- хеш відомого файлу не збігається;
- файл із маніфесту відсутній;
- у `Tools\` з'явився сторонній `.exe`/`.dll`/`.com` (DLL side-loading:
  щоб виконати чужий код, підміняти `WinSCP.exe` не обов'язково —
  достатньо підкласти DLL із відповідним іменем);
- сам `TOOLS_MANIFEST.json` відсутній, порожній або пошкоджений.

Health при цьому не просто попереджає: він пропускає всю SFTP-гілку
(єдине місце, де він торкається `Tools\`) і завершується кодом `32`.
Локальні перевірки — служби, вільне місце, вік копій — виконуються далі.

> **Маніфест ніколи не створюється й не оновлюється автоматично.**
> Оновлення інструментів — свідома дія на робочій станції, не на сервері:
>
> ```powershell
> .\ci\Update-BRAVOToolsManifest.ps1          # лише показує розбіжності
> .\ci\Update-BRAVOToolsManifest.ps1 -Apply   # записує новий еталон
> git diff -- Tools TOOLS_MANIFEST.json       # рев'ю разом із бінарником
> ```
>
> Видаляти маніфест, щоб «полагодити» помилку цілісності, не можна: це
> не лікування, а вимкнення самої перевірки. У режимі `Enforce`
> відсутній маніфест — теж відмова.

Окремо існує додатковий шар виявлення дрейфу — `Tools\TOOLS_INTEGRITY.json`
(trust-on-first-use, створюється автоматично, розбіжність лише попереджає).
Це **не** контроль безпеки й не еталон: якщо хеш у ньому розійшовся,
рішення ухвалює `TOOLS_MANIFEST.json`.

## 2. Рекомендована структура каталогів

```text
C:\LIMS\
├── Model\                 джерело MODEL
├── BLOG\                  джерело BLOG
├── BAZA\                  джерело BAZA, якщо ввімкнено
└── ARCHIV\
    ├── README.md, SECURITY.md, CHANGELOG.md, RELEASE_CHECKLIST.md
    ├── VERSION.json
    ├── BRAVO.config
    ├── BRAVO_ARCHIV.ps1, BRAVO_MAINTENANCE.ps1, BRAVO_HEALTH.ps1
    ├── BRAVO_SETUP.ps1, BRAVO_DRY_RUN.ps1, BRAVO_SELF_TEST.ps1
    ├── BRAVO_CREDENTIALS_SETUP.ps1, BRAVO_TASKS_INSTALL.ps1,
    │   BRAVO_TASKS_UNINSTALL.ps1, BRAVO_TASKS_DIAGNOSE.ps1
    ├── modules\             спільні PowerShell-модулі (розділ 13)
    ├── Tools\
    │   ├── 7za.exe
    │   ├── WinSCP.com
    │   ├── WinSCP.exe
    │   └── WinSCPnet.dll
    ├── LOGS\              створюється автоматично
    ├── MODEL\             локальні архіви
    ├── BLOG\
    ├── BRAVOEXCH\
    └── BAZA\              локальна копія BAZA_APP, якщо ввімкнено
```

За замовчуванням `BRAVO.config` визначає `C:\LIMS` як батьківський каталог
`ARCHIV`. Якщо скрипти розташовані інакше або резервні копії потрібно зберігати
на іншому диску, задайте абсолютні значення у `pathSettings`.

## 3. Що налаштувати у `BRAVO.config`

`BRAVO.config` є PowerShell-конфігурацією, тому зберігайте його кодування і
синтаксис. Паролі, логіни та webhook URL у файл не записуються.

Перед першим запуском перевірте такі секції:

| Секція | Що перевірити |
|---|---|
| `bravoSettings` | `NotificationProvider` (`slack` або `discord`) і `NotificationMode` |
| `pathSettings` | `LIMSRoot`, `ArchiveRoot`, `BackupRoot` |
| `maintenanceSettings` | імена служб, каталог Br-a-vo.web, таймаути та параметри обслуговування |
| `componentSettings` | які архіви, BAZA, SFTP і SMB потрібно виконувати |
| `backupConsistency` | обов'язковий режим `VSS` і контекст `ClientAccessible` для узгоджених архівів |
| SFTP | `sftpHostTemplate`, порт, fingerprint `sftpHostKey`, віддалені каталоги |
| `smbSettings` | реальний UNC-шлях і підкаталоги, якщо `ArchiveCopy = $true` |
| `backupMonitoring` | `CheckManagedServices`, допустимий вік копій, SHA512-перевірки і частота повторних alert |
| `schedulerSettings` | час запуску, імена завдань, таймаути і task account |

Початково ввімкнено:

- архівацію `MODEL`, `BLOG`, `BRAVOEXCH`;
- завантаження архівів на SFTP;
- синхронізацію основної `BAZA` на SFTP;
- щоденний backup о `23:00`;
- щоденне maintenance о `23:55`;
- health-check кожні 240 хвилин, починаючи з `00:15`.

Початково вимкнено:

- локальну копію `BAZA`;
- синхронізацію `BAZA WWW`;
- копіювання архівів на SMB/NAS.

Не вмикайте компонент, доки не задані його шлях, доступ і Credential Manager.
Віддалені SFTP-каталоги `model`, `blog`, `bravoexch`, `baza_app` і `baza_www`
потрібно попередньо створити або змінити їхні назви у `sftpDirectories`.

### 3.1. Автоматичне визначення джерел (Discovery)

Джерела архівації (`MODEL`, `BLOG`, `BRAVOEXCH`, `BAZA_APP`, `BAZA_WWW`, а також
`BRAVO_ROOT`/`WEB_ROOT`) за замовчуванням визначаються **автоматично**, без
редагування `BRAVO.config`:

1. Знаходиться служба BRAVO (`maintenanceSettings.Services.BravoName`) →
   з її виконуваного файлу визначається `BRAVO_ROOT` і поруч шукається
   `bravo.ini`.
2. Із секції `[model]` файлу `bravo.ini` читаються `MODEL=`, `BLOG=`,
   `BEXCH=` — саме ці значення й стають джерелами архівації.
3. Служба Apache (одна зі `BravoWebCandidates`) аналогічно дає `WEB_ROOT`
   і, відповідно, `BAZA_WWW`.
4. Якщо служба або `bravo.ini` не знайдені — комплект відкочується до
   попередньої, LIMSRoot-відносної поведінки (`Model\*`, `BLOG\*` у корені
   `pathSettings.LIMSRoot`), як і раніше до цієї версії.

Ручне перевизначення будь-якого поля лишається можливим через
`$global:discoverySettings` у `BRAVO.config` (`Sources.MODEL`,
`Sources.BLOG`, `Sources.BRAVOEXCH`, `BravoRoot`, `WebRoot`,
`BravoIniPath` тощо) — заданe вручну значення завжди має пріоритет над
автоматично знайденим і ніколи не перезаписується.

Щоб побачити, які джерела буде визначено на конкретному сервері, і чи
пройдуть вони перевірку (існування шляху, конфлікт джерело/призначення
тощо), запустіть:

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly
```

Розділ виводу `=== DISCOVERY ДЖЕРЕЛ ===` показує знайдені служби,
шлях до `bravo.ini`, кожне обчислене джерело з поясненням (звідки саме
взято значення: override / `bravo.ini` / legacy fallback) і результат
валідації.

#### Неоднозначність і дрейф джерел

Якщо на сервері знайдено кілька служб BRAVO (або кілька Apache-подібних
служб) із **різними** виконуваними файлами — це ознака stale/дублюючої
інсталяції. Discovery попереджає про це (`УВАГА: знайдено кілька служб-
кандидатів...`), а `Test-BRAVODiscoveryResult` під `-ValidateOnly`
блокує валідацію для будь-якого увімкненого компонента, що залежить від
неоднозначного `BRAVO_ROOT`/`WEB_ROOT` — доки адміністратор явно не
задасть потрібне значення через `discoverySettings.BravoRoot`/`WebRoot`
або не прибере зайву службу.

`BRAVO_SETUP.ps1 -ValidateOnly` також порівнює поточний discovery-
результат зі збереженим **baseline** (`LOGS\DISCOVERY_BASELINE.json`,
не в git) і повідомляє про дрейф (`Discovery drift: ...`), якщо джерело
змінилося відносно останнього підтвердженого запуску — наприклад,
службу перейменували й комплект тихо перейшов на legacy fallback.
Це лише інформаційне попередження, воно не блокує роботу.

Щоб зафіксувати поточний discovery-результат як новий baseline (після
ручної перевірки, що джерела визначені правильно):

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly -ConfirmDiscoveryBaseline
```

### 3.2. Sanity-check обсягу backup

Технічно валідний архів (пройшов `7za test`, SHA-512 збігається) все одно
може бути підозріло малим через неправильне джерело, зламані permissions
чи неповний VSS exposure — сам файл при цьому виглядає коректним.
`backupMonitoring.SizeSanity` у `BRAVO.config` порівнює розмір щойно
створеного архіву з медіаною останніх `HistoryCount` валідних (hash-
підтверджених) архівів того самого компонента:

| Поле | Призначення |
|---|---|
| `Enabled` | вимкнути перевірку повністю |
| `HistoryCount` | скільки останніх валідних архівів брати для медіани (типово 5) |
| `MinimumBytes` | абсолютний мінімум незалежно від історії — захищає навіть перший backup компонента |
| `MaxSizeDropPercent` | падіння відносно медіани, що вважається аномалією (типово 50%) |

Перший backup компонента (історії ще немає) автоматично пропускає
перевірку — це не вважається аномалією. Виявлена аномалія **не блокує**
backup — лише пише `WARNING` у журнал (`Write-Log`) і піднімає статус
кроку `Архівація <компонент>` до `WARNING` у консольному звіті; це
потрапляє в лічильник попереджень і, відповідно, у Slack/Discord-
сповіщення після backup.

## 4. Параметри установи та секрети

Наступні значення зберігаються у Windows Credential Manager, тому їх не потрібно
знову вписувати у config після оновлення:

| Target Credential Manager | Значення |
|---|---|
| `BRAVO_INSTITUTION_NAME` | назва установи |
| `BRAVO_INSTITUTION_CODE` | код ЄДРПОУ/локальний код |
| `BRAVO_ARCHIVE_PREFIX` | префікс імен архівів |
| `BRAVO_7Z_PASSWORD` | пароль архівів |
| `BRAVO_SFTP_LOGIN` | логін SFTP |
| `BRAVO_SFTP_PASSWORD` | пароль SFTP |
| `BRAVO_SMB_LOGIN` | логін SMB/NAS |
| `BRAVO_SMB_PASSWORD` | пароль SMB/NAS |
| `BRAVO_SLACK_URL` | Slack webhook |
| `BRAVO_DISCORD_URL` | Discord webhook |

Значення `InstitutionName`, `InstitutionCode` і `ArchivePrefix` у
`BRAVO.config` — лише fallback для першого запуску. Після налаштування
використовуються записи Credential Manager.

`ArchivePrefix` може містити латинські літери, цифри, `.`, `_` і `-`. Після
зміни префікса старі архіви не видаляються, але новий health-check і retention
працюють уже з новим префіксом.

Credential Manager є прив'язаним до облікового запису. Тому стандартний режим
`-StoreFor Both` зберігає потрібні записи окремо:

1. для поточного адміністратора — ручні запуски;
2. для `NT AUTHORITY\SYSTEM` — автоматичні завдання.

Не використовуйте лише `CurrentUser`, якщо завдання запускаються від `SYSTEM`.

## 5. Перша інсталяція

### Крок 1. Розмістити файли

Скопіюйте комплект у `C:\LIMS\ARCHIV`, додайте інструменти у `Tools` і
перевірте наявність джерельних каталогів.

### Крок 2. Виконати локальні тести

```powershell
cd /d C:\LIMS\ARCHIV
.\BRAVO_SELF_TEST.ps1
```

Self-test перевіряє синтаксис усіх PowerShell-файлів, узгодженість версій,
захисні параметри backup, спільний operation lock і визначення завдань
Планувальника без production-архівації.

### Крок 3. Перевірити конфігурацію без змін

```powershell
.\BRAVO_SETUP.ps1 -ValidateOnly
```

Цей режим не створює постійні credentials або production-завдання і не
надсилає тестове повідомлення. Для читання Credential Manager від `SYSTEM`
може бути створене короткочасне службове завдання, яке видаляється автоматично.

### Крок 4. Запустити комплексне налаштування

```powershell
.\BRAVO_SETUP.ps1
```

Стандартний режим `Full`:

1. виконує preflight і dry-run без production-операцій;
2. запитує лише відсутні credentials та параметри установи;
3. перевіряє їх читання поточним користувачем і `SYSTEM`;
4. перевіряє і встановлює завдання Планувальника;
5. запускає dry-run та read-only тести SFTP/SMB від `SYSTEM`;
6. надсилає одне тестове повідомлення у налаштований Slack або Discord.

У цьому сценарії не створюються архіви, не синхронізуються дані, не видаляються
файли, не перезапускаються служби і не вимикається комп'ютер. Єдина зовнішня
операція запису — одне явно позначене тестове повідомлення.

Якщо зовнішня мережа тимчасово недоступна:

```powershell
.\BRAVO_SETUP.ps1 -SkipAccessTest
```

Якщо потрібно перевірити SFTP/SMB, але не надсилати повідомлення:

```powershell
.\BRAVO_SETUP.ps1 -SkipTestNotification
```

### Крок 5. Перевірити створені завдання

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly
.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess
```

Перший виклик лише читає реєстрацію. Другий запускає end-to-end dry-run від
`SYSTEM` і перевіряє реальний доступ без архівації чи синхронізації.

## 6. Безпечний тестовий прогін

Лише перевірка конфігурації, файлів, каталогів, tools і плану операцій:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config"
```

Додатково перевірити реальну автентифікацію та read-only доступ:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config" -TestAccess
```

End-to-end тест із одним реальним Slack/Discord повідомленням:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
```

`-TestAccess` виконує:

- SFTP: TCP-з'єднання, вхід через WinSCP і читання віддаленого каталогу;
- SMB: тимчасове підключення `PSDrive` і читання кореня, після чого drive
  видаляється;
- Slack/Discord: лише перевірку TCP-доступності HTTPS endpoint.

`-SendTestNotification` виконує HTTP POST і підтверджує, що webhook дійсно
приймає повідомлення. Для Discord mentions вимкнені. Невдале надсилання
повертає помилку, тому для першої інсталяції рекомендовано виконати саме цей
end-to-end тест.

Рядки `PLAN` у результаті показують, які production-операції були б виконані.
Dry-run їх не запускає.

### 6.1. Restore drill (перевірка відновлюваності)

Читабельний і навіть SHA-512/7za-перевірений архів доводить лише те, що
його байти не пошкоджені — не те, що з нього реально можна відновитися.
`BRAVO_RESTORE_TEST.ps1` бере найновіший локальний backup із коректним
`.sha512` для кожного увімкненого компонента (`MODEL`/`BLOG`/`BRAVOEXCH`),
розпаковує його в ІЗОЛЬОВАНИЙ тимчасовий каталог (не production-шлях,
видаляється одразу після перевірки) і звіряє кількість розпакованих
файлів проти мінімального порогу:

```powershell
.\BRAVO_RESTORE_TEST.ps1 -ConfigPath ".\BRAVO.config"
```

Лише один компонент, машинно-читаний JSON-результат і вища мінімальна
кількість файлів (типово `1`, підвищіть для реалістичного порогу під
конкретну інсталяцію):

```powershell
.\BRAVO_RESTORE_TEST.ps1 -Component MODEL -MinimumFileCount 50 -ResultPath ".\restore_drill_result.json" -AsJson
```

Це read-only діагностика: не видаляє, не переміщує й не змінює жоден
існуючий backup, не вимагає елевації. Кожен компонент отримує статус
`PASS`/`WARN` (немає верифікованого backup для перевірки)/`FAIL`
(не пройшла перевірка цілісності 7za, розпакування або мінімальна
кількість файлів) — коди завершення `0`/`10`/`41` відповідно до
контракту (розділ 12). Сповіщення в Slack/Discord надсилається
автоматично лише при `WARN`/`FAIL`, якщо не задано `-SkipNotification`.

Рекомендовано запускати щотижня або щомісяця окремим завданням
Планувальника — на відміну від `BRAVO_HEALTH.ps1`, це не входить до
типового набору завдань, встановлюваних `BRAVO_TASKS_INSTALL.ps1`
(потрібно додати вручну, якщо плануєте регулярний drill).

## 7. Окремі етапи налаштування

Комплексний setup можна обмежити одним етапом:

```powershell
.\BRAVO_SETUP.ps1 -Action Credentials
.\BRAVO_SETUP.ps1 -Action Scheduler
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly
```

Оновлення лише назви установи, коду і префікса:

```powershell
.\BRAVO_SETUP.ps1 -Action Credentials -CredentialComponent Institution
```

Розширене керування credentials:

```powershell
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Required -StoreFor Both
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Test -Component Required -StoreFor Both
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Set -Component Institution -StoreFor Both
```

Основні дії:

| Дія | Поведінка |
|---|---|
| `Ensure` | створює лише відсутні записи, наявні не змінює |
| `Set` | створює або перезаписує вибрані записи |
| `Add` | помилка, якщо запис уже існує |
| `Update` | помилка, якщо запису немає |
| `Test` | лише перевіряє читання |
| `Remove` | видаляє вибрані записи; використовуйте обережно |

`Component Required` автоматично вибирає credentials для фактично ввімкнених
компонентів. Доступні також `All`, `SFTP`, `SMB`, `Slack`, `Discord`, `Archive`
та `Institution`.

## 8. Планувальник завдань

`.\BRAVO_TASKS_INSTALL.ps1` створює завдання у `\BRAVO\`:

| Завдання | Типовий розклад | Призначення |
|---|---|---|
| `BRAVO_ARCHIV` | щодня `23:00` | архівація та передача копій |
| `BRAVO_MAINTENANCE` | щодня `23:55` | обслуговування BRAVO |
| `BRAVO_ARCHIV_HEALTH` | кожні 240 хв. від `00:15` | контроль служб і локальних/SFTP/SMB копій |

Архівація, maintenance і health-check використовують спільний
`BRAVO_OPERATION.lock`. Якщо інша операція вже працює, наступна не накладається
на неї. Backup і maintenance можуть очікувати звільнення lock до 360 хвилин;
health-check пропускає перевірку під час активного backup.

Lock — це реальний ексклюзивний файловий handle (`FileShare.None`), а не
маркер-файл, тому Windows сама звільняє його одразу, якщо процес завершився
аварійно; окремої "stale lock"-логіки не потрібно. Для діагностики файл
містить JSON: `pid`, `processStartTime`, `hostname`, `operation`
(`Archive`/`Maintenance`), `startedAt`, `packageVersion`, `config` —
`processStartTime` і `hostname` дають змогу відрізнити той самий PID,
перевикористаний іншим процесом після перезавантаження сервера, від справді
активного запуску, коли з'ясовуєте, хто саме тримає lock на спільному сервері.

Якщо перед архівацією або maintenance встановлена керована служба не має стану
`Running`, Slack/Discord одразу отримує одне зведене попередження.
`BRAVO_ARCHIV` ніколи не зупиняє і не запускає служби — керування ними виконує
лише `BRAVO_MAINTENANCE`. Кожний архів читається з окремого VSS-знімка; якщо
знімок створити не вдалося, live-каталог не архівується і запуск повертає
помилку. Погодинний health-check повторно контролює встановлені
служби, крім служб із типом запуску `Disabled`; однакові health-alert
пригнічуються на інтервал `RepeatAlertAfterHours`.

Встановити або оновити лише завдання:

```powershell
.\BRAVO_TASKS_INSTALL.ps1 -ConfigPath ".\BRAVO.config"
```

Перевірити визначення без встановлення:

```powershell
.\BRAVO_TASKS_INSTALL.ps1 -ConfigPath ".\BRAVO.config" -ValidateOnly
```

Видалити завдання:

```powershell
.\BRAVO_TASKS_UNINSTALL.ps1 -ConfigPath ".\BRAVO.config"
```

Перед реальним встановленням скрипт:

- відмовляється створювати `SYSTEM`-завдання з каталогу профілю користувача;
- перевіряє та захищає ACL runtime-каталогу;
- вмикає журнал `Microsoft-Windows-TaskScheduler/Operational`;
- перевіряє фактичну реєстрацію Action, Arguments і WorkingDirectory;
- у разі помилки повертає попередній стан завдань.

## 9. Ручний production-запуск

Архівація:

```powershell
.\BRAVO_ARCHIV.ps1 -NoPause
```

Maintenance:

```powershell
.\BRAVO_MAINTENANCE.ps1
```

Health-check:

```powershell
.\BRAVO_HEALTH.ps1
```

Ці команди виконують **фактичні операції**. Перед першим production-запуском
обов'язково виконайте `.\BRAVO_SETUP.ps1` або щонайменше dry-run.

Додатковий параметр архівації `-SyncBAZA` примусово запитує синхронізацію BAZA,
якщо її дозволяє конфігурація. Для maintenance доступні службові перемикачі
`-ForceRestore`, `-DisableSizeCheck`, `-EnableAllSlack`, `-DisableAllSlack`,
`-AutoShutdown on|off` і `-ArchiveAfterMaintenance on|off`; змінювати їх слід
лише з розумінням впливу на production.

## 10. Оновлення в установі

1. Зробіть копію поточного `BRAVO.config`.
2. Атомарно замініть весь комплект новою версією: виконувані `.ps1`,
   `VERSION.json`, документацію та весь каталог `modules`. Не змішуйте модулі й
   wrappers із різних версій.
3. Після копіювання вилучіть застарілі root-бібліотеки
   `BRAVO_COMPATIBILITY.ps1`, `BRAVO_CREDENTIALS.ps1`,
   `BRAVO_HELPER_LOGGING.ps1`, `BRAVO_NOTIFICATION.ps1`,
   `BRAVO_ARCHIVE_HELPERS.ps1`, `BRAVO_ARCHIV_RUNTIME.ps1` і
   `BRAVO_SYSTEM_HELPERS.ps1`.
4. Порівняйте та перенесіть локальні значення шляхів, компонентів, служб,
   SFTP/SMB і розкладу у новий `BRAVO.config`.
5. Не переносіть у config секрети, назву установи, код або префікс — вони вже
   зберігаються у Credential Manager.
6. Запустіть:

```powershell
.\BRAVO_SELF_TEST.ps1
.\BRAVO_SETUP.ps1 -ValidateOnly
.\BRAVO_SETUP.ps1
```

Повторний `.\BRAVO_SETUP.ps1` використовує режим `Ensure`: наявні credentials не
запитуються і не перезаписуються. Завдання оновлюються відповідно до поточного
`schedulerSettings`.

## 11. Якщо вручну працює, а за розкладом — ні

Найчастіша причина — різний контекст: вручну скрипт бачить credentials і доступ
поточного користувача, а завдання працює від `SYSTEM`.

Виконайте від адміністратора:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -InspectOnly
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -TestAccess
```

Для перевірки webhook одним реальним повідомленням:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
```

Діагностика показує:

- чи існують і ввімкнені всі очікувані завдання;
- точні Action, Arguments, WorkingDirectory і task account;
- `LastTaskResult` з текстовим поясненням;
- історію Task Scheduler Operational;
- dry-run і доступи саме від `SYSTEM`.

Типові `LastTaskResult`:

| Код | Значення |
|---|---|
| `0x00000000` | успішно |
| `0x00041301` | завдання зараз виконується |
| `0x00041303` | завдання ще не запускалося |
| `0x80070002` | не знайдено скрипт або config |
| `0x80070005` | відмовлено в доступі |
| `0x8007010B` | некоректний робочий каталог |
| `0x8007052E` | помилка входу облікового запису |

Якщо 7-Zip повертає code `1` або іншу помилку, у тому самому журналі
`BRAVO_ARCHIV_*.log` після загального повідомлення записуються останні рядки
stdout/stderr. Зазвичай вони містять точний недоступний, заблокований або
пропущений файл.

Якщо tasks відсутні, запустіть `.\BRAVO_SETUP.ps1 -Action Scheduler`. Якщо
діагностика не читає credentials від `SYSTEM`, повторіть:

```powershell
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Required -StoreFor Both
```

На локалізованій Windows Task Scheduler може показувати `SYSTEM` як `СИСТЕМА`
або іншу перекладену назву. Інсталятор порівнює вбудовані облікові записи за
мовно-незалежним SID, тому це не є помилкою.

## 12. Логи та результати

Основні журнали знаходяться у `ArchiveRoot\LOGS`, за замовчуванням:

```text
C:\LIMS\ARCHIV\LOGS
```

Marker `restore_done_yyyyMMdd.marker` створюється лише після успішної
реставрації, перевіреного after-архіву та SHA512. Він записується атомарно у
UTF-8 і не створюється після примусового `-ForceRestore`.

Допоміжні скрипти `BRAVO_SETUP`, `BRAVO_DRY_RUN`,
`BRAVO_CREDENTIALS_SETUP`, `BRAVO_TASKS_INSTALL`,
`BRAVO_TASKS_UNINSTALL`, `BRAVO_TASKS_DIAGNOSE` і `BRAVO_SELF_TEST` створюють
окремий transcript для кожного процесу:

```text
C:\LIMS\ARCHIV\LOGS\HELPERS\<SCRIPT>_yyyyMMdd_HHmmss_fff_PID<n>.log
```

У журналі є контекст запуску, консольний результат і фінальний process exit
code. Це дозволяє окремо бачити батьківський setup, дочірні етапи та перевірки
від `SYSTEM`. Helper-логи зберігаються 31 день. Якщо основний каталог
недоступний для запису, скрипт попереджає про це і використовує резервний
`%TEMP%\BRAVO\LOGS\HELPERS`.

Значення паролів, які вводяться через захищений prompt, у лог не виводяться.
Не передавайте секрети як довільні аргументи командного рядка.

Додатково переглядайте:

- Event Viewer → Applications and Services Logs → Microsoft → Windows →
  TaskScheduler → Operational;
- властивості завдань у `Task Scheduler Library\BRAVO`;
- `Last Run Result` і час наступного запуску.

Для dry-run код завершення `0` означає відсутність критичних проблем, `1` —
щонайменше одну критичну проблему. PowerShell-скрипти повертають код PowerShell
скрипта, тому результат можна використовувати в автоматичних перевірках.

### Коди завершення production-скриптів

`BRAVO_ARCHIV.ps1`, `BRAVO_MAINTENANCE.ps1` і `BRAVO_HEALTH.ps1` повертають
один зі стабільних кодів контракту `modules\BRAVO.ExitCodes`, а не просто
`0`/`1`. Це дозволяє зовнішньому моніторингу (Task Scheduler history, Zabbix)
розрізняти причину відмови, а не лише факт її наявності:

| Код | Значення |
|---|---|
| `0` | успішно |
| `10` | успішно, але в лозі були попередження |
| `20` | пропущено — спільний lock зайнятий іншою операцією |
| `30` | некоректна конфігурація |
| `31` | недоступні credentials |
| `32` | порушено цілісність інструментів (`TOOLS_MANIFEST.json`) — запуск заблоковано |
| `33` | порушено цілісність PowerShell-комплекту (`RUNTIME_MANIFEST.json`) — запуск заблоковано до завантаження модулів |
| `40` | помилка локальної архівації або відновлення з архіву |
| `41` | не підтверджено цілісність (7-Zip test / SHA512) |
| `50` | помилка SFTP |
| `51` | помилка SMB |
| `60` | інша критична помилка обслуговування (Maintenance) |
| `70` | health-check критичний |
| `90` | непередбачена внутрішня помилка |

При одночасних відмовах перемагає найвищий пріоритет: lock > конфігурація >
credentials > локальна архівація > цілісність > SFTP > SMB > maintenance >
health > лише попередження. Код `90` має найвищий пріоритет за все — він
означає, що runtime не встиг сам категоризувати відмову.

Сам код `70` (health-check критичний) — лише один агрегований показник;
щоб зовнішній моніторинг бачив, який саме напрямок деградував, а не тільки
факт наявності проблеми, програмний Health API (`Invoke-BRAVOHealthCheck`)
повертає окремі `LocalVerified`/`SftpVerified`/`SmbVerified` у result object
— відмова одного напрямку (наприклад SFTP недоступний) не впливає на
значення інших, бо кожен перевіряється незалежним викликом.

### Матриця діагностики за кодом завершення

Куди дивитись у журналі `LOGS\BRAVO_ARCHIV_*.log` /
`BRAVO_MAINTENANCE_*.log` / `BRAVO_ARCHIV_HEALTH_*.log` для кожного коду:

| Код | Найімовірніша причина | Де дивитись |
|---|---|---|
| `20` | Інший екземпляр Archive/Maintenance ще виконується | `BRAVO_OPERATION.lock` (JSON: `pid`, `hostname`, `operation`, `startedAt`) у `LOGS`; збільшіть `OperationLockWaitMinutes`, якщо це штатне перекриття довгих завдань |
| `30` | Некоректний/відсутній розділ `BRAVO.config` (`maintenanceSettings`, `pathSettings` тощо) | Перший `[ERROR]` одразу після `=== ПЕРЕВІРКА СУМІСНОСТІ СИСТЕМИ ===`; `.\BRAVO_SETUP.ps1 -ValidateOnly` відтворює ту саму перевірку без production-дій |
| `31` | Відсутній або порожній запис Credential Manager для потрібного компонента | Рядок `credentialInitializationError`/`archiveCredentialInitializationError` у консольному виводі; `.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Test -Component Required -StoreFor Both` |
| `32` | SHA-256 файлу в `Tools/` не збігається з еталонним `TOOLS_MANIFEST.json`, або маніфест відсутній/пошкоджений | Рядок `ЦIЛIСНIСТЬ IНСТРУМЕНТIВ ПОРУШЕНО` на старті логу. Якщо оновлення інструментів свідоме — оновіть маніфест на робочій станції (`ci\Update-BRAVOToolsManifest.ps1 -Apply`), перегляньте `git diff`, розгорніть новий комплект. Якщо ні — це можлива підміна: заплановане завдання виконується від `SYSTEM`, тому інструмент отримав би найвищі права |
| `33` | SHA-256 файлу комплекту не збігається з `RUNTIME_MANIFEST.json`, файл відсутній, або в комплекті з'явився сторонній `.ps1`/`.psm1` | Рядок `ЦІЛІСНІСТЬ КОМПЛЕКТУ ПОРУШЕНО` — це найперше, що виводиться, ще до завантаження модулів. Якщо оновлення коду свідоме: `ci\Update-BRAVORuntimeManifest.ps1 -Apply` на робочій станції, `git diff`, розгортання нового комплекту |
| `40` | Провал створення архіву 7-Zip, або (Maintenance) провал відновлення з архіву | `[ERROR]` у секції `АРХІВАЦІЯ <компонент>`/`ВІДНОВЛЕННЯ`; останні рядки stdout/stderr 7-Zip записуються одразу після загального повідомлення |
| `41` | `7z test` або SHA512-звірка не підтвердили цілісність | `Перевiрка цiлiсностi 7-Zip не пройдена` у секції `АРХІВАЦІЯ`; пошкоджений архів навмисно залишається на диску для діагностики (не видаляється) |
| `50` | SFTP: з'єднання, автентифікація або передача файлу | Секція `ЗАВАНТАЖЕННЯ АРХІВІВ НА SFTP` / `СИНХРОНІЗАЦІЯ BAZA НА SFTP`; перевірте `sftpHostKey` fingerprint і мережевий доступ до TCP 22 |
| `51` | SMB/NAS: недоступний UNC-шлях або облікові дані | Секція `КОПІЮВАННЯ АРХІВІВ НА NAS/SMB`; перевірте доступність UNC-шляху від `SYSTEM` через `BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess` |
| `60` | Maintenance: служби, диск, файлове господарство — усе, що не потрапляє під `40`/`41` | Секція, де `Результат: ПОМИЛКА` вперше з'являється в `BRAVO_MAINTENANCE_*.log`; часто — недостатньо вільного місця (`Limits.MinimumFreeSpaceGB`) або служба не в стані `Running` |
| `70` | Health-check: локальні/SFTP/SMB копії застаріли, або керована служба не працює | `BRAVO_ARCHIV_HEALTH_*.log`, рядки `[ERROR] Проблема ...`; дивіться `LocalVerified`/`SftpVerified`/`SmbVerified`, якщо результат читається програмно |
| `90` | Непередбачений виняток, якого runtime не встиг категоризувати | `Write-Error`/останній `[ERROR]` перед аварійним завершенням; часто вказує на прогалину в конфігурації, яку варто завести як окремий issue, а не лише перезапустити завдання |

Для `LastTaskResult` самого Task Scheduler (окремо від кодів вище —
це код запуску процесу, а не BRAVO) дивіться таблицю на початку цього
розділу.

## 13. Призначення файлів

### Основні точки входу

| Файл | Призначення |
|---|---|
| `BRAVO_SETUP.ps1` | комплексна інсталяція, credentials, tasks і тест |
| `BRAVO_DRY_RUN.ps1` | симуляція без production-операцій |
| `BRAVO_ARCHIV.ps1` | production-архівація |
| `BRAVO_MAINTENANCE.ps1` | production-обслуговування |
| `BRAVO_HEALTH.ps1` | контроль резервних копій і служб |
| `BRAVO_TASKS_DIAGNOSE.ps1` | діагностика Планувальника і запуск від `SYSTEM` |
| `BRAVO_RESTORE_TEST.ps1` | restore drill — розпакування останнього verified backup в ізольований каталог (розділ 6.1) |

### Службові файли

| Файл | Призначення |
|---|---|
| `BRAVO.config` | головна конфігурація BRAVO |
| `BRAVO_CREDENTIALS_SETUP.ps1` | керування записами Credential Manager |
| `modules\BRAVO.Credentials` | модуль читання/запису credentials |
| `modules\BRAVO.HelperLogging` | модуль transcript-журналювання допоміжних скриптів |
| `BRAVO_TASKS_INSTALL.ps1` | встановлення завдань |
| `BRAVO_TASKS_UNINSTALL.ps1` | видалення завдань |
| `modules\BRAVO.Compatibility` | модуль сумісності зі старими Windows/PowerShell |
| `modules\BRAVO.Archive` | runtime-модуль архівації; `BRAVO_ARCHIV.ps1` є тонким wrapper |
| `modules\BRAVO.Health` | runtime-модуль health-check; `BRAVO_HEALTH.ps1` є тонким wrapper |
| `modules\BRAVO.Maintenance` | runtime-модуль maintenance; `BRAVO_MAINTENANCE.ps1` є тонким wrapper |
| `BRAVO_SELF_TEST.ps1` | автоматичні регресійні тести |

Детальні параметри комплексного setup наведені у
[BRAVO_SETUP.md](BRAVO_SETUP.md), історія версій — у
[CHANGELOG.md](CHANGELOG.md), модель безпеки й порядок повідомлення про
вразливості — у [SECURITY.md](SECURITY.md), а чек-лист перед випуском
нової версії — у [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

### Гілки та release channel

`VERSION.json.releaseChannel` — це лише **нейтральний fallback**
(`"stable"`), однаковий на обох гілках у git. Реальний release channel
визначається динамічно під час завантаження конфігурації
(`Resolve-BRAVOReleaseChannelFromGit`, `BRAVO_CONFIG_LOADER.ps1`): якщо
поруч є каталог `.git`, значення читається напряму з `.git/HEAD`
(без виклику `git.exe`, який може бути відсутній на production-сервері):

| Гілка | Ефективний `releaseChannel` | Призначення |
|---|---|---|
| `developer` | `development` | Поточна розробка; може містити ще не повністю перевірені зміни |
| `master`/`main` | `stable` | Стабільний стан для production-розгортання |
| інша гілка / detached HEAD | статичне значення з `VERSION.json` (`stable`) | fallback, коли гілку не вдалося однозначно визначити |
| без `.git` (розгорнутий production-сервер) | статичне значення з `VERSION.json` (`stable`) | дистрибутив копіюється файлами, не клонується |

Раніше `releaseChannel` зберігався як буквальне значення, що вручну
різнилося між гілками — кожен merge `developer` → `master` вимагав
окремого follow-up commit, а fast-forward-мержі могли мовчки протягнути
значення в неправильний бік і в той, і в інший бік (AUD-016). Тепер
джерело не потребує ручного редагування цього поля взагалі:
`BRAVO_SELF_TEST.ps1` перевіряє, що на `developer` ефективний channel —
`development` (з `ReleaseChannelSource=git-branch`), а на `master`/`main`
— ніколи не `development`.

## 14. Правила безпеки

- не записуйте паролі, webhook URL або логіни у `.config`, `.ps1` чи
  логи;
- не розміщуйте SYSTEM runtime у каталозі, доступному звичайним користувачам
  на запис;
- не вимикайте `RequireProtectedRuntime`, окрім контрольованої міграції;
- не додавайте `-delete` до SFTP-синхронізації BAZA: хмара є накопичувальною;
- після зміни SFTP fingerprint перевірте його через незалежний довірений канал;
- пароль 7-Zip передається утиліті лише через redirected standard input і не
  повинен повертатися до аргументів процесу; це контролює self-test;
- перед production-змінами завжди виконуйте self-test, `-ValidateOnly` і
  dry-run;
- `enableArchiveDeletion` ніколи не видаляє останні `minimumRetainedVerifiedBackups`
  (за замовчуванням `1`) перевірених (SHA512 збігається) комплектів кожного
  компонента, навіть якщо вони старші за `archiveRetentionDays` — серія
  невдалих backup не повинна лишити компонент без жодної придатної копії;
- помилки завантаження `BRAVO.config` і читання Credential Manager
  (SFTP/SMB/архів/webhook) маскуються `Protect-BRAVOLogSecret` одразу при
  захопленні винятку, а не лише при подальшому записі в лог — ці
  повідомлення друкуються у консоль ще до того, як спрацює єдина точка
  масковки в `Write-Log`;
- `hostInformationSettings.PublicIPLookupEnabled` вимкнено за замовчуванням:
  без цього Slack/Discord-сповіщення звертаються до `api.ipify.org`/
  `checkip.amazonaws.com`, зайвої зовнішньої залежності, яка розкриває
  стороннім сервісам факт і час запуску backup. Увімкніть свідомо, якщо
  публічна IP-адреса потрібна в сповіщеннях.
