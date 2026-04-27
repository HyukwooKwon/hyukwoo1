[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [string]$PairId,
    [string]$SeedTargetId,
    [string]$SeedWorkRepoRoot,
    [string]$SeedReviewInputPath,
    [string]$SeedTaskText,
    [int]$WatcherPollIntervalMs = 1500,
    [int]$WatcherRunDurationSec = 900,
    [int]$WatcherMaxForwardCount = 0,
    [int]$WatcherPairMaxRoundtripCount = 0,
    [int]$WaitForRouterSeconds = 20,
    [int]$WaitForWatcherSeconds = 20,
    [int]$WaitForFirstHandoffSeconds = 180,
    [int]$WaitForRoundtripSeconds = 180,
    [int]$SeedWaitForPublishSeconds = 180,
    [switch]$ReuseExistingRunRoot,
    [switch]$ForceFreshRouter,
    [switch]$KeepWatcherRunning,
    [switch]$PreflightOnly,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NonEmptyString {
    param([object]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Get-WindowLaunchEvidence {
    param([Parameter(Mandatory)]$Config)

    $windowLaunch = if ($Config.ContainsKey('WindowLaunch')) { $Config.WindowLaunch } else { @{} }
    $launcherWrapperPath = if ($Config.ContainsKey('LauncherWrapperPath')) { [string]$Config.LauncherWrapperPath } else { '' }
    $launchMode = if ($windowLaunch.ContainsKey('LauncherMode')) { [string]$windowLaunch.LauncherMode } elseif (Test-NonEmptyString $launcherWrapperPath) { 'wrapper' } else { '' }
    $reuseMode = if ($windowLaunch.ContainsKey('ReuseMode')) { [string]$windowLaunch.ReuseMode } elseif (Test-NonEmptyString $launcherWrapperPath) { 'attach-only' } else { '' }

    return [pscustomobject]@{
        LaunchMode             = $launchMode
        ReuseMode              = $reuseMode
        WrapperPath            = $launcherWrapperPath
        NonStandardWindowBlock = (Test-NonEmptyString $launcherWrapperPath)
    }
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

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)][string]$PathValue,
        [Parameter(Mandatory)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Get-PairDefinition {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$PairId
    )

    return (Get-PairDefinitionById -PairTest $PairTest -PairId $PairId)
}

function ConvertTo-CommandArgumentList {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath
    )

    foreach ($entry in $Parameters.GetEnumerator()) {
        $parameterName = '-' + [string]$entry.Key
        $value = $entry.Value

        if ($value -is [switch]) {
            if ($value.IsPresent) {
                $argumentList += $parameterName
            }
            continue
        }

        if ($value -is [bool]) {
            if ($value) {
                $argumentList += $parameterName
            }
            continue
        }

        if ($value -is [System.Array]) {
            $argumentList += $parameterName
            foreach ($item in $value) {
                $argumentList += [string]$item
            }
            continue
        }

        $argumentList += $parameterName
        $argumentList += [string]$value
    }

    return @($argumentList)
}

function Invoke-ScriptAndCaptureOutput {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $powershellPath = Resolve-PowerShellExecutable
    $argumentList = ConvertTo-CommandArgumentList -ScriptPath $ScriptPath -Parameters $Parameters
    $scriptOutput = @()
    foreach ($line in @(& $powershellPath @argumentList 2>&1)) {
        $scriptOutput += [string]$line
    }

    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = ($scriptOutput -join [Environment]::NewLine)
        throw "스크립트 실행 실패 exitCode=$exitCode file=$ScriptPath output=$detail"
    }

    return @($scriptOutput)
}

function Invoke-JsonRelayScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $scriptOutput = Invoke-ScriptAndCaptureOutput -ScriptPath $ScriptPath -Parameters $Parameters
    $raw = ($scriptOutput | Out-String).Trim()
    if (-not (Test-NonEmptyString $raw)) {
        throw ("script returned no json output: " + $ScriptPath)
    }

    return (ConvertFrom-RelayJsonText -Json $raw)
}

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return (ConvertFrom-RelayJsonText -Json $raw)
}

function Get-RunContractEvidence {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$SeedTargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId
    )

    $manifestPath = Join-Path $RunRoot 'manifest.json'
    $manifest = Read-JsonObject -Path $manifestPath
    if ($null -eq $manifest) {
        return [pscustomobject]@{
            ExternalWorkRepoUsed = $false
            PrimaryContractExternalized = $false
            ExternalRunRootUsed = $false
            BookkeepingExternalized = $false
            FullExternalized = $false
            ExternalContractPathsValidated = $false
            RunRootPathValidated = $false
            InternalResidualRoots = @()
            ContractTargets = @()
        }
    }

    $targetIds = @($SeedTargetId, $PartnerTargetId) | Where-Object { Test-NonEmptyString $_ } | Select-Object -Unique
    $contractTargets = @(
        foreach ($targetId in $targetIds) {
            $row = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq [string]$targetId } | Select-Object -First 1)
            if (@($row).Count -eq 0) {
                continue
            }

            [pscustomobject]@{
                TargetId = [string]$row[0].TargetId
                WorkRepoRoot = [string](Get-ResultPropertyValue -Object $row[0] -Name 'WorkRepoRoot' -DefaultValue '')
                ContractPathMode = [string](Get-ResultPropertyValue -Object $row[0] -Name 'ContractPathMode' -DefaultValue '')
                ContractRootPath = [string](Get-ResultPropertyValue -Object $row[0] -Name 'ContractRootPath' -DefaultValue '')
                ContractReferenceTimeUtc = [string](Get-ResultPropertyValue -Object $row[0] -Name 'ContractReferenceTimeUtc' -DefaultValue '')
                SourceOutboxPath = [string](Get-ResultPropertyValue -Object $row[0] -Name 'SourceOutboxPath' -DefaultValue '')
                SourceSummaryPath = [string](Get-ResultPropertyValue -Object $row[0] -Name 'SourceSummaryPath' -DefaultValue '')
                SourceReviewZipPath = [string](Get-ResultPropertyValue -Object $row[0] -Name 'SourceReviewZipPath' -DefaultValue '')
                PublishReadyPath = [string](Get-ResultPropertyValue -Object $row[0] -Name 'PublishReadyPath' -DefaultValue '')
            }
        }
    )

    return [pscustomobject]@{
        ExternalWorkRepoUsed = [bool](Get-ResultPropertyValue -Object $manifest -Name 'ExternalWorkRepoUsed' -DefaultValue $false)
        PrimaryContractExternalized = [bool](Get-ResultPropertyValue -Object $manifest -Name 'PrimaryContractExternalized' -DefaultValue $false)
        ExternalRunRootUsed = [bool](Get-ResultPropertyValue -Object $manifest -Name 'ExternalRunRootUsed' -DefaultValue $false)
        BookkeepingExternalized = [bool](Get-ResultPropertyValue -Object $manifest -Name 'BookkeepingExternalized' -DefaultValue $false)
        FullExternalized = [bool](Get-ResultPropertyValue -Object $manifest -Name 'FullExternalized' -DefaultValue $false)
        ExternalContractPathsValidated = [bool](Get-ResultPropertyValue -Object $manifest -Name 'ExternalContractPathsValidated' -DefaultValue $false)
        RunRootPathValidated = [bool](Get-ResultPropertyValue -Object $manifest -Name 'RunRootPathValidated' -DefaultValue $false)
        InternalResidualRoots = @((Get-ResultPropertyValue -Object $manifest -Name 'InternalResidualRoots' -DefaultValue @()))
        ContractTargets = @($contractTargets)
    }
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

function Get-TargetReadyFileCount {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TargetId
    )

    $target = @($Config.Targets | Where-Object { [string]$_.Id -eq $TargetId } | Select-Object -First 1)
    if (@($target).Length -eq 0) {
        throw "target relay config not found: $TargetId"
    }

    $folder = [string]$target[0].Folder
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        return 0
    }

    return @(
        Get-ChildItem -LiteralPath $folder -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue
    ).Length
}

function Get-TargetRow {
    param(
        $Status,
        [Parameter(Mandatory)][string]$TargetId
    )

    return @($Status.Targets | Where-Object { [string]$_.TargetId -eq $TargetId } | Select-Object -First 1)
}

function New-AcceptanceTargetDiagnostics {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$TargetId
    )

    return [pscustomobject]@{
        TargetId                = $TargetId
        LatestState             = [string]$Row.LatestState
        SourceOutboxState       = [string]$Row.SourceOutboxState
        SourceOutboxReason      = [string]$Row.SourceOutboxReason
        SourceOutboxContractLatestState = [string]$Row.SourceOutboxContractLatestState
        SourceOutboxNextAction  = [string]$Row.SourceOutboxNextAction
        SourceOutboxUpdatedAt   = [string]$Row.SourceOutboxUpdatedAt
        SourceOutboxLastActivityAt = [string]$Row.SourceOutboxLastActivityAt
        DispatchState           = [string]$Row.DispatchState
        DispatchUpdatedAt       = [string]$Row.DispatchUpdatedAt
        DispatchHeartbeatAt     = [string]$Row.DispatchHeartbeatAt
        DispatchElapsedSeconds  = [int]$Row.DispatchElapsedSeconds
        DispatchStdOutBytes     = [int64]$Row.DispatchStdOutBytes
        DispatchStdErrBytes     = [int64]$Row.DispatchStdErrBytes
        SeedSendState           = [string]$Row.SeedSendState
        SubmitState             = [string]$Row.SubmitState
        SubmitReason            = [string]$Row.SubmitReason
        SubmitProbeState        = [string](Get-ResultPropertyValue -Object $Row -Name 'SubmitProbeState' -DefaultValue '')
        SubmitProbeElapsedSeconds = [int](Get-ResultPropertyValue -Object $Row -Name 'SubmitProbeElapsedSeconds' -DefaultValue 0)
        SubmitRetryCount        = [int](Get-ResultPropertyValue -Object $Row -Name 'SubmitRetryCount' -DefaultValue 0)
        SubmitConfirmationSignal = [string](Get-ResultPropertyValue -Object $Row -Name 'SubmitConfirmationSignal' -DefaultValue '')
        TypedWindowExecutionState = [string](Get-ResultPropertyValue -Object $Row -Name 'TypedWindowExecutionState' -DefaultValue '')
        TypedWindowSessionState = [string](Get-ResultPropertyValue -Object $Row -Name 'TypedWindowSessionState' -DefaultValue '')
        TypedWindowLastResetReason = [string](Get-ResultPropertyValue -Object $Row -Name 'TypedWindowLastResetReason' -DefaultValue '')
        SeedProcessedAt         = [string]$Row.SeedProcessedAt
        SeedFirstAttemptedAt    = [string]$Row.SeedFirstAttemptedAt
        SeedLastAttemptedAt     = [string]$Row.SeedLastAttemptedAt
        SeedAttemptCount        = [int]$Row.SeedAttemptCount
        SeedMaxAttempts         = [int]$Row.SeedMaxAttempts
        SeedNextRetryAt         = [string]$Row.SeedNextRetryAt
        SeedBackoffMs           = [int]$Row.SeedBackoffMs
        SeedRetryReason         = [string]$Row.SeedRetryReason
        ManualAttentionRequired = [bool]$Row.ManualAttentionRequired
        ExecutionPathMode       = [string]$Row.ExecutionPathMode
        UserVisibleCellExecutionRequired = [bool]$Row.UserVisibleCellExecutionRequired
        AllowedWindowVisibilityMethods = @($Row.AllowedWindowVisibilityMethods)
        SeedSubmitRetryModes    = @($Row.SeedSubmitRetryModes)
        SeedSubmitRetrySequenceSummary = [string]$Row.SeedSubmitRetrySequenceSummary
        SeedPrimarySubmitMode   = [string]$Row.SeedPrimarySubmitMode
        SeedFinalSubmitMode     = [string]$Row.SeedFinalSubmitMode
        SeedSubmitRetryIntervalMs = [int]$Row.SeedSubmitRetryIntervalMs
    }
}

function Test-VisibleWorkerLateSeedSuccess {
    param(
        [Parameter(Mandatory)]$Row
    )

    if ([bool](Get-ResultPropertyValue -Object $Row -Name 'SeedSendSuperseded' -DefaultValue $false)) {
        return $true
    }

    return (Test-PairedSourceOutboxStrictReadyRow -Row $Row)
}

function Resolve-LateVisibleWorkerSeedResult {
    param(
        [Parameter(Mandatory)]$SeedResult,
        $Row = $null
    )

    if ($null -eq $Row) {
        return $SeedResult
    }

    if (-not (Test-VisibleWorkerLateSeedSuccess -Row $Row)) {
        return $SeedResult
    }

    Add-Member -InputObject $SeedResult -NotePropertyName 'FinalState' -NotePropertyValue 'publish-detected-late' -Force
    Add-Member -InputObject $SeedResult -NotePropertyName 'SubmitState' -NotePropertyValue 'confirmed' -Force
    Add-Member -InputObject $SeedResult -NotePropertyName 'SubmitConfirmed' -NotePropertyValue $true -Force
    Add-Member -InputObject $SeedResult -NotePropertyName 'SubmitReason' -NotePropertyValue 'outbox-publish-detected-late' -Force
    Add-Member -InputObject $SeedResult -NotePropertyName 'OutboxPublished' -NotePropertyValue $true -Force
    Add-Member -InputObject $SeedResult -NotePropertyName 'TypedWindowExecutionState' -NotePropertyValue 'typed-window-running-confirmed' -Force
    Add-Member -InputObject $SeedResult -NotePropertyName 'SubmitProbeState' -NotePropertyValue 'typed-window-running-confirmed' -Force
    Add-Member -InputObject $SeedResult -NotePropertyName 'SubmitConfirmationSignal' -NotePropertyValue 'outbox-publish-ready' -Force

    return $SeedResult
}

function Get-ResultPropertyValue {
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

function Test-VisibleWorkerTargetProgress {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]$PairTest
    )

    $latestState = [string]$Row.LatestState
    $sourceOutboxState = [string]$Row.SourceOutboxState
    $contractLatestState = [string]$Row.SourceOutboxContractLatestState
    $nextAction = [string]$Row.SourceOutboxNextAction
    $dispatchState = [string]$Row.DispatchState
    $dispatchAcceptedStaleSeconds = [math]::Max(5, [int](Get-ConfigValue -Object $PairTest.VisibleWorker -Name 'DispatchAcceptedStaleSeconds' -DefaultValue 15))
    $dispatchRunningStaleSeconds = [math]::Max($dispatchAcceptedStaleSeconds, [int](Get-ConfigValue -Object $PairTest.VisibleWorker -Name 'DispatchRunningStaleSeconds' -DefaultValue 30))

    if ($latestState -eq 'forwarded') {
        return $true
    }

    if ($sourceOutboxState -in @('publish-started', 'seed-send-processed', 'imported', 'imported-archive-pending', 'duplicate-marker-archived')) {
        return $true
    }

    if (Test-NonEmptyString $contractLatestState -or Test-NonEmptyString $nextAction) {
        return $true
    }

    $dispatchAgeSeconds = Get-IsoTimestampAgeSeconds -IsoTimestamp ([string]$Row.DispatchHeartbeatAt)
    if ($dispatchAgeSeconds -lt 0) {
        $dispatchAgeSeconds = Get-IsoTimestampAgeSeconds -IsoTimestamp ([string]$Row.DispatchUpdatedAt)
    }

    if ($dispatchState -eq 'accepted') {
        return ($dispatchAgeSeconds -ge 0 -and $dispatchAgeSeconds -le $dispatchAcceptedStaleSeconds)
    }

    if ($dispatchState -eq 'running') {
        return ($dispatchAgeSeconds -ge 0 -and $dispatchAgeSeconds -le $dispatchRunningStaleSeconds)
    }

    return $false
}

function Invoke-ShowPairedStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot
    )

    $powershellPath = Resolve-PowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'tests\Show-PairedExchangeStatus.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $RunRoot,
        '-AsJson'
    )
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-paired-exchange-status failed: " + (($result | Out-String).Trim()))
    }
    return (ConvertFrom-RelayJsonText -Json (($result | Out-String).Trim()))
}

function Invoke-ShowRelayStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath
    )

    $powershellPath = Resolve-PowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'show-relay-status.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-AsJson'
    )
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-relay-status failed: " + (($result | Out-String).Trim()))
    }
    return (ConvertFrom-RelayJsonText -Json (($result | Out-String).Trim()))
}

