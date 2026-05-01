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
$tmpRoot = Join-Path $externalFixtureRoot 'Test-StartPairedExchangeMultiRepoPairRunRoots'
$repoARoot = Join-Path $tmpRoot 'repo-a'
$repoBRoot = Join-Path $tmpRoot 'repo-b'
$coordinatorRoot = Join-Path $tmpRoot 'repo-coordinator'
$repoAReviewRoot = Join-Path $repoARoot 'reviewfile'
$repoAReviewInputPath = Join-Path $repoAReviewRoot 'seed-input.zip'
$configPath = Join-Path $tmpRoot 'settings.multi-repo.psd1'
$explicitRunRoot = Join-Path $coordinatorRoot '.relay-runs\bottest-live-visible\run_mixed_pair_repo_test'
$coordinatorInboxRoot = Join-Path $coordinatorRoot '.relay-bookkeeping\bottest-live-visible\inbox'
$coordinatorProcessedRoot = Join-Path $coordinatorRoot '.relay-bookkeeping\bottest-live-visible\processed'
$coordinatorRuntimeRoot = Join-Path $coordinatorRoot '.relay-bookkeeping\bottest-live-visible\runtime'
$coordinatorLogsRoot = Join-Path $coordinatorRoot '.relay-bookkeeping\bottest-live-visible\logs'

New-Item -ItemType Directory -Path $repoAReviewRoot -Force | Out-Null
New-Item -ItemType Directory -Path $repoBRoot -Force | Out-Null
New-Item -ItemType Directory -Path $coordinatorRoot -Force | Out-Null
Set-Content -LiteralPath $repoAReviewInputPath -Value 'seed-input' -Encoding UTF8

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$baseConfigText = Get-Content -LiteralPath $baseConfigPath -Raw -Encoding UTF8
$escapedRepoARoot = $repoARoot.Replace("'", "''")
$escapedRepoBRoot = $repoBRoot.Replace("'", "''")
$escapedReviewInputPath = $repoAReviewInputPath.Replace("'", "''")
$escapedInboxRoot = $coordinatorInboxRoot.Replace("'", "''")
$escapedProcessedRoot = $coordinatorProcessedRoot.Replace("'", "''")
$escapedRuntimeRoot = $coordinatorRuntimeRoot.Replace("'", "''")
$escapedLogsRoot = $coordinatorLogsRoot.Replace("'", "''")
$configText = $baseConfigText `
    -replace "DefaultSeedWorkRepoRoot = '.*?'", ("DefaultSeedWorkRepoRoot = '" + $escapedRepoARoot + "'") `
    -replace "DefaultSeedReviewInputPath = '.*?'", ("DefaultSeedReviewInputPath = '" + $escapedReviewInputPath + "'") `
    -replace "ExternalWorkRepoContractRelativeRoot = '.*?'", "ExternalWorkRepoContractRelativeRoot = '.relay-contract\\external-multi-repo-test'" `
    -replace "InboxRoot = '.*?'", ("InboxRoot = '" + $escapedInboxRoot + "'") `
    -replace "ProcessedRoot = '.*?'", ("ProcessedRoot = '" + $escapedProcessedRoot + "'") `
    -replace "RuntimeRoot = '.*?'", ("RuntimeRoot = '" + $escapedRuntimeRoot + "'") `
    -replace "LogsRoot = '.*?'", ("LogsRoot = '" + $escapedLogsRoot + "'")
$configText = [regex]::Replace(
    $configText,
    "(?s)(pair02\s*=\s*@\{\s*.*?DefaultSeedTargetId\s*=\s*'target02'\s*)",
    ('$1' + "                DefaultSeedWorkRepoRoot = '" + $escapedRepoBRoot + "'`r`n")
)
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

$startOutput = @(
    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $configPath `
        -IncludePairId @('pair01','pair02') `
        -SeedTargetId target01 `
        -RunRoot $explicitRunRoot 2>&1
)
$runRoot = [System.IO.Path]::GetFullPath($explicitRunRoot)

$manifestPath = Join-Path $runRoot 'manifest.json'
Assert-True ((Test-Path -LiteralPath $manifestPath -PathType Leaf)) 'mixed pair repo manifest should be created at the explicit coordinator run root.'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pair01 = @($manifest.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)[0]
$pair02 = @($manifest.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)[0]
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$target05 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)[0]
$target02 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
$target06 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target06' } | Select-Object -First 1)[0]

