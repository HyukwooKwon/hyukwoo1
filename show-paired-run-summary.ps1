[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [int]$RecentFailureCount = 10,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = ''
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Read-JsonObjectSafe {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not (Test-NonEmptyString $raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function Test-SuccessAcceptanceState {
    param([string]$AcceptanceState)

    return ($AcceptanceState -in @('roundtrip-confirmed', 'first-handoff-confirmed'))
}

function Get-AcceptanceSummary {
    param(
        $AcceptanceReceipt,
        $Status
    )

    $acceptanceOutcome = Get-ObjectPropertyValue -Object $AcceptanceReceipt -Name 'Outcome' -DefaultValue $null
    $rawStage = [string](Get-ObjectPropertyValue -Object $AcceptanceReceipt -Name 'Stage' -DefaultValue '')
    $rawAcceptanceState = if ($null -ne $acceptanceReceipt) { [string](Get-ObjectPropertyValue -Object $acceptanceOutcome -Name 'AcceptanceState' -DefaultValue '') } else { [string]$Status.AcceptanceReceipt.AcceptanceState }
    $rawAcceptanceReason = if ($null -ne $acceptanceReceipt) { [string](Get-ObjectPropertyValue -Object $acceptanceOutcome -Name 'AcceptanceReason' -DefaultValue '') } else { [string]$Status.AcceptanceReceipt.AcceptanceReason }
    $rawSeed = Get-ObjectPropertyValue -Object $AcceptanceReceipt -Name 'Seed' -DefaultValue $null
    $rawSeedFinalState = if ($null -ne $acceptanceReceipt) { [string](Get-ObjectPropertyValue -Object $rawSeed -Name 'FinalState' -DefaultValue '') } else { '' }
    $rawSeedSubmitState = if ($null -ne $acceptanceReceipt) { [string](Get-ObjectPropertyValue -Object $rawSeed -Name 'SubmitState' -DefaultValue '') } else { '' }
    $rawSeedOutboxPublished = if ($null -ne $acceptanceReceipt) { [bool](Get-ObjectPropertyValue -Object $rawSeed -Name 'OutboxPublished' -DefaultValue $false) } else { $false }

    $effectiveEntry = $null
    $phaseHistoryEntries = @((Get-ObjectPropertyValue -Object $AcceptanceReceipt -Name 'PhaseHistory' -DefaultValue @()))
    for ($index = $phaseHistoryEntries.Count - 1; $index -ge 0; $index--) {
        $entry = $phaseHistoryEntries[$index]
        if ($null -eq $entry) {
            continue
        }

        $entryState = [string](Get-ObjectPropertyValue -Object $entry -Name 'AcceptanceState' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($entryState) -or $entryState -eq 'preflight-passed') {
            continue
        }

        $effectiveEntry = $entry
        break
    }

    $effectiveStage = $rawStage
    $effectiveAcceptanceState = $rawAcceptanceState
    $effectiveAcceptanceReason = $rawAcceptanceReason
    $effectiveSeedFinalState = $rawSeedFinalState
    $effectiveSeedSubmitState = $rawSeedSubmitState
    $effectiveSeedOutboxPublished = $rawSeedOutboxPublished
    $effectiveRecordedAt = ''
    $effectiveSource = 'current-receipt'

    if ($null -ne $effectiveEntry) {
        $effectiveStage = [string](Get-ObjectPropertyValue -Object $effectiveEntry -Name 'Stage' -DefaultValue $effectiveStage)
        $effectiveAcceptanceState = [string](Get-ObjectPropertyValue -Object $effectiveEntry -Name 'AcceptanceState' -DefaultValue $effectiveAcceptanceState)
        $effectiveAcceptanceReason = [string](Get-ObjectPropertyValue -Object $effectiveEntry -Name 'AcceptanceReason' -DefaultValue $effectiveAcceptanceReason)
        $effectiveSeedFinalState = [string](Get-ObjectPropertyValue -Object $effectiveEntry -Name 'SeedFinalState' -DefaultValue $effectiveSeedFinalState)
        $effectiveSeedSubmitState = [string](Get-ObjectPropertyValue -Object $effectiveEntry -Name 'SeedSubmitState' -DefaultValue $effectiveSeedSubmitState)
        $effectiveSeedOutboxPublished = [bool](Get-ObjectPropertyValue -Object $effectiveEntry -Name 'SeedOutboxPublished' -DefaultValue $effectiveSeedOutboxPublished)
        $effectiveRecordedAt = [string](Get-ObjectPropertyValue -Object $effectiveEntry -Name 'RecordedAt' -DefaultValue '')
        $effectiveSource = 'phase-history'
    }

    return [pscustomobject]@{
        Exists                  = ($null -ne $acceptanceReceipt)
        Path                    = [string]$Status.AcceptanceReceipt.Path
        Stage                   = $effectiveStage
        AcceptanceState         = $effectiveAcceptanceState
        AcceptanceReason        = $effectiveAcceptanceReason
        SeedFinalState          = $effectiveSeedFinalState
        SeedSubmitState         = $effectiveSeedSubmitState
        SeedOutboxPublished     = $effectiveSeedOutboxPublished
        CurrentStage            = $rawStage
        CurrentAcceptanceState  = $rawAcceptanceState
        CurrentAcceptanceReason = $rawAcceptanceReason
        CurrentSeedFinalState   = $rawSeedFinalState
        CurrentSeedSubmitState  = $rawSeedSubmitState
        CurrentSeedOutboxPublished = $rawSeedOutboxPublished
        EffectiveRecordedAt     = $effectiveRecordedAt
        EffectiveSource         = $effectiveSource
    }
}

function Get-OverallState {
    param(
        $AcceptanceSummary,
        $Status
    )

    $acceptanceStage = [string](Get-ObjectPropertyValue -Object $AcceptanceSummary -Name 'Stage' -DefaultValue '')
    $acceptanceState = [string](Get-ObjectPropertyValue -Object $AcceptanceSummary -Name 'AcceptanceState' -DefaultValue '')
    $failureCount = [int]$Status.Counts.FailureLineCount
    $manualAttentionCount = [int]$Status.Counts.ManualAttentionCount
    $submitUnconfirmedCount = [int]$Status.Counts.SubmitUnconfirmedCount
    $targetUnresponsiveCount = [int]$Status.Counts.TargetUnresponsiveCount

    if ($acceptanceStage -eq 'completed' -and (Test-SuccessAcceptanceState -AcceptanceState $acceptanceState)) {
        return 'success'
    }

    if (
        $acceptanceStage -in @('failed', 'seed-publish-missing', 'acceptance-failed') -or
        $acceptanceState -in @('error', 'manual_attention_required', 'submit-unconfirmed', 'target-unresponsive-after-send', 'seed-send-failed', 'seed-send-timeout', 'first-handoff-timeout', 'roundtrip-timeout') -or
        $failureCount -gt 0 -or
        $manualAttentionCount -gt 0 -or
        $submitUnconfirmedCount -gt 0 -or
        $targetUnresponsiveCount -gt 0
    ) {
        return 'failing'
    }

    return 'in-progress'
}

function Read-ConfigObjectSafe {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Import-PowerShellDataFile -Path $Path)
    }
    catch {
        return $null
    }
}

function Normalize-DisplayPath {
    param([string]$Path)

    $value = [string]$Path
    if (-not (Test-NonEmptyString $value)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($value)
    }
    catch {
        return ($value -replace '\\\\', '\')
    }
}

function ConvertTo-UtcDateTimeOrNull {
    param([string]$Value)

    $text = [string]$Value
    if (-not (Test-NonEmptyString $text)) {
        return $null
    }

    try {
        return [System.DateTimeOffset]::Parse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    }
    catch {
        try {
            return [System.DateTimeOffset]::Parse(
                $text,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal
            ).ToUniversalTime()
        }
        catch {
            return $null
        }
    }
}

function New-EventRecord {
    param(
        [string]$At,
        [string]$Text,
        [string]$Source = '',
        [int]$Priority = 50,
        [string]$EventClass = 'supporting-signal',
        [string]$PairId = '',
        [string]$TargetId = '',
        [bool]$IsProgressSignal = $false
    )

    if (-not (Test-NonEmptyString $Text)) {
        return $null
    }

    $timestamp = ConvertTo-UtcDateTimeOrNull -Value $At
    return [pscustomobject]@{
        At       = if ($null -ne $timestamp) { $timestamp.ToString('o') } else { [string]$At }
        SortTicks = if ($null -ne $timestamp) { [int64]$timestamp.UtcDateTime.Ticks } else { [int64]0 }
        Text     = $Text
        Source   = $Source
        Priority = $Priority
        EventClass = $EventClass
        PairId   = $PairId
        TargetId = $TargetId
        IsProgressSignal = $IsProgressSignal
    }
}

function Add-EventRecord {
    param(
        $List,
        [string]$At,
        [string]$Text,
        [string]$Source = '',
        [int]$Priority = 50,
        [string]$EventClass = 'supporting-signal',
        [string]$PairId = '',
        [string]$TargetId = '',
        [bool]$IsProgressSignal = $false
    )

    $record = New-EventRecord `
        -At $At `
        -Text $Text `
        -Source $Source `
        -Priority $Priority `
        -EventClass $EventClass `
        -PairId $PairId `
        -TargetId $TargetId `
        -IsProgressSignal:$IsProgressSignal
    if ($null -ne $record) {
        [void]$List.Add($record)
    }
}

function Get-FileSnapshot {
    param([string]$Path)

    $normalizedPath = [string]$Path
    if (-not (Test-NonEmptyString $normalizedPath) -or -not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists      = $false
            Path        = $normalizedPath
            LastWriteAt = ''
            Length      = 0
        }
    }

    $item = Get-Item -LiteralPath $normalizedPath
    return [pscustomobject]@{
        Exists      = $true
        Path        = $item.FullName
        LastWriteAt = $item.LastWriteTime.ToString('o')
        Length      = [int64]$item.Length
    }
}

function Get-FilePreviewText {
    param(
        [string]$Path,
        [int]$MaxLines = 8,
        [int]$MaxChars = 1200
    )

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    try {
        $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount $MaxLines)
    }
    catch {
        return ''
    }

    $preview = (($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if (-not (Test-NonEmptyString $preview)) {
        return ''
    }

    if ($preview.Length -gt $MaxChars) {
        return ($preview.Substring(0, $MaxChars).TrimEnd() + ' ...')
    }

    return $preview
}

function Get-LatestMatchingFilePath {
    param(
        [string]$DirectoryPath,
        [string]$Filter = '*.log'
    )

    if (-not (Test-NonEmptyString $DirectoryPath) -or -not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        return ''
    }

    $latest = Get-ChildItem -LiteralPath $DirectoryPath -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        return ''
    }

    return $latest.FullName
}

function Get-StatusTargetLookup {
    param([object[]]$Targets)

    $lookup = @{}
    foreach ($target in @($Targets)) {
        if ($null -eq $target) {
            continue
        }

        $targetId = [string](Get-ObjectPropertyValue -Object $target -Name 'TargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            continue
        }

        $lookup[$targetId] = $target
    }

    return $lookup
}

function Get-ManifestSummary {
    param([string]$RunRoot)

    $manifestPath = Join-Path $RunRoot 'manifest.json'
    $manifest = Read-JsonObjectSafe -Path $manifestPath
    $targets = @()
    if ($null -ne $manifest) {
        $targets = @((Get-ObjectPropertyValue -Object $manifest -Name 'Targets' -DefaultValue @()))
    }

    return [pscustomobject]@{
        Exists   = ($null -ne $manifest)
        Path     = $manifestPath
        Data     = $manifest
        Targets  = $targets
    }
}

function Get-ContractSummary {
    param($AcceptanceReceipt)

    $contract = Get-ObjectPropertyValue -Object $AcceptanceReceipt -Name 'Contract' -DefaultValue $null
    if ($null -eq $contract) {
        return [pscustomobject]@{
            PrimaryContractExternalized = $false
            ExternalRunRootUsed         = $false
            BookkeepingExternalized     = $false
            FullExternalized            = $false
            InternalResidualRoots       = @()
            Targets                     = @()
        }
    }

    return [pscustomobject]@{
        PrimaryContractExternalized = [bool](Get-ObjectPropertyValue -Object $contract -Name 'PrimaryContractExternalized' -DefaultValue $false)
        ExternalRunRootUsed         = [bool](Get-ObjectPropertyValue -Object $contract -Name 'ExternalRunRootUsed' -DefaultValue $false)
        BookkeepingExternalized     = [bool](Get-ObjectPropertyValue -Object $contract -Name 'BookkeepingExternalized' -DefaultValue $false)
        FullExternalized            = [bool](Get-ObjectPropertyValue -Object $contract -Name 'FullExternalized' -DefaultValue $false)
        InternalResidualRoots       = @((Get-ObjectPropertyValue -Object $contract -Name 'InternalResidualRoots' -DefaultValue @()))
        Targets                     = @((Get-ObjectPropertyValue -Object $contract -Name 'Targets' -DefaultValue @()))
    }
}

function Format-InternalResidualRootsDisplay {
    param([object[]]$Items)

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Items)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [string]) {
            if (Test-NonEmptyString $item) {
                $tokens.Add($item)
            }
            continue
        }

        $name = [string](Get-ObjectPropertyValue -Object $item -Name 'Name' -DefaultValue '')
        $path = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $item -Name 'Path' -DefaultValue ''))
        if (Test-NonEmptyString $name -and Test-NonEmptyString $path) {
            $tokens.Add(('{0}={1}' -f $name, $path))
        }
        elseif (Test-NonEmptyString $name) {
            $tokens.Add($name)
        }
        elseif (Test-NonEmptyString $path) {
            $tokens.Add($path)
        }
    }

    return @($tokens)
}

