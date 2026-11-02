<#
    VxRail Manager REST API client (read-only).
    Field names follow Dell's published VxRail public API schema
    (GET /v1/system, /v1/system/cluster-hosts, /v1/hosts, /v1/chassis,
    /v1/hosts/{sn}/idrac/network, /v1/callhome/info). Every nested property
    is treated as optional because the schema can change between VxRail releases.
#>

function Get-VhProp {
    # First non-empty property from a list of candidate names (handles casing/renames across API versions)
    param($Object, [string[]]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    foreach ($n in $Name) {
        $p = $Object.PSObject.Properties[$n]
        # 0 and $false are real values (slot 0, enclosure 0); only $null and '' count as missing
        if ($p -and $null -ne $p.Value -and -not ($p.Value -is [string] -and $p.Value -eq '')) { return $p.Value }
    }
    $Default
}

function ConvertFrom-VhEpoch {
    # VxRail returns epoch time in milliseconds in most fields, seconds in a few
    param($Value)
    if (-not $Value) { return $null }
    $n = [double]$Value
    if ($n -gt 1e11) { $n = $n / 1000 }
    [DateTimeOffset]::FromUnixTimeSeconds([long]$n).UtcDateTime
}

function Invoke-VhVxRailApi {
    <#
        .SYNOPSIS
            GET a VxRail Manager API path. Returns $null on 404 so callers can fall back.
    #>
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$SkipCertificateCheck,
        [int]$TimeoutSec = 60
    )
    $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $headers = @{
        Accept        = 'application/json'
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    }
    $uri = "https://$Manager/rest/vxm$Path"
    $params = @{ Uri = $uri; Method = 'Get'; Headers = $headers; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }

    $restoreCallback = $false
    $oldCallback = $null
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if ($SkipCertificateCheck) { $params.SkipCertificateCheck = $true }
    }
    else {
        # Windows PowerShell 5.1: make sure TLS 1.2 is offered (additive, never enables TLS 1.0/1.1)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($SkipCertificateCheck) {
            $oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $restoreCallback = $true
        }
    }
    try {
        # Assign then emit: Windows PowerShell 5.1 writes a JSON array as one object,
        # emitting the variable enumerates it so callers always get individual items
        $resp = Invoke-RestMethod @params
        $resp
    }
    catch {
        $err = $_
        $status = Get-VhSafe { [int]$err.Exception.Response.StatusCode } 0
        if ($status -eq 404) {
            throw "VxRail API $Path on $Manager returned 404 (endpoint not found). The API may have changed in this VxRail release; run with -SaveInventory and compare with the VxRail API reference."
        }
        throw "VxRail API $Path on $Manager failed: $($err.Exception.Message)"
    }
    finally {
        if ($restoreCallback) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
    }
}

