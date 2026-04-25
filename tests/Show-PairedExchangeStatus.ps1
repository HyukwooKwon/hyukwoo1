[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [int]$RecentFailureCount = 10,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CurrentPairStateSchemaVersion = '1.0.0'
$SupportedPairStateSchemaVersions = @('1.0.0', '1.0')

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

function Get-PairPolicySummary {
    param($Policy)

    if ($null -eq $Policy) {
        return ''
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $seedTargetId = [string](Get-ConfigValue -Object $Policy -Name 'DefaultSeedTargetId' -DefaultValue '')
    $pairLimit = [int](Get-ConfigValue -Object $Policy -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0)
    $publishMode = [string](Get-ConfigValue -Object $Policy -Name 'PublishContractMode' -DefaultValue '')
    $recoveryPolicy = [string](Get-ConfigValue -Object $Policy -Name 'RecoveryPolicy' -DefaultValue '')

    if (Test-NonEmptyString $seedTargetId) {
        $parts.Add(('seed={0}' -f $seedTargetId))
    }
    if ($pairLimit -gt 0) {
        $parts.Add(('policyPairRt={0}' -f $pairLimit))
    }
    if (Test-NonEmptyString $publishMode) {
        $parts.Add(('publish={0}' -f $publishMode))
    }
    if (Test-NonEmptyString $recoveryPolicy) {
        $parts.Add(('recovery={0}' -f $recoveryPolicy))
    }

    return (@($parts) -join ' / ')
}

function Resolve-PairedRunRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$RequestedRunRoot,
        [Parameter(Mandatory)]$PairTest
    )

    if (Test-NonEmptyString $RequestedRunRoot) {
        if ([System.IO.Path]::IsPathRooted($RequestedRunRoot)) {
            return [System.IO.Path]::GetFullPath($RequestedRunRoot)
        }

        return [System.IO.Path]::GetFullPath((Join-Path $Root $RequestedRunRoot))
    }

    $pairTestRoot = [string](Get-ConfigValue -Object $PairTest -Name 'RunRootBase' -DefaultValue (Join-Path $Root 'pair-test'))
    if (-not (Test-Path -LiteralPath $pairTestRoot)) {
        throw "pair-test root not found: $pairTestRoot"
    }

    $latest = Get-ChildItem -LiteralPath $pairTestRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        throw "no paired run root found under: $pairTestRoot"
    }

    return $latest.FullName
}

function Read-JsonDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('array', 'object')][string]$ExpectedShape
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists      = $false
            ParseError  = ''
            Data        = if ($ExpectedShape -eq 'array') { @() } else { $null }
            LastWriteAt = ''
        }
    }

    $lastWriteAt = (Get-Item -LiteralPath $Path).LastWriteTime.ToString('o')
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            Exists      = $true
            ParseError  = ''
            Data        = if ($ExpectedShape -eq 'array') { @() } else { $null }
            LastWriteAt = $lastWriteAt
        }
    }

    try {
        $parsed = ConvertFrom-RelayJsonText -Json $raw
    }
    catch {
        try {
            $parsed = $raw | ConvertFrom-Json
        }
        catch {
            return [pscustomobject]@{
                Exists      = $true
                ParseError  = $_.Exception.Message
                Data        = if ($ExpectedShape -eq 'array') { @() } else { $null }
                LastWriteAt = $lastWriteAt
            }
        }
    }

    $data = if ($ExpectedShape -eq 'array') {
        if ($null -eq $parsed) {
            @()
        }
        elseif ($parsed -is [System.Array]) {
            $parsed
        }
        else {
            ,$parsed
        }
    }
    else {
        $parsed
    }

    return [pscustomobject]@{
        Exists      = $true
        ParseError  = ''
        Data        = $data
        LastWriteAt = $lastWriteAt
    }
}

function Get-AgeSeconds {
    param([string]$IsoTimestamp)

    if (-not (Test-NonEmptyString $IsoTimestamp)) {
        return $null
    }

    try {
        $parsed = [DateTimeOffset]::Parse($IsoTimestamp)
    }
    catch {
        return $null
    }

    return [math]::Round(((Get-Date).ToUniversalTime() - $parsed.UtcDateTime).TotalSeconds, 3)
}

function Load-ForwardedState {
    param([Parameter(Mandatory)][string]$Path)

    $doc = Read-JsonDocument -Path $Path -ExpectedShape 'object'
    $state = @{}

    if ($null -ne $doc.Data) {
        foreach ($property in $doc.Data.PSObject.Properties) {
            $state[[string]$property.Name] = [string]$property.Value
        }
    }

    return [pscustomobject]@{
        Exists      = $doc.Exists
        ParseError  = $doc.ParseError
        LastWriteAt = $doc.LastWriteAt
        Data        = $state
    }
}

