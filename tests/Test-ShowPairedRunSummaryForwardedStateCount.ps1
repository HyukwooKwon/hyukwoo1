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
$tempRoot = Join-Path $root ('_tmp\show-paired-run-summary-forwarded-state_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $scriptCopyPath = Join-Path $tempRoot 'show-paired-run-summary.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'show-paired-run-summary.ps1') -Destination $scriptCopyPath -Force
    $helperCopyPath = Join-Path $tempRoot 'tests\lib\PairedSourceOutboxPaths.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $helperCopyPath) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'tests\lib\PairedSourceOutboxPaths.ps1') -Destination $helperCopyPath -Force

    $runRoot = Join-Path $tempRoot 'run_forwarded_state'
    $stateRoot = Join-Path $runRoot '.state'
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

    [pscustomobject]@{
        Stage = 'post-cleanup'
        Outcome = [pscustomobject]@{
            AcceptanceState = 'roundtrip-confirmed'
            AcceptanceReason = 'forwarded-state-roundtrip-detected'
        }
        Seed = [pscustomobject]@{
            FinalState = 'publish-detected'
            SubmitState = 'confirmed'
            OutboxPublished = $true
        }
        RelayIssues = [pscustomobject]@{
            RelayFolderMismatchCount = 0
            RelayFolderMissingCount = 0
            RelayFolderConfigMissingCount = 0
            Source = 'test'
        }
        PhaseHistory = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'live-acceptance-result.json') -Encoding UTF8

    @'
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [int]$RecentFailureCount,
    [switch]$AsJson
)

[pscustomobject]@{
    RunRoot = $RunRoot
    AcceptanceReceipt = [pscustomobject]@{
        Path = (Join-Path $RunRoot '.state\live-acceptance-result.json')
        AcceptanceState = 'roundtrip-confirmed'
        AcceptanceReason = 'forwarded-state-roundtrip-detected'
    }
    Watcher = [pscustomobject]@{
        Status = 'stopped'
        StatusReason = 'import-source-outbox-complete'
        LastHandledResult = ''
        LastHandledAt = ''
        HeartbeatAt = '2026-06-20T10:55:00+09:00'
        HeartbeatAgeSeconds = 1
        StatusFileUpdatedAt = '2026-06-20T10:55:00+09:00'
        StatusPath = (Join-Path $RunRoot '.state\watcher-status.json')
    }
    Counts = [pscustomobject]@{
        MessageFiles = 8
        ForwardedCount = 1
        ForwardedStateCount = 2
        SummaryPresentCount = 2
        ZipPresentCount = 2
        DonePresentCount = 2
        FailureLineCount = 0
        RelayFolderMismatchCount = 0
        RelayFolderMissingCount = 0
        RelayFolderConfigMissingCount = 0
        ManualAttentionCount = 0
        SubmitUnconfirmedCount = 0
        TargetUnresponsiveCount = 0
        FocusLostObservedCount = 0
        FocusLostRecoveredCount = 0
        ReadyToForwardCount = 1
        DispatchRunningCount = 0
    }
    Targets = @()
    Pairs = @()
} | ConvertTo-Json -Depth 8
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'show-paired-exchange-status.ps1') -Encoding UTF8

    $configPath = Join-Path $tempRoot 'settings.psd1'
    '@{}' | Set-Content -LiteralPath $configPath -Encoding UTF8

    $raw = & $scriptCopyPath -ConfigPath $configPath -RunRoot $runRoot -AsJson
    $summary = $raw | ConvertFrom-Json
    Assert-True ([string]$summary.SummaryLine -match 'forwarded=2\b') 'SummaryLine should use ForwardedStateCount for forwarded display.'
    Assert-True ([int]$summary.Counts.ForwardedCount -eq 1) 'Counts should preserve raw forwarded target count.'
    Assert-True ([int]$summary.Counts.ForwardedStateCount -eq 2) 'Counts should expose forwarded state count.'

    $importantText = Get-Content -LiteralPath $summary.ImportantSummary.TextPath -Raw -Encoding UTF8
    Assert-True ($importantText -match 'Counts: forwarded=2 summaries=2 zips=2 failures=0') 'Important summary text should use ForwardedStateCount for forwarded display.'

    Write-Host 'show-paired-run-summary forwarded-state count display ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
