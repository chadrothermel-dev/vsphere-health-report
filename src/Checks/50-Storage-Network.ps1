function Get-VhReportDatastore {
    param($Inventory, $Settings)
    $Inventory.Datastores | Where-Object { -not (Test-VhExcluded $_.Name $Settings.Exclusions.DatastoreNamePattern) }
}

Register-VhCheck -Id 'DS-001' -Category 'Storage' -Severity 'Warning' `
    -Title 'Datastores low on free space' `
    -Description 'Full datastores stop VMs with thin disks or snapshots from writing (VMs pause with "no space left").' `
    -Remediation 'Delete old snapshots, Storage vMotion VMs, reclaim space (UNMAP), or grow the datastore.' `
    -Script {
    param($Inventory, $Settings)
    $t = $Settings.Thresholds
    foreach ($d in (Get-VhReportDatastore $Inventory $Settings)) {
        if ($d.CapacityGB -le 0) { continue }
        $pct = [math]::Round(100 * $d.FreeGB / $d.CapacityGB, 1)
        if ($pct -lt $t.DatastoreFreeWarnPct) {
            [pscustomobject]@{ Severity = if ($pct -lt $t.DatastoreFreeCritPct) { 'Critical' } else { 'Warning' }; vCenter = $d.vCenter; Datastore = $d.Name; Type = $d.Type; CapacityGB = $d.CapacityGB; FreeGB = $d.FreeGB; FreePct = $pct }
        }
    }
}

Register-VhCheck -Id 'DS-002' -Category 'Storage' -Severity 'Warning' `
    -Title 'Datastores over-provisioned' `
    -Description 'Provisioned (thin) capacity well above physical capacity risks running out of space if VMs grow.' `
    -Remediation 'Rebalance VMs, add capacity, or use Storage DRS with space thresholds.' `
    -Script {
    param($Inventory, $Settings)
    $max = [double]$Settings.Thresholds.DatastoreOverProvisionPct
    foreach ($d in (Get-VhReportDatastore $Inventory $Settings | Where-Object { $_.Type -ne 'vsan' })) {
        if ($d.CapacityGB -le 0) { continue }
        $pct = [math]::Round(100 * $d.ProvisionedGB / $d.CapacityGB, 0)
        if ($pct -gt $max) {
            [pscustomobject]@{ vCenter = $d.vCenter; Datastore = $d.Name; CapacityGB = $d.CapacityGB; ProvisionedGB = $d.ProvisionedGB; ProvisionedPct = $pct }
        }
    }
}

Register-VhCheck -Id 'DS-003' -Category 'Storage' -Severity 'Critical' `
    -Title 'Datastores inaccessible or in maintenance mode' `
    -Description 'VMs on an inaccessible datastore are down or unprotected.' `
    -Remediation 'Check array and path health; exit datastore maintenance mode when work is complete.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportDatastore $Inventory $Settings | Where-Object { -not $_.Accessible -or ($_.MaintenanceMode -and $_.MaintenanceMode -ne 'normal') } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Datastore = $_.Name; Accessible = $_.Accessible; MaintenanceMode = $_.MaintenanceMode; VMs = $_.VmCount }
    }
}

Register-VhCheck -Id 'NET-001' -Category 'Networking' -Severity 'Warning' `
    -Title 'Insecure switch security policies' `
    -Description 'Promiscuous mode, forged transmits and MAC address changes should be Reject unless an appliance requires them (hardening guide).' `
    -Remediation 'Set the three policies to Reject on the switch; allow overrides only on port groups that need them (for example nested ESXi or some load balancers).' `
    -Script {
    param($Inventory, $Settings)
    foreach ($h in $Inventory.Hosts) {
        foreach ($s in @($h.VSwitches)) {
            if ($s -and ($s.AllowPromiscuous -or $s.ForgedTransmits -or $s.MacChanges)) {
                [pscustomobject]@{ vCenter = $h.vCenter; Scope = "Host $($h.Name)"; Switch = $s.Name; PortGroup = '(switch default)'; Promiscuous = $s.AllowPromiscuous; ForgedTransmits = $s.ForgedTransmits; MacChanges = $s.MacChanges }
            }
        }
        foreach ($p in @($h.PortGroups)) {
            if ($p -and ($p.AllowPromiscuous -eq $true -or $p.ForgedTransmits -eq $true -or $p.MacChanges -eq $true)) {
                [pscustomobject]@{ vCenter = $h.vCenter; Scope = "Host $($h.Name)"; Switch = $p.vSwitch; PortGroup = $p.Name; Promiscuous = [bool]$p.AllowPromiscuous; ForgedTransmits = [bool]$p.ForgedTransmits; MacChanges = [bool]$p.MacChanges }
            }
        }
    }
    foreach ($p in $Inventory.DvPortGroups) {
        if ($p.AllowPromiscuous -or $p.ForgedTransmits -or $p.MacChanges) {
            [pscustomobject]@{ vCenter = $p.vCenter; Scope = 'Distributed'; Switch = $p.Switch; PortGroup = $p.Name; Promiscuous = $p.AllowPromiscuous; ForgedTransmits = $p.ForgedTransmits; MacChanges = $p.MacChanges }
        }
    }
}

Register-VhCheck -Id 'NET-002' -Category 'Networking' -Severity 'Warning' `
    -Title 'Distributed port groups running out of ports' `
    -Description 'Static-binding port groups without auto-expand refuse new VM connections when ports run out.' `
    -Remediation 'Enable auto-expand on the port group, or increase the number of ports.' `
    -Script {
    param($Inventory, $Settings)
    $min = [int]$Settings.Thresholds.PortGroupFreePortsMin
    $Inventory.DvPortGroups | Where-Object { -not $_.AutoExpand -and $_.BindingType -eq 'earlyBinding' -and ($_.NumPorts - $_.ConnectedVms) -lt $min } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Switch = $_.Switch; PortGroup = $_.Name; Ports = $_.NumPorts; ConnectedVMs = $_.ConnectedVms; Free = $_.NumPorts - $_.ConnectedVms }
    }
}