function Get-ImportantTargetSummary {
    param(
        $ManifestTarget,
        $StatusTarget,
        [string]$LogsRoot = ''
    )

    $targetId = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'TargetId' -DefaultValue '')
    if (-not (Test-NonEmptyString $targetId)) {
        $targetId = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'TargetId' -DefaultValue '')
    }

    $messagePath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'MessagePath' -DefaultValue '')
    $requestPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'RequestPath' -DefaultValue '')
    $workRepoRoot = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'WorkRepoRoot' -DefaultValue '')
    $reviewInputPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'ReviewInputPath' -DefaultValue '')
    $processedPath = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'ProcessedPath' -DefaultValue '')
    $sourceSummaryPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'SourceSummaryPath' -DefaultValue '')
    $sourceReviewZipPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'SourceReviewZipPath' -DefaultValue '')
    $publishReadyPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'PublishReadyPath' -DefaultValue '')
    $initialRoleMode = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'InitialRoleMode' -DefaultValue '')
    $contractPathMode = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'ContractPathMode' -DefaultValue '')
    $contractRootPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'ContractRootPath' -DefaultValue '')
    $contractReferenceTimeUtc = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'ContractReferenceTimeUtc' -DefaultValue '')

    $latestPrepareLogPath = ''
    $latestAhkLogPath = ''
    if (Test-NonEmptyString $LogsRoot) {
        $latestPrepareLogPath = Get-LatestMatchingFilePath -DirectoryPath (Join-Path (Join-Path $LogsRoot 'typed-window-prepare') $targetId)
        $latestAhkLogPath = Get-LatestMatchingFilePath -DirectoryPath (Join-Path (Join-Path $LogsRoot 'ahk-debug') $targetId)
    }

    $sourceSummary = Get-FileSnapshot -Path $sourceSummaryPath
    $sourceReviewZip = Get-FileSnapshot -Path $sourceReviewZipPath
    $publishReady = Get-FileSnapshot -Path $publishReadyPath
    $messageFile = Get-FileSnapshot -Path $messagePath
    $requestFile = Get-FileSnapshot -Path $requestPath
    $processedFile = Get-FileSnapshot -Path $processedPath
    $processedPayloadSnapshotPath = if (Test-NonEmptyString $processedPath) { ($processedPath + '.payload.txt') } else { '' }
    $processedPayloadSnapshot = Get-FileSnapshot -Path $processedPayloadSnapshotPath
    $latestPrepareLog = Get-FileSnapshot -Path $latestPrepareLogPath
    $latestAhkLog = Get-FileSnapshot -Path $latestAhkLogPath
    $missingContractFiles = New-Object System.Collections.Generic.List[string]
    if (-not [bool]$sourceSummary.Exists) {
        $missingContractFiles.Add('summary.txt')
    }
    if (-not [bool]$sourceReviewZip.Exists) {
        $missingContractFiles.Add('review.zip')
    }
    if (-not [bool]$publishReady.Exists) {
        $missingContractFiles.Add('publish.ready.json')
    }

    return [pscustomobject]@{
        PairId             = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'PairId' -DefaultValue (Get-ObjectPropertyValue -Object $ManifestTarget -Name 'PairId' -DefaultValue ''))
        PartnerTargetId    = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'PartnerTargetId' -DefaultValue (Get-ObjectPropertyValue -Object $ManifestTarget -Name 'PartnerTargetId' -DefaultValue ''))
        TargetId           = $targetId
        RoleName           = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'RoleName' -DefaultValue (Get-ObjectPropertyValue -Object $ManifestTarget -Name 'RoleName' -DefaultValue ''))
        LatestState        = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'LatestState' -DefaultValue '')
        SourceOutboxState  = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SourceOutboxState' -DefaultValue '')
        SourceOutboxNextAction = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SourceOutboxNextAction' -DefaultValue '')
        SeedSendState      = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SeedSendState' -DefaultValue '')
        SubmitState        = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SubmitState' -DefaultValue '')
        DispatchState      = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'DispatchState' -DefaultValue '')
        ManualAttentionRequired = [bool](Get-ObjectPropertyValue -Object $StatusTarget -Name 'ManualAttentionRequired' -DefaultValue $false)
        FailureCount       = [int](Get-ObjectPropertyValue -Object $StatusTarget -Name 'FailureCount' -DefaultValue 0)
        DonePresent        = [bool](Get-ObjectPropertyValue -Object $StatusTarget -Name 'DonePresent' -DefaultValue $false)
        ResultPresent      = [bool](Get-ObjectPropertyValue -Object $StatusTarget -Name 'ResultPresent' -DefaultValue $false)
        ForwardedAt        = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'ForwardedAt' -DefaultValue '')
        SourceOutboxUpdatedAt = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SourceOutboxUpdatedAt' -DefaultValue '')
        InitialRoleMode    = $initialRoleMode
        ContractPathMode   = $contractPathMode
        ContractRootPath   = $contractRootPath
        ContractReferenceTimeUtc = $contractReferenceTimeUtc
        WorkRepoRoot       = $workRepoRoot
        ReviewInputPath    = $reviewInputPath
        MessagePath        = $messagePath
        MessageFile        = $messageFile
        MessagePreview     = Get-FilePreviewText -Path $messagePath
        RequestPath        = $requestPath
        RequestFile        = $requestFile
        ProcessedPath      = $processedPath
        ProcessedFile      = $processedFile
        ProcessedPayloadSnapshotPath = $processedPayloadSnapshotPath
        ProcessedPayloadSnapshot = $processedPayloadSnapshot
        ProcessedPayloadSnapshotPreview = Get-FilePreviewText -Path $processedPayloadSnapshotPath
        SourceSummary      = $sourceSummary
        SourceReviewZip    = $sourceReviewZip
        PublishReady       = $publishReady
        ContractArtifactsReady = ($missingContractFiles.Count -eq 0)
        MissingContractFiles = @($missingContractFiles)
        LatestPrepareLog   = $latestPrepareLog
        LatestPrepareLogPath = $latestPrepareLogPath
        LatestAhkLog       = $latestAhkLog
        LatestAhkLogPath   = $latestAhkLogPath
    }
}

