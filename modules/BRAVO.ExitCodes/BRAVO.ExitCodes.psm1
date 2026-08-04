# Формальний контракт кодів завершення BRAVO.
#
# Раніше всі три runtime (Archive/Health/Maintenance) зводили десятки різних
# категорій відмови до простого 0/1, тому зовнішній моніторинг (Task
# Scheduler history, Zabbix) не міг відрізнити "немає SFTP з'єднання" від
# "архів пошкоджено". Цей модуль — єдине джерело правди для кодів: кожен
# runtime обчислює свій набір switch-прапорців із уже наявних у нього
# змінних стану й один раз, у кінці виконання, викликає Resolve-BRAVOExitCode.
#
# Мінімальна підтримувана версія: Windows PowerShell 3.0.

# Set-StrictMode успадковується від конфігураційного завантажувача, тому весь
# стан модуля ініціалізується явно.
#
# ВАЖЛИВО: саме @{} (Hashtable), не [ordered]@{}. OrderedDictionary має
# позиційний індексатор this[int index] поряд із ключовим this[object key],
# і для цілочисельних ключів PowerShell обирає саме позиційний — $d[10]
# поверне 11-й за порядком вставки елемент, а не значення ключа 10.
# Перевірено експериментально: [ordered]@{0=...;10=...;...} на $d[10]
# віддавало значення зовсім іншого ключа. Порядок тут не потрібен, тому
# звичайний Hashtable — і безпечніший, і достатній.
$script:BRAVOExitCodeNames = @{
    0  = "Success"
    10 = "SuccessWithWarnings"
    20 = "SkippedLockBusy"
    30 = "InvalidConfiguration"
    31 = "CredentialsUnavailable"
    40 = "LocalArchiveFailed"
    41 = "IntegrityTestFailed"
    50 = "SftpFailed"
    51 = "SmbFailed"
    60 = "MaintenanceFailed"
    70 = "HealthCritical"
    90 = "InternalError"
}

function Resolve-BRAVOExitCode {
    [CmdletBinding()]
    param(
        [switch]$LockBusy,
        [switch]$InvalidConfiguration,
        [switch]$CredentialsUnavailable,
        [switch]$LocalArchiveFailed,
        [switch]$IntegrityTestFailed,
        [switch]$SftpFailed,
        [switch]$SmbFailed,
        [switch]$MaintenanceFailed,
        [switch]$HealthCritical,
        [switch]$InternalError,
        [switch]$HasWarnings
    )

    # Пріоритет при одночасних відмовах: спершу — чому взагалі не змогли
    # почати (lock/config/creds), потім — що саме не вдалося зробити
    # (local -> SFTP -> SMB -> maintenance -> health), і лише насамкінець —
    # "були тільки попередження". InternalError має найвищий пріоритет:
    # непередбачений збій ховає будь-яку часткову категоризацію нижче.
    if ($InternalError) { return 90 }
    if ($LockBusy) { return 20 }
    if ($InvalidConfiguration) { return 30 }
    if ($CredentialsUnavailable) { return 31 }
    if ($LocalArchiveFailed) { return 40 }
    if ($IntegrityTestFailed) { return 41 }
    if ($SftpFailed) { return 50 }
    if ($SmbFailed) { return 51 }
    if ($MaintenanceFailed) { return 60 }
    if ($HealthCritical) { return 70 }
    if ($HasWarnings) { return 10 }
    return 0
}

function Get-BRAVOExitCodeName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Code)

    if ($script:BRAVOExitCodeNames.ContainsKey($Code)) {
        return [string]$script:BRAVOExitCodeNames[$Code]
    }
    return "Unknown($Code)"
}

Export-ModuleMember -Function @(
    'Resolve-BRAVOExitCode',
    'Get-BRAVOExitCodeName'
)
