[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$PromptFilePath,
    [string]$RequestFilePath = '',
    [ValidateSet('target-inbox-submit', 'target-autoloop')][string]$RunMode = 'target-inbox-submit',
    [ValidateSet('input-file', 'publish-ready')][string]$TriggerKind = 'input-file',
    [ValidateSet('external-inbox', 'self-output')][string]$LoopSource = 'external-inbox',
    [string]$TriggerFingerprint = '',
    [string]$PublishReadyDispatchDelayMode = '',
    [int]$PublishReadyDispatchDelaySeconds = 0,
    [int]$PublishReadyDispatchMinDelaySeconds = 0,
    [int]$PublishReadyDispatchMaxDelaySeconds = 0,
    [string]$DispatchEligibleAt = '',
    [int]$CycleId = 0,
    [int]$ParentCycleId = 0,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\TargetAutoloopConfig.ps1')
. (Join-Path $root 'tests\lib\RelayTargetFolderPreflight.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
$resolvedRunRoot = if ([System.IO.Path]::IsPathRooted($RunRoot)) {
    [System.IO.Path]::GetFullPath($RunRoot)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $root $RunRoot))
}
$resolvedPromptFilePath = (Resolve-Path -LiteralPath $PromptFilePath).Path
if (-not (Test-Path -LiteralPath $resolvedRunRoot -PathType Container)) {
    throw "target autoloop run root not found: $resolvedRunRoot"
}

$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "target autoloop manifest not found: $manifestPath"
}
$manifest = Read-JsonObject -Path $manifestPath
$targetRow = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq $TargetId } | Select-Object -First 1)
if (@($targetRow).Count -eq 0) {
    throw "target not found in target autoloop manifest: $TargetId"
}
$targetConfig = @($config.Targets | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') -eq $TargetId } | Select-Object -First 1)
if (@($targetConfig).Count -eq 0) {
    throw "target autoloop target config not found: $TargetId"
}
$null = Assert-RelayTargetFolderReady `
    -ConfiguredFolder ([string](Get-ConfigValue -Object $targetConfig[0] -Name 'GlobalFolder' -DefaultValue '')) `
    -InboxRoot ([string](Get-ConfigValue -Object $config -Name 'InboxRoot' -DefaultValue '')) `
    -TargetKey $TargetId

$queuePaths = Get-TargetAutoloopQueuePaths -RunRoot $resolvedRunRoot -TargetId $TargetId -Target $targetRow[0] -Config $config
$queuePaths = Use-TargetAutoloopManifestQueuePaths -Paths $queuePaths -ManifestTarget $targetRow[0]
foreach ($queuePath in @($queuePaths.QueuedRoot, $queuePaths.ProcessingRoot, $queuePaths.CompletedRoot, $queuePaths.FailedRoot, $queuePaths.PayloadRoot)) {
    Ensure-Directory -Path $queuePath
}

$commandId = '{0}-cycle-{1:d6}-{2}' -f $TargetId, $CycleId, ([guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path ([string]$queuePaths.PayloadRoot) $commandId
Ensure-Directory -Path $payloadRoot
$promptSnapshotPath = Join-Path $payloadRoot 'prompt.txt'
Copy-Item -LiteralPath $resolvedPromptFilePath -Destination $promptSnapshotPath -Force

$resolvedRequestFilePath = ''
$requestSnapshotPath = ''
if (Test-NonEmptyString $RequestFilePath) {
    $resolvedRequestFilePath = (Resolve-Path -LiteralPath $RequestFilePath).Path
    $requestSnapshotPath = Join-Path $payloadRoot 'request.json'
    Copy-Item -LiteralPath $resolvedRequestFilePath -Destination $requestSnapshotPath -Force
}

$commandPath = Join-Path $queuePaths.QueuedRoot ("command_{0}.json" -f $commandId)
$command = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunMode = $RunMode
    RunRoot = $resolvedRunRoot
    WorkRepoRoot = [string]$queuePaths.WorkRepoRoot
    TargetRunRoot = [string]$queuePaths.TargetRunRoot
    TargetId = $TargetId
    CommandId = $commandId
    TriggerKind = $TriggerKind
    TriggerFingerprint = [string]$TriggerFingerprint
    LoopSource = $LoopSource
    PromptPath = $promptSnapshotPath
    PromptFilePath = $promptSnapshotPath
    PromptSourcePath = $resolvedPromptFilePath
    PromptSnapshotPath = $promptSnapshotPath
    RequestSourcePath = $resolvedRequestFilePath
    RequestSnapshotPath = $requestSnapshotPath
    FixedSuffixPolicy = 'target'
    CycleId = [int]$CycleId
    ParentCycleId = [int]$ParentCycleId
    PublishReadyDispatchDelayMode = [string]$PublishReadyDispatchDelayMode
    PublishReadyDispatchDelaySeconds = [int]$PublishReadyDispatchDelaySeconds
    PublishReadyDispatchMinDelaySeconds = [int]$PublishReadyDispatchMinDelaySeconds
    PublishReadyDispatchMaxDelaySeconds = [int]$PublishReadyDispatchMaxDelaySeconds
    DispatchEligibleAt = [string]$DispatchEligibleAt
    CreatedAt = (Get-Date).ToString('o')
}
Write-JsonFileAtomically -Path $commandPath -Payload $command

$result = [pscustomobject][ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    ConfigPath = [string]$config.ConfigPath
    RunMode = $RunMode
    RunRoot = $resolvedRunRoot
    WorkRepoRoot = [string]$queuePaths.WorkRepoRoot
    TargetRunRoot = [string]$queuePaths.TargetRunRoot
    TargetId = $TargetId
    CommandId = $commandId
    CommandPath = $commandPath
    PayloadRoot = $payloadRoot
    PromptFilePath = $promptSnapshotPath
    PromptSourcePath = $resolvedPromptFilePath
    PromptSnapshotPath = $promptSnapshotPath
    RequestSourcePath = $resolvedRequestFilePath
    RequestSnapshotPath = $requestSnapshotPath
    TriggerKind = $TriggerKind
    TriggerFingerprint = [string]$TriggerFingerprint
    LoopSource = $LoopSource
    PublishReadyDispatchDelayMode = [string]$PublishReadyDispatchDelayMode
    PublishReadyDispatchDelaySeconds = [int]$PublishReadyDispatchDelaySeconds
    PublishReadyDispatchMinDelaySeconds = [int]$PublishReadyDispatchMinDelaySeconds
    PublishReadyDispatchMaxDelaySeconds = [int]$PublishReadyDispatchMaxDelaySeconds
    DispatchEligibleAt = [string]$DispatchEligibleAt
    CycleId = [int]$CycleId
    ParentCycleId = [int]$ParentCycleId
    DispatchIntegrated = $false
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

$result
