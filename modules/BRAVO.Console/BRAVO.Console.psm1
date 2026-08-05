# Рендер операційної консолі BRAVO.
#
# Цей модуль відповідає лише за те, що бачить оператор: заголовок, етапи,
# короткі результати й фінальний підсумок. Він нічого не пише у журнал —
# цим займається BRAVO.Logging.
#
# Мінімальна підтримувана версія: Windows PowerShell 3.0.

# Set-StrictMode успадковується від конфігураційного завантажувача, тому весь
# стан модуля ініціалізується явно.
$script:BRAVOConsoleStepWidth = 58
$script:BRAVOConsoleStepOpen = $false
$script:BRAVOConsoleEnabled = $true

# Єдиний індикатор прогресу. Раніше паралельно малювались три Write-Progress
# (загальний, покомпонентний і 7-Zip), причому перші два дублювали один одного.
# Тут завжди один Id без ParentId, тому вкладених смуг не виникає.
$script:BRAVOProgressId = 1
$script:BRAVOProgressActivity = 'BRAVO'
$script:BRAVOProgressPhase = $null
$script:BRAVOProgressPercent = 0
$script:BRAVOProgressEnabled = $true

$script:BRAVOConsoleStatusColors = @{
    RUNNING = 'Cyan'
    OK      = 'Green'
    SKIPPED = 'DarkGray'
    WARNING = 'Yellow'
    ERROR   = 'Red'
}

function Initialize-BRAVOConsole {
    [CmdletBinding()]
    param(
        [ValidateRange(20, 200)]
        [int]$StepWidth = 58,

        [bool]$Enabled = $true
    )

    $script:BRAVOConsoleStepWidth = $StepWidth
    $script:BRAVOConsoleStepOpen = $false
    $script:BRAVOConsoleEnabled = $Enabled
}

function Initialize-BRAVOProgress {
    [CmdletBinding()]
    param(
        [string]$Activity = 'BRAVO',
        [bool]$Enabled = $true
    )

    $script:BRAVOProgressActivity = $Activity
    $script:BRAVOProgressEnabled = $Enabled
    $script:BRAVOProgressPhase = $null
    $script:BRAVOProgressPercent = 0
}

# Фаза — це великий етап скрипта. Вона лишається на смузі, поки конкретна
# операція (7-Zip, robocopy, WinSCP) не додасть до неї свій живий деталь.
function Write-BRAVOProgressPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Phase,
        [int]$PercentComplete = -1
    )

    $script:BRAVOProgressPhase = $Phase
    if ($PercentComplete -ge 0) {
        $script:BRAVOProgressPercent = [Math]::Max(0, [Math]::Min(100, $PercentComplete))
    }
    Write-BRAVOProgressDetail -Detail ''
}

function Write-BRAVOProgressDetail {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Detail)

    if (-not $script:BRAVOProgressEnabled) {
        return
    }

    $status = if ([string]::IsNullOrWhiteSpace($Detail)) {
        [string]$script:BRAVOProgressPhase
    } elseif ([string]::IsNullOrWhiteSpace($script:BRAVOProgressPhase)) {
        $Detail
    } else {
        "{0} — {1}" -f $script:BRAVOProgressPhase, $Detail
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = ' '
    }

    Write-Progress `
        -Id $script:BRAVOProgressId `
        -Activity $script:BRAVOProgressActivity `
        -Status $status `
        -PercentComplete $script:BRAVOProgressPercent
}

function Complete-BRAVOProgress {
    [CmdletBinding()]
    param()

    if (-not $script:BRAVOProgressEnabled) {
        return
    }
    $script:BRAVOProgressPhase = $null
    Write-Progress -Id $script:BRAVOProgressId -Activity $script:BRAVOProgressActivity -Completed
}

function Format-BRAVOFileSize {
    [CmdletBinding()]
    param([AllowNull()][Nullable[long]]$Bytes)

    if ($null -eq $Bytes) {
        return 'немає даних'
    }
    if ($Bytes -ge 1TB) { return "$([math]::Round($Bytes / 1TB, 2)) ТБ" }
    if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) ГБ" }
    if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) МБ" }
    if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 2)) КБ" }
    return "$Bytes Б"
}

# У класичному хості PowerShell Write-Progress малюється поверх верхніх
# рядків вікна й повертає їх лише на -Completed. Через це заголовок і перші
# етапи були невидимі протягом усього запуску — саме тоді, коли оператор
# дивиться на екран. Порожні рядки перед заголовком зсувають вміст під
# смугу, тому нічого не перекривається.
$script:BRAVOConsoleProgressReservedLines = 6

function Write-BRAVOHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Institution,

        [string]$InstitutionCode,

        [datetime]$StartedAt = (Get-Date)
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }

    if ($script:BRAVOProgressEnabled) {
        for ($i = 0; $i -lt $script:BRAVOConsoleProgressReservedLines; $i++) {
            Write-Host ''
        }
    }

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Institution)) {
        $institutionLine = if ([string]::IsNullOrWhiteSpace($InstitutionCode)) {
            "Установа: $Institution"
        } else {
            "Установа: $Institution [$InstitutionCode]"
        }
        Write-Host $institutionLine
    }
    Write-Host ("Початок: {0}" -f $StartedAt.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ''
}

function Get-BRAVOStepPrefixText {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Name
    )

    $prefix = '[{0}/{1}]' -f $Current, $Total
    return "$prefix $Name"
}

