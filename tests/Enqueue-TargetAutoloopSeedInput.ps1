[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [string]$ReferenceInputPath = '',
    [string]$CreatedBy = 'relay_operator_panel',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')

function Get-TargetAutoloopSeedComposerRuntimeState {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)]$QueuePaths
    )

    $pendingInputCount = @(
        Get-ChildItem -LiteralPath ([string]$Paths.InboxPendingRoot) -File -ErrorAction SilentlyContinue
    ).Count
    $claimedInputCount = @(
        Get-ChildItem -LiteralPath ([string]$Paths.InboxClaimedRoot) -File -ErrorAction SilentlyContinue
    ).Count
    $queuedCommandCount = @(
        Get-ChildItem -LiteralPath ([string]$QueuePaths.QueuedRoot) -File -Filter '*.json' -ErrorAction SilentlyContinue
    ).Count
    $processingCommandCount = @(
        Get-ChildItem -LiteralPath ([string]$QueuePaths.ProcessingRoot) -File -Filter '*.json' -ErrorAction SilentlyContinue
    ).Count

    return [pscustomobject]@{
        PendingInputCount = $pendingInputCount
        ClaimedInputCount = $claimedInputCount
        QueuedCommandCount = $queuedCommandCount
        ProcessingCommandCount = $processingCommandCount
        Summary = ('runtime: pendingInput={0} / claimed={1} / queued={2} / processing={3}' -f
            $pendingInputCount,
            $claimedInputCount,
            $queuedCommandCount,
            $processingCommandCount)
    }
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $resolvedConfigPath
$resolvedRunRoot = Resolve-TargetAutoloopRunRoot -Config $config -RequestedRunRoot $RunRoot
if (-not (Test-Path -LiteralPath $resolvedRunRoot -PathType Container)) {
    throw "target-autoloop run root not found: $resolvedRunRoot"
}

$target = @($config.Targets | Where-Object { [string]$_.TargetId -eq $TargetId } | Select-Object -First 1)[0]
if ($null -eq $target) {
    throw "target-autoloop target not found: $TargetId"
}

$paths = Get-TargetAutoloopTargetPaths -RunRoot $resolvedRunRoot -TargetId $TargetId -Target $target -Config $config
$queuePaths = Get-TargetAutoloopQueuePaths -RunRoot $resolvedRunRoot -TargetId $TargetId -Target $target -Config $config
Ensure-TargetAutoloopTargetDirectories -Paths $paths
Ensure-Directory -Path ([string]$paths.InboxPendingRoot)

$itemId = 'seed-input-{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$inputTriggerPath = Join-Path ([string]$paths.InboxPendingRoot) ($itemId + '.json')
$payload = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    EventKind = 'target-autoloop-seed-input'
    QueueSource = 'target-autoloop-seed-composer'
    SourceLabel = 'target-autoloop-seed-composer'
    TargetId = $TargetId
    RunRoot = $resolvedRunRoot
    WorkRepoRoot = [string]$paths.WorkRepoRoot
    TargetRunRoot = [string]$paths.TargetRunRoot
    TaskText = [string]$Text
    ReferenceInputPath = [string]$ReferenceInputPath
    CreatedAt = (Get-Date).ToString('o')
    CreatedBy = [string]$CreatedBy
    TriggerNonce = [guid]::NewGuid().ToString('N')
}
Write-JsonFileAtomically -Path $inputTriggerPath -Payload $payload
$fingerprint = Get-TargetAutoloopInputTriggerFingerprint -Path $inputTriggerPath
$runtimeState = Get-TargetAutoloopSeedComposerRuntimeState -Paths $paths -QueuePaths $queuePaths

$result = [pscustomobject]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    WorkRepoRoot = [string]$paths.WorkRepoRoot
    TargetRunRoot = [string]$paths.TargetRunRoot
    TargetId = $TargetId
    InputTriggerPath = $inputTriggerPath
    Fingerprint = $fingerprint
    QueueSummary = 'input-file trigger queued'
    SeedRuntime = $runtimeState
    SeedRuntimeSummary = [string]$runtimeState.Summary
    Item = [pscustomobject]@{
        Id = $itemId
        EventKind = 'target-autoloop-seed-input'
        QueueSource = 'target-autoloop-seed-composer'
        InputTriggerPath = $inputTriggerPath
        ReferenceInputPath = [string]$ReferenceInputPath
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host ("target-autoloop seed input queued: {0}" -f $inputTriggerPath)
