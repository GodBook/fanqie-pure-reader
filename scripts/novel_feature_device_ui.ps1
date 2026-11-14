#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Serial = '',
    [string]$EvidenceDirectory = 'build/novel-validation/features-16-2026-11-14',
    [string]$TapDescription = '',
    [int]$TapX = -1,
    [int]$TapY = -1,
    [switch]$Back,
    [switch]$SwipeUp,
    [switch]$Screenshot
)
$ErrorActionPreference = 'Stop'
if (-not $Serial) {
    $featureDevices = @(& adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($featureDevices.Count -ne 1) { throw 'Connect exactly one authorized Android device or pass -Serial.' }
    $Serial = $featureDevices[0]
}
if ($Name -notmatch '^[a-zA-Z0-9_.-]{1,80}$') { throw 'Use a short artifact name.' }
$featureRoot = Join-Path (Split-Path -Parent $PSScriptRoot) $EvidenceDirectory
New-Item -ItemType Directory -Path $featureRoot -Force | Out-Null
$featurePrevious = Join-Path $featureRoot 'latest-ui.xml'
if ($TapDescription) {
    if (-not (Test-Path -LiteralPath $featurePrevious)) { throw 'Take an initial snapshot first.' }
    [xml]$featureTree = Get-Content -LiteralPath $featurePrevious -Raw
    $featureTargets = @($featureTree.SelectNodes('//node') | Where-Object { $_.'content-desc' -match $TapDescription -or $_.text -match $TapDescription })
    if ($featureTargets.Count -ne 1) { throw "Description matched $($featureTargets.Count) nodes." }
    if ($featureTargets[0].bounds -notmatch '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') { throw 'Missing target bounds.' }
    $TapX = ([int]$Matches[1] + [int]$Matches[3]) / 2
    $TapY = ([int]$Matches[2] + [int]$Matches[4]) / 2
}
if ($TapX -ge 0 -and $TapY -ge 0) { & adb -s $Serial shell input tap $TapX $TapY | Out-Null }
if ($Back) { & adb -s $Serial shell input keyevent KEYCODE_BACK | Out-Null }
if ($SwipeUp) { & adb -s $Serial shell input swipe 540 1800 540 650 350 | Out-Null }
& adb -s $Serial shell uiautomator dump /data/local/tmp/fq-feature-ui.xml 2>$null | Out-Null
& adb -s $Serial pull /data/local/tmp/fq-feature-ui.xml (Join-Path $featureRoot "$Name.xml") 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not save the current UI.' }
Copy-Item -LiteralPath (Join-Path $featureRoot "$Name.xml") -Destination $featurePrevious -Force
if ($Screenshot) {
    & adb -s $Serial shell screencap -p /data/local/tmp/fq-feature-ui.png
    & adb -s $Serial pull /data/local/tmp/fq-feature-ui.png (Join-Path $featureRoot "$Name.png") 2>$null | Out-Null
}
[xml]$featureTree = Get-Content -LiteralPath $featurePrevious -Raw
@($featureTree.SelectNodes('//node') | Where-Object { $_.text -or $_.'content-desc' } | ForEach-Object {
    [pscustomobject]@{ text = $_.text; description = $_.'content-desc'; bounds = $_.bounds }
}) | ConvertTo-Json -Compress
