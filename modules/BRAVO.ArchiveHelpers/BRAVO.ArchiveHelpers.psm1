# Shared BRAVO archive helpers with an explicit Compatibility dependency.

$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

function Write-BRAVOArchiveHelperLog {
    param(
        [AllowNull()][scriptblock]$Logger,
        [string]$Message,
        [string]$Level = 'INFO'
    )

    if ($null -ne $Logger) {
        & $Logger $Message $Level
    }
}

function Remove-OldLogsByAge {
    param(
        [string]$Path,
        [string]$Filter,
        [int]$RetentionDays,
        [AllowNull()][scriptblock]$Logger
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $failed = $false
    foreach ($file in @(Get-BRAVOFiles -Path $Path -Filter $Filter |
        Where-Object { $_.LastWriteTime -lt $cutoff })) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-BRAVOArchiveHelperLog `
                -Logger $Logger `
                -Message "Видалено старий лог: $($file.Name)" `
                -Level "SUCCESS"
        } catch {
            $failed = $true
            Write-BRAVOArchiveHelperLog `
                -Logger $Logger `
                -Message "Не вдалося видалити лог $($file.Name): $($_.Exception.Message)" `
                -Level "ERROR"
        }
    }
    return (-not $failed)
}

function Test-SevenZipArchiveIntegrity {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Тонка обгортка над Invoke-BRAVOSevenZipIntegrityTest — пароль іде далі через redirected stdin.')]
    param(
        [string]$SevenZipPath,
        [string]$ArchivePath,
        [string]$Password,
        [int]$TimeoutSeconds = 43200,
        [AllowNull()][scriptblock]$Logger
    )

    Write-BRAVOArchiveHelperLog `
        -Logger $Logger `
        -Message "Перевiрка цiлiсностi 7-Zip: $(Split-Path $ArchivePath -Leaf)"
    $testResult = Invoke-BRAVOSevenZipIntegrityTest `
        -SevenZipPath $SevenZipPath `
        -ArchivePath $ArchivePath `
        -Password $Password `
        -TimeoutSeconds $TimeoutSeconds

    $exitCodeText = if ($null -eq $testResult.ExitCode) {
        "немає"
    } else {
        [string]$testResult.ExitCode
    }
    if ($testResult.Success) {
        Write-BRAVOArchiveHelperLog `
            -Logger $Logger `
            -Message "Цiлiснiсть архiву пiдтверджено 7-Zip (код: 0): $ArchivePath" `
            -Level "SUCCESS"
        return $true
    }

    Write-BRAVOArchiveHelperLog `
        -Logger $Logger `
        -Message "Перевiрка цiлiсностi 7-Zip не пройдена (код: $exitCodeText — $($testResult.Description)): $ArchivePath" `
        -Level "ERROR"
    $diagnosticLines = @(
        @($testResult.StandardError, $testResult.StandardOutput) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ -split '\r?\n' } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 20
    )
    if ($diagnosticLines.Count -gt 0) {
        Write-BRAVOArchiveHelperLog `
            -Logger $Logger `
            -Message "Дiагностика 7-Zip test: $($diagnosticLines -join [Environment]::NewLine)" `
            -Level "DEBUG"
    }
    return $false
}

function Get-BRAVOValidArchiveSizeHistory {
    # AUD-008 (аудит P1.6): для sanity-check обсягу backup потрібна історія
    # РОЗМІРІВ попередніх валідних (hash-підтверджених) архівів того самого
    # компонента. Той самий алгоритм валідації, що Remove-OldBackupSets
    # (BRAVO.Archive.Runtime.ps1) використовує для retention — сюди
    # свідомо не винесений як спільна функція, щоб не чіпати вже
    # перевірений retention-код; тут лише збирається .Length, видалення
    # не відбувається.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$ArchiveFilter,
        [Parameter(Mandatory = $true)][string]$HashFileExtension,
        [string]$ExcludeArchivePath,
        [int]$MaxCount = 5
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }
    $validSizes = New-Object System.Collections.Generic.List[pscustomobject]
    $candidates = @(Get-BRAVOFiles -Path $Directory -Filter $ArchiveFilter |
        Sort-Object -Property LastWriteTime -Descending)
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($ExcludeArchivePath) -and
            [string]::Equals($candidate.FullName, $ExcludeArchivePath, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $hashPath = "$($candidate.FullName)$HashFileExtension"
        try {
            if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
                continue
            }
            $hashText = ([System.IO.File]::ReadAllText($hashPath)).Trim([char]0xFEFF).Trim()
            if ($hashText -notmatch '^(?<Hash>[a-fA-F0-9]{128})\s+\*(?<FileName>.+)$') {
                continue
            }
            if ($Matches.FileName -cne $candidate.Name) {
                continue
            }
            $expectedHash = $Matches.Hash.ToUpperInvariant()
            $actualHash = (Get-BRAVOFileHash -Path $candidate.FullName -Algorithm SHA512).Hash.ToUpperInvariant()
            if ($actualHash -cne $expectedHash) {
                continue
            }
        } catch {
            continue
        }
        $validSizes.Add([pscustomobject]@{
            Path = $candidate.FullName
            Bytes = [int64]$candidate.Length
            LastWriteTime = $candidate.LastWriteTime
        })
        if ($validSizes.Count -ge $MaxCount) {
            break
        }
    }
    return @($validSizes)
}

function Test-BRAVOBackupSizeAnomaly {
    # AUD-008 (аудит P1.6): "успішний" backup технічно валідний (7za test +
    # SHA512 збігається), але може бути ПІДОЗРІЛО малим через неправильне
    # джерело, поламані permissions, неповний VSS exposure чи помилку
    # wildcard — сам файл при цьому виглядає коректним. Порівнює новий
    # архів із медіаною останніх валідних архівів того самого компонента;
    # НЕ блокує (лише сигналізує) — критичність лишається за викликачем.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int64]$NewArchiveBytes,
        [Parameter(Mandatory = $true)][string]$HistoryDirectory,
        [Parameter(Mandatory = $true)][string]$ArchiveFilter,
        [Parameter(Mandatory = $true)][string]$HashFileExtension,
        [string]$ExcludeArchivePath,
        [int]$HistoryCount = 5,
        [int64]$MinimumBytes = 1024,
        [int]$MaxSizeDropPercent = 50
    )

    $history = @(Get-BRAVOValidArchiveSizeHistory `
        -Directory $HistoryDirectory `
        -ArchiveFilter $ArchiveFilter `
        -HashFileExtension $HashFileExtension `
        -ExcludeArchivePath $ExcludeArchivePath `
        -MaxCount $HistoryCount)

    if ($NewArchiveBytes -lt $MinimumBytes) {
        return [pscustomobject]@{
            IsAnomaly = $true
            Reason = "розмір архіву ($NewArchiveBytes байт) менший за мінімально допустимий ($MinimumBytes байт)"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $null
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    if ($history.Count -eq 0) {
        return [pscustomobject]@{
            IsAnomaly = $false
            Reason = "недостатньо історії валідних архівів для порівняння (перший backup цього компонента чи ще не накопичено історію)"
            HistorySampleCount = 0
            MedianHistoricalBytes = $null
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    $sortedSizes = @($history | Select-Object -ExpandProperty Bytes | Sort-Object)
    $middleIndex = [math]::Floor($sortedSizes.Count / 2)
    $medianBytes = if ($sortedSizes.Count % 2 -eq 0 -and $sortedSizes.Count -ge 2) {
        [int64][math]::Round(($sortedSizes[$middleIndex - 1] + $sortedSizes[$middleIndex]) / 2.0)
    } else {
        [int64]$sortedSizes[$middleIndex]
    }

    if ($medianBytes -le 0) {
        return [pscustomobject]@{
            IsAnomaly = $false
            Reason = "медіана історичних розмірів нульова — порівняння неможливе"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $medianBytes
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $null
        }
    }

    $dropPercent = [math]::Round((1.0 - ([double]$NewArchiveBytes / [double]$medianBytes)) * 100.0, 1)
    if ($dropPercent -gt $MaxSizeDropPercent) {
        return [pscustomobject]@{
            IsAnomaly = $true
            Reason = "розмір архіву впав на $dropPercent% відносно медіани останніх $($history.Count) валідних backup (поріг: $MaxSizeDropPercent%)"
            HistorySampleCount = $history.Count
            MedianHistoricalBytes = $medianBytes
            NewArchiveBytes = $NewArchiveBytes
            DropPercent = $dropPercent
        }
    }

    return [pscustomobject]@{
        IsAnomaly = $false
        Reason = "у межах норми (відхилення від медіани: $dropPercent%)"
        HistorySampleCount = $history.Count
        MedianHistoricalBytes = $medianBytes
        NewArchiveBytes = $NewArchiveBytes
        DropPercent = $dropPercent
    }
}
