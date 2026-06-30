[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\TargetAutoloopConfig.ps1')

$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusOutputBlock'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_status_output_block'
$runtimeRoot = Join-Path $tmpRoot 'runtime'
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
$routerStatePath = Join-Path $runtimeRoot 'router-state.json'
$target01Folder = Join-Path $tmpRoot 'router-inbox\target01'
$target02Folder = Join-Path $tmpRoot 'router-inbox\target02'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
New-Item -ItemType Directory -Path $target01Folder -Force | Out-Null
New-Item -ItemType Directory -Path $target02Folder -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    RuntimeMapPath = '$($runtimeMapPath.Replace("'", "''"))'
    RouterStatePath = '$($routerStatePath.Replace("'", "''"))'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($target01Folder.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
        @{ Id = 'target02'; Folder = '$($target02Folder.Replace("'", "''"))'; WindowTitle = 'Target02'; FixedSuffix = 'suffix-02' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready'); MaxCycleCount = 5 }
            @{ TargetId = 'target02'; Enabled = `$true; TriggerKinds = @('publish-ready'); MaxCycleCount = 5 }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

@(
    [ordered]@{ TargetId = 'target01'; LauncherSessionId = 'session-current'; Available = $true }
    [ordered]@{ TargetId = 'target02'; LauncherSessionId = 'session-current'; Available = $true }
) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeMapPath -Encoding UTF8

[ordered]@{
    Status = 'running'
    RouterPid = $PID
    LauncherSessionId = 'session-current'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $routerStatePath -Encoding UTF8

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01,target02 `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json
$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $configPath
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Assert-True (Test-Path -LiteralPath ([string]$target01.TargetStatePath) -PathType Leaf) 'start run should create target01 state sidecar.'
Assert-True (Test-Path -LiteralPath ([string]$target01.TargetControlPath) -PathType Leaf) 'start run should create target01 control sidecar.'
Assert-True (Test-Path -LiteralPath ([string]$target01.TargetStatusPath) -PathType Leaf) 'start run should create target01 status sidecar.'
Assert-True (Test-Path -LiteralPath ([string]$target01.TargetEventsPath) -PathType Leaf) 'start run should create target01 events sidecar.'
$target01SidecarState = Read-JsonObject -Path ([string]$target01.TargetStatePath)
$target01SidecarControl = Read-JsonObject -Path ([string]$target01.TargetControlPath)
$target01SidecarStatus = Read-JsonObject -Path ([string]$target01.TargetStatusPath)
Assert-True ([string]$target01SidecarState.SidecarKind -eq 'target-state') 'target01 state sidecar should identify its kind.'
Assert-True ([string]$target01SidecarState.TargetId -eq 'target01') 'target01 state sidecar should be target scoped.'
Assert-True ([string]$target01SidecarState.Target.TargetStatePath -eq [string]$target01.TargetStatePath) 'target01 state sidecar should include only target01 state paths.'
Assert-True ([string]$target01SidecarControl.SidecarScope -eq 'global-control-mirror') 'target01 control sidecar should be a global control mirror.'
Assert-True ([string]$target01SidecarControl.TargetId -eq 'target01') 'target01 control sidecar should be target addressable.'
Assert-True ([string]$target01SidecarStatus.SidecarKind -eq 'target-status') 'target01 status sidecar should identify its kind.'
Assert-True ([string]$target01SidecarStatus.Target.TargetId -eq 'target01') 'target01 status sidecar should include only target01 status row.'

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'blocked output summary'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'blocked-output-note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'blocked output zip payload'
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 5 `
    -ParentCycleId 4 `
    -OutputFingerprint current-marker `
    -Overwrite | Out-Null

$state = Read-JsonObject -Path ([string]$start.StatePath)
$control = Read-JsonObject -Path ([string]$start.ControlPath)
$state.Targets.target01.Phase = 'limit-reached'
$state.Targets.target01.CycleCount = 5
$state.Targets.target01.MaxCycleCount = 5
$state.Targets.target01.NextAction = 'limit-reached'
$state.Targets.target01.LastHandledOutputFingerprint = 'previous-marker'
$state.Targets.target01.LastDispatchState = 'router-session-not-ready'
$state.Targets.target02.Phase = 'idle'
$state.Targets.target02.CycleCount = 0
$state.Targets.target02.MaxCycleCount = 5
$state.Targets.target02.NextAction = 'wait-for-output'
Write-JsonFileAtomically -Path ([string]$start.StatePath) -Payload $state

$status = New-TargetAutoloopStatusDocument `
    -Config $config `
    -RunRoot $runRoot `
    -StateDocument $state `
    -ControlDocument $control `
    -WatcherState 'running' `
    -WatcherTargetIds @('target01') `
    -HeartbeatAt (Get-Date).ToString('o') `
    -ConfiguredRunDurationSec 120
Write-JsonFileAtomically -Path ([string]$start.StatusPath) -Payload $status

$statusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$statusJson.WatcherHealth -eq 'active') 'output block fixture should keep watcher heartbeat active.'
Assert-True ([int]$statusJson.OutputBlockSummary.LimitReachedReadyUnacceptedCount -eq 1) 'status json should count limit-reached unaccepted marker blocks.'
Assert-True ([string]$statusJson.OutputBlockSummary.LimitReachedReadyUnacceptedTargetIds[0] -eq 'target01') 'status json should identify the blocked target.'
Assert-True ([string]$statusJson.WatcherCoverageSummary.State -eq 'partial') 'status json should surface partial watcher target coverage.'
Assert-True ([string]$statusJson.Targets[0].WatcherCoverageState -eq 'covered') 'status json should mark target01 as covered by the active watcher.'
Assert-True ([string]$statusJson.Targets[1].WatcherCoverageState -eq 'missing') 'status json should mark target02 as missing from active watcher coverage.'
Assert-True ([string]$statusJson.Targets[0].TargetStatusPath -match [regex]::Escape('target01\.state\target-autoloop-status.json')) 'status json should expose target01 sidecar status path.'
Assert-True ([string]$statusJson.Targets[0].TargetControlPath -match [regex]::Escape('target01\.state\target-autoloop-control.json')) 'status json should expose target01 sidecar control path.'
Assert-True ([string]$statusJson.Targets[0].TargetWatcherMutexName -match '^Global\\RelayTargetAutoloopTarget_[0-9a-f]+$') 'status json should expose target01 sidecar watcher mutex preview.'
Assert-True ([string]$statusJson.RecommendationActionKey -eq 'prepare_autoloop_runroot') 'status json should recommend preparing a fresh RunRoot.'
Assert-True ([string]$statusJson.RecommendationLabel -eq '새 RunRoot 준비') 'status json should surface the RunRoot prepare label.'
Assert-True ([string]$statusJson.RecommendationDetail -match 'MaxCycleCount') 'status json should explain the max cycle block.'
Assert-True ([string]$statusJson.RecommendationDetail -match 'target01') 'status json should include the blocked target id.'
Assert-True ([string]$statusJson.RecommendationDetail -match 'publish.ready') 'status json should explain that recreating artifacts in the same RunRoot is insufficient.'

$output = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$joined = (@($output) -join "`n")

Assert-True ($joined -match 'OutputBlockSummary: checked=2 limit=1 readyUnaccepted=1 limitReady=1 routerBlocked=1 latestTarget=target01 latestDispatch=router-session-not-ready') 'status text should surface output block summary.'
Assert-True ($joined -match 'WatcherCoverage: state=partial scope=scoped targets=target01 covered=target01 missing=target02') 'status text should surface partial watcher target coverage.'
Assert-True ($joined -match 'target02 \| idle .* watcherCoverage: missing') 'status text should mark target02 as missing from active watcher coverage.'
Assert-True ($joined -match 'targetState: status=.*target01.*target-autoloop-status\.json control=.*target01.*target-autoloop-control\.json mutex=Global\\RelayTargetAutoloopTarget_') 'status text should include target01 sidecar diagnostics.'
Assert-True ($joined -match 'RecommendationAction: prepare_autoloop_runroot') 'status text should surface the prepare recommendation.'
Assert-True ($joined -match 'Counts: .*outputBlock=1/1') 'status counts should include compact output block counts.'

Write-Host 'show target autoloop status output block ok'
