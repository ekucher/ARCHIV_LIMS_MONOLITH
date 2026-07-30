##########
# BravoSoft
# Author: Evgeniy Kucher
# Скрипт для архівації та резервного копіювання даних BRAVO/LIMS
# Конфігурація винесена в окремий файл
##########

# Ручна синхронізація лише BAZA на SFTP:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\BRAVO_ARCHIV.ps1" -SyncBAZA -NoPause

param(
    [string]$ConfigPath,
    [switch]$SyncBAZA,
    [switch]$HealthCheckOnly,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause
)

$bravoScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Path $PSCommandPath -Parent
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

# Вбудовані функції сумісності й Credential Manager нижче усувають runtime-
# залежність від BRAVO_COMPATIBILITY.ps1 і BRAVO_CREDENTIALS.ps1.
# BEGIN BRAVO EMBEDDED RUNTIME LIBRARIES
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

function Test-BRAVOTcpConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

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

function Enter-BRAVOWinSCPProcessLock {
    $lockPath = Join-Path $logPath "BRAVO_WINSCP.lock"
    try {
        if (-not (Test-Path -LiteralPath $logPath -PathType Container)) {
            New-Item -ItemType Directory -Path $logPath -Force -ErrorAction Stop | Out-Null
        }
        $stream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        return [pscustomobject]@{ Success = $true; Stream = $stream; Path = $lockPath; Error = $null }
    } catch {
        return [pscustomobject]@{ Success = $false; Stream = $null; Path = $lockPath; Error = $_.Exception.Message }
    }
}

function Start-BRAVOProcessOutputCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    $winSCPProcessLock = $null
    if ([System.IO.Path]::GetFileName([string]$Process.StartInfo.FileName) -ieq "WinSCP.com") {
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
        try { $Process.Start() | Out-Null } catch { if ($winSCPProcessLock) { $winSCPProcessLock.Dispose() }; throw }
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

function Test-BRAVOWinSCPAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WinSCPPath
    )

    # BRAVO запускає консольний клієнт WinSCP.com. Відкритий графічний
    # WinSCP.exe не блокує задачу, а інший WinSCP.com може одночасно змінювати
    # той самий SFTP-каталог, тому запуск у такому разі забороняємо.
    $processName = [System.IO.Path]::GetFileName($WinSCPPath)
    if ([string]::IsNullOrWhiteSpace($processName)) {
        return [pscustomobject]@{
            Available = $false
            Processes = @()
            Error = "не вдалося визначити ім'я процесу WinSCP"
        }
    }

    try {
        $activeProcesses = @(
            Get-CimInstance -ClassName Win32_Process -Filter "Name = '$processName'" -ErrorAction Stop |
                ForEach-Object {
                    [pscustomobject]@{
                        ProcessId = [int]$_.ProcessId
                        Started = [string]$_.CreationDate
                    }
                }
        )
        return [pscustomobject]@{
            Available = ($activeProcesses.Count -eq 0)
            Processes = $activeProcesses
            Error = $null
        }
    } catch {
        # Без достовірної перевірки не запускаємо передачу паралельно.
        return [pscustomobject]@{
            Available = $false
            Processes = @()
            Error = "не вдалося перевірити активні процеси ${processName}: $($_.Exception.Message)"
        }
    }
}

function Get-BRAVOWinSCPBusyMessage {
    param(
        [Parameter(Mandatory = $true)]
        $Availability,
        [string]$Operation = "операція SFTP"
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Availability.Error)) {
        return "Запуск WinSCP для ${Operation} заблоковано: $($Availability.Error)"
    }

    $processDetails = @($Availability.Processes | ForEach-Object {
        "PID=$($_.ProcessId)"
    }) -join ", "
    return "Запуск WinSCP для ${Operation} заблоковано: виявлено активний WinSCP.com ($processDetails)"
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
    $outboundMessages = if ($normalizedProvider -eq "discord" -and $messageForWebhook.Length -gt 1900) {
        $chunks = New-Object System.Collections.Generic.List[string]
        $current = New-Object System.Text.StringBuilder
        foreach ($line in ($messageForWebhook -split "`r?`n")) {
            if ($current.Length -gt 0 -and ($current.Length + $line.Length + 1) -gt 1900) {
                $chunks.Add($current.ToString()); [void]$current.Clear()
            }
            if ($current.Length -gt 0) { [void]$current.AppendLine() }
            [void]$current.Append($line)
        }
        if ($current.Length -gt 0) { $chunks.Add($current.ToString()) }
        @($chunks)
    } else { @($messageForWebhook) }
    foreach ($outboundMessage in $outboundMessages) {
        $payload = if ($normalizedProvider -eq "discord") { @{ content = $outboundMessage; allowed_mentions = @{parse = @()} } } else { @{text = $outboundMessage} }
        $requestParameters = @{ Uri = $webhookUri.AbsoluteUri; Method = "Post"; ContentType = "application/json; charset=utf-8"; Body = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress -Depth 4)); TimeoutSec = [math]::Max(1, $TimeoutSeconds); UseBasicParsing = $true; ErrorAction = "Stop" }
        $response = Invoke-WebRequest @requestParameters
        if ($normalizedProvider -eq "slack") {
            $responseText = ([string]$response.Content).Trim()
            if (-not [string]::IsNullOrWhiteSpace($responseText) -and $responseText -ne "ok") { throw "Slack повернув неочікувану відповідь: $responseText" }
        }
    }
}

Assert-BRAVOPowerShellCompatibility
[void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
$script:BRAVOCompatibility = Get-BRAVOCompatibilityInfo
$script:BRAVOPowerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation


function Initialize-BRAVOCredentialManager {
    if ("BRAVO.Security.CredentialManager" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;

namespace BRAVO.Security
{
    public sealed class StoredCredential
    {
        public string TargetName { get; internal set; }
        public string UserName { get; internal set; }
        public string Secret { get; internal set; }
    }

    public static class CredentialManager
    {
        private const int CRED_TYPE_GENERIC = 1;
        private const int CRED_PERSIST_LOCAL_MACHINE = 2;
        private const int ERROR_NOT_FOUND = 1168;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credentialPointer);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll", SetLastError = false)]
        private static extern void CredFree(IntPtr buffer);

        public static StoredCredential ReadGeneric(string target)
        {
            if (String.IsNullOrWhiteSpace(target))
                throw new ArgumentException("Credential target is empty.", "target");

            IntPtr pointer;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out pointer))
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_NOT_FOUND)
                    return null;
                throw new Win32Exception(error, "CredRead failed for target '" + target + "'.");
            }

            try
            {
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(pointer, typeof(CREDENTIAL));
                string secret = String.Empty;
                if (credential.CredentialBlob != IntPtr.Zero && credential.CredentialBlobSize > 0)
                {
                    byte[] secretBytes = new byte[credential.CredentialBlobSize];
                    Marshal.Copy(credential.CredentialBlob, secretBytes, 0, secretBytes.Length);
                    try
                    {
                        secret = Encoding.Unicode.GetString(secretBytes).TrimEnd('\0');
                    }
                    finally
                    {
                        Array.Clear(secretBytes, 0, secretBytes.Length);
                    }
                }

                return new StoredCredential
                {
                    TargetName = credential.TargetName,
                    UserName = credential.UserName ?? String.Empty,
                    Secret = secret
                };
            }
            finally
            {
                CredFree(pointer);
            }
        }

        public static void WriteGeneric(string target, string userName, SecureString secret)
        {
            if (String.IsNullOrWhiteSpace(target))
                throw new ArgumentException("Credential target is empty.", "target");
            if (secret == null || secret.Length == 0)
                throw new ArgumentException("Credential secret is empty.", "secret");

            IntPtr secretPointer = IntPtr.Zero;
            try
            {
                secretPointer = Marshal.SecureStringToCoTaskMemUnicode(secret);
                CREDENTIAL credential = new CREDENTIAL
                {
                    Flags = 0,
                    Type = CRED_TYPE_GENERIC,
                    TargetName = target,
                    Comment = "BRAVO protected credential",
                    CredentialBlobSize = checked(secret.Length * 2),
                    CredentialBlob = secretPointer,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    AttributeCount = 0,
                    Attributes = IntPtr.Zero,
                    TargetAlias = null,
                    UserName = userName ?? String.Empty
                };

                if (!CredWrite(ref credential, 0))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error, "CredWrite failed for target '" + target + "'.");
                }
            }
            finally
            {
                if (secretPointer != IntPtr.Zero)
                    Marshal.ZeroFreeCoTaskMemUnicode(secretPointer);
            }
        }

        public static bool DeleteGeneric(string target)
        {
            if (String.IsNullOrWhiteSpace(target))
                throw new ArgumentException("Credential target is empty.", "target");

            if (CredDelete(target, CRED_TYPE_GENERIC, 0))
                return true;

            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_NOT_FOUND)
                return false;
            throw new Win32Exception(error, "CredDelete failed for target '" + target + "'.");
        }
    }
}
'@
}

function Get-BRAVOCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    Initialize-BRAVOCredentialManager
    return [BRAVO.Security.CredentialManager]::ReadGeneric($Target)
}

function Get-BRAVOCredentialSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    $credential = Get-BRAVOCredential -Target $Target
    if ($null -eq $credential) {
        return $null
    }
    return [string]$credential.Secret
}

function Set-BRAVOCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [string]$UserName = "",

        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Secret
    )

    Initialize-BRAVOCredentialManager
    [BRAVO.Security.CredentialManager]::WriteGeneric($Target, $UserName, $Secret)
}

function Remove-BRAVOCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    Initialize-BRAVOCredentialManager
    return [BRAVO.Security.CredentialManager]::DeleteGeneric($Target)
}

function Get-BRAVOCredentialIdentity {
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-BRAVOArchivePasswordTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $CredentialSettings,

        [string]$InstitutionCode
    )

    $configuredTarget = [string]$CredentialSettings.Targets.ArchivePassword
    if (-not [string]::IsNullOrWhiteSpace($configuredTarget)) {
        return $configuredTarget
    }

    return "BRAVO_7Z_PASSWORD"
}

function Test-BRAVOInstitutionSettingValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("InstitutionName", "InstitutionCode", "ArchivePrefix")]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $normalized = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "$Name не може бути порожнім"
    }
    if ($normalized -match '[\x00-\x1F\x7F]') {
        throw "$Name містить керуючі символи"
    }

    switch ($Name) {
        "InstitutionName" {
            if ($normalized.Length -gt 160) {
                throw "InstitutionName не може бути довшим за 160 символів"
            }
        }
        "InstitutionCode" {
            if ($normalized -notmatch '^[\p{L}\p{Nd}._-]{1,64}$') {
                throw "InstitutionCode: дозволені лише літери, цифри, крапка, '_' і '-' (до 64 символів)"
            }
        }
        "ArchivePrefix" {
            if ($normalized -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
                throw "ArchivePrefix повинен починатися з латинської літери/цифри; дозволені A-Z, 0-9, '.', '_' і '-' (до 80 символів)"
            }
            if ($normalized.EndsWith(".")) {
                throw "ArchivePrefix не може закінчуватися крапкою"
            }
        }
    }
    return $normalized
}

function Import-BRAVOInstitutionSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $CredentialSettings,

        [Parameter(Mandatory = $true)]
        $BravoSettings
    )

    $descriptors = @(
        [pscustomobject]@{
            Name = "InstitutionName"
            DefaultTarget = "BRAVO_INSTITUTION_NAME"
        },
        [pscustomobject]@{
            Name = "InstitutionCode"
            DefaultTarget = "BRAVO_INSTITUTION_CODE"
        },
        [pscustomobject]@{
            Name = "ArchivePrefix"
            DefaultTarget = "BRAVO_ARCHIVE_PREFIX"
        }
    )
    $results = New-Object System.Collections.ArrayList

    foreach ($descriptor in $descriptors) {
        $target = [string]$CredentialSettings.Targets[$descriptor.Name]
        if ([string]::IsNullOrWhiteSpace($target)) {
            $target = [string]$descriptor.DefaultTarget
        }

        $storedValue = Get-BRAVOCredentialSecret -Target $target
        $source = "CredentialManager"
        if ([string]::IsNullOrWhiteSpace($storedValue)) {
            $storedValue = [string]$BravoSettings[$descriptor.Name]
            $source = "ConfigurationFallback"
        }
        $normalizedValue = Test-BRAVOInstitutionSettingValue `
            -Name ([string]$descriptor.Name) `
            -Value $storedValue
        $BravoSettings[$descriptor.Name] = $normalizedValue

        [void]$results.Add([pscustomobject]@{
            Name = [string]$descriptor.Name
            Target = $target
            Source = $source
        })
        $storedValue = $null
        $normalizedValue = $null
    }

    # BRAVO.config створює ці похідні значення до читання Credential Manager.
    # Оновлюємо їх разом, щоб archive, maintenance і health мали один контекст.
    $global:archivePrefix = [string]$BravoSettings.ArchivePrefix
    if ($null -ne $global:maintenanceSettings -and
        $null -ne $global:maintenanceSettings.General) {
        $global:maintenanceSettings.General.ObjectName = (
            "$($BravoSettings.InstitutionName) [$($BravoSettings.InstitutionCode)]"
        )
        $global:maintenanceSettings.General.ArchivePrefix =
            [string]$BravoSettings.ArchivePrefix
    }
    if ($null -ne $global:backupMonitoring) {
        $global:backupMonitoring.InstitutionName =
            [string]$BravoSettings.InstitutionName
        $global:backupMonitoring.InstitutionCode =
            [string]$BravoSettings.InstitutionCode
    }

    return $results.ToArray()
}

function Resolve-BRAVOSftpHostName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [string]$HostTemplate,

        [string]$FallbackHostName
    )

    $normalizedUserName = $UserName.Trim()
    $resolvedHostName = ""

    if (-not [string]::IsNullOrWhiteSpace($HostTemplate)) {
        if ($HostTemplate -notmatch '\{0\}') {
            throw "SFTP host template must contain {0} for BRAVO_SFTP_LOGIN substitution"
        }
        try {
            $resolvedHostName = $HostTemplate.Trim() -f $normalizedUserName
        } catch {
            throw "Cannot build SFTP host from template '$HostTemplate': $($_.Exception.Message)"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($FallbackHostName)) {
        # Compatibility with old BRAVO.config files that contain a full hostname.
        $resolvedHostName = $FallbackHostName.Trim()
    } else {
        throw "Neither sftpHostTemplate nor legacy sftpHost is configured"
    }

    $resolvedHostName = $resolvedHostName.Trim().TrimEnd(".")
    if ($resolvedHostName.Length -gt 253 -or
        $resolvedHostName -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') {
        throw "Invalid SFTP host was generated: '$resolvedHostName'"
    }

    return $resolvedHostName.ToLowerInvariant()
}

function New-BRAVOSftpUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Password,

        [ValidateRange(1, 65535)]
        [int]$Port = 22
    )

    $escapedUserName = [Uri]::EscapeDataString($UserName)
    $escapedPassword = [Uri]::EscapeDataString($Password)
    $portSuffix = if ($Port -eq 22) { "" } else { ":$Port" }
    return "sftp://${escapedUserName}:${escapedPassword}@${HostName}${portSuffix}/"
}

# END BRAVO EMBEDDED RUNTIME LIBRARIES

# BEGIN BRAVO EMBEDDED HEALTH MODE
function Invoke-BRAVOEmbeddedHealth {
    param(
        [string]$ConfigPath,
        [switch]$ForceNotification,
        [switch]$NotifyOnSuccess,
        [switch]$NoSlack,
        [switch]$SkipIfBackupTaskRunning
    )

function Complete-BRAVOHealthResult {
    param([Parameter(Mandatory = $true)]$Result)
    return $Result
}

$bravoScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Path $PSCommandPath -Parent
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

# Compatibility runtime is embedded in BRAVO_ARCHIV.ps1.

try {
    Enable-BRAVOTls12
} catch {
    # Health-check зможе виконати локальні перевірки навіть тоді, коли
    # TLS 1.2 не підтримується системним .NET/Schannel.
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

$healthCheckStarted = Get-Date
$script:healthLatestArchives = @{}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    Write-Error "Файл конфігурації не знайдено: $ConfigPath"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "ConfigurationError"
        IssueCount = 0
        Notification = "NotSent"
    })
}

try {
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $ConfigPath -Parent
    $configText = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
    $configScript = [scriptblock]::Create($configText)
    & $configScript -ConfigRoot $configRoot
    if ($null -ne $credentialSettings) {
        [void](Import-BRAVOInstitutionSettings `
            -CredentialSettings $credentialSettings `
            -BravoSettings $bravoSettings)
    }
} catch {
    Write-Error "Не вдалося завантажити конфігурацію: $($_.Exception.Message)"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "ConfigurationError"
        IssueCount = 0
        Notification = "NotSent"
    })
}

function Test-BRAVOSettingEnabled {
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($null -eq $Value) {
        return $false
    }

    # Не використовуємо пряме [bool]"false": у PowerShell будь-який
    # непорожній рядок перетворюється на $true.
    return ([string]$Value).Trim() -match '^(?i:true|1|yes|on)$'
}

$bazaLocalHealthEnabled = Test-BRAVOSettingEnabled `
    -Value $componentSettings.Synchronization.BAZALocal
$bazaSFTPHealthEnabled = Test-BRAVOSettingEnabled `
    -Value $componentSettings.Synchronization.BAZASFTP
$bazaWWWSFTPHealthEnabled = Test-BRAVOSettingEnabled `
    -Value $componentSettings.Synchronization.BAZAWWWSFTP

$healthLogTimestamp = $healthCheckStarted.ToString($logFileDateFormat)
$healthLogName = $backupMonitoring.LogFileNameTemplate -f $healthLogTimestamp
$healthLogFile = Join-Path $logPath $healthLogName

$credentialHelperLoaded = $false
$credentialHelperError = $null
$notificationCredentialError = $null
$sftpCredentialError = $null
$smbCredentialError = $null
$script:smbCredential = $null
try {
    if ($null -eq $credentialSettings -or $null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
        throw 'вбудований Credential Manager недоступний'
    }
    $credentialHelperLoaded = $true
} catch {
    $credentialHelperError = $_.Exception.Message
}

$NotificationProvider = ([string]$backupMonitoring.NotificationProvider).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($NotificationProvider)) {
    $NotificationProvider = "discord"
}
$NotificationMode = [string]$backupMonitoring.NotificationMode
if ([string]::IsNullOrWhiteSpace($NotificationMode)) {
    # Сумісність зі старим BRAVO.config.
    $NotificationMode = [string]$backupMonitoring.SlackMode
}
$NotificationMode = $NotificationMode.ToLowerInvariant()
$NotificationWebhookUrl = $null
$notificationCredentialTarget = if ($NotificationProvider -eq "discord") {
    [string]$backupMonitoring.NotificationCredentialTargets.DiscordWebhook
} else {
    [string]$backupMonitoring.NotificationCredentialTargets.SlackWebhook
}
if ([string]::IsNullOrWhiteSpace($notificationCredentialTarget)) {
    $notificationCredentialTarget = if ($NotificationProvider -eq "discord") {
        "BRAVO_DISCORD_URL"
    } else {
        "BRAVO_SLACK_URL"
    }
}
if ($NotificationMode -ne "none" -and $credentialHelperLoaded) {
    try {
        if ([string]::IsNullOrWhiteSpace($notificationCredentialTarget)) {
            throw "не налаштовано назву Credential Manager для $NotificationProvider"
        }
        $NotificationWebhookUrl = Get-BRAVOCredentialSecret -Target $notificationCredentialTarget
        if ([string]::IsNullOrWhiteSpace($NotificationWebhookUrl)) {
            throw "запис Credential Manager '$notificationCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
    } catch {
        $notificationCredentialError = $_.Exception.Message
    }
} elseif ($NotificationMode -ne "none") {
    $notificationCredentialError = $credentialHelperError
}

$global:Login = $null
$global:sftpUrl = $null
$sftpCredentialRequired = [bool]$backupMonitoring.SFTP.Enabled -and
    (([bool]$backupMonitoring.SFTP.CheckArchiveUploads -and [bool]$componentSettings.SFTP.ArchiveUpload) -or
    ([bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
    ($bazaSFTPHealthEnabled -or $bazaWWWSFTPHealthEnabled)))
if ($sftpCredentialRequired -and $credentialHelperLoaded) {
    try {
        $sftpLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
        $sftpPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
        if ([string]::IsNullOrWhiteSpace($sftpLoginTarget)) {
            $sftpLoginTarget = "BRAVO_SFTP_LOGIN"
        }
        if ([string]::IsNullOrWhiteSpace($sftpPasswordTarget)) {
            $sftpPasswordTarget = "BRAVO_SFTP_PASSWORD"
        }
        $storedSftpLogin = Get-BRAVOCredentialSecret -Target $sftpLoginTarget
        $storedSftpPassword = Get-BRAVOCredentialSecret -Target $sftpPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSftpLogin)) {
            throw "запис Credential Manager '$sftpLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ([string]::IsNullOrWhiteSpace($storedSftpPassword)) {
            throw "запис Credential Manager '$sftpPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        $global:Login = ([string]$storedSftpLogin).Trim()
        $configuredSftpHost = [string]$sftpHost
        $global:sftpHost = Resolve-BRAVOSftpHostName `
            -UserName $global:Login `
            -HostTemplate ([string]$sftpHostTemplate) `
            -FallbackHostName $configuredSftpHost
        $global:sftpUrl = New-BRAVOSftpUrl `
            -HostName $global:sftpHost `
            -Port ([int]$sftpPort) `
            -UserName $global:Login `
            -Password ([string]$storedSftpPassword)
        $storedSftpLogin = $null
        $storedSftpPassword = $null
    } catch {
        $sftpCredentialError = $_.Exception.Message
    }
} elseif ($sftpCredentialRequired) {
    $sftpCredentialError = $credentialHelperError
}

$smbCredentialRequired = [bool]$backupMonitoring.SMB.Enabled -and
    [bool]$backupMonitoring.SMB.CheckArchiveCopies -and
    [bool]$componentSettings.SMB.ArchiveCopy
if ($smbCredentialRequired -and $credentialHelperLoaded) {
    try {
        $smbLoginTarget = [string]$credentialSettings.Targets.SMBLogin
        $smbPasswordTarget = [string]$credentialSettings.Targets.SMBPassword
        if ([string]::IsNullOrWhiteSpace($smbLoginTarget)) {
            $smbLoginTarget = "BRAVO_SMB_LOGIN"
        }
        if ([string]::IsNullOrWhiteSpace($smbPasswordTarget)) {
            $smbPasswordTarget = "BRAVO_SMB_PASSWORD"
        }
        $storedSmbLogin = Get-BRAVOCredentialSecret -Target $smbLoginTarget
        $storedSmbPassword = Get-BRAVOCredentialSecret -Target $smbPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSmbLogin)) {
            throw "запис Credential Manager '$smbLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ([string]::IsNullOrWhiteSpace($storedSmbPassword)) {
            throw "запис Credential Manager '$smbPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $secureSmbPassword = ConvertTo-SecureString -String ([string]$storedSmbPassword) -AsPlainText -Force
        $script:smbCredential = New-Object System.Management.Automation.PSCredential(
            [string]$storedSmbLogin,
            $secureSmbPassword
        )
        $storedSmbLogin = $null
        $storedSmbPassword = $null
        $secureSmbPassword = $null
    } catch {
        $smbCredentialError = $_.Exception.Message
    }
} elseif ($smbCredentialRequired) {
    $smbCredentialError = $credentialHelperError
}

$NotificationRequestTimeoutSeconds = if ($null -ne $backupMonitoring.NotificationRequestTimeoutSeconds) {
    [math]::Max(1, [int]$backupMonitoring.NotificationRequestTimeoutSeconds)
} elseif ($null -ne $backupMonitoring.SlackRequestTimeoutSeconds) {
    [math]::Max(1, [int]$backupMonitoring.SlackRequestTimeoutSeconds)
} else {
    30
}
$NotificationProviderDisplayName = if ($NotificationProvider -eq "discord") { "Discord" } else { "Slack" }

function Write-HealthLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format $logTimestampFormat
    $entry = "[$timestamp] [$Level] $Message"
    $consoleEntry = if ($consoleSettings.ShowTimestampsInConsole) {
        $entry
    } else {
        "[$Level] $Message"
    }
    Write-Host $consoleEntry

    try {
        if (-not (Test-Path -Path $logPath -PathType Container)) {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        $entry | Out-File -FilePath $healthLogFile -Append -Encoding $logFileEncoding
    } catch {
        Write-Host "Не вдалося записати health-check лог: $($_.Exception.Message)"
    }
}

function Get-HostInformation {
    if ($null -ne $script:CachedHostInformation) {
        return $script:CachedHostInformation
    }

    $machineName = [Environment]::MachineName
    $localAddresses = @()

    try {
        $adapterAddresses = Get-BRAVOWmiInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = TRUE" |
            ForEach-Object { @($_.IPAddress) }

        foreach ($address in $adapterAddresses) {
            $parsedAddress = $null
            if ([System.Net.IPAddress]::TryParse([string]$address, [ref]$parsedAddress) -and
                $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not [System.Net.IPAddress]::IsLoopback($parsedAddress) -and
                -not ([string]$address).StartsWith("169.254.")) {
                $localAddresses += [string]$address
            }
        }
    } catch {
        try {
            $localAddresses = @(
                [System.Net.Dns]::GetHostAddresses($machineName) |
                    Where-Object {
                        $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                        -not [System.Net.IPAddress]::IsLoopback($_) -and
                        -not $_.ToString().StartsWith("169.254.")
                    } |
                    ForEach-Object { $_.ToString() }
            )
        } catch {
            $localAddresses = @()
        }
    }

    $localAddressText = if ($localAddresses.Count -gt 0) {
        (@($localAddresses | Sort-Object -Unique) -join ", ")
    } else {
        "недоступна"
    }

    $lookupEnabled = $true
    $lookupUrls = @("https://api.ipify.org")
    $lookupTimeoutSeconds = 5
    if ($hostInformationSettings -is [System.Collections.IDictionary]) {
        if ($hostInformationSettings.Contains("PublicIPLookupEnabled")) {
            $lookupEnabled = [System.Convert]::ToBoolean($hostInformationSettings.PublicIPLookupEnabled)
        }
        if ($hostInformationSettings.Contains("PublicIPLookupUrls")) {
            $configuredUrls = @($hostInformationSettings.PublicIPLookupUrls | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            })
            if ($configuredUrls.Count -gt 0) {
                $lookupUrls = $configuredUrls
            }
        }
        if ($hostInformationSettings.Contains("PublicIPLookupTimeoutSeconds")) {
            $lookupTimeoutSeconds = [math]::Max(
                1,
                [int]$hostInformationSettings.PublicIPLookupTimeoutSeconds
            )
        }
    }

    $publicAddressText = if ($lookupEnabled) { "недоступна" } else { "вимкнено" }
    if ($lookupEnabled) {
        foreach ($lookupUrl in $lookupUrls) {
            $response = $null
            $reader = $null
            try {
                $request = [System.Net.WebRequest]::Create([string]$lookupUrl)
                $request.Method = "GET"
                $request.Timeout = $lookupTimeoutSeconds * 1000
                $request.ReadWriteTimeout = $lookupTimeoutSeconds * 1000
                $response = $request.GetResponse()
                $reader = New-Object System.IO.StreamReader(
                    $response.GetResponseStream(),
                    [System.Text.Encoding]::UTF8
                )
                $candidateAddress = $reader.ReadToEnd().Trim()
                $parsedPublicAddress = $null
                if ([System.Net.IPAddress]::TryParse($candidateAddress, [ref]$parsedPublicAddress)) {
                    $publicAddressText = $candidateAddress
                    break
                }
            } catch {
                # Недоступність зовнішнього сервісу не впливає на health-check.
            } finally {
                if ($reader) { $reader.Dispose() }
                if ($response) { $response.Dispose() }
            }
        }
    }

    $script:CachedHostInformation = [pscustomobject]@{
        MachineName = $machineName
        LocalIP = $localAddressText
        PublicIP = $publicAddressText
    }
    return $script:CachedHostInformation
}

function ConvertTo-DiscordNotificationText {
    param([string]$Message)

    $emojiReplacements = [ordered]@{
        ":rotating_light:" = "🚨"
        ":derelict_house_building:" = "🏚️"
        ":desktop_computer:" = "🖥️"
        ":globe_with_meridians:" = "🌐"
        ":spiral_calendar_pad:" = "🗓️"
        ":alarm_clock:" = "⏰"
        ":hourglass_flowing_sand:" = "⏳"
        ":pushpin:" = "📌"
        ":cloud:" = "☁️"
        ":warning:" = "⚠️"
        ":file_folder:" = "📁"
        ":page_facing_up:" = "📄"
        ":clock3:" = "🕒"
        ":outbox_tray:" = "📤"
        ":inbox_tray:" = "📥"
        ":arrows_counterclockwise:" = "🔄"
        ":twisted_rightwards_arrows:" = "🔀"
        ":bar_chart:" = "📊"
        ":satellite_antenna:" = "📡"
        ":floppy_disk:" = "💾"
        ":memo:" = "📝"
        ":white_check_mark:" = "✅"
        ":package:" = "📦"
        ":minidisc:" = "💽"
        ":satellite:" = "🛰️"
        ":wrench:" = "🔧"
        ":x:" = "❌"
    }

    $discordMessage = $Message
    foreach ($replacement in $emojiReplacements.GetEnumerator()) {
        $discordMessage = $discordMessage.Replace($replacement.Key, $replacement.Value)
    }

    return [regex]::Replace(
        $discordMessage,
        '(?m)(?<!\*)\*([^*\r\n]+)\*(?!\*)',
        '**$1**'
    )
}

function Split-DiscordNotificationText {
    param(
        [string]$Message,
        [int]$MaximumLength = 1900
    )

    $chunks = New-Object 'System.Collections.Generic.List[string]'
    $currentChunk = New-Object System.Text.StringBuilder

    foreach ($line in ($Message -split "\r?\n")) {
        $remainingLine = [string]$line
        do {
            $availableLength = $MaximumLength - $currentChunk.Length
            if ($currentChunk.Length -gt 0) {
                $availableLength -= [Environment]::NewLine.Length
            }

            if ($availableLength -le 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
                continue
            }

            $partLength = [math]::Min($availableLength, $remainingLine.Length)
            $linePart = $remainingLine.Substring(0, $partLength)
            if ($currentChunk.Length -gt 0) {
                [void]$currentChunk.AppendLine()
            }
            [void]$currentChunk.Append($linePart)
            $remainingLine = $remainingLine.Substring($partLength)

            if ($remainingLine.Length -gt 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
            }
        } while ($remainingLine.Length -gt 0)
    }

    if ($currentChunk.Length -gt 0 -or $chunks.Count -eq 0) {
        $chunks.Add($currentChunk.ToString())
    }
    return $chunks.ToArray()
}

function Format-FileSize {
    param([Nullable[long]]$Bytes)

    if ($null -eq $Bytes) {
        return "немає даних"
    }

    if ($Bytes -ge 1TB) {
        return "$([math]::Round($Bytes / 1TB, 2)) ТБ"
    }
    if ($Bytes -ge 1GB) {
        return "$([math]::Round($Bytes / 1GB, 2)) ГБ"
    }
    if ($Bytes -ge 1MB) {
        return "$([math]::Round($Bytes / 1MB, 2)) МБ"
    }
    if ($Bytes -ge 1KB) {
        return "$([math]::Round($Bytes / 1KB, 2)) КБ"
    }
    return "$Bytes Б"
}

function Format-BackupAge {
    param([object]$LastWriteTime)

    if ($null -eq $LastWriteTime) {
        return "немає даних"
    }

    $age = (Get-Date) - [datetime]$LastWriteTime
    if ($age.TotalMinutes -lt 0) {
        return "0 хв."
    }
    if ($age.TotalHours -lt 1) {
        return "$([math]::Floor($age.TotalMinutes)) хв."
    }

    $hours = [math]::Floor($age.TotalHours)
    return "$hours год. $($age.Minutes) хв."
}

function Get-FileSHA512 {
    param([string]$Path)

    $stream = $null
    $hasher = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $hasher = [System.Security.Cryptography.SHA512]::Create()
        $hashBytes = $hasher.ComputeHash($stream)
        return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
    } finally {
        if ($stream) {
            $stream.Dispose()
        }
        if ($hasher) {
            $hasher.Dispose()
        }
    }
}

function Get-ExpectedArchiveSHA512 {
    param(
        [string]$HashPath,
        [string]$ArchiveName
    )

    $hashText = (Read-BRAVOTextFile -Path $HashPath).Trim([char]0xFEFF).Trim()
    if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
        throw "hash-файл має некоректний формат"
    }
    if ($Matches.FileName -cne $ArchiveName) {
        throw "hash-файл належить іншому архіву"
    }
    return $Matches.Hash.ToLowerInvariant()
}

function Test-BackupCandidate {
    param([System.IO.FileInfo]$Archive)

    $hashPath = "$($Archive.FullName)$hashFileExtension"
    if (-not (Test-Path -Path $hashPath -PathType Leaf)) {
        return [pscustomobject]@{
            Valid = $false
            Reason = "відсутній hash-файл"
        }
    }

    try {
        $hashText = [System.IO.File]::ReadAllText($hashPath).Trim([char]0xFEFF).Trim()
    } catch {
        return [pscustomobject]@{
            Valid = $false
            Reason = "не вдалося прочитати hash-файл: $($_.Exception.Message)"
        }
    }

    if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
        return [pscustomobject]@{
            Valid = $false
            Reason = "hash-файл має некоректний формат"
        }
    }

    if ($Matches.FileName -ne $Archive.Name) {
        return [pscustomobject]@{
            Valid = $false
            Reason = "hash-файл належить іншому архіву"
        }
    }

    if ($backupMonitoring.VerifyFileHash) {
        try {
            $actualHash = Get-FileSHA512 -Path $Archive.FullName
        } catch {
            return [pscustomobject]@{
                Valid = $false
                Reason = "не вдалося обчислити SHA512: $($_.Exception.Message)"
            }
        }

        if ($actualHash -ne $Matches.Hash.ToLowerInvariant()) {
            return [pscustomobject]@{
                Valid = $false
                Reason = "SHA512 архіву не збігається"
            }
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Reason = ""
    }
}

function Test-ArchiveFileName {
    param(
        [string]$FileName,
        [hashtable]$ArchiveDefinition
    )

    # Ім'я має точно відповідати шаблону, який використовує BRAVO_ARCHIV.ps1.
    # Завдяки цьому архіви BRAVO_MAINTENANCE.ps1 з частинами _before_ та _after_
    # не потрапляють до кандидатів health-check.
    $timestampToken = "__BRAVO_ARCHIVE_TIMESTAMP__"
    try {
        $nameWithToken = [string]$ArchiveDefinition.NameTemplate -f $archivePrefix, $timestampToken
    } catch {
        return $false
    }

    $escapedName = [regex]::Escape($nameWithToken)
    $escapedToken = [regex]::Escape($timestampToken)
    $namePattern = "^$($escapedName.Replace($escapedToken, '(?<Timestamp>.+)'))$"
    $nameMatch = [regex]::Match(
        $FileName,
        $namePattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $nameMatch.Success) {
        return $false
    }

    $parsedTimestamp = [datetime]::MinValue
    return [datetime]::TryParseExact(
        $nameMatch.Groups["Timestamp"].Value,
        $archiveTimestampFormat,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsedTimestamp
    )
}

