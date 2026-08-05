[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Apply
)

# Проставляння sourceCommit і buildId у VERSION.json (аудит P4).
#
# Мета — однозначно відповісти на питання "який саме код зараз на цьому
# сервері". Короткий buildId для цього недостатній: короткі hash можуть
# збігатися й не шукаються надійно в історії. sourceCommit — повний
# 40-символьний git-hash.
#
# Запускається на робочій станції ПЕРЕД тегуванням релізу, коли всі
# зміни вже закомічені: інакше буде зафіксовано hash коміту, який не
# містить самого VERSION.json з цим hash. Це неминуча природа
# самопосилання — зафіксований коміт є батьківським для релізного.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "Не схоже на корінь репозиторію BRAVO: $Root" -ForegroundColor Red
    exit 1
}

$versionPath = Join-Path $Root 'VERSION.json'
$version = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json

$headCommit = (& git -C $Root rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headCommit)) {
    Write-Host "Не вдалося визначити поточний коміт (git rev-parse HEAD)." -ForegroundColor Red
    exit 1
}
$headCommit = $headCommit.Trim()
$shortCommit = $headCommit.Substring(0, 7)

$isDirty = -not [string]::IsNullOrWhiteSpace((& git -C $Root status --porcelain 2>$null))

$currentSourceCommit = if ($null -ne $version.PSObject.Properties['sourceCommit']) {
    [string]$version.sourceCommit
} else {
    $null
}

Write-Host "HEAD:                 $headCommit"
Write-Host "VERSION.sourceCommit: $(if ([string]::IsNullOrWhiteSpace($currentSourceCommit)) { '(не задано)' } else { $currentSourceCommit })"
Write-Host "VERSION.buildId:      $($version.buildId)"

if ($isDirty) {
    Write-Host ""
    Write-Host "УВАГА: у робочій копії є незакомічені зміни. Зафіксований hash не описуватиме те, що ви розгорнете." -ForegroundColor Yellow
}

if ($currentSourceCommit -eq $headCommit -and $version.buildId -eq $shortCommit) {
    Write-Host ""
    Write-Host "VERSION.json актуальний." -ForegroundColor Green
    exit 0
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "Нічого не записано. Запустіть з -Apply, щоб проставити sourceCommit = $headCommit, buildId = $shortCommit." -ForegroundColor Yellow
    exit 0
}

# Точкова заміна, а не ConvertTo-Json: PowerShell 5.1 переформатовує
# весь файл (4 пробої відступу, подвійний пробіл після двокрапки), і
# VERSION.json перестає відповідати конвенції репозиторію — це вже
# ламало самотест. Зберігаємо формат, змінюємо лише два значення.
$raw = [System.IO.File]::ReadAllText($versionPath, [System.Text.Encoding]::UTF8)

$raw = [regex]::Replace(
    $raw,
    '("buildId"\s*:\s*")[^"]*(")',
    ('${1}' + $shortCommit + '${2}')
)

if ($raw -match '"sourceCommit"\s*:') {
    $raw = [regex]::Replace(
        $raw,
        '("sourceCommit"\s*:\s*")[^"]*(")',
        ('${1}' + $headCommit + '${2}')
    )
} else {
    # Додаємо одразу після buildId, зберігаючи відступ сусіднього рядка.
    $raw = [regex]::Replace(
        $raw,
        '(?<Indent>[ \t]*)"buildId"(?<Rest>\s*:\s*"[^"]*")',
        ('${Indent}"buildId"${Rest},' + [Environment]::NewLine +
         '${Indent}"sourceCommit": "' + $headCommit + '"')
    )
}

[System.IO.File]::WriteAllText($versionPath, $raw, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "VERSION.json оновлено. Не забудьте перегенерувати RUNTIME_MANIFEST.json — VERSION.json входить до нього." -ForegroundColor Green
exit 0
