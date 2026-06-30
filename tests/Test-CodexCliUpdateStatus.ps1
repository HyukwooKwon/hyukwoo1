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

function Assert-Equal {
    param(
        [AllowNull()]$Expected,
        [AllowNull()]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ($Message + " expected=" + [string]$Expected + " actual=" + [string]$Actual)
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'launcher\Get-CodexCliUpdateStatus.ps1'
$tempRoot = Join-Path $root '_tmp\test-codex-cli-update-status'
$sideBySideRoot = Join-Path $tempRoot 'versions'
$installRoot = Join-Path $sideBySideRoot '1.2.3'
$packageJson = Join-Path $installRoot 'node_modules\@openai\codex\package.json'
$shimPath = Join-Path $installRoot 'node_modules\.bin\codex.ps1'

New-Item -ItemType Directory -Path (Split-Path -Parent $packageJson) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $shimPath) -Force | Out-Null
[System.IO.File]::WriteAllText(
    $packageJson,
    '{"name":"@openai/codex","version":"1.2.3"}',
    (New-Utf8NoBomEncoding)
)
[System.IO.File]::WriteAllText(
    $shimPath,
    "Write-Output 'codex-cli 1.2.3'`n",
    (New-Utf8NoBomEncoding)
)

$payload = & $scriptPath `
    -SideBySideRoot $sideBySideRoot `
    -LatestVersionOverride '1.2.3' `
    -SkipNpmView `
    -AsJson |
    ConvertFrom-Json

Assert-Equal 1 $payload.SchemaVersion 'schema version mismatch'
Assert-True ([bool]$payload.IsReadOnly) 'diagnostic should be read-only'
Assert-Equal '1.2.3' $payload.LatestVersion 'latest override mismatch'
Assert-Equal 'override' $payload.LatestVersionSource 'latest source mismatch'
Assert-True ([bool]$payload.SideBySideLatestAvailable) 'side-by-side latest install should be detected'
Assert-True ([string]$payload.RecommendedTargetLaunchCommand -like '*codex.ps1*') 'recommended launch command should use powershell shim'
Assert-True ($payload.CodexProcessCount -ge 0) 'codex process count should be numeric'
Assert-True ($payload.GlobalPackageProcessCount -ge 0) 'global package process count should be numeric'

Write-Host 'codex cli update status contract ok'
