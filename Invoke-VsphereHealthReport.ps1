#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a health, compliance and licensing report for VMware vSphere 8 and VCF/vSphere 9.

.DESCRIPTION
    Connects read-only to one or more vCenter Servers, collects inventory once with
    property-filtered Get-View calls, runs ~45 checks and writes a self-contained
    HTML report plus CSV and JSON exports. Optionally emails a summary.

.PARAMETER Server
    vCenter Server(s). Overrides Connection.Servers in the settings file.

.PARAMETER Credential
    vCenter credential. Overrides Connection.CredentialFile.

.PARAMETER ConfigPath
    Settings file (.psd1). Defaults to .\config\Settings.psd1.

.PARAMETER OutputPath
    Report output folder. Overrides Report.OutputPath.

.PARAMETER SampleData
    Render from a saved inventory JSON instead of connecting (demo, testing, offline review).

.PARAMETER SaveInventory
    Also save the raw collected inventory as inventory.json (can be replayed with -SampleData).

.PARAMETER SendEmail
    Send the email summary even if Email.Enabled is $false.

.EXAMPLE
    .\Invoke-VsphereHealthReport.ps1 -Server vcsa01.corp.local

.EXAMPLE
    .\Invoke-VsphereHealthReport.ps1 -SampleData .\samples\sample-inventory.json -Open

.EXAMPLE
    # Store credentials once (DPAPI-encrypted for this user on this machine)
    Get-Credential | Export-Clixml .\config\vcenter.cred.xml
    .\Invoke-VsphereHealthReport.ps1 -ConfigPath .\config\Settings.prod.psd1
#>
[CmdletBinding()]
param(
    [string[]]$Server,
    [pscredential]$Credential,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config/Settings.psd1'),
    [string]$OutputPath,
    [string]$SampleData,
    [switch]$SaveInventory,
    [switch]$SendEmail,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$toolVersion = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'src/VsphereHealth.psd1')).ModuleVersion
Import-Module (Join-Path $PSScriptRoot 'src/VsphereHealth.psd1') -Force

$settings = Import-VhSettings -Path $ConfigPath
if ($OutputPath) { $settings.Report.OutputPath = $OutputPath }
$outRoot = $settings.Report.OutputPath
if (-not [IO.Path]::IsPathRooted($outRoot)) { $outRoot = Join-Path $PSScriptRoot $outRoot }

$sw = [Diagnostics.Stopwatch]::StartNew()
$connections = @()
try {
    if ($SampleData) {
        Write-Host "Loading sample inventory: $SampleData" -ForegroundColor Cyan
        $inventory = Import-VhInventoryJson -Path (Resolve-Path $SampleData).Path
    }
    else {
        $targets = if ($Server) { $Server } else { @($settings.Connection.Servers) }
        $connections = @(Connect-VhServer -Server $targets -Credential $Credential -CredentialFile $settings.Connection.CredentialFile `
                -AllLinked:([bool]$settings.Connection.AllLinked) -InvalidCertificateAction $settings.Connection.InvalidCertificateAction)
        $perVc = foreach ($c in $connections) {
            Write-Host "Collecting inventory from $($c.Name) (vCenter $($c.Version))" -ForegroundColor Cyan
            Get-VhInventory -Server $c
        }
        $inventory = Merge-VhInventory -Inventory @($perVc)
    }

    Write-Host 'Running health checks' -ForegroundColor Cyan
    $results = @(Invoke-VhHealthCheck -Inventory $inventory -Settings $settings)
    $sw.Stop()

    $paths = Export-VhReport -Results $results -Inventory $inventory -Settings $settings -OutputPath $outRoot -Duration $sw.Elapsed -ToolVersion $toolVersion
    if ($SaveInventory) {
        $inventory | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $paths.Folder 'inventory.json') -Encoding UTF8
    }

    if ($SendEmail -or $settings.Email.Enabled) {
        Write-Host 'Sending email summary' -ForegroundColor Cyan
        Send-VhReport -Results $results -Settings $settings -HtmlPath $paths.Html
    }

    $sev = $results | Where-Object Status -eq 'Finding' | Group-Object Severity -NoElement
    Write-Host ''
    Write-Host ('Findings: ' + (($sev | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  ')) -ForegroundColor Yellow
    $errors = @($results | Where-Object Status -eq 'Error')
    if ($errors) { Write-Warning ("Checks with errors: " + (($errors | ForEach-Object { "$($_.Id): $($_.Error)" }) -join '; ')) }
    Write-Host "Report: $($paths.Folder)" -ForegroundColor Green
    if (($Open -or $settings.Report.OpenWhenDone) -and $paths.Html) { Invoke-Item $paths.Html }
    $paths
}
finally {
    if ($connections) { Disconnect-VhServer -Server $connections }
}
