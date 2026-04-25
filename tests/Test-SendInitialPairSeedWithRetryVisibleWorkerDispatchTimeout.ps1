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
$scriptPath = Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

Assert-True ($scriptText.Contains('Get-ConfigValue -Object $pairTest.VisibleWorker -Name ''DispatchTimeoutSeconds''')) 'visible worker dispatch timeout should be sourced from PairTest.VisibleWorker.DispatchTimeoutSeconds.'
Assert-True ($scriptText.Contains('-TimeoutSeconds $visibleWorkerDispatchTimeoutSeconds')) 'visible worker dispatch wait should use the dedicated visible worker dispatch timeout.'

Write-Host 'send-initial-pair-seed-with-retry visible worker dispatch timeout wiring ok'
