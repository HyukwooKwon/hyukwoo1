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
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$runRoot = Join-Path $root '_tmp\Test-StartPairedExchangeTestRejectsAutomationRepoRunRoot'
$externalWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
$externalReviewInputPath = Join-Path $externalWorkRepoRoot 'reviewfile\seed_review_input_latest.zip'
if (Test-Path -LiteralPath $runRoot) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
}

$output = @(
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -IncludePairId pair01 `
        -SeedTargetId target01 `
        -SeedWorkRepoRoot $externalWorkRepoRoot `
        -SeedReviewInputPath $externalReviewInputPath 2>&1
)
$exitCode = $LASTEXITCODE

Assert-True ($exitCode -ne 0) 'Start-PairedExchangeTest should reject automation repo as run root.'
$detail = ($output | Out-String)
Assert-True ($detail.Contains('automation-repo-runroot-disallowed')) 'failure output should mention automation-repo-runroot-disallowed.'

Write-Host 'start-paired-exchange-test external run root guard ok'
