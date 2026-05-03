[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [int]$PollIntervalMs = 1500,
    [int]$RunDurationSec = 0,
    [switch]$UseHeadlessDispatch,
    [switch]$AllowHeadlessDispatchInTypedWindowLane,
    [int]$MaxForwardCount = 0,
    [int]$PairMaxRoundtripCount = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SupportedSourceOutboxSchemaVersions = @('1.0.0', '1.0')
$CurrentPairStateSchemaVersion = '1.0.0'
$SupportedPairStateSchemaVersions = @('1.0.0', '1.0')
$ForbiddenArtifactLiterals = @()
$ForbiddenArtifactRegexes = @()

if ($PSVersionTable.PSEdition -ne 'Core') {
    $currentVersion = [string]$PSVersionTable.PSVersion
    throw ("Watch-PairedExchange.ps1 must be run with pwsh (PowerShell 7+). Current host={0} version={1}. Use: pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Watch-PairedExchange.ps1 ..." -f [string]$PSVersionTable.PSEdition, $currentVersion)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Test-ZipArchiveReadable {
    param([Parameter(Mandatory)][string]$Path)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    }
    catch {
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $null = $archive.Entries.Count
        }
        finally {
            if ($null -ne $archive) {
                $archive.Dispose()
            }
        }

        return [pscustomobject]@{
            Ok = $true
            ErrorMessage = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-TextFileForbiddenArtifactMatch {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-ForbiddenArtifactTextFileMatch -Path $Path -LiteralList @($ForbiddenArtifactLiterals) -RegexPatternList @($ForbiddenArtifactRegexes))
}

function Get-ZipArchiveForbiddenArtifactMatch {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-ForbiddenArtifactZipMatch -Path $Path -LiteralList @($ForbiddenArtifactLiterals) -RegexPatternList @($ForbiddenArtifactRegexes))
}

function Write-JsonFileAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload,
        [int]$Depth = 8,
        [int]$MaxAttempts = 8,
        [int]$RetryDelayMs = 125
    )

    $parent = Split-Path -Parent $Path
    if (Test-NonEmptyString $parent) {
        Ensure-Directory -Path $parent
    }

    $encoding = New-Utf8NoBomEncoding
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $tempPath = ($Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $json = $Payload | ConvertTo-Json -Depth $Depth
            [System.IO.File]::WriteAllText($tempPath, $json, $encoding)
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
            return
        }
        catch {
            $lastError = $_
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }

            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds $RetryDelayMs
                continue
            }
        }
    }

    throw $lastError
}

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }

        if ($command.Source) {
            return [string]$command.Source
        }
        if ($command.Path) {
            return [string]$command.Path
        }
        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Get-HeadlessDispatchStatusPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$TargetId
    )

    return (Join-Path $Root ("dispatch_{0}.json" -f $TargetId))
}

function Save-HeadlessDispatchStatus {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )

    $persisted = [ordered]@{
        SchemaVersion = '1.0.0'
    }

    if ($Payload -is [System.Collections.IDictionary]) {
        foreach ($key in $Payload.Keys) {
            $persisted[[string]$key] = $Payload[$key]
        }
    }
    else {
        foreach ($property in $Payload.PSObject.Properties) {
            $persisted[[string]$property.Name] = $property.Value
        }
    }

    $persisted['UpdatedAt'] = (Get-Date).ToString('o')
    Write-JsonFileAtomically -Path $Path -Payload $persisted -Depth 8
}

function Invoke-HeadlessDispatch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PromptFilePath,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$StatusRoot
    )

    $powershellPath = Resolve-PowerShellExecutable
    $stderrLogPath = ($LogPath + '.stderr')
    $dispatchStatusPath = Get-HeadlessDispatchStatusPath -Root $StatusRoot -TargetId $TargetId
    $startedAt = (Get-Date).ToString('o')
    Save-HeadlessDispatchStatus -Path $dispatchStatusPath -Payload ([ordered]@{
            TargetId       = $TargetId
            RunRoot        = $RunRoot
            ConfigPath     = $ConfigPath
            PromptFilePath = $PromptFilePath
            StdOutPath     = $LogPath
            StdErrPath     = $stderrLogPath
            StartedAt      = $startedAt
            CompletedAt    = ''
            ExitCode       = $null
            State          = 'running'
            Reason         = ''
        })
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'invoke-codex-exec-turn.ps1'),
        '-ConfigPath', $ConfigPath,
        '-RunRoot', $RunRoot,
        '-TargetId', $TargetId,
        '-PromptFilePath', $PromptFilePath
    )
    $process = $null
    try {
        $process = Start-Process -FilePath $powershellPath -ArgumentList $argumentList -Wait -PassThru -NoNewWindow -RedirectStandardOutput $LogPath -RedirectStandardError $stderrLogPath
    }
    catch {
        Save-HeadlessDispatchStatus -Path $dispatchStatusPath -Payload ([ordered]@{
                TargetId       = $TargetId
                RunRoot        = $RunRoot
                ConfigPath     = $ConfigPath
                PromptFilePath = $PromptFilePath
                StdOutPath     = $LogPath
                StdErrPath     = $stderrLogPath
                StartedAt      = $startedAt
                CompletedAt    = (Get-Date).ToString('o')
                ExitCode       = $null
                State          = 'failed'
                Reason         = $_.Exception.Message
            })
        throw
    }

    $completedAt = (Get-Date).ToString('o')
    Save-HeadlessDispatchStatus -Path $dispatchStatusPath -Payload ([ordered]@{
            TargetId       = $TargetId
            RunRoot        = $RunRoot
            ConfigPath     = $ConfigPath
            PromptFilePath = $PromptFilePath
            StdOutPath     = $LogPath
            StdErrPath     = $stderrLogPath
            StartedAt      = $startedAt
            CompletedAt    = $completedAt
            ExitCode       = [int]$process.ExitCode
            State          = if ($process.ExitCode -eq 0) { 'completed' } else { 'failed' }
            Reason         = if ($process.ExitCode -eq 0) { '' } else { ('exit-code:' + [string]$process.ExitCode) }
        })

    if ($process.ExitCode -ne 0) {
        throw "headless dispatch failed target=$TargetId exitCode=$($process.ExitCode) stdout=$LogPath stderr=$stderrLogPath"
    }
}

function Get-PairedWatcherMutexName {
    param([Parameter(Mandatory)][string]$RunRoot)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($RunRoot.ToLowerInvariant())
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return ('Global\RelayPairWatcher_' + $hash)
}

function Acquire-PairedWatcherMutex {
    param([Parameter(Mandatory)][string]$Name)

    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$createdNew)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "paired watcher mutex already held: $Name"
        }

        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Normalize-PairPhase {
    param(
        [string]$Phase = '',
        [string]$WatcherStatus = '',
        [string]$NextAction = '',
        [bool]$LimitReached = $false
    )

    $normalized = if (Test-NonEmptyString $Phase) { $Phase.Trim().ToLowerInvariant() } else { '' }
    switch ($normalized) {
        'seed-running' { return 'seed-running' }
        'partner-running' { return 'partner-running' }
        'waiting-partner-handoff' { return 'waiting-partner-handoff' }
        'waiting-handoff' { return 'waiting-partner-handoff' }
        'waiting-return' { return 'waiting-return' }
        'paused' { return 'paused' }
        'limit-reached' { return 'limit-reached' }
        'manual-attention' { return 'manual-attention' }
        'manual-review' { return 'manual-attention' }
        'error-blocked' { return 'error-blocked' }
        'completed' { return 'completed' }
    }

    if ($LimitReached -or $NextAction -eq 'limit-reached') {
        return 'limit-reached'
    }
    if ($WatcherStatus -eq 'paused') {
        return 'paused'
    }
    if ($NextAction -eq 'manual-review') {
        return 'manual-attention'
    }

    return ''
}

function Get-PairStateSchemaMetadata {
    param($DocumentData)

    if ($null -eq $DocumentData) {
        return [pscustomobject]@{
            SchemaVersion = ''
            DeclaredSchemaVersion = ''
            SchemaStatus = ''
            Warnings = @()
        }
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    $declaredSchemaVersion = [string](Get-ConfigValue -Object $DocumentData -Name 'SchemaVersion' -DefaultValue '')
    $effectiveSchemaVersion = $declaredSchemaVersion
    $schemaStatus = 'current'

    if (-not (Test-NonEmptyString $declaredSchemaVersion)) {
        $effectiveSchemaVersion = $CurrentPairStateSchemaVersion
        $schemaStatus = 'legacy-missing'
        $warnings.Add(('pair-state schema version missing; assuming {0}' -f $CurrentPairStateSchemaVersion))
    }
    elseif ($declaredSchemaVersion -eq $CurrentPairStateSchemaVersion) {
        $schemaStatus = 'current'
    }
    elseif ($declaredSchemaVersion -in $SupportedPairStateSchemaVersions) {
        $schemaStatus = 'legacy-supported'
    }
    else {
        $schemaStatus = 'unsupported'
        $warnings.Add(('unsupported pair-state schema version: {0}' -f $declaredSchemaVersion))
    }

    return [pscustomobject]@{
        SchemaVersion = $effectiveSchemaVersion
        DeclaredSchemaVersion = $declaredSchemaVersion
        SchemaStatus = $schemaStatus
        Warnings = @($warnings)
    }
}

function Load-State {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $parsed = ConvertFrom-RelayJsonText -Json $raw
    $state = @{}
    foreach ($property in $parsed.PSObject.Properties) {
        $state[[string]$property.Name] = [string]$property.Value
    }

    return $state
}

function Save-State {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )

    $ordered = [ordered]@{}
    foreach ($key in ($State.Keys | Sort-Object)) {
        $ordered[$key] = [string]$State[$key]
    }

    Write-JsonFileAtomically -Path $Path -Payload $ordered -Depth 4
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        return (ConvertFrom-RelayJsonText -Json $raw)
    }
    catch {
        return $null
    }
}

function Get-WatcherStopCategory {
    param(
        [Parameter(Mandatory)][string]$State,
        [string]$Reason = ''
    )

    if ($State -notin @('stop_requested', 'stopping', 'stopped')) {
        return ''
    }

    switch ($Reason) {
        'completed' { return 'completed' }
        'max-forward-count-reached' { return 'expected-limit' }
        'pair-roundtrip-limit-reached' { return 'expected-limit' }
        'control-stop-request' { return 'manual-stop' }
        'run-duration-reached' { return 'time-limit' }
        default { return 'error' }
    }
}

function Get-ContractNextAction {
    param([string]$LatestState = '')

    switch ($LatestState) {
        'ready-to-forward' { return 'handoff-ready' }
        'forwarded' { return 'already-forwarded' }
        'error-present' { return 'manual-review' }
        default { return '' }
    }
}

function Save-WatcherStatus {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$MutexName,
        [Parameter(Mandatory)][string]$State,
        [string]$Reason = '',
        [string]$RequestId = '',
        [string]$Action = '',
        [string]$LastHandledRequestId = '',
        [string]$LastHandledAction = '',
        [string]$LastHandledResult = '',
        [string]$LastHandledAt = '',
        [string]$HeartbeatAt = '',
        [int]$StatusSequence = 0,
        [string]$ProcessStartedAt = '',
        [int]$ForwardedCount = 0,
        [int]$ConfiguredMaxForwardCount = 0,
        [int]$ConfiguredRunDurationSec = 0,
        [int]$ConfiguredMaxRoundtripCount = 0,
        [string]$StopCategory = ''
    )

    if (-not (Test-NonEmptyString $StopCategory)) {
        $StopCategory = Get-WatcherStopCategory -State $State -Reason $Reason
    }

    $payload = [ordered]@{
        SchemaVersion        = '1.0.0'
        RunRoot              = $RunRoot
        MutexName            = $MutexName
        State                = $State
        UpdatedAt            = (Get-Date).ToString('o')
        HeartbeatAt          = $HeartbeatAt
        StatusSequence       = $StatusSequence
        ProcessStartedAt     = $ProcessStartedAt
        Reason               = $Reason
        StopCategory         = $StopCategory
        ForwardedCount       = $ForwardedCount
        ConfiguredMaxForwardCount = $ConfiguredMaxForwardCount
        ConfiguredRunDurationSec = $ConfiguredRunDurationSec
        ConfiguredMaxRoundtripCount = $ConfiguredMaxRoundtripCount
        RequestId            = $RequestId
        Action               = $Action
        LastHandledRequestId = $LastHandledRequestId
        LastHandledAction    = $LastHandledAction
        LastHandledResult    = $LastHandledResult
        LastHandledAt        = $LastHandledAt
    }

    Write-JsonFileAtomically -Path $Path -Payload $payload -Depth 4
}

function Get-WatcherControlRequest {
    param([Parameter(Mandatory)][string]$Path)

    $doc = Read-JsonObject -Path $Path
    if ($null -eq $doc) {
        return $null
    }

    if ([string]$doc.Action -notin @('stop', 'pause', 'resume')) {
        return $null
    }

    return $doc
}

function Clear-WatcherControlRequest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$RetryCount = 20,
        [int]$RetryDelayMs = 100
    )

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $true
        }

        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch {
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            return $true
        }

        if ($attempt -lt $RetryCount) {
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }

    return (-not (Test-Path -LiteralPath $Path))
}

function Get-ZipFingerprint {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$ZipFile
    )

    return ('{0}|{1}|{2}|{3}' -f
        [string]$TargetId,
        $ZipFile.FullName.ToLowerInvariant(),
        [int64]$ZipFile.Length,
        [int64]$ZipFile.LastWriteTimeUtc.Ticks
    )
}

function Get-PairForwardedCounts {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$TargetItemsById
    )

    $counts = @{}
    foreach ($stateKey in @($State.Keys)) {
        $rawStateKey = [string]$stateKey
        if (-not (Test-NonEmptyString $rawStateKey)) {
            continue
        }

        $segments = $rawStateKey.Split('|', 2)
        if ($segments.Count -lt 2) {
            continue
        }

        $targetId = [string]$segments[0]
        if (-not (Test-NonEmptyString $targetId)) {
            continue
        }

        $targetItem = Get-ConfigValue -Object $TargetItemsById -Name $targetId -DefaultValue $null
        if ($null -eq $targetItem) {
            continue
        }

        $pairId = [string](Get-ConfigValue -Object $targetItem -Name 'PairId' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId)) {
            continue
        }

        if (-not $counts.ContainsKey($pairId)) {
            $counts[$pairId] = 0
        }
        $counts[$pairId] += 1
    }

    return $counts
}

function Get-ActiveWatcherElapsedSeconds {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [double]$PausedDurationSeconds = 0
    )

    return [math]::Max(0, ($Stopwatch.Elapsed.TotalSeconds - $PausedDurationSeconds))
}

function Get-PairRoundtripLimitMap {
    param(
        [Parameter(Mandatory)][object[]]$TargetItems,
        [int]$GlobalPairMaxRoundtripCount = 0
    )

    $limitMap = @{}
    foreach ($item in @($TargetItems)) {
        $pairId = [string](Get-ConfigValue -Object $item -Name 'PairId' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId) -or $limitMap.ContainsKey($pairId)) {
            continue
        }

        $limit = 0
        if ($GlobalPairMaxRoundtripCount -gt 0) {
            $limit = [int]$GlobalPairMaxRoundtripCount
        }
        else {
            $pairPolicy = Get-ConfigValue -Object $item -Name 'PairPolicy' -DefaultValue $null
            $limit = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0)
        }

        if ($limit -lt 0) {
            $limit = 0
        }
        $limitMap[$pairId] = [int]$limit
    }

    return $limitMap
}

