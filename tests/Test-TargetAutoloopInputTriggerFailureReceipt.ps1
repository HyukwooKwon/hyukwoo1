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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopInputTriggerFailureReceipt'
$expectedInboxRoot = Join-Path $tmpRoot 'router-inbox'
$expectedTarget01Inbox = Join-Path $expectedInboxRoot 'target01'
$mismatchTarget01Inbox = Join-Path $tmpRoot 'different-router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-inbox-submit-failure.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_inbox_submit_failure'
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
        RunMode = 'target-inbox-submit'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$inputPath = Join-Path $target01.InboxPendingRoot 'task_001.txt'
Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'input trigger failure body'

$watchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watch = $watchJson | ConvertFrom-Json
Assert-True ([int]$watch.QueuedCount -eq 0) 'input trigger relay mismatch should not queue commands.'
Assert-True ([int]$watch.FailedCount -eq 1) 'input trigger relay mismatch should count as one failure.'

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetState = $state.Targets.target01
Assert-True ([string]$targetState.Phase -eq 'failed') 'target state should move to failed after input trigger relay mismatch.'
Assert-True ([string]$targetState.LastDispatchState -eq 'relay-folder-preflight-failed') 'target state should record relay-folder preflight failure.'
Assert-True ([string]$targetState.RelayTargetFolderState -eq 'relay-folder-mismatch') 'target state should preserve relay-folder mismatch state.'
Assert-True ([string]$targetState.LastTriggerKind -eq 'input-file') 'target state should preserve input-file trigger kind after failure.'
Assert-True ((Test-Path -LiteralPath $targetState.LastReceiptPath -PathType Leaf)) 'input trigger relay mismatch should still create a receipt.'

$receipt = Get-Content -LiteralPath $targetState.LastReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$receipt.EventKind -eq 'input-file-failed') 'failure receipt should use input-file-failed event kind.'
Assert-True ([string]$receipt.TriggerKind -eq 'input-file') 'failure receipt should preserve the input-file trigger kind.'
Assert-True ([string]$receipt.FailureState -eq 'relay-folder-preflight-failed') 'failure receipt should preserve failure state.'
Assert-True ([string]$receipt.RelayTargetFolderState -eq 'relay-folder-mismatch') 'failure receipt should preserve relay-folder mismatch state.'
Assert-True ([string]$receipt.FailureReason -match 'target relay folder mismatch:') 'failure receipt should preserve the relay-folder mismatch reason.'
Assert-True (([string]$receipt.InputPath).Length -gt 0) 'failure receipt should preserve the failed input path.'
Assert-True ((Test-Path -LiteralPath ([string]$receipt.InputPath) -PathType Leaf)) 'failure receipt input path should exist on disk.'

$failedInputs = @(Get-ChildItem -LiteralPath $target01.InboxFailedRoot -File -ErrorAction SilentlyContinue)
Assert-True (@($failedInputs).Count -eq 1) 'input trigger relay mismatch should archive the claimed input into inbox failed.'

Write-Host 'target autoloop input trigger failure receipt ok'
