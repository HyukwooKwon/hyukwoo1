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

Assert-True ($scriptText.Contains('-ReferenceTime ([datetime]::MinValue)')) 'late success outbox reconciliation should pass a real DateTime expression for ReferenceTime.'

Write-Host 'send-initial-pair-seed-with-retry late success reference time wiring ok'
