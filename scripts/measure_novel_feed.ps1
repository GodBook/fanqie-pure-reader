#requires -Version 7.2
param(
    [string]$Serial = '',
    [ValidateSet('com.fanqie.pure.reader', 'com.fanqie.pure.reader.benchmark')]
    [string]$Package = 'com.fanqie.pure.reader',
    [ValidateRange(1, 10)][int]$Count = 3,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
if (-not $Serial) {
    $devices = @(& adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devices.Count -ne 1) { throw 'Connect exactly one authorized device or pass -Serial.' }
    $Serial = $devices[0]
}
function Read-Adb([string[]]$Arguments) {
    $result = (& adb -s $Serial @Arguments) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Device command failed: $($Arguments[0])" }
    return $result
}
$samples = @()
foreach ($run in 1..$Count) {
    $null = Read-Adb @('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    $policy = Read-Adb @('shell', 'dumpsys', 'window', 'policy')
    if ($policy -match '(?m)^\s+showing=true\s*$') { throw 'Unlock the phone before measuring visible books.' }
    $null = Read-Adb @('shell', 'am', 'force-stop', $Package)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $launch = Read-Adb @('shell', 'am', 'start', '-W', '-n', "$Package/com.fqapp.fqapp.MainActivity")
    $appPid = (Read-Adb @('shell', 'pidof', $Package)).Trim()
    $frameMs = $null
    $source = $null
    do {
        $log = Read-Adb @('logcat', '-d', "--pid=$appPid", '-v', 'brief', '-s', 'NovelPerformance:I', '*:S')
        if ($log -match 'feed_first_frame_ms=(\d+) source=([a-z]+)') {
            $frameMs = [int]$Matches[1]
            $source = $Matches[2]
            break
        }
        Start-Sleep -Milliseconds 100
    } while ($watch.ElapsedMilliseconds -lt 20000)
    $observedMs = $watch.ElapsedMilliseconds
    if ($null -eq $frameMs) { throw 'No actionable book frame observed. Strict filters may require live data; do not count an empty page.' }
    $sample = [ordered]@{
        run = $run; source = $source; processToBookFrameMs = $frameMs
        launchToObservedBookFrameMs = $observedMs
        activityTotalMs = if ($launch -match 'TotalTime:\s*(\d+)') { [int]$Matches[1] } else { $null }
        within2Seconds = $observedMs -lt 2000
    }
    $samples += $sample
    Write-Output ($sample | ConvertTo-Json -Compress)
}
$report = [ordered]@{
    recordedAt = [DateTimeOffset]::Now.ToString('o'); package = $Package
    method = 'Real release books: Flutter post-frame plus Android next vsync; wall time also includes ADB launch and observation overhead. Network refresh is a separate metric.'
    samples = $samples
}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding utf8
if (@($samples | Where-Object { -not $_.within2Seconds }).Count) { throw 'At least one measured first-book frame exceeded two seconds.' }
