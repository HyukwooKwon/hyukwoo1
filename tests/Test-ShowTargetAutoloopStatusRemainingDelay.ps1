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
$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusRemainingDelay'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_status'
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
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready'); PublishReadyDispatchMinDelaySeconds = 15; PublishReadyDispatchMaxDelaySeconds = 30 }
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
$targetState = $state.Targets.target01
$targetState.Phase = 'dispatch-delay'
$targetState.CycleCount = 2
$targetState.NextAction = 'wait-dispatch-delay'
$targetState.LastTriggerKind = 'publish-ready'
$targetState.LastDispatchState = 'dispatch-delay-waiting'
$targetState.PublishReadyDispatchDelayMode = 'range'
$targetState.PublishReadyDispatchMinDelaySeconds = 15
$targetState.PublishReadyDispatchMaxDelaySeconds = 30
$targetState.PendingDispatchDelaySeconds = 21
$targetState.PendingDispatchEligibleAt = (Get-Date).AddSeconds(21).ToString('o')
$state.LastUpdatedAt = (Get-Date).ToString('o')
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatePath -Encoding UTF8

$status = Get-Content -LiteralPath $start.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$status.Counts.DispatchDelayTargets = 1
$status.Targets[0].Phase = 'dispatch-delay'
$status.Targets[0].CycleCount = 2
$status.Targets[0].NextAction = 'wait-dispatch-delay'
$status.Targets[0].LastTriggerKind = 'publish-ready'
$status.Targets[0].LastDispatchState = 'dispatch-delay-waiting'
$status.Targets[0].PublishReadyDispatchDelayMode = 'range'
$status.Targets[0].PublishReadyDispatchMinDelaySeconds = 15
$status.Targets[0].PublishReadyDispatchMaxDelaySeconds = 30
$status.Targets[0].PendingDispatchDelaySeconds = 21
$status.Targets[0].PendingDispatchEligibleAt = $targetState.PendingDispatchEligibleAt
$status.LastUpdatedAt = (Get-Date).ToString('o')
$status | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatusPath -Encoding UTF8

$statusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

$delaySummary = $statusJson.DelaySummary
Assert-True ([string]$delaySummary.State -eq 'dispatch-delay-waiting') 'status json should surface dispatch-delay waiting state.'
Assert-True ([string]$delaySummary.TargetId -eq 'target01') 'status json should surface delay target id.'
Assert-True ([string]$delaySummary.DelayRange -eq '15-30s') 'status json should surface delay range.'
$actualDueAt = ([datetimeoffset]$delaySummary.DueAt).ToString('o')
Assert-True ($actualDueAt -eq [string]$targetState.PendingDispatchEligibleAt) 'status json should surface due timestamp.'

$output = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

$joined = (@($output) -join "`n")
Assert-True ($joined -match 'pendingDelay: 21s') 'status output should include pending dispatch delay.'
Assert-True ($joined -match 'eligibleAt: ') 'status output should include dispatch eligible timestamp.'
Assert-True ($joined -match 'remaining: \d+s') 'status output should include remaining dispatch wait seconds.'
Assert-True ($joined -match 'Counts: .*delayState=dispatch-delay-waiting') 'status output should surface delay state in the summary line.'
Assert-True ($joined -match 'Counts: .*minRemaining=\d+s') 'status output should surface minimum remaining delay in the summary line.'
Assert-True ($joined -match 'Counts: .*delayTarget=target01') 'status output should surface the earliest delayed target in the summary line.'
Assert-True ($joined -match 'Counts: .*delayRange=15-30s') 'status output should surface the earliest delayed target range in the summary line.'
Assert-True ($joined -match ('Counts: .*delayDueAt=' + [regex]::Escape([string]$targetState.PendingDispatchEligibleAt))) 'status output should surface the earliest delayed target due timestamp in the summary line.'
Assert-True ($joined -match 'target01 \| dispatch-delay \| cycle 2/10') 'status output should include cycle progress with the configured maximum.'

Write-Host 'show target autoloop status remaining delay ok'
