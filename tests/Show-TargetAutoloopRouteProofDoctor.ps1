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

function Get-TargetAutoloopDoctorPathState {
    param([Parameter(Mandatory)][string]$Path)

    $item = $null
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($exists) {
        try {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        }
        catch {
            $item = $null
        }
    }

    return [pscustomobject]@{
        Path = [string]$Path
        Exists = [bool]$exists
        SizeBytes = if ($null -ne $item) { [int64]$item.Length } else { 0 }
        LastWriteAt = if ($null -ne $item) { $item.LastWriteTimeUtc.ToString('o') } else { '' }
    }
}

function Get-TargetAutoloopDoctorDirectoryCount {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return 0
    }

    return @(
        Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue
    ).Count
}

function Get-TargetAutoloopDoctorContractSnapshot {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$TargetId
    )

    $summaryState = Get-TargetAutoloopDoctorPathState -Path ([string]$Paths.SourceSummaryPath)
    $reviewState = Get-TargetAutoloopDoctorPathState -Path ([string]$Paths.SourceReviewZipPath)
    $publishState = Get-TargetAutoloopDoctorPathState -Path ([string]$Paths.PublishReadyPath)
    $core = Get-TargetAutoloopContractSnapshotCore -Paths $Paths -TargetId $TargetId -SummaryState $summaryState -ReviewZipState $reviewState -PublishReadyState $publishState

    return [pscustomobject]@{
        State = [string]$core.State
        Reason = [string]$core.Reason
        PublishReadyValid = [bool]$core.PublishReadyValid
        Summary = $summaryState
        ReviewZip = $reviewState
        PublishReady = $publishState
        OutputFingerprint = [string]$core.OutputFingerprint
        PublishedAt = [string]$core.PublishedAt
    }
}

function Get-TargetAutoloopDoctorCollisionSummaries {
    param([Parameter(Mandatory)]$Rows)

    $collisions = @()
    foreach ($fieldName in @('SourceSummaryPath', 'SourceReviewZipPath', 'PublishReadyPath')) {
        $groupMap = @{}
        foreach ($row in @($Rows)) {
            $targetId = [string](Get-ConfigValue -Object $row -Name 'TargetId' -DefaultValue '')
            $pathValue = [string](Get-ConfigValue -Object $row -Name $fieldName -DefaultValue '')
            $normalizedPath = Get-NormalizedFullPath -Path $pathValue
            if (-not (Test-NonEmptyString $normalizedPath)) {
                continue
            }
            if (-not $groupMap.ContainsKey($normalizedPath)) {
                $groupMap[$normalizedPath] = @()
            }
            $groupMap[$normalizedPath] = @($groupMap[$normalizedPath]) + @($targetId)
        }
        foreach ($normalizedPath in @($groupMap.Keys | Sort-Object)) {
            $targets = @($groupMap[$normalizedPath])
            if (@($targets).Count -lt 2) {
                continue
            }
            $collisions += [pscustomobject]@{
                Field = $fieldName
                Path = $normalizedPath
                TargetIds = @($targets)
                Count = @($targets).Count
            }
        }
    }
    return @($collisions)
}

