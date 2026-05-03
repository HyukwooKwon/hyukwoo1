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

function Get-NormalizedFullPath {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    }
    catch {
        return ([string]$Path).ToLowerInvariant()
    }
}

function Test-NormalizedPathMatch {
    param(
        [string]$Left,
        [string]$Right
    )

    if (-not (Test-NonEmptyString $Left) -or -not (Test-NonEmptyString $Right)) {
        return $false
    }

    return ((Get-NormalizedFullPath -Path $Left) -eq (Get-NormalizedFullPath -Path $Right))
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

function ConvertTo-IntOrDefault {
    param(
        $Value,
        [int]$DefaultValue = 0
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
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

function Get-RequestAttemptInfo {
    param(
        [string]$RequestPath,
        $ManifestTarget = $null
    )

    $request = Read-JsonObjectSafe -Path $RequestPath
    $attemptId = [string](Get-ObjectPropertyValue -Object $request -Name 'AttemptId' -DefaultValue ([string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'AttemptId' -DefaultValue '')))
    $attemptStartedAt = [string](Get-ObjectPropertyValue -Object $request -Name 'AttemptStartedAt' -DefaultValue ([string](Get-ObjectPropertyValue -Object $request -Name 'CreatedAt' -DefaultValue ([string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'AttemptStartedAt' -DefaultValue ([string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'ContractReferenceTimeUtc' -DefaultValue '')))))))

    return [pscustomobject]@{
        AttemptId        = $attemptId
        AttemptStartedAt = $attemptStartedAt
        Request          = $request
    }
}

function ConvertFrom-AhkLogTimestamp {
    param([string]$RawTimestamp)

    $text = [string]$RawTimestamp
    if (-not (Test-NonEmptyString $text) -or $text -notmatch '^\d{14}$') {
        return ''
    }

    try {
        $parsed = [datetime]::ParseExact($text, 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $offset = [System.TimeZoneInfo]::Local.GetUtcOffset($parsed)
        return ([datetimeoffset]::new($parsed, $offset)).ToString('o')
    }
    catch {
        return ''
    }
}

function Get-AhkLifecycleSummary {
    param([string]$LogPath)

    $result = [ordered]@{
        SendBeginAt       = ''
        PayloadEnteredAt  = ''
        SubmitStartedAt   = ''
        SubmitCompletedAt = ''
        SendCompletedAt   = ''
    }

    if (-not (Test-NonEmptyString $LogPath) -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return [pscustomobject]$result
    }

    try {
        $lines = @(Get-Content -LiteralPath $LogPath -Encoding UTF8)
    }
    catch {
        return [pscustomobject]$result
    }

    foreach ($line in $lines) {
        $text = [string]$line
        if (-not (Test-NonEmptyString $text)) {
            continue
        }

        if ($text -notmatch '^\[(\d{14})\]\s+') {
            continue
        }

        $timestamp = ConvertFrom-AhkLogTimestamp -RawTimestamp $matches[1]
        if (-not (Test-NonEmptyString $timestamp)) {
            continue
        }

        if (-not (Test-NonEmptyString $result.SendBeginAt) -and $text -match '\bsend_begin\b') {
            $result.SendBeginAt = $timestamp
        }
        if (-not (Test-NonEmptyString $result.PayloadEnteredAt) -and $text -match '\bterminal_paste bytes=|\bterminal_sendtext\b|\bcontrol_sendtext\b') {
            $result.PayloadEnteredAt = $timestamp
        }
        if (-not (Test-NonEmptyString $result.SubmitStartedAt) -and $text -match '\bsubmit_attempt\b') {
            $result.SubmitStartedAt = $timestamp
        }
        if (-not (Test-NonEmptyString $result.SubmitCompletedAt) -and $text -match '\bsubmit_complete\b') {
            $result.SubmitCompletedAt = $timestamp
        }
        if (-not (Test-NonEmptyString $result.SendCompletedAt) -and $text -match '\bsend_complete\b') {
            $result.SendCompletedAt = $timestamp
        }
    }

    return [pscustomobject]$result
}

function Test-DateTimeOnOrAfter {
    param(
        [string]$Later,
        [string]$Earlier
    )

    $laterValue = ConvertTo-UtcDateTimeOrNull -Value $Later
    $earlierValue = ConvertTo-UtcDateTimeOrNull -Value $Earlier
    if ($null -eq $laterValue -or $null -eq $earlierValue) {
        return $null
    }

    return ($laterValue.UtcDateTime.Ticks -ge $earlierValue.UtcDateTime.Ticks)
}

function Get-LatestTimestamp {
    param([string[]]$Values)

    $latest = $null
    foreach ($value in @($Values)) {
        $parsed = ConvertTo-UtcDateTimeOrNull -Value ([string]$value)
        if ($null -eq $parsed) {
            continue
        }
        if ($null -eq $latest -or $parsed.UtcDateTime.Ticks -gt $latest.UtcDateTime.Ticks) {
            $latest = $parsed
        }
    }

    if ($null -eq $latest) {
        return ''
    }

    return $latest.ToString('o')
}

function Get-FirstOrderingViolation {
    param(
        [string]$SummaryWrittenAt = '',
        [string]$ReviewZipWrittenAt = '',
        [string]$PublishReadyWrittenAt = '',
        [string]$ImportedReviewCopyCreatedAt = '',
        [string]$ImportedSummaryCreatedAt = '',
        [string]$TriggerArtifactsCompletedAt = '',
        [bool]$CurrentArtifactsAheadOfObservedPublish = $false,
        $TimelineChecks = $null
    )

    if ($null -eq $TimelineChecks) {
        return ''
    }

    $publishAfterArtifacts = Get-ObjectPropertyValue -Object $TimelineChecks -Name 'PublishAfterArtifacts' -DefaultValue $null
    if ($publishAfterArtifacts -is [bool] -and -not [bool]$publishAfterArtifacts) {
        if ($CurrentArtifactsAheadOfObservedPublish) {
            return 'unpublished-artifacts-after-observed-publish'
        }

        if ((Test-NonEmptyString $SummaryWrittenAt) -and -not (Test-DateTimeOnOrAfter -Later $PublishReadyWrittenAt -Earlier $SummaryWrittenAt)) {
            return 'publish-before-summary'
        }

        if ((Test-NonEmptyString $ReviewZipWrittenAt) -and -not (Test-DateTimeOnOrAfter -Later $PublishReadyWrittenAt -Earlier $ReviewZipWrittenAt)) {
            return 'publish-before-reviewzip'
        }

        return 'publish-before-artifacts'
    }

    $watcherObservedAfterPublish = Get-ObjectPropertyValue -Object $TimelineChecks -Name 'WatcherObservedAfterPublish' -DefaultValue $null
    if ($watcherObservedAfterPublish -is [bool] -and -not [bool]$watcherObservedAfterPublish) {
        return 'watcher-observed-before-publish'
    }

    $handoffOpenedAfterPublish = Get-ObjectPropertyValue -Object $TimelineChecks -Name 'HandoffOpenedAfterPublish' -DefaultValue $null
    if ($handoffOpenedAfterPublish -is [bool] -and -not [bool]$handoffOpenedAfterPublish) {
        return 'handoff-before-publish'
    }

    $importedCopyAfterTrigger = Get-ObjectPropertyValue -Object $TimelineChecks -Name 'ImportedCopyAfterTrigger' -DefaultValue $null
    if ($importedCopyAfterTrigger -is [bool] -and -not [bool]$importedCopyAfterTrigger) {
        return 'import-copy-before-trigger'
    }

    $importedSummaryAfterTrigger = Get-ObjectPropertyValue -Object $TimelineChecks -Name 'ImportedSummaryAfterTrigger' -DefaultValue $null
    if ($importedSummaryAfterTrigger -is [bool] -and -not [bool]$importedSummaryAfterTrigger) {
        return 'import-summary-before-trigger'
    }

    return ''
}

function Get-ForbiddenArtifactPolicyFromConfig {
    param($Config)

    $pairTest = Get-ObjectPropertyValue -Object $Config -Name 'PairTest' -DefaultValue $null
    $defaultLiterals = @(
        '여기에 고정문구 입력'
    )
    $defaultRegexes = @(
        '이렇게 계획개선해봤어',
        '더 개선해야될 부분이 있어\??',
        '이런부분도 참고해봐'
    )

    $literalValues = @()
    $literalSource = Get-ObjectPropertyValue -Object $pairTest -Name 'ForbiddenArtifactLiterals' -DefaultValue @($defaultLiterals)
    foreach ($item in @($literalSource)) {
        if (Test-NonEmptyString ([string]$item)) {
            $literalValues += [string]$item
        }
    }

    $regexValues = @()
    $regexSource = Get-ObjectPropertyValue -Object $pairTest -Name 'ForbiddenArtifactRegexes' -DefaultValue @($defaultRegexes)
    foreach ($item in @($regexSource)) {
        if (Test-NonEmptyString ([string]$item)) {
            $regexValues += [string]$item
        }
    }

    return [pscustomobject]@{
        Literals = @($literalValues)
        Regexes  = @($regexValues)
    }
}

function Get-ForbiddenArtifactMatchFromText {
    param(
        [string]$Text,
        $Policy
    )

    if (-not (Test-NonEmptyString $Text)) {
        return [pscustomobject]@{
            Found = $false
            MatchKind = ''
            MatchText = ''
            Pattern = ''
            EntryPath = ''
        }
    }

    foreach ($literal in @((Get-ObjectPropertyValue -Object $Policy -Name 'Literals' -DefaultValue @()))) {
        if (-not (Test-NonEmptyString ([string]$literal))) {
            continue
        }
        if ($Text.Contains([string]$literal)) {
            return [pscustomobject]@{
                Found = $true
                MatchKind = 'literal'
                MatchText = [string]$literal
                Pattern = [string]$literal
                EntryPath = ''
            }
        }
    }

    foreach ($pattern in @((Get-ObjectPropertyValue -Object $Policy -Name 'Regexes' -DefaultValue @()))) {
        if (-not (Test-NonEmptyString ([string]$pattern))) {
            continue
        }

        try {
            $match = [regex]::Match(
                $Text,
                [string]$pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
        catch {
            continue
        }

        if ($match.Success) {
            $matchText = [string]$match.Value
            if ($matchText.Length -gt 120) {
                $matchText = ($matchText.Substring(0, 120) + ' ...')
            }

            return [pscustomobject]@{
                Found = $true
                MatchKind = 'regex'
                MatchText = $matchText
                Pattern = [string]$pattern
                EntryPath = ''
            }
        }
    }

    return [pscustomobject]@{
        Found = $false
        MatchKind = ''
        MatchText = ''
        Pattern = ''
        EntryPath = ''
    }
}

function Get-ForbiddenArtifactMatchFromFile {
    param(
        [string]$Path,
        $Policy
    )

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Found = $false
            MatchKind = ''
            MatchText = ''
            Pattern = ''
            EntryPath = ''
        }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            Found = $false
            MatchKind = ''
            MatchText = ''
            Pattern = ''
            EntryPath = ''
        }
    }

    return (Get-ForbiddenArtifactMatchFromText -Text $raw -Policy $Policy)
}

function Get-ForbiddenArtifactMatchFromZip {
    param(
        [string]$Path,
        $Policy
    )

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    }
    catch {
    }

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Found = $false
            MatchKind = ''
            MatchText = ''
            Pattern = ''
            EntryPath = ''
        }
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.Length -le 0 -or $entry.Length -gt 1MB) {
                    continue
                }

                $reader = $null
                try {
                    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8, $true)
                    $content = $reader.ReadToEnd()
                    $match = Get-ForbiddenArtifactMatchFromText -Text $content -Policy $Policy
                    if ([bool]$match.Found) {
                        $match | Add-Member -NotePropertyName 'EntryPath' -NotePropertyValue ([string]$entry.FullName) -Force
                        return $match
                    }
                }
                catch {
                }
                finally {
                    if ($null -ne $reader) {
                        $reader.Dispose()
                    }
                }
            }
        }
        finally {
            if ($null -ne $archive) {
                $archive.Dispose()
            }
        }
    }
    catch {
    }

    return [pscustomobject]@{
        Found = $false
        MatchKind = ''
        MatchText = ''
        Pattern = ''
        EntryPath = ''
    }
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

