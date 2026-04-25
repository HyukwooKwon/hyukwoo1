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

    $result = if ($Condition -is [System.Array]) {
        ($Condition.Count -gt 0)
    }
    else {
        [bool]$Condition
    }

    if (-not $result) {
        throw $Message
    }
}

$root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$runRoot = Join-Path $root ('pair-test\bottest-live-visible\run_contract_confirm_four_pair_soak_closeout_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01,pair02,pair03,pair04 | Out-Null

$stateRoot = Join-Path $runRoot '.state'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$now = (Get-Date).ToString('o')

@{
    SchemaVersion              = '1.0.0'
    RunRoot                    = $runRoot
    State                      = 'stopped'
    UpdatedAt                  = $now
    HeartbeatAt                = $now
    StatusSequence             = 12
    ProcessStartedAt           = $now
    Reason                     = 'manual-stop'
    StopCategory               = 'manual-stop'
    ForwardedCount             = 8
    ConfiguredMaxForwardCount  = 0
    ConfiguredRunDurationSec   = 3600
    ConfiguredMaxRoundtripCount = 0
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'watcher-status.json') -Encoding UTF8

$finalPairs = @(
    [pscustomobject]@{
        PairId = 'pair01'
        CurrentPhase = 'waiting-handoff'
        RoundtripCount = 2
        ForwardedStateCount = 4
        HandoffReadyCount = 1
        NextExpectedHandoff = 'target01->target05'
        PolicySeedTargetId = 'target01'
        ConfiguredMaxRoundtripCount = 0
    }
    [pscustomobject]@{
        PairId = 'pair02'
        CurrentPhase = 'limit-reached'
        RoundtripCount = 1
        ForwardedStateCount = 2
        HandoffReadyCount = 0
        NextExpectedHandoff = ''
        PolicySeedTargetId = 'target02'
        ConfiguredMaxRoundtripCount = 1
    }
    [pscustomobject]@{
        PairId = 'pair03'
        CurrentPhase = 'manual-attention'
        RoundtripCount = 1
        ForwardedStateCount = 2
        HandoffReadyCount = 0
        NextExpectedHandoff = ''
        PolicySeedTargetId = 'target03'
        ConfiguredMaxRoundtripCount = 0
    }
    [pscustomobject]@{
        PairId = 'pair04'
        CurrentPhase = 'completed'
        RoundtripCount = 2
        ForwardedStateCount = 4
        HandoffReadyCount = 0
        NextExpectedHandoff = ''
        PolicySeedTargetId = 'target04'
        ConfiguredMaxRoundtripCount = 0
    }
)

@{
    SchemaVersion = '1.0.0'
    GeneratedAt   = $now
    Pairs         = $finalPairs
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'pair-state.json') -Encoding UTF8

$receipt = [pscustomobject]@{
    SchemaVersion = '1.0.0'
    GeneratedAt = $now
    ExecutionMode = 'execute'
    ConfigPath = $resolvedConfigPath
    RunRoot = $runRoot
    PlannedReceiptPath = (Join-Path $stateRoot 'four-pair-soak-receipt.json')
    CloseoutThresholds = [pscustomobject]@{
        MinRequiredSoakDurationMinutes = 60
        MaxAllowedManualAttentionCount = 4
        MaxAllowedWatcherRestartCount = 1
        MaxAllowedPauseRequestCount = 1
        MaxAllowedResumeRequestCount = 1
        MinRequiredSnapshotCount = 3
        RequiredFinalWatcherStatus = 'stopped'
        ExpectedPairCount = 4
    }
    Execution = [pscustomobject]@{
        Summary = [pscustomobject]@{
            SnapshotCount = 5
            FirstSnapshotAt = ((Get-Date).AddMinutes(-65).ToString('o'))
            LastSnapshotAt = $now
            ActualDurationMinutes = 65.0
            PauseRequestCount = 1
            ResumeRequestCount = 1
            WatcherRestartCount = 1
            MaxManualAttentionCount = 1
            MaxHandoffReadyCount = 2
            MaxForwardedStateCount = 8
            FinalWatcherStatus = 'stopped'
            FinalWatcherReason = 'manual-stop'
            FinalPairs = $finalPairs
        }
    }
}
$receiptPath = Join-Path $stateRoot 'four-pair-soak-receipt.json'
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receiptPath -Encoding UTF8

$powershellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop | Select-Object -First 1).Source
$passRaw = & $powershellPath `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File (Join-Path $root 'tests\Confirm-FourPairMixedSoakCloseout.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -KnownLimitationsReviewed `
    -KnownLimitationsReviewNote 'reviewed-by-test' `
    -AsJson
if ($LASTEXITCODE -ne 0) {
    throw ("Confirm-FourPairMixedSoakCloseout.ps1 failed: " + (($passRaw | Out-String).Trim()))
}
$passResult = ($passRaw | ConvertFrom-Json)

Assert-True ([bool]$passResult.Passed) 'Expected closeout confirmation to pass for matching receipt and status.'
Assert-True ([bool]$passResult.StatusAgreement.WatcherStatusMatch) 'Expected watcher status agreement to pass.'
Assert-True ([bool]$passResult.StatusAgreement.PairAgreementPassed) 'Expected pair agreement to pass.'
Assert-True ([bool]$passResult.KnownLimitationsReviewed) 'Expected known limitations reviewed flag to be persisted.'
Assert-True ([string]$passResult.KnownLimitationsReviewNote -eq 'reviewed-by-test') 'Expected known limitations review note to be persisted.'
Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'four-pair-soak-closeout.json') -PathType Leaf) 'Expected closeout record to be written.'
Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'four-pair-soak-summary.txt') -PathType Leaf) 'Expected one-page summary text to be written.'

$failRaw = & $powershellPath `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File (Join-Path $root 'tests\Confirm-FourPairMixedSoakCloseout.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -MaxAllowedManualAttentionCount 0 `
    -AsJson
if ($LASTEXITCODE -ne 0) {
    throw ("Confirm-FourPairMixedSoakCloseout.ps1 strict run failed: " + (($failRaw | Out-String).Trim()))
}
$failResult = ($failRaw | ConvertFrom-Json)

Assert-True (-not [bool]$failResult.Passed) 'Expected strict closeout confirmation to fail.'
Assert-True (@($failResult.Checks | Where-Object { [string]$_.Name -eq 'maximum-manual-attention-count' -and -not [bool]$_.Passed }).Count -eq 1) 'Expected manual attention threshold failure to be reported.'

Write-Host ('confirm-four-pair-mixed-soak-closeout contract ok: runRoot=' + $runRoot)
