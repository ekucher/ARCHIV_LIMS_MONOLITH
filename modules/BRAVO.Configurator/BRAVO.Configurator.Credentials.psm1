# BRAVO.Configurator.Credentials — статус SFTP/SMB-креденшелів для UI,
# БЕЗ жодного секрету в моделі Configurator-а.
#
# Дизайн-рішення (P1.7): requirement-формула ("чи потрібні креденшели цього
# transport-у") живе виключно inline у BRAVO_CREDENTIALS_SETUP.ps1
# (Resolve-RequestedComponents) — окремої canonical exported-функції немає.
# BRAVO_CREDENTIALS_SETUP.ps1 сам по собі — це executing entrypoint-скрипт
# (param() -> function defs -> top-level try{} з реальними записами й
# інтерактивними запитами), НЕ importable module: dot-source його для
# "лише функцій" фактично запустив би повний credential setup flow. Тому:
#   - requirement обчислюється тут з тих самих canonical Effective-структур
#     (storageEffective/bazaSyncEffective/backupMonitoring), які Configurator
#     вже captures — той самий вираз, що Resolve-RequestedComponents,
#     нічого не вигадується;
#   - Found/Missing статус отримується РЕАЛЬНИМ прогоном
#     BRAVO_CREDENTIALS_SETUP.ps1 -Action Test дочірнім процесом (той самий
#     підхід, що Effective.psm1 для canonical loader-а) — жодного
#     незалежного читання Windows Credential Manager чи дублювання
#     target-name resolution (Get-CredentialTarget) у Configurator.
#
# Секрети НІКОЛИ не читаються, не логуються, не серіалізуються тут — лише
# exit code/статус дочірнього процесу.

Set-StrictMode -Version 2.0

function Get-BRAVOConfiguratorCredentialRequirement {
    <#
    .SYNOPSIS
        Обчислює, чи потрібні SFTP/SMB-креденшелі за поточним Effective
        topology — той самий вираз, що BRAVO_CREDENTIALS_SETUP.ps1
        (Resolve-RequestedComponents), з тих самих canonical джерел.
    .PARAMETER EffectiveConfig
        Результат Invoke-BRAVOConfiguratorEffectiveComputation (містить
        storageEffective/bazaSyncEffective/backupMonitoring).
    #>
    [CmdletBinding()]
    param($EffectiveConfig)

    $storage = $EffectiveConfig.storageEffective
    $bazaSync = $EffectiveConfig.bazaSyncEffective
    $backupMonitoring = $EffectiveConfig.backupMonitoring
    # componentSettings — новий (R3-4) необов'язковий вхід: під
    # Set-StrictMode звернення до відсутньої властивості (і до властивості
    # НА $null-значенні) кидає виняток, а не повертає $null. Існуючі
    # виклик-площини/фікстури, побудовані до R3-4 (звужені сценарії, що не
    # стосуються own-log toggles), не зобов'язані передавати це поле —
    # безпечний дефолт (обидва own-log-тумблери = вимкнено) зберігає їхню
    # сумісність без потреби оновлювати кожну.
    $componentSettings = if ($EffectiveConfig.PSObject.Properties['componentSettings']) {
        $EffectiveConfig.componentSettings
    } else {
        [pscustomobject]@{ SFTP = [pscustomobject]@{ MaintenanceLogUploadEnabled = $false; ArchiveLogUploadEnabled = $false } }
    }

    # SFTP: canonical Test-BRAVOSftpCredentialsRequired (R3-4, PR #136
    # третє коло review) — master AND (ArchiveUpload OR own-log upload
    # toggles OR запланований BAZA SFTP sync OR Health SFTP-моніторинг),
    # ідентично Resolve-RequestedComponents/BRAVO_DRY_RUN.ps1.
    $sftpRequired = Test-BRAVOSftpCredentialsRequired `
        -SftpEnabled ([bool]$storage.SFTP.Enabled) `
        -ArchiveUploadEnabled ([bool]$storage.SFTP.ArchiveUpload) `
        -MaintenanceLogUploadEnabled ([bool]$componentSettings.SFTP.MaintenanceLogUploadEnabled) `
        -ArchiveLogUploadEnabled ([bool]$componentSettings.SFTP.ArchiveLogUploadEnabled) `
        -ScheduledSftpSyncRequired ([bool]$bazaSync.ScheduledSftpSyncRequired) `
        -BackupMonitoringSftpEnabled ([bool]$backupMonitoring.SFTP.Enabled)
    # SMB: storageEffective.SMB.ArchiveCopy вже є (master AND child) —
    # окремо перевіряти SMB.Enabled не потрібно.
    $smbRequired = [bool]$storage.SMB.ArchiveCopy

    return [pscustomobject]@{
        SFTP = [pscustomobject]@{ Required = $sftpRequired }
        SMB  = [pscustomobject]@{ Required = $smbRequired }
    }
}

