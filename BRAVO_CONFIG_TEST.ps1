#requires -Version 3.0

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
} else {
    [Environment]::CurrentDirectory
}

$loaderPath = Join-Path $scriptRoot 'BRAVO_CONFIG_LOADER.ps1'
if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
    throw "Configuration loader not found: $loaderPath"
}

. $loaderPath

$result = Import-BravoConfiguration `
    -ConfigRoot $scriptRoot `
    -ConfigPath $ConfigPath `
    -PassThru

$validation = [pscustomobject]@{
    Status = 'OK'
    Product = $result.Version.Product
    PackageVersion = $result.Version.PackageVersion
    LegacyScriptVersion = $result.Configuration.LegacyScriptVersion
    PackageVersionMatchesLegacyConfig = $result.Configuration.PackageVersionMatchesLegacyConfig
    ConfigSchemaVersion = $result.Configuration.ConfigSchemaVersion
    ConfigFormat = $result.Configuration.Format
    ConfigPath = $result.Configuration.ConfigPath
    LIMSRoot = [string]$result.PathSettings.LIMSRoot
    ArchiveRoot = [string]$result.PathSettings.ArchiveRoot
    BackupRoot = [string]$result.PathSettings.BackupRoot
    LoadedAt = $result.Configuration.LoadedAt
}

if ($AsJson) {
    $validation | ConvertTo-Json -Depth 5
    exit 0
}

Write-Host ('[INFO] Configuration loaded: {0}' -f $validation.ConfigPath)
Write-Host ('[INFO] Package version: {0}' -f $validation.PackageVersion)
Write-Host ('[INFO] Legacy config version: {0}' -f $validation.LegacyScriptVersion)
Write-Host ('[INFO] Configuration schema: {0}' -f $validation.ConfigSchemaVersion)
Write-Host ('[INFO] LIMSRoot: {0}' -f $validation.LIMSRoot)
Write-Host ('[INFO] ArchiveRoot: {0}' -f $validation.ArchiveRoot)
Write-Host ('[INFO] BackupRoot: {0}' -f $validation.BackupRoot)

if (-not [string]::IsNullOrWhiteSpace([string]$validation.LegacyScriptVersion) -and
    -not $validation.PackageVersionMatchesLegacyConfig) {
    Write-Warning (
        'Transitional state: VERSION.json and BRAVO.config have different versions. ' +
        'This is allowed only until loader integration into production scripts is complete.'
    )
}

Write-Host '[SUCCESS] Configuration validation completed successfully.'
exit 0
