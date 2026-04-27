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
$tmpRoot = Join-Path $externalFixtureRoot 'Test-RunLiveVisiblePairAcceptanceRejectsAutomationRepoBookkeepingRoots'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$reviewInputPath = Join-Path $reviewRoot 'seed-input.zip'

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath $reviewInputPath -Value 'seed-input' -Encoding UTF8

$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$output = @(
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1') `
        -ConfigPath $configPath `
        -PairId pair01 `
        -SeedTargetId target01 `
        -SeedWorkRepoRoot $workRepoRoot `
        -SeedReviewInputPath $reviewInputPath `
        -PreflightOnly `
        -AsJson 2>&1
)
$exitCode = $LASTEXITCODE

Assert-True ($exitCode -ne 0) 'Run-LiveVisiblePairAcceptance should reject bookkeeping roots that still point into the automation repo.'
$detail = ($output | Out-String)
Assert-True ($detail.Contains('automation-repo-bookkeeping-roots-disallowed')) 'failure output should mention automation-repo-bookkeeping-roots-disallowed.'

Write-Host 'run-live-visible-pair-acceptance bookkeeping roots guard ok'
