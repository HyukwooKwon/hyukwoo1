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
$configPath = Join-Path $tmpRoot 'settings.test-seed-selection-guard.psd1'

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath (Join-Path $reviewRoot '20260414010000.zip') -Value 'one' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $reviewRoot '20260414020000.zip') -Value 'two' -Encoding UTF8

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$baseConfigText = Get-Content -LiteralPath $baseConfigPath -Raw -Encoding UTF8
$escapedWorkRepoRoot = $workRepoRoot.Replace("'", "''")
$configText = $baseConfigText `
    -replace "DefaultSeedWorkRepoRoot = '.*?'", ("DefaultSeedWorkRepoRoot = '" + $escapedWorkRepoRoot + "'") `
    -replace "DefaultSeedReviewInputPath = '.*?'", "DefaultSeedReviewInputPath = ''" `
    -replace "DefaultSeedReviewInputSearchRelativePath = '.*?'", "DefaultSeedReviewInputSearchRelativePath = 'reviewfile'" `
    -replace "DefaultSeedReviewInputFilter = '.*?'", "DefaultSeedReviewInputFilter = '*.zip'"
$configText = $configText -replace 'DefaultSeedReviewInputRequireSingleCandidate = \$false', 'DefaultSeedReviewInputRequireSingleCandidate = $true'
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$request = Get-Content -LiteralPath (Join-Path $runRoot 'pair01\target01\request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest = Get-Content -LiteralPath (Join-Path $runRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestTarget = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Assert-True (-not [string]::IsNullOrWhiteSpace([string]$request.WorkRepoRoot)) 'WorkRepoRoot should still resolve from default config.'
Assert-True ([string]::IsNullOrWhiteSpace([string]$request.ReviewInputPath)) 'ReviewInputPath should stay empty when single-candidate is required and multiple candidates exist.'
Assert-True ([string]$request.ReviewInputSelectionMode -eq 'auto-rejected-multiple') 'request should record multiple-candidate rejection.'
Assert-True ([string]$request.ReviewInputSelectionWarning -eq 'multiple-candidates') 'request should record multiple-candidate warning.'
Assert-True ([int]$request.ReviewInputCandidateCount -eq 2) 'request should record rejected candidate count.'
Assert-True ([string]$manifestTarget.ReviewInputSelectionMode -eq 'auto-rejected-multiple') 'manifest target row should record rejected selection mode.'
Assert-True ([int]$manifestTarget.ReviewInputCandidateCount -eq 2) 'manifest target row should record rejected candidate count.'

Write-Host ('seed selection guard ok: runRoot=' + $runRoot)
