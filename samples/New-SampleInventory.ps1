<#
.SYNOPSIS
    Builds the fictional sample inventory used for demos and tests.
    One VCF 9 vCenter (production) and one vSphere 8 vCenter (DR site).
    Output is deterministic so tests and screenshots are repeatable.
.EXAMPLE
    .\samples\New-SampleInventory.ps1 | Set-Content .\samples\sample-inventory.json
#>
param([datetime]$Now = (Get-Date).Date.AddHours(6))

$rand = [Random]::new(42)
function Get-Rnd([int]$min, [int]$max) { $rand.Next($min, $max + 1) }
$d = { param($days) $Now.AddDays(-$days).ToUniversalTime().ToString('o') }

function New-SampleHardware {
    # Fictional as-built hardware for one host. Deliberate drift/faults feed HW-00x checks.
    param($c, [int]$i, [string]$name, [bool]$connected)
    $vxr = [bool]$c.VxRail
    $dell = $c.vc -eq 0 -or $vxr
    $tag = ('{0}{1}{2:D2}' -f $(if ($vxr) { 'VX' } elseif ($dell) { 'PE' } else { 'HP' }), ($c.Name -creplace '[^A-Z0-9]', ''), $i)
    $speed = if ($dell) { 25000 } else { 10000 }
    $nicDrv = if ($dell) { 'bnxtnet' } else { 'i40en' }
    $nicFw = if ($dell) { '22.31.13.70' } else { '9.20 0x8000d95e 1.3429.0' }
    if ($vxr -and $i -eq 3) { $nicFw = '21.85.21.92' }                       # NIC firmware drift (HW-001)
    $pnics = foreach ($n in 0..3) {
        $up = $true
        if ($c.Name -eq 'DR-Compute-01' -and $i -eq 3 -and $n -eq 1) { $up = $false }   # dead uplink (HW-003)
        $sw = if ($n -lt 2) { if ($c.vc -eq 0 -or $vxr) { if ($vxr) { 'vds-vxrail-01' } else { 'vds-prod-01' } } else { 'vSwitch0' } } else { if ($vxr) { 'vds-vxrail-01' } elseif ($c.vc -eq 0) { 'vds-prod-01' } else { 'vds-dr-01' } }
        [pscustomobject]@{
            Device = "vmnic$n"; Driver = $nicDrv; DriverVersion = if ($dell) { '226.0.145.0' } else { '2.6.5.0' }; FirmwareVersion = $nicFw
            Mac = ('00:50:56:{0:x2}:{1:x2}:{2:x2}' -f $c.vc, $i, ($n + 16)); LinkSpeedMb = if ($up) { if ($c.Name -eq 'PROD-Compute-02' -and $i -eq 2 -and $n -eq 3) { 10000 } else { $speed } } else { 0 }
            LinkUp = $up; Pci = ('0000:{0:x2}:00.{1}' -f (0x31 + [int]($n / 2)), ($n % 2)); Switch = $sw
        }
    }
    $base = if ($c.vc -eq 0) { 10 } else { 20 }
    $vmks = @(
        [pscustomobject]@{ Device = 'vmk0'; Switch = $pnics[0].Switch; PortGroup = 'Management'; IpAddress = "10.$base.10.$(10 + $i)"; Netmask = '255.255.255.0'; Dhcp = $false; Mtu = 1500; Mac = ''; TcpStack = 'defaultTcpipStack'; Services = @('management') }
        [pscustomobject]@{ Device = 'vmk1'; Switch = $pnics[2].Switch; PortGroup = 'vMotion'; IpAddress = "10.$base.11.$(10 + $i)"; Netmask = '255.255.255.0'; Dhcp = $false; Mtu = 9000; Mac = ''; TcpStack = 'vmotion'; Services = @('vmotion') }
    )
    if ($c.Vsan) {
        $mtu = if ($c.Name -eq 'PROD-Compute-02' -and $i -eq 3) { 1500 } else { 9000 }      # MTU mismatch (HW-005)
        $vmks += [pscustomobject]@{ Device = 'vmk2'; Switch = $pnics[2].Switch; PortGroup = 'vSAN'; IpAddress = "10.$base.12.$(10 + $i)"; Netmask = '255.255.255.0'; Dhcp = $false; Mtu = $mtu; Mac = ''; TcpStack = 'defaultTcpipStack'; Services = @('vsan') }
    }
    $hbas = @([pscustomobject]@{ Device = 'vmhba0'; Type = 'Block'; Model = if ($dell) { 'Dell BOSS-N1 Monolithic' } else { 'HPE NS204i-p Gen10+ Boot Controller' }; Driver = 'vmw_ahci'; Status = 'online'; Pci = '0000:02:00.0'; Wwpn = ''; Iqn = '' })
    if ($c.vc -eq 1 -and -not $vxr) {
        foreach ($n in 1..2) { $hbas += [pscustomobject]@{ Device = "vmhba$($n + 1)"; Type = 'FibreChannel'; Model = 'QLogic QLE2772 32Gb FC'; Driver = 'qlnativefc'; Status = 'online'; Pci = "0000:5e:00.$($n - 1)"; Wwpn = ('21:00:00:24:ff:{0:x2}:{1:x2}:{2:x2}' -f $c.Hosts, $i, $n); Iqn = '' } }
    }
    if ($c.Vsan) { $hbas += [pscustomobject]@{ Device = 'vmhba3'; Type = 'Block'; Model = 'NVMe PCIe controller'; Driver = 'nvme_pcie'; Status = 'online'; Pci = '0000:c1:00.0'; Wwpn = ''; Iqn = '' } }
    $disks = @([pscustomobject]@{ CanonicalName = "t10.ATA_____BOOT_M.2_____$tag"; DisplayName = 'Local boot (M.2 RAID1)'; Vendor = 'ATA'; Model = if ($dell) { 'Dell BOSS-N1 VD' } else { 'HPE NS204i VD' }; Firmware = '2.1.13.2025'; CapacityGB = 447.1; Ssd = $true; Local = $true; State = 'ok'; VsanState = 'ineligible' })
    if ($c.Vsan) {
        $count = if ($c.Esa) { 6 } else { 5 }
        foreach ($n in 1..$count) {
            $cache = (-not $c.Esa) -and $n -eq 1
            $disks += [pscustomobject]@{
                CanonicalName = ('eui.{0}{1:D2}{2:D2}' -f ($tag.ToLower() -replace '[^a-z0-9]', ''), $i, $n); DisplayName = "Local NVMe Disk $n"
                Vendor = 'NVMe'; Model = if ($cache) { 'Dell Ent NVMe P5800x WI U.2 800GB' } else { 'Dell Ent NVMe P5620 MU U.2 3.2TB' }
                Firmware = if ($vxr -and $i -eq 2 -and $n -eq 4) { '1.3.0' } else { '1.4.1' }; CapacityGB = if ($cache) { 745.2 } else { 2980.4 }
                Ssd = $true; Local = $true; State = 'ok'; VsanState = 'inUse'
            }
        }
    }
    if ($c.vc -eq 1 -and -not $vxr) {
        foreach ($n in 1..3) { $disks += [pscustomobject]@{ CanonicalName = ('naa.624a9370{0:D8}{1:D16}' -f $n, 4096 + $n); DisplayName = "PURE Fibre Channel Disk (DR-VMFS-0$n)"; Vendor = 'PURE'; Model = 'FlashArray'; Firmware = '8888'; CapacityGB = if ($n -eq 3) { 8192 } else { 16384 }; Ssd = $true; Local = $false; State = 'ok'; VsanState = '' } }
    }
    $psuBad = $c.Name -eq 'DR-Compute-01' -and $i -eq 3
    $sensors = @(
        [pscustomobject]@{ Name = 'Power Supply 1 PS1 Status'; Type = 'power'; Health = 'green'; Reading = '' }
        [pscustomobject]@{ Name = 'Power Supply 2 PS2 Status'; Type = 'power'; Health = if ($psuBad) { 'yellow' } else { 'green' }; Reading = '' }
        [pscustomobject]@{ Name = 'System Board 1 Fan1A RPM'; Type = 'fan'; Health = 'green'; Reading = "$(5400 + 120 * $i) RPM" }
        [pscustomobject]@{ Name = 'CPU1 Temp'; Type = 'temperature'; Health = 'green'; Reading = "$(52 + $i) Degrees C" }
        [pscustomobject]@{ Name = 'System Board 1 Inlet Temp'; Type = 'temperature'; Health = 'green'; Reading = "$(21 + ($i % 3)) Degrees C" }
        [pscustomobject]@{ Name = 'Memory'; Type = 'Memory'; Health = 'green'; Reading = '' }
    )
    $pci = @(
        [pscustomobject]@{ Id = '0000:31:00.0'; Class = 'Network'; Vendor = if ($dell) { 'Broadcom Inc.' } else { 'Intel Corporation' }; Device = if ($dell) { 'BCM57414 NetXtreme-E 10Gb/25Gb RDMA Ethernet Controller' } else { 'Ethernet Controller X710 for 10GbE SFP+' } }
        [pscustomobject]@{ Id = '0000:02:00.0'; Class = 'Storage'; Vendor = if ($dell) { 'Marvell' } else { 'HPE' }; Device = if ($dell) { 'BOSS-N1 Monolithic' } else { 'NS204i-p Gen10+ Boot Controller' } }
    )
    if ($c.Name -eq 'PROD-Compute-01' -and $i -le 2) { $pci += [pscustomobject]@{ Id = '0000:ca:00.0'; Class = 'Display/GPU'; Vendor = 'NVIDIA Corporation'; Device = 'NVIDIA L40S' } }
    $bios = if ($vxr) { '2.3.5' } elseif ($dell) { if ($c.Name -eq 'PROD-Compute-01' -and $i -eq 5) { '2.2.6' } else { '2.3.5' } } else { 'U30 v2.90 (07/20/2023)' }
    [pscustomobject]@{
        Vendor = if ($dell) { 'Dell Inc.' } else { 'HPE' }
        Model = if ($vxr) { 'VxRail VE-660' } elseif ($dell) { 'PowerEdge R760' } else { 'ProLiant DL380 Gen10' }
        SerialNumber = $tag; ServiceTag = if ($dell) { $tag } else { '' }; AssetTag = ''
        BiosVersion = $bios; BiosDate = if ($dell) { '2025-04-10T00:00:00Z' } else { '2023-07-20T00:00:00Z' }
        CpuModel = if ($vxr) { 'Intel(R) Xeon(R) Gold 6438N' } elseif ($dell) { 'Intel(R) Xeon(R) Gold 6430' } else { 'Intel(R) Xeon(R) Silver 4214' }
        CpuMhz = if ($dell) { 2100 } else { 2200 }; HyperThreading = $true; BootTime = $null
        BmcIp = "10.$base.5.$(10 + $i)"
        Pnics = @($pnics); Vmks = @($vmks); Hbas = @($hbas); Disks = @($disks); Sensors = @($sensors); PciDevices = @($pci)
    }
}

