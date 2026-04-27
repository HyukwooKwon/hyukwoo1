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
$testRoot = Join-Path $root '_tmp\test-send-initial-pair-seed-inline-prepare-blocked'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runRoot = Join-Path $testRoot 'run'
$runtimeRoot = Join-Path $testRoot 'runtime'
$logsRoot = Join-Path $testRoot 'logs'
$inboxTarget01 = Join-Path $testRoot 'inbox\target01'
$inboxTarget05 = Join-Path $testRoot 'inbox\target05'
$processedRoot = Join-Path $testRoot 'processed'
$failedRoot = Join-Path $testRoot 'failed'
$retryPendingRoot = Join-Path $testRoot 'retry-pending'
$sessionRoot = Join-Path $runtimeRoot 'typed-window-session'
foreach ($path in @($inboxTarget01, $inboxTarget05, $processedRoot, $failedRoot, $retryPendingRoot, $sessionRoot, $logsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    MaxPayloadChars = 4000
    MaxPayloadBytes = 12000
    RuntimeRoot = '$($runtimeRoot.Replace("'", "''"))'
    LogsRoot = '$($logsRoot.Replace("'", "''"))'
    ProcessedRoot = '$($processedRoot.Replace("'", "''"))'
    FailedRoot = '$($failedRoot.Replace("'", "''"))'
    RetryPendingRoot = '$($retryPendingRoot.Replace("'", "''"))'
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($inboxTarget01.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow01'
            FixedSuffix = `$null
        }
        @{
            Id = 'target05'
            Folder = '$($inboxTarget05.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow05'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        RunRootBase = '$($testRoot.Replace("'", "''"))'
        ExecutionPathMode = 'typed-window'
        TypedWindow = @{
            SubmitProbeSeconds = 1
            SubmitProbePollMs = 200
            SubmitRetryLimit = 0
            ProgressCpuDeltaThresholdSeconds = 0.05
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$reviewInputPath = Join-Path $root 'README.md'
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $root `
    -SeedReviewInputPath $reviewInputPath `
    -SeedTaskText 'inline prepare blocked test' | Out-Null

$sessionPath = Join-Path $sessionRoot 'target01.json'
$dirtySession = [ordered]@{
    SchemaVersion = '1.0.0'
    TargetId = 'target01'
    State = 'dirty-session'
    SessionRunRoot = (Join-Path $testRoot 'old-run')
    SessionPairId = 'pair01'
    SessionTargetId = 'target01'
    SessionEpoch = 3
    LastPrepareAt = ''
    LastSubmitAt = ''
    LastProgressAt = ''
    LastConfirmedArtifactAt = ''
    LastResetReason = 'typed-window-submit-unconfirmed'
    ConsecutiveSubmitUnconfirmedCount = 1
    UpdatedAt = (Get-Date).ToString('o')
}
$dirtySession | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionPath -Encoding UTF8

$resultRaw = & (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -MaxAttempts 1 `
    -DelaySeconds 1 `
    -WaitForRouterSeconds 3 `
    -DisallowInlineTypedWindowPrepare `
    -AsJson
$result = $resultRaw | ConvertFrom-Json

Assert-True ([string]$result.FinalState -eq 'manual_attention_required') 'inline prepare guard should fail fast with manual attention required.'
Assert-True ([string]$result.SubmitReason -eq 'typed-window-inline-prepare-blocked') 'inline prepare guard should expose typed-window-inline-prepare-blocked submit reason.'
Assert-True ([string]$result.TypedWindowExecutionState -eq 'typed-window-inline-prepare-blocked') 'inline prepare guard should record typed-window-inline-prepare-blocked execution state.'
Assert-True ([string]$result.SubmitProbeState -eq 'typed-window-inline-prepare-blocked') 'inline prepare guard should record typed-window-inline-prepare-blocked probe state.'
Assert-True ([string]$result.TypedWindowSessionState -eq 'recovery-needed') 'inline prepare guard should keep the session in recovery-needed state.'
Assert-True ([string]$result.TypedWindowLastResetReason -eq 'typed-window-inline-prepare-blocked') 'inline prepare guard should record the reset reason.'
Assert-True ([string]$result.SubmitConfirmationSignal -like '*dirty-session*') 'inline prepare guard should expose the blocked prepare reason.'

$seedSendStatusPath = Join-Path $runRoot '.state\seed-send-status.json'
$seedSendStatus = Get-Content -LiteralPath $seedSendStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetStatus = @($seedSendStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$targetStatus.FinalState -eq 'manual_attention_required') 'persisted status should record manual attention required.'
Assert-True ([string]$targetStatus.SubmitReason -eq 'typed-window-inline-prepare-blocked') 'persisted status should record inline prepare blocked reason.'

Write-Host ('send-initial-pair-seed-inline-prepare-blocked ok: runRoot=' + $runRoot)
