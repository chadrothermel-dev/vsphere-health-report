function Get-VhRequiredCore {
    <#
        .SYNOPSIS
            Subscription cores required for a host: every physical CPU is counted
            at its core count, with a minimum of MinCoresPerCpu (16) per CPU.
        .EXAMPLE
            Get-VhRequiredCore -Sockets 2 -CoresPerSocket 12   # -> 32
    #>
    param(
        [Parameter(Mandatory)][int]$Sockets,
        [Parameter(Mandatory)][int]$CoresPerSocket,
        [int]$MinCoresPerCpu = 16
    )
    $Sockets * [math]::Max($MinCoresPerCpu, $CoresPerSocket)
}

function Get-VhLicenseSummary {
    <#
        .SYNOPSIS
            Computes the core and vSAN entitlement picture used by the report
            header and the licensing checks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $lic = $Settings.Licensing
    $min = [int]$lic.MinCoresPerCpu
    if ($min -le 0) { $min = 16 }

    $hostRows = foreach ($h in $Inventory.Hosts) {
        $per = [int]$h.CpuCoresPerSocket
        [pscustomobject]@{
            vCenter        = $h.vCenter
            Host           = $h.Name
            Cluster        = $h.Cluster
            Sockets        = [int]$h.CpuSockets
            CoresPerSocket = $per
            PhysicalCores  = [int]$h.CpuCores
            LicensedCores  = Get-VhRequiredCore -Sockets ([int]$h.CpuSockets) -CoresPerSocket $per -MinCoresPerCpu $min
        }
    }
    $physical = [int]((Get-VhSum @($hostRows) 'PhysicalCores'))
    $required = [int]((Get-VhSum @($hostRows) 'LicensedCores'))

    # vSAN: raw capacity of vSAN datastores (vSAN datastore capacity is reported raw)
    $vsanBytesGB = (Get-VhSum @($Inventory.Datastores | Where-Object { $_.Type -eq 'vsan' }) 'CapacityGB')
    $vsanTiB = if ($vsanBytesGB) { [math]::Round($vsanBytesGB / 1024, 2) } else { 0 }

    $model = [string]$lic.Model
    $perCore = 0
    if ($lic.VsanTiBPerCore -and $lic.VsanTiBPerCore.ContainsKey($model)) { $perCore = [double]$lic.VsanTiBPerCore[$model] }

    $purchased = [int]$lic.PurchasedCores
    $coreBasis = if ($purchased -gt 0) { $purchased } else { $required }
    # Entitlement rounds up to the next whole TiB
    $includedTiB = [math]::Ceiling($coreBasis * $perCore)
    $entitledTiB = $includedTiB + [double]$lic.VsanAddOnTiB

    $majors = @($Inventory.vCenters | ForEach-Object { [int](([string]$_.Version).Split('.')[0]) })
    $usesKeys = [bool]($majors | Where-Object { $_ -lt 9 })
    $usesFile = [bool]($majors | Where-Object { $_ -ge 9 })

    $usageDue = $null; $usageDaysLeft = $null
    if ($usesFile -and $lic.UsageReportLastSubmitted) {
        $last = [datetime]::ParseExact($lic.UsageReportLastSubmitted, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $usageDue = $last.AddDays([int]$lic.UsageReportIntervalDays)
        $usageDaysLeft = [int][math]::Floor(($usageDue - (Get-Date).Date).TotalDays)
    }

    [pscustomobject]@{
        Model              = $model
        LicensingMethod    = if ($usesKeys -and $usesFile) { 'Mixed (license keys + VCF license file)' } elseif ($usesFile) { 'VCF license file (VCF Operations)' } else { 'License keys (vCenter)' }
        UsesLicenseKeys    = $usesKeys
        UsesLicenseFile    = $usesFile
        HostCount          = @($hostRows).Count
        PhysicalCores      = $physical
        RequiredCores      = $required
        MinimumCoreUplift  = $required - $physical
        PurchasedCores     = $purchased
        CoreShortfall      = if ($purchased -gt 0) { [math]::Max(0, $required - $purchased) } else { $null }
        VsanRawTiB         = $vsanTiB
        VsanTiBPerCore     = $perCore
        VsanIncludedTiB    = $includedTiB
        VsanAddOnTiB       = [double]$lic.VsanAddOnTiB
        VsanEntitledTiB    = $entitledTiB
        VsanShortfallTiB   = [math]::Max(0, [math]::Ceiling($vsanTiB - $entitledTiB))
        UsageReportDue     = $usageDue
        UsageReportDaysLeft = $usageDaysLeft
        Hosts              = @($hostRows)
    }
}
