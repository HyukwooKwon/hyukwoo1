[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$TargetId,
    [string]$KeepRunRoot,
    [int]$StaleAgeSeconds = 300,
    [switch]$Apply,
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

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }

    return ($raw | ConvertFrom-Json)
}

function Write-JsonFileAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $tempPath = ($Path + '.tmp')
    $Payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Get-WorkerStatusPath {
    param(
        [Parameter(Mandatory)][string]$StatusRoot,
        [Parameter(Mandatory)][string]$TargetKey
    )

    return (Join-Path (Join-Path $StatusRoot 'workers') ("worker_{0}.json" -f $TargetKey))
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

function Stop-ProcessTree {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return
    }

    $taskKillPath = Join-Path $env:WINDIR 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $taskKillPath -PathType Leaf) {
        & $taskKillPath /PID $ProcessId /T /F | Out-Null
        return
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
}

function Get-NormalizedPath {
    param([string]$PathValue)

    if (-not (Test-NonEmptyString $PathValue)) {
        return ''
    }

    return [System.IO.Path]::GetFullPath($PathValue)
}

function Test-SameNormalizedPath {
    param(
        [string]$Left,
        [string]$Right
    )

    if (-not (Test-NonEmptyString $Left) -or -not (Test-NonEmptyString $Right)) {
        return $false
    }

    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-IsoAgeSeconds {
    param([string]$IsoTimestamp)

    if (-not (Test-NonEmptyString $IsoTimestamp)) {
        return -1
    }

    try {
        $parsed = [datetimeoffset]::Parse($IsoTimestamp)
    }
    catch {
        return -1
    }

    return [int][math]::Max(0, [math]::Round(((Get-Date).ToUniversalTime() - $parsed.UtcDateTime).TotalSeconds))
}

function Test-RequiredCommandFieldSet {
    param($Command)

    $requiredFields = @('SchemaVersion', 'CommandId', 'RunRoot', 'TargetId', 'PromptFilePath')
    $missing = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Command) {
        foreach ($field in $requiredFields) {
            $missing.Add($field)
        }

        return [pscustomobject]@{
            Passed = $false
            MissingFields = [string[]]$missing.ToArray()
        }
    }

    foreach ($field in $requiredFields) {
        $property = $Command.PSObject.Properties[$field]
        if ($null -eq $property) {
            $missing.Add($field)
            continue
        }

        $value = $property.Value
        if (-not (Test-NonEmptyString ([string]$value))) {
            $missing.Add($field)
        }
    }

    return [pscustomobject]@{
        Passed = ($missing.Count -eq 0)
        MissingFields = [string[]]$missing.ToArray()
    }
}

function Get-OptionalCommandFieldValue {
    param(
        $Command,
        [Parameter(Mandatory)][string]$FieldName
    )

    if ($null -eq $Command) {
        return ''
    }

    $property = $Command.PSObject.Properties[$FieldName]
    if ($null -eq $property) {
        return ''
    }

    return [string]$property.Value
}

function Get-WorkerSnapshot {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $statusPath = Get-WorkerStatusPath -StatusRoot ([string]$PairTest.VisibleWorker.StatusRoot) -TargetKey $TargetKey
    $statusDoc = $null
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try {
            $statusDoc = Read-JsonObject -Path $statusPath
        }
        catch {
            $statusDoc = $null
        }
    }

    $workerPid = if ($null -ne $statusDoc -and $null -ne $statusDoc.WorkerPid) { [int]$statusDoc.WorkerPid } else { 0 }
    return [pscustomobject]@{
        StatusPath            = $statusPath
        Exists                 = ($null -ne $statusDoc)
        Status                 = if ($null -ne $statusDoc) { [string]$statusDoc.State } else { '' }
        WorkerPid              = $workerPid
        WorkerAlive            = (Test-ProcessAlive -ProcessId $workerPid)
        CurrentCommandId       = if ($null -ne $statusDoc) { [string]$statusDoc.CurrentCommandId } else { '' }
        CurrentRunRoot         = if ($null -ne $statusDoc) { [string]$statusDoc.CurrentRunRoot } else { '' }
        CurrentPromptFilePath  = if ($null -ne $statusDoc) { [string]$statusDoc.CurrentPromptFilePath } else { '' }
        LastCommandId          = if ($null -ne $statusDoc) { [string]$statusDoc.LastCommandId } else { '' }
        LastCompletedAt        = if ($null -ne $statusDoc) { [string]$statusDoc.LastCompletedAt } else { '' }
        LastFailedAt           = if ($null -ne $statusDoc) { [string]$statusDoc.LastFailedAt } else { '' }
        StdOutLogPath          = if ($null -ne $statusDoc) { [string]$statusDoc.StdOutLogPath } else { '' }
        StdErrLogPath          = if ($null -ne $statusDoc) { [string]$statusDoc.StdErrLogPath } else { '' }
        Reason                 = if ($null -ne $statusDoc) { [string]$statusDoc.Reason } else { '' }
        Document               = $statusDoc
    }
}

