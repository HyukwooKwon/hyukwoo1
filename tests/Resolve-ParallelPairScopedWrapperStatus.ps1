[CmdletBinding()]
param(
    [string]$CoordinatorRunRoot,
    [string]$WrapperStatusPath,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload,
        [int]$Depth = 12
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth $Depth), (New-Utf8NoBomEncoding))
}

function Read-JsonFileOrDefault {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-JsonObjectFromMixedOutput {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $start = $raw.IndexOf('{')
    $end = $raw.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) {
        return $null
    }

    try {
        return ($raw.Substring($start, $end - $start + 1) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-LatestRunRootFromBase {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return ''
    }

    $candidate = Get-ChildItem -LiteralPath $Path -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $candidate) {
        return ''
    }

    return [string]$candidate.FullName
}

function Test-ProcessAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }

    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-ChildRunRoot {
    param([Parameter(Mandatory)]$Child)

    if (Test-NonEmptyString ([string]$Child.RunRoot) -and (Test-Path -LiteralPath ([string]$Child.RunRoot) -PathType Container)) {
        return [string]$Child.RunRoot
    }

    $stdoutPayload = $null
    if (Test-NonEmptyString ([string]$Child.StdOutPath)) {
        $stdoutPayload = Get-JsonObjectFromMixedOutput -Path ([string]$Child.StdOutPath)
        if ($null -ne $stdoutPayload -and (Test-NonEmptyString ([string]$stdoutPayload.RunRoot)) -and (Test-Path -LiteralPath ([string]$stdoutPayload.RunRoot) -PathType Container)) {
            return [string]$stdoutPayload.RunRoot
        }
    }

    if (Test-NonEmptyString ([string]$Child.PairRunRootBase)) {
        return (Get-LatestRunRootFromBase -Path ([string]$Child.PairRunRootBase))
    }

    return ''
}

function Get-CountUnderRunRoot {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$Filter
    )

    if (-not (Test-Path -LiteralPath $RunRoot -PathType Container)) {
        return 0
    }

    return [int]((Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue | Measure-Object).Count)
}

function Get-ChildRunSnapshot {
    param([Parameter(Mandatory)]$Child)

    $runRoot = Resolve-ChildRunRoot -Child $Child
    $watcher = $null
    $pairState = $null
    if (Test-NonEmptyString $runRoot) {
        $watcher = Read-JsonFileOrDefault -Path (Join-Path $runRoot '.state\watcher-status.json')
        $pairState = Read-JsonFileOrDefault -Path (Join-Path $runRoot '.state\pair-state.json')
    }

    $pairSummary = $null
    if ($null -ne $pairState -and @($pairState.Pairs).Count -gt 0) {
        $pairSummary = @($pairState.Pairs | Where-Object { [string]$_.PairId -eq [string]$Child.PairId } | Select-Object -First 1)[0]
        if ($null -eq $pairSummary) {
            $pairSummary = @($pairState.Pairs | Select-Object -First 1)[0]
        }
    }

    $doneCount = if (Test-NonEmptyString $runRoot) { Get-CountUnderRunRoot -RunRoot $runRoot -Filter 'done.json' } else { 0 }
    $errorCount = if (Test-NonEmptyString $runRoot) { Get-CountUnderRunRoot -RunRoot $runRoot -Filter 'error.json' } else { 0 }
    $resultCount = if (Test-NonEmptyString $runRoot) { Get-CountUnderRunRoot -RunRoot $runRoot -Filter 'result.json' } else { 0 }
    $processAlive = Test-ProcessAlive -ProcessId ([int]($Child.ProcessId | ForEach-Object { $_ }))

    $watcherState = if ($null -ne $watcher) { [string]$watcher.State } else { '' }
    $watcherReason = if ($null -ne $watcher) { [string]$watcher.Reason } else { '' }
    $roundtripCount = if ($null -ne $pairSummary) { [int]$pairSummary.RoundtripCount } else { 0 }
    $currentPhase = if ($null -ne $pairSummary) { [string]$pairSummary.CurrentPhase } else { '' }
    $lastForwardedAt = if ($null -ne $pairSummary) { [string]$pairSummary.LastForwardedAt } else { '' }
    $heartbeatAt = if ($null -ne $watcher) { [string]$watcher.HeartbeatAt } else { '' }

    $finalResult = 'unknown'
    $completionSource = ''
    $completedAt = ''
    if ($watcherState -eq 'stopped' -and $errorCount -eq 0 -and $doneCount -ge 2) {
        $finalResult = 'success'
        $completionSource = 'child-watcher'
        $completedAt = if ($null -ne $watcher -and (Test-NonEmptyString ([string]$watcher.UpdatedAt))) { [string]$watcher.UpdatedAt } else { (Get-Date).ToString('o') }
    }
    elseif ($errorCount -gt 0) {
        $finalResult = 'failed'
        $completionSource = 'child-run'
        $completedAt = (Get-Date).ToString('o')
    }
    elseif ($processAlive -or $watcherState -in @('running', 'starting', 'pause_requested', 'resume_requested', 'stop_requested', 'stopping')) {
        $finalResult = 'running'
    }
    elseif ($watcherState -eq 'stopped') {
        $finalResult = 'failed'
        $completionSource = 'child-watcher'
        $completedAt = if ($null -ne $watcher -and (Test-NonEmptyString ([string]$watcher.UpdatedAt))) { [string]$watcher.UpdatedAt } else { (Get-Date).ToString('o') }
    }
    else {
        $finalResult = 'running'
    }

    return [pscustomobject]@{
        PairId = [string]$Child.PairId
        WorkRepoRoot = [string]$Child.WorkRepoRoot
        BookkeepingRoot = [string]$Child.BookkeepingRoot
        ConfigPath = [string]$Child.ConfigPath
        PairRunRootBase = [string]$Child.PairRunRootBase
        RunRoot = $runRoot
        ProcessId = [int]($Child.ProcessId | ForEach-Object { $_ })
        ProcessAlive = $processAlive
        ProcessStartedAt = [string]$Child.ProcessStartedAt
        ProcessExitedAt = [string]$Child.ProcessExitedAt
        StdOutPath = [string]$Child.StdOutPath
        StdErrPath = [string]$Child.StdErrPath
        WatcherState = $watcherState
        WatcherReason = $watcherReason
        LastHeartbeatAt = $heartbeatAt
        RoundtripCount = $roundtripCount
        CurrentPhase = $currentPhase
        LastForwardedAt = $lastForwardedAt
        DonePresentCount = $doneCount
        ErrorPresentCount = $errorCount
        ResultPresentCount = $resultCount
        CompletedAt = $completedAt
        CompletionSource = $completionSource
        FinalResult = $finalResult
    }
}

