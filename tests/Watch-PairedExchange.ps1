[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [int]$PollIntervalMs = 1500,
    [int]$RunDurationSec = 0,
    [switch]$UseHeadlessDispatch,
    [int]$MaxForwardCount = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    $persisted | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
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

    $ordered | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
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
        RequestId            = $RequestId
        Action               = $Action
        LastHandledRequestId = $LastHandledRequestId
        LastHandledAction    = $LastHandledAction
        LastHandledResult    = $LastHandledResult
        LastHandledAt        = $LastHandledAt
    }

    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-WatcherControlRequest {
    param([Parameter(Mandatory)][string]$Path)

    $doc = Read-JsonObject -Path $Path
    if ($null -eq $doc) {
        return $null
    }

    if ([string]$doc.Action -ne 'stop') {
        return $null
    }

    return $doc
}

function Clear-WatcherControlRequest {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
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

function Test-SourceOutboxReady {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)]$Item
    )

    $paths = Get-SourceOutboxPaths -PairTest $PairTest -Item $Item
    $readyPath = [string]$paths.PublishReadyPath
    $readyExists = Test-Path -LiteralPath $readyPath -PathType Leaf
    $readyItem = if ($readyExists) { Get-Item -LiteralPath $readyPath -ErrorAction Stop } else { $null }
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
    foreach ($requiredField in @('SchemaVersion', 'PairId', 'TargetId', 'SummaryPath', 'ReviewZipPath', 'PublishedAt', 'SummarySizeBytes', 'ReviewZipSizeBytes')) {
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
        [Parameter(Mandatory)][string]$ReviewZipSourcePath
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

    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
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
    $recipientSourceOutboxPath = Join-Path ([string]$SourceItem.PartnerFolder) ([string]$PairTest.SourceOutboxFolderName)
    $recipientSourceSummaryPath = Join-Path $recipientSourceOutboxPath ([string]$PairTest.SourceSummaryFileName)
    $recipientSourceReviewZipPath = Join-Path $recipientSourceOutboxPath ([string]$PairTest.SourceReviewZipFileName)
    $recipientPublishReadyPath = Join-Path $recipientSourceOutboxPath ([string]$PairTest.PublishReadyFileName)
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
    $targetItems = @($manifest.Targets)
    $targetItemsById = @{}
    foreach ($targetItem in @($targetItems)) {
        $targetItemsById[[string]$targetItem.TargetId] = $targetItem
    }
    Ensure-Directory -Path $stateRoot
    $statePath = Join-Path $stateRoot 'forwarded.json'
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
    $sourceOutboxStatusEntries = @{}
    $forwardedThisRun = 0
    Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
    $watcherStatusSequence++
    $watcherHeartbeatAt = (Get-Date).ToString('o')
    Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'running' -Reason 'started' -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount
    $watcherStarted = $true

    Write-Host "watching paired exchange root: $resolvedRunRoot mutex=$watcherMutexName"

    while ($true) {
        if ($RunDurationSec -gt 0 -and $stopwatch.Elapsed.TotalSeconds -ge $RunDurationSec) {
            $watcherStopReason = 'run-duration-reached'
            break
        }

        $watcherStatusSequence++
        $watcherHeartbeatAt = (Get-Date).ToString('o')
        Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'running' -Reason 'heartbeat' -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount
        $controlRequest = Get-WatcherControlRequest -Path $watcherControlPath
        if ($null -ne $controlRequest -and [string]$controlRequest.RunRoot -eq $resolvedRunRoot) {
            $watcherRequestId = [string]$controlRequest.RequestId
            $watcherAction = [string]$controlRequest.Action
            $watcherLastHandledRequestId = $watcherRequestId
            $watcherLastHandledAction = $watcherAction
            $watcherLastHandledResult = 'accepted'
            $watcherLastHandledAt = (Get-Date).ToString('o')
            $watcherStopReason = 'control-stop-request'
            $watcherStatusSequence++
            $watcherHeartbeatAt = (Get-Date).ToString('o')
            Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'stop_requested' -Reason $watcherStopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount
            Clear-WatcherControlRequest -Path $watcherControlPath
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
            if ($sourceOutboxReadiness.MarkerPresent) {
                if (-not $sourceOutboxReadiness.IsReady) {
                    $sourcePendingKey = [string]$sourceOutboxReadiness.StateKey
                    if (Test-NonEmptyString $sourcePendingKey -and -not $sourceOutboxPendingState.ContainsKey($sourcePendingKey)) {
                        $sourceOutboxPendingState[$sourcePendingKey] = $true
                        Write-Host ("source-outbox waiting {0} marker={1} reason={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.PublishReadyPath, [string]$sourceOutboxReadiness.Reason)
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
                        PublishReadyPath    = [string]$sourceOutboxReadiness.Paths.PublishReadyPath
                        PublishedAt         = [string]$sourceOutboxReadiness.PublishedAt
                        ContractLatestState = ''
                        NextAction          = ''
                    }
                    Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
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
                                -ReviewZipSourcePath ([string]$sourceOutboxReadiness.Paths.SourceReviewZipPath)
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
                                    -MarkerPath ([string]$sourceOutboxReadiness.Paths.PublishReadyPath) `
                                    -StateKey $sourceFingerprint `
                                    -Message $sourceImportFailure
                                Write-Host ("source-outbox import failed {0} marker={1} error={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.PublishReadyPath, $sourceImportFailure)
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
                                PublishReadyPath    = [string]$sourceOutboxReadiness.Paths.PublishReadyPath
                                PublishedAt         = [string]$sourceOutboxReadiness.PublishedAt
                                ContractLatestState = ''
                                NextAction          = ''
                            }
                            Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
                        }
                        else {
                            $archivedReadyPath = ''
                            $archiveFailure = ''
                            try {
                                $archivedReadyPath = Archive-SourceOutboxReadyMarker `
                                    -PublishReadyPath ([string]$sourceOutboxReadiness.Paths.PublishReadyPath) `
                                    -ArchiveRoot ([string]$sourceOutboxReadiness.Paths.PublishedArchivePath) `
                                    -TargetId ([string]$item.TargetId)
                            }
                            catch {
                                $archiveFailure = $_.Exception.Message
                                Write-SourceOutboxFailureLog `
                                    -Path $sourceOutboxFailureLogPath `
                                    -PairId ([string]$item.PairId) `
                                    -TargetId ([string]$item.TargetId) `
                                    -MarkerPath ([string]$sourceOutboxReadiness.Paths.PublishReadyPath) `
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
                                PublishReadyPath    = [string]$sourceOutboxReadiness.Paths.PublishReadyPath
                                PublishedAt         = [string]$sourceOutboxReadiness.PublishedAt
                                ArchivedReadyPath   = $archivedReadyPath
                                ImportedZipPath     = if ($null -ne $sourceImportResult.Json -and $null -ne $sourceImportResult.Json.Contract) { [string]$sourceImportResult.Json.Contract.DestinationZipPath } else { '' }
                                LatestState         = $contractLatestState
                                ContractLatestState = $contractLatestState
                                NextAction          = Get-ContractNextAction -LatestState $contractLatestState
                            }
                            Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
                            Write-Host ("source-outbox imported {0} marker={1} destZip={2}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.PublishReadyPath, [string]$sourceOutboxStatusEntries[[string]$item.TargetId].ImportedZipPath)
                        }
                    }
                    else {
                        $duplicateArchivePath = ''
                        $duplicateArchiveFailure = ''
                        try {
                            $duplicateArchivePath = Archive-SourceOutboxReadyMarker `
                                -PublishReadyPath ([string]$sourceOutboxReadiness.Paths.PublishReadyPath) `
                                -ArchiveRoot ([string]$sourceOutboxReadiness.Paths.PublishedArchivePath) `
                                -TargetId ([string]$item.TargetId)
                        }
                        catch {
                            $duplicateArchiveFailure = $_.Exception.Message
                            Write-SourceOutboxFailureLog `
                                -Path $sourceOutboxFailureLogPath `
                                -PairId ([string]$item.PairId) `
                                -TargetId ([string]$item.TargetId) `
                                -MarkerPath ([string]$sourceOutboxReadiness.Paths.PublishReadyPath) `
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
                            PublishReadyPath    = [string]$sourceOutboxReadiness.Paths.PublishReadyPath
                            PublishedAt         = [string]$sourceOutboxReadiness.PublishedAt
                            ArchivedReadyPath   = $duplicateArchivePath
                            ImportedZipPath     = ''
                            LatestState         = 'duplicate-skipped'
                            ContractLatestState = ''
                            NextAction          = 'duplicate-skipped'
                        }
                        Save-SourceOutboxStatus -Path $sourceOutboxStatusPath -RunRoot $resolvedRunRoot -Entries $sourceOutboxStatusEntries
                        Write-Host ("source-outbox duplicate skipped {0} marker={1}" -f [string]$item.TargetId, [string]$sourceOutboxReadiness.Paths.PublishReadyPath)
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

            $zipFiles = @(
                Get-ChildItem -LiteralPath $reviewRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc, Name
            )

            foreach ($zipFile in $zipFiles) {
                $stateKey = Get-ZipFingerprint -TargetId ([string]$item.TargetId) -ZipFile $zipFile
                if ($state.ContainsKey($stateKey)) {
                    continue
                }

                $readinessStatus = $null
                if (Test-Path -LiteralPath $donePath) {
                    $readinessStatus = Test-DoneMarkerReadyForZip -DonePath $donePath -ZipFile $zipFile -MaxSkewSeconds ([double]$pairTest.SummaryZipMaxSkewSeconds)
                }

                if ($null -eq $readinessStatus -or -not $readinessStatus.IsReady) {
                    if ($null -eq $readinessStatus -or [string]$readinessStatus.Reason -eq 'done-missing') {
                        $readinessStatus = Test-SummaryReadyForZip -SummaryPath $summaryPath -ZipFile $zipFile -MaxSkewSeconds ([double]$pairTest.SummaryZipMaxSkewSeconds)
                    }
                }

                if (-not $readinessStatus.IsReady) {
                    $pendingStateKey = ($stateKey + '|' + [string]$readinessStatus.Reason)
                    if (-not $pendingState.ContainsKey($pendingStateKey)) {
                        $pendingState[$pendingStateKey] = $true
                        Write-Host ("waiting {0} zip={1} reason={2}" -f [string]$item.TargetId, $zipFile.FullName, [string]$readinessStatus.Reason)
                    }
                    continue
                }

                $recipientItem = Get-ConfigValue -Object $targetItemsById -Name ([string]$item.PartnerTargetId) -DefaultValue $null
                if ($null -eq $recipientItem) {
                    throw ("recipient target item not found: {0}" -f [string]$item.PartnerTargetId)
                }

                $queueState = Get-OneTimeQueueDocument -Root $root -Config $config -PairId ([string]$recipientItem.PairId)
                $handoffOneTimeItems = @(Get-ApplicableOneTimeQueueItems `
                    -QueueDocument $queueState.Document `
                    -PairId ([string]$recipientItem.PairId) `
                    -RoleName ([string]$recipientItem.RoleName) `
                    -TargetId ([string]$recipientItem.TargetId) `
                    -MessageType 'handoff')
                $messageText = Get-HandoffMessageText -PairTest $pairTest -SourceItem $item -RecipientItem $recipientItem -ZipPath $zipFile.FullName -SummaryPath $summaryValue -OneTimeItems $handoffOneTimeItems
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

                        $handoffOneTimeItemIds = @($handoffOneTimeItems | ForEach-Object { [string](Get-ConfigValue -Object $_ -Name 'Id' -DefaultValue '') } | Where-Object { Test-NonEmptyString $_ })
                        if ($handoffOneTimeItemIds.Count -gt 0) {
                            [void](Complete-OneTimeQueueItems `
                                -Root $root `
                                -Config $config `
                                -PairId ([string]$item.PairId) `
                                -ItemIds $handoffOneTimeItemIds `
                                -IgnoreMissing)
                        }
                    }
                    else {
                        & (Join-Path $root 'producer-example.ps1') `
                            -ConfigPath $resolvedConfigPath `
                            -TargetId ([string]$item.PartnerTargetId) `
                            -TextFilePath $messagePath | Out-Null
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
                            -ZipPath $zipFile.FullName `
                            -StateKey $stateKey `
                            -Message $failureMessage
                        Write-Host ("handoff failed {0} -> {1} zip={2} error={3}" -f [string]$item.TargetId, [string]$item.PartnerTargetId, $zipFile.FullName, $failureMessage)
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
                Write-Host ("forwarded {0} -> {1} zip={2}" -f [string]$item.TargetId, [string]$item.PartnerTargetId, $zipFile.FullName)

                if ($MaxForwardCount -gt 0 -and $forwardedThisRun -ge $MaxForwardCount) {
                    Write-Host ("paired exchange watcher reached max forward count: {0}" -f $MaxForwardCount)
                    $watcherStopReason = 'max-forward-count-reached'
                    break
                }
            }

            if ($MaxForwardCount -gt 0 -and $forwardedThisRun -ge $MaxForwardCount) {
                break
            }
        }

        if ($MaxForwardCount -gt 0 -and $forwardedThisRun -ge $MaxForwardCount) {
            break
        }

        Start-Sleep -Milliseconds $PollIntervalMs
    }

    $watcherStatusSequence++
    $watcherHeartbeatAt = (Get-Date).ToString('o')
    Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'stopping' -Reason $watcherStopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount
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
        if (Test-NonEmptyString $watcherRequestId) {
            $watcherLastHandledRequestId = $watcherRequestId
            $watcherLastHandledAction = $watcherAction
            $watcherLastHandledResult = 'stopped'
            $watcherLastHandledAt = (Get-Date).ToString('o')
        }
        $watcherStatusSequence++
        $watcherHeartbeatAt = (Get-Date).ToString('o')
        Save-WatcherStatus -Path $watcherStatusPath -RunRoot $resolvedRunRoot -MutexName $watcherMutexName -State 'stopped' -Reason $watcherStopReason -RequestId $watcherRequestId -Action $watcherAction -LastHandledRequestId $watcherLastHandledRequestId -LastHandledAction $watcherLastHandledAction -LastHandledResult $watcherLastHandledResult -LastHandledAt $watcherLastHandledAt -HeartbeatAt $watcherHeartbeatAt -StatusSequence $watcherStatusSequence -ProcessStartedAt $watcherProcessStartedAt -ForwardedCount $forwardedThisRun -ConfiguredMaxForwardCount $MaxForwardCount
    }
}
