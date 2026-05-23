[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [ValidateSet('target-inbox-submit', 'target-autoloop')][string]$RunMode = '',
    [string[]]$Targets = @(),
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
if (Test-NonEmptyString $RunMode) {
    if ($config -is [System.Collections.IDictionary]) {
        $config['RunMode'] = $RunMode
    }
    else {
        $config.RunMode = $RunMode
    }
}

$selectedTargets = @(
    $Targets |
        Where-Object { Test-NonEmptyString $_ } |
        ForEach-Object { [string]$_ } |
        Sort-Object -Unique
)
if (@($selectedTargets).Count -eq 0) {
    $selectedTargets = @($config.Targets | Where-Object { [bool]$_.Enabled } | ForEach-Object { [string]$_.TargetId })
}
if (@($selectedTargets).Count -eq 0) {
    throw 'no target-autoloop targets were selected. configure TargetAutoloop.Targets.Enabled or pass -Targets.'
}

$selectedSet = @{}
foreach ($targetId in @($selectedTargets)) {
    $selectedSet[$targetId] = $true
}
foreach ($targetId in @($selectedTargets)) {
    if ($config.RequireTargetMetadata -and $targetId -notin @($config.SupportedTargetIds)) {
        throw ("selected target is not part of the configured official targets: {0}" -f $targetId)
    }
}

$resolvedRunRoot = if (Test-NonEmptyString $RunRoot) {
    if ([System.IO.Path]::IsPathRooted($RunRoot)) {
        [System.IO.Path]::GetFullPath($RunRoot)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $root $RunRoot))
    }
}
else {
    Ensure-Directory -Path ([string]$config.RunRootBase)
    $runLeaf = 'run_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    Join-Path ([string]$config.RunRootBase) $runLeaf
}

Ensure-Directory -Path $resolvedRunRoot
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
Ensure-Directory -Path $statePaths.StateRoot
if (Test-Path -LiteralPath $statePaths.SmokeReceiptPath -PathType Leaf) {
    Remove-Item -LiteralPath $statePaths.SmokeReceiptPath -Force
}

$manifestTargets = New-Object System.Collections.Generic.List[object]
$routePathKeys = @{}
foreach ($target in @($config.Targets | Where-Object { $selectedSet.ContainsKey([string]$_.TargetId) })) {
    $targetId = [string]$target.TargetId
    $paths = Get-TargetAutoloopTargetPaths -RunRoot $resolvedRunRoot -TargetId $targetId -Target $target -Config $config
    Ensure-TargetAutoloopTargetDirectories -Paths $paths

    $queuePaths = Get-TargetAutoloopQueuePaths -RunRoot $resolvedRunRoot -TargetId $targetId -Target $target -Config $config
    foreach ($queuePath in @($queuePaths.QueuedRoot, $queuePaths.ProcessingRoot, $queuePaths.CompletedRoot, $queuePaths.FailedRoot)) {
        Ensure-Directory -Path $queuePath
    }

    foreach ($routePath in @(
            @{ Label = 'InboxPendingRoot'; Path = [string]$paths.InboxPendingRoot },
            @{ Label = 'SourceOutboxPath'; Path = [string]$paths.SourceOutboxRoot },
            @{ Label = 'QueueRoot'; Path = [string]$queuePaths.QueueRoot }
        )) {
        $routeKey = Get-NormalizedFullPath -Path ([string]$routePath.Path)
        if (-not (Test-NonEmptyString $routeKey)) {
            continue
        }
        if ($routePathKeys.ContainsKey($routeKey)) {
            throw ('target-autoloop path collision: target={0} label={1} path={2} conflictsWith={3}' -f $targetId, [string]$routePath.Label, [string]$routePath.Path, [string]$routePathKeys[$routeKey])
        }
        $routePathKeys[$routeKey] = ('{0}:{1}' -f $targetId, [string]$routePath.Label)
    }

    $manifestTargets.Add([ordered]@{
            TargetId = $targetId
            Enabled = [bool]$target.Enabled
            FixedSuffix = [string]$target.FixedSuffix
            WorkRepoRoot = [string]$paths.WorkRepoRoot
            TargetRunRoot = [string]$paths.TargetRunRoot
            CoordinatorRunRoot = [string]$paths.CoordinatorRunRoot
            CooldownSeconds = [int]$target.CooldownSeconds
            PublishReadyDispatchDelayMode = [string]$target.PublishReadyDispatchDelayMode
            PublishReadyDispatchDelaySeconds = [int]$target.PublishReadyDispatchDelaySeconds
            PublishReadyDispatchMinDelaySeconds = [int]$target.PublishReadyDispatchMinDelaySeconds
            PublishReadyDispatchMaxDelaySeconds = [int]$target.PublishReadyDispatchMaxDelaySeconds
            MaxCycleCount = [int]$target.MaxCycleCount
            TriggerKinds = @($target.TriggerKinds)
            WindowTitle = [string]$target.WindowTitle
            GlobalFolder = [string]$target.GlobalFolder
            InboxRoot = [string]$paths.InboxRoot
            InboxPendingRoot = [string]$paths.InboxPendingRoot
            InboxClaimedRoot = [string]$paths.InboxClaimedRoot
            InboxProcessedRoot = [string]$paths.InboxProcessedRoot
            InboxFailedRoot = [string]$paths.InboxFailedRoot
            WorkRoot = [string]$paths.WorkRoot
            CurrentRequestPath = [string]$paths.CurrentRequestPath
            LastPromptPath = [string]$paths.LastPromptPath
            SourceOutboxPath = [string]$paths.SourceOutboxRoot
            SourceSummaryPath = [string]$paths.SourceSummaryPath
            SourceReviewZipPath = [string]$paths.SourceReviewZipPath
            PublishReadyPath = [string]$paths.PublishReadyPath
            ReceiptsRoot = [string]$paths.ReceiptsRoot
            QueueRoot = [string]$queuePaths.QueueRoot
            QueueQueuedRoot = [string]$queuePaths.QueuedRoot
            QueueProcessingRoot = [string]$queuePaths.ProcessingRoot
            QueueCompletedRoot = [string]$queuePaths.CompletedRoot
            QueueFailedRoot = [string]$queuePaths.FailedRoot
            QueuePayloadRoot = [string]$queuePaths.PayloadRoot
        }) | Out-Null
}

