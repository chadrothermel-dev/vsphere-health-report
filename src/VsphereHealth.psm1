#Requires -Version 5.1
<#
    VsphereHealth module
    Collect once -> evaluate checks against plain objects -> render.
    Checks never call PowerCLI; they only read the inventory object, which makes
    them fast, testable offline, and safe to run against sample data.
#>

Set-StrictMode -Version 2.0

$script:HealthChecks = [System.Collections.Generic.List[object]]::new()
$script:SeverityRank = @{ Pass = 0; Info = 1; Warning = 2; Critical = 3; Error = 2 }
$script:SeverityWeight = @{ Info = 1; Warning = 3; Critical = 5 }

foreach ($folder in 'Private', 'Checks') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { . $_.FullName }
}

Export-ModuleMember -Function @(
    'Connect-VhServer'
    'Disconnect-VhServer'
    'Get-VhInventory'
    'Merge-VhInventory'
    'Import-VhInventoryJson'
    'Import-VhSettings'
    'Get-VhHealthCheck'
    'Invoke-VhHealthCheck'
    'Get-VhLicenseSummary'
    'Get-VhRequiredCore'
    'ConvertTo-VhHtmlReport'
    'Export-VhReport'
    'Send-VhReport'
)
