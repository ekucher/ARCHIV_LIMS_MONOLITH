# Спільне transcript-журналювання для допоміжних скриптів BRAVO.
# Production-скрипти мають власні предметні журнали й цей файл не підключають.

$script:BRAVOHelperLogActive = $false
$script:BRAVOHelperLogPath = $null
$script:BRAVOHelperLogQuietConsole = $false

function Start-BRAVOHelperLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string]$ConfigPath,

        [switch]$QuietConsole,

        [ValidateRange(1, 3650)]
        [int]$RetentionDays = 31
    )

    if ($script:BRAVOHelperLogActive) {
        return [string]$script:BRAVOHelperLogPath
    }

    $scriptDirectory = Split-Path -Path $ScriptPath -Parent
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        $scriptDirectory = [Environment]::CurrentDirectory
    }

    $preferredLogDirectory = Join-Path $scriptDirectory "LOGS\HELPERS"
    $logDirectory = $preferredLogDirectory
    try {
        [void][IO.Directory]::CreateDirectory($logDirectory)
    } catch {
        $logDirectory = Join-Path ([IO.Path]::GetTempPath()) "BRAVO\LOGS\HELPERS"
        try {
            [void][IO.Directory]::CreateDirectory($logDirectory)
            if (-not $QuietConsole) {
                Write-Warning (
                    "Не вдалося створити каталог журналів '$preferredLogDirectory'. " +
                    "Використовується резервний каталог '$logDirectory'."
                )
            }
        } catch {
            if (-not $QuietConsole) {
                Write-Warning "Не вдалося створити каталог журналів допоміжних скриптів: $($_.Exception.Message)"
            }
            return $null
        }
    }

    $scriptName = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    $safeScriptName = $scriptName -replace '[^A-Za-z0-9_.-]', '_'
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $logFileName = "{0}_{1}_PID{2}.log" -f $safeScriptName, $timestamp, $PID
    $logPath = Join-Path $logDirectory $logFileName

    try {
        $retentionThreshold = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $logDirectory -Filter "*.log" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $retentionThreshold } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        if (-not $QuietConsole) {
            Write-Warning "Не вдалося очистити застарілі helper-логи: $($_.Exception.Message)"
        }
    }

    try {
        Start-Transcript -Path $logPath -Force | Out-Null
        $script:BRAVOHelperLogActive = $true
        $script:BRAVOHelperLogPath = $logPath
        $script:BRAVOHelperLogQuietConsole = [bool]$QuietConsole
        if (-not $QuietConsole) {
            Write-Host "Лог допоміжного скрипта: $logPath" -ForegroundColor DarkGray
            Write-Host (
                "Запуск: script=$scriptName; user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name); " +
                "computer=$env:COMPUTERNAME; PID=$PID; PowerShell=$($PSVersionTable.PSVersion)"
            ) -ForegroundColor DarkGray
            if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
                Write-Host "Config: $ConfigPath" -ForegroundColor DarkGray
            }
        }
        return $logPath
    } catch {
        $script:BRAVOHelperLogActive = $false
        $script:BRAVOHelperLogPath = $null
        $script:BRAVOHelperLogQuietConsole = $false
        if (-not $QuietConsole) {
            Write-Warning "Не вдалося розпочати журнал допоміжного скрипта: $($_.Exception.Message)"
        }
        return $null
    }
}

function Complete-BRAVOHelperLog {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    if ($script:BRAVOHelperLogActive) {
        $completedLogPath = [string]$script:BRAVOHelperLogPath
        $quietConsole = [bool]$script:BRAVOHelperLogQuietConsole
        if (-not $quietConsole) {
            Write-Host "Код завершення допоміжного скрипта: $ExitCode" -ForegroundColor DarkGray
            Write-Host "Лог допоміжного скрипта: $completedLogPath" -ForegroundColor DarkGray
        }
        try {
            Stop-Transcript | Out-Null
        } catch {
            if (-not $quietConsole) {
                Write-Warning "Не вдалося коректно завершити transcript: $($_.Exception.Message)"
            }
        }
        if ($quietConsole) {
            try {
                [IO.File]::AppendAllText(
                    $completedLogPath,
                    "`r`nBRAVO helper process exit code: $ExitCode`r`n",
                    [Text.Encoding]::UTF8
                )
            } catch {
                # Machine-readable stdout має залишатися чистим навіть при помилці логування.
            }
        }
        $script:BRAVOHelperLogActive = $false
        $script:BRAVOHelperLogQuietConsole = $false
    }

    exit $ExitCode
}
