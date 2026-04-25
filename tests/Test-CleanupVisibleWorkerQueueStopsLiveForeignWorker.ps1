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
$testRoot = Join-Path $root '_tmp\test-cleanup-visible-worker-live-foreign'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runtimeRoot = Join-Path $testRoot 'runtime'
$queueRoot = Join-Path $runtimeRoot 'visible-worker\queue\target01'
$processingRoot = Join-Path $queueRoot 'processing'
$statusRoot = Join-Path $runtimeRoot 'visible-worker\status'
$logRoot = Join-Path $runtimeRoot 'visible-worker\logs'
New-Item -ItemType Directory -Path $processingRoot,$statusRoot,$logRoot -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'
            EnterCount = `$null
            WindowTitle = 'CleanupLiveWorker01'
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

$keepRunRoot = Join-Path $testRoot 'pair-test\run_keep'
$foreignRunRoot = Join-Path $testRoot 'pair-test\run_foreign'
New-Item -ItemType Directory -Path $keepRunRoot,$foreignRunRoot -Force | Out-Null

$processingPath = Join-Path $processingRoot 'command_target01_foreign_processing.json'
Write-JsonFile -Path $processingPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = 'foreign-live'
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $foreignRunRoot
    TargetId = 'target01'
    PromptFilePath = (Join-Path $foreignRunRoot 'handoff.txt')
})

$workerStatusPath = Join-Path (Join-Path $statusRoot 'workers') 'worker_target01.json'
$sleepProcess = $null
try {
    $sleepProcess = Start-Process -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -PassThru

    Write-JsonFile -Path $workerStatusPath -Payload ([ordered]@{
        SchemaVersion = '1.0.0'
        TargetId = 'target01'
        WorkerPid = $sleepProcess.Id
        State = 'running'
        CurrentCommandId = 'foreign-live'
        CurrentRunRoot = $foreignRunRoot
        CurrentPromptFilePath = (Join-Path $foreignRunRoot 'handoff.txt')
        Reason = ''
        StdOutLogPath = ''
        StdErrLogPath = ''
        LastCommandId = ''
        LastCompletedAt = ''
        LastFailedAt = ''
        UpdatedAt = (Get-Date).ToString('o')
    })

    $applyRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Cleanup-VisibleWorkerQueue.ps1') `
        -ConfigPath $configPath `
        -TargetId target01 `
        -KeepRunRoot $keepRunRoot `
        -StaleAgeSeconds 60 `
        -Apply `
        -AsJson
    if ($LASTEXITCODE -ne 0) {
        throw ('cleanup apply failed: ' + (($applyRaw | Out-String).Trim()))
    }

    $applyResult = $applyRaw | ConvertFrom-Json
    Assert-True ([int]$applyResult.Summary.ForeignCount -eq 1) 'cleanup apply should classify one foreign processing command.'
    Assert-True ([int]$applyResult.Summary.StoppedWorkerProcessCount -eq 1) 'cleanup apply should stop one active foreign worker process.'
    Assert-True ([int]$applyResult.Summary.ReleasedRunningStateCount -eq 1) 'cleanup apply should release one running worker state.'
    Assert-True ([bool]$applyResult.Targets[0].Cleanup.StoppedWorkerProcess) 'cleanup target result should report stopped worker process.'
    Assert-True (-not (Get-Process -Id $sleepProcess.Id -ErrorAction SilentlyContinue)) 'cleanup should terminate the live foreign worker process.'
    Assert-True (-not (Test-Path -LiteralPath $processingPath -PathType Leaf)) 'cleanup should move foreign processing command to archive.'

    $updatedStatus = Get-Content -LiteralPath $workerStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$updatedStatus.State -eq 'stopped') 'cleanup should mark worker status stopped after killing foreign worker.'
    Assert-True ([string]$updatedStatus.CurrentCommandId -eq '') 'cleanup should clear current command id after killing foreign worker.'
}
finally {
    if ($null -ne $sleepProcess) {
        $alive = Get-Process -Id $sleepProcess.Id -ErrorAction SilentlyContinue
        if ($null -ne $alive) {
            Stop-Process -Id $sleepProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host 'cleanup-visible-worker-live-foreign ok'