function Test-AllPairsReachedRoundtripLimit {
    param(
        [Parameter(Mandatory)][hashtable]$PairForwardedCounts,
        [Parameter(Mandatory)][hashtable]$PairRoundtripLimitMap
    )

    $pairIds = @($PairRoundtripLimitMap.Keys | ForEach-Object { [string]$_ } | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)
    if ($pairIds.Count -eq 0) {
        return $false
    }

    $hasUnlimitedPair = $false
    $limitedPairCount = 0
    foreach ($pairId in $pairIds) {
        $pairRoundtripLimit = [int](Get-ConfigValue -Object $PairRoundtripLimitMap -Name $pairId -DefaultValue 0)
        if ($pairRoundtripLimit -le 0) {
            $hasUnlimitedPair = $true
            continue
        }

        $limitedPairCount += 1
        $forwardLimit = [math]::Max(1, $pairRoundtripLimit) * 2
        $currentForwardCount = [int](Get-ConfigValue -Object $PairForwardedCounts -Name $pairId -DefaultValue 0)
        if ($currentForwardCount -lt $forwardLimit) {
            return $false
        }
    }

    if ($hasUnlimitedPair) {
        return $false
    }

    return ($limitedPairCount -gt 0)
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

function Get-FileHashHex {
    param([string]$Path)

    if (-not (Test-NonEmptyString $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Get-SourceOutboxPaths {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$Item
    )

    $targetFolder = [string]$Item.TargetFolder
    $sourceOutboxPath = [string](Get-ConfigValue -Object $Item -Name 'SourceOutboxPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $sourceOutboxPath)) {
        $sourceOutboxPath = Join-Path $targetFolder ([string]$PairTest.SourceOutboxFolderName)
    }

    $sourceSummaryPath = [string](Get-ConfigValue -Object $Item -Name 'SourceSummaryPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $sourceSummaryPath)) {
        $sourceSummaryPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    }

    $sourceReviewZipPath = [string](Get-ConfigValue -Object $Item -Name 'SourceReviewZipPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $sourceReviewZipPath)) {
        $sourceReviewZipPath = Join-Path $sourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    }

    $publishReadyPath = [string](Get-ConfigValue -Object $Item -Name 'PublishReadyPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $publishReadyPath)) {
        $publishReadyPath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishReadyFileName)
    }

    $publishedArchivePath = [string](Get-ConfigValue -Object $Item -Name 'PublishedArchivePath' -DefaultValue '')
    if (-not (Test-NonEmptyString $publishedArchivePath)) {
        $publishedArchivePath = Join-Path $sourceOutboxPath ([string]$PairTest.PublishedArchiveFolderName)
    }

    return [pscustomobject]@{
        SourceOutboxPath     = $sourceOutboxPath
        SourceSummaryPath    = $sourceSummaryPath
        SourceReviewZipPath  = $sourceReviewZipPath
        PublishReadyPath     = $publishReadyPath
        PublishedArchivePath = $publishedArchivePath
    }
}

function Read-JsonDocumentWithStatus {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-missing'
            Data = $null
            ErrorMessage = ''
        }
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-empty'
            Data = $null
            ErrorMessage = ''
        }
    }

    try {
        return [pscustomobject]@{
            Ok = $true
            Reason = ''
            Data = (ConvertFrom-RelayJsonText -Json $raw)
            ErrorMessage = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'marker-json-invalid'
            Data = $null
            ErrorMessage = $_.Exception.Message
        }
    }
}

function New-SourceOutboxStateKey {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$Reason,
        [string]$PublishReadyPath = '',
        [int64]$PublishReadyTicks = 0,
        [int64]$SummaryTicks = 0,
        [int64]$ZipTicks = 0
    )

    return ('{0}|{1}|{2}|{3}|{4}|{5}' -f
        [string]$TargetId,
        $Reason,
        (Get-NormalizedFullPath -Path $PublishReadyPath),
        [int64]$PublishReadyTicks,
        [int64]$SummaryTicks,
        [int64]$ZipTicks
    )
}

function Test-SourceOutboxMarkerRepairEligible {
    param([string]$Reason)

    if (-not (Test-NonEmptyString $Reason)) {
        return $false
    }

    if ($Reason -like 'marker-missing-field-*') {
        return $true
    }

    return ($Reason -in @(
            'marker-empty',
            'marker-json-invalid',
            'marker-validation-flag-invalid',
            'marker-validation-not-passed',
            'marker-publisher-unsupported',
            'marker-before-request',
            'marker-before-artifacts',
            'summary-size-mismatch',
            'reviewzip-size-mismatch',
            'summary-hash-mismatch',
            'reviewzip-hash-mismatch'
        ))
}

function Get-SourceOutboxMarkerSuggestedAction {
    param(
        [string]$Reason,
        [bool]$RepairEligible = $false
    )

    if ($RepairEligible) {
        return 'rerun-publish-helper-overwrite'
    }

    if (-not (Test-NonEmptyString $Reason)) {
        return ''
    }

    if ($Reason -in @(
            'marker-pairid-mismatch',
            'marker-targetid-mismatch',
            'marker-summary-path-mismatch',
            'marker-reviewzip-path-mismatch',
            'marker-schema-version-unsupported'
        )) {
        return 'manual-review-source-outbox-marker'
    }

    if ($Reason -in @(
            'source-summary-missing',
            'source-reviewzip-invalid',
            'source-summary-forbidden-literal',
            'source-reviewzip-forbidden-literal'
        )) {
        return 'fix-source-artifacts-before-publish'
    }

    return ''
}

function Get-SourceOutboxMarkerRepairPlan {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Reason
    )

    $eligible = [bool](Test-SourceOutboxMarkerRepairEligible -Reason $Reason)
    $targetId = [string](Get-ConfigValue -Object $Item -Name 'TargetId' -DefaultValue '')
    $wrapperScriptPath = [string](Get-ConfigValue -Object $Item -Name 'PublishScriptPath' -DefaultValue '')
    $wrapperCommandPath = [string](Get-ConfigValue -Object $Item -Name 'PublishCmdPath' -DefaultValue '')
    $repairSourceContext = ('watcher-auto-repair:' + $Reason)
    $displayCommand = ''
    if (Test-NonEmptyString $wrapperScriptPath) {
        $displayCommand = ("& '{0}' -Overwrite -SourceContext '{1}' -AsJson" -f $wrapperScriptPath, $repairSourceContext)
    }
    elseif (Test-NonEmptyString $wrapperCommandPath) {
        $displayCommand = ("& '{0}'" -f $wrapperCommandPath)
    }
    else {
        $displayCommand = ("& '{0}' -ConfigPath '{1}' -RunRoot '{2}' -TargetId '{3}' -Overwrite -SourceContext '{4}' -AsJson" -f
            (Join-Path $Root 'tests\Publish-PairedExchangeArtifact.ps1'),
            $ConfigPath,
            $RunRoot,
            $targetId,
            $repairSourceContext)
    }

    return [pscustomobject]@{
        Eligible          = $eligible
        RepairScriptPath  = (Join-Path $Root 'tests\Publish-PairedExchangeArtifact.ps1')
        RepairArgs        = @(
            '-ConfigPath', $ConfigPath,
            '-RunRoot', $RunRoot,
            '-TargetId', $targetId,
            '-Overwrite',
            '-SourceContext', $repairSourceContext,
            '-AsJson'
        )
        RepairCommand     = $displayCommand
        RepairSourceContext = $repairSourceContext
        ExpectedPublisher = 'publish-paired-exchange-artifact.ps1'
        SuggestedAction   = (Get-SourceOutboxMarkerSuggestedAction -Reason $Reason -RepairEligible:$eligible)
    }
}

function Invoke-SourceOutboxMarkerRepair {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Reason
    )

    $repairPlan = Get-SourceOutboxMarkerRepairPlan -Root $Root -ConfigPath $ConfigPath -RunRoot $RunRoot -Item $Item -Reason $Reason
    if (-not [bool]$repairPlan.Eligible) {
        return [pscustomobject]@{
            Ok            = $false
            RepairPlan    = $repairPlan
            ErrorMessage  = 'source-outbox-marker-repair-not-eligible'
            ExitCode      = 1
            Json          = $null
            Raw           = ''
        }
    }

    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' ([string]$repairPlan.RepairScriptPath) @($repairPlan.RepairArgs)
    $exitCode = $LASTEXITCODE
    $raw = ($result | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Ok            = $false
            RepairPlan    = $repairPlan
            ErrorMessage  = 'source-outbox-marker-repair-no-output'
            ExitCode      = $exitCode
            Json          = $null
            Raw           = ''
        }
    }

    $json = $null
    try {
        $json = ConvertFrom-RelayJsonText -Json $raw
    }
    catch {
        return [pscustomobject]@{
            Ok            = $false
            RepairPlan    = $repairPlan
            ErrorMessage  = ('source-outbox-marker-repair-json-parse-failed: ' + $_.Exception.Message)
            ExitCode      = $exitCode
            Json          = $null
            Raw           = $raw
        }
    }

    if ($exitCode -ne 0 -or -not [bool](Get-ConfigValue -Object $json -Name 'PublishReadyCreated' -DefaultValue $false)) {
        $issues = @([string[]](Get-ConfigValue -Object $json -Name 'Issues' -DefaultValue @()))
        $errorMessage = if ($issues.Count -gt 0) {
            ('source-outbox-marker-repair-failed:' + ($issues -join ','))
        }
        else {
            ('source-outbox-marker-repair-exit-' + [string]$exitCode)
        }
        return [pscustomobject]@{
            Ok            = $false
            RepairPlan    = $repairPlan
            ErrorMessage  = $errorMessage
            ExitCode      = $exitCode
            Json          = $json
            Raw           = $raw
        }
    }

    return [pscustomobject]@{
        Ok            = $true
        RepairPlan    = $repairPlan
        ErrorMessage  = ''
        ExitCode      = $exitCode
        Json          = $json
        Raw           = $raw
    }
}

function Test-SourceOutboxReady {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$Item
    )

    $paths = Get-SourceOutboxPaths -PairTest $PairTest -Item $Item
    $requestPath = [string](Get-ConfigValue -Object $Item -Name 'RequestPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $requestPath)) {
        $targetFolder = [string](Get-ConfigValue -Object $Item -Name 'TargetFolder' -DefaultValue '')
        $requestFileName = [string](Get-ConfigValue -Object $PairTest.HeadlessExec -Name 'RequestFileName' -DefaultValue 'request.json')
        if (Test-NonEmptyString $targetFolder) {
            $requestPath = Join-Path $targetFolder $requestFileName
        }
    }
    $requestReferenceTicks = 0L
    if (Test-NonEmptyString $requestPath -and (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
        try {
            $requestDoc = Read-JsonDocumentWithStatus -Path $requestPath
            $requestCreatedAt = if ([bool]$requestDoc.Ok) { [string](Get-ConfigValue -Object $requestDoc.Data -Name 'CreatedAt' -DefaultValue '') } else { '' }
            $requestReferenceTicks = ConvertTo-UtcTicksOrDefault -IsoTimestamp $requestCreatedAt -DefaultValue 0
            if ($requestReferenceTicks -le 0) {
                $requestReferenceTicks = [int64](Get-Item -LiteralPath $requestPath -ErrorAction Stop).LastWriteTimeUtc.Ticks
            }
        }
        catch {
            $requestReferenceTicks = 0L
        }
    }
    $readyPath = [string]$paths.PublishReadyPath
    $readyExists = Test-Path -LiteralPath $readyPath -PathType Leaf
    $readyItem = if ($readyExists) { Get-Item -LiteralPath $readyPath -ErrorAction Stop } else { $null }
    $markerArchived = $false
    if (-not $readyExists) {
        $archiveRoot = [string]$paths.PublishedArchivePath
        if (Test-NonEmptyString $archiveRoot -and (Test-Path -LiteralPath $archiveRoot -PathType Container)) {
            $archiveItems = @(
                Get-ChildItem -LiteralPath $archiveRoot -Filter '*.ready.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc -Descending |
                    Select-Object -First 1
            )
            if ($archiveItems.Count -ge 1) {
                $readyItem = $archiveItems[0]
                $readyPath = [string]$readyItem.FullName
                $readyExists = $true
                $markerArchived = $true
            }
        }
    }
    $paths | Add-Member -NotePropertyName 'EffectivePublishReadyPath' -NotePropertyValue $readyPath -Force
    $paths | Add-Member -NotePropertyName 'PublishReadyArchived' -NotePropertyValue $markerArchived -Force
    if (-not $readyExists) {
        return [pscustomobject]@{
            MarkerPresent = $false
            IsReady = $false
            Reason = 'ready-missing'
            Paths = $paths
            Marker = $null
            PublishedAt = ''
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'ready-missing' -PublishReadyPath $readyPath)
        }
    }

    $markerDoc = Read-JsonDocumentWithStatus -Path $readyPath
    if (-not [bool]$markerDoc.Ok) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = [string]$markerDoc.Reason
            Paths = $paths
            Marker = $null
            PublishedAt = ''
            SummaryItem = $null
            ZipItem = $null
            ErrorMessage = [string]$markerDoc.ErrorMessage
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason ([string]$markerDoc.Reason) -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    $marker = $markerDoc.Data
    foreach ($requiredField in @('SchemaVersion', 'PairId', 'TargetId', 'SummaryPath', 'ReviewZipPath', 'PublishedAt', 'SummarySizeBytes', 'ReviewZipSizeBytes', 'PublishedBy', 'ValidationCompletedAt')) {
        if (-not (Test-NonEmptyString ([string](Get-ConfigValue -Object $marker -Name $requiredField -DefaultValue '')))) {
            return [pscustomobject]@{
                MarkerPresent = $true
                IsReady = $false
                Reason = ('marker-missing-field-' + $requiredField)
                Paths = $paths
                Marker = $marker
                PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
                SummaryItem = $null
                ZipItem = $null
                StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason ('marker-missing-field-' + $requiredField) -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
            }
        }
    }

    $validationPassed = Get-ConfigValue -Object $marker -Name 'ValidationPassed' -DefaultValue $null
    if ($validationPassed -isnot [bool]) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-validation-flag-invalid'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-validation-flag-invalid' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }
    if (-not [bool]$validationPassed) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-validation-not-passed'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-validation-not-passed' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    $markerSchemaVersion = [string](Get-ConfigValue -Object $marker -Name 'SchemaVersion' -DefaultValue '')
    if ($markerSchemaVersion -notin $SupportedSourceOutboxSchemaVersions) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-schema-version-unsupported'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            ErrorMessage = ('unsupported schema version: ' + $markerSchemaVersion)
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-schema-version-unsupported' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    $publishedBy = [string](Get-ConfigValue -Object $marker -Name 'PublishedBy' -DefaultValue '')
    if ($publishedBy -ne 'publish-paired-exchange-artifact.ps1') {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-publisher-unsupported'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-publisher-unsupported' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    if ([string](Get-ConfigValue -Object $marker -Name 'PairId' -DefaultValue '') -ne [string]$Item.PairId) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-pairid-mismatch'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-pairid-mismatch' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    if ([string](Get-ConfigValue -Object $marker -Name 'TargetId' -DefaultValue '') -ne [string]$Item.TargetId) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-targetid-mismatch'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-targetid-mismatch' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    $expectedSummaryPath = Get-NormalizedFullPath -Path ([string]$paths.SourceSummaryPath)
    $expectedZipPath = Get-NormalizedFullPath -Path ([string]$paths.SourceReviewZipPath)
    $markerSummaryPath = Get-NormalizedFullPath -Path ([string](Get-ConfigValue -Object $marker -Name 'SummaryPath' -DefaultValue ''))
    $markerZipPath = Get-NormalizedFullPath -Path ([string](Get-ConfigValue -Object $marker -Name 'ReviewZipPath' -DefaultValue ''))

    if ($markerSummaryPath -ne $expectedSummaryPath) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-summary-path-mismatch'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-summary-path-mismatch' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    if ($markerZipPath -ne $expectedZipPath) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-reviewzip-path-mismatch'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-reviewzip-path-mismatch' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    if (-not (Test-Path -LiteralPath $paths.SourceSummaryPath -PathType Leaf)) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'source-summary-missing'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $null
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'source-summary-missing' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks))
        }
    }

    if (-not (Test-Path -LiteralPath $paths.SourceReviewZipPath -PathType Leaf)) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'source-reviewzip-missing'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = Get-Item -LiteralPath $paths.SourceSummaryPath -ErrorAction Stop
            ZipItem = $null
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'source-reviewzip-missing' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64](Get-Item -LiteralPath $paths.SourceSummaryPath -ErrorAction Stop).LastWriteTimeUtc.Ticks))
        }
    }

    $summaryItem = Get-Item -LiteralPath $paths.SourceSummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $paths.SourceReviewZipPath -ErrorAction Stop
    if ($requestReferenceTicks -gt 0) {
        if ([int64]$summaryItem.LastWriteTimeUtc.Ticks -lt $requestReferenceTicks) {
            return [pscustomobject]@{
                MarkerPresent = $true
                IsReady = $false
                Reason = 'source-summary-before-request'
                Paths = $paths
                Marker = $marker
                PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
                SummaryItem = $summaryItem
                ZipItem = $zipItem
                StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'source-summary-before-request' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
            }
        }
        if ([int64]$zipItem.LastWriteTimeUtc.Ticks -lt $requestReferenceTicks) {
            return [pscustomobject]@{
                MarkerPresent = $true
                IsReady = $false
                Reason = 'source-reviewzip-before-request'
                Paths = $paths
                Marker = $marker
                PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
                SummaryItem = $summaryItem
                ZipItem = $zipItem
                StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'source-reviewzip-before-request' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
            }
        }
        if ([int64]$readyItem.LastWriteTimeUtc.Ticks -lt $requestReferenceTicks) {
            return [pscustomobject]@{
                MarkerPresent = $true
                IsReady = $false
                Reason = 'marker-before-request'
                Paths = $paths
                Marker = $marker
                PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
                SummaryItem = $summaryItem
                ZipItem = $zipItem
                StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-before-request' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
            }
        }
    }

    $summaryForbiddenMatch = Get-TextFileForbiddenArtifactMatch -Path $paths.SourceSummaryPath
    if ([bool]$summaryForbiddenMatch.Found) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'source-summary-forbidden-literal'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $summaryItem
            ZipItem = $zipItem
            ErrorMessage = ('forbidden summary artifact detected type={0} pattern={1} match={2}' -f [string]$summaryForbiddenMatch.MatchKind, [string]$summaryForbiddenMatch.Pattern, [string]$summaryForbiddenMatch.MatchText)
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'source-summary-forbidden-literal' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
        }
    }
    $zipValidation = Test-ZipArchiveReadable -Path $paths.SourceReviewZipPath
    if (-not [bool]$zipValidation.Ok) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'source-reviewzip-invalid'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $summaryItem
            ZipItem = $zipItem
            ErrorMessage = [string]$zipValidation.ErrorMessage
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'source-reviewzip-invalid' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
        }
    }

    $zipForbiddenMatch = Get-ZipArchiveForbiddenArtifactMatch -Path $paths.SourceReviewZipPath
    if ([bool]$zipForbiddenMatch.Found) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'source-reviewzip-forbidden-literal'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $summaryItem
            ZipItem = $zipItem
            ErrorMessage = ('forbidden review zip artifact detected entry={0} type={1} pattern={2} match={3}' -f [string]$zipForbiddenMatch.EntryPath, [string]$zipForbiddenMatch.MatchKind, [string]$zipForbiddenMatch.Pattern, [string]$zipForbiddenMatch.MatchText)
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'source-reviewzip-forbidden-literal' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
        }
    }

    if ($readyItem.LastWriteTimeUtc -lt $summaryItem.LastWriteTimeUtc -or $readyItem.LastWriteTimeUtc -lt $zipItem.LastWriteTimeUtc) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-before-artifacts'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $summaryItem
            ZipItem = $zipItem
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-before-artifacts' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
        }
    }

    $summarySizeExpected = 0L
    $reviewZipSizeExpected = 0L
    if (-not [int64]::TryParse([string](Get-ConfigValue -Object $marker -Name 'SummarySizeBytes' -DefaultValue ''), [ref]$summarySizeExpected)) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-summary-size-invalid'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $summaryItem
            ZipItem = $zipItem
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-summary-size-invalid' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
        }
    }

    if (-not [int64]::TryParse([string](Get-ConfigValue -Object $marker -Name 'ReviewZipSizeBytes' -DefaultValue ''), [ref]$reviewZipSizeExpected)) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'marker-reviewzip-size-invalid'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $summaryItem
            ZipItem = $zipItem
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'marker-reviewzip-size-invalid' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
        }
    }

    if ($summarySizeExpected -ne [int64]$summaryItem.Length) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'summary-size-mismatch'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $summaryItem
            ZipItem = $zipItem
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'summary-size-mismatch' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
        }
    }

    if ($reviewZipSizeExpected -ne [int64]$zipItem.Length) {
        return [pscustomobject]@{
            MarkerPresent = $true
            IsReady = $false
            Reason = 'reviewzip-size-mismatch'
            Paths = $paths
            Marker = $marker
            PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
            SummaryItem = $summaryItem
            ZipItem = $zipItem
            StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'reviewzip-size-mismatch' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
        }
    }

    $summaryHashExpected = [string](Get-ConfigValue -Object $marker -Name 'SummarySha256' -DefaultValue '')
    if (Test-NonEmptyString $summaryHashExpected) {
        $summaryHashActual = Get-FileHashHex -Path $paths.SourceSummaryPath
        if ($summaryHashActual.ToLowerInvariant() -ne $summaryHashExpected.ToLowerInvariant()) {
            return [pscustomobject]@{
                MarkerPresent = $true
                IsReady = $false
                Reason = 'summary-hash-mismatch'
                Paths = $paths
                Marker = $marker
                PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
                SummaryItem = $summaryItem
                ZipItem = $zipItem
                StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'summary-hash-mismatch' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
            }
        }
    }

    $reviewZipHashExpected = [string](Get-ConfigValue -Object $marker -Name 'ReviewZipSha256' -DefaultValue '')
    if (Test-NonEmptyString $reviewZipHashExpected) {
        $reviewZipHashActual = Get-FileHashHex -Path $paths.SourceReviewZipPath
        if ($reviewZipHashActual.ToLowerInvariant() -ne $reviewZipHashExpected.ToLowerInvariant()) {
            return [pscustomobject]@{
                MarkerPresent = $true
                IsReady = $false
                Reason = 'reviewzip-hash-mismatch'
                Paths = $paths
                Marker = $marker
                PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
                SummaryItem = $summaryItem
                ZipItem = $zipItem
                StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'reviewzip-hash-mismatch' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
            }
        }
    }

    return [pscustomobject]@{
        MarkerPresent = $true
        IsReady = $true
        Reason = ''
        Paths = $paths
        Marker = $marker
        PublishedAt = [string](Get-ConfigValue -Object $marker -Name 'PublishedAt' -DefaultValue '')
        SummaryItem = $summaryItem
        ZipItem = $zipItem
        StateKey = (New-SourceOutboxStateKey -TargetId ([string]$Item.TargetId) -Reason 'ready' -PublishReadyPath $readyPath -PublishReadyTicks ([int64]$readyItem.LastWriteTimeUtc.Ticks) -SummaryTicks ([int64]$summaryItem.LastWriteTimeUtc.Ticks) -ZipTicks ([int64]$zipItem.LastWriteTimeUtc.Ticks))
    }
}

