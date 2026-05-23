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
$testRoot = Join-Path $root '_tmp\test-show-paired-exchange-status-typed-window-scope'
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
foreach ($path in @($runtimeRoot, $logsRoot, $inboxTarget01, $inboxTarget05, $processedRoot, $failedRoot, $retryPendingRoot)) {
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
    -SeedTaskText 'show paired exchange status typed-window scope test' | Out-Null

$seedSendStatusPath = Join-Path $runRoot '.state\seed-send-status.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $seedSendStatusPath) -Force | Out-Null
$seedSendPayload = [ordered]@{
    SchemaVersion = '1.0.0'
    RunRoot = $runRoot
    UpdatedAt = (Get-Date).ToString('o')
    Targets = @(
        [ordered]@{
            TargetId = 'target01'
            UpdatedAt = (Get-Date).ToString('o')
            FinalState = 'manual_attention_required'
            SubmitState = 'failed'
            SubmitReason = 'target relay folder mismatch: target=target01 configFolder=C:\bad expectedFolder=C:\good'
            TypedWindowExecutionState = 'typed-window-inline-prepare-blocked'
            TypedWindowSessionState = 'recovery-needed'
            TypedWindowLastResetReason = 'typed-window-inline-prepare-blocked'
            TypedWindowSessionScopeKind = 'pair'
            TypedWindowSessionScopeId = 'pair01'
            TypedWindowSessionRouteKey = 'pair:pair01:target01'
        }
    )
}
$seedSendPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $seedSendStatusPath -Encoding UTF8

$statusRaw = & (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$status = $statusRaw | ConvertFrom-Json
$targetRow = @($status.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

Assert-True ($null -ne $targetRow) 'paired status should include target01 row.'
Assert-True ([string]$targetRow.TypedWindowSessionState -eq 'recovery-needed') 'paired status should surface typed-window session state.'
Assert-True ([string]$targetRow.TypedWindowSessionScopeKind -eq 'pair') 'paired status should surface typed-window session scope kind.'
Assert-True ([string]$targetRow.TypedWindowSessionScopeId -eq 'pair01') 'paired status should surface typed-window session scope id.'
Assert-True ([string]$targetRow.TypedWindowSessionRouteKey -eq 'pair:pair01:target01') 'paired status should surface typed-window session route key.'
Assert-True ([string]$targetRow.RelayTargetFolderState -eq 'relay-folder-mismatch') 'paired status should classify relay folder mismatch distinctly.'
Assert-True ([string]$targetRow.SubmitStateDisplay -eq 'relay-folder-mismatch') 'paired status should expose relay folder mismatch as submit display state.'
Assert-True ([int]$status.Counts.RelayFolderMismatchCount -eq 1) 'paired status counts should include relay-folder mismatch targets.'
Assert-True ([int]$status.Counts.RelayFolderMissingCount -eq 0) 'paired status counts should exclude relay-folder missing when absent.'
Assert-True ([int]$status.Counts.RelayFolderConfigMissingCount -eq 0) 'paired status counts should exclude relay-folder config-missing when absent.'

Write-Host 'show-paired-exchange-status typed-window scope ok'
