[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Assert-True {
    param(
        [Parameter(Mandatory)]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not [bool]$Condition) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusRetryPending'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_status_retry_pending'
$runtimeRoot = Join-Path $tmpRoot 'runtime'
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
$routerStatePath = Join-Path $runtimeRoot 'router-state.json'
$retryPendingRoot = Join-Path $tmpRoot 'retry-pending'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
New-Item -ItemType Directory -Path $retryPendingRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    RuntimeMapPath = '$($runtimeMapPath.Replace("'", "''"))'
    RouterStatePath = '$($routerStatePath.Replace("'", "''"))'
    RetryPendingRoot = "$retryPendingRoot"
    Targets = @(
        @{ Id = 'target01'; Folder = '$((Join-Path $tmpRoot 'inbox\target01').Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('publish-ready'); MaxCycleCount = 2 }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

@(
    [ordered]@{
        TargetId = 'target01'
        LauncherSessionId = 'session-current'
        Available = $true
    }
) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeMapPath -Encoding UTF8

[ordered]@{
    Status = 'running'
    RouterPid = $PID
    LauncherSessionId = 'session-current'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $routerStatePath -Encoding UTF8

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json

$status = Get-Content -LiteralPath $start.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$status.WatcherState = 'stopped'
$status.WatcherStopReason = 'test-stopped'
$status.LastUpdatedAt = (Get-Date).ToString('o')
$status | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatusPath -Encoding UTF8

$retryFile = Join-Path $retryPendingRoot 'target01__20260525_000000_000__message.ready.txt'
[System.IO.File]::WriteAllText($retryFile, 'payload', (New-Utf8NoBomEncoding))
([ordered]@{
    FailureCategory = 'focus_lost'
    FailureMessage = 'active window changed before submit'
    DebugLogPath = Join-Path $tmpRoot 'focus-lost-debug.log'
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($retryFile + '.meta.json') -Encoding UTF8
([ordered]@{
    TargetId = 'target01'
    LauncherSessionId = 'session-current'
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($retryFile + '.delivery.json') -Encoding UTF8

$statusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True (-not [bool]$statusJson.RouterSessionMismatch) 'retry-pending recommendation test requires router session to be ok.'
Assert-True ([int]$statusJson.RouterRetryPendingSummary.Count -eq 1) 'status json should count retry-pending ready files.'
Assert-True ([string]$statusJson.RouterRetryPendingSummary.LatestFailureCategory -eq 'focus_lost') 'status json should surface latest retry-pending failure category.'
Assert-True ([string]$statusJson.RecommendationActionKey -eq 'requeue_retry_pending') 'status json should recommend retry-pending requeue.'
Assert-True ([string]$statusJson.RecommendationLabel -eq 'retry-pending 재큐잉') 'status json should surface retry-pending requeue label.'
Assert-True ([string]$statusJson.RecommendationDetail -match 'focus_lost') 'status json should explain latest retry-pending failure.'

$output = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$joined = (@($output) -join "`n")

Assert-True ($joined -match 'RouterRetryPending: count=1 targets=target01') 'status text should surface retry-pending summary.'
Assert-True ($joined -match 'RecommendationAction: requeue_retry_pending') 'status text should surface retry-pending action.'
Assert-True ($joined -match 'RecommendationLabel: retry-pending 재큐잉') 'status text should surface retry-pending label.'
Assert-True ($joined -match 'retryPending=1') 'status text counts should include retry-pending count.'

Write-Host 'show target autoloop status retry-pending ok'
