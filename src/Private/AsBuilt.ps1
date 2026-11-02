<#
    As-built documentation output.
    Get-VhAsBuiltTable builds every inventory table once; the HTML document,
    Excel workbook and CSV fallback all render from it.
#>

function Join-VhList { param($Value) (@($Value) | Where-Object { $_ -ne $null -and $_ -ne '' }) -join ', ' }

function Get-VhAsBuiltTable {
    <#
        .SYNOPSIS
            Returns an ordered dictionary: table name -> rows.
    #>
    param([Parameter(Mandatory)]$Inventory, [Parameter(Mandatory)][hashtable]$Settings)
    $t = [ordered]@{}
    $hwHosts = @($Inventory.Hosts | Where-Object { Get-VhProp $_ 'Hardware' })

    $t['vCenter Servers'] = @($Inventory.vCenters | ForEach-Object {
            [pscustomobject]@{ vCenter = $_.Name; Version = $_.Version; Build = $_.Build; Product = Get-VhProp $_ 'FullName' '' }
        })
    $t['Clusters'] = @($Inventory.Clusters | ForEach-Object {
            [pscustomobject]@{
                vCenter = $_.vCenter; Cluster = $_.Name; Datacenter = $_.Datacenter; Hosts = $_.NumHosts
                CpuCores = $_.TotalCpuCores; MemoryGB = $_.TotalMemoryGB
                HA = $_.HAEnabled; AdmissionControl = if ($_.HAAdmissionControl) { Get-VhProp $_ 'HAAdmissionPolicy' 'Enabled' } else { 'Disabled' }
                IsolationResponse = Get-VhProp $_ 'HAIsolationResponse' ''; VmMonitoring = Get-VhProp $_ 'HAVmMonitoring' ''
                DRS = if ($_.DrsEnabled) { $_.DrsBehavior } else { 'Disabled' }; DrsThreshold = Get-VhProp $_ 'DrsMigrationThreshold' ''
                EVC = if ($_.EvcMode) { $_.EvcMode } else { 'Disabled' }
                vSAN = if ($_.VsanEnabled) { if ($_.VsanEsa) { 'ESA' } else { 'OSA' } } else { 'No' }
                Lifecycle = if (Get-VhProp $_ 'IsVxRail' $false) { 'VxRail Manager' } elseif ($_.ImageManaged) { 'vLCM image' } else { 'Baselines' }
                VxRailManager = Get-VhProp $_ 'VxRailManager' ''; HostProfile = $_.HostProfile
            }
        })
    $t['Hosts'] = @($Inventory.Hosts | ForEach-Object {
            $hw = Get-VhProp $_ 'Hardware'
            [pscustomobject]@{
                Host = $_.Name; Cluster = $_.Cluster; Vendor = $_.Vendor; Model = $_.Model
                SerialNumber = Get-VhProp $hw 'SerialNumber' ''; ServiceTag = Get-VhProp $hw 'ServiceTag' ''
                Bios = Get-VhProp $hw 'BiosVersion' ''; BmcIp = Get-VhProp $hw 'BmcIp' ''
                Cpu = $_.CpuModel; Sockets = $_.CpuSockets; Cores = $_.CpuCores; MemoryGB = $_.MemoryGB
                ESXi = "$($_.Version) ($($_.Build))"; State = $_.ConnectionState; Maintenance = $_.MaintenanceMode
                TPM = if ($_.TpmSupported) { $_.TpmVersion } else { 'None' }; SecureBoot = $_.UefiSecureBoot
            }
        })
    $t['Physical NICs'] = @(foreach ($h in $hwHosts) {
            foreach ($p in @($h.Hardware.Pnics)) {
                if (-not $p) { continue }
                [pscustomobject]@{ Host = $h.Name; Nic = $p.Device; Switch = $p.Switch; Speed = if ($p.LinkUp) { "$([int]($p.LinkSpeedMb / 1000)) Gb" } else { 'Down' }; Driver = $p.Driver; DriverVersion = $p.DriverVersion; Firmware = $p.FirmwareVersion; Mac = $p.Mac; Pci = $p.Pci }
            }
        })
    $t['VMkernel Adapters'] = @(foreach ($h in $hwHosts) {
            foreach ($v in @($h.Hardware.Vmks)) {
                if (-not $v) { continue }
                [pscustomobject]@{ Host = $h.Name; Vmk = $v.Device; Services = Join-VhList $v.Services; Switch = $v.Switch; PortGroup = $v.PortGroup; IpAddress = $v.IpAddress; Netmask = $v.Netmask; Mtu = $v.Mtu; TcpStack = $v.TcpStack }
            }
        })
    $t['Storage Adapters'] = @(foreach ($h in $hwHosts) {
            foreach ($a in @($h.Hardware.Hbas)) {
                if (-not $a) { continue }
                [pscustomobject]@{ Host = $h.Name; Adapter = $a.Device; Type = $a.Type; Model = $a.Model; Driver = $a.Driver; Status = $a.Status; WWPN = $a.Wwpn; IQN = $a.Iqn }
            }
        })
    $t['Disks'] = @(foreach ($h in $hwHosts) {
            foreach ($d in @($h.Hardware.Disks)) {
                if (-not $d) { continue }
                [pscustomobject]@{ Host = $h.Name; Device = $d.CanonicalName; Vendor = $d.Vendor; Model = $d.Model; Firmware = $d.Firmware; CapacityGB = $d.CapacityGB; SSD = $d.Ssd; Local = $d.Local; vSAN = $d.VsanState; State = $d.State }
            }
        })
    # Document-sized views (the workbook keeps the full per-host lists): local disks per host,
    # shared LUNs once with the number of hosts that see them
    $t['Local Disks'] = @($t['Disks'] | Where-Object Local | Select-Object Host, Device, Vendor, Model, Firmware, CapacityGB, SSD, vSAN, State)
    $t['Shared LUNs'] = @($t['Disks'] | Where-Object { -not $_.Local } | Group-Object Device | ForEach-Object {
            $d = $_.Group[0]
            [pscustomobject]@{ Device = $d.Device; Vendor = $d.Vendor; Model = $d.Model; CapacityGB = $d.CapacityGB; SSD = $d.SSD; Hosts = $_.Count }
        })
    $t['PCI Devices'] = @(foreach ($h in $hwHosts) {
            foreach ($d in @($h.Hardware.PciDevices)) { if ($d) { [pscustomobject]@{ Host = $h.Name; Address = $d.Id; Class = $d.Class; Vendor = $d.Vendor; Device = $d.Device } } }
        })
    $t['Hardware Sensors'] = @(foreach ($h in $hwHosts) {
            foreach ($s in @($h.Hardware.Sensors)) { if ($s) { [pscustomobject]@{ Host = $h.Name; Sensor = $s.Name; Type = $s.Type; Reading = $s.Reading; Health = $s.Health } } }
        })
    $t['Sensors Not Normal'] = @($t['Hardware Sensors'] | Where-Object { $_.Health -and $_.Health -ne 'green' })
    $t['Distributed Switches'] = @($Inventory.DvSwitches | ForEach-Object { $_ | Select-Object vCenter, Name, Version, Mtu, Uplinks, Hosts, Nioc, Discovery })
    $t['Distributed Port Groups'] = @($Inventory.DvPortGroups | ForEach-Object {
            [pscustomobject]@{ vCenter = $_.vCenter; Switch = $_.Switch; PortGroup = $_.Name; VLAN = Get-VhProp $_ 'VlanId' ''; Binding = $_.BindingType; Ports = $_.NumPorts; VMs = $_.ConnectedVms }
        })
    $t['Standard Switches'] = @(foreach ($h in $Inventory.Hosts) {
            foreach ($s in @($h.VSwitches)) { if ($s) { [pscustomobject]@{ Host = $h.Name; Switch = $s.Name; Mtu = Get-VhProp $s 'Mtu' ''; Uplinks = Join-VhList (Get-VhProp $s 'Uplinks' @()) } } }
        })
    $t['Datastores'] = @($Inventory.Datastores | ForEach-Object {
            [pscustomobject]@{ vCenter = $_.vCenter; Datastore = $_.Name; Type = $_.Type; CapacityGB = $_.CapacityGB; FreeGB = $_.FreeGB; ProvisionedGB = $_.ProvisionedGB; Hosts = $_.HostCount; VMs = $_.VmCount }
        })
    if ($Settings.AsBuilt -and $Settings.AsBuilt.IncludeVmInventory) {
        $t['Virtual Machines'] = @($Inventory.Vms | Where-Object { -not $_.IsTemplate } | Sort-Object Cluster, Name | ForEach-Object {
                [pscustomobject]@{ VM = $_.Name; Cluster = $_.Cluster; Power = $_.PowerState; GuestOS = $_.ConfiguredOS; vCPU = $_.NumCpu; MemoryGB = $_.MemoryGB; ProvisionedGB = $_.ProvisionedGB; Hardware = $_.HardwareVersion; Firmware = $_.Firmware; Tools = $_.ToolsVersionStatus }
            })
    }

    # VxRail
    $vx = @($Inventory.VxRail)
    if ($vx.Count) {
        $t['VxRail Systems'] = @($vx | ForEach-Object {
                [pscustomobject]@{ Cluster = $_.Cluster; Manager = $_.Manager; Version = $_.Version; Health = $_.Health; Type = $_.ClusterType; Nodes = $_.NumberOfHosts; Installed = $_.InstalledTime; CallHome = $_.CallHomeStatus; Reachable = $_.Reachable }
            })
        $t['VxRail Components'] = @(foreach ($v in $vx) { foreach ($c in @($v.Components)) { if ($c) { [pscustomobject]@{ Cluster = $v.Cluster; Component = $c.Name; Description = $c.Description; Version = $c.Version; Baseline = $c.Baseline; Drifted = $c.BaselineDrifted } } } })
        $t['VxRail Nodes'] = @($vx | ForEach-Object { $_.Nodes } | Where-Object { $_ } | ForEach-Object { $_ | Select-Object Cluster, Hostname, Model, SerialNumber, Psnt, Slot, Health, PowerStatus, TpmPresent, ManagementIp, VmotionIp, VsanIp, IdracIp })
        $t['VxRail Firmware'] = @($vx | ForEach-Object { $_.Firmware } | Where-Object { $_ } | ForEach-Object { $_ | Select-Object Cluster, Hostname, Bios, Idrac, Boss, Perc, Hba, Cpld, BackplaneExpander, BackplaneNonExpander, Dcpm })
        $t['VxRail Disks'] = @($vx | ForEach-Object { $_.Disks } | Where-Object { $_ } | ForEach-Object { $_ | Select-Object Cluster, Hostname, Enclosure, Slot, Type, Protocol, Manufacturer, Model, SerialNumber, Firmware, Capacity, Speed, State, WriteEndurance })
        $t['VxRail Boot Devices'] = @($vx | ForEach-Object { $_.BootDevices } | Where-Object { $_ } | ForEach-Object { $_ | Select-Object Cluster, Hostname, Type, Model, SerialNumber, Slot, Capacity, Firmware, Health, PowerOnHours })
        $t['VxRail NICs'] = @($vx | ForEach-Object { $_.Nics } | Where-Object { $_ } | ForEach-Object { $_ | Select-Object Cluster, Hostname, Slot, Mac, LinkStatus, LinkSpeed, Firmware })
        $t['VxRail Power Supplies'] = @($vx | ForEach-Object { $_.PowerSupplies } | Where-Object { $_ } | ForEach-Object { $_ | Select-Object Cluster, Chassis, Slot, Name, Manufacturer, PartNumber, SerialNumber, Revision, Health })
        $t['VxRail Chassis'] = @($vx | ForEach-Object { $_.Chassis } | Where-Object { $_ } | ForEach-Object { $_ | Select-Object Cluster, Model, ServiceTag, SerialNumber, Psnt, Generation, Nodes, Health })
    }
    # Drop empty tables so the document and workbook only show what was collected
    $out = [ordered]@{}
    foreach ($k in $t.Keys) { if (@($t[$k]).Count) { $out[$k] = $t[$k] } }
    $out
}

