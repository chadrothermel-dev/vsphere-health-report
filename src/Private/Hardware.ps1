<#
    Host hardware (as-built) collection from vCenter.
    Vendor-neutral: works for Dell/VxRail, HPE, Lenovo, Cisco, etc. Everything
    comes from HostSystem properties already fetched by the collector, plus
    optional esxcli calls for NIC firmware/driver versions and the BMC address.
#>

# Extra HostSystem properties needed for the hardware inventory
$script:VhHardwareHostProperties = @(
    'Hardware.SystemInfo', 'Hardware.BiosInfo', 'Hardware.CpuPkg', 'Hardware.PciDevice', 'Hardware.MemorySize',
    'Config.HyperThread', 'Config.Network.Pnic', 'Config.Network.Vnic', 'Config.Network.ProxySwitch',
    'Config.VirtualNicManagerInfo', 'Config.StorageDevice.HostBusAdapter', 'Config.StorageDevice.ScsiLun',
    'Runtime.HealthSystemRuntime', 'Runtime.BootTime'
)

function Format-VhWwn {
    param($Value)
    if (-not $Value) { return '' }
    $hex = ('{0:x16}' -f [long]$Value)
    ($hex -split '(..)' | Where-Object { $_ }) -join ':'
}

function Get-VhHostHardware {
    <#
        .SYNOPSIS
            Builds the as-built hardware object for one HostSystem view.
        .PARAMETER DvsNames
            Hashtable of DVS UUID -> switch name, for VMkernel adapter mapping.
        .PARAMETER DvPortGroupNames
            Hashtable of port group key -> name.
    #>
    param(
        [Parameter(Mandatory)]$HostView,
        [Parameter(Mandatory)]$Server,
        [hashtable]$DvsNames = @{},
        [hashtable]$DvPortGroupNames = @{},
        [switch]$UseEsxcli
    )
    $h = $HostView
    $sys = $h.Hardware.SystemInfo
    $ids = @(Get-VhSafe { $sys.OtherIdentifyingInfo } @())
    $idValue = { param($key) [string](($ids | Where-Object { $_.IdentifierType.Key -eq $key } | Select-Object -First 1).IdentifierValue) }
    $serial = [string](Get-VhSafe { $sys.SerialNumber } '')
    $serviceTag = & $idValue 'ServiceTag'
    if (-not $serial) { $serial = & $idValue 'EnclosureSerialNumberTag' }

    # Uplink membership (standard and distributed switches)
    $uplinkOf = @{}
    foreach ($vs in @(Get-VhSafe { $h.Config.Network.Vswitch } @())) {
        foreach ($k in @($vs.Pnic)) { if ($k) { $uplinkOf[$k] = $vs.Name } }
    }
    foreach ($ps in @(Get-VhSafe { $h.Config.Network.ProxySwitch } @())) {
        foreach ($k in @($ps.Pnic)) { if ($k) { $uplinkOf[$k] = $ps.DvsName } }
    }

    # esxcli: NIC driver/firmware versions and BMC IP (opt-in; slower, may need extra privileges)
    $nicDetail = @{}; $bmcIp = ''
    if ($UseEsxcli -and $h.Runtime.ConnectionState -eq 'connected') {
        $esx = Get-VhSafe { Get-EsxCli -VMHost (Get-VIObjectByVIView -VIView $h -Server $Server) -V2 -ErrorAction Stop }
        if ($esx) {
            foreach ($p in @($h.Config.Network.Pnic)) {
                $info = Get-VhSafe { $esx.network.nic.get.Invoke(@{ nicname = $p.Device }) }
                if ($info) {
                    $nicDetail[$p.Device] = [pscustomobject]@{
                        DriverVersion   = [string](Get-VhSafe { $info.DriverInfo.Version } '')
                        FirmwareVersion = [string](Get-VhSafe { $info.DriverInfo.FirmwareVersion } '')
                    }
                }
            }
            $bmcIp = [string](Get-VhSafe { ($esx.hardware.ipmi.bmc.get.Invoke() | Select-Object -First 1).IPv4Address } '')
        }
    }

    $pnics = foreach ($p in @(Get-VhSafe { $h.Config.Network.Pnic } @())) {
        $d = $nicDetail[$p.Device]
        [pscustomobject]@{
            Device          = $p.Device
            Driver          = [string]$p.Driver
            DriverVersion   = if ($d) { $d.DriverVersion } else { '' }
            FirmwareVersion = if ($d) { $d.FirmwareVersion } else { '' }
            Mac             = [string]$p.Mac
            LinkSpeedMb     = if ($p.LinkSpeed) { [int]$p.LinkSpeed.SpeedMb } else { 0 }
            LinkUp          = [bool]$p.LinkSpeed
            Pci             = [string]$p.Pci
            Switch          = [string]$uplinkOf[$p.Key]
        }
    }

    # VMkernel adapters with enabled services (management, vmotion, vsan, ...)
    $services = @{}
    foreach ($nc in @(Get-VhSafe { $h.Config.VirtualNicManagerInfo.NetConfig } @())) {
        foreach ($sel in @($nc.SelectedVnic)) {
            if (-not $sel) { continue }
            $vk = ($sel -split '\.', 2)[-1]
            if (-not $services.ContainsKey($vk)) { $services[$vk] = @() }
            $services[$vk] += $nc.NicType
        }
    }
    $vmks = foreach ($v in @(Get-VhSafe { $h.Config.Network.Vnic } @())) {
        $dvp = $v.Spec.DistributedVirtualPort
        [pscustomobject]@{
            Device    = $v.Device
            Switch    = if ($dvp) { [string]$DvsNames[$dvp.SwitchUuid] } else { '' }
            PortGroup = if ($dvp) { [string]$DvPortGroupNames[$dvp.PortgroupKey] } else { [string]$v.Portgroup }
            IpAddress = [string]$v.Spec.Ip.IpAddress
            Netmask   = [string]$v.Spec.Ip.SubnetMask
            Dhcp      = [bool]$v.Spec.Ip.Dhcp
            Mtu       = [int]$v.Spec.Mtu
            Mac       = [string]$v.Spec.Mac
            TcpStack  = [string]$v.Spec.NetStackInstanceKey
            Services  = @($services[$v.Key] | Sort-Object -Unique)
        }
    }

    $hbas = foreach ($a in @(Get-VhSafe { $h.Config.StorageDevice.HostBusAdapter } @())) {
        $type = $a.GetType().Name -replace '^Host', '' -replace 'HostBusAdapter$', '' -replace 'Hba$', ''
        [pscustomobject]@{
            Device = $a.Device; Type = $type; Model = [string]$a.Model; Driver = [string]$a.Driver
            Status = [string]$a.Status; Pci = [string]$a.Pci
            Wwpn   = if ($a.PSObject.Properties['PortWorldWideName']) { Format-VhWwn $a.PortWorldWideName } else { '' }
            Iqn    = if ($a.PSObject.Properties['IScsiName']) { [string]$a.IScsiName } else { '' }
        }
    }

    # vSAN claim state per disk (eligible / inUse / ineligible); ESA and OSA both answer this
    $vsanState = @{}
    if ($h.Runtime.ConnectionState -eq 'connected') {
        Get-VhSafe {
            $vs = Get-View -Server $Server $h.ConfigManager.VsanSystem
            foreach ($r in $vs.QueryDisksForVsan($null)) { $vsanState[$r.Disk.CanonicalName] = [string]$r.State }
        }
    }
    $disks = foreach ($l in @(Get-VhSafe { $h.Config.StorageDevice.ScsiLun } @())) {
        if ($l.LunType -ne 'disk') { continue }
        $bytes = Get-VhSafe { [double]$l.Capacity.Block * [double]$l.Capacity.BlockSize } 0
        [pscustomobject]@{
            CanonicalName = [string]$l.CanonicalName
            DisplayName   = [string]$l.DisplayName
            Vendor        = ([string]$l.Vendor).Trim()
            Model         = ([string]$l.Model).Trim()
            Firmware      = ([string]$l.Revision).Trim()
            CapacityGB    = [math]::Round($bytes / 1GB, 1)
            Ssd           = [bool](Get-VhSafe { $l.Ssd } $false)
            Local         = [bool](Get-VhSafe { $l.LocalDisk } $false)
            State         = [string](@($l.OperationalState) | Select-Object -First 1)
            VsanState     = [string]$vsanState[[string]$l.CanonicalName]
        }
    }

    # Sensors: numeric sensors plus memory / CPU / storage status lists
    $hs = Get-VhSafe { $h.Runtime.HealthSystemRuntime }
    $sensors = @(
        foreach ($s in @(Get-VhSafe { $hs.SystemHealthInfo.NumericSensorInfo } @())) {
            $reading = if ($null -ne $s.CurrentReading) { [math]::Round($s.CurrentReading * [math]::Pow(10, $s.UnitModifier), 2) } else { $null }
            [pscustomobject]@{ Name = [string]$s.Name; Type = [string]$s.SensorType; Health = [string]$s.HealthState.Key; Reading = if ($null -ne $reading) { "$reading $($s.BaseUnits)".Trim() } else { '' } }
        }
        foreach ($pair in @(@('Memory', 'MemoryStatusInfo'), @('Processor', 'CpuStatusInfo'), @('Storage', 'StorageStatusInfo'))) {
            foreach ($s in @(Get-VhSafe { $hs.HardwareStatusInfo.($pair[1]) } @())) {
                [pscustomobject]@{ Name = [string]$s.Name; Type = $pair[0]; Health = [string]$s.Status.Key; Reading = '' }
            }
        }
    )

    # PCI: storage (0x01), network (0x02), display/GPU (0x03), accelerators (0x12)
    $pci = foreach ($d in @(Get-VhSafe { $h.Hardware.PciDevice } @())) {
        $class = ([int]$d.ClassId -shr 8) -band 0xFF
        if ($class -notin 0x01, 0x02, 0x03, 0x12) { continue }
        [pscustomobject]@{
            Id = [string]$d.Id
            Class = switch ($class) { 0x01 { 'Storage' } 0x02 { 'Network' } 0x03 { 'Display/GPU' } 0x12 { 'Accelerator' } }
            Vendor = [string]$d.VendorName; Device = [string]$d.DeviceName
        }
    }

    $pkg = @(Get-VhSafe { $h.Hardware.CpuPkg } @())
    [pscustomobject]@{
        Vendor          = [string](Get-VhSafe { $sys.Vendor } '')
        Model           = [string](Get-VhSafe { $sys.Model } '')
        SerialNumber    = $serial
        ServiceTag      = $serviceTag
        AssetTag        = & $idValue 'AssetTag'
        BiosVersion     = [string](Get-VhSafe { $h.Hardware.BiosInfo.BiosVersion } '')
        BiosDate        = Get-VhSafe { $h.Hardware.BiosInfo.ReleaseDate }
        CpuModel        = [string](($pkg | Select-Object -First 1).Description -replace '\s+', ' ')
        CpuMhz          = [int](Get-VhSafe { ($pkg | Select-Object -First 1).Hz / 1e6 } 0)
        HyperThreading  = [bool](Get-VhSafe { $h.Config.HyperThread.Active } $false)
        BootTime        = Get-VhSafe { $h.Runtime.BootTime }
        BmcIp           = $bmcIp
        Pnics           = @($pnics)
        Vmks            = @($vmks)
        Hbas            = @($hbas)
        Disks           = @($disks)
        Sensors         = @($sensors)
        PciDevices      = @($pci)
    }
}
