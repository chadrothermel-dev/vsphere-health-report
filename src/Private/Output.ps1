function Export-VhReport {
    <#
        .SYNOPSIS
            Writes HTML, CSV and/or JSON output into a timestamped folder and
            returns the paths written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$OutputPath,
        [timespan]$Duration = [timespan]::Zero,
        [string]$ToolVersion = '1.0.0'
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $OutputPath "vSphereHealth-$stamp"
    $null = New-Item -ItemType Directory -Path $dir -Force
    $formats = @($Settings.Report.Formats)
    $out = [ordered]@{ Folder = $dir }

    if ('Html' -in $formats) {
        $path = Join-Path $dir 'vSphereHealthReport.html'
        ConvertTo-VhHtmlReport -Results $Results -Inventory $Inventory -Settings $Settings -Duration $Duration -ToolVersion $ToolVersion |
            Set-Content -Path $path -Encoding UTF8
        $out.Html = $path
    }
    if ('Csv' -in $formats) {
        $csvDir = Join-Path $dir 'csv'
        $null = New-Item -ItemType Directory -Path $csvDir -Force
        $Results | Select-Object Id, Category, Title, Status, Severity, @{ n = 'Items'; e = { @($_.Rows).Count } }, Remediation, Error |
            Export-Csv -Path (Join-Path $csvDir '_summary.csv') -NoTypeInformation -Encoding UTF8
        foreach ($r in ($Results | Where-Object { $_.Status -eq 'Finding' })) {
            $r.Rows | Export-Csv -Path (Join-Path $csvDir "$($r.Id).csv") -NoTypeInformation -Encoding UTF8
        }
        $out.Csv = $csvDir
    }
    if ('Json' -in $formats) {
        $path = Join-Path $dir 'results.json'
        [pscustomobject]@{
            GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
            ToolVersion = $ToolVersion
            Score       = Get-VhHealthScore -Results $Results
            License     = Get-VhLicenseSummary -Inventory $Inventory -Settings $Settings
            vCenters    = $Inventory.vCenters
            Results     = $Results | Select-Object Id, Category, Title, Status, Severity, Description, Remediation, Error, DurationMs, Rows
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
        $out.Json = $path
    }

    $keep = [int]$Settings.Report.KeepReports
    if ($keep -gt 0) {
        Get-ChildItem -Path $OutputPath -Directory -Filter 'vSphereHealth-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$keep) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]$out
}

function Send-VhReport {
    <#
        .SYNOPSIS
            Emails an inline-styled summary with the full HTML report attached.
        .NOTES
            Uses Send-MailMessage for portability. It is marked obsolete by Microsoft
            but still ships in PowerShell 7; swap in MailKit or Microsoft Graph if your
            mail platform requires modern auth.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][hashtable]$Settings,
        [string]$HtmlPath
    )
    $e = $Settings.Email
    $crit = @($Results | Where-Object { $_.Status -eq 'Finding' -and $_.Severity -eq 'Critical' }).Count
    $warn = @($Results | Where-Object { $_.Status -eq 'Finding' -and $_.Severity -eq 'Warning' }).Count
    if ($e.OnlyWhenFindings -and ($crit + $warn) -eq 0) { Write-Verbose 'No findings; email skipped.'; return }

    $params = @{
        SmtpServer = $e.SmtpServer; Port = [int]$e.Port; UseSsl = [bool]$e.UseSsl
        From = $e.From; To = @($e.To)
        Subject = "$($Settings.Report.Title): $crit critical, $warn warning ($(Get-Date -Format 'yyyy-MM-dd'))"
        Body = ConvertTo-VhEmailSummary -Results $Results -Settings $Settings
        BodyAsHtml = $true; Encoding = [Text.Encoding]::UTF8; WarningAction = 'SilentlyContinue'
    }
    if ($e.CredentialFile) { $params.Credential = Import-Clixml -Path $e.CredentialFile }
    if ($e.AttachFullReport -and $HtmlPath) { $params.Attachments = $HtmlPath }
    Send-MailMessage @params
}
