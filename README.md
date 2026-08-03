# BRAVO 4.2.1 — архівація, обслуговування та контроль резервних копій

Цей комплект автоматизує:

- архівацію `MODEL`, `BLOG` і `BRAVOEXCH`;
- локальну та SFTP-синхронізацію `BAZA`;
- копіювання архівів на SFTP і, за потреби, SMB/NAS;
- обслуговування служб BRAVO;
- перевірку локальних, SFTP і SMB-копій;
- сповіщення у Slack або Discord;
- створення й діагностику завдань Планувальника Windows.

Для звичайного встановлення не потрібно запускати всі скрипти окремо. Основна
точка входу — **`BRAVO_SETUP.cmd`**.

> **Важливо:** production-комплект для завдань від `SYSTEM` не можна запускати з
> `Desktop`, `Documents`, `Downloads` або іншого каталогу профілю користувача.
> Рекомендоване розташування — `C:\LIMS\ARCHIV`. Каталог зі скриптами має
> називатися саме `ARCHIV`.

## Швидкий вибір команди

| Що потрібно зробити | Команда |
|---|---|
| Перша інсталяція або повне оновлення | `BRAVO_SETUP.cmd` |
| Перевірити все без постійних змін | `BRAVO_SETUP.cmd -ValidateOnly` |
| Симулювати production-операції | `BRAVO_DRY_RUN.cmd` |
| Перевірити реєстрацію завдань без UAC | `BRAVO_TASKS_DIAGNOSE.cmd -InspectOnly` |
| Перевірити завдання та доступ від `SYSTEM` | `BRAVO_TASKS_DIAGNOSE.cmd -TestAccess` |
| Оновити лише параметри установи | `BRAVO_SETUP.cmd -Action Credentials -CredentialComponent Institution` |
| Запустити архівацію вручну | `BRAVO_ARCHIV.cmd -NoPause` |
| Запустити обслуговування вручну | `BRAVO_MAINTENANCE.cmd` |
| Запустити health-check вручну | `BRAVO_HEALTH.cmd` |
| Виконати тести коду | `BRAVO_SELF_TEST.cmd` |

Усі команди в цій інструкції потрібно виконувати з каталогу `ARCHIV`. Для
інсталяції, зміни Credential Manager для `SYSTEM` і Планувальника відкрийте
`cmd.exe` або PowerShell **від імені адміністратора**.

## 1. Системні вимоги

- Windows 7 / Windows Server 2008 R2 або новіша система;
- Windows PowerShell 3.0 або новіший; рекомендовано WMF/PowerShell 5.1;
- 64-бітна Windows для повного сценарію обслуговування;
- локальні права адміністратора для встановлення завдань і керування службами;
- доступний VSS на локальних томах із `MODEL`, `BLOG` і `BRAVOEXCH`;
- доступ до SFTP через TCP 22, якщо SFTP-компоненти ввімкнені;
- доступ до Slack/Discord через HTTPS 443, якщо сповіщення ввімкнені;
- доступ до потрібного UNC-шляху, якщо SMB/NAS ввімкнений.

У каталозі `ARCHIV\Tools` мають бути:

| Файл | Для чого потрібен |
|---|---|
| `7za.exe` | Створення та повна перевірка архівів |
| `WinSCP.com` | Production-передача і синхронізація SFTP |
| `WinSCPnet.dll` | Автентифікований read-only тест SFTP |
| `WinSCP.exe` | Працює в парі з `WinSCPnet.dll` під час тесту доступу |

## 2. Рекомендована структура каталогів

