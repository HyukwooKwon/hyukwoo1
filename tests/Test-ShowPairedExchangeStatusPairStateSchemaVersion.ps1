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
$tmpRoot = Join-Path $root '_tmp\Test-ShowPairedExchangeStatusPairStateSchemaVersion'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$stateRoot = Join-Path $runRoot '.state'

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$pairStatePath = Join-Path $stateRoot 'pair-state.json'

[ordered]@{
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
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $pairStatePath -Encoding UTF8

$legacyStatusRaw = & (Resolve-Path (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1')).Path `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$legacyStatus = $legacyStatusRaw | ConvertFrom-Json
$legacyPair = @($legacyStatus.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)

Assert-True ([string]$legacyStatus.PairState.SchemaStatus -eq 'legacy-missing') 'missing schema version should fall back to legacy-missing.'
Assert-True ([string]$legacyStatus.PairState.SchemaVersion -eq '1.0.0') 'missing schema version should assume 1.0.0.'
Assert-True ((@($legacyStatus.PairState.Warnings)).Count -ge 1) 'missing schema version should surface a warning.'
Assert-True ([string]$legacyPair[0].CurrentPhase -eq 'waiting-partner-handoff') 'legacy pair-state should still normalize phases.'

[ordered]@{
    SchemaVersion = '9.9.9'
    RunRoot = $runRoot
    UpdatedAt = (Get-Date).ToString('o')
    Pairs = @(
        [ordered]@{
            PairId = 'pair01'
            TopTargetId = 'target01'
            BottomTargetId = 'target05'
            SeedTargetId = 'target01'
            ForwardCount = 4
            RoundtripCount = 2
            CurrentPhase = 'manual-review'
            NextAction = 'manual-review'
            HandoffReadyCount = 0
            NextExpectedSourceTargetId = 'target05'
            NextExpectedTargetId = 'target01'
            NextExpectedHandoff = 'target05 -> target01'
            ConfiguredMaxRoundtripCount = 10
            LimitReached = $false
            Paused = $false
            UpdatedAt = (Get-Date).ToString('o')
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $pairStatePath -Encoding UTF8

$unsupportedStatusRaw = & (Resolve-Path (Join-Path $root 'tests\Show-PairedExchangeStatus.ps1')).Path `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson
$unsupportedStatus = $unsupportedStatusRaw | ConvertFrom-Json
$unsupportedPair = @($unsupportedStatus.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)

Assert-True ([string]$unsupportedStatus.PairState.SchemaStatus -eq 'unsupported') 'unsupported schema version should be surfaced.'
Assert-True ([string]$unsupportedStatus.PairState.DeclaredSchemaVersion -eq '9.9.9') 'unsupported schema version should preserve the declared version.'
Assert-True ((@($unsupportedStatus.PairState.Warnings)).Count -ge 1) 'unsupported schema version should surface a warning.'
Assert-True ([string]$unsupportedPair[0].CurrentPhase -eq 'manual-attention') 'unsupported schema version should still keep pair rows readable.'

Write-Host ('show paired exchange status pair-state schema version ok: runRoot=' + $runRoot)
