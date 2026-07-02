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

function Resolve-Pwsh {
    foreach ($name in @('pwsh.exe', 'pwsh')) {
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

    throw 'pwsh is required.'
}

function Test-ProcessAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }

    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-StopTargetAutoloopAutomation'
$fakeRunRoot = Join-Path $tmpRoot 'target-autoloop\run_20260702_000000_000'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $fakeRunRoot -Force | Out-Null

$pwsh = Resolve-Pwsh
$fakeWatcherCommand = "Start-Sleep -Seconds 120 # tests\Watch-TargetAutoloop.ps1 -RunRoot '$fakeRunRoot'"
$fakeWorkerCommand = "Start-Sleep -Seconds 120 # visible\Start-TargetAutoloopWorker.ps1 -RunRoot '$fakeRunRoot' -TargetId target01"
$fakeWatcherProcess = $null
$fakeWorkerProcess = $null
$fakeWatcherProcess = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', $fakeWatcherCommand) -WindowStyle Hidden -PassThru
$fakeWorkerProcess = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', $fakeWorkerCommand) -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Seconds 1
    Assert-True (Test-ProcessAlive -ProcessId $fakeWatcherProcess.Id) 'fake target-autoloop watcher process should start.'
    Assert-True (Test-ProcessAlive -ProcessId $fakeWorkerProcess.Id) 'fake target-autoloop worker process should start.'

    $result = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Stop-TargetAutoloopAutomation.ps1') `
        -RunRoot $fakeRunRoot `
        -GraceSeconds 0 `
        -ForceAfterGrace `
        -AsJson | ConvertFrom-Json

    Assert-True ([bool]$result.Ok) 'cleanup should stop all matching target-autoloop automation processes.'
    Assert-True ([int]$result.InitialProcessCount -ge 2) 'cleanup should detect the fake watcher and worker processes.'
    Assert-True ([int]$result.RemainingAfterCount -eq 0) 'cleanup should leave no matching process for the filtered runroot.'

    Start-Sleep -Milliseconds 500
    Assert-True (-not (Test-ProcessAlive -ProcessId $fakeWatcherProcess.Id)) 'fake watcher process should be terminated.'
    Assert-True (-not (Test-ProcessAlive -ProcessId $fakeWorkerProcess.Id)) 'fake worker process should be terminated.'
}
finally {
    if ($null -ne $fakeWatcherProcess -and (Test-ProcessAlive -ProcessId $fakeWatcherProcess.Id)) {
        Stop-Process -Id $fakeWatcherProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $fakeWorkerProcess -and (Test-ProcessAlive -ProcessId $fakeWorkerProcess.Id)) {
        Stop-Process -Id $fakeWorkerProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force
    }
}

Write-Host 'stop target autoloop automation ok'