function Get-RunWatcherSnapshot {
    param([string]$RunRoot)

    $normalizedRunRoot = Get-NormalizedPath -PathValue $RunRoot
    if (-not (Test-NonEmptyString $normalizedRunRoot)) {
        return [pscustomobject]@{
            Exists                    = $false
            RunRoot                   = ''
            Status                    = ''
            Reason                    = ''
            UpdatedAt                 = ''
            HeartbeatAt               = ''
            EffectiveAgeSeconds       = -1
            ForwardedCount            = 0
            ConfiguredMaxForwardCount = 0
        }
    }

    $watcherStatusPath = Join-Path $normalizedRunRoot '.state\watcher-status.json'
    if (-not (Test-Path -LiteralPath $watcherStatusPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists                    = $false
            RunRoot                   = $normalizedRunRoot
            Status                    = ''
            Reason                    = ''
            UpdatedAt                 = ''
            HeartbeatAt               = ''
            EffectiveAgeSeconds       = -1
            ForwardedCount            = 0
            ConfiguredMaxForwardCount = 0
        }
    }

    try {
        $statusDoc = Read-JsonObject -Path $watcherStatusPath
    }
    catch {
        return [pscustomobject]@{
            Exists                    = $false
            RunRoot                   = $normalizedRunRoot
            Status                    = ''
            Reason                    = ('watcher-status-parse-failed:' + $_.Exception.Message)
            UpdatedAt                 = ''
            HeartbeatAt               = ''
            EffectiveAgeSeconds       = -1
            ForwardedCount            = 0
            ConfiguredMaxForwardCount = 0
        }
    }

    $updatedAt = [string](Get-OptionalCommandFieldValue -Command $statusDoc -FieldName 'UpdatedAt')
    $heartbeatAt = [string](Get-OptionalCommandFieldValue -Command $statusDoc -FieldName 'HeartbeatAt')
    $heartbeatAgeSeconds = Get-IsoAgeSeconds -IsoTimestamp $heartbeatAt
    $updatedAgeSeconds = Get-IsoAgeSeconds -IsoTimestamp $updatedAt
    $effectiveAgeSeconds = if ($heartbeatAgeSeconds -ge 0) { $heartbeatAgeSeconds } else { $updatedAgeSeconds }

    return [pscustomobject]@{
        Exists                    = $true
        RunRoot                   = $normalizedRunRoot
        Status                    = [string](Get-OptionalCommandFieldValue -Command $statusDoc -FieldName 'State')
        Reason                    = [string](Get-OptionalCommandFieldValue -Command $statusDoc -FieldName 'Reason')
        UpdatedAt                 = $updatedAt
        HeartbeatAt               = $heartbeatAt
        EffectiveAgeSeconds       = $effectiveAgeSeconds
        ForwardedCount            = [int](Get-OptionalCommandFieldValue -Command $statusDoc -FieldName 'ForwardedCount')
        ConfiguredMaxForwardCount = [int](Get-OptionalCommandFieldValue -Command $statusDoc -FieldName 'ConfiguredMaxForwardCount')
    }
}

function Get-RunRootProtection {
    param(
        [string]$RunRoot,
        [int]$StaleAgeSeconds = 300
    )

    $watcherSnapshot = Get-RunWatcherSnapshot -RunRoot $RunRoot
    if (-not [bool]$watcherSnapshot.Exists) {
        return [pscustomobject]@{
            Protected = $false
            Reason    = ''
        }
    }

    $protectionAgeThresholdSeconds = [math]::Max(60, $StaleAgeSeconds)
    if ([int]$watcherSnapshot.EffectiveAgeSeconds -gt $protectionAgeThresholdSeconds) {
        return [pscustomobject]@{
            Protected = $false
            Reason    = ('watcher-status-stale ageSeconds=' + [int]$watcherSnapshot.EffectiveAgeSeconds)
        }
    }

    if ([string]$watcherSnapshot.Status -ne 'stopped') {
        return [pscustomobject]@{
            Protected = $true
            Reason    = ('protected-active-run status=' + [string]$watcherSnapshot.Status)
        }
    }

    if (
        [int]$watcherSnapshot.ConfiguredMaxForwardCount -gt 0 -and
        [int]$watcherSnapshot.ForwardedCount -lt [int]$watcherSnapshot.ConfiguredMaxForwardCount
    ) {
        return [pscustomobject]@{
            Protected = $true
            Reason    = ('protected-incomplete-closeout forwarded=' + [int]$watcherSnapshot.ForwardedCount + ' target=' + [int]$watcherSnapshot.ConfiguredMaxForwardCount)
        }
    }

    return [pscustomobject]@{
        Protected = $false
        Reason    = ''
    }
}