$vcenters = @(
    [pscustomobject]@{ Name = 'vcsa-prod01.corp.local'; Version = '9.0.1'; Build = '24957454'; ApiVersion = '9.0.0.0'; FullName = 'VMware vCenter Server 9.0.1 build-24957454'; InstanceUuid = '7c1d0f1e-0000-4000-8000-000000000001' }
    [pscustomobject]@{ Name = 'vcsa-dr01.corp.local'; Version = '8.0.3'; Build = '24322831'; ApiVersion = '8.0.3.0'; FullName = 'VMware vCenter Server 8.0.3 build-24322831'; InstanceUuid = '7c1d0f1e-0000-4000-8000-000000000002' }
)

$clusterDefs = @(
    @{ vc = 0; Name = 'PROD-Compute-01'; Dc = 'DC-East'; Hosts = 6; Ver = '9.0.1'; Build = '24957456'; Cores = 32; Sockets = 2; Mem = 1024; Vsan = $true; Esa = $true; Image = $true; Ha = $true; Ac = $true; Drs = 'fullyAutomated' }
    @{ vc = 0; Name = 'PROD-Compute-02'; Dc = 'DC-East'; Hosts = 4; Ver = '9.0.1'; Build = '24957456'; Cores = 24; Sockets = 2; Mem = 768; Vsan = $true; Esa = $false; Image = $true; Ha = $true; Ac = $false; Drs = 'partiallyAutomated' }
    @{ vc = 0; Name = 'PROD-Mgmt'; Dc = 'DC-East'; Hosts = 4; Ver = '9.0.1'; Build = '24957456'; Cores = 16; Sockets = 1; Mem = 512; Vsan = $true; Esa = $true; Image = $true; Ha = $true; Ac = $true; Drs = 'fullyAutomated' }
    @{ vc = 1; Name = 'DR-Compute-01'; Dc = 'DC-West'; Hosts = 4; Ver = '8.0.3'; Build = '24280767'; Cores = 12; Sockets = 2; Mem = 512; Vsan = $false; Esa = $false; Image = $false; Ha = $true; Ac = $true; Drs = 'fullyAutomated'; Profile = 'DR-Baseline-Profile' }
    @{ vc = 1; Name = 'DR-VxRail-01'; Dc = 'DC-West'; Hosts = 4; Ver = '8.0.3'; Build = '24280767'; Cores = 32; Sockets = 2; Mem = 1024; Vsan = $true; Esa = $true; Image = $true; Ha = $true; Ac = $true; Drs = 'fullyAutomated'; VxRail = 'vxm-dr01.corp.local' }
    @{ vc = 1; Name = 'DR-Legacy'; Dc = 'DC-West'; Hosts = 2; Ver = '7.0.3'; Build = '21930508'; Cores = 10; Sockets = 2; Mem = 256; Vsan = $false; Esa = $false; Image = $false; Ha = $false; Ac = $false; Drs = 'fullyAutomated' }
)

