#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$JdkRoot = 'D:\dev\jdk-17',
    [string]$BuildRoot = 'D:\dev\fanqie-pure',
    [string]$DartTarget = 'integration_test/novel_resume_safety_test.dart',
    [string]$Driver = 'test_driver/novel_resume_safety.dart',
    [switch]$SkipBuild,
    [switch]$InstallWithDeviceRoot
)
$ErrorActionPreference = 'Stop'
$resumeDevices = @(& adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
if ($resumeDevices.Count -ne 1) { throw 'Exactly one authorized Android device is required.' }
$resumeSerial = $resumeDevices[0]
$resumePolicy = (& adb -s $resumeSerial shell dumpsys window policy) -join "`n"
if ($resumePolicy -match '(?m)^\s+showing=true\s*$') { throw 'Unlock the phone before running the visible safety check.' }
function Invoke-ResumeChecked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed ($LASTEXITCODE)." }
}
$resumePreviousJava = $env:JAVA_HOME
$resumePreviousPath = $env:PATH
$resumePort = $null
Push-Location -LiteralPath $BuildRoot
try {
    $env:JAVA_HOME = $JdkRoot
    $env:PATH = (Join-Path $JdkRoot 'bin') + ';' + $env:PATH
    if (-not $SkipBuild) {
        Invoke-ResumeChecked 'flutter' @('--no-version-check', 'build', 'apk', '--no-pub', '--profile',
            '--target-platform', 'android-arm64', '--target', $DartTarget)
    }
    $resumeSdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $env:ANDROID_SDK_ROOT }
    if (-not $resumeSdk) { throw 'Set ANDROID_HOME before verifying the isolated test package.' }
    $resumeBuildTools = Get-ChildItem -LiteralPath (Join-Path $resumeSdk 'build-tools') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $resumeBadging = (& (Join-Path $resumeBuildTools.FullName 'aapt.exe') dump badging 'build/app/outputs/flutter-apk/app-profile.apk') -join "`n"
    if ($LASTEXITCODE -ne 0 -or $resumeBadging -notmatch "package: name='com\.fanqie\.pure\.reader\.test'") {
        throw 'Refusing to install an APK outside the isolated .test package.'
    }
    if ($InstallWithDeviceRoot) {
        Invoke-ResumeChecked 'adb' @('-s', $resumeSerial, 'push', 'build/app/outputs/flutter-apk/app-profile.apk', '/data/local/tmp/fq-features-test.apk')
        try {
            Invoke-ResumeChecked 'adb' @('-s', $resumeSerial, 'shell', 'su', '-c', 'pm install -r -t /data/local/tmp/fq-features-test.apk')
        } finally {
            & adb -s $resumeSerial shell rm -f /data/local/tmp/fq-features-test.apk
        }
    } else {
        Invoke-ResumeChecked 'adb' @('-s', $resumeSerial, 'install', '-r', '-t', 'build/app/outputs/flutter-apk/app-profile.apk')
    }
    Invoke-ResumeChecked 'adb' @('-s', $resumeSerial, 'shell', 'am', 'force-stop', 'com.fanqie.pure.reader.test')
    Invoke-ResumeChecked 'adb' @('-s', $resumeSerial, 'shell', 'am', 'start', '-n',
        'com.fanqie.pure.reader.test/com.fqapp.fqapp.MainActivity', '--ez', 'start-paused', 'true',
        '--ez', 'disable-service-auth-codes', 'true', '--ei', 'vm-service-port', '58900')
    $resumePort = (& adb -s $resumeSerial forward tcp:0 tcp:58900).Trim()
    if ($LASTEXITCODE -ne 0 -or $resumePort -notmatch '^\d+$') { throw 'USB forwarding failed.' }
    $resumeVmReady = $false
    for ($resumeAttempt = 0; $resumeAttempt -lt 30; $resumeAttempt++) {
        try {
            $resumeVm = Invoke-RestMethod -Uri "http://127.0.0.1:$resumePort/getVM" -TimeoutSec 2
            if ($resumeVm.result.type -eq 'VM') { $resumeVmReady = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    if (-not $resumeVmReady) { throw 'The isolated test VM did not become ready.' }
    Invoke-ResumeChecked 'flutter' @('--no-version-check', 'drive', '--no-pub', '--no-dds', '--profile',
        '--keep-app-running', "--use-existing-app=http://127.0.0.1:$resumePort/", '--driver', $Driver)
} finally {
    if ($resumePort) { & adb -s $resumeSerial forward --remove "tcp:$resumePort" }
    & adb -s $resumeSerial shell am force-stop com.fanqie.pure.reader.test
    $env:JAVA_HOME = $resumePreviousJava
    $env:PATH = $resumePreviousPath
    Pop-Location
}
