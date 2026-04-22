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
if (-not (Test-NonEmptyString $watcherStopCategory)) {
    $watcherStopCategory = Get-WatcherStopCategoryDisplay -Reason $watcherStatusReason
}
$watcherControlPendingAction = [string](Get-ConfigValue -Object $watcherControlData -Name 'Action' -DefaultValue '')
$watcherControlPendingRequestId = [string](Get-ConfigValue -Object $watcherControlData -Name 'RequestId' -DefaultValue '')
$watcherControlAgeSeconds = Get-AgeSeconds -IsoTimestamp $watcherControlRequestedAt
$watcherStatusAgeSeconds = Get-AgeSeconds -IsoTimestamp $watcherStatusUpdatedAt
$watcherHeartbeatAgeSeconds = Get-AgeSeconds -IsoTimestamp $watcherHeartbeatAt
$watcherEffectiveStatus = if ($watcherRunning) {
    if ($watcherStatusFileState -in @('running', 'stop_requested', 'stopping')) {
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
        SourceOutboxState = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'State' -DefaultValue '')
        SourceOutboxReason = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'Reason' -DefaultValue '')
        SourceOutboxContractLatestState = $sourceOutboxContractLatestState
        SourceOutboxNextAction = $sourceOutboxNextAction
        SourceOutboxUpdatedAt = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'UpdatedAt' -DefaultValue '')
        SourceOutboxLastActivityAt = [string](Get-ConfigValue -Object $sourceOutboxRow -Name 'SourceOutboxLastActivityAt' -DefaultValue '')
        DispatchState     = [string](Get-ConfigValue -Object $dispatchData -Name 'State' -DefaultValue '')
        DispatchReason    = [string](Get-ConfigValue -Object $dispatchData -Name 'Reason' -DefaultValue '')
        DispatchStartedAt = [string](Get-ConfigValue -Object $dispatchData -Name 'StartedAt' -DefaultValue '')
        DispatchCompletedAt = [string](Get-ConfigValue -Object $dispatchData -Name 'CompletedAt' -DefaultValue '')
        DispatchExitCode  = [string](Get-ConfigValue -Object $dispatchData -Name 'ExitCode' -DefaultValue '')
        DispatchUpdatedAt = [string](Get-ConfigValue -Object $dispatchRow -Name 'UpdatedAt' -DefaultValue '')
        SeedSendState     = [string](Get-ConfigValue -Object $seedSendRow -Name 'FinalState' -DefaultValue '')
        SeedProcessedAt   = [string](Get-ConfigValue -Object $seedSendRow -Name 'ProcessedAt' -DefaultValue '')
        SeedFirstAttemptedAt = [string](Get-ConfigValue -Object $seedSendRow -Name 'FirstAttemptedAt' -DefaultValue '')
        SeedLastAttemptedAt = [string](Get-ConfigValue -Object $seedSendRow -Name 'LastAttemptedAt' -DefaultValue '')
        SeedAttemptCount  = [int](Get-ConfigValue -Object $seedSendRow -Name 'AttemptCount' -DefaultValue 0)
        SeedMaxAttempts   = [int](Get-ConfigValue -Object $seedSendRow -Name 'MaxAttempts' -DefaultValue 0)
        SeedNextRetryAt   = [string](Get-ConfigValue -Object $seedSendRow -Name 'NextRetryAt' -DefaultValue '')
        SeedBackoffMs     = [int](Get-ConfigValue -Object $seedSendRow -Name 'BackoffMs' -DefaultValue 0)
        SeedRetryReason   = [string](Get-ConfigValue -Object $seedSendRow -Name 'RetryReason' -DefaultValue '')
        ManualAttentionRequired = [bool](Get-ConfigValue -Object $seedSendRow -Name 'ManualAttentionRequired' -DefaultValue $false)
        SubmitState       = [string](Get-ConfigValue -Object $seedSendRow -Name 'SubmitState' -DefaultValue '')
        SubmitConfirmed   = [bool](Get-ConfigValue -Object $seedSendRow -Name 'SubmitConfirmed' -DefaultValue $false)
        SubmitReason      = [string](Get-ConfigValue -Object $seedSendRow -Name 'SubmitReason' -DefaultValue '')
        ForwardedAt       = $latestForwardedAt
        FailureCount      = $targetFailureCount
        TargetFolder      = $targetFolder
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
    Forwarded = [pscustomobject]@{
        Exists      = [bool]$forwardedStateDoc.Exists
        ParseError  = [string]$forwardedStateDoc.ParseError
        LastWriteAt = [string]$forwardedStateDoc.LastWriteAt
    }
    RecentFailures = @($handoffFailureLines | Select-Object -Last $RecentFailureCount)
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
$lines.Add(('Watcher: status={0} mutex={1} statusFileState={2} statusUpdatedAt={3} reason={4} stopCategory={5} forwarded={6}/{7} controlAction={8} lastHandledRequestId={9} lastHandledResult={10}' -f `
    $status.Watcher.Status,
    $status.Watcher.MutexName,
    $status.Watcher.StatusFileState,
    $status.Watcher.StatusFileUpdatedAt,
    $status.Watcher.StatusReason,
    $status.Watcher.StopCategory,
    $status.Watcher.ForwardedCount,
    $status.Watcher.ConfiguredMaxForwardCount,
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
