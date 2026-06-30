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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopInputTrigger'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-inbox-submit.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_inbox_submit'
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
        RunMode = 'target-inbox-submit'
        DispatchQueuedCommandsInline = `$false
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$inputPath = Join-Path $target01.InboxPendingRoot 'task_001.txt'
Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'input trigger body'

$watchJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watch = $watchJson | ConvertFrom-Json
Assert-True ([int]$watch.QueuedCount -eq 1) 'input trigger should queue exactly one command.'

$queueFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($queueFiles).Count -eq 1) 'one queued target-autoloop command should be present.'
$command = Get-Content -LiteralPath $queueFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$command.RunMode -eq 'target-inbox-submit') 'queued command should preserve target-inbox-submit run mode.'
Assert-True ([string]$command.TargetId -eq 'target01') 'queued command should target target01.'
Assert-True ([string]$command.TriggerKind -eq 'input-file') 'queued command should record input-file trigger kind.'
Assert-True ([string]$command.LoopSource -eq 'external-inbox') 'queued command should record external-inbox loop source.'
Assert-True ($null -eq $command.PSObject.Properties['PartnerTargetId']) 'queued command should not carry PartnerTargetId.'
$promptText = Get-Content -LiteralPath ([string]$command.PromptSnapshotPath) -Raw -Encoding UTF8
Assert-True ($promptText.Contains([string]$target01.SourceSummaryPath)) 'watcher should append the manifest summary path to the dispatched prompt.'
Assert-True ($promptText.Contains([string]$target01.SourceReviewZipPath)) 'watcher should append the manifest review.zip path to the dispatched prompt.'
Assert-True ($promptText.Contains([string]$target01.PublishReadyPath)) 'watcher should append the manifest publish-ready path to the dispatched prompt.'
Assert-True (($promptText | Select-String -Pattern ([regex]::Escape([string]$target01.SourceSummaryPath)) -AllMatches).Matches.Count -eq 1) 'watcher should append the summary path exactly once.'
Assert-True ($promptText.Contains('input trigger body')) 'watcher should keep the operator input body.'
Assert-True ($promptText.Contains('[고정문구 / 항상 포함]')) 'input trigger prompt should keep the fixed suffix header.'
Assert-True ($promptText.Contains('suffix-01')) 'watcher should append the target fixed suffix.'

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetState = $state.Targets.target01
Assert-True ([string]$targetState.Phase -eq 'queued') 'target state should move to queued after input trigger.'
Assert-True ([string]$targetState.LastTriggerKind -eq 'input-file') 'target state should record input-file trigger kind.'
Assert-True ([string]$targetState.NextAction -eq 'dispatch-command') 'target state should wait for dispatch integration.'
Assert-True ((Test-Path -LiteralPath $targetState.LastReceiptPath -PathType Leaf)) 'receipt should be created for the queued input trigger.'

$processedFiles = @(Get-ChildItem -LiteralPath $target01.InboxProcessedRoot -File -ErrorAction SilentlyContinue)
Assert-True (@($processedFiles).Count -eq 1) 'input trigger should move into processed after queueing.'

Write-Host 'target autoloop input trigger ok'