function Load-PairState {
    param([Parameter(Mandatory)][string]$Path)

    $doc = Read-JsonDocument -Path $Path -ExpectedShape 'object'
    $state = @{}
    $schemaMetadata = Get-PairStateSchemaMetadata -DocumentData $doc.Data

    if ($null -ne $doc.Data) {
        foreach ($row in @($doc.Data.Pairs)) {
            $pairId = [string](Get-ConfigValue -Object $row -Name 'PairId' -DefaultValue '')
            if (Test-NonEmptyString $pairId) {
                $state[$pairId] = $row
            }
        }
    }

    return [pscustomobject]@{
        Exists      = $doc.Exists
        ParseError  = $doc.ParseError
        LastWriteAt = $doc.LastWriteAt
        Data        = $state
        SchemaVersion = [string]$schemaMetadata.SchemaVersion
        DeclaredSchemaVersion = [string]$schemaMetadata.DeclaredSchemaVersion
        SchemaStatus = [string]$schemaMetadata.SchemaStatus
        Warnings    = @($schemaMetadata.Warnings)
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

function Test-MutexHeld {
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

        if ($acquired) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
            }

            return $false
        }

        return $true
    }
    finally {
        $mutex.Dispose()
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

function Test-SummaryReadyForZip {
    param(
        [Parameter(Mandatory)][string]$SummaryPath,
        $ZipFile = $null,
        [double]$MaxSkewSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $SummaryPath)) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'summary-missing'
        }
    }

    if ($null -eq $ZipFile) {
        return [pscustomobject]@{
            IsReady = $true
            Reason  = ''
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
        $ZipFile = $null,
        [double]$MaxSkewSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $DonePath)) {
        return [pscustomobject]@{
            IsReady = $false
            Reason  = 'done-missing'
        }
    }

    if ($null -eq $ZipFile) {
        return [pscustomobject]@{
            IsReady = $true
            Reason  = ''
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

function Test-SuccessEvidenceDocument {
    param(
        $Document = $null,
        [string]$LatestZipPath = ''
    )

    if ($null -eq $Document) {
        return $false
    }

    $documentZipPath = [string](Get-ConfigValue -Object $Document -Name 'LatestZipPath' -DefaultValue '')
    if (-not (Test-NonEmptyString $documentZipPath) -or -not (Test-NonEmptyString $LatestZipPath)) {
        return $false
    }

    try {
        return ([System.IO.Path]::GetFullPath($documentZipPath).ToLowerInvariant() -eq $LatestZipPath)
    }
    catch {
        return ($documentZipPath.ToLowerInvariant() -eq $LatestZipPath)
    }
}

function Test-ErrorSuperseded {
    param(
        [Parameter(Mandatory)][string]$ErrorPath,
        [string]$DonePath = '',
        [string]$ResultPath = '',
        [string]$SummaryPath = '',
        $ZipFile = $null,
        $ReadinessStatus = $null
    )

    if (-not (Test-Path -LiteralPath $ErrorPath)) {
        return $false
    }

    if ($null -eq $ZipFile -or $null -eq $ReadinessStatus -or -not $ReadinessStatus.IsReady) {
        return $false
    }

    $errorTicks = (Get-Item -LiteralPath $ErrorPath -ErrorAction Stop).LastWriteTimeUtc.Ticks
    $latestZipPath = [System.IO.Path]::GetFullPath($ZipFile.FullName).ToLowerInvariant()
    $successTicks = @()

    foreach ($candidatePath in @($DonePath, $ResultPath)) {
        if (-not (Test-NonEmptyString $candidatePath) -or -not (Test-Path -LiteralPath $candidatePath)) {
            continue
        }

        $candidateDoc = Read-JsonDocument -Path $candidatePath -ExpectedShape 'object'
        if (-not (Test-SuccessEvidenceDocument -Document $candidateDoc.Data -LatestZipPath $latestZipPath)) {
            continue
        }

        $successTicks += (Get-Item -LiteralPath $candidatePath -ErrorAction Stop).LastWriteTimeUtc.Ticks
    }

    if ($successTicks.Count -eq 0) {
        return $false
    }

    return (($successTicks | Measure-Object -Maximum).Maximum -gt $errorTicks)
}

function Get-RecentFileSummary {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [pscustomobject]@{
        Name       = $item.Name
        FullName   = $item.FullName
        ModifiedAt = $item.LastWriteTime.ToString('o')
        SizeBytes  = if ($item.PSIsContainer) { 0 } else { [int64]$item.Length }
    }
}

function Load-CurrentHeadlessDispatchStatusState {
    param([Parameter(Mandatory)][string]$Root)

    $byTarget = @{}
    $parseErrorCount = 0
    if (-not (Test-Path -LiteralPath $Root)) {
        return [pscustomobject]@{
            Root            = $Root
            ByTarget        = $byTarget
            FileCount       = 0
            ParseErrorCount = 0
        }
    }

    $candidateFiles = @()
    $candidateFiles += @(Get-ChildItem -LiteralPath $Root -Filter 'dispatch_*.json' -File -ErrorAction SilentlyContinue)
    $candidateFiles += @(Get-ChildItem -LiteralPath $Root -Filter 'current_*.json' -File -ErrorAction SilentlyContinue)

    foreach ($file in @($candidateFiles | Sort-Object LastWriteTimeUtc, Name)) {
        $doc = Read-JsonDocument -Path $file.FullName -ExpectedShape 'object'
        if (Test-NonEmptyString $doc.ParseError -or $null -eq $doc.Data) {
            $parseErrorCount++
            continue
        }

        $targetId = [string](Get-ConfigValue -Object $doc.Data -Name 'TargetId' -DefaultValue '')
        if (-not (Test-NonEmptyString $targetId)) {
            continue
        }

        $row = [pscustomobject]@{
            Data      = $doc.Data
            UpdatedAt = [string]$doc.LastWriteAt
            Path      = $file.FullName
            IsLegacyCurrentFile = ($file.Name -like 'current_*.json')
        }

        $existing = Get-ConfigValue -Object $byTarget -Name $targetId -DefaultValue $null
        $shouldReplace = ($null -eq $existing)
        if (-not $shouldReplace) {
            $existingIsLegacy = [bool](Get-ConfigValue -Object $existing -Name 'IsLegacyCurrentFile' -DefaultValue $false)
            $currentIsLegacy = [bool]$row.IsLegacyCurrentFile
            $shouldReplace = ($existingIsLegacy -and -not $currentIsLegacy)
            if (-not $shouldReplace -and ($existingIsLegacy -eq $currentIsLegacy)) {
                $existingUpdated = [string](Get-ConfigValue -Object $existing -Name 'UpdatedAt' -DefaultValue '')
                $shouldReplace = ($existingUpdated -le [string]$doc.LastWriteAt)
            }
        }

        if ($shouldReplace) {
            $byTarget[$targetId] = $row
        }
    }

    return [pscustomobject]@{
        Root            = $Root
        ByTarget        = $byTarget
        FileCount       = $byTarget.Count
        ParseErrorCount = $parseErrorCount
    }
}

function Get-WatcherStopCategoryDisplay {
    param([string]$Reason = '')

    switch ($Reason) {
        'completed' { return 'completed' }
        'max-forward-count-reached' { return 'expected-limit' }
        'control-stop-request' { return 'manual-stop' }
        'run-duration-reached' { return 'time-limit' }
        default { return '' }
    }
}

function Get-ContractNextActionDisplay {
    param([string]$LatestState = '')

    switch ($LatestState) {
        'ready-to-forward' { return 'handoff-ready' }
        'forwarded' { return 'already-forwarded' }
        'error-present' { return 'manual-review' }
        'duplicate-skipped' { return 'duplicate-skipped' }
        default { return '' }
    }
}

function Get-PairNextActionDisplay {
    param([object[]]$Rows)

    $pairRows = @($Rows)
    if ((@($pairRows | Where-Object { $_.ErrorPresent -or $_.SourceOutboxNextAction -eq 'manual-review' })).Count -gt 0) {
        return 'manual-review'
    }

    if ((@($pairRows | Where-Object { $_.SourceOutboxNextAction -eq 'handoff-ready' -or $_.LatestState -eq 'ready-to-forward' })).Count -gt 0) {
        return 'handoff-ready'
    }

    if ((@($pairRows | Where-Object { $_.DispatchState -eq 'running' })).Count -gt 0) {
        return 'dispatch-running'
    }

    if ((@($pairRows | Where-Object { $_.DispatchState -eq 'failed' })).Count -gt 0) {
        return 'dispatch-failed'
    }

    if ((@($pairRows | Where-Object { $_.LatestState -in @('summary-missing', 'summary-stale', 'done-stale', 'no-zip') })).Count -gt 0) {
        return 'artifact-check-needed'
    }

    if ((@($pairRows | Where-Object { $_.LatestState -eq 'forwarded' })).Count -gt 0) {
        return 'await-partner-output'
    }

    return ''
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PairedExchangeConfig.ps1')
. (Join-Path $root 'router\RelayMessageMetadata.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$pairTestFromConfig = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$resolvedRunRoot = Resolve-PairedRunRoot -Root $root -RequestedRunRoot $RunRoot -PairTest $pairTestFromConfig
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "manifest not found: $manifestPath"
}

$manifestDoc = Read-JsonDocument -Path $manifestPath -ExpectedShape 'object'
$manifest = $manifestDoc.Data
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath -ManifestPairTest (Get-ConfigValue -Object $manifest -Name 'PairTest' -DefaultValue $null)
$targetItems = if ($null -ne $manifest) { @($manifest.Targets) } else { @() }
$stateRoot = Join-Path $resolvedRunRoot '.state'
$forwardedStateDoc = Load-ForwardedState -Path (Join-Path $stateRoot 'forwarded.json')
$forwardedState = $forwardedStateDoc.Data
$pairStatePath = Join-Path $stateRoot 'pair-state.json'
$pairStateDoc = Load-PairState -Path $pairStatePath
$pairStateById = $pairStateDoc.Data
$forwardedCountsByTarget = @{}
foreach ($fingerprint in @($forwardedState.Keys)) {
    $rawFingerprint = [string]$fingerprint
    if (-not (Test-NonEmptyString $rawFingerprint)) {
        continue
    }

    $segments = $rawFingerprint.Split('|', 2)
    if ($segments.Count -lt 2) {
        continue
    }

    $targetId = [string]$segments[0]
    if (-not (Test-NonEmptyString $targetId)) {
        continue
    }

    if (-not $forwardedCountsByTarget.ContainsKey($targetId)) {
        $forwardedCountsByTarget[$targetId] = 0
    }
    $forwardedCountsByTarget[$targetId] += 1
}
$sourceOutboxStatusDoc = Read-JsonDocument -Path (Join-Path $stateRoot 'source-outbox-status.json') -ExpectedShape 'object'
$sourceOutboxStatusByTarget = @{}
foreach ($row in @(
        if ($null -ne $sourceOutboxStatusDoc.Data) { @($sourceOutboxStatusDoc.Data.Targets) } else { @() }
    )) {
    $targetId = [string](Get-ConfigValue -Object $row -Name 'TargetId' -DefaultValue '')
    if (Test-NonEmptyString $targetId) {
        $sourceOutboxStatusByTarget[$targetId] = $row
    }
}
$seedSendStatusDoc = Read-JsonDocument -Path (Join-Path $stateRoot 'seed-send-status.json') -ExpectedShape 'object'
$seedSendStatusByTarget = @{}
foreach ($row in @(
        if ($null -ne $seedSendStatusDoc.Data) { @($seedSendStatusDoc.Data.Targets) } else { @() }
    )) {
    $targetId = [string](Get-ConfigValue -Object $row -Name 'TargetId' -DefaultValue '')
    if (Test-NonEmptyString $targetId) {
        $seedSendStatusByTarget[$targetId] = $row
    }
}
$acceptanceReceiptPath = Join-Path $stateRoot 'live-acceptance-result.json'
$acceptanceReceiptDoc = Read-JsonDocument -Path $acceptanceReceiptPath -ExpectedShape 'object'
$acceptanceReceipt = $acceptanceReceiptDoc.Data
$handoffFailureLogPath = Join-Path $stateRoot 'handoff-failures.log'
$handoffFailureLines = if (Test-Path -LiteralPath $handoffFailureLogPath) { @(Get-Content -LiteralPath $handoffFailureLogPath -Encoding UTF8) } else { @() }
$watcherMutexName = Get-PairedWatcherMutexName -RunRoot $resolvedRunRoot
$watcherRunning = Test-MutexHeld -Name $watcherMutexName
$watcherControlPath = Join-Path $stateRoot 'watcher-control.json'
$watcherStatusPath = Join-Path $stateRoot 'watcher-status.json'
$watcherControlDoc = Read-JsonDocument -Path $watcherControlPath -ExpectedShape 'object'
$watcherControlData = $watcherControlDoc.Data
$watcherStatusDoc = Read-JsonDocument -Path $watcherStatusPath -ExpectedShape 'object'
$watcherStatusData = $watcherStatusDoc.Data
$watcherControlRequestedAt = [string](Get-ConfigValue -Object $watcherControlData -Name 'RequestedAt' -DefaultValue '')
$watcherStatusFileState = [string](Get-ConfigValue -Object $watcherStatusData -Name 'State' -DefaultValue '')
$watcherStatusReason = [string](Get-ConfigValue -Object $watcherStatusData -Name 'Reason' -DefaultValue '')
$watcherStatusUpdatedAt = [string](Get-ConfigValue -Object $watcherStatusData -Name 'UpdatedAt' -DefaultValue '')
$watcherHeartbeatAt = [string](Get-ConfigValue -Object $watcherStatusData -Name 'HeartbeatAt' -DefaultValue '')
$watcherStatusSequence = [int](Get-ConfigValue -Object $watcherStatusData -Name 'StatusSequence' -DefaultValue 0)
$watcherProcessStartedAt = [string](Get-ConfigValue -Object $watcherStatusData -Name 'ProcessStartedAt' -DefaultValue '')
$watcherStatusRequestId = [string](Get-ConfigValue -Object $watcherStatusData -Name 'RequestId' -DefaultValue '')
$watcherStatusAction = [string](Get-ConfigValue -Object $watcherStatusData -Name 'Action' -DefaultValue '')
$watcherStatusLastHandledRequestId = [string](Get-ConfigValue -Object $watcherStatusData -Name 'LastHandledRequestId' -DefaultValue '')
$watcherStatusLastHandledAction = [string](Get-ConfigValue -Object $watcherStatusData -Name 'LastHandledAction' -DefaultValue '')
$watcherStatusLastHandledResult = [string](Get-ConfigValue -Object $watcherStatusData -Name 'LastHandledResult' -DefaultValue '')
$watcherStatusLastHandledAt = [string](Get-ConfigValue -Object $watcherStatusData -Name 'LastHandledAt' -DefaultValue '')
$watcherStopCategory = [string](Get-ConfigValue -Object $watcherStatusData -Name 'StopCategory' -DefaultValue '')
$watcherForwardedCount = [int](Get-ConfigValue -Object $watcherStatusData -Name 'ForwardedCount' -DefaultValue (-1))
$watcherConfiguredMaxForwardCount = [int](Get-ConfigValue -Object $watcherStatusData -Name 'ConfiguredMaxForwardCount' -DefaultValue (-1))
$watcherConfiguredRunDurationSec = [int](Get-ConfigValue -Object $watcherStatusData -Name 'ConfiguredRunDurationSec' -DefaultValue (-1))
$watcherConfiguredMaxRoundtripCount = [int](Get-ConfigValue -Object $watcherStatusData -Name 'ConfiguredMaxRoundtripCount' -DefaultValue (-1))
if (-not (Test-NonEmptyString $watcherStopCategory)) {
    $watcherStopCategory = Get-WatcherStopCategoryDisplay -Reason $watcherStatusReason
}
$watcherControlPendingAction = [string](Get-ConfigValue -Object $watcherControlData -Name 'Action' -DefaultValue '')
$watcherControlPendingRequestId = [string](Get-ConfigValue -Object $watcherControlData -Name 'RequestId' -DefaultValue '')
$watcherControlAgeSeconds = Get-AgeSeconds -IsoTimestamp $watcherControlRequestedAt
$watcherStatusAgeSeconds = Get-AgeSeconds -IsoTimestamp $watcherStatusUpdatedAt
$watcherHeartbeatAgeSeconds = Get-AgeSeconds -IsoTimestamp $watcherHeartbeatAt
$watcherEffectiveStatus = if ($watcherRunning) {
    if ($watcherStatusFileState -in @('running', 'paused', 'stop_requested', 'stopping')) {
        $watcherStatusFileState
    }
    else {
        'running'
    }
}
else {
    'stopped'
}
$messagesRoot = Join-Path $resolvedRunRoot ([string]$pairTest.MessageFolderName)
$messageCount = if (Test-Path -LiteralPath $messagesRoot) { @(Get-ChildItem -LiteralPath $messagesRoot -File -ErrorAction SilentlyContinue).Count } else { 0 }
$headlessDispatchRoot = Join-Path $stateRoot 'headless-dispatch'
$headlessDispatchState = Load-CurrentHeadlessDispatchStatusState -Root $headlessDispatchRoot
$headlessDispatchByTarget = $headlessDispatchState.ByTarget
$targetRows = @()

foreach ($item in $targetItems | Sort-Object TargetId) {
    $targetId = [string]$item.TargetId
    $targetFolder = [string]$item.TargetFolder
    $contract = Get-TargetContractPaths -PairTest $pairTest -TargetEntry $item
    $requestDoc = Read-JsonDocument -Path ([string]$contract.RequestPath) -ExpectedShape 'object'
    $contract = Get-TargetContractPaths -PairTest $pairTest -TargetEntry $item -Request $requestDoc.Data
    $reviewRoot = [string]$contract.ReviewFolderPath
    $summaryPath = [string]$contract.SummaryPath
    $donePath = [string]$contract.DonePath
    $errorPath = [string]$contract.ErrorPath
    $resultPath = [string]$contract.ResultPath
    $summaryInfo = Get-RecentFileSummary -Path $summaryPath
    $doneInfo = Get-RecentFileSummary -Path $donePath
    $errorInfo = Get-RecentFileSummary -Path $errorPath
    $resultInfo = Get-RecentFileSummary -Path $resultPath
    $zipFiles = @()
    if (Test-Path -LiteralPath $reviewRoot) {
        $zipFiles = @(
            Get-ChildItem -LiteralPath $reviewRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property LastWriteTimeUtc, Name -Descending
        )
    }

    $latestZip = if ($zipFiles.Count -gt 0) { $zipFiles[0] } else { $null }
    $latestFingerprint = if ($null -ne $latestZip) { Get-ZipFingerprint -TargetId ([string]$item.TargetId) -ZipFile $latestZip } else { '' }
    $latestForwardedAt = if (Test-NonEmptyString $latestFingerprint -and $forwardedState.ContainsKey($latestFingerprint)) { [string]$forwardedState[$latestFingerprint] } else { '' }
    $readinessStatus = $null
    if ($null -ne $doneInfo) {
        $readinessStatus = Test-DoneMarkerReadyForZip -DonePath $donePath -ZipFile $latestZip -MaxSkewSeconds ([double]$pairTest.SummaryZipMaxSkewSeconds)
    }
    if ($null -eq $readinessStatus -or -not $readinessStatus.IsReady) {
        if ($null -eq $readinessStatus -or [string]$readinessStatus.Reason -eq 'done-missing') {
            $readinessStatus = Test-SummaryReadyForZip -SummaryPath $summaryPath -ZipFile $latestZip -MaxSkewSeconds ([double]$pairTest.SummaryZipMaxSkewSeconds)
        }
    }
    $errorSuperseded = if ($null -ne $errorInfo) {
        Test-ErrorSuperseded -ErrorPath $errorPath -DonePath $donePath -ResultPath $resultPath -SummaryPath $summaryPath -ZipFile $latestZip -ReadinessStatus $readinessStatus
    }
    else {
        $false
    }
    $errorPresent = [bool](($null -ne $errorInfo) -and -not $errorSuperseded)
    $latestState = if ($null -eq $latestZip) {
        'no-zip'
    }
    elseif ($errorPresent) {
        'error-present'
    }
    elseif (-not $readinessStatus.IsReady) {
        [string]$readinessStatus.Reason
    }
    elseif (Test-NonEmptyString $latestForwardedAt) {
        'forwarded'
    }
    else {
        'ready-to-forward'
    }

    $targetFailureCount = (@($handoffFailureLines | Where-Object { $_ -match ("from={0}\b" -f [regex]::Escape($targetId)) })).Count
    $sourceOutboxRow = Get-ConfigValue -Object $sourceOutboxStatusByTarget -Name $targetId -DefaultValue $null
    $seedSendRow = Get-ConfigValue -Object $seedSendStatusByTarget -Name $targetId -DefaultValue $null
    $dispatchRow = Get-ConfigValue -Object $headlessDispatchByTarget -Name $targetId -DefaultValue $null
    $dispatchData = if ($null -ne $dispatchRow) { Get-ConfigValue -Object $dispatchRow -Name 'Data' -DefaultValue $null } else { $null }
    $sourceOutboxContractLatestState = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'ContractLatestState' -DefaultValue '')
    if (-not (Test-NonEmptyString $sourceOutboxContractLatestState)) {
        $sourceOutboxContractLatestState = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'LatestState' -DefaultValue '')
    }
    $sourceOutboxNextAction = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'NextAction' -DefaultValue '')
    if (-not (Test-NonEmptyString $sourceOutboxNextAction)) {
        $sourceOutboxNextAction = Get-ContractNextActionDisplay -LatestState $sourceOutboxContractLatestState
    }
    $sourceOutboxState = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'State' -DefaultValue '')
    $sourceOutboxReason = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'Reason' -DefaultValue '')
    $dispatchState = [string](Get-ConfigValue -Object $dispatchData -Name 'State' -DefaultValue '')
    $dispatchReason = [string](Get-ConfigValue -Object $dispatchData -Name 'Reason' -DefaultValue '')
    $seedSendRawState = [string](Get-ConfigValue -Object $seedSendRow -Name 'FinalState' -DefaultValue '')
    $submitRawState = [string](Get-ConfigValue -Object $seedSendRow -Name 'SubmitState' -DefaultValue '')
    $submitRawReason = [string](Get-ConfigValue -Object $seedSendRow -Name 'SubmitReason' -DefaultValue '')
    $lateSuccessEvidence = (
        ($null -ne $readinessStatus -and [bool]$readinessStatus.IsReady) -or
        ($latestState -in @('ready-to-forward', 'forwarded')) -or
        ($sourceOutboxState -in @('publish-started', 'imported', 'imported-archive-pending', 'duplicate-marker-archived'))
    )
    $seedSendState = $seedSendRawState
    $submitState = $submitRawState
    $submitReason = $submitRawReason
    $seedSendSuperseded = $false
    if ($lateSuccessEvidence -and (($submitRawState -eq 'unconfirmed') -or ($seedSendRawState -in @('timeout', 'submit-unconfirmed', 'failed', 'worker-not-ready', 'dispatch-accepted-stale', 'dispatch-running-stale-no-heartbeat')))) {
        $seedSendState = 'superseded-late-success'
        $submitState = 'confirmed'
        $submitReason = if (Test-NonEmptyString $submitRawReason) { ('superseded-late-success:' + $submitRawReason) } else { 'outbox-publish-detected-late' }
        $seedSendSuperseded = $true
    }

    $targetRows += [pscustomobject]@{
        PairId            = [string]$item.PairId
        RoleName          = [string]$item.RoleName
        TargetId          = $targetId
        PartnerTargetId   = [string]$item.PartnerTargetId
        RequestPath       = [string]$contract.RequestPath
        SummaryPath       = $summaryPath
        ReviewFolderPath  = $reviewRoot
        DonePath          = $donePath
        ErrorPath         = $errorPath
        ResultPath        = $resultPath
        SummaryPresent    = [bool]($null -ne $summaryInfo)
        SummaryModifiedAt = if ($null -ne $summaryInfo) { [string]$summaryInfo.ModifiedAt } else { '' }
        DonePresent       = [bool]($null -ne $doneInfo)
        DoneModifiedAt    = if ($null -ne $doneInfo) { [string]$doneInfo.ModifiedAt } else { '' }
        ResultPresent     = [bool]($null -ne $resultInfo)
        ResultModifiedAt  = if ($null -ne $resultInfo) { [string]$resultInfo.ModifiedAt } else { '' }
        ErrorPresent      = $errorPresent
        ErrorFilePresent  = [bool]($null -ne $errorInfo)
        ErrorSuperseded   = [bool]$errorSuperseded
        ErrorModifiedAt   = if ($null -ne $errorInfo) { [string]$errorInfo.ModifiedAt } else { '' }
        ZipCount          = $zipFiles.Count
        LatestZipName     = if ($null -ne $latestZip) { [string]$latestZip.Name } else { '' }
        LatestZipModifiedAt = if ($null -ne $latestZip) { $latestZip.LastWriteTime.ToString('o') } else { '' }
        LatestState       = $latestState
        SourceOutboxState = $sourceOutboxState
        SourceOutboxReason = $sourceOutboxReason
        SourceOutboxContractLatestState = $sourceOutboxContractLatestState
        SourceOutboxNextAction = $sourceOutboxNextAction
        SourceOutboxUpdatedAt = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'UpdatedAt' -DefaultValue '')
        SourceOutboxLastActivityAt = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'SourceOutboxLastActivityAt' -DefaultValue '')
        DispatchState     = $dispatchState
        DispatchReason    = $dispatchReason
        DispatchStartedAt = [string](Get-ConfigValue -Object $dispatchData -Name 'StartedAt' -DefaultValue '')
        DispatchCompletedAt = [string](Get-ConfigValue -Object $dispatchData -Name 'CompletedAt' -DefaultValue '')
        DispatchExitCode  = [string](Get-ConfigValue -Object $dispatchData -Name 'ExitCode' -DefaultValue '')
        DispatchUpdatedAt = [string](Get-ConfigValue -Object $dispatchRow -Name 'UpdatedAt' -DefaultValue '')
        DispatchHeartbeatAt = [string](Get-ConfigValue -Object $dispatchData -Name 'HeartbeatAt' -DefaultValue '')
        DispatchElapsedSeconds = [int](Get-ConfigValue -Object $dispatchData -Name 'ElapsedSeconds' -DefaultValue 0)
        DispatchCpuSeconds = [double](Get-ConfigValue -Object $dispatchData -Name 'CpuSeconds' -DefaultValue 0)
        DispatchStdOutBytes = [int64](Get-ConfigValue -Object $dispatchData -Name 'StdOutBytes' -DefaultValue 0)
        DispatchStdErrBytes = [int64](Get-ConfigValue -Object $dispatchData -Name 'StdErrBytes' -DefaultValue 0)
        SeedSendState     = $seedSendState
        SeedSendRawState  = $seedSendRawState
        SeedSendSuperseded = $seedSendSuperseded
        SeedProcessedAt   = [string](Get-ConfigValue -Object $seedSendRow -Name 'ProcessedAt' -DefaultValue '')
        SeedFirstAttemptedAt = [string](Get-ConfigValue -Object $seedSendRow -Name 'FirstAttemptedAt' -DefaultValue '')
        SeedLastAttemptedAt = [string](Get-ConfigValue -Object $seedSendRow -Name 'LastAttemptedAt' -DefaultValue '')
        SeedAttemptCount  = [int](Get-ConfigValue -Object $seedSendRow -Name 'AttemptCount' -DefaultValue 0)
        SeedMaxAttempts   = [int](Get-ConfigValue -Object $seedSendRow -Name 'MaxAttempts' -DefaultValue 0)
        SeedNextRetryAt   = [string](Get-ConfigValue -Object $seedSendRow -Name 'NextRetryAt' -DefaultValue '')
        SeedBackoffMs     = [int](Get-ConfigValue -Object $seedSendRow -Name 'BackoffMs' -DefaultValue 0)
        SeedRetryReason   = [string](Get-ConfigValue -Object $seedSendRow -Name 'RetryReason' -DefaultValue '')
        ManualAttentionRequired = [bool](Get-ConfigValue -Object $seedSendRow -Name 'ManualAttentionRequired' -DefaultValue $false)
        SubmitState       = $submitState
        SubmitRawState    = $submitRawState
        SubmitConfirmed   = [bool](Get-ConfigValue -Object $seedSendRow -Name 'SubmitConfirmed' -DefaultValue $false)
        SubmitReason      = $submitReason
        SubmitRawReason   = $submitRawReason
        ForwardedAt       = $latestForwardedAt
        FailureCount      = $targetFailureCount
        TargetFolder      = $targetFolder
    }
}

