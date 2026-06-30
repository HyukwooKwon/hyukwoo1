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

function Invoke-FocusLostScenario {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$StubAhkText,
        [Parameter(Mandatory)][bool]$ExpectAutomaticRetry,
        [Parameter(Mandatory)][int]$ExpectedRetryAttempt,
        [Parameter(Mandatory)][string]$ExpectedFocusLostStage,
        [Parameter(Mandatory)][string]$ExpectedFocusLostRetryPolicy
    )

    $scenarioRoot = Join-Path $script:testRoot $Name
    New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null

    $inboxRoot = Join-Path $scenarioRoot 'inbox'
    $processedRoot = Join-Path $scenarioRoot 'processed'
    $failedRoot = Join-Path $scenarioRoot 'failed'
    $retryPendingRoot = Join-Path $scenarioRoot 'retry-pending'
    $runtimeRoot = Join-Path $scenarioRoot 'runtime'
    $logsRoot = Join-Path $scenarioRoot 'logs'

    foreach ($path in @($inboxRoot, $processedRoot, $failedRoot, $retryPendingRoot, $runtimeRoot, $logsRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $stubAhkPath = Join-Path $scenarioRoot 'ExitFocusLost.ahk'
    [System.IO.File]::WriteAllText($stubAhkPath, $StubAhkText, (New-Utf8NoBomEncoding))

    $targetBlocks = @()
    foreach ($index in 1..8) {
        $targetId = 'target{0:D2}' -f $index
        $targetFolder = Join-Path $inboxRoot $targetId
        New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null

        $targetBlocks += @"
        @{
            Id = '$targetId'
            WindowTitle = 'FocusLost-$Name-$targetId'
            Folder = '$($targetFolder.Replace("'", "''"))'
            EnterCount = 1
            FixedSuffix = `$null
        }
"@
    }

    $configPath = Join-Path $scenarioRoot 'settings.focus-lost.psd1'
    $configText = @"
@{
    Root = '$($scenarioRoot.Replace("'", "''"))'
    InboxRoot = '$($inboxRoot.Replace("'", "''"))'
    ProcessedRoot = '$($processedRoot.Replace("'", "''"))'
    FailedRoot = '$($failedRoot.Replace("'", "''"))'
    RetryPendingRoot = '$($retryPendingRoot.Replace("'", "''"))'
    RuntimeRoot = '$($runtimeRoot.Replace("'", "''"))'
    RuntimeMapPath = '$($(Join-Path $runtimeRoot 'target-runtime.json').Replace("'", "''"))'
    RouterStatePath = '$($(Join-Path $runtimeRoot 'router-state.json').Replace("'", "''"))'
    RouterMutexName = 'Global\RelayRouter_test_focus_lost_$Name'
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
    VisibleExecutionFailOnFocusSteal = `$true
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
            Title             = "FocusLost-$Name-$targetId"
            StartedAt         = (Get-Date).ToString('o')
            ShellPath         = 'pwsh.exe'
            Available         = $false
            ResolvedBy        = ''
            LookupSucceededAt = ''
            LauncherSessionId = "focus-lost-$Name-session"
            LaunchedAt        = (Get-Date).ToString('o')
            LauncherPid       = $PID
            ProcessName       = 'pwsh'
            WindowClass       = 'ConsoleWindowClass'
            HostKind          = 'test'
        }
    }
    $runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
    [System.IO.File]::WriteAllText($runtimeMapPath, ($runtimeSeed | ConvertTo-Json -Depth 6), (New-Utf8NoBomEncoding))

    & (Join-Path $script:root 'producer-example.ps1') -ConfigPath $configPath -TargetId 'target01' -Text "focus lost $Name smoke" | Out-Null
    & (Join-Path $script:root 'router\Start-Router.ps1') -ConfigPath $configPath -RunDurationMs 1800

    $retryFiles = @(Get-ChildItem -LiteralPath $retryPendingRoot -Filter 'target01__*.txt' -File -ErrorAction SilentlyContinue)
    $retryMetaFiles = @(Get-ChildItem -LiteralPath $retryPendingRoot -Filter 'target01__*.txt.meta.json' -File -ErrorAction SilentlyContinue)
    $failedFiles = @(Get-ChildItem -LiteralPath $failedRoot -Filter 'target01__*.txt' -File -ErrorAction SilentlyContinue)
    $processedFiles = @(Get-ChildItem -LiteralPath $processedRoot -Filter 'target01__*.txt' -File -ErrorAction SilentlyContinue)

    Assert-True ($retryFiles.Count -eq 1) "$Name should move the message to retry-pending."
    Assert-True ($retryMetaFiles.Count -eq 1) "$Name should write retry-pending metadata."
    Assert-True ($failedFiles.Count -eq 0) "$Name must not move the message to failed."
    Assert-True ($processedFiles.Count -eq 0) "$Name must not move the message to processed."

    $routerLogPath = Join-Path $logsRoot 'router.log'
    $routerLog = [System.IO.File]::ReadAllText($routerLogPath, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-True ($routerLog -like '*category=focus_lost*') "$Name router log should record focus_lost category."
    Assert-True ($routerLog -like '*processing attempt=1/2*') "$Name router log should record the first bounded attempt."

    if ($ExpectAutomaticRetry) {
        Assert-True ($routerLog -like '*processing attempt=2/2*') "$Name should retry once when focus is lost before payload input starts."
    }
    else {
        Assert-True ($routerLog -notlike '*processing attempt=2/2*') "$Name must not retry once payload or submit has started."
    }

    $retryMetadata = Get-Content -LiteralPath $retryMetaFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$retryMetadata.FailureCategory -eq 'focus_lost') "$Name retry-pending metadata should preserve focus_lost category."
    Assert-True ([int]$retryMetadata.Attempt -eq $ExpectedRetryAttempt) "$Name retry-pending metadata should record the final bounded attempt."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$retryMetadata.DebugLogPath)) "$Name retry-pending metadata should preserve the AHK debug log path."
    Assert-True ([string]$retryMetadata.FocusLostStage -eq $ExpectedFocusLostStage) "$Name retry-pending metadata should record the focus_lost stage."
    Assert-True ([string]$retryMetadata.FocusLostRetryPolicy -eq $ExpectedFocusLostRetryPolicy) "$Name retry-pending metadata should record the focus_lost retry policy."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$retryMetadata.OperatorRetryHint)) "$Name retry-pending metadata should record the operator retry hint."

    $debugLogRoot = Join-Path $logsRoot 'ahk-debug\target01'
    $debugLogs = @(Get-ChildItem -LiteralPath $debugLogRoot -Filter '*.log' -File -ErrorAction SilentlyContinue)
    $expectedDebugLogCount = if ($ExpectAutomaticRetry) { 2 } else { 1 }
    Assert-True ($debugLogs.Count -eq $expectedDebugLogCount) "$Name should create the expected number of AHK debug logs."

    return [pscustomobject]@{
        Name = $Name
        Root = $scenarioRoot
        DebugLogCount = $debugLogs.Count
        RetryAttempt = [int]$retryMetadata.Attempt
    }
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-router-focus-lost-pre-input-retry'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$preInputStub = @'
#Requires AutoHotkey v2.0
debugLog := ""
Loop A_Args.Length {
    if (A_Args[A_Index] = "--debugLog" && A_Index < A_Args.Length) {
        debugLog := A_Args[A_Index + 1]
    }
}
if (debugLog != "") {
    SplitPath debugLog,, &dir
    if (dir != "") {
        DirCreate dir
    }
    FileAppend "[test] text_pre_clear_focus_stolen_hard_fail activeTitle=BlueStacks App Player`n", debugLog, "UTF-8"
}
ExitApp 42
'@

