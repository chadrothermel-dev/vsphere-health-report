<#
    Inventory collector.
    Uses property-filtered Get-View calls (one per object type) instead of
    Get-VM/Get-VMHost per object, which keeps large estates fast. Everything is
    flattened to plain PSCustomObjects so checks and tests never need PowerCLI.
#>

function Get-VhSafe {
    # Evaluate a scriptblock, returning $Default on any error (missing API, privilege, etc.)
    param([scriptblock]$Script, $Default = $null)
    try { & $Script } catch { Write-Verbose "Collector: $($_.Exception.Message)"; $Default }
}

function Get-VhInventory {
    <#
        .SYNOPSIS
            Collects a flattened inventory from one connected vCenter Server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Server,
        # Collect the full as-built hardware inventory per host (slower)
        [switch]$IncludeHardware,
        # Also use esxcli for NIC driver/firmware versions and the BMC IP (slowest)
        [switch]$UseEsxcli
    )

    $vc = $Server.Name
    Write-Verbose "[$vc] Collecting service content"
    $si = Get-View ServiceInstance -Server $Server
    $about = $si.Content.About

    # ---- Clusters ---------------------------------------------------------
    Write-Verbose "[$vc] Clusters"
    $clusterViews = @(Get-View -Server $Server -ViewType ClusterComputeResource -Property Name, Parent, ConfigurationEx, Summary, Host, LifecycleManaged, CustomValue)

    # Custom attribute names; VxRail stamps its clusters with 'VxRail-IP' (the VxRail Manager address)
    $fieldNames = @{}
    Get-VhSafe { foreach ($f in (Get-View -Server $Server $si.Content.CustomFieldsManager).Field) { $fieldNames[[string]$f.Key] = $f.Name } }
    $clusterByMoRef = @{}
    foreach ($c in $clusterViews) { $clusterByMoRef[$c.MoRef.ToString()] = $c.Name }

    # Datacenter lookup by walking parents once
    $folderParents = @{}
    foreach ($f in (Get-View -Server $Server -ViewType Folder -Property Name, Parent)) { $folderParents[$f.MoRef.ToString()] = $f.Parent }
    $dcNames = @{}
    foreach ($d in (Get-View -Server $Server -ViewType Datacenter -Property Name)) { $dcNames[$d.MoRef.ToString()] = $d.Name }
    $resolveDc = {
        param($parent)
        $p = $parent
        for ($i = 0; $i -lt 20 -and $p; $i++) {
            $k = $p.ToString()
            if ($dcNames.ContainsKey($k)) { return $dcNames[$k] }
            $p = $folderParents[$k]
        }
        ''
    }

    $hostProfiles = @{}
    Get-VhSafe {
        foreach ($hp in (Get-VMHostProfile -Server $Server -ErrorAction Stop)) {
            foreach ($e in @($hp.ExtensionData.Entity)) { if ($e) { $hostProfiles[$e.ToString()] = $hp.Name } }
        }
    }

    $clusters = foreach ($c in $clusterViews) {
        $cfg = $c.ConfigurationEx
        $vsanEnabled = [bool](Get-VhSafe { $cfg.VsanConfigInfo.Enabled } $false)
        $vxrIp = [string](@($c.CustomValue) | Where-Object { $_ -and $fieldNames[[string]$_.Key] -eq 'VxRail-IP' } | Select-Object -First 1).Value
        [pscustomobject]@{
            vCenter                 = $vc
            Name                    = $c.Name
            Datacenter              = & $resolveDc $c.Parent
            NumHosts                = [int]$c.Summary.NumHosts
            NumEffectiveHosts       = [int]$c.Summary.NumEffectiveHosts
            TotalCpuCores           = [int]$c.Summary.NumCpuCores
            TotalMemoryGB           = [math]::Round($c.Summary.TotalMemory / 1GB, 1)
            HAEnabled               = [bool]$cfg.DasConfig.Enabled
            HAAdmissionControl      = [bool]$cfg.DasConfig.AdmissionControlEnabled
            HAHostMonitoring        = [string]$cfg.DasConfig.HostMonitoring
            DrsEnabled              = [bool]$cfg.DrsConfig.Enabled
            DrsBehavior             = [string]$cfg.DrsConfig.DefaultVmBehavior
            EvcMode                 = [string]$c.Summary.CurrentEVCModeKey
            VsanEnabled             = $vsanEnabled
            VsanEsa                 = [bool](Get-VhSafe { $cfg.VsanConfigInfo.VsanEsaEnabled } $false)
            ImageManaged            = [bool](Get-VhSafe { $c.LifecycleManaged } $false)
            HostProfile             = [string]$hostProfiles[$c.MoRef.ToString()]
            IsVxRail                = [bool]$vxrIp
            VxRailManager           = $vxrIp
            HAAdmissionPolicy       = [string](Get-VhSafe { $cfg.DasConfig.AdmissionControlPolicy.GetType().Name -replace '^ClusterFailover', '' -replace 'AdmissionControlPolicy$', '' } '')
            HAIsolationResponse     = [string](Get-VhSafe { $cfg.DasConfig.DefaultVmSettings.IsolationResponse } '')
            HAVmMonitoring          = [string](Get-VhSafe { $cfg.DasConfig.VmMonitoring } '')
            DrsMigrationThreshold   = [int](Get-VhSafe { $cfg.DrsConfig.VmotionRate } 0)
        }
    }

    # ---- Distributed switches / port groups -------------------------------
    Write-Verbose "[$vc] Distributed switches"
    $dvsNames = @{}; $dvsByUuid = @{}; $dvpgNames = @{}
    $dvSwitches = foreach ($s in (Get-VhSafe { Get-View -Server $Server -ViewType DistributedVirtualSwitch -Property Name, Uuid, Config, Summary } @())) {
        $dvsNames[$s.MoRef.ToString()] = $s.Name
        $dvsByUuid[[string]$s.Uuid] = $s.Name
        [pscustomobject]@{
            vCenter   = $vc
            Name      = $s.Name
            Version   = [string](Get-VhSafe { $s.Config.ProductInfo.Version } '')
            Mtu       = [int](Get-VhSafe { $s.Config.MaxMtu } 0)
            Uplinks   = @(Get-VhSafe { $s.Config.UplinkPortPolicy.UplinkPortName } @()).Count
            Hosts     = @(Get-VhSafe { $s.Summary.HostMember } @()).Count
            Nioc      = [bool](Get-VhSafe { $s.Config.NetworkResourceManagementEnabled } $false)
            Discovery = [string](Get-VhSafe { "$($s.Config.LinkDiscoveryProtocolConfig.Protocol)/$($s.Config.LinkDiscoveryProtocolConfig.Operation)" } '')
        }
    }
    $dvPortGroups = foreach ($pg in (Get-VhSafe { Get-View -Server $Server -ViewType DistributedVirtualPortgroup -Property Name, Key, Config, Vm } @())) {
        $dvpgNames[[string]$pg.Key] = $pg.Name
        if ($pg.Config.Uplink) { continue }
        $sec = Get-VhSafe { $pg.Config.DefaultPortConfig.SecurityPolicy }
        $vlan = Get-VhSafe { $pg.Config.DefaultPortConfig.Vlan }
        $vlanText = ''
        if ($vlan -and $vlan.PSObject.Properties['VlanId']) {
            $id = $vlan.VlanId
            $vlanText = if ($id -is [array]) { ($id | ForEach-Object { "$($_.Start)-$($_.End)" }) -join ',' } else { [string]$id }
        }
        elseif ($vlan -and $vlan.PSObject.Properties['PvlanId']) { $vlanText = "PVLAN $($vlan.PvlanId)" }
        [pscustomobject]@{
            vCenter          = $vc
            Name             = $pg.Name
            Switch           = [string]$dvsNames[$pg.Config.DistributedVirtualSwitch.ToString()]
            VlanId           = $vlanText
            BindingType      = [string]$pg.Config.Type
            NumPorts         = [int]$pg.Config.NumPorts
            AutoExpand       = [bool]$pg.Config.AutoExpand
            ConnectedVms     = @($pg.Vm).Count
            AllowPromiscuous = [bool](Get-VhSafe { $sec.AllowPromiscuous.Value } $false)
            ForgedTransmits  = [bool](Get-VhSafe { $sec.ForgedTransmits.Value } $false)
            MacChanges       = [bool](Get-VhSafe { $sec.MacChanges.Value } $false)
        }
    }

    # ---- Hosts ------------------------------------------------------------
    Write-Verbose "[$vc] Hosts"
    $hostProps = @('Name', 'Parent', 'Runtime', 'Summary', 'OverallStatus', 'ConfigIssue',
        'Hardware.CpuInfo', 'Config.Product', 'Config.LockdownMode', 'Config.PowerSystemInfo', 'Config.StorageDevice.MultipathInfo',
        'Config.Network.Vswitch', 'Config.Network.Portgroup', 'Capability', 'ConfigManager')
    if ($IncludeHardware) { $hostProps += $script:VhHardwareHostProperties }
    $hostViews = @(Get-View -Server $Server -ViewType HostSystem -Property $hostProps)
    $hostByMoRef = @{}
    $hostCluster = @{}
    $hosts = foreach ($h in $hostViews) {
        $clusterName = [string]$clusterByMoRef[$h.Parent.ToString()]
        $hostByMoRef[$h.MoRef.ToString()] = $h.Name
        $hostCluster[$h.MoRef.ToString()] = $clusterName
        $connected = $h.Runtime.ConnectionState -eq 'connected'

        $services = @()
        $ntp = @(); $ntpRunning = $false; $syslog = ''; $certExpires = $null
        if ($connected) {
            $services = Get-VhSafe { (Get-View -Server $Server $h.ConfigManager.ServiceSystem -Property ServiceInfo).ServiceInfo.Service } @()
            $ntp = Get-VhSafe { @((Get-View -Server $Server $h.ConfigManager.DateTimeSystem -Property DateTimeInfo).DateTimeInfo.NtpConfig.Server) } @()
            $ntpRunning = [bool]($services | Where-Object { $_.Key -in 'ntpd', 'chronyd' -and $_.Running })
            $syslog = Get-VhSafe { [string]((Get-View -Server $Server $h.ConfigManager.AdvancedOption).QueryOptions('Syslog.global.logHost') | Select-Object -First 1).Value } ''
            $certExpires = Get-VhSafe { (Get-View -Server $Server $h.ConfigManager.CertificateManager -Property CertificateInfo).CertificateInfo.NotAfter }
        }
        $deadPaths = [int](Get-VhSafe {
                @($h.Config.StorageDevice.MultipathInfo.Lun | ForEach-Object { $_.Path } | Where-Object { $_.State -eq 'dead' }).Count
            } 0)
        $cpu = $h.Hardware.CpuInfo
        $hw = $h.Summary.Hardware
        $qs = $h.Summary.QuickStats

        [pscustomobject]@{
            vCenter            = $vc
            Name               = $h.Name
            Cluster            = $clusterName
            Version            = [string]$h.Config.Product.Version
            Build              = [string]$h.Config.Product.Build
            ConnectionState    = [string]$h.Runtime.ConnectionState
            PowerState         = [string]$h.Runtime.PowerState
            MaintenanceMode    = [bool]$h.Runtime.InMaintenanceMode
            OverallStatus      = [string]$h.OverallStatus
            Vendor             = [string]$hw.Vendor
            Model              = [string]$hw.Model
            CpuModel           = [string]$hw.CpuModel
            CpuSockets         = [int]$cpu.NumCpuPackages
            CpuCores           = [int]$cpu.NumCpuCores
            CpuCoresPerSocket  = if ($cpu.NumCpuPackages) { [int]($cpu.NumCpuCores / $cpu.NumCpuPackages) } else { 0 }
            MemoryGB           = [math]::Round($hw.MemorySize / 1GB, 0)
            CpuUsagePct        = if ($hw.CpuMhz -and $hw.NumCpuCores) { [math]::Round(100 * $qs.OverallCpuUsage / ($hw.CpuMhz * $hw.NumCpuCores), 1) } else { 0 }
            MemUsagePct        = if ($hw.MemorySize) { [math]::Round(100 * $qs.OverallMemoryUsage * 1MB / $hw.MemorySize, 1) } else { 0 }
            UptimeDays         = [math]::Round($qs.Uptime / 86400, 1)
            RebootRequired     = [bool]$h.Summary.RebootRequired
            LockdownMode       = [string]$h.Config.LockdownMode
            SshRunning         = [bool]($services | Where-Object { $_.Key -eq 'TSM-SSH' -and $_.Running })
            ShellRunning       = [bool]($services | Where-Object { $_.Key -eq 'TSM' -and $_.Running })
            NtpServers         = @($ntp)
            NtpRunning         = $ntpRunning
            SyslogHost         = $syslog
            CertExpires        = $certExpires
            PowerPolicy        = [string](Get-VhSafe { $h.Config.PowerSystemInfo.CurrentPolicy.ShortName } '')
            DeadPaths          = $deadPaths
            ConfigIssues       = @($h.ConfigIssue | ForEach-Object { $_.FullFormattedMessage })
            TpmSupported       = [bool](Get-VhSafe { $h.Capability.TpmSupported } $false)
            TpmVersion         = [string](Get-VhSafe { $h.Capability.TpmVersion } '')
            UefiSecureBoot     = [bool](Get-VhSafe { $h.Capability.UefiSecureBoot } $false)
            VSwitches          = @($h.Config.Network.Vswitch | ForEach-Object {
                    $sec = $_.Spec.Policy.Security
                    [pscustomobject]@{
                        Name = $_.Name; Mtu = [int]$_.Mtu
                        Uplinks = @(@($_.Pnic) | Where-Object { $_ } | ForEach-Object { $_ -replace '^.*PhysicalNic-', '' })
                        AllowPromiscuous = [bool]$sec.AllowPromiscuous; ForgedTransmits = [bool]$sec.ForgedTransmits; MacChanges = [bool]$sec.MacChanges
                    }
                })
            PortGroups         = @($h.Config.Network.Portgroup | ForEach-Object {
                    $sec = $_.Spec.Policy.Security
                    [pscustomobject]@{ Name = $_.Spec.Name; vSwitch = $_.Spec.VswitchName; VlanId = [int]$_.Spec.VlanId; AllowPromiscuous = $sec.AllowPromiscuous; ForgedTransmits = $sec.ForgedTransmits; MacChanges = $sec.MacChanges }
                })
            Hardware           = if ($IncludeHardware) { Get-VhHostHardware -HostView $h -Server $Server -DvsNames $dvsByUuid -DvPortGroupNames $dvpgNames -UseEsxcli:$UseEsxcli } else { $null }
        }
    }

    # ---- Datastores -------------------------------------------------------
    Write-Verbose "[$vc] Datastores"
    $datastores = foreach ($d in (Get-View -Server $Server -ViewType Datastore -Property Name, Summary, Host, Vm, OverallStatus)) {
        $s = $d.Summary
        $prov = $s.Capacity - $s.FreeSpace + $s.Uncommitted
        [pscustomobject]@{
            vCenter         = $vc
            Name            = $d.Name
            Type            = [string]$s.Type
            CapacityGB      = [math]::Round($s.Capacity / 1GB, 1)
            FreeGB          = [math]::Round($s.FreeSpace / 1GB, 1)
            ProvisionedGB   = [math]::Round($prov / 1GB, 1)
            Accessible      = [bool]$s.Accessible
            MaintenanceMode = [string]$s.MaintenanceMode
            HostCount       = @($d.Host).Count
            VmCount         = @($d.Vm).Count
            OverallStatus   = [string]$d.OverallStatus
        }
    }

    # ---- Virtual machines -------------------------------------------------
    Write-Verbose "[$vc] Virtual machines"
    $vmViews = @(Get-View -Server $Server -ViewType VirtualMachine -Property Name, Runtime, Guest, Snapshot, Summary.Storage,
        Config.GuestFullName, Config.Version, Config.Template, Config.Hardware, Config.CpuAllocation,
        Config.MemoryAllocation, Config.Firmware, Config.BootOptions, Config.Uuid)

    # Snapshot sizes need Get-Snapshot; only call it for VMs that have snapshots
    $snapSize = @{}
    $withSnaps = @($vmViews | Where-Object { $_.Snapshot })
    if ($withSnaps.Count) {
        Get-VhSafe {
            foreach ($sn in (Get-VIObjectByVIView -VIView $withSnaps | Get-Snapshot -ErrorAction Stop)) {
                $snapSize["$($sn.VMId)|$($sn.Name)|$($sn.Created.ToUniversalTime().ToString('s'))"] = [math]::Round($sn.SizeGB, 1)
            }
        }
    }
    $flattenSnaps = {
        param($vmView, $list)
        foreach ($n in $list) {
            $created = $n.CreateTime
            $key = "$($vmView.MoRef.ToString())|$($n.Name)|$($created.ToUniversalTime().ToString('s'))"
            [pscustomobject]@{ Name = $n.Name; Created = $created; SizeGB = $snapSize[$key] }
            if ($n.ChildSnapshotList) { & $flattenSnaps $vmView $n.ChildSnapshotList }
        }
    }

    $vms = foreach ($v in $vmViews) {
        $cfg = $v.Config
        $devices = if ($cfg) { @($cfg.Hardware.Device) } else { @() }
        $hostKey = if ($v.Runtime.Host) { $v.Runtime.Host.ToString() } else { '' }
        $hostName = [string]$hostByMoRef[$hostKey]
        $clusterName = [string]$hostCluster[$hostKey]

        $media = foreach ($dev in $devices) {
            if (($dev -is [VMware.Vim.VirtualCdrom] -or $dev -is [VMware.Vim.VirtualFloppy]) -and $dev.Connectable.Connected) {
                $dev.DeviceInfo.Label + ': ' + $dev.DeviceInfo.Summary
            }
        }
        $nics = foreach ($dev in $devices) { if ($dev -is [VMware.Vim.VirtualEthernetCard]) { $dev.GetType().Name -replace '^Virtual', '' } }

        [pscustomobject]@{
            vCenter             = $vc
            Name                = $v.Name
            Cluster             = $clusterName
            Host                = $hostName
            IsTemplate          = [bool](Get-VhSafe { $cfg.Template } $false)
            PowerState          = [string]$v.Runtime.PowerState
            ConnectionState     = [string]$v.Runtime.ConnectionState
            ConsolidationNeeded = [bool]$v.Runtime.ConsolidationNeeded
            ConfiguredOS        = [string](Get-VhSafe { $cfg.GuestFullName } '')
            GuestOS             = [string]$v.Guest.GuestFullName
            NumCpu              = [int](Get-VhSafe { $cfg.Hardware.NumCPU } 0)
            MemoryGB            = [math]::Round((Get-VhSafe { $cfg.Hardware.MemoryMB } 0) / 1024, 1)
            HardwareVersion     = [string](Get-VhSafe { $cfg.Version } '')
            ToolsRunningStatus  = [string]$v.Guest.ToolsRunningStatus
            ToolsVersionStatus  = [string]$v.Guest.ToolsVersionStatus2
            ToolsVersion        = [string]$v.Guest.ToolsVersion
            CpuLimitMHz         = [long](Get-VhSafe { $cfg.CpuAllocation.Limit } -1)
            MemLimitMB          = [long](Get-VhSafe { $cfg.MemoryAllocation.Limit } -1)
            CpuReservationMHz   = [long](Get-VhSafe { $cfg.CpuAllocation.Reservation } 0)
            MemReservationMB    = [long](Get-VhSafe { $cfg.MemoryAllocation.Reservation } 0)
            Firmware            = [string](Get-VhSafe { $cfg.Firmware } '')
            SecureBoot          = [bool](Get-VhSafe { $cfg.BootOptions.EfiSecureBootEnabled } $false)
            HasVTpm             = [bool]($devices | Where-Object { $_.GetType().Name -eq 'VirtualTPM' })
            ConnectedMedia      = @($media)
            NicTypes            = @($nics)
            ProvisionedGB       = [math]::Round(($v.Summary.Storage.Committed + $v.Summary.Storage.Uncommitted) / 1GB, 1)
            Snapshots           = @(if ($v.Snapshot) { & $flattenSnaps $v $v.Snapshot.RootSnapshotList })
        }
    }

    # ---- Triggered alarms -------------------------------------------------
    Write-Verbose "[$vc] Alarms"
    $alarmNames = @{}
    $alarms = foreach ($a in (Get-VhSafe { (Get-View -Server $Server $si.Content.RootFolder -Property TriggeredAlarmState).TriggeredAlarmState } @())) {
        $ak = $a.Alarm.ToString()
        if (-not $alarmNames.ContainsKey($ak)) { $alarmNames[$ak] = Get-VhSafe { (Get-View -Server $Server $a.Alarm -Property Info).Info.Name } $ak }
        [pscustomobject]@{
            vCenter = $vc
            Entity  = Get-VhSafe { (Get-View -Server $Server $a.Entity -Property Name).Name } $a.Entity.ToString()
            Type    = $a.Entity.Type
            Alarm   = $alarmNames[$ak]
            Status  = [string]$a.OverallStatus
            Time    = $a.Time
            Acknowledged = [bool]$a.Acknowledged
        }
    }

    # ---- Sessions ---------------------------------------------------------
    $sessions = foreach ($s in (Get-VhSafe { (Get-View -Server $Server $si.Content.SessionManager -Property SessionList).SessionList } @())) {
        [pscustomobject]@{ vCenter = $vc; UserName = $s.UserName; IpAddress = $s.IpAddress; UserAgent = $s.UserAgent; LoginTime = $s.LoginTime; LastActive = $s.LastActiveTime }
    }

    # ---- Licensing --------------------------------------------------------
    Write-Verbose "[$vc] Licensing"
    # vCenter 9 has no license keys (licensing moved to VCF Operations), so these
    # calls may return nothing. That is expected and handled by the licensing checks.
    $lm = Get-VhSafe { Get-View -Server $Server $si.Content.LicenseManager }
    $licenses = @(Get-VhSafe {
            foreach ($l in $lm.Licenses) {
                $exp = ($l.Properties | Where-Object { $_.Key -eq 'expirationDate' } | Select-Object -First 1).Value
                [pscustomobject]@{
                    vCenter    = $vc
                    Name       = [string]$l.Name
                    KeySuffix  = if ($l.LicenseKey) { [string]$l.LicenseKey.Substring([math]::Max(0, $l.LicenseKey.Length - 5)) } else { '' }
                    IsEval     = $l.LicenseKey -eq '00000-00000-00000-00000-00000'
                    EditionKey = [string]$l.EditionKey
                    CostUnit   = [string]$l.CostUnit
                    Total      = [long]$l.Total
                    Used       = [long]$l.Used
                    Expiration = $exp
                }
            }
        } @())
    $assignments = @(Get-VhSafe {
            $lam = Get-View -Server $Server $lm.LicenseAssignmentManager
            foreach ($a in $lam.QueryAssignedLicenses($null)) {
                [pscustomobject]@{
                    vCenter    = $vc
                    EntityName = [string]$a.EntityDisplayName
                    License    = [string]$a.AssignedLicense.Name
                    EditionKey = [string]$a.AssignedLicense.EditionKey
                    IsEval     = $a.AssignedLicense.LicenseKey -eq '00000-00000-00000-00000-00000'
                }
            }
        } @())

    [pscustomobject]@{
        vCenters     = @([pscustomobject]@{
                Name = $vc; Version = [string]$about.Version; Build = [string]$about.Build
                ApiVersion = [string]$about.ApiVersion; FullName = [string]$about.FullName
                InstanceUuid = [string]$about.InstanceUuid
            })
        CollectedAt  = (Get-Date).ToUniversalTime()
        Clusters     = @($clusters)
        Hosts        = @($hosts)
        Datastores   = @($datastores)
        Vms          = @($vms)
        DvSwitches   = @($dvSwitches)
        DvPortGroups = @($dvPortGroups)
        VxRail       = @()
        Alarms       = @($alarms)
        Sessions     = @($sessions)
        Licenses     = @($licenses)
        Assignments  = @($assignments)
    }
}