function Build-CoordinatorArtifacts {
    param(
        [Parameter(Mandatory)]$Wrapper,
        [Parameter(Mandatory)][object[]]$PairRuns
    )

    $coordinatorForwardedCount = 0
    $coordinatorDoneCount = 0
    $coordinatorErrorCount = 0
    foreach ($summary in @($PairRuns)) {
        $coordinatorForwardedCount += [int]$summary.RoundtripCount * 2
        $coordinatorDoneCount += [int]$summary.DonePresentCount
        $coordinatorErrorCount += [int]$summary.ErrorPresentCount
    }

    $manifest = [pscustomobject]@{
        SchemaVersion = '1.0.0'
        GeneratedAt = (Get-Date).ToString('o')
        Mode = 'pair-scoped-shared-coordinator'
        BaseConfigPath = [string]$Wrapper.BaseConfigPath
        CoordinatorWorkRepoRoot = [string]$Wrapper.CoordinatorWorkRepoRoot
        RunRoot = [string]$Wrapper.CoordinatorRunRoot
        PairIds = @($Wrapper.PairIds)
        PairMaxRoundtripCount = [int]$Wrapper.PairMaxRoundtripCount
        RunDurationSec = [int]$Wrapper.RunDurationSec
        PairRuns = @($PairRuns)
    }

    $allReachedLimit = $true
    foreach ($summary in @($PairRuns)) {
        if ([int]$summary.RoundtripCount -lt [int]$Wrapper.PairMaxRoundtripCount) {
            $allReachedLimit = $false
            break
        }
    }
    $statusReason = if ([int]$Wrapper.PairMaxRoundtripCount -gt 0 -and $allReachedLimit) { 'pair-scoped-shared-coordinator-limit-reached' } else { 'pair-scoped-shared-coordinator-completed' }

    $watcherStatus = [pscustomobject]@{
        SchemaVersion = '1.0.0'
        Status = 'stopped'
        StatusReason = $statusReason
        StopCategory = 'expected-limit'
        UpdatedAt = (Get-Date).ToString('o')
        PairIds = @($Wrapper.PairIds)
        PairMaxRoundtripCount = [int]$Wrapper.PairMaxRoundtripCount
        PairRunCount = @($PairRuns).Count
        ForwardedCount = $coordinatorForwardedCount
    }

    $pairState = [pscustomobject]@{
        SchemaVersion = '1.0.0'
        GeneratedAt = (Get-Date).ToString('o')
        RunRoot = [string]$Wrapper.CoordinatorRunRoot
        PairIds = @($Wrapper.PairIds)
        DonePresentCount = $coordinatorDoneCount
        ErrorPresentCount = $coordinatorErrorCount
        ForwardedStateCount = $coordinatorForwardedCount
        Pairs = @($PairRuns)
    }

    return [pscustomobject]@{
        Manifest = $manifest
        WatcherStatus = $watcherStatus
        PairState = $pairState
    }
}

if (-not (Test-NonEmptyString $WrapperStatusPath)) {
    if (-not (Test-NonEmptyString $CoordinatorRunRoot)) {
        throw 'CoordinatorRunRoot 또는 WrapperStatusPath가 필요합니다.'
    }
    $WrapperStatusPath = Join-Path $CoordinatorRunRoot '.state\wrapper-status.json'
}