function Wait-TypedWindowHandoffLateSuccess {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$Item,
        [int]$TimeoutSeconds = 30,
        [int]$PollIntervalMs = 1000
    )

    $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
    $lastReadiness = $null
    $lastActivity = ''

    while ((Get-Date) -lt $deadline) {
        $lastReadiness = Test-SourceOutboxReady -PairTest $PairTest -Item $Item
        if ([bool]$lastReadiness.IsReady) {
            return [pscustomobject]@{
                Published = $true
                Reason = 'outbox-publish-detected-late'
                Readiness = $lastReadiness
                LastActivity = $lastActivity
            }
        }

        $summaryPath = [string](Get-ConfigValue -Object $lastReadiness.Paths -Name 'SummaryPath' -DefaultValue '')
        $zipPath = [string](Get-ConfigValue -Object $lastReadiness.Paths -Name 'ReviewZipPath' -DefaultValue '')
        $publishReadyPath = [string](Get-ConfigValue -Object $lastReadiness.Paths -Name 'EffectivePublishReadyPath' -DefaultValue '')
        foreach ($path in @($summaryPath, $zipPath, $publishReadyPath)) {
            if (-not (Test-NonEmptyString $path)) {
                continue
            }

            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $lastActivity = (Get-Date).ToString('o')
                break
            }
        }

        Start-Sleep -Milliseconds ([math]::Max(250, $PollIntervalMs))
    }

    return [pscustomobject]@{
        Published = $false
        Reason = if ($null -ne $lastReadiness) { [string]$lastReadiness.Reason } else { 'outbox-publish-timeout' }
        Readiness = $lastReadiness
        LastActivity = $lastActivity
    }
}

function Get-SourceOutboxFingerprint {
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$Readiness
    )

    return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f
        [string]$TargetId,
        (Get-NormalizedFullPath -Path ([string]$Readiness.Paths.SourceSummaryPath)),
        [int64]$Readiness.SummaryItem.Length,
        [int64]$Readiness.SummaryItem.LastWriteTimeUtc.Ticks,
        (Get-NormalizedFullPath -Path ([string]$Readiness.Paths.SourceReviewZipPath)),
        [int64]$Readiness.ZipItem.Length,
        [int64]$Readiness.ZipItem.LastWriteTimeUtc.Ticks,
        [string]$Readiness.PublishedAt
    )
}

function Invoke-SourceOutboxImport {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SummarySourcePath,
        [Parameter(Mandatory)][string]$ReviewZipSourcePath,
        [string]$SourcePublishReadyPath = '',
        [string]$SourcePublishedAt = '',
        [string]$SourcePublishAttemptId = '',
        [int]$SourcePublishSequence = 0,
        [string]$SourcePublishCycleId = '',
        [string]$SourceValidationCompletedAt = '',
        [string]$SourceSummarySha256 = '',
        [string]$SourceReviewZipSha256 = ''
    )

    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath `
        '-NoProfile' `
        '-ExecutionPolicy' 'Bypass' `
        '-File' (Join-Path $Root 'tests\Import-PairedExchangeArtifact.ps1') `
        '-ConfigPath' $ConfigPath `
        '-RunRoot' $RunRoot `
        '-TargetId' $TargetId `
        '-SummarySourcePath' $SummarySourcePath `
        '-ReviewZipSourcePath' $ReviewZipSourcePath `
        '-SourcePublishReadyPath' $SourcePublishReadyPath `
        '-SourcePublishedAt' $SourcePublishedAt `
        '-SourcePublishAttemptId' $SourcePublishAttemptId `
        '-SourcePublishSequence' ([string]$SourcePublishSequence) `
        '-SourcePublishCycleId' $SourcePublishCycleId `
        '-SourceValidationCompletedAt' $SourceValidationCompletedAt `
        '-SourceSummarySha256' $SourceSummarySha256 `
        '-SourceReviewZipSha256' $SourceReviewZipSha256 `
        '-ImportMode' 'source-outbox-publish' `
        '-Overwrite' `
        '-AsJson'
    $exitCode = $LASTEXITCODE
    $raw = ($result | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "source-outbox import returned no output for target=$TargetId"
    }

    try {
        $json = ConvertFrom-RelayJsonText -Json $raw
    }
    catch {
        throw "source-outbox import json parse failed target=$TargetId raw=$raw"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw = $raw
        Json = $json
    }
}

function Archive-SourceOutboxReadyMarker {
    param(
        [Parameter(Mandatory)][string]$PublishReadyPath,
        [Parameter(Mandatory)][string]$ArchiveRoot,
        [Parameter(Mandatory)][string]$TargetId
    )

    Ensure-Directory -Path $ArchiveRoot
    $archivePath = Join-Path $ArchiveRoot ('publish_{0}_{1}.ready.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $TargetId)
    Move-Item -LiteralPath $PublishReadyPath -Destination $archivePath -Force
    return $archivePath
}

function Write-SourceOutboxFailureLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$MarkerPath,
        [Parameter(Mandatory)][string]$StateKey,
        [Parameter(Mandatory)][string]$Message
    )

    $line = '{0} pair={1} target={2} stateKey={3} marker={4} error={5}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), `
        $PairId, `
        $TargetId, `
        $StateKey, `
        $MarkerPath, `
        $Message

    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Save-SourceOutboxStatus {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][hashtable]$Entries
    )

    $payload = [ordered]@{
        SchemaVersion = '1.0.0'
        RunRoot = $RunRoot
        UpdatedAt = (Get-Date).ToString('o')
        Targets = @(
            $Entries.Keys | Sort-Object | ForEach-Object { $Entries[[string]$_] }
        )
    }

    Write-JsonFileAtomically -Path $Path -Payload $payload -Depth 8
}

function Get-SourceOutboxRepairStatusMetadata {
    param(
        $ExistingEntry = $null,
        [string]$OriginalReadyReason = '',
        [string]$FinalReadyReason = '',
        [string]$RepairSourceContext = '',
        [string]$RepairCommand = '',
        [bool]$RepairAttempted = $false,
        [bool]$RepairSucceeded = $false,
        [string]$RepairCompletedAt = '',
        [string]$RepairMessage = ''
    )

    $currentOriginalReason = if (Test-NonEmptyString $OriginalReadyReason) { $OriginalReadyReason } else { '' }
    $currentFinalReason = if (Test-NonEmptyString $FinalReadyReason) { $FinalReadyReason } else { '' }
    $shouldCarryExisting = $false
    if ($null -ne $ExistingEntry -and $currentOriginalReason -eq 'ready' -and -not $RepairAttempted -and -not $RepairSucceeded) {
        $existingOriginalReason = [string](Get-ConfigValue -Object $ExistingEntry -Name 'OriginalReadyReason' -DefaultValue '')
        $existingRepairAttempted = [bool](Get-ConfigValue -Object $ExistingEntry -Name 'RepairAttempted' -DefaultValue $false)
        if ($existingRepairAttempted -or ((Test-NonEmptyString $existingOriginalReason) -and $existingOriginalReason -ne 'ready')) {
            $shouldCarryExisting = $true
        }
    }

    if ($shouldCarryExisting) {
        return [pscustomobject]@{
            OriginalReadyReason = [string](Get-ConfigValue -Object $ExistingEntry -Name 'OriginalReadyReason' -DefaultValue $currentOriginalReason)
            FinalReadyReason    = $(if (Test-NonEmptyString $currentFinalReason) { $currentFinalReason } else { [string](Get-ConfigValue -Object $ExistingEntry -Name 'FinalReadyReason' -DefaultValue '') })
            RepairSourceContext = [string](Get-ConfigValue -Object $ExistingEntry -Name 'RepairSourceContext' -DefaultValue $RepairSourceContext)
            RepairCommand       = [string](Get-ConfigValue -Object $ExistingEntry -Name 'RepairCommand' -DefaultValue $RepairCommand)
            RepairAttempted     = [bool](Get-ConfigValue -Object $ExistingEntry -Name 'RepairAttempted' -DefaultValue $RepairAttempted)
            RepairSucceeded     = [bool](Get-ConfigValue -Object $ExistingEntry -Name 'RepairSucceeded' -DefaultValue $RepairSucceeded)
            RepairCompletedAt   = [string](Get-ConfigValue -Object $ExistingEntry -Name 'RepairCompletedAt' -DefaultValue $RepairCompletedAt)
            RepairMessage       = [string](Get-ConfigValue -Object $ExistingEntry -Name 'RepairMessage' -DefaultValue $RepairMessage)
        }
    }

    return [pscustomobject]@{
        OriginalReadyReason = $currentOriginalReason
        FinalReadyReason    = $currentFinalReason
        RepairSourceContext = $RepairSourceContext
        RepairCommand       = $RepairCommand
        RepairAttempted     = [bool]$RepairAttempted
        RepairSucceeded     = [bool]$RepairSucceeded
        RepairCompletedAt   = $RepairCompletedAt
        RepairMessage       = $RepairMessage
    }
}

function Load-PairStateEntries {
    param([Parameter(Mandatory)][string]$Path)

    $doc = Read-JsonDocumentWithStatus -Path $Path
    $entries = @{}
    if (-not [bool]$doc.Ok -or $null -eq $doc.Data) {
        return $entries
    }

    foreach ($row in @($doc.Data.Pairs)) {
        $pairId = [string](Get-ConfigValue -Object $row -Name 'PairId' -DefaultValue '')
        if (Test-NonEmptyString $pairId) {
            $entries[$pairId] = $row
        }
    }

    return $entries
}

