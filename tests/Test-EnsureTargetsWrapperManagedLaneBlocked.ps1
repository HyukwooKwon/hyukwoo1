[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-ensure-targets-wrapper-managed-blocked'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    LaneName = 'bottest-live-visible'
    LauncherWrapperPath = 'C:\dummy\wrapper.py'
    WindowLaunch = @{
        DirectStartAllowed = `$false
        AllowReplaceExisting = `$false
        DirectStartAllowEnvVar = 'TEST_BLOCK_DIRECT_ENSURE'
        ReplaceExistingAllowEnvVar = 'TEST_BLOCK_REPLACE_ENSURE'
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$result = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'launcher\Ensure-Targets.ps1') -ConfigPath $configPath 2>&1
Assert-True ($LASTEXITCODE -ne 0) 'Ensure-Targets should fail for wrapper-managed lanes that disallow direct ensure.'
$text = ($result | Out-String)
Assert-True ($text -like '*Direct Ensure-Targets is blocked for wrapper-managed lanes*') 'Ensure-Targets block message should mention wrapper-managed direct start policy.'

Write-Host 'ensure-targets wrapper-managed direct launch blocked ok'