$pairDefinitions = if ($null -ne $manifest) { @($manifest.Pairs) } else { @() }
if ((@($pairDefinitions)).Count -eq 0) {
    $pairDefinitions = if ((@($pairTest.PairDefinitions)).Count -gt 0) {
        @(
            @($pairTest.PairDefinitions) | ForEach-Object {
                [pscustomobject]@{
                    PairId = [string](Get-ConfigValue -Object $_ -Name 'PairId' -DefaultValue '')
                    TopTargetId = [string](Get-ConfigValue -Object $_ -Name 'TopTargetId' -DefaultValue '')
                    BottomTargetId = [string](Get-ConfigValue -Object $_ -Name 'BottomTargetId' -DefaultValue '')
                    Policy = (Get-PairPolicyForPair -PairTest $pairTest -PairId ([string](Get-ConfigValue -Object $_ -Name 'PairId' -DefaultValue '')))
                }
            }
        )
    }
    else {
        @(
            $targetRows |
                Group-Object PairId |
                ForEach-Object {
                    $rows = @($_.Group)
                    $topRow = @($rows | Where-Object { $_.RoleName -eq 'top' } | Select-Object -First 1)
                    $bottomRow = @($rows | Where-Object { $_.RoleName -eq 'bottom' } | Select-Object -First 1)
                    [pscustomobject]@{
                        PairId = [string]$_.Name
                        TopTargetId = if ((@($topRow)).Count -gt 0) { [string]$topRow[0].TargetId } else { '' }
                        BottomTargetId = if ((@($bottomRow)).Count -gt 0) { [string]$bottomRow[0].TargetId } else { '' }
                        Policy = $null
                    }
                }
        )
    }
}

