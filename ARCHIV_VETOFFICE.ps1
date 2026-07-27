##########
# BravoSoft
# Author: Evgeniy Kucher
# Version: 2.6.0, 2026-07-26
# Скрипт для архівації та резервного копіювання даних VETOFFICE системи
# Модифікована версія з покращеним логуванням
# Конфігурація винесена в окремий файл
##########

# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass –Force

$vetOfficeScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Path $PSCommandPath -Parent
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}
$compatibilityModulePath = Join-Path $vetOfficeScriptDirectory "BRAVO_COMPATIBILITY.ps1"
if (-not (Test-Path -LiteralPath $compatibilityModulePath -PathType Leaf)) {
    Write-Host "ПОМИЛКА: Не знайдено модуль сумісності: $compatibilityModulePath" -ForegroundColor Red
    exit 1
}
try {
    . $compatibilityModulePath
} catch {
    Write-Host "ПОМИЛКА сумісності: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Запит на підвищення дозволу виконання скрипта
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Потрiбнi права адмiнiстратора. Запит UAC..." -ForegroundColor Yellow
    
    # Створюємо процес з явним запитом UAC
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "powershell.exe"
    $processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($args.Count -gt 0) {
        $forwardedArguments = @($args | ForEach-Object {
            '"' + ([string]$_).Replace('"', '\"') + '"'
        })
        $processInfo.Arguments += " " + ($forwardedArguments -join " ")
    }
    $processInfo.Verb = "runas"  # Це викликає UAC
    $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    
    try {
    $process = [System.Diagnostics.Process]::Start($processInfo)
    $process.WaitForExit()
    Exit $process.ExitCode
} catch {
    Write-Host "UAC запит вiдхилено або сталася помилка: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Запустiть PowerShell з правами адмiнiстратора вручну" -ForegroundColor Yellow
    Exit 1
    }
}

# =============================================
# ЗАВАНТАЖЕННЯ КОНФІГУРАЦІЇ
# =============================================

# Змінні версії
$ScriptVersion = "2.6.0"
$ScriptDate = "2026-07-26"

# Шлях до файлу конфігурації
$configPath = Join-Path $vetOfficeScriptDirectory "ARCHIV_VETOFFICE.config.ps1"

# Перевірка наявності файлу конфігурації
if (-not (Test-Path $configPath)) {
    Write-Host "ПОМИЛКА: Файл конфiгурацiї не знайдено: $configPath" -ForegroundColor Red
    Write-Host "Створiть файл ARCHIV_VETOFFICE.config.ps1 на основi шаблону." -ForegroundColor Yellow
    Exit 1
}

