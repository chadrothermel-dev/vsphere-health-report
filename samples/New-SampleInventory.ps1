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

$vcenters = @(
    [pscustomobject]@{ Name = 'vcsa-prod01.corp.local'; Version = '9.0.1'; Build = '24957454'; ApiVersion = '9.0.0.0'; FullName = 'VMware vCenter Server 9.0.1 build-24957454'; InstanceUuid = '7c1d0f1e-0000-4000-8000-000000000001' }
    [pscustomobject]@{ Name = 'vcsa-dr01.corp.local'; Version = '8.0.3'; Build = '24322831'; ApiVersion = '8.0.3.0'; FullName = 'VMware vCenter Server 8.0.3 build-24322831'; InstanceUuid = '7c1d0f1e-0000-4000-8000-000000000002' }
)

$clusterDefs = @(
    @{ vc = 0; Name = 'PROD-Compute-01'; Dc = 'DC-East'; Hosts = 6; Ver = '9.0.1'; Build = '24957456'; Cores = 32; Sockets = 2; Mem = 1024; Vsan = $true; Esa = $true; Image = $true; Ha = $true; Ac = $true; Drs = 'fullyAutomated' }
    @{ vc = 0; Name = 'PROD-Compute-02'; Dc = 'DC-East'; Hosts = 4; Ver = '9.0.1'; Build = '24957456'; Cores = 24; Sockets = 2; Mem = 768; Vsan = $true; Esa = $false; Image = $true; Ha = $true; Ac = $false; Drs = 'partiallyAutomated' }
    @{ vc = 0; Name = 'PROD-Mgmt'; Dc = 'DC-East'; Hosts = 4; Ver = '9.0.1'; Build = '24957456'; Cores = 16; Sockets = 1; Mem = 512; Vsan = $true; Esa = $true; Image = $true; Ha = $true; Ac = $true; Drs = 'fullyAutomated' }
    @{ vc = 1; Name = 'DR-Compute-01'; Dc = 'DC-West'; Hosts = 4; Ver = '8.0.3'; Build = '24280767'; Cores = 12; Sockets = 2; Mem = 512; Vsan = $false; Esa = $false; Image = $false; Ha = $true; Ac = $true; Drs = 'fullyAutomated'; Profile = 'DR-Baseline-Profile' }
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
        $hosts += [pscustomobject]@{
            vCenter = $vcName; Name = $name; Cluster = $c.Name; Version = $c.Ver; Build = $build
            ConnectionState = $state; PowerState = 'poweredOn'
            MaintenanceMode = ($c.Name -eq 'PROD-Mgmt' -and $i -eq 4)
            OverallStatus = if ($c.Name -eq 'DR-Compute-01' -and $i -eq 3) { 'yellow' } else { 'green' }
            Vendor = if ($c.vc -eq 0) { 'Dell Inc.' } else { 'HPE' }
            Model = if ($c.vc -eq 0) { 'PowerEdge R760' } else { 'ProLiant DL380 Gen10' }
            CpuModel = if ($c.vc -eq 0) { 'Intel(R) Xeon(R) Gold 6430' } else { 'Intel(R) Xeon(R) Silver 4214' }
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
            TpmSupported = $c.vc -eq 0; TpmVersion = if ($c.vc -eq 0) { '2.0' } else { '' }; UefiSecureBoot = $c.vc -eq 0
            VSwitches = @([pscustomobject]@{ Name = 'vSwitch0'; AllowPromiscuous = $false; ForgedTransmits = ($c.vc -eq 1); MacChanges = $false })
            PortGroups = @([pscustomobject]@{ Name = 'Management Network'; vSwitch = 'vSwitch0'; AllowPromiscuous = $null; ForgedTransmits = $null; MacChanges = $null })
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
$vmCounts = @{ 'PROD-Compute-01' = 120; 'PROD-Compute-02' = 85; 'PROD-Mgmt' = 18; 'DR-Compute-01' = 40; 'DR-Legacy' = 14 }
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
    [pscustomobject]@{ vCenter = $vcenters[0].Name; Name = 'dvpg-prod-app-vlan110'; Switch = 'vds-prod-01'; BindingType = 'earlyBinding'; NumPorts = 512; AutoExpand = $true; ConnectedVms = 140; AllowPromiscuous = $false; ForgedTransmits = $false; MacChanges = $false }
    [pscustomobject]@{ vCenter = $vcenters[0].Name; Name = 'dvpg-nested-lab'; Switch = 'vds-prod-01'; BindingType = 'earlyBinding'; NumPorts = 32; AutoExpand = $true; ConnectedVms = 6; AllowPromiscuous = $true; ForgedTransmits = $true; MacChanges = $true }
    [pscustomobject]@{ vCenter = $vcenters[1].Name; Name = 'dvpg-dr-app-vlan210'; Switch = 'vds-dr-01'; BindingType = 'earlyBinding'; NumPorts = 64; AutoExpand = $false; ConnectedVms = 59; AllowPromiscuous = $false; ForgedTransmits = $false; MacChanges = $false }
)

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
    Clusters = $clusters; Hosts = $hosts; Datastores = $datastores; Vms = $vms; DvPortGroups = $dvpg
    Alarms = $alarms; Sessions = $sessions; Licenses = $licenses; Assignments = $assignments
} | ConvertTo-Json -Depth 8
