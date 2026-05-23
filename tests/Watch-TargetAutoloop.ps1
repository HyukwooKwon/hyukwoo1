[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [string[]]$Targets = @(),
    [int]$RunDurationSec = 60,
    [switch]$DispatchQueuedCommandsInline,
    [switch]$ProcessOnce,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')
. (Join-Path $PSScriptRoot 'lib\RelayTargetFolderPreflight.ps1')

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Move-FileToDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    Ensure-Directory -Path $DestinationDirectory
    $fileName = [System.IO.Path]::GetFileName($Path)
    $destination = Join-Path $DestinationDirectory $fileName
    if (Test-Path -LiteralPath $destination) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $extension = [System.IO.Path]::GetExtension($fileName)
        $destination = Join-Path $DestinationDirectory ('{0}_{1}{2}' -f $stem, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $extension)
    }

    Move-Item -LiteralPath $Path -Destination $destination -Force
    return $destination
}

function Get-TargetAutoloopWatcherMutexName {
    param([Parameter(Mandatory)][string]$RunRoot)

    $normalizedRunRoot = Get-NormalizedFullPath -Path $RunRoot
    $hashHex = (Get-TextHashHex -Text $normalizedRunRoot)
    $token = if ($hashHex.Length -ge 24) { $hashHex.Substring(0, 24) } else { $hashHex }
    return ('Global\RelayTargetAutoloop_{0}' -f $token)
}

function Acquire-TargetAutoloopWatcherMutex {
    param([Parameter(Mandatory)][string]$Name)

    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$createdNew)
    try {
        $acquired = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }

    if (-not $acquired) {
        try {
            $mutex.Dispose()
        }
        catch {
        }
        throw "target autoloop watcher is already running for mutex=$Name"
    }

    return $mutex
}

function Get-FirstPendingInputFile {
    param([Parameter(Mandatory)]$Paths)

    $candidate = Get-ChildItem -LiteralPath $Paths.InboxPendingRoot -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, Name |
        Select-Object -First 1
    if ($null -eq $candidate) {
        return $null
    }

    return $candidate.FullName
}

function Read-InputTriggerPayload {
    param([Parameter(Mandatory)][string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq '.json') {
        $payload = Read-JsonObject -Path $Path
        $body = [string](Get-ConfigValue -Object $payload -Name 'Body' -DefaultValue '')
        if (-not (Test-NonEmptyString $body)) {
            $body = [string](Get-ConfigValue -Object $payload -Name 'PromptBody' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $body)) {
            $body = [string](Get-ConfigValue -Object $payload -Name 'TaskText' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $body)) {
            throw "input trigger json is missing Body/PromptBody/TaskText: $Path"
        }

        return [pscustomobject]@{
            Body = $body
            FixedSuffix = [string](Get-ConfigValue -Object $payload -Name 'FixedSuffix' -DefaultValue '')
            SourceLabel = [string](Get-ConfigValue -Object $payload -Name 'SourceLabel' -DefaultValue '')
        }
    }

    $bodyText = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not (Test-NonEmptyString $bodyText)) {
        throw "input trigger file is empty: $Path"
    }

    return [pscustomobject]@{
        Body = $bodyText
        FixedSuffix = ''
        SourceLabel = ''
    }
}

function Compose-InputPromptText {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$RunMode,
        [Parameter(Mandatory)]$Payload,
        $Paths = $null,
        [string]$EffectiveFixedSuffix = ''
    )

    $blocks = New-Object System.Collections.Generic.List[string]
    $blocks.Add(('Target trigger mode: ' + $RunMode)) | Out-Null
    $blocks.Add(('TargetId: ' + $TargetId)) | Out-Null
    if (Test-NonEmptyString ([string]$Payload.SourceLabel)) {
        $blocks.Add(('SourceLabel: ' + [string]$Payload.SourceLabel)) | Out-Null
    }
    if ($null -ne $Paths) {
        if (Test-NonEmptyString ([string](Get-ConfigValue -Object $Paths -Name 'WorkRepoRoot' -DefaultValue ''))) {
            $blocks.Add(('WorkRepoRoot: ' + [string]$Paths.WorkRepoRoot)) | Out-Null
            $blocks.Add(('TargetRunRoot: ' + [string]$Paths.TargetRunRoot)) | Out-Null
        }
        $blocks.Add(('summary.txt: ' + [string]$Paths.SourceSummaryPath)) | Out-Null
        $blocks.Add(('review.zip: ' + [string]$Paths.SourceReviewZipPath)) | Out-Null
        $blocks.Add(('publish.ready.json: ' + [string]$Paths.PublishReadyPath)) | Out-Null
    }
    $blocks.Add([string]$Payload.Body.Trim()) | Out-Null
    if (Test-NonEmptyString $EffectiveFixedSuffix) {
        $blocks.Add($EffectiveFixedSuffix.Trim()) | Out-Null
    }

    return ((@($blocks) | Where-Object { Test-NonEmptyString $_ }) -join "`r`n`r`n")
}

function Compose-PublishReadyPromptText {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$RunMode,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)]$Marker,
        [string]$EffectiveFixedSuffix = ''
    )

    $blocks = @(
        ('Target trigger mode: ' + $RunMode),
        ('TargetId: ' + $TargetId),
        '같은 target에서 직전 산출물을 이어받아 다음 턴을 준비하세요.',
        ('WorkRepoRoot: ' + $(if (Test-NonEmptyString ([string](Get-ConfigValue -Object $Paths -Name 'WorkRepoRoot' -DefaultValue ''))) { [string]$Paths.WorkRepoRoot } else { '(공통 RunRoot 사용)' })),
        ('TargetRunRoot: ' + [string]$Paths.TargetRunRoot),
        ('summary.txt: ' + [string]$Paths.SourceSummaryPath),
        ('review.zip: ' + [string]$Paths.SourceReviewZipPath),
        ('publish.ready.json: ' + [string]$Paths.PublishReadyPath),
        ('CycleId: ' + [string](Get-ConfigValue -Object $Marker -Name 'CycleId' -DefaultValue '')),
        ('ParentCycleId: ' + [string](Get-ConfigValue -Object $Marker -Name 'ParentCycleId' -DefaultValue '')),
        ('OutputFingerprint: ' + [string](Get-ConfigValue -Object $Marker -Name 'OutputFingerprint' -DefaultValue '')),
        ('PublishedBy: ' + [string](Get-ConfigValue -Object $Marker -Name 'PublishedBy' -DefaultValue '')),
        ('PublishedAt: ' + [string](Get-ConfigValue -Object $Marker -Name 'PublishedAt' -DefaultValue ''))
    )
    if (Test-NonEmptyString $EffectiveFixedSuffix) {
        $blocks += $EffectiveFixedSuffix.Trim()
    }

    return ((@($blocks) | Where-Object { Test-NonEmptyString $_ }) -join "`r`n`r`n")
}

function Write-TargetPromptAndRequest {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)]$Request
    )

    $encoding = New-Utf8NoBomEncoding
    [System.IO.File]::WriteAllText([string]$Paths.LastPromptPath, $PromptText, $encoding)
    Write-JsonFileAtomically -Path ([string]$Paths.CurrentRequestPath) -Payload $Request
}

function Write-TargetReceipt {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][int]$CycleId,
        [Parameter(Mandatory)]$Receipt
    )

    $receiptPath = Join-Path $Paths.ReceiptsRoot ('cycle-{0:d6}.receipt.json' -f $CycleId)
    Write-JsonFileAtomically -Path $receiptPath -Payload $Receipt
    return $receiptPath
}