function Get-VhAsBuiltCss {
@'
.doc .tbl{max-height:none;overflow-x:auto;overflow-y:visible}
.cover{background:linear-gradient(135deg,var(--brand),var(--brand2));color:#fff;padding:96px 0 72px}
.cover .org{font-size:13px;letter-spacing:.14em;text-transform:uppercase;opacity:.8}
.cover h1{font-size:40px;margin:10px 0 8px;font-weight:600;letter-spacing:-.01em}
.cover .sub{font-size:16px;opacity:.9}
.cover dl{display:grid;grid-template-columns:auto 1fr;gap:6px 24px;margin:36px 0 0;font-size:14px}
.cover dt{opacity:.7}.cover dd{margin:0}
.toc{columns:2;column-gap:32px;padding:0;margin:0;list-style:none}
.toc li{padding:5px 0;border-bottom:1px dashed var(--line);break-inside:avoid}
.toc .n{display:inline-block;min-width:34px;color:var(--muted);font-variant-numeric:tabular-nums}
section.ab{margin-top:28px}
section.ab>h2{font-size:22px;margin:0 0 4px;padding-bottom:8px;border-bottom:2px solid var(--line)}
section.ab>h2 .n{color:var(--muted);margin-right:10px;font-weight:500}
section.ab>p.lead{color:var(--muted);margin:6px 0 14px}
h3.sub{font-size:14px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:22px 0 8px}
.hostcard{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:18px 20px;margin:0 0 18px}
.hostcard>h3{margin:0 0 12px;font-size:17px}
.hostcard>h3 small{color:var(--muted);font-weight:400;margin-left:8px}
.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:8px 24px;margin:0 0 6px}
.facts div{font-size:13px}.facts div>span:first-child{display:block;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.06em}
.sens-ok{color:var(--pass)}.sens-bad{color:var(--crit);font-weight:600}
@page{size:A4 landscape;margin:10mm}
@media print{.cover{page-break-after:always;padding:120px 0}section.ab{page-break-before:always}.hostcard{break-inside:avoid-page}.toc{columns:1}
.doc .tbl{overflow:visible;border:0}.doc table{font-size:9.5px}.doc th,.doc td{padding:4px 6px}.doc th{position:static}
.doc tr{break-inside:avoid}.doc thead{display:table-header-group}}
@media (max-width:700px){.toc{columns:1}.cover h1{font-size:30px}}
'@
}