function Merge-VhInventory {
    <# Combines per-vCenter inventories into one. #>
    param([Parameter(Mandatory)][object[]]$Inventory)
    $props = 'vCenters', 'Clusters', 'Hosts', 'Datastores', 'Vms', 'DvSwitches', 'DvPortGroups', 'VxRail', 'Alarms', 'Sessions', 'Licenses', 'Assignments'
    $merged = [ordered]@{ CollectedAt = ($Inventory | Select-Object -First 1).CollectedAt }
    foreach ($p in $props) { $merged[$p] = @($Inventory | ForEach-Object { $_.$p } | Where-Object { $null -ne $_ }) }
    [pscustomobject]$merged
}

function Import-VhInventoryJson {
    <# Loads an inventory saved with -SaveInventory or a sample fixture. #>
    param([Parameter(Mandatory)][string]$Path)
    $inv = Get-Content -Path $Path -Raw | ConvertFrom-Json
    # ConvertFrom-Json collapses single-element arrays and leaves dates as strings in 5.1
    foreach ($p in 'vCenters', 'Clusters', 'Hosts', 'Datastores', 'Vms', 'DvSwitches', 'DvPortGroups', 'VxRail', 'Alarms', 'Sessions', 'Licenses', 'Assignments') {
        if (-not $inv.PSObject.Properties[$p]) { $inv | Add-Member -NotePropertyName $p -NotePropertyValue @() }
        $inv.$p = @($inv.$p)
    }
    $inv
}
