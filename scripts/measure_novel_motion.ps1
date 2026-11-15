#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateSet('reader', 'feed')][string]$Scenario = 'reader',
    [ValidateRange(2, 20)][int]$Gestures = 8
)
$ErrorActionPreference = 'Stop'
function Read-Device([string[]]$Arguments) {
    $value = (& adb -s $Serial @Arguments) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Device command failed: $($Arguments[0])" }
    return $value.Trim()
}
function Assert-Visible {
    if ((Read-Device @('shell','settings','get','global','mobile_data')) -ne '1') { throw 'Mobile data must remain enabled.' }
    if ((Read-Device @('shell','dumpsys','power')) -notmatch 'mWakefulness=Awake') { throw 'Require an awake display.' }
    if ((Read-Device @('shell','dumpsys','activity','activities')) -notmatch '(?m)^\s*(?:topResumedActivity=|mResumedActivity:)\s*ActivityRecord\{[^\r\n]*\scom[.]fanqie[.]pure[.]reader/') { throw 'Require the production app in front.' }
}
Assert-Visible
function Read-Counters {
    $processId = Read-Device @('shell','pidof','com.fanqie.pure.reader')
    $stat = Read-Device @('shell','su','-c','cat',"/proc/$processId/stat")
    $fields = $stat.Substring($stat.LastIndexOf(')') + 2) -split '\s+'
    $uptime = (Read-Device @('shell','cat','/proc/uptime')) -split '\s+'
    $memory = Read-Device @('shell','dumpsys','meminfo','-s','com.fanqie.pure.reader')
    if ($memory -notmatch 'TOTAL PSS:\s+(\d+)\s+TOTAL RSS:\s+(\d+)') { throw 'Missing visible-process memory accounting.' }
    [ordered]@{
        pid=$processId;processStartTicks=[long]$fields[19];cpuTicks=[long]$fields[11]+[long]$fields[12]
        uptimeSeconds=[double]::Parse($uptime[0],[Globalization.CultureInfo]::InvariantCulture)
        pssKiB=[long]$Matches[1];rssKiB=[long]$Matches[2]
    }
}
$layers = (Read-Device @('shell','dumpsys','SurfaceFlinger','--list')) -split "`n"
$matches = @($layers | Where-Object { $_ -match '^SurfaceView\[com[.]fanqie[.]pure[.]reader/.*\]\(BLAST\)#\d+$' })
if ($matches.Count -ne 1) { throw 'Need one identifiable Flutter presentation layer.' }
$layer = $matches[0].Trim()
$appPid = Read-Device @('shell','pidof','com.fanqie.pure.reader')
$clockTicks = [int](Read-Device @('shell','getconf','CLK_TCK'))
$before = Read-Counters
$runs = @()
for ($i = 0; $i -lt $Gestures; $i++) {
    Assert-Visible
    $null = Read-Device @('shell',"dumpsys SurfaceFlinger --latency-clear '$layer'")
    $forward = $i % 2 -eq 0
    $gesture = if ($Scenario -eq 'reader') {
        if ($forward) { 'input swipe 900 1200 160 1200 300' } else { 'input swipe 160 1200 900 1200 300' }
    } else {
        if ($forward) { 'input swipe 540 1800 540 750 450' } else { 'input swipe 540 750 540 1800 450' }
    }
    $null = Read-Device @('shell',$gesture)
    Start-Sleep -Milliseconds 350
    $raw = Read-Device @('shell',"dumpsys SurfaceFlinger --latency '$layer'")
    $lines = $raw -split "`n"
    $refreshNs = [long]$lines[0]
    $timestamps = @($lines | ForEach-Object {
        if ($_ -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s*$') {
            $present = [long]$Matches[2]
            if ($present -gt 0 -and $present -lt [long]::MaxValue) { $present }
        }
    } | Sort-Object -Unique)
    $gaps = @(for ($j = 1; $j -lt $timestamps.Count; $j++) { [Math]::Round(($timestamps[$j] - $timestamps[$j-1]) / 1000000.0, 3) })
    $runs += [ordered]@{
        gesture=$i+1;forward=$forward;refreshPeriodMs=$refreshNs/1000000.0;frames=$timestamps.Count
        presentationGapsMs=$gaps;raw=$raw
    }
}
Assert-Visible
$after = Read-Counters
if ((Read-Device @('shell','pidof','com.fanqie.pure.reader')) -ne $appPid) { throw 'Process restarted; motion sample invalid.' }
if ($before.processStartTicks -ne $after.processStartTicks) { throw 'Process accounting changed; sample invalid.' }
$elapsed = $after.uptimeSeconds-$before.uptimeSeconds
$cpu = ($after.cpuTicks-$before.cpuTicks)/$clockTicks
$all = @($runs | ForEach-Object { $_.presentationGapsMs })
if ($all.Count -lt 20) { throw 'Too few presented frames; no smoothness conclusion.' }
$sorted = @($all | Sort-Object)
$result = [ordered]@{
    recordedAt=[DateTimeOffset]::Now.ToString('o');scenario=$Scenario;package='com.fanqie.pure.reader'
    method='SurfaceFlinger actual presentation timestamps, cleared for each alternating gesture. Includes intra-gesture delays; no intervals across gestures. Measures presentation cadence, not Flutter build/raster time or touch latency.'
    mobileData='1';gestures=$runs;intervals=$all.Count
    medianGapMs=$sorted[[int][Math]::Floor(($sorted.Count-1)*0.5)]
    p95GapMs=$sorted[[int][Math]::Ceiling(($sorted.Count-1)*0.95)]
    gapsOver25Ms=@($all | Where-Object { $_ -gt 25 }).Count
    gapsOver50Ms=@($all | Where-Object { $_ -gt 50 }).Count
    maxGapMs=$sorted[-1]
    resources=[ordered]@{before=$before;after=$after;elapsedSeconds=$elapsed;processCpuSeconds=$cpu;cpuPercentOfOneCore=[Math]::Round(100*$cpu/$elapsed,2)}
}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
[pscustomobject]$result | Select-Object scenario,intervals,medianGapMs,p95GapMs,gapsOver25Ms,gapsOver50Ms,maxGapMs | ConvertTo-Json
