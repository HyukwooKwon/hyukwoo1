[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [string]$TargetId,
    [string]$MessageTextFilePath,
    [int]$MaxAttempts = 3,
    [int]$DelaySeconds = 5,
    [int[]]$RetryBackoffMs = @(),
    [int]$WaitForRouterSeconds = 20,
    [int]$WaitForPublishSeconds = 0,
    [switch]$DisallowInlineTypedWindowPrepare,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-ConfigValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
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

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

function Get-IntegerArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = @()
    if ($Value -is [System.Array]) {
        $items = @($Value)
    }
    else {
        $items = @($Value)
    }

    $result = New-Object System.Collections.Generic.List[int]
    foreach ($item in $items) {
        if ($null -eq $item) {
            continue
        }

        $text = [string]$item
        if (-not (Test-NonEmptyString $text)) {
            continue
        }

        $parsed = 0
        if ([int]::TryParse($text, [ref]$parsed) -and $parsed -gt 0) {
            $result.Add($parsed)
        }
    }

    return @($result)
}

function Import-ConfigDataFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $importCommand = Get-Command -Name Import-PowerShellDataFile -ErrorAction SilentlyContinue
    if ($null -ne $importCommand) {
        return Import-PowerShellDataFile -Path $resolvedPath
    }

    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
    return [scriptblock]::Create($raw).InvokeReturnAsIs()
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }

    return ($raw | ConvertFrom-Json)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Get-TypedWindowSessionRoot {
    param([Parameter(Mandatory)]$Config)

    $runtimeRoot = [string](Get-ConfigValue -Object $Config -Name 'RuntimeRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $runtimeRoot)) {
        $runtimeRoot = Join-Path $root 'runtime\bottest-live-visible'
    }

    $sessionRoot = Join-Path $runtimeRoot 'typed-window-session'
    Ensure-Directory -Path $sessionRoot
    return $sessionRoot
}

function Get-TypedWindowSessionStatePath {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey
    )

    return (Join-Path (Get-TypedWindowSessionRoot -Config $Config) ($TargetKey + '.json'))
}

function New-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)][string]$TargetKey,
        [string]$State = 'bootstrap-needed',
        [string]$RunRoot = '',
        [string]$PairId = '',
        [string]$ResetReason = ''
    )

    return [ordered]@{
        SchemaVersion                   = '1.0.0'
        TargetId                        = $TargetKey
        State                           = $State
        SessionRunRoot                  = $RunRoot
        SessionPairId                   = $PairId
        SessionTargetId                 = $TargetKey
        SessionEpoch                    = 0
        LastPrepareAt                   = ''
        LastSubmitAt                    = ''
        LastProgressAt                  = ''
        LastConfirmedArtifactAt         = ''
        LastResetReason                 = $ResetReason
        ConsecutiveSubmitUnconfirmedCount = 0
        UpdatedAt                       = (Get-Date).ToString('o')
    }
}

function Read-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $path = Get-TypedWindowSessionStatePath -Config $Config -TargetKey $TargetKey
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject](New-TypedWindowSessionState -TargetKey $TargetKey)
    }

    try {
        $session = Read-JsonObject -Path $path
        return [pscustomobject]@{
            SchemaVersion                     = [string](Get-ConfigValue -Object $session -Name 'SchemaVersion' -DefaultValue '1.0.0')
            TargetId                          = [string](Get-ConfigValue -Object $session -Name 'TargetId' -DefaultValue $TargetKey)
            State                             = [string](Get-ConfigValue -Object $session -Name 'State' -DefaultValue 'bootstrap-needed')
            SessionRunRoot                    = [string](Get-ConfigValue -Object $session -Name 'SessionRunRoot' -DefaultValue '')
            SessionPairId                     = [string](Get-ConfigValue -Object $session -Name 'SessionPairId' -DefaultValue '')
            SessionTargetId                   = [string](Get-ConfigValue -Object $session -Name 'SessionTargetId' -DefaultValue $TargetKey)
            SessionEpoch                      = [int](Get-ConfigValue -Object $session -Name 'SessionEpoch' -DefaultValue 0)
            LastPrepareAt                     = [string](Get-ConfigValue -Object $session -Name 'LastPrepareAt' -DefaultValue '')
            LastSubmitAt                      = [string](Get-ConfigValue -Object $session -Name 'LastSubmitAt' -DefaultValue '')
            LastProgressAt                    = [string](Get-ConfigValue -Object $session -Name 'LastProgressAt' -DefaultValue '')
            LastConfirmedArtifactAt           = [string](Get-ConfigValue -Object $session -Name 'LastConfirmedArtifactAt' -DefaultValue '')
            LastResetReason                   = [string](Get-ConfigValue -Object $session -Name 'LastResetReason' -DefaultValue '')
            ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $session -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0)
            UpdatedAt                         = [string](Get-ConfigValue -Object $session -Name 'UpdatedAt' -DefaultValue '')
        }
    }
    catch {
        return [pscustomobject](New-TypedWindowSessionState -TargetKey $TargetKey -State 'dirty-session' -ResetReason 'session-parse-failed')
    }
}

function Save-TypedWindowSessionState {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)]$Session
    )

    $path = Get-TypedWindowSessionStatePath -Config $Config -TargetKey $TargetKey
    $payload = [ordered]@{
        SchemaVersion                     = '1.0.0'
        TargetId                          = $TargetKey
        State                             = [string](Get-ConfigValue -Object $Session -Name 'State' -DefaultValue 'bootstrap-needed')
        SessionRunRoot                    = [string](Get-ConfigValue -Object $Session -Name 'SessionRunRoot' -DefaultValue '')
        SessionPairId                     = [string](Get-ConfigValue -Object $Session -Name 'SessionPairId' -DefaultValue '')
        SessionTargetId                   = [string](Get-ConfigValue -Object $Session -Name 'SessionTargetId' -DefaultValue $TargetKey)
        SessionEpoch                      = [int](Get-ConfigValue -Object $Session -Name 'SessionEpoch' -DefaultValue 0)
        LastPrepareAt                     = [string](Get-ConfigValue -Object $Session -Name 'LastPrepareAt' -DefaultValue '')
        LastSubmitAt                      = [string](Get-ConfigValue -Object $Session -Name 'LastSubmitAt' -DefaultValue '')
        LastProgressAt                    = [string](Get-ConfigValue -Object $Session -Name 'LastProgressAt' -DefaultValue '')
        LastConfirmedArtifactAt           = [string](Get-ConfigValue -Object $Session -Name 'LastConfirmedArtifactAt' -DefaultValue '')
        LastResetReason                   = [string](Get-ConfigValue -Object $Session -Name 'LastResetReason' -DefaultValue '')
        ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $Session -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0)
        UpdatedAt                         = (Get-Date).ToString('o')
    }

    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Set-TypedWindowSessionFields {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$State
    )

    $Session.State = $State
    $Session.UpdatedAt = (Get-Date).ToString('o')
    return $Session
}

function Test-ProcessAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return ($null -ne $process -and -not $process.HasExited)
    }
    catch {
        return $false
    }
}

function Load-SeedSendStatusState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{}
    }

    $doc = Read-JsonObject -Path $Path
    $state = @{}
    foreach ($row in @($doc.Targets)) {
        $targetId = [string]$row.TargetId
        if (Test-NonEmptyString $targetId) {
            $state[$targetId] = $row
        }
    }

    return $state
}

function Save-SeedSendStatusState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][hashtable]$State
    )

    $payload = [ordered]@{
        SchemaVersion = '1.0.0'
        RunRoot = $RunRoot
        UpdatedAt = (Get-Date).ToString('o')
        Targets = @(
            $State.Keys | Sort-Object | ForEach-Object { $State[[string]$_] }
        )
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-RetryPendingMetadataPath {
    param([Parameter(Mandatory)][string]$RetryPendingPath)

    return ($RetryPendingPath + '.meta.json')
}

function Read-RetryPendingMetadata {
    param([string]$RetryPendingPath)

    if (-not (Test-NonEmptyString $RetryPendingPath)) {
        return $null
    }

    $metadataPath = Get-RetryPendingMetadataPath -RetryPendingPath $RetryPendingPath
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Read-JsonObject -Path $metadataPath)
    }
    catch {
        return $null
    }
}

function Remove-RetryPendingMetadata {
    param([string]$RetryPendingPath)

    if (-not (Test-NonEmptyString $RetryPendingPath)) {
        return
    }

    $metadataPath = Get-RetryPendingMetadataPath -RetryPendingPath $RetryPendingPath
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RetryBackoffMilliseconds {
    param(
        [int]$AttemptNumber,
        [int[]]$BackoffScheduleMs = @(),
        [int]$FallbackDelaySeconds = 5
    )

    $schedule = @($BackoffScheduleMs | Where-Object { [int]$_ -gt 0 })
    if ($schedule.Count -eq 0) {
        return ([math]::Max(1, $FallbackDelaySeconds) * 1000)
    }

    $index = [math]::Max(0, $AttemptNumber - 1)
    if ($index -ge $schedule.Count) {
        return [int]$schedule[-1]
    }

    return [int]$schedule[$index]
}

function Get-UserIdleMilliseconds {
    if (-not ('HyukwooPairUserIdle' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HyukwooPairUserIdle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static uint GetIdleMilliseconds() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) {
            return 0;
        }

        return unchecked((uint)Environment.TickCount - info.dwTime);
    }
}
'@
    }

    return [int][HyukwooPairUserIdle]::GetIdleMilliseconds()
}

function Wait-ForUserIdle {
    param(
        [int]$RequiredIdleMs = 0,
        [int]$TimeoutSeconds = 0
    )

    $result = [ordered]@{
        Satisfied = $true
        TimedOut = $false
        LastIdleMs = 0
        WaitedMs = 0
    }

    if ($RequiredIdleMs -le 0 -or $TimeoutSeconds -le 0) {
        $result.LastIdleMs = Get-UserIdleMilliseconds
        return [pscustomobject]$result
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))

    while ((Get-Date) -lt $deadline) {
        $idleMs = Get-UserIdleMilliseconds
        $result.LastIdleMs = $idleMs
        $result.WaitedMs = [int]$stopwatch.ElapsedMilliseconds
        if ($idleMs -ge $RequiredIdleMs) {
            return [pscustomobject]$result
        }

        Start-Sleep -Milliseconds 500
    }

    $result.Satisfied = $false
    $result.TimedOut = $true
    $result.LastIdleMs = Get-UserIdleMilliseconds
    $result.WaitedMs = [int]$stopwatch.ElapsedMilliseconds
    return [pscustomobject]$result
}

