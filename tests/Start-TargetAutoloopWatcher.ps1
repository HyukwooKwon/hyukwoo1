[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [ValidateSet('target-inbox-submit', 'target-autoloop')][string]$RunMode = '',
    [string[]]$Targets = @(),
    [int]$RunDurationSec = 0,
    [switch]$DispatchQueuedCommandsInline,
    [switch]$ProcessOnce,
    [switch]$Detached,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Resolve-RequestedRunRootPath {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$RequestedRunRoot = ''
    )

    if (Test-NonEmptyString $RequestedRunRoot) {
        if ([System.IO.Path]::IsPathRooted($RequestedRunRoot)) {
            return [System.IO.Path]::GetFullPath($RequestedRunRoot)
        }

        return [System.IO.Path]::GetFullPath((Join-Path ([string]$Config.Root) $RequestedRunRoot))
    }

    return ''
}

function Get-TargetAutoloopWatcherHostPath {
    $command = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($null -ne $command -and (Test-NonEmptyString ([string]$command.Source))) {
        return [string]$command.Source
    }

    $command = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command -and (Test-NonEmptyString ([string]$command.Source))) {
        return [string]$command.Source
    }

    throw 'pwsh is required to launch target autoloop watcher in detached mode.'
}

function Quote-PowerShellLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    return ("'{0}'" -f (([string]$Value).Replace("'", "''")))
}

function Try-ParseTargetAutoloopStatusDateTime {
    param([string]$Value)

    [datetimeoffset]$parsed = [datetimeoffset]::MinValue
    if ((Test-NonEmptyString $Value) -and [datetimeoffset]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Test-TargetAutoloopWatcherFresh {
    param(
        $StatusDocument,
        [int]$StaleAfterSeconds = 15
    )

    $watcherState = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherState' -DefaultValue '')
    if ($watcherState -notin @('running', 'paused')) {
        return $false
    }

    $timestampText = [string](Get-ConfigValue -Object $StatusDocument -Name 'HeartbeatAt' -DefaultValue '')
    if (-not (Test-NonEmptyString $timestampText)) {
        $timestampText = [string](Get-ConfigValue -Object $StatusDocument -Name 'LastUpdatedAt' -DefaultValue '')
    }
    $timestamp = Try-ParseTargetAutoloopStatusDateTime -Value $timestampText
    if ($null -eq $timestamp) {
        return $false
    }

    return (($timestamp - [datetimeoffset]::Now).TotalSeconds -ge (-1 * [math]::Max(5, $StaleAfterSeconds)))
}

function Get-TargetAutoloopAppliedPendingControlState {
    param(
        [string]$PendingAction,
        $ControlDocument = $null,
        $StatusDocument = $null
    )

    $action = ([string]$PendingAction).Trim().ToLowerInvariant()
    if (-not (Test-NonEmptyString $action)) {
        return ''
    }

    $controllerState = [string](Get-ConfigValue -Object $ControlDocument -Name 'State' -DefaultValue '')
    $watcherState = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherState' -DefaultValue '')
    switch ($action) {
        'stop' {
            if ($controllerState -eq 'stopped' -or $watcherState -eq 'stopped') {
                return 'stopped'
            }
        }
        'pause' {
            if ($controllerState -eq 'paused' -or $watcherState -eq 'paused') {
                return 'paused'
            }
        }
        'resume' {
            if ($controllerState -eq 'running' -or $watcherState -eq 'running') {
                return 'running'
            }
        }
    }

    return ''
}

function New-TargetAutoloopAlreadyRunningPayload {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ResolvedRunRoot,
        [Parameter(Mandatory)]$StatePaths,
        $ControlDocument = $null,
        $StatusDocument = $null,
        [string]$WatcherMutexName = '',
        [string[]]$ReasonCodes = @('watcher_already_active'),
        [string]$Message = '',
        [bool]$ActiveConfirmed = $true
    )

    $currentWatcherState = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherState' -DefaultValue '')
    if (-not (Test-NonEmptyString $Message)) {
        $Message = ('target-autoloop watcher가 이미 active 상태입니다: {0}' -f $currentWatcherState)
    }

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Ok = $ActiveConfirmed
        RunMode = [string]$Config.RunMode
        RunRoot = $ResolvedRunRoot
        Result = 'already-running'
        Message = $Message
        ReasonCodes = @($ReasonCodes)
        Idempotent = $true
        ActiveConfirmed = $ActiveConfirmed
        WatcherMutexHeld = (@($ReasonCodes) -contains 'watcher_mutex_held')
        ControllerState = [string](Get-ConfigValue -Object $ControlDocument -Name 'State' -DefaultValue '')
        WatcherState = $currentWatcherState
        HeartbeatAt = [string](Get-ConfigValue -Object $StatusDocument -Name 'HeartbeatAt' -DefaultValue '')
        ProcessStartedAt = [string](Get-ConfigValue -Object $StatusDocument -Name 'ProcessStartedAt' -DefaultValue '')
        WatcherMutexName = $WatcherMutexName
        WatcherTargetIds = @(Get-StringArray (Get-ConfigValue -Object $StatusDocument -Name 'WatcherTargetIds' -DefaultValue @()))
        WatcherTargetScope = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherTargetScope' -DefaultValue '')
        StatusPath = [string]$StatePaths.StatusPath
        ControlPath = [string]$StatePaths.ControlPath
    }
}

