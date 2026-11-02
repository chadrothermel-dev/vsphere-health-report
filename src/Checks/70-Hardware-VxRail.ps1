function Get-VhHwHost {
    # Hosts that have as-built hardware data (collected with -ReportType AsBuilt/Both)
    param($Inventory)
    $Inventory.Hosts | Where-Object { Get-VhProp $_ 'Hardware' }
}

function Format-VhVersionSpread {
    param([object[]]$Values)
    ($Values | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join '; '
}

Register-VhCheck -Id 'HW-001' -Category 'Hardware' -Severity 'Warning' `
    -Title 'Firmware or driver drift within a cluster' `
    -Description 'Hosts of the same model in one cluster should run identical BIOS, BMC/iDRAC, storage controller, boot device and NIC firmware/driver levels. Drift causes inconsistent behaviour and can block vSAN/vLCM/VxRail upgrades.' `
    -Remediation 'Bring hosts to the same validated baseline: VxRail via VxRail Manager LCM; other vendors via the vLCM image firmware add-on (Dell OMIVV, HPE iLO Amplifier/OneView, Lenovo XClarity) or vendor tooling.' `
    -Script {
    param($Inventory, $Settings)
    $rows = @()
    # vCenter-sourced: BIOS per model, NIC firmware/driver per driver (esxcli)
    foreach ($g in (Get-VhHwHost $Inventory | Where-Object Cluster | Group-Object vCenter, Cluster, { $_.Hardware.Model })) {
        $hosts = @($g.Group)
        if ($hosts.Count -lt 2) { continue }
        $bios = @($hosts | ForEach-Object { $_.Hardware.BiosVersion } | Where-Object { $_ } | Select-Object -Unique)
        if ($bios.Count -gt 1) {
            $rows += [pscustomobject]@{ Cluster = $hosts[0].Cluster; Model = $hosts[0].Hardware.Model; Component = 'BIOS'; Versions = Format-VhVersionSpread @($hosts | ForEach-Object { $_.Hardware.BiosVersion }); Source = 'vCenter' }
        }
        $pn = @($hosts | ForEach-Object { $hn = $_.Name; @($_.Hardware.Pnics) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Host = $hn; Driver = $_.Driver; Fw = $_.FirmwareVersion; Drv = $_.DriverVersion } } })
        foreach ($d in ($pn | Group-Object Driver)) {
            foreach ($pair in @(@('Fw', 'NIC firmware'), @('Drv', 'NIC driver'))) {
                $vals = @($d.Group | ForEach-Object { $_.($pair[0]) } | Where-Object { $_ })
                if (@($vals | Select-Object -Unique).Count -gt 1) {
                    $perHost = @($d.Group | Where-Object { $_.($pair[0]) } | Group-Object Host | ForEach-Object { $_.Group[0].($pair[0]) })
                    $rows += [pscustomobject]@{ Cluster = $hosts[0].Cluster; Model = $hosts[0].Hardware.Model; Component = "$($pair[1]) ($($d.Name))"; Versions = Format-VhVersionSpread $perHost; Source = 'esxcli' }
                }
            }
        }
    }
    # VxRail Manager-sourced firmware matrix
    foreach ($v in @($Inventory.VxRail)) {
        $fw = @($v.Firmware)
        if ($fw.Count -lt 2) { continue }
        $models = @{}; foreach ($n in @($v.Nodes)) { $models[$n.Hostname] = $n.Model }
        foreach ($mg in ($fw | Group-Object { $models[$_.Hostname] })) {
            if (@($mg.Group).Count -lt 2) { continue }
            foreach ($comp in 'Bios', 'Idrac', 'Boss', 'Perc', 'Hba', 'Cpld', 'BackplaneExpander', 'BackplaneNonExpander', 'Dcpm') {
                $vals = @($mg.Group | ForEach-Object { $_.$comp } | Where-Object { $_ })
                if (@($vals | Select-Object -Unique).Count -gt 1) {
                    $rows += [pscustomobject]@{ Cluster = $v.Cluster; Model = $mg.Name; Component = $comp.ToUpper() -replace 'IDRAC', 'iDRAC'; Versions = Format-VhVersionSpread $vals; Source = 'VxRail Manager' }
                }
            }
        }
    }
    # Same component reported by both sources: keep one row
    $rows | Sort-Object Cluster, Component, Source -Unique
}

