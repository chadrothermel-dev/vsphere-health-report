@{
    RootModule        = 'VsphereHealth.psm1'
    ModuleVersion     = '1.1.2'
    GUID              = '5d0f3c1e-8a4b-4b8e-9f2a-6f1c2e7d9a41'
    Author            = 'Chad Rothermel'
    Description       = 'Health, compliance and licensing report for VMware vSphere 8, VCF/vSphere 9 and Dell VxRail 8, with as-built hardware documentation.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Connect-VhServer', 'Disconnect-VhServer', 'Get-VhInventory', 'Merge-VhInventory', 'Import-VhInventoryJson',
        'Import-VhSettings', 'Get-VhHealthCheck', 'Invoke-VhHealthCheck', 'Get-VhLicenseSummary',
        'Get-VhRequiredCore', 'ConvertTo-VhHtmlReport', 'Export-VhReport', 'Send-VhReport',
        'Get-VhVxRailInventory', 'Get-VhVxRailTarget', 'Get-VhAsBuiltTable', 'ConvertTo-VhAsBuiltHtml', 'Export-VhAsBuiltWorkbook'
    )
    PrivateData       = @{
        PSData = @{
            Tags       = @('VMware', 'vSphere', 'VCF', 'PowerCLI', 'Health', 'Report', 'Licensing', 'VxRail', 'AsBuilt')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
