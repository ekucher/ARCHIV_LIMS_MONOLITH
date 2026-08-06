# Changelog

## 4.5.0-dev.1 — 2026-08-05

Перший development-реліз циклу `4.5.0`. Відкриває нову модель гілок і
версій, описану в `RELEASE_POLICY.md`.

- **`RELEASE_POLICY.md`.** Що дозволено випускати з кожної гілки:
  `developer` — лише `X.Y.Z-dev.N` / `X.Y.Z-rc.N`, `master` — лише
  `X.Y.Z`; гілки ніколи не несуть однакової версії; stable виникає лише
  promotion перевіреного RC, без нових функцій. Чек-лист відповідає на
  питання «що зробити перед випуском», політика — «що взагалі дозволено
  випускати звідси».

- **`releaseChannel` повернувся у `VERSION.json`.** AUD-016 колись
  вивів його з `.git/HEAD`, бо ручна синхронізація між гілками двічі
  підвела на fast-forward merge. Але розгорнутий на сервері комплект
  приходить ZIP-ом, копіюванням, SFTP або SMB — `.git` там немає взагалі,
  і канал нізвідки взяти. Причину AUD-016 усунуто інакше: гілки більше
  не можуть містити однакову версію, тому fast-forward між ними
  неможливий, а замість людської дисципліни працює механічний gate.

  `Resolve-BRAVOReleaseChannelFromGit` лишилась — уже не як джерело
  значення, а як перехресна перевірка (`ReleaseChannelMatchesGit`).

- **`ci\Test-BRAVOReleasePolicy.ps1` + крок CI.** Stable-версія на
  `developer` або `-dev`/`-rc` на `master` тепер валить CI, а не їде на
  сервер непоміченою. Перевіряє також `ModuleVersion`, наявність версії
  в `CHANGELOG.md` і заголовки `README.md` / `BRAVO_SETUP.md`. У Pull
  Request гілка береться з цільової (`GITHUB_BASE_REF`): promotion
  `developer` → `master` несе вже stable-версію і має перевірятись
  правилами `master`.

- **`ModuleVersion` = базова частина версії.** `ModuleVersion` це
  `[System.Version]` — prerelease-суфікса він не приймає, а
  `New-ModuleManifest` у Windows PowerShell 5.1 не має `-Prerelease`
  (перевірено на цільовій платформі). Тому маніфести модулів несуть
  `4.5.0`, а повна версія пакета (`4.5.0-dev.1`) завжди береться з
  `VERSION.json`.

- Закрито тестами `Version/DeveloperBranchCarriesPrereleaseVersion`,
  `Version/ReleaseChannelStoredInPackage`, `Version/ModuleManifests`,
  `Documentation/ReleasePolicyExists`,
  `Documentation/ReleasePolicyCoversVersionModel`,
  `ReleasePolicy/CiGateEnforcesBranchVersionChannel`.

- **Ручний запуск не через Планувальник тепер чекає на клавішу — в усіх
  трьох runtime, а не лише в Archive.** `BRAVO_ARCHIV.ps1` уже мав робочу
  паузу (`RawUI.ReadKey` з фолбеком на `Read-Host` для ISE);
  `BRAVO_HEALTH.ps1` приймав `-NoPause`, але ніде його не використовував
  — Health ніколи не чекав; `BRAVO_MAINTENANCE.ps1` не мав ні параметра,
  ні паузи взагалі. Обидва тепер працюють так само, як Archive.

  Спільна реалізація — `Wait-BRAVOManualExit` (`BRAVO.Console`) — не
  спрацьовує без явного дозволу: `-NoPause`, вимкнений `PauseOnExit` у
  `BRAVO.config`, `[Environment]::UserInteractive = $false` (сесія 0,
  де й виконуються SYSTEM-завдання) чи перенаправлений stdin — кожна з
  цих причин самостійно скасовує очікування. Для 6 ранніх `exit`
  guard-блоку (до `Import-Module`, коли жоден модуль BRAVO ще не
  довірений) — самодостатній інлайн-варіант без залежності від модулів,
  за тим самим принципом, що й сам guard.

  `Maintenance.Runtime.ps1` має майже 30 точок `exit`, розкиданих по
  всьому файлу. Замість редагування кожної — один зовнішній
  `try/finally`: `exit` усередині `try` гарантовано проходить крізь усі
  `finally` на своєму шляху, перш ніж процес завершиться (властивість
  PowerShell, перевірено емпірично, включно з вкладеними
  `try/catch/finally`), тому один `finally` на весь файл охоплює їх усі.

  Попутно знайдено й закрито реальну прогалину: `BRAVO_TASKS_INSTALL.ps1`
  додавав `-NoPause` вибірково за типом завдання — `Recovery` і
  `Maintenance` (нічний, найризикованіший) його не отримували взагалі.
  Не мало наслідків, доки в цих runtime не було паузи; після цієї зміни
  було б реальним ризиком зависання нічної автоматизації. Тепер
  `-NoPause` додається безумовно для кожного типу.

- Закрито тестами `Console/WaitManualExitChecksNoPauseFirst`,
  `Console/WaitManualExitNoPauseReturnsImmediately`,
  `Console/EarlyGuardExitsPauseBeforeClosing`,
  `Console/HealthPausesOnEveryExitPath`,
  `Console/MaintenancePausesOnEveryExitPath`,
  `Console/MaintenanceAcceptsNoPauseParameter`,
  `Console/EntrypointsForwardNoPauseToRuntime`,
  `Scheduler/EveryTaskTypeGetsNoPauseUnconditionally`.