function Invoke-WindowVisibilityStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath
    )

    $powershellPath = Resolve-PowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'launcher\Check-TargetWindowVisibility.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-AsJson'
    )
    $output = @(& $powershellPath @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $rawText = (($output | Out-String).Trim())
    $status = $null
    $parseError = ''
    if (Test-NonEmptyString $rawText) {
        try {
            $status = ConvertFrom-RelayJsonText -Json $rawText
        }
        catch {
            $parseError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        ExitCode   = $exitCode
        RawText    = $rawText
        ParseError = $parseError
        Status     = $status
    }
}

function Get-TypedWindowPreflightReport {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)]$PairTest
    )

    $visibility = Invoke-WindowVisibilityStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath
    $officialWindowReport = Get-OfficialVisibleWindowReuseReport -Root $Root -Config $Config
    $allowedMethods = @(
        Get-ConfigValue -Object $PairTest -Name 'AllowedWindowVisibilityMethods' -DefaultValue @('hwnd')
    )
    $allowedMethods = @($allowedMethods | ForEach-Object { [string]$_ } | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)
    if ($allowedMethods.Count -eq 0) {
        $allowedMethods = @('hwnd')
    }

    $targets = @()
    if ($null -ne $visibility.Status -and $null -ne $visibility.Status.Targets) {
        $targets = @($visibility.Status.Targets)
    }

    $badRows = @()
    foreach ($row in $targets) {
        $method = [string](Get-ResultPropertyValue -Object $row -Name 'InjectionMethod' -DefaultValue '')
        $injectable = [bool](Get-ResultPropertyValue -Object $row -Name 'Injectable' -DefaultValue $false)
        if (-not $injectable -or $method -notin $allowedMethods) {
            $badRows += $row
        }
    }

    $uniqueHwndCount = @(
        $targets |
            ForEach-Object { [string](Get-ResultPropertyValue -Object $_ -Name 'RuntimeHwnd' -DefaultValue '') } |
            Where-Object { Test-NonEmptyString $_ } |
            Sort-Object -Unique
    ).Count
    $windowPidOnlyFallbackDetected = (@($targets | Where-Object { [string](Get-ResultPropertyValue -Object $_ -Name 'InjectionMethod' -DefaultValue '') -eq 'windowPid' }).Count -gt 0)
    $passed = ($visibility.ExitCode -eq 0 -and -not (Test-NonEmptyString $visibility.ParseError) -and $badRows.Count -eq 0 -and [bool]$officialWindowReport.Passed)
    $blockedBy = ''
    $blockedTargetId = ''
    $blockedDetail = ''
    if (Test-NonEmptyString $visibility.ParseError) {
        $blockedBy = 'window-visibility-parse-error'
        $blockedDetail = [string]$visibility.ParseError
    }
    elseif ($visibility.ExitCode -ne 0 -and $badRows.Count -eq 0) {
        $blockedBy = 'window-visibility-check-failed'
        $blockedDetail = 'check-target-window-visibility returned non-zero exit code.'
    }
    elseif ($badRows.Count -gt 0) {
        $firstBadRow = @($badRows | Select-Object -First 1)
        $blockedBy = 'window-visibility-method-not-allowed'
        $blockedTargetId = [string](Get-ResultPropertyValue -Object $firstBadRow[0] -Name 'TargetId' -DefaultValue '')
        $blockedDetail = ('allowedMethods={0} actualMethod={1} injectable={2}' -f ($allowedMethods -join ','), [string](Get-ResultPropertyValue -Object $firstBadRow[0] -Name 'InjectionMethod' -DefaultValue ''), [bool](Get-ResultPropertyValue -Object $firstBadRow[0] -Name 'Injectable' -DefaultValue $false))
    }
    elseif (-not [bool]$officialWindowReport.Passed) {
        $blockedBy = 'nonstandard-visible-window-present'
        $blockedDetail = 'shared visible lane must reuse wrapper-launched official cells only.'
    }

    return [pscustomobject]@{
        Passed                        = $passed
        Visibility                    = $visibility.Status
        AllowedMethods                = @($allowedMethods)
        UniqueHwndCount               = [int]$uniqueHwndCount
        WindowPidOnlyFallbackDetected = [bool]$windowPidOnlyFallbackDetected
        OfficialWindowReport          = $officialWindowReport
        Targets                       = @($targets)
        BlockedBy                     = $blockedBy
        BlockedTargetId               = $blockedTargetId
        BlockedDetail                 = $blockedDetail
        SummaryLines                  = @(
            ('WindowVisibilityOk={0}' -f $passed),
            ('VisibilityPassMode={0}' -f $(if ($passed) { ($allowedMethods -join ',') } else { '' })),
            ('UniqueHwndCount={0}' -f $uniqueHwndCount),
            ('WindowPidOnlyFallbackDetected={0}' -f $windowPidOnlyFallbackDetected)
        ) + @($officialWindowReport.SummaryLines)
    }
}

function Get-VisibleWorkerStatusPath {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetId
    )

    return (Join-Path (Join-Path ([string]$PairTest.VisibleWorker.StatusRoot) 'workers') ("worker_{0}.json" -f $TargetId))
}

function Get-VisibleWorkerSnapshot {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string[]]$TargetIds
    )

    if (-not [bool]$PairTest.VisibleWorker.Enabled) {
        return [pscustomobject]@{
            Enabled = $false
            Targets = @()
        }
    }

    $targets = foreach ($targetId in @($TargetIds | Where-Object { Test-NonEmptyString $_ } | Sort-Object -Unique)) {
        $queueRoot = Join-Path ([string]$PairTest.VisibleWorker.QueueRoot) $targetId
        $queuedRoot = Join-Path $queueRoot 'queued'
        $processingRoot = Join-Path $queueRoot 'processing'
        $completedRoot = Join-Path $queueRoot 'completed'
        $failedRoot = Join-Path $queueRoot 'failed'
        $statusPath = Get-VisibleWorkerStatusPath -PairTest $PairTest -TargetId $targetId
        $statusDoc = $null
        if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            $statusDoc = Read-JsonObject -Path $statusPath
        }

        [pscustomobject]@{
            TargetId            = $targetId
            StatusPath          = $statusPath
            State               = if ($null -ne $statusDoc) { [string]$statusDoc.State } else { '' }
            WorkerPid           = if ($null -ne $statusDoc -and $null -ne $statusDoc.WorkerPid) { [int]$statusDoc.WorkerPid } else { 0 }
            WorkerAlive         = if ($null -ne $statusDoc -and $null -ne $statusDoc.WorkerPid) { [bool](Test-ProcessAlive -ProcessId ([int]$statusDoc.WorkerPid)) } else { $false }
            CurrentCommandId    = if ($null -ne $statusDoc) { [string]$statusDoc.CurrentCommandId } else { '' }
            CurrentRunRoot      = if ($null -ne $statusDoc) { [string]$statusDoc.CurrentRunRoot } else { '' }
            CurrentPromptFilePath = if ($null -ne $statusDoc) { [string]$statusDoc.CurrentPromptFilePath } else { '' }
            Reason              = if ($null -ne $statusDoc) { [string]$statusDoc.Reason } else { '' }
            LastCommandId       = if ($null -ne $statusDoc) { [string]$statusDoc.LastCommandId } else { '' }
            LastCompletedAt     = if ($null -ne $statusDoc) { [string]$statusDoc.LastCompletedAt } else { '' }
            LastFailedAt        = if ($null -ne $statusDoc) { [string]$statusDoc.LastFailedAt } else { '' }
            HeartbeatAt         = if ($null -ne $statusDoc) { [string](Get-ConfigValue -Object $statusDoc -Name 'HeartbeatAt' -DefaultValue '') } else { '' }
            HeartbeatAgeSeconds = if ($null -ne $statusDoc) {
                $heartbeatAge = Get-IsoTimestampAgeSeconds -IsoTimestamp ([string](Get-ConfigValue -Object $statusDoc -Name 'HeartbeatAt' -DefaultValue ''))
                if ($heartbeatAge -ge 0) { $heartbeatAge } else { Get-IsoTimestampAgeSeconds -IsoTimestamp ([string]$statusDoc.UpdatedAt) }
            } else { -1 }
            UpdatedAt           = if ($null -ne $statusDoc) { [string]$statusDoc.UpdatedAt } else { '' }
            StdOutLogPath       = if ($null -ne $statusDoc) { [string]$statusDoc.StdOutLogPath } else { '' }
            StdErrLogPath       = if ($null -ne $statusDoc) { [string]$statusDoc.StdErrLogPath } else { '' }
            QueuedCount         = if (Test-Path -LiteralPath $queuedRoot -PathType Container) { @(Get-ChildItem -LiteralPath $queuedRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count } else { 0 }
            ProcessingCount     = if (Test-Path -LiteralPath $processingRoot -PathType Container) { @(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count } else { 0 }
            CompletedCount      = if (Test-Path -LiteralPath $completedRoot -PathType Container) { @(Get-ChildItem -LiteralPath $completedRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count } else { 0 }
            FailedCount         = if (Test-Path -LiteralPath $failedRoot -PathType Container) { @(Get-ChildItem -LiteralPath $failedRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count } else { 0 }
        }
    }

    return [pscustomobject]@{
        Enabled    = $true
        QueueRoot  = [string]$PairTest.VisibleWorker.QueueRoot
        StatusRoot = [string]$PairTest.VisibleWorker.StatusRoot
        LogRoot    = [string]$PairTest.VisibleWorker.LogRoot
        Targets    = @($targets)
    }
}

function Get-VisibleWorkerCommandEntries {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$TargetId
    )

    $queueRoot = Join-Path ([string]$PairTest.VisibleWorker.QueueRoot) $TargetId
    $entries = New-Object System.Collections.Generic.List[object]

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
            $command = $null
            $parseError = ''
            try {
                $command = Read-JsonObject -Path $file.FullName
            }
            catch {
                $parseError = $_.Exception.Message
            }

            $entries.Add([pscustomobject]@{
                TargetId   = $TargetId
                Bucket     = $bucket
                Path       = $file.FullName
                Name       = $file.Name
                RunRoot    = if ($null -ne $command) { [string]$command.RunRoot } else { '' }
                CommandId  = if ($null -ne $command) { [string]$command.CommandId } else { '' }
                CreatedAt  = if ($null -ne $command) { [string]$command.CreatedAt } else { '' }
                ParseError = $parseError
            })
        }
    }

    return [object[]]$entries.ToArray()
}

function Get-VisibleWorkerExpectedForwardCount {
    param(
        [Parameter(Mandatory)][int]$ConfiguredMaxForwardCount,
        [Parameter(Mandatory)][int]$WaitForRoundtripSeconds
    )

    if ($WaitForRoundtripSeconds -gt 0) {
        return 2
    }

    return 1
}

function Get-VisibleWorkerCloseoutForwardCount {
    param(
        [Parameter(Mandatory)][int]$ConfiguredMaxForwardCount,
        [Parameter(Mandatory)][int]$WaitForRoundtripSeconds
    )

    if ($ConfiguredMaxForwardCount -gt 0) {
        return [math]::Max(1, $ConfiguredMaxForwardCount)
    }

    return (Get-VisibleWorkerExpectedForwardCount -ConfiguredMaxForwardCount $ConfiguredMaxForwardCount -WaitForRoundtripSeconds $WaitForRoundtripSeconds)
}

function Get-VisibleWorkerWatcherDurationPlan {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][int]$RequestedRunDurationSec,
        [Parameter(Mandatory)][int]$SeedWaitForPublishSeconds,
        [Parameter(Mandatory)][int]$WaitForFirstHandoffSeconds,
        [Parameter(Mandatory)][int]$WaitForRoundtripSeconds,
        [Parameter(Mandatory)][int]$ConfiguredMaxForwardCount
    )

    $acceptanceForwardCount = Get-VisibleWorkerExpectedForwardCount `
        -ConfiguredMaxForwardCount $ConfiguredMaxForwardCount `
        -WaitForRoundtripSeconds $WaitForRoundtripSeconds
    $expectedForwardCount = Get-VisibleWorkerCloseoutForwardCount `
        -ConfiguredMaxForwardCount $ConfiguredMaxForwardCount `
        -WaitForRoundtripSeconds $WaitForRoundtripSeconds
    $perTurnTimeoutSeconds = [math]::Max(60, [int]$PairTest.VisibleWorker.CommandTimeoutSeconds)
    $turnBudgetSeconds = ($perTurnTimeoutSeconds * $expectedForwardCount) + 120
    $acceptanceBudgetSeconds = [math]::Max(60, $SeedWaitForPublishSeconds) + [math]::Max(60, $WaitForFirstHandoffSeconds)
    if ($WaitForRoundtripSeconds -gt 0) {
        $acceptanceBudgetSeconds += [math]::Max(60, $WaitForRoundtripSeconds)
    }
    $acceptanceBudgetSeconds += 120

    $recommendedMinRunDurationSec = [math]::Max($turnBudgetSeconds, $acceptanceBudgetSeconds)
    $effectiveRunDurationSec = if ($RequestedRunDurationSec -gt 0) {
        [math]::Max($RequestedRunDurationSec, $recommendedMinRunDurationSec)
    }
    else {
        $recommendedMinRunDurationSec
    }

    return [pscustomobject]@{
        AcceptanceForwardedStateCount = $acceptanceForwardCount
        CloseoutForwardedStateCount   = $expectedForwardCount
        ExpectedForwardedStateCount   = $expectedForwardCount
        PerTurnTimeoutSeconds         = $perTurnTimeoutSeconds
        TurnBudgetSeconds             = $turnBudgetSeconds
        AcceptanceBudgetSeconds       = $acceptanceBudgetSeconds
        RecommendedMinRunDurationSec  = $recommendedMinRunDurationSec
        RequestedRunDurationSec       = $RequestedRunDurationSec
        EffectiveRunDurationSec       = $effectiveRunDurationSec
        RequestedDurationAdjusted     = ($effectiveRunDurationSec -ne $RequestedRunDurationSec)
    }
}

function Get-CloseoutStatus {
    param(
        $Status = $null,
        [Parameter(Mandatory)][int]$AcceptanceForwardedStateCount,
        [Parameter(Mandatory)][int]$CloseoutForwardedStateCount,
        [int]$ExpectedDonePresentCount = 2
    )

    $counts = if ($null -ne $Status -and $null -ne $Status.Counts) { $Status.Counts } else { $null }
    $observedForwardedStateCount = if ($null -ne $counts -and $null -ne $counts.ForwardedStateCount) { [int]$counts.ForwardedStateCount } else { 0 }
    $observedDonePresentCount = if ($null -ne $counts -and $null -ne $counts.DonePresentCount) { [int]$counts.DonePresentCount } else { 0 }
    $observedErrorPresentCount = if ($null -ne $counts -and $null -ne $counts.ErrorPresentCount) { [int]$counts.ErrorPresentCount } else { 0 }
    $requested = ($CloseoutForwardedStateCount -gt $AcceptanceForwardedStateCount)
    $satisfied = ($observedForwardedStateCount -ge $CloseoutForwardedStateCount) -and ($observedDonePresentCount -ge $ExpectedDonePresentCount) -and ($observedErrorPresentCount -eq 0)

    return [pscustomobject]@{
        Requested                     = $requested
        AcceptanceForwardedStateCount = $AcceptanceForwardedStateCount
        TargetForwardedStateCount     = $CloseoutForwardedStateCount
        ExpectedDonePresentCount      = $ExpectedDonePresentCount
        ObservedForwardedStateCount   = $observedForwardedStateCount
        ObservedDonePresentCount      = $observedDonePresentCount
        ObservedErrorPresentCount     = $observedErrorPresentCount
        Satisfied                     = $satisfied
        Status                        = if (-not $requested) { 'not-requested' } elseif ($satisfied) { 'satisfied' } else { 'pending' }
    }
}

function Get-CloseoutWaitBudgetSeconds {
    param(
        [Parameter(Mandatory)][int]$AcceptanceForwardedStateCount,
        [Parameter(Mandatory)][int]$CloseoutForwardedStateCount,
        [Parameter(Mandatory)][int]$WaitForRoundtripSeconds
    )

    if ($CloseoutForwardedStateCount -le $AcceptanceForwardedStateCount) {
        return 0
    }

    $extraForwardCount = [math]::Max(0, ($CloseoutForwardedStateCount - $AcceptanceForwardedStateCount))
    $extraRoundtripCount = [math]::Max(1, [int][math]::Ceiling($extraForwardCount / 2.0))
    return ($extraRoundtripCount * [math]::Max(60, $WaitForRoundtripSeconds)) + 120
}