$clusters = @(); $hosts = @(); $vms = @(); $datastores = @()
$hostSeq = 0
foreach ($c in $clusterDefs) {
    $vcName = $vcenters[$c.vc].Name
    $clusters += [pscustomobject]@{
        vCenter = $vcName; Name = $c.Name; Datacenter = $c.Dc; NumHosts = $c.Hosts; NumEffectiveHosts = $c.Hosts
        TotalCpuCores = $c.Hosts * $c.Cores * $c.Sockets; TotalMemoryGB = $c.Hosts * $c.Mem
        HAEnabled = $c.Ha; HAAdmissionControl = $c.Ac; HAHostMonitoring = 'enabled'
        DrsEnabled = $true; DrsBehavior = $c.Drs; EvcMode = 'intel-sapphirerapids'
        VsanEnabled = $c.Vsan; VsanEsa = $c.Esa; ImageManaged = $c.Image; HostProfile = [string]$c.Profile
        IsVxRail = [bool]$c.VxRail; VxRailManager = [string]$c.VxRail
        HAAdmissionPolicy = 'ResourcePercentage'; HAIsolationResponse = 'powerOff'; HAVmMonitoring = 'vmMonitoringDisabled'; DrsMigrationThreshold = 3
    }
    for ($i = 1; $i -le $c.Hosts; $i++) {
        $hostSeq++
        $name = ('{0}-esx{1:00}.corp.local' -f ($c.Name.ToLower() -replace '-compute-', 'c' -replace '-', ''), $i)
        $build = $c.Build
        if ($c.Name -eq 'PROD-Compute-02' -and $i -eq 4) { $build = '24585383' }   # mixed build
        $state = 'connected'
        if ($c.Name -eq 'DR-Legacy' -and $i -eq 2) { $state = 'notResponding' }
        $mem = Get-Rnd 55 82
        if ($c.Name -eq 'PROD-Compute-02') { $mem = Get-Rnd 86 94 }
        $hwo = New-SampleHardware -c $c -i $i -name $name -connected ($state -eq 'connected')
        $hosts += [pscustomobject]@{
            vCenter = $vcName; Name = $name; Cluster = $c.Name; Version = $c.Ver; Build = $build
            ConnectionState = $state; PowerState = 'poweredOn'
            MaintenanceMode = ($c.Name -eq 'PROD-Mgmt' -and $i -eq 4)
            OverallStatus = if ($c.Name -eq 'DR-Compute-01' -and $i -eq 3) { 'yellow' } else { 'green' }
            Vendor = $hwo.Vendor
            Model = $hwo.Model
            CpuModel = $hwo.CpuModel
            CpuSockets = $c.Sockets; CpuCores = $c.Sockets * $c.Cores; CpuCoresPerSocket = $c.Cores
            MemoryGB = $c.Mem; CpuUsagePct = (Get-Rnd 18 62); MemUsagePct = $mem
            UptimeDays = (Get-Rnd 12 190); RebootRequired = ($c.Name -eq 'DR-Compute-01' -and $i -le 2)
            LockdownMode = if ($c.vc -eq 0) { 'lockdownNormal' } else { 'lockdownDisabled' }
            SshRunning = ($c.Name -eq 'PROD-Compute-01' -and $i -eq 2) -or ($c.Name -eq 'DR-Legacy')
            ShellRunning = ($c.Name -eq 'DR-Legacy' -and $i -eq 1)
            NtpServers = if ($c.Name -eq 'DR-Legacy') { @() } else { @('ntp1.corp.local', 'ntp2.corp.local') }
            NtpRunning = $c.Name -ne 'DR-Legacy'
            SyslogHost = if ($c.vc -eq 0) { 'tcp://syslog.corp.local:514' } else { '' }
            CertExpires = if ($c.Name -eq 'DR-Compute-01' -and $i -eq 4) { & $d -21 } elseif ($c.Name -eq 'DR-Legacy') { & $d -9 } else { & $d (-(Get-Rnd 300 700)) }
            PowerPolicy = 'dynamic'
            DeadPaths = if ($c.Name -eq 'DR-Compute-01' -and $i -eq 1) { 2 } else { 0 }
            ConfigIssues = @(if ($c.Name -eq 'DR-Compute-01' -and $i -eq 3) { "Network uplink redundancy lost on vSwitch0 for host $name" })
            TpmSupported = $c.vc -eq 0 -or [bool]$c.VxRail; TpmVersion = if ($c.vc -eq 0 -or $c.VxRail) { '2.0' } else { '' }; UefiSecureBoot = $c.vc -eq 0 -or [bool]$c.VxRail
            VSwitches = @(if ($c.vc -eq 1 -and -not $c.VxRail) { [pscustomobject]@{ Name = 'vSwitch0'; Mtu = 1500; Uplinks = @('vmnic0', 'vmnic1'); AllowPromiscuous = $false; ForgedTransmits = $true; MacChanges = $false } })
            PortGroups = @(if ($c.vc -eq 1 -and -not $c.VxRail) { [pscustomobject]@{ Name = 'Management Network'; vSwitch = 'vSwitch0'; VlanId = 20; AllowPromiscuous = $null; ForgedTransmits = $null; MacChanges = $null } })
            Hardware = $hwo
        }
    }
    if ($c.Vsan) {
        $raw = $c.Hosts * $(if ($c.Name -eq 'PROD-Compute-01') { 46080 } elseif ($c.Name -eq 'PROD-Compute-02') { 30720 } else { 15360 })
        $datastores += [pscustomobject]@{ vCenter = $vcName; Name = "vsanDatastore-$($c.Name)"; Type = 'vsan'; CapacityGB = $raw; FreeGB = [math]::Round($raw * (Get-Rnd 30 55) / 100, 1); ProvisionedGB = [math]::Round($raw * 0.7, 1); Accessible = $true; MaintenanceMode = 'normal'; HostCount = $c.Hosts; VmCount = 0; OverallStatus = 'green' }
    }
}

