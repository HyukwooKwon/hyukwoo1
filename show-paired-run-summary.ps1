[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [int]$RecentFailureCount = 10,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = ''
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Read-JsonObjectSafe {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not (Test-NonEmptyString $raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function Get-OverallState {
    param(
        $AcceptanceReceipt,
        $Status
    )

    $acceptanceOutcome = Get-ObjectPropertyValue -Object $AcceptanceReceipt -Name 'Outcome' -DefaultValue $null
    $acceptanceStage = [string](Get-ObjectPropertyValue -Object $AcceptanceReceipt -Name 'Stage' -DefaultValue '')
    $acceptanceState = [string](Get-ObjectPropertyValue -Object $acceptanceOutcome -Name 'AcceptanceState' -DefaultValue '')
    $failureCount = [int]$Status.Counts.FailureLineCount
    $manualAttentionCount = [int]$Status.Counts.ManualAttentionCount
    $submitUnconfirmedCount = [int]$Status.Counts.SubmitUnconfirmedCount
    $targetUnresponsiveCount = [int]$Status.Counts.TargetUnresponsiveCount

    if ($acceptanceStage -eq 'completed' -and $acceptanceState -in @('roundtrip-confirmed', 'first-handoff-confirmed')) {
        return 'success'
    }

    if (
        $acceptanceStage -in @('failed', 'seed-publish-missing', 'acceptance-failed') -or
        $acceptanceState -in @('error', 'manual_attention_required', 'submit-unconfirmed', 'target-unresponsive-after-send', 'seed-send-failed', 'seed-send-timeout', 'first-handoff-timeout', 'roundtrip-timeout') -or
        $failureCount -gt 0 -or
        $manualAttentionCount -gt 0 -or
        $submitUnconfirmedCount -gt 0 -or
        $targetUnresponsiveCount -gt 0
    ) {
        return 'failing'
    }

    return 'in-progress'
}

$statusParams = @{}
if (Test-NonEmptyString $ConfigPath) {
    $statusParams.ConfigPath = $ConfigPath
}
if (Test-NonEmptyString $RunRoot) {
    $statusParams.RunRoot = $RunRoot
}
$statusParams.RecentFailureCount = $RecentFailureCount
$statusParams.AsJson = $true

$status = & (Join-Path $PSScriptRoot 'show-paired-exchange-status.ps1') @statusParams | ConvertFrom-Json
$acceptanceReceipt = Read-JsonObjectSafe -Path ([string]$status.AcceptanceReceipt.Path)
$acceptanceOutcome = Get-ObjectPropertyValue -Object $acceptanceReceipt -Name 'Outcome' -DefaultValue $null

$targets = @(
    @($status.Targets) | ForEach-Object {
        [pscustomobject]@{
            PairId                  = [string]$_.PairId
            RoleName                = [string]$_.RoleName
            TargetId                = [string]$_.TargetId
            PartnerTargetId         = [string]$_.PartnerTargetId
            LatestState             = [string]$_.LatestState
            SourceOutboxState       = [string]$_.SourceOutboxState
            SeedSendState           = [string]$_.SeedSendState
            SubmitState             = [string]$_.SubmitState
            ManualAttentionRequired = [bool]$_.ManualAttentionRequired
            SummaryPresent          = [bool]$_.SummaryPresent
            ZipCount                = [int]$_.ZipCount
            DonePresent             = [bool]$_.DonePresent
            ResultPresent           = [bool]$_.ResultPresent
            FailureCount            = [int]$_.FailureCount
            ForwardedAt             = [string]$_.ForwardedAt
            SourceOutboxUpdatedAt   = [string]$_.SourceOutboxUpdatedAt
            TargetFolder            = [string]$_.TargetFolder
        }
    }
)

$acceptanceSummary = [pscustomobject]@{
    Exists            = ($null -ne $acceptanceReceipt)
    Path              = [string]$status.AcceptanceReceipt.Path
    Stage             = [string](Get-ObjectPropertyValue -Object $acceptanceReceipt -Name 'Stage' -DefaultValue '')
    AcceptanceState   = if ($null -ne $acceptanceReceipt) { [string](Get-ObjectPropertyValue -Object $acceptanceOutcome -Name 'AcceptanceState' -DefaultValue '') } else { [string]$status.AcceptanceReceipt.AcceptanceState }
    AcceptanceReason  = if ($null -ne $acceptanceReceipt) { [string](Get-ObjectPropertyValue -Object $acceptanceOutcome -Name 'AcceptanceReason' -DefaultValue '') } else { [string]$status.AcceptanceReceipt.AcceptanceReason }
    SeedFinalState    = if ($null -ne $acceptanceReceipt) { [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $acceptanceReceipt -Name 'Seed' -DefaultValue $null) -Name 'FinalState' -DefaultValue '') } else { '' }
    SeedSubmitState   = if ($null -ne $acceptanceReceipt) { [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $acceptanceReceipt -Name 'Seed' -DefaultValue $null) -Name 'SubmitState' -DefaultValue '') } else { '' }
    SeedOutboxPublished = if ($null -ne $acceptanceReceipt) { [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $acceptanceReceipt -Name 'Seed' -DefaultValue $null) -Name 'OutboxPublished' -DefaultValue $false) } else { $false }
}

