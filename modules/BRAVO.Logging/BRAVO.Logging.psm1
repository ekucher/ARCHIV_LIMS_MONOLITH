# Єдиний журнал BRAVO з розділенням каналів.
#
# Принцип: бізнес-логіка лише повідомляє, що сталося. Цей модуль вирішує, що
# записати у файл, а що показати в консолі. Рівні файлу й консолі незалежні,
# тому докладний журнал не перевантажує оператора.
#
# Мінімальна підтримувана версія: Windows PowerShell 3.0.

# Set-StrictMode успадковується від конфігураційного завантажувача, тому весь
# стан модуля ініціалізується явно.
$script:BRAVOLogFile = $null
$script:BRAVOLogFileLevel = 'INFO'
$script:BRAVOLogConsoleLevel = 'WARNING'
$script:BRAVOLogActive = $false
$script:BRAVOLogWarningCount = 0
$script:BRAVOLogErrorCount = 0

# Куди саме йде консольна половина запису. За замовчуванням — Write-Host,
# щоб модуль лишався самодостатнім. Runtime, який рендерить операційну
# консоль, підмінює це на BRAVO.Console: інакше WARNING із бізнес-логіки
# дописався б у хвіст відкритого рядка етапу.
#
# Це навмисно callback, а не залежність від BRAVO.Console: журналювання —
# нижчий шар, і воно має працювати там, де консолі немає взагалі
# (допоміжні скрипти, -AsJson, виклик із планувальника).
$script:BRAVOLogConsoleWriter = $null

# Порядок важливий: SUCCESS свідомо нижче за WARNING, щоб підняття порога
# ніколи не приховало попереджень і помилок. У старому $global:logLevels
# SUCCESS=4 був вище за ERROR=3, через що $LogLevel="SUCCESS" ховав збої.
$script:BRAVOLogSeverity = @{
    TRACE   = 0
    DEBUG   = 1
    INFO    = 2
    SUCCESS = 3
    WARNING = 4
    ERROR   = 5
    FATAL   = 6
}

$script:BRAVOLogColors = @{
    TRACE   = 'DarkGray'
    DEBUG   = 'DarkGray'
    INFO    = 'White'
    SUCCESS = 'Green'
    WARNING = 'Yellow'
    ERROR   = 'Red'
    FATAL   = 'Red'
}

function Get-BRAVOLogSeverityValue {
    param([string]$Level)

    if (-not [string]::IsNullOrWhiteSpace($Level)) {
        $normalized = $Level.Trim().ToUpperInvariant()
        if ($script:BRAVOLogSeverity.ContainsKey($normalized)) {
            return [int]$script:BRAVOLogSeverity[$normalized]
        }
    }
    return [int]$script:BRAVOLogSeverity['INFO']
}

function Protect-BRAVOLogSecret {
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $sanitized = $Text
    # Облікові дані всередині URL: sftp://user:password@host -> sftp://user:***@host
    $sanitized = $sanitized -replace '(?i)([a-z][a-z0-9+.-]*://[^:/\s@]+):[^@\s]+@', '$1:***@'
    # Явні параметри пароля у командних рядках WinSCP і 7-Zip.
    $sanitized = $sanitized -replace '(?i)(-password=)(?:"[^"]*"|\S+)', '$1***'
    # (?!ath|assword) — інакше це правило повторно "з'їдає" вже замасковане
    # -password=*** з рядка вище, розпізнавши його як коротку форму -p.
    $sanitized = $sanitized -replace '(?i)(\s-p)(?!ath|assword)(?:"[^"]*"|\S+)', '$1***'
    $sanitized = $sanitized -replace '(?i)((?:password|passwd|secret|token)\s*[:=]\s*)(?:"[^"]*"|\S+)', '$1***'
    # Webhook URL — сам bearer-секрет, без user:pass@; підтримувані провайдери
    # (Send-BRAVOWebhookNotification -Provider slack|discord) мають токен
    # прямо у шляху, а не в окремому параметрі.
    $sanitized = $sanitized -replace '(?i)(hooks\.slack\.com/services/)\S+', '$1***'
    $sanitized = $sanitized -replace '(?i)(discord(?:app)?\.com/api/webhooks/)\S+', '$1***'
    return $sanitized
}

function Initialize-BRAVOLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFile,

        [string]$FileLevel = 'INFO',

        [string]$ConsoleLevel = 'WARNING'
    )

    $logDirectory = Split-Path -Path $LogFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and
        -not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($logDirectory)
    }

    $script:BRAVOLogFile = $LogFile
    $script:BRAVOLogFileLevel = $FileLevel
    $script:BRAVOLogConsoleLevel = $ConsoleLevel
    $script:BRAVOLogActive = $true
    $script:BRAVOLogWarningCount = 0
    $script:BRAVOLogErrorCount = 0

    return $LogFile
}

