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

    [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth 12), (New-Utf8NoBomEncoding))
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-cleanup-visible-worker-post-cleanup-receipt'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$runtimeRoot = Join-Path $testRoot 'runtime'
$queueRoot = Join-Path $runtimeRoot 'visible-worker\queue\target01'
$queuedRoot = Join-Path $queueRoot 'queued'
$statusRoot = Join-Path $runtimeRoot 'visible-worker\status'
$logRoot = Join-Path $runtimeRoot 'visible-worker\logs'
$runRoot = Join-Path $testRoot 'pair-test\run_current'
New-Item -ItemType Directory -Path $queuedRoot,$statusRoot,$logRoot,$runRoot -Force | Out-Null

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($testRoot.Replace("'", "''"))\inbox\target01'
            EnterCount = 1
            WindowTitle = 'CleanupReceiptWindow01'
            FixedSuffix = `$null
        }
        @{
            Id = 'target02'
            Folder = '$($testRoot.Replace("'", "''"))\inbox\target02'
            EnterCount = 1
            WindowTitle = 'CleanupReceiptWindow02'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        PairDefinitions = @(
            @{
                PairId = 'pair01'
                TopTargetId = 'target01'
                BottomTargetId = 'target02'
                SeedTargetId = 'target01'
            }
        )
        VisibleWorker = @{
            Enabled = `$true
            QueueRoot = '$($(Join-Path $runtimeRoot 'visible-worker\queue').Replace("'", "''"))'
            StatusRoot = '$($statusRoot.Replace("'", "''"))'
            LogRoot = '$($logRoot.Replace("'", "''"))'
        }
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$receiptPath = Join-Path $runRoot '.state\live-acceptance-result.json'
Write-JsonFile -Path $receiptPath -Payload ([ordered]@{
    Stage = 'handoff-checking'
    LastUpdatedAt = '2026-05-10T15:00:00+09:00'
    Outcome = [ordered]@{
        AcceptanceState = 'roundtrip-confirmed'
        AcceptanceReason = 'ok'
    }
    PhaseHistory = @(
        [ordered]@{
            RecordedAt = '2026-05-10T14:59:00+09:00'
            Stage = 'active-acceptance'
            AcceptanceState = 'pending'
        },
        [ordered]@{
            RecordedAt = '2026-05-10T15:00:00+09:00'
            Stage = 'handoff-checking'
            AcceptanceState = 'roundtrip-confirmed'
        }
    )
})

$resultRaw = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Cleanup-VisibleWorkerQueue.ps1') `
    -ConfigPath $configPath `
    -TargetId target01 `
    -KeepRunRoot $runRoot `
    -Apply `
    -MarkAcceptancePostCleanup `
    -AsJson
if ($LASTEXITCODE -ne 0) {
    throw ('cleanup post-cleanup receipt update failed: ' + (($resultRaw | Out-String).Trim()))
}

$result = $resultRaw | ConvertFrom-Json
Assert-True ([bool]$result.ReceiptUpdated) 'cleanup should report ReceiptUpdated=true for post-cleanup receipt mark.'
Assert-True ([bool]$result.PreflightPassed) 'cleanup should surface canonical PreflightPassed.'
Assert-True ([bool]$result.ActiveAttempted) 'cleanup should surface canonical ActiveAttempted.'
Assert-True ([bool]$result.PostCleanupDone) 'cleanup should surface canonical PostCleanupDone.'
Assert-True (-not [bool]$result.CleanPreflightPassed) 'cleanup should reset canonical CleanPreflightPassed until recheck.'

$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$receipt.Stage -eq 'post-cleanup') 'receipt stage should be updated to post-cleanup.'
Assert-True ([bool]$receipt.PreflightPassed) 'receipt should persist canonical PreflightPassed.'
Assert-True ([bool]$receipt.ActiveAttempted) 'receipt should persist canonical ActiveAttempted.'
Assert-True ([bool]$receipt.PostCleanupDone) 'receipt should persist canonical PostCleanupDone.'
Assert-True (-not [bool]$receipt.CleanPreflightPassed) 'receipt should persist canonical CleanPreflightPassed=false.'
Assert-True (@($receipt.PhaseHistory).Count -ge 3) 'receipt should append a post-cleanup phase-history entry.'
Assert-True ([string]@($receipt.PhaseHistory | Select-Object -Last 1)[0].Stage -eq 'post-cleanup') 'receipt should append post-cleanup terminal phase.'

Write-Host 'cleanup-visible-worker-queue post-cleanup receipt ok'
