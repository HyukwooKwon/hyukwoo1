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

function New-ReadyPayload {
    param(
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ReviewZipPath,
        [Parameter(Mandatory)][string]$PublishedAt,
        [Parameter(Mandatory)][string]$PublishedBy
    )

    $summaryItem = Get-Item -LiteralPath $SummaryPath -ErrorAction Stop
    $zipItem = Get-Item -LiteralPath $ReviewZipPath -ErrorAction Stop
    return [ordered]@{
        SchemaVersion = '1.0.0'
        PairId = $PairId
        TargetId = $TargetId
        SummaryPath = $SummaryPath
        ReviewZipPath = $ReviewZipPath
        PublishedAt = $PublishedAt
        SummarySizeBytes = [int64]$summaryItem.Length
        ReviewZipSizeBytes = [int64]$zipItem.Length
        SummarySha256 = [string](Get-FileHash -LiteralPath $SummaryPath -Algorithm SHA256 -ErrorAction Stop).Hash
        ReviewZipSha256 = [string](Get-FileHash -LiteralPath $ReviewZipPath -Algorithm SHA256 -ErrorAction Stop).Hash
        PublishedBy = $PublishedBy
        ValidationPassed = $true
        ValidationCompletedAt = $PublishedAt
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
$runRoot = Join-Path $pairRunRootBase ('run_watch_manual_marker_repair_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 | Out-Null

$targetRoot = Join-Path $runRoot 'pair01\target01'
$request = Get-Content -LiteralPath (Join-Path $targetRoot 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$summaryPath = [string]$request.SourceSummaryPath
$reviewZipPath = [string]$request.SourceReviewZipPath
$publishReadyPath = [string]$request.PublishReadyPath
$archiveRoot = [string]$request.PublishedArchivePath
$sourceOutboxRoot = Split-Path -Parent $summaryPath
New-Item -ItemType Directory -Path $sourceOutboxRoot -Force | Out-Null
[System.IO.File]::WriteAllText($summaryPath, 'manual marker repair summary', (New-Utf8NoBomEncoding))
$zipNotePath = Join-Path $sourceOutboxRoot 'manual-marker-note.txt'
[System.IO.File]::WriteAllText($zipNotePath, 'manual marker repair zip payload', (New-Utf8NoBomEncoding))
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $reviewZipPath -Force
$readyPayload = New-ReadyPayload `
    -PairId 'pair01' `
    -TargetId 'target01' `
    -SummaryPath $summaryPath `
    -ReviewZipPath $reviewZipPath `
    -PublishedAt ((Get-Date).ToString('o')) `
    -PublishedBy 'codex'
$readyPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $publishReadyPath -Encoding UTF8

$watcherRun = Invoke-PowerShellProcess -ScriptPath (Join-Path $root 'tests\Watch-PairedExchange.ps1') -Arguments @(
    '-ConfigPath', $resolvedConfigPath,
    '-RunRoot', $runRoot,
    '-MaxForwardCount', '1',
    '-RunDurationSec', '8'
)

Assert-True ($watcherRun.ExitCode -eq 0) 'watcher should exit cleanly after manual marker auto-repair.'
Assert-True ($watcherRun.Raw.Contains('source-outbox auto-repair succeeded target01')) 'watcher should report auto-repair success for the manual marker.'
Assert-True (-not (Test-Path -LiteralPath $publishReadyPath -PathType Leaf)) 'manual marker should be archived after watcher import.'
Assert-True ((Test-Path -LiteralPath (Join-Path $targetRoot 'summary.txt') -PathType Leaf)) 'contract summary should exist after auto-repair import.'
Assert-True ((Test-Path -LiteralPath (Join-Path $targetRoot 'done.json') -PathType Leaf)) 'done.json should exist after auto-repair import.'

$archivedReadyFiles = @(Get-ChildItem -LiteralPath $archiveRoot -Filter '*.ready.json' -File -ErrorAction SilentlyContinue)
Assert-True ($archivedReadyFiles.Count -eq 1) 'archive should contain the repaired publish.ready marker.'
$archivedReady = Get-Content -LiteralPath $archivedReadyFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$archivedReady.PublishedBy -eq 'publish-paired-exchange-artifact.ps1') 'archived marker should be rewritten by publish helper.'

$sourceOutboxStatusPath = Join-Path $runRoot '.state\source-outbox-status.json'
$sourceOutboxStatus = Get-Content -LiteralPath $sourceOutboxStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetStatus = @($sourceOutboxStatus.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ($null -ne $targetStatus) 'source-outbox status should include target01 after auto-repair import.'
Assert-True ([string]$targetStatus.State -in @('imported', 'imported-archive-pending', 'forwarded', 'duplicate-marker-archived')) 'source-outbox status should record successful import after auto-repair.'
Assert-True ([string]$targetStatus.OriginalReadyReason -eq 'marker-publisher-unsupported') 'source-outbox status should record the original readiness reason before auto-repair.'
Assert-True ([string]$targetStatus.FinalReadyReason -eq 'ready') 'source-outbox status should record the repaired readiness reason.'
Assert-True ([bool]$targetStatus.RepairAttempted) 'source-outbox status should record that auto-repair was attempted.'
Assert-True ([bool]$targetStatus.RepairSucceeded) 'source-outbox status should record that auto-repair succeeded.'
Assert-True ([string]$targetStatus.RepairSourceContext -eq 'watcher-auto-repair:marker-publisher-unsupported') 'source-outbox status should record the repair source context.'

Write-Host ('watch-paired-exchange manual publish.ready auto-repair ok: runRoot=' + $runRoot)
