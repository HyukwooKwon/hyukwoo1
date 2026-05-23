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

function Read-JsonObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "json file is empty: $Path"
    }

    return ($raw | ConvertFrom-Json)
}

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }
        if ($command.Source) {
            return [string]$command.Source
        }
        if ($command.Path) {
            return [string]$command.Path
        }
        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

function Get-StateSummary {
    param(
        [string]$WorkerStatusPath,
        [string]$QueuedRoot,
        [string]$ProcessingRoot,
        [string]$FailedRoot,
        [string]$StdOutLogPath,
        [string]$StdErrLogPath
    )

    $statusState = '(missing)'
    $statusReason = '(missing)'
    $currentCommandId = '(missing)'
    if (Test-Path -LiteralPath $WorkerStatusPath -PathType Leaf) {
        try {
            $statusDoc = Read-JsonObject -Path $WorkerStatusPath
            $statusState = [string]$statusDoc.State
            $statusReason = [string]$statusDoc.Reason
            $currentCommandId = [string]$statusDoc.CurrentCommandId
        }
        catch {
            $statusState = '(unreadable)'
            $statusReason = $_.Exception.Message
        }
    }

    $queuedCount = @(
        Get-ChildItem -LiteralPath $QueuedRoot -Filter '*.json' -File -ErrorAction SilentlyContinue
    ).Count
    $processingCount = @(
        Get-ChildItem -LiteralPath $ProcessingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue
    ).Count
    $failedCount = @(
        Get-ChildItem -LiteralPath $FailedRoot -Filter '*.json' -File -ErrorAction SilentlyContinue
    ).Count

    return "workerState={0} reason={1} currentCommandId={2} queued={3} processing={4} failed={5} stdout={6} stderr={7}" -f `
        $statusState, `
        $statusReason, `
        $currentCommandId, `
        $queuedCount, `
        $processingCount, `
        $failedCount, `
        $StdOutLogPath, `
        $StdErrLogPath
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-visible-worker-pause-blocks-claim'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

$queueRoot = Join-Path $testRoot 'queue'
$statusRoot = Join-Path $testRoot 'status'
$logRoot = Join-Path $testRoot 'logs'
$runRoot = Join-Path $testRoot 'run'
$stateRoot = Join-Path $runRoot '.state'
$queuedRoot = Join-Path $queueRoot 'target05\queued'
$processingRoot = Join-Path $queueRoot 'target05\processing'
$completedRoot = Join-Path $queueRoot 'target05\completed'
$failedRoot = Join-Path $queueRoot 'target05\failed'
foreach ($path in @($queuedRoot, $processingRoot, $completedRoot, $failedRoot, (Join-Path $statusRoot 'workers'), $logRoot, $stateRoot)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

$configPath = Join-Path $testRoot 'settings.psd1'
$configContent = @"
@{
    PairTest = @{
        ExecutionPathMode = 'visible-worker'
        Targets = @(
            @{ Id = 'target01' },
            @{ Id = 'target05' }
        )
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($queueRoot -replace '\\','\\')'
            StatusRoot = '$($statusRoot -replace '\\','\\')'
            LogRoot = '$($logRoot -replace '\\','\\')'
            PollIntervalMs = 100
            IdleExitSeconds = 1
            CommandTimeoutSeconds = 60
        }
        HeadlessExec = @{
            MaxRunSeconds = 60
        }
    }
}
"@
Set-Content -LiteralPath $configPath -Encoding UTF8 -Value $configContent

$watcherStatusPath = Join-Path $stateRoot 'watcher-status.json'
[pscustomobject]@{
    State = 'paused'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $watcherStatusPath -Encoding UTF8

$commandId = [guid]::NewGuid().ToString('N')
$queuedCommandPath = Join-Path $queuedRoot 'command_target05_handoff_01.json'
[ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = $commandId
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $runRoot
    PairId = 'pair01'
    TargetId = 'target05'
    PartnerTargetId = 'target01'
    RoleName = 'bottom'
    Mode = 'handoff'
    PromptFilePath = (Join-Path $testRoot 'missing-prompt.txt')
    MessagePath = (Join-Path $testRoot 'missing-prompt.txt')
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $queuedCommandPath -Encoding UTF8

$workerScriptPath = Join-Path $root 'visible\Start-VisibleTargetWorker.ps1'
$powershellPath = Resolve-PowerShellExecutable
$stdoutLogPath = Join-Path $logRoot 'visible-worker.stdout.log'
$stderrLogPath = Join-Path $logRoot 'visible-worker.stderr.log'
$worker = $null

try {
    $worker = Start-Process -FilePath $powershellPath -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $workerScriptPath,
        '-ConfigPath', $configPath,
        '-TargetId', 'target05',
        '-IdleExitSeconds', '1'
    ) -PassThru -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath

    $workerStatusPath = Join-Path $statusRoot 'workers\worker_target05.json'
    $pauseDeadline = (Get-Date).AddSeconds(10)
    $pausedObserved = $false
    while ((Get-Date) -lt $pauseDeadline) {
        if (Test-Path -LiteralPath $workerStatusPath -PathType Leaf) {
            $statusDoc = Read-JsonObject -Path $workerStatusPath
            if ([string]$statusDoc.State -eq 'paused') {
                $pausedObserved = $true
                break
            }
        }
        Start-Sleep -Milliseconds 100
    }

    $pauseSummary = Get-StateSummary `
        -WorkerStatusPath $workerStatusPath `
        -QueuedRoot $queuedRoot `
        -ProcessingRoot $processingRoot `
        -FailedRoot $failedRoot `
        -StdOutLogPath $stdoutLogPath `
        -StdErrLogPath $stderrLogPath
    Assert-True $pausedObserved ("visible worker should surface paused state before claiming the queued command. {0}" -f $pauseSummary)

    Start-Sleep -Milliseconds 400

    $pausedStatus = Read-JsonObject -Path $workerStatusPath
    $queuedFilesWhilePaused = @(Get-ChildItem -LiteralPath $queuedRoot -Filter '*.json' -File)
    $processingFilesWhilePaused = @(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File)
    Assert-True ([string]$pausedStatus.State -eq 'paused') 'worker status should remain paused while watcher is paused.'
    Assert-True ([string]$pausedStatus.CurrentCommandId -eq $commandId) 'paused worker status should point at the queued command without claiming it.'
    Assert-True ([string]$pausedStatus.CurrentRunRoot -eq $runRoot) 'paused worker status should surface the queued command run root.'
    Assert-True ([string]$pausedStatus.Reason -eq 'watcher-paused') 'paused worker status should explain that watcher pause blocked the claim.'
    Assert-True ($queuedFilesWhilePaused.Count -eq 1) 'queued command should remain queued while watcher pause is active.'
    Assert-True ($processingFilesWhilePaused.Count -eq 0) 'processing folder should stay empty while watcher pause is active.'

    [pscustomobject]@{
        State = 'running'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $watcherStatusPath -Encoding UTF8

    $exitDeadline = (Get-Date).AddSeconds(15)
    while (-not $worker.HasExited -and (Get-Date) -lt $exitDeadline) {
        Start-Sleep -Milliseconds 200
    }

    if (-not $worker.HasExited) {
        $exitSummary = Get-StateSummary `
            -WorkerStatusPath $workerStatusPath `
            -QueuedRoot $queuedRoot `
            -ProcessingRoot $processingRoot `
            -FailedRoot $failedRoot `
            -StdOutLogPath $stdoutLogPath `
            -StdErrLogPath $stderrLogPath
        throw ("visible worker should resume, drain the queued command, and exit after idle timeout once watcher pause is lifted. {0}" -f $exitSummary)
    }

    $queuedFiles = @(Get-ChildItem -LiteralPath $queuedRoot -Filter '*.json' -File)
    $processingFiles = @(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File)
    $failedFiles = @(Get-ChildItem -LiteralPath $failedRoot -Filter '*.json' -File)
    $finalStatus = Read-JsonObject -Path $workerStatusPath

    Assert-True ($queuedFiles.Count -eq 0) 'queued command should be drained after watcher pause is lifted.'
    Assert-True ($processingFiles.Count -eq 0) 'processing folder should be empty after worker finishes.'
    Assert-True ($failedFiles.Count -eq 1) 'missing prompt command should fail after pause is lifted, proving the worker resumed and claimed it.'
    Assert-True ([string]$finalStatus.State -eq 'stopped') 'worker should stop after resume and idle exit.'
    Assert-True ([string]$finalStatus.LastCommandId -eq $commandId) 'worker should record the resumed command as the last processed command.'
}
finally {
    if ($null -ne $worker -and -not $worker.HasExited) {
        Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'visible worker pause blocks claim ok'
