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

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload,
        [int]$Depth = 12
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth $Depth), (New-Utf8NoBomEncoding))
}

function New-TestPairRun {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$WatcherState,
        [Parameter(Mandatory)][string]$WatcherReason,
        [Parameter(Mandatory)][int]$RoundtripCount,
        [Parameter(Mandatory)][string]$CurrentPhase,
        [int]$DonePresentCount = 2,
        [int]$ErrorPresentCount = 0
    )

    New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $RunRoot '.state') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $RunRoot "$PairId\target01") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $RunRoot "$PairId\target05") -Force | Out-Null

    $targetIds = @('target01', 'target05', 'target02', 'target06')
    for ($i = 0; $i -lt $DonePresentCount; $i++) {
        $targetId = $targetIds[$i]
        $donePath = Join-Path $RunRoot (Join-Path $PairId (Join-Path $targetId 'done.json'))
        $doneParent = Split-Path -Parent $donePath
        if (-not (Test-Path -LiteralPath $doneParent)) {
            New-Item -ItemType Directory -Path $doneParent -Force | Out-Null
        }
        Set-Content -LiteralPath $donePath -Value '{}' -Encoding UTF8
    }
    for ($i = 0; $i -lt $ErrorPresentCount; $i++) {
        $targetId = $targetIds[$i]
        $errorPath = Join-Path $RunRoot (Join-Path $PairId (Join-Path $targetId 'error.json'))
        $errorParent = Split-Path -Parent $errorPath
        if (-not (Test-Path -LiteralPath $errorParent)) {
            New-Item -ItemType Directory -Path $errorParent -Force | Out-Null
        }
        Set-Content -LiteralPath $errorPath -Value '{}' -Encoding UTF8
    }

    Write-JsonFile -Path (Join-Path $RunRoot '.state\watcher-status.json') -Payload ([pscustomobject]@{
        SchemaVersion = '1.0.0'
        RunRoot = $RunRoot
        State = $WatcherState
        UpdatedAt = (Get-Date).ToString('o')
        HeartbeatAt = (Get-Date).ToString('o')
        Reason = $WatcherReason
        StopCategory = if ($WatcherState -eq 'stopped') { 'expected-limit' } else { '' }
        ForwardedCount = $RoundtripCount * 2
        ConfiguredMaxRoundtripCount = 1
    })

    Write-JsonFile -Path (Join-Path $RunRoot '.state\pair-state.json') -Payload ([pscustomobject]@{
        SchemaVersion = '1.0.0'
        RunRoot = $RunRoot
        UpdatedAt = (Get-Date).ToString('o')
        Pairs = @(
            [pscustomobject]@{
                PairId = $PairId
                RoundtripCount = $RoundtripCount
                ForwardCount = $RoundtripCount * 2
                CurrentPhase = $CurrentPhase
                NextAction = $CurrentPhase
                HandoffReadyCount = $RoundtripCount * 2
                LastForwardedAt = (Get-Date).ToString('o')
            }
        )
    })
}

$root = Split-Path -Parent $PSScriptRoot
$resolveScript = Join-Path $root 'tests\Resolve-ParallelPairScopedWrapperStatus.ps1'
$fixtureRoot = Join-Path 'C:\dev\python\_relay-test-fixtures\Test-ResolveParallelPairScopedWrapperStatus' (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

# success reconciliation
$successCoordinatorRunRoot = Join-Path $fixtureRoot 'repo-coordinator\.relay-runs\bottest-live-visible\pair-scoped-shared\run_success'
$successWrapperStatusPath = Join-Path $successCoordinatorRunRoot '.state\wrapper-status.json'
$successPair01Base = Join-Path $fixtureRoot 'repo-a\.relay-runs\bottest-live-visible\pairs\pair01'
$successPair02Base = Join-Path $fixtureRoot 'repo-b\.relay-runs\bottest-live-visible\pairs\pair02'
$successPair01RunRoot = Join-Path $successPair01Base 'run_pair01'
$successPair02RunRoot = Join-Path $successPair02Base 'run_pair02'

New-TestPairRun -RunRoot $successPair01RunRoot -PairId 'pair01' -WatcherState 'stopped' -WatcherReason 'pair-roundtrip-limit-reached' -RoundtripCount 1 -CurrentPhase 'limit-reached'
New-TestPairRun -RunRoot $successPair02RunRoot -PairId 'pair02' -WatcherState 'stopped' -WatcherReason 'pair-roundtrip-limit-reached' -RoundtripCount 1 -CurrentPhase 'limit-reached'

Write-JsonFile -Path $successWrapperStatusPath -Payload ([pscustomobject]@{
    SchemaVersion = '1.0.0'
    Status = 'running'
    UpdatedAt = (Get-Date).ToString('o')
    BaseConfigPath = 'C:\dev\python\hyukwoo\hyukwoo1\config\settings.bottest-live-visible.psd1'
    CoordinatorWorkRepoRoot = (Join-Path $fixtureRoot 'repo-coordinator')
    CoordinatorRunRoot = $successCoordinatorRunRoot
    CoordinatorManifestPath = (Join-Path $successCoordinatorRunRoot 'manifest.json')
    CoordinatorWatcherStatusPath = (Join-Path $successCoordinatorRunRoot '.state\watcher-status.json')
    CoordinatorPairStatePath = (Join-Path $successCoordinatorRunRoot '.state\pair-state.json')
    PairIds = @('pair01', 'pair02')
    PairMaxRoundtripCount = 1
    RunDurationSec = 900
    Message = 'child pair runs started'
    GeneratedConfigs = @()
    ChildProcesses = @(
        [pscustomobject]@{
            PairId = 'pair01'
            ConfigPath = 'pair01.psd1'
            WorkRepoRoot = (Join-Path $fixtureRoot 'repo-a')
            BookkeepingRoot = (Join-Path $fixtureRoot 'repo-a\.relay-bookkeeping\bottest-live-visible\pairs\pair01')
            PairRunRootBase = $successPair01Base
            StdOutPath = ''
            StdErrPath = ''
            ProcessId = 0
            ProcessStartedAt = (Get-Date).ToString('o')
            ExitCode = 0
            RunRoot = ''
            ProcessExitedAt = ''
        },
        [pscustomobject]@{
            PairId = 'pair02'
            ConfigPath = 'pair02.psd1'
            WorkRepoRoot = (Join-Path $fixtureRoot 'repo-b')
            BookkeepingRoot = (Join-Path $fixtureRoot 'repo-b\.relay-bookkeeping\bottest-live-visible\pairs\pair02')
            PairRunRootBase = $successPair02Base
            StdOutPath = ''
            StdErrPath = ''
            ProcessId = 0
            ProcessStartedAt = (Get-Date).ToString('o')
            ExitCode = 0
            RunRoot = ''
            ProcessExitedAt = ''
        }
    )
    PairRuns = @()
})

$successResult = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $resolveScript -WrapperStatusPath $successWrapperStatusPath -AsJson | ConvertFrom-Json
Assert-True ([string]$successResult.Status -eq 'completed') 'Expected wrapper reconcile success status.'
Assert-True ([string]$successResult.FinalResult -eq 'success') 'Expected wrapper reconcile success final result.'
Assert-True ([string]$successResult.CompletionSource -eq 'coordinator-reconcile') 'Expected wrapper reconcile completion source.'
Assert-True (@($successResult.PairRuns).Count -eq 2) 'Expected wrapper reconcile to include two pair runs.'
Assert-True (Test-Path -LiteralPath ([string]$successResult.CoordinatorManifestPath) -PathType Leaf) 'Expected reconciled coordinator manifest.'
Assert-True (Test-Path -LiteralPath ([string]$successResult.CoordinatorWatcherStatusPath) -PathType Leaf) 'Expected reconciled coordinator watcher status.'
Assert-True (Test-Path -LiteralPath ([string]$successResult.CoordinatorPairStatePath) -PathType Leaf) 'Expected reconciled coordinator pair state.'

$reconciledWatcher = Get-Content -LiteralPath ([string]$successResult.CoordinatorWatcherStatusPath) -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$reconciledWatcher.Status -eq 'stopped') 'Expected reconciled coordinator watcher stopped.'

