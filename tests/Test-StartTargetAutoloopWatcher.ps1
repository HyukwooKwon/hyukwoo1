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
$control.Action = ''
$control.RequestId = ''
$control.RequestedAt = ''
$control.RequestedBy = ''
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

$activeStatus = Get-Content -LiteralPath $start.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$activeStatus.ControllerState = 'running'
$activeStatus.WatcherState = 'running'
$activeStatus.WatcherStopReason = ''
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
