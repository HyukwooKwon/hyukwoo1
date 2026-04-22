[CmdletBinding()]
param(
    [string]$ConfigPath
)

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

function Invoke-ShowPairedStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot
    )

    $powershellPath = Resolve-PowerShellExecutable
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'tests\Show-PairedExchangeStatus.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $RunRoot,
        '-AsJson'
    )
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-paired-exchange-status failed: " + (($result | Out-String).Trim()))
    }
    return ($result | ConvertFrom-Json)
}

function Wait-ForWatcherStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][scriptblock]$Predicate,
        [int]$TimeoutSec = 20,
        [int]$PollMs = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastStatus = $null
    while ((Get-Date) -lt $deadline) {
        $lastStatus = Invoke-ShowPairedStatus -Root $Root -ResolvedConfigPath $ResolvedConfigPath -RunRoot $RunRoot
        if (& $Predicate $lastStatus) {
            return $lastStatus
        }
        Start-Sleep -Milliseconds $PollMs
    }
    throw ('watcher status timeout: ' + (($lastStatus | ConvertTo-Json -Depth 6) | Out-String))
}

function Write-StopRequest {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RequestedBy
    )

    $stateRoot = Join-Path $RunRoot '.state'
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }
    $requestId = [guid]::NewGuid().ToString()
    $controlPath = Join-Path $stateRoot 'watcher-control.json'
    [ordered]@{
        SchemaVersion = '1.0.0'
        RequestedAt   = (Get-Date).ToString('o')
        RequestedBy   = $RequestedBy
        Action        = 'stop'
        RunRoot       = $RunRoot
        RequestId     = $requestId
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $controlPath -Encoding UTF8
    return [pscustomobject]@{
        RequestId   = $requestId
        ControlPath = $controlPath
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_e2e_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$powershellPath = Resolve-PowerShellExecutable
$watchProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

try {
    $stdoutLog1 = Join-Path $root ('_tmp\watcher-e2e-1-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
    $stderrLog1 = ($stdoutLog1 + '.stderr')
    $stdoutLog2 = Join-Path $root ('_tmp\watcher-e2e-2-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
    $stderrLog2 = ($stdoutLog2 + '.stderr')
    $watchArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
        '-ConfigPath', $resolvedConfigPath,
        '-RunRoot', $contractRunRoot,
        '-PollIntervalMs', '250',
        '-RunDurationSec', '20'
    )

    $process1 = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog1 -RedirectStandardError $stderrLog1
    $watchProcesses.Add($process1) | Out-Null

    $running1 = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'running') -and
            -not [string]::IsNullOrWhiteSpace([string]$status.Watcher.HeartbeatAt) -and
            ([int]$status.Watcher.StatusSequence -gt 0)
        }
    Assert-True ($running1.Watcher.Status -eq 'running') 'Expected first watcher start to reach running state.'

    $stop1 = Write-StopRequest -RunRoot $contractRunRoot -RequestedBy 'tests\\Test-WatcherRoundtripE2ESmoke.ps1:first-stop'
    $stopped1 = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'stopped') -and
            ([string]$status.Watcher.ControlPendingAction -eq '') -and
            ([string]$status.Watcher.LastHandledRequestId -eq $stop1.RequestId) -and
            ([string]$status.Watcher.LastHandledResult -eq 'stopped')
        }
    Assert-True ($stopped1.Watcher.Status -eq 'stopped') 'Expected first stop request to stop watcher.'

    $process2 = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog2 -RedirectStandardError $stderrLog2
    $watchProcesses.Add($process2) | Out-Null

    $running2 = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'running') -and
            -not [string]::IsNullOrWhiteSpace([string]$status.Watcher.ProcessStartedAt) -and
            ([int]$status.Watcher.StatusSequence -gt 0)
        }
    Assert-True ($running2.Watcher.Status -eq 'running') 'Expected second watcher start to reach running state.'

    $stop2 = Write-StopRequest -RunRoot $contractRunRoot -RequestedBy 'tests\\Test-WatcherRoundtripE2ESmoke.ps1:second-stop'
    $stopped2 = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'stopped') -and
            ([string]$status.Watcher.ControlPendingAction -eq '') -and
            ([string]$status.Watcher.LastHandledRequestId -eq $stop2.RequestId) -and
            ([string]$status.Watcher.LastHandledResult -eq 'stopped')
        }
    Assert-True ($stopped2.Watcher.Status -eq 'stopped') 'Expected second stop request to stop watcher.'
}
finally {
    foreach ($process in $watchProcesses) {
        if ($null -ne $process) {
            [void]$process.WaitForExit(12000)
        }
    }
}

Write-Host ('watcher roundtrip e2e smoke ok: runRoot=' + $contractRunRoot)
