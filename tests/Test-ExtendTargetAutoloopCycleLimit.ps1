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
Assert-True ([string]$extendedState.Targets.target01.Phase -eq 'idle') 'extension should release the limit-reached phase.'
Assert-True ([string]$extendedState.Targets.target01.NextAction -eq 'wait-for-output') 'extension should restore publish-ready wait next action.'
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

Write-Host 'target autoloop cycle limit extension ok'