function Get-ImportantPairSummaries {
    param($Status)

    $pairSummaries = @()
    foreach ($pair in @((Get-ObjectPropertyValue -Object $Status -Name 'Pairs' -DefaultValue @()))) {
        if ($null -eq $pair) {
            continue
        }

        $pairSummaries += [pscustomobject]@{
            PairId              = [string](Get-ObjectPropertyValue -Object $pair -Name 'PairId' -DefaultValue '')
            CurrentPhase        = [string](Get-ObjectPropertyValue -Object $pair -Name 'CurrentPhase' -DefaultValue '')
            NextAction          = [string](Get-ObjectPropertyValue -Object $pair -Name 'NextAction' -DefaultValue '')
            NextExpectedHandoff = [string](Get-ObjectPropertyValue -Object $pair -Name 'NextExpectedHandoff' -DefaultValue '')
            RoundtripCount      = [int](Get-ObjectPropertyValue -Object $pair -Name 'RoundtripCount' -DefaultValue 0)
            ForwardedStateCount = [int](Get-ObjectPropertyValue -Object $pair -Name 'ForwardedStateCount' -DefaultValue 0)
            HandoffReadyCount   = [int](Get-ObjectPropertyValue -Object $pair -Name 'HandoffReadyCount' -DefaultValue 0)
            ProgressDetail      = [string](Get-ObjectPropertyValue -Object $pair -Name 'ProgressDetail' -DefaultValue '')
        }
    }

    return @($pairSummaries)
}

function Get-FocusPairSummary {
    param(
        [object[]]$Pairs,
        [object[]]$Targets
    )

    $pairCandidates = @()
    foreach ($pair in @($Pairs)) {
        if ($null -eq $pair) {
            continue
        }

        $pairId = [string](Get-ObjectPropertyValue -Object $pair -Name 'PairId' -DefaultValue '')
        $pairTargets = if (Test-NonEmptyString $pairId) {
            @($Targets | Where-Object { [string](Get-ObjectPropertyValue -Object $_ -Name 'PairId' -DefaultValue '') -eq $pairId })
        }
        else {
            @()
        }

        $hasManualAttention = ((@($pairTargets | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name 'ManualAttentionRequired' -DefaultValue $false) })).Count -gt 0)
        $hasSubmitUnconfirmed = ((@($pairTargets | Where-Object {
                        [string](Get-ObjectPropertyValue -Object $_ -Name 'SubmitState' -DefaultValue '') -eq 'unconfirmed' -or
                        [string](Get-ObjectPropertyValue -Object $_ -Name 'SourceOutboxState' -DefaultValue '') -eq 'submit-unconfirmed' -or
                        [string](Get-ObjectPropertyValue -Object $_ -Name 'SeedSendState' -DefaultValue '') -in @('submit-unconfirmed', 'timeout')
                    })).Count -gt 0)
        $hasTargetUnresponsive = ((@($pairTargets | Where-Object {
                        [string](Get-ObjectPropertyValue -Object $_ -Name 'SourceOutboxState' -DefaultValue '') -eq 'target-unresponsive-after-send' -or
                        [string](Get-ObjectPropertyValue -Object $_ -Name 'LatestState' -DefaultValue '') -eq 'target-unresponsive-after-send'
                    })).Count -gt 0)
        $hasContractIncomplete = ((@($pairTargets | Where-Object {
                        -not [bool](Get-ObjectPropertyValue -Object $_ -Name 'ContractArtifactsReady' -DefaultValue $false)
                    })).Count -gt 0)
        $hasNextAction = (
            (Test-NonEmptyString ([string](Get-ObjectPropertyValue -Object $pair -Name 'NextAction' -DefaultValue ''))) -or
            (Test-NonEmptyString ([string](Get-ObjectPropertyValue -Object $pair -Name 'CurrentPhase' -DefaultValue '')))
        )

        $priority = 4
        if ($hasManualAttention) {
            $priority = 0
        }
        elseif ($hasSubmitUnconfirmed -or $hasTargetUnresponsive) {
            $priority = 1
        }
        elseif ($hasContractIncomplete) {
            $priority = 2
        }
        elseif ($hasNextAction) {
            $priority = 3
        }

        $pairCandidates += [pscustomobject]@{
            Pair     = $pair
            PairId   = $pairId
            Priority = $priority
        }
    }

    $selected = @(
        @($pairCandidates) |
            Sort-Object `
                @{ Expression = { [int](Get-ObjectPropertyValue -Object $_ -Name 'Priority' -DefaultValue 99) } }, `
                @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -Name 'PairId' -DefaultValue '') } } |
            Select-Object -First 1
    )
    if ($selected.Count -eq 0) {
        return $null
    }

    return $selected[0].Pair
}

