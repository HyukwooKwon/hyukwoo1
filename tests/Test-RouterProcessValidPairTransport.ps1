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

function Assert-IsoTimestampString {
    param(
        [string]$Value,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T') {
        throw $Message
    }

    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($Value, [ref]$parsed)) {
        throw $Message
    }
}

function Get-JsonStringField {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$FieldName
    )

    $match = [regex]::Match($Json, ('"' + [regex]::Escape($FieldName) + '"\s*:\s*"([^"]+)"'))
    if ($match.Success) {
        return [string]$match.Groups[1].Value
    }

    return ''
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

function Wait-ForRouterRunning {
    param(
        [Parameter(Mandatory)][string]$RouterStatePath,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastStatus = ''

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $RouterStatePath -PathType Leaf) {
            $raw = Get-Content -LiteralPath $RouterStatePath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $state = ConvertFrom-RelayJsonText -Json $raw
                $lastStatus = [string]$state.Status
                if ($lastStatus -eq 'running' -and -not [string]::IsNullOrWhiteSpace([string]$state.RouterStartedAt)) {
                    return $state
                }
            }
        }

        Start-Sleep -Milliseconds 200
    }

    throw "router running timeout: statePath=$RouterStatePath lastStatus=$lastStatus"
}

function Wait-ForArchivedMessage {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$BaseName,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $matches = @(
            Get-ChildItem -LiteralPath $Root -Filter ('*' + $BaseName) -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending
        )

        if ($matches.Count -gt 0) {
            return $matches[0]
        }

        Start-Sleep -Milliseconds 200
    }

    throw "archived message timeout: root=$Root baseName=$BaseName"
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'router\RelayMessageMetadata.ps1')
$testRoot = Join-Path $root '_tmp\test-router-process-valid-pair-transport'
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

$stubAhkPath = Join-Path $testRoot 'AlwaysSuccess.ahk'
[System.IO.File]::WriteAllText($stubAhkPath, "#Requires AutoHotkey v2.0`r`nExitApp 0`r`n", (New-Utf8NoBomEncoding))

$targetBlocks = @()
foreach ($index in 1..8) {
    $targetId = 'target{0:D2}' -f $index
    $targetFolder = Join-Path $inboxRoot $targetId
    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null

    $targetBlocks += @"
        @{
            Id = '$targetId'
            WindowTitle = 'ProcessValidPair-$targetId'
            Folder = '$($targetFolder.Replace("'", "''"))'
            EnterCount = 1
            FixedSuffix = `$null
        }
"@
}

$configPath = Join-Path $testRoot 'settings.process-valid-pair.psd1'
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
    RouterMutexName = 'Global\RelayRouter_test_process_valid_pair_transport'
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
    SweepIntervalMs = 200
    IdleSleepMs = 100
    RetryDelayMs = 250
    MaxRetryCount = 1
    SendTimeoutMs = 3000
    WindowLookupTimeoutMs = 1000
    IgnorePreexistingReadyFiles = `$true
    PreexistingHandlingMode = 'ignore-archive'
    RequireReadyDeliveryMetadata = `$true
    RequirePairTransportMetadata = `$true
    Targets = @(
$($targetBlocks -join ",`r`n")
    )
    PairTest = @{
        RunRootBase = '$($testRoot.Replace("'", "''"))'
    }
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
        Title             = "ProcessValidPair-$targetId"
        StartedAt         = (Get-Date).ToString('o')
        ShellPath         = 'pwsh.exe'
        Available         = $false
        ResolvedBy        = ''
        LookupSucceededAt = ''
        LauncherSessionId = 'process-valid-pair-session'
        LaunchedAt        = (Get-Date).ToString('o')
        LauncherPid       = $PID
        ProcessName       = 'pwsh'
        WindowClass       = 'ConsoleWindowClass'
        HostKind          = 'test'
    }
}
$runtimeMapPath = Join-Path $runtimeRoot 'target-runtime.json'
[System.IO.File]::WriteAllText($runtimeMapPath, ($runtimeSeed | ConvertTo-Json -Depth 6), (New-Utf8NoBomEncoding))

$runRoot = Join-Path $testRoot 'run'
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -InitialTargetId target01 | Out-Null

$messagePath = Join-Path $runRoot 'messages\target01.txt'
$messageMetadataPath = ($messagePath + '.relay.json')
Assert-True (Test-Path -LiteralPath $messagePath -PathType Leaf) 'prepared pair message should exist.'
Assert-True (Test-Path -LiteralPath $messageMetadataPath -PathType Leaf) 'prepared pair source metadata should exist.'

$powershellPath = Resolve-PowerShellExecutable
$routerStdoutLog = Join-Path $logsRoot 'router-process-valid.stdout.log'
$routerStderrLog = Join-Path $logsRoot 'router-process-valid.stderr.log'
$routerProcess = $null