$stateDocument = New-TargetAutoloopStateDocument -Config $config -RunRoot $resolvedRunRoot -SelectedTargetIds @($selectedTargets)
$controlDocument = New-TargetAutoloopControlDocument -Config $config -RunRoot $resolvedRunRoot
$statusDocument = New-TargetAutoloopStatusDocument -Config $config -RunRoot $resolvedRunRoot -StateDocument $stateDocument -ControlDocument $controlDocument

$manifest = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    CreatedAt = (Get-Date).ToString('o')
    RunMode = [string]$config.RunMode
    ConfigPath = [string]$config.ConfigPath
    RunRoot = $resolvedRunRoot
    LaneName = [string]$config.LaneName
    PairSystemUntouched = $true
    ModeCapabilities = [ordered]@{
        CommandQueue = $true
        TypedWindowDispatch = $false
        RouterReadyDispatch = [bool]$config.DispatchQueuedCommandsInline
        PublishReadyLoop = ([string]$config.RunMode -eq 'target-autoloop')
    }
    TargetAutoloop = [ordered]@{
        Enabled = [bool]$config.Enabled
        MutexScope = [string]$config.MutexScope
        MaxConcurrentTargets = [int]$config.MaxConcurrentTargets
        MaxConcurrentSubmits = [int]$config.MaxConcurrentSubmits
        DispatchQueuedCommandsInline = [bool]$config.DispatchQueuedCommandsInline
        DefaultCooldownSeconds = [int]$config.DefaultCooldownSeconds
        DefaultPublishReadyDispatchDelayMode = [string]$config.DefaultPublishReadyDispatchDelayMode
        DefaultPublishReadyDispatchDelaySeconds = [int]$config.DefaultPublishReadyDispatchDelaySeconds
        DefaultPublishReadyDispatchMinDelaySeconds = [int]$config.DefaultPublishReadyDispatchMinDelaySeconds
        DefaultPublishReadyDispatchMaxDelaySeconds = [int]$config.DefaultPublishReadyDispatchMaxDelaySeconds
        DefaultMaxCycleCount = [int]$config.DefaultMaxCycleCount
        RequireExplicitContractPath = [bool]$config.RequireExplicitContractPath
        RequireTargetMetadata = [bool]$config.RequireTargetMetadata
        AllowRecursiveWatch = [bool]$config.AllowRecursiveWatch
        PollIntervalMs = [int]$config.PollIntervalMs
    }
    StatePaths = [ordered]@{
        StatePath = [string]$statePaths.StatePath
        StatusPath = [string]$statePaths.StatusPath
        ControlPath = [string]$statePaths.ControlPath
        EventsPath = [string]$statePaths.EventsPath
        SmokeReceiptPath = [string]$statePaths.SmokeReceiptPath
    }
    Targets = $manifestTargets.ToArray()
}

$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
Write-JsonFileAtomically -Path $manifestPath -Payload $manifest
Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
Write-JsonFileAtomically -Path $statePaths.StatusPath -Payload $statusDocument
if (-not (Test-Path -LiteralPath $statePaths.EventsPath -PathType Leaf)) {
    '' | Set-Content -LiteralPath $statePaths.EventsPath -Encoding UTF8
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunMode = [string]$config.RunMode
    ConfigPath = [string]$config.ConfigPath
    RunRoot = $resolvedRunRoot
    ManifestPath = $manifestPath
    StatePath = [string]$statePaths.StatePath
    StatusPath = [string]$statePaths.StatusPath
    ControlPath = [string]$statePaths.ControlPath
    EventsPath = [string]$statePaths.EventsPath
    SmokeReceiptPath = [string]$statePaths.SmokeReceiptPath
    TargetIds = @($selectedTargets)
    QueueDispatchIntegrated = $false
    RouterReadyDispatchIntegrated = [bool]$config.DispatchQueuedCommandsInline
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Host ('prepared target autoloop root: ' + $resolvedRunRoot)
$result
