[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$TargetId,
    [string]$TaskText = '',
    [string]$ReferenceInputPath = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')

function Quote-PowerShellLiteral {
    param([string]$Value)

    return ("'" + [string]($Value -replace "'", "''") + "'")
}

function Get-TargetAutoloopSeedComposerPathState {
    param([Parameter(Mandatory)][string]$Path)

    return [pscustomobject]@{
        Path = [string]$Path
        Exists = [bool](Test-Path -LiteralPath $Path -PathType Leaf)
    }
}

function Get-TargetAutoloopSeedComposerInputPathState {
    param(
        [AllowEmptyString()][string]$ReferenceInputPath,
        [Parameter(Mandatory)][string]$AutomationRoot
    )

    if (-not (Test-NonEmptyString $ReferenceInputPath)) {
        return [pscustomobject]@{
            Path = ''
            ResolvedPath = ''
            Exists = $false
            Scope = 'none'
            ExistsLabel = 'none'
            ScopeLabel = 'none'
            Badge = 'INPUT NONE'
            CheckReason = 'none'
            Warning = ''
            Summary = '추가 입력 파일: (없음)'
        }
    }

    $resolvedPath = if ([System.IO.Path]::IsPathRooted($ReferenceInputPath)) {
        [System.IO.Path]::GetFullPath($ReferenceInputPath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ReferenceInputPath))
    }
    $exists = [bool](Test-Path -LiteralPath $resolvedPath -PathType Leaf)
    $normalizedAutomationRoot = [System.IO.Path]::GetFullPath($AutomationRoot).TrimEnd('\')
    $normalizedResolvedPath = $resolvedPath.TrimEnd('\')
    $withinAutomationRepo = (
        $normalizedResolvedPath.Equals($normalizedAutomationRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedResolvedPath.StartsWith(($normalizedAutomationRoot + '\'), [System.StringComparison]::OrdinalIgnoreCase)
    )
    $scope = if ($withinAutomationRepo) { 'automation-repo' } else { 'external' }
    $existsLabel = if ($exists) { 'present' } else { 'missing' }
    $scopeLabel = if ($scope -eq 'external') { 'external' } else { 'automation-repo' }
    $badge = if ($exists -and $scope -eq 'external') { 'INPUT READY' } else { 'INPUT CHECK' }
    $reasons = @()
    if (-not $exists) {
        $reasons += 'missing'
    }
    if ($scope -eq 'automation-repo') {
        $reasons += 'automation-repo'
    }
    $checkReason = if (@($reasons).Count -gt 0) { [string]::Join('+', @($reasons)) } else { 'none' }
    $warning = switch ($checkReason) {
        'missing' { '입력 파일이 아직 없습니다.' }
        'automation-repo' { '입력 파일이 automation repo 아래 경로라 shared visible 기준에 맞지 않습니다.' }
        'missing+automation-repo' { '입력 파일이 아직 없고 automation repo 아래 경로라 shared visible 기준에 맞지 않습니다.' }
        default { '' }
    }

    return [pscustomobject]@{
        Path = [string]$ReferenceInputPath
        ResolvedPath = $resolvedPath
        Exists = $exists
        Scope = $scope
        ExistsLabel = $existsLabel
        ScopeLabel = $scopeLabel
        Badge = $badge
        CheckReason = $checkReason
        Warning = $warning
        Summary = ('추가 입력 파일: {0} / {1} / {2}' -f $existsLabel, $scopeLabel, $resolvedPath)
    }
}

function Get-TargetAutoloopSeedComposerInputRecommendation {
    param([Parameter(Mandatory)]$InputPathState)

    $badge = [string](Get-ConfigValue -Object $InputPathState -Name 'Badge' -DefaultValue 'INPUT NONE')
    $checkReason = [string](Get-ConfigValue -Object $InputPathState -Name 'CheckReason' -DefaultValue 'none')

    if ($badge -eq 'INPUT READY') {
        return [pscustomobject]@{
            Action = 'open-input'
            Label = '입력 파일 열기'
            Detail = '현재 외부 repo 입력 파일이 존재합니다. 열어서 내용을 먼저 확인하세요.'
        }
    }

    switch ($checkReason) {
        'missing' {
            return [pscustomobject]@{
                Action = 'browse-input'
                Label = '입력 파일 다시 선택'
                Detail = '경로는 외부지만 파일이 없습니다. 존재하는 파일을 다시 선택하세요.'
            }
        }
        'automation-repo' {
            return [pscustomobject]@{
                Action = 'browse-external-input'
                Label = '외부 repo 파일 선택'
                Detail = 'automation repo 아래 입력 파일은 shared visible 기준에 맞지 않습니다. 외부 repo 파일로 바꾸세요.'
            }
        }
        'missing+automation-repo' {
            return [pscustomobject]@{
                Action = 'browse-external-input'
                Label = '외부 repo 파일 다시 선택'
                Detail = '현재 경로는 automation repo 아래이고 파일도 없습니다. 외부 repo에 있는 실제 파일을 다시 선택하세요.'
            }
        }
        default {
            return [pscustomobject]@{
                Action = 'browse-input'
                Label = '입력 파일 선택'
                Detail = '추가 입력 파일이 필요하면 외부 repo 경로의 파일을 선택하세요.'
            }
        }
    }
}

function Get-TargetAutoloopSeedComposerQueueState {
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskText,
        [Parameter(Mandatory)]$InputPathState,
        [Parameter(Mandatory)][bool]$RunRootExists,
        [Parameter(Mandatory)][string]$RunRootMode,
        [Parameter(Mandatory)]$OperationalNotice
    )

    if (-not $Enabled) {
        return [pscustomobject]@{
            Allowed = $false
            BlockedReason = 'target가 비활성화되어 있어 초기 입력 queue를 등록할 수 없습니다.'
            Summary = 'queue: blocked / target-disabled'
        }
    }

    if (-not $RunRootExists -or $RunRootMode -eq 'preview') {
        return [pscustomobject]@{
            Allowed = $false
            BlockedReason = '실제 RunRoot가 아직 준비되지 않았습니다. target-autoloop run을 먼저 시작하세요.'
            Summary = 'queue: blocked / runroot-not-ready'
        }
    }

    if ([bool](Get-ConfigValue -Object $OperationalNotice -Name 'BlocksQueue' -DefaultValue $false)) {
        $summary = [string](Get-ConfigValue -Object $OperationalNotice -Name 'Summary' -DefaultValue '')
        return [pscustomobject]@{
            Allowed = $false
            BlockedReason = if (Test-NonEmptyString $summary) { $summary } else { '현재 target 상태에서는 queue 등록을 진행할 수 없습니다.' }
            Summary = ('queue: blocked / {0}' -f [string](Get-ConfigValue -Object $OperationalNotice -Name 'ReasonCode' -DefaultValue 'operational-blocked'))
        }
    }

    $inputBadge = [string](Get-ConfigValue -Object $InputPathState -Name 'Badge' -DefaultValue 'INPUT NONE')
    $inputWarning = [string](Get-ConfigValue -Object $InputPathState -Name 'Warning' -DefaultValue '')
    $hasTaskText = Test-NonEmptyString $TaskText
    $hasInputPath = Test-NonEmptyString ([string](Get-ConfigValue -Object $InputPathState -Name 'ResolvedPath' -DefaultValue ''))

    if (-not $hasTaskText -and -not $hasInputPath) {
        return [pscustomobject]@{
            Allowed = $false
            BlockedReason = '작업 설명 또는 추가 입력 파일이 필요합니다.'
            Summary = 'queue: blocked / missing-task-and-input'
        }
    }

    if ($inputBadge -eq 'INPUT CHECK') {
        return [pscustomobject]@{
            Allowed = $false
            BlockedReason = if (Test-NonEmptyString $inputWarning) { $inputWarning } else { '추가 입력 파일 상태가 INPUT CHECK라 queue 등록을 진행할 수 없습니다.' }
            Summary = 'queue: blocked / input-check'
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        BlockedReason = ''
        Summary = 'queue: ready / input-file trigger로 watcher가 다음 sweep에서 처리합니다.'
    }
}

function Get-TargetAutoloopSeedComposerOperationalNotice {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Phase,
        [Parameter(Mandatory)][int]$CycleCount,
        [Parameter(Mandatory)][int]$MaxCycleCount,
        [Parameter(Mandatory)][bool]$PublishReadyTriggerEnabled,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RouterSessionState,
        [Parameter(Mandatory)][bool]$RouterSessionMismatch,
        [Parameter(Mandatory)][int]$RouterPid,
        [Parameter(Mandatory)][bool]$RouterPidExists,
        [Parameter(Mandatory)][bool]$RouterMutexHeld
    )

    $phaseValue = [string]$Phase
    $limitReached = ($phaseValue -eq 'limit-reached') -or ($MaxCycleCount -gt 0 -and $CycleCount -ge $MaxCycleCount)
    if ($limitReached) {
        return [pscustomobject]@{
            State = 'blocked'
            ReasonCode = 'max-cycle-reached'
            BlocksQueue = $true
            Summary = ('진행 중지: target이 MaxCycleCount에 도달했습니다. cycle={0}/{1}, phase={2}. 같은 RunRoot에 publish.ready.json을 다시 만들어도 다음 action은 생성되지 않습니다. 새 RunRoot를 준비하거나 MaxCycleCount를 늘린 뒤 다시 시작하세요.' -f $CycleCount, $MaxCycleCount, $(if (Test-NonEmptyString $phaseValue) { $phaseValue } else { '-' }))
        }
    }

    if (-not $PublishReadyTriggerEnabled) {
        return [pscustomobject]@{
            State = 'blocked'
            ReasonCode = 'publish-ready-trigger-disabled'
            BlocksQueue = $true
            Summary = '주의: 이 target은 TriggerKinds에 publish-ready가 없어 산출물 생성 후 다음 action으로 이어지지 않습니다. target 설정에서 publish-ready를 켜고 새 RunRoot를 준비하세요.'
        }
    }

    $routerStateValue = [string]$RouterSessionState
    $routerNotReady = $RouterSessionMismatch -or (
        (Test-NonEmptyString $routerStateValue) -and
        $routerStateValue -ne 'ok'
    )
    if ($routerNotReady) {
        return [pscustomobject]@{
            State = 'warning'
            ReasonCode = 'router-session-not-ready'
            BlocksQueue = $false
            Summary = ('주의: router/runtime 세션이 ready 파일 소비 조건을 만족하지 않습니다. state={0}, routerPid={1}, pidExists={2}, mutexHeld={3}. 공식 8창 attach 후 router를 현재 세션으로 다시 시작해야 다음 action이 실제 셀창으로 전달됩니다.' -f $(if (Test-NonEmptyString $routerStateValue) { $routerStateValue } else { '-' }), $RouterPid, $RouterPidExists, $RouterMutexHeld)
        }
    }

    return [pscustomobject]@{
        State = 'ready'
        ReasonCode = 'none'
        BlocksQueue = $false
        Summary = ''
    }
}

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

function Get-TargetAutoloopSeedComposerContractSnapshot {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$TargetId
    )

    $summaryState = Get-TargetAutoloopSeedComposerPathState -Path ([string]$Paths.SourceSummaryPath)
    $reviewState = Get-TargetAutoloopSeedComposerPathState -Path ([string]$Paths.SourceReviewZipPath)
    $publishState = Get-TargetAutoloopSeedComposerPathState -Path ([string]$Paths.PublishReadyPath)
    $core = Get-TargetAutoloopContractSnapshotCore -Paths $Paths -TargetId $TargetId -SummaryState $summaryState -ReviewZipState $reviewState -PublishReadyState $publishState

    return [pscustomobject]@{
        State = [string]$core.State
        Reason = [string]$core.Reason
        RouteBadge = [string]$core.RouteBadge
        PublishReadyValid = [bool]$core.PublishReadyValid
        SummaryExists = [bool]$core.SummaryExists
        ReviewZipExists = [bool]$core.ReviewZipExists
        PublishReadyExists = [bool]$core.PublishReadyExists
        OutputFingerprint = [string]$core.OutputFingerprint
        PublishedAt = [string]$core.PublishedAt
    }
}

function New-TargetAutoloopSeedComposerPathSnapshot {
    param([Parameter(Mandatory)]$Paths)

    return [pscustomobject]@{
        WorkRepoRoot = [string](Get-ConfigValue -Object $Paths -Name 'WorkRepoRoot' -DefaultValue '')
        TargetRunRoot = [string](Get-ConfigValue -Object $Paths -Name 'TargetRunRoot' -DefaultValue '')
        SourceOutboxPath = [string](Get-ConfigValue -Object $Paths -Name 'SourceOutboxRoot' -DefaultValue '')
        SourceSummaryPath = [string](Get-ConfigValue -Object $Paths -Name 'SourceSummaryPath' -DefaultValue '')
        SourceReviewZipPath = [string](Get-ConfigValue -Object $Paths -Name 'SourceReviewZipPath' -DefaultValue '')
        PublishReadyPath = [string](Get-ConfigValue -Object $Paths -Name 'PublishReadyPath' -DefaultValue '')
    }
}

function Test-TargetAutoloopSeedComposerSamePath {
    param(
        [AllowEmptyString()][string]$Left,
        [AllowEmptyString()][string]$Right
    )

    return ((Get-NormalizedFullPath -Path $Left) -eq (Get-NormalizedFullPath -Path $Right))
}

function Get-TargetAutoloopSeedComposerContractPathProof {
    param(
        [Parameter(Mandatory)]$ComputedPaths,
        [Parameter(Mandatory)]$ResolvedPaths,
        [object]$ManifestTarget,
        [string]$ManifestPath = ''
    )

    $fields = @(
        @{ Name = 'WorkRepoRoot'; ManifestField = 'WorkRepoRoot'; ComputedField = 'WorkRepoRoot'; ResolvedField = 'WorkRepoRoot' },
        @{ Name = 'TargetRunRoot'; ManifestField = 'TargetRunRoot'; ComputedField = 'TargetRunRoot'; ResolvedField = 'TargetRunRoot' },
        @{ Name = 'SourceOutboxPath'; ManifestField = 'SourceOutboxPath'; ComputedField = 'SourceOutboxPath'; ResolvedField = 'SourceOutboxPath' },
        @{ Name = 'SourceSummaryPath'; ManifestField = 'SourceSummaryPath'; ComputedField = 'SourceSummaryPath'; ResolvedField = 'SourceSummaryPath' },
        @{ Name = 'SourceReviewZipPath'; ManifestField = 'SourceReviewZipPath'; ComputedField = 'SourceReviewZipPath'; ResolvedField = 'SourceReviewZipPath' },
        @{ Name = 'PublishReadyPath'; ManifestField = 'PublishReadyPath'; ComputedField = 'PublishReadyPath'; ResolvedField = 'PublishReadyPath' }
    )

    $computedMismatchFields = New-Object System.Collections.Generic.List[string]
    $resolvedMismatchFields = New-Object System.Collections.Generic.List[string]
    $fieldRows = New-Object System.Collections.Generic.List[object]
    $hasManifestTarget = ($null -ne $ManifestTarget)
    foreach ($field in @($fields)) {
        $manifestValue = if ($hasManifestTarget) { [string](Get-ConfigValue -Object $ManifestTarget -Name ([string]$field.ManifestField) -DefaultValue '') } else { '' }
        $computedValue = [string](Get-ConfigValue -Object $ComputedPaths -Name ([string]$field.ComputedField) -DefaultValue '')
        $resolvedValue = [string](Get-ConfigValue -Object $ResolvedPaths -Name ([string]$field.ResolvedField) -DefaultValue '')
        $computedMatches = if ($hasManifestTarget) { Test-TargetAutoloopSeedComposerSamePath -Left $computedValue -Right $manifestValue } else { $true }
        $resolvedMatches = if ($hasManifestTarget) { Test-TargetAutoloopSeedComposerSamePath -Left $resolvedValue -Right $manifestValue } else { $true }
        if (-not $computedMatches) {
            $computedMismatchFields.Add([string]$field.Name) | Out-Null
        }
        if (-not $resolvedMatches) {
            $resolvedMismatchFields.Add([string]$field.Name) | Out-Null
        }

        $fieldRows.Add([pscustomobject]@{
                Name = [string]$field.Name
                ManifestPath = $manifestValue
                ComputedPath = $computedValue
                ResolvedPath = $resolvedValue
                ComputedMatchesManifest = [bool]$computedMatches
                ResolvedMatchesManifest = [bool]$resolvedMatches
            }) | Out-Null
    }

    $strictPathSource = if ($hasManifestTarget) { 'manifest' } else { 'computed' }
    $computedMatchesManifest = (@($computedMismatchFields).Count -eq 0)
    $resolvedMatchesManifest = (@($resolvedMismatchFields).Count -eq 0)
    $summary = if (-not $hasManifestTarget) {
        'strict path source=computed / manifest target row 없음'
    }
    elseif (-not $resolvedMatchesManifest) {
        ('strict path source=manifest / resolved mismatch={0}' -f (@($resolvedMismatchFields) -join ','))
    }
    elseif (-not $computedMatchesManifest) {
        ('strict path source=manifest / config drift override active={0}' -f (@($computedMismatchFields) -join ','))
    }
    else {
        'strict path source=manifest / copied paths match manifest'
    }
    $resolvedMismatchArray = $resolvedMismatchFields.ToArray()
    $computedMismatchArray = $computedMismatchFields.ToArray()
    $fieldRowArray = $fieldRows.ToArray()
    $configDriftDetected = [bool]($hasManifestTarget -and (-not [bool]$computedMatchesManifest))

    return [pscustomobject]@{
        StrictPathSource = $strictPathSource
        ManifestPath = [string]$ManifestPath
        ManifestTargetPresent = [bool]$hasManifestTarget
        ComputedPathsMatchManifest = [bool]$computedMatchesManifest
        ResolvedPathsMatchManifest = [bool]$resolvedMatchesManifest
        ConfigDriftDetected = $configDriftDetected
        ResolvedMismatchFields = @($resolvedMismatchArray)
        ComputedMismatchFields = @($computedMismatchArray)
        Fields = @($fieldRowArray)
        Summary = $summary
    }
}

function Get-TargetAutoloopSeedComposerRepoNotice {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$AutomationRoot
    )

    $workRepoRoot = [string](Get-ConfigValue -Object $Paths -Name 'WorkRepoRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $workRepoRoot)) {
        return [pscustomobject]@{
            State = 'coordinator-runroot'
            Summary = '산출물 contract는 공통 RunRoot 기준입니다.'
        }
    }

    $resolvedWorkRepoRoot = [System.IO.Path]::GetFullPath($workRepoRoot)
    $resolvedAutomationRoot = [System.IO.Path]::GetFullPath($AutomationRoot)
    $insideAutomationRepo = Test-PathEqualsOrIsDescendant -Path $resolvedWorkRepoRoot -BasePath $resolvedAutomationRoot
    $state = if ($insideAutomationRepo) { 'automation-repo-contract' } else { 'external-workrepo-contract' }
    $summary = if ($insideAutomationRepo) {
        ('주의: WorkRepoRoot가 automation repo 아래입니다. shared visible strict 기준에 맞지 않습니다. workRepoRoot={0}' -f $resolvedWorkRepoRoot)
    }
    else {
        ('산출물은 automation repo가 아니라 WorkRepoRoot 아래 target runroot에 생성됩니다. workRepoRoot={0} targetRunRoot={1}' -f $resolvedWorkRepoRoot, [string]$Paths.TargetRunRoot)
    }

    return [pscustomobject]@{
        State = $state
        Summary = $summary
    }
}

function Resolve-TargetAutoloopSeedComposerRunContext {
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

function Get-TargetAutoloopSeedComposerPublishHelperCommand {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId
    )

    return (
        "pwsh -NoProfile -ExecutionPolicy Bypass -File {0} -ConfigPath {1} -RunRoot {2} -TargetId {3} -Overwrite" -f
        (Quote-PowerShellLiteral $ScriptPath),
        (Quote-PowerShellLiteral $ConfigPath),
        (Quote-PowerShellLiteral $RunRoot),
        (Quote-PowerShellLiteral $TargetId)
    )
}

function New-TargetAutoloopSeedComposerTexts {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RunRootMode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReferenceInputPath,
        [Parameter(Mandatory)][string]$InputSummary,
        [Parameter(Mandatory)][string]$InputBadge,
        [Parameter(Mandatory)][string]$InputCheckReason,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputWarning,
        [Parameter(Mandatory)][string]$InputRecommendationLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputRecommendationDetail,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OperationalNotice,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DeliverySummary,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DeliveryAction,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DeliveryActionLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RepoNotice,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ContractPathProofSummary,
        [Parameter(Mandatory)][string]$RuntimeSummary,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FixedSuffix,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$CycleCount,
        [Parameter(Mandatory)][int]$MaxCycleCount,
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkRepoRoot,
        [Parameter(Mandatory)][string]$TargetRunRoot,
        [Parameter(Mandatory)][string]$SourceSummaryPath,
        [Parameter(Mandatory)][string]$SourceReviewZipPath,
        [Parameter(Mandatory)][string]$PublishReadyPath,
        [Parameter(Mandatory)][string]$SourceOutboxPath,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$QueueRoot,
        [Parameter(Mandatory)][string]$PublishHelperCommand,
        [Parameter(Mandatory)][string]$CloseoutSummary
    )

    $manualLines = @()
    $queueLines = @()
    if (Test-NonEmptyString $FixedSuffix) {
        $manualLines += @('[고정문구 / 항상 포함]', $FixedSuffix.Trim(), '')
    }
    if (Test-NonEmptyString $TaskText) {
        $manualLines += @('[작업 내용]', $TaskText.Trim(), '')
        $queueLines += @('[작업 내용]', $TaskText.Trim(), '')
    }
    if (Test-NonEmptyString $ReferenceInputPath) {
        $manualLines += @('[먼저 확인할 입력 파일]', $ReferenceInputPath, '')
        $queueLines += @('[먼저 확인할 입력 파일]', $ReferenceInputPath, '')
    }
    $manualLines += @(
        '[생성해야 할 파일]',
        ('1. summary.txt -> ' + $SourceSummaryPath),
        ('2. review.zip -> ' + $SourceReviewZipPath),
        '',
        '[마지막 단계]',
        ('3. publish helper 실행 -> ' + $PublishHelperCommand),
        ('4. helper output marker -> ' + $PublishReadyPath),
        '',
        '[규칙]',
        '- summary.txt 와 review.zip 을 먼저 준비하세요.',
        '- publish.ready.json 은 직접 만들지 말고 마지막에 helper 로만 생성하세요.',
        '- 위 target 계약 경로 외 다른 위치에 최종 산출물을 두지 마세요.',
        '- 순서는 summary.txt -> review.zip -> publish helper 입니다.'
    )
    $manualStartText = ($manualLines -join "`n").Trim()
    $queuePromptText = ($queueLines -join "`n").Trim()
    $contractText = @(
        '[자동 계약 / 경로]',
        ('- target: ' + $TargetId),
        ('- runroot: ' + $RunRoot),
        ('- runroot mode: ' + $RunRootMode),
        ('- route badge: ' + [string]$Contract.RouteBadge),
        ('- contract state: ' + [string]$Contract.State),
        ('- contract reason: ' + [string]$Contract.Reason),
        ('- strict path proof: ' + $ContractPathProofSummary),
        ('- delivery: ' + $DeliverySummary),
        ('- delivery next: ' + $(if (Test-NonEmptyString $DeliveryActionLabel) { $DeliveryActionLabel + ' - ' + $DeliveryAction } else { $DeliveryAction })),
        ('- cycle: ' + $CycleCount + '/' + $MaxCycleCount),
        ('- phase: ' + $Phase),
        ('- work repo: ' + $(if (Test-NonEmptyString $WorkRepoRoot) { $WorkRepoRoot } else { '(공통 RunRoot 사용)' })),
        ('- target runroot: ' + $TargetRunRoot),
        ('- target root: ' + $TargetRoot),
        ('- source outbox: ' + $SourceOutboxPath),
        ('- queue root: ' + $QueueRoot),
        ('- closeout: ' + $CloseoutSummary),
        '',
        ('summary.txt: ' + $SourceSummaryPath),
        ('review.zip: ' + $SourceReviewZipPath),
        ('publish.ready.json: ' + $PublishReadyPath)
    ) -join "`n"

    $helperText = @(
        '[publish helper]',
        ('- 실행: ' + $PublishHelperCommand),
        ('- helper output marker: ' + $PublishReadyPath),
        '- summary.txt 와 review.zip 작성이 끝난 뒤 마지막에만 helper 를 실행하세요.',
        '- helper 가 strict marker 와 validation 정보를 자동으로 기록합니다.'
    ) -join "`n"

    $startStepsText = @(
        '[권장 시작 순서]',
        ('1. target=' + $TargetId + ' / route=' + [string]$Contract.RouteBadge + ' / runroot mode=' + $RunRootMode + ' 상태를 확인합니다.'),
        '2. 아래 초간단 시작문을 실제 target 셀 창에 그대로 붙여넣습니다.',
        '3. 대상은 같은 contract 경로에 summary.txt 와 review.zip 을 생성합니다.',
        ('4. 마지막에 publish helper 만 실행합니다: ' + $PublishHelperCommand),
        ('5. helper output marker: ' + $PublishReadyPath),
        '6. marker 가 생기면 watcher 가 다음 cycle/handoff 를 이어갑니다.'
    ) -join "`n"

    $detailedStartText = @(
        $manualStartText,
        '',
        $contractText,
        '',
        $helperText
    ) -join "`n"

    $fullPreviewText = @(
        '[8 Cell Autoloop Seed Composer]',
        ('target=' + $TargetId + ' / route=' + [string]$Contract.RouteBadge + ' / contract=' + [string]$Contract.State + ' / cycle=' + $CycleCount + '/' + $MaxCycleCount + ' / phase=' + $Phase + ' / input=' + $InputBadge + ' / inputReason=' + $InputCheckReason),
        $InputSummary,
        $RuntimeSummary,
        $(if (Test-NonEmptyString $DeliverySummary) { '[진행 단계] ' + $DeliverySummary } else { '' }),
        $(if (Test-NonEmptyString $DeliveryAction) { '[다음 확인] ' + $(if (Test-NonEmptyString $DeliveryActionLabel) { $DeliveryActionLabel + ' - ' + $DeliveryAction } else { $DeliveryAction }) } else { '' }),
        $(if (Test-NonEmptyString $RepoNotice) { '[Repo 확인] ' + $RepoNotice } else { '' }),
        $(if (Test-NonEmptyString $OperationalNotice) { '[시작 가능 여부] ' + $OperationalNotice } else { '' }),
        $(if (Test-NonEmptyString $InputWarning) { '[입력 파일 확인 필요] ' + $InputWarning } else { '' }),
        $(if (Test-NonEmptyString $InputRecommendationLabel) { '[권장 입력 조치] ' + $InputRecommendationLabel + $(if (Test-NonEmptyString $InputRecommendationDetail) { ' - ' + $InputRecommendationDetail } else { '' }) } else { '' }),
        '',
        $manualStartText,
        '',
        $contractText,
        '',
        $helperText,
        '',
        $startStepsText
    ) -join "`n"

    return [pscustomobject]@{
        InputSummary = $InputSummary
        InputBadge = $InputBadge
        InputCheckReason = $InputCheckReason
        InputWarning = $InputWarning
        InputRecommendationLabel = $InputRecommendationLabel
        InputRecommendationDetail = $InputRecommendationDetail
        QueuePromptText = $queuePromptText
        ManualStartText = $manualStartText
        DetailedStartText = $detailedStartText
        ContractText = $contractText
        HelperText = $helperText
        StartStepsText = $startStepsText
        FullPreviewText = $fullPreviewText
    }
}

$resolvedConfigPath = if (Test-NonEmptyString $ConfigPath) { (Resolve-Path -LiteralPath $ConfigPath).Path } else { Join-Path $root 'config\settings.bottest-live-visible.psd1' }
$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $resolvedConfigPath
$runContext = Resolve-TargetAutoloopSeedComposerRunContext -Config $config -RequestedRunRoot $RunRoot
$resolvedRunRoot = [string]$runContext.RunRoot
$availableTargetIds = @($config.Targets | ForEach-Object { [string]$_.TargetId } | Where-Object { Test-NonEmptyString $_ })
$enabledTargetIds = @($config.Targets | Where-Object { [bool]$_.Enabled } | ForEach-Object { [string]$_.TargetId })
$requestedTargetId = [string]$TargetId
$selectedTargetId = if ((Test-NonEmptyString $requestedTargetId) -and ($requestedTargetId -in $availableTargetIds)) {
    $requestedTargetId
}
elseif (@($enabledTargetIds).Count -gt 0) {
    [string]$enabledTargetIds[0]
}
elseif (@($availableTargetIds).Count -gt 0) {
    [string]$availableTargetIds[0]
}
else {
    ''
}
if (-not (Test-NonEmptyString $selectedTargetId)) {
    throw 'target-autoloop seed composer could not resolve a target id.'
}

$selectedTargetRows = @($config.Targets | Where-Object { [string]$_.TargetId -eq $selectedTargetId } | Select-Object -First 1)
if (@($selectedTargetRows).Count -lt 1) {
    throw ("target-autoloop seed composer could not resolve selected target config: {0}" -f $selectedTargetId)
}
$selectedTarget = $selectedTargetRows[0]
$paths = Get-TargetAutoloopTargetPaths -RunRoot $resolvedRunRoot -TargetId $selectedTargetId -Target $selectedTarget -Config $config
$computedPathSnapshot = New-TargetAutoloopSeedComposerPathSnapshot -Paths $paths
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
$manifestDocument = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Read-JsonObject -Path $manifestPath } else { [pscustomobject]@{} }
$manifestTargetRows = @(Get-ConfigValue -Object $manifestDocument -Name 'Targets' -DefaultValue @() | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') -eq $selectedTargetId } | Select-Object -First 1)
$manifestTarget = if (@($manifestTargetRows).Count -gt 0) { $manifestTargetRows[0] } else { $null }
if ($null -ne $manifestTarget) {
    $paths = Use-TargetAutoloopManifestTargetPaths -Paths $paths -ManifestTarget $manifestTarget
}
$resolvedPathSnapshot = New-TargetAutoloopSeedComposerPathSnapshot -Paths $paths
$contractPathProof = Get-TargetAutoloopSeedComposerContractPathProof `
    -ComputedPaths $computedPathSnapshot `
    -ResolvedPaths $resolvedPathSnapshot `
    -ManifestTarget $manifestTarget `
    -ManifestPath $manifestPath

$queuePathTarget = if ($null -ne $manifestTarget) { $manifestTarget } else { $selectedTarget }
$queuePaths = Get-TargetAutoloopQueuePaths -RunRoot $resolvedRunRoot -TargetId $selectedTargetId -Target $queuePathTarget -Config $config
if ($null -ne $manifestTarget) {
    $queuePaths = Use-TargetAutoloopManifestQueuePaths -Paths $queuePaths -ManifestTarget $manifestTarget
}
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
$stateDocument = if (Test-Path -LiteralPath $statePaths.StatePath -PathType Leaf) { Read-JsonObject -Path $statePaths.StatePath } else { [pscustomobject]@{} }
$statusDocument = if (Test-Path -LiteralPath $statePaths.StatusPath -PathType Leaf) { Read-JsonObject -Path $statePaths.StatusPath } else { [pscustomobject]@{} }
$stateTargetMap = Get-TargetAutoloopTargetStateMap -StateDocument $stateDocument
$statusRows = @(Get-ConfigValue -Object $statusDocument -Name 'Targets' -DefaultValue @())
$statusRowRows = @($statusRows | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') -eq $selectedTargetId } | Select-Object -First 1)
$statusRow = if (@($statusRowRows).Count -gt 0) { $statusRowRows[0] } else { $null }
$stateRecord = if ($stateTargetMap.Contains($selectedTargetId)) { $stateTargetMap[$selectedTargetId] } else { $null }
$contract = Get-TargetAutoloopSeedComposerContractSnapshot -Paths $paths -TargetId $selectedTargetId
$repoNotice = Get-TargetAutoloopSeedComposerRepoNotice -Paths $paths -AutomationRoot $root
$proofReceipt = Get-TargetAutoloopProofReceiptSummary `
    -SmokeReceiptPath $statePaths.SmokeReceiptPath `
    -AcceptanceReceiptPath $statePaths.AcceptanceReceiptPath `
    -TargetRows @($statusRows)
$proofCloseout = Get-TargetAutoloopProofCloseoutSummary -ProofReceipt $proofReceipt

$cycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'CycleCount' -DefaultValue ([int](Get-ConfigValue -Object $statusRow -Name 'CycleCount' -DefaultValue 0)))
$maxCycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'MaxCycleCount' -DefaultValue ([int](Get-ConfigValue -Object $statusRow -Name 'MaxCycleCount' -DefaultValue ([int]$selectedTarget.MaxCycleCount))))
$phase = [string](Get-ConfigValue -Object $stateRecord -Name 'Phase' -DefaultValue ([string](Get-ConfigValue -Object $statusRow -Name 'Phase' -DefaultValue $(if ([bool]$selectedTarget.Enabled) { 'idle' } else { 'disabled' }))))
$fixedSuffix = [string](Get-ConfigValue -Object $selectedTarget -Name 'FixedSuffix' -DefaultValue '')
$selectedTriggerKinds = @(Get-StringArray (Get-ConfigValue -Object $selectedTarget -Name 'TriggerKinds' -DefaultValue @()))
$publishReadyTriggerEnabled = (@($selectedTriggerKinds) -contains 'publish-ready')
$inputPathState = Get-TargetAutoloopSeedComposerInputPathState -ReferenceInputPath ([string]$ReferenceInputPath) -AutomationRoot $root
$inputRecommendation = Get-TargetAutoloopSeedComposerInputRecommendation -InputPathState $inputPathState
$routerSessionState = Get-TargetAutoloopRouterSessionState -Config $config
$routerSessionMismatch = [bool](Get-ConfigValue -Object $routerSessionState -Name 'Mismatch' -DefaultValue $false)
$deliverySnapshot = Get-TargetAutoloopDeliverySnapshot `
    -Contract $contract `
    -StateRecord $stateRecord `
    -StatusRow $statusRow `
    -RouterSessionState $routerSessionState `
    -UseRouterSessionFallback
$operationalNotice = Get-TargetAutoloopSeedComposerOperationalNotice `
    -Phase $phase `
    -CycleCount $cycleCount `
    -MaxCycleCount $maxCycleCount `
    -PublishReadyTriggerEnabled ([bool]$publishReadyTriggerEnabled) `
    -RouterSessionState ([string](Get-ConfigValue -Object $routerSessionState -Name 'State' -DefaultValue '')) `
    -RouterSessionMismatch:$routerSessionMismatch `
    -RouterPid ([int](Get-ConfigValue -Object $routerSessionState -Name 'RouterPid' -DefaultValue 0)) `
    -RouterPidExists ([bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterPidExists' -DefaultValue $false)) `
    -RouterMutexHeld ([bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterMutexHeld' -DefaultValue $false))
$queueState = Get-TargetAutoloopSeedComposerQueueState `
    -Enabled ([bool](Get-ConfigValue -Object $selectedTarget -Name 'Enabled' -DefaultValue $false)) `
    -TaskText ([string]$TaskText) `
    -InputPathState $inputPathState `
    -RunRootExists ([bool]$runContext.RunRootExists) `
    -RunRootMode ([string]$runContext.RunRootMode) `
    -OperationalNotice $operationalNotice
$runtimeState = Get-TargetAutoloopSeedComposerRuntimeState -Paths $paths -QueuePaths $queuePaths
$publishHelperScriptPath = Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1'
$publishHelperCommand = Get-TargetAutoloopSeedComposerPublishHelperCommand `
    -ScriptPath $publishHelperScriptPath `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $resolvedRunRoot `
    -TargetId $selectedTargetId
$texts = New-TargetAutoloopSeedComposerTexts `
    -TargetId $selectedTargetId `
    -RunRoot $resolvedRunRoot `
    -RunRootMode ([string]$runContext.RunRootMode) `
    -TaskText ([string]$TaskText) `
    -ReferenceInputPath ([string]$inputPathState.ResolvedPath) `
    -InputSummary ([string]$inputPathState.Summary) `
    -InputBadge ([string]$inputPathState.Badge) `
    -InputCheckReason ([string]$inputPathState.CheckReason) `
    -InputWarning ([string]$inputPathState.Warning) `
    -InputRecommendationLabel ([string]$inputRecommendation.Label) `
    -InputRecommendationDetail ([string]$inputRecommendation.Detail) `
    -OperationalNotice ([string](Get-ConfigValue -Object $operationalNotice -Name 'Summary' -DefaultValue '')) `
    -DeliverySummary ([string](Get-ConfigValue -Object $deliverySnapshot -Name 'Summary' -DefaultValue '')) `
    -DeliveryAction ([string](Get-ConfigValue -Object $deliverySnapshot -Name 'NextAction' -DefaultValue '')) `
    -DeliveryActionLabel ([string](Get-ConfigValue -Object $deliverySnapshot -Name 'NextActionLabel' -DefaultValue '')) `
    -RepoNotice ([string](Get-ConfigValue -Object $repoNotice -Name 'Summary' -DefaultValue '')) `
    -ContractPathProofSummary ([string](Get-ConfigValue -Object $contractPathProof -Name 'Summary' -DefaultValue '')) `
    -RuntimeSummary ([string]$runtimeState.Summary) `
    -FixedSuffix $fixedSuffix `
    -Phase $phase `
    -CycleCount $cycleCount `
    -MaxCycleCount $maxCycleCount `
    -Contract $contract `
    -WorkRepoRoot ([string]$paths.WorkRepoRoot) `
    -TargetRunRoot ([string]$paths.TargetRunRoot) `
    -SourceSummaryPath ([string]$paths.SourceSummaryPath) `
    -SourceReviewZipPath ([string]$paths.SourceReviewZipPath) `
    -PublishReadyPath ([string]$paths.PublishReadyPath) `
    -SourceOutboxPath ([string]$paths.SourceOutboxRoot) `
    -TargetRoot ([string]$paths.TargetRoot) `
    -QueueRoot ([string]$queuePaths.QueueRoot) `
    -PublishHelperCommand $publishHelperCommand `
    -CloseoutSummary ([string](Get-ConfigValue -Object $proofCloseout -Name 'Summary' -DefaultValue ''))

$readiness = if ([string](Get-ConfigValue -Object $operationalNotice -Name 'State' -DefaultValue '') -in @('blocked', 'warning')) {
    [string](Get-ConfigValue -Object $operationalNotice -Name 'Summary' -DefaultValue '')
}
elseif ([string](Get-ConfigValue -Object $deliverySnapshot -Name 'Watcher' -DefaultValue '') -eq 'not-yet-accepted-current-marker') {
    'publish.ready.json은 생성됐지만 watcher가 현재 marker를 아직 accepted 처리하지 않았습니다. 감지기 sweep/RunRoot/target 상태를 먼저 확인하세요. ' + [string](Get-ConfigValue -Object $deliverySnapshot -Name 'Summary' -DefaultValue '')
}
elseif (
    [string](Get-ConfigValue -Object $deliverySnapshot -Name 'Watcher' -DefaultValue '') -eq 'accepted-current-marker' -and
    [string](Get-ConfigValue -Object $deliverySnapshot -Name 'Router' -DefaultValue '') -ne 'ready-file-created'
) {
    'watcher는 현재 marker를 accepted 처리했지만 router 전달이 완료되지 않았습니다. router/runtime 세션과 ready 파일 소비 상태를 확인하세요. ' + [string](Get-ConfigValue -Object $deliverySnapshot -Name 'Summary' -DefaultValue '')
}
elseif (-not (Test-NonEmptyString ([string]$TaskText))) {
    '작업 설명이 비어 있습니다. 경로만 자동 주입한 시작문을 복사할 수 있지만 작업 설명을 채우는 편이 안전합니다.'
}
elseif ([string]$contract.RouteBadge -eq 'ROUTE READY') {
    '현재 contract 파일은 ready입니다. 단, 실제 진행 여부는 artifact/watcher/router 3단계 상태를 같이 확인하세요. ' + [string](Get-ConfigValue -Object $deliverySnapshot -Name 'Summary' -DefaultValue '')
}
elseif (-not $publishReadyTriggerEnabled) {
    '주의: 이 target은 TriggerKinds에 publish-ready가 없어 산출물 생성 후 다음 동작으로 이어지지 않습니다. 8 Cell Autoloop target 설정에서 publish-ready를 켜고 저장하세요.'
}
elseif ([string]$runContext.RunRootMode -eq 'preview') {
    '현재는 preview runroot 기준입니다. 실제 RunRoot를 준비한 뒤 다시 확인하면 더 안전합니다.'
}
else {
    ('준비: target={0} / route={1} / runroot mode={2} / cycle={3}/{4}' -f
        $selectedTargetId,
        [string]$contract.RouteBadge,
        [string]$runContext.RunRootMode,
        $cycleCount,
        $maxCycleCount)
}

$payload = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    ConfigPath = $resolvedConfigPath
    RunRoot = $resolvedRunRoot
    RunRootMode = [string]$runContext.RunRootMode
    RunRootExists = [bool]$runContext.RunRootExists
    WorkRepoRoot = [string]$paths.WorkRepoRoot
    TargetRunRoot = [string]$paths.TargetRunRoot
    AvailableTargetIds = @($availableTargetIds)
    TargetId = $selectedTargetId
    Enabled = [bool](Get-ConfigValue -Object $selectedTarget -Name 'Enabled' -DefaultValue $false)
    TriggerKinds = @($selectedTriggerKinds)
    PublishReadyTriggerEnabled = [bool]$publishReadyTriggerEnabled
    FixedSuffix = $fixedSuffix
    Phase = $phase
    CycleCount = $cycleCount
    MaxCycleCount = $maxCycleCount
    RouteBadge = [string]$contract.RouteBadge
    Contract = $contract
    ContractPathProof = $contractPathProof
    ContractPathProofSummary = [string](Get-ConfigValue -Object $contractPathProof -Name 'Summary' -DefaultValue '')
    ProofReceipt = $proofReceipt
    ProofCloseout = $proofCloseout
    Delivery = $deliverySnapshot
    DeliverySummary = [string](Get-ConfigValue -Object $deliverySnapshot -Name 'Summary' -DefaultValue '')
    DeliveryNextAction = [string](Get-ConfigValue -Object $deliverySnapshot -Name 'NextAction' -DefaultValue '')
    DeliveryNextActionCode = [string](Get-ConfigValue -Object $deliverySnapshot -Name 'NextActionCode' -DefaultValue '')
    DeliveryNextActionLabel = [string](Get-ConfigValue -Object $deliverySnapshot -Name 'NextActionLabel' -DefaultValue '')
    RepoNotice = $repoNotice
    RepoNoticeSummary = [string](Get-ConfigValue -Object $repoNotice -Name 'Summary' -DefaultValue '')
    TargetBanner = ('붙여넣기 대상: 8 Cell Autoloop / ' + $selectedTargetId)
    Readiness = $readiness
    OperationalState = [string](Get-ConfigValue -Object $operationalNotice -Name 'State' -DefaultValue 'ready')
    OperationalReason = [string](Get-ConfigValue -Object $operationalNotice -Name 'ReasonCode' -DefaultValue 'none')
    OperationalBlocksQueue = [bool](Get-ConfigValue -Object $operationalNotice -Name 'BlocksQueue' -DefaultValue $false)
    OperationalNotice = [string](Get-ConfigValue -Object $operationalNotice -Name 'Summary' -DefaultValue '')
    RouterSessionState = [string](Get-ConfigValue -Object $routerSessionState -Name 'State' -DefaultValue '')
    RouterSessionMismatch = [bool]$routerSessionMismatch
    RouterPid = [int](Get-ConfigValue -Object $routerSessionState -Name 'RouterPid' -DefaultValue 0)
    RouterPidExists = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterPidExists' -DefaultValue $false)
    RouterMutexHeld = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterMutexHeld' -DefaultValue $false)
    TaskText = [string]$TaskText
    InputPath = [string]$inputPathState.ResolvedPath
    InputPathState = $inputPathState
    InputBadge = [string]$inputPathState.Badge
    InputCheckReason = [string]$inputPathState.CheckReason
    InputWarning = [string]$inputPathState.Warning
    InputRecommendation = $inputRecommendation
    InputSummary = [string]$texts.InputSummary
    SeedRuntime = $runtimeState
    SeedRuntimeSummary = [string]$runtimeState.Summary
    QueueAllowed = [bool]$queueState.Allowed
    QueueBlockedReason = [string]$queueState.BlockedReason
    QueueSummary = [string]$queueState.Summary
    QueuePromptText = [string]$texts.QueuePromptText
    ResolvedOutputPaths = [ordered]@{
        PathSource = [string](Get-ConfigValue -Object $contractPathProof -Name 'StrictPathSource' -DefaultValue 'computed')
        ManifestPath = [string]$manifestPath
        WorkRepoRoot = [string]$paths.WorkRepoRoot
        TargetRunRoot = [string]$paths.TargetRunRoot
        TargetRoot = [string]$paths.TargetRoot
        SourceOutboxPath = [string]$paths.SourceOutboxRoot
        SourceSummaryPath = [string]$paths.SourceSummaryPath
        SourceReviewZipPath = [string]$paths.SourceReviewZipPath
        PublishReadyPath = [string]$paths.PublishReadyPath
        QueueRoot = [string]$queuePaths.QueueRoot
    }
    PublishHelperCommand = $publishHelperCommand
    PublishHelperScriptPath = $publishHelperScriptPath
    ContractText = [string]$texts.ContractText
    HelperText = [string]$texts.HelperText
    StartStepsText = [string]$texts.StartStepsText
    FullPreviewText = [string]$texts.FullPreviewText
    ManualStartText = [string]$texts.ManualStartText
    DetailedStartText = [string]$texts.DetailedStartText
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 10
    return
}

[string]$payload.FullPreviewText