Register-VhCheck -Id 'HW-002' -Category 'Hardware' -Severity 'Warning' `
    -Title 'Hardware sensors reporting a fault' `
    -Description 'Sensors (power supplies, fans, temperature, voltage, memory, processors, storage) that ESXi reports as yellow or red through CIM/IPMI.' `
    -Remediation 'Check the BMC (iDRAC, iLO, XCC, CIMC) event log and open a hardware case with the vendor if the fault is genuine.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($h in (Get-VhHwHost $Inventory)) {
        foreach ($s in @($h.Hardware.Sensors)) {
            if ($s -and $s.Health -in 'red', 'yellow') {
                [pscustomobject]@{ Severity = if ($s.Health -eq 'red') { 'Critical' } else { 'Warning' }; Host = $h.Name; Cluster = $h.Cluster; Sensor = $s.Name; Type = $s.Type; Reading = $s.Reading; Health = $s.Health }
            }
        }
    }
}

Register-VhCheck -Id 'HW-003' -Category 'Hardware' -Severity 'Critical' `
    -Title 'Switch uplinks with no link' `
    -Description 'A physical NIC assigned as an uplink to a standard or distributed switch has no link, reducing redundancy for management, vMotion, vSAN or VM traffic.' `
    -Remediation 'Check cabling, SFPs and the upstream switch port. Remove the NIC from the switch only if it is intentionally unused.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($h in (Get-VhHwHost $Inventory | Where-Object ConnectionState -eq 'connected')) {
        foreach ($p in @($h.Hardware.Pnics)) {
            if ($p -and $p.Switch -and -not $p.LinkUp) {
                [pscustomobject]@{ Host = $h.Name; Cluster = $h.Cluster; Nic = $p.Device; Switch = $p.Switch; Driver = $p.Driver; Mac = $p.Mac }
            }
        }
    }
}

Register-VhCheck -Id 'HW-004' -Category 'Hardware' -Severity 'Warning' `
    -Title 'Uplinks on the same switch at different speeds' `
    -Description 'Uplinks in one switch negotiating different speeds (for example 10 and 25 Gb) usually indicate a cabling, optic or port configuration problem, and give uneven failover performance.' `
    -Remediation 'Verify optics/cables and the upstream port speed configuration for the slower uplink.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($h in (Get-VhHwHost $Inventory)) {
        foreach ($g in (@($h.Hardware.Pnics) | Where-Object { $_ -and $_.Switch -and $_.LinkUp } | Group-Object Switch)) {
            $speeds = @($g.Group | ForEach-Object { $_.LinkSpeedMb } | Select-Object -Unique)
            if ($speeds.Count -gt 1) {
                [pscustomobject]@{ Host = $h.Name; Cluster = $h.Cluster; Switch = $g.Name; Uplinks = (($g.Group | ForEach-Object { "$($_.Device)=$([int]($_.LinkSpeedMb / 1000))G" }) -join ', ') }
            }
        }
    }
}

Register-VhCheck -Id 'HW-005' -Category 'Hardware' -Severity 'Warning' `
    -Title 'VMkernel MTU differs across a cluster' `
    -Description 'vSAN and vMotion VMkernel adapters should use the same MTU on every host in a cluster; a mismatch causes fragmentation or dropped jumbo frames (vSAN health "MTU check").' `
    -Remediation 'Set a consistent MTU on the VMkernel adapters and confirm the physical switches carry it end to end (vmkping -d -s 8972).' `
    -Script {
    param($Inventory, $Settings)
    $rows = foreach ($h in (Get-VhHwHost $Inventory | Where-Object Cluster)) {
        foreach ($v in @($h.Hardware.Vmks)) {
            foreach ($svc in @($v.Services)) { if ($svc -in 'vsan', 'vmotion', 'vSphereReplication') { [pscustomobject]@{ Cluster = $h.Cluster; Service = $svc; Host = $h.Name; Mtu = $v.Mtu } } }
        }
    }
    foreach ($g in (@($rows) | Where-Object { $_ } | Group-Object Cluster, Service)) {
        if (@($g.Group | ForEach-Object Mtu | Select-Object -Unique).Count -gt 1) {
            [pscustomobject]@{ Cluster = $g.Group[0].Cluster; Service = $g.Group[0].Service; MTUs = Format-VhVersionSpread @($g.Group | ForEach-Object { [string]$_.Mtu }) }
        }
    }
}

# ---------------------------------------------------------------- VxRail ----

function Test-VhHealthy {
    param([string]$Value)
    [string]::IsNullOrWhiteSpace($Value) -or $Value -match '^(healthy|ok|normal|good|online|up|green|ready)$'
}

function Get-VhHealthSeverity {
    param([string]$Value)
    if ($Value -match 'critical|error|fail|fault|red|offline|missing') { 'Critical' } else { 'Warning' }
}

Register-VhCheck -Id 'VXR-001' -Category 'VxRail' -Severity 'Warning' `
    -Title 'VxRail Manager not reachable or API errors' `
    -Description 'The VxRail Manager API could not be queried, so VxRail hardware checks for that cluster are incomplete.' `
    -Remediation 'Confirm the VxRail Manager address (cluster attribute VxRail-IP or Settings.VxRail.Managers), that the account has a VxRail role, and that HTTPS 443 is reachable from the reporting server.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($v in @($Inventory.VxRail)) {
        if (-not $v.Reachable -or @($v.Errors).Count) {
            [pscustomobject]@{ Severity = if ($v.Reachable) { 'Info' } else { 'Warning' }; Cluster = $v.Cluster; Manager = $v.Manager; Reachable = $v.Reachable; Errors = (@($v.Errors) -join ' | ') }
        }
    }
}