function Wait-ForAcceptanceCloseout {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][int]$AcceptanceForwardedStateCount,
        [Parameter(Mandatory)][int]$CloseoutForwardedStateCount,
        [Parameter(Mandatory)][int]$WaitForRoundtripSeconds
    )

    $initialCloseout = Get-CloseoutStatus `
        -Status $null `
        -AcceptanceForwardedStateCount $AcceptanceForwardedStateCount `
        -CloseoutForwardedStateCount $CloseoutForwardedStateCount
    if (-not [bool]$initialCloseout.Requested) {
        return [pscustomobject]@{
            Requested        = $false
            Satisfied        = $true
            WatcherStopped   = $false
            Closeout         = $initialCloseout
            Status           = $null
            CompletedAt      = ''
            FailureReason    = ''
            TimeoutSeconds   = 0
        }
    }

    $timeoutSeconds = Get-CloseoutWaitBudgetSeconds `
        -AcceptanceForwardedStateCount $AcceptanceForwardedStateCount `
        -CloseoutForwardedStateCount $CloseoutForwardedStateCount `
        -WaitForRoundtripSeconds $WaitForRoundtripSeconds
    $deadline = (Get-Date).AddSeconds([math]::Max(5, $timeoutSeconds))
    $lastStatus = $null
    $lastCloseout = $initialCloseout

    while ((Get-Date) -lt $deadline) {
        $lastStatus = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        $lastCloseout = Get-CloseoutStatus `
            -Status $lastStatus `
            -AcceptanceForwardedStateCount $AcceptanceForwardedStateCount `
            -CloseoutForwardedStateCount $CloseoutForwardedStateCount
        $watcherStopped = ($null -ne $lastStatus -and $null -ne $lastStatus.Watcher -and [string]$lastStatus.Watcher.Status -eq 'stopped')
        if ([bool]$lastCloseout.Satisfied -and $watcherStopped) {
            return [pscustomobject]@{
                Requested      = $true
                Satisfied      = $true
                WatcherStopped = $true
                Closeout       = $lastCloseout
                Status         = $lastStatus
                CompletedAt    = (Get-Date).ToString('o')
                FailureReason  = ''
                TimeoutSeconds = $timeoutSeconds
            }
        }

        if ($null -ne $lastCloseout -and [int]$lastCloseout.ObservedErrorPresentCount -gt 0) {
            return [pscustomobject]@{
                Requested      = $true
                Satisfied      = $false
                WatcherStopped = $watcherStopped
                Closeout       = $lastCloseout
                Status         = $lastStatus
                CompletedAt    = ''
                FailureReason  = 'closeout-error-present'
                TimeoutSeconds = $timeoutSeconds
            }
        }

        Start-Sleep -Milliseconds 1000
    }

    $watcherStopped = ($null -ne $lastStatus -and $null -ne $lastStatus.Watcher -and [string]$lastStatus.Watcher.Status -eq 'stopped')
    return [pscustomobject]@{
        Requested      = $true
        Satisfied      = $false
        WatcherStopped = $watcherStopped
        Closeout       = $lastCloseout
        Status         = $lastStatus
        CompletedAt    = ''
        FailureReason  = if ($watcherStopped) { 'closeout-counts-incomplete' } else { 'closeout-timeout-before-watcher-stop' }
        TimeoutSeconds = $timeoutSeconds
    }
}

function Get-VisibleWorkerPreflightReport {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string[]]$TargetIds,
        [Parameter(Mandatory)][string]$CurrentRunRoot,
        $WatcherStatus = $null,
        [switch]$AllowActiveWatcherForCurrentRun
    )

    $snapshot = Get-VisibleWorkerSnapshot -PairTest $PairTest -TargetIds $TargetIds
    $normalizedCurrentRunRoot = [System.IO.Path]::GetFullPath($CurrentRunRoot)
    $workerReadyFreshnessSeconds = [math]::Max(5, [int](Get-ConfigValue -Object $PairTest.VisibleWorker -Name 'WorkerReadyFreshnessSeconds' -DefaultValue 30))
    $targetReports = foreach ($target in @($snapshot.Targets)) {
        $commands = @(Get-VisibleWorkerCommandEntries -PairTest $PairTest -TargetId ([string]$target.TargetId))
        $parseErrorEntry = @($commands | Where-Object { Test-NonEmptyString ([string]$_.ParseError) } | Select-Object -First 1)
        $foreignCommands = @(
            $commands |
                Where-Object {
                    Test-NonEmptyString ([string]$_.RunRoot) -and
                    ([System.IO.Path]::GetFullPath([string]$_.RunRoot) -ne $normalizedCurrentRunRoot)
                }
        )
        $foreignQueuedEntry = @($foreignCommands | Where-Object { [string]$_.Bucket -eq 'queued' } | Select-Object -First 1)
        $foreignProcessingEntry = @($foreignCommands | Where-Object { [string]$_.Bucket -eq 'processing' } | Select-Object -First 1)
        $firstQueuedEntry = @($commands | Where-Object { [string]$_.Bucket -eq 'queued' } | Select-Object -First 1)
        $firstProcessingEntry = @($commands | Where-Object { [string]$_.Bucket -eq 'processing' } | Select-Object -First 1)
        $parseErrorCount = @($commands | Where-Object { Test-NonEmptyString ([string]$_.ParseError) }).Count
        $queuedForeignCount = @($foreignCommands | Where-Object { [string]$_.Bucket -eq 'queued' }).Count
        $processingForeignCount = @($foreignCommands | Where-Object { [string]$_.Bucket -eq 'processing' }).Count
        $foreignActiveCurrentRun = [bool]$target.WorkerAlive -and [string]$target.State -in @('running', 'waiting-for-dispatch-slot', 'accepted', 'paused') -and (Test-NonEmptyString ([string]$target.CurrentRunRoot)) -and ([System.IO.Path]::GetFullPath([string]$target.CurrentRunRoot) -ne $normalizedCurrentRunRoot)

        [pscustomobject]@{
            TargetId                = [string]$target.TargetId
            IdleOk                  = ([string]$target.State -notin @('running', 'waiting-for-dispatch-slot', 'accepted', 'paused')) -and ([int]$target.QueuedCount -eq 0) -and ([int]$target.ProcessingCount -eq 0)
            QueueEmptyOk            = ([int]$target.QueuedCount -eq 0)
            ProcessingEmptyOk       = ([int]$target.ProcessingCount -eq 0)
            WorkerAlive             = [bool]$target.WorkerAlive
            WorkerHeartbeatAt       = [string]$target.HeartbeatAt
            WorkerHeartbeatAgeSeconds = [int]$target.HeartbeatAgeSeconds
            WorkerReadyOk           = [bool]$target.WorkerAlive -and ([string]$target.State -eq 'idle') -and ([int]$target.QueuedCount -eq 0) -and ([int]$target.ProcessingCount -eq 0) -and ([int]$target.HeartbeatAgeSeconds -ge 0) -and ([int]$target.HeartbeatAgeSeconds -le $workerReadyFreshnessSeconds)
            State                   = [string]$target.State
            CurrentRunRoot          = [string]$target.CurrentRunRoot
            QueuedCount             = [int]$target.QueuedCount
            ProcessingCount         = [int]$target.ProcessingCount
            FailedCount             = [int]$target.FailedCount
            ParseErrorCount         = $parseErrorCount
            FirstParseErrorPath     = if (@($parseErrorEntry).Count -gt 0) { [string]$parseErrorEntry[0].Path } else { '' }
            FirstParseErrorDetail   = if (@($parseErrorEntry).Count -gt 0) { [string]$parseErrorEntry[0].ParseError } else { '' }
            ForeignQueuedCount      = $queuedForeignCount
            ForeignProcessingCount  = $processingForeignCount
            ForeignActiveCurrentRun = $foreignActiveCurrentRun
            ForeignRunRoots         = @($foreignCommands | ForEach-Object { [string]$_.RunRoot } | Sort-Object -Unique)
            FirstForeignQueuedPath      = if (@($foreignQueuedEntry).Count -gt 0) { [string]$foreignQueuedEntry[0].Path } else { '' }
            FirstForeignQueuedCommandId = if (@($foreignQueuedEntry).Count -gt 0) { [string]$foreignQueuedEntry[0].CommandId } else { '' }
            FirstForeignQueuedRunRoot   = if (@($foreignQueuedEntry).Count -gt 0) { [string]$foreignQueuedEntry[0].RunRoot } else { '' }
            FirstForeignProcessingPath      = if (@($foreignProcessingEntry).Count -gt 0) { [string]$foreignProcessingEntry[0].Path } else { '' }
            FirstForeignProcessingCommandId = if (@($foreignProcessingEntry).Count -gt 0) { [string]$foreignProcessingEntry[0].CommandId } else { '' }
            FirstForeignProcessingRunRoot   = if (@($foreignProcessingEntry).Count -gt 0) { [string]$foreignProcessingEntry[0].RunRoot } else { '' }
            FirstQueuedPath           = if (@($firstQueuedEntry).Count -gt 0) { [string]$firstQueuedEntry[0].Path } else { '' }
            FirstQueuedCommandId      = if (@($firstQueuedEntry).Count -gt 0) { [string]$firstQueuedEntry[0].CommandId } else { '' }
            FirstQueuedRunRoot        = if (@($firstQueuedEntry).Count -gt 0) { [string]$firstQueuedEntry[0].RunRoot } else { '' }
            FirstProcessingPath       = if (@($firstProcessingEntry).Count -gt 0) { [string]$firstProcessingEntry[0].Path } else { '' }
            FirstProcessingCommandId  = if (@($firstProcessingEntry).Count -gt 0) { [string]$firstProcessingEntry[0].CommandId } else { '' }
            FirstProcessingRunRoot    = if (@($firstProcessingEntry).Count -gt 0) { [string]$firstProcessingEntry[0].RunRoot } else { '' }
        }
    }

    $watcherState = if ($null -ne $WatcherStatus) { [string]$WatcherStatus.Status } else { '' }
    $watcherReason = if ($null -ne $WatcherStatus) { [string]$WatcherStatus.StatusReason } else { '' }
    $watcherNotRunningOrSameRunOk = if (-not (Test-NonEmptyString $watcherState) -or $watcherState -eq 'stopped') {
        $true
    }
    elseif ($AllowActiveWatcherForCurrentRun) {
        $watcherState -in @('running', 'stop_requested', 'stopping')
    }
    else {
        $false
    }

    $visibleWorkerIdleOk = (@($targetReports | Where-Object { -not [bool]$_.IdleOk }).Count -eq 0)
    $visibleWorkerQueueEmptyOk = (@($targetReports | Where-Object { -not [bool]$_.QueueEmptyOk }).Count -eq 0)
    $visibleWorkerProcessingEmptyOk = (@($targetReports | Where-Object { -not [bool]$_.ProcessingEmptyOk }).Count -eq 0)
    $visibleWorkerReadyOk = (@($targetReports | Where-Object { -not [bool]$_.WorkerReadyOk }).Count -eq 0)
    $visibleWorkerForeignRunCleanOk = (@($targetReports | Where-Object { [int]$_.ForeignQueuedCount -gt 0 -or [int]$_.ForeignProcessingCount -gt 0 -or [bool]$_.ForeignActiveCurrentRun }).Count -eq 0)
    $visibleWorkerMetadataCleanOk = (@($targetReports | Where-Object { [int]$_.ParseErrorCount -gt 0 }).Count -eq 0)
    $blockedBy = ''
    $blockedTargetId = ''
    $blockedCommandId = ''
    $blockedRunRoot = ''
    $blockedPath = ''
    $blockedDetail = ''

    if (-not $visibleWorkerMetadataCleanOk) {
        $blockedTarget = @($targetReports | Where-Object { [int]$_.ParseErrorCount -gt 0 } | Select-Object -First 1)
        if (@($blockedTarget).Count -gt 0) {
            $blockedBy = 'metadata-parse-error'
            $blockedTargetId = [string]$blockedTarget[0].TargetId
            $blockedPath = [string]$blockedTarget[0].FirstParseErrorPath
            $blockedDetail = [string]$blockedTarget[0].FirstParseErrorDetail
        }
    }
    elseif (-not $visibleWorkerForeignRunCleanOk) {
        $blockedTarget = @($targetReports | Where-Object { [int]$_.ForeignQueuedCount -gt 0 -or [int]$_.ForeignProcessingCount -gt 0 -or [bool]$_.ForeignActiveCurrentRun } | Select-Object -First 1)
        if (@($blockedTarget).Count -gt 0) {
            $blockedTargetId = [string]$blockedTarget[0].TargetId
            if ([int]$blockedTarget[0].ForeignQueuedCount -gt 0) {
                $blockedBy = 'foreign-queued-command'
                $blockedCommandId = [string]$blockedTarget[0].FirstForeignQueuedCommandId
                $blockedRunRoot = [string]$blockedTarget[0].FirstForeignQueuedRunRoot
                $blockedPath = [string]$blockedTarget[0].FirstForeignQueuedPath
                $blockedDetail = 'foreign queued command must be cleaned before active acceptance'
            }
            elseif ([int]$blockedTarget[0].ForeignProcessingCount -gt 0) {
                $blockedBy = 'foreign-processing-command'
                $blockedCommandId = [string]$blockedTarget[0].FirstForeignProcessingCommandId
                $blockedRunRoot = [string]$blockedTarget[0].FirstForeignProcessingRunRoot
                $blockedPath = [string]$blockedTarget[0].FirstForeignProcessingPath
                $blockedDetail = 'foreign processing command must be reclaimed before active acceptance'
            }
            else {
                $blockedBy = 'foreign-active-worker-run'
                $blockedRunRoot = [string]$blockedTarget[0].CurrentRunRoot
                $blockedDetail = 'worker is still active for a different run root'
            }
        }
    }
    elseif (-not $visibleWorkerQueueEmptyOk) {
        $blockedTarget = @($targetReports | Where-Object { -not [bool]$_.QueueEmptyOk } | Select-Object -First 1)
        if (@($blockedTarget).Count -gt 0) {
            $blockedBy = 'visible-worker-queue-not-empty'
            $blockedTargetId = [string]$blockedTarget[0].TargetId
            $blockedCommandId = [string]$blockedTarget[0].FirstQueuedCommandId
            $blockedRunRoot = [string]$blockedTarget[0].FirstQueuedRunRoot
            $blockedPath = [string]$blockedTarget[0].FirstQueuedPath
            $blockedDetail = 'queued commands remain for target before acceptance start'
        }
    }
    elseif (-not $visibleWorkerProcessingEmptyOk) {
        $blockedTarget = @($targetReports | Where-Object { -not [bool]$_.ProcessingEmptyOk } | Select-Object -First 1)
        if (@($blockedTarget).Count -gt 0) {
            $blockedBy = 'visible-worker-processing-not-empty'
            $blockedTargetId = [string]$blockedTarget[0].TargetId
            $blockedCommandId = [string]$blockedTarget[0].FirstProcessingCommandId
            $blockedRunRoot = [string]$blockedTarget[0].FirstProcessingRunRoot
            $blockedPath = [string]$blockedTarget[0].FirstProcessingPath
            $blockedDetail = 'processing commands remain for target before acceptance start'
        }
    }
    elseif (-not $visibleWorkerIdleOk) {
        $blockedTarget = @($targetReports | Where-Object { -not [bool]$_.IdleOk } | Select-Object -First 1)
        if (@($blockedTarget).Count -gt 0) {
            $blockedBy = 'visible-worker-not-idle'
            $blockedTargetId = [string]$blockedTarget[0].TargetId
            $blockedRunRoot = [string]$blockedTarget[0].CurrentRunRoot
            $blockedDetail = ('worker state is not idle: state=' + [string]$blockedTarget[0].State)
        }
    }
    elseif (-not $visibleWorkerReadyOk) {
        $blockedTarget = @($targetReports | Where-Object { -not [bool]$_.WorkerReadyOk } | Select-Object -First 1)
        if (@($blockedTarget).Count -gt 0) {
            $blockedBy = 'visible-worker-not-ready'
            $blockedTargetId = [string]$blockedTarget[0].TargetId
            $blockedRunRoot = [string]$blockedTarget[0].CurrentRunRoot
            $blockedDetail = ('worker not ready: alive=' + [string][bool]$blockedTarget[0].WorkerAlive + '; state=' + [string]$blockedTarget[0].State + '; heartbeatAgeSeconds=' + [int]$blockedTarget[0].WorkerHeartbeatAgeSeconds)
        }
    }
    elseif (-not $watcherNotRunningOrSameRunOk) {
        $blockedBy = 'watcher-not-stopped-or-same-run'
        $blockedDetail = ('watcherState=' + $watcherState + '; watcherReason=' + $watcherReason)
    }

    $summaryLines = @(
        ('VisibleWorkerIdleOk={0}' -f $visibleWorkerIdleOk),
        ('VisibleWorkerQueueEmptyOk={0}' -f $visibleWorkerQueueEmptyOk),
        ('VisibleWorkerProcessingEmptyOk={0}' -f $visibleWorkerProcessingEmptyOk),
        ('VisibleWorkerReadyOk={0}' -f $visibleWorkerReadyOk),
        ('VisibleWorkerForeignRunCleanOk={0}' -f $visibleWorkerForeignRunCleanOk),
        ('VisibleWorkerMetadataCleanOk={0}' -f $visibleWorkerMetadataCleanOk),
        ('WatcherNotRunningOrSameRunOk={0}' -f $watcherNotRunningOrSameRunOk)
    )
    foreach ($target in @($targetReports)) {
        $summaryLines += ('{0}: state={1} workerAlive={2} readyOk={3} heartbeatAgeSeconds={4} queued={5} processing={6} foreignQueued={7} foreignProcessing={8} foreignActive={9}' -f `
            [string]$target.TargetId,
            [string]$target.State,
            [bool]$target.WorkerAlive,
            [bool]$target.WorkerReadyOk,
            [int]$target.WorkerHeartbeatAgeSeconds,
            [int]$target.QueuedCount,
            [int]$target.ProcessingCount,
            [int]$target.ForeignQueuedCount,
            [int]$target.ForeignProcessingCount,
            [bool]$target.ForeignActiveCurrentRun)
    }

    return [pscustomobject]@{
        Passed                          = ($visibleWorkerIdleOk -and $visibleWorkerQueueEmptyOk -and $visibleWorkerProcessingEmptyOk -and $visibleWorkerReadyOk -and $visibleWorkerForeignRunCleanOk -and $visibleWorkerMetadataCleanOk -and $watcherNotRunningOrSameRunOk)
        VisibleWorker                   = $snapshot
        VisibleWorkerIdleOk             = $visibleWorkerIdleOk
        VisibleWorkerQueueEmptyOk       = $visibleWorkerQueueEmptyOk
        VisibleWorkerProcessingEmptyOk  = $visibleWorkerProcessingEmptyOk
        VisibleWorkerReadyOk            = $visibleWorkerReadyOk
        VisibleWorkerForeignRunCleanOk  = $visibleWorkerForeignRunCleanOk
        VisibleWorkerMetadataCleanOk    = $visibleWorkerMetadataCleanOk
        WatcherNotRunningOrSameRunOk    = $watcherNotRunningOrSameRunOk
        WatcherState                    = $watcherState
        WatcherReason                   = $watcherReason
        BlockedBy                       = $blockedBy
        BlockedTargetId                 = $blockedTargetId
        BlockedCommandId                = $blockedCommandId
        BlockedRunRoot                  = $blockedRunRoot
        BlockedPath                     = $blockedPath
        BlockedDetail                   = $blockedDetail
        Targets                         = @($targetReports)
        SummaryLines                    = @($summaryLines)
    }
}

