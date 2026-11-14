#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('debug', 'profile', 'release')][string]$BuildMode = 'release',
    [string]$JdkRoot = 'D:\dev\jdk-17',
    [string]$BuildRoot = 'D:\dev\fanqie-pure',
    [string]$DartTarget = 'lib/main.dart',
    [switch]$RebuildNative,
    [switch]$AcceptancePackage,
    [switch]$UpdateBootstrap
)

$ErrorActionPreference = 'Stop'
if ($AcceptancePackage -and $BuildMode -ne 'release') { throw 'AcceptancePackage requires release mode.' }
if ($UpdateBootstrap -and ($BuildMode -ne 'release' -or $AcceptancePackage)) { throw 'UpdateBootstrap requires the production package in release mode.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectItem = Get-Item -LiteralPath $projectRoot
$physicalProjectRoot = if ($projectItem.LinkType -eq 'Junction') { [string]@($projectItem.Target)[0] } else { $projectItem.FullName }
if (-not (Test-Path -LiteralPath (Join-Path $JdkRoot 'bin\java.exe'))) {
    throw "JDK 17 not found at $JdkRoot. Pass -JdkRoot with its actual directory."
}
if (-not (Test-Path -LiteralPath $BuildRoot)) {
    New-Item -ItemType Junction -Path $BuildRoot -Target $projectRoot | Out-Null
}
$link = Get-Item -LiteralPath $BuildRoot
if ($link.LinkType -eq 'Junction' -and ([string]@($link.Target)[0]).TrimEnd('\') -ne $physicalProjectRoot.TrimEnd('\')) {
    throw 'BuildRoot belongs to a different project. Choose another -BuildRoot.'
}
if (-not (Test-Path -LiteralPath (Join-Path $BuildRoot 'pubspec.yaml'))) {
    throw 'BuildRoot does not contain the novel project.'
}

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}

$environmentKeys = @('JAVA_HOME', 'PATH', 'NOVEL_SIGNING_PASSWORD', 'RELEASE_KEYSTORE_FILE',
    'RELEASE_STORE_PASSWORD', 'RELEASE_KEY_ALIAS', 'RELEASE_KEY_PASSWORD', 'FQAPP_ACCEPTANCE_SUFFIX', 'FQAPP_UPDATE_BOOTSTRAP')
$previousEnvironment = @{}
foreach ($name in $environmentKeys) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

Push-Location -LiteralPath $BuildRoot
try {
    $env:JAVA_HOME = $JdkRoot
    $env:FQAPP_ACCEPTANCE_SUFFIX = if ($AcceptancePackage) { '.benchmark' } else { $null }
    $env:FQAPP_UPDATE_BOOTSTRAP = if ($UpdateBootstrap) { 'true' } else { $null }
    $env:PATH = (Join-Path $JdkRoot 'bin') + ';' + $env:PATH
    Invoke-Checked 'flutter' @('--no-version-check', 'pub', 'get')
    if ($RebuildNative -or -not (Test-Path 'android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so')) {
        & (Join-Path $projectRoot 'scripts/build_rust_backend.ps1') -SkipCodegen
        if ($LASTEXITCODE -ne 0) { throw 'Rust native build failed' }
    }

    if ($BuildMode -eq 'release') {
        # Stable local signing identity, isolated from other projects. The
        # password is protected with Windows DPAPI for the current user.
        $signingDir = Join-Path $env:LOCALAPPDATA 'FanqiePure\signing'
        New-Item -ItemType Directory -Force -Path $signingDir | Out-Null
        $keystore = Join-Path $signingDir 'reader.p12'
        $passwordFile = Join-Path $signingDir 'password.xml'
        if (Test-Path -LiteralPath $keystore) {
            if (-not (Test-Path -LiteralPath $passwordFile)) { throw 'Signing key exists but its protected password is missing.' }
            $securePassword = Import-Clixml -LiteralPath $passwordFile
        } else {
            $randomPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
            $securePassword = ConvertTo-SecureString $randomPassword -AsPlainText -Force
            $securePassword | Export-Clixml -LiteralPath $passwordFile
            $env:NOVEL_SIGNING_PASSWORD = $randomPassword
            Invoke-Checked (Join-Path $JdkRoot 'bin/keytool.exe') @('-genkeypair', '-keystore', $keystore,
                '-alias', 'novel-reader', '-storetype', 'PKCS12', '-keyalg', 'RSA', '-keysize', '3072',
                '-validity', '10000', '-dname', 'CN=Fanqie Pure Reader',
                '-storepass:env', 'NOVEL_SIGNING_PASSWORD', '-keypass:env', 'NOVEL_SIGNING_PASSWORD')
        }
        $env:RELEASE_KEYSTORE_FILE = $keystore
        $env:RELEASE_STORE_PASSWORD = [Net.NetworkCredential]::new('', $securePassword).Password
        $env:RELEASE_KEY_PASSWORD = $env:RELEASE_STORE_PASSWORD
        $env:RELEASE_KEY_ALIAS = 'novel-reader'
    }

    # Bind the compiler action to actual Dart sources, including after tests.
    $sourceManifest = @(@(Get-ChildItem -LiteralPath (Join-Path $BuildRoot 'lib') -Recurse -File -Filter '*.dart') +
        @(Get-Item -LiteralPath (Join-Path $BuildRoot 'pubspec.yaml')) | Sort-Object FullName | ForEach-Object {
            [pscustomobject]@{
                path = [IO.Path]::GetRelativePath($BuildRoot, $_.FullName).Replace('\', '/')
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
    $sourceCanonical = ($sourceManifest | ForEach-Object { $_.path + "`t" + $_.sha256 }) -join "`n"
    $sourceDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceCanonical))).ToLowerInvariant()
    # Flutter prepares production-only plugin registration for release; calling
    # Gradle directly after a widget test can leave dev-only plugins registered.
    Invoke-Checked 'flutter' @('--no-version-check', 'build', 'apk', "--$BuildMode",
        '--target-platform', 'android-arm64', '--target', $DartTarget, "--dart-define=FQAPP_SOURCE_DIGEST=$sourceDigest")

    $apk = Join-Path $BuildRoot "build/app/outputs/flutter-apk/app-$BuildMode.apk"
    if (-not (Test-Path -LiteralPath $apk)) { throw 'Gradle completed without the expected APK.' }
    foreach ($sourceEntry in $sourceManifest) {
        if ((Get-FileHash -LiteralPath (Join-Path $BuildRoot $sourceEntry.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceEntry.sha256) {
            throw "Source changed during build: $($sourceEntry.path). Rebuild the final source."
        }
    }
    if ($BuildMode -eq 'release' -and -not $AcceptancePackage) {
        & (Join-Path $projectRoot 'scripts/verify_novel_apk.ps1') -ApkPath $apk -ReportPath (Join-Path $BuildRoot 'build/novel-validation/package.json')
    }
    $distribution = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Force -Path $distribution | Out-Null
    $outputKind = if ($AcceptancePackage) { 'benchmark' } elseif ($UpdateBootstrap) { 'update-bootstrap' } else { $BuildMode }
    $destination = Join-Path $distribution "fanqie-pure-$outputKind-arm64.apk"
    Copy-Item -LiteralPath $apk -Destination $destination -Force
    $hash = Get-FileHash -LiteralPath $destination -Algorithm SHA256
    $bindingDirectory = Join-Path $BuildRoot 'build/novel-validation'
    New-Item -ItemType Directory -Path $bindingDirectory -Force | Out-Null
    [pscustomobject]@{ target = $DartTarget; mode = $BuildMode; sourceDigest = $sourceDigest;
        sourceFiles = $sourceManifest; apk = $destination; sha256 = $hash.Hash.ToLowerInvariant() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bindingDirectory 'build-source-binding.json') -Encoding utf8
    "$($hash.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($destination))" |
        Set-Content -LiteralPath (Join-Path $distribution "$outputKind-SHA256SUMS") -Encoding utf8
    Write-Host "APK: $destination"
    Write-Host "SHA256: $($hash.Hash.ToLowerInvariant())"
} finally {
    Pop-Location
    foreach ($name in $environmentKeys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name]) }
}
