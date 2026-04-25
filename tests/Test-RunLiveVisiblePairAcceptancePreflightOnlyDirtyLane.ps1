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
        [Parameter(Mandatory)]$Payload
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth 10), (New-Utf8NoBomEncoding))
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-run-live-visible-pair-acceptance-preflight-dirty'
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
$queue05 = Join-Path $runtimeRoot 'visible-worker\queue\target05\queued'
New-Item -ItemType Directory -Path $inbox01,$inbox05,$runtimeRoot,$pairRoot,$processedRoot,$failedRoot,$retryRoot,$ignoredRoot,$queue05 -Force | Out-Null

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
    RouterMutexName = 'Global\RelayRouter_test_preflight_dirty'
    RouterStatePath = '$($runtimeRoot.Replace("'", "''"))\router-state.json'
    RouterLogPath = '$($runtimeRoot.Replace("'", "''"))\router.log'
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($inbox01.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestDirtyWindow01'
            FixedSuffix = `$null
        }
        @{
            Id = 'target05'
            Folder = '$($inbox05.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestDirtyWindow05'
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

$foreignRunRoot = Join-Path $testRoot 'pair-test\run_foreign'
New-Item -ItemType Directory -Path $foreignRunRoot -Force | Out-Null
$dirtyCommandPath = Join-Path $queue05 'command_target05_handoff_foreign.json'
Write-JsonFile -Path $dirtyCommandPath -Payload ([ordered]@{
    SchemaVersion = '1.0.0'
    CommandId = 'foreign-queued'
    CreatedAt = (Get-Date).ToString('o')
    RunRoot = $foreignRunRoot
    PairId = 'pair01'
    TargetId = 'target05'
    PartnerTargetId = 'target01'
    RoleName = 'bottom'
    Mode = 'handoff'
    PromptFilePath = (Join-Path $foreignRunRoot 'handoff.txt')
})

$runRoot = Join-Path $pairRoot 'run_preflight_only_dirty'
$resultRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -PairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $root `
    -SeedReviewInputPath (Join-Path $root 'README.md') `
    -PreflightOnly `
    -AsJson 2>&1

Assert-True ($LASTEXITCODE -ne 0) 'dirty preflight-only should fail when foreign queued command exists.'

$receiptPath = Join-Path $runRoot '.state\live-acceptance-result.json'
Assert-True (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'dirty preflight-only should still write receipt.'
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$receipt.BlockedBy -eq 'foreign-queued-command') 'dirty preflight-only should surface foreign queued command as blocked reason.'
Assert-True ([string]$receipt.BlockedTargetId -eq 'target05') 'dirty preflight-only should identify blocked target.'
Assert-True ([string]$receipt.Preflight.BlockedBy -eq 'foreign-queued-command') 'dirty preflight-only preflight block should surface foreign queued command.'

$workerStatusPath = Join-Path $runtimeRoot 'visible-worker\status\workers\worker_target05.json'
Assert-True (-not (Test-Path -LiteralPath $workerStatusPath -PathType Leaf)) 'dirty preflight-only should not auto-start target05 worker.'
Assert-True (Test-Path -LiteralPath $dirtyCommandPath -PathType Leaf) 'dirty preflight-only should not consume foreign queued command.'

Write-Host 'run-live-visible-pair-acceptance preflight-only dirty lane ok'