function Get-TargetAutoloopStatusWatcherTargetIds {
    param($StatusDocument)

    return @(
        Get-StringArray (Get-ConfigValue -Object $StatusDocument -Name 'WatcherTargetIds' -DefaultValue @()) |
            Where-Object { Test-NonEmptyString $_ } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
}

function Test-TargetAutoloopWatcherCoversTargets {
    param(
        [string[]]$ActiveTargetIds = @(),
        [string[]]$RequestedTargetIds = @()
    )

    $requested = @(
        $RequestedTargetIds |
            Where-Object { Test-NonEmptyString $_ } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    if (@($requested).Count -eq 0) {
        return $true
    }
    $activeLookup = @{}
    foreach ($targetId in @($ActiveTargetIds)) {
        if (Test-NonEmptyString $targetId) {
            $activeLookup[[string]$targetId] = $true
        }
    }
    if ($activeLookup.Count -eq 0) {
        return $false
    }
    foreach ($targetId in @($requested)) {
        if (-not $activeLookup.ContainsKey([string]$targetId)) {
            return $false
        }
    }
    return $true
}

function New-TargetAutoloopWatcherScopeMismatchPayload {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ResolvedRunRoot,
        [Parameter(Mandatory)]$StatePaths,
        $ControlDocument = $null,
        $StatusDocument = $null,
        [string]$WatcherMutexName = '',
        [string[]]$RequestedTargetIds = @(),
        [string[]]$ActiveTargetIds = @(),
        [bool]$ScopeKnown = $true
    )

    $requested = @(
        $RequestedTargetIds |
            Where-Object { Test-NonEmptyString $_ } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    $active = @(
        $ActiveTargetIds |
            Where-Object { Test-NonEmptyString $_ } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    $result = if ($ScopeKnown) { 'watcher-target-scope-mismatch' } else { 'watcher-target-scope-unknown' }
    $reason = if ($ScopeKnown) { 'watcher_target_scope_mismatch' } else { 'watcher_target_scope_unknown' }
    $activeText = if (@($active).Count -gt 0) { @($active) -join ', ' } else { '(unknown)' }
    $requestedText = if (@($requested).Count -gt 0) { @($requested) -join ', ' } else { '(all)' }
    $message = if ($ScopeKnown) {
        'target-autoloop watcher가 이미 active지만 요청 target 범위를 포함하지 않습니다. activeTargets={0}; requestedTargets={1}. stop 후 해당 target 포함 범위로 재시작하세요.' -f $activeText, $requestedText
    }
    else {
        'target-autoloop watcher가 이미 active지만 감지 대상 범위를 확인할 수 없습니다. requestedTargets={0}. 안전하게 stop 후 해당 target 포함 범위로 재시작하세요.' -f $requestedText
    }

    return [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Ok = $false
        RunMode = [string]$Config.RunMode
        RunRoot = $ResolvedRunRoot
        Result = $result
        Message = $message
        ReasonCodes = @($reason, 'watcher_already_active')
        Idempotent = $false
        ActiveConfirmed = $true
        WatcherMutexHeld = $false
        ControllerState = [string](Get-ConfigValue -Object $ControlDocument -Name 'State' -DefaultValue '')
        WatcherState = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherState' -DefaultValue '')
        HeartbeatAt = [string](Get-ConfigValue -Object $StatusDocument -Name 'HeartbeatAt' -DefaultValue '')
        ProcessStartedAt = [string](Get-ConfigValue -Object $StatusDocument -Name 'ProcessStartedAt' -DefaultValue '')
        WatcherMutexName = $WatcherMutexName
        RequestedTargetIds = @($requested)
        WatcherTargetIds = @($active)
        WatcherTargetScope = [string](Get-ConfigValue -Object $StatusDocument -Name 'WatcherTargetScope' -DefaultValue $(if ($ScopeKnown) { 'scoped' } else { 'unknown' }))
        StatusPath = [string]$StatePaths.StatusPath
        ControlPath = [string]$StatePaths.ControlPath
    }
}

function Test-TargetAutoloopWatcherMutexHeld {
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
        return (-not $acquired)
    }
    finally {
        if ($acquired) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
            }
        }
        try {
            $mutex.Dispose()
        }
        catch {
        }
    }
}