$watcherSummary = [pscustomobject]@{
    Status        = [string]$status.Watcher.Status
    Reason        = [string]$status.Watcher.StatusReason
    LastHandled   = [string]$status.Watcher.LastHandledResult
    HeartbeatAt   = [string]$status.Watcher.HeartbeatAt
    StatusPath    = [string]$status.Watcher.StatusPath
}

$countsSummary = [pscustomobject]@{
    MessageFiles             = [int]$status.Counts.MessageFiles
    ForwardedCount           = [int]$status.Counts.ForwardedCount
    SummaryPresentCount      = [int]$status.Counts.SummaryPresentCount
    ZipPresentCount          = [int]$status.Counts.ZipPresentCount
    DonePresentCount         = [int]$status.Counts.DonePresentCount
    FailureLineCount         = [int]$status.Counts.FailureLineCount
    ManualAttentionCount     = [int]$status.Counts.ManualAttentionCount
    SubmitUnconfirmedCount   = [int]$status.Counts.SubmitUnconfirmedCount
    TargetUnresponsiveCount  = [int]$status.Counts.TargetUnresponsiveCount
    ReadyToForwardCount      = [int]$status.Counts.ReadyToForwardCount
}

$overallState = Get-OverallState -AcceptanceReceipt $acceptanceReceipt -Status $status
$runName = Split-Path -Leaf ([string]$status.RunRoot)
$summaryLine = '{0} overall={1} acceptance={2} stage={3} watcher={4} forwarded={5} summaries={6} zips={7} failures={8}' -f `
    $runName,
    $overallState,
    $acceptanceSummary.AcceptanceState,
    $acceptanceSummary.Stage,
    $watcherSummary.Status,
    $countsSummary.ForwardedCount,
    $countsSummary.SummaryPresentCount,
    $countsSummary.ZipPresentCount,
    $countsSummary.FailureLineCount

$result = [pscustomobject]@{
    RunRoot          = [string]$status.RunRoot
    SummaryLine      = $summaryLine
    OverallState     = $overallState
    Acceptance       = $acceptanceSummary
    Watcher          = $watcherSummary
    Counts           = $countsSummary
    RecentFailureCount = [int]$RecentFailureCount
    Targets          = $targets
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Output $summaryLine
Write-Output ('RunRoot: ' + [string]$result.RunRoot)
Write-Output ('Acceptance: stage={0} state={1} reason={2}' -f $acceptanceSummary.Stage, $acceptanceSummary.AcceptanceState, $acceptanceSummary.AcceptanceReason)
Write-Output ('Seed: final={0} submit={1} outboxPublished={2}' -f $acceptanceSummary.SeedFinalState, $acceptanceSummary.SeedSubmitState, $acceptanceSummary.SeedOutboxPublished)
Write-Output ('Watcher: status={0} reason={1} lastHandled={2}' -f $watcherSummary.Status, $watcherSummary.Reason, $watcherSummary.LastHandled)
Write-Output ('Counts: messages={0} forwarded={1} summaries={2} zips={3} failures={4}' -f $countsSummary.MessageFiles, $countsSummary.ForwardedCount, $countsSummary.SummaryPresentCount, $countsSummary.ZipPresentCount, $countsSummary.FailureLineCount)
Write-Output 'Targets:'
foreach ($target in $targets) {
    Write-Output ('- {0}({1}): latest={2} outbox={3} seed={4} submit={5} summary={6} zip={7} failures={8}' -f `
        $target.TargetId,
        $target.RoleName,
        $target.LatestState,
        $target.SourceOutboxState,
        $target.SeedSendState,
        $target.SubmitState,
        $target.SummaryPresent,
        $target.ZipCount,
        $target.FailureCount)
}
