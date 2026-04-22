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

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-PairRunRootResolution'
$foreignCwd = Join-Path $tmpRoot 'foreign-cwd'
$relativeRunRoot = '.\pair-test\bottest-live-visible\run_relative_resolution_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
$expectedRunRoot = Join-Path $root ($relativeRunRoot -replace '^[.][\\/]', '')

New-Item -ItemType Directory -Path $foreignCwd -Force | Out-Null

Push-Location $foreignCwd
try {
    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath (Join-Path $root 'config\settings.bottest-live-visible.psd1') `
        -RunRoot $relativeRunRoot `
        -IncludePairId pair01 `
        -SeedTargetId target01 | Out-Null
}
finally {
    Pop-Location
}

$manifestPath = Join-Path $expectedRunRoot 'manifest.json'
Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'relative RunRoot should resolve from repo root, not current working directory.'

Write-Host ('pair run root resolution ok: ' + $expectedRunRoot)
