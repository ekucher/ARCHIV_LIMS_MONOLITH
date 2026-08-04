# Спільний шар сумісності BRAVO для Windows 7 і новіших ОС.
# Мінімальна підтримувана версія: Windows PowerShell 3.0.
# Функції спочатку використовують сучасний командлет, а якщо його немає
# або він недоступний на поточній ОС — сумісний API .NET/WMI/COM.

function Assert-BRAVOPowerShellCompatibility {
    param([int]$MinimumMajorVersion = 3)

    $currentMajor = [int]$PSVersionTable.PSVersion.Major
    if ($currentMajor -lt $MinimumMajorVersion) {
        $compatibilityError = (
            "BRAVO потребує Windows PowerShell {0}.0 або новішої версії. " +
            "Поточна версія: {1}. Для Windows 7 встановіть Windows Management Framework 3.0+ " +
            "(рекомендовано WMF 5.1)."
        ) -f $MinimumMajorVersion, $PSVersionTable.PSVersion
        throw $compatibilityError
    }
}

function Initialize-BRAVOConsoleEncoding {
    [CmdletBinding()]
    param([int]$CodePage = 65001)

    try {
        $consoleEncoding = if ($CodePage -eq 65001) {
            # Конструктор без BOM сумісний з Windows PowerShell 3.0.
            New-Object System.Text.UTF8Encoding($false)
        } else {
            [System.Text.Encoding]::GetEncoding($CodePage)
        }

        # $OutputEncoding використовується під час обміну з консольними
        # програмами, а Console.OutputEncoding узгоджує кодову сторінку
        # самого вікна консолі. Помилка в сеансі без консолі не є критичною.
        $global:OutputEncoding = $consoleEncoding
        try {
            [Console]::OutputEncoding = $consoleEncoding
        } catch {
            return $false
        }

        return $true
    } catch {
        return $false
    }
}

function Test-BRAVOCommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)

    # Діагностичний режим дає змогу перевірити fallback-гілки на новій ОС:
    # set BRAVO_FORCE_LEGACY_API=1
    if ($env:BRAVO_FORCE_LEGACY_API -eq "1" -and
        @(
            "Get-CimInstance",
            "Get-FileHash",
            "Test-NetConnection",
            "Get-ScheduledTask",
            "Register-ScheduledTask",
            "ConvertTo-Json",
            "ConvertFrom-Json",
            "Get-ChildItem"
        ) -contains $Name) {
        return $false
    }

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function ConvertTo-BRAVOAccountSidValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountName
    )

    $trimmedAccount = $AccountName.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedAccount)) {
        return $null
    }

    $canonicalAccount = $trimmedAccount.Replace(" ", "").ToUpperInvariant()
    switch ($canonicalAccount) {
        "SYSTEM" { return "S-1-5-18" }
        "NTAUTHORITY\SYSTEM" { return "S-1-5-18" }
        "LOCALSERVICE" { return "S-1-5-19" }
        "NTAUTHORITY\LOCALSERVICE" { return "S-1-5-19" }
        "NETWORKSERVICE" { return "S-1-5-20" }
        "NTAUTHORITY\NETWORKSERVICE" { return "S-1-5-20" }
    }

    if ($trimmedAccount -match "^(?i)S-\d+(?:-\d+)+$") {
        try {
            return (
                New-Object Security.Principal.SecurityIdentifier($trimmedAccount)
            ).Value
        } catch {
            return $null
        }
    }

    try {
        # Task Scheduler повертає локалізовані назви вбудованих облікових
        # записів (наприклад, "СИСТЕМА"). SID залишається мовно-незалежним.
        $ntAccount = New-Object Security.Principal.NTAccount($trimmedAccount)
        $sid = $ntAccount.Translate(
            [Security.Principal.SecurityIdentifier]
        )
        return [string]$sid.Value
    } catch {
        return $null
    }
}

