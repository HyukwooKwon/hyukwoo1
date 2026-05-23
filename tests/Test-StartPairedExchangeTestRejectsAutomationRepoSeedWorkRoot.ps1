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
. (Join-Path $root 'tests\lib\ConfigMutationHelpers.ps1')
$externalFixtureRoot = 'C:\dev\python\_relay-test-fixtures'
$tmpRoot = Join-Path $externalFixtureRoot 'Test-StartPairedExchangeTestRejectsAutomationRepoSeedWorkRoot'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$configPath = Join-Path $tmpRoot 'settings.seed-workrepo-guard.psd1'
$runRoot = Join-Path $workRepoRoot '.relay-runs\bottest-live-visible\run_guard'
if (Test-Path -LiteralPath $runRoot) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRepoRoot -Force | Out-Null

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$baseConfigText = Get-Content -LiteralPath $baseConfigPath -Raw -Encoding UTF8
$configText = Set-BooleanPairPolicyAssignment -Text $baseConfigText -PairId 'pair01' -Name 'UseExternalWorkRepoRunRoot' -Value $false
$configText = Set-BooleanPairPolicyAssignment -Text $configText -PairId 'pair01' -Name 'RequireExternalRunRoot' -Value $false
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

$output = @(
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -IncludePairId pair01 `
        -SeedTargetId target01 `
        -SeedWorkRepoRoot $root `
        -SeedReviewInputPath (Join-Path $root 'README.md') 2>&1
)
$exitCode = $LASTEXITCODE

Assert-True ($exitCode -ne 0) 'Start-PairedExchangeTest should reject automation repo as seed work repo.'
$detail = ($output | Out-String)
Assert-True (
    $detail.Contains('automation-repo-workrepo-disallowed') -or
    $detail.Contains('bookkeeping-root-outside-workrepo')
) 'failure output should mention either the direct seed work repo guard or the downstream bookkeeping root guard.'

Write-Host 'start-paired-exchange-test external work repo guard ok'