function Set-SeedSendStatusEntry {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$UpdatedAt,
        [Parameter(Mandatory)][string]$FinalState,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExecutionPathMode,
        [Parameter(Mandatory)][bool]$UserVisibleCellExecutionRequired,
        [Parameter(Mandatory)][string[]]$AllowedWindowVisibilityMethods,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RouterDispatchState,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubmitState,
        [Parameter(Mandatory)][bool]$SubmitConfirmed,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubmitReason,
        [Parameter(Mandatory)][string[]]$SubmitRetryModes,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubmitRetrySequenceSummary,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrimarySubmitMode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FinalSubmitMode,
        [Parameter(Mandatory)][int]$SubmitRetryIntervalMs,
        [Parameter(Mandatory)][int]$AttemptCount,
        [Parameter(Mandatory)][int]$MaxAttempts,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FirstAttemptedAt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LastAttemptedAt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NextRetryAt,
        [Parameter(Mandatory)][int]$BackoffMs,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RetryReason,
        [Parameter(Mandatory)][bool]$ManualAttentionRequired,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProcessedPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProcessedAt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FailedPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FailedAt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RetryPendingPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RetryPendingAt,
        [Parameter(Mandatory)][bool]$OutboxPublished,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutboxObservedAt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LastReadyPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LastReadyBaseName,
        [AllowEmptyString()][string]$TypedWindowExecutionState = '',
        [AllowEmptyString()][string]$SubmitProbeState = '',
        [int]$SubmitProbeElapsedSeconds = 0,
        [int]$SubmitRetryCount = 0,
        [AllowEmptyString()][string]$SubmitConfirmationSignal = '',
        [AllowEmptyString()][string]$TypedWindowSessionState = '',
        [AllowEmptyString()][string]$TypedWindowLastResetReason = ''
    )

    $State[$TargetKey] = [pscustomobject]@{
        TargetId = $TargetKey
        UpdatedAt = $UpdatedAt
        FinalState = $FinalState
        ExecutionPathMode = $ExecutionPathMode
        UserVisibleCellExecutionRequired = $UserVisibleCellExecutionRequired
        AllowedWindowVisibilityMethods = @($AllowedWindowVisibilityMethods)
        RouterDispatchState = $RouterDispatchState
        SubmitState = $SubmitState
        SubmitConfirmed = $SubmitConfirmed
        SubmitReason = $SubmitReason
        SubmitRetryModes = @($SubmitRetryModes)
        SubmitRetrySequenceSummary = $SubmitRetrySequenceSummary
        PrimarySubmitMode = $PrimarySubmitMode
        FinalSubmitMode = $FinalSubmitMode
        SubmitRetryIntervalMs = $SubmitRetryIntervalMs
        AttemptCount = $AttemptCount
        MaxAttempts = $MaxAttempts
        FirstAttemptedAt = $FirstAttemptedAt
        LastAttemptedAt = $LastAttemptedAt
        NextRetryAt = $NextRetryAt
        BackoffMs = $BackoffMs
        RetryReason = $RetryReason
        ManualAttentionRequired = $ManualAttentionRequired
        ProcessedPath = $ProcessedPath
        ProcessedAt = $ProcessedAt
        FailedPath = $FailedPath
        FailedAt = $FailedAt
        RetryPendingPath = $RetryPendingPath
        RetryPendingAt = $RetryPendingAt
        OutboxPublished = $OutboxPublished
        OutboxObservedAt = $OutboxObservedAt
        LastReadyPath = $LastReadyPath
        LastReadyBaseName = $LastReadyBaseName
        TypedWindowExecutionState = $TypedWindowExecutionState
        SubmitProbeState = $SubmitProbeState
        SubmitProbeElapsedSeconds = $SubmitProbeElapsedSeconds
        SubmitRetryCount = $SubmitRetryCount
        SubmitConfirmationSignal = $SubmitConfirmationSignal
        TypedWindowSessionState = $TypedWindowSessionState
        TypedWindowLastResetReason = $TypedWindowLastResetReason
    }
}

function Resolve-TargetManifestRow {
    param(
        [Parameter(Mandatory)]$Manifest,
        [string]$TargetId
    )

    $targets = @($Manifest.Targets)
    if ($targets.Count -eq 0) {
        throw 'manifest contains no targets'
    }

    $requestedTargetId = [string]$TargetId
    if (-not (Test-NonEmptyString $requestedTargetId)) {
        $seedTarget = @($Manifest.SeedTargetIds | Where-Object { Test-NonEmptyString $_ } | Select-Object -First 1)
        if ($seedTarget.Count -ge 1) {
            $requestedTargetId = [string]$seedTarget[0]
        }
    }
    if (-not (Test-NonEmptyString $requestedTargetId)) {
        $seedRow = @(
            $targets |
                Where-Object { ($_.SeedEnabled -eq $true) -or ([string]$_.InitialRoleMode -eq 'seed') } |
                Select-Object -First 1
        )
        if ($seedRow.Count -ge 1) {
            $requestedTargetId = [string]$seedRow[0].TargetId
        }
    }
    if (-not (Test-NonEmptyString $requestedTargetId)) {
        throw 'no seed target could be resolved from manifest'
    }

    $row = @($targets | Where-Object { [string]$_.TargetId -eq $requestedTargetId } | Select-Object -First 1)
    if ($row.Count -eq 0) {
        throw "target not found in manifest: $requestedTargetId"
    }

    return $row[0]
}

function Find-ArchivedMessage {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$BaseName
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    $items = @(
        Get-ChildItem -LiteralPath $Root -Filter ('*__' + $BaseName) -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
    )
    if ($items.Count -eq 0) {
        return $null
    }

    return $items[0]
}

function Wait-ForMessageTransition {
    param(
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$InboxRoot,
        [Parameter(Mandatory)][string]$ProcessedRoot,
        [Parameter(Mandatory)][string]$FailedRoot,
        [Parameter(Mandatory)][string]$RetryPendingRoot,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $processed = Find-ArchivedMessage -Root $ProcessedRoot -BaseName $BaseName
        if ($null -ne $processed) {
            return [pscustomobject]@{
                State = 'processed'
                Path  = $processed.FullName
            }
        }

        $failed = Find-ArchivedMessage -Root $FailedRoot -BaseName $BaseName
        if ($null -ne $failed) {
            return [pscustomobject]@{
                State = 'failed'
                Path  = $failed.FullName
            }
        }

        $retry = Find-ArchivedMessage -Root $RetryPendingRoot -BaseName $BaseName
        if ($null -ne $retry) {
            return [pscustomobject]@{
                State = 'retry-pending'
                Path  = $retry.FullName
            }
        }

        $inboxItems = @(
            Get-ChildItem -LiteralPath $InboxRoot -Filter $BaseName -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
        )
        $inbox = if ($inboxItems.Count -ge 1) { $inboxItems[0] } else { $null }
        if ($null -ne $inbox) {
            Start-Sleep -Milliseconds 500
            continue
        }

        Start-Sleep -Milliseconds 500
    }

    return [pscustomobject]@{
        State = 'timeout'
        Path  = ''
    }
}

function Move-RetryPendingMessageToInbox {
    param(
        [Parameter(Mandatory)][string]$RetryPendingPath,
        [Parameter(Mandatory)][string]$InboxRoot
    )

    if (-not (Test-Path -LiteralPath $RetryPendingPath -PathType Leaf)) {
        throw "retry-pending message not found: $RetryPendingPath"
    }

    if (-not (Test-Path -LiteralPath $InboxRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $InboxRoot -Force | Out-Null
    }

    $name = [System.IO.Path]::GetFileName($RetryPendingPath)
    $segments = $name -split '__', 3
    if ($segments.Count -lt 3) {
        throw "retry-pending message name is malformed: $name"
    }

    $destinationName = 'requeued_{0}__{1}__{2}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), [guid]::NewGuid().ToString('N'), $segments[2]
    $destinationPath = Join-Path $InboxRoot $destinationName
    $metadataPath = Get-RetryPendingMetadataPath -RetryPendingPath $RetryPendingPath
    $destinationMetadataPath = Get-RetryPendingMetadataPath -RetryPendingPath $destinationPath
    $deliveryMetadataPath = ($RetryPendingPath + '.delivery.json')
    $destinationDeliveryMetadataPath = ($destinationPath + '.delivery.json')
    Move-Item -LiteralPath $RetryPendingPath -Destination $destinationPath -Force
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        Move-Item -LiteralPath $metadataPath -Destination $destinationMetadataPath -Force
    }
    if (Test-Path -LiteralPath $deliveryMetadataPath -PathType Leaf) {
        Move-Item -LiteralPath $deliveryMetadataPath -Destination $destinationDeliveryMetadataPath -Force
    }
    return $destinationPath
}

function Wait-ForOutboxPublish {
    param(
        [Parameter(Mandatory)]$TargetRow,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [datetime]$ReferenceTime = [datetime]::MinValue
    )

    $deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { Get-Date }
    $summaryPath = [string]$TargetRow.SourceSummaryPath
    $reviewZipPath = [string]$TargetRow.SourceReviewZipPath
    $publishReadyPath = [string]$TargetRow.PublishReadyPath
    $publishedArchivePath = [string]$TargetRow.PublishedArchivePath
    do {
        $hasSummary = (Test-Path -LiteralPath $summaryPath -PathType Leaf)
        $hasReviewZip = (Test-Path -LiteralPath $reviewZipPath -PathType Leaf)
        if ((Test-Path -LiteralPath $summaryPath -PathType Leaf) -and
            (Test-Path -LiteralPath $reviewZipPath -PathType Leaf) -and
            (Test-Path -LiteralPath $publishReadyPath -PathType Leaf)) {
            return [pscustomobject]@{
                Published = $true
                SummaryPath = $summaryPath
                ReviewZipPath = $reviewZipPath
                PublishReadyPath = $publishReadyPath
            }
        }

        if ($hasSummary -and $hasReviewZip -and (Test-Path -LiteralPath $publishedArchivePath -PathType Container)) {
            $archiveItems = @(
                Get-ChildItem -LiteralPath $publishedArchivePath -Filter '*.ready.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc -Descending |
                    Select-Object -First 1
            )
            if ($archiveItems.Count -ge 1 -and $archiveItems[0].LastWriteTime -ge $ReferenceTime) {
                return [pscustomobject]@{
                    Published = $true
                    SummaryPath = $summaryPath
                    ReviewZipPath = $reviewZipPath
                    PublishReadyPath = $archiveItems[0].FullName
                }
            }
        }

        if ($TimeoutSeconds -le 0) {
            break
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Published = $false
        SummaryPath = $summaryPath
        ReviewZipPath = $reviewZipPath
        PublishReadyPath = $publishReadyPath
    }
}

function Get-TypedWindowRuntimeTarget {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey
    )

    $runtimeMapPath = [string](Get-ConfigValue -Object $Config -Name 'RuntimeMapPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $runtimeMapPath) -or -not (Test-Path -LiteralPath $runtimeMapPath -PathType Leaf)) {
        return $null
    }

    try {
        $runtimeDoc = Read-JsonObject -Path $runtimeMapPath
    }
    catch {
        return $null
    }

    $runtimeItems = if ($runtimeDoc -is [System.Array]) { @($runtimeDoc) } else { @($runtimeDoc) }
    $targetRow = @($runtimeItems | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') -eq $TargetKey } | Select-Object -First 1)
    if (@($targetRow).Count -eq 0) {
        return $null
    }

    return $targetRow[0]
}

function Get-ChildProcessIdsRecursive {
    param([int]$ParentPid)

    if ($ParentPid -le 0) {
        return @()
    }

    $result = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $seen = @{}
    $queue.Enqueue($ParentPid)
    $seen[$ParentPid] = $true

    while ($queue.Count -gt 0) {
        $currentPid = [int]$queue.Dequeue()
        $childRows = @()
        try {
            $childRows = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = {0}" -f $currentPid) -ErrorAction Stop)
        }
        catch {
            $childRows = @()
        }

        foreach ($childRow in @($childRows)) {
            $childPid = [int](Get-ConfigValue -Object $childRow -Name 'ProcessId' -DefaultValue 0)
            if ($childPid -le 0 -or $seen.ContainsKey($childPid)) {
                continue
            }

            $seen[$childPid] = $true
            $result.Add($childPid)
            $queue.Enqueue($childPid)
        }
    }

    return @($result)
}

function Get-ProcessCpuSecondsSum {
    param([int[]]$ProcessIds = @())

    $totalCpuSeconds = 0.0
    foreach ($processId in @($ProcessIds | Where-Object { [int]$_ -gt 0 })) {
        try {
            $process = Get-Process -Id ([int]$processId) -ErrorAction Stop
            if ($null -ne $process -and -not $process.HasExited -and $null -ne $process.CPU) {
                $totalCpuSeconds += [double]$process.CPU
            }
        }
        catch {
            continue
        }
    }

    return [math]::Round($totalCpuSeconds, 6)
}

function Get-TypedWindowProgressSnapshot {
    param(
        [Parameter(Mandatory)]$TargetRow,
        [int]$ShellPid = 0,
        [datetime]$ReferenceTime = [datetime]::MinValue
    )

    $trackedFiles = @(
        [pscustomobject]@{ Path = [string]$TargetRow.PublishReadyPath; Signal = 'publish-ready' },
        [pscustomobject]@{ Path = [string]$TargetRow.SourceSummaryPath; Signal = 'summary-updated' },
        [pscustomobject]@{ Path = [string]$TargetRow.SourceReviewZipPath; Signal = 'review-zip-updated' },
        [pscustomobject]@{ Path = [string](Get-ConfigValue -Object $TargetRow -Name 'ResultPath' -DefaultValue ''); Signal = 'result-updated' },
        [pscustomobject]@{ Path = [string](Get-ConfigValue -Object $TargetRow -Name 'DonePath' -DefaultValue ''); Signal = 'done-updated' }
    )

    $latestTicks = 0L
    $latestSignal = ''
    $latestPath = ''
    foreach ($trackedFile in @($trackedFiles)) {
        $trackedPath = [string]$trackedFile.Path
        if (-not (Test-NonEmptyString $trackedPath) -or -not (Test-Path -LiteralPath $trackedPath -PathType Leaf)) {
            continue
        }

        $item = Get-Item -LiteralPath $trackedPath -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            continue
        }

        if ($ReferenceTime -ne [datetime]::MinValue -and $item.LastWriteTime -lt $ReferenceTime) {
            continue
        }

        if ([int64]$item.LastWriteTimeUtc.Ticks -gt $latestTicks) {
            $latestTicks = [int64]$item.LastWriteTimeUtc.Ticks
            $latestSignal = [string]$trackedFile.Signal
            $latestPath = $trackedPath
        }
    }

    $childProcessIds = if ($ShellPid -gt 0) { @(Get-ChildProcessIdsRecursive -ParentPid $ShellPid) } else { @() }
    $cpuSeconds = Get-ProcessCpuSecondsSum -ProcessIds $childProcessIds

    return [pscustomobject]@{
        ShellPid = $ShellPid
        ChildProcessIds = @($childProcessIds)
        CpuSeconds = $cpuSeconds
        LatestArtifactTicks = $latestTicks
        LatestArtifactSignal = $latestSignal
        LatestArtifactPath = $latestPath
    }
}

