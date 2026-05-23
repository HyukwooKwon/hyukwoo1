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

$pairPolicyRequired = [pscustomobject]@{
    PairId = 'pair01'
    RequireExternalSeedWorkRepo = $true
}

$pairTestRequired = [pscustomobject]@{
    RequireExternalSeedWorkRepo = $true
}

$disabledByPairPolicy = Test-SeedWorkRepoPolicy `
    -PairTest $pairTestRequired `
    -PairPolicy ([pscustomobject]@{
        PairId = 'pair01'
        RequireExternalSeedWorkRepo = $false
    }) `
    -AutomationRoot $root `
    -WorkRepoRoot ''
Assert-True ([bool]$disabledByPairPolicy.Passed) 'pair policy false should bypass external seed work repo enforcement.'

$emptyWorkRepoRoot = Test-SeedWorkRepoPolicy `
    -PairTest $pairTestRequired `
    -PairPolicy $pairPolicyRequired `
    -AutomationRoot $root `
    -WorkRepoRoot ''
Assert-True (-not [bool]$emptyWorkRepoRoot.Passed) 'empty work repo root should fail when external seed work repo is required.'
Assert-True ([string]$emptyWorkRepoRoot.Reason -eq 'external-workrepo-required') 'empty work repo root should use external-workrepo-required.'

$automationRepoWorkRepo = Test-SeedWorkRepoPolicy `
    -PairTest $pairTestRequired `
    -PairPolicy $pairPolicyRequired `
    -AutomationRoot $root `
    -WorkRepoRoot $root
Assert-True (-not [bool]$automationRepoWorkRepo.Passed) 'automation repo work repo should fail when external seed work repo is required.'
Assert-True ([string]$automationRepoWorkRepo.Reason -eq 'automation-repo-workrepo-disallowed') 'automation repo work repo should use automation-repo-workrepo-disallowed.'

$automationRepoReviewInput = Test-SeedWorkRepoPolicy `
    -PairTest $pairTestRequired `
    -PairPolicy $pairPolicyRequired `
    -AutomationRoot $root `
    -WorkRepoRoot 'C:\dev\python\relay-workrepo-visible-smoke' `
    -ReviewInputPath (Join-Path $root 'README.md')
Assert-True (-not [bool]$automationRepoReviewInput.Passed) 'review input inside automation repo should fail when external seed work repo is required.'
Assert-True ([string]$automationRepoReviewInput.Reason -eq 'automation-repo-reviewinput-disallowed') 'review input inside automation repo should use automation-repo-reviewinput-disallowed.'

$externalRepo = Test-SeedWorkRepoPolicy `
    -PairTest $pairTestRequired `
    -PairPolicy $pairPolicyRequired `
    -AutomationRoot $root `
    -WorkRepoRoot 'C:\dev\python\relay-workrepo-visible-smoke' `
    -ReviewInputPath 'C:\dev\python\relay-workrepo-visible-smoke\reviewfile\seed.zip'
Assert-True ([bool]$externalRepo.Passed) 'external work repo and review input should pass.'

Write-Host 'seed work repo policy ok'
