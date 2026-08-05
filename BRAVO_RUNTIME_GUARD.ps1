[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [string]$ManifestPath,

    # Ін'єкція для self-test: перевірити довільний каталог і вміст
    # маніфесту без файлу на диску.
    [string]$ManifestContent,

    [ValidateSet('Enforce', 'Warn')]
    [string]$Mode = 'Enforce'
)

##########
# Перевірка цілісності PowerShell-комплекту BRAVO перед завантаженням
# модулів (аудит P2).
#
# ЧОМУ ЦЕ ОКРЕМИЙ САМОДОСТАТНІЙ ФАЙЛ, А НЕ ФУНКЦІЯ В МОДУЛІ:
# перевірка має відбутися ДО Import-Module. Якби вона жила в
# BRAVO.Compatibility, довелося б спершу завантажити модуль, щоб
# перевірити модулі, — тобто виконати саме той код, який ще не
# перевірено. Тому тут використовуються лише .NET-типи й жодної
# залежності від решти комплекту.
#
# ЧЕСНА МЕЖА (не обходьте її мовчки):
# 1. Сам entrypoint (BRAVO_ARCHIV.ps1) і цей guard уже виконуються, коли
#    перевірка починається. Підміна саме цих двох файлів не буде
#    виявлена ДО їх запуску — вони входять до маніфесту, тому будуть
#    помічені, але вже після того, як їхній код відпрацював. Повне
#    закриття цієї межі потребує Authenticode-підпису й
#    ExecutionPolicy AllSigned (аудит P0.3, не реалізовано).
# 2. BRAVO.config НАВМИСНО не входить до маніфесту: він редагується на
#    кожному сервері (шляхи, розклад, увімкнені компоненти), тому
#    спільного еталонного хешу для нього не існує. Натомість guard
#    окремо перевіряє, що конфігурація не ПОСЛАБЛЮЄ захист (див.
#    Test-BRAVORuntimeSecuritySettings нижче).
##########

Set-StrictMode -Version 2.0

function Get-BRAVORuntimeFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Get-FileHash доступний з PowerShell 4.0; проєкт підтримує 3.0 як
    # мінімум для допоміжних шляхів, тому рахуємо через .NET напряму.
    $stream = $null
    $sha256 = $null
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $hashBytes = $sha256.ComputeHash($stream)
        return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToUpperInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $sha256) { $sha256.Dispose() }
    }
}

function Test-BRAVORuntimeManifestIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$ManifestContent,
        [ValidateSet('Enforce', 'Warn')][string]$Mode = 'Enforce'
    )

    $result = New-Object PSObject -Property @{
        IsValid = $true
        Mode = $Mode
        ManifestPath = $ManifestPath
        MismatchedFiles = @()
        MissingFiles = @()
        UnknownFiles = @()
        Message = $null
        ShouldBlock = $false
        CheckedCount = 0
    }

    $raw = $null
    if ($PSBoundParameters.ContainsKey('ManifestContent')) {
        $raw = $ManifestContent
    } elseif ([System.IO.File]::Exists($ManifestPath)) {
        try {
            $raw = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
        } catch {
            $raw = $null
        }
    }

    # Відсутній маніфест у режимі Enforce — відмова, а не мовчазний
    # пропуск: інакше найпростішим обходом було б його видалити.
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.IsValid = $false
        $result.Message = "Не знайдено або не вдалося прочитати RUNTIME_MANIFEST.json: $ManifestPath"
        $result.ShouldBlock = ($Mode -eq 'Enforce')
        return $result
    }

    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        $result.IsValid = $false
        $result.Message = "Пошкоджений RUNTIME_MANIFEST.json ($ManifestPath): $($_.Exception.Message)"
        $result.ShouldBlock = ($Mode -eq 'Enforce')
        return $result
    }

    $expected = @{}
    if ($null -ne $parsed -and
        $null -ne $parsed.PSObject.Properties['files'] -and
        $null -ne $parsed.files) {
        foreach ($property in $parsed.files.PSObject.Properties) {
            $expected[$property.Name] = ([string]$property.Value).Trim()
        }
    }
    if ($expected.Count -eq 0) {
        $result.IsValid = $false
        $result.Message = "RUNTIME_MANIFEST.json не містить жодного запису: $ManifestPath"
        $result.ShouldBlock = ($Mode -eq 'Enforce')
        return $result
    }

    $mismatched = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $unknown = New-Object System.Collections.ArrayList

    foreach ($relativePath in @($expected.Keys)) {
        $fullPath = Join-Path $RuntimeRoot $relativePath
        if (-not [System.IO.File]::Exists($fullPath)) {
            [void]$missing.Add($relativePath)
            continue
        }
        try {
            $actual = Get-BRAVORuntimeFileHash -Path $fullPath
        } catch {
            # Нечитабельний файл трактуємо як розбіжність: заблокований
            # на читання скрипт міг бути щойно підмінений.
            [void]$mismatched.Add("$relativePath (не вдалося обчислити хеш: $($_.Exception.Message))")
            continue
        }
        if (-not [string]::Equals($expected[$relativePath], $actual, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$mismatched.Add($relativePath)
        }
        $result.CheckedCount = $result.CheckedCount + 1
    }

    # Підкинутий у комплект новий .ps1/.psm1 — теж аномалія: він може
    # бути dot-source-нутий або підхоплений як модуль.
    $scanExtensions = @('.ps1', '.psm1', '.psd1')
    if ([System.IO.Directory]::Exists($RuntimeRoot)) {
        $rootPrefixLength = $RuntimeRoot.TrimEnd('\', '/').Length + 1
        $allScripts = @(
            [System.IO.Directory]::GetFiles($RuntimeRoot, '*', [System.IO.SearchOption]::AllDirectories) |
                Where-Object {
                    $scanExtensions -contains ([System.IO.Path]::GetExtension($_).ToLowerInvariant())
                }
        )
        foreach ($scriptPath in $allScripts) {
            $relative = $scriptPath.Substring($rootPrefixLength)
            # Каталоги, які не є частиною комплекту: логи й локальні
            # робочі копії розробника.
            if ($relative -match '^(LOGS|\.git|\.vscode|local-backups)[\\/]') {
                continue
            }
            if (-not $expected.ContainsKey($relative)) {
                [void]$unknown.Add($relative)
            }
        }
    }

    $result.MismatchedFiles = @($mismatched.ToArray())
    $result.MissingFiles = @($missing.ToArray())
    $result.UnknownFiles = @($unknown.ToArray())

    if ($mismatched.Count -eq 0 -and $missing.Count -eq 0 -and $unknown.Count -eq 0) {
        return $result
    }

    $result.IsValid = $false
    $result.ShouldBlock = ($Mode -eq 'Enforce')

    $details = New-Object System.Collections.ArrayList
    if ($mismatched.Count -gt 0) {
        [void]$details.Add("змінено: $(@($mismatched.ToArray()) -join ', ')")
    }
    if ($missing.Count -gt 0) {
        [void]$details.Add("відсутні: $(@($missing.ToArray()) -join ', ')")
    }
    if ($unknown.Count -gt 0) {
        [void]$details.Add("сторонні скрипти в комплекті: $(@($unknown.ToArray()) -join ', ')")
    }

    $action = if ($Mode -eq 'Enforce') {
        "Запуск заблоковано (RuntimeIntegrityMode = Enforce)."
    } else {
        "Запуск продовжується (RuntimeIntegrityMode = Warn), але це слід перевірити."
    }

    $result.Message = (
        "ЦІЛІСНІСТЬ КОМПЛЕКТУ ПОРУШЕНО: {0}. {1} Заплановане завдання виконується від " +
        "NT AUTHORITY\SYSTEM, тому підмінений скрипт отримав би найвищі права в системі. " +
        "Якщо оновлення комплекту свідоме — оновіть RUNTIME_MANIFEST.json у репозиторії " +
        "(ci\Update-BRAVORuntimeManifest.ps1 -Apply) і розгорніть новий комплект; маніфест " +
        "навмисно не оновлюється автоматично на сервері."
    ) -f (@($details.ToArray()) -join "; "), $action

    return $result
}

# Пряме виконання (не dot-source): виконати перевірку й повернути код.
# Dot-source з entrypoint лише оголошує функції, нічого не виконуючи, —
# так само, як це роблять runtime-файли модулів.
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = $PSScriptRoot
    }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $RuntimeRoot 'RUNTIME_MANIFEST.json'
    }

    $guardParameters = @{
        RuntimeRoot = $RuntimeRoot
        ManifestPath = $ManifestPath
        Mode = $Mode
    }
    if ($PSBoundParameters.ContainsKey('ManifestContent')) {
        $guardParameters['ManifestContent'] = $ManifestContent
    }
    $guardResult = Test-BRAVORuntimeManifestIntegrity @guardParameters

    if ($guardResult.IsValid) {
        Write-Host "Цілісність комплекту підтверджена (перевірено файлів: $($guardResult.CheckedCount))." -ForegroundColor Green
        exit 0
    }

    Write-Host $guardResult.Message -ForegroundColor Red
    if ($guardResult.ShouldBlock) { exit 33 }
    exit 0
}
