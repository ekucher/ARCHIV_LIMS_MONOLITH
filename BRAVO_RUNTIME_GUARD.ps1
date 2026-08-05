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
            if ($relative -match '^(LOGS|\.git|\.vscode|local-backups)[\\/]') {
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
        # Відсутність конфігурації — не задача цього guard: її діагностує
        # завантажувач із кодом 30 і зрозумілим повідомленням.
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

    try {
        $versionParsed = $versionRaw | ConvertFrom-Json
        $deployedText = [string]$versionParsed.packageVersion
        $deployed = [version]$deployedText
    } catch {
        return $result
    }
    $result.DeployedVersion = $deployed.ToString()

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
            if ($null -ne $stateParsed -and
                $null -ne $stateParsed.PSObject.Properties['highestVersion']) {
                $recorded = [version]([string]$stateParsed.highestVersion)
            }
        } catch {
            # Пошкоджений файл стану НЕ блокує: на відміну від маніфеста,
            # він не є еталоном довіри, і його втрата не мусить зупиняти
            # backup. Наступний успішний запуск запише його наново.
            $recorded = $null
        }
    }

    if ($null -ne $recorded) { $result.RecordedVersion = $recorded.ToString() }

    # Перший запуск або новіша версія — запам'ятовуємо й пропускаємо.
    if ($null -eq $recorded -or $deployed -ge $recorded) {
        if (-not $NoWrite -and ($null -eq $recorded -or $deployed -gt $recorded)) {
            $sourceCommit = ''
            try {
                if ($null -ne $versionParsed.PSObject.Properties['sourceCommit']) {
                    $sourceCommit = [string]$versionParsed.sourceCommit
                }
            } catch {
                $sourceCommit = ''
            }
            $stateJson = (
                '{{{0}  "highestVersion": "{1}",{0}  "sourceCommit": "{2}",{0}  "recordedAt": "{3}"{0}}}{0}'
            ) -f [Environment]::NewLine,
                 $deployed.ToString(),
                 $sourceCommit,
                 ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
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
        -StatePath (Join-Path $RuntimeRoot 'LOGS\BRAVO_VERSION_STATE.json') `
        -Mode $Mode `
        -NoWrite

    if (-not $versionResult.IsValid) {
        $versionColor = if ($versionResult.ShouldBlock) { 'Red' } else { 'Yellow' }
        Write-Host $versionResult.Message -ForegroundColor $versionColor
        if ($versionResult.ShouldBlock) { exit 35 }
    }

    exit 0
}