$resolvedConfigPath = if (Test-NonEmptyString $ConfigPath) { (Resolve-Path -LiteralPath $ConfigPath).Path } else { Join-Path $root 'config\settings.bottest-live-visible.psd1' }
$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $resolvedConfigPath
$resolvedRunRoot = Resolve-TargetAutoloopRunRoot -Config $config -RequestedRunRoot $RunRoot
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
$manifestSummary = Get-TargetAutoloopManifestRouteSummary -Config $config -RunRoot $resolvedRunRoot -Mode ProofDoctor
$manifestPath = [string]$manifestSummary.ManifestPath
$manifestExists = [bool]$manifestSummary.ManifestExists
$manifestRunMode = [string]$manifestSummary.ManifestRunMode
$manifestTargetMap = $manifestSummary.ManifestTargetMap
$configEnabledTargetIds = @($manifestSummary.ConfigEnabledTargetIds)
$sortedManifestTargetIds = @($manifestSummary.SortedManifestTargetIds)
$sortedManifestEnabledTargetIds = @($manifestSummary.SortedManifestEnabledTargetIds)
$manifestPublishReadyTargetIds = @($manifestSummary.SortedManifestPublishReadyTargetIds)
$manifestPublishReadyMissingTargetIds = @($manifestSummary.SortedManifestPublishReadyMissingTargetIds)
$manifestScope = [string]$manifestSummary.ManifestScope
$manifestMismatch = [bool]$manifestSummary.ManifestMismatch
$manifestMismatchReason = [string]$manifestSummary.ManifestMismatchReason
$operationalRecommendation = [string]$manifestSummary.OperationalRecommendation

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
    $contract = Get-TargetAutoloopDoctorContractSnapshot -Paths $paths -TargetId $targetId
    $delivery = Get-TargetAutoloopDeliverySnapshot -Contract $contract -StateRecord $stateRecord -StatusRow $statusRow
    $inManifest = [bool]$manifestTargetMap.ContainsKey($targetId)
    $manifestTargetRecord = if ($inManifest) { $manifestTargetMap[$targetId] } else { $null }
    $manifestEnabled = if ($inManifest) { [bool](Get-ConfigValue -Object $manifestTargetRecord -Name 'Enabled' -DefaultValue $false) } else { $false }

    $row = [pscustomobject]@{
        TargetId = $targetId
        Enabled = [bool](Get-ConfigValue -Object $target -Name 'Enabled' -DefaultValue $false)
        InManifest = [bool]$inManifest
        ManifestEnabled = [bool]$manifestEnabled
        Phase = [string](Get-ConfigValue -Object $stateRecord -Name 'Phase' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'Phase' -DefaultValue '')))
        CycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'CycleCount' -DefaultValue ([int](Get-ConfigValue -Object $statusRow -Name 'CycleCount' -DefaultValue 0)))
        MaxCycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'MaxCycleCount' -DefaultValue ([int](Get-ConfigValue -Object $statusRow -Name 'MaxCycleCount' -DefaultValue 0)))
        NextAction = [string](Get-ConfigValue -Object $stateRecord -Name 'NextAction' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'NextAction' -DefaultValue '')))
        LastDispatchState = [string](Get-ConfigValue -Object $stateRecord -Name 'LastDispatchState' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'LastDispatchState' -DefaultValue '')))
        LastFailureReason = [string](Get-ConfigValue -Object $stateRecord -Name 'LastFailureReason' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'LastFailureReason' -DefaultValue '')))
        TriggerKinds = @($target.TriggerKinds)
        WorkRepoRoot = [string]$paths.WorkRepoRoot
        TargetRunRoot = [string]$paths.TargetRunRoot
        TargetRoot = [string]$paths.TargetRoot
        SourceSummaryPath = [string]$paths.SourceSummaryPath
        SourceReviewZipPath = [string]$paths.SourceReviewZipPath
        PublishReadyPath = [string]$paths.PublishReadyPath
        Contract = $contract
        Delivery = $delivery
        DeliverySummary = [string](Get-ConfigValue -Object $delivery -Name 'Summary' -DefaultValue '')
        DeliveryNextAction = [string](Get-ConfigValue -Object $delivery -Name 'NextAction' -DefaultValue '')
        DeliveryNextActionCode = [string](Get-ConfigValue -Object $delivery -Name 'NextActionCode' -DefaultValue '')
        DeliveryNextActionLabel = [string](Get-ConfigValue -Object $delivery -Name 'NextActionLabel' -DefaultValue '')
        InboxPendingCount = Get-TargetAutoloopDoctorDirectoryCount -Path ([string]$paths.InboxPendingRoot)
        QueueQueuedCount = Get-TargetAutoloopDoctorDirectoryCount -Path ([string]$queuePaths.QueuedRoot)
        QueueProcessingCount = Get-TargetAutoloopDoctorDirectoryCount -Path ([string]$queuePaths.ProcessingRoot)
        QueueCompletedCount = Get-TargetAutoloopDoctorDirectoryCount -Path ([string]$queuePaths.CompletedRoot)
        QueueFailedCount = Get-TargetAutoloopDoctorDirectoryCount -Path ([string]$queuePaths.FailedRoot)
    }
    $targetRows += $row
}