function Save-CleanupWorkerStatus {
    param(
        [Parameter(Mandatory)][string]$StatusPath,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$Reason,
        $ExistingStatus = $null
    )

    $payload = [ordered]@{
        SchemaVersion         = '1.0.0'
        TargetId              = $TargetKey
        WorkerPid             = 0
        State                 = 'stopped'
        CurrentCommandId      = ''
        CurrentRunRoot        = ''
        CurrentPromptFilePath = ''
        Reason                = $Reason
        StdOutLogPath         = if ($null -ne $ExistingStatus) { [string]$ExistingStatus.StdOutLogPath } else { '' }
        StdErrLogPath         = if ($null -ne $ExistingStatus) { [string]$ExistingStatus.StdErrLogPath } else { '' }
        LastCommandId         = if ($null -ne $ExistingStatus) { [string]$ExistingStatus.LastCommandId } else { '' }
        LastCompletedAt       = if ($null -ne $ExistingStatus) { [string]$ExistingStatus.LastCompletedAt } else { '' }
        LastFailedAt          = if ($null -ne $ExistingStatus) { [string]$ExistingStatus.LastFailedAt } else { '' }
        UpdatedAt             = (Get-Date).ToString('o')
    }

    Write-JsonFileAtomically -Path $StatusPath -Payload $payload
}

function Classify-CommandItem {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Bucket,
        [Parameter(Mandatory)][string]$TargetKey,
        [string]$KeepRunRoot,
        [Parameter(Mandatory)]$WorkerSnapshot,
        [int]$StaleAgeSeconds = 300
    )

    $command = $null
    $parseError = ''
    try {
        $command = Read-JsonObject -Path $Item.FullName
    }
    catch {
        $parseError = $_.Exception.Message
    }

    if (Test-NonEmptyString $parseError) {
        return [pscustomobject]@{
            Action       = 'archive-invalid'
            ReasonDetail = $parseError
            Command      = $null
            ParseError   = $parseError
        }
    }

    $required = Test-RequiredCommandFieldSet -Command $command
    if (-not [bool]$required.Passed) {
        return [pscustomobject]@{
            Action       = 'archive-invalid'
            ReasonDetail = ('missing-fields:' + (@($required.MissingFields) -join ','))
            Command      = $command
            ParseError   = ''
        }
    }

    if ([string]$command.TargetId -ne $TargetKey) {
        return [pscustomobject]@{
            Action       = 'archive-invalid'
            ReasonDetail = ('target-mismatch:' + [string]$command.TargetId)
            Command      = $command
            ParseError   = ''
        }
    }

    $normalizedKeepRunRoot = Get-NormalizedPath -PathValue $KeepRunRoot
    $normalizedCommandRunRoot = Get-NormalizedPath -PathValue ([string]$command.RunRoot)
    $runProtection = Get-RunRootProtection -RunRoot $normalizedCommandRunRoot -StaleAgeSeconds $StaleAgeSeconds
    if ([bool]$runProtection.Protected) {
        return [pscustomobject]@{
            Action       = 'keep-protected-run'
            ReasonDetail = [string]$runProtection.Reason
            Command      = $command
            ParseError   = ''
        }
    }

    if ((Test-NonEmptyString $normalizedKeepRunRoot) -and -not (Test-SameNormalizedPath -Left $normalizedCommandRunRoot -Right $normalizedKeepRunRoot)) {
        return [pscustomobject]@{
            Action       = 'archive-foreign'
            ReasonDetail = ('foreign-run-root:' + [string]$command.RunRoot)
            Command      = $command
            ParseError   = ''
        }
    }

    if ($Bucket -eq 'processing') {
        $isCurrentActiveCommand =
            [bool]$WorkerSnapshot.WorkerAlive -and
            [string]$WorkerSnapshot.Status -in @('running', 'waiting-for-dispatch-slot', 'accepted', 'paused') -and
            ([string]$WorkerSnapshot.CurrentCommandId -eq [string]$command.CommandId) -and
            (Test-SameNormalizedPath -Left (Get-NormalizedPath -PathValue ([string]$WorkerSnapshot.CurrentRunRoot)) -Right $normalizedCommandRunRoot)

        if ($isCurrentActiveCommand) {
            if (-not [bool]$runProtection.Protected) {
                return [pscustomobject]@{
                    Action       = 'archive-stale'
                    ReasonDetail = 'active-current-worker-command-with-inactive-run'
                    Command      = $command
                    ParseError   = ''
                }
            }

            return [pscustomobject]@{
                Action       = 'keep-same-run'
                ReasonDetail = 'active-current-worker-command'
                Command      = $command
                ParseError   = ''
            }
        }

        $ageSeconds = [math]::Max(0, [int][math]::Round(((Get-Date).ToUniversalTime() - $Item.LastWriteTimeUtc).TotalSeconds))
        if ((-not [bool]$WorkerSnapshot.WorkerAlive) -or $ageSeconds -ge [math]::Max(1, $StaleAgeSeconds)) {
            return [pscustomobject]@{
                Action       = 'archive-stale'
                ReasonDetail = ('stale-processing ageSeconds=' + $ageSeconds)
                Command      = $command
                ParseError   = ''
            }
        }
    }

    return [pscustomobject]@{
        Action       = 'keep-same-run'
        ReasonDetail = 'preserved'
        Command      = $command
        ParseError   = ''
    }
}

