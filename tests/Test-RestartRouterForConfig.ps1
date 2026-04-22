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

function Resolve-PowerShellExecutable {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }

        if ($command.Source) {
            return [string]$command.Source
        }
        if ($command.Path) {
            return [string]$command.Path
        }

        return [string]$name
    }

    throw 'pwsh.exe 또는 powershell.exe를 찾지 못했습니다.'
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-restart-router-for-config'
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

$stubAhkPath = Join-Path $testRoot 'ExitSuccess.ahk'
[System.IO.File]::WriteAllText($stubAhkPath, "#Requires AutoHotkey v2.0`r`nExitApp 0`r`n", (New-Utf8NoBomEncoding))

$targetBlocks = @()
foreach ($index in 1..8) {
    $targetId = 'target{0:D2}' -f $index
    $targetFolder = Join-Path $inboxRoot $targetId
    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null

    $targetBlocks += @"
        @{
            Id = '$targetId'
            WindowTitle = 'RestartRouter-$targetId'
            Folder = '$($targetFolder.Replace("'", "''"))'
            EnterCount = 1
            FixedSuffix = `$null
        }
"@
}

$configPath = Join-Path $testRoot 'settings.restart-router.psd1'
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
    RouterMutexName = 'Global\RelayRouter_test_restart_router_for_config'
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
    RequireUserIdleBeforeSend = `$false
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
        Title             = "RestartRouter-$targetId"
        StartedAt         = (Get-Date).ToString('o')
        ShellPath         = 'pwsh.exe'
        Available         = $false
        ResolvedBy        = ''
        LookupSucceededAt = ''
        LauncherSessionId = 'restart-router-session'
        LaunchedAt        = (Get-Date).ToString('o')
        LauncherPid       = $PID
        ProcessName       = 'pwsh'
        WindowClass       = 'ConsoleWindowClass'
        HostKind          = 'test'
    }
}
[System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'target-runtime.json'), ($runtimeSeed | ConvertTo-Json -Depth 6), (New-Utf8NoBomEncoding))

$powershellPath = Resolve-PowerShellExecutable
$initialRouter = Start-Process -FilePath $powershellPath -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'router.ps1'),
    '-ConfigPath', $configPath,
    '-RunDurationMs', '30000'
) -PassThru -WindowStyle Hidden

$restart = $null
try {
    $deadline = (Get-Date).AddSeconds(10)
    $mutexHeld = $false
    while ((Get-Date) -lt $deadline) {
        $relayStatusRaw = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' (Join-Path $root 'show-relay-status.ps1') '-ConfigPath' $configPath '-AsJson'
        $relayStatus = $relayStatusRaw | ConvertFrom-Json
        if ([bool]$relayStatus.Router.MutexHeld) {
            $mutexHeld = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }

    Assert-True $mutexHeld 'initial router should acquire mutex before restart helper runs.'

    $restartRaw = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' (Join-Path $root 'router\Restart-RouterForConfig.ps1') '-ConfigPath' $configPath '-RunDurationMs' '30000' '-AsJson'
    $restart = $restartRaw | ConvertFrom-Json

    Assert-True (@($restart.MatchedProcessIds).Count -ge 1) 'restart helper should find existing router processes.'
    Assert-True (@($restart.StoppedProcessIds).Count -ge 1) 'restart helper should stop existing router processes.'
    Assert-True ([int]$restart.StartedProcessId -gt 0) 'restart helper should start a fresh router launcher process.'
    Assert-True ([int]$restart.EffectiveRouterPid -gt 0) 'restart helper should report the effective router pid.'
    Assert-True ([bool]$restart.MutexHeld) 'restart helper should return with router mutex held.'
}
finally {
    $startedRouterPid = if ($null -ne $restart) { [int]$restart.StartedProcessId } else { 0 }
    $effectiveRouterPid = if ($null -ne $restart) { [int]$restart.EffectiveRouterPid } else { 0 }
    foreach ($processId in @($initialRouter.Id, $startedRouterPid, $effectiveRouterPid)) {
        if ($processId -gt 0) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host ('restart-router-for-config ok: root=' + $testRoot)