# Shared SAN / NFS datastores
$dsDefs = @(
    @{ vc = 0; Name = 'PROD-NFS-ISO'; Type = 'NFS41'; Cap = 4096; Free = 2210; Prov = 1900 }
    @{ vc = 0; Name = 'PROD-VVOL-Tier1'; Type = 'VVOL'; Cap = 20480; Free = 9100; Prov = 14000 }
    @{ vc = 1; Name = 'DR-VMFS-01'; Type = 'VMFS'; Cap = 16384; Free = 1310; Prov = 27800 }
    @{ vc = 1; Name = 'DR-VMFS-02'; Type = 'VMFS'; Cap = 16384; Free = 2900; Prov = 15100 }
    @{ vc = 1; Name = 'DR-VMFS-03'; Type = 'VMFS'; Cap = 8192; Free = 4100; Prov = 6000 }
)
foreach ($x in $dsDefs) {
    $datastores += [pscustomobject]@{ vCenter = $vcenters[$x.vc].Name; Name = $x.Name; Type = $x.Type; CapacityGB = $x.Cap; FreeGB = $x.Free; ProvisionedGB = $x.Prov; Accessible = $true; MaintenanceMode = 'normal'; HostCount = 4; VmCount = (Get-Rnd 8 60); OverallStatus = 'green' }
}

