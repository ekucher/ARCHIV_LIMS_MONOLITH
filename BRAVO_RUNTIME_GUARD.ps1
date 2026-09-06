[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [string]$ManifestPath,

    # Ін'єкція для self-test: перевірити довільний каталог і вміст
    # маніфесту без файлу на диску.
    [string]$ManifestContent,

    [ValidateSet('Enforce', 'Warn')]
    [string]$Mode = 'Enforce'
)

##########
# Перевірка цілісності PowerShell-комплекту BRAVO перед завантаженням
# модулів (аудит P2).
#
# ЧОМУ ЦЕ ОКРЕМИЙ САМОДОСТАТНІЙ ФАЙЛ, А НЕ ФУНКЦІЯ В МОДУЛІ:
# перевірка має відбутися ДО Import-Module. Якби вона жила в
# BRAVO.Compatibility, довелося б спершу завантажити модуль, щоб
# перевірити модулі, — тобто виконати саме той код, який ще не
# перевірено. Тому тут використовуються лише .NET-типи й жодної
# залежності від решти комплекту.
#
# ЧЕСНА МЕЖА (не обходьте її мовчки):
# 1. Сам entrypoint (BRAVO_ARCHIV.ps1) і цей guard уже виконуються, коли
#    перевірка починається. Підміна саме цих двох файлів не буде
#    виявлена ДО їх запуску — вони входять до маніфесту, тому будуть
#    помічені, але вже після того, як їхній код відпрацював. Повне
#    закриття цієї межі потребує Authenticode-підпису й
#    ExecutionPolicy AllSigned (аудит P0.3, не реалізовано).
# 2. BRAVO.config НАВМИСНО не входить до маніфесту: він редагується на
#    кожному сервері (шляхи, розклад, увімкнені компоненти), тому
#    спільного еталонного хешу для нього не існує. Натомість guard
#    окремо перевіряє, що конфігурація не ПОСЛАБЛЮЄ захист (див.
#    Test-BRAVORuntimeSecuritySettings нижче).
##########

Set-StrictMode -Version 2.0

function Get-BRAVORuntimeFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Get-FileHash доступний з PowerShell 4.0; проєкт підтримує 3.0 як
    # мінімум для допоміжних шляхів, тому рахуємо через .NET напряму.
    $stream = $null
    $sha256 = $null
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $hashBytes = $sha256.ComputeHash($stream)
        return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToUpperInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $sha256) { $sha256.Dispose() }
    }
}

function Test-BRAVORuntimeManifestIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$ManifestContent,
        [ValidateSet('Enforce', 'Warn')][string]$Mode = 'Enforce'
    )

    $result = New-Object PSObject -Property @{
        IsValid = $true
        Mode = $Mode
        ManifestPath = $ManifestPath
        MismatchedFiles = @()
        MissingFiles = @()
        UnknownFiles = @()
        Message = $null
        ShouldBlock = $false
        CheckedCount = 0
    }

    $raw = $null
    if ($PSBoundParameters.ContainsKey('ManifestContent')) {
        $raw = $ManifestContent
    } elseif ([System.IO.File]::Exists($ManifestPath)) {
        try {
            $raw = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
        } catch {
            $raw = $null
        }
    }

    # Відсутній маніфест у режимі Enforce — відмова, а не мовчазний
    # пропуск: інакше найпростішим обходом було б його видалити.
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.IsValid = $false
        $result.Message = "Не знайдено або не вдалося прочитати RUNTIME_MANIFEST.json: $ManifestPath"
        $result.ShouldBlock = ($Mode -eq 'Enforce')
        return $result
    }

    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        $result.IsValid = $false
        $result.Message = "Пошкоджений RUNTIME_MANIFEST.json ($ManifestPath): $($_.Exception.Message)"
        $result.ShouldBlock = ($Mode -eq 'Enforce')
        return $result
    }

    $expected = @{}
    if ($null -ne $parsed -and
        $null -ne $parsed.PSObject.Properties['files'] -and
        $null -ne $parsed.files) {
        foreach ($property in $parsed.files.PSObject.Properties) {
            $expected[$property.Name] = ([string]$property.Value).Trim()
        }
    }
    if ($expected.Count -eq 0) {
        $result.IsValid = $false
        $result.Message = "RUNTIME_MANIFEST.json не містить жодного запису: $ManifestPath"
        $result.ShouldBlock = ($Mode -eq 'Enforce')
        return $result
    }

    $mismatched = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $unknown = New-Object System.Collections.ArrayList

    foreach ($relativePath in @($expected.Keys)) {
        $fullPath = Join-Path $RuntimeRoot $relativePath
        if (-not [System.IO.File]::Exists($fullPath)) {
            [void]$missing.Add($relativePath)
            continue
        }
        try {
            $actual = Get-BRAVORuntimeFileHash -Path $fullPath
        } catch {
            # Нечитабельний файл трактуємо як розбіжність: заблокований
            # на читання скрипт міг бути щойно підмінений.
            [void]$mismatched.Add("$relativePath (не вдалося обчислити хеш: $($_.Exception.Message))")
            continue
        }
        if (-not [string]::Equals($expected[$relativePath], $actual, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$mismatched.Add($relativePath)
        }
        $result.CheckedCount = $result.CheckedCount + 1
    }

    # Підкинутий у комплект новий .ps1/.psm1 — теж аномалія: він може
    # бути dot-source-нутий або підхоплений як модуль.
    $scanExtensions = @('.ps1', '.psm1', '.psd1')
    if ([System.IO.Directory]::Exists($RuntimeRoot)) {
        $rootPrefixLength = $RuntimeRoot.TrimEnd('\', '/').Length + 1
        $allScripts = @(
            [System.IO.Directory]::GetFiles($RuntimeRoot, '*', [System.IO.SearchOption]::AllDirectories) |
                Where-Object {
                    $scanExtensions -contains ([System.IO.Path]::GetExtension($_).ToLowerInvariant())
                }
        )
        foreach ($scriptPath in $allScripts) {
            $relative = $scriptPath.Substring($rootPrefixLength)
            # Каталоги, які не є частиною комплекту: логи й локальні
            # робочі копії розробника.
            if ($relative -match '^(LOGS|\.git|\.vscode|\.claude|local-backups)[\\/]') {
                continue
            }
            if (-not $expected.ContainsKey($relative)) {
                [void]$unknown.Add($relative)
            }
        }
    }

    $result.MismatchedFiles = @($mismatched.ToArray())
    $result.MissingFiles = @($missing.ToArray())
    $result.UnknownFiles = @($unknown.ToArray())

    if ($mismatched.Count -eq 0 -and $missing.Count -eq 0 -and $unknown.Count -eq 0) {
        return $result
    }

    $result.IsValid = $false
    $result.ShouldBlock = ($Mode -eq 'Enforce')

    $details = New-Object System.Collections.ArrayList
    if ($mismatched.Count -gt 0) {
        [void]$details.Add("змінено: $(@($mismatched.ToArray()) -join ', ')")
    }
    if ($missing.Count -gt 0) {
        [void]$details.Add("відсутні: $(@($missing.ToArray()) -join ', ')")
    }
    if ($unknown.Count -gt 0) {
        [void]$details.Add("сторонні скрипти в комплекті: $(@($unknown.ToArray()) -join ', ')")
    }

    $action = if ($Mode -eq 'Enforce') {
        "Запуск заблоковано (RuntimeIntegrityMode = Enforce)."
    } else {
        "Запуск продовжується (RuntimeIntegrityMode = Warn), але це слід перевірити."
    }

    $result.Message = (
        "ЦІЛІСНІСТЬ КОМПЛЕКТУ ПОРУШЕНО: {0}. {1} Заплановане завдання виконується від " +
        "NT AUTHORITY\SYSTEM, тому підмінений скрипт отримав би найвищі права в системі. " +
        "Якщо оновлення комплекту свідоме — оновіть RUNTIME_MANIFEST.json у репозиторії " +
        "(ci\Update-BRAVORuntimeManifest.ps1 -Apply) і розгорніть новий комплект; маніфест " +
        "навмисно не оновлюється автоматично на сервері."
    ) -f (@($details.ToArray()) -join "; "), $action

    return $result
}

##########
# Перевірка, що BRAVO.config не ПОСЛАБЛЮЄ захист.
#
# BRAVO.config навмисно не входить до RUNTIME_MANIFEST.json: він
# редагується на кожному сервері (шляхи, розклад, увімкнені компоненти),
# спільного еталонного хешу для нього не існує. Через це він лишався
# єдиним файлом комплекту, який можна змінити без жодного сліду — а в
# ньому є перемикачі, що вимикають самі перевірки безпеки:
#
#   $global:toolIntegritySettings.Mode = "Warn"   # підмінений 7za не блокує
#   $global:backupConsistency.Mode     = "Live"   # архів без VSS-знімка
#
# Рядок у файлі коштує зловмиснику дешевше, ніж підміна бінарника, і
# лишає менше слідів.
#
# ЧОМУ AST, А НЕ ВИКОНАННЯ КОНФІГУРАЦІЇ:
# BRAVO.config — це PowerShell-код, і завантажити його означає виконати
# довільний код ДО перевірки. Тут файл лише розбирається парсером
# ([Parser]::ParseFile) і читаються літеральні значення. Нічого не
# виконується.
#
# ЧЕСНА МЕЖА: перевіряються лише літерали. Значення, обчислене виразом
# ($mode = Get-Something; Mode = $mode), статично не читається — такий
# випадок трактується як "не вдалося підтвердити" й теж блокує в режимі
# Enforce, щоб обхід не був простішим за пряме послаблення.
##########

function Get-BRAVORuntimeConfigLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ConfigAst,
        [Parameter(Mandatory = $true)][string]$VariableName,
        [Parameter(Mandatory = $true)][string]$Key
    )

    # Усі присвоєння змінній (їх може бути кілька — беремо всі, бо
    # послаблення в будь-якому з них однаково небезпечне).
    $assignments = @($ConfigAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        (($node.Left.VariablePath.UserPath -replace '^global:', '') -eq $VariableName)
    }, $true))

    $found = New-Object System.Collections.ArrayList
    foreach ($assignment in $assignments) {
        $hashtables = @($assignment.Right.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.HashtableAst]
        }, $true))

        foreach ($hashtable in $hashtables) {
            foreach ($pair in $hashtable.KeyValuePairs) {
                $keyName = $null
                if ($pair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $keyName = $pair.Item1.Value
                }
                if ($keyName -ne $Key) { continue }

                # Значення літерал? Розгортаємо Pipeline -> CommandExpression.
                $valueAst = $pair.Item2
                $constants = @($valueAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }, $true))

                if ($constants.Count -eq 1) {
                    [void]$found.Add($constants[0].Value)
                } else {
                    # Обчислюване значення — статично не підтверджується.
                    [void]$found.Add($null)
                }
            }
        }
    }

    # Кома обов'язкова: PowerShell розгортає масив при поверненні, і
    # @($null) на виході перетворився б на $null. Тоді foreach по
    # результату не виконався б жодного разу — випадок "значення
    # обчислюється виразом" мовчки перестав би блокувати, тобто саме
    # той обхід, який ця функція має ловити. Знайдено функціональним
    # тестом, не рев'ю.
    return ,@($found.ToArray())
}

function Test-BRAVORuntimeSecuritySettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,

        # Ін'єкція для self-test: розібрати довільний вміст без файлу.
        [string]$ConfigContent,

        [ValidateSet('Enforce', 'Warn')][string]$Mode = 'Enforce',

        # Свідоме послаблення — лише через змінну середовища, за тим самим
        # зразком, що BRAVO_ALLOW_UNSUPPORTED_OS. Редагування самого
        # BRAVO.config при цьому недостатньо: щоб послабити захист, треба
        # зробити ДВІ різні дії в двох різних місцях, і друга лишає слід
        # поза комплектом.
        [string]$AllowWeakened
    )

    $result = New-Object PSObject -Property @{
        IsValid = $true
        Mode = $Mode
        ConfigPath = $ConfigPath
        Weakened = @()
        Unverifiable = @()
        Message = $null
        ShouldBlock = $false
        OverrideApplied = $false
    }

    if (-not $PSBoundParameters.ContainsKey('AllowWeakened')) {
        $AllowWeakened = [System.Environment]::GetEnvironmentVariable('BRAVO_ALLOW_WEAKENED_SECURITY')
    }

    $tokens = $null
    $parseErrors = $null
    $configAst = $null

    if ($PSBoundParameters.ContainsKey('ConfigContent')) {
        $configAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $ConfigContent, [ref]$tokens, [ref]$parseErrors)
    } elseif ([System.IO.File]::Exists($ConfigPath)) {
        $configAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $ConfigPath, [ref]$tokens, [ref]$parseErrors)
    } else {
        # P0 Configuration Foundation: BRAVO.config — опційний override-шар.
        # Його відсутність за замовчуваним шляхом — легітимний
        # synthetic-no-config сценарій (Import-BravoConfiguration/
        # BRAVO_CONFIG_LOADER.ps1), не помилка: без BRAVO.config
        # toolIntegritySettings.Mode/backupConsistency.Mode стартують із
        # canonical дефолтів (Get-BRAVODefaultConfiguration; toolIntegritySettings
        # взагалі не raw-configurable — лише deriv). Цей guard, як і раніше,
        # текстово перевіряє САМЕ BRAVO.config і не бачить BRAVO.local.config
        # (той самий, уже задокументований поза цим guard-ом розрив — не
        # новий, і не специфічний для synthetic-шляху: він існував і коли
        # BRAVO.config був обов'язковим).
        return $result
    }

    if ($null -eq $configAst) {
        return $result
    }

    # Перемикачі, послаблення яких вимикає саме те, що ми будували.
    $securityRules = @(
        @{
            Variable = 'toolIntegritySettings'
            Key = 'Mode'
            Expected = 'Enforce'
            Explanation = 'підмінений 7za.exe/WinSCP більше не блокує запуск'
        },
        @{
            Variable = 'backupConsistency'
            Key = 'Mode'
            Expected = 'VSS'
            Explanation = 'архів читається з live-каталогу, файли належать різним моментам часу'
        }
    )

    $weakened = New-Object System.Collections.ArrayList
    $unverifiable = New-Object System.Collections.ArrayList

    foreach ($rule in $securityRules) {
        # БЕЗ @() навколо виклику. Функція вже повертає масив через `,@(...)`,
        # і додаткове загортання зробило б із порожнього результату масив
        # з одного елемента-порожнього-масиву: Count стало б 1, а значення
        # прочиталось як порожній рядок. Тоді конфігурація, яка взагалі не
        # згадує ці налаштування, помилково рахувалася б послабленою.
        $values = Get-BRAVORuntimeConfigLiteral `
            -ConfigAst $configAst `
            -VariableName $rule.Variable `
            -Key $rule.Key

        if ($values.Count -eq 0) { continue }

        foreach ($value in $values) {
            if ($null -eq $value) {
                [void]$unverifiable.Add(
                    "`$global:$($rule.Variable).$($rule.Key) обчислюється виразом — статично не підтверджується")
                continue
            }
            if (-not [string]::Equals($value, $rule.Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$weakened.Add(
                    "`$global:$($rule.Variable).$($rule.Key) = '$value' замість '$($rule.Expected)' ($($rule.Explanation))")
            }
        }
    }

    $result.Weakened = @($weakened.ToArray())
    $result.Unverifiable = @($unverifiable.ToArray())

    if ($weakened.Count -eq 0 -and $unverifiable.Count -eq 0) {
        return $result
    }

    $result.IsValid = $false

    if ($AllowWeakened -eq '1') {
        $result.OverrideApplied = $true
        $result.ShouldBlock = $false
        $result.Message = (
            "УВАГА: BRAVO.config послаблює захист: {0}. Продовжено через " +
            "BRAVO_ALLOW_WEAKENED_SECURITY=1. Це тимчасовий режим міграції, не для постійної експлуатації."
        ) -f ((@($weakened.ToArray()) + @($unverifiable.ToArray())) -join '; ')
        return $result
    }

    $result.ShouldBlock = ($Mode -eq 'Enforce')

    $action = if ($Mode -eq 'Enforce') {
        "Запуск заблоковано."
    } else {
        "Запуск продовжується (RuntimeIntegrityMode = Warn), але це слід перевірити."
    }

    $result.Message = (
        "КОНФІГУРАЦІЯ ПОСЛАБЛЮЄ ЗАХИСТ: {0}. {1} BRAVO.config навмисно не входить до " +
        "RUNTIME_MANIFEST.json (він різний на кожному сервері), тому саме ці перемикачі — " +
        "найдешевший спосіб тихо вимкнути перевірки. Якщо послаблення свідоме й тимчасове, " +
        "встановіть BRAVO_ALLOW_WEAKENED_SECURITY=1 — тоді воно лишає слід поза комплектом."
    ) -f ((@($weakened.ToArray()) + @($unverifiable.ToArray())) -join '; '), $action

    return $result
}