Register-VhCheck -Id 'VXR-002' -Category 'VxRail' -Severity 'Critical' `
    -Title 'VxRail system health not healthy' `
    -Description 'VxRail Manager reports the overall appliance health as Warning, Error or Critical.' `
    -Remediation 'Open VxRail Manager > Health > Physical/Logical to find the failing component; collect a VxRail log bundle for Dell support if needed.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($v in @($Inventory.VxRail | Where-Object Reachable)) {
        if (-not (Test-VhHealthy $v.Health)) {
            [pscustomobject]@{ Severity = Get-VhHealthSeverity $v.Health; Cluster = $v.Cluster; Manager = $v.Manager; Version = $v.Version; Health = $v.Health }
        }
    }
}

Register-VhCheck -Id 'VXR-003' -Category 'VxRail' -Severity 'Critical' `
    -Title 'VxRail nodes unhealthy, missing or powered off' `
    -Description 'Node-level health from VxRail Manager.' `
    -Remediation 'Check the node in VxRail Manager and its iDRAC; replace failed components through Dell support.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($n in @($Inventory.VxRail | ForEach-Object { $_.Nodes })) {
        if (-not $n) { continue }
        $off = $n.PowerStatus -and $n.PowerStatus -notmatch '^(on|poweredon)$'
        if ($n.Missing -or $off -or -not (Test-VhHealthy $n.Health)) {
            [pscustomobject]@{ Severity = if ($n.Missing -or $off) { 'Critical' } else { Get-VhHealthSeverity $n.Health }; Cluster = $n.Cluster; Node = $n.Hostname; ServiceTag = $n.SerialNumber; Health = $n.Health; Power = $n.PowerStatus; Missing = $n.Missing }
        }
    }
}

Register-VhCheck -Id 'VXR-004' -Category 'VxRail' -Severity 'Warning' `
    -Title 'VxRail disks failed, missing or wearing out' `
    -Description 'Capacity/cache disks that VxRail Manager reports in a non-OK state, missing, or with low remaining write endurance (threshold Settings.VxRail.DiskEnduranceWarnPct).' `
    -Remediation 'Replace the disk using the VxRail Manager disk replacement wizard; check vSAN resync status first.' `
    -Script {
    param($Inventory, $Settings)
    $minPct = 20
    if ($Settings.VxRail -and $Settings.VxRail.DiskEnduranceWarnPct) { $minPct = [int]$Settings.VxRail.DiskEnduranceWarnPct }
    foreach ($d in @($Inventory.VxRail | ForEach-Object { $_.Disks })) {
        if (-not $d) { continue }
        $endurance = $null
        if ($d.WriteEndurance -match '^\d+(\.\d+)?%?$') { $endurance = [double]($d.WriteEndurance -replace '%', '') }
        $worn = ($null -ne $endurance -and $endurance -lt $minPct) -or ($d.EnduranceStatus -and -not (Test-VhHealthy $d.EnduranceStatus))
        if ($d.Missing -or -not (Test-VhHealthy $d.State) -or $worn) {
            [pscustomobject]@{
                Severity = if ($d.Missing -or $d.State -match 'fail|error|critical|offline') { 'Critical' } else { 'Warning' }
                Cluster = $d.Cluster; Node = $d.Hostname; Slot = "$($d.Enclosure):$($d.Slot)"; Model = $d.Model; SerialNumber = $d.SerialNumber
                State = $d.State; Endurance = $d.WriteEndurance; Missing = $d.Missing
            }
        }
    }
}

