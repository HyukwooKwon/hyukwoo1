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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopPublishReadyDispatchDelay'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_delay'
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
        DefaultPublishReadyDispatchMinDelaySeconds = 2
        DefaultPublishReadyDispatchMaxDelaySeconds = 4
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
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'summary ready for delayed next cycle'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'zip payload'
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
    -OutputFingerprint output-fingerprint-delay-001 `
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
Assert-True ([int]$watchDelay.QueuedCount -eq 0) 'publish-ready delay should prevent queueing on first sweep.'

$delayQueueFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($delayQueueFiles).Count -eq 0) 'no queued command should exist before delay expires.'

$delayState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$delayTargetState = $delayState.Targets.target01
Assert-True ([string]$delayTargetState.Phase -eq 'dispatch-delay') 'target state should move to dispatch-delay before queueing.'
Assert-True ([string]$delayTargetState.NextAction -eq 'wait-dispatch-delay') 'target state should expose wait-dispatch-delay next action.'
Assert-True ([string]$delayTargetState.PendingTriggerKind -eq 'publish-ready') 'target state should preserve pending publish-ready trigger kind.'
Assert-True (([string]$delayTargetState.PendingTriggerFingerprint).Length -gt 0) 'target state should keep pending publish trigger fingerprint.'
Assert-True ([string]$delayTargetState.PendingOutputFingerprint -eq 'output-fingerprint-delay-001') 'target state should keep pending output fingerprint.'
Assert-True (([string]$delayTargetState.PendingDispatchEligibleAt).Length -gt 0) 'target state should record pending dispatch eligibility.'
Assert-True ([string]$delayTargetState.PublishReadyDispatchDelayMode -eq 'range') 'target state should expose range delay mode.'
Assert-True ([int]$delayTargetState.PublishReadyDispatchMinDelaySeconds -eq 2) 'target state should keep configured publish-ready min delay.'
Assert-True ([int]$delayTargetState.PublishReadyDispatchMaxDelaySeconds -eq 4) 'target state should keep configured publish-ready max delay.'
Assert-True ([int]$delayTargetState.PendingDispatchDelaySeconds -ge 2 -and [int]$delayTargetState.PendingDispatchDelaySeconds -le 4) 'target state should choose an actual pending delay inside the configured range.'
Assert-True ([string]$delayTargetState.LastDispatchState -eq 'dispatch-delay-waiting') 'target state should expose dispatch-delay-waiting dispatch state.'

Start-Sleep -Milliseconds (([int]$delayTargetState.PendingDispatchDelaySeconds * 1000) + 400)

$watchQueueJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchQueue = $watchQueueJson | ConvertFrom-Json
Assert-True ([int]$watchQueue.QueuedCount -eq 1) 'publish-ready delay should queue exactly one command after eligibility.'

$queueFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queueFiles).Count -eq 1) 'one queued command should exist after delay expiry.'
$command = Get-Content -LiteralPath $queueFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$command.TriggerKind -eq 'publish-ready') 'queued command should preserve publish-ready trigger kind after delay.'
Assert-True ([string]$command.PublishReadyDispatchDelayMode -eq 'range') 'queued command should preserve publish-ready range delay mode.'
Assert-True ([int]$command.PublishReadyDispatchMinDelaySeconds -eq 2) 'queued command should preserve publish-ready min delay.'
Assert-True ([int]$command.PublishReadyDispatchMaxDelaySeconds -eq 4) 'queued command should preserve publish-ready max delay.'
Assert-True ([int]$command.PublishReadyDispatchDelaySeconds -eq [int]$delayTargetState.PendingDispatchDelaySeconds) 'queued command should keep the actual chosen publish-ready dispatch delay.'

$queuedState = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$queuedTargetState = $queuedState.Targets.target01
Assert-True ([string]$queuedTargetState.Phase -eq 'queued') 'target state should move to queued after delayed dispatch.'
Assert-True ([string]$queuedTargetState.PendingTriggerKind -eq '') 'pending publish-ready state should be cleared after queueing.'
Assert-True ([string]$queuedTargetState.LastHandledOutputFingerprint -eq 'output-fingerprint-delay-001') 'target state should keep handled output fingerprint after delayed dispatch.'

Write-Host 'target autoloop publish-ready dispatch delay ok'
