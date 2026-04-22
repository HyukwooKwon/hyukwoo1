[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-router-user-active-hold'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot | Out-Null

$inboxRoot = Join-Path $testRoot 'inbox'
$processedRoot = Join-Path $testRoot 'processed'
$failedRoot = Join-Path $testRoot 'failed'
$retryPendingRoot = Join-Path $testRoot 'retry-pending'
$runtimeRoot = Join-Path $testRoot 'runtime'
$logsRoot = Join-Path $testRoot 'logs'

foreach ($path in @($inboxRoot, $processedRoot, $failedRoot, $retryPendingRoot, $runtimeRoot, $logsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$stubAhkPath = Join-Path $testRoot 'ExitUserActiveHold.ahk'
[System.IO.File]::WriteAllText($stubAhkPath, "#Requires AutoHotkey v2.0`r`nExitApp 43`r`n", (New-Utf8NoBomEncoding))

$targetBlocks = @()
foreach ($index in 1..8) {
    $targetId = 'target{0:D2}' -f $index
    $targetFolder = Join-Path $inboxRoot $targetId
    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null

    $targetBlocks += @"
        @{
            Id = '$targetId'
            WindowTitle = 'UserActiveHold-$targetId'
            Folder = '$($targetFolder.Replace("'", "''"))'
            EnterCount = 1
            FixedSuffix = `$null
        }
"@
}

$configPath = Join-Path $testRoot 'settings.user-active-hold.psd1'
$configText = @"
@{
    Root = '$($testRoot.Replace("'", "''"))'
    InboxRoot = '$($inboxRoot.Replace("'", "''"))'
    ProcessedRoot = '$($processedRoot.Replace("'", "''"))'
    FailedRoot = '$($failedRoot.Replace("'", "''"))'
    RetryPendingRoot = '$($retryPendingRoot.Replace("'", "''"))'
    RuntimeRoot = '$($runtimeRoot.Replace("'", "''"))'
    RuntimeMapPath = '$($(Join-Path $runtimeRoot 'target-runtime.json').Replace("'", "''"))'
    RouterStatePath = '$($(Join-Path $runtimeRoot 'router-state.json').Replace("'", "''"))'
    RouterMutexName = 'Global\RelayRouter_test_user_active_hold'
    LogsRoot = '$($logsRoot.Replace("'", "''"))'
    RouterLogPath = '$($(Join-Path $logsRoot 'router.log').Replace("'", "''"))'
    AhkExePath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    AhkScriptPath = '$($stubAhkPath.Replace("'", "''"))'
    ShellPath = 'pwsh.exe'
    ResolverShellPath = 'pwsh.exe'
    DefaultEnterCount = 1
    DefaultFixedSuffix = `$null
    MaxPayloadChars = 4000
    MaxPayloadBytes = 12000
    SweepIntervalMs = 250
    IdleSleepMs = 100
    RetryDelayMs = 250
    MaxRetryCount = 1
    SendTimeoutMs = 3000
    WindowLookupTimeoutMs = 1000
    RequireActiveBeforeEnter = `$true
    RequireUserIdleBeforeSend = `$true
    MinUserIdleBeforeSendMs = 2147483000
    Targets = @(
$($targetBlocks -join ",`r`n")
    )
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$runtimeSeed = foreach ($index in 1..8) {
    $targetId = 'target{0:D2}' -f $index
    [pscustomobject]@{
        TargetId          = $targetId
        ShellPid          = 0
        WindowPid         = 0
        Hwnd              = ''
        Title             = "UserActiveHold-$targetId"
        StartedAt         = (Get-Date).ToString('o')
        ShellPath         = 'pwsh.exe'
        Available         = $false
        ResolvedBy        = ''
        LookupSucceededAt = ''
        LauncherSessionId = 'user-active-hold-session'
        LaunchedAt        = (Get-Date).ToString('o')
        LauncherPid       = $PID
        ProcessName       = 'pwsh'
        WindowClass       = 'ConsoleWindowClass'
        HostKind          = 'test'
    }
}
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
[System.IO.File]::WriteAllText($runtimeMapPath, ($runtimeSeed | ConvertTo-Json -Depth 6), (New-Utf8NoBomEncoding))

& (Join-Path $root 'producer-example.ps1') -ConfigPath $configPath -TargetId 'target01' -Text 'user-active-hold smoke' | Out-Null

& (Join-Path $root 'router\Start-Router.ps1') -ConfigPath $configPath -RunDurationMs 1200

$retryFiles = @(Get-ChildItem -LiteralPath $retryPendingRoot -Filter 'target01__*.txt' -File -ErrorAction SilentlyContinue)
$retryMetaFiles = @(Get-ChildItem -LiteralPath $retryPendingRoot -Filter 'target01__*.txt.meta.json' -File -ErrorAction SilentlyContinue)
$failedFiles = @(Get-ChildItem -LiteralPath $failedRoot -Filter 'target01__*.txt' -File -ErrorAction SilentlyContinue)
$processedFiles = @(Get-ChildItem -LiteralPath $processedRoot -Filter 'target01__*.txt' -File -ErrorAction SilentlyContinue)

Assert-True ($retryFiles.Count -eq 1) 'user active hold should move the message to retry-pending.'
Assert-True ($retryMetaFiles.Count -eq 1) 'user active hold should write retry-pending metadata.'
Assert-True ($failedFiles.Count -eq 0) 'user active hold must not move the message to failed.'
Assert-True ($processedFiles.Count -eq 0) 'user active hold must not move the message to processed.'

$routerLogPath = Join-Path $logsRoot 'router.log'
$routerLog = [System.IO.File]::ReadAllText($routerLogPath, [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($routerLog -like '*category=user_active_hold*') 'router log should record user_active_hold category.'

Write-Host ('router user-active-hold ok: root=' + $testRoot)