function Get-OperatorFocusSummary {
    param(
        [string]$OverallState,
        $AcceptanceSummary,
        $WatcherSummary,
        $CountsSummary,
        [object[]]$Pairs,
        [object[]]$Targets
    )

    $focusPair = Get-FocusPairSummary -Pairs @($Pairs) -Targets @($Targets)

    $focusPairId = if ($null -ne $focusPair) { [string](Get-ObjectPropertyValue -Object $focusPair -Name 'PairId' -DefaultValue '') } else { '' }
    $pairPhase = if ($null -ne $focusPair) { [string](Get-ObjectPropertyValue -Object $focusPair -Name 'CurrentPhase' -DefaultValue '') } else { '' }
    $pairNextAction = if ($null -ne $focusPair) { [string](Get-ObjectPropertyValue -Object $focusPair -Name 'NextAction' -DefaultValue '') } else { '' }
    $nextExpectedHandoff = if ($null -ne $focusPair) { [string](Get-ObjectPropertyValue -Object $focusPair -Name 'NextExpectedHandoff' -DefaultValue '') } else { '' }

    $readyTargets = @(
        @($Targets) |
            Where-Object {
                [bool](Get-ObjectPropertyValue -Object $_ -Name 'ContractArtifactsReady' -DefaultValue $false)
            }
    )
    $incompleteTargets = @(
        @($Targets) |
            Where-Object {
                -not [bool](Get-ObjectPropertyValue -Object $_ -Name 'ContractArtifactsReady' -DefaultValue $false)
            }
    )
    $incompleteTargetIds = @(
        $incompleteTargets |
            ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name 'TargetId' -DefaultValue '') } |
            Where-Object { Test-NonEmptyString $_ }
    )

    $attentionLevel = 'watch'
    $bottleneckCode = 'in-progress'
    $bottleneck = 'run is still in progress'
    $nextStep = 'monitor watcher status and contract artifact changes'
    $recommendedAction = 'open important-summary.txt and verify payload preview, contract paths, and latest logs'

    if ($OverallState -eq 'success') {
        $attentionLevel = 'ok'
        $bottleneckCode = 'none'
        $bottleneck = 'no active bottleneck; acceptance completed successfully'
        $nextStep = 'none; final relay sequence already completed'
        $recommendedAction = 'open final summary/review artifacts only if a manual spot check is needed'
    }
    elseif ([int]$CountsSummary.ManualAttentionCount -gt 0 -or [string]$AcceptanceSummary.AcceptanceState -eq 'manual_attention_required') {
        $attentionLevel = 'action-required'
        $bottleneckCode = 'manual-attention-required'
        $bottleneck = 'manual attention is required for at least one target'
        $nextStep = 'resolve the blocked target before continuing pair orchestration'
        $recommendedAction = 'inspect target LatestState, LatestPrepareLogPath, LatestAhkLogPath, and recent failures first'
    }
    elseif ([int]$CountsSummary.TargetUnresponsiveCount -gt 0 -or [string]$AcceptanceSummary.AcceptanceState -eq 'target-unresponsive-after-send') {
        $attentionLevel = 'action-required'
        $bottleneckCode = 'target-unresponsive-after-send'
        $bottleneck = 'a target stopped responding after submit'
        $nextStep = 'recover target responsiveness before sending the next payload'
        $recommendedAction = 'verify foreground focus policy, target window health, and router/AHK logs'
    }
    elseif ([string]$AcceptanceSummary.Stage -eq 'seed-publish-missing' -or [string]$AcceptanceSummary.AcceptanceState -eq 'seed-send-timeout') {
        $attentionLevel = 'action-required'
        $bottleneckCode = 'seed-publish-missing'
        $bottleneck = 'seed payload was not observed at the source-outbox publish stage'
        if ([int]$CountsSummary.SubmitUnconfirmedCount -gt 0) {
            $bottleneck += ' (submit evidence is also unconfirmed)'
        }
        $nextStep = 'typed-window -> router/AHK -> source-outbox publish must complete for the seed target'
        $recommendedAction = 'check the seed target message preview, request path, router.log, and prepare/AHK logs'
    }
    elseif ([int]$CountsSummary.SubmitUnconfirmedCount -gt 0 -or [string]$AcceptanceSummary.AcceptanceState -eq 'submit-unconfirmed') {
        $attentionLevel = 'action-required'
        $bottleneckCode = 'typed-window-submit-unconfirmed'
        $bottleneck = 'typed-window submit was not confirmed'
        $nextStep = 'recovery or retry is required before the shared visible path can progress'
        $recommendedAction = 'check visible beacon, LatestPrepareLogPath, LatestAhkLogPath, and submit evidence before retry'
    }
    elseif ([int]$CountsSummary.FailureLineCount -gt 0) {
        $attentionLevel = 'action-required'
        $bottleneckCode = 'handoff-failure-lines'
        $bottleneck = 'handoff or publish failures are already recorded in the run'
        $nextStep = 'clear the recorded failure cause before expecting new contract artifacts'
        $recommendedAction = 'review recent failures plus target-specific logs before rerunning any send path'
    }
    elseif ($pairNextAction -eq 'handoff-ready' -or [int]$CountsSummary.ReadyToForwardCount -gt 0) {
        $attentionLevel = 'watch'
        $bottleneckCode = 'handoff-ready'
        $bottleneck = 'no hard blocker; handoff payload is ready to forward'
        $nextStep = if (Test-NonEmptyString $nextExpectedHandoff) { 'watcher forwards ' + $nextExpectedHandoff } else { 'watcher forwards the ready handoff payload' }
        $recommendedAction = 'keep watcher running and confirm the next forwarded event appears'
    }
    elseif ($pairNextAction -eq 'dispatch-running' -or [int]$CountsSummary.DispatchRunningCount -gt 0) {
        $attentionLevel = 'watch'
        $bottleneckCode = 'dispatch-running'
        $bottleneck = 'dispatch is still running; final publish evidence is not expected yet'
        $nextStep = 'wait for dispatch completion and the next contract artifact update'
        $recommendedAction = 'check dispatch status and latest target activity before intervening'
    }
    elseif ($pairNextAction -eq 'artifact-check-needed' -or $incompleteTargetIds.Count -gt 0) {
        $attentionLevel = 'watch'
        $bottleneckCode = 'contract-artifacts-missing'
        $missingLabel = if ($incompleteTargetIds.Count -gt 0) { $incompleteTargetIds -join ', ' } else { 'one or more targets' }
        $bottleneck = 'contract artifacts are incomplete for ' + $missingLabel
        $nextStep = 'summary.txt, review.zip, and publish.ready.json must all exist under each target source-outbox path'
        $recommendedAction = 'open the affected target block in important-summary.txt and verify the explicit source-outbox paths'
    }
    elseif ($pairNextAction -eq 'await-partner-output' -or [int]$CountsSummary.ForwardedCount -gt 0) {
        $attentionLevel = 'watch'
        $bottleneckCode = 'await-partner-output'
        $bottleneck = 'partner output has not been published yet'
        $nextStep = if (Test-NonEmptyString $nextExpectedHandoff) { 'wait for publish from ' + $nextExpectedHandoff } else { 'wait for the partner summary.txt / review.zip / publish.ready.json publish' }
        $recommendedAction = 'watch router.log and the partner source-outbox contract path instead of rerunning the seed blindly'
    }
    elseif ([string]$WatcherSummary.Status -in @('paused', 'stopped', 'stop_requested', 'stopping')) {
        $attentionLevel = 'watch'
        $bottleneckCode = 'watcher-not-running'
        $bottleneck = 'watcher status is ' + [string]$WatcherSummary.Status
        $nextStep = 'resume or restart the watcher if more relay progress is expected'
        $recommendedAction = 'confirm the current RunRoot and watcher control state before restarting'
    }

    return [pscustomobject]@{
        AttentionLevel          = $attentionLevel
        FocusPairId             = $focusPairId
        PairPhase               = $pairPhase
        PairNextAction          = $pairNextAction
        NextExpectedHandoff     = $nextExpectedHandoff
        CurrentBottleneckCode   = $bottleneckCode
        CurrentBottleneck       = $bottleneck
        NextExpectedStep        = $nextStep
        RecommendedAction       = $recommendedAction
        ContractReadyTargetCount = @($readyTargets).Count
        TotalTargetCount        = @($Targets).Count
        IncompleteTargetIds     = @($incompleteTargetIds)
    }
}

function Sort-ImportantPairSummaries {
    param(
        [object[]]$Pairs,
        [string]$FocusPairId = ''
    )

    return @(
        @($Pairs) |
            Sort-Object `
                @{ Expression = { if ((Test-NonEmptyString $FocusPairId) -and [string](Get-ObjectPropertyValue -Object $_ -Name 'PairId' -DefaultValue '') -eq $FocusPairId) { 0 } elseif (Test-NonEmptyString ([string](Get-ObjectPropertyValue -Object $_ -Name 'NextAction' -DefaultValue ''))) { 1 } else { 2 } } }, `
                @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -Name 'PairId' -DefaultValue '') } }
    )
}

function Sort-ImportantTargets {
    param(
        [object[]]$Targets,
        [string]$FocusPairId = ''
    )

    return @(
        @($Targets) |
            Sort-Object `
                @{ Expression = {
                        $pairId = [string](Get-ObjectPropertyValue -Object $_ -Name 'PairId' -DefaultValue '')
                        $contractReady = [bool](Get-ObjectPropertyValue -Object $_ -Name 'ContractArtifactsReady' -DefaultValue $false)
                        $manualAttention = [bool](Get-ObjectPropertyValue -Object $_ -Name 'ManualAttentionRequired' -DefaultValue $false)
                        if ((Test-NonEmptyString $FocusPairId) -and $pairId -eq $FocusPairId) { 0 }
                        elseif (-not $contractReady) { 1 }
                        elseif ($manualAttention) { 2 }
                        else { 3 }
                    }
                }, `
                @{ Expression = { if (-not [bool](Get-ObjectPropertyValue -Object $_ -Name 'ContractArtifactsReady' -DefaultValue $false)) { 0 } else { 1 } } }, `
                @{ Expression = { if ([bool](Get-ObjectPropertyValue -Object $_ -Name 'ManualAttentionRequired' -DefaultValue $false)) { 0 } else { 1 } } }, `
                @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -Name 'TargetId' -DefaultValue '') } }
    )
}