- **Discovery: уточнене джерело істини для служби BRAVO — за прямою
  вказівкою користувача.** Три виправлення:

  1. **Ідентифікація служби BRAVO** — тепер Service name ТА Display name
     одночасно (`"BRAVO"` і `"BRAVO Service"`), а не будь-яке з них
     окремо. Сторонній сервіс із випадково схожим ім'ям більше не
     проходить як BRAVO.

  2. **`bravo.ini` шукається в системному каталозі Windows**
     (`%SystemRoot%\SysWOW64` на 64-бітній ОС, `\System32` на 32-бітній),
     а не поруч із `bravo.exe`, як вважалось раніше. Причина —
     WOW64 File System Redirector: BRAVO 32-бітний, і коли він пише в
     "System32", 64-бітна Windows прозоро перенаправляє це в SysWOW64;
     64-бітний PowerShell (типово для запланованих завдань), звертаючись
     до "System32" напряму, бачить каталог без редиректу — і файлу там
     просто немає. Підтверджено буквально: на машині розробки він
     справді лежить у `SysWOW64`, і початкова версія тестів це
     випадково довела, підхопивши реальний файл замість фікстури.
     Старий шлях (поруч із `bravo.exe`) лишився вторинним fallback.

  3. **`BACKUP_ROOT`** — каталог збереження бекапів тепер визначається як
     підкаталог `ARCHIV` усередині шляху встановлення служби BRAVO, а не
     LIMSRoot-відносний шлях. `BRAVO.config` використовує це значення як
     дефолт `pathSettings.BackupRoot`, лише якщо адміністратор не змінив
     `BackupRoot` вручну — override ніколи не перезаписується мовчки,
     той самий принцип, що й для решти discovery-полів.

  Закрито тестами `Discovery/BravoServiceRequiresNameAndDisplayNameMatch`,
  `Discovery/SystemDirectoryIsPrimaryBravoIniSource`,
  `Discovery/Win32UsesSystem32NotSysWOW64`,
  `Discovery/FallsBackNextToExecutableWhenSystemIniMissing`,
  `Discovery/BackupRootDerivedFromBravoRoot`,
  `Discovery/BackupRootOverrideWins`,
  `Discovery/ConfigUsesStrictBravoIdentityAndBackupRoot`.

  (Поле переймено на `BACKUP_ROOT` уже в цьому циклі — `ARCHIV_ROOT`
  збігалося з уже наявним `pathSettings.ArchiveRoot`, геть іншим
  поняттям: каталогом самого скрипта, де лежать `Tools\`/`LOGS\`.)

- **`Tools\TOOLS_MANIFEST.json` — маніфест переїхав у той самий
  каталог, що й самі утиліти.** Раніше шукався поруч зі скриптом
  (`$archivPath\TOOLS_MANIFEST.json`), окремо від `Tools\`, де
  фактично лежать `7za.exe`/`WinSCP.*`. Тепер — `Tools\TOOLS_MANIFEST.json`,
  узгоджено з `TOOLS_INTEGRITY.json` (TOFU-базова лінія), який завжди
  був там. Оновлено всюди: `BRAVO.config`, fallback-значення в усіх
  трьох runtime, `ci\Update-BRAVOToolsManifest.ps1`,
  `ci\Update-BRAVORuntimeManifest.ps1` (сам маніфест теж
  version-controlled і входить у `RUNTIME_MANIFEST.json` — довелось
  оновити шлях і там, інакше він випав би з перевірки цілісності
  мовчки), `README.md`, `SECURITY.md`.

  Закрито тестами `ToolManifest/ManifestPathIsInsideToolsDirectory`,
  `ToolManifest/ManifestFileLivesInsideTools`.

- **`pathSettings.ArchiveRoot` дефолтився в обчислений здогад, а не в
  каталог самого скрипта — корінь того, чому маніфест "губився".**
  Раніше: `Join-Path (Split-Path -Parent $ConfigRoot) "ARCHIV"` —
  «піднятись на рівень вище й зайти в підкаталог, що зветься буквально
  ARCHIV». Працювало лише випадково, коли комплект розгорнутий у теці з
  таким іменем. Запущений з git-чекауту (інша назва теки — наприклад,
  `ARCHIV_LIMS_MONOLITH`) — обчислення тихо вказувало на каталог, якого
  не існує, і `Tools\TOOLS_MANIFEST.json` "губився", хоча фізично лежав
  поруч зі скриптом. Тепер — `$ConfigRoot` напряму.

  Той самий недолік був і в `Resolve-BRAVOInstallationDiscovery`:
  legacy-fallback для `BACKUP_ROOT` (коли служби BRAVO не знайдено)
  теж комбінував `LIMSRoot + "ARCHIV"` — друга здогадка поверх першої,
  і гірша за власний дефолт `BRAVO.config`. Тепер у цьому випадку
  `BACKUP_ROOT` лишається порожнім, і перемагає дефолт `ArchiveRoot`.

  Закрито тестами `Discovery/ArchiveRootDefaultsToScriptDirectory`,
  `Discovery/BackupRootStaysEmptyWithoutRealService`.

- **Ручний запуск `BRAVO_ARCHIV.ps1` з відсутніми обов'язковими
  обліковими даними тепер сам пропонує їх налаштувати**, замість того
  щоб просто впасти з помилкою `Не вдалося завантажити пароль архiвiв`
  і змусити шукати окремий скрипт. Якщо запуск інтерактивний (не
  `-NoPause`, реальна консоль — та сама перевірка
  `[Environment]::UserInteractive -and -not [Console]::IsInputRedirected`,
  що вже охороняє паузу перед закриттям) і не вистачає `BRAVO_7Z_PASSWORD`
  та/або `BRAVO_SFTP_LOGIN`/`BRAVO_SFTP_PASSWORD` (останні — лише якщо
  компонент їх справді потребує), автоматично запускається
  `BRAVO_CREDENTIALS_SETUP.ps1 -Action Ensure -Component Required
  -StoreFor CurrentUser` окремим процесом (ізольовано, щоб не
  перезаписати глобальний стан поточного запуску) — і лише для
  поточного користувача; обліковий запис запланованого завдання
  (`-StoreFor ScheduledTaskAccount`) як і раніше налаштовується окремо
  через `BRAVO_SETUP.ps1`/`BRAVO_CREDENTIALS_SETUP.ps1`.

  Закрито тестами `Console/ArchiveOffersCredentialSetupOnlyWhenInteractive`,
  `Console/ArchiveCredentialSetupUsesEnsureAndCurrentUserOnly`,
  `Console/ArchiveCredentialSetupRunsAsIsolatedProcess`.

- **Лог-файл тепер показує обране джерело для MODEL/BLOG/BAZA**, а не
  лише "УВIМКНЕНО"/"ВИМКНЕНО" як раніше. Секція `=== ОПЦIЇ СКРИПТА ===`
  для кожного увімкненого компонента додатково виводить рядок
  `Джерело <TYPE>: <шлях> (<причина>)`, де причина береться з
  `bravoDiscoveryResult.Reasons` (наприклад, `bravo.ini [model]
  MODEL=D:\LIMS-NEW\Model\lims` або `legacy fallback: ...`) — той самий
  формат, що вже показує `BRAVO_SETUP.ps1 -ValidateOnly`. Якщо джерело
  не вдалось визначити — `ERROR`-рядок з тією ж причиною замість
  мовчазного `null`. BRAVOEXCH і BAZA WWW це вже мали (окремі блоки),
  тепер симетрично й для MODEL/BLOG/BAZA.

  Закрито тестами `Console/ArchiveLogsModelSource`,
  `Console/ArchiveLogsBlogSource`, `Console/ArchiveLogsBazaLocalSource`.

- **Health падав із "The property 'ActionCounts' cannot be found on
  this object" щоразу, коли синхронізація BAZA на SFTP увімкнена, а
  локальний каталог BAZA відсутній.** Той самий клас бага, що вже
  ловив AUD (`Get-AlertFingerprint` і `DifferenceCount` для `Kind =
  "Service"`), але в іншому полі й інших місцях: лише ОДИН з чотирьох
  способів побудови проблеми `"SFTPSynchronization"`
  (`Get-SFTPHealthIssues`, гілка "у хмарі відсутні...") насправді
  встановлює `ActionCounts`. Три інших ("не вдалося визначити локальне
  джерело", "локальний каталог не знайдено", "не вдалося порівняти
  каталоги") — ні, а консольний журнал і `Format-CompactSFTPIssue`
  зверталися до `$healthIssue.ActionCounts`/`$Issue.ActionCounts`
  напряму навіть усередині `if ($null -ne ...)` — під `Set-StrictMode`
  це падає ще до самого порівняння. Archive (де Health викликається
  in-process) ловив це як повну відмову health-check замість звичайної
  проблеми в звіті — оператор не отримував жодної тривоги.

  Новий `Get-BRAVOHealthIssueActionCounts` (той самий підхід, що вже
  має `Get-BRAVOHealthIssueField`: `PSObject.Properties['ActionCounts']`
  замість прямої крапки) замінив усі небезпечні звернення в обох
  місцях. Перевірено живим прогоном `BRAVO_HEALTH.ps1` за тих самих
  умов, що й реальний збій: третя проблема тепер коректно потрапляє у
  звіт (`SFTP BAZA: локальний каталог BAZA не знайдено; ...; типи
  розбіжностей: немає даних`) замість краху всього health-check.

  Закрито тестом `Health/SFTPSynchronizationToleratesMissingActionCounts`.

- **`BAZA_APP` шукався поруч із `LIMSRoot`, а не поруч із реальним
  `MODEL`/`BLOG` з `bravo.ini`.** `BAZA` не має власного ключа в
  `bravo.ini`, тому `BAZA_APP` завжди виводився як `<BRAVO_ROOT>\BAZA`
  — а `BRAVO_ROOT`, коли Windows-службу BRAVO не знайдено (типова
  dev/test-машина без встановленої служби, лише з конфігом), деградує
  до `LIMSRoot`-фолбеку. Реальний випадок: `bravo.ini` знайдено
  (системний каталог Windows не залежить від служби), `MODEL`/`BLOG` з
  нього коректно вказували на `D:\LIMS-NEW\...`, а `BAZA_APP` усе одно
  шукався в `C:\Users\...\Documents\BAZA` — зовсім іншому місці.

  Тепер, коли `MODEL` або `BLOG` вже взято з `bravo.ini`, `BAZA_APP`
  виводиться як сусідній каталог у тому самому корені інсталяції
  (`Split-Path -Parent` від `MODEL_SOURCE`/`BLOG_SOURCE`) — і лише
  якщо жоден з них з `bravo.ini` не прийшов, лишається старий
  `<BRAVO_ROOT>\BAZA` fallback.

  Закрито тестом
  `Discovery/BazaAppFollowsIniInstallationRootNotBravoRootFallback`.

- **SFTP: скрипт тепер сам створює відсутні кореневі каталоги**
  (`model`/`blog`/`bravoexch`/`baza_app`/...) замість того, щоб просто
  падати. Реальний випадок: WinSCP явно повідомляв `Error listing
  directory '/baza_app'. No such file or directory` — жоден із
  каталогів на сервері ще не існував, і кожна передача (як окремих
  файлів, так і синхронізація BAZA) провалювалася кодом 1.

  Новий `Initialize-BRAVOSFTPRemoteDirectories` викликається одним
  пакетним WinSCP-скриптом одразу після підтвердженого з'єднання, перед
  Send-FileViaWinSCP/Sync-FolderToSFTP — і в автоматичному потоці, і в
  ручній `-SyncBAZA`. `option batch continue` навмисно: `mkdir` на вже
  наявному каталозі повертає помилку (а після першого успішного запуску
  каталоги вже існують щоразу), тому виклик — best-effort і ніколи не є
  джерелом істини про успіх; реальний результат перевіряють окремі
  виклики передачі, які на це не зважають.

  Це оголило два раніше недосяжні StrictMode-баги в самій `Sync-FolderToSFTP`
  (аудит BAZA до цього завжди падав на "каталог не знайдено" ще до того,
  як доходило до цього коду):
  - `Get-BAZASFTPComparison` читав ім'я локального елемента порівняння
    через `.FullName` — а `$difference.Local` з WinSCP `CompareDirectories`
    це `WinSCP.RemoteFileInfo` (навіть для локальної сторони), а не
    `System.IO.FileInfo`: такої властивості там немає взагалі, лише
    `.FileName` (той самий API, що вже коректно працює через
    `$side.FileName` у `BRAVO.Health.Runtime.ps1`).
  - `Write-BAZASFTPComparisonAudit`/`Write-BAZARemoteNameCompatibilityAudit`
    викликали `Write-BRAVOLog -FileOnly` — цей перемикач існує лише на
    локальному шимі `Write-Log` (транслює його в `-NoConsole`), а сам
    `Write-BRAVOLog` такого параметра не має і падає з
    `InputValidationError`.

  Перевірено живим прогоном на реальному SFTP (Hetzner Storage Box):
  до фіксів — 0 з 6 файлів; після mkdir-фіксу — 6 з 6 файлів, але аудит
  BAZA падав на `.FullName`; після `.FileName`-фіксу — падав на
  `-FileOnly` при спробі залогувати 374 елементи аудиту; після всіх
  трьох фіксів разом — `374 з 374` файлів BAZA синхронізовано,
  `Каталог BAZA повнiстю синхронiзовано з /baza_app`.

  Закрито тестами `Console/ArchiveEnsuresSFTPDirectoriesBeforeTransfer`,
  `Console/BazaComparisonReadsFileNameSafely`,
  `Console/BazaAuditUsesNoConsoleNotFileOnly`.

- **Власний прогрес-бокс `Test-NetConnection` ("Attempting TCP connect",
  "Waiting for response") усе одно з'являвся в консолі поверх кроків
  BRAVO**, хоча мав бути прихованим. `Test-BRAVOTcpConnection` уже
  придушував його через `$ProgressPreference = 'SilentlyContinue'`, але
  локальне присвоєння (без `$global:`) ненадійне для цього конкретного
  командлета — відомий нюанс Windows PowerShell 5.1, коли сам
  `Test-NetConnection` не завжди резолвить preference-змінну лише з
  локального scope виклику.

  Тепер тимчасово підміняється ГЛОБАЛЬНЕ `$ProgressPreference`
  (з гарантованим відновленням попереднього значення в `finally`) —
  саме так, як і задумувалося коментарем, що вже існував у коді.

  Закрито тестом `Compatibility/TcpConnectionSuppressesGlobalProgress`.

- **`BRAVO_ARCHIV.ps1` друкував ПОВНИЙ заголовок Health усередині
  власного кроку "Перевірка резервних копій"** — "BRAVO HEALTH X.X.X /
  Установа / Початок" виглядало як друга незалежна програма всередині
  виводу Archive, з власною версією й міткою часу, хоча це один
  прогін. Реальний випадок (скріншот користувача): "дублювання
  зявляється при запуску BRAVO_ARCHIV.ps1 + BRAVO_HEALTH.ps1 — у
  кожного свої заголовки та етапи".

  `Invoke-BRAVOHealth` отримав новий `-SuppressHeader`, який передається
  лише зі шляху `Invoke-BRAVOHealthCheck` (`BRAVO.Health.psm1`) —
  вбудований виклик з Archive. Самостійний запуск `BRAVO_HEALTH.ps1`
  проходить іншим шляхом (без цього параметра), тому там заголовок
  лишається без змін. `Write-BRAVOHeader` (BRAVO.Console) отримав
  `-SuppressText`: приховує сам текст заголовка, але зберігає
  резервування порожніх рядків під прогрес-бар — без цього перші рядки
  вбудованого Health-звіту ризикували опинитися під смугою.

  Закрито тестом `Console/EmbeddedHealthSuppressesDuplicateHeader`.

- **Уніфіковано вбудований звіт Health усередині `BRAVO_ARCHIV.ps1`** —
  прибирання заголовка (див. вище) закрило лише частину проблеми
  (реальний скріншот користувача, зроблений після цього): вбудований
  виклик усе одно друкував ВЛАСНУ покрокову нумерацію `[N/5]` поряд із
  нумерацією Archive `[N/7]`, ВЛАСНИЙ підсумок (`Результат`/
  `Тривалість`/.../`Детальний журнал`) поряд із підсумком Archive —
  фактично два незалежні звіти замість одного. Плюс `SFTP MODEL:
  серверний SHA архіву недоступний; використано повний збіг
  віддаленого hash-файлу` показувалось як WARNING, хоча перевірка все
  одно успішна (просто іншим методом).

  `Write-BRAVOHealthStep` тепер пропускає власний друк `[N/5]` при
  `-SuppressHeader`, не збиваючи внутрішній лічильник кроків (від нього
  залежить нумерація кроку "Сповіщення"). `Complete-BRAVOHealthResult`
  придушує власний `Write-BRAVOSummary` — `Complete-BRAVOProgress`
  (очищення прогрес-бару) лишається безумовним. Фолбек на `.sha512`
  тепер логується як INFO, а не WARNING: перевірка успішна, це нотатка
  про метод, а не привід для уваги оператора. Разом з попереднім
  прибиранням заголовка вбудований виклик тепер показує лише те, що
  справді потрібно: значущі "Проблема ..." деталі (якщо є) і ОДИН
  підсумок Archive з ОДНИМ посиланням на лог-файл.

  Закрито тестами `Health/EmbeddedCallSuppressesStepNumbering`,
  `Health/EmbeddedCallSuppressesOwnSummary`,
  `Health/ServerSideHashFallbackIsInfoNotWarning`.

- **Зайвий порожній розрив між `[6/7]` і `[7/7]` усередині
  `BRAVO_ARCHIV.ps1`** — після прибирання заголовка й підсумку Health
  (див. вище) лишався фіксований блок із 6 порожніх рядків
  (`BRAVOConsoleProgressReservedLines`), який раніше захищав текст
  заголовка Health від накладання прогрес-бару. Без самого тексту
  захищати вже нічого, а блок лишався видимим розривом навіть тоді,
  коли Health не знаходила жодної проблеми для показу (реальний
  скріншот користувача). `Write-BRAVOHeader -SuppressText` тепер
  пропускає ввесь вивід одразу — і текст, і резервування рядків.

- **`BAZA_WWW` (бекап `{DocumentRoot}\BAZA` встановленого Apache) тепер
  визначається автоматично, а не задається вручну.** `Resolve-BRAVOInstallationDiscovery`
  шукає службу Apache2.4/Br-a-vo.web (той самий канал кандидатів, що й
  раніше), знаходить її `httpd.exe`, читає `<ServerRoot>\conf\httpd.conf`
  новим парсером `Get-BRAVOApacheDocumentRoot` і бере `DocumentRoot`
  звідти — а не вгадує його з розташування `apache\`. Синхронізація
  вмикається лише тоді, коли служба справді встановлена і `DocumentRoot`
  вдалось прочитати; каталог на SFTP лишається `baza_www`, без змін.
  `BRAVO.config` більше не містить окремої логіки пошуку (видалено
  ~130-рядковий `Find-BRAVOWebBAZASource` з обходом предків і евристикою
  "перша непорожня папка") — тепер це тонкий адаптер над результатом
  Discovery.

  Попутно знайдено й виправлено реальний баг, який виявився лише на
  живій машині з дійсно встановленою службою Apache: `BRAVO.Discovery`
  викликає `Get-BRAVOWmiInstance` (з `BRAVO.Compatibility`), не
  імпортувавши цей модуль сам — і те, що виклик модуля-споживача
  (наприклад, `BRAVO.Health.Runtime.ps1`) імпортує `BRAVO.Compatibility`
  РАНІШЕ, не робить її функції видимими всередині чужого модуля: кожен
  PowerShell-модуль має власний session state. Через це `WEB_ROOT` і
  `BAZA_WWW` мовчки лишались порожніми на машині з реально запущеною
  службою `Br-a-vo.web`, хоча той самий пошук служби прекрасно
  спрацьовував поза модулем. Виправлено додаванням явного
  `Import-Module BRAVO.Compatibility` на початку `BRAVO.Discovery.psm1`
  — той самий патерн, що вже застосовано в `BRAVO.Notifications`,
  `BRAVO.ArchiveRuntime`, `BRAVO.ArchiveHelpers`.

  Закрито тестами `Discovery/ApacheDocumentRootParserReadsQuotedForwardSlashPath`,
  `Discovery/ApacheDocumentRootParserIgnoresCommentedDirective`,
  `Discovery/BazaWwwUsesHttpdConfDocumentRoot`. Підтверджено живим
  прогоном `BRAVO_HEALTH.ps1` на машині з реальною службою
  `Br-a-vo.web`: `WEB_ROOT`, `HttpdConfPath`, `BAZA_WWW` заповнюються
  коректно зі справжнього `httpd.conf`.

- **Визначення BAZA обмежено рівно чотирма незалежними значеннями:
  `BAZA_APP_SFTP`, `BAZA_WWW_SFTP`, `BAZA_APP_LOCAL`, `BAZA_WWW_LOCAL`.**
  Раніше `componentSettings.Synchronization` називав ці прапорці
  `BAZALocal`/`BAZASFTP`/`BAZAWWWSFTP` — бареве `BAZA` без суфікса
  означало "APP", що легко сплутати з `BAZA WWW` при читанні коду чи
  конфігурації. Перейменовано наскрізно (`BRAVO.config`, `BRAVO.Archive`,
  `BRAVO.Health`, `BRAVO_DRY_RUN.ps1`, `BRAVO_SETUP.ps1`,
  `BRAVO_CREDENTIALS_SETUP.ps1`, `BRAVO_TASKS_INSTALL.ps1`) разом із
  похідними змінними (`bazaAppLocalSyncEnabled` тощо) і текстом логів
  ("Синхронiзацiя BAZA APP на SFTP" замість голого "BAZA"). Discovery-поля
  (`BAZA_APP`/`BAZA_WWW` — шляхи-джерела, не прапорці) і каталоги на SFTP
  (`baza_app`/`baza_www`) не чіпались — вони й так уже однозначні.

  **`BAZA_WWW_LOCAL` — нова функція**, а не просто перейменування: локальна
  копія `BAZA_WWW` (`{DocumentRoot}\BAZA` встановленого Apache/Br-a-vo.web)
  у каталог `BackupRoot\BAZA_WWW`, точно за тим самим принципом, що вже
  давно робить `BAZA_APP_LOCAL` (`Sync-Folders` через robocopy). За
  замовчуванням вимкнено (`$false`), як і `BAZA_APP_LOCAL`. Health отримав
  той самий read-only `robocopy /L` контроль актуальності, що вже був для
  `BAZA_APP_LOCAL` (спільна `Get-BAZALocalSyncHealthIssues`, раніше
  `Get-BAZALocalHealthIssues`, з новим параметром `-Label`).

  Закрито тестами `Discovery/ConfigDefinesExactlyFourBazaSyncFlags`,
  `Discovery/ArchiveReadsExactlyFourBazaSyncFlags`,
  `Console/ArchiveSyncsBazaWwwLocally`, `Health/BazaWwwLocalHealthCheckWired`.

- **`BRAVO_MAINTENANCE.ps1` відмовлявся запускатись, якщо каталог скрипта
  назвався не буквально `ARCHIV`.** Той самий крихкий здогад, що вже
  прибрано з `ArchiveRoot` (`pathSettings`, дивись запис нижче в цьому ж
  циклі) — і так само працював лише випадково, коли комплект розгорнутий
  саме в теці з таким іменем. Будь-яке інше розташування (наприклад,
  git-чекаут з іменем репозиторію) блокувало Maintenance повідомленням
  "Скрипт має запускатись лише з папки ARCHIV!" (код `90`) без жодної
  реальної причини — `ArchiveRoot`/`LIMSRoot` і так явно задаються
  окремо в `pathSettings`. Перевірку прибрано; жодне інше місце в
  комплекті на неї не покладалось.

- **`BRAVO_MAINTENANCE.ps1` мовчки пропускав до 3 із 7 етапів, коли
  `LIMSRoot` не вказує на реальний корінь LIMS-інсталяції.** `Check-MdFileSizes`
  сканував `$MODEL_PATH = "$ROOT_LIMS\Model"` — той самий крихкий
  LIMSRoot-відносний здогад, що вже прибрано з `MODEL_SOURCE` в Archive.
  Коли реальний каталог MODEL не збігався з цим здогадом (`LIMSRoot`
  вказував не на корінь інсталяції), `EnumerateFiles` кидав
  `DirectoryNotFoundException`, який ніхто не ловив аж до
  `Invoke-BRAVOMaintenanceEntrypoint`: `finally`-блоки встигали відновити
  служби й показати "Натисніть будь-яку клавішу", але етапи "Реставрація
  моделі"/"Обробка trace і логів"/"Очистка" пропускались мовчки, без
  видимої помилки в консолі (лише after-the-fact `Write-Error`, після
  натискання клавіші).

  Той самий здогад використовувала й **реставрація моделі через
  `bravocmd.exe`** (`$ROOT_LIMS\MODEL\lims`) та шлях до самого
  `bravocmd.exe` (`$ROOT_LIMS\bravocmd.exe`) — деструктивна операція, яка
  на нетиповій структурі диска так само вказувала б у порожнечу.

  Усі три джерела істини — `bravoDiscoveryResult.MODEL_SOURCE`,
  `.MODEL_PROJECT_FILE` (точне значення `MODEL=` з `bravo.ini`, те, що
  приймає `bravocmd.exe`) і `.BRAVO_ROOT` (каталог `bravo.exe`, де
  логічно лежить і `bravocmd.exe`) — з тим самим фолбеком на старий
  LIMSRoot-відносний шлях, коли Discovery нічого не знайшов (bravo.ini чи
  служба відсутні), тому поведінка на типовому розгортанні не змінюється.

  Перевірка: живий прогін на машині, де раніше падало на кроці
  "Перевірка розмірів .md" — тепер усі 7 етапів показуються й
  завершуються, результат УСПІШНО.

- **Заголовок `BRAVO_MAINTENANCE.ps1` дублював код установи:**
  "Установа: Тестова установа [0000000] [0000000]". `Write-BRAVOHeader`
  сам додає `[InstitutionCode]` до `-Institution`, а Maintenance передавав
  туди вже складений `$script:ObjectName` (`"$InstitutionName [$InstitutionCode]"`,
  той самий рядок, що йде в Slack/лог-підсумок) — замість самої лише
  назви, як роблять Archive і Health. Виправлено на `bravoSettings.InstitutionName`,
  узгоджено з обома іншими runtime. Підтверджено живим прогоном.

- **Консольний підсумок `BRAVO_MAINTENANCE.ps1` теж повторював установу**
  окремим рядком "Установа: ..." після "Попереджень: 0" — зайве, коли та
  сама інформація вже показана в заголовку рядком вище. Ні Archive, ні
  Health установу в підсумку не дублюють. Прибрано.

## 4.4.2 — 2026-08-05

Виправлення за результатами першого тестового розгортання на реальному
сервері. Обидва дефекти — не в тому, що BRAVO робить, а в тому, що він
**показує**: перевірка готовності звітувала «все гаразд» там, де запуск
би не відбувся, а діагностика виводила результат нечитабельним.

- **`BRAVO_DRY_RUN.ps1` не перевіряв цілісність комплекту.** Він звітував
  «помилок — 0» на комплекті, у `Tools\` якого лежали залишки старого
  розкладання; кожен запуск за розкладом на тому ж комплекті завершився б
  кодом `33`, бо entrypoint кличе guard, а dry-run — ні.

  Перевірка готовності, яка не перевіряє того, що перевіряє сам запуск,
  дає хибну впевненість — а це найгірше, що вона може зробити. Тепер
  dry-run виконує ті самі три перевірки (`33`, `34`, `35`), причому
  `Test-BRAVOVersionDowngrade` — з `-NoWrite`: dry-run не має права
  фіксувати розгортання, якого ще не було.

  Закрито тестами `DryRun/VerifiesRuntimeIntegrity` і
  `DryRun/DoesNotRecordVersionState`.

- **`OPERATIONS.md`:** два розділи за реальними симптомами цього
  розгортання — «сторонні скрипти в комплекті» (код `33`, найчастіша
  причина на свіжому сервері, з прямою забороною «узаконювати» знахідку
  оновленням маніфесту на сервері) і «Цей хост невідомий» для SFTP (це
  DNS та ім'я, що будується з логіна й шаблону, а не автентифікація).

- **Результат SYSTEM dry-run у `BRAVO_TASKS_DIAGNOSE.ps1` друкувався одним
  нечитабельним рядком.** `ConvertFrom-Json` у Windows PowerShell 5.1
  віддає JSON-масив **одним об'єктом**, не розгортаючи його в конвеєр, тому
  `@(... | ConvertFrom-Json)` давало масив із єдиного елемента-масиву: цикл
  виконувався один раз, `$result.Status` ставав `System.Object[]`, і весь
  звіт злипався у `[PASS PASS FAIL ...] Конфігурація Скрипти ...: шлях шлях`.

  Саме цей вивід читають, коли треба зрозуміти, чому завдання від `SYSTEM`
  не працює. Виявлено на тестовому сервері.

  Закрито двома тестами: функціональним (обидві форми, з перевіркою що
  хибна справді згортає) і AST-сканером усіх скриптів комплекту. Сканер
  саме по AST, а не підрядком, щоб не ловити власні пояснювальні коментарі.

## 4.4.1 — 2026-08-05

Патч безпеки, знайдений першим же тестовим розгортанням 4.4.0. Ставте
на сервер саме цю версію, а не 4.4.0.

- **Незавантажуваний `BRAVO_RUNTIME_GUARD.ps1` більше не вимикає весь шар
  цілісності.** `Test-Path` підтверджував лише наявність файлу. Якщо
  dot-source не виконувався — `ExecutionPolicy AllSigned` без підпису,
  синтаксична помилка, блокування файлу — entrypoint мовчки йшов далі:
  усі три перевірки (`33`, `34`, `35`) падали з `CommandNotFound`, не
  зупиняючи запуск, і справа доходила до `Import-Module`.

  Тобто найдешевшим способом обійти перевірку цілісності було не
  підбирати SHA-256, а зробити guard непрацездатним. Тепер dot-source
  обгорнуто в `try/catch`, а наявність усіх трьох функцій підтверджується
  через `Get-Command`; будь-який збій — код `33` до завантаження модулів.
  Виявлено під час тестового розгортання 4.4.0 на сервері з `AllSigned`.

  Закрито двома тестами: статичним (`try/catch` + `Get-Command` у всіх
  трьох entrypoint) і функціональним — справжній entrypoint поруч із
  guard-ом, що не парситься, мусить завершитись кодом `33`. До
  виправлення той самий сценарій давав `90`, тобто прохід повз перевірки.

- **`OPERATIONS.md`:** окремий розділ для `33` під `ExecutionPolicy
  AllSigned`. Це не атака, а політика виконання: заплановані завдання
  працюють (`-ExecutionPolicy Bypass`), ручний запуск із консолі — ні.
  Прямо сказано, чого робити не можна: знижувати політику машини заради
  зручності.

## 4.4.0 — 2026-08-05

Реліз для тестового розгортання. Основне — єдиний стиль операційної
консолі для всіх трьох runtime; дорогою закрито зовнішнє рев'ю, кілька
пунктів аудиту й два дефекти, через які моніторинг мовчав.

**Перед першим запуском на сервері:** `BRAVO_MAINTENANCE.ps1` цієї версії
жодного разу не виконувався наскрізь — його логування, шкала рівнів і
структура виводу змінені й перевірені статично, самотестом і на стенді,
але не живим прогоном. Перший запуск має бути ручним і під наглядом, не
за розкладом: Maintenance зупиняє служби LIMS, реставрує модель і
видаляє дані.

- **Єдиний стиль відображення для всіх трьох runtime.** `BRAVO.Console`
  існував і робив саме те, що треба — заголовок, нумеровані етапи
  `[1/7] Назва.....OK`, сталі кольори статусів, одна смуга прогресу,
  підсумок, — але користувався ним лише Archive. Health вивалював в
  консоль кожен запис журналу суцільним потоком `[LEVEL] текст` без
  жодного кольору; Maintenance малював `=== ЗАГОЛОВОК ===` і власну
  палітру. Оператор бачив три різні програми.

  Health і Maintenance переведено на `BRAVO.Console`: заголовок, етапи,
  підсумок із метриками. Вимкнений у конфігурації компонент не показуємо
  й не рахуємо — знаменник обчислюється за увімкненими, як це від
  початку робив Archive. Вимкнені BAZA, NAS/SMB і сповіщення дають
  `[1/4]…[4/4]`, а не `[1/7]…[7/7]` із трьома порожніми рядками.
  Реставрація моделі показується лише тоді, коли справді виконуватиметься
  цього запуску; якщо вона була запланована, але службу BRAVO не вдалося
  зупинити, рядок лишається — це не «не настав час», а заплановане й
  невиконане. У Health підсумок друкується з
  `Complete-BRAVOHealthResult`, через яку проходить кожен зі шляхів
  виходу, тому нова гілка не може лишитися без підсумку.

  Консольна половина журналу теж тепер іде через `BRAVO.Console`
  (`Set-BRAVOLogConsoleWriter`): `WARNING` із бізнес-логіки дописувався
  у хвіст відкритого рядка етапу й ламав розмітку рівно тоді, коли
  щось пішло не так. Це callback, а не залежність: журналювання —
  нижчий шар і має працювати там, де консолі немає взагалі.

  З підсумку Health прибрано метрики вимкнених призначень: рядок
  `NAS/SMB: True` читався як «перевірено й усе гаразд», хоча перевірки
  не було взагалі.

  Заголовок тепер зсуває вміст під смугу прогресу: у класичному хості
  `Write-Progress` малюється поверх верхніх рядків вікна й повертає їх
  лише на `-Completed`, через що заголовок і перші етапи були невидимі
  протягом усього запуску.

- **Health падав із кодом `90` щоразу, коли лежала керована служба.**
  Об'єкт проблеми `Kind = "Service"` не несе полів `DifferenceCount` і
  `ActionCounts`, а `Get-AlertFingerprint` читав їх у всіх проблем без
  розбору. Під `Set-StrictMode` це помилка, тому runtime завершувався
  внутрішньою помилкою **замість того, щоб надіслати тривогу**: рівно
  той тип мовчазного моніторингу, проти якого існує Health. Поля тепер
  читаються через `Get-BRAVOHealthIssueField`.

- **`LogLevel = "SUCCESS"` приховував помилки в Maintenance.** У
  локальній шкалі рівнів `SUCCESS=4` стояв вище за `ERROR=3`, тому
  найвища детальність відсікала саме помилки й попередження. Шкалу
  приведено до тієї, що в `BRAVO.Logging`, де `SUCCESS` свідомо нижче
  за `WARNING`. Ту саму пастку `BRAVO.Logging` виправив раніше — тут
  вона лишалася в копії.

- **`THREAT_MODEL.md` приведено у відповідність до коду.** Документ
  описував як відкриті три ризики, які код уже закрив: послаблення
  перемикачів безпеки в `BRAVO.config` (код `34`), відкат версії
  (код `35`) і секрет як звичайний .NET `string`. Модель загроз, що
  перебільшує ризик, шкодить не менше за ту, що применшує — власник
  ухвалює інфраструктурні рішення саме за її списком пріоритетів.

  Перероблено розділи 3 (`BRAVO.config` як AST, умови блокування,
  `BRAVO_ALLOW_WEAKENED_SECURITY`), 4 (`SecureString`-ланцюг і чесна межа:
  SFTP URL і пароль 7-Zip лишаються незанулюваними рядками), 7 (перевірка
  `34` стежить за перемикачами, не за самим призначенням), 8 (стан у
  `LOGS\BRAVO_VERSION_STATE.json`, `BRAVO_ALLOW_DOWNGRADE`, і прямо
  сказано, що це захист від помилкового відкату, не від зловмисного —
  файл стану лежить на тому самому сервері) і 11 (перелік пріоритетів
  перебудовано, закриті пункти винесено окремо).

  Дрейф закрито тестами `Documentation/ThreatModelReflectsImplementedControls`
  і `Documentation/ThreatModelHasNoStaleResidualRisk`.

- **Аудит #5: секрет із Credential Manager більше не матеріалізується як
  звичайний рядок.** `StoredCredential.Secret` тепер `SecureString`. У
  .NET рядок незмінний, тому його неможливо занулити — копія пароля
  лишалась у керованій купі до збирання сміття, і кожне читання
  створювало ще одну, а Archive/Health/Maintenance читають облікові дані
  кілька разів за запуск.

  Декодування blob'а йде в `char[]` (масив можна очистити) з посимвольним
  додаванням у `SecureString`; масив байтів і масив символів зануляються
  у `finally`. Повного відкритого пароля не існує в керованій пам'яті на
  жодному кроці читання.

  **SMB-шлях плейнтексту не створює взагалі:** новий
  `New-BRAVOSecureCredential` будує `PSCredential` напряму з
  `SecureString`. Раніше пароль SMB ставав рядком лише для того, щоб
  одразу перетворитись назад.

  `ConvertFrom-BRAVOSecureSecret` — єдина точка перетворення в
  плейнтекст, із детермінованим зануленням проміжного BSTR
  (`ZeroFreeBSTR`). `Get-BRAVOCredentialSecret` збережено без зміни
  сигнатури, щоб не переписувати 19 місць runtime одним махом.

  **Чесна межа задокументована в SECURITY.md:** рядок, повернутий із
  точки перетворення, лишається незанулюваним. Зміна прибирає зайві
  копії й робить кожне перетворення видимим, але не усуває плейнтекст як
  такий — WinSCP приймає URL `sftp://user:pass@host`, а 7-Zip пароль
  через stdin. Повне усунення потребує SFTP-автентифікації ключем.

  Покрито `Secrets/CredentialSecretIsSecureString`,
  `SecureSecretRoundTrip` (кирилиця й спецсимволи — C# декодує байти
  вручну), `SecureCredentialSkipsPlainText`,
  `SmbPasswordNeverBecomesPlainText`.

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
