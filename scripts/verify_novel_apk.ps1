#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApkPath,
    [string]$ReportPath = ''
)
$ErrorActionPreference = 'Stop'
$apkFile = Get-Item -LiteralPath $ApkPath
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($apkFile.FullName)
try {
    $native = @($archive.Entries | Where-Object FullName -Like 'lib/*/*.so')
    $abis = @($native | ForEach-Object { ($_.FullName -split '/')[1] } | Sort-Object -Unique)
    if ($abis.Count -ne 1 -or $abis[0] -ne 'arm64-v8a') { throw "Unexpected packaged ABIs: $($abis -join ', ')" }
    foreach ($name in @('libapp.so', 'libflutter.so', 'libfqapi_core.so', 'libdartjni.so')) {
        $entry = $archive.GetEntry("lib/arm64-v8a/$name")
        if (-not $entry) { throw "Missing native library $name" }
        $stream = $entry.Open()
        try {
            $header = [byte[]]::new(20)
            $read = $stream.Read($header, 0, 20)
            if ($read -ne 20 -or $header[0] -ne 127 -or $header[1] -ne 69 -or $header[2] -ne 76 -or $header[3] -ne 70 -or $header[4] -ne 2 -or [BitConverter]::ToUInt16($header, 18) -ne 183) {
                throw "Invalid ARM64 ELF header in $name"
            }
        } finally { $stream.Dispose() }
    }
    if ($archive.Entries.FullName -match 'libshortplay_|NotoSerifSC-|assets/images/drama/') { throw 'Unused upstream media binaries or artwork remain packaged.' }
    if (-not $archive.GetEntry('assets/flutter_assets/LICENSE')) { throw 'GPL license is missing from the APK.' }
} finally { $archive.Dispose() }

$sdkRoot = $env:ANDROID_HOME
if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
if (-not $sdkRoot) { throw 'Set ANDROID_HOME to inspect the APK.' }
$tools = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$badging = (& (Join-Path $tools.FullName 'aapt.exe') dump badging $apkFile.FullName) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'aapt could not inspect the package.' }
if ($badging -match 'application-debuggable') { throw 'Shipping APK is debuggable.' }
if ($badging -notmatch "package: name='com\.fanqie\.pure\.reader'" -or $badging -notmatch "application-label:'番茄小说纯净版'") { throw 'Unexpected package identity or application label.' }
if ($badging -notmatch "sdkVersion:'24'" -or $badging -notmatch "targetSdkVersion:'36'") { throw 'Unexpected SDK requirements.' }
$permissions = @([regex]::Matches($badging, "uses-permission: name='([^']+)'") | ForEach-Object { $_.Groups[1].Value })
$allowed = @('android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE', 'android.permission.REQUEST_INSTALL_PACKAGES', 'com.fanqie.pure.reader.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION')
if (@($permissions | Where-Object { $_ -notin $allowed }).Count -ne 0) { throw 'Unexpected Android permissions.' }
$manifest = (& (Join-Path $tools.FullName 'aapt.exe') dump xmltree $apkFile.FullName AndroidManifest.xml) -join "`n"
if ($manifest -match 'E: service ') { throw 'The novel app must not package a background media service.' }
$signature = & (Join-Path $tools.FullName 'apksigner.bat') verify --print-certs $apkFile.FullName
if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
$certificate = @($signature | Where-Object { $_ -match '^Signer #1 certificate SHA-256 digest:' })[0] -replace '^.*digest: ', ''
$report = [ordered]@{
    verifiedAt = [DateTimeOffset]::Now.ToString('o')
    apk = $apkFile.FullName
    sha256 = (Get-FileHash -LiteralPath $apkFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    bytes = $apkFile.Length
    package = 'com.fanqie.pure.reader'
    applicationName = '番茄小说纯净版'
    abis = $abis
    permissions = $permissions
    signingCertificateSha256 = $certificate
    checks = @('ARM64-only native libraries', 'ELF headers', 'no media libraries/artwork', 'GPL asset', 'identity', 'SDK versions', 'permissions', 'no services', 'APK signature')
}
if ($ReportPath) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding utf8
}
Write-Output ($report | ConvertTo-Json -Depth 4)
