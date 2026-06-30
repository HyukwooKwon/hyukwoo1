[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$TargetId,
    [ValidateRange(1, 1000)][int]$AdditionalCycles = 1,
    [string]$RequestedBy = 'relay_operator_panel',
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

function Set-JsonMemberValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
        return
    }

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

function Get-TargetAutoloopCycleExtensionWatcherMutexName {
    param([Parameter(Mandatory)][string]$RunRoot)

    $normalizedRunRoot = Get-NormalizedFullPath -Path $RunRoot
    $hashHex = (Get-TextHashHex -Text $normalizedRunRoot)
    $token = if ($hashHex.Length -ge 24) { $hashHex.Substring(0, 24) } else { $hashHex }
    return ('Global\RelayTargetAutoloop_{0}' -f $token)
}

if (-not (Test-NonEmptyString $ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -Root $root
}

$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $ConfigPath
$resolvedRunRoot = Resolve-TargetAutoloopRunRoot -Config $config -RequestedRunRoot $RunRoot
$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "target-autoloop manifest not found: $manifestPath"
}

$manifest = Read-JsonObject -Path $manifestPath
$manifestRunMode = [string](Get-ConfigValue -Object $manifest -Name 'RunMode' -DefaultValue '')
if ($manifestRunMode -ne 'target-autoloop') {
    throw "target-autoloop cycle extension requires manifest RunMode target-autoloop: $manifestRunMode"
}

$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
if (-not (Test-Path -LiteralPath $statePaths.StatePath -PathType Leaf)) {
    throw "target-autoloop state file not found: $($statePaths.StatePath)"
}
if (-not (Test-Path -LiteralPath $statePaths.ControlPath -PathType Leaf)) {
    throw "target-autoloop control file not found: $($statePaths.ControlPath)"
}

$stateDocument = Read-JsonObject -Path $statePaths.StatePath
$controlDocument = Read-JsonObject -Path $statePaths.ControlPath
$targetMap = Get-TargetAutoloopTargetStateMap -StateDocument $stateDocument
if (-not $targetMap.Contains($TargetId)) {
    throw "target state not found for target-autoloop cycle extension: $TargetId"
}

$stateRecord = $targetMap[$TargetId]
$cycleCount = [int](Get-ConfigValue -Object $stateRecord -Name 'CycleCount' -DefaultValue 0)
$beforeMax = [int](Get-ConfigValue -Object $stateRecord -Name 'MaxCycleCount' -DefaultValue 0)
$phase = [string](Get-ConfigValue -Object $stateRecord -Name 'Phase' -DefaultValue '')
if ($beforeMax -le 0) {
    throw "target has no finite MaxCycleCount to extend: $TargetId"
}
$nextActionBeforeExtension = [string](Get-ConfigValue -Object $stateRecord -Name 'NextAction' -DefaultValue '')
$limitReachedBeforeExtension = ($cycleCount -ge $beforeMax) -or $phase -eq 'limit-reached'
$preservedInFlightState = -not $limitReachedBeforeExtension

$afterMax = ([math]::Max($cycleCount, $beforeMax) + $AdditionalCycles)
$manifestTarget = $null
foreach ($target in @(Get-ConfigValue -Object $manifest -Name 'Targets' -DefaultValue @())) {
    if ([string](Get-ConfigValue -Object $target -Name 'TargetId' -DefaultValue '') -eq $TargetId) {
        $manifestTarget = $target
        break
    }
}
if ($null -eq $manifestTarget) {
    throw "manifest target not found for target-autoloop cycle extension: $TargetId"
}

$triggerKinds = @(Get-StringArray (Get-ConfigValue -Object $stateRecord -Name 'TriggerKinds' -DefaultValue @()))
$nextAction = Get-TargetAutoloopDefaultNextAction -TriggerKinds @($triggerKinds)
$lastRouterReadyPath = [string](Get-ConfigValue -Object $stateRecord -Name 'LastRouterReadyPath' -DefaultValue '')
$lastDispatchState = [string](Get-ConfigValue -Object $stateRecord -Name 'LastDispatchState' -DefaultValue '')
$restoreWaitingOutput = (Test-NonEmptyString $lastRouterReadyPath) -or $lastDispatchState -eq 'router-ready-file-created'
if ($limitReachedBeforeExtension) {
    $nextPhase = if ($restoreWaitingOutput) { 'waiting-output' } else { 'idle' }
    $nextActionAfterExtend = if ($restoreWaitingOutput) { 'wait-for-output' } else { $nextAction }
    $nextDispatchState = if ($restoreWaitingOutput) { 'router-ready-file-created' } else { '' }
}
else {
    $restoreWaitingOutput = $false
    $nextPhase = if (Test-NonEmptyString $phase) { $phase } else { 'idle' }
    $nextActionAfterExtend = if (Test-NonEmptyString $nextActionBeforeExtension) { $nextActionBeforeExtension } else { $nextAction }
    $nextDispatchState = $lastDispatchState
}
Set-JsonMemberValue -Object $stateRecord -Name 'MaxCycleCount' -Value $afterMax
Set-JsonMemberValue -Object $stateRecord -Name 'Phase' -Value $nextPhase
Set-JsonMemberValue -Object $stateRecord -Name 'NextAction' -Value $nextActionAfterExtend
Set-JsonMemberValue -Object $stateRecord -Name 'LastDispatchState' -Value $nextDispatchState
if ($limitReachedBeforeExtension) {
    Set-JsonMemberValue -Object $stateRecord -Name 'PausedPhase' -Value ''
    Set-JsonMemberValue -Object $stateRecord -Name 'PausedNextAction' -Value ''
    Set-JsonMemberValue -Object $stateRecord -Name 'StoppedPhase' -Value ''
    Set-JsonMemberValue -Object $stateRecord -Name 'StoppedNextAction' -Value ''
    Set-JsonMemberValue -Object $stateRecord -Name 'RelayTargetFolderState' -Value ''
    Set-JsonMemberValue -Object $stateRecord -Name 'LastFailureReason' -Value ''
}
Set-JsonMemberValue -Object $manifestTarget -Name 'MaxCycleCount' -Value $afterMax