$resolvedWrapperStatusPath = (Resolve-Path -LiteralPath $WrapperStatusPath).Path
$wrapper = Read-JsonFileOrDefault -Path $resolvedWrapperStatusPath
if ($null -eq $wrapper) {
    throw "wrapper-status.json을 읽지 못했습니다: $resolvedWrapperStatusPath"
}

$childSnapshots = @(
    foreach ($child in @($wrapper.ChildProcesses)) {
        Get-ChildRunSnapshot -Child $child
    }
)

$allSuccessful = (@($childSnapshots).Count -gt 0)
$hasFailures = $false
$hasRunning = $false
foreach ($snapshot in @($childSnapshots)) {
    if ([string]$snapshot.FinalResult -eq 'failed') {
        $hasFailures = $true
        $allSuccessful = $false
    }
    elseif ([string]$snapshot.FinalResult -ne 'success') {
        $hasRunning = $true
        $allSuccessful = $false
    }
}

$wrapper.Status = if ($allSuccessful) { 'completed' } elseif ($hasFailures) { 'failed' } else { 'running' }
$reconciledAt = (Get-Date).ToString('o')
$completionSource = if ($allSuccessful -or $hasFailures) { 'coordinator-reconcile' } else { '' }
$completedAt = if ($allSuccessful -or $hasFailures) { $reconciledAt } else { '' }
$finalResult = if ($allSuccessful) { 'success' } elseif ($hasFailures) { 'failed' } else { 'timed_out_parent_but_children_running' }
$message = if ($allSuccessful) { 'reconciled from child pair runs' } elseif ($hasFailures) { 'reconciled with failed child pair runs' } else { 'child pair runs are still active or not yet complete' }
$wrapper | Add-Member -NotePropertyName ReconciledAt -NotePropertyValue $reconciledAt -Force
$wrapper | Add-Member -NotePropertyName PairRuns -NotePropertyValue @($childSnapshots) -Force
$wrapper | Add-Member -NotePropertyName CompletionSource -NotePropertyValue $completionSource -Force
$wrapper | Add-Member -NotePropertyName CompletedAt -NotePropertyValue $completedAt -Force
$wrapper | Add-Member -NotePropertyName FinalResult -NotePropertyValue $finalResult -Force
$wrapper | Add-Member -NotePropertyName Message -NotePropertyValue $message -Force

if ($allSuccessful -and (Test-NonEmptyString ([string]$wrapper.CoordinatorManifestPath)) -and (Test-NonEmptyString ([string]$wrapper.CoordinatorWatcherStatusPath)) -and (Test-NonEmptyString ([string]$wrapper.CoordinatorPairStatePath))) {
    $pairRunSummaries = @(
        foreach ($snapshot in @($childSnapshots)) {
            [pscustomobject]@{
                PairId = [string]$snapshot.PairId
                ConfigPath = [string]$snapshot.ConfigPath
                WorkRepoRoot = [string]$snapshot.WorkRepoRoot
                BookkeepingRoot = [string]$snapshot.BookkeepingRoot
                RunRoot = [string]$snapshot.RunRoot
                WatcherStatus = [string]$snapshot.WatcherState
                WatcherReason = [string]$snapshot.WatcherReason
                DonePresentCount = [int]$snapshot.DonePresentCount
                ErrorPresentCount = [int]$snapshot.ErrorPresentCount
                ForwardedStateCount = [int]$snapshot.RoundtripCount * 2
                RoundtripCount = [int]$snapshot.RoundtripCount
                CurrentPhase = [string]$snapshot.CurrentPhase
                NextAction = if ([string]$snapshot.CurrentPhase -eq 'limit-reached') { 'limit-reached' } else { [string]$snapshot.CurrentPhase }
                LastForwardedAt = [string]$snapshot.LastForwardedAt
                CompletionSource = [string]$snapshot.CompletionSource
                CompletedAt = [string]$snapshot.CompletedAt
                FinalResult = [string]$snapshot.FinalResult
            }
        }
    )

    $aggregateArtifacts = Build-CoordinatorArtifacts -Wrapper $wrapper -PairRuns @($pairRunSummaries)
    Write-JsonFile -Path ([string]$wrapper.CoordinatorManifestPath) -Payload $aggregateArtifacts.Manifest -Depth 12
    Write-JsonFile -Path ([string]$wrapper.CoordinatorWatcherStatusPath) -Payload $aggregateArtifacts.WatcherStatus -Depth 8
    Write-JsonFile -Path ([string]$wrapper.CoordinatorPairStatePath) -Payload $aggregateArtifacts.PairState -Depth 12
}

Write-JsonFile -Path $resolvedWrapperStatusPath -Payload $wrapper -Depth 14

if ($AsJson) {
    $wrapper | ConvertTo-Json -Depth 14
    return
}

$wrapper
