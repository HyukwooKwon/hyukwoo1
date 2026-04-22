[CmdletBinding()]
param(
    [string]$ConfigPath
)

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

function Invoke-PowerShellProcess {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $powershellPath = Resolve-PowerShellExecutable
    $result = & $powershellPath '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $ScriptPath @Arguments
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Raw = ($result | Out-String).Trim()
    }
}

function Invoke-PowerShellJson {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $result = Invoke-PowerShellProcess -ScriptPath $ScriptPath -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($result.Raw)) {
        throw "script returned no output: $ScriptPath"
    }
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        Raw = $result.Raw
        Json = ($result.Raw | ConvertFrom-Json)
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$runRoot = Join-Path $pairRunRootBase ('run_seed_lane_status_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 `
    -SeedWorkRepoRoot $root `
    -SeedReviewInputPath (Join-Path $root 'README.md') `
    -SeedTaskText 'seed lane status test' | Out-Null

$stateRoot = Join-Path $runRoot '.state'
$seedSendStatusPath = Join-Path $stateRoot 'seed-send-status.json'
$target01Outbox = Join-Path $runRoot 'pair01\target01\source-outbox'
$target01SummaryPath = Join-Path $target01Outbox 'summary.txt'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

$seedProcessedAt = (Get-Date).AddMinutes(-10).ToString('o')
$seedSendPayload = [ordered]@{
    SchemaVersion = '1.0.0'
    RunRoot = $runRoot
    UpdatedAt = (Get-Date).ToString('o')
    Targets = @(
        [ordered]@{
            TargetId = 'target01'
            UpdatedAt = (Get-Date).ToString('o')
            FinalState = 'processed'
            AttemptCount = 1
            MaxAttempts = 3
            ProcessedPath = (Join-Path $stateRoot 'dummy-processed.txt')
            ProcessedAt = $seedProcessedAt
            FailedPath = ''
            FailedAt = ''
            RetryPendingPath = ''
            RetryPendingAt = ''
            OutboxPublished = $false
            OutboxObservedAt = ''
            LastReadyPath = ''
            LastReadyBaseName = ''
        }
    )
}
$seedSendPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $seedSendStatusPath -Encoding UTF8

$watcherFirstRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-RunDurationSec', '2'
)
Assert-True ($watcherFirstRun.ExitCode -eq 0) 'watcher should exit cleanly for seed lane unresponsive status pass.'

$statusPath = Join-Path $stateRoot 'source-outbox-status.json'
$sourceOutboxStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01Status = @($sourceOutboxStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ($null -ne $target01Status) 'target01 source-outbox status row should exist.'
Assert-True ([string]$target01Status.State -eq 'target-unresponsive-after-send') 'target01 should be marked target-unresponsive-after-send when no outbox activity follows processed seed.'

$pairedStatusFirst = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-AsJson'
)
$target01PairedFirst = @($pairedStatusFirst.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$target01PairedFirst.SourceOutboxState -eq 'target-unresponsive-after-send') 'paired status should surface target-unresponsive-after-send.'
Assert-True ([int]$pairedStatusFirst.Json.Counts.TargetUnresponsiveCount -ge 1) 'paired status counts should include target-unresponsive-after-send.'

[System.IO.File]::WriteAllText($target01SummaryPath, 'seed lane publish started', (New-Utf8NoBomEncoding))

$watcherSecondRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-RunDurationSec', '2'
)
Assert-True ($watcherSecondRun.ExitCode -eq 0) 'watcher should exit cleanly for publish-started status pass.'

$sourceOutboxStatusSecond = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01StatusSecond = @($sourceOutboxStatusSecond.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$target01StatusSecond.State -eq 'publish-started') 'target01 should move to publish-started when outbox activity appears after processed seed.'

$pairedStatusSecond = Invoke-PowerShellJson -ScriptPath (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-AsJson'
)
$target01PairedSecond = @($pairedStatusSecond.Json.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$target01PairedSecond.SourceOutboxState -eq 'publish-started') 'paired status should surface publish-started.'
Assert-True ([int]$pairedStatusSecond.Json.Counts.PublishStartedCount -ge 1) 'paired status counts should include publish-started.'

Write-Host ('seed send lane status ok: runRoot=' + $runRoot)