$submitStageStub = @'
#Requires AutoHotkey v2.0
debugLog := ""
Loop A_Args.Length {
    if (A_Args[A_Index] = "--debugLog" && A_Index < A_Args.Length) {
        debugLog := A_Args[A_Index + 1]
    }
}
if (debugLog != "") {
    SplitPath debugLog,, &dir
    if (dir != "") {
        DirCreate dir
    }
    FileAppend "[test] terminal_input_mode mode=paste`n[test] terminal_paste bytes=42`n[test] submit_precheck mode=enter index=1/1`n[test] submit mode=enter index=1/1_focus_stolen_hard_fail`n", debugLog, "UTF-8"
}
ExitApp 42
'@

$preInputResult = Invoke-FocusLostScenario -Name 'pre-input' -StubAhkText $preInputStub -ExpectAutomaticRetry $true -ExpectedRetryAttempt 2 -ExpectedFocusLostStage 'pre-input' -ExpectedFocusLostRetryPolicy 'bounded-auto-retry-exhausted'
$submitStageResult = Invoke-FocusLostScenario -Name 'submit-stage' -StubAhkText $submitStageStub -ExpectAutomaticRetry $false -ExpectedRetryAttempt 1 -ExpectedFocusLostStage 'submit-ready-no-dispatch' -ExpectedFocusLostRetryPolicy 'manual-submit-only-retry'

Write-Host ('router focus-lost pre-input retry ok: preInput={0} submitStage={1}' -f $preInputResult.Root, $submitStageResult.Root)