function Get-ImportantRecentEvents {
    param(
        [string]$GeneratedAt,
        $AcceptanceSummary,
        $WatcherSummary,
        $Status,
        [object[]]$Pairs,
        [object[]]$Targets,
        [int]$MaxCount = 8
    )

    $events = New-Object System.Collections.ArrayList
    $firstPair = $null
    $pairCandidates = @(@($Pairs) | Select-Object -First 1)
    if ($pairCandidates.Count -gt 0) {
        $firstPair = $pairCandidates[0]
    }
    $firstPairId = if ($null -ne $firstPair) { [string](Get-ObjectPropertyValue -Object $firstPair -Name 'PairId' -DefaultValue '') } else { '' }
    $statusAcceptanceReceipt = Get-ObjectPropertyValue -Object $Status -Name 'AcceptanceReceipt' -DefaultValue $null
    $statusPairState = Get-ObjectPropertyValue -Object $Status -Name 'PairState' -DefaultValue $null

    Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $statusAcceptanceReceipt -Name 'LastWriteAt' -DefaultValue '')) -Text ('acceptance receipt updated: stage={0} state={1}' -f [string]$AcceptanceSummary.Stage, [string]$AcceptanceSummary.AcceptanceState) -Source 'acceptance-receipt' -Priority 5 -EventClass 'acceptance' -PairId $firstPairId -IsProgressSignal:$true
    Add-EventRecord -List $events -At ([string]$AcceptanceSummary.EffectiveRecordedAt) -Text ('acceptance effective result recorded: stage={0} state={1}' -f [string]$AcceptanceSummary.Stage, [string]$AcceptanceSummary.AcceptanceState) -Source 'acceptance-effective' -Priority 4 -EventClass 'acceptance' -PairId $firstPairId -IsProgressSignal:$true
    Add-EventRecord -List $events -At ([string]$WatcherSummary.StatusUpdatedAt) -Text ('watcher status updated: status={0} reason={1}' -f [string]$WatcherSummary.Status, [string]$WatcherSummary.Reason) -Source 'watcher-status' -Priority 10 -EventClass 'watcher' -PairId $firstPairId
    Add-EventRecord -List $events -At ([string]$WatcherSummary.HeartbeatAt) -Text ('watcher heartbeat: status={0} reason={1}' -f [string]$WatcherSummary.Status, [string]$WatcherSummary.Reason) -Source 'watcher-heartbeat' -Priority 11 -EventClass 'watcher' -PairId $firstPairId
    Add-EventRecord -List $events -At ([string]$WatcherSummary.LastHandledAt) -Text ('watcher last handled: {0}' -f [string]$WatcherSummary.LastHandled) -Source 'watcher-last-handled' -Priority 12 -EventClass 'watcher' -PairId $firstPairId -IsProgressSignal:$true
    Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $statusPairState -Name 'LastWriteAt' -DefaultValue '')) -Text ('pair-state updated: {0}' -f ([string](Get-ObjectPropertyValue -Object $firstPair -Name 'ProgressDetail' -DefaultValue 'pair progress available'))) -Source 'pair-state' -Priority 15 -EventClass 'pair-state' -PairId $firstPairId -IsProgressSignal:$true

    foreach ($target in @($Targets)) {
        $pairId = [string](Get-ObjectPropertyValue -Object $target -Name 'PairId' -DefaultValue '')
        $targetId = [string](Get-ObjectPropertyValue -Object $target -Name 'TargetId' -DefaultValue '')
        $partnerTargetId = [string](Get-ObjectPropertyValue -Object $target -Name 'PartnerTargetId' -DefaultValue '')
        $sourceOutboxState = [string](Get-ObjectPropertyValue -Object $target -Name 'SourceOutboxState' -DefaultValue '')
        $sourceOutboxNextAction = [string](Get-ObjectPropertyValue -Object $target -Name 'SourceOutboxNextAction' -DefaultValue '')

        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.MessageFile -Name 'LastWriteAt' -DefaultValue '')) -Text ('{0} payload message prepared' -f $targetId) -Source ($targetId + ':message') -Priority 30 -EventClass 'supporting-signal' -PairId $pairId -TargetId $targetId
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.RequestFile -Name 'LastWriteAt' -DefaultValue '')) -Text ('{0} request.json prepared' -f $targetId) -Source ($targetId + ':request') -Priority 29 -EventClass 'supporting-signal' -PairId $pairId -TargetId $targetId
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.LatestPrepareLog -Name 'LastWriteAt' -DefaultValue '')) -Text ('{0} typed-window prepare log updated' -f $targetId) -Source ($targetId + ':prepare-log') -Priority 20 -EventClass 'supporting-signal' -PairId $pairId -TargetId $targetId
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.LatestAhkLog -Name 'LastWriteAt' -DefaultValue '')) -Text ('{0} AHK log updated' -f $targetId) -Source ($targetId + ':ahk-log') -Priority 21 -EventClass 'supporting-signal' -PairId $pairId -TargetId $targetId
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.ProcessedFile -Name 'LastWriteAt' -DefaultValue '')) -Text ('{0} processed archive updated' -f $targetId) -Source ($targetId + ':processed') -Priority 19 -EventClass 'source-outbox' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
        Add-EventRecord -List $events -At ([string]$target.SourceOutboxUpdatedAt) -Text ('{0} source-outbox state={1} next={2}' -f $targetId, $sourceOutboxState, $sourceOutboxNextAction) -Source ($targetId + ':outbox') -Priority 18 -EventClass 'source-outbox' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
        Add-EventRecord -List $events -At ([string]$target.ForwardedAt) -Text ('{0} forwarded to {1}' -f $targetId, $(if (Test-NonEmptyString $partnerTargetId) { $partnerTargetId } else { 'partner' })) -Source ($targetId + ':forwarded') -Priority 17 -EventClass 'watcher' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.SourceSummary -Name 'LastWriteAt' -DefaultValue '')) -Text ('{0} summary.txt created' -f $targetId) -Source ($targetId + ':summary') -Priority 14 -EventClass 'contract-artifact' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.SourceReviewZip -Name 'LastWriteAt' -DefaultValue '')) -Text ('{0} review.zip created' -f $targetId) -Source ($targetId + ':review-zip') -Priority 13 -EventClass 'contract-artifact' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.PublishReady -Name 'LastWriteAt' -DefaultValue '')) -Text ('{0} publish.ready.json created' -f $targetId) -Source ($targetId + ':publish-ready') -Priority 12 -EventClass 'contract-artifact' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
    }

    $results = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($event in @(
            @($events) |
                Where-Object { $null -ne $_ -and (Test-NonEmptyString ([string]$_.Text)) } |
                Sort-Object @{ Expression = { [int64]$_.SortTicks }; Descending = $true }, @{ Expression = { [int]$_.Priority } }, @{ Expression = { [string]$_.Text } }
        )) {
        $key = ([string]$event.At + '|' + [string]$event.Text)
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        [void]$results.Add([pscustomobject]@{
                At   = [string]$event.At
                Text = [string]$event.Text
                EventClass = [string](Get-ObjectPropertyValue -Object $event -Name 'EventClass' -DefaultValue '')
                PairId = [string](Get-ObjectPropertyValue -Object $event -Name 'PairId' -DefaultValue '')
                TargetId = [string](Get-ObjectPropertyValue -Object $event -Name 'TargetId' -DefaultValue '')
                IsProgressSignal = [bool](Get-ObjectPropertyValue -Object $event -Name 'IsProgressSignal' -DefaultValue $false)
            })
        if ($results.Count -ge $MaxCount) {
            break
        }
    }

    return @($results)
}

function Get-FreshnessSummary {
    param(
        [string]$GeneratedAt,
        [object[]]$RecentEvents,
        [string]$OverallState,
        $WatcherSummary
    )

    $referenceTime = ConvertTo-UtcDateTimeOrNull -Value $GeneratedAt
    if ($null -eq $referenceTime) {
        $referenceTime = (Get-Date).ToUniversalTime()
    }

    $newestEvent = $null
    $eventCandidates = @(@($RecentEvents) | Select-Object -First 1)
    if ($eventCandidates.Count -gt 0) {
        $newestEvent = $eventCandidates[0]
    }
    $newestSignalAt = if ($null -ne $newestEvent) { [string](Get-ObjectPropertyValue -Object $newestEvent -Name 'At' -DefaultValue '') } else { '' }
    $newestSignalLabel = if ($null -ne $newestEvent) { [string](Get-ObjectPropertyValue -Object $newestEvent -Name 'Text' -DefaultValue '') } else { '' }
    $newestSignalTime = ConvertTo-UtcDateTimeOrNull -Value $newestSignalAt
    $newestProgressEvent = @(
        @($RecentEvents) |
            Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name 'IsProgressSignal' -DefaultValue $false) } |
            Select-Object -First 1
    )
    $newestProgressSignalAt = if ($newestProgressEvent.Count -gt 0) { [string](Get-ObjectPropertyValue -Object $newestProgressEvent[0] -Name 'At' -DefaultValue '') } else { '' }
    $newestProgressSignalText = if ($newestProgressEvent.Count -gt 0) { [string](Get-ObjectPropertyValue -Object $newestProgressEvent[0] -Name 'Text' -DefaultValue '') } else { '' }
    $newestProgressSignalTime = ConvertTo-UtcDateTimeOrNull -Value $newestProgressSignalAt

    $signalAgeSeconds = $null
    if ($null -ne $newestSignalTime) {
        $signalAgeSeconds = [math]::Round(($referenceTime - $newestSignalTime).TotalSeconds, 3)
        if ($signalAgeSeconds -lt 0) {
            $signalAgeSeconds = 0
        }
    }
    $progressSignalAgeSeconds = $null
    if ($null -ne $newestProgressSignalTime) {
        $progressSignalAgeSeconds = [math]::Round(($referenceTime - $newestProgressSignalTime).TotalSeconds, 3)
        if ($progressSignalAgeSeconds -lt 0) {
            $progressSignalAgeSeconds = 0
        }
    }

    $freshnessWindowSeconds = if ($OverallState -eq 'success' -or [string]$WatcherSummary.Status -in @('stopped', 'paused')) { 1800 } else { 300 }
    $staleSummary = $false
    $staleReason = 'fresh'
    $progressStale = $false
    $progressStaleReason = 'fresh'
    if ($null -eq $newestSignalTime) {
        $staleSummary = $true
        $staleReason = 'no-observed-signal'
    }
    elseif ($signalAgeSeconds -gt $freshnessWindowSeconds) {
        $staleSummary = $true
        $staleReason = ('latest-signal-older-than-{0}s' -f $freshnessWindowSeconds)
    }
    elseif ([string]$WatcherSummary.Status -eq 'running' -and [double](Get-ObjectPropertyValue -Object $WatcherSummary -Name 'HeartbeatAgeSeconds' -DefaultValue 0) -gt $freshnessWindowSeconds) {
        $staleSummary = $true
        $staleReason = 'watcher-heartbeat-stale'
    }
    if ($null -eq $newestProgressSignalTime) {
        $progressStale = $true
        $progressStaleReason = 'no-progress-signal'
    }
    elseif ($progressSignalAgeSeconds -gt $freshnessWindowSeconds) {
        $progressStale = $true
        $progressStaleReason = ('latest-progress-signal-older-than-{0}s' -f $freshnessWindowSeconds)
    }

    return [pscustomobject]@{
        GeneratedAt              = $GeneratedAt
        NewestObservedSignalAt   = $newestSignalAt
        NewestObservedSignalText = $newestSignalLabel
        SignalAgeSeconds         = $signalAgeSeconds
        NewestProgressSignalAt   = $newestProgressSignalAt
        NewestProgressSignalText = $newestProgressSignalText
        ProgressSignalAgeSeconds = $progressSignalAgeSeconds
        FreshnessWindowSeconds   = $freshnessWindowSeconds
        StaleSummary             = $staleSummary
        StaleReason              = $staleReason
        ProgressStale            = $progressStale
        ProgressStaleReason      = $progressStaleReason
    }
}