$pairRows = @()
foreach ($pair in $pairDefinitions | Sort-Object PairId) {
    $pairId = [string](Get-ConfigValue -Object $pair -Name 'PairId' -DefaultValue '')
    if (-not (Test-NonEmptyString $pairId)) {
        continue
    }

    $rows = @($targetRows | Where-Object { $_.PairId -eq $pairId } | Sort-Object TargetId)
    $pairStateRow = Get-ConfigValue -Object $pairStateById -Name $pairId -DefaultValue $null
    $topTargetId = [string](Get-ConfigValue -Object $pair -Name 'TopTargetId' -DefaultValue '')
    $bottomTargetId = [string](Get-ConfigValue -Object $pair -Name 'BottomTargetId' -DefaultValue '')
    $pairPolicy = Get-ConfigValue -Object $pair -Name 'Policy' -DefaultValue $null
    if (-not (Test-NonEmptyString $topTargetId)) {
        $topTargetId = [string](($rows | Where-Object { $_.RoleName -eq 'top' } | Select-Object -First 1).TargetId)
    }
    if (-not (Test-NonEmptyString $bottomTargetId)) {
        $bottomTargetId = [string](($rows | Where-Object { $_.RoleName -eq 'bottom' } | Select-Object -First 1).TargetId)
    }

    $targetsLabel = if ((Test-NonEmptyString $topTargetId) -and (Test-NonEmptyString $bottomTargetId)) {
        ('{0} ↔ {1}' -f $topTargetId, $bottomTargetId)
    }
    else {
        (@($rows | ForEach-Object { [string]$_.TargetId }) -join ', ')
    }

    $latestStateSummary = if ((@($rows)).Count -gt 0) {
        (@($rows | ForEach-Object { '{0}:{1}' -f [string]$_.TargetId, [string]$_.LatestState }) -join ', ')
    }
    else {
        ''
    }
    if (-not (Test-NonEmptyString $latestStateSummary)) {
        $latestStateSummary = [string](Get-ConfigValue -Object $pairStateRow -Name 'StateSummary' -DefaultValue '')
    }
    $pairForwardedStateCount = 0
    foreach ($targetId in @($rows | ForEach-Object { [string]$_.TargetId })) {
        $pairForwardedStateCount += [int](Get-ConfigValue -Object $forwardedCountsByTarget -Name $targetId -DefaultValue 0)
    }
    $pairRoundtripCount = [math]::Floor($pairForwardedStateCount / 2)
    $handoffReadyCount = (@($rows | Where-Object { $_.SourceOutboxNextAction -eq 'handoff-ready' -or $_.LatestState -eq 'ready-to-forward' })).Count
    $dispatchRunningCount = (@($rows | Where-Object { $_.DispatchState -eq 'running' })).Count
    $dispatchFailedCount = (@($rows | Where-Object { $_.DispatchState -eq 'failed' })).Count
    $zipPresentCount = (@($rows | Where-Object { $_.ZipCount -gt 0 })).Count
    $donePresentCount = (@($rows | Where-Object { $_.DonePresent })).Count
    $errorPresentCount = (@($rows | Where-Object { $_.ErrorPresent })).Count
    $failureCount = (@($rows | ForEach-Object { [int]$_.FailureCount } | Measure-Object -Sum).Sum)
    $currentPhase = ''
    $nextExpectedHandoff = ''
    $nextAction = Get-PairNextActionDisplay -Rows $rows
    $policyConfiguredMaxRoundtripCount = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0)
    $configuredMaxRoundtripCount = if ($watcherConfiguredMaxRoundtripCount -gt 0) { $watcherConfiguredMaxRoundtripCount } elseif ($policyConfiguredMaxRoundtripCount -gt 0) { $policyConfiguredMaxRoundtripCount } else { 0 }
    $reachedRoundtripLimit = [bool]($configuredMaxRoundtripCount -gt 0 -and $pairRoundtripCount -ge $configuredMaxRoundtripCount)
    if ($null -ne $pairStateRow) {
        $pairForwardedStateCount = [int](Get-ConfigValue -Object $pairStateRow -Name 'ForwardCount' -DefaultValue $pairForwardedStateCount)
        $pairRoundtripCount = [int](Get-ConfigValue -Object $pairStateRow -Name 'RoundtripCount' -DefaultValue $pairRoundtripCount)
        $handoffReadyCount = [int](Get-ConfigValue -Object $pairStateRow -Name 'HandoffReadyCount' -DefaultValue $handoffReadyCount)
        $currentPhase = [string](Get-ConfigValue -Object $pairStateRow -Name 'CurrentPhase' -DefaultValue '')
        $nextExpectedHandoff = [string](Get-ConfigValue -Object $pairStateRow -Name 'NextExpectedHandoff' -DefaultValue '')
        $nextAction = [string](Get-ConfigValue -Object $pairStateRow -Name 'NextAction' -DefaultValue $nextAction)
        $configuredMaxRoundtripCount = [int](Get-ConfigValue -Object $pairStateRow -Name 'ConfiguredMaxRoundtripCount' -DefaultValue $configuredMaxRoundtripCount)
        $reachedRoundtripLimit = [bool](Get-ConfigValue -Object $pairStateRow -Name 'LimitReached' -DefaultValue $reachedRoundtripLimit)
    }
    $currentPhase = Normalize-PairPhase -Phase $currentPhase -WatcherStatus $watcherEffectiveStatus -NextAction $nextAction -LimitReached:$reachedRoundtripLimit
    $policySummary = Get-PairPolicySummary -Policy $pairPolicy
    $progressParts = @(
        ('왕복={0}' -f $pairRoundtripCount),
        ('forwardedState={0}' -f $pairForwardedStateCount)
    )
    if (Test-NonEmptyString $currentPhase) {
        $progressParts += ('단계={0}' -f $currentPhase)
    }
    if ($configuredMaxRoundtripCount -gt 0) {
        $progressParts += ('limit={0}' -f $configuredMaxRoundtripCount)
    }
    if ($reachedRoundtripLimit) {
        $progressParts += 'limit-reached'
    }
    if ($handoffReadyCount -gt 0) {
        $progressParts += ('handoffReady={0}' -f $handoffReadyCount)
    }
    if ($dispatchRunningCount -gt 0) {
        $progressParts += ('dispatchRunning={0}' -f $dispatchRunningCount)
    }
    if ($dispatchFailedCount -gt 0) {
        $progressParts += ('dispatchFailed={0}' -f $dispatchFailedCount)
    }
    if (Test-NonEmptyString $nextAction) {
        $progressParts += ('다음={0}' -f $nextAction)
    }
    if (Test-NonEmptyString $nextExpectedHandoff) {
        $progressParts += ('예정={0}' -f $nextExpectedHandoff)
    }
    if (Test-NonEmptyString $latestStateSummary) {
        $progressParts += ('state={0}' -f $latestStateSummary)
    }
    if (Test-NonEmptyString $policySummary) {
        $progressParts += ('policy={0}' -f $policySummary)
    }

    $pairRows += [pscustomobject]@{
        PairId              = $pairId
        Targets             = $targetsLabel
        TopTargetId         = $topTargetId
        BottomTargetId      = $bottomTargetId
        PolicySeedTargetId  = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedTargetId' -DefaultValue '')
        PolicyWatcherMaxForwardCount = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultWatcherMaxForwardCount' -DefaultValue 0)
        PolicyWatcherRunDurationSec = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultWatcherRunDurationSec' -DefaultValue 0)
        PolicyPairMaxRoundtripCount = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0)
        PolicyPublishContractMode = [string](Get-ConfigValue -Object $pairPolicy -Name 'PublishContractMode' -DefaultValue '')
        PolicyRecoveryPolicy = [string](Get-ConfigValue -Object $pairPolicy -Name 'RecoveryPolicy' -DefaultValue '')
        PolicyPauseAllowed = [bool](Get-ConfigValue -Object $pairPolicy -Name 'PauseAllowed' -DefaultValue $true)
        PolicySummary      = $policySummary
        LatestStateSummary  = $latestStateSummary
        ZipPresentCount     = $zipPresentCount
        FailureCount        = $failureCount
        DonePresentCount    = $donePresentCount
        ErrorPresentCount   = $errorPresentCount
        HandoffReadyCount   = $handoffReadyCount
        DispatchRunningCount = $dispatchRunningCount
        DispatchFailedCount = $dispatchFailedCount
        ForwardedStateCount = $pairForwardedStateCount
        RoundtripCount      = [int]$pairRoundtripCount
        ConfiguredMaxRoundtripCount = $configuredMaxRoundtripCount
        ReachedRoundtripLimit = [bool]$reachedRoundtripLimit
        CurrentPhase        = $currentPhase
        NextExpectedHandoff = $nextExpectedHandoff
        NextAction          = $nextAction
        ProgressDetail      = ($progressParts -join ' / ')
    }
}