function Invoke-ArchiveCommandItem {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$ArchiveRoot,
        [Parameter(Mandatory)][string]$ReasonCode,
        [Parameter(Mandatory)][string]$ReasonDetail,
        [Parameter(Mandatory)][string]$TargetKey,
        [string]$KeepRunRoot,
        $Command = $null,
        [switch]$Apply
    )

    $reasonRoot = Join-Path $ArchiveRoot $ReasonCode
    $destinationPath = Join-Path $reasonRoot $Item.Name
    $metadataPath = ($destinationPath + '.cleanup.json')

    $metadata = [ordered]@{
        SchemaVersion = '1.0.0'
        TargetId = $TargetKey
        ArchivedAt = (Get-Date).ToString('o')
        ReasonCode = $ReasonCode
        ReasonDetail = $ReasonDetail
        SourcePath = $Item.FullName
        ArchivedPath = $destinationPath
        KeepRunRoot = $KeepRunRoot
        OriginalBucket = Split-Path -Leaf (Split-Path -Parent $Item.FullName)
        CommandId = Get-OptionalCommandFieldValue -Command $Command -FieldName 'CommandId'
        RunRoot = Get-OptionalCommandFieldValue -Command $Command -FieldName 'RunRoot'
        PromptFilePath = Get-OptionalCommandFieldValue -Command $Command -FieldName 'PromptFilePath'
        DryRun = (-not $Apply.IsPresent)
    }

    if ($Apply.IsPresent) {
        Ensure-Directory -Path $reasonRoot
        Move-Item -LiteralPath $Item.FullName -Destination $destinationPath -Force
        Write-JsonFileAtomically -Path $metadataPath -Payload $metadata
    }

    return [pscustomobject]@{
        ReasonCode = $ReasonCode
        ReasonDetail = $ReasonDetail
        SourcePath = $Item.FullName
        ArchivedPath = $destinationPath
        MetadataPath = $metadataPath
        Applied = [bool]$Apply.IsPresent
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
if (-not [bool]$pairTest.VisibleWorker.Enabled) {
    throw "visible worker is not enabled for config: $resolvedConfigPath"
}

$resolvedKeepRunRoot = if (Test-NonEmptyString $KeepRunRoot) { (Resolve-Path -LiteralPath $KeepRunRoot).Path } else { '' }
$targetIds = if ($null -ne $TargetId -and @($TargetId).Count -gt 0) {
    @($TargetId | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)
}
else {
    @($config.Targets | ForEach-Object { [string]$_.Id } | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)
}

$targetResults = foreach ($targetKey in $targetIds) {
    $queueRoot = Join-Path ([string]$pairTest.VisibleWorker.QueueRoot) $targetKey
    $archiveRoot = Join-Path $queueRoot 'archive'
    $workerSnapshot = Get-WorkerSnapshot -PairTest $pairTest -TargetKey $targetKey
    $items = New-Object System.Collections.Generic.List[object]
    $releasedRunningState = $false
    $releasedRunningStateReason = ''
    $stoppedWorkerProcess = $false
    $stoppedWorkerProcessId = 0
    $stoppedWorkerProcessReason = ''

    foreach ($bucket in @('queued', 'processing')) {
        $bucketRoot = Join-Path $queueRoot $bucket
        if (-not (Test-Path -LiteralPath $bucketRoot -PathType Container)) {
            continue
        }

        $files = @(
            Get-ChildItem -LiteralPath $bucketRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc, Name
        )
        foreach ($file in $files) {
            $classification = Classify-CommandItem `
                -Item $file `
                -Bucket $bucket `
                -TargetKey $targetKey `
                -KeepRunRoot $resolvedKeepRunRoot `
                -WorkerSnapshot $workerSnapshot `
                -StaleAgeSeconds $StaleAgeSeconds

            $archiveResult = $null
            if ([string]$classification.Action -notin @('keep-same-run', 'keep-protected-run')) {
                $archiveResult = Invoke-ArchiveCommandItem `
                    -Item $file `
                    -ArchiveRoot $archiveRoot `
                    -ReasonCode ([string]$classification.Action) `
                    -ReasonDetail ([string]$classification.ReasonDetail) `
                    -TargetKey $targetKey `
                    -KeepRunRoot $resolvedKeepRunRoot `
                    -Command $classification.Command `
                    -Apply:$Apply
            }

            $items.Add([pscustomobject]@{
                TargetId = $targetKey
                Bucket = $bucket
                Name = $file.Name
                SourcePath = $file.FullName
                Action = [string]$classification.Action
                ReasonDetail = [string]$classification.ReasonDetail
                CommandId = Get-OptionalCommandFieldValue -Command $classification.Command -FieldName 'CommandId'
                RunRoot = Get-OptionalCommandFieldValue -Command $classification.Command -FieldName 'RunRoot'
                Archive = $archiveResult
            })
        }
    }

    $activeArchivedItem = @(
        $items |
            Where-Object {
                ([string]$_.Action -notin @('keep-same-run', 'keep-protected-run')) -and
                (Test-NonEmptyString ([string]$_.CommandId)) -and
                ([string]$_.CommandId -eq [string]$workerSnapshot.CurrentCommandId)
            } |
            Select-Object -First 1
    )
    if ($Apply -and [bool]$workerSnapshot.WorkerAlive -and @($activeArchivedItem).Count -gt 0) {
        Stop-ProcessTree -ProcessId ([int]$workerSnapshot.WorkerPid)
        $stoppedWorkerProcess = $true
        $stoppedWorkerProcessId = [int]$workerSnapshot.WorkerPid
        $stoppedWorkerProcessReason = ('cleanup-stopped-active-worker-for-' + [string]$activeArchivedItem[0].Action)
        Start-Sleep -Milliseconds 300
        $workerSnapshot = Get-WorkerSnapshot -PairTest $pairTest -TargetKey $targetKey
    }

    if ($Apply -and ((-not [bool]$workerSnapshot.WorkerAlive) -or $stoppedWorkerProcess)) {
        $remainingQueued = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'queued') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        $remainingProcessing = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'processing') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        if ($remainingProcessing -eq 0 -and [string]$workerSnapshot.Status -in @('running', 'waiting-for-dispatch-slot', 'accepted', 'paused')) {
            $releasedRunningState = $true
            if (-not (Test-NonEmptyString $releasedRunningStateReason)) {
                $releasedRunningStateReason = if ($stoppedWorkerProcess) { $stoppedWorkerProcessReason } else { 'cleanup-cleared-stale-worker-state' }
            }
            Save-CleanupWorkerStatus `
                -StatusPath $workerSnapshot.StatusPath `
                -TargetKey $targetKey `
                -Reason $releasedRunningStateReason `
                -ExistingStatus $workerSnapshot.Document
            $workerSnapshot = Get-WorkerSnapshot -PairTest $pairTest -TargetKey $targetKey
        }
    }

    $keptCount = @($items | Where-Object { [string]$_.Action -in @('keep-same-run', 'keep-protected-run') }).Count
    $archivedCount = @($items | Where-Object { [string]$_.Action -notin @('keep-same-run', 'keep-protected-run') }).Count

    [pscustomobject]@{
        TargetId = $targetKey
        QueueRoot = $queueRoot
        ArchiveRoot = $archiveRoot
        WorkerStatus = [pscustomobject]@{
            StatusPath = $workerSnapshot.StatusPath
            Exists = [bool]$workerSnapshot.Exists
            WorkerPid = [int]$workerSnapshot.WorkerPid
            WorkerAlive = [bool]$workerSnapshot.WorkerAlive
            State = [string]$workerSnapshot.Status
            CurrentCommandId = [string]$workerSnapshot.CurrentCommandId
            CurrentRunRoot = [string]$workerSnapshot.CurrentRunRoot
            Reason = [string]$workerSnapshot.Reason
        }
        Counts = [pscustomobject]@{
            Kept = $keptCount
            Archived = $archivedCount
            Foreign = @($items | Where-Object { [string]$_.Action -eq 'archive-foreign' }).Count
            Invalid = @($items | Where-Object { [string]$_.Action -eq 'archive-invalid' }).Count
            Stale = @($items | Where-Object { [string]$_.Action -eq 'archive-stale' }).Count
            ForeignArchived = @($items | Where-Object { [string]$_.Action -eq 'archive-foreign' }).Count
            InvalidMetadataArchived = @($items | Where-Object { [string]$_.Action -eq 'archive-invalid' }).Count
            StaleProcessingReclaimed = @($items | Where-Object { [string]$_.Action -eq 'archive-stale' }).Count
            KeptSameRun = $keptCount
            ProtectedRunKept = @($items | Where-Object { [string]$_.Action -eq 'keep-protected-run' }).Count
        }
        Cleanup = [pscustomobject]@{
            DryRun = (-not [bool]$Apply)
            ReleasedRunningState = $releasedRunningState
            ReleasedRunningStateReason = $releasedRunningStateReason
            StoppedWorkerProcess = $stoppedWorkerProcess
            StoppedWorkerProcessId = $stoppedWorkerProcessId
            StoppedWorkerProcessReason = $stoppedWorkerProcessReason
        }
        Items = [object[]]$items.ToArray()
    }
}