function Test-BRAVOAccountIdentityEquivalent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedAccount,

        [Parameter(Mandatory = $true)]
        [string]$ActualAccount
    )

    $expectedSid = ConvertTo-BRAVOAccountSidValue -AccountName $ExpectedAccount
    $actualSid = ConvertTo-BRAVOAccountSidValue -AccountName $ActualAccount
    if (-not [string]::IsNullOrWhiteSpace($expectedSid) -and
        -not [string]::IsNullOrWhiteSpace($actualSid)) {
        return [string]::Equals(
            $expectedSid,
            $actualSid,
            [StringComparison]::OrdinalIgnoreCase
        )
    }

    $expectedName = $ExpectedAccount.Trim().Replace(
        "NT AUTHORITY\",
        ""
    )
    $actualName = $ActualAccount.Trim().Replace(
        "NT AUTHORITY\",
        ""
    )
    return [string]::Equals(
        $expectedName,
        $actualName,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-BRAVOCompatibilityInfo {
    $windowsVersion = [Environment]::OSVersion.Version
    $hasCim = Test-BRAVOCommandAvailable -Name "Get-CimInstance"
    $hasFileHash = Test-BRAVOCommandAvailable -Name "Get-FileHash"
    $hasTestNetConnection = Test-BRAVOCommandAvailable -Name "Test-NetConnection"
    $hasScheduledTasks = (
        (Test-BRAVOCommandAvailable -Name "Get-ScheduledTask") -and
        (Test-BRAVOCommandAvailable -Name "Register-ScheduledTask")
    )
    $getChildItemCommand = Get-Command -Name "Get-ChildItem" -ErrorAction SilentlyContinue
    $hasFileDirectorySwitches = (
        (Test-BRAVOCommandAvailable -Name "Get-ChildItem") -and
        $null -ne $getChildItemCommand -and
        $getChildItemCommand.Parameters.ContainsKey("File") -and
        $getChildItemCommand.Parameters.ContainsKey("Directory")
    )

    return New-Object PSObject -Property @{
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        WindowsVersion = $windowsVersion.ToString()
        WmiProvider = $(if ($hasCim) { "CIM" } else { "WMI" })
        FileHashProvider = $(if ($hasFileHash) { "Get-FileHash" } else { ".NET" })
        NetworkProvider = $(if ($hasTestNetConnection) { "Test-NetConnection" } else { "TcpClient" })
        ChildItemProvider = $(if ($hasFileDirectorySwitches) { "NativeFilter" } else { "PSIsContainer" })
        TaskSchedulerProvider = $(if ($hasScheduledTasks) { "ScheduledTasks/COM-fallback" } else { "COM" })
        JsonProvider = $(if (Test-BRAVOCommandAvailable -Name "ConvertTo-Json") { "PowerShell" } else { ".NET" })
        IsCompatibilityMode = -not (
            $hasCim -and
            $hasFileHash -and
            $hasTestNetConnection -and
            $hasFileDirectorySwitches
        )
    }
}

function Get-BRAVOPowerShellUpdateRecommendation {
    [CmdletBinding()]
    param(
        [version]$PowerShellVersion = $PSVersionTable.PSVersion,
        [object]$OperatingSystemInfo,
        [int]$DotNetRelease = -1
    )

    $targetVersion = [version]"5.1"
    if ($PowerShellVersion -ge $targetVersion) {
        return New-Object PSObject -Property @{
            IsUpdateRecommended = $false
            IsDirectUpdateSupported = $false
            CurrentVersion = $PowerShellVersion.ToString()
            TargetVersion = $targetVersion.ToString()
            OperatingSystem = [Environment]::OSVersion.VersionString
            Message = $null
        }
    }

    if ($null -eq $OperatingSystemInfo) {
        try {
            $OperatingSystemInfo = Get-BRAVOWmiInstance `
                -ClassName Win32_OperatingSystem |
                Select-Object -First 1
        } catch {
            $OperatingSystemInfo = $null
        }
    }

    $registryProductName = $null
    try {
        $registryProductName = [string](
            Get-ItemProperty `
                -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
                -Name "ProductName" `
                -ErrorAction Stop
        ).ProductName
    } catch {
        $registryProductName = $null
    }

    $osVersion = if ($null -ne $OperatingSystemInfo -and
        $null -ne $OperatingSystemInfo.Version) {
        [version]([string]$OperatingSystemInfo.Version)
    } else {
        [Environment]::OSVersion.Version
    }
    $osCaption = if ($null -ne $OperatingSystemInfo -and
        -not [string]::IsNullOrWhiteSpace([string]$OperatingSystemInfo.Caption)) {
        ([string]$OperatingSystemInfo.Caption).Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($registryProductName)) {
        $registryProductName.Trim()
    } else {
        [Environment]::OSVersion.VersionString
    }
    $servicePackMajor = if ($null -ne $OperatingSystemInfo -and
        $null -ne $OperatingSystemInfo.ServicePackMajorVersion) {
        [int]$OperatingSystemInfo.ServicePackMajorVersion
    } else {
        $environmentServicePack = [string][Environment]::OSVersion.ServicePack
        if ($environmentServicePack -match "(\d+)") {
            [int]$matches[1]
        } else {
            0
        }
    }
    $productType = if ($null -ne $OperatingSystemInfo -and
        $null -ne $OperatingSystemInfo.ProductType) {
        [int]$OperatingSystemInfo.ProductType
    } elseif ($osCaption -match "(?i)\bServer\b") {
        3
    } else {
        1
    }
    $isServer = $productType -ne 1
    $directUpdateSupported = $false
    $action = $null

    if ($DotNetRelease -lt 0) {
        try {
            $DotNetRelease = [int](
                Get-ItemProperty `
                    -LiteralPath "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" `
                    -Name "Release" `
                    -ErrorAction Stop
            ).Release
        } catch {
            $DotNetRelease = 0
        }
    }
    # Мінімальна версія для WMF 5.1 — .NET Framework 4.5.2.
    $hasRequiredDotNet = $DotNetRelease -ge 379893

    if ($osVersion.Major -eq 6 -and $osVersion.Minor -eq 1) {
        if ($servicePackMajor -ge 1) {
            $directUpdateSupported = $true
            $action = "можна встановити Windows Management Framework 5.1"
        } else {
            $action = "спочатку встановіть Service Pack 1, після цього Windows Management Framework 5.1"
        }
    } elseif ($osVersion.Major -eq 6 -and $osVersion.Minor -eq 2) {
        if ($isServer) {
            $directUpdateSupported = $true
            $action = "можна встановити Windows Management Framework 5.1"
        } else {
            $action = "для Windows 8 спочатку потрібне оновлення ОС до Windows 8.1 або новішої"
        }
    } elseif ($osVersion.Major -eq 6 -and $osVersion.Minor -eq 3) {
        $directUpdateSupported = $true
        $action = "можна встановити Windows Management Framework 5.1"
    } elseif ($osVersion.Major -ge 10) {
        $action = "PowerShell 5.1 є компонентом Windows; виконайте Windows Update або відновлення системних компонентів"
    } elseif ($osVersion.Major -gt 6 -or
        ($osVersion.Major -eq 6 -and $osVersion.Minor -gt 3)) {
        $action = "оновіть PowerShell засобами оновлення поточної версії Windows"
    } else {
        $action = "ця версія Windows не підтримує рекомендоване оновлення; спочатку оновіть ОС"
    }

    $wmf51OsFamily = (
        $osVersion.Major -eq 6 -and
        $osVersion.Minor -ge 1 -and
        $osVersion.Minor -le 3
    )
    if ($wmf51OsFamily -and -not $hasRequiredDotNet) {
        if ($directUpdateSupported) {
            $directUpdateSupported = $false
            $action = (
                "спочатку встановіть .NET Framework 4.5.2 або новіший, " +
                "після цього Windows Management Framework 5.1"
            )
        } elseif ($action -notmatch "\.NET Framework") {
            $action += "; перед встановленням WMF 5.1 також потрібен .NET Framework 4.5.2 або новіший"
        }
    }

    $availabilityText = if ($directUpdateSupported) {
        "Можливе пряме оновлення"
    } else {
        "Пряме оновлення зараз недоступне"
    }
    $message = (
        "{0}: поточна версія PowerShell {1}, рекомендована 5.1. " +
        "ОС: {2}. Дія: {3}. Пакет оновлення завантажуйте лише з офіційного " +
        "Microsoft Download Center або Microsoft Update Catalog; після встановлення перезавантажте ПК. " +
        "Скрипт продовжує роботу, автоматичне встановлення не виконується."
    ) -f $availabilityText, $PowerShellVersion, $osCaption, $action

    return New-Object PSObject -Property @{
        IsUpdateRecommended = $true
        IsDirectUpdateSupported = $directUpdateSupported
        CurrentVersion = $PowerShellVersion.ToString()
        TargetVersion = $targetVersion.ToString()
        OperatingSystem = $osCaption
        OperatingSystemVersion = $osVersion.ToString()
        ServicePackMajorVersion = $servicePackMajor
        DotNetRelease = $DotNetRelease
        HasRequiredDotNet = $hasRequiredDotNet
        IsServer = $isServer
        Message = $message
    }
}