function Get-LocalBackupState {
    param([hashtable]$ArchiveDefinition)

    $candidateLimit = [math]::Max(1, [int]$backupMonitoring.CandidateLimit)
    $candidates = @()
    if (Test-Path -Path $ArchiveDefinition.Destination -PathType Container) {
        $candidates = @(
            Get-BRAVOFiles -Path $ArchiveDefinition.Destination -Filter $archiveFileFilter |
                Where-Object { Test-ArchiveFileName -FileName $_.Name -ArchiveDefinition $ArchiveDefinition } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First $candidateLimit
        )
    }

    $newestValidArchive = $null
    foreach ($candidate in $candidates) {
        $candidateResult = Test-BackupCandidate -Archive $candidate
        if ($candidateResult.Valid) {
            $newestValidArchive = $candidate
            break
        }
    }

    return [pscustomobject]@{
        Candidates = $candidates
        NewestValidArchive = $newestValidArchive
    }
}

function Get-BackupHealthIssues {
    $issues = @()
    $enabledArchiveDefinitions = @($archiveDefinitions | Where-Object { $_.Enabled })
    $maximumAge = [timespan]::FromHours([double]$backupMonitoring.MaxBackupAgeHours)

    foreach ($archiveDefinition in $enabledArchiveDefinitions) {
        $localState = Get-LocalBackupState -ArchiveDefinition $archiveDefinition
        $candidates = @($localState.Candidates)

        if ($candidates.Count -eq 0) {
            $expectedArchiveName = [string]$archiveDefinition.NameTemplate -f $archivePrefix, $archiveTimestampFormat
            $issues += [pscustomobject]@{
                Kind = "LocalBackup"
                Component = $archiveDefinition.Type
                Reason = "резервну копію не знайдено"
                FileName = "не знайдено ($expectedArchiveName)"
                LastWriteTime = $null
                SizeBytes = $null
            }
            continue
        }

        $newestValidArchive = $localState.NewestValidArchive

        if ($null -eq $newestValidArchive) {
            $newestCandidate = $candidates[0]
            $newestCandidateResult = Test-BackupCandidate -Archive $newestCandidate
            $issues += [pscustomobject]@{
                Kind = "LocalBackup"
                Component = $archiveDefinition.Type
                Reason = "немає коректної резервної копії: $($newestCandidateResult.Reason)"
                FileName = $newestCandidate.Name
                LastWriteTime = $newestCandidate.LastWriteTime
                SizeBytes = $newestCandidate.Length
            }
            continue
        }

        $backupAge = $healthCheckStarted - $newestValidArchive.LastWriteTime
        if ($backupAge -gt $maximumAge) {
            $newerInvalidCount = @($candidates | Where-Object { $_.LastWriteTime -gt $newestValidArchive.LastWriteTime }).Count
            $reason = "остання коректна копія старша за $($backupMonitoring.MaxBackupAgeHours) год."
            if ($newerInvalidCount -gt 0) {
                $reason += "; новіші файли не пройшли перевірку"
            }

            $issues += [pscustomobject]@{
                Kind = "LocalBackup"
                Component = $archiveDefinition.Type
                Reason = $reason
                FileName = $newestValidArchive.Name
                LastWriteTime = $newestValidArchive.LastWriteTime
                SizeBytes = $newestValidArchive.Length
            }
        } else {
            $script:healthLatestArchives[$archiveDefinition.Type] = [pscustomobject]@{
                Name = $newestValidArchive.Name
                SizeBytes = [long]$newestValidArchive.Length
            }
            Write-HealthLog "Бекап $($archiveDefinition.Type) справний: $($newestValidArchive.Name), вік $(Format-BackupAge $newestValidArchive.LastWriteTime), розмір $(Format-FileSize $newestValidArchive.Length)" -Level "SUCCESS"
        }
    }

    return @($issues)
}

function Get-BAZALocalHealthIssues {
    if (-not $bazaLocalHealthEnabled) {
        return @()
    }

    $sourcePath = [string]$bazaPaths.Source
    $destinationPath = [string]$bazaPaths.Destination
    $issueBase = @{
        Kind = "LocalSynchronization"
        Component = "Локальна BAZA"
        FileName = "каталог BAZA"
        LastWriteTime = $null
        SizeBytes = $null
        DifferenceCount = $null
        Details = @()
        Source = $sourcePath
        Location = $destinationPath
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        return @([pscustomobject]($issueBase + @{
            Reason = "джерельний каталог BAZA не знайдено"
        }))
    }

    if ([bool]$synchronizationSafety.RequireNonEmptyBAZASource) {
        $firstSourceFile = Get-BRAVOFiles `
            -LiteralPath $sourcePath `
            -Recurse `
            -Force `
            |
            Select-Object -First 1
        if ($null -eq $firstSourceFile) {
            return @([pscustomobject]($issueBase + @{
                Reason = "джерельний каталог BAZA порожній"
            }))
        }
    }

    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
        return @([pscustomobject]($issueBase + @{
            Reason = "локальну копію BAZA не знайдено"
        }))
    }

    $robocopyCommand = Get-Command -Name $robocopyPath -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $robocopyCommand) {
        return @([pscustomobject]($issueBase + @{
            Reason = "robocopy не знайдено; локальну BAZA не перевірено"
        }))
    }

    $process = $null
    try {
        # /L гарантує read-only перевірку. /E відповідає режиму, який
        # BRAVO_ARCHIV.ps1 використовує для локальної копії BAZA.
        $arguments = @(
            "`"$sourcePath`"",
            "`"$destinationPath`"",
            "/E",
            "/L",
            "/R:0",
            "/W:0",
            "/XJ",
            "/NFL",
            "/NDL",
            "/NJH",
            "/NJS",
            "/NP",
            "/LOG:NUL"
        )
        $process = Start-Process `
            -FilePath $robocopyCommand.Source `
            -ArgumentList $arguments `
            -PassThru `
            -WindowStyle Hidden

        $timeoutSeconds = [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                Write-HealthLog "Не вдалося завершити robocopy після таймауту: $($_.Exception.Message)" -Level "DEBUG"
            }
            return @([pscustomobject]($issueBase + @{
                Reason = "перевищено таймаут локальної перевірки BAZA ($timeoutSeconds сек.)"
            }))
        }

        $exitCode = [int]$process.ExitCode
        if (($exitCode -band 24) -ne 0) {
            return @([pscustomobject]($issueBase + @{
                Reason = "robocopy не зміг порівняти каталоги (код: $exitCode)"
                ExitCode = $exitCode
            }))
        }

        # 1 = є файли для копіювання, 4 = є невідповідності.
        # Біт 2 (зайві файли у призначенні) не є помилкою, бо робоча
        # синхронізація використовує /E, а не /MIR.
        if (($exitCode -band 5) -ne 0) {
            return @([pscustomobject]($issueBase + @{
                Reason = "локальна копія BAZA неактуальна"
                ExitCode = $exitCode
            }))
        }

        Write-HealthLog "Локальна BAZA справна: $sourcePath відповідає $destinationPath" -Level "SUCCESS"
        return @()
    } catch {
        return @([pscustomobject]($issueBase + @{
            Reason = "не вдалося порівняти локальну BAZA: $($_.Exception.Message)"
        }))
    } finally {
        if ($process) {
            $process.Dispose()
        }
    }
}

function Normalize-SFTPPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "/"
    }

    $normalized = $Path.Replace("\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return "/"
    }
    return "/$normalized"
}

function Test-BRAVOPathWithinDirectory {
    param(
        [string]$Path,
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        [string]::IsNullOrWhiteSpace($Directory)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
        $directoryPrefix = $fullDirectory.TrimEnd("\", "/") +
            [System.IO.Path]::DirectorySeparatorChar
        return $fullPath.StartsWith(
            $directoryPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        return $false
    }
}

function Test-BRAVOAsciiPath {
    param([string]$Path)

    return (
        -not [string]::IsNullOrWhiteSpace($Path) -and
        $Path -notmatch '[^\x00-\x7F]'
    )
}

function Get-BRAVOHealthTemporaryRoot {
    if (-not [string]::IsNullOrWhiteSpace(
            [string]$script:bravoHealthTemporaryRoot
        ) -and
        (Test-Path `
            -LiteralPath $script:bravoHealthTemporaryRoot `
            -PathType Container)) {
        return $script:bravoHealthTemporaryRoot
    }

    $candidateRoots = @(
        (Join-Path $bravoScriptDirectory "TEMP")
    )
    $commonApplicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData
    )
    if (-not [string]::IsNullOrWhiteSpace($commonApplicationData)) {
        $candidateRoots += Join-Path $commonApplicationData "BRAVO\TEMP"
    }
    $systemTemporaryRoot = [System.IO.Path]::GetTempPath()
    if (Test-BRAVOAsciiPath -Path $systemTemporaryRoot) {
        $candidateRoots += Join-Path $systemTemporaryRoot "BRAVO"
    }

    $creationErrors = @()
    foreach ($candidateRoot in @($candidateRoots | Select-Object -Unique)) {
        if (-not (Test-BRAVOAsciiPath -Path $candidateRoot)) {
            continue
        }
        try {
            if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) {
                New-Item `
                    -ItemType Directory `
                    -Path $candidateRoot `
                    -Force `
                    -ErrorAction Stop |
                    Out-Null
            }
            $resolvedRoot = (Resolve-Path `
                -LiteralPath $candidateRoot `
                -ErrorAction Stop).Path
            if (Test-BRAVOAsciiPath -Path $resolvedRoot) {
                $script:bravoHealthTemporaryRoot = $resolvedRoot
                return $resolvedRoot
            }
        } catch {
            $creationErrors += "$candidateRoot`: $($_.Exception.Message)"
        }
    }

    $details = if ($creationErrors.Count -gt 0) {
        "; " + ($creationErrors -join "; ")
    } else {
        ""
    }
    throw (
        "не знайдено доступного ASCII-каталогу для тимчасових файлів " +
        "WinSCP$details"
    )
}

function Remove-BRAVOHealthTemporaryDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $leafName = Split-Path -Path $fullPath -Leaf
        $allowedRoots = @(
            [System.IO.Path]::GetTempPath()
        )
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$script:bravoHealthTemporaryRoot
            )) {
            $allowedRoots += $script:bravoHealthTemporaryRoot
        }
        $isWithinAllowedRoot = $false
        foreach ($allowedRoot in @($allowedRoots | Select-Object -Unique)) {
            if (Test-BRAVOPathWithinDirectory `
                -Path $fullPath `
                -Directory $allowedRoot) {
                $isWithinAllowedRoot = $true
                break
            }
        }
        $isSafeTarget = (
            $isWithinAllowedRoot -and
            $leafName -match '^BRAVO_HEALTH_[0-9a-f]{32}$'
        )
        if (-not $isSafeTarget) {
            Write-HealthLog "Пропущено очищення неочікуваного тимчасового шляху: $fullPath" -Level "WARNING"
            return
        }
        if ([System.IO.Directory]::Exists($fullPath)) {
            [System.IO.Directory]::Delete($fullPath, $true)
        }
    } catch {
        Write-HealthLog "Не вдалося очистити тимчасовий каталог health-check: $($_.Exception.Message)" -Level "WARNING"
    }
}

function ConvertTo-WinSCPScriptArgument {
    param([string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-CompactWinSCPError {
    param(
        [string]$Text,
        [int]$MaximumLength = 300
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "немає деталей"
    }
    if ($Text -match '(?i)Server refused to start a shell/command') {
        return "SFTP-сервер забороняє серверний checksum/shell"
    }

    $compact = ($Text -replace '(?i)Authentication log.*$', '') -replace '\s+', ' '
    $compact = $compact.Trim(" ", ";", ".")
    $safeMaximumLength = [math]::Max(40, $MaximumLength)
    if ($compact.Length -gt $safeMaximumLength) {
        return $compact.Substring(0, $safeMaximumLength - 3) + "..."
    }
    return $compact
}

function Test-SFTPHealthConfiguration {
    param(
        [bool]$CheckArchives,
        [bool]$CheckBAZA,
        [bool]$CheckBAZAWWW
    )

    $errors = @()
    if (-not [string]::IsNullOrWhiteSpace($sftpCredentialError)) {
        $errors += $sftpCredentialError
    }
    if ([string]::IsNullOrWhiteSpace($Login)) {
        $errors += "не завантажено SFTP логін з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace($sftpUrl) -or -not $sftpUrl.StartsWith("sftp://")) {
        $errors += "не вдалося сформувати SFTP URL із захищених облікових даних"
    }
    if ([string]::IsNullOrWhiteSpace($sftpHostKey)) {
        $errors += "не встановлено SFTP host key"
    }
    if ([string]::IsNullOrWhiteSpace($winSCPPath) -or -not (Test-Path -Path $winSCPPath -PathType Leaf)) {
        $errors += "не знайдено WinSCP"
    }
    if ([int]$backupMonitoring.SFTP.OperationTimeoutSeconds -le 0) {
        $errors += "таймаут SFTP-перевірки повинен бути більшим за 0"
    }

    if ($CheckArchives) {
        if ([double]$backupMonitoring.SFTP.RemoteBackupMaxAgeHours -le 0) {
            $errors += "максимальний вік віддаленого бекапу повинен бути більшим за 0"
        }
        foreach ($archiveDefinition in @($archiveDefinitions | Where-Object { $_.Enabled })) {
            if (-not $sftpDirectories.ContainsKey($archiveDefinition.Type) -or
                [string]::IsNullOrWhiteSpace($sftpDirectories[$archiveDefinition.Type])) {
                $errors += "не встановлено SFTP каталог для $($archiveDefinition.Type)"
            }
        }
    }

    if ($CheckBAZA -and
        (-not $sftpDirectories.ContainsKey("BAZA") -or [string]::IsNullOrWhiteSpace($sftpDirectories.BAZA))) {
        $errors += "не встановлено SFTP каталог для BAZA"
    }
    if ($CheckBAZAWWW -and
        (-not $sftpDirectories.ContainsKey("BAZAWWW") -or
        [string]::IsNullOrWhiteSpace($sftpDirectories.BAZAWWW))) {
        $errors += "не встановлено SFTP каталог для BAZA WWW"
    }
    $checkFolderSynchronization = $CheckBAZA -or $CheckBAZAWWW
    if ($checkFolderSynchronization -and
        ([string]::IsNullOrWhiteSpace($backupMonitoring.SFTP.BAZAPreviewOptions) -or
        $backupMonitoring.SFTP.BAZAPreviewOptions -notmatch '(?i)(^|\s)-preview(\s|$)')) {
        $errors += "BAZAPreviewOptions обов'язково повинен містити -preview"
    }
    if ($checkFolderSynchronization -and
        [string]$backupMonitoring.SFTP.BAZAPreviewOptions -match '(?i)(^|\s)-delete(\s|$)') {
        $errors += "опція -delete заборонена для BAZA: віддалені файли мають зберігатися для відновлення"
    }
    if ($checkFolderSynchronization -and
        [string]$sftpSynchronizationOptions -match '(?i)(^|\s)-delete(\s|$)') {
        $errors += "sftpSynchronizationOptions містить заборонену опцію -delete для BAZA"
    }
    if ($checkFolderSynchronization -and
        [int]$backupMonitoring.SFTP.DifferenceDetailLimit -le 0) {
        $errors += "ліміт деталей SFTP-розбіжностей повинен бути більшим за 0"
    }
    return [pscustomobject]@{
        Valid = $errors.Count -eq 0
        Errors = @($errors)
    }
}

function Get-WinSCPDotNetComponents {
    if ($null -ne $script:WinSCPDotNetComponents) {
        return $script:WinSCPDotNetComponents
    }

    $assemblyCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPAssemblyPath)) {
        $assemblyCandidates += [string]$winSCPAssemblyPath
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
        $assemblyCandidates += Join-Path (Split-Path -Path $winSCPPath -Parent) "WinSCPnet.dll"
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $assemblyCandidates += Join-Path ${env:ProgramFiles(x86)} "WinSCP\WinSCPnet.dll"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $assemblyCandidates += Join-Path $env:ProgramFiles "WinSCP\WinSCPnet.dll"
    }

    foreach ($assemblyPath in @($assemblyCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            continue
        }
        $executablePath = Join-Path (Split-Path -Path $assemblyPath -Parent) "WinSCP.exe"
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            continue
        }

        $script:WinSCPDotNetComponents = [pscustomobject]@{
            AssemblyPath = (Resolve-Path -LiteralPath $assemblyPath).Path
            ExecutablePath = (Resolve-Path -LiteralPath $executablePath).Path
        }
        return $script:WinSCPDotNetComponents
    }

    return $null
}

