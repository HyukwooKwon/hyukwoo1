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
$testRoot = Join-Path $root '_tmp\test-send-initial-pair-seed-submit-state'
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
    -SeedTaskText 'seed submit state test' | Out-Null

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
        `$destinationName = 'target01__{0}__{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), `$file.Name
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
    '-InboxRoot', $inboxTarget01,
    '-ProcessedRoot', $processedRoot
) -PassThru -WindowStyle Hidden

try {
    $resultRaw = & (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -TargetId target01 `
        -MaxAttempts 1 `
        -DelaySeconds 1 `
        -WaitForRouterSeconds 6 `
        -WaitForPublishSeconds 1 `
        -AsJson
    $result = $resultRaw | ConvertFrom-Json
}
finally {
    $null = $processor.WaitForExit(10000)
    if (-not $processor.HasExited) {
        Stop-Process -Id $processor.Id -Force
    }
}

Assert-True ([string]$result.FinalState -eq 'submit-unconfirmed') 'helper should mark submit-unconfirmed when router processed but no publish evidence appears within wait window.'
Assert-True ([string]$result.SubmitState -eq 'unconfirmed') 'submit state should be unconfirmed without publish evidence.'
Assert-True (-not [bool]$result.SubmitConfirmed) 'submit confirmed flag should remain false without publish evidence.'

$seedSendStatusPath = Join-Path $runRoot '.state\seed-send-status.json'
$seedSendStatus = Get-Content -LiteralPath $seedSendStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetStatus = @($seedSendStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$targetStatus.FinalState -eq 'submit-unconfirmed') 'persisted seed-send status should record submit-unconfirmed.'
Assert-True ([string]$targetStatus.SubmitState -eq 'unconfirmed') 'persisted seed-send status should record unconfirmed submit state.'

Write-Host ('send-initial-pair-seed-submit-state ok: runRoot=' + $runRoot)