```text
C:\LIMS\
├── Model\                 джерело MODEL
├── BLOG\                  джерело BLOG
├── BAZA\                  джерело BAZA, якщо ввімкнено
└── ARCHIV\
    ├── README.md
    ├── BRAVO.config
    ├── BRAVO_*.ps1
    ├── BRAVO_*.cmd
    ├── Tools\
    │   ├── 7za.exe
    │   ├── WinSCP.com
    │   ├── WinSCP.exe
    │   └── WinSCPnet.dll
    ├── LOGS\              створюється автоматично
    ├── MODEL\             локальні архіви
    ├── BLOG\
    ├── BRAVOEXCH\
    └── BAZA\              локальна копія BAZA, якщо ввімкнено
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

```bat
cd /d C:\LIMS\ARCHIV
BRAVO_SELF_TEST.cmd
```

Self-test перевіряє синтаксис усіх PowerShell-файлів, узгодженість версій,
захисні параметри backup, спільний operation lock і визначення завдань
Планувальника без production-архівації.

### Крок 3. Перевірити конфігурацію без змін

```bat
BRAVO_SETUP.cmd -ValidateOnly
```

Цей режим не створює постійні credentials або production-завдання і не
надсилає тестове повідомлення. Для читання Credential Manager від `SYSTEM`
може бути створене короткочасне службове завдання, яке видаляється автоматично.

### Крок 4. Запустити комплексне налаштування

```bat
BRAVO_SETUP.cmd
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

```bat
BRAVO_SETUP.cmd -SkipAccessTest
```

Якщо потрібно перевірити SFTP/SMB, але не надсилати повідомлення:

```bat
BRAVO_SETUP.cmd -SkipTestNotification
```

### Крок 5. Перевірити створені завдання

```bat
BRAVO_TASKS_DIAGNOSE.cmd -InspectOnly
BRAVO_TASKS_DIAGNOSE.cmd -TestAccess
```

Перший виклик лише читає реєстрацію. Другий запускає end-to-end dry-run від
`SYSTEM` і перевіряє реальний доступ без архівації чи синхронізації.

## 6. Безпечний тестовий прогін

Лише перевірка конфігурації, файлів, каталогів, tools і плану операцій:

```bat
BRAVO_DRY_RUN.cmd -ConfigPath ".\BRAVO.config"
```

Додатково перевірити реальну автентифікацію та read-only доступ:

```bat
BRAVO_DRY_RUN.cmd -ConfigPath ".\BRAVO.config" -TestAccess
```

End-to-end тест із одним реальним Slack/Discord повідомленням:

```bat
BRAVO_DRY_RUN.cmd -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
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

## 7. Окремі етапи налаштування

Комплексний setup можна обмежити одним етапом:

```bat
BRAVO_SETUP.cmd -Action Credentials
BRAVO_SETUP.cmd -Action Scheduler
BRAVO_SETUP.cmd -Action Test -ValidateOnly
```

Оновлення лише назви установи, коду і префікса:

```bat
BRAVO_SETUP.cmd -Action Credentials -CredentialComponent Institution
```

Розширене керування credentials:

```bat
BRAVO_CREDENTIALS_SETUP.cmd -Action Ensure -Component Required -StoreFor Both
BRAVO_CREDENTIALS_SETUP.cmd -Action Test -Component Required -StoreFor Both
BRAVO_CREDENTIALS_SETUP.cmd -Action Set -Component Institution -StoreFor Both
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

