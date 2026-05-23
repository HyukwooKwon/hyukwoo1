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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopCycleLimitCloseout'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_cycle_limit'
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
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready'); MaxCycleCount = 2 }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'summary ready but cycle limit already reached'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'zip payload for cycle limit closeout'
if (Test-Path -LiteralPath $target01.SourceReviewZipPath) {
    Remove-Item -LiteralPath $target01.SourceReviewZipPath -Force
}
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 2 `
    -ParentCycleId 1 `
    -OutputFingerprint output-fingerprint-cycle-limit-001 `
    -AsJson

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$state.Targets.target01.CycleCount = 2
$state.Targets.target01.LastCycleId = 2
$state.Targets.target01.LastParentCycleId = 1
$state.Targets.target01.Phase = 'waiting-output'
$state.Targets.target01.NextAction = 'wait-for-output'
$state.Targets.target01.LastTriggerKind = 'publish-ready'
$state.LastUpdatedAt = (Get-Date).ToString('o')
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatePath -Encoding UTF8

$watchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchResult = $watchJson | ConvertFrom-Json

Assert-True ([int]$watchResult.QueuedCount -eq 0) 'cycle limit closeout should prevent queuing when max cycle count is reached.'
Assert-True ([string]$watchResult.WatcherStopReason -eq 'all-targets-limit-reached') 'cycle limit closeout should stop the watcher when every selected target reached the limit.'

$queueFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queueFiles).Count -eq 0) 'no queued command should exist after cycle limit closeout.'

$finalState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$finalTarget = $finalState.Targets.target01
Assert-True ([string]$finalState.State -eq 'stopped') 'state document should move to stopped after cycle limit closeout.'
Assert-True ([string]$finalTarget.Phase -eq 'limit-reached') 'target phase should become limit-reached after cycle limit closeout.'
Assert-True ([string]$finalTarget.NextAction -eq 'limit-reached') 'target next action should become limit-reached after cycle limit closeout.'
Assert-True ([int]$finalTarget.CycleCount -eq 2) 'cycle limit closeout should preserve the current cycle count.'

$control = Get-Content -LiteralPath $start.ControlPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$control.State -eq 'stopped') 'control document should become stopped after cycle limit closeout.'
Assert-True ([string]$control.Action -eq '') 'cycle limit closeout should not leave a pending control action.'

$statusJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
Assert-True ([string]$statusJson.ControllerState -eq 'stopped') 'status json should surface stopped controller state after cycle limit closeout.'
Assert-True ([string]$statusJson.WatcherStopReason -eq 'all-targets-limit-reached') 'status json should surface the cycle limit closeout watcher stop reason.'
Assert-True ([int]$statusJson.Counts.LimitReachedTargets -eq 1) 'status json should count limit-reached targets.'
Assert-True ([string]$statusJson.Targets[0].Phase -eq 'limit-reached') 'status json should surface limit-reached phase.'

$output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$joined = (@($output) -join "`n")
Assert-True ($joined -match 'Counts: .*limit=1') 'status output should surface the limit reached count in the summary line.'
Assert-True ($joined -match 'Counts: .*watchStop=all-targets-limit-reached') 'status output should surface the cycle limit closeout stop reason in the summary line.'
Assert-True ($joined -match 'target01 \| limit-reached \| cycle 2/2') 'status output should surface the limit-reached target row with cycle progress.'

Write-Host 'target autoloop cycle limit closeout ok'