function Get-BRAVOWindowsPatchLevelRecommendation {
    [CmdletBinding()]
    param(
        # Дозволяє підставити тестові дані замість реального Get-HotFix.
        [object[]]$InstalledHotfixes,

        [datetime]$Now = (Get-Date),

        # Скільки днів без оновлень вважати приводом для попередження.
        # Не привʼязано до конкретних KB чи дат випуску Microsoft, тому
        # перевірка лишається чинною без ручного супроводу цього коду.
        [ValidateRange(1, 3650)]
        [int]$StaleAfterDays = 120
    )

    $osVersion = [Environment]::OSVersion.Version
    $osCaption = $null
    $updateBuildRevision = $null
    try {
        $currentVersionKey = Get-ItemProperty `
            -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
            -ErrorAction Stop
        $osCaption = [string]$currentVersionKey.ProductName
        if ($null -ne $currentVersionKey.UBR) {
            $updateBuildRevision = [int]$currentVersionKey.UBR
        }
    } catch {
        $osCaption = [Environment]::OSVersion.VersionString
    }
    $buildDescription = if ($null -ne $updateBuildRevision) {
        "{0}.{1}" -f $osVersion.Build, $updateBuildRevision
    } else {
        [string]$osVersion.Build
    }

    if ($null -eq $InstalledHotfixes) {
        try {
            $InstalledHotfixes = @(Get-HotFix -ErrorAction Stop)
        } catch {
            $InstalledHotfixes = @()
        }
    }
    $lastInstalledOn = $InstalledHotfixes |
        Where-Object { $null -ne $_.InstalledOn } |
        Sort-Object -Property InstalledOn -Descending |
        Select-Object -First 1 -ExpandProperty InstalledOn

    if ($null -eq $lastInstalledOn) {
        return New-Object PSObject -Property @{
            IsUpdateRecommended = $true
            LastInstalledOn = $null
            DaysSinceLastUpdate = $null
            OperatingSystem = $osCaption
            Build = $buildDescription
            Message = (
                "Не вдалося визначити дату останнього оновлення Windows на цьому " +
                "комп'ютері (ОС: $osCaption, білд $buildDescription). Перевірте " +
                "історію оновлень вручну через Windows Update і встановіть " +
                "найновіші оновлення, якщо давно цього не робили. Пакети " +
                "завантажуйте лише з офіційного Microsoft Update Catalog " +
                "(catalog.update.microsoft.com). Скрипт продовжує роботу, " +
                "автоматичне встановлення не виконується."
            )
        }
    }

    $daysSinceLastUpdate = [int]($Now - $lastInstalledOn).TotalDays
    $isStale = $daysSinceLastUpdate -gt $StaleAfterDays

    $message = if ($isStale) {
        (
            "Останнє оновлення Windows встановлено {0:yyyy-MM-dd} ({1} дн. тому) " +
            "на комп'ютері з ОС {2}, білд {3}. Застарілі накопичувальні оновлення " +
            "підвищують ризик відомих і вже виправлених дефектів .NET/CLR " +
            "(включно з аварійним завершенням powershell.exe під час рекурсивного " +
            "обходу каталогів). Рекомендовано встановити найновіше кумулятивне " +
            "оновлення через Windows Update або Microsoft Update Catalog " +
            "(catalog.update.microsoft.com), після цього перезавантажити " +
            "комп'ютер. Скрипт продовжує роботу, автоматичне встановлення не виконується."
        ) -f $lastInstalledOn, $daysSinceLastUpdate, $osCaption, $buildDescription
    } else {
        $null
    }

    return New-Object PSObject -Property @{
        IsUpdateRecommended = $isStale
        LastInstalledOn = $lastInstalledOn
        DaysSinceLastUpdate = $daysSinceLastUpdate
        OperatingSystem = $osCaption
        Build = $buildDescription
        Message = $message
    }
}

function Get-BRAVOWmiInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Namespace = "root\cimv2",
        [string]$Filter
    )

    if (Test-BRAVOCommandAvailable -Name "Get-CimInstance") {
        $parameters = @{
            ClassName = $ClassName
            Namespace = $Namespace
            ErrorAction = "Stop"
        }
        if (-not [string]::IsNullOrWhiteSpace($Filter)) {
            $parameters.Filter = $Filter
        }
        try {
            return @(Get-CimInstance @parameters)
        } catch {
            # Старі CIM/WinRM-конфігурації іноді присутні, але не працюють.
            # У такому разі повторюємо запит через DCOM/WMI.
        }
    }

    $wmiParameters = @{
        Class = $ClassName
        Namespace = $Namespace
        ErrorAction = "Stop"
    }
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $wmiParameters.Filter = $Filter
    }
    return @(Get-WmiObject @wmiParameters)
}

function Get-BRAVOFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = "Path")][string]$Path,
        [Parameter(Mandatory = $true, ParameterSetName = "LiteralPath")][string]$LiteralPath,
        [string]$Filter = "*",
        [switch]$Recurse,
        [switch]$Force
    )

    $parameters = @{
        Filter = $Filter
        ErrorAction = "SilentlyContinue"
    }
    if ($PSCmdlet.ParameterSetName -eq "LiteralPath") {
        $parameters.LiteralPath = $LiteralPath
    } else {
        $parameters.Path = $Path
    }
    if ($Recurse) {
        $parameters.Recurse = $true
    }
    if ($Force) {
        $parameters.Force = $true
    }

    $command = Get-Command -Name "Get-ChildItem" -ErrorAction Stop
    if ((Test-BRAVOCommandAvailable -Name "Get-ChildItem") -and
        $command.Parameters.ContainsKey("File")) {
        $parameters.File = $true
        return @(Get-ChildItem @parameters)
    }

    return @(Get-ChildItem @parameters | Where-Object { -not $_.PSIsContainer })
}

function Get-BRAVODirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Filter = "*",
        [switch]$Recurse
    )

    $parameters = @{
        Path = $Path
        Filter = $Filter
        ErrorAction = "SilentlyContinue"
    }
    if ($Recurse) {
        $parameters.Recurse = $true
    }

    $command = Get-Command -Name "Get-ChildItem" -ErrorAction Stop
    if ((Test-BRAVOCommandAvailable -Name "Get-ChildItem") -and
        $command.Parameters.ContainsKey("Directory")) {
        $parameters.Directory = $true
        return @(
            Get-ChildItem @parameters |
                Where-Object {
                    ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
                }
        )
    }

    return @(
        Get-ChildItem @parameters |
            Where-Object {
                $_.PSIsContainer -and
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
            }
    )
}

function Get-BRAVOFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("MD5", "SHA1", "SHA256", "SHA384", "SHA512")]
        [string]$Algorithm = "SHA512"
    )

    if (Test-BRAVOCommandAvailable -Name "Get-FileHash") {
        return Get-FileHash -LiteralPath $Path -Algorithm $Algorithm -ErrorAction Stop
    }

    $stream = $null
    $hasher = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        if ($null -eq $hasher) {
            throw "Алгоритм хешування не підтримується: $Algorithm"
        }
        $hashBytes = $hasher.ComputeHash($stream)
        return New-Object PSObject -Property @{
            Algorithm = $Algorithm
            Hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
            Path = (Resolve-Path -LiteralPath $Path).Path
        }
    } finally {
        if ($null -ne $hasher) {
            $hasher.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-BRAVOToolIntegrityRecommendation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$ToolPaths,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    # Довіряємо стану на перший запуск (trust-on-first-use) і зберігаємо
    # контрольні суми SHA-256 у маніфесті поруч із самими інструментами —
    # той самий каталог, який Set-BRAVOProtectedRuntimeAcl вже захищає
    # рекурсивно (запис лише для SYSTEM/Administrators). Це виявляє
    # випадкове пошкодження чи підміну файлу між запусками, але не
    # замінює зовнішній підпис виробника: якщо зловмисник мав доступ на
    # запис у момент першого запуску, і файл, і маніфест можна підмінити
    # одночасно.
    #
    # Відсутність інструменту на диску — це окрема, вже наявна перевірка
    # шляхів (Test-PathWithLog тощо); тут перевіряється лише цілісність
    # того, що реально присутнє.
    $existingTools = @(
        $ToolPaths |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            (Test-Path -LiteralPath $_ -PathType Leaf)
        }
    )
    if ($existingTools.Count -eq 0) {
        return New-Object PSObject -Property @{
            HasIntegrityIssue = $false
            Message = $null
            ManifestPath = $ManifestPath
            MismatchedTools = @()
        }
    }

    $manifest = @{}
    $manifestExisted = Test-Path -LiteralPath $ManifestPath -PathType Leaf
    if ($manifestExisted) {
        try {
            $rawManifest = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
            $parsedManifest = ConvertFrom-BRAVOJson -InputObject $rawManifest
            foreach ($manifestProperty in $parsedManifest.PSObject.Properties) {
                $manifest[$manifestProperty.Name] = [string]$manifestProperty.Value
            }
        } catch {
            # Пошкоджений маніфест не повинен зупиняти роботу — трактуємо
            # як відсутній і перестворюємо базову лінію нижче.
            $manifest = @{}
            $manifestExisted = $false
        }
    }

    $mismatchedTools = New-Object System.Collections.Generic.List[string]
    $manifestChanged = $false
    foreach ($toolPath in $existingTools) {
        $toolName = [System.IO.Path]::GetFileName($toolPath)
        try {
            $currentHash = (Get-BRAVOFileHash -Path $toolPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        } catch {
            continue
        }
        if ($manifest.ContainsKey($toolName)) {
            if (-not [string]::Equals(
                    $manifest[$toolName],
                    $currentHash,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                [void]$mismatchedTools.Add($toolName)
            }
        } else {
            $manifest[$toolName] = $currentHash
            $manifestChanged = $true
        }
    }

    if (-not $manifestExisted -or $manifestChanged) {
        try {
            $manifestDirectory = Split-Path -Path $ManifestPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($manifestDirectory) -and
                -not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) {
                [void][System.IO.Directory]::CreateDirectory($manifestDirectory)
            }
            $manifestJson = $manifest | ConvertTo-BRAVOJson
            [System.IO.File]::WriteAllText(
                $ManifestPath,
                $manifestJson,
                (New-Object System.Text.UTF8Encoding($true))
            )
        } catch {
            # Не вдалося зберегти базову лінію зараз — спробуємо на наступному
            # запуску; це не привід зупиняти поточну операцію.
        }
    }

    if ($mismatchedTools.Count -eq 0) {
        return New-Object PSObject -Property @{
            HasIntegrityIssue = $false
            Message = $null
            ManifestPath = $ManifestPath
            MismatchedTools = @()
        }
    }

    $toolWord = if ($mismatchedTools.Count -eq 1) { "інструмента" } else { "інструментів" }
    $message = (
        "Виявлено розбіжність контрольної суми для {0}: {1}. Це може бути " +
        "легітимне оновлення інструменту або ознака підміни файлу. Якщо " +
        "оновлення свідоме — видаліть '{2}', щоб зафіксувати нову базову " +
        "лінію. Якщо ні — перевірте походження файлу й права доступу до " +
        "каталогу Tools. Скрипт продовжує роботу, автоматичних дій не виконується."
    ) -f $toolWord, ($mismatchedTools -join ", "), $ManifestPath

    return New-Object PSObject -Property @{
        HasIntegrityIssue = $true
        Message = $message
        ManifestPath = $ManifestPath
        MismatchedTools = @($mismatchedTools)
    }
}

function Test-BRAVOTcpConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

    # Test-NetConnection малює власний Write-Progress ("Attempting TCP connect",
    # "Waiting for response"), який перекриває єдиний індикатор BRAVO.
    # Присвоєння створює локальну змінну: після виходу з функції глобальне
    # значення лишається незмінним, тому власний прогрес не глушиться.
    $ProgressPreference = 'SilentlyContinue'

    if (Test-BRAVOCommandAvailable -Name "Test-NetConnection") {
        try {
            return [bool](Test-NetConnection `
                -ComputerName $ComputerName `
                -Port $Port `
                -InformationLevel Quiet `
                -WarningAction SilentlyContinue `
                -ErrorAction Stop)
        } catch {
            # Якщо командлет є, але не підтримується поточною ОС/мережею,
            # перевіряємо той самий TCP endpoint через .NET.
        }
    }

    $client = New-Object System.Net.Sockets.TcpClient
    $asyncResult = $null
    try {
        $asyncResult = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($asyncResult)
        return $client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $asyncResult -and $null -ne $asyncResult.AsyncWaitHandle) {
            $asyncResult.AsyncWaitHandle.Close()
        }
        $client.Close()
    }
}