function New-TypedWindowDebugLogPath {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$Label
    )

    $logsRoot = [string](Get-ConfigValue -Object $Config -Name 'LogsRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $logsRoot)) {
        $logsRoot = Join-Path $root '_tmp'
    }

    $debugRoot = Join-Path $logsRoot ('typed-window-prepare\' + $TargetKey)
    Ensure-Directory -Path $debugRoot
    return (Join-Path $debugRoot ((Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '__' + $Label + '.log'))
}

function Invoke-TypedWindowAhkPayload {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$Payload,
        [Parameter(Mandatory)][bool]$ClearInput,
        [Parameter(Mandatory)][string[]]$SubmitModes,
        [Parameter(Mandatory)][string]$DebugLabel
    )

    $ahkExePath = [string](Get-ConfigValue -Object $Config -Name 'AhkExePath' -DefaultValue '')
    $ahkScriptPath = [string](Get-ConfigValue -Object $Config -Name 'AhkScriptPath' -DefaultValue '')
    $runtimeMapPath = [string](Get-ConfigValue -Object $Config -Name 'RuntimeMapPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $ahkExePath) -or -not (Test-Path -LiteralPath $ahkExePath -PathType Leaf) -or -not (Test-NonEmptyString $ahkScriptPath) -or -not (Test-Path -LiteralPath $ahkScriptPath -PathType Leaf) -or -not (Test-NonEmptyString $runtimeMapPath) -or -not (Test-Path -LiteralPath $runtimeMapPath -PathType Leaf)) {
        return [pscustomobject]@{
            Executed = $false
            ExitCode = 0
            DebugLogPath = ''
            SkippedReason = 'typed-window-prepare-dependencies-missing'
        }
    }

    $payloadFile = Join-Path $stateRoot ('typed_window_payload_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($payloadFile, $Payload, (New-Utf8NoBomEncoding))
    $debugLogPath = New-TypedWindowDebugLogPath -Config $Config -TargetKey $TargetKey -Label $DebugLabel

    $activateSettleMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'ActivateSettleMs' -DefaultValue 250))
    $textSettleMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'TextSettleMs' -DefaultValue 2200))
    $terminalInputMode = [string](Get-ConfigValue -Object $Config -Name 'TerminalInputMode' -DefaultValue 'sendtext')
    if (-not (Test-NonEmptyString $terminalInputMode)) {
        $terminalInputMode = 'sendtext'
    }
    $submitGuardMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'SubmitGuardMs' -DefaultValue 0))
    $enterDelayMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'EnterDelayMs' -DefaultValue 900))
    $postSubmitDelayMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'PostSubmitDelayMs' -DefaultValue 900))
    $submitRetryIntervalMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'SubmitRetryIntervalMs' -DefaultValue 1800))
    $sendTimeoutMs = [math]::Max(1000, [int](Get-ConfigValue -Object $Config -Name 'SendTimeoutMs' -DefaultValue 5000))
    $requireActiveBeforeEnter = [bool](Get-ConfigValue -Object $Config -Name 'RequireActiveBeforeEnter' -DefaultValue $true)
    $resolverShellPath = [string](Get-ConfigValue -Object $Config -Name 'ResolverShellPath' -DefaultValue 'powershell.exe')
    $visibleBeaconEnabled = [bool](Get-ConfigValue -Object $Config -Name 'VisibleExecutionBeaconEnabled' -DefaultValue $false)
    $visiblePreHoldMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'VisibleExecutionPreHoldMs' -DefaultValue 0))
    $visiblePostHoldMs = [math]::Max(0, [int](Get-ConfigValue -Object $Config -Name 'VisibleExecutionPostHoldMs' -DefaultValue 0))
    $restorePreviousActive = [bool](Get-ConfigValue -Object $Config -Name 'VisibleExecutionRestorePreviousActive' -DefaultValue $true)
    $failOnFocusSteal = [bool](Get-ConfigValue -Object $Config -Name 'VisibleExecutionFailOnFocusSteal' -DefaultValue $false)
    $clearInputArg = if ($ClearInput) { '1' } else { '0' }
    $requireActiveBeforeEnterArg = if ($requireActiveBeforeEnter) { '1' } else { '0' }
    $visibleBeaconEnabledArg = if ($visibleBeaconEnabled) { '1' } else { '0' }
    $restorePreviousActiveArg = if ($restorePreviousActive) { '1' } else { '0' }
    $failOnFocusStealArg = if ($failOnFocusSteal) { '1' } else { '0' }

    try {
        $proc = Start-Process -FilePath $ahkExePath -ArgumentList @(
            $ahkScriptPath,
            '--runtime', $runtimeMapPath,
            '--targetId', $TargetKey,
            '--resolverShell', $resolverShellPath,
            '--file', $payloadFile,
            '--enter', '1',
            '--timeoutMs', [string]$sendTimeoutMs,
            '--activateSettleMs', [string]$activateSettleMs,
            '--textSettleMs', [string]$textSettleMs,
            '--inputMode', [string]$terminalInputMode,
            '--submitGuardMs', [string]$submitGuardMs,
            '--enterDelayMs', [string]$enterDelayMs,
            '--postSubmitDelayMs', [string]$postSubmitDelayMs,
            '--submitModes', ([string]::Join(',', @($SubmitModes))),
            '--submitRetryIntervalMs', [string]$submitRetryIntervalMs,
            '--requireActiveBeforeEnter', $requireActiveBeforeEnterArg,
            '--requireUserIdleBeforeSend', '0',
            '--minUserIdleBeforeSendMs', '0',
            '--visibleBeaconEnabled', $visibleBeaconEnabledArg,
            '--visibleLabel', $TargetKey,
            '--visiblePreHoldMs', [string]$visiblePreHoldMs,
            '--visiblePostHoldMs', [string]$visiblePostHoldMs,
            '--restorePreviousActive', $restorePreviousActiveArg,
            '--failOnFocusSteal', $failOnFocusStealArg,
            '--clearInput', $clearInputArg,
            '--debugLog', $debugLogPath
        ) -Wait -PassThru -WindowStyle Hidden

        return [pscustomobject]@{
            Executed = $true
            ExitCode = [int]$proc.ExitCode
            DebugLogPath = $debugLogPath
            SkippedReason = ''
        }
    }
    finally {
        if (Test-Path -LiteralPath $payloadFile -PathType Leaf) {
            Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-TypedWindowAhkFailure {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$FailurePhase,
        [Parameter(Mandatory)][string]$PrepareReason
    )

    $failOnFocusSteal = [bool](Get-ConfigValue -Object $Config -Name 'VisibleExecutionFailOnFocusSteal' -DefaultValue $false)
    if ($failOnFocusSteal -and $ExitCode -eq 42) {
        return [pscustomobject]@{
            FinalState                = 'manual_attention_required'
            ManualAttentionRequired   = $true
            SubmitReason              = 'visible-focus-steal'
            RetryReason               = 'visible-focus-steal'
            TypedWindowExecutionState = 'typed-window-visible-contract-failed'
            SubmitProbeState          = 'typed-window-focus-steal'
            LastResetReason           = 'focus-steal-before-submit'
            FailureSummary            = ('typed-window {0} failed due to visible focus steal' -f $FailurePhase)
            VisibleContractFailed     = $true
        }
    }

    return [pscustomobject]@{
        FinalState                = 'failed'
        ManualAttentionRequired   = $false
        SubmitReason              = ('typed-window-{0}-failed' -f $FailurePhase)
        RetryReason               = ('typed-window-{0}-failed' -f $FailurePhase)
        TypedWindowExecutionState = ('typed-window-{0}-failed' -f $FailurePhase)
        SubmitProbeState          = ('typed-window-{0}-failed' -f $FailurePhase)
        LastResetReason           = if (Test-NonEmptyString $PrepareReason) { $PrepareReason } else { ('typed-window-{0}-failed' -f $FailurePhase) }
        FailureSummary            = ('typed-window {0} failed exitCode={1}' -f $FailurePhase, $ExitCode)
        VisibleContractFailed     = $false
    }
}

function Resolve-TypedWindowPrepareRequirement {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetKey
    )

    if (-not (Test-NonEmptyString ([string](Get-ConfigValue -Object $Session -Name 'SessionRunRoot' -DefaultValue '')))) {
        return [pscustomobject]@{ Required = $true; Reason = 'bootstrap-needed' }
    }

    $sessionState = [string](Get-ConfigValue -Object $Session -Name 'State' -DefaultValue 'bootstrap-needed')
    if ($sessionState -in @('bootstrap-needed', 'recovery-needed', 'dirty-session')) {
        return [pscustomobject]@{ Required = $true; Reason = if (Test-NonEmptyString $sessionState) { $sessionState } else { 'bootstrap-needed' } }
    }

    if ([string](Get-ConfigValue -Object $Session -Name 'SessionRunRoot' -DefaultValue '') -ne $RunRoot) {
        return [pscustomobject]@{ Required = $true; Reason = 'runroot-changed' }
    }

    if ([string](Get-ConfigValue -Object $Session -Name 'SessionPairId' -DefaultValue '') -ne $PairId) {
        return [pscustomobject]@{ Required = $true; Reason = 'pair-changed' }
    }

    if ([string](Get-ConfigValue -Object $Session -Name 'SessionTargetId' -DefaultValue '') -ne $TargetKey) {
        return [pscustomobject]@{ Required = $true; Reason = 'target-changed' }
    }

    return [pscustomobject]@{ Required = $false; Reason = 'reuse-session' }
}

