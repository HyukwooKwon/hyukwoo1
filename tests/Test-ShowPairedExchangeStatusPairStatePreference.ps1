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
$tmpRoot = Join-Path $root '_tmp\Test-ShowPairedExchangeStatusPairStatePreference'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$stateRoot = Join-Path $runRoot '.state'

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

[ordered]@{
    'target01|seed-forward-01' = (Get-Date).ToString('o')
    'target05|seed-forward-02' = (Get-Date).AddSeconds(1).ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stateRoot 'forwarded.json') -Encoding UTF8

[ordered]@{
    SchemaVersion = '1.0.0'
    RunRoot = $runRoot
    UpdatedAt = (Get-Date).ToString('o')
    Pairs = @(
        [ordered]@{
            PairId = 'pair01'
            TopTargetId = 'target01'
            BottomTargetId = 'target05'
            SeedTargetId = 'target01'
            ForwardCount = 6
            RoundtripCount = 3
            CurrentPhase = 'paused'
            NextAction = 'resume-required'
            HandoffReadyCount = 0
            NextExpectedSourceTargetId = 'target05'
            NextExpectedTargetId = 'target01'
            NextExpectedHandoff = 'target05 -> target01'
            LastFromTargetId = 'target01'
            LastToTargetId = 'target05'
            LastForwardedAt = (Get-Date).ToString('o')
            LastForwardedZipPath = 'C:\fake\pair01-review.zip'
            StateSummary = 'target01:forwarded, target05:forwarded'
            ConfiguredMaxRoundtripCount = 10
            LimitReached = $false
            LimitReachedAt = ''
            Paused = $true
            UpdatedAt = (Get-Date).ToString('o')
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'pair-state.json') -Encoding UTF8

$statusRaw = & (Resolve-Path (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1')).Path `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$status = $statusRaw | ConvertFrom-Json
$pair = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)

Assert-True ([bool]$status.PairState.Exists) 'status should surface pair-state file metadata.'
Assert-True ($pair.Count -eq 1) 'status should surface pair summary for pair01.'
Assert-True ([int]$pair[0].RoundtripCount -eq 3) 'pair-state roundtrip count should override computed fallback.'
Assert-True ([int]$pair[0].ForwardedStateCount -eq 6) 'pair-state forward count should override computed fallback.'
Assert-True ([string]$pair[0].CurrentPhase -eq 'paused') 'pair-state current phase should be surfaced.'
Assert-True ([string]$pair[0].NextExpectedHandoff -eq 'target05 -> target01') 'pair-state next expected handoff should be surfaced.'
Assert-True ([string]$pair[0].NextAction -eq 'resume-required') 'pair-state next action should be preferred.'
Assert-True ([string]$pair[0].ProgressDetail -match '단계=paused') 'pair-state progress detail should include the current phase.'

Write-Host ('show paired exchange status pair-state preference ok: runRoot=' + $runRoot)