function Get-SFTPRemoteArchiveChecksumResults {
    param([object[]]$ArchiveChecks)

    $results = @{}
    foreach ($archiveCheck in @($ArchiveChecks)) {
        $results[$archiveCheck.LocalArchive.FullName] = [pscustomobject]@{
            Success = $false
            Hash = $null
            Algorithm = $null
            Error = "перевірку контрольної суми не виконано"
        }
    }

    $components = Get-WinSCPDotNetComponents
    if ($null -eq $components) {
        Write-HealthLog (
            "WinSCPnet.dll + WinSCP.exe недоступні; " +
            "контрольні суми SFTP перевіряються через WinSCP.com"
        ) -Level "INFO"
        return Get-SFTPRemoteArchiveChecksumResultsViaCli -ArchiveChecks $ArchiveChecks
    }

    $session = $null
    $serverChecksumUnavailable = $false
    try {
        if (-not ("WinSCP.Session" -as [type])) {
            Add-Type -Path $components.AssemblyPath -ErrorAction Stop
        }
        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.ParseUrl($sftpUrl)
        $sessionOptions.SshHostKeyFingerprint = ([string]$sftpHostKey).Trim().Trim('"')
        $sessionOptions.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds)
        )

        $session = New-Object WinSCP.Session
        $session.ExecutablePath = $components.ExecutablePath
        $session.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        )
        $session.Open($sessionOptions)

        foreach ($archiveCheck in @($ArchiveChecks)) {
            $key = $archiveCheck.LocalArchive.FullName
            if ($serverChecksumUnavailable) {
                $results[$key].Error =
                    "SFTP-сервер забороняє серверний checksum/shell"
                continue
            }
            $remoteArchivePath = "{0}/{1}" -f `
                $archiveCheck.RemoteDirectory.TrimEnd('/'), `
                $archiveCheck.LocalArchive.Name
            $algorithmErrors = @()
            foreach ($algorithm in @("sha-512", "sha-256")) {
                try {
                    $checksumBytes = $session.CalculateFileChecksum($algorithm, $remoteArchivePath)
                    $results[$key] = [pscustomobject]@{
                        Success = $true
                        Hash = [System.BitConverter]::ToString($checksumBytes).Replace("-", "").ToLowerInvariant()
                        Algorithm = $algorithm
                        Error = $null
                    }
                    break
                } catch {
                    $algorithmError = $_.Exception.Message
                    $algorithmErrors += "${algorithm}: $algorithmError"
                    if ($algorithmError -match '(?i)Server refused to start a shell/command') {
                        $serverChecksumUnavailable = $true
                        break
                    }
                }
            }
            if (-not $results[$key].Success) {
                $results[$key] = [pscustomobject]@{
                    Success = $false
                    Hash = $null
                    Algorithm = $null
                    Error = $algorithmErrors -join "; "
                }
            }
        }
    } catch {
        foreach ($archiveCheck in @($ArchiveChecks)) {
            $key = $archiveCheck.LocalArchive.FullName
            if (-not $results[$key].Success) {
                $results[$key].Error = $_.Exception.Message
            }
        }
    } finally {
        if ($session) {
            $session.Dispose()
        }
    }

    $failedChecks = @(
        $ArchiveChecks |
            Where-Object { -not $results[$_.LocalArchive.FullName].Success }
    )
    if ($failedChecks.Count -gt 0 -and $serverChecksumUnavailable) {
        Write-HealthLog (
            "SFTP-сервер не підтримує серверний checksum; " +
            "перевірка архівів продовжується через віддалені .sha512"
        ) -Level "INFO"
    } elseif ($failedChecks.Count -gt 0) {
        Write-HealthLog (
            "Для $($failedChecks.Count) SFTP-архівів перевірка через WinSCP .NET " +
            "не вдалася; використовується WinSCP.com"
        ) -Level "WARNING"
        $cliResults = Get-SFTPRemoteArchiveChecksumResultsViaCli `
            -ArchiveChecks $failedChecks
        foreach ($archiveCheck in $failedChecks) {
            $key = $archiveCheck.LocalArchive.FullName
            if ($cliResults[$key].Success) {
                $results[$key] = $cliResults[$key]
            } else {
                $dotNetError = [string]$results[$key].Error
                $cliError = [string]$cliResults[$key].Error
                $results[$key].Error =
                    ".NET: $dotNetError; WinSCP.com: $cliError"
            }
        }
    }

    return $results
}

function Invoke-WinSCPHealthSession {
    param([string[]]$Commands)

    $temporaryName = "BRAVO_ARCHIV_HEALTH_$([guid]::NewGuid().ToString('N'))"
    # WinSCP-командний файл може навмисно використовувати ASCII для сумісності
    # зі старими версіями клієнта. Тому всі вставлені в нього локальні шляхи,
    # а також службові файли сеансу тримаємо в гарантовано ASCII-каталозі.
    $temporaryRoot = Get-BRAVOHealthTemporaryRoot
    $temporaryScriptPath = Join-Path $temporaryRoot "$temporaryName.txt"
    $temporaryXmlPath = Join-Path $temporaryRoot "$temporaryName.xml"
    $process = $null

    try {
        $scriptLines = @(
            "option batch continue",
            "option confirm off",
            "open $sftpUrl -hostkey=$sftpHostKey -timeout=$sftpConnectionTimeoutSeconds"
        )
        $scriptLines += @($Commands)
        $scriptLines += "exit"

        $scriptEncoding = [System.Text.Encoding]::GetEncoding($winSCPScriptEncoding)
        [System.IO.File]::WriteAllLines($temporaryScriptPath, $scriptLines, $scriptEncoding)

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $winSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /xmllog=`"$temporaryXmlPath`" /xmlgroups /script=`"$temporaryScriptPath`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $winSCPPath
        if (-not $winSCPAvailability.Available) {
            throw (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "SFTP health-check")
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process

        $timeoutSeconds = [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        $completed = $process.WaitForExit($timeoutSeconds * 1000)
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                Write-HealthLog "Не вдалося завершити WinSCP після таймауту: $($_.Exception.Message)" -Level "DEBUG"
            }
            if ($null -ne $outputCapture) {
                [void](Complete-BRAVOProcessOutputCapture -Capture $outputCapture)
                $outputCapture = $null
            }
            throw "перевищено таймаут SFTP-перевірки ($timeoutSeconds сек.)"
        }

        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError

        if (-not (Test-Path -Path $temporaryXmlPath -PathType Leaf)) {
            throw "WinSCP не створив XML-журнал (код: $($process.ExitCode))"
        }

        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.Load($temporaryXmlPath)
        } catch {
            throw "не вдалося прочитати XML-журнал WinSCP: $($_.Exception.Message)"
        }

        if ($process.ExitCode -ne 0) {
            Write-HealthLog "WinSCP health-check завершився з кодом $($process.ExitCode); аналізуємо доступні XML-результати" -Level "WARNING"
        }

        return [pscustomobject]@{
            Success = $true
            ExitCode = $process.ExitCode
            Xml = $xml
            Output = $output
            ErrorOutput = $errorOutput
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            ExitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { $null }
            Xml = $null
            Output = ""
            ErrorOutput = ""
            Error = $_.Exception.Message
        }
    } finally {
        foreach ($temporaryPath in @($temporaryScriptPath, $temporaryXmlPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
        if ($process) {
            $process.Dispose()
        }
    }
}

function New-WinSCPNamespaceManager {
    param([System.Xml.XmlDocument]$Xml)

    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $namespaceManager.AddNamespace("w", "http://winscp.net/schema/session/1.0")
    return ,$namespaceManager
}

function Get-WinSCPXmlFailureText {
    param(
        [System.Xml.XmlDocument]$Xml,
        [int]$MaximumMessages = 5
    )

    if ($null -eq $Xml) {
        return ""
    }

    $namespaceManager = New-WinSCPNamespaceManager -Xml $Xml
    $messages = @(
        $Xml.SelectNodes("//w:failure/w:message", $namespaceManager) |
            ForEach-Object { ([string]$_.InnerText).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique -First ([math]::Max(1, $MaximumMessages))
    )
    return $messages -join "; "
}

function Get-SFTPRemoteArchiveChecksumResultsViaCli {
    param([object[]]$ArchiveChecks)

    $results = @{}
    $errorsByKey = @{}
    foreach ($archiveCheck in @($ArchiveChecks)) {
        $key = $archiveCheck.LocalArchive.FullName
        $results[$key] = [pscustomobject]@{
            Success = $false
            Hash = $null
            Algorithm = $null
            Error = "WinSCP.com не повернув контрольну суму"
        }
        $errorsByKey[$key] = @()
    }

    # SHA512 є основним алгоритмом. SHA256 запускається другим окремим
    # проходом лише для тих серверів/файлів, де SHA512 недоступний.
    foreach ($algorithm in @("sha-512", "sha-256")) {
        $pendingChecks = @(
            $ArchiveChecks |
                Where-Object { -not $results[$_.LocalArchive.FullName].Success }
        )
        if ($pendingChecks.Count -eq 0) {
            break
        }

        $commands = @(
            $pendingChecks |
                ForEach-Object {
                    $remoteArchivePath = "{0}/{1}" -f `
                        $_.RemoteDirectory.TrimEnd('/'), `
                        $_.LocalArchive.Name
                    "checksum $algorithm $(ConvertTo-WinSCPScriptArgument $remoteArchivePath)"
                }
        )
        $sessionResult = Invoke-WinSCPHealthSession -Commands $commands
        if (-not $sessionResult.Success) {
            foreach ($archiveCheck in $pendingChecks) {
                $key = $archiveCheck.LocalArchive.FullName
                $errorsByKey[$key] += "${algorithm}: $($sessionResult.Error)"
            }
            continue
        }

        $namespaceManager = New-WinSCPNamespaceManager -Xml $sessionResult.Xml
        $checksumNodes = @(
            $sessionResult.Xml.SelectNodes("//w:checksum", $namespaceManager)
        )
        $failureText = Get-WinSCPXmlFailureText -Xml $sessionResult.Xml
        $serverCommandUnavailable = (
            $algorithm -eq "sha-512" -and
            $failureText -match '(?i)Server refused to start a shell/command'
        )
        $expectedLength = if ($algorithm -eq "sha-512") { 128 } else { 64 }

        foreach ($archiveCheck in $pendingChecks) {
            $key = $archiveCheck.LocalArchive.FullName
            $remoteArchivePath = Normalize-SFTPPath (
                "{0}/{1}" -f `
                    $archiveCheck.RemoteDirectory.TrimEnd('/'), `
                    $archiveCheck.LocalArchive.Name
            )
            $matchingNode = @(
                $checksumNodes |
                    Where-Object {
                        $fileNode = $_.SelectSingleNode("w:filename", $namespaceManager)
                        $algorithmNode = $_.SelectSingleNode("w:algorithm", $namespaceManager)
                        $resultNode = $_.SelectSingleNode("w:result", $namespaceManager)
                        $fileNode -and
                            $algorithmNode -and
                            $resultNode -and
                            $resultNode.GetAttribute("success") -eq "true" -and
                            (Normalize-SFTPPath ($fileNode.GetAttribute("value"))) -ceq $remoteArchivePath -and
                            $algorithmNode.GetAttribute("value") -ieq $algorithm
                    } |
                    Select-Object -First 1
            )
            if ($matchingNode.Count -eq 0) {
                $errorText = if (-not [string]::IsNullOrWhiteSpace($failureText)) {
                    $failureText
                } else {
                    "контрольну суму не повернуто (код: $($sessionResult.ExitCode))"
                }
                $errorsByKey[$key] += "${algorithm}: $errorText"
                continue
            }

            $hashNode = $matchingNode[0].SelectSingleNode(
                "w:checksum",
                $namespaceManager
            )
            $hashValue = if ($hashNode) {
                $hashNode.GetAttribute("value").Replace("-", "").ToLowerInvariant()
            } else {
                ""
            }
            if ($hashValue -notmatch "^[0-9a-f]{$expectedLength}$") {
                $errorsByKey[$key] += "${algorithm}: WinSCP.com повернув некоректний формат контрольної суми"
                continue
            }

            $results[$key] = [pscustomobject]@{
                Success = $true
                Hash = $hashValue
                Algorithm = $algorithm
                Error = $null
            }
        }

        if ($serverCommandUnavailable) {
            # Коли хостинг повністю забороняє запуск shell/command, повторна
            # спроба з іншим алгоритмом завершиться тією самою помилкою.
            break
        }
    }

    foreach ($archiveCheck in @($ArchiveChecks)) {
        $key = $archiveCheck.LocalArchive.FullName
        if (-not $results[$key].Success) {
            $errorParts = @($errorsByKey[$key] | Select-Object -Unique)
            $results[$key].Error = if ($errorParts.Count -gt 0) {
                $errorParts -join "; "
            } else {
                "WinSCP.com не повернув підтримувану SHA512/SHA256 контрольну суму"
            }
        }
    }

    return $results
}

function Get-WinSCPRemoteListings {
    param([System.Xml.XmlDocument]$Xml)

    $namespaceManager = New-WinSCPNamespaceManager -Xml $Xml
    $listings = @()

    foreach ($listingNode in @($Xml.SelectNodes("//w:ls", $namespaceManager))) {
        $destinationNode = $listingNode.SelectSingleNode("w:destination", $namespaceManager)
        $resultNode = $listingNode.SelectSingleNode("w:result", $namespaceManager)
        $files = @()

        foreach ($fileNode in @($listingNode.SelectNodes("w:files/w:file", $namespaceManager))) {
            $nameNode = $fileNode.SelectSingleNode("w:filename", $namespaceManager)
            $typeNode = $fileNode.SelectSingleNode("w:type", $namespaceManager)
            $sizeNode = $fileNode.SelectSingleNode("w:size", $namespaceManager)
            $modificationNode = $fileNode.SelectSingleNode("w:modification", $namespaceManager)
            $lastWriteTime = $null

            if ($modificationNode -and -not [string]::IsNullOrWhiteSpace($modificationNode.GetAttribute("value"))) {
                try {
                    $lastWriteTime = [datetimeoffset]::Parse(
                        $modificationNode.GetAttribute("value"),
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind
                    ).LocalDateTime
                } catch {
                    $lastWriteTime = $null
                }
            }

            $size = $null
            if ($sizeNode -and $sizeNode.GetAttribute("value") -match '^\d+$') {
                $size = [long]$sizeNode.GetAttribute("value")
            }

            $files += [pscustomobject]@{
                Name = if ($nameNode) { $nameNode.GetAttribute("value") } else { "" }
                Type = if ($typeNode) { $typeNode.GetAttribute("value") } else { "" }
                SizeBytes = $size
                LastWriteTime = $lastWriteTime
            }
        }

        $listings += [pscustomobject]@{
            Destination = if ($destinationNode) { Normalize-SFTPPath $destinationNode.GetAttribute("value") } else { "/" }
            Success = $resultNode -and $resultNode.GetAttribute("success") -eq "true"
            Files = @($files)
        }
    }

    return @($listings)
}

function Get-WinSCPRemoteDownloads {
    param([System.Xml.XmlDocument]$Xml)

    $namespaceManager = New-WinSCPNamespaceManager -Xml $Xml
    $downloads = @()
    foreach ($downloadNode in @(
        $Xml.SelectNodes("//w:download", $namespaceManager)
    )) {
        $fileNode = $downloadNode.SelectSingleNode("w:filename", $namespaceManager)
        $destinationNode = $downloadNode.SelectSingleNode(
            "w:destination",
            $namespaceManager
        )
        $resultNode = $downloadNode.SelectSingleNode("w:result", $namespaceManager)
        $messages = if ($resultNode) {
            @(
                $resultNode.SelectNodes("w:message", $namespaceManager) |
                    ForEach-Object { ([string]$_.InnerText).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        } else {
            @()
        }

        $downloads += [pscustomobject]@{
            RemotePath = if ($fileNode) {
                Normalize-SFTPPath ($fileNode.GetAttribute("value"))
            } else {
                ""
            }
            LocalPath = if ($destinationNode) {
                [Environment]::ExpandEnvironmentVariables(
                    $destinationNode.GetAttribute("value")
                )
            } else {
                ""
            }
            Success = $resultNode -and
                $resultNode.GetAttribute("success") -eq "true"
            Error = $messages -join "; "
        }
    }
    return @($downloads)
}

function Resolve-DownloadedRemoteHashPath {
    param(
        [object]$ArchiveCheck,
        [object[]]$Downloads
    )

    $remoteHashPath = Normalize-SFTPPath (
        "{0}/{1}{2}" -f `
            $ArchiveCheck.RemoteDirectory.TrimEnd('/'), `
            $ArchiveCheck.LocalArchive.Name, `
            $hashFileExtension
    )
    $download = @(
        $Downloads |
            Where-Object { $_.RemotePath -ceq $remoteHashPath } |
            Select-Object -Last 1
    )

    $candidatePaths = @()
    if ($download.Count -gt 0 -and $download[0].Success) {
        $candidatePaths += [string]$download[0].LocalPath
    }
    $candidatePaths += [string]$ArchiveCheck.RemoteHashDownloadPath

    foreach ($candidatePath in @(
        $candidatePaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )) {
        if ((Test-BRAVOPathWithinDirectory `
                -Path $candidatePath `
                -Directory $ArchiveCheck.RemoteHashDownloadDirectory) -and
            (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            return [pscustomobject]@{
                Path = (Resolve-Path -LiteralPath $candidatePath).Path
                Error = $null
            }
        }
    }

    # Старі версії WinSCP можуть застосувати operation mask і повернути інше
    # ім'я призначення. Каталог унікальний для одного sidecar, тому безпечно
    # знайти фактично створений файл у його межах.
    $createdFiles = if (Test-Path `
        -LiteralPath $ArchiveCheck.RemoteHashDownloadDirectory `
        -PathType Container) {
        @(
            Get-ChildItem `
                -LiteralPath $ArchiveCheck.RemoteHashDownloadDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    -not $_.PSIsContainer -and
                    $_.Name -ceq "$($ArchiveCheck.LocalArchive.Name)$hashFileExtension"
                }
        )
    } else {
        @()
    }
    if ($createdFiles.Count -eq 1 -and
        (Test-BRAVOPathWithinDirectory `
            -Path $createdFiles[0].FullName `
            -Directory $ArchiveCheck.RemoteHashDownloadDirectory)) {
        return [pscustomobject]@{
            Path = $createdFiles[0].FullName
            Error = $null
        }
    }

    $downloadError = if ($download.Count -eq 0) {
        "XML-журнал WinSCP не містить операції download для $remoteHashPath"
    } elseif (-not $download[0].Success) {
        if ([string]::IsNullOrWhiteSpace([string]$download[0].Error)) {
            "WinSCP позначив download як невдалий"
        } else {
            [string]$download[0].Error
        }
    } else {
        "WinSCP повідомив успішний download, але локальний файл не знайдено; destination=$($download[0].LocalPath)"
    }
    return [pscustomobject]@{
        Path = $null
        Error = $downloadError
    }
}

function Test-SFTPArchiveCopy {
    param(
        [hashtable]$ArchiveDefinition,
        [object]$LocalArchive,
        [object]$RemoteListing,
        [string]$RemoteDirectory,
        [string]$DownloadedRemoteHashPath,
        [object]$RemoteArchiveChecksumResult
    )

    $remotePath = Normalize-SFTPPath $RemoteDirectory
    if ($null -eq $RemoteListing -or -not $RemoteListing.Success) {
        return [pscustomobject]@{
            Kind = "SFTPArchive"
            Component = "SFTP $($ArchiveDefinition.Type)"
            Reason = "не вдалося прочитати віддалений каталог"
            FileName = $LocalArchive.Name
            LastWriteTime = $null
            SizeBytes = $null
            ExpectedSizeBytes = [long]$LocalArchive.Length
            ActualSizeBytes = $null
            Location = $remotePath
        }
    }

    $remoteArchive = @($RemoteListing.Files | Where-Object { $_.Name -ceq $LocalArchive.Name -and $_.Type -ne "d" } | Select-Object -First 1)
    $remoteHashName = "$($LocalArchive.Name)$hashFileExtension"
    $remoteHash = @($RemoteListing.Files | Where-Object { $_.Name -ceq $remoteHashName -and $_.Type -ne "d" } | Select-Object -First 1)
    $problems = @()
    $remoteArchiveHashVerified = $false
    $remoteHashSidecarVerified = $false

    if ($remoteArchive.Count -eq 0) {
        $problems += "архів відсутній"
    } elseif ($null -eq $remoteArchive[0].SizeBytes -or [long]$remoteArchive[0].SizeBytes -ne [long]$LocalArchive.Length) {
        $problems += "розмір архіву не збігається"
    }

    $localHashPath = "$($LocalArchive.FullName)$hashFileExtension"
    $localHashSize = if (Test-Path -Path $localHashPath -PathType Leaf) {
        [long](Get-Item -Path $localHashPath).Length
    } else {
        $null
    }

    if ($remoteHash.Count -eq 0) {
        $problems += "hash-файл відсутній"
    } elseif ($null -ne $localHashSize -and
        ($null -eq $remoteHash[0].SizeBytes -or [long]$remoteHash[0].SizeBytes -ne $localHashSize)) {
        $problems += "розмір hash-файлу не збігається"
    } elseif ([string]::IsNullOrWhiteSpace($DownloadedRemoteHashPath) -or
        -not (Test-Path -LiteralPath $DownloadedRemoteHashPath -PathType Leaf)) {
        $problems += "не вдалося прочитати віддалений hash-файл"
    } else {
        try {
            $localHashText = (Read-BRAVOTextFile -Path $localHashPath).Trim()
            $remoteHashText = (Read-BRAVOTextFile -Path $DownloadedRemoteHashPath).Trim()
            if ($localHashText -cne $remoteHashText) {
                $problems += "вміст hash-файлу не збігається"
            } else {
                $remoteHashSidecarVerified = $true
            }
        } catch {
            $problems += "не вдалося порівняти вміст hash-файлу"
        }
    }

    $verifyRemoteHash = if ($null -eq $backupMonitoring.SFTP.VerifyRemoteArchiveHash) {
        $true
    } else {
        Test-BRAVOSettingEnabled -Value $backupMonitoring.SFTP.VerifyRemoteArchiveHash
    }
    if ($verifyRemoteHash -and $remoteArchive.Count -gt 0 -and
        $null -ne $remoteArchive[0].SizeBytes -and
        [long]$remoteArchive[0].SizeBytes -eq [long]$LocalArchive.Length) {
        try {
            if ($null -eq $RemoteArchiveChecksumResult -or
                -not $RemoteArchiveChecksumResult.Success) {
                $checksumError = if ($null -ne $RemoteArchiveChecksumResult) {
                    [string]$RemoteArchiveChecksumResult.Error
                } else {
                    "немає результату"
                }
                $requireServerSideHash = (
                    $null -ne $backupMonitoring.SFTP.RequireServerSideArchiveHash -and
                    (Test-BRAVOSettingEnabled `
                        -Value $backupMonitoring.SFTP.RequireServerSideArchiveHash)
                )
                if ($remoteHashSidecarVerified -and -not $requireServerSideHash) {
                    Write-HealthLog (
                        "SFTP $($ArchiveDefinition.Type): серверний SHA архіву недоступний; " +
                        "використано повний збіг віддаленого hash-файлу"
                    ) -Level "WARNING"
                } else {
                    $problems += (
                        "не вдалося обчислити контрольну суму віддаленого архіву: " +
                        (Get-CompactWinSCPError -Text $checksumError)
                    )
                }
            } else {
                $checksumAlgorithm = [string]$RemoteArchiveChecksumResult.Algorithm
                $expectedArchiveHash = if ($checksumAlgorithm -eq "sha-512") {
                    Get-ExpectedArchiveSHA512 `
                        -HashPath $localHashPath `
                        -ArchiveName $LocalArchive.Name
                } elseif ($checksumAlgorithm -eq "sha-256") {
                    (Get-BRAVOFileHash -Path $LocalArchive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                } else {
                    throw "непідтримуваний алгоритм віддаленої контрольної суми: $checksumAlgorithm"
                }
                if ([string]$RemoteArchiveChecksumResult.Hash -cne $expectedArchiveHash) {
                    $problems += "$checksumAlgorithm віддаленого архіву не збігається"
                } else {
                    $remoteArchiveHashVerified = $true
                }
            }
        } catch {
            $problems += "не вдалося перевірити SHA512 віддаленого архіву: $($_.Exception.Message)"
        }
    }

    if ($remoteArchiveHashVerified -and
        $problems -contains "не вдалося прочитати віддалений hash-файл") {
        # Повна серверна контрольна сума архіву сильніша за повторне читання
        # текстового sidecar-файлу. Сам sidecar при цьому вже знайдено та
        # перевірено за розміром.
        $problems = @(
            $problems |
                Where-Object {
                    $_ -cne "не вдалося прочитати віддалений hash-файл"
                }
        )
        Write-HealthLog (
            "SFTP $($ArchiveDefinition.Type): віддалений hash-файл не завантажено, " +
            "але SHA віддаленого архіву успішно перевірено"
        ) -Level "WARNING"
    }

    $remoteLastWriteTime = if ($remoteArchive.Count -gt 0) { $remoteArchive[0].LastWriteTime } else { $null }
    if ($null -ne $remoteLastWriteTime) {
        $remoteAge = $healthCheckStarted - [datetime]$remoteLastWriteTime
        if ($remoteAge.TotalHours -gt [double]$backupMonitoring.SFTP.RemoteBackupMaxAgeHours) {
            $problems += "віддалена копія старша за $($backupMonitoring.SFTP.RemoteBackupMaxAgeHours) год."
        }
    }

    if ($problems.Count -eq 0) {
        Write-HealthLog "SFTP $($ArchiveDefinition.Type) справний: $($LocalArchive.Name), каталог $remotePath, розмір $(Format-FileSize $LocalArchive.Length)" -Level "SUCCESS"
        return
    }

    return [pscustomobject]@{
        Kind = "SFTPArchive"
        Component = "SFTP $($ArchiveDefinition.Type)"
        Reason = $problems -join "; "
        FileName = $LocalArchive.Name
        LastWriteTime = $remoteLastWriteTime
        SizeBytes = if ($remoteArchive.Count -gt 0) { $remoteArchive[0].SizeBytes } else { $null }
        ExpectedSizeBytes = [long]$LocalArchive.Length
        ActualSizeBytes = if ($remoteArchive.Count -gt 0) { $remoteArchive[0].SizeBytes } else { $null }
        Location = $remotePath
    }
}

function Test-BRAVODirectoryContainsFiles {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Container)) {
        # Невідомий або недоступний каталог не можна безпечно ігнорувати.
        return $true
    }
    try {
        return @(
            Get-ChildItem `
                -LiteralPath $Path `
                -Recurse `
                -Force `
                -ErrorAction Stop |
                Where-Object { -not $_.PSIsContainer } |
                Select-Object -First 1
        ).Count -gt 0
    } catch {
        return $true
    }
}

function Get-BAZACloudPendingDifferences {
    param([object[]]$Differences)

    # Накопичувальна хмара не видаляє додаткові віддалені об'єкти.
    # Водночас UploadUpdate є реальною невиконаною передачею: у хмарі
    # зберігається застаріла версія локального файла.
    return @(
        $Differences |
            Where-Object {
                $isPendingUpload = $_.RawAction -in @(
                    "UploadNew",
                    "UploadUpdate",
                    "UploadPending"
                )
                $isIgnorableEmptyDirectory = (
                    $_.IsDirectory -and
                    $_.RawAction -in @("UploadNew", "UploadPending") -and
                    -not (Test-BRAVODirectoryContainsFiles -Path $_.Path)
                )
                $isPendingUpload -and -not $isIgnorableEmptyDirectory
            }
    )
}

function Get-BAZAPendingAlertAfterHours {
    $configuredValue = if (
        $null -ne $backupMonitoring.SFTP -and
        $backupMonitoring.SFTP.Contains("BAZAPendingAlertAfterHours")
    ) {
        [double]$backupMonitoring.SFTP.BAZAPendingAlertAfterHours
    } else {
        26
    }
    return [math]::Max(0, $configuredValue)
}

function Test-BAZAPendingSynchronizationOverdue {
    param([object]$PreviewSummary)

    $alertAfterHours = Get-BAZAPendingAlertAfterHours
    if ($null -eq $PreviewSummary.OldestLastWriteTime) {
        # Порівняння без часу (наприклад, лише каталог) не можна безпечно
        # вважати новою штатною чергою.
        return $true
    }
    $pendingAge = $healthCheckStarted - [datetime]$PreviewSummary.OldestLastWriteTime
    return $pendingAge.TotalHours -ge $alertAfterHours
}

function Invoke-WinSCPBAZAComparisonViaCli {
    param(
        [string]$LocalPath,
        [string]$RemotePath
    )

    try {
        $previewOptions = [string]$backupMonitoring.SFTP.BAZAPreviewOptions
        $previewOptions = (
            $previewOptions -replace '(?i)(^|\s)-delete(?=\s|$)', ' '
        ).Trim()
        if ($previewOptions -notmatch '(?i)(^|\s)-preview(\s|$)') {
            $previewOptions = "-preview $previewOptions".Trim()
        }

        $command = "synchronize remote $previewOptions {0} {1}" -f `
            (ConvertTo-WinSCPScriptArgument $LocalPath), `
            (ConvertTo-WinSCPScriptArgument $RemotePath)
        $sessionResult = Invoke-WinSCPHealthSession -Commands @($command)
        if (-not $sessionResult.Success) {
            throw [string]$sessionResult.Error
        }

        $failureText = Get-WinSCPXmlFailureText -Xml $sessionResult.Xml
        if (-not [string]::IsNullOrWhiteSpace($failureText)) {
            throw $failureText
        }
        if ($sessionResult.ExitCode -ne 0) {
            throw "WinSCP.com завершив preview BAZA з кодом $($sessionResult.ExitCode)"
        }

        $namespaceManager = New-WinSCPNamespaceManager -Xml $sessionResult.Xml
        $differences = @()
        $localRoot = [System.IO.Path]::GetFullPath($LocalPath).TrimEnd("\")
        $normalizedRemoteRoot = (Normalize-SFTPPath $RemotePath).TrimEnd("/")

        foreach ($uploadNode in @(
            $sessionResult.Xml.SelectNodes("//w:upload", $namespaceManager)
        )) {
            $resultNode = $uploadNode.SelectSingleNode("w:result", $namespaceManager)
            if ($resultNode -and $resultNode.GetAttribute("success") -ne "true") {
                continue
            }

            $fileNode = $uploadNode.SelectSingleNode("w:filename", $namespaceManager)
            $destinationNode = $uploadNode.SelectSingleNode("w:destination", $namespaceManager)
            $sizeNode = $uploadNode.SelectSingleNode("w:size", $namespaceManager)
            $localFilePath = if ($fileNode) {
                [string]$fileNode.GetAttribute("value")
            } else {
                ""
            }
            $displayPath = if (
                -not [string]::IsNullOrWhiteSpace($localFilePath) -and
                $localFilePath.StartsWith(
                    "$localRoot\",
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $localFilePath.Substring($localRoot.Length + 1)
            } elseif ($destinationNode) {
                $remoteDestination = Normalize-SFTPPath (
                    $destinationNode.GetAttribute("value")
                )
                $remoteDestination.Substring(
                    [math]::Min(
                        $remoteDestination.Length,
                        $normalizedRemoteRoot.Length
                    )
                ).TrimStart("/")
            } else {
                "невідомий файл"
            }

            $localItem = if (
                -not [string]::IsNullOrWhiteSpace($localFilePath) -and
                (Test-Path -LiteralPath $localFilePath -PathType Leaf)
            ) {
                Get-Item -LiteralPath $localFilePath
            } else {
                $null
            }
            $sizeBytes = if ($sizeNode -and
                $sizeNode.GetAttribute("value") -match '^\d+$') {
                [long]$sizeNode.GetAttribute("value")
            } elseif ($null -ne $localItem) {
                [long]$localItem.Length
            } else {
                $null
            }

            $differences += [pscustomobject]@{
                RawAction = "UploadPending"
                Action = "передати"
                Path = $displayPath
                IsDirectory = $false
                SizeBytes = $sizeBytes
                LastWriteTime = if ($null -ne $localItem) {
                    $localItem.LastWriteTime
                } else {
                    $null
                }
            }
        }

        foreach ($directoryNode in @(
            $sessionResult.Xml.SelectNodes("//w:mkdir", $namespaceManager)
        )) {
            $resultNode = $directoryNode.SelectSingleNode("w:result", $namespaceManager)
            if ($resultNode -and $resultNode.GetAttribute("success") -ne "true") {
                continue
            }
            $fileNode = $directoryNode.SelectSingleNode("w:filename", $namespaceManager)
            $remoteDirectory = if ($fileNode) {
                Normalize-SFTPPath ($fileNode.GetAttribute("value"))
            } else {
                ""
            }
            $displayPath = if (
                -not [string]::IsNullOrWhiteSpace($remoteDirectory) -and
                $remoteDirectory.StartsWith(
                    "$normalizedRemoteRoot/",
                    [System.StringComparison]::Ordinal
                )
            ) {
                $remoteDirectory.Substring($normalizedRemoteRoot.Length + 1)
            } else {
                $remoteDirectory.TrimStart("/")
            }
            $localDirectoryPath = Join-Path `
                $localRoot `
                ($displayPath.Replace("/", "\"))
            if (-not (Test-BRAVODirectoryContainsFiles `
                -Path $localDirectoryPath)) {
                continue
            }

            $differences += [pscustomobject]@{
                RawAction = "UploadPending"
                Action = "створити папку"
                Path = $displayPath
                IsDirectory = $true
                SizeBytes = $null
                LastWriteTime = $null
            }
        }

        $knownSizes = @($differences | Where-Object { $null -ne $_.SizeBytes })
        $knownTimes = @(
            $differences |
                Where-Object { $null -ne $_.LastWriteTime } |
                Sort-Object LastWriteTime
        )
        $detailLimit = [math]::Max(
            1,
            [int]$backupMonitoring.SFTP.DifferenceDetailLimit
        )
        $details = @(
            $differences |
                Select-Object -First $detailLimit |
                ForEach-Object { "потребує передачі: $($_.Path)" }
        )

        return [pscustomobject]@{
            Success = $true
            Error = $null
            DifferenceCount = $differences.Count
            SizeBytes = if ($knownSizes.Count -gt 0) {
                [long](($knownSizes | Measure-Object -Property SizeBytes -Sum).Sum)
            } else {
                $null
            }
            OldestLastWriteTime = if ($knownTimes.Count -gt 0) {
                $knownTimes[0].LastWriteTime
            } else {
                $null
            }
            ActionCounts = [pscustomobject]@{
                New = 0
                Updated = 0
                RemoteExtra = 0
                Other = $differences.Count
            }
            IgnoredActionCounts = [pscustomobject]@{
                Updated = 0
                RemoteExtra = 0
                Other = 0
            }
            Details = @($details)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
            DifferenceCount = $null
            SizeBytes = $null
            OldestLastWriteTime = $null
            ActionCounts = $null
            IgnoredActionCounts = $null
            Details = @()
        }
    }
}

function Invoke-WinSCPBAZAComparison {
    param(
        [string]$LocalPath,
        [string]$RemotePath
    )

    $components = Get-WinSCPDotNetComponents
    if ($null -eq $components) {
        Write-HealthLog (
            "WinSCPnet.dll + WinSCP.exe недоступні; " +
            "BAZA порівнюється через WinSCP.com synchronize -preview"
        ) -Level "INFO"
        return Invoke-WinSCPBAZAComparisonViaCli `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath
    }

    $session = $null
    try {
        if (-not ("WinSCP.Session" -as [type])) {
            Add-Type -Path $components.AssemblyPath -ErrorAction Stop
        }

        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.ParseUrl($sftpUrl)
        $sessionOptions.SshHostKeyFingerprint = ([string]$sftpHostKey).Trim().Trim('"')
        $sessionOptions.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds)
        )

        $session = New-Object WinSCP.Session
        $session.ExecutablePath = $components.ExecutablePath
        $session.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        )
        $session.Open($sessionOptions)

        $previewOptions = [string]$backupMonitoring.SFTP.BAZAPreviewOptions
        # Накопичувальна хмара: віддалені файли, яких уже немає локально,
        # не видаляються і не вважаються розбіжностями.
        $removeFiles = $false
        $mirror = $previewOptions -match '(?i)(^|\s)-mirror(\s|$)'
        $criteria = [WinSCP.SynchronizationCriteria]::Time
        $criteriaMatch = [regex]::Match(
            $previewOptions,
            '(?i)(^|\s)-criteria=(?<Value>[^\s]+)'
        )
        if ($criteriaMatch.Success) {
            $criteria = [WinSCP.SynchronizationCriteria]::None
            foreach ($criterion in $criteriaMatch.Groups["Value"].Value.Split(",")) {
                switch ($criterion.ToLowerInvariant()) {
                    "time" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Time
                    }
                    "size" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Size
                    }
                    "checksum" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Checksum
                    }
                }
            }
        }

        # CompareDirectories є read-only еквівалентом synchronize -preview
        # і повертає структуровану колекцію запланованих змін.
        $comparison = @(
            $session.CompareDirectories(
                [WinSCP.SynchronizationMode]::Remote,
                $LocalPath,
                $RemotePath,
                $removeFiles,
                $mirror,
                $criteria,
                $null
            )
        )

        $allDifferences = @()
        foreach ($difference in $comparison) {
            $side = if ($null -ne $difference.Local) {
                $difference.Local
            } else {
                $difference.Remote
            }
            $actionText = switch ([string]$difference.Action) {
                "UploadNew" { "додати" }
                "UploadUpdate" { "оновити" }
                "DeleteRemote" { "видалити віддалений" }
                default { [string]$difference.Action }
            }
            $allDifferences += [pscustomobject]@{
                RawAction = [string]$difference.Action
                Action = $actionText
                Path = if ($null -ne $side) { [string]$side.FileName } else { "невідомий файл" }
                IsDirectory = [bool]$difference.IsDirectory
                SizeBytes = if ($null -ne $side -and -not $difference.IsDirectory) {
                    [long]$side.Length
                } else {
                    $null
                }
                LastWriteTime = if ($null -ne $side) { $side.LastWriteTime } else { $null }
            }
        }

        $pendingDifferences = @(
            Get-BAZACloudPendingDifferences -Differences $allDifferences
        )
        $knownSizes = @($pendingDifferences | Where-Object { $null -ne $_.SizeBytes })
        $knownTimes = @(
            $pendingDifferences |
                Where-Object { $null -ne $_.LastWriteTime } |
                Sort-Object LastWriteTime
        )
        $detailLimit = [math]::Max(1, [int]$backupMonitoring.SFTP.DifferenceDetailLimit)
        $details = @(
            $pendingDifferences |
                Select-Object -First $detailLimit |
                ForEach-Object {
                    $detailAction = if ($_.RawAction -eq "UploadUpdate") {
                        "потребує оновлення у хмарі"
                    } else {
                        "відсутній у хмарі"
                    }
                    "${detailAction}: $($_.Path)"
                }
        )
        $actionCounts = [pscustomobject]@{
            New = @($pendingDifferences | Where-Object { $_.RawAction -eq "UploadNew" }).Count
            Updated = @($pendingDifferences | Where-Object { $_.RawAction -eq "UploadUpdate" }).Count
            RemoteExtra = 0
            Other = 0
        }
        $ignoredActionCounts = [pscustomobject]@{
            Updated = 0
            RemoteExtra = @($allDifferences | Where-Object { $_.RawAction -eq "DeleteRemote" }).Count
            Other = @($allDifferences | Where-Object {
                $_.RawAction -notin @("UploadNew", "UploadUpdate", "DeleteRemote")
            }).Count
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            DifferenceCount = $pendingDifferences.Count
            SizeBytes = if ($knownSizes.Count -gt 0) {
                [long](($knownSizes | Measure-Object -Property SizeBytes -Sum).Sum)
            } else {
                $null
            }
            OldestLastWriteTime = if ($knownTimes.Count -gt 0) {
                $knownTimes[0].LastWriteTime
            } else {
                $null
            }
            ActionCounts = $actionCounts
            IgnoredActionCounts = $ignoredActionCounts
            Details = @($details)
        }
    } catch {
        $dotNetError = $_.Exception.Message
        Write-HealthLog (
            "Порівняння BAZA через WinSCP .NET не вдалося: $dotNetError; " +
            "використовується WinSCP.com"
        ) -Level "WARNING"
        $fallbackResult = Invoke-WinSCPBAZAComparisonViaCli `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath
        if (-not $fallbackResult.Success) {
            $fallbackResult.Error =
                ".NET: $dotNetError; WinSCP.com: $($fallbackResult.Error)"
        }
        return $fallbackResult
    } finally {
        if ($session) {
            $session.Dispose()
        }
    }
}

function Get-SFTPHealthIssues {
    $issues = @()
    if (-not $backupMonitoring.SFTP.Enabled) {
        Write-HealthLog "Незалежну SFTP-перевірку вимкнено в конфігурації" -Level "INFO"
        return @()
    }

    $checkArchives = [bool]$backupMonitoring.SFTP.CheckArchiveUploads -and
        [bool]$componentSettings.SFTP.ArchiveUpload
    $checkBAZA = [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaSFTPHealthEnabled
    $checkBAZAWWW = [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled

    if (-not $checkArchives -and -not $checkBAZA -and -not $checkBAZAWWW) {
        Write-HealthLog "SFTP health-check не потрібний: компоненти віддаленої передачі вимкнено" -Level "INFO"
        return @()
    }

    $configurationResult = Test-SFTPHealthConfiguration `
        -CheckArchives $checkArchives `
        -CheckBAZA $checkBAZA `
        -CheckBAZAWWW $checkBAZAWWW
    if (-not $configurationResult.Valid) {
        return @([pscustomobject]@{
            Kind = "SFTPConnection"
            Component = "SFTP"
            Reason = "перевірку не виконано: $($configurationResult.Errors -join '; ')"
            FileName = "немає даних"
            LastWriteTime = $null
            SizeBytes = $null
            Location = "/"
        })
    }

    if ($checkArchives) {
        $archiveChecks = @()
        $healthTemporaryRoot = Get-BRAVOHealthTemporaryRoot
        foreach ($archiveDefinition in @($archiveDefinitions | Where-Object { $_.Enabled })) {
            $localState = Get-LocalBackupState -ArchiveDefinition $archiveDefinition
            if ($null -eq $localState.NewestValidArchive) {
                Write-HealthLog "SFTP $($archiveDefinition.Type) пропущено: немає коректної локальної копії для порівняння" -Level "WARNING"
                continue
            }

            $remoteDirectory = Normalize-SFTPPath $sftpDirectories[$archiveDefinition.Type]
            $archiveChecks += [pscustomobject]@{
                Definition = $archiveDefinition
                LocalArchive = $localState.NewestValidArchive
                RemoteDirectory = $remoteDirectory
                RemoteHashDownloadDirectory = Join-Path `
                    $healthTemporaryRoot `
                    ("BRAVO_HEALTH_{0}" -f [guid]::NewGuid().ToString("N"))
                RemoteHashDownloadPath = $null
            }
            $archiveChecks[-1].RemoteHashDownloadPath = Join-Path `
                $archiveChecks[-1].RemoteHashDownloadDirectory `
                "$($localState.NewestValidArchive.Name)$hashFileExtension"
        }

        if ($archiveChecks.Count -gt 0) {
            $verifySFTPRemoteHash = if ($null -eq $backupMonitoring.SFTP.VerifyRemoteArchiveHash) {
                $true
            } else {
                Test-BRAVOSettingEnabled -Value $backupMonitoring.SFTP.VerifyRemoteArchiveHash
            }
            $remoteArchiveChecksumResults = if ($verifySFTPRemoteHash) {
                Get-SFTPRemoteArchiveChecksumResults -ArchiveChecks $archiveChecks
            } else {
                @{}
            }
            $archiveCommands = @($archiveChecks | ForEach-Object {
                if (-not (Test-Path -LiteralPath $_.RemoteHashDownloadDirectory -PathType Container)) {
                    New-Item `
                        -ItemType Directory `
                        -Path $_.RemoteHashDownloadDirectory `
                        -Force |
                        Out-Null
                }
                "ls $(ConvertTo-WinSCPScriptArgument $_.RemoteDirectory)"
                $remoteHashPath = "{0}/{1}{2}" -f `
                    $_.RemoteDirectory.TrimEnd('/'), `
                    $_.LocalArchive.Name, `
                    $hashFileExtension
                # lcd + get без локального аргументу уникає неоднозначного
                # розбору quoted Windows-шляху, що завершується "\".
                "lcd $(ConvertTo-WinSCPScriptArgument $_.RemoteHashDownloadDirectory)"
                "get $(ConvertTo-WinSCPScriptArgument $remoteHashPath)"
            })
            try {
                $archiveSession = Invoke-WinSCPHealthSession -Commands $archiveCommands

                if (-not $archiveSession.Success) {
                $issues += [pscustomobject]@{
                    Kind = "SFTPConnection"
                    Component = "SFTP архіви"
                    Reason = "не вдалося виконати віддалену перевірку: $($archiveSession.Error)"
                    FileName = "немає даних"
                    LastWriteTime = $null
                    SizeBytes = $null
                    Location = "/"
                }
                } else {
                    $remoteListings = @(Get-WinSCPRemoteListings -Xml $archiveSession.Xml)
                    $remoteDownloads = @(Get-WinSCPRemoteDownloads -Xml $archiveSession.Xml)
                    if ($remoteListings.Count -eq 0 -and $archiveSession.ExitCode -ne 0) {
                    $issues += [pscustomobject]@{
                        Kind = "SFTPConnection"
                        Component = "SFTP архіви"
                        Reason = "з'єднання або читання каталогів завершилося з кодом $($archiveSession.ExitCode)"
                        FileName = "немає даних"
                        LastWriteTime = $null
                        SizeBytes = $null
                        Location = "/"
                    }
                    } else {
                        foreach ($archiveCheck in $archiveChecks) {
                        $remoteListing = @(
                            $remoteListings |
                                Where-Object { $_.Destination -ceq $archiveCheck.RemoteDirectory } |
                                Select-Object -First 1
                        )
                            $downloadedHash = Resolve-DownloadedRemoteHashPath `
                                -ArchiveCheck $archiveCheck `
                                -Downloads $remoteDownloads
                            if ([string]::IsNullOrWhiteSpace([string]$downloadedHash.Path)) {
                                Write-HealthLog (
                                    "SFTP $($archiveCheck.Definition.Type): " +
                                    "не вдалося отримати віддалений hash-файл: " +
                                    $downloadedHash.Error
                                ) -Level "WARNING"
                            }
                            $archiveIssue = Test-SFTPArchiveCopy `
                                -ArchiveDefinition $archiveCheck.Definition `
                                -LocalArchive $archiveCheck.LocalArchive `
                                -RemoteListing $(if ($remoteListing.Count -gt 0) { $remoteListing[0] } else { $null }) `
                                -RemoteDirectory $archiveCheck.RemoteDirectory `
                                -DownloadedRemoteHashPath $downloadedHash.Path `
                                -RemoteArchiveChecksumResult $remoteArchiveChecksumResults[$archiveCheck.LocalArchive.FullName]
                            if ($null -ne $archiveIssue) {
                                $issues += $archiveIssue
                            }
                        }
                    }
                }
            } finally {
                foreach ($archiveCheck in $archiveChecks) {
                    Remove-BRAVOHealthTemporaryDirectory `
                        -Path $archiveCheck.RemoteHashDownloadDirectory
                }
            }
        }
    }

    $folderSynchronizationChecks = @()
    if ($checkBAZA) {
        $folderSynchronizationChecks += [pscustomobject]@{
            Name = "BAZA"
            Component = "SFTP BAZA"
            LocalPath = [string]$bazaPaths.Source
            RemotePath = Normalize-SFTPPath $sftpDirectories.BAZA
            DetectionError = $null
        }
    }
    if ($checkBAZAWWW) {
        $folderSynchronizationChecks += [pscustomobject]@{
            Name = "BAZA WWW"
            Component = "SFTP BAZA WWW"
            LocalPath = [string]$bazaWWWPaths.Source
            RemotePath = Normalize-SFTPPath $sftpDirectories.BAZAWWW
            DetectionError = if ($bazaWWWDetection.Success) {
                $null
            } else {
                [string]$bazaWWWDetection.Reason
            }
        }
    }

    foreach ($folderCheck in $folderSynchronizationChecks) {
        if (-not [string]::IsNullOrWhiteSpace($folderCheck.DetectionError)) {
            $issues += [pscustomobject]@{
                Kind = "SFTPSynchronization"
                Component = $folderCheck.Component
                Reason = "не вдалося визначити локальне джерело: $($folderCheck.DetectionError)"
                FileName = "немає даних"
                LastWriteTime = $null
                SizeBytes = $null
                DifferenceCount = $null
                Details = @()
                Location = $folderCheck.RemotePath
            }
        } elseif (-not (Test-Path `
            -LiteralPath $folderCheck.LocalPath `
            -PathType Container)) {
            $issues += [pscustomobject]@{
                Kind = "SFTPSynchronization"
                Component = $folderCheck.Component
                Reason = "локальний каталог $($folderCheck.Name) не знайдено"
                FileName = "немає даних"
                LastWriteTime = $null
                SizeBytes = $null
                DifferenceCount = $null
                Details = @()
                Location = $folderCheck.RemotePath
            }
        } else {
            $previewSummary = Invoke-WinSCPBAZAComparison `
                -LocalPath $folderCheck.LocalPath `
                -RemotePath $folderCheck.RemotePath

            if (-not $previewSummary.Success) {
                $issues += [pscustomobject]@{
                    Kind = "SFTPSynchronization"
                    Component = $folderCheck.Component
                    Reason = "не вдалося порівняти каталоги: $($previewSummary.Error)"
                    FileName = "немає даних"
                    LastWriteTime = $null
                    SizeBytes = $null
                    DifferenceCount = $null
                    Details = @()
                    Location = $folderCheck.RemotePath
                }
            } elseif ($previewSummary.DifferenceCount -gt 0) {
                if (-not (Test-BAZAPendingSynchronizationOverdue -PreviewSummary $previewSummary)) {
                    $pendingAge = $healthCheckStarted - [datetime]$previewSummary.OldestLastWriteTime
                    Write-HealthLog (
                        "SFTP $($folderCheck.Name): штатна черга передачі " +
                        "$($previewSummary.DifferenceCount) об'єктів, найстаріший вік " +
                        "$(Format-BackupAge $previewSummary.OldestLastWriteTime); " +
                        "alert після $(Get-BAZAPendingAlertAfterHours) год."
                    ) -Level "INFO"
                } else {
                    $issues += [pscustomobject]@{
                    Kind = "SFTPSynchronization"
                    Component = $folderCheck.Component
                    Reason = "у хмарі відсутні або потребують оновлення локальні файли/папки"
                    FileName = if ($previewSummary.Details.Count -gt 0) { $previewSummary.Details -join "; " } else { "немає деталей" }
                    LastWriteTime = $previewSummary.OldestLastWriteTime
                    SizeBytes = $previewSummary.SizeBytes
                    DifferenceCount = $previewSummary.DifferenceCount
                    ActionCounts = $previewSummary.ActionCounts
                    Details = @($previewSummary.Details)
                    Location = $folderCheck.RemotePath
                }
                }
            } else {
                $ignoredRemoteExtraCount = if ($null -ne $previewSummary.IgnoredActionCounts) {
                    [int]$previewSummary.IgnoredActionCounts.RemoteExtra
                } else {
                    0
                }
                Write-HealthLog "SFTP $($folderCheck.Name) справний: усі локальні файли та папки актуальні у $($folderCheck.RemotePath); додаткових об'єктів у хмарі проігноровано: $ignoredRemoteExtraCount" -Level "SUCCESS"
            }
        }
    }

    return @($issues)
}

function Test-SMBHealthConfiguration {
    $errors = @()
    if (-not [string]::IsNullOrWhiteSpace($smbCredentialError)) {
        $errors += $smbCredentialError
    }
    if ($null -eq $script:smbCredential) {
        $errors += "не завантажено NAS/SMB облікові дані з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace([string]$smbSettings.RootPath) -or
        [string]$smbSettings.RootPath -notmatch '^\\\\[^\\]+\\[^\\]+') {
        $errors += "smbSettings.RootPath повинен бути UNC-шляхом виду \\server\share"
    }
    if ([double]$backupMonitoring.SMB.RemoteBackupMaxAgeHours -le 0) {
        $errors += "максимальний вік NAS/SMB-копії повинен бути більшим за 0"
    }

    foreach ($archiveDefinition in @($archiveDefinitions | Where-Object { $_.Enabled })) {
        if ($null -eq $smbSettings.Directories -or
            -not $smbSettings.Directories.ContainsKey($archiveDefinition.Type) -or
            [string]::IsNullOrWhiteSpace([string]$smbSettings.Directories[$archiveDefinition.Type])) {
            $errors += "не встановлено NAS/SMB каталог для $($archiveDefinition.Type)"
        }
    }

    return [pscustomobject]@{
        Valid = $errors.Count -eq 0
        Errors = @($errors)
    }
}

function New-BRAVOSMBHealthDrive {
    $driveName = "BRAVOSMBHEALTH$PID"
    Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
    try {
        return New-PSDrive `
            -Name $driveName `
            -PSProvider FileSystem `
            -Root ([string]$smbSettings.RootPath) `
            -Credential $script:smbCredential `
            -Scope Script `
            -ErrorAction Stop
    } catch {
        throw "не вдалося підключитися до '$($smbSettings.RootPath)': $($_.Exception.Message)"
    }
}

