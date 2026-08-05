@{
    RootModule = 'BRAVO.ArchiveHelpers.psm1'
    ModuleVersion = '4.4.1'
    GUID = '0a073e11-f066-4dc5-b9f7-24aae1a9b3df'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Remove-OldLogsByAge', 'Test-SevenZipArchiveIntegrity', 'Get-BRAVOValidArchiveSizeHistory', 'Test-BRAVOBackupSizeAnomaly')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
