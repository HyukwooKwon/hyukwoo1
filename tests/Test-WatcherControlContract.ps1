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

function Assert-IsoTimestampOrEmpty {
    param(
        [string]$Value,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T') {
        throw $Message
    }

    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($Value, [ref]$parsed)) {
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

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Root 'show-paired-exchange-status.ps1'),
        '-ConfigPath', $ResolvedConfigPath,
        '-RunRoot', $RunRoot,
        '-AsJson'
    )
    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("show-paired-exchange-status failed: " + (($result | Out-String).Trim()))
    }
    return (ConvertFrom-RelayJsonText -Json (($result | Out-String).Trim()))
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

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'router\RelayMessageMetadata.ps1')
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_control_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$powershellPath = Resolve-PowerShellExecutable
$stdoutLog = Join-Path $root ('_tmp\watcher-contract-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
$stderrLog = ($stdoutLog + '.stderr')
$watchArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-PollIntervalMs', '250',
    '-RunDurationSec', '8'
)

$process = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

try {
    $runningStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate { param($status) $status.Watcher.Status -eq 'running' }

    Assert-True ($runningStatus.Watcher.Status -eq 'running') 'Expected watcher to reach running state.'
    Assert-IsoTimestampOrEmpty -Value ([string]$runningStatus.Manifest.CreatedAt) -Message 'Manifest.CreatedAt must remain an ISO timestamp string in the paired status bridge.'
    Assert-IsoTimestampOrEmpty -Value ([string]$runningStatus.Watcher.StatusFileUpdatedAt) -Message 'Watcher.StatusFileUpdatedAt must remain an ISO timestamp string in the paired status bridge.'
    Assert-IsoTimestampOrEmpty -Value ([string]$runningStatus.Watcher.HeartbeatAt) -Message 'Watcher.HeartbeatAt must remain an ISO timestamp string in the paired status bridge.'
    Assert-IsoTimestampOrEmpty -Value ([string]$runningStatus.Watcher.ProcessStartedAt) -Message 'Watcher.ProcessStartedAt must remain an ISO timestamp string in the paired status bridge.'
    Assert-IsoTimestampOrEmpty -Value ([string]$runningStatus.Watcher.StatusLastWriteAt) -Message 'Watcher.StatusLastWriteAt must remain an ISO timestamp string in the paired status bridge.'
    Assert-IsoTimestampOrEmpty -Value ([string]$runningStatus.Watcher.ControlLastWriteAt) -Message 'Watcher.ControlLastWriteAt must remain an ISO timestamp string in the paired status bridge.'
    Assert-IsoTimestampOrEmpty -Value ([string]$runningStatus.Watcher.ControlRequestedAt) -Message 'Watcher.ControlRequestedAt must remain an ISO timestamp string in the paired status bridge when present.'

    $stateRoot = Join-Path $contractRunRoot '.state'
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }
    $requestId = [guid]::NewGuid().ToString()
    $controlPath = Join-Path $stateRoot 'watcher-control.json'
    [ordered]@{
        SchemaVersion = '1.0.0'
        RequestedAt   = (Get-Date).ToString('o')
        RequestedBy   = 'tests\Test-WatcherControlContract.ps1'
        Action        = 'stop'
        RunRoot       = $contractRunRoot
        RequestId     = $requestId
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $controlPath -Encoding UTF8

    $stoppedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'stopped') -and
            ([string]$status.Watcher.ControlPendingAction -eq '') -and
            ([string]$status.Watcher.LastHandledRequestId -eq $requestId) -and
            ([string]$status.Watcher.LastHandledAction -eq 'stop') -and
            ([string]$status.Watcher.LastHandledResult -eq 'stopped')
        }

    Assert-True ($stoppedStatus.Watcher.Status -eq 'stopped') 'Expected watcher to stop after control request.'
    Assert-True ($stoppedStatus.Watcher.ControlPendingAction -eq '') 'Expected control file to be cleared after stop.'
    Assert-True ($stoppedStatus.Watcher.LastHandledRequestId -eq $requestId) 'Expected last handled request id to match stop request.'
    Assert-True ($stoppedStatus.Watcher.LastHandledResult -eq 'stopped') 'Expected last handled result to be stopped.'
    Assert-True (-not (Test-Path -LiteralPath $controlPath)) 'Expected control file to be removed after stop.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$stoppedStatus.Watcher.LastHandledAt)) 'Expected last handled timestamp to be recorded after stop.'
    Assert-IsoTimestampOrEmpty -Value ([string]$stoppedStatus.Watcher.LastHandledAt) -Message 'Watcher.LastHandledAt must remain an ISO timestamp string in the paired status bridge.'
    Assert-IsoTimestampOrEmpty -Value ([string]$stoppedStatus.Watcher.StatusFileUpdatedAt) -Message 'Watcher.StatusFileUpdatedAt must remain an ISO timestamp string after stop.'
    Assert-IsoTimestampOrEmpty -Value ([string]$stoppedStatus.Watcher.HeartbeatAt) -Message 'Watcher.HeartbeatAt must remain an ISO timestamp string after stop.'
}
finally {
    [void]$process.WaitForExit(12000)
}

Write-Host ('watcher-control contract ok: runRoot=' + $contractRunRoot)
