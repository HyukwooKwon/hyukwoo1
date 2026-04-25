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
$testRoot = Join-Path $root '_tmp\test-show-paired-exchange-status-late-seed-success'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    MaxPayloadChars = 4000
    MaxPayloadBytes = 12000
    ProcessedRoot = '$($testRoot.Replace("'", "''"))\processed'
    FailedRoot = '$($testRoot.Replace("'", "''"))\failed'
    RetryPendingRoot = '$($testRoot.Replace("'", "''"))\retry-pending'
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'
            EnterCount = 1
            WindowTitle = 'TestWindow01'
            FixedSuffix = `$null
        }
        @{
            Id = 'target05'
            Folder = '$($testRoot.Replace("'", "''"))\inbox\target05'
            EnterCount = 1
            WindowTitle = 'TestWindow05'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        RunRootBase = '$($testRoot.Replace("'", "''"))'
        ExecutionPathMode = 'visible-worker'
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($testRoot.Replace("'", "''"))\visible-worker\queue'
            StatusRoot = '$($testRoot.Replace("'", "''"))\visible-worker\status'
            LogRoot = '$($testRoot.Replace("'", "''"))\visible-worker\logs'
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$runRoot = Join-Path $testRoot 'run'
$reviewInputPath = Join-Path $root 'README.md'
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $root `
    -SeedReviewInputPath $reviewInputPath `
    -SeedTaskText 'late seed success status test' | Out-Null

$manifest = Get-Content -LiteralPath (Join-Path $runRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$targetRow = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ($null -ne $targetRow) 'manifest should contain target01.'

New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName([string]$targetRow.SourceSummaryPath)) -Force | Out-Null
Set-Content -LiteralPath ([string]$targetRow.SourceSummaryPath) -Encoding UTF8 -Value 'summary-ready'
Set-Content -LiteralPath ([string]$targetRow.SourceReviewZipPath) -Encoding UTF8 -Value 'zip-ready'
@{
    SchemaVersion = '1.0.0'
    PairId = 'pair01'
    TargetId = 'target01'
    SummaryPath = [string]$targetRow.SourceSummaryPath
    ReviewZipPath = [string]$targetRow.SourceReviewZipPath
    PublishedAt = (Get-Date).ToString('o')
    SummarySizeBytes = 12
    ReviewZipSizeBytes = 8
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ([string]$targetRow.PublishReadyPath) -Encoding UTF8

$stateRoot = Join-Path $runRoot '.state'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
@{
    SchemaVersion = '1.0.0'
    RunRoot = $runRoot
    UpdatedAt = (Get-Date).ToString('o')
    Targets = @(
        @{
            TargetId = 'target01'
            UpdatedAt = (Get-Date).ToString('o')
            FinalState = 'timeout'
            RouterDispatchState = 'timeout'
            SubmitState = 'unconfirmed'
            SubmitConfirmed = $false
            SubmitReason = 'visible-worker-dispatch-timeout'
            AttemptCount = 1
            MaxAttempts = 1
            FirstAttemptedAt = (Get-Date).AddMinutes(-10).ToString('o')
            LastAttemptedAt = (Get-Date).AddMinutes(-9).ToString('o')
            NextRetryAt = ''
            BackoffMs = 0
            RetryReason = 'visible-worker-dispatch-timeout'
            ManualAttentionRequired = $false
            ProcessedPath = ''
            ProcessedAt = ''
            FailedPath = ''
            FailedAt = ''
            RetryPendingPath = ''
            RetryPendingAt = ''
            OutboxPublished = $false
            OutboxObservedAt = ''
            LastReadyPath = ''
            LastReadyBaseName = ''
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'seed-send-status.json') -Encoding UTF8
@{
    SchemaVersion = '1.0.0'
    UpdatedAt = (Get-Date).ToString('o')
    Targets = @(
        @{
            TargetId = 'target01'
            PairId = 'pair01'
            UpdatedAt = (Get-Date).ToString('o')
            State = 'publish-started'
            Reason = 'test-late-success'
            ContractLatestState = 'ready-to-forward'
            NextAction = 'handoff-ready'
            SourceOutboxLastActivityAt = (Get-Date).ToString('o')
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'source-outbox-status.json') -Encoding UTF8

$statusRaw = & (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$status = $statusRaw | ConvertFrom-Json
$targetStatus = @($status.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Assert-True ([string]$targetStatus.SeedSendState -eq 'superseded-late-success') 'late source-outbox success should supersede timeout seed state.'
Assert-True ([bool]$targetStatus.SeedSendSuperseded) 'late source-outbox success should mark seed send as superseded.'
Assert-True ([string]$targetStatus.SubmitState -eq 'confirmed') 'late source-outbox success should mark submit confirmed.'
Assert-True ([string]$targetStatus.SeedSendRawState -eq 'timeout') 'raw seed state should preserve original timeout.'

Write-Host ('show-paired-exchange-status late seed success ok: runRoot=' + $runRoot)
