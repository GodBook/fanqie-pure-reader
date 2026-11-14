#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$JdkRoot = 'D:\dev\jdk-17',
    [string]$BuildRoot = 'D:\dev\fanqie-pure'
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'test_novel_resume_safety.ps1') -JdkRoot $JdkRoot -BuildRoot $BuildRoot `
    -DartTarget 'integration_test/novel_features_live_test.dart' `
    -Driver 'test_driver/novel_features_live.dart'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