function Test-IsOfficialSharedVisibleLane {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Config
    )

    $laneName = ''
    if ($Config -is [hashtable]) {
        if ($Config.ContainsKey('LaneName')) {
            $laneName = [string]$Config['LaneName']
        }
    }
    else {
        $laneNameProperty = $Config.PSObject.Properties['LaneName']
        if ($null -ne $laneNameProperty) {
            $laneName = [string]$laneNameProperty.Value
        }
    }
    if ($laneName -eq 'bottest-live-visible') {
        return $true
    }

    $runtimeRoot = ''
    if ($Config -is [hashtable]) {
        if ($Config.ContainsKey('RuntimeRoot')) {
            $runtimeRoot = [string]$Config['RuntimeRoot']
        }
    }
    else {
        $runtimeRootProperty = $Config.PSObject.Properties['RuntimeRoot']
        if ($null -ne $runtimeRootProperty) {
            $runtimeRoot = [string]$runtimeRootProperty.Value
        }
    }
    if (-not (Test-NonEmptyString $runtimeRoot)) {
        return $false
    }

    $officialRuntimeRoot = [System.IO.Path]::GetFullPath((Join-Path $Root 'runtime\bottest-live-visible'))
    return ([System.IO.Path]::GetFullPath($runtimeRoot) -eq $officialRuntimeRoot)
}

function Get-OfficialVisibleWindowReuseReport {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Config
    )

    if (-not (Test-IsOfficialSharedVisibleLane -Root $Root -Config $Config)) {
        return [pscustomobject]@{
            Passed             = $true
            VisibleWindowCount = 0
            NonStandardCount   = 0
            NonStandardWindows = @()
            SummaryLines       = @('OfficialWindowReuseOk=True (non-shared-or-isolated-lane)')
        }
    }

    $allowedPrefixes = @()
    foreach ($target in @($Config.Targets)) {
        $prefix = [string]$target.WindowTitle
        if (Test-NonEmptyString $prefix) {
            $allowedPrefixes += $prefix
        }
    }
    $allowedPrefixes = @($allowedPrefixes | Sort-Object -Unique)

    $visibleWindows = @()
    foreach ($window in @(Get-VisibleWindows)) {
        if ($null -eq $window) {
            continue
        }

        $title = [string]$window.Title
        if (-not (Test-NonEmptyString $title)) {
            continue
        }

        if ($title -notmatch '^(?i:BotTestLive-)') {
            continue
        }

        $visibleWindows += [pscustomobject]@{
            Hwnd      = $window.Hwnd
            ProcessId = $window.ProcessId
            Title     = $title
            ClassName = [string]$window.ClassName
        }
    }

    $nonStandardWindows = @()
    foreach ($window in @($visibleWindows)) {
        $title = [string]$window.Title
        $matched = $false
        foreach ($prefix in @($allowedPrefixes)) {
            if ($title -like (([string]$prefix) + '*')) {
                $matched = $true
                break
            }
        }

        if (-not $matched) {
            $nonStandardWindows += $window
        }
    }

    return [pscustomobject]@{
        Passed             = (@($nonStandardWindows).Count -eq 0)
        VisibleWindowCount = @($visibleWindows).Count
        NonStandardCount   = @($nonStandardWindows).Count
        NonStandardWindows = @($nonStandardWindows)
        SummaryLines       = @(
            ('OfficialWindowReuseOk={0}' -f (@($nonStandardWindows).Count -eq 0)),
            ('VisibleBotTestWindowCount={0}' -f @($visibleWindows).Count),
            ('NonStandardVisibleWindowCount={0}' -f @($nonStandardWindows).Count)
        )
    }
}

function Start-VisibleWorkerForTarget {
    param(
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$TargetId
    )

    $powershellPath = Resolve-PowerShellExecutable
    $workerScriptPath = Join-Path $Root 'visible\Start-VisibleTargetWorker.ps1'
    $bootstrapLogRoot = Join-Path ([string]$PairTest.VisibleWorker.LogRoot) 'acceptance-bootstrap'
    if (-not (Test-Path -LiteralPath $bootstrapLogRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $bootstrapLogRoot -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $stdoutLogPath = Join-Path $bootstrapLogRoot ("worker_{0}_{1}.stdout.log" -f $TargetId, $timestamp)
    $stderrLogPath = Join-Path $bootstrapLogRoot ("worker_{0}_{1}.stderr.log" -f $TargetId, $timestamp)
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $workerScriptPath,
        '-ConfigPath', $ResolvedConfigPath,
        '-TargetId', $TargetId
    )

    return (Start-Process -FilePath $powershellPath -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath)
}

function Wait-ForVisibleWorkerTargetsReady {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string[]]$TargetIds,
        [int]$TimeoutSeconds = 180,
        [switch]$StartIdleWorkers
    )

    $deadline = (Get-Date).AddSeconds([math]::Max(1, $TimeoutSeconds))
    $restartAttempts = @{}
    $readyFreshnessSeconds = [math]::Max(5, [int](Get-ConfigValue -Object $PairTest.VisibleWorker -Name 'WorkerReadyFreshnessSeconds' -DefaultValue 30))
    while ((Get-Date) -lt $deadline) {
        $snapshot = Get-VisibleWorkerSnapshot -PairTest $PairTest -TargetIds $TargetIds
        $needsRestart = @(
            $snapshot.Targets |
                Where-Object {
                    (
                        (-not [bool]$_.WorkerAlive) -or
                        (-not [bool](Test-NonEmptyString ([string]$_.StatusPath))) -or
                        ([string]$_.State -eq 'stopped')
                    ) -and
                    (
                        $StartIdleWorkers -or
                        ([int]$_.QueuedCount -gt 0) -or
                        ([int]$_.ProcessingCount -gt 0)
                    )
                }
        )

        foreach ($target in $needsRestart) {
            $targetKey = [string]$target.TargetId
            if (-not $restartAttempts.ContainsKey($targetKey)) {
                [void](Start-VisibleWorkerForTarget -PairTest $PairTest -Root $Root -ResolvedConfigPath $ResolvedConfigPath -TargetId $targetKey)
                $restartAttempts[$targetKey] = $true
            }
        }

        if ($needsRestart.Count -gt 0) {
            Start-Sleep -Milliseconds 1500
            continue
        }

        $notReadyTargets = @(
            $snapshot.Targets |
                Where-Object {
                    (-not [bool]$_.WorkerAlive) -or
                    ([string]$_.State -ne 'idle') -or
                    ([int]$_.HeartbeatAgeSeconds -lt 0) -or
                    ([int]$_.HeartbeatAgeSeconds -gt $readyFreshnessSeconds) -or
                    [int]$_.QueuedCount -gt 0 -or
                    [int]$_.ProcessingCount -gt 0
                }
        )

        if ($notReadyTargets.Count -eq 0) {
            return $snapshot
        }

        Start-Sleep -Milliseconds 1000
    }

    $finalSnapshot = Get-VisibleWorkerSnapshot -PairTest $PairTest -TargetIds $TargetIds
    $busySummary = @(
        $finalSnapshot.Targets |
            Where-Object {
                (-not [bool]$_.WorkerAlive) -or
                ([string]$_.State -ne 'idle') -or
                ([int]$_.HeartbeatAgeSeconds -lt 0) -or
                ([int]$_.HeartbeatAgeSeconds -gt $readyFreshnessSeconds) -or
                [int]$_.QueuedCount -gt 0 -or
                [int]$_.ProcessingCount -gt 0
            } |
            ForEach-Object {
                '{0}:state={1},alive={2},heartbeatAgeSeconds={3},queued={4},processing={5},run={6}' -f $_.TargetId, $_.State, $_.WorkerAlive, $_.HeartbeatAgeSeconds, $_.QueuedCount, $_.ProcessingCount, $_.CurrentRunRoot
            }
    ) -join '; '
    throw ("visible worker targets are still busy: " + $busySummary)
}

function Resolve-PreparedRunRootFromOutput {
    param([Parameter(Mandatory)][string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match '^prepared pair test root:\s*(.+)$') {
            return [string]$Matches[1].Trim()
        }
    }

    return ''
}

function Wait-ForRouterReady {
    param(
        [Parameter(Mandatory)][string]$RouterMutexName,
        [Parameter(Mandatory)][string]$RouterStatePath,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Read-JsonObject -Path $RouterStatePath
        $mutexHeld = Test-MutexHeld -Name $RouterMutexName
        if ($mutexHeld) {
            $effectiveStatus = 'running-existing'
            $lastError = ''
            if ($null -ne $state) {
                if (Test-NonEmptyString ([string]$state.Status) -and [string]$state.Status -ne 'failed') {
                    $effectiveStatus = [string]$state.Status
                }
                elseif (Test-NonEmptyString ([string]$state.LastError)) {
                    $lastError = [string]$state.LastError
                }
            }

            return [pscustomobject]@{
                Status = $effectiveStatus
                StateFileStatus = if ($null -ne $state) { [string]$state.Status } else { '' }
                LastError = $lastError
            }
        }

        if ($null -ne $state -and [string]$state.Status -eq 'failed' -and -not $mutexHeld) {
            throw ("router start failed: " + [string]$state.LastError)
        }

        Start-Sleep -Milliseconds 300
    }

    throw "router ready timeout: statePath=$RouterStatePath mutex=$RouterMutexName"
}

function Wait-ForWatcherRunning {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastStatus = $null
    while ((Get-Date) -lt $deadline) {
        $lastStatus = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        if ([string]$lastStatus.Watcher.Status -eq 'running') {
            return $lastStatus
        }
        Start-Sleep -Milliseconds 400
    }

    throw ('watcher running timeout: ' + (($lastStatus | ConvertTo-Json -Depth 6) | Out-String))
}

function Write-WatcherStopRequest {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RequestedBy
    )

    $stateRoot = Join-Path $RunRoot '.state'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }

    $requestId = [guid]::NewGuid().ToString()
    $controlPath = Join-Path $stateRoot 'watcher-control.json'
    [ordered]@{
        SchemaVersion = '1.0.0'
        RequestedAt   = (Get-Date).ToString('o')
        RequestedBy   = $RequestedBy
        Action        = 'stop'
        RunRoot       = $RunRoot
        RequestId     = $requestId
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $controlPath -Encoding UTF8

    return $requestId
}

function Test-WatcherStopSatisfied {
    param(
        $Status,
        [string]$RequestId
    )

    if ($null -eq $Status -or $null -eq $Status.Watcher) {
        return $false
    }

    if ([string]$Status.Watcher.Status -ne 'stopped') {
        return $false
    }

    if (-not (Test-NonEmptyString $RequestId)) {
        return $true
    }

    return (
        [string]$Status.Watcher.LastHandledRequestId -eq $RequestId -and
        [string]$Status.Watcher.LastHandledResult -eq 'stopped'
    )
}

function New-WatcherReceiptSummary {
    param(
        [string]$LaunchMode,
        [string]$StopRequestId,
        [string]$StopError,
        [string]$StdoutLogPath,
        [string]$StderrLogPath,
        $WatcherStatus,
        [bool]$StopReconciled = $false,
        [bool]$StopErrorSuppressed = $false
    )

    $stopSatisfied = Test-WatcherStopSatisfied -Status ([pscustomobject]@{ Watcher = $WatcherStatus }) -RequestId $StopRequestId
    $stopObservedAt = ''
    if ($stopSatisfied) {
        $stopObservedAt = [string](Get-ResultPropertyValue -Object $WatcherStatus -Name 'LastHandledAt' -DefaultValue '')
        if (-not (Test-NonEmptyString $stopObservedAt)) {
            $stopObservedAt = [string](Get-ResultPropertyValue -Object $WatcherStatus -Name 'StatusFileUpdatedAt' -DefaultValue '')
        }
        if (-not (Test-NonEmptyString $stopObservedAt)) {
            $stopObservedAt = [string](Get-ResultPropertyValue -Object $WatcherStatus -Name 'UpdatedAt' -DefaultValue '')
        }
    }

    return [pscustomobject]@{
        LaunchMode           = $LaunchMode
        StopRequestId        = $StopRequestId
        StopError            = $StopError
        StopSatisfied        = $stopSatisfied
        StopObservedAt       = $stopObservedAt
        StopReconciled       = $StopReconciled
        StopErrorSuppressed  = $StopErrorSuppressed
        StdoutLogPath        = $StdoutLogPath
        StderrLogPath        = $StderrLogPath
        Status               = $WatcherStatus
    }
}

function Wait-ForWatcherStopped {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $status = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        if (Test-WatcherStopSatisfied -Status $status -RequestId $RequestId) {
            return $status
        }
        Start-Sleep -Milliseconds 400
    }

    try {
        $status = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        if (Test-WatcherStopSatisfied -Status $status -RequestId $RequestId) {
            return $status
        }
    }
    catch {
    }

    throw "watcher stop timeout: requestId=$RequestId"
}

function Write-AcceptanceReceipt {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)]$Result
    )

    $stateRoot = Join-Path $RunRoot '.state'
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }

    function New-AcceptanceReceiptPhaseEntry {
        param(
            [Parameter(Mandatory)]$CurrentResult,
            [Parameter(Mandatory)][string]$RecordedAt
        )

        $outcome = Get-ResultPropertyValue -Object $CurrentResult -Name 'Outcome' -DefaultValue $null
        $seed = Get-ResultPropertyValue -Object $CurrentResult -Name 'Seed' -DefaultValue $null
        $preflight = Get-ResultPropertyValue -Object $CurrentResult -Name 'Preflight' -DefaultValue $null
        $bootstrap = Get-ResultPropertyValue -Object $CurrentResult -Name 'Bootstrap' -DefaultValue $null

        return [ordered]@{
            RecordedAt          = $RecordedAt
            Stage               = [string](Get-ResultPropertyValue -Object $CurrentResult -Name 'Stage' -DefaultValue '')
            AcceptanceState     = [string](Get-ResultPropertyValue -Object $outcome -Name 'AcceptanceState' -DefaultValue '')
            AcceptanceReason    = [string](Get-ResultPropertyValue -Object $outcome -Name 'AcceptanceReason' -DefaultValue '')
            BlockedBy           = [string](Get-ResultPropertyValue -Object $CurrentResult -Name 'BlockedBy' -DefaultValue '')
            BlockedTargetId     = [string](Get-ResultPropertyValue -Object $CurrentResult -Name 'BlockedTargetId' -DefaultValue '')
            BlockedRunRoot      = [string](Get-ResultPropertyValue -Object $CurrentResult -Name 'BlockedRunRoot' -DefaultValue '')
            BlockedPath         = [string](Get-ResultPropertyValue -Object $CurrentResult -Name 'BlockedPath' -DefaultValue '')
            BlockedDetail       = [string](Get-ResultPropertyValue -Object $CurrentResult -Name 'BlockedDetail' -DefaultValue '')
            PreflightCheckState = [string](Get-ResultPropertyValue -Object $preflight -Name 'CheckState' -DefaultValue '')
            BootstrapPrepareState = [string](Get-ResultPropertyValue -Object $bootstrap -Name 'BootstrapPrepareState' -DefaultValue '')
            BootstrapFailureReason = [string](Get-ResultPropertyValue -Object $bootstrap -Name 'BootstrapFailureReason' -DefaultValue '')
            BootstrapFocusStealDetected = [bool](Get-ResultPropertyValue -Object $bootstrap -Name 'BootstrapFocusStealDetected' -DefaultValue $false)
            BootstrapVisibleBeaconObserved = [bool](Get-ResultPropertyValue -Object $bootstrap -Name 'BootstrapVisibleBeaconObserved' -DefaultValue $false)
            SeedFinalState      = [string](Get-ResultPropertyValue -Object $seed -Name 'FinalState' -DefaultValue '')
            SeedSubmitState     = [string](Get-ResultPropertyValue -Object $seed -Name 'SubmitState' -DefaultValue '')
            SeedOutboxPublished = [bool](Get-ResultPropertyValue -Object $seed -Name 'OutboxPublished' -DefaultValue $false)
        }
    }

    function Get-AcceptanceReceiptPhaseHistory {
        param(
            [string]$ExistingReceiptPath,
            [Parameter(Mandatory)]$CurrentResult,
            [Parameter(Mandatory)][string]$RecordedAt
        )

        $history = New-Object System.Collections.Generic.List[object]
        if (Test-Path -LiteralPath $ExistingReceiptPath -PathType Leaf) {
            try {
                $existing = Read-JsonObject -Path $ExistingReceiptPath
                foreach ($entry in @((Get-ResultPropertyValue -Object $existing -Name 'PhaseHistory' -DefaultValue @()))) {
                    if ($null -ne $entry) {
                        [void]$history.Add($entry)
                    }
                }
            }
            catch {
            }
        }

        $currentEntry = New-AcceptanceReceiptPhaseEntry -CurrentResult $CurrentResult -RecordedAt $RecordedAt
        $shouldAppend = $true
        if ($history.Count -gt 0) {
            $lastEntry = $history[$history.Count - 1]
            $comparisonFields = @(
                'Stage',
                'AcceptanceState',
                'AcceptanceReason',
                'BlockedBy',
                'BlockedTargetId',
                'BlockedRunRoot',
                'BlockedPath',
                'BlockedDetail',
                'PreflightCheckState',
                'BootstrapPrepareState',
                'BootstrapFailureReason',
                'BootstrapFocusStealDetected',
                'BootstrapVisibleBeaconObserved',
                'SeedFinalState',
                'SeedSubmitState',
                'SeedOutboxPublished'
            )
            $shouldAppend = $false
            foreach ($fieldName in $comparisonFields) {
                $lastValue = Get-ResultPropertyValue -Object $lastEntry -Name $fieldName -DefaultValue ''
                $currentValue = Get-ResultPropertyValue -Object $currentEntry -Name $fieldName -DefaultValue ''
                if ([string]$lastValue -ne [string]$currentValue) {
                    $shouldAppend = $true
                    break
                }
            }
        }

        if ($shouldAppend) {
            [void]$history.Add([pscustomobject]$currentEntry)
        }

        return @($history | Select-Object -Last 40)
    }

    $recordedAt = (Get-Date).ToString('o')
    $phaseHistory = Get-AcceptanceReceiptPhaseHistory -ExistingReceiptPath $ReceiptPath -CurrentResult $Result -RecordedAt $recordedAt
    Add-Member -InputObject $Result -NotePropertyName 'LastUpdatedAt' -NotePropertyValue $recordedAt -Force
    Add-Member -InputObject $Result -NotePropertyName 'PhaseHistory' -NotePropertyValue @($phaseHistory) -Force
    $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8
}