`BRAVO_TASKS_INSTALL.cmd` створює завдання у `\BRAVO\`:

| Завдання | Типовий розклад | Призначення |
|---|---|---|
| `BRAVO_ARCHIV` | щодня `23:00` | архівація та передача копій |
| `BRAVO_MAINTENANCE` | щодня `23:55` | обслуговування BRAVO |
| `BRAVO_ARCHIV_HEALTH` | кожні 240 хв. від `00:15` | контроль служб і локальних/SFTP/SMB копій |

Архівація, maintenance і health-check використовують спільний
`BRAVO_OPERATION.lock`. Якщо інша операція вже працює, наступна не накладається
на неї. Backup і maintenance можуть очікувати звільнення lock до 360 хвилин;
health-check пропускає перевірку під час активного backup.

Якщо перед архівацією або maintenance встановлена керована служба не має стану
`Running`, Slack/Discord одразу отримує одне зведене попередження.
`BRAVO_ARCHIV` ніколи не зупиняє і не запускає служби — керування ними виконує
лише `BRAVO_MAINTENANCE`. Кожний архів читається з окремого VSS-знімка; якщо
знімок створити не вдалося, live-каталог не архівується і запуск повертає
помилку. Погодинний health-check повторно контролює встановлені
служби, крім служб із типом запуску `Disabled`; однакові health-alert
пригнічуються на інтервал `RepeatAlertAfterHours`.

Встановити або оновити лише завдання:

```bat
BRAVO_TASKS_INSTALL.cmd -ConfigPath ".\BRAVO.config"
```

Перевірити визначення без встановлення:

```bat
BRAVO_TASKS_INSTALL.cmd -ConfigPath ".\BRAVO.config" -ValidateOnly
```

Видалити завдання:

```bat
BRAVO_TASKS_UNINSTALL.cmd -ConfigPath ".\BRAVO.config"
```

Перед реальним встановленням скрипт:

- відмовляється створювати `SYSTEM`-завдання з каталогу профілю користувача;
- перевіряє та захищає ACL runtime-каталогу;
- вмикає журнал `Microsoft-Windows-TaskScheduler/Operational`;
- перевіряє фактичну реєстрацію Action, Arguments і WorkingDirectory;
- у разі помилки повертає попередній стан завдань.

## 9. Ручний production-запуск

Архівація:

```bat
BRAVO_ARCHIV.cmd -NoPause
```

Maintenance:

```bat
BRAVO_MAINTENANCE.cmd
```

Health-check:

```bat
BRAVO_HEALTH.cmd
```

Ці команди виконують **фактичні операції**. Перед першим production-запуском
обов'язково виконайте `BRAVO_SETUP.cmd` або щонайменше dry-run.

Додатковий параметр архівації `-SyncBAZA` примусово запитує синхронізацію BAZA,
якщо її дозволяє конфігурація. Для maintenance доступні службові перемикачі
`-ForceRestore`, `-DisableSizeCheck`, `-EnableAllSlack`, `-DisableAllSlack`,
`-AutoShutdown on|off` і `-ArchiveAfterMaintenance on|off`; змінювати їх слід
лише з розумінням впливу на production.

## 10. Оновлення в установі

1. Зробіть копію поточного `BRAVO.config`.
2. Замініть `.ps1`, `.cmd` і документацію новою версією.
3. Порівняйте та перенесіть локальні значення шляхів, компонентів, служб,
   SFTP/SMB і розкладу у новий `BRAVO.config`.
4. Не переносіть у config секрети, назву установи, код або префікс — вони вже
   зберігаються у Credential Manager.
5. Запустіть:

```bat
BRAVO_SELF_TEST.cmd
BRAVO_SETUP.cmd -ValidateOnly
BRAVO_SETUP.cmd
```

Повторний `BRAVO_SETUP.cmd` використовує режим `Ensure`: наявні credentials не
запитуються і не перезаписуються. Завдання оновлюються відповідно до поточного
`schedulerSettings`.

## 11. Якщо вручну працює, а за розкладом — ні

Найчастіша причина — різний контекст: вручну скрипт бачить credentials і доступ
поточного користувача, а завдання працює від `SYSTEM`.

Виконайте від адміністратора:

```bat
BRAVO_TASKS_DIAGNOSE.cmd -ConfigPath ".\BRAVO.config" -InspectOnly
BRAVO_TASKS_DIAGNOSE.cmd -ConfigPath ".\BRAVO.config" -TestAccess
```

Для перевірки webhook одним реальним повідомленням:

```bat
BRAVO_TASKS_DIAGNOSE.cmd -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
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

Якщо tasks відсутні, запустіть `BRAVO_SETUP.cmd -Action Scheduler`. Якщо
діагностика не читає credentials від `SYSTEM`, повторіть:

