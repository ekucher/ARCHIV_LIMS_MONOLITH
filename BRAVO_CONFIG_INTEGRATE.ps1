#requires -Version 3.0

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RootPath,
    [switch]$KeepBackup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $PSScriptRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    } else {
        [Environment]::CurrentDirectory
    }
}

$RootPath = [System.IO.Path]::GetFullPath($RootPath)
$loaderPath = Join-Path $RootPath 'BRAVO_CONFIG_LOADER.ps1'
if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
    throw "Configuration loader not found: $loaderPath"
}

$targets = @(
    'BRAVO_ARCHIV.ps1',
    'BRAVO_MAINTENANCE.ps1'
)

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backups = New-Object System.Collections.Generic.List[object]
$changed = New-Object System.Collections.Generic.List[string]

$legacyPattern = '(?ms)(?<indent>^[ \t]*)\$configRoot\s*=\s*Split-Path\s+-Path\s+\$(?:ConfigPath|configPath)\s+-Parent\s*\r?\n\k<indent>\$configText\s*=\s*\[System\.IO\.File\]::ReadAllText\(\$(?:ConfigPath|configPath),\s*\[System\.Text\.Encoding\]::UTF8\)\s*\r?\n\k<indent>\$configScript\s*=\s*\[scriptblock\]::Create\(\$configText\)\s*\r?\n\k<indent>&\s+\$configScript\s+-ConfigRoot\s+\$configRoot'

try {
    foreach ($targetName in $targets) {
        $targetPath = Join-Path $RootPath $targetName
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "Production script not found: $targetPath"
        }

        $original = [System.IO.File]::ReadAllText($targetPath, [System.Text.Encoding]::UTF8)
        if ($original -match 'Import-BravoConfiguration\s+`?\s*-ConfigRoot') {
            Write-Host "[INFO] Loader already integrated: $targetName"
            continue
        }

        $matchCount = [regex]::Matches($original, $legacyPattern).Count
        $expectedMinimum = if ($targetName -eq 'BRAVO_ARCHIV.ps1') { 2 } else { 1 }
        if ($matchCount -lt $expectedMinimum) {
            throw "Unexpected legacy configuration blocks in ${targetName}: found $matchCount, expected at least $expectedMinimum"
        }

        $replacementEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $indent = $match.Groups['indent'].Value
            return @(
                '${indent}$configRoot = Split-Path -Path $ConfigPath -Parent',
                '${indent}$configurationLoaderPath = Join-Path $configRoot ''BRAVO_CONFIG_LOADER.ps1''',
                '${indent}if (-not (Test-Path -LiteralPath $configurationLoaderPath -PathType Leaf)) {',
                '${indent}    throw "Configuration loader not found: $configurationLoaderPath"',
                '${indent}}',
                '${indent}. $configurationLoaderPath',
                '${indent}Import-BravoConfiguration `',
                '${indent}    -ConfigRoot $configRoot `',
                '${indent}    -ConfigPath $ConfigPath'
            ).Replace('${indent}', $indent) -join [Environment]::NewLine
        }

        $updated = [regex]::Replace($original, $legacyPattern, $replacementEvaluator)
        if ($updated -ceq $original) {
            throw "No changes produced for $targetName"
        }

        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $updated,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -gt 0) {
            $details = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
            throw "PowerShell parser rejected updated ${targetName}: $details"
        }

        $backupPath = "$targetPath.pre-loader-$timestamp.bak"
        [System.IO.File]::WriteAllText($backupPath, $original, $utf8Bom)
        $backups.Add([pscustomobject]@{ Target = $targetPath; Backup = $backupPath })

        if ($PSCmdlet.ShouldProcess($targetPath, 'Integrate BRAVO_CONFIG_LOADER')) {
            [System.IO.File]::WriteAllText($targetPath, $updated, $utf8Bom)
            $changed.Add($targetName)
            Write-Host "[SUCCESS] Loader integrated: $targetName ($matchCount blocks)"
        }
    }

    if ($changed.Count -eq 0) {
        Write-Host '[INFO] No production scripts required changes.'
        exit 0
    }

    foreach ($targetName in $changed) {
        $targetPath = Join-Path $RootPath $targetName
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $targetPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -gt 0) {
            throw "Post-write syntax validation failed: $targetName"
        }
    }

    if (-not $KeepBackup) {
        foreach ($backup in $backups) {
            Remove-Item -LiteralPath $backup.Backup -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ('[SUCCESS] Integration completed: {0}' -f ($changed -join ', '))
    Write-Host '[INFO] Run BRAVO_CONFIG_TEST.ps1 and review git diff before committing.'
    exit 0
}
catch {
    foreach ($backup in $backups) {
        if (Test-Path -LiteralPath $backup.Backup -PathType Leaf) {
            Copy-Item -LiteralPath $backup.Backup -Destination $backup.Target -Force
        }
    }
    Write-Error "Loader integration failed and modified files were restored: $($_.Exception.Message)"
    exit 1
}
