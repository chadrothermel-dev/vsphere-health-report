function ConvertTo-VhHtmlText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $(if ($Value) { 'Yes' } else { 'No' }) }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm') }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { $Value = ($Value | ForEach-Object { [string]$_ }) -join ', ' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-VhSeverityClass { param([string]$Severity) switch ($Severity) { 'Critical' { 'crit' } 'Warning' { 'warn' } 'Info' { 'info' } 'Error' { 'err' } default { 'pass' } } }

function Get-VhCss {
@'
:root{--bg:#f4f6f9;--panel:#fff;--ink:#1d2533;--muted:#5b6578;--line:#e2e6ed;--brand:#0b2545;--brand2:#13315c;--accent:#1f6feb;
--crit:#c62828;--crit-bg:#fdecea;--warn:#b26a00;--warn-bg:#fff4e0;--info:#1565c0;--info-bg:#e8f1fd;--pass:#2e7d32;--pass-bg:#e8f5e9;--err:#6a1b9a;--err-bg:#f3e5f5;--row:#f8fafc}
@media (prefers-color-scheme:dark){:root{--bg:#0f141b;--panel:#171e28;--ink:#e6eaf0;--muted:#98a2b3;--line:#2a3442;--brand:#0a1a30;--brand2:#102542;--accent:#58a6ff;
--crit:#ff6b6b;--crit-bg:#3a1a1a;--warn:#f0b04c;--warn-bg:#3a2c12;--info:#6cb4ff;--info-bg:#132a44;--pass:#6fcf75;--pass-bg:#16301a;--err:#c792ea;--err-bg:#2c1a3a;--row:#1b2330}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 "Segoe UI",-apple-system,BlinkMacSystemFont,Roboto,"Helvetica Neue",Arial,sans-serif}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.wrap{max-width:1280px;margin:0 auto;padding:0 24px}
header.top{background:linear-gradient(135deg,var(--brand),var(--brand2));color:#fff;padding:28px 0 24px}
header.top .org{font-size:12px;letter-spacing:.12em;text-transform:uppercase;opacity:.75}
header.top h1{margin:4px 0 6px;font-size:28px;font-weight:600;letter-spacing:-.01em}
header.top .meta{font-size:13px;opacity:.85;display:flex;flex-wrap:wrap;gap:6px 18px}
.chips{margin-top:12px;display:flex;flex-wrap:wrap;gap:8px}
.chip{background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.2);border-radius:999px;padding:3px 12px;font-size:12px}
main{padding:24px 0 48px}
.grid{display:grid;gap:16px}
.g-top{grid-template-columns:280px 1fr}
.g-tiles{grid-template-columns:repeat(4,1fr)}
.g-kpi{grid-template-columns:repeat(auto-fit,minmax(150px,1fr))}
.g-2{grid-template-columns:1fr 1fr}
@media (max-width:900px){.g-top,.g-2{grid-template-columns:1fr}.g-tiles{grid-template-columns:repeat(2,1fr)}.wrap{padding:0 16px}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:18px 20px}
.card h2{margin:0 0 12px;font-size:15px;font-weight:600}
.card h2 small{font-weight:400;color:var(--muted);margin-left:6px}
.score{display:flex;align-items:center;gap:18px}
.score .lbl{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
.score .grade{font-size:30px;font-weight:700}
.score .sub{color:var(--muted);font-size:13px}
.tile{border-radius:10px;padding:14px 16px;border:1px solid var(--line);background:var(--panel)}
.tile .n{font-size:30px;font-weight:700;line-height:1.1}
.tile .t{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.tile.crit{border-left:5px solid var(--crit)}.tile.crit .n{color:var(--crit)}
.tile.warn{border-left:5px solid var(--warn)}.tile.warn .n{color:var(--warn)}
.tile.info{border-left:5px solid var(--info)}.tile.info .n{color:var(--info)}
.tile.pass{border-left:5px solid var(--pass)}.tile.pass .n{color:var(--pass)}
.kpi .v{font-size:22px;font-weight:600}.kpi .k{font-size:12px;color:var(--muted)}
.bar{height:8px;background:var(--line);border-radius:6px;overflow:hidden;margin:6px 0 2px}
.bar>span{display:block;height:100%;background:var(--accent)}
.bar.over>span{background:var(--crit)}
dl.kv{display:grid;grid-template-columns:auto 1fr;gap:6px 16px;margin:0}
dl.kv dt{color:var(--muted)}dl.kv dd{margin:0;font-weight:500}
.pill{display:inline-block;border-radius:999px;padding:1px 10px;font-size:11px;font-weight:600;letter-spacing:.03em;text-transform:uppercase;white-space:nowrap}
.pill.crit{background:var(--crit-bg);color:var(--crit)}.pill.warn{background:var(--warn-bg);color:var(--warn)}
.pill.info{background:var(--info-bg);color:var(--info)}.pill.pass{background:var(--pass-bg);color:var(--pass)}.pill.err{background:var(--err-bg);color:var(--err)}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);font-weight:600;background:var(--row);position:sticky;top:0}
th.sortable{cursor:pointer;user-select:none}th.sortable:after{content:" \2195";opacity:.35}
tbody tr:hover{background:var(--row)}
td.num{text-align:right;font-variant-numeric:tabular-nums}
.tbl{max-height:520px;overflow:auto;border:1px solid var(--line);border-radius:8px}
.toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:28px 0 12px}
.toolbar h2{margin:0 auto 0 0;font-size:18px}
.btn{border:1px solid var(--line);background:var(--panel);color:var(--ink);padding:6px 12px;border-radius:6px;cursor:pointer;font:inherit;font-size:13px}
.btn:hover{border-color:var(--accent)}
input.filter{border:1px solid var(--line);background:var(--panel);color:var(--ink);padding:6px 10px;border-radius:6px;font:inherit;font-size:13px;min-width:220px}
section.cat{margin-top:22px}
section.cat>h3{font-size:13px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);margin:0 0 8px;padding-bottom:6px;border-bottom:2px solid var(--line)}
details.check{background:var(--panel);border:1px solid var(--line);border-radius:10px;margin:0 0 10px;overflow:hidden}
details.check>summary{list-style:none;cursor:pointer;padding:12px 16px;display:flex;gap:12px;align-items:center}
details.check>summary::-webkit-details-marker{display:none}
details.check>summary:before{content:"\25B8";color:var(--muted);transition:transform .15s}
details.check[open]>summary:before{transform:rotate(90deg)}
details.check>summary .id{font-family:Consolas,"SFMono-Regular",Menlo,monospace;font-size:12px;color:var(--muted);min-width:64px}
details.check>summary .title{font-weight:600;flex:1}
details.check>summary .count{color:var(--muted);font-size:12px;white-space:nowrap}
details.check.crit{border-left:4px solid var(--crit)}details.check.warn{border-left:4px solid var(--warn)}
details.check.info{border-left:4px solid var(--info)}details.check.err{border-left:4px solid var(--err)}
.body{padding:0 16px 16px}
.desc{color:var(--muted);margin:0 0 10px}
.fix{background:var(--row);border:1px solid var(--line);border-radius:8px;padding:8px 12px;margin:0 0 12px;font-size:13px}
.fix b{color:var(--ink)}
.fix code,.desc code{font-family:Consolas,Menlo,monospace;font-size:12px}
.passed{columns:2;column-gap:24px;margin:0;padding:0;list-style:none}
.passed li{break-inside:avoid;padding:4px 0;border-bottom:1px dashed var(--line);font-size:13px}
.passed .id{font-family:Consolas,Menlo,monospace;color:var(--muted);font-size:12px;margin-right:8px}
@media (max-width:700px){.passed{columns:1}}
.top-list{margin:0;padding:0;list-style:none}
.top-list li{display:flex;gap:10px;align-items:center;padding:7px 0;border-bottom:1px solid var(--line)}
.top-list li:last-child{border-bottom:0}
.top-list .c{margin-left:auto;color:var(--muted);font-size:12px;white-space:nowrap}
footer{color:var(--muted);font-size:12px;border-top:1px solid var(--line);padding:16px 0 32px}
.note{font-size:12px;color:var(--muted);margin-top:10px}
@media print{body{background:#fff}.toolbar .btn,input.filter{display:none}details.check{break-inside:avoid}.tbl{max-height:none;overflow:visible}header.top{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
'@
}

function Get-VhScript {
@'
(function(){
  function cellVal(td){var t=td.getAttribute('data-v');if(t===null)t=td.textContent.trim();var n=parseFloat(t.replace(/[, ]/g,''));return isNaN(n)||!/^-?[\d.,\s]+%?$/.test(t)?t.toLowerCase():n;}
  document.querySelectorAll('table.data').forEach(function(tbl){
    tbl.querySelectorAll('th').forEach(function(th,i){
      th.classList.add('sortable');
      th.addEventListener('click',function(){
        var tb=tbl.tBodies[0],rows=[].slice.call(tb.rows),asc=th.getAttribute('data-dir')!=='asc';
        tbl.querySelectorAll('th').forEach(function(h){h.removeAttribute('data-dir');});
        th.setAttribute('data-dir',asc?'asc':'desc');
        rows.sort(function(a,b){var x=cellVal(a.cells[i]),y=cellVal(b.cells[i]);return (x>y?1:x<y?-1:0)*(asc?1:-1);});
        rows.forEach(function(r){tb.appendChild(r);});
      });
    });
  });
  var f=document.getElementById('filter');
  if(f){f.addEventListener('input',function(){
    var q=f.value.toLowerCase();
    document.querySelectorAll('details.check').forEach(function(d){
      var hit=!q||d.textContent.toLowerCase().indexOf(q)>=0;d.style.display=hit?'':'none';
      if(q&&hit){d.open=true;d.querySelectorAll('tbody tr').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>=0||d.querySelector('summary').textContent.toLowerCase().indexOf(q)>=0?'':'none';});}
      else d.querySelectorAll('tbody tr').forEach(function(r){r.style.display='';});
    });
  });}
  var ex=document.getElementById('expand'),co=document.getElementById('collapse');
  if(ex)ex.onclick=function(){document.querySelectorAll('details.check').forEach(function(d){d.open=true;});};
  if(co)co.onclick=function(){document.querySelectorAll('details.check').forEach(function(d){d.open=false;});};
  window.addEventListener('beforeprint',function(){document.querySelectorAll('details.check').forEach(function(d){d.open=true;});});
})();
'@
}

function ConvertTo-VhHtmlTable {
    param([object[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return '' }
    $cols = @($Rows[0].PSObject.Properties.Name)
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('<div class="tbl"><table class="data"><thead><tr>')
    foreach ($c in $cols) {
        # PascalCase -> words (EndOfGeneralSupport -> End Of General Support). A single leading
        # lowercase letter is a product prefix (vCenter, vCPU, vSAN, iDRAC), so it is not split off.
        $label = $c -creplace '(?<=[a-z])(?<!^[a-z])(?=[A-Z])', ' ' -creplace '(?<=[A-Z])(?=[A-Z][a-z])', ' '
        [void]$sb.Append("<th>$(ConvertTo-VhHtmlText $label)</th>")
    }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $Rows) {
        [void]$sb.Append('<tr>')
        foreach ($c in $cols) {
            $v = $r.$c
            if ($c -eq 'Severity') {
                [void]$sb.Append("<td data-v=""$(@{Critical=3;Warning=2;Info=1}[[string]$v])""><span class=""pill $(Get-VhSeverityClass $v)"">$(ConvertTo-VhHtmlText $v)</span></td>")
            }
            elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
                [void]$sb.Append("<td class=""num"">$(ConvertTo-VhHtmlText $v)</td>")
            }
            else { [void]$sb.Append("<td>$(ConvertTo-VhHtmlText $v)</td>") }
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    $sb.ToString()
}

function Get-VhScoreSvg {
    param([int]$Score)
    $color = if ($Score -ge 90) { '#2e7d32' } elseif ($Score -ge 75) { '#1f6feb' } elseif ($Score -ge 60) { '#b26a00' } else { '#c62828' }
    $r = 46; $circ = [math]::Round(2 * [math]::PI * $r, 2); $off = [math]::Round($circ * (1 - $Score / 100), 2)
    "<svg width=""116"" height=""116"" viewBox=""0 0 116 116"" role=""img"" aria-label=""Health score $Score of 100""><circle cx=""58"" cy=""58"" r=""$r"" fill=""none"" stroke=""#e2e6ed"" stroke-width=""10""/><circle cx=""58"" cy=""58"" r=""$r"" fill=""none"" stroke=""$color"" stroke-width=""10"" stroke-linecap=""round"" stroke-dasharray=""$circ"" stroke-dashoffset=""$off"" transform=""rotate(-90 58 58)""/><text x=""58"" y=""64"" text-anchor=""middle"" font-size=""28"" font-weight=""700"" fill=""$color"" font-family=""Segoe UI,Arial,sans-serif"">$Score</text></svg>"
}

function ConvertTo-VhHtmlReport {
    <#
        .SYNOPSIS
            Renders check results and inventory into a single self-contained HTML file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][hashtable]$Settings,
        [timespan]$Duration = [timespan]::Zero,
        [string]$ToolVersion = '1.0.0'
    )
    $h = { param($v) ConvertTo-VhHtmlText $v }
    $findings = @($Results | Where-Object { $_.Status -in 'Finding', 'Error' })
    $passed = @($Results | Where-Object { $_.Status -eq 'Pass' })
    $count = @{
        Critical = @($findings | Where-Object Severity -eq 'Critical').Count
        Warning  = @($findings | Where-Object Severity -eq 'Warning').Count
        Info     = @($findings | Where-Object Severity -eq 'Info').Count
        Error    = @($findings | Where-Object Severity -eq 'Error').Count
    }
    $score = Get-VhHealthScore -Results $Results
    $grade = if ($score -ge 90) { 'Healthy' } elseif ($score -ge 75) { 'Good' } elseif ($score -ge 60) { 'Needs attention' } else { 'At risk' }
    $lic = Get-VhLicenseSummary -Inventory $Inventory -Settings $Settings
    $title = [string]$Settings.Report.Title
    $org = [string]$Settings.Report.Organization
    $generated = Get-Date

    $vms = @($Inventory.Vms | Where-Object { -not $_.IsTemplate })
    $vmOn = @($vms | Where-Object PowerState -eq 'poweredOn').Count
    $dsCap = (Get-VhSum @($Inventory.Datastores) 'CapacityGB')
    $dsFree = (Get-VhSum @($Inventory.Datastores) 'FreeGB')
    $dsUsedPct = if ($dsCap) { [math]::Round(100 * ($dsCap - $dsFree) / $dsCap, 0) } else { 0 }
    $memTotal = (Get-VhSum @($Inventory.Hosts) 'MemoryGB')

    $sb = [Text.StringBuilder]::new()
    $add = { param($s) [void]$sb.Append($s) }

    & $add "<!DOCTYPE html><html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1"">"
    & $add "<title>$(& $h $title) - $($generated.ToString('yyyy-MM-dd'))</title><style>$(Get-VhCss)</style></head><body>"

    # ---- Header ----
    & $add "<header class=""top""><div class=""wrap""><div class=""org"">$(& $h $org)</div><h1>$(& $h $title)</h1>"
    & $add "<div class=""meta""><span>Generated $($generated.ToString('dddd, MMMM d, yyyy HH:mm'))</span><span>$($Results.Count) checks evaluated</span><span>Collection time $([int]$Duration.TotalSeconds)s</span></div><div class=""chips"">"
    foreach ($v in $Inventory.vCenters) { & $add "<span class=""chip"">$(& $h $v.Name) &middot; vCenter $(& $h $v.Version) build $(& $h $v.Build)</span>" }
    & $add "</div></div></header><main><div class=""wrap"">"

    # ---- Score + tiles ----
    & $add "<div class=""grid g-top""><div class=""card score"">$(Get-VhScoreSvg $score)<div><div class=""lbl"">Health score</div><div class=""grade"">$grade</div><div class=""sub"">Weighted share of checks passing</div></div></div>"
    & $add "<div class=""grid g-tiles"">"
    & $add "<div class=""tile crit""><div class=""n"">$($count.Critical)</div><div class=""t"">Critical</div></div>"
    & $add "<div class=""tile warn""><div class=""n"">$($count.Warning)</div><div class=""t"">Warning</div></div>"
    & $add "<div class=""tile info""><div class=""n"">$($count.Info)</div><div class=""t"">Advisory</div></div>"
    & $add "<div class=""tile pass""><div class=""n"">$($passed.Count)</div><div class=""t"">Passed</div></div></div></div>"

    # ---- Environment KPIs ----
    & $add "<div class=""card"" style=""margin-top:16px""><h2>Environment</h2><div class=""grid g-kpi"">"
    $kpis = [ordered]@{
        'vCenter Servers' = @($Inventory.vCenters).Count
        'Clusters'        = @($Inventory.Clusters).Count
        'ESXi hosts'      = @($Inventory.Hosts).Count
        'Virtual machines' = "$($vms.Count) <span style=""font-size:13px;color:var(--muted)"">($vmOn powered on)</span>"
        'Physical cores'  = '{0:N0}' -f $lic.PhysicalCores
        'Host memory'     = '{0:N1} TB' -f ($memTotal / 1024)
        'Datastores'      = @($Inventory.Datastores).Count
        'Storage used'    = "$dsUsedPct% <span style=""font-size:13px;color:var(--muted)"">of $('{0:N1}' -f ($dsCap / 1024)) TB</span>"
    }
    foreach ($k in $kpis.Keys) { & $add "<div class=""kpi""><div class=""v"">$($kpis[$k])</div><div class=""k"">$k</div></div>" }
    & $add "</div></div>"

    # ---- Licensing + top issues ----
    & $add "<div class=""grid g-2"" style=""margin-top:16px""><div class=""card""><h2>Licensing &amp; entitlement<small>$(& $h $lic.Model)</small></h2><dl class=""kv"">"
    & $add "<dt>Licensing method</dt><dd>$(& $h $lic.LicensingMethod)</dd>"
    & $add "<dt>Physical cores</dt><dd>$('{0:N0}' -f $lic.PhysicalCores) across $($lic.HostCount) hosts</dd>"
    $uplift = if ($lic.MinimumCoreUplift -gt 0) { ' <span class="pill info">+' + $lic.MinimumCoreUplift + ' from 16-core minimum</span>' } else { '' }
    & $add "<dt>Cores to license</dt><dd>$('{0:N0}' -f $lic.RequiredCores)$uplift</dd>"
    if ($lic.PurchasedCores -gt 0) {
        $pill = if ($lic.CoreShortfall -gt 0) { "<span class=""pill crit"">short $($lic.CoreShortfall)</span>" } else { "<span class=""pill pass"">covered</span>" }
        & $add "<dt>Cores purchased</dt><dd>$('{0:N0}' -f $lic.PurchasedCores) $pill</dd>"
    }
    if ($lic.VsanRawTiB -gt 0) {
        $pct = if ($lic.VsanEntitledTiB -gt 0) { [math]::Min(100, [math]::Round(100 * $lic.VsanRawTiB / $lic.VsanEntitledTiB)) } else { 100 }
        $over = if ($lic.VsanShortfallTiB -gt 0) { ' over' } else { '' }
        & $add "<dt>vSAN raw capacity</dt><dd>$($lic.VsanRawTiB) TiB of $($lic.VsanEntitledTiB) TiB entitled<div class=""bar$over""><span style=""width:$pct%""></span></div></dd>"
    }
    if ($lic.UsesLicenseFile) {
        $due = if ($lic.UsageReportDue) { "$($lic.UsageReportDue.ToString('yyyy-MM-dd')) ($($lic.UsageReportDaysLeft) days)" } else { 'Not tracked - set Licensing.UsageReportLastSubmitted' }
        & $add "<dt>Usage report due</dt><dd>$(& $h $due)</dd>"
    }
    $keys = @($Inventory.Licenses | Where-Object { -not $_.IsEval })
    if ($keys.Count) { & $add "<dt>License keys</dt><dd>$($keys.Count) key(s) in vCenter 8.x</dd>" }
    & $add "</dl><div class=""note"">Core counts follow the per-core subscription model: each CPU is counted at its core count with a minimum of $($Settings.Licensing.MinCoresPerCpu). vCenter 9 has no license keys; license status and the usage-report cycle live in VCF Operations.</div></div>"

    & $add "<div class=""card""><h2>Top issues</h2>"
    $top = @($findings | Where-Object { $_.Severity -in 'Critical', 'Warning', 'Error' } | Sort-Object @{ e = { $script:SeverityRank[$_.Severity] }; Descending = $true }, @{ e = { $_.Rows.Count }; Descending = $true } | Select-Object -First 8)
    if ($top.Count) {
        & $add "<ul class=""top-list"">"
        foreach ($t in $top) { & $add "<li><span class=""pill $(Get-VhSeverityClass $t.Severity)"">$($t.Severity)</span><a href=""#$($t.Id)"">$(& $h $t.Title)</a><span class=""c"">$(if ($t.Status -eq 'Error') { 'check error' } else { "$($t.Rows.Count) item(s)" })</span></li>" }
        & $add "</ul>"
    }
    else { & $add "<p class=""desc"">No critical or warning findings. Nice work.</p>" }
    & $add "</div></div>"

    # ---- Category summary ----
    $cats = 'Licensing', 'Lifecycle', 'vCenter', 'Clusters', 'Hosts', 'Hardware', 'VxRail', 'Storage', 'Virtual Machines', 'Networking'
    & $add "<div class=""card"" style=""margin-top:16px""><h2>Summary by area</h2><div class=""tbl""><table><thead><tr><th>Area</th><th>Critical</th><th>Warning</th><th>Advisory</th><th>Passed</th></tr></thead><tbody>"
    foreach ($c in $cats) {
        $cr = @($Results | Where-Object Category -eq $c)
        if (-not $cr) { continue }
        $n = { param($s) @($cr | Where-Object { $_.Status -eq 'Finding' -and $_.Severity -eq $s }).Count }
        $cells = foreach ($s in 'Critical', 'Warning', 'Info') {
            $x = & $n $s
            if ($x) { "<td><span class=""pill $(Get-VhSeverityClass $s)"">$x</span></td>" } else { '<td style="color:var(--muted)">0</td>' }
        }
        & $add "<tr><td><a href=""#cat-$($c -replace ' ', '-')"">$c</a></td>$($cells -join '')<td>$(@($cr | Where-Object Status -eq 'Pass').Count)</td></tr>"
    }
    & $add "</tbody></table></div></div>"

    # ---- Findings ----
    & $add "<div class=""toolbar""><h2>Findings</h2><input id=""filter"" class=""filter"" type=""search"" placeholder=""Filter findings, VMs, hosts..."" aria-label=""Filter findings""><button class=""btn"" id=""expand"" type=""button"">Expand all</button><button class=""btn"" id=""collapse"" type=""button"">Collapse all</button></div>"
    if (-not $findings) { & $add "<div class=""card""><p class=""desc"">No findings.</p></div>" }
    foreach ($c in $cats) {
        $cf = @($findings | Where-Object Category -eq $c | Sort-Object @{ e = { $script:SeverityRank[$_.Severity] }; Descending = $true }, Id)
        if (-not $cf) { continue }
        & $add "<section class=""cat"" id=""cat-$($c -replace ' ', '-')""><h3>$c</h3>"
        foreach ($f in $cf) {
            $cls = Get-VhSeverityClass $f.Severity
            $open = if ($f.Severity -in 'Critical', 'Error') { ' open' } else { '' }
            $label = if ($f.Severity -eq 'Info') { 'Advisory' } else { $f.Severity }
            $cnt = if ($f.Status -eq 'Error') { 'check failed' } else { "$($f.Rows.Count) item$(if ($f.Rows.Count -ne 1) { 's' })" }
            & $add "<details class=""check $cls"" id=""$($f.Id)""$open><summary><span class=""id"">$($f.Id)</span><span class=""pill $cls"">$label</span><span class=""title"">$(& $h $f.Title)</span><span class=""count"">$cnt</span></summary><div class=""body"">"
            & $add "<p class=""desc"">$(& $h $f.Description)</p>"
            if ($f.Remediation) { & $add "<div class=""fix""><b>Recommended action:</b> $(& $h $f.Remediation)</div>" }
            if ($f.Status -eq 'Error') { & $add "<div class=""fix""><b>Check error:</b> $(& $h $f.Error)</div>" }
            else { & $add (ConvertTo-VhHtmlTable -Rows $f.Rows) }
            & $add "</div></details>"
        }
        & $add "</section>"
    }

    # ---- Passed ----
    if ($Settings.Report.ShowPassed -and $passed) {
        & $add "<div class=""card"" style=""margin-top:24px""><h2>Passed checks<small>$($passed.Count)</small></h2><ul class=""passed"">"
        foreach ($p in ($passed | Sort-Object Id)) { & $add "<li><span class=""id"">$($p.Id)</span>$(& $h $p.Title)</li>" }
        & $add "</ul></div>"
    }
    $na = @($Results | Where-Object { $_.Status -in 'NotApplicable', 'Skipped' })
    if ($na) { & $add "<p class=""note"">Not evaluated: $(($na | ForEach-Object { "$($_.Id) ($($_.Status))" }) -join ', ').</p>" }

    & $add "</div></main><footer><div class=""wrap"">vSphere Health Report v$ToolVersion &middot; read-only collection via PowerCLI &middot; $($generated.ToString('u'))</div></footer>"
    & $add "<script>$(Get-VhScript)</script></body></html>"
    $sb.ToString()
}

function ConvertTo-VhEmailSummary {
    <#  Compact summary with inline styles for mail clients that strip <style> and scripts. #>
    param([object[]]$Results, [hashtable]$Settings)
    $findings = @($Results | Where-Object { $_.Status -eq 'Finding' -and $_.Severity -in 'Critical', 'Warning' } | Sort-Object @{ e = { $script:SeverityRank[$_.Severity] }; Descending = $true }, Id)
    $score = Get-VhHealthScore -Results $Results
    $c = @{ Critical = '#c62828'; Warning = '#b26a00' }
    $rows = foreach ($f in $findings) {
        "<tr><td style=""padding:6px 10px;border-bottom:1px solid #e2e6ed""><span style=""color:$($c[$f.Severity]);font-weight:600"">$($f.Severity)</span></td><td style=""padding:6px 10px;border-bottom:1px solid #e2e6ed;font-family:Consolas,monospace;color:#5b6578"">$($f.Id)</td><td style=""padding:6px 10px;border-bottom:1px solid #e2e6ed"">$(ConvertTo-VhHtmlText $f.Title)</td><td style=""padding:6px 10px;border-bottom:1px solid #e2e6ed;text-align:right"">$($f.Rows.Count)</td></tr>"
    }
    $body = if ($rows) { "<table style=""border-collapse:collapse;width:100%;font-size:13px""><tr style=""background:#f4f6f9""><th align=""left"" style=""padding:6px 10px"">Severity</th><th align=""left"" style=""padding:6px 10px"">ID</th><th align=""left"" style=""padding:6px 10px"">Finding</th><th align=""right"" style=""padding:6px 10px"">Items</th></tr>$($rows -join '')</table>" } else { '<p>No critical or warning findings.</p>' }
    "<div style=""font-family:Segoe UI,Arial,sans-serif;color:#1d2533;max-width:760px""><div style=""background:#0b2545;color:#fff;padding:18px 22px""><div style=""font-size:11px;letter-spacing:.12em;text-transform:uppercase;opacity:.8"">$(ConvertTo-VhHtmlText $Settings.Report.Organization)</div><div style=""font-size:22px;font-weight:600"">$(ConvertTo-VhHtmlText $Settings.Report.Title)</div><div style=""font-size:13px;opacity:.85"">Health score $score / 100 &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div></div><div style=""padding:16px 22px;background:#fff;border:1px solid #e2e6ed"">$body<p style=""font-size:12px;color:#5b6578"">The full interactive report is attached.</p></div></div>"
}
