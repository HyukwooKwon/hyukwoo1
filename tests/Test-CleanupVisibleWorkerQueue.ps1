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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth 10), (New-Utf8NoBomEncoding))
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-cleanup-visible-worker-queue'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runtimeRoot = Join-Path $testRoot 'runtime'
$queueRoot = Join-Path $runtimeRoot 'visible-worker\queue\target01'
$queuedRoot = Join-Path $queueRoot 'queued'
$processingRoot = Join-Path $queueRoot 'processing'
$statusRoot = Join-Path $runtimeRoot 'visible-worker\status'
$logRoot = Join-Path $runtimeRoot 'visible-worker\logs'
New-Item -ItemType Directory -Path $queuedRoot,$processingRoot,$statusRoot,$logRoot -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'
            EnterCount = 1
            WindowTitle = 'CleanupTestWindow01'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($(Join-Path $runtimeRoot 'visible-worker\queue').Replace("'", "''"))'
            StatusRoot = '$($statusRoot.Replace("'", "''"))'
            LogRoot = '$($logRoot.Replace("'", "''"))'
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$sameRunRoot = Join-Path $testRoot 'pair-test\run_same'
$foreignRunRoot = Join-Path $testRoot 'pair-test\run_foreign'
New-Item -ItemType Directory -Path $sameRunRoot,$foreignRunRoot -Force | Out-Null

$sameRunCommandPath = Join-Path $queuedRoot 'command_target01_seed_same.json'
Write-JsonFile -Path $sameRunCommandPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = 'same-seed'
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $sameRunRoot
    TargetId = 'target01'
    PromptFilePath = (Join-Path $sameRunRoot 'headless-prompt.txt')
})

$foreignCommandPath = Join-Path $queuedRoot 'command_target01_seed_foreign.json'
Write-JsonFile -Path $foreignCommandPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = 'foreign-seed'
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $foreignRunRoot
    TargetId = 'target01'
    PromptFilePath = (Join-Path $foreignRunRoot 'headless-prompt.txt')
})

$invalidCommandPath = Join-Path $queuedRoot 'command_target01_invalid.json'
[System.IO.File]::WriteAllText($invalidCommandPath, '{invalid-json', (New-Utf8NoBomEncoding))

$missingFieldCommandPath = Join-Path $queuedRoot 'command_target01_missing_prompt.json'
Write-JsonFile -Path $missingFieldCommandPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = 'missing-prompt'
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $sameRunRoot
    TargetId = 'target01'
})

$staleProcessingPath = Join-Path $processingRoot 'command_target01_processing.json'
Write-JsonFile -Path $staleProcessingPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = 'processing-stale'
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $sameRunRoot
    TargetId = 'target01'
    PromptFilePath = (Join-Path $sameRunRoot 'handoff.txt')
})
(Get-Item -LiteralPath $staleProcessingPath).LastWriteTime = (Get-Date).AddMinutes(-10)

$workerStatusPath = Join-Path (Join-Path $statusRoot 'workers') 'worker_target01.json'
Write-JsonFile -Path $workerStatusPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    TargetId = 'target01'
    WorkerPid = 999999
    State = 'running'
    CurrentCommandId = 'processing-stale'
    CurrentRunRoot = $sameRunRoot
    CurrentPromptFilePath = (Join-Path $sameRunRoot 'handoff.txt')
    Reason = ''
    StdOutLogPath = ''
    StdErrLogPath = ''
    LastCommandId = ''
    LastCompletedAt = ''
    LastFailedAt = ''
    UpdatedAt = (Get-Date).ToString('o')
})

$dryRunRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Cleanup-VisibleWorkerQueue.ps1') `
    -ConfigPath $configPath `
    -TargetId target01 `
    -KeepRunRoot $sameRunRoot `
    -StaleAgeSeconds 60 `
    -AsJson
if ($LASTEXITCODE -ne 0) {
    throw ('cleanup dry-run failed: ' + (($dryRunRaw | Out-String).Trim()))
}