# Virtual machines
$roles = @(
    @{ p = 'app'; os = 'Microsoft Windows Server 2022 (64-bit)'; cpu = 4; mem = 16 }
    @{ p = 'web'; os = 'Red Hat Enterprise Linux 9 (64-bit)'; cpu = 2; mem = 8 }
    @{ p = 'sql'; os = 'Microsoft Windows Server 2022 (64-bit)'; cpu = 8; mem = 64 }
    @{ p = 'k8s'; os = 'Ubuntu Linux (64-bit)'; cpu = 8; mem = 32 }
    @{ p = 'file'; os = 'Microsoft Windows Server 2019 (64-bit)'; cpu = 4; mem = 16 }
)
$vmCounts = @{ 'PROD-Compute-01' = 120; 'PROD-Compute-02' = 85; 'PROD-Mgmt' = 18; 'DR-Compute-01' = 40; 'DR-VxRail-01' = 30; 'DR-Legacy' = 14 }
$n = 0
foreach ($c in $clusterDefs) {
    $vcName = $vcenters[$c.vc].Name
    $clusterHosts = @($hosts | Where-Object Cluster -eq $c.Name)
    for ($i = 1; $i -le $vmCounts[$c.Name]; $i++) {
        $n++
        $r = $roles[$n % $roles.Count]
        $name = '{0}{1}-{2:000}' -f $(if ($c.vc -eq 0) { 'p' } else { 'd' }), $r.p, $i
        if ($c.Name -eq 'PROD-Mgmt') { $name = @('vcf-ops01', 'vcf-ops02', 'vcf-auto01', 'nsx-mgr01', 'nsx-mgr02', 'nsx-mgr03', 'sddc-mgr01', 'vcf-logs01', 'idm01', 'backup-proxy01', 'dc01', 'dc02', 'pki-ca01', 'jump01', 'jump02', 'monitor01', 'syslog01', 'wsus01')[$i - 1] }
        $hw = if ($c.vc -eq 0) { @('vmx-22', 'vmx-21', 'vmx-20')[$n % 3] } else { @('vmx-19', 'vmx-17', 'vmx-15', 'vmx-13')[$n % 4] }
        $power = if ($n % 17 -eq 0) { 'poweredOff' } else { 'poweredOn' }
        $toolsRun = if ($power -eq 'poweredOn' -and $n % 29 -eq 0) { 'guestToolsNotRunning' } elseif ($power -eq 'poweredOn') { 'guestToolsRunning' } else { 'guestToolsNotRunning' }
        $toolsVer = if ($c.vc -eq 1 -and $n % 7 -eq 0) { 'guestToolsSupportedOld' } elseif ($n % 41 -eq 0) { 'guestToolsTooOld' } else { 'guestToolsCurrent' }
        $snaps = @()
        if ($n % 43 -eq 0) { $snaps += [pscustomobject]@{ Name = 'Before patching'; Created = (& $d (Get-Rnd 8 45)); SizeGB = [math]::Round((Get-Rnd 12 160) + 0.4, 1) } }
        if ($n % 61 -eq 0) { $snaps += [pscustomobject]@{ Name = 'pre-upgrade'; Created = (& $d 96); SizeGB = 212.7 } }
        if ($n % 37 -eq 0) { $snaps += [pscustomobject]@{ Name = 'VEEAM BACKUP TEMPORARY SNAPSHOT'; Created = (& $d 5); SizeGB = 31.2 } }
        $vms += [pscustomobject]@{
            vCenter = $vcName; Name = $name; Cluster = $c.Name; Host = $clusterHosts[$n % $clusterHosts.Count].Name
            IsTemplate = $false; PowerState = $power; ConnectionState = if ($n -eq 250) { 'orphaned' } else { 'connected' }
            ConsolidationNeeded = ($n % 53 -eq 0)
            ConfiguredOS = $r.os; GuestOS = if ($n % 47 -eq 0 -and $r.os -like '*2019*') { 'Microsoft Windows Server 2022 (64-bit)' } elseif ($power -eq 'poweredOn') { $r.os } else { '' }
            NumCpu = $r.cpu * $(if ($c.Name -eq 'PROD-Compute-02') { 3 } else { 1 }); MemoryGB = $r.mem; HardwareVersion = $hw
            ToolsRunningStatus = $toolsRun; ToolsVersionStatus = $toolsVer; ToolsVersion = if ($toolsVer -eq 'guestToolsCurrent') { '12.5.0' } else { '11.3.5' }
            CpuLimitMHz = if ($n % 71 -eq 0) { 4000 } else { -1 }; MemLimitMB = if ($n % 83 -eq 0) { 8192 } else { -1 }
            CpuReservationMHz = 0; MemReservationMB = if ($r.p -eq 'sql' -and $c.vc -eq 0 -and $i -le 10) { $r.mem * 1024 } else { 0 }
            Firmware = if ($c.vc -eq 1 -and $n % 2 -eq 0) { 'bios' } else { 'efi' }; SecureBoot = $c.vc -eq 0; HasVTpm = ($c.vc -eq 0 -and $r.os -like '*Windows*')
            ConnectedMedia = @(if ($n % 31 -eq 0) { 'CD/DVD drive 1: ISO [PROD-NFS-ISO] iso/win2022.iso' })
            NicTypes = @(if ($c.vc -eq 1 -and $n % 5 -eq 0) { 'E1000e' } else { 'Vmxnet3' })
            ProvisionedGB = (Get-Rnd 60 900); Snapshots = $snaps
        }
    }
}
# vCLS agents are excluded by default (Exclusions.VmNamePattern)
$vms += [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'vCLS-4c4c4544-0001'; Cluster = 'DR-Compute-01'; Host = ($hosts | Where-Object Cluster -eq 'DR-Compute-01')[0].Name; IsTemplate = $false; PowerState = 'poweredOn'; ConnectionState = 'connected'; ConsolidationNeeded = $false; ConfiguredOS = 'Other 3.x Linux (64-bit)'; GuestOS = ''; NumCpu = 1; MemoryGB = 0.1; HardwareVersion = 'vmx-11'; ToolsRunningStatus = 'guestToolsNotRunning'; ToolsVersionStatus = 'guestToolsUnmanaged'; ToolsVersion = ''; CpuLimitMHz = -1; MemLimitMB = -1; CpuReservationMHz = 0; MemReservationMB = 0; Firmware = 'bios'; SecureBoot = $false; HasVTpm = $false; ConnectedMedia = @(); NicTypes = @(); ProvisionedGB = 2; Snapshots = @() }

