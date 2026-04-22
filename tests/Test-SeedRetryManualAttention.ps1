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
$testRoot = Join-Path $root '_tmp\test-seed-retry-manual-attention'
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
        SeedRetryMaxAttempts = 2
        SeedRetryBackoffMs = @(250)
        SeedOutboxStartTimeoutSeconds = 30
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
    -SeedTaskText 'seed manual attention test' | Out-Null

$processorScriptPath = Join-Path $testRoot 'processor.ps1'
$processorScript = @"
param(
    [string]`$InboxRoot,
    [string]`$RetryPendingRoot
)

`$attempt = 0
`$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt `$deadline -and `$attempt -lt 2) {
    `$file = @(Get-ChildItem -LiteralPath `$InboxRoot -Filter '*.ready.txt' -File -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
    if (`$null -eq `$file) {
        Start-Sleep -Milliseconds 20
        continue
    }

    `$attempt += 1
    `$destinationName = 'target01__{0}__{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), `$file.Name
    `$destinationPath = Join-Path `$RetryPendingRoot `$destinationName
    Move-Item -LiteralPath `$file.FullName -Destination `$destinationPath -Force

    `$metadataPath = `$destinationPath + '.meta.json'
    [ordered]@{
        SchemaVersion = '1.0.0'
        RetryPath = `$destinationPath
        FailureCategory = 'user_active_hold'
        FailureMessage = 'simulated user activity hold'
        TargetId = 'target01'
        OriginalPath = `$file.FullName
        Attempt = `$attempt
        RecordedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `$metadataPath -Encoding UTF8
}

exit 0
"@
[System.IO.File]::WriteAllText($processorScriptPath, $processorScript, (New-Utf8NoBomEncoding))

$powershellPath = Resolve-PowerShellExecutable
$processor = Start-Process -FilePath $powershellPath -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $processorScriptPath,
    '-InboxRoot', $inboxTarget01,
    '-RetryPendingRoot', $retryPendingRoot
) -PassThru -WindowStyle Hidden

try {
    $resultRaw = & (Join-Path $root 'tests\Send-InitialPairSeedWithRetry.ps1') `
        -ConfigPath $configPath `
        -RunRoot $runRoot `
        -TargetId target01 `
        -WaitForRouterSeconds 5 `
        -DelaySeconds 1 `
        -AsJson
    $result = $resultRaw | ConvertFrom-Json
}
finally {
    $null = $processor.WaitForExit(10000)
    if (-not $processor.HasExited) {
        Stop-Process -Id $processor.Id -Force
    }
}

Assert-True ([string]$result.FinalState -eq 'manual_attention_required') 'helper should stop with manual_attention_required after retry ceiling.'
Assert-True ([bool]$result.ManualAttentionRequired) 'manual attention flag should be true.'
Assert-True ([string]$result.RetryReason -eq 'user_active_hold') 'retry reason should preserve router failure category.'
Assert-True ([int]$result.AttemptCount -eq 2) 'helper should exhaust two attempts.'

$seedSendStatusPath = Join-Path $runRoot '.state\seed-send-status.json'
$seedSendStatus = Get-Content -LiteralPath $seedSendStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetStatus = @($seedSendStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$targetStatus.FinalState -eq 'manual_attention_required') 'persisted seed-send status should record manual attention state.'
Assert-True ([bool]$targetStatus.ManualAttentionRequired) 'persisted seed-send status should set manual attention flag.'
Assert-True ([string]$targetStatus.RetryReason -eq 'user_active_hold') 'persisted seed-send status should preserve retry reason.'

$watcherResult = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' (Join-Path $root 'tests\Watch-PairedExchange.ps1') `
    '-ConfigPath' $configPath `
    '-RunRoot' $runRoot `
    '-RunDurationSec' '2'
if ($LASTEXITCODE -ne 0) {
    throw "watcher should exit cleanly for manual attention status pass. exitCode=$LASTEXITCODE"
}

$statusJson = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') `
    '-ConfigPath' $configPath `
    '-RunRoot' $runRoot `
    '-AsJson'
$pairedStatus = $statusJson | ConvertFrom-Json
$target01Row = @($pairedStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$target01Row.SourceOutboxState -eq 'manual-attention-required') 'paired status should surface manual-attention-required.'
Assert-True ([string]$target01Row.SourceOutboxReason -eq 'user_active_hold') 'paired status should expose retry reason.'
Assert-True ([bool]$target01Row.ManualAttentionRequired) 'paired status should expose manual attention flag.'
Assert-True ([int]$pairedStatus.Counts.ManualAttentionCount -ge 1) 'paired status counts should include manual attention rows.'

Write-Host ('seed retry manual attention ok: runRoot=' + $runRoot)
