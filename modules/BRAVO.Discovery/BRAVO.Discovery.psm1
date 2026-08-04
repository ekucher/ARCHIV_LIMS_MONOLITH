# Автоматичний Discovery джерел BRAVO: визначення BRAVO_ROOT/WEB_ROOT і
# джерел MODEL/BLOG/BRAVOEXCH/BAZA_APP/BAZA_WWW за встановленими Windows-
# службами та активним bravo.ini, з повним ручним перевизначенням через
# BRAVO.config.
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
        [string[]]$WebServiceCandidates = @(),
        [string]$ExchangeApiServiceName,
        [object[]]$Services
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

    $bravoServices = Find-BRAVOServiceByCandidates `
        -ServiceCandidates @($BravoServiceName) `
        -Services $Services
    $bravoServiceMatch = $bravoServices | Select-Object -First 1
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
    } else {
        $bravoRoot = $LimsRoot
        $bravoRootReason = "legacy fallback: LIMSRoot (службу BRAVO не знайдено)"
    }
    $reasons["BravoRoot"] = $bravoRootReason

    $bravoIniPath = $null
    $bravoIniReason = $null
    if (-not [string]::IsNullOrWhiteSpace($bravoIniPathOverride)) {
        $bravoIniPath = $bravoIniPathOverride
        $overrides["BravoIniPath"] = $true
        $bravoIniReason = "явний override discoverySettings.BravoIniPath"
    } elseif (-not [string]::IsNullOrWhiteSpace($bravoRoot)) {
        $candidateIniPath = Join-Path $bravoRoot "bravo.ini"
        if (Test-Path -LiteralPath $candidateIniPath -PathType Leaf) {
            $bravoIniPath = $candidateIniPath
            $bravoIniReason = "знайдено поруч з bravo.exe: $candidateIniPath"
        } else {
            $bravoIniReason = "bravo.ini не знайдено за шляхом $candidateIniPath"
        }
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
    $bazaAppResolved = Resolve-BRAVOSourceField `
        -FieldName "BAZA_APP" -IniSection "__none__" -IniKey "__none__" `
        -DeriveFromIniValue $null `
        -LegacyFallbackPath (Join-Path $bravoRoot "BAZA")

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
        Services = $allServices
        Overrides = $overrides
        Reasons = @{
            BravoRoot = $reasons["BravoRoot"]
            WebRoot = $reasons["WebRoot"]
            BravoIniPath = $reasons["BravoIniPath"]
            MODEL = $modelResolved.Reason
            BLOG = $blogResolved.Reason
            BRAVOEXCH = $bravoexchResolved.Reason
            BAZA_APP = $bazaAppResolved.Reason
            BAZA_WWW = $bazaWwwResolved.Reason
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

    # ",": без унарної коми масив з 1 елементом розгортається пайплайном у
    # скаляр при виклику через просте присвоєння — і .Count падає під
    # Set-StrictMode -Version 2.0 на Windows PowerShell 5.1 (немає .Count
    # на String до PS 7). Кома гарантує, що завжди повертається масив.
    return ,@($errors.ToArray())
}

Export-ModuleMember -Function @(
    'Get-BRAVOServiceExecutablePath',
    'Find-BRAVOServiceByCandidates',
    'ConvertFrom-BRAVOIniFile',
    'Resolve-BRAVOInstallationDiscovery',
    'Test-BRAVODiscoveryResult'
)