function Get-TargetAutoloopWatcherMutexName {
    param([Parameter(Mandatory)][string]$RunRoot)

    $normalizedRunRoot = Get-NormalizedFullPath -Path $RunRoot
    $hashHex = (Get-TextHashHex -Text $normalizedRunRoot)
    $token = if ($hashHex.Length -ge 24) { $hashHex.Substring(0, 24) } else { $hashHex }
    return ('Global\RelayTargetAutoloop_{0}' -f $token)
}

function Read-TargetAutoloopJsonObjectWithRetry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$RetryCount = 10,
        [int]$RetryDelayMs = 100
    )

    $lastError = $null
    for ($attempt = 0; $attempt -le [math]::Max(0, $RetryCount); $attempt++) {
        try {
            return (Read-JsonObject -Path $Path)
        }
        catch {
            $lastError = $_
            if ($attempt -ge [math]::Max(0, $RetryCount)) {
                break
            }
            Start-Sleep -Milliseconds ([math]::Max(1, $RetryDelayMs))
        }
    }

    throw $lastError
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
if (Test-NonEmptyString $RunMode) {
    if ($config -is [System.Collections.IDictionary]) {
        $config['RunMode'] = $RunMode
    }
    else {
        $config.RunMode = $RunMode
    }
}

$selectedTargets = @(
    $Targets |
        Where-Object { Test-NonEmptyString $_ } |
        ForEach-Object { [string]$_ } |
        Sort-Object -Unique
)

$resolvedRunRoot = Resolve-RequestedRunRootPath -Config $config -RequestedRunRoot $RunRoot
$preparedNewRun = $false
$preparedTargetIds = @()
$manifestPath = ''
$statePaths = $null

if (-not (Test-NonEmptyString $resolvedRunRoot)) {
    try {
        $resolvedRunRoot = Resolve-TargetAutoloopRunRoot -Config $config -RequestedRunRoot ''
    }
    catch {
        $resolvedRunRoot = ''
    }
}

if (Test-NonEmptyString $resolvedRunRoot) {
    $manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
    $statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
}

$watcherMutexName = if (Test-NonEmptyString $resolvedRunRoot) {
    Get-TargetAutoloopWatcherMutexName -RunRoot $resolvedRunRoot
}
else {
    ''
}

$needsPreparation = $false
if (-not (Test-NonEmptyString $resolvedRunRoot)) {
    $needsPreparation = $true
}
elseif (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $needsPreparation = $true
}
elseif ($null -eq $statePaths) {
    $needsPreparation = $true
}
elseif (-not (Test-Path -LiteralPath $statePaths.StatePath -PathType Leaf)) {
    $needsPreparation = $true
}
elseif (-not (Test-Path -LiteralPath $statePaths.ControlPath -PathType Leaf)) {
    $needsPreparation = $true
}

