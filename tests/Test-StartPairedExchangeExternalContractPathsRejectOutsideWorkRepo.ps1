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
$tmpRoot = Join-Path $externalFixtureRoot 'Test-StartPairedExchangeExternalContractPathsRejectOutsideWorkRepo'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$runRoot = Join-Path $workRepoRoot ('.relay-runs\bottest-live-visible\run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$reviewInputPath = Join-Path $reviewRoot 'seed-input.zip'

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath $reviewInputPath -Value 'seed-input' -Encoding UTF8

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$generated = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Write-ExternalizedRelayConfig.ps1') `
    -BaseConfigPath $baseConfigPath `
    -WorkRepoRoot $workRepoRoot `
    -ReviewInputPath $reviewInputPath `
    -PairId 'pair01' `
    -ExternalWorkRepoContractRelativeRoot '..\..\outside-contract' `
    -AsJson | ConvertFrom-Json
$resolvedConfigPath = [string]$generated.OutputConfigPath

$failed = $false
$errorMessage = ''
try {
    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $resolvedConfigPath `
        -RunRoot $runRoot `
        -IncludePairId pair01 `
        -SeedTargetId target01 | Out-Null
}
catch {
    $failed = $true
    $errorMessage = $_.Exception.Message
}

Assert-True $failed 'start paired exchange should fail when external contract path escapes work repo.'
Assert-True ($errorMessage -like '*external-contract-path-outside-workrepo*') 'failure should mention external-contract-path-outside-workrepo.'

Write-Host 'start paired exchange external contract outside-root guard ok'