function Get-BRAVOScheduledTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$TaskName
    )

    $normalizedPath = if ([string]::IsNullOrWhiteSpace($TaskPath) -or $TaskPath -eq "\") {
        "\"
    } else {
        "\" + $TaskPath.Trim("\") + "\"
    }

    if (Test-BRAVOCommandAvailable -Name "Get-ScheduledTask") {
        try {
            $task = Get-ScheduledTask `
                -TaskPath $normalizedPath `
                -TaskName $TaskName `
                -ErrorAction Stop
            return New-Object PSObject -Property @{
                Exists = $true
                State = [string]$task.State
                IsRunning = ([string]$task.State -eq "Running")
                Provider = "ScheduledTasks"
                Task = $task
            }
        } catch {
            # Windows 8+ може мати модуль, але провайдер іноді недоступний.
            # Повторюємо перевірку через базовий COM API планувальника.
        }
    }

    try {
        $service = New-Object -ComObject "Schedule.Service"
        $service.Connect()
        $folderPath = if ($normalizedPath -eq "\") {
            "\"
        } else {
            $normalizedPath.TrimEnd("\")
        }
        $folder = $service.GetFolder($folderPath)
        $task = $folder.GetTask($TaskName)
        return New-Object PSObject -Property @{
            Exists = $true
            State = $(switch ([int]$task.State) {
                0 { "Unknown" }
                1 { "Disabled" }
                2 { "Queued" }
                3 { "Ready" }
                4 { "Running" }
                default { [string]$task.State }
            })
            IsRunning = ([int]$task.State -eq 4)
            Provider = "COM"
            Task = $task
        }
    } catch {
        return New-Object PSObject -Property @{
            Exists = $false
            State = "NotFound"
            IsRunning = $false
            Provider = "COM"
            Task = $null
        }
    }
}

function Enable-BRAVOTls12 {
    # 3072 = TLS 1.2. Число працює навіть у старих .NET, де enum Tls12
    # ще не має символічного імені.
    $tls12 = [Enum]::ToObject([System.Net.SecurityProtocolType], 3072)
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor $tls12
}

function Read-BRAVOTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )

    return [System.IO.File]::ReadAllText($Path, $Encoding)
}

function ConvertTo-BRAVOJsonCompatibleObject {
    param(
        [object]$Value,
        [int]$Depth,
        [int]$CurrentDepth = 0
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($CurrentDepth -ge $Depth -or
        $Value -is [string] -or
        $Value -is [char] -or
        $Value -is [bool] -or
        $Value -is [datetime] -or
        $Value.GetType().IsPrimitive -or
        $Value -is [decimal]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $dictionary = @{}
        foreach ($key in $Value.Keys) {
            $dictionary[[string]$key] = ConvertTo-BRAVOJsonCompatibleObject `
                -Value $Value[$key] `
                -Depth $Depth `
                -CurrentDepth ($CurrentDepth + 1)
        }
        return $dictionary
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-BRAVOJsonCompatibleObject `
                -Value $item `
                -Depth $Depth `
                -CurrentDepth ($CurrentDepth + 1)))
        }
        return @($items)
    }

    $properties = @{}
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.MemberType -match "Property") {
            $properties[$property.Name] = ConvertTo-BRAVOJsonCompatibleObject `
                -Value $property.Value `
                -Depth $Depth `
                -CurrentDepth ($CurrentDepth + 1)
        }
    }
    return $properties
}

