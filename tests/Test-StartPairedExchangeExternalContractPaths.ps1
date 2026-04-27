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
$externalFixtureRoot = 'C:\dev\python\_relay-test-fixtures'
$tmpRoot = Join-Path $externalFixtureRoot 'Test-StartPairedExchangeExternalContractPaths'
$workRepoRoot = Join-Path $tmpRoot 'work-repo'
$reviewRoot = Join-Path $workRepoRoot 'reviewfile'
$configPath = Join-Path $tmpRoot 'settings.external-contract.psd1'
$reviewInputPath = Join-Path $reviewRoot 'seed-input.zip'
$externalInboxRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\inbox'
$externalProcessedRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\processed'
$externalRuntimeRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\runtime'
$externalLogsRoot = Join-Path $workRepoRoot '.relay-bookkeeping\bottest-live-visible\logs'

New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath $reviewInputPath -Value 'seed-input' -Encoding UTF8

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$baseConfigText = Get-Content -LiteralPath $baseConfigPath -Raw -Encoding UTF8
$escapedWorkRepoRoot = $workRepoRoot.Replace("'", "''")
$escapedReviewInputPath = $reviewInputPath.Replace("'", "''")
$escapedInboxRoot = $externalInboxRoot.Replace("'", "''")
$escapedProcessedRoot = $externalProcessedRoot.Replace("'", "''")
$escapedRuntimeRoot = $externalRuntimeRoot.Replace("'", "''")
$escapedLogsRoot = $externalLogsRoot.Replace("'", "''")
$configText = $baseConfigText `
    -replace "DefaultSeedWorkRepoRoot = '.*?'", ("DefaultSeedWorkRepoRoot = '" + $escapedWorkRepoRoot + "'") `
    -replace "DefaultSeedReviewInputPath = '.*?'", ("DefaultSeedReviewInputPath = '" + $escapedReviewInputPath + "'") `
    -replace "ExternalWorkRepoContractRelativeRoot = '.*?'", "ExternalWorkRepoContractRelativeRoot = '.relay-contract\\external-contract-test'" `
    -replace "InboxRoot = '.*?'", ("InboxRoot = '" + $escapedInboxRoot + "'") `
    -replace "ProcessedRoot = '.*?'", ("ProcessedRoot = '" + $escapedProcessedRoot + "'") `
    -replace "RuntimeRoot = '.*?'", ("RuntimeRoot = '" + $escapedRuntimeRoot + "'") `
    -replace "LogsRoot = '.*?'", ("LogsRoot = '" + $escapedLogsRoot + "'")
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

$startOutput = @(
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $configPath `
        -IncludePairId pair01 `
        -SeedTargetId target01 2>&1
)
$startOutputText = ($startOutput | Out-String)
$runRootMatch = [regex]::Match($startOutputText, '(?im)^prepared pair test root:\s*(.+)$')
Assert-True ($runRootMatch.Success) 'prepared pair test root output should be present.'
$runRoot = $runRootMatch.Groups[1].Value.Trim()

$manifestPath = Join-Path $runRoot 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$target05 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)[0]

$expectedContractBase = Join-Path $workRepoRoot '.relay-contract\external-contract-test'
$expectedRunRootBase = Join-Path $workRepoRoot '.relay-runs\bottest-live-visible'
$expectedTarget01ContractRoot = Join-Path $expectedContractBase (Join-Path (Split-Path -Leaf $runRoot) 'pair01\target01')
$expectedTarget05ContractRoot = Join-Path $expectedContractBase (Join-Path (Split-Path -Leaf $runRoot) 'pair01\target05')
$expectedTarget01Outbox = Join-Path $expectedTarget01ContractRoot 'source-outbox'
$expectedTarget05Outbox = Join-Path $expectedTarget05ContractRoot 'source-outbox'
$expectedTarget01Summary = Join-Path $expectedTarget01Outbox 'summary.txt'
$expectedTarget01Zip = Join-Path $expectedTarget01Outbox 'review.zip'
$expectedTarget01Ready = Join-Path $expectedTarget01Outbox 'publish.ready.json'
$expectedTarget05Summary = Join-Path $expectedTarget05Outbox 'summary.txt'
$expectedTarget05Zip = Join-Path $expectedTarget05Outbox 'review.zip'
$expectedTarget05Ready = Join-Path $expectedTarget05Outbox 'publish.ready.json'

Assert-True ([string]$target01.ContractPathMode -eq 'external-workrepo') 'target01 should use external-workrepo contract mode.'
Assert-True ([string]$target05.ContractPathMode -eq 'external-workrepo') 'target05 should use external-workrepo contract mode.'
Assert-True ([string]$target01.ContractRootPath -eq $expectedTarget01ContractRoot) 'target01 should record external contract root.'
Assert-True ([string]$target05.ContractRootPath -eq $expectedTarget05ContractRoot) 'target05 should record external contract root.'
Assert-True ([string]$target01.SourceOutboxPath -eq $expectedTarget01Outbox) 'target01 should publish into external source-outbox.'
Assert-True ([string]$target01.SourceSummaryPath -eq $expectedTarget01Summary) 'target01 should publish summary into external repo contract path.'
Assert-True ([string]$target01.SourceReviewZipPath -eq $expectedTarget01Zip) 'target01 should publish review zip into external repo contract path.'
Assert-True ([string]$target01.PublishReadyPath -eq $expectedTarget01Ready) 'target01 should publish ready marker into external repo contract path.'
Assert-True ([string]$target05.SourceOutboxPath -eq $expectedTarget05Outbox) 'target05 should publish into external source-outbox.'
Assert-True ([string]$target05.SourceSummaryPath -eq $expectedTarget05Summary) 'target05 should publish summary into external repo contract path.'
Assert-True ([string]$target05.SourceReviewZipPath -eq $expectedTarget05Zip) 'target05 should publish review zip into external repo contract path.'
Assert-True ([string]$target05.PublishReadyPath -eq $expectedTarget05Ready) 'target05 should publish ready marker into external repo contract path.'
Assert-True ([string]$target01.WorkRepoRoot -eq $workRepoRoot) 'seed target should preserve external work repo root.'
Assert-True ([string]$target05.WorkRepoRoot -eq $workRepoRoot) 'partner target should inherit pair external work repo root.'
Assert-True ([bool]$manifest.ExternalWorkRepoUsed) 'manifest should mark external work repo usage.'
Assert-True ([bool]$manifest.PrimaryContractExternalized) 'manifest should mark primary contract externalization.'
Assert-True ([bool]$manifest.ExternalRunRootUsed) 'manifest should mark external run root usage.'
Assert-True ([bool]$manifest.BookkeepingExternalized) 'manifest should mark bookkeeping externalization when external bookkeeping roots are used.'
Assert-True ([bool]$manifest.FullExternalized) 'manifest should mark full externalization when contract, runroot, and bookkeeping are externalized.'
Assert-True ([bool]$manifest.ExternalContractPathsValidated) 'manifest should mark external contract path validation.'
Assert-True ([bool]$manifest.RunRootPathValidated) 'manifest should mark external run root validation.'
Assert-True (@($manifest.InternalResidualRoots).Count -ge 4) 'manifest should expose internal residual roots evidence.'
Assert-True ([string]@($manifest.InternalResidualRoots | Where-Object { [string]$_.Name -eq 'InboxRoot' } | Select-Object -First 1).Path -ne '') 'manifest should expose InboxRoot residual path.'
Assert-True ([string]@($manifest.InternalResidualRoots | Where-Object { [string]$_.Name -eq 'ProcessedRoot' } | Select-Object -First 1).Path -ne '') 'manifest should expose ProcessedRoot residual path.'
Assert-True ([string]@($manifest.InternalResidualRoots | Where-Object { [string]$_.Name -eq 'RuntimeRoot' } | Select-Object -First 1).Path -ne '') 'manifest should expose RuntimeRoot residual path.'
Assert-True ([string]@($manifest.InternalResidualRoots | Where-Object { [string]$_.Name -eq 'LogsRoot' } | Select-Object -First 1).Path -ne '') 'manifest should expose LogsRoot residual path.'
Assert-True ($runRoot.StartsWith($expectedRunRootBase, [System.StringComparison]::OrdinalIgnoreCase)) 'run root should be created under the external work repo run root base.'
Assert-True (-not $runRoot.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) 'run root should not be created under automation repo root.'
Assert-True (([string]$target01.ContractReferenceTimeUtc).Length -gt 0) 'target01 should record contract reference time.'
Assert-True (([string]$target05.ContractReferenceTimeUtc).Length -gt 0) 'target05 should record contract reference time.'
Assert-True ((Test-Path -LiteralPath $expectedTarget01Outbox -PathType Container)) 'target01 external source-outbox folder should be created.'
Assert-True ((Test-Path -LiteralPath (Join-Path $expectedTarget01Outbox '.published') -PathType Container)) 'target01 external published archive folder should be created.'
Assert-True ((Test-Path -LiteralPath $expectedTarget05Outbox -PathType Container)) 'target05 external source-outbox folder should be created.'
Assert-True ((Test-Path -LiteralPath (Join-Path $expectedTarget05Outbox '.published') -PathType Container)) 'target05 external published archive folder should be created.'

Write-Host ('start paired exchange external contract paths ok: runRoot=' + $runRoot)