# running reconciliation
$runningCoordinatorRunRoot = Join-Path $fixtureRoot 'repo-coordinator\.relay-runs\bottest-live-visible\pair-scoped-shared\run_running'
$runningWrapperStatusPath = Join-Path $runningCoordinatorRunRoot '.state\wrapper-status.json'
$runningPair01Base = Join-Path $fixtureRoot 'repo-c\.relay-runs\bottest-live-visible\pairs\pair01'
$runningPair01RunRoot = Join-Path $runningPair01Base 'run_pair01'

New-TestPairRun -RunRoot $runningPair01RunRoot -PairId 'pair01' -WatcherState 'running' -WatcherReason 'heartbeat' -RoundtripCount 0 -CurrentPhase 'partner-running' -DonePresentCount 1

Write-JsonFile -Path $runningWrapperStatusPath -Payload ([pscustomobject]@{
    SchemaVersion = '1.0.0'
    Status = 'running'
    UpdatedAt = (Get-Date).ToString('o')
    BaseConfigPath = 'C:\dev\python\hyukwoo\hyukwoo1\config\settings.bottest-live-visible.psd1'
    CoordinatorWorkRepoRoot = (Join-Path $fixtureRoot 'repo-coordinator')
    CoordinatorRunRoot = $runningCoordinatorRunRoot
    CoordinatorManifestPath = (Join-Path $runningCoordinatorRunRoot 'manifest.json')
    CoordinatorWatcherStatusPath = (Join-Path $runningCoordinatorRunRoot '.state\watcher-status.json')
    CoordinatorPairStatePath = (Join-Path $runningCoordinatorRunRoot '.state\pair-state.json')
    PairIds = @('pair01')
    PairMaxRoundtripCount = 1
    RunDurationSec = 900
    Message = 'child pair runs started'
    GeneratedConfigs = @()
    ChildProcesses = @(
        [pscustomobject]@{
            PairId = 'pair01'
            ConfigPath = 'pair01.psd1'
            WorkRepoRoot = (Join-Path $fixtureRoot 'repo-c')
            BookkeepingRoot = (Join-Path $fixtureRoot 'repo-c\.relay-bookkeeping\bottest-live-visible\pairs\pair01')
            PairRunRootBase = $runningPair01Base
            StdOutPath = ''
            StdErrPath = ''
            ProcessId = 0
            ProcessStartedAt = (Get-Date).ToString('o')
            ExitCode = 0
            RunRoot = ''
            ProcessExitedAt = ''
        }
    )
    PairRuns = @()
})

$runningResult = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $resolveScript -WrapperStatusPath $runningWrapperStatusPath -AsJson | ConvertFrom-Json
Assert-True ([string]$runningResult.Status -eq 'running') 'Expected wrapper reconcile running status.'
Assert-True ([string]$runningResult.FinalResult -eq 'timed_out_parent_but_children_running') 'Expected wrapper reconcile running final result.'
Assert-True (@($runningResult.PairRuns).Count -eq 1) 'Expected wrapper reconcile running pair count.'
Assert-True (-not (Test-Path -LiteralPath ([string]$runningResult.CoordinatorManifestPath) -PathType Leaf)) 'Did not expect coordinator manifest for running reconcile.'

Write-Host 'parallel pair-scoped wrapper status reconcile contract ok'