function Write-BRAVOStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Current,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }

    $baseText = Get-BRAVOStepPrefixText -Current $Current -Total $Total -Name $Name
    $dots = '.' * [math]::Max(1, $script:BRAVOConsoleStepWidth - $baseText.Length)
    Write-Host "$baseText$dots " -NoNewline
    $script:BRAVOConsoleStepOpen = $true
}

function Write-BRAVOStepResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Current,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Name,

        [ValidateSet('RUNNING', 'OK', 'SKIPPED', 'WARNING', 'ERROR')]
        [string]$Status = 'OK',

        [string]$Details
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }

    # Якщо рядок етапу вже відкрито через Write-BRAVOStep, дописуємо лише
    # статус, щоб етап займав рівно один рядок консолі.
    if (-not $script:BRAVOConsoleStepOpen) {
        $baseText = Get-BRAVOStepPrefixText -Current $Current -Total $Total -Name $Name
        $dots = '.' * [math]::Max(1, $script:BRAVOConsoleStepWidth - $baseText.Length)
        Write-Host "$baseText$dots " -NoNewline
    }
    $script:BRAVOConsoleStepOpen = $false

    $statusColor = if ($script:BRAVOConsoleStatusColors.ContainsKey($Status)) {
        $script:BRAVOConsoleStatusColors[$Status]
    } else {
        'White'
    }
    if ([string]::IsNullOrWhiteSpace($Details)) {
        Write-Host $Status -ForegroundColor $statusColor
    } else {
        Write-Host $Status -ForegroundColor $statusColor -NoNewline
        Write-Host "  $Details" -ForegroundColor DarkGray
    }
}

function Write-BRAVOConsoleDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::DarkGray
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    if ($script:BRAVOConsoleStepOpen) {
        Write-Host ''
        $script:BRAVOConsoleStepOpen = $false
    }
    Write-Host ("      " + $Message) -ForegroundColor $Color
}

# Рівні журналу мають ті самі кольори, що й статуси етапів: оператор не має
# вчитуватись у префікс, щоб зрозуміти, що сталося. Ключі збігаються з
# рівнями BRAVO.Logging, тому маплення один-в-один без перекладу.
$script:BRAVOConsoleLevelColors = @{
    TRACE   = 'DarkGray'
    DEBUG   = 'DarkGray'
    INFO    = 'Gray'
    SUCCESS = 'Green'
    WARNING = 'Yellow'
    ERROR   = 'Red'
    FATAL   = 'Red'
}

# Єдина точка, через яку в консоль потрапляє повідомлення журналу. Головне,
# що вона робить понад вибір кольору — закриває відкритий рядок етапу, інакше
# WARNING із бізнес-логіки дописався б у хвіст "[3/7] BLOG........." і зламав
# би розмітку саме тоді, коли щось пішло не так.
function Write-BRAVOConsoleMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,

        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'SUCCESS', 'WARNING', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO'
    )

    $color = if ($script:BRAVOConsoleLevelColors.ContainsKey($Level)) {
        [ConsoleColor]$script:BRAVOConsoleLevelColors[$Level]
    } else {
        [ConsoleColor]::Gray
    }
    Write-BRAVOConsoleDetail -Message $Message -Color $color
}

function Write-BRAVOWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-BRAVOConsoleDetail -Message $Message -Color ([ConsoleColor]::Yellow)
}

function Write-BRAVOError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$SeeLog
    )

    Write-BRAVOConsoleDetail -Message $Message -Color ([ConsoleColor]::Red)
    if ($SeeLog) {
        Write-BRAVOConsoleDetail -Message 'Деталі записано у журнал.'
    }
}

function Write-BRAVOSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('УСПІШНО', 'ЧАСТКОВО', 'ПОМИЛКА')]
        [string]$Result,

        [timespan]$Duration,

        # Впорядкований перелік підсумкових показників у форматі "Назва" = "Значення".
        [System.Collections.IDictionary]$Metrics,

        [string]$LogFile
    )

    if (-not $script:BRAVOConsoleEnabled) {
        return
    }
    if ($script:BRAVOConsoleStepOpen) {
        Write-Host ''
        $script:BRAVOConsoleStepOpen = $false
    }

    $resultColor = switch ($Result) {
        'УСПІШНО'  { 'Green' }
        'ЧАСТКОВО' { 'Yellow' }
        default    { 'Red' }
    }

    Write-Host ''
    Write-Host 'Результат: ' -NoNewline
    Write-Host $Result -ForegroundColor $resultColor
    if ($PSBoundParameters.ContainsKey('Duration')) {
        Write-Host ("Тривалість: {0:hh\:mm\:ss}" -f $Duration)
    }
    if ($null -ne $Metrics) {
        foreach ($key in $Metrics.Keys) {
            Write-Host ("{0}: {1}" -f $key, $Metrics[$key])
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Write-Host ''
        Write-Host 'Детальний журнал:'
        Write-Host $LogFile -ForegroundColor DarkGray
    }
    Write-Host ''
}

Export-ModuleMember -Function @(
    'Initialize-BRAVOConsole',
    'Initialize-BRAVOProgress',
    'Write-BRAVOProgressPhase',
    'Write-BRAVOProgressDetail',
    'Complete-BRAVOProgress',
    'Format-BRAVOFileSize',
    'Write-BRAVOHeader',
    'Write-BRAVOStep',
    'Write-BRAVOStepResult',
    'Write-BRAVOConsoleDetail',
    'Write-BRAVOConsoleMessage',
    'Write-BRAVOWarning',
    'Write-BRAVOError',
    'Write-BRAVOSummary'
)