function Get-LatestArchivedPublishReadyPath {
    param([string]$PublishReadyPath)

    if (-not (Test-NonEmptyString $PublishReadyPath)) {
        return ''
    }

    $publishDir = Split-Path -Parent $PublishReadyPath
    if (-not (Test-NonEmptyString $publishDir)) {
        return ''
    }

    $archiveDir = Join-Path $publishDir '.published'
    if (-not (Test-Path -LiteralPath $archiveDir -PathType Container)) {
        return ''
    }

    $latest = Get-ChildItem -LiteralPath $archiveDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        return ''
    }

    return [string]$latest.FullName
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

function Get-SourceOutboxStatusSummary {
    param([string]$RunRoot)

    $statusPath = Join-Path (Join-Path $RunRoot '.state') 'source-outbox-status.json'
    $statusDocument = Read-JsonObjectSafe -Path $statusPath
    $targets = @()
    if ($null -ne $statusDocument) {
        $targets = @((Get-ObjectPropertyValue -Object $statusDocument -Name 'Targets' -DefaultValue @()))
    }

    return [pscustomobject]@{
        Exists  = ($null -ne $statusDocument)
        Path    = $statusPath
        Data    = $statusDocument
        Targets = $targets
    }
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
        $SourceOutboxStatusTarget = $null,
        [string]$LogsRoot = '',
        $ForbiddenArtifactPolicy = $null
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
    $targetFolder = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'TargetFolder' -DefaultValue '')
    $sourceSummaryPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'SourceSummaryPath' -DefaultValue '')
    $sourceReviewZipPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'SourceReviewZipPath' -DefaultValue '')
    $publishReadyPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'PublishReadyPath' -DefaultValue '')
    $sourceOutboxPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'SourceOutboxPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $sourceOutboxPath) -and (Test-NonEmptyString $sourceSummaryPath)) {
        try {
            $sourceOutboxPath = Split-Path -LiteralPath $sourceSummaryPath -Parent
        }
        catch {
            $sourceOutboxPath = ''
        }
    }
    $pairRunRoot = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'PairRunRoot' -DefaultValue '')
    if (-not (Test-NonEmptyString $pairRunRoot) -and (Test-NonEmptyString $targetFolder)) {
        try {
            $pairRunRoot = Split-Path -LiteralPath $targetFolder -Parent
        }
        catch {
            $pairRunRoot = ''
        }
    }
    $initialRoleMode = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'InitialRoleMode' -DefaultValue '')
    $contractPathMode = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'ContractPathMode' -DefaultValue '')
    $contractRootPath = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'ContractRootPath' -DefaultValue '')
    $contractReferenceTimeUtc = [string](Get-ObjectPropertyValue -Object $ManifestTarget -Name 'ContractReferenceTimeUtc' -DefaultValue '')
    $attemptInfo = Get-RequestAttemptInfo -RequestPath $requestPath -ManifestTarget $ManifestTarget

    $latestPrepareLogPath = ''
    $latestAhkLogPath = ''
    if (Test-NonEmptyString $LogsRoot) {
        $latestPrepareLogPath = Get-LatestMatchingFilePath -DirectoryPath (Join-Path (Join-Path $LogsRoot 'typed-window-prepare') $targetId)
        $latestAhkLogPath = Get-LatestMatchingFilePath -DirectoryPath (Join-Path (Join-Path $LogsRoot 'ahk-debug') $targetId)
    }

    $sourceSummary = Get-FileSnapshot -Path $sourceSummaryPath
    $sourceReviewZip = Get-FileSnapshot -Path $sourceReviewZipPath
    $triggerPublishReady = Get-FileSnapshot -Path $publishReadyPath
    $archivedPublishReadyPath = ''
    if (-not [bool]$triggerPublishReady.Exists) {
        $archivedPublishReadyPath = Get-LatestArchivedPublishReadyPath -PublishReadyPath $publishReadyPath
        if (Test-NonEmptyString $archivedPublishReadyPath) {
            $triggerPublishReady = Get-FileSnapshot -Path $archivedPublishReadyPath
        }
    }
    $triggerPublishReadyDocument = Read-JsonObjectSafe -Path ([string]$triggerPublishReady.Path)
    $triggerPublishedAt = [string](Get-ObjectPropertyValue -Object $triggerPublishReadyDocument -Name 'PublishedAt' -DefaultValue '')
    $triggerPublishAttemptId = [string](Get-ObjectPropertyValue -Object $triggerPublishReadyDocument -Name 'AttemptId' -DefaultValue '')
    $triggerPublishSequence = ConvertTo-IntOrDefault -Value (Get-ObjectPropertyValue -Object $triggerPublishReadyDocument -Name 'PublishSequence' -DefaultValue 0)
    $triggerPublishCycleId = [string](Get-ObjectPropertyValue -Object $triggerPublishReadyDocument -Name 'PublishCycleId' -DefaultValue '')
    $observedPublishReadyPath = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'ArchivedReadyPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $observedPublishReadyPath)) {
        $observedPublishReadyPath = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'PublishReadyPath' -DefaultValue '')
    }
    if (-not (Test-NonEmptyString $observedPublishReadyPath)) {
        $observedPublishReadyPath = if (Test-NonEmptyString ([string]$triggerPublishReady.Path)) { [string]$triggerPublishReady.Path } else { $publishReadyPath }
    }
    $observedPublishReady = Get-FileSnapshot -Path $observedPublishReadyPath
    $observedPublishReadyDocument = Read-JsonObjectSafe -Path $observedPublishReadyPath
    $observedPublishedAt = [string](Get-ObjectPropertyValue -Object $observedPublishReadyDocument -Name 'PublishedAt' -DefaultValue ([string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'PublishedAt' -DefaultValue '')))
    $observedPublishAttemptId = [string](Get-ObjectPropertyValue -Object $observedPublishReadyDocument -Name 'AttemptId' -DefaultValue '')
    $observedPublishSequence = ConvertTo-IntOrDefault -Value (Get-ObjectPropertyValue -Object $observedPublishReadyDocument -Name 'PublishSequence' -DefaultValue (Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'PublishSequence' -DefaultValue 0))
    $observedPublishCycleId = [string](Get-ObjectPropertyValue -Object $observedPublishReadyDocument -Name 'PublishCycleId' -DefaultValue ([string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'PublishCycleId' -DefaultValue '')))
    $sourceOutboxUpdatedAt = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'UpdatedAt' -DefaultValue ([string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SourceOutboxUpdatedAt' -DefaultValue '')))
    $messageFile = Get-FileSnapshot -Path $messagePath
    $requestFile = Get-FileSnapshot -Path $requestPath
    $processedFile = Get-FileSnapshot -Path $processedPath
    $processedPayloadSnapshotPath = if (Test-NonEmptyString $processedPath) { ($processedPath + '.payload.txt') } else { '' }
    $processedPayloadSnapshot = Get-FileSnapshot -Path $processedPayloadSnapshotPath
    $latestPrepareLog = Get-FileSnapshot -Path $latestPrepareLogPath
    $latestAhkLog = Get-FileSnapshot -Path $latestAhkLogPath
    $ahkLifecycle = Get-AhkLifecycleSummary -LogPath $latestAhkLogPath
    $payloadForbiddenArtifact = Get-ForbiddenArtifactMatchFromFile -Path $processedPayloadSnapshotPath -Policy $ForbiddenArtifactPolicy
    $sourceSummaryForbiddenArtifact = Get-ForbiddenArtifactMatchFromFile -Path $sourceSummaryPath -Policy $ForbiddenArtifactPolicy
    $sourceReviewZipForbiddenArtifact = Get-ForbiddenArtifactMatchFromZip -Path $sourceReviewZipPath -Policy $ForbiddenArtifactPolicy
    $resultPathCandidate = if (Test-NonEmptyString $targetFolder) { Join-Path $targetFolder 'result.json' } else { '' }
    $resultDocument = Read-JsonObjectSafe -Path $resultPathCandidate
    $resultCompletedAt = [string](Get-ObjectPropertyValue -Object $resultDocument -Name 'CompletedAt' -DefaultValue '')
    $resultSummaryPath = [string](Get-ObjectPropertyValue -Object $resultDocument -Name 'SummaryPath' -DefaultValue '')
    $resultLatestZipPath = [string](Get-ObjectPropertyValue -Object $resultDocument -Name 'LatestZipPath' -DefaultValue ([string](Get-ObjectPropertyValue -Object $resultDocument -Name 'ImportedZipPath' -DefaultValue '')))
    $resultSourcePublishReadyPath = [string](Get-ObjectPropertyValue -Object $resultDocument -Name 'SourcePublishReadyPath' -DefaultValue '')
    $resultSourcePublishedAt = [string](Get-ObjectPropertyValue -Object $resultDocument -Name 'SourcePublishedAt' -DefaultValue '')
    $resultSourcePublishAttemptId = [string](Get-ObjectPropertyValue -Object $resultDocument -Name 'SourcePublishAttemptId' -DefaultValue '')
    $resultSourcePublishSequence = ConvertTo-IntOrDefault -Value (Get-ObjectPropertyValue -Object $resultDocument -Name 'SourcePublishSequence' -DefaultValue 0)
    $resultSourcePublishCycleId = [string](Get-ObjectPropertyValue -Object $resultDocument -Name 'SourcePublishCycleId' -DefaultValue '')
    $effectiveWorkingDirectory = [string](Get-ObjectPropertyValue -Object $resultDocument -Name 'EffectiveWorkingDirectory' -DefaultValue '')
    if (-not (Test-NonEmptyString $effectiveWorkingDirectory)) {
        $effectiveWorkingDirectory = if (Test-NonEmptyString $workRepoRoot) { $workRepoRoot } else { $targetFolder }
    }
    $importedSummaryPath = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SummaryPath' -DefaultValue $resultSummaryPath)
    $importedReviewCopyPath = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'LatestZipPath' -DefaultValue $resultLatestZipPath)
    $importedSummarySnapshot = Get-FileSnapshot -Path $importedSummaryPath
    $importedReviewCopySnapshot = Get-FileSnapshot -Path $importedReviewCopyPath
    $importedCopyMatchesObservedPublish = $null
    if ((Test-NonEmptyString $resultSourcePublishCycleId) -and (Test-NonEmptyString $observedPublishCycleId)) {
        $importedCopyMatchesObservedPublish = ([string]$resultSourcePublishCycleId -eq [string]$observedPublishCycleId)
    }
    elseif (($resultSourcePublishSequence -gt 0) -and ($observedPublishSequence -gt 0)) {
        $importedCopyMatchesObservedPublish = ([int]$resultSourcePublishSequence -eq [int]$observedPublishSequence)
    }
    elseif ((Test-NonEmptyString $resultSourcePublishedAt) -and (Test-NonEmptyString $observedPublishedAt)) {
        $importedCopyMatchesObservedPublish = ([string]$resultSourcePublishedAt -eq [string]$observedPublishedAt)
    }
    elseif ((Test-NonEmptyString $resultSourcePublishAttemptId) -and (Test-NonEmptyString $observedPublishAttemptId)) {
        $importedCopyMatchesObservedPublish = ([string]$resultSourcePublishAttemptId -eq [string]$observedPublishAttemptId)
    }
    elseif ((Test-NonEmptyString $resultSourcePublishReadyPath) -and (Test-NonEmptyString $observedPublishReadyPath)) {
        $importedCopyMatchesObservedPublish = (Test-NormalizedPathMatch -Left $resultSourcePublishReadyPath -Right $observedPublishReadyPath)
    }
    $currentTriggerAheadOfObservedCycle = $false
    if (($triggerPublishSequence -gt 0) -and ($observedPublishSequence -gt 0) -and ($triggerPublishSequence -ne $observedPublishSequence)) {
        $currentTriggerAheadOfObservedCycle = ($triggerPublishSequence -gt $observedPublishSequence)
    }
    elseif ((Test-NonEmptyString $triggerPublishedAt) -and (Test-NonEmptyString $observedPublishedAt) -and ([string]$triggerPublishedAt -ne [string]$observedPublishedAt)) {
        $currentTriggerAheadOfObservedCycle = [bool](Test-DateTimeOnOrAfter -Later $triggerPublishedAt -Earlier $observedPublishedAt)
    }
    elseif (
        [bool]$triggerPublishReady.Exists -and
        [bool]$observedPublishReady.Exists -and
        -not (Test-NormalizedPathMatch -Left ([string]$triggerPublishReady.Path) -Right ([string]$observedPublishReady.Path))
    ) {
        $currentTriggerAheadOfObservedCycle = [bool](Test-DateTimeOnOrAfter -Later ([string]$triggerPublishReady.LastWriteAt) -Earlier ([string]$observedPublishReady.LastWriteAt))
    }
    $importedSummaryCreatedAt = if (
        (Test-NonEmptyString $resultCompletedAt) -and
        (Test-NonEmptyString $resultSummaryPath) -and
        (Test-NormalizedPathMatch -Left $importedSummaryPath -Right $resultSummaryPath)
    ) {
        $resultCompletedAt
    }
    elseif ([bool]$importedSummarySnapshot.Exists) {
        [string]$importedSummarySnapshot.LastWriteAt
    }
    else {
        [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SummaryModifiedAt' -DefaultValue '')
    }
    $importedReviewCopyCreatedAt = if (
        (Test-NonEmptyString $resultCompletedAt) -and
        (Test-NonEmptyString $resultLatestZipPath) -and
        (Test-NormalizedPathMatch -Left $importedReviewCopyPath -Right $resultLatestZipPath)
    ) {
        $resultCompletedAt
    }
    elseif ([bool]$importedReviewCopySnapshot.Exists) {
        [string]$importedReviewCopySnapshot.LastWriteAt
    }
    else {
        [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'LatestZipModifiedAt' -DefaultValue '')
    }
    $doneWrittenAt = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'DoneModifiedAt' -DefaultValue '')
    $resultWrittenAt = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'ResultModifiedAt' -DefaultValue '')
    $watcherReadyObservedAt = $sourceOutboxUpdatedAt
    $handoffOpenedAt = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'ForwardedAt' -DefaultValue '')
    $summaryWrittenAt = [string]$sourceSummary.LastWriteAt
    $reviewZipWrittenAt = [string]$sourceReviewZip.LastWriteAt
    $publishReadyWrittenAt = if ([bool]$observedPublishReady.Exists) { [string]$observedPublishReady.LastWriteAt } else { [string]$triggerPublishReady.LastWriteAt }
    $triggerArtifactsCompletedAt = if ($currentTriggerAheadOfObservedCycle -and (Test-NonEmptyString $observedPublishedAt)) {
        $observedPublishedAt
    }
    else {
        Get-LatestTimestamp -Values @($summaryWrittenAt, $reviewZipWrittenAt, $publishReadyWrittenAt)
    }
    $currentArtifactsAheadOfObservedPublish = $false
    $latestArtifactWriteAt = Get-LatestTimestamp -Values @($summaryWrittenAt, $reviewZipWrittenAt)
    if ((Test-NonEmptyString $latestArtifactWriteAt) -and (Test-NonEmptyString $publishReadyWrittenAt)) {
        $currentArtifactsAheadOfObservedPublish = -not (Test-DateTimeOnOrAfter -Later $publishReadyWrittenAt -Earlier $latestArtifactWriteAt)
    }
    $timeline = [pscustomobject]@{
        AttemptId                  = [string]$attemptInfo.AttemptId
        AttemptStartedAt           = [string]$attemptInfo.AttemptStartedAt
        SummaryWrittenAt           = $summaryWrittenAt
        ReviewZipWrittenAt         = $reviewZipWrittenAt
        PublishReadyWrittenAt      = $publishReadyWrittenAt
        TriggerArtifactsCompletedAt = $triggerArtifactsCompletedAt
        WatcherReadyObservedAt     = $watcherReadyObservedAt
        HandoffOpenedAt            = $handoffOpenedAt
        RouterProcessedAt          = [string]$processedFile.LastWriteAt
        SendBeginAt                = [string]$ahkLifecycle.SendBeginAt
        PayloadEnteredAt           = [string]$ahkLifecycle.PayloadEnteredAt
        SubmitStartedAt            = [string]$ahkLifecycle.SubmitStartedAt
        SubmitCompletedAt          = [string]$ahkLifecycle.SubmitCompletedAt
        SendCompletedAt            = [string]$ahkLifecycle.SendCompletedAt
        ImportedSummaryCreatedAt   = $importedSummaryCreatedAt
        ImportedReviewCopyCreatedAt = $importedReviewCopyCreatedAt
        ImportCompletedAt          = $resultCompletedAt
        DoneWrittenAt              = $doneWrittenAt
        ResultWrittenAt            = $resultWrittenAt
    }
    $timelineChecks = [pscustomobject]@{
        PublishAfterArtifacts         = if ($currentTriggerAheadOfObservedCycle) { $null } else { (Test-DateTimeOnOrAfter -Later $publishReadyWrittenAt -Earlier (Get-LatestTimestamp -Values @($summaryWrittenAt, $reviewZipWrittenAt))) }
        CurrentArtifactsAheadOfObservedPublish = $currentArtifactsAheadOfObservedPublish
        WatcherObservedAfterPublish   = (Test-DateTimeOnOrAfter -Later $watcherReadyObservedAt -Earlier $publishReadyWrittenAt)
        HandoffOpenedAfterPublish     = (Test-DateTimeOnOrAfter -Later $handoffOpenedAt -Earlier $publishReadyWrittenAt)
        ImportedCopyAfterTrigger      = if ($importedCopyMatchesObservedPublish -is [bool] -and -not $importedCopyMatchesObservedPublish) { $null } else { (Test-DateTimeOnOrAfter -Later $importedReviewCopyCreatedAt -Earlier $triggerArtifactsCompletedAt) }
        ImportedSummaryAfterTrigger   = if ($importedCopyMatchesObservedPublish -is [bool] -and -not $importedCopyMatchesObservedPublish) { $null } else { (Test-DateTimeOnOrAfter -Later $importedSummaryCreatedAt -Earlier $triggerArtifactsCompletedAt) }
        SubmitCompletedAfterAttempt   = (Test-DateTimeOnOrAfter -Later ([string]$ahkLifecycle.SubmitCompletedAt) -Earlier ([string]$attemptInfo.AttemptStartedAt))
    }
    $firstOrderingViolation = Get-FirstOrderingViolation `
        -SummaryWrittenAt $summaryWrittenAt `
        -ReviewZipWrittenAt $reviewZipWrittenAt `
        -PublishReadyWrittenAt $publishReadyWrittenAt `
        -ImportedReviewCopyCreatedAt $importedReviewCopyCreatedAt `
        -ImportedSummaryCreatedAt $importedSummaryCreatedAt `
        -TriggerArtifactsCompletedAt $triggerArtifactsCompletedAt `
        -CurrentArtifactsAheadOfObservedPublish:$currentArtifactsAheadOfObservedPublish `
        -TimelineChecks $timelineChecks
    $missingContractFiles = New-Object System.Collections.Generic.List[string]
    if (-not [bool]$sourceSummary.Exists) {
        $missingContractFiles.Add('summary.txt')
    }
    if (-not [bool]$sourceReviewZip.Exists) {
        $missingContractFiles.Add('review.zip')
    }
    if (-not [bool]$triggerPublishReady.Exists) {
        $missingContractFiles.Add('publish.ready.json')
    }

    return [pscustomobject]@{
        PairId             = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'PairId' -DefaultValue (Get-ObjectPropertyValue -Object $ManifestTarget -Name 'PairId' -DefaultValue ''))
        PartnerTargetId    = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'PartnerTargetId' -DefaultValue (Get-ObjectPropertyValue -Object $ManifestTarget -Name 'PartnerTargetId' -DefaultValue ''))
        TargetId           = $targetId
        RoleName           = [string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'RoleName' -DefaultValue (Get-ObjectPropertyValue -Object $ManifestTarget -Name 'RoleName' -DefaultValue ''))
        AttemptId          = [string]$attemptInfo.AttemptId
        AttemptStartedAt   = [string]$attemptInfo.AttemptStartedAt
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
        SourceOutboxOriginalReadyReason = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'OriginalReadyReason' -DefaultValue '')
        SourceOutboxFinalReadyReason = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'FinalReadyReason' -DefaultValue '')
        SourceOutboxRepairAttempted = [bool](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'RepairAttempted' -DefaultValue $false)
        SourceOutboxRepairSucceeded = [bool](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'RepairSucceeded' -DefaultValue $false)
        SourceOutboxRepairCompletedAt = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'RepairCompletedAt' -DefaultValue '')
        SourceOutboxRepairMessage = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'RepairMessage' -DefaultValue '')
        SourceOutboxRepairCommand = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'RepairCommand' -DefaultValue '')
        SourceOutboxRepairSourceContext = [string](Get-ObjectPropertyValue -Object $SourceOutboxStatusTarget -Name 'RepairSourceContext' -DefaultValue '')
        InitialRoleMode    = $initialRoleMode
        ContractPathMode   = $contractPathMode
        ContractRootPath   = $contractRootPath
        ContractReferenceTimeUtc = $contractReferenceTimeUtc
        WorkRepoRoot       = $workRepoRoot
        PairRunRoot        = $pairRunRoot
        EffectiveWorkingDirectory = $effectiveWorkingDirectory
        ReviewInputPath    = $reviewInputPath
        MessagePath        = $messagePath
        MessageFile        = $messageFile
        MessagePreview     = Get-FilePreviewText -Path $messagePath
        RequestPath        = $requestPath
        RequestFile        = $requestFile
        CurrentTriggerSummaryPath = $sourceSummaryPath
        CurrentTriggerReviewZipPath = $sourceReviewZipPath
        CurrentTriggerPublishReadyPath = $publishReadyPath
        CurrentTriggerSourceOutboxPath = $sourceOutboxPath
        CurrentObservedPublishReadyPath = if (Test-NonEmptyString ([string]$observedPublishReady.Path)) { [string]$observedPublishReady.Path } else { $observedPublishReadyPath }
        CurrentArchivedPublishReadyPath = $archivedPublishReadyPath
        CurrentTriggerPublishSequence = $triggerPublishSequence
        CurrentTriggerPublishCycleId = $triggerPublishCycleId
        CurrentObservedPublishSequence = $observedPublishSequence
        CurrentObservedPublishCycleId = $observedPublishCycleId
        CurrentImportedSummaryPath = $importedSummaryPath
        CurrentImportedReviewCopyPath = $importedReviewCopyPath
        CurrentImportedSourcePublishSequence = $resultSourcePublishSequence
        CurrentImportedSourcePublishCycleId = $resultSourcePublishCycleId
        CurrentTriggerAheadOfObservedCycle = $currentTriggerAheadOfObservedCycle
        CurrentArtifactsAheadOfObservedPublish = $currentArtifactsAheadOfObservedPublish
        ImportedCopyMatchesObservedPublish = $importedCopyMatchesObservedPublish
        ProcessedPath      = $processedPath
        ProcessedFile      = $processedFile
        ProcessedPayloadSnapshotPath = $processedPayloadSnapshotPath
        ProcessedPayloadSnapshot = $processedPayloadSnapshot
        ProcessedPayloadSnapshotPreview = Get-FilePreviewText -Path $processedPayloadSnapshotPath
        PayloadContainsForbiddenLiteral = [bool]$payloadForbiddenArtifact.Found
        PayloadForbiddenArtifact = $payloadForbiddenArtifact
        SourceSummaryContainsForbiddenLiteral = [bool]$sourceSummaryForbiddenArtifact.Found
        SourceSummaryForbiddenArtifact = $sourceSummaryForbiddenArtifact
        SourceReviewZipContainsForbiddenLiteral = [bool]$sourceReviewZipForbiddenArtifact.Found
        SourceReviewZipForbiddenArtifact = $sourceReviewZipForbiddenArtifact
        ForwardBlockedByForbiddenLiteral = ([string](Get-ObjectPropertyValue -Object $StatusTarget -Name 'SourceOutboxState' -DefaultValue '') -in @('source-summary-forbidden-literal', 'source-reviewzip-forbidden-literal'))
        SourceSummary      = $sourceSummary
        SourceReviewZip    = $sourceReviewZip
        PublishReady       = $triggerPublishReady
        Timeline           = $timeline
        TimelineChecks     = $timelineChecks
        FirstOrderingViolation = $firstOrderingViolation
        ContractArtifactsReady = ($missingContractFiles.Count -eq 0)
        MissingContractFiles = @($missingContractFiles)
        LatestPrepareLog   = $latestPrepareLog
        LatestPrepareLogPath = $latestPrepareLogPath
        LatestAhkLog       = $latestAhkLog
        LatestAhkLogPath   = $latestAhkLogPath
    }
}

