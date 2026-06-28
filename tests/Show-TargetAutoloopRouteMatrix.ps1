[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')

function Get-TargetAutoloopRouteMatrixPathState {
    param([Parameter(Mandatory)][string]$Path)

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    return [pscustomobject]@{
        Path = [string]$Path
        Exists = [bool]$exists
    }
}

function Get-TargetAutoloopRouteMatrixContractSnapshot {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$TargetId
    )

    $summaryState = Get-TargetAutoloopRouteMatrixPathState -Path ([string]$Paths.SourceSummaryPath)
    $reviewState = Get-TargetAutoloopRouteMatrixPathState -Path ([string]$Paths.SourceReviewZipPath)
    $publishState = Get-TargetAutoloopRouteMatrixPathState -Path ([string]$Paths.PublishReadyPath)
    $core = Get-TargetAutoloopContractSnapshotCore -Paths $Paths -TargetId $TargetId -SummaryState $summaryState -ReviewZipState $reviewState -PublishReadyState $publishState

    return [pscustomobject]@{
        State = [string]$core.State
        Reason = [string]$core.Reason
        PublishReadyValid = [bool]$core.PublishReadyValid
        SummaryExists = [bool]$core.SummaryExists
        ReviewZipExists = [bool]$core.ReviewZipExists
        PublishReadyExists = [bool]$core.PublishReadyExists
        OutputFingerprint = [string]$core.OutputFingerprint
        PublishedAt = [string]$core.PublishedAt
    }
}

function Resolve-TargetAutoloopRouteMatrixRunContext {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$RequestedRunRoot = ''
    )

    if (Test-NonEmptyString $RequestedRunRoot) {
        $resolved = if ([System.IO.Path]::IsPathRooted($RequestedRunRoot)) {
            [System.IO.Path]::GetFullPath($RequestedRunRoot)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path ([string]$Config.Root) $RequestedRunRoot))
        }
        return [pscustomobject]@{
            RunRoot = $resolved
            RunRootMode = 'selected'
            RunRootExists = [bool](Test-Path -LiteralPath $resolved -PathType Container)
        }
    }

    try {
        $resolvedLatest = Resolve-TargetAutoloopRunRoot -Config $Config
        return [pscustomobject]@{
            RunRoot = $resolvedLatest
            RunRootMode = 'latest-existing'
            RunRootExists = $true
        }
    }
    catch {
        $previewRoot = Join-Path ([string]$Config.RunRootBase) 'run_preview'
        return [pscustomobject]@{
            RunRoot = $previewRoot
            RunRootMode = 'preview'
            RunRootExists = [bool](Test-Path -LiteralPath $previewRoot -PathType Container)
        }
    }
}

$resolvedConfigPath = if (Test-NonEmptyString $ConfigPath) { (Resolve-Path -LiteralPath $ConfigPath).Path } else { Join-Path $root 'config\settings.bottest-live-visible.psd1' }
$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $resolvedConfigPath
$runContext = Resolve-TargetAutoloopRouteMatrixRunContext -Config $config -RequestedRunRoot $RunRoot
$resolvedRunRoot = [string]$runContext.RunRoot
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
$manifestSummary = Get-TargetAutoloopManifestRouteSummary -Config $config -RunRoot $resolvedRunRoot -Mode RouteMatrix
$manifestPath = [string]$manifestSummary.ManifestPath
$manifestExists = [bool]$manifestSummary.ManifestExists
$manifestRunMode = [string]$manifestSummary.ManifestRunMode
$manifestTargetMap = $manifestSummary.ManifestTargetMap
$configEnabledTargetIds = @($manifestSummary.ConfigEnabledTargetIds)
$sortedManifestEnabledTargetIds = @($manifestSummary.SortedManifestEnabledTargetIds)
$sortedManifestTargetIds = @($manifestSummary.SortedManifestTargetIds)
$manifestPublishReadyTargetIds = @($manifestSummary.SortedManifestPublishReadyTargetIds)
$manifestPublishReadyMissingTargetIds = @($manifestSummary.SortedManifestPublishReadyMissingTargetIds)
$manifestMismatch = [bool]$manifestSummary.ManifestMismatch
$manifestMismatchReason = [string]$manifestSummary.ManifestMismatchReason

