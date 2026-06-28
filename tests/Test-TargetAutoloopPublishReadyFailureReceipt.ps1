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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopPublishReadyFailureReceipt'
$expectedInboxRoot = Join-Path $tmpRoot 'router-inbox'
$expectedTarget01Inbox = Join-Path $expectedInboxRoot 'target01'
$mismatchTarget01Inbox = Join-Path $tmpRoot 'different-router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop-failure.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_failure'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
foreach ($path in @($expectedTarget01Inbox, $mismatchTarget01Inbox)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    InboxRoot = '$($expectedInboxRoot.Replace("'", "''"))'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($mismatchTarget01Inbox.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
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
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'summary ready for failure receipt'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'zip payload'
if (Test-Path -LiteralPath $target01.SourceReviewZipPath) {
    Remove-Item -LiteralPath $target01.SourceReviewZipPath -Force
}
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 1 `
    -ParentCycleId 0 `
    -OutputFingerprint output-fingerprint-failure-001 | Out-Null

$watchJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watch = $watchJson | ConvertFrom-Json
Assert-True ([int]$watch.QueuedCount -eq 0) 'publish-ready relay mismatch should not queue commands.'
Assert-True ([int]$watch.FailedCount -eq 1) 'publish-ready relay mismatch should count as one failure.'

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetState = $state.Targets.target01
Assert-True ([string]$targetState.Phase -eq 'failed') 'target state should move to failed after publish-ready relay mismatch.'
Assert-True ([string]$targetState.LastDispatchState -eq 'relay-folder-preflight-failed') 'target state should record relay-folder preflight failure.'
Assert-True ([string]$targetState.RelayTargetFolderState -eq 'relay-folder-mismatch') 'target state should preserve relay-folder mismatch state.'
Assert-True ([string]$targetState.LastTriggerKind -eq 'publish-ready') 'target state should preserve publish-ready trigger kind after failure.'
Assert-True ((Test-Path -LiteralPath $targetState.LastReceiptPath -PathType Leaf)) 'publish-ready relay mismatch should still create a receipt.'

$receipt = Get-Content -LiteralPath $targetState.LastReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$receipt.EventKind -eq 'publish-ready-failed') 'failure receipt should use publish-ready-failed event kind.'
Assert-True ([string]$receipt.TriggerKind -eq 'publish-ready') 'failure receipt should preserve publish-ready trigger kind.'
Assert-True ([string]$receipt.FailureState -eq 'relay-folder-preflight-failed') 'failure receipt should preserve failure state.'
Assert-True ([string]$receipt.RelayTargetFolderState -eq 'relay-folder-mismatch') 'failure receipt should preserve relay-folder mismatch state.'
Assert-True ([string]$receipt.OutputFingerprint -eq 'output-fingerprint-failure-001') 'failure receipt should preserve the publish marker output fingerprint.'
Assert-True ([string]$receipt.FailureReason -match 'target relay folder mismatch:') 'failure receipt should preserve the relay-folder mismatch reason.'
Assert-True ([string]$receipt.PublishReadyPath -eq [string]$target01.PublishReadyPath) 'failure receipt should preserve publish-ready path.'

Write-Host 'target autoloop publish-ready failure receipt ok'
