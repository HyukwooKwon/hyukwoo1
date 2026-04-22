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
$testRoot = Join-Path $root '_tmp\test-router-ignore-launcher-session-mismatch'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot | Out-Null

$inboxRoot = Join-Path $testRoot 'inbox'
$processedRoot = Join-Path $testRoot 'processed'
$failedRoot = Join-Path $testRoot 'failed'
$ignoredRoot = Join-Path $testRoot 'ignored'
$retryPendingRoot = Join-Path $testRoot 'retry-pending'
$runtimeRoot = Join-Path $testRoot 'runtime'
$logsRoot = Join-Path $testRoot 'logs'

foreach ($path in @($inboxRoot, $processedRoot, $failedRoot, $ignoredRoot, $retryPendingRoot, $runtimeRoot, $logsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$stubAhkPath = Join-Path $testRoot 'ShouldNotRun.ahk'
[System.IO.File]::WriteAllText($stubAhkPath, "#Requires AutoHotkey v2.0`r`nExitApp 0`r`n", (New-Utf8NoBomEncoding))

$targetBlocks = @()
foreach ($index in 1..8) {
    $targetId = 'target{0:D2}' -f $index
    $targetFolder = Join-Path $inboxRoot $targetId
    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null

    $targetBlocks += @"
        @{
            Id = '$targetId'
            WindowTitle = 'IgnoreLauncherSession-$targetId'
            Folder = '$($targetFolder.Replace("'", "''"))'
            EnterCount = 1
            FixedSuffix = `$null
        }
"@
}

$configPath = Join-Path $testRoot 'settings.ignore-launcher-session.psd1'
$configText = @"
@{
    Root = '$($testRoot.Replace("'", "''"))'
    InboxRoot = '$($inboxRoot.Replace("'", "''"))'
    ProcessedRoot = '$($processedRoot.Replace("'", "''"))'
    FailedRoot = '$($failedRoot.Replace("'", "''"))'
    IgnoredRoot = '$($ignoredRoot.Replace("'", "''"))'
    RetryPendingRoot = '$($retryPendingRoot.Replace("'", "''"))'
    RuntimeRoot = '$($runtimeRoot.Replace("'", "''"))'
    RuntimeMapPath = '$($(Join-Path $runtimeRoot 'target-runtime.json').Replace("'", "''"))'
    RouterStatePath = '$($(Join-Path $runtimeRoot 'router-state.json').Replace("'", "''"))'
    RouterMutexName = 'Global\RelayRouter_test_ignore_launcher_session_mismatch'
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
        Title             = "IgnoreLauncherSession-$targetId"
        StartedAt         = (Get-Date).ToString('o')
        ShellPath         = 'pwsh.exe'
        Available         = $false
        ResolvedBy        = ''
        LookupSucceededAt = ''
        LauncherSessionId = 'session-match'
        LaunchedAt        = (Get-Date).ToString('o')
        LauncherPid       = $PID
        ProcessName       = 'pwsh'
        WindowClass       = 'ConsoleWindowClass'
        HostKind          = 'test'
    }
}
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
[System.IO.File]::WriteAllText($runtimeMapPath, ($runtimeSeed | ConvertTo-Json -Depth 6), (New-Utf8NoBomEncoding))

& (Join-Path $root 'producer-example.ps1') -ConfigPath $configPath -TargetId 'target01' -Text 'ignore-launcher-session mismatch smoke' | Out-Null
$readyFile = @(Get-ChildItem -LiteralPath (Join-Path $inboxRoot 'target01') -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
Assert-True ($null -ne $readyFile) 'producer should create one ready file before router startup.'

$deliveryMetadataPath = ($readyFile.FullName + '.delivery.json')
Assert-True (Test-Path -LiteralPath $deliveryMetadataPath -PathType Leaf) 'producer should create ready delivery metadata.'

$deliveryMetadata = Get-Content -LiteralPath $deliveryMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$deliveryMetadata.LauncherSessionId -eq 'session-match') 'producer should stamp the current launcher session into ready metadata.'
$deliveryMetadata.LauncherSessionId = 'session-other'
$deliveryMetadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $deliveryMetadataPath -Encoding UTF8

& (Join-Path $root 'router\Start-Router.ps1') -ConfigPath $configPath -RunDurationMs 1200

$ignoredFiles = @(Get-ChildItem -LiteralPath $ignoredRoot -Filter 'target01__*.ready.txt' -File -ErrorAction SilentlyContinue)
$ignoredArchiveMetadataFiles = @(Get-ChildItem -LiteralPath $ignoredRoot -Filter 'target01__*.ready.txt.archive.json' -File -ErrorAction SilentlyContinue)
$processedFiles = @(Get-ChildItem -LiteralPath $processedRoot -Filter 'target01__*.ready.txt' -File -ErrorAction SilentlyContinue)
$failedFiles = @(Get-ChildItem -LiteralPath $failedRoot -Filter 'target01__*.ready.txt' -File -ErrorAction SilentlyContinue)
$retryFiles = @(Get-ChildItem -LiteralPath $retryPendingRoot -Filter 'target01__*.ready.txt' -File -ErrorAction SilentlyContinue)

Assert-True ($ignoredFiles.Count -eq 1) 'session mismatch ready file should move to ignored.'
Assert-True ($ignoredArchiveMetadataFiles.Count -eq 1) 'ignored archive metadata should be recorded for launcher session mismatch.'
Assert-True ($processedFiles.Count -eq 0) 'session mismatch ready file must not be processed.'
Assert-True ($failedFiles.Count -eq 0) 'session mismatch ready file must not be treated as failed.'
Assert-True ($retryFiles.Count -eq 0) 'session mismatch ready file must not be retried.'

$ignoredArchiveMetadata = Get-Content -LiteralPath $ignoredArchiveMetadataFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$ignoredArchiveMetadata.ArchiveState -eq 'ignored') 'ignored archive metadata should record the ignored archive state.'
Assert-True ([string]$ignoredArchiveMetadata.ArchiveReasonCode -eq 'launcher-session-mismatch') 'ignored archive metadata should record the launcher session mismatch reason.'

$routerLogPath = Join-Path $logsRoot 'router.log'
$routerLog = [System.IO.File]::ReadAllText($routerLogPath, [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($routerLog -like '*launcher-session-mismatch*') 'router log should record the launcher session mismatch reason.'

$statusJson = & (Join-Path $root 'show-relay-status.ps1') -ConfigPath $configPath -RecentCount 2 -AsJson
$status = $statusJson | ConvertFrom-Json
Assert-True ([int]$status.Counts.Ignored -ge 1) 'show-relay-status should report ignored files for launcher session mismatch.'
Assert-True (@($status.IgnoredReasonCounts | Where-Object { [string]$_.Code -eq 'launcher-session-mismatch' -and [int]$_.Count -ge 1 }).Count -eq 1) 'show-relay-status should aggregate launcher session mismatch ignored reasons.'
Assert-True (@($status.Recent.Ignored | Where-Object { [string]$_.ReasonCode -eq 'launcher-session-mismatch' }).Count -eq 1) 'show-relay-status recent ignored rows should include launcher session mismatch.'

Write-Host ('router ignore-launcher-session mismatch ok: root=' + $testRoot)
