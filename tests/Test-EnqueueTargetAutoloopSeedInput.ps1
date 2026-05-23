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
$tmpRoot = Join-Path $root '_tmp\Test-EnqueueTargetAutoloopSeedInput'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop-seed-queue.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_seed_queue'
$referenceInputRoot = 'C:\dev\python\relay-target-autoloop-seed-queue-input'
$referenceInputPath = Join-Path $referenceInputRoot 'seed-input.md'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
New-Item -ItemType Directory -Path $routerInboxRoot -Force | Out-Null
New-Item -ItemType Directory -Path $referenceInputRoot -Force | Out-Null
'seed queue input' | Set-Content -LiteralPath $referenceInputPath -Encoding UTF8

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($routerInboxRoot.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 2 }
        )
    }
}
"@, (New-Object System.Text.UTF8Encoding($false)))

$startJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$queueJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Enqueue-TargetAutoloopSeedInput.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -Text "queue prompt text`nsummary path: $([string]$target01.SourceSummaryPath)" `
    -ReferenceInputPath $referenceInputPath `
    -AsJson | ConvertFrom-Json

Assert-True ((Test-Path -LiteralPath $queueJson.InputTriggerPath -PathType Leaf)) 'enqueue script should create an input trigger file.'
Assert-True ([string]$queueJson.TargetId -eq 'target01') 'enqueue script should preserve target id.'
Assert-True (([string]$queueJson.Fingerprint).Length -gt 0) 'enqueue script should return a trigger fingerprint.'
Assert-True ([string]$queueJson.SeedRuntimeSummary -eq 'runtime: pendingInput=1 / claimed=0 / queued=0 / processing=0') 'enqueue script should return the updated runtime summary after writing the trigger.'

$trigger = Get-Content -LiteralPath $queueJson.InputTriggerPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$trigger.EventKind -eq 'target-autoloop-seed-input') 'input trigger payload should use target-autoloop-seed-input event kind.'
Assert-True ([string]$trigger.QueueSource -eq 'target-autoloop-seed-composer') 'input trigger payload should record the seed composer queue source.'
Assert-True ([string]$trigger.SourceLabel -eq 'target-autoloop-seed-composer') 'input trigger payload should record the seed composer source label.'
Assert-True ([string]$trigger.ReferenceInputPath -eq $referenceInputPath) 'input trigger payload should preserve the reference input path.'
Assert-True ([string]$trigger.TaskText -match [regex]::Escape([string]$target01.SourceSummaryPath)) 'input trigger payload should preserve the queue prompt text.'

$pendingFiles = @(Get-ChildItem -LiteralPath $target01.InboxPendingRoot -File -Filter '*.json' | Sort-Object Name)
Assert-True (@($pendingFiles).Count -eq 1) 'enqueue script should leave exactly one pending input trigger file.'

Write-Host 'enqueue target autoloop seed input ok'
