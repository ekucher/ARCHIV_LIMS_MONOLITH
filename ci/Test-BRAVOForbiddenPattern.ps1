[CmdletBinding()]
param(
    [string]$Root
)

# Заборонені патерни: те, чого PSScriptAnalyzer не ловить взагалі або
# ловить лише як AST (пропускаючи входження всередині рядків). Кожен
# пункт — те, чого в цьому репозиторії немає й не повинно з'явитись.
#
# Чому окремий файл, а не крок `run:` у ci.yml: GitHub Actions записує
# вміст `run:` у тимчасовий .ps1 БЕЗ BOM, і Windows PowerShell 5.1
# читає його в системній ANSI-кодовій сторінці. Кирилична літера, чий
# другий байт UTF-8 потрапляє в діапазон 0x80-0x9F (наприклад "я" =
# D1 8F), декодується в control-символ і руйнує рядковий літерал —
# крок падає з ParserError ще до виконання. Файл у репозиторії має BOM,
# тому читається коректно, і його можна запустити локально.

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

# ExecutionPolicy Bypass легітимний лише там, де скрипт перезапускає сам
# себе через UAC або описує завдання Планувальника (SECURITY.md розділ
# 4). Мета правила — заблокувати НОВІ файли з Bypass, а не переписати
# наявний механізм elevation.
$bypassAllowlist = @(
    'BRAVO_TASKS_INSTALL.ps1',
    'BRAVO_TASKS_UNINSTALL.ps1',
    'BRAVO_CREDENTIALS_SETUP.ps1',
    'BRAVO_SELF_TEST.ps1',
    'BRAVO.Archive.Runtime.ps1',
    'BRAVO.Maintenance.Runtime.ps1'
)

$forbiddenRules = @(
    @{
        Name = 'Invoke-Expression / iex'
        Pattern = '(?i)\b(Invoke-Expression|iex)\s'
        Allowlist = @()
    },
    @{
        Name = 'Мережеве завантаження коду'
        Pattern = '(?i)(DownloadString|DownloadFile|Net\.WebClient)'
        Allowlist = @()
    },
    @{
        Name = 'Секрет в аргументах процесу'
        Pattern = '(?i)-ArgumentList[^\r\n]*\$(password|secret|apiKey|token)\b'
        Allowlist = @()
    },
    @{
        Name = 'ExecutionPolicy Bypass поза installer/task definitions'
        Pattern = '(?i)ExecutionPolicy\s+Bypass'
        Allowlist = $bypassAllowlist
    }
)

. (Join-Path $PSScriptRoot 'BRAVOAnalyzableFiles.ps1')
$files = @(Get-BRAVOAnalyzableFile -Root $Root)

$violationCount = 0
foreach ($file in $files) {
    # Сам цей скрипт містить заборонені патерни у визначеннях правил
    # (регулярні вирази), тому інакше спрацював би сам на себе.
    if ($file.FullName -eq $PSCommandPath) {
        continue
    }

    $lines = [IO.File]::ReadAllLines($file.FullName)
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]

        # Рядки-коментарі не є виконуваним кодом: у репозиторії є
        # приклади команд запуску в коментарях, і сам цей файл описує
        # заборонені патерни в тексті правил.
        if ($line.TrimStart().StartsWith('#')) {
            continue
        }

        foreach ($rule in $forbiddenRules) {
            if ($line -notmatch $rule.Pattern) {
                continue
            }
            if ($rule.Allowlist -contains $file.Name) {
                continue
            }
            Write-Host "::error file=$($file.FullName),line=$($index + 1)::Заборонений патерн ($($rule.Name)): $($line.Trim())"
            $violationCount++
        }
    }
}

if ($violationCount -gt 0) {
    Write-Host "::error::Знайдено заборонених патернів: $violationCount. Ці конструкції не мають легітимного застосування в цьому репозиторії."
    exit 1
}

Write-Host "Заборонені патерни: не знайдено (перевірено файлів: $($files.Count))."
exit 0
