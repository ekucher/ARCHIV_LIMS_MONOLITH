# Шлях до каталогу архівів
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [string]$ArchivePath = "E:\Archiv",
    [string[]]$Directories = @("MODEL", "BLOG", "BRAVOEXCH"),
    [ValidateRange(1, 120)][int]$RetentionMonths = 2,
    [string]$LogDirectory = "D:\LIMS\Archiv\LOGS"
)

$archivePath = $ArchivePath
$directories = $Directories

# Поточна дата для назви лог-файлу
$currentDateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# Шлях для лог-файлу з датою та часом
$logPath = Join-Path $LogDirectory "remove_old_archiv_$currentDateTime.log"

# Поточна дата
$currentDate = Get-Date

# Дата, старіше якої файли будуть видалятися (2 місяці тому)
$cutoffDate = $currentDate.AddMonths(-$RetentionMonths)

if (-not (Test-Path -LiteralPath $archivePath -PathType Container)) {
    throw "Каталог архівів не знайдено: $archivePath"
}
$resolvedArchivePath = (Resolve-Path -LiteralPath $archivePath -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
$logDirectory = Split-Path -Path $logPath -Parent
if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
}

# Функція для запису в лог
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    Add-Content -Path $logPath -Value $logEntry
}

Write-Host "Починаємо очищення обідніх архівів старіших за $cutoffDate..." -ForegroundColor Green
Write-Log "=== ПОЧАТОК ОЧИЩЕННЯ АРХІВІВ ==="
Write-Log "Дата відсічення: $cutoffDate"
Write-Log "Лог-файл: $logPath"
$hadErrors = $false

foreach ($dir in $directories) {
    if ([IO.Path]::IsPathRooted($dir) -or $dir -match '(^|[\\/])\.\.([\\/]|$)') {
        Write-Log "НЕБЕЗПЕЧНИЙ КАТАЛОГ ПРОПУЩЕНО: $dir"
        $hadErrors = $true
        continue
    }
    $fullPath = Join-Path $resolvedArchivePath $dir
    Write-Host "`nОбробка каталогу: $fullPath" -ForegroundColor Yellow
    Write-Log "Обробка каталогу: $fullPath"

    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $resolvedFullPath = (Resolve-Path -LiteralPath $fullPath -ErrorAction Stop).Path.TrimEnd([char[]]"\\/")
        if (-not $resolvedFullPath.StartsWith(
            $resolvedArchivePath + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            Write-Log "НЕБЕЗПЕЧНИЙ КАТАЛОГ ПОЗА ARCHIVEPATH ПРОПУЩЕНО: $fullPath"
            $hadErrors = $true
            continue
        }
        # Видаляти можна лише повний комплект .mdz + .mdz.sha512.
        # Хеш-файли не обробляються окремо, щоб не створювати сироти.
        $files = @(Get-ChildItem -LiteralPath $resolvedFullPath -File -Filter "*_1300.mdz")

        $deletedCount = 0
        $keptCount = 0

        foreach ($file in $files) {
            $hashPath = "$($file.FullName).sha512"
            if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
                Write-Log "НЕПОВНИЙ КОМПЛЕКТ ЗАЛИШЕНО: $($file.Name)"
                $keptCount++
                continue
            }
            $hashFile = Get-Item -LiteralPath $hashPath -ErrorAction Stop
            $setLastWriteTime = (@($file.LastWriteTime, $hashFile.LastWriteTime) | Measure-Object -Maximum).Maximum
            if ($setLastWriteTime -ge $cutoffDate) {
                Write-Host "Залишено обідній комплект (новий): $($file.Name)" -ForegroundColor Green
                $keptCount += 2
                continue
            }
            try {
                if (-not $PSCmdlet.ShouldProcess($file.FullName, "Видалити старий обідній комплект")) {
                    Write-Log "ПЛАН ВИДАЛЕННЯ: $($file.Name) і $($hashFile.Name)"
                    continue
                }
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Remove-Item -LiteralPath $hashFile.FullName -Force -ErrorAction Stop
                $logMessage = "ВИДАЛЕНО КОМПЛЕКТ: $($file.Name) і $($hashFile.Name)"
                Write-Host "Видалено обідній комплект: $($file.Name)" -ForegroundColor Red
                Write-Log $logMessage
                $deletedCount += 2
            } catch {
                $errorMessage = "ПОМИЛКА: $($file.Name) - $($_.Exception.Message)"
                Write-Host "Помилка при видаленні $($file.Name): $($_.Exception.Message)" -ForegroundColor Red
                Write-Log $errorMessage
                $hadErrors = $true
            }
        }

        # Записуємо підсумок по каталогу в лог
        if ($deletedCount -gt 0) {
            Write-Log "ПІДСУМОК $dir : Видалено $deletedCount обідніх архівів"
        }

        Write-Host ("Каталог {0}: видалено {1} обідніх архівів, залишено {2} файлів" -f $dir, $deletedCount, $keptCount) -ForegroundColor Cyan
    }
    else {
        $errorMsg = "Каталог $fullPath не знайдено!"
        Write-Host $errorMsg -ForegroundColor Red
        Write-Log "ПОМИЛКА: $errorMsg"
        $hadErrors = $true
    }
}

if ($hadErrors) {
    Write-Log "=== ЗАВЕРШЕННЯ ОЧИЩЕННЯ АРХІВІВ З ПОМИЛКАМИ ==="
    Write-Host "`nОчищення завершено з помилками. Лог: $logPath" -ForegroundColor Red
    exit 1
}

Write-Log "=== ЗАВЕРШЕННЯ ОЧИЩЕННЯ АРХІВІВ: УСПІШНО ==="
Write-Host "`nОчищення завершено успішно! Лог збережено в: $logPath" -ForegroundColor Green
exit 0