function Save-PairState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][hashtable]$Entries
    )

    $payload = [ordered]@{
        SchemaVersion = $CurrentPairStateSchemaVersion
        RunRoot = $RunRoot
        UpdatedAt = (Get-Date).ToString('o')
        Pairs = @(
            $Entries.Keys | Sort-Object | ForEach-Object { $Entries[[string]$_] }
        )
    }

    Write-JsonFileAtomically -Path $Path -Payload $payload -Depth 8
}

function Get-PairProfiles {
    param([Parameter(Mandatory)][object[]]$TargetItems)

    $profiles = @{}
    foreach ($item in @($TargetItems)) {
        $pairId = [string](Get-ConfigValue -Object $item -Name 'PairId' -DefaultValue '')
        $targetId = [string](Get-ConfigValue -Object $item -Name 'TargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $pairId) -or -not (Test-NonEmptyString $targetId)) {
            continue
        }

        if (-not $profiles.ContainsKey($pairId)) {
            $profiles[$pairId] = [ordered]@{
                PairId = $pairId
                TopTargetId = ''
                BottomTargetId = ''
                SeedTargetId = ''
                TargetIds = @()
            }
        }

        $profile = $profiles[$pairId]
        $profile.TargetIds = @($profile.TargetIds + $targetId | Where-Object { Test-NonEmptyString $_ } | Select-Object -Unique)
        $roleName = [string](Get-ConfigValue -Object $item -Name 'RoleName' -DefaultValue '')
        if ($roleName -eq 'top') {
            $profile.TopTargetId = $targetId
        }
        elseif ($roleName -eq 'bottom') {
            $profile.BottomTargetId = $targetId
        }

        if ([bool](Get-ConfigValue -Object $item -Name 'SeedEnabled' -DefaultValue $false)) {
            $profile.SeedTargetId = $targetId
        }
    }

    foreach ($pairId in @($profiles.Keys)) {
        $profile = $profiles[$pairId]
        $targetIds = @($profile.TargetIds | Where-Object { Test-NonEmptyString $_ })
        if (-not (Test-NonEmptyString $profile.TopTargetId) -and $targetIds.Count -gt 0) {
            $profile.TopTargetId = [string]$targetIds[0]
        }
        if (-not (Test-NonEmptyString $profile.BottomTargetId) -and $targetIds.Count -gt 1) {
            $profile.BottomTargetId = [string](@($targetIds | Where-Object { $_ -ne $profile.TopTargetId })[0])
        }
        if (-not (Test-NonEmptyString $profile.SeedTargetId)) {
            if (Test-NonEmptyString $profile.TopTargetId) {
                $profile.SeedTargetId = $profile.TopTargetId
            }
            elseif ($targetIds.Count -gt 0) {
                $profile.SeedTargetId = [string]$targetIds[0]
            }
        }
        $profiles[$pairId] = [pscustomobject]$profile
    }

    return $profiles
}

function Test-PairStatusReadyForHandoff {
    param($StatusEntry)

    if ($null -eq $StatusEntry) {
        return $false
    }

    $nextAction = [string](Get-ConfigValue -Object $StatusEntry -Name 'NextAction' -DefaultValue '')
    if ($nextAction -eq 'handoff-ready') {
        return $true
    }

    $contractLatestState = [string](Get-ConfigValue -Object $StatusEntry -Name 'ContractLatestState' -DefaultValue '')
    if ($contractLatestState -eq 'ready-to-forward') {
        return $true
    }

    $latestState = [string](Get-ConfigValue -Object $StatusEntry -Name 'LatestState' -DefaultValue '')
    return ($latestState -eq 'ready-to-forward')
}

function Get-PairAttentionCategory {
    param([object[]]$StatusEntries = @())

    $attentionCategory = ''
    foreach ($row in @($StatusEntries)) {
        if ($null -eq $row) {
            continue
        }

        $state = [string](Get-ConfigValue -Object $row -Name 'State' -DefaultValue '')
        $latestState = [string](Get-ConfigValue -Object $row -Name 'LatestState' -DefaultValue '')
        $contractLatestState = [string](Get-ConfigValue -Object $row -Name 'ContractLatestState' -DefaultValue '')
        $nextAction = [string](Get-ConfigValue -Object $row -Name 'NextAction' -DefaultValue '')
        $manualAttentionRequired = [bool](Get-ConfigValue -Object $row -Name 'SeedManualAttentionRequired' -DefaultValue $false)

        if ($state -eq 'failed' -or $latestState -eq 'error-present' -or $contractLatestState -eq 'error-present') {
            return 'error-blocked'
        }

        if ($manualAttentionRequired -or $nextAction -eq 'manual-review' -or $state -in @('target-unresponsive-after-send', 'submit-unconfirmed')) {
            $attentionCategory = 'manual-attention'
        }
    }

    return $attentionCategory
}

function Sync-PairStateEntries {
    param(
        [Parameter(Mandatory)][hashtable]$Entries,
        [Parameter(Mandatory)][hashtable]$PairProfiles,
        [Parameter(Mandatory)][hashtable]$PairForwardedCounts,
        [Parameter(Mandatory)][hashtable]$SourceOutboxStatusEntries,
        [Parameter(Mandatory)][hashtable]$PairRoundtripLimitMap,
        [bool]$WatcherPaused = $false
    )

    $updatedAt = (Get-Date).ToString('o')
    foreach ($pairId in @($PairProfiles.Keys | Sort-Object)) {
        $profile = Get-ConfigValue -Object $PairProfiles -Name ([string]$pairId) -DefaultValue $null
        if ($null -eq $profile) {
            continue
        }

        $targetIds = @((Get-ConfigValue -Object $profile -Name 'TargetIds' -DefaultValue @()) | Where-Object { Test-NonEmptyString $_ })
        $topTargetId = [string](Get-ConfigValue -Object $profile -Name 'TopTargetId' -DefaultValue '')
        $bottomTargetId = [string](Get-ConfigValue -Object $profile -Name 'BottomTargetId' -DefaultValue '')
        $seedTargetId = [string](Get-ConfigValue -Object $profile -Name 'SeedTargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $seedTargetId) -and (Test-NonEmptyString $topTargetId)) {
            $seedTargetId = $topTargetId
        }
        $partnerTargetId = [string](@($targetIds | Where-Object { $_ -ne $seedTargetId } | Select-Object -First 1)[0])
        $forwardCount = [int](Get-ConfigValue -Object $PairForwardedCounts -Name ([string]$pairId) -DefaultValue 0)
        $roundtripCount = [int][math]::Floor($forwardCount / 2)
        $configuredMaxRoundtripCount = [int](Get-ConfigValue -Object $PairRoundtripLimitMap -Name ([string]$pairId) -DefaultValue 0)
        $limitReached = [bool]($configuredMaxRoundtripCount -gt 0 -and $roundtripCount -ge $configuredMaxRoundtripCount)
        $existing = Get-ConfigValue -Object $Entries -Name ([string]$pairId) -DefaultValue $null

        $lastFromTargetId = [string](Get-ConfigValue -Object $existing -Name 'LastFromTargetId' -DefaultValue '')
        $lastToTargetId = [string](Get-ConfigValue -Object $existing -Name 'LastToTargetId' -DefaultValue '')
        if ($targetIds -notcontains $lastFromTargetId) {
            $lastFromTargetId = ''
        }
        if ($targetIds -notcontains $lastToTargetId) {
            $lastToTargetId = ''
        }

        if (-not (Test-NonEmptyString $lastToTargetId) -and $forwardCount -gt 0) {
            if (($forwardCount % 2) -eq 1) {
                $lastToTargetId = $partnerTargetId
            }
            else {
                $lastToTargetId = $seedTargetId
            }
        }
        if (-not (Test-NonEmptyString $lastFromTargetId) -and (Test-NonEmptyString $lastToTargetId)) {
            $lastFromTargetId = [string](@($targetIds | Where-Object { $_ -ne $lastToTargetId } | Select-Object -First 1)[0])
        }

        $nextExpectedSourceTargetId = ''
        $nextExpectedTargetId = ''
        if ($forwardCount -le 0) {
            $nextExpectedSourceTargetId = $seedTargetId
            $nextExpectedTargetId = $partnerTargetId
        }
        elseif (Test-NonEmptyString $lastToTargetId) {
            $nextExpectedSourceTargetId = $lastToTargetId
            $nextExpectedTargetId = [string](@($targetIds | Where-Object { $_ -ne $lastToTargetId } | Select-Object -First 1)[0])
        }
        else {
            $nextExpectedSourceTargetId = $seedTargetId
            $nextExpectedTargetId = $partnerTargetId
        }
        $nextExpectedHandoff = if ((Test-NonEmptyString $nextExpectedSourceTargetId) -and (Test-NonEmptyString $nextExpectedTargetId)) {
            ('{0} -> {1}' -f $nextExpectedSourceTargetId, $nextExpectedTargetId)
        }
        else {
            ''
        }

        $statusRows = @()
        foreach ($targetId in @($targetIds)) {
            $row = Get-ConfigValue -Object $SourceOutboxStatusEntries -Name ([string]$targetId) -DefaultValue $null
            if ($null -ne $row) {
                $statusRows += $row
            }
        }

        $handoffReadyCount = 0
        $statusSummaryParts = @()
        foreach ($targetId in @($targetIds)) {
            $row = Get-ConfigValue -Object $SourceOutboxStatusEntries -Name ([string]$targetId) -DefaultValue $null
            if ($null -eq $row) {
                continue
            }
            if (Test-PairStatusReadyForHandoff -StatusEntry $row) {
                $handoffReadyCount++
            }
            $displayState = [string](Get-ConfigValue -Object $row -Name 'ContractLatestState' -DefaultValue '')
            if (-not (Test-NonEmptyString $displayState)) {
                $displayState = [string](Get-ConfigValue -Object $row -Name 'LatestState' -DefaultValue '')
            }
            if (-not (Test-NonEmptyString $displayState)) {
                $displayState = [string](Get-ConfigValue -Object $row -Name 'State' -DefaultValue '')
            }
            if (Test-NonEmptyString $displayState) {
                $statusSummaryParts += ('{0}:{1}' -f [string]$targetId, $displayState)
            }
        }

        $attentionCategory = Get-PairAttentionCategory -StatusEntries @($statusRows)
        $expectedTargetStatus = if (Test-NonEmptyString $nextExpectedSourceTargetId) {
            Get-ConfigValue -Object $SourceOutboxStatusEntries -Name $nextExpectedSourceTargetId -DefaultValue $null
        }
        else {
            $null
        }
        $expectedReady = Test-PairStatusReadyForHandoff -StatusEntry $expectedTargetStatus
        $currentPhase = ''
        $nextAction = ''
        if ($limitReached) {
            $currentPhase = 'limit-reached'
            $nextAction = 'limit-reached'
        }
        elseif ($WatcherPaused) {
            $currentPhase = 'paused'
            $nextAction = 'resume-required'
        }
        elseif (Test-NonEmptyString $attentionCategory) {
            $currentPhase = $attentionCategory
            $nextAction = 'manual-review'
        }
        elseif ($expectedReady) {
            $currentPhase = if ($nextExpectedSourceTargetId -eq $seedTargetId) { 'waiting-partner-handoff' } else { 'waiting-return' }
            $nextAction = 'handoff-ready'
        }
        else {
            $currentPhase = if ($nextExpectedSourceTargetId -eq $seedTargetId) { 'seed-running' } else { 'partner-running' }
            $nextAction = if ($nextExpectedSourceTargetId -eq $seedTargetId) { 'await-seed-output' } else { 'await-partner-output' }
        }

        $limitReachedAt = [string](Get-ConfigValue -Object $existing -Name 'LimitReachedAt' -DefaultValue '')
        if ($limitReached -and -not (Test-NonEmptyString $limitReachedAt)) {
            $limitReachedAt = $updatedAt
        }
        elseif (-not $limitReached) {
            $limitReachedAt = ''
        }

        $currentPhase = Normalize-PairPhase -Phase $currentPhase -WatcherStatus $(if ($WatcherPaused) { 'paused' } else { '' }) -NextAction $nextAction -LimitReached:$limitReached

        $Entries[[string]$pairId] = [pscustomobject]@{
            PairId = [string]$pairId
            TopTargetId = $topTargetId
            BottomTargetId = $bottomTargetId
            SeedTargetId = $seedTargetId
            ForwardCount = $forwardCount
            RoundtripCount = $roundtripCount
            CurrentPhase = $currentPhase
            NextAction = $nextAction
            HandoffReadyCount = $handoffReadyCount
            NextExpectedSourceTargetId = $nextExpectedSourceTargetId
            NextExpectedTargetId = $nextExpectedTargetId
            NextExpectedHandoff = $nextExpectedHandoff
            LastFromTargetId = $lastFromTargetId
            LastToTargetId = $lastToTargetId
            LastForwardedAt = [string](Get-ConfigValue -Object $existing -Name 'LastForwardedAt' -DefaultValue '')
            LastForwardedZipPath = [string](Get-ConfigValue -Object $existing -Name 'LastForwardedZipPath' -DefaultValue '')
            StateSummary = (@($statusSummaryParts) -join ', ')
            ConfiguredMaxRoundtripCount = $configuredMaxRoundtripCount
            LimitReached = [bool]$limitReached
            LimitReachedAt = $limitReachedAt
            Paused = [bool]$WatcherPaused
            UpdatedAt = $updatedAt
        }
    }
}

function Write-PairStateSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][hashtable]$Entries,
        [Parameter(Mandatory)][hashtable]$PairProfiles,
        [Parameter(Mandatory)][hashtable]$PairForwardedCounts,
        [Parameter(Mandatory)][hashtable]$SourceOutboxStatusEntries,
        [Parameter(Mandatory)][hashtable]$PairRoundtripLimitMap,
        [bool]$WatcherPaused = $false
    )

    Sync-PairStateEntries `
        -Entries $Entries `
        -PairProfiles $PairProfiles `
        -PairForwardedCounts $PairForwardedCounts `
        -SourceOutboxStatusEntries $SourceOutboxStatusEntries `
        -PairRoundtripLimitMap $PairRoundtripLimitMap `
        -WatcherPaused:$WatcherPaused
    Save-PairState -Path $Path -RunRoot $RunRoot -Entries $Entries
}

function Load-SeedSendStatusState {
    param([Parameter(Mandatory)][string]$Path)

    $doc = Read-JsonDocumentWithStatus -Path $Path
    if (-not [bool]$doc.Ok -or $null -eq $doc.Data) {
        return @{}
    }

    $state = @{}
    foreach ($row in @($doc.Data.Targets)) {
        $targetId = [string](Get-ConfigValue -Object $row -Name 'TargetId' -DefaultValue '')
        if (Test-NonEmptyString $targetId) {
            $state[$targetId] = $row
        }
    }

    return $state
}

function ConvertTo-UtcTicksOrDefault {
    param(
        [string]$IsoTimestamp,
        [int64]$DefaultValue = 0
    )

    if (-not (Test-NonEmptyString $IsoTimestamp)) {
        return [int64]$DefaultValue
    }

    try {
        return [int64][DateTimeOffset]::Parse($IsoTimestamp).UtcDateTime.Ticks
    }
    catch {
        return [int64]$DefaultValue
    }
}

function Get-LatestSourceOutboxActivity {
    param([Parameter(Mandatory)]$Paths)

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(
        [pscustomobject]@{ Kind = 'summary'; Path = [string]$Paths.SourceSummaryPath }
        [pscustomobject]@{ Kind = 'reviewzip'; Path = [string]$Paths.SourceReviewZipPath }
        [pscustomobject]@{ Kind = 'publish-ready'; Path = [string]$Paths.PublishReadyPath }
    )) {
        if (-not (Test-NonEmptyString $entry.Path) -or -not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
            continue
        }

        $item = Get-Item -LiteralPath $entry.Path -ErrorAction Stop
        $candidates.Add([pscustomobject]@{
                Kind = [string]$entry.Kind
                Path = [string]$entry.Path
                ModifiedAt = $item.LastWriteTime.ToString('o')
                ModifiedUtcTicks = [int64]$item.LastWriteTimeUtc.Ticks
            })
    }

    $archiveRoot = [string]$Paths.PublishedArchivePath
    if (Test-NonEmptyString $archiveRoot -and (Test-Path -LiteralPath $archiveRoot -PathType Container)) {
        $archiveItems = @(
            Get-ChildItem -LiteralPath $archiveRoot -Filter '*.ready.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
        )
        if ($archiveItems.Count -ge 1) {
            $archiveItem = $archiveItems[0]
            $candidates.Add([pscustomobject]@{
                    Kind = 'published-archive'
                    Path = [string]$archiveItem.FullName
                    ModifiedAt = $archiveItem.LastWriteTime.ToString('o')
                    ModifiedUtcTicks = [int64]$archiveItem.LastWriteTimeUtc.Ticks
                })
        }
    }

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            Exists = $false
            Kind = ''
            Path = ''
            ModifiedAt = ''
            ModifiedUtcTicks = 0L
        }
    }

    $latest = @($candidates | Sort-Object ModifiedUtcTicks, Kind -Descending | Select-Object -First 1)[0]
    return [pscustomobject]@{
        Exists = $true
        Kind = [string]$latest.Kind
        Path = [string]$latest.Path
        ModifiedAt = [string]$latest.ModifiedAt
        ModifiedUtcTicks = [int64]$latest.ModifiedUtcTicks
    }
}

