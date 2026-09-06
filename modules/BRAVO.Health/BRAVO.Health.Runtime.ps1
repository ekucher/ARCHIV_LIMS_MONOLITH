##########
# BravoSoft
# Read-only health monitoring for BRAVO backups and managed services.
# This file is intentionally the single runtime owner of health functionality.
##########

param(
    [string]$ConfigPath,
    [bool]$ConfigPathWasExplicit = $false,
    [switch]$ForceNotification,
    [switch]$NotifyOnSuccess,
    [switch]$NoSlack,
    [switch]$SkipIfBackupTaskRunning,
    [switch]$NoPause,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$EntryScriptPath
)
function Invoke-BRAVOHealth {
    param(
        [string]$ConfigPath,
        [switch]$ForceNotification,
        [switch]$NotifyOnSuccess,
        [switch]$NoSlack,
        [switch]$SkipIfBackupTaskRunning,
        # Archive викликає Health усередині власного кроку "Перевірка
        # резервних копій" (Invoke-BRAVOHealthCheck, dot-source-шлях) — там
        # заголовок "BRAVO HEALTH X.X.X / Установа / Початок" виглядав як
        # друга незалежна програма всередині виводу Archive. Самостійний
        # запуск (BRAVO_HEALTH.ps1) цей параметр не передає — заголовок там
        # лишається.
        [switch]$SuppressHeader,
        # ONE synchronization, ONE SyncResult (safety-review): якщо Archive
        # щойно виконав BAZA sync, тут — уже готовий результат. Ключі
        # 'BAZA_APP'/'BAZA_WWW'. Самостійний запуск BRAVO_HEALTH.ps1 не
        # передає це — Health сам вирішує, чи потрібна власна синхронізація.
        [hashtable]$BazaSyncResults
    )

# ONE synchronization, ONE SyncResult (safety-review): script-scope, щоб
# Get-SFTPHealthIssues (окрема функція нижче, без власних параметрів —
# той самий стиль, що решта health-check функцій цього файлу) міг його
# прочитати без протягування через кожен виклик у стеку.
$script:bazaSyncResults = $BazaSyncResults

# Нумерація етапів операційної консолі: [1/7], [2/7], ... Health має рівно
# ті самі елементи виводу, що й Archive: заголовок, етапи, підсумок.
$script:BRAVOHealthStepCurrent = 0
$script:BRAVOHealthStepTotal = 0
$script:BRAVOHealthConsoleReady = $false
$script:BRAVOHealthStepOkCount = 0
$script:BRAVOHealthStepWarningCount = 0
$script:BRAVOHealthStepErrorCount = 0
$script:BRAVOHealthLastStepTime = $null
# Перевірка цілісності інструментів виконується значно нижче, але
# Complete-BRAVOHealthResult читає її результат — а через цю функцію
# проходить КОЖЕН вихід Health, зокрема ранні (моніторинг вимкнено,
# некоректний webhook, відкладено через архівацію, непідтримана ОС).
# Під Set-StrictMode 2.0 звернення до неприсвоєної змінної є термінальною
# помилкою, тому без цієї ініціалізації ранні виходи падали: у гілці
# "відкладено" виняток ковтав catch, і Health продовжував роботу під час
# архівації замість того, щоб відкластися.
$script:BRAVOToolManifest = $null

function Initialize-BRAVOHealthSteps {
    param([Parameter(Mandatory = $true)][int]$Total)

    $script:BRAVOHealthStepCurrent = 0
    $script:BRAVOHealthStepTotal = [Math]::Max(1, $Total)
    $script:BRAVOHealthStepOkCount = 0
    $script:BRAVOHealthStepWarningCount = 0
    $script:BRAVOHealthStepErrorCount = 0
    $script:BRAVOHealthLastStepTime = Get-Date
}

function Write-BRAVOHealthStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('OK', 'SKIPPED', 'WARNING', 'ERROR')]
        [string]$Status = 'OK',
        [string]$Details
    )

    $script:BRAVOHealthStepCurrent++
    switch ($Status) {
        'OK'      { $script:BRAVOHealthStepOkCount++ }
        'WARNING' { $script:BRAVOHealthStepWarningCount++ }
        'ERROR'   { $script:BRAVOHealthStepErrorCount++ }
    }
    # Тривалість кроку — час від попереднього кроку (чи від Initialize,
    # для першого). Health не має власного таймера на кожен крок, тому
    # це найточніша оцінка без додаткової інструментації кожної перевірки.
    $stepDuration = $null
    if ($null -ne $script:BRAVOHealthLastStepTime) {
        $stepDuration = (Get-Date) - $script:BRAVOHealthLastStepTime
    }
    $script:BRAVOHealthLastStepTime = Get-Date
    # Вбудований виклик з Archive (SuppressHeader) не друкує власну
    # покрокову нумерацію [N/5]: вона стоїть поряд із власною нумерацією
    # Archive [N/7] і виглядає як другий незалежний прогін замість одного
    # кроку "Перевірка резервних копій". Лічильник вище лишається
    # безумовним — від нього залежить нумерація кроку "Сповіщення".
    if ($SuppressHeader) {
        return
    }
    Write-BRAVOStepResult `
        -Current $script:BRAVOHealthStepCurrent `
        -Total $script:BRAVOHealthStepTotal `
        -Name $Name `
        -Status $Status `
        -Details $Details `
        -Duration $stepDuration
}

# Health не «виконує» компоненти, а перевіряє їх, тому статус етапу — це
# просто наявність знайдених проблем. ERROR, а не WARNING: будь-яка проблема
# резервної копії означає, що відновлення може не спрацювати.
function Get-BRAVOHealthStepStatus {
    param([int]$IssueCount)

    if ($IssueCount -gt 0) { return 'ERROR' }
    return 'OK'
}

function Get-BRAVOHealthStepDetails {
    param([int]$IssueCount)

    if ($IssueCount -gt 0) { return "проблем: $IssueCount" }
    return $null
}

