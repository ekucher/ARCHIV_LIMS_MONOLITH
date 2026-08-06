# Автоматичний Discovery джерел BRAVO: визначення BRAVO_ROOT/WEB_ROOT і
# джерел MODEL/BLOG/BRAVOEXCH/BAZA_APP/BAZA_WWW/BACKUP_ROOT за встановленими
# Windows-службами та активним bravo.ini, з повним ручним перевизначенням
# через BRAVO.config.
#
# BRAVO_ROOT — каталог встановлення служби BRAVO (де лежить bravo.exe).
# Не плутати з pathSettings.ArchiveRoot (BRAVO.config) — каталогом самого
# скрипта резервного копіювання (де лежать Tools\/LOGS\/TOOLS_MANIFEST.json,
# завжди поруч зі скриптом, ніколи не через Discovery). BACKUP_ROOT —
# підкаталог "ARCHIV" усередині BRAVO_ROOT, дефолт для
# pathSettings.BackupRoot (куди зберігаються самі архіви) — третє окреме
# поняття, яке легко сплутати з двома першими через спільне слово
# "ARCHIV"/"архів".
#
# Мінімальна підтримувана версія: Windows PowerShell 3.0.

function Get-BRAVOServiceExecutablePath {
    # Парсить Win32_Service.PathName ("C:\...\bravo.exe" -k runservice ->
    # C:\...\bravo.exe). Перенесено з BRAVO.config без зміни поведінки:
    # Find-BRAVOWebBAZASource (BRAVO.config) продовжує використовувати цю
    # саму функцію з модуля.
    [CmdletBinding()]
    param([string]$PathName)

    $expandedPath = [Environment]::ExpandEnvironmentVariables(
        [string]$PathName
    ).Trim()
    if ($expandedPath -match '^\s*"([^"]+)"') {
        return $matches[1]
    }
    if ($expandedPath -match '^\s*([^\s]+)') {
        return $matches[1]
    }
    return $null
}

