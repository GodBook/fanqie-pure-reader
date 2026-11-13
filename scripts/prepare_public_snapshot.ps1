#requires -Version 7.2
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$targetRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
if (Test-Path -LiteralPath $targetRoot) { throw 'Choose a new, empty destination for the public snapshot.' }
if ($targetRoot.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $targetRoot -eq $sourceRoot) { throw 'Destination must be separate from the source checkout.' }
$allowedRoots = @('lib', 'android', 'assets', 'rust', 'native', 'third_party', 'test', 'integration_test', 'test_driver', 'scripts', 'linux', 'windows', 'ios', 'macos', 'web', '.cargo')
$allowedFiles = @('.gitattributes', '.gitignore', '.metadata', 'LICENSE', 'README.md', 'UPSTREAM_README.md', 'RELEASING.md', 'CHANGELOG.md', 'analysis_options.yaml', 'pubspec.yaml', 'pubspec.lock', 'flutter_rust_bridge.yaml')
$files = @(& git -C $sourceRoot -c core.quotepath=false ls-files --cached --others --exclude-standard | Sort-Object -Unique | Where-Object {
    $root = ($_ -split '/')[0]
    ($root -in $allowedRoots -or $_ -in $allowedFiles -or $_ -eq '.github/workflows/novel-checks.yml') -and
    $_ -notmatch '(?i)(device_pool\.json$|keystore\.properties$|local\.properties$|\.(p12|jks|keystore|pepk|hive|db|apk|aab|so|log)$|(^|/)(build|target|\.dart_tool|\.gradle|\.cxx)/)'
})
if ($LASTEXITCODE -ne 0 -or $files.Count -lt 500) { throw 'Source inventory failed.' }
$blocked = @()
foreach ($relative in $files) {
    $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relative))
    if (-not $source.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid source path.' }
    $item = Get-Item -LiteralPath $source
    if ($item.Length -gt 50MB) { throw "Oversized source asset: $relative" }
    if ($item.Extension -in @('.dart', '.kt', '.kts', '.ps1', '.sh', '.json', '.yaml', '.yml', '.toml', '.md', '.xml')) {
        $content = Get-Content -LiteralPath $source -Raw
        if ($content -match '(?i)(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|C:\\Users\\(?!Public\b|Default\b)[A-Za-z0-9_-]+\\|adb\s+-s\s+[A-Za-z0-9]{8,})') { $blocked += $relative }
    }
}
if ($blocked.Count) { throw "Private material found; inspect: $($blocked -join ', ')" }
New-Item -ItemType Directory -Path $targetRoot | Out-Null
foreach ($relative in $files) {
    $target = Join-Path $targetRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $target
}
Write-Output "Prepared $($files.Count) source files; no original Git history, local project records, device pools, private caches or signing keys."