function ConvertTo-BRAVOJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][object]$InputObject,
        [int]$Depth = 5,
        [switch]$Compress
    )

    process {
        if (Test-BRAVOCommandAvailable -Name "ConvertTo-Json") {
            if ($Compress) {
                return ($InputObject | ConvertTo-Json -Depth $Depth -Compress)
            }
            return ($InputObject | ConvertTo-Json -Depth $Depth)
        }

        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        $compatibleObject = ConvertTo-BRAVOJsonCompatibleObject `
            -Value $InputObject `
            -Depth $Depth
        return $serializer.Serialize($compatibleObject)
    }
}

function ConvertFrom-BRAVOJsonCompatibleObject {
    param([object]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsPrimitive) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $properties = @{}
        foreach ($key in $Value.Keys) {
            $properties[[string]$key] = ConvertFrom-BRAVOJsonCompatibleObject -Value $Value[$key]
        }
        return New-Object PSObject -Property $properties
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object {
            ConvertFrom-BRAVOJsonCompatibleObject -Value $_
        })
    }
    return $Value
}

function ConvertFrom-BRAVOJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][string]$InputObject)

    process {
        if (Test-BRAVOCommandAvailable -Name "ConvertFrom-Json") {
            return ($InputObject | ConvertFrom-Json -ErrorAction Stop)
        }

        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        $value = $serializer.DeserializeObject($InputObject)
        return ConvertFrom-BRAVOJsonCompatibleObject -Value $value
    }
}