$status = [pscustomobject]@{
    RunRoot   = $resolvedRunRoot
    Manifest  = [pscustomobject]@{
        Exists      = [bool]$manifestDoc.Exists
        ParseError  = [string]$manifestDoc.ParseError
        LastWriteAt = [string]$manifestDoc.LastWriteAt
        CreatedAt   = if ($null -ne $manifest) { [string]$manifest.CreatedAt } else { '' }
        TargetCount = (@($targetRows)).Count
        PairCount   = if ($null -ne $manifest) { (@($manifest.Pairs)).Count } else { 0 }
    }
    PairTest  = [pscustomobject]@{
        SummaryFileName   = [string]$pairTest.SummaryFileName
        ReviewFolderName  = [string]$pairTest.ReviewFolderName
        MessageFolderName = [string]$pairTest.MessageFolderName
        ReviewZipPattern  = [string]$pairTest.ReviewZipPattern
        SeedOutboxStartTimeoutSeconds = [int]$pairTest.SeedOutboxStartTimeoutSeconds
        SeedRetryMaxAttempts = [int]$pairTest.SeedRetryMaxAttempts
        SeedRetryBackoffMs = @($pairTest.SeedRetryBackoffMs)
        SummaryZipMaxSkewSeconds = [double]$pairTest.SummaryZipMaxSkewSeconds
        RequestFileName   = [string]$pairTest.HeadlessExec.RequestFileName
        DoneFileName      = [string]$pairTest.HeadlessExec.DoneFileName
        ErrorFileName     = [string]$pairTest.HeadlessExec.ErrorFileName
    }
    Watcher   = [pscustomobject]@{
        Status                 = $watcherEffectiveStatus
        MutexName              = $watcherMutexName
        StatusFileState        = $watcherStatusFileState
        StatusFileUpdatedAt    = $watcherStatusUpdatedAt
        HeartbeatAt            = $watcherHeartbeatAt
        HeartbeatAgeSeconds    = $watcherHeartbeatAgeSeconds
        StatusSequence         = $watcherStatusSequence
        ProcessStartedAt       = $watcherProcessStartedAt
        StatusReason           = $watcherStatusReason
        StopCategory           = $watcherStopCategory
        ForwardedCount         = if ($watcherForwardedCount -ge 0) { $watcherForwardedCount } else { (@($targetRows | Where-Object { $_.LatestState -eq 'forwarded' })).Count }
        ConfiguredMaxForwardCount = if ($watcherConfiguredMaxForwardCount -ge 0) { $watcherConfiguredMaxForwardCount } else { 0 }
        ConfiguredRunDurationSec = if ($watcherConfiguredRunDurationSec -ge 0) { $watcherConfiguredRunDurationSec } else { 0 }
        ConfiguredMaxRoundtripCount = if ($watcherConfiguredMaxRoundtripCount -ge 0) { $watcherConfiguredMaxRoundtripCount } else { 0 }
        StatusRequestId        = $watcherStatusRequestId
        StatusAction           = $watcherStatusAction
        LastHandledRequestId   = $watcherStatusLastHandledRequestId
        LastHandledAction      = $watcherStatusLastHandledAction
        LastHandledResult      = $watcherStatusLastHandledResult
        LastHandledAt          = $watcherStatusLastHandledAt
        StatusExists           = [bool]$watcherStatusDoc.Exists
        StatusParseError       = [string]$watcherStatusDoc.ParseError
        StatusLastWriteAt      = [string]$watcherStatusDoc.LastWriteAt
        StatusAgeSeconds       = $watcherStatusAgeSeconds
        StatusPath             = $watcherStatusPath
        ControlExists          = [bool]$watcherControlDoc.Exists
        ControlParseError      = [string]$watcherControlDoc.ParseError
        ControlLastWriteAt     = [string]$watcherControlDoc.LastWriteAt
        ControlRequestedAt     = $watcherControlRequestedAt
        ControlAgeSeconds      = $watcherControlAgeSeconds
        ControlPendingAction   = $watcherControlPendingAction
        ControlPendingRequestId = $watcherControlPendingRequestId
        ControlPath            = $watcherControlPath
    }
    Counts    = [pscustomobject]@{
        MessageFiles        = $messageCount
        SummaryPresentCount = (@($targetRows | Where-Object { $_.SummaryPresent })).Count
        DonePresentCount    = (@($targetRows | Where-Object { $_.DonePresent })).Count
        ErrorPresentCount   = (@($targetRows | Where-Object { $_.ErrorPresent })).Count
        ErrorFilePresentCount = (@($targetRows | Where-Object { $_.ErrorFilePresent })).Count
        ErrorSupersededCount = (@($targetRows | Where-Object { $_.ErrorSuperseded })).Count
        ZipPresentCount     = (@($targetRows | Where-Object { $_.ZipCount -gt 0 })).Count
        SourceOutboxWaitingCount = (@($targetRows | Where-Object { $_.SourceOutboxState -eq 'waiting' })).Count
        SeedSendProcessedCount = (@($targetRows | Where-Object { $_.SourceOutboxState -eq 'seed-send-processed' })).Count
        SeedRetryPendingCount = (@($targetRows | Where-Object { $_.SourceOutboxState -eq 'seed-retry-pending' })).Count
        SubmitUnconfirmedCount = (@($targetRows | Where-Object { $_.SourceOutboxState -eq 'submit-unconfirmed' })).Count
        PublishStartedCount = (@($targetRows | Where-Object { $_.SourceOutboxState -eq 'publish-started' })).Count
        TargetUnresponsiveCount = (@($targetRows | Where-Object { $_.SourceOutboxState -eq 'target-unresponsive-after-send' })).Count
        ManualAttentionCount = (@($targetRows | Where-Object { $_.SourceOutboxState -eq 'manual-attention-required' })).Count
        SourceOutboxImportedCount = (@($targetRows | Where-Object { $_.SourceOutboxState -in @('imported', 'imported-archive-pending') })).Count
        HandoffReadyCount  = (@($targetRows | Where-Object { $_.SourceOutboxNextAction -eq 'handoff-ready' })).Count
        DispatchRunningCount = (@($targetRows | Where-Object { $_.DispatchState -eq 'running' })).Count
        DispatchFailedCount  = (@($targetRows | Where-Object { $_.DispatchState -eq 'failed' })).Count
        ReadyToForwardCount = (@($targetRows | Where-Object { $_.LatestState -eq 'ready-to-forward' })).Count
        ForwardedCount      = (@($targetRows | Where-Object { $_.LatestState -eq 'forwarded' })).Count
        SummaryMissingCount = (@($targetRows | Where-Object { $_.LatestState -eq 'summary-missing' })).Count
        SummaryStaleCount   = (@($targetRows | Where-Object { $_.LatestState -eq 'summary-stale' })).Count
        DoneStaleCount      = (@($targetRows | Where-Object { $_.LatestState -eq 'done-stale' })).Count
        NoZipCount          = (@($targetRows | Where-Object { $_.LatestState -eq 'no-zip' })).Count
        FailureLineCount    = (@($handoffFailureLines)).Count
        ForwardedStateCount = (@($forwardedState.Keys)).Count
    }
    SourceOutbox = [pscustomobject]@{
        Exists      = [bool]$sourceOutboxStatusDoc.Exists
        ParseError  = [string]$sourceOutboxStatusDoc.ParseError
        LastWriteAt = [string]$sourceOutboxStatusDoc.LastWriteAt
    }
    SeedSend = [pscustomobject]@{
        Exists      = [bool]$seedSendStatusDoc.Exists
        ParseError  = [string]$seedSendStatusDoc.ParseError
        LastWriteAt = [string]$seedSendStatusDoc.LastWriteAt
    }
    HeadlessDispatch = [pscustomobject]@{
        Root            = $headlessDispatchState.Root
        StatusFileCount = [int]$headlessDispatchState.FileCount
        CurrentFileCount = [int]$headlessDispatchState.FileCount
        ParseErrorCount = [int]$headlessDispatchState.ParseErrorCount
        RunningCount    = (@($targetRows | Where-Object { $_.DispatchState -eq 'running' })).Count
        FailedCount     = (@($targetRows | Where-Object { $_.DispatchState -eq 'failed' })).Count
        CompletedCount  = (@($targetRows | Where-Object { $_.DispatchState -eq 'completed' })).Count
    }
    AcceptanceReceipt = [pscustomobject]@{
        Exists      = [bool]$acceptanceReceiptDoc.Exists
        ParseError  = [string]$acceptanceReceiptDoc.ParseError
        LastWriteAt = [string]$acceptanceReceiptDoc.LastWriteAt
        Path        = $acceptanceReceiptPath
        GeneratedAt = if ($null -ne $acceptanceReceipt) { [string](Get-ConfigValue -Object $acceptanceReceipt -Name 'GeneratedAt' -DefaultValue '') } else { '' }
        AcceptanceState = if ($null -ne $acceptanceReceipt) { [string](Get-ConfigValue -Object (Get-ConfigValue -Object $acceptanceReceipt -Name 'Outcome' -DefaultValue $null) -Name 'AcceptanceState' -DefaultValue '') } else { '' }
        AcceptanceReason = if ($null -ne $acceptanceReceipt) { [string](Get-ConfigValue -Object (Get-ConfigValue -Object $acceptanceReceipt -Name 'Outcome' -DefaultValue $null) -Name 'AcceptanceReason' -DefaultValue '') } else { '' }
    }
    PairState = [pscustomobject]@{
        Exists      = [bool]$pairStateDoc.Exists
        ParseError  = [string]$pairStateDoc.ParseError
        LastWriteAt = [string]$pairStateDoc.LastWriteAt
        Path        = $pairStatePath
        SchemaVersion = [string]$pairStateDoc.SchemaVersion
        DeclaredSchemaVersion = [string]$pairStateDoc.DeclaredSchemaVersion
        SchemaStatus = [string]$pairStateDoc.SchemaStatus
        WarningCount = (@($pairStateDoc.Warnings)).Count
        Warnings    = @($pairStateDoc.Warnings)
    }
    Forwarded = [pscustomobject]@{
        Exists      = [bool]$forwardedStateDoc.Exists
        ParseError  = [string]$forwardedStateDoc.ParseError
        LastWriteAt = [string]$forwardedStateDoc.LastWriteAt
    }
    RecentFailures = @($handoffFailureLines | Select-Object -Last $RecentFailureCount)
    Pairs = @($pairRows)
    Targets = @($targetRows)
}

