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
$sourcePath = Join-Path $root 'show-paired-run-summary.ps1'
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)

foreach ($functionName in @(
        'Test-NonEmptyString',
        'Get-ObjectPropertyValue',
        'Test-SuccessAcceptanceState',
        'Get-AcceptanceSummary',
        'Get-OverallState'
    )) {
    $functionAst = @(
        $scriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) |
            Select-Object -First 1
    )
    Assert-True (@($functionAst).Count -eq 1) ("missing function: " + $functionName)
    Invoke-Expression $functionAst[0].Extent.Text
}

$receipt = [pscustomobject]@{
    Stage = 'completed'
    Outcome = [pscustomobject]@{
        AcceptanceState = 'preflight-passed'
        AcceptanceReason = 'visible-worker-preflight-passed'
    }
    Seed = [pscustomobject]@{
        FinalState = ''
        SubmitState = ''
        OutboxPublished = $false
    }
    RelayIssues = [pscustomobject]@{
        RelayFolderMismatchCount = 0
        RelayFolderMissingCount = 0
        RelayFolderConfigMissingCount = 0
        Source = 'current-receipt'
    }
    PhaseHistory = @(
        [pscustomobject]@{
            RecordedAt = '2026-04-25T02:28:39+09:00'
            Stage = 'completed'
            AcceptanceState = 'roundtrip-confirmed'
            AcceptanceReason = 'forwarded-state-roundtrip-detected'
            SeedFinalState = ''
            SeedSubmitState = ''
            SeedOutboxPublished = $false
            RelayFolderMismatchCount = 1
            RelayFolderMissingCount = 0
            RelayFolderConfigMissingCount = 0
            RelayIssuesSource = 'phase-history'
        },
        [pscustomobject]@{
            RecordedAt = '2026-04-25T02:38:56+09:00'
            Stage = 'completed'
            AcceptanceState = 'preflight-passed'
            AcceptanceReason = 'visible-worker-preflight-passed'
            SeedFinalState = ''
            SeedSubmitState = ''
            SeedOutboxPublished = $false
            RelayFolderMismatchCount = 0
            RelayFolderMissingCount = 0
            RelayFolderConfigMissingCount = 0
            RelayIssuesSource = 'phase-history'
        }
    )
}
$status = [pscustomobject]@{
    AcceptanceReceipt = [pscustomobject]@{
        Path = 'C:\runs\acceptance\.state\live-acceptance-result.json'
        AcceptanceState = 'preflight-passed'
        AcceptanceReason = 'visible-worker-preflight-passed'
    }
    Counts = [pscustomobject]@{
        FailureLineCount = 0
        ManualAttentionCount = 0
        SubmitUnconfirmedCount = 0
        TargetUnresponsiveCount = 0
    }
}

$summary = Get-AcceptanceSummary -AcceptanceReceipt $receipt -Status $status
Assert-True ([string]$summary.AcceptanceState -eq 'roundtrip-confirmed') 'summary should prefer phase-history roundtrip-confirmed over trailing preflight-only state.'
Assert-True ([string]$summary.CurrentAcceptanceState -eq 'preflight-passed') 'summary should still expose the trailing current acceptance state.'
Assert-True ([string]$summary.EffectiveSource -eq 'phase-history') 'summary should report phase-history as effective source when it overrides the current receipt.'
Assert-True ([int]$summary.RelayFolderMismatchCount -eq 1) 'summary should prefer phase-history relay mismatch counts over trailing receipt values.'
Assert-True ([string]$summary.RelayIssuesSource -eq 'phase-history') 'summary should report relay issue source from the effective phase-history entry.'
Assert-True ([int]$summary.CurrentRelayFolderMismatchCount -eq 0) 'summary should still expose the trailing current receipt relay mismatch count.'

$overallState = Get-OverallState -AcceptanceSummary $summary -Status $status
Assert-True ([string]$overallState -eq 'success') 'overall state should be success when phase-history contains a completed roundtrip-confirmed acceptance.'

$postCleanupSummary = [pscustomobject]@{
    Stage = 'post-cleanup'
    AcceptanceState = 'roundtrip-confirmed'
}
$postCleanupOverallState = Get-OverallState -AcceptanceSummary $postCleanupSummary -Status $status
Assert-True ([string]$postCleanupOverallState -eq 'success') 'post-cleanup roundtrip-confirmed should remain a successful closeout state.'

Write-Host 'show-paired-run-summary effective acceptance helper ok'
