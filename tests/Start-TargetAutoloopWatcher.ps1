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

    $null = $parsed = [datetimeoffset]::MinValue
    if (Test-NonEmptyString $Value -and [datetimeoffset]::TryParse($Value, [ref]$parsed)) {
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

$manifestDocument = Read-JsonObject -Path $manifestPath
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
$manifestEnabledTargetIds = New-Object System.Collections.Generic.List[string]
$manifestPublishReadyTargetIds = New-Object System.Collections.Generic.List[string]
$manifestPublishReadyMissingTargetIds = New-Object System.Collections.Generic.List[string]
foreach ($manifestTarget in @(Get-ConfigValue -Object $manifestDocument -Name 'Targets' -DefaultValue @())) {
    $manifestTargetId = [string](Get-ConfigValue -Object $manifestTarget -Name 'TargetId' -DefaultValue '')
    if (-not (Test-NonEmptyString $manifestTargetId)) {
        continue
    }
    if ($selectedTargetLookup.Count -gt 0 -and -not $selectedTargetLookup.ContainsKey($manifestTargetId)) {
        continue
    }
    if (-not [bool](Get-ConfigValue -Object $manifestTarget -Name 'Enabled' -DefaultValue $false)) {
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

$routerSessionState = Get-TargetAutoloopRouterSessionState -Config $config
if ([string]$config.RunMode -eq 'target-autoloop' -and [bool](Get-ConfigValue -Object $routerSessionState -Name 'Mismatch' -DefaultValue $false)) {
    $sessionMessage = New-TargetAutoloopRouterSessionMismatchMessage -RouterSessionState $routerSessionState
    $sessionPayload = [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Ok = $false
        RunMode = [string]$config.RunMode
        RunRoot = $resolvedRunRoot
        Result = 'router-launcher-session-mismatch'
        Message = $sessionMessage
        ReasonCodes = @('router_launcher_session_mismatch')
        ManifestPath = $manifestPath
        StatusPath = [string]$statePaths.StatusPath
        ControlPath = [string]$statePaths.ControlPath
        RuntimeMapPath = [string](Get-ConfigValue -Object $routerSessionState -Name 'RuntimeMapPath' -DefaultValue '')
        RuntimeLauncherSessionId = [string](Get-ConfigValue -Object $routerSessionState -Name 'RuntimeLauncherSessionId' -DefaultValue '')
        RouterStatePath = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterStatePath' -DefaultValue '')
        RouterLauncherSessionId = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterLauncherSessionId' -DefaultValue '')
        RouterStatus = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterStatus' -DefaultValue '')
    }
    if ($AsJson) {
        $sessionPayload | ConvertTo-Json -Depth 12
        return
    }
    $sessionPayload
    return
}

$stateDocument = Read-JsonObject -Path $statePaths.StatePath
$controlDocument = Read-JsonObject -Path $statePaths.ControlPath
$statusDocument = if (Test-Path -LiteralPath $statePaths.StatusPath -PathType Leaf) {
    Read-JsonObject -Path $statePaths.StatusPath
}
else {
    New-TargetAutoloopStatusDocument -Config $config -RunRoot $resolvedRunRoot -StateDocument $stateDocument -ControlDocument $controlDocument
}

$pollIntervalMs = [int](Get-ConfigValue -Object $config -Name 'PollIntervalMs' -DefaultValue 1000)
$watcherFreshWindowSec = [math]::Max(10, [int][math]::Ceiling(($pollIntervalMs * 4) / 1000.0))
$pendingAction = Get-TargetAutoloopPendingControlAction -ControlDocument $controlDocument
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
    $alreadyRunningPayload = [ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        Ok = $false
        RunMode = [string]$config.RunMode
        RunRoot = $resolvedRunRoot
        Result = 'already-running'
        Message = ('target-autoloop watcher가 이미 active 상태입니다: {0}' -f $currentWatcherState)
        ReasonCodes = @('watcher_already_active')
        ControllerState = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue '')
        WatcherState = $currentWatcherState
        HeartbeatAt = [string](Get-ConfigValue -Object $statusDocument -Name 'HeartbeatAt' -DefaultValue '')
        ProcessStartedAt = [string](Get-ConfigValue -Object $statusDocument -Name 'ProcessStartedAt' -DefaultValue '')
        StatusPath = [string]$statePaths.StatusPath
        ControlPath = [string]$statePaths.ControlPath
    }
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
    ControllerState = $controllerState
    ExpectedWatcherState = $expectedWatcherState
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
