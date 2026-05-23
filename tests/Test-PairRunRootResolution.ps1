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
$externalFixtureRoot = 'C:\dev\python\_relay-test-fixtures'
$tmpRoot = Join-Path $externalFixtureRoot 'Test-PairRunRootResolution'
$foreignCwd = Join-Path $tmpRoot 'foreign-cwd'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$reviewInputPath = Join-Path $reviewRoot 'seed-input.zip'
$relativeRunRoot = '..\..\_relay-test-fixtures\Test-PairRunRootResolution\work-repo\.relay-runs\bottest-live-visible\run_relative_resolution_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
$expectedRunRoot = Join-Path $root ($relativeRunRoot -replace '^[.][\\/]', '')

New-Item -ItemType Directory -Path $foreignCwd -Force | Out-Null
New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath $reviewInputPath -Value 'seed-input' -Encoding UTF8
$generatedPayload = & (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath (Join-Path $root 'config\settings.bottest-live-visible.psd1') `
    -WorkRepoRoot $workRepoRoot `
    -ReviewInputPath $reviewInputPath `
    -PairId pair01 `
    -AsJson | ConvertFrom-Json
$resolvedConfigPath = [string]$generatedPayload.OutputConfigPath

Push-Location $foreignCwd
try {
    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $resolvedConfigPath `
        -RunRoot $relativeRunRoot `
        -IncludePairId pair01 `
        -SeedTargetId target01 `
        -SeedWorkRepoRoot $workRepoRoot `
        -SeedReviewInputPath $reviewInputPath | Out-Null
}
finally {
    Pop-Location
}

$manifestPath = Join-Path ([System.IO.Path]::GetFullPath($expectedRunRoot)) 'manifest.json'
Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'relative RunRoot should resolve from repo root, not current working directory.'

Write-Host ('pair run root resolution ok: ' + [System.IO.Path]::GetFullPath($expectedRunRoot))
