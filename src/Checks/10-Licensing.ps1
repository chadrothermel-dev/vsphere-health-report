Register-VhCheck -Id 'LIC-001' -Category 'Licensing' -Severity 'Critical' `
    -Title 'Assets running on evaluation licenses' `
    -Description 'vCenter, hosts or vSAN clusters assigned the evaluation key stop working (hosts disconnect, VMs cannot power on) when the evaluation period ends.' `
    -Remediation 'vSphere 8: assign a subscription key in vCenter > Licensing. vSphere 9: import the VCF license file in VCF Operations > License Management and assign it to the vCenter.' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Assignments | Where-Object { $_.IsEval } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Asset = $_.EntityName; License = $_.License }
    }
}

Register-VhCheck -Id 'LIC-002' -Category 'Licensing' -Severity 'Warning' `
    -Title 'License keys expired or expiring soon' `
    -Description 'Subscription keys carry an end date. An expired key blocks new host connections and vSAN/feature use.' `
    -Remediation 'Renew the subscription in the Broadcom Support Portal and replace the key before the expiration date.' `
    -AppliesTo '6', '7', '8' `
    -Script {
    param($Inventory, $Settings)
    $warn = [int]$Settings.Licensing.ExpiryWarningDays
    foreach ($l in ($Inventory.Licenses | Where-Object { -not $_.IsEval -and $_.Expiration })) {
        $exp = ConvertTo-VhDate $l.Expiration
        $days = [int][math]::Floor(($exp - (Get-Date)).TotalDays)
        if ($days -le $warn) {
            [pscustomobject]@{
                Severity = if ($days -lt 0) { 'Critical' } else { 'Warning' }
                vCenter = $l.vCenter; License = $l.Name; Key = "*****-$($l.KeySuffix)"
                Expires = $exp.ToString('yyyy-MM-dd'); DaysLeft = $days
            }
        }
    }
}

Register-VhCheck -Id 'LIC-003' -Category 'Licensing' -Severity 'Critical' `
    -Title 'License keys over capacity' `
    -Description 'A key is consuming more units (cores or CPUs) than it provides. vCenter raises a compliance alarm and the estate is out of contract.' `
    -Remediation 'Add capacity to the subscription or move hosts to a key with free capacity.' `
    -AppliesTo '6', '7', '8' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Licenses | Where-Object { -not $_.IsEval -and $_.Total -gt 0 -and $_.Used -gt $_.Total } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; License = $_.Name; Key = "*****-$($_.KeySuffix)"; Unit = $_.CostUnit; Used = $_.Used; Total = $_.Total; Over = $_.Used - $_.Total }
    }
}

Register-VhCheck -Id 'LIC-004' -Category 'Licensing' -Severity 'Critical' `
    -Title 'Core entitlement shortfall' `
    -Description 'Cores required by the per-core model (each CPU counted at max(16, physical cores)) exceed the cores purchased, as set in Settings.Licensing.PurchasedCores.' `
    -Remediation 'Buy additional cores, or reduce licensed hosts. Confirm counts against Broadcom KB 313548 ("Counting Cores for VCF and vSphere Foundation").' `
    -Script {
    param($Inventory, $Settings)
    $sum = Get-VhLicenseSummary -Inventory $Inventory -Settings $Settings
    if ($sum.PurchasedCores -gt 0 -and $sum.CoreShortfall -gt 0) {
        [pscustomobject]@{ Model = $sum.Model; Hosts = $sum.HostCount; RequiredCores = $sum.RequiredCores; PurchasedCores = $sum.PurchasedCores; Shortfall = $sum.CoreShortfall }
    }
}

Register-VhCheck -Id 'LIC-005' -Category 'Licensing' -Severity 'Critical' `
    -Title 'vSAN raw capacity exceeds TiB entitlement' `
    -Description 'vSAN is licensed per raw TiB. VCF includes 1 TiB per core and VVF 0.25 TiB per core (rounded up); anything above that needs a vSAN add-on.' `
    -Remediation 'Purchase vSAN add-on TiB capacity, or reclaim/retire vSAN capacity. Set Settings.Licensing.VsanAddOnTiB once purchased.' `
    -Script {
    param($Inventory, $Settings)
    $sum = Get-VhLicenseSummary -Inventory $Inventory -Settings $Settings
    if ($sum.VsanRawTiB -gt 0 -and $sum.Model -in 'VCF', 'VVF' -and $sum.VsanShortfallTiB -gt 0) {
        [pscustomobject]@{ Model = $sum.Model; RawTiB = $sum.VsanRawTiB; IncludedTiB = $sum.VsanIncludedTiB; AddOnTiB = $sum.VsanAddOnTiB; ShortfallTiB = $sum.VsanShortfallTiB }
    }
}

Register-VhCheck -Id 'LIC-006' -Category 'Licensing' -Severity 'Warning' `
    -Title 'VCF 9 license usage report due' `
    -Description 'vCenter 9 has no license keys. Licensing is a license file managed in VCF Operations, and in disconnected mode a usage file must be uploaded to Broadcom at least every 180 days or the license goes out of compliance.' `
    -Remediation 'In VCF Operations > License Management, download the usage file, upload it to the Broadcom Support Portal, import the returned license file, then update Settings.Licensing.UsageReportLastSubmitted.' `
    -AppliesTo '9' `
    -Script {
    param($Inventory, $Settings)
    $sum = Get-VhLicenseSummary -Inventory $Inventory -Settings $Settings
    $v9 = ($Inventory.vCenters | Where-Object { [int](([string]$_.Version).Split('.')[0]) -ge 9 }).Name -join ', '
    if ($null -eq $sum.UsageReportDaysLeft) {
        [pscustomobject]@{ Severity = 'Info'; vCenter = $v9; Status = 'Last submission date not set'; Detail = 'Set Licensing.UsageReportLastSubmitted to track the 180-day deadline. Connected-mode VCF Operations submits automatically.' }
    }
    elseif ($sum.UsageReportDaysLeft -le 30) {
        [pscustomobject]@{
            Severity = if ($sum.UsageReportDaysLeft -lt 0) { 'Critical' } else { 'Warning' }
            vCenter = $v9; Status = if ($sum.UsageReportDaysLeft -lt 0) { 'Overdue' } else { 'Due soon' }
            Detail = "Due $($sum.UsageReportDue.ToString('yyyy-MM-dd')) ($($sum.UsageReportDaysLeft) days)"
        }
    }
}

Register-VhCheck -Id 'LIC-007' -Category 'Licensing' -Severity 'Info' `
    -Title 'Hosts paying for unused cores (16-core minimum)' `
    -Description 'CPUs with fewer than 16 cores are still licensed at 16. Low-core-count CPUs can make the per-core model expensive.' `
    -Remediation 'When refreshing hardware, prefer CPUs with 16 or more cores per socket, or consolidate onto fewer, denser hosts.' `
    -Script {
    param($Inventory, $Settings)
    $sum = Get-VhLicenseSummary -Inventory $Inventory -Settings $Settings
    $sum.Hosts | Where-Object { $_.LicensedCores -gt $_.PhysicalCores } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Host; Cluster = $_.Cluster; Sockets = $_.Sockets; CoresPerSocket = $_.CoresPerSocket; PhysicalCores = $_.PhysicalCores; LicensedCores = $_.LicensedCores; UnusedCores = $_.LicensedCores - $_.PhysicalCores }
    }
}
