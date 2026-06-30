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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopResumeContinuesPendingDelay'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$runtimeRoot = Join-Path $tmpRoot 'runtime'
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
$routerStatePath = Join-Path $runtimeRoot 'router-state.json'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_resume_delay'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
New-Item -ItemType Directory -Path $routerInboxRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    RuntimeMapPath = '$($runtimeMapPath.Replace("'", "''"))'
    RouterStatePath = '$($routerStatePath.Replace("'", "''"))'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($routerInboxRoot.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        DefaultPublishReadyDispatchDelaySeconds = 30
        DefaultPublishReadyDispatchMinDelaySeconds = 30
        DefaultPublishReadyDispatchMaxDelaySeconds = 30
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

@(
    [ordered]@{
        TargetId = 'target01'
        LauncherSessionId = 'session-current'
        Available = $true
    }
) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeMapPath -Encoding UTF8

[ordered]@{
    Status = 'running'
    RouterPid = $PID
    LauncherSessionId = 'session-current'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $routerStatePath -Encoding UTF8

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'summary ready for paused delayed next cycle'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'zip payload for paused delayed cycle'
if (Test-Path -LiteralPath $target01.SourceReviewZipPath) {
    Remove-Item -LiteralPath $target01.SourceReviewZipPath -Force
}
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
$null = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 1 `
    -ParentCycleId 0 `
    -OutputFingerprint output-fingerprint-resume-delay-001 `
    -AsJson
$publishMarker = Get-Content -LiteralPath $target01.PublishReadyPath -Raw -Encoding UTF8 | ConvertFrom-Json
$publishMarker.PublishedAt = (Get-Date).ToString('o')
$publishMarker | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $target01.PublishReadyPath -Encoding UTF8

$watchDelayJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchDelay = $watchDelayJson | ConvertFrom-Json
Assert-True ([int]$watchDelay.QueuedCount -eq 0) 'initial delayed publish-ready sweep should not queue before eligibility.'

$delayState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$delayTarget = $delayState.Targets.target01
$originalEligibleAt = [string]$delayTarget.PendingDispatchEligibleAt
Assert-True ([string]$delayTarget.Phase -eq 'dispatch-delay') 'target should enter dispatch-delay before pause.'
Assert-True ([string]$delayTarget.NextAction -eq 'wait-dispatch-delay') 'target should expose wait-dispatch-delay before pause.'
Assert-True (([string]$originalEligibleAt).Length -gt 0) 'target should record pending dispatch due time before pause.'
Assert-True ([int]$delayTarget.PendingDispatchDelaySeconds -eq 30) 'target should keep the fixed thirty-second publish-ready delay.'

$pauseRequest = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action pause `
    -RequestedBy 'tests\Test-TargetAutoloopResumeContinuesPendingDelay.ps1:pause' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$pauseRequest.Ok) 'pause request should succeed for delayed publish-ready target.'
$pauseControlSidecar = Get-Content -LiteralPath ([string]$target01.TargetControlPath) -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$pauseControlSidecar.SidecarKind -eq 'target-control') 'pause request should refresh the target control sidecar kind.'
Assert-True ([string]$pauseControlSidecar.TargetId -eq 'target01') 'pause request should refresh the target control sidecar scope.'
Assert-True ([string]$pauseControlSidecar.Action -eq 'pause') 'pause request should immediately expose pending pause in the target control sidecar.'
Assert-True ([string]$pauseControlSidecar.RequestId -eq [string]$pauseRequest.RequestId) 'pause request should mirror the pending request id into the target control sidecar.'

$null = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson

$pausedStatus = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$pausedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$pausedTarget = $pausedState.Targets.target01
Assert-True ([string]$pausedStatus.ControllerState -eq 'paused') 'controller state should become paused.'
Assert-True ([string]$pausedTarget.Phase -eq 'paused') 'paused controller should pause the delayed target.'
Assert-True ([string]$pausedTarget.PausedPhase -eq 'dispatch-delay') 'paused target should remember dispatch-delay phase.'
Assert-True ([string]$pausedTarget.PausedNextAction -eq 'wait-dispatch-delay') 'paused target should remember dispatch-delay next action.'
Assert-True ([string]$pausedTarget.PendingDispatchEligibleAt -eq $originalEligibleAt) 'pause should preserve the existing pending dispatch due time.'
$pausedStateSidecar = Get-Content -LiteralPath ([string]$target01.TargetStatePath) -Raw -Encoding UTF8 | ConvertFrom-Json
$pausedStatusSidecar = Get-Content -LiteralPath ([string]$target01.TargetStatusPath) -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$pausedStateSidecar.Target.Phase -eq 'paused') 'paused watcher sweep should refresh target state sidecar phase.'
Assert-True ([string]$pausedStatusSidecar.ControllerState -eq 'paused') 'paused watcher sweep should refresh target status sidecar controller state.'
Assert-True ([string]$pausedStatusSidecar.Target.Phase -eq 'paused') 'paused watcher sweep should refresh target status sidecar target row.'

