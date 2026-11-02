function Import-VhPowerCLI {
    # VCF.PowerCLI (9.x) and VMware.PowerCLI (13.x) both ship VMware.VimAutomation.Core.
    if (Get-Module -Name VMware.VimAutomation.Core) { return }
    if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
        throw "PowerCLI not found. Install it with: Install-Module VCF.PowerCLI -Scope CurrentUser"
    }
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
}

function Connect-VhServer {
    <#
        .SYNOPSIS
            Connects to one or more vCenter Servers for read-only collection.
        .NOTES
            A read-only vCenter role is sufficient for everything except the
            session list (Sessions.TerminateSession) and host certificate info.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Server,
        [pscredential]$Credential,
        [string]$CredentialFile,
        [switch]$AllLinked,
        [ValidateSet('Fail', 'Warn', 'Ignore')][string]$InvalidCertificateAction = 'Warn'
    )
    Import-VhPowerCLI

    # Session scope only - never changes the user's persistent PowerCLI config
    $null = Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction $InvalidCertificateAction `
        -ParticipateInCeip $false -DefaultVIServerMode Multiple -Confirm:$false

    if (-not $Credential -and $CredentialFile) {
        if (-not (Test-Path $CredentialFile)) { throw "Credential file not found: $CredentialFile" }
        $Credential = Import-Clixml -Path $CredentialFile
    }
    if (-not $Credential) { $Credential = Get-Credential -Message 'vCenter credentials' }

    $connected = foreach ($s in $Server) {
        $params = @{ Server = $s; Credential = $Credential; ErrorAction = 'Stop' }
        if ($AllLinked) { $params.AllLinked = $true }
        Write-Verbose "Connecting to $s"
        Connect-VIServer @params
    }
    $connected | Sort-Object Name -Unique
}

function Disconnect-VhServer {
    param([Parameter(Mandatory)][object[]]$Server)
    foreach ($s in $Server) {
        try { Disconnect-VIServer -Server $s -Force -Confirm:$false -ErrorAction Stop } catch { Write-Verbose $_ }
    }
}
