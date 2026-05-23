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
$testRoot = Join-Path $root '_tmp\test-seed-retry-focus-lost-proof-grade'
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
$logsRoot = Join-Path $testRoot 'logs'
foreach ($path in @($inboxTarget01, $inboxTarget05, $processedRoot, $failedRoot, $retryPendingRoot, $logsRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$debugLogPath = Join-Path $logsRoot 'focus-lost-ahk.log'
'focus_stolen_hard_fail' | Set-Content -LiteralPath $debugLogPath -Encoding UTF8

$configPath = Join-Path $testRoot 'settings.test.psd1'
$configText = @"
@{
    MaxPayloadChars = 4000
    MaxPayloadBytes = 12000
    Root = '$($testRoot.Replace("'", "''"))'
    InboxRoot = '$($testRoot.Replace("'", "''"))\inbox'
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
        SeedRetryBackoffMs = @(100)
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
    -SeedTaskText 'seed focus lost proof grade test' | Out-Null

$processorScriptPath = Join-Path $testRoot 'processor.ps1'
$processorScript = @"
param(
    [string]`$InboxRoot,
    [string]`$ProcessedRoot,
    [string]`$RetryPendingRoot,
    [string]`$DebugLogPath
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
    if (`$attempt -eq 1) {
        `$destinationPath = Join-Path `$RetryPendingRoot `$destinationName
        Move-Item -LiteralPath `$file.FullName -Destination `$destinationPath -Force
        [ordered]@{
            SchemaVersion = '1.0.0'
            RetryPath = `$destinationPath
            FailureCategory = 'focus_lost'
            FailureMessage = ('AHK exit code: 42 debugLog=' + `$DebugLogPath)
            DebugLogPath = `$DebugLogPath
            TargetId = 'target01'
            OriginalPath = `$file.FullName
            Attempt = `$attempt
            RecordedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (`$destinationPath + '.meta.json') -Encoding UTF8
        continue
    }

    Move-Item -LiteralPath `$file.FullName -Destination (Join-Path `$ProcessedRoot `$destinationName) -Force
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
    '-ProcessedRoot', $processedRoot,
    '-RetryPendingRoot', $retryPendingRoot,
    '-DebugLogPath', $debugLogPath
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

Assert-True ([string]$result.FinalState -eq 'processed') 'helper should finish after the focus_lost retry is reprocessed.'
Assert-True ([bool]$result.FocusLostObserved) 'result should record focus_lost observation.'
Assert-True ([int]$result.FocusLostCount -eq 1) 'result should count one focus_lost retry.'
Assert-True ([string]$result.FocusLostPolicy -eq 'retry-then-manual') 'result should record the operational focus_lost policy.'
Assert-True ([string]$result.FocusLostRecoveryMode -eq 'auto-retry') 'result should record automatic retry recovery.'
Assert-True ([string]$result.FocusLostDebugLogPath -eq $debugLogPath) 'result should preserve focus_lost debug log path.'
Assert-True ([string]$result.AcceptanceProofGrade -eq 'recovered-auto-retry') 'result should grade the pass as recovered, not clean.'

$seedSendStatusPath = Join-Path $runRoot '.state\seed-send-status.json'
$seedSendStatus = Get-Content -LiteralPath $seedSendStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetStatus = @($seedSendStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([bool]$targetStatus.FocusLostObserved) 'persisted seed-send status should record focus_lost observation.'
Assert-True ([int]$targetStatus.FocusLostCount -eq 1) 'persisted seed-send status should record focus_lost count.'
Assert-True ([string]$targetStatus.FocusLostRecoveryMode -eq 'auto-retry') 'persisted seed-send status should record recovery mode.'
Assert-True ([string]$targetStatus.AcceptanceProofGrade -eq 'recovered-auto-retry') 'persisted seed-send status should record recovered proof grade.'

$statusJson = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') `
    '-ConfigPath' $configPath `
    '-RunRoot' $runRoot `
    '-AsJson'
$pairedStatus = $statusJson | ConvertFrom-Json
$target01Row = @($pairedStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([bool]$target01Row.FocusLostObserved) 'paired status should surface focus_lost observation.'
Assert-True ([int]$target01Row.FocusLostCount -eq 1) 'paired status should surface focus_lost count.'
Assert-True ([string]$target01Row.AcceptanceProofGrade -eq 'recovered-auto-retry') 'paired status should surface recovered proof grade.'
Assert-True ([int]$pairedStatus.Counts.FocusLostObservedCount -ge 1) 'paired status counts should include focus_lost observed rows.'
Assert-True ([int]$pairedStatus.Counts.FocusLostRecoveredCount -ge 1) 'paired status counts should include recovered proof rows.'

Write-Host ('seed retry focus_lost proof grade ok: runRoot=' + $runRoot)
