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
$testRoot = Join-Path $root '_tmp\test-invoke-paired-exchange-one-shot-submit'
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
$runtimeRoot = Join-Path $testRoot 'runtime'
$logsRoot = Join-Path $testRoot 'logs'
foreach ($path in @($inboxTarget01, $inboxTarget05, $processedRoot, $failedRoot, $retryPendingRoot, $runtimeRoot, $logsRoot)) {
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
    RuntimeRoot = '$($runtimeRoot.Replace("'", "''"))'
    LogsRoot = '$($logsRoot.Replace("'", "''"))'
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
        TypedWindow = @{
            SubmitProbeSeconds = 1
            SubmitProbePollMs = 200
            SubmitRetryLimit = 0
            ProgressCpuDeltaThresholdSeconds = 0.05
        }
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
    -SeedTaskText 'one-shot submit primitive test' | Out-Null

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
    $resultRaw = & (Join-Path $root 'tests\Invoke-PairedExchangeOneShotSubmit.ps1') `
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

Assert-True ([string]$result.PrimitiveName -eq 'one-shot-submit') 'wrapper should mark the primitive name.'
Assert-True ([string]$result.PairId -eq 'pair01') 'wrapper should resolve pair01 from target01.'
Assert-True ([string]$result.TargetId -eq 'target01') 'wrapper should preserve selected target.'
Assert-True ([string]$result.PartnerTargetId -eq 'target05') 'wrapper should resolve partner target.'
Assert-True ([bool]$result.PrimitiveSuccess) 'wrapper should report primitive success when seed result is recorded.'
Assert-True (-not [bool]$result.PrimitiveAccepted) 'submit-unconfirmed should not count as accepted submit primitive.'
Assert-True ([string]$result.PrimitiveState -eq 'submit-unconfirmed') 'wrapper should surface final seed state.'
Assert-True ([string]$result.NextPrimitiveAction -eq 'publish-confirm') 'wrapper should recommend publish confirmation after submit.'
Assert-True ([string]$result.Submit.FinalState -eq 'submit-unconfirmed') 'wrapper should retain raw seed result.'
Assert-True ([string]$result.Submit.SubmitState -eq 'unconfirmed') 'wrapper should retain raw submit state.'
Assert-True ([string]$result.Evidence.Target.SubmitState -eq 'unconfirmed') 'wrapper should surface evidence target submit state.'
Assert-True ([string]$result.Evidence.SubmitState -eq 'unconfirmed') 'wrapper should surface compact evidence submit state.'
Assert-True ([string]$result.PairedTargetStatus.SubmitState -eq 'unconfirmed') 'wrapper should attach paired target submit state.'
Assert-True ([string]$result.PairedTargetStatus.ExecutionPathMode -eq 'typed-window') 'wrapper should attach typed-window execution path on target row.'
Assert-True ([string]$result.PairedStatusSnapshot.PairTest.ExecutionPathMode -eq 'typed-window') 'wrapper should include paired status snapshot.'

Write-Host ('invoke paired exchange one-shot submit ok: runRoot=' + $runRoot)
