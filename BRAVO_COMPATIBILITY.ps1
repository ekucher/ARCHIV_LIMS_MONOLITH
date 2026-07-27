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

function Start-BRAVOProcessOutputCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    $readToEndAsyncMethod = [System.IO.StreamReader].GetMethod(
        "ReadToEndAsync",
        [Type[]]@()
    )
    $useModernApi = (
        $null -ne $readToEndAsyncMethod -and
        $env:BRAVO_FORCE_LEGACY_API -ne "1"
    )

    if ($useModernApi) {
        $Process.Start() | Out-Null
        return New-Object PSObject -Property @{
            Mode = "Task"
            Process = $Process
            OutputTask = $Process.StandardOutput.ReadToEndAsync()
            ErrorTask = $Process.StandardError.ReadToEndAsync()
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
            # Task-based capture не реєструє PowerShell event jobs.
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
        if ($Password.Contains('"')) {
            throw "пароль архіву містить непідтримуваний символ подвійних лапок"
        }

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $SevenZipPath
        $processInfo.Arguments = (
            "t -y -bb1 -p`"{0}`" `"{1}`"" -f $Password, $ArchivePath
        )
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $capture = Start-BRAVOProcessOutputCapture -Process $process

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

Assert-BRAVOPowerShellCompatibility
[void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
$script:BRAVOCompatibility = Get-BRAVOCompatibilityInfo
$script:BRAVOPowerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
