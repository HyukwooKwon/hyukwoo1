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
$tmpRoot = Join-Path $root '_tmp\Test-ShowPairedExchangeStatusMixedPairStates'
$runRoot = Join-Path $tmpRoot ('run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$configPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$stateRoot = Join-Path $runRoot '.state'

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -IncludePairId pair01,pair02,pair03,pair04 | Out-Null

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
            CurrentPhase = 'paused'
            NextAction = 'resume-required'
            HandoffReadyCount = 0
            NextExpectedSourceTargetId = 'target01'
            NextExpectedTargetId = 'target05'
            NextExpectedHandoff = 'target01 -> target05'
            ConfiguredMaxRoundtripCount = 10
            LimitReached = $false
            Paused = $true
            UpdatedAt = (Get-Date).ToString('o')
        },
        [ordered]@{
            PairId = 'pair02'
            TopTargetId = 'target02'
            BottomTargetId = 'target06'
            SeedTargetId = 'target02'
            ForwardCount = 20
            RoundtripCount = 10
            CurrentPhase = ''
            NextAction = 'limit-reached'
            HandoffReadyCount = 0
            NextExpectedSourceTargetId = 'target06'
            NextExpectedTargetId = 'target02'
            NextExpectedHandoff = 'target06 -> target02'
            ConfiguredMaxRoundtripCount = 10
            LimitReached = $true
            Paused = $false
            UpdatedAt = (Get-Date).ToString('o')
        },
        [ordered]@{
            PairId = 'pair03'
            TopTargetId = 'target03'
            BottomTargetId = 'target07'
            SeedTargetId = 'target03'
            ForwardCount = 3
            RoundtripCount = 1
            CurrentPhase = ''
            NextAction = 'manual-review'
            HandoffReadyCount = 0
            NextExpectedSourceTargetId = 'target07'
            NextExpectedTargetId = 'target03'
            NextExpectedHandoff = 'target07 -> target03'
            ConfiguredMaxRoundtripCount = 0
            LimitReached = $false
            Paused = $false
            UpdatedAt = (Get-Date).ToString('o')
        },
        [ordered]@{
            PairId = 'pair04'
            TopTargetId = 'target04'
            BottomTargetId = 'target08'
            SeedTargetId = 'target04'
            ForwardCount = 6
            RoundtripCount = 3
            CurrentPhase = 'partner-running'
            NextAction = 'await-partner-output'
            HandoffReadyCount = 1
            NextExpectedSourceTargetId = 'target08'
            NextExpectedTargetId = 'target04'
            NextExpectedHandoff = 'target08 -> target04'
            ConfiguredMaxRoundtripCount = 0
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
$pairMap = @{}
foreach ($row in @($status.Pairs)) {
    $pairMap[[string]$row.PairId] = $row
}

Assert-True ($pairMap.Keys.Count -eq 4) 'status should surface all four pair rows.'
Assert-True ([string]$pairMap['pair01'].CurrentPhase -eq 'paused') 'pair01 should remain paused.'
Assert-True ([string]$pairMap['pair02'].CurrentPhase -eq 'limit-reached') 'pair02 should normalize to limit-reached.'
Assert-True ([string]$pairMap['pair03'].CurrentPhase -eq 'manual-attention') 'pair03 should normalize manual-review to manual-attention.'
Assert-True ([string]$pairMap['pair04'].CurrentPhase -eq 'partner-running') 'pair04 should preserve partner-running.'
Assert-True ([string]$pairMap['pair01'].NextAction -eq 'resume-required') 'pair01 should keep resume-required next action.'
Assert-True ([string]$pairMap['pair02'].NextAction -eq 'limit-reached') 'pair02 should keep limit-reached next action.'
Assert-True ([string]$pairMap['pair03'].NextAction -eq 'manual-review') 'pair03 should keep manual-review next action.'
Assert-True ([string]$pairMap['pair04'].NextExpectedHandoff -eq 'target08 -> target04') 'pair04 should surface next expected handoff.'
Assert-True ([string]$pairMap['pair04'].ProgressDetail -match '단계=partner-running') 'pair04 progress should include current phase.'
Assert-True ([string]$pairMap['pair04'].ProgressDetail -match '예정=target08 -> target04') 'pair04 progress should include next expected handoff.'

Write-Host ('show paired exchange status mixed pair states ok: runRoot=' + $runRoot)