$dryRun = $dryRunRaw | ConvertFrom-Json
Assert-True ([int]$dryRun.Summary.ForeignCount -eq 1) 'cleanup dry-run should classify one foreign command.'
Assert-True ([int]$dryRun.Summary.InvalidCount -eq 2) 'cleanup dry-run should classify invalid JSON and missing-field commands.'
Assert-True ([int]$dryRun.Summary.StaleCount -eq 1) 'cleanup dry-run should classify one stale processing command.'
Assert-True ([bool]$dryRun.Summary.DryRun) 'cleanup dry-run summary should mark DryRun=true.'
Assert-True ([int]$dryRun.Summary.ForeignArchivedCount -eq 1) 'cleanup dry-run should report one foreign archive candidate.'
Assert-True ([int]$dryRun.Summary.InvalidMetadataArchivedCount -eq 2) 'cleanup dry-run should report invalid JSON and missing-field archive candidates.'
Assert-True ([int]$dryRun.Summary.StaleProcessingReclaimedCount -eq 1) 'cleanup dry-run should report one stale processing reclaim candidate.'
Assert-True ([int]$dryRun.Summary.KeptSameRunCount -eq 1) 'cleanup dry-run should report one same-run preserved command.'
Assert-True ([int]$dryRun.Summary.ReleasedRunningStateCount -eq 0) 'cleanup dry-run should not release worker state.'
Assert-True (Test-Path -LiteralPath $foreignCommandPath -PathType Leaf) 'dry-run should not move foreign command.'
Assert-True (Test-Path -LiteralPath $invalidCommandPath -PathType Leaf) 'dry-run should not move invalid command.'
Assert-True (Test-Path -LiteralPath $missingFieldCommandPath -PathType Leaf) 'dry-run should not move missing-field command.'
Assert-True (Test-Path -LiteralPath $staleProcessingPath -PathType Leaf) 'dry-run should not move stale processing command.'

$applyRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Cleanup-VisibleWorkerQueue.ps1') `
    -ConfigPath $configPath `
    -TargetId target01 `
    -KeepRunRoot $sameRunRoot `
    -StaleAgeSeconds 60 `
    -Apply `
    -AsJson
if ($LASTEXITCODE -ne 0) {
    throw ('cleanup apply failed: ' + (($applyRaw | Out-String).Trim()))
}

$applyResult = $applyRaw | ConvertFrom-Json
Assert-True ([int]$applyResult.Summary.ForeignCount -eq 1) 'cleanup apply should archive one foreign command.'
Assert-True ([int]$applyResult.Summary.InvalidCount -eq 2) 'cleanup apply should archive invalid JSON and missing-field commands.'
Assert-True ([int]$applyResult.Summary.StaleCount -eq 1) 'cleanup apply should archive one stale processing command.'
Assert-True (-not [bool]$applyResult.Summary.DryRun) 'cleanup apply summary should mark DryRun=false.'
Assert-True ([int]$applyResult.Summary.ForeignArchivedCount -eq 1) 'cleanup apply should report one foreign archived command.'
Assert-True ([int]$applyResult.Summary.InvalidMetadataArchivedCount -eq 2) 'cleanup apply should report invalid JSON and missing-field archived commands.'
Assert-True ([int]$applyResult.Summary.StaleProcessingReclaimedCount -eq 1) 'cleanup apply should report one stale reclaimed command.'
Assert-True ([int]$applyResult.Summary.KeptSameRunCount -eq 1) 'cleanup apply should report one same-run kept command.'
Assert-True ([int]$applyResult.Summary.ReleasedRunningStateCount -eq 1) 'cleanup apply should report one released running state.'
Assert-True ([bool]$applyResult.Targets[0].Cleanup.ReleasedRunningState) 'cleanup apply target result should report released worker state.'
Assert-True (Test-Path -LiteralPath $sameRunCommandPath -PathType Leaf) 'cleanup should preserve same-run queued command.'
Assert-True (-not (Test-Path -LiteralPath $foreignCommandPath -PathType Leaf)) 'cleanup should move foreign command to archive.'
Assert-True (-not (Test-Path -LiteralPath $invalidCommandPath -PathType Leaf)) 'cleanup should move invalid command to archive.'
Assert-True (-not (Test-Path -LiteralPath $missingFieldCommandPath -PathType Leaf)) 'cleanup should move missing-field command to archive.'
Assert-True (-not (Test-Path -LiteralPath $staleProcessingPath -PathType Leaf)) 'cleanup should move stale processing command to archive.'

$archiveRoot = Join-Path $queueRoot 'archive'
Assert-True (Test-Path -LiteralPath (Join-Path $archiveRoot 'archive-foreign\command_target01_seed_foreign.json') -PathType Leaf) 'foreign command should be archived under archive-foreign.'
Assert-True (Test-Path -LiteralPath (Join-Path $archiveRoot 'archive-invalid\command_target01_invalid.json') -PathType Leaf) 'invalid command should be archived under archive-invalid.'
Assert-True (Test-Path -LiteralPath (Join-Path $archiveRoot 'archive-invalid\command_target01_missing_prompt.json') -PathType Leaf) 'missing-field command should be archived under archive-invalid.'
Assert-True (Test-Path -LiteralPath (Join-Path $archiveRoot 'archive-stale\command_target01_processing.json') -PathType Leaf) 'stale command should be archived under archive-stale.'

$updatedStatus = Get-Content -LiteralPath $workerStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$updatedStatus.State -eq 'stopped') 'cleanup should clear dead worker active state.'
Assert-True ([string]$updatedStatus.CurrentCommandId -eq '') 'cleanup should clear current command id after stale cleanup.'

Write-Host 'cleanup-visible-worker-queue ok'