$collisions = @()
foreach ($fieldName in @('SourceSummaryPath', 'SourceReviewZipPath', 'PublishReadyPath')) {
    $groupMap = @{}
    foreach ($row in $targetRows) {
        $targetId = [string](Get-ConfigValue -Object $row -Name 'TargetId' -DefaultValue '')
        $pathValue = [string](Get-ConfigValue -Object $row -Name $fieldName -DefaultValue '')
        $normalizedPath = Get-NormalizedFullPath -Path $pathValue
        if (-not (Test-NonEmptyString $normalizedPath)) {
            continue
        }
        if (-not $groupMap.ContainsKey($normalizedPath)) {
            $groupMap[$normalizedPath] = @()
        }
        $groupMap[$normalizedPath] = @($groupMap[$normalizedPath]) + @($targetId)
    }
    foreach ($normalizedPath in @($groupMap.Keys | Sort-Object)) {
        $targets = @($groupMap[$normalizedPath])
        if (@($targets).Count -lt 2) {
            continue
        }
        $collisions += [pscustomobject]@{
            Field = $fieldName
            Path = $normalizedPath
            TargetIds = @($targets)
            Count = @($targets).Count
        }
    }
}
$counts = [ordered]@{
    TotalTargets = @($targetRows).Count
    EnabledTargets = @($targetRows | Where-Object { [bool]$_.Enabled }).Count
    ReadyContracts = @($targetRows | Where-Object { [string]$_.Contract.State -eq 'ready' }).Count
    PartialContracts = @($targetRows | Where-Object { [string]$_.Contract.State -eq 'partial' }).Count
    InvalidContracts = @($targetRows | Where-Object { [string]$_.Contract.State -eq 'invalid' }).Count
    MissingContracts = @($targetRows | Where-Object { [string]$_.Contract.State -eq 'missing' }).Count
    CollisionEntries = @($collisions).Count
}

$payload = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunRoot = $resolvedRunRoot
    ConfigPath = $resolvedConfigPath
    ManifestPath = [string]$manifestPath
    ManifestExists = [bool]$manifestExists
    ManifestRunMode = [string]$manifestRunMode
    ManifestTargetIds = @($sortedManifestTargetIds)
    ManifestEnabledTargetIds = @($sortedManifestEnabledTargetIds)
    ManifestPublishReadyTargetIds = @($manifestPublishReadyTargetIds | Sort-Object)
    ManifestPublishReadyMissingTargetIds = @($manifestPublishReadyMissingTargetIds | Sort-Object)
    ConfigEnabledTargetIds = @($configEnabledTargetIds)
    ManifestScope = [string]$manifestScope
    ManifestMismatch = [bool]$manifestMismatch
    ManifestMismatchReason = $(if ($manifestMismatch) { $manifestMismatchReason } else { '' })
    ManifestReasonCodes = @($manifestSummary.ReasonCodes)
    BlockingReasonCodes = @($manifestSummary.BlockingReasonCodes)
    OperationalRecommendation = [string]$operationalRecommendation
    ControllerState = [string](Get-ConfigValue -Object $statusDocument -Name 'ControllerState' -DefaultValue ([string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue 'unknown')))
    WatcherState = [string](Get-ConfigValue -Object $statusDocument -Name 'WatcherState' -DefaultValue '')
    WatcherStopReason = [string](Get-ConfigValue -Object $statusDocument -Name 'WatcherStopReason' -DefaultValue '')
    ProofReceipt = $proofReceipt
    ProofCloseout = $proofCloseout
    Counts = $counts
    Collisions = @($collisions)
    Targets = @($targetRows)
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
    return
}

