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
#
# BRAVO_TASKS_DIAGNOSE.ps1 належить до тієї самої категорії "описує завдання
# Планувальника": він не запускає нічого з Bypass, а ПЕРЕВІРЯЄ, що вже
# зареєстровані завдання містять очікувані аргументи. Без цього рядка
# діагностика не могла б назвати те, чого шукає.
# BRAVO_SETUP.ps1 є installer-ом і генерує три ручні launcher-и. Self-test
# окремо вимагає, щоб Bypass існував лише всередині
# New-BRAVOManualLauncherContent і рівно в одному місці файла.
$bypassAllowlist = @(
    'BRAVO_SETUP.ps1',
    'BRAVO_TASKS_INSTALL.ps1',
    'BRAVO_TASKS_UNINSTALL.ps1',
    'BRAVO_TASKS_DIAGNOSE.ps1',
    'BRAVO_CREDENTIALS_SETUP.ps1',
    'BRAVO_SELF_TEST.ps1',
    # Домен-фрагменти self-test (dot-sourced з BRAVO_SELF_TEST.ps1, Фаза 2
    # модуляризації): несуть ТІ САМІ перевірки, що раніше жили в allowlisted
    # моноліті — Governance проганяє release-policy гейт дочірнім
    # powershell.exe, ManualLaunchers ПЕРЕВІРЯЄ, що Bypass у BRAVO_SETUP.ps1
    # обмежений рівно New-BRAVOManualLauncherContent, і містить очікуваний
    # рядок launcher-а. Нових ВИКОНУВАНИХ Bypass-місць не додано.
    'BRAVO_SELF_TEST.Governance.ps1',
    'BRAVO_SELF_TEST.ManualLaunchers.ps1',
    # ConfigLoader: Import-BravoConfiguration встановлює $global:ScriptVersion/
    # $global:BravoConfigurationMetadata та інший глобальний стан, небезпечний
    # для змішування з рештою self-test-прогону в тому самому процесі — той
    # самий ізольований дочірній powershell.exe патерн, що ManualLaunchers/
    # Governance вище. Нових ВИКОНУВАНИХ Bypass-місць не додано.
    'BRAVO_SELF_TEST.ConfigLoader.ps1',
    # RestoreVerify (P1.1): legacy-loader probe — той самий ізольований
    # дочірній powershell.exe патерн, що ConfigLoader/Governance вище
    # (Import-BravoConfiguration змінює глобальний стан). Нових
    # ВИКОНУВАНИХ Bypass-місць не додано.
    'BRAVO_SELF_TEST.RestoreVerify.ps1',
    # ConfigIntent: E2E AUTO/EXPLICIT намір -ConfigPath на межі оператора —
    # реальні root-entrypoints запускаються ізольованим дочірнім
    # powershell.exe зі stub-runtime (той самий патерн, що ConfigLoader/
    # Governance вище). Нових ВИКОНУВАНИХ Bypass-місць не додано.
    'BRAVO_SELF_TEST.ConfigIntent.ps1',
    'BRAVO.Archive.Runtime.ps1',
    'BRAVO.Maintenance.Runtime.ps1',
    # Self-elevation (-Verb RunAs) і дочірній запуск BRAVO_HEALTH — той
    # самий патерн, що в Archive/Maintenance runtime.
    'BRAVO.DataRestore.Runtime.ps1',
    # Ручний E2E-матричний тест DataRestore: кожна комбінація — окремий
    # дочірній powershell.exe того самого довіреного комплекту (Runtime.ps1
    # робить рядковий exit, тому in-process виклик неможливий), той самий
    # елевований self-relaunch патерн, що BRAVO_SELF_TEST.ps1 і
    # BRAVO.DataRestore.Runtime.ps1 вище.
    'BRAVO.DataRestore.MatrixTest.psm1',
    # BRAVO.config описує завдання Планувальника (ArgumentsTemplate для
    # schtasks) — та сама категорія "описує завдання", що TASKS_INSTALL.
    # Config увійшов у скан заради правила legacy-webhook нижче.
    'BRAVO.config',
    # BRAVO.Configuration.psm1 (P0 Configuration Foundation, PR A):
    # Get-BRAVODefaultConfiguration повертає ТОЙ САМИЙ elevationSettings.
    # ArgumentsTemplate, що сьогодні буквально в BRAVO.config вище —
    # canonical built-in default того самого self-elevation-опису, а не
    # нове виконуване Bypass-місце.
    'BRAVO.Configuration.psm1'
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
    },
    @{
        # 5.2.1: legacy provider-wide webhook-и виведені з активного
        # контракту — Discord/Slack працюють лише через канальні
        # GENERAL/ALERTS targets. Правило блокує ПОВЕРНЕННЯ legacy-літералів
        # в активний runtime/config/setup код (коментарі пропускаються
        # загальним фільтром вище; історичні CHANGELOG/evidence-docs не
        # входять у analyzable-набір).
        # Allowlist: BRAVO_DRY_RUN.ps1 — міграційна діагностика legacy-only
        # інсталяції (читає запис лише щоб пояснити FAIL, runtime resolver
        # його не використовує); BRAVO_SELF_TEST.ps1 — негативні регресії
        # (доводять, що навіть наявний legacy-запис ігнорується).
        Name = 'Legacy provider-wide webhook target (BRAVO_DISCORD_URL/BRAVO_SLACK_URL)'
        Pattern = 'BRAVO_(DISCORD|SLACK)_URL'
        Allowlist = @(
            'BRAVO_DRY_RUN.ps1',
            'BRAVO_SELF_TEST.ps1'
        )
    }
)

. (Join-Path $PSScriptRoot 'BRAVOAnalyzableFiles.ps1')
$files = @(Get-BRAVOAnalyzableFile -Root $Root)

# Активні конфігураційні файли — не .ps1/.psm1/.psd1, тому поза
# Get-BRAVOAnalyzableFile, але legacy webhook-літерали (та інші заборонені
# патерни) не мають права з'являтись і в них.
foreach ($configFileName in @('BRAVO.config', 'BRAVO.local.config.example')) {
    $configFilePath = Join-Path $Root $configFileName
    if (Test-Path -LiteralPath $configFilePath -PathType Leaf) {
        $files += @(Get-Item -LiteralPath $configFilePath)
    }
}

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
