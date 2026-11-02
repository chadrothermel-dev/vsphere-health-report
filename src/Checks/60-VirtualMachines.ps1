function Get-VhReportVm {
    # Excludes templates and names matching Settings.Exclusions.VmNamePattern (vCLS by default)
    param($Inventory, $Settings)
    $Inventory.Vms | Where-Object { -not $_.IsTemplate -and -not (Test-VhExcluded $_.Name $Settings.Exclusions.VmNamePattern) }
}

Register-VhCheck -Id 'VM-001' -Category 'Virtual Machines' -Severity 'Warning' `
    -Title 'Old or large snapshots' `
    -Description 'Snapshots are not backups. Long-lived or large snapshots slow the VM, fill datastores and make consolidation stun time longer.' `
    -Remediation 'Confirm with the owner and delete the snapshot (Get-Snapshot | Remove-Snapshot). Check backup jobs that leave snapshots behind.' `
    -Script {
    param($Inventory, $Settings)
    $t = $Settings.Thresholds
    $skip = $Settings.Exclusions.SnapshotNamePattern
    foreach ($v in (Get-VhReportVm $Inventory $Settings)) {
        foreach ($s in @($v.Snapshots)) {
            if (-not $s -or (Test-VhExcluded $s.Name $skip)) { continue }
            $created = ConvertTo-VhDate $s.Created
            $age = [int][math]::Floor(((Get-Date) - $created).TotalDays)
            $size = if ($null -ne $s.SizeGB) { [double]$s.SizeGB } else { 0 }
            if ($age -ge $t.SnapshotAgeDays -or $size -ge $t.SnapshotSizeGB) {
                [pscustomobject]@{
                    Severity = if ($age -ge ($t.SnapshotAgeDays * 10) -or $size -ge ($t.SnapshotSizeGB * 4)) { 'Critical' } else { 'Warning' }
                    vCenter = $v.vCenter; VM = $v.Name; Snapshot = $s.Name; Created = $created.ToString('yyyy-MM-dd'); AgeDays = $age
                    SizeGB = if ($null -ne $s.SizeGB) { $s.SizeGB } else { 'n/a' }
                }
            }
        }
    }
}

Register-VhCheck -Id 'VM-002' -Category 'Virtual Machines' -Severity 'Critical' `
    -Title 'VMs needing disk consolidation' `
    -Description 'A snapshot removal left delta disks behind. They keep growing and can fill the datastore.' `
    -Remediation 'Run Snapshots > Consolidate during a quiet period (brief stun).' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportVm $Inventory $Settings | Where-Object { $_.ConsolidationNeeded } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; Host = $_.Host; Cluster = $_.Cluster }
    }
}

Register-VhCheck -Id 'VM-003' -Category 'Virtual Machines' -Severity 'Warning' `
    -Title 'VMware Tools not running' `
    -Description 'Without Tools, guest shutdown, quiesced backups, heartbeats (HA VM monitoring) and guest metrics do not work.' `
    -Remediation 'Install or start VMware Tools (open-vm-tools on Linux).' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportVm $Inventory $Settings | Where-Object { $_.PowerState -eq 'poweredOn' -and $_.ToolsRunningStatus -ne 'guestToolsRunning' } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; GuestOS = $_.ConfiguredOS; ToolsStatus = $_.ToolsVersionStatus; Running = $_.ToolsRunningStatus }
    }
}

Register-VhCheck -Id 'VM-004' -Category 'Virtual Machines' -Severity 'Info' `
    -Title 'VMware Tools out of date' `
    -Description 'Older Tools miss driver fixes (vmxnet3, pvscsi) and security patches.' `
    -Remediation 'Upgrade Tools with vLCM, Update-Tools, or the guest OS package manager for open-vm-tools.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportVm $Inventory $Settings | Where-Object { $_.PowerState -eq 'poweredOn' -and $_.ToolsVersionStatus -in 'guestToolsNeedUpgrade', 'guestToolsTooOld', 'guestToolsSupportedOld', 'guestToolsBlacklisted' } | ForEach-Object {
        [pscustomobject]@{
            Severity = if ($_.ToolsVersionStatus -in 'guestToolsTooOld', 'guestToolsBlacklisted') { 'Warning' } else { 'Info' }
            vCenter = $_.vCenter; VM = $_.Name; ToolsVersion = $_.ToolsVersion; Status = $_.ToolsVersionStatus
        }
    }
}

Register-VhCheck -Id 'VM-005' -Category 'Virtual Machines' -Severity 'Info' `
    -Title 'Old virtual hardware versions' `
    -Description 'VMs below the minimum hardware version in Settings.Thresholds.MinVmHardwareVersion miss newer features (vTPM, larger limits, newer device support). vmx-20 = 8.0, vmx-21 = 8.0 U2, vmx-22 = 9.0.' `
    -Remediation 'Upgrade the compatibility level during a maintenance window (VM must be powered off, take a backup first). Do not exceed what the oldest host in the cluster supports.' `
    -Script {
    param($Inventory, $Settings)
    $min = [int]$Settings.Thresholds.MinVmHardwareVersion
    Get-VhReportVm $Inventory $Settings | Where-Object { $_.HardwareVersion -match '^vmx-(\d+)$' -and [int]$Matches[1] -lt $min } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; Cluster = $_.Cluster; HardwareVersion = $_.HardwareVersion; PowerState = $_.PowerState }
    }
}

Register-VhCheck -Id 'VM-006' -Category 'Virtual Machines' -Severity 'Warning' `
    -Title 'Connected CD-ROM or floppy media' `
    -Description 'Connected removable media can block vMotion, DRS and maintenance mode evacuations.' `
    -Remediation 'Disconnect the media: Get-VM | Get-CDDrive | Set-CDDrive -NoMedia -Confirm:$false' `
    -Script {
    param($Inventory, $Settings)
    foreach ($v in (Get-VhReportVm $Inventory $Settings)) {
        foreach ($m in @($v.ConnectedMedia)) { if ($m) { [pscustomobject]@{ vCenter = $v.vCenter; VM = $v.Name; Host = $v.Host; Media = $m } } }
    }
}

Register-VhCheck -Id 'VM-007' -Category 'Virtual Machines' -Severity 'Warning' `
    -Title 'CPU or memory limits configured' `
    -Description 'Limits cap a VM even when the host is idle, causing ballooning, swapping or CPU ready time that is hard to diagnose.' `
    -Remediation 'Remove limits (set to Unlimited) unless they are a documented chargeback or licensing requirement.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportVm $Inventory $Settings | Where-Object { $_.CpuLimitMHz -ge 0 -or $_.MemLimitMB -ge 0 } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; CpuLimitMHz = if ($_.CpuLimitMHz -ge 0) { $_.CpuLimitMHz } else { 'Unlimited' }; MemLimitMB = if ($_.MemLimitMB -ge 0) { $_.MemLimitMB } else { 'Unlimited' }; MemoryGB = $_.MemoryGB }
    }
}

