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
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopRouterBridge'
$routerInboxRoot = Join-Path $tmpRoot 'router-inbox\target01'
$configPath = Join-Path $tmpRoot 'settings.target-router-bridge.psd1'
$runRoot = Join-Path $tmpRoot 'run_target_router_bridge'
if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $routerInboxRoot -Force | Out-Null

[System.IO.File]::WriteAllText($configPath, @"
@{
    LaneName = 'bottest-live-visible'
    AhkExePath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    AhkScriptPath = 'C:\dev\python\hyukwoo\hyukwoo1\sender\SendToWindow.ahk'
    ResolverShellPath = 'powershell.exe'
    RuntimeMapPath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\target-runtime.json'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($routerInboxRoot.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-bridge' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-inbox-submit'
        DispatchQueuedCommandsInline = `$true
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$startJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target01 `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$inputPath = Join-Path $target01.InboxPendingRoot 'bridge_001.txt'
Set-Content -LiteralPath $inputPath -Encoding UTF8 -Value 'bridge body for router'

$watchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -DispatchQueuedCommandsInline `
    -ProcessOnce `
    -AsJson
$watch = $watchJson | ConvertFrom-Json
Assert-True ([int]$watch.QueuedCount -eq 1) 'router bridge flow should queue one command.'
Assert-True ([int]$watch.DispatchedCount -eq 1) 'router bridge flow should dispatch one command into a ready file.'

$readyFiles = @(Get-ChildItem -LiteralPath $routerInboxRoot -File -Filter '*.ready.txt' -ErrorAction SilentlyContinue | Sort-Object Name)
Assert-True (@($readyFiles).Count -eq 1) 'router inbox should contain one ready file after inline dispatch.'
$readyMetadataPath = ($readyFiles[0].FullName + '.delivery.json')
Assert-True ((Test-Path -LiteralPath $readyMetadataPath -PathType Leaf)) 'ready file delivery metadata should be created.'
$readyMetadata = Get-Content -LiteralPath $readyMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$readyMetadata.TargetId -eq 'target01') 'ready metadata target should be target01.'
Assert-True ([string]$readyMetadata.MessageType -eq 'generic') 'ready metadata should use generic message type for target-autoloop bridge.'

$state = Get-Content -LiteralPath $start.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetState = $state.Targets.target01
Assert-True ([string]$targetState.Phase -eq 'waiting-output') 'state should move to waiting-output after router ready file creation.'
Assert-True ([string]$targetState.LastDispatchState -eq 'router-ready-file-created') 'state should record router-ready-file-created dispatch state.'
Assert-True (([string]$targetState.LastRouterReadyPath).EndsWith('.ready.txt')) 'state should store the ready file path.'

$queueQueuedFiles = @(Get-ChildItem -LiteralPath $target01.QueueQueuedRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
$queueCompletedFiles = @(Get-ChildItem -LiteralPath $target01.QueueCompletedRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-True (@($queueQueuedFiles).Count -eq 0) 'queued commands should be consumed after inline router dispatch.'
Assert-True (@($queueCompletedFiles).Count -eq 1) 'completed queue archive should contain the processed command.'

$mismatchRoot = Join-Path $tmpRoot 'session-mismatch'
$mismatchRouterInboxRoot = Join-Path $mismatchRoot 'router-inbox\target01'
$mismatchConfigPath = Join-Path $mismatchRoot 'settings.target-router-session-mismatch.psd1'
$mismatchRunRoot = Join-Path $mismatchRoot 'run_target_router_session_mismatch'
$mismatchRuntimeMapPath = Join-Path $mismatchRoot 'runtime-map.json'
$mismatchRouterStatePath = Join-Path $mismatchRoot 'router-state.json'
New-Item -ItemType Directory -Path $mismatchRouterInboxRoot -Force | Out-Null
@(
    [ordered]@{
        TargetId = 'target01'
        LauncherSessionId = 'runtime-session-new'
    }
) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $mismatchRuntimeMapPath -Encoding UTF8
[ordered]@{
    Status = 'running'
    LauncherSessionId = 'router-session-old'
    RouterPid = 5678
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $mismatchRouterStatePath -Encoding UTF8
[System.IO.File]::WriteAllText($mismatchConfigPath, @"
@{
    LaneName = 'bottest-live-visible'
    AhkExePath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    AhkScriptPath = 'C:\dev\python\hyukwoo\hyukwoo1\sender\SendToWindow.ahk'
    ResolverShellPath = 'powershell.exe'
    RuntimeMapPath = '$($mismatchRuntimeMapPath.Replace("'", "''"))'
    RouterStatePath = '$($mismatchRouterStatePath.Replace("'", "''"))'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($mismatchRouterInboxRoot.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-bridge' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-inbox-submit'
        DispatchQueuedCommandsInline = `$true
        RunRootBase = '$($mismatchRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file') }
        )
    }
}
"@, (New-Utf8NoBomEncoding))

$mismatchStartJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $mismatchConfigPath `
    -RunRoot $mismatchRunRoot `
    -Targets target01 `
    -AsJson
$mismatchStart = $mismatchStartJson | ConvertFrom-Json
$mismatchManifest = Get-Content -LiteralPath $mismatchStart.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$mismatchTarget01 = @($mismatchManifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$mismatchInputPath = Join-Path $mismatchTarget01.InboxPendingRoot 'bridge_session_mismatch_001.txt'
Set-Content -LiteralPath $mismatchInputPath -Encoding UTF8 -Value 'bridge body blocked by router session mismatch'

$mismatchWatchJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $mismatchConfigPath `
    -RunRoot $mismatchRunRoot `
    -DispatchQueuedCommandsInline `
    -ProcessOnce `
    -AsJson
$mismatchWatch = $mismatchWatchJson | ConvertFrom-Json
Assert-True ([int]$mismatchWatch.QueuedCount -eq 1) 'session mismatch flow should still queue one command.'
Assert-True ([int]$mismatchWatch.DispatchedCount -eq 0) 'session mismatch flow must not create a router ready file.'
Assert-True (@(Get-ChildItem -LiteralPath $mismatchRouterInboxRoot -File -Filter '*.ready.txt' -ErrorAction SilentlyContinue).Count -eq 0) 'router inbox should remain empty when launcher sessions mismatch.'

$mismatchQueuedFiles = @(Get-ChildItem -LiteralPath $mismatchTarget01.QueueQueuedRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
$mismatchCompletedFiles = @(Get-ChildItem -LiteralPath $mismatchTarget01.QueueCompletedRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-True (@($mismatchQueuedFiles).Count -eq 1) 'session mismatch should leave the queued command retryable.'
Assert-True (@($mismatchCompletedFiles).Count -eq 0) 'session mismatch must not archive the command as completed.'

$mismatchState = Get-Content -LiteralPath $mismatchStart.StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$mismatchTargetState = $mismatchState.Targets.target01
Assert-True ([string]$mismatchTargetState.Phase -eq 'queued') 'session mismatch target should remain queued.'
Assert-True ([string]$mismatchTargetState.LastDispatchState -eq 'router-session-mismatch') 'session mismatch should be recorded in target state.'
Assert-True ([string]$mismatchTargetState.LastFailureReason -like '*LauncherSessionId*') 'session mismatch should explain the LauncherSessionId problem.'

Write-Host 'target autoloop router bridge ok'
