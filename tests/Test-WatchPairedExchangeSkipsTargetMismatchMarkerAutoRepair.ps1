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

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $preferredExternalizedConfigPath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-config\bottest-live-visible\settings.externalized.psd1'
    if (Test-Path -LiteralPath $preferredExternalizedConfigPath -PathType Leaf) {
        $ConfigPath = $preferredExternalizedConfigPath
    }
    else {
        $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
    }
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$runRoot = Join-Path $pairRunRootBase ('run_watch_targetid_mismatch_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 | Out-Null

$targetRoot = Join-Path $runRoot 'pair01\target01'
$request = Get-Content -LiteralPath (Join-Path $targetRoot 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$summaryPath = [string]$request.SourceSummaryPath
$reviewZipPath = [string]$request.SourceReviewZipPath
$publishReadyPath = [string]$request.PublishReadyPath
$publishScriptPath = [string]$request.PublishScriptPath
$sourceOutboxRoot = Split-Path -Parent $summaryPath
New-Item -ItemType Directory -Path $sourceOutboxRoot -Force | Out-Null
[System.IO.File]::WriteAllText($summaryPath, 'target mismatch summary', (New-Utf8NoBomEncoding))
$zipNotePath = Join-Path $sourceOutboxRoot 'target-mismatch-note.txt'
[System.IO.File]::WriteAllText($zipNotePath, 'target mismatch zip payload', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $reviewZipPath -Force

$publish = Invoke-PowerShellProcess -ScriptPath $publishScriptPath -Arguments @(
    '-Overwrite',
    '-SourceContext', 'watch-test-targetid-mismatch',
    '-AsJson'
)
Assert-True ($publish.ExitCode -eq 0) 'publish helper should create the initial marker before mutation.'
Assert-True ((Test-Path -LiteralPath $publishReadyPath -PathType Leaf)) 'publish helper should create publish.ready.json before mutation.'

$readyDoc = Get-Content -LiteralPath $publishReadyPath -Raw -Encoding UTF8 | ConvertFrom-Json
$readyDoc.TargetId = 'target99'
$readyDoc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $publishReadyPath -Encoding UTF8

$watcherRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-MaxForwardCount', '1',
    '-RunDurationSec', '8'
)

Assert-True ($watcherRun.ExitCode -eq 0) 'watcher should exit cleanly when the target mismatch marker remains waiting.'
Assert-True ($watcherRun.Raw.Contains('reason=marker-targetid-mismatch')) 'watcher should report marker-targetid-mismatch.'
Assert-True (-not $watcherRun.Raw.Contains('source-outbox auto-repair start target01')) 'watcher should not auto-repair a target mismatch marker.'
Assert-True (-not $watcherRun.Raw.Contains('source-outbox auto-repair succeeded target01')) 'watcher should not report target mismatch auto-repair success.'
Assert-True ((Test-Path -LiteralPath $publishReadyPath -PathType Leaf)) 'target mismatch marker should remain in place because watcher must not auto-repair it.'

$sourceOutboxStatusPath = Join-Path $runRoot '.state\source-outbox-status.json'
$sourceOutboxStatus = Get-Content -LiteralPath $sourceOutboxStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetStatus = @($sourceOutboxStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ($null -ne $targetStatus) 'source-outbox status should include target01 while waiting on the invalid marker.'
Assert-True ([string]$targetStatus.State -eq 'waiting') 'source-outbox status should remain waiting for target mismatch markers.'
Assert-True ([string]$targetStatus.Reason -eq 'marker-targetid-mismatch') 'source-outbox status should surface marker-targetid-mismatch.'
Assert-True (-not [bool]$targetStatus.RepairAttempted) 'source-outbox status should record that no auto-repair was attempted for target mismatch.'
Assert-True (-not [bool]$targetStatus.RepairSucceeded) 'source-outbox status should record that no auto-repair succeeded for target mismatch.'
Assert-True ([string]$targetStatus.SuggestedAction -eq 'manual-review-source-outbox-marker') 'source-outbox status should recommend manual review for target mismatch markers.'
Assert-True ([string]$targetStatus.OriginalReadyReason -eq 'marker-targetid-mismatch') 'source-outbox status should keep the original readiness reason.'
Assert-True ([string]$targetStatus.FinalReadyReason -eq 'marker-targetid-mismatch') 'source-outbox status should keep the final readiness reason unchanged when no repair runs.'

Write-Host ('watch-paired-exchange target mismatch marker skips auto-repair ok: runRoot=' + $runRoot)
