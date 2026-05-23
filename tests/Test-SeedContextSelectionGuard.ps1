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
$tmpRoot = Join-Path $externalFixtureRoot 'Test-SeedContextSelectionGuard'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$runRoot = Join-Path $workRepoRoot ('.relay-runs\bottest-live-visible\run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath (Join-Path $reviewRoot '20260414010000.zip') -Value 'one' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $reviewRoot '20260414020000.zip') -Value 'two' -Encoding UTF8

$generatedPayload = & (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath (Join-Path $root 'config\settings.bottest-live-visible.psd1') `
    -WorkRepoRoot $workRepoRoot `
    -PairId pair01 `
    -ReviewInputPath '' `
    -DefaultSeedReviewInputRequireSingleCandidate:$true `
    -AsJson | ConvertFrom-Json
$resolvedConfigPath = [string]$generatedPayload.OutputConfigPath

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$manifest = Get-Content -LiteralPath (Join-Path $runRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestTarget = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$request = Get-Content -LiteralPath ([string]$manifestTarget.RequestPath) -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-True (-not [string]::IsNullOrWhiteSpace([string]$request.WorkRepoRoot)) 'WorkRepoRoot should still resolve from default config.'
Assert-True ([string]::IsNullOrWhiteSpace([string]$request.ReviewInputPath)) 'ReviewInputPath should stay empty when single-candidate is required and multiple candidates exist.'
Assert-True ([string]$request.ReviewInputSelectionMode -eq 'auto-rejected-multiple') 'request should record multiple-candidate rejection.'
Assert-True ([string]$request.ReviewInputSelectionWarning -eq 'multiple-candidates') 'request should record multiple-candidate warning.'
Assert-True ([int]$request.ReviewInputCandidateCount -eq 2) 'request should record rejected candidate count.'
Assert-True ([string]$manifestTarget.ReviewInputSelectionMode -eq 'auto-rejected-multiple') 'manifest target row should record rejected selection mode.'
Assert-True ([int]$manifestTarget.ReviewInputCandidateCount -eq 2) 'manifest target row should record rejected candidate count.'

Write-Host ('seed selection guard ok: runRoot=' + $runRoot)
