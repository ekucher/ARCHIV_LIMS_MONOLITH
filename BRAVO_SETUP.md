# BRAVO 4.2.12 — комплексне налаштування і безпечний тестовий прогін

Кожен запуск setup і його допоміжних дочірніх скриптів створює окремий
transcript у `LOGS\HELPERS`. Ім'я містить назву скрипта, timestamp і PID, а
журнал завершується process exit code. Строк зберігання helper-логів — 31 день.

## Швидкий запуск

Запустіть від адміністратора:

```powershell
.\BRAVO_SETUP.ps1
```

Стандартний режим `Full` послідовно:

1. перевіряє конфігурацію, скрипти, інструменти та джерельні каталоги;
2. перевіряє Credential Manager і запитує тільки відсутні параметри установи та секрети;
3. повторно читає записи з обох сховищ;
4. валідує та встановлює завдання з `schedulerSettings`;
5. запускає dry-run від `NT AUTHORITY\SYSTEM`, тобто від task account;
6. виконує безпечний read-only тест SFTP/SMB;
7. надсилає одне тестове повідомлення у налаштований Slack або Discord.

Архівація, копіювання, синхронізація, видалення, перезапуск служб,
shutdown та інші production-операції у цьому сценарії не виконуються.
Тестове повідомлення — єдина зовнішня операція запису.

## Розташування runtime і безпека

Не встановлюйте SYSTEM-завдання зі `Desktop`, `Documents`, `Downloads` або
іншого каталогу профілю користувача. Робочий комплект потрібно розміщувати,
наприклад, у `C:\LIMS\ARCHIV`.

Під час інсталяції Планувальника `BRAVO_TASKS_INSTALL.ps1` відмовляється
створювати SYSTEM-завдання з профілю користувача, захищає runtime ACL та
вмикає журнал `Microsoft-Windows-TaskScheduler/Operational`.

## Локальні параметри установи

Стандартний компонент `Required` тепер створює три додаткові записи:

- `BRAVO_INSTITUTION_NAME` — назва установи;
- `BRAVO_INSTITUTION_CODE` — код установи;
- `BRAVO_ARCHIVE_PREFIX` — префікс імен архівів.

`BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`, `BRAVO_ARCHIV_HEALTH` і dry-run
завантажують ці значення після `BRAVO.config`. Тому під час оновлення можна
замінювати стандартний config без повторного ручного редагування назви
установи, коду та префікса.

Значення у `BRAVO.config` залишаються fallback для першого запуску. Фінальний
dry-run повідомляє про відсутні записи Credential Manager як про помилку.

Окреме оновлення лише цих параметрів:

```powershell
.\BRAVO_SETUP.ps1 -Action Credentials -CredentialComponent Institution
```

Або без комплексного оркестратора:

```powershell
.\BRAVO_CREDENTIALS_SETUP.ps1 -Action Set -Component Institution -StoreFor Both
```

`ArchivePrefix` обмежено латинськими літерами, цифрами, `.`, `_` і `-`, тому
він безпечний для назв файлів, wildcard і регулярних виразів retention.
Після зміни префікса старі архіви залишаються на диску, але health-check і
retention нового запуску шукають уже новий префікс.

Повторний `.\BRAVO_SETUP.ps1` працює в режимі `Ensure`: якщо записи вже наявні
для поточного користувача та `SYSTEM`, значення не запитуються і не
перезаписуються. Якщо компонент відсутній, запитується лише він.

## Спочатку лише перевірка

```powershell
.\BRAVO_SETUP.ps1 -ValidateOnly
```

Цей режим не створює і не змінює постійні записи Credential Manager та
завдання Планувальника. Для перевірки Credential Manager облікового запису
`SYSTEM` може короткочасно створюватися службове завдання, яке автоматично
видаляється скриптом `BRAVO_CREDENTIALS_SETUP.ps1`.

У режимі `-ValidateOnly` тестове повідомлення не надсилається.

Якщо зовнішня мережа під час інсталяції недоступна:

```powershell
.\BRAVO_SETUP.ps1 -SkipAccessTest
```

Щоб виконати read-only тести SFTP/SMB, але не надсилати тестове повідомлення:

```powershell
.\BRAVO_SETUP.ps1 -SkipTestNotification
```

## Окремі етапи

Лише credentials:

```powershell
.\BRAVO_SETUP.ps1 -Action Credentials
```

Лише Планувальник:

```powershell
.\BRAVO_SETUP.ps1 -Action Scheduler
```

Діагностика реєстрації, `LastTaskResult` і end-to-end доступу від `SYSTEM`:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -TestAccess
```

Лише перегляд реєстрації без UAC і без тимчасового SYSTEM-завдання:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -InspectOnly
```

З одним тестовим повідомленням від `SYSTEM`:

```powershell
.\BRAVO_TASKS_DIAGNOSE.ps1 -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
```

Тільки комплексна перевірка без змін:

```powershell
.\BRAVO_SETUP.ps1 -Action Test -ValidateOnly
```

## Окремий dry-run

Без мережевої автентифікації:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config"
```

З read-only перевіркою доступів:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config" -TestAccess
```

З end-to-end надсиланням одного тестового повідомлення:

```powershell
.\BRAVO_DRY_RUN.ps1 -ConfigPath ".\BRAVO.config" -TestAccess -SendTestNotification
```

`-TestAccess` виконує:

- SFTP: TCP-з’єднання, автентифікацію WinSCP і читання каталогу `.`;
- SMB: тимчасове підключення `PSDrive` та читання кореня, після чого drive видаляється;
- Slack/Discord з `-TestAccess`: лише TCP-доступність HTTPS endpoint;
- Slack/Discord з `-SendTestNotification`: HTTP POST тестового повідомлення.

Для Discord payload містить `allowed_mentions.parse = []`, тому тестове
повідомлення не створює mentions. Невдале надсилання є критичною помилкою і
повертає код завершення `1`.

Код завершення `0` означає відсутність помилок, `1` — щонайменше одну
критичну проблему. Рядки `PLAN` описують операції, які production-скрипт
виконав би, але dry-run їх не запускає.