function Invoke-TypedWindowPrepareIfNeeded {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetKey,
        [bool]$AllowInlinePrepare = $true
    )

    $session = Read-TypedWindowSessionState -Config $Config -TargetKey $TargetKey
    $requirement = Resolve-TypedWindowPrepareRequirement -Session $session -RunRoot $RunRoot -PairId $PairId -TargetKey $TargetKey
    if (-not [bool]$requirement.Required) {
        return [pscustomobject]@{
            Prepared = $false
            PrepareReason = [string]$requirement.Reason
            PrepareResult = $null
            Session = $session
        }
    }

    if (-not $AllowInlinePrepare) {
        return [pscustomobject]@{
            Prepared = $false
            PrepareBlocked = $true
            PrepareFailed = $false
            PrepareReason = [string]$requirement.Reason
            PrepareResult = $null
            Session = $session
        }
    }

    $prepareResult = Invoke-TypedWindowAhkPayload -Config $Config -TargetKey $TargetKey -Payload '/new' -ClearInput $true -SubmitModes @('enter') -DebugLabel ([string]$requirement.Reason)
    if ([bool]$prepareResult.Executed -and [int]$prepareResult.ExitCode -ne 0) {
        return [pscustomobject]@{
            Prepared = $false
            PrepareBlocked = $false
            PrepareFailed = $true
            PrepareReason = [string]$requirement.Reason
            PrepareResult = $prepareResult
            Session = $session
        }
    }

    $session = Set-TypedWindowSessionFields -Session $session -State 'active-run'
    $session.SessionRunRoot = $RunRoot
    $session.SessionPairId = $PairId
    $session.SessionTargetId = $TargetKey
    $session.SessionEpoch = [int](Get-ConfigValue -Object $session -Name 'SessionEpoch' -DefaultValue 0) + 1
    $session.LastPrepareAt = (Get-Date).ToString('o')
    $session.LastResetReason = [string]$requirement.Reason
    $session.ConsecutiveSubmitUnconfirmedCount = 0
    Save-TypedWindowSessionState -Config $Config -TargetKey $TargetKey -Session $session

    return [pscustomobject]@{
        Prepared = $true
        PrepareBlocked = $false
        PrepareFailed = $false
        PrepareReason = [string]$requirement.Reason
        PrepareResult = $prepareResult
        Session = $session
    }
}

function Wait-ForTypedWindowSubmitProgress {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$TargetRow,
        [Parameter(Mandatory)][string]$TargetKey,
        [datetime]$ReferenceTime = [datetime]::MinValue,
        [int]$ProbeSeconds = 10,
        [int]$ProbePollMs = 1000,
        [double]$ProgressCpuDeltaThresholdSeconds = 0.05
    )

    $runtimeTarget = Get-TypedWindowRuntimeTarget -Config $Config -TargetKey $TargetKey
    $shellPid = if ($null -ne $runtimeTarget) { [int](Get-ConfigValue -Object $runtimeTarget -Name 'ShellPid' -DefaultValue 0) } else { 0 }
    $baseline = Get-TypedWindowProgressSnapshot -TargetRow $TargetRow -ShellPid $shellPid -ReferenceTime $ReferenceTime
    if ($baseline.LatestArtifactTicks -gt 0 -and (Test-NonEmptyString $baseline.LatestArtifactSignal)) {
        return [pscustomobject]@{
            ProgressDetected = $true
            Signal = [string]$baseline.LatestArtifactSignal
            SignalStrength = 'strong'
            SignalPath = [string]$baseline.LatestArtifactPath
            ElapsedSeconds = 0
            CpuDeltaSeconds = 0.0
            ShellPid = $shellPid
            ChildProcessIds = @($baseline.ChildProcessIds)
        }
    }

    $probeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds([math]::Max(1, $ProbeSeconds))
    $pollMs = [math]::Max(100, $ProbePollMs)
    do {
        Start-Sleep -Milliseconds $pollMs
        $current = Get-TypedWindowProgressSnapshot -TargetRow $TargetRow -ShellPid $shellPid -ReferenceTime $ReferenceTime
        if ($current.LatestArtifactTicks -gt 0 -and (Test-NonEmptyString $current.LatestArtifactSignal)) {
            return [pscustomobject]@{
                ProgressDetected = $true
                Signal = [string]$current.LatestArtifactSignal
                SignalStrength = 'strong'
                SignalPath = [string]$current.LatestArtifactPath
                ElapsedSeconds = [int][math]::Round($probeStopwatch.Elapsed.TotalSeconds, 0)
                CpuDeltaSeconds = [math]::Round(([double]$current.CpuSeconds - [double]$baseline.CpuSeconds), 6)
                ShellPid = $shellPid
                ChildProcessIds = @($current.ChildProcessIds)
            }
        }

        $cpuDeltaSeconds = [math]::Round(([double]$current.CpuSeconds - [double]$baseline.CpuSeconds), 6)
        if ($cpuDeltaSeconds -ge $ProgressCpuDeltaThresholdSeconds) {
            return [pscustomobject]@{
                ProgressDetected = $true
                Signal = 'codex-cpu-delta'
                SignalStrength = 'weak'
                SignalPath = ''
                ElapsedSeconds = [int][math]::Round($probeStopwatch.Elapsed.TotalSeconds, 0)
                CpuDeltaSeconds = $cpuDeltaSeconds
                ShellPid = $shellPid
                ChildProcessIds = @($current.ChildProcessIds)
            }
        }
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        ProgressDetected = $false
        Signal = 'none'
        SignalStrength = 'none'
        SignalPath = ''
        ElapsedSeconds = [int][math]::Round($probeStopwatch.Elapsed.TotalSeconds, 0)
        CpuDeltaSeconds = [math]::Round(([double](Get-TypedWindowProgressSnapshot -TargetRow $TargetRow -ShellPid $shellPid -ReferenceTime $ReferenceTime).CpuSeconds - [double]$baseline.CpuSeconds), 6)
        ShellPid = $shellPid
        ChildProcessIds = @($baseline.ChildProcessIds)
    }
}

function Get-VisibleWorkerDispatchResult {
    param(
        [Parameter(Mandatory)]$WaitResult,
        [Parameter(Mandatory)]$TargetRow,
        [Parameter(Mandatory)][int]$WaitForPublishSeconds
    )

    $finalState = [string]$WaitResult.State
    $processedPath = [string]$WaitResult.Path
    $processedAt = ''
    $failedPath = ''
    $failedAt = ''
    $retryReason = ''
    $outboxResult = $null

    if (Test-Path -LiteralPath $processedPath -PathType Leaf) {
        $processedAt = (Get-Item -LiteralPath $processedPath -ErrorAction Stop).LastWriteTime.ToString('o')
    }

    switch ([string]$WaitResult.State) {
        'completed' {
            $referenceTime = if ($null -ne $WaitResult.StatusData -and (Test-NonEmptyString ([string](Get-ConfigValue -Object $WaitResult.StatusData -Name 'CompletedAt' -DefaultValue '')))) {
                try { [datetime]::Parse([string](Get-ConfigValue -Object $WaitResult.StatusData -Name 'CompletedAt' -DefaultValue '')) } catch { Get-Date }
            }
            else {
                Get-Date
            }
            $outboxResult = Wait-ForOutboxPublish -TargetRow $TargetRow -TimeoutSeconds $WaitForPublishSeconds -ReferenceTime $referenceTime
            if ($outboxResult.Published) {
                $finalState = 'publish-detected'
            }
            elseif ($WaitForPublishSeconds -gt 0) {
                $finalState = 'submit-unconfirmed'
            }
            break
        }
        'failed' {
            $failedPath = [string]$WaitResult.Path
            if (Test-Path -LiteralPath $failedPath -PathType Leaf) {
                $failedAt = (Get-Item -LiteralPath $failedPath -ErrorAction Stop).LastWriteTime.ToString('o')
            }
            if ($null -ne $WaitResult.StatusData) {
                $retryReason = [string](Get-ConfigValue -Object $WaitResult.StatusData -Name 'Reason' -DefaultValue 'visible-worker-failed')
            }
            break
        }
        'worker-not-ready' {
            $retryReason = 'visible-worker-not-ready'
            break
        }
        'dispatch-accepted-stale' {
            $retryReason = 'dispatch-accepted-stale'
            break
        }
        'dispatch-running-stale-no-heartbeat' {
            $retryReason = 'dispatch-running-stale-no-heartbeat'
            break
        }
        'timeout' {
            $retryReason = 'visible-worker-dispatch-timeout'
            break
        }
    }

    return [pscustomobject]@{
        FinalState = $finalState
        ProcessedPath = $processedPath
        ProcessedAt = $processedAt
        FailedPath = $failedPath
        FailedAt = $failedAt
        RetryReason = $retryReason
        OutboxResult = $outboxResult
    }
}

function Resolve-VisibleWorkerLateSuccess {
    param(
        [Parameter(Mandatory)]$TargetRow,
        [string]$CurrentFinalState,
        [string]$CurrentSubmitState,
        [bool]$CurrentSubmitConfirmed,
        [string]$CurrentSubmitReason,
        [string]$DispatchPath,
        [string]$CommandId
    )

    $outboxSnapshot = Wait-ForOutboxPublish -TargetRow $TargetRow -TimeoutSeconds 0 -ReferenceTime ([datetime]::MinValue)
    $dispatchCompleted = $false
    if ((Test-NonEmptyString $DispatchPath) -and (Test-Path -LiteralPath $DispatchPath -PathType Leaf)) {
        try {
            $dispatchDoc = Read-JsonObject -Path $DispatchPath
            $dispatchCommandId = [string](Get-ConfigValue -Object $dispatchDoc -Name 'CommandId' -DefaultValue '')
            if ((-not (Test-NonEmptyString $CommandId)) -or ($dispatchCommandId -eq $CommandId)) {
                $dispatchCompleted = ([string](Get-ConfigValue -Object $dispatchDoc -Name 'State' -DefaultValue '') -eq 'completed')
            }
        }
        catch {
            $dispatchCompleted = $false
        }
    }

    $superseded = $outboxSnapshot.Published -and (-not $CurrentSubmitConfirmed)
    return [pscustomobject]@{
        Superseded = $superseded
        FinalState = if ($superseded) { if ($dispatchCompleted) { 'publish-detected-late' } else { 'publish-detected' } } else { $CurrentFinalState }
        SubmitState = if ($superseded) { 'confirmed' } else { $CurrentSubmitState }
        SubmitConfirmed = if ($superseded) { $true } else { $CurrentSubmitConfirmed }
        SubmitReason = if ($superseded) { if ($dispatchCompleted) { 'outbox-publish-detected-after-dispatch-timeout' } else { 'outbox-publish-detected-late' } } else { $CurrentSubmitReason }
        OutboxResult = $outboxSnapshot
    }
}

function Resolve-TypedWindowLateSuccess {
    param(
        [Parameter(Mandatory)]$TargetRow,
        [string]$CurrentFinalState,
        [string]$CurrentSubmitState,
        [bool]$CurrentSubmitConfirmed,
        [string]$CurrentSubmitReason,
        [string]$CurrentTypedWindowExecutionState,
        [string]$CurrentSubmitProbeState,
        [string]$CurrentSubmitConfirmationSignal
    )

    $outboxSnapshot = Wait-ForOutboxPublish -TargetRow $TargetRow -TimeoutSeconds 0 -ReferenceTime ([datetime]::MinValue)
    $superseded = $outboxSnapshot.Published -and (-not $CurrentSubmitConfirmed)

    return [pscustomobject]@{
        Superseded = $superseded
        FinalState = if ($superseded) { 'publish-detected-late' } else { $CurrentFinalState }
        SubmitState = if ($superseded) { 'confirmed' } else { $CurrentSubmitState }
        SubmitConfirmed = if ($superseded) { $true } else { $CurrentSubmitConfirmed }
        SubmitReason = if ($superseded) { 'outbox-publish-detected-late' } else { $CurrentSubmitReason }
        TypedWindowExecutionState = if ($superseded) { 'typed-window-running-confirmed' } else { $CurrentTypedWindowExecutionState }
        SubmitProbeState = if ($superseded) { 'typed-window-running-confirmed' } else { $CurrentSubmitProbeState }
        SubmitConfirmationSignal = if ($superseded) {
            if (Test-NonEmptyString $CurrentSubmitConfirmationSignal) { $CurrentSubmitConfirmationSignal } else { 'outbox-publish-ready' }
        } else {
            $CurrentSubmitConfirmationSignal
        }
        OutboxResult = $outboxSnapshot
    }
}

function Get-VisibleWorkerDispatchStatusPath {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetKey
    )

    return (Join-Path (Join-Path $RunRoot '.state\headless-dispatch') ("dispatch_{0}.json" -f $TargetKey))
}

function Get-VisibleWorkerStatusPath {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetKey
    )

    return (Join-Path (Join-Path ([string]$PairTest.VisibleWorker.StatusRoot) 'workers') ("worker_{0}.json" -f $TargetKey))
}