##########
# Захист від відкату на старішу версію комплекту (downgrade).
#
# Усі перевірки вище порівнюють комплект із його ВЛАСНИМ маніфестом.
# Старий, коректно підписаний і внутрішньо узгоджений комплект пройде їх
# бездоганно — разом із усіма вразливостями, які відтоді закрили, і без
# перевірок, яких у ньому ще не існувало. Найпростіший спосіб вимкнути
# режим Enforce — не ламати його, а розгорнути версію, де його не було.
#
# Тому сервер запам'ятовує найвищу версію, яку на ньому колись
# запускали, і відмовляється виконувати старішу.
#
# ЧЕСНА МЕЖА: файл стану лежить поруч із логами, і той, хто має права
# підмінити комплект, зазвичай має права й видалити цей файл. Перевірка
# не робить відкат неможливим — вона робить його помітним і таким, що
# потребує ще однієї свідомої дії. Проти випадкового відкату (розгорнули
# не той архів) вона працює повністю.
##########

# Розбір версії комплекту з підтримкою prerelease-суфікса (SemVer:
# X.Y.Z[-prerelease][+build]). Сам по собі [version] кидає виняток на
# "5.3.0-dev.2" — і саме так prerelease-версії мовчки обходили
# downgrade-захист: і не фіксували highestVersion, і не блокували
# справжній відкат (acceptance-знахідка 2026-09-03; походження — коміт
# 3e27dae, до Configuration Foundation). Повертає $null, якщо текст не є
# версією, — рішення про наслідки ухвалює викликач.
function ConvertTo-BRAVOComparableVersion {
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()

    # Build-метадані (+...) за SemVer не впливають на порядок версій,
    # але їхній синтаксис валідується (dot-separated, непорожні
    # ідентифікатори [0-9A-Za-z-]): build-суфікс не має бути каналом,
    # яким malformed текст оминає перевірку нижче.
    $plusIndex = $trimmed.IndexOf('+')
    if ($plusIndex -ge 0) {
        $buildMetadata = $trimmed.Substring($plusIndex + 1)
        $trimmed = $trimmed.Substring(0, $plusIndex)
        if ([string]::IsNullOrEmpty($buildMetadata)) { return $null }
        foreach ($buildIdentifier in $buildMetadata.Split('.')) {
            if ($buildIdentifier -cnotmatch '^[0-9A-Za-z-]+$') { return $null }
        }
    }

    $prerelease = $null
    $baseText = $trimmed
    $dashIndex = $trimmed.IndexOf('-')
    if ($dashIndex -ge 0) {
        $prerelease = $trimmed.Substring($dashIndex + 1)
        $baseText = $trimmed.Substring(0, $dashIndex)
        if ([string]::IsNullOrWhiteSpace($prerelease)) { return $null }
        # SemVer 2.0 §9: кожен dot-ідентифікатор prerelease непорожній,
        # лише [0-9A-Za-z-]; числовий — без leading zero (крім "0").
        # Review-знахідка PR #135: суфікс на кшталт 'rc"oops' раніше
        # приймався, лапка потрапляла в highestVersionFull і ламала
        # state JSON — наступний запуск втрачав high-water mark, і
        # захист від відкату слабшав. Валідація ДО порівняння і ДО
        # запису стану.
        foreach ($prereleaseIdentifier in $prerelease.Split('.')) {
            if ($prereleaseIdentifier -cnotmatch '^[0-9A-Za-z-]+$') { return $null }
            if ($prereleaseIdentifier -cmatch '^0[0-9]+$') { return $null }
        }
    }

    # Канонічний контракт пакета — рівно X.Y.Z (три числові
    # dot-ідентифікатори без leading zero). Сам [version] прийняв би і
    # "5.3", і "5.3.0.1", і "05.3.0" — а чотирикомпонентний запис у
    # state зробив би коректний "5.3.0" «відкатом» (Revision -1 проти 1)
    # замість malformed fail-closed шляху (review PR #135, друга хвиля).
    if ($baseText -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        return $null
    }
    # СВІДОМИЙ контракт BRAVO, а не випадковий технічний ліміт: core
    # X.Y.Z записується як ModuleVersion у кожному *.psd1, а
    # ModuleVersion на Windows PowerShell 5.1 — [System.Version], тобто
    # кожен компонент <= Int32.MaxValue. Тому core, непредставимий через
    # [version] (напр. 2147483648.0.0), — це непідтримувана packageVersion
    # (malformed fail-closed шлях); той самий контракт заздалегідь
    # блокує її в CI (ci\Test-BRAVOReleasePolicy.ps1, RELEASE_POLICY.md).
    # Numeric prerelease-ідентифікатори (-rc.N) цим НЕ обмежені —
    # порівнюються як digit-рядки довільної довжини (див. нижче).
    $base = $null
    if (-not [version]::TryParse($baseText, [ref]$base)) { return $null }

    return New-Object PSObject -Property @{
        Base = $base
        Prerelease = $prerelease
        Text = $trimmed
    }
}