Register-VhCheck -Id 'VXR-005' -Category 'VxRail' -Severity 'Critical' `
    -Title 'VxRail power supplies unhealthy or missing' `
    -Description 'A failed or missing PSU leaves the node without power redundancy.' `
    -Remediation 'Reseat or replace the PSU and check the PDU feed; confirm in iDRAC.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($p in @($Inventory.VxRail | ForEach-Object { $_.PowerSupplies })) {
        if ($p -and ($p.Missing -or -not (Test-VhHealthy $p.Health))) {
            [pscustomobject]@{ Cluster = $p.Cluster; Chassis = $p.Chassis; Slot = $p.Slot; PartNumber = $p.PartNumber; Health = $p.Health; Missing = $p.Missing }
        }
    }
}

Register-VhCheck -Id 'VXR-006' -Category 'VxRail' -Severity 'Critical' `
    -Title 'VxRail boot device (BOSS) unhealthy' `
    -Description 'The ESXi boot device (BOSS card / M.2) is reported as degraded. A failed boot device stops the node from booting after the next reboot.' `
    -Remediation 'Open a Dell case; replace the M.2 module using the VxRail boot device replacement procedure.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($b in @($Inventory.VxRail | ForEach-Object { $_.BootDevices })) {
        if ($b -and -not (Test-VhHealthy $b.Health)) {
            [pscustomobject]@{ Cluster = $b.Cluster; Node = $b.Hostname; Slot = $b.Slot; Model = $b.Model; SerialNumber = $b.SerialNumber; Health = $b.Health }
        }
    }
}

Register-VhCheck -Id 'VXR-007' -Category 'VxRail' -Severity 'Warning' `
    -Title 'VxRail NIC ports link down' `
    -Description 'NIC ports that VxRail Manager reports as link down.' `
    -Remediation 'Check cabling and the top-of-rack switch. Ports intentionally unused can be ignored.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($n in @($Inventory.VxRail | ForEach-Object { $_.Nics })) {
        if ($n -and $n.LinkStatus -match 'down|disconnect') {
            [pscustomobject]@{ Cluster = $n.Cluster; Node = $n.Hostname; Slot = $n.Slot; Mac = $n.Mac; LinkStatus = $n.LinkStatus }
        }
    }
}

Register-VhCheck -Id 'VXR-008' -Category 'VxRail' -Severity 'Info' `
    -Title 'VxRail call home / secure connect not connected' `
    -Description 'Without call home (Secure Connect Gateway), Dell is not notified of hardware failures and cannot dispatch parts proactively.' `
    -Remediation 'Configure Secure Connect Gateway in VxRail Manager > Configure > Support.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($v in @($Inventory.VxRail | Where-Object Reachable)) {
        if ($v.CallHomeStatus -notmatch 'connected|enabled|^ok$|registered') {
            [pscustomobject]@{ Cluster = $v.Cluster; Manager = $v.Manager; CallHomeStatus = if ($v.CallHomeStatus) { $v.CallHomeStatus } else { 'Not configured' } }
        }
    }
}

Register-VhCheck -Id 'VXR-009' -Category 'VxRail' -Severity 'Warning' `
    -Title 'VxRail components drifted from baseline' `
    -Description 'Installed components that differ from the VxRail release baseline or are flagged unsupported.' `
    -Remediation 'Remediate to the baseline with a VxRail LCM upgrade; do not update firmware or drivers outside VxRail Manager.' `
    -Script {
    param($Inventory, $Settings)
    foreach ($v in @($Inventory.VxRail)) {
        foreach ($c in @($v.Components)) {
            if ($c -and ($c.BaselineDrifted -or $c.Supported -eq $false)) {
                [pscustomobject]@{ Cluster = $v.Cluster; Component = $c.Name; Version = $c.Version; Baseline = $c.Baseline; Drifted = $c.BaselineDrifted; Supported = $c.Supported }
            }
        }
    }
}
