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
$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusRouterSession'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_status_router_session'
$runtimeRoot = Join-Path $tmpRoot 'runtime'
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
$routerStatePath = Join-Path $runtimeRoot 'router-state.json'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    RuntimeMapPath = '$($runtimeMapPath.Replace("'", "''"))'
    RouterStatePath = '$($routerStatePath.Replace("'", "''"))'
    RequireUserIdleBeforeSend = `$true
    MinUserIdleBeforeSendMs = 1000
    UserIdleWaitTimeoutMs = 15000
    UserIdleWaitPollMs = 250
    Targets = @(
        @{ Id = 'target01'; Folder = 'C:\tmp\target01'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
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
        LauncherSessionId = 'runtime-session-current'
        Available = $true
    }
) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeMapPath -Encoding UTF8

[ordered]@{
    Status = 'running'
    RouterPid = $PID
    LauncherSessionId = 'router-session-stale'
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

$statusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$statusJson.RouterSessionState -eq 'mismatch') 'status json should surface router session mismatch state.'
Assert-True ([bool]$statusJson.RouterSessionMismatch) 'status json should surface router session mismatch flag.'
Assert-True ([string]$statusJson.RouterLauncherSessionId -eq 'router-session-stale') 'status json should surface router launcher session id.'
Assert-True ([string]$statusJson.RuntimeLauncherSessionId -eq 'runtime-session-current') 'status json should surface runtime launcher session id.'
Assert-True ([string]$statusJson.RecommendationActionKey -eq 'restart_router_for_autoloop') 'status json should recommend router restart for session mismatch.'
Assert-True ([string]$statusJson.RecommendationLabel -eq 'router만 세션 맞추기') 'status json should surface router-only action label.'
Assert-True ([string]$statusJson.NextOperatorActionKey -eq 'restart_router_for_autoloop') 'status json should surface next operator action key.'
Assert-True ([string]$statusJson.NextOperatorActionLabel -eq 'router만 세션 맞추기') 'status json should surface next operator action label.'
Assert-True ([string]$statusJson.NextOperatorAction -eq 'router만 세션 맞추기 (restart_router_for_autoloop)') 'status json should surface next operator action summary.'
Assert-True ([string]$statusJson.RecommendationDetail -match 'router/runtime LauncherSessionId') 'status json should explain the router/runtime mismatch.'

$output = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$joined = (@($output) -join "`n")

Assert-True ($joined -match 'RouterSession: state=mismatch mismatch=True router=router-session-stale runtime=runtime-session-current') 'status text should surface router session mismatch summary.'
Assert-True ($joined -match 'RecommendationAction: restart_router_for_autoloop') 'status text should surface router restart action.'
Assert-True ($joined -match 'RecommendationLabel: router만 세션 맞추기') 'status text should surface router-only action label.'
Assert-True ($joined -match 'NextOperatorAction: router만 세션 맞추기 \(restart_router_for_autoloop\)') 'status text should surface next operator action.'

[ordered]@{
    Status = 'stopped'
    RouterPid = 4242
    LauncherSessionId = 'runtime-session-current'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $routerStatePath -Encoding UTF8

$notRunningJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$notRunningJson.RouterSessionState -eq 'router-not-running') 'status json should surface router-not-running state.'
Assert-True (-not [bool]$notRunningJson.RouterSessionMismatch) 'router-not-running should not be reported as a session mismatch.'
Assert-True ([string]$notRunningJson.RecommendationActionKey -eq 'restart_router_for_autoloop') 'status json should recommend router restart when router is not running.'
Assert-True ([string]$notRunningJson.RecommendationLabel -eq '8창 재사용+router 동기화') 'status json should surface sync action label when router is not running.'
Assert-True ([string]$notRunningJson.RecommendationDetail -match 'router-not-running') 'status json should explain the router-not-running state.'

[ordered]@{
    Status = 'running'
    RouterPid = 2147483647
    LauncherSessionId = 'runtime-session-current'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $routerStatePath -Encoding UTF8

$deadPidJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$deadPidJson.RouterSessionState -eq 'router-pid-not-running') 'status json should reject stale running router state when RouterPid is not alive.'
Assert-True (-not [bool]$deadPidJson.RouterPidExists) 'status json should surface that stale RouterPid is not alive.'
Assert-True ([string]$deadPidJson.RecommendationActionKey -eq 'restart_router_for_autoloop') 'status json should recommend router restart when router pid is stale.'
Assert-True ([string]$deadPidJson.RecommendationDetail -match 'router-pid-not-running') 'status json should explain the stale router pid state.'

[ordered]@{
    Status = 'running'
    RouterPid = $PID
    LauncherSessionId = 'runtime-session-current'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $routerStatePath -Encoding UTF8

$driftJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$driftJson.RouterSessionState -eq 'ok') 'router config drift test requires an otherwise ok router session.'
Assert-True ([bool]$driftJson.RouterConfigDrift) 'status json should detect router config drift when effective send settings are missing.'
Assert-True ([string]$driftJson.RecommendationActionKey -eq 'restart_router_for_autoloop') 'status json should recommend router restart for config drift.'
Assert-True ([string]$driftJson.RecommendationLabel -eq 'router 설정 재시작') 'status json should surface router config restart label.'
Assert-True ([string]$driftJson.RecommendationDetail -match 'router-state-missing-effective-send-settings') 'status json should explain router config drift.'

Write-Host 'show target autoloop status router session ok'