function Invoke-BRAVOConfiguratorCredentialCheck {
    <#
    .SYNOPSIS
        Реальний, non-destructive прогін canonical
        BRAVO_CREDENTIALS_SETUP.ps1 -Action Test дочірнім процесом —
        повертає Found/Missing/Error для запитаного Component,
        без жодного читання секрету цим модулем.
    .DESCRIPTION
        Fail-closed: canonical exit-code контракт для -Action Test —
        0 = усі запитані записи знайдено; 1 = хоча б один Missing/Error
        (сам скрипт документує цю семантику: "Missing є невдачею лише для
        Test"). Ми довіряємо exit code, не парсимо консольний вивід.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('SFTP', 'SMB', 'Required', 'All', 'Institution')]
        [string]$Component,
        [int]$TimeoutSeconds = 60
    )

    $scriptPath = Join-Path $RuntimeRoot 'BRAVO_CREDENTIALS_SETUP.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        return [pscustomobject]@{ Component = $Component; Status = 'Error'; ExitCode = $null; Reason = "BRAVO_CREDENTIALS_SETUP.ps1 не знайдено ('$scriptPath')." }
    }

    $logDir = Join-Path ([System.IO.Path]::GetTempPath()) ('BRAVO_CONFIGURATOR_CREDCHECK_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    try {
        # -Component на command line — лише ІМ'Я запитаної групи (напр.
        # "SFTP"), ніколи секрет; -Action Test не приймає й не читає
        # відкритих значень. Canonical назва параметра
        # BRAVO_CREDENTIALS_SETUP.ps1 — перевірено реальним прогоном.
        $processArgs = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath,
            '-Action', 'Test',
            '-Component', $Component
        )
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $processArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput (Join-Path $logDir 'stdout.log') `
            -RedirectStandardError (Join-Path $logDir 'stderr.log')
        $null = $process.Handle
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try { & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null } catch { <# найкраще-зусилля cleanup: гонитва з природним завершенням процесу #> }
            try { $process.Kill() } catch { <# те саме #> }
            return [pscustomobject]@{ Component = $Component; Status = 'Error'; ExitCode = $null; Reason = "Перевірка креденшелів не завершилась за $TimeoutSeconds с (fail-closed, timeout)." }
        }

        $status = if ($process.ExitCode -eq 0) { 'Found' } else { 'Missing' }
        return [pscustomobject]@{ Component = $Component; Status = $status; ExitCode = $process.ExitCode; Reason = $null }
    } catch {
        return [pscustomobject]@{ Component = $Component; Status = 'Error'; ExitCode = $null; Reason = $_.Exception.Message }
    } finally {
        # P2 (незалежний review, Agent D): те саме обґрунтування, що
        # Effective.psm1 — свідомий SilentlyContinue, не недбалість; жоден
        # секрет у цей каталог не потрапляє (лише stdout/stderr canonical
        # -Action Test, який сам ніколи не друкує відкритий пароль).
        Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-BRAVOConfiguratorCredentialState {
    <#
    .SYNOPSIS
        Повний credential-статус для UI: Required/NotRequired ×
        Found/Missing/Error, для SFTP і SMB. НЕ перевіряє Found/Missing,
        якщо Required=$false (не потрібно й не бажано зайвий раз
        звертатись до Credential Manager).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)]$EffectiveConfig
    )

    $requirement = Get-BRAVOConfiguratorCredentialRequirement -EffectiveConfig $EffectiveConfig

    $sftpState = if ($requirement.SFTP.Required) {
        Invoke-BRAVOConfiguratorCredentialCheck -RuntimeRoot $RuntimeRoot -Component 'SFTP'
    } else {
        [pscustomobject]@{ Component = 'SFTP'; Status = 'NotRequired'; ExitCode = $null; Reason = $null }
    }
    $smbState = if ($requirement.SMB.Required) {
        Invoke-BRAVOConfiguratorCredentialCheck -RuntimeRoot $RuntimeRoot -Component 'SMB'
    } else {
        [pscustomobject]@{ Component = 'SMB'; Status = 'NotRequired'; ExitCode = $null; Reason = $null }
    }

    return [pscustomobject]@{
        SFTP = [pscustomobject]@{ Required = $requirement.SFTP.Required; Status = $sftpState.Status; Reason = $sftpState.Reason }
        SMB  = [pscustomobject]@{ Required = $requirement.SMB.Required; Status = $smbState.Status; Reason = $smbState.Reason }
    }
}

function Invoke-BRAVOConfiguratorCredentialSetup {
    <#
    .SYNOPSIS
        "Налаштувати": запускає canonical BRAVO_CREDENTIALS_SETUP.ps1
        інтерактивно (НЕ -NonInteractive) для запитаного компонента — той
        самий механізм, яким оператор користується сьогодні. Configurator
        не збирає, не бачить і не передає секрет далі себе: canonical
        скрипт сам запитує ввід у власній консолі.
    .DESCRIPTION
        Викликається лише як явна операторська дія (кнопка "Налаштувати"),
        не автоматично. Успадковує поточну консоль (-NoNewWindow, без
        redirect stdin/stdout) — оператор бачить і вводить у canonical UI
        скрипта напряму.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('SFTP', 'SMB', 'Required', 'All', 'Institution')]
        [string]$Component
    )

    $scriptPath = Join-Path $RuntimeRoot 'BRAVO_CREDENTIALS_SETUP.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "BRAVO.Configurator.Credentials: BRAVO_CREDENTIALS_SETUP.ps1 не знайдено ('$scriptPath')."
    }

    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-Action', 'Ensure',
        '-Component', $Component
    ) -NoNewWindow -PassThru -Wait

    return [pscustomobject]@{ ExitCode = $process.ExitCode }
}

Export-ModuleMember -Function @(
    'Get-BRAVOConfiguratorCredentialRequirement',
    'Invoke-BRAVOConfiguratorCredentialCheck',
    'Get-BRAVOConfiguratorCredentialState',
    'Invoke-BRAVOConfiguratorCredentialSetup'
)