$lines = @(
    'Target Autoloop Route/Proof Doctor'
    ('RunRoot: ' + [string]$payload.RunRoot)
    ('ConfigPath: ' + [string]$payload.ConfigPath)
)
$lines += @(Get-TargetAutoloopManifestRouteTextLines -Payload $payload -IncludeScope -IncludeOperationalRecommendation)
$lines += @(
    ('ControllerState: ' + [string]$payload.ControllerState)
    ('WatcherState: ' + $(if (Test-NonEmptyString ([string]$payload.WatcherState)) { [string]$payload.WatcherState } else { '(none)' }))
    ('WatcherStopReason: ' + $(if (Test-NonEmptyString ([string]$payload.WatcherStopReason)) { [string]$payload.WatcherStopReason } else { '(none)' }))
    ('SmokeSummary: ' + [string](Get-ConfigValue -Object $proofReceipt -Name 'Summary' -DefaultValue 'smoke: (없음)'))
    ('CloseoutSummary: ' + [string](Get-ConfigValue -Object $proofCloseout -Name 'Summary' -DefaultValue 'closeout: pending-proof / mode=not-ready / reason=no-proof'))
    ('CloseoutNextStep: ' + [string](Get-ConfigValue -Object $proofCloseout -Name 'RecommendedNextStep' -DefaultValue ''))
    ('Counts: total={0} enabled={1} ready={2} partial={3} invalid={4} missing={5} collisions={6}' -f
        [int]$counts.TotalTargets,
        [int]$counts.EnabledTargets,
        [int]$counts.ReadyContracts,
        [int]$counts.PartialContracts,
        [int]$counts.InvalidContracts,
        [int]$counts.MissingContracts,
        [int]$counts.CollisionEntries)
    ''
)

foreach ($row in @($targetRows)) {
    $cycleCount = [int](Get-ConfigValue -Object $row -Name 'CycleCount' -DefaultValue 0)
    $maxCycleCount = [int](Get-ConfigValue -Object $row -Name 'MaxCycleCount' -DefaultValue 0)
    $cycleLabel = if ($maxCycleCount -gt 0) { ('cycle {0}/{1}' -f $cycleCount, $maxCycleCount) } else { ('cycle {0}' -f $cycleCount) }
    $lines += ('{0} | {1} | {2} | next={3} | contract={4} | reason={5} | inbox={6} | queued={7} | processing={8} | completed={9} | failed={10}' -f
        [string]$row.TargetId,
        [string]$row.Phase,
        $cycleLabel,
        [string]$row.NextAction,
        [string]$row.Contract.State,
        [string]$row.Contract.Reason,
        [int]$row.InboxPendingCount,
        [int]$row.QueueQueuedCount,
        [int]$row.QueueProcessingCount,
        [int]$row.QueueCompletedCount,
        [int]$row.QueueFailedCount)
    $lines += ('  summary.txt: {0} [{1}]' -f [string]$row.SourceSummaryPath, $(if ([bool]$row.Contract.Summary.Exists) { 'exists' } else { 'missing' }))
    $lines += ('  review.zip: {0} [{1}]' -f [string]$row.SourceReviewZipPath, $(if ([bool]$row.Contract.ReviewZip.Exists) { 'exists' } else { 'missing' }))
    $lines += ('  publish.ready.json: {0} [{1}]' -f [string]$row.PublishReadyPath, $(if ([bool]$row.Contract.PublishReady.Exists) { 'exists' } else { 'missing' }))
    $lines += @(Get-TargetAutoloopDeliveryTextLines -Row $row)
    $lines += (Get-TargetAutoloopRouteRowManifestTextLine -Row $row)
    if (Test-NonEmptyString ([string]$row.LastDispatchState)) {
        $lines += ('  lastDispatch: ' + [string]$row.LastDispatchState)
    }
    if (Test-NonEmptyString ([string]$row.LastFailureReason)) {
        $lines += ('  lastFailure: ' + [string]$row.LastFailureReason)
    }
    $lines += ''
}

if (@($collisions).Count -gt 0) {
    $lines += 'Collisions:'
    foreach ($collision in @($collisions)) {
        $lines += ('- {0}: {1} <= {2}' -f [string]$collision.Field, [string]$collision.Path, (@($collision.TargetIds) -join ', '))
    }
}
else {
    $lines += 'Collisions: (none)'
}

$lines -join [Environment]::NewLine