function Start-BRAVOProcessOutputCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    # Архіватор і health-check можуть підключити SFTP runtime, який надає
    # атомарний lock для WinSCP.com. Інші процеси та утиліти працюють без нього.
    $winSCPProcessLock = $null
    if ([System.IO.Path]::GetFileName([string]$Process.StartInfo.FileName) -ieq "WinSCP.com" -and
        $null -ne (Get-Command -Name "Enter-BRAVOWinSCPProcessLock" -CommandType Function -ErrorAction SilentlyContinue)) {
        $lockResult = Enter-BRAVOWinSCPProcessLock
        if (-not $lockResult.Success) {
            throw "Запуск WinSCP заблоковано атомарним lock ($($lockResult.Path)): $($lockResult.Error)"
        }
        $winSCPProcessLock = $lockResult.Stream
    }

    $readToEndAsyncMethod = [System.IO.StreamReader].GetMethod(
        "ReadToEndAsync",
        [Type[]]@()
    )
    $useModernApi = (
        $null -ne $readToEndAsyncMethod -and
        $env:BRAVO_FORCE_LEGACY_API -ne "1"
    )

    if ($useModernApi) {
        try {
            $Process.Start() | Out-Null
        } catch {
            if ($winSCPProcessLock) { $winSCPProcessLock.Dispose() }
            throw
        }
        return New-Object PSObject -Property @{
            Mode = "Task"
            Process = $Process
            OutputTask = $Process.StandardOutput.ReadToEndAsync()
            ErrorTask = $Process.StandardError.ReadToEndAsync()
            WinSCPProcessLock = $winSCPProcessLock
        }
    }

    # .NET Framework 4.0 не має ReadToEndAsync. Події Process одночасно
    # дренують stdout і stderr та не дають зовнішньому процесу зависнути.
    $outputLines = [System.Collections.ArrayList]::Synchronized(
        (New-Object System.Collections.ArrayList)
    )
    $errorLines = [System.Collections.ArrayList]::Synchronized(
        (New-Object System.Collections.ArrayList)
    )
    $captureId = [guid]::NewGuid().ToString("N")
    $outputSource = "BRAVO_PROCESS_OUTPUT_$captureId"
    $errorSource = "BRAVO_PROCESS_ERROR_$captureId"
    $outputJob = Register-ObjectEvent `
        -InputObject $Process `
        -EventName OutputDataReceived `
        -SourceIdentifier $outputSource `
        -MessageData $outputLines `
        -Action {
            if ($null -ne $EventArgs.Data) {
                [void]$Event.MessageData.Add([string]$EventArgs.Data)
            }
        }
    $errorJob = Register-ObjectEvent `
        -InputObject $Process `
        -EventName ErrorDataReceived `
        -SourceIdentifier $errorSource `
        -MessageData $errorLines `
        -Action {
            if ($null -ne $EventArgs.Data) {
                [void]$Event.MessageData.Add([string]$EventArgs.Data)
            }
        }

    try {
        $Process.Start() | Out-Null
        $Process.BeginOutputReadLine()
        $Process.BeginErrorReadLine()
    } catch {
        foreach ($source in @($outputSource, $errorSource)) {
            Unregister-Event -SourceIdentifier $source -ErrorAction SilentlyContinue
        }
        foreach ($job in @($outputJob, $errorJob)) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        if ($winSCPProcessLock) { $winSCPProcessLock.Dispose() }
        throw
    }

    return New-Object PSObject -Property @{
        Mode = "Event"
        Process = $Process
        OutputLines = $outputLines
        ErrorLines = $errorLines
        OutputSource = $outputSource
        ErrorSource = $errorSource
        OutputJob = $outputJob
        ErrorJob = $errorJob
        WinSCPProcessLock = $winSCPProcessLock
    }
}

