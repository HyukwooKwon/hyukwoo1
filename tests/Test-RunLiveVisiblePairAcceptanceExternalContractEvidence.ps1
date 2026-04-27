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
$scriptPath = Join-Path $root 'tests\Run-LiveVisiblePairAcceptance.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

Assert-True ($scriptText.Contains('function Get-RunContractEvidence')) 'acceptance script should define external contract evidence helper.'
Assert-True ($scriptText.Contains('ExternalWorkRepoUsed')) 'acceptance receipt should expose ExternalWorkRepoUsed.'
Assert-True ($scriptText.Contains('PrimaryContractExternalized')) 'acceptance receipt should expose PrimaryContractExternalized.'
Assert-True ($scriptText.Contains('ExternalRunRootUsed')) 'acceptance receipt should expose ExternalRunRootUsed.'
Assert-True ($scriptText.Contains('BookkeepingExternalized')) 'acceptance receipt should expose BookkeepingExternalized.'
Assert-True ($scriptText.Contains('FullExternalized')) 'acceptance receipt should expose FullExternalized.'
Assert-True ($scriptText.Contains('ExternalContractPathsValidated')) 'acceptance receipt should expose ExternalContractPathsValidated.'
Assert-True ($scriptText.Contains('RunRootPathValidated')) 'acceptance receipt should expose RunRootPathValidated.'
Assert-True ($scriptText.Contains('InternalResidualRoots')) 'acceptance receipt should expose InternalResidualRoots.'
Assert-True ($scriptText.Contains('ContractReferenceTimeUtc')) 'acceptance receipt should expose ContractReferenceTimeUtc.'
Assert-True ($scriptText.Contains('SourceSummaryPath')) 'acceptance receipt should expose SourceSummaryPath.'
Assert-True ($scriptText.Contains('PublishReadyPath')) 'acceptance receipt should expose PublishReadyPath.'

Write-Host 'run-live-visible-pair-acceptance external contract evidence wiring ok'