if ($needsPreparation) {
    $startParams = @{
        AsJson = $true
    }
    if (Test-NonEmptyString $ConfigPath) {
        $startParams['ConfigPath'] = $ConfigPath
    }
    if (Test-NonEmptyString $resolvedRunRoot) {
        $startParams['RunRoot'] = $resolvedRunRoot
    }
    if (Test-NonEmptyString $RunMode) {
        $startParams['RunMode'] = $RunMode
    }
    if (@($selectedTargets).Count -gt 0) {
        $startParams['Targets'] = @($selectedTargets)
    }

    $startPayload = & (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') @startParams | ConvertFrom-Json
    $resolvedRunRoot = [string](Get-ConfigValue -Object $startPayload -Name 'RunRoot' -DefaultValue $resolvedRunRoot)
    $manifestPath = [string](Get-ConfigValue -Object $startPayload -Name 'ManifestPath' -DefaultValue (Join-Path $resolvedRunRoot 'manifest.json'))
    $statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
    $preparedNewRun = $true
    $preparedTargetIds = @(
        Get-ConfigValue -Object $startPayload -Name 'TargetIds' -DefaultValue @() |
            Where-Object { Test-NonEmptyString $_ } |
            ForEach-Object { [string]$_ }
    )
}

$watcherMutexName = Get-TargetAutoloopWatcherMutexName -RunRoot $resolvedRunRoot

$manifestDocument = Read-TargetAutoloopJsonObjectWithRetry -Path $manifestPath
$manifestRunMode = [string](Get-ConfigValue -Object $manifestDocument -Name 'RunMode' -DefaultValue '')
if ((Test-NonEmptyString $RunMode) -and (Test-NonEmptyString $manifestRunMode) -and $manifestRunMode -ne [string]$config.RunMode) {
    $mismatchPayload = [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Ok = $false
        RunMode = [string]$config.RunMode
        ExistingRunMode = $manifestRunMode
        RunRoot = $resolvedRunRoot
        Result = 'manifest-runmode-mismatch'
        Message = ('현재 RunRoot manifest RunMode({0})가 요청 RunMode({1})와 달라 watcher 시작을 막았습니다. 새 RunRoot를 준비하세요.' -f $manifestRunMode, [string]$config.RunMode)
        ReasonCodes = @('manifest_run_mode_mismatch')
        ManifestPath = $manifestPath
        StatusPath = [string]$statePaths.StatusPath
        ControlPath = [string]$statePaths.ControlPath
    }
    if ($AsJson) {
        $mismatchPayload | ConvertTo-Json -Depth 12
        return
    }
    $mismatchPayload
    return
}

$selectedTargetLookup = @{}
foreach ($selectedTargetId in @($selectedTargets)) {
    if (Test-NonEmptyString $selectedTargetId) {
        $selectedTargetLookup[[string]$selectedTargetId] = $true
    }
}
$manifestAllEnabledTargetIds = New-Object System.Collections.Generic.List[string]
$manifestEnabledTargetIds = New-Object System.Collections.Generic.List[string]
$manifestPublishReadyTargetIds = New-Object System.Collections.Generic.List[string]
$manifestPublishReadyMissingTargetIds = New-Object System.Collections.Generic.List[string]
foreach ($manifestTarget in @(Get-ConfigValue -Object $manifestDocument -Name 'Targets' -DefaultValue @())) {
    $manifestTargetId = [string](Get-ConfigValue -Object $manifestTarget -Name 'TargetId' -DefaultValue '')
    if (-not (Test-NonEmptyString $manifestTargetId)) {
        continue
    }
    $manifestTargetEnabled = [bool](Get-ConfigValue -Object $manifestTarget -Name 'Enabled' -DefaultValue $false)
    if (-not $manifestTargetEnabled) {
        continue
    }
    $manifestAllEnabledTargetIds.Add($manifestTargetId) | Out-Null
    if ($selectedTargetLookup.Count -gt 0 -and -not $selectedTargetLookup.ContainsKey($manifestTargetId)) {
        continue
    }
    $manifestEnabledTargetIds.Add($manifestTargetId) | Out-Null
    $manifestTriggerKinds = @(Get-StringArray (Get-ConfigValue -Object $manifestTarget -Name 'TriggerKinds' -DefaultValue @()))
    if ($manifestTriggerKinds -contains 'publish-ready') {
        $manifestPublishReadyTargetIds.Add($manifestTargetId) | Out-Null
    }
    else {
        $manifestPublishReadyMissingTargetIds.Add($manifestTargetId) | Out-Null
    }
}
if ([string]$config.RunMode -eq 'target-autoloop' -and @($manifestPublishReadyMissingTargetIds).Count -gt 0) {
    $triggerPayload = [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Ok = $false
        RunMode = [string]$config.RunMode
        RunRoot = $resolvedRunRoot
        Result = 'publish-ready-trigger-missing'
        Message = ('publish-ready 트리거가 꺼진 enabled target이 있어 watcher 시작을 막았습니다: {0}. 8 Cell Autoloop 탭에서 publish-ready를 켜고 저장한 뒤 새 RunRoot를 준비하세요.' -f (@($manifestPublishReadyMissingTargetIds) -join ', '))
        ReasonCodes = @('publish_ready_trigger_missing')
        ManifestPath = $manifestPath
        EnabledTargetIds = $manifestEnabledTargetIds.ToArray()
        PublishReadyTargetIds = $manifestPublishReadyTargetIds.ToArray()
        PublishReadyMissingTargetIds = $manifestPublishReadyMissingTargetIds.ToArray()
        StatusPath = [string]$statePaths.StatusPath
        ControlPath = [string]$statePaths.ControlPath
    }
    if ($AsJson) {
        $triggerPayload | ConvertTo-Json -Depth 12
        return
    }
    $triggerPayload
    return
}

$requestedWatcherTargetIds = if (@($selectedTargets).Count -gt 0) {
    @($selectedTargets)
}
else {
    @($manifestEnabledTargetIds.ToArray())
}

$routerSessionState = Get-TargetAutoloopRouterSessionState -Config $config
$routerSessionStateName = [string](Get-ConfigValue -Object $routerSessionState -Name 'State' -DefaultValue '')
$routerSessionMismatch = [bool](Get-ConfigValue -Object $routerSessionState -Name 'Mismatch' -DefaultValue $false)
if ([string]$config.RunMode -eq 'target-autoloop' -and $routerSessionStateName -ne 'ok') {
    $sessionMessage = New-TargetAutoloopRouterSessionNotReadyMessage -RouterSessionState $routerSessionState
    $sessionResult = if ($routerSessionMismatch) { 'router-launcher-session-mismatch' } elseif (Test-NonEmptyString $routerSessionStateName) { $routerSessionStateName } else { 'router-session-not-ready' }
    $sessionReasonCode = if ($routerSessionMismatch) { 'router_launcher_session_mismatch' } else { ('router_session_' + ($sessionResult -replace '[^A-Za-z0-9]+', '_').Trim('_').ToLowerInvariant()) }
    $sessionPayload = [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Ok = $false
        RunMode = [string]$config.RunMode
        RunRoot = $resolvedRunRoot
        Result = $sessionResult
        Message = $sessionMessage
        ReasonCodes = @($sessionReasonCode)
        ManifestPath = $manifestPath
        StatusPath = [string]$statePaths.StatusPath
        ControlPath = [string]$statePaths.ControlPath
        RuntimeMapPath = [string](Get-ConfigValue -Object $routerSessionState -Name 'RuntimeMapPath' -DefaultValue '')
        RuntimeLauncherSessionId = [string](Get-ConfigValue -Object $routerSessionState -Name 'RuntimeLauncherSessionId' -DefaultValue '')
        RouterStatePath = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterStatePath' -DefaultValue '')
        RouterLauncherSessionId = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterLauncherSessionId' -DefaultValue '')
        RouterStatus = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterStatus' -DefaultValue '')
        RouterSessionState = $routerSessionStateName
        RouterPid = [int](Get-ConfigValue -Object $routerSessionState -Name 'RouterPid' -DefaultValue 0)
        RouterPidExists = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterPidExists' -DefaultValue $false)
        RouterMutexName = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterMutexName' -DefaultValue '')
        RouterMutexHeld = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterMutexHeld' -DefaultValue $false)
    }
    if ($AsJson) {
        $sessionPayload | ConvertTo-Json -Depth 12
        return
    }
    $sessionPayload
    return
}

$stateDocument = Read-TargetAutoloopJsonObjectWithRetry -Path $statePaths.StatePath
$controlDocument = Read-TargetAutoloopJsonObjectWithRetry -Path $statePaths.ControlPath
$statusDocument = if (Test-Path -LiteralPath $statePaths.StatusPath -PathType Leaf) {
    Read-TargetAutoloopJsonObjectWithRetry -Path $statePaths.StatusPath
}
else {
    New-TargetAutoloopStatusDocument -Config $config -RunRoot $resolvedRunRoot -StateDocument $stateDocument -ControlDocument $controlDocument
}

$pollIntervalMs = [int](Get-ConfigValue -Object $config -Name 'PollIntervalMs' -DefaultValue 1000)
$watcherFreshWindowSec = [math]::Max(10, [int][math]::Ceiling(($pollIntervalMs * 4) / 1000.0))
$pendingAction = Get-TargetAutoloopPendingControlAction -ControlDocument $controlDocument
$reconciledControlAction = ''
$reconciledControlState = ''
if (Test-NonEmptyString $pendingAction) {
    $appliedControlState = Get-TargetAutoloopAppliedPendingControlState `
        -PendingAction $pendingAction `
        -ControlDocument $controlDocument `
        -StatusDocument $statusDocument
    if (Test-NonEmptyString $appliedControlState) {
        $reconciledControlAction = $pendingAction
        $reconciledControlState = $appliedControlState
        Complete-TargetAutoloopControlAction `
            -ControlDocument $controlDocument `
            -State $appliedControlState `
            -Result ('reconciled-{0}' -f $appliedControlState)
        $timestamp = (Get-Date).ToString('o')
        $stateDocument.State = $appliedControlState
        $stateDocument.LastUpdatedAt = $timestamp
        $controlDocument.LastUpdatedAt = $timestamp
        $statusDocument.ControllerState = $appliedControlState
        $statusDocument.LastUpdatedAt = $timestamp
        Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
        Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
        Write-JsonFileAtomically -Path $statePaths.StatusPath -Payload $statusDocument
        Sync-TargetAutoloopTargetSidecarDocuments `
            -Config $config `
            -RunRoot $resolvedRunRoot `
            -StateDocument $stateDocument `
            -ControlDocument $controlDocument `
            -StatusDocument $statusDocument
        $pendingAction = Get-TargetAutoloopPendingControlAction -ControlDocument $controlDocument
    }
}
if (Test-NonEmptyString $pendingAction) {
    $pendingPayload = [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Ok = $false
        RunMode = [string]$config.RunMode
        RunRoot = $resolvedRunRoot
        Result = 'control-pending'
        Message = ('target-autoloop 제어 요청({0})이 아직 처리 중이라 watcher 시작을 막았습니다.' -f $pendingAction)
        ReasonCodes = @('control_pending_action_exists')
        ControllerState = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue '')
        WatcherState = [string](Get-ConfigValue -Object $statusDocument -Name 'WatcherState' -DefaultValue '')
        StatusPath = [string]$statePaths.StatusPath
        ControlPath = [string]$statePaths.ControlPath
    }
    if ($AsJson) {
        $pendingPayload | ConvertTo-Json -Depth 12
        return
    }
    $pendingPayload
    return
}

$currentWatcherState = [string](Get-ConfigValue -Object $statusDocument -Name 'WatcherState' -DefaultValue '')
if (Test-TargetAutoloopWatcherFresh -StatusDocument $statusDocument -StaleAfterSeconds $watcherFreshWindowSec) {
    $activeTargetIds = @(Get-TargetAutoloopStatusWatcherTargetIds -StatusDocument $statusDocument)
    if (@($requestedWatcherTargetIds).Count -gt 0 -and -not (Test-TargetAutoloopWatcherCoversTargets -ActiveTargetIds @($activeTargetIds) -RequestedTargetIds @($requestedWatcherTargetIds))) {
        $scopeMismatchPayload = New-TargetAutoloopWatcherScopeMismatchPayload `
            -Config $config `
            -ResolvedRunRoot $resolvedRunRoot `
            -StatePaths $statePaths `
            -ControlDocument $controlDocument `
            -StatusDocument $statusDocument `
            -WatcherMutexName $watcherMutexName `
            -RequestedTargetIds @($requestedWatcherTargetIds) `
            -ActiveTargetIds @($activeTargetIds) `
            -ScopeKnown (@($activeTargetIds).Count -gt 0)
        if ($AsJson) {
            $scopeMismatchPayload | ConvertTo-Json -Depth 12
            return
        }
        $scopeMismatchPayload
        return
    }
    $alreadyRunningPayload = New-TargetAutoloopAlreadyRunningPayload `
        -Config $config `
        -ResolvedRunRoot $resolvedRunRoot `
        -StatePaths $statePaths `
        -ControlDocument $controlDocument `
        -StatusDocument $statusDocument `
        -WatcherMutexName $watcherMutexName `
        -ReasonCodes @('watcher_already_active')
    if ($AsJson) {
        $alreadyRunningPayload | ConvertTo-Json -Depth 12
        return
    }
    $alreadyRunningPayload
    return
}

$controllerState = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue 'running')
$restoredTargetIds = New-Object System.Collections.Generic.List[string]
if ($controllerState -eq 'stopped') {
    $stateMap = Get-TargetAutoloopTargetStateMap -StateDocument $stateDocument
    foreach ($targetId in @($stateMap.Keys)) {
        if ($selectedTargetLookup.Count -gt 0 -and -not $selectedTargetLookup.ContainsKey([string]$targetId)) {
            continue
        }
        $entry = $stateMap[$targetId]
        $entryPhase = [string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '')
        $stoppedPhase = [string](Get-ConfigValue -Object $entry -Name 'StoppedPhase' -DefaultValue '')
        $stoppedNextAction = [string](Get-ConfigValue -Object $entry -Name 'StoppedNextAction' -DefaultValue '')
        if ($entryPhase -eq 'stopped' -or (Test-NonEmptyString $stoppedPhase) -or (Test-NonEmptyString $stoppedNextAction)) {
            Restore-TargetAutoloopStoppedEntryState -Entry $entry
            $restoredTargetIds.Add([string]$targetId) | Out-Null
        }
    }
    Set-TargetAutoloopTargetStateMap -TargetStateMap $stateMap -StateDocument $stateDocument
    Clear-TargetAutoloopControlPendingAction -ControlDocument $controlDocument
    $controllerState = 'running'
    $controlDocument.State = 'running'
    $stateDocument.State = 'running'
    $timestamp = (Get-Date).ToString('o')
    $stateDocument.LastUpdatedAt = $timestamp
    $controlDocument.LastUpdatedAt = $timestamp
    Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
    Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
    $statusDocument = New-TargetAutoloopStatusDocument `
        -Config $config `
        -RunRoot $resolvedRunRoot `
        -StateDocument $stateDocument `
        -ControlDocument $controlDocument `
        -WatcherState 'stopped' `
        -WatcherStopReason 'restart-requested'
    Write-JsonFileAtomically -Path $statePaths.StatusPath -Payload $statusDocument
    Sync-TargetAutoloopTargetSidecarDocuments `
        -Config $config `
        -RunRoot $resolvedRunRoot `
        -StateDocument $stateDocument `
        -ControlDocument $controlDocument `
        -StatusDocument $statusDocument
}

