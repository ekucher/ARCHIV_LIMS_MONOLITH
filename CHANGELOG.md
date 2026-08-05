# Changelog

## Не випущено

- **Літерали, що виглядають як облікові дані, прибрані з тестових
  фікстур.** У тесті `Protect-BRAVOLogSecret` лежали sftp-URL із паролем,
  повні Slack/Discord webhook-URL із токенами й паролі 7-Zip — записані
  літералами. Значення вигадані, але для сканера це справжні секрети:
  саме через них GitGuardian періодично піднімав інциденти, які
  доводилось закривати вручну.

  Альтернатива «додати виняток сканеру» гірша: виняток глушить і
  справжній витік у тому самому файлі. Тому фікстури тепер збираються з
  частин у рантаймі, а перевірки звіряються зі змінними — маскування
  тестується так само строго.

  Самотест `Secrets/NoCredentialShapedLiterals` не дає їм повернутись.
  Перевіряються лише **строкові літерали з AST**: коментарі й
  документація свідомо поза межами, бо там форма URL з обліковими даними
  потрібна, щоб пояснити, що саме маскується. Плейсхолдерами вважаються
  узагальнені слова (`pass`, `password`), маска `***`, підстановка
  формату `{0}` і посилання на змінну — останнє обов'язкове, бо
  `New-BRAVOSftpUrl` будує саме такий рядок із `${escapedPassword}`, і
  перша версія перевірки на цьому робочому коді спіткнулась.