# dev.16 (review round 3): компактний per-entity/per-component Details для
# кроків, що НЕ розділяються на окремі steps ("Керовані служби", "Локальні
# резервні копії" — залишаються одним кроком, лише отримують перелік
# зачеплених імен). $EntityProperty бере вже наявне factual поле issue-
# об'єкта (Location для служб — plain ім'я служби без префікса; Component
# для локальних резервних копій — plain ім'я компонента MODEL/BLOG/...).
# Нічого не вигадується: лише унікальні наявні значення, коротко
# приєднані до вже наявного "проблем: N".
function Get-BRAVOHealthCompactIssueDetails {
    param(
        [array]$Issues,
        [string]$EntityProperty = 'Component',
        [string]$Label = 'компоненти'
    )

    $baseDetails = Get-BRAVOHealthStepDetails -IssueCount $Issues.Count
    if ($Issues.Count -eq 0) {
        return $baseDetails
    }
    $entityNames = @(
        $Issues |
            ForEach-Object { [string]$_.$EntityProperty } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if ($entityNames.Count -eq 0) {
        return $baseDetails
    }
    return "$baseDetails; ${Label}: $($entityNames -join ', ')"
}

# Статуси Health -> три результати спільної консолі. Deferred/Skipped/Disabled
# свідомо не «УСПІШНО»: перевірка не виконувалась, і показувати зелений
# результат там, де нічого не перевірено, — це рівно той тип брехливого
# моніторингу, проти якого існує цей runtime.
function Get-BRAVOHealthSummaryResult {
    param([string]$Status, [int]$WarningCount)

    switch ($Status) {
        'Healthy' {
            if ($WarningCount -gt 0) { return 'ЧАСТКОВО' }
            return 'УСПІШНО'
        }
        'Deferred' { return 'ЧАСТКОВО' }
        'Skipped'  { return 'ЧАСТКОВО' }
        'Disabled' { return 'ЧАСТКОВО' }
        default    { return 'ПОМИЛКА' }
    }
}

function Complete-BRAVOHealthResult {
    param([Parameter(Mandatory = $true)]$Result)

    # Код завершення обчислюється тут, ДО друку підсумку — той самий клас
    # виправлення, що вже застосований в Archive: раніше цей самий switch
    # стояв у самому кінці файлу й виконувався ПІСЛЯ друку підсумку, тому
    # підсумок фізично не міг показати правильний "Код завершення:". Через
    # цю функцію проходить КОЖЕН з 13 шляхів виходу Health, тому обчислення
    # тут покриває їх усі без дублювання логіки.
    $healthExitCode = switch ([string]$Result.Status) {
        'Healthy'            { 0 }
        'Skipped'            { 0 }
        'Disabled'           { 0 }
        'Deferred'           { Resolve-BRAVOExitCode -LockBusy }
        'ConfigurationError' { Resolve-BRAVOExitCode -InvalidConfiguration }
        # dev.13: локальна AccessDenied (чи інша I/O-відмова) на LOGS/TEMP —
        # реальні health-checks (служби/локальні копії/SFTP/SMB) не
        # виконувались, тому це не HealthCritical (70), а окремий
        # prerequisite-код. IsPrivilegeFailure розрізняє "потрібні права
        # адміністратора" (36) від "диск повний / шлях зіпсований / інша
        # I/O-причина" (37) — друге не варто радити "запустити адміністратором".
        'EnvironmentError'   {
            if ([bool]$Result.IsPrivilegeFailure) {
                Resolve-BRAVOExitCode -PrivilegeRequired
            } else {
                Resolve-BRAVOExitCode -EnvironmentUnavailable
            }
        }
        'Critical'           { Resolve-BRAVOExitCode -HealthCritical }
        'NotificationError'  { Resolve-BRAVOExitCode -HealthCritical }
        default              { Resolve-BRAVOExitCode -HealthCritical }
    }
    if ($healthExitCode -eq 0 -and $script:BRAVOWarningCount -gt 0) {
        $healthExitCode = Resolve-BRAVOExitCode -HasWarnings
    }
    # Порушення цілісності інструментів перекриває будь-який інший
    # результат Health — те саме застереження, що раніше стояло в кінці
    # файлу, перенесене сюди без зміни умови.
    if ($null -ne $script:BRAVOToolManifest -and $script:BRAVOToolManifest.ShouldBlock) {
        $healthExitCode = Resolve-BRAVOExitCode -ToolIntegrityViolation
    }
    $script:healthRuntimeExitCode = $healthExitCode

    # Machine-readable status contract v1 (ROADMAP P2.1, BRAVO.Status):
    # пишеться ПІСЛЯ обчислення exit code і fail-soft — помилка запису
    # лише логується і НІКОЛИ не змінює результат Health (інваріант
    # «telemetry не змінює exit code»). Вбудований виклик з Archive
    # (-SuppressHeader) статус НЕ пише: інакше він перезаписував би
    # результат останнього самостійного Health-прогону. Поля деталей
    # best-effort: на ранніх виходах (config не завантажено) відсутні
    # значення лишаються порожніми/null, а недоступний $stateRoot
    # коректно перехоплюється зовнішнім catch.
    # ([bool]-форма guard-а навмисно відрізняється ТЕКСТУАЛЬНО від guard-а
    # консольного підсумку нижче: контракт Health/EmbeddedCallSuppressesOwnSummary
    # аналізує перші входження точних рядків того блоку і не повинен
    # зачепити цей телеметричний блок — тому тут жодних згадок імен
    # функцій консольного підсумку.)
    if (-not [bool]$SuppressHeader) {
        try {
            $statusLastCompleteGeneration = ''
            try {
                $statusLastCompleteGeneration = [string](Get-BRAVORestoreGenerationManifest `
                    -BackupRoot $backupRootPath).Manifest.generationId
            } catch {
                $statusLastCompleteGeneration = ''
            }
            $statusLastRestoreVerifiedAt = ''
            try {
                $statusRestoreVerifyState = Get-BRAVORestoreVerifyState `
                    -Path (Get-BRAVORestoreVerifyStatePath -StateRoot $stateRoot)
                if ($statusRestoreVerifyState.Exists -and -not $statusRestoreVerifyState.Corrupt) {
                    $statusLastRestoreVerifiedAt = [string]$statusRestoreVerifyState.State.LastVerifiedAt
                }
            } catch {
                $statusLastRestoreVerifiedAt = ''
            }
            $statusDetails = @{
                issueCount = if ($null -ne $Result.PSObject.Properties['IssueCount']) { [int]$Result.IssueCount } else { $null }
                localVerified = if ($null -ne $Result.PSObject.Properties['LocalVerified']) { [bool]$Result.LocalVerified } else { $null }
                sftpVerified = if ($null -ne $Result.PSObject.Properties['SftpVerified']) { [bool]$Result.SftpVerified } else { $null }
                smbVerified = if ($null -ne $Result.PSObject.Properties['SmbVerified']) { [bool]$Result.SmbVerified } else { $null }
                runtimeIntegrity = if ($env:BRAVO_RUNTIME_INTEGRITY_MODE -eq 'Warn') { 'UNVERIFIED' } else { 'OK' }
                toolIntegrity = if ($null -ne $script:BRAVOToolManifest -and $script:BRAVOToolManifest.ShouldBlock) { 'VIOLATION' } else { 'OK' }
                lastCompleteGeneration = $statusLastCompleteGeneration
                lastRestoreVerifiedAt = $statusLastRestoreVerifiedAt
            }
            Write-BRAVOOperationStatus `
                -StateRoot $stateRoot `
                -Operation Health `
                -ExitCode $healthExitCode `
                -ExitCodeName (Get-BRAVOExitCodeName -Code $healthExitCode) `
                -StartedAt $healthCheckStarted `
                -Details $statusDetails
        } catch {
            # Ранні виходи (config не завантажено) стаються ДО оголошення
            # Write-HealthLog — catch мусить бути самодостатнім, інакше
            # телеметрична помилка зламала б сам шлях виходу.
            $statusWriteFailureMessage = "Не вдалося записати machine-readable status-файл Health: $($_.Exception.Message)"
            if (Get-Command -Name Write-HealthLog -CommandType Function -ErrorAction SilentlyContinue) {
                Write-HealthLog $statusWriteFailureMessage -Level WARNING -Environmental
            } else {
                Write-Warning $statusWriteFailureMessage
            }
        }
    }

    # Через цю функцію проходить КОЖЕН шлях виходу Health, тому підсумок тут
    # неможливо забути додати в новій гілці — на відміну від друку підсумку
    # в кінці основного потоку.
    if ($script:BRAVOHealthConsoleReady) {
        # Останній етап друкується тут, бо гілок відправлення сповіщення
        # шість (вимкнено, пригнічено, надіслано, помилка, не потрібно...),
        # і в кожній його довелося б дублювати. Умова про передостанній
        # номер захищає ранні виходи: без пройдених перевірок рядок
        # «Сповіщення» лише збивав би нумерацію.
        if ($script:BRAVOHealthNotificationStepEnabled -and
            $script:BRAVOHealthStepCurrent -eq ($script:BRAVOHealthStepTotal - 1)) {
            $notificationStatus = switch ([string]$Result.Notification) {
                'Sent'        { 'OK' }
                'NotRequired' { 'SKIPPED' }
                'Suppressed'  { 'SKIPPED' }
                'Failed'      { 'ERROR' }
                'NotSent'     { 'ERROR' }
                default       { 'SKIPPED' }
            }
            Write-BRAVOHealthStep `
                -Name 'Сповіщення' `
                -Status $notificationStatus `
                -Details ([string]$Result.Notification)
        }

        Complete-BRAVOProgress

        # Вбудований виклик з Archive не друкує власний підсумок
        # (Результат/Тривалість/.../Детальний журнал) — Archive вже показує
        # свій ОДИН підсумок наприкінці, а окремий рядок
        # "Health-check: знайдено проблем: N; повідомлення: ..." (Archive.Runtime.ps1)
        # передає суть без другого блоку й другого посилання на лог-файл.
        # Сам файл Health-логу як і раніше створюється — просто не
        # анонсується другим "Детальний журнал:" у консолі.
        if (-not $SuppressHeader) {
            $summaryResult = Get-BRAVOHealthSummaryResult `
                -Status ([string]$Result.Status) `
                -WarningCount $script:BRAVOWarningCount
            $summaryStatusColor = switch ($summaryResult) {
                'УСПІШНО'  { 'Green' }
                'ЧАСТКОВО' { 'Yellow' }
                default    { 'Red' }
            }
            $healthCheckEnded = Get-Date

            Write-BRAVOResultHeader `
                -Status $summaryResult `
                -StatusColor $summaryStatusColor `
                -ExitCode $healthExitCode `
                -ExitCodeName (Get-BRAVOExitCodeName -Code $healthExitCode)
            Write-BRAVOResultField -Label 'Початок' -Value $healthCheckStarted.ToString('dd.MM.yyyy HH:mm:ss')
            Write-BRAVOResultField -Label 'Завершення' -Value $healthCheckEnded.ToString('dd.MM.yyyy HH:mm:ss')
            Write-BRAVOResultField -Label 'Тривалість' -Value (Format-BRAVODuration -Duration ($healthCheckEnded - $healthCheckStarted))
            Write-BRAVOResultBlankLine
            Write-BRAVOResultField -Label 'Перевірок' -Value ([string]$script:BRAVOHealthStepCurrent)
            Write-BRAVOResultField -Label 'Успішно' -Value ([string]$script:BRAVOHealthStepOkCount)
            Write-BRAVOResultField -Label 'Попереджень' -Value ([string]$script:BRAVOHealthStepWarningCount)
            Write-BRAVOResultField -Label 'Помилок' -Value ([string]$script:BRAVOHealthStepErrorCount)
            if ($null -ne $Result.PSObject.Properties['IssueCount']) {
                Write-BRAVOResultField -Label 'Проблем' -Value ([string][int]$Result.IssueCount)
            }
            # Метрика вимкненого призначення бреше найгірше з усього виводу:
            # «NAS/SMB: True» читається як «перевірено й усе гаразд», хоча
            # перевірки не було взагалі. Вимкнений компонент не показуємо тут
            # рівно так само, як не показуємо його етап.
            foreach ($destination in @(
                @{ Property = 'LocalVerified'; Title = 'Локальні копії'; Enabled = $true },
                @{ Property = 'SftpVerified';  Title = 'SFTP';           Enabled = $script:BRAVOHealthSftpStepEnabled },
                @{ Property = 'SmbVerified';   Title = 'NAS/SMB';        Enabled = $script:BRAVOHealthSmbStepEnabled }
            )) {
                if (-not $destination.Enabled) {
                    continue
                }
                $property = $Result.PSObject.Properties[$destination.Property]
                if ($null -ne $property -and $null -ne $property.Value) {
                    Write-BRAVOResultField -Label $destination.Title -Value ([string]$property.Value)
                }
            }
            if ($script:BRAVOHealthNotificationStepEnabled -and
                $null -ne $Result.PSObject.Properties['Notification']) {
                Write-BRAVOResultField -Label 'Сповіщення' -Value ([string]$Result.Notification)
            }

            # Резервні копії: останній справний архів кожного увімкненого
            # компонента. $script:healthLatestArchives заповнюється лише для
            # копій, що пройшли перевірку (Get-BackupHealthIssues) — те саме
            # джерело даних, що вже йде в успішне Slack-сповіщення.
            # Глобальна archiveDefinitions ще не існує на ранніх шляхах виходу
            # (до завантаження BRAVO.config, наприклад ConfigurationError
            # на відсутній файл конфігурації) — Get-Variable без помилки
            # повертає $null замість кидати виняток під Set-StrictMode.
            $archiveDefinitionsVariable = Get-Variable -Name archiveDefinitions -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $archiveDefinitionsVariable -and $script:healthLatestArchives.Count -gt 0) {
                $enabledArchiveDefinitionsForSummary = @($archiveDefinitionsVariable.Value | Where-Object { $_.Enabled })
                if ($enabledArchiveDefinitionsForSummary.Count -gt 0) {
                    Write-BRAVOResultSection -Title 'Резервні копії'
                    foreach ($definition in $enabledArchiveDefinitionsForSummary) {
                        $archiveInfo = $script:healthLatestArchives[$definition.Type]
                        if ($null -eq $archiveInfo) {
                            continue
                        }
                        $ageText = Format-BackupAge -LastWriteTime $archiveInfo.LastWriteTime
                        Write-BRAVOConsoleDetail -Message ("{0,-11}OK   {1,10}   вік {2}" -f $definition.Type, (Format-BRAVOFileSize -Bytes $archiveInfo.SizeBytes), $ageText)
                    }
                }
            }

            # Проблеми: короткий операторський індекс поточного прогону —
            # лише коли справді є що показати (порожній розділ виглядав би
            # як прихована помилка форматування, а не підтвердження
            # відсутності проблем). $healthIssues — локальна змінна
            # Invoke-BRAVOHealth, існує лише на пізніх шляхах виходу (після
            # збору всіх перевірок) — той самий захист Get-Variable, що й
            # вище.
            $healthIssuesVariable = Get-Variable -Name healthIssues -ErrorAction SilentlyContinue
            if ($null -ne $healthIssuesVariable -and @($healthIssuesVariable.Value).Count -gt 0) {
                Write-BRAVOResultSection -Title 'Проблеми'
                foreach ($issue in @($healthIssuesVariable.Value)) {
                    $issueLine = Get-BRAVOHealthConsoleIssueLine -Issue $issue
                    $issueColor = if ($issueLine.Severity -eq 'WARNING') { [ConsoleColor]::Yellow } else { [ConsoleColor]::Red }
                    Write-BRAVOConsoleDetail -Message ("{0,-7}  {1}" -f $issueLine.Severity, $issueLine.Component) -Color $issueColor
                    if (-not [string]::IsNullOrWhiteSpace($issueLine.Detail)) {
                        Write-BRAVOConsoleDetail -Message ("         {0}" -f $issueLine.Detail)
                    }
                }
            }

            Write-BRAVOResultFooter -LogFile ([string]$Result.LogPath)
        }
    }

    return $Result
}

$bravoScriptDirectory = $RuntimeRoot

# Health використовує спільні модулі, а не копії з архіватора.
# dev.14: BRAVO.ArchiveHelpers додано для Get-BRAVOBackupGenerationManifestFiles
# (централізований read-only reader generation manifest-ів, MANIFESTS +
# legacy fallback) — Health лишається read-only, з ArchiveHelpers
# використовується лише читання; функція міграції/запису сюди не викликається.
foreach ($moduleName in @('BRAVO.Compatibility', 'BRAVO.Credentials', 'BRAVO.ArchiveRuntime', 'BRAVO.BazaSync', 'BRAVO.ArchiveHelpers', 'BRAVO.Logging', 'BRAVO.Console', 'BRAVO.ExitCodes', 'BRAVO.System', 'BRAVO.RestoreVerify', 'BRAVO.Status')) {
    $modulePath = Join-Path $bravoScriptDirectory "modules\$moduleName\$moduleName.psd1"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Не знайдено спільний PowerShell-модуль: $modulePath"
    }
    Import-Module -Name $modulePath -ErrorAction Stop
}
Assert-BRAVOPowerShellCompatibility
[void](Initialize-BRAVOConsoleEncoding -CodePage 65001)
$script:BRAVOCompatibility = Get-BRAVOCompatibilityInfo
$script:BRAVOPowerShellUpdate = Get-BRAVOPowerShellUpdateRecommendation
$script:BRAVOWindowsPatchLevel = Get-BRAVOWindowsPatchLevelRecommendation
$notificationHelpersPath = Join-Path $bravoScriptDirectory 'modules\BRAVO.Notifications\BRAVO.Notifications.psd1'
if (-not (Test-Path -LiteralPath $notificationHelpersPath -PathType Leaf)) {
    throw "Не знайдено PowerShell-модуль notifications: $notificationHelpersPath"
}
Import-Module -Name $notificationHelpersPath -ErrorAction Stop

try {
    Enable-BRAVOTls12
} catch {
    # Health-check зможе виконати локальні перевірки навіть тоді, коли
    # TLS 1.2 не підтримується системним .NET/Schannel.
}

# P0 Configuration Foundation: справжня межа виклику оператора — root
# entrypoint, і лише ВІН знає, чи -ConfigPath був реально переданий: сюди
# ConfigPath завжди приходить уже резолвленим і непорожнім, тому
# $PSBoundParameters тут відновити намір не може (acceptance-клас дефектів
# CF-17/AUTO-intent). Намір приймається явним -ConfigPathWasExplicit;
# додаткова перевірка порожнього шляху страхує від помилкового виклику з
# прапорцем без шляху (та сама семантика, що в Import-BravoConfiguration).
$configPathWasExplicit = $ConfigPathWasExplicit -and
    -not [string]::IsNullOrWhiteSpace($ConfigPath)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $bravoScriptDirectory "BRAVO.config"
}

$healthCheckStarted = Get-Date
$healthCheckStartedUtc = $healthCheckStarted.ToUniversalTime()
$script:healthLatestArchives = @{}

# P0 Configuration Foundation: BRAVO.config став опційним основним
# override-шаром — попередня жорстка "файл мусить існувати" перевірка
# тут дублювала (і випереджала) те саме рішення, яке Import-Bravo
# Configuration тепер приймає коректно сама (auto-derived відсутній
# BRAVO.config -> canonical built-in defaults + BRAVO.local.config;
# явно вказаний відсутній -ConfigPath -> як і раніше, помилка,
# перехоплена нижче тим самим catch і тим самим ConfigurationError-
# результатом). Один canonical guard замість двох незалежних копій.

try {
    $loaderPath = Join-Path `
        -Path $bravoScriptDirectory `
        -ChildPath "BRAVO_CONFIG_LOADER.ps1"

    if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
        throw "Configuration loader not found: $loaderPath"
    }

    . $loaderPath

    Import-BravoConfiguration `
        -ConfigRoot (Split-Path -Path ([System.IO.Path]::GetFullPath($ConfigPath)) -Parent) `
        -ConfigPath $ConfigPath `
        -RuntimeRoot $bravoScriptDirectory `
        -ConfigPathWasExplicit:$configPathWasExplicit

    $ConfigPath = [string]$global:BravoConfigurationMetadata.ConfigPath
    if ($null -ne $credentialSettings) {
        [void](Import-BRAVOInstitutionSettings `
            -CredentialSettings $credentialSettings `
            -BravoSettings $bravoSettings)
    }
} catch {
    Write-Error "Не вдалося завантажити конфігурацію: $(Protect-BRAVOLogSecret -Text $_.Exception.Message)"
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

$bazaAppLocalHealthEnabled = Test-BRAVOSettingEnabled `
    -Value $componentSettings.Synchronization.BAZA_APP_LOCAL
# SFTP-напрямки BAZA (5.2.2): через canonical $bazaSyncEffective.Components
# (Get-BRAVOEffectiveSynchronizationConfiguration), той самий вираз, що і
# в Archive/Дry Run — componentSettings.SFTP.Enabled уже "запечений" в
# SftpEnabled, Health не дублює AND самостійно. LOCAL-напрямки від
# глобального SFTP-вимикача не залежать і лишаються прямим читанням.
$bazaAppSFTPHealthEnabled = [bool]($bazaSyncEffective.Components | Where-Object { $_.Name -eq 'BAZA_APP' } | Select-Object -First 1 -ExpandProperty SftpEnabled)
$bazaWWWSFTPHealthEnabled = [bool]($bazaSyncEffective.Components | Where-Object { $_.Name -eq 'BAZA_WWW' } | Select-Object -First 1 -ExpandProperty SftpEnabled)
$bazaWWWLocalHealthEnabled = Test-BRAVOSettingEnabled `
    -Value $componentSettings.Synchronization.BAZA_WWW_LOCAL

$healthLogTimestamp = $healthCheckStarted.ToString($logFileDateFormat)
$healthLogName = $backupMonitoring.LogFileNameTemplate -f $healthLogTimestamp
$healthLogFile = Join-Path $logPath $healthLogName

$credentialHelperLoaded = $false
$credentialHelperError = $null
$notificationCredentialError = $null
$sftpCredentialError = $null
$smbCredentialError = $null
$script:smbCredential = $null
# Лічильник WARNING для контракту кодів завершення: успіх без жодного
# попередження -> 0, успіх із попередженнями -> 10 (Resolve-BRAVOExitCode).
# Ініціалізується тут явно, а не лише в Write-HealthLog — інакше перше ж
# читання під Set-StrictMode впало б, якщо жодного попередження не було.
$script:BRAVOWarningCount = 0
# Кеш каталогу тимчасових файлів WinSCP. Get-BRAVOHealthTemporaryRoot читає
# його ще до першого присвоєння, а Set-StrictMode (успадкований від
# конфігураційного завантажувача) робить читання неоголошеної змінної помилкою.
$script:bravoHealthTemporaryRoot = $null
# dev.13: fail-safe запис логу. Write-HealthLog викликається десятки разів
# за один прогін — без цього прапорця AccessDenied на здоровому (LOGS
# просто недоступний) запуску друкував ту саму помилку в консоль щоразу.
# $true, доки перша спроба запису не провалиться; після цього Write-HealthLog
# більше не намагається писати у файл (і не друкує ту саму помилку знову).
$script:BRAVOHealthLogWritable = $true
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
# Маршрутизація (GENERAL/ALERTS) і резолв webhook — виключно через
# централізований API BRAVO.Notifications; Health сам канал не обирає.
# Preflight-резолв лише тих routes, які реально досяжні за поточного
# NotificationMode: ALERTS потрібен, доки mode != none (WARNING/ERROR/
# CRITICAL завжди туди маршрутизуються); GENERAL — лише коли mode == all
# (інакше SUCCESS все одно придушується і GENERAL webhook не знадобиться).
$script:NotificationWebhookUrls = @{}
if ($NotificationMode -ne "none" -and $credentialHelperLoaded) {
    $reachableNotificationRoutes = @("alerts")
    if ($NotificationMode -eq "all") {
        $reachableNotificationRoutes += "general"
    }
    foreach ($reachableRoute in $reachableNotificationRoutes) {
        try {
            $script:NotificationWebhookUrls[$reachableRoute] = Resolve-BRAVONotificationEndpoint `
                -Provider $NotificationProvider `
                -Route $reachableRoute `
                -CredentialTargets $backupMonitoring.NotificationCredentialTargets
        } catch {
            if (-not $notificationCredentialError) {
                $notificationCredentialError = $_.Exception.Message
            }
        }
    }
} elseif ($NotificationMode -ne "none") {
    $notificationCredentialError = $credentialHelperError
}

$script:Login = $null
$script:resolvedSftpHost = $null
$script:sftpUrl = $null
# dev.16 (review round 3): три незалежні флаги — та сама булева логіка,
# розкладена по компонентах (A OR (B AND (C OR D)) == (A) OR (B AND C) OR
# (B AND D)), для розділення "SFTP" на 3 dynamic steps нижче.
# $sftpCredentialRequired (нижче) лишається ЇХНІМ OR — той самий
# consumer (BRAVOHealthSftpStepEnabled, підсумок Complete-BRAVOHealthResult)
# і той самий сигнал про потребу в credential, що й раніше.
# componentSettings.SFTP.Enabled (5.2.2): $storageEffective.SFTP.ArchiveUpload
# уже "запечений" master AND child; bazaApp/WwwSFTPHealthEnabled вище так
# само вже effective через $bazaSyncEffective.Components — тому явний AND
# з $storageEffective.SFTP.Enabled тут не потрібен для цих трьох, окрім
# ArchiveUpload-терму нижче (той досі читав raw componentSettings).
$sftpArchivesHealthEnabled = [bool]$backupMonitoring.SFTP.Enabled -and
    [bool]$backupMonitoring.SFTP.CheckArchiveUploads -and
    [bool]$storageEffective.SFTP.ArchiveUpload
$sftpBazaAppHealthEnabled = [bool]$backupMonitoring.SFTP.Enabled -and
    [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
    $bazaAppSFTPHealthEnabled
$sftpBazaWWWHealthEnabled = [bool]$backupMonitoring.SFTP.Enabled -and
    [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
    $bazaWWWSFTPHealthEnabled
$sftpCredentialRequired = [bool]$backupMonitoring.SFTP.Enabled -and
    (([bool]$backupMonitoring.SFTP.CheckArchiveUploads -and [bool]$storageEffective.SFTP.ArchiveUpload) -or
    ([bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
    ($bazaAppSFTPHealthEnabled -or $bazaWWWSFTPHealthEnabled)))
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
        $script:Login = ([string]$storedSftpLogin).Trim()
        $legacySftpHostVariable = Get-Variable -Name 'sftpHost' -Scope Global -ErrorAction SilentlyContinue
        $configuredSftpHost = if ($null -ne $legacySftpHostVariable) { [string]$legacySftpHostVariable.Value } else { $null }
        $script:resolvedSftpHost = Resolve-BRAVOSftpHostName `
            -UserName $script:Login `
            -HostTemplate ([string]$sftpHostTemplate) `
            -FallbackHostName $configuredSftpHost
        $script:sftpUrl = New-BRAVOSftpUrl `
            -HostName $script:resolvedSftpHost `
            -Port ([int]$sftpPort) `
            -UserName $script:Login `
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
    [bool]$storageEffective.SMB.ArchiveCopy
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
        # SecureString, не рядок: далі потрібен лише PSCredential, тому
        # плейнтекст пароля SMB не створюється взагалі (аудит #5).
        $storedSmbPassword = Get-BRAVOCredentialSecureSecret -Target $smbPasswordTarget
        if ([string]::IsNullOrWhiteSpace($storedSmbLogin)) {
            throw "запис Credential Manager '$smbLoginTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }
        if ($null -eq $storedSmbPassword -or $storedSmbPassword.Length -eq 0) {
            throw "запис Credential Manager '$smbPasswordTarget' не знайдено або він порожній для $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        }

        $script:smbCredential = New-BRAVOSecureCredential `
            -UserName ([string]$storedSmbLogin) `
            -SecureSecret $storedSmbPassword
        $storedSmbLogin = $null
        $storedSmbPassword = $null
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

# Ті самі рівні й та сама шкала, що в BRAVO.Logging: SUCCESS свідомо нижче
# за WARNING, щоб підняття порога ніколи не приховало попереджень.
$script:BRAVOHealthLevelSeverity = @{
    TRACE   = 0
    DEBUG   = 1
    INFO    = 2
    SUCCESS = 3
    WARNING = 4
    ERROR   = 5
    FATAL   = 6
}

function Get-BRAVOHealthLevelSeverity {
    param([string]$Level)

    if (-not [string]::IsNullOrWhiteSpace($Level)) {
        $normalized = $Level.Trim().ToUpperInvariant()
        if ($script:BRAVOHealthLevelSeverity.ContainsKey($normalized)) {
            return [int]$script:BRAVOHealthLevelSeverity[$normalized]
        }
    }
    return [int]$script:BRAVOHealthLevelSeverity['INFO']
}

# Нормалізація потрібна саме тут: Write-HealthLog історично приймає будь-який
# рядок рівня, а Write-BRAVOConsoleMessage має ValidateSet і впав би на
# друкарській помилці в одному з понад ста викликів.
function Get-BRAVOHealthNormalizedLevel {
    param([string]$Level)

    if (-not [string]::IsNullOrWhiteSpace($Level)) {
        $normalized = $Level.Trim().ToUpperInvariant()
        if ($script:BRAVOHealthLevelSeverity.ContainsKey($normalized)) {
            return $normalized
        }
    }
    return 'INFO'
}

# Поріг консолі береться з тієї самої секції BRAVO.config, що й в Archive,
# тому оператор налаштовує детальність один раз для всіх трьох runtime.
$healthConfiguredConsoleLevel = if ($null -ne $consoleSettings.ConsoleLevel) {
    [string]$consoleSettings.ConsoleLevel
} else {
    'WARNING'
}
$script:BRAVOHealthConsoleThreshold = Get-BRAVOHealthLevelSeverity `
    -Level $healthConfiguredConsoleLevel

$healthConfiguredStepWidth = if ($null -ne $consoleSettings.StepWidth) {
    [int]$consoleSettings.StepWidth
} else {
    58
}
Initialize-BRAVOConsole -StepWidth $healthConfiguredStepWidth
Initialize-BRAVOProgress -Activity 'BRAVO HEALTH' -Enabled ([bool]$progressSettings.Enabled)

# Вимкнений у конфігурації компонент не показуємо й не рахуємо: етап існує
# лише для того, що справді перевірятиметься. Та сама логіка, що в Archive
# (Initialize-BRAVOArchiveSteps) — вимкнений SFTP чи NAS не створює порожніх
# рядків і не роздуває знаменник.
$script:BRAVOHealthSftpStepEnabled = $sftpCredentialRequired
$script:BRAVOHealthSmbStepEnabled = $smbCredentialRequired
$script:BRAVOHealthNotificationStepEnabled = ($NotificationMode -ne 'none') -and (-not $NoSlack)
# P1.1: крок «Відновлюваність» видимий лише коли задача BRAVO_RESTORE_VERIFY
# увімкнена конфігурацією (loader гарантує наявність вузла і для legacy).
$script:BRAVOHealthRestoreVerifyStepEnabled = [bool]$schedulerSettings.RestoreVerify.Enabled
# SFTP-перевірку відкладено через зайнятий WinSCP (див. Get-SFTPHealthIssues):
# кроки SFTP рендеряться SKIPPED, SftpVerified не оголошується підтвердженим.
$script:BRAVOHealthSftpCheckDeferredByBusyWinSCP = $false
# Середовище, керовані служби й локальні копії виконуються завжди.
# dev.16 (review round 3): BAZA (локальна копія) і SFTP розділені на
# незалежні dynamic steps — Total тепер точно дорівнює кількості РЕАЛЬНО
# видимих увімкнених перевірок (Health/StepTotalMatchesVisibleEnabledChecks);
# кожен доданок тут відповідає РІВНО одному Write-BRAVOHealthStep нижче.
Initialize-BRAVOHealthSteps -Total (
    3 +
    $(if ($bazaAppLocalHealthEnabled) { 1 } else { 0 }) +
    $(if ($bazaWWWLocalHealthEnabled) { 1 } else { 0 }) +
    $(if ($sftpArchivesHealthEnabled) { 1 } else { 0 }) +
    $(if ($sftpBazaAppHealthEnabled) { 1 } else { 0 }) +
    $(if ($sftpBazaWWWHealthEnabled) { 1 } else { 0 }) +
    $(if ($script:BRAVOHealthSmbStepEnabled) { 1 } else { 0 }) +
    $(if ($script:BRAVOHealthNotificationStepEnabled) { 1 } else { 0 }) +
    $(if ($script:BRAVOHealthRestoreVerifyStepEnabled) { 1 } else { 0 })
)
Write-BRAVOHeader `
    -Title ("BRAVO HEALTH {0}" -f $global:ScriptVersion) `
    -Institution ([string]$bravoSettings.InstitutionName) `
    -InstitutionCode ([string]$bravoSettings.InstitutionCode) `
    -Mode $(if ($NoPause) { 'SCHEDULED' } else { 'MANUAL' }) `
    -StartedAt $healthCheckStarted `
    -SuppressText:$SuppressHeader

# dev.16 (review round 3): "План перевірок" — той самий "plan-first"
# принцип, що Maintenance/Archive, лише коли Health запущено самостійно
# (не вбудований виклик з Archive: там SuppressHeader вже приглушує
# заголовок, і другий, вкладений план лише заплутав би оператора). Джерело
# значень — ті самі прапорці, що вже визначають нумерацію кроків вище
# (Initialize-BRAVOHealthSteps) і Total вище, тому план і фактичне
# виконання не можуть розійтися. Рендер через спільний Write-BRAVOPlan
# (BRAVO.Console) — Health не має права на власний raw Write-Host
# (Console/HealthRendersNoRawWriteHost).
if (-not $SuppressHeader) {
    $healthPlanEntries = [ordered]@{}
    $healthPlanEntries['Середовище й цілісність інструментів'] = $true
    $healthPlanEntries['Керовані служби'] = $true
    $healthPlanEntries['Локальні резервні копії'] = $true
    $healthPlanEntries['Відновлюваність (restore drill)'] = [bool]$script:BRAVOHealthRestoreVerifyStepEnabled
    $healthPlanEntries['BAZA_APP (локальна копія)'] = [bool]$bazaAppLocalHealthEnabled
    $healthPlanEntries['BAZA_WWW (локальна копія)'] = [bool]$bazaWWWLocalHealthEnabled
    $healthPlanEntries['SFTP: резервні копії'] = [bool]$sftpArchivesHealthEnabled
    $healthPlanEntries['SFTP: BAZA_APP'] = [bool]$sftpBazaAppHealthEnabled
    $healthPlanEntries['SFTP: BAZA_WWW'] = [bool]$sftpBazaWWWHealthEnabled
    $healthPlanEntries['NAS/SMB'] = [bool]$script:BRAVOHealthSmbStepEnabled
    $healthPlanEntries['Сповіщення'] = [bool]$script:BRAVOHealthNotificationStepEnabled
    Write-BRAVOPlan -Title 'План перевірок:' -Entries $healthPlanEntries
}
$script:BRAVOHealthConsoleReady = $true

function Write-HealthLog {
    param(
        [string]$Message,
        [string]$Level = "INFO",

        # Environmental-нагадування (застарілі оновлення ОС/PowerShell) —
        # це стан середовища, а не результат операції. Такий запис лишається
        # видимим як WARNING, але НЕ інкрементує лічильник попереджень:
        # інакше кожен успішний прогін на невідновленому сервері назавжди
        # завершувався б кодом 10 (SuccessWithWarnings) зі статусом ЧАСТКОВО,
        # поки адміністратор не встановить оновлення Windows.
        [switch]$Environmental
    )

    # SFTP URL із паролем, webhook чи інший секрет можуть потрапити сюди
    # через повідомлення винятку WinSCP/Invoke-WebRequest — маскуємо перед
    # тим, як щось піде в консоль чи файл.
    $Message = Protect-BRAVOLogSecret -Text $Message
    if ($Level -eq "WARNING" -and -not $Environmental) {
        $script:BRAVOWarningCount++
    }

    $timestamp = Get-Date -Format $logTimestampFormat
    $entry = "[$timestamp] [$Level] $Message"

    # Консоль і файл — два незалежні канали, як в Archive. У файл іде все,
    # оператору показуємо лише те, що дотягує до порога: структуру запуску
    # задають етапи (Write-BRAVOHealthStep), а не потік записів журналу.
    # Раніше сюди вивалювався кожен рядок, і знайти серед них WARNING було
    # неможливо — саме це й робило вивід Health несумісним із Archive.
    if ((Get-BRAVOHealthLevelSeverity -Level $Level) -ge $script:BRAVOHealthConsoleThreshold) {
        $consoleEntry = if ($consoleSettings.ShowTimestampsInConsole) {
            $entry
        } else {
            $Message
        }
        Write-BRAVOConsoleMessage `
            -Message $consoleEntry `
            -Level (Get-BRAVOHealthNormalizedLevel -Level $Level)
    }

    if (-not $script:BRAVOHealthLogWritable) {
        # Перша спроба вже провалилась цього прогону — не повторюємо той
        # самий New-Item/Out-File на той самий недоступний файл на кожен
        # виклик (їх десятки) і не друкуємо ту саму помилку знову.
        return
    }

    try {
        if (-not (Test-Path -Path $logPath -PathType Container)) {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        $entry | Out-File -FilePath $healthLogFile -Append -Encoding $logFileEncoding
    } catch {
        $script:BRAVOHealthLogWritable = $false
        # Не через Write-HealthLog: журнал саме зараз недоступний, тому
        # рекурсія лише поглибила б проблему.
        Write-BRAVOConsoleMessage `
            -Message "Не вдалося записати health-check лог ($healthLogFile): $($_.Exception.Message). Подальші записи в цей файл у цьому запуску пропускаються." `
            -Level 'WARNING'
    }
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

function ConvertTo-BRAVOUtcDateTime {
    param([Parameter(Mandatory = $true)][datetime]$Timestamp)

    switch ($Timestamp.Kind) {
        ([DateTimeKind]::Utc) { return $Timestamp }
        ([DateTimeKind]::Local) { return $Timestamp.ToUniversalTime() }
        default {
            # Generation manifests are produced from local wall-clock time.
            # Legacy values without an offset are explicitly treated as local.
            return [datetime]::SpecifyKind($Timestamp, [DateTimeKind]::Local).ToUniversalTime()
        }
    }
}

function Get-BRAVOUtcAge {
    param(
        [Parameter(Mandatory = $true)][datetime]$Timestamp,
        [datetime]$NowUtc = (Get-Date).ToUniversalTime()
    )

    return (ConvertTo-BRAVOUtcDateTime -Timestamp $NowUtc) -
        (ConvertTo-BRAVOUtcDateTime -Timestamp $Timestamp)
}

function Format-BackupAge {
    param(
        [object]$LastWriteTime,
        [datetime]$NowUtc = (Get-Date).ToUniversalTime()
    )

    if ($null -eq $LastWriteTime) {
        return "немає даних"
    }

    $age = Get-BRAVOUtcAge -Timestamp ([datetime]$LastWriteTime) -NowUtc $NowUtc
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

    # Мітка часу може нести collision-safe суфікс: коли фінальне ім'я вже
    # зайняте наявним валідним backup, BRAVO_ARCHIV публікує копію як
    # "..._1.mdz". Такий архів — повноцінний кандидат health-check, тому
    # суфікс відокремлюється до розбору дати, а не робить ім'я «чужим».
    $timestampValue = $nameMatch.Groups["Timestamp"].Value
    $collisionMatch = [regex]::Match($timestampValue, '^(?<Timestamp>.+?)_(?<Suffix>\d+)$')
    $timestampCandidates = @($timestampValue)
    if ($collisionMatch.Success) {
        $timestampCandidates += $collisionMatch.Groups["Timestamp"].Value
    }

    # Приймаються обидва формати: чинний із секундами і той, що діяв до
    # переходу на GenerationId. Інакше health перестав би бачити всі
    # backup, створені до оновлення, і звітував би про їх відсутність.
    $acceptedFormats = @($archiveTimestampFormat, "yyyyMMdd_HHmmss", "yyyyMMdd_HHmm") |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    $parsedTimestamp = [datetime]::MinValue
    foreach ($timestampCandidate in $timestampCandidates) {
        foreach ($acceptedFormat in $acceptedFormats) {
            if ([datetime]::TryParseExact(
                    $timestampCandidate,
                    $acceptedFormat,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$parsedTimestamp)) {
                return $true
            }
        }
    }
    return $false
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

    if ($enabledArchiveDefinitions.Count -eq 0) {
        return @()
    }
    if ([string]::IsNullOrWhiteSpace([string]$backupRootPath) -or
        -not (Test-Path -LiteralPath $backupRootPath -PathType Container)) {
        return @([pscustomobject]@{
            Kind = 'LocalBackupGeneration'
            Component = 'Generation'
            Reason = "BackupRoot не знайдено: $backupRootPath"
            FileName = 'немає даних'
            LastWriteTime = $null
            SizeBytes = $null
        })
    }

    $manifestCandidates = @()
    # dev.14: MANIFESTS-first reader з fallback на legacy корінь BackupRoot.
    # Health лишається read-only — жодної міграції/запису тут не відбувається;
    # відсутність MANIFESTS на ще не мігрованій інсталяції не є помилкою, поки
    # legacy manifest-и в корені BackupRoot доступні для читання.
    foreach ($manifestFile in @(Get-BRAVOBackupGenerationManifestFiles -BackupRoot $backupRootPath)) {
        try {
            $manifest = [IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$manifest.status -ne 'COMPLETE') {
                continue
            }
            $createdAtUtc = $manifestFile.LastWriteTimeUtc
            foreach ($dateProperty in @('createdAt', 'startedAt')) {
                $property = $manifest.PSObject.Properties[$dateProperty]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $createdAtUtc = ConvertTo-BRAVOUtcDateTime -Timestamp ([datetime]$property.Value)
                    break
                }
            }
            $manifestCandidates += [pscustomobject]@{
                File = $manifestFile
                Manifest = $manifest
                CreatedAtUtc = $createdAtUtc
            }
        } catch {
            Write-HealthLog "Generation manifest не прочитано: $($manifestFile.Name): $($_.Exception.Message)" -Level 'WARNING'
        }
    }

    $generation = $manifestCandidates | Sort-Object CreatedAtUtc -Descending | Select-Object -First 1
    if ($null -eq $generation) {
        return @([pscustomobject]@{
            Kind = 'LocalBackupGeneration'
            Component = 'Generation'
            Reason = 'не знайдено жодного COMPLETE generation manifest'
            FileName = 'немає даних'
            LastWriteTime = $null
            SizeBytes = $null
        })
    }

    $manifestGenerationId = [string]$generation.Manifest.generationId
    if ([string]::IsNullOrWhiteSpace($manifestGenerationId)) {
        $issues += [pscustomobject]@{
            Kind = 'LocalBackupGeneration'
            Component = 'Generation'
            Reason = 'COMPLETE manifest не містить GenerationId'
            FileName = $generation.File.Name
            LastWriteTime = $generation.CreatedAtUtc
            SizeBytes = $generation.File.Length
        }
    }

    $componentsProperty = $generation.Manifest.PSObject.Properties['components']
    if ($null -eq $componentsProperty -or $null -eq $componentsProperty.Value) {
        return @($issues) + @([pscustomobject]@{
            Kind = 'LocalBackupGeneration'
            Component = 'Generation'
            Reason = 'COMPLETE manifest не містить components'
            FileName = $generation.File.Name
            LastWriteTime = $generation.CreatedAtUtc
            SizeBytes = $generation.File.Length
        })
    }

    foreach ($archiveDefinition in $enabledArchiveDefinitions) {
        $componentName = [string]$archiveDefinition.Type
        $componentProperty = @($componentsProperty.Value.PSObject.Properties | Where-Object {
            [string]::Equals($_.Name, $componentName, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($componentProperty.Count -eq 0) {
            $issues += [pscustomobject]@{
                Kind = 'LocalBackupGeneration'
                Component = $componentName
                Reason = "COMPLETE generation $manifestGenerationId не містить enabled component"
                FileName = $generation.File.Name
                LastWriteTime = $generation.CreatedAtUtc
                SizeBytes = $null
            }
            continue
        }

        $component = $componentProperty[0].Value
        $archivePath = [string]$component.ArchivePath
        $hashPath = [string]$component.HashPath
        $componentValid = [bool]$component.Enabled -and
            [bool]$component.CreateSuccess -and
            [bool]$component.IntegritySuccess -and
            [bool]$component.HashSuccess
        $archiveFile = $null
        $invalidReason = $null
        if (-not $componentValid) {
            $invalidReason = 'component не пройшов archive/integrity/SHA512 stages'
        } elseif (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
            $invalidReason = 'manifest посилається на відсутній archive/hash artifact'
        } else {
            $archiveFile = Get-Item -LiteralPath $archivePath
            $candidateResult = Test-BackupCandidate -Archive $archiveFile
            if (-not $candidateResult.Valid) {
                $invalidReason = $candidateResult.Reason
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($invalidReason)) {
            $issues += [pscustomobject]@{
                Kind = 'LocalBackupGeneration'
                Component = $componentName
                Reason = "generation $manifestGenerationId некоректний: $invalidReason"
                FileName = $(if ($null -ne $archiveFile) { $archiveFile.Name } else { $generation.File.Name })
                LastWriteTime = $generation.CreatedAtUtc
                SizeBytes = $(if ($null -ne $archiveFile) { $archiveFile.Length } else { $null })
            }
            continue
        }

        $script:healthLatestArchives[$componentName] = [pscustomobject]@{
            Name = $archiveFile.Name
            FullName = $archiveFile.FullName
            HashPath = $hashPath
            SizeBytes = [long]$archiveFile.Length
            LastWriteTime = $generation.CreatedAtUtc
            GenerationId = $manifestGenerationId
        }
        Write-HealthLog "Generation $manifestGenerationId / $componentName справний: $($archiveFile.Name), розмір $(Format-FileSize $archiveFile.Length)" -Level 'SUCCESS'
    }

    if ((Get-BRAVOUtcAge -Timestamp $generation.CreatedAtUtc -NowUtc $healthCheckStartedUtc) -gt $maximumAge) {
        $issues += [pscustomobject]@{
            Kind = 'LocalBackupGeneration'
            Component = 'Generation'
            Reason = "остання COMPLETE generation старша за $($backupMonitoring.MaxBackupAgeHours) год."
            FileName = $generation.File.Name
            LastWriteTime = $generation.CreatedAtUtc
            SizeBytes = $generation.File.Length
        }
    } elseif ($issues.Count -eq 0) {
        Write-HealthLog "Остання COMPLETE generation $manifestGenerationId справна; one generation = one point-in-time" -Level 'SUCCESS'
    }

    return @($issues)
}

function Get-BAZALocalSyncHealthIssues {
    # Спільна read-only robocopy /L перевірка для обох незалежних локальних
    # копій — BAZA_APP_LOCAL і BAZA_WWW_LOCAL. -Label потрапляє лише в текст
    # повідомлень (наприклад "BAZA APP"/"BAZA WWW"), самої різної поведінки
    # для компонентів немає.
    param(
        [bool]$Enabled,
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Label
    )

    if (-not $Enabled) {
        return @()
    }

    $sourcePath = [string]$SourcePath
    $destinationPath = [string]$DestinationPath
    $issueBase = @{
        Kind = "LocalSynchronization"
        Component = "Локальна $Label"
        FileName = "каталог $Label"
        LastWriteTime = $null
        SizeBytes = $null
        DifferenceCount = $null
        Details = @()
        Source = $sourcePath
        Location = $destinationPath
    }

    # BAZA_WWW джерело автовизначається через httpd.conf і може лишитись
    # порожнім (службу не знайдено, DocumentRoot не прочитано) навіть коли
    # локальну синхронізацію ввімкнено — Test-Path з порожнім -LiteralPath
    # кидає виняток, тому перевіряємо це окремо, до першого звернення до диска.
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        return @([pscustomobject]($issueBase + @{
            Reason = "джерело $Label не визначено"
        }))
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        return @([pscustomobject]($issueBase + @{
            Reason = "джерельний каталог $Label не знайдено"
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
                Reason = "джерельний каталог $Label порожній"
            }))
        }
    }

    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
        return @([pscustomobject]($issueBase + @{
            Reason = "локальну копію $Label не знайдено"
        }))
    }

    $robocopyCommand = Get-Command -Name $robocopyPath -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $robocopyCommand) {
        return @([pscustomobject]($issueBase + @{
            Reason = "robocopy не знайдено; локальну $Label не перевірено"
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
                Reason = "перевищено таймаут локальної перевірки $Label ($timeoutSeconds сек.)"
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
                Reason = "локальна копія $Label неактуальна"
                ExitCode = $exitCode
            }))
        }

        Write-HealthLog "Локальна $Label справна: $sourcePath відповідає $destinationPath" -Level "SUCCESS"
        return @()
    } catch {
        return @([pscustomobject]($issueBase + @{
            Reason = "не вдалося порівняти локальну $Label`: $($_.Exception.Message)"
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
    # correctness pass: якщо ВСІ кандидати провалюються, викликач (preflight)
    # повинен мати змогу класифікувати ПЕРВИННУ причину (privilege чи ні) —
    # первинний кандидат <RuntimeRoot>\TEMP відповідає реальному сценарію
    # дефекту (D:\BRAVO\TEMP). Перший captured exception, не останній.
    $firstCreationException = $null
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
            if ($null -eq $firstCreationException) {
                $firstCreationException = $_.Exception
            }
        }
    }

    $details = if ($creationErrors.Count -gt 0) {
        "; " + ($creationErrors -join "; ")
    } else {
        ""
    }
    $aggregateMessage = (
        "не знайдено доступного ASCII-каталогу для тимчасових файлів " +
        "WinSCP$details"
    )
    # Типізований виняток (наприклад UnauthorizedAccessException створення
    # <RuntimeRoot>\TEMP) зберігається як InnerException — інакше
    # Test-BRAVOHealthIsPrivilegeException (яка йде саме по InnerException
    # chain) на виклику ззовні не мала б звідки його прочитати.
    if ($null -ne $firstCreationException) {
        throw (New-Object System.Management.Automation.RuntimeException(
            $aggregateMessage, $firstCreationException))
    }
    throw $aggregateMessage
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

# correctness pass: не кожна помилка запису означає "потрібні права
# адміністратора" — диск може бути повний, шлях зіпсований, файлова
# система пошкоджена. UnauthorizedAccessException (і лише воно, у всьому
# ланцюжку InnerException — той самий підхід, що Test-BRAVOHealthElevationCancelled
# у BRAVO_HEALTH.ps1 для Win32Exception 1223) — єдина категорія, яку чесно
# можна назвати "недостатньо прав".
function Test-BRAVOHealthIsPrivilegeException {
    param($Exception)

    $currentException = $Exception
    while ($null -ne $currentException) {
        if ($currentException -is [System.UnauthorizedAccessException]) {
            return $true
        }
        $currentException = $currentException.InnerException
    }
    return $false
}

# dev.13: ручний non-elevated запуск міг ЛИСТИНГУВАТИ D:\BRAVO\LOGS/TEMP
# (каталог уже існує — його створив SYSTEM), але не мати права запису в
# нього. Get-BRAVOHealthTemporaryRoot вище лише створює каталог, якщо його
# немає — якщо він уже існує, write-доступ ніколи не перевіряється, і
# AccessDenied спливає лише глибоко всередині SFTP-етапу (New-Item під lcd
# WinSCP), де стає фальшивою "SFTP недоступний". Ця функція перевіряє
# WRITE, а не лише EXISTS: створює унікальний probe-файл і одразу прибирає
# його в finally.
function Test-BRAVOHealthRuntimePathWritable {
    param([Parameter(Mandatory = $true)][string]$Path)

    $probeName = "BRAVO_HEALTH_PREFLIGHT_{0}.tmp" -f ([guid]::NewGuid().ToString("N"))
    $probePath = $null
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $probePath = Join-Path $Path $probeName
        [System.IO.File]::WriteAllText($probePath, [string]([guid]::NewGuid()))
        return [pscustomobject]@{ IsWritable = $true; ErrorMessage = $null; IsPrivilegeFailure = $false }
    } catch {
        return [pscustomobject]@{
            IsWritable = $false
            ErrorMessage = $_.Exception.Message
            IsPrivilegeFailure = (Test-BRAVOHealthIsPrivilegeException -Exception $_.Exception)
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($probePath)) {
            Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Обидва шляхи, від яких залежить сам Health (не бізнес-логіка backup) —
# лог і тимчасовий каталог WinSCP — перевіряються ДО будь-якого реального
# health-check (служби/локальні копії/SFTP/SMB), а не під час SFTP-етапу.
function Test-BRAVOHealthEnvironmentPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$TemporaryRoot
    )

    foreach ($candidatePath in @($LogPath, $TemporaryRoot)) {
        $probeResult = Test-BRAVOHealthRuntimePathWritable -Path $candidatePath
        if (-not $probeResult.IsWritable) {
            return [pscustomobject]@{
                IsWritable = $false
                FailedPath = $candidatePath
                ErrorMessage = $probeResult.ErrorMessage
                IsPrivilegeFailure = $probeResult.IsPrivilegeFailure
            }
        }
    }
    return [pscustomobject]@{ IsWritable = $true; FailedPath = $null; ErrorMessage = $null; IsPrivilegeFailure = $false }
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

    # Найважливіша умова: не запускати інструменти, цілісність яких не
    # підтверджена. Небезпека не в тому, що Health кудись пише (він
    # read-only), а в САМОМУ запуску WinSCP.com / завантаженні
    # WinSCPnet.dll: підмінений бінарник виконає довільний код з правами
    # облікового запису запланованого завдання (SYSTEM), і read-only
    # перевірка стає повноцінним носієм шкідливого коду.
    #
    # Локальні перевірки (служби, диски, вік локальних копій) Tools не
    # запускають і виконуються далі — саме вони й лишаються корисними,
    # коли SFTP-гілку заблоковано.
    if ($null -ne $script:BRAVOToolManifest -and $script:BRAVOToolManifest.ShouldBlock) {
        $errors += (
            "SFTP-перевірки пропущено: не підтверджено цілісність інструментів " +
            "(запуск WinSCP заборонено). $($script:BRAVOToolManifest.Message)"
        )
    }

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

    $components = Get-BRAVOWinSCPDotNetComponents `
        -WinSCPAssemblyPath ([string]$winSCPAssemblyPath) `
        -WinSCPPath ([string]$winSCPPath)
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
            # Санітизуємо тут же, у джерелі, а не покладаємось на те, що
            # кожен майбутній споживач цього поля сам згадає викликати
            # Get-SanitizedWinSCPDiagnostic перед логуванням/сповіщенням.
            Output = Get-SanitizedWinSCPDiagnostic -Text $output
            ErrorOutput = Get-SanitizedWinSCPDiagnostic -Text $errorOutput
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
    # @() ЗОВНІ if/else: у Windows PowerShell 5.1 if/else-вираз розгортає
    # одноелементний результат у скаляр (1 знайдений файл -> FileInfo), а
    # порожній -> $null — в обох випадках $createdFiles.Count нижче кидав
    # PropertyNotFoundException під Set-StrictMode -Version 2.0 замість
    # graceful-діагностики $downloadError (той самий клас, що
    # production-інцидент 2026-08-19 у Get-BRAVOArchiveFreeSpaceResult;
    # обидва fallback-кейси відтворені детерміновано).
    $createdFiles = @(if (Test-Path `
        -LiteralPath $ArchiveCheck.RemoteHashDownloadDirectory `
        -PathType Container) {
        Get-ChildItem `
            -LiteralPath $ArchiveCheck.RemoteHashDownloadDirectory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.PSIsContainer -and
                $_.Name -ceq "$($ArchiveCheck.LocalArchive.Name)$hashFileExtension"
            }
    })
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
                    # INFO, не WARNING: перевірка все одно УСПІШНА (через
                    # .sha512-файл) — це нотатка про метод, яким сервер не
                    # підтримує обчислення контрольної суми на своїй стороні,
                    # а не привід для уваги оператора.
                    Write-HealthLog (
                        "SFTP $($ArchiveDefinition.Type): серверний SHA архіву недоступний; " +
                        "використано повний збіг віддаленого hash-файлу"
                    ) -Level "INFO"
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
        $remoteAge = Get-BRAVOUtcAge `
            -Timestamp ([datetime]$remoteLastWriteTime) `
            -NowUtc $healthCheckStartedUtc
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
    $pendingAge = Get-BRAVOUtcAge `
        -Timestamp ([datetime]$PreviewSummary.OldestLastWriteTime) `
        -NowUtc $healthCheckStartedUtc
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

    $components = Get-BRAVOWinSCPDotNetComponents `
        -WinSCPAssemblyPath ([string]$winSCPAssemblyPath) `
        -WinSCPPath ([string]$winSCPPath)
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
    # componentSettings.SFTP.Enabled=false (5.2.2): глобальний вимикач
    # перевіряється ПЕРШИМ, до backupMonitoring.SFTP.Enabled — не лише
    # блокує читання/сповіщення про SFTP-стан, а й запобігає реальному
    # BAZA-sync нижче в цій функції (SynchronizeBeforeHealth відкриває
    # WinSCP-сесію через Invoke-BRAVOBazaComponentSyncSession).
    if (-not [bool]$storageEffective.SFTP.Enabled) {
        Write-HealthLog "SFTP health-check пропущено: $([string]$storageEffective.SFTP.DisabledReason)" -Level "INFO"
        return @()
    }
    if (-not $backupMonitoring.SFTP.Enabled) {
        Write-HealthLog "Незалежну SFTP-перевірку вимкнено в конфігурації" -Level "INFO"
        return @()
    }

    $checkArchives = [bool]$backupMonitoring.SFTP.CheckArchiveUploads -and
        [bool]$componentSettings.SFTP.ArchiveUpload
    $checkBAZA = [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaAppSFTPHealthEnabled
    $checkBAZAWWW = [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled

    if (-not $checkArchives -and -not $checkBAZA -and -not $checkBAZAWWW) {
        Write-HealthLog "SFTP health-check не потрібний: компоненти віддаленої передачі вимкнено" -Level "INFO"
        return @()
    }

    # 5.2.1 (реальний алерт SERV_HRDL_1 23:03): активний WinSCP.com іншої
    # BRAVO-операції (паралельна передача/затяжна синхронізація) робив
    # SFTP-перевірку CRITICAL «ПОТРІБНА ДІЯ», хоча це transient-конкуренція,
    # а не збій SFTP. Тепер зайнятий WinSCP = ВІДКЛАДЕННЯ: WARNING у лозі
    # (exit 10/ЧАСТКОВО, жовте сповіщення), кроки SFTP — SKIPPED, наступний
    # health-прогін (кожні 4 год) перевірить знову. Довго висячий процес
    # видно з PID у попередженні — його завершує оператор. Fail-closed не
    # втрачено: реальна відсутність свіжих копій на SFTP почервоніє, щойно
    # WinSCP звільниться і перевірка виконається.
    $sftpWinScpAvailability = Test-BRAVOWinSCPAvailable -WinSCPPath $winSCPPath
    if (-not $sftpWinScpAvailability.Available) {
        $script:BRAVOHealthSftpCheckDeferredByBusyWinSCP = $true
        Write-HealthLog (
            (Get-BRAVOWinSCPBusyMessage -Availability $sftpWinScpAvailability -Operation "SFTP health-check") +
            " — перевірку відкладено до наступного health-прогону (ймовірно, триває інша передача BRAVO); " +
            "якщо процес WinSCP.com висить довго — завершіть його вручну"
        ) -Level "WARNING"
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
            $generationArchive = $script:healthLatestArchives[[string]$archiveDefinition.Type]
            if ($null -eq $generationArchive -or
                -not (Test-Path -LiteralPath ([string]$generationArchive.FullName) -PathType Leaf)) {
                $issues += [pscustomobject]@{
                    Kind = 'SFTPArchive'
                    Component = "SFTP $($archiveDefinition.Type)"
                    Reason = 'перевірку пропущено: component відсутній у verified COMPLETE local generation'
                    FileName = 'немає даних'
                    LastWriteTime = $null
                    SizeBytes = $null
                    ExpectedSizeBytes = $null
                    ActualSizeBytes = $null
                    Location = [string]$sftpDirectories[$archiveDefinition.Type]
                }
                continue
            }
            $localGenerationArchive = Get-Item -LiteralPath ([string]$generationArchive.FullName)

            $remoteDirectory = Normalize-SFTPPath $sftpDirectories[$archiveDefinition.Type]
            $archiveChecks += [pscustomobject]@{
                Definition = $archiveDefinition
                LocalArchive = $localGenerationArchive
                RemoteDirectory = $remoteDirectory
                RemoteHashDownloadDirectory = Join-Path `
                    $healthTemporaryRoot `
                    ("BRAVO_HEALTH_{0}" -f [guid]::NewGuid().ToString("N"))
                RemoteHashDownloadPath = $null
            }
            $archiveChecks[-1].RemoteHashDownloadPath = Join-Path `
                $archiveChecks[-1].RemoteHashDownloadDirectory `
                "$($localGenerationArchive.Name)$hashFileExtension"
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
            Name = "BAZA APP"
            Component = "SFTP BAZA APP"
            ComponentKey = "BAZA_APP"
            LocalPath = [string]$bazaAppPaths.Source
            RemotePath = Normalize-SFTPPath $sftpDirectories.BAZA
            DetectionError = $null
        }
    }
    if ($checkBAZAWWW) {
        $folderSynchronizationChecks += [pscustomobject]@{
            Name = "BAZA WWW"
            Component = "SFTP BAZA WWW"
            ComponentKey = "BAZA_WWW"
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
        } elseif (Test-BRAVOBazaIncrementalModeEnabled) {
            # Incremental append-only fast path (safety-review ТЗ п.2/п.8):
            # SYNC -> VERIFY -> HEALTH RESULT з уже готового SyncResult, а
            # не нове повне порівняння дерева. ONE synchronization (ТЗ п.9):
            # якщо Archive ЩОЙНО передав SyncResult у ЦЬОМУ ж прогоні
            # (script:bazaSyncResults) — переоцінюємо його; інакше (справді
            # standalone BRAVO_HEALTH.ps1) виконуємо ОДИН incremental sync
            # самі. Bootstrap НЕ виконується тут навмисно: перший (дорогий)
            # цикл — виключно відповідальність BRAVO_ARCHIV, який завжди
            # виконується першим за розкладом; якщо стану справді ще немає
            # (Archive жодного разу не запускався), SyncResult.Status=ERROR
            # чесно про це повідомить, а не мовчки перезавантажить 50+ GB.
            # StateRoot -- та сама canonical точка (Get-BRAVOBazaSettingsEffective,
            # BRAVO.ArchiveRuntime), що й Archive: інакше можливий
            # BAZA.StateRoot override спричинив би, що Archive і Health
            # тихо пишуть/читають ДВА РІЗНІ файли стану того самого
            # компонента.
            $bazaSettingsEffective = Get-BRAVOBazaSettingsEffective
            $bazaSyncResult = $null
            if ($null -ne $script:bazaSyncResults -and
                $script:bazaSyncResults.ContainsKey($folderCheck.ComponentKey)) {
                $bazaSyncResult = $script:bazaSyncResults[$folderCheck.ComponentKey]
            }
            if ($null -eq $bazaSyncResult) {
                # Acceptance DEV-LIMS (2026-08-13, знахідка #5): .NET-асемблі
                # потрібен winscp.exe, а $winSCPPath — це Tools\WinSCP.com;
                # цей fallback-шлях зазвичай не виконується (Health
                # переви­користовує SyncResult від Archive), тому дефект
                # виринув лише коли Archive пропустив BAZA через збій
                # SFTP-автентифікації, і його зловив fail-fast guard
                # session-функції. Резолвимо ТУ САМУ пару dll+exe, що й
                # Archive-wiring (Invoke-BRAVOBazaIncrementalSync).
                $winSCPComponents = Get-BRAVOWinSCPDotNetComponents `
                    -WinSCPAssemblyPath ([string]$winSCPAssemblyPath) `
                    -WinSCPPath ([string]$winSCPPath)
                if ($null -eq $winSCPComponents) {
                    $bazaSyncResult = New-BRAVOBazaSyncResult `
                        -Component $folderCheck.ComponentKey `
                        -CycleId (New-BRAVOBazaCycleId) `
                        -StartedUtc (Get-Date).ToUniversalTime() `
                        -CutoffUtc (Get-Date).ToUniversalTime()
                    $bazaSyncResult.Status = 'ERROR'
                    $bazaSyncResult.Error = 'не знайдено сумісну пару WinSCPnet.dll та WinSCP.exe для incremental BAZA sync'
                    $bazaSyncResult.CompletedUtc = (Get-Date).ToUniversalTime()
                } else {
                    $bazaSyncResult = Invoke-BRAVOBazaComponentSyncSession `
                        -Component $folderCheck.ComponentKey `
                        -LocalDirectory $folderCheck.LocalPath `
                        -RemoteRootPath $folderCheck.RemotePath `
                        -RepositorySFTPUrl $sftpUrl `
                        -HostKey $sftpHostKey `
                        -WinSCPAssemblyPath $winSCPComponents.AssemblyPath `
                        -WinSCPExecutablePath $winSCPComponents.ExecutablePath `
                        -StateRoot $bazaSettingsEffective.StateRoot `
                        -ConnectionTimeoutSeconds $sftpConnectionTimeoutSeconds `
                        -OperationTimeoutSeconds ([math]::Max(1, [int]$backupMonitoring.SFTP.OperationTimeoutSeconds)) `
                        -MutationPolicy $bazaSettingsEffective.MutationPolicy `
                        -AutoArchiveMutationThreshold $bazaSettingsEffective.AutoArchiveMutationThreshold `
                        -WriteCheckpoint
                }
            }
            $bazaSyncResult = Update-BRAVOBazaSyncResultNewAfterCutoff `
                -SyncResult $bazaSyncResult `
                -LocalDirectory $folderCheck.LocalPath `
                -StateRoot $bazaSettingsEffective.StateRoot
            $fastHealthResult = Get-BRAVOBazaFastHealthResult -SyncResult $bazaSyncResult
            if (-not $fastHealthResult.Healthy) {
                $issues += [pscustomobject]@{
                    Kind = "SFTPSynchronization"
                    Component = $folderCheck.Component
                    Reason = $fastHealthResult.Message
                    FileName = "немає даних"
                    LastWriteTime = $null
                    SizeBytes = $null
                    DifferenceCount = $null
                    Details = @()
                    Location = $folderCheck.RemotePath
                }
            } else {
                # SKIPPED_CONCURRENT (інший процес синхронізує зараз) — INFO,
                # не SUCCESS: healthy, але не є підтвердженням актуальності копії.
                $healthyLogLevel = if ($fastHealthResult.Level -eq 'INFO') { "INFO" } else { "SUCCESS" }
                Write-HealthLog $fastHealthResult.Message -Level $healthyLogLevel
                foreach ($infoLine in @($fastHealthResult.Info)) {
                    Write-HealthLog "SFTP $($folderCheck.Name): $infoLine" -Level "INFO"
                }
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
    # componentSettings.SMB.Enabled=false (5.2.2): глобальний вимикач
    # перевіряється ПЕРШИМ, до backupMonitoring.SMB.Enabled — жодного
    # New-PSDrive/UNC-звернення для глобально вимкненого destination.
    if (-not [bool]$storageEffective.SMB.Enabled) {
        Write-HealthLog "NAS/SMB health-check пропущено: $([string]$storageEffective.SMB.DisabledReason)" -Level "INFO"
        return @()
    }
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
            $generationArchive = $script:healthLatestArchives[[string]$archiveDefinition.Type]
            if ($null -eq $generationArchive -or
                -not (Test-Path -LiteralPath ([string]$generationArchive.FullName) -PathType Leaf)) {
                $issues += [pscustomobject]@{
                    Kind = 'SMBArchive'
                    Component = "NAS/SMB $($archiveDefinition.Type)"
                    Reason = 'перевірку пропущено: component відсутній у verified COMPLETE local generation'
                    FileName = 'немає даних'
                    LastWriteTime = $null
                    SizeBytes = $null
                    ExpectedSizeBytes = $null
                    ActualSizeBytes = $null
                    Location = [string]$smbSettings.RootPath
                }
                continue
            }
            $localArchive = Get-Item -LiteralPath ([string]$generationArchive.FullName)

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
                (Get-BRAVOUtcAge `
                    -Timestamp ([datetime]$remoteLastWriteTime) `
                    -NowUtc $healthCheckStartedUtc).TotalHours -gt
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
    if ($bazaAppLocalHealthEnabled -or $bazaAppSFTPHealthEnabled) {
        $componentNames += "BAZA_APP"
    }
    if ($bazaWWWSFTPHealthEnabled -or $bazaWWWLocalHealthEnabled) {
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
                $issueActionCounts = Get-BRAVOHealthIssueActionCounts -Issue $Issue
                if ($null -ne $issueActionCounts) {
                    $actionParts = @()
                    if ([int]$issueActionCounts.New -gt 0) {
                        $actionParts += "відсутніх: $($issueActionCounts.New)"
                    }
                    if ([int]$issueActionCounts.Updated -gt 0) {
                        $actionParts += "застарілих: $($issueActionCounts.Updated)"
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
            $issueActionCounts = Get-BRAVOHealthIssueActionCounts -Issue $Issue
            if ($null -ne $issueActionCounts) {
                if ([int]$issueActionCounts.New -gt 0) {
                    $actionParts += "нових: $($issueActionCounts.New)"
                }
                if ([int]$issueActionCounts.Updated -gt 0) {
                    $actionParts += "змінених: $($issueActionCounts.Updated)"
                }
                if ([int]$issueActionCounts.RemoteExtra -gt 0) {
                    $actionParts += "зайвих у хмарі: $($issueActionCounts.RemoteExtra)"
                }
                if ([int]$issueActionCounts.Other -gt 0) {
                    $actionParts += "очікують передачі: $($issueActionCounts.Other)"
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

# Операторська консоль ("Проблеми:" в РЕЗУЛЬТАТ) повторно використовує ці
# самі Format-Compact*-форматтери замість власної класифікації WARNING/ERROR
# — одна й та сама проблема має показувати однаковий рівень серйозності і в
# Slack-сповіщенні, і в консолі. Service/невідомі Kind не мають окремого
# форматтера (див. New-SlackAlertMessage нижче) — там завжди ":x:".
function Get-BRAVOHealthConsoleIssueLine {
    param([Parameter(Mandatory = $true)][object]$Issue)

    $compactText = switch ($Issue.Kind) {
        { $_ -in @('LocalBackup', 'LocalSynchronization') } { Format-CompactLocalIssue -Issue $Issue }
        { $_ -in @('SFTPArchive', 'SFTPSynchronization', 'SFTPConnection') } { Format-CompactSFTPIssue -Issue $Issue }
        { $_ -in @('SMBArchive', 'SMBConnection') } { Format-CompactSMBIssue -Issue $Issue }
        default { ":x: $($Issue.Component) — $($Issue.Reason)" }
    }

    $severity = if ($compactText.StartsWith(':warning:')) { 'WARNING' } else { 'ERROR' }
    $text = $compactText -replace '^:(warning|x):\s*', ''
    $separatorIndex = $text.IndexOf(' — ')
    if ($separatorIndex -ge 0) {
        $component = $text.Substring(0, $separatorIndex)
        $detail = $text.Substring($separatorIndex + 3)
    } else {
        $component = $text
        $detail = $null
    }
    return [pscustomobject]@{ Severity = $severity; Component = $component; Detail = $detail }
}

function Get-BRAVOHealthLatestBackupSummary {
    $archives = @(
        $archiveDefinitions |
            Where-Object { $_.Enabled } |
            ForEach-Object {
                $archiveInfo = $script:healthLatestArchives[$_.Type]
                if ($null -ne $archiveInfo -and $null -ne $archiveInfo.LastWriteTime) {
                    [pscustomobject]@{
                        Type = [string]$_.Type
                        LastWriteTime = [datetime]$archiveInfo.LastWriteTime
                        SizeBytes = $archiveInfo.SizeBytes
                        GenerationId = [string]$archiveInfo.GenerationId
                    }
                }
            }
    )
    if ($archives.Count -eq 0) {
        return [pscustomobject]@{
            Found = $false
            TimestampText = "не знайдено"
            AgeText = "немає даних"
            ComponentLines = @()
        }
    }

    $latestTimestamp = @($archives | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0].LastWriteTime
    $componentLines = @(
        $archives |
            Sort-Object Type |
            ForEach-Object {
                $sizeText = if ($null -ne $_.SizeBytes) { Format-FileSize -Bytes ([long]$_.SizeBytes) } else { "розмір невідомий" }
                Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":package:" -Name $_.Type -Detail $sizeText
            }
    )
    # dev.17: $latestTimestamp — це $generation.CreatedAtUtc (нормалізовано
    # через ConvertTo-BRAVOUtcDateTime, Kind=Utc). Age (AgeText нижче)
    # правильно рахується у UTC-арифметиці й лишається незмінним. Але
    # human-facing TimestampText раніше форматував це саме UTC-значення
    # напряму — оператор бачив UTC замість локального часу сервера
    # (реальний DEV-LIMS acceptance: generation 18:57 local показувалась
    # як 15:57). Конвертація в локальний час сервера — єдина зміна:
    # внутрішня модель лишається UTC, сама конвертація відбувається лише
    # тут, у presentation layer, в ОДНІЙ спільній точці для обох
    # notification-повідомлень
    # ("Остання резервна копія"/"Остання успішна резервна копія" — обидва
    # читають TimestampText із цього самого summary).
    $localTimestamp = $latestTimestamp.ToLocalTime()
    return [pscustomobject]@{
        Found = $true
        Timestamp = $latestTimestamp
        TimestampText = $localTimestamp.ToString("dd.MM.yyyy HH:mm")
        AgeText = Format-BackupAge -LastWriteTime $latestTimestamp -NowUtc $healthCheckStartedUtc
        ComponentLines = $componentLines
    }
}

function Get-BRAVOHealthIssueActionText {
    param([array]$Issues)

    $firstIssue = @($Issues | Select-Object -First 1)
    if ($firstIssue.Count -eq 0) {
        return "перевірити журнал BRAVO_HEALTH"
    }
    # Issue може нести ВЛАСНИЙ ActionText (watchdog-issues: Component там —
    # опис події, не ім'я служби, і шаблон «запустити або перевірити службу
    # <Component>» давав зламану фразу «...службу Служби після аварії...»).
    if ($null -ne $firstIssue[0].PSObject.Properties['ActionText'] -and
        -not [string]::IsNullOrWhiteSpace([string]$firstIssue[0].ActionText)) {
        return [string]$firstIssue[0].ActionText
    }
    switch ([string]$firstIssue[0].Kind) {
        "Service" { return "запустити або перевірити службу $($firstIssue[0].Component)" }
        { $_ -in @("LocalBackup", "LocalBackupGeneration") } { return "перевірити виконання BRAVO_ARCHIV" }
        { $_ -in @("SFTPArchive", "SFTPSynchronization", "SFTPConnection") } { return "перевірити SFTP-з'єднання та останній запуск BRAVO_ARCHIV" }
        { $_ -in @("SMBArchive", "SMBConnection") } { return "перевірити NAS/SMB доступ і останній запуск BRAVO_ARCHIV" }
        default { return "перевірити журнал BRAVO_HEALTH" }
    }
}

function New-SlackAlertMessage {
    param(
        [array]$Issues,
        [timespan]$Duration
    )

    $hostInformation = Get-HostInformation
    $archiveVersionText = [string]$global:ScriptVersion
    $archiveBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$global:ScriptBuildId)) {
        "невідома"
    } else {
        [string]$global:ScriptBuildId
    }
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

    $operationTitle = if ($serviceIssues.Count -gt 0 -and $serviceIssues.Count -eq $Issues.Count) {
        "BRAVO SERVICES — ПОТРІБНА ДІЯ"
    } else {
        "BRAVO BACKUP — ПОТРІБНА ДІЯ"
    }
    $latestBackup = Get-BRAVOHealthLatestBackupSummary
    # Компактність (запит оператора, DEV-LIMS 2026-08-21): повний Reason
    # з'являється в повідомленні РІВНО ОДИН РАЗ — у тематичній секції нижче.
    # Шапка причин — лише перелік проблемних компонентів одним рядком
    # (до 4 імен, далі «та ще N»); раніше сюди дублювався повний текст
    # першої проблеми, і оператор читав його тричі.
    $reasonLines = New-Object System.Collections.Generic.List[string]
    if ($problemComponentNames.Count -gt 0) {
        $reasonComponentsText = if ($problemComponentNames.Count -le 4) {
            $problemComponentNames -join ' · '
        } else {
            (@($problemComponentNames | Select-Object -First 4) -join ' · ') + " та ще $($problemComponentNames.Count - 4)"
        }
        $reasonLines.Add(":x: $reasonComponentsText")
    }
    $resultLines = New-Object System.Collections.Generic.List[string]
    $resultLines.Add(":clock3: Остання успішна резервна копія: $($latestBackup.TimestampText)")
    if ($latestBackup.Found) {
        $resultLines.Add(":hourglass_flowing_sand: Вік копії: $($latestBackup.AgeText)")
    }
    if ($null -ne $backupMonitoring.MaxBackupAgeHours) {
        $resultLines.Add(":warning: Допустимий вік: $($backupMonitoring.MaxBackupAgeHours) год.")
    }
    $resultLines.Add("")
    # Перелік компонентів уже в шапці причин; тут — лише лічильники
    # (окремий :package:-рядок з тим самим переліком був третім дублем).
    $resultLines.Add(":pushpin: Проблемних компонентів: $($problemComponentNames.Count) · перевірок: $($Issues.Count)")

    if ($serviceIssues.Count -gt 0) {
        $resultLines.Add("")
        $resultLines.Add(":gear: СЛУЖБИ")
        foreach ($issue in $serviceIssues) {
            $resultLines.Add(":x: $($issue.Component) — $($issue.Reason)")
        }
    }

    if ($localIssues.Count -gt 0) {
        $resultLines.Add("")
        $resultLines.Add(":floppy_disk: ЛОКАЛЬНІ БЕКАПИ")
        foreach ($issue in $localIssues) {
            $resultLines.Add((Format-CompactLocalIssue -Issue $issue))
        }
    }

    if ($sftpIssues.Count -gt 0) {
        $resultLines.Add("")
        $resultLines.Add(":cloud: БЕКАПИ У ХМАРІ")
        foreach ($issue in $sftpIssues) {
            $resultLines.Add((Format-CompactSFTPIssue -Issue $issue))
        }
    }

    if ($smbIssues.Count -gt 0) {
        $resultLines.Add("")
        $resultLines.Add(":minidisc: NAS/SMB")
        foreach ($issue in $smbIssues) {
            $resultLines.Add((Format-CompactSMBIssue -Issue $issue))
        }
    }

    if ($otherIssues.Count -gt 0) {
        $resultLines.Add("")
        $resultLines.Add(":warning: ІНШІ ПОМИЛКИ")
        foreach ($issue in $otherIssues) {
            $resultLines.Add(":x: $($issue.Component) — $($issue.Reason)")
        }
    }

    $bazaAppLocalHealthy = $bazaAppLocalHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "Локальна BAZA APP"
        }).Count -eq 0
    $bazaAppSFTPHealthy = [bool]$backupMonitoring.SFTP.Enabled -and
        [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaAppSFTPHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "SFTP BAZA APP" -or $_.Kind -eq "SFTPConnection"
        }).Count -eq 0
    if ($bazaAppLocalHealthy -or $bazaAppSFTPHealthy) {
        $resultLines.Add("")
        if ($bazaAppLocalHealthy -and $bazaAppSFTPHealthy) {
            $resultLines.Add(":white_check_mark: BAZA_APP — локальна копія та SFTP актуальні")
        } elseif ($bazaAppLocalHealthy) {
            $resultLines.Add(":white_check_mark: BAZA_APP — локальна копія актуальна")
        } else {
            $resultLines.Add(":white_check_mark: BAZA_APP — SFTP актуальна")
        }
    }
    $bazaWWWLocalHealthy = $bazaWWWLocalHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "Локальна BAZA WWW"
        }).Count -eq 0
    $bazaWWWSFTPHealthy = [bool]$backupMonitoring.SFTP.Enabled -and
        [bool]$backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled -and
        @($Issues | Where-Object {
            $_.Component -eq "SFTP BAZA WWW" -or
            $_.Kind -eq "SFTPConnection"
        }).Count -eq 0
    if ($bazaWWWLocalHealthy -or $bazaWWWSFTPHealthy) {
        $resultLines.Add("")
        if ($bazaWWWLocalHealthy -and $bazaWWWSFTPHealthy) {
            $resultLines.Add(":white_check_mark: BAZA_WWW — локальна копія та SFTP актуальні")
        } elseif ($bazaWWWLocalHealthy) {
            $resultLines.Add(":white_check_mark: BAZA_WWW — локальна копія актуальна")
        } else {
            $resultLines.Add(":white_check_mark: BAZA_WWW — SFTP актуальна")
        }
    }

    return New-BRAVOOperatorNotificationMessage `
        -Severity "CRITICAL" `
        -Operation $operationTitle `
        -ActionText (Get-BRAVOHealthIssueActionText -Issues $Issues) `
        -ReasonLines $reasonLines.ToArray() `
        -InstitutionName ([string]$backupMonitoring.InstitutionName) `
        -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
        -HostInformation $hostInformation `
        -ResultLines $resultLines.ToArray() `
        -Timestamp $healthCheckStarted `
        -Duration $Duration `
        -ProductName "BRAVO Archive" `
        -Version $archiveVersionText `
        -BuildId $archiveBuildIdText `
        -LogPath $healthLogFile `
        -LogLabel "Журнал"
}

function Get-BRAVOHealthDestinationSummary {
    # Аудит P1.6: раніше health-check повертав лише один агрегований
    # Status/IssueCount — зовнішній моніторинг не міг побачити "локальні
    # копії в порядку, а SFTP деградував" окремо від "усе зламано разом".
    # Кожен вхідний масив уже й так є результатом незалежного виклику
    # (Get-BackupHealthIssues/Get-BAZALocalSyncHealthIssues/Get-SFTPHealthIssues/
    # Get-SMBHealthIssues) — жоден з них не перериває виконання інших при
    # відмові, тому тут лишається тільки звести їх у три прапорці, а не
    # виправляти саму послідовність перевірок.
    [CmdletBinding()]
    param(
        [array]$LocalIssues = @(),
        [array]$BazaLocalIssues = @(),
        [array]$SftpIssues = @(),
        [array]$SmbIssues = @()
    )

    return [pscustomobject]@{
        LocalVerified = (@($LocalIssues) + @($BazaLocalIssues)).Count -eq 0
        SftpVerified = @($SftpIssues).Count -eq 0
        SmbVerified = @($SmbIssues).Count -eq 0
    }
}

function New-SlackSuccessMessage {
    param([timespan]$Duration)

    $hostInformation = Get-HostInformation
    $archiveVersionText = [string]$global:ScriptVersion
    $archiveBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$global:ScriptBuildId)) {
        "невідома"
    } else {
        [string]$global:ScriptBuildId
    }
    $latestBackup = Get-BRAVOHealthLatestBackupSummary
    $resultLines = New-Object System.Collections.Generic.List[string]
    if ($latestBackup.Found) {
        $resultLines.Add(":clock3: Остання резервна копія: $($latestBackup.TimestampText)")
        $resultLines.Add(":hourglass_flowing_sand: Вік копії: $($latestBackup.AgeText)")
        $resultLines.Add("")
    }
    foreach ($componentLine in @($latestBackup.ComponentLines)) {
        $resultLines.Add($componentLine)
    }

    $resultLines.Add("")
    $resultLines.Add((Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":floppy_disk:" -Name "Local"))

    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckArchiveUploads -and
        [bool]$storageEffective.SFTP.ArchiveUpload) {
        $resultLines.Add((Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":cloud:" -Name "SFTP"))
    }
    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaAppSFTPHealthEnabled) {
        $resultLines.Add((Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":arrows_counterclockwise:" -Name "BAZA_APP" -Detail "синхронізовано"))
    }
    if ($backupMonitoring.SFTP.Enabled -and
        $backupMonitoring.SFTP.CheckBAZASynchronization -and
        $bazaWWWSFTPHealthEnabled) {
        $resultLines.Add((Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":arrows_counterclockwise:" -Name "BAZA_WWW" -Detail "синхронізовано"))
    }
    if ($bazaAppLocalHealthEnabled) {
        $resultLines.Add((Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":arrows_counterclockwise:" -Name "BAZA_APP local"))
    }
    if ($bazaWWWLocalHealthEnabled) {
        $resultLines.Add((Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":arrows_counterclockwise:" -Name "BAZA_WWW local"))
    }
    if ($backupMonitoring.SMB.Enabled -and
        $backupMonitoring.SMB.CheckArchiveCopies -and
        [bool]$storageEffective.SMB.ArchiveCopy) {
        $resultLines.Add((Format-BRAVOOperatorStatusLine -Status SUCCESS -Icon ":minidisc:" -Name "SMB"))
    }

    $enabledComponentCount = @(Get-EnabledBackupComponentNames).Count
    if ($enabledComponentCount -gt 0) {
        $resultLines.Add("")
        $resultLines.Add("Компоненти: $enabledComponentCount/$enabledComponentCount")
    }

    return New-BRAVOOperatorNotificationMessage `
        -Severity "SUCCESS" `
        -Operation "BRAVO BACKUP — ВСЕ СПРАВНО" `
        -InstitutionName ([string]$backupMonitoring.InstitutionName) `
        -InstitutionCode ([string]$backupMonitoring.InstitutionCode) `
        -HostInformation $hostInformation `
        -ResultLines $resultLines.ToArray() `
        -Timestamp $healthCheckStarted `
        -Duration $Duration `
        -ProductName "BRAVO Archive" `
        -Version $archiveVersionText `
        -BuildId $archiveBuildIdText `
        -LogPath $healthLogFile `
        -LogLabel "Журнал"
}

# Різні види проблем несуть різний набір полів: об'єкт Kind = "Service"
# не має ні DifferenceCount, ні ActionCounts. Під Set-StrictMode звернення
# до неоголошеної властивості — помилка, тому пряме $_.DifferenceCount
# валило весь runtime із кодом 90 щоразу, коли лежала керована служба:
# замість тривоги «служба не працює» оператор не отримував нічого.
function Get-BRAVOHealthIssueField {
    param([object]$Issue, [string]$Name)

    if ($null -eq $Issue) {
        return ''
    }
    $property = $Issue.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    return [string]$property.Value
}

# ActionCounts — той самий випадок, але для вкладеного об'єкта, а не
# рядка: лише ОДИН з чотирьох способів побудови проблеми
# "SFTPSynchronization" (Get-SFTPHealthIssues, гілка "у хмарі відсутні...")
# насправді встановлює це поле. Три інших ("не вдалося визначити
# локальне джерело", "локальний каталог не знайдено", "не вдалося
# порівняти каталоги") — ні, тому навіть перевірка на порожнечу цього
# поля напряму через крапку під Set-StrictMode падає ще до самого
# порівняння. Реальний випадок: BAZA-SFTP синхронізація увімкнена, а
# локальний каталог BAZA відсутній — Archive ловив це як "Помилка
# запуску окремого health-check: The property 'ActionCounts' cannot be
# found".
function Get-BRAVOHealthIssueActionCounts {
    param([object]$Issue)

    if ($null -eq $Issue) {
        return $null
    }
    $property = $Issue.PSObject.Properties['ActionCounts']
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
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
            $issue = $_
            $actionCounts = $issue.PSObject.Properties['ActionCounts']
            $actionValues = if ($null -eq $actionCounts -or $null -eq $actionCounts.Value) {
                @('', '', '', '')
            } else {
                @(
                    (Get-BRAVOHealthIssueField -Issue $actionCounts.Value -Name 'New'),
                    (Get-BRAVOHealthIssueField -Issue $actionCounts.Value -Name 'Updated'),
                    (Get-BRAVOHealthIssueField -Issue $actionCounts.Value -Name 'RemoteExtra'),
                    (Get-BRAVOHealthIssueField -Issue $actionCounts.Value -Name 'Other')
                )
            }
            $fields = @(
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'Kind'),
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'Component'),
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'Reason'),
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'FileName'),
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'LastWriteTime'),
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'Location'),
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'DifferenceCount'),
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'ExpectedSizeBytes'),
                (Get-BRAVOHealthIssueField -Issue $issue -Name 'ActualSizeBytes')
            ) + $actionValues
            $fields -join '|'
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

function Get-BRAVOHealthSuccessNotificationState {
    # Стан попереднього фактично відправленого success-звіту:
    # @{ Age = [timespan]; Fingerprint = [string]|$null } або $null.
    # Відсутній/нечитабельний/битий стан = fail-open ($null): дедуп —
    # зручність, доставка звіту — первинний контракт. Legacy-файл 5.2.1
    # без поля Fingerprint читається (Age валідний), Fingerprint = $null —
    # семантична рівність недоказова, тому такий стан не придушує звіт.
    $statePath = [string]$backupMonitoring.SuccessNotificationStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    try {
        $state = Read-BRAVOTextFile -Path $statePath | ConvertFrom-BRAVOJson
        $lastSent = [datetime]::Parse(
            $state.LastSuccessSentUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        $stateFingerprint = $null
        $fingerprintProperty = $state.PSObject.Properties['Fingerprint']
        if ($null -ne $fingerprintProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$fingerprintProperty.Value)) {
            $stateFingerprint = [string]$fingerprintProperty.Value
        }
        return [pscustomobject]@{
            Age = [datetime]::UtcNow - $lastSent.ToUniversalTime()
            Fingerprint = $stateFingerprint
        }
    } catch {
        Write-HealthLog "Не вдалося прочитати стан попереднього success-звіту (дедуп пропущено, звіт буде відправлено): $($_.Exception.Message)" -Level "WARNING"
        return $null
    }
}

function Get-BRAVOHealthSuccessFingerprint {
    # Семантичний відбиток здорового стану для дедуплікації SUCCESS-звітів.
    # Містить лише verdict-поля, зміна яких означає реальну зміну
    # operational state: прапори підтвердження destination-ів, ознаку
    # відкладеної SFTP-перевірки, набір увімкнених перевірок та ідентичність
    # останніх резервних копій (GenerationId; fallback — UTC-час копії).
    # Волатильні поля (час запуску, тривалість, вік копії, PID) свідомо
    # НЕ входять: старіння тієї самої копії в межах healthy-порогу — не
    # зміна стану. Канонічний рядок детермінований (сортування, InvariantCulture,
    # без hashtable-порядку) і хешується SHA-256 — у state/лог потрапляє
    # лише хеш, жодних секретів чи шляхів.
    param(
        [Parameter(Mandatory = $true)]$DestinationSummary,
        [bool]$SftpDeferred,
        [string[]]$EnabledCheckNames = @(),
        [array]$ArchiveIdentities = @()
    )

    $canonicalLines = New-Object System.Collections.Generic.List[string]
    $canonicalLines.Add('schema=1')
    $canonicalLines.Add("localVerified=$([bool]$DestinationSummary.LocalVerified)")
    $canonicalLines.Add("sftpVerified=$([bool]$DestinationSummary.SftpVerified)")
    $canonicalLines.Add("smbVerified=$([bool]$DestinationSummary.SmbVerified)")
    $canonicalLines.Add("sftpDeferred=$SftpDeferred")
    $canonicalLines.Add('checks=' + ((@($EnabledCheckNames) | Sort-Object) -join ','))
    foreach ($archiveIdentity in @($ArchiveIdentities | Sort-Object -Property Type)) {
        $identityText = if (-not [string]::IsNullOrWhiteSpace([string]$archiveIdentity.GenerationId)) {
            [string]$archiveIdentity.GenerationId
        } elseif ($null -ne $archiveIdentity.LastWriteTime) {
            ([datetime]$archiveIdentity.LastWriteTime).ToUniversalTime().ToString(
                'o', [System.Globalization.CultureInfo]::InvariantCulture)
        } else {
            'unknown'
        }
        $canonicalLines.Add("archive=$([string]$archiveIdentity.Type):$identityText")
    }

    $canonicalText = ($canonicalLines -join "`n")
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonicalText))
    } finally {
        $sha256.Dispose()
    }
    return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-BRAVOHealthSuccessNotificationDecision {
    # Чисте (без I/O) рішення про доставку/придушення SUCCESS-звіту.
    # Викликається лише коли сповіщення взагалі увімкнені. Пріоритети:
    # примус оператора > первинний post-backup звіт > вимкнений дедуп >
    # непідтверджене відновлення (RecoveryPending) > відсутній/недоказовий
    # попередній стан > зміна semantic-стану > вичерпане часове вікно;
    # придушується лише семантично той самий standalone-звіт у межах вікна.
    param(
        [bool]$ForceNotification,
        [bool]$EmbeddedPostBackup,
        [int]$DedupMinutes,
        [bool]$RecoveryPending,
        $PreviousState,
        [string]$CurrentFingerprint
    )

    $decision = { param([bool]$Send, [string]$Reason)
        [pscustomobject]@{ Send = $Send; Reason = $Reason }
    }
    if ($ForceNotification) { return (& $decision $true 'ForceNotification') }
    if ($EmbeddedPostBackup) { return (& $decision $true 'PostBackup') }
    if ($DedupMinutes -le 0) { return (& $decision $true 'DedupDisabled') }
    if ($RecoveryPending) { return (& $decision $true 'Recovery') }
    if ($null -eq $PreviousState) { return (& $decision $true 'NoPreviousState') }
    if ([string]::IsNullOrWhiteSpace([string]$PreviousState.Fingerprint) -or
        [string]$PreviousState.Fingerprint -ne $CurrentFingerprint) {
        return (& $decision $true 'StateChanged')
    }
    if (([timespan]$PreviousState.Age).TotalMinutes -ge $DedupMinutes) {
        return (& $decision $true 'WindowExpired')
    }
    return (& $decision $false 'SameStateWithinWindow')
}

