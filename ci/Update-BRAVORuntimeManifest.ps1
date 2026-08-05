[CmdletBinding()]
param(
    [string]$Root,

    # Без цього перемикача скрипт лише показує розбіжності й нічого не
    # записує.
    [switch]$Apply
)

# Оновлення RUNTIME_MANIFEST.json — еталонних SHA-256 усього
# PowerShell-комплекту (аудит P2).
#
# ЦЕЙ СКРИПТ НЕ ПРИЗНАЧЕНИЙ ДЛЯ PRODUCTION-СЕРВЕРА. Він для робочої
# станції: змінили код -> оновили маніфест -> переглянули git diff ->
# закомітили разом зі змінами. Якщо маніфест можна перегенерувати там,
# де виконується архівація, то зловмисник, який підмінив BRAVO_ARCHIV.ps1,
# просто перегенерує й маніфест — сторож сам випише перепустку злодію.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "Не схоже на корінь репозиторію BRAVO (немає BRAVO_SELF_TEST.ps1): $Root" -ForegroundColor Red
    exit 1
}

$manifestPath = Join-Path $Root 'RUNTIME_MANIFEST.json'

# BRAVO.config навмисно НЕ входить: він редагується на кожному сервері
# (шляхи, розклад, увімкнені компоненти), спільного еталонного хешу для
# нього не існує. Замість цього guard окремо перевіряє, що конфігурація
# не послаблює захист.
$includedExtensions = @('.ps1', '.psm1', '.psd1')
$includedExtraFiles = @('VERSION.json', 'TOOLS_MANIFEST.json')
$excludedDirectoryPattern = '^(LOGS|\.git|\.vscode|local-backups)[\\/]'

$rootPrefixLength = $Root.TrimEnd('\', '/').Length + 1
$currentHashes = [ordered]@{}

$candidates = New-Object System.Collections.ArrayList
Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object { $includedExtensions -contains $_.Extension.ToLowerInvariant() } |
    ForEach-Object { [void]$candidates.Add($_.FullName) }
foreach ($extraName in $includedExtraFiles) {
    $extraPath = Join-Path $Root $extraName
    if (Test-Path -LiteralPath $extraPath -PathType Leaf) {
        [void]$candidates.Add((Resolve-Path -LiteralPath $extraPath).Path)
    }
}

foreach ($fullPath in ($candidates | Sort-Object)) {
    $relative = $fullPath.Substring($rootPrefixLength)
    if ($relative -match $excludedDirectoryPattern) {
        continue
    }
    $currentHashes[$relative] = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

$recorded = @{}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $existing.files) {
        foreach ($property in $existing.files.PSObject.Properties) {
            $recorded[$property.Name] = [string]$property.Value
        }
    }
}

$changes = New-Object System.Collections.ArrayList
foreach ($name in $currentHashes.Keys) {
    if (-not $recorded.ContainsKey($name)) {
        [void]$changes.Add("НОВИЙ    $name")
    } elseif ($recorded[$name] -ne $currentHashes[$name]) {
        [void]$changes.Add("ЗМІНЕНО  $name")
    }
}
foreach ($name in $recorded.Keys) {
    if (-not $currentHashes.Contains($name)) {
        [void]$changes.Add("ВИДАЛЕНО $name")
    }
}

if ($changes.Count -eq 0) {
    Write-Host "RUNTIME_MANIFEST.json актуальний: розбіжностей немає (файлів: $($currentHashes.Count))." -ForegroundColor Green
    exit 0
}

Write-Host "Розбіжності між комплектом і RUNTIME_MANIFEST.json:" -ForegroundColor Yellow
$changes | ForEach-Object { Write-Host "  $_" }

if (-not $Apply) {
    Write-Host ""
    Write-Host "Нічого не записано. Якщо ці зміни свідомі, запустіть з -Apply." -ForegroundColor Yellow
    exit 0
}

$manifest = [ordered]@{
    schemaVersion = 1
    description = "Еталонні SHA-256 PowerShell-комплекту BRAVO. Version-controlled; НІКОЛИ не формується автоматично на production-сервері. BRAVO.config навмисно не входить (сервер-специфічний) — замість хешу BRAVO_RUNTIME_GUARD.ps1 перевіряє, що конфігурація не послаблює захист."
    updateProcedure = "Змінили код -> ci\Update-BRAVORuntimeManifest.ps1 -Apply -> git diff -> коміт разом зі змінами."
    files = $currentHashes
}
$json = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, ($json + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "RUNTIME_MANIFEST.json оновлено (файлів: $($currentHashes.Count)). Перегляньте git diff перед комітом." -ForegroundColor Green
exit 0