function ConvertTo-VhAsBuiltHtml {
    <#
        .SYNOPSIS
            Renders the as-built document (cover, contents, numbered sections, per-host hardware detail).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][hashtable]$Settings,
        [string]$ToolVersion = '1.0.0'
    )
    $h = { param($v) ConvertTo-VhHtmlText $v }
    $ab = if ($Settings.AsBuilt) { $Settings.AsBuilt } else { @{} }
    $title = if ($ab.Title) { [string]$ab.Title } else { 'vSphere As-Built Report' }
    $tables = Get-VhAsBuiltTable -Inventory $Inventory -Settings $Settings
    $lic = Get-VhLicenseSummary -Inventory $Inventory -Settings $Settings
    $now = Get-Date
    $sb = [Text.StringBuilder]::new()
    $add = { param($s) [void]$sb.Append($s) }

    # Section plan: (id, title, lead, table names)
    $sections = [System.Collections.Generic.List[object]]::new()
    $addSection = { param($id, $title, $lead, [string[]]$names) $sections.Add([pscustomobject]@{ Id = $id; Title = $title; Lead = $lead; Tables = @($names | Where-Object { $tables.Contains($_) }) }) }
    & $addSection 'summary' 'Executive summary' 'Scope of this document and the environment at a glance.' @()
    & $addSection 'vcenter' 'vCenter Server' 'vCenter Server instances included in this document.' @('vCenter Servers')
    & $addSection 'licensing' 'Licensing' 'Per-core subscription and vSAN capacity picture at the time of collection.' @()
    & $addSection 'clusters' 'Clusters' 'Cluster-level HA, DRS, EVC, vSAN and lifecycle configuration.' @('Clusters')
    & $addSection 'hosts' 'ESXi hosts' 'Host summary: hardware platform, firmware, CPU, memory and ESXi build.' @('Hosts')
    if (@($Inventory.Hosts | Where-Object { Get-VhProp $_ 'Hardware' }).Count) {
        & $addSection 'hostdetail' 'Host hardware detail' 'Per-host physical NICs, VMkernel adapters, storage adapters, disks and hardware sensors.' @()
    }
    & $addSection 'network' 'Networking' 'Distributed and standard switches, port groups and VLANs.' @('Distributed Switches', 'Distributed Port Groups', 'Standard Switches', 'Physical NICs', 'VMkernel Adapters')
    & $addSection 'storage' 'Storage' 'Datastores, storage adapters, local/vSAN disks and shared LUNs (each LUN listed once with the number of hosts that see it).' @('Datastores', 'Storage Adapters', 'Local Disks', 'Shared LUNs')
    if ($tables.Contains('VxRail Systems')) {
        & $addSection 'vxrail' 'Dell VxRail' 'Data from the VxRail Manager API: system, installed components, nodes, firmware, disks, boot devices, NICs and power supplies.' @('VxRail Systems', 'VxRail Components', 'VxRail Chassis', 'VxRail Nodes', 'VxRail Firmware', 'VxRail Disks', 'VxRail Boot Devices', 'VxRail NICs', 'VxRail Power Supplies')
    }
    if ($tables.Contains('Virtual Machines')) { & $addSection 'vms' 'Virtual machines' 'Virtual machine inventory (templates and excluded VMs omitted).' @('Virtual Machines') }
    if ($tables.Contains('PCI Devices') -or $tables.Contains('Sensors Not Normal')) { & $addSection 'appendix' 'Appendix: PCI devices and sensor exceptions' 'PCI devices (storage, network, GPU, accelerator) and any sensor not reporting normal. The full sensor list is in the Excel workbook.' @('PCI Devices', 'Sensors Not Normal') }

    & $add "<!DOCTYPE html><html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1"">"
    & $add "<title>$(& $h $title) - $($now.ToString('yyyy-MM-dd'))</title><style>$(Get-VhCss)$(Get-VhAsBuiltCss)</style></head><body class=""doc"">"

    # ---- Cover ----
    & $add "<div class=""cover""><div class=""wrap""><div class=""org"">$(& $h $Settings.Report.Organization)</div><h1>$(& $h $title)</h1><div class=""sub"">VMware vSphere$(if ($tables.Contains('VxRail Systems')) { ' &amp; Dell VxRail' }) configuration and hardware inventory</div><dl>"
    & $add "<dt>Date</dt><dd>$($now.ToString('MMMM d, yyyy'))</dd>"
    & $add "<dt>vCenter</dt><dd>$(& $h (($Inventory.vCenters | ForEach-Object { "$($_.Name) ($($_.Version))" }) -join ', '))</dd>"
    if ($ab.PreparedBy) { & $add "<dt>Prepared by</dt><dd>$(& $h $ab.PreparedBy)</dd>" }
    if ($ab.DocumentVersion) { & $add "<dt>Document version</dt><dd>$(& $h $ab.DocumentVersion)</dd>" }
    & $add "<dt>Data collected</dt><dd>$(& $h (ConvertTo-VhDate $Inventory.CollectedAt))</dd></dl></div></div><main><div class=""wrap"">"

    # ---- Contents ----
    & $add "<div class=""card"" style=""margin-top:24px""><h2>Contents</h2><ol class=""toc"">"
    $i = 0
    foreach ($s in $sections) { $i++; & $add "<li><span class=""n"">$i.</span><a href=""#$($s.Id)"">$(& $h $s.Title)</a></li>" }
    & $add "</ol></div>"

    $i = 0
    foreach ($s in $sections) {
        $i++
        & $add "<section class=""ab"" id=""$($s.Id)""><h2><span class=""n"">$i</span>$(& $h $s.Title)</h2><p class=""lead"">$(& $h $s.Lead)</p>"
        switch ($s.Id) {
            'summary' {
                $vms = @($Inventory.Vms | Where-Object { -not $_.IsTemplate })
                $facts = [ordered]@{
                    'vCenter Servers' = @($Inventory.vCenters).Count; 'Clusters' = @($Inventory.Clusters).Count
                    'ESXi hosts' = @($Inventory.Hosts).Count; 'Physical cores' = '{0:N0}' -f $lic.PhysicalCores
                    'Host memory' = '{0:N1} TB' -f ((Get-VhSum @($Inventory.Hosts) 'MemoryGB') / 1024)
                    'Virtual machines' = $vms.Count; 'Datastores' = @($Inventory.Datastores).Count
                    'Storage capacity' = '{0:N1} TB' -f ((Get-VhSum @($Inventory.Datastores) 'CapacityGB') / 1024)
                    'VxRail clusters' = @($Inventory.VxRail).Count
                    'Host models' = Join-VhList (@($Inventory.Hosts | ForEach-Object { "$($_.Vendor) $($_.Model)".Trim() } | Select-Object -Unique))
                }
                & $add "<div class=""card""><div class=""facts"">"
                foreach ($k in $facts.Keys) { & $add "<div><span>$k</span>$(& $h $facts[$k])</div>" }
                & $add "</div></div>"
            }
            'licensing' {
                & $add "<div class=""card""><dl class=""kv""><dt>Licensing method</dt><dd>$(& $h $lic.LicensingMethod)</dd><dt>Model</dt><dd>$(& $h $lic.Model)</dd>"
                & $add "<dt>Physical cores</dt><dd>$($lic.PhysicalCores)</dd><dt>Cores to license (16/CPU minimum)</dt><dd>$($lic.RequiredCores)</dd>"
                if ($lic.PurchasedCores) { & $add "<dt>Cores purchased</dt><dd>$($lic.PurchasedCores)</dd>" }
                if ($lic.VsanRawTiB) { & $add "<dt>vSAN raw capacity</dt><dd>$($lic.VsanRawTiB) TiB (entitled $($lic.VsanEntitledTiB) TiB)</dd>" }
                & $add "</dl></div>"
                $keys = @($Inventory.Licenses | Where-Object { -not $_.IsEval } | ForEach-Object { [pscustomobject]@{ vCenter = $_.vCenter; License = $_.Name; Key = "*****-$($_.KeySuffix)"; Unit = $_.CostUnit; Used = $_.Used; Total = $_.Total; Expires = ConvertTo-VhDate $_.Expiration } })
                if ($keys) { & $add "<h3 class=""sub"">License keys (vCenter 8.x)</h3>$(ConvertTo-VhHtmlTable -Rows $keys)" }
                & $add "<h3 class=""sub"">Cores per host</h3>$(ConvertTo-VhHtmlTable -Rows @($lic.Hosts))"
            }
            'hostdetail' {
                foreach ($hh in ($Inventory.Hosts | Where-Object { Get-VhProp $_ 'Hardware' } | Sort-Object Cluster, Name)) {
                    $hw = $hh.Hardware
                    $bad = @($hw.Sensors | Where-Object { $_ -and $_.Health -in 'red', 'yellow' }).Count
                    & $add "<div class=""hostcard"" id=""host-$(& $h $hh.Name)""><h3>$(& $h $hh.Name)<small>$(& $h $hh.Cluster)</small></h3><div class=""facts"">"
                    $f = [ordered]@{
                        'Platform' = "$($hw.Vendor) $($hw.Model)"; 'Serial / Service tag' = (Join-VhList @($hw.SerialNumber, $hw.ServiceTag | Select-Object -Unique))
                        'BIOS' = "$($hw.BiosVersion)$(if ($hw.BiosDate) { ' (' + (ConvertTo-VhDate $hw.BiosDate).ToString('yyyy-MM-dd') + ')' })"
                        'BMC / iDRAC' = $hw.BmcIp; 'CPU' = "$($hh.CpuSockets) x $($hw.CpuModel)"
                        'Cores / HT' = "$($hh.CpuCores) cores, HT $(if ($hw.HyperThreading) { 'on' } else { 'off' })"
                        'Memory' = "$($hh.MemoryGB) GB"; 'ESXi' = "$($hh.Version) build $($hh.Build)"
                        'TPM / Secure Boot' = "$(if ($hh.TpmSupported) { "TPM $($hh.TpmVersion)" } else { 'No TPM' }) / $(if ($hh.UefiSecureBoot) { 'Secure Boot' } else { 'No Secure Boot' })"
                        'Sensors' = if ($bad) { "<span class=""sens-bad"">$bad not normal</span>" } else { "<span class=""sens-ok"">All normal</span>" }
                    }
                    foreach ($k in $f.Keys) { & $add "<div><span>$k</span>$(if ($k -eq 'Sensors') { $f[$k] } else { & $h $f[$k] })</div>" }
                    & $add "</div>"
                    $pn = @($hw.Pnics | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Nic = $_.Device; Switch = $_.Switch; Speed = if ($_.LinkUp) { "$([int]($_.LinkSpeedMb / 1000)) Gb" } else { 'Down' }; Driver = $_.Driver; DriverVersion = $_.DriverVersion; Firmware = $_.FirmwareVersion; Mac = $_.Mac } })
                    if ($pn) { & $add "<h3 class=""sub"">Physical NICs</h3>$(ConvertTo-VhHtmlTable -Rows $pn)" }
                    $vk = @($hw.Vmks | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Vmk = $_.Device; Services = Join-VhList $_.Services; PortGroup = $_.PortGroup; IpAddress = $_.IpAddress; Netmask = $_.Netmask; Mtu = $_.Mtu } })
                    if ($vk) { & $add "<h3 class=""sub"">VMkernel adapters</h3>$(ConvertTo-VhHtmlTable -Rows $vk)" }
                    $hb = @($hw.Hbas | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Adapter = $_.Device; Type = $_.Type; Model = $_.Model; Driver = $_.Driver; WWPN = $_.Wwpn } })
                    if ($hb) { & $add "<h3 class=""sub"">Storage adapters</h3>$(ConvertTo-VhHtmlTable -Rows $hb)" }
                    $dk = @($hw.Disks | Where-Object { $_ -and $_.Local } | ForEach-Object { [pscustomobject]@{ Device = $_.CanonicalName; Vendor = $_.Vendor; Model = $_.Model; Firmware = $_.Firmware; CapacityGB = $_.CapacityGB; SSD = $_.Ssd; vSAN = $_.VsanState } })
                    if ($dk) { & $add "<h3 class=""sub"">Local disks</h3>$(ConvertTo-VhHtmlTable -Rows $dk)" }
                    $acc = @($hw.PciDevices | Where-Object { $_ -and $_.Class -in 'Display/GPU', 'Accelerator' })
                    if ($acc) { & $add "<h3 class=""sub"">GPUs / accelerators</h3>$(ConvertTo-VhHtmlTable -Rows $acc)" }
                    & $add "</div>"
                }
            }
        }
        foreach ($tn in $s.Tables) {
            if ($s.Tables.Count -gt 1) { & $add "<h3 class=""sub"">$(& $h $tn)</h3>" }
            & $add (ConvertTo-VhHtmlTable -Rows @($tables[$tn]))
        }
        & $add "</section>"
    }
    & $add "</div></main><footer><div class=""wrap"">$(& $h $title) &middot; generated by vSphere Health Report v$ToolVersion &middot; $($now.ToString('u')) &middot; Print or save as PDF from your browser for a paginated document.</div></footer>"
    & $add "<script>$(Get-VhScript)</script></body></html>"
    $sb.ToString()
}