function Save-BRAVOHealthSuccessNotificationState {
    param([string]$Fingerprint)

    $statePath = [string]$backupMonitoring.SuccessNotificationStatePath
    $stateDirectory = Split-Path $statePath -Parent
    if (-not (Test-Path -Path $stateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $state = @{
        LastSuccessSentUtc = [datetime]::UtcNow.ToString("o")
        Fingerprint = [string]$Fingerprint
    } | ConvertTo-BRAVOJson

    $temporaryStatePath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryStatePath,
            $state,
            [System.Text.Encoding]::UTF8
        )
        Move-Item -LiteralPath $temporaryStatePath -Destination $statePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryStatePath) {
            Remove-Item -LiteralPath $temporaryStatePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BRAVOHealthOperationalState {
    # Операційний lifecycle-стан Health, окремий від notification-дедупів:
    # RecoveryPending = «система була unhealthy після останнього
    # ПІДТВЕРДЖЕНОГО оператору відновлення» (факт, а не стан доставки
    # сповіщень). Семантика читання:
    #   файл відсутній  -> RecoveryPending = $false (норма першої інсталяції
    #                      або підтвердженого відновлення — дедуп працює);
    #   файл читається  -> фактичне значення;
    #   файл битий      -> RecoveryPending = $true (fail-open: невідомість
    #                      не має права придушити recovery-звіт; storm
    #                      неможливий — перша ж успішна доставка SUCCESS
    #                      перезапише стан значенням $false).
    $statePath = [string]$backupMonitoring.OperationalStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject]@{ RecoveryPending = $false }
    }
    try {
        $state = Read-BRAVOTextFile -Path $statePath | ConvertFrom-BRAVOJson
        return [pscustomobject]@{
            RecoveryPending = [bool]$state.RecoveryPending
        }
    } catch {
        Write-HealthLog "Не вдалося прочитати операційний стан Health (fail-open: recovery-звіт буде надіслано): $($_.Exception.Message)" -Level "WARNING"
        return [pscustomobject]@{ RecoveryPending = $true }
    }
}