$expectedWatcherState = if ($controllerState -eq 'paused') { 'paused' } else { 'running' }
$watcherScriptPath = Join-Path $root 'tests\Watch-TargetAutoloop.ps1'
$watcherArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watcherScriptPath)
$watcherInvokeParams = @{}
if (Test-NonEmptyString $ConfigPath) {
    $watcherArgs += @('-ConfigPath', $ConfigPath)
    $watcherInvokeParams.ConfigPath = $ConfigPath
}
$watcherArgs += @('-RunRoot', $resolvedRunRoot, '-RunDurationSec', [string]$RunDurationSec)
$watcherInvokeParams.RunRoot = $resolvedRunRoot
$watcherInvokeParams.RunDurationSec = $RunDurationSec
if (@($selectedTargets).Count -gt 0) {
    $watcherArgs += '-Targets'
    $watcherArgs += @($selectedTargets)
    $watcherInvokeParams.Targets = @($selectedTargets)
}
if ($PSBoundParameters.ContainsKey('DispatchQueuedCommandsInline')) {
    $watcherArgs += '-DispatchQueuedCommandsInline'
    $watcherInvokeParams.DispatchQueuedCommandsInline = $true
}
if ($ProcessOnce) {
    $watcherArgs += '-ProcessOnce'
    $watcherInvokeParams.ProcessOnce = $true
}

