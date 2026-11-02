@{
    # Settings used with samples\sample-inventory.json (fictional Contoso estate)
    Report = @{
        Title = 'vSphere Health Report'; Organization = 'Contoso Ltd - Infrastructure Engineering'
        OutputPath = '.\reports'; Formats = @('Html', 'Csv', 'Json'); OpenWhenDone = $false; KeepReports = 0; ShowPassed = $true
    }
    Connection = @{ Servers = @(); CredentialFile = ''; AllLinked = $false; InvalidCertificateAction = 'Warn' }
    Licensing = @{
        Model = 'VCF'; PurchasedCores = 1024; VsanAddOnTiB = 0
        UsageReportLastSubmitted = ''; UsageReportIntervalDays = 180; ExpiryWarningDays = 60
        MinCoresPerCpu = 16; VsanTiBPerCore = @{ VCF = 1.0; VVF = 0.25 }
    }
    Thresholds = @{
        SnapshotAgeDays = 3; SnapshotSizeGB = 50; DatastoreFreeWarnPct = 20; DatastoreFreeCritPct = 10
        DatastoreOverProvisionPct = 150; HostCpuWarnPct = 85; HostMemWarnPct = 90; VcpuToPcpuRatio = 4
        CertExpiryWarnDays = 60; CertExpiryCritDays = 14; SessionIdleHours = 24; MinVmHardwareVersion = 19; PortGroupFreePortsMin = 10
    }
    Exclusions = @{ VmNamePattern = '^vCLS'; DatastoreNamePattern = ''; SnapshotNamePattern = ''; HostNamePattern = '' }
    Lifecycle = @{ '6.5' = '2022-10-15'; '6.7' = '2022-10-15'; '7.0' = '2025-10-02'; '8.0' = '2027-10-11'; '9.0' = ''; WarnDaysBefore = 180 }
    Email = @{ Enabled = $false; SmtpServer = ''; Port = 587; UseSsl = $true; From = ''; To = @(); CredentialFile = ''; AttachFullReport = $true; OnlyWhenFindings = $false }
    DisabledChecks = @()
}