function Resolve-TypedWindowBootstrapFailureClass {
    param([Parameter(Mandatory)]$BootstrapResult)

    $visibleFailureReason = [string](Get-ResultPropertyValue -Object $BootstrapResult -Name 'VisibleFailureReason' -DefaultValue '')
    if (Test-NonEmptyString $visibleFailureReason) {
        return $visibleFailureReason
    }

    $lastResetReason = [string](Get-ResultPropertyValue -Object $BootstrapResult -Name 'TypedWindowLastResetReason' -DefaultValue '')
    switch ($lastResetReason) {
        'focus-steal-before-submit' { return 'visible-bootstrap-focus-steal' }
        'target-not-foreground' { return 'visible-bootstrap-target-not-foreground' }
    }

    $finalState = [string](Get-ResultPropertyValue -Object $BootstrapResult -Name 'FinalState' -DefaultValue '')
    switch ($finalState) {
        'manual_attention_required' { return 'visible-bootstrap-submit-unconfirmed' }
        'failed' { return 'visible-bootstrap-prepare-failed' }
        default { return 'visible-bootstrap-failed' }
    }
}

function New-TypedWindowBootstrapSummary {
    param([object[]]$BootstrapResults)

    $allResults = @($BootstrapResults)
    $completedAt = ''
    foreach ($entry in $allResults) {
        $candidateCompletedAt = [string](Get-ResultPropertyValue -Object $entry -Name 'CompletedAt' -DefaultValue '')
        if (Test-NonEmptyString $candidateCompletedAt) {
            $completedAt = $candidateCompletedAt
        }
    }

    $preparedTargets = @(
        $allResults |
            Where-Object {
                [string](Get-ResultPropertyValue -Object $_ -Name 'FinalState' -DefaultValue '') -in @('prepared', 'reused')
            } |
            ForEach-Object { [string](Get-ResultPropertyValue -Object $_ -Name 'TargetId' -DefaultValue '') } |
            Where-Object { Test-NonEmptyString $_ }
    )
    $failedResults = @(
        $allResults | Where-Object {
            [string](Get-ResultPropertyValue -Object $_ -Name 'FinalState' -DefaultValue '') -notin @('prepared', 'reused')
        }
    )
    $failure = @($failedResults | Select-Object -First 1)
    $prepareState = if ($allResults.Count -eq 0) {
        'pending'
    }
    elseif (@($failure).Count -gt 0) {
        'failed'
    }
    else {
        'completed'
    }

    $visibleBeaconObserved = [bool](@(
        $allResults | Where-Object { [bool](Get-ResultPropertyValue -Object $_ -Name 'VisibleBeaconObserved' -DefaultValue $false) }
    ).Count -gt 0)
    $focusStealDetected = [bool](@(
        $allResults | Where-Object { [bool](Get-ResultPropertyValue -Object $_ -Name 'FocusStealDetected' -DefaultValue $false) }
    ).Count -gt 0)

    $failureReason = ''
    $failureTargetId = ''
    if (@($failure).Count -gt 0) {
        $failureReason = Resolve-TypedWindowBootstrapFailureClass -BootstrapResult $failure[0]
        $failureTargetId = [string](Get-ResultPropertyValue -Object $failure[0] -Name 'TargetId' -DefaultValue '')
        if ($failureReason -eq 'visible-bootstrap-focus-steal') {
            $focusStealDetected = $true
        }
    }

    return [pscustomobject]@{
        BootstrapPrepareState = $prepareState
        BootstrapPreparedTargets = @($preparedTargets)
        BootstrapPreparedTargetCount = @($preparedTargets).Count
        BootstrapTotalTargetCount = $allResults.Count
        BootstrapVisibleBeaconObserved = $visibleBeaconObserved
        BootstrapFocusStealDetected = $focusStealDetected
        BootstrapCompletedAt = $completedAt
        BootstrapFailureReason = $failureReason
        BootstrapFailureTargetId = $failureTargetId
    }
}

function Wait-ForLiveAcceptanceOutcome {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$PairTest,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$SeedTargetId,
        [Parameter(Mandatory)][string]$PartnerTargetId,
        [Parameter(Mandatory)][int]$InitialSeedInboxCount,
        [Parameter(Mandatory)][int]$InitialPartnerInboxCount,
        [Parameter(Mandatory)][int]$WaitForFirstHandoffSeconds,
        [Parameter(Mandatory)][int]$WaitForRoundtripSeconds,
        [switch]$UseVisibleWorker,
        [int]$VisibleWorkerProgressGraceSeconds = 30
    )

    $firstHandoffDeadline = (Get-Date).AddSeconds([math]::Max(1, $WaitForFirstHandoffSeconds))
    $firstHandoffConfirmed = $false
    $roundtripConfirmed = $false
    $roundtripBaselineSeedInboxCount = 0
    $lastStatus = $null
    $firstHandoffAt = ''
    $roundtripAt = ''
    $acceptanceState = 'waiting'
    $acceptanceReason = ''
    $seedFailureStates = @('failed', 'timeout', 'submit-unconfirmed', 'worker-not-ready', 'dispatch-accepted-stale', 'dispatch-running-stale-no-heartbeat')
    $partnerFailureStates = @('failed', 'timeout', 'submit-unconfirmed', 'worker-not-ready', 'dispatch-accepted-stale', 'dispatch-running-stale-no-heartbeat')

    while ($true) {
        $lastStatus = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        $seedRow = @(Get-TargetRow -Status $lastStatus -TargetId $SeedTargetId)
        $partnerRow = @(Get-TargetRow -Status $lastStatus -TargetId $PartnerTargetId)
        if (@($seedRow).Length -eq 0 -or @($partnerRow).Length -eq 0) {
            throw "paired status target rows missing: seed=$SeedTargetId partner=$PartnerTargetId"
        }

        $seedStillProgressing = $false
        $partnerStillProgressing = $false

        $seedReadyCount = Get-TargetReadyFileCount -Config $Config -TargetId $SeedTargetId
        $partnerReadyCount = Get-TargetReadyFileCount -Config $Config -TargetId $PartnerTargetId

        $seedLatestState = [string]$seedRow[0].LatestState
        $seedSendState = [string]$seedRow[0].SeedSendState
        $partnerSeedState = [string]$partnerRow[0].SeedSendState
        $seedSubmitState = [string]$seedRow[0].SubmitState
        $partnerSubmitState = [string]$partnerRow[0].SubmitState
        $seedPublishObserved = Test-PairedSourceOutboxObservedRow -Row $seedRow[0]
        $seedHandoffReady = Test-PairedHandoffTransitionReadyRow -Row $seedRow[0]
        $seedHandoffAccepted = Test-PairedHandoffAcceptedRow -Row $seedRow[0]
        $partnerHandoffAccepted = Test-PairedHandoffAcceptedRow -Row $partnerRow[0]
        $partnerProgressObserved = Test-PairedPartnerProgressObserved -Row $partnerRow[0]
        $forwardedCount = [int]$lastStatus.Counts.ForwardedStateCount
        $watcherStatusValue = [string]$lastStatus.Watcher.Status
        $watcherStopCategory = [string]$lastStatus.Watcher.StopCategory
        $watcherReasonValue = [string]$lastStatus.Watcher.StatusReason
        $watcherStopSuffix = if ($watcherStatusValue -eq 'stopped' -and (Test-NonEmptyString $watcherStopCategory -or Test-NonEmptyString $watcherReasonValue)) {
            '; watcherStopCategory=' + $watcherStopCategory + '; watcherReason=' + $watcherReasonValue
        }
        else {
            ''
        }

        if (-not $firstHandoffConfirmed) {
            if ($seedSendState -eq 'manual_attention_required' -or [bool]$seedRow[0].ManualAttentionRequired) {
                $manualAttentionOutcome = Get-PairedAcceptanceManualAttentionOutcome -RetryReason ([string]$seedRow[0].SeedRetryReason)
                $acceptanceState = [string]$manualAttentionOutcome.AcceptanceState
                $acceptanceReason = [string]$manualAttentionOutcome.AcceptanceReason
                break
            }

            $seedStillProgressing = $UseVisibleWorker -and (Test-VisibleWorkerTargetProgress -Row $seedRow[0] -PairTest $PairTest)
            if (($seedSubmitState -eq 'unconfirmed' -or $seedSendState -in $seedFailureStates) -and -not $seedStillProgressing) {
                $failureOutcome = Get-PairedAcceptanceFailureOutcome -SubmitState $seedSubmitState -ExecutionState $seedSendState -SubmitReason ([string]$seedRow[0].SubmitReason)
                $acceptanceState = [string]$failureOutcome.AcceptanceState
                $acceptanceReason = [string]$failureOutcome.AcceptanceReason
                break
            }

            $firstHandoffDetected = Test-PairedFirstHandoffDetected `
                -CurrentRow $seedRow[0] `
                -PartnerRow $partnerRow[0] `
                -ForwardedCount $forwardedCount `
                -PartnerReadyCount $partnerReadyCount `
                -InitialPartnerInboxCount $InitialPartnerInboxCount `
                -UseVisibleWorker:$UseVisibleWorker

            if ($firstHandoffDetected) {
                $firstHandoffConfirmed = $true
                $firstHandoffAt = (Get-Date).ToString('o')
                $roundtripBaselineSeedInboxCount = $seedReadyCount
                if ($WaitForRoundtripSeconds -le 0) {
                    $successOutcome = Get-PairedAcceptanceSuccessOutcome -FirstHandoff -UseVisibleWorker:$UseVisibleWorker
                    $acceptanceState = [string]$successOutcome.AcceptanceState
                    $acceptanceReason = [string]$successOutcome.AcceptanceReason
                    break
                }
                $firstHandoffDeadline = (Get-Date).AddSeconds([math]::Max(1, $WaitForRoundtripSeconds))
            }
        }
        else {
            if ($partnerSeedState -eq 'manual_attention_required' -or [bool]$partnerRow[0].ManualAttentionRequired) {
                $manualAttentionOutcome = Get-PairedAcceptanceManualAttentionOutcome -RetryReason ([string]$partnerRow[0].SeedRetryReason)
                $acceptanceState = [string]$manualAttentionOutcome.AcceptanceState
                $acceptanceReason = [string]$manualAttentionOutcome.AcceptanceReason
                break
            }

            $partnerStillProgressing = $UseVisibleWorker -and (Test-VisibleWorkerTargetProgress -Row $partnerRow[0] -PairTest $PairTest)
            if (($partnerSubmitState -eq 'unconfirmed' -or $partnerSeedState -in $partnerFailureStates) -and -not $partnerStillProgressing) {
                $failureOutcome = Get-PairedAcceptanceFailureOutcome -SubmitState $partnerSubmitState -ExecutionState $partnerSeedState -SubmitReason ([string]$partnerRow[0].SubmitReason)
                $acceptanceState = [string]$failureOutcome.AcceptanceState
                $acceptanceReason = [string]$failureOutcome.AcceptanceReason
                break
            }

            $roundtripDetected = Test-PairedRoundtripDetected `
                -SeedRow $seedRow[0] `
                -PartnerRow $partnerRow[0] `
                -ForwardedCount $forwardedCount `
                -SeedReadyCount $seedReadyCount `
                -RoundtripBaselineSeedInboxCount $roundtripBaselineSeedInboxCount `
                -UseVisibleWorker:$UseVisibleWorker

            if ($roundtripDetected) {
                $roundtripConfirmed = $true
                $roundtripAt = (Get-Date).ToString('o')
                $successOutcome = Get-PairedAcceptanceSuccessOutcome -Roundtrip -UseVisibleWorker:$UseVisibleWorker
                $acceptanceState = [string]$successOutcome.AcceptanceState
                $acceptanceReason = [string]$successOutcome.AcceptanceReason
                break
            }
        }

        if ((Get-Date) -ge $firstHandoffDeadline) {
            if ($UseVisibleWorker) {
                if ((-not $firstHandoffConfirmed) -and $seedStillProgressing) {
                    $firstHandoffDeadline = (Get-Date).AddSeconds([math]::Max(5, $VisibleWorkerProgressGraceSeconds))
                    Start-Sleep -Milliseconds 1000
                    continue
                }
                if ($firstHandoffConfirmed -and $partnerStillProgressing) {
                    $firstHandoffDeadline = (Get-Date).AddSeconds([math]::Max(5, $VisibleWorkerProgressGraceSeconds))
                    Start-Sleep -Milliseconds 1000
                    continue
                }
            }
            $timeoutOutcome = Get-PairedAcceptanceTimeoutOutcome -FirstHandoffConfirmed:$firstHandoffConfirmed -UseVisibleWorker:$UseVisibleWorker -WatcherStopSuffix $watcherStopSuffix
            $acceptanceState = [string]$timeoutOutcome.AcceptanceState
            $acceptanceReason = [string]$timeoutOutcome.AcceptanceReason
            break
        }

        Start-Sleep -Milliseconds 1000
    }

    $seedRowFinal = if ($null -ne $lastStatus) { @(Get-TargetRow -Status $lastStatus -TargetId $SeedTargetId) } else { @() }
    $partnerRowFinal = if ($null -ne $lastStatus) { @(Get-TargetRow -Status $lastStatus -TargetId $PartnerTargetId) } else { @() }

    return [pscustomobject]@{
        AcceptanceState = $acceptanceState
        AcceptanceReason = $acceptanceReason
        FirstHandoffConfirmed = $firstHandoffConfirmed
        FirstHandoffAt = $firstHandoffAt
        RoundtripConfirmed = $roundtripConfirmed
        RoundtripAt = $roundtripAt
        InitialSeedInboxCount = $InitialSeedInboxCount
        InitialPartnerInboxCount = $InitialPartnerInboxCount
        FinalSeedInboxCount = (Get-TargetReadyFileCount -Config $Config -TargetId $SeedTargetId)
        FinalPartnerInboxCount = (Get-TargetReadyFileCount -Config $Config -TargetId $PartnerTargetId)
        Diagnostics = [pscustomobject]@{
            Seed = if (@($seedRowFinal).Length -gt 0) { New-AcceptanceTargetDiagnostics -Row $seedRowFinal[0] -TargetId $SeedTargetId } else { $null }
            Partner = if (@($partnerRowFinal).Length -gt 0) { New-AcceptanceTargetDiagnostics -Row $partnerRowFinal[0] -TargetId $PartnerTargetId } else { $null }
        }
        FinalStatus = $lastStatus
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'router\RelayMessageMetadata.ps1')
. (Join-Path $root 'tests\PairedExchangeConfig.ps1')
. (Join-Path $root 'launcher\WindowDiscovery.ps1')
if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairTest = Resolve-PairTestConfig -Root $root -ConfigPath $resolvedConfigPath
$windowLaunchEvidence = Get-WindowLaunchEvidence -Config $config
$executionPathMode = [string](Get-ConfigValue -Object $pairTest -Name 'ExecutionPathMode' -DefaultValue $(if ([bool]$pairTest.VisibleWorker.Enabled) { 'visible-worker' } else { 'typed-window' }))
$acceptanceProfile = [string](Get-ConfigValue -Object $pairTest -Name 'AcceptanceProfile' -DefaultValue 'project-review')
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
if (-not (Test-NonEmptyString $PairId)) {
    $PairId = Get-DefaultPairId -PairTest $pairTest
}
if ($visibleWorkerEnabled -and -not [bool]$pairTest.VisibleWorker.Enabled) {
    throw 'PairTest.ExecutionPathMode is visible-worker but PairTest.VisibleWorker.Enabled is false.'
}
if ($requireUserVisibleCellExecution -and $executionPathMode -ne 'typed-window') {
    throw 'shared real test policy requires typed-window execution in the user-visible cells.'
}
$pairDefinition = Get-PairDefinition -PairTest $pairTest -PairId $PairId
$pairPolicy = Get-PairPolicyForPair -PairTest $pairTest -PairId $PairId
if (-not $PSBoundParameters.ContainsKey('SeedTargetId') -and -not (Test-NonEmptyString $SeedTargetId)) {
    $SeedTargetId = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedTargetId' -DefaultValue ([string]$pairDefinition.TopTargetId))
}
if (-not $PSBoundParameters.ContainsKey('SeedWorkRepoRoot') -and -not (Test-NonEmptyString $SeedWorkRepoRoot)) {
    $SeedWorkRepoRoot = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedWorkRepoRoot' -DefaultValue '')
}
if (-not $PSBoundParameters.ContainsKey('SeedReviewInputPath') -and -not (Test-NonEmptyString $SeedReviewInputPath)) {
    $SeedReviewInputPath = [string](Get-ConfigValue -Object $pairPolicy -Name 'DefaultSeedReviewInputPath' -DefaultValue '')
}
Assert-SeedWorkRepoPolicy `
    -PairTest $pairTest `
    -PairPolicy $pairPolicy `
    -AutomationRoot $root `
    -WorkRepoRoot $SeedWorkRepoRoot `
    -ReviewInputPath $SeedReviewInputPath
if (-not $PSBoundParameters.ContainsKey('SeedTaskText') -and -not (Test-NonEmptyString $SeedTaskText) -and ($acceptanceProfile -eq 'smoke')) {
    $SeedTaskText = [string](Get-ConfigValue -Object $pairTest -Name 'SmokeSeedTaskText' -DefaultValue '')
}
if (-not $PSBoundParameters.ContainsKey('WatcherRunDurationSec') -and [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultWatcherRunDurationSec' -DefaultValue 0) -gt 0) {
    $WatcherRunDurationSec = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultWatcherRunDurationSec' -DefaultValue $WatcherRunDurationSec)
}
if (-not $PSBoundParameters.ContainsKey('WatcherMaxForwardCount') -and [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultWatcherMaxForwardCount' -DefaultValue 0) -gt 0) {
    $WatcherMaxForwardCount = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultWatcherMaxForwardCount' -DefaultValue $WatcherMaxForwardCount)
}
if (-not $PSBoundParameters.ContainsKey('WatcherPairMaxRoundtripCount') -and [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultPairMaxRoundtripCount' -DefaultValue 0) -gt 0) {
    $WatcherPairMaxRoundtripCount = [int](Get-ConfigValue -Object $pairPolicy -Name 'DefaultPairMaxRoundtripCount' -DefaultValue $WatcherPairMaxRoundtripCount)
}

$partnerTargetId = if ([string]$SeedTargetId -eq [string]$pairDefinition.TopTargetId) {
    [string]$pairDefinition.BottomTargetId
}
elseif ([string]$SeedTargetId -eq [string]$pairDefinition.BottomTargetId) {
    [string]$pairDefinition.TopTargetId
}
else {
    throw "seed target does not belong to pair: seed=$SeedTargetId pair=$PairId"
}

$resolvedRunRoot = ''
$startedWatcher = $false
$routerLaunchMode = 'existing'
$watcherLaunchMode = 'existing'
$watcherStopRequestId = ''
$watcherStopError = ''
$preflightOnlyCompleted = $false
$routerRestartResult = $null
$result = $null
$watcherDurationPlan = $null

if (Test-NonEmptyString $RunRoot) {
    $resolvedRunRoot = Resolve-PairRunRootPath `
        -Root $root `
        -RunRoot $RunRoot `
        -PairTest $pairTest `
        -PairPolicy $pairPolicy `
        -WorkRepoRoot $SeedWorkRepoRoot
}

