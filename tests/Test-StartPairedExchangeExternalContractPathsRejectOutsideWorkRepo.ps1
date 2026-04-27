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
$configPath = Join-Path $tmpRoot 'settings.external-contract-outside-root.psd1'
$reviewInputPath = Join-Path $reviewRoot 'seed-input.zip'
$externalInboxRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\inbox'
$externalProcessedRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\processed'
$externalRuntimeRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\runtime'
$externalLogsRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\logs'

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath $reviewInputPath -Value 'seed-input' -Encoding UTF8

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$baseConfigText = Get-Content -LiteralPath $baseConfigPath -Raw -Encoding UTF8
$escapedWorkRepoRoot = $workRepoRoot.Replace("'", "''")
$escapedReviewInputPath = $reviewInputPath.Replace("'", "''")
$escapedInboxRoot = $externalInboxRoot.Replace("'", "''")
$escapedProcessedRoot = $externalProcessedRoot.Replace("'", "''")
$escapedRuntimeRoot = $externalRuntimeRoot.Replace("'", "''")
$escapedLogsRoot = $externalLogsRoot.Replace("'", "''")
$configText = $baseConfigText `
    -replace "DefaultSeedWorkRepoRoot = '.*?'", ("DefaultSeedWorkRepoRoot = '" + $escapedWorkRepoRoot + "'") `
    -replace "DefaultSeedReviewInputPath = '.*?'", ("DefaultSeedReviewInputPath = '" + $escapedReviewInputPath + "'") `
    -replace "ExternalWorkRepoContractRelativeRoot = '.*?'", "ExternalWorkRepoContractRelativeRoot = '..\\..\\outside-contract'" `
    -replace "InboxRoot = '.*?'", ("InboxRoot = '" + $escapedInboxRoot + "'") `
    -replace "ProcessedRoot = '.*?'", ("ProcessedRoot = '" + $escapedProcessedRoot + "'") `
    -replace "RuntimeRoot = '.*?'", ("RuntimeRoot = '" + $escapedRuntimeRoot + "'") `
    -replace "LogsRoot = '.*?'", ("LogsRoot = '" + $escapedLogsRoot + "'")
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

$failed = $false
$errorMessage = ''
try {
    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $configPath `
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
