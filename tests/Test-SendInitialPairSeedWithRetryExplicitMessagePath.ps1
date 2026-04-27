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

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '_tmp\test-send-initial-pair-seed-with-retry-explicit-message'
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot | Out-Null

$runRoot = Join-Path $testRoot 'run'
$inboxTarget01 = Join-Path $testRoot 'inbox\target01'
$inboxTarget05 = Join-Path $testRoot 'inbox\target05'
$processedRoot = Join-Path $testRoot 'processed'
$failedRoot = Join-Path $testRoot 'failed'
$retryPendingRoot = Join-Path $testRoot 'retry-pending'
foreach ($path in @($inboxTarget01, $inboxTarget05, $processedRoot, $failedRoot, $retryPendingRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    MaxPayloadChars = 4000
    MaxPayloadBytes = 12000
    RuntimeRoot = '$($testRoot.Replace("'", "''"))\runtime'
    LogsRoot = '$($testRoot.Replace("'", "''"))\logs'
    ProcessedRoot = '$($processedRoot.Replace("'", "''"))'
    FailedRoot = '$($failedRoot.Replace("'", "''"))'
    RetryPendingRoot = '$($retryPendingRoot.Replace("'", "''"))'
    Targets = @(
        @{
            Id = 'target01'
            Folder = '$($inboxTarget01.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow01'
            FixedSuffix = `$null
        }
        @{
            Id = 'target05'
            Folder = '$($inboxTarget05.Replace("'", "''"))'
            EnterCount = 1
            WindowTitle = 'TestWindow05'
            FixedSuffix = `$null
        }
    )
    PairTest = @{
        RunRootBase = '$($testRoot.Replace("'", "''"))'
        ExecutionPathMode = 'typed-window'
    }
}
"@
[System.IO.File]::WriteAllText($configPath, $configText, (New-Utf8NoBomEncoding))

$reviewInputPath = Join-Path $root 'README.md'
& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $root `
    -SeedReviewInputPath $reviewInputPath `
    -SeedTaskText 'explicit message path test' | Out-Null

$explicitMessagePath = Join-Path $testRoot 'handoff_target05.txt'
$explicitMessageText = "partner handoff explicit message $(Get-Date -Format 'yyyyMMddHHmmssfff')"
[System.IO.File]::WriteAllText($explicitMessagePath, $explicitMessageText, (New-Utf8NoBomEncoding))

$processorScriptPath = Join-Path $testRoot 'processor.ps1'
$processorScript = @"
param(
    [string]`$InboxRoot,
    [string]`$ProcessedRoot
)

`$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt `$deadline) {
    `$file = @(Get-ChildItem -LiteralPath `$InboxRoot -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
    if (`$null -ne `$file) {
        `$destinationName = 'target05__{0}__{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), `$file.Name
        Move-Item -LiteralPath `$file.FullName -Destination (Join-Path `$ProcessedRoot `$destinationName) -Force
        exit 0
    }

    Start-Sleep -Milliseconds 200
}

exit 1
"@
[System.IO.File]::WriteAllText($processorScriptPath, $processorScript, (New-Utf8NoBomEncoding))

$processor = Start-Process -FilePath 'pwsh' -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $processorScriptPath,
    '-InboxRoot', $inboxTarget05,
    '-ProcessedRoot', $processedRoot
) -PassThru -WindowStyle Hidden

try {
    $resultRaw = & (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -TargetId target05 `
        -MessageTextFilePath $explicitMessagePath `
        -MaxAttempts 1 `
        -DelaySeconds 1 `
        -WaitForRouterSeconds 6 `
        -AsJson
    $result = $resultRaw | ConvertFrom-Json
}
finally {
    $null = $processor.WaitForExit(10000)
    if (-not $processor.HasExited) {
        Stop-Process -Id $processor.Id -Force
    }
}

Assert-True ([string]$result.TargetId -eq 'target05') 'helper should target target05 when explicit message path is used.'
Assert-True ([string]$result.FinalState -eq 'processed') 'helper should stop after processed is detected for explicit message path.'
Assert-True ([string]$result.SubmitState -eq 'unknown') 'helper should record unknown submit state when no publish wait is requested for explicit message path.'
Assert-True ([string]$result.MessageTextFilePath -eq $explicitMessagePath) 'result should record the explicit message path.'
Assert-True (Test-Path -LiteralPath ([string]$result.ProcessedPath) -PathType Leaf) 'processed archive path should exist for explicit message path.'

$processedContent = Get-Content -LiteralPath ([string]$result.ProcessedPath) -Raw -Encoding UTF8
Assert-True ($processedContent.Contains($explicitMessageText)) 'processed archive should preserve the explicit handoff message text.'

$seedSendStatusPath = Join-Path $runRoot '.state\seed-send-status.json'
$seedSendStatus = Get-Content -LiteralPath $seedSendStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetStatus = @($seedSendStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)[0]
Assert-True ($null -ne $targetStatus) 'helper should persist seed-send status for target05 when explicit message path is used.'
Assert-True ([string]$targetStatus.FinalState -eq 'processed') 'persisted seed-send status should record processed for explicit message path.'
Assert-True ([string]$targetStatus.LastReadyPath -ne '') 'persisted seed-send status should record the ready path for explicit message path.'

Write-Host ('send-initial-pair-seed-with-retry-explicit-message-path ok: runRoot=' + $runRoot)
