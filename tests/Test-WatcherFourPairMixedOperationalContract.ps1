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

function Set-ManifestPairPolicyLimit {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$PairId,
        [int]$RoundtripLimit
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $manifest.PairTest.PairPolicies) {
        $manifest.PairTest | Add-Member -MemberType NoteProperty -Name PairPolicies -Value ([pscustomobject]@{})
    }
    if ($null -eq $manifest.PairTest.PairPolicies.PSObject.Properties[$PairId]) {
        $manifest.PairTest.PairPolicies | Add-Member -MemberType NoteProperty -Name $PairId -Value ([pscustomobject]@{})
    }
    $manifest.PairTest.PairPolicies.$PairId | Add-Member -MemberType NoteProperty -Name DefaultPairMaxRoundtripCount -Value $RoundtripLimit -Force

    foreach ($pairRow in @($manifest.Pairs)) {
        if ([string]$pairRow.PairId -ne $PairId) {
            continue
        }
        if ($null -eq $pairRow.Policy) {
            $pairRow | Add-Member -MemberType NoteProperty -Name Policy -Value ([pscustomobject]@{})
        }
        $pairRow.Policy | Add-Member -MemberType NoteProperty -Name DefaultPairMaxRoundtripCount -Value $RoundtripLimit -Force
    }

    foreach ($targetRow in @($manifest.Targets)) {
        if ([string]$targetRow.PairId -ne $PairId) {
            continue
        }
        if ($null -eq $targetRow.PairPolicy) {
            $targetRow | Add-Member -MemberType NoteProperty -Name PairPolicy -Value ([pscustomobject]@{})
        }
        $targetRow.PairPolicy | Add-Member -MemberType NoteProperty -Name DefaultPairMaxRoundtripCount -Value $RoundtripLimit -Force
    }

    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_four_pair_mixed_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01,pair02,pair03,pair04 | Out-Null

$manifestPath = Join-Path $contractRunRoot 'manifest.json'
Set-ManifestPairPolicyLimit -ManifestPath $manifestPath -PairId 'pair02' -RoundtripLimit 1

$stateRoot = Join-Path $contractRunRoot '.state'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}

$now = Get-Date
[ordered]@{
    'target02|mixed-limit-01' = $now.ToString('o')
    'target06|mixed-limit-02' = $now.AddSeconds(1).ToString('o')
    'target04|mixed-forward-01' = $now.AddSeconds(2).ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stateRoot 'forwarded.json') -Encoding UTF8

