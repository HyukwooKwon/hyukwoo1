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
$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusDelayState'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_status_delay_state'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
        @{ Id = 'target02'; Folder = 'C:\tmp\target02'; WindowTitle = 'Target02'; FixedSuffix = 'suffix-02' }
        @{ Id = 'target03'; Folder = 'C:\tmp\target03'; WindowTitle = 'Target03'; FixedSuffix = 'suffix-03' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready'); PublishReadyDispatchMinDelaySeconds = 15; PublishReadyDispatchMaxDelaySeconds = 30 }
            @{ TargetId = 'target02'; Enabled = `$true; TriggerKinds = @('publish-ready'); PublishReadyDispatchDelaySeconds = 15 }
            @{ TargetId = 'target03'; Enabled = `$true; TriggerKinds = @('publish-ready'); PublishReadyDispatchDelaySeconds = 10 }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json

$futureEligibleAt = (Get-Date).AddSeconds(45).ToString('o')
$pastEligibleAt = (Get-Date).AddSeconds(-8).ToString('o')

$dueStatus = [ordered]@{
    SchemaVersion = '1.0.0'
    RunMode = 'target-autoloop'
    RunRoot = $runRoot
    ControllerState = 'running'
    State = 'running'
    LastUpdatedAt = (Get-Date).ToString('o')
    Counts = [ordered]@{
        TotalTargets = 3
        EnabledTargets = 3
        DispatchDelayTargets = 1
        QueuedTargets = 1
        WaitingOutputTargets = 0
        FailedTargets = 1
        LimitReachedTargets = 0
    }
    Targets = @(
        [ordered]@{
            TargetId = 'target01'
            Phase = 'queued'
            CycleCount = 4
            MaxCycleCount = 10
            NextAction = 'dispatch-command'
            LastTriggerKind = 'publish-ready'
            LastDispatchState = 'router-ready-file-created'
            PublishReadyDispatchDelayMode = 'range'
            PublishReadyDispatchMinDelaySeconds = 15
            PublishReadyDispatchMaxDelaySeconds = 30
            PendingDispatchDelaySeconds = 25
            PendingDispatchEligibleAt = $futureEligibleAt
            LastFailureReason = ''
        }
        [ordered]@{
            TargetId = 'target02'
            Phase = 'dispatch-delay'
            CycleCount = 2
            MaxCycleCount = 10
            NextAction = 'wait-dispatch-delay'
            LastTriggerKind = 'publish-ready'
            LastDispatchState = 'dispatch-delay-waiting'
            PublishReadyDispatchDelayMode = 'fixed'
            PublishReadyDispatchDelaySeconds = 15
            PublishReadyDispatchMinDelaySeconds = 15
            PublishReadyDispatchMaxDelaySeconds = 15
            PendingDispatchDelaySeconds = 15
            PendingDispatchEligibleAt = $pastEligibleAt
            LastFailureReason = ''
        }
        [ordered]@{
            TargetId = 'target03'
            Phase = 'failed'
            CycleCount = 1
            MaxCycleCount = 10
            NextAction = 'open-receipt'
            LastTriggerKind = 'input-file'
            LastDispatchState = 'relay-folder-preflight-failed'
            LastFailureReason = 'relay target mismatch'
        }
    )
}
$dueStatus | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatusPath -Encoding UTF8

$dueJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$dueJson.DelaySummary.State -eq 'dispatch-delay-due') 'status json should surface due delay state.'
Assert-True ([string]$dueJson.DelaySummary.TargetId -eq 'target02') 'status json should ignore stale queued delay fields and pick the real dispatch-delay row.'
$actualDueAt = ([datetimeoffset]$dueJson.DelaySummary.DueAt).ToString('o')
Assert-True ($actualDueAt -eq $pastEligibleAt) 'status json should surface due timestamp for the selected delayed target.'

$dueOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$dueJoined = (@($dueOutput) -join "`n")
$target01Line = @($dueOutput | Where-Object { [string]$_ -match '^target01 \|' } | Select-Object -First 1)[0]
Assert-True ($dueJoined -match 'Counts: .*delayState=dispatch-delay-due') 'status output should surface due delay state.'
Assert-True ($dueJoined -match 'Counts: .*delayTarget=target02') 'status output should surface the due delayed target.'
Assert-True ($dueJoined -notmatch 'Counts: .*minRemaining=') 'due delay state should not surface minRemaining in the summary line.'
Assert-True ([string]$target01Line -notmatch 'eligibleAt:') 'queued stale rows should not surface delay-specific fields in detail output.'

$invalidStatus = [ordered]@{
    SchemaVersion = '1.0.0'
    RunMode = 'target-autoloop'
    RunRoot = $runRoot
    ControllerState = 'running'
    State = 'running'
    LastUpdatedAt = (Get-Date).ToString('o')
    Counts = [ordered]@{
        TotalTargets = 3
        EnabledTargets = 3
        DispatchDelayTargets = 1
        QueuedTargets = 1
        WaitingOutputTargets = 0
        FailedTargets = 1
        LimitReachedTargets = 0
    }
    Targets = @(
        [ordered]@{
            TargetId = 'target01'
            Phase = 'queued'
            CycleCount = 4
            MaxCycleCount = 10
            NextAction = 'dispatch-command'
            LastTriggerKind = 'publish-ready'
            LastDispatchState = 'router-ready-file-created'
            LastFailureReason = ''
        }
        [ordered]@{
            TargetId = 'target02'
            Phase = 'dispatch-delay'
            CycleCount = 2
            MaxCycleCount = 10
            NextAction = 'wait-dispatch-delay'
            LastTriggerKind = 'publish-ready'
            LastDispatchState = 'dispatch-delay-waiting'
            PublishReadyDispatchDelayMode = 'fixed'
            PublishReadyDispatchDelaySeconds = 15
            PublishReadyDispatchMinDelaySeconds = 15
            PublishReadyDispatchMaxDelaySeconds = 15
            PendingDispatchDelaySeconds = 15
            PendingDispatchEligibleAt = 'not-a-time'
            LastFailureReason = ''
        }
        [ordered]@{
            TargetId = 'target03'
            Phase = 'failed'
            CycleCount = 1
            MaxCycleCount = 10
            NextAction = 'open-receipt'
            LastTriggerKind = 'input-file'
            LastDispatchState = 'relay-folder-preflight-failed'
            LastFailureReason = 'relay target mismatch'
        }
    )
}
$invalidStatus | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatusPath -Encoding UTF8

$invalidOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$invalidJoined = (@($invalidOutput) -join "`n")
Assert-True ($invalidJoined -match 'Counts: .*delayState=dispatch-delay-invalid') 'status output should surface invalid delay state.'
Assert-True ($invalidJoined -match 'Counts: .*delayTarget=target02') 'status output should surface invalid delayed target.'
Assert-True ($invalidJoined -match 'Counts: .*delayDueAt=not-a-time') 'status output should surface the original invalid due timestamp.'

Write-Host 'show target autoloop status delay state ok'
