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
$testRoot = Join-Path $root '_tmp\test-cleanup-visible-worker-stopped-run'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runtimeRoot = Join-Path $testRoot 'runtime'
$queueRoot = Join-Path $runtimeRoot 'visible-worker\queue\target05'
$processingRoot = Join-Path $queueRoot 'processing'
$statusRoot = Join-Path $runtimeRoot 'visible-worker\status'
$logRoot = Join-Path $runtimeRoot 'visible-worker\logs'
New-Item -ItemType Directory -Path $processingRoot,$statusRoot,$logRoot -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    Targets = @(
        @{
            Id = 'target05'
            Folder = '$($testRoot.Replace("'", "''"))\inbox\target05'
            EnterCount = `$null
            WindowTitle = 'CleanupStoppedRun05'
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

$runRoot = Join-Path $testRoot 'pair-test\run_stopped'
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
Write-JsonFile -Path (Join-Path $runRoot '.state\watcher-status.json') -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    RunRoot = $runRoot
    State = 'stopped'
    Reason = 'control-stop-request'
    UpdatedAt = (Get-Date).ToString('o')
    HeartbeatAt = (Get-Date).ToString('o')
    ForwardedCount = 1
    ConfiguredMaxForwardCount = 0
})

$processingPath = Join-Path $processingRoot 'command_target05_handoff_same_run.json'
Write-JsonFile -Path $processingPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = 'same-run-live'
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $runRoot
    TargetId = 'target05'
    PromptFilePath = (Join-Path $runRoot 'handoff.txt')
})

$workerStatusPath = Join-Path (Join-Path $statusRoot 'workers') 'worker_target05.json'
$sleepProcess = $null
try {
    $sleepProcess = Start-Process -FilePath 'pwsh.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -PassThru

    Write-JsonFile -Path $workerStatusPath -Payload ([ordered]@{
        SchemaVersion = '1.0.0'
        TargetId = 'target05'
        WorkerPid = $sleepProcess.Id
        State = 'running'
        CurrentCommandId = 'same-run-live'
        CurrentRunRoot = $runRoot
        CurrentPromptFilePath = (Join-Path $runRoot 'handoff.txt')
        Reason = 'heartbeat'
        StdOutLogPath = ''
        StdErrLogPath = ''
        LastCommandId = ''
        LastCompletedAt = ''
        LastFailedAt = ''
        UpdatedAt = (Get-Date).ToString('o')
    })

    $applyRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Cleanup-VisibleWorkerQueue.ps1') `
        -ConfigPath $configPath `
        -TargetId target05 `
        -StaleAgeSeconds 60 `
        -Apply `
        -AsJson
    if ($LASTEXITCODE -ne 0) {
        throw ('cleanup apply failed: ' + (($applyRaw | Out-String).Trim()))
    }

    $applyResult = $applyRaw | ConvertFrom-Json
    Assert-True ([int]$applyResult.Summary.StoppedWorkerProcessCount -eq 1) 'cleanup should stop active worker for a stopped run.'
    Assert-True ([int]$applyResult.Summary.ReleasedRunningStateCount -eq 1) 'cleanup should release running state for a stopped run.'
    Assert-True (-not (Get-Process -Id $sleepProcess.Id -ErrorAction SilentlyContinue)) 'cleanup should terminate the active worker process for a stopped run.'
    Assert-True (-not (Test-Path -LiteralPath $processingPath -PathType Leaf)) 'cleanup should archive same-run processing command when watcher is already stopped.'

    $updatedStatus = Get-Content -LiteralPath $workerStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$updatedStatus.State -eq 'stopped') 'cleanup should mark worker status stopped for a stopped run.'
    Assert-True ([string]$updatedStatus.CurrentCommandId -eq '') 'cleanup should clear current command id for a stopped run.'
}
finally {
    if ($null -ne $sleepProcess) {
        $alive = Get-Process -Id $sleepProcess.Id -ErrorAction SilentlyContinue
        if ($null -ne $alive) {
            Stop-Process -Id $sleepProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host 'cleanup-visible-worker-stopped-run ok'