function New-ImportantSummaryData {
    param(
        [string]$RunRoot,
        [string]$ConfigPath,
        $AcceptanceReceipt,
        $AcceptanceSummary,
        $Status,
        $WatcherSummary,
        $CountsSummary,
        [string]$SummaryLine
    )

    $manifestSummary = Get-ManifestSummary -RunRoot $RunRoot
    $contractSummary = Get-ContractSummary -AcceptanceReceipt $AcceptanceReceipt
    $config = Read-ConfigObjectSafe -Path $ConfigPath
    $logsRoot = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $config -Name 'LogsRoot' -DefaultValue ''))
    $runtimeRoot = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $config -Name 'RuntimeRoot' -DefaultValue ''))
    $inboxRoot = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $config -Name 'InboxRoot' -DefaultValue ''))
    $processedRoot = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $config -Name 'ProcessedRoot' -DefaultValue ''))
    $statusTargetLookup = Get-StatusTargetLookup -Targets @($Status.Targets)

    $importantTargets = @()
    foreach ($manifestTarget in @($manifestSummary.Targets)) {
        $targetId = [string](Get-ObjectPropertyValue -Object $manifestTarget -Name 'TargetId' -DefaultValue '')
        $statusTarget = $null
        if (Test-NonEmptyString $targetId -and $statusTargetLookup.ContainsKey($targetId)) {
            $statusTarget = $statusTargetLookup[$targetId]
        }

        $importantTargets += Get-ImportantTargetSummary -ManifestTarget $manifestTarget -StatusTarget $statusTarget -LogsRoot $logsRoot
    }

    $generatedAt = (Get-Date).ToString('o')
    $importantPairs = Get-ImportantPairSummaries -Status $Status
    $operatorFocus = Get-OperatorFocusSummary `
        -OverallState (Get-OverallState -AcceptanceSummary $AcceptanceSummary -Status $Status) `
        -AcceptanceSummary $AcceptanceSummary `
        -WatcherSummary $WatcherSummary `
        -CountsSummary $CountsSummary `
        -Pairs @($importantPairs) `
        -Targets @($importantTargets)
    $importantPairs = Sort-ImportantPairSummaries -Pairs @($importantPairs) -FocusPairId ([string]$operatorFocus.FocusPairId)
    $importantTargets = Sort-ImportantTargets -Targets @($importantTargets) -FocusPairId ([string]$operatorFocus.FocusPairId)
    $recentEvents = Get-ImportantRecentEvents `
        -GeneratedAt $generatedAt `
        -AcceptanceSummary $AcceptanceSummary `
        -WatcherSummary $WatcherSummary `
        -Status $Status `
        -Pairs @($importantPairs) `
        -Targets @($importantTargets)
    $freshness = Get-FreshnessSummary `
        -GeneratedAt $generatedAt `
        -RecentEvents @($recentEvents) `
        -OverallState (Get-OverallState -AcceptanceSummary $AcceptanceSummary -Status $Status) `
        -WatcherSummary $WatcherSummary

    $stateRoot = Join-Path $RunRoot '.state'
    return [pscustomobject]@{
        GeneratedAt = $generatedAt
        RunRoot     = $RunRoot
        ConfigPath  = $ConfigPath
        SummaryLine = $SummaryLine
        OverallState = Get-OverallState -AcceptanceSummary $AcceptanceSummary -Status $Status
        Freshness   = $freshness
        OperatorFocus = $operatorFocus
        Acceptance  = $AcceptanceSummary
        Watcher     = $WatcherSummary
        Counts      = $CountsSummary
        Contract    = $contractSummary
        KeyPaths    = [pscustomobject]@{
            ManifestPath           = [string]$manifestSummary.Path
            ReceiptPath            = [string]$Status.AcceptanceReceipt.Path
            SeedSendStatusPath     = (Join-Path $stateRoot 'seed-send-status.json')
            PairStatePath          = (Join-Path $stateRoot 'pair-state.json')
            WatcherStatusPath      = [string]$WatcherSummary.StatusPath
            MessagesRoot           = (Join-Path $RunRoot 'messages')
            LogsRoot               = $logsRoot
            RouterLogPath          = if (Test-NonEmptyString $logsRoot) { Join-Path $logsRoot 'router.log' } else { '' }
            RuntimeRoot            = $runtimeRoot
            InboxRoot              = $inboxRoot
            ProcessedRoot          = $processedRoot
        }
        RecentEvents = @($recentEvents)
        Pairs = @($importantPairs)
        Targets = @($importantTargets)
    }
}

