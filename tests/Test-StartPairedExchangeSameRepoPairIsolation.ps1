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
$tmpRoot = Join-Path $externalFixtureRoot 'Test-StartPairedExchangeSameRepoPairIsolation'
$sharedRepoRoot = Join-Path $tmpRoot 'shared-work-repo'
$reviewRoot = Join-Path $sharedRepoRoot 'reviewfile'
$reviewInputPath = Join-Path $reviewRoot 'seed-input.zip'
$configPath = Join-Path $tmpRoot 'settings.same-repo.psd1'
$explicitRunRoot = Join-Path $sharedRepoRoot '.relay-runs\bottest-live-visible\run_same_repo_pair_test'
$bookkeepingRoot = Join-Path $sharedRepoRoot '.relay-bookkeeping\bottest-live-visible'
$inboxRoot = Join-Path $bookkeepingRoot 'inbox'
$processedRoot = Join-Path $bookkeepingRoot 'processed'
$runtimeRoot = Join-Path $bookkeepingRoot 'runtime'
$logsRoot = Join-Path $bookkeepingRoot 'logs'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
Set-Content -LiteralPath $reviewInputPath -Value 'seed-input' -Encoding UTF8

$baseConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
$baseConfigText = Get-Content -LiteralPath $baseConfigPath -Raw -Encoding UTF8
$escapedSharedRepoRoot = $sharedRepoRoot.Replace("'", "''")
$escapedReviewInputPath = $reviewInputPath.Replace("'", "''")
$escapedInboxRoot = $inboxRoot.Replace("'", "''")
$escapedProcessedRoot = $processedRoot.Replace("'", "''")
$escapedRuntimeRoot = $runtimeRoot.Replace("'", "''")
$escapedLogsRoot = $logsRoot.Replace("'", "''")
$configText = $baseConfigText `
    -replace "DefaultSeedWorkRepoRoot = '.*?'", ("DefaultSeedWorkRepoRoot = '" + $escapedSharedRepoRoot + "'") `
    -replace "DefaultSeedReviewInputPath = '.*?'", ("DefaultSeedReviewInputPath = '" + $escapedReviewInputPath + "'") `
    -replace "ExternalWorkRepoContractRelativeRoot = '.*?'", "ExternalWorkRepoContractRelativeRoot = '.relay-contract\\external-same-repo-test'" `
    -replace "InboxRoot = '.*?'", ("InboxRoot = '" + $escapedInboxRoot + "'") `
    -replace "ProcessedRoot = '.*?'", ("ProcessedRoot = '" + $escapedProcessedRoot + "'") `
    -replace "RuntimeRoot = '.*?'", ("RuntimeRoot = '" + $escapedRuntimeRoot + "'") `
    -replace "LogsRoot = '.*?'", ("LogsRoot = '" + $escapedLogsRoot + "'")
$configText = [regex]::Replace(
    $configText,
    "(?s)(pair02\s*=\s*@\{\s*.*?DefaultSeedTargetId\s*=\s*'target02'\s*)",
    ('$1' + "                DefaultSeedWorkRepoRoot = '" + $escapedSharedRepoRoot + "'`r`n")
)
Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8

@(
    & (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
        -ConfigPath $configPath `
        -IncludePairId @('pair01', 'pair02') `
        -SeedTargetId target01 `
        -RunRoot $explicitRunRoot 2>&1
) | Out-Null

$runRoot = [System.IO.Path]::GetFullPath($explicitRunRoot)
$manifestPath = Join-Path $runRoot 'manifest.json'
Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'same-repo pair manifest should be created.'

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pair01 = @($manifest.Pairs | Where-Object { [string]$_.PairId -eq 'pair01' } | Select-Object -First 1)[0]
$pair02 = @($manifest.Pairs | Where-Object { [string]$_.PairId -eq 'pair02' } | Select-Object -First 1)[0]
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$target05 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target05' } | Select-Object -First 1)[0]
$target02 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
$target06 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target06' } | Select-Object -First 1)[0]

