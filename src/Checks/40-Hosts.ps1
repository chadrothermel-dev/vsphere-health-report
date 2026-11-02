function Get-VhReportHost {
    param($Inventory, $Settings)
    $Inventory.Hosts | Where-Object { -not (Test-VhExcluded $_.Name $Settings.Exclusions.HostNamePattern) }
}

Register-VhCheck -Id 'HST-001' -Category 'Hosts' -Severity 'Critical' `
    -Title 'Hosts disconnected or not responding' `
    -Description 'vCenter cannot manage these hosts; HA protection and monitoring for their VMs may be degraded.' `
    -Remediation 'Check management network reachability and the hostd/vpxa agents. Reconnect the host in vCenter.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.ConnectionState -ne 'connected' } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; State = $_.ConnectionState; Power = $_.PowerState }
    }
}

Register-VhCheck -Id 'HST-002' -Category 'Hosts' -Severity 'Info' `
    -Title 'Hosts in maintenance mode' `
    -Description 'Hosts in maintenance mode reduce cluster capacity and failover headroom.' `
    -Remediation 'Exit maintenance mode once work is complete.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.MaintenanceMode } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; Version = $_.Version }
    }
}

Register-VhCheck -Id 'HST-003' -Category 'Hosts' -Severity 'Warning' `
    -Title 'Hosts pending a reboot' `
    -Description 'A patch or configuration change has been applied that only takes effect after a reboot.' `
    -Remediation 'Schedule maintenance mode and reboot, or remediate the cluster with vLCM.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.RebootRequired } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; UptimeDays = $_.UptimeDays }
    }
}

Register-VhCheck -Id 'HST-004' -Category 'Hosts' -Severity 'Warning' `
    -Title 'Host configuration issues' `
    -Description 'Configuration issues reported by vCenter (for example lost network redundancy, SSH enabled warnings, HA agent errors).' `
    -Remediation 'Resolve each issue at its source; suppress warnings only where it is a deliberate design decision.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($h in (Get-VhReportHost $Inventory $Settings)) {
        foreach ($i in @($h.ConfigIssues)) { if ($i) { [pscustomobject]@{ vCenter = $h.vCenter; Host = $h.Name; Cluster = $h.Cluster; Issue = $i } } }
    }
}

Register-VhCheck -Id 'HST-005' -Category 'Hosts' -Severity 'Warning' `
    -Title 'SSH or ESXi Shell running' `
    -Description 'The hardening guide requires SSH and the ESXi Shell to be stopped except during active troubleshooting.' `
    -Remediation 'Stop the services and set their policy to "Start and stop manually": Get-VMHost | Get-VMHostService | ? Key -in "TSM-SSH","TSM" | Stop-VMHostService' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.SshRunning -or $_.ShellRunning } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; SSH = $_.SshRunning; ESXiShell = $_.ShellRunning }
    }
}

Register-VhCheck -Id 'HST-006' -Category 'Hosts' -Severity 'Info' `
    -Title 'Lockdown mode disabled' `
    -Description 'Lockdown mode forces management through vCenter. It is a hardening guide and DISA STIG requirement in most environments.' `
    -Remediation 'Enable Normal lockdown mode and add break-glass accounts to the Exception Users list.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.ConnectionState -eq 'connected' -and $_.LockdownMode -in 'lockdownDisabled', '' } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; LockdownMode = 'Disabled' }
    }
}

Register-VhCheck -Id 'HST-007' -Category 'Hosts' -Severity 'Warning' `
    -Title 'NTP not configured or not running' `
    -Description 'Time drift breaks vSAN, Kerberos/AD authentication, certificate validation and log correlation.' `
    -Remediation 'Configure at least two NTP sources and start the NTP service with policy "Start and stop with host".' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.ConnectionState -eq 'connected' -and (@($_.NtpServers).Count -eq 0 -or -not $_.NtpRunning) } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; NtpServers = (@($_.NtpServers) -join ', '); ServiceRunning = $_.NtpRunning }
    }
}

Register-VhCheck -Id 'HST-008' -Category 'Hosts' -Severity 'Warning' `
    -Title 'Remote syslog not configured' `
    -Description 'Without remote syslog, host logs are lost on reboot or failure and cannot reach your SIEM.' `
    -Remediation 'Set Syslog.global.logHost (for example udp://syslog.corp.local:514 or tcp/ssl) on every host.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.ConnectionState -eq 'connected' -and [string]::IsNullOrWhiteSpace($_.SyslogHost) } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster }
    }
}

