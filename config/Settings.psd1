@{
    # ---------------------------------------------------------------------------
    # vSphere Health Report - settings
    # Copy this file (e.g. Settings.prod.psd1) and pass it with -ConfigPath.
    # ---------------------------------------------------------------------------

    Report = @{
        Title        = 'vSphere Health Report'
        Organization = 'Contoso IT'
        OutputPath   = '.\reports'
        Formats      = @('Html', 'Csv', 'Json')   # Html | Csv | Json
        OpenWhenDone = $false
        KeepReports  = 30                        # delete report folders older than N days (0 = keep all)
        ShowPassed   = $true                     # list passed checks at the end of the report
        # Health | AsBuilt | Both   (AsBuilt/Both collect full hardware and VxRail data - slower)
        Type         = 'Health'
    }

    AsBuilt = @{
        Title            = 'vSphere As-Built Report'
        PreparedBy       = 'Infrastructure Engineering'
        DocumentVersion  = '1.0'
        # esxcli adds NIC driver/firmware versions and BMC/iDRAC IP; slower and needs more than read-only [verify privileges]
        UseEsxcli        = $true
        IncludeVmInventory = $true
        # Write an .xlsx workbook when the ImportExcel module is installed (CSV files otherwise)
        Excel            = $true
    }

    VxRail = @{
        Enabled              = $true             # query VxRail Manager for clusters that have one
        # Override / add VxRail Managers: cluster name -> VxRail Manager FQDN or IP.
        # By default the vCenter cluster attribute 'VxRail-IP' is used.
        Managers             = @{}
        # PSCredential file for VxRail Manager (vCenter SSO account with a VxRail role). Empty = reuse vCenter credential.
        CredentialFile       = ''
        SkipCertificateCheck = $false            # only for self-signed VxRail Manager certificates
        IncludeIdrac         = $true             # one extra call per node for the iDRAC IP
        DiskEnduranceWarnPct = 20                # remaining SSD write endurance (%) warning threshold
    }

    Connection = @{
        Servers                = @('vcenter01.corp.local')
        # Path to a PSCredential exported with Export-Clixml (DPAPI-encrypted, per user/machine).
        # Leave empty to be prompted, or pass -Credential.
        CredentialFile         = ''
        AllLinked              = $false          # connect to every vCenter in the SSO (ELM) domain
        InvalidCertificateAction = 'Warn'        # Fail | Warn | Ignore  (session scope only)
    }

    Licensing = @{
        # VCF | VVF | vSphereStandard | vSphereEnterprisePlus | Perpetual
        Model                    = 'VCF'
        # Subscription cores purchased (0 = skip entitlement comparison)
        PurchasedCores           = 0
        # Extra vSAN add-on capacity purchased in TiB (on top of the per-core entitlement)
        VsanAddOnTiB             = 0
        # vSphere/VCF 9 only: date the last license usage file was uploaded to Broadcom
        # (yyyy-MM-dd). Disconnected mode requires an upload at least every 180 days.
        UsageReportLastSubmitted = ''
        UsageReportIntervalDays  = 180
        ExpiryWarningDays        = 60
        # Per-core entitlement rules [verify against your Broadcom contract]
        MinCoresPerCpu           = 16
        VsanTiBPerCore           = @{ VCF = 1.0; VVF = 0.25 }
    }

    Thresholds = @{
        SnapshotAgeDays           = 3
        SnapshotSizeGB            = 50
        DatastoreFreeWarnPct      = 20
        DatastoreFreeCritPct      = 10
        DatastoreOverProvisionPct = 150
        HostCpuWarnPct            = 85
        HostMemWarnPct            = 90
        VcpuToPcpuRatio           = 4
        CertExpiryWarnDays        = 60
        CertExpiryCritDays        = 14
        SessionIdleHours          = 24
        MinVmHardwareVersion      = 19            # vmx-19 = vSphere 7.0 U2
        PortGroupFreePortsMin     = 10
    }

    Exclusions = @{
        VmNamePattern        = '^(vCLS|VxRail Manager)'   # regex, '' = none
        DatastoreNamePattern = ''
        SnapshotNamePattern  = ''
        HostNamePattern      = ''
    }

    # End of general support dates used by the lifecycle check.
    # Source: Broadcom Product Lifecycle Matrix [verify - dates can change].
    Lifecycle = @{
        '6.5' = '2022-10-15'
        '6.7' = '2022-10-15'
        '7.0' = '2025-10-02'
        '8.0' = '2027-10-11'
        '9.0' = ''                                # not yet published / fill in from the matrix
        WarnDaysBefore = 180
    }

    Email = @{
        Enabled          = $false
        SmtpServer       = 'smtp.corp.local'
        Port             = 587
        UseSsl           = $true
        From             = 'vsphere-report@corp.local'
        To               = @('vmware-team@corp.local')
        CredentialFile   = ''                     # Export-Clixml PSCredential for SMTP auth
        AttachFullReport = $true
        OnlyWhenFindings = $false
    }

    # Check IDs to skip, e.g. @('VM-008','HST-012')
    DisabledChecks = @()
}
