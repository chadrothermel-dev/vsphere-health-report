Register-VhCheck -Id 'VC-001' -Category 'vCenter' -Severity 'Warning' `
    -Title 'Triggered alarms' `
    -Description 'Alarms currently in a red or yellow state across the inventory.' `
    -Remediation 'Investigate and resolve the underlying condition. Acknowledge only after the cause is understood.' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Alarms | Where-Object { $_.Status -in 'red', 'yellow' } | Sort-Object Status, Entity | ForEach-Object {
        $t = ConvertTo-VhDate $_.Time
        [pscustomobject]@{
            Severity = if ($_.Status -eq 'red') { 'Critical' } else { 'Warning' }
            vCenter = $_.vCenter; Entity = $_.Entity; Type = $_.Type; Alarm = $_.Alarm
            Triggered = if ($t) { $t.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }
            Acknowledged = $_.Acknowledged
        }
    }
}

Register-VhCheck -Id 'VC-002' -Category 'vCenter' -Severity 'Info' `
    -Title 'Idle vCenter sessions' `
    -Description 'Sessions idle longer than the threshold. Stale sessions from scripts and tools consume vCenter resources and may indicate credentials left logged in.' `
    -Remediation 'Make scripts call Disconnect-VIServer. Set a session timeout in vCenter advanced settings (vpxd.httpClientIdleTimeout) per your hardening baseline.' `
    -Script {
    param($Inventory, $Settings)
    $hours = [int]$Settings.Thresholds.SessionIdleHours
    foreach ($s in $Inventory.Sessions) {
        $last = ConvertTo-VhDate $s.LastActive
        if ($last -and ((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalHours -gt $hours) {
            [pscustomobject]@{ vCenter = $s.vCenter; User = $s.UserName; Client = $s.IpAddress; Agent = $s.UserAgent; IdleHours = [int]((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalHours }
        }
    }
}

Register-VhCheck -Id 'CL-001' -Category 'Clusters' -Severity 'Critical' `
    -Title 'vSphere HA disabled' `
    -Description 'Without HA, VMs on a failed host stay down until someone restarts them manually.' `
    -Remediation 'Enable vSphere HA with host monitoring and datastore heartbeating (2+ shared datastores).' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Clusters | Where-Object { -not $_.HAEnabled -and $_.NumHosts -gt 1 } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Cluster = $_.Name; Datacenter = $_.Datacenter; Hosts = $_.NumHosts }
    }
}

Register-VhCheck -Id 'CL-002' -Category 'Clusters' -Severity 'Warning' `
    -Title 'HA admission control disabled' `
    -Description 'With admission control off, the cluster can be filled past the point where it can restart VMs after a host failure.' `
    -Remediation 'Enable admission control using the cluster resource percentage policy (tolerate at least 1 host failure).' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Clusters | Where-Object { $_.HAEnabled -and -not $_.HAAdmissionControl } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Cluster = $_.Name; Hosts = $_.NumHosts }
    }
}

Register-VhCheck -Id 'CL-003' -Category 'Clusters' -Severity 'Warning' `
    -Title 'DRS disabled or not fully automated' `
    -Description 'Without fully automated DRS, load is not balanced and maintenance mode evacuations need manual vMotions.' `
    -Remediation 'Set DRS to Fully Automated with the default migration threshold (3).' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Clusters | Where-Object { $_.NumHosts -gt 1 -and (-not $_.DrsEnabled -or $_.DrsBehavior -ne 'fullyAutomated') } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Cluster = $_.Name; DrsEnabled = $_.DrsEnabled; Automation = if ($_.DrsEnabled) { $_.DrsBehavior } else { 'Disabled' } }
    }
}

Register-VhCheck -Id 'CL-004' -Category 'Clusters' -Severity 'Warning' `
    -Title 'vCPU to physical core ratio above threshold' `
    -Description 'High vCPU:pCore ratios lead to CPU ready time. The threshold is in Settings.Thresholds.VcpuToPcpuRatio.' `
    -Remediation 'Right-size oversized VMs (VCF Operations rightsizing), or add hosts to the cluster.' `
    -Script {
    param($Inventory, $Settings)
    $max = [double]$Settings.Thresholds.VcpuToPcpuRatio
    foreach ($c in $Inventory.Clusters) {
        $cores = (Get-VhSum @($Inventory.Hosts | Where-Object { $_.vCenter -eq $c.vCenter -and $_.Cluster -eq $c.Name }) 'CpuCores')
        $vcpu = (Get-VhSum @($Inventory.Vms | Where-Object { $_.vCenter -eq $c.vCenter -and $_.Cluster -eq $c.Name -and $_.PowerState -eq 'poweredOn' }) 'NumCpu')
        if ($cores -gt 0 -and ($vcpu / $cores) -gt $max) {
            [pscustomobject]@{ vCenter = $c.vCenter; Cluster = $c.Name; PoweredOnVcpu = [int]$vcpu; PhysicalCores = [int]$cores; Ratio = '{0:N1}:1' -f ($vcpu / $cores) }
        }
    }
}

Register-VhCheck -Id 'CL-005' -Category 'Clusters' -Severity 'Critical' `
    -Title 'Cluster cannot absorb a host failure (memory N+1)' `
    -Description 'Active memory across the cluster is more than the remaining hosts could hold if the largest host failed.' `
    -Remediation 'Add a host, reduce memory allocation, or move workloads to another cluster.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($c in $Inventory.Clusters) {
        $h = @($Inventory.Hosts | Where-Object { $_.vCenter -eq $c.vCenter -and $_.Cluster -eq $c.Name -and $_.ConnectionState -eq 'connected' -and -not $_.MaintenanceMode })
        if ($h.Count -lt 2) { continue }
        $total = (Get-VhSum @($h) 'MemoryGB')
        $used = (Get-VhSum @($h | ForEach-Object { $_.MemoryGB * $_.MemUsagePct / 100 }))
        $largest = ($h | Measure-Object MemoryGB -Maximum).Maximum
        $afterFailure = $total - $largest
        if ($used -gt $afterFailure) {
            [pscustomobject]@{ vCenter = $c.vCenter; Cluster = $c.Name; Hosts = $h.Count; TotalMemGB = [int]$total; UsedMemGB = [int]$used; CapacityAfterFailureGB = [int]$afterFailure }
        }
    }
}
