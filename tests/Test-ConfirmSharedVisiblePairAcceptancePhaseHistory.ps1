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
$sourcePath = Join-Path $root 'tests\Confirm-SharedVisiblePairAcceptance.ps1'
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)

foreach ($functionName in @(
        'Test-SuccessAcceptanceState',
        'Test-VisibleReceiptRoundtripSatisfied'
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

$runSummary = [pscustomobject]@{
    Acceptance = [pscustomobject]@{
        Stage = 'completed'
        AcceptanceState = 'roundtrip-confirmed'
        SeedOutboxPublished = $false
        SeedFinalState = ''
        SeedSubmitState = ''
    }
}
$pairedStatus = [pscustomobject]@{
    AcceptanceReceipt = [pscustomobject]@{
        Exists = $true
        AcceptanceState = 'preflight-passed'
    }
}
$sourceOutboxCloseout = [pscustomobject]@{
    AcceptedCount = 2
}

Assert-True (Test-VisibleReceiptRoundtripSatisfied -RunSummary $runSummary -PairedStatus $pairedStatus -SourceOutboxCloseout $sourceOutboxCloseout) 'phase-history roundtrip with source-outbox acceptance should satisfy receipt-required confirm even when the current receipt state is preflight-passed.'

Write-Host 'confirm shared visible phase-history receipt helper ok'
