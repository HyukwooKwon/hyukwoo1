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

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-start-target-shell-skips-visible-worker-bootstrap-typed-window'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$workerQueueRoot = Join-Path $testRoot 'queue'
$workerStatusRoot = Join-Path $testRoot 'status'
$workerLogRoot = Join-Path $testRoot 'logs'
$configPath = Join-Path $testRoot 'settings.typed-window.psd1'
$configText = @"
@{
    PairTest = @{
        ExecutionPathMode = 'typed-window'
        RequireUserVisibleCellExecution = `$true
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($workerQueueRoot.Replace("'", "''"))'
            StatusRoot = '$($workerStatusRoot.Replace("'", "''"))'
            LogRoot = '$($workerLogRoot.Replace("'", "''"))'
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$powershellPath = Resolve-PowerShellExecutable
$shellProcess = $null
$statusPath = Join-Path $workerStatusRoot 'workers\worker_target01.json'

try {
    $shellProcess = Start-Process -FilePath $powershellPath -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'launcher\Start-TargetShell.ps1'),
        '-TargetId', 'target01',
        '-WindowTitle', 'TypedWindowNoWorkerBootstrap-target01',
        '-RootPath', $root,
        '-ManagedMarker', 'typed-window-no-worker-bootstrap',
        '-ConfigPath', $configPath
    ) -PassThru

    Start-Sleep -Seconds 2

    Assert-True (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) 'typed-window shell launch should not bootstrap a visible worker status file.'
}
finally {
    if ($null -ne $shellProcess -and -not $shellProcess.HasExited) {
        try {
            Stop-Process -Id $shellProcess.Id -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

Write-Host 'start-target-shell typed-window bootstrap skip ok'
