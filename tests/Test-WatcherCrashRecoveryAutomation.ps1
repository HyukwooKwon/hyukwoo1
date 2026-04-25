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
        [int]$TimeoutSec = 25,
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

    throw ('watcher status timeout: ' + (($lastStatus | ConvertTo-Json -Depth 10) | Out-String))
}

function Write-ControlRequest {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$Action,
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
        Action        = $Action
        RunRoot       = $RunRoot
        RequestId     = $requestId
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $controlPath -Encoding UTF8
    return $requestId
}

function Invoke-PythonWatcherRecovery {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$PairedStatus
    )

    $tmpRoot = Join-Path $Root '_tmp\watcher-recovery-automation'
    if (-not (Test-Path -LiteralPath $tmpRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    }
    $statusJsonPath = Join-Path $tmpRoot ('status_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.json')
    $PairedStatus | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $statusJsonPath -Encoding UTF8

    $pythonScript = @'
import json
import sys
from relay_panel_watchers import WatcherService

status_path, run_root = sys.argv[1], sys.argv[2]
with open(status_path, encoding="utf-8-sig") as handle:
    paired_status = json.load(handle)

service = WatcherService()
eligibility = service.get_start_eligibility(paired_status, run_root)
result = service.recover_stale_start_blockers(run_root, paired_status)

print(json.dumps({
    "cleanup_allowed": bool(eligibility.cleanup_allowed),
    "eligibility_allowed": bool(eligibility.allowed),
    "recommended_action": eligibility.recommended_action,
    "reason_codes": list(eligibility.reason_codes),
    "recover_ok": bool(result.ok),
    "recover_message": result.message,
    "recover_reason_codes": list(result.reason_codes),
}, ensure_ascii=False))
'@

    Push-Location $Root
    try {
        $raw = $pythonScript | python - $statusJsonPath $RunRoot
    }
    finally {
        Pop-Location
    }

    if ($LASTEXITCODE -ne 0) {
        throw ('python watcher recovery bridge failed: ' + (($raw | Out-String).Trim()))
    }
    return ($raw | ConvertFrom-Json)
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_crash_recovery_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$powershellPath = Resolve-PowerShellExecutable
$watchArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-PollIntervalMs', '250',
    '-RunDurationSec', '30'
)

$stdoutLog1 = Join-Path $root ('_tmp\watcher-crash-recovery-1-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
$stderrLog1 = ($stdoutLog1 + '.stderr')
$stdoutLog2 = Join-Path $root ('_tmp\watcher-crash-recovery-2-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
$stderrLog2 = ($stdoutLog2 + '.stderr')
$watchProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

try {
    $process1 = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog1 -RedirectStandardError $stderrLog1
    $watchProcesses.Add($process1) | Out-Null

    $runningStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'running') -and
            ([string]$status.Watcher.ControlPendingAction -eq '')
        }
    Assert-True ($runningStatus.Watcher.Status -eq 'running') 'watcher should reach running state before crash simulation.'

    Stop-Process -Id $process1.Id -Force
    [void]$process1.WaitForExit(12000)

    $crashedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'stopped') -and
            ([bool]$status.Watcher.StatusExists)
        }
    Assert-True ($crashedStatus.Watcher.Status -eq 'stopped') 'crashed watcher should surface stopped effective status once the mutex is released.'

    $stateRoot = Join-Path $contractRunRoot '.state'
    $controlPath = Join-Path $stateRoot 'watcher-control.json'
    [ordered]@{
        SchemaVersion = '1.0.0'
        RequestedAt   = (Get-Date).AddMinutes(-10).ToString('o')
        RequestedBy   = 'tests\\Test-WatcherCrashRecoveryAutomation.ps1:stale-control'
        Action        = 'stop'
        RunRoot       = $contractRunRoot
        RequestId     = [guid]::NewGuid().ToString()
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $controlPath -Encoding UTF8

    $staleControlStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'stopped') -and
            ([string]$status.Watcher.ControlPendingAction -eq 'stop') -and
            ($null -ne $status.Watcher.ControlAgeSeconds) -and
            ([double]$status.Watcher.ControlAgeSeconds -ge 60)
        }
    Assert-True ([string]$staleControlStatus.Watcher.ControlPendingAction -eq 'stop') 'stale recovery test should surface a pending stop control file.'

    $recoveryResult = Invoke-PythonWatcherRecovery -Root $root -RunRoot $contractRunRoot -PairedStatus $staleControlStatus
    Assert-True ([bool]$recoveryResult.cleanup_allowed) 'stale control after crash should be marked recoverable.'
    Assert-True ([bool]$recoveryResult.recover_ok) 'stale recovery bridge should clear the stale control file.'
    Assert-True (-not (Test-Path -LiteralPath $controlPath -PathType Leaf)) 'stale recovery should remove watcher-control.json.'

    $postRecoveryStatus = Invoke-ShowPairedStatus -Root $root -ResolvedConfigPath $resolvedConfigPath -RunRoot $contractRunRoot
    Assert-True ([string]$postRecoveryStatus.Watcher.ControlPendingAction -eq '') 'post-recovery status should clear the pending action.'

    $process2 = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog2 -RedirectStandardError $stderrLog2
    $watchProcesses.Add($process2) | Out-Null

    $restartedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'running') -and
            ([string]$status.Watcher.ControlPendingAction -eq '')
        }
    Assert-True ($restartedStatus.Watcher.Status -eq 'running') 'watcher should restart cleanly after stale recovery.'

    $stopRequestId = Write-ControlRequest -RunRoot $contractRunRoot -Action 'stop' -RequestedBy 'tests\\Test-WatcherCrashRecoveryAutomation.ps1:stop'
    $stoppedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'stopped') -and
            ([string]$status.Watcher.ControlPendingAction -eq '') -and
            ([string]$status.Watcher.LastHandledRequestId -eq $stopRequestId) -and
            ([string]$status.Watcher.LastHandledAction -eq 'stop') -and
            ([string]$status.Watcher.LastHandledResult -eq 'stopped')
        }
    Assert-True ([string]$stoppedStatus.Watcher.Status -eq 'stopped') 'watcher should stop cleanly after crash recovery restart.'
}
finally {
    foreach ($process in $watchProcesses) {
        if ($null -ne $process) {
            [void]$process.WaitForExit(12000)
        }
    }
}

Write-Host ('watcher crash recovery automation ok: runRoot=' + $contractRunRoot)