function Export-VhAsBuiltWorkbook {
    <#
        .SYNOPSIS
            One worksheet per as-built table via ImportExcel; falls back to CSV files.
            Returns the path written.
    #>
    param([Parameter(Mandatory)]$Inventory, [Parameter(Mandatory)][hashtable]$Settings, [Parameter(Mandatory)][string]$Folder)
    $all = Get-VhAsBuiltTable -Inventory $Inventory -Settings $Settings
    # Subsets made for the printed document; the workbook carries the full lists instead
    $tables = [ordered]@{}
    foreach ($k in $all.Keys) { if ($k -notin 'Local Disks', 'Sensors Not Normal') { $tables[$k] = $all[$k] } }
    $useExcel = $Settings.AsBuilt -and $Settings.AsBuilt.Excel -and (Get-Module -ListAvailable -Name ImportExcel)
    if ($useExcel) {
        Import-Module ImportExcel -ErrorAction Stop
        $path = Join-Path $Folder 'vSphereAsBuilt.xlsx'
        foreach ($k in $tables.Keys) {
            $sheet = ($k -replace '[\[\]\*\?/\\:]', '')
            if ($sheet.Length -gt 31) { $sheet = $sheet.Substring(0, 31) }
            @($tables[$k]) | ForEach-Object {
                # Flatten arrays so cells stay readable
                $o = [ordered]@{}
                foreach ($p in $_.PSObject.Properties) { $o[$p.Name] = if ($p.Value -is [array]) { Join-VhList $p.Value } else { $p.Value } }
                [pscustomobject]$o
            } | Export-Excel -Path $path -WorksheetName $sheet -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter -TableStyle Medium2 -TableName ('t' + ($sheet -replace '[^A-Za-z0-9]', ''))
        }
        return $path
    }
    $dir = Join-Path $Folder 'asbuilt-csv'
    $null = New-Item -ItemType Directory -Path $dir -Force
    foreach ($k in $tables.Keys) {
        @($tables[$k]) | Export-Csv -Path (Join-Path $dir (($k -replace '[^A-Za-z0-9]+', '-') + '.csv')) -NoTypeInformation -Encoding UTF8
    }
    $dir
}