[ordered]@{
    SchemaVersion = '1.0.0'
    RunRoot = $contractRunRoot
    UpdatedAt = $now.AddSeconds(3).ToString('o')
    Targets = @(
        [ordered]@{
            TargetId = 'target03'
            FinalState = 'manual_attention_required'
            ManualAttentionRequired = $true
            RetryReason = 'operator-review-needed'
            AttemptCount = 2
            MaxAttempts = 2
            UpdatedAt = $now.AddSeconds(3).ToString('o')
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'seed-send-status.json') -Encoding UTF8

$powershellPath = Resolve-PowerShellExecutable
$stdoutLog = Join-Path $root ('_tmp\watcher-four-pair-mixed-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
$stderrLog = ($stdoutLog + '.stderr')
$watchArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-PollIntervalMs', '250',
    '-MaxForwardCount', '0',
    '-PairMaxRoundtripCount', '0',
    '-RunDurationSec', '30'
)

$process = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

try {
    $runningStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            if ([string]$status.Watcher.Status -ne 'running') {
                return $false
            }
            $pair01 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
            $pair02 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)
            $pair03 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair03' } | Select-Object -First 1)
            $pair04 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair04' } | Select-Object -First 1)
            return (
                @($pair01).Count -eq 1 -and
                @($pair02).Count -eq 1 -and
                @($pair03).Count -eq 1 -and
                @($pair04).Count -eq 1 -and
                [string]$pair01[0].CurrentPhase -eq 'seed-running' -and
                [string]$pair02[0].CurrentPhase -eq 'limit-reached' -and
                [string]$pair03[0].CurrentPhase -eq 'manual-attention' -and
                [string]$pair04[0].CurrentPhase -eq 'partner-running'
            )
        }

    $pairMap = @{}
    foreach ($pairRow in @($runningStatus.Pairs)) {
        $pairMap[[string]$pairRow.PairId] = $pairRow
    }

    Assert-True ([bool]$runningStatus.PairState.Exists) 'mixed watcher flow should persist pair-state metadata.'
    Assert-True ([int]$pairMap['pair02'].ConfiguredMaxRoundtripCount -eq 1) 'pair02 should surface the manifest policy roundtrip limit.'
    Assert-True ([string]$pairMap['pair03'].NextAction -eq 'manual-review') 'pair03 should require manual review before pause.'
    Assert-True ([string]$pairMap['pair04'].NextExpectedHandoff -eq 'target08 -> target04') 'pair04 should surface partner-running handoff expectation.'

    $pauseRequestId = Write-ControlRequest -RunRoot $contractRunRoot -Action 'pause' -RequestedBy 'tests\\Test-WatcherFourPairMixedOperationalContract.ps1:pause'
    $pausedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            if ([string]$status.Watcher.Status -ne 'paused' -or [string]$status.Watcher.LastHandledRequestId -ne $pauseRequestId) {
                return $false
            }
            $pair01 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
            $pair02 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)
            $pair03 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair03' } | Select-Object -First 1)
            $pair04 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair04' } | Select-Object -First 1)
            return (
                @($pair01).Count -eq 1 -and
                @($pair02).Count -eq 1 -and
                @($pair03).Count -eq 1 -and
                @($pair04).Count -eq 1 -and
                [string]$pair01[0].CurrentPhase -eq 'paused' -and
                [string]$pair02[0].CurrentPhase -eq 'limit-reached' -and
                [string]$pair03[0].CurrentPhase -eq 'paused' -and
                [string]$pair04[0].CurrentPhase -eq 'paused'
            )
        }
    Assert-True ([string]$pausedStatus.Watcher.LastHandledAction -eq 'pause') 'pause request should be acknowledged as pause.'
    Assert-True ([string]$pausedStatus.Watcher.LastHandledResult -eq 'paused') 'pause request should finish with paused result.'

    $resumeRequestId = Write-ControlRequest -RunRoot $contractRunRoot -Action 'resume' -RequestedBy 'tests\\Test-WatcherFourPairMixedOperationalContract.ps1:resume'
    $resumedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            if ([string]$status.Watcher.Status -ne 'running' -or [string]$status.Watcher.LastHandledRequestId -ne $resumeRequestId) {
                return $false
            }
            $pair02 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)
            $pair03 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair03' } | Select-Object -First 1)
            $pair04 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair04' } | Select-Object -First 1)
            return (
                @($pair02).Count -eq 1 -and
                @($pair03).Count -eq 1 -and
                @($pair04).Count -eq 1 -and
                [string]$pair02[0].CurrentPhase -eq 'limit-reached' -and
                [string]$pair03[0].CurrentPhase -eq 'manual-attention' -and
                [string]$pair04[0].CurrentPhase -eq 'partner-running'
            )
        }
    Assert-True ([string]$resumedStatus.Watcher.LastHandledAction -eq 'resume') 'resume request should be acknowledged as resume.'
    Assert-True ([string]$resumedStatus.Watcher.LastHandledResult -eq 'resumed') 'resume request should finish with resumed result.'

    $stopRequestId = Write-ControlRequest -RunRoot $contractRunRoot -Action 'stop' -RequestedBy 'tests\\Test-WatcherFourPairMixedOperationalContract.ps1:stop'
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

    $stoppedPair03 = @($stoppedStatus.Pairs | Where-Object { [string]$_.PairId -eq 'pair03' } | Select-Object -First 1)[0]
    $stoppedPair04 = @($stoppedStatus.Pairs | Where-Object { [string]$_.PairId -eq 'pair04' } | Select-Object -First 1)[0]
    Assert-True ([bool]$stoppedStatus.PairState.Exists) 'pair-state metadata should remain after mixed flow stop.'
    Assert-True ([string]$stoppedPair03.CurrentPhase -eq 'manual-attention') 'manual attention pair should restore after resume/stop flow.'
    Assert-True ([string]$stoppedPair04.CurrentPhase -eq 'partner-running') 'partner-running pair should restore after resume/stop flow.'
}
finally {
    if ($null -ne $process) {
        [void]$process.WaitForExit(12000)
    }
}

Write-Host ('watcher four pair mixed operational contract ok: runRoot=' + $contractRunRoot)