$dvpg = @(
    [pscustomobject]@{ vCenter = $vcenters[0].Name; Name = 'dvpg-prod-app-vlan110'; Switch = 'vds-prod-01'; VlanId = '110'; BindingType = 'earlyBinding'; NumPorts = 512; AutoExpand = $true; ConnectedVms = 140; AllowPromiscuous = $false; ForgedTransmits = $false; MacChanges = $false }
    [pscustomobject]@{ vCenter = $vcenters[0].Name; Name = 'dvpg-nested-lab'; Switch = 'vds-prod-01'; VlanId = '0-4094'; BindingType = 'earlyBinding'; NumPorts = 32; AutoExpand = $true; ConnectedVms = 6; AllowPromiscuous = $true; ForgedTransmits = $true; MacChanges = $true }
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'dvpg-dr-app-vlan210'; Switch = 'vds-dr-01'; VlanId = '210'; BindingType = 'earlyBinding'; NumPorts = 64; AutoExpand = $false; ConnectedVms = 59; AllowPromiscuous = $false; ForgedTransmits = $false; MacChanges = $false }
)

$dvpg += [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'VxRail Management-vxm-dr01'; Switch = 'vds-vxrail-01'; VlanId = '3939'; BindingType = 'earlyBinding'; NumPorts = 128; AutoExpand = $true; ConnectedVms = 5; AllowPromiscuous = $false; ForgedTransmits = $false; MacChanges = $false }
$dvpg += [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'vSAN-vxm-dr01'; Switch = 'vds-vxrail-01'; VlanId = '3940'; BindingType = 'earlyBinding'; NumPorts = 128; AutoExpand = $true; ConnectedVms = 0; AllowPromiscuous = $false; ForgedTransmits = $false; MacChanges = $false }
$dvSwitches = @(
    [pscustomobject]@{ vCenter = $vcenters[0].Name; Name = 'vds-prod-01'; Version = '9.0.0'; Mtu = 9000; Uplinks = 4; Hosts = 14; Nioc = $true; Discovery = 'lldp/both' }
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'vds-dr-01'; Version = '8.0.0'; Mtu = 9000; Uplinks = 2; Hosts = 6; Nioc = $true; Discovery = 'cdp/listen' }
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'vds-vxrail-01'; Version = '8.0.3'; Mtu = 9000; Uplinks = 4; Hosts = 4; Nioc = $true; Discovery = 'lldp/both' }
)