function Get-VhVxRailInventory {
    <#
        .SYNOPSIS
            Collects system, node, disk, NIC, boot device, PSU and firmware data
            from one VxRail Manager and flattens it for checks and the as-built report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][pscredential]$Credential,
        [string]$Cluster = '',
        [string]$vCenter = '',
        [switch]$SkipCertificateCheck,
        [switch]$IncludeIdrac,
        [switch]$KeepRaw
    )
    Set-StrictMode -Off   # API responses vary by VxRail release; fields are read with Get-VhProp
    $errors = [System.Collections.Generic.List[string]]::new()
    $call = {
        param($path)
        try { Invoke-VhVxRailApi -Manager $Manager -Path $path -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck }
        catch { $errors.Add($_.Exception.Message); $null }
    }

    Write-Verbose "[VxRail $Manager] system"
    $system = & $call '/v1/system'
    $clusterHosts = @(& $call '/v1/system/cluster-hosts')
    $hostsRaw = @(& $call '/v1/hosts')
    $chassisRaw = @(& $call '/v1/chassis')
    $callHome = & $call '/v1/callhome/info'

    $ipBySn = @{}; $ipByName = @{}
    foreach ($ch in $clusterHosts) {
        if (-not $ch) { continue }
        $set = Get-VhProp $ch 'ip_set'
        $o = [pscustomobject]@{
            Model        = [string](Get-VhProp $ch 'model', 'Model' '')
            ManagementIp = [string](Get-VhProp $set 'management_ip' '')
            VmotionIp    = [string](Get-VhProp $set 'vmotion_ip' '')
            VsanIp       = [string](Get-VhProp $set 'vsan_ip' '')
        }
        $sn = [string](Get-VhProp $ch 'serial_number', 'sn' '')
        if ($sn) { $ipBySn[$sn] = $o }
        $ipByName[[string](Get-VhProp $ch 'host_name', 'hostname' '')] = $o
    }

    # Chassis -> model / PSUs; match nodes via the chassis hosts[] list (handles multi-node chassis) or by sn
    $chassisOfHost = @{}
    $chassis = foreach ($c in $chassisRaw) {
        if (-not $c) { continue }
        $csn = [string](Get-VhProp $c 'sn' '')
        foreach ($hh in @(Get-VhProp $c 'hosts' @())) { if ($hh) { $chassisOfHost[[string](Get-VhProp $hh 'sn' '')] = $c } }
        if ($csn -and -not $chassisOfHost.ContainsKey($csn)) { $chassisOfHost[$csn] = $c }
        [pscustomobject]@{
            Manager = $Manager; Cluster = $Cluster; SerialNumber = $csn
            ServiceTag = [string](Get-VhProp $c 'service_tag' ''); Psnt = [string](Get-VhProp $c 'psnt' '')
            Model = [string](Get-VhProp $c 'model' ''); Generation = [string](Get-VhProp $c 'generation' '')
            Health = [string](Get-VhProp $c 'health' ''); Missing = [bool](Get-VhProp $c 'missing' $false)
            Nodes = @(Get-VhProp $c 'hosts' @()).Count
        }
    }

    $nodes = @(); $disks = @(); $nics = @(); $boot = @(); $psus = @(); $firmware = @()
    foreach ($h in $hostsRaw) {
        if (-not $h) { continue }
        $sn = [string](Get-VhProp $h 'sn' '')
        $name = [string](Get-VhProp $h 'hostname', 'name' '')
        $ips = if ($ipBySn.ContainsKey($sn)) { $ipBySn[$sn] } else { $ipByName[$name] }
        $ch = $chassisOfHost[$sn]
        $idrac = ''
        if ($IncludeIdrac -and $sn) {
            $net = & $call "/v1/hosts/$sn/idrac/network"
            $idrac = [string](Get-VhProp (Get-VhProp $net 'ip') 'ip_address' '')
        }
        $fw = Get-VhProp $h 'firmwareInfo', 'firmware_info'

        $nodes += [pscustomobject]@{
            Manager = $Manager; Cluster = $Cluster; Hostname = $name; SerialNumber = $sn
            Psnt = [string](Get-VhProp $h 'psnt' ''); Model = [string](Get-VhProp $ch 'model' (Get-VhProp $ips 'Model' ''))
            Slot = [string](Get-VhProp $h 'slot' ''); Health = [string](Get-VhProp $h 'health' '')
            OperationalStatus = [string](Get-VhProp $h 'operational_status' ''); PowerStatus = [string](Get-VhProp $h 'power_status' '')
            Missing = [bool](Get-VhProp $h 'missing' $false); TpmPresent = [bool](Get-VhProp $h 'tpm_present' $false)
            ManagementIp = [string](Get-VhProp $ips 'ManagementIp' ''); VmotionIp = [string](Get-VhProp $ips 'VmotionIp' '')
            VsanIp = [string](Get-VhProp $ips 'VsanIp' ''); IdracIp = $idrac
        }
        $firmware += [pscustomobject]@{
            Manager = $Manager; Cluster = $Cluster; Hostname = $name
            Bios = [string](Get-VhProp $fw 'bios_revision' ''); Idrac = [string](Get-VhProp $fw 'bmc_revision' '')
            Cpld = [string](Get-VhProp $fw 'cpld_version' ''); Hba = [string](Get-VhProp $fw 'hba_version' '')
            Boss = [string](Get-VhProp $fw 'boss_version' ''); Perc = [string](Get-VhProp $fw 'perc_version' '')
            BackplaneExpander = [string](Get-VhProp $fw 'expander_bpf_version' ''); BackplaneNonExpander = [string](Get-VhProp $fw 'nonexpander_bpf_version' '')
            Dcpm = [string](Get-VhProp $fw 'dcpm_version' '')
        }
        foreach ($d in @(Get-VhProp $h 'disks' @())) {
            if (-not $d) { continue }
            $disks += [pscustomobject]@{
                Manager = $Manager; Cluster = $Cluster; Hostname = $name
                Enclosure = [string](Get-VhProp $d 'enclosure' ''); Slot = [string](Get-VhProp $d 'slot' '')
                SerialNumber = [string](Get-VhProp $d 'sn' ''); Manufacturer = [string](Get-VhProp $d 'manufacturer' '')
                Model = [string](Get-VhProp $d 'model' ''); Firmware = [string](Get-VhProp $d 'firmware_revision' '')
                Type = [string](Get-VhProp $d 'disk_type' ''); Protocol = [string](Get-VhProp $d 'protocol' '')
                Capacity = [string](Get-VhProp $d 'capacity' ''); Speed = [string](Get-VhProp $d 'max_capable_speed' '')
                State = [string](Get-VhProp $d 'disk_state' ''); Missing = [bool](Get-VhProp $d 'missing' $false)
                WriteEndurance = [string](Get-VhProp $d 'remaining_write_endurance_rate', 'write_endurance' '')
                EnduranceStatus = [string](Get-VhProp $d 'write_endurance_status' '')
            }
        }
        foreach ($n in @(Get-VhProp $h 'nics' @())) {
            if (-not $n) { continue }
            $nics += [pscustomobject]@{
                Manager = $Manager; Cluster = $Cluster; Hostname = $name
                Slot = [string](Get-VhProp $n 'slot' ''); Mac = [string](Get-VhProp $n 'mac' '')
                LinkStatus = [string](Get-VhProp $n 'link_status' ''); LinkSpeed = [string](Get-VhProp $n 'link_speed' '')
                Firmware = [string](Get-VhProp $n 'firmware_family_version' '')
            }
        }
        foreach ($b in @(Get-VhProp $h 'boot_devices' @())) {
            if (-not $b) { continue }
            $boot += [pscustomobject]@{
                Manager = $Manager; Cluster = $Cluster; Hostname = $name
                Type = [string](Get-VhProp $b 'bootdevice_type' ''); Model = [string](Get-VhProp $b 'device_model' '')
                SerialNumber = [string](Get-VhProp $b 'sn' ''); Slot = [string](Get-VhProp $b 'slot' '')
                Capacity = [string](Get-VhProp $b 'capacity' ''); SataType = [string](Get-VhProp $b 'sata_type' '')
                Firmware = [string](Get-VhProp $b 'firmware_version' ''); Health = [string](Get-VhProp $b 'health' '')
                PowerOnHours = [string](Get-VhProp $b 'power_on_hours' '')
            }
        }
    }
    # PSUs are per chassis
    foreach ($c in $chassisRaw) {
        if (-not $c) { continue }
        foreach ($p in @(Get-VhProp $c 'power_supplies' @())) {
            if (-not $p) { continue }
            $psus += [pscustomobject]@{
                Manager = $Manager; Cluster = $Cluster; Chassis = [string](Get-VhProp $c 'service_tag', 'sn' '')
                Slot = [string](Get-VhProp $p 'slot' ''); Name = [string](Get-VhProp $p 'name' '')
                Manufacturer = [string](Get-VhProp $p 'manufacturer' ''); SerialNumber = [string](Get-VhProp $p 'sn' '')
                PartNumber = [string](Get-VhProp $p 'part_number' ''); Revision = [string](Get-VhProp $p 'revision_number' '')
                Health = [string](Get-VhProp $p 'health' ''); Missing = [bool](Get-VhProp $p 'missing' $false)
            }
        }
    }

    $components = foreach ($ic in @(Get-VhProp $system 'installed_components' @())) {
        if (-not $ic) { continue }
        [pscustomobject]@{
            Name = [string](Get-VhProp $ic 'name', 'component' ''); Description = [string](Get-VhProp $ic 'description' '')
            Version = [string](Get-VhProp $ic 'current_version' ''); Baseline = [string](Get-VhProp $ic 'baseline' '')
            BaselineDrifted = [bool](Get-VhProp $ic 'baseline_drifted' $false); Supported = Get-VhProp $ic 'supported' $null
            UpgradeStatus = [string](Get-VhProp $ic 'upgrade_status' '')
        }
    }

    [pscustomobject]@{
        Manager          = $Manager
        Cluster          = $Cluster
        vCenter          = $vCenter
        Reachable        = [bool]$system
        Version          = [string](Get-VhProp $system 'version' '')
        Health           = [string](Get-VhProp $system 'health' '')
        ClusterType      = [string](Get-VhProp $system 'cluster_type' '')
        NumberOfHosts    = [int](Get-VhProp $system 'number_of_host' 0)
        InstalledTime    = ConvertFrom-VhEpoch (Get-VhProp $system 'installed_time')
        NetworkConnected = Get-VhProp $system 'network_connected' $null
        VcConnected      = Get-VhProp $system 'vc_connected' $null
        ExternalVc       = Get-VhProp $system 'is_external_vc' $null
        UpgradeStatus    = [string](Get-VhProp $system 'upgrade_status' '')
        CallHomeStatus   = [string](Get-VhProp $callHome 'status' '')
        CallHomeSiteId   = [string](Get-VhProp $callHome 'site_id' '')
        Components       = @($components)
        Chassis          = @($chassis)
        Nodes            = @($nodes)
        Firmware         = @($firmware)
        Disks            = @($disks)
        Nics             = @($nics)
        BootDevices      = @($boot)
        PowerSupplies    = @($psus)
        Errors           = @($errors)
        Raw              = if ($KeepRaw) { [pscustomobject]@{ System = $system; ClusterHosts = $clusterHosts; Hosts = $hostsRaw; Chassis = $chassisRaw; CallHome = $callHome } } else { $null }
    }
}

function Get-VhVxRailTarget {
    <#
        .SYNOPSIS
            Resolves which VxRail Managers to query: explicit Settings.VxRail.Managers
            (cluster name -> address) override the vCenter 'VxRail-IP' attribute.
    #>
    param([Parameter(Mandatory)]$Inventory, [Parameter(Mandatory)][hashtable]$Settings)
    $map = @{}
    if ($Settings.VxRail -and $Settings.VxRail.Managers) { $map = $Settings.VxRail.Managers }
    $seen = @{}
    foreach ($c in $Inventory.Clusters) {
        $addr = if ($map.ContainsKey($c.Name)) { [string]$map[$c.Name] } else { [string]$c.VxRailManager }
        if (-not $addr -or $seen.ContainsKey($addr)) { continue }
        $seen[$addr] = $true
        [pscustomobject]@{ Manager = $addr; Cluster = $c.Name; vCenter = $c.vCenter }
    }
}