function Get-SMBHealthIssues {
    $issues = @()
    if (-not [bool]$backupMonitoring.SMB.Enabled) {
        Write-HealthLog "Незалежну NAS/SMB-перевірку вимкнено в конфігурації" -Level "INFO"
        return @()
    }
    if (-not [bool]$backupMonitoring.SMB.CheckArchiveCopies -or
        -not [bool]$componentSettings.SMB.ArchiveCopy) {
        Write-HealthLog "NAS/SMB health-check не потрібний: копіювання архівів вимкнено" -Level "INFO"
        return @()
    }

    $configurationResult = Test-SMBHealthConfiguration
    if (-not $configurationResult.Valid) {
        return @([pscustomobject]@{
            Kind = "SMBConnection"
            Component = "NAS/SMB"
            Reason = "перевірку не виконано: $($configurationResult.Errors -join '; ')"
            FileName = "немає даних"
            LastWriteTime = $null
            SizeBytes = $null
            ExpectedSizeBytes = $null
            ActualSizeBytes = $null
            Location = [string]$smbSettings.RootPath
        })
    }

    $drive = $null
    try {
        $drive = New-BRAVOSMBHealthDrive
        foreach ($archiveDefinition in @($archiveDefinitions | Where-Object { $_.Enabled })) {
            $localState = Get-LocalBackupState -ArchiveDefinition $archiveDefinition
            $localArchive = $localState.NewestValidArchive
            if ($null -eq $localArchive) {
                Write-HealthLog "NAS/SMB $($archiveDefinition.Type) пропущено: немає коректної локальної копії для порівняння" -Level "WARNING"
                continue
            }

            $remoteDirectory = Join-Path `
                ([string]$smbSettings.RootPath) `
                ([string]$smbSettings.Directories[$archiveDefinition.Type])
            $remoteArchivePath = Join-Path $remoteDirectory $localArchive.Name
            $remoteHashPath = "$remoteArchivePath$hashFileExtension"
            $localHashPath = "$($localArchive.FullName)$hashFileExtension"
            $localHashSize = if (Test-Path -LiteralPath $localHashPath -PathType Leaf) {
                [long](Get-Item -LiteralPath $localHashPath).Length
            } else {
                $null
            }
            $remoteArchive = if (Test-Path -LiteralPath $remoteArchivePath -PathType Leaf) {
                Get-Item -LiteralPath $remoteArchivePath
            } else {
                $null
            }
            $remoteHash = if (Test-Path -LiteralPath $remoteHashPath -PathType Leaf) {
                Get-Item -LiteralPath $remoteHashPath
            } else {
                $null
            }
            $problems = @()

            if ($null -eq $remoteArchive) {
                $problems += "архів відсутній"
            } elseif ([long]$remoteArchive.Length -ne [long]$localArchive.Length) {
                $problems += "розмір архіву не збігається"
            }
            if ($null -eq $remoteHash) {
                $problems += "hash-файл відсутній"
            } elseif ($null -ne $localHashSize -and [long]$remoteHash.Length -ne $localHashSize) {
                $problems += "розмір hash-файлу не збігається"
            } else {
                try {
                    $localHashText = (Read-BRAVOTextFile -Path $localHashPath).Trim()
                    $remoteHashText = (Read-BRAVOTextFile -Path $remoteHashPath).Trim()
                    if ($localHashText -cne $remoteHashText) {
                        $problems += "вміст hash-файлу не збігається"
                    }
                } catch {
                    $problems += "не вдалося порівняти вміст hash-файлу"
                }
            }

            $verifyRemoteHash = if ($null -eq $backupMonitoring.SMB.VerifyRemoteArchiveHash) {
                $true
            } else {
                Test-BRAVOSettingEnabled -Value $backupMonitoring.SMB.VerifyRemoteArchiveHash
            }
            if ($verifyRemoteHash -and $null -ne $remoteArchive -and
                [long]$remoteArchive.Length -eq [long]$localArchive.Length) {
                try {
                    $expectedArchiveHash = Get-ExpectedArchiveSHA512 `
                        -HashPath $localHashPath `
                        -ArchiveName $localArchive.Name
                    $remoteArchiveHash = Get-FileSHA512 -Path $remoteArchivePath
                    if ($remoteArchiveHash -cne $expectedArchiveHash) {
                        $problems += "SHA512 віддаленого архіву не збігається"
                    }
                } catch {
                    $problems += "не вдалося перевірити SHA512 віддаленого архіву: $($_.Exception.Message)"
                }
            }

            $remoteLastWriteTime = if ($remoteArchive) { $remoteArchive.LastWriteTime } else { $null }
            if ($null -ne $remoteLastWriteTime -and
                ($healthCheckStarted - $remoteLastWriteTime).TotalHours -gt
                [double]$backupMonitoring.SMB.RemoteBackupMaxAgeHours) {
                $problems += "віддалена копія старша за $($backupMonitoring.SMB.RemoteBackupMaxAgeHours) год."
            }

            if ($problems.Count -eq 0) {
                Write-HealthLog "NAS/SMB $($archiveDefinition.Type) справний: $($localArchive.Name), каталог $remoteDirectory, розмір $(Format-FileSize $localArchive.Length)" -Level "SUCCESS"
                continue
            }

            $issues += [pscustomobject]@{
                Kind = "SMBArchive"
                Component = "NAS/SMB $($archiveDefinition.Type)"
                Reason = $problems -join "; "
                FileName = $localArchive.Name
                LastWriteTime = $remoteLastWriteTime
                SizeBytes = if ($remoteArchive) { [long]$remoteArchive.Length } else { $null }
                ExpectedSizeBytes = [long]$localArchive.Length
                ActualSizeBytes = if ($remoteArchive) { [long]$remoteArchive.Length } else { $null }
                Location = $remoteDirectory
            }
        }
    } catch {
        $issues += [pscustomobject]@{
            Kind = "SMBConnection"
            Component = "NAS/SMB"
            Reason = $_.Exception.Message
            FileName = "немає даних"
            LastWriteTime = $null
            SizeBytes = $null
            ExpectedSizeBytes = $null
            ActualSizeBytes = $null
            Location = [string]$smbSettings.RootPath
        }
    } finally {
        if ($drive) {
            Remove-PSDrive -Name $drive.Name -Force -ErrorAction SilentlyContinue
        }
    }

    return @($issues)
}

function Get-EnabledBackupComponentNames {
    $componentNames = @()
    if ($bazaLocalHealthEnabled -or $bazaSFTPHealthEnabled) {
        $componentNames += "BAZA_APP"
    }
    if ($bazaWWWSFTPHealthEnabled) {
        $componentNames += "BAZA_WWW"
    }
    $componentNames += @(
        $archiveDefinitions |
            Where-Object { $_.Enabled } |
            ForEach-Object { $_.Type }
    )

    # Порядок у повідомленні не залежить від порядку archiveDefinitions.
    # Невідомі майбутні компоненти додаються наприкінці, а не губляться.
    $preferredOrder = @("BAZA_APP", "BAZA_WWW", "BLOG", "BRAVOEXCH", "MODEL")
    $orderedNames = @($preferredOrder | Where-Object { $componentNames -contains $_ })
    $orderedNames += @($componentNames | Where-Object { $_ -notin $preferredOrder })
    return @($orderedNames | Select-Object -Unique)
}

function Get-ManagedServiceHealthIssues {
    $checkManagedServices = if ($backupMonitoring.Contains("CheckManagedServices")) {
        Test-BRAVOSettingEnabled -Value $backupMonitoring.CheckManagedServices
    } else {
        $true
    }
    if (-not $checkManagedServices -or
        $null -eq $maintenanceSettings -or
        $null -eq $maintenanceSettings.Services) {
        return @()
    }

    $services = New-Object System.Collections.ArrayList
    $addService = {
        param([object]$Service)

        if ($null -ne $Service -and
            @($services | Where-Object { $_.Name -ieq $Service.Name }).Count -eq 0) {
            [void]$services.Add($Service)
        }
    }

    foreach ($serviceName in @(
            [string]$maintenanceSettings.Services.BravoName,
            [string]$maintenanceSettings.Services.ExchangeApiName
        )) {
        if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
            & $addService (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)
        }
    }

    if (Test-BRAVOSettingEnabled -Value $maintenanceSettings.Services.BravoWebEnabled) {
        foreach ($candidate in @($maintenanceSettings.Services.BravoWebCandidates)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
                continue
            }
            $webService = Get-Service -Name ([string]$candidate) -ErrorAction SilentlyContinue
            if ($null -eq $webService) {
                $webService = Get-Service -DisplayName ([string]$candidate) -ErrorAction SilentlyContinue
            }
            if ($null -ne $webService) {
                & $addService $webService
                break
            }
        }
    }

    $startModeByName = @{}
    try {
        foreach ($serviceInfo in @(Get-BRAVOWmiInstance -ClassName Win32_Service)) {
            $startModeByName[[string]$serviceInfo.Name] = [string]$serviceInfo.StartMode
        }
    } catch {
        Write-HealthLog "Не вдалося прочитати типи запуску служб: $($_.Exception.Message)" -Level "WARNING"
    }

    $issues = @()
    foreach ($service in @($services)) {
        $startMode = [string]$service.StartType
        if ([string]::IsNullOrWhiteSpace($startMode) -and
            $startModeByName.ContainsKey([string]$service.Name)) {
            $startMode = [string]$startModeByName[[string]$service.Name]
        }
        if ($startMode -ieq "Disabled") {
            Write-HealthLog "Перевірку служби $($service.Name) пропущено: тип запуску Disabled" -Level "INFO"
            continue
        }

        $service.Refresh()
        if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
            Write-HealthLog "Служба $($service.Name) працює" -Level "SUCCESS"
            continue
        }
        $issues += [pscustomobject]@{
            Kind = "Service"
            Component = "Служба $($service.Name)"
            Reason = "не запущена (стан: $($service.Status))"
            FileName = ""
            LastWriteTime = $null
            Location = [string]$service.Name
            SizeBytes = $null
            Details = @()
        }
    }
    return @($issues)
}

function Get-HealthIssueComponentName {
    param([object]$Issue)

    $name = [string]$Issue.Component
    if ($name -eq "SFTP архіви") {
        return "SFTP"
    }
    $name = $name -replace '^(SFTP|NAS/SMB|Локальна)\s+', ''
    if ($name -match '\bBAZA WWW\b') {
        return "BAZA WWW"
    }
    if ($name -match '\bBAZA\b') {
        return "BAZA"
    }
    return $name
}

function ConvertTo-NotificationLiteralText {
    param([AllowEmptyString()][string]$Text)

    # Slack does not require Discord Markdown escaping. In PowerShell a
    # backslash is literal, so use "\*" (one slash), not "\\*".
    $literalText = [string]$Text
    if ($NotificationProvider -ne "discord") {
        return $literalText
    }
    $literalText = $literalText.Replace("\", "\\")
    $literalText = $literalText.Replace("*", "\*")
    $literalText = $literalText.Replace("_", "\_")
    $literalText = $literalText.Replace("~", "\~")
    $literalText = $literalText.Replace("|", "\|")
    $literalText = $literalText.Replace(">", "\>")
    return $literalText
}

function Format-HealthIssueFileName {
    param([object]$Issue)

    if ([string]::IsNullOrWhiteSpace([string]$Issue.FileName)) {
        return ""
    }
    return " • файл: $(ConvertTo-NotificationLiteralText -Text ([string]$Issue.FileName))"
}

function Format-CompactLocalIssue {
    param([object]$Issue)

    $componentName = Get-HealthIssueComponentName -Issue $Issue
    if ($Issue.Kind -eq "LocalSynchronization") {
        $exitCodeText = if ($null -ne $Issue.ExitCode) {
            " • robocopy: $($Issue.ExitCode)"
        } else {
            ""
        }
        return ":warning: $componentName — $($Issue.Reason)$exitCodeText"
    }

    if ($Issue.Reason -match '^остання коректна копія старша за ') {
        return ":warning: $componentName — прострочено: $(Format-BackupAge $Issue.LastWriteTime) • $(Format-FileSize $Issue.SizeBytes)$(Format-HealthIssueFileName -Issue $Issue)"
    }

    $fileText = Format-HealthIssueFileName -Issue $Issue
    return ":x: $componentName — $($Issue.Reason)$fileText"
}

function Format-CompactSFTPIssue {
    param([object]$Issue)

    $componentName = Get-HealthIssueComponentName -Issue $Issue
    switch ($Issue.Kind) {
        "SFTPArchive" {
            $expectedSize = $Issue.ExpectedSizeBytes
            $actualSize = $Issue.ActualSizeBytes
            $fileExists = $null -ne $actualSize
            $sizeMatches = $fileExists -and
                $null -ne $expectedSize -and
                [long]$actualSize -eq [long]$expectedSize
            $ageOnly = $Issue.Reason -match '^віддалена копія старша за [\d.,]+ год\.$'

            if ($sizeMatches -and $ageOnly) {
                return ":warning: $componentName — файл є, розмір збігається ($(Format-FileSize $actualSize)), але прострочений: $(Format-BackupAge $Issue.LastWriteTime)$(Format-HealthIssueFileName -Issue $Issue)"
            }
            if (-not $fileExists) {
                return ":x: $componentName — $($Issue.Reason)$(Format-HealthIssueFileName -Issue $Issue)"
            }
            if ($null -ne $expectedSize -and -not $sizeMatches) {
                return ":x: $componentName — $($Issue.Reason) • очікується $(Format-FileSize $expectedSize), у хмарі $(Format-FileSize $actualSize)$(Format-HealthIssueFileName -Issue $Issue)"
            }
            return ":warning: $componentName — файл є ($(Format-FileSize $actualSize)) • $($Issue.Reason)$(Format-HealthIssueFileName -Issue $Issue)"
        }
        "SFTPSynchronization" {
            if ($Issue.Reason -eq "у хмарі відсутні або потребують оновлення локальні файли/папки") {
                $missingText = if ($null -eq $Issue.DifferenceCount) {
                    "немає даних"
                } else {
                    [string]$Issue.DifferenceCount
                }
                $sizeText = if ($null -ne $Issue.SizeBytes) {
                    " • $(Format-FileSize $Issue.SizeBytes)"
                } else {
                    ""
                }
                $actionText = ""
                if ($null -ne $Issue.ActionCounts) {
                    $actionParts = @()
                    if ([int]$Issue.ActionCounts.New -gt 0) {
                        $actionParts += "відсутніх: $($Issue.ActionCounts.New)"
                    }
                    if ([int]$Issue.ActionCounts.Updated -gt 0) {
                        $actionParts += "застарілих: $($Issue.ActionCounts.Updated)"
                    }
                    if ($actionParts.Count -gt 0) {
                        $actionText = " ($($actionParts -join '; '))"
                    }
                }
                return ":warning: $componentName — локальні дані очікують передачі у хмару: $missingText$actionText$sizeText"
            }

            $differenceText = if ($null -eq $Issue.DifferenceCount) {
                "немає даних"
            } else {
                [string]$Issue.DifferenceCount
            }
            $actionParts = @()
            if ($null -ne $Issue.ActionCounts) {
                if ([int]$Issue.ActionCounts.New -gt 0) {
                    $actionParts += "нових: $($Issue.ActionCounts.New)"
                }
                if ([int]$Issue.ActionCounts.Updated -gt 0) {
                    $actionParts += "змінених: $($Issue.ActionCounts.Updated)"
                }
                if ([int]$Issue.ActionCounts.RemoteExtra -gt 0) {
                    $actionParts += "зайвих у хмарі: $($Issue.ActionCounts.RemoteExtra)"
                }
                if ([int]$Issue.ActionCounts.Other -gt 0) {
                    $actionParts += "очікують передачі: $($Issue.ActionCounts.Other)"
                }
            }
            $actionText = if ($actionParts.Count -gt 0) {
                " ($($actionParts -join '; '))"
            } else {
                ""
            }
            $sizeText = if ($null -ne $Issue.SizeBytes) {
                " • $(Format-FileSize $Issue.SizeBytes)"
            } else {
                ""
            }
            return ":warning: $componentName — $($Issue.Reason) • розбіжностей: $differenceText$actionText$sizeText"
        }
        default {
            return ":x: $componentName — $($Issue.Reason)"
        }
    }
}

function Format-CompactSMBIssue {
    param([object]$Issue)

    $componentName = Get-HealthIssueComponentName -Issue $Issue
    if ($Issue.Kind -eq "SMBArchive") {
        $actualSizeText = if ($null -ne $Issue.ActualSizeBytes) {
            " • $(Format-FileSize $Issue.ActualSizeBytes)"
        } else {
            ""
        }
        return ":warning: $componentName — $($Issue.Reason)$actualSizeText"
    }
    return ":x: $componentName — $($Issue.Reason)"
}

function New-SlackAlertMessage {
    param(
        [array]$Issues,
        [timespan]$Duration
    )

    $ukrainianCulture = [System.Globalization.CultureInfo]::GetCultureInfo("uk-UA")
    $dateText = $healthCheckStarted.ToString("dd MMMM yyyy", $ukrainianCulture).Replace(" р.", "")
    $durationSeconds = [math]::Max(0, [math]::Round($Duration.TotalSeconds))
    $hostInformation = Get-HostInformation
    $archiveVersionText = [string]$global:ScriptVersion
    $archiveScriptDateText = [string]$global:ScriptDate
    $problemComponentNames = @()
    foreach ($issue in $Issues) {
        $componentName = Get-HealthIssueComponentName -Issue $issue
        if ($problemComponentNames -notcontains $componentName) {
            $problemComponentNames += $componentName
        }
    }
    $localIssues = @($Issues | Where-Object {
        $_.Kind -in @("LocalBackup", "LocalSynchronization")
    })
    $serviceIssues = @($Issues | Where-Object { $_.Kind -eq "Service" })
    $sftpIssues = @($Issues | Where-Object {
        $_.Kind -in @("SFTPArchive", "SFTPSynchronization", "SFTPConnection")
    })
    $smbIssues = @($Issues | Where-Object {
        $_.Kind -in @("SMBArchive", "SMBConnection")
    })
    $knownKinds = @(
        "LocalBackup",
        "LocalSynchronization",
        "Service",
        "SFTPArchive",
        "SFTPSynchronization",
        "SFTPConnection",
        "SMBArchive",
        "SMBConnection"
    )
    $otherIssues = @($Issues | Where-Object { $_.Kind -notin $knownKinds })

    $alertTitle = if ($serviceIssues.Count -gt 0 -and $serviceIssues.Count -eq $Issues.Count) {
        "СЛУЖБИ BRAVO ПОТРЕБУЮТЬ УВАГИ"
    } else {
        "BRAVO ПОТРЕБУЄ УВАГИ"
    }
    $lines = @(
        ":rotating_light: *$alertTitle*",
        ":derelict_house_building: $($backupMonitoring.InstitutionName) [$($backupMonitoring.InstitutionCode)]",
        ":desktop_computer: $($hostInformation.MachineName) • $($hostInformation.LocalIP) | $($hostInformation.PublicIP)",
        ":clock3: $dateText, $($healthCheckStarted.ToString('HH:mm:ss')) • $durationSeconds сек.",
        "🏷️ Версія BRAVO_ARCHIV: $archiveVersionText від $archiveScriptDateText",
        ":pushpin: Проблемних компонентів: $($problemComponentNames.Count) • перевірок: $($Issues.Count)",
        "",
        ":package: $($problemComponentNames -join ', ')"
    )

    if ($serviceIssues.Count -gt 0) {
        $lines += ""
        $lines += ":gear: *СЛУЖБИ*"
        foreach ($issue in $serviceIssues) {
            $lines += ":x: $($issue.Component) — $($issue.Reason)"
        }
    }

    if ($localIssues.Count -gt 0) {
        $lines += ""
        $lines += ":floppy_disk: *ЛОКАЛЬНІ БЕКАПИ*"
        foreach ($issue in $localIssues) {
            $lines += Format-CompactLocalIssue -Issue $issue
        }
    }

    if ($sftpIssues.Count -gt 0) {
        $lines += ""
        $lines += ":cloud: *БЕКАПИ У ХМАРІ*"
        foreach ($issue in $sftpIssues) {
            $lines += Format-CompactSFTPIssue -Issue $issue
        }
    }

    if ($smbIssues.Count -gt 0) {
        $lines += ""
        $lines += ":minidisc: *NAS/SMB*"
        foreach ($issue in $smbIssues) {
            $lines += Format-CompactSMBIssue -Issue $issue
        }
    }

    if ($otherIssues.Count -gt 0) {
        $lines += ""
        $lines += ":warning: *ІНШІ ПОМИЛКИ*"
        foreach ($issue in $otherIssues) {
            $lines += ":x: $($issue.Component) — $($issue.Reason)"
        }
    }

    $bazaLocalHealthy = $bazaLocalHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "Локальна BAZA"
        }).Count -eq 0
    $bazaSFTPHealthy = [bool]$backupMonitoring.SFTP.Enabled -and
        [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaSFTPHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "SFTP BAZA" -or $_.Kind -eq "SFTPConnection"
        }).Count -eq 0
    if ($bazaLocalHealthy -or $bazaSFTPHealthy) {
        $lines += ""
        if ($bazaLocalHealthy -and $bazaSFTPHealthy) {
            $lines += ":white_check_mark: *BAZA_APP* — локальна копія та SFTP актуальні"
        } elseif ($bazaLocalHealthy) {
            $lines += ":white_check_mark: *BAZA_APP* — локальна копія актуальна"
        } else {
            $lines += ":white_check_mark: *BAZA_APP* — SFTP актуальна"
        }
    }
    $bazaWWWSFTPHealthy = [bool]$backupMonitoring.SFTP.Enabled -and
        [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "SFTP BAZA WWW" -or
            $_.Kind -eq "SFTPConnection"
        }).Count -eq 0
    if ($bazaWWWSFTPHealthy) {
        $lines += ""
        $lines += ":white_check_mark: *BAZA_WWW* — SFTP актуальна"
    }

    $lines += ""
    $lines += ":memo: Журнал: $healthLogFile"
    return $lines -join [Environment]::NewLine
}

function New-SlackSuccessMessage {
    param([timespan]$Duration)

    $ukrainianCulture = [System.Globalization.CultureInfo]::GetCultureInfo("uk-UA")
    $dateText = $healthCheckStarted.ToString("dd MMMM yyyy", $ukrainianCulture).Replace(" р.", "")
    $durationSeconds = [math]::Max(0, [math]::Round($Duration.TotalSeconds))
    $enabledNames = @(Get-EnabledBackupComponentNames)
    $enabledComponentsText = if ($enabledNames.Count -gt 0) {
        $enabledNames -join ', '
    } else {
        'немає'
    }
    $hostInformation = Get-HostInformation
    $archiveVersionText = [string]$global:ScriptVersion
    $archiveScriptDateText = [string]$global:ScriptDate

    $lines = @(
        ":white_check_mark: *РЕЗЕРВНІ КОПІЇ АКТУАЛЬНІ*",
        ":derelict_house_building: Установа: $($backupMonitoring.InstitutionName) [$($backupMonitoring.InstitutionCode)]",
        ":desktop_computer: Машина: $($hostInformation.MachineName)",
        ":globe_with_meridians: IP-адреси: $($hostInformation.LocalIP) | $($hostInformation.PublicIP)",
        ":spiral_calendar_pad: Дата: $dateText",
        ":alarm_clock: Час: $($healthCheckStarted.ToString('HH:mm:ss'))",
        ":hourglass_flowing_sand: Тривалість перевірки: $durationSeconds сек.",
        "🏷️ Версія BRAVO_ARCHIV: $archiveVersionText від $archiveScriptDateText",
        ":package: Увімкнені компоненти для бекапу: $enabledComponentsText",
        "",
        ":floppy_disk: Локальні архіви та hash-файли актуальні"
    )

    $latestArchiveLines = @(
        $archiveDefinitions |
            Where-Object { $_.Enabled } |
            ForEach-Object {
                $archiveInfo = $script:healthLatestArchives[$_.Type]
                $archiveName = if ($null -ne $archiveInfo) { [string]$archiveInfo.Name } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($archiveName)) {
                    $archiveSizeText = Format-FileSize -Bytes ([long]$archiveInfo.SizeBytes)
                    "• $($_.Type): $archiveName ($archiveSizeText)"
                }
            }
    )
    if ($latestArchiveLines.Count -gt 0) {
        $lines += ":package: Останні локальні архіви:"
        $lines += $latestArchiveLines
    }

    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckArchiveUploads -and
        $componentSettings.SFTP.ArchiveUpload) {
        $lines += ":cloud: Архіви у хмарі актуальні"
    }
    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaSFTPHealthEnabled) {
        $lines += ":arrows_counterclockwise: Синхронізація BAZA_APP з хмарою актуальна"
    }
    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled) {
        $lines += ":arrows_counterclockwise: Синхронізація BAZA_WWW з хмарою актуальна"
    }
    if ($bazaLocalHealthEnabled) {
        $lines += ":arrows_counterclockwise: Локальна копія BAZA_APP актуальна"
    }
    if ($backupMonitoring.SMB.Enabled -and
        $backupMonitoring.SMB.CheckArchiveCopies -and
        $componentSettings.SMB.ArchiveCopy) {
        $lines += ":minidisc: Архіви на NAS/SMB актуальні"
    }

    $lines += ""
    $lines += ":memo: Журнал перевірки: $healthLogFile"
    return $lines -join [Environment]::NewLine
}

function Get-AlertFingerprint {
    param([array]$Issues)

    $source = "compact-alert-v3`n" + (($Issues | ForEach-Object {
        if ($_.Kind -eq "SFTPSynchronization" -and
            $_.Reason -eq "у хмарі відсутні або потребують оновлення локальні файли/папки") {
            # Розмір черги BAZA природно змінюється щогодини. Він не має
            # створювати новий fingerprint та обходити RepeatAlertAfterHours.
            "$($_.Kind)|$($_.Component)|$($_.Reason)|$($_.Location)"
        } else {
            "$($_.Kind)|$($_.Component)|$($_.Reason)|$($_.FileName)|$($_.LastWriteTime)|$($_.Location)|$($_.DifferenceCount)|$($_.ExpectedSizeBytes)|$($_.ActualSizeBytes)|$($_.ActionCounts.New)|$($_.ActionCounts.Updated)|$($_.ActionCounts.RemoteExtra)|$($_.ActionCounts.Other)"
        }
    }) -join "`n")

    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($source)
        return [System.BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }
}

function Test-AlertSuppressed {
    param([string]$Fingerprint)

    if ($ForceNotification -or -not (Test-Path -Path $backupMonitoring.AlertStatePath -PathType Leaf)) {
        return $false
    }

    try {
        $state = Read-BRAVOTextFile -Path $backupMonitoring.AlertStatePath |
            ConvertFrom-BRAVOJson
        $lastSent = [datetime]::Parse(
            $state.LastSentUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        $timeSinceLastAlert = [datetime]::UtcNow - $lastSent.ToUniversalTime()
        return $state.Fingerprint -eq $Fingerprint -and
            $timeSinceLastAlert.TotalHours -lt [double]$backupMonitoring.RepeatAlertAfterHours
    } catch {
        Write-HealthLog "Не вдалося прочитати стан попереднього сповіщення: $($_.Exception.Message)" -Level "WARNING"
        return $false
    }
}

function Save-AlertState {
    param([string]$Fingerprint)

    $stateDirectory = Split-Path $backupMonitoring.AlertStatePath -Parent
    if (-not (Test-Path -Path $stateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $state = @{
        Fingerprint = $Fingerprint
        LastSentUtc = [datetime]::UtcNow.ToString("o")
    } | ConvertTo-BRAVOJson

    $temporaryStatePath = "$($backupMonitoring.AlertStatePath).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryStatePath,
            $state,
            [System.Text.Encoding]::UTF8
        )
        Move-Item -LiteralPath $temporaryStatePath -Destination $backupMonitoring.AlertStatePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryStatePath) {
            Remove-Item -LiteralPath $temporaryStatePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-AlertState {
    if (-not (Test-Path -LiteralPath $backupMonitoring.AlertStatePath -PathType Leaf)) {
        return
    }
    try {
        Remove-Item -LiteralPath $backupMonitoring.AlertStatePath -Force -ErrorAction Stop
        Write-HealthLog "Стан попередньої аварії очищено після успішної перевірки" -Level "INFO"
    } catch {
        # Неможливість очистити suppression-state не робить резервні копії
        # несправними, але має бути видимою у журналі.
        Write-HealthLog "Не вдалося очистити стан попереднього сповіщення: $($_.Exception.Message)" -Level "WARNING"
    }
}

function Send-SlackAlert {
    param([string]$Message)

    if ($NotificationProvider -notin @("slack", "discord")) {
        throw "Невідомий канал повідомлень: $NotificationProvider"
    }
    if ([string]::IsNullOrWhiteSpace($NotificationWebhookUrl) -or
        -not $NotificationWebhookUrl.StartsWith("https://")) {
        throw "Webhook для $NotificationProviderDisplayName не налаштовано або він не використовує HTTPS"
    }

    try {
        Enable-BRAVOTls12
    } catch {
        Write-HealthLog "Не вдалося примусово увімкнути TLS 1.2: $($_.Exception.Message)" -Level "DEBUG"
    }

    $notificationSeparator = (("━" * 36) -join "")
    $messageForWebhook = if ($Message.TrimStart().StartsWith($notificationSeparator)) {
        $Message
    } else {
        "$notificationSeparator`n$Message"
    }
    $outboundMessages = if ($NotificationProvider -eq "discord") {
        $discordMessage = ConvertTo-DiscordNotificationText -Message $messageForWebhook
        @(Split-DiscordNotificationText -Message $discordMessage)
    } else {
        @($messageForWebhook)
    }

    foreach ($outboundMessage in $outboundMessages) {
        $payload = if ($NotificationProvider -eq "discord") {
            @{
                content = $outboundMessage
                allowed_mentions = @{parse = @()}
            }
        } else {
            @{text = $outboundMessage}
        }
        $body = [System.Text.Encoding]::UTF8.GetBytes(
            ($payload | ConvertTo-BRAVOJson -Compress -Depth 5)
        )
        $request = [System.Net.WebRequest]::Create($NotificationWebhookUrl)
        $request.Method = "POST"
        $request.ContentType = "application/json; charset=utf-8"
        $request.ContentLength = $body.Length
        $request.Timeout = $NotificationRequestTimeoutSeconds * 1000
        $request.ReadWriteTimeout = $NotificationRequestTimeoutSeconds * 1000

        $requestStream = $null
        $response = $null
        $reader = $null
        try {
            $requestStream = $request.GetRequestStream()
            $requestStream.Write($body, 0, $body.Length)
            $requestStream.Dispose()
            $requestStream = $null

            $response = $request.GetResponse()
            $reader = New-Object System.IO.StreamReader(
                $response.GetResponseStream(),
                [System.Text.Encoding]::UTF8
            )
            $responseText = $reader.ReadToEnd().Trim()
            $reader.Dispose()
            $reader = $null
            $response.Dispose()
            $response = $null

            if ($NotificationProvider -eq "slack" -and
                -not [string]::IsNullOrWhiteSpace($responseText) -and
                $responseText -ne "ok") {
                throw "Slack повернув неочікувану відповідь: $responseText"
            }
        } catch [System.Net.WebException] {
            $webException = $_.Exception
            $statusText = "невідомий HTTP-статус"
            $responseText = ""
            $errorResponse = $webException.Response

            if ($null -ne $errorResponse) {
                try {
                    if ($errorResponse.StatusCode) {
                        $statusText = "$([int]$errorResponse.StatusCode) $($errorResponse.StatusDescription)"
                    }
                    $errorReader = New-Object System.IO.StreamReader(
                        $errorResponse.GetResponseStream(),
                        [System.Text.Encoding]::UTF8
                    )
                    try {
                        $responseText = $errorReader.ReadToEnd().Trim()
                    } finally {
                        $errorReader.Dispose()
                    }
                } catch {
                    $responseText = ""
                }
            }

            if ([string]::IsNullOrWhiteSpace($responseText)) {
                throw "$NotificationProviderDisplayName HTTP ${statusText}: $($webException.Message)"
            }
            throw "$NotificationProviderDisplayName HTTP ${statusText}: $responseText"
        } finally {
            if ($requestStream) { $requestStream.Dispose() }
            if ($reader) { $reader.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}

function Test-BRAVOArchiveProcessLockActive {
    $lockPath = Join-Path $logPath "BRAVO_OPERATION.lock"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        return $false
    }

    $lockStream = $null
    try {
        $lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        return $false
    } catch {
        return $true
    } finally {
        if ($lockStream) {
            $lockStream.Dispose()
        }
    }
}

if (-not $backupMonitoring.Enabled) {
    Write-HealthLog "Моніторинг резервних копій вимкнено в конфігурації" -Level "INFO"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Disabled"
        IssueCount = 0
        Notification = "NotSent"
        LogPath = $healthLogFile
    })
}

if ($NotificationProvider -notin @("slack", "discord") -or
    $NotificationMode -notin @("none", "errors_only", "all") -or
    ($NotificationMode -ne "none" -and
    ([string]::IsNullOrWhiteSpace($NotificationWebhookUrl) -or
    -not $NotificationWebhookUrl.StartsWith("https://")))) {
    $credentialDetails = if ($notificationCredentialError) { ": $notificationCredentialError" } else { "" }
    Write-HealthLog "Некоректно налаштовано канал повідомлень або його webhook у Credential Manager$credentialDetails" -Level "ERROR"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "ConfigurationError"
        IssueCount = 0
        Notification = "NotSent"
        LogPath = $healthLogFile
    })
}

if ($SkipIfBackupTaskRunning) {
    try {
        $backupTaskState = Get-BRAVOScheduledTaskState `
            -TaskPath ([string]$schedulerSettings.TaskPath) `
            -TaskName ([string]$schedulerSettings.Backup.TaskName)
        Write-HealthLog "Перевірка стану завдання архівації: $($backupTaskState.Provider)" -Level "DEBUG"

        $archiveProcessLockActive = Test-BRAVOArchiveProcessLockActive
        if ($backupTaskState.IsRunning -or $archiveProcessLockActive) {
            $runningIndicator = if (
                $backupTaskState.IsRunning -and $archiveProcessLockActive
            ) {
                "стан завдання та блокування процесу"
            } elseif ($backupTaskState.IsRunning) {
                "стан завдання"
            } else {
                "блокування процесу"
            }
            Write-HealthLog "Health-check відкладено: архівація зараз виконується ($runningIndicator)" -Level "INFO"
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "Deferred"
                IssueCount = 0
                Notification = "NotRequired"
                LogPath = $healthLogFile
            })
        }
    } catch {
        Write-HealthLog "Не вдалося перевірити стан завдання архівації; health-check продовжується: $($_.Exception.Message)" -Level "WARNING"
    }
}

Write-HealthLog "Конфігурація: $ConfigPath"
Write-HealthLog "Сумісність: Windows $($BRAVOCompatibility.WindowsVersion); PowerShell $($BRAVOCompatibility.PowerShellVersion); WMI=$($BRAVOCompatibility.WmiProvider); JSON=$($BRAVOCompatibility.JsonProvider); завдання=$($BRAVOCompatibility.TaskSchedulerProvider)"
Write-HealthLog "Каталог резервних копій: $backupRootPath"
if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
    Write-HealthLog $BRAVOPowerShellUpdate.Message -Level "WARNING"
}
$bazaLocalMode = if ($bazaLocalHealthEnabled) { "увімкнено" } else { "вимкнено" }
$bazaSFTPMode = if ($bazaSFTPHealthEnabled) { "увімкнено" } else { "вимкнено" }
$bazaWWWSFTPMode = if ($bazaWWWSFTPHealthEnabled) { "увімкнено" } else { "вимкнено" }
Write-HealthLog "Перевірка BAZA: локальна копія = $bazaLocalMode; SFTP = $bazaSFTPMode; BAZA WWW SFTP = $bazaWWWSFTPMode"
if ($bazaWWWSFTPHealthEnabled) {
    if ($bazaWWWDetection.Success) {
        Write-HealthLog (
            "BAZA WWW визначено через службу $($bazaWWWDetection.ServiceName): " +
            $bazaWWWPaths.Source
        ) -Level "INFO"
    } else {
        Write-HealthLog "BAZA WWW не визначено: $($bazaWWWDetection.Reason)" -Level "WARNING"
    }
}
Write-HealthLog "Початок перевірки резервних копій за останні $($backupMonitoring.MaxBackupAgeHours) год."
$serviceHealthIssues = @(Get-ManagedServiceHealthIssues)
$localHealthIssues = @(Get-BackupHealthIssues)
$bazaLocalHealthIssues = if ($bazaLocalHealthEnabled) {
    @(Get-BAZALocalHealthIssues)
} else {
    Write-HealthLog "Локальну перевірку BAZA пропущено: componentSettings.Synchronization.BAZALocal = `$false"
    @()
}
$sftpHealthIssues = @(Get-SFTPHealthIssues)
$smbHealthIssues = @(Get-SMBHealthIssues)
$healthIssues = @($serviceHealthIssues) + @($localHealthIssues) + @($bazaLocalHealthIssues) + @($sftpHealthIssues) + @($smbHealthIssues)

