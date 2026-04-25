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
    throw ('watcher status timeout: ' + (($lastStatus | ConvertTo-Json -Depth 8) | Out-String))
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$contractRunRoot = Join-Path $pairRunRootBase ('run_contract_watcher_pair_limit_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $contractRunRoot `
    -IncludePairId pair01 | Out-Null

$stateRoot = Join-Path $contractRunRoot '.state'
if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}

$forwardedStatePath = Join-Path $stateRoot 'forwarded.json'
[ordered]@{
    'target01|seed-forward-01' = (Get-Date).ToString('o')
    'target05|seed-forward-02' = (Get-Date).AddSeconds(1).ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $forwardedStatePath -Encoding UTF8

$powershellPath = Resolve-PowerShellExecutable
$stdoutLog = Join-Path $root ('_tmp\watcher-pair-limit-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.stdout.log')
$stderrLog = ($stdoutLog + '.stderr')
$watchArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\Watch-PairedExchange.ps1'),
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $contractRunRoot,
    '-PollIntervalMs', '250',
    '-MaxForwardCount', '0',
    '-PairMaxRoundtripCount', '1',
    '-RunDurationSec', '20'
)

$process = Start-Process -FilePath $powershellPath -ArgumentList $watchArguments -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

try {
    $stoppedStatus = Wait-ForWatcherStatus `
        -Root $root `
        -ResolvedConfigPath $resolvedConfigPath `
        -RunRoot $contractRunRoot `
        -Predicate {
            param($status)
            ($status.Watcher.Status -eq 'stopped') -and
            ([string]$status.Watcher.StatusReason -eq 'pair-roundtrip-limit-reached') -and
            ([string]$status.Watcher.StopCategory -eq 'expected-limit') -and
            ([int]$status.Watcher.ConfiguredMaxRoundtripCount -eq 1) -and
            ([string]$status.Watcher.ControlPendingAction -eq '')
        }

    Assert-True ($stoppedStatus.Watcher.Status -eq 'stopped') 'Expected watcher to stop on pair roundtrip limit.'
    Assert-True ([string]$stoppedStatus.Watcher.StatusReason -eq 'pair-roundtrip-limit-reached') 'Expected watcher reason to be pair-roundtrip-limit-reached.'
    Assert-True ([string]$stoppedStatus.Watcher.StopCategory -eq 'expected-limit') 'Expected pair roundtrip limit stop category to map to expected-limit.'
    Assert-True ([int]$stoppedStatus.Watcher.ConfiguredMaxRoundtripCount -eq 1) 'Expected watcher status to expose configured pair roundtrip limit.'
    Assert-True ([bool]$stoppedStatus.PairState.Exists) 'Expected pair roundtrip limit flow to persist pair-state metadata.'

    $pairSummary = @($stoppedStatus.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
    Assert-True (@($pairSummary).Count -eq 1) 'Expected pair01 summary row to exist.'
    Assert-True ([int]$pairSummary[0].RoundtripCount -eq 1) 'Expected pair01 roundtrip count to reflect the forwarded state baseline.'
    Assert-True ([bool]$pairSummary[0].ReachedRoundtripLimit) 'Expected pair01 summary to mark the roundtrip limit as reached.'
    Assert-True ([string]$pairSummary[0].CurrentPhase -eq 'limit-reached') 'Expected pair01 summary to expose the limit-reached phase.'
}
finally {
    if ($null -ne $process) {
        [void]$process.WaitForExit(12000)
    }
}

Write-Host ('watcher pair roundtrip limit contract ok: runRoot=' + $contractRunRoot)
