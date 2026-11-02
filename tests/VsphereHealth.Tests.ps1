#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/VsphereHealth.psd1') -Force
    $settings = Import-VhSettings (Join-Path $root 'config/Settings.sample.psd1')
    $inventory = Import-VhInventoryJson (Join-Path $root 'samples/sample-inventory.json')
}

Describe 'Source files' {
    It '<_> parses without errors' -ForEach @(
        Get-ChildItem (Split-Path $PSScriptRoot -Parent) -Recurse -Include *.ps1, *.psm1, *.psd1 | Select-Object -ExpandProperty FullName
    ) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Per-core licensing math' {
    It 'counts <Sockets> x <Cores> cores as <Expected>' -ForEach @(
        @{ Sockets = 2; Cores = 12; Expected = 32 }   # 16-core minimum per CPU
        @{ Sockets = 2; Cores = 32; Expected = 64 }
        @{ Sockets = 1; Cores = 16; Expected = 16 }
        @{ Sockets = 4; Cores = 8; Expected = 64 }
    ) {
        Get-VhRequiredCore -Sockets $Sockets -CoresPerSocket $Cores | Should -Be $Expected
    }

    It 'rounds the VVF vSAN entitlement up to the next whole TiB' {
        $s = Import-VhSettings (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/Settings.sample.psd1')
        $s.Licensing.Model = 'VVF'; $s.Licensing.PurchasedCores = 10
        $inv = [pscustomobject]@{ vCenters = @([pscustomobject]@{ Version = '9.0.1' }); Hosts = @(); Datastores = @() }
        (Get-VhLicenseSummary -Inventory $inv -Settings $s).VsanIncludedTiB | Should -Be 3
    }

    It 'reports a core shortfall when purchased cores are too low' {
        $s = Import-VhSettings (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/Settings.sample.psd1')
        $s.Licensing.PurchasedCores = 100
        $r = Invoke-VhHealthCheck -Inventory $inventory -Settings $s | Where-Object Id -eq 'LIC-004'
        $r.Status | Should -Be 'Finding'
        $r.Rows[0].Shortfall | Should -BeGreaterThan 0
    }

    It 'treats vCenter 9 as license-file based' {
        $inv = [pscustomobject]@{ vCenters = @([pscustomobject]@{ Version = '9.0.1' }); Hosts = @(); Datastores = @() }
        $sum = Get-VhLicenseSummary -Inventory $inv -Settings $settings
        $sum.UsesLicenseFile | Should -BeTrue
        $sum.UsesLicenseKeys | Should -BeFalse
    }
}

Describe 'Health checks' {
    BeforeAll { $results = @(Invoke-VhHealthCheck -Inventory $inventory -Settings $settings) }

    It 'has unique check IDs' {
        $ids = (Get-VhHealthCheck).Id
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'runs every check against the sample without errors' {
        $results | Where-Object Status -eq 'Error' | ForEach-Object { "$($_.Id): $($_.Error)" } | Should -BeNullOrEmpty
    }

    It 'skips key-based license checks on a vSphere 9-only estate' {
        $inv9 = Import-VhInventoryJson (Join-Path (Split-Path $PSScriptRoot -Parent) 'samples/sample-inventory.json')
        $inv9.vCenters = @($inv9.vCenters | Where-Object { $_.Version -like '9.*' })
        $r = Invoke-VhHealthCheck -Inventory $inv9 -Settings $settings
        ($r | Where-Object Id -eq 'LIC-003').Status | Should -Be 'NotApplicable'
        ($r | Where-Object Id -eq 'LIC-006').Status | Should -Not -Be 'NotApplicable'
    }

    It 'flags an unsupported vCenter 7.0-only estate instead of skipping every check' {
        $inv7 = Import-VhInventoryJson (Join-Path (Split-Path $PSScriptRoot -Parent) 'samples/sample-inventory.json')
        $inv7.vCenters = @([pscustomobject]@{ Name = 'vc7'; Version = '7.0.3'; Build = '1' })
        $inv7.Hosts = @($inv7.Hosts | Where-Object { $_.Version -like '7.*' })
        $r = @(Invoke-VhHealthCheck -Inventory $inv7 -Settings $settings)
        ($r | Where-Object Id -eq 'LCM-001').Status | Should -Be 'Finding'
        ($r | Where-Object Id -eq 'LIC-003').Status | Should -Not -Be 'NotApplicable'
        @($r | Where-Object Status -eq 'NotApplicable').Count | Should -BeLessThan 3
        $module = Get-Module VsphereHealth
        (& $module { param($x) Get-VhHealthScore -Results $x } $r) | Should -BeLessThan 100
    }

    It 'excludes vCLS agent VMs by default' {
        $results | ForEach-Object { $_.Rows } | Where-Object { $_.PSObject.Properties['VM'] -and $_.VM -like 'vCLS*' } | Should -BeNullOrEmpty
    }

    It 'honours DisabledChecks' {
        $s = Import-VhSettings (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/Settings.sample.psd1')
        $s.DisabledChecks = @('VM-012')
        (Invoke-VhHealthCheck -Inventory $inventory -Settings $s | Where-Object Id -eq 'VM-012').Status | Should -Be 'Skipped'
    }
}

Describe 'HTML report' {
    It 'renders a complete, self-contained document' {
        $results = @(Invoke-VhHealthCheck -Inventory $inventory -Settings $settings)
        $html = ConvertTo-VhHtmlReport -Results $results -Inventory $inventory -Settings $settings
        $html | Should -Match '^<!DOCTYPE html>'
        $html | Should -Match '</html>$'
        $html | Should -Not -Match '<link |src="http'
    }

    It 'HTML-encodes inventory values' {
        $inv = Import-VhInventoryJson (Join-Path (Split-Path $PSScriptRoot -Parent) 'samples/sample-inventory.json')
        $inv.Vms[0].Name = '<img src=x onerror=alert(1)>'
        $inv.Vms[0].ConsolidationNeeded = $true
        $results = @(Invoke-VhHealthCheck -Inventory $inv -Settings $settings)
        $html = ConvertTo-VhHtmlReport -Results $results -Inventory $inv -Settings $settings
        $html | Should -Not -Match '<img src=x'
        $html | Should -Match '&lt;img src=x'
    }
}
