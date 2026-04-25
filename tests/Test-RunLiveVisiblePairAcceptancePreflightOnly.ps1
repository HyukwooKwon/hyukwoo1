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

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-run-live-visible-pair-acceptance-preflight-only'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$inbox01 = Join-Path $testRoot 'inbox\target01'
$inbox05 = Join-Path $testRoot 'inbox\target05'
$runtimeRoot = Join-Path $testRoot 'runtime'
$pairRoot = Join-Path $testRoot 'pair-test'
$processedRoot = Join-Path $testRoot 'processed'
$failedRoot = Join-Path $testRoot 'failed'
$retryRoot = Join-Path $testRoot 'retry-pending'
$ignoredRoot = Join-Path $testRoot 'ignored'
$wrapperPath = Join-Path $testRoot 'wrapper.py'
New-Item -ItemType Directory -Path $inbox01,$inbox05,$runtimeRoot,$pairRoot,$processedRoot,$failedRoot,$retryRoot,$ignoredRoot -Force | Out-Null
[System.IO.File]::WriteAllText($wrapperPath, "print('wrapper test')`n", (New-Utf8NoBomEncoding))

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    MaxPayloadChars = 4000
    MaxPayloadBytes = 12000
    InboxRoot = '$($(Join-Path $testRoot 'inbox').Replace("'", "''"))'
    ProcessedRoot = '$($processedRoot.Replace("'", "''"))'
    FailedRoot = '$($failedRoot.Replace("'", "''"))'
    RetryPendingRoot = '$($retryRoot.Replace("'", "''"))'
    IgnoredRoot = '$($ignoredRoot.Replace("'", "''"))'
    RouterMutexName = 'Global\RelayRouter_test_preflight_only'
    RouterStatePath = '$($runtimeRoot.Replace("'", "''"))\router-state.json'
    RouterLogPath = '$($runtimeRoot.Replace("'", "''"))\router.log'
    LauncherWrapperPath = '$($wrapperPath.Replace("'", "''"))'
    WindowLaunch = @{
        LauncherMode = 'wrapper'
        ReuseMode = 'attach-only'
        DirectStartAllowed = `$false
        AllowReplaceExisting = `$false
    }
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($inbox01.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow01'
            FixedSuffix = `$null
        }
        @{
            Id = 'target05'
            Folder = '$($inbox05.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow05'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        RunRootBase = '$($pairRoot.Replace("'", "''"))'
        HeadlessExec = @{
            Enabled = `$true
            MaxRunSeconds = 480
        }
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($(Join-Path $runtimeRoot 'visible-worker\queue').Replace("'", "''"))'
            StatusRoot = '$($(Join-Path $runtimeRoot 'visible-worker\status').Replace("'", "''"))'
            LogRoot = '$($(Join-Path $runtimeRoot 'visible-worker\logs').Replace("'", "''"))'
            PollIntervalMs = 300
            IdleExitSeconds = 30
            CommandTimeoutSeconds = 540
            PreflightTimeoutSeconds = 30
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$runRoot = Join-Path $pairRoot 'run_preflight_only'
$resultRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -PairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $root `
    -SeedReviewInputPath (Join-Path $root 'README.md') `
    -PreflightOnly `
    -AsJson

if ($LASTEXITCODE -ne 0) {
    throw ('Run-LiveVisiblePairAcceptance preflight-only failed: ' + (($resultRaw | Out-String).Trim()))
}

$result = $resultRaw | ConvertFrom-Json
Assert-True ([string]$result.Stage -eq 'completed') 'preflight-only run should complete without seeding.'
Assert-True ([string]$result.Outcome.AcceptanceState -eq 'preflight-passed') 'preflight-only run should report preflight-passed.'
Assert-True ([string]$result.ExecutionPathMode -eq 'visible-worker') 'preflight-only run should expose visible-worker execution path mode.'
Assert-True ([int]$result.Preflight.AcceptanceForwardedStateCount -eq 2) 'preflight-only should expose 2-forward acceptance target count.'
Assert-True ([int]$result.Preflight.CloseoutForwardedStateCount -eq 2) 'preflight-only without keep-running should expose same closeout target count.'
Assert-True ([bool]$result.Preflight.VisibleWorkerIdleOk) 'preflight-only should require idle visible worker state.'
Assert-True ([bool]$result.Preflight.VisibleWorkerQueueEmptyOk) 'preflight-only should require empty visible worker queue.'
Assert-True ([bool]$result.Preflight.VisibleWorkerProcessingEmptyOk) 'preflight-only should require empty visible worker processing.'
Assert-True ([bool]$result.Preflight.VisibleWorkerReadyOk) 'preflight-only should require visible worker readiness.'
Assert-True ([int]$result.Preflight.EffectiveWatcherRunDurationSec -ge [int]$result.Preflight.RequestedWatcherRunDurationSec) 'effective watcher duration should not be smaller than requested.'
Assert-True ([string]$result.WindowLaunchMode -eq 'wrapper') 'preflight-only should expose wrapper launch mode.'
Assert-True ([string]$result.WindowReuseMode -eq 'attach-only') 'preflight-only should expose attach-only reuse mode.'
Assert-True ([string]$result.WrapperPath -eq $wrapperPath) 'preflight-only should expose configured wrapper path.'
Assert-True ([string]$result.Preflight.WindowLaunchMode -eq 'wrapper') 'preflight should expose wrapper launch mode.'
Assert-True ([string]$result.Preflight.WindowReuseMode -eq 'attach-only') 'preflight should expose attach-only reuse mode.'
Assert-True ([string]$result.Preflight.WrapperPath -eq $wrapperPath) 'preflight should expose configured wrapper path.'
Assert-True ([bool]$result.Preflight.NonStandardWindowBlock) 'preflight should record non-standard visible window blocking policy for wrapper-managed lane.'
Assert-True ([string]$result.BlockedBy -eq '') 'preflight-only success should not expose blocked reason.'
Assert-True ([string]$result.Preflight.BlockedBy -eq '') 'preflight-only success preflight block should not expose blocked reason.'
Assert-True ([string]$result.Closeout.Status -eq 'not-requested') 'preflight-only should mark closeout as not requested by default.'
Assert-True ($null -eq $result.Seed) 'preflight-only should not dispatch seed work.'
Assert-True (@($result.PhaseHistory).Count -ge 3) 'preflight-only should record receipt phase history.'
Assert-True ([string]@($result.PhaseHistory | Select-Object -Last 1)[0].Stage -eq 'completed') 'phase history should keep the completed terminal stage.'
Assert-True (@($result.PhaseHistory | Where-Object { [string]$_.Stage -eq 'visible-worker-preflight' }).Count -ge 1) 'phase history should preserve the visible-worker-preflight phase.'

Write-Host 'run-live-visible-pair-acceptance preflight-only ok'
