#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Serial = '',
    [ValidateSet('com.fanqie.pure.reader', 'com.fanqie.pure.reader.test')]
    [string]$Package = 'com.fanqie.pure.reader',
    [Parameter(Mandatory)][string]$Scenario,
    [ValidateRange(5, 30)][int]$Seconds = 10,
    [string]$ReportRoot = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Serial) {
    $devices = @(& adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devices.Count -ne 1) { throw 'Connect exactly one authorized device or pass -Serial.' }
    $Serial = $devices[0]
}
if (-not $ReportRoot) { $ReportRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'build/novel-validation' }

function Read-Device([string[]]$Arguments) {
    $output = (& adb -s $Serial @Arguments) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Device measurement failed: $($Arguments[0])" }
    return $output.Trim()
}

function Read-Sample {
    $power = Read-Device @('shell', 'dumpsys', 'power')
    if ($power -notmatch '(?m)^\s*mWakefulness=Awake\s*$') {
        throw 'Reading measurements require an awake display.'
    }
    $activities = Read-Device @('shell', 'dumpsys', 'activity', 'activities')
    if ($activities -notmatch ('(?m)^\s*topResumedActivity=[^\r\n]*' + [regex]::Escape($Package) + '/')) {
        throw 'Reading measurements require the app in the foreground.'
    }
    $appPid = Read-Device @('shell', 'pidof', $Package)
    if ($appPid -notmatch '^\d+$') { throw 'Exactly one running app process is required.' }
    # Root reads only process accounting; no app content or keys are collected.
    $stat = Read-Device @('shell', 'su', '-c', 'cat', "/proc/$appPid/stat")
    $fields = $stat.Substring($stat.LastIndexOf(')') + 2) -split '\s+'
    $uptime = (Read-Device @('shell', 'cat', '/proc/uptime')) -split '\s+'
    $memory = Read-Device @('shell', 'dumpsys', 'meminfo', '-s', $Package)
    if ($memory -match 'TOTAL PSS:\s+(\d+)\s+TOTAL RSS:\s+(\d+)') {
        $pssKiB = [long]$Matches[1]
        $rssKiB = [long]$Matches[2]
    } else {
        # Android can omit cached/frozen processes from dumpsys. Kernel rollup
        # still supplies resident/PSS accounting without thawing the app.
        $memory = Read-Device @('shell', 'su', '-c', 'cat', "/proc/$appPid/smaps_rollup")
        if ($memory -notmatch '(?m)^Pss:\s+(\d+)\s+kB') { throw 'Missing kernel PSS.' }
        $pssKiB = [long]$Matches[1]
        if ($memory -notmatch '(?m)^Rss:\s+(\d+)\s+kB') { throw 'Missing kernel RSS.' }
        $rssKiB = [long]$Matches[1]
    }
    return @{
        displayAwake = $true
        appForeground = $true
        pid = $appPid
        processStartTicks = [long]$fields[19]
        cpuTicks = [long]$fields[11] + [long]$fields[12]
        uptimeSeconds = [double]::Parse($uptime[0], [Globalization.CultureInfo]::InvariantCulture)
        pssKiB = $pssKiB
        rssKiB = $rssKiB
        rawMeminfo = $memory
    }
}

$clockTicks = [int](Read-Device @('shell', 'getconf', 'CLK_TCK'))
if ($clockTicks -le 0) { throw 'Invalid device clock tick rate.' }
$before = Read-Sample
Start-Sleep -Seconds $Seconds
$after = Read-Sample
if ($before.pid -ne $after.pid -or $before.processStartTicks -ne $after.processStartTicks) {
    throw 'App restarted during measurement; this sample is invalid.'
}
$elapsed = $after.uptimeSeconds - $before.uptimeSeconds
if ($elapsed -le 0) { throw 'Invalid device elapsed time.' }
$cpuSeconds = ($after.cpuTicks - $before.cpuTicks) / $clockTicks
$report = @{
    recordedAt = [DateTimeOffset]::Now.ToString('o')
    package = $Package
    scenario = $Scenario
    elapsedSeconds = $elapsed
    processCpuSeconds = $cpuSeconds
    cpuPercentOfOneCore = [Math]::Round(100 * $cpuSeconds / $elapsed, 2)
    before = $before
    after = $after
}
New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null
$reportPath = Join-Path $ReportRoot ('resources-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '.json')
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Output $reportPath
$report | Select-Object scenario, elapsedSeconds, processCpuSeconds, cpuPercentOfOneCore | ConvertTo-Json