Register-VhCheck -Id 'VM-008' -Category 'Virtual Machines' -Severity 'Info' `
    -Title 'CPU or memory reservations configured' `
    -Description 'Reservations guarantee resources but reduce HA failover capacity and DRS flexibility.' `
    -Remediation 'Keep reservations only for workloads that need them (latency-sensitive, appliances that require them).' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportVm $Inventory $Settings | Where-Object { $_.CpuReservationMHz -gt 0 -or $_.MemReservationMB -gt 0 } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; CpuReservationMHz = $_.CpuReservationMHz; MemReservationMB = $_.MemReservationMB }
    }
}

Register-VhCheck -Id 'VM-009' -Category 'Virtual Machines' -Severity 'Critical' `
    -Title 'Orphaned, inaccessible or invalid VMs' `
    -Description 'vCenter has lost track of the VM files or the VM configuration is invalid.' `
    -Remediation 'Locate the .vmx in the datastore browser and re-register it, or remove the stale inventory entry.' `
    -Script {
    param($Inventory, $Settings)
    $Inventory.Vms | Where-Object { $_.ConnectionState -and $_.ConnectionState -ne 'connected' } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; State = $_.ConnectionState; Host = $_.Host }
    }
}

Register-VhCheck -Id 'VM-010' -Category 'Virtual Machines' -Severity 'Info' `
    -Title 'Emulated network adapters (E1000/E1000e)' `
    -Description 'Emulated NICs use more CPU and are slower than the paravirtual VMXNET3 adapter.' `
    -Remediation 'Replace with VMXNET3 during a maintenance window (the guest sees a new NIC; re-apply static IP settings).' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportVm $Inventory $Settings | Where-Object { @($_.NicTypes) -match '^E1000' } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; GuestOS = $_.ConfiguredOS; Adapters = (@($_.NicTypes) -join ', ') }
    }
}

Register-VhCheck -Id 'VM-011' -Category 'Virtual Machines' -Severity 'Info' `
    -Title 'Configured guest OS does not match running OS' `
    -Description 'A wrong guest OS setting gives the VM the wrong default devices, optimizations and support statement.' `
    -Remediation 'Power off the VM and set the correct Guest OS family/version in VM settings.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportVm $Inventory $Settings | Where-Object { $_.PowerState -eq 'poweredOn' -and $_.GuestOS -and $_.ConfiguredOS -and $_.GuestOS -ne $_.ConfiguredOS } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; Configured = $_.ConfiguredOS; Running = $_.GuestOS }
    }
}

Register-VhCheck -Id 'VM-012' -Category 'Virtual Machines' -Severity 'Info' `
    -Title 'VMs using BIOS firmware or without Secure Boot' `
    -Description 'EFI with Secure Boot is the default for modern guests and a prerequisite for vTPM, Windows 11 and VBS.' `
    -Remediation 'For new builds use EFI + Secure Boot. Converting existing VMs requires an in-guest MBR-to-GPT conversion first.' `
    -Script {
    param($Inventory, $Settings)
    Get-VhReportVm $Inventory $Settings | Where-Object { $_.Firmware -eq 'bios' -or ($_.Firmware -eq 'efi' -and -not $_.SecureBoot) } | ForEach-Object {
        [pscustomobject]@{ vCenter = $_.vCenter; VM = $_.Name; GuestOS = $_.ConfiguredOS; Firmware = $_.Firmware.ToUpper(); SecureBoot = $_.SecureBoot; vTPM = $_.HasVTpm }
    }
}