function Save-BRAVOHealthOperationalState {
    param([Parameter(Mandatory = $true)][bool]$RecoveryPending)

    $statePath = [string]$backupMonitoring.OperationalStatePath
    $stateDirectory = Split-Path $statePath -Parent
    if (-not (Test-Path -Path $stateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $stateObject = @{
        RecoveryPending = $RecoveryPending
        UpdatedAtUtc = [datetime]::UtcNow.ToString("o")
    }
    if ($RecoveryPending) {
        $stateObject.LastUnhealthyAtUtc = [datetime]::UtcNow.ToString("o")
    }
    $state = $stateObject | ConvertTo-BRAVOJson

    $temporaryStatePath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryStatePath,
            $state,
            [System.Text.Encoding]::UTF8
        )
        Move-Item -LiteralPath $temporaryStatePath -Destination $statePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryStatePath) {
            Remove-Item -LiteralPath $temporaryStatePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-BRAVOArchiveProcessLockActive {
    # Archive and Maintenance coordinate through the canonical machine-wide
    # lock. Health does not acquire it, but must inspect that same handle so a
    # custom ArchiveRoot/ConfigPath cannot make an active backup invisible.
    $lockPath = [string]$operationLockSettings.Path
    if ([string]::IsNullOrWhiteSpace($lockPath)) {
        throw 'operationLockSettings.Path is not configured'
    }
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

$notificationConfigurationValid = $true
if ($NotificationProvider -notin @("slack", "discord") -or
    $NotificationMode -notin @("none", "errors_only", "all")) {
    $notificationConfigurationValid = $false
} elseif ($NotificationMode -ne "none") {
    # Перевіряються лише ті routes, які реально досяжні за поточного
    # NotificationMode (див. preflight-резолв вище) — так само, як і
    # раніше, коли перевірявся один спільний webhook.
    $requiredNotificationRoutes = @("alerts")
    if ($NotificationMode -eq "all") {
        $requiredNotificationRoutes += "general"
    }
    foreach ($requiredRoute in $requiredNotificationRoutes) {
        $requiredRouteUrl = [string]$script:NotificationWebhookUrls[$requiredRoute]
        if ([string]::IsNullOrWhiteSpace($requiredRouteUrl) -or -not $requiredRouteUrl.StartsWith("https://")) {
            $notificationConfigurationValid = $false
        }
    }
}
if (-not $notificationConfigurationValid) {
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
    # 5.2.1: BAZASync (BRAVO_ARCHIV -SyncBAZA, кожні 4 год о :00) на
    # реальних серверах тримає lock архівації ~16-17 хв і систематично
    # накривав слот Health :15 — КОЖЕН денний health-прогін відкладався без
    # повтору (доведено логами ДНДІЛДВСЕ 25-27.08.2026). Замість негайного
    # відкладення Health обмежено чекає звільнення архівації
    # (schedulerSettings.Health.BusyWaitMinutes, loader-дефолт 60 хв;
    # 0 = стара поведінка) і лише після вичерпання ліміту відкладається
    # до наступного слота, як раніше.
    $busyWaitMinutes = [int]$schedulerSettings.Health.BusyWaitMinutes
    $busyWaitStarted = Get-Date
    $busyWaitDeadline = $busyWaitStarted.AddMinutes($busyWaitMinutes)
    $busyWaitAnnounced = $false
    while ($true) {
        # Два НЕЗАЛЕЖНІ сигнали. Запит стану завдання може впасти (COM/ACL),
        # і тоді єдиним свідченням лишається lock — тому він перевіряється
        # поза тим самим try, а не після невдалого запиту в спільному блоці.
        $backupTaskRunning = $false
        try {
            $backupTaskState = Get-BRAVOScheduledTaskState `
                -TaskPath ([string]$schedulerSettings.TaskPath) `
                -TaskName ([string]$schedulerSettings.Backup.TaskName)
            if (-not $busyWaitAnnounced) {
                Write-HealthLog "Перевірка стану завдання архівації: $($backupTaskState.Provider)" -Level "DEBUG"
            }
            $backupTaskRunning = [bool]$backupTaskState.IsRunning
        } catch {
            Write-HealthLog "Не вдалося прочитати стан завдання архівації; рішення за блокуванням процесу: $($_.Exception.Message)" -Level "WARNING"
        }

        $archiveProcessLockActive = $false
        try {
            $archiveProcessLockActive = Test-BRAVOArchiveProcessLockActive
        } catch {
            Write-HealthLog "Не вдалося перевірити блокування архівації: $($_.Exception.Message)" -Level "WARNING"
        }

        # Рішення й повернення — ПОЗА try: вже ухвалене й залоговане
        # відкладення не має скасовуватись помилкою у формуванні результату.
        # Саме так Health продовжував роботу під час архівації, ковтаючи
        # виняток.
        if (-not ($backupTaskRunning -or $archiveProcessLockActive)) {
            if ($busyWaitAnnounced) {
                $busyWaitedSeconds = [int]((Get-Date) - $busyWaitStarted).TotalSeconds
                Write-HealthLog "Архівація завершилась — health-check продовжується після очікування $busyWaitedSeconds с." -Level "INFO"
            }
            break
        }

        $runningIndicator = if ($backupTaskRunning -and $archiveProcessLockActive) {
            "стан завдання та блокування процесу"
        } elseif ($backupTaskRunning) {
            "стан завдання"
        } else {
            "блокування процесу"
        }
        if ((Get-Date) -ge $busyWaitDeadline) {
            Write-HealthLog "Health-check відкладено: архівація зараз виконується ($runningIndicator)" -Level "INFO"
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "Deferred"
                IssueCount = 0
                Notification = "NotRequired"
                LogPath = $healthLogFile
            })
        }
        if (-not $busyWaitAnnounced) {
            Write-HealthLog "Архівація зараз виконується ($runningIndicator) — health-check зачекає її завершення до $busyWaitMinutes хв." -Level "INFO"
            $busyWaitAnnounced = $true
        }
        Start-Sleep -Seconds 30
    }
}

Write-HealthLog "Конфігурація: $ConfigPath"
Write-HealthLog "Сумісність: Windows $($BRAVOCompatibility.WindowsVersion); PowerShell $($BRAVOCompatibility.PowerShellVersion); WMI=$($BRAVOCompatibility.WmiProvider); JSON=$($BRAVOCompatibility.JsonProvider); завдання=$($BRAVOCompatibility.TaskSchedulerProvider)"
Write-HealthLog "Каталог резервних копій: $backupRootPath"
if ($BRAVOPowerShellUpdate.IsUpdateRecommended) {
    Write-HealthLog $BRAVOPowerShellUpdate.Message -Level "WARNING" -Environmental
}
if ($BRAVOWindowsPatchLevel.IsUpdateRecommended) {
    Write-HealthLog $BRAVOWindowsPatchLevel.Message -Level "WARNING" -Environmental
}
$script:BRAVOOSSupportTier = Get-BRAVOOSSupportTier
Write-HealthLog "Підтримка ОС: $($script:BRAVOOSSupportTier.Tier) — Windows $($script:BRAVOOSSupportTier.OperatingSystem) ($($script:BRAVOOSSupportTier.OperatingSystemVersion), build $($script:BRAVOOSSupportTier.Build)); PowerShell $($script:BRAVOOSSupportTier.PowerShellVersion); .NET release $($script:BRAVOOSSupportTier.DotNetRelease)"
if ($script:BRAVOOSSupportTier.Tier -eq "LegacyBestEffort") {
    Write-HealthLog $script:BRAVOOSSupportTier.Message -Level "WARNING"
} elseif ($script:BRAVOOSSupportTier.Tier -eq "Unsupported") {
    if ($env:BRAVO_ALLOW_UNSUPPORTED_OS -eq "1") {
        Write-HealthLog "$($script:BRAVOOSSupportTier.Message) Продовжено через BRAVO_ALLOW_UNSUPPORTED_OS=1." -Level "WARNING"
    } else {
        Write-HealthLog $script:BRAVOOSSupportTier.Message -Level "ERROR"
        return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
            Status = "ConfigurationError"
            IssueCount = 0
            Notification = "NotRequired"
            LogPath = $healthLogFile
            Error = $script:BRAVOOSSupportTier.Message
        })
    }
}
$script:BRAVOToolIntegrity = Get-BRAVOToolIntegrityRecommendation `
    -ToolPaths @($arcPath, $winSCPPath, $winSCPAssemblyPath) `
    -ManifestPath (Join-Path $toolsPath "TOOLS_INTEGRITY.json")
