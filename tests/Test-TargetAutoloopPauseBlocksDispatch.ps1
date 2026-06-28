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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopPauseBlocksDispatch'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-pause-blocks-dispatch.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_pause_blocks_dispatch'
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
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$inputPath = Join-Path $target01.InboxPendingRoot 'task_pause_dispatch_001.txt'
Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'pause should block queued dispatch until resume'

$watchQueueJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchQueue = $watchQueueJson | ConvertFrom-Json
Assert-True ([int]$watchQueue.QueuedCount -eq 1) 'input trigger should queue one command before pause is requested.'

$queuedFilesBeforePause = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queuedFilesBeforePause).Count -eq 1) 'queued command should exist before pause acknowledgement.'

$pauseRequest = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action pause `
    -RequestedBy 'tests\Test-TargetAutoloopPauseBlocksDispatch.ps1:pause' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$pauseRequest.Ok) 'pause request should succeed.'
Assert-True (([string]$pauseRequest.RequestId).Length -gt 0) 'pause request should allocate request id.'

$null = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson

$pausedStatus = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
Assert-True ([string]$pausedStatus.ControllerState -eq 'paused') 'controller state should be paused before dispatch worker runs.'

$blockedWorkerJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -ProcessOnce `
    -AsJson
$blockedWorker = $blockedWorkerJson | ConvertFrom-Json
Assert-True ([int]$blockedWorker.ProcessedCount -eq 0) 'paused controller should block the queued command from being claimed.'
Assert-True ([string]$blockedWorker.LastResult.State -eq 'blocked-by-controller') 'worker should report blocked-by-controller while paused.'
Assert-True ([string]$blockedWorker.LastResult.ControllerState -eq 'paused') 'blocked dispatch should surface paused controller state.'
Assert-True ([string]$blockedWorker.LastResult.BlockReason -eq 'watcher-paused') 'blocked dispatch should explain that watcher pause blocked the claim.'

$queuedFilesWhilePaused = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
$processingFilesWhilePaused = @(Get-ChildItem -LiteralPath $target01.QueueProcessingRoot -File -Filter '*.json' | Sort-Object Name)
$completedFilesWhilePaused = @(Get-ChildItem -LiteralPath $target01.QueueCompletedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queuedFilesWhilePaused).Count -eq 1) 'queued command should remain queued while paused.'
Assert-True (@($processingFilesWhilePaused).Count -eq 0) 'processing archive should stay empty while paused.'
Assert-True (@($completedFilesWhilePaused).Count -eq 0) 'completed archive should stay empty while paused.'

$resumeRequest = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action resume `
    -RequestedBy 'tests\Test-TargetAutoloopPauseBlocksDispatch.ps1:resume' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$resumeRequest.Ok) 'resume request should succeed.'
Assert-True (([string]$resumeRequest.RequestId).Length -gt 0) 'resume request should allocate request id.'

$null = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson

$resumedStatus = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
Assert-True ([string]$resumedStatus.ControllerState -eq 'running') 'controller state should return to running after resume acknowledgement.'

$resumedWorkerJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -ProcessOnce `
    -AsJson
$resumedWorker = $resumedWorkerJson | ConvertFrom-Json
Assert-True ([int]$resumedWorker.ProcessedCount -eq 1) 'resumed controller should allow the queued command to dispatch.'
Assert-True ([string]$resumedWorker.LastResult.State -eq 'router-ready-file-created') 'resumed dispatch should create the router ready file.'

$queuedFilesAfterResume = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
$completedFilesAfterResume = @(Get-ChildItem -LiteralPath $target01.QueueCompletedRoot -File -Filter '*.json' | Sort-Object Name)
$readyFiles = @(Get-ChildItem -LiteralPath $routerInboxRoot -File -Filter '*.ready.txt' | Sort-Object Name)
Assert-True (@($queuedFilesAfterResume).Count -eq 0) 'queued command should be drained after resume.'
Assert-True (@($completedFilesAfterResume).Count -eq 1) 'completed archive should contain the resumed command.'
Assert-True (@($readyFiles).Count -eq 1) 'router ready file should be created after resume.'

$finalState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$finalTarget = $finalState.Targets.target01
Assert-True ([string]$finalTarget.Phase -eq 'waiting-output') 'target state should move to waiting-output after resumed dispatch.'
Assert-True ([string]$finalTarget.LastDispatchState -eq 'router-ready-file-created') 'target state should record resumed router dispatch.'

Write-Host 'target autoloop pause blocks dispatch ok'