$stateDocument = if (Test-Path -LiteralPath $statePaths.StatePath -PathType Leaf) { Read-JsonObject -Path $statePaths.StatePath } else { [pscustomobject]@{} }
$statusDocument = if (Test-Path -LiteralPath $statePaths.StatusPath -PathType Leaf) { Read-JsonObject -Path $statePaths.StatusPath } else { [pscustomobject]@{} }
$controlDocument = if (Test-Path -LiteralPath $statePaths.ControlPath -PathType Leaf) { Read-JsonObject -Path $statePaths.ControlPath } else { [pscustomobject]@{} }
$stateTargetMap = Get-TargetAutoloopTargetStateMap -StateDocument $stateDocument
$statusRows = @(Get-ConfigValue -Object $statusDocument -Name 'Targets' -DefaultValue @())
$statusRowMap = @{}
foreach ($row in @($statusRows)) {
    $targetId = [string](Get-ConfigValue -Object $row -Name 'TargetId' -DefaultValue '')
    if (Test-NonEmptyString $targetId) {
        $statusRowMap[$targetId] = $row
    }
}

$proofReceipt = Get-TargetAutoloopProofReceiptSummary `
    -SmokeReceiptPath $statePaths.SmokeReceiptPath `
    -AcceptanceReceiptPath $statePaths.AcceptanceReceiptPath `
    -TargetRows @($statusRows)
$proofCloseout = Get-TargetAutoloopProofCloseoutSummary -ProofReceipt $proofReceipt

$targetRows = @()
foreach ($target in @($config.Targets | Sort-Object TargetId)) {
    $targetId = [string]$target.TargetId
    $paths = Get-TargetAutoloopTargetPaths -RunRoot $resolvedRunRoot -TargetId $targetId -Target $target -Config $config
    $queuePaths = Get-TargetAutoloopQueuePaths -RunRoot $resolvedRunRoot -TargetId $targetId -Target $target -Config $config
    $stateRecord = if ($stateTargetMap.Contains($targetId)) { $stateTargetMap[$targetId] } else { $null }
    $statusRow = if ($statusRowMap.ContainsKey($targetId)) { $statusRowMap[$targetId] } else { $null }
    $enabled = [bool](Get-ConfigValue -Object $target -Name 'Enabled' -DefaultValue $false)
    $inManifest = [bool]$manifestTargetMap.ContainsKey($targetId)
    $manifestTargetRecord = if ($inManifest) { $manifestTargetMap[$targetId] } else { $null }
    $manifestEnabled = if ($inManifest) { [bool](Get-ConfigValue -Object $manifestTargetRecord -Name 'Enabled' -DefaultValue $false) } else { $false }
    $defaultPhase = if ($enabled) { 'idle' } else { 'disabled' }
    $defaultNextAction = if ($enabled) {
        Get-TargetAutoloopDefaultNextAction -TriggerKinds @($target.TriggerKinds)
    }
    else {
        'no-op'
    }
    $contract = Get-TargetAutoloopRouteMatrixContractSnapshot -Paths $paths -TargetId $targetId
    $delivery = Get-TargetAutoloopDeliverySnapshot -Contract $contract -StateRecord $stateRecord -StatusRow $statusRow
    $contractState = [string](Get-ConfigValue -Object $contract -Name 'State' -DefaultValue 'missing')
    $routeBadge = if (-not $enabled) {
        'DISABLED'
    }
    elseif ($contractState -eq 'ready') {
        'ROUTE READY'
    }
    elseif ($contractState -in @('partial', 'invalid')) {
        'ROUTE CHECK'
    }
    else {
        'ROUTE EMPTY'
    }
    $cycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'CycleCount' -DefaultValue ([int](Get-ConfigValue -Object $statusRow -Name 'CycleCount' -DefaultValue 0)))
    $maxCycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'MaxCycleCount' -DefaultValue ([int](Get-ConfigValue -Object $statusRow -Name 'MaxCycleCount' -DefaultValue ([int]$target.MaxCycleCount))))

    $targetRows += [pscustomobject]@{
        TargetId = $targetId
        Enabled = $enabled
        InManifest = [bool]$inManifest
        ManifestEnabled = [bool]$manifestEnabled
        RouteBadge = $routeBadge
        ContractState = $contractState
        ContractReason = [string](Get-ConfigValue -Object $contract -Name 'Reason' -DefaultValue '')
        TriggerKinds = @($target.TriggerKinds)
        CycleCount = $cycleCount
        MaxCycleCount = $maxCycleCount
        Phase = [string](Get-ConfigValue -Object $stateRecord -Name 'Phase' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'Phase' -DefaultValue $defaultPhase)))
        NextAction = [string](Get-ConfigValue -Object $stateRecord -Name 'NextAction' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'NextAction' -DefaultValue $defaultNextAction)))
        FixedSuffix = [string](Get-ConfigValue -Object $target -Name 'FixedSuffix' -DefaultValue '')
        WorkRepoRoot = [string]$paths.WorkRepoRoot
        TargetRunRoot = [string]$paths.TargetRunRoot
        SourceSummaryPath = [string]$paths.SourceSummaryPath
        SourceReviewZipPath = [string]$paths.SourceReviewZipPath
        PublishReadyPath = [string]$paths.PublishReadyPath
        SourceOutboxPath = [string]$paths.SourceOutboxRoot
        QueueRoot = [string]$queuePaths.QueueRoot
        Delivery = $delivery
        DeliverySummary = [string](Get-ConfigValue -Object $delivery -Name 'Summary' -DefaultValue '')
        DeliveryNextAction = [string](Get-ConfigValue -Object $delivery -Name 'NextAction' -DefaultValue '')
        DeliveryNextActionCode = [string](Get-ConfigValue -Object $delivery -Name 'NextActionCode' -DefaultValue '')
        DeliveryNextActionLabel = [string](Get-ConfigValue -Object $delivery -Name 'NextActionLabel' -DefaultValue '')
    }
}

$counts = [ordered]@{
    TotalTargets = @($targetRows).Count
    EnabledTargets = @($targetRows | Where-Object { [bool]$_.Enabled }).Count
    DisabledTargets = @($targetRows | Where-Object { -not [bool]$_.Enabled }).Count
    RouteReadyTargets = @($targetRows | Where-Object { [string]$_.RouteBadge -eq 'ROUTE READY' }).Count
    RouteCheckTargets = @($targetRows | Where-Object { [string]$_.RouteBadge -eq 'ROUTE CHECK' }).Count
    RouteEmptyTargets = @($targetRows | Where-Object { [string]$_.RouteBadge -eq 'ROUTE EMPTY' }).Count
    ReadyContracts = @($targetRows | Where-Object { [string]$_.ContractState -eq 'ready' }).Count
    PartialContracts = @($targetRows | Where-Object { [string]$_.ContractState -eq 'partial' }).Count
    InvalidContracts = @($targetRows | Where-Object { [string]$_.ContractState -eq 'invalid' }).Count
    MissingContracts = @($targetRows | Where-Object { [string]$_.ContractState -eq 'missing' }).Count
}

$payload = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    RunRootMode = [string]$runContext.RunRootMode
    RunRootExists = [bool]$runContext.RunRootExists
    PathMode = 'strict-explicit-per-target'
    ManifestPath = [string]$manifestPath
    ManifestExists = [bool]$manifestExists
    ManifestRunMode = [string]$manifestRunMode
    ManifestTargetIds = @($sortedManifestTargetIds)
    ManifestEnabledTargetIds = @($sortedManifestEnabledTargetIds)
    ManifestPublishReadyTargetIds = @($manifestPublishReadyTargetIds | Sort-Object)
    ManifestPublishReadyMissingTargetIds = @($manifestPublishReadyMissingTargetIds | Sort-Object)
    ConfigEnabledTargetIds = @($configEnabledTargetIds)
    ManifestMismatch = [bool]$manifestMismatch
    ManifestMismatchReason = $(if ($manifestMismatch) { $manifestMismatchReason } else { '' })
    ManifestReasonCodes = @($manifestSummary.ReasonCodes)
    BlockingReasonCodes = @($manifestSummary.BlockingReasonCodes)
    ControllerState = [string](Get-ConfigValue -Object $statusDocument -Name 'ControllerState' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue 'unknown')))
    WatcherState = [string](Get-ConfigValue -Object $statusDocument -Name 'WatcherState' -DefaultValue '')
    ProofReceipt = $proofReceipt
    ProofCloseout = $proofCloseout
    Counts = $counts
    Targets = @($targetRows)
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 10
    return
}

$lines = @(
    'Target Autoloop Route Matrix'
    ('ConfigPath: ' + [string]$payload.ConfigPath)
    ('RunRoot: ' + [string]$payload.RunRoot)
    ('RunRootMode: ' + [string]$payload.RunRootMode)
    ('RunRootExists: ' + [string]$payload.RunRootExists)
)
$lines += @(Get-TargetAutoloopManifestRouteTextLines -Payload $payload)
$lines += @(
    ('PathMode: ' + [string]$payload.PathMode)
    ('ControllerState: ' + [string]$payload.ControllerState)
    ('WatcherState: ' + $(if (Test-NonEmptyString ([string]$payload.WatcherState)) { [string]$payload.WatcherState } else { '(none)' }))
    ('SmokeSummary: ' + [string](Get-ConfigValue -Object $proofReceipt -Name 'Summary' -DefaultValue 'smoke: (없음)'))
    ('CloseoutSummary: ' + [string](Get-ConfigValue -Object $proofCloseout -Name 'Summary' -DefaultValue 'closeout: pending-proof / mode=not-ready / reason=no-proof'))
    ('CloseoutNextStep: ' + [string](Get-ConfigValue -Object $proofCloseout -Name 'RecommendedNextStep' -DefaultValue ''))
    ('Counts: total={0} enabled={1} routeReady={2} routeCheck={3} routeEmpty={4} disabled={5} contractReady={6} partial={7} invalid={8} missing={9}' -f
        [int]$counts.TotalTargets,
        [int]$counts.EnabledTargets,
        [int]$counts.RouteReadyTargets,
        [int]$counts.RouteCheckTargets,
        [int]$counts.RouteEmptyTargets,
        [int]$counts.DisabledTargets,
        [int]$counts.ReadyContracts,
        [int]$counts.PartialContracts,
        [int]$counts.InvalidContracts,
        [int]$counts.MissingContracts)
    ''
)

foreach ($row in @($targetRows)) {
    $triggerKinds = @($row.TriggerKinds | ForEach-Object { [string]$_ }) -join ','
    $lines += ('{0} | {1} | {2} | contract={3} | cycle {4}/{5} | phase={6} | next={7} | triggers={8}' -f
        [string]$row.TargetId,
        $(if ([bool]$row.Enabled) { 'enabled' } else { 'disabled' }),
        [string]$row.RouteBadge,
        [string]$row.ContractState,
        [int]$row.CycleCount,
        [int]$row.MaxCycleCount,
        [string]$row.Phase,
        [string]$row.NextAction,
        $triggerKinds)
    if (Test-NonEmptyString ([string]$row.FixedSuffix)) {
        $lines += ('  fixedSuffix: ' + [string]$row.FixedSuffix)
    }
    $lines += (Get-TargetAutoloopRouteRowManifestTextLine -Row $row)
    if (Test-NonEmptyString ([string]$row.WorkRepoRoot)) {
        $lines += ('  workRepoRoot: ' + [string]$row.WorkRepoRoot)
        $lines += ('  targetRunRoot: ' + [string]$row.TargetRunRoot)
    }
    $lines += ('  summary: ' + [string]$row.SourceSummaryPath)
    $lines += ('  review : ' + [string]$row.SourceReviewZipPath)
    $lines += ('  publish: ' + [string]$row.PublishReadyPath)
    $lines += ('  queue  : ' + [string]$row.QueueRoot)
    $lines += @(Get-TargetAutoloopDeliveryTextLines -Row $row)
    $lines += ''
}

$lines -join [Environment]::NewLine