if ($ReuseExistingRunRoot) {
    if (-not (Test-NonEmptyString $resolvedRunRoot) -or -not (Test-Path -LiteralPath (Join-Path $resolvedRunRoot 'manifest.json') -PathType Leaf)) {
        throw 'ReuseExistingRunRoot를 사용할 때는 manifest.json이 있는 기존 RunRoot가 필요합니다.'
    }
}
else {
    $preparedRunRootExists = $false
    if (Test-NonEmptyString $resolvedRunRoot) {
        $preparedRunRootExists = (Test-Path -LiteralPath (Join-Path $resolvedRunRoot 'manifest.json') -PathType Leaf)
    }

    if ($preparedRunRootExists) {
        throw "RunRoot already exists. Reuse하려면 -ReuseExistingRunRoot를 사용하세요: $resolvedRunRoot"
    }

    $startScriptPath = Join-Path $root 'tests\Start-PairedExchangeTest.ps1'
    $startParams = @{
        ConfigPath    = $resolvedConfigPath
        IncludePairId = @($PairId)
        InitialTargetId = @($SeedTargetId)
    }
    if (Test-NonEmptyString $SeedWorkRepoRoot) {
        $startParams.SeedWorkRepoRoot = $SeedWorkRepoRoot
    }
    if (Test-NonEmptyString $SeedReviewInputPath) {
        $startParams.SeedReviewInputPath = $SeedReviewInputPath
    }
    if (Test-NonEmptyString $SeedTaskText) {
        $startParams.SeedTaskText = $SeedTaskText
    }
    if (Test-NonEmptyString $resolvedRunRoot) {
        $startParams.RunRoot = $resolvedRunRoot
    }
    $startOutput = Invoke-ScriptAndCaptureOutput -ScriptPath $startScriptPath -Parameters $startParams
    $preparedRunRoot = Resolve-PreparedRunRootFromOutput -Lines $startOutput
    if (Test-NonEmptyString $preparedRunRoot) {
        $resolvedRunRoot = $preparedRunRoot
    }
    elseif (-not (Test-NonEmptyString $resolvedRunRoot)) {
        throw 'Start-PairedExchangeTest 출력에서 prepared pair test root를 찾지 못했습니다.'
    }
}