if ($healthIssues.Count -eq 0) {
    Write-HealthLog "Усі керовані служби працюють, а локальні, SFTP та NAS/SMB-компоненти мають актуальні резервні копії" -Level "SUCCESS"
    Clear-AlertState

    $sendSuccessNotification = (
        ($NotifyOnSuccess -or $ForceNotification) -and
        -not $NoSlack -and
        $NotificationMode -eq "all"
    )
    if ($sendSuccessNotification) {
        $healthDuration = (Get-Date) - $healthCheckStarted
        $successMessage = New-SlackSuccessMessage -Duration $healthDuration
        try {
            Send-SlackAlert -Message $successMessage
            Write-HealthLog "Успішний звіт відправлено у $NotificationProviderDisplayName" -Level "SUCCESS"
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "Healthy"
                IssueCount = 0
                Notification = "Sent"
                LogPath = $healthLogFile
            })
        } catch {
            Write-HealthLog "Не вдалося відправити успішний звіт у ${NotificationProviderDisplayName}: $($_.Exception.Message)" -Level "ERROR"
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "NotificationError"
                IssueCount = 0
                Notification = "Failed"
                LogPath = $healthLogFile
                Error = $_.Exception.Message
            })
        }
    }

    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Healthy"
        IssueCount = 0
        Notification = "NotRequired"
        LogPath = $healthLogFile
    })
}

foreach ($healthIssue in $healthIssues) {
    switch ($healthIssue.Kind) {
        "Service" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason)" -Level "ERROR"
        }
        "SFTPArchive" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); файл: $($healthIssue.FileName); фактичний розмір: $(Format-FileSize $healthIssue.ActualSizeBytes)" -Level "ERROR"
        }
        "SFTPSynchronization" {
            if ($healthIssue.Reason -eq "у хмарі відсутні або потребують оновлення локальні файли/папки") {
                $pendingParts = @()
                if ([int]$healthIssue.ActionCounts.New -gt 0) {
                    $pendingParts += "відсутніх: $($healthIssue.ActionCounts.New)"
                }
                if ([int]$healthIssue.ActionCounts.Updated -gt 0) {
                    $pendingParts += "застарілих: $($healthIssue.ActionCounts.Updated)"
                }
                if ([int]$healthIssue.ActionCounts.Other -gt 0) {
                    $pendingParts += "без окремої класифікації: $($healthIssue.ActionCounts.Other)"
                }
                $pendingSummary = if ($pendingParts.Count -gt 0) {
                    $pendingParts -join ", "
                } else {
                    "типи не визначено"
                }
                Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); очікують передачі: $($healthIssue.DifferenceCount) ($pendingSummary); розмір: $(Format-FileSize $healthIssue.SizeBytes)" -Level "ERROR"
            } else {
                $actionSummary = if ($null -ne $healthIssue.ActionCounts) {
                    "нових: $($healthIssue.ActionCounts.New), змінених: $($healthIssue.ActionCounts.Updated), зайвих у хмарі: $($healthIssue.ActionCounts.RemoteExtra), очікують передачі: $($healthIssue.ActionCounts.Other)"
                } else {
                    "типи розбіжностей: немає даних"
                }
                Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); розбіжностей: $($healthIssue.DifferenceCount) ($actionSummary); розмір: $(Format-FileSize $healthIssue.SizeBytes)" -Level "ERROR"
            }
            if ($healthIssue.Details -and $healthIssue.Details.Count -gt 0) {
                Write-HealthLog "Деталі $($healthIssue.Component): $($healthIssue.Details -join '; ')" -Level "ERROR"
            }
        }
        "LocalSynchronization" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); джерело: $($healthIssue.Source); локальна копія: $($healthIssue.Location); код robocopy: $($healthIssue.ExitCode)" -Level "ERROR"
        }
        "SFTPConnection" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason)" -Level "ERROR"
        }
        "SMBArchive" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); файл: $($healthIssue.FileName); фактичний розмір: $(Format-FileSize $healthIssue.ActualSizeBytes)" -Level "ERROR"
        }
        "SMBConnection" {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason)" -Level "ERROR"
        }
        default {
            Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); файл: $($healthIssue.FileName); вік: $(Format-BackupAge $healthIssue.LastWriteTime); розмір: $(Format-FileSize $healthIssue.SizeBytes)" -Level "ERROR"
        }
    }
}

$healthDuration = (Get-Date) - $healthCheckStarted
$slackMessage = New-SlackAlertMessage -Issues $healthIssues -Duration $healthDuration
$alertFingerprint = Get-AlertFingerprint -Issues $healthIssues

if ($NoSlack -or $NotificationMode -eq "none") {
    $disabledReason = if ($NoSlack) { "параметром -NoSlack" } else { "режимом none" }
    Write-HealthLog "Відправлення повідомлення вимкнено $disabledReason" -Level "WARNING"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Critical"
        IssueCount = $healthIssues.Count
        Notification = "Disabled"
        LogPath = $healthLogFile
        Message = $slackMessage
    })
}

if (Test-AlertSuppressed -Fingerprint $alertFingerprint) {
    Write-HealthLog "Повторне однакове сповіщення тимчасово пригнічено" -Level "INFO"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Critical"
        IssueCount = $healthIssues.Count
        Notification = "Suppressed"
        LogPath = $healthLogFile
    })
}

try {
    Send-SlackAlert -Message $slackMessage
    Save-AlertState -Fingerprint $alertFingerprint
    Write-HealthLog "Критичне повідомлення успішно відправлено у $NotificationProviderDisplayName" -Level "SUCCESS"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Critical"
        IssueCount = $healthIssues.Count
        Notification = "Sent"
        LogPath = $healthLogFile
    })
} catch {
    Write-HealthLog "Не вдалося відправити повідомлення у ${NotificationProviderDisplayName}: $($_.Exception.Message)" -Level "ERROR"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "NotificationError"
        IssueCount = $healthIssues.Count
        Notification = "Failed"
        LogPath = $healthLogFile
        Error = $_.Exception.Message
    })
}

}
# END BRAVO EMBEDDED HEALTH MODE

if ($HealthCheckOnly) {
    $healthParameters = @{
        ConfigPath = $ConfigPath
        ForceNotification = $ForceNotification
        NotifyOnSuccess = $NotifyOnSuccess
        NoSlack = $NoSlack
        SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning
    }
    $healthResult = Invoke-BRAVOEmbeddedHealth @healthParameters
    if ([string]$healthResult.Status -in @('Healthy', 'Skipped', 'Deferred', 'Disabled')) {
        exit 0
    }
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass –Force

# =============================================
# ЗАВАНТАЖЕННЯ КОНФІГУРАЦІЇ
# =============================================

# Перевірка наявності файлу конфігурації
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Host "ПОМИЛКА: Файл конфiгурацiї не знайдено: $ConfigPath" -ForegroundColor Red
    Write-Host "Створiть або налаштуйте файл BRAVO.config поруч зі скриптом." -ForegroundColor Yellow
    Exit 1
}

# Завантаження конфігурації
try {
    $configPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $configRoot = Split-Path -Path $configPath -Parent
    $configText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    $configScript = [scriptblock]::Create($configText)
    & $configScript -ConfigRoot $configRoot

    Write-Host "Конфiгурацiю завантажено успiшно: $configPath" -ForegroundColor $logColors.SUCCESS
} catch {
    Write-Host "ПОМИЛКА: Не вдалося завантажити конфiгурацiю: $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}

# Запит на підвищення дозволу виконання скрипта
if ($requireAdministrator) {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Потрiбнi права адмiнiстратора. Запит UAC..." -ForegroundColor $logColors.WARNING

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $elevationSettings.PowerShellExecutable
        $processInfo.Arguments = $elevationSettings.ArgumentsTemplate -f $PSCommandPath, $configPath
        if ($NoPause) {
            $processInfo.Arguments += " -NoPause"
        }
        if ($SyncBAZA) {
            $processInfo.Arguments += " -SyncBAZA"
        }
        $processInfo.Verb = $elevationSettings.Verb
        $processInfo.WindowStyle = $elevationSettings.WindowStyle

        try {
            $elevatedProcess = [System.Diagnostics.Process]::Start($processInfo)
            $elevatedProcess.WaitForExit()
            Exit $elevatedProcess.ExitCode
        } catch {
            Write-Host "UAC запит вiдхилено або сталася помилка: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
            Write-Host "Запустiть PowerShell з правами адмiнiстратора вручну" -ForegroundColor $logColors.WARNING
            Exit 1
        }
    }
}

# =============================================
# ЗАВАНТАЖЕННЯ СЕКРЕТІВ З CREDENTIAL MANAGER
# =============================================

$global:Login = $null
$global:sftpUrl = $null
$script:archivePassword = $null
$script:smbCredential = $null
$script:credentialInitializationError = $null
$script:archiveCredentialInitializationError = $null
$script:smbCredentialInitializationError = $null
$script:institutionSettingsInitializationError = $null
$script:notificationWebhookUrl = $null
$script:notificationCredentialInitializationError = $null
$script:notificationProvider = ([string]$bravoSettings.NotificationProvider).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($script:notificationProvider)) {
    $script:notificationProvider = "discord"
}
$script:notificationMode = [string]$bravoSettings.NotificationMode
if ([string]::IsNullOrWhiteSpace($script:notificationMode)) {
    $script:notificationMode = [string]$bravoSettings.SlackMode
}
if ([string]::IsNullOrWhiteSpace($script:notificationMode)) {
    $script:notificationMode = "none"
}
$script:notificationMode = $script:notificationMode.ToLowerInvariant()
$script:notificationRequestTimeoutSeconds = if ($null -ne $bravoSettings.NotificationRequestTimeoutSeconds) {
    [math]::Max(1, [int]$bravoSettings.NotificationRequestTimeoutSeconds)
} else {
    30
}
$sftpCredentialRequired = $SyncBAZA -or
    [bool]$componentSettings.SFTP.ArchiveUpload -or
    [bool]$componentSettings.Synchronization.BAZASFTP -or
    [bool]$componentSettings.Synchronization.BAZAWWWSFTP
$smbCredentialRequired = -not $SyncBAZA -and
    [bool]$componentSettings.SMB.ArchiveCopy
$archiveCredentialRequired = -not $SyncBAZA -and (
    [bool]$componentSettings.Archive.MODEL -or
    [bool]$componentSettings.Archive.BLOG -or
    [bool]$componentSettings.Archive.BRAVOEXCH
)
$institutionSettingsRequired = (
    $null -ne $bravoSettings.InstitutionName -and
    $null -ne $bravoSettings.InstitutionCode -and
    $null -ne $bravoSettings.ArchivePrefix
)
$script:notificationProviderDisplayName = if ($script:notificationProvider -eq "discord") {
    "Discord"
} else {
    "Slack"
}
# -SyncBAZA can emit an alert about objects which will never be uploaded.
# Load its webhook too, but treat a missing webhook as a notification error,
# not as a reason to stop the synchronization itself.
$notificationCredentialRequired = $script:notificationMode -ne "none"
$credentialHelperLoaded = $false

if ($institutionSettingsRequired -or
    $sftpCredentialRequired -or
    $smbCredentialRequired -or
    $archiveCredentialRequired -or
    $notificationCredentialRequired) {
    try {
        if ($null -eq (Get-Command -Name Initialize-BRAVOCredentialManager -ErrorAction SilentlyContinue)) {
            throw "вбудований Credential Manager недоступний"
        }
        $credentialHelperLoaded = $true
    } catch {
        if ($sftpCredentialRequired) {
            $script:credentialInitializationError = $_.Exception.Message
        }
        if ($archiveCredentialRequired) {
            $script:archiveCredentialInitializationError = $_.Exception.Message
        }
        if ($smbCredentialRequired) {
            $script:smbCredentialInitializationError = $_.Exception.Message
        }
        if ($institutionSettingsRequired) {
            $script:institutionSettingsInitializationError = $_.Exception.Message
        }
        if ($notificationCredentialRequired) {
            $script:notificationCredentialInitializationError = $_.Exception.Message
        }
    }
}

if ($credentialHelperLoaded) {
    try {
        [void](Import-BRAVOInstitutionSettings `
            -CredentialSettings $credentialSettings `
            -BravoSettings $bravoSettings)
    } catch {
        Write-Host "ПОМИЛКА: Некоректні локальні параметри установи у Credential Manager: $($_.Exception.Message)" `
            -ForegroundColor $logColors.ERROR
        exit 1
    }
} elseif ($institutionSettingsRequired) {
    Write-Host "ПОМИЛКА: Не вдалося завантажити локальні параметри установи: $($script:institutionSettingsInitializationError)" `
        -ForegroundColor $logColors.ERROR
    exit 1
}

if ($credentialHelperLoaded -and $archiveCredentialRequired) {
    try {
        $archiveCredentialTarget = [string]$credentialSettings.Targets.ArchivePassword
        if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
            $archiveCredentialTarget = "BRAVO_7Z_PASSWORD"
        }
        if ([string]::IsNullOrWhiteSpace($archiveCredentialTarget)) {
            throw "не вдалося визначити назву запису Credential Manager для пароля архівів"
        }
        $script:archivePassword = Get-BRAVOCredentialSecret -Target $archiveCredentialTarget
        if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            throw "запис Credential Manager '$archiveCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
    } catch {
        $script:archiveCredentialInitializationError = $_.Exception.Message
    }
}

if ($credentialHelperLoaded -and $sftpCredentialRequired) {
    try {
        $sftpLoginTarget = [string]$credentialSettings.Targets.SFTPLogin
        $sftpPasswordTarget = [string]$credentialSettings.Targets.SFTPPassword
        if ([string]::IsNullOrWhiteSpace($sftpLoginTarget)) {
            $sftpLoginTarget = "BRAVO_SFTP_LOGIN"
        }
        if ([string]::IsNullOrWhiteSpace($sftpPasswordTarget)) {
            $sftpPasswordTarget = "BRAVO_SFTP_PASSWORD"
        }

        $storedSftpLogin = Get-BRAVOCredentialSecret -Target $sftpLoginTarget
        $storedSftpPassword = Get-BRAVOCredentialSecret -Target $sftpPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSftpLogin)) {
            throw "запис Credential Manager '$sftpLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ([string]::IsNullOrWhiteSpace($storedSftpPassword)) {
            throw "запис Credential Manager '$sftpPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $global:Login = ([string]$storedSftpLogin).Trim()
        $configuredSftpHost = [string]$sftpHost
        $global:sftpHost = Resolve-BRAVOSftpHostName `
            -UserName $global:Login `
            -HostTemplate ([string]$sftpHostTemplate) `
            -FallbackHostName $configuredSftpHost
        $global:sftpUrl = New-BRAVOSftpUrl `
            -HostName $global:sftpHost `
            -Port ([int]$sftpPort) `
            -UserName $global:Login `
            -Password ([string]$storedSftpPassword)
        $storedSftpLogin = $null
        $storedSftpPassword = $null
    } catch {
        $script:credentialInitializationError = $_.Exception.Message
    }
}

if ($credentialHelperLoaded -and $smbCredentialRequired) {
    try {
        $smbLoginTarget = [string]$credentialSettings.Targets.SMBLogin
        $smbPasswordTarget = [string]$credentialSettings.Targets.SMBPassword
        if ([string]::IsNullOrWhiteSpace($smbLoginTarget)) {
            $smbLoginTarget = "BRAVO_SMB_LOGIN"
        }
        if ([string]::IsNullOrWhiteSpace($smbPasswordTarget)) {
            $smbPasswordTarget = "BRAVO_SMB_PASSWORD"
        }

        $storedSmbLogin = Get-BRAVOCredentialSecret -Target $smbLoginTarget
        $storedSmbPassword = Get-BRAVOCredentialSecret -Target $smbPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSmbLogin)) {
            throw "запис Credential Manager '$smbLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ([string]::IsNullOrWhiteSpace($storedSmbPassword)) {
            throw "запис Credential Manager '$smbPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $secureSmbPassword = ConvertTo-SecureString -String ([string]$storedSmbPassword) -AsPlainText -Force
        $script:smbCredential = New-Object System.Management.Automation.PSCredential(
            [string]$storedSmbLogin,
            $secureSmbPassword
        )
        $storedSmbLogin = $null
        $storedSmbPassword = $null
        $secureSmbPassword = $null
    } catch {
        $script:smbCredentialInitializationError = $_.Exception.Message
    }
}

if ($credentialHelperLoaded -and $notificationCredentialRequired) {
    try {
        if ($script:notificationProvider -notin @("slack", "discord")) {
            throw "невідомий канал повідомлень: $($script:notificationProvider)"
        }
        $notificationCredentialTarget = if ($script:notificationProvider -eq "discord") {
            [string]$credentialSettings.Targets.DiscordWebhook
        } else {
            [string]$credentialSettings.Targets.SlackWebhook
        }
        if ([string]::IsNullOrWhiteSpace($notificationCredentialTarget)) {
            $notificationCredentialTarget = if ($script:notificationProvider -eq "discord") {
                "BRAVO_DISCORD_URL"
            } else {
                "BRAVO_SLACK_URL"
            }
        }
        $script:notificationWebhookUrl = Get-BRAVOCredentialSecret -Target $notificationCredentialTarget
        if ([string]::IsNullOrWhiteSpace($script:notificationWebhookUrl)) {
            throw "запис Credential Manager '$notificationCredentialTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
    } catch {
        $script:notificationCredentialInitializationError = $_.Exception.Message
    }
}

# =============================================
# ІНІЦІАЛІЗАЦІЯ ЗМІННИХ З КОНФІГУРАЦІЇ
# =============================================

# РЕЖИМ СУМІСНОСТІ
$compatibilityMode = $false  # Автоматично визначається нижче

# =============================================
# НАЛАШТУВАННЯ КОНСОЛІ
# =============================================
$configuredOutputEncoding = [System.Text.Encoding]::GetEncoding($consoleSettings.OutputEncodingCodePage)
$global:OutputEncoding = $configuredOutputEncoding
try {
    [Console]::OutputEncoding = $configuredOutputEncoding
} catch {
    # Деякі PowerShell-hosts і запуски через Task Scheduler не мають
    # дійсного консольного дескриптора. Кодування зовнішніх команд уже
    # налаштовано через $OutputEncoding, тому роботу можна продовжити.
}
try {
    $Host.UI.RawUI.WindowTitle = $consoleSettings.WindowTitleTemplate -f $ScriptVersion
    $Host.UI.RawUI.BackgroundColor = $consoleSettings.BackgroundColor
    $Host.UI.RawUI.ForegroundColor = $consoleSettings.ForegroundColor
} catch {
    # RawUI може бути недоступним у неінтерактивному PowerShell-host.
}
if ($consoleSettings.ClearOnStart) {
    try {
        Clear-Host
    } catch {
        # Очищення екрана не є обов'язковим для роботи скрипта.
    }
}

# =============================================
# ФУНКЦІЇ ПЕРЕВІРКИ СУМІСНОСТІ
# =============================================

function Test-Compatibility {
    Write-Log "Перевiрка сумiсностi системи..." -Level "INFO"

    $script:hasFileHash = $BRAVOCompatibility.FileHashProvider -eq "Get-FileHash"
    $script:hasNetConnection = $BRAVOCompatibility.NetworkProvider -eq "Test-NetConnection"
    $script:compatibilityMode = [bool]$BRAVOCompatibility.IsCompatibilityMode

    Write-Log "Windows: $($BRAVOCompatibility.WindowsVersion); PowerShell: $($BRAVOCompatibility.PowerShellVersion)" -Level "DEBUG"
    Write-Log "WMI: $($BRAVOCompatibility.WmiProvider); Hash: $($BRAVOCompatibility.FileHashProvider); Network: $($BRAVOCompatibility.NetworkProvider); Files: $($BRAVOCompatibility.ChildItemProvider)" -Level "DEBUG"

    if ($script:compatibilityMode) {
        Write-Log "Режим сумiсностi активний: несумiснi сучаснi API буде автоматично замiнено" -Level "INFO"
    } else {
        Write-Log "Стандартний режим" -Level "INFO"
    }
    if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
        Write-Log $BRAVOPowerShellUpdate.Message -Level "WARNING"
    }

    return $BRAVOCompatibility
}

function New-SHA512HashLegacy {
    param(
        [string]$FilePath,
        [string]$HashFilePath
    )
    
    Write-Log "Створення SHA512 хешу (сумiсний режим): $(Split-Path $FilePath -Leaf)"
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Файл не знайдено: $FilePath" -Level "ERROR"
        return $false
    }
    
    try {
        # Використовуємо .NET для створення хешу в сумiсному режимi
        $fileStream = [System.IO.File]::OpenRead($FilePath)
        $hasher = [System.Security.Cryptography.SHA512]::Create()
        $hashBytes = $hasher.ComputeHash($fileStream)
        $fileStream.Close()
        
        # Конвертуємо байти в hex-рядок
        $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
        $fileName = (Get-Item $FilePath).Name
        
        # Виправлення для PowerShell 3.0: використовуємо .NET метод замiсть Out-File з -NoNewline
        [System.IO.File]::WriteAllText($HashFilePath, "${hash} *${fileName}", [System.Text.Encoding]::GetEncoding($hashFileEncoding))
        
        Write-Log "Хеш створено (сумiсний режим): $HashFilePath" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Помилка створення хешу (сумiсний режим): $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($hasher) { $hasher.Dispose() }
    }
}

function Test-NetworkConnectionLegacy {
    try {
        Write-Log "Перевiрка мережевого з'єднання (сумiсний режим)..." -Level "DEBUG"
        
        # Альтернативнi методи перевiрки мережi
        $ping = New-Object System.Net.NetworkInformation.Ping
        $result = $ping.Send($networkCheckHost, $networkPingTimeoutMilliseconds)
        
        if ($result.Status -eq "Success") {
            Write-Log "Мережеве з'єднання доступне (сумiсний режим)" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Мережеве з'єднання недоступне (сумiсний режим)" -Level "ERROR"
            return $false
        }
    } catch {
        Write-Log "Помилка перевiрки мережевого з'єднання (сумiсний режим): $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# =============================================
# ДОПОМІЖНІ ФУНКЦІЇ
# =============================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = $defaultLogLevel,
        [int]$SeparatorLength = $logSeparatorLength,
        [switch]$NoTimestamp,  # Новий параметр для вiдключення timestamp
        [switch]$FileOnly
    )
    
    # Отримуємо поточний рівень логування з глобальної змінної
    $currentLogLevel = if ($global:LogLevel -and $logLevels.ContainsKey($global:LogLevel)) { 
        $logLevels[$global:LogLevel] 
    } else { 
        $logLevels[$defaultLogLevel]
    }
    
    $messageLevel = if ($logLevels.ContainsKey($Level)) { 
        $logLevels[$Level] 
    } else { 
        $logLevels[$defaultLogLevel]
    }
    
    # Пропускаємо повідомлення нижчого рівня
    # FileOnly використовується для обов'язкового файлового аудиту:
    # такі записи зберігаються незалежно від поточного рівня журналу.
    if ($messageLevel -lt $currentLogLevel -and -not $FileOnly) {
        return
    }
    
    # Обробка спеціальних повідомлень-роздільників
    if ($Message -eq "=" -or $Message -eq "===") {
        # Генеруємо роздільник з вказаною кількістю знаків
        $separator = "=" * $SeparatorLength
        Write-Host $separator -ForegroundColor $logColors.Default
        try {
            if (-not (Test-Path $logPath)) {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
            }
            $separator | Out-File -FilePath $global:logFile -Append -Encoding $logFileEncoding
        } catch {
            Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
        }
        return
    }
    
    # Обробка заголовків
    if ($Message -match "^=== .* ===$") {
        # Для заголовків виводимо без timestamp та рівня
        Write-Host $Message -ForegroundColor $logColors.Header
        try {
            if (-not (Test-Path $logPath)) {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
            }
            $Message | Out-File -FilePath $global:logFile -Append -Encoding $logFileEncoding
        } catch {
            Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
        }
        return
    }
    
    # Звичайні повідомлення
    if ($NoTimestamp) {
        # Повідомлення без timestamp (для інформаційних блоків)
        $logEntry = $Message
        if (-not $FileOnly) {
            Write-Host $logEntry -ForegroundColor $logColors.Default
        }
    } else {
        # Звичайні повідомлення з timestamp
        $timestamp = Get-Date -Format $logTimestampFormat
        $logEntry = "[$timestamp] [$Level] $Message"
        $consoleEntry = if ($consoleSettings.ShowTimestampsInConsole) {
            $logEntry
        } else {
            "[$Level] $Message"
        }
        
        if (-not $FileOnly) {
            switch ($Level) {
                "SUCCESS" { Write-Host $consoleEntry -ForegroundColor $logColors.SUCCESS }
                "ERROR"   { Write-Host $consoleEntry -ForegroundColor $logColors.ERROR }
                "WARNING" { Write-Host $consoleEntry -ForegroundColor $logColors.WARNING }
                "DEBUG"   { Write-Host $consoleEntry -ForegroundColor $logColors.DEBUG }
                default   { Write-Host $consoleEntry -ForegroundColor $logColors.Default }
            }
        }
    }
    
    try {
        if (-not (Test-Path $logPath)) {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        $logEntry | Out-File -FilePath $global:logFile -Append -Encoding $logFileEncoding
    } catch {
        Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor $logColors.ERROR
    }
}

function Show-ScriptProgress {
    param(
        [string]$Status,
        [int]$PercentComplete = 0,
        [switch]$Completed
    )

    if (-not $progressSettings.Enabled -or -not $progressSettings.ShowOverallProgress) {
        return
    }

    if ($Completed) {
        Write-Progress -Id 1 -Activity $progressSettings.Activity -Completed
        return
    }

    $safePercent = [Math]::Max(0, [Math]::Min(100, $PercentComplete))
    Write-Progress -Id 1 -Activity $progressSettings.Activity -Status $Status -PercentComplete $safePercent
}

function Show-ItemProgress {
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Item,
        [int]$Current,
        [int]$Total,
        [switch]$Completed
    )

    if (-not $progressSettings.Enabled) {
        return
    }

    if ($Completed) {
        Write-Progress -Id $Id -Activity $Activity -Completed
        return
    }

    $safeTotal = [Math]::Max(1, $Total)
    $safeCurrent = [Math]::Max(0, [Math]::Min($safeTotal, $Current))
    $percent = [Math]::Floor(($safeCurrent * 100.0) / $safeTotal)
    $progressArguments = @{
        Id = $Id
        Activity = $Activity
        Status = "$Item ($safeCurrent з $safeTotal)"
        PercentComplete = $percent
    }
    if ($progressSettings.ShowOverallProgress) {
        $progressArguments.ParentId = 1
    }

    Write-Progress @progressArguments
}

function Show-RunningProgress {
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = -1,
        [switch]$Completed
    )

    if (-not $progressSettings.Enabled) {
        return
    }

    if ($Completed) {
        Write-Progress -Id $Id -Activity $Activity -Completed
        return
    }

    $safePercent = if ($PercentComplete -lt 0) {
        -1
    } else {
        [Math]::Max(0, [Math]::Min(100, $PercentComplete))
    }
    $progressArguments = @{
        Id = $Id
        Activity = $Activity
        Status = $Status
        PercentComplete = $safePercent
    }
    if ($progressSettings.ShowOverallProgress) {
        $progressArguments.ParentId = 1
    }

    Write-Progress @progressArguments
}

function Wait-ForManualExit {
    if ($NoPause -or -not $consoleSettings.PauseOnExit) {
        return
    }

    $prompt = [string]$consoleSettings.PausePrompt
    if ([string]::IsNullOrWhiteSpace($prompt)) {
        $prompt = "Натиснiть будь-яку клавiшу для закриття вiкна..."
    }

    Write-Host ""
    Write-Host $prompt -ForegroundColor $logColors.Progress
    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        # У хостах без RawUI очікуємо Enter; для -NonInteractive помилку ігноруємо.
        try {
            [void](Read-Host)
        } catch {
            Write-Log "Пауза завершення недоступна у цьому режимi PowerShell" -Level "DEBUG"
        }
    }
}

function Test-PathWithLog {
    param(
        [string]$Path,
        [string]$Description,
        [bool]$CreateIfMissing = $false
    )

    if (Test-Path $Path) {
        Write-Log "$Description знайдено: $Path" -Level "DEBUG"
        return $true
    } else {
        # Створення дозволяється лише для явно позначених каталогів призначення.
        if ($CreateIfMissing) {
            try {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
                Write-Log "$Description не знайдено, створено автоматично: $Path" -Level "SUCCESS"
                return $true
            } catch {
                Write-Log "$Description не знайдено i не вдалося створити: $Path" -Level "ERROR"
                return $false
            }
        } else {
            Write-Log "$Description не знайдено: $Path" -Level "ERROR"
            return $false
        }
    }
}

function Show-PathCheckSummary {
    param(
        [array]$CheckedPaths,
        [bool]$AllPathsExist
    )
    
    if ($AllPathsExist) {
        Write-Log "Всi необхiднi шляхи перевiрено успiшно" -Level "SUCCESS"
    } else {
        Write-Log "Знайдено помилки в шляхах - див. вище" -Level "ERROR"
    }
}

function Show-ArchiveCleanupSection {
    param([ref]$SectionShown)

    if (-not $SectionShown.Value) {
        Write-Log "==="
        Write-Log "=== ОЧИЩЕННЯ СТАРИХ АРХIВIВ ==="
        Show-ScriptProgress -Status "Очищення старих архiвiв" -PercentComplete 72
        $SectionShown.Value = $true
    }
}

function Remove-OldBackupSets {
    param(
        [string]$Path,
        [int]$RetentionDays,
        [string]$Component,
        [ref]$CleanupSectionShown
    )

    $failedArchiveDeletionEnabled = ($null -eq $enableFailedArchiveDeletion) -or [bool]$enableFailedArchiveDeletion
    if (-not $enableArchiveDeletion -and -not $failedArchiveDeletionEnabled) {
        return $true
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Log "Шлях архівів не знайдено: $Path" -Level "WARNING"
        return $false
    }

    try {
        $invalidRetentionDays = if ($null -ne $failedArchiveRetentionDays) {
            [math]::Max(1, [int]$failedArchiveRetentionDays)
        } else {
            30
        }
        $invalidCutoff = (Get-Date).AddDays(-$invalidRetentionDays)
        # Захист для старих конфігів без archiveRetentionDays: ніколи не
        # зменшуємо строк зберігання до одного дня через значення $null/0.
        $validRetentionDays = if ($RetentionDays -gt 0) {
            [int]$RetentionDays
        } else {
            183
        }
        $validCutoff = (Get-Date).AddDays(-$validRetentionDays)
        $validSets = @()
        foreach ($archive in @(Get-BRAVOFiles -Path $Path -Filter $archiveFileFilter)) {
            $hashPath = "$($archive.FullName)$hashFileExtension"
            $setValid = $false
            $invalidReason = ""
            try {
                if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
                    throw "відсутній hash-файл"
                }
                $hashText = ([System.IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
                if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
                    throw "некоректний формат hash-файлу"
                }
                if ($Matches.FileName -cne $archive.Name) {
                    throw "hash-файл належить іншому архіву"
                }
                $expectedHash = $Matches.Hash.ToUpperInvariant()
                $actualHash = (Get-BRAVOFileHash -Path $archive.FullName -Algorithm SHA512).Hash.ToUpperInvariant()
                if ($actualHash -cne $expectedHash) {
                    throw "SHA512 не збігається"
                }
                $setValid = $true
            } catch {
                $invalidReason = $_.Exception.Message
            }

            if ($setValid) {
                $validSets += [pscustomobject]@{
                    Archive = $archive
                    HashPath = $hashPath
                }
            } elseif ($failedArchiveDeletionEnabled -and $archive.LastWriteTime -lt $invalidCutoff) {
                Show-ArchiveCleanupSection -SectionShown $CleanupSectionShown
                Write-Log "Видалення непридатного комплекту ${Component}, старшого за $invalidRetentionDays днів: $($archive.Name) — $invalidReason" -Level "WARNING"
                Remove-Item -LiteralPath $archive.FullName -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
                    Remove-Item -LiteralPath $hashPath -Force -ErrorAction Stop
                }
            } else {
                Write-Log "Непридатний комплект збережено для діагностики: $($archive.Name) — $invalidReason" -Level "WARNING"
            }
        }
        $validSets = @($validSets | Sort-Object { $_.Archive.LastWriteTime } -Descending)

        foreach ($orphanHash in @(Get-BRAVOFiles -Path $Path -Filter "*$hashFileExtension")) {
            $archivePath = $orphanHash.FullName.Substring(0, $orphanHash.FullName.Length - $hashFileExtension.Length)
            if ($failedArchiveDeletionEnabled -and
                -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -and
                $orphanHash.LastWriteTime -lt $invalidCutoff) {
                Show-ArchiveCleanupSection -SectionShown $CleanupSectionShown
                Remove-Item -LiteralPath $orphanHash.FullName -Force -ErrorAction Stop
                Write-Log "Видалено застарілий hash-файл без архіву: $($orphanHash.Name)" -Level "WARNING"
            }
        }

        if (-not $enableArchiveDeletion) {
            return $true
        }

        # Зберігання коректних комплектів визначається календарним віком, а не
        # кількістю запусків: додатковий ручний бекап не скорочує строк зберігання.
        $setsToDelete = @($validSets | Where-Object {
            $_.Archive.LastWriteTime -lt $validCutoff
        })
        foreach ($set in $setsToDelete) {
            Show-ArchiveCleanupSection -SectionShown $CleanupSectionShown
            # Спочатку видаляється великий архів. Якщо видалення hash-файлу
            # не вдасться, залишиться лише безпечний сирота, а не архів без hash.
            Remove-Item -LiteralPath $set.Archive.FullName -Force -ErrorAction Stop
            try {
                Remove-Item -LiteralPath $set.HashPath -Force -ErrorAction Stop
            } catch {
                Write-Log "Архів видалено, але не вдалося видалити його hash-файл $($set.HashPath): $($_.Exception.Message)" -Level "WARNING"
            }
            Write-Log "Видалено комплект ${Component}, старший за $validRetentionDays днів: $($set.Archive.Name)" -Level "SUCCESS"
        }
        return $true
    } catch {
        Write-Log "Помилка очищення комплектів ${Component}: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Remove-OldLunchArchives {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string[]]$Directories,
        [int]$RetentionMonths = 2
    )

    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
        Write-Log "Каталог обідніх архівів не знайдено: $ArchiveRoot" -Level "ERROR"
        return $false
    }

    $resolvedArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
    $effectiveRetentionMonths = [Math]::Max(1, $RetentionMonths)
    $cutoff = (Get-Date).AddMonths(-$effectiveRetentionMonths)
    $failed = $false
    $deletedCount = 0

    Write-Log "==="
    Write-Log "=== ОЧИЩЕННЯ СТАРИХ ОБІДНІХ АРХІВІВ ==="
    Write-Log "Дата відсічення: $cutoff; маркер імені: _1300." -Level "INFO"

    foreach ($directory in @($Directories | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })) {
        $directoryPath = Join-Path -Path $resolvedArchiveRoot -ChildPath $directory
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            Write-Log "Каталог обідніх архівів не знайдено: $directoryPath" -Level "WARNING"
            $failed = $true
            continue
        }
        $resolvedDirectoryPath = (Resolve-Path -LiteralPath $directoryPath -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
        $archiveRootPrefix = $resolvedArchiveRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedDirectoryPath.StartsWith($archiveRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "Небезпечний каталог очищення поза ArchiveRoot пропущено: $directory" -Level "ERROR"
            $failed = $true
            continue
        }

        $directoryDeletedCount = 0
        $archiveSets = @{}
        foreach ($file in @(Get-BRAVOFiles -LiteralPath $resolvedDirectoryPath -Filter "*_1300.*")) {
            $setName = if ($file.Name -like "*.mdz.sha512") {
                $file.Name.Substring(0, $file.Name.Length - ".sha512".Length)
            } elseif ($file.Name -like "*.mdz") {
                $file.Name
            } else {
                continue
            }
            if (-not $archiveSets.ContainsKey($setName)) {
                $archiveSets[$setName] = @{}
            }
            if ($file.Name -like "*.mdz.sha512") {
                $archiveSets[$setName].Hash = $file
            } else {
                $archiveSets[$setName].Archive = $file
            }
        }

        foreach ($setName in @($archiveSets.Keys | Sort-Object)) {
            $archiveSet = $archiveSets[$setName]
            if (-not $archiveSet.ContainsKey("Archive") -or -not $archiveSet.ContainsKey("Hash")) {
                Write-Log "Неповний обідній комплект залишено без змін: $setName" -Level "WARNING"
                continue
            }
            $setLastWriteTime = (@(
                $archiveSet.Archive.LastWriteTime,
                $archiveSet.Hash.LastWriteTime
            ) | Measure-Object -Maximum).Maximum
            if ($setLastWriteTime -ge $cutoff) {
                continue
            }
            try {
                Remove-Item -LiteralPath $archiveSet.Archive.FullName -Force -ErrorAction Stop
                Remove-Item -LiteralPath $archiveSet.Hash.FullName -Force -ErrorAction Stop
                $directoryDeletedCount += 2
                $deletedCount += 2
                Write-Log "Видалено обідній комплект: $setName і $($archiveSet.Hash.Name)" -Level "SUCCESS"
            } catch {
                $failed = $true
                Write-Log "Не вдалося видалити обідній комплект ${setName}: $($_.Exception.Message)" -Level "ERROR"
            }
        }

        Write-Log "Каталог ${directory}: видалено $directoryDeletedCount обідніх файлів" -Level "INFO"
    }

    Write-Log "Усього видалено обідніх файлів: $deletedCount" -Level "INFO"
    return (-not $failed)
}

function Remove-OldLogsByAge {
    param(
        [string]$Path,
        [string]$Filter,
        [int]$RetentionDays
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $failed = $false
    foreach ($file in @(Get-BRAVOFiles -Path $Path -Filter $Filter |
        Where-Object { $_.LastWriteTime -lt $cutoff })) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-Log "Видалено старий лог: $($file.Name)" -Level "SUCCESS"
        } catch {
            $failed = $true
            Write-Log "Не вдалося видалити лог $($file.Name): $($_.Exception.Message)" -Level "ERROR"
        }
    }
    return (-not $failed)
}

function Sync-Folders {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    
    Write-Log "Синхронiзацiя: $SourcePath -> $DestinationPath"
    
    if (-not (Test-Path $SourcePath)) {
        Write-Log "Джерельна папка не знайдена: $SourcePath" -Level "ERROR"
        return $false
    }
    
    try {
        # Створюємо цільову папку, якщо не існує
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Write-Log "Створено цiльову папку: $DestinationPath" -Level "SUCCESS"
        }
        
        # Виконуємо синхронізацію за допомогою Robocopy
        $effectiveRobocopyOptions = @($robocopyOptions)
        $showRobocopyProgress = $progressSettings.Enabled -and $progressSettings.ShowRobocopyOutput

        if ($showRobocopyProgress) {
            # /NP приховує відсотки, тому прибираємо його лише для режиму прогресу.
            $effectiveRobocopyOptions = @($effectiveRobocopyOptions | Where-Object { $_ -ine "/NP" })
            foreach ($progressOption in @($progressSettings.RobocopyProgressOptions)) {
                if (-not [string]::IsNullOrWhiteSpace($progressOption) -and
                    -not ($effectiveRobocopyOptions -icontains $progressOption)) {
                    $effectiveRobocopyOptions += $progressOption
                }
            }
        }

        $robocopyArgs = @("`"$SourcePath`"", "`"$DestinationPath`"") + $effectiveRobocopyOptions
        
        Write-Log "Виконання: robocopy $robocopyArgs" -Level "DEBUG"

        if ($showRobocopyProgress) {
            # Локалізований текст Robocopy використовує OEM-кодування і в деяких
            # PowerShell-hosts відображається пошкодженим. Вивід спрямовується у
            # NUL, а скрипт показує власний незалежний індикатор виконання.
            $progressRobocopyArgs = @($robocopyArgs) + @("/LOG:NUL")
            $process = Start-Process `
                -FilePath $robocopyPath `
                -ArgumentList $progressRobocopyArgs `
                -PassThru `
                -WindowStyle $robocopyWindowStyle
            $robocopyStarted = Get-Date
            do {
                $process.Refresh()
                $elapsed = [math]::Floor(((Get-Date) - $robocopyStarted).TotalSeconds)
                Show-RunningProgress `
                    -Id 3 `
                    -Activity "Robocopy — синхронiзацiя BAZA" `
                    -Status "Виконується, минуло $elapsed сек." `
                    -PercentComplete -1
                if (-not $process.HasExited) {
                    Start-Sleep -Milliseconds 500
                }
            } while (-not $process.HasExited)
            $process.WaitForExit()
            Show-RunningProgress -Id 3 -Activity "Robocopy — синхронiзацiя BAZA" -Completed
            $exitCode = $process.ExitCode
        } else {
            $process = Start-Process -FilePath $robocopyPath -ArgumentList $robocopyArgs -Wait -PassThru -WindowStyle $robocopyWindowStyle
            $exitCode = $process.ExitCode
        }
        
        # Коди виходу Robocopy: 0-7 = успіх, 8+ = помилка
        if ($exitCode -le $robocopyMaxSuccessExitCode) {
            Write-Log "Синхронiзацiя успiшна (код: $exitCode)" -Level "DEBUG"
            return $true
        } else {
            Write-Log "Помилка синхронiзацiї (код: $exitCode)" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Помилка синхронiзацiї: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# =============================================
# ФУНКЦІЇ АРХІВАЦІЇ
# =============================================

function Test-SevenZipArchiveIntegrity {
    param(
        [string]$SevenZipPath,
        [string]$ArchivePath,
        [string]$Password,
        [int]$TimeoutSeconds = 43200
    )

    Write-Log "Перевiрка цiлiсностi 7-Zip: $(Split-Path $ArchivePath -Leaf)"
    $testResult = Invoke-BRAVOSevenZipIntegrityTest `
        -SevenZipPath $SevenZipPath `
        -ArchivePath $ArchivePath `
        -Password $Password `
        -TimeoutSeconds $TimeoutSeconds

    $exitCodeText = if ($null -eq $testResult.ExitCode) {
        "немає"
    } else {
        [string]$testResult.ExitCode
    }
    if ($testResult.Success) {
        Write-Log "Цiлiснiсть архiву пiдтверджено 7-Zip (код: 0): $ArchivePath" -Level "SUCCESS"
        return $true
    }

    Write-Log "Перевiрка цiлiсностi 7-Zip не пройдена (код: $exitCodeText — $($testResult.Description)): $ArchivePath" -Level "ERROR"
    $diagnosticLines = @(
        @($testResult.StandardError, $testResult.StandardOutput) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ -split '\r?\n' } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 20
    )
    if ($diagnosticLines.Count -gt 0) {
        Write-Log "Дiагностика 7-Zip test: $($diagnosticLines -join [Environment]::NewLine)" -Level "DEBUG"
    }
    return $false
}

