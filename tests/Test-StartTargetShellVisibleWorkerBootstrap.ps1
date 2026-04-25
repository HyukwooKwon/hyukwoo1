[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
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

function Wait-ForWorkerStatus {
    param(
        [Parameter(Mandatory)][string]$StatusPath,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
            $raw = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                return ($raw | ConvertFrom-Json)
            }
        }

        Start-Sleep -Milliseconds 250
    }

    throw "worker status timeout: $StatusPath"
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-start-target-shell-visible-worker-bootstrap'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$workerQueueRoot = Join-Path $testRoot 'queue'
$workerStatusRoot = Join-Path $testRoot 'status'
$workerLogRoot = Join-Path $testRoot 'logs'
$configPath = Join-Path $testRoot 'settings.bootstrap-worker.psd1'
$configText = @"
@{
    PairTest = @{
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($workerQueueRoot.Replace("'", "''"))'
            StatusRoot = '$($workerStatusRoot.Replace("'", "''"))'
            LogRoot = '$($workerLogRoot.Replace("'", "''"))'
            PollIntervalMs = 250
            IdleExitSeconds = 30
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$powershellPath = Resolve-PowerShellExecutable
$shellProcess = $null
$workerPid = 0
$statusPath = Join-Path $workerStatusRoot 'workers\worker_target01.json'

try {
    $shellProcess = Start-Process -FilePath $powershellPath -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'launcher\Start-TargetShell.ps1'),
        '-TargetId', 'target01',
        '-WindowTitle', 'VisibleWorkerBootstrapTest-target01',
        '-RootPath', $root,
        '-ManagedMarker', 'bootstrap-test-marker',
        '-ConfigPath', $configPath
    ) -PassThru

    $workerStatus = Wait-ForWorkerStatus -StatusPath $statusPath -TimeoutSeconds 15
    $workerPid = if ($null -ne $workerStatus.WorkerPid) { [int]$workerStatus.WorkerPid } else { 0 }

    Assert-True ([bool](Test-Path -LiteralPath $statusPath -PathType Leaf)) 'start-target-shell should create a visible worker status file when visible worker bootstrap is enabled.'
    Assert-True ($workerPid -gt 0) 'visible worker bootstrap should record a live worker pid.'
    Assert-True ([string]$workerStatus.TargetId -eq 'target01') 'visible worker bootstrap should preserve the target id in worker status.'
    $workerProcess = Get-Process -Id $workerPid -ErrorAction Stop
    Assert-True ($null -ne $workerProcess) 'visible worker bootstrap should leave a worker process running.'
    Assert-True ([string]$workerStatus.State -in @('idle', 'running', 'waiting-for-dispatch-slot', 'paused', 'stopped')) 'visible worker bootstrap should emit a recognized worker state.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$workerStatus.UpdatedAt)) 'visible worker bootstrap should record an UpdatedAt timestamp.'
}
finally {
    if ($workerPid -gt 0) {
        try {
            Stop-Process -Id $workerPid -Force -ErrorAction Stop
        }
        catch {
        }
    }
    if ($null -ne $shellProcess -and -not $shellProcess.HasExited) {
        try {
            Stop-Process -Id $shellProcess.Id -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

Write-Host ('start-target-shell visible worker bootstrap ok: root=' + $testRoot)