$runLeaf = Split-Path -Leaf $runRoot
$expectedPair01Root = Join-Path $sharedRepoRoot (Join-Path '.relay-runs\bottest-live-visible' (Join-Path $runLeaf 'pair01'))
$expectedPair02Root = Join-Path $sharedRepoRoot (Join-Path '.relay-runs\bottest-live-visible' (Join-Path $runLeaf 'pair02'))
$expectedTarget01Outbox = Join-Path $sharedRepoRoot (Join-Path '.relay-contract\external-same-repo-test' (Join-Path $runLeaf 'pair01\target01\source-outbox'))
$expectedTarget05Outbox = Join-Path $sharedRepoRoot (Join-Path '.relay-contract\external-same-repo-test' (Join-Path $runLeaf 'pair01\target05\source-outbox'))
$expectedTarget02Outbox = Join-Path $sharedRepoRoot (Join-Path '.relay-contract\external-same-repo-test' (Join-Path $runLeaf 'pair02\target02\source-outbox'))
$expectedTarget06Outbox = Join-Path $sharedRepoRoot (Join-Path '.relay-contract\external-same-repo-test' (Join-Path $runLeaf 'pair02\target06\source-outbox'))

Assert-True ([string]$pair01.PairRunRoot -eq $expectedPair01Root) 'pair01 run root should stay under the shared repo but remain pair-scoped.'
Assert-True ([string]$pair02.PairRunRoot -eq $expectedPair02Root) 'pair02 run root should stay under the shared repo but remain pair-scoped.'
Assert-True ([string]$pair01.PairRunRoot -ne [string]$pair02.PairRunRoot) 'pair01 and pair02 run roots must differ even when WorkRepoRoot is shared.'

foreach ($target in @($target01, $target05, $target02, $target06)) {
    Assert-True ([string]$target.WorkRepoRoot -eq $sharedRepoRoot) ("target should keep the shared repo root: {0}" -f [string]$target.TargetId)
}

Assert-True ([string]$target01.SourceOutboxPath -eq $expectedTarget01Outbox) 'target01 outbox should be pair01/target01 scoped under the shared repo.'
Assert-True ([string]$target05.SourceOutboxPath -eq $expectedTarget05Outbox) 'target05 outbox should be pair01/target05 scoped under the shared repo.'
Assert-True ([string]$target02.SourceOutboxPath -eq $expectedTarget02Outbox) 'target02 outbox should be pair02/target02 scoped under the shared repo.'
Assert-True ([string]$target06.SourceOutboxPath -eq $expectedTarget06Outbox) 'target06 outbox should be pair02/target06 scoped under the shared repo.'
Assert-True ([string]$target01.SourceOutboxPath -ne [string]$target02.SourceOutboxPath) 'pair01 and pair02 must not share the same source outbox path.'
Assert-True ([string]$target05.SourceOutboxPath -ne [string]$target06.SourceOutboxPath) 'bottom targets across pairs must not share the same source outbox path.'

foreach ($path in @(
    [string]$target01.SourceOutboxPath,
    [string]$target05.SourceOutboxPath,
    [string]$target02.SourceOutboxPath,
    [string]$target06.SourceOutboxPath
)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Container) ("source outbox should exist: {0}" -f $path)
    Assert-True ($path.StartsWith($sharedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) ("source outbox should stay under shared repo root: {0}" -f $path)
}

Assert-True ([bool]$manifest.ExternalWorkRepoUsed) 'manifest should record external work repo usage.'
Assert-True ([bool]$manifest.PrimaryContractExternalized) 'manifest should record primary contract externalization.'
Assert-True ([bool]$manifest.ExternalRunRootUsed) 'manifest should record external run root usage.'
Assert-True ([bool]$manifest.BookkeepingExternalized) 'manifest should record bookkeeping externalization.'
Assert-True ([bool]$manifest.FullExternalized) 'manifest should record full externalization.'

Write-Host ('start paired exchange same repo pair isolation ok: runRoot=' + $runRoot)
