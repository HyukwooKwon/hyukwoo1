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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopControlContract'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_control'
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
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$state.Targets.target01.Phase = 'dispatch-delay'
$state.Targets.target01.NextAction = 'wait-dispatch-delay'
$state.Targets.target01.LastTriggerKind = 'publish-ready'
$state.Targets.target01.LastDispatchState = 'dispatch-delay-waiting'
$state.Targets.target01.PendingDispatchDelaySeconds = 18
$state.Targets.target01.PendingDispatchEligibleAt = (Get-Date).AddSeconds(18).ToString('o')
$state.LastUpdatedAt = (Get-Date).ToString('o')
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatePath -Encoding UTF8

$pauseRequest = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action pause `
    -RequestedBy 'tests\Test-TargetAutoloopControlContract.ps1:pause' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$pauseRequest.Ok) 'pause request should succeed.'
Assert-True ([string]$pauseRequest.ControlPendingAction -eq 'pause') 'pause request should write pending action.'
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
$pausedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$pausedTarget = $pausedState.Targets.target01
Assert-True ([string]$pausedStatus.ControllerState -eq 'paused') 'controller state should become paused after pause ack.'
Assert-True ([string]$pausedStatus.ControlPendingAction -eq '') 'pause ack should clear pending control action.'
Assert-True ([string]$pausedStatus.LastHandledRequestId -eq [string]$pauseRequest.RequestId) 'pause ack should keep request id.'
Assert-True ([string]$pausedStatus.LastHandledAction -eq 'pause') 'pause ack should surface last handled action.'
Assert-True ([string]$pausedStatus.LastHandledResult -eq 'paused') 'pause ack should surface paused result.'
Assert-True ([string]$pausedTarget.Phase -eq 'paused') 'target phase should move to paused while controller is paused.'
Assert-True ([string]$pausedTarget.NextAction -eq 'resume') 'paused target should expose resume next action.'
Assert-True ([string]$pausedTarget.PausedPhase -eq 'dispatch-delay') 'paused target should preserve the original phase.'
Assert-True ([string]$pausedTarget.PausedNextAction -eq 'wait-dispatch-delay') 'paused target should preserve the original next action.'

$resumeRequest = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action resume `
    -RequestedBy 'tests\Test-TargetAutoloopControlContract.ps1:resume' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$resumeRequest.Ok) 'resume request should succeed.'
Assert-True ([string]$resumeRequest.ControlPendingAction -eq 'resume') 'resume request should write pending action.'
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
$resumedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$resumedTarget = $resumedState.Targets.target01
Assert-True ([string]$resumedStatus.ControllerState -eq 'running') 'controller state should return to running after resume ack.'
Assert-True ([string]$resumedStatus.ControlPendingAction -eq '') 'resume ack should clear pending control action.'
Assert-True ([string]$resumedStatus.LastHandledRequestId -eq [string]$resumeRequest.RequestId) 'resume ack should keep request id.'
Assert-True ([string]$resumedStatus.LastHandledAction -eq 'resume') 'resume ack should surface last handled action.'
Assert-True ([string]$resumedStatus.LastHandledResult -eq 'resumed') 'resume ack should surface resumed result.'
Assert-True ([string]$resumedTarget.Phase -eq 'dispatch-delay') 'resume should restore the preserved dispatch-delay phase.'
Assert-True ([string]$resumedTarget.NextAction -eq 'wait-dispatch-delay') 'resume should restore the preserved next action.'
Assert-True ([string]$resumedTarget.PausedPhase -eq '') 'resume should clear paused phase bookkeeping.'
Assert-True ([string]$resumedTarget.PausedNextAction -eq '') 'resume should clear paused next action bookkeeping.'

$stopRequest = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action stop `
    -RequestedBy 'tests\Test-TargetAutoloopControlContract.ps1:stop' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$stopRequest.Ok) 'stop request should succeed.'
Assert-True ([string]$stopRequest.ControlPendingAction -eq 'stop') 'stop request should write pending action.'
Assert-True (([string]$stopRequest.RequestId).Length -gt 0) 'stop request should allocate request id.'

$null = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson

$stoppedStatus = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$stoppedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$stoppedTarget = $stoppedState.Targets.target01
Assert-True ([string]$stoppedStatus.ControllerState -eq 'stopped') 'controller state should become stopped after stop ack.'
Assert-True ([string]$stoppedStatus.ControlPendingAction -eq '') 'stop ack should clear pending control action.'
Assert-True ([string]$stoppedStatus.LastHandledRequestId -eq [string]$stopRequest.RequestId) 'stop ack should keep request id.'
Assert-True ([string]$stoppedStatus.LastHandledAction -eq 'stop') 'stop ack should surface last handled action.'
Assert-True ([string]$stoppedStatus.LastHandledResult -eq 'stopped') 'stop ack should surface stopped result.'
Assert-True ([string]$stoppedTarget.Phase -eq 'stopped') 'stop should force target phase to stopped.'
Assert-True ([string]$stoppedTarget.NextAction -eq 'stopped') 'stop should force target next action to stopped.'

Write-Host 'target autoloop control contract ok'
