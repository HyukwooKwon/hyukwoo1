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
$tmpRoot = Join-Path $root '_tmp\Test-ShowPairedExchangeStatusPairPhaseNormalization'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$stateRoot = Join-Path $runRoot '.state'

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01,pair02 | Out-Null

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
            ForwardCount = 2
            RoundtripCount = 1
            CurrentPhase = 'waiting-handoff'
            NextAction = 'handoff-ready'
            HandoffReadyCount = 1
            NextExpectedSourceTargetId = 'target01'
            NextExpectedTargetId = 'target05'
            NextExpectedHandoff = 'target01 -> target05'
            ConfiguredMaxRoundtripCount = 10
            LimitReached = $false
            Paused = $false
            UpdatedAt = (Get-Date).ToString('o')
        },
        [ordered]@{
            PairId = 'pair02'
            TopTargetId = 'target02'
            BottomTargetId = 'target06'
            SeedTargetId = 'target02'
            ForwardCount = 4
            RoundtripCount = 2
            CurrentPhase = 'unknown-phase'
            NextAction = 'manual-review'
            HandoffReadyCount = 0
            NextExpectedSourceTargetId = 'target06'
            NextExpectedTargetId = 'target02'
            NextExpectedHandoff = 'target06 -> target02'
            ConfiguredMaxRoundtripCount = 10
            LimitReached = $false
            Paused = $false
            UpdatedAt = (Get-Date).ToString('o')
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'pair-state.json') -Encoding UTF8

$statusRaw = & (Resolve-Path (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1')).Path `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$status = $statusRaw | ConvertFrom-Json
$pair01 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)
$pair02 = @($status.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)

Assert-True ($pair01.Count -eq 1) 'status should surface pair01 summary row.'
Assert-True ($pair02.Count -eq 1) 'status should surface pair02 summary row.'
Assert-True ([string]$pair01[0].CurrentPhase -eq 'waiting-partner-handoff') 'waiting-handoff should normalize to waiting-partner-handoff.'
Assert-True ([string]$pair02[0].CurrentPhase -eq 'manual-attention') 'manual-review fallback should normalize to manual-attention.'
Assert-True ([string]$pair01[0].ProgressDetail -match '단계=waiting-partner-handoff') 'progress detail should use normalized waiting handoff phase.'
Assert-True ([string]$pair02[0].ProgressDetail -match '단계=manual-attention') 'progress detail should use normalized manual attention phase.'

Write-Host ('show paired exchange status pair phase normalization ok: runRoot=' + $runRoot)
