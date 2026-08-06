[CmdletBinding()]
param(
    [string]$Root,

    # Без цього перемикача скрипт лише показує розбіжності й нічого не
    # записує. Оновлення еталонних хешів має бути свідомою дією.
    [switch]$Apply
)

# Оновлення TOOLS_MANIFEST.json — еталонних SHA-256 виконуваних файлів
# Tools/.
#
# ЦЕЙ СКРИПТ НЕ ПРИЗНАЧЕНИЙ ДЛЯ PRODUCTION-СЕРВЕРА. Він для робочої
# станції розробника: замінили бінарник з офіційного джерела -> оновили
# маніфест -> переглянули git diff -> закомітили разом з бінарником.
# Якщо маніфест можна перегенерувати там, де виконується архівація, то
# зловмисник, який підмінив 7za.exe, просто перегенерує й маніфест.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "Не схоже на корінь репозиторію BRAVO (немає BRAVO_SELF_TEST.ps1): $Root" -ForegroundColor Red
    exit 1
}

$toolsDirectory = Join-Path $Root 'Tools'
# Маніфест лежить у тому самому каталозі, що й самі інструменти —
# так само, як TOOLS_INTEGRITY.json (TOFU-базова лінія).
$manifestPath = Join-Path $toolsDirectory 'TOOLS_MANIFEST.json'

if (-not (Test-Path -LiteralPath $toolsDirectory -PathType Container)) {
    Write-Host "Не знайдено каталог Tools: $toolsDirectory" -ForegroundColor Red
    exit 1
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$currentHashes = [ordered]@{}
Get-ChildItem -LiteralPath $toolsDirectory -File |
    Where-Object { $_.Extension -in @('.exe', '.dll', '.com') } |
    Sort-Object Name |
    ForEach-Object {
        $currentHashes[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    }

$recorded = @{}
foreach ($property in $manifest.tools.PSObject.Properties) {
    $recorded[$property.Name] = [string]$property.Value
}

$changes = New-Object System.Collections.Generic.List[string]
foreach ($name in $currentHashes.Keys) {
    if (-not $recorded.ContainsKey($name)) {
        [void]$changes.Add("НОВИЙ    $name -> $($currentHashes[$name])")
    } elseif ($recorded[$name] -ne $currentHashes[$name]) {
        [void]$changes.Add("ЗМІНЕНО  $name")
        [void]$changes.Add("         було:  $($recorded[$name])")
        [void]$changes.Add("         стало: $($currentHashes[$name])")
    }
}
foreach ($name in $recorded.Keys) {
    if (-not $currentHashes.Contains($name)) {
        [void]$changes.Add("ВИДАЛЕНО $name (більше немає у Tools/)")
    }
}

if ($changes.Count -eq 0) {
    Write-Host "TOOLS_MANIFEST.json актуальний: розбіжностей немає (файлів: $($currentHashes.Count))." -ForegroundColor Green
    exit 0
}

Write-Host "Розбіжності між Tools/ і TOOLS_MANIFEST.json:" -ForegroundColor Yellow
$changes | ForEach-Object { Write-Host "  $_" }

if (-not $Apply) {
    Write-Host ""
    Write-Host "Нічого не записано. Якщо ці зміни свідомі (ви самі замінили бінарник з офіційного джерела), запустіть з -Apply." -ForegroundColor Yellow
    exit 0
}

$manifest.tools = [pscustomobject]$currentHashes
$json = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, ($json + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "TOOLS_MANIFEST.json оновлено. ОБОВ'ЯЗКОВО перегляньте git diff перед комітом:" -ForegroundColor Green
Write-Host "  git diff -- TOOLS_MANIFEST.json" -ForegroundColor Green
exit 0
