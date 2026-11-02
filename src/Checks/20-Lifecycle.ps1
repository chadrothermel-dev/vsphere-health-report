Register-VhCheck -Id 'LCM-001' -Category 'Lifecycle' -Severity 'Critical' `
    -Title 'Products past or nearing end of general support' `
    -Description 'vSphere 7.0 reached end of general support on 2025-10-02. Unsupported versions get no security patches. Dates come from Settings.Lifecycle.' `
    -Remediation 'Plan the upgrade path in the Broadcom Product Interoperability Matrix (vCenter first, then ESXi via vLCM).' `
    -Script {
    param($Inventory, $Settings)
    $lc = $Settings.Lifecycle
    $warnDays = [int]$lc.WarnDaysBefore
    $items = @($Inventory.vCenters | ForEach-Object { [pscustomobject]@{ Product = 'vCenter Server'; Name = $_.Name; Version = $_.Version } }) +
             @($Inventory.Hosts | ForEach-Object { [pscustomobject]@{ Product = 'ESXi'; Name = $_.Name; Version = $_.Version } })
    foreach ($i in $items) {
        $mm = Get-VhMajorMinor $i.Version
        if (-not $lc.ContainsKey($mm) -or -not $lc[$mm]) { continue }
        $eogs = [datetime]::ParseExact($lc[$mm], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $days = [int][math]::Floor(($eogs - (Get-Date)).TotalDays)
        if ($days -le $warnDays) {
            [pscustomobject]@{
                Severity = if ($days -lt 0) { 'Critical' } else { 'Warning' }
                Product = $i.Product; Name = $i.Name; Version = $i.Version
                EndOfGeneralSupport = $eogs.ToString('yyyy-MM-dd')
                Status = if ($days -lt 0) { "Unsupported for $(-$days) days" } else { "$days days left" }
            }
        }
    }
}

Register-VhCheck -Id 'LCM-002' -Category 'Lifecycle' -Severity 'Warning' `
    -Title 'Mixed ESXi builds within a cluster' `
    -Description 'Hosts in the same cluster should run the same build. Mixed builds limit vMotion/EVC, VM hardware versions and vLCM remediation.' `
    -Remediation 'Remediate the cluster against its vLCM image so every host matches. VxRail clusters: run the upgrade from VxRail Manager, never from vCenter Lifecycle Manager directly.' `
    -Script {
    param($Inventory, $Settings)
    $vxr = @{}; foreach ($c in $Inventory.Clusters) { $vxr["$($c.vCenter)|$($c.Name)"] = [bool](Get-VhProp $c 'IsVxRail' $false) }
    $Inventory.Hosts | Where-Object { $_.Cluster -and $_.Build } | Group-Object vCenter, Cluster | ForEach-Object {
        $builds = @($_.Group | Group-Object Build)
        if ($builds.Count -gt 1) {
            [pscustomobject]@{
                vCenter = $_.Group[0].vCenter; Cluster = $_.Group[0].Cluster; Hosts = $_.Count
                Builds = ($builds | ForEach-Object { "$($_.Group[0].Version) build $($_.Name) ($($_.Count))" }) -join '; '
                ManagedBy = if ($vxr["$($_.Group[0].vCenter)|$($_.Group[0].Cluster)"]) { 'VxRail Manager' } else { 'vLCM' }
            }
        }
    }
}

Register-VhCheck -Id 'LCM-003' -Category 'Lifecycle' -Severity 'Warning' `
    -Title 'Clusters managed with vLCM baselines instead of images' `
    -Description 'Baseline (VUM-style) lifecycle management is deprecated in vSphere 8 and removed in vSphere 9. Baseline-managed clusters must be converted to an image before upgrading to ESXi 9.' `
    -Remediation 'Cluster > Updates > Image > Manage with a single image. Check the image compliance report before switching; the change cannot be undone. VxRail clusters: lifecycle is owned by VxRail Manager; switch to vLCM mode from VxRail Manager (not the vCenter Updates tab) and follow the VxRail upgrade path for vSphere 9.' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Clusters | Where-Object { -not $_.ImageManaged -and $_.NumHosts -gt 0 } | ForEach-Object {
        $isVxr = [bool](Get-VhProp $_ 'IsVxRail' $false)
        [pscustomobject]@{
            Severity = if ($isVxr) { 'Info' } else { 'Warning' }
            vCenter = $_.vCenter; Cluster = $_.Name; Datacenter = $_.Datacenter; Hosts = $_.NumHosts
            Lifecycle = if ($isVxr) { 'VxRail Manager (legacy mode)' } else { 'Baselines' }
        }
    }
}

Register-VhCheck -Id 'LCM-004' -Category 'Lifecycle' -Severity 'Info' `
    -Title 'Host Profiles in use' `
    -Description 'Host Profiles are the legacy configuration tool. On image-managed clusters, vSphere Configuration Profiles replace them; plan the move before vSphere 9 adoption.' `
    -Remediation 'Convert the cluster to vSphere Configuration Profiles (Cluster > Configure > Desired State > Configuration) after moving it to a vLCM image.' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Clusters | Where-Object { $_.HostProfile } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Cluster = $_.Name; HostProfile = $_.HostProfile; ImageManaged = $_.ImageManaged }
    }
}

Register-VhCheck -Id 'LCM-005' -Category 'Lifecycle' -Severity 'Warning' `
    -Title 'vVols datastores in use' `
    -Description 'vSphere Virtual Volumes are deprecated as of VCF/VVF 9.0 and planned for removal in a future release.' `
    -Remediation 'Plan migration of vVols workloads to VMFS, NFS or vSAN with Storage vMotion. Do not build new vVols datastores.' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Datastores | Where-Object { $_.Type -eq 'VVOL' } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Datastore = $_.Name; CapacityGB = $_.CapacityGB; VMs = $_.VmCount }
    }
}

Register-VhCheck -Id 'LCM-006' -Category 'Lifecycle' -Severity 'Info' `
    -Title 'vSAN clusters on Original Storage Architecture (OSA)' `
    -Description 'vSAN Express Storage Architecture (ESA) is the strategic architecture on NVMe hardware, with better efficiency and performance. OSA clusters cannot be converted in place.' `
    -Remediation 'At the next hardware refresh, deploy ESA-certified ReadyNodes and migrate workloads to a new ESA cluster.' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Clusters | Where-Object { $_.VsanEnabled -and -not $_.VsanEsa } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Cluster = $_.Name; Hosts = $_.NumHosts; Architecture = 'OSA' }
    }
}

Register-VhCheck -Id 'LCM-007' -Category 'Lifecycle' -Severity 'Info' `
    -Title 'Enhanced Linked Mode detected' `
    -Description 'ELM is deprecated in vCenter 9.0 and kept only for upgrades of existing estates. VCF 9 uses VCF Operations to group vCenters instead.' `
    -Remediation 'Do not create new ELM groups. Plan to manage multiple vCenters through VCF Operations.' `
    -Script {
    param($Inventory, $Settings)
    $vcs = @($Inventory.vCenters)
    if ($vcs.Count -gt 1 -and $Settings.Connection.AllLinked) {
        [pscustomobject]@{ LinkedvCenters = $vcs.Count; Members = ($vcs.Name -join ', ') }
    }
}