function Get-SeedSendObservation {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$Item,
        $SeedStatusEntry = $null
    )

    if ($null -eq $SeedStatusEntry) {
        return [pscustomobject]@{
            HasState = $false
        }
    }

    $paths = Get-SourceOutboxPaths -PairTest $PairTest -Item $Item
    $latestActivity = Get-LatestSourceOutboxActivity -Paths $paths
    $seedFinalState = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'FinalState' -DefaultValue '')
    $submitState = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'SubmitState' -DefaultValue '')
    $submitReason = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'SubmitReason' -DefaultValue '')
    $processedAt = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'ProcessedAt' -DefaultValue '')
    $processedPath = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'ProcessedPath' -DefaultValue '')
    $retryPendingAt = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'RetryPendingAt' -DefaultValue '')
    $retryPendingPath = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'RetryPendingPath' -DefaultValue '')
    $failedAt = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'FailedAt' -DefaultValue '')
    $failedPath = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'FailedPath' -DefaultValue '')
    $attemptCount = [int](Get-ConfigValue -Object $SeedStatusEntry -Name 'AttemptCount' -DefaultValue 0)
    $maxAttempts = [int](Get-ConfigValue -Object $SeedStatusEntry -Name 'MaxAttempts' -DefaultValue 0)
    $firstAttemptedAt = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'FirstAttemptedAt' -DefaultValue '')
    $lastAttemptedAt = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'LastAttemptedAt' -DefaultValue '')
    $nextRetryAt = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'NextRetryAt' -DefaultValue '')
    $backoffMs = [int](Get-ConfigValue -Object $SeedStatusEntry -Name 'BackoffMs' -DefaultValue 0)
    $retryReason = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'RetryReason' -DefaultValue '')
    $manualAttentionRequired = [bool](Get-ConfigValue -Object $SeedStatusEntry -Name 'ManualAttentionRequired' -DefaultValue $false)
    $timeoutSeconds = [int]$PairTest.SeedOutboxStartTimeoutSeconds
    $processedUtcTicks = ConvertTo-UtcTicksOrDefault -IsoTimestamp $processedAt
    $updatedAt = [string](Get-ConfigValue -Object $SeedStatusEntry -Name 'UpdatedAt' -DefaultValue '')
    $referenceTicks = ConvertTo-UtcTicksOrDefault -IsoTimestamp $updatedAt -DefaultValue $processedUtcTicks

    $state = ''
    $reason = ''
    if ($seedFinalState -eq 'submit-unconfirmed') {
        if ($latestActivity.Exists -and [int64]$latestActivity.ModifiedUtcTicks -gt $processedUtcTicks) {
            $state = 'publish-started'
            $reason = ('outbox-activity-after-send:' + [string]$latestActivity.Kind)
        }
        else {
            $state = 'submit-unconfirmed'
            $reason = if (Test-NonEmptyString $submitReason) { $submitReason } else { 'no-outbox-publish-within-wait-window' }
        }
    }
    elseif ($seedFinalState -eq 'processed' -or $seedFinalState -eq 'publish-detected') {
        if ($latestActivity.Exists -and [int64]$latestActivity.ModifiedUtcTicks -gt $processedUtcTicks) {
            $state = 'publish-started'
            $reason = ('outbox-activity-after-send:' + [string]$latestActivity.Kind)
        }
        else {
            $processedAgeSeconds = if ($processedUtcTicks -gt 0) {
                [math]::Round(((Get-Date).ToUniversalTime().Ticks - $processedUtcTicks) / [double][TimeSpan]::TicksPerSecond, 3)
            }
            else {
                $null
            }

            if ($null -ne $processedAgeSeconds -and $timeoutSeconds -gt 0 -and $processedAgeSeconds -ge $timeoutSeconds) {
                $state = 'target-unresponsive-after-send'
                $reason = 'seed-send-processed-no-outbox-activity'
            }
            else {
                $state = 'seed-send-processed'
                $reason = 'awaiting-outbox-activity'
            }
        }
    }
    elseif ($seedFinalState -eq 'retry-pending') {
        $state = 'seed-retry-pending'
        $reason = if (Test-NonEmptyString $retryReason) { $retryReason } else { 'router-retry-pending' }
    }
    elseif ($seedFinalState -eq 'manual_attention_required') {
        $state = 'manual-attention-required'
        $reason = if (Test-NonEmptyString $retryReason) { $retryReason } else { 'manual-attention-required' }
    }
    elseif ($seedFinalState -eq 'failed') {
        $state = 'seed-send-failed'
        $reason = 'seed-send-failed'
    }
    elseif ($seedFinalState -eq 'timeout') {
        $state = 'seed-send-timeout'
        $reason = 'seed-send-timeout'
    }

    if (-not (Test-NonEmptyString $state)) {
        return [pscustomobject]@{
            HasState = $false
        }
    }

    return [pscustomobject]@{
        HasState = $true
        State = $state
        Reason = $reason
        ReferenceUtcTicks = $referenceTicks
        ProcessedAt = $processedAt
        ProcessedPath = $processedPath
        RetryPendingAt = $retryPendingAt
        RetryPendingPath = $retryPendingPath
        FailedAt = $failedAt
        FailedPath = $failedPath
        AttemptCount = $attemptCount
        MaxAttempts = $maxAttempts
        FirstAttemptedAt = $firstAttemptedAt
        LastAttemptedAt = $lastAttemptedAt
        NextRetryAt = $nextRetryAt
        BackoffMs = $backoffMs
        RetryReason = $retryReason
        ManualAttentionRequired = $manualAttentionRequired
        SubmitState = $submitState
        SubmitReason = $submitReason
        TimeoutSeconds = $timeoutSeconds
        SourceOutboxPath = [string]$paths.SourceOutboxPath
        SourceSummaryPath = [string]$paths.SourceSummaryPath
        SourceReviewZipPath = [string]$paths.SourceReviewZipPath
        PublishReadyPath = [string]$paths.PublishReadyPath
        PublishedArchivePath = [string]$paths.PublishedArchivePath
        SourceOutboxLastActivityKind = [string]$latestActivity.Kind
        SourceOutboxLastActivityPath = [string]$latestActivity.Path
        SourceOutboxLastActivityAt = [string]$latestActivity.ModifiedAt
    }
}

function Test-SummaryReadyForZip {
    param(
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)]$ZipFile,
        [double]$MaxSkewSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $SummaryPath)) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'summary-missing'
        }
    }

    $summaryItem = Get-Item -LiteralPath $SummaryPath -ErrorAction Stop
    $deltaSeconds = ($ZipFile.LastWriteTimeUtc - $summaryItem.LastWriteTimeUtc).TotalSeconds
    if ($deltaSeconds -gt $MaxSkewSeconds) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'summary-stale'
        }
    }

    return [pscustomobject]@{
        IsReady = $true
        Reason  = ''
    }
}

function Test-DoneMarkerReadyForZip {
    param(
        [Parameter(Mandatory)][string]$DonePath,
        [Parameter(Mandatory)]$ZipFile,
        [double]$MaxSkewSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $DonePath)) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'done-missing'
        }
    }

    $doneItem = Get-Item -LiteralPath $DonePath -ErrorAction Stop
    $deltaSeconds = ($doneItem.LastWriteTimeUtc - $ZipFile.LastWriteTimeUtc).TotalSeconds
    if ($deltaSeconds -lt (-1 * $MaxSkewSeconds)) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'done-stale'
        }
    }

    return [pscustomobject]@{
        IsReady = $true
        Reason  = ''
    }
}