function Write-TargetFailureReceipt {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][int]$CycleId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$TriggerKind,
        [string]$TriggerFingerprint = '',
        [string]$FailureState = '',
        [string]$RelayTargetFolderState = '',
        [string]$FailureReason = '',
        [hashtable]$ExtraFields = @{}
    )

    $receipt = [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        EventKind = ('{0}-failed' -f $TriggerKind)
        TargetId = $TargetId
        CycleId = $CycleId
        TriggerKind = $TriggerKind
        TriggerFingerprint = [string]$TriggerFingerprint
        FailureState = [string]$FailureState
        RelayTargetFolderState = [string]$RelayTargetFolderState
        FailureReason = [string]$FailureReason
        CreatedAt = (Get-Date).ToString('o')
    }
    foreach ($key in @($ExtraFields.Keys)) {
        if (-not $receipt.Contains($key)) {
            $receipt[$key] = $ExtraFields[$key]
        }
    }

    return (Write-TargetReceipt -Paths $Paths -CycleId $CycleId -Receipt $receipt)
}

function Try-ParseTargetAutoloopDateTimeOffset {
    param([string]$Value)

    $null = $parsed = [datetimeoffset]::MinValue
    if (Test-NonEmptyString $Value -and [datetimeoffset]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Clear-TargetAutoloopPendingPublishDispatch {
    param([Parameter(Mandatory)]$Entry)

    $Entry.PendingTriggerKind = ''
    $Entry.PendingTriggerFingerprint = ''
    $Entry.PendingDispatchEligibleAt = ''
    $Entry.PendingDispatchDelaySeconds = 0
    $Entry.PendingPublishedAt = ''
    $Entry.PendingOutputFingerprint = ''
    $Entry.PendingPublishCycleId = 0
    $Entry.PendingPublishParentCycleId = 0
}

function Restore-TargetAutoloopPausedEntryState {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string[]]$TriggerKinds
    )

    $restoredPhase = [string](Get-ConfigValue -Object $Entry -Name 'PausedPhase' -DefaultValue '')
    $restoredNextAction = [string](Get-ConfigValue -Object $Entry -Name 'PausedNextAction' -DefaultValue '')
    if (-not (Test-NonEmptyString $restoredPhase)) {
        $restoredPhase = 'idle'
    }
    if (-not (Test-NonEmptyString $restoredNextAction)) {
        $restoredNextAction = if ($TriggerKinds -contains 'publish-ready') { 'wait-for-output' } else { 'wait-for-input' }
    }

    $Entry.Phase = $restoredPhase
    $Entry.NextAction = $restoredNextAction
    $Entry.PausedPhase = ''
    $Entry.PausedNextAction = ''
}

function Apply-TargetAutoloopControlAction {
    param(
        [Parameter(Mandatory)]$ControlDocument,
        [Parameter(Mandatory)]$StateDocument
    )

    $pendingAction = Get-TargetAutoloopPendingControlAction -ControlDocument $ControlDocument
    if (-not (Test-NonEmptyString $pendingAction)) {
        return [pscustomobject]@{
            ControlChanged = $false
            StateChanged = $false
            SkipSweep = $false
            ExitLoop = $false
        }
    }

    switch ($pendingAction) {
        'pause' {
            Complete-TargetAutoloopControlAction -ControlDocument $ControlDocument -State 'paused' -Result 'paused'
            $StateDocument.State = 'paused'
            return [pscustomobject]@{
                ControlChanged = $true
                StateChanged = $true
                SkipSweep = $false
                ExitLoop = $false
                StopReason = ''
            }
        }
        'resume' {
            Complete-TargetAutoloopControlAction -ControlDocument $ControlDocument -State 'running' -Result 'resumed'
            $StateDocument.State = 'running'
            return [pscustomobject]@{
                ControlChanged = $true
                StateChanged = $true
                SkipSweep = $false
                ExitLoop = $false
                StopReason = ''
            }
        }
        'stop' {
            Complete-TargetAutoloopControlAction -ControlDocument $ControlDocument -State 'stopped' -Result 'stopped'
            $StateDocument.State = 'stopped'
            $stateMap = Get-TargetAutoloopTargetStateMap -StateDocument $StateDocument
            foreach ($targetId in @($stateMap.Keys)) {
                $entry = $stateMap[$targetId]
                $phase = [string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '')
                $nextAction = [string](Get-ConfigValue -Object $entry -Name 'NextAction' -DefaultValue '')
                if ($phase -eq 'paused') {
                    $phase = [string](Get-ConfigValue -Object $entry -Name 'PausedPhase' -DefaultValue $phase)
                    $nextAction = [string](Get-ConfigValue -Object $entry -Name 'PausedNextAction' -DefaultValue $nextAction)
                }
                if ($phase -ne 'stopped') {
                    $entry.StoppedPhase = $phase
                    $entry.StoppedNextAction = $nextAction
                }
                $stateMap[$targetId].Phase = 'stopped'
                $stateMap[$targetId].NextAction = 'stopped'
                $stateMap[$targetId].PausedPhase = ''
                $stateMap[$targetId].PausedNextAction = ''
            }
            Set-TargetAutoloopTargetStateMap -TargetStateMap $stateMap -StateDocument $StateDocument
            return [pscustomobject]@{
                ControlChanged = $true
                StateChanged = $true
                SkipSweep = $true
                ExitLoop = $true
                StopReason = 'control-stop-request'
            }
        }
    }

    return [pscustomobject]@{
        ControlChanged = $false
        StateChanged = $false
        SkipSweep = $false
        ExitLoop = $false
        StopReason = ''
    }
}

function Get-TargetAutoloopPublishReadyDelayPolicy {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Target,
        $Entry = $null
    )

    $delayMode = [string](Get-ConfigValue -Object $Target -Name 'PublishReadyDispatchDelayMode' -DefaultValue ([string](Get-ConfigValue -Object $Config -Name 'DefaultPublishReadyDispatchDelayMode' -DefaultValue 'fixed')))
    $minDelaySeconds = [int](Get-ConfigValue -Object $Target -Name 'PublishReadyDispatchMinDelaySeconds' -DefaultValue ([int](Get-ConfigValue -Object $Config -Name 'DefaultPublishReadyDispatchMinDelaySeconds' -DefaultValue ([int](Get-ConfigValue -Object $Config -Name 'DefaultPublishReadyDispatchDelaySeconds' -DefaultValue 0)))))
    $maxDelaySeconds = [int](Get-ConfigValue -Object $Target -Name 'PublishReadyDispatchMaxDelaySeconds' -DefaultValue ([int](Get-ConfigValue -Object $Config -Name 'DefaultPublishReadyDispatchMaxDelaySeconds' -DefaultValue $minDelaySeconds)))
    if ($null -ne $Entry) {
        $delayMode = [string](Get-ConfigValue -Object $Entry -Name 'PublishReadyDispatchDelayMode' -DefaultValue $delayMode)
        $minDelaySeconds = [int](Get-ConfigValue -Object $Entry -Name 'PublishReadyDispatchMinDelaySeconds' -DefaultValue $minDelaySeconds)
        $maxDelaySeconds = [int](Get-ConfigValue -Object $Entry -Name 'PublishReadyDispatchMaxDelaySeconds' -DefaultValue $maxDelaySeconds)
    }

    if ($maxDelaySeconds -lt $minDelaySeconds) {
        $maxDelaySeconds = $minDelaySeconds
    }

    return [pscustomobject]@{
        DelayMode = if ([string]::IsNullOrWhiteSpace($delayMode)) { if ($maxDelaySeconds -gt $minDelaySeconds) { 'range' } else { 'fixed' } } else { $delayMode }
        MinDelaySeconds = [math]::Max(0, $minDelaySeconds)
        MaxDelaySeconds = [math]::Max(0, $maxDelaySeconds)
    }
}