function Get-IsoTimestampAgeSeconds {
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

function Get-DispatchFreshnessAgeSeconds {
    param($StatusDoc)

    if ($null -eq $StatusDoc) {
        return -1
    }

    $heartbeatAge = Get-IsoTimestampAgeSeconds -IsoTimestamp ([string](Get-ConfigValue -Object $StatusDoc -Name 'HeartbeatAt' -DefaultValue ''))
    if ($heartbeatAge -ge 0) {
        return $heartbeatAge
    }

    return (Get-IsoTimestampAgeSeconds -IsoTimestamp ([string](Get-ConfigValue -Object $StatusDoc -Name 'UpdatedAt' -DefaultValue '')))
}

function Wait-ForVisibleWorkerDispatch {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetKey,
        [Parameter(Mandatory)][string]$CommandId,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)]$PairTest,
        [int]$AcceptedStaleSeconds = 15,
        [int]$RunningStaleSeconds = 30
    )

    $statusPath = Get-VisibleWorkerDispatchStatusPath -RunRoot $RunRoot -TargetKey $TargetKey
    $workerStatusPath = Get-VisibleWorkerStatusPath -PairTest $PairTest -TargetKey $TargetKey
    $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            try {
                $statusDoc = Read-JsonObject -Path $statusPath
            }
            catch {
                $statusDoc = $null
            }

            if ($null -ne $statusDoc -and [string](Get-ConfigValue -Object $statusDoc -Name 'CommandId' -DefaultValue '') -eq $CommandId) {
                $state = [string](Get-ConfigValue -Object $statusDoc -Name 'State' -DefaultValue '')
                if ($state -in @('completed', 'failed')) {
                    return [pscustomobject]@{
                        State      = $state
                        Path       = $statusPath
                        StatusData = $statusDoc
                    }
                }

                $workerStatus = $null
                if (Test-Path -LiteralPath $workerStatusPath -PathType Leaf) {
                    try {
                        $workerStatus = Read-JsonObject -Path $workerStatusPath
                    }
                    catch {
                        $workerStatus = $null
                    }
                }

                $workerPid = if ($null -ne $workerStatus) { [int](Get-ConfigValue -Object $workerStatus -Name 'WorkerPid' -DefaultValue 0) } else { 0 }
                $workerAlive = Test-ProcessAlive -ProcessId $workerPid
                if (-not $workerAlive) {
                    return [pscustomobject]@{
                        State      = 'worker-not-ready'
                        Path       = $statusPath
                        StatusData = $statusDoc
                    }
                }

                $dispatchAgeSeconds = Get-DispatchFreshnessAgeSeconds -StatusDoc $statusDoc
                if ($state -eq 'accepted' -and $dispatchAgeSeconds -ge $AcceptedStaleSeconds) {
                    return [pscustomobject]@{
                        State      = 'dispatch-accepted-stale'
                        Path       = $statusPath
                        StatusData = $statusDoc
                    }
                }
                if ($state -eq 'running' -and $dispatchAgeSeconds -ge $RunningStaleSeconds) {
                    return [pscustomobject]@{
                        State      = 'dispatch-running-stale-no-heartbeat'
                        Path       = $statusPath
                        StatusData = $statusDoc
                    }
                }
            }
        }

        Start-Sleep -Milliseconds 400
    }

    return [pscustomobject]@{
        State      = 'timeout'
        Path       = $statusPath
        StatusData = $null
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "manifest not found: $manifestPath"
}

$config = Import-ConfigDataFile -Path $resolvedConfigPath
$pairTestConfig = Get-ConfigValue -Object $config -Name 'PairTest' -DefaultValue @{}
$configuredMaxAttempts = [int](Get-ConfigValue -Object $pairTestConfig -Name 'SeedRetryMaxAttempts' -DefaultValue $MaxAttempts)
$configuredBackoffMs = @(Get-IntegerArray (Get-ConfigValue -Object $pairTestConfig -Name 'SeedRetryBackoffMs' -DefaultValue @()))
$seedWaitForUserIdleTimeoutSeconds = [int](Get-ConfigValue -Object $pairTestConfig -Name 'SeedWaitForUserIdleTimeoutSeconds' -DefaultValue 0)
if (-not $PSBoundParameters.ContainsKey('MaxAttempts')) {
    $MaxAttempts = $configuredMaxAttempts
}
if (-not $PSBoundParameters.ContainsKey('RetryBackoffMs') -or @($RetryBackoffMs).Count -eq 0) {
    $RetryBackoffMs = $configuredBackoffMs
}
$RetryBackoffMs = @(Get-IntegerArray $RetryBackoffMs)
if ($MaxAttempts -lt 1) {
    $MaxAttempts = 1
}
$manifest = Read-JsonObject -Path $manifestPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath -ManifestPairTest (Get-ConfigValue -Object $manifest -Name 'PairTest' -DefaultValue $null)
$executionPathMode = [string](Get-ConfigValue -Object $pairTest -Name 'ExecutionPathMode' -DefaultValue $(if ([bool]$pairTest.VisibleWorker.Enabled) { 'visible-worker' } else { 'typed-window' }))
$requireUserVisibleCellExecution = [bool](Get-ConfigValue -Object $pairTest -Name 'RequireUserVisibleCellExecution' -DefaultValue $false)
$allowedWindowVisibilityMethods = @(Get-StringArray (Get-ConfigValue -Object $pairTest -Name 'AllowedWindowVisibilityMethods' -DefaultValue @('hwnd')))
if ($allowedWindowVisibilityMethods.Count -eq 0) {
    $allowedWindowVisibilityMethods = @('hwnd')
}
$submitRetryModes = @(Get-RelaySubmitRetryModes -Config $config)
$submitRetrySequenceSummary = Get-RelaySubmitRetrySequenceSummary -Modes $submitRetryModes
$primarySubmitMode = Get-RelayPrimarySubmitMode -Modes $submitRetryModes
$finalSubmitMode = Get-RelayFinalSubmitMode -Modes $submitRetryModes
$submitRetryIntervalMs = [int](Get-ConfigValue -Object $config -Name 'SubmitRetryIntervalMs' -DefaultValue 1000)
$visibleWorkerEnabled = ($executionPathMode -eq 'visible-worker')
if ($visibleWorkerEnabled -and -not [bool]$pairTest.VisibleWorker.Enabled) {
    throw 'PairTest.ExecutionPathMode is visible-worker but PairTest.VisibleWorker.Enabled is false.'
}
$visibleWorkerDispatchTimeoutSeconds = if ($visibleWorkerEnabled) {
    [math]::Max(1, [int](Get-ConfigValue -Object $pairTest.VisibleWorker -Name 'DispatchTimeoutSeconds' -DefaultValue ([int]$pairTest.VisibleWorker.CommandTimeoutSeconds)))
}
else {
    0
}
$typedWindowSubmitProbeSeconds = if (-not $visibleWorkerEnabled) {
    [math]::Max(1, [int](Get-ConfigValue -Object $pairTest.TypedWindow -Name 'SubmitProbeSeconds' -DefaultValue 10))
}
else {
    0
}
$typedWindowSubmitProbePollMs = if (-not $visibleWorkerEnabled) {
    [math]::Max(100, [int](Get-ConfigValue -Object $pairTest.TypedWindow -Name 'SubmitProbePollMs' -DefaultValue 1000))
}
else {
    0
}
$typedWindowSubmitRetryLimit = if (-not $visibleWorkerEnabled) {
    [math]::Max(0, [int](Get-ConfigValue -Object $pairTest.TypedWindow -Name 'SubmitRetryLimit' -DefaultValue 1))
}
else {
    0
}
$typedWindowProgressCpuDeltaThresholdSeconds = if (-not $visibleWorkerEnabled) {
    [math]::Max(0.0, [double](Get-ConfigValue -Object $pairTest.TypedWindow -Name 'ProgressCpuDeltaThresholdSeconds' -DefaultValue 0.05))
}
else {
    0.0
}
$targetRow = Resolve-TargetManifestRow -Manifest $manifest -TargetId $TargetId
$targetKey = [string]$targetRow.TargetId
$pairId = [string](Get-ConfigValue -Object $targetRow -Name 'PairId' -DefaultValue '')
$targetConfig = @($config.Targets | Where-Object { [string]$_.Id -eq $targetKey } | Select-Object -First 1)
if ($targetConfig.Count -eq 0) {
    throw "target relay config not found: $targetKey"
}

$requireUserIdleBeforeSend = [bool](Get-ConfigValue -Object $config -Name 'RequireUserIdleBeforeSend' -DefaultValue $false)
$minUserIdleBeforeSendMs = [int](Get-ConfigValue -Object $config -Name 'MinUserIdleBeforeSendMs' -DefaultValue 0)
$inboxRoot = [string]$targetConfig[0].Folder
$processedRoot = [string]$config.ProcessedRoot
$failedRoot = [string]$config.FailedRoot
$retryPendingRoot = [string]$config.RetryPendingRoot
$stateRoot = Join-Path $resolvedRunRoot '.state'
$seedSendStatusPath = Join-Path $stateRoot 'seed-send-status.json'
Ensure-Directory -Path $stateRoot
$seedSendState = Load-SeedSendStatusState -Path $seedSendStatusPath
$resolvedMessageTextFilePath = ''
if (Test-NonEmptyString $MessageTextFilePath) {
    $resolvedMessageTextFilePath = (Resolve-Path -LiteralPath $MessageTextFilePath).Path
}