if (Test-NonEmptyString $resolvedRunRoot) {
    Assert-RunRootPolicy `
        -PairTest $pairTest `
        -PairPolicy $pairPolicy `
        -AutomationRoot $root `
        -RunRoot $resolvedRunRoot `
        -WorkRepoRoot $SeedWorkRepoRoot

    Assert-BookkeepingRootsPolicy `
        -Config $config `
        -PairTest $pairTest `
        -PairPolicy $pairPolicy `
        -AutomationRoot $root `
        -BasePath $root `
        -WorkRepoRoot $SeedWorkRepoRoot
}

$watcherDurationPlan = Get-VisibleWorkerWatcherDurationPlan `
    -PairTest $pairTest `
    -RequestedRunDurationSec $WatcherRunDurationSec `
    -SeedWaitForPublishSeconds $SeedWaitForPublishSeconds `
    -WaitForFirstHandoffSeconds $WaitForFirstHandoffSeconds `
    -WaitForRoundtripSeconds $WaitForRoundtripSeconds `
    -ConfiguredMaxForwardCount $WatcherMaxForwardCount
$WatcherRunDurationSec = [int]$watcherDurationPlan.EffectiveRunDurationSec

$contractEvidence = Get-RunContractEvidence -RunRoot $resolvedRunRoot -SeedTargetId $SeedTargetId -PartnerTargetId $partnerTargetId

$result = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    ConfigPath = $resolvedConfigPath
    TransportMode = if ($visibleWorkerEnabled) { 'visible-worker' } else { 'typed-window' }
    ExecutionPathMode = $executionPathMode
    AcceptanceProfile = $acceptanceProfile
    PairId = $PairId
    PairPolicy = $pairPolicy
    RunRoot = $resolvedRunRoot
    ReceiptPath = (Join-Path $resolvedRunRoot '.state\live-acceptance-result.json')
    WindowLaunchMode = [string]$windowLaunchEvidence.LaunchMode
    WindowReuseMode = [string]$windowLaunchEvidence.ReuseMode
    WrapperPath = [string]$windowLaunchEvidence.WrapperPath
    WindowControl = $windowLaunchEvidence
    Contract = [pscustomobject]@{
        ExternalWorkRepoUsed = [bool](Get-ResultPropertyValue -Object $contractEvidence -Name 'ExternalWorkRepoUsed' -DefaultValue $false)
        PrimaryContractExternalized = [bool](Get-ResultPropertyValue -Object $contractEvidence -Name 'PrimaryContractExternalized' -DefaultValue $false)
        ExternalRunRootUsed = [bool](Get-ResultPropertyValue -Object $contractEvidence -Name 'ExternalRunRootUsed' -DefaultValue $false)
        BookkeepingExternalized = [bool](Get-ResultPropertyValue -Object $contractEvidence -Name 'BookkeepingExternalized' -DefaultValue $false)
        FullExternalized = [bool](Get-ResultPropertyValue -Object $contractEvidence -Name 'FullExternalized' -DefaultValue $false)
        ExternalContractPathsValidated = [bool](Get-ResultPropertyValue -Object $contractEvidence -Name 'ExternalContractPathsValidated' -DefaultValue $false)
        RunRootPathValidated = [bool](Get-ResultPropertyValue -Object $contractEvidence -Name 'RunRootPathValidated' -DefaultValue $false)
        InternalResidualRoots = @((Get-ResultPropertyValue -Object $contractEvidence -Name 'InternalResidualRoots' -DefaultValue @()))
        Targets = @((Get-ResultPropertyValue -Object $contractEvidence -Name 'ContractTargets' -DefaultValue @()))
    }
    UserVisibleCellExecutionRequired = $requireUserVisibleCellExecution
    AllowedWindowVisibilityMethods = @($allowedWindowVisibilityMethods)
    SubmitRetryModes = @($submitRetryModes)
    SubmitRetrySequenceSummary = $submitRetrySequenceSummary
    PrimarySubmitMode = $primarySubmitMode
    FinalSubmitMode = $finalSubmitMode
    SubmitRetryIntervalMs = $submitRetryIntervalMs
    VisibleExecutionBeaconEnabled = [bool](Get-ConfigValue -Object $config -Name 'VisibleExecutionBeaconEnabled' -DefaultValue $false)
    VisibleExecutionPreHoldMs = [int](Get-ConfigValue -Object $config -Name 'VisibleExecutionPreHoldMs' -DefaultValue 0)
    VisibleExecutionPostHoldMs = [int](Get-ConfigValue -Object $config -Name 'VisibleExecutionPostHoldMs' -DefaultValue 0)
    VisibleExecutionRestorePreviousActive = [bool](Get-ConfigValue -Object $config -Name 'VisibleExecutionRestorePreviousActive' -DefaultValue $true)
    VisibleExecutionFailOnFocusSteal = [bool](Get-ConfigValue -Object $config -Name 'VisibleExecutionFailOnFocusSteal' -DefaultValue $false)
    SeedTargetId = $SeedTargetId
    PartnerTargetId = $partnerTargetId
    Stage = 'prepared'
    Router = $null
    Watcher = $null
    Preflight = if ($visibleWorkerEnabled) {
        [pscustomobject]@{
            CheckState = 'pending'
            RequestedWatcherRunDurationSec = [int]$watcherDurationPlan.RequestedRunDurationSec
            EffectiveWatcherRunDurationSec = [int]$watcherDurationPlan.EffectiveRunDurationSec
            RequestedWatcherPairMaxRoundtripCount = [int]$WatcherPairMaxRoundtripCount
            EffectiveWatcherPairMaxRoundtripCount = [int]$WatcherPairMaxRoundtripCount
            RecommendedMinWatcherRunDurationSec = [int]$watcherDurationPlan.RecommendedMinRunDurationSec
            RequestedWatcherDurationAdjusted = [bool]$watcherDurationPlan.RequestedDurationAdjusted
            AcceptanceForwardedStateCount = [int]$watcherDurationPlan.AcceptanceForwardedStateCount
            CloseoutForwardedStateCount = [int]$watcherDurationPlan.CloseoutForwardedStateCount
            ExpectedForwardedStateCount = [int]$watcherDurationPlan.ExpectedForwardedStateCount
            PerTurnTimeoutSeconds = [int]$watcherDurationPlan.PerTurnTimeoutSeconds
            TurnBudgetSeconds = [int]$watcherDurationPlan.TurnBudgetSeconds
            AcceptanceBudgetSeconds = [int]$watcherDurationPlan.AcceptanceBudgetSeconds
            VisibleWorkerIdleOk = $false
            VisibleWorkerQueueEmptyOk = $false
            VisibleWorkerProcessingEmptyOk = $false
            VisibleWorkerReadyOk = $false
            VisibleWorkerForeignRunCleanOk = $false
            VisibleWorkerMetadataCleanOk = $false
            WorkerReadyFreshnessSeconds = [int](Get-ConfigValue -Object $pairTest.VisibleWorker -Name 'WorkerReadyFreshnessSeconds' -DefaultValue 30)
            DispatchAcceptedStaleSeconds = [int](Get-ConfigValue -Object $pairTest.VisibleWorker -Name 'DispatchAcceptedStaleSeconds' -DefaultValue 15)
            DispatchRunningStaleSeconds = [int](Get-ConfigValue -Object $pairTest.VisibleWorker -Name 'DispatchRunningStaleSeconds' -DefaultValue 30)
            WindowLaunchMode = [string]$windowLaunchEvidence.LaunchMode
            WindowReuseMode = [string]$windowLaunchEvidence.ReuseMode
            WrapperPath = [string]$windowLaunchEvidence.WrapperPath
            NonStandardWindowBlock = [bool]$windowLaunchEvidence.NonStandardWindowBlock
            WatcherNotRunningOrSameRunOk = $false
            OfficialWindowReuseOk = $true
            NonStandardVisibleWindowCount = 0
            NonStandardVisibleWindowTitles = @()
            RouterStateConsistentOk = $true
            BlockedBy = ''
            BlockedTargetId = ''
            BlockedCommandId = ''
            BlockedRunRoot = ''
            BlockedPath = ''
            BlockedDetail = ''
            SummaryLines = @()
            Targets = @()
        }
    } else {
        [pscustomobject]@{
            CheckState = 'pending'
            WindowLaunchMode = [string]$windowLaunchEvidence.LaunchMode
            WindowReuseMode = [string]$windowLaunchEvidence.ReuseMode
            WrapperPath = [string]$windowLaunchEvidence.WrapperPath
            NonStandardWindowBlock = [bool]$windowLaunchEvidence.NonStandardWindowBlock
            OfficialWindowReuseOk = $true
            NonStandardVisibleWindowCount = 0
            NonStandardVisibleWindowTitles = @()
            WindowVisibilityOk = $false
            VisibilityPassMode = ''
            AllowedVisibilityMethods = @()
            UniqueHwndCount = 0
            WindowPidOnlyFallbackDetected = $false
            UserVisibleCellExecutionRequired = $requireUserVisibleCellExecution
            BlockedBy = ''
            BlockedTargetId = ''
            BlockedCommandId = ''
            BlockedRunRoot = ''
            BlockedPath = ''
            BlockedDetail = ''
            SummaryLines = @()
            Targets = @()
        }
    }
    Seed = $null
    Bootstrap = [pscustomobject]@{
        BootstrapPrepareState = 'pending'
        BootstrapPreparedTargets = @()
        BootstrapPreparedTargetCount = 0
        BootstrapTotalTargetCount = 0
        BootstrapVisibleBeaconObserved = $false
        BootstrapFocusStealDetected = $false
        BootstrapCompletedAt = ''
        BootstrapFailureReason = ''
        BootstrapFailureTargetId = ''
    }
    Primitives = [pscustomobject]@{
        Bootstrap = @()
        Submit = $null
        Publish = $null
        Handoff = $null
    }
    VisibleWorker = if ($visibleWorkerEnabled) { Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId) } else { $null }
    Closeout = [pscustomobject]@{
        Requested = ($WatcherMaxForwardCount -gt [int]$watcherDurationPlan.AcceptanceForwardedStateCount)
        AcceptanceForwardedStateCount = [int]$watcherDurationPlan.AcceptanceForwardedStateCount
        TargetForwardedStateCount = [int]$watcherDurationPlan.CloseoutForwardedStateCount
        ObservedForwardedStateCount = 0
        ObservedDonePresentCount = 0
        ObservedErrorPresentCount = 0
        Satisfied = $false
        Status = if ($WatcherMaxForwardCount -gt [int]$watcherDurationPlan.AcceptanceForwardedStateCount) { 'pending' } else { 'not-requested' }
    }
    BlockedBy = ''
    BlockedTargetId = ''
    BlockedCommandId = ''
    BlockedRunRoot = ''
    BlockedPath = ''
    BlockedDetail = ''
    Outcome = $null
}

Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

try {
    $processLogsRoot = ''
    if ($config.ContainsKey('LogsRoot')) {
        $processLogsRoot = [string]$config.LogsRoot
    }
    if (Test-NonEmptyString $processLogsRoot) {
        $tmpRoot = Join-Path (Resolve-FullPath -PathValue $processLogsRoot -BasePath (Split-Path -Parent $resolvedConfigPath)) 'acceptance-process-logs'
    }
    else {
        $tmpRoot = Join-Path (Join-Path $resolvedRunRoot '.state') 'process-logs'
    }
    if (-not (Test-Path -LiteralPath $tmpRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $routerStdoutLog = Join-Path $tmpRoot ('live-router-' + $timestamp + '.stdout.log')
    $routerStderrLog = ($routerStdoutLog + '.stderr')
    $watcherStdoutLog = Join-Path $tmpRoot ('live-watcher-' + $timestamp + '.stdout.log')
    $watcherStderrLog = ($watcherStdoutLog + '.stderr')

    $routerMutexName = [string]$config.RouterMutexName
    $routerStatePath = [string]$config.RouterStatePath
    $routerLogPath = [string]$config.RouterLogPath
    $routerState = $null
    $relayStatus = $null

    if ($visibleWorkerEnabled) {
        $routerLaunchMode = 'not-required'
        $result.Stage = 'router-skipped'
        $result.Router = [pscustomobject]@{
            LaunchMode = $routerLaunchMode
            MutexName = $routerMutexName
            Status = 'disabled-for-visible-worker'
            StateFileStatus = ''
            LastError = ''
            MutexHeld = $false
            StatePath = $routerStatePath
            LogPath = $routerLogPath
            StdoutLogPath = ''
            StderrLogPath = ''
            Restart = $null
        }
        $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
    }
    else {
        if ($ForceFreshRouter) {
            $result.Stage = 'router-restarting'
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
            $routerLaunchMode = 'restarted'
            $routerRestartRaw = & (Resolve-PowerShellExecutable) `
                '-NoProfile' `
                '-ExecutionPolicy' 'Bypass' `
                '-File' (Join-Path $root 'router\Restart-RouterForConfig.ps1') `
                '-ConfigPath' $resolvedConfigPath `
                '-AsJson'
            if ($LASTEXITCODE -ne 0) {
                throw ("Restart-RouterForConfig failed: " + (($routerRestartRaw | Out-String).Trim()))
            }
            $routerRestartResult = ConvertFrom-RelayJsonText -Json (($routerRestartRaw | Out-String).Trim())
        }
        elseif (-not (Test-MutexHeld -Name $routerMutexName)) {
            $routerLaunchMode = 'started'
            $powershellPath = Resolve-PowerShellExecutable
            $routerArguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $root 'router\Start-Router.ps1'),
                '-ConfigPath', $resolvedConfigPath
            )
            Start-Process -FilePath $powershellPath -ArgumentList $routerArguments -PassThru -RedirectStandardOutput $routerStdoutLog -RedirectStandardError $routerStderrLog | Out-Null
        }

        $result.Stage = 'router-waiting'
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        $routerState = Wait-ForRouterReady -RouterMutexName $routerMutexName -RouterStatePath $routerStatePath -TimeoutSeconds $WaitForRouterSeconds
        $relayStatus = Invoke-ShowRelayStatus -Root $root -ResolvedConfigPath $resolvedConfigPath

        $result.Stage = 'router-ready'
        $result.Router = [pscustomobject]@{
            LaunchMode = $routerLaunchMode
            MutexName = $routerMutexName
            Status = [string]$relayStatus.Router.Status
            StateFileStatus = if (Test-NonEmptyString ([string]$routerState.StateFileStatus)) { [string]$routerState.StateFileStatus } else { [string]$relayStatus.Router.Status }
            LastError = [string]$relayStatus.Router.LastError
            MutexHeld = [bool]$relayStatus.Router.MutexHeld
            StatePath = $routerStatePath
            LogPath = $routerLogPath
            StdoutLogPath = if ($null -ne $routerRestartResult -and (Test-NonEmptyString ([string]$routerRestartResult.StdoutLogPath))) { [string]$routerRestartResult.StdoutLogPath } else { $routerStdoutLog }
            StderrLogPath = if ($null -ne $routerRestartResult -and (Test-NonEmptyString ([string]$routerRestartResult.StderrLogPath))) { [string]$routerRestartResult.StderrLogPath } else { $routerStderrLog }
            Restart = $routerRestartResult
        }
        if ($visibleWorkerEnabled) {
            $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
        }
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
    }

    $result.Stage = 'status-snapshot'
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
    $watcherStatusSnapshot = ConvertFrom-RelayJsonText -Json ((& (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -AsJson | Out-String).Trim())
    if ($visibleWorkerEnabled) {
        $result.Stage = 'visible-worker-preflight'
        $result.Preflight.CheckState = 'waiting-for-visible-worker-clean'
        $result.Preflight.SummaryLines = @(
            'waiting for visible worker queue/processing cleanup before seed',
            ('effectiveWatcherRunDurationSec={0}' -f [int]$WatcherRunDurationSec)
        )
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

        $visibleWorkerPreflight = Get-VisibleWorkerPreflightReport `
            -PairTest $pairTest `
            -TargetIds @($SeedTargetId, $partnerTargetId) `
            -CurrentRunRoot $resolvedRunRoot `
            -WatcherStatus $watcherStatusSnapshot.Watcher `
            -AllowActiveWatcherForCurrentRun:$ReuseExistingRunRoot
        if ([string]$visibleWorkerPreflight.BlockedBy -eq 'visible-worker-not-ready') {
            $result.Stage = 'visible-worker-bootstrap'
            $result.Preflight.CheckState = 'bootstrapping-visible-worker'
            $result.Preflight.SummaryLines = @($visibleWorkerPreflight.SummaryLines + @('bootstrapping idle visible workers before final preflight'))
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

            $result.VisibleWorker = Wait-ForVisibleWorkerTargetsReady `
                -Root $root `
                -ResolvedConfigPath $resolvedConfigPath `
                -PairTest $pairTest `
                -TargetIds @($SeedTargetId, $partnerTargetId) `
                -TimeoutSeconds ([int]$pairTest.VisibleWorker.PreflightTimeoutSeconds) `
                -StartIdleWorkers
            $watcherStatusSnapshot = ConvertFrom-RelayJsonText -Json ((& (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -AsJson | Out-String).Trim())
            $visibleWorkerPreflight = Get-VisibleWorkerPreflightReport `
                -PairTest $pairTest `
                -TargetIds @($SeedTargetId, $partnerTargetId) `
                -CurrentRunRoot $resolvedRunRoot `
                -WatcherStatus $watcherStatusSnapshot.Watcher `
                -AllowActiveWatcherForCurrentRun:$ReuseExistingRunRoot
        }
        $officialWindowReport = Get-OfficialVisibleWindowReuseReport -Root $root -Config $config

        $result.Preflight.CheckState = if ([bool]$visibleWorkerPreflight.Passed) { 'passed' } else { 'failed' }
        $result.Preflight.VisibleWorkerIdleOk = [bool]$visibleWorkerPreflight.VisibleWorkerIdleOk
        $result.Preflight.VisibleWorkerQueueEmptyOk = [bool]$visibleWorkerPreflight.VisibleWorkerQueueEmptyOk
        $result.Preflight.VisibleWorkerProcessingEmptyOk = [bool]$visibleWorkerPreflight.VisibleWorkerProcessingEmptyOk
        $result.Preflight.VisibleWorkerReadyOk = [bool]$visibleWorkerPreflight.VisibleWorkerReadyOk
        $result.Preflight.VisibleWorkerForeignRunCleanOk = [bool]$visibleWorkerPreflight.VisibleWorkerForeignRunCleanOk
        $result.Preflight.VisibleWorkerMetadataCleanOk = [bool]$visibleWorkerPreflight.VisibleWorkerMetadataCleanOk
        $result.Preflight.WatcherNotRunningOrSameRunOk = [bool]$visibleWorkerPreflight.WatcherNotRunningOrSameRunOk
        $result.Preflight.OfficialWindowReuseOk = [bool]$officialWindowReport.Passed
        $result.Preflight.NonStandardVisibleWindowCount = [int]$officialWindowReport.NonStandardCount
        $result.Preflight.NonStandardVisibleWindowTitles = @($officialWindowReport.NonStandardWindows | ForEach-Object { [string]$_.Title })
        $result.Preflight.BlockedBy = [string]$visibleWorkerPreflight.BlockedBy
        $result.Preflight.BlockedTargetId = [string]$visibleWorkerPreflight.BlockedTargetId
        $result.Preflight.BlockedCommandId = [string]$visibleWorkerPreflight.BlockedCommandId
        $result.Preflight.BlockedRunRoot = [string]$visibleWorkerPreflight.BlockedRunRoot
        $result.Preflight.BlockedPath = [string]$visibleWorkerPreflight.BlockedPath
        $result.Preflight.BlockedDetail = [string]$visibleWorkerPreflight.BlockedDetail
        $result.Preflight.SummaryLines = @($visibleWorkerPreflight.SummaryLines + $officialWindowReport.SummaryLines)
        $result.Preflight.Targets = @($visibleWorkerPreflight.Targets)
        $result.VisibleWorker = $visibleWorkerPreflight.VisibleWorker
        $result.BlockedBy = [string]$visibleWorkerPreflight.BlockedBy
        $result.BlockedTargetId = [string]$visibleWorkerPreflight.BlockedTargetId
        $result.BlockedCommandId = [string]$visibleWorkerPreflight.BlockedCommandId
        $result.BlockedRunRoot = [string]$visibleWorkerPreflight.BlockedRunRoot
        $result.BlockedPath = [string]$visibleWorkerPreflight.BlockedPath
        $result.BlockedDetail = [string]$visibleWorkerPreflight.BlockedDetail

        if (-not [bool]$officialWindowReport.Passed) {
            $result.Preflight.CheckState = 'failed'
            $result.Preflight.BlockedBy = 'nonstandard-visible-window-present'
            $result.Preflight.BlockedDetail = 'shared visible lane must reuse official BotTestLive-Window-01..08 only'
            $result.BlockedBy = 'nonstandard-visible-window-present'
            $result.BlockedDetail = 'shared visible lane must reuse official BotTestLive-Window-01..08 only'
            if (@($officialWindowReport.NonStandardWindows).Count -gt 0) {
                $firstWindow = @($officialWindowReport.NonStandardWindows | Select-Object -First 1)
                $result.Preflight.BlockedPath = [string]$firstWindow[0].Title
                $result.BlockedPath = [string]$firstWindow[0].Title
            }
        }
        if (-not [bool]$visibleWorkerPreflight.Passed -or -not [bool]$officialWindowReport.Passed) {
            $result.Stage = 'preflight-failed'
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
            $combinedPreflightLines = @($visibleWorkerPreflight.SummaryLines + $officialWindowReport.SummaryLines)
            throw ('visible worker preflight failed: ' + (@($combinedPreflightLines) -join '; '))
        }

        $result.Stage = 'visible-worker-ready'
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

        if ($PreflightOnly) {
            $result.Stage = 'completed'
            $result.Outcome = [pscustomobject]@{
                AcceptanceState = 'preflight-passed'
                AcceptanceReason = 'visible-worker-preflight-passed'
            }
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
            $preflightOnlyCompleted = $true
        }

        if (-not $preflightOnlyCompleted) {
            $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
            $watcherStatusSnapshot = ConvertFrom-RelayJsonText -Json ((& (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -ConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -AsJson | Out-String).Trim())
        }
    }
    else {
        $result.Stage = 'typed-window-preflight-starting'
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        $typedWindowPreflight = Get-TypedWindowPreflightReport `
            -Root $root `
            -Config $config `
            -ResolvedConfigPath $resolvedConfigPath `
            -PairTest $pairTest

        $result.Stage = 'typed-window-preflight'
        $result.Preflight.CheckState = if ([bool]$typedWindowPreflight.Passed) { 'passed' } else { 'failed' }
        $result.Preflight.OfficialWindowReuseOk = [bool]$typedWindowPreflight.OfficialWindowReport.Passed
        $result.Preflight.NonStandardVisibleWindowCount = [int]$typedWindowPreflight.OfficialWindowReport.NonStandardCount
        $result.Preflight.NonStandardVisibleWindowTitles = @($typedWindowPreflight.OfficialWindowReport.NonStandardWindows | ForEach-Object { [string]$_.Title })
        $result.Preflight.WindowVisibilityOk = [bool]$typedWindowPreflight.Passed
        $result.Preflight.VisibilityPassMode = ($typedWindowPreflight.AllowedMethods -join ',')
        $result.Preflight.AllowedVisibilityMethods = @($typedWindowPreflight.AllowedMethods)
        $result.Preflight.UniqueHwndCount = [int]$typedWindowPreflight.UniqueHwndCount
        $result.Preflight.WindowPidOnlyFallbackDetected = [bool]$typedWindowPreflight.WindowPidOnlyFallbackDetected
        $result.Preflight.BlockedBy = [string]$typedWindowPreflight.BlockedBy
        $result.Preflight.BlockedTargetId = [string]$typedWindowPreflight.BlockedTargetId
        $result.Preflight.BlockedDetail = [string]$typedWindowPreflight.BlockedDetail
        $result.Preflight.SummaryLines = @($typedWindowPreflight.SummaryLines)
        $result.Preflight.Targets = @($typedWindowPreflight.Targets)
        $result.BlockedBy = [string]$typedWindowPreflight.BlockedBy
        $result.BlockedTargetId = [string]$typedWindowPreflight.BlockedTargetId
        $result.BlockedDetail = [string]$typedWindowPreflight.BlockedDetail

        if (-not [bool]$typedWindowPreflight.Passed) {
            $result.Stage = 'preflight-failed'
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
            throw ('typed-window preflight failed: ' + (@($typedWindowPreflight.SummaryLines) -join '; '))
        }

        $result.Stage = 'typed-window-ready'
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

        if ($PreflightOnly) {
            $result.Stage = 'completed'
            $result.Outcome = [pscustomobject]@{
                AcceptanceState = 'preflight-passed'
                AcceptanceReason = 'typed-window-preflight-passed'
            }
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
            $preflightOnlyCompleted = $true
        }

        if (-not $preflightOnlyCompleted) {
            $result.Stage = 'typed-window-bootstrap'
            $result.Bootstrap.BootstrapPrepareState = 'running'
            $result.Bootstrap.BootstrapPreparedTargets = @()
            $result.Bootstrap.BootstrapPreparedTargetCount = 0
            $result.Bootstrap.BootstrapTotalTargetCount = 2
            $result.Bootstrap.BootstrapVisibleBeaconObserved = $false
            $result.Bootstrap.BootstrapFocusStealDetected = $false
            $result.Bootstrap.BootstrapCompletedAt = ''
            $result.Bootstrap.BootstrapFailureReason = ''
            $result.Bootstrap.BootstrapFailureTargetId = ''
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

            $bootstrapResults = @()
            foreach ($bootstrapTargetId in @($SeedTargetId, $partnerTargetId)) {
                $bootstrapResult = Invoke-JsonRelayScript -ScriptPath (Join-Path $root 'tests\Prepare-TypedWindowSession.ps1') -Parameters @{
                    ConfigPath = $resolvedConfigPath
                    RunRoot = $resolvedRunRoot
                    PairId = $PairId
                    TargetId = [string]$bootstrapTargetId
                    AsJson = $true
                }
                $bootstrapResults += @($bootstrapResult)
            }
            $result.Primitives.Bootstrap = @($bootstrapResults)
            $result.Bootstrap = New-TypedWindowBootstrapSummary -BootstrapResults @($bootstrapResults)

            $bootstrapFailure = @($bootstrapResults | Where-Object {
                [string](Get-ResultPropertyValue -Object $_ -Name 'FinalState' -DefaultValue '') -notin @('prepared', 'reused')
            } | Select-Object -First 1)
            if (@($bootstrapFailure).Count -gt 0) {
                $bootstrapFailureReason = ('typed-window bootstrap failed target={0} finalState={1} reason={2}' -f `
                    [string]$result.Bootstrap.BootstrapFailureTargetId, `
                    [string](Get-ResultPropertyValue -Object $bootstrapFailure[0] -Name 'FinalState' -DefaultValue ''), `
                    [string]$result.Bootstrap.BootstrapFailureReason)
                $result.Stage = 'typed-window-bootstrap-failed'
                $result.Outcome = [pscustomobject]@{
                    AcceptanceState = 'manual_attention_required'
                    AcceptanceReason = $bootstrapFailureReason
                }
                Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
                throw $bootstrapFailureReason
            }

            $result.Stage = 'typed-window-bootstrapped'
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        }
    }

    if (-not $preflightOnlyCompleted) {
    $watcherMutexName = [string]$watcherStatusSnapshot.Watcher.MutexName
    if (-not (Test-MutexHeld -Name ([string]$watcherMutexName))) {
        $watcherLaunchMode = 'started'
        $startedWatcher = $true
        $powershellPath = Resolve-PowerShellExecutable
        $watchArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
            '-ConfigPath', $resolvedConfigPath,
            '-RunRoot', $resolvedRunRoot,
            '-PollIntervalMs', [string]$WatcherPollIntervalMs,
            '-RunDurationSec', [string]$WatcherRunDurationSec
        )
        if ($WatcherMaxForwardCount -gt 0) {
            $watchArguments += @('-MaxForwardCount', [string]$WatcherMaxForwardCount)
        }
        if ($WatcherPairMaxRoundtripCount -gt 0) {
            $watchArguments += @('-PairMaxRoundtripCount', [string]$WatcherPairMaxRoundtripCount)
        }
        Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $watcherStdoutLog -RedirectStandardError $watcherStderrLog | Out-Null
    }

    $watcherStatus = Wait-ForWatcherRunning -Root $root -ResolvedConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -TimeoutSeconds $WaitForWatcherSeconds

    $result.Stage = 'watcher-ready'
    $result.Watcher = New-WatcherReceiptSummary `
        -LaunchMode $watcherLaunchMode `
        -StopRequestId $watcherStopRequestId `
        -StopError $watcherStopError `
        -StdoutLogPath $watcherStdoutLog `
        -StderrLogPath $watcherStderrLog `
        -WatcherStatus $watcherStatus.Watcher
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    $initialSeedInboxCount = Get-TargetReadyFileCount -Config $config -TargetId $SeedTargetId
    $initialPartnerInboxCount = Get-TargetReadyFileCount -Config $config -TargetId $partnerTargetId

    $result.Stage = 'submit-running'
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    $submitPrimitive = Invoke-JsonRelayScript -ScriptPath (Join-Path $root 'tests\Invoke-PairedExchangeOneShotSubmit.ps1') -Parameters @{
        ConfigPath = $resolvedConfigPath
        RunRoot = $resolvedRunRoot
        PairId = $PairId
        TargetId = $SeedTargetId
        WaitForPublishSeconds = $SeedWaitForPublishSeconds
        DisallowInlineTypedWindowPrepare = (-not $visibleWorkerEnabled)
        AsJson = $true
    }
    $result.Primitives.Submit = $submitPrimitive
    $seedResult = Get-ResultPropertyValue -Object $submitPrimitive -Name 'Submit' -DefaultValue $submitPrimitive
    if ($visibleWorkerEnabled -and -not [bool]$seedResult.OutboxPublished) {
        $seedStatusRow = @((Get-ResultPropertyValue -Object $submitPrimitive -Name 'PairedTargetStatus' -DefaultValue $null))
        if (@($seedStatusRow).Length -gt 0) {
            $seedResult = Resolve-LateVisibleWorkerSeedResult -SeedResult $seedResult -Row $seedStatusRow[0]
        }
    }

    $result.Stage = 'seed-finished'
    $result.Seed = $seedResult
    if ($visibleWorkerEnabled) {
        $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
    }
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    $result.Stage = 'publish-checking'
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    $publishPrimitive = Invoke-JsonRelayScript -ScriptPath (Join-Path $root 'tests\Confirm-PairedExchangePublishPrimitive.ps1') -Parameters @{
        ConfigPath = $resolvedConfigPath
        RunRoot = $resolvedRunRoot
        PairId = $PairId
        TargetId = $SeedTargetId
        AsJson = $true
    }
    $result.Primitives.Publish = $publishPrimitive
    if (-not [bool]$seedResult.OutboxPublished -and [bool](Get-ResultPropertyValue -Object $publishPrimitive -Name 'PrimitiveSuccess' -DefaultValue $false)) {
        $publishTargetRow = @((Get-ResultPropertyValue -Object $publishPrimitive -Name 'PairedTargetStatus' -DefaultValue $null))
        if (@($publishTargetRow).Length -gt 0) {
            $seedResult = Resolve-LateVisibleWorkerSeedResult -SeedResult $seedResult -Row $publishTargetRow[0]
            $result.Seed = $seedResult
        }
    }

    $result.Stage = 'publish-checked'
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    $publishObserved = ([bool]$seedResult.OutboxPublished -or [bool](Get-ResultPropertyValue -Object $publishPrimitive -Name 'PrimitiveSuccess' -DefaultValue $false))
    if (-not $publishObserved) {
        if ($visibleWorkerEnabled) {
            $result.Stage = 'seed-pending'
            $result.Outcome = [pscustomobject]@{
                AcceptanceState = 'pending'
                AcceptanceReason = "seed publish still pending after visible worker dispatch: finalState=$([string]$seedResult.FinalState) submitState=$([string]$seedResult.SubmitState) publishState=$([string](Get-ResultPropertyValue -Object $publishPrimitive -Name 'PrimitiveState' -DefaultValue '')) publishReason=$([string](Get-ResultPropertyValue -Object $publishPrimitive -Name 'PrimitiveReason' -DefaultValue '')) reason=$([string]$seedResult.SubmitReason)"
            }
            $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        }
        else {
            $seedFailureReason = "seed publish not detected: finalState=$([string]$seedResult.FinalState) submitState=$([string]$seedResult.SubmitState) publishState=$([string](Get-ResultPropertyValue -Object $publishPrimitive -Name 'PrimitiveState' -DefaultValue '')) publishReason=$([string](Get-ResultPropertyValue -Object $publishPrimitive -Name 'PrimitiveReason' -DefaultValue '')) probeState=$([string](Get-ResultPropertyValue -Object $seedResult -Name 'SubmitProbeState' -DefaultValue '')) typedState=$([string](Get-ResultPropertyValue -Object $seedResult -Name 'TypedWindowExecutionState' -DefaultValue '')) sessionState=$([string](Get-ResultPropertyValue -Object $seedResult -Name 'TypedWindowSessionState' -DefaultValue '')) resetReason=$([string](Get-ResultPropertyValue -Object $seedResult -Name 'TypedWindowLastResetReason' -DefaultValue '')) signal=$([string](Get-ResultPropertyValue -Object $seedResult -Name 'SubmitConfirmationSignal' -DefaultValue '')) reason=$([string]$seedResult.SubmitReason)"
            $result.Stage = 'seed-publish-missing'
            $result.Outcome = [pscustomobject]@{
                AcceptanceState = 'error'
                AcceptanceReason = $seedFailureReason
            }
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
            throw $seedFailureReason
        }
    }

    $outcome = Wait-ForLiveAcceptanceOutcome `
        -Root $root `
        -Config $config `
        -PairTest $pairTest `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $resolvedRunRoot `
        -SeedTargetId $SeedTargetId `
        -PartnerTargetId $partnerTargetId `
        -InitialSeedInboxCount $initialSeedInboxCount `
        -InitialPartnerInboxCount $initialPartnerInboxCount `
        -WaitForFirstHandoffSeconds $WaitForFirstHandoffSeconds `
        -WaitForRoundtripSeconds $WaitForRoundtripSeconds `
        -UseVisibleWorker:$visibleWorkerEnabled

    $expectedAcceptanceState = if ($WaitForRoundtripSeconds -gt 0) { 'roundtrip-confirmed' } else { 'first-handoff-confirmed' }
    if ([string]$outcome.AcceptanceState -ne $expectedAcceptanceState) {
        $acceptanceFailureReason = "acceptance outcome mismatch: expected=$expectedAcceptanceState actual=$([string]$outcome.AcceptanceState) reason=$([string]$outcome.AcceptanceReason)"
        $result.Stage = 'acceptance-failed'
        $result.Outcome = $outcome
        if ($visibleWorkerEnabled) {
            $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
        }
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        throw $acceptanceFailureReason
    }

    $result.Stage = 'handoff-checking'
    $result.Outcome = $outcome
    Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

    if ([bool]$result.Closeout.Requested) {
        $result.Stage = 'closeout-running'
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

        $closeoutOutcome = Wait-ForAcceptanceCloseout `
            -Root $root `
            -ResolvedConfigPath $resolvedConfigPath `
            -RunRoot $resolvedRunRoot `
            -AcceptanceForwardedStateCount ([int]$watcherDurationPlan.AcceptanceForwardedStateCount) `
            -CloseoutForwardedStateCount ([int]$watcherDurationPlan.CloseoutForwardedStateCount) `
            -WaitForRoundtripSeconds $WaitForRoundtripSeconds
        $result.Closeout = $closeoutOutcome.Closeout
        if ($null -ne $closeoutOutcome.Status) {
            $outcome.FinalStatus = $closeoutOutcome.Status
        }

        if (-not [bool]$closeoutOutcome.Satisfied) {
            $closeoutFailureReason = "closeout incomplete: reason=$([string]$closeoutOutcome.FailureReason) forwarded=$([int](Get-ResultPropertyValue -Object $result.Closeout -Name 'ObservedForwardedStateCount' -DefaultValue 0)) done=$([int](Get-ResultPropertyValue -Object $result.Closeout -Name 'ObservedDonePresentCount' -DefaultValue 0)) error=$([int](Get-ResultPropertyValue -Object $result.Closeout -Name 'ObservedErrorPresentCount' -DefaultValue 0)) target=$([int](Get-ResultPropertyValue -Object $result.Closeout -Name 'TargetForwardedStateCount' -DefaultValue 0)) watcherStopped=$([bool]$closeoutOutcome.WatcherStopped)"
            $result.Stage = 'closeout-failed'
            $result.Outcome = [pscustomobject]@{
                AcceptanceState = 'error'
                AcceptanceReason = $closeoutFailureReason
                PreviousOutcome = $outcome
            }
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
            throw $closeoutFailureReason
        }

        $result.Stage = 'closeout-completed'
        $result.Outcome = $outcome
        Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
    }

    try {
        $result.Primitives.Handoff = Invoke-JsonRelayScript -ScriptPath (Join-Path $root 'tests\Confirm-PairedExchangeHandoffPrimitive.ps1') -Parameters @{
            ConfigPath = $resolvedConfigPath
            RunRoot = $resolvedRunRoot
            PairId = $PairId
            TargetId = $SeedTargetId
            AsJson = $true
        }
    }
    catch {
        $result.Primitives.Handoff = [pscustomobject]@{
            PrimitiveName = 'handoff-confirm'
            PrimitiveSuccess = $false
            PrimitiveAccepted = $false
            PrimitiveState = 'wrapper-error'
            PrimitiveReason = $_.Exception.Message
            NextPrimitiveAction = ''
            SummaryLine = ''
            PairId = $PairId
            TargetId = $SeedTargetId
            PartnerTargetId = $partnerTargetId
            RunRoot = $resolvedRunRoot
            Evidence = [pscustomobject]@{
                Error = $_.Exception.Message
            }
        }
    }

    $result.Stage = 'completed'
    if (-not $visibleWorkerEnabled) {
        $result.Router = [pscustomobject]@{
            LaunchMode = $routerLaunchMode
            MutexName = $routerMutexName
            Status = [string]$relayStatus.Router.Status
            StateFileStatus = if (Test-NonEmptyString ([string]$routerState.StateFileStatus)) { [string]$routerState.StateFileStatus } else { [string]$relayStatus.Router.Status }
            LastError = [string]$relayStatus.Router.LastError
            MutexHeld = [bool]$relayStatus.Router.MutexHeld
            StatePath = $routerStatePath
            LogPath = $routerLogPath
            StdoutLogPath = if ($null -ne $routerRestartResult -and (Test-NonEmptyString ([string]$routerRestartResult.StdoutLogPath))) { [string]$routerRestartResult.StdoutLogPath } else { $routerStdoutLog }
            StderrLogPath = if ($null -ne $routerRestartResult -and (Test-NonEmptyString ([string]$routerRestartResult.StderrLogPath))) { [string]$routerRestartResult.StderrLogPath } else { $routerStderrLog }
            Restart = $routerRestartResult
        }
    }
    $result.Watcher = New-WatcherReceiptSummary `
        -LaunchMode $watcherLaunchMode `
        -StopRequestId $watcherStopRequestId `
        -StopError $watcherStopError `
        -StdoutLogPath $watcherStdoutLog `
        -StderrLogPath $watcherStderrLog `
        -WatcherStatus $watcherStatus.Watcher
    $result.Seed = $seedResult
    $result.Outcome = $outcome
    if ($visibleWorkerEnabled) {
        $seedStatusRow = @(Get-TargetRow -Status $outcome.FinalStatus -TargetId $SeedTargetId)
        if (@($seedStatusRow).Length -gt 0) {
            $result.Seed = Resolve-LateVisibleWorkerSeedResult -SeedResult $result.Seed -Row $seedStatusRow[0]
        }
        $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
    }
    $result.Closeout = Get-CloseoutStatus `
        -Status $outcome.FinalStatus `
        -AcceptanceForwardedStateCount ([int]$watcherDurationPlan.AcceptanceForwardedStateCount) `
        -CloseoutForwardedStateCount ([int]$watcherDurationPlan.CloseoutForwardedStateCount)
    }
}
catch {
    if ($null -ne $result) {
        if ([string]$result.Stage -notin @('seed-publish-missing', 'acceptance-failed')) {
            $result.Stage = 'failed'
        }
        $previousOutcome = $result.Outcome
        $result.Outcome = [pscustomobject]@{
            AcceptanceState = 'error'
            AcceptanceReason = $_.Exception.Message
            PreviousOutcome = $previousOutcome
        }
        if ($visibleWorkerEnabled) {
            $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
        }
        try {
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        }
        catch {
        }
    }
    throw
}
finally {
    if ($startedWatcher -and -not $KeepWatcherRunning) {
        $watcherAlreadyStopped = $false
        try {
            $finalWatcherStatus = Invoke-ShowPairedStatus -Root $root -ResolvedConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot
            $watcherAlreadyStopped = ([string]$finalWatcherStatus.Watcher.Status -eq 'stopped')
        }
        catch {
            $watcherAlreadyStopped = $false
        }

        if (-not $watcherAlreadyStopped -and -not (Test-NonEmptyString $watcherStopRequestId)) {
            try {
                $watcherStopRequestId = Write-WatcherStopRequest -RunRoot $resolvedRunRoot -RequestedBy 'tests\Run-LiveVisiblePairAcceptance.ps1'
            }
            catch {
                if (-not (Test-NonEmptyString $watcherStopError)) {
                    $watcherStopError = $_.Exception.Message
                }
            }
        }
        if (-not $watcherAlreadyStopped -and (Test-NonEmptyString $watcherStopRequestId)) {
            try {
                [void](Wait-ForWatcherStopped -Root $root -ResolvedConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot -RequestId $watcherStopRequestId -TimeoutSeconds 30)
            }
            catch {
                if (-not (Test-NonEmptyString $watcherStopError)) {
                    $watcherStopError = $_.Exception.Message
                }
            }
        }
    }

    if ($null -ne $result -and $null -ne $result.Watcher) {
        $watcherStopReconciled = $false
        $watcherStopErrorSuppressed = $false
        try {
            $latestWatcherStatus = Invoke-ShowPairedStatus -Root $root -ResolvedConfigPath $resolvedConfigPath -RunRoot $resolvedRunRoot
            if ($null -ne $latestWatcherStatus -and $null -ne $latestWatcherStatus.Watcher) {
                $result.Watcher.Status = $latestWatcherStatus.Watcher
            }
            if (Test-WatcherStopSatisfied -Status $latestWatcherStatus -RequestId $watcherStopRequestId) {
                $watcherStopReconciled = Test-NonEmptyString $watcherStopError
                $watcherStopErrorSuppressed = Test-NonEmptyString $watcherStopError
                $watcherStopError = ''
            }
            $result.Closeout = Get-CloseoutStatus `
                -Status $latestWatcherStatus `
                -AcceptanceForwardedStateCount ([int]$watcherDurationPlan.AcceptanceForwardedStateCount) `
                -CloseoutForwardedStateCount ([int]$watcherDurationPlan.CloseoutForwardedStateCount)
        }
        catch {
        }
        $result.Watcher = New-WatcherReceiptSummary `
            -LaunchMode $watcherLaunchMode `
            -StopRequestId $watcherStopRequestId `
            -StopError $watcherStopError `
            -StdoutLogPath $watcherStdoutLog `
            -StderrLogPath $watcherStderrLog `
            -WatcherStatus $result.Watcher.Status `
            -StopReconciled:$watcherStopReconciled `
            -StopErrorSuppressed:$watcherStopErrorSuppressed
        if ($visibleWorkerEnabled) {
            $result.VisibleWorker = Get-VisibleWorkerSnapshot -PairTest $pairTest -TargetIds @($SeedTargetId, $partnerTargetId)
        }
        try {
            Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result
        }
        catch {
        }
    }
}

Write-AcceptanceReceipt -RunRoot $resolvedRunRoot -ReceiptPath ([string]$result.ReceiptPath) -Result $result

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
}
else {
    $result
}