# Dell VxRail Manager data for DR-VxRail-01 (fictional serials)
$vxHosts = @($hosts | Where-Object Cluster -eq 'DR-VxRail-01')
$vxNodes = @(); $vxFw = @(); $vxDisks = @(); $vxNics = @(); $vxBoot = @(); $vxPsu = @(); $vxChassis = @()
$k = 0
foreach ($h in $vxHosts) {
    $k++
    $sn = $h.Hardware.ServiceTag
    $vxNodes += [pscustomobject]@{ Manager = 'vxm-dr01.corp.local'; Cluster = 'DR-VxRail-01'; Hostname = $h.Name; SerialNumber = $sn; Psnt = ('VXRPSNT{0:D7}' -f (4200 + $k)); Model = 'VxRail VE-660'; Slot = '1'; Health = 'Healthy'; OperationalStatus = 'normal'; PowerStatus = 'on'; Missing = $false; TpmPresent = $true; ManagementIp = $h.Hardware.Vmks[0].IpAddress; VmotionIp = $h.Hardware.Vmks[1].IpAddress; VsanIp = $h.Hardware.Vmks[2].IpAddress; IdracIp = $h.Hardware.BmcIp }
    $vxFw += [pscustomobject]@{ Manager = 'vxm-dr01.corp.local'; Cluster = 'DR-VxRail-01'; Hostname = $h.Name; Bios = '2.3.5'; Idrac = if ($k -eq 4) { '7.10.70.00' } else { '7.10.90.00' }; Cpld = '1.0.6'; Hba = ''; Boss = '2.1.13.2025'; Perc = ''; BackplaneExpander = ''; BackplaneNonExpander = '7.10'; Dcpm = '' }
    $vxChassis += [pscustomobject]@{ Manager = 'vxm-dr01.corp.local'; Cluster = 'DR-VxRail-01'; SerialNumber = $sn; ServiceTag = $sn; Psnt = ('VXRPSNT{0:D7}' -f (4200 + $k)); Model = 'VxRail VE-660'; Generation = '16'; Health = if ($k -eq 2) { 'Warning' } else { 'Healthy' }; Missing = $false; Nodes = 1 }
    foreach ($n in 1..6) {
        $vxDisks += [pscustomobject]@{ Manager = 'vxm-dr01.corp.local'; Cluster = 'DR-VxRail-01'; Hostname = $h.Name; Enclosure = '0'; Slot = [string]($n - 1); SerialNumber = ('S6EVNA0W{0}{1:D3}' -f $k, $n); Manufacturer = 'Samsung'; Model = 'Dell Ent NVMe PM1733a RI 3.84TB'; Firmware = if ($k -eq 2 -and $n -eq 4) { '1.3.0' } else { '1.4.1' }; Type = 'SSD'; Protocol = 'NVMe'; Capacity = '3.49 TB'; Speed = '16 GT/s'; State = if ($k -eq 3 -and $n -eq 5) { 'Failed' } else { 'OK' }; Missing = $false; WriteEndurance = if ($k -eq 1 -and $n -eq 2) { '14' } else { [string](92 - $n) }; EnduranceStatus = '' }
    }
    foreach ($n in 1..4) { $vxNics += [pscustomobject]@{ Manager = 'vxm-dr01.corp.local'; Cluster = 'DR-VxRail-01'; Hostname = $h.Name; Slot = [string]$n; Mac = $h.Hardware.Pnics[$n - 1].Mac; LinkStatus = 'Up'; LinkSpeed = '25 Gbps'; Firmware = $h.Hardware.Pnics[$n - 1].FirmwareVersion } }
    $vxBoot += [pscustomobject]@{ Manager = 'vxm-dr01.corp.local'; Cluster = 'DR-VxRail-01'; Hostname = $h.Name; Type = 'BOSS-N1'; Model = 'Dell BOSS-N1 M.2 480GB'; SerialNumber = ('PHYH4{0:D6}' -f (31000 + $k)); Slot = '0'; Capacity = '447 GB'; SataType = 'NVMe'; Firmware = '2.1.13.2025'; Health = 'Healthy'; PowerOnHours = [string](8100 + 37 * $k) }
    foreach ($n in 1..2) { $vxPsu += [pscustomobject]@{ Manager = 'vxm-dr01.corp.local'; Cluster = 'DR-VxRail-01'; Chassis = $sn; Slot = [string]$n; Name = "PSU$n"; Manufacturer = 'Dell'; SerialNumber = ('CNDED00{0}{1}' -f $k, $n); PartNumber = '0J1GKC'; Revision = 'A01'; Health = if ($k -eq 2 -and $n -eq 2) { 'Warning' } else { 'Healthy' }; Missing = $false } }
}
$vxNics[13].LinkStatus = 'Down'
$vxrail = @([pscustomobject]@{
        Manager = 'vxm-dr01.corp.local'; Cluster = 'DR-VxRail-01'; vCenter = $vcenters[1].Name; Reachable = $true
        Version = '8.0.320-28447893'; Health = 'Warning'; ClusterType = 'STANDARD'; NumberOfHosts = $vxHosts.Count
        InstalledTime = '2025-03-14T15:22:00Z'; NetworkConnected = $true; VcConnected = $true; ExternalVc = $true; UpgradeStatus = 'LATEST'
        CallHomeStatus = 'Connected'; CallHomeSiteId = '12345678'
        Components = @(
            [pscustomobject]@{ Name = 'VxRail Manager'; Description = 'VxRail Manager appliance'; Version = '8.0.320-28447893'; Baseline = '8.0.320'; BaselineDrifted = $false; Supported = $true; UpgradeStatus = 'LATEST' }
            [pscustomobject]@{ Name = 'ESXi'; Description = 'VMware ESXi'; Version = '8.0.3-24280767'; Baseline = '8.0.3-24280767'; BaselineDrifted = $false; Supported = $true; UpgradeStatus = 'LATEST' }
            [pscustomobject]@{ Name = 'BIOS'; Description = 'Dell PowerEdge BIOS'; Version = '2.3.5'; Baseline = '2.3.5'; BaselineDrifted = $false; Supported = $true; UpgradeStatus = 'LATEST' }
            [pscustomobject]@{ Name = 'iDRAC'; Description = 'Integrated Dell Remote Access Controller'; Version = '7.10.90.00'; Baseline = '7.10.90.00'; BaselineDrifted = $true; Supported = $true; UpgradeStatus = 'LATEST' }
            [pscustomobject]@{ Name = 'BOSS-N1'; Description = 'Boot Optimized Storage Solution firmware'; Version = '2.1.13.2025'; Baseline = '2.1.13.2025'; BaselineDrifted = $false; Supported = $true; UpgradeStatus = 'LATEST' }
            [pscustomobject]@{ Name = 'bnxtnet'; Description = 'Broadcom NIC driver'; Version = '226.0.145.0'; Baseline = '226.0.145.0'; BaselineDrifted = $false; Supported = $true; UpgradeStatus = 'LATEST' }
        )
        Chassis = $vxChassis; Nodes = $vxNodes; Firmware = $vxFw; Disks = $vxDisks; Nics = $vxNics; BootDevices = $vxBoot; PowerSupplies = $vxPsu
        Errors = @(); Raw = $null
    })