$attemptResults = @()
$finalState = 'not-started'
$processedPath = ''
$failedPath = ''
$retryPendingPath = ''
$outboxResult = $null
$firstAttemptedAt = ''
$lastAttemptedAt = ''
$nextRetryAt = ''
$backoffMs = 0
$retryReason = ''
$manualAttentionRequired = $false
$processedAt = ''
$failedAt = ''
$retryPendingAt = ''
$workerCommandId = ''
$workerDispatchPath = ''
$typedWindowExecutionState = ''
$submitProbeState = ''
$submitProbeElapsedSeconds = 0
$submitRetryCount = 0
$submitConfirmationSignal = ''
$typedWindowSessionState = ''
$typedWindowLastResetReason = ''
$typedWindowSession = $null
$resendSeedReadyFile = $false

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $readyPath = ''
    $producerOutput = ''
    $baseName = ''
    $transportMode = ''
    $requeued = $false
    $retryScheduled = $false
    $attemptedAt = (Get-Date).ToString('o')
    if (-not (Test-NonEmptyString $firstAttemptedAt)) {
        $firstAttemptedAt = $attemptedAt
    }
    $lastAttemptedAt = $attemptedAt
    $nextRetryAt = ''
    $backoffMs = 0

    if (-not $visibleWorkerEnabled) {
        $prepareResult = Invoke-TypedWindowPrepareIfNeeded `
            -Config $config `
            -RunRoot $resolvedRunRoot `
            -PairId $pairId `
            -TargetKey $targetKey `
            -AllowInlinePrepare:(-not $DisallowInlineTypedWindowPrepare)
        $typedWindowSession = $prepareResult.Session
        $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
        $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')
        if ([bool](Get-ConfigValue -Object $prepareResult -Name 'PrepareBlocked' -DefaultValue $false)) {
            $typedWindowExecutionState = 'typed-window-inline-prepare-blocked'
            $submitProbeState = 'typed-window-inline-prepare-blocked'
            $submitReason = 'typed-window-inline-prepare-blocked'
            $retryReason = 'typed-window-inline-prepare-blocked'
            $finalState = 'manual_attention_required'
            $manualAttentionRequired = $true
            $submitConfirmed = $false
            $submitState = 'failed'
            $submitConfirmationSignal = ('inline prepare blocked target={0} reason={1}' -f $targetKey, [string]$prepareResult.PrepareReason)
            if ($null -eq $typedWindowSession) {
                $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
            }
            $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'recovery-needed'
            $typedWindowSession.LastResetReason = 'typed-window-inline-prepare-blocked'
            $typedWindowSession.ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $typedWindowSession -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0) + 1
            Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
            $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
            $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')

            Set-SeedSendStatusEntry -State $seedSendState `
                -TargetKey $targetKey `
                -UpdatedAt (Get-Date).ToString('o') `
                -FinalState $finalState `
                -ExecutionPathMode $executionPathMode `
                -UserVisibleCellExecutionRequired $requireUserVisibleCellExecution `
                -AllowedWindowVisibilityMethods @($allowedWindowVisibilityMethods) `
                -RouterDispatchState '' `
                -SubmitState $submitState `
                -SubmitConfirmed $false `
                -SubmitReason $submitReason `
                -SubmitRetryModes @($submitRetryModes) `
                -SubmitRetrySequenceSummary $submitRetrySequenceSummary `
                -PrimarySubmitMode $primarySubmitMode `
                -FinalSubmitMode $finalSubmitMode `
                -SubmitRetryIntervalMs $submitRetryIntervalMs `
                -AttemptCount @($attemptResults).Count `
                -MaxAttempts $MaxAttempts `
                -FirstAttemptedAt $firstAttemptedAt `
                -LastAttemptedAt $lastAttemptedAt `
                -NextRetryAt '' `
                -BackoffMs 0 `
                -RetryReason $retryReason `
                -ManualAttentionRequired $manualAttentionRequired `
                -ProcessedPath '' `
                -ProcessedAt '' `
                -FailedPath '' `
                -FailedAt '' `
                -RetryPendingPath '' `
                -RetryPendingAt '' `
                -OutboxPublished $false `
                -OutboxObservedAt '' `
                -LastReadyPath '' `
                -LastReadyBaseName '' `
                -TypedWindowExecutionState $typedWindowExecutionState `
                -SubmitProbeState $submitProbeState `
                -SubmitProbeElapsedSeconds 0 `
                -SubmitRetryCount $submitRetryCount `
                -SubmitConfirmationSignal $submitConfirmationSignal `
                -TypedWindowSessionState $typedWindowSessionState `
                -TypedWindowLastResetReason $typedWindowLastResetReason
            Save-SeedSendStatusState -Path $seedSendStatusPath -RunRoot $resolvedRunRoot -State $seedSendState
            break
        }
        if ([bool](Get-ConfigValue -Object $prepareResult -Name 'PrepareFailed' -DefaultValue $false)) {
            $prepareExitCode = [int](Get-ConfigValue -Object $prepareResult.PrepareResult -Name 'ExitCode' -DefaultValue 1)
            $prepareFailure = Resolve-TypedWindowAhkFailure `
                -Config $config `
                -ExitCode $prepareExitCode `
                -FailurePhase 'prepare' `
                -PrepareReason ([string]$prepareResult.PrepareReason)
            $typedWindowExecutionState = [string]$prepareFailure.TypedWindowExecutionState
            $submitProbeState = [string]$prepareFailure.SubmitProbeState
            $submitReason = [string]$prepareFailure.SubmitReason
            $retryReason = [string]$prepareFailure.RetryReason
            $finalState = [string]$prepareFailure.FinalState
            $manualAttentionRequired = [bool]$prepareFailure.ManualAttentionRequired
            $submitConfirmationSignal = [string]$prepareFailure.FailureSummary
            $submitConfirmed = $false
            $submitState = 'failed'
            if ($null -eq $typedWindowSession) {
                $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
            }
            $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State $(if ($manualAttentionRequired) { 'recovery-needed' } else { 'dirty-session' })
            $typedWindowSession.LastResetReason = [string]$prepareFailure.LastResetReason
            if ($manualAttentionRequired) {
                $typedWindowSession.ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $typedWindowSession -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0) + 1
            }
            Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
            $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
            $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')

            Set-SeedSendStatusEntry -State $seedSendState `
                -TargetKey $targetKey `
                -UpdatedAt (Get-Date).ToString('o') `
                -FinalState $finalState `
                -ExecutionPathMode $executionPathMode `
                -UserVisibleCellExecutionRequired $requireUserVisibleCellExecution `
                -AllowedWindowVisibilityMethods @($allowedWindowVisibilityMethods) `
                -RouterDispatchState '' `
                -SubmitState $submitState `
                -SubmitConfirmed $false `
                -SubmitReason $submitReason `
                -SubmitRetryModes @($submitRetryModes) `
                -SubmitRetrySequenceSummary $submitRetrySequenceSummary `
                -PrimarySubmitMode $primarySubmitMode `
                -FinalSubmitMode $finalSubmitMode `
                -SubmitRetryIntervalMs $submitRetryIntervalMs `
                -AttemptCount @($attemptResults).Count `
                -MaxAttempts $MaxAttempts `
                -FirstAttemptedAt $firstAttemptedAt `
                -LastAttemptedAt $lastAttemptedAt `
                -NextRetryAt '' `
                -BackoffMs 0 `
                -RetryReason $retryReason `
                -ManualAttentionRequired $manualAttentionRequired `
                -ProcessedPath '' `
                -ProcessedAt '' `
                -FailedPath '' `
                -FailedAt '' `
                -RetryPendingPath '' `
                -RetryPendingAt '' `
                -OutboxPublished $false `
                -OutboxObservedAt '' `
                -LastReadyPath '' `
                -LastReadyBaseName '' `
                -TypedWindowExecutionState $typedWindowExecutionState `
                -SubmitProbeState $submitProbeState `
                -SubmitProbeElapsedSeconds 0 `
                -SubmitRetryCount $submitRetryCount `
                -SubmitConfirmationSignal ([string]$prepareFailure.FailureSummary) `
                -TypedWindowSessionState $typedWindowSessionState `
                -TypedWindowLastResetReason $typedWindowLastResetReason
            Save-SeedSendStatusState -Path $seedSendStatusPath -RunRoot $resolvedRunRoot -State $seedSendState
            break
        }
    }

    if ($requireUserIdleBeforeSend -and $minUserIdleBeforeSendMs -gt 0 -and $seedWaitForUserIdleTimeoutSeconds -gt 0) {
        $idleWaitResult = Wait-ForUserIdle -RequiredIdleMs $minUserIdleBeforeSendMs -TimeoutSeconds $seedWaitForUserIdleTimeoutSeconds
        if (-not [bool]$idleWaitResult.Satisfied) {
            $retryReason = 'user-idle-timeout'
            $finalState = 'manual_attention_required'
            $manualAttentionRequired = $true
            break
        }
    }

    if ($attempt -eq 1 -or $resendSeedReadyFile) {
        $seedParameters = @{
            ConfigPath = $resolvedConfigPath
            RunRoot = $resolvedRunRoot
            TargetId = $targetKey
            AsJson = $true
        }
        if (Test-NonEmptyString $resolvedMessageTextFilePath) {
            $seedParameters['MessageTextFilePath'] = $resolvedMessageTextFilePath
        }

        $seedRaw = & (Join-Path $root 'tests\Send-InitialPairSeed.ps1') @seedParameters
        $seedResult = $seedRaw | ConvertFrom-Json
        $seedRow = @($seedResult.Results | Where-Object { [string]$_.TargetId -eq $targetKey } | Select-Object -First 1)
        if ($seedRow.Count -eq 0) {
            throw "seed enqueue returned no result row for target: $targetKey"
        }

        $readyPath = [string]$seedRow[0].ReadyPath
        $producerOutput = [string]$seedRow[0].ProducerOutput
        $transportMode = [string](Get-ConfigValue -Object $seedRow[0] -Name 'TransportMode' -DefaultValue '')
        $workerCommandId = [string](Get-ConfigValue -Object $seedRow[0] -Name 'CommandId' -DefaultValue '')
        if (-not (Test-NonEmptyString $readyPath)) {
            throw "seed enqueue returned empty ready path for target: $targetKey output=$producerOutput"
        }
        $baseName = [System.IO.Path]::GetFileName($readyPath)
        $resendSeedReadyFile = $false
    }
    elseif (Test-NonEmptyString $retryPendingPath) {
        $readyPath = Move-RetryPendingMessageToInbox -RetryPendingPath $retryPendingPath -InboxRoot $inboxRoot
        $baseName = [System.IO.Path]::GetFileName($readyPath)
        $requeued = $true
        $retryPendingPath = ''
    }
    else {
        break
    }

    if (-not $visibleWorkerEnabled) {
        if ($null -eq $typedWindowSession) {
            $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
        }
        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'active-run'
        $typedWindowSession.SessionRunRoot = $resolvedRunRoot
        $typedWindowSession.SessionPairId = $pairId
        $typedWindowSession.SessionTargetId = $targetKey
        $typedWindowSession.LastSubmitAt = $attemptedAt
        Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
        $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
        $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')
    }

    if ($visibleWorkerEnabled) {
        if (-not (Test-NonEmptyString $workerCommandId)) {
            throw "visible worker enqueue returned empty command id for target: $targetKey"
        }

        $waitResult = Wait-ForVisibleWorkerDispatch `
            -RunRoot $resolvedRunRoot `
            -TargetKey $targetKey `
            -CommandId $workerCommandId `
            -TimeoutSeconds $visibleWorkerDispatchTimeoutSeconds `
            -PairTest $pairTest `
            -AcceptedStaleSeconds ([int]$pairTest.VisibleWorker.DispatchAcceptedStaleSeconds) `
            -RunningStaleSeconds ([int]$pairTest.VisibleWorker.DispatchRunningStaleSeconds)
        $workerDispatchPath = [string]$waitResult.Path
        if ([string]$waitResult.State -in @('accepted', 'running', 'processed', 'retry-pending')) {
            throw ("Wait-ForVisibleWorkerDispatch returned unexpected non-terminal state for visible-worker mode: {0}" -f [string]$waitResult.State)
        }
    }
    else {
        $waitResult = Wait-ForMessageTransition `
            -BaseName $baseName `
            -InboxRoot $inboxRoot `
            -ProcessedRoot $processedRoot `
            -FailedRoot $failedRoot `
            -RetryPendingRoot $retryPendingRoot `
            -TimeoutSeconds $WaitForRouterSeconds
    }

    $attemptResults += [pscustomobject]@{
        Attempt = $attempt
        TargetId = $targetKey
        ReadyPath = $readyPath
        ReadyBaseName = $baseName
        Requeued = $requeued
        ProducerOutput = $producerOutput
        TransportMode = if (Test-NonEmptyString $transportMode) { $transportMode } else { if ($visibleWorkerEnabled) { 'visible-worker' } else { 'router-ready-file' } }
        CommandId = $workerCommandId
        TransitionState = [string]$waitResult.State
        TransitionPath = [string]$waitResult.Path
    }

    if ($visibleWorkerEnabled) {
        $visibleWorkerDispatchResult = Get-VisibleWorkerDispatchResult `
            -WaitResult $waitResult `
            -TargetRow $targetRow `
            -WaitForPublishSeconds $WaitForPublishSeconds
        $finalState = [string]$visibleWorkerDispatchResult.FinalState
        $processedPath = [string]$visibleWorkerDispatchResult.ProcessedPath
        $processedAt = [string]$visibleWorkerDispatchResult.ProcessedAt
        $failedPath = [string]$visibleWorkerDispatchResult.FailedPath
        $failedAt = [string]$visibleWorkerDispatchResult.FailedAt
        $retryReason = [string]$visibleWorkerDispatchResult.RetryReason
        $outboxResult = $visibleWorkerDispatchResult.OutboxResult
    }
    else {
        switch ([string]$waitResult.State) {
            'processed' {
                $finalState = 'processed'
                $processedPath = [string]$waitResult.Path
                if (Test-Path -LiteralPath $processedPath -PathType Leaf) {
                    $processedAt = (Get-Item -LiteralPath $processedPath -ErrorAction Stop).LastWriteTime.ToString('o')
                }
                $processedItem = Get-Item -LiteralPath $processedPath -ErrorAction SilentlyContinue
                $referenceTime = if ($null -ne $processedItem) { $processedItem.LastWriteTime } else { Get-Date }
                if (-not $visibleWorkerEnabled -and $WaitForPublishSeconds -gt 0) {
                    $typedWindowProgress = Wait-ForTypedWindowSubmitProgress `
                        -Config $config `
                        -TargetRow $targetRow `
                        -TargetKey $targetKey `
                        -ReferenceTime $referenceTime `
                        -ProbeSeconds $typedWindowSubmitProbeSeconds `
                        -ProbePollMs $typedWindowSubmitProbePollMs `
                        -ProgressCpuDeltaThresholdSeconds $typedWindowProgressCpuDeltaThresholdSeconds
                    $submitProbeElapsedSeconds = [int]$typedWindowProgress.ElapsedSeconds
                    $submitConfirmationSignal = [string]$typedWindowProgress.Signal
                    if ([bool]$typedWindowProgress.ProgressDetected) {
                        $signalStrength = [string](Get-ConfigValue -Object $typedWindowProgress -Name 'SignalStrength' -DefaultValue 'weak')
                        if ($signalStrength -eq 'strong') {
                            $typedWindowExecutionState = 'typed-window-running-confirmed'
                            $submitProbeState = 'typed-window-running-confirmed'
                        }
                        else {
                            $typedWindowExecutionState = 'typed-window-possible-running'
                            $submitProbeState = 'typed-window-possible-running'
                        }
                        if ($null -eq $typedWindowSession) {
                            $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
                        }
                        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State $(if ($signalStrength -eq 'strong') { 'running-confirmed' } else { 'active-run' })
                        $typedWindowSession.LastProgressAt = (Get-Date).ToString('o')
                        Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
                        $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
                        $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')
                    }
                    else {
                        $canRetryTypedWindowSubmit = ($attempt -lt $MaxAttempts -and $submitRetryCount -lt $typedWindowSubmitRetryLimit)
                        if ($canRetryTypedWindowSubmit) {
                            $submitRetryCount += 1
                            $typedWindowExecutionState = ('typed-window-retry-{0}' -f $submitRetryCount)
                            $submitProbeState = 'typed-window-submit-unconfirmed'
                            $retryReason = 'typed-window-submit-unconfirmed'
                            $finalState = 'retry-pending'
                            if ($null -eq $typedWindowSession) {
                                $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
                            }
                            $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'recovery-needed'
                            $typedWindowSession.LastResetReason = 'typed-window-submit-unconfirmed'
                            $typedWindowSession.ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $typedWindowSession -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0) + 1
                            Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
                            $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
                            $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')
                            $backoffMs = Get-RetryBackoffMilliseconds -AttemptNumber $attempt -BackoffScheduleMs $RetryBackoffMs -FallbackDelaySeconds $DelaySeconds
                            $nextRetryAt = (Get-Date).AddMilliseconds($backoffMs).ToString('o')
                            $resendSeedReadyFile = $true
                            Set-SeedSendStatusEntry -State $seedSendState `
                                -TargetKey $targetKey `
                                -UpdatedAt (Get-Date).ToString('o') `
                                -FinalState $finalState `
                                -ExecutionPathMode $executionPathMode `
                                -UserVisibleCellExecutionRequired $requireUserVisibleCellExecution `
                                -AllowedWindowVisibilityMethods @($allowedWindowVisibilityMethods) `
                                -RouterDispatchState 'processed' `
                                -SubmitState 'unconfirmed' `
                                -SubmitConfirmed $false `
                                -SubmitReason $retryReason `
                                -SubmitRetryModes @($submitRetryModes) `
                                -SubmitRetrySequenceSummary $submitRetrySequenceSummary `
                                -PrimarySubmitMode $primarySubmitMode `
                                -FinalSubmitMode $finalSubmitMode `
                                -SubmitRetryIntervalMs $submitRetryIntervalMs `
                                -AttemptCount $attempt `
                                -MaxAttempts $MaxAttempts `
                                -FirstAttemptedAt $firstAttemptedAt `
                                -LastAttemptedAt $lastAttemptedAt `
                                -NextRetryAt $nextRetryAt `
                                -BackoffMs $backoffMs `
                                -RetryReason $retryReason `
                                -ManualAttentionRequired $false `
                                -ProcessedPath $processedPath `
                                -ProcessedAt $processedAt `
                                -FailedPath $failedPath `
                                -FailedAt $failedAt `
                                -RetryPendingPath '' `
                                -RetryPendingAt '' `
                                -OutboxPublished $false `
                                -OutboxObservedAt '' `
                                -LastReadyPath $readyPath `
                                -LastReadyBaseName $baseName `
                                -TypedWindowExecutionState $typedWindowExecutionState `
                                -SubmitProbeState $submitProbeState `
                                -SubmitProbeElapsedSeconds $submitProbeElapsedSeconds `
                                -SubmitRetryCount $submitRetryCount `
                                -SubmitConfirmationSignal $submitConfirmationSignal `
                                -TypedWindowSessionState $typedWindowSessionState `
                                -TypedWindowLastResetReason $typedWindowLastResetReason
                            Save-SeedSendStatusState -Path $seedSendStatusPath -RunRoot $resolvedRunRoot -State $seedSendState
                            Start-Sleep -Milliseconds $backoffMs
                            $retryScheduled = $true
                            break
                        }

                        $typedWindowExecutionState = 'typed-window-submit-unconfirmed'
                        $submitProbeState = 'typed-window-submit-unconfirmed'
                        $retryReason = 'typed-window-submit-unconfirmed'
                        $finalState = 'submit-unconfirmed'
                        if ($null -eq $typedWindowSession) {
                            $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
                        }
                        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'recovery-needed'
                        $typedWindowSession.LastResetReason = 'typed-window-submit-unconfirmed'
                        $typedWindowSession.ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $typedWindowSession -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0) + 1
                        Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
                        $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
                        $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')
                        break
                    }
                }
                $outboxResult = Wait-ForOutboxPublish -TargetRow $targetRow -TimeoutSeconds $WaitForPublishSeconds -ReferenceTime $referenceTime
                if ($outboxResult.Published) {
                    $finalState = 'publish-detected'
                    if (-not $visibleWorkerEnabled) {
                        if ($null -eq $typedWindowSession) {
                            $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
                        }
                        $typedWindowExecutionState = 'typed-window-running-confirmed'
                        $submitProbeState = 'typed-window-running-confirmed'
                        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'running-confirmed'
                        $typedWindowSession.LastProgressAt = (Get-Date).ToString('o')
                        $typedWindowSession.LastConfirmedArtifactAt = (Get-Date).ToString('o')
                        $typedWindowSession.ConsecutiveSubmitUnconfirmedCount = 0
                        Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
                        $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
                        $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')
                    }
                }
                elseif ($WaitForPublishSeconds -gt 0) {
                    if (-not $visibleWorkerEnabled -and $typedWindowExecutionState -eq 'typed-window-possible-running') {
                        $typedWindowExecutionState = 'typed-window-running-no-artifact'
                        $submitProbeState = 'typed-window-running-no-artifact'
                        if ($null -eq $typedWindowSession) {
                            $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
                        }
                        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'dirty-session'
                        $typedWindowSession.LastResetReason = 'no-artifact-after-submit'
                        Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
                        $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
                        $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')
                        $finalState = 'processed'
                    }
                    elseif (-not $visibleWorkerEnabled -and $typedWindowExecutionState -eq 'typed-window-running-confirmed') {
                        $finalState = 'processed'
                    }
                    else {
                        $finalState = 'submit-unconfirmed'
                    }
                }
                break
            }
            'failed' {
                $finalState = 'failed'
                $failedPath = [string]$waitResult.Path
                if (Test-Path -LiteralPath $failedPath -PathType Leaf) {
                    $failedAt = (Get-Item -LiteralPath $failedPath -ErrorAction Stop).LastWriteTime.ToString('o')
                }
                break
            }
            'retry-pending' {
            $retryPendingPath = [string]$waitResult.Path
            if (Test-Path -LiteralPath $retryPendingPath -PathType Leaf) {
                $retryPendingAt = (Get-Item -LiteralPath $retryPendingPath -ErrorAction Stop).LastWriteTime.ToString('o')
            }
            $retryMetadata = Read-RetryPendingMetadata -RetryPendingPath $retryPendingPath
            if ($null -ne $retryMetadata) {
                $category = [string]$retryMetadata.FailureCategory
                if (Test-NonEmptyString $category) {
                    $retryReason = $category
                }
                else {
                    $retryReason = [string](Get-ConfigValue -Object $retryMetadata -Name 'Reason' -DefaultValue 'router-retry-pending')
                }
            }
            else {
                $retryReason = 'router-retry-pending'
            }
            if ($attempt -lt $MaxAttempts) {
                $finalState = 'retry-pending'
                $backoffMs = Get-RetryBackoffMilliseconds -AttemptNumber $attempt -BackoffScheduleMs $RetryBackoffMs -FallbackDelaySeconds $DelaySeconds
                $nextRetryAt = (Get-Date).AddMilliseconds($backoffMs).ToString('o')
                Set-SeedSendStatusEntry -State $seedSendState `
                    -TargetKey $targetKey `
                    -UpdatedAt (Get-Date).ToString('o') `
                    -FinalState $finalState `
                    -ExecutionPathMode $executionPathMode `
                    -UserVisibleCellExecutionRequired $requireUserVisibleCellExecution `
                    -AllowedWindowVisibilityMethods @($allowedWindowVisibilityMethods) `
                    -RouterDispatchState '' `
                    -SubmitState '' `
                    -SubmitConfirmed $false `
                    -SubmitReason '' `
                    -SubmitRetryModes @($submitRetryModes) `
                    -SubmitRetrySequenceSummary $submitRetrySequenceSummary `
                    -PrimarySubmitMode $primarySubmitMode `
                    -FinalSubmitMode $finalSubmitMode `
                    -SubmitRetryIntervalMs $submitRetryIntervalMs `
                    -AttemptCount $attempt `
                    -MaxAttempts $MaxAttempts `
                    -FirstAttemptedAt $firstAttemptedAt `
                    -LastAttemptedAt $lastAttemptedAt `
                    -NextRetryAt $nextRetryAt `
                    -BackoffMs $backoffMs `
                    -RetryReason $retryReason `
                    -ManualAttentionRequired $false `
                    -ProcessedPath $processedPath `
                    -ProcessedAt $processedAt `
                    -FailedPath $failedPath `
                    -FailedAt $failedAt `
                    -RetryPendingPath $retryPendingPath `
                    -RetryPendingAt $retryPendingAt `
                    -OutboxPublished $false `
                    -OutboxObservedAt '' `
                    -LastReadyPath $readyPath `
                    -LastReadyBaseName $baseName `
                    -TypedWindowExecutionState $typedWindowExecutionState `
                    -SubmitProbeState $submitProbeState `
                    -SubmitProbeElapsedSeconds $submitProbeElapsedSeconds `
                    -SubmitRetryCount $submitRetryCount `
                    -SubmitConfirmationSignal $submitConfirmationSignal `
                    -TypedWindowSessionState $typedWindowSessionState `
                    -TypedWindowLastResetReason $typedWindowLastResetReason
                Save-SeedSendStatusState -Path $seedSendStatusPath -RunRoot $resolvedRunRoot -State $seedSendState
                Start-Sleep -Milliseconds $backoffMs
                $retryScheduled = $true
                break
            }
            $finalState = 'manual_attention_required'
            $manualAttentionRequired = $true
            break
            }
            default {
                $finalState = [string]$waitResult.State
                break
            }
        }
    }

    if ($retryScheduled) {
        continue
    }

    break
}