$payload = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = (Get-Date).ToString('o')
    ConfigPath = $resolvedConfigPath
    KeepRunRoot = $resolvedKeepRunRoot
    StaleAgeSeconds = $StaleAgeSeconds
    Apply = [bool]$Apply
    Targets = @($targetResults)
    Summary = [pscustomobject]@{
        TargetCount = @($targetResults).Count
        ArchivedCount = (@($targetResults | ForEach-Object { [int]$_.Counts.Archived } | Measure-Object -Sum).Sum)
        ForeignCount = (@($targetResults | ForEach-Object { [int]$_.Counts.Foreign } | Measure-Object -Sum).Sum)
        InvalidCount = (@($targetResults | ForEach-Object { [int]$_.Counts.Invalid } | Measure-Object -Sum).Sum)
        StaleCount = (@($targetResults | ForEach-Object { [int]$_.Counts.Stale } | Measure-Object -Sum).Sum)
        KeptCount = (@($targetResults | ForEach-Object { [int]$_.Counts.Kept } | Measure-Object -Sum).Sum)
        ForeignArchivedCount = (@($targetResults | ForEach-Object { [int]$_.Counts.ForeignArchived } | Measure-Object -Sum).Sum)
        InvalidMetadataArchivedCount = (@($targetResults | ForEach-Object { [int]$_.Counts.InvalidMetadataArchived } | Measure-Object -Sum).Sum)
        StaleProcessingReclaimedCount = (@($targetResults | ForEach-Object { [int]$_.Counts.StaleProcessingReclaimed } | Measure-Object -Sum).Sum)
        KeptSameRunCount = (@($targetResults | ForEach-Object { [int]$_.Counts.KeptSameRun } | Measure-Object -Sum).Sum)
        ProtectedRunCount = (@($targetResults | ForEach-Object { [int]$_.Counts.ProtectedRunKept } | Measure-Object -Sum).Sum)
        ReleasedRunningStateCount = (@($targetResults | ForEach-Object { if ([bool]$_.Cleanup.ReleasedRunningState) { 1 } else { 0 } } | Measure-Object -Sum).Sum)
        StoppedWorkerProcessCount = (@($targetResults | ForEach-Object { if ([bool]$_.Cleanup.StoppedWorkerProcess) { 1 } else { 0 } } | Measure-Object -Sum).Sum)
        DryRun = (-not [bool]$Apply)
    }
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
}
else {
    $payload
}