- **Аудит Low #10: `Get-BRAVOWinSCPBusyMessage` формував текст в обхід
  єдиної точки санітизації.** Її результат іде у `Write-BRAVOLog`
  (Archive) і в `throw` (Health) — тобто в журнал і в сповіщення, — тоді
  як `Get-SanitizedWinSCPDiagnostic` застосовувалась лише до
  stdout/stderr WinSCP.

  Сьогодні витікати нема чому: в `$Availability.Processes` лежать самі
  `ProcessId`. Але `$Availability.Error` — це вільний текст із
  `$_.Exception.Message`, а найприроднішим розширенням діагностики «який
  саме WinSCP зараз працює» є `CommandLine` з `Win32_Process`, у якому
  лежить `sftp://user:password@host`. Тоді повідомлення про зайнятість
  стало б місцем витоку пароля в журнал і Slack/Discord.

  Тепер обидві гілки повідомлення проходять спільну санітизацію.
  Покрито двома самотестами: `Secrets/WinSCPBusyMessageIsSanitized`
  (пароль у `sftp://` і в `-password=` замаскований) і
  `Secrets/WinSCPBusyMessageKeepsDiagnostics` (PID і назва операції
  лишаються читабельними — інакше санітизацію почнуть обходити).

  На цьому закрито всі три Low-зауваження початкового аудиту (#8, #9,
  #10).

- **Аудит Low #9: вікно між створенням тимчасового WinSCP-файла й
  накладанням ACL.** `New-BRAVOWinSCPTemporaryScriptPath` створювала файл
  через `[IO.File]::Open`, а потім захищала його через `Set-Acl` —
  попри коментар, який стверджував, що файл створюється «атомарно».

  У вікні між цими двома діями файл існує з успадкованими від `%TEMP%`
  правами. Для запланованого завдання `%TEMP%` — це `C:\Windows\Temp`,
  куди має доступ значно ширше коло. Порожній файл секрету ще не
  містить, але **Windows перевіряє права в момент відкриття
  дескриптора, а не при кожному читанні**: відкритий у цьому вікні
  дескриптор переживає зміну ACL і прочитає облікові дані SFTP, які
  запише туди викликач.

  Тепер DACL будується ДО створення й передається у конструктор
  `System.IO.FileStream` разом із `FileSecurity` — файл ніколи не існує
  з успадкованими правами, вікна немає взагалі.

  Наявний функціональний тест `Runtime/ProtectedWinSCPTemporaryScript`
  посилено (жодного успадкованого правила, жодного зайвого SID), але
  сам по собі він цю ваду не ловить: **результат в обох схемах
  однаковий**, різниця лише у вікні. Регресійна перевірка це
  підтвердила — під час повернення старої схеми функціональний тест
  лишився зеленим. Тому додано статичний
  `SFTP/TemporaryScriptCreatedWithFinalAcl`, який вимагає `FileSecurity`
  у конструкторі `FileStream` і забороняє виклики `Set-Acl`/`Get-Acl` у
  цій функції. Виклики шукаються в AST, а не пошуком підрядка: текст
  функції містить слово `Set-Acl` у коментарі, що пояснює її
  відсутність.

- **Аудит Low #8: порожні `catch {}` ковтали діагностику.** У комплекті
  було 35 порожніх `catch`, з них 11 — без жодного пояснення. Проблема
  не в тому, що блок порожній (частина з них законна: прибирання у
  `finally`, де початкова помилка важливіша), а в тому, що він **мовчить
  без причини** — саме тоді, коли діагностика потрібна найбільше.

  Три з них були не діагностичною, а **безпековою** проблемою:
  `Remove-BRAVOWinSCPSensitiveTemporaryScript` затирає й видаляє
  тимчасовий WinSCP-скрипт, який містить облікові дані SFTP. Мовчазна
  помилка означала, що файл із секретом лишається в `%TEMP%`, і ніхто
  про це не дізнається. Тепер — `WARNING` з іменем файлу, який треба
  видалити вручну.

  Решта отримала `DEBUG` (завершення процесу після таймауту, DNS-запит
  локальної IP для сповіщення, читання попереднього стану завдань,
  дренаж потоків) або `Write-Warning` (невидалене тимчасове завдання
  Планувальника — наступний запуск діагностики впав би на імені, що вже
  існує). У `BRAVO.Compatibility` логування свідомо не додано: це
  найнижчий шар, він завантажується до `BRAVO.Logging` і навмисно не має
  від нього залежності — тепер це записано в самому `catch`, а не
  мається на увазі.

  Самотест `Diagnostics/NoSilentEmptyCatch` вимагає, щоб кожен порожній
  `catch` у production-комплекті або логував, або **всередині блоку**
  пояснював, чому логування тут недоречне.

- **Захист від відкату на старішу версію (новий код завершення `35`).**
  Четвертий залишковий ризик із THREAT_MODEL §11. Усі наявні перевірки
  звіряють комплект із його **власним** маніфестом — старий, внутрішньо
  узгоджений комплект проходить їх бездоганно, разом із вразливостями,
  які відтоді закрили, і без перевірок, яких у ньому ще не існувало.
  Найпростіший спосіб вимкнути `Enforce` — не ламати його, а розгорнути
  версію, де його ще не було.

  Сервер запам'ятовує найвищу версію, яку на ньому запускали
  (`LOGS\BRAVO_VERSION_STATE.json`: `highestVersion`, `sourceCommit`,
  `recordedAt`), і відмовляється виконувати старішу. Свідомий відкат —
  через `BRAVO_ALLOW_DOWNGRADE=1`.

  Файл стану навмисно НЕ поводиться як маніфест: пошкоджений або
  відсутній — не блокує. Він не є еталоном довіри, і його втрата не
  мусить зупиняти backup; наступний успішний запуск запише його наново.
  Ручний запуск `BRAVO_RUNTIME_GUARD.ps1` перевіряє версію з `-NoWrite`,
  щоб діагностика не змінювала стан, який вона перевіряє.

  Чесна межа задокументована в SECURITY.md і OPERATIONS.md: той, хто має
  права підмінити комплект, зазвичай має права й видалити файл стану.
  Перевірка робить відкат помітним і таким, що потребує ще однієї
  свідомої дії; проти випадкового відкату вона працює повністю.

  Покрито `VersionState/*` (8 тестів, включно з повним циклом запису на
  диск) і `ExitCodes/VersionDowngradePriority`.

- **Захист перемикачів безпеки в `BRAVO.config` (новий код завершення
  `34`).** THREAT_MODEL §11 називав це третім залишковим ризиком; окремо
  виявилось, що коментар у `BRAVO_RUNTIME_GUARD.ps1` уже посилався на
  `Test-BRAVORuntimeSecuritySettings` як на наявну перевірку — функції не
  існувало. Документація обіцяла захист, якого не було.

  `BRAVO.config` навмисно не входить до `RUNTIME_MANIFEST.json`: він
  різний на кожному сервері, спільного еталонного хешу не існує. Через це
  він лишався єдиним файлом комплекту, який можна змінити без сліду — а в
  ньому є перемикачі, що вимикають решту захисту:
  `toolIntegritySettings.Mode = "Warn"` (підмінений `7za.exe` більше не
  блокує) і `backupConsistency.Mode ≠ "VSS"` (архів без VSS-знімка).
  Рядок у текстовому файлі коштує дешевше за підміну бінарника.

  Значення читаються **розбором AST** (`[Parser]::ParseFile`), без
  виконання: завантажити `BRAVO.config` означало б виконати довільний
  PowerShell-код ще до перевірки. Послаблення лишається можливим, але
  вимагає двох дій у двох різних місцях — правки конфігурації й
  `BRAVO_ALLOW_WEAKENED_SECURITY=1`, за зразком уже наявного
  `BRAVO_ALLOW_UNSUPPORTED_OS`. Друга дія лишає слід поза комплектом.

  Обхід через обчислюване значення (`$m = "Warn"; Mode = $m`) статично не
  підтверджується й тому блокує так само — інакше він був би дешевшим за
  пряме послаблення.

  Код `34` у контракті стоїть нижче за `33` (там факт підміни), але вище
  за `32` і `20`: доки перемикачі вимкнені, будь-який успіх нижче
  означає менше, ніж здається. Покрито `ConfigSecurity/*` (8 тестів) і
  `ExitCodes/SecuritySettingsWeakenedPriority`.

  Під час розробки функціональний тест виявив дефект, якого не було б
  видно в рев'ю: `return ,@()` віддає порожній масив як один елемент, і
  зайве `@()` на місці виклику робило з нього масив із порожнім рядком —
  конфігурація, яка взагалі не згадує ці налаштування, помилково
  вважалася послабленою. Обидва місця тепер із поясненням у коді.

- Зовнішнє рев'ю 2026-08-05, P2: [OPERATIONS.md](OPERATIONS.md) —
  операторський runbook. README пояснює, як налаштувати; матриця в
  розділі 12 — де шукати причину. Не було документа, який відповідає на
  питання «зламалось, які дії зараз». Кожен із 12 кодів завершення
  (`20`–`90`) отримав розділ за структурою: симптом, що означає, **чого
  не робити**, команди діагностики, безпечне виправлення, умова
  ескалації. Плюс сценарії поза кодами: розбіжність контекстів
  `SYSTEM`/адміністратора, оновлення `7za`/WinSCP, помилка Discovery,
  ransomware, відновлення на чистий сервер.

  Розділ «чого не робити» — не оформлення, а суть документа. Найдорожча
  помилка в історії репозиторію (порада видалити `TOOLS_INTEGRITY.json`)
  належала саме до цієї категорії, для якої не існувало місця в
  документації. Тому в runbook зафіксовані як заборони: не видаляти
  маніфест і не оновлювати його на сервері (`32`/`33`), не підганяти
  `sftpHostKey` під те, що прийшло по мережі (`50`), не видаляти
  пошкоджений архів — він навмисно лишається для діагностики (`41`), не
  «лікувати» health ручним запуском Archive (`70`), не запускати
  Archive і Maintenance при підозрі на ransomware — вони перезапишуть і
  видалять те, що ще вціліло.

  Покрито самотестами `Documentation/OperationsRunbook*` (наявність,
  повнота за кодами завершення, наявність «чого не робити» щонайменше у
  8 сценаріях, критичні сценарії поза кодами, заборона поради видалити
  маніфест).

- Зовнішнє рев'ю 2026-08-05, P1 «документація не встигає за кодом»:
  - **README описував застарілу модель довіри до `Tools/`.** Розділ 1
    досі подавав trust-on-first-use як основний контроль і радив
    «видаліть `TOOLS_INTEGRITY.json`, щоб прийняти нову базову лінію»,
    хоча код уже блокував запуск за `TOOLS_MANIFEST.json` (код `32`).
    Ризик не теоретичний: адміністратор, який після security-алерту
    сумлінно виконає застарілу інструкцію, власноруч легітимізує
    підмінений бінарник. Розділ переписано під фактичну модель
    (`Enforce`, сторонні DLL, заборона автостворення маніфесту);
    `TOOLS_INTEGRITY.json` лишився описаним, але явно позначений як
    додатковий шар виявлення дрейфу, а не еталон. Охороняється
    самотестами `Documentation/ReadmeDescribesManifestToolTrust` і
    `ReadmeNeverAdvisesDeletingManifest` — другий забороняє будь-яку
    пораду видалити маніфест цілісності.
  - **`SECURITY.md` містив `[заповнити]` замість контакту й SLA.**
    Політика без строків не є політикою. Розділ 2 заповнено конкретним
    каналом (приватний репозиторій — Issue з міткою `security` або
    власник; Security Advisory, якщо репозиторій стане публічним) і
    таблицею строків: підтвердження 2 робочі дні, первинна оцінка 5,
    виправлення критичної вразливості 7–14 календарних днів. Самотест
    `Documentation/SecurityPolicyHasNoPlaceholders` не дає заглушці
    повернутись. Це скасовує свідоме рішення версії 4.2.0 лишити
    заглушки як є.

## 4.3.0 — 2026-08-04

- Аудит P3/P4/P5:
  - **P3.** Усі сторонні GitHub Actions зафіксовані на повний commit SHA
    замість рухомого тега (`@v4` можна переписати, 40-символьний SHA —
    ні). Версія PSScriptAnalyzer закріплена через `-RequiredVersion`,
    інакше нове правило ламає CI без жодної зміни коду. Охороняється
    самотестами `StaticAnalysis/ActionsPinnedToCommitSha` і
    `AnalyzerVersionPinned`.
  - **P4.** `VERSION.json.sourceCommit` — повний 40-символьний git-hash.
    Короткий `buildId` не давав однозначної відповіді, який саме код
    розгорнуто: короткі hash збігаються й погано шукаються в історії.
    `ci\Update-BRAVOVersionStamp.ps1` проставляє обидва поля, зберігаючи
    форматування файлу (`ConvertTo-Json` у PowerShell 5.1 переформатовує
    весь файл і вже ламав самотест).
  - **P5.** [THREAT_MODEL.md](THREAT_MODEL.md) — 9 сценаріїв
    (компрометація адміністратора, підміна Tools і runtime, витік
    credentials, ransomware, VSS, підміна призначення, rollback,
    паралельні запуски), кожен із явним розділом залишкового ризику.
    Найбільший незакритий — ransomware на SFTP-призначення: воно
    доступне на запис тими самими обліковими даними, немає
    immutable-сховища. Самотест вимагає наявності розділу залишкового
    ризику, щоб модель не перетворилась на рекламу.
  - `.gitleaks.toml`: SHA-256 у маніфестах цілісності — не секрети.
    Виняток навмисно вузький (`condition = "AND"`): лише 64-hex, лише в
    двох файлах маніфестів.

- Аудит P2: цілісність усього PowerShell-комплекту, а не лише `Tools/`.
  - `RUNTIME_MANIFEST.json` (version-controlled) — еталонні SHA-256 54
    файлів: `.ps1`, `.psm1`, `.psd1`, `VERSION.json`,
    `TOOLS_MANIFEST.json`.
  - `BRAVO_RUNTIME_GUARD.ps1` — перевірка виконується **до**
    `Import-Module`, тому guard навмисно самодостатній (лише .NET, без
    жодного модуля BRAVO): інакше довелося б завантажити модуль, щоб
    перевірити модулі. Усі три entrypoint dot-source-ять його першим і
    завершуються кодом `33` (`RuntimeIntegrityViolation`).
  - Блокує змінений хеш, відсутній файл і **підкинутий сторонній
    `.ps1`/`.psm1`** — останній може бути dot-source-нутий або
    підхоплений як модуль. Відсутній чи пошкоджений маніфест — теж
    відмова.
  - `ci\Update-BRAVORuntimeManifest.ps1` — оновлення на робочій станції;
    CI-крок «Integrity manifests are current» не дасть змержити
    застарілий маніфест (інакше свіжий комплект заблокував би сам себе).
  - `BRAVO.config` навмисно поза маніфестом (сервер-специфічний), але
    послаблення захисту через нього тепер гучне: усі три runtime пишуть
    `WARNING`, якщо `toolIntegritySettings.Mode` не `Enforce`.
  - Чесні межі задокументовані в `SECURITY.md` 4.1: сам guard і
    entrypoint уже виконуються на момент перевірки — повне закриття
    потребує Authenticode-підпису (P0.3, не реалізовано).

- Рев'ю попереднього кроку виявило дві прогалини в захисті `Tools/` —
  обидві виправлено:
  - **Health більше не запускає інструменти, цілісність яких не
    підтверджена.** Попереднє рішення («Health read-only, тому не
    блокуємо») було обґрунтоване хибно: небезпечний не запис на SFTP, а
    сам запуск `WinSCP.com` / завантаження `WinSCPnet.dll` — підмінений
    бінарник виконує довільний код з правами `SYSTEM` незалежно від
    того, що робить Health. Тепер `Test-SFTPHealthConfiguration`
    пропускає всю SFTP-гілку (єдиний шлях до `Tools/` у Health), а сам
    Health завершується кодом `32`. Локальні перевірки (служби, диски,
    вік копій) інструментів не запускають і виконуються далі.
  - **Сторонній `.exe`/`.dll`/`.com` у `Tools/` тепер блокує запуск** у
    режимі `Enforce`, а не лише повідомляється. Причина — DLL
    side-loading: підміняти `WinSCP.exe` не обов'язково, достатньо
    підкласти DLL з відповідним іменем у той самий каталог, і жоден хеш
    у маніфесті не зміниться. Самотест
    `ToolManifest/UnknownExecutableIsReportedNotBlocking`, який
    закріплював стару поведінку, замінено на
    `ToolManifest/UnknownExecutableBlocksInEnforce` і
    `ToolManifest/UnknownDllBlocksInEnforceWarnsInWarn`.

- Аудит P1 (найнебезпечніший сценарій: підмінений інструмент запускається
  від `NT AUTHORITY\SYSTEM`): цілісність `Tools/` тепер БЛОКУЄ запуск, а
  не лише попереджає.
  - Новий version-controlled `TOOLS_MANIFEST.json` — еталонні SHA-256
    усіх семи виконуваних файлів `Tools/` (не лише `.exe`: підміна
    `7za.dll` не менш небезпечна). Потрапляє на сервер разом з
    комплектом і проходить код-рев'ю як звичайна зміна.
  - `Test-BRAVOToolManifestIntegrity` (`BRAVO.Compatibility`): режим
    `Enforce` (типово) зупиняє Archive і Maintenance з кодом `32`
    (`ToolIntegrityViolation`) і надсилає критичне сповіщення; Health
    як read-only діагностика звітує рівнем `ERROR`, не блокуючи себе.
    Режим `Warn` (`$global:toolIntegritySettings.Mode`) лишає стару
    поведінку для міграції.
  - Маніфест **ніколи** не створюється й не оновлюється автоматично.
    Відсутній, порожній чи пошкоджений маніфест у `Enforce` — теж
    відмова: інакше найпростішим обходом було б просто видалити еталон.
  - Сторонній `.exe`/`.dll`/`.com` у `Tools/` повідомляється окремо, але
    не блокує запуск (може взагалі не використовуватись).
  - `ci\Update-BRAVOToolsManifest.ps1` — оновлення еталона на робочій
    станції; без `-Apply` лише показує розбіжності.
  - Новий код завершення `32` має пріоритет вище за `LockBusy`, щоб
    подія безпеки не губилась у Планувальнику як буденне «зайнято».
  - 11 нових самотестів (`ToolManifest/*`, `Runtime/ToolManifest*`,
    `ExitCodes/ToolIntegrityViolationPriority`), включно з перевіркою,
    що маніфест у репозиторії відповідає реальним `Tools/` — інакше
    свіжий комплект заблокував би сам себе на першому запуску.

- Аудит P1 (PSScriptAnalyzer майже не блокував небезпечні патерни):
  CI блокував лише `Severity=Error`, а `PSAvoidUsingInvokeExpression`,
  `PSAvoidUsingConvertToSecureStringWithPlainText`,
  `PSAvoidUsingUsernameAndPasswordParams` та інші виключались
  **глобально** — тобто новий небезпечний код у будь-якому файлі теж
  мовчки проходив CI.
  - Новий `PSScriptAnalyzerSettings.psd1`: явний блокуючий
    security-набір (`IncludeRules`) + інформаційний прохід для решти.
  - Глобальні `-ExcludeRule` для security-правил прибрані. Натомість
    11 точкових `SuppressMessageAttribute` із `Justification` біля
    конкретних функцій (плюс 3 для хибних спрацювань правила на
    параметрах, чия назва містить «Credential», але які не є секретом).
  - `New-BRAVOPlainTextCredential` (`BRAVO.Credentials`) — блок
    `ConvertTo-SecureString` + `New-Object PSCredential` був
    продубльований у Archive- і Health-runtime; тепер це одна функція з
    одним точковим виключенням замість двох розсіяних.
  - Новий CI-крок «Заборонені патерни»: `Invoke-Expression`/`iex`,
    мережеве завантаження коду (`DownloadString`/`Net.WebClient`),
    секрет у `-ArgumentList`, `ExecutionPolicy Bypass` поза allowlist
    із шести файлів, де він легітимний. Коментарі ігноруються.
  - PSScriptAnalyzer тепер обходить файли поодинці: окремі правила
    здатні кинути `NullReferenceException` на конкретному файлі й
    обірвати весь аналіз, замаскувавши решту знахідок.
  - Побічно виправлено знайдене цим набором: `clear` → `Clear-Host` і
    `$x -ne $null` → `$null -ne $x` (Maintenance), два мертвих
    присвоєння (`$compatibilityIssues` в Archive, `$pendingAge` в
    Health).
  - Самотест: `StaticAnalysis/SecurityRulesAreBlocking`,
    `StaticAnalysis/NoGlobalSecurityRuleExclusions` та ще три —
    охороняють від повернення глобальних виключень.

- Внутрішній код-рев'ю, рефакторинг: `Get-SanitizedWinSCPDiagnostic`
  (маскування паролю/host key у діагностиці WinSCP.com) перенесено зі
  `BRAVO.Archive.Runtime.ps1` у спільний `BRAVO.ArchiveRuntime` — раніше
  функція була продубльована лише в Archive, а `Invoke-WinSCPHealthSession`
  (`BRAVO.Health.Runtime.ps1`) повертав `Output`/`ErrorOutput` без
  санітизації взагалі; тепер обидва runtime використовують одну спільну
  реалізацію, і Health-сесія санітизує результат одразу в джерелі.
- Внутрішній код-рев'ю (не з формального аудиту, точкові виправлення):
  - `Enter-BRAVOWinSCPProcessLock` (`BRAVO.ArchiveRuntime`) тепер приймає
    явний параметр `-LogPath` замість мовчазного покладання на
    `$global:logPath` — якщо модуль колись імпортується до ініціалізації
    конфігу, функція явно повертає помилку замість створення lock-файлу
    у непередбачуваному відносному шляху.
  - `Get-HostInformation` (`BRAVO.Notifications`) логує `WARNING`, якщо
    `$global:hostInformationSettings` взагалі не ініціалізовано — раніше
    public IP lookup тихо трактувався як вимкнений без жодного сліду.
  - `New-BRAVOVSSSnapshotLink` (`BRAVO.Archive.Runtime.ps1`): шляхи для
    `cmd.exe /c mklink` тепер явно квотуються.
  - `BRAVO_ARCHIV.ps1`/`BRAVO_HEALTH.ps1`/`BRAVO_MAINTENANCE.ps1`:
    невдалий `Import-Module` на старті (пошкоджене розгортання) тепер
    завершує процес кодом `90` (`InternalError`) замість довільного
    коду виключення PowerShell — дотримання контракту кодів завершення
    навіть на найранішому етапі entrypoint.

- AUD-001 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P0.1): доданий CI —
  `.github/workflows/ci.yml`, `windows-latest` (проєкт цільово Windows
  PowerShell 5.1, не PowerShell 7 — між ними вже траплялись реальні
  поведінкові розбіжності в цьому репозиторії, тому раннер саме
  Windows, кроки через `shell: powershell`). Запускається на кожен
  push і PR у `master`/`developer`: парсинг усіх `.ps1`/`.psm1`/`.psd1`,
  UTF-8 BOM (обов'язковий для PowerShell-файлів, заборонений для
  `.md`), валідність JSON, `PSScriptAnalyzer` (блокує на
  `Severity=Error`, `Warning`/`Information` — інформаційно, кілька
  правил навмисно виключено як такі, що суперечать усталеній
  архітектурі — `PSAvoidUsingWriteHost`/`PSAvoidGlobalVars`), повний
  `BRAVO_SELF_TEST.ps1`, сканування секретів (`gitleaks`, окрема
  Linux-джоба).

  **Явно НЕ зроблено:** GitHub branch protection (required status
  checks, заборона прямого push у `master`) — CI лише показує статус,
  технічно ще не блокує merge, доки власник репозиторію не ввімкне це
  вручну в налаштуваннях GitHub. `SECURITY.md`/`RELEASE_CHECKLIST.md`
  оновлені, щоб чесно відображати цей проміжний стан.

