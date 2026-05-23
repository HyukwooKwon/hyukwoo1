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
. (Join-Path $root 'tests\TargetAutoloopConfig.ps1')
$externalWorkRoot = 'C:\dev\python\relay-target-autoloop-live-smoke\Test-TargetAutoloopOneTargetLiveSmoke'
$routerInboxRoot = Join-Path $externalWorkRoot 'router-inbox\target01'
$runRoot = Join-Path $externalWorkRoot '.relay-runs\target-autoloop-one-target-live-smoke'
$configPath = Join-Path $root '_tmp\Test-TargetAutoloopOneTargetLiveSmoke.settings.psd1'

if (Test-Path -LiteralPath $externalWorkRoot) {
    Remove-Item -LiteralPath $externalWorkRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $externalWorkRoot -Force | Out-Null
New-Item -ItemType Directory -Path $routerInboxRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($routerInboxRoot.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-live-smoke' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        PollIntervalMs = 200
        DefaultPublishReadyDispatchDelaySeconds = 0
        DefaultPublishReadyDispatchMinDelaySeconds = 0
        DefaultPublishReadyDispatchMaxDelaySeconds = 0
        RunRootBase = '$($externalWorkRoot.Replace("'", "''"))\.relay-runs'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 2 }
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

Assert-True ([string]$start.RunRoot -like 'C:\dev\python\relay-target-autoloop-live-smoke*') 'smoke runroot should stay outside the automation repo.'
Assert-True ([string]$target01.SourceSummaryPath -like 'C:\dev\python\relay-target-autoloop-live-smoke*') 'source summary contract path should stay outside the automation repo.'
Assert-True ([string]$target01.SourceReviewZipPath -like 'C:\dev\python\relay-target-autoloop-live-smoke*') 'source review zip contract path should stay outside the automation repo.'
Assert-True ([string]$target01.PublishReadyPath -like 'C:\dev\python\relay-target-autoloop-live-smoke*') 'publish-ready contract path should stay outside the automation repo.'

$inputPath = Join-Path $target01.InboxPendingRoot 'task_live_smoke_001.txt'
Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'single target live smoke cycle 1 input'

$cycle1WatchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -DispatchQueuedCommandsInline `
    -ProcessOnce `
    -AsJson
$cycle1Watch = $cycle1WatchJson | ConvertFrom-Json
Assert-True ([int]$cycle1Watch.QueuedCount -eq 1) 'cycle 1 input trigger should queue one command.'
Assert-True ([int]$cycle1Watch.DispatchedCount -eq 1) 'cycle 1 input trigger should dispatch one command inline.'

$readyFilesAfterCycle1 = @(Get-ChildItem -LiteralPath $routerInboxRoot -File -Filter '*.ready.txt' | Sort-Object Name)
$completedFilesAfterCycle1 = @(Get-ChildItem -LiteralPath $target01.QueueCompletedRoot -File -Filter '*.json' | Sort-Object Name)
$stateAfterCycle1 = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetAfterCycle1 = $stateAfterCycle1.Targets.target01
Assert-True (@($readyFilesAfterCycle1).Count -eq 1) 'cycle 1 should create exactly one ready file.'
Assert-True (@($completedFilesAfterCycle1).Count -eq 1) 'cycle 1 should archive one completed queue command.'
Assert-True ([string]$targetAfterCycle1.Phase -eq 'waiting-output') 'cycle 1 should leave the target waiting for output.'
Assert-True ([int]$targetAfterCycle1.CycleCount -eq 1) 'cycle 1 should increment cycle count to 1.'
Assert-True ([string]$targetAfterCycle1.LastDispatchState -eq 'router-ready-file-created') 'cycle 1 should record router-ready dispatch state.'

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'cycle 1 output summary ready for next target-autoloop cycle'
$cycle1ZipNotePath = Join-Path $target01.SourceOutboxPath 'cycle1_note.txt'
Set-Content -LiteralPath $cycle1ZipNotePath -Encoding UTF8 -Value 'cycle 1 zip payload'
if (Test-Path -LiteralPath $target01.SourceReviewZipPath) {
    Remove-Item -LiteralPath $target01.SourceReviewZipPath -Force
}
Compress-Archive -LiteralPath $cycle1ZipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
$publish1Json = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 1 `
    -ParentCycleId 0 `
    -OutputFingerprint output-fingerprint-live-smoke-001 `
    -Overwrite `
    -AsJson
$publish1 = $publish1Json | ConvertFrom-Json
Assert-True ([string]$publish1.Marker.OutputFingerprint -eq 'output-fingerprint-live-smoke-001') 'cycle 1 publish-ready artifact should keep the requested fingerprint.'

$cycle2WatchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -DispatchQueuedCommandsInline `
    -ProcessOnce `
    -AsJson
$cycle2Watch = $cycle2WatchJson | ConvertFrom-Json
Assert-True ([int]$cycle2Watch.QueuedCount -eq 1) 'cycle 2 publish-ready trigger should queue one next-cycle command.'
Assert-True ([int]$cycle2Watch.DispatchedCount -eq 1) 'cycle 2 publish-ready trigger should dispatch one next-cycle command inline.'

$readyFilesAfterCycle2 = @(Get-ChildItem -LiteralPath $routerInboxRoot -File -Filter '*.ready.txt' | Sort-Object Name)
$completedFilesAfterCycle2 = @(Get-ChildItem -LiteralPath $target01.QueueCompletedRoot -File -Filter '*.json' | Sort-Object Name)
$stateAfterCycle2 = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetAfterCycle2 = $stateAfterCycle2.Targets.target01
Assert-True (@($readyFilesAfterCycle2).Count -eq 2) 'cycle 2 should create a second ready file.'
Assert-True (@($completedFilesAfterCycle2).Count -eq 2) 'cycle 2 should archive two completed queue commands total.'
Assert-True ([string]$targetAfterCycle2.Phase -eq 'waiting-output') 'cycle 2 should leave the target waiting for output again.'
Assert-True ([int]$targetAfterCycle2.CycleCount -eq 2) 'cycle 2 should increment cycle count to 2.'
Assert-True ([string]$targetAfterCycle2.LastHandledOutputFingerprint -eq 'output-fingerprint-live-smoke-001') 'cycle 2 should preserve the previous output fingerprint as the handled trigger source.'

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'cycle 2 output summary should not trigger cycle 3 because max cycle count is reached'
$cycle2ZipNotePath = Join-Path $target01.SourceOutboxPath 'cycle2_note.txt'
Set-Content -LiteralPath $cycle2ZipNotePath -Encoding UTF8 -Value 'cycle 2 zip payload'
if (Test-Path -LiteralPath $target01.SourceReviewZipPath) {
    Remove-Item -LiteralPath $target01.SourceReviewZipPath -Force
}
Compress-Archive -LiteralPath $cycle2ZipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
$publish2Json = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 2 `
    -ParentCycleId 1 `
    -OutputFingerprint output-fingerprint-live-smoke-002 `
    -Overwrite `
    -AsJson
$publish2 = $publish2Json | ConvertFrom-Json
Assert-True ([string]$publish2.Marker.OutputFingerprint -eq 'output-fingerprint-live-smoke-002') 'cycle 2 publish-ready artifact should keep the requested fingerprint.'

$closeoutWatchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -DispatchQueuedCommandsInline `
    -ProcessOnce `
    -AsJson
$closeoutWatch = $closeoutWatchJson | ConvertFrom-Json
Assert-True ([int]$closeoutWatch.QueuedCount -eq 0) 'max cycle count should prevent a third queued command.'
Assert-True ([int]$closeoutWatch.DispatchedCount -eq 0) 'max cycle count should prevent a third dispatch.'
Assert-True ([string]$closeoutWatch.WatcherStopReason -eq 'all-targets-limit-reached') 'max cycle count should end the smoke with all-targets-limit-reached.'

$smokeReceiptPath = [string]$start.SmokeReceiptPath
Write-TargetAutoloopSmokeReceipt `
    -Path $smokeReceiptPath `
    -Scenario 'one-target-live-smoke' `
    -Result 'passed' `
    -Source 'script-smoke' `
    -ProofLevel 'script-level' `
    -RunRoot $runRoot `
    -TargetId 'target01' `
    -CycleCount 2 `
    -MaxCycleCount 2 `
    -FinalPhase 'limit-reached' `
    -WatcherStopReason 'all-targets-limit-reached' | Out-Null

$finalStatus = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$finalStatusText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$finalState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$finalTarget = $finalState.Targets.target01
$queuedFilesFinal = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True ([string]$finalStatus.ControllerState -eq 'stopped') 'final controller state should be stopped after smoke closeout.'
Assert-True ([string]$finalStatus.WatcherStopReason -eq 'all-targets-limit-reached') 'final status should surface the limit closeout reason.'
Assert-True ([int]$finalStatus.Counts.LimitReachedTargets -eq 1) 'final status should count one limit-reached target.'
Assert-True ([string]$finalStatus.SmokeReceipt.Result -eq 'passed') 'final status json should surface the smoke receipt result.'
Assert-True ([string]$finalStatus.SmokeReceipt.Source -eq 'script-smoke') 'final status json should surface the smoke receipt source.'
Assert-True ([string]$finalStatus.SmokeReceipt.ProofLevel -eq 'script-level') 'final status json should surface the smoke receipt proof level.'
Assert-True ([string]$finalStatus.SmokeReceipt.TargetId -eq 'target01') 'final status json should surface the smoke receipt target.'
Assert-True ([int]$finalStatus.SmokeReceipt.CycleCount -eq 2) 'final status json should surface the smoke receipt cycle count.'
Assert-True ([string]$finalStatus.ProofCloseout.State -eq 'pending-visible-proof') 'script smoke should stay in pending-visible-proof closeout state until visible acceptance is proven.'
Assert-True ([string]$finalStatus.ProofCloseout.Mode -eq 'operational') 'script smoke should be operational but not final.'
Assert-True ($finalStatusText -match 'smoke=passed') 'final status text should surface smoke=passed in the summary.'
Assert-True ($finalStatusText -match 'smokeProof=script-level') 'final status text should surface smoke proof level in the summary.'
Assert-True ($finalStatusText -match 'smokeSource=script-smoke') 'final status text should surface smoke source in the summary.'
Assert-True ($finalStatusText -match 'closeout=pending-visible-proof') 'final status text should mark the closeout as pending visible proof.'
Assert-True ($finalStatusText -match 'closeoutMode=operational') 'final status text should mark the closeout mode as operational.'
Assert-True ($finalStatusText -match 'SmokeSummary: smoke: passed / proof=script-level / source=script-smoke / target=target01 / cycle=2/2 / phase=limit-reached / stop=all-targets-limit-reached') 'final status text should surface the compact smoke summary.'
Assert-True ($finalStatusText -match 'CloseoutSummary: closeout: pending-visible-proof / mode=operational / reason=proof-passed-script-level / proof=script-level / source=script-smoke') 'final status text should surface the closeout summary.'
Assert-True ([string]$finalTarget.Phase -eq 'limit-reached') 'final target phase should be limit-reached.'
Assert-True ([string]$finalTarget.NextAction -eq 'limit-reached') 'final target next action should be limit-reached.'
Assert-True ([int]$finalTarget.CycleCount -eq 2) 'final target cycle count should remain 2.'
Assert-True (@($queuedFilesFinal).Count -eq 0) 'no queued commands should remain after smoke closeout.'

Write-Host 'target autoloop one target live smoke ok'
