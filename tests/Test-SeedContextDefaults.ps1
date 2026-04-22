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
$tmpRoot = Join-Path $root '_tmp\Test-SeedContextDefaults'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $tmpRoot 'settings.test-seed-defaults.psd1'

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null

$olderZip = Join-Path $reviewRoot '20260414010000.zip'
$latestZip = Join-Path $reviewRoot '20260414020000.zip'
Set-Content -LiteralPath $olderZip -Value 'older' -Encoding UTF8
Start-Sleep -Milliseconds 50
Set-Content -LiteralPath $latestZip -Value 'latest' -Encoding UTF8

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$baseConfigText = Get-Content -LiteralPath $baseConfigPath -Raw -Encoding UTF8
$escapedWorkRepoRoot = $workRepoRoot.Replace("'", "''")
$configText = $baseConfigText `
    -replace "DefaultSeedWorkRepoRoot = '.*?'", ("DefaultSeedWorkRepoRoot = '" + $escapedWorkRepoRoot + "'") `
    -replace "DefaultSeedReviewInputSearchRelativePath = '.*?'", "DefaultSeedReviewInputSearchRelativePath = 'reviewfile'" `
    -replace "DefaultSeedReviewInputFilter = '.*?'", "DefaultSeedReviewInputFilter = '*.zip'"
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$requestPath = Join-Path $runRoot 'pair01\target01\request.json'
$messagePath = Join-Path $runRoot 'messages\target01.txt'
$manifestPath = Join-Path $runRoot 'manifest.json'
$request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestTarget = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$messageText = Get-Content -LiteralPath $messagePath -Raw -Encoding UTF8

Assert-True ([string]$request.WorkRepoRoot -eq $workRepoRoot) 'default seed WorkRepoRoot should be resolved from PairTest config.'
Assert-True ([string]$request.ReviewInputPath -eq $latestZip) 'default seed ReviewInputPath should resolve to latest zip in configured review folder.'
Assert-True ([string]$request.ReviewInputSelectionMode -eq 'auto-latest-candidate') 'request should record auto-latest selection mode.'
Assert-True ([int]$request.ReviewInputCandidateCount -eq 2) 'request should record candidate count.'
Assert-True ([string]$request.ReviewInputSearchRoot -eq $reviewRoot) 'request should record selection search root.'
Assert-True ([string]$manifest.SeedReviewInputSelection.SelectionMode -eq 'auto-latest-candidate') 'manifest should record seed selection mode.'
Assert-True ([int]$manifest.SeedReviewInputSelection.CandidateCount -eq 2) 'manifest should record seed candidate count.'
Assert-True ([string]$manifestTarget.ReviewInputSelectionMode -eq 'auto-latest-candidate') 'manifest target row should record selection mode.'
Assert-True ($messageText.Contains("WorkRepoRoot: $workRepoRoot")) 'seed message should include default WorkRepoRoot.'
Assert-True ($messageText.Contains("ReviewInputPath: $latestZip")) 'seed message should include default ReviewInputPath.'

Write-Host ('seed context defaults ok: runRoot=' + $runRoot)
