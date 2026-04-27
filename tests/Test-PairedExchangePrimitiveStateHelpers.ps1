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

$publishStartedRow = [pscustomobject]@{
    SourceOutboxState = 'publish-started'
    SourceOutboxNextAction = ''
    LatestState = 'ready-to-forward'
    PublishReadyPath = ''
}
Assert-True (Test-PairedSourceOutboxObservedRow -Row $publishStartedRow) 'publish-started row should count as observed.'
Assert-True (Test-PairedSourceOutboxStrictReadyRow -Row $publishStartedRow) 'ready-to-forward row should count as strict-ready.'
Assert-True (-not (Test-PairedSourceOutboxAcceptedRow -Row $publishStartedRow)) 'publish-started row should not count as accepted.'
Assert-True (Test-PairedHandoffTransitionReadyRow -Row $publishStartedRow) 'ready-to-forward row should count as handoff transition-ready.'

$forwardedRow = [pscustomobject]@{
    SourceOutboxState = 'forwarded'
    SourceOutboxNextAction = 'already-forwarded'
    LatestState = 'forwarded'
}
Assert-True (Test-PairedSourceOutboxAcceptedRow -Row $forwardedRow) 'forwarded row should count as accepted publish.'
Assert-True (Test-PairedHandoffAcceptedRow -Row $forwardedRow) 'forwarded row should count as accepted handoff.'
Assert-True (Test-PairedSourceOutboxStrictReadyRow -Row $forwardedRow) 'forwarded row should count as strict-ready publish.'

$targetUnresponsiveRow = [pscustomobject]@{
    SourceOutboxState = 'target-unresponsive-after-send'
    SourceOutboxNextAction = 'manual-review'
    LatestState = 'no-zip'
    PublishReadyPath = ''
}
Assert-True (-not (Test-PairedSourceOutboxObservedRow -Row $targetUnresponsiveRow)) 'target-unresponsive-after-send should not count as observed publish.'
Assert-True (-not (Test-PairedSourceOutboxStrictReadyRow -Row $targetUnresponsiveRow)) 'target-unresponsive-after-send should not count as strict-ready publish.'

$partnerActiveRow = [pscustomobject]@{
    SubmitState = 'confirmed'
    SourceOutboxState = ''
    LatestState = ''
    DispatchState = ''
}
Assert-True (Test-PairedPartnerProgressObserved -Row $partnerActiveRow) 'confirmed submit state should count as partner progress.'

Assert-True (
    Test-PairedFirstHandoffDetected -CurrentRow $publishStartedRow -PartnerRow $partnerActiveRow -ForwardedCount 0 -UseVisibleWorker
) 'publish observed plus partner progress should count as first handoff for visible-worker.'
Assert-True (
    Test-PairedRoundtripDetected -SeedRow $publishStartedRow -PartnerRow $forwardedRow -ForwardedCount 1 -UseVisibleWorker
) 'partner forwarded state should count as roundtrip for visible-worker.'

$evidence = New-PairedPrimitiveEvidence -TargetRow $publishStartedRow -PartnerRow $partnerActiveRow -Extra @{
    DemoFlag = $true
}
Assert-True ([bool]$evidence.DemoFlag) 'primitive evidence helper should keep extra fields.'
Assert-True ([string]$evidence.Target.SourceOutboxState -eq 'publish-started') 'primitive evidence helper should keep target row.'

$manualAttention = Get-PairedAcceptanceManualAttentionOutcome -RetryReason ''
Assert-True ([string]$manualAttention.AcceptanceState -eq 'manual_attention_required') 'manual attention helper should surface manual_attention_required state.'
Assert-True ([string]$manualAttention.AcceptanceReason -eq 'manual-attention-required') 'manual attention helper should surface fallback reason.'

$failure = Get-PairedAcceptanceFailureOutcome -SubmitState 'unconfirmed' -ExecutionState 'timeout' -SubmitReason ''
Assert-True ([string]$failure.AcceptanceState -eq 'submit-unconfirmed') 'failure helper should normalize unconfirmed submit state.'
Assert-True ([string]$failure.AcceptanceReason -eq 'submit-unconfirmed') 'failure helper should fall back to normalized state.'

$success = Get-PairedAcceptanceSuccessOutcome -Roundtrip -UseVisibleWorker
Assert-True ([string]$success.AcceptanceState -eq 'roundtrip-confirmed') 'success helper should surface roundtrip-confirmed state.'
Assert-True ([string]$success.AcceptanceReason -eq 'forwarded-state-roundtrip-detected') 'success helper should surface visible-worker roundtrip reason.'

$timeout = Get-PairedAcceptanceTimeoutOutcome -FirstHandoffConfirmed:$true -UseVisibleWorker -WatcherStopSuffix '; watcher=test'
Assert-True ([string]$timeout.AcceptanceState -eq 'roundtrip-timeout') 'timeout helper should surface roundtrip-timeout state.'
Assert-True ([string]$timeout.AcceptanceReason -eq 'roundtrip-forwarded-state-not-detected; watcher=test') 'timeout helper should append watcher suffix.'

Assert-True (Test-PairedAcceptanceSuccessState -AcceptanceState 'first-handoff-confirmed') 'first-handoff-confirmed should count as success acceptance state.'
Assert-True (Test-PairedAcceptanceSuccessState -AcceptanceState 'roundtrip-confirmed') 'roundtrip-confirmed should count as success acceptance state.'
Assert-True (-not (Test-PairedAcceptanceSuccessState -AcceptanceState 'roundtrip-timeout')) 'timeout state should not count as success acceptance state.'

Write-Host 'paired exchange primitive state helpers ok'
