function Register-VhCheck {
    <#
        .SYNOPSIS
            Registers a health check. Called by the files in src\Checks.
        .PARAMETER Script
            Scriptblock with param($Inventory, $Settings). Returns zero or more rows.
            A row may carry a 'Severity' property (Info|Warning|Critical) to override
            the default severity for that row.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Licensing', 'Lifecycle', 'vCenter', 'Clusters', 'Hosts', 'Storage', 'Virtual Machines', 'Networking')]
        [string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('Info', 'Warning', 'Critical')][string]$Severity,
        [Parameter(Mandatory)][string]$Description,
        [string]$Remediation = '',
        [string[]]$AppliesTo = @(),          # major versions; empty = all
        [Parameter(Mandatory)][scriptblock]$Script
    )
    $script:HealthChecks.Add([pscustomobject]@{
            Id          = $Id
            Category    = $Category
            Title       = $Title
            Severity    = $Severity
            Description = $Description
            Remediation = $Remediation
            AppliesTo   = $AppliesTo
            Script      = $Script
        })
}

function Get-VhHealthCheck {
    [CmdletBinding()]
    param([string[]]$Id, [string]$Category)
    $script:HealthChecks |
        Where-Object { (-not $Id -or $_.Id -in $Id) -and (-not $Category -or $_.Category -eq $Category) } |
        Select-Object Id, Category, Title, Severity, AppliesTo, Description, Remediation
}

function Invoke-VhHealthCheck {
    <#
        .SYNOPSIS
            Runs every registered check against an inventory and returns results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $disabled = @($Settings.DisabledChecks)
    $majors = @($Inventory.vCenters | ForEach-Object { ([string]$_.Version).Split('.')[0] } | Select-Object -Unique)

    foreach ($check in $script:HealthChecks) {
        $result = [ordered]@{
            Id = $check.Id; Category = $check.Category; Title = $check.Title
            Description = $check.Description; Remediation = $check.Remediation
            DefaultSeverity = $check.Severity; Severity = 'Pass'; Status = 'Pass'
            Rows = @(); Error = $null; DurationMs = 0
        }
        if ($check.Id -in $disabled) {
            $result.Status = 'Skipped'; $result.Severity = 'Pass'
            [pscustomobject]$result; continue
        }
        if (@($check.AppliesTo).Count -and -not ($majors | Where-Object { $_ -in $check.AppliesTo })) {
            $result.Status = 'NotApplicable'
            [pscustomobject]$result; continue
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $rows = @(& $check.Script $Inventory $Settings | Where-Object { $null -ne $_ })
            if ($rows.Count -gt 0) {
                # Rows that carry their own Severity decide the check severity
                # (can be lower than the default, e.g. all rows Info); otherwise the default applies.
                $worst = $check.Severity
                if ($rows[0].PSObject.Properties['Severity']) {
                    $worst = $rows | ForEach-Object { [string]$_.Severity } |
                        Sort-Object { $script:SeverityRank[$_] } -Descending | Select-Object -First 1
                }
                $result.Severity = $worst
                $result.Status = 'Finding'
                $result.Rows = $rows
            }
        }
        catch {
            $result.Status = 'Error'
            $result.Severity = 'Error'
            $result.Error = $_.Exception.Message
        }
        $sw.Stop()
        $result.DurationMs = [int]$sw.Elapsed.TotalMilliseconds
        [pscustomobject]$result
    }
}

function Get-VhHealthScore {
    <#  Weighted percentage of applicable checks that passed.
        Critical checks weigh 5, Warning 3, Info 1. #>
    param([Parameter(Mandatory)][object[]]$Results)
    $scored = $Results | Where-Object { $_.Status -in 'Pass', 'Finding' }
    $total = 0; $lost = 0
    foreach ($r in $scored) {
        $w = $script:SeverityWeight[$r.DefaultSeverity]
        $total += $w
        if ($r.Status -eq 'Finding' -and $r.Severity -ne 'Info') { $lost += $w }
    }
    if ($total -eq 0) { return 100 }
    [int][math]::Round(100 * ($total - $lost) / $total)
}

function Import-VhSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Settings file not found: $Path" }
    Import-PowerShellDataFile -Path $Path
}

function Test-VhExcluded {
    param([string]$Name, [string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    return $Name -match $Pattern
}

function Get-VhSum {
    # Null-safe sum (Measure-Object returns nothing for empty input, which breaks StrictMode)
    param([object[]]$InputObject, [string]$Property)
    $total = 0
    foreach ($o in @($InputObject)) {
        if ($null -eq $o) { continue }
        $v = if ($Property) { $o.$Property } else { $o }
        if ($null -ne $v) { $total += [double]$v }
    }
    $total
}

function ConvertTo-VhDate {
    # Dates arrive as DateTime (live / PS7 JSON) or ISO strings (PS5.1 JSON)
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-VhMajorMinor {
    param([string]$Version)
    $p = ([string]$Version).Split('.')
    if ($p.Count -ge 2) { return "$($p[0]).$($p[1])" }
    return $Version
}
