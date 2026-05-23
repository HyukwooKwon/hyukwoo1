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
$tmpRoot = Join-Path $externalFixtureRoot 'Test-SeedContextMissingDefaultPathFallsBackToLatestCandidate'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$runRoot = Join-Path $workRepoRoot ('.relay-runs\bottest-live-visible\run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null

$olderZip = Join-Path $reviewRoot '20260414010000.zip'
$latestZip = Join-Path $reviewRoot '20260414020000.zip'
$missingConfiguredZip = Join-Path $reviewRoot 'seed_review_input_latest.zip'
Set-Content -LiteralPath $olderZip -Value 'older' -Encoding UTF8
Start-Sleep -Milliseconds 50
Set-Content -LiteralPath $latestZip -Value 'latest' -Encoding UTF8

$generatedPayload = & (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath (Join-Path $root 'config\settings.bottest-live-visible.psd1') `
    -WorkRepoRoot $workRepoRoot `
    -PairId pair01 `
    -ReviewInputPath $missingConfiguredZip `
    -AsJson | ConvertFrom-Json
$resolvedConfigPath = [string]$generatedPayload.OutputConfigPath

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$manifestPath = Join-Path $runRoot 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestTarget = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$requestPath = [string]$manifestTarget.RequestPath
$messagePath = [string]$manifestTarget.MessagePath
$request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$messageText = Get-Content -LiteralPath $messagePath -Raw -Encoding UTF8

Assert-True ([string]$request.WorkRepoRoot -eq $workRepoRoot) 'WorkRepoRoot should still resolve from default config.'
Assert-True ([string]$request.ReviewInputPath -eq $latestZip) 'missing configured default path should fall back to the latest reviewfile candidate.'
Assert-True ([string]$request.ReviewInputSelectionMode -eq 'auto-latest-candidate') 'request should record auto-latest fallback selection mode.'
Assert-True ([int]$request.ReviewInputCandidateCount -eq 2) 'request should record fallback candidate count without the missing configured path.'
Assert-True ([string]$manifestTarget.ReviewInputPath -eq $latestZip) 'manifest target row should carry fallback ReviewInputPath.'
Assert-True ([string]$manifestTarget.ReviewInputSelectionMode -eq 'auto-latest-candidate') 'manifest target row should record fallback selection mode.'
Assert-True ($messageText.Contains('먼저 확인할 파일:')) 'seed message should include review input guidance block.'
Assert-True ($messageText.Contains($latestZip)) 'seed message should include fallback review input file path.'

Write-Host ('seed context missing default path fallback ok: runRoot=' + $runRoot)