function Write-SevenZipFailureDiagnostics {
    param([string]$Operation, [string]$StandardOutput, [string]$StandardError)
    foreach ($line in @($StandardOutput, $StandardError)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log "${Operation}: $($line.Trim().Substring(0, [math]::Min(4000, $line.Trim().Length)))" -Level 'DEBUG'
        }
    }
}

function Get-BRAVOVSSSnapshotSourcePath {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DeviceObject
    )

    $normalizedSourcePath = $SourcePath.Replace("/", "\")
    $volumeRoot = [IO.Path]::GetPathRoot($normalizedSourcePath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        $volumeRoot -notmatch '^[A-Za-z]:\\$') {
        throw "VSS підтримує лише локальний шлях із літерою диска: $SourcePath"
    }
    if ([string]::IsNullOrWhiteSpace($DeviceObject)) {
        throw "VSS не повернув шлях DeviceObject для джерела: $SourcePath"
    }

    $snapshotRoot = $DeviceObject.TrimEnd([char[]]"\/")
    $relativePath = $normalizedSourcePath.Substring($volumeRoot.Length).TrimStart([char[]]"\/")
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return "$snapshotRoot\"
    }
    return "$snapshotRoot\$relativePath"
}

function Get-BRAVOVSSReturnCodeDescription {
    param([int]$ReturnCode)

    $descriptions = @{
        0 = "успішно"
        1 = "доступ заборонено"
        2 = "некоректний аргумент"
        3 = "том не знайдено"
        4 = "том не підтримує VSS"
        5 = "контекст VSS не підтримується"
        6 = "недостатньо місця для shadow copy"
        7 = "том зайнятий"
        8 = "досягнуто максимальну кількість shadow copies"
        9 = "вже виконується інша операція shadow copy"
        10 = "VSS provider відхилив операцію"
        11 = "VSS provider не зареєстрований"
        12 = "помилка VSS provider"
        13 = "невідома помилка VSS"
    }
    if ($descriptions.ContainsKey($ReturnCode)) {
        return $descriptions[$ReturnCode]
    }
    return "невідома помилка VSS"
}

function New-BRAVOVSSSnapshot {
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    $normalizedSourcePath = $SourcePath.Replace("/", "\")
    $volumeRoot = [IO.Path]::GetPathRoot($normalizedSourcePath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        $volumeRoot -notmatch '^[A-Za-z]:\\$') {
        throw "Не вдалося визначити локальний том VSS для джерела: $SourcePath"
    }

    $snapshotContext = [string]$backupConsistency.SnapshotContext
    if ([string]::IsNullOrWhiteSpace($snapshotContext)) {
        $snapshotContext = "ClientAccessible"
    }

    $shadowId = $null
    try {
        Write-Log "Створення VSS-знімка тому $volumeRoot для узгодженої архівації" -Level "INFO"
        $shadowClass = [wmiclass]"\\.\root\cimv2:Win32_ShadowCopy"
        $createResult = $shadowClass.Create($volumeRoot, $snapshotContext)
        if ($null -eq $createResult) {
            throw "Win32_ShadowCopy.Create не повернув результат"
        }

        $returnCode = [int]$createResult.ReturnValue
        if ($returnCode -ne 0) {
            $description = Get-BRAVOVSSReturnCodeDescription -ReturnCode $returnCode
            throw "Win32_ShadowCopy.Create повернув код $returnCode ($description)"
        }

        $shadowId = [string]$createResult.ShadowID
        if ([string]::IsNullOrWhiteSpace($shadowId)) {
            throw "VSS не повернув ідентифікатор створеного знімка"
        }

        $escapedShadowId = $shadowId.Replace("'", "''")
        $shadow = Get-WmiObject `
            -Namespace "root\cimv2" `
            -Class "Win32_ShadowCopy" `
            -Filter ("ID='{0}'" -f $escapedShadowId) `
            -ErrorAction Stop |
            Select-Object -First 1
        if ($null -eq $shadow -or [string]::IsNullOrWhiteSpace([string]$shadow.DeviceObject)) {
            throw "створений VSS-знімок $shadowId не знайдено"
        }

        $snapshotSourcePath = Get-BRAVOVSSSnapshotSourcePath `
            -SourcePath $SourcePath `
            -DeviceObject ([string]$shadow.DeviceObject)
        Write-Log "VSS-знімок створено: $shadowId" -Level "SUCCESS"
        return [pscustomobject]@{
            Id = $shadowId
            VolumeRoot = $volumeRoot
            DeviceObject = [string]$shadow.DeviceObject
            SourcePath = $snapshotSourcePath
            WmiObject = $shadow
        }
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($shadowId)) {
            try {
                $escapedShadowId = $shadowId.Replace("'", "''")
                $orphanedShadow = Get-WmiObject `
                    -Namespace "root\cimv2" `
                    -Class "Win32_ShadowCopy" `
                    -Filter ("ID='{0}'" -f $escapedShadowId) `
                    -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($null -ne $orphanedShadow) {
                    $null = $orphanedShadow.Delete()
                }
            } catch {
                # Основна помилка створення VSS важливіша за помилку best-effort cleanup.
            }
        }
        throw
    }
}

function Remove-BRAVOVSSSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    try {
        $deleteResult = $Snapshot.WmiObject.Delete()
        if ($null -ne $deleteResult -and [int]$deleteResult.ReturnValue -ne 0) {
            $returnCode = [int]$deleteResult.ReturnValue
            $description = Get-BRAVOVSSReturnCodeDescription -ReturnCode $returnCode
            Write-Log "Не вдалося видалити VSS-знімок $($Snapshot.Id): код $returnCode ($description)" -Level "ERROR"
            return $false
        }
        Write-Log "VSS-знімок видалено: $($Snapshot.Id)" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Не вдалося видалити VSS-знімок $($Snapshot.Id): $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function New-Archive {
    param(
        [string]$SourcePath,
        [string]$ArchivePath,
        [string]$ArchiveName,
        [string]$ArcPath,
        [string]$ArcParams
    )
    
    Write-Log "Створення архiву: $ArchiveName"
    
    $archiveDir = Split-Path $ArchivePath -Parent
    if (-not (Test-Path $archiveDir)) {
        try {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
            Write-Log "Каталог створено: $archiveDir" -Level "SUCCESS"
        } catch {
            Write-Log "Помилка при створеннi каталогу: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }
    
    if (-not (Test-Path $SourcePath)) {
        Write-Log "Джерело не знайдено: $SourcePath" -Level "ERROR"
        return $false
    }
    
    $fullArchivePath = Join-Path $ArchivePath $ArchiveName
    
    try {
        if ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            Write-Log "Пароль архiву не завантажено з Windows Credential Manager" -Level "ERROR"
            return $false
        }
        if ($script:archivePassword.IndexOfAny([char[]]"`r`n") -ge 0) {
            Write-Log "Пароль архiву не може мiстити символи нового рядка" -Level "ERROR"
            return $false
        }

        $effectiveArcParams = $ArcParams
        $showSevenZipProgress = $progressSettings.Enabled -and $progressSettings.ShowSevenZipOutput
        $integrityTestTimeoutSeconds = if (
            $null -ne $progressSettings.SevenZipTestTimeoutSeconds
        ) {
            [math]::Max(0, [int]$progressSettings.SevenZipTestTimeoutSeconds)
        } else {
            43200
        }

        $staleHashPath = "$fullArchivePath$hashFileExtension"
        if (Test-Path -LiteralPath $staleHashPath -PathType Leaf) {
            Remove-Item -LiteralPath $staleHashPath -Force -ErrorAction Stop
            Write-Log "Видалено попереднiй hash-файл перед повторним створенням архiву: $staleHashPath" -Level "WARNING"
        }

        # -p без значення вмикає шифрування і читає пароль зі stdin.
        $arguments = "$effectiveArcParams -p `"$fullArchivePath`" `"$SourcePath`""
        Write-Log "Команда: $ArcPath $arguments (пароль передається через stdin)" -Level "DEBUG"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $ArcPath
        $processInfo.Arguments = $arguments
        $processInfo.RedirectStandardInput = $true
        # Потоки завжди перенаправляються, щоб технічний вивід 7-Zip не
        # дублював журнал. Власний індикатор показує час і поточний розмір.
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        # Сучасні ОС використовують ReadToEndAsync, Windows 7/.NET 4.0 —
        # сумісний подієвий механізм зі спільного модуля.
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $process.StandardInput.WriteLine($script:archivePassword)
        $process.StandardInput.Close()
        $sevenZipProgressId = 2
        $progressActivity = "7-Zip — $ArchiveName"
        $archiveStarted = Get-Date
        $archiveTimeoutSeconds = if ($null -ne $progressSettings.SevenZipTimeoutSeconds) {
            [math]::Max(0, [int]$progressSettings.SevenZipTimeoutSeconds)
        } else {
            43200
        }
        $archiveTimedOut = $false

        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $archiveStarted).TotalSeconds)
            if ($showSevenZipProgress) {
                $currentSizeText = "очiкування створення файла"
                if (Test-Path -LiteralPath $fullArchivePath -PathType Leaf) {
                    $currentArchiveLength = (Get-Item -LiteralPath $fullArchivePath).Length
                    $currentSizeText = "поточний розмiр: {0:N1} МБ" -f ($currentArchiveLength / 1MB)
                }
                Show-RunningProgress `
                    -Id $sevenZipProgressId `
                    -Activity $progressActivity `
                    -Status "Виконується $elapsedSeconds сек.; $currentSizeText" `
                    -PercentComplete -1
            }

            if ($archiveTimeoutSeconds -gt 0 -and $elapsedSeconds -ge $archiveTimeoutSeconds) {
                $archiveTimedOut = $true
                try {
                    $process.Kill()
                } catch {
                    # Процес міг завершитися між перевіркою таймауту та Kill().
                }
                break
            }
        }

        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "7-Zip не завершився протягом 5 секунд після спроби примусового завершення"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $standardOutput = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        if ($showSevenZipProgress) {
            Show-RunningProgress -Id $sevenZipProgressId -Activity $progressActivity -Completed
        }
        $lastSevenZipOutput = @($standardOutput -split "\r?\n" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Last 1)

        if ($archiveTimedOut) {
            Write-Log "Архiвацiю перервано: перевищено таймаут $archiveTimeoutSeconds сек.: $ArchiveName" -Level "ERROR"
            if (Test-Path -LiteralPath $fullArchivePath -PathType Leaf) {
                Remove-Item -LiteralPath $fullArchivePath -Force -ErrorAction SilentlyContinue
                Write-Log "Неповний архiв видалено: $fullArchivePath" -Level "WARNING"
            }
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Архiв створено; виконується контроль цiлiсностi: $fullArchivePath" -Level "INFO"
            if (Test-SevenZipArchiveIntegrity `
                -SevenZipPath $ArcPath `
                -ArchivePath $fullArchivePath `
                -Password $script:archivePassword `
                -TimeoutSeconds $integrityTestTimeoutSeconds) {
                Write-Log "Архiв створено та перевiрено: $fullArchivePath" -Level "SUCCESS"
                return $true
            }
            Write-Log "Пошкоджений або неперевiрений архiв залишено для дiагностики; hash i передача не виконуватимуться: $fullArchivePath" -Level "ERROR"
            return $false
        } else {
            $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $process.ExitCode
            Write-Log "Помилка архiвацiї 7-Zip (код: $($process.ExitCode) — $exitDescription): $fullArchivePath" -Level "ERROR"
            Write-SevenZipFailureDiagnostics -Operation "Дiагностика 7-Zip create" -StandardOutput $standardOutput -StandardError $errorOutput
            if ($showSevenZipProgress) {
                if (-not [string]::IsNullOrWhiteSpace($lastSevenZipOutput)) {
                    Write-Log "Останнiй вивiд 7-Zip: $lastSevenZipOutput" -Level "DEBUG"
                }
                if (-not [string]::IsNullOrWhiteSpace($errorOutput)) {
                    Write-Log "Помилка 7-Zip: $errorOutput" -Level "DEBUG"
                }
            } else {
                Write-Log "Деталi: $errorOutput" -Level "DEBUG"
            }
            return $false
        }
    } catch {
        Write-Log "Помилка архiвацiї: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function New-SHA512Hash {
    param(
        [string]$FilePath,
        [string]$HashFilePath
    )
    
    if ($script:compatibilityMode) {
        # У режимі сумісності використовуємо тільки сумісну функцію
        return New-SHA512HashLegacy -FilePath $FilePath -HashFilePath $HashFilePath
    } else {
        Write-Log "Створення SHA512 хешу: $(Split-Path $FilePath -Leaf)"
        
        if (-not (Test-Path $FilePath)) {
            Write-Log "Файл не знайдено: $FilePath" -Level "ERROR"
            return $false
        }
        
        try {
            # Використовуємо стандартний метод, якщо доступний
            if ($script:hasFileHash) {
                $hash = (Get-BRAVOFileHash -Path $FilePath -Algorithm SHA512).Hash.ToLower()
                Write-Log "Хеш створено (стандартний метод): $HashFilePath" -Level "SUCCESS"
            } else {
                # Використовуємо сумісний метод
                return New-SHA512HashLegacy -FilePath $FilePath -HashFilePath $HashFilePath
            }
            
            $fileName = (Get-Item $FilePath).Name
            
            # Виправлення для PowerShell 4.0: використовуємо .NET метод замість Out-File з -NoNewline
            [System.IO.File]::WriteAllText($HashFilePath, "${hash} *${fileName}", [System.Text.Encoding]::GetEncoding($hashFileEncoding))
            
            return $true
        } catch {
            Write-Log "Помилка створення хешу: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }
}

# =============================================
# ФУНКЦІЇ МЕРЕЖІ ТА SFTP
# =============================================

function Test-SFTPConfig {
    param(
        [switch]$BAZAOnly,
        [switch]$SynchronizationOnly
    )

    $configurationErrors = @()

    if (-not [string]::IsNullOrWhiteSpace($script:credentialInitializationError)) {
        $configurationErrors += $script:credentialInitializationError
    }
    if ([string]::IsNullOrWhiteSpace($Login)) {
        $configurationErrors += "не завантажено SFTP логiн з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace($sftpUrl) -or -not $sftpUrl.StartsWith("sftp://")) {
        $configurationErrors += "не вдалося сформувати SFTP URL із захищених облікових даних"
    }
    if ([string]::IsNullOrWhiteSpace($sftpHostKey)) {
        $configurationErrors += "не встановлено SFTP host key"
    }
    if ([string]::IsNullOrWhiteSpace($winSCPPath) -or -not (Test-Path -Path $winSCPPath -PathType Leaf)) {
        $configurationErrors += "не знайдено WinSCP: $winSCPPath"
    }

    if (-not $BAZAOnly -and -not $SynchronizationOnly -and $componentSettings.SFTP.ArchiveUpload) {
        foreach ($archive in ($archiveDefinitions | Where-Object { $_.Enabled })) {
            if (-not $sftpDirectories.ContainsKey($archive.Type) -or [string]::IsNullOrWhiteSpace($sftpDirectories[$archive.Type])) {
                $configurationErrors += "не встановлено SFTP каталог для архiву $($archive.Type)"
            }
        }
    }

    if ($BAZAOnly -or $componentSettings.Synchronization.BAZASFTP) {
        if (-not $sftpDirectories.ContainsKey("BAZA") -or [string]::IsNullOrWhiteSpace($sftpDirectories.BAZA)) {
            $configurationErrors += "не встановлено SFTP каталог для BAZA"
        }
    }
    if ($componentSettings.Synchronization.BAZAWWWSFTP) {
        if (-not $sftpDirectories.ContainsKey("BAZAWWW") -or
            [string]::IsNullOrWhiteSpace($sftpDirectories.BAZAWWW)) {
            $configurationErrors += "не встановлено SFTP каталог для BAZA WWW"
        }
    }
    if ($BAZAOnly -or
        $componentSettings.Synchronization.BAZASFTP -or
        $componentSettings.Synchronization.BAZAWWWSFTP) {
        if ([string]$sftpSynchronizationOptions -match '(?i)(^|\s)-delete(\s|$)') {
            $configurationErrors += "опція -delete заборонена для BAZA: віддалені файли мають зберігатися для відновлення"
        }
    }

    if ($configurationErrors.Count -gt 0) {
        foreach ($configurationError in $configurationErrors) {
            Write-Log "Помилка конфiгурацiї SFTP: $configurationError" -Level "ERROR"
        }
        return $false
    }

    Write-Log "Доступ до SFTP налаштовано коректно" -Level "SUCCESS"
    return $true
}

function Test-SMBConfig {
    $configurationErrors = @()

    if (-not [string]::IsNullOrWhiteSpace($script:smbCredentialInitializationError)) {
        $configurationErrors += $script:smbCredentialInitializationError
    }
    if ($null -eq $script:smbCredential) {
        $configurationErrors += "не завантажено NAS/SMB облікові дані з Credential Manager"
    }
    if ([string]::IsNullOrWhiteSpace([string]$smbSettings.RootPath) -or
        [string]$smbSettings.RootPath -notmatch '^\\\\[^\\]+\\[^\\]+') {
        $configurationErrors += "smbSettings.RootPath повинен бути UNC-шляхом виду \\server\share"
    }
    if ([int]$smbSettings.CopyBufferSizeMB -le 0) {
        $configurationErrors += "smbSettings.CopyBufferSizeMB повинен бути більшим за 0"
    }

    foreach ($archive in @($archiveDefinitions | Where-Object { $_.Enabled })) {
        if ($null -eq $smbSettings.Directories -or
            -not $smbSettings.Directories.ContainsKey($archive.Type) -or
            [string]::IsNullOrWhiteSpace([string]$smbSettings.Directories[$archive.Type])) {
            $configurationErrors += "не встановлено NAS/SMB каталог для архіву $($archive.Type)"
        }
    }

    if ($configurationErrors.Count -gt 0) {
        foreach ($configurationError in $configurationErrors) {
            Write-Log "Помилка конфігурації NAS/SMB: $configurationError" -Level "ERROR"
        }
        return $false
    }

    Write-Log "Доступ до NAS/SMB налаштовано коректно" -Level "SUCCESS"
    return $true
}

function New-BRAVOSMBDrive {
    $driveName = "BRAVOSMB$PID"
    Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue

    try {
        $drive = New-PSDrive `
            -Name $driveName `
            -PSProvider FileSystem `
            -Root ([string]$smbSettings.RootPath) `
            -Credential $script:smbCredential `
            -Scope Script `
            -ErrorAction Stop
        return $drive
    } catch {
        throw "не вдалося підключитися до '$($smbSettings.RootPath)': $($_.Exception.Message)"
    }
}

function Copy-FileToSMBWithProgress {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Component
    )

    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceFile = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
        $bufferSize = [math]::Max(1, [int]$smbSettings.CopyBufferSizeMB) * 1MB
        $buffer = New-Object byte[] $bufferSize
        $sourceStream = New-Object System.IO.FileStream(
            $sourceFile.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read,
            $bufferSize,
            [System.IO.FileOptions]::SequentialScan
        )
        $destinationStream = New-Object System.IO.FileStream(
            $DestinationPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            $bufferSize,
            [System.IO.FileOptions]::SequentialScan
        )

        $copiedBytes = [long]0
        while (($readBytes = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $destinationStream.Write($buffer, 0, $readBytes)
            $copiedBytes += $readBytes
            if ($progressSettings.Enabled -and $sourceFile.Length -gt 0) {
                $percent = [math]::Min(100, [math]::Floor(($copiedBytes * 100.0) / $sourceFile.Length))
                Show-RunningProgress `
                    -Id 4 `
                    -Activity "NAS/SMB — копіювання $Component" `
                    -Status "$($sourceFile.Name): $percent%" `
                    -PercentComplete $percent
            }
        }
        $destinationStream.Flush()
        $destinationStream.Dispose()
        $destinationStream = $null
        [System.IO.File]::SetLastWriteTimeUtc($DestinationPath, $sourceFile.LastWriteTimeUtc)

        $destinationFile = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
        if ([long]$destinationFile.Length -ne [long]$sourceFile.Length) {
            throw "розмір скопійованого файлу не збігається"
        }
        return $true
    } catch {
        if ($destinationStream) {
            $destinationStream.Dispose()
            $destinationStream = $null
        }
        if ($sourceStream) {
            $sourceStream.Dispose()
            $sourceStream = $null
        }
        Write-Log "Помилка копіювання на NAS/SMB: $($_.Exception.Message)" -Level "ERROR"
        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    } finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
        if ($progressSettings.Enabled) {
            Show-RunningProgress -Id 4 -Activity "NAS/SMB — копіювання" -Completed
        }
    }
}

function Copy-ArchivesToSMB {
    param([hashtable]$ArchiveResults)

    $drive = $null
    $copySuccess = 0
    $copyQueue = @()

    foreach ($archive in @($archiveDefinitions | Where-Object { $_.Enabled })) {
        if (-not $ArchiveResults.ContainsKey($archive.Type) -or
            -not $ArchiveResults[$archive.Type].ArchiveSuccess -or
            -not $ArchiveResults[$archive.Type].HashSuccess) {
            continue
        }

        $destinationDirectory = Join-Path `
            ([string]$smbSettings.RootPath) `
            ([string]$smbSettings.Directories[$archive.Type])
        foreach ($sourcePath in @(
            [string]$ArchiveResults[$archive.Type].ArchivePath,
            [string]$ArchiveResults[$archive.Type].HashPath
        )) {
            $copyQueue += [pscustomobject]@{
                SourcePath = $sourcePath
                DestinationDirectory = $destinationDirectory
                Component = [string]$archive.Type
            }
        }
    }

    $copyTotal = $copyQueue.Count
    if ($copyTotal -eq 0) {
        return [pscustomobject]@{
            Total = 0
            Success = 0
        }
    }

    try {
        $drive = New-BRAVOSMBDrive
        Write-Log "Підключення до NAS/SMB успішне: $($smbSettings.RootPath)" -Level "SUCCESS"

        $copyIndex = 0
        foreach ($copyItem in $copyQueue) {
            $copyIndex++
            $copyFileName = Split-Path $copyItem.SourcePath -Leaf
            Show-ItemProgress `
                -Id 14 `
                -Activity "BRAVO_ARCHIV — копіювання на NAS/SMB" `
                -Item $copyFileName `
                -Current $copyIndex `
                -Total $copyTotal

            if (-not (Test-Path -LiteralPath $copyItem.DestinationDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $copyItem.DestinationDirectory -Force -ErrorAction Stop | Out-Null
            }

            $destinationPath = Join-Path $copyItem.DestinationDirectory $copyFileName
            Write-Log "Копіювання на NAS/SMB: $copyFileName -> $($copyItem.DestinationDirectory)"
            if (Copy-FileToSMBWithProgress `
                -SourcePath $copyItem.SourcePath `
                -DestinationPath $destinationPath `
                -Component $copyItem.Component) {
                $copySuccess++
                Write-Log "Файл успішно скопійовано на NAS/SMB: $copyFileName" -Level "SUCCESS"
            }
        }
    } catch {
        Write-Log "Помилка NAS/SMB: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        Show-ItemProgress -Id 14 -Activity "BRAVO_ARCHIV — копіювання на NAS/SMB" -Completed
        if ($drive) {
            Remove-PSDrive -Name $drive.Name -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        Total = $copyTotal
        Success = $copySuccess
    }
}

function Test-NetworkConnection {
    try {
        Write-Log "Перевiрка мережевого з'єднання..." -Level "DEBUG"
        
        $connection = Test-BRAVOTcpConnection `
            -ComputerName $networkCheckHost `
            -Port $networkCheckPort `
            -TimeoutMilliseconds $networkPingTimeoutMilliseconds
        if ($connection) {
            Write-Log "Мережеве з'єднання доступне ($($BRAVOCompatibility.NetworkProvider))" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Мережеве з'єднання недоступне" -Level "ERROR"
            return $false
        }
    } catch {
        Write-Log "Помилка перевiрки мережевого з'єднання: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Remove-BRAVOWinSCPSensitiveTemporaryScript {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]"\/")
    $fullPath = [IO.Path]::GetFullPath($Path)
    $expectedPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar
    $fileName = [IO.Path]::GetFileName($fullPath)
    if (-not $fullPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $fileName -notmatch '^BRAVO_WinSCP_[0-9a-f]{32}\.txt$') {
        throw "відхилено небезпечний шлях тимчасового WinSCP-файла: $Path"
    }

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        # Спершу прибираємо вміст із доступного файлового запису, потім файл.
        [IO.File]::WriteAllText($fullPath, "", [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    }
}

function Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts {
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $staleBefore = (Get-Date).AddDays(-1)
    foreach ($file in @(
            Get-ChildItem `
                -LiteralPath $temporaryRoot `
                -Filter "BRAVO_WinSCP_*.txt" `
                -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $staleBefore }
        )) {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $file.FullName
        } catch {
            # Файл іншого облікового запису може мати закритий ACL.
        }
    }
}

function New-BRAVOWinSCPTemporaryScriptPath {
    # WinSCP script містить URL з обліковими даними. Створюємо файл атомарно
    # та залишаємо доступ лише поточному користувачу, SYSTEM і Administrators.
    Clear-BRAVOStaleWinSCPSensitiveTemporaryScripts
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $temporaryPath = Join-Path `
        -Path $temporaryRoot `
        -ChildPath ("BRAVO_WinSCP_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        $stream = $null

        $acl = Get-Acl -LiteralPath $temporaryPath -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existingRule in @($acl.Access)) {
            [void]$acl.RemoveAccessRuleAll($existingRule)
        }

        $uniqueSids = @{}
        foreach ($sid in @(
                [Security.Principal.WindowsIdentity]::GetCurrent().User,
                (New-Object Security.Principal.SecurityIdentifier("S-1-5-18")),
                (New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544"))
            )) {
            if ($null -eq $sid -or $uniqueSids.ContainsKey($sid.Value)) {
                continue
            }
            $uniqueSids[$sid.Value] = $true
            $rule = New-Object `
                -TypeName System.Security.AccessControl.FileSystemAccessRule `
                -ArgumentList @(
                    $sid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    [Security.AccessControl.AccessControlType]::Allow
                )
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $temporaryPath -AclObject $acl -ErrorAction Stop
        return $temporaryPath
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            try {
                Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $temporaryPath
            } catch {}
        }
        throw
    }
}

function Test-SFTPConnection {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey
    )
    
    Write-Log "Перевiрка пiдключення до SFTP сервера" -Level "DEBUG"
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-Log "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }
    
    $testCommand = @"
option batch abort
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
ls
exit
"@
    
    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    try {
        $testCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-Log (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "перевірка SFTP-з'єднання") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $completed = $process.WaitForExit(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds + 30) * 1000
        )
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {}
            throw "перевищено таймаут перевірки SFTP-з'єднання"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Пiдключення до SFTP сервера успiшне" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Помилка пiдключення до SFTP сервера (код: $($process.ExitCode))" -Level "ERROR"
            Write-Log "Вивiд: $(Get-SanitizedWinSCPDiagnostic -Text $output)" -Level "DEBUG"
            Write-Log "Помилка: $(Get-SanitizedWinSCPDiagnostic -Text $errorOutput)" -Level "DEBUG"
            return $false
        }

    } finally {
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {}
    }
}

function Get-SanitizedWinSCPDiagnostic {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaximumLines = 80
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $sanitized = $Text
    $sanitized = $sanitized -replace '(?i)(sftp://)[^@\s]+@', '$1***@'
    $sanitized = $sanitized -replace '(?i)(-password=)(?:"[^"]*"|\S+)', '$1***'
    $lines = @(
        $sanitized -split '\r?\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $safeMaximumLines = [math]::Max(1, $MaximumLines)
    if ($lines.Count -gt $safeMaximumLines) {
        $omittedCount = $lines.Count - $safeMaximumLines
        $lines = @(
            "... пропущено рядкiв WinSCP: $omittedCount ..."
            $lines | Select-Object -Last $safeMaximumLines
        )
    }

    return ($lines -join [Environment]::NewLine)
}

function Get-WinSCPDotNetComponents {
    if ($null -ne $script:WinSCPDotNetComponents) {
        return $script:WinSCPDotNetComponents
    }

    $assemblyCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPAssemblyPath)) {
        $assemblyCandidates += [string]$winSCPAssemblyPath
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$winSCPPath)) {
        $assemblyCandidates += Join-Path (Split-Path -Path $winSCPPath -Parent) "WinSCPnet.dll"
    }

    foreach ($assemblyPath in @($assemblyCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            continue
        }

        $executablePath = Join-Path (Split-Path -Path $assemblyPath -Parent) "WinSCP.exe"
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            continue
        }

        $script:WinSCPDotNetComponents = [pscustomobject]@{
            AssemblyPath = (Resolve-Path -LiteralPath $assemblyPath).Path
            ExecutablePath = (Resolve-Path -LiteralPath $executablePath).Path
        }
        return $script:WinSCPDotNetComponents
    }

    return $null
}

