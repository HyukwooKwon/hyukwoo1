[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [string]$TargetId,
    [int]$MaxAttempts = 3,
    [int]$DelaySeconds = 5,
    [int[]]$RetryBackoffMs = @(),
    [int]$WaitForRouterSeconds = 20,
    [int]$WaitForPublishSeconds = 0,
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$RouterDispatchState,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubmitState,
        [Parameter(Mandatory)][bool]$SubmitConfirmed,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubmitReason,
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$LastReadyBaseName
    )

    $State[$TargetKey] = [pscustomobject]@{
        TargetId = $TargetKey
        UpdatedAt = $UpdatedAt
        FinalState = $FinalState
        RouterDispatchState = $RouterDispatchState
        SubmitState = $SubmitState
        SubmitConfirmed = $SubmitConfirmed
        SubmitReason = $SubmitReason
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

    if ($TimeoutSeconds -le 0) {
        return [pscustomobject]@{
            Published = $false
            SummaryPath = [string]$TargetRow.SourceSummaryPath
            ReviewZipPath = [string]$TargetRow.SourceReviewZipPath
            PublishReadyPath = [string]$TargetRow.PublishReadyPath
        }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $summaryPath = [string]$TargetRow.SourceSummaryPath
    $reviewZipPath = [string]$TargetRow.SourceReviewZipPath
    $publishReadyPath = [string]$TargetRow.PublishReadyPath
    $publishedArchivePath = [string]$TargetRow.PublishedArchivePath
    while ((Get-Date) -lt $deadline) {
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

        Start-Sleep -Milliseconds 500
    }

    return [pscustomobject]@{
        Published = $false
        SummaryPath = $summaryPath
        ReviewZipPath = $reviewZipPath
        PublishReadyPath = $publishReadyPath
    }
}

$root = Split-Path -Parent $PSScriptRoot
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
$targetRow = Resolve-TargetManifestRow -Manifest $manifest -TargetId $TargetId
$targetKey = [string]$targetRow.TargetId
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

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $readyPath = ''
    $producerOutput = ''
    $baseName = ''
    $requeued = $false
    $retryScheduled = $false
    $attemptedAt = (Get-Date).ToString('o')
    if (-not (Test-NonEmptyString $firstAttemptedAt)) {
        $firstAttemptedAt = $attemptedAt
    }
    $lastAttemptedAt = $attemptedAt
    $nextRetryAt = ''
    $backoffMs = 0

    if ($requireUserIdleBeforeSend -and $minUserIdleBeforeSendMs -gt 0 -and $seedWaitForUserIdleTimeoutSeconds -gt 0) {
        $idleWaitResult = Wait-ForUserIdle -RequiredIdleMs $minUserIdleBeforeSendMs -TimeoutSeconds $seedWaitForUserIdleTimeoutSeconds
        if (-not [bool]$idleWaitResult.Satisfied) {
            $retryReason = 'user-idle-timeout'
            $finalState = 'manual_attention_required'
            $manualAttentionRequired = $true
            break
        }
    }

    if ($attempt -eq 1) {
        $seedRaw = & (Join-Path $root 'tests\Send-InitialPairSeed.ps1') `
            -ConfigPath $resolvedConfigPath `
            -RunRoot $resolvedRunRoot `
            -TargetId $targetKey `
            -AsJson
        $seedResult = $seedRaw | ConvertFrom-Json
        $seedRow = @($seedResult.Results | Where-Object { [string]$_.TargetId -eq $targetKey } | Select-Object -First 1)
        if ($seedRow.Count -eq 0) {
            throw "seed enqueue returned no result row for target: $targetKey"
        }

        $readyPath = [string]$seedRow[0].ReadyPath
        $producerOutput = [string]$seedRow[0].ProducerOutput
        if (-not (Test-NonEmptyString $readyPath)) {
            throw "seed enqueue returned empty ready path for target: $targetKey output=$producerOutput"
        }
        $baseName = [System.IO.Path]::GetFileName($readyPath)
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

    $waitResult = Wait-ForMessageTransition `
        -BaseName $baseName `
        -InboxRoot $inboxRoot `
        -ProcessedRoot $processedRoot `
        -FailedRoot $failedRoot `
        -RetryPendingRoot $retryPendingRoot `
        -TimeoutSeconds $WaitForRouterSeconds

    $attemptResults += [pscustomobject]@{
        Attempt = $attempt
        TargetId = $targetKey
        ReadyPath = $readyPath
        ReadyBaseName = $baseName
        Requeued = $requeued
        ProducerOutput = $producerOutput
        TransitionState = [string]$waitResult.State
        TransitionPath = [string]$waitResult.Path
    }

    switch ([string]$waitResult.State) {
        'processed' {
            $finalState = 'processed'
            $processedPath = [string]$waitResult.Path
            if (Test-Path -LiteralPath $processedPath -PathType Leaf) {
                $processedAt = (Get-Item -LiteralPath $processedPath -ErrorAction Stop).LastWriteTime.ToString('o')
            }
            $processedItem = Get-Item -LiteralPath $processedPath -ErrorAction SilentlyContinue
            $referenceTime = if ($null -ne $processedItem) { $processedItem.LastWriteTime } else { Get-Date }
            $outboxResult = Wait-ForOutboxPublish -TargetRow $targetRow -TimeoutSeconds $WaitForPublishSeconds -ReferenceTime $referenceTime
            if ($outboxResult.Published) {
                $finalState = 'publish-detected'
            }
            elseif ($WaitForPublishSeconds -gt 0) {
                $finalState = 'submit-unconfirmed'
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
                    -RouterDispatchState '' `
                    -SubmitState '' `
                    -SubmitConfirmed $false `
                    -SubmitReason '' `
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
                    -LastReadyBaseName $baseName
                Save-SeedSendStatusState -Path $seedSendStatusPath -RunRoot $resolvedRunRoot -State $seedSendState
                Start-Sleep -Milliseconds $backoffMs
                $retryScheduled = $true
                break
            }
            $finalState = 'manual_attention_required'
            $manualAttentionRequired = $true
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
        default {
            $finalState = [string]$waitResult.State
            break
        }
    }

    if ($retryScheduled) {
        continue
    }

    break
}

$routerDispatchState = if (Test-NonEmptyString $processedPath) { 'processed' } else { '' }
$submitState = ''
$submitConfirmed = $false
$submitReason = ''
if ($null -ne $outboxResult -and [bool]$outboxResult.Published) {
    $submitState = 'confirmed'
    $submitConfirmed = $true
    $submitReason = 'outbox-publish-detected'
}
elseif ($finalState -eq 'submit-unconfirmed') {
    $submitState = 'unconfirmed'
    $submitReason = 'no-outbox-publish-within-wait-window'
}
elseif ($finalState -eq 'processed') {
    $submitState = 'unknown'
    $submitReason = 'router-processed-without-publish-check'
}
$outboxPublished = if ($null -ne $outboxResult) { [bool]$outboxResult.Published } else { $false }
$outboxObservedAt = if ($outboxPublished) { (Get-Date).ToString('o') } else { '' }
$lastReadyPath = if (@($attemptResults).Count -gt 0) { [string]$attemptResults[-1].ReadyPath } else { '' }
$lastReadyBaseName = if (@($attemptResults).Count -gt 0) { [string]$attemptResults[-1].ReadyBaseName } else { '' }

$result = [pscustomobject]@{
    RunRoot = $resolvedRunRoot
    ConfigPath = $resolvedConfigPath
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
    Attempts = @($attemptResults)
}
Set-SeedSendStatusEntry -State $seedSendState `
    -TargetKey $targetKey `
    -UpdatedAt (Get-Date).ToString('o') `
    -FinalState $finalState `
    -RouterDispatchState $routerDispatchState `
    -SubmitState $submitState `
    -SubmitConfirmed $submitConfirmed `
    -SubmitReason $submitReason `
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
    -LastReadyBaseName $lastReadyBaseName
Save-SeedSendStatusState -Path $seedSendStatusPath -RunRoot $resolvedRunRoot -State $seedSendState

if ($AsJson) {
    Write-Output ($result | ConvertTo-Json -Depth 8)
}
else {
    Write-Output $result
}