function Complete-BRAVOProcessOutputCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Capture,
        [int]$WaitTimeoutMilliseconds = 5000
    )

    if ($Capture.Mode -eq "Task") {
        try {
            if (-not $Capture.Process.HasExited -and
                -not $Capture.Process.WaitForExit([math]::Max(1, $WaitTimeoutMilliseconds))) {
                throw "процес не завершився під час збору виводу"
            }
            if (-not $Capture.OutputTask.Wait([math]::Max(1, $WaitTimeoutMilliseconds)) -or
                -not $Capture.ErrorTask.Wait([math]::Max(1, $WaitTimeoutMilliseconds))) {
                throw "потоки виводу процесу не завершилися вчасно"
            }
            return New-Object PSObject -Property @{
                StandardOutput = [string]$Capture.OutputTask.Result
                StandardError = [string]$Capture.ErrorTask.Result
            }
        } finally {
            if ($Capture.WinSCPProcessLock) { $Capture.WinSCPProcessLock.Dispose() }
        }
    }

    try {
        if (-not $Capture.Process.HasExited -and
            -not $Capture.Process.WaitForExit([math]::Max(1, $WaitTimeoutMilliseconds))) {
            throw "процес не завершився під час збору виводу"
        }
        try { $Capture.Process.CancelOutputRead() } catch {}
        try { $Capture.Process.CancelErrorRead() } catch {}
        return New-Object PSObject -Property @{
            StandardOutput = [string](@($Capture.OutputLines) -join [Environment]::NewLine)
            StandardError = [string](@($Capture.ErrorLines) -join [Environment]::NewLine)
        }
    } finally {
        foreach ($source in @($Capture.OutputSource, $Capture.ErrorSource)) {
            Get-Event -SourceIdentifier $source -ErrorAction SilentlyContinue |
                Remove-Event -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier $source -ErrorAction SilentlyContinue
        }
        foreach ($job in @($Capture.OutputJob, $Capture.ErrorJob)) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        if ($Capture.WinSCPProcessLock) { $Capture.WinSCPProcessLock.Dispose() }
    }
}

function Get-BRAVOSevenZipExitCodeDescription {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [Nullable[int]]$ExitCode,
        [switch]$TimedOut
    )

    if ($TimedOut) {
        return "перевищено час очікування"
    }
    if ($null -eq $ExitCode) {
        return "7-Zip не повернув код завершення"
    }

    switch ([int]$ExitCode) {
        0 { return "помилок немає" }
        1 { return "попередження: частину даних не вдалося обробити" }
        2 { return "критична помилка" }
        7 { return "помилка параметрів командного рядка" }
        8 { return "недостатньо пам'яті" }
        255 { return "операцію перервано користувачем або системою" }
        default { return "невідомий код 7-Zip" }
    }
}