function Format-ImportantSummaryText {
    param($ImportantSummary)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[important-summary]')
    $lines.Add(('RunRoot: {0}' -f [string]$ImportantSummary.RunRoot))
    $lines.Add(('OverallState: {0}' -f [string]$ImportantSummary.OverallState))
    $lines.Add(('Summary: {0}' -f [string]$ImportantSummary.SummaryLine))
    $lines.Add('')
    $lines.Add('[freshness]')
    $lines.Add(('GeneratedAt: {0}' -f [string]$ImportantSummary.Freshness.GeneratedAt))
    $lines.Add(('NewestObservedSignalAt: {0}' -f [string]$ImportantSummary.Freshness.NewestObservedSignalAt))
    $lines.Add(('NewestObservedSignalText: {0}' -f [string]$ImportantSummary.Freshness.NewestObservedSignalText))
    $lines.Add(('SignalAgeSeconds: {0}' -f [string]$ImportantSummary.Freshness.SignalAgeSeconds))
    $lines.Add(('NewestProgressSignalAt: {0}' -f [string]$ImportantSummary.Freshness.NewestProgressSignalAt))
    $lines.Add(('NewestProgressSignalText: {0}' -f [string]$ImportantSummary.Freshness.NewestProgressSignalText))
    $lines.Add(('ProgressSignalAgeSeconds: {0}' -f [string]$ImportantSummary.Freshness.ProgressSignalAgeSeconds))
    $lines.Add(('FreshnessWindowSeconds: {0}' -f [int]$ImportantSummary.Freshness.FreshnessWindowSeconds))
    $lines.Add(('StaleSummary: {0}' -f [bool]$ImportantSummary.Freshness.StaleSummary))
    $lines.Add(('StaleReason: {0}' -f [string]$ImportantSummary.Freshness.StaleReason))
    $lines.Add(('ProgressStale: {0}' -f [bool]$ImportantSummary.Freshness.ProgressStale))
    $lines.Add(('ProgressStaleReason: {0}' -f [string]$ImportantSummary.Freshness.ProgressStaleReason))
    $lines.Add(('Acceptance: stage={0} state={1} reason={2}' -f [string]$ImportantSummary.Acceptance.Stage, [string]$ImportantSummary.Acceptance.AcceptanceState, [string]$ImportantSummary.Acceptance.AcceptanceReason))
    $lines.Add(('Seed: final={0} submit={1} outboxPublished={2}' -f [string]$ImportantSummary.Acceptance.SeedFinalState, [string]$ImportantSummary.Acceptance.SeedSubmitState, [bool]$ImportantSummary.Acceptance.SeedOutboxPublished))
    $lines.Add(('Watcher: status={0} reason={1} lastHandled={2}' -f [string]$ImportantSummary.Watcher.Status, [string]$ImportantSummary.Watcher.Reason, [string]$ImportantSummary.Watcher.LastHandled))
    $lines.Add(('Counts: forwarded={0} summaries={1} zips={2} failures={3}' -f [int]$ImportantSummary.Counts.ForwardedCount, [int]$ImportantSummary.Counts.SummaryPresentCount, [int]$ImportantSummary.Counts.ZipPresentCount, [int]$ImportantSummary.Counts.FailureLineCount))
    $lines.Add('')
    $lines.Add('[operator-focus]')
    $lines.Add(('AttentionLevel: {0}' -f [string]$ImportantSummary.OperatorFocus.AttentionLevel))
    if (Test-NonEmptyString ([string]$ImportantSummary.OperatorFocus.FocusPairId)) {
        $lines.Add(('FocusPair: {0}' -f [string]$ImportantSummary.OperatorFocus.FocusPairId))
    }
    if (Test-NonEmptyString [string]$ImportantSummary.OperatorFocus.PairPhase) {
        $lines.Add(('PairPhase: {0}' -f [string]$ImportantSummary.OperatorFocus.PairPhase))
    }
    if (Test-NonEmptyString [string]$ImportantSummary.OperatorFocus.PairNextAction) {
        $lines.Add(('PairNextAction: {0}' -f [string]$ImportantSummary.OperatorFocus.PairNextAction))
    }
    if (Test-NonEmptyString [string]$ImportantSummary.OperatorFocus.NextExpectedHandoff) {
        $lines.Add(('NextExpectedHandoff: {0}' -f [string]$ImportantSummary.OperatorFocus.NextExpectedHandoff))
    }
    $lines.Add(('CurrentBottleneck: {0}' -f [string]$ImportantSummary.OperatorFocus.CurrentBottleneck))
    $lines.Add(('NextExpectedStep: {0}' -f [string]$ImportantSummary.OperatorFocus.NextExpectedStep))
    $lines.Add(('RecommendedAction: {0}' -f [string]$ImportantSummary.OperatorFocus.RecommendedAction))
    $lines.Add(('ContractTargetsReady: {0}/{1}' -f [int]$ImportantSummary.OperatorFocus.ContractReadyTargetCount, [int]$ImportantSummary.OperatorFocus.TotalTargetCount))
    $incompleteTargetIds = @($ImportantSummary.OperatorFocus.IncompleteTargetIds | Where-Object { Test-NonEmptyString ([string]$_) })
    if ($incompleteTargetIds.Count -gt 0) {
        $lines.Add(('IncompleteTargets: {0}' -f ($incompleteTargetIds -join ', ')))
    }
    $lines.Add('')
    $lines.Add('[recent-events]')
    if ((@($ImportantSummary.RecentEvents)).Count -eq 0) {
        $lines.Add('(none)')
    }
    else {
        foreach ($event in @($ImportantSummary.RecentEvents)) {
            $lines.Add(('- {0} {1}' -f [string]$event.At, [string]$event.Text))
        }
    }
    $lines.Add('')
    $lines.Add('[externalization]')
    $lines.Add(('PrimaryContractExternalized: {0}' -f [bool]$ImportantSummary.Contract.PrimaryContractExternalized))
    $lines.Add(('ExternalRunRootUsed: {0}' -f [bool]$ImportantSummary.Contract.ExternalRunRootUsed))
    $lines.Add(('BookkeepingExternalized: {0}' -f [bool]$ImportantSummary.Contract.BookkeepingExternalized))
    $lines.Add(('FullExternalized: {0}' -f [bool]$ImportantSummary.Contract.FullExternalized))
    $internalResidualRoots = @(Format-InternalResidualRootsDisplay -Items @($ImportantSummary.Contract.InternalResidualRoots))
    $lines.Add(('InternalResidualRoots: {0}' -f ($(if ($internalResidualRoots.Count -gt 0) { $internalResidualRoots -join ', ' } else { '(none)' }))))
    $lines.Add('')
    $lines.Add('[key-paths]')
    foreach ($entry in @(
            @('ManifestPath', [string]$ImportantSummary.KeyPaths.ManifestPath),
            @('ReceiptPath', [string]$ImportantSummary.KeyPaths.ReceiptPath),
            @('SeedSendStatusPath', [string]$ImportantSummary.KeyPaths.SeedSendStatusPath),
            @('PairStatePath', [string]$ImportantSummary.KeyPaths.PairStatePath),
            @('WatcherStatusPath', [string]$ImportantSummary.KeyPaths.WatcherStatusPath),
            @('MessagesRoot', [string]$ImportantSummary.KeyPaths.MessagesRoot),
            @('LogsRoot', [string]$ImportantSummary.KeyPaths.LogsRoot),
            @('RouterLogPath', [string]$ImportantSummary.KeyPaths.RouterLogPath),
            @('RuntimeRoot', [string]$ImportantSummary.KeyPaths.RuntimeRoot),
            @('InboxRoot', [string]$ImportantSummary.KeyPaths.InboxRoot),
            @('ProcessedRoot', [string]$ImportantSummary.KeyPaths.ProcessedRoot)
        )) {
        if (Test-NonEmptyString [string]$entry[1]) {
            $lines.Add(('{0}: {1}' -f [string]$entry[0], [string]$entry[1]))
        }
    }

    foreach ($pair in @($ImportantSummary.Pairs)) {
        $pairId = [string]$pair.PairId
        if (-not (Test-NonEmptyString $pairId)) {
            continue
        }
        $lines.Add('')
        $lines.Add(('[pair {0}] phase={1} next={2} handoff={3}' -f $pairId, [string]$pair.CurrentPhase, [string]$pair.NextAction, [string]$pair.NextExpectedHandoff))
        $lines.Add(('RoundtripCount: {0}' -f [int]$pair.RoundtripCount))
        $lines.Add(('ForwardedStateCount: {0}' -f [int]$pair.ForwardedStateCount))
        $lines.Add(('HandoffReadyCount: {0}' -f [int]$pair.HandoffReadyCount))
        if (Test-NonEmptyString ([string]$pair.ProgressDetail)) {
            $lines.Add(('ProgressDetail: {0}' -f [string]$pair.ProgressDetail))
        }
    }

    foreach ($target in @($ImportantSummary.Targets)) {
        $lines.Add('')
        $lines.Add(('[target {0}] role={1} latest={2} seed={3} submit={4}' -f [string]$target.TargetId, [string]$target.RoleName, [string]$target.LatestState, [string]$target.SeedSendState, [string]$target.SubmitState))
        $lines.Add(('InitialRoleMode: {0}' -f [string]$target.InitialRoleMode))
        $lines.Add(('ManualAttentionRequired: {0}' -f [bool]$target.ManualAttentionRequired))
        $lines.Add(('WorkRepoRoot: {0}' -f [string]$target.WorkRepoRoot))
        $lines.Add(('ReviewInputPath: {0}' -f [string]$target.ReviewInputPath))
        $lines.Add(('MessagePath: {0}' -f [string]$target.MessagePath))
        $lines.Add(('RequestPath: {0}' -f [string]$target.RequestPath))
        if (Test-NonEmptyString ([string]$target.ProcessedPath)) {
            $lines.Add(('ProcessedPath: {0}' -f [string]$target.ProcessedPath))
        }
        $lines.Add(('ContractPathMode: {0}' -f [string]$target.ContractPathMode))
        $lines.Add(('ContractRootPath: {0}' -f [string]$target.ContractRootPath))
        $lines.Add(('ContractReferenceTimeUtc: {0}' -f [string]$target.ContractReferenceTimeUtc))
        $lines.Add(('ContractArtifactsReady: {0}' -f [bool]$target.ContractArtifactsReady))
        $missingContractFiles = @($target.MissingContractFiles | Where-Object { Test-NonEmptyString ([string]$_) })
        if ($missingContractFiles.Count -gt 0) {
            $lines.Add(('MissingContractFiles: {0}' -f ($missingContractFiles -join ', ')))
        }
        $lines.Add(('summary.txt: exists={0} path={1}' -f [bool]$target.SourceSummary.Exists, [string]$target.SourceSummary.Path))
        $lines.Add(('review.zip: exists={0} path={1}' -f [bool]$target.SourceReviewZip.Exists, [string]$target.SourceReviewZip.Path))
        $lines.Add(('publish.ready.json: exists={0} path={1}' -f [bool]$target.PublishReady.Exists, [string]$target.PublishReady.Path))
        if (Test-NonEmptyString ([string]$target.LatestPrepareLogPath)) {
            $lines.Add(('LatestPrepareLogPath: {0}' -f [string]$target.LatestPrepareLogPath))
        }
        if (Test-NonEmptyString ([string]$target.LatestAhkLogPath)) {
            $lines.Add(('LatestAhkLogPath: {0}' -f [string]$target.LatestAhkLogPath))
        }
        if (Test-NonEmptyString ([string]$target.ProcessedPayloadSnapshotPath)) {
            $lines.Add(('ProcessedPayloadSnapshotPath: {0}' -f [string]$target.ProcessedPayloadSnapshotPath))
            $lines.Add(('ProcessedPayloadSnapshotExists: {0}' -f [bool]$target.ProcessedPayloadSnapshot.Exists))
        }
        $preview = [string]$target.MessagePreview
        if (Test-NonEmptyString $preview) {
            $lines.Add('MessagePreview:')
            foreach ($previewLine in @($preview -split "(`r`n|`n|`r)")) {
                $lines.Add(('  {0}' -f [string]$previewLine))
            }
        }
        $payloadPreview = [string]$target.ProcessedPayloadSnapshotPreview
        if (Test-NonEmptyString $payloadPreview) {
            $lines.Add('ProcessedPayloadSnapshotPreview:')
            foreach ($previewLine in @($payloadPreview -split "(`r`n|`n|`r)")) {
                $lines.Add(('  {0}' -f [string]$previewLine))
            }
        }
    }

    return (($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).TrimEnd()
}

function Write-ImportantSummaryArtifacts {
    param(
        [string]$RunRoot,
        $ImportantSummary
    )

    $stateRoot = Join-Path $RunRoot '.state'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }

    $jsonPath = Join-Path $stateRoot 'important-summary.json'
    $textPath = Join-Path $stateRoot 'important-summary.txt'
    $textContent = Format-ImportantSummaryText -ImportantSummary $ImportantSummary

    $ImportantSummary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $textContent | Set-Content -LiteralPath $textPath -Encoding UTF8

    return [pscustomobject]@{
        JsonPath = $jsonPath
        TextPath = $textPath
        Text     = $textContent
    }
}