$runLeaf = Split-Path -Leaf $runRoot
$expectedPair01Root = Join-Path $repoARoot (Join-Path '.relay-runs\bottest-live-visible' (Join-Path $runLeaf 'pair01'))
$expectedPair02Root = Join-Path $repoBRoot (Join-Path '.relay-runs\bottest-live-visible' (Join-Path $runLeaf 'pair02'))
$expectedTarget01Root = Join-Path $expectedPair01Root 'target01'
$expectedTarget05Root = Join-Path $expectedPair01Root 'target05'
$expectedTarget02Root = Join-Path $expectedPair02Root 'target02'
$expectedTarget06Root = Join-Path $expectedPair02Root 'target06'
$expectedTarget01Outbox = Join-Path $repoARoot (Join-Path '.relay-contract\external-multi-repo-test' (Join-Path $runLeaf 'pair01\target01\source-outbox'))
$expectedTarget02Outbox = Join-Path $repoBRoot (Join-Path '.relay-contract\external-multi-repo-test' (Join-Path $runLeaf 'pair02\target02\source-outbox'))

Assert-True ([System.IO.Path]::GetFullPath($runRoot) -eq [System.IO.Path]::GetFullPath($explicitRunRoot)) 'mixed pair test should honor explicit coordinator run root.'
Assert-True ([string]$manifest.CoordinatorWorkRepoRoot -eq [System.IO.Path]::GetFullPath($coordinatorRoot)) 'manifest should expose coordinator work repo root.'
Assert-True ([string]$pair01.PairRunRoot -eq $expectedPair01Root) 'pair01 should use repo A pair run root.'
Assert-True ([string]$pair02.PairRunRoot -eq $expectedPair02Root) 'pair02 should use repo B pair run root.'
Assert-True ([string]$target01.PairRunRoot -eq $expectedPair01Root) 'target01 should record pair01 run root.'
Assert-True ([string]$target02.PairRunRoot -eq $expectedPair02Root) 'target02 should record pair02 run root.'
Assert-True ([string]$target01.TargetFolder -eq $expectedTarget01Root) 'target01 folder should live under repo A.'
Assert-True ([string]$target05.TargetFolder -eq $expectedTarget05Root) 'target05 folder should live under repo A.'
Assert-True ([string]$target02.TargetFolder -eq $expectedTarget02Root) 'target02 folder should live under repo B.'
Assert-True ([string]$target06.TargetFolder -eq $expectedTarget06Root) 'target06 folder should live under repo B.'
Assert-True ([string]$target01.WorkRepoRoot -eq $repoARoot) 'target01 should keep repo A as effective work repo.'
Assert-True ([string]$target02.WorkRepoRoot -eq $repoBRoot) 'target02 should keep repo B as effective work repo.'
Assert-True ([string]$target01.SourceOutboxPath -eq $expectedTarget01Outbox) 'target01 should publish to repo A contract path.'
Assert-True ([string]$target02.SourceOutboxPath -eq $expectedTarget02Outbox) 'target02 should publish to repo B contract path.'
Assert-True ([bool]$manifest.ExternalWorkRepoUsed) 'manifest should mark external work repo usage.'
Assert-True ([bool]$manifest.PrimaryContractExternalized) 'manifest should mark primary contract externalization.'
Assert-True ([bool]$manifest.ExternalRunRootUsed) 'manifest should mark external run root usage.'
Assert-True ([bool]$manifest.BookkeepingExternalized) 'manifest should mark bookkeeping externalization when shared external bookkeeping roots are used.'
Assert-True ([bool]$manifest.FullExternalized) 'manifest should mark full externalization for mixed pair external run roots and contract paths.'
Assert-True ((Test-Path -LiteralPath $expectedTarget01Root -PathType Container)) 'target01 pair-local target folder should be created.'
Assert-True ((Test-Path -LiteralPath $expectedTarget02Root -PathType Container)) 'target02 pair-local target folder should be created.'
Assert-True ((Test-Path -LiteralPath $expectedTarget01Outbox -PathType Container)) 'target01 pair-local source outbox should be created.'
Assert-True ((Test-Path -LiteralPath $expectedTarget02Outbox -PathType Container)) 'target02 pair-local source outbox should be created.'

Write-Host ('start paired exchange mixed pair run roots ok: runRoot=' + $runRoot)
