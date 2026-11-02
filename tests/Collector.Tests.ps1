#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Live vCenter data is full of nulls (disconnected hosts, inaccessible VMs, clusters with no
# config). These tests run the real collector against mocked PowerCLI output shaped that way.

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/VsphereHealth.psd1') -Force
    $settings = Import-VhSettings (Join-Path $root 'config/Settings.sample.psd1')

    # PowerCLI isn't needed for the tests: stub the cmdlets the collector calls so Pester can mock them
    if (-not (Get-Command Get-View -ErrorAction SilentlyContinue)) {
        function global:Get-View { param([Parameter(Position = 0)]$VIObject, $Server, $ViewType, $Property) }
    }
    if (-not (Get-Command Get-VMHostProfile -ErrorAction SilentlyContinue)) {
        function global:Get-VMHostProfile { param($Server) }
    }
}

AfterAll {
    Remove-Item function:\Get-View, function:\Get-VMHostProfile -ErrorAction SilentlyContinue
}

Describe 'Get-VhInventory with null-heavy live data' {
    BeforeAll {
        Mock -ModuleName VsphereHealth Get-VMHostProfile { }
        Mock -ModuleName VsphereHealth Get-View {
            if ($VIObject -eq 'ServiceInstance') {
                return [pscustomobject]@{ Content = [pscustomobject]@{
                        About = [pscustomobject]@{ Version = '8.0.3'; Build = '1'; ApiVersion = '8.0.3.0'; FullName = 'vCenter'; InstanceUuid = 'x' }
                        CustomFieldsManager = 'cfm'; RootFolder = 'root'; SessionManager = 'sm'; LicenseManager = $null
                    }
                }
            }
            switch ($ViewType) {
                'ClusterComputeResource' { [pscustomobject]@{ MoRef = 'cl-1'; Name = 'CL1'; Parent = 'folder-1'; ConfigurationEx = $null; Summary = $null; Host = $null; LifecycleManaged = $null; CustomValue = $null } }
                'HostSystem' {
                    [pscustomobject]@{ MoRef = 'host-1'; Name = 'esx-ok'; Parent = 'cl-1'; OverallStatus = 'green'; ConfigIssue = $null; Capability = $null; ConfigManager = $null
                        Runtime = [pscustomobject]@{ ConnectionState = 'connected'; PowerState = 'poweredOn'; InMaintenanceMode = $false }
                        Summary = $null; Hardware = $null; Config = $null }
                    [pscustomobject]@{ MoRef = 'host-2'; Name = 'esx-down'; Parent = 'cl-1'; OverallStatus = 'gray'; ConfigIssue = $null; Capability = $null; ConfigManager = $null
                        Runtime = [pscustomobject]@{ ConnectionState = 'notResponding'; PowerState = 'unknown'; InMaintenanceMode = $false }
                        Summary = $null; Hardware = $null; Config = $null }
                }
                'Datastore' { [pscustomobject]@{ MoRef = 'ds-1'; Name = 'DS1'; Summary = $null; Host = $null; Vm = $null; OverallStatus = 'gray' } }
                'VirtualMachine' {
                    [pscustomobject]@{ MoRef = 'vm-1'; Name = 'vm-inaccessible'; Snapshot = $null; Guest = $null; Summary = $null; Config = $null
                        Runtime = [pscustomobject]@{ PowerState = 'poweredOff'; ConnectionState = 'inaccessible'; Host = 'host-2'; ConsolidationNeeded = $false } }
                }
                default { $null }
            }
        }
    }

    It 'returns exactly one inventory object when a guarded call fails (no leaked $null)' {
        # Host Profiles lookup failing (licensing/privilege) used to leak $null into the output
        Mock -ModuleName VsphereHealth Get-VMHostProfile { throw 'Host profiles not available' }
        $out = @(Get-VhInventory -Server ([pscustomobject]@{ Name = 'vc-test' }) -WarningAction SilentlyContinue)
        $out.Count | Should -Be 1
        $out[0].PSObject.Properties['vCenters'] | Should -Not -BeNullOrEmpty
        { Merge-VhInventory -Inventory @($null, $out[0]) } | Should -Not -Throw
    }

    It 'returns an inventory instead of nothing' {
        $inv = Get-VhInventory -Server ([pscustomobject]@{ Name = 'vc-test' }) -WarningAction SilentlyContinue
        $inv | Should -Not -BeNullOrEmpty
        @($inv.Hosts).Count | Should -Be 2
        @($inv.Vms).Count | Should -Be 1
        @($inv.Clusters).Count | Should -Be 1
        ($inv.Hosts | Where-Object Name -eq 'esx-down').ConnectionState | Should -Be 'notResponding'
        ($inv.Vms[0]).Cluster | Should -Be 'CL1'
    }

    It 'still collects hardware mode without errors' {
        $inv = Get-VhInventory -Server ([pscustomobject]@{ Name = 'vc-test' }) -IncludeHardware -WarningAction SilentlyContinue
        @($inv.Hosts).Count | Should -Be 2
        $inv.Hosts[0].Hardware | Should -Not -BeNullOrEmpty
    }

    It 'produces a report from that inventory' {
        $inv = Merge-VhInventory -Inventory @(Get-VhInventory -Server ([pscustomobject]@{ Name = 'vc-test' }) -WarningAction SilentlyContinue)
        $r = @(Invoke-VhHealthCheck -Inventory $inv -Settings $settings)
        $r | Where-Object Status -eq 'Error' | ForEach-Object { "$($_.Id): $($_.Error)" } | Should -BeNullOrEmpty
        ($r | Where-Object Id -eq 'HST-001').Status | Should -Be 'Finding'
        ConvertTo-VhHtmlReport -Results $r -Inventory $inv -Settings $settings | Should -Match '</html>$'
    }
}
