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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopStopRestartContinuesQueuedCommand'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-inbox-submit.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_stop_restart_queued'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
New-Item -ItemType Directory -Path $routerInboxRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($routerInboxRoot.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
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

$startJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-inbox-submit `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$inputPath = Join-Path $target01.InboxPendingRoot 'task_stop_restart_001.txt'
Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'stop then restart should continue the queued command without replaying stale control'

$watchQueueJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchQueue = $watchQueueJson | ConvertFrom-Json
Assert-True ([int]$watchQueue.QueuedCount -eq 1) 'input trigger should queue one command before stop.'

$queuedFilesBeforeStop = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queuedFilesBeforeStop).Count -eq 1) 'queued command should exist before stop.'
$queuedCommandBeforeStop = Get-Content -LiteralPath $queuedFilesBeforeStop[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$queuedCommandId = [string]$queuedCommandBeforeStop.CommandId

$stopRequest = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action stop `
    -RequestedBy 'tests\Test-TargetAutoloopStopRestartContinuesQueuedCommand.ps1:stop' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$stopRequest.Ok) 'stop request should succeed.'
Assert-True (([string]$stopRequest.RequestId).Length -gt 0) 'stop request should allocate request id.'

$stopWatchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$stopWatch = $stopWatchJson | ConvertFrom-Json
Assert-True ([string]$stopWatch.WatcherStopReason -eq 'control-stop-request') 'watcher should stop because of the explicit stop request.'

$stoppedStatus = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$stoppedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$stoppedTarget = $stoppedState.Targets.target01
$stoppedControl = Get-Content -LiteralPath $start.ControlPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$stoppedStatus.ControllerState -eq 'stopped') 'controller should be stopped after stop acknowledgement.'
Assert-True ([string]$stoppedTarget.Phase -eq 'stopped') 'target should move to stopped after stop.'
Assert-True ([string]$stoppedTarget.StoppedPhase -eq 'queued') 'stop should preserve the queued phase for restart.'
Assert-True ([string]$stoppedTarget.StoppedNextAction -eq 'dispatch-command') 'stop should preserve the queued next action for restart.'
Assert-True ([string]$stoppedControl.Action -eq '') 'stop acknowledgement should not leave a pending action.'
Assert-True ([string]$stoppedControl.RequestId -eq '') 'stop acknowledgement should clear the control request id.'

$queuedFilesWhileStopped = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
$completedFilesWhileStopped = @(Get-ChildItem -LiteralPath $target01.QueueCompletedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queuedFilesWhileStopped).Count -eq 1) 'queued command should remain queued across stop.'
Assert-True (@($completedFilesWhileStopped).Count -eq 0) 'completed archive should remain empty before restart.'

$watcherJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopWatcher.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watcher = $watcherJson | ConvertFrom-Json
Assert-True ([bool]$watcher.Ok) 'restart watcher should succeed after stop.'
Assert-True (@($watcher.RestoredTargetIds) -contains 'target01') 'restart should restore stopped target state bookkeeping.'

$restartedStatus = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$restartedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$restartedTarget = $restartedState.Targets.target01
$restartedControl = Get-Content -LiteralPath $start.ControlPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$restartedStatus.ControllerState -eq 'running') 'restart should restore controller state to running.'
Assert-True ([string]$restartedTarget.Phase -eq 'queued') 'restart should restore queued phase rather than replay stopped state.'
Assert-True ([string]$restartedTarget.NextAction -eq 'dispatch-command') 'restart should restore queued next action.'
Assert-True ([string]$restartedTarget.StoppedPhase -eq '') 'restart should clear stopped phase bookkeeping.'
Assert-True ([string]$restartedTarget.StoppedNextAction -eq '') 'restart should clear stopped next action bookkeeping.'
Assert-True ([string]$restartedControl.Action -eq '') 'restart should keep control action cleared.'
Assert-True ([string]$restartedControl.RequestId -eq '') 'restart should not replay stale stop request ids.'

$queuedFilesAfterRestart = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queuedFilesAfterRestart).Count -eq 1) 'restart should keep the original queued command without duplicating it.'
$queuedCommandAfterRestart = Get-Content -LiteralPath $queuedFilesAfterRestart[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$queuedCommandAfterRestart.CommandId -eq $queuedCommandId) 'restart should preserve the original queued command identity.'

$workerJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -ProcessOnce `
    -AsJson
$worker = $workerJson | ConvertFrom-Json
Assert-True ([int]$worker.ProcessedCount -eq 1) 'worker should process the preserved queued command after restart.'
Assert-True ([string]$worker.LastResult.State -eq 'router-ready-file-created') 'restarted queued command should dispatch successfully.'
Assert-True ([string]$worker.LastResult.CommandId -eq $queuedCommandId) 'worker should process the original pre-stop queued command.'

$queuedFilesAfterDispatch = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
$completedFilesAfterDispatch = @(Get-ChildItem -LiteralPath $target01.QueueCompletedRoot -File -Filter '*.json' | Sort-Object Name)
$readyFiles = @(Get-ChildItem -LiteralPath $routerInboxRoot -File -Filter '*.ready.txt' | Sort-Object Name)
Assert-True (@($queuedFilesAfterDispatch).Count -eq 0) 'queued command should drain after restart dispatch succeeds.'
Assert-True (@($completedFilesAfterDispatch).Count -eq 1) 'completed archive should contain the restarted queued command.'
Assert-True (@($readyFiles).Count -eq 1) 'restart flow should create exactly one ready file.'

$finalState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$finalTarget = $finalState.Targets.target01
Assert-True ([string]$finalTarget.Phase -eq 'waiting-output') 'target should move to waiting-output after restarted queued dispatch.'
Assert-True ([string]$finalTarget.LastDispatchState -eq 'router-ready-file-created') 'target should record router dispatch after restart.'

Write-Host 'target autoloop stop restart continues queued command ok'
