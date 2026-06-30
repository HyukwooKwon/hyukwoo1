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

$currentOriginalPath = Join-Path $tmpRoot 'inbox\target01\current-router.ready.txt'
$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$state.Targets.target01.LastRouterReadyPath = $currentOriginalPath
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $start.StatePath -Encoding UTF8

$retryFile = Join-Path $retryPendingRoot 'target01__20260525_000000_000__message.ready.txt'
$currentDebugLogPath = Join-Path $tmpRoot 'focus-lost-debug.log'
'[test] text_pre_clear_focus_stolen_hard_fail activeTitle=OtherWindow' | Set-Content -LiteralPath $currentDebugLogPath -Encoding UTF8
[System.IO.File]::WriteAllText($retryFile, "payload`r`nRunRoot: $runRoot", (New-Utf8NoBomEncoding))
([ordered]@{
    FailureCategory = 'focus_lost'
    FailureMessage = 'active window changed before submit'
    DebugLogPath = $currentDebugLogPath
    FocusLostStage = 'pre-input'
    FocusLostRetryPolicy = 'bounded-auto-retry-exhausted'
    OperatorRetryHint = 'metadata hint: 입력 시작 전 포커스 이탈'
    OriginalPath = $currentOriginalPath
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($retryFile + '.meta.json') -Encoding UTF8
([ordered]@{
    TargetId = 'target01'
    LauncherSessionId = 'session-current'
    RunRoot = ''
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($retryFile + '.delivery.json') -Encoding UTF8

$staleInScopeRetryFile = Join-Path $retryPendingRoot 'target01__20260525_000000_500__same-run-stale-message.ready.txt'
[System.IO.File]::WriteAllText($staleInScopeRetryFile, "payload`r`nRunRoot: $runRoot", (New-Utf8NoBomEncoding))
([ordered]@{
    FailureCategory = 'focus_lost'
    FailureMessage = 'same run old focus lost'
    DebugLogPath = Join-Path $tmpRoot 'same-run-stale-focus-lost-debug.log'
    OriginalPath = Join-Path $tmpRoot 'inbox\target01\old-router.ready.txt'
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($staleInScopeRetryFile + '.meta.json') -Encoding UTF8
([ordered]@{
    TargetId = 'target01'
    LauncherSessionId = 'session-current'
    RunRoot = $runRoot
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($staleInScopeRetryFile + '.delivery.json') -Encoding UTF8

$staleRetryFile = Join-Path $retryPendingRoot 'target01__20260525_000001_000__stale-message.ready.txt'
[System.IO.File]::WriteAllText($staleRetryFile, 'payload from C:\tmp\old-target-autoloop-run', (New-Utf8NoBomEncoding))
([ordered]@{
    FailureCategory = 'focus_lost'
    FailureMessage = 'stale focus lost'
    DebugLogPath = Join-Path $tmpRoot 'stale-focus-lost-debug.log'
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($staleRetryFile + '.meta.json') -Encoding UTF8
([ordered]@{
    TargetId = 'target01'
    LauncherSessionId = 'session-current'
    RunRoot = 'C:\tmp\old-target-autoloop-run'
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($staleRetryFile + '.delivery.json') -Encoding UTF8

$statusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True (-not [bool]$statusJson.RouterSessionMismatch) 'retry-pending recommendation test requires router session to be ok.'
Assert-True ([int]$statusJson.RouterRetryPendingSummary.Count -eq 2) 'status json should count in-scope retry-pending ready files.'
Assert-True ([int]$statusJson.RouterRetryPendingSummary.CurrentCount -eq 1) 'status json should classify current retry-pending ready files.'
Assert-True ([int]$statusJson.RouterRetryPendingSummary.StaleCount -eq 1) 'status json should classify same-run stale retry-pending ready files.'
Assert-True ([int]$statusJson.RouterRetryPendingSummary.IgnoredOutOfScopeCount -eq 1) 'status json should ignore stale retry-pending files from another run root.'
Assert-True ([string]$statusJson.RouterRetryPendingSummary.LatestCurrentFailureCategory -eq 'focus_lost') 'status json should surface latest current retry-pending failure category.'
Assert-True ([string]$statusJson.RouterRetryPendingSummary.LatestCurrentFocusLostStage -eq 'pre-input') 'status json should classify pre-input focus_lost retry-pending.'
Assert-True ([string]$statusJson.RouterRetryPendingSummary.LatestCurrentFocusLostRetryPolicy -eq 'bounded-auto-retry-exhausted') 'status json should explain that safe focus_lost auto retry was already exhausted.'
Assert-True ([string]$statusJson.RouterRetryPendingSummary.LatestCurrentOperatorRetryHint -match 'metadata hint') 'status json should prefer metadata focus_lost operator retry hints.'
Assert-True ([string]$statusJson.RecommendationActionKey -eq 'requeue_retry_pending') 'status json should recommend retry-pending requeue.'
Assert-True ([string]$statusJson.RecommendationLabel -eq '현재 전송보류 재시도') 'status json should surface current retry-pending requeue label.'
Assert-True ([string]$statusJson.RecommendationDetail -match 'focus_lost') 'status json should explain latest retry-pending failure.'
Assert-True ([string]$statusJson.RecommendationDetail -match 'bounded-auto-retry-exhausted') 'status json should include the focus_lost retry policy.'

$output = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$joined = (@($output) -join "`n")

Assert-True ($joined -match 'RouterRetryPending: count=2 current=1 stale=1 targets=target01 currentTargets=target01') 'status text should surface retry-pending current/stale summary.'
Assert-True ($joined -match 'latestFocusPolicy=bounded-auto-retry-exhausted') 'status text should surface latest focus_lost retry policy.'
Assert-True ($joined -match 'RecommendationAction: requeue_retry_pending') 'status text should surface retry-pending action.'
Assert-True ($joined -match 'RecommendationLabel: 현재 전송보류 재시도') 'status text should surface retry-pending label.'
Assert-True ($joined -match 'retryPending=2') 'status text counts should include retry-pending count.'

Write-Host 'show target autoloop status retry-pending ok'