if ($script:BRAVOToolIntegrity.HasIntegrityIssue) {
    Write-HealthLog $script:BRAVOToolIntegrity.Message -Level "WARNING"
}

# Health — діагностичний, read-only runtime: він НЕ блокує себе, а
# звітує. Саме він має першим помітити підміну й підняти тривогу навіть
# тоді, коли архівація ще не запускалась. Блокують Archive і Maintenance.
# ЄДИНИЙ дозволений виняток з read-only політики —
# Invoke-BRAVOServiceQuiescenceWatchdog: старт служб, перелічених у
# ВЛАСНОМУ осиротілому ownership-маркері BRAVO (аварійне переривання
# Maintenance/DataRestore). Ручні зупинки техпідтримки (без маркера)
# Health ніколи не чіпає.
$script:BRAVOToolManifestMode = 'Enforce'
$script:BRAVOToolManifestPath = Join-Path $toolsPath "TOOLS_MANIFEST.json"
if ($toolIntegritySettings -is [System.Collections.IDictionary]) {
    if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.Mode)) {
        $script:BRAVOToolManifestMode = [string]$toolIntegritySettings.Mode
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$toolIntegritySettings.ManifestPath)) {
        $script:BRAVOToolManifestPath = [string]$toolIntegritySettings.ManifestPath
    }
}
if ($script:BRAVOToolManifestMode -ne 'Enforce') {
    Write-HealthLog (
        "УВАГА: перевірку цілісності інструментів послаблено в конфігурації " +
        "(toolIntegritySettings.Mode = $($script:BRAVOToolManifestMode)). Підміна 7za/WinSCP НЕ заблокує запуск."
    ) -Level "WARNING"
}
$script:BRAVOToolManifest = Test-BRAVOToolManifestIntegrity `
    -ToolsDirectory $toolsPath `
    -ManifestPath $script:BRAVOToolManifestPath `
    -Mode $script:BRAVOToolManifestMode
if (-not $script:BRAVOToolManifest.IsValid) {
    Write-HealthLog $script:BRAVOToolManifest.Message -Level "ERROR"
} elseif (-not [string]::IsNullOrWhiteSpace([string]$script:BRAVOToolManifest.Message)) {
    Write-HealthLog $script:BRAVOToolManifest.Message -Level "WARNING"
}
$bazaAppLocalMode = if ($bazaAppLocalHealthEnabled) { "увімкнено" } else { "вимкнено" }
$bazaAppSFTPMode = if ($bazaAppSFTPHealthEnabled) { "увімкнено" } else { "вимкнено" }
$bazaWWWSFTPMode = if ($bazaWWWSFTPHealthEnabled) { "увімкнено" } else { "вимкнено" }
$bazaWWWLocalMode = if ($bazaWWWLocalHealthEnabled) { "увімкнено" } else { "вимкнено" }
Write-HealthLog (
    "Перевірка BAZA: BAZA_APP_LOCAL = $bazaAppLocalMode; BAZA_APP_SFTP = $bazaAppSFTPMode; " +
    "BAZA_WWW_SFTP = $bazaWWWSFTPMode; BAZA_WWW_LOCAL = $bazaWWWLocalMode"
)
if ($bazaWWWSFTPHealthEnabled -or $bazaWWWLocalHealthEnabled) {
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

# Етап 1 уже відпрацював вище (сумісність, підтримка ОС, цілісність
# інструментів); тут лише його результат для оператора.
$environmentStepStatus = 'OK'
$environmentStepDetails = $null
if ($null -ne $script:BRAVOToolManifest -and -not $script:BRAVOToolManifest.IsValid) {
    $environmentStepStatus = 'ERROR'
    $environmentStepDetails = 'порушено цілісність інструментів'
} elseif ($script:BRAVOOSSupportTier.Tier -ne 'Supported') {
    $environmentStepStatus = 'WARNING'
    $environmentStepDetails = "підтримка ОС: $($script:BRAVOOSSupportTier.Tier)"
}

# dev.13: write-probe у LOGS і TEMP, ДО будь-якого реального health-check
# (служби/локальні копії/SFTP/SMB). Раніше локальна AccessDenied (ручний
# запуск без elevation) спливала лише глибоко всередині SFTP-етапу й
# помилково ставала "SFTP недоступний" — сюди вона не доходить взагалі:
# при провалі преflight нижче SFTP-перевірка не викликається.
$environmentPreflight = try {
    Test-BRAVOHealthEnvironmentPreflight -LogPath $logPath -TemporaryRoot (Get-BRAVOHealthTemporaryRoot)
} catch {
    # Get-BRAVOHealthTemporaryRoot сама кидає виняток, якщо жоден кандидат
    # TEMP не створюється — типізований виняток первинного кандидата
    # (<RuntimeRoot>\TEMP) зберігається як InnerException саме для цього:
    # Test-BRAVOHealthIsPrivilegeException іде по InnerException chain так
    # само, як для прямого провалу Test-BRAVOHealthRuntimePathWritable.
    [pscustomobject]@{
        IsWritable = $false
        FailedPath = 'TEMP'
        ErrorMessage = $_.Exception.Message
        IsPrivilegeFailure = (Test-BRAVOHealthIsPrivilegeException -Exception $_.Exception)
    }
}
if (-not $environmentPreflight.IsWritable) {
    $environmentStepStatus = 'ERROR'
    $environmentStepDetails = if ($environmentPreflight.IsPrivilegeFailure) {
        "недостатньо прав запису: $($environmentPreflight.FailedPath)"
    } else {
        "не вдалося використати $($environmentPreflight.FailedPath)"
    }
}

Write-BRAVOHealthStep `
    -Name 'Середовище й цілісність інструментів' `
    -Status $environmentStepStatus `
    -Details $environmentStepDetails