$routerDispatchState = if ($visibleWorkerEnabled) {
    if (@($attemptResults).Count -gt 0) { [string]$attemptResults[-1].TransitionState } else { '' }
} else {
    if (Test-NonEmptyString $processedPath) { 'processed' } else { '' }
}
$submitState = ''
$submitConfirmed = $false
$submitReason = ''
if (-not $visibleWorkerEnabled -and $typedWindowExecutionState -eq 'typed-window-inline-prepare-blocked') {
    $submitState = 'failed'
    $submitConfirmed = $false
    $submitReason = if (Test-NonEmptyString $retryReason) { $retryReason } else { 'typed-window-inline-prepare-blocked' }
}
elseif (-not $visibleWorkerEnabled -and $typedWindowExecutionState -eq 'typed-window-visible-contract-failed') {
    $submitState = 'failed'
    $submitConfirmed = $false
    $submitReason = if (Test-NonEmptyString $retryReason) { $retryReason } else { 'visible-focus-steal' }
}
elseif ($null -ne $outboxResult -and [bool]$outboxResult.Published) {
    $submitState = 'confirmed'
    $submitConfirmed = $true
    $submitReason = 'outbox-publish-detected'
}
elseif (-not $visibleWorkerEnabled -and $typedWindowExecutionState -eq 'typed-window-running-confirmed') {
    $submitState = 'confirmed'
    $submitConfirmed = $true
    $submitReason = if (Test-NonEmptyString $submitConfirmationSignal) {
        ('typed-window-running-confirmed:' + $submitConfirmationSignal)
    }
    else {
        'typed-window-running-confirmed'
    }
}
elseif (-not $visibleWorkerEnabled -and $typedWindowExecutionState -in @('typed-window-possible-running', 'typed-window-running-no-artifact')) {
    $submitState = 'possible-running'
    $submitConfirmed = $false
    $submitReason = if (Test-NonEmptyString $submitConfirmationSignal) {
        ('typed-window-possible-running:' + $submitConfirmationSignal)
    }
    else {
        'typed-window-possible-running'
    }
}
elseif ($finalState -eq 'submit-unconfirmed') {
    $submitState = 'unconfirmed'
    if (-not $visibleWorkerEnabled -and $submitProbeState -in @('typed-window-submit-unconfirmed', 'typed-window-stalled-after-submit')) {
        $submitReason = $submitProbeState
    }
    else {
        $submitReason = if ($visibleWorkerEnabled) { 'no-outbox-publish-after-visible-worker' } else { 'no-outbox-publish-within-wait-window' }
    }
}
elseif ($finalState -in @('timeout', 'worker-not-ready', 'dispatch-accepted-stale', 'dispatch-running-stale-no-heartbeat')) {
    $submitState = 'unconfirmed'
    $submitReason = if ($finalState -eq 'timeout' -and $visibleWorkerEnabled) { 'visible-worker-dispatch-timeout' } else { $finalState }
}
elseif ($finalState -eq 'processed') {
    $submitState = 'unknown'
    $submitReason = 'router-processed-without-publish-check'
}
elseif ($visibleWorkerEnabled -and $finalState -in @('accepted', 'running', 'completed')) {
    $submitState = 'unknown'
    $submitReason = 'visible-worker-dispatch-without-publish-check'
}
$outboxPublished = if ($null -ne $outboxResult) { [bool]$outboxResult.Published } else { $false }
$outboxObservedAt = if ($outboxPublished) { (Get-Date).ToString('o') } else { '' }
$lateVisibleWorkerSuccess = $null
if ($visibleWorkerEnabled) {
    $lateVisibleWorkerSuccess = Resolve-VisibleWorkerLateSuccess `
        -TargetRow $targetRow `
        -CurrentFinalState $finalState `
        -CurrentSubmitState $submitState `
        -CurrentSubmitConfirmed $submitConfirmed `
        -CurrentSubmitReason $submitReason `
        -DispatchPath $workerDispatchPath `
        -CommandId $workerCommandId
    if ([bool]$lateVisibleWorkerSuccess.Superseded) {
        $finalState = [string]$lateVisibleWorkerSuccess.FinalState
        $submitState = [string]$lateVisibleWorkerSuccess.SubmitState
        $submitConfirmed = [bool]$lateVisibleWorkerSuccess.SubmitConfirmed
        $submitReason = [string]$lateVisibleWorkerSuccess.SubmitReason
        $outboxResult = $lateVisibleWorkerSuccess.OutboxResult
        $outboxPublished = [bool]$outboxResult.Published
        $outboxObservedAt = if ($outboxPublished) { (Get-Date).ToString('o') } else { '' }
    }
}
elseif ($null -ne $typedWindowSession -or -not $visibleWorkerEnabled) {
    $lateTypedWindowSuccess = Resolve-TypedWindowLateSuccess `
        -TargetRow $targetRow `
        -CurrentFinalState $finalState `
        -CurrentSubmitState $submitState `
        -CurrentSubmitConfirmed $submitConfirmed `
        -CurrentSubmitReason $submitReason `
        -CurrentTypedWindowExecutionState $typedWindowExecutionState `
        -CurrentSubmitProbeState $submitProbeState `
        -CurrentSubmitConfirmationSignal $submitConfirmationSignal
    if ([bool]$lateTypedWindowSuccess.Superseded) {
        $finalState = [string]$lateTypedWindowSuccess.FinalState
        $submitState = [string]$lateTypedWindowSuccess.SubmitState
        $submitConfirmed = [bool]$lateTypedWindowSuccess.SubmitConfirmed
        $submitReason = [string]$lateTypedWindowSuccess.SubmitReason
        $typedWindowExecutionState = [string]$lateTypedWindowSuccess.TypedWindowExecutionState
        $submitProbeState = [string]$lateTypedWindowSuccess.SubmitProbeState
        $submitConfirmationSignal = [string]$lateTypedWindowSuccess.SubmitConfirmationSignal
        $outboxResult = $lateTypedWindowSuccess.OutboxResult
        $outboxPublished = [bool]$outboxResult.Published
        $outboxObservedAt = if ($outboxPublished) { (Get-Date).ToString('o') } else { '' }
    }

    if ($null -eq $typedWindowSession) {
        $typedWindowSession = Read-TypedWindowSessionState -Config $config -TargetKey $targetKey
    }

    if ($outboxPublished) {
        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'running-confirmed'
        $typedWindowSession.LastProgressAt = (Get-Date).ToString('o')
        $typedWindowSession.LastConfirmedArtifactAt = (Get-Date).ToString('o')
        $typedWindowSession.ConsecutiveSubmitUnconfirmedCount = 0
    }
    elseif ($finalState -eq 'submit-unconfirmed') {
        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'recovery-needed'
        $typedWindowSession.LastResetReason = 'typed-window-submit-unconfirmed'
        $typedWindowSession.ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $typedWindowSession -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0) + 1
    }
    elseif ($typedWindowExecutionState -eq 'typed-window-inline-prepare-blocked') {
        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'recovery-needed'
        $typedWindowSession.LastResetReason = 'typed-window-inline-prepare-blocked'
        $typedWindowSession.ConsecutiveSubmitUnconfirmedCount = [int](Get-ConfigValue -Object $typedWindowSession -Name 'ConsecutiveSubmitUnconfirmedCount' -DefaultValue 0) + 1
    }
    elseif ($finalState -in @('failed', 'manual_attention_required')) {
        $typedWindowSession = Set-TypedWindowSessionFields -Session $typedWindowSession -State 'dirty-session'
        if ($typedWindowExecutionState -eq 'typed-window-visible-contract-failed') {
            $typedWindowSession.LastResetReason = 'focus-steal-before-submit'
        }
        else {
            $typedWindowSession.LastResetReason = if ($finalState -eq 'failed') { 'typed-window-failed' } else { 'typed-window-manual-attention' }
        }
    }

    Save-TypedWindowSessionState -Config $config -TargetKey $targetKey -Session $typedWindowSession
    $typedWindowSessionState = [string](Get-ConfigValue -Object $typedWindowSession -Name 'State' -DefaultValue '')
    $typedWindowLastResetReason = [string](Get-ConfigValue -Object $typedWindowSession -Name 'LastResetReason' -DefaultValue '')
}
$lastReadyPath = if (@($attemptResults).Count -gt 0) { [string]$attemptResults[-1].ReadyPath } else { '' }
$lastReadyBaseName = if (@($attemptResults).Count -gt 0) { [string]$attemptResults[-1].ReadyBaseName } else { '' }

$result = [pscustomobject]@{
    RunRoot = $resolvedRunRoot
    ConfigPath = $resolvedConfigPath
    ExecutionPathMode = $executionPathMode
    UserVisibleCellExecutionRequired = $requireUserVisibleCellExecution
    AllowedWindowVisibilityMethods = @($allowedWindowVisibilityMethods)
    SubmitRetryModes = @($submitRetryModes)
    SubmitRetrySequenceSummary = $submitRetrySequenceSummary
    PrimarySubmitMode = $primarySubmitMode
    FinalSubmitMode = $finalSubmitMode
    SubmitRetryIntervalMs = $submitRetryIntervalMs
    TypedWindowExecutionState = $typedWindowExecutionState
    SubmitProbeState = $submitProbeState
    SubmitProbeElapsedSeconds = $submitProbeElapsedSeconds
    SubmitRetryCount = $submitRetryCount
    SubmitConfirmationSignal = $submitConfirmationSignal
    TypedWindowSessionState = $typedWindowSessionState
    TypedWindowLastResetReason = $typedWindowLastResetReason
    TargetId = $targetKey
    FinalState = $finalState
    RouterDispatchState = $routerDispatchState
    SubmitState = $submitState
    SubmitConfirmed = $submitConfirmed
    SubmitReason = $submitReason
    RetryReason = $retryReason
    ManualAttentionRequired = $manualAttentionRequired
    MaxAttempts = $MaxAttempts
    AttemptCount = @($attemptResults).Count
    FirstAttemptedAt = $firstAttemptedAt
    LastAttemptedAt = $lastAttemptedAt
    NextRetryAt = $nextRetryAt
    BackoffMs = $backoffMs
    ProcessedPath = $processedPath
    FailedPath = $failedPath
    RetryPendingPath = $retryPendingPath
    SourceOutboxPath = [string]$targetRow.SourceOutboxPath
    SourceSummaryPath = [string]$targetRow.SourceSummaryPath
    SourceReviewZipPath = [string]$targetRow.SourceReviewZipPath
    PublishReadyPath = [string]$targetRow.PublishReadyPath
    OutboxPublished = $outboxPublished
    MessageTextFilePath = $resolvedMessageTextFilePath
    CommandId = $workerCommandId
    DispatchPath = $workerDispatchPath
    TransportMode = if ($visibleWorkerEnabled) { 'visible-worker' } else { 'router-ready-file' }
    Attempts = @($attemptResults)
}
Set-SeedSendStatusEntry -State $seedSendState `
    -TargetKey $targetKey `
    -UpdatedAt (Get-Date).ToString('o') `
    -FinalState $finalState `
    -ExecutionPathMode $executionPathMode `
    -UserVisibleCellExecutionRequired $requireUserVisibleCellExecution `
    -AllowedWindowVisibilityMethods @($allowedWindowVisibilityMethods) `
    -RouterDispatchState $routerDispatchState `
    -SubmitState $submitState `
    -SubmitConfirmed $submitConfirmed `
    -SubmitReason $submitReason `
    -SubmitRetryModes @($submitRetryModes) `
    -SubmitRetrySequenceSummary $submitRetrySequenceSummary `
    -PrimarySubmitMode $primarySubmitMode `
    -FinalSubmitMode $finalSubmitMode `
    -SubmitRetryIntervalMs $submitRetryIntervalMs `
    -AttemptCount @($attemptResults).Count `
    -MaxAttempts $MaxAttempts `
    -FirstAttemptedAt $firstAttemptedAt `
    -LastAttemptedAt $lastAttemptedAt `
    -NextRetryAt $nextRetryAt `
    -BackoffMs $backoffMs `
    -RetryReason $retryReason `
    -ManualAttentionRequired $manualAttentionRequired `
    -ProcessedPath $processedPath `
    -ProcessedAt $processedAt `
    -FailedPath $failedPath `
    -FailedAt $failedAt `
    -RetryPendingPath $retryPendingPath `
    -RetryPendingAt $retryPendingAt `
    -OutboxPublished ([bool]$result.OutboxPublished) `
    -OutboxObservedAt $outboxObservedAt `
    -LastReadyPath $lastReadyPath `
    -LastReadyBaseName $lastReadyBaseName `
    -TypedWindowExecutionState $typedWindowExecutionState `
    -SubmitProbeState $submitProbeState `
    -SubmitProbeElapsedSeconds $submitProbeElapsedSeconds `
    -SubmitRetryCount $submitRetryCount `
    -SubmitConfirmationSignal $submitConfirmationSignal `
    -TypedWindowSessionState $typedWindowSessionState `
    -TypedWindowLastResetReason $typedWindowLastResetReason
Save-SeedSendStatusState -Path $seedSendStatusPath -RunRoot $resolvedRunRoot -State $seedSendState

if ($AsJson) {
    Write-Output ($result | ConvertTo-Json -Depth 8)
}
else {
    Write-Output $result
}