# SemVer-порівняння двох результатів ConvertTo-BRAVOComparableVersion:
# -1/0/1 (Left молодший / рівний / старший). База X.Y.Z — за [version];
# за однакової бази stable СТАРШИЙ за будь-який prerelease
# (5.3.0 > 5.3.0-rc.9); два prerelease — за dot-ідентифікаторами:
# числові порівнюються як числа і молодші за текстові, текстові —
# ординально, коротший список ідентифікаторів молодший
# (dev.2 < rc.1 < rc.1.hotfix).
function Compare-BRAVOComparableVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    if ($Left.Base -lt $Right.Base) { return -1 }
    if ($Left.Base -gt $Right.Base) { return 1 }

    if ($null -eq $Left.Prerelease -and $null -eq $Right.Prerelease) { return 0 }
    if ($null -eq $Left.Prerelease) { return 1 }
    if ($null -eq $Right.Prerelease) { return -1 }

    $leftIdentifiers = $Left.Prerelease.Split('.')
    $rightIdentifiers = $Right.Prerelease.Split('.')
    $commonCount = [Math]::Min($leftIdentifiers.Length, $rightIdentifiers.Length)
    for ($index = 0; $index -lt $commonCount; $index++) {
        # SemVer не обмежує числовий ідентифікатор розрядністю Int64
        # (review-знахідка PR #135: два ідентифікатори понад
        # Int64.MaxValue обидва «переставали» бути числовими і падали в
        # ординальне порівняння, яке може інвертувати порядок). Числовий
        # ідентифікатор — це рядок цифр без leading zero (гарантія
        # ConvertTo-BRAVOComparableVersion), тому порівняння точне для
        # будь-якої довжини: коротший рядок цифр менший, за однакової
        # довжини — ординально.
        $leftIsNumeric = $leftIdentifiers[$index] -cmatch '^[0-9]+$'
        $rightIsNumeric = $rightIdentifiers[$index] -cmatch '^[0-9]+$'
        if ($leftIsNumeric -and $rightIsNumeric) {
            if ($leftIdentifiers[$index].Length -lt $rightIdentifiers[$index].Length) { return -1 }
            if ($leftIdentifiers[$index].Length -gt $rightIdentifiers[$index].Length) { return 1 }
            $numericOrdinal = [string]::CompareOrdinal($leftIdentifiers[$index], $rightIdentifiers[$index])
            if ($numericOrdinal -lt 0) { return -1 }
            if ($numericOrdinal -gt 0) { return 1 }
        } elseif ($leftIsNumeric) {
            return -1
        } elseif ($rightIsNumeric) {
            return 1
        } else {
            $ordinal = [string]::CompareOrdinal($leftIdentifiers[$index], $rightIdentifiers[$index])
            if ($ordinal -lt 0) { return -1 }
            if ($ordinal -gt 0) { return 1 }
        }
    }
    if ($leftIdentifiers.Length -lt $rightIdentifiers.Length) { return -1 }
    if ($leftIdentifiers.Length -gt $rightIdentifiers.Length) { return 1 }
    return 0
}

