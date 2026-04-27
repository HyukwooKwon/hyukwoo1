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

function Get-PublishPrimitiveNextAction {
    param(
        [Parameter(Mandatory)]$TargetRow,
        [bool]$PublishAccepted,
        [bool]$PublishObserved
    )

    if ($PublishAccepted) {
        return 'handoff-confirm'
    }
    if ($PublishObserved) {
        return 'wait-for-import'
    }

    $submitState = [string](Get-ConfigValue -Object $TargetRow -Name 'SubmitState' -DefaultValue '')
    if ($submitState -eq 'unconfirmed') {
        return 'submit-retry-or-manual-review'
    }
    if (Test-NonEmptyString $submitState) {
        return 'wait-for-publish'
    }
    return 'submit-needed'
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

$publishObserved = Test-PairedSourceOutboxStrictReadyRow -Row $targetRow
$publishAccepted = Test-PairedSourceOutboxAcceptedRow -Row $targetRow
$primitiveState = if ($publishAccepted) {
    'accepted'
}
elseif ($publishObserved) {
    'observed'
}
else {
    'missing'
}
$displaySourceOutboxState = [string](Get-ConfigValue -Object $targetRow -Name 'SourceOutboxState' -DefaultValue '')
$displaySourceOutboxNextAction = [string](Get-ConfigValue -Object $targetRow -Name 'SourceOutboxNextAction' -DefaultValue '')
$displayLatestState = [string](Get-ConfigValue -Object $targetRow -Name 'LatestState' -DefaultValue '')
if (-not (Test-NonEmptyString $displaySourceOutboxState)) {
    $displaySourceOutboxState = '(none)'
}
if (-not (Test-NonEmptyString $displaySourceOutboxNextAction)) {
    $displaySourceOutboxNextAction = '(none)'
}
if (-not (Test-NonEmptyString $displayLatestState)) {
    $displayLatestState = '(none)'
}
$primitiveReason = "{0}/{1}/{2}" -f $displaySourceOutboxState, $displaySourceOutboxNextAction, $displayLatestState
$nextPrimitiveAction = Get-PublishPrimitiveNextAction -TargetRow $targetRow -PublishAccepted:$publishAccepted -PublishObserved:$publishObserved
$summaryLine = "pair={0} target={1} publish={2} accepted={3} next={4}" -f $resolvedPairId, $resolvedTargetId, $primitiveState, $publishAccepted, $nextPrimitiveAction
$evidence = New-PairedPrimitiveEvidence -TargetRow $targetRow -PartnerRow $partnerRow -PairRow $pairRow -Receipt $pairedStatus.AcceptanceReceipt -Watcher $pairedStatus.Watcher -Counts $pairedStatus.Counts -Extra @{
    LatestState = [string](Get-ConfigValue -Object $targetRow -Name 'LatestState' -DefaultValue '')
    PublishReadyPath = [string](Get-ConfigValue -Object $targetRow -Name 'PublishReadyPath' -DefaultValue '')
    PublishReadyPathExists = [bool]((Test-NonEmptyString ([string](Get-ConfigValue -Object $targetRow -Name 'PublishReadyPath' -DefaultValue ''))) -and (Test-Path -LiteralPath ([string](Get-ConfigValue -Object $targetRow -Name 'PublishReadyPath' -DefaultValue ''))))
    SourceOutboxNextAction = [string](Get-ConfigValue -Object $targetRow -Name 'SourceOutboxNextAction' -DefaultValue '')
    SourceOutboxState = [string](Get-ConfigValue -Object $targetRow -Name 'SourceOutboxState' -DefaultValue '')
    SubmitState = [string](Get-ConfigValue -Object $targetRow -Name 'SubmitState' -DefaultValue '')
}

$payload = [pscustomobject][ordered]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    PrimitiveName = 'publish-confirm'
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    PairId = $resolvedPairId
    TargetId = $resolvedTargetId
    PartnerTargetId = $partnerTargetId
    PrimitiveSuccess = [bool]$publishObserved
    PrimitiveAccepted = [bool]$publishAccepted
    PrimitiveState = $primitiveState
    PrimitiveReason = $primitiveReason
    NextPrimitiveAction = $nextPrimitiveAction
    SummaryLine = $summaryLine
    Evidence = $evidence
    SourceOutboxState = [string](Get-ConfigValue -Object $targetRow -Name 'SourceOutboxState' -DefaultValue '')
    SourceOutboxNextAction = [string](Get-ConfigValue -Object $targetRow -Name 'SourceOutboxNextAction' -DefaultValue '')
    LatestState = [string](Get-ConfigValue -Object $targetRow -Name 'LatestState' -DefaultValue '')
    SubmitState = [string](Get-ConfigValue -Object $targetRow -Name 'SubmitState' -DefaultValue '')
    SubmitReason = [string](Get-ConfigValue -Object $targetRow -Name 'SubmitReason' -DefaultValue '')
    TypedWindowExecutionState = [string](Get-ConfigValue -Object $targetRow -Name 'TypedWindowExecutionState' -DefaultValue '')
    PublishReadyPath = [string](Get-ConfigValue -Object $targetRow -Name 'PublishReadyPath' -DefaultValue '')
    PublishReadyPathExists = [bool]((Test-NonEmptyString ([string](Get-ConfigValue -Object $targetRow -Name 'PublishReadyPath' -DefaultValue ''))) -and (Test-Path -LiteralPath ([string](Get-ConfigValue -Object $targetRow -Name 'PublishReadyPath' -DefaultValue ''))))
    SeedSubmitRetrySequenceSummary = [string](Get-ConfigValue -Object $targetRow -Name 'SeedSubmitRetrySequenceSummary' -DefaultValue '')
    PairedTargetStatus = $targetRow
    PairedPartnerStatus = $partnerRow
    PairStatus = $pairRow
    AcceptanceReceipt = $pairedStatus.AcceptanceReceipt
    Watcher = $pairedStatus.Watcher
    Counts = $pairedStatus.Counts
    PairedStatusSnapshot = $pairedStatus
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
    return
}

$lines = @(
    'Paired Exchange Publish Confirm Primitive'
    ('Pair: ' + $resolvedPairId)
    ('Target: ' + $resolvedTargetId)
    ('Partner: ' + $partnerTargetId)
    ('RunRoot: ' + $resolvedRunRoot)
    ('PrimitiveState: ' + $primitiveState)
    ('PrimitiveAccepted: ' + $publishAccepted)
    ('SourceOutboxState: ' + $displaySourceOutboxState)
    ('SourceOutboxNextAction: ' + $displaySourceOutboxNextAction)
    ('LatestState: ' + $displayLatestState)
    ('NextPrimitiveAction: ' + $nextPrimitiveAction)
    ('Summary: ' + $summaryLine)
)
$lines