if (-not $environmentPreflight.IsWritable) {
    if ($environmentPreflight.IsPrivilegeFailure) {
        Write-HealthLog (
            "Недостатньо прав для виконання BRAVO HEALTH: недоступний шлях " +
            "$($environmentPreflight.FailedPath) ($($environmentPreflight.ErrorMessage)). " +
            "Для ручного запуску потрібні права адміністратора. SFTP-перевірка не виконувалась."
        ) -Level "ERROR"
    } else {
        Write-HealthLog (
            "Не вдалося використовувати runtime TEMP/LOGS: " +
            "$($environmentPreflight.FailedPath) ($($environmentPreflight.ErrorMessage)). " +
            "SFTP-перевірка не виконувалась."
        ) -Level "ERROR"
    }

    # Чесне сповіщення: НЕ "SFTP недоступний" (SFTP-перевірка фактично не
    # запускалась), а конкретно "середовище виконання" — і текст різний
    # для privilege/generic, щоб не радити "запустіть адміністратором",
    # коли причина не в правах. Той самий канал і той самий
    # NotificationMode/NoSlack-контракт, що й для Critical нижче — нової
    # notification taxonomy не додається.
    $environmentNotificationStatus = "NotRequired"
    if ((-not $NoSlack) -and ($NotificationMode -ne "none")) {
        $environmentVersionText = [string]$global:ScriptVersion
        $environmentBuildIdText = if ([string]::IsNullOrWhiteSpace([string]$global:ScriptBuildId)) {
            "невідома"
        } else {
            [string]$global:ScriptBuildId
        }
        $environmentActionText = if ($environmentPreflight.IsPrivilegeFailure) {
            "запустити BRAVO HEALTH з правами адміністратора"
        } else {
            "перевірити доступність runtime TEMP/LOGS (диск, шлях, файлова система)"
        }
        $environmentReasonLines = if ($environmentPreflight.IsPrivilegeFailure) {
            @(":x: Середовище виконання — недостатньо прав")
        } else {
            @(":x: Середовище виконання — недоступний TEMP/LOGS")
        }
        $environmentResultLines = if ($environmentPreflight.IsPrivilegeFailure) {
            @(
                "Недоступний шлях: $($environmentPreflight.FailedPath)",
                "SFTP-перевірка не виконувалась."
            )
        } else {
            @(
                "Не вдалося використати: $($environmentPreflight.FailedPath)",
                "Причина: $($environmentPreflight.ErrorMessage)",
                "SFTP-перевірка не виконувалась."
            )
        }
        # Minor 1: якщо сам health-check лог не вдалося створити/писати
        # (той самий провал міг зачепити LOGS), не заявляти в сповіщенні
        # журнал, якого фактично немає.
        $environmentNotificationParameters = @{
            Severity = "CRITICAL"
            Operation = "BRAVO HEALTH — ПОТРІБНА ДІЯ"
            ActionText = $environmentActionText
            ReasonLines = $environmentReasonLines
            InstitutionName = [string]$backupMonitoring.InstitutionName
            InstitutionCode = [string]$backupMonitoring.InstitutionCode
            HostInformation = (Get-HostInformation)
            ResultLines = $environmentResultLines
            Timestamp = $healthCheckStarted
            ProductName = "BRAVO Archive"
            Version = $environmentVersionText
            BuildId = $environmentBuildIdText
        }
        if ($script:BRAVOHealthLogWritable) {
            $environmentNotificationParameters.LogPath = $healthLogFile
        }
        $environmentMessage = New-BRAVOOperatorNotificationMessage @environmentNotificationParameters
        try {
            $environmentRoute = Resolve-BRAVONotificationRoute `
                -Severity "CRITICAL" `
                -NotificationMode $NotificationMode `
                -RoutingTable $backupMonitoring.NotificationRouting
            $environmentChunks = ConvertTo-BRAVONotificationPayloadText -Provider $NotificationProvider -Message $environmentMessage
            Send-BRAVONotificationChunks `
                -Provider $NotificationProvider `
                -WebhookUrl $script:NotificationWebhookUrls[$environmentRoute] `
                -MessageChunks $environmentChunks `
                -TimeoutSeconds $NotificationRequestTimeoutSeconds
            $environmentNotificationStatus = "Sent"
            Write-HealthLog "Сповіщення про недоступність середовища відправлено у $NotificationProviderDisplayName" -Level "SUCCESS"
        } catch {
            $environmentNotificationStatus = "Failed"
            Write-HealthLog "Не вдалося відправити сповіщення про недоступність середовища у ${NotificationProviderDisplayName}: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "EnvironmentError"
        IssueCount = 0
        Notification = $environmentNotificationStatus
        # Minor 1: те саме — консольний підсумок (Write-BRAVOResultFooter)
        # не повинен показувати "Детальний журнал: ..." для файлу, який
        # фактично не був записаний.
        LogPath = $(if ($script:BRAVOHealthLogWritable) { $healthLogFile } else { $null })
        FailedPath = $environmentPreflight.FailedPath
        IsPrivilegeFailure = $environmentPreflight.IsPrivilegeFailure
    })
}

function Get-BRAVOQuiescenceWatchdogAllowedServiceNames {
    # Білий список для watchdog (review F4): маркер — persistent-файл, тобто
    # ВХІД для привілейованого Start-Service. Навіть валідний на вигляд
    # маркер не має права змусити SYSTEM-Health запустити довільну службу:
    # стартувати можна лише канонічні керовані служби з конфігурації
    # (maintenanceSettings.Services — те саме джерело, що в
    # Get-ManagedServiceHealthIssues; BravoWeb резолвиться за кандидатами
    # так само). Конфігурація недоступна -> порожній список -> watchdog
    # відмовляє всім (fail-safe: без керованого набору легітимного маркера
    # існувати не може — його пишуть лише Maintenance/DataRestore, які цю ж
    # конфігурацію читають).
    $allowedServiceNames = @()
    $servicesSettings = $null
    $maintenanceSettingsVariable = Get-Variable -Name maintenanceSettings -ErrorAction SilentlyContinue
    if ($null -ne $maintenanceSettingsVariable -and $null -ne $maintenanceSettingsVariable.Value) {
        $servicesSettings = $maintenanceSettingsVariable.Value.Services
    }
    if ($null -eq $servicesSettings) { return @() }
    foreach ($configuredServiceName in @(
            [string]$servicesSettings.BravoName,
            [string]$servicesSettings.ExchangeApiName
        )) {
        if (-not [string]::IsNullOrWhiteSpace($configuredServiceName)) {
            $allowedServiceNames += $configuredServiceName
        }
    }
    if (Test-BRAVOSettingEnabled -Value $servicesSettings.BravoWebEnabled) {
        foreach ($webCandidate in @($servicesSettings.BravoWebCandidates)) {
            if ([string]::IsNullOrWhiteSpace([string]$webCandidate)) { continue }
            $webService = Get-Service -Name ([string]$webCandidate) -ErrorAction SilentlyContinue
            if ($null -eq $webService) {
                $webService = Get-Service -DisplayName ([string]$webCandidate) -ErrorAction SilentlyContinue
            }
            if ($null -ne $webService) {
                $allowedServiceNames += [string]$webService.Name
            }
        }
    }
    return @($allowedServiceNames)
}

function Invoke-BRAVOServiceQuiescenceWatchdog {
    # ЄДИНИЙ дозволений Health виняток з read-only політики (див. політику
    # нижче в цьому файлі та BRAVO.config): якщо Maintenance/DataRestore
    # зупинив служби, записав ownership-маркер BRAVO_SERVICE_QUIESCENCE.json
    # (BRAVO.System) і загинув ЖОРСТКО (kill/живлення — finally не
    # виконався), цей watchdog запускає РІВНО перелічені в маркері служби.
    # Усі інші випадки читання-тільки:
    #   - маркера немає (служби зупинила техпідтримка вручну) — НІКОЛИ не
    #     стартувати, лише штатний issue "не запущена" нижче;
    #   - власник маркера ЖИВИЙ (pid+processStartTime збігаються) —
    #     обслуговування саме триває, не втручатися;
    #   - restartSuppressed=true (DataRestore лишив служби зупиненими
    #     навмисно, rollback неповний) — не стартувати, CRITICAL-issue про
    #     ручне втручання;
    #   - маркер чужого hostname / невалідний — Read повертає $null, дій
    #     немає.
    # Повертає масив issue-об'єктів у форматі Get-ManagedServiceHealthIssues
    # (аварійне відновлення — теж подія, про яку оператор МУСИТЬ дізнатися).
    $watchdogIssues = @()
    $quiescenceState = $null
    try { $quiescenceState = Read-BRAVOServiceQuiescenceState } catch { $quiescenceState = $null }
    if ($null -eq $quiescenceState) { return @() }

    $ownerAlive = Test-BRAVOProcessAlive `
        -ProcessId ([int]$quiescenceState.pid) `
        -ProcessStartTime ([string]$quiescenceState.processStartTime)
    if ($ownerAlive) {
        Write-HealthLog "Ownership-маркер зупинки служб належить живому процесу $($quiescenceState.owner) (PID $($quiescenceState.pid)) — обслуговування триває, watchdog не втручається" -Level "INFO"
        return @()
    }

    $ownerText = "$($quiescenceState.owner) (PID $($quiescenceState.pid), лог: $($quiescenceState.logFile))"
    if ([bool]$quiescenceState.restartSuppressed) {
        # DataRestore пише маркер suppressed ОДРАЗУ (жорсткий kill посеред
        # деструктивної фази лишає live filesystem у невизначеному стані —
        # автостарт поверх нього неприпустимий), тому suppressed тут означає
        # і аварійно перерваний DataRestore, і незавершений rollback.
        Write-HealthLog "Осиротілий ownership-маркер із restartSuppressed: $ownerText залишив служби зупиненими (аварійно перерваний DataRestore або незавершений rollback — live filesystem може бути в невизначеному стані) — автоматичний старт заборонено, потрібне ручне відновлення (OPERATIONS.md, код 43)" -Level "ERROR"
        $watchdogIssues += [pscustomobject]@{
            Kind = "Service"
            Component = "Служби після аварії $($quiescenceState.owner)"
            # Компактно (запит оператора): одна причина + одна дія + лог.
            # Повний технічний контекст (restartSuppressed, варіанти
            # переривання) лишається в ERROR-рядку Health-логу вище.
            Reason = "перерване відновлення — потрібне РУЧНЕ втручання за кодом 43 (автостарт заборонено); лог: $($quiescenceState.logFile)"
            # Власний ActionText: Component тут — опис події, тому загальний
            # шаблон «запустити або перевірити службу <Component>» непридатний.
            ActionText = "виконати ручне відновлення служб (OPERATIONS.md, код 43)"
            FileName = ""
            LastWriteTime = $null
            Location = [string]$quiescenceState.owner
            SizeBytes = $null
            Details = @()
        }
        return @($watchdogIssues)
    }

    # TOCTOU-guard: між першим Read і Start-Service нижче міг стартувати
    # НОВИЙ власник (записати власний маркер і зупинити служби — Maintenance
    # о 23:55 перетинається з 4-годинним циклом Health). Перечитуємо маркер:
    # якщо він зник або це вже інший маркер (owner/pid/createdAt) — виходимо
    # без жодних дій, аварію опрацює наступний прогін.
    $verificationState = $null
    try { $verificationState = Read-BRAVOServiceQuiescenceState } catch { $verificationState = $null }
    if ($null -eq $verificationState -or
        [string]$verificationState.owner -ne [string]$quiescenceState.owner -or
        ($verificationState.pid -as [int]) -ne ($quiescenceState.pid -as [int]) -or
        [string]$verificationState.createdAt -ne [string]$quiescenceState.createdAt) {
        Write-HealthLog "Ownership-маркер зупинки служб змінився під час перевірки (новий власник активний або маркер зник) — watchdog виходить без дій" -Level "INFO"
        return @()
    }

    Write-HealthLog "Осиротілий ownership-маркер зупинки служб: власник $ownerText мертвий — відновлюю служби зі списку маркера" -Level "WARNING"
    $allowedServiceNames = @(Get-BRAVOQuiescenceWatchdogAllowedServiceNames)
    $startFailures = @()
    $startedServices = @()
    $alreadyRunningServices = @()
    foreach ($markedService in @($quiescenceState.services | Where-Object { [bool]$_.RestartIntent })) {
        $markedName = [string]$markedService.Name
        if (@($allowedServiceNames | Where-Object { $_ -ieq $markedName }).Count -eq 0) {
            # Review F4: маркер вимагає службу поза канонічним керованим
            # набором конфігурації — ознака стороннього редагування файлу.
            # Відмова потрапляє у startFailures: маркер лишається, issue
            # робить подію видимою оператору при кожному прогоні.
            $startFailures += "${markedName}: не входить до керованого набору служб конфігурації — автоматичний старт заборонено (можливе стороннє редагування маркера)"
            Write-HealthLog "Відмовлено у старті служби ${markedName}: її немає в керованому наборі конфігурації (можливе стороннє редагування ownership-маркера)" -Level "ERROR"
            continue
        }
        try {
            $serviceObject = Get-Service -Name $markedName -ErrorAction Stop
            if ($serviceObject.Status -ne 'Running') {
                Start-Service -Name $markedName -ErrorAction Stop
                $startedServices += $markedName
                Write-HealthLog "Службу $markedName відновлено після аварійного переривання $($quiescenceState.owner)" -Level "SUCCESS"
            } else {
                # Review F5: службу, що вже працює, НЕ рапортуємо як
                # «відновлену» — інакше оператор бачить хибний масштаб аварії.
                $alreadyRunningServices += $markedName
                Write-HealthLog "Служба $markedName вже працює — старт після аварійного переривання не потрібен" -Level "INFO"
            }
        } catch {
            $startFailures += "${markedName}: $($_.Exception.Message)"
            Write-HealthLog "Не вдалося відновити службу $markedName після аварійного переривання: $($_.Exception.Message)" -Level "ERROR"
        }
    }
    if ($startFailures.Count -eq 0) {
        try {
            # -ExpectedState: видалити рівно той маркер, за яким діяли; якщо
            # його вже перезаписав новий живий власник — не чіпати.
            $quiescenceMarkerCleared = Clear-BRAVOServiceQuiescenceState -ExpectedState $quiescenceState
            if (-not $quiescenceMarkerCleared) {
                Write-HealthLog "Служби відновлено, але ownership-маркер уже належить іншому власнику — залишено без змін" -Level "WARNING"
            }
        } catch {
            Write-HealthLog "Служби відновлено, але ownership-маркер не видалився: $($_.Exception.Message)" -Level "WARNING"
        }
        $recoveryReportText = if ($startedServices.Count -gt 0 -and $alreadyRunningServices.Count -gt 0) {
            "служби $($startedServices -join ', ') відновлено автоматично (служби $($alreadyRunningServices -join ', ') вже працювали)"
        } elseif ($startedServices.Count -gt 0) {
            "служби $($startedServices -join ', ') відновлено автоматично"
        } else {
            "усі служби з маркера ($($alreadyRunningServices -join ', ')) вже працювали, старт не знадобився"
        }
        $watchdogIssues += [pscustomobject]@{
            Kind = "Service"
            Component = "Аварійне відновлення служб"
            Reason = "$recoveryReportText після аварійного переривання $ownerText — перевірте причину переривання"
            ActionText = "перевірити причину аварійного переривання $($quiescenceState.owner)"
            FileName = ""
            LastWriteTime = $null
            Location = [string]$quiescenceState.owner
            SizeBytes = $null
            Details = @()
        }
    } else {
        # Маркер лишається — наступний Health-прогін повторить спробу.
        $watchdogIssues += [pscustomobject]@{
            Kind = "Service"
            Component = "Аварійне відновлення служб"
            Reason = "після аварійного переривання $ownerText не вдалося відновити: $($startFailures -join '; ') — маркер збережено, наступний Health повторить"
            ActionText = "запустити служби вручну та перевірити ownership-маркер"
            FileName = ""
            LastWriteTime = $null
            Location = [string]$quiescenceState.owner
            SizeBytes = $null
            Details = @()
        }
    }
    return @($watchdogIssues)
}

Write-BRAVOProgressPhase -Phase 'Керовані служби' -PercentComplete 15
$quiescenceWatchdogIssues = @(Invoke-BRAVOServiceQuiescenceWatchdog)
$serviceHealthIssues = @($quiescenceWatchdogIssues) + @(Get-ManagedServiceHealthIssues)
Write-BRAVOHealthStep `
    -Name 'Керовані служби' `
    -Status (Get-BRAVOHealthStepStatus -IssueCount $serviceHealthIssues.Count) `
    -Details (Get-BRAVOHealthCompactIssueDetails -Issues $serviceHealthIssues -EntityProperty 'Location' -Label 'служби')

Write-BRAVOProgressPhase -Phase 'Локальні резервні копії' -PercentComplete 30
$localHealthIssues = @(Get-BackupHealthIssues)
Write-BRAVOHealthStep `
    -Name 'Локальні резервні копії' `
    -Status (Get-BRAVOHealthStepStatus -IssueCount $localHealthIssues.Count) `
    -Details (Get-BRAVOHealthCompactIssueDetails -Issues $localHealthIssues -EntityProperty 'Component' -Label 'компоненти')

# P1.1: вік останньої УСПІШНОЇ перевірки відновлюваності (restore drill,
# BRAVO_RESTORE_TEST.ps1 / задача BRAVO_RESTORE_VERIFY). Оцінка — канонічна
# Get-BRAVORestoreVerifyHealthIssue (BRAVO.RestoreVerify): FAIL останнього
# drill, прострочений/недоведений LastVerifiedAt або пошкоджений state =
# issue (ERROR); ЩЕ ВІДСУТНІЙ state (сервер щойно оновлено, перший
# суботній прогін попереду) = лише environmental-нагадування в журнал —
# інакше кожен сервер тиждень стояв би в ЧАСТКОВО без реальної проблеми.
function Get-RestoreVerifyHealthIssues {
    $restoreVerifyIssues = @()
    $restoreVerifyStatePath = Get-BRAVORestoreVerifyStatePath -StateRoot $stateRoot
    $restoreVerifyStateResult = Get-BRAVORestoreVerifyState -Path $restoreVerifyStatePath
    $restoreVerifyEvaluation = Get-BRAVORestoreVerifyHealthIssue `
        -StateResult $restoreVerifyStateResult `
        -MaxVerificationAgeHours ([int]$restoreVerifySettings.MaxVerificationAgeHours)
    if (-not [string]::IsNullOrWhiteSpace([string]$restoreVerifyEvaluation.Warning)) {
        Write-HealthLog ("Відновлюваність: {0}" -f [string]$restoreVerifyEvaluation.Warning) -Level WARNING -Environmental
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$restoreVerifyEvaluation.Detail)) {
        Write-HealthLog ("Відновлюваність: {0}" -f [string]$restoreVerifyEvaluation.Detail)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$restoreVerifyEvaluation.Issue)) {
        $restoreVerifyIssues += [pscustomobject]@{
            Kind = "RestoreVerify"
            Component = "Restore drill"
            Reason = [string]$restoreVerifyEvaluation.Issue
            ActionText = "запустити BRAVO_RESTORE_TEST.ps1 вручну та перевірити задачу BRAVO_RESTORE_VERIFY (BRAVO_TASKS_DIAGNOSE.ps1)"
            FileName = ""
            LastWriteTime = $null
            Location = $restoreVerifyStatePath
            SizeBytes = $null
            Details = @()
        }
    }
    return @($restoreVerifyIssues)
}

$restoreVerifyHealthIssues = @()
if ($script:BRAVOHealthRestoreVerifyStepEnabled) {
    Write-BRAVOProgressPhase -Phase 'Відновлюваність (restore drill)' -PercentComplete 35
    $restoreVerifyHealthIssues = @(Get-RestoreVerifyHealthIssues)
    Write-BRAVOHealthStep `
        -Name 'Відновлюваність (restore drill)' `
        -Status (Get-BRAVOHealthStepStatus -IssueCount $restoreVerifyHealthIssues.Count) `
        -Details (Get-BRAVOHealthStepDetails -IssueCount $restoreVerifyHealthIssues.Count)
} else {
    Write-HealthLog "Перевірку відновлюваності пропущено: schedulerSettings.RestoreVerify.Enabled = `$false"
}

# dev.16 (review round 3): BAZA_APP і BAZA_WWW локальна копія — незалежні
# dynamic steps (було: один комбінований "BAZA (локальна копія)" рядок,
# що ховав, ЯКИЙ саме компонент має проблему). Той самий "вимкнений
# компонент не займає рядка" принцип; Get-BAZALocalSyncHealthIssues
# викликається так само, як і раніше, для кожного компонента окремо.
Write-BRAVOProgressPhase -Phase 'BAZA_APP (локальна копія)' -PercentComplete 40
$bazaAppLocalHealthIssues = @(Get-BAZALocalSyncHealthIssues `
    -Enabled $bazaAppLocalHealthEnabled `
    -SourcePath $bazaAppPaths.Source `
    -DestinationPath $bazaAppPaths.Destination `
    -Label "BAZA APP")
if ($bazaAppLocalHealthEnabled) {
    Write-BRAVOHealthStep `
        -Name 'BAZA_APP (локальна копія)' `
        -Status (Get-BRAVOHealthStepStatus -IssueCount $bazaAppLocalHealthIssues.Count) `
        -Details (Get-BRAVOHealthStepDetails -IssueCount $bazaAppLocalHealthIssues.Count)
} else {
    # Лише у журнал: вимкнений компонент не займає рядка в консолі.
    Write-HealthLog "Локальну перевірку BAZA APP пропущено: BAZA_APP_LOCAL = `$false"
}

Write-BRAVOProgressPhase -Phase 'BAZA_WWW (локальна копія)' -PercentComplete 50
$bazaWWWLocalHealthIssues = @(Get-BAZALocalSyncHealthIssues `
    -Enabled $bazaWWWLocalHealthEnabled `
    -SourcePath $bazaWWWPaths.Source `
    -DestinationPath $bazaWWWPaths.Destination `
    -Label "BAZA WWW")
if ($bazaWWWLocalHealthEnabled) {
    Write-BRAVOHealthStep `
        -Name 'BAZA_WWW (локальна копія)' `
        -Status (Get-BRAVOHealthStepStatus -IssueCount $bazaWWWLocalHealthIssues.Count) `
        -Details (Get-BRAVOHealthStepDetails -IssueCount $bazaWWWLocalHealthIssues.Count)
} else {
    Write-HealthLog "Локальну перевірку BAZA WWW пропущено: BAZA_WWW_LOCAL = `$false"
}
$bazaLocalHealthIssues = @($bazaAppLocalHealthIssues) + @($bazaWWWLocalHealthIssues)

# dev.16 (review round 3): SFTP розділено на 3 незалежні dynamic steps
# (резервні копії/BAZA_APP/BAZA_WWW). Get-SFTPHealthIssues викликається
# ЯК Є, рівно один раз (той самий WinSCP session/connection contract, той
# самий єдиний виклик Test-SFTPHealthConfiguration всередині) — результат
# лише партиціонується за вже існуючим полем Component. Спільна
# prerequisite-помилка з'єднання (Component == 'SFTP', bez суфікса)
# приєднується до КОЖНОГО увімкненого кроку нижче, щоб оператор бачив її
# на будь-якому увімкненому SFTP-рядку; сирий виняток лишається
# залогованим лише ОДИН раз — усередині самої Get-SFTPHealthIssues.
# $sftpHealthIssues (сирий, неподілений список) і надалі йде в
# $healthIssues/$destinationSummary нижче без змін — critical/notification/
# exit-code семантика не зачеплена.
Write-BRAVOProgressPhase -Phase 'SFTP' -PercentComplete 60
$sftpHealthIssues = @(Get-SFTPHealthIssues)
$sftpArchiveComponentNames = @(@($archiveDefinitions | ForEach-Object { "SFTP $($_.Type)" }) + @('SFTP архіви'))
$sftpSharedIssues = @($sftpHealthIssues | Where-Object { $_.Component -eq 'SFTP' })
$sftpArchivesStepIssues = @($sftpHealthIssues | Where-Object { $_.Component -in $sftpArchiveComponentNames }) + @($sftpSharedIssues)
$sftpBazaAppStepIssues = @($sftpHealthIssues | Where-Object { $_.Component -eq 'SFTP BAZA APP' }) + @($sftpSharedIssues)
$sftpBazaWWWStepIssues = @($sftpHealthIssues | Where-Object { $_.Component -eq 'SFTP BAZA WWW' }) + @($sftpSharedIssues)
# Відкладення через зайнятий WinSCP (5.2.1): кроки SFTP — SKIPPED з
# причиною, а не OK (нічого не перевірено) і не ERROR (це не збій SFTP).
$sftpDeferredDetails = 'відкладено: WinSCP зайнятий іншою операцією'
if ($sftpArchivesHealthEnabled) {
    Write-BRAVOHealthStep `
        -Name 'SFTP: резервні копії' `
        -Status $(if ($script:BRAVOHealthSftpCheckDeferredByBusyWinSCP) { 'SKIPPED' } else { Get-BRAVOHealthStepStatus -IssueCount $sftpArchivesStepIssues.Count }) `
        -Details $(if ($script:BRAVOHealthSftpCheckDeferredByBusyWinSCP) { $sftpDeferredDetails } else { Get-BRAVOHealthStepDetails -IssueCount $sftpArchivesStepIssues.Count })
}
if ($sftpBazaAppHealthEnabled) {
    Write-BRAVOHealthStep `
        -Name 'SFTP: BAZA_APP' `
        -Status $(if ($script:BRAVOHealthSftpCheckDeferredByBusyWinSCP) { 'SKIPPED' } else { Get-BRAVOHealthStepStatus -IssueCount $sftpBazaAppStepIssues.Count }) `
        -Details $(if ($script:BRAVOHealthSftpCheckDeferredByBusyWinSCP) { $sftpDeferredDetails } else { Get-BRAVOHealthStepDetails -IssueCount $sftpBazaAppStepIssues.Count })
}
if ($sftpBazaWWWHealthEnabled) {
    Write-BRAVOHealthStep `
        -Name 'SFTP: BAZA_WWW' `
        -Status $(if ($script:BRAVOHealthSftpCheckDeferredByBusyWinSCP) { 'SKIPPED' } else { Get-BRAVOHealthStepStatus -IssueCount $sftpBazaWWWStepIssues.Count }) `
        -Details $(if ($script:BRAVOHealthSftpCheckDeferredByBusyWinSCP) { $sftpDeferredDetails } else { Get-BRAVOHealthStepDetails -IssueCount $sftpBazaWWWStepIssues.Count })
}
if (-not $sftpArchivesHealthEnabled -and -not $sftpBazaAppHealthEnabled -and -not $sftpBazaWWWHealthEnabled) {
    # componentSettings.SFTP.Enabled=false (5.2.2): та сама "усі кроки
    # вимкнено -> кроки мовчки відсутні" 5.2.1-конвенція (Total нижче не
    # рахує їх, denominator звужується), але причина в лозі відрізняється
    # від "оператор вимкнув усі дочірні прапорці" — явно цитуємо
    # DisabledReason, коли причина саме глобальний вимикач.
    if (-not [bool]$storageEffective.SFTP.Enabled) {
        Write-HealthLog "SFTP health-check пропущено: $([string]$storageEffective.SFTP.DisabledReason)"
    } else {
        Write-HealthLog "SFTP health-check пропущено: усі SFTP-перевірки вимкнено в конфігурації"
    }
}

Write-BRAVOProgressPhase -Phase 'NAS/SMB' -PercentComplete 80
$smbHealthIssues = @(Get-SMBHealthIssues)
if (-not $script:BRAVOHealthSmbStepEnabled -and -not [bool]$storageEffective.SMB.Enabled) {
    Write-HealthLog "NAS/SMB health-check пропущено: $([string]$storageEffective.SMB.DisabledReason)"
}
if ($script:BRAVOHealthSmbStepEnabled) {
    Write-BRAVOHealthStep `
        -Name 'NAS/SMB' `
        -Status (Get-BRAVOHealthStepStatus -IssueCount $smbHealthIssues.Count) `
        -Details (Get-BRAVOHealthStepDetails -IssueCount $smbHealthIssues.Count)
}

Write-BRAVOProgressPhase -Phase 'Сповіщення' -PercentComplete 95
$healthIssues = @($serviceHealthIssues) + @($localHealthIssues) + @($restoreVerifyHealthIssues) + @($bazaLocalHealthIssues) + @($sftpHealthIssues) + @($smbHealthIssues)
$destinationSummary = Get-BRAVOHealthDestinationSummary `
    -LocalIssues $localHealthIssues `
    -BazaLocalIssues $bazaLocalHealthIssues `
    -SftpIssues $sftpHealthIssues `
    -SmbIssues $smbHealthIssues
if ($script:BRAVOHealthSftpCheckDeferredByBusyWinSCP) {
    # Відкладена SFTP-перевірка не має оголошуватись підтвердженою: нуль
    # issues означає «не перевіряли», а не «перевірено успішно».
    $destinationSummary.SftpVerified = $false
}
if (-not [bool]$storageEffective.SFTP.Enabled) {
    # componentSettings.SFTP.Enabled=false (5.2.2): Get-SFTPHealthIssues
    # повертає @() ще до будь-якої перевірки — той самий принцип, що й
    # deferred вище: нуль issues тут означає «глобально вимкнено», а не
    # «перевірено успішно». JSON/notification-споживачі SftpVerified не
    # мають читати відсутність перевірки як підтвердження.
    $destinationSummary.SftpVerified = $false
}
if (-not [bool]$storageEffective.SMB.Enabled) {
    $destinationSummary.SmbVerified = $false
}

if ($healthIssues.Count -eq 0) {
    Write-HealthLog "Усі керовані служби працюють, а локальні, SFTP та NAS/SMB-компоненти мають актуальні резервні копії" -Level "SUCCESS"
    # Recovery-факт живе в окремому операційному стані (RecoveryPending),
    # а не в alert-state: alert-state описує дедуп доставки алертів і
    # очищається нижче незалежно, тоді як RecoveryPending переживає провал
    # доставки recovery-звіту і повторює його на наступних healthy-прогонах,
    # доки відновлення не буде фактично підтверджене оператору.
    $operationalRecoveryPending = [bool](Get-BRAVOHealthOperationalState).RecoveryPending
    Clear-AlertState

    $sendSuccessNotification = (
        ($NotifyOnSuccess -or $ForceNotification) -and
        -not $NoSlack -and
        $NotificationMode -eq "all"
    )
    # 5.2.1: semantic + recovery-aware дедуплікація зелених звітів.
    # Embedded post-backup виклик з Archive (SuppressHeader) не дедупиться —
    # це первинне підтвердження свіжої копії; standalone-прогін мовчить лише
    # коли semantic-стан не змінився, аварії з часу попереднього звіту не
    # було і вікно SuccessDedupMinutes не вичерпане. -ForceNotification —
    # обхід. Fingerprint обчислюється завжди (потрібен і для запису стану
    # після фактичної доставки).
    $successNotificationDisposition = 'NotRequired'
    $successDedupMinutes = [int]$backupMonitoring.SuccessDedupMinutes
    $successEnabledCheckNames = @(
        if ($bazaAppLocalHealthEnabled) { 'baza_app_local' }
        if ($bazaWWWLocalHealthEnabled) { 'baza_www_local' }
        if ($sftpArchivesHealthEnabled) { 'sftp_archives' }
        if ($sftpBazaAppHealthEnabled) { 'sftp_baza_app' }
        if ($sftpBazaWWWHealthEnabled) { 'sftp_baza_www' }
        if ($script:BRAVOHealthSmbStepEnabled) { 'smb' }
    )
    $successArchiveIdentities = @(
        $archiveDefinitions | Where-Object { [bool]$_.Enabled } | ForEach-Object {
            $successArchiveInfo = $script:healthLatestArchives[[string]$_.Type]
            if ($null -ne $successArchiveInfo -and $null -ne $successArchiveInfo.LastWriteTime) {
                [pscustomobject]@{
                    Type = [string]$_.Type
                    GenerationId = [string]$successArchiveInfo.GenerationId
                    LastWriteTime = [datetime]$successArchiveInfo.LastWriteTime
                }
            }
        }
    )
    $successFingerprint = Get-BRAVOHealthSuccessFingerprint `
        -DestinationSummary $destinationSummary `
        -SftpDeferred ([bool]$script:BRAVOHealthSftpCheckDeferredByBusyWinSCP) `
        -EnabledCheckNames $successEnabledCheckNames `
        -ArchiveIdentities $successArchiveIdentities
    if ($sendSuccessNotification) {
        $previousSuccessState = $null
        if (-not $ForceNotification -and -not $SuppressHeader -and
            $successDedupMinutes -gt 0 -and -not $operationalRecoveryPending) {
            $previousSuccessState = Get-BRAVOHealthSuccessNotificationState
        }
        $successDecision = Get-BRAVOHealthSuccessNotificationDecision `
            -ForceNotification:$ForceNotification `
            -EmbeddedPostBackup:$SuppressHeader `
            -DedupMinutes $successDedupMinutes `
            -RecoveryPending:$operationalRecoveryPending `
            -PreviousState $previousSuccessState `
            -CurrentFingerprint $successFingerprint
        switch ([string]$successDecision.Reason) {
            'Recovery' {
                Write-HealthLog "Recovery pending: оператор ще не отримав підтвердження відновлення після аварійного стану — SUCCESS не підлягає дедуплікації" -Level "INFO"
            }
            'StateChanged' {
                $previousFingerprintShort = if ($null -ne $previousSuccessState -and
                    -not [string]::IsNullOrWhiteSpace([string]$previousSuccessState.Fingerprint)) {
                    ([string]$previousSuccessState.Fingerprint).Substring(0, 8)
                } else {
                    'невідомий'
                }
                Write-HealthLog "Semantic-стан змінився з часу попереднього success-звіту (fingerprint $previousFingerprintShort -> $($successFingerprint.Substring(0, 8))) — звіт буде відправлено" -Level "INFO"
            }
            'SameStateWithinWindow' {
                $previousSuccessAgeMinutes = [int][math]::Round(([timespan]$previousSuccessState.Age).TotalMinutes)
                Write-HealthLog "SUCCESS-звіт придушено дедуплікацією: semantic-стан не змінився (fingerprint $($successFingerprint.Substring(0, 8))), попередню доставку виконано $previousSuccessAgeMinutes хв тому (вікно SuccessDedupMinutes = $successDedupMinutes хв; -ForceNotification надсилає примусово)" -Level "INFO"
            }
        }
        if (-not $successDecision.Send) {
            $sendSuccessNotification = $false
            $successNotificationDisposition = 'Suppressed'
        }
    }
    if ($sendSuccessNotification) {
        $healthDuration = (Get-Date) - $healthCheckStarted
        $successMessage = New-SlackSuccessMessage -Duration $healthDuration
        try {
            $successRoute = Resolve-BRAVONotificationRoute `
                -Severity "SUCCESS" `
                -NotificationMode $NotificationMode `
                -RoutingTable $backupMonitoring.NotificationRouting
            $successChunks = ConvertTo-BRAVONotificationPayloadText -Provider $NotificationProvider -Message $successMessage
            Send-BRAVONotificationChunks `
                -Provider $NotificationProvider `
                -WebhookUrl $script:NotificationWebhookUrls[$successRoute] `
                -MessageChunks $successChunks `
                -TimeoutSeconds $NotificationRequestTimeoutSeconds
            Write-HealthLog "Успішний звіт відправлено у $NotificationProviderDisplayName" -Level "SUCCESS"
            try {
                Save-BRAVOHealthSuccessNotificationState -Fingerprint $successFingerprint
            } catch {
                # Провал запису state не змінює первинний результат —
                # звіт УЖЕ відправлено; наступний прогін просто не
                # дедуплікується.
                Write-HealthLog "Не вдалося зберегти стан success-звіту (наступний звіт може не дедуплікуватись): $($_.Exception.Message)" -Level "WARNING"
            }
            if ($operationalRecoveryPending) {
                # Recovery підтверджене лише ФАКТИЧНО доставленим SUCCESS —
                # тому очищення стоїть тут, після Send, а не в decision-гілці.
                # Провал запису fail-safe у бік повтору: наступний healthy
                # прогін надішле recovery-звіт ще раз.
                try {
                    Save-BRAVOHealthOperationalState -RecoveryPending $false
                    Write-HealthLog "Recovery SUCCESS доставлено; RecoveryPending очищено" -Level "INFO"
                } catch {
                    Write-HealthLog "Recovery SUCCESS доставлено, але операційний стан не вдалося оновити — наступний healthy прогін повторить recovery-звіт: $($_.Exception.Message)" -Level "WARNING"
                }
            }
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "Healthy"
                IssueCount = 0
                Notification = "Sent"
                LogPath = $healthLogFile
                LocalVerified = $destinationSummary.LocalVerified
                SftpVerified = $destinationSummary.SftpVerified
                SmbVerified = $destinationSummary.SmbVerified
            })
        } catch {
            Write-HealthLog "Не вдалося відправити успішний звіт у ${NotificationProviderDisplayName}: $($_.Exception.Message)" -Level "ERROR"
            if ($operationalRecoveryPending) {
                # Операційний стан навмисно НЕ чіпаємо: RecoveryPending
                # лишається true, наступний healthy прогін повторить спробу.
                Write-HealthLog "Recovery SUCCESS не доставлено; RecoveryPending збережено для повторної спроби на наступному healthy-прогоні" -Level "WARNING"
            }
            return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
                Status = "NotificationError"
                IssueCount = 0
                Notification = "Failed"
                LogPath = $healthLogFile
                Error = $_.Exception.Message
                LocalVerified = $destinationSummary.LocalVerified
                SftpVerified = $destinationSummary.SftpVerified
                SmbVerified = $destinationSummary.SmbVerified
            })
        }
    }

    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Healthy"
        IssueCount = 0
        Notification = $successNotificationDisposition
        LogPath = $healthLogFile
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
}

# Операційний факт фіксується ДО будь-якої notification-логіки і незалежно
# від того, чи вдасться доставити alert (operational truth і notification
# delivery — різні речі): система unhealthy, отже оператор ще не отримав
# підтвердження відновлення — наступний healthy прогін зобов'язаний надіслати
# recovery-SUCCESS, і так до першої успішної доставки.
try {
    Save-BRAVOHealthOperationalState -RecoveryPending $true
    Write-HealthLog "RecoveryPending встановлено: Health перейшов у problem state; відновлення буде підтверджено окремим SUCCESS-звітом" -Level "INFO"
} catch {
    Write-HealthLog "Не вдалося зберегти операційний стан RecoveryPending — гарантія повторного recovery-звіту після відновлення втрачена до наступного unhealthy-прогону: $($_.Exception.Message)" -Level "WARNING"
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
            $healthIssueActionCounts = Get-BRAVOHealthIssueActionCounts -Issue $healthIssue
            if ($healthIssue.Reason -eq "у хмарі відсутні або потребують оновлення локальні файли/папки") {
                $pendingParts = @()
                if ($null -ne $healthIssueActionCounts) {
                    if ([int]$healthIssueActionCounts.New -gt 0) {
                        $pendingParts += "відсутніх: $($healthIssueActionCounts.New)"
                    }
                    if ([int]$healthIssueActionCounts.Updated -gt 0) {
                        $pendingParts += "застарілих: $($healthIssueActionCounts.Updated)"
                    }
                    if ([int]$healthIssueActionCounts.Other -gt 0) {
                        $pendingParts += "без окремої класифікації: $($healthIssueActionCounts.Other)"
                    }
                }
                $pendingSummary = if ($pendingParts.Count -gt 0) {
                    $pendingParts -join ", "
                } else {
                    "типи не визначено"
                }
                Write-HealthLog "Проблема $($healthIssue.Component): $($healthIssue.Reason); каталог: $($healthIssue.Location); очікують передачі: $($healthIssue.DifferenceCount) ($pendingSummary); розмір: $(Format-FileSize $healthIssue.SizeBytes)" -Level "ERROR"
            } else {
                $actionSummary = if ($null -ne $healthIssueActionCounts) {
                    "нових: $($healthIssueActionCounts.New), змінених: $($healthIssueActionCounts.Updated), зайвих у хмарі: $($healthIssueActionCounts.RemoteExtra), очікують передачі: $($healthIssueActionCounts.Other)"
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
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
}

if (Test-AlertSuppressed -Fingerprint $alertFingerprint) {
    Write-HealthLog "Повторне однакове сповіщення тимчасово пригнічено" -Level "INFO"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Critical"
        IssueCount = $healthIssues.Count
        Notification = "Suppressed"
        LogPath = $healthLogFile
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
}

try {
    $issuesRoute = Resolve-BRAVONotificationRoute `
        -Severity "CRITICAL" `
        -NotificationMode $NotificationMode `
        -RoutingTable $backupMonitoring.NotificationRouting
    $issuesChunks = ConvertTo-BRAVONotificationPayloadText -Provider $NotificationProvider -Message $slackMessage
    Send-BRAVONotificationChunks `
        -Provider $NotificationProvider `
        -WebhookUrl $script:NotificationWebhookUrls[$issuesRoute] `
        -MessageChunks $issuesChunks `
        -TimeoutSeconds $NotificationRequestTimeoutSeconds
    Save-AlertState -Fingerprint $alertFingerprint
    Write-HealthLog "Критичне повідомлення успішно відправлено у $NotificationProviderDisplayName" -Level "SUCCESS"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "Critical"
        IssueCount = $healthIssues.Count
        Notification = "Sent"
        LogPath = $healthLogFile
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
} catch {
    Write-HealthLog "Не вдалося відправити повідомлення у ${NotificationProviderDisplayName}: $($_.Exception.Message)" -Level "ERROR"
    return Complete-BRAVOHealthResult -Result ([pscustomobject]@{
        Status = "NotificationError"
        IssueCount = $healthIssues.Count
        Notification = "Failed"
        LogPath = $healthLogFile
        Error = $_.Exception.Message
        LocalVerified = $destinationSummary.LocalVerified
        SftpVerified = $destinationSummary.SftpVerified
        SmbVerified = $destinationSummary.SmbVerified
    })
}

}
# END BRAVO HEALTH RUNTIME
if ($MyInvocation.InvocationName -ne '.') {
    $healthParameters = @{
        ConfigPath = $ConfigPath
        ForceNotification = $ForceNotification
        NotifyOnSuccess = $NotifyOnSuccess
        NoSlack = $NoSlack
        SkipIfBackupTaskRunning = $SkipIfBackupTaskRunning
    }
    # -NoPause приймався тут і раніше, але ніде не використовувався — Health
    # ніколи не чекав на клавішу при ручному запуску. try/finally гарантує
    # паузу і на нормальному завершенні, і на непередбаченому throw
    # усередині Invoke-BRAVOHealth (те саме, що вже робить Archive.Runtime.ps1).
    # Код завершення обчислюється всередині Complete-BRAVOHealthResult (див.
    # вище) — САМЕ ДО друку підсумку, а не тут і не після нього, як було
    # раніше. Deferred — це "пропущено через lock/уже виконується інше
    # завдання" у сенсі загального контракту кодів, тому окремий код 20, а
    # не 0/1. Skipped ніколи фактично не породжується цим runtime (мертва
    # гілка), лишена як безпечний fallback на успіх. Порушення цілісності
    # інструментів перекриває будь-який інший результат: Health навмисно не
    # переривається на старті (на відміну від Archive/Maintenance) —
    # локальні перевірки служб, дисків і віку копій Tools не запускають,
    # тому лишаються корисними саме тоді, коли підозрюється підміна. Але
    # SFTP-гілка при цьому пропущена (Test-SFTPHealthConfiguration), і
    # зовнішній моніторинг має бачити подію безпеки, а не звичайний
    # health-статус.
    $script:healthRuntimeExitCode = 90
    try {
        [void](Invoke-BRAVOHealth @healthParameters)
    } finally {
        Wait-BRAVOManualExit -NoPause:$NoPause
    }

    exit $script:healthRuntimeExitCode
}