# Внутрішній regression-test isolation seam (SELFTEST-SAFETY-0 v1.4).
# НЕ security/authorization boundary і НЕ production-налаштування: клас
# загрози "env-обхід" не новий (рівноцінний існуючому аварійному вентилю
# BRAVO_ALLOW_DOWNGRADE=1). Контракт: рівно два валідні режими —
#   None     : жодної з трьох BRAVO_SELFTEST_* змінних немає -> канонічна
#              production-поведінка (StatePath викликача авторитетний);
#   Isolated : УСІ ТРИ присутні й узгоджені -> сховище стану
#              переспрямовується в sandbox самотесту, валідація версій
#              виконується без змін.
# Будь-яка часткова/некоректна комбінація -> Invalid (fail closed у
# Test-BRAVOVersionDowngrade, без відкату до production-шляху). Вимоги:
# SESSION_ID — GUID; ROOT — абсолютний локальний шлях (не UNC) з basename
# рівно BRAVO_SELFTEST_<GUID>; STATE_PATH — рівно <ROOT>\State\
# BRAVO_VERSION_STATE.json (канонізація GetFullPath, порівняння
# case-insensitive — traversal/sibling-трюки відсікаються рівністю, не
# StartsWith); ROOT і <ROOT>\State, якщо існують, не сміють бути
# reparse-point/junction (тест-контрольований junction не має права
# завести запис у справжній production-каталог).
function Resolve-BRAVOSelfTestIsolationContext {
    [CmdletBinding()]
    param()

    $sessionIdRaw = [System.Environment]::GetEnvironmentVariable('BRAVO_SELFTEST_SESSION_ID')
    $rootRaw = [System.Environment]::GetEnvironmentVariable('BRAVO_SELFTEST_ROOT')
    $statePathRaw = [System.Environment]::GetEnvironmentVariable('BRAVO_SELFTEST_VERSION_STATE_PATH')

    $context = New-Object PSObject -Property @{
        Mode = 'None'
        Reason = $null
        SessionId = $null
        Root = $null
        StatePath = $null
    }

    $sessionPresent = -not [string]::IsNullOrWhiteSpace($sessionIdRaw)
    $rootPresent = -not [string]::IsNullOrWhiteSpace($rootRaw)
    $statePresent = -not [string]::IsNullOrWhiteSpace($statePathRaw)

    if (-not $sessionPresent -and -not $rootPresent -and -not $statePresent) {
        return $context
    }

    $context.Mode = 'Invalid'

    if (-not ($sessionPresent -and $rootPresent -and $statePresent)) {
        $missing = @()
        if (-not $sessionPresent) { $missing += 'BRAVO_SELFTEST_SESSION_ID' }
        if (-not $rootPresent) { $missing += 'BRAVO_SELFTEST_ROOT' }
        if (-not $statePresent) { $missing += 'BRAVO_SELFTEST_VERSION_STATE_PATH' }
        $context.Reason = "неповний контекст (відсутні: $($missing -join ', '))"
        return $context
    }

    $sessionGuid = [guid]::Empty
    if (-not [guid]::TryParse($sessionIdRaw.Trim(), [ref]$sessionGuid)) {
        $context.Reason = "BRAVO_SELFTEST_SESSION_ID не є GUID"
        return $context
    }

    $rootText = $rootRaw.Trim()
    $stateText = $statePathRaw.Trim()

    # UNC відсікається до канонізації: мережевий sandbox самотесту не
    # передбачений цією фазою.
    if ($rootText.StartsWith('\\') -or $stateText.StartsWith('\\')) {
        $context.Reason = "UNC-шлях не підтримується для self-test sandbox"
        return $context
    }
    if (-not [System.IO.Path]::IsPathRooted($rootText) -or
        $rootText -notmatch '^[A-Za-z]:\\') {
        $context.Reason = "BRAVO_SELFTEST_ROOT не є абсолютним локальним шляхом"
        return $context
    }
    if (-not [System.IO.Path]::IsPathRooted($stateText) -or
        $stateText -notmatch '^[A-Za-z]:\\') {
        $context.Reason = "BRAVO_SELFTEST_VERSION_STATE_PATH не є абсолютним локальним шляхом"
        return $context
    }

    $rootFull = $null
    $stateFull = $null
    try {
        $rootFull = [System.IO.Path]::GetFullPath($rootText).TrimEnd('\')
        $stateFull = [System.IO.Path]::GetFullPath($stateText)
    } catch {
        $context.Reason = "шлях контексту не канонізується: $($_.Exception.Message)"
        return $context
    }

    $expectedBasename = 'BRAVO_SELFTEST_' + $sessionGuid.ToString('D')
    $actualBasename = [System.IO.Path]::GetFileName($rootFull)
    if (-not [string]::Equals($actualBasename, $expectedBasename,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $context.Reason = "basename ROOT ('$actualBasename') не відповідає сесії ('$expectedBasename')"
        return $context
    }

    $expectedStatePath = [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $rootFull 'State') 'BRAVO_VERSION_STATE.json'))
    if (-not [string]::Equals($stateFull, $expectedStatePath,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $context.Reason = "STATE_PATH не є рівно <ROOT>\State\BRAVO_VERSION_STATE.json"
        return $context
    }

    # Reparse/junction: рядкова валідація не ловить перенаправлення
    # файлової системи. Неіснуючі каталоги легітимні (guard сам створює
    # State при першому записі).
    foreach ($guardedDirectory in @($rootFull, (Join-Path $rootFull 'State'))) {
        try {
            if ([System.IO.Directory]::Exists($guardedDirectory)) {
                $directoryAttributes = [System.IO.File]::GetAttributes($guardedDirectory)
                if (($directoryAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $context.Reason = "'$guardedDirectory' є reparse point/junction"
                    return $context
                }
            }
        } catch {
            $context.Reason = "не вдалося перевірити атрибути '$guardedDirectory': $($_.Exception.Message)"
            return $context
        }
    }

    $context.Mode = 'Isolated'
    $context.Reason = $null
    $context.SessionId = $sessionGuid.ToString('D')
    $context.Root = $rootFull
    $context.StatePath = $expectedStatePath
    return $context
}

function Test-BRAVOVersionDowngrade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$StatePath,

        # Ін'єкція для self-test.
        [string]$VersionContent,
        [string]$StateContent,

        [ValidateSet('Enforce', 'Warn')][string]$Mode = 'Enforce',
        [string]$AllowDowngrade,

        # Self-test перевіряє логіку, не змінюючи стан машини.
        [switch]$NoWrite
    )

    $result = New-Object PSObject -Property @{
        IsValid = $true
        Mode = $Mode
        StatePath = $StatePath
        DeployedVersion = $null
        RecordedVersion = $null
        Message = $null
        ShouldBlock = $false
        OverrideApplied = $false
        StateUpdated = $false
    }

    if (-not $PSBoundParameters.ContainsKey('AllowDowngrade')) {
        $AllowDowngrade = [System.Environment]::GetEnvironmentVariable('BRAVO_ALLOW_DOWNGRADE')
    }

    # Тест-ізоляція СХОВИЩА стану (SELFTEST-SAFETY-0 v1.4): валідний
    # self-test-контекст переспрямовує лише місце зберігання
    # BRAVO_VERSION_STATE.json; частковий/некоректний контекст — fail
    # closed БЕЗ жодного звертання до production-шляху. Перевірка
    # виконується ДО будь-якого читання/запису стану за $StatePath.
    $selfTestContext = Resolve-BRAVOSelfTestIsolationContext
    if ($selfTestContext.Mode -eq 'Invalid') {
        $result.IsValid = $false
        $result.ShouldBlock = $true
        $result.Message = "Invalid BRAVO SelfTest isolation context: $($selfTestContext.Reason)"
        return $result
    }
    if ($selfTestContext.Mode -eq 'Isolated') {
        $StatePath = $selfTestContext.StatePath
        $result.StatePath = $StatePath
    }

    $versionRaw = $null
    if ($PSBoundParameters.ContainsKey('VersionContent')) {
        $versionRaw = $VersionContent
    } else {
        $versionPath = Join-Path $RuntimeRoot 'VERSION.json'
        if ([System.IO.File]::Exists($versionPath)) {
            try {
                $versionRaw = [System.IO.File]::ReadAllText($versionPath, [System.Text.Encoding]::UTF8)
            } catch {
                $versionRaw = $null
            }
        }
    }

    # VERSION.json входить до RUNTIME_MANIFEST.json, тому його
    # відсутність уже спіймана перевіркою цілісності вище. Тут вона
    # означає лише, що порівнювати нема з чим.
    if ([string]::IsNullOrWhiteSpace($versionRaw)) { return $result }

    $deployed = $null
    $deployedText = $null
    try {
        $versionParsed = $versionRaw | ConvertFrom-Json
        $deployedText = [string]$versionParsed.packageVersion
        $deployed = ConvertTo-BRAVOComparableVersion -Text $deployedText
    } catch {
        $deployed = $null
    }

    # VERSION.json захищений маніфестом, тому непарсибельна packageVersion
    # тут — не "битий файл на сервері", а аномалія самого комплекту
    # (дефект release-інженерії або обхід). Мовчазний пропуск був би тим
    # самим bypass-ом, який ця перевірка мусить ловити, — fail-closed за
    # режимом, з тим самим аварійним вентилем BRAVO_ALLOW_DOWNGRADE=1.
    if ($null -eq $deployed) {
        $result.IsValid = $false
        if ($AllowDowngrade -eq '1') {
            $result.OverrideApplied = $true
            $result.Message = (
                "УВАГА: packageVersion у VERSION.json не розпізнано як версію ('{0}'). " +
                "Продовжено через BRAVO_ALLOW_DOWNGRADE=1."
            ) -f $deployedText
            return $result
        }
        $result.ShouldBlock = ($Mode -eq 'Enforce')
        $versionParseAction = if ($Mode -eq 'Enforce') {
            "Запуск заблоковано."
        } else {
            "Запуск продовжується (RuntimeIntegrityMode = Warn), але це слід перевірити."
        }
        $result.Message = (
            "ВЕРСІЯ НЕ РОЗПІЗНАНА: packageVersion у VERSION.json ('{0}') не є версією " +
            "X.Y.Z[-prerelease] — захист від відкату не може порівняти комплект. {1} " +
            "Якщо запуск свідомий, встановіть BRAVO_ALLOW_DOWNGRADE=1."
        ) -f $deployedText, $versionParseAction
        return $result
    }
    $result.DeployedVersion = $deployed.Text

    $stateRaw = $null
    if ($PSBoundParameters.ContainsKey('StateContent')) {
        $stateRaw = $StateContent
    } elseif ([System.IO.File]::Exists($StatePath)) {
        try {
            $stateRaw = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8)
        } catch {
            $stateRaw = $null
        }
    }

    $recorded = $null
    if (-not [string]::IsNullOrWhiteSpace($stateRaw)) {
        try {
            $stateParsed = $stateRaw | ConvertFrom-Json
            # highestVersionFull зберігає повну версію разом із
            # prerelease-суфіксом; legacy-поле highestVersion лишається
            # базовим X.Y.Z, щоб старіший guard (який парсить його через
            # [version]) продовжував читати цей стан.
            $recordedText = $null
            if ($null -ne $stateParsed -and
                $null -ne $stateParsed.PSObject.Properties['highestVersionFull']) {
                $recordedText = [string]$stateParsed.highestVersionFull
            }
            if ([string]::IsNullOrWhiteSpace($recordedText) -and
                $null -ne $stateParsed -and
                $null -ne $stateParsed.PSObject.Properties['highestVersion']) {
                $recordedText = [string]$stateParsed.highestVersion
            }
            if (-not [string]::IsNullOrWhiteSpace($recordedText)) {
                $recorded = ConvertTo-BRAVOComparableVersion -Text $recordedText
            }
        } catch {
            # Пошкоджений файл стану НЕ блокує: на відміну від маніфеста,
            # він не є еталоном довіри, і його втрата не мусить зупиняти
            # backup. Наступний успішний запуск запише його наново.
            $recorded = $null
        }
    }

    if ($null -ne $recorded) { $result.RecordedVersion = $recorded.Text }

    # Перший запуск або новіша версія — запам'ятовуємо й пропускаємо.
    $comparison = if ($null -eq $recorded) { 1 } else {
        Compare-BRAVOComparableVersion -Left $deployed -Right $recorded
    }
    if ($comparison -ge 0) {
        if (-not $NoWrite -and ($null -eq $recorded -or $comparison -gt 0)) {
            $sourceCommit = ''
            try {
                if ($null -ne $versionParsed.PSObject.Properties['sourceCommit']) {
                    $sourceCommit = [string]$versionParsed.sourceCommit
                }
            } catch {
                $sourceCommit = ''
            }
            # Штатна JSON-серіалізація замість ручного формат-рядка:
            # ConvertTo-Json екранує будь-який вміст полів, тому жоден
            # символ у версії чи sourceCommit не може зробити state
            # непарсибельним (review-знахідка PR #135). Імена полів —
            # контракт: highestVersion лишається legacy-сумісною базою
            # X.Y.Z для старішого guard, highestVersionFull — повна
            # валідована версія.
            $stateJson = ([pscustomobject]@{
                highestVersion = $deployed.Base.ToString()
                highestVersionFull = $deployed.Text
                sourceCommit = $sourceCommit
                recordedAt = ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
            } | ConvertTo-Json) + [Environment]::NewLine
            try {
                $stateDirectory = [System.IO.Path]::GetDirectoryName($StatePath)
                if (-not [System.IO.Directory]::Exists($stateDirectory)) {
                    [void][System.IO.Directory]::CreateDirectory($stateDirectory)
                }
                [System.IO.File]::WriteAllText(
                    $StatePath, $stateJson, (New-Object System.Text.UTF8Encoding($false)))
                $result.StateUpdated = $true
            } catch {
                # Недоступний для запису каталог логів не мусить зупиняти
                # backup — це діагностується окремо.
                $result.StateUpdated = $false
            }
        }
        return $result
    }

    $result.IsValid = $false

    if ($AllowDowngrade -eq '1') {
        $result.OverrideApplied = $true
        $result.Message = (
            "УВАГА: розгорнуто старішу версію комплекту ({0} замість {1}, яку вже запускали на цьому сервері). " +
            "Продовжено через BRAVO_ALLOW_DOWNGRADE=1."
        ) -f $result.DeployedVersion, $result.RecordedVersion
        return $result
    }

    $result.ShouldBlock = ($Mode -eq 'Enforce')

    $action = if ($Mode -eq 'Enforce') {
        "Запуск заблоковано."
    } else {
        "Запуск продовжується (RuntimeIntegrityMode = Warn), але це слід перевірити."
    }

    $result.Message = (
        "ВІДКАТ ВЕРСІЇ: розгорнуто {0}, тоді як на цьому сервері вже запускали {1}. {2} " +
        "Старіший комплект проходить усі перевірки цілісності — разом із вразливостями, які " +
        "відтоді закрили, і без перевірок, яких у ньому ще не існувало. Якщо відкат свідомий " +
        "(наприклад, аварійне повернення на попередній реліз), встановіть BRAVO_ALLOW_DOWNGRADE=1."
    ) -f $result.DeployedVersion, $result.RecordedVersion, $action

    return $result
}

