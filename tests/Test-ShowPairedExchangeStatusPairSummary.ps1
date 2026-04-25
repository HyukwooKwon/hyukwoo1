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

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-ShowPairedExchangeStatusPairSummary'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$stateRoot = Join-Path $runRoot '.state'

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$manifestPath = Join-Path $runRoot 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pairTest = $manifest.PairTest
$targets = @($manifest.Targets | Where-Object { [string]$_.PairId -eq 'pair01' })
$forwardedState = @{}

foreach ($item in $targets) {
    $targetId = [string]$item.TargetId
    $targetFolder = [string]$item.TargetFolder
    $reviewFolder = [string]$item.ReviewFolderPath
    $summaryPath = [string]$item.SummaryPath
    $donePath = Join-Path $targetFolder ([string]($pairTest.HeadlessExec.DoneFileName))
    $contentPath = Join-Path $reviewFolder ($targetId + '-payload.txt')
    $zipPath = Join-Path $reviewFolder ($targetId + '-review.zip')

    New-Item -ItemType Directory -Path $reviewFolder -Force | Out-Null
    Set-Content -LiteralPath $contentPath -Value ('artifact for ' + $targetId) -Encoding UTF8
    Compress-Archive -LiteralPath $contentPath -DestinationPath $zipPath -Force
    Remove-Item -LiteralPath $contentPath -Force
    Set-Content -LiteralPath $summaryPath -Value ('summary for ' + $targetId) -Encoding UTF8
    Set-Content -LiteralPath $donePath -Value 'done' -Encoding UTF8

    $zipInfo = Get-Item -LiteralPath $zipPath
    $fingerprint = '{0}|{1}|{2}|{3}' -f `
        $targetId,
        $zipInfo.FullName.ToLowerInvariant(),
        [int64]$zipInfo.Length,
        [int64]$zipInfo.LastWriteTimeUtc.Ticks
    $forwardedState[$fingerprint] = (Get-Date).ToString('o')
}

$forwardedPath = Join-Path $stateRoot 'forwarded.json'
$forwardedState | ConvertTo-Json | Set-Content -LiteralPath $forwardedPath -Encoding UTF8

$statusRaw = & (Resolve-Path (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1')).Path `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$status = $statusRaw | ConvertFrom-Json
$pair = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)

Assert-True ($pair.Count -eq 1) 'status should surface pair summary for pair01.'
Assert-True ([int]$pair[0].RoundtripCount -eq 1) 'pair summary should count one completed roundtrip from two forwarded states.'
Assert-True ([int]$pair[0].ForwardedStateCount -eq 2) 'pair summary should surface forwarded state count for both targets.'
Assert-True ([string]$pair[0].NextAction -eq 'await-partner-output') 'pair summary should mark forwarded pair as awaiting partner output.'
Assert-True ([string]$pair[0].LatestStateSummary -match 'target01:forwarded') 'pair summary should include target01 latest state.'
Assert-True ([string]$pair[0].LatestStateSummary -match 'target05:forwarded') 'pair summary should include target05 latest state.'
Assert-True ([string]$pair[0].ProgressDetail -match '왕복=1') 'pair summary should surface roundtrip progress detail.'
Assert-True ([string]$pair[0].PolicySeedTargetId -eq 'target01') 'pair summary should surface policy seed target.'
Assert-True ([string]$pair[0].PolicyPublishContractMode -eq 'strict') 'pair summary should surface policy publish contract mode.'
Assert-True ([string]$pair[0].PolicySummary -match 'seed=target01') 'pair summary should include compact policy summary.'

Write-Host ('show paired exchange status pair summary ok: runRoot=' + $runRoot)