function Write-BRAVOLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'SUCCESS', 'WARNING', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO',

        [string]$Component = 'GENERAL',

        # Показати запис у консолі навіть якщо його рівень нижчий за поріг.
        [switch]$Console,

        # Ніколи не показувати запис у консолі.
        [switch]$NoConsole
    )

    $severity = Get-BRAVOLogSeverityValue -Level $Level
    if ($severity -ge (Get-BRAVOLogSeverityValue -Level 'WARNING')) {
        if ($severity -ge (Get-BRAVOLogSeverityValue -Level 'ERROR')) {
            $script:BRAVOLogErrorCount++
        } else {
            $script:BRAVOLogWarningCount++
        }
    }

    $safeMessage = Protect-BRAVOLogSecret -Text $Message

    if ($script:BRAVOLogActive -and
        $severity -ge (Get-BRAVOLogSeverityValue -Level $script:BRAVOLogFileLevel)) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $line = '{0} [{1,-7}] [{2}] {3}' -f $timestamp, $Level, $Component, $safeMessage
        try {
            # UTF-8 із BOM — конвенція журналів проєкту ($logFileEncoding = "UTF8").
            # Без BOM Windows PowerShell 5.1, Notepad і частина засобів перегляду
            # читають файл як ANSI і показують кирилицю кракозябрами.
            # AppendAllText пише преамбулу лише під час створення файлу.
            [System.IO.File]::AppendAllText(
                $script:BRAVOLogFile,
                $line + [Environment]::NewLine,
                (New-Object System.Text.UTF8Encoding($true))
            )
        } catch {
            Write-Warning "Не вдалося записати журнал: $($_.Exception.Message)"
        }
    }

    $showInConsole = $severity -ge (Get-BRAVOLogSeverityValue -Level $script:BRAVOLogConsoleLevel)
    if ($Console) {
        $showInConsole = $true
    }
    if ($NoConsole) {
        $showInConsole = $false
    }
    if (-not $showInConsole) {
        return
    }

    if ($null -ne $script:BRAVOLogConsoleWriter) {
        # Помилка рендера консолі не має ховати сам запис: файл уже
        # записано вище, тому тут лишається дати оператору побачити текст
        # хоч у сирому вигляді.
        try {
            & $script:BRAVOLogConsoleWriter $safeMessage $Level
            return
        } catch {
            Write-Warning "Не вдалося відрендерити запис журналу в консоль: $($_.Exception.Message)"
        }
    }

    $color = if ($script:BRAVOLogColors.ContainsKey($Level)) {
        $script:BRAVOLogColors[$Level]
    } else {
        'White'
    }
    Write-Host $safeMessage -ForegroundColor $color
}

# Runtime викликає це один раз після імпорту BRAVO.Console. Виклик без
# -Writer повертає стандартний Write-Host — потрібно для допоміжних
# скриптів і машинних режимів, де операційної консолі немає.
function Set-BRAVOLogConsoleWriter {
    [CmdletBinding()]
    param([AllowNull()][scriptblock]$Writer)

    $script:BRAVOLogConsoleWriter = $Writer
}

function Write-BRAVOLogException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [string]$Component = 'GENERAL',

        [string]$Context
    )

    $header = if ([string]::IsNullOrWhiteSpace($Context)) {
        $ErrorRecord.Exception.Message
    } else {
        "${Context}: $($ErrorRecord.Exception.Message)"
    }
    # Саме повідомлення потрібне оператору, а stack trace — лише в журналі.
    Write-BRAVOLog -Message $header -Level 'ERROR' -Component $Component

    $details = New-Object System.Collections.Generic.List[string]
    $details.Add("Тип: $($ErrorRecord.Exception.GetType().FullName)")
    if ($null -ne $ErrorRecord.InvocationInfo) {
        $details.Add("Розташування: $($ErrorRecord.InvocationInfo.PositionMessage -replace "`r?`n", ' ')")
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
        $details.Add("Стек: $($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' | ')")
    }
    foreach ($detail in $details) {
        Write-BRAVOLog -Message $detail -Level 'DEBUG' -Component $Component -NoConsole
    }
}

function Get-BRAVOLogStatistics {
    [CmdletBinding()]
    param()

    return New-Object PSObject -Property @{
        LogFile = $script:BRAVOLogFile
        Warnings = $script:BRAVOLogWarningCount
        Errors = $script:BRAVOLogErrorCount
        FileLevel = $script:BRAVOLogFileLevel
        ConsoleLevel = $script:BRAVOLogConsoleLevel
    }
}

function Complete-BRAVOLog {
    [CmdletBinding()]
    param()

    $statistics = Get-BRAVOLogStatistics
    $script:BRAVOLogActive = $false
    return $statistics
}

Export-ModuleMember -Function @(
    'Initialize-BRAVOLog',
    'Set-BRAVOLogConsoleWriter',
    'Write-BRAVOLog',
    'Write-BRAVOLogException',
    'Protect-BRAVOLogSecret',
    'Get-BRAVOLogStatistics',
    'Complete-BRAVOLog'
)
