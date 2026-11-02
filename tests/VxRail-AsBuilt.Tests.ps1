#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/VsphereHealth.psd1') -Force
    $settings = Import-VhSettings (Join-Path $root 'config/Settings.sample.psd1')
    $samplePath = Join-Path $root 'samples/sample-inventory.json'
    $inventory = Import-VhInventoryJson $samplePath
    $cred = [pscredential]::new('administrator@vsphere.local', (ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force))
}

Describe 'VxRail Manager client' {
    BeforeAll {
        # Minimal responses shaped like Dell's published VxRail API schema
        Mock -ModuleName VsphereHealth Invoke-RestMethod {
            switch -Wildcard ($Uri) {
                '*/v1/system' { [pscustomobject]@{ version = '8.0.320-1'; health = 'Healthy'; cluster_type = 'STANDARD'; number_of_host = 1; installed_time = 1700000000000; installed_components = @([pscustomobject]@{ name = 'iDRAC'; current_version = '7.10'; baseline_drifted = $true }) } }
                '*/v1/system/cluster-hosts' { @([pscustomobject]@{ host_name = 'esx01'; serial_number = 'ABC1234'; ip_set = [pscustomobject]@{ management_ip = '10.0.0.11'; vsan_ip = '10.0.2.11' } }) }
                '*/v1/hosts' {
                    @([pscustomobject]@{
                            sn = 'ABC1234'; hostname = 'esx01'; psnt = 'PSNT1'; health = 'Healthy'; power_status = 'on'
                            firmwareInfo = [pscustomobject]@{ bios_revision = '2.3.5'; bmc_revision = '7.10' }
                            disks = @([pscustomobject]@{ slot = 1; sn = 'D1'; disk_state = 'Failed'; model = 'NVMe' })
                            nics = @([pscustomobject]@{ slot = 1; mac = 'aa'; link_status = 'Up' })
                            # boot_devices intentionally missing
                        })
                }
                '*/v1/chassis' { @([pscustomobject]@{ sn = 'ABC1234'; model = 'VxRail VE-660'; hosts = @([pscustomobject]@{ sn = 'ABC1234' }); power_supplies = @([pscustomobject]@{ slot = 1; health = 'Critical' }) }) }
                '*/v1/callhome/info' { throw 'connection refused' }
                default { $null }
            }
        }
    }

    It 'calls /rest/vxm with Basic auth and maps nodes, firmware, disks and PSUs' {
        $v = Get-VhVxRailInventory -Manager 'vxm.test' -Credential $cred -Cluster 'C1'
        Should -Invoke -ModuleName VsphereHealth Invoke-RestMethod -ParameterFilter {
            $Uri -eq 'https://vxm.test/rest/vxm/v1/system' -and $Headers.Authorization -like 'Basic *'
        } -Times 1 -Exactly
        $v.Reachable | Should -BeTrue
        $v.Version | Should -Be '8.0.320-1'
        $v.InstalledTime.Year | Should -Be 2023            # epoch milliseconds handled
        $v.Nodes[0].Model | Should -Be 'VxRail VE-660'     # chassis matched via hosts[]
        $v.Nodes[0].ManagementIp | Should -Be '10.0.0.11'
        $v.Firmware[0].Idrac | Should -Be '7.10'
        $v.Disks[0].State | Should -Be 'Failed'
        @($v.BootDevices).Count | Should -Be 0             # missing fields are tolerated
        $v.PowerSupplies[0].Health | Should -Be 'Critical'
    }

    It 'records endpoint failures instead of aborting the collection' {
        $v = Get-VhVxRailInventory -Manager 'vxm.test' -Credential $cred
        @($v.Errors).Count | Should -Be 1
        $v.Errors[0] | Should -Match 'callhome'
    }

    It 'enumerates arrays that Windows PowerShell 5.1 emits as a single object' {
        Mock -ModuleName VsphereHealth Invoke-RestMethod {
            if ($Uri -like '*/v1/hosts') { Write-Output -NoEnumerate @([pscustomobject]@{ sn = 'A'; hostname = 'h1' }, [pscustomobject]@{ sn = 'B'; hostname = 'h2' }) }
            elseif ($Uri -like '*/v1/system') { [pscustomobject]@{ version = '8.0'; health = 'Healthy'; number_of_host = 2 } }
        }
        $v = Get-VhVxRailInventory -Manager 'vxm.test' -Credential $cred
        @($v.Nodes).Count | Should -Be 2
        $v.Nodes.Hostname | Should -Be @('h1', 'h2')
    }

    It 'keeps numeric zero values such as slot 0' {
        Mock -ModuleName VsphereHealth Invoke-RestMethod {
            if ($Uri -like '*/v1/hosts') { @([pscustomobject]@{ sn = 'A'; hostname = 'h1'; disks = @([pscustomobject]@{ enclosure = 0; slot = 0; disk_state = 'OK' }) }) }
            elseif ($Uri -like '*/v1/system') { [pscustomobject]@{ version = '8.0'; health = 'Healthy'; number_of_host = 1 } }
        }
        $v = Get-VhVxRailInventory -Manager 'vxm.test' -Credential $cred
        $v.Disks[0].Slot | Should -Be '0'
        $v.Disks[0].Enclosure | Should -Be '0'
    }

    It 'flags a reachable VxRail Manager that returns no node data' {
        Mock -ModuleName VsphereHealth Invoke-RestMethod {
            if ($Uri -like '*/v1/system') { [pscustomobject]@{ version = '8.0'; health = 'Healthy'; number_of_host = 4 } }
            else { $null }
        }
        $v = Get-VhVxRailInventory -Manager 'vxm.test' -Credential $cred -Cluster 'C1'
        $inv = Import-VhInventoryJson $samplePath
        $inv.VxRail = @($v)
        $r = Invoke-VhHealthCheck -Inventory $inv -Settings $settings | Where-Object Id -eq 'VXR-001'
        $r.Status | Should -Be 'Finding'
        $r.Severity | Should -Be 'Warning'
        $r.Rows[0].NodesReturned | Should -Be 0
        ($inv.VxRail | ForEach-Object Nodes) | Should -BeNullOrEmpty
        ((Invoke-VhHealthCheck -Inventory $inv -Settings $settings) | Where-Object Id -eq 'VXR-003').Status | Should -Be 'Pass'
    }

    It 'prefers Settings.VxRail.Managers over the VxRail-IP attribute' {
        $s = Import-VhSettings (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/Settings.sample.psd1')
        $s.VxRail.Managers = @{ 'DR-VxRail-01' = 'override.corp.local' }
        (Get-VhVxRailTarget -Inventory $inventory -Settings $s).Manager | Should -Be 'override.corp.local'
    }
}

Describe 'Hardware and VxRail checks' {
    BeforeAll { $results = @(Invoke-VhHealthCheck -Inventory $inventory -Settings $settings) }

    It 'detects BIOS, iDRAC and NIC firmware drift' {
        $rows = ($results | Where-Object Id -eq 'HW-001').Rows
        $rows.Component | Should -Contain 'BIOS'
        $rows.Component | Should -Contain 'iDRAC'
        ($rows.Component -like 'NIC firmware*') | Should -Not -BeNullOrEmpty
    }

    It 'flags the failed VxRail disk as critical' {
        $r = $results | Where-Object Id -eq 'VXR-004'
        $r.Severity | Should -Be 'Critical'
        ($r.Rows | Where-Object State -eq 'Failed') | Should -Not -BeNullOrEmpty
    }

    It 'gives VxRail clusters VxRail-specific lifecycle advice' {
        $row = ($results | Where-Object Id -eq 'LCM-002').Rows | Where-Object Cluster -eq 'PROD-Compute-02'
        $row.ManagedBy | Should -Be 'vLCM'
        $isVxr = $inventory.Clusters | Where-Object IsVxRail
        $isVxr.Name | Should -Be 'DR-VxRail-01'
    }

    It 'passes hardware/VxRail checks cleanly on a health-only inventory (v1.0 JSON)' {
        $inv = Import-VhInventoryJson $samplePath
        foreach ($h in $inv.Hosts) { $h.PSObject.Properties.Remove('Hardware') }
        foreach ($c in $inv.Clusters) { $c.PSObject.Properties.Remove('IsVxRail') }
        $inv.VxRail = @()
        $r = @(Invoke-VhHealthCheck -Inventory $inv -Settings $settings)
        $r | Where-Object Status -eq 'Error' | ForEach-Object { "$($_.Id): $($_.Error)" } | Should -BeNullOrEmpty
        ($r | Where-Object { $_.Id -like 'HW-*' -or $_.Id -like 'VXR-*' }).Status | Select-Object -Unique | Should -Be 'Pass'
    }
}

Describe 'As-built output' {
    It 'renders the document with VxRail and host detail sections' {
        $html = ConvertTo-VhAsBuiltHtml -Inventory $inventory -Settings $settings
        $html | Should -Match '^<!DOCTYPE html>'
        $html | Should -Match 'id="vxrail"'
        $html | Should -Match 'id="hostdetail"'
        $html | Should -Not -Match 'src="http'
    }

    It 'HTML-encodes hardware strings' {
        $inv = Import-VhInventoryJson $samplePath
        $inv.Hosts[0].Hardware.SerialNumber = '<script>x</script>'
        (ConvertTo-VhAsBuiltHtml -Inventory $inv -Settings $settings) | Should -Not -Match '<script>x</script>'
    }

    It 'falls back to CSV when Excel output is off' {
        $s = Import-VhSettings (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/Settings.sample.psd1')
        $s.AsBuilt.Excel = $false
        $dir = Join-Path $TestDrive 'ab'
        $null = New-Item -ItemType Directory $dir
        $out = Export-VhAsBuiltWorkbook -Inventory $inventory -Settings $s -Folder $dir
        (Get-ChildItem $out -Filter *.csv).Name | Should -Contain 'VxRail-Firmware.csv'
    }
}