function Resolve-TargetAutoloopPublishReadyDelaySeconds {
    param(
        [string]$TriggerFingerprint = '',
        [int]$MinDelaySeconds = 0,
        [int]$MaxDelaySeconds = 0
    )

    $normalizedMinDelaySeconds = [math]::Max(0, $MinDelaySeconds)
    $normalizedMaxDelaySeconds = [math]::Max($normalizedMinDelaySeconds, $MaxDelaySeconds)
    if ($normalizedMaxDelaySeconds -le $normalizedMinDelaySeconds) {
        return $normalizedMinDelaySeconds
    }

    $normalizedFingerprint = [string]$TriggerFingerprint
    if (-not (Test-NonEmptyString $normalizedFingerprint)) {
        return $normalizedMinDelaySeconds
    }

    $hashHex = (Get-TextHashHex -Text $normalizedFingerprint)
    $sampleHex = if ($hashHex.Length -ge 8) { $hashHex.Substring(0, 8) } else { $hashHex.PadLeft(8, '0') }
    $sampleValue = [uint32]::Parse($sampleHex, [System.Globalization.NumberStyles]::HexNumber)
    $span = ($normalizedMaxDelaySeconds - $normalizedMinDelaySeconds) + 1
    return ($normalizedMinDelaySeconds + [int]($sampleValue % [uint32]$span))
}

function Resolve-TargetAutoloopPublishReadyEligibleAt {
    param(
        [string]$PublishReadyPath = '',
        [string]$PublishedAt = '',
        [int]$DelaySeconds = 0
    )

    $publishedAtValue = [datetimeoffset]::Now
    if (Test-NonEmptyString $PublishReadyPath -and (Test-Path -LiteralPath $PublishReadyPath -PathType Leaf)) {
        $publishedAtValue = [datetimeoffset](Get-Item -LiteralPath $PublishReadyPath -ErrorAction Stop).LastWriteTime
    }
    else {
        $null = $parsedPublishedAt = [datetimeoffset]::MinValue
        if (Test-NonEmptyString $PublishedAt -and [datetimeoffset]::TryParse($PublishedAt, [ref]$parsedPublishedAt)) {
            $publishedAtValue = $parsedPublishedAt
        }
    }

    return $publishedAtValue.AddSeconds([math]::Max(0, $DelaySeconds))
}

function Test-TargetAutoloopAllSelectedTargetsLimitReached {
    param(
        [Parameter(Mandatory)]$StateDocument,
        [string[]]$SelectedTargetIds = @()
    )

    $stateMap = Get-TargetAutoloopTargetStateMap -StateDocument $StateDocument
    $candidateTargetIds = @($SelectedTargetIds | Where-Object { Test-NonEmptyString $_ })
    if (@($candidateTargetIds).Count -eq 0) {
        $candidateTargetIds = @($stateMap.Keys)
    }

    $relevantCount = 0
    $hasLimitReached = $false
    foreach ($targetId in @($candidateTargetIds)) {
        if (-not $stateMap.Contains($targetId)) {
            return $false
        }
        $entry = $stateMap[$targetId]
        $phase = [string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '')
        if (-not (Test-NonEmptyString $phase)) {
            return $false
        }
        $relevantCount += 1
        if ($phase -eq 'limit-reached') {
            $hasLimitReached = $true
            continue
        }
        if ($phase -in @('disabled', 'stopped')) {
            continue
        }
        return $false
    }

    return ($relevantCount -gt 0 -and $hasLimitReached)
}