- AUD-016 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md: усунено структурну
  причину повторюваного бага з `releaseChannel`. Раніше значення
  зберігалося як буквальний рядок, що вручну підтримувався різним на
  `master` (`"stable"`) і `developer` (`"development"`) — кожен merge
  `developer` → `master` вимагав окремого follow-up commit; у цій самій
  сесії fast-forward-мержі двічі мовчки протягували значення не в той
  бік (спочатку `"development"` на `master` після мержу PR, потім
  `"stable"` назад на `developer` після виправлення).

  `VERSION.json.releaseChannel` тепер — нейтральний fallback
  (`"stable"`), **однаковий на обох гілках**. Реальний channel визначає
  новий `Resolve-BRAVOReleaseChannelFromGit` (`BRAVO_CONFIG_LOADER.ps1`)
  напряму з `.git/HEAD` (без виклику `git.exe`): `master`/`main` →
  `stable`, `developer` → `development`, будь-яка інша гілка, detached
  HEAD або відсутній `.git` (розгорнутий production-сервер) — fallback
  на статичне значення з `VERSION.json`. Новий `ReleaseChannelSource`
  (`git-branch`/`VERSION.json`/`legacy`) у метаданих версії показує,
  звідки взято ефективне значення.

  Додано self-test `Version/ReleaseChannelResolvedFromGitBranch`
  (`Resolve-BRAVOReleaseChannelFromGit` із синтетичним `.git/HEAD`),
  `Version/DeveloperBranchResolvesToDevelopmentViaGit`,
  `Version/StaticReleaseChannelIsNeutralFallback`.

  Під час розробки виявлено ще один класичний PowerShell-гачок:
  непереданий параметр типу `[string]` дефолтить у `""`, а не `$null` —
  перевірка `if ($null -eq $GitHeadContent)` для визначення "чи викликач
  передав -GitHeadContent явно" завжди була `$false`, тому функція
  ніколи не читала реальний `.git/HEAD`. Виправлено через
  `$PSBoundParameters.ContainsKey('GitHeadContent')`.