$alarms = @(
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Entity = ($hosts | Where-Object Cluster -eq 'DR-Compute-01')[2].Name; Type = 'HostSystem'; Alarm = 'Network uplink redundancy lost'; Status = 'yellow'; Time = (& $d 2); Acknowledged = $false }
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Entity = 'DR-VMFS-01'; Type = 'Datastore'; Alarm = 'Datastore usage on disk'; Status = 'red'; Time = (& $d 1); Acknowledged = $false }
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Entity = ($hosts | Where-Object Cluster -eq 'DR-Legacy')[1].Name; Type = 'HostSystem'; Alarm = 'Host connection and power state'; Status = 'red'; Time = (& $d 0.2); Acknowledged = $false }
    [pscustomobject]@{ vCenter = $vcenters[0].Name; Entity = 'vcsa-prod01.corp.local'; Type = 'VirtualMachine'; Alarm = 'Certificate Status'; Status = 'yellow'; Time = (& $d 6); Acknowledged = $true }
)

$sessions = @(
    [pscustomobject]@{ vCenter = $vcenters[0].Name; UserName = 'CORP\svc-backup'; IpAddress = '10.10.20.15'; UserAgent = 'VMware vim-java 1.0'; LoginTime = (& $d 9); LastActive = (& $d 3) }
    [pscustomobject]@{ vCenter = $vcenters[0].Name; UserName = 'VSPHERE.LOCAL\Administrator'; IpAddress = '10.10.5.21'; UserAgent = 'Mozilla/5.0'; LoginTime = (& $d 0.1); LastActive = (& $d 0.01) }
)

# vCenter 8 keeps license keys; vCenter 9 does not
$licenses = @(
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'VMware vSphere 8 Enterprise Plus for VCF'; KeySuffix = '4K2Q1'; IsEval = $false; EditionKey = 'esx.vcf.cpuCore'; CostUnit = 'cpuCore'; Total = 192; Used = 208; Expiration = (& $d -38) }
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'VMware vCenter Server 8 Standard'; KeySuffix = '9M3D7'; IsEval = $false; EditionKey = 'vc.vcf.std'; CostUnit = 'server'; Total = 1; Used = 1; Expiration = (& $d -38) }
)
$assignments = @(
    [pscustomobject]@{ vCenter = $vcenters[1].Name; EntityName = ($hosts | Where-Object Cluster -eq 'DR-Legacy')[0].Name; License = 'Evaluation Mode'; EditionKey = 'eval'; IsEval = $true }
)

[pscustomobject]@{
    vCenters = $vcenters; CollectedAt = $Now.ToUniversalTime().ToString('o')
    Clusters = $clusters; Hosts = $hosts; Datastores = $datastores; Vms = $vms; DvSwitches = $dvSwitches; DvPortGroups = $dvpg; VxRail = $vxrail
    Alarms = $alarms; Sessions = $sessions; Licenses = $licenses; Assignments = $assignments
} | ConvertTo-Json -Depth 10