function Get-BAZASFTPComparison {
    param(
        [string]$LocalPath,
        [string]$RemotePath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey
    )

    $components = Get-WinSCPDotNetComponents
    if ($null -eq $components) {
        return [pscustomobject]@{
            Success = $false
            Error = "не знайдено сумісну пару WinSCPnet.dll та WinSCP.exe"
            PendingFiles = @()
        }
    }

    $session = $null
    try {
        if ($null -eq ("WinSCP.Session" -as [type])) {
            Add-Type -Path $components.AssemblyPath -ErrorAction Stop
        }

        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.ParseUrl($RepositorySFTPUrl)
        $sessionOptions.SshHostKeyFingerprint = ([string]$HostKey).Trim().Trim('"')
        $sessionOptions.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$sftpConnectionTimeoutSeconds)
        )

        $session = New-Object WinSCP.Session
        $session.ExecutablePath = $components.ExecutablePath
        $session.Timeout = [timespan]::FromSeconds(
            [math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)
        )
        $session.Open($sessionOptions)

        $mirror = [string]$sftpSynchronizationOptions -match '(?i)(^|\s)-mirror(\s|$)'
        $criteria = [WinSCP.SynchronizationCriteria]::Time
        $criteriaMatch = [regex]::Match(
            [string]$sftpSynchronizationOptions,
            '(?i)(^|\s)-criteria=(?<Value>[^\s]+)'
        )
        if ($criteriaMatch.Success) {
            $criteria = [WinSCP.SynchronizationCriteria]::None
            foreach ($criterion in $criteriaMatch.Groups["Value"].Value.Split(",")) {
                switch ($criterion.ToLowerInvariant()) {
                    "time" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Time
                    }
                    "size" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Size
                    }
                    "checksum" {
                        $criteria = $criteria -bor [WinSCP.SynchronizationCriteria]::Checksum
                    }
                }
            }
        }

        # removeFiles = false: додаткові файли у накопичувальній хмарі
        # не видаляються і не потрапляють до списку очікуваних передач.
        $comparison = @(
            $session.CompareDirectories(
                [WinSCP.SynchronizationMode]::Remote,
                $LocalPath,
                $RemotePath,
                $false,
                $mirror,
                $criteria,
                $null
            )
        )

        $pendingFiles = @()
        foreach ($difference in $comparison) {
            $rawAction = [string]$difference.Action
            if ($rawAction -notin @("UploadNew", "UploadUpdate")) {
                continue
            }

            $localItem = $difference.Local
            $localItemPath = if ($null -ne $localItem) {
                [string]$localItem.FullName
            } else {
                ""
            }
            if ([string]::IsNullOrWhiteSpace($localItemPath) -and $null -ne $localItem) {
                $localItemPath = [string]$localItem.FileName
            }
            if (-not [string]::IsNullOrWhiteSpace($localItemPath) -and
                -not [IO.Path]::IsPathRooted($localItemPath)) {
                $localItemPath = Join-Path -Path $LocalPath -ChildPath $localItemPath
            }
            $pendingFiles += [pscustomobject]@{
                Action = $rawAction
                Reason = if ($rawAction -eq "UploadNew") {
                    "відсутній у хмарі"
                } else {
                    "потребує оновлення у хмарі"
                }
                Path = if (-not [string]::IsNullOrWhiteSpace($localItemPath)) {
                    $localItemPath
                } else {
                    "невідомий локальний шлях"
                }
                IsDirectory = [bool]$difference.IsDirectory
                SizeBytes = if ($null -ne $localItem -and -not $difference.IsDirectory) {
                    [long]$localItem.Length
                } else {
                    $null
                }
            }
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            PendingFiles = @($pendingFiles)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
            PendingFiles = @()
        }
    } finally {
        if ($session) {
            $session.Dispose()
        }
    }
}

