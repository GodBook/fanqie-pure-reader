#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Serial = '',
    [ValidateSet('all', 'online', 'offline')][string]$Stage = 'all',
    [switch]$MeasureExistingOffline,
    [ValidateSet('debug', 'profile')][string]$BuildMode = 'profile',
    [string]$JdkRoot = 'D:\dev\jdk-17',
    [string]$BuildRoot = 'D:\dev\fanqie-pure'
)
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}

if (-not $Serial) {
    $devices = @(& adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devices.Count -ne 1) { throw 'Connect and authorize exactly one Android device, or pass -Serial.' }
    $Serial = $devices[0]
}
$policy = (& adb -s $Serial shell dumpsys window policy) -join "`n"
if ($policy -match '(?m)^\s+showing=true\s*$') {
    throw 'The phone is locked. Unlock it on the phone before running UI acceptance.'
}
$wifiStatus = (& adb -s $Serial shell cmd wifi status) -join "`n"
$route = (& adb -s $Serial shell ip -4 route get 1.1.1.1 2>&1) -join "`n"
if ($Stage -ne 'offline' -and ($LASTEXITCODE -ne 0 -or $route -notmatch '\bsrc\s+\d+\.')) {
    throw 'The phone has no usable network route. Connect it to Wi-Fi before online acceptance.'
}
$registrationHosts = (& adb -s $Serial shell "grep -E '(^|[[:space:]])log[.]snssdk[.]com([[:space:]]|$)' /system/etc/hosts") -join "`n"
if ($Stage -ne 'offline' -and $registrationHosts -match '(?m)^\s*(?:0\.0\.0\.0|127\.\d+\.\d+\.\d+|::1)\s+[^#\r\n]*\blog\.snssdk\.com\b') {
    throw 'The phone blocks log.snssdk.com, which the upstream protocol needs for first-time registration. Allow that domain in the blocking tool before online acceptance.'
}

$previousJava = $env:JAVA_HOME
$previousPath = $env:PATH
$previousOffline = $env:NOVEL_E2E_OFFLINE
$previousTestBuildMode = $env:NOVEL_E2E_BUILD_MODE
$baseline = @{
    serial = $Serial
    wifi = if ($wifiStatus -match '(?m)^Wifi is enabled\r?$') { '1' } else { '0' }
    data = ( & adb -s $Serial shell settings get global mobile_data ).Trim()
    stayAwake = ( & adb -s $Serial shell settings get global stay_on_while_plugged_in ).Trim()
}
$networkChanged = $false
$testForwardPort = $null
Push-Location -LiteralPath $BuildRoot
try {
    $env:JAVA_HOME = $JdkRoot
    $env:NOVEL_E2E_BUILD_MODE = $BuildMode
    $env:PATH = (Join-Path $JdkRoot 'bin') + ';' + $env:PATH
    $reports = Join-Path $BuildRoot 'build/novel-validation'
    New-Item -ItemType Directory -Force -Path $reports | Out-Null
    $baseline | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reports 'device-settings-before.json') -Encoding utf8
    Invoke-Checked 'adb' @('-s', $Serial, 'shell', 'settings', 'put', 'global', 'stay_on_while_plugged_in', '7')
    Invoke-Checked 'adb' @('-s', $Serial, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    $stages = if ($Stage -eq 'all') { @('online', 'offline') } else { @($Stage) }
    foreach ($currentStage in $stages) {
    $offlineValue = if ($currentStage -eq 'offline') { 'true' } else { 'false' }
    $offlineBuildArguments = @('--no-version-check', 'build', 'apk', '--no-pub', "--$BuildMode",
        '--target-platform', 'android-arm64', "--dart-define=NOVEL_E2E_OFFLINE=$offlineValue",
        '--target', 'integration_test/novel_workflow_test.dart')
    if ($MeasureExistingOffline) { $offlineBuildArguments += '--dart-define=NOVEL_E2E_MEASURE_EXISTING=true' }
    Invoke-Checked 'flutter' $offlineBuildArguments
    Invoke-Checked 'adb' @('-s', $Serial, 'install', '-r', '-t', "build/app/outputs/flutter-apk/app-$BuildMode.apk")
    if ($currentStage -eq 'offline') {
        $networkChanged = $true
        Invoke-Checked 'adb' @('-s', $Serial, 'shell', 'svc', 'wifi', 'disable')
        Invoke-Checked 'adb' @('-s', $Serial, 'shell', 'svc', 'data', 'disable')
    }
    $env:NOVEL_E2E_OFFLINE = $offlineValue
    # flutter drive normally uninstalls its app at exit, which would erase the
    # downloads before the persistence check. Keep it installed, then explicitly
    # kill the process so the second run proves a cold restart with its data.
    Invoke-Checked 'adb' @('-s', $Serial, 'shell', 'am', 'force-stop', 'com.fanqie.pure.reader.test')
    Invoke-Checked 'adb' @('-s', $Serial, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    # Offline log-based VM discovery is unreliable on this phone. This temporary
    # test VM listens on loopback only; direct USB forwarding bypasses discovery.
    Invoke-Checked 'adb' @('-s', $Serial, 'shell', 'am', 'start', '-n',
        'com.fanqie.pure.reader.test/com.fqapp.fqapp.MainActivity',
        '--ez', 'start-paused', 'true', '--ez', 'disable-service-auth-codes', 'true',
        '--ei', 'vm-service-port', '58900')
    $testForwardPort = (& adb -s $Serial forward tcp:0 tcp:58900).Trim()
    if ($LASTEXITCODE -ne 0 -or $testForwardPort -notmatch '^\d+$') { throw 'USB VM forwarding failed.' }
    $vmReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $vm = Invoke-RestMethod -Uri "http://127.0.0.1:$testForwardPort/getVM" -TimeoutSec 2
            if ($vm.result.type -eq 'VM') { $vmReady = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    if (-not $vmReady) { throw 'The test VM did not become ready over USB.' }
    Invoke-Checked 'flutter' @('--no-version-check', 'drive', '--no-pub', '--no-dds', "--$BuildMode", '--keep-app-running',
        "--use-existing-app=http://127.0.0.1:$testForwardPort/", '--driver', 'test_driver/novel_workflow.dart')
    Invoke-Checked 'adb' @('-s', $Serial, 'forward', '--remove', "tcp:$testForwardPort")
    $testForwardPort = $null
    }
} finally {
    if ($testForwardPort) { & adb -s $Serial forward --remove "tcp:$testForwardPort" }
    if ($networkChanged) {
        $wifiAction = if ($baseline.wifi -eq '1') { 'enable' } else { 'disable' }
        $dataAction = if ($baseline.data -eq '1') { 'enable' } else { 'disable' }
        & adb -s $Serial shell svc wifi $wifiAction
        & adb -s $Serial shell svc data $dataAction
    }
    if ($baseline.stayAwake -match '^\d+$') {
        & adb -s $Serial shell settings put global stay_on_while_plugged_in $baseline.stayAwake
    }
    $env:JAVA_HOME = $previousJava
    $env:PATH = $previousPath
    $env:NOVEL_E2E_OFFLINE = $previousOffline
    $env:NOVEL_E2E_BUILD_MODE = $previousTestBuildMode
    Pop-Location
}
