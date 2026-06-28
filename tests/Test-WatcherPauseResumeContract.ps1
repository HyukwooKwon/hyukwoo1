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

    throw 'pwsh (PowerShell 7+)를 찾지 못했습니다.'
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
    return [pscustomobject]@{
        RequestId = $requestId
        ControlPath = $controlPath
    }
}

function Ensure-MinimalSeedReviewZip {
    param([Parameter(Mandatory)][string]$ZipPath)

    if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
        return
    }

    $parent = Split-Path -Parent $ZipPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fileStream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $archive.CreateEntry('seed-review.txt')
            $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
            try {
                $writer.WriteLine('watcher pause/resume contract fixture')
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedBaseConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$generatedConfigPayload = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Write-PairExternalizedRelayConfigs.ps1') `
    -BaseConfigPath $resolvedBaseConfigPath `
    -PairId pair01 `
    -AsJson | ConvertFrom-Json
$resolvedConfigPath = [string]@($generatedConfigPayload.GeneratedConfigs | Select-Object -First 1)[0].OutputConfigPath
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairPolicy = $null
if ($null -ne $config.PairTest -and $null -ne $config.PairTest.PairPolicies) {
    $pairPolicy = $config.PairTest.PairPolicies['pair01']
}
$seedReviewInputPath = ''
if ($null -ne $pairPolicy -and -not [string]::IsNullOrWhiteSpace([string]$pairPolicy.DefaultSeedReviewInputPath)) {
    $seedReviewInputPath = [string]$pairPolicy.DefaultSeedReviewInputPath
}
elseif (-not [string]::IsNullOrWhiteSpace([string]$config.PairTest.DefaultSeedReviewInputPath)) {
    $seedReviewInputPath = [string]$config.PairTest.DefaultSeedReviewInputPath
}
else {
    $seedReviewInputPath = Join-Path ([string]@($generatedConfigPayload.GeneratedConfigs | Select-Object -First 1)[0].WorkRepoRoot) 'reviewfile\seed_review_input_latest.zip'
}
Ensure-MinimalSeedReviewZip -ZipPath $seedReviewInputPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_pause_resume_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$powershellPath = Resolve-PowerShellExecutable
$stdoutLog = Join-Path $root ('_tmp\watcher-pause-resume-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
$stderrLog = ($stdoutLog + '.stderr')
$watchArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-PollIntervalMs', '250',
    '-RunDurationSec', '20'
)

$process = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

try {
    $runningStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'running') -and
            ([string]$status.Watcher.ControlPendingAction -eq '')
        }
    Assert-True ($runningStatus.Watcher.Status -eq 'running') 'Expected watcher to reach running state before pause.'

    $pauseRequest = Write-ControlRequest -RunRoot $contractRunRoot -Action 'pause' -RequestedBy 'tests\\Test-WatcherPauseResumeContract.ps1:pause'
    $pausedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'paused') -and
            ([string]$status.Watcher.ControlPendingAction -eq '') -and
            ([string]$status.Watcher.LastHandledRequestId -eq $pauseRequest.RequestId) -and
            ([string]$status.Watcher.LastHandledAction -eq 'pause') -and
            ([string]$status.Watcher.LastHandledResult -eq 'paused')
        }
    Assert-True ($pausedStatus.Watcher.Status -eq 'paused') 'Expected watcher to enter paused state.'
    Assert-True ([string]$pausedStatus.Watcher.StatusReason -in @('paused', 'control-pause-request')) 'Expected paused watcher reason to reflect pause state.'
    Assert-True ([bool]$pausedStatus.PairState.Exists) 'Expected watcher pause flow to persist pair-state metadata.'
    $pausedPair = @($pausedStatus.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
    Assert-True (@($pausedPair).Count -eq 1) 'Expected pair01 summary row while paused.'
    Assert-True ([string]$pausedPair[0].CurrentPhase -eq 'paused') 'Expected paused watcher to surface paused pair phase.'

    $resumeRequest = Write-ControlRequest -RunRoot $contractRunRoot -Action 'resume' -RequestedBy 'tests\\Test-WatcherPauseResumeContract.ps1:resume'
    $resumedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'running') -and
            ([string]$status.Watcher.ControlPendingAction -eq '') -and
            ([string]$status.Watcher.LastHandledRequestId -eq $resumeRequest.RequestId) -and
            ([string]$status.Watcher.LastHandledAction -eq 'resume') -and
            ([string]$status.Watcher.LastHandledResult -eq 'resumed')
        }
    Assert-True ($resumedStatus.Watcher.Status -eq 'running') 'Expected watcher to resume running state.'
    Assert-True ([bool]$resumedStatus.PairState.Exists) 'Expected pair-state metadata to remain after resume.'

    $stopRequest = Write-ControlRequest -RunRoot $contractRunRoot -Action 'stop' -RequestedBy 'tests\\Test-WatcherPauseResumeContract.ps1:stop'
    $stoppedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'stopped') -and
            ([string]$status.Watcher.ControlPendingAction -eq '') -and
            ([string]$status.Watcher.LastHandledRequestId -eq $stopRequest.RequestId) -and
            ([string]$status.Watcher.LastHandledAction -eq 'stop') -and
            ([string]$status.Watcher.LastHandledResult -eq 'stopped')
        }
    Assert-True ($stoppedStatus.Watcher.Status -eq 'stopped') 'Expected watcher to stop after pause/resume flow.'
}
finally {
    if ($null -ne $process) {
        [void]$process.WaitForExit(12000)
    }
}

Write-Host ('watcher pause/resume contract ok: runRoot=' + $contractRunRoot)
