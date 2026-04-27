[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [string]$PairId,
    [string]$TargetId,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Invoke-JsonScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    try {
        $raw = & $ScriptPath @Parameters
    }
    catch {
        throw ("script failed: {0} :: {1}" -f $ScriptPath, $_.Exception.Message)
    }

    $outputText = ($raw | Out-String).Trim()
    if (-not (Test-NonEmptyString $outputText)) {
        throw ("script returned no json output: " + $ScriptPath)
    }

    try {
        return ($outputText | ConvertFrom-Json)
    }
    catch {
        throw ("invalid json output: {0} :: {1}" -f $ScriptPath, $_.Exception.Message)
    }
}

function Get-HandoffPrimitiveNextAction {
    param(
        $PairRow,
        [string]$PrimitiveState,
        [string]$ReceiptState,
        [string]$PartnerTargetId
    )

    $pairNextAction = [string](Get-ConfigValue -Object $PairRow -Name 'NextAction' -DefaultValue '')
    if (Test-NonEmptyString $pairNextAction) {
        return $pairNextAction
    }

    switch ($PrimitiveState) {
        'accepted' {
            if ($ReceiptState -eq 'roundtrip-confirmed') {
                return 'roundtrip-closeout'
            }
            if (Test-NonEmptyString $PartnerTargetId) {
                return 'select-partner-target'
            }
            return 'inspect-pair-status'
        }
        'ready' { return 'wait-for-forward' }
        'partner-active' { return 'inspect-partner-progress' }
        default { return 'publish-confirm' }
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}
if (-not (Test-NonEmptyString $RunRoot)) {
    throw 'RunRoot가 필요합니다.'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$selection = Resolve-PairTargetSelection -PairTest $pairTest -PairId $PairId -TargetId $TargetId
$resolvedPairId = [string]$selection.PairId
$resolvedTargetId = [string]$selection.TargetId
$partnerTargetId = [string]$selection.PartnerTargetId

$pairedStatus = Invoke-JsonScript -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -Parameters @{
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    AsJson = $true
}
$targetRow = @($pairedStatus.Targets | Where-Object { [string]$_.TargetId -eq $resolvedTargetId } | Select-Object -First 1)[0]
$partnerRow = @($pairedStatus.Targets | Where-Object { [string]$_.TargetId -eq $partnerTargetId } | Select-Object -First 1)[0]
$pairRow = @($pairedStatus.Pairs | Where-Object { [string]$_.PairId -eq $resolvedPairId } | Select-Object -First 1)[0]
if ($null -eq $targetRow) {
    throw "paired status target row not found: $resolvedTargetId"
}
if ($null -eq $pairRow) {
    throw "paired status pair row not found: $resolvedPairId"
}

$receipt = $pairedStatus.AcceptanceReceipt
$receiptState = [string](Get-ConfigValue -Object $receipt -Name 'AcceptanceState' -DefaultValue '')
$pairForwardedStateCount = [int](Get-ConfigValue -Object $pairRow -Name 'ForwardedStateCount' -DefaultValue 0)
$pairHandoffReadyCount = [int](Get-ConfigValue -Object $pairRow -Name 'HandoffReadyCount' -DefaultValue 0)
$currentAccepted = Test-PairedHandoffAcceptedRow -Row $targetRow
$currentReady = Test-PairedHandoffTransitionReadyRow -Row $targetRow
$partnerProgressObserved = Test-PairedPartnerProgressObserved -Row $partnerRow
$receiptAccepted = Test-PairedAcceptanceSuccessState -AcceptanceState $receiptState

$primitiveState = if ($receiptAccepted -or $currentAccepted -or $pairForwardedStateCount -gt 0) {
    'accepted'
}
elseif ($currentReady -or $pairHandoffReadyCount -gt 0) {
    'ready'
}
elseif ($partnerProgressObserved) {
    'partner-active'
}
else {
    'missing'
}
$primitiveAccepted = ($primitiveState -eq 'accepted')
$primitiveSuccess = ($primitiveState -ne 'missing')
$currentLatestState = [string](Get-ConfigValue -Object $targetRow -Name 'LatestState' -DefaultValue '')
$currentNextAction = [string](Get-ConfigValue -Object $targetRow -Name 'SourceOutboxNextAction' -DefaultValue '')
$pairCurrentPhase = [string](Get-ConfigValue -Object $pairRow -Name 'CurrentPhase' -DefaultValue '')
$primitiveReason = 'current={0}/{1} pairPhase={2} forwarded={3} handoffReady={4} receipt={5}' -f `
    $(if (Test-NonEmptyString $currentLatestState) { $currentLatestState } else { '(none)' }), `
    $(if (Test-NonEmptyString $currentNextAction) { $currentNextAction } else { '(none)' }), `
    $(if (Test-NonEmptyString $pairCurrentPhase) { $pairCurrentPhase } else { '(none)' }), `
    $pairForwardedStateCount, `
    $pairHandoffReadyCount, `
    $(if (Test-NonEmptyString $receiptState) { $receiptState } else { '(none)' })
$nextPrimitiveAction = Get-HandoffPrimitiveNextAction -PairRow $pairRow -PrimitiveState $primitiveState -ReceiptState $receiptState -PartnerTargetId $partnerTargetId
$summaryLine = 'pair={0} target={1} handoff={2} accepted={3} next={4}' -f $resolvedPairId, $resolvedTargetId, $primitiveState, $primitiveAccepted, $nextPrimitiveAction
$evidence = New-PairedPrimitiveEvidence -TargetRow $targetRow -PartnerRow $partnerRow -PairRow $pairRow -Receipt $receipt -Watcher $pairedStatus.Watcher -Counts $pairedStatus.Counts -Extra @{
    CurrentAccepted = [bool]$currentAccepted
    CurrentReady = [bool]$currentReady
    PairCurrentPhase = $pairCurrentPhase
    PairForwardedStateCount = $pairForwardedStateCount
    PairHandoffReadyCount = $pairHandoffReadyCount
    PartnerProgressObserved = [bool]$partnerProgressObserved
}

$payload = [pscustomobject][ordered]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    PrimitiveName = 'handoff-confirm'
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    PairId = $resolvedPairId
    TargetId = $resolvedTargetId
    PartnerTargetId = $partnerTargetId
    PrimitiveSuccess = [bool]$primitiveSuccess
    PrimitiveAccepted = [bool]$primitiveAccepted
    PrimitiveState = $primitiveState
    PrimitiveReason = $primitiveReason
    NextPrimitiveAction = $nextPrimitiveAction
    SummaryLine = $summaryLine
    Evidence = $evidence
    PairCurrentPhase = $pairCurrentPhase
    PairNextExpectedHandoff = [string](Get-ConfigValue -Object $pairRow -Name 'NextExpectedHandoff' -DefaultValue '')
    PairNextAction = [string](Get-ConfigValue -Object $pairRow -Name 'NextAction' -DefaultValue '')
    PairForwardedStateCount = $pairForwardedStateCount
    PairHandoffReadyCount = $pairHandoffReadyCount
    AcceptanceState = $receiptState
    CurrentAccepted = [bool]$currentAccepted
    CurrentReady = [bool]$currentReady
    PartnerProgressObserved = [bool]$partnerProgressObserved
    PairedTargetStatus = $targetRow
    PairedPartnerStatus = $partnerRow
    PairStatus = $pairRow
    AcceptanceReceipt = $receipt
    Watcher = $pairedStatus.Watcher
    Counts = $pairedStatus.Counts
    PairedStatusSnapshot = $pairedStatus
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
    return
}

$lines = @(
    'Paired Exchange Handoff Confirm Primitive'
    ('Pair: ' + $resolvedPairId)
    ('Target: ' + $resolvedTargetId)
    ('Partner: ' + $partnerTargetId)
    ('RunRoot: ' + $resolvedRunRoot)
    ('PrimitiveState: ' + $primitiveState)
    ('PrimitiveAccepted: ' + $primitiveAccepted)
    ('PairCurrentPhase: ' + $(if (Test-NonEmptyString $pairCurrentPhase) { $pairCurrentPhase } else { '(none)' }))
    ('PairNextAction: ' + $(if (Test-NonEmptyString ([string]$payload.PairNextAction)) { [string]$payload.PairNextAction } else { '(none)' }))
    ('NextPrimitiveAction: ' + $nextPrimitiveAction)
    ('Summary: ' + $summaryLine)
)
$lines
