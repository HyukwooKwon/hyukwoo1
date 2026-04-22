[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\router\RelayMessageMetadata.ps1')

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
$testRoot = Join-Path $root '_tmp\test-router-require-pair-transport-metadata'
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
$messageRoot = Join-Path $testRoot 'messages'

foreach ($path in @($inboxRoot, $processedRoot, $failedRoot, $ignoredRoot, $retryPendingRoot, $runtimeRoot, $logsRoot, $messageRoot)) {
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
            WindowTitle = 'RequirePairMetadata-$targetId'
            Folder = '$($targetFolder.Replace("'", "''"))'
            EnterCount = 1
            FixedSuffix = `$null
        }
"@
}

$configPath = Join-Path $testRoot 'settings.require-pair-metadata.psd1'
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
    RouterMutexName = 'Global\RelayRouter_test_require_pair_transport_metadata'
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
    RequireReadyDeliveryMetadata = `$true
    RequirePairTransportMetadata = `$true
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
        Title             = "RequirePairMetadata-$targetId"
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

$messagePath = Join-Path $messageRoot 'target01.txt'
[System.IO.File]::WriteAllText($messagePath, "pair metadata contract smoke", (New-Utf8NoBomEncoding))
$messageMetadata = New-PairedRelayMessageMetadata `
    -RunRoot (Join-Path $testRoot 'run_20260422_000000') `
    -PairId 'pair01' `
    -TargetId 'target01' `
    -PartnerTargetId 'target05' `
    -RoleName 'top' `
    -InitialRoleMode 'seed' `
    -MessageType 'pair-seed' `
    -MessagePath $messagePath `
    -LauncherSessionId 'session-match'
Write-RelayMessageMetadata -MessagePath $messagePath -Metadata $messageMetadata | Out-Null

& (Join-Path $root 'producer-example.ps1') -ConfigPath $configPath -TargetId 'target01' -TextFilePath $messagePath | Out-Null
$readyFile = @(Get-ChildItem -LiteralPath (Join-Path $inboxRoot 'target01') -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
Assert-True ($null -ne $readyFile) 'producer should create one ready file before router startup.'

$deliveryMetadataPath = ($readyFile.FullName + '.delivery.json')
Assert-True (Test-Path -LiteralPath $deliveryMetadataPath -PathType Leaf) 'producer should create ready delivery metadata.'

$deliveryMetadata = Get-Content -LiteralPath $deliveryMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$deliveryMetadata.MessageType -eq 'pair-seed') 'ready metadata should preserve the pair message type.'
$deliveryMetadata.PairId = ''
$deliveryMetadata.RunId = ''
$deliveryMetadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $deliveryMetadataPath -Encoding UTF8

& (Join-Path $root 'router\Start-Router.ps1') -ConfigPath $configPath -RunDurationMs 1200

$ignoredFiles = @(Get-ChildItem -LiteralPath $ignoredRoot -Filter 'target01__*.ready.txt' -File -ErrorAction SilentlyContinue)
$ignoredArchiveMetadataFiles = @(Get-ChildItem -LiteralPath $ignoredRoot -Filter 'target01__*.ready.txt.archive.json' -File -ErrorAction SilentlyContinue)
$processedFiles = @(Get-ChildItem -LiteralPath $processedRoot -Filter 'target01__*.ready.txt' -File -ErrorAction SilentlyContinue)
$failedFiles = @(Get-ChildItem -LiteralPath $failedRoot -Filter 'target01__*.ready.txt' -File -ErrorAction SilentlyContinue)
$retryFiles = @(Get-ChildItem -LiteralPath $retryPendingRoot -Filter 'target01__*.ready.txt' -File -ErrorAction SilentlyContinue)

Assert-True ($ignoredFiles.Count -eq 1) 'pair transport ready file with missing required metadata should move to ignored.'
Assert-True ($ignoredArchiveMetadataFiles.Count -eq 1) 'ignored archive metadata should be recorded for pair transport contract violations.'
Assert-True ($processedFiles.Count -eq 0) 'pair transport ready file with missing required metadata must not be processed.'
Assert-True ($failedFiles.Count -eq 0) 'pair transport ready file with missing required metadata must not be treated as failed.'
Assert-True ($retryFiles.Count -eq 0) 'pair transport ready file with missing required metadata must not be retried.'

$ignoredArchiveMetadata = Get-Content -LiteralPath $ignoredArchiveMetadataFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$ignoredArchiveMetadata.ArchiveState -eq 'ignored') 'ignored archive metadata should record the ignored archive state.'
Assert-True ([string]$ignoredArchiveMetadata.ArchiveReasonCode -eq 'paired-metadata-missing-fields') 'ignored archive metadata should record the pair transport contract reason.'
Assert-True ([string]$ignoredArchiveMetadata.ArchiveReasonDetail -like '*PairId*') 'pair transport contract reason detail should mention PairId.'
Assert-True ([string]$ignoredArchiveMetadata.ArchiveReasonDetail -like '*RunId*') 'pair transport contract reason detail should mention RunId.'

$routerLogPath = Join-Path $logsRoot 'router.log'
$routerLog = [System.IO.File]::ReadAllText($routerLogPath, [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($routerLog -like '*paired-metadata-missing-fields*') 'router log should record the pair transport contract reason.'

$statusJson = & (Join-Path $root 'show-relay-status.ps1') -ConfigPath $configPath -RecentCount 2 -AsJson
$status = $statusJson | ConvertFrom-Json
Assert-True ([bool]$status.Router.RequireReadyDeliveryMetadata) 'show-relay-status should surface the ready delivery metadata contract flag.'
Assert-True ([bool]$status.Router.RequirePairTransportMetadata) 'show-relay-status should surface the pair transport metadata contract flag.'
Assert-True (@($status.IgnoredReasonCounts | Where-Object { [string]$_.Code -eq 'paired-metadata-missing-fields' -and [int]$_.Count -ge 1 }).Count -eq 1) 'show-relay-status should aggregate pair transport metadata contract violations.'
Assert-True (@($status.Recent.Ignored | Where-Object { [string]$_.ReasonCode -eq 'paired-metadata-missing-fields' }).Count -eq 1) 'show-relay-status recent ignored rows should include the pair transport contract reason.'

Write-Host ('router require-pair-transport-metadata ok: root=' + $testRoot)