function Find-BRAVOServiceByCandidates {
    # Generic-версія enumerate-частини Find-BRAVOWebBAZASource: знаходить
    # встановлені (не Disabled) служби за списком кандидатів імен
    # (Name/DisplayName, case-insensitive), опційно доповнює список
    # службами, які запускають виконуваний файл із заданою назвою
    # (ExecutableNameFallback), незалежно від імені самої служби —
    # той самий підхід, що вже застосований для httpd.exe. Активні
    # (Running) служби завжди йдуть перед зупиненими.
    #
    # -Services дозволяє self-test підставити синтетичні Win32_Service-
    # подібні об'єкти замість реального WMI-запиту — той самий injectable-
    # патерн, що вже використовує Get-BRAVOOSSupportTier/
    # Get-BRAVOPowerShellUpdateRecommendation (modules\BRAVO.Compatibility).
    [CmdletBinding()]
    param(
        [string[]]$ServiceCandidates,
        [string]$ExecutableNameFallback,
        [object[]]$Services
    )

    if ($null -eq $Services) {
        try {
            $Services = @(
                Get-BRAVOWmiInstance -ClassName Win32_Service |
                    Where-Object {
                        [string]$_.StartMode -ne "Disabled" -and
                        -not [string]::IsNullOrWhiteSpace([string]$_.PathName)
                    }
            )
        } catch {
            return @()
        }
    } else {
        $Services = @(
            $Services | Where-Object {
                [string]$_.StartMode -ne "Disabled" -and
                -not [string]::IsNullOrWhiteSpace([string]$_.PathName)
            }
        )
    }

    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($runningOnly in @($true, $false)) {
        foreach ($candidateName in @($ServiceCandidates)) {
            foreach ($service in @(
                $Services | Where-Object {
                    ($_.Name -ieq $candidateName -or
                    $_.DisplayName -ieq $candidateName) -and
                    (
                        ($runningOnly -and $_.State -eq "Running") -or
                        (-not $runningOnly -and $_.State -ne "Running")
                    )
                }
            )) {
                if (-not $ordered.Contains($service)) {
                    $ordered.Add($service)
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExecutableNameFallback)) {
        foreach ($service in @(
            $Services |
                Where-Object {
                    $executable = Get-BRAVOServiceExecutablePath -PathName $_.PathName
                    -not [string]::IsNullOrWhiteSpace($executable) -and
                    [System.IO.Path]::GetFileName($executable) -ieq $ExecutableNameFallback
                } |
                Sort-Object @{
                    Expression = { if ($_.State -eq "Running") { 0 } else { 1 } }
                }
        )) {
            if (-not $ordered.Contains($service)) {
                $ordered.Add($service)
            }
        }
    }

    return @($ordered | ForEach-Object {
        $executablePath = Get-BRAVOServiceExecutablePath -PathName $_.PathName
        [pscustomobject]@{
            Name = [string]$_.Name
            DisplayName = [string]$_.DisplayName
            State = [string]$_.State
            StartMode = [string]$_.StartMode
            ExecutablePath = $executablePath
        }
    })
}

function ConvertFrom-BRAVOIniFile {
    # Мінімальний INI-парсер: секції [Name], рядки KEY=VALUE, коментарі ";"
    # (після trim рядка), порожні рядки ігноруються, ключі case-insensitive,
    # останнє неекрановане значення для дубльованого ключа виграє. Точно
    # покриває формат наданого bravo.ini (секції [system]/[archiv]/[model]/
    # /[net]/[Debug], закоментовані й задубльовані ключі).
    #
    # Звичайний Hashtable (не [ordered]) для узгодженості з
    # BRAVO.ExitCodes: тут немає позиційного індексатора, порядок секцій
    # не потрібен для читання значень за іменем.
    [CmdletBinding()]
    param(
        [string]$Path,
        [string[]]$Content
    )

    if ($null -eq $Content) {
        if ([string]::IsNullOrWhiteSpace($Path) -or
            -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }
        $Content = Get-Content -LiteralPath $Path -Encoding UTF8
    }

    $result = @{}
    $currentSectionName = ""
    $result[$currentSectionName] = @{}

    foreach ($rawLine in @($Content)) {
        $line = [string]$rawLine
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        if ($trimmed.StartsWith(";")) {
            continue
        }
        if ($trimmed.StartsWith("[") -and $trimmed.EndsWith("]")) {
            $currentSectionName = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
            if (-not $result.ContainsKey($currentSectionName)) {
                $result[$currentSectionName] = @{}
            }
            continue
        }
        $separatorIndex = $trimmed.IndexOf("=")
        if ($separatorIndex -lt 0) {
            continue
        }
        $key = $trimmed.Substring(0, $separatorIndex).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }
        $value = $trimmed.Substring($separatorIndex + 1).Trim()
        $result[$currentSectionName][$key] = $value
    }

    return $result
}

function Get-BRAVOIniValue {
    # Case-insensitive пошук значення в результаті ConvertFrom-BRAVOIniFile;
    # $null, якщо секції/ключа немає або значення порожнє.
    [CmdletBinding()]
    param(
        [object]$IniData,
        [string]$Section,
        [string]$Key
    )

    if ($null -eq $IniData -or -not ($IniData -is [System.Collections.IDictionary])) {
        return $null
    }
    $sectionData = $null
    foreach ($sectionName in $IniData.Keys) {
        if ($sectionName -ieq $Section) {
            $sectionData = $IniData[$sectionName]
            break
        }
    }
    if ($null -eq $sectionData -or -not ($sectionData -is [System.Collections.IDictionary])) {
        return $null
    }
    foreach ($keyName in $sectionData.Keys) {
        if ($keyName -ieq $Key) {
            $value = [string]$sectionData[$keyName]
            if ([string]::IsNullOrWhiteSpace($value)) {
                return $null
            }
            return $value
        }
    }
    return $null
}

function Get-BRAVOSystemBravoIniPath {
    # bravo.ini не лежить поруч із bravo.exe — служба BRAVO пише його в
    # системний каталог Windows. Джерело істини (підтверджено на реальних
    # інсталяціях): %SystemRoot%\SysWOW64\bravo.ini на 64-бітній Windows,
    # %SystemRoot%\System32\bravo.ini на 32-бітній.
    #
    # Причина розбіжності — WOW64 File System Redirector: BRAVO 32-бітний
    # процес, і коли він звертається до "System32", 64-бітна Windows
    # прозоро для нього перенаправляє звернення в SysWOW64. Якщо PowerShell
    # тут запущено як 64-бітний процес (типово для запланованих завдань),
    # він бачить СПРАВЖНІй System32 без редиректу — і bravo.ini там просто
    # немає, бо служба писала його в SysWOW64. На 32-бітній Windows шару
    # редиректора не існує взагалі, тому System32 — це вже правильний шлях.
    #
    # -Is64BitOperatingSystem/-SystemRoot дозволяють self-test підставити
    # синтетичне значення замість [Environment]::Is64BitOperatingSystem/
    # $env:SystemRoot — той самий injectable-патерн, що й -Services.
    [CmdletBinding()]
    param(
        [string]$SystemRoot,
        [Nullable[bool]]$Is64BitOperatingSystem
    )

    $resolvedSystemRoot = if (-not [string]::IsNullOrWhiteSpace($SystemRoot)) {
        $SystemRoot
    } else {
        $env:SystemRoot
    }
    if ([string]::IsNullOrWhiteSpace($resolvedSystemRoot)) {
        return $null
    }
    $resolvedIs64Bit = if ($null -ne $Is64BitOperatingSystem) {
        [bool]$Is64BitOperatingSystem
    } else {
        [Environment]::Is64BitOperatingSystem
    }
    $systemSubDirectory = if ($resolvedIs64Bit) { 'SysWOW64' } else { 'System32' }
    return Join-Path $resolvedSystemRoot "$systemSubDirectory\bravo.ini"
}

function Resolve-BRAVOInstallationDiscovery {
    # Пріоритетний ланцюг (аудит/ТЗ CLAUDE_CODE_TZ_ARCHIV_LIMS_MONOLITH.md):
    # 1. CLI-параметри runtime-скриптів — не реалізовано в цій ітерації.
    # 2. Явний override у BRAVO.config (-DiscoverySettings) — виграє й
    #    ніколи не замінюється автоматично знайденим значенням.
    # 3. Активний bravo.ini, знайдений через встановлену службу BRAVO.
    # 4. Похідні значення (MODEL_SOURCE/BLOG_SOURCE/BRAVOEXCH_SOURCE/
    #    BAZA_APP/WEB_ROOT/BAZA_WWW) з даних bravo.ini й Apache-служби.
    # 5. Legacy fallback — чинна до цієї зміни поведінка
    #    (LIMSRoot-відносні шляхи), якщо служба/bravo.ini недоступні.
    # 6. Керована помилка — тут НЕ кидається; повертається DiscoveryResult
    #    із Reasons, що пояснюють кожне поле, а остаточне рішення "це
    #    помилка чи ні" ухвалює Test-BRAVODiscoveryResult (validation),
    #    щоб точки виклику самі вирішували критичність.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LimsRoot,
        [hashtable]$DiscoverySettings,
        [string]$BravoServiceName = "BRAVO",
        # Джерело істини для ідентифікації служби BRAVO — Service name
        # ТА Display name одночасно, а не будь-яке з них окремо: сторонній
        # сервіс із випадково схожим ім'ям не повинен пройти як BRAVO.
        [string]$BravoDisplayName = "BRAVO Service",
        [string[]]$WebServiceCandidates = @(),
        [string]$ExchangeApiServiceName,
        [object[]]$Services,
        [string]$SystemRoot,
        [Nullable[bool]]$Is64BitOperatingSystem
    )

    $reasons = @{}
    $overrides = @{}

    $normalizedDiscoverySettings = if ($null -ne $DiscoverySettings) {
        $DiscoverySettings
    } else {
        @{}
    }
    $sourceOverrides = if ($normalizedDiscoverySettings.Contains("Sources") -and
        $normalizedDiscoverySettings.Sources -is [System.Collections.IDictionary]) {
        $normalizedDiscoverySettings.Sources
    } else {
        @{}
    }

    # --- BRAVO_ROOT і bravo.ini ---
    $bravoIniPathOverride = if ($normalizedDiscoverySettings.Contains("BravoIniPath")) {
        [string]$normalizedDiscoverySettings.BravoIniPath
    } else {
        $null
    }
    $bravoRootOverride = if ($normalizedDiscoverySettings.Contains("BravoRoot")) {
        [string]$normalizedDiscoverySettings.BravoRoot
    } else {
        $null
    }

    # Пошук веде за обома іменами (ширша сітка — Name АБО DisplayName
    # дорівнює будь-якому кандидату), але службою BRAVO визнається лише
    # та, що пройшла СТРОГУ перевірку нижче: Name -eq BravoServiceName
    # І DisplayName -eq BravoDisplayName одночасно. Джерело істини.
    $bravoServiceSearchCandidates = @(
        $BravoServiceName, $BravoDisplayName
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $bravoServicesFound = Find-BRAVOServiceByCandidates `
        -ServiceCandidates $bravoServiceSearchCandidates `
        -Services $Services
    $bravoServices = @($bravoServicesFound | Where-Object {
        $_.Name -ieq $BravoServiceName -and $_.DisplayName -ieq $BravoDisplayName
    })
    $bravoServiceMatch = $bravoServices | Select-Object -First 1
    # AUD-007 (аудит P1.1): кілька служб BRAVO з РІЗНИМИ виконуваними
    # файлами — ознака stale/дублюючої інсталяції. Обираємо перший
    # (running-first), як і раніше, але позначаємо неоднозначність, щоб
    # Test-BRAVODiscoveryResult міг її заблокувати для enabled-компонентів.
    $distinctBravoExecutables = @(
        $bravoServices |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) } |
            Select-Object -ExpandProperty ExecutablePath -Unique
    )
    $bravoRootAmbiguous = $distinctBravoExecutables.Count -gt 1
    $bravoRoot = $null
    $bravoRootReason = $null
    if (-not [string]::IsNullOrWhiteSpace($bravoRootOverride)) {
        $bravoRoot = $bravoRootOverride
        $overrides["BravoRoot"] = $true
        $bravoRootReason = "явний override discoverySettings.BravoRoot"
    } elseif ($null -ne $bravoServiceMatch -and
        -not [string]::IsNullOrWhiteSpace($bravoServiceMatch.ExecutablePath)) {
        $bravoRoot = Split-Path -Path $bravoServiceMatch.ExecutablePath -Parent
        $bravoRootReason = "служба '$($bravoServiceMatch.Name)' -> $($bravoServiceMatch.ExecutablePath)"
        if ($bravoRootAmbiguous) {
            $bravoRootReason += " [УВАГА: знайдено кілька служб BRAVO з різними виконуваними файлами, обрано першу]"
        }
    } else {
        $bravoRoot = $LimsRoot
        $bravoRootReason = "legacy fallback: LIMSRoot (службу BRAVO не знайдено)"
    }
    $reasons["BravoRoot"] = $bravoRootReason

    # Джерело істини — системний каталог Windows (Get-BRAVOSystemBravoIniPath),
    # НЕ каталог встановлення bravo.exe: bravo.ini туди не пишеться.
    # Шлях поруч із bravo.exe лишається лише вторинним fallback — на
    # випадок нетипової інсталяції, де файл справді лежить там.
    $systemBravoIniPath = Get-BRAVOSystemBravoIniPath -SystemRoot $SystemRoot -Is64BitOperatingSystem $Is64BitOperatingSystem
    $bravoIniPath = $null
    $bravoIniReason = $null
    if (-not [string]::IsNullOrWhiteSpace($bravoIniPathOverride)) {
        $bravoIniPath = $bravoIniPathOverride
        $overrides["BravoIniPath"] = $true
        $bravoIniReason = "явний override discoverySettings.BravoIniPath"
    } elseif (-not [string]::IsNullOrWhiteSpace($systemBravoIniPath) -and
        (Test-Path -LiteralPath $systemBravoIniPath -PathType Leaf)) {
        $bravoIniPath = $systemBravoIniPath
        $bravoIniReason = "знайдено в системному каталозі Windows: $systemBravoIniPath"
    } elseif (-not [string]::IsNullOrWhiteSpace($bravoRoot)) {
        $candidateIniPath = Join-Path $bravoRoot "bravo.ini"
        if (Test-Path -LiteralPath $candidateIniPath -PathType Leaf) {
            $bravoIniPath = $candidateIniPath
            $bravoIniReason = "не знайдено в системному каталозі ($systemBravoIniPath); знайдено поруч з bravo.exe: $candidateIniPath"
        } else {
            $bravoIniReason = "bravo.ini не знайдено ні в системному каталозі ($systemBravoIniPath), ні поруч з bravo.exe ($candidateIniPath)"
        }
    } else {
        $bravoIniReason = "bravo.ini не знайдено в системному каталозі ($systemBravoIniPath), а BRAVO_ROOT невідомий"
    }
    $reasons["BravoIniPath"] = $bravoIniReason

    $iniData = if (-not [string]::IsNullOrWhiteSpace($bravoIniPath)) {
        ConvertFrom-BRAVOIniFile -Path $bravoIniPath
    } else {
        $null
    }

    # --- MODEL/BLOG/BRAVOEXCH з bravo.ini, з override ---
    function Resolve-BRAVOSourceField {
        param(
            [string]$FieldName,
            [string]$IniSection,
            [string]$IniKey,
            [scriptblock]$DeriveFromIniValue,
            [string]$LegacyFallbackPath
        )

        if ($sourceOverrides.Contains($FieldName) -and
            -not [string]::IsNullOrWhiteSpace([string]$sourceOverrides[$FieldName])) {
            $overrides[$FieldName] = $true
            return [pscustomobject]@{
                Value = [string]$sourceOverrides[$FieldName]
                Reason = "явний override discoverySettings.Sources.$FieldName"
            }
        }
        $iniValue = Get-BRAVOIniValue -IniData $iniData -Section $IniSection -Key $IniKey
        if (-not [string]::IsNullOrWhiteSpace($iniValue)) {
            $derived = if ($null -ne $DeriveFromIniValue) {
                & $DeriveFromIniValue $iniValue
            } else {
                $iniValue
            }
            return [pscustomobject]@{
                Value = $derived
                Reason = "bravo.ini [$IniSection] $IniKey=$iniValue"
            }
        }
        return [pscustomobject]@{
            Value = $LegacyFallbackPath
            Reason = "legacy fallback: LIMSRoot-відносний шлях (bravo.ini недоступний або без $IniKey)"
        }
    }

    $modelResolved = Resolve-BRAVOSourceField `
        -FieldName "MODEL" -IniSection "model" -IniKey "MODEL" `
        -DeriveFromIniValue { param($v) (Split-Path -Path $v -Parent) } `
        -LegacyFallbackPath (Join-Path $LimsRoot "Model")
    $blogResolved = Resolve-BRAVOSourceField `
        -FieldName "BLOG" -IniSection "model" -IniKey "BLOG" `
        -DeriveFromIniValue { param($v) ($v.TrimEnd("\", "/")) } `
        -LegacyFallbackPath (Join-Path $LimsRoot "BLOG")
    $bravoexchResolved = Resolve-BRAVOSourceField `
        -FieldName "BRAVOEXCH" -IniSection "model" -IniKey "BEXCH" `
        -DeriveFromIniValue { param($v) ($v.TrimEnd("\", "/")) } `
        -LegacyFallbackPath $null

    $modelProjectFile = Get-BRAVOIniValue -IniData $iniData -Section "model" -Key "MODEL"

    # --- BAZA_APP ---
    # BAZA не має власного ключа в bravo.ini. Коли MODEL/BLOG вже взято з
    # bravo.ini (реальна інсталяція), BAZA_APP надійніше вивести як
    # сусідній каталог у тому самому корені LIMS-інсталяції, ніж через
    # BRAVO_ROOT: останній залежить від того, чи знайдено саму
    # Windows-службу BRAVO, а MODEL/BLOG з bravo.ini — ні. Реальний
    # випадок: службу BRAVO не встановлено (лише bravo.ini на диску),
    # BRAVO_ROOT деградує до LIMSRoot — без цього кроку BAZA_APP шукався
    # б поруч із LIMSRoot, а не поруч із реальним MODEL/BLOG.
    $iniInstallationRoot = if ($modelResolved.Reason -like "bravo.ini *") {
        Split-Path -Path $modelResolved.Value -Parent
    } elseif ($blogResolved.Reason -like "bravo.ini *") {
        Split-Path -Path $blogResolved.Value -Parent
    } else {
        $null
    }
    $bazaAppOverrideValue = if ($sourceOverrides.Contains("BAZA_APP") -and
        -not [string]::IsNullOrWhiteSpace([string]$sourceOverrides["BAZA_APP"])) {
        [string]$sourceOverrides["BAZA_APP"]
    } else {
        $null
    }
    $bazaAppResolved = if (-not [string]::IsNullOrWhiteSpace($bazaAppOverrideValue)) {
        $overrides["BAZA_APP"] = $true
        [pscustomobject]@{
            Value = $bazaAppOverrideValue
            Reason = "явний override discoverySettings.Sources.BAZA_APP"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($iniInstallationRoot)) {
        [pscustomobject]@{
            Value = Join-Path $iniInstallationRoot "BAZA"
            Reason = "поруч із MODEL/BLOG з bravo.ini: $iniInstallationRoot"
        }
    } else {
        [pscustomobject]@{
            Value = if (-not [string]::IsNullOrWhiteSpace($bravoRoot)) {
                Join-Path $bravoRoot "BAZA"
            } else {
                $null
            }
            Reason = "legacy fallback: BRAVO_ROOT-відносний шлях (bravo.ini недоступний)"
        }
    }

    # --- BACKUP_ROOT: каталог збереження бекапів ---
    # Джерело істини: каталог "ARCHIV" усередині шляху встановлення служби
    # BRAVO (той самий каталог, де лежить bravo.exe) — але ЛИШЕ коли
    # службу дійсно знайдено. Якщо ні — $bravoRoot тут це вже не каталог
    # BRAVO, а LIMSRoot (legacy fallback, рядок вище): "LIMSRoot\ARCHIV"
    # для BACKUP_ROOT — це не легша, а ГІРША здогадка за той дефолт, який
    # BRAVO.config уже має сам (pathSettings.ArchiveRoot — каталог
    # скрипта). Тому в цьому випадку BACKUP_ROOT лишається $null: нехай
    # переможе дефолт BRAVO.config, а не другий здогад поверх першого.
    $backupRootResolved = Resolve-BRAVOSourceField `
        -FieldName "BACKUP_ROOT" -IniSection "__none__" -IniKey "__none__" `
        -DeriveFromIniValue $null `
        -LegacyFallbackPath $(
            if (-not [string]::IsNullOrWhiteSpace($bravoRoot) -and
                $bravoRootReason -notmatch '^legacy fallback') {
                Join-Path $bravoRoot "ARCHIV"
            } else {
                $null
            }
        )

    # --- WEB_ROOT / BAZA_WWW через Apache-службу ---
    $webRootOverride = if ($normalizedDiscoverySettings.Contains("WebRoot")) {
        [string]$normalizedDiscoverySettings.WebRoot
    } else {
        $null
    }
    $webServices = if (@($WebServiceCandidates).Count -gt 0) {
        Find-BRAVOServiceByCandidates `
            -ServiceCandidates $WebServiceCandidates `
            -ExecutableNameFallback "httpd.exe" `
            -Services $Services
    } else {
        @()
    }
    $webServiceMatch = $webServices | Select-Object -First 1
    $distinctWebExecutables = @(
        $webServices |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) } |
            Select-Object -ExpandProperty ExecutablePath -Unique
    )
    $webRootAmbiguous = $distinctWebExecutables.Count -gt 1
    $webRoot = $null
    $webRootReason = $null
    if (-not [string]::IsNullOrWhiteSpace($webRootOverride)) {
        $webRoot = $webRootOverride
        $overrides["WebRoot"] = $true
        $webRootReason = "явний override discoverySettings.WebRoot"
    } elseif ($null -ne $webServiceMatch -and
        -not [string]::IsNullOrWhiteSpace($webServiceMatch.ExecutablePath) -and
        [System.IO.Path]::GetFileName($webServiceMatch.ExecutablePath) -ieq "httpd.exe") {
        # <WEB_ROOT>\apache\bin\httpd.exe -> bin -> apache -> WEB_ROOT.
        $binDir = Split-Path -Path $webServiceMatch.ExecutablePath -Parent
        $apacheDir = Split-Path -Path $binDir -Parent
        $webRoot = Split-Path -Path $apacheDir -Parent
        $webRootReason = "служба '$($webServiceMatch.Name)' -> $($webServiceMatch.ExecutablePath)"
        if ($webRootAmbiguous) {
            $webRootReason += " [УВАГА: знайдено кілька Apache-подібних служб з різними виконуваними файлами, обрано першу]"
        }
    } else {
        $webRootReason = "Apache-службу не знайдено; BAZA_WWW недоступний"
    }
    $reasons["WebRoot"] = $webRootReason

    $bazaWwwResolved = Resolve-BRAVOSourceField `
        -FieldName "BAZA_WWW" -IniSection "__none__" -IniKey "__none__" `
        -DeriveFromIniValue $null `
        -LegacyFallbackPath $(
            if (-not [string]::IsNullOrWhiteSpace($webRoot)) {
                Join-Path $webRoot "www\BAZA"
            } else {
                $null
            }
        )
    if ([string]::IsNullOrWhiteSpace($bazaWwwResolved.Value) -and
        -not $overrides.Contains("BAZA_WWW")) {
        $bazaWwwResolved.Reason = $webRootReason
    }

    # --- ExchangeAPI: лише ідентифікація служби, шлях завжди з bravo.ini ---
    $exchangeApiServices = if (-not [string]::IsNullOrWhiteSpace($ExchangeApiServiceName)) {
        Find-BRAVOServiceByCandidates `
            -ServiceCandidates @($ExchangeApiServiceName) `
            -Services $Services
    } else {
        @()
    }

    $allServices = @($bravoServices) + @($webServices) + @($exchangeApiServices)

    return [pscustomobject]@{
        BRAVO_ROOT = $bravoRoot
        WEB_ROOT = $webRoot
        BravoIniPath = $bravoIniPath
        MODEL_PROJECT_FILE = $modelProjectFile
        MODEL_SOURCE = $modelResolved.Value
        BLOG_SOURCE = $blogResolved.Value
        BRAVOEXCH_SOURCE = $bravoexchResolved.Value
        BAZA_APP = $bazaAppResolved.Value
        BAZA_WWW = $bazaWwwResolved.Value
        BACKUP_ROOT = $backupRootResolved.Value
        Services = $allServices
        Overrides = $overrides
        Ambiguous = @{
            BravoRoot = $bravoRootAmbiguous
            WebRoot = $webRootAmbiguous
        }
        Reasons = @{
            BravoRoot = $reasons["BravoRoot"]
            WebRoot = $reasons["WebRoot"]
            BravoIniPath = $reasons["BravoIniPath"]
            MODEL = $modelResolved.Reason
            BLOG = $blogResolved.Reason
            BRAVOEXCH = $bravoexchResolved.Reason
            BAZA_APP = $bazaAppResolved.Reason
            BAZA_WWW = $bazaWwwResolved.Reason
            BACKUP_ROOT = $backupRootResolved.Reason
        }
    }
}

function Test-BRAVODiscoveryResult {
    # Validation за ТЗ: існування enabled source, існування/створюваність
    # destination, destination != source, destination не вкладений у
    # source, наявність bravo.ini якщо він потрібен (тобто жоден
    # Sources.*-override не заданий), непорожність значень з bravo.ini.
    # Повертає масив рядків-помилок (порожній масив == валідно); виклик,
    # що це критично (код 30), лишається за BRAVO.config.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DiscoveryResult,
        [hashtable]$EnabledComponents = @{},
        [hashtable]$DestinationPaths = @{}
    )

    $errors = New-Object System.Collections.Generic.List[string]

    # AUD-007 (аудит P1.1): неоднозначний BRAVO_ROOT/WEB_ROOT (кілька служб
    # із різними виконуваними файлами) не має мовчки давати "успішний"
    # backup не того джерела — блокуємо лише для реально увімкнених
    # компонентів, які від цього кореня залежать.
    if ($DiscoveryResult.PSObject.Properties['Ambiguous'] -and
        $DiscoveryResult.Ambiguous -is [System.Collections.IDictionary]) {
        $bravoRootDependents = @('MODEL', 'BLOG', 'BRAVOEXCH', 'BAZA_APP') |
            Where-Object { $EnabledComponents.Contains($_) -and [bool]$EnabledComponents[$_] }
        if ([bool]$DiscoveryResult.Ambiguous['BravoRoot'] -and @($bravoRootDependents).Count -gt 0) {
            $errors.Add("Знайдено кілька служб BRAVO з різними виконуваними файлами — BRAVO_ROOT неоднозначний (впливає на: $($bravoRootDependents -join ', ')). Задайте discoverySettings.BravoRoot вручну або приберіть зайву службу.")
        }
        if ([bool]$DiscoveryResult.Ambiguous['WebRoot'] -and
            $EnabledComponents.Contains('BAZA_WWW') -and [bool]$EnabledComponents['BAZA_WWW']) {
            $errors.Add("Знайдено кілька Apache-подібних служб з різними виконуваними файлами — WEB_ROOT неоднозначний (впливає на: BAZA_WWW). Задайте discoverySettings.WebRoot вручну або приберіть зайву службу.")
        }
    }

    $sourceFieldsByComponent = @{
        MODEL = "MODEL_SOURCE"
        BLOG = "BLOG_SOURCE"
        BRAVOEXCH = "BRAVOEXCH_SOURCE"
        BAZA_APP = "BAZA_APP"
        BAZA_WWW = "BAZA_WWW"
    }

    foreach ($componentName in $sourceFieldsByComponent.Keys) {
        if (-not $EnabledComponents.Contains($componentName) -or
            -not [bool]$EnabledComponents[$componentName]) {
            continue
        }
        $sourceFieldName = $sourceFieldsByComponent[$componentName]
        $sourceValue = $DiscoveryResult.$sourceFieldName
        if ([string]::IsNullOrWhiteSpace([string]$sourceValue)) {
            $errors.Add("Джерело '$componentName' увімкнено, але шлях не визначено (жодне джерело: override/bravo.ini/legacy fallback не дало значення).")
            continue
        }
        $sourceForTest = ([string]$sourceValue).TrimEnd("*", "\")
        if (-not (Test-Path -LiteralPath $sourceForTest)) {
            $errors.Add("Джерело '$componentName' увімкнено, але шлях не існує: $sourceValue")
        }
    }

    foreach ($componentName in $DestinationPaths.Keys) {
        $destinationValue = [string]$DestinationPaths[$componentName]
        if ([string]::IsNullOrWhiteSpace($destinationValue)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $destinationValue -PathType Container)) {
            try {
                [void](New-Item -ItemType Directory -Path $destinationValue -Force -ErrorAction Stop)
            } catch {
                $errors.Add("Каталог призначення '$componentName' не існує і не вдалося створити: $destinationValue ($($_.Exception.Message))")
                continue
            }
        }
        if ($sourceFieldsByComponent.Contains($componentName)) {
            $sourceFieldName = $sourceFieldsByComponent[$componentName]
            $sourceValue = ([string]$DiscoveryResult.$sourceFieldName).TrimEnd("*", "\")
            if (-not [string]::IsNullOrWhiteSpace($sourceValue)) {
                $normalizedSource = $sourceValue.TrimEnd("\").ToLowerInvariant()
                $normalizedDestination = $destinationValue.TrimEnd("\").ToLowerInvariant()
                if ($normalizedSource -eq $normalizedDestination) {
                    $errors.Add("Каталог призначення '$componentName' збігається з джерелом: $destinationValue")
                } elseif ($normalizedDestination.StartsWith($normalizedSource + "\")) {
                    $errors.Add("Каталог призначення '$componentName' вкладений у джерело: $destinationValue всередині $sourceValue")
                }
            }
        }
    }

    # Звичайний масив, БЕЗ унарної коми і БЕЗ -NoEnumerate: обидва
    # трюки ламають один із двох стилів виклику (пряме присвоєння vs
    # виклик, обгорнутий у @(...) на боці клієнта). Контракт цієї функції
    # — виклик ЗАВЖДИ обгортається @(...) на боці клієнта (як і
    # BRAVO_SETUP.ps1 та BRAVO_SELF_TEST.ps1 уже роблять); це коректно
    # відновлює масив для 0, 1 і N елементів під Set-StrictMode -Version 2.0
    # на Windows PowerShell 5.1.
    return $errors.ToArray()
}

$script:BRAVODiscoveryBaselineFields = @(
    'BRAVO_ROOT', 'WEB_ROOT', 'MODEL_SOURCE', 'BLOG_SOURCE',
    'BRAVOEXCH_SOURCE', 'BAZA_APP', 'BAZA_WWW', 'BACKUP_ROOT'
)

function Save-BRAVODiscoveryBaseline {
    # AUD-007 (аудит P1.1/P1.2): зберігає останній підтверджений discovery-
    # результат на диск (JSON, без BOM — узгоджено з VERSION.json), щоб
    # Compare-BRAVODiscoveryBaseline міг виявити дрейф джерел між запусками.
    # Явне збереження (не автоматичне при кожному запуску) — за задумом:
    # baseline підтверджує адміністратор через BRAVO_SETUP.ps1
    # -ConfirmDiscoveryBaseline, після ручної перевірки виводу DISCOVERY.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DiscoveryResult,
        [Parameter(Mandatory = $true)][string]$BaselinePath
    )

    $snapshot = [ordered]@{ SavedAt = (Get-Date).ToString("o") }
    foreach ($fieldName in $script:BRAVODiscoveryBaselineFields) {
        $snapshot[$fieldName] = [string]$DiscoveryResult.$fieldName
    }

    $parentDir = Split-Path -Path $BaselinePath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and
        -not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parentDir -Force)
    }

    $json = [pscustomobject]$snapshot | ConvertTo-Json
    [IO.File]::WriteAllText($BaselinePath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Compare-BRAVODiscoveryBaseline {
    # Повертає масив рядків-попереджень про дрейф джерел відносно
    # останнього збереженого baseline (порожній масив == дрейфу немає або
    # baseline ще не існує — перший запуск не є дрейфом). -Baseline
    # дозволяє self-test підставити синтетичний baseline без файлу на
    # диску (той самий injectable-патерн, що й -Services).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DiscoveryResult,
        [string]$BaselinePath,
        [object]$Baseline
    )

    if ($null -eq $Baseline) {
        if ([string]::IsNullOrWhiteSpace($BaselinePath) -or
            -not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
            return @()
        }
        try {
            $rawBaseline = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8
            $Baseline = $rawBaseline | ConvertFrom-Json
        } catch {
            return @("Не вдалося прочитати збережений discovery baseline '$BaselinePath': $($_.Exception.Message)")
        }
    }

    $drift = New-Object System.Collections.Generic.List[string]
    foreach ($fieldName in $script:BRAVODiscoveryBaselineFields) {
        $baselineValue = if ($Baseline.PSObject.Properties[$fieldName]) {
            [string]$Baseline.$fieldName
        } else {
            $null
        }
        if ([string]::IsNullOrWhiteSpace($baselineValue)) {
            continue
        }
        $currentValue = [string]$DiscoveryResult.$fieldName
        if ([string]::IsNullOrWhiteSpace($currentValue)) {
            $drift.Add("Discovery drift: '$fieldName' раніше було '$baselineValue', зараз не визначено.")
        } elseif (-not [string]::Equals($baselineValue, $currentValue, [StringComparison]::OrdinalIgnoreCase)) {
            $drift.Add("Discovery drift: '$fieldName' змінився з '$baselineValue' на '$currentValue' відносно збереженого baseline.")
        }
    }

    return $drift.ToArray()
}

Export-ModuleMember -Function @(
    'Get-BRAVOServiceExecutablePath',
    'Find-BRAVOServiceByCandidates',
    'ConvertFrom-BRAVOIniFile',
    'Get-BRAVOSystemBravoIniPath',
    'Resolve-BRAVOInstallationDiscovery',
    'Test-BRAVODiscoveryResult',
    'Save-BRAVODiscoveryBaseline',
    'Compare-BRAVODiscoveryBaseline'
)