function Get-HandoffMessageText {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$SourceItem,
        [Parameter(Mandatory)]$RecipientItem,
        [Parameter(Mandatory)][string]$ZipPath,
        [string]$SummaryPath = '',
        $OneTimeItems = @()
    )

    $templateBlocks = Get-PairTemplateBlocks -PairTest $PairTest -TemplateName 'Handoff' -PairId ([string]$RecipientItem.PairId) -RoleName ([string]$RecipientItem.RoleName) -TargetId ([string]$RecipientItem.TargetId)
    $summaryFileName = [string]$PairTest.SummaryFileName
    $zipFileName = [System.IO.Path]::GetFileName($ZipPath)
    $resolvedSummaryPath = if (Test-NonEmptyString $SummaryPath) { $SummaryPath } else { '(missing)' }
    $recipientSourceOutboxPath = [string](Get-ConfigValue -Object $RecipientItem -Name 'SourceOutboxPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $recipientSourceOutboxPath)) {
        $recipientSourceOutboxPath = Join-Path ([string]$SourceItem.PartnerFolder) ([string]$PairTest.SourceOutboxFolderName)
    }
    $recipientSourceSummaryPath = [string](Get-ConfigValue -Object $RecipientItem -Name 'SourceSummaryPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $recipientSourceSummaryPath)) {
        $recipientSourceSummaryPath = Join-Path $recipientSourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    }
    $recipientSourceReviewZipPath = [string](Get-ConfigValue -Object $RecipientItem -Name 'SourceReviewZipPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $recipientSourceReviewZipPath)) {
        $recipientSourceReviewZipPath = Join-Path $recipientSourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    }
    $recipientPublishReadyPath = [string](Get-ConfigValue -Object $RecipientItem -Name 'PublishReadyPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $recipientPublishReadyPath)) {
        $recipientPublishReadyPath = Join-Path $recipientSourceOutboxPath ([string]$PairTest.PublishReadyFileName)
    }
    $recipientPublishScriptPath = [string](Get-ConfigValue -Object $RecipientItem -Name 'PublishScriptPath' -DefaultValue '')
    $recipientPublishCmdPath = [string](Get-ConfigValue -Object $RecipientItem -Name 'PublishCmdPath' -DefaultValue '')
    $availableReviewInputPaths = @()
    foreach ($candidate in @($SummaryPath, $ZipPath)) {
        if (-not (Test-NonEmptyString $candidate)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $availableReviewInputPaths += [System.IO.Path]::GetFullPath($candidate)
    }
    $availableReviewInputPaths = @($availableReviewInputPaths | Select-Object -Unique)
    $pathGuideLines = @(
        '[자동 경로 안내]'
        ('현재 대상: ' + [string]$RecipientItem.TargetId)
        ('내 작업 폴더: ' + [string]$RecipientItem.TargetFolder)
        ('상대 작업 폴더: ' + [string]$RecipientItem.PartnerFolder)
        ''
    )
    if ($availableReviewInputPaths.Count -gt 0) {
        $pathGuideLines += '먼저 확인할 파일:'
        foreach ($path in @($availableReviewInputPaths)) {
            $pathGuideLines += ('- ' + $path)
        }
    }
    else {
        $pathGuideLines += '먼저 확인할 검토 입력 파일 없음. 현재 작업 파일 기준으로 검토 후 내 출력 파일을 생성하세요.'
    }
    $pathGuideLines += @(
        ''
        '내가 생성할 파일:'
        ('- summary.txt: ' + $recipientSourceSummaryPath)
        ('- review.zip: ' + $recipientSourceReviewZipPath)
        ('- publish.ready.json: ' + $recipientPublishReadyPath)
    )
    $pathGuideBlock = $pathGuideLines -join "`r`n"

    $bodyBlock = @(
        '[paired-exchange handoff]'
        ('pair: ' + [string]$SourceItem.PairId)
        ('from: ' + [string]$SourceItem.TargetId)
        ('to: ' + [string]$RecipientItem.TargetId)
        ''
        $pathGuideBlock
        ''
        '다음 작업:'
        ('1. 상대가 보낸 {0} 와 review zip 을 입력으로 확인합니다.' -f $summaryFileName)
        '2. 필요한 수정이나 검토를 진행합니다.'
        '3. 최종 결과만 내 SourceOutboxPath 아래의 summary.txt 와 review.zip 으로 생성합니다.'
        '4. summary.txt 와 review.zip 작성이 끝난 뒤 마지막에 publish.ready.json 을 생성합니다.'
        ('   publish helper: {0}{1}' -f `
            $(if (Test-NonEmptyString $recipientPublishCmdPath) { ("'" + $recipientPublishCmdPath + "'") } else { 'publish helper' }), `
            $(if (Test-NonEmptyString $recipientPublishScriptPath) { (' / ''' + $recipientPublishScriptPath + '''') } else { '' }))
        '5. 직접 target contract 경로에 복사하거나 별도 submit 명령을 다시 실행하지 마세요.'
    ) -join "`r`n"

    $blocks = Get-OrderedMessageBlocks -TemplateBlocks $templateBlocks -BodyText $bodyBlock -OneTimeItems $OneTimeItems
    return (Join-MessageBlocks -Blocks $blocks)
}

function Write-HandoffFailureLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$StateKey,
        [Parameter(Mandatory)][string]$Message
    )

    $line = '{0} pair={1} from={2} to={3} stateKey={4} zip={5} error={6}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),
        $PairId,
        $TargetId,
        $PartnerTargetId,
        $StateKey,
        $ZipPath,
        $Message

    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
. (Join-Path $PSScriptRoot 'OneTimeMessageQueue.ps1')
. (Join-Path $root 'router\RelayMessageMetadata.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$resolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$watcherMutexName = Get-PairedWatcherMutexName -RunRoot $resolvedRunRoot
$watcherMutex = $null
$stateRoot = Join-Path $resolvedRunRoot '.state'
$watcherControlPath = Join-Path $stateRoot 'watcher-control.json'
$watcherStatusPath = Join-Path $stateRoot 'watcher-status.json'
$watcherStopReason = 'completed'
$watcherRequestId = ''
$watcherAction = ''
$watcherLastHandledRequestId = ''
$watcherLastHandledAction = ''
$watcherLastHandledResult = ''
$watcherLastHandledAt = ''
$watcherHeartbeatAt = ''
$watcherStatusSequence = 0
$watcherProcessStartedAt = ''
$watcherStarted = $false
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "manifest not found: $manifestPath"
}

try {
    $watcherMutex = Acquire-PairedWatcherMutex -Name $watcherMutexName

    $manifest = ConvertFrom-RelayJsonText -Json (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8)
    $pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath -ManifestPairTest (Get-ConfigValue -Object $manifest -Name 'PairTest' -DefaultValue $null)
    Assert-HeadlessDispatchAllowedForLane `
        -UseHeadlessDispatch:$UseHeadlessDispatch `
        -AllowHeadlessDispatchInTypedWindowLane:$AllowHeadlessDispatchInTypedWindowLane `
        -Config $config `
        -PairTest $pairTest `
        -ConfigPath $resolvedConfigPath
    $script:ForbiddenArtifactLiterals = @($pairTest.ForbiddenArtifactLiterals)
    $script:ForbiddenArtifactRegexes = @($pairTest.ForbiddenArtifactRegexes)
    $targetItems = @($manifest.Targets)
    $targetItemsById = @{}
    foreach ($targetItem in @($targetItems)) {
        $targetItemsById[[string]$targetItem.TargetId] = $targetItem
    }
    Ensure-Directory -Path $stateRoot
    $statePath = Join-Path $stateRoot 'forwarded.json'
    $pairStatePath = Join-Path $stateRoot 'pair-state.json'
    $sourceOutboxStatePath = Join-Path $stateRoot 'source-outbox-processed.json'
    $sourceOutboxFailureLogPath = Join-Path $stateRoot 'source-outbox-failures.log'
    $sourceOutboxStatusPath = Join-Path $stateRoot 'source-outbox-status.json'
    $seedSendStatusPath = Join-Path $stateRoot 'seed-send-status.json'
    $handoffFailureLogPath = Join-Path $stateRoot 'handoff-failures.log'
    $headlessDispatchLogRoot = Join-Path $stateRoot 'headless-dispatch'
    $messageRoot = Join-Path $resolvedRunRoot ([string]$pairTest.MessageFolderName)
    Ensure-Directory -Path $messageRoot
    if ($UseHeadlessDispatch) {
        if (-not [bool]$pairTest.HeadlessExec.Enabled) {
            throw "headless dispatch requested but HeadlessExec.Enabled is false in config: $resolvedConfigPath"
        }
        Ensure-Directory -Path $headlessDispatchLogRoot
    }
    $state = Load-State -Path $statePath
    $sourceOutboxState = Load-State -Path $sourceOutboxStatePath
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $watcherProcessStartedAt = (Get-Date).ToString('o')
    $pendingState = @{}
    $handoffFailureState = @{}
    $sourceOutboxPendingState = @{}
    $sourceOutboxFailureState = @{}
    $sourceOutboxRepairState = @{}
    $sourceOutboxRepairMetadataByTarget = @{}
    $sourceOutboxStatusEntries = @{}
    $pairProfiles = Get-PairProfiles -TargetItems @($targetItems)
    $pairRoundtripLimitMap = Get-PairRoundtripLimitMap -TargetItems @($targetItems) -GlobalPairMaxRoundtripCount $PairMaxRoundtripCount
    $pairStateEntries = Load-PairStateEntries -Path $pairStatePath
    $pairForwardedCounts = Get-PairForwardedCounts -State $state -TargetItemsById $targetItemsById
    $watcherPaused = $false
    $pauseStartedAtUtc = $null
    $pausedDurationSeconds = 0.0
    $forwardedThisRun = 0
    Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
    Write-PairStateSnapshot `
        -Path $pairStatePath `
        -RunRoot $resolvedRunRoot `
        -Entries $pairStateEntries `
        -PairProfiles $pairProfiles `
        -PairForwardedCounts $pairForwardedCounts `
        -SourceOutboxStatusEntries $sourceOutboxStatusEntries `
        -PairRoundtripLimitMap $pairRoundtripLimitMap `
        -WatcherPaused:$watcherPaused
    $watcherStatusSequence++
    $watcherHeartbeatAt = (Get-Date).ToString('o')
    Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'running' -Reason 'started' -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount -ConfiguredRunDurationSec $RunDurationSec -ConfiguredMaxRoundtripCount $PairMaxRoundtripCount
    $watcherStarted = $true

    Write-Host "watching paired exchange root: $resolvedRunRoot mutex=$watcherMutexName"

    while ($true) {
        Write-PairStateSnapshot `
            -Path $pairStatePath `
            -RunRoot $resolvedRunRoot `
            -Entries $pairStateEntries `
            -PairProfiles $pairProfiles `
            -PairForwardedCounts $pairForwardedCounts `
            -SourceOutboxStatusEntries $sourceOutboxStatusEntries `
            -PairRoundtripLimitMap $pairRoundtripLimitMap `
            -WatcherPaused:$watcherPaused
        $activeElapsedSeconds = Get-ActiveWatcherElapsedSeconds -Stopwatch $stopwatch -PausedDurationSeconds $pausedDurationSeconds
        if ($RunDurationSec -gt 0 -and $activeElapsedSeconds -ge $RunDurationSec) {
            $watcherStopReason = 'run-duration-reached'
            break
        }

        $watcherStatusSequence++
        $watcherHeartbeatAt = (Get-Date).ToString('o')
        $watcherLoopState = if ($watcherPaused) { 'paused' } else { 'running' }
        $watcherLoopReason = if ($watcherPaused) { 'paused' } else { 'heartbeat' }
        Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State $watcherLoopState -Reason $watcherLoopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount -ConfiguredRunDurationSec $RunDurationSec -ConfiguredMaxRoundtripCount $PairMaxRoundtripCount
        $controlRequest = Get-WatcherControlRequest -Path $watcherControlPath
        if ($null -ne $controlRequest -and [string]$controlRequest.RunRoot -eq $resolvedRunRoot) {
            $watcherRequestId = [string]$controlRequest.RequestId
            $watcherAction = [string]$controlRequest.Action
            $watcherLastHandledRequestId = $watcherRequestId
            $watcherLastHandledAction = $watcherAction
            $watcherLastHandledAt = (Get-Date).ToString('o')
            $exitWatcherLoop = $false
            switch ($watcherAction) {
                'stop' {
                    $watcherLastHandledResult = 'accepted'
                    $watcherStopReason = 'control-stop-request'
                    $watcherStatusSequence++
                    $watcherHeartbeatAt = (Get-Date).ToString('o')
                    Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'stop_requested' -Reason $watcherStopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount -ConfiguredRunDurationSec $RunDurationSec -ConfiguredMaxRoundtripCount $PairMaxRoundtripCount
                    Clear-WatcherControlRequest -Path $watcherControlPath
                    $exitWatcherLoop = $true
                }
                'pause' {
                    if (-not $watcherPaused) {
                        $watcherPaused = $true
                        $pauseStartedAtUtc = [DateTime]::UtcNow
                        $watcherLastHandledResult = 'paused'
                        $watcherLoopReason = 'control-pause-request'
                    }
                    else {
                        $watcherLastHandledResult = 'already-paused'
                        $watcherLoopReason = 'paused'
                    }
                    Clear-WatcherControlRequest -Path $watcherControlPath
                    Write-PairStateSnapshot `
                        -Path $pairStatePath `
                        -RunRoot $resolvedRunRoot `
                        -Entries $pairStateEntries `
                        -PairProfiles $pairProfiles `
                        -PairForwardedCounts $pairForwardedCounts `
                        -SourceOutboxStatusEntries $sourceOutboxStatusEntries `
                        -PairRoundtripLimitMap $pairRoundtripLimitMap `
                        -WatcherPaused:$watcherPaused
                    $watcherStatusSequence++
                    $watcherHeartbeatAt = (Get-Date).ToString('o')
                    Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'paused' -Reason $watcherLoopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount -ConfiguredRunDurationSec $RunDurationSec -ConfiguredMaxRoundtripCount $PairMaxRoundtripCount
                    Start-Sleep -Milliseconds $PollIntervalMs
                    continue
                }
                'resume' {
                    if ($watcherPaused) {
                        if ($null -ne $pauseStartedAtUtc) {
                            $pausedDurationSeconds += ([DateTime]::UtcNow - $pauseStartedAtUtc).TotalSeconds
                            $pauseStartedAtUtc = $null
                        }
                        $watcherPaused = $false
                        $watcherLastHandledResult = 'resumed'
                        $watcherLoopReason = 'control-resume-request'
                    }
                    else {
                        $watcherLastHandledResult = 'already-running'
                        $watcherLoopReason = 'heartbeat'
                    }
                    Clear-WatcherControlRequest -Path $watcherControlPath
                    Write-PairStateSnapshot `
                        -Path $pairStatePath `
                        -RunRoot $resolvedRunRoot `
                        -Entries $pairStateEntries `
                        -PairProfiles $pairProfiles `
                        -PairForwardedCounts $pairForwardedCounts `
                        -SourceOutboxStatusEntries $sourceOutboxStatusEntries `
                        -PairRoundtripLimitMap $pairRoundtripLimitMap `
                        -WatcherPaused:$watcherPaused
                    $watcherStatusSequence++
                    $watcherHeartbeatAt = (Get-Date).ToString('o')
                    Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'running' -Reason $watcherLoopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount -ConfiguredRunDurationSec $RunDurationSec -ConfiguredMaxRoundtripCount $PairMaxRoundtripCount
                    continue
                }
            }
            if ($exitWatcherLoop) {
                break
            }
        }

        if (Test-AllPairsReachedRoundtripLimit -PairForwardedCounts $pairForwardedCounts -PairRoundtripLimitMap $pairRoundtripLimitMap) {
            Write-Host 'paired exchange watcher reached pair roundtrip limit.'
            $watcherStopReason = 'pair-roundtrip-limit-reached'
            break
        }

        $seedSendState = Load-SeedSendStatusState -Path $seedSendStatusPath
        foreach ($item in $targetItems) {
            $targetId = [string]$item.TargetId
            $seedObservation = Get-SeedSendObservation -PairTest $pairTest -Item $item -SeedStatusEntry (Get-ConfigValue -Object $seedSendState -Name $targetId -DefaultValue $null)
            if ([bool]$seedObservation.HasState) {
                $existingSeedStatus = Get-ConfigValue -Object $sourceOutboxStatusEntries -Name $targetId -DefaultValue $null
                $existingUpdatedTicks = ConvertTo-UtcTicksOrDefault -IsoTimestamp ([string](Get-ConfigValue -Object $existingSeedStatus -Name 'UpdatedAt' -DefaultValue ''))
                $shouldApplySeedObservation = ($null -eq $existingSeedStatus) -or ($existingUpdatedTicks -le [int64]$seedObservation.ReferenceUtcTicks)
                if ($shouldApplySeedObservation) {
                    $sourceOutboxStatusEntries[$targetId] = [pscustomobject]@{
                        TargetId                    = $targetId
                        PairId                      = [string]$item.PairId
                        UpdatedAt                   = (Get-Date).ToString('o')
                        State                       = [string]$seedObservation.State
                        Reason                      = [string]$seedObservation.Reason
                        SourceOutboxPath            = [string]$seedObservation.SourceOutboxPath
                        SourceSummaryPath           = [string]$seedObservation.SourceSummaryPath
                        SourceReviewZipPath         = [string]$seedObservation.SourceReviewZipPath
                        PublishReadyPath            = [string]$seedObservation.PublishReadyPath
                        PublishedArchivePath        = [string]$seedObservation.PublishedArchivePath
                        SeedProcessedAt             = [string]$seedObservation.ProcessedAt
                        SeedProcessedPath           = [string]$seedObservation.ProcessedPath
                        SeedRetryPendingAt          = [string]$seedObservation.RetryPendingAt
                        SeedRetryPendingPath        = [string]$seedObservation.RetryPendingPath
                        SeedFailedAt                = [string]$seedObservation.FailedAt
                        SeedFailedPath              = [string]$seedObservation.FailedPath
                        SeedAttemptCount            = [int]$seedObservation.AttemptCount
                        SeedMaxAttempts             = [int]$seedObservation.MaxAttempts
                        SeedFirstAttemptedAt        = [string]$seedObservation.FirstAttemptedAt
                        SeedLastAttemptedAt         = [string]$seedObservation.LastAttemptedAt
                        SeedNextRetryAt             = [string]$seedObservation.NextRetryAt
                        SeedBackoffMs               = [int]$seedObservation.BackoffMs
                        SeedRetryReason             = [string]$seedObservation.RetryReason
                        SeedManualAttentionRequired = [bool]$seedObservation.ManualAttentionRequired
                        SeedOutboxStartTimeoutSeconds = [int]$seedObservation.TimeoutSeconds
                        SourceOutboxLastActivityKind = [string]$seedObservation.SourceOutboxLastActivityKind
                        SourceOutboxLastActivityPath = [string]$seedObservation.SourceOutboxLastActivityPath
                        SourceOutboxLastActivityAt   = [string]$seedObservation.SourceOutboxLastActivityAt
                        ContractLatestState          = ''
                        NextAction                   = ''
                    }
                    Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
                }
            }

            $sourceOutboxReadiness = Test-SourceOutboxReady -PairTest $pairTest -Item $item
            $sourceOutboxOriginalReason = if (Test-NonEmptyString ([string]$sourceOutboxReadiness.Reason)) { [string]$sourceOutboxReadiness.Reason } elseif ([bool]$sourceOutboxReadiness.IsReady) { 'ready' } else { '' }
            $repairPlan = if (Test-NonEmptyString $sourceOutboxOriginalReason) {
                Get-SourceOutboxMarkerRepairPlan `
                    -Root $root `
                    -ConfigPath $resolvedConfigPath `
                    -RunRoot $resolvedRunRoot `
                    -Item $item `
                    -Reason $sourceOutboxOriginalReason
            }
            else {
                [pscustomobject]@{
                    Eligible            = $false
                    RepairScriptPath    = ''
                    RepairArgs          = @()
                    RepairCommand       = ''
                    RepairSourceContext = ''
                    ExpectedPublisher   = 'publish-paired-exchange-artifact.ps1'
                    SuggestedAction     = ''
                }
            }
            $repairAttempted = $false
            $repairSucceeded = $false
            $repairMessage = ''
            $repairCompletedAt = ''
            $repairResult = $null
            $finalReadyReason = if (Test-NonEmptyString ([string]$sourceOutboxReadiness.Reason)) { [string]$sourceOutboxReadiness.Reason } elseif ([bool]$sourceOutboxReadiness.IsReady) { 'ready' } else { '' }
            $existingTargetStatusEntry = Get-ConfigValue -Object $sourceOutboxStatusEntries -Name ([string]$item.TargetId) -DefaultValue $null
            $existingRepairMetadataEntry = Get-ConfigValue -Object $sourceOutboxRepairMetadataByTarget -Name ([string]$item.TargetId) -DefaultValue $existingTargetStatusEntry
            $repairStatus = Get-SourceOutboxRepairStatusMetadata `
                -ExistingEntry $existingRepairMetadataEntry `
                -OriginalReadyReason $sourceOutboxOriginalReason `
                -FinalReadyReason $finalReadyReason `
                -RepairSourceContext ([string]$repairPlan.RepairSourceContext) `
                -RepairCommand ([string]$repairPlan.RepairCommand) `
                -RepairAttempted:$repairAttempted `
                -RepairSucceeded:$repairSucceeded `
                -RepairCompletedAt $repairCompletedAt `
                -RepairMessage ([string]$repairMessage)
            if ($sourceOutboxReadiness.MarkerPresent) {
                if (-not $sourceOutboxReadiness.IsReady) {
                    if ([bool]$repairPlan.Eligible -and -not [bool]$sourceOutboxReadiness.Paths.PublishReadyArchived) {
                        $repairStateKey = ($sourceOutboxReadiness.StateKey + '|repair')
                        if (Test-NonEmptyString $repairStateKey -and -not $sourceOutboxRepairState.ContainsKey($repairStateKey)) {
                            $sourceOutboxRepairState[$repairStateKey] = $true
                            $repairAttempted = $true
                            Write-Host ("source-outbox auto-repair start {0} marker={1} reason={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath, [string]$sourceOutboxReadiness.Reason)
                            $repairResult = Invoke-SourceOutboxMarkerRepair `
                                -Root $root `
                                -ConfigPath $resolvedConfigPath `
                                -RunRoot $resolvedRunRoot `
                                -Item $item `
                                -Reason ([string]$sourceOutboxReadiness.Reason)
                            $repairCompletedAt = (Get-Date).ToString('o')
                            if ([bool]$repairResult.Ok) {
                                $repairSucceeded = $true
                                $repairMessage = 'source-outbox-marker-repaired'
                                Write-Host ("source-outbox auto-repair succeeded {0} marker={1} helper={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath, [string]$repairResult.RepairPlan.RepairCommand)
                                $sourceOutboxReadiness = Test-SourceOutboxReady -PairTest $pairTest -Item $item
                            }
                            else {
                                $repairMessage = [string]$repairResult.ErrorMessage
                                Write-SourceOutboxFailureLog `
                                    -Path $sourceOutboxFailureLogPath `
                                    -PairId ([string]$item.PairId) `
                                    -TargetId ([string]$item.TargetId) `
                                    -MarkerPath ([string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath) `
                                    -StateKey $repairStateKey `
                                    -Message ('auto-repair-failed:' + $repairMessage)
                                Write-Host ("source-outbox auto-repair failed {0} marker={1} error={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath, $repairMessage)
                            }
                        }
                    }

                    $finalReadyReason = if (Test-NonEmptyString ([string]$sourceOutboxReadiness.Reason)) { [string]$sourceOutboxReadiness.Reason } elseif ([bool]$sourceOutboxReadiness.IsReady) { 'ready' } else { '' }
                    $existingTargetStatusEntry = Get-ConfigValue -Object $sourceOutboxStatusEntries -Name ([string]$item.TargetId) -DefaultValue $null
                    $existingRepairMetadataEntry = Get-ConfigValue -Object $sourceOutboxRepairMetadataByTarget -Name ([string]$item.TargetId) -DefaultValue $existingTargetStatusEntry
                    $repairStatus = Get-SourceOutboxRepairStatusMetadata `
                        -ExistingEntry $existingRepairMetadataEntry `
                        -OriginalReadyReason $sourceOutboxOriginalReason `
                        -FinalReadyReason $finalReadyReason `
                        -RepairSourceContext ([string]$repairPlan.RepairSourceContext) `
                        -RepairCommand ([string]$repairPlan.RepairCommand) `
                        -RepairAttempted:$repairAttempted `
                        -RepairSucceeded:$repairSucceeded `
                        -RepairCompletedAt $repairCompletedAt `
                        -RepairMessage ([string]$repairMessage)
                    if ([bool]$repairStatus.RepairAttempted -or [bool]$repairStatus.RepairSucceeded) {
                        $sourceOutboxRepairMetadataByTarget[[string]$item.TargetId] = $repairStatus
                    }

                    if (-not $sourceOutboxReadiness.IsReady) {
                    $sourcePendingKey = [string]$sourceOutboxReadiness.StateKey
                    if (Test-NonEmptyString $sourcePendingKey -and -not $sourceOutboxPendingState.ContainsKey($sourcePendingKey)) {
                        $sourceOutboxPendingState[$sourcePendingKey] = $true
                        $waitingMessage = ("source-outbox waiting {0} marker={1} reason={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath, [string]$sourceOutboxReadiness.Reason)
                        if (Test-NonEmptyString ([string]$repairPlan.SuggestedAction)) {
                            $waitingMessage += (' suggestedAction=' + [string]$repairPlan.SuggestedAction)
                        }
                        if (Test-NonEmptyString ([string]$repairPlan.RepairCommand)) {
                            $waitingMessage += (' repair=' + [string]$repairPlan.RepairCommand)
                        }
                        Write-Host $waitingMessage
                    }

                    $sourceOutboxStatusEntries[[string]$item.TargetId] = [pscustomobject]@{
                        TargetId            = [string]$item.TargetId
                        PairId              = [string]$item.PairId
                        UpdatedAt           = (Get-Date).ToString('o')
                        State               = 'waiting'
                        Reason              = [string]$sourceOutboxReadiness.Reason
                        SourceOutboxPath    = [string]$sourceOutboxReadiness.Paths.SourceOutboxPath
                        SourceSummaryPath   = [string]$sourceOutboxReadiness.Paths.SourceSummaryPath
                        SourceReviewZipPath = [string]$sourceOutboxReadiness.Paths.SourceReviewZipPath
                        PublishReadyPath    = [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath
                        PublishedAt         = [string]$sourceOutboxReadiness.PublishedAt
                        ContractLatestState = ''
                        NextAction          = [string]$repairPlan.SuggestedAction
                        SuggestedAction     = [string]$repairPlan.SuggestedAction
                        OriginalReadyReason = [string]$repairStatus.OriginalReadyReason
                        FinalReadyReason    = [string]$repairStatus.FinalReadyReason
                        RepairSourceContext = [string]$repairStatus.RepairSourceContext
                        RepairCommand       = [string]$repairStatus.RepairCommand
                        RepairAttempted     = [bool]$repairStatus.RepairAttempted
                        RepairSucceeded     = [bool]$repairStatus.RepairSucceeded
                        RepairCompletedAt   = [string]$repairStatus.RepairCompletedAt
                        RepairMessage       = [string]$repairStatus.RepairMessage
                    }
                    Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
                }
                }
                else {
                    $sourceFingerprint = Get-SourceOutboxFingerprint -TargetId ([string]$item.TargetId) -Readiness $sourceOutboxReadiness
                    if (-not $sourceOutboxState.ContainsKey($sourceFingerprint)) {
                        $sourceImportResult = $null
                        $sourceImportFailure = ''
                        try {
                            $sourceImportResult = Invoke-SourceOutboxImport `
                                -Root $root `
                                -ConfigPath $resolvedConfigPath `
                                -RunRoot $resolvedRunRoot `
                                -TargetId ([string]$item.TargetId) `
                                -SummarySourcePath ([string]$sourceOutboxReadiness.Paths.SourceSummaryPath) `
                                -ReviewZipSourcePath ([string]$sourceOutboxReadiness.Paths.SourceReviewZipPath) `
                                -SourcePublishReadyPath ([string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath) `
                                -SourcePublishedAt ([string]$sourceOutboxReadiness.PublishedAt) `
                                -SourcePublishAttemptId ([string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'AttemptId' -DefaultValue '')) `
                                -SourcePublishSequence ([int](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishSequence' -DefaultValue 0)) `
                                -SourcePublishCycleId ([string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishCycleId' -DefaultValue '')) `
                                -SourceValidationCompletedAt ([string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'ValidationCompletedAt' -DefaultValue '')) `
                                -SourceSummarySha256 ([string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'SummarySha256' -DefaultValue '')) `
                                -SourceReviewZipSha256 ([string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'ReviewZipSha256' -DefaultValue ''))
                        }
                        catch {
                            $sourceImportFailure = $_.Exception.Message
                        }

                        if ([string]::IsNullOrWhiteSpace($sourceImportFailure) -and ($null -eq $sourceImportResult.Json -or $sourceImportResult.ExitCode -ne 0 -or -not [bool]$sourceImportResult.Json.Validation.Ok)) {
                            $issues = if ($null -ne $sourceImportResult.Json -and $null -ne $sourceImportResult.Json.Validation) {
                                @($sourceImportResult.Json.Validation.Issues | ForEach-Object { [string]$_ })
                            }
                            else {
                                @()
                            }
                            $sourceImportFailure = if ($issues.Count -gt 0) {
                                ('import-failed:' + ($issues -join ','))
                            }
                            else {
                                ('import-exit-' + [string]$sourceImportResult.ExitCode)
                            }
                        }

                        if (Test-NonEmptyString $sourceImportFailure) {
                            $sourceFailureKey = ($sourceFingerprint + '|' + $sourceImportFailure)
                            if (-not $sourceOutboxFailureState.ContainsKey($sourceFailureKey)) {
                                $sourceOutboxFailureState[$sourceFailureKey] = $true
                                Write-SourceOutboxFailureLog `
                                    -Path $sourceOutboxFailureLogPath `
                                    -PairId ([string]$item.PairId) `
                                    -TargetId ([string]$item.TargetId) `
                                    -MarkerPath ([string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath) `
                                    -StateKey $sourceFingerprint `
                                    -Message $sourceImportFailure
                                Write-Host ("source-outbox import failed {0} marker={1} error={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath, $sourceImportFailure)
                            }

                            $sourceOutboxStatusEntries[[string]$item.TargetId] = [pscustomobject]@{
                                TargetId            = [string]$item.TargetId
                                PairId              = [string]$item.PairId
                                UpdatedAt           = (Get-Date).ToString('o')
                                State               = 'failed'
                                Reason              = $sourceImportFailure
                                SourceOutboxPath    = [string]$sourceOutboxReadiness.Paths.SourceOutboxPath
                                SourceSummaryPath   = [string]$sourceOutboxReadiness.Paths.SourceSummaryPath
                                SourceReviewZipPath = [string]$sourceOutboxReadiness.Paths.SourceReviewZipPath
                                PublishReadyPath    = [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath
                                PublishedAt         = [string]$sourceOutboxReadiness.PublishedAt
                                PublishSequence     = [int](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishSequence' -DefaultValue 0)
                                PublishCycleId      = [string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishCycleId' -DefaultValue '')
                                ContractLatestState = ''
                                NextAction          = ''
                                OriginalReadyReason = [string]$repairStatus.OriginalReadyReason
                                FinalReadyReason    = [string]$repairStatus.FinalReadyReason
                                RepairSourceContext = [string]$repairStatus.RepairSourceContext
                                RepairCommand       = [string]$repairStatus.RepairCommand
                                RepairAttempted     = [bool]$repairStatus.RepairAttempted
                                RepairSucceeded     = [bool]$repairStatus.RepairSucceeded
                                RepairCompletedAt   = [string]$repairStatus.RepairCompletedAt
                                RepairMessage       = [string]$repairStatus.RepairMessage
                            }
                            Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
                        }
                        else {
                            $archivedReadyPath = ''
                            $archiveFailure = ''
                            try {
                                if ([bool]$sourceOutboxReadiness.Paths.PublishReadyArchived) {
                                    $archivedReadyPath = [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath
                                }
                                else {
                                    $archivedReadyPath = Archive-SourceOutboxReadyMarker `
                                        -PublishReadyPath ([string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath) `
                                        -ArchiveRoot ([string]$sourceOutboxReadiness.Paths.PublishedArchivePath) `
                                        -TargetId ([string]$item.TargetId)
                                }
                            }
                            catch {
                                $archiveFailure = $_.Exception.Message
                                Write-SourceOutboxFailureLog `
                                    -Path $sourceOutboxFailureLogPath `
                                    -PairId ([string]$item.PairId) `
                                    -TargetId ([string]$item.TargetId) `
                                    -MarkerPath ([string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath) `
                                    -StateKey $sourceFingerprint `
                                    -Message ('archive-failed:' + $archiveFailure)
                            }

                            $sourceOutboxState[$sourceFingerprint] = (Get-Date).ToString('o')
                            Save-State -Path $sourceOutboxStatePath -State $sourceOutboxState
                            foreach ($sourcePendingKey in @($sourceOutboxPendingState.Keys | Where-Object { $_ -like ([string]$item.TargetId + '|*') })) {
                                $sourceOutboxPendingState.Remove([string]$sourcePendingKey) | Out-Null
                            }
                            foreach ($sourceFailureKey in @($sourceOutboxFailureState.Keys | Where-Object { $_ -like ($sourceFingerprint + '|*') })) {
                                $sourceOutboxFailureState.Remove([string]$sourceFailureKey) | Out-Null
                            }

                            $contractLatestState = if ($null -ne $sourceImportResult.Json -and $null -ne $sourceImportResult.Json.PostImportStatus) { [string]$sourceImportResult.Json.PostImportStatus.LatestState } else { '' }
                            $sourceOutboxStatusEntries[[string]$item.TargetId] = [pscustomobject]@{
                                TargetId            = [string]$item.TargetId
                                PairId              = [string]$item.PairId
                                UpdatedAt           = (Get-Date).ToString('o')
                                State               = $(if (Test-NonEmptyString $archiveFailure) { 'imported-archive-pending' } else { 'imported' })
                                Reason              = $(if (Test-NonEmptyString $archiveFailure) { $archiveFailure } else { '' })
                                SourceOutboxPath    = [string]$sourceOutboxReadiness.Paths.SourceOutboxPath
                                SourceSummaryPath   = [string]$sourceOutboxReadiness.Paths.SourceSummaryPath
                                SourceReviewZipPath = [string]$sourceOutboxReadiness.Paths.SourceReviewZipPath
                                PublishReadyPath    = [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath
                                PublishedAt         = [string]$sourceOutboxReadiness.PublishedAt
                                ArchivedReadyPath   = $archivedReadyPath
                                PublishSequence     = [int](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishSequence' -DefaultValue 0)
                                PublishCycleId      = [string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishCycleId' -DefaultValue '')
                                ImportedZipPath     = if ($null -ne $sourceImportResult.Json -and $null -ne $sourceImportResult.Json.Contract) { [string]$sourceImportResult.Json.Contract.DestinationZipPath } else { '' }
                                ImportedSourcePublishSequence = if ($null -ne $sourceImportResult.Json -and $null -ne $sourceImportResult.Json.SourcePublish) { [int](Get-ConfigValue -Object $sourceImportResult.Json.SourcePublish -Name 'PublishSequence' -DefaultValue 0) } else { [int](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishSequence' -DefaultValue 0) }
                                ImportedSourcePublishCycleId  = if ($null -ne $sourceImportResult.Json -and $null -ne $sourceImportResult.Json.SourcePublish) { [string](Get-ConfigValue -Object $sourceImportResult.Json.SourcePublish -Name 'PublishCycleId' -DefaultValue '') } else { [string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishCycleId' -DefaultValue '') }
                                LatestState         = $contractLatestState
                                ContractLatestState = $contractLatestState
                                NextAction          = Get-ContractNextAction -LatestState $contractLatestState
                                SuggestedAction     = ''
                                OriginalReadyReason = [string]$repairStatus.OriginalReadyReason
                                FinalReadyReason    = [string]$repairStatus.FinalReadyReason
                                RepairSourceContext = [string]$repairStatus.RepairSourceContext
                                RepairCommand       = [string]$repairStatus.RepairCommand
                                RepairAttempted     = [bool]$repairStatus.RepairAttempted
                                RepairSucceeded     = [bool]$repairStatus.RepairSucceeded
                                RepairCompletedAt   = [string]$repairStatus.RepairCompletedAt
                                RepairMessage       = [string]$repairStatus.RepairMessage
                            }
                            Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
                            Write-Host ("source-outbox imported {0} marker={1} destZip={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath, [string]$sourceOutboxStatusEntries[[string]$item.TargetId].ImportedZipPath)
                        }
                    }
                    else {
                        $duplicateArchivePath = ''
                        $duplicateArchiveFailure = ''
                        try {
                            if ([bool]$sourceOutboxReadiness.Paths.PublishReadyArchived) {
                                $duplicateArchivePath = [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath
                            }
                            else {
                                $duplicateArchivePath = Archive-SourceOutboxReadyMarker `
                                    -PublishReadyPath ([string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath) `
                                    -ArchiveRoot ([string]$sourceOutboxReadiness.Paths.PublishedArchivePath) `
                                    -TargetId ([string]$item.TargetId)
                            }
                        }
                        catch {
                            $duplicateArchiveFailure = $_.Exception.Message
                            Write-SourceOutboxFailureLog `
                                -Path $sourceOutboxFailureLogPath `
                                -PairId ([string]$item.PairId) `
                                -TargetId ([string]$item.TargetId) `
                                -MarkerPath ([string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath) `
                                -StateKey $sourceFingerprint `
                                -Message ('duplicate-archive-failed:' + $duplicateArchiveFailure)
                        }

                        $sourceOutboxStatusEntries[[string]$item.TargetId] = [pscustomobject]@{
                            TargetId            = [string]$item.TargetId
                            PairId              = [string]$item.PairId
                            UpdatedAt           = (Get-Date).ToString('o')
                            State               = $(if (Test-NonEmptyString $duplicateArchiveFailure) { 'duplicate-marker-present' } else { 'duplicate-marker-archived' })
                            Reason              = $duplicateArchiveFailure
                            SourceOutboxPath    = [string]$sourceOutboxReadiness.Paths.SourceOutboxPath
                            SourceSummaryPath   = [string]$sourceOutboxReadiness.Paths.SourceSummaryPath
                            SourceReviewZipPath = [string]$sourceOutboxReadiness.Paths.SourceReviewZipPath
                            PublishReadyPath    = [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath
                            PublishedAt         = [string]$sourceOutboxReadiness.PublishedAt
                            ArchivedReadyPath   = $duplicateArchivePath
                            PublishSequence     = [int](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishSequence' -DefaultValue 0)
                            PublishCycleId      = [string](Get-ConfigValue -Object $sourceOutboxReadiness.Marker -Name 'PublishCycleId' -DefaultValue '')
                            ImportedZipPath     = ''
                            LatestState         = 'duplicate-skipped'
                            ContractLatestState = ''
                            NextAction          = 'duplicate-skipped'
                            SuggestedAction     = ''
                            OriginalReadyReason = [string]$repairStatus.OriginalReadyReason
                            FinalReadyReason    = [string]$repairStatus.FinalReadyReason
                            RepairSourceContext = [string]$repairStatus.RepairSourceContext
                            RepairCommand       = [string]$repairStatus.RepairCommand
                            RepairAttempted     = [bool]$repairStatus.RepairAttempted
                            RepairSucceeded     = [bool]$repairStatus.RepairSucceeded
                            RepairCompletedAt   = [string]$repairStatus.RepairCompletedAt
                            RepairMessage       = [string]$repairStatus.RepairMessage
                        }
                        Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
                        Write-Host ("source-outbox duplicate skipped {0} marker={1}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.EffectivePublishReadyPath)
                    }
                }
            }

            $targetFolder = [string]$item.TargetFolder
            $reviewRoot = Join-Path $targetFolder ([string]$pairTest.ReviewFolderName)
            if (-not (Test-Path -LiteralPath $reviewRoot)) {
                continue
            }

            $summaryPath = Join-Path $targetFolder ([string]$pairTest.SummaryFileName)
            $donePath = Join-Path $targetFolder ([string]$pairTest.HeadlessExec.DoneFileName)
            $summaryValue = if (Test-Path -LiteralPath $summaryPath) { $summaryPath } else { '' }

            $latestZipFile = Get-ChildItem -LiteralPath $reviewRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc, Name -Descending |
                Select-Object -First 1
            if ($null -eq $latestZipFile) {
                continue
            }

            $stateKey = Get-ZipFingerprint -TargetId ([string]$item.TargetId) -ZipFile $latestZipFile
            if ($state.ContainsKey($stateKey)) {
                continue
            }

            $pairRoundtripLimit = [int](Get-ConfigValue -Object $pairRoundtripLimitMap -Name ([string]$item.PairId) -DefaultValue 0)
            $pairForwardLimit = if ($pairRoundtripLimit -gt 0) { ([math]::Max(1, $pairRoundtripLimit) * 2) } else { 0 }
            $pairForwardedCount = [int](Get-ConfigValue -Object $pairForwardedCounts -Name ([string]$item.PairId) -DefaultValue 0)
            if ($pairForwardLimit -gt 0 -and $pairForwardedCount -ge $pairForwardLimit) {
                continue
            }

            $readinessStatus = $null
            if (Test-Path -LiteralPath $donePath) {
                $readinessStatus = Test-DoneMarkerReadyForZip -DonePath $donePath -ZipFile $latestZipFile -MaxSkewSeconds ([double]$pairTest.SummaryZipMaxSkewSeconds)
            }

            if ($null -eq $readinessStatus -or -not $readinessStatus.IsReady) {
                if ($null -eq $readinessStatus -or [string]$readinessStatus.Reason -eq 'done-missing') {
                    $readinessStatus = Test-SummaryReadyForZip -SummaryPath $summaryPath -ZipFile $latestZipFile -MaxSkewSeconds ([double]$pairTest.SummaryZipMaxSkewSeconds)
                }
            }

            if (-not $readinessStatus.IsReady) {
                $pendingStateKey = ($stateKey + '|' + [string]$readinessStatus.Reason)
                if (-not $pendingState.ContainsKey($pendingStateKey)) {
                    $pendingState[$pendingStateKey] = $true
                    Write-Host ("waiting {0} zip={1} reason={2}" -f [string]$item.TargetId, $latestZipFile.FullName, [string]$readinessStatus.Reason)
                }
                continue
            }

            $recipientItem = Get-ConfigValue -Object $targetItemsById -Name ([string]$item.PartnerTargetId) -DefaultValue $null
            if ($null -eq $recipientItem) {
                throw ("recipient target item not found: {0}" -f [string]$item.PartnerTargetId)
            }

            $visibleWorkerTransportActive = (([string]$pairTest.ExecutionPathMode -eq 'visible-worker') -and [bool]$pairTest.VisibleWorker.Enabled)
            $pauseBlocksDirectDispatch = $watcherPaused -and ($UseHeadlessDispatch -or -not $visibleWorkerTransportActive)
            if ($pauseBlocksDirectDispatch) {
                continue
            }

            $queueState = Get-OneTimeQueueDocument -Root $root -Config $config -PairId ([string]$recipientItem.PairId)
            $handoffOneTimeItems = @(Get-ApplicableOneTimeQueueItems `
                -QueueDocument $queueState.Document `
                -PairId ([string]$recipientItem.PairId) `
                -RoleName ([string]$recipientItem.RoleName) `
                -TargetId ([string]$recipientItem.TargetId) `
                -MessageType 'handoff')
            $handoffOneTimeItemIds = @($handoffOneTimeItems | ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'Id' -DefaultValue '') } | Where-Object { Test-NonEmptyString $_ })
            $messageText = Get-HandoffMessageText -PairTest $pairTest -SourceItem $item -RecipientItem $recipientItem -ZipPath $latestZipFile.FullName -SummaryPath $summaryValue -OneTimeItems $handoffOneTimeItems
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
            $messagePath = Join-Path $messageRoot ("handoff_{0}_to_{1}_{2}.txt" -f [string]$item.TargetId, [string]$item.PartnerTargetId, $stamp)
            [System.IO.File]::WriteAllText($messagePath, $messageText, (New-Utf8NoBomEncoding))
            $messageMetadata = New-PairedRelayMessageMetadata `
                -RunRoot $resolvedRunRoot `
                -PairId ([string]$recipientItem.PairId) `
                -TargetId ([string]$recipientItem.TargetId) `
                -PartnerTargetId ([string]$recipientItem.PartnerTargetId) `
                -RoleName ([string]$recipientItem.RoleName) `
                -InitialRoleMode ([string](Get-ConfigValue -Object $recipientItem -Name 'InitialRoleMode' -DefaultValue '')) `
                -MessageType 'pair-handoff' `
                -SourceTargetId ([string]$item.TargetId) `
                -MessagePath $messagePath
            Write-RelayMessageMetadata -MessagePath $messagePath -Metadata $messageMetadata | Out-Null

            try {
                if ($UseHeadlessDispatch) {
                    $dispatchLogPath = Join-Path $headlessDispatchLogRoot ("handoff_{0}_to_{1}_{2}.log" -f [string]$item.TargetId, [string]$item.PartnerTargetId, $stamp)
                    Invoke-HeadlessDispatch `
                        -Root $root `
                        -ConfigPath $resolvedConfigPath `
                        -RunRoot $resolvedRunRoot `
                        -TargetId ([string]$item.PartnerTargetId) `
                        -PromptFilePath $messagePath `
                        -LogPath $dispatchLogPath `
                        -StatusRoot $headlessDispatchLogRoot
                }
                else {
                    if ($visibleWorkerTransportActive) {
                        & (Join-Path $root 'visible\Queue-VisibleWorkerCommand.ps1') `
                            -ConfigPath $resolvedConfigPath `
                            -RunRoot $resolvedRunRoot `
                            -TargetId ([string]$item.PartnerTargetId) `
                            -PromptFilePath $messagePath `
                            -Mode 'handoff' | Out-Null
                    }
                    else {
                        $handoffSubmitRaw = & (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1') `
                            -ConfigPath $resolvedConfigPath `
                            -RunRoot $resolvedRunRoot `
                            -TargetId ([string]$item.PartnerTargetId) `
                            -MessageTextFilePath $messagePath `
                            -WaitForPublishSeconds ([int]$pairTest.SeedOutboxStartTimeoutSeconds) `
                            -DisallowInlineTypedWindowPrepare `
                            -AsJson
                        $handoffSubmitResult = $handoffSubmitRaw | ConvertFrom-Json
                        $handoffFinalState = [string](Get-ConfigValue -Object $handoffSubmitResult -Name 'FinalState' -DefaultValue '')
                        $handoffSubmitState = [string](Get-ConfigValue -Object $handoffSubmitResult -Name 'SubmitState' -DefaultValue '')
                        $handoffSubmitReason = [string](Get-ConfigValue -Object $handoffSubmitResult -Name 'SubmitReason' -DefaultValue '')
                        $handoffOutboxPublished = [bool](Get-ConfigValue -Object $handoffSubmitResult -Name 'OutboxPublished' -DefaultValue $false)
                        if (-not $handoffOutboxPublished -and $handoffFinalState -notin @('publish-detected', 'publish-detected-late')) {
                            $lateHandoffResult = Wait-TypedWindowHandoffLateSuccess `
                                -PairTest $pairTest `
                                -Item $recipientItem `
                                -TimeoutSeconds ([math]::Min([math]::Max(10, [int]$pairTest.SeedOutboxStartTimeoutSeconds), 30)) `
                                -PollIntervalMs $PollIntervalMs
                            if ([bool]$lateHandoffResult.Published) {
                                $handoffOutboxPublished = $true
                                $handoffFinalState = 'publish-detected-late'
                                $handoffSubmitState = 'confirmed'
                                $handoffSubmitReason = [string]$lateHandoffResult.Reason
                                Write-Host ("typed-window handoff late success {0} -> {1} reason={2}" -f [string]$item.TargetId, [string]$item.PartnerTargetId, $handoffSubmitReason)
                            }
                            else {
                                $lateHandoffReason = [string](Get-ConfigValue -Object $lateHandoffResult -Name 'Reason' -DefaultValue '')
                                if (Test-NonEmptyString $lateHandoffReason) {
                                    $handoffSubmitReason = if (Test-NonEmptyString $handoffSubmitReason) {
                                        ($handoffSubmitReason + '; lateGrace=' + $lateHandoffReason)
                                    }
                                    else {
                                        ('lateGrace=' + $lateHandoffReason)
                                    }
                                }

                                throw ("typed-window handoff not confirmed target={0} finalState={1} submitState={2} reason={3}" -f [string]$item.PartnerTargetId, $handoffFinalState, $handoffSubmitState, $handoffSubmitReason)
                            }
                        }
                    }
                }

                if ($handoffOneTimeItemIds.Count -gt 0) {
                    [void](Complete-OneTimeQueueItems `
                        -Root $root `
                        -Config $config `
                        -PairId ([string]$item.PairId) `
                        -ItemIds $handoffOneTimeItemIds `
                        -IgnoreMissing)
                }
            }
            catch {
                $failureMessage = $_.Exception.Message
                $failureStateKey = ($stateKey + '|' + $failureMessage)
                if (-not $handoffFailureState.ContainsKey($failureStateKey)) {
                    $handoffFailureState[$failureStateKey] = $true
                    Write-HandoffFailureLog `
                        -Path $handoffFailureLogPath `
                        -PairId ([string]$item.PairId) `
                        -TargetId ([string]$item.TargetId) `
                        -PartnerTargetId ([string]$item.PartnerTargetId) `
                        -ZipPath $latestZipFile.FullName `
                        -StateKey $stateKey `
                        -Message $failureMessage
                    Write-Host ("handoff failed {0} -> {1} zip={2} error={3}" -f [string]$item.TargetId, [string]$item.PartnerTargetId, $latestZipFile.FullName, $failureMessage)
                }
                continue
            }

            $state[$stateKey] = (Get-Date).ToString('o')
            foreach ($pendingKey in @($pendingState.Keys | Where-Object { $_ -like ($stateKey + '|*') })) {
                $pendingState.Remove([string]$pendingKey) | Out-Null
            }
            foreach ($failureKey in @($handoffFailureState.Keys | Where-Object { $_ -like ($stateKey + '|*') })) {
                $handoffFailureState.Remove([string]$failureKey) | Out-Null
            }
            Save-State -Path $statePath -State $state
            $forwardedThisRun++
            if (-not $pairForwardedCounts.ContainsKey([string]$item.PairId)) {
                $pairForwardedCounts[[string]$item.PairId] = 0
            }
            $pairForwardedCounts[[string]$item.PairId] += 1
            $pairStateEntries[[string]$item.PairId] = [pscustomobject]@{
                PairId = [string]$item.PairId
                LastFromTargetId = [string]$item.TargetId
                LastToTargetId = [string]$item.PartnerTargetId
                LastForwardedAt = (Get-Date).ToString('o')
                LastForwardedZipPath = [string]$latestZipFile.FullName
                LimitReachedAt = [string](Get-ConfigValue -Object (Get-ConfigValue -Object $pairStateEntries -Name ([string]$item.PairId) -DefaultValue $null) -Name 'LimitReachedAt' -DefaultValue '')
            }
            Write-PairStateSnapshot `
                -Path $pairStatePath `
                -RunRoot $resolvedRunRoot `
                -Entries $pairStateEntries `
                -PairProfiles $pairProfiles `
                -PairForwardedCounts $pairForwardedCounts `
                -SourceOutboxStatusEntries $sourceOutboxStatusEntries `
                -PairRoundtripLimitMap $pairRoundtripLimitMap `
                -WatcherPaused:$watcherPaused
            Write-Host ("forwarded {0} -> {1} zip={2}" -f [string]$item.TargetId, [string]$item.PartnerTargetId, $latestZipFile.FullName)

            if ($MaxForwardCount -gt 0 -and $forwardedThisRun -ge $MaxForwardCount) {
                Write-Host ("paired exchange watcher reached max forward count: {0}" -f $MaxForwardCount)
                $watcherStopReason = 'max-forward-count-reached'
                break
            }
            if (Test-AllPairsReachedRoundtripLimit -PairForwardedCounts $pairForwardedCounts -PairRoundtripLimitMap $pairRoundtripLimitMap) {
                Write-Host 'paired exchange watcher reached pair roundtrip limit.'
                $watcherStopReason = 'pair-roundtrip-limit-reached'
                break
            }
        }

        if ($MaxForwardCount -gt 0 -and $forwardedThisRun -ge $MaxForwardCount) {
            break
        }
        if (Test-AllPairsReachedRoundtripLimit -PairForwardedCounts $pairForwardedCounts -PairRoundtripLimitMap $pairRoundtripLimitMap) {
            break
        }

        Write-PairStateSnapshot `
            -Path $pairStatePath `
            -RunRoot $resolvedRunRoot `
            -Entries $pairStateEntries `
            -PairProfiles $pairProfiles `
            -PairForwardedCounts $pairForwardedCounts `
            -SourceOutboxStatusEntries $sourceOutboxStatusEntries `
            -PairRoundtripLimitMap $pairRoundtripLimitMap `
            -WatcherPaused:$watcherPaused
        Start-Sleep -Milliseconds $PollIntervalMs
    }

    [void](Clear-WatcherControlRequest -Path $watcherControlPath -RetryCount 10 -RetryDelayMs 100)
    Write-PairStateSnapshot `
        -Path $pairStatePath `
        -RunRoot $resolvedRunRoot `
        -Entries $pairStateEntries `
        -PairProfiles $pairProfiles `
        -PairForwardedCounts $pairForwardedCounts `
        -SourceOutboxStatusEntries $sourceOutboxStatusEntries `
        -PairRoundtripLimitMap $pairRoundtripLimitMap `
        -WatcherPaused:$watcherPaused
    $watcherStatusSequence++
    $watcherHeartbeatAt = (Get-Date).ToString('o')
    Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'stopping' -Reason $watcherStopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount -ConfiguredRunDurationSec $RunDurationSec -ConfiguredMaxRoundtripCount $PairMaxRoundtripCount
    Write-Host 'paired exchange watcher stopped.'
}
finally {
    if ($null -ne $watcherMutex) {
        try {
            $watcherMutex.ReleaseMutex()
        }
        catch {
        }

        $watcherMutex.Dispose()
    }

    if ($watcherStarted) {
        Ensure-Directory -Path $stateRoot
        [void](Clear-WatcherControlRequest -Path $watcherControlPath -RetryCount 10 -RetryDelayMs 100)
        Write-PairStateSnapshot `
            -Path $pairStatePath `
            -RunRoot $resolvedRunRoot `
            -Entries $pairStateEntries `
            -PairProfiles $pairProfiles `
            -PairForwardedCounts $pairForwardedCounts `
            -SourceOutboxStatusEntries $sourceOutboxStatusEntries `
            -PairRoundtripLimitMap $pairRoundtripLimitMap `
            -WatcherPaused:$watcherPaused
        if (Test-NonEmptyString $watcherRequestId) {
            $watcherLastHandledRequestId = $watcherRequestId
            $watcherLastHandledAction = $watcherAction
            $watcherLastHandledResult = 'stopped'
            $watcherLastHandledAt = (Get-Date).ToString('o')
        }
        $watcherStatusSequence++
        $watcherHeartbeatAt = (Get-Date).ToString('o')
        Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'stopped' -Reason $watcherStopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount -ConfiguredRunDurationSec $RunDurationSec -ConfiguredMaxRoundtripCount $PairMaxRoundtripCount
    }
}
