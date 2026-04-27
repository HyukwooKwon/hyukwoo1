[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [string]$PairId,
    [string]$TargetId,
    [int]$MaxAttempts = 3,
    [int]$DelaySeconds = 5,
    [int[]]$RetryBackoffMs = @(),
    [int]$WaitForRouterSeconds = 20,
    [int]$WaitForPublishSeconds = 0,
    [switch]$DisallowInlineTypedWindowPrepare,
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

function Get-SubmitPrimitiveNextAction {
    param(
        [Parameter(Mandatory)]$SubmitResult,
        $TargetRow = $null
    )

    $sourceOutboxNextAction = [string](Get-ConfigValue -Object $TargetRow -Name 'SourceOutboxNextAction' -DefaultValue '')
    $latestState = [string](Get-ConfigValue -Object $TargetRow -Name 'LatestState' -DefaultValue '')
    if ($sourceOutboxNextAction -in @('handoff-ready', 'already-forwarded', 'duplicate-skipped') -or $latestState -in @('ready-to-forward', 'forwarded', 'duplicate-skipped')) {
        return 'handoff-confirm'
    }

    $finalState = [string](Get-ConfigValue -Object $SubmitResult -Name 'FinalState' -DefaultValue '')
    if ($finalState -eq 'manual_attention_required') {
        return 'manual-review'
    }
    if ($finalState -eq 'retry-pending') {
        return 'retry-after-backoff'
    }

    return 'publish-confirm'
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

$seedParameters = @{
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    TargetId = $resolvedTargetId
    MaxAttempts = $MaxAttempts
    DelaySeconds = $DelaySeconds
    WaitForRouterSeconds = $WaitForRouterSeconds
    WaitForPublishSeconds = $WaitForPublishSeconds
    AsJson = $true
}
if (@($RetryBackoffMs).Count -gt 0) {
    $seedParameters.RetryBackoffMs = @($RetryBackoffMs)
}
if ($DisallowInlineTypedWindowPrepare) {
    $seedParameters.DisallowInlineTypedWindowPrepare = $true
}

$submitResult = Invoke-JsonScript -ScriptPath (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1') -Parameters $seedParameters
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

$finalState = [string](Get-ConfigValue -Object $submitResult -Name 'FinalState' -DefaultValue '')
$submitState = [string](Get-ConfigValue -Object $submitResult -Name 'SubmitState' -DefaultValue '')
$submitReason = [string](Get-ConfigValue -Object $submitResult -Name 'SubmitReason' -DefaultValue '')
$primitiveSuccess = (Test-NonEmptyString $finalState)
$primitiveReason = if (Test-NonEmptyString $submitReason) {
    $submitReason
}
else {
    $finalState
}
$primitiveAccepted = [bool](Get-ConfigValue -Object $submitResult -Name 'SubmitConfirmed' -DefaultValue $false)
$nextPrimitiveAction = Get-SubmitPrimitiveNextAction -SubmitResult $submitResult -TargetRow $targetRow
$displayFinalState = if (Test-NonEmptyString $finalState) { $finalState } else { '(none)' }
$displaySubmitState = if (Test-NonEmptyString $submitState) { $submitState } else { '(none)' }
$summaryLine = "pair={0} target={1} final={2} submit={3} next={4}" -f $resolvedPairId, $resolvedTargetId, $displayFinalState, $displaySubmitState, $nextPrimitiveAction
$evidence = New-PairedPrimitiveEvidence -TargetRow $targetRow -PartnerRow $partnerRow -PairRow $pairRow -Receipt $pairedStatus.AcceptanceReceipt -Watcher $pairedStatus.Watcher -Counts $pairedStatus.Counts -Extra @{
    ExecutionPathMode = [string](Get-ConfigValue -Object $submitResult -Name 'ExecutionPathMode' -DefaultValue '')
    FinalState = $finalState
    OutboxPublished = [bool](Get-ConfigValue -Object $submitResult -Name 'OutboxPublished' -DefaultValue $false)
    SubmitConfirmed = $primitiveAccepted
    SubmitRetrySequenceSummary = [string](Get-ConfigValue -Object $submitResult -Name 'SubmitRetrySequenceSummary' -DefaultValue '')
    SubmitState = $submitState
}

$payload = [pscustomobject][ordered]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    PrimitiveName = 'one-shot-submit'
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    PairId = $resolvedPairId
    TargetId = $resolvedTargetId
    PartnerTargetId = $partnerTargetId
    PrimitiveSuccess = [bool]$primitiveSuccess
    PrimitiveAccepted = [bool]$primitiveAccepted
    PrimitiveState = $finalState
    PrimitiveReason = $primitiveReason
    NextPrimitiveAction = $nextPrimitiveAction
    SummaryLine = $summaryLine
    Evidence = $evidence
    FinalState = $finalState
    ExecutionPathMode = [string](Get-ConfigValue -Object $submitResult -Name 'ExecutionPathMode' -DefaultValue '')
    SubmitState = $submitState
    SubmitConfirmed = [bool]$primitiveAccepted
    SubmitReason = $submitReason
    SubmitRetryModes = @((Get-ConfigValue -Object $submitResult -Name 'SubmitRetryModes' -DefaultValue @()))
    SubmitRetrySequenceSummary = [string](Get-ConfigValue -Object $submitResult -Name 'SubmitRetrySequenceSummary' -DefaultValue '')
    PrimarySubmitMode = [string](Get-ConfigValue -Object $submitResult -Name 'PrimarySubmitMode' -DefaultValue '')
    FinalSubmitMode = [string](Get-ConfigValue -Object $submitResult -Name 'FinalSubmitMode' -DefaultValue '')
    SubmitRetryIntervalMs = [int](Get-ConfigValue -Object $submitResult -Name 'SubmitRetryIntervalMs' -DefaultValue 0)
    OutboxPublished = [bool](Get-ConfigValue -Object $submitResult -Name 'OutboxPublished' -DefaultValue $false)
    Submit = $submitResult
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
    'Paired Exchange One-shot Submit Primitive'
    ('Pair: ' + $resolvedPairId)
    ('Target: ' + $resolvedTargetId)
    ('Partner: ' + $partnerTargetId)
    ('RunRoot: ' + $resolvedRunRoot)
    ('PrimitiveState: ' + $displayFinalState)
    ('SubmitState: ' + $displaySubmitState)
    ('SubmitReason: ' + $(if (Test-NonEmptyString $submitReason) { $submitReason } else { '(none)' }))
    ('NextPrimitiveAction: ' + $nextPrimitiveAction)
    ('Summary: ' + $summaryLine)
)
$lines