$result = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    Ok = $true
    RunMode = [string]$config.RunMode
    RunRoot = $resolvedRunRoot
    Result = if ($Detached) { 'launch-requested' } else { 'completed-inline' }
    Message = if ($Detached) { 'target-autoloop watcher launch를 요청했습니다.' } else { 'target-autoloop watcher inline 실행이 완료되었습니다.' }
    ReasonCodes = @()
    PreparedNewRun = $preparedNewRun
    PreparedTargetIds = @($preparedTargetIds)
    RestoredTargetIds = $restoredTargetIds.ToArray()
    ReconciledControlAction = $reconciledControlAction
    ReconciledControlState = $reconciledControlState
    ControllerState = $controllerState
    ExpectedWatcherState = $expectedWatcherState
    WatcherTargetIds = @($requestedWatcherTargetIds)
    WatcherTargetScope = if (@($requestedWatcherTargetIds).Count -gt 0 -and @($requestedWatcherTargetIds).Count -lt @($manifestAllEnabledTargetIds.ToArray()).Count) { 'scoped' } else { 'all' }
    StatusPath = [string]$statePaths.StatusPath
    ControlPath = [string]$statePaths.ControlPath
    StatePath = [string]$statePaths.StatePath
    WatcherScriptPath = $watcherScriptPath
}

