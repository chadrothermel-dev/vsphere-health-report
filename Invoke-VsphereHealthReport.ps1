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

.PARAMETER ReportType
    Health (daily findings), AsBuilt (full configuration and hardware document, incl. VxRail) or Both.
    Defaults to Report.Type in the settings file.

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
    .\Invoke-VsphereHealthReport.ps1 -Server vcsa01.corp.local -ReportType AsBuilt -Open

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
    # Health = daily findings report; AsBuilt = full configuration + hardware document; Both
    [ValidateSet('Health', 'AsBuilt', 'Both')][string]$ReportType,
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
if (-not $ReportType) { $ReportType = if ($settings.Report.Type) { [string]$settings.Report.Type } else { 'Health' } }
$asBuilt = $ReportType -in 'AsBuilt', 'Both'
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
        if (-not $Credential -and $settings.Connection.CredentialFile) { $Credential = Import-Clixml -Path $settings.Connection.CredentialFile }
        if (-not $Credential) { $Credential = Get-Credential -Message 'vCenter credentials' }
        $targets = if ($Server) { $Server } else { @($settings.Connection.Servers) }
        $connections = @(Connect-VhServer -Server $targets -Credential $Credential `
                -AllLinked:([bool]$settings.Connection.AllLinked) -InvalidCertificateAction $settings.Connection.InvalidCertificateAction)
        $useEsxcli = $asBuilt -and $settings.AsBuilt -and [bool]$settings.AsBuilt.UseEsxcli
        if (-not $connections.Count) { throw "Could not connect to any vCenter Server ($($targets -join ', '))." }
        $perVc = @(foreach ($c in $connections) {
                Write-Host "Collecting inventory from $($c.Name) (vCenter $($c.Version))$(if ($asBuilt) { ' with hardware detail' })" -ForegroundColor Cyan
                # Keep only the inventory object, in case anything else leaked into the pipeline
                $inv = @(Get-VhInventory -Server $c -IncludeHardware:$asBuilt -UseEsxcli:$useEsxcli) |
                    Where-Object { $_ -and $_.PSObject.Properties['vCenters'] } | Select-Object -Last 1
                if ($inv) { $inv }
                else { Write-Warning "No inventory was returned from $($c.Name). Re-run with -Verbose to see where collection stopped." }
            })
        if (-not $perVc.Count) {
            throw "No inventory was collected from $(@($connections | ForEach-Object Name) -join ', '). See the errors/warnings above, or re-run with -Verbose."
        }
        $inventory = Merge-VhInventory -Inventory $perVc

        # VxRail Manager API (clusters tagged with the VxRail-IP attribute, or listed in Settings.VxRail.Managers)
        $vx = $settings.VxRail
        if ($vx -and $vx.Enabled) {
            $vxCred = if ($vx.CredentialFile) { Import-Clixml -Path $vx.CredentialFile } else { $Credential }
            $skip = [bool]$vx.SkipCertificateCheck -or $settings.Connection.InvalidCertificateAction -eq 'Ignore'
            $inventory.VxRail = @(foreach ($t in @(Get-VhVxRailTarget -Inventory $inventory -Settings $settings)) {
                    Write-Host "Querying VxRail Manager $($t.Manager) (cluster $($t.Cluster))" -ForegroundColor Cyan
                    Get-VhVxRailInventory -Manager $t.Manager -Credential $vxCred -Cluster $t.Cluster -vCenter $t.vCenter `
                        -SkipCertificateCheck:$skip -IncludeIdrac:([bool]$vx.IncludeIdrac) -KeepRaw:$SaveInventory
                })
        }
    }

    Write-Host 'Running health checks' -ForegroundColor Cyan
    $results = @(Invoke-VhHealthCheck -Inventory $inventory -Settings $settings)
    $sw.Stop()

    $paths = Export-VhReport -Results $results -Inventory $inventory -Settings $settings -OutputPath $outRoot -Duration $sw.Elapsed -ToolVersion $toolVersion -ReportType $ReportType
    if ($SaveInventory) {
        # Includes raw VxRail API responses - useful to validate field names on a new VxRail release
        $inventory | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $paths.Folder 'inventory.json') -Encoding UTF8
    }

    if (($SendEmail -or $settings.Email.Enabled) -and $ReportType -ne 'AsBuilt') {
        Write-Host 'Sending email summary' -ForegroundColor Cyan
        Send-VhReport -Results $results -Settings $settings -HtmlPath $paths.Html
    }

    $sev = $results | Where-Object Status -eq 'Finding' | Group-Object Severity -NoElement
    Write-Host ''
    Write-Host ('Findings: ' + (($sev | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  ')) -ForegroundColor Yellow
    $errors = @($results | Where-Object Status -eq 'Error')
    if ($errors) { Write-Warning ("Checks with errors: " + (($errors | ForEach-Object { "$($_.Id): $($_.Error)" }) -join '; ')) }
    Write-Host "Report: $($paths.Folder)" -ForegroundColor Green
    if ($Open -or $settings.Report.OpenWhenDone) {
        foreach ($p in @($paths.Html, $paths.AsBuilt)) { if ($p) { Invoke-Item $p } }
    }
    $paths
}
finally {
    if ($connections) { Disconnect-VhServer -Server $connections }
}