function Invoke-TargetAutoloopSweep {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ResolvedRunRoot,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$StateDocument,
        [Parameter(Mandatory)]$ControlDocument,
        [Parameter(Mandatory)]$StatePaths,
        [Parameter(Mandatory)][string[]]$SelectedTargetIds
    )

    $stateMap = Get-TargetAutoloopTargetStateMap -StateDocument $StateDocument
    $selectedSet = @{}
    foreach ($targetId in @($SelectedTargetIds)) {
        if (Test-NonEmptyString $targetId) {
            $selectedSet[$targetId] = $true
        }
    }

    $controllerState = [string](Get-ConfigValue -Object $ControlDocument -Name 'State' -DefaultValue 'running')
    $pauseRequested = [bool](Get-ConfigValue -Object $ControlDocument -Name 'PauseRequested' -DefaultValue $false)
    $stopRequested = [bool](Get-ConfigValue -Object $ControlDocument -Name 'StopRequested' -DefaultValue $false)
    if ($stopRequested -or $controllerState -eq 'stopped') {
        $StateDocument.State = 'stopped'
        foreach ($targetId in @($stateMap.Keys)) {
            $stateMap[$targetId].Phase = 'stopped'
            $stateMap[$targetId].NextAction = 'stopped'
        }
        Set-TargetAutoloopTargetStateMap -TargetStateMap $stateMap -StateDocument $StateDocument
        return [pscustomobject]@{ QueuedCount = 0; DuplicateCount = 0; FailedCount = 0; StateChanged = $true }
    }

    $maxTargetsThisSweep = if ([int]$Config.MaxConcurrentTargets -gt 0) { [int]$Config.MaxConcurrentTargets } else { [math]::Max(1, @($Manifest.Targets).Count) }
    $maxCommandsThisSweep = if ([int]$Config.MaxConcurrentSubmits -gt 0) { [int]$Config.MaxConcurrentSubmits } else { 1 }
    $queuedCount = 0
    $duplicateCount = 0
    $failedCount = 0
    $stateChanged = $false
    $queuedTargetIds = New-Object System.Collections.Generic.List[string]

    $candidateTargets = @(
        $Manifest.Targets |
            Where-Object {
                $targetId = [string]$_.TargetId
                $selectedSet.Count -eq 0 -or $selectedSet.ContainsKey($targetId)
            } |
            Select-Object -First $maxTargetsThisSweep
    )

    foreach ($target in @($candidateTargets)) {
        $targetId = [string]$target.TargetId
        $entry = $stateMap[$targetId]
        if ($null -eq $entry) {
            continue
        }

        $controllerPaused = ($pauseRequested -or $controllerState -eq 'paused')
        if ($controllerPaused) {
            $currentPhaseForPause = [string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '')
            if ($currentPhaseForPause -notin @('paused', 'queued', 'disabled', 'failed', 'limit-reached', 'waiting-output')) {
                $entry.PausedPhase = $currentPhaseForPause
                $entry.PausedNextAction = [string](Get-ConfigValue -Object $entry -Name 'NextAction' -DefaultValue '')
                $entry.Phase = 'paused'
                $entry.NextAction = 'resume'
                $stateChanged = $true
            }
        }

        if (-not [bool](Get-ConfigValue -Object $entry -Name 'Enabled' -DefaultValue $false)) {
            $entry.Phase = 'disabled'
            $entry.NextAction = 'no-op'
            $stateChanged = $true
            continue
        }

        $maxCycleCount = [int](Get-ConfigValue -Object $entry -Name 'MaxCycleCount' -DefaultValue 0)
        $currentCycleCount = [int](Get-ConfigValue -Object $entry -Name 'CycleCount' -DefaultValue 0)
        if ($maxCycleCount -gt 0 -and $currentCycleCount -ge $maxCycleCount) {
            $entry.Phase = 'limit-reached'
            $entry.NextAction = 'limit-reached'
            $stateChanged = $true
            continue
        }

        $cooldownUntil = [string](Get-ConfigValue -Object $entry -Name 'CooldownUntil' -DefaultValue '')
        if (Test-NonEmptyString $cooldownUntil) {
            $cooldownAt = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($cooldownUntil, [ref]$cooldownAt) -and $cooldownAt -gt [datetimeoffset]::Now) {
                $entry.Phase = 'cooldown'
                $entry.NextAction = 'cooldown'
                $stateChanged = $true
                continue
            }
            $entry.CooldownUntil = ''
        }

        $paths = Get-TargetAutoloopTargetPaths -RunRoot $ResolvedRunRoot -TargetId $targetId -Target $target -Config $Config
        Ensure-TargetAutoloopTargetDirectories -Paths $paths
        $triggerKinds = @(Get-StringArray (Get-ConfigValue -Object $entry -Name 'TriggerKinds' -DefaultValue @()))
        $fixedSuffix = [string](Get-ConfigValue -Object $target -Name 'FixedSuffix' -DefaultValue '')
        $publishReadyDelayPolicy = Get-TargetAutoloopPublishReadyDelayPolicy -Config $Config -Target $target -Entry $entry
        if ($controllerState -eq 'running' -and [string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '') -eq 'paused') {
            Restore-TargetAutoloopPausedEntryState -Entry $entry -TriggerKinds @($triggerKinds)
            $stateChanged = $true
        }

        $handled = $false
        if ($queuedCount -lt $maxCommandsThisSweep -and $triggerKinds -contains 'publish-ready') {
            $publishReadyValid = Test-TargetAutoloopPublishReadyValid -Paths $paths -ExpectedTargetId $targetId
            if ($publishReadyValid) {
                $publishFingerprint = ''
                $cycleId = $currentCycleCount + 1
                $parentCycleId = [int](Get-ConfigValue -Object $entry -Name 'LastCycleId' -DefaultValue 0)
                $markerCycleId = 0
                $markerParentCycleId = 0
                $markerOutputFingerprint = ''
                try {
                    $publishFingerprint = Get-TargetAutoloopPublishReadyFingerprint -Paths $paths -ExpectedTargetId $targetId
                    if ([string](Get-ConfigValue -Object $entry -Name 'LastTriggerFingerprint' -DefaultValue '') -eq $publishFingerprint) {
                        $duplicateCount += 1
                        Append-TargetAutoloopEvent -Path $StatePaths.EventsPath -EventType 'duplicate-trigger-skipped' -TargetId $targetId -TriggerKind 'publish-ready' -TriggerFingerprint $publishFingerprint
                    }
                    else {
                        $marker = Read-JsonObject -Path $paths.PublishReadyPath
                        $markerCycleId = [int](Get-ConfigValue -Object $marker -Name 'CycleId' -DefaultValue 0)
                        $markerParentCycleId = [int](Get-ConfigValue -Object $marker -Name 'ParentCycleId' -DefaultValue 0)
                        $markerOutputFingerprint = [string](Get-ConfigValue -Object $marker -Name 'OutputFingerprint' -DefaultValue $publishFingerprint)
                        $markerPublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
                        $publishReadyDelaySeconds = Resolve-TargetAutoloopPublishReadyDelaySeconds -TriggerFingerprint $publishFingerprint -MinDelaySeconds ([int]$publishReadyDelayPolicy.MinDelaySeconds) -MaxDelaySeconds ([int]$publishReadyDelayPolicy.MaxDelaySeconds)
                        $dispatchEligibleAt = Resolve-TargetAutoloopPublishReadyEligibleAt -PublishReadyPath ([string]$paths.PublishReadyPath) -PublishedAt $markerPublishedAt -DelaySeconds $publishReadyDelaySeconds
                        $dispatchEligibleAtText = $dispatchEligibleAt.ToString('o')
                        $pendingFingerprint = [string](Get-ConfigValue -Object $entry -Name 'PendingTriggerFingerprint' -DefaultValue '')
                        $pendingEligibleAt = [string](Get-ConfigValue -Object $entry -Name 'PendingDispatchEligibleAt' -DefaultValue '')
                        if ($publishReadyDelaySeconds -gt 0) {
                            if ($pendingFingerprint -ne $publishFingerprint -or $pendingEligibleAt -ne $dispatchEligibleAtText) {
                                $entry.PendingTriggerKind = 'publish-ready'
                                $entry.PendingTriggerFingerprint = $publishFingerprint
                                $entry.PendingDispatchEligibleAt = $dispatchEligibleAtText
                                $entry.PendingDispatchDelaySeconds = $publishReadyDelaySeconds
                                $entry.PendingPublishedAt = $markerPublishedAt
                                $entry.PendingOutputFingerprint = $markerOutputFingerprint
                                $entry.PendingPublishCycleId = $markerCycleId
                                $entry.PendingPublishParentCycleId = $markerParentCycleId
                                if ($controllerPaused) {
                                    $entry.PausedPhase = 'dispatch-delay'
                                    $entry.PausedNextAction = 'wait-dispatch-delay'
                                    $entry.Phase = 'paused'
                                    $entry.NextAction = 'resume'
                                }
                                else {
                                    $entry.Phase = 'dispatch-delay'
                                    $entry.NextAction = 'wait-dispatch-delay'
                                }
                                $entry.LastTriggerKind = 'publish-ready'
                                $entry.LastTriggerSource = 'self-output'
                                $entry.LastOutputReadyAt = (Get-Date).ToString('o')
                                $entry.LastProgressSignalAt = (Get-Date).ToString('o')
                                $entry.LastDispatchState = 'dispatch-delay-waiting'
                                $entry.RelayTargetFolderState = ''
                                $entry.LastFailureReason = ''
                                Append-TargetAutoloopEvent -Path $StatePaths.EventsPath -EventType 'publish-ready-detected' -TargetId $targetId -TriggerKind 'publish-ready' -TriggerFingerprint $publishFingerprint -Extra @{
                                    DelayMode = [string]$publishReadyDelayPolicy.DelayMode
                                    DelaySeconds = $publishReadyDelaySeconds
                                    DelayMinSeconds = [int]$publishReadyDelayPolicy.MinDelaySeconds
                                    DelayMaxSeconds = [int]$publishReadyDelayPolicy.MaxDelaySeconds
                                    DispatchEligibleAt = $dispatchEligibleAtText
                                    PublishCycleId = $markerCycleId
                                    OutputFingerprint = $markerOutputFingerprint
                                }
                                $stateChanged = $true
                            }

                            if ($dispatchEligibleAt -gt [datetimeoffset]::Now) {
                                if ($controllerPaused) {
                                    $entry.PausedPhase = 'dispatch-delay'
                                    $entry.PausedNextAction = 'wait-dispatch-delay'
                                    $entry.Phase = 'paused'
                                    $entry.NextAction = 'resume'
                                }
                                else {
                                    $entry.Phase = 'dispatch-delay'
                                    $entry.NextAction = 'wait-dispatch-delay'
                                }
                                $entry.LastDispatchState = 'dispatch-delay-waiting'
                                $stateChanged = $true
                                $handled = $true
                            }
                        }

                        if ($handled) {
                            continue
                        }

                        $cycleId = $currentCycleCount + 1
                        $parentCycleId = [int](Get-ConfigValue -Object $entry -Name 'LastCycleId' -DefaultValue 0)
                        $promptText = Compose-PublishReadyPromptText -TargetId $targetId -RunMode ([string]$Config.RunMode) -Paths $paths -Marker $marker -EffectiveFixedSuffix $fixedSuffix
                        $request = [ordered]@{
                            SchemaVersion = $script:TargetAutoloopSchemaVersion
                            RunMode = [string]$Config.RunMode
                            TriggerKind = 'publish-ready'
                            TriggerFingerprint = $publishFingerprint
                            LoopSource = 'self-output'
                            CycleId = $cycleId
                            ParentCycleId = $parentCycleId
                            PublishCycleId = $markerCycleId
                            PublishParentCycleId = $markerParentCycleId
                            OutputFingerprint = $markerOutputFingerprint
                            PublishedAt = $markerPublishedAt
                            PublishReadyDispatchDelayMode = [string]$publishReadyDelayPolicy.DelayMode
                            PublishReadyDispatchDelaySeconds = $publishReadyDelaySeconds
                            PublishReadyDispatchMinDelaySeconds = [int]$publishReadyDelayPolicy.MinDelaySeconds
                            PublishReadyDispatchMaxDelaySeconds = [int]$publishReadyDelayPolicy.MaxDelaySeconds
                            DispatchEligibleAt = $dispatchEligibleAtText
                            TargetId = $targetId
                            WorkRepoRoot = [string]$paths.WorkRepoRoot
                            TargetRunRoot = [string]$paths.TargetRunRoot
                            SummaryPath = [string]$paths.SourceSummaryPath
                            ReviewZipPath = [string]$paths.SourceReviewZipPath
                            PublishReadyPath = [string]$paths.PublishReadyPath
                            CreatedAt = (Get-Date).ToString('o')
                        }
                        Write-TargetPromptAndRequest -Paths $paths -PromptText $promptText -Request $request
                        $queueRaw = & (Join-Path $root 'visible\Queue-TargetAutoloopCommand.ps1') `
                            -ConfigPath ([string]$Config.ConfigPath) `
                            -RunRoot $ResolvedRunRoot `
                            -TargetId $targetId `
                            -PromptFilePath ([string]$paths.LastPromptPath) `
                            -RequestFilePath ([string]$paths.CurrentRequestPath) `
                            -RunMode ([string]$Config.RunMode) `
                            -TriggerKind 'publish-ready' `
                            -LoopSource 'self-output' `
                            -TriggerFingerprint $publishFingerprint `
                            -PublishReadyDispatchDelayMode ([string]$publishReadyDelayPolicy.DelayMode) `
                            -PublishReadyDispatchDelaySeconds $publishReadyDelaySeconds `
                            -PublishReadyDispatchMinDelaySeconds ([int]$publishReadyDelayPolicy.MinDelaySeconds) `
                            -PublishReadyDispatchMaxDelaySeconds ([int]$publishReadyDelayPolicy.MaxDelaySeconds) `
                            -DispatchEligibleAt $dispatchEligibleAtText `
                            -CycleId $cycleId `
                            -ParentCycleId $parentCycleId `
                            -AsJson
                        $queueResult = ($queueRaw | ConvertFrom-Json)
                        $queuedPromptPath = [string]$queueResult.PromptFilePath
                        $promptHash = Get-FileHashHex -Path $queuedPromptPath
                        $zipHash = Get-FileHashHex -Path ([string]$paths.SourceReviewZipPath)
                        $receipt = [ordered]@{
                            SchemaVersion = $script:TargetAutoloopSchemaVersion
                            EventKind = 'publish-ready'
                            TargetId = $targetId
                            CycleId = $cycleId
                            ParentCycleId = $parentCycleId
                            PublishCycleId = $markerCycleId
                            PublishParentCycleId = $markerParentCycleId
                            OutputFingerprint = $markerOutputFingerprint
                            TriggerFingerprint = $publishFingerprint
                            CommandId = [string]$queueResult.CommandId
                            CommandPath = [string]$queueResult.CommandPath
                            PromptFilePath = $queuedPromptPath
                            PromptSourcePath = [string]$queueResult.PromptSourcePath
                            RequestSnapshotPath = [string]$queueResult.RequestSnapshotPath
                            PromptSha256 = $promptHash
                            ReviewZipSha256 = $zipHash
                            CreatedAt = (Get-Date).ToString('o')
                        }
                        $receiptPath = Write-TargetReceipt -Paths $paths -CycleId $cycleId -Receipt $receipt
                        $entry.Phase = 'queued'
                        $entry.PausedPhase = ''
                        $entry.PausedNextAction = ''
                        $entry.CycleCount = $cycleId
                        $entry.LastCycleId = $cycleId
                        $entry.LastParentCycleId = $parentCycleId
                        $entry.LastTriggerKind = 'publish-ready'
                        $entry.LastTriggerSource = 'self-output'
                        $entry.LastTriggerFingerprint = $publishFingerprint
                        $entry.LastHandledPublishMarkerId = $markerOutputFingerprint
                        $entry.LastHandledPublishCycleId = $markerCycleId
                        $entry.LastHandledPublishParentCycleId = $markerParentCycleId
                        $entry.LastHandledOutputFingerprint = $markerOutputFingerprint
                        $entry.LastHandledOutputZipHash = $zipHash
                        Clear-TargetAutoloopPendingPublishDispatch -Entry $entry
                        $entry.LastSubmittedPromptHash = $promptHash
                        $entry.LastSubmittedPromptPath = $queuedPromptPath
                        $entry.LastCommandId = [string]$queueResult.CommandId
                        $entry.LastCommandPath = [string]$queueResult.CommandPath
                        $entry.LastReceiptPath = $receiptPath
                        $entry.LastSubmittedAt = (Get-Date).ToString('o')
                        $entry.LastProgressSignalAt = (Get-Date).ToString('o')
                        $entry.LastOutputReadyAt = (Get-Date).ToString('o')
                        $entry.LastDispatchState = ''
                        $entry.RelayTargetFolderState = ''
                        $entry.LastFailureReason = ''
                        $entry.NextAction = 'dispatch-command'
                        Append-TargetAutoloopEvent -Path $StatePaths.EventsPath -EventType 'queued-command' -TargetId $targetId -TriggerKind 'publish-ready' -TriggerFingerprint $publishFingerprint -Extra @{
                            CommandId = [string]$queueResult.CommandId
                            CycleId = $cycleId
                            PublishCycleId = $markerCycleId
                            OutputFingerprint = $markerOutputFingerprint
                        }
                        $queuedTargetIds.Add($targetId) | Out-Null
                        $queuedCount += 1
                        $stateChanged = $true
                        $handled = $true
                    }
                }
                catch {
                    $failedCount += 1
                    $relayTargetFolderState = Get-RelayTargetFolderIssueStateFromMessage -Message $_.Exception.Message
                    $entry.Phase = 'failed'
                    $entry.LastDispatchState = if (Test-NonEmptyString $relayTargetFolderState) { 'relay-folder-preflight-failed' } else { 'queue-command-failed' }
                    $entry.RelayTargetFolderState = $relayTargetFolderState
                    $entry.LastTriggerKind = 'publish-ready'
                    $entry.LastTriggerSource = 'self-output'
                    $entry.LastTriggerFingerprint = $publishFingerprint
                    Clear-TargetAutoloopPendingPublishDispatch -Entry $entry
                    $entry.LastFailureReason = $_.Exception.Message
                    $entry.NextAction = 'open-receipt'
                    $receiptPath = Write-TargetFailureReceipt -Paths $paths `
                        -CycleId $cycleId `
                        -TargetId $targetId `
                        -TriggerKind 'publish-ready' `
                        -TriggerFingerprint $publishFingerprint `
                        -FailureState ([string]$entry.LastDispatchState) `
                        -RelayTargetFolderState $relayTargetFolderState `
                        -FailureReason $_.Exception.Message `
                        -ExtraFields @{
                            ParentCycleId = $parentCycleId
                            PublishCycleId = $markerCycleId
                            PublishParentCycleId = $markerParentCycleId
                            OutputFingerprint = $markerOutputFingerprint
                            SummaryPath = [string]$paths.SourceSummaryPath
                            ReviewZipPath = [string]$paths.SourceReviewZipPath
                            PublishReadyPath = [string]$paths.PublishReadyPath
                        }
                    $entry.LastReceiptPath = $receiptPath
                    Append-TargetAutoloopEvent -Path $StatePaths.EventsPath -EventType 'publish-ready-trigger-failed' -TargetId $targetId -TriggerKind 'publish-ready' -TriggerFingerprint $publishFingerprint -Extra @{
                        Reason = $_.Exception.Message
                        FailureState = [string]$entry.LastDispatchState
                        RelayTargetFolderState = $relayTargetFolderState
                        ReceiptPath = $receiptPath
                    }
                    $stateChanged = $true
                }
            }
            elseif ([string](Get-ConfigValue -Object $entry -Name 'PendingTriggerKind' -DefaultValue '') -eq 'publish-ready') {
                Clear-TargetAutoloopPendingPublishDispatch -Entry $entry
                if ([string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '') -eq 'dispatch-delay') {
                    $entry.Phase = 'idle'
                    $entry.NextAction = 'wait-for-output'
                    $entry.LastDispatchState = ''
                    $stateChanged = $true
                }
            }
        }

        if ($handled -or $queuedCount -ge $maxCommandsThisSweep) {
            continue
        }

        if ($triggerKinds -contains 'input-file') {
            $pendingFilePath = Get-FirstPendingInputFile -Paths $paths
            if (Test-NonEmptyString $pendingFilePath) {
                $inputFingerprint = ''
                $cycleId = $currentCycleCount + 1
                $claimedPath = ''
                $processedPath = ''
                try {
                    $inputFingerprint = Get-TargetAutoloopInputTriggerFingerprint -Path $pendingFilePath
                    if ([string](Get-ConfigValue -Object $entry -Name 'LastTriggerFingerprint' -DefaultValue '') -eq $inputFingerprint) {
                        $duplicateCount += 1
                        Append-TargetAutoloopEvent -Path $StatePaths.EventsPath -EventType 'duplicate-trigger-skipped' -TargetId $targetId -TriggerKind 'input-file' -TriggerFingerprint $inputFingerprint
                        continue
                    }

                    $entry.Phase = 'input-detected'
                    $entry.NextAction = 'claim-input'
                    $claimedPath = Move-FileToDirectory -Path $pendingFilePath -DestinationDirectory ([string]$paths.InboxClaimedRoot)
                    $payload = Read-InputTriggerPayload -Path $claimedPath
                    $effectiveFixedSuffix = [string]$payload.FixedSuffix
                    if (-not (Test-NonEmptyString $effectiveFixedSuffix)) {
                        $effectiveFixedSuffix = $fixedSuffix
                    }
                    $promptText = Compose-InputPromptText -TargetId $targetId -RunMode ([string]$Config.RunMode) -Payload $payload -Paths $paths -EffectiveFixedSuffix $effectiveFixedSuffix
                    $request = [ordered]@{
                        SchemaVersion = $script:TargetAutoloopSchemaVersion
                        RunMode = [string]$Config.RunMode
                        TriggerKind = 'input-file'
                        TriggerFingerprint = $inputFingerprint
                        LoopSource = 'external-inbox'
                        CycleId = $cycleId
                        ParentCycleId = 0
                        TargetId = $targetId
                        WorkRepoRoot = [string]$paths.WorkRepoRoot
                        TargetRunRoot = [string]$paths.TargetRunRoot
                        SummaryPath = [string]$paths.SourceSummaryPath
                        ReviewZipPath = [string]$paths.SourceReviewZipPath
                        PublishReadyPath = [string]$paths.PublishReadyPath
                        InputPath = $claimedPath
                        CreatedAt = (Get-Date).ToString('o')
                    }
                    Write-TargetPromptAndRequest -Paths $paths -PromptText $promptText -Request $request
                    $queueRaw = & (Join-Path $root 'visible\Queue-TargetAutoloopCommand.ps1') `
                        -ConfigPath ([string]$Config.ConfigPath) `
                        -RunRoot $ResolvedRunRoot `
                        -TargetId $targetId `
                        -PromptFilePath ([string]$paths.LastPromptPath) `
                        -RequestFilePath ([string]$paths.CurrentRequestPath) `
                        -RunMode ([string]$Config.RunMode) `
                        -TriggerKind 'input-file' `
                        -LoopSource 'external-inbox' `
                        -TriggerFingerprint $inputFingerprint `
                        -CycleId $cycleId `
                        -ParentCycleId 0 `
                        -AsJson
                    $queueResult = ($queueRaw | ConvertFrom-Json)
                    $processedPath = Move-FileToDirectory -Path $claimedPath -DestinationDirectory ([string]$paths.InboxProcessedRoot)
                    $queuedPromptPath = [string]$queueResult.PromptFilePath
                    $promptHash = Get-FileHashHex -Path $queuedPromptPath
                    $receipt = [ordered]@{
                        SchemaVersion = $script:TargetAutoloopSchemaVersion
                        EventKind = 'input-file'
                        TargetId = $targetId
                        CycleId = $cycleId
                        ParentCycleId = 0
                        TriggerFingerprint = $inputFingerprint
                        CommandId = [string]$queueResult.CommandId
                        CommandPath = [string]$queueResult.CommandPath
                        PromptFilePath = $queuedPromptPath
                        PromptSourcePath = [string]$queueResult.PromptSourcePath
                        RequestSnapshotPath = [string]$queueResult.RequestSnapshotPath
                        PromptSha256 = $promptHash
                        InputPath = $processedPath
                        CreatedAt = (Get-Date).ToString('o')
                    }
                    $receiptPath = Write-TargetReceipt -Paths $paths -CycleId $cycleId -Receipt $receipt
                    $entry.Phase = 'queued'
                    $entry.PausedPhase = ''
                    $entry.PausedNextAction = ''
                    $entry.CycleCount = $cycleId
                    $entry.LastCycleId = $cycleId
                    $entry.LastParentCycleId = 0
                    $entry.LastTriggerKind = 'input-file'
                    $entry.LastTriggerSource = 'external-inbox'
                    $entry.LastTriggerFingerprint = $inputFingerprint
                    $entry.LastSubmittedPromptHash = $promptHash
                    $entry.LastSubmittedPromptPath = $queuedPromptPath
                    $entry.LastInputPath = $processedPath
                    $entry.LastClaimedPath = $claimedPath
                    $entry.LastCommandId = [string]$queueResult.CommandId
                    $entry.LastCommandPath = [string]$queueResult.CommandPath
                    $entry.LastReceiptPath = $receiptPath
                    $entry.LastSubmittedAt = (Get-Date).ToString('o')
                    $entry.LastProgressSignalAt = (Get-Date).ToString('o')
                    $entry.LastDispatchState = ''
                    $entry.RelayTargetFolderState = ''
                    $entry.LastFailureReason = ''
                    $entry.NextAction = 'dispatch-command'
                    Append-TargetAutoloopEvent -Path $StatePaths.EventsPath -EventType 'queued-command' -TargetId $targetId -TriggerKind 'input-file' -TriggerFingerprint $inputFingerprint -Extra @{
                        CommandId = [string]$queueResult.CommandId
                        CycleId = $cycleId
                    }
                    $queuedTargetIds.Add($targetId) | Out-Null
                    $queuedCount += 1
                    $stateChanged = $true
                }
                catch {
                    $failedCount += 1
                    $relayTargetFolderState = Get-RelayTargetFolderIssueStateFromMessage -Message $_.Exception.Message
                    $entry.Phase = 'failed'
                    $entry.LastDispatchState = if (Test-NonEmptyString $relayTargetFolderState) { 'relay-folder-preflight-failed' } else { 'queue-command-failed' }
                    $entry.RelayTargetFolderState = $relayTargetFolderState
                    $entry.LastTriggerKind = 'input-file'
                    $entry.LastTriggerSource = 'external-inbox'
                    $entry.LastTriggerFingerprint = $inputFingerprint
                    $entry.LastFailureReason = $_.Exception.Message
                    $entry.NextAction = 'open-receipt'
                    $receiptInputPath = ''
                    if (Test-NonEmptyString $claimedPath -and (Test-Path -LiteralPath $claimedPath -PathType Leaf)) {
                        try {
                            $receiptInputPath = Move-FileToDirectory -Path $claimedPath -DestinationDirectory ([string]$paths.InboxFailedRoot)
                        }
                        catch {
                            $receiptInputPath = $claimedPath
                        }
                    }
                    elseif (Test-NonEmptyString $processedPath) {
                        $receiptInputPath = $processedPath
                    }
                    elseif (Test-NonEmptyString $pendingFilePath -and (Test-Path -LiteralPath $pendingFilePath -PathType Leaf)) {
                        $receiptInputPath = $pendingFilePath
                    }
                    if (Test-NonEmptyString $claimedPath) {
                        $entry.LastClaimedPath = $claimedPath
                    }
                    if (Test-NonEmptyString $receiptInputPath) {
                        $entry.LastInputPath = $receiptInputPath
                    }
                    $receiptPath = Write-TargetFailureReceipt -Paths $paths `
                        -CycleId $cycleId `
                        -TargetId $targetId `
                        -TriggerKind 'input-file' `
                        -TriggerFingerprint $inputFingerprint `
                        -FailureState ([string]$entry.LastDispatchState) `
                        -RelayTargetFolderState $relayTargetFolderState `
                        -FailureReason $_.Exception.Message `
                        -ExtraFields @{
                            ParentCycleId = 0
                            InputPath = $receiptInputPath
                            ClaimedPath = $claimedPath
                        }
                    $entry.LastReceiptPath = $receiptPath
                    Append-TargetAutoloopEvent -Path $StatePaths.EventsPath -EventType 'input-trigger-failed' -TargetId $targetId -TriggerKind 'input-file' -TriggerFingerprint $inputFingerprint -Extra @{
                        Reason = $_.Exception.Message
                        FailureState = [string]$entry.LastDispatchState
                        RelayTargetFolderState = $relayTargetFolderState
                        ReceiptPath = $receiptPath
                        InputPath = $receiptInputPath
                    }
                    $stateChanged = $true
                }
            }
            elseif ([string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '') -eq 'idle') {
                $entry.NextAction = if ($triggerKinds -contains 'publish-ready') { 'wait-for-output' } else { 'wait-for-input' }
            }
        }
    }

    Set-TargetAutoloopTargetStateMap -TargetStateMap $stateMap -StateDocument $StateDocument
    return [pscustomobject]@{
        QueuedCount = $queuedCount
        DuplicateCount = $duplicateCount
        FailedCount = $failedCount
        StateChanged = $stateChanged
        QueuedTargetIds = $queuedTargetIds.ToArray()
    }
}

function Write-TargetAutoloopStatusSnapshot {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$StateDocument,
        [Parameter(Mandatory)]$ControlDocument,
        [Parameter(Mandatory)]$StatePaths,
        [Parameter(Mandatory)][ValidateSet('running', 'paused', 'stopped')][string]$WatcherState,
        [string]$WatcherStopReason = '',
        [string]$WatcherMutexName = '',
        [string]$HeartbeatAt = '',
        [string]$ProcessStartedAt = '',
        [int]$ConfiguredRunDurationSec = 0
    )

    $statusDocument = New-TargetAutoloopStatusDocument `
        -Config $Config `
        -RunRoot $RunRoot `
        -StateDocument $StateDocument `
        -ControlDocument $ControlDocument `
        -WatcherState $WatcherState `
        -WatcherStopReason $WatcherStopReason `
        -WatcherMutexName $WatcherMutexName `
        -HeartbeatAt $HeartbeatAt `
        -ProcessStartedAt $ProcessStartedAt `
        -ConfiguredRunDurationSec $ConfiguredRunDurationSec
    Write-JsonFileAtomically -Path $StatePaths.StatusPath -Payload $statusDocument
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
$resolvedRunRoot = Resolve-TargetAutoloopRunRoot -Config $config -RequestedRunRoot $RunRoot
$dispatchQueuedInline = if ($PSBoundParameters.ContainsKey('DispatchQueuedCommandsInline')) {
    [bool]$DispatchQueuedCommandsInline
}
else {
    [bool]$config.DispatchQueuedCommandsInline
}
$watcherMutexName = Get-TargetAutoloopWatcherMutexName -RunRoot $resolvedRunRoot
$watcherMutex = $null
$watcherStarted = $false
$watcherProcessStartedAt = ''
$watcherHeartbeatAt = ''
$watcherStopReason = 'completed'
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "target autoloop manifest not found: $manifestPath"
}
$manifest = Read-JsonObject -Path $manifestPath
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
$stateDocument = Read-JsonObject -Path $statePaths.StatePath
$controlDocument = Read-JsonObject -Path $statePaths.ControlPath
$selectedTargets = @(
    $Targets |
        Where-Object { Test-NonEmptyString $_ } |
        ForEach-Object { [string]$_ } |
        Sort-Object -Unique
)
if (@($selectedTargets).Count -eq 0) {
    $selectedTargets = @($manifest.Targets | ForEach-Object { [string]$_.TargetId })
}

$deadline = if ($RunDurationSec -gt 0) { (Get-Date).AddSeconds($RunDurationSec) } else { $null }
$aggregateQueued = 0
$aggregateDuplicates = 0
$aggregateFailed = 0
$aggregateDispatched = 0
$iterationCount = 0
try {
    $watcherMutex = Acquire-TargetAutoloopWatcherMutex -Name $watcherMutexName
    $watcherStarted = $true
    $watcherProcessStartedAt = (Get-Date).ToString('o')
    $watcherHeartbeatAt = $watcherProcessStartedAt
    $initialControllerState = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue 'running')
    $initialWatcherState = if ($initialControllerState -eq 'paused') { 'paused' } elseif ($initialControllerState -eq 'stopped') { 'stopped' } else { 'running' }
    Write-TargetAutoloopStatusSnapshot `
        -Config $config `
        -RunRoot $resolvedRunRoot `
        -StateDocument $stateDocument `
        -ControlDocument $controlDocument `
        -StatePaths $statePaths `
        -WatcherState $initialWatcherState `
        -WatcherStopReason '' `
        -WatcherMutexName $watcherMutexName `
        -HeartbeatAt $watcherHeartbeatAt `
        -ProcessStartedAt $watcherProcessStartedAt `
        -ConfiguredRunDurationSec $RunDurationSec

    do {
        if ($RunDurationSec -gt 0 -and $null -ne $deadline -and (Get-Date) -ge $deadline) {
            $watcherStopReason = 'run-duration-reached'
            break
        }

        $iterationCount += 1
        $controlActionResult = Apply-TargetAutoloopControlAction -ControlDocument $controlDocument -StateDocument $stateDocument
        if ([bool]$controlActionResult.ControlChanged) {
            Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
        }
        if ([bool]$controlActionResult.SkipSweep) {
            $sweepResult = [pscustomobject]@{
                QueuedCount = 0
                DuplicateCount = 0
                FailedCount = 0
                StateChanged = [bool]$controlActionResult.StateChanged
                QueuedTargetIds = @()
            }
        }
        else {
            $sweepResult = Invoke-TargetAutoloopSweep `
                -Config $config `
                -ResolvedRunRoot $resolvedRunRoot `
                -Manifest $manifest `
                -StateDocument $stateDocument `
                -ControlDocument $controlDocument `
                -StatePaths $statePaths `
                -SelectedTargetIds @($selectedTargets)
        }
        $aggregateQueued += [int]$sweepResult.QueuedCount
        $aggregateDuplicates += [int]$sweepResult.DuplicateCount
        $aggregateFailed += [int]$sweepResult.FailedCount
        $autoStopReason = ''
        if (Test-TargetAutoloopAllSelectedTargetsLimitReached -StateDocument $stateDocument -SelectedTargetIds @($selectedTargets)) {
            $stateDocument.State = 'stopped'
            $controlDocument.State = 'stopped'
            $controlDocument.LastUpdatedAt = (Get-Date).ToString('o')
            $autoStopReason = 'all-targets-limit-reached'
        }
        $stateDocument.LastUpdatedAt = (Get-Date).ToString('o')
        Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
        Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
        $watcherHeartbeatAt = (Get-Date).ToString('o')
        $loopControllerState = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue 'running')
        $loopWatcherState = if ([bool]$controlActionResult.ExitLoop -or $loopControllerState -eq 'stopped') { 'stopped' } elseif ($loopControllerState -eq 'paused') { 'paused' } else { 'running' }
        Write-TargetAutoloopStatusSnapshot `
            -Config $config `
            -RunRoot $resolvedRunRoot `
            -StateDocument $stateDocument `
            -ControlDocument $controlDocument `
            -StatePaths $statePaths `
            -WatcherState $loopWatcherState `
            -WatcherStopReason '' `
            -WatcherMutexName $watcherMutexName `
            -HeartbeatAt $watcherHeartbeatAt `
            -ProcessStartedAt $watcherProcessStartedAt `
            -ConfiguredRunDurationSec $RunDurationSec

        if ($dispatchQueuedInline) {
            $dispatchTargetIds = @(
                Get-StringArray (Get-ConfigValue -Object $sweepResult -Name 'QueuedTargetIds' -DefaultValue @()) |
                    Where-Object { Test-NonEmptyString $_ } |
                    Sort-Object -Unique
            )
            foreach ($dispatchTargetId in @($dispatchTargetIds)) {
                $dispatchRaw = & (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
                    -ConfigPath ([string]$config.ConfigPath) `
                    -RunRoot $resolvedRunRoot `
                    -TargetId $dispatchTargetId `
                    -ProcessOnce `
                    -AsJson
                $dispatchResult = ($dispatchRaw | ConvertFrom-Json)
                $aggregateDispatched += [int](Get-ConfigValue -Object $dispatchResult -Name 'ProcessedCount' -DefaultValue 0)
            }
            $stateDocument = Read-JsonObject -Path $statePaths.StatePath
            $controlDocument = Read-JsonObject -Path $statePaths.ControlPath
            $watcherHeartbeatAt = (Get-Date).ToString('o')
            $dispatchControllerState = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue 'running')
            $dispatchWatcherState = if ($dispatchControllerState -eq 'paused') { 'paused' } elseif ($dispatchControllerState -eq 'stopped') { 'stopped' } else { 'running' }
            Write-TargetAutoloopStatusSnapshot `
                -Config $config `
                -RunRoot $resolvedRunRoot `
                -StateDocument $stateDocument `
                -ControlDocument $controlDocument `
                -StatePaths $statePaths `
                -WatcherState $dispatchWatcherState `
                -WatcherStopReason '' `
                -WatcherMutexName $watcherMutexName `
                -HeartbeatAt $watcherHeartbeatAt `
                -ProcessStartedAt $watcherProcessStartedAt `
                -ConfiguredRunDurationSec $RunDurationSec
        }

        if (Test-NonEmptyString $autoStopReason) {
            $watcherStopReason = $autoStopReason
            break
        }
        if ([bool]$controlActionResult.ExitLoop) {
            if (Test-NonEmptyString ([string]$controlActionResult.StopReason)) {
                $watcherStopReason = [string]$controlActionResult.StopReason
            }
            break
        }
        if ($ProcessOnce) {
            $watcherStopReason = 'process-once-completed'
            break
        }
        Start-Sleep -Milliseconds ([math]::Max(100, [int]$config.PollIntervalMs))
        $controlDocument = Read-JsonObject -Path $statePaths.ControlPath
        $stateDocument = Read-JsonObject -Path $statePaths.StatePath
    } while ($true)
}
finally {
    if ($watcherStarted -and $null -ne $stateDocument -and $null -ne $controlDocument) {
        $stateDocument.LastUpdatedAt = (Get-Date).ToString('o')
        Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
        Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
        if (-not (Test-NonEmptyString $watcherHeartbeatAt)) {
            $watcherHeartbeatAt = (Get-Date).ToString('o')
        }
        Write-TargetAutoloopStatusSnapshot `
            -Config $config `
            -RunRoot $resolvedRunRoot `
            -StateDocument $stateDocument `
            -ControlDocument $controlDocument `
            -StatePaths $statePaths `
            -WatcherState 'stopped' `
            -WatcherStopReason $watcherStopReason `
            -WatcherMutexName $watcherMutexName `
            -HeartbeatAt $watcherHeartbeatAt `
            -ProcessStartedAt $watcherProcessStartedAt `
            -ConfiguredRunDurationSec $RunDurationSec
    }
    if ($null -ne $watcherMutex) {
        try {
            $watcherMutex.ReleaseMutex()
        }
        catch {
        }
        try {
            $watcherMutex.Dispose()
        }
        catch {
        }
    }
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunMode = [string]$config.RunMode
    RunRoot = $resolvedRunRoot
    IterationCount = $iterationCount
    QueuedCount = $aggregateQueued
    DuplicateCount = $aggregateDuplicates
    FailedCount = $aggregateFailed
    DispatchedCount = $aggregateDispatched
    StatePath = [string]$statePaths.StatePath
    StatusPath = [string]$statePaths.StatusPath
    ControlPath = [string]$statePaths.ControlPath
    WatcherState = 'stopped'
    WatcherStopReason = $watcherStopReason
    WatcherMutexName = $watcherMutexName
    HeartbeatAt = $watcherHeartbeatAt
    ProcessStartedAt = $watcherProcessStartedAt
    ConfiguredRunDurationSec = $RunDurationSec
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

$result
