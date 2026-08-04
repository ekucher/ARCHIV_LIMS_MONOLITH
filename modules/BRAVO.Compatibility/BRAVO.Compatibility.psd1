@{
    RootModule = 'BRAVO.Compatibility.psm1'
    ModuleVersion = '4.2.12'
    GUID = 'c5da1e9b-a766-4a47-a0ef-396b3fcbbe9e'
    PowerShellVersion = '3.0'
    FunctionsToExport = @('Assert-BRAVOPowerShellCompatibility', 'Initialize-BRAVOConsoleEncoding', 'Test-BRAVOCommandAvailable', 'ConvertTo-BRAVOAccountSidValue', 'Test-BRAVOAccountIdentityEquivalent', 'Get-BRAVOCompatibilityInfo', 'Get-BRAVOPowerShellUpdateRecommendation', 'Get-BRAVOWindowsPatchLevelRecommendation', 'Get-BRAVOWmiInstance', 'Get-BRAVOFiles', 'Get-BRAVODirectories', 'Get-BRAVOFileHash', 'Test-BRAVOTcpConnection', 'Get-BRAVOScheduledTaskState', 'Enable-BRAVOTls12', 'Read-BRAVOTextFile', 'ConvertTo-BRAVOJsonCompatibleObject', 'ConvertTo-BRAVOJson', 'ConvertFrom-BRAVOJsonCompatibleObject', 'ConvertFrom-BRAVOJson', 'Start-BRAVOProcessOutputCapture', 'Complete-BRAVOProcessOutputCapture', 'Get-BRAVOSevenZipExitCodeDescription', 'ConvertTo-BRAVOWindowsCommandLineArgument', 'Invoke-BRAVOSevenZipIntegrityTest', 'Send-BRAVOWebhookNotification', 'Get-BRAVOTaskStateName')
    VariablesToExport = @()
    CmdletsToExport = @()
    AliasesToExport = @()
}
