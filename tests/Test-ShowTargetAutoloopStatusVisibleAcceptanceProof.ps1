[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusVisibleAcceptanceProof'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_visible_acceptance_proof'
$stateRoot = Join-Path $runRoot '.state'
$configPath = Join-Path $tmpRoot 'settings.test.psd1'
$inboxTarget01 = Join-Path $tmpRoot 'inbox\target01'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $inboxTarget01 -Force | Out-Null

$configText = @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($inboxTarget01.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-visible-proof' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        PollIntervalMs = 200
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 2 }
        )
    }
}
"@
$configText | Set-Content -LiteralPath $configPath -Encoding UTF8

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json

@{
    RunMode = 'target-autoloop'
    RunRoot = $runRoot
    ControllerState = 'running'
    WatcherState = 'running'
    State = 'running'
    Counts = @{
        TotalTargets = 1
        EnabledTargets = 1
        DispatchDelayTargets = 0
        QueuedTargets = 0
        WaitingOutputTargets = 1
        FailedTargets = 0
        LimitReachedTargets = 0
    }
    Targets = @(
        @{
            TargetId = 'target01'
            Phase = 'waiting-output'
            CycleCount = 1
            MaxCycleCount = 2
            NextAction = 'wait-for-output'
            LastTriggerKind = 'input-file'
            LastDispatchState = 'router-ready-file-created'
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([string]$start.StatusPath) -Encoding UTF8

@{
    GeneratedAt = '2026-05-12T19:40:00+09:00'
    LastUpdatedAt = '2026-05-12T19:41:00+09:00'
    Stage = 'post-cleanup'
    SeedTargetId = 'target01'
    Outcome = @{
        AcceptanceState = 'preflight-passed'
        AcceptanceReason = 'typed-window-preflight-passed'
    }
    PhaseHistory = @(
        @{
            Stage = 'closeout-completed'
            AcceptanceState = 'roundtrip-confirmed'
        },
        @{
            Stage = 'post-cleanup'
            AcceptanceState = 'preflight-passed'
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'live-acceptance-result.json') -Encoding UTF8

$statusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$statusText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

Assert-True ([string]$statusJson.SmokeReceipt.Result -eq 'passed') 'status json should promote visible acceptance success history as passed proof.'
Assert-True ([string]$statusJson.SmokeReceipt.Source -eq 'shared-visible-acceptance') 'status json should mark the visible acceptance proof source.'
Assert-True ([string]$statusJson.SmokeReceipt.ProofLevel -eq 'visible-live') 'status json should mark the visible proof level.'
Assert-True ([string]$statusJson.SmokeReceipt.TargetId -eq 'target01') 'status json should surface the visible acceptance target.'
Assert-True ([string]$statusJson.SmokeReceipt.AcceptanceState -eq 'roundtrip-confirmed') 'status json should use the last success acceptance state from phase history.'
Assert-True ([string]$statusJson.SmokeReceipt.AcceptanceReason -eq 'typed-window-preflight-passed') 'status json should surface the current acceptance reason.'
Assert-True ([string]$statusJson.ProofCloseout.State -eq 'final-pass') 'visible acceptance proof should promote closeout to final-pass.'
Assert-True ([string]$statusJson.ProofCloseout.Mode -eq 'final') 'visible acceptance proof should mark the closeout mode as final.'
Assert-True ($statusText -match 'Counts: .*smoke=passed') 'status text should surface the visible acceptance proof result.'
Assert-True ($statusText -match 'Counts: .*smokeProof=visible-live') 'status text should surface the visible proof level.'
Assert-True ($statusText -match 'Counts: .*smokeSource=shared-visible-acceptance') 'status text should surface the visible proof source.'
Assert-True ($statusText -match 'Counts: .*smokeAcceptance=roundtrip-confirmed') 'status text should surface the effective visible acceptance state.'
Assert-True ($statusText -match 'Counts: .*smokeCycle=1/2') 'status text should surface the current target-autoloop cycle/max evidence for visible proof.'
Assert-True ($statusText -match 'Counts: .*smokeReason=typed-window-preflight-passed') 'status text should surface the visible acceptance reason.'
Assert-True ($statusText -match 'Counts: .*closeout=final-pass') 'status text should surface the final closeout state.'
Assert-True ($statusText -match 'Counts: .*closeoutMode=final') 'status text should surface the final closeout mode.'
Assert-True ($statusText -match 'SmokeSummary: smoke: passed / proof=visible-live / source=shared-visible-acceptance / target=target01 / acceptance=roundtrip-confirmed / reason=typed-window-preflight-passed / cycle=1/2 / stage=post-cleanup') 'status text should surface the compact visible acceptance proof summary.'
Assert-True ($statusText -match 'CloseoutSummary: closeout: final-pass / mode=final / reason=visible-live-passed / proof=visible-live / source=shared-visible-acceptance') 'status text should surface the final closeout summary.'
Assert-True ($statusText -match 'SmokeReceiptPath: .*live-acceptance-result\.json') 'status text should surface the effective visible acceptance receipt path.'

Write-Host 'show target autoloop status visible acceptance proof ok'
