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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopPauseQueuesInputSnapshots'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-pause-queues-input.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_pause_queues_input'
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

$startJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-inbox-submit `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$pauseRequest = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action pause `
    -RequestedBy 'tests\Test-TargetAutoloopPauseQueuesInputSnapshots.ps1:pause' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$pauseRequest.Ok) 'pause request should succeed before paused input queueing.'

$null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson

$pausedStatus = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
Assert-True ([string]$pausedStatus.ControllerState -eq 'paused') 'controller should be paused before input files arrive.'

$inputPath1 = Join-Path $target01.InboxPendingRoot 'task_paused_input_001.txt'
$inputPath2 = Join-Path $target01.InboxPendingRoot 'task_paused_input_002.txt'
Set-Content -LiteralPath $inputPath1 -Encoding UTF8 -Value 'first paused input should keep its own prompt snapshot'
Start-Sleep -Milliseconds 50
Set-Content -LiteralPath $inputPath2 -Encoding UTF8 -Value 'second paused input should not overwrite the first command prompt'

$watchFirstJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchFirst = $watchFirstJson | ConvertFrom-Json
Assert-True ([int]$watchFirst.QueuedCount -eq 1) 'first paused sweep should queue one input command.'

$watchSecondJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson
$watchSecond = $watchSecondJson | ConvertFrom-Json
Assert-True ([int]$watchSecond.QueuedCount -eq 1) 'second paused sweep should queue the next input command.'

$queuedFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object LastWriteTimeUtc, Name)
Assert-True (@($queuedFiles).Count -eq 2) 'two input commands should remain queued while paused.'

$command1 = Get-Content -LiteralPath $queuedFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$command2 = Get-Content -LiteralPath $queuedFiles[1].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$command1.PromptSourcePath -eq [string]$target01.LastPromptPath) 'first command should preserve source prompt path separately.'
Assert-True ([string]$command2.PromptSourcePath -eq [string]$target01.LastPromptPath) 'second command should preserve source prompt path separately.'
Assert-True ([string]$command1.PromptFilePath -ne [string]$target01.LastPromptPath) 'first command should use a prompt snapshot path.'
Assert-True ([string]$command2.PromptFilePath -ne [string]$target01.LastPromptPath) 'second command should use a prompt snapshot path.'
Assert-True ([string]$command1.PromptFilePath -ne [string]$command2.PromptFilePath) 'each queued command should have a distinct prompt snapshot.'
Assert-True (Test-Path -LiteralPath ([string]$command1.PromptFilePath) -PathType Leaf) 'first prompt snapshot should exist.'
Assert-True (Test-Path -LiteralPath ([string]$command2.PromptFilePath) -PathType Leaf) 'second prompt snapshot should exist.'

$prompt1 = Get-Content -LiteralPath ([string]$command1.PromptFilePath) -Raw -Encoding UTF8
$prompt2 = Get-Content -LiteralPath ([string]$command2.PromptFilePath) -Raw -Encoding UTF8
$latestPrompt = Get-Content -LiteralPath ([string]$target01.LastPromptPath) -Raw -Encoding UTF8
Assert-True ($prompt1 -match 'first paused input') 'first snapshot should keep the first input prompt text.'
Assert-True ($prompt2 -match 'second paused input') 'second snapshot should keep the second input prompt text.'
Assert-True ($latestPrompt -match 'second paused input') 'mutable last prompt should reflect only the latest queued input.'
Assert-True (-not ($latestPrompt -match 'first paused input')) 'mutable last prompt overwrite should not affect the first snapshot.'

$blockedWorkerJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -ProcessOnce `
    -AsJson
$blockedWorker = $blockedWorkerJson | ConvertFrom-Json
Assert-True ([int]$blockedWorker.ProcessedCount -eq 0) 'paused controller should block queued input dispatch.'
Assert-True ([string]$blockedWorker.LastResult.State -eq 'blocked-by-controller') 'paused input queue should report blocked-by-controller.'

$resumeRequest = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Request-TargetAutoloopControl.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Action resume `
    -RequestedBy 'tests\Test-TargetAutoloopPauseQueuesInputSnapshots.ps1:resume' `
    -AsJson | ConvertFrom-Json
Assert-True ([bool]$resumeRequest.Ok) 'resume request should succeed after paused input queueing.'

$null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -ProcessOnce `
    -AsJson

$workerOneJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -ProcessOnce `
    -AsJson
$workerOne = $workerOneJson | ConvertFrom-Json
Assert-True ([int]$workerOne.ProcessedCount -eq 1) 'resumed worker should dispatch the first queued input command.'

$workerTwoJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -ProcessOnce `
    -AsJson
$workerTwo = $workerTwoJson | ConvertFrom-Json
Assert-True ([int]$workerTwo.ProcessedCount -eq 1) 'resumed worker should dispatch the second queued input command.'

$queuedFilesAfterResume = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' | Sort-Object Name)
$completedFiles = @(Get-ChildItem -LiteralPath $target01.QueueCompletedRoot -File -Filter '*.json' | Sort-Object Name)
$readyFiles = @(Get-ChildItem -LiteralPath $routerInboxRoot -File -Filter '*.ready.txt' | Sort-Object Name)
Assert-True (@($queuedFilesAfterResume).Count -eq 0) 'all paused input commands should drain after resume.'
Assert-True (@($completedFiles).Count -eq 2) 'completed archive should contain both resumed input commands.'
Assert-True (@($readyFiles).Count -eq 2) 'router ready files should be created for both resumed input commands.'

Write-Host 'target autoloop pause queues input snapshots ok'
