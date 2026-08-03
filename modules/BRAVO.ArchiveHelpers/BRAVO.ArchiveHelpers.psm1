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