# Завантаження конфігурації
try {
    # Видаляємо глобальні змінні перед завантаженням нових
    Get-Variable | Where-Object { $_.Name -like "global:*" -and $_.Name -notlike "global:?*" } | Remove-Variable -ErrorAction SilentlyContinue
    
    # Завантажуємо конфігурацію
    . $configPath
    
    Write-Host "Конфiгурацiю завантажено успiшно: $configPath" -ForegroundColor Green
} catch {
    Write-Host "ПОМИЛКА: Не вдалося завантажити конфiгурацiю: $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}

# Секрети VETOFFICE зберігаються лише у Windows Credential Manager.
$script:vetArchiveCredentialError = $null
$script:vetSFTPCredentialError = $null
$script:vetSMBCredentialError = $null
$credentialHelperError = $null
$script:vetArchivePassword = $null
$script:vetNetworkDriveName = "BRAVOVET_$PID"
$Login = $null
$Password = $null
$sftpUrl = $null
try {
    if ($null -eq $credentialSettings -or
        [string]::IsNullOrWhiteSpace([string]$credentialSettings.HelperPath) -or
        -not (Test-Path -LiteralPath $credentialSettings.HelperPath -PathType Leaf)) {
        throw "не знайдено модуль Credential Manager: $($credentialSettings.HelperPath)"
    }

    . $credentialSettings.HelperPath
} catch {
    $credentialHelperError = $_.Exception.Message
    $script:vetArchiveCredentialError = $credentialHelperError
    $script:vetSFTPCredentialError = $credentialHelperError
    $script:vetSMBCredentialError = $credentialHelperError
}

if ([string]::IsNullOrWhiteSpace($credentialHelperError)) {
try {
    if ($archiveParams -match '(?i)(^|\s)-p(?=\S|\s|$)') {
        throw "пароль архіву не можна зберігати в archiveParams"
    }

    $script:vetArchivePassword = Get-BRAVOCredentialSecret `
        -Target ([string]$credentialSettings.Targets.ArchivePassword)
    if ([string]::IsNullOrWhiteSpace($script:vetArchivePassword)) {
        throw "не знайдено пароль 7-Zip у Credential Manager"
    }
    if ($script:vetArchivePassword.Contains('"')) {
        throw "пароль 7-Zip містить непідтримуваний символ подвійних лапок"
    }
    $archiveParams = "$archiveParams -p$($script:vetArchivePassword)"
} catch {
    $script:vetArchiveCredentialError = $_.Exception.Message
}

if ($enableSFTPUpload) {
    try {
        $Login = Get-BRAVOCredentialSecret `
            -Target ([string]$credentialSettings.Targets.SFTPLogin)
        $Password = Get-BRAVOCredentialSecret `
            -Target ([string]$credentialSettings.Targets.SFTPPassword)
        if ([string]::IsNullOrWhiteSpace($Login) -or
            [string]::IsNullOrWhiteSpace($Password)) {
            throw "не знайдено логін або пароль SFTP у Credential Manager"
        }
        $sftpUrl = New-BRAVOSFTPSessionUrl `
            -HostName $sftpHostName `
            -UserName $Login `
            -Password $Password `
            -Port $sftpPort
    } catch {
        $script:vetSFTPCredentialError = $_.Exception.Message
    }
}

if ($enableNetworkCopy) {
    try {
        $networkCopyConfig.Username = Get-BRAVOCredentialSecret `
            -Target ([string]$credentialSettings.Targets.SMBLogin)
        $networkCopyConfig.Password = Get-BRAVOCredentialSecret `
            -Target ([string]$credentialSettings.Targets.SMBPassword)
        if ([string]::IsNullOrWhiteSpace([string]$networkCopyConfig.Username) -or
            [string]::IsNullOrWhiteSpace([string]$networkCopyConfig.Password)) {
            throw "не знайдено логін або пароль SMB у Credential Manager"
        }
    } catch {
        $script:vetSMBCredentialError = $_.Exception.Message
    }
}
}

# =============================================
# ІНІЦІАЛІЗАЦІЯ ЗМІННИХ З КОНФІГУРАЦІЇ
# =============================================

# РЕЖИМ СУМІСНОСТІ
$compatibilityMode = $false  # Автоматично визначається нижче

# ШЛЯХИ ДО ІНСТРУМЕНТІВ
$arcPath = Join-Path $toolsPath "7za.exe"
$winSCPPath = Join-Path $toolsPath "WinSCP.com"

# КОНФІГУРАЦІЙНИЙ ОБ'ЄКТ (для сумісності з існуючим кодом)
$config = @{
    RootPath = $rootPath
    ArchivPath = $archivPath
    ToolsPath = $toolsPath
    LogPath = $logPath
    ArchivePrefix = $archivePrefix
    LogRetentionDays = $logRetentionDays
    ArchiveVersions = $archiveVersions
    EnableArchiveDeletion = $enableArchiveDeletion
    EnableSFTPUpload = $enableSFTPUpload
    EnableNetworkCopy = $enableNetworkCopy  # НОВИЙ параметр
    CompatibilityMode = $compatibilityMode
    ExcludeComponents = $excludeComponents
    ShowSystemInfo = $showSystemInfo
    ShowHardwareInfo = $showHardwareInfo
    ShowPerformanceInfo = $showPerformanceInfo
}

# ІНСТРУМЕНТИ (для сумісності з існуючим кодом)
$tools = @{
    ArcPath = $arcPath
    WinSCPPath = $winSCPPath
}

# SFTP КОНФІГ (для сумісності з існуючим кодом)
$sftpConfig = @{
    Login = $Login
    Password = $Password
    Url = $sftpUrl
    HostKey = $sftpHostKey
    Directories = $sftpDirectories
}

# МЕРЕЖЕВА КОНФІГ (для сумісності з існуючим кодом)
$networkCopyConfig = @{
    Enabled = $enableNetworkCopy
    NetworkPath = $networkCopyConfig.NetworkPath
    Username = $networkCopyConfig.Username
    Password = $networkCopyConfig.Password
    MaxRetries = $networkCopyConfig.MaxRetries
    RetryDelay = $networkCopyConfig.RetryDelay
}

# =============================================
# НАЛАШТУВАННЯ КОНСОЛІ
# =============================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "СКРИПТ АРХIВАЦIЇ VETOFFICE v.$ScriptVersion (МОДИФІКОВАНИЙ)"
$Host.UI.RawUI.BackgroundColor = "Black"
$Host.UI.RawUI.ForegroundColor = "White"
Clear-Host

# =============================================
# ФУНКЦІЯ ДЛЯ РОБОТИ З ПЛАНУВАЛЬНИКОМ
# =============================================

function Get-VetOfficeTaskSchedulerContext {
    $service = New-Object -ComObject "Schedule.Service"
    $service.Connect()
    return [pscustomobject]@{
        Service = $service
        Root = $service.GetFolder("\")
    }
}

function Get-VetOfficeScheduledTasks {
    param($RootFolder)

    return @(
        $RootFolder.GetTasks(1) |
            Where-Object { $_.Name -like "*ARCHIV_VETOFFICE*" }
    )
}

function Get-VetOfficeTaskStateName {
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

function Add-ToTaskScheduler {
    param(
        [string]$TaskName = "ARCHIV_VETOFFICE_Backup",  # Назва завдання в Планувальнику
        [string]$ScriptPath = $PSCommandPath,           # Шлях до скрипта PowerShell
        [string]$StartTime = "02:00",                   # Час запуску завдання (формат HH:MM)
        [int]$IntervalDays = 1                          # Інтервал днів між запусками
    )
    
    Write-Host "`n=== НАЛАШТУВАННЯ ПЛАНУВАЛЬНИКА ЗАВДАНЬ ===" -ForegroundColor Yellow
    
    # Запит часу запуску
    Write-Host "`nУ який час запускати архiвацiю?" -ForegroundColor Cyan
    Write-Host "Формат: HH:MM (наприклад, 02:00, 23:30)" -ForegroundColor Gray
    $userTime = Read-Host "Час запуску (за замовчуванням $StartTime)"
    
    if ([string]::IsNullOrWhiteSpace($userTime)) {
        $userTime = $StartTime
    }
    
    # Валідація формату часу
    if ($userTime -notmatch '^([01]?[0-9]|2[0-3]):([0-5][0-9])$') {
        Write-Host "Невiрний формат часу! Використовується значення за замовчуванням: $StartTime" -ForegroundColor Red
        $userTime = $StartTime
    }
    
    # Розбиваємо час на години та хвилини
    $timeParts = $userTime -split ':'
    $hour = [int]$timeParts[0]
    $minute = [int]$timeParts[1]
    
    # Запит інтервалу
    Write-Host "`nЯк часто виконувати архiвацiю?" -ForegroundColor Cyan
    Write-Host "1. Щодня" -ForegroundColor Gray
    Write-Host "2. Щотижня" -ForegroundColor Gray
    Write-Host "3. Щомiсяця" -ForegroundColor Gray
    $intervalChoice = Read-Host "Оберiть варiант (1-3, за замовчуванням 1)"
    
    switch ($intervalChoice) {
        "2" { 
            $interval = "Weekly"
            $daysOfWeek = "Monday, Tuesday, Wednesday, Thursday, Friday"
            Write-Host "Завдання буде виконуватися щотижня у буднi" -ForegroundColor Green
        }
        "3" { 
            $interval = "Monthly"
            Write-Host "Завдання буде виконуватися щомiсяця 1-го числа" -ForegroundColor Green
        }
        default { 
            $interval = "Daily"
            Write-Host "Завдання буде виконуватися щодня" -ForegroundColor Green
        }
    }
    
    # Створюємо безпечне ім'я завдання (замінюємо двокрапку на підкреслення)
    $safeTime = $userTime -replace ':', '_'
    $taskName = "${TaskName}_${safeTime}"
    
    Write-Host "`nСтворення завдання в Планувальнику..." -ForegroundColor Yellow
    Write-Host "Назва завдання: $taskName" -ForegroundColor White
    Write-Host "Час запуску: $userTime" -ForegroundColor White
    Write-Host "Шлях до скрипта: $ScriptPath" -ForegroundColor White

    $scheduler = Get-VetOfficeTaskSchedulerContext
    
    # Перевіряємо, чи існує вже таке завдання
    $existingTask = try {
        $scheduler.Root.GetTask($taskName)
    } catch {
        $null
    }
    
    if ($existingTask) {
        Write-Host "Завдання вже iснує! Видаляємо старе..." -ForegroundColor Yellow
        try {
            $scheduler.Root.DeleteTask($taskName, 0)
            Write-Host "Старе завдання видалено успiшно" -ForegroundColor Green
        } catch {
            Write-Host "Не вдалося видалити старе завдання: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    try {
        $taskDefinition = $scheduler.Service.NewTask(0)
        $taskDefinition.RegistrationInfo.Description =
            "Автоматична архiвацiя VETOFFICE системи. Створено $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

        $taskDefinition.Principal.UserId = "SYSTEM"
        $taskDefinition.Principal.LogonType = 5 # TASK_LOGON_SERVICE_ACCOUNT
        $taskDefinition.Principal.RunLevel = 1 # TASK_RUNLEVEL_HIGHEST

        $taskDefinition.Settings.Enabled = $true
        $taskDefinition.Settings.DisallowStartIfOnBatteries = $false
        $taskDefinition.Settings.StopIfGoingOnBatteries = $false
        $taskDefinition.Settings.StartWhenAvailable = $true
        $taskDefinition.Settings.RestartInterval = "PT5M"
        $taskDefinition.Settings.RestartCount = 3
        $taskDefinition.Settings.ExecutionTimeLimit = [System.Xml.XmlConvert]::ToString(
            [timespan]::FromHours([math]::Max(1, [double]$taskExecutionTimeLimitHours))
        )
        $taskDefinition.Settings.MultipleInstances = 2 # TASK_INSTANCES_IGNORE_NEW

        $action = $taskDefinition.Actions.Create(0) # TASK_ACTION_EXEC
        $action.Path = "powershell.exe"
        $action.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $action.WorkingDirectory = Split-Path $ScriptPath -Parent

        $startDate = (Get-Date).Date.AddHours($hour).AddMinutes($minute)
        
        # Створюємо тригер залежно від інтервалу
        switch ($interval) {
            "Daily" {
                $trigger = $taskDefinition.Triggers.Create(2)
                $trigger.DaysInterval = [math]::Max(1, $IntervalDays)
            }
            "Weekly" {
                $trigger = $taskDefinition.Triggers.Create(3)
                $trigger.DaysOfWeek = 62 # Monday-Friday
                $trigger.WeeksInterval = 1
            }
            "Monthly" {
                $trigger = $taskDefinition.Triggers.Create(4)
                $trigger.DaysOfMonth = 1
                $trigger.MonthsOfYear = 4095 # January-December
            }
        }
        $trigger.StartBoundary = $startDate.ToString("yyyy-MM-dd'T'HH:mm:ss")
        $trigger.Enabled = $true

        $createdTask = $scheduler.Root.RegisterTaskDefinition(
            $taskName,
            $taskDefinition,
            6,
            "SYSTEM",
            $null,
            5,
            $null
        )
        
        Write-Host "`n✓ Завдання успiшно додано до Планувальника!" -ForegroundColor Green
        Write-Host "Назва: $taskName" -ForegroundColor White
        Write-Host "Час: $userTime" -ForegroundColor White
        Write-Host "Iнтервал: $interval" -ForegroundColor White
        
        # Показуємо інформацію про завдання
        Start-Sleep -Seconds 2
        Write-Host "`nПеревiрка створеного завдання..." -ForegroundColor Yellow
        
        try {
            if ($createdTask) {
                Write-Host "✓ Завдання знайдено в Планувальнику" -ForegroundColor Green
                Write-Host "Статус: $(Get-VetOfficeTaskStateName -State ([int]$createdTask.State))" -ForegroundColor White
                Write-Host "Останнiй запуск: $($createdTask.LastRunTime)" -ForegroundColor Gray
                Write-Host "Наступний запуск: $($createdTask.NextRunTime)" -ForegroundColor Gray
            }
        } catch {
            Write-Host "Не вдалося знайти створене завдання: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        
        return $true
        
    } catch {
        Write-Host "`n✗ Помилка при створеннi завдання: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Деталi помилки:" -ForegroundColor Yellow
        
        if ($_.Exception.Message -like "*0x80070057*") {
            Write-Host "- Можлива причина: недопустиме ім'я завдання (наприклад, містить спеціальні символи)" -ForegroundColor White
            Write-Host "- Спробуйте використати інший час без спеціальних символів" -ForegroundColor White
        } elseif ($_.Exception.Message -like "*доступ запрещен*" -or $_.Exception.Message -like "*access denied*") {
            Write-Host "- Можлива причина: недостатньо прав" -ForegroundColor White
            Write-Host "- Запустіть PowerShell від імені адміністратора" -ForegroundColor White
        }
        
        Write-Host "`nПеревiрте права адмiнiстратора та доступ до Планувальника завдань." -ForegroundColor Yellow
        return $false
    }
}

function Show-TaskSchedulerInfo {
    Write-Host "`n=== ІНФОРМАЦІЯ ПРО ЗАВДАННЯ В ПЛАНУВАЛЬНИКУ ===" -ForegroundColor Yellow
    
    $scheduler = Get-VetOfficeTaskSchedulerContext
    $tasks = @(Get-VetOfficeScheduledTasks -RootFolder $scheduler.Root)
    
    if ($tasks.Count -gt 0) {
        Write-Host "Знайдено завдання:" -ForegroundColor Green
        foreach ($task in $tasks) {
            Write-Host "`n  Назва: $($task.Name)" -ForegroundColor White
            Write-Host "  Статус: $(Get-VetOfficeTaskStateName -State ([int]$task.State))" -ForegroundColor Gray
            Write-Host "Останнiй запуск: $($task.LastRunTime)" -ForegroundColor Gray
            Write-Host "Наступний запуск: $($task.NextRunTime)" -ForegroundColor Gray
            
            # Отримуємо тригери
            $triggers = $task.Definition.Triggers
            foreach ($trigger in $triggers) {
                if ($trigger.StartBoundary) {
                    Write-Host "  Час запуску: $($trigger.StartBoundary)" -ForegroundColor Gray
                }
            }
            
            # Отримуємо інформацію про дію (що виконується)
            $actions = $task.Definition.Actions
            foreach ($action in $actions) {
                if ($action.Path) {
                    Write-Host "  Виконуваний файл: $($action.Path)" -ForegroundColor DarkGray
                }
                if ($action.Arguments) {
                    Write-Host "  Аргументи: $($action.Arguments)" -ForegroundColor DarkGray
                }
            }
        }
    } else {
        Write-Host "Завдання архiвацiї VETOFFICE не знайдено в Планувальнику." -ForegroundColor Yellow
        Write-Host "Використовуйте ключ -Schedule для додавання завдання." -ForegroundColor Gray
    }
    
    if ($tasks.Count -gt 0) {
        Write-Host "`n=== ЗАГАЛЬНИЙ ПЕРЕЛІК ЗАВДАНЬ ===" -ForegroundColor Yellow
        $tasks | ForEach-Object {
            [pscustomobject]@{
                TaskName = $_.Name
                State = Get-VetOfficeTaskStateName -State ([int]$_.State)
                LastRun = $_.LastRunTime
                NextRun = $_.NextRunTime
            }
        } | Format-Table -AutoSize
    }
}

function Remove-FromTaskScheduler {
    param(
        [string]$TaskName = ""  # Назва завдання для видалення (пусто - показати список)
    )
    
    Write-Host "`n=== ВИДАЛЕННЯ ЗАВДАНЬ З ПЛАНУВАЛЬНИКА ===" -ForegroundColor Yellow
    $scheduler = Get-VetOfficeTaskSchedulerContext
    
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        # Показуємо всі завдання для видалення
        $tasks = @(Get-VetOfficeScheduledTasks -RootFolder $scheduler.Root)
        
        if ($tasks.Count -eq 0) {
            Write-Host "Завдання архiвацiї VETOFFICE не знайдено." -ForegroundColor Yellow
            return
        }
        
        Write-Host "Знайдено завдання:" -ForegroundColor White
        $i = 1
        $taskList = @()
        foreach ($task in $tasks) {
            Write-Host "  $i. $($task.Name)" -ForegroundColor Gray
            $taskList += $task
            $i++
        }
        
        Write-Host "  $i. Всi завдання" -ForegroundColor Gray
        
        $choice = Read-Host "`nОберiть номер завдання для видалення (або Enter для скасування)"
        
        if ([string]::IsNullOrWhiteSpace($choice)) {
            Write-Host "Скасовано." -ForegroundColor Yellow
            return
        }
        
        if ($choice -eq $i) {
            # Видаляємо всі завдання
            Write-Host "Ви впевненi, що хочете видалити ВСI завдання архiвацiї VETOFFICE?" -ForegroundColor Red
            $confirm = Read-Host "Введiть 'YES' для пiдтвердження"
            
            if ($confirm -eq "YES") {
                foreach ($task in $taskList) {
                    try {
                        $scheduler.Root.DeleteTask($task.Name, 0)
                        Write-Host "✓ Видалено: $($task.Name)" -ForegroundColor Green
                    } catch {
                        Write-Host "✗ Помилка при видаленнi $($task.Name): $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
                Write-Host "`n✓ Всi завдання архiвацiї видалено." -ForegroundColor Green
            } else {
                Write-Host "Скасовано." -ForegroundColor Yellow
            }
        } elseif ($choice -ge 1 -and $choice -lt $i) {
            # Видаляємо одне завдання
            $taskToDelete = $taskList[$choice - 1]
            Write-Host "Ви впевненi, що хочете видалити завдання: $($taskToDelete.Name)?" -ForegroundColor Red
            $confirm = Read-Host "Введiть 'YES' для пiдтвердження"
            
            if ($confirm -eq "YES") {
                try {
                    $scheduler.Root.DeleteTask($taskToDelete.Name, 0)
                    Write-Host "✓ Завдання видалено: $($taskToDelete.Name)" -ForegroundColor Green
                } catch {
                    Write-Host "✗ Помилка при видаленнi: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "Скасовано." -ForegroundColor Yellow
            }
        } else {
            Write-Host "Невiрний вибiр. Скасовано." -ForegroundColor Red
        }
    } else {
        # Видаляємо конкретне завдання
        Write-Host "Ви впевненi, що хочете видалити завдання: $TaskName?" -ForegroundColor Red
        $confirm = Read-Host "Введiть 'YES' для пiдтвердження"
        
        if ($confirm -eq "YES") {
            try {
                $scheduler.Root.DeleteTask($TaskName, 0)
                Write-Host "✓ Завдання видалено: $TaskName" -ForegroundColor Green
            } catch {
                Write-Host "✗ Помилка при видаленнi: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "Скасовано." -ForegroundColor Yellow
        }
    }
}

# =============================================
# ДОПОМІЖНІ ФУНКЦІЇ
# =============================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [int]$SeparatorLength = 100,
        [switch]$NoTimestamp,  # Новий параметр для вiдключення timestamp
        [switch]$LogOnly        # Новий параметр: записувати тiльки в лог-файл, не в консоль
    )
    
    # Перевірка рівня логування
    $logLevels = @{"DEBUG"=0; "INFO"=1; "WARNING"=2; "ERROR"=3; "SUCCESS"=4}
    
    # Отримуємо поточний рівень логування з глобальної змінної
    $currentLogLevel = if ($global:LogLevel -and $logLevels.ContainsKey($global:LogLevel)) { 
        $logLevels[$global:LogLevel] 
    } else { 
        1 # Значення за замовчуванням - INFO
    }
    
    $messageLevel = if ($logLevels.ContainsKey($Level)) { 
        $logLevels[$Level] 
    } else { 
        1 # Значення за замовчуванням - INFO
    }
    
    # Пропускаємо повідомлення нижчого рівня
    if ($messageLevel -lt $currentLogLevel) {
        return
    }
    
    # Обробка спеціальних повідомлень-роздільників
    if ($Message -eq "=" -or $Message -eq "===") {
        # Генеруємо роздільник з 100 знаками "="
        $separator = "=" * 100
        
        # Виводимо в консоль тiльки якщo не LogOnly
        if (-not $LogOnly) {
            Write-Host $separator -ForegroundColor White
        }
        
        try {
            if (-not (Test-Path $logPath)) {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
            }
            $separator | Out-File -FilePath $global:logFile -Append -Encoding UTF8
        } catch {
            if (-not $LogOnly) {
                Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        return
    }
    
    # Обробка заголовків "--- текст ---"
    if ($Message -match "^--- .* ---$") {
        # Для підзаголовків --- ---
        if (-not $LogOnly) {
            Write-Host $Message -ForegroundColor Cyan
        }
        
        try {
            if (-not (Test-Path $logPath)) {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
            }
            $Message | Out-File -FilePath $global:logFile -Append -Encoding UTF8
        } catch {
            if (-not $LogOnly) {
                Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        return
    }
    
    # Обробка заголовків "=== текст ==="
    if ($Message -match "^=== .* ===$") {
        # Для заголовків === ===
        if (-not $LogOnly) {
            Write-Host $Message -ForegroundColor Yellow
        }
        
        try {
            if (-not (Test-Path $logPath)) {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
            }
            $Message | Out-File -FilePath $global:logFile -Append -Encoding UTF8
        } catch {
            if (-not $LogOnly) {
                Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        return
    }
    
    # Звичайні повідомлення
    if ($NoTimestamp) {
        # Повідомлення без timestamp (для інформаційних блоків)
        $logEntry = $Message
        
        # Для NoTimestamp повідомлень з LogOnly - додаємо timestamp при записі в лог
        if ($LogOnly) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $logEntry = "[$timestamp] [$Level] $Message"
        }
    } else {
        # Звичайні повідомлення з timestamp
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
    }
    
    # Виводимо в консоль тiльки якщo не LogOnly
    if (-not $LogOnly) {
        switch ($Level) {
            "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
            "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
            "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
            "DEBUG"   { Write-Host $logEntry -ForegroundColor Gray }
            default   { Write-Host $logEntry -ForegroundColor White }
        }
    }
    
    # Завжди записуємо в лог-файл
    try {
        if (-not (Test-Path $logPath)) {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        $logEntry | Out-File -FilePath $global:logFile -Append -Encoding UTF8
    } catch {
        if (-not $LogOnly) {
            Write-Host "Помилка запису у файл логу: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Test-PathWithLog {
    param(
        [string]$Path,
        [string]$Description
    )
    
    # Визначаємо, чи це каталог призначення (архіви, логи, тощо)
    $isDestinationPath = ($Description -like "*архiв*" -or 
                         $Description -like "*логiв*" -or 
                         $Path -eq $bazaPaths.Destination -or
                         $Path -eq $logPath -or
                         $Path -eq $toolsPath -or
                         $Path -eq $archivPath)
    
    if (Test-Path $Path) {
        Write-Log "$Description знайдено: $Path" -Level "DEBUG"
        return $true
    } else {
        # Для каталогів призначення - створюємо автоматично
        if ($isDestinationPath) {
            try {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
                Write-Log "$Description не знайдено, створено автоматично: $Path" -Level "SUCCESS"
                return $true
            } catch {
                Write-Log "$Description не знайдено i не вдалося створити: $Path" -Level "ERROR"
                return $false
            }
        } else {
            # Для всіх інших шляхів (джерела даних) - показуємо помилку
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
        Write-Log "==="
    } else {
        Write-Log "Знайдено помилки в шляхах - див. вище" -Level "ERROR"
        Write-Log "==="
    }
}

function Remove-OldBackupSets {
    param(
        [string]$Path,
        [int]$KeepCount,
        [string]$Component
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
        $validSets = @()
        foreach ($archive in @(Get-BRAVOFiles -Path $Path -Filter "*.mdz")) {
            $hashPath = "$($archive.FullName).sha512"
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

        foreach ($orphanHash in @(Get-BRAVOFiles -Path $Path -Filter "*.sha512")) {
            $archivePath = $orphanHash.FullName.Substring(0, $orphanHash.FullName.Length - ".sha512".Length)
            if ($failedArchiveDeletionEnabled -and
                -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -and
                $orphanHash.LastWriteTime -lt $invalidCutoff) {
                Remove-Item -LiteralPath $orphanHash.FullName -Force -ErrorAction Stop
                Write-Log "Видалено застарілий hash-файл без архіву: $($orphanHash.Name)" -Level "WARNING"
            }
        }

        if (-not $enableArchiveDeletion) {
            return $true
        }

        foreach ($set in @($validSets | Select-Object -Skip $KeepCount)) {
            Remove-Item -LiteralPath $set.Archive.FullName -Force -ErrorAction Stop
            try {
                Remove-Item -LiteralPath $set.HashPath -Force -ErrorAction Stop
            } catch {
                Write-Log "Архів видалено, але не вдалося видалити hash-файл $($set.HashPath): $($_.Exception.Message)" -Level "WARNING"
            }
            Write-Log "Видалено комплект ${Component}: $($set.Archive.Name)" -Level "SUCCESS"
        }
        return $true
    } catch {
        Write-Log "Помилка очищення комплектів ${Component}: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
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
        [string]$DestinationPath,
        [string]$SyncType = "LOCAL",  # "LOCAL" або "NETWORK"
        [switch]$LogAlways = $false
    )
    
    # Заголовок залежно від типу синхронізації
    $headerTitle = if ($SyncType -eq "NETWORK") { 
        "--- МЕРЕЖЕВА СИНХРОНІЗАЦІЯ ФАЙЛІВ BAZA ---"
    } else { 
        "--- ЛОКАЛЬНА СИНХРОНІЗАЦІЯ ФАЙЛІВ BAZA ---" 
    }
    
    Write-Log $headerTitle -Level "INFO"
    Write-Log "Джерело: $SourcePath" -Level "INFO"
    Write-Log "Призначення: $DestinationPath" -Level "INFO"
    
    # Перевірка джерельної папки
    if (-not (Test-Path $SourcePath)) {
        Write-Log "ДЖЕРЕЛЬНА ПАПКА НЕ ЗНАЙДЕНА: $SourcePath" -Level "ERROR"
        return $false
    }
    
    # Унікальний ідентифікатор сесії
    $sessionId = Get-Date -Format "yyyyMMdd_HHmmss"
    $logType = if ($SyncType -eq "NETWORK") { "network" } else { "local" }
    $tempLog = "$env:TEMP\robocopy_${logType}_temp_$sessionId.log"
    
    try {
        # === ПІДГОТОВКА ===
        Write-Log "Підготовка до синхронізації..." -Level "INFO"
        
        # Нормалізація шляхів
        $SourcePath = $SourcePath.TrimEnd('\')
        $DestinationPath = $DestinationPath.TrimEnd('\')
        
        # Створюємо цільову папку, якщо не існує
        if (-not (Test-Path $DestinationPath)) {
            try {
                New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
                Write-Log "Створено цiльову папку: $DestinationPath" -Level "SUCCESS"
            } catch {
                Write-Log "Не вдалося створити цiльову папку: $($_.Exception.Message)" -Level "ERROR"
                return $false
            }
        }
        
        # === ПАРАМЕТРИ ROBOCOPY ===
        # Базові параметри однакові для обох типів
        $robocopyBaseParams = @(
            "/E",                    # Включаючи підпапки
            "/COPY:DAT",             # Копіювати: Дані, Атрибути, Мітки часу
            "/DCOPY:T",              # Мітки часу для папок
            "/FFT",                  # FAT-час (2 секунди точності)
            "/DST",                  # Компенсація літнього/зимового часу
            "/XO",                   # Тільки новіші файли
            "/XJ",                   # Ігнорувати junction points
            "/Z",                    # Режим перезапуску
            "/TBD",                  # Чекати на мережеві ресурси
            "/NP",                   # Не показувати відсоток виконання
            "/MT:8",                 # 8 потоків
            "/UNICODE",              # Unicode підтримка
            "/V",                    # Детальний вивід
            "/TS",                   # Мітки часу у виводі
            "/FP",                   # Повні шляхи файлів
            "/NDL",                  # Без списку каталогів
            "/NS",                   # Без розмірів файлів
            "/NC",                   # Без класів файлів
            "/LOG:`"$tempLog`""      # Логування у тимчасовий файл
        )
        
        # Додаткові параметри залежно від типу
        $robocopyAdditionalParams = if ($SyncType -eq "NETWORK") {
            @(
                "/R:5",              # 5 спроб для мережі
                "/W:10"              # 10 секунд очікування для мережі
            )
        } else {
            @(
                "/R:3",              # 3 спроб для локальної
                "/W:5"               # 5 секунд очікування для локальної
            )
        }
        
        # Об'єднуємо всі параметри
        $robocopyParams = @("`"$SourcePath`"", "`"$DestinationPath`"") + 
                          $robocopyBaseParams + 
                          $robocopyAdditionalParams
        
        Write-Log "Запуск синхронізації..." -Level "INFO"
        
        $startTime = Get-Date
        
        # Запуск Robocopy
        $process = Start-Process robocopy.exe `
            -ArgumentList $robocopyParams `
            -WindowStyle Hidden `
            -Wait `
            -PassThru `
            -ErrorAction Stop
        
        $endTime = Get-Date
        $exitCode = $process.ExitCode
        $duration = $endTime - $startTime
        
        # === ПОКРАЩЕНИЙ АНАЛІЗ РЕЗУЛЬТАТІВ ===
        Write-Log "Robocopy завершено. Код: $exitCode, Час: $([math]::Round($duration.TotalSeconds, 1)) сек" -Level "INFO"
        
        # Розшифровка коду виходу
        $exitCodeInfo = @{
            0 = "УСПІХ - без змін"
            1 = "УСПІХ - деякі файли не оброблені (немає змін)"
            2 = "ДОДАТКОВІ ФАЙЛИ"
            4 = "НЕВІДПОВІДНІ ПАПКИ"
            8 = "ПОМИЛКИ КОПІЮВАННЯ"
            16 = "ПОМИЛКИ СЕРВЕРА"
        }
        
        if ($exitCodeInfo.ContainsKey($exitCode)) {
            $exitMessage = $exitCodeInfo[$exitCode]
        } else {
            $exitMessage = "Невідомий код ($exitCode)"
        }
        Write-Log "Результат: $exitMessage" -Level "INFO"
        
        $hasChanges = $false
        $hasErrors = $false
        $copiedFiles = @()
        $errorLines = @()
        $copiedCount = 0
        $skippedCount = 0
        $mismatchCount = 0
        $failedCount = 0
        
        if (Test-Path $tempLog -PathType Leaf) {
            $logContent = Get-Content $tempLog
            
            # Детальний аналіз логу
            foreach ($line in $logContent) {
                # Файли, які були скопійовані
                if ($line -match '(изменен|новая|newer|changed)\s+(\d+)') {
                    $hasChanges = $true
                    $fileCount = [int]$matches[2]
                    $copiedCount += $fileCount
                    
                    if ($line -match '\\[^\\]+$') {
                        $copiedFiles += $matches[0].Trim('\')
                    }
                }
                
                # Пропущені файли
                if ($line -match '(пропущен|skipped|extra)\s+(\d+)') {
                    $skippedCount += [int]$matches[2]
                }
                
                # Невідповідності
                if ($line -match '(mismatch|несоответств)\s+(\d+)') {
                    $mismatchCount += [int]$matches[2]
                }
                
                # Помилки
                if ($line -match 'ERROR|СБОЙ|FAILED|ошибка') {
                    $hasErrors = $true
                    $errorLines += $line
                }
                
                # Підсумкова статистика
                if ($line -match 'Файлов\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
                    $totalFiles = [int]$matches[1]
                    $copied = [int]$matches[2]
                    $skipped = [int]$matches[3]
                    $failed = [int]$matches[4]
                    
                    if ($copied -gt 0) {
                        $hasChanges = $true
                        $copiedCount = $copied
                    }
                    $failedCount = $failed
                }
            }
        }
        
        # Перевірка на критичні помилки (код >= 8)
        if ($exitCode -ge 8) {
            $hasErrors = $true
        }
        
        # === ЗБЕРЕЖЕННЯ ЛОГУ ===
        $needSaveLog = $LogAlways -or $hasChanges -or $hasErrors -or ($exitCode -gt 0)
        
        # Шлях для лог-файлів
        $logBasePath = Join-Path $logPath "SYNC_LOGS"
        if (-not (Test-Path $logBasePath)) {
            New-Item -Path $logBasePath -ItemType Directory -Force | Out-Null
        }
        
        if ($needSaveLog) {
            # Формування імені лог -файлу
            $logTypeName = if ($hasErrors) { "ERROR" } 
                          elseif ($hasChanges) { "CHANGES" } 
                          elseif ($exitCode -eq 0) { "NOCHANGES" }
                          else { "INFO" }
            
            $logFileName = "robocopy_${SyncType}_${logTypeName}_${sessionId}.log"
            $finalLogPath = Join-Path $logBasePath $logFileName
            
            # Запис логу
            if (Test-Path $tempLog) {
                Copy-Item $tempLog $finalLogPath -Force
                Write-Log "Лог синхронізації збережено: $finalLogPath" -Level "INFO" -LogOnly
            }
        }
        
        # Видалення тимчасового логу
        if (Test-Path $tempLog) {
            Remove-Item $tempLog -Force -ErrorAction SilentlyContinue
        }
        
        # === ПОВЕРНЕННЯ РЕЗУЛЬТАТУ ===
        # Коди 0-7 вважаються успішними для Robocopy
        return ($exitCode -le 7)
    }
    catch {
        # Обробка критичних помилок
        $errorMsg = $_.Exception.Message
        
        Write-Log "КРИТИЧНА ПОМИЛКА СИНХРОНІЗАЦІЇ ($SyncType): $errorMsg" -Level "ERROR"
        
        # Очищення
        if (Test-Path $tempLog) {
            Remove-Item $tempLog -Force -ErrorAction SilentlyContinue
        }
        
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
        $staleHashPath = "$fullArchivePath.sha512"
        if (Test-Path -LiteralPath $staleHashPath -PathType Leaf) {
            Remove-Item -LiteralPath $staleHashPath -Force -ErrorAction Stop
            Write-Log "Видалено попереднiй hash-файл перед повторним створенням архiву: $staleHashPath" -Level "WARNING"
        }

        $arguments = "$ArcParams `"$fullArchivePath`" `"$SourcePath`""
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $ArcPath
        $processInfo.Arguments = $arguments
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $creationTimeout = if ($null -ne $archiveCreationTimeoutSeconds) {
            [math]::Max(1, [int]$archiveCreationTimeoutSeconds)
        } else {
            43200
        }
        $completed = $process.WaitForExit(
            [int][math]::Min([int]::MaxValue, [double]$creationTimeout * 1000)
        )
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {
                Write-Log "Не вдалося завершити 7-Zip після таймауту: $($_.Exception.Message)" -Level "WARNING"
            }
            if (-not $process.HasExited) {
                throw "7-Zip не завершився після таймауту створення архіву"
            }
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture

        if (-not $completed) {
            Write-Log "Створення архіву перевищило таймаут $creationTimeout сек.: $fullArchivePath" -Level "ERROR"
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Архiв створено; виконується контроль цiлiсностi: $fullArchivePath" -Level "INFO"
            $testTimeout = if ($null -ne $archiveIntegrityTestTimeoutSeconds) {
                [math]::Max(0, [int]$archiveIntegrityTestTimeoutSeconds)
            } else {
                43200
            }
            if (Test-SevenZipArchiveIntegrity `
                -SevenZipPath $ArcPath `
                -ArchivePath $fullArchivePath `
                -Password $script:vetArchivePassword `
                -TimeoutSeconds $testTimeout) {
                Write-Log "Архiв створено та перевiрено: $fullArchivePath" -Level "SUCCESS"
                return $true
            }
            Write-Log "Пошкоджений або неперевiрений архiв залишено для дiагностики; hash i передача не виконуватимуться: $fullArchivePath" -Level "ERROR"
            return $false
        } else {
            $errorOutput = $capturedOutput.StandardError
            $exitDescription = Get-BRAVOSevenZipExitCodeDescription -ExitCode $process.ExitCode
            Write-Log "Помилка архiвацiї 7-Zip (код: $($process.ExitCode) — $exitDescription): $fullArchivePath" -Level "ERROR"
            $diagnosticLines = @(
                @($capturedOutput.StandardError, $capturedOutput.StandardOutput) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    ForEach-Object { [string]$_ -split '\r?\n' } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Last 20
            )
            if ($diagnosticLines.Count -gt 0) {
                Write-Log "Дiагностика 7-Zip: $($diagnosticLines -join [Environment]::NewLine)" -Level "DEBUG"
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
    
    Write-Log "Створення SHA512 хешу: $(Split-Path $FilePath -Leaf)"
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Файл не знайдено: $FilePath" -Level "ERROR"
        return $false
    }
    
    try {
        # Використовуємо стандартний метод
        $hash = (Get-BRAVOFileHash -Path $FilePath -Algorithm SHA512).Hash.ToLower()
        $fileName = (Get-Item $FilePath).Name
        
        # Записуємо хеш-файл
        [System.IO.File]::WriteAllText($HashFilePath, "${hash} *${fileName}", [System.Text.Encoding]::UTF8)
        
        Write-Log "Хеш створено: $HashFilePath" -Level "SUCCESS"
        return $true
    } catch {
        Write-Log "Помилка створення хешу: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# =============================================
# ФУНКЦІЇ МЕРЕЖІ ТА SFTP
# =============================================

function Test-SFTPConfig {
    if ([string]::IsNullOrEmpty($Login) -or [string]::IsNullOrEmpty($Password)) {
        Write-Log "SFTP логiн або пароль не встановленi" -Level "ERROR"
        return $false
    }
    
    Write-Log "SFTP конфiгурацiя перевiрена успiшно" -Level "SUCCESS"
    return $true
}

function Test-NetworkConnection {
    try {
        Write-Log "Перевiрка мережевого з'єднання..." -Level "DEBUG" -LogOnly
        
        $connection = Test-BRAVOTcpConnection `
            -ComputerName "google.com" `
            -Port 443 `
            -TimeoutMilliseconds 5000
        
        if ($connection) {
            Write-Log "Мережеве з'єднання доступне" -Level "SUCCESS" -LogOnly
            return $true
        } else {
            Write-Log "Мережеве з'єднання недоступне" -Level "ERROR" -LogOnly
            return $false
        }
    } catch {
        Write-Log "Помилка перевiрки мережевого з'єднання: $($_.Exception.Message)" -Level "ERROR" -LogOnly
        return $false
    }
}

function Test-SFTPConnection {
    param(
        [string]$WinSCPPath,
        [string]$RepositorySFTPUrl,
        [string]$HostKey
    )
    
    Write-Log "Перевiрка пiдключення до SFTP сервера: $sftpHostName`:$sftpPort" -Level "DEBUG" -LogOnly
    
    if (-not (Test-Path $WinSCPPath)) {
        Write-Log "WinSCP не знайдено: $WinSCPPath" -Level "ERROR" -LogOnly
        return $false
    }
    
    $testCommand = @"
option batch abort
option confirm off
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=30
ls
exit
"@
    
    $tempScript = [System.IO.Path]::GetTempFileName() + ".txt"
    try {
        $testCommand | Out-File -FilePath $tempScript -Encoding ASCII -Force
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=nul /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $completed = $process.WaitForExit(60000)
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {}
            throw "перевищено таймаут перевірки SFTP-з'єднання (60 сек.)"
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Пiдключення до SFTP сервера успiшне" -Level "SUCCESS" -LogOnly
            return $true
        } else {
            Write-Log "Помилка пiдключення до SFTP сервера (код: $($process.ExitCode))" -Level "ERROR" -LogOnly
            return $false
        }

    } finally {
        if (Test-Path $tempScript) {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
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
open $RepositorySFTPUrl -hostkey=$HostKey -timeout=30
cd /$RemoteDirectory
put "$LocalFilePath"
exit
"@
    
    $tempScript = [System.IO.Path]::GetTempFileName() + ".txt"
    try {
        $winscpCommand | Out-File -FilePath $tempScript -Encoding ASCII -Force
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $WinSCPPath
        $processInfo.Arguments = "/ini=nul /script=`"$tempScript`""
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $outputCapture = Start-BRAVOProcessOutputCapture -Process $process
        $operationTimeout = if ($null -ne $sftpOperationTimeoutSeconds) {
            [math]::Max(1, [int]$sftpOperationTimeoutSeconds)
        } else {
            1800
        }
        $completed = $process.WaitForExit(
            [int][math]::Min([int]::MaxValue, [double]$operationTimeout * 1000)
        )
        if (-not $completed) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            } catch {}
            if (-not $process.HasExited) {
                throw "WinSCP не завершився після таймауту передачі"
            }
        }
        $capturedOutput = Complete-BRAVOProcessOutputCapture -Capture $outputCapture
        $output = $capturedOutput.StandardOutput
        $errorOutput = $capturedOutput.StandardError

        if (-not $completed) {
            Write-Log "Передача WinSCP перевищила таймаут $operationTimeout сек.: $(Split-Path $LocalFilePath -Leaf)" -Level "ERROR"
            return $false
        }
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Файл успiшно завантажено: $(Split-Path $LocalFilePath -Leaf)" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Помилка завантаження (код: $($process.ExitCode)): $(Split-Path $LocalFilePath -Leaf)" -Level "ERROR"
            return $false
        }
    } catch {
        Write-Log "Помилка пiд час завантаження через WinSCP: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        # Очищаємо тимчасовий файл
        if (Test-Path $tempScript) {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
    }
}

# =============================================
# ФУНКЦІЇ ДЛЯ РОБОТИ З МЕРЕЖЕВОЮ ПАПКОЮ
# =============================================

function Connect-NetworkDrive {
    Write-Log "Пiдключення мережевого диска..." -Level "INFO"
    
    $driveName = $script:vetNetworkDriveName
    $driveLetter = "${driveName}:"
    $script:vetNetworkDriveCreated = $false
    $networkPath = $networkCopyConfig.NetworkPath.TrimEnd('\')
    $username = $networkCopyConfig.Username
    $password = $networkCopyConfig.Password
    
    # Перевіряємо, чи не підключений вже диск
    try {
        $existingDrive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        if ($existingDrive) {
            Write-Log "Тимчасовий диск $driveLetter уже існує у поточному процесі" -Level "INFO"
            
            # Перевіряємо, чи працює диск
            if (Test-Path $driveLetter) {
                Write-Log "Диск $driveLetter працює нормально" -Level "SUCCESS"
                return $true
            } else {
                Write-Log "Диск $driveLetter не працює, намагаємося вiдключити..." -Level "WARNING"
                Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
    } catch {
        Write-Log "Помилка перевiрки диска: $($_.Exception.Message)" -Level "WARNING" -LogOnly
    }
    
    # Пароль передається через PSCredential і не потрапляє у командний рядок.
    $securePassword = $null
    try {
        $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential(
            $username,
            $securePassword
        )
        New-PSDrive `
            -Name $driveName `
            -PSProvider FileSystem `
            -Root $networkPath `
            -Credential $credential `
            -Scope Global `
            -ErrorAction Stop |
            Out-Null
        $script:vetNetworkDriveCreated = $true

        # Даємо системі час на ініціалізацію диска
        Start-Sleep -Seconds 3
        
        # Перевіряємо доступ
        if (Test-Path $driveLetter) {
            Write-Log "Мережевий диск пiдключено успiшно" -Level "SUCCESS"
            
            # Отримуємо інформацію про диск
            try {
                $driveInfo = Get-PSDrive -Name $driveName -ErrorAction Stop
                $freeSpaceGB = [math]::Round($driveInfo.Free / 1GB, 2)
                Write-Log "Доступний вiльний простiр: $freeSpaceGB GB" -Level "INFO"
                
                # Перевірка достатності місця
                if ($freeSpaceGB -gt 10) {
                    Write-Log "Вiльного простору достатньо." -Level "SUCCESS"
                } else {
                    Write-Log "Увага! Мало вiльного мiсця: $freeSpaceGB GB" -Level "WARNING"
                }
            } catch {
                Write-Log "Не вдалося отримати iнформацiю про диск" -Level "WARNING" -LogOnly
            }
            
            return $true
        } else {
            Write-Log "Диск пiдключено, але доступ вiдсутнiй" -Level "ERROR"
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
            $script:vetNetworkDriveCreated = $false
            return $false
        }
    } catch {
        Write-Log "Помилка пiдключення мережевого диска: $($_.Exception.Message)" -Level "ERROR"
        return $false
    } finally {
        if ($securePassword) {
            $securePassword.Dispose()
        }
    }
}

function Disconnect-NetworkDrive {
    $driveLetter = "$($script:vetNetworkDriveName):"
    
    Write-Log "Вiдключення мережевого диска $driveLetter..." -Level "DEBUG" -LogOnly
    
    if (-not $script:vetNetworkDriveCreated) {
        Write-Log "Існуючий до запуску диск $driveLetter не відключається" -Level "DEBUG" -LogOnly
        return $true
    }

    try {
        Remove-PSDrive -Name $script:vetNetworkDriveName -Force -ErrorAction Stop
        $script:vetNetworkDriveCreated = $false
        Write-Log "Мережевий диск вiдключено" -Level "SUCCESS" -LogOnly
        return $true
    } catch {
        Write-Log "Помилка вiдключення мережевого диска: $($_.Exception.Message)" -Level "WARNING" -LogOnly
        return $false
    }
}

function Copy-ToNetworkDrive {
    param(
        [string]$SourcePath,
        [string]$DestinationFolder
    )
    
    $fileName = Split-Path $SourcePath -Leaf
    $driveLetter = "$($script:vetNetworkDriveName):"
    $networkPath = "$driveLetter\$DestinationFolder"
    
    Write-Log "Копiювання до мережевого диска: $fileName -> $networkPath"
        
    # Перевіряємо, чи диск підключено
    if (-not (Test-Path $driveLetter)) {
        Write-Log "Мережевий диск $driveLetter не пiдключено" -Level "ERROR"
        return $false
    }
    
    # Створюємо цільовий каталог, якщо не існує
    if (-not (Test-Path $networkPath)) {
        try {
            New-Item -ItemType Directory -Path $networkPath -Force | Out-Null
            Write-Log "Створено каталог: $networkPath" -Level "SUCCESS"
        } catch {
            Write-Log "Помилка створення каталогу: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }
    
    $destFile = Join-Path $networkPath $fileName
    
    try {
        # Копіюємо файл
        Copy-Item -Path $SourcePath -Destination $destFile -Force -ErrorAction Stop
        
        # Перевіряємо успішність
        if (Test-Path $destFile) {
            $fileSize = (Get-Item $destFile).Length / 1MB
            Write-Log "Файл успiшно скопiйовано: $fileName ($([math]::Round($fileSize, 2)) MB)" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Файл не знайдено пiсля копiювання" -Level "ERROR"
            return $false
        }
        
    } catch {
        Write-Log "Помилка копiювання: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Process-NetworkCopy {
    param(
        [hashtable]$Results
    )
    
    if (-not $enableNetworkCopy) {
        Write-Log "Копiювання в мережеву папку вимкнено в налаштуваннях" -Level "INFO"
        return
    }
    
    Write-Log "=== КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ ==="
    Write-Log "--- ПIДКЛЮЧЕННЯ МЕРЕЖЕВОГО ДИСКА ---"
    
    # Підключаємо мережевий диск
    $connected = Connect-NetworkDrive
    
    if (-not $connected) {
        Write-Log "Не вдалося пiдключити мережевий диск - пропускаємо копiювання" -Level "ERROR"
        return
    }
    
    $copySuccess = 0
    $copyTotal = 0
    
    # Копіюємо архіви та хеш-файли
    foreach ($archiveType in $Results.Keys) {
        if ($Results[$archiveType].ArchiveSuccess -and $Results[$archiveType].HashSuccess) {
            $copyTotal += 2
            
            # Визначаємо папку призначення
            $targetFolder = if ($archiveType -eq "BLOG") { "BLOG" } else { "Model" }
            
            # Копіюємо архів
            Write-Log "--- КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ АРХІВУ $archiveType ---"
            $archiveCopy = Copy-ToNetworkDrive -SourcePath $Results[$archiveType].ArchivePath -DestinationFolder $targetFolder
            if ($archiveCopy) { $copySuccess++ }
            
            # Копіюємо хеш-файл
            Write-Log "--- КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ ХЕШУ АРХІВУ $archiveType ---"
            $hashCopy = Copy-ToNetworkDrive -SourcePath $Results[$archiveType].HashPath -DestinationFolder $targetFolder
            if ($hashCopy) { $copySuccess++ }
            
            if ($archiveCopy -and $hashCopy) {
                Write-Log "Успiшно скопiйовано $archiveType в мережеву папку" -Level "SUCCESS" -LogOnly
            }
        }
    }
    
    Write-Log "=== ПІДСУМОК КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ ==="
    
    if ($copyTotal -gt 0) {
        $percentage = [math]::Round(($copySuccess / $copyTotal) * 100, 1)
        Write-Log "Скопiйовано $copySuccess з $copyTotal файлiв ($percentage%) в мережеву папку" -Level "SUCCESS"
    } else {
        Write-Log "Немає файлiв для копiювання в мережеву папку" -Level "WARNING"
    }
    
    # Відключаємо диск
    Disconnect-NetworkDrive | Out-Null
}

# =============================================
# ОСНОВНА ЛОГІКА
# =============================================

function Main {
    $uploadSuccess = 0
    $uploadTotal = 0
    $copySuccess = 0
    $copyTotal = 0
    $sftpCompleted = -not $enableSFTPUpload
    $networkCopyCompleted = -not $enableNetworkCopy
    $syncLocalSuccess = $excludeComponents.BAZA
    $syncNetworkSuccess = $excludeComponents.BAZA_Network -or -not $enableNetworkCopy

    # Ініціалізація
    $scriptStartTime = Get-Date
    $now = Get-Date -Format "yyyyMMdd_HHmm"
    $global:logFile = "$logPath\ARCHIV_VETOFFICE_$now.log"
    
    Write-Log "==="
    Write-Log "=== ПОЧАТОК РОБОТИ СКРИПТА ARCHIV_VETOFFICE v.$ScriptVersion ==="
    Write-Log "Файл конфiгурацiї: $configPath" -Level "INFO"
    Write-Log "==="
    
    Write-Log "=== ОПЦIЇ СКРИПТА ==="
    Write-Log "Версiя та дата скрипта: $ScriptVersion вiд $ScriptDate" -NoTimestamp
    Write-Log "Час початку: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -NoTimestamp
    Write-Log "Кореневий каталог: $rootPath" -NoTimestamp
    Write-Log "Режим логування: $LogLevel" -NoTimestamp
    if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
        Write-Log $BRAVOPowerShellUpdate.Message -Level "WARNING"
    }
    Write-Log "Копiювання в мережу: $(if ($enableNetworkCopy) {'УВIМКНЕНО'} else {'ВИМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA в мережу: $(if ($excludeComponents.BAZA_Network) {'ВИМКНЕНО'} else {'УВIМКНЕНО'})" -NoTimestamp
    Write-Log "Синхронiзацiя BAZA локальна: $(if ($excludeComponents.BAZA) {'ВИМКНЕНО'} else {'УВIМКНЕНО'})" -NoTimestamp
    Write-Log "==="
    
    # ОЧИЩЕННЯ СТАРИХ ЛОГІВ - виконується в кінці
    
    # Перевірка шляхів
    Write-Log "=== ПЕРЕВIРКА НЕОБХIДНИХ ШЛЯХIВ ==="

    $archiveRequired = -not $excludeComponents.Blog -or -not $excludeComponents.VETOFFICE
    if ($archiveRequired -and
        -not [string]::IsNullOrWhiteSpace($script:vetArchiveCredentialError)) {
        Write-Log "Пароль архівів недоступний: $($script:vetArchiveCredentialError)" -Level "ERROR"
        $script:processExitCode = 1
    }
    if ($enableSFTPUpload -and
        -not [string]::IsNullOrWhiteSpace($script:vetSFTPCredentialError)) {
        Write-Log "Облікові дані SFTP недоступні: $($script:vetSFTPCredentialError)" -Level "ERROR"
        $script:processExitCode = 1
    }
    if ($enableNetworkCopy -and
        -not [string]::IsNullOrWhiteSpace($script:vetSMBCredentialError)) {
        Write-Log "Облікові дані SMB недоступні: $($script:vetSMBCredentialError)" -Level "ERROR"
        $script:processExitCode = 1
    }

    $requiredPaths = @(
        @{Path=$logPath; Description="Каталог логiв"}
    )
    if ($archiveRequired) {
        $requiredPaths += @{Path=$arcPath; Description="7-Zip"}
    }
    if ($enableSFTPUpload) {
        $requiredPaths += @{Path=$winSCPPath; Description="WinSCP"}
    }
    if (-not $excludeComponents.BAZA -or
        (-not $excludeComponents.BAZA_Network -and $enableNetworkCopy)) {
        $requiredPaths += @{Path=$bazaPaths.Source; Description="Каталог BAZA"}
    }
    if (-not $excludeComponents.BAZA) {
        $requiredPaths += @{
            Path=$bazaPaths.Destination_Local
            Description="Локальний каталог архiву BAZA"
        }
    }
    
    # Додаємо шляхи тільки для невимкнених компонентів
    if (-not $excludeComponents.Blog) {
        $requiredPaths += @{Path=(Split-Path $sourcePaths.Blog -Parent); Description="Каталог BLOG"}
        $requiredPaths += @{Path=$archiveDirs.Blog; Description="Каталог архiву BLOG"}
    }
    
    if (-not $excludeComponents.VETOFFICE) {
        $requiredPaths += @{Path=(Split-Path $sourcePaths.Model -Parent); Description="Каталог VETOFFICE"}
        $requiredPaths += @{Path=$archiveDirs.Model; Description="Каталог архiву VETOFFICE"}
    }
    
    $allPathsExist = $true
    foreach ($item in $requiredPaths) {
        if (-not (Test-PathWithLog $item.Path $item.Description)) {
            $allPathsExist = $false
        }
    }

    # Показуємо підсумок перевірки шляхів
    Show-PathCheckSummary -CheckedPaths $requiredPaths -AllPathsExist $allPathsExist

    if (-not $allPathsExist) {
        Write-Log "Критична помилка: не знайдено обов'язковi шляхи" -Level "ERROR"
        $script:processExitCode = 1
        return
    }
    
    # Створення архівів (тільки для невимкнених компонентів)
    $archives = @()
    
    if (-not $excludeComponents.VETOFFICE) {
        $archives += @{
            Name = "$($archivePrefix)_$now.mdz"
            Source = $sourcePaths.Model
            Destination = $archiveDirs.Model
            Type = "VETOFFICE"
        }
    }
    
    if (-not $excludeComponents.Blog) {
        $archives += @{
            Name = "$($archivePrefix)_blog_$now.mdz"
            Source = $sourcePaths.Blog
            Destination = $archiveDirs.Blog
            Type = "BLOG"
        }
    }
    
    $results = @{}
    
    Write-Log "=== АРХIВАЦIЯ ТА СТВОРЕННЯ ХЕШУ ==="
    
    foreach ($archive in $archives) {
        Write-Log "--- АРХIВАЦIЯ $($archive.Type) ---"
        if (-not [string]::IsNullOrWhiteSpace($script:vetArchiveCredentialError)) {
            Write-Log "Архівацію $($archive.Type) пропущено: пароль 7-Zip недоступний" -Level "ERROR"
            $results[$archive.Type] = @{
                ArchiveSuccess = $false
                HashSuccess = $false
            }
            continue
        }
        $success = New-Archive -SourcePath $archive.Source -ArchivePath $archive.Destination -ArchiveName $archive.Name -ArcPath $arcPath -ArcParams $archiveParams
        
        if ($success) {
            Write-Log "--- СТВОРЕННЯ ХЕШУ $($archive.Type) ---"
            $archivePath = Join-Path $archive.Destination $archive.Name
            $hashPath = "$archivePath.sha512"
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
    
    Write-Log "==="
    
    # Завантаження на SFTP
    if ($enableSFTPUpload) {
        Write-Log "=== ЗАВАНТАЖЕННЯ НА SFTP ==="
        Write-Log "--- ПЕРЕВІРКА КОНФІГУРАЦІЇ SFTP ---"
        
        # Перевірка конфігурації SFTP
        if (-not [string]::IsNullOrWhiteSpace($script:vetSFTPCredentialError)) {
            Write-Log "SFTP пропущено: $($script:vetSFTPCredentialError)" -Level "ERROR"
        } elseif (-not (Test-SFTPConfig)) {
            Write-Log "SFTP конфiгурацiя невiрна - пропускаємо завантаження" -Level "ERROR"
        } elseif (-not (Test-NetworkConnection)) {
            Write-Log "Мережеве з'єднання недоступне - пропускаємо завантаження" -Level "ERROR"
        } elseif (-not (Test-SFTPConnection -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey)) {
            Write-Log "Помилка пiдключення до SFTP - пропускаємо завантаження" -Level "ERROR"
        } else {
            # Завантаження VETOFFICE
            if ($results.ContainsKey("VETOFFICE") -and $results["VETOFFICE"].ArchiveSuccess -and $results["VETOFFICE"].HashSuccess) {
                $uploadTotal += 2
                
                Write-Log "--- ЗАВАНТАЖЕННЯ АРХІВУ VETOFFICE НА SFTP ---"
                $archiveUpload = Send-FileViaWinSCP -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey -LocalFilePath $results["VETOFFICE"].ArchivePath -RemoteDirectory $sftpDirectories["Model"]
                if ($archiveUpload) { $uploadSuccess++ }
                
                Write-Log "--- ЗАВАНТАЖЕННЯ ХЕШУ АРХІВУ VETOFFICE НА SFTP ---"
                $hashUpload = Send-FileViaWinSCP -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey -LocalFilePath $results["VETOFFICE"].HashPath -RemoteDirectory $sftpDirectories["Model"]
                if ($hashUpload) { $uploadSuccess++ }
            }
            
            # Завантаження BLOG
            if ($results.ContainsKey("BLOG") -and $results["BLOG"].ArchiveSuccess -and $results["BLOG"].HashSuccess) {
                $uploadTotal += 2
                
                Write-Log "--- ЗАВАНТАЖЕННЯ АРХІВУ BLOG НА SFTP ---"
                $archiveUpload = Send-FileViaWinSCP -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey -LocalFilePath $results["BLOG"].ArchivePath -RemoteDirectory $sftpDirectories["BLOG"]
                if ($archiveUpload) { $uploadSuccess++ }
                
                Write-Log "--- ЗАВАНТАЖЕННЯ ХЕШУ АРХІВУ BLOG НА SFTP ---"
                $hashUpload = Send-FileViaWinSCP -WinSCPPath $winSCPPath -RepositorySFTPUrl $sftpUrl -HostKey $sftpHostKey -LocalFilePath $results["BLOG"].HashPath -RemoteDirectory $sftpDirectories["BLOG"]
                if ($hashUpload) { $uploadSuccess++ }
            }
            
            Write-Log "--- ПІДСУМОК ЗАВАНТАЖЕННЯ НА SFTP ---"
            if ($uploadTotal -gt 0) {
                $sftpCompleted = $uploadSuccess -eq $uploadTotal
                $uploadLevel = if ($sftpCompleted) { "SUCCESS" } else { "ERROR" }
                Write-Log "Завантажено $uploadSuccess з $uploadTotal файлiв на SFTP" -Level $uploadLevel
            } else {
                Write-Log "Немає файлiв для завантаження на SFTP" -Level "WARNING"
            }
        }
        Write-Log "==="
    } else {
        Write-Log "=== ЗАВАНТАЖЕННЯ НА SFTP ===" -LogOnly
        Write-Log "Завантаження на SFTP вимкнено в налаштуваннях" -Level "INFO" -LogOnly
        Write-Log "===" -LogOnly
    }
    
    # Завантаження в мережеву папку (Samba)
    if ($enableNetworkCopy) {
        Write-Log "=== КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ ==="
        Write-Log "--- ПIДКЛЮЧЕННЯ МЕРЕЖЕВОГО ДИСКА ---"
        
        # Підключаємо мережевий диск
        $connected = if ([string]::IsNullOrWhiteSpace($script:vetSMBCredentialError)) {
            Connect-NetworkDrive
        } else {
            Write-Log "SMB пропущено: $($script:vetSMBCredentialError)" -Level "ERROR"
            $false
        }
        
        if (-not $connected) {
            Write-Log "Не вдалося пiдключити мережевий диск - пропускаємо копiювання" -Level "ERROR"
        } else {
            # Копіювання VETOFFICE
            if ($results.ContainsKey("VETOFFICE") -and $results["VETOFFICE"].ArchiveSuccess -and $results["VETOFFICE"].HashSuccess) {
                $copyTotal += 2
                
                Write-Log "--- КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ АРХІВУ VETOFFICE ---"
                $archiveCopy = Copy-ToNetworkDrive -SourcePath $results["VETOFFICE"].ArchivePath -DestinationFolder "Model"
                if ($archiveCopy) { $copySuccess++ }
                
                Write-Log "--- КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ ХЕШУ АРХІВУ VETOFFICE ---"
                $hashCopy = Copy-ToNetworkDrive -SourcePath $results["VETOFFICE"].HashPath -DestinationFolder "Model"
                if ($hashCopy) { $copySuccess++ }
            }
            
            # Копіювання BLOG
            if ($results.ContainsKey("BLOG") -and $results["BLOG"].ArchiveSuccess -and $results["BLOG"].HashSuccess) {
                $copyTotal += 2
                
                Write-Log "--- КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ АРХІВУ BLOG ---"
                $archiveCopy = Copy-ToNetworkDrive -SourcePath $results["BLOG"].ArchivePath -DestinationFolder "BLOG"
                if ($archiveCopy) { $copySuccess++ }
                
                Write-Log "--- КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ ХЕШУ АРХІВУ BLOG ---"
                $hashCopy = Copy-ToNetworkDrive -SourcePath $results["BLOG"].HashPath -DestinationFolder "BLOG"
                if ($hashCopy) { $copySuccess++ }
            }
            
            Write-Log "=== ПІДСУМОК КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ ==="
            
            if ($copyTotal -gt 0) {
                $percentage = [math]::Round(($copySuccess / $copyTotal) * 100, 1)
                $networkCopyCompleted = $copySuccess -eq $copyTotal
                $copyLevel = if ($networkCopyCompleted) { "SUCCESS" } else { "ERROR" }
                Write-Log "Скопiйовано $copySuccess з $copyTotal файлiв ($percentage%) в мережеву папку" -Level $copyLevel
            } else {
                Write-Log "Немає файлiв для копiювання в мережеву папку" -Level "WARNING"
            }
            
            # Відключаємо диск
            Disconnect-NetworkDrive | Out-Null
        }
        Write-Log "==="
    } else {
        Write-Log "=== КОПIЮВАННЯ В МЕРЕЖЕВУ ПАПКУ ===" -LogOnly
        Write-Log "Копiювання в мережеву папку вимкнено в налаштуваннях" -Level "INFO" -LogOnly
        Write-Log "===" -LogOnly
    }
    
    Write-Log "=== СИНХРОНІЗАЦІЯ ФАЙЛІВ BAZA ==="
    
    # Синхронізація BAZA (тільки якщо не вимкнена)
    if (-not $excludeComponents.BAZA) {
        # ЛОКАЛЬНА синхронізація BAZA
        $syncLocalSuccess = Sync-Folders -SourcePath $bazaPaths.Source -DestinationPath $bazaPaths.Destination_Local -SyncType "LOCAL"

        if ($syncLocalSuccess) {
            Write-Log "Локальна синхронiзацiя BAZA успiшна" -Level "SUCCESS"
        } else {
            Write-Log "Помилка локальної синхронiзацiї BAZA" -Level "WARNING"
        }
    } else {
        Write-Log "Локальна синхронiзацiя BAZA вимкнена в налаштуваннях" -Level "INFO"
    }
    
    # МЕРЕЖЕВА синхронізація BAZA
    if (-not $excludeComponents.BAZA_Network -and $enableNetworkCopy) {
        $syncNetworkSuccess = Sync-Folders -SourcePath $bazaPaths.Source -DestinationPath $bazaPaths.Destination_Network -SyncType "NETWORK"

        if ($syncNetworkSuccess) {
            Write-Log "Мережева синхронiзацiя BAZA успiшна" -Level "SUCCESS"
        } else {
            Write-Log "Помилка мережевої синхронiзацiї BAZA" -Level "WARNING"
        }
    } elseif ($excludeComponents.BAZA_Network) {
        Write-Log "Мережева синхронiзацiя BAZA вимкнена в налаштуваннях" -Level "INFO"
    } elseif (-not $enableNetworkCopy) {
        Write-Log "Мережева синхронiзацiя BAZA вимкнена (копiювання в мережу вимкнено)" -Level "INFO"
    }
    
    Write-Log "==="
    
    # Очищення старих архівів
    if ($enableArchiveDeletion) {
        Write-Log "=== ОЧИЩЕННЯ СТАРИХ АРХIВIВ ==="
        foreach ($archiveType in $archiveDirs.Keys) {
            # Пропускаємо вимкнені компоненти
            $componentEnabled = $true
            switch ($archiveType) {
                "Model" { $componentEnabled = -not $excludeComponents.VETOFFICE }
                "Blog" { $componentEnabled = -not $excludeComponents.Blog }
            }
            
            if ($componentEnabled) {
                if (-not (Remove-OldBackupSets -Path $archiveDirs[$archiveType] -KeepCount $archiveVersions -Component $archiveType)) {
                    $script:processExitCode = 1
                }
            }
        }
        Write-Log "==="
    } else {
        Write-Log "=== ОЧИЩЕННЯ СТАРИХ АРХIВIВ ===" -LogOnly
        Write-Log "Видалення старих архiвiв вимкнено в налаштуваннях" -Level "INFO" -LogOnly
        Write-Log "===" -LogOnly
    }
    
    Write-Log "=== ОЧИЩЕННЯ СТАРИХ ЛОГIВ ==="
    if (-not (Remove-OldLogsByAge -Path $logPath -Filter "ARCHIV_VETOFFICE_*.log" -RetentionDays $logRetentionDays)) {
        Write-Log "Очищення старих логів завершилося з помилкою" -Level "ERROR"
        $script:processExitCode = 1
    }
    Write-Log "==="
    
    # Завершення
    $scriptEndTime = Get-Date
    $duration = $scriptEndTime - $scriptStartTime
    
    Write-Log "=== ЗАВЕРШЕННЯ РОБОТИ СКРИПТА ==="
    Write-Log "Час початку: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -NoTimestamp
    Write-Log "Час завершення: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))" -NoTimestamp
    Write-Log "Тривалiсть: $($duration.ToString('hh\:mm\:ss'))" -NoTimestamp
    Write-Log "" -NoTimestamp
    
    # Детальний підсумок
    $successArchives = ($results.Values | Where-Object { $_.ArchiveSuccess }).Count
    $successHashes = ($results.Values | Where-Object { $_.HashSuccess }).Count
    $totalArchives = $results.Count
    
    Write-Log "Створено архiвiв: $(if ($successArchives -eq $totalArchives -and $totalArchives -gt 0) {'успішно'} else {'$successArchives з $totalArchives'})" -NoTimestamp
    Write-Log "Створено хешу для архівів: $(if ($successHashes -eq $totalArchives -and $totalArchives -gt 0) {'успішно'} else {'$successHashes з $totalArchives'})" -NoTimestamp
    
    if ($enableSFTPUpload) {
        Write-Log "Завантаження на SFTP: $(if ($sftpCompleted) {'успiшно'} elseif ($uploadTotal -eq 0) {'не виконано'} else {'$uploadSuccess з $uploadTotal'})" -NoTimestamp
    } else {
        Write-Log "Завантаження на SFTP: вимкнено" -NoTimestamp
    }
    
    if ($enableNetworkCopy) {
        Write-Log "Завантаження в мережеву папку: $(if ($networkCopyCompleted) {'успiшно'} elseif ($copyTotal -eq 0) {'не виконано'} else {'$copySuccess з $copyTotal'})" -NoTimestamp
    } else {
        Write-Log "Завантаження в мережеву папку: вимкнено" -NoTimestamp
    }
    
    if (-not $excludeComponents.BAZA) {
        Write-Log "Локальна сихронізація BAZA: $(if ($syncLocalSuccess) {'успiшна'} else {'з помилками'})" -NoTimestamp
    } else {
        Write-Log "Локальна сихронізація BAZA: вимкнено" -NoTimestamp
    }
    
    if (-not $excludeComponents.BAZA_Network -and $enableNetworkCopy) {
        Write-Log "Мережева сихронізація BAZA: $(if ($syncNetworkSuccess) {'успiшна'} else {'з помилками'})" -NoTimestamp
    } else {
        Write-Log "Мережева сихронізація BAZA: вимкнено" -NoTimestamp
    }

    $archiveFailed = (
        $totalArchives -ne $archives.Count -or
        @($results.Values | Where-Object {
            -not $_.ArchiveSuccess -or -not $_.HashSuccess
        }).Count -gt 0
    )
    if ($archiveFailed -or
        -not $sftpCompleted -or
        -not $networkCopyCompleted -or
        -not $syncLocalSuccess -or
        -not $syncNetworkSuccess) {
        $script:processExitCode = 1
    }
    
    Write-Log "" -NoTimestamp
    Write-Log "Лог-файл: $logFile" -NoTimestamp
    Write-Log "==="

    # Пауза тільки при інтерактивному запуску
    $isInteractive = [Environment]::UserInteractive
    if ($isInteractive) {
        Write-Host "`nНатиснiть будь-яку клавiшу для закриття..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# =============================================
# ОБРОБКА ПАРАМЕТРІВ КОМАНДНОГО РЯДКА
# =============================================

function Show-Help {
    Write-Host "`n=== ВИКОРИСТАННЯ СКРИПТА ARCHIV_VETOFFICE ===" -ForegroundColor Yellow
    Write-Host "`nОсновнi параметри:" -ForegroundColor Cyan
    Write-Host "  Без параметрiв           - Запуск архiвацiї" -ForegroundColor White
    Write-Host "  -Schedule                - Додати в Планувальник завдань" -ForegroundColor White
    Write-Host "  -ShowTasks               - Показати завдання в Планувальнику" -ForegroundColor White
    Write-Host "  -RemoveTask              - Видалити завдання з Планувальника" -ForegroundColor White
    Write-Host "  -Help, -?, /?            - Показати цю довiдку" -ForegroundColor White
    
    Write-Host "`nПриклади:" -ForegroundColor Cyan
    Write-Host "  .\ARCHIV_VETOFFICE.ps1                    - Запуск архiвацiї" -ForegroundColor Gray
    Write-Host "  .\ARCHIV_VETOFFICE.ps1 -Schedule         - Додати в Планувальник" -ForegroundColor Gray
    Write-Host "  .\ARCHIV_VETOFFICE.ps1 -ShowTasks        - Перелiк завдань" -ForegroundColor Gray
    Write-Host "  .\ARCHIV_VETOFFICE.ps1 -RemoveTask       - Видалити завдання" -ForegroundColor Gray
    
    Write-Host "`nФайл конфiгурацiї: $configPath" -ForegroundColor Gray
    Write-Host "Версiя скрипта: $ScriptVersion вiд $ScriptDate`n" -ForegroundColor Gray
}

# Обробка параметрів командного рядка
if ($args.Count -gt 0) {
    $param = $args[0].ToLower()
    
    switch ($param) {
        "-schedule" {
            Write-Host "`n=== ДОДАВАННЯ СКРИПТА ДО ПЛАНУВАЛЬНИКА ЗАВДАНЬ ===" -ForegroundColor Yellow
            Write-Host "Скрипт буде додано до Планувальника для автоматичного запуску.`n" -ForegroundColor White
            
            $confirmation = Read-Host "Продовжити? (Y/N)"
            if ($confirmation -eq "Y" -or $confirmation -eq "y") {
                Add-ToTaskScheduler
            } else {
                Write-Host "Скасовано." -ForegroundColor Yellow
            }
            Exit 0
        }
        
        "-showtasks" {
            Show-TaskSchedulerInfo
            Exit 0
        }
        
        "-removetask" {
            Write-Host "`n=== ВИДАЛЕННЯ ЗАВДАНЬ З ПЛАНУВАЛЬНИКА ===" -ForegroundColor Yellow
            Write-Host "Ви можете видалити одне або всi завдання архiвацiї.`n" -ForegroundColor White
            
            $confirmation = Read-Host "Продовжити? (Y/N)"
            if ($confirmation -eq "Y" -or $confirmation -eq "y") {
                Remove-FromTaskScheduler
            } else {
                Write-Host "Скасовано." -ForegroundColor Yellow
            }
            Exit 0
        }
        
        "-help" { Show-Help; Exit 0 }
        "-?" { Show-Help; Exit 0 }
        "/?" { Show-Help; Exit 0 }
        
        default {
            Write-Host "`nНевiдомий параметр: $param" -ForegroundColor Red
            Show-Help
            Exit 1
        }
    }
}

# Запуск головної функції (якщо не було параметрів)
$script:processExitCode = 0
try {
    Main
} catch {
    $script:processExitCode = 1
    Write-Host "КРИТИЧНА ПОМИЛКА: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    $script:vetArchivePassword = $null
    $Login = $null
    $Password = $null
}
exit $script:processExitCode