function Get-UniqueNonEmptyStrings {
    param([object[]]$Values)

    $seen = @{}
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        $text = [string]$value
        if (-not (Test-NonEmptyString $text)) {
            continue
        }

        $key = $text.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $items.Add($text)
    }

    return @($items)
}

function Get-PairRouteState {
    param(
        [bool]$TargetsShareWorkRepoRoot,
        [bool]$TargetsSharePairRunRoot,
        [bool]$TargetOutboxesDistinct
    )

    if (-not $TargetsShareWorkRepoRoot) {
        return 'mismatched-workrepo'
    }
    if (-not $TargetsSharePairRunRoot) {
        return 'mismatched-pair-runroot'
    }
    if (-not $TargetOutboxesDistinct) {
        return 'outbox-collision-risk'
    }

    return 'aligned'
}

function Get-ImportantPairRouteMatrix {
    param(
        [object[]]$Pairs,
        [object[]]$Targets
    )

    $pairRefs = @()
    foreach ($pair in @($Pairs)) {
        if ($null -eq $pair) {
            continue
        }

        $pairId = [string](Get-ObjectPropertyValue -Object $pair -Name 'PairId' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId)) {
            continue
        }

        $pairRefs += [pscustomobject]@{
            PairId = $pairId
            Pair   = $pair
        }
    }
    foreach ($target in @($Targets)) {
        if ($null -eq $target) {
            continue
        }

        $pairId = [string](Get-ObjectPropertyValue -Object $target -Name 'PairId' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId)) {
            continue
        }
        if ((@($pairRefs | Where-Object { [string]$_.PairId -eq $pairId })).Count -gt 0) {
            continue
        }

        $pairRefs += [pscustomobject]@{
            PairId = $pairId
            Pair   = $null
        }
    }

    $matrix = @()
    foreach ($pairRef in @($pairRefs)) {
        $pairId = [string](Get-ObjectPropertyValue -Object $pairRef -Name 'PairId' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId)) {
            continue
        }

        $pairTargets = @()
        foreach ($candidateTarget in @($Targets)) {
            if ($null -eq $candidateTarget) {
                continue
            }
            if ([string](Get-ObjectPropertyValue -Object $candidateTarget -Name 'PairId' -DefaultValue '') -eq $pairId) {
                $pairTargets += $candidateTarget
            }
        }
        if ($pairTargets.Count -eq 0) {
            continue
        }

        $top = $null
        $bottom = $null
        foreach ($pairTarget in @($pairTargets)) {
            $roleName = [string](Get-ObjectPropertyValue -Object $pairTarget -Name 'RoleName' -DefaultValue '')
            if ($null -eq $top -and $roleName -eq 'top') {
                $top = $pairTarget
                continue
            }
            if ($null -eq $bottom -and $roleName -eq 'bottom') {
                $bottom = $pairTarget
                continue
            }
        }
        if ($null -eq $top -and $pairTargets.Count -gt 0) {
            $top = $pairTargets[0]
        }
        if ($null -eq $bottom) {
            foreach ($pairTarget in @($pairTargets)) {
                if ($pairTarget -ne $top) {
                    $bottom = $pairTarget
                    break
                }
            }
        }

        $workRepoRootValues = @()
        $pairRunRootValues = @()
        $sourceOutboxValues = @()
        foreach ($pairTarget in @($pairTargets)) {
            $workRepoRootValues += [string](Get-ObjectPropertyValue -Object $pairTarget -Name 'WorkRepoRoot' -DefaultValue '')
            $pairRunRootValues += [string](Get-ObjectPropertyValue -Object $pairTarget -Name 'PairRunRoot' -DefaultValue '')
            $sourceOutboxValues += [string](Get-ObjectPropertyValue -Object $pairTarget -Name 'CurrentTriggerSourceOutboxPath' -DefaultValue '')
        }

        $workRepoRoots = @(Get-UniqueNonEmptyStrings -Values $workRepoRootValues)
        $pairRunRoots = @(Get-UniqueNonEmptyStrings -Values $pairRunRootValues)
        $sourceOutboxes = @(Get-UniqueNonEmptyStrings -Values $sourceOutboxValues)

        $targetsShareWorkRepoRoot = ($workRepoRoots.Count -eq 1)
        $targetsSharePairRunRoot = ($pairRunRoots.Count -eq 1)
        $targetOutboxesDistinct = ($sourceOutboxes.Count -eq $pairTargets.Count)
        $sharedWorkRepoRoot = ''
        if ($workRepoRoots.Count -eq 1) {
            $sharedWorkRepoRoot = [string]$workRepoRoots[0]
        }
        $pairRunRootValue = ''
        if ($pairRunRoots.Count -eq 1) {
            $pairRunRootValue = [string]$pairRunRoots[0]
        }

        $sharesWorkRepoRootWithOtherPairs = $false
        if (Test-NonEmptyString $sharedWorkRepoRoot) {
            foreach ($otherTarget in @($Targets)) {
                if ($null -eq $otherTarget) {
                    continue
                }

                $otherPairId = [string](Get-ObjectPropertyValue -Object $otherTarget -Name 'PairId' -DefaultValue '')
                if (-not (Test-NonEmptyString $otherPairId) -or $otherPairId -eq $pairId) {
                    continue
                }

                $otherWorkRepoRoot = [string](Get-ObjectPropertyValue -Object $otherTarget -Name 'WorkRepoRoot' -DefaultValue '')
                if (Test-NormalizedPathMatch -Left $sharedWorkRepoRoot -Right $otherWorkRepoRoot) {
                    $sharesWorkRepoRootWithOtherPairs = $true
                    break
                }
            }
        }

        $matrix += [pscustomobject]@{
                PairId                      = $pairId
                TopTargetId                 = [string](Get-ObjectPropertyValue -Object $top -Name 'TargetId' -DefaultValue '')
                BottomTargetId              = [string](Get-ObjectPropertyValue -Object $bottom -Name 'TargetId' -DefaultValue '')
                PairWorkRepoRoot            = $sharedWorkRepoRoot
                PairRunRoot                 = $pairRunRootValue
                TopWorkRepoRoot             = [string](Get-ObjectPropertyValue -Object $top -Name 'WorkRepoRoot' -DefaultValue '')
                BottomWorkRepoRoot          = [string](Get-ObjectPropertyValue -Object $bottom -Name 'WorkRepoRoot' -DefaultValue '')
                TopPairRunRoot              = [string](Get-ObjectPropertyValue -Object $top -Name 'PairRunRoot' -DefaultValue '')
                BottomPairRunRoot           = [string](Get-ObjectPropertyValue -Object $bottom -Name 'PairRunRoot' -DefaultValue '')
                TopSourceOutboxPath         = [string](Get-ObjectPropertyValue -Object $top -Name 'CurrentTriggerSourceOutboxPath' -DefaultValue '')
                BottomSourceOutboxPath      = [string](Get-ObjectPropertyValue -Object $bottom -Name 'CurrentTriggerSourceOutboxPath' -DefaultValue '')
                TopPublishReadyPath         = [string](Get-ObjectPropertyValue -Object $top -Name 'CurrentTriggerPublishReadyPath' -DefaultValue '')
                BottomPublishReadyPath      = [string](Get-ObjectPropertyValue -Object $bottom -Name 'CurrentTriggerPublishReadyPath' -DefaultValue '')
                TargetsShareWorkRepoRoot    = $targetsShareWorkRepoRoot
                TargetsSharePairRunRoot     = $targetsSharePairRunRoot
                TargetOutboxesDistinct      = $targetOutboxesDistinct
                SharesWorkRepoRootWithOtherPairs = $sharesWorkRepoRootWithOtherPairs
                RouteState                  = Get-PairRouteState -TargetsShareWorkRepoRoot $targetsShareWorkRepoRoot -TargetsSharePairRunRoot $targetsSharePairRunRoot -TargetOutboxesDistinct $targetOutboxesDistinct
            }
    }

    return @($matrix)
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
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.Timeline -Name 'SubmitStartedAt' -DefaultValue '')) -Text ('{0} submit started' -f $targetId) -Source ($targetId + ':submit-start') -Priority 20 -EventClass 'dispatch' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.Timeline -Name 'SubmitCompletedAt' -DefaultValue '')) -Text ('{0} submit completed' -f $targetId) -Source ($targetId + ':submit-complete') -Priority 16 -EventClass 'dispatch' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
        Add-EventRecord -List $events -At ([string](Get-ObjectPropertyValue -Object $target.Timeline -Name 'ImportedReviewCopyCreatedAt' -DefaultValue '')) -Text ('{0} imported review copy created' -f $targetId) -Source ($targetId + ':imported-review') -Priority 15 -EventClass 'import' -PairId $pairId -TargetId $targetId -IsProgressSignal:$true
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
    $forbiddenArtifactPolicy = Get-ForbiddenArtifactPolicyFromConfig -Config $config
    $logsRoot = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $config -Name 'LogsRoot' -DefaultValue ''))
    $runtimeRoot = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $config -Name 'RuntimeRoot' -DefaultValue ''))
    $inboxRoot = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $config -Name 'InboxRoot' -DefaultValue ''))
    $processedRoot = Normalize-DisplayPath -Path ([string](Get-ObjectPropertyValue -Object $config -Name 'ProcessedRoot' -DefaultValue ''))
    $statusTargetLookup = Get-StatusTargetLookup -Targets @($Status.Targets)
    $sourceOutboxStatusSummary = Get-SourceOutboxStatusSummary -RunRoot $RunRoot
    $sourceOutboxTargetLookup = Get-StatusTargetLookup -Targets @($sourceOutboxStatusSummary.Targets)

    $importantTargets = @()
    foreach ($manifestTarget in @($manifestSummary.Targets)) {
        $targetId = [string](Get-ObjectPropertyValue -Object $manifestTarget -Name 'TargetId' -DefaultValue '')
        $statusTarget = $null
        $sourceOutboxStatusTarget = $null
        if (Test-NonEmptyString $targetId -and $statusTargetLookup.ContainsKey($targetId)) {
            $statusTarget = $statusTargetLookup[$targetId]
        }
        if (Test-NonEmptyString $targetId -and $sourceOutboxTargetLookup.ContainsKey($targetId)) {
            $sourceOutboxStatusTarget = $sourceOutboxTargetLookup[$targetId]
        }

        $importantTargets += Get-ImportantTargetSummary -ManifestTarget $manifestTarget -StatusTarget $statusTarget -SourceOutboxStatusTarget $sourceOutboxStatusTarget -LogsRoot $logsRoot -ForbiddenArtifactPolicy $forbiddenArtifactPolicy
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
    $pairRouteMatrix = Get-ImportantPairRouteMatrix -Pairs @($importantPairs) -Targets @($importantTargets)
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
        PairRouteMatrix = @($pairRouteMatrix)
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

    $lines.Add('')
    $lines.Add('[pair-route-matrix]')
    if ((@($ImportantSummary.PairRouteMatrix)).Count -eq 0) {
        $lines.Add('(none)')
    }
    else {
        foreach ($route in @($ImportantSummary.PairRouteMatrix)) {
            $pairId = [string](Get-ObjectPropertyValue -Object $route -Name 'PairId' -DefaultValue '')
            $topTargetId = [string](Get-ObjectPropertyValue -Object $route -Name 'TopTargetId' -DefaultValue '')
            $bottomTargetId = [string](Get-ObjectPropertyValue -Object $route -Name 'BottomTargetId' -DefaultValue '')
            $lines.Add(('[pair {0}] routeState={1} top={2} bottom={3}' -f $pairId, [string]$route.RouteState, $topTargetId, $bottomTargetId))
            $lines.Add(('PairWorkRepoRoot: {0}' -f [string]$route.PairWorkRepoRoot))
            $lines.Add(('PairRunRoot: {0}' -f [string]$route.PairRunRoot))
            $lines.Add(('TargetsShareWorkRepoRoot: {0}' -f [bool]$route.TargetsShareWorkRepoRoot))
            $lines.Add(('TargetsSharePairRunRoot: {0}' -f [bool]$route.TargetsSharePairRunRoot))
            $lines.Add(('TargetOutboxesDistinct: {0}' -f [bool]$route.TargetOutboxesDistinct))
            $lines.Add(('SharesWorkRepoRootWithOtherPairs: {0}' -f [bool]$route.SharesWorkRepoRootWithOtherPairs))
            $lines.Add(('TopSourceOutboxPath: {0}' -f [string]$route.TopSourceOutboxPath))
            $lines.Add(('BottomSourceOutboxPath: {0}' -f [string]$route.BottomSourceOutboxPath))
            $lines.Add(('TopPublishReadyPath: {0}' -f [string]$route.TopPublishReadyPath))
            $lines.Add(('BottomPublishReadyPath: {0}' -f [string]$route.BottomPublishReadyPath))
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
        $lines.Add(('PairRunRoot: {0}' -f [string]$target.PairRunRoot))
        $lines.Add(('EffectiveWorkingDirectory: {0}' -f [string]$target.EffectiveWorkingDirectory))
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
        if (Test-NonEmptyString ([string]$target.SourceOutboxOriginalReadyReason)) {
            $lines.Add(('SourceOutboxOriginalReadyReason: {0}' -f [string]$target.SourceOutboxOriginalReadyReason))
        }
        if (Test-NonEmptyString ([string]$target.SourceOutboxFinalReadyReason)) {
            $lines.Add(('SourceOutboxFinalReadyReason: {0}' -f [string]$target.SourceOutboxFinalReadyReason))
        }
        if ([bool]$target.SourceOutboxRepairAttempted -or (Test-NonEmptyString ([string]$target.SourceOutboxRepairMessage))) {
            $lines.Add(('SourceOutboxRepairAttempted: {0}' -f [bool]$target.SourceOutboxRepairAttempted))
            $lines.Add(('SourceOutboxRepairSucceeded: {0}' -f [bool]$target.SourceOutboxRepairSucceeded))
            if (Test-NonEmptyString ([string]$target.SourceOutboxRepairCompletedAt)) {
                $lines.Add(('SourceOutboxRepairCompletedAt: {0}' -f [string]$target.SourceOutboxRepairCompletedAt))
            }
            if (Test-NonEmptyString ([string]$target.SourceOutboxRepairSourceContext)) {
                $lines.Add(('SourceOutboxRepairSourceContext: {0}' -f [string]$target.SourceOutboxRepairSourceContext))
            }
            if (Test-NonEmptyString ([string]$target.SourceOutboxRepairMessage)) {
                $lines.Add(('SourceOutboxRepairMessage: {0}' -f [string]$target.SourceOutboxRepairMessage))
            }
        }
        $lines.Add(('CurrentTriggerSourceOutboxPath: {0}' -f [string]$target.CurrentTriggerSourceOutboxPath))
        $lines.Add(('CurrentTriggerSummaryPath: {0}' -f [string]$target.CurrentTriggerSummaryPath))
        $lines.Add(('CurrentTriggerReviewZipPath: {0}' -f [string]$target.CurrentTriggerReviewZipPath))
        $lines.Add(('CurrentTriggerPublishReadyPath: {0}' -f [string]$target.CurrentTriggerPublishReadyPath))
        $lines.Add(('CurrentObservedPublishReadyPath: {0}' -f [string]$target.CurrentObservedPublishReadyPath))
        if (Test-NonEmptyString ([string]$target.CurrentArchivedPublishReadyPath)) {
            $lines.Add(('CurrentArchivedPublishReadyPath: {0}' -f [string]$target.CurrentArchivedPublishReadyPath))
        }
        if ([int]$target.CurrentTriggerPublishSequence -gt 0) {
            $lines.Add(('CurrentTriggerPublishSequence: {0}' -f [int]$target.CurrentTriggerPublishSequence))
        }
        if (Test-NonEmptyString ([string]$target.CurrentTriggerPublishCycleId)) {
            $lines.Add(('CurrentTriggerPublishCycleId: {0}' -f [string]$target.CurrentTriggerPublishCycleId))
        }
        if ([int]$target.CurrentObservedPublishSequence -gt 0) {
            $lines.Add(('CurrentObservedPublishSequence: {0}' -f [int]$target.CurrentObservedPublishSequence))
        }
        if (Test-NonEmptyString ([string]$target.CurrentObservedPublishCycleId)) {
            $lines.Add(('CurrentObservedPublishCycleId: {0}' -f [string]$target.CurrentObservedPublishCycleId))
        }
        if (Test-NonEmptyString ([string]$target.CurrentImportedSummaryPath)) {
            $lines.Add(('CurrentImportedSummaryPath: {0}' -f [string]$target.CurrentImportedSummaryPath))
        }
        $lines.Add(('CurrentImportedReviewCopyPath: {0}' -f [string]$target.CurrentImportedReviewCopyPath))
        if ([int]$target.CurrentImportedSourcePublishSequence -gt 0) {
            $lines.Add(('CurrentImportedSourcePublishSequence: {0}' -f [int]$target.CurrentImportedSourcePublishSequence))
        }
        if (Test-NonEmptyString ([string]$target.CurrentImportedSourcePublishCycleId)) {
            $lines.Add(('CurrentImportedSourcePublishCycleId: {0}' -f [string]$target.CurrentImportedSourcePublishCycleId))
        }
        $lines.Add(('CurrentTriggerAheadOfObservedCycle: {0}' -f [string]$target.CurrentTriggerAheadOfObservedCycle))
        $lines.Add(('CurrentArtifactsAheadOfObservedPublish: {0}' -f [string]$target.CurrentArtifactsAheadOfObservedPublish))
        $lines.Add(('ImportedCopyMatchesObservedPublish: {0}' -f [string]$target.ImportedCopyMatchesObservedPublish))
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
        $lines.Add(('AttemptId: {0}' -f [string]$target.AttemptId))
        $lines.Add(('AttemptStartedAt: {0}' -f [string]$target.AttemptStartedAt))
        $lines.Add(('Timeline: summaryAt={0} reviewZipAt={1} publishReadyAt={2} watcherReadyAt={3} handoffOpenedAt={4}' -f [string]$target.Timeline.SummaryWrittenAt, [string]$target.Timeline.ReviewZipWrittenAt, [string]$target.Timeline.PublishReadyWrittenAt, [string]$target.Timeline.WatcherReadyObservedAt, [string]$target.Timeline.HandoffOpenedAt))
        $lines.Add(('TimelineDispatch: routerProcessedAt={0} sendBeginAt={1} payloadEnteredAt={2} submitStartedAt={3} submitCompletedAt={4}' -f [string]$target.Timeline.RouterProcessedAt, [string]$target.Timeline.SendBeginAt, [string]$target.Timeline.PayloadEnteredAt, [string]$target.Timeline.SubmitStartedAt, [string]$target.Timeline.SubmitCompletedAt))
        $lines.Add(('TimelineImport: importedSummaryAt={0} importedReviewCopyAt={1} doneAt={2} resultAt={3}' -f [string]$target.Timeline.ImportedSummaryCreatedAt, [string]$target.Timeline.ImportedReviewCopyCreatedAt, [string]$target.Timeline.DoneWrittenAt, [string]$target.Timeline.ResultWrittenAt))
        $lines.Add(('TimelineChecks: publishAfterArtifacts={0} currentArtifactsAheadOfObservedPublish={1} watcherObservedAfterPublish={2} handoffOpenedAfterPublish={3} importedCopyAfterTrigger={4}' -f [string]$target.TimelineChecks.PublishAfterArtifacts, [string]$target.TimelineChecks.CurrentArtifactsAheadOfObservedPublish, [string]$target.TimelineChecks.WatcherObservedAfterPublish, [string]$target.TimelineChecks.HandoffOpenedAfterPublish, [string]$target.TimelineChecks.ImportedCopyAfterTrigger))
        $lines.Add(('FirstOrderingViolation: {0}' -f [string]$target.FirstOrderingViolation))
        $lines.Add(('PayloadContainsForbiddenLiteral: {0}' -f [bool]$target.PayloadContainsForbiddenLiteral))
        if ([bool]$target.PayloadContainsForbiddenLiteral) {
            $lines.Add(('PayloadForbiddenArtifact: type={0} pattern={1} match={2}' -f [string]$target.PayloadForbiddenArtifact.MatchKind, [string]$target.PayloadForbiddenArtifact.Pattern, [string]$target.PayloadForbiddenArtifact.MatchText))
        }
        $lines.Add(('SourceSummaryContainsForbiddenLiteral: {0}' -f [bool]$target.SourceSummaryContainsForbiddenLiteral))
        if ([bool]$target.SourceSummaryContainsForbiddenLiteral) {
            $lines.Add(('SourceSummaryForbiddenArtifact: type={0} pattern={1} match={2}' -f [string]$target.SourceSummaryForbiddenArtifact.MatchKind, [string]$target.SourceSummaryForbiddenArtifact.Pattern, [string]$target.SourceSummaryForbiddenArtifact.MatchText))
        }
        $lines.Add(('SourceReviewZipContainsForbiddenLiteral: {0}' -f [bool]$target.SourceReviewZipContainsForbiddenLiteral))
        if ([bool]$target.SourceReviewZipContainsForbiddenLiteral) {
            $lines.Add(('SourceReviewZipForbiddenArtifact: type={0} pattern={1} match={2} entry={3}' -f [string]$target.SourceReviewZipForbiddenArtifact.MatchKind, [string]$target.SourceReviewZipForbiddenArtifact.Pattern, [string]$target.SourceReviewZipForbiddenArtifact.MatchText, [string]$target.SourceReviewZipForbiddenArtifact.EntryPath))
        }
        $lines.Add(('ForwardBlockedByForbiddenLiteral: {0}' -f [bool]$target.ForwardBlockedByForbiddenLiteral))
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