```bat
BRAVO_CREDENTIALS_SETUP.cmd -Action Ensure -Component Required -StoreFor Both
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
щонайменше одну критичну проблему. `.cmd` wrappers повертають код PowerShell
скрипта, тому результат можна використовувати в автоматичних перевірках.

## 13. ARCHIV_VETOFFICE

`ARCHIV_VETOFFICE` є окремим сумісним сценарієм зі своїм
`ARCHIV_VETOFFICE.config.ps1`. Він може використовувати спільні credentials і
dry-run, але не має повної секції `schedulerSettings` для
`BRAVO_TASKS_INSTALL.ps1`.

Налаштувати потрібні credentials для поточного користувача та `SYSTEM`:

```bat
BRAVO_CREDENTIALS_SETUP.cmd -ConfigPath ".\ARCHIV_VETOFFICE.config.ps1" -Action Ensure -Component Required -StoreFor Both
```

Безпечна перевірка:

```bat
BRAVO_DRY_RUN.cmd -ConfigPath ".\ARCHIV_VETOFFICE.config.ps1" -TestAccess
```

Команди самого VETOFFICE:

```bat
ARCHIV_VETOFFICE.cmd -Help
ARCHIV_VETOFFICE.cmd -Schedule
ARCHIV_VETOFFICE.cmd -ShowTasks
ARCHIV_VETOFFICE.cmd -RemoveTask
```

Запуск без параметрів виконує фактичну архівацію:

```bat
ARCHIV_VETOFFICE.cmd
```

Для VETOFFICE назва/код установи не винесені у Credential Manager, бо його
конфігурація їх не використовує. Префікс VETOFFICE поки що задається у
`ARCHIV_VETOFFICE.config.ps1`.

## 14. Призначення файлів

### Основні точки входу

| Файл | Призначення |
|---|---|
| `BRAVO_SETUP.cmd/.ps1` | комплексна інсталяція, credentials, tasks і тест |
| `BRAVO_DRY_RUN.cmd/.ps1` | симуляція без production-операцій |
| `BRAVO_ARCHIV.cmd/.ps1` | production-архівація |
| `BRAVO_MAINTENANCE.cmd/.ps1` | production-обслуговування |
| `BRAVO_HEALTH.cmd/.ps1` | контроль резервних копій і служб |
| `BRAVO_TASKS_DIAGNOSE.cmd/.ps1` | діагностика Планувальника і запуск від `SYSTEM` |

### Службові файли

| Файл | Призначення |
|---|---|
| `BRAVO.config` | головна конфігурація BRAVO |
| `BRAVO_CREDENTIALS_SETUP.cmd/.ps1` | керування записами Credential Manager |
| `BRAVO_CREDENTIALS.ps1` | внутрішня бібліотека читання/запису credentials |
| `BRAVO_HELPER_LOGGING.ps1` | спільне transcript-журналювання допоміжних скриптів |
| `BRAVO_TASKS_INSTALL.cmd/.ps1` | встановлення завдань |
| `BRAVO_TASKS_UNINSTALL.cmd/.ps1` | видалення завдань |
| `BRAVO_COMPATIBILITY.ps1` | сумісність зі старими Windows/PowerShell |
| `BRAVO_SELF_TEST.cmd/.ps1` | автоматичні регресійні тести |
| `ARCHIV_VETOFFICE.*` | окремий сценарій VETOFFICE |

Детальні параметри комплексного setup наведені у
[BRAVO_SETUP.md](BRAVO_SETUP.md), а історія версій — у
[CHANGELOG.md](CHANGELOG.md).

## 15. Правила безпеки

- не записуйте паролі, webhook URL або логіни у `.config`, `.ps1`, `.cmd` чи
  логи;
- не розміщуйте SYSTEM runtime у каталозі, доступному звичайним користувачам
  на запис;
- не вимикайте `RequireProtectedRuntime`, окрім контрольованої міграції;
- не додавайте `-delete` до SFTP-синхронізації BAZA: хмара є накопичувальною;
- після зміни SFTP fingerprint перевірте його через незалежний довірений канал;
- враховуйте, що пароль 7-Zip передається утиліті як аргумент процесу через
  обмеження CLI 7-Zip; обмежуйте локальні адміністративні права і доступ до
  сервера;
- перед production-змінами завжди виконуйте self-test, `-ValidateOnly` і
  dry-run.