- AUD-008 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P1.6): sanity-check
  обсягу backup. Технічно валідний архів (7za test + SHA512 збігається)
  все одно може бути підозріло малим через неправильне джерело, зламані
  permissions чи неповний VSS exposure. Нові
  `Test-BRAVOBackupSizeAnomaly`/`Get-BRAVOValidArchiveSizeHistory`
  (`modules\BRAVO.ArchiveHelpers`) порівнюють розмір щойно створеного
  архіву з медіаною останніх валідних (hash-підтверджених) архівів того
  самого компонента; новий `backupMonitoring.SizeSanity` у `BRAVO.config`
  (`Enabled`/`HistoryCount`/`MinimumBytes`/`MaxSizeDropPercent`).
  Перший backup компонента (без історії) не вважається аномалією.
  Виявлена аномалія НЕ блокує backup — лише `WARNING` у журналі й статус
  кроку `Архівація <компонент>` підвищується до `WARNING`, що потрапляє в
  лічильник попереджень і Slack/Discord-сповіщення.

- AUD-004 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P0.4): доданий restore
  drill — `BRAVO_RESTORE_TEST.ps1`. Читабельний і навіть SHA-512/7za-
  перевірений архів доводить лише незмінність байтів, не відновлюваність
  системи; новий скрипт бере найновіший локальний backup із коректним
  `.sha512` для кожного увімкненого компонента (`MODEL`/`BLOG`/`BRAVOEXCH`,
  `-Component` для одного або всіх), запускає `7za t` (перевикористано
  `Test-SevenZipArchiveIntegrity`), розпаковує в ІЗОЛЬОВАНИЙ тимчасовий
  каталог (не production-шлях, ACL SYSTEM+Administrators+поточний
  користувач, видаляється одразу після перевірки — навіть при помилці,
  через `finally`), звіряє кількість розпакованих файлів проти
  `-MinimumFileCount` і повертає контрактний exit code (`0`/`10`/`41`)
  та машинно-читаний JSON (`-ResultPath`/`-AsJson`). Сповіщення в
  Slack/Discord — лише при `WARN`/`FAIL`, якщо не задано
  `-SkipNotification`. Read-only діагностика: не видаляє, не переміщує й
  не змінює жоден існуючий backup, елевація не потрібна.

  Новий спільний компонент `Invoke-BRAVOSevenZipExtraction`
  (`modules\BRAVO.Compatibility`) — розпакування архіву, дзеркалить уже
  наявний `Invoke-BRAVOSevenZipIntegrityTest` (той самий
  ProcessStartInfo/stdin-пароль патерн, пароль ніколи не потрапляє до
  командного рядка чи логів).

  Restore drill НЕ входить до типового набору завдань
  `BRAVO_TASKS_INSTALL.ps1` — рекомендовано (розділ 6.1 README.md)
  додати окреме щотижневе/щомісячне завдання Планувальника вручну.

- AUD-007 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md (P1.1/P1.2): захист від
  неоднозначного й дрейфового discovery. `Resolve-BRAVOInstallationDiscovery`
  тепер позначає `Ambiguous.BravoRoot`/`Ambiguous.WebRoot`, якщо знайдено
  кілька служб BRAVO/Apache із РІЗНИМИ виконуваними файлами (ознака
  stale/дублюючої інсталяції) — `Test-BRAVODiscoveryResult` блокує
  валідацію для будь-якого увімкненого компонента, що залежить від
  неоднозначного кореня. Додано `Save-BRAVODiscoveryBaseline` і
  `Compare-BRAVODiscoveryBaseline`: `BRAVO_SETUP.ps1 -ValidateOnly`
  порівнює поточний discovery-результат зі збереженим
  `LOGS\DISCOVERY_BASELINE.json` (поза git) і повідомляє про дрейф
  джерел відносно останнього підтвердженого запуску (лише попередження,
  не блокує); новий switch `-ConfirmDiscoveryBaseline` явно фіксує
  поточний результат як baseline.

  Під час розробки виявлено й виправлено реальний баг у самому модулі
  `BRAVO.Discovery`: ідіома `return ,@($collection.ToArray())`
  (застосована раніше для фіксу розгортання 1-елементного масиву в
  скаляр під Set-StrictMode -Version 2.0 на Windows PowerShell 5.1) при
  ПОРОЖНІЙ колекції створює масив з ОДНИМ елементом-порожнім-масивом, а
  не порожній масив — той самий клас бага, лише в інший бік. Спроба
  виправити через `Write-Output -NoEnumerate` натомість ламала виклики,
  де результат додатково обгортається `@(...)` на боці клієнта
  (подвійне обгортання). Остаточне рішення: звичайний `return
  $collection.ToArray()` у `Test-BRAVODiscoveryResult` і
  `Compare-BRAVODiscoveryBaseline`, а всі точки виклику (в
  `BRAVO_SETUP.ps1` і `BRAVO_SELF_TEST.ps1`) уніфіковано завжди
  обгортають виклик `@(...)` — єдиний послідовний контракт, який
  коректно повертає масив для 0, 1 і N елементів незалежно від стилю
  виклику.

- AUD-017 з ARCHIV_LIMS_MONOLITH_FULL_AUDIT.md: виправлено застарілий
  рядок у `SECURITY.md` (розділ 8), який стверджував, що
  `RELEASE_CHECKLIST.md` "наразі не існує" — файл вже доданий раніше
  (P2.6). Розділ 8 тепер лише чесно перелічує те, що справді ще не
  реалізовано (threat model, CI/CD gate, SFTP/SMB key auth,
  `AppLocker`/`WDAC`/`gMSA`), без згадки вже виконаних пунктів.
  Контакт і SLA в розділі 2 (`[заповнити]`) свідомо лишені як є —
  власник репозиторію ще не надав реальні значення.

