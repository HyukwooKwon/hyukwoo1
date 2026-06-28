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
$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopStatusRouterInboxReady'
$configPath = Join-Path $tmpRoot 'settings.target-autoloop.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_status_router_inbox_ready'
$runtimeRoot = Join-Path $tmpRoot 'runtime'
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
$routerStatePath = Join-Path $runtimeRoot 'router-state.json'
$routerInboxTarget = Join-Path $tmpRoot 'router-inbox\target01'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
New-Item -ItemType Directory -Path $routerInboxTarget -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    RuntimeMapPath = '$($runtimeMapPath.Replace("'", "''"))'
    RouterStatePath = '$($routerStatePath.Replace("'", "''"))'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($routerInboxTarget.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-01' }
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

$readyFile = Join-Path $routerInboxTarget 'message_20260618_180000_000__stale.ready.txt'
[System.IO.File]::WriteAllText($readyFile, 'payload waiting in router inbox', (New-Utf8NoBomEncoding))
([ordered]@{
    SchemaVersion = '1.0.0'
    Kind = 'relay-ready'
    CreatedAt = '2026-06-18T18:00:00.0000000+09:00'
    TargetId = 'target01'
    MessageType = 'generic'
    LauncherSessionId = 'session-current'
} | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath ($readyFile + '.delivery.json') -Encoding UTF8

$statusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json

Assert-True (-not [bool]$statusJson.RouterSessionMismatch) 'router inbox ready test requires router session to be ok.'
Assert-True ([string]$statusJson.RouterSessionState -eq 'ok') 'router inbox ready test requires router session ok.'
Assert-True ([int]$statusJson.RouterInboxReadySummary.Count -eq 1) 'status json should count router inbox ready files.'
Assert-True ([string]$statusJson.RouterInboxReadySummary.LatestTargetId -eq 'target01') 'status json should surface latest router inbox target.'
Assert-True ([string]$statusJson.RouterInboxReadySummary.LatestLauncherSessionId -eq 'session-current') 'status json should surface latest router inbox launcher session.'
Assert-True ([string]$statusJson.RouterInboxReadySummary.LatestCreatedAt -match '2026') 'status json should surface latest router inbox ready created year.'
Assert-True ([string]$statusJson.RouterInboxReadySummary.LatestCreatedAt -match '18:00') 'status json should surface latest router inbox ready created time.'
Assert-True ([string]$statusJson.RouterInboxReadySummary.LatestPath -eq $readyFile) 'status json should surface latest router inbox ready path.'

$output = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopStatus.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot
$joined = (@($output) -join "`n")

Assert-True ($joined -match 'RouterInboxReady: count=1 targets=target01') 'status text should surface router inbox ready summary.'
Assert-True ($joined -match 'routerInboxReady=1') 'status text counts should include router inbox ready count.'

Write-Host 'show target autoloop status router inbox ready ok'