# Пряме виконання (не dot-source): виконати перевірку й повернути код.
# Dot-source з entrypoint лише оголошує функції, нічого не виконуючи, —
# так само, як це роблять runtime-файли модулів.
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = $PSScriptRoot
    }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $RuntimeRoot 'RUNTIME_MANIFEST.json'
    }

    $guardParameters = @{
        RuntimeRoot = $RuntimeRoot
        ManifestPath = $ManifestPath
        Mode = $Mode
    }
    if ($PSBoundParameters.ContainsKey('ManifestContent')) {
        $guardParameters['ManifestContent'] = $ManifestContent
    }
    $guardResult = Test-BRAVORuntimeManifestIntegrity @guardParameters

    if (-not $guardResult.IsValid) {
        Write-Host $guardResult.Message -ForegroundColor Red
        if ($guardResult.ShouldBlock) { exit 33 }
    } else {
        Write-Host "Цілісність комплекту підтверджена (перевірено файлів: $($guardResult.CheckedCount))." -ForegroundColor Green
    }

    # Цілісність комплекту підтверджує, що файли ті самі. Вона нічого не
    # каже про BRAVO.config, якого в маніфесті немає за задумом, — тому
    # перевірка перемикачів іде окремим кроком.
    $securityResult = Test-BRAVORuntimeSecuritySettings `
        -ConfigPath (Join-Path $RuntimeRoot 'BRAVO.config') `
        -Mode $Mode

    if (-not $securityResult.IsValid) {
        $color = if ($securityResult.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $securityResult.Message -ForegroundColor $color
        if ($securityResult.ShouldBlock) { exit 34 }
    }

    # -NoWrite: ручний діагностичний запуск guard-а не повинен фіксувати
    # версію як "запускали на цьому сервері". Інакше сама діагностика
    # змінювала б стан, який вона перевіряє.
    $versionResult = Test-BRAVOVersionDowngrade `
        -RuntimeRoot $RuntimeRoot `
        -StatePath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BRAVO\State\BRAVO_VERSION_STATE.json') `
        -Mode $Mode `
        -NoWrite

    if (-not $versionResult.IsValid) {
        $versionColor = if ($versionResult.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $versionResult.Message -ForegroundColor $versionColor
        if ($versionResult.ShouldBlock) { exit 35 }
    }

    exit 0
}
