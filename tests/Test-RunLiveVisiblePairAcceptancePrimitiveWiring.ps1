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

Assert-True ($scriptText.Contains("Invoke-PairedExchangeOneShotSubmit.ps1")) 'acceptance script should call the shared one-shot submit primitive wrapper.'
Assert-True ($scriptText.Contains("Confirm-PairedExchangePublishPrimitive.ps1")) 'acceptance script should call the shared publish primitive wrapper.'
Assert-True ($scriptText.Contains("Confirm-PairedExchangeHandoffPrimitive.ps1")) 'acceptance script should call the shared handoff primitive wrapper.'
Assert-True ($scriptText.Contains("Primitives = [pscustomobject]@{")) 'acceptance receipt should reserve primitive payload slots.'
Assert-True ($scriptText.Contains("Test-PairedSourceOutboxObservedRow")) 'acceptance wait loop should use shared publish observation helper.'
Assert-True ($scriptText.Contains("Test-PairedHandoffTransitionReadyRow")) 'acceptance wait loop should use shared handoff transition helper.'
Assert-True ($scriptText.Contains("Test-PairedPartnerProgressObserved")) 'acceptance wait loop should use shared partner progress helper.'
Assert-True ($scriptText.Contains("Test-PairedFirstHandoffDetected")) 'acceptance wait loop should use shared first-handoff detection helper.'
Assert-True ($scriptText.Contains("Test-PairedRoundtripDetected")) 'acceptance wait loop should use shared roundtrip detection helper.'
Assert-True ($scriptText.Contains("Get-PairedAcceptanceFailureOutcome")) 'acceptance wait loop should use shared failure outcome helper.'
Assert-True ($scriptText.Contains("Get-PairedAcceptanceSuccessOutcome")) 'acceptance wait loop should use shared success outcome helper.'
Assert-True ($scriptText.Contains("Get-PairedAcceptanceTimeoutOutcome")) 'acceptance wait loop should use shared timeout outcome helper.'

Write-Host 'run-live-visible-pair-acceptance primitive wiring ok'
