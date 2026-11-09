#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Repository = 'GodBook/fanqie-pure-reader',
    [string]$ApkPath = '',
    [Parameter(Mandatory)][string]$NotesFile
)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
if (-not $ApkPath) { $ApkPath = Join-Path $sourceRoot 'dist/fanqie-pure-release-arm64.apk' }
$versionLine = Get-Content -LiteralPath (Join-Path $sourceRoot 'pubspec.yaml') | Where-Object { $_ -match '^version:' }
if ($versionLine -notmatch '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'Expected a version and integer build number.' }
$releaseVersion = $Matches[1]
$releaseCode = [int]$Matches[2]
$tag = "v$releaseVersion"
if ($Repository -ne 'GodBook/fanqie-pure-reader') { throw 'Update service is pinned to GodBook/fanqie-pure-reader. Change the app identity before publishing elsewhere.' }
if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) { throw 'Provide saved public release notes.' }
$notes = Get-Content -LiteralPath $NotesFile -Raw
$apk = Get-Item -LiteralPath $ApkPath
$report = & (Join-Path $PSScriptRoot 'verify_novel_apk.ps1') -ApkPath $apk.FullName | ConvertFrom-Json
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $env:ANDROID_SDK_ROOT }
$buildTools = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory | Where-Object Name -Match '^\d+\.\d+\.\d+$' | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$badging = (& (Join-Path $buildTools.FullName 'aapt.exe') dump badging $apk.FullName) -join "`n"
if ($badging -notmatch "versionCode='$releaseCode'" -or $badging -notmatch "versionName='$releaseVersion'") { throw 'APK version differs from pubspec.yaml.' }
$staging = Join-Path $sourceRoot "build/public-release/$tag"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$assetName = "fanqie-pure-$releaseVersion-arm64.apk"
$asset = Join-Path $staging $assetName
Copy-Item -LiteralPath $apk.FullName -Destination $asset -Force
$manifest = [ordered]@{
    schema = 1; package = 'com.fanqie.pure.reader'; abi = 'arm64-v8a'
    version = $releaseVersion; versionCode = $releaseCode; bytes = $report.bytes
    sha256 = $report.sha256
    apkUrl = "https://github.com/$Repository/releases/download/$tag/$assetName"
    notes = $notes.Trim()
}
$manifestFile = Join-Path $staging 'update.json'
$checksumFile = Join-Path $staging 'SHA256SUMS'
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestFile -Encoding utf8NoBOM
"$($report.sha256)  $assetName" | Set-Content -LiteralPath $checksumFile -Encoding utf8NoBOM
& gh release create $tag $asset $manifestFile $checksumFile --repo $Repository --draft --title "番茄小说纯净版 $releaseVersion" --notes-file $NotesFile
if ($LASTEXITCODE -ne 0) { throw 'Draft creation/upload failed. Inspect GitHub before retrying.' }
& gh release edit $tag --repo $Repository --draft=false --latest
if ($LASTEXITCODE -ne 0) { throw 'Assets are uploaded but publication failed. Inspect the draft.' }