if ($AsJson) {
    $status | ConvertTo-Json -Depth 8
    return
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('Paired Exchange Status')
$lines.Add(('RunRoot: {0}' -f $status.RunRoot))
$lines.Add(('Manifest: created={0} pairs={1} targets={2}' -f $status.Manifest.CreatedAt, $status.Manifest.PairCount, $status.Manifest.TargetCount))
$lines.Add(('PairTest: summary={0} reviewFolder={1} messageFolder={2} zipPattern={3} request={4} done={5} error={6} seedTimeoutSec={7} seedRetryMax={8} seedBackoffMs={9}' -f $status.PairTest.SummaryFileName, $status.PairTest.ReviewFolderName, $status.PairTest.MessageFolderName, $status.PairTest.ReviewZipPattern, $status.PairTest.RequestFileName, $status.PairTest.DoneFileName, $status.PairTest.ErrorFileName, $status.PairTest.SeedOutboxStartTimeoutSeconds, $status.PairTest.SeedRetryMaxAttempts, ((@($status.PairTest.SeedRetryBackoffMs) -join ','))))
$lines.Add(('Watcher: status={0} mutex={1} statusFileState={2} statusUpdatedAt={3} reason={4} stopCategory={5} forwarded={6}/{7} runLimitSec={8} roundtripLimit={9} controlAction={10} lastHandledRequestId={11} lastHandledResult={12}' -f `
    $status.Watcher.Status,
    $status.Watcher.MutexName,
    $status.Watcher.StatusFileState,
    $status.Watcher.StatusFileUpdatedAt,
    $status.Watcher.StatusReason,
    $status.Watcher.StopCategory,
    $status.Watcher.ForwardedCount,
    $status.Watcher.ConfiguredMaxForwardCount,
    $status.Watcher.ConfiguredRunDurationSec,
    $status.Watcher.ConfiguredMaxRoundtripCount,
    $status.Watcher.ControlPendingAction,
    $status.Watcher.LastHandledRequestId,
    $status.Watcher.LastHandledResult))
$lines.Add(('HeadlessDispatch: statusFiles={0} running={1} failed={2} completed={3} parseErrors={4}' -f `
    $status.HeadlessDispatch.StatusFileCount,
    $status.HeadlessDispatch.RunningCount,
    $status.HeadlessDispatch.FailedCount,
    $status.HeadlessDispatch.CompletedCount,
    $status.HeadlessDispatch.ParseErrorCount))
$lines.Add(('AcceptanceReceipt: exists={0} state={1} reason={2} updatedAt={3}' -f `
    $status.AcceptanceReceipt.Exists,
    $status.AcceptanceReceipt.AcceptanceState,
    $status.AcceptanceReceipt.AcceptanceReason,
    $status.AcceptanceReceipt.LastWriteAt))
$lines.Add(('Counts: messages={0} summaries={1} done={2} errors={3} supersededErrors={4} zipTargets={5} outboxWaiting={6} seedProcessed={7} seedRetryPending={8} submitUnconfirmed={9} publishStarted={10} unresponsive={11} manualAttention={12} imported={13} handoffReady={14} dispatchRunning={15} dispatchFailed={16} ready={17} forwarded={18} missingSummary={19} staleSummary={20} doneStale={21} noZip={22} failures={23}' -f `
    $status.Counts.MessageFiles,
    $status.Counts.SummaryPresentCount,
    $status.Counts.DonePresentCount,
    $status.Counts.ErrorPresentCount,
    $status.Counts.ErrorSupersededCount,
    $status.Counts.ZipPresentCount,
    $status.Counts.SourceOutboxWaitingCount,
    $status.Counts.SeedSendProcessedCount,
    $status.Counts.SeedRetryPendingCount,
    $status.Counts.SubmitUnconfirmedCount,
    $status.Counts.PublishStartedCount,
    $status.Counts.TargetUnresponsiveCount,
    $status.Counts.ManualAttentionCount,
    $status.Counts.SourceOutboxImportedCount,
    $status.Counts.HandoffReadyCount,
    $status.Counts.DispatchRunningCount,
    $status.Counts.DispatchFailedCount,
    $status.Counts.ReadyToForwardCount,
    $status.Counts.ForwardedCount,
    $status.Counts.SummaryMissingCount,
    $status.Counts.SummaryStaleCount,
    $status.Counts.DoneStaleCount,
    $status.Counts.NoZipCount,
    $status.Counts.FailureLineCount))

if (Test-NonEmptyString $status.Manifest.ParseError) {
    $lines.Add(('Manifest ParseError: {0}' -f $status.Manifest.ParseError))
}

if (Test-NonEmptyString $status.Forwarded.ParseError) {
    $lines.Add(('Forwarded ParseError: {0}' -f $status.Forwarded.ParseError))
}

if (Test-NonEmptyString $status.PairState.ParseError) {
    $lines.Add(('PairState ParseError: {0}' -f $status.PairState.ParseError))
}
if (Test-NonEmptyString $status.PairState.SchemaStatus) {
    $lines.Add(('PairState Schema: {0} ({1})' -f $status.PairState.SchemaVersion, $status.PairState.SchemaStatus))
}
foreach ($warning in @($status.PairState.Warnings)) {
    if (Test-NonEmptyString $warning) {
        $lines.Add(('PairState Warning: {0}' -f $warning))
    }
}

$lines.Add('')
$lines.Add('Pairs')
if ((@($status.Pairs)).Count -eq 0) {
    $lines.Add('- (none)')
}
else {
    $pairTable = ($status.Pairs |
        Select-Object PairId, Targets,
            @{ Name = 'Phase'; Expression = { $_.CurrentPhase } },
            RoundtripCount, ForwardedStateCount, HandoffReadyCount,
            @{ Name = 'Latest'; Expression = { $_.LatestStateSummary } },
            @{ Name = 'NextHandoff'; Expression = { $_.NextExpectedHandoff } },
            @{ Name = 'NextAction'; Expression = { $_.NextAction } },
            FailureCount |
        Format-Table -AutoSize | Out-String).TrimEnd()
    $lines.Add($pairTable)
}

$lines.Add('')
$lines.Add('Targets')
$targetTable = ($status.Targets |
    Select-Object PairId, TargetId, RoleName, PartnerTargetId, ZipCount, LatestState,
        @{ Name = 'OutboxState'; Expression = { $_.SourceOutboxState } },
        @{ Name = 'NextAction'; Expression = { $_.SourceOutboxNextAction } },
        @{ Name = 'Dispatch'; Expression = { $_.DispatchState } },
        @{ Name = 'SeedState'; Expression = { $_.SeedSendState } },
        @{ Name = 'Submit'; Expression = { $_.SubmitState } },
        SeedAttemptCount, FailureCount |
    Format-Table -AutoSize | Out-String).TrimEnd()
$lines.Add($targetTable)

$lines.Add('')
$lines.Add('Recent Failures')
if ((@($status.RecentFailures)).Count -eq 0) {
    $lines.Add('- (none)')
}
else {
    foreach ($line in $status.RecentFailures) {
        $lines.Add(('- {0}' -f $line))
    }
}

$lines