Set-TargetAutoloopTargetStateMap -TargetStateMap $targetMap -StateDocument $stateDocument
$updatedAt = (Get-Date).ToString('o')
Set-JsonMemberValue -Object $stateDocument -Name 'State' -Value 'running'
Set-JsonMemberValue -Object $stateDocument -Name 'LastUpdatedAt' -Value $updatedAt
Set-JsonMemberValue -Object $controlDocument -Name 'State' -Value 'running'
Clear-TargetAutoloopControlPendingAction -ControlDocument $controlDocument
Set-JsonMemberValue -Object $controlDocument -Name 'LastUpdatedAt' -Value $updatedAt

$extensionRecord = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    EventKind = 'cycle-limit-extended'
    TargetId = $TargetId
    RunRoot = $resolvedRunRoot
    CycleCount = $cycleCount
    BeforeMaxCycleCount = $beforeMax
    AfterMaxCycleCount = $afterMax
    AdditionalCycles = $AdditionalCycles
    PreviousPhase = $phase
    NextPhase = $nextPhase
    NextAction = $nextActionAfterExtend
    LimitReachedBeforeExtension = $limitReachedBeforeExtension
    PreservedInFlightState = $preservedInFlightState
    RestoredWaitingOutput = $restoreWaitingOutput
    RequestedBy = $RequestedBy
    ExtendedAt = $updatedAt
}
$extensionPath = Join-Path $statePaths.StateRoot 'target-autoloop-cycle-extensions.json'
$extensionPayload = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunRoot = $resolvedRunRoot
    UpdatedAt = $updatedAt
    Extensions = @($extensionRecord)
}
if (Test-Path -LiteralPath $extensionPath -PathType Leaf) {
    try {
        $existing = Read-JsonObject -Path $extensionPath
        $existingExtensions = @(Get-ConfigValue -Object $existing -Name 'Extensions' -DefaultValue @())
        $extensionPayload.Extensions = @($existingExtensions + @($extensionRecord))
    }
    catch {
    }
}

Write-JsonFileAtomically -Path $manifestPath -Payload $manifest
Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
Write-JsonFileAtomically -Path $extensionPath -Payload $extensionPayload
Append-TargetAutoloopEvent -Path $statePaths.EventsPath -EventType 'cycle-limit-extended' -TargetId $TargetId -Extra @{
    BeforeMaxCycleCount = $beforeMax
    AfterMaxCycleCount = $afterMax
    AdditionalCycles = $AdditionalCycles
    CycleCount = $cycleCount
    RequestedBy = $RequestedBy
    NextPhase = $nextPhase
    LimitReachedBeforeExtension = $limitReachedBeforeExtension
    PreservedInFlightState = $preservedInFlightState
    RestoredWaitingOutput = $restoreWaitingOutput
}
$watcherStopReason = if ($limitReachedBeforeExtension) { 'cycle-limit-extended' } else { 'cycle-limit-extended-state-preserved' }
$statusDocument = New-TargetAutoloopStatusDocument `
    -Config $config `
    -RunRoot $resolvedRunRoot `
    -StateDocument $stateDocument `
    -ControlDocument $controlDocument `
    -WatcherState 'stopped' `
    -WatcherStopReason $watcherStopReason `
    -WatcherMutexName (Get-TargetAutoloopCycleExtensionWatcherMutexName -RunRoot $resolvedRunRoot) `
    -HeartbeatAt $updatedAt `
    -ProcessStartedAt $updatedAt `
    -ConfiguredRunDurationSec 0
Write-JsonFileAtomically -Path $statePaths.StatusPath -Payload $statusDocument
Sync-TargetAutoloopTargetSidecarDocuments `
    -Config $config `
    -RunRoot $resolvedRunRoot `
    -StateDocument $stateDocument `
    -ControlDocument $controlDocument `
    -StatusDocument $statusDocument

$payload = [ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    Ok = $true
    RunMode = 'target-autoloop'
    RunRoot = $resolvedRunRoot
    TargetId = $TargetId
    CycleCount = $cycleCount
    BeforeMaxCycleCount = $beforeMax
    AfterMaxCycleCount = $afterMax
    AdditionalCycles = $AdditionalCycles
    PreviousPhase = $phase
    NextPhase = $nextPhase
    NextAction = $nextActionAfterExtend
    LimitReachedBeforeExtension = $limitReachedBeforeExtension
    PreservedInFlightState = $preservedInFlightState
    RestoredWaitingOutput = $restoreWaitingOutput
    ManifestPath = $manifestPath
    StatePath = [string]$statePaths.StatePath
    ControlPath = [string]$statePaths.ControlPath
    StatusPath = [string]$statePaths.StatusPath
    ExtensionPath = $extensionPath
    Message = ('{0}: MaxCycleCount {1} -> {2} (+{3})' -f $TargetId, $beforeMax, $afterMax, $AdditionalCycles)
}

if ($AsJson) {
    $payload | ConvertTo-Json -Depth 12
    return
}

$payload