- CLAUDE_CODE_TZ_ARCHIV_LIMS_MONOLITH.md: визначення джерел резервного
  копіювання (`MODEL`, `BLOG`, `BRAVOEXCH`, `BAZA_APP`, `BAZA_WWW`,
  `BRAVO_ROOT`, `WEB_ROOT`) тепер відбувається автоматично на основі
  активної інсталяції BRAVO (служба `BRAVO`, служба Apache, файл
  `bravo.ini`), з повним ручним перевизначенням через
  `$global:discoverySettings` у `BRAVO.config`. Новий модуль
  `modules\BRAVO.Discovery\` (`Get-BRAVOServiceExecutablePath`,
  `Find-BRAVOServiceByCandidates`, `ConvertFrom-BRAVOIniFile`,
  `Resolve-BRAVOInstallationDiscovery`, `Test-BRAVODiscoveryResult`)
  реалізує пріоритетний ланцюг: явний override → значення з `bravo.ini`
  → попередня LIMSRoot-відносна поведінка (legacy fallback) — 100%
  зворотної сумісності для інсталяцій без служби BRAVO/Apache або без
  `bravo.ini`. Слабка евристика `Find-BRAVOExchSourceDirectory`
  (фіксований список кандидатів) замінена: значення з `bravo.ini`
  (`BEXCH=`) тепер має найвищий пріоритет, а старі жорстко задані
  кандидати (`exchangAPI`, `bravoexch`, `C:\bravoexch`) лишаються лише як
  запасний варіант. `Archive.Runtime.ps1`/`Health.Runtime.ps1`/
  `Maintenance.Runtime.ps1` не змінювались — вони читають ті самі
  глобальні змінні (`$global:sourcePaths`, `$global:bazaPaths` тощо), які
  тепер заповнюються результатом discovery замість прямих обчислень.

  `BRAVO_SETUP.ps1 -ValidateOnly` виводить новий розділ
  `=== DISCOVERY ДЖЕРЕЛ ===` (знайдені служби, шлях `bravo.ini`, кожне
  джерело з поясненням походження значення) і викликає
  `Test-BRAVODiscoveryResult` для перевірки увімкнених джерел і
  каталогів призначення — без аварійного завершення самого wizard.
  `BRAVO.config` свідомо НЕ виконує жорстку валідацію (throw) при
  звичайному завантаженні: увімкнені за замовчуванням компоненти
  (`MODEL`/`BLOG`/`BRAVOEXCH`) на сервері без реальної інсталяції LIMS
  зламали б кожен виклик `Import-BravoConfiguration`, включно з
  `BRAVO_SELF_TEST.ps1`.

  Додано self-test `Discovery/IniParserHandlesRealBravoIniFormat`,
  `Discovery/ResolvesFromServiceAndIniWithoutOverride`,
  `Discovery/ExplicitOverrideWinsAndIsNeverReplaced`,
  `Discovery/LegacyFallbackWhenNoServiceFound`,
  `Discovery/ValidationDetectsMissingEnabledSourceOnly`,
  `Discovery/WiredIntoConfigLoaderAndSetup`.

  Під час розробки `Test-BRAVODiscoveryResult` спершу повертав масив
  помилок через `return @($errors)`, що на Windows PowerShell 5.1 і
  `Set-StrictMode -Version 2.0` розгортається пайплайном у скаляр при
  рівно одному елементі — виклик `.Count` на такому скалярі (рядку) падав
  з `PropertyNotFoundStrict`, бо `String` не має `.Count` до PowerShell 7.
  Виправлено уніарною комою (`return ,@($errors.ToArray())`), що
  гарантує повернення масиву незалежно від кількості елементів.

## 4.2.13 — 2026-08-04

- P2.7 з плану виправлень: виправлено дрібні зауваження документації.
  README.md більше не має дубльованого рядка-заглушки `BRAVO_*.ps1` у
  дереві каталогів (розділ 2) — дерево тепер перелічує реальні файли
  комплекту, включно з `SECURITY.md`/`RELEASE_CHECKLIST.md`/`VERSION.json`
  і каталогом `modules`. Додано матрицю діагностики за кодом завершення
  (розділ 12): для кожного коду (`20`–`90`) — найімовірніша причина і де
  саме в журналі шукати деталі, доповнює вже наявну таблицю значень
  кодів і `LastTaskResult` Task Scheduler. Пункти аудиту про lifecycle
  `.partial`, manifest архіву й restore drill свідомо НЕ додано до
  README — ці функції ще не реалізовані (P1.4/P1.5/P0.5), документувати
  їх як наявні означало б написати неправду; прогалини вже чесно
  перелічені в `SECURITY.md`/`RELEASE_CHECKLIST.md`. Опис підтримуваних
  версій ОС і чітке розділення development/stable вже було зроблено
  раніше (P0.4/P0.6) — цей пункт лише перевірено, без змін.

  Під час розробки матриці власний новий self-test спершу хибно падав
  через несподіваний артефакт: у PowerShell зворотна лапка `` ` `` є
  символом екранування навіть у звичайному подвійному рядку, тому
  `"| `31` |"` тихо перетворювалось на `"| 31 |"` (без лапок) ще на
  етапі парсингу — Contains-перевірка порівнювала вже спотворений
  рядок і завжди повертала false. Виправлено переходом на одинарні
  лапки для цього шаблону.

- P2.6 з плану виправлень: додано `RELEASE_CHECKLIST.md`. Розділ 1 —
  пункти, які реально виконуються сьогодні й частина яких уже забезпечена
  self-test (`Version/ModuleManifests`, `Version/BuildIdSurfacedInRuntimes`,
  `Version/StableBranchNotDevelopmentChannel`). Розділ 2 — свідомо окремо
  винесені рекомендації аудиту, які в цьому репозиторії ще не
  автоматизовано (PSScriptAnalyzer, secret scanning, підписаний release
  manifest, restore drill тощо) — не позначені чекбоксами обов'язкового
  виконання, щоб чек-лист не створював хибного враження виконаної роботи.
  Додано self-test `Documentation/ReleaseChecklistExists` і
  `Documentation/ReleaseChecklistCoversRequiredSteps`.

- P2.4 з плану виправлень: додано `SECURITY.md` — підтримувані версії
  (продукт і ОС/PowerShell), порядок повідомлення про вразливості, модель
  секретів (Credential Manager, `Protect-BRAVOLogSecret`, очищення
  script-scope змінних), модель довіри до Tools (TOFU, чесно
  задокументовані відсутні Authenticode/Fail-режим/підписані завдання),
  модель ACL, обмеження Credential Manager (прив'язка до облікового
  запису, відсутність gMSA), політика оновлення. Документ описує
  фактичний поточний стан, включно з відомими незакритими прогалинами —
  не видає заплановане за вже реалізоване. Секції SLA/контакту для
  повідомлення про вразливості лишено як явний placeholder для власника
  репозиторію. Додано self-test `Documentation/SecurityMdExists` і
  `Documentation/SecurityMdCoversRequiredSections`.

