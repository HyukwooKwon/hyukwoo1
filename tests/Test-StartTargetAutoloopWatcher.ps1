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
$tmpRoot = Join-Path $root '_tmp\Test-StartTargetAutoloopWatcher'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_watcher'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-inbox-submit'
        DispatchQueuedCommandsInline = `$false
        PollIntervalMs = 200
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-inbox-submit `
    -AsJson
$start = $startJson | ConvertFrom-Json

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$state.State = 'stopped'
$state.Targets.target01.Phase = 'stopped'
$state.Targets.target01.NextAction = 'stopped'
$state.Targets.target01.StoppedPhase = 'idle'
$state.Targets.target01.StoppedNextAction = 'wait-for-input'
$state.LastUpdatedAt = (Get-Date).ToString('o')
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatePath -Encoding UTF8

$control = Get-Content -LiteralPath $start.ControlPath -Raw -Encoding UTF8 | ConvertFrom-Json
$control.State = 'stopped'
$control.Action = 'stop'
$control.RequestId = 'req-stale-stop'
$control.RequestedAt = (Get-Date).AddSeconds(-30).ToString('o')
$control.RequestedBy = 'test-stale-stop'
$control.StopRequested = $true
$control.LastHandledAction = 'stop'
$control.LastHandledResult = 'stopped'
$control.LastHandledAt = (Get-Date).ToString('o')
$control.LastUpdatedAt = (Get-Date).ToString('o')
$control | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.ControlPath -Encoding UTF8

$status = Get-Content -LiteralPath $start.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$status.ControllerState = 'stopped'
$status.WatcherState = 'stopped'
$status.WatcherStopReason = 'control-stop-request'
$status.HeartbeatAt = (Get-Date).AddSeconds(-30).ToString('o')
$status.ProcessStartedAt = (Get-Date).AddSeconds(-60).ToString('o')
$status.LastUpdatedAt = (Get-Date).ToString('o')
$status | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatusPath -Encoding UTF8

$watcherJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopWatcher.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -RunDurationSec 1 `
    -AsJson
$watcher = $watcherJson | ConvertFrom-Json

Assert-True ([bool]$watcher.Ok) 'watcher start should succeed.'
Assert-True ([string]$watcher.Result -eq 'completed-inline') 'inline watcher start should finish synchronously.'
Assert-True (@($watcher.RestoredTargetIds) -contains 'target01') 'restart should restore stopped target state bookkeeping.'
Assert-True ([string]$watcher.ReconciledControlAction -eq 'stop') 'restart should reconcile stale stop control pending action.'
Assert-True ([string]$watcher.ReconciledControlState -eq 'stopped') 'restart should report reconciled stopped control state.'

$finalStatus = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$finalState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-True ([string]$finalStatus.ControllerState -eq 'running') 'inline watcher restart should restore controller state to running.'
Assert-True ([string]$finalStatus.WatcherState -eq 'stopped') 'inline watcher should end in stopped state after run-duration timeout.'
Assert-True ([string]$finalStatus.WatcherStopReason -eq 'run-duration-reached') 'inline watcher should surface run-duration stop reason.'
Assert-True ([string]$finalStatus.WatcherHealth -eq 'stopped') 'status json should expose watcher health.'
Assert-True (([string]$finalStatus.WatcherRecommendation).Contains('watcher가 stopped입니다')) 'status json should expose watcher recommendation.'
Assert-True ([string]$finalState.Targets.target01.Phase -ne 'stopped') 'restart should restore target phase from stopped.'
Assert-True ([string]$finalState.Targets.target01.NextAction -eq 'wait-for-input') 'restored input target should return to wait-for-input.'

$scopedConfigPath = Join-Path $tmpRoot 'settings.target-autoloop.scoped-restore.psd1'
$scopedRunRoot = Join-Path $tmpRoot 'run_target_autoloop_scoped_restore'
[System.IO.File]::WriteAllText($scopedConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' },
        @{ Id = 'target02'; Folder = 'C:\tmp\target02'; WindowTitle = 'Target02'; FixedSuffix = 'suffix-02' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-inbox-submit'
        DispatchQueuedCommandsInline = `$false
        PollIntervalMs = 200
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file') },
            @{ TargetId = 'target02'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$scopedStartJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $scopedConfigPath `
    -RunRoot $scopedRunRoot `
    -Targets target01,target02 `
    -RunMode target-inbox-submit `
    -AsJson
$scopedStart = $scopedStartJson | ConvertFrom-Json

$scopedState = Get-Content -LiteralPath $scopedStart.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$scopedState.State = 'stopped'
$scopedState.Targets.target01.Phase = 'stopped'
$scopedState.Targets.target01.NextAction = 'stopped'
$scopedState.Targets.target01.StoppedPhase = 'idle'
$scopedState.Targets.target01.StoppedNextAction = 'wait-for-input'
$scopedState.Targets.target02.Phase = 'stopped'
$scopedState.Targets.target02.NextAction = 'stopped'
$scopedState.Targets.target02.StoppedPhase = 'idle'
$scopedState.Targets.target02.StoppedNextAction = 'wait-for-input'
$scopedState.LastUpdatedAt = (Get-Date).ToString('o')
$scopedState | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $scopedStart.StatePath -Encoding UTF8

$scopedControl = Get-Content -LiteralPath $scopedStart.ControlPath -Raw -Encoding UTF8 | ConvertFrom-Json
$scopedControl.State = 'stopped'
$scopedControl.LastHandledAction = 'stop'
$scopedControl.LastHandledResult = 'stopped'
$scopedControl.LastHandledAt = (Get-Date).ToString('o')
$scopedControl.LastUpdatedAt = (Get-Date).ToString('o')
$scopedControl | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $scopedStart.ControlPath -Encoding UTF8

$scopedStatus = Get-Content -LiteralPath $scopedStart.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$scopedStatus.ControllerState = 'stopped'
$scopedStatus.WatcherState = 'stopped'
$scopedStatus.WatcherStopReason = 'control-stop-request'
$scopedStatus.HeartbeatAt = (Get-Date).AddSeconds(-30).ToString('o')
$scopedStatus.ProcessStartedAt = (Get-Date).AddSeconds(-60).ToString('o')
$scopedStatus.LastUpdatedAt = (Get-Date).ToString('o')
$scopedStatus | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $scopedStart.StatusPath -Encoding UTF8

$scopedWatcherJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopWatcher.ps1') `
    -ConfigPath $scopedConfigPath `
    -RunRoot $scopedRunRoot `
    -Targets target01 `
    -RunDurationSec 1 `
    -AsJson
$scopedWatcher = $scopedWatcherJson | ConvertFrom-Json
$scopedFinalState = Get-Content -LiteralPath $scopedStart.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-True ([bool]$scopedWatcher.Ok) 'scoped watcher start should succeed.'
Assert-True (@($scopedWatcher.RestoredTargetIds) -contains 'target01') 'scoped restart should restore selected target.'
Assert-True (-not (@($scopedWatcher.RestoredTargetIds) -contains 'target02')) 'scoped restart should not restore unselected target.'
Assert-True ([string]$scopedFinalState.Targets.target01.Phase -ne 'stopped') 'selected target should leave stopped phase.'
Assert-True ([string]$scopedFinalState.Targets.target02.Phase -eq 'stopped') 'unselected target should remain stopped.'

$scopedActiveStatus = Get-Content -LiteralPath $scopedStart.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$scopedActiveStatus.ControllerState = 'running'
$scopedActiveStatus.WatcherState = 'running'
$scopedActiveStatus.WatcherStopReason = ''
$scopedActiveStatus.WatcherTargetIds = @('target01')
$scopedActiveStatus.WatcherTargetScope = 'scoped'
$scopedActiveStatus.HeartbeatAt = (Get-Date).ToString('o')
$scopedActiveStatus.ProcessStartedAt = (Get-Date).AddMinutes(-5).ToString('o')
$scopedActiveStatus.LastUpdatedAt = (Get-Date).ToString('o')
$scopedActiveStatus | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $scopedStart.StatusPath -Encoding UTF8

$scopeMismatchJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopWatcher.ps1') `
    -ConfigPath $scopedConfigPath `
    -RunRoot $scopedRunRoot `
    -Targets target02 `
    -RunDurationSec 1 `
    -AsJson
$scopeMismatch = $scopeMismatchJson | ConvertFrom-Json

Assert-True (-not [bool]$scopeMismatch.Ok) 'fresh active watcher should reject requests for uncovered targets.'
Assert-True ([string]$scopeMismatch.Result -eq 'watcher-target-scope-mismatch') 'uncovered active watcher should return a stable scope mismatch result.'
Assert-True (@($scopeMismatch.ReasonCodes) -contains 'watcher_target_scope_mismatch') 'scope mismatch should include a stable reason code.'
Assert-True (@($scopeMismatch.WatcherTargetIds) -contains 'target01') 'scope mismatch should report active watcher target ids.'
Assert-True (@($scopeMismatch.RequestedTargetIds) -contains 'target02') 'scope mismatch should report requested target ids.'

$activeStatus = Get-Content -LiteralPath $start.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$activeStatus.ControllerState = 'running'
$activeStatus.WatcherState = 'running'
$activeStatus.WatcherStopReason = ''
$activeStatus.WatcherTargetIds = @('target01')
$activeStatus.WatcherTargetScope = 'all'
$activeStatus.HeartbeatAt = (Get-Date).ToString('o')
$activeStatus.ProcessStartedAt = (Get-Date).AddMinutes(-5).ToString('o')
$activeStatus.LastUpdatedAt = (Get-Date).ToString('o')
$activeStatus | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatusPath -Encoding UTF8

$alreadyRunningJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopWatcher.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -RunMode target-inbox-submit `
    -ProcessOnce `
    -AsJson
$alreadyRunning = $alreadyRunningJson | ConvertFrom-Json

Assert-True ([bool]$alreadyRunning.Ok) 'fresh active watcher start should return an idempotent successful already-running payload.'
Assert-True ([string]$alreadyRunning.Result -eq 'already-running') 'fresh active watcher start should not launch another watcher.'
Assert-True (@($alreadyRunning.ReasonCodes) -contains 'watcher_already_active') 'fresh active watcher start should include watcher_already_active.'
Assert-True ([bool]$alreadyRunning.Idempotent) 'fresh active watcher start should mark the response idempotent.'
Assert-True ([bool]$alreadyRunning.ActiveConfirmed) 'fresh active watcher start should mark active confirmation.'
Assert-True (-not [bool]$alreadyRunning.WatcherMutexHeld) 'fresh active watcher start should not report mutex-only handling.'
Assert-True ([string]$alreadyRunning.WatcherState -eq 'running') 'fresh active watcher start should report running state.'
Assert-True ([string]$alreadyRunning.WatcherMutexName) 'already-running payload should include watcher mutex name.'

$mismatchJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopWatcher.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -RunMode target-autoloop `
    -AsJson
$mismatch = $mismatchJson | ConvertFrom-Json

Assert-True (-not [bool]$mismatch.Ok) 'watcher start should reject an existing run prepared with a different RunMode.'
Assert-True ([string]$mismatch.Result -eq 'manifest-runmode-mismatch') 'mismatched run should return a manifest-runmode-mismatch result.'
Assert-True (@($mismatch.ReasonCodes) -contains 'manifest_run_mode_mismatch') 'mismatched run should include a stable reason code.'

$publishConfigPath = Join-Path $tmpRoot 'settings.target-autoloop.publish-missing.psd1'
$publishRunRoot = Join-Path $tmpRoot 'run_target_autoloop_publish_missing'
[System.IO.File]::WriteAllText($publishConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target02'; Folder = 'C:\tmp\target02'; WindowTitle = 'Target02'; FixedSuffix = 'suffix-02' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        PollIntervalMs = 200
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target02'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $publishConfigPath `
    -RunRoot $publishRunRoot `
    -Targets target02 `
    -RunMode target-autoloop `
    -AsJson | Out-Null
$publishMissingJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopWatcher.ps1') `
    -ConfigPath $publishConfigPath `
    -RunRoot $publishRunRoot `
    -RunMode target-autoloop `
    -AsJson
$publishMissing = $publishMissingJson | ConvertFrom-Json

Assert-True (-not [bool]$publishMissing.Ok) 'target-autoloop watcher start should reject enabled targets without publish-ready.'
Assert-True ([string]$publishMissing.Result -eq 'publish-ready-trigger-missing') 'publish-ready missing should return a stable result.'
Assert-True (@($publishMissing.PublishReadyMissingTargetIds) -contains 'target02') 'publish-ready missing result should identify the target.'

$sessionConfigPath = Join-Path $tmpRoot 'settings.target-autoloop.session-mismatch.psd1'
$sessionRunRoot = Join-Path $tmpRoot 'run_target_autoloop_session_mismatch'
$sessionRuntimeMapPath = Join-Path $tmpRoot 'runtime-map.session-mismatch.json'
$sessionRouterStatePath = Join-Path $tmpRoot 'router-state.session-mismatch.json'
@(
    [ordered]@{
        TargetId = 'target03'
        LauncherSessionId = 'runtime-session-new'
    }
) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionRuntimeMapPath -Encoding UTF8
[ordered]@{
    Status = 'running'
    LauncherSessionId = 'router-session-old'
    RouterPid = $PID
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionRouterStatePath -Encoding UTF8
[System.IO.File]::WriteAllText($sessionConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    RuntimeMapPath = '$($sessionRuntimeMapPath.Replace("'", "''"))'
    RouterStatePath = '$($sessionRouterStatePath.Replace("'", "''"))'
    Targets = @(
        @{ Id = 'target03'; Folder = 'C:\tmp\target03'; WindowTitle = 'Target03'; FixedSuffix = 'suffix-03' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        PollIntervalMs = 200
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target03'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $sessionConfigPath `
    -RunRoot $sessionRunRoot `
    -Targets target03 `
    -RunMode target-autoloop `
    -AsJson | Out-Null
$sessionMismatchJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopWatcher.ps1') `
    -ConfigPath $sessionConfigPath `
    -RunRoot $sessionRunRoot `
    -RunMode target-autoloop `
    -AsJson
$sessionMismatch = $sessionMismatchJson | ConvertFrom-Json

Assert-True (-not [bool]$sessionMismatch.Ok) 'target-autoloop watcher start should reject router/runtime launcher session mismatch.'
Assert-True ([string]$sessionMismatch.Result -eq 'router-launcher-session-mismatch') 'session mismatch should return a stable result.'
Assert-True (@($sessionMismatch.ReasonCodes) -contains 'router_launcher_session_mismatch') 'session mismatch should include a stable reason code.'
Assert-True ([string]$sessionMismatch.RouterLauncherSessionId -eq 'router-session-old') 'session mismatch should include router session id.'
Assert-True ([string]$sessionMismatch.RuntimeLauncherSessionId -eq 'runtime-session-new') 'session mismatch should include runtime session id.'

Write-Host 'start target autoloop watcher ok'
