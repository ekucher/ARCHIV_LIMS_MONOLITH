@{
    RootModule = 'BRAVO.Credentials.psm1'
    ModuleVersion = '4.2.13'
    GUID = '8c5d5f3a-34e5-482b-ae31-80d5e39227ee'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Initialize-BRAVOCredentialManager', 'Get-BRAVOCredential', 'Get-BRAVOCredentialSecret', 'Set-BRAVOCredential', 'Remove-BRAVOCredential', 'Get-BRAVOCredentialIdentity', 'Get-BRAVOArchivePasswordTarget', 'Test-BRAVOInstitutionSettingValue', 'Import-BRAVOInstitutionSettings', 'Resolve-BRAVOSftpHostName', 'New-BRAVOSftpUrl')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
