[CmdletBinding()]
param(
    [string]$Root,

    # Інформаційний режим: аналізує ВСЕ, крім блокуючого набору, і ніколи
    # не повертає ненульовий код завершення.
    [switch]$Informational
)

# Статичний аналіз PSScriptAnalyzer для CI.
#
# Чому окремий файл, а не крок `run:` у ci.yml: GitHub Actions записує
# вміст `run:` у тимчасовий .ps1 БЕЗ BOM, і Windows PowerShell 5.1 читає
# його в системній ANSI-кодовій сторінці. Кирилична літера, чий другий
# байт UTF-8 потрапляє в діапазон 0x80-0x9F (наприклад "я" = D1 8F),
# декодується в control-символ і руйнує рядковий літерал — крок падає з
# ParserError ще до виконання. Файл у репозиторії має BOM, тому читається
# коректно, і його можна запустити локально перед комітом.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

# Явна перевірка, а не тихий аналіз чужого каталогу: помилка на один
# рівень вгору вже траплялась при перенесенні цього скрипта і призвела
# до сканування всього Documents замість репозиторію.
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "::error::Не схоже на корінь репозиторію BRAVO (немає BRAVO_SELF_TEST.ps1): $Root"
    exit 1
}

$settingsPath = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    Write-Host "::error::Не знайдено PSScriptAnalyzerSettings.psd1: $settingsPath"
    exit 1
}

Import-Module -Name PSScriptAnalyzer -ErrorAction Stop

. (Join-Path $PSScriptRoot 'BRAVOAnalyzableFiles.ps1')
$files = @(Get-BRAVOAnalyzableFile -Root $Root)

# Пофайловий обхід, а не -Path . -Recurse: окремі правила PSScriptAnalyzer
# здатні кинути NullReferenceException на конкретному файлі й обірвати
# весь аналіз, замаскувавши решту знахідок.
$findings = @()
foreach ($file in $files) {
    try {
        if ($Informational) {
            $blockingRules = @((Import-PowerShellDataFile -LiteralPath $settingsPath).IncludeRules)
            $findings += Invoke-ScriptAnalyzer -Path $file.FullName -ExcludeRule $blockingRules
        } else {
            $findings += Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath
        }
    } catch {
        $message = "PSScriptAnalyzer впав на цьому файлі: $($_.Exception.Message)"
        if ($Informational) {
            Write-Host "::warning file=$($file.FullName)::$message"
        } else {
            Write-Host "::error file=$($file.FullName)::$message"
            exit 1
        }
    }
}

if ($Informational) {
    Write-Host "PSScriptAnalyzer (інформаційно): зауважень $($findings.Count)."
    $findings |
        Group-Object RuleName |
        Sort-Object Count -Descending |
        ForEach-Object { Write-Host "  $($_.Count)x $($_.Name)" }
    exit 0
}

if ($findings.Count -gt 0) {
    foreach ($finding in $findings) {
        Write-Host "::error file=$($finding.ScriptPath),line=$($finding.Line)::$($finding.RuleName): $($finding.Message)"
    }
    Write-Host "::error::Заблоковано security-порушень: $($findings.Count). Якщо використання обґрунтоване, додайте точковий SuppressMessageAttribute з полем Justification біля конкретної функції, а не глобальний виняток."
    exit 1
}

Write-Host "Security-набір PSScriptAnalyzer: чисто (перевірено файлів: $($files.Count))."
exit 0