function ConvertTo-BRAVOWindowsCommandLineArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($backslashCount * 2 + 1)))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-BRAVOSevenZipIntegrityTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZipPath,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$TimeoutSeconds = 43200
    )

    $process = $null
    $capture = $null
    $timedOut = $false
    $exitCode = $null
    $standardOutput = ""
    $standardError = ""

    try {
        if (-not (Test-Path -LiteralPath $SevenZipPath -PathType Leaf)) {
            throw "7-Zip не знайдено: $SevenZipPath"
        }
        if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
            throw "архів не знайдено: $ArchivePath"
        }
        if ([string]::IsNullOrWhiteSpace($Password)) {
            throw "пароль архіву не задано"
        }
        if ($Password.IndexOfAny([char[]]"`r`n") -ge 0) {
            throw "пароль архіву не може містити символи нового рядка"
        }

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $SevenZipPath
        # Без параметра -p 7-Zip запитує пароль зашифрованого архіву зі
        # стандартного вводу. Так секрет не потрапляє до командного рядка.
        $processInfo.Arguments = "t -y -bb1 `"$ArchivePath`""
        $processInfo.RedirectStandardInput = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $capture = Start-BRAVOProcessOutputCapture -Process $process
        $process.StandardInput.WriteLine($Password)
        $process.StandardInput.Close()

        if ($TimeoutSeconds -gt 0) {
            $timeoutMilliseconds = [int][math]::Min(
                [double][int]::MaxValue,
                [double]$TimeoutSeconds * 1000
            )
            $completed = $process.WaitForExit($timeoutMilliseconds)
        } else {
            $process.WaitForExit()
            $completed = $true
        }

        if (-not $completed) {
            $timedOut = $true
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                # Процес міг завершитися між перевіркою таймауту та Kill().
            }
        }

        if ($null -ne $capture) {
            $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $capture
            $capture = $null
            $standardOutput = [string]$capturedOutput.StandardOutput
            $standardError = [string]$capturedOutput.StandardError
        }
        if ($process.HasExited) {
            $exitCode = [int]$process.ExitCode
        }

        $description = Get-BRAVOSevenZipExitCodeDescription `
            -ExitCode $exitCode `
            -TimedOut:$timedOut
        return New-Object PSObject -Property @{
            Success = (-not $timedOut -and $exitCode -eq 0)
            ExitCode = $exitCode
            Description = $description
            TimedOut = $timedOut
            StandardOutput = $standardOutput
            StandardError = $standardError
            Error = $null
        }
    } catch {
        return New-Object PSObject -Property @{
            Success = $false
            ExitCode = $exitCode
            Description = $_.Exception.Message
            TimedOut = $timedOut
            StandardOutput = $standardOutput
            StandardError = $standardError
            Error = $_.Exception.Message
        }
    } finally {
        if ($null -ne $capture) {
            try {
                [void](Complete-BRAVOProcessOutputCapture -Capture $capture)
            } catch {
                # Збір виводу не повинен приховувати основний результат тесту.
            }
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Send-BRAVOWebhookNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("slack", "discord")]
        [string]$Provider,

        [Parameter(Mandatory = $true)]
        [string]$WebhookUrl,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$TimeoutSeconds = 30
    )

    $webhookUri = $null
    if (-not [Uri]::TryCreate($WebhookUrl, [UriKind]::Absolute, [ref]$webhookUri) -or
        $webhookUri.Scheme -ne [Uri]::UriSchemeHttps) {
        throw "Webhook для $Provider не налаштовано або він не використовує HTTPS"
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        throw "Текст webhook-повідомлення порожній"
    }

    Enable-BRAVOTls12
    $notificationSeparator = (("━" * 36) -join "")
    $messageForWebhook = if ($Message.TrimStart().StartsWith($notificationSeparator)) {
        $Message
    } else {
        "$notificationSeparator`n$Message"
    }
    $normalizedProvider = $Provider.ToLowerInvariant()
    $payload = if ($normalizedProvider -eq "discord") {
        @{
            content = $messageForWebhook
            allowed_mentions = @{parse = @()}
        }
    } else {
        @{text = $messageForWebhook}
    }
    $payloadJson = $payload | ConvertTo-Json -Compress -Depth 4
    $requestParameters = @{
        Uri = $webhookUri.AbsoluteUri
        Method = "Post"
        ContentType = "application/json; charset=utf-8"
        Body = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
        TimeoutSec = [math]::Max(1, $TimeoutSeconds)
        UseBasicParsing = $true
        ErrorAction = "Stop"
    }
    # Invoke-WebRequest теж має власний індикатор; глушимо його локально,
    # щоб надсилання сповіщення не перекривало смугу прогресу BRAVO.
    $ProgressPreference = 'SilentlyContinue'
    $response = Invoke-WebRequest @requestParameters

    if ($normalizedProvider -eq "slack") {
        $responseText = ([string]$response.Content).Trim()
        if (-not [string]::IsNullOrWhiteSpace($responseText) -and $responseText -ne "ok") {
            throw "Slack повернув неочікувану відповідь: $responseText"
        }
    }
}

function Get-BRAVOTaskStateName {
    param([int]$State)

    switch ($State) {
        0 { return "UNKNOWN" }
        1 { return "DISABLED" }
        2 { return "QUEUED" }
        3 { return "READY" }
        4 { return "RUNNING" }
        default { return [string]$State }
    }
}
