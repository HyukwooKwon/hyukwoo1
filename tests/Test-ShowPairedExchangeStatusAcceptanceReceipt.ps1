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
$tmpRoot = Join-Path $root '_tmp\Test-ShowPairedExchangeStatusAcceptanceReceipt'
$runtimeRoot = Join-Path $tmpRoot 'runtime'
$logsRoot = Join-Path $tmpRoot 'logs'
$inboxTarget01 = Join-Path $tmpRoot 'inbox\target01'
$inboxTarget05 = Join-Path $tmpRoot 'inbox\target05'
$processedRoot = Join-Path $tmpRoot 'processed'
$failedRoot = Join-Path $tmpRoot 'failed'
$retryPendingRoot = Join-Path $tmpRoot 'retry-pending'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $tmpRoot 'settings.test.psd1'
$stateRoot = Join-Path $runRoot '.state'
$receiptPath = Join-Path $stateRoot 'live-acceptance-result.json'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
foreach ($path in @($stateRoot, $runtimeRoot, $logsRoot, $inboxTarget01, $inboxTarget05, $processedRoot, $failedRoot, $retryPendingRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

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
        @{ Id = 'target01'; Folder = '$($inboxTarget01.Replace("'", "''"))'; EnterCount = 1; WindowTitle = 'TestWindow01'; FixedSuffix = `$null }
        @{ Id = 'target05'; Folder = '$($inboxTarget05.Replace("'", "''"))'; EnterCount = 1; WindowTitle = 'TestWindow05'; FixedSuffix = `$null }
    )
    PairTest = @{
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        ExecutionPathMode = 'typed-window'
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$receipt = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    RunRoot = $runRoot
    PairId = 'pair01'
    SeedTargetId = 'target01'
    PartnerTargetId = 'target05'
    Outcome = [pscustomobject]@{
        AcceptanceState = 'manual_attention_required'
        AcceptanceReason = 'user_active_hold'
        Diagnostics = [pscustomobject]@{
            Seed = [pscustomobject]@{
                TargetId = 'target01'
                SeedAttemptCount = 3
                SeedMaxAttempts = 3
                SeedRetryReason = 'user_active_hold'
            }
            Partner = [pscustomobject]@{
                TargetId = 'target05'
                LatestState = 'no-zip'
            }
        }
    }
    RelayIssues = [pscustomobject]@{
        RelayFolderMismatchCount = 1
        RelayFolderMissingCount = 0
        RelayFolderConfigMissingCount = 0
        RelayIssueSummary = 'relay-folder-mismatch:1'
        Source = 'current-receipt'
    }
}
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8

$statusRaw = & (Resolve-Path (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1')).Path `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$status = $statusRaw | ConvertFrom-Json

Assert-True ([bool]$status.AcceptanceReceipt.Exists) 'status should report acceptance receipt exists.'
Assert-True ([string]$status.AcceptanceReceipt.Path -eq $receiptPath) 'status should surface receipt path.'
Assert-True ([string]$status.AcceptanceReceipt.AcceptanceState -eq 'manual_attention_required') 'status should surface receipt acceptance state.'
Assert-True ([string]$status.AcceptanceReceipt.AcceptanceReason -eq 'user_active_hold') 'status should surface receipt acceptance reason.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$status.AcceptanceReceipt.GeneratedAt)) 'status should surface receipt generated at.'
Assert-True ([int]$status.AcceptanceReceipt.RelayFolderMismatchCount -eq 1) 'status should surface receipt relay-folder mismatch count.'
Assert-True ([int]$status.AcceptanceReceipt.RelayFolderMissingCount -eq 0) 'status should surface receipt relay-folder missing count.'
Assert-True ([int]$status.AcceptanceReceipt.RelayFolderConfigMissingCount -eq 0) 'status should surface receipt relay-folder config-missing count.'
Assert-True ([string]$status.AcceptanceReceipt.RelayIssueSummary -eq 'relay-folder-mismatch:1') 'status should surface receipt relay issue summary.'
Assert-True ([string]$status.AcceptanceReceipt.RelayIssuesSource -eq 'current-receipt') 'status should surface receipt relay issue source.'

Write-Host ('show paired exchange status acceptance receipt ok: runRoot=' + $runRoot)
