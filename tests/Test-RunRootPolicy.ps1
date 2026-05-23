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
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

$pairTest = [pscustomobject]@{
    RequireExternalRunRoot = $true
    ExternalWorkRepoRunRootRelativeRoot = '.relay-runs\bottest-live-visible'
}
$pairPolicy = [pscustomobject]@{
    PairId = 'pair01'
    RequireExternalRunRoot = $true
}

$emptyRunRoot = Test-RunRootPolicy `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -AutomationRoot $root `
    -RunRoot '' `
    -WorkRepoRoot 'C:\dev\python\relay-workrepo-visible-smoke'
Assert-True (-not [bool]$emptyRunRoot.Passed) 'empty run root should fail when external run root is required.'
Assert-True ([string]$emptyRunRoot.Reason -eq 'external-runroot-required') 'empty run root should use external-runroot-required.'

$emptyWorkRepoRoot = Test-RunRootPolicy `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -AutomationRoot $root `
    -RunRoot 'C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible\run_x' `
    -WorkRepoRoot ''
Assert-True (-not [bool]$emptyWorkRepoRoot.Passed) 'empty work repo root should fail when external run root is required.'
Assert-True ([string]$emptyWorkRepoRoot.Reason -eq 'external-runroot-workrepo-required') 'empty work repo root should use external-runroot-workrepo-required.'

$automationRepoRunRoot = Test-RunRootPolicy `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -AutomationRoot $root `
    -RunRoot (Join-Path $root '_tmp\runroot-policy-test') `
    -WorkRepoRoot 'C:\dev\python\relay-workrepo-visible-smoke'
Assert-True (-not [bool]$automationRepoRunRoot.Passed) 'automation repo run root should fail.'
Assert-True ([string]$automationRepoRunRoot.Reason -eq 'automation-repo-runroot-disallowed') 'automation repo run root should use automation-repo-runroot-disallowed.'

$outsideWorkRepo = Test-RunRootPolicy `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -AutomationRoot $root `
    -RunRoot 'C:\dev\python\another-work-repo\.relay-runs\bottest-live-visible\run_x' `
    -WorkRepoRoot 'C:\dev\python\relay-workrepo-visible-smoke'
Assert-True (-not [bool]$outsideWorkRepo.Passed) 'run root outside WorkRepoRoot should fail.'
Assert-True ([string]$outsideWorkRepo.Reason -eq 'external-runroot-outside-workrepo') 'outside work repo run root should use external-runroot-outside-workrepo.'

$insideWorkRepo = Test-RunRootPolicy `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -AutomationRoot $root `
    -RunRoot 'C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible\run_x' `
    -WorkRepoRoot 'C:\dev\python\relay-workrepo-visible-smoke'
Assert-True ([bool]$insideWorkRepo.Passed) 'run root inside WorkRepoRoot should pass.'

$coordinatorRunRoot = 'C:\dev\python\repo-coordinator\.relay-runs\bottest-live-visible\run_coord'
$resolvedCoordinatorRoot = Resolve-ExternalRunRootOwnerRoot `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -RunRoot $coordinatorRunRoot `
    -WorkRepoRoot 'C:\dev\python\repo-a'
Assert-True ([string]$resolvedCoordinatorRoot -eq 'C:\dev\python\repo-coordinator') 'coordinator owner root should resolve from external run root relative base.'

$coordinatorPolicy = Test-RunRootPolicy `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -AutomationRoot $root `
    -RunRoot $coordinatorRunRoot `
    -WorkRepoRoot $resolvedCoordinatorRoot
Assert-True ([bool]$coordinatorPolicy.Passed) 'coordinator run root should pass when validated against resolved owner root.'

Write-Host 'run root policy ok'
