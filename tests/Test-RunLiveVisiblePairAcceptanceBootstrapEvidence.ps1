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
$scriptPath = Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

Assert-True ($scriptText.Contains('function New-TypedWindowBootstrapSummary')) 'acceptance script should summarize typed-window bootstrap evidence.'
Assert-True ($scriptText.Contains('BootstrapPrepareState')) 'acceptance receipt should expose BootstrapPrepareState.'
Assert-True ($scriptText.Contains('BootstrapPreparedTargets')) 'acceptance receipt should expose BootstrapPreparedTargets.'
Assert-True ($scriptText.Contains('BootstrapVisibleBeaconObserved')) 'acceptance receipt should expose BootstrapVisibleBeaconObserved.'
Assert-True ($scriptText.Contains('BootstrapFocusStealDetected')) 'acceptance receipt should expose BootstrapFocusStealDetected.'
Assert-True ($scriptText.Contains('BootstrapFailureReason')) 'acceptance receipt should expose BootstrapFailureReason.'

Write-Host 'run-live-visible-pair-acceptance bootstrap evidence wiring ok'