function Write-BAZASFTPComparisonAudit {
    param(
        [object]$Comparison,
        [ValidateSet("Before", "After")]
        [string]$Stage,
        [string]$ComponentName = "BAZA",
        [object[]]$IncompatibleIssues = @()
    )

    $stageText = if ($Stage -eq "Before") {
        "ДО СИНХРОНIЗАЦIЇ"
    } else {
        "ПIСЛЯ СИНХРОНIЗАЦIЇ"
    }

    if (-not $Comparison.Success) {
        Write-Log "Аудит $ComponentName $stageText не виконано: $($Comparison.Error)" -Level "WARNING"
        return
    }

    $pendingFiles = @($Comparison.PendingFiles)
    $pendingSplit = Split-BAZAPendingFilesByCompatibility `
        -PendingFiles $pendingFiles `
        -IncompatibleIssues $IncompatibleIssues
    $retryablePendingFiles = @($pendingSplit.Retryable)
    $incompatiblePendingFiles = @($pendingSplit.Incompatible)
    $missingCount = @($pendingFiles | Where-Object { $_.Action -eq "UploadNew" }).Count
    $updateCount = @($pendingFiles | Where-Object { $_.Action -eq "UploadUpdate" }).Count
    if ($pendingFiles.Count -eq 0) {
        Write-Log "Аудит $ComponentName ${stageText}: усi локальнi файли синхронiзованi" -Level "SUCCESS"
        return
    }

    $summaryLevel = if ($Stage -eq "Before") {
        "INFO"
    } elseif ($retryablePendingFiles.Count -eq 0 -and $incompatiblePendingFiles.Count -gt 0) {
        "WARNING"
    } else {
        "ERROR"
    }
    Write-Log "Аудит $ComponentName ${stageText}: очiкують передачi: $($pendingFiles.Count) (вiдсутнi у хмарi: $missingCount; потребують оновлення: $updateCount; несумісні імена: $($incompatiblePendingFiles.Count))" -Level $summaryLevel
    foreach ($pendingFile in $retryablePendingFiles) {
        $itemType = if ($pendingFile.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        $sizeText = if ($null -ne $pendingFile.SizeBytes) {
            "; байт: $($pendingFile.SizeBytes)"
        } else {
            ""
        }
        Write-Log "AUDIT $ComponentName $stageText [$itemType] [$($pendingFile.Reason)] $($pendingFile.Path)$sizeText" -Level $summaryLevel -FileOnly
    }
    foreach ($pendingFile in $incompatiblePendingFiles) {
        Write-Log "AUDIT $ComponentName $stageText [ПРОПУЩЕНО: НЕСУМІСНЕ ІМ'Я] $($pendingFile.Path)" -Level "WARNING" -FileOnly
    }
}

function Test-BAZAPathBlockedByIncompatibleName {
    param(
        [string]$CandidatePath,
        [object[]]$IncompatibleIssues = @()
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        return $false
    }
    try {
        $candidateFullPath = [IO.Path]::GetFullPath($CandidatePath).TrimEnd([char[]]"\\/")
    } catch {
        return $false
    }

    foreach ($issue in @($IncompatibleIssues)) {
        try {
            $issueFullPath = [IO.Path]::GetFullPath([string]$issue.Path).TrimEnd([char[]]"\\/")
        } catch {
            continue
        }
        if ($candidateFullPath.Equals($issueFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ([bool]$issue.IsDirectory) {
            $issuePrefix = $issueFullPath + [IO.Path]::DirectorySeparatorChar
            if ($candidateFullPath.StartsWith($issuePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Split-BAZAPendingFilesByCompatibility {
    param(
        [object[]]$PendingFiles = @(),
        [object[]]$IncompatibleIssues = @()
    )

    $retryable = @()
    $incompatible = @()
    foreach ($pendingFile in @($PendingFiles)) {
        if (Test-BAZAPathBlockedByIncompatibleName `
            -CandidatePath ([string]$pendingFile.Path) `
            -IncompatibleIssues $IncompatibleIssues) {
            $incompatible += $pendingFile
        } else {
            $retryable += $pendingFile
        }
    }
    return [pscustomobject]@{
        Retryable = @($retryable)
        Incompatible = @($incompatible)
    }
}

function Get-BAZASynchronizationOutcome {
    param(
        [int]$WinSCPExitCode,
        [object]$ComparisonBefore,
        [object]$ComparisonAfter,
        [object[]]$IncompatibleIssues = @()
    )

    $verificationSucceeded = $null -ne $ComparisonAfter -and $ComparisonAfter.Success
    $afterSplit = if ($verificationSucceeded) {
        Split-BAZAPendingFilesByCompatibility `
            -PendingFiles @($ComparisonAfter.PendingFiles) `
            -IncompatibleIssues $IncompatibleIssues
    } else {
        $null
    }
    $beforeSplit = if ($null -ne $ComparisonBefore -and $ComparisonBefore.Success) {
        Split-BAZAPendingFilesByCompatibility `
            -PendingFiles @($ComparisonBefore.PendingFiles) `
            -IncompatibleIssues $IncompatibleIssues
    } else {
        $null
    }
    $remainingCount = if ($verificationSucceeded) {
        @($ComparisonAfter.PendingFiles).Count
    } else {
        $null
    }
    $retryableRemainingCount = if ($verificationSucceeded) {
        @($afterSplit.Retryable).Count
    } else {
        $null
    }
    $incompatibleRemainingCount = if ($verificationSucceeded) {
        @($afterSplit.Incompatible).Count
    } else {
        $null
    }
    $beforeCount = if ($null -ne $ComparisonBefore -and $ComparisonBefore.Success) {
        @($ComparisonBefore.PendingFiles).Count
    } else {
        $null
    }
    $completedCount = if ($null -ne $beforeSplit -and $null -ne $afterSplit) {
        [math]::Max(0, @($beforeSplit.Retryable).Count - @($afterSplit.Retryable).Count)
    } else {
        $null
    }

    return [pscustomobject]@{
        VerificationSucceeded = $verificationSucceeded
        ExitCode = $WinSCPExitCode
        BeforeCount = $beforeCount
        CompletedCount = $completedCount
        RemainingCount = $remainingCount
        RetryableRemainingCount = $retryableRemainingCount
        IncompatibleRemainingCount = $incompatibleRemainingCount
        IsComplete = (
            $WinSCPExitCode -eq 0 -and
            $verificationSucceeded -and
            $retryableRemainingCount -eq 0
        )
        IsDegraded = (
            $WinSCPExitCode -eq 0 -and
            $verificationSucceeded -and
            $retryableRemainingCount -eq 0 -and
            $incompatibleRemainingCount -gt 0
        )
        IsPartial = (
            $verificationSucceeded -and
            $retryableRemainingCount -gt 0
        )
    }
}

function Get-BAZARemoteNameCompatibilityIssues {
    param(
        [string]$LocalPath,
        [int]$MaximumFileUtf8Bytes = 255,
        [int]$MaximumDirectoryUtf8Bytes = 255
    )

    $issues = @()
    try {
        $localItems = @(
            Get-ChildItem `
                -LiteralPath $LocalPath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        )
        foreach ($localItem in $localItems) {
            $utf8ByteCount = [System.Text.Encoding]::UTF8.GetByteCount($localItem.Name)
            $maximumUtf8Bytes = if ($localItem.PSIsContainer) {
                $MaximumDirectoryUtf8Bytes
            } else {
                $MaximumFileUtf8Bytes
            }
            if ($utf8ByteCount -le $maximumUtf8Bytes) {
                continue
            }

            $issues += [pscustomobject]@{
                Path = $localItem.FullName
                Name = $localItem.Name
                IsDirectory = [bool]$localItem.PSIsContainer
                CharacterCount = $localItem.Name.Length
                Utf8ByteCount = $utf8ByteCount
                MaximumUtf8Bytes = $maximumUtf8Bytes
                Reason = "ім'я довше за допустимі $maximumUtf8Bytes байт у UTF-8"
            }
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            Issues = @($issues)
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Error = $_.Exception.Message
            Issues = @()
        }
    }
}

function Write-BAZARemoteNameCompatibilityAudit {
    param(
        [object]$CompatibilityResult,
        [string]$ComponentName = "BAZA"
    )

    if (-not $CompatibilityResult.Success) {
        Write-Log "Не вдалося перевiрити сумiснiсть iмен $ComponentName з SFTP: $($CompatibilityResult.Error)" -Level "WARNING"
        return
    }

    $issues = @($CompatibilityResult.Issues)
    if ($issues.Count -eq 0) {
        Write-Log "Перевiрка iмен ${ComponentName}: несумiсних iз SFTP iмен не знайдено" -Level "SUCCESS"
        return
    }

    Write-Log "Перевiрка iмен ${ComponentName}: знайдено несумiсних iмен: $($issues.Count). Цi об'єкти буде пропущено; потрiбне скорочення локальних iмен" -Level "ERROR"
    foreach ($issue in $issues) {
        $itemType = if ($issue.IsDirectory) { "КАТАЛОГ" } else { "ФАЙЛ" }
        Write-Log "AUDIT $ComponentName НЕСУМIСНЕ IМ'Я [$itemType] [довжина: $($issue.CharacterCount) символів; $($issue.Utf8ByteCount)/$($issue.MaximumUtf8Bytes) UTF-8 байт] $($issue.Path)" -Level "ERROR" -FileOnly
    }

    # Notification failures must never stop the actual SFTP synchronization.
    try {
        Send-BAZAIncompatibleNameAlert -Issues $issues -ComponentName $ComponentName
    } catch {
        Write-Log "Не вдалося підготувати сповіщення про несумісні імена ${ComponentName}: $($_.Exception.Message)" -Level "ERROR"
    }
}

function global:Split-DiscordNotificationText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateRange(100, 2000)]
        [int]$MaximumLength = 1900
    )

    $chunks = New-Object 'System.Collections.Generic.List[string]'

    if ($null -eq $Message) {
        $Message = ""
    }

    if ($Message.Length -eq 0) {
        $chunks.Add("")
        return $chunks.ToArray()
    }

    $normalizedMessage = $Message -replace "`r`n", "`n"
    $normalizedMessage = $normalizedMessage -replace "`r", "`n"

    $currentChunk = New-Object System.Text.StringBuilder

    foreach ($line in ($normalizedMessage -split "`n", 0, "SimpleMatch")) {
        $remainingLine = [string]$line

        do {
            $newlineLength = if ($currentChunk.Length -gt 0) {
                1
            }
            else {
                0
            }

            $availableLength = (
                $MaximumLength -
                $currentChunk.Length -
                $newlineLength
            )

            if ($availableLength -le 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
                continue
            }

            if ($currentChunk.Length -gt 0) {
                [void]$currentChunk.Append("`n")
            }

            $partLength = [Math]::Min(
                $availableLength,
                $remainingLine.Length
            )

            if ($partLength -gt 0) {
                [void]$currentChunk.Append(
                    $remainingLine.Substring(0, $partLength)
                )

                $remainingLine = $remainingLine.Substring($partLength)
            }
            else {
                $remainingLine = ""
            }

            if ($remainingLine.Length -gt 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
            }
        }
        while ($remainingLine.Length -gt 0)
    }

    if ($currentChunk.Length -gt 0 -or $chunks.Count -eq 0) {
        $chunks.Add($currentChunk.ToString())
    }

    return $chunks.ToArray()
}

function Send-BAZAIncompatibleNameAlert {
    param(
        [object[]]$Issues,
        [string]$ComponentName = "BAZA"
    )

    if ($NoSlack -or $script:notificationMode -eq "none") {
        Write-Log "Сповіщення про несумісні імена $ComponentName вимкнено параметрами запуску або конфігурацією" -Level "INFO"
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:notificationWebhookUrl)) {
        Write-Log (
            "Сповіщення про несумісні імена $ComponentName не відправлено: " +
            "webhook для $($script:notificationProviderDisplayName) не налаштовано"
        ) -Level "INFO"
        return
    }

    $examples = @(
        $Issues |
            Select-Object -First 5 |
            ForEach-Object {
                $itemType = if ($_.IsDirectory) { "каталог" } else { "файл" }
                $displayName = [string]$_.Name
                if ($displayName.Length -gt 180) {
                    $displayName = $displayName.Substring(0, 177) + "..."
                }

                # The health formatter lives in a different function scope.
                # Keep this standalone mode self-contained and only apply
                # Markdown escaping when the selected provider is Discord.
                if ($script:notificationProvider -eq "discord") {
                    $displayName = $displayName.Replace("\", "\\")
                    $displayName = $displayName.Replace("*", "\*")
                    $displayName = $displayName.Replace("_", "\_")
                    $displayName = $displayName.Replace("~", "\~")
                    $displayName = $displayName.Replace("|", "\|")
                    $displayName = $displayName.Replace(">", "\>")
                }
                (
                    "• $itemType [довжина: $($_.CharacterCount) символів; " +
                    "$($_.Utf8ByteCount)/$($_.MaximumUtf8Bytes) UTF-8 байт]:`n  " +
                    $displayName
                )
            }
    )
    $examplesText = $examples -join "`n"
    $machineName = [Environment]::MachineName
    $localIpAddresses = @()
    try {
        $localIpAddresses = @(
            [System.Net.Dns]::GetHostAddresses($machineName) |
                Where-Object {
                    $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                    -not [System.Net.IPAddress]::IsLoopback($_) -and
                    -not $_.ToString().StartsWith("169.254.")
                } |
                ForEach-Object { $_.ToString() } |
                Sort-Object -Unique
        )
    } catch {}
    $localIpText = if ($localIpAddresses.Count -gt 0) {
        $localIpAddresses -join " | "
    } else {
        "недоступні"
    }
    $notificationTime = (Get-Date).ToString("dd.MM.yyyy HH:mm:ss")
    $archiveVersionText = [string]$global:ScriptVersion
    $archiveScriptDateText = [string]$global:ScriptDate
    $logFilePath = if (-not [string]::IsNullOrWhiteSpace([string]$global:logFile)) {
        [string]$global:logFile
    } else {
        "журнал BRAVO_ARCHIV"
    }
    $message = @"
🚨 SFTP-СИНХРОНІЗАЦІЯ $ComponentName ПОТРЕБУЄ УВАГИ
🏚️ Установа: $($backupMonitoring.InstitutionName) [$($backupMonitoring.InstitutionCode)]
🖥️ Машина: $machineName
🌐 IP-адреси: $localIpText
🕒 Час: $notificationTime
🏷️ Версія BRAVO_ARCHIV: $archiveVersionText від $archiveScriptDateText

Знайдено несумісних імен: $($Issues.Count). Ці об'єкти не буде передано у хмару, доки локальні імена не буде скорочено.
Довжину показано в символах; технічний ліміт WinSCP — $($Issues[0].MaximumUtf8Bytes) UTF-8 байт.
Приклади:
$examplesText
📝 Повний перелік: $logFilePath
"@

    try {
        $outboundMessages = if ($script:notificationProvider -eq "discord") {
            @(Split-DiscordNotificationText -Message $message)
        } else {
            @($message)
        }
        foreach ($outboundMessage in $outboundMessages) {
            Send-BRAVOWebhookNotification `
                -Provider $script:notificationProvider `
                -WebhookUrl $script:notificationWebhookUrl `
                -Message $outboundMessage `
                -TimeoutSeconds $script:notificationRequestTimeoutSeconds
        }
        $chunkText = if ($outboundMessages.Count -gt 1) {
            " частинами: $($outboundMessages.Count)"
        } else {
            ""
        }
        Write-Log "Сповіщення про $($Issues.Count) несумісних імен $ComponentName відправлено у $($script:notificationProviderDisplayName)$chunkText" -Level "SUCCESS"
    } catch {
        Write-Log "Не вдалося відправити сповіщення про несумісні імена $ComponentName у $($script:notificationProviderDisplayName): $($_.Exception.Message)" -Level "ERROR"
    }
}

function Send-FileViaWinSCP {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey,
        [string]$LocalFilePath,
        [string]$RemoteDirectory
    )
    
    Write-Log "Завантаження через WinSCP: $(Split-Path $LocalFilePath -Leaf) -> $RemoteDirectory"
    
    if (-not (Test-Path $LocalFilePath)) {
        Write-Log "Файл не знайдено: $LocalFilePath" -Level "ERROR"
        return $false
    }
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-Log "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }
    
    # Створюємо тимчасовий скрипт для WinSCP
    $winscpCommand = @"
option batch abort
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
cd /$RemoteDirectory
put "$LocalFilePath"
exit
"@
    
    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    $showWinSCPProgress = $progressSettings.Enabled -and $progressSettings.ShowWinSCPOutput
    $transferFileName = Split-Path $LocalFilePath -Leaf
    $transferActivity = "WinSCP — передача $transferFileName"
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force
        Write-Log "Створено тимчасовий скрипт WinSCP: $tempScript" -Level "DEBUG"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        # Вивід WinSCP завжди перехоплюється, щоб він не дублював журнал у консолі.
        # Замість нього показується єдиний індикатор Write-Progress.
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        Write-Log "Запуск WinSCP..." -Level "DEBUG"
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-Log (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "передача $transferFileName") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $transferStarted = Get-Date
        $operationTimeoutSeconds = [math]::Max(
            1,
            [int]$backupMonitoring.SFTP.OperationTimeoutSeconds
        )
        $transferTimedOut = $false
        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $transferStarted).TotalSeconds)
            if ($showWinSCPProgress) {
                Show-RunningProgress `
                    -Id 11 `
                    -Activity $transferActivity `
                    -Status "Виконується, минуло $elapsedSeconds сек."
            }
            if ($elapsedSeconds -ge $operationTimeoutSeconds) {
                $transferTimedOut = $true
                try {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                } catch {
                    Write-Log "Не вдалося завершити WinSCP після таймауту: $($_.Exception.Message)" -Level "WARNING"
                }
                break
            }
        }
        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "WinSCP не завершився після таймауту передачі"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        $safeOutput = Get-SanitizedWinSCPDiagnostic -Text $output
        $safeErrorOutput = Get-SanitizedWinSCPDiagnostic -Text $errorOutput
        
        if (-not [string]::IsNullOrWhiteSpace($safeOutput)) {
            Write-Log "WinSCP вивiд: $safeOutput" -Level "DEBUG"
        }
        if ($transferTimedOut) {
            Write-Log "Передача WinSCP перевищила таймаут $operationTimeoutSeconds сек.: $transferFileName" -Level "ERROR"
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Файл успiшно завантажено: $(Split-Path $LocalFilePath -Leaf)" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Помилка завантаження (код: $($process.ExitCode)): $(Split-Path $LocalFilePath -Leaf)" -Level "ERROR"
            if (-not [string]::IsNullOrEmpty($safeOutput)) {
                Write-Log "Вивiд WinSCP: $safeOutput" -Level "DEBUG"
            }
            if (-not [string]::IsNullOrEmpty($safeErrorOutput)) {
                Write-Log "Помилка WinSCP: $safeErrorOutput" -Level "DEBUG"
            }
            return $false
        }
    } catch {
        Write-Log "Помилка пiд час завантаження через WinSCP: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($showWinSCPProgress) {
            Show-RunningProgress -Id 11 -Activity $transferActivity -Completed
        }
        # Очищаємо тимчасовий файл із конфіденційними даними.
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
            Write-Log "Тимчасовий скрипт видалено: $tempScript" -Level "DEBUG"
        } catch {
            Write-Log "Не вдалося видалити тимчасовий скрипт: $($_.Exception.Message)" -Level "WARNING"
        }
    }
}

function Sync-FolderToSFTP {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey,
        [string]$LocalDirectory,
        [string]$RemoteDirectory,
        [string]$ComponentName = "BAZA"
    )

    $normalizedRemoteDirectory = $RemoteDirectory.Replace("\", "/").Trim("/")
    $remotePath = if ([string]::IsNullOrWhiteSpace($normalizedRemoteDirectory)) {
        "/"
    } else {
        "/$normalizedRemoteDirectory"
    }

    Write-Log "Синхронiзацiя каталогу через WinSCP: $LocalDirectory -> $remotePath"

    if (-not (Test-Path -Path $LocalDirectory -PathType Container)) {
        Write-Log "Локальний каталог не знайдено: $LocalDirectory" -Level "ERROR"
        return $false
    }

    if ($synchronizationSafety.RequireNonEmptyBAZASource) {
        $firstSourceFile = Get-BRAVOFiles `
            -LiteralPath $LocalDirectory `
            -Recurse `
            -Force `
            |
            Select-Object -First 1
        if ($null -eq $firstSourceFile) {
            Write-Log "SFTP-синхронiзацiю $ComponentName заблоковано: локальний каталог порожнiй або недоступний" -Level "ERROR"
            return $false
        }
    }

    if (-not (Test-Path -Path $WinSCPPath -PathType Leaf)) {
        Write-Log "WinSCP не знайдено: $WinSCPPath" -Level "ERROR"
        return $false
    }

    $fileNameUtf8Limit = if (
        [string]$sftpSynchronizationOptions -match '(?i)(^|\s)-resumesupport=on(\s|$)'
    ) {
        # WinSCP додає ".filepart" (9 UTF-8 байт) до тимчасового імені.
        246
    } else {
        255
    }
    $nameCompatibility = Get-BAZARemoteNameCompatibilityIssues `
        -LocalPath $LocalDirectory `
        -MaximumFileUtf8Bytes $fileNameUtf8Limit `
        -MaximumDirectoryUtf8Bytes 255
    Write-BAZARemoteNameCompatibilityAudit `
        -CompatibilityResult $nameCompatibility `
        -ComponentName $ComponentName

    $comparisonBefore = Get-BAZASFTPComparison `
        -LocalPath $LocalDirectory `
        -RemotePath $remotePath `
        -RepositorySFTPUrl $RepositorySFTPUrl `
        -HostKey $HostKey
    Write-BAZASFTPComparisonAudit `
        -Comparison $comparisonBefore `
        -Stage "Before" `
        -ComponentName $ComponentName `
        -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })

    # Кореневий каталог синхронізації має бути попередньо створений на SFTP.
    # Не виконуємо mkdir: WinSCP повертає код 1, якщо каталог уже існує,
    # навіть коли option batch continue дозволяє перейти до синхронізації.
    # stat однозначно перевіряє каталог і не створює хибної помилки.
    $winscpCommand = @"
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=$sftpConnectionTimeoutSeconds
option batch abort
stat "$remotePath"
option batch continue
synchronize remote $sftpSynchronizationOptions "$LocalDirectory" "$remotePath"
exit
"@

    $tempScript = New-BRAVOWinSCPTemporaryScriptPath
    $showWinSCPProgress = $progressSettings.Enabled -and $progressSettings.ShowWinSCPOutput
    $syncActivity = "WinSCP — синхронiзацiя $ComponentName"
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding $winSCPScriptEncoding -Force

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=$winSCPIniPath /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        try {
            # WinSCP.com використовує UTF-8 для перенаправленого виводу.
            # Явне декодування запобігає появі тексту виду "╨..." у журналі.
            $winSCPUtf8Encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
            $processInfo.StandardOutputEncoding = $winSCPUtf8Encoding
            $processInfo.StandardErrorEncoding = $winSCPUtf8Encoding
        } catch {
            Write-Log "Не вдалося встановити UTF-8 для виводу WinSCP: $($_.Exception.Message)" -Level "DEBUG"
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $winSCPAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $WinSCPPath
        if (-not $winSCPAvailability.Available) {
            Write-Log (Get-BRAVOWinSCPBusyMessage -Availability $winSCPAvailability -Operation "синхронізація $ComponentName") -Level "ERROR"
            return $false
        }
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $syncStarted = Get-Date
        $configuredSynchronizationTimeout = [int](
            $backupMonitoring.SFTP.SynchronizationTimeoutSeconds
        )
        $operationTimeoutSeconds = if (
            $configuredSynchronizationTimeout -gt 0
        ) {
            $configuredSynchronizationTimeout
        } else {
            # Сумісність зі старими BRAVO.config.
            [math]::Max(
                1,
                [int]$backupMonitoring.SFTP.OperationTimeoutSeconds
            )
        }
        Write-Log (
            "Таймаут синхронiзацiї ${ComponentName}: " +
            "$operationTimeoutSeconds сек."
        ) -Level "INFO"
        $syncTimedOut = $false
        while (-not $process.WaitForExit(500)) {
            $elapsedSeconds = [math]::Floor(((Get-Date) - $syncStarted).TotalSeconds)
            if ($showWinSCPProgress) {
                Show-RunningProgress `
                    -Id 12 `
                    -Activity $syncActivity `
                    -Status "Виконується, минуло $elapsedSeconds сек."
            }
            if ($elapsedSeconds -ge $operationTimeoutSeconds) {
                $syncTimedOut = $true
                try {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                } catch {
                    Write-Log "Не вдалося завершити WinSCP після таймауту синхронізації ${ComponentName}: $($_.Exception.Message)" -Level "WARNING"
                }
                break
            }
        }
        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
            throw "WinSCP не завершився після таймауту синхронізації $ComponentName"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        $sanitizedOutput = Get-SanitizedWinSCPDiagnostic -Text $output
        $sanitizedErrorOutput = Get-SanitizedWinSCPDiagnostic -Text $errorOutput

        if (-not [string]::IsNullOrWhiteSpace($sanitizedOutput)) {
            Write-Log "WinSCP вивiд синхронiзацiї ${ComponentName}: $sanitizedOutput" -Level "DEBUG"
        }
        if ($syncTimedOut) {
            Write-Log "Синхронізація $ComponentName перевищила таймаут $operationTimeoutSeconds сек." -Level "ERROR"
            Write-Log "Повторний запуск продовжить передачу файлів із використанням WinSCP resumesupport" -Level "INFO"
            return $false
        }

        $winSCPExitCode = $process.ExitCode
        if ($winSCPExitCode -ne 0) {
            Write-Log "Помилка SFTP-синхронiзацiї $ComponentName (код: $winSCPExitCode)" -Level "ERROR"
            if (-not [string]::IsNullOrWhiteSpace($sanitizedOutput)) {
                Write-Log "Дiагностика WinSCP (stdout): $sanitizedOutput" -Level "ERROR"
            }
            if (-not [string]::IsNullOrWhiteSpace($sanitizedErrorOutput)) {
                Write-Log "Дiагностика WinSCP (stderr): $sanitizedErrorOutput" -Level "ERROR"
            }
            if ([string]::IsNullOrWhiteSpace($sanitizedOutput) -and
                [string]::IsNullOrWhiteSpace($sanitizedErrorOutput)) {
                Write-Log "WinSCP не повернув тексту помилки; перевiрте права доступу до $remotePath" -Level "ERROR"
            }
        }

        # option batch continue може повернути код 0, навіть якщо окремі файли
        # були пропущені. Тому остаточний результат визначає лише повторне
        # read-only порівняння локального каталогу з хмарою.
        $comparisonAfter = Get-BAZASFTPComparison `
            -LocalPath $LocalDirectory `
            -RemotePath $remotePath `
            -RepositorySFTPUrl $RepositorySFTPUrl `
            -HostKey $HostKey
        Write-BAZASFTPComparisonAudit `
            -Comparison $comparisonAfter `
            -Stage "After" `
            -ComponentName $ComponentName `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })

        $syncOutcome = Get-BAZASynchronizationOutcome `
            -WinSCPExitCode $winSCPExitCode `
            -ComparisonBefore $comparisonBefore `
            -ComparisonAfter $comparisonAfter `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })

        if (-not $syncOutcome.VerificationSucceeded) {
            Write-Log "Не вдалося пiдтвердити результат синхронiзацiї $ComponentName повторним порiвнянням; результат вважається помилкою" -Level "ERROR"
            return $false
        }

        if ($null -ne $syncOutcome.CompletedCount) {
            $resultLevel = if ($syncOutcome.IsComplete -and -not $syncOutcome.IsDegraded) {
                "SUCCESS"
            } else {
                "WARNING"
            }
            Write-Log "Результат ${ComponentName}: передано або оновлено сумісних об'єктiв: $($syncOutcome.CompletedCount); залишилося несинхронiзованих: $($syncOutcome.RemainingCount)" -Level $resultLevel
        }

        if ($syncOutcome.IsComplete) {
            if ($syncOutcome.IsDegraded) {
                Write-Log "Каталог $ComponentName синхронізовано для всіх сумісних імен; $($syncOutcome.IncompatibleRemainingCount) об'єктів пропущено через незмінювані несумісні імена. Повторний запуск не потрібен." -Level "WARNING"
            } else {
                Write-Log "Каталог $ComponentName повнiстю синхронiзовано з $remotePath" -Level "SUCCESS"
            }
            return $true
        }

        if ($winSCPExitCode -eq 0 -and $syncOutcome.IsPartial) {
            Write-Log "WinSCP повернув код 0, але синхронiзацiя $ComponentName часткова: залишилося об'єктiв: $($syncOutcome.RemainingCount)" -Level "ERROR"
        }
        return $false
    } catch {
        Write-Log "Помилка пiд час SFTP-синхронiзацiї ${ComponentName}: $($_.Exception.Message)" -Level "ERROR"
        $comparisonAfterException = Get-BAZASFTPComparison `
            -LocalPath $LocalDirectory `
            -RemotePath $remotePath `
            -RepositorySFTPUrl $RepositorySFTPUrl `
            -HostKey $HostKey
        Write-BAZASFTPComparisonAudit `
            -Comparison $comparisonAfterException `
            -Stage "After" `
            -ComponentName $ComponentName `
            -IncompatibleIssues $(if ($nameCompatibility.Success) { @($nameCompatibility.Issues) } else { @() })
        return $false
    } finally {
        if ($showWinSCPProgress) {
            Show-RunningProgress -Id 12 -Activity $syncActivity -Completed
        }
        try {
            Remove-BRAVOWinSCPSensitiveTemporaryScript -Path $tempScript
        } catch {}
    }
}

function Invoke-ManualBAZASFTPSynchronization {
    Write-Log "==="
    Write-Log "=== РУЧНА СИНХРОНIЗАЦIЯ BAZA_APP / BAZA_WWW НА SFTP ==="
    Write-Log "Режим -SyncBAZA: синхронізуються всі увімкнені BAZA_APP/BAZA_WWW; архiвацiю, очищення архiвiв, NAS/SMB та health-check пропущено" -Level "INFO"
    Show-ScriptProgress -Status "Ручна синхронiзацiя BAZA_APP / BAZA_WWW на SFTP" -PercentComplete 20

    $syncTargets = @()
    $sourceConfigurationFailed = $false
    if ([bool]$componentSettings.Synchronization.BAZASFTP) {
        if (Test-PathWithLog -Path $bazaPaths.Source -Description "Каталог BAZA_APP" -CreateIfMissing $false) {
            $syncTargets += [pscustomobject]@{
                Name = "BAZA_APP"
                Source = [string]$bazaPaths.Source
                Destination = [string]$sftpDirectories.BAZA
            }
        } else {
            $sourceConfigurationFailed = $true
            Write-Log "Ручну синхронізацію BAZA_APP пропущено: локальний каталог недоступний" -Level "ERROR"
        }
    }
    if ([bool]$componentSettings.Synchronization.BAZAWWWSFTP) {
        if ($bazaWWWDetection.Success -and
            -not [string]::IsNullOrWhiteSpace([string]$bazaWWWPaths.Source) -and
            (Test-PathWithLog -Path $bazaWWWPaths.Source -Description "Каталог BAZA_WWW" -CreateIfMissing $false)) {
            $syncTargets += [pscustomobject]@{
                Name = "BAZA_WWW"
                Source = [string]$bazaWWWPaths.Source
                Destination = [string]$sftpDirectories.BAZAWWW
            }
        } else {
            $sourceConfigurationFailed = $true
            $detectionReason = if ($bazaWWWDetection.Success) { "локальний каталог недоступний" } else { [string]$bazaWWWDetection.Reason }
            Write-Log "Ручну синхронізацію BAZA_WWW пропущено: $detectionReason" -Level "ERROR"
        }
    }
    if ($syncTargets.Count -eq 0) {
        Write-Log "Ручну синхронізацію скасовано: BAZASFTP і BAZAWWWSFTP вимкнені або їхні джерела недоступні" -Level "ERROR"
        return $false
    }

    if (-not (Test-SFTPConfig -SynchronizationOnly)) {
        Write-Log "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено через помилки конфiгурацiї SFTP" -Level "ERROR"
        return $false
    }

    Show-ScriptProgress -Status "Перевiрка з'єднання з SFTP" -PercentComplete 35
    if (-not (Test-NetworkConnection)) {
        Write-Log "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено: мережеве з'єднання недоступне" -Level "ERROR"
        return $false
    }

    if (-not (Test-SFTPConnection `
        -WinSCPPath $winSCPPath `
        -RepositorySFTPUrl $sftpUrl `
        -HostKey $sftpHostKey)) {
        Write-Log "Ручну синхронiзацiю BAZA_APP / BAZA_WWW зупинено: не вдалося пiдключитися до SFTP" -Level "ERROR"
        return $false
    }

    $syncFailed = $sourceConfigurationFailed
    $syncIndex = 0
    foreach ($syncTarget in $syncTargets) {
        $syncIndex++
        $progressPercent = 55 + [math]::Floor(($syncIndex - 1) * 35 / [math]::Max(1, $syncTargets.Count))
        Show-ScriptProgress -Status "Синхронiзацiя $($syncTarget.Name) на SFTP" -PercentComplete $progressPercent
        $syncSuccess = Sync-FolderToSFTP `
            -WinSCPPath $winSCPPath `
            -RepositorySFTPUrl $sftpUrl `
            -HostKey $sftpHostKey `
            -LocalDirectory $syncTarget.Source `
            -RemoteDirectory $syncTarget.Destination `
            -ComponentName $syncTarget.Name
        if ($syncSuccess) {
            Write-Log "Ручну синхронiзацiю $($syncTarget.Name) на SFTP завершено успiшно" -Level "SUCCESS"
        } else {
            $syncFailed = $true
            Write-Log "Ручна синхронiзацiя $($syncTarget.Name) на SFTP завершилася з помилкою" -Level "ERROR"
        }
    }

    return (-not $syncFailed)
}

function Enter-BRAVOArchiveProcessLock {
    # Спільний lock для BRAVO_ARCHIV і BRAVO_MAINTENANCE. Він не дозволяє
    # maintenance зупиняти служби або змінювати джерела під час backup.
    $lockPath = Join-Path $logPath "BRAVO_OPERATION.lock"
    try {
        if (-not (Test-Path -LiteralPath $logPath -PathType Container)) {
            New-Item `
                -ItemType Directory `
                -Path $logPath `
                -Force `
                -ErrorAction Stop |
                Out-Null
        }
        $waitMinutes = if ($null -ne $schedulerSettings -and
            $schedulerSettings.Contains("OperationLockWaitMinutes")) {
            [math]::Max(0, [int]$schedulerSettings.OperationLockWaitMinutes)
        } else {
            0
        }
        $deadline = (Get-Date).AddMinutes($waitMinutes)
        $lockStream = $null
        $lastLockError = $null
        do {
            try {
                $lockStream = [System.IO.File]::Open(
                    $lockPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::None
                )
            } catch {
                $lastLockError = $_.Exception.Message
                if ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 30
                }
            }
        } while ($null -eq $lockStream -and (Get-Date) -lt $deadline)
        if ($null -eq $lockStream) {
            throw "lock не звільнився за $waitMinutes хв.: $lastLockError"
        }
        $lockText = (
            "PID={0}; Started={1}; Config={2}" -f
            $PID,
            (Get-Date).ToString("o"),
            $configPath
        )
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes($lockText)
        $lockStream.SetLength(0)
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        $lockStream.Flush()

        return [pscustomobject]@{
            Success = $true
            Stream = $lockStream
            Path = $lockPath
            Error = $null
        }
    } catch {
        if ($lockStream) {
            $lockStream.Dispose()
        }
        return [pscustomobject]@{
            Success = $false
            Stream = $null
            Path = $lockPath
            Error = $_.Exception.Message
        }
    }
}

# =============================================
# ОСНОВНА ЛОГІКА
# =============================================

function Write-BRAVOBackupExecutionState {
    $path = Join-Path $logPath 'BRAVO_TASK_EXECUTION_STATE.json'
    $state = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $previous = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $state.Maintenance = [string]$previous.Maintenance
            $state.Backup = [string]$previous.Backup
        } catch {}
    }
    $state.Backup = ([datetime]::Now).ToString('o')
    [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Main {
    # Ініціалізація
    $scriptStartTime = Get-Date
    $now = $scriptStartTime.ToString($archiveTimestampFormat)
    $logTimestamp = $scriptStartTime.ToString($logFileDateFormat)
    $global:logFile = Join-Path $logPath ($logFileNameTemplate -f $logTimestamp)
    $processLockResult = Enter-BRAVOArchiveProcessLock
    if (-not $processLockResult.Success) {
        Write-Log (
            "Запуск скасовано: інший екземпляр BRAVO_ARCHIV уже працює " +
            "або файл блокування недоступний: $($processLockResult.Error)"
        ) -Level "ERROR"
        $script:processExitCode = 2
        return
    }
    $script:archiveProcessLock = $processLockResult.Stream
    $script:archiveProcessLockPath = $processLockResult.Path

    $enabledArchives = @($archiveDefinitions | Where-Object { $_.Enabled })
    $readyArchives = @()
    $results = @{}
    $bazaLocalSyncEnabled = [bool]$componentSettings.Synchronization.BAZALocal
    $bazaSFTPSyncEnabled = [bool]$componentSettings.Synchronization.BAZASFTP
    $bazaWWWSFTPSyncEnabled = [bool]$componentSettings.Synchronization.BAZAWWWSFTP
    $sftpArchiveUploadEnabled = [bool]$componentSettings.SFTP.ArchiveUpload
    $smbArchiveCopyEnabled = [bool]$componentSettings.SMB.ArchiveCopy
    $sftpTransferEnabled = (
        $sftpArchiveUploadEnabled -or
        $bazaSFTPSyncEnabled -or
        $bazaWWWSFTPSyncEnabled
    )
    $operationFailed = $false
    Show-ScriptProgress -Status "Iнiцiалiзацiя" -PercentComplete 2
    
    Write-Log "==="
    Write-Log "=== ПОЧАТОК РОБОТИ СКРИПТА BRAVO_ARCHIV v.$ScriptVersion ==="
    Write-Log "Файл конфiгурацiї: $configPath" -Level "INFO"
    
    # Перевірка сумісності
    Write-Log "==="
    Write-Log "=== ПЕРЕВIРКА СУМIСНОСТI СИСТЕМИ ==="
    Show-ScriptProgress -Status "Перевiрка сумiсностi" -PercentComplete 5
    $compatibilityIssues = Test-Compatibility

    if ($SyncBAZA) {
        $manualSyncStarted = Get-Date
        $manualSyncSuccess = Invoke-ManualBAZASFTPSynchronization
        $manualSyncFinished = Get-Date
        $manualSyncDuration = $manualSyncFinished - $manualSyncStarted

        Write-Log "==="
        Write-Log "=== ЗАВЕРШЕННЯ РУЧНОЇ СИНХРОНIЗАЦIЇ BAZA_APP / BAZA_WWW ==="
        Write-Log "Результат: $(if ($manualSyncSuccess) {'УСПIШНО'} else {'ПОМИЛКА'})" -NoTimestamp
        Write-Log "Тривалiсть: $($manualSyncDuration.ToString($durationFormat))" -NoTimestamp
        Write-Log "Лог-файл: $logFile" -NoTimestamp
        $script:processExitCode = if ($manualSyncSuccess) { 0 } else { 1 }
        Show-ScriptProgress -Status "Завершено" -PercentComplete 100
        return
    }
    
    # Використовуємо NoTimestamp для інформаційного блоку
    Write-Log "==="
    Write-Log "=== ОПЦIЇ СКРИПТА ==="
    Write-Log "Версiя та дата скрипта: $ScriptVersion вiд $ScriptDate" -NoTimestamp
    Write-Log "Час початку: $($scriptStartTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Кореневий каталог: $rootPath" -NoTimestamp
    Write-Log "Каталог резервних копiй: $backupRootPath" -NoTimestamp
    Write-Log "Режим логування: $LogLevel" -NoTimestamp
    Write-Log "Режим сумiсностi: $(if ($compatibilityMode) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Видалення коректних архiвiв за строком зберігання: $(if ($enableArchiveDeletion) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Очищення неповних/пошкоджених комплектів після $failedArchiveRetentionDays днів: $(if ($enableFailedArchiveDeletion) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Очищення обідніх архівів (_1300.): $(if ($enableLunchArchiveCleanup) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Узгодженість щоденних архівів: $([string]$backupConsistency.Mode)" -NoTimestamp
    foreach ($archive in $archiveDefinitions) {
        Write-Log "Архiвацiя $($archive.Type): $(if ($archive.Enabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    }
    if ([bool]$componentSettings.Archive.BRAVOEXCH) {
        if (-not [string]::IsNullOrWhiteSpace([string]$bravoExchSourceDirectory)) {
            Write-Log "Джерело BRAVOEXCH: $bravoExchSourceDirectory (вибрано автоматично)" -NoTimestamp
        } else {
            Write-Log "Джерело BRAVOEXCH не знайдено: жоден із каталогів не існує або не містить файлів: $($bravoExchSourceCandidates -join '; ')" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Локальна синхронiзацiя BAZA: $(if ($bazaLocalSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Завантаження архiвiв на SFTP: $(if ($sftpArchiveUploadEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA на SFTP: $(if ($bazaSFTPSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA WWW на SFTP: $(if ($bazaWWWSFTPSyncEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    if ($bazaWWWSFTPSyncEnabled) {
        if ($bazaWWWDetection.Success) {
            Write-Log (
                "Джерело BAZA WWW: $($bazaWWWPaths.Source); " +
                "служба: $($bazaWWWDetection.ServiceName); " +
                "executable: $($bazaWWWDetection.ServiceExecutable)"
            ) -NoTimestamp
        } else {
            Write-Log "Джерело BAZA WWW не визначено: $($bazaWWWDetection.Reason)" -Level "ERROR" -NoTimestamp
        }
    }
    Write-Log "Копіювання архівів на NAS/SMB: $(if ($smbArchiveCopyEnabled) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp

    $archiveCredentialValid = $true
    if ($enabledArchives.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА ПАРОЛЯ АРХIВIВ ==="
        if (-not [string]::IsNullOrWhiteSpace($script:archiveCredentialInitializationError)) {
            Write-Log "Не вдалося завантажити пароль архiвiв: $($script:archiveCredentialInitializationError)" -Level "ERROR"
            $archiveCredentialValid = $false
        } elseif ([string]::IsNullOrWhiteSpace($script:archivePassword)) {
            Write-Log "Пароль архiвiв вiдсутнiй у Windows Credential Manager" -Level "ERROR"
            $archiveCredentialValid = $false
        } elseif ($archiveParams -match '(?i)(^|\s)-p(?=\S|\s|$)') {
            Write-Log "Видалiть параметр -p<пароль> з archiveParams у BRAVO.config: пароль має зберiгатися лише у Credential Manager" -Level "ERROR"
            $archiveCredentialValid = $false
        } else {
            Write-Log "Пароль архiвiв завантажено з Windows Credential Manager" -Level "SUCCESS"
        }
    }

    $archiveConsistencyValid = $true
    if ($enabledArchives.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА УЗГОДЖЕНОСТI АРХIВIВ ==="
        $consistencyMode = [string]$backupConsistency.Mode
        $snapshotContext = [string]$backupConsistency.SnapshotContext
        if ($consistencyMode -ne "VSS") {
            Write-Log "backupConsistency.Mode повинен мати значення VSS; live-архівація заборонена" -Level "ERROR"
            $archiveConsistencyValid = $false
        } elseif ($snapshotContext -ne "ClientAccessible") {
            Write-Log "backupConsistency.SnapshotContext повинен мати значення ClientAccessible" -Level "ERROR"
            $archiveConsistencyValid = $false
        } else {
            Write-Log "Узгодженість архівів: окремий VSS-знімок для кожного компонента" -Level "SUCCESS"
        }
    }

    # Перевіряємо налаштування SFTP лише для увімкнених компонентів передачі
    $sftpConfigurationValid = $true
    if ($sftpTransferEnabled) {
        Show-ScriptProgress -Status "Перевiрка конфiгурацiї SFTP" -PercentComplete 10
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА КОНФIГУРАЦIЇ SFTP ==="
        $sftpConfigurationValid = Test-SFTPConfig
        if (-not $sftpConfigurationValid) {
            Write-Log "SFTP-компоненти буде пропущено; локальна архiвацiя продовжиться" -Level "WARNING"
            $operationFailed = $true
        }
    } else {
        Write-Log "Перевiрка SFTP не потрiбна: усi компоненти передачi вимкнено" -Level "INFO"
    }

    $smbConfigurationValid = $true
    if ($smbArchiveCopyEnabled) {
        Show-ScriptProgress -Status "Перевірка конфігурації NAS/SMB" -PercentComplete 11
        Write-Log "==="
        Write-Log "=== ПЕРЕВІРКА КОНФІГУРАЦІЇ NAS/SMB ==="
        $smbConfigurationValid = Test-SMBConfig
        if (-not $smbConfigurationValid) {
            Write-Log "Копіювання на NAS/SMB буде пропущено; локальна архівація продовжиться" -Level "WARNING"
            $operationFailed = $true
        }
    } else {
        Write-Log "Перевірка NAS/SMB не потрібна: компонент вимкнено" -Level "INFO"
    }
    
    $oldLogsToRemove = @()
    if (Test-Path -LiteralPath $logPath -PathType Container) {
        $logRetentionCutoff = (Get-Date).AddDays(-$logRetentionDays)
        $oldLogsToRemove = @(Get-BRAVOFiles -Path $logPath -Filter $logFileFilter |
            Where-Object { $_.LastWriteTime -lt $logRetentionCutoff })
    } else {
        Write-Log "Шлях журналів не знайдено: $logPath" -Level "ERROR"
        $operationFailed = $true
    }

    if ($oldLogsToRemove.Count -gt 0) {
        Write-Log "==="
        Write-Log "=== ОЧИЩЕННЯ СТАРИХ ЛОГIВ ==="
        Show-ScriptProgress -Status "Очищення старих логiв" -PercentComplete 12
        if (-not (Remove-OldLogsByAge -Path $logPath -Filter $logFileFilter -RetentionDays $logRetentionDays)) {
            $operationFailed = $true
        }
    }
    
    # Перевірка шляхів
    Write-Log "==="
    Write-Log "=== ПЕРЕВIРКА НЕОБХIДНИХ ШЛЯХIВ ==="
    Show-ScriptProgress -Status "Перевiрка необхiдних шляхiв" -PercentComplete 15
    $requiredPaths = @($baseRequiredPaths)
    $archiveToolAvailable = $archiveCredentialValid -and $archiveConsistencyValid

    if ($enabledArchives.Count -gt 0) {
        $requiredPaths += @{Path=$arcPath; Description="7-Zip"; CreateIfMissing=$false}
    }

    $basePathsAvailable = $true
    foreach ($item in $requiredPaths) {
        if (-not (Test-PathWithLog `
            -Path $item.Path `
            -Description $item.Description `
            -CreateIfMissing ([bool]$item.CreateIfMissing))) {
            $basePathsAvailable = $false
            if ($item.Path -eq $arcPath) {
                $archiveToolAvailable = $false
            }
        }
    }

    foreach ($archive in $enabledArchives) {
        $sourceAvailable = Test-PathWithLog `
            -Path $archive.Source `
            -Description "Джерело архiву $($archive.Type) мiстить данi" `
            -CreateIfMissing $false
        $destinationAvailable = Test-PathWithLog `
            -Path $archive.Destination `
            -Description "Каталог архiву $($archive.Type)" `
            -CreateIfMissing $true

        if ($archiveToolAvailable -and $sourceAvailable -and $destinationAvailable) {
            $readyArchives += $archive
        } else {
            $results[$archive.Type] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
            }
            Write-Log "Компонент $($archive.Type) пропущено через помилку налаштувань, шляху або вiдсутнi данi" -Level "ERROR"
            $operationFailed = $true
        }
    }

    $bazaSourceAvailable = $true
    $bazaDestinationAvailable = $true
    if ($bazaLocalSyncEnabled -or $bazaSFTPSyncEnabled) {
        $bazaSourceAvailable = Test-PathWithLog `
            -Path $bazaPaths.Source `
            -Description "Каталог BAZA" `
            -CreateIfMissing $false
    }
    if ($bazaLocalSyncEnabled) {
        $bazaDestinationAvailable = Test-PathWithLog `
            -Path $bazaPaths.Destination `
            -Description "Каталог архiву BAZA" `
            -CreateIfMissing $true
    }
    $bazaWWWSourceAvailable = $true
    if ($bazaWWWSFTPSyncEnabled) {
        if ($bazaWWWDetection.Success -and
            -not [string]::IsNullOrWhiteSpace([string]$bazaWWWPaths.Source)) {
            $bazaWWWSourceAvailable = Test-PathWithLog `
                -Path $bazaWWWPaths.Source `
                -Description "Каталог BAZA WWW" `
                -CreateIfMissing $false
        } else {
            Write-Log "Каталог BAZA WWW недоступний: $($bazaWWWDetection.Reason)" -Level "ERROR"
            $bazaWWWSourceAvailable = $false
        }
    }

    $allPathsExist = (
        $basePathsAvailable -and
        $readyArchives.Count -eq $enabledArchives.Count -and
        $bazaSourceAvailable -and
        $bazaDestinationAvailable -and
        $bazaWWWSourceAvailable
    )
    Show-PathCheckSummary -CheckedPaths $requiredPaths -AllPathsExist $allPathsExist
    
    # Синхронізація BAZA
    if ($bazaLocalSyncEnabled -and $bazaSourceAvailable -and $bazaDestinationAvailable) {
        Show-ScriptProgress -Status "Локальна синхронiзацiя BAZA" -PercentComplete 20
        Write-Log "==="
        Write-Log "=== СИНХРОНIЗАЦIЯ BAZA ==="
        $syncSuccess = Sync-Folders -SourcePath $bazaPaths.Source -DestinationPath $bazaPaths.Destination

        if ($syncSuccess) {
            Write-Log "Синхронiзацiя BAZA успiшна" -Level "SUCCESS"
        } else {
            Write-Log "Помилка синхронiзацiї BAZA - архiвацiя може бути неповною" -Level "WARNING"
            $operationFailed = $true
        }
    } elseif ($bazaLocalSyncEnabled) {
        Write-Log "Локальну синхронiзацiю BAZA пропущено через помилку шляху" -Level "ERROR"
        $operationFailed = $true
    } else {
        Write-Log "Локальну синхронiзацiю BAZA вимкнено в конфiгурацiї" -Level "INFO"
    }
    
    # Створення архівів
    $archiveIndex = 0

    foreach ($archive in $readyArchives) {
        $archiveIndex++
        $archiveProgress = 30 + [Math]::Floor((($archiveIndex - 1) / [Math]::Max(1, $readyArchives.Count)) * 40)
        Show-ScriptProgress -Status "Архiвацiя $($archive.Type) ($archiveIndex з $($readyArchives.Count))" -PercentComplete $archiveProgress
        Show-ItemProgress `
            -Id 10 `
            -Activity "BRAVO_ARCHIV — архiвацiя компонентiв" `
            -Item $archive.Type `
            -Current $archiveIndex `
            -Total $readyArchives.Count
        $archiveName = $archive.NameTemplate -f $archivePrefix, $now
        Write-Log "==="
        Write-Log "=== АРХIВАЦIЯ $($archive.Type) ==="
        $success = $false
        $vssSnapshot = $null
        try {
            $vssSnapshot = New-BRAVOVSSSnapshot -SourcePath $archive.Source
            $success = New-Archive `
                -SourcePath $vssSnapshot.SourcePath `
                -ArchivePath $archive.Destination `
                -ArchiveName $archiveName `
                -ArcPath $arcPath `
                -ArcParams $archiveParams
        } catch {
            Write-Log "Не вдалося виконати узгоджену VSS-архівацію $($archive.Type): $($_.Exception.Message)" -Level "ERROR"
            $success = $false
        } finally {
            if ($null -ne $vssSnapshot) {
                if (-not (Remove-BRAVOVSSSnapshot -Snapshot $vssSnapshot)) {
                    $operationFailed = $true
                }
            }
        }
        
        if ($success) {
            Write-Log "==="
            Write-Log "=== СТВОРЕННЯ ХЕШУ $($archive.Type) ==="
            $hashProgress = [Math]::Min(69, $archiveProgress + 8)
            Show-ScriptProgress -Status "Створення SHA512 для $($archive.Type)" -PercentComplete $hashProgress
            $archivePath = Join-Path $archive.Destination $archiveName
            $hashPath = "$archivePath$hashFileExtension"
            $hashSuccess = New-SHA512Hash -FilePath $archivePath -HashFilePath $hashPath
            
            $results[$archive.Type] = @{
                ArchivePath = $archivePath
                HashPath = $hashPath
                ArchiveSuccess = $success
                HashSuccess = $hashSuccess
            }
        } else {
            $results[$archive.Type] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
            }
        }
    }
    Show-ItemProgress -Id 10 -Activity "BRAVO_ARCHIV — архiвацiя компонентiв" -Completed
    
    # Видалення старих архівів: розділ логу з'являється лише перед фактичним видаленням.
    if ($enableArchiveDeletion) {
        $effectiveArchiveRetentionDays = 183
        try {
            if ($null -ne $archiveRetentionDays -and [int]$archiveRetentionDays -gt 0) {
                $effectiveArchiveRetentionDays = [int]$archiveRetentionDays
            } elseif ($null -ne $archiveVersions -and [int]$archiveVersions -gt 0) {
                # Сумісність із конфігами до archiveRetentionDays. Значення
                # archiveVersions використовуємо як строк у днях лише під час міграції.
                $effectiveArchiveRetentionDays = [int]$archiveVersions
                Write-Log "Застарілий archiveVersions=$effectiveArchiveRetentionDays застосовано як строк зберігання у днях; перенесіть значення до archiveRetentionDays" -Level "WARNING"
            } else {
                Write-Log "archiveRetentionDays відсутній або некоректний; для безпеки застосовано $effectiveArchiveRetentionDays днів" -Level "WARNING"
            }
        } catch {
            Write-Log "archiveRetentionDays не вдалося прочитати; для безпеки застосовано $effectiveArchiveRetentionDays днів" -Level "WARNING"
        }
        $archiveCleanupSectionShown = $false
        foreach ($archive in $enabledArchives) {
            if (-not (Remove-OldBackupSets -Path $archive.Destination -RetentionDays $effectiveArchiveRetentionDays -Component $archive.Type -CleanupSectionShown ([ref]$archiveCleanupSectionShown))) {
                $operationFailed = $true
            }
        }
    }

    if ($enableLunchArchiveCleanup) {
        $effectiveLunchArchiveRetentionMonths = 2
        try {
            if ($null -ne $lunchArchiveRetentionMonths -and [int]$lunchArchiveRetentionMonths -gt 0) {
                $effectiveLunchArchiveRetentionMonths = [int]$lunchArchiveRetentionMonths
            } else {
                Write-Log "lunchArchiveRetentionMonths відсутній або некоректний; для безпеки застосовано $effectiveLunchArchiveRetentionMonths місяці" -Level "WARNING"
            }
        } catch {
            Write-Log "lunchArchiveRetentionMonths не вдалося прочитати; для безпеки застосовано $effectiveLunchArchiveRetentionMonths місяці" -Level "WARNING"
        }

        $lunchArchiveDirectories = @($lunchArchiveCleanupDirectories | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
        if ([string]::IsNullOrWhiteSpace([string]$lunchArchiveCleanupPath) -or $lunchArchiveDirectories.Count -eq 0) {
            Write-Log "Очищення обідніх архівів увімкнено, але lunchArchiveCleanupPath або lunchArchiveCleanupDirectories не налаштовано" -Level "ERROR"
            $operationFailed = $true
        } elseif (-not (Remove-OldLunchArchives `
            -ArchiveRoot $lunchArchiveCleanupPath `
            -Directories $lunchArchiveDirectories `
            -RetentionMonths $effectiveLunchArchiveRetentionMonths)) {
            $operationFailed = $true
        }
    }
    
    # Передача на SFTP
    if ($sftpTransferEnabled) {
        Show-ScriptProgress -Status "Перевiрка з'єднання з SFTP" -PercentComplete 78
        if (-not $sftpConfigurationValid) {
            Write-Log "Передачу на SFTP пропущено через помилки конфiгурацiї" -Level "ERROR"
            $operationFailed = $true
        } elseif (-not (Test-NetworkConnection)) {
            Write-Log "Мережеве з'єднання недоступне - пропускаємо передачу на SFTP" -Level "ERROR"
            $operationFailed = $true
        } elseif (-not (Test-SFTPConnection -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey)) {
            Write-Log "Помилка пiдключення до SFTP - пропускаємо передачу" -Level "ERROR"
            $operationFailed = $true
        } else {
            if ($sftpArchiveUploadEnabled) {
                $uploadSuccess = 0
                $uploadQueue = @()

                # Формуємо чергу у стабільному порядку компонентів, щоб відсоток
                # і лічильник файлів не змінювали порядок між запусками.
                foreach ($archive in $enabledArchives) {
                    $archiveType = $archive.Type
                    if ($results.ContainsKey($archiveType) -and
                        $results[$archiveType].ArchiveSuccess -and
                        $results[$archiveType].HashSuccess) {
                        $uploadQueue += [pscustomobject]@{
                            LocalPath = [string]$results[$archiveType].ArchivePath
                            RemoteDirectory = [string]$sftpDirectories[$archiveType]
                        }
                        $uploadQueue += [pscustomobject]@{
                            LocalPath = [string]$results[$archiveType].HashPath
                            RemoteDirectory = [string]$sftpDirectories[$archiveType]
                        }
                    }
                }

                $uploadTotal = $uploadQueue.Count
                if ($uploadTotal -gt 0) {
                    Show-ScriptProgress -Status "Завантаження архiвiв на SFTP" -PercentComplete 82
                    Write-Log "==="
                    Write-Log "=== ЗАВАНТАЖЕННЯ АРХIВIВ НА SFTP ==="
                }
                $uploadIndex = 0
                foreach ($uploadItem in $uploadQueue) {
                    $uploadIndex++
                    $uploadFileName = Split-Path $uploadItem.LocalPath -Leaf
                    Show-ItemProgress `
                        -Id 13 `
                        -Activity "BRAVO_ARCHIV — завантаження на SFTP" `
                        -Item $uploadFileName `
                        -Current $uploadIndex `
                        -Total $uploadTotal
                    $fileUploaded = Send-FileViaWinSCP `
                        -WinSCPPath $winSCPPath `
                        -RepositorySFTPUrl $sftpUrl `
                        -HostKey $sftpHostKey `
                        -LocalFilePath $uploadItem.LocalPath `
                        -RemoteDirectory $uploadItem.RemoteDirectory
                    if ($fileUploaded) {
                        $uploadSuccess++
                    }
                }
                Show-ItemProgress -Id 13 -Activity "BRAVO_ARCHIV — завантаження на SFTP" -Completed

                if ($uploadTotal -gt 0) {
                    $uploadLevel = if ($uploadSuccess -eq $uploadTotal) { "SUCCESS" } else { "ERROR" }
                    Write-Log "Завантажено $uploadSuccess з $uploadTotal файлiв на SFTP" -Level $uploadLevel
                    if ($uploadSuccess -ne $uploadTotal) {
                        $operationFailed = $true
                    }
                } else {
                    Write-Log "Немає успiшно створених архiвiв для завантаження на SFTP" -Level "WARNING"
                    if ($enabledArchives.Count -gt 0) {
                        $operationFailed = $true
                    }
                }
            } else {
                Write-Log "Завантаження архiвiв на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }

            if ($bazaSFTPSyncEnabled -and $bazaSourceAvailable) {
                Show-ScriptProgress -Status "Синхронiзацiя BAZA на SFTP" -PercentComplete 90
                Write-Log "==="
                Write-Log "=== СИНХРОНIЗАЦIЯ BAZA НА SFTP ==="
                $bazaSFTPSync = Sync-FolderToSFTP -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey -LocalDirectory $bazaPaths.Source -RemoteDirectory $sftpDirectories.BAZA
                if (-not $bazaSFTPSync) {
                    Write-Log "Каталог BAZA не вдалося синхронiзувати з SFTP" -Level "WARNING"
                    $operationFailed = $true
                }
            } elseif ($bazaSFTPSyncEnabled) {
                Write-Log "Синхронiзацiю BAZA на SFTP пропущено через помилку локального шляху" -Level "ERROR"
                $operationFailed = $true
            } else {
                Write-Log "Синхронiзацiю BAZA на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }

            if ($bazaWWWSFTPSyncEnabled -and $bazaWWWSourceAvailable) {
                Show-ScriptProgress -Status "Синхронiзацiя BAZA WWW на SFTP" -PercentComplete 91
                Write-Log "==="
                Write-Log "=== СИНХРОНIЗАЦIЯ BAZA WWW НА SFTP ==="
                $bazaWWWSFTPSync = Sync-FolderToSFTP `
                    -WinSCPPath $winSCPPath `
                    -RepositorySFTPUrl $sftpUrl `
                    -HostKey $sftpHostKey `
                    -LocalDirectory $bazaWWWPaths.Source `
                    -RemoteDirectory $sftpDirectories.BAZAWWW `
                    -ComponentName "BAZA WWW"
                if (-not $bazaWWWSFTPSync) {
                    Write-Log "Каталог BAZA WWW не вдалося синхронiзувати з SFTP" -Level "WARNING"
                    $operationFailed = $true
                }
            } elseif ($bazaWWWSFTPSyncEnabled) {
                Write-Log "Синхронiзацiю BAZA WWW на SFTP пропущено через помилку автоматичного визначення шляху" -Level "ERROR"
                $operationFailed = $true
            } else {
                Write-Log "Синхронiзацiю BAZA WWW на SFTP вимкнено в конфiгурацiї" -Level "INFO"
            }
        }
    } else {
        Write-Log "Усi компоненти передачi на SFTP вимкнено в конфiгурацiї" -Level "INFO"
    }

    # Копіювання успішно створених архівів та hash-файлів на NAS/SMB
    if ($smbArchiveCopyEnabled) {
        Show-ScriptProgress -Status "Копіювання архівів на NAS/SMB" -PercentComplete 92
        Write-Log "==="
        Write-Log "=== КОПІЮВАННЯ АРХІВІВ НА NAS/SMB ==="
        if (-not $smbConfigurationValid) {
            Write-Log "Копіювання на NAS/SMB пропущено через помилки конфігурації" -Level "ERROR"
            $operationFailed = $true
        } else {
            $smbCopyResult = Copy-ArchivesToSMB -ArchiveResults $results
            if ($smbCopyResult.Total -eq 0) {
                Write-Log "Немає успішно створених архівів для копіювання на NAS/SMB" -Level "WARNING"
                if ($enabledArchives.Count -gt 0) {
                    $operationFailed = $true
                }
            } elseif ($smbCopyResult.Success -eq $smbCopyResult.Total) {
                Write-Log "Скопійовано $($smbCopyResult.Success) з $($smbCopyResult.Total) файлів на NAS/SMB" -Level "SUCCESS"
            } else {
                Write-Log "Скопійовано $($smbCopyResult.Success) з $($smbCopyResult.Total) файлів на NAS/SMB" -Level "ERROR"
                $operationFailed = $true
            }
        }
    } else {
        Write-Log "Копіювання архівів на NAS/SMB вимкнено в конфігурації" -Level "INFO"
    }
    
    # Завершення
    $scriptEndTime = Get-Date
    $duration = $scriptEndTime - $scriptStartTime
    
    Write-Log "==="
    Write-Log "=== ЗАВЕРШЕННЯ РОБОТИ СКРИПТА ==="
    Write-Log "Час початку: $($scriptStartTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Час завершення: $($scriptEndTime.ToString($logTimestampFormat))" -NoTimestamp
    Write-Log "Тривалiсть: $($duration.ToString($durationFormat))" -NoTimestamp
    
    # Підсумок
    $successCount = ($results.Values | Where-Object { $_.ArchiveSuccess }).Count
    $totalCount = $results.Count
    if ($readyArchives.Count -ne $enabledArchives.Count -or
        @($results.Values | Where-Object {
            -not $_.ArchiveSuccess -or -not $_.HashSuccess
        }).Count -gt 0) {
        $operationFailed = $true
    }
    
    Write-Log "Створено архiвiв: $successCount з $totalCount" -NoTimestamp
    Write-Log "Лог-файл: $logFile" -NoTimestamp

    if ($backupMonitoring.Enabled -and $backupMonitoring.RunAfterBackup) {
        Show-ScriptProgress -Status "Перевiрка стану резервних копiй" -PercentComplete 96
        Write-Log "==="
        Write-Log "=== ПЕРЕВIРКА СТАНУ РЕЗЕРВНИХ КОПIЙ ==="

        try {
                $healthParameters = @{
                    ConfigPath = $configPath
                }
                $backupNotificationMode = [string]$backupMonitoring.NotificationMode
                if ([string]::IsNullOrWhiteSpace($backupNotificationMode)) {
                    $backupNotificationMode = [string]$backupMonitoring.SlackMode
                }
                if ($backupMonitoring.NotifyOnSuccessAfterBackup -and
                    $backupNotificationMode.ToLowerInvariant() -eq "all") {
                    $healthParameters.NotifyOnSuccess = $true
                }
                $healthCheckResult = Invoke-BRAVOEmbeddedHealth @healthParameters
                switch ($healthCheckResult.Status) {
                    "Healthy" {
                        Write-Log "Health-check: усi резервнi копiї актуальнi; повідомлення: $($healthCheckResult.Notification)" -Level "SUCCESS"
                    }
                    "Critical" {
                        Write-Log "Health-check: знайдено проблем: $($healthCheckResult.IssueCount); повідомлення: $($healthCheckResult.Notification)" -Level "ERROR"
                        $operationFailed = $true
                    }
                    "NotificationError" {
                        Write-Log "Health-check завершився, але повідомлення не вiдправлено: $($healthCheckResult.Error)" -Level "ERROR"
                        $operationFailed = $true
                    }
                    default {
                        Write-Log "Health-check завершився зі статусом: $($healthCheckResult.Status)" -Level "WARNING"
                        $operationFailed = $true
                    }
                }
        } catch {
            Write-Log "Помилка запуску вбудованого health-check: $($_.Exception.Message)" -Level "ERROR"
            $operationFailed = $true
        }
    }

    Write-Log "Результат: $(if ($operationFailed) {'ПОМИЛКА'} else {'УСПIШНО'})" -NoTimestamp
    Write-Log "==="
    if (-not $operationFailed) {
        Write-BRAVOBackupExecutionState
    }
    Show-ScriptProgress -Status "Завершено" -PercentComplete 100
    if ($operationFailed) {
        $script:processExitCode = 1
    }
}

# Запуск головної функції
$script:processExitCode = 0
$script:archiveProcessLock = $null
$script:archiveProcessLockPath = $null
try {
    Main
} catch {
    $script:processExitCode = 1
    throw
} finally {
    if ($script:archiveProcessLock) {
        $script:archiveProcessLock.Dispose()
        $script:archiveProcessLock = $null
    }
    if (-not [string]::IsNullOrWhiteSpace(
            [string]$script:archiveProcessLockPath
        ) -and
        (Test-Path -LiteralPath $script:archiveProcessLockPath -PathType Leaf)) {
        Remove-Item `
            -LiteralPath $script:archiveProcessLockPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if ($script:smbCredential -and $script:smbCredential.Password) {
        $script:smbCredential.Password.Dispose()
        $script:smbCredential = $null
    }
    Show-ScriptProgress -Completed
    Wait-ForManualExit
}

if ($script:processExitCode -ne 0) {
    Exit $script:processExitCode
}