Register-VhCheck -Id 'HST-009' -Category 'Hosts' -Severity 'Warning' `
    -Title 'Host certificates expiring' `
    -Description 'An expired ESXi certificate breaks the vCenter-to-host connection.' `
    -Remediation 'Renew via Host > Configure > Certificate > Renew (VMCA), or replace with a CA-signed certificate.' `
    -Script {
    param($Inventory, $Settings)
    $warn = [int]$Settings.Thresholds.CertExpiryWarnDays
    $crit = [int]$Settings.Thresholds.CertExpiryCritDays
    foreach ($h in (Get-VhReportHost $Inventory $Settings)) {
        $exp = ConvertTo-VhDate $h.CertExpires
        if (-not $exp) { continue }
        $days = [int][math]::Floor(($exp - (Get-Date)).TotalDays)
        if ($days -le $warn) {
            [pscustomobject]@{ Severity = if ($days -le $crit) { 'Critical' } else { 'Warning' }; vCenter = $h.vCenter; Host = $h.Name; Expires = $exp.ToString('yyyy-MM-dd'); DaysLeft = $days }
        }
    }
}

Register-VhCheck -Id 'HST-010' -Category 'Hosts' -Severity 'Critical' `
    -Title 'Dead storage paths' `
    -Description 'Dead paths reduce multipathing redundancy; another failure could cause an all-paths-down event.' `
    -Remediation 'Check HBA/NIC links, fabric zoning and array ports. Rescan storage after the fix.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.DeadPaths -gt 0 } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; DeadPaths = $_.DeadPaths }
    }
}

Register-VhCheck -Id 'HST-011' -Category 'Hosts' -Severity 'Warning' `
    -Title 'High host CPU or memory usage' `
    -Description 'Point-in-time utilization above the thresholds in Settings.Thresholds.' `
    -Remediation 'Check DRS balance and VM right-sizing; add capacity if the trend persists.' `
    -Script {
    param($Inventory, $Settings)
    $t = $Settings.Thresholds
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.CpuUsagePct -ge $t.HostCpuWarnPct -or $_.MemUsagePct -ge $t.HostMemWarnPct } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; CpuPct = $_.CpuUsagePct; MemPct = $_.MemUsagePct }
    }
}

Register-VhCheck -Id 'HST-012' -Category 'Hosts' -Severity 'Info' `
    -Title 'Hosts without TPM 2.0 or UEFI Secure Boot' `
    -Description 'TPM 2.0 and Secure Boot provide host attestation and protect vSphere Native Key Provider keys and encrypted configuration.' `
    -Remediation 'Enable TPM 2.0 (FIPS mode where required) and UEFI Secure Boot in the server BIOS during the next maintenance window.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.ConnectionState -eq 'connected' -and (-not $_.TpmSupported -or -not $_.UefiSecureBoot) } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; Host = $_.Name; Model = "$($_.Vendor) $($_.Model)"; TPM = if ($_.TpmSupported) { $_.TpmVersion } else { 'None' }; SecureBoot = $_.UefiSecureBoot }
    }
}

Register-VhCheck -Id 'HST-013' -Category 'Hosts' -Severity 'Warning' `
    -Title 'Host overall status not green' `
    -Description 'vCenter rolls hardware sensors, alarms and agent health into an overall status.' `
    -Remediation 'Review Host > Monitor > Hardware Health and the vendor management controller (iDRAC, iLO, XCC, CIMC).' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportHost $Inventory $Settings | Where-Object { $_.ConnectionState -eq 'connected' -and $_.OverallStatus -in 'red', 'yellow' } | ForEach-Object {
        [pscustomobject]@{ Severity = if ($_.OverallStatus -eq 'red') { 'Critical' } else { 'Warning' }; vCenter = $_.vCenter; Host = $_.Name; Cluster = $_.Cluster; Status = $_.OverallStatus }
    }
}
