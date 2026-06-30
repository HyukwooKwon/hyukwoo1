[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [string[]]$Targets = @(),
    [int]$RunDurationSec = 0,
    [switch]$DispatchQueuedCommandsInline,
    [switch]$ProcessOnce,
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

$selectedTargets = @(
    $Targets |
        Where-Object { Test-NonEmptyString $_ } |
        ForEach-Object { [string]$_ } |
        Sort-Object -Unique
)

$manifestPath = Join-Path $resolvedRunRoot 'manifest.json'
$statePaths = Get-TargetAutoloopStatePaths -RunRoot $resolvedRunRoot -Config $config
$preparedFresh = $false
$restartRecovered = $false

if (
    -not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $statePaths.StatePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $statePaths.ControlPath -PathType Leaf)
) {
    $startRaw = & (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
        -ConfigPath ([string]$config.ConfigPath) `
        -RunRoot $resolvedRunRoot `
        -Targets $selectedTargets `
        -RunMode ([string]$config.RunMode) `
        -AsJson
    $null = $startRaw | ConvertFrom-Json
    $preparedFresh = $true
}

$manifest = Read-JsonObject -Path $manifestPath
if (@($selectedTargets).Count -eq 0) {
    $selectedTargets = @($manifest.Targets | ForEach-Object { [string]$_.TargetId })
}

$stateDocument = Read-JsonObject -Path $statePaths.StatePath
$controlDocument = Read-JsonObject -Path $statePaths.ControlPath
$pendingAction = Get-TargetAutoloopPendingControlAction -ControlDocument $controlDocument
if (Test-NonEmptyString $pendingAction) {
    throw "target autoloop control request is still pending: $pendingAction"
}

$controllerState = [string](Get-ConfigValue -Object $controlDocument -Name 'State' -DefaultValue 'running')
$stateValue = [string](Get-ConfigValue -Object $stateDocument -Name 'State' -DefaultValue '')
if ($controllerState -eq 'stopped' -or $stateValue -eq 'stopped') {
    $stateMap = Get-TargetAutoloopTargetStateMap -StateDocument $stateDocument
    foreach ($targetId in @($stateMap.Keys)) {
        $entry = $stateMap[$targetId]
        if ($null -eq $entry) {
            continue
        }
        if ([string](Get-ConfigValue -Object $entry -Name 'Phase' -DefaultValue '') -eq 'stopped' -or $stateValue -eq 'stopped') {
            Restore-TargetAutoloopStoppedEntryState -Entry $entry
        }
    }
    Set-TargetAutoloopTargetStateMap -TargetStateMap $stateMap -StateDocument $stateDocument
    $stateDocument.State = 'running'
    $stateDocument.LastUpdatedAt = (Get-Date).ToString('o')
    $controlDocument.State = 'running'
    Clear-TargetAutoloopControlPendingAction -ControlDocument $controlDocument
    $controlDocument.LastUpdatedAt = (Get-Date).ToString('o')
    Write-JsonFileAtomically -Path $statePaths.StatePath -Payload $stateDocument
    Write-JsonFileAtomically -Path $statePaths.ControlPath -Payload $controlDocument
    $statusDocument = New-TargetAutoloopStatusDocument `
        -Config $config `
        -RunRoot $resolvedRunRoot `
        -StateDocument $stateDocument `
        -ControlDocument $controlDocument `
        -WatcherState 'stopped' `
        -WatcherStopReason '' `
        -ConfiguredRunDurationSec $RunDurationSec
    Write-JsonFileAtomically -Path $statePaths.StatusPath -Payload $statusDocument
    Sync-TargetAutoloopTargetSidecarDocuments `
        -Config $config `
        -RunRoot $resolvedRunRoot `
        -StateDocument $stateDocument `
        -ControlDocument $controlDocument `
        -StatusDocument $statusDocument
    $restartRecovered = $true
}

$watchRaw = & (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath ([string]$config.ConfigPath) `
    -RunRoot $resolvedRunRoot `
    -Targets $selectedTargets `
    -RunDurationSec $RunDurationSec `
    -DispatchQueuedCommandsInline:$DispatchQueuedCommandsInline `
    -ProcessOnce:$ProcessOnce `
    -AsJson
$watchResult = $watchRaw | ConvertFrom-Json

$result = [pscustomobject][ordered]@{
    SchemaVersion = $script:TargetAutoloopSchemaVersion
    RunRoot = $resolvedRunRoot
    PreparedFresh = $preparedFresh
    RestartRecovered = $restartRecovered
    WatchResult = $watchResult
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    return
}

$result