- P1.6 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`): Health
  тепер окремо повертає `LocalVerified`/`SftpVerified`/`SmbVerified` у
  result object (усі 7 гілок `return Complete-BRAVOHealthResult`), а не
  лише агрегований `Status`/`IssueCount` — зовнішній моніторинг більше не
  втрачає деталізацію "локальні копії в порядку, а SFTP деградував" за
  єдиним `Status = "Critical"`. Кожен напрямок обчислюється незалежним
  викликом (`Get-BackupHealthIssues`/`Get-BAZALocalHealthIssues`/
  `Get-SFTPHealthIssues`/`Get-SMBHealthIssues`) — жоден не перериває
  виконання інших при відмові, тому сам механізм перевірок не
  редагувався, лише додано `Get-BRAVOHealthDestinationSummary`, яка
  зводить уже наявні незалежні списки issues у три прапорці. Додано
  self-test `Health/DestinationSummaryAlgorithm` (функціональний, на
  синтетичних issues) і `Health/DestinationSummaryWiredIntoAllResults`
  (текстовий, підтверджує підключення до всіх 7 місць повернення).

- P1.8 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `BRAVO_OPERATION.lock` (спільний exclusive-lock Archive/Maintenance)
  тепер містить структуровані JSON-метадані замість голого
  `"PID=...; Started=...; Config=..."`: `pid`, `processStartTime`
  (реальний час старту процесу з `Get-Process`, не лише PID — відрізняє
  той самий PID, перевикористаний після перезавантаження сервера, від
  справді активного запуску), `hostname`, `operation`
  (`Archive`/`Maintenance`), `startedAt`, `packageVersion`, `config`.
  Сам механізм lock не змінено — це вже реальний ексклюзивний файловий
  handle (`FileShare.None`), який Windows звільняє автоматично при
  аварійному завершенні процесу, тому окремої перевірки "живий PID перед
  видаленням stale lock" не було потрібно, на відміну від класичних
  PID-файлів. Додано self-test `Scheduler/OperationLockMetadata`.

- P1.9 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  катастрофи ErrorRecord навколо завантаження `BRAVO.config` і читання
  Credential Manager (SFTP/SMB/архів/webhook) в Archive/Health/Maintenance
  друкували `$_.Exception.Message` через `Write-Host`/`Write-Error`
  напряму в консоль, минаючи єдину точку масковки секретів
  (`Write-Log`/`Write-BRAVOLog`/`Write-HealthLog`, яка вже маскує
  `Protect-BRAVOLogSecret`). Тепер ці catch-блоки маскують повідомлення
  винятку одразу при захопленні — так безпечним лишається кожне подальше
  читання відповідних script-scope змінних (`credentialInitializationError`,
  `archiveCredentialInitializationError`, `smbCredentialInitializationError`,
  `notificationCredentialInitializationError`,
  `ArchiveCredentialError`/`NotificationCredentialError` у Maintenance), а
  не лише перший вивід. Додано self-test
  `Runtime/CredentialAndConfigErrorsMaskedAtCapture`.

- P1.10 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `hostInformationSettings.PublicIPLookupEnabled` у `BRAVO.config` тепер
  `$false` за замовчуванням — раніше кожен запуск Health/Maintenance
  звертався до `api.ipify.org`/`checkip.amazonaws.com`, зайвої зовнішньої
  залежності, яка розкриває стороннім сервісам факт і час запуску backup.
  Внутрішній fallback у `Get-HostInformation` (`BRAVO.Notifications`) на
  випадок відсутньої конфігурації узгоджено з тим самим `$false`. Якщо
  вимкнено, `Get-HostInformation` не робить жодного мережевого запиту й
  одразу повертає `PublicIP = "вимкнено"`. Додано self-test
  `Notifications/PublicIPLookupDisabledByDefault`.

- P0.4 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  формалізовано мінімально підтримувану ОС трьома рівнями — Supported
  (Windows Server 2019+, Windows 10/11, PowerShell 5.1), Legacy best-effort
  (Server 2012 R2, Server 2016, без гарантій) і Unsupported (Windows 7,
  Server 2008 R2, PowerShell 3.0). Раніше README декларував єдиний
  розмитий baseline "Windows 7 / Server 2008 R2 або новіша", без жодної
  різниці в поведінці між дуже старою й сучасною системою. Нова
  `Get-BRAVOOSSupportTier` (`BRAVO.Compatibility`) визначає рівень при
  кожному запуску Archive/Health/Maintenance і завжди пише в журнал точну
  версію ОС, build, PowerShell і .NET, незалежно від рівня. `Legacy
  best-effort` лише попереджає; `Unsupported` блокує production-запуск
  (код `30`, `InvalidConfiguration`) — продовжити свідомо можна лише через
  явний override `BRAVO_ALLOW_UNSUPPORTED_OS=1` в середовищі процесу.
  Для Health, яка може викликатися програмно через dot-source
  (`Invoke-BRAVOHealthCheck`), заборона повертається як звичайний
  `Status = "ConfigurationError"`, а не через `exit`, щоб не завершувати
  процес виклика́ча. Додано функціональні self-test на синтетичних
  Win32_OperatingSystem-подібних даних (Get-BRAVOOSSupportTier не можна
  протестувати на реальній іншій ОС) і текстову перевірку підключення
  guard-у в усі три runtime.

- P1.7 з плану виправлень (`ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`):
  `Remove-OldBackupSets` більше не може видалити останню перевірену
  копію компонента. Раніше retention був прив'язаний лише до календарного
  віку (`archiveRetentionDays`) — серія невдалих backup, після якої всі
  ще валідні (SHA512 збігається) комплекти виявились старшими за retention,
  могла видалити їх усі й лишити компонент без жодної придатної копії.
  Новий `BRAVO.config`-параметр `minimumRetainedVerifiedBackups`
  (за замовчуванням `1`) захищає N найновіших перевірених комплектів від
  видалення незалежно від віку; список кандидатів на видалення будується
  через `Select-Object -Skip $minimumRetainedCount` на вже відсортованому
  за спаданням часу списку. Додано текстову перевірку self-test, що
  підтверджує підключення механізму в реальний код, і окрему функціональну
  перевірку алгоритму відбору на синтетичних даних (Archive.Runtime.ps1
  безумовно запускає `Main` при dot-source, тому саму функцію в self-test
  безпечно викликати не можна).

- Упорядковано release channels (P0.6 з плану виправлень
  `ARCHIV_LIMS_MONOLITH_AUDIT_FIXES.md`): `VERSION.json.releaseChannel`
  тепер відповідає гілці — `development` на `developer`, `stable` на
  `master`. Додано self-test `Version/StableBranchNotDevelopmentChannel`,
  який визначає поточну git-гілку і забороняє `releaseChannel=development`
  на `master`/`main`; перевірка м'яко пропускається, якщо `.git`
  недоступний (розгорнутий release-пакет без клону репозиторію). У
  README задокументовано відповідність гілка → канал.

- Повторний аудит (`ARCHIV_LIMS_MONOLITH_REPEAT_AUDIT.md`, P1) вказав: після
  релізного коміту `v.4.2.12` у код внесено суттєві зміни (StrictMode-фікси,
  VSS exposure, ACL runtime, нове логування, маскування секретів, integrity
  preflight, формальна модель exit code, класифікація restore errors,
  виправлення тегів журналу), але `VERSION.json` і всі 13 module manifests
  продовжували показувати `4.2.12` — дві збірки з однаковим номером версії
  могли мати різний код і різну поведінку.
- `VERSION.json` отримав нове обов'язкове для нових релізів (але не для
  вже розгорнутих старих копій) поле `buildId` — короткий git-hash коміту,
  з якого зібрано випуск. `Get-BravoVersionMetadata`
  (`BRAVO_CONFIG_LOADER.ps1`) читає його як необов'язкову властивість,
  щоб оновлення поверх старішого `VERSION.json` без `buildId` не ламалось.
  Значення прокидається як `$global:ScriptBuildId`, той самий шаблон, що
  вже використовувався для `ScriptVersion`/`ScriptDate`.
- Archive, Health і Maintenance тепер показують build ID у консолі/журналі
  та в Slack/Discord-сповіщеннях поруч з версією й датою (`Версiя та дата
  скрипта: 4.2.13 вiд 2026-08-04` + окремий рядок `Збірка (build): ...` в
  Archive; `(build ...)` у сповіщеннях Health і Maintenance).
- `ModuleVersion` усіх 13 module manifests і версія в заголовках `README.md`
  та `BRAVO_SETUP.md` синхронізовано з `VERSION.json` (`4.2.13`).
- Додано self-test `Version/BuildIdSurfacedInRuntimes` (build ID справді
  прокидається у всі три runtime) і розширено `Version/AuthoritativeLoader`
  перевіркою, що `ScriptBuildId` відповідає `buildId` у `VERSION.json`.

## 4.2.12 — 2026-08-03

- Виправлено хибне тегування підсумкового рядка `Результат:` у
  `BRAVO_ARCHIV`: заголовок секції health-check (`=== ПЕРЕВІРКА СТАНУ
  РЕЗЕРВНИХ КОПІЙ ===`) виставляв компонент журналу на `HEALTH` і нічого не
  повертало його назад на `SUMMARY`, тому фінальний рядок з результатом
  усього запуску потрапляв у лог під тегом `[HEALTH]` навіть тоді, коли
  сам health-check пройшов успішно, а `ПОМИЛКА` була викликана чимось
  іншим (наприклад провалом перевірки цілісності одного з архівів). Тепер
  `Set-BRAVOLogComponent -Component 'SUMMARY'` явно виставляється перед
  цим рядком.

- Формальний контракт кодів завершення (`modules/BRAVO.ExitCodes`): замість
  `0`/`1` Archive, Health і Maintenance тепер повертають одне з `0`
  (успішно), `10` (успішно з попередженнями), `20` (пропущено — lock
  зайнятий), `30` (некоректна конфігурація), `31` (немає credentials),
  `40` (помилка локальної архівації), `41` (не підтверджено цілісність),
  `50` (SFTP failed), `51` (SMB failed), `60` (Maintenance failed), `70`
  (Health critical), `90` (внутрішня непередбачена помилка). Дозволяє
  зовнішньому моніторингу (Task Scheduler history, Zabbix) розрізняти
  причину збою, а не лише факт його наявності. При одночасних відмовах
  переможець визначається пріоритетом (lock > config > creds > local
  archive > integrity > SFTP > SMB > maintenance > health > warnings).
  Заразом узгоджено: Archive більше не трактує статуси Health `Disabled`/
  `Deferred` як власну відмову — сам Health вважає їх безпечними. Maintenance
  також розрізняє `40`/`41` для власних операцій відновлення: помилка
  створення/розпакування локального архіву (`Restore-FromArchive`, попередній/
  контрольний архів навколо відновлення) повертає `40`, а провал 7-Zip test /
  SHA512-звірки чи розбіжність розміру файлів — `41`; решта відмов Maintenance
  (сервіси, диск, файлове господарство, оркестрація BRAVO_ARCHIV) лишаються
  спільним `60`, як і раніше.
- Runtime Archive, Health і Maintenance та спільні бібліотеки перенесено до
  versioned PowerShell-модулів у каталозі `modules`; task-entrypoint-и залишено
  тонкими стабільними wrappers.
- `BRAVO.ArchiveHelpers` отримав явний logger callback і більше не залежить від
  приватного `Write-Log` caller-а; додано runtime smoke-test цієї межі модуля.
- Програмний Health API гарантовано очищає SFTP/SMB credential state у `finally`.
- Пошук WinSCP .NET components і перевірку цілісності 7-Zip централізовано у
  спільних модулях без дубльованих реалізацій у domain runtime.
- Процедуру оновлення змінено на атомарну заміну всього комплекту разом із
  каталогом `modules`; опис передачі пароля 7-Zip синхронізовано з реалізацією.
- Виправлено конфігурацію SFTP, яка падала на кожному запуску: `$sftpHost`
  ніде не присвоюється, а централізований завантажувач конфігурації привніс
  `Set-StrictMode`, тому звернення до неоголошеної змінної стало помилкою.
  Archive, Health і dry-run тепер читають legacy-змінні через `Get-Variable`.
- Тим самим способом полагоджено legacy-гілки `$archiveVersions` (строк
  зберігання архівів) і `$networkCopyConfig` (шлях SMB у dry-run): раніше вони
  не могли спрацювати й обривали відповідну перевірку.
- VSS-архівація більше не передає 7-Zip шлях `\\?\GLOBALROOT\Device\...`,
  який .NET не читає: знімок експонується через каталогове символічне
  посилання, що прибирається разом зі знімком.
- Завантажувач конфігурації читає `VERSION.json` і `BRAVO.config` явно як
  UTF-8, попереджає про розбіжність версій між ними і вимагає, щоб файл
  конфігурації лежав усередині каталогу конфігурації.
- Версію в `README.md` і `BRAVO_SETUP.md` синхронізовано з `VERSION.json`.
- Прибрано `REMOVE_OLD_ARCHIV_LIMS.ps1` разом із блоком `Cleanup/*` у
  самотесті, який безумовно читав цей файл і через це падав.
- Виправлено аудит P1 (ненадійний `$LASTEXITCODE`): у `Archive.Runtime.ps1`
  повторний `throw` усередині `catch { $script:processExitCode = 1; throw }`
  ніколи не доходив до власного `Exit` runtime, і код виходу процесу
  визначала загальна поведінка PowerShell на необроблену помилку, а не
  керована логіка BRAVO. Усі три `.psm1`-обгортки (Archive/Maintenance/
  Health) тепер викликають runtime у `try/catch`: на непередбаченому
  винятку повертається керована `1` (пізніше синхронізовано з новим
  контрактом exit code — див. вище), повідомлення виводиться через
  `Write-Error`.
- Маскування секретів (`Protect-BRAVOLogSecret`) поширено з Archive також
  на Health (`Write-HealthLog`) і Maintenance (`Write-Log`): раніше вони
  писали повідомлення без маскування, і виняток WinSCP чи webhook-запиту
  міг потрапити в лог/консоль разом з обліковими даними. Заразом
  виправлено дві прогалини самого `Protect-BRAVOLogSecret`: Slack/Discord
  webhook URL не маскувались зовсім, а коротка форма пароля 7-Zip (`-p`)
  повторно "з'їдала" вже замасковане правило `-password=***`.
- Додано integrity preflight для інструментів у `Tools`
  (`7za.exe`, `WinSCP.com`, `WinSCPnet.dll`): `Get-BRAVOToolIntegrityRecommendation`
  (`BRAVO.Compatibility`) за моделлю trust-on-first-use на першому запуску
  фіксує SHA-256 кожного наявного інструмента в `Tools\TOOLS_INTEGRITY.json`,
  а на кожному наступному звіряє і лише попереджає при розбіжності —
  виконання свідомо не блокується, підміна файлу могла бути легітимним
  оновленням. Підключено в Archive/Health/Maintenance поруч із наявними
  рекомендаціями про PowerShell і Windows.

## 4.2.11 — 2026-08-03

- `BRAVO_SETUP -ValidateOnly` більше не запитує UAC: режим виконує лише
  read-only перевірки.

## 4.2.10 — 2026-08-03

- WinSCP process lock інтегровано у спільний compatibility runtime; прибрано
  дубльовані `Start/Complete-BRAVOProcessOutputCapture` з SFTP runtime.

## 4.2.9 — 2026-08-03

- Standalone `BRAVO_HEALTH` підключає SFTP runtime з перевіркою активного
  WinSCP та process lock, тому SFTP health-check не залежить від архіватора.

## 4.2.8 — 2026-08-03

- Інтервал health-check тепер визначається лише `BRAVO.config` (240 хвилин);
  інсталятор Планувальника більше не змінює його неявно.
- Перевірка активного WinSCP використовує спільний WMI/CIM fallback і працює
  на підтримуваних старих версіях Windows PowerShell.

## 4.2.7 — 2026-08-03

- Health-перевірку винесено з `BRAVO_ARCHIV.ps1` у самостійний
  `BRAVO_HEALTH.ps1`; Планувальник запускає його напряму.
- `BRAVO_ARCHIV` після backup викликає спільний health runtime, а застарілий
  параметр `-HealthCheckOnly` лише сумісно перенаправляє до нового скрипта.
- Health runtime підключає `BRAVO_COMPATIBILITY.ps1` і
  `BRAVO_CREDENTIALS.ps1`, не дублюючи їхню функціональність.
- `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE` також переведено зі вбудованих копій
  compatibility/credentials на спільні файли. Специфічний WinSCP lock
  архіватора винесено до `BRAVO_ARCHIV_RUNTIME.ps1`.

## 4.2.6 — 2026-08-03

- Планувальні завдання `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE`, запущені від
  `SYSTEM`, більше не намагаються відкрити інтерактивний UAC (`RunAs`). Це
  усуває код результату Планувальника `0x80070001` / `2147942401`.
- Додано регресійну перевірку, що обидва сценарії розпізнають SID LocalSystem
  `S-1-5-18` і не запускають UAC у цьому контексті.

## 4.2.5 — 2026-08-03

- Runtime ACL тепер застосовується рекурсивно до наявних файлів і папок перед
  реєстрацією SYSTEM-завдань.
- Усі BRAVO-утиліти використовують спільний loader конфігурації; VETOFFICE
  залишається окремим legacy-шляхом.
- Усунуто колізію імен у credentials-утиліті з функцією loader-а PowerShell.
- Версію та дату релізу централізовано у `VERSION.json`; усунено розбіжність
  документації з фактичною періодичністю health-check.

## 4.2.4 — 2026-08-03

- Виправлено виклики централізованого завантажувача конфігурації в обох
  entrypoint-ах `BRAVO_ARCHIV.ps1`: тепер вони передають обов'язковий
  параметр `-ConfigRoot`.
- `BRAVO_TASKS_INSTALL.ps1` і `BRAVO_SELF_TEST.ps1` переведено на спільний
  `BRAVO_CONFIG_LOADER.ps1`; додано регресійну перевірку контракту loader-а.
- Прибрано хибне попередження про розбіжність версій, коли legacy-версія в
  `BRAVO.config` навмисно відсутня.

## 4.2.1 — 2026-07-30

### Узгодженість резервних копій

- Щоденні архіви `MODEL`, `BLOG` і `BRAVOEXCH` тепер створюються з окремих
  моментальних VSS-знімків локальних томів у контексті `ClientAccessible`.
- `BRAVO_ARCHIV` не зупиняє служби під час backup. Якщо VSS-знімок створити
  неможливо, компонент завершується з помилкою без небезпечного переходу до
  архівації live-каталогу.
- Після штатного завершення або обробленої помилки компонента VSS-знімок
  видаляється у `finally`; окремо обробляються та журналюються коди помилок
  створення й очищення VSS.
- У `BRAVO.config` додано обов'язковий блок `backupConsistency`; self-test
  перевіряє режим `VSS`, контекст і побудову шляху `GLOBALROOT`.

### SFTP-синхронізація BAZA

- Режим `-SyncBAZA` синхронізує всі увімкнені джерела `BAZA_APP` і
  `BAZA_WWW`, окремо перевіряє їхні локальні шляхи та повертає загальний
  результат виконання.
- Webhook Slack/Discord завантажується також у режимі `-SyncBAZA`; виправлено
  ситуацію, коли налаштований webhook ставав порожнім через область видимості
  змінної.
- Несумісні з обмеженням WinSCP імена визначаються до синхронізації за
  фактичною довжиною UTF-8. Сумісні файли передаються, а несумісний залишок
  класифікується як завершений `degraded`-результат без марного повтору всього
  backup.
- Аудит до й після синхронізації розділяє передані, retryable та несумісні
  об'єкти; журнал пояснює, коли повторний запуск не потрібен.
- Сповіщення про несумісні імена містить установу, машину, IP-адреси, версію,
  час, ліміт WinSCP, п'ять читабельних прикладів і шлях до повного журналу.
- Імена в Discord екрануються як literal text і виводяться кожне з нового
  рядка без злиття через Markdown. Довгі повідомлення розбиваються на частини
  до 1900 символів.
- Виправлено граничний підрахунок Windows `CRLF`: двосимвольне перенесення
  рядка більше не створює Discord-повідомлення довжиною 1901 символ.

### Health-звіти

- У локальних і хмарних секціях health-звіту показується ім'я останнього
  архіву разом із віком і розміром.
- Ім'я локального еталонного архіву додається не лише до простроченої
  SFTP-копії, а й до повідомлень про відсутній файл, невідповідний розмір та
  інші помилки віддаленої копії.
- Символи Markdown у назвах файлів екрануються лише для Discord; Slack
  отримує початкове ім'я без зайвих зворотних рисок.

### Захист секретів і тимчасових файлів

- Пароль 7-Zip більше не додається до командного рядка процесу. Створення,
  перевірка та розпакування архівів передають пароль через `stdin` у
  `BRAVO_ARCHIV`, `BRAVO_MAINTENANCE`, `ARCHIV_VETOFFICE` і спільному модулі
  сумісності.
- Заборонено лише паролі з символами нового рядка; подвійні лапки більше не
  потребують вставлення або маскування в process arguments.
- Тимчасові WinSCP-скрипти `BRAVO_ARCHIV` і `ARCHIV_VETOFFICE` створюються
  атомарно з GUID-іменами та захищеним ACL лише для поточного користувача,
  `SYSTEM` і `Administrators`.
- Перед видаленням конфіденційний тимчасовий файл очищується. Шлях
  перевіряється на належність системному temp-каталогу, а застарілі файли
  прибираються під час наступного запуску.
- SYSTEM-worker налаштування Credential Manager працює без `Write-Host`, коли
  немає інтерактивної консолі.

### Maintenance, setup і очищення

- Журнал maintenance має однозначне ім'я
  `BRAVO_MAINTENANCE_yyyyMMdd_HHmm.log`; очищення журналів підтримує новий і
  попередній формати назв.
- Планову реставрацію перенесено із середи `00:20` на неділю `03:00`;
  startup-recovery пропущеного запуску збережено.
- `BRAVO_SETUP.ps1` очікує підтвердження перед закриттям інтерактивного вікна;
  для автоматизованого запуску додано `-NoPause`, який зберігається після UAC
  elevation.
- Додано кероване очищення повних пар обідніх архівів `_1300.mdz` і
  `.sha512` за календарним віком. Очищення вимкнене за замовчуванням,
  перевіряє containment каталогу та не видаляє неповні комплекти.
- Додано окремий `REMOVE_OLD_ARCHIV_LIMS.ps1` із підтримкою `-WhatIf`,
  параметрами шляху, каталогів, строку зберігання й каталогу журналів.
  Часткові помилки, відсутні або небезпечні каталоги повертають exit code `1`;
  успішне виконання повертає `0`.

### Перевірки та документація

- `BRAVO_SELF_TEST` розширено зі статичного аналізу до static + runtime:
  фактично створюється й перевіряється зашифрований 7-Zip-архів із паролем
  через `stdin`.
- Додано runtime-перевірки Discord escaping і chunking, degraded-результату
  BAZA, VSS-шляху, ACL та видалення WinSCP-файлів, а також exit codes
  cleanup-скрипта.
- Статичні перевірки блокують повернення пароля 7-Zip до process arguments,
  live-архівацію без VSS, повторне використання небезпечних temp-файлів та
  втрату імен архівів у health-звіті.
- Dry-run, README і setup-документацію синхронізовано з VSS-вимогами, новими
  параметрами та єдиною версією `4.2.1`; згадку видаленого
  `QuiesceForBackup` прибрано з preflight-звіту.

## 4.2.0 — 2026-07-30

- Єдина версія та дата релізу зберігаються у `BRAVO.config` і додаються до повідомлень архівації, обслуговування та dry-run.
- Health-звіт показує лише увімкнені компоненти резервного копіювання, включно з окремими каталогами `BAZA_APP` і `BAZA_WWW`.
- Коректні комплекти резервних копій очищуються за календарним віком; типовий строк — 183 дні.
- Додано атомарне блокування запусків WinSCP та повідомлення про несумісні імена BAZA.

## 4.9.2 — 2026-07-27

- `BRAVO_ARCHIV` більше не зупиняє і не запускає Windows-служби за жодних
  налаштувань: він лише читає їхній стан, пише його в журнал і надсилає
  попередження, якщо служба не працює.
- Видалено `QuiesceForBackup`, функції керування службами та блок
  stop/start навколо створення архівів. Керування службами залишається лише у
  `BRAVO_MAINTENANCE`.
- Self-test перевіряє відсутність `Stop-Service`, `Start-Service` і колишніх
  функцій керування службами у `BRAVO_ARCHIV`.
- Версія конфігурації: 4.9.2; BRAVO_ARCHIV: 4.0.2;
  BRAVO_MAINTENANCE: 1.7.1.

## 4.9.1 — 2026-07-27

- `BRAVO_ARCHIV` і `BRAVO_MAINTENANCE` до зупинки служб перевіряють їхній
  початковий стан та негайно надсилають одне зведене попередження у Slack/Discord,
  якщо одна або кілька керованих служб не працюють.
- Погодинний `BRAVO_ARCHIV_HEALTH` також контролює встановлені служби з типом
  запуску, відмінним від `Disabled`; активний operation lock запобігає хибним
  тривогам під час штатного backup/maintenance.
- Негайне попередження основних скриптів надсилається також у режимі
  `errors_only`, але саме по собі не змінює їхній exit code: початково зупинені
  служби не запускаються автоматично після backup/maintenance.
- Додано спільний HTTPS webhook-клієнт і статичні self-test перевірки цього сценарію.
- Версія конфігурації: 4.9.1; BRAVO_ARCHIV: 4.0.1;
  BRAVO_MAINTENANCE: 1.7.1.

## 4.9.0 — 2026-07-27

- Marker успішної реставрації MODEL тепер створюється атомарно в UTF-8 без BOM
  замість системного ANSI-кодування Windows PowerShell.
- При code `1+` або таймауті 7-Zip журнал архівації тепер записує останні
  діагностичні рядки stdout/stderr на рівні `ERROR`, незалежно від `LogLevel`;
  пароль архіву маскується.
- Перевірка principal Планувальника тепер порівнює вбудовані service accounts
  за SID, тому локалізовані назви на кшталт `СИСТЕМА` коректно розпізнаються
  як `SYSTEM` (`S-1-5-18`) і не спричиняють помилковий rollback.
- Допоміжні setup, dry-run, credentials, scheduler і self-test скрипти
  отримали окремі transcript-журнали у `LOGS\HELPERS`, фінальний exit code,
  31-денний retention і fallback до `%TEMP%`, якщо runtime недоступний.
- Додано кореневий `README.md` з єдиним маршрутом першої інсталяції,
  оновлення, dry-run, налаштування Credential Manager, Планувальника,
  діагностики запуску від `SYSTEM` і окремими командами VETOFFICE.
- Додано спільний `BRAVO_OPERATION.lock` для взаємного виключення backup і
  maintenance; конфліктуюче завдання очікує lock до шести годин.
- Щоденна архівація зупиняє лише служби, які працювали, створює та перевіряє
  локальні архіви, після чого гарантовано повертає початковий стан служб.
- Для щоденного backup вилучено `-ssw`: відкритий стороннім процесом файл
  спричиняє fail-closed помилку замість потенційно неузгодженого архіву.
- Credential setup отримав режим `Ensure`; повторний setup не перезаписує
  наявні секрети та параметри установи.
- Операції Credential Manager і реєстрація завдань отримали rollback при
  частковій помилці.
- Додано `BRAVO_TASKS_DIAGNOSE.ps1/.cmd`: перевірка реєстрації, action,
  working directory, `LastTaskResult` і dry-run від `NT AUTHORITY\SYSTEM`.
- Setup після встановлення Планувальника перевіряє SFTP, SMB, Credential
  Manager і тестове повідомлення від task account.
- Інсталятор вмикає Task Scheduler Operational log, захищає runtime ACL і
  відмовляється створювати SYSTEM-завдання з профілю користувача.
- Версія конфігурації: 4.9; BRAVO_ARCHIV: 4.0.0;
  BRAVO_MAINTENANCE: 1.7.0.
