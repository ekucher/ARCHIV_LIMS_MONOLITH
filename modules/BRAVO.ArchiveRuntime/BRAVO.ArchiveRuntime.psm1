# Archive-specific extensions of the shared BRAVO runtime.
# They serialize WinSCP.com access and import their Compatibility dependency.
$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

function Get-BRAVOWinSCPDotNetComponents {
    [CmdletBinding()]
    param(
        [string]$WinSCPAssemblyPath,
        [string]$WinSCPPath
    )

    $assemblyCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($WinSCPAssemblyPath)) {
        $assemblyCandidates += $WinSCPAssemblyPath
    }
    if (-not [string]::IsNullOrWhiteSpace($WinSCPPath)) {
        $assemblyCandidates += Join-Path `
            (Split-Path -Path $WinSCPPath -Parent) `
            'WinSCPnet.dll'
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $assemblyCandidates += Join-Path `
            ${env:ProgramFiles(x86)} `
            'WinSCP\WinSCPnet.dll'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $assemblyCandidates += Join-Path `
            $env:ProgramFiles `
            'WinSCP\WinSCPnet.dll'
    }

    foreach ($assemblyPath in @($assemblyCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            continue
        }
        $executablePath = Join-Path `
            (Split-Path -Path $assemblyPath -Parent) `
            'WinSCP.exe'
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            continue
        }

        return [pscustomobject]@{
            AssemblyPath = (Resolve-Path -LiteralPath $assemblyPath).Path
            ExecutablePath = (Resolve-Path -LiteralPath $executablePath).Path
        }
    }

    return $null
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
            Get-BRAVOWmiInstance -ClassName Win32_Process -Filter "Name = '$processName'" |
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

