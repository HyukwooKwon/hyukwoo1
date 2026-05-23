[CmdletBinding()]
param(
    [string]$ConfigPath
)

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
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedBaseConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$payload = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Write-PairExternalizedRelayConfigs.ps1') `
    -BaseConfigPath $resolvedBaseConfigPath `
    -PairId pair01 `
    -AsJson | ConvertFrom-Json

$generated = @($payload.GeneratedConfigs | Select-Object -First 1)[0]
Assert-True ($null -ne $generated) 'Expected one generated externalized config.'

$resolvedConfigPath = [string]$generated.OutputConfigPath
$workRepoRoot = [string]$generated.WorkRepoRoot
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId 'pair01'

$evidence = @(Get-BookkeepingResidualRootsEvidence -Config $config -BasePath $root)
$evidenceNames = @($evidence | ForEach-Object { [string]$_.Name })
foreach ($requiredName in @(
        'RouterStatePath',
        'BindingProfilePath',
        'PairActivation.StatePath',
        'PairTest.VisibleWorker.QueueRoot',
        'PairTest.VisibleWorker.StatusRoot',
        'PairTest.VisibleWorker.LogRoot',
        'TargetAutoloop.RunRootBase',
        'TargetAutoloop.StatusRoot',
        'TargetAutoloop.QueueRoot',
        'Targets.target01.Folder'
    )) {
    Assert-True ($evidenceNames -contains $requiredName) ("bookkeeping evidence should include {0}" -f $requiredName)
}

$policyPassed = Test-BookkeepingRootsPolicy `
    -Config $config `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -AutomationRoot $root `
    -BasePath $root `
    -WorkRepoRoot $workRepoRoot
Assert-True ([bool]$policyPassed.Passed) 'externalized config should satisfy bookkeeping root policy before mutation.'

$mutatedConfigPath = Join-Path (Split-Path -Parent $resolvedConfigPath) 'settings.externalized.routerstate-internal.psd1'
$internalRouterStatePath = (Join-Path $root 'runtime\bottest-live-visible\router-state.json')
$escapedInternalRouterStatePath = $internalRouterStatePath.Replace("'", "''")
$configText = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$configText = [regex]::Replace(
    $configText,
    "(?m)(RouterStatePath\s*=\s*)'.*?'",
    {
        param($match)
        return ($match.Groups[1].Value + "'" + $escapedInternalRouterStatePath + "'")
    },
    1
)
Set-Content -LiteralPath $mutatedConfigPath -Value $configText -Encoding UTF8

$mutatedConfig = Import-PowerShellDataFile -Path $mutatedConfigPath
$mutatedPairTest = Resolve-PairTestConfig -Root $root -ConfigPath $mutatedConfigPath
$mutatedPairPolicy = Get-PairPolicyForPair -PairTest $mutatedPairTest -PairId 'pair01'
$mutatedPolicyResult = Test-BookkeepingRootsPolicy `
    -Config $mutatedConfig `
    -PairTest $mutatedPairTest `
    -PairPolicy $mutatedPairPolicy `
    -AutomationRoot $root `
    -BasePath $root `
    -WorkRepoRoot $workRepoRoot

Assert-True (-not [bool]$mutatedPolicyResult.Passed) 'router-state path inside automation repo should fail bookkeeping root policy.'
Assert-True ([string]$mutatedPolicyResult.Reason -eq 'automation-repo-bookkeeping-roots-disallowed') 'router-state policy failure should use automation repo bookkeeping reason.'
Assert-True ([string]$mutatedPolicyResult.Detail -like '*RouterStatePath*') 'router-state policy failure detail should mention RouterStatePath.'

$contractOnlyConfig = [pscustomobject]@{
    RouterStatePath = $internalRouterStatePath
}
$contractOnlyPairTest = [pscustomobject]@{
    RequireExternalRunRoot = $false
    UseExternalWorkRepoRunRoot = $false
    UseExternalWorkRepoContractPaths = $false
}
$contractOnlyPairPolicy = [pscustomobject]@{
    PairId = 'pair01'
    RequireExternalRunRoot = $false
    UseExternalWorkRepoRunRoot = $false
    UseExternalWorkRepoContractPaths = $true
}
$contractOnlyPolicyResult = Test-BookkeepingRootsPolicy `
    -Config $contractOnlyConfig `
    -PairTest $contractOnlyPairTest `
    -PairPolicy $contractOnlyPairPolicy `
    -AutomationRoot $root `
    -BasePath $root `
    -WorkRepoRoot $workRepoRoot

Assert-True (-not [bool]$contractOnlyPolicyResult.Passed) 'contract-path-only external mode should still require external bookkeeping roots.'
Assert-True ([string]$contractOnlyPolicyResult.Reason -eq 'automation-repo-bookkeeping-roots-disallowed') 'contract-path-only policy should block automation repo bookkeeping roots.'
Assert-True ([string]$contractOnlyPolicyResult.Detail -like '*RouterStatePath*') 'contract-path-only policy failure detail should mention RouterStatePath.'

Write-Host 'visible config bookkeeping root policy ok'
