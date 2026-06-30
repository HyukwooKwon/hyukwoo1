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
$tmpRoot = Join-Path $root '_tmp\Test-ExtendTargetAutoloopCycleLimit'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_extend_limit'
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

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'summary ready for cycle extension'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'zip payload for cycle extension'
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
$null = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 2 `
    -ParentCycleId 1 `
    -OutputFingerprint output-fingerprint-cycle-extension-001 `
    -AsJson

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$state.Targets.target01.CycleCount = 2
$state.Targets.target01.LastCycleId = 2
$state.Targets.target01.LastParentCycleId = 1
$state.Targets.target01.Phase = 'waiting-output'
$state.Targets.target01.NextAction = 'wait-for-output'
$state.Targets.target01.LastTriggerKind = 'publish-ready'
$state.Targets.target01.LastRouterReadyPath = (Join-Path $routerInboxRoot 'last-cycle.ready.txt')
$state.Targets.target01.LastDispatchState = 'router-ready-file-created'
$state.Targets.target01.LastCommandId = 'target01-cycle-000002-test'
$state.LastUpdatedAt = (Get-Date).ToString('o')
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatePath -Encoding UTF8

$null = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson

$limitedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$limitedState.State -eq 'stopped') 'precondition: state should stop at cycle limit.'
Assert-True ([string]$limitedState.Targets.target01.Phase -eq 'limit-reached') 'precondition: target should be limit-reached.'

$extendJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Extend-TargetAutoloopCycleLimit.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -AdditionalCycles 3 `
    -AsJson
$extend = $extendJson | ConvertFrom-Json
Assert-True ([bool]$extend.Ok) 'extension helper should return Ok.'
Assert-True ([int]$extend.BeforeMaxCycleCount -eq 2) 'extension should report previous max cycle count.'
Assert-True ([int]$extend.AfterMaxCycleCount -eq 5) 'extension should add cycles to the current limit.'

$extendedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$extendedControl = Get-Content -LiteralPath $start.ControlPath -Raw -Encoding UTF8 | ConvertFrom-Json
$extendedManifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$extendedManifestTarget = @($extendedManifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$extendedState.State -eq 'running') 'extension should reopen the state document for a restarted watcher.'
Assert-True ([string]$extendedControl.State -eq 'running') 'extension should reopen the control document for a restarted watcher.'
Assert-True ([int]$extendedState.Targets.target01.MaxCycleCount -eq 5) 'extension should update state target max cycle count.'
Assert-True ([int]$extendedManifestTarget.MaxCycleCount -eq 5) 'extension should update manifest target max cycle count.'
Assert-True ([string]$extendedState.Targets.target01.Phase -eq 'waiting-output') 'extension should restore the in-flight final cycle output wait.'
Assert-True ([string]$extendedState.Targets.target01.NextAction -eq 'wait-for-output') 'extension should restore publish-ready wait next action.'
Assert-True ([string]$extendedState.Targets.target01.LastDispatchState -eq 'router-ready-file-created') 'extension should preserve the final cycle router dispatch state.'
Assert-True ([bool]$extend.RestoredWaitingOutput) 'extension payload should report waiting-output restoration.'
Assert-True (Test-Path -LiteralPath $extend.ExtensionPath -PathType Leaf) 'extension receipt should be written.'

$watchAfterExtendJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchAfterExtend = $watchAfterExtendJson | ConvertFrom-Json
Assert-True ([int]$watchAfterExtend.QueuedCount -eq 1) 'extended run should queue the next publish-ready cycle.'

$finalState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([int]$finalState.Targets.target01.CycleCount -eq 3) 'extended run should continue with the next cycle.'
Assert-True ([int]$finalState.Targets.target01.MaxCycleCount -eq 5) 'extended run should keep the new max cycle count.'

$earlyRunRoot = Join-Path $tmpRoot 'run_target_autoloop_extend_early'
$earlyStartJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $earlyRunRoot `
    -Targets target01 `
    -RunMode target-autoloop `
    -AsJson
$earlyStart = $earlyStartJson | ConvertFrom-Json
$earlyState = Get-Content -LiteralPath $earlyStart.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$earlyState.Targets.target01.CycleCount = 1
$earlyState.Targets.target01.Phase = 'queued'
$earlyState.Targets.target01.NextAction = 'dispatch-router-ready'
$earlyState.Targets.target01.LastDispatchState = 'queued-for-router'
$earlyState.Targets.target01.LastFailureReason = 'operator-check'
$earlyState.LastUpdatedAt = (Get-Date).ToString('o')
$earlyState | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $earlyStart.StatePath -Encoding UTF8

$earlyExtendJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Extend-TargetAutoloopCycleLimit.ps1') `
    -ConfigPath $configPath `
    -RunRoot $earlyRunRoot `
    -TargetId target01 `
    -AdditionalCycles 3 `
    -AsJson
$earlyExtend = $earlyExtendJson | ConvertFrom-Json
Assert-True ([bool]$earlyExtend.Ok) 'early extension helper should return Ok.'
Assert-True (-not [bool]$earlyExtend.LimitReachedBeforeExtension) 'early extension should report that max was not reached.'
Assert-True ([bool]$earlyExtend.PreservedInFlightState) 'early extension should preserve in-flight state.'
Assert-True ([int]$earlyExtend.BeforeMaxCycleCount -eq 2) 'early extension should report previous max cycle count.'
Assert-True ([int]$earlyExtend.AfterMaxCycleCount -eq 5) 'early extension should add cycles to the existing max.'
Assert-True ([string]$earlyExtend.NextPhase -eq 'queued') 'early extension payload should keep queued phase.'
Assert-True ([string]$earlyExtend.NextAction -eq 'dispatch-router-ready') 'early extension payload should keep next action.'

$earlyExtendedState = Get-Content -LiteralPath $earlyStart.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$earlyExtendedManifest = Get-Content -LiteralPath $earlyStart.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$earlyExtendedManifestTarget = @($earlyExtendedManifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([int]$earlyExtendedState.Targets.target01.CycleCount -eq 1) 'early extension should keep current cycle count.'
Assert-True ([int]$earlyExtendedState.Targets.target01.MaxCycleCount -eq 5) 'early extension should update state max cycle count.'
Assert-True ([int]$earlyExtendedManifestTarget.MaxCycleCount -eq 5) 'early extension should update manifest max cycle count.'
Assert-True ([string]$earlyExtendedState.Targets.target01.Phase -eq 'queued') 'early extension should preserve target phase.'
Assert-True ([string]$earlyExtendedState.Targets.target01.NextAction -eq 'dispatch-router-ready') 'early extension should preserve target next action.'
Assert-True ([string]$earlyExtendedState.Targets.target01.LastDispatchState -eq 'queued-for-router') 'early extension should preserve dispatch state.'
Assert-True ([string]$earlyExtendedState.Targets.target01.LastFailureReason -eq 'operator-check') 'early extension should preserve failure detail outside limit recovery.'

Write-Host 'target autoloop cycle limit extension ok'