$duePublishedAt = (Get-Date).AddSeconds(-60)
$publishMarker = Get-Content -LiteralPath $target01.PublishReadyPath -Raw -Encoding UTF8 | ConvertFrom-Json
$publishMarker.PublishedAt = $duePublishedAt.ToString('o')
$publishMarker | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $target01.PublishReadyPath -Encoding UTF8
(Get-Item -LiteralPath $target01.PublishReadyPath).LastWriteTime = $duePublishedAt
$expectedEligibleAtAfterPause = ([datetimeoffset](Get-Item -LiteralPath $target01.PublishReadyPath).LastWriteTime).AddSeconds(30).ToString('o')

$watchWhilePausedJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchWhilePaused = $watchWhilePausedJson | ConvertFrom-Json
Assert-True ([int]$watchWhilePaused.QueuedCount -eq 1) 'paused controller should keep detecting and queue the due publish-ready command.'

$pausedQueueFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
$pausedStateAfterDue = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$pausedTargetAfterDue = $pausedStateAfterDue.Targets.target01
Assert-True (@($pausedQueueFiles).Count -eq 1) 'one queued command should appear while pause is active after the due time.'
Assert-True ([string]$pausedTargetAfterDue.Phase -eq 'queued') 'target should show queued after pause-time detection creates the command.'
Assert-True ([string]$pausedTargetAfterDue.PendingTriggerKind -eq '') 'pending delayed trigger bookkeeping should clear after paused queue.'

$blockedWorkerJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -ProcessOnce `
    -AsJson
$blockedWorker = $blockedWorkerJson | ConvertFrom-Json
Assert-True ([int]$blockedWorker.ProcessedCount -eq 0) 'paused controller should still block dispatch for the queued delayed command.'
Assert-True ([string]$blockedWorker.LastResult.State -eq 'blocked-by-controller') 'paused delayed command dispatch should be blocked by controller.'

$resumeRequest = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action resume `
    -RequestedBy 'tests\Test-TargetAutoloopResumeContinuesPendingDelay.ps1:resume' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$resumeRequest.Ok) 'resume request should succeed after delayed pause.'
$resumeControlSidecar = Get-Content -LiteralPath ([string]$target01.TargetControlPath) -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$resumeControlSidecar.Action -eq 'resume') 'resume request should immediately expose pending resume in the target control sidecar.'
Assert-True ([string]$resumeControlSidecar.RequestId -eq [string]$resumeRequest.RequestId) 'resume request should mirror the pending request id into the target control sidecar.'

$watchResumeJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchResume = $watchResumeJson | ConvertFrom-Json
Assert-True ([int]$watchResume.QueuedCount -eq 0) 'resume should not queue a duplicate delayed publish-ready command.'

$resumedStatus = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$queueFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True ([string]$resumedStatus.ControllerState -eq 'running') 'controller state should return to running after resume.'
Assert-True (@($queueFiles).Count -eq 1) 'exactly one queued command should be emitted after resume.'
$resumedStatusSidecar = Get-Content -LiteralPath ([string]$target01.TargetStatusPath) -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$resumedStatusSidecar.ControllerState -eq 'running') 'resume sweep should refresh target status sidecar controller state.'

$command = Get-Content -LiteralPath $queueFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$command.TriggerKind -eq 'publish-ready') 'resumed delayed queue should preserve publish-ready trigger kind.'
Assert-True ([int]$command.PublishReadyDispatchDelaySeconds -eq 30) 'resumed delayed queue should preserve the fixed publish-ready delay.'
Assert-True (([datetimeoffset]$command.DispatchEligibleAt).ToString('o') -eq $expectedEligibleAtAfterPause) 'resumed delayed queue should preserve the recomputed paused dispatch due timestamp.'
Assert-True ([string]$command.PromptSourcePath -eq [string]$target01.LastPromptPath) 'queued delayed command should keep the mutable source prompt path separately.'
Assert-True ([string]$command.PromptFilePath -ne [string]$target01.LastPromptPath) 'queued delayed command should point at an immutable prompt snapshot.'
Assert-True (Test-Path -LiteralPath ([string]$command.PromptFilePath) -PathType Leaf) 'queued delayed command prompt snapshot should exist.'

$queuedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$queuedTarget = $queuedState.Targets.target01
Assert-True ([string]$queuedTarget.Phase -eq 'queued') 'target should move to queued after resumed delayed dispatch.'
Assert-True ([string]$queuedTarget.PendingTriggerKind -eq '') 'pending delayed trigger bookkeeping should clear after resumed queue.'
Assert-True ([string]$queuedTarget.LastHandledOutputFingerprint -eq 'output-fingerprint-resume-delay-001') 'resumed delayed queue should preserve handled output fingerprint.'

$resumedWorkerJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -ProcessOnce `
    -AsJson
$resumedWorker = $resumedWorkerJson | ConvertFrom-Json
Assert-True ([int]$resumedWorker.ProcessedCount -eq 1) 'resume should allow the queued delayed command to dispatch.'
Assert-True ([string]$resumedWorker.LastResult.State -eq 'router-ready-file-created') 'resumed delayed dispatch should create the router ready file.'

Write-Host 'target autoloop resume continues pending delay ok'
