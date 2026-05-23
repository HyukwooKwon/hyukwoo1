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
$tmpRoot = Join-Path $externalFixtureRoot 'Test-SeedContextExplicitMissingReviewInputPathFails'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$runRoot = Join-Path $workRepoRoot ('.relay-runs\bottest-live-visible\run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null

$candidateZip = Join-Path $reviewRoot '20260414020000.zip'
$explicitMissingZip = Join-Path $reviewRoot 'explicit-missing.zip'
Set-Content -LiteralPath $candidateZip -Value 'latest' -Encoding UTF8

$generatedPayload = & (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath (Join-Path $root 'config\settings.bottest-live-visible.psd1') `
    -WorkRepoRoot $workRepoRoot `
    -PairId pair01 `
    -AsJson | ConvertFrom-Json
$resolvedConfigPath = [string]$generatedPayload.OutputConfigPath

$failed = $false
$errorText = ''
try {
    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $resolvedConfigPath `
        -RunRoot $runRoot `
        -IncludePairId pair01 `
        -SeedTargetId target01 `
        -SeedReviewInputPath $explicitMissingZip | Out-Null
}
catch {
    $failed = $true
    $errorText = [string]$_.Exception.Message
}

Assert-True $failed 'explicit missing SeedReviewInputPath should fail instead of silently falling back.'
Assert-True (
    $errorText.Contains('Cannot find path') -or
    $errorText.Contains('explicit-missing.zip')
) 'failure should mention the missing explicit review input path.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $runRoot 'manifest.json') -PathType Leaf)) 'manifest should not be created when explicit review input path is missing.'

Write-Host ('seed context explicit missing review input path failed as expected: runRoot=' + $runRoot)
