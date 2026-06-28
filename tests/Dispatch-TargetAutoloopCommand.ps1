[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [string]$CommandPath,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TargetAutoloopConfig.ps1')
. (Join-Path $PSScriptRoot 'lib\RelayTargetFolderPreflight.ps1')

function Get-DefaultConfigPath {
    param([Parameter(Mandatory)][string]$Root)

    $preferred = Join-Path $Root 'config\settings.bottest-live-visible.psd1'
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    return (Join-Path $Root 'config\settings.psd1')
}

function Convert-ProducerOutputToRawText {
    param([Parameter(Mandatory)][object[]]$ProducerOutput)

    $lines = @(
        $ProducerOutput |
            ForEach-Object { [string]$_ }
    )
    return (($lines -join [Environment]::NewLine).Trim())
}

function Invoke-TargetAutoloopProducerReadyFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$PromptFilePath
    )

    $promptText = Get-Content -LiteralPath $PromptFilePath -Raw -Encoding UTF8
    if (-not (Test-NonEmptyString $promptText)) {
        throw "target autoloop prompt file is empty: $PromptFilePath"
    }

    $producerScriptPath = Join-Path $Root 'producer-example.ps1'
    $producerOutput = & {
        & $producerScriptPath `
            -ConfigPath $ConfigPath `
            -TargetId $TargetId `
            -Text $promptText
    } 6>&1

    $producerRaw = Convert-ProducerOutputToRawText -ProducerOutput @($producerOutput)
    if ([string]::IsNullOrWhiteSpace($producerRaw)) {
        throw "producer returned no output for target autoloop target: $TargetId"
    }

    $readyPath = ''
    $match = [regex]::Match($producerRaw, 'created ready file:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        $readyPath = [string]$match.Groups[1].Value.Trim()
    }
    if (-not (Test-NonEmptyString $readyPath)) {
        throw ("producer ready path not found in output: " + $producerRaw)
    }

    return [pscustomobject]@{
        ReadyPath = $readyPath
        ProducerOutput = $producerRaw
    }
}

function Move-CommandToArchive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    Ensure-Directory -Path $DestinationRoot
    $destination = Join-Path $DestinationRoot ([System.IO.Path]::GetFileName($Path))
    Move-Item -LiteralPath $Path -Destination $destination -Force
    return $destination
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
$resolvedRunRoot = if ([System.IO.Path]::IsPathRooted($RunRoot)) {
    [System.IO.Path]::GetFullPath($RunRoot)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $root $RunRoot))
}
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
$stateDocument = Read-JsonObject -Path $statePaths.StatePath
$controlDocument = Read-JsonObject -Path $statePaths.ControlPath
$stateMap = Get-TargetAutoloopTargetStateMap -StateDocument $stateDocument
$entry = Get-ConfigValue -Object $stateMap -Name $TargetId -DefaultValue $null
if ($null -eq $entry) {
    throw "target not found in target-autoloop state: $TargetId"
}

$targetConfig = @($config.Targets | Where-Object { [string](Get-ConfigValue -Object $_ -Name 'TargetId' -DefaultValue '') -eq $TargetId } | Select-Object -First 1)
if (@($targetConfig).Count -eq 0) {
    throw "target autoloop target config not found: $TargetId"
}

$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "target autoloop manifest not found: $manifestPath"
}
$manifest = Read-JsonObject -Path $manifestPath
$targetRow = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq $TargetId } | Select-Object -First 1)
if (@($targetRow).Count -eq 0) {
    throw "target not found in target autoloop manifest: $TargetId"
}

$queuePaths = Get-TargetAutoloopQueuePaths -RunRoot $resolvedRunRoot -TargetId $TargetId -Target $targetRow[0] -Config $config
$queuePaths = Use-TargetAutoloopManifestQueuePaths -Paths $queuePaths -ManifestTarget $targetRow[0]
foreach ($queuePath in @($queuePaths.QueuedRoot, $queuePaths.ProcessingRoot, $queuePaths.CompletedRoot, $queuePaths.FailedRoot)) {
    Ensure-Directory -Path $queuePath
}

$resolvedCommandPath = ''
if (Test-NonEmptyString $CommandPath) {
    $resolvedCommandPath = (Resolve-Path -LiteralPath $CommandPath).Path
}
else {
    $firstQueued = Get-ChildItem -LiteralPath $queuePaths.QueuedRoot -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, Name |
        Select-Object -First 1
    if ($null -eq $firstQueued) {
        $result = [pscustomobject]@{
            SchemaVersion = $script:TargetAutoloopSchemaVersion
            RunRoot = $resolvedRunRoot
            TargetId = $TargetId
            State = 'no-command'
            ReadyPath = ''
            CommandPath = ''
        }
        if ($AsJson) {
            $result | ConvertTo-Json -Depth 8
            return
        }
        $result
        return
    }

    $resolvedCommandPath = $firstQueued.FullName
}

$routerSessionState = Get-TargetAutoloopRouterSessionState -Config $config
$routerSessionStateName = [string](Get-ConfigValue -Object $routerSessionState -Name 'State' -DefaultValue '')
$routerSessionMismatch = [bool](Get-ConfigValue -Object $routerSessionState -Name 'Mismatch' -DefaultValue $false)
$routerSessionBlocksDispatch = $routerSessionMismatch -or ([string]$config.RunMode -eq 'target-autoloop' -and $routerSessionStateName -ne 'ok')
if ($routerSessionBlocksDispatch) {
    $queuedCommandPreview = Read-JsonObject -Path $resolvedCommandPath
    $blockedCommandId = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'CommandId' -DefaultValue '')
    $blockedTriggerKind = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'TriggerKind' -DefaultValue '')
    $blockedTriggerFingerprint = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'TriggerFingerprint' -DefaultValue '')
    $blockedLoopSource = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'LoopSource' -DefaultValue '')
    $blockedCycleId = [int](Get-ConfigValue -Object $queuedCommandPreview -Name 'CycleId' -DefaultValue 0)
    $blockMessage = New-TargetAutoloopRouterSessionNotReadyMessage -RouterSessionState $routerSessionState
    $dispatchState = if ($routerSessionMismatch) { 'router-session-mismatch' } else { 'router-session-not-ready' }
    $resultState = if ($routerSessionMismatch) { 'blocked-by-router-session-mismatch' } else { 'blocked-by-router-session-not-ready' }
    $blockReason = if ($routerSessionMismatch) { 'router-launcher-session-mismatch' } elseif (Test-NonEmptyString $routerSessionStateName) { $routerSessionStateName } else { 'router-session-not-ready' }

    $entry.Phase = 'queued'
    $entry.NextAction = 'dispatch-command'
    $entry.LastDispatchAt = (Get-Date).ToString('o')
    $entry.LastDispatchState = $dispatchState
    $entry.LastCommandPath = $resolvedCommandPath
    $entry.LastFailureReason = $blockMessage
    $entry.LastProgressSignalAt = (Get-Date).ToString('o')
    Set-TargetAutoloopTargetStateMap -TargetStateMap $stateMap -StateDocument $stateDocument
    $stateDocument.LastUpdatedAt = (Get-Date).ToString('o')
    Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
    $statusDocument = New-TargetAutoloopStatusDocument -Config $config -RunRoot $resolvedRunRoot -StateDocument $stateDocument -ControlDocument $controlDocument
    Write-JsonFileAtomically -Path $statePaths.StatusPath -Payload $statusDocument

    Append-TargetAutoloopEvent -Path $statePaths.EventsPath -EventType 'dispatch-blocked' -TargetId $TargetId -TriggerKind $blockedTriggerKind -TriggerFingerprint $blockedTriggerFingerprint -Extra @{
        CommandId = $blockedCommandId
        CommandPath = $resolvedCommandPath
        CycleId = $blockedCycleId
        LoopSource = $blockedLoopSource
        BlockReason = $blockReason
        RouterSessionState = $routerSessionStateName
        RouterLauncherSessionId = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterLauncherSessionId' -DefaultValue '')
        RuntimeLauncherSessionId = [string](Get-ConfigValue -Object $routerSessionState -Name 'RuntimeLauncherSessionId' -DefaultValue '')
        RouterPid = [int](Get-ConfigValue -Object $routerSessionState -Name 'RouterPid' -DefaultValue 0)
        RouterPidExists = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterPidExists' -DefaultValue $false)
        RouterMutexName = [string](Get-ConfigValue -Object $routerSessionState -Name 'RouterMutexName' -DefaultValue '')
        RouterMutexHeld = [bool](Get-ConfigValue -Object $routerSessionState -Name 'RouterMutexHeld' -DefaultValue $false)
    }

    $sessionBlockedResult = [pscustomobject][ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        RunRoot = $resolvedRunRoot
        TargetId = $TargetId
        CommandId = $blockedCommandId
        CommandPath = $resolvedCommandPath
        TriggerKind = $blockedTriggerKind
        TriggerFingerprint = $blockedTriggerFingerprint
        LoopSource = $blockedLoopSource
        CycleId = $blockedCycleId
        State = $resultState
        BlockReason = $blockReason
        Message = $blockMessage
        ReadyPath = ''
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
        $sessionBlockedResult | ConvertTo-Json -Depth 10
        return
    }

    $sessionBlockedResult
    return
}

$controllerState = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue 'running')
$controlPendingAction = [string](Get-TargetAutoloopPendingControlAction -ControlDocument $controlDocument)
$dispatchBlockedByController = (Test-NonEmptyString $controlPendingAction) -or ($controllerState -ne 'running')
if ($dispatchBlockedByController) {
    $queuedCommandPreview = Read-JsonObject -Path $resolvedCommandPath
    $blockedCommandId = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'CommandId' -DefaultValue '')
    $blockedTriggerKind = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'TriggerKind' -DefaultValue '')
    $blockedTriggerFingerprint = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'TriggerFingerprint' -DefaultValue '')
    $blockedLoopSource = [string](Get-ConfigValue -Object $queuedCommandPreview -Name 'LoopSource' -DefaultValue '')
    $blockedCycleId = [int](Get-ConfigValue -Object $queuedCommandPreview -Name 'CycleId' -DefaultValue 0)
    $blockReason = if (Test-NonEmptyString $controlPendingAction) {
        'control-pending'
    }
    elseif ($controllerState -eq 'paused') {
        'watcher-paused'
    }
    elseif ($controllerState -eq 'stopped') {
        'watcher-stopped'
    }
    else {
        'controller-not-running'
    }
    $blockMessage = if (Test-NonEmptyString $controlPendingAction) {
        ('queued target-autoloop command dispatch is blocked while control action is pending: {0}' -f $controlPendingAction)
    }
    else {
        ('queued target-autoloop command dispatch is blocked while controller state is {0}' -f $controllerState)
    }

    Append-TargetAutoloopEvent -Path $statePaths.EventsPath -EventType 'dispatch-blocked' -TargetId $TargetId -TriggerKind $blockedTriggerKind -TriggerFingerprint $blockedTriggerFingerprint -Extra @{
        CommandId = $blockedCommandId
        CommandPath = $resolvedCommandPath
        CycleId = $blockedCycleId
        LoopSource = $blockedLoopSource
        ControllerState = $controllerState
        ControlPendingAction = $controlPendingAction
        BlockReason = $blockReason
    }

    $blockedResult = [pscustomobject][ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        RunRoot = $resolvedRunRoot
        TargetId = $TargetId
        CommandId = $blockedCommandId
        CommandPath = $resolvedCommandPath
        TriggerKind = $blockedTriggerKind
        TriggerFingerprint = $blockedTriggerFingerprint
        LoopSource = $blockedLoopSource
        CycleId = $blockedCycleId
        State = 'blocked-by-controller'
        ControllerState = $controllerState
        ControlPendingAction = $controlPendingAction
        BlockReason = $blockReason
        Message = $blockMessage
        ReadyPath = ''
    }

    if ($AsJson) {
        $blockedResult | ConvertTo-Json -Depth 10
        return
    }

    $blockedResult
    return
}

$processingPath = Move-CommandToArchive -Path $resolvedCommandPath -DestinationRoot ([string]$queuePaths.ProcessingRoot)
$command = Read-JsonObject -Path $processingPath
if ([string](Get-ConfigValue -Object $command -Name 'TargetId' -DefaultValue '') -ne $TargetId) {
    throw "target autoloop command target mismatch: expected=$TargetId actual=$([string](Get-ConfigValue -Object $command -Name 'TargetId' -DefaultValue ''))"
}

$commandId = [string](Get-ConfigValue -Object $command -Name 'CommandId' -DefaultValue '')
$promptFilePath = [string](Get-ConfigValue -Object $command -Name 'PromptFilePath' -DefaultValue '')
$triggerKind = [string](Get-ConfigValue -Object $command -Name 'TriggerKind' -DefaultValue '')
$triggerFingerprint = [string](Get-ConfigValue -Object $command -Name 'TriggerFingerprint' -DefaultValue '')
$loopSource = [string](Get-ConfigValue -Object $command -Name 'LoopSource' -DefaultValue '')
$cycleId = [int](Get-ConfigValue -Object $command -Name 'CycleId' -DefaultValue 0)
try {
    $null = Assert-RelayTargetFolderReady `
        -ConfiguredFolder ([string](Get-ConfigValue -Object $targetConfig[0] -Name 'GlobalFolder' -DefaultValue '')) `
        -InboxRoot ([string](Get-ConfigValue -Object $config -Name 'InboxRoot' -DefaultValue '')) `
        -TargetKey $TargetId
    $producerResult = Invoke-TargetAutoloopProducerReadyFile `
        -Root $root `
        -ConfigPath ([string]$config.ConfigPath) `
        -TargetId $TargetId `
        -PromptFilePath $promptFilePath
    $completedPath = Move-CommandToArchive -Path $processingPath -DestinationRoot ([string]$queuePaths.CompletedRoot)

    $entry.Phase = 'waiting-output'
    $entry.NextAction = 'wait-for-output'
    $entry.LastDispatchAt = (Get-Date).ToString('o')
    $entry.LastDispatchState = 'router-ready-file-created'
    $entry.LastRouterReadyPath = [string]$producerResult.ReadyPath
    $entry.RelayTargetFolderState = ''
    $entry.LastCommandPath = $completedPath
    $entry.LastProgressSignalAt = (Get-Date).ToString('o')
    $entry.LastFailureReason = ''

    Set-TargetAutoloopTargetStateMap -TargetStateMap $stateMap -StateDocument $stateDocument
    $stateDocument.LastUpdatedAt = (Get-Date).ToString('o')
    Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
    $statusDocument = New-TargetAutoloopStatusDocument -Config $config -RunRoot $resolvedRunRoot -StateDocument $stateDocument -ControlDocument $controlDocument
    Write-JsonFileAtomically -Path $statePaths.StatusPath -Payload $statusDocument
    Append-TargetAutoloopEvent -Path $statePaths.EventsPath -EventType 'router-ready-created' -TargetId $TargetId -TriggerKind $triggerKind -TriggerFingerprint $triggerFingerprint -Extra @{
        CommandId = $commandId
        CycleId = $cycleId
        ReadyPath = [string]$producerResult.ReadyPath
        LoopSource = $loopSource
    }

    $result = [pscustomobject][ordered]@{
        SchemaVersion = $script:TargetAutoloopSchemaVersion
        RunRoot = $resolvedRunRoot
        TargetId = $TargetId
        CommandId = $commandId
        CommandPath = $completedPath
        TriggerKind = $triggerKind
        TriggerFingerprint = $triggerFingerprint
        LoopSource = $loopSource
        CycleId = $cycleId
        State = 'router-ready-file-created'
        ReadyPath = [string]$producerResult.ReadyPath
        ProducerOutput = [string]$producerResult.ProducerOutput
    }
}
catch {
    $failedPath = Move-CommandToArchive -Path $processingPath -DestinationRoot ([string]$queuePaths.FailedRoot)
    $relayTargetFolderState = Get-RelayTargetFolderIssueStateFromMessage -Message $_.Exception.Message
    $entry.Phase = 'failed'
    $entry.NextAction = 'open-receipt'
    $entry.LastDispatchAt = (Get-Date).ToString('o')
    $entry.LastDispatchState = if (Test-NonEmptyString $relayTargetFolderState) { 'relay-folder-preflight-failed' } else { 'router-ready-file-failed' }
    $entry.RelayTargetFolderState = $relayTargetFolderState
    $entry.LastCommandPath = $failedPath
    $entry.LastFailureReason = $_.Exception.Message
    $entry.LastProgressSignalAt = (Get-Date).ToString('o')
    Set-TargetAutoloopTargetStateMap -TargetStateMap $stateMap -StateDocument $stateDocument
    $stateDocument.LastUpdatedAt = (Get-Date).ToString('o')
    Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
    $statusDocument = New-TargetAutoloopStatusDocument -Config $config -RunRoot $resolvedRunRoot -StateDocument $stateDocument -ControlDocument $controlDocument
    Write-JsonFileAtomically -Path $statePaths.StatusPath -Payload $statusDocument
    Append-TargetAutoloopEvent -Path $statePaths.EventsPath -EventType 'router-ready-failed' -TargetId $TargetId -TriggerKind $triggerKind -TriggerFingerprint $triggerFingerprint -Extra @{
        CommandId = $commandId
        CycleId = $cycleId
        Reason = $_.Exception.Message
    }
    throw
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

$result