try {
    $routerProcess = Start-Process -FilePath $powershellPath -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'router\Start-Router.ps1'),
        '-ConfigPath', $configPath,
        '-RunDurationMs', '8000'
    ) -PassThru -RedirectStandardOutput $routerStdoutLog -RedirectStandardError $routerStderrLog

    $routerState = Wait-ForRouterRunning -RouterStatePath (Join-Path $runtimeRoot 'router-state.json') -TimeoutSeconds 15
    Assert-True ([string]$routerState.Status -eq 'running') 'router should reach running state.'

    & (Join-Path $root 'producer-example.ps1') -ConfigPath $configPath -TargetId 'target01' -TextFilePath $messagePath | Out-Null

    $readyFile = @(
        Get-ChildItem -LiteralPath (Join-Path $inboxRoot 'target01') -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
    )[0]
    Assert-True ($null -ne $readyFile) 'producer should create a ready file after router startup.'

    $processedFile = Wait-ForArchivedMessage -Root $processedRoot -BaseName $readyFile.Name -TimeoutSeconds 15
    Assert-True (Test-Path -LiteralPath $processedFile.FullName -PathType Leaf) 'router should archive the valid pair ready file to processed.'
    Assert-True (Test-Path -LiteralPath ($processedFile.FullName + '.delivery.json') -PathType Leaf) 'processed archive should retain ready delivery metadata.'
    Assert-True (-not (Test-Path -LiteralPath $readyFile.FullName -PathType Leaf)) 'ready file should leave the inbox after successful processing.'

    $ignoredFiles = @(Get-ChildItem -LiteralPath $ignoredRoot -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue)
    $failedFiles = @(Get-ChildItem -LiteralPath $failedRoot -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue)
    $retryFiles = @(Get-ChildItem -LiteralPath $retryPendingRoot -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue)
    Assert-True ($ignoredFiles.Count -eq 0) 'valid pair ready file must not move to ignored.'
    Assert-True ($failedFiles.Count -eq 0) 'valid pair ready file must not move to failed.'
    Assert-True ($retryFiles.Count -eq 0) 'valid pair ready file must not move to retry-pending.'

    $deliveryMetadataRaw = Get-Content -LiteralPath ($processedFile.FullName + '.delivery.json') -Raw -Encoding UTF8
    $deliveryMetadata = ConvertFrom-RelayJsonText -Json $deliveryMetadataRaw
    Assert-True ([string]$deliveryMetadata.MessageType -eq 'pair-seed') 'processed delivery metadata should preserve the pair seed message type.'
    Assert-True ([string]$deliveryMetadata.PairId -eq 'pair01') 'processed delivery metadata should preserve the pair id.'
    Assert-True ([string]$deliveryMetadata.RunId -eq 'run') 'processed delivery metadata should preserve the run id.'
    Assert-IsoTimestampString -Value ([string]$deliveryMetadata.CreatedAt) -Message 'processed delivery metadata should preserve CreatedAt as an ISO timestamp string.'
    Assert-IsoTimestampString -Value ([string]$deliveryMetadata.SourceMessageCreatedAt) -Message 'processed delivery metadata should preserve SourceMessageCreatedAt as an ISO timestamp string.'
    Assert-True ((Get-JsonStringField -Json $deliveryMetadataRaw -FieldName 'CreatedAt') -eq [string]$deliveryMetadata.CreatedAt) 'delivery metadata reader should preserve CreatedAt without locale conversion.'
    Assert-True ((Get-JsonStringField -Json $deliveryMetadataRaw -FieldName 'SourceMessageCreatedAt') -eq [string]$deliveryMetadata.SourceMessageCreatedAt) 'delivery metadata reader should preserve SourceMessageCreatedAt without locale conversion.'

    $statusJson = & (Join-Path $root 'show-relay-status.ps1') -ConfigPath $configPath -RecentCount 4 -AsJson
    $status = ConvertFrom-RelayJsonText -Json (($statusJson | Out-String).Trim())
    Assert-True ([int]$status.Counts.Processed -ge 1) 'show-relay-status should report processed files for the valid pair transport flow.'
    Assert-True ([bool]$status.Router.RequirePairTransportMetadata) 'show-relay-status should surface pair transport metadata enforcement.'
    Assert-True ([bool]$status.Router.RequireReadyDeliveryMetadata) 'show-relay-status should surface ready delivery metadata enforcement.'

    if ($null -ne $routerProcess) {
        [void]$routerProcess.WaitForExit(12000)
    }

    $finalRouterState = ConvertFrom-RelayJsonText -Json (Get-Content -LiteralPath (Join-Path $runtimeRoot 'router-state.json') -Raw -Encoding UTF8)
    Assert-True ([string]$finalRouterState.Status -eq 'stopped') 'router should stop cleanly after the timed isolated run.'
}
finally {
    if ($null -ne $routerProcess -and -not $routerProcess.HasExited) {
        try {
            Stop-Process -Id $routerProcess.Id -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

Write-Host ('router process-valid-pair-transport ok: root=' + $testRoot)