$statusParams = @{}
if (Test-NonEmptyString $ConfigPath) {
    $statusParams.ConfigPath = $ConfigPath
}
if (Test-NonEmptyString $RunRoot) {
    $statusParams.RunRoot = $RunRoot
}
$statusParams.RecentFailureCount = $RecentFailureCount
$statusParams.AsJson = $true

$status = & (Join-Path $PSScriptRoot 'show-paired-exchange-status.ps1') @statusParams | ConvertFrom-Json
$acceptanceReceipt = Read-JsonObjectSafe -Path ([string]$status.AcceptanceReceipt.Path)

$targets = @(
    @($status.Targets) | ForEach-Object {
        [pscustomobject]@{
            PairId                  = [string]$_.PairId
            RoleName                = [string]$_.RoleName
            TargetId                = [string]$_.TargetId
            PartnerTargetId         = [string]$_.PartnerTargetId
            LatestState             = [string]$_.LatestState
            SourceOutboxState       = [string]$_.SourceOutboxState
            SeedSendState           = [string]$_.SeedSendState
            SubmitState             = [string]$_.SubmitState
            ManualAttentionRequired = [bool]$_.ManualAttentionRequired
            SummaryPresent          = [bool]$_.SummaryPresent
            ZipCount                = [int]$_.ZipCount
            DonePresent             = [bool]$_.DonePresent
            ResultPresent           = [bool]$_.ResultPresent
            FailureCount            = [int]$_.FailureCount
            ForwardedAt             = [string]$_.ForwardedAt
            SourceOutboxUpdatedAt   = [string]$_.SourceOutboxUpdatedAt
            TargetFolder            = [string]$_.TargetFolder
        }
    }
)

$acceptanceSummary = Get-AcceptanceSummary -AcceptanceReceipt $acceptanceReceipt -Status $status

$watcherSummary = [pscustomobject]@{
    Status        = [string]$status.Watcher.Status
    Reason        = [string]$status.Watcher.StatusReason
    LastHandled   = [string]$status.Watcher.LastHandledResult
    LastHandledAt = [string](Get-ObjectPropertyValue -Object $status.Watcher -Name 'LastHandledAt' -DefaultValue '')
    HeartbeatAt   = [string]$status.Watcher.HeartbeatAt
    HeartbeatAgeSeconds = [double](Get-ObjectPropertyValue -Object $status.Watcher -Name 'HeartbeatAgeSeconds' -DefaultValue 0)
    StatusUpdatedAt = [string](Get-ObjectPropertyValue -Object $status.Watcher -Name 'StatusFileUpdatedAt' -DefaultValue '')
    StatusPath    = [string]$status.Watcher.StatusPath
}

$countsSummary = [pscustomobject]@{
    MessageFiles             = [int]$status.Counts.MessageFiles
    ForwardedCount           = [int]$status.Counts.ForwardedCount
    SummaryPresentCount      = [int]$status.Counts.SummaryPresentCount
    ZipPresentCount          = [int]$status.Counts.ZipPresentCount
    DonePresentCount         = [int]$status.Counts.DonePresentCount
    FailureLineCount         = [int]$status.Counts.FailureLineCount
    ManualAttentionCount     = [int]$status.Counts.ManualAttentionCount
    SubmitUnconfirmedCount   = [int]$status.Counts.SubmitUnconfirmedCount
    TargetUnresponsiveCount  = [int]$status.Counts.TargetUnresponsiveCount
    ReadyToForwardCount      = [int]$status.Counts.ReadyToForwardCount
    DispatchRunningCount     = [int](Get-ObjectPropertyValue -Object $status.Counts -Name 'DispatchRunningCount' -DefaultValue 0)
}

$overallState = Get-OverallState -AcceptanceSummary $acceptanceSummary -Status $status
$runName = Split-Path -Leaf ([string]$status.RunRoot)
$summaryLine = '{0} overall={1} acceptance={2} stage={3} watcher={4} forwarded={5} summaries={6} zips={7} failures={8}' -f `
    $runName,
    $overallState,
    $acceptanceSummary.AcceptanceState,
    $acceptanceSummary.Stage,
    $watcherSummary.Status,
    $countsSummary.ForwardedCount,
    $countsSummary.SummaryPresentCount,
    $countsSummary.ZipPresentCount,
    $countsSummary.FailureLineCount

$importantSummary = New-ImportantSummaryData `
    -RunRoot ([string]$status.RunRoot) `
    -ConfigPath $ConfigPath `
    -AcceptanceReceipt $acceptanceReceipt `
    -AcceptanceSummary $acceptanceSummary `
    -Status $status `
    -WatcherSummary $watcherSummary `
    -CountsSummary $countsSummary `
    -SummaryLine $summaryLine
$importantSummaryArtifacts = Write-ImportantSummaryArtifacts -RunRoot ([string]$status.RunRoot) -ImportantSummary $importantSummary

$result = [pscustomobject]@{
    RunRoot          = [string]$status.RunRoot
    SummaryLine      = $summaryLine
    OverallState     = $overallState
    Acceptance       = $acceptanceSummary
    Watcher          = $watcherSummary
    Counts           = $countsSummary
    RecentFailureCount = [int]$RecentFailureCount
    Targets          = $targets
    ImportantSummary = [pscustomobject]@{
        JsonPath = [string]$importantSummaryArtifacts.JsonPath
        TextPath = [string]$importantSummaryArtifacts.TextPath
        Data     = $importantSummary
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

Write-Output $summaryLine
Write-Output ('RunRoot: ' + [string]$result.RunRoot)
Write-Output ('Acceptance: stage={0} state={1} reason={2}' -f $acceptanceSummary.Stage, $acceptanceSummary.AcceptanceState, $acceptanceSummary.AcceptanceReason)
Write-Output ('Seed: final={0} submit={1} outboxPublished={2}' -f $acceptanceSummary.SeedFinalState, $acceptanceSummary.SeedSubmitState, $acceptanceSummary.SeedOutboxPublished)
Write-Output ('Watcher: status={0} reason={1} lastHandled={2}' -f $watcherSummary.Status, $watcherSummary.Reason, $watcherSummary.LastHandled)
Write-Output ('Counts: messages={0} forwarded={1} summaries={2} zips={3} failures={4}' -f $countsSummary.MessageFiles, $countsSummary.ForwardedCount, $countsSummary.SummaryPresentCount, $countsSummary.ZipPresentCount, $countsSummary.FailureLineCount)
Write-Output ('Freshness: stale={0} reason={1} newestSignalAt={2} signalAgeSec={3}' -f [bool]$importantSummary.Freshness.StaleSummary, [string]$importantSummary.Freshness.StaleReason, [string]$importantSummary.Freshness.NewestObservedSignalAt, [string]$importantSummary.Freshness.SignalAgeSeconds)
Write-Output ('ProgressFreshness: stale={0} reason={1} newestProgressSignalAt={2} progressSignalAgeSec={3}' -f [bool]$importantSummary.Freshness.ProgressStale, [string]$importantSummary.Freshness.ProgressStaleReason, [string]$importantSummary.Freshness.NewestProgressSignalAt, [string]$importantSummary.Freshness.ProgressSignalAgeSeconds)
Write-Output ('Bottleneck: ' + [string]$importantSummary.OperatorFocus.CurrentBottleneck)
Write-Output ('NextStep: ' + [string]$importantSummary.OperatorFocus.NextExpectedStep)
Write-Output ('RecommendedAction: ' + [string]$importantSummary.OperatorFocus.RecommendedAction)
Write-Output ('ImportantSummaryText: ' + [string]$importantSummaryArtifacts.TextPath)
Write-Output ('ImportantSummaryJson: ' + [string]$importantSummaryArtifacts.JsonPath)
Write-Output 'RecentEvents:'
foreach ($event in @($importantSummary.RecentEvents)) {
    Write-Output ('- {0} {1}' -f [string]$event.At, [string]$event.Text)
}
Write-Output 'Targets:'
foreach ($target in $targets) {
    Write-Output ('- {0}({1}): latest={2} outbox={3} seed={4} submit={5} summary={6} zip={7} failures={8}' -f `
        $target.TargetId,
        $target.RoleName,
        $target.LatestState,
        $target.SourceOutboxState,
        $target.SeedSendState,
        $target.SubmitState,
        $target.SummaryPresent,
        $target.ZipCount,
        $target.FailureCount)
}
Write-Output 'Important target paths:'
foreach ($target in @($importantSummary.Targets)) {
    Write-Output ('- {0}: message={1} request={2} summaryExists={3} zipExists={4} publishExists={5}' -f `
        [string]$target.TargetId,
        [string]$target.MessagePath,
        [string]$target.RequestPath,
        [bool]$target.SourceSummary.Exists,
        [bool]$target.SourceReviewZip.Exists,
        [bool]$target.PublishReady.Exists)
}