if ($Detached) {
    $stateRoot = [string]$statePaths.StateRoot
    Ensure-Directory -Path $stateRoot
    $stdoutLogPath = Join-Path $stateRoot 'target-autoloop-watcher.stdout.log'
    $stderrLogPath = Join-Path $stateRoot 'target-autoloop-watcher.stderr.log'
    $launcherPath = Join-Path $stateRoot 'target-autoloop-watcher.launch.ps1'
    $pwshPath = Get-TargetAutoloopWatcherHostPath
    if (Test-TargetAutoloopWatcherMutexHeld -Name $watcherMutexName) {
        $latestStatusDocument = if (Test-Path -LiteralPath $statePaths.StatusPath -PathType Leaf) {
            Read-TargetAutoloopJsonObjectWithRetry -Path $statePaths.StatusPath
        }
        else {
            $statusDocument
        }
        $reasonCodes = @('watcher_mutex_held')
        $message = ('target-autoloop watcher mutex가 이미 사용 중입니다: {0}' -f $watcherMutexName)
        $activeConfirmed = Test-TargetAutoloopWatcherFresh -StatusDocument $latestStatusDocument -StaleAfterSeconds $watcherFreshWindowSec
        if ($activeConfirmed) {
            $activeTargetIds = @(Get-TargetAutoloopStatusWatcherTargetIds -StatusDocument $latestStatusDocument)
            if (@($requestedWatcherTargetIds).Count -gt 0 -and -not (Test-TargetAutoloopWatcherCoversTargets -ActiveTargetIds @($activeTargetIds) -RequestedTargetIds @($requestedWatcherTargetIds))) {
                $scopeMismatchPayload = New-TargetAutoloopWatcherScopeMismatchPayload `
                    -Config $config `
                    -ResolvedRunRoot $resolvedRunRoot `
                    -StatePaths $statePaths `
                    -ControlDocument $controlDocument `
                    -StatusDocument $latestStatusDocument `
                    -WatcherMutexName $watcherMutexName `
                    -RequestedTargetIds @($requestedWatcherTargetIds) `
                    -ActiveTargetIds @($activeTargetIds) `
                    -ScopeKnown (@($activeTargetIds).Count -gt 0)
                if ($AsJson) {
                    $scopeMismatchPayload | ConvertTo-Json -Depth 12
                    return
                }
                $scopeMismatchPayload
                return
            }
            $reasonCodes = @('watcher_already_active', 'watcher_mutex_held')
            $message = ('target-autoloop watcher가 이미 active 상태입니다: {0}' -f ([string](Get-ConfigValue -Object $latestStatusDocument -Name 'WatcherState' -DefaultValue '')))
        }
        $alreadyRunningPayload = New-TargetAutoloopAlreadyRunningPayload `
            -Config $config `
            -ResolvedRunRoot $resolvedRunRoot `
            -StatePaths $statePaths `
            -ControlDocument $controlDocument `
            -StatusDocument $latestStatusDocument `
            -WatcherMutexName $watcherMutexName `
            -ReasonCodes $reasonCodes `
            -Message $message `
            -ActiveConfirmed $activeConfirmed
        if ($AsJson) {
            $alreadyRunningPayload | ConvertTo-Json -Depth 12
            return
        }
        $alreadyRunningPayload
        return
    }
    $watcherCommandLine = @(
        '&',
        (Quote-PowerShellLiteral -Value $pwshPath)
    ) + @(
        $watcherArgs | ForEach-Object { Quote-PowerShellLiteral -Value ([string]$_) }
    )
    $launcherText = @(
        '$ErrorActionPreference = ''Stop''',
        ('$stdoutLogPath = {0}' -f (Quote-PowerShellLiteral -Value $stdoutLogPath)),
        ('$stderrLogPath = {0}' -f (Quote-PowerShellLiteral -Value $stderrLogPath)),
        'try {',
        ('    {0} 1> $stdoutLogPath 2> $stderrLogPath' -f ($watcherCommandLine -join ' ')),
        '    if ($null -ne $global:LASTEXITCODE) { exit $global:LASTEXITCODE }',
        '    exit 0',
        '}',
        'catch {',
        '    $message = ($_ | Out-String)',
        '    [System.IO.File]::AppendAllText($stderrLogPath, $message)',
        '    exit 1',
        '}'
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($launcherPath, $launcherText, (New-Utf8NoBomEncoding))
    $process = Start-Process `
        -FilePath $pwshPath `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcherPath) `
        -WindowStyle Hidden `
        -PassThru
    Start-Sleep -Milliseconds 350
    try {
        $process.Refresh()
    }
    catch {
    }
    if ($process.HasExited -and -not $ProcessOnce) {
        $stderrText = ''
        if (Test-Path -LiteralPath $stderrLogPath -PathType Leaf) {
            try {
                $stderrText = (Get-Content -LiteralPath $stderrLogPath -Raw -Encoding UTF8).Trim()
            }
            catch {
            }
        }
        throw ('target-autoloop watcher exited immediately: exitCode={0} stderrLog={1}{2}' -f `
                $process.ExitCode, `
                $stderrLogPath, `
                $(if (Test-NonEmptyString $stderrText) { " stderr=$stderrText" } else { '' }))
    }
    $result.WatcherProcessId = [int]$process.Id
    $result.WatcherStdoutLogPath = $stdoutLogPath
    $result.WatcherStderrLogPath = $stderrLogPath
    $result.WatcherLauncherPath = $launcherPath
}
else {
    $watcherInvokeParams.AsJson = $true
    $watcherPayload = & $watcherScriptPath @watcherInvokeParams | ConvertFrom-Json
    $result.WatcherResult = $watcherPayload
    $result.WatcherState = [string](Get-ConfigValue -Object $watcherPayload -Name 'WatcherState' -DefaultValue 'stopped')
    $result.WatcherStopReason = [string](Get-ConfigValue -Object $watcherPayload -Name 'WatcherStopReason' -DefaultValue '')
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 12
    return
}

$result
