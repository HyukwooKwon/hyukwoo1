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

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) ("proof file missing: {0}" -f $Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$root = Split-Path -Parent $PSScriptRoot
$reviewRoot = Join-Path $root 'reviewfile'

$externalContractProof = Read-JsonFile -Path (Join-Path $reviewRoot 'proof_external_contract_paths.json')
$externalRunRootProof = Read-JsonFile -Path (Join-Path $reviewRoot 'proof_external_runroot_state.json')
$roundtripMatrixProof = Read-JsonFile -Path (Join-Path $reviewRoot 'proof_multi_repo_roundtrip_matrix.json')
$pairRunRootsProof = Read-JsonFile -Path (Join-Path $reviewRoot 'proof_multi_repo_pair_runroots.json')
$pairScopedConfigProof = Read-JsonFile -Path (Join-Path $reviewRoot 'proof_pair_scoped_externalized_configs.json')

foreach ($proof in @($externalContractProof, $externalRunRootProof)) {
    Assert-True ([bool]$proof.ExternalWorkRepoUsed) 'external contract/runroot proof should mark ExternalWorkRepoUsed.'
    Assert-True ([bool]$proof.PrimaryContractExternalized) 'external contract/runroot proof should mark PrimaryContractExternalized.'
    Assert-True ([bool]$proof.ExternalRunRootUsed) 'external contract/runroot proof should mark ExternalRunRootUsed.'
    Assert-True ([bool]$proof.BookkeepingExternalized) 'external contract/runroot proof should mark BookkeepingExternalized.'
    Assert-True ([bool]$proof.FullExternalized) 'external contract/runroot proof should mark FullExternalized.'
    Assert-True ([bool]$proof.ExternalContractPathsValidated) 'external contract/runroot proof should mark ExternalContractPathsValidated.'
    Assert-True ([bool]$proof.RunRootPathValidated) 'external contract/runroot proof should mark RunRootPathValidated.'
    Assert-True (@($proof.InternalResidualRoots).Count -ge 4) 'external contract/runroot proof should include bookkeeping roots evidence.'
    Assert-True (@($proof.Targets).Count -ge 2) 'external contract/runroot proof should include target evidence rows.'
}

Assert-True ([bool]$roundtripMatrixProof.Summary.ExternalContractPathsImplemented) 'roundtrip proof summary should record implemented external contract paths.'
Assert-True ([bool]$roundtripMatrixProof.Summary.MultiRepoLiveProven) 'roundtrip proof summary should record multi-repo live proof.'
Assert-True ([bool]$roundtripMatrixProof.Summary.RepoAOneRoundtripLiveProven) 'roundtrip proof summary should record repo A one-roundtrip proof.'
Assert-True ([bool]$roundtripMatrixProof.Summary.RepoAThreeRoundtripLiveProven) 'roundtrip proof summary should record repo A three-roundtrip proof.'
Assert-True ([bool]$roundtripMatrixProof.Summary.RepoBOneRoundtripLiveProven) 'roundtrip proof summary should record repo B one-roundtrip proof.'
Assert-True (@($roundtripMatrixProof.ProofMatrix).Count -ge 3) 'roundtrip proof matrix should contain repo A/B entries.'

$repoAThreeRoundtrip = @($roundtripMatrixProof.ProofMatrix | Where-Object { [string]$_.Repo -eq 'repoA' -and [string]$_.Scenario -eq '3-roundtrip' } | Select-Object -First 1)[0]
Assert-True ($null -ne $repoAThreeRoundtrip) 'roundtrip proof should include repo A three-roundtrip entry.'
Assert-True ([bool]$repoAThreeRoundtrip.LiveProven) 'repo A three-roundtrip proof entry should be live-proven.'
Assert-True ([string]$repoAThreeRoundtrip.AcceptanceState -eq 'roundtrip-confirmed') 'repo A three-roundtrip proof entry should be roundtrip-confirmed.'

Assert-True ([bool]$pairRunRootsProof.Summary.PairSpecificContractPathsImplemented) 'mixed pair proof should record pair-specific contract path support.'
Assert-True ([bool]$pairRunRootsProof.Summary.PairSpecificCodexCwdImplemented) 'mixed pair proof should record pair-specific Codex cwd support.'
Assert-True ([bool]$pairRunRootsProof.Summary.MixedPairPreparationImplemented) 'mixed pair proof should record mixed pair preparation support.'
Assert-True ([bool]$pairRunRootsProof.Summary.MixedPairCoordinatorBookkeepingSupported) 'mixed pair proof should record shared coordinator bookkeeping support.'
Assert-True ([bool]$pairRunRootsProof.Summary.MixedPairFixtureProven) 'mixed pair proof should record fixture proof.'
Assert-True ([bool]$pairRunRootsProof.Summary.MixedPairLiveProven) 'mixed pair proof should record live proof.'
Assert-True ([bool]$pairRunRootsProof.Summary.MixedPairOneRoundtripLiveProven) 'mixed pair proof should record one-roundtrip live proof.'
Assert-True ([bool]$pairRunRootsProof.Summary.MixedPairThreeRoundtripLiveProven) 'mixed pair proof should record three-roundtrip live proof.'
Assert-True ([bool]$pairRunRootsProof.Summary.PairsUseDistinctRepos) 'mixed pair proof should record distinct repos.'
Assert-True ([bool]$pairRunRootsProof.Summary.SharedCoordinatorBookkeepingRootUsed) 'mixed pair proof should record shared coordinator bookkeeping usage.'
Assert-True (@($pairRunRootsProof.Pairs).Count -eq 2) 'mixed pair proof should describe pair01 and pair02.'
Assert-True (Test-Path -LiteralPath ([string]$pairRunRootsProof.Coordinator.RunRoot) -PathType Container) 'mixed pair proof coordinator run root should exist.'
Assert-True (Test-Path -LiteralPath ([string]$pairRunRootsProof.Coordinator.ConfigPath) -PathType Leaf) 'mixed pair proof coordinator config path should exist.'

$pairRoots = @($pairRunRootsProof.Pairs)
$distinctWorkRepos = @($pairRoots | ForEach-Object { [string]$_.WorkRepoRoot } | Sort-Object -Unique)
Assert-True ($distinctWorkRepos.Count -eq 2) 'mixed pair proof should record two distinct pair work repos.'
foreach ($pair in $pairRoots) {
    Assert-True (@($pair.Targets).Count -eq 2) ("mixed pair proof should contain two targets for {0}" -f [string]$pair.PairId)
    foreach ($target in @($pair.Targets)) {
        Assert-True (([string]$target.TargetFolder).StartsWith([string]$pair.WorkRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) ("target folder should live under pair work repo for {0}/{1}" -f [string]$pair.PairId, [string]$target.TargetId)
        Assert-True (([string]$target.SourceOutboxPath).StartsWith([string]$pair.WorkRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) ("source outbox should live under pair work repo for {0}/{1}" -f [string]$pair.PairId, [string]$target.TargetId)
    }
}

$mixedPairOneRoundtrip = @($pairRunRootsProof.LiveMatrix | Where-Object { [string]$_.Scenario -eq '1-roundtrip' } | Select-Object -First 1)[0]
$mixedPairThreeRoundtrip = @($pairRunRootsProof.LiveMatrix | Where-Object { [string]$_.Scenario -eq '3-roundtrip' } | Select-Object -First 1)[0]
Assert-True ($null -ne $mixedPairOneRoundtrip) 'mixed pair proof should include one-roundtrip live entry.'
Assert-True ($null -ne $mixedPairThreeRoundtrip) 'mixed pair proof should include three-roundtrip live entry.'
Assert-True ([bool]$mixedPairOneRoundtrip.LiveProven) 'mixed pair one-roundtrip entry should be live-proven.'
Assert-True ([bool]$mixedPairThreeRoundtrip.LiveProven) 'mixed pair three-roundtrip entry should be live-proven.'
Assert-True ([string]$mixedPairOneRoundtrip.WatcherStatus -eq 'stopped') 'mixed pair one-roundtrip watcher should stop cleanly.'
Assert-True ([string]$mixedPairThreeRoundtrip.WatcherStatus -eq 'stopped') 'mixed pair three-roundtrip watcher should stop cleanly.'
Assert-True ([int]$mixedPairOneRoundtrip.Pair01RoundtripCount -ge 1) 'mixed pair one-roundtrip entry should record pair01 roundtrip count.'
Assert-True ([int]$mixedPairOneRoundtrip.Pair02RoundtripCount -ge 1) 'mixed pair one-roundtrip entry should record pair02 roundtrip count.'
Assert-True ([int]$mixedPairThreeRoundtrip.Pair01RoundtripCount -ge 3) 'mixed pair three-roundtrip entry should record pair01 roundtrip count.'
Assert-True ([int]$mixedPairThreeRoundtrip.Pair02RoundtripCount -ge 3) 'mixed pair three-roundtrip entry should record pair02 roundtrip count.'
Assert-True ([int]$mixedPairOneRoundtrip.ErrorPresentCount -eq 0) 'mixed pair one-roundtrip entry should record no errors.'
Assert-True ([int]$mixedPairThreeRoundtrip.ErrorPresentCount -eq 0) 'mixed pair three-roundtrip entry should record no errors.'
Assert-True (Test-Path -LiteralPath ([string]$mixedPairOneRoundtrip.RunRoot) -PathType Container) 'mixed pair one-roundtrip run root should exist.'
Assert-True (Test-Path -LiteralPath ([string]$mixedPairThreeRoundtrip.RunRoot) -PathType Container) 'mixed pair three-roundtrip run root should exist.'
Assert-True (Test-Path -LiteralPath ([string]$mixedPairOneRoundtrip.WatcherStatusPath) -PathType Leaf) 'mixed pair one-roundtrip watcher status path should exist.'
Assert-True (Test-Path -LiteralPath ([string]$mixedPairThreeRoundtrip.WatcherStatusPath) -PathType Leaf) 'mixed pair three-roundtrip watcher status path should exist.'

Assert-True ([bool]$pairScopedConfigProof.Summary.PairSpecificBookkeepingConfigImplemented) 'pair-scoped config proof should record implementation.'
Assert-True ([bool]$pairScopedConfigProof.Summary.PairSpecificBookkeepingConfigFixtureProven) 'pair-scoped config proof should record fixture proof.'
Assert-True ([bool]$pairScopedConfigProof.Summary.PairSpecificBookkeepingLiveProven) 'pair-scoped config proof should record live proof.'
Assert-True ([bool]$pairScopedConfigProof.Summary.PairScopedOneRoundtripLiveProven) 'pair-scoped config proof should record one-roundtrip live proof.'
Assert-True ([bool]$pairScopedConfigProof.Summary.PairScopedThreeRoundtripLiveProven) 'pair-scoped config proof should record three-roundtrip live proof.'
Assert-True ([bool]$pairScopedConfigProof.Summary.PairScopedParallelLiveProven) 'pair-scoped config proof should record parallel live proof.'
Assert-True ([bool]$pairScopedConfigProof.Summary.PairScopedSharedCoordinatorLiveProven) 'pair-scoped config proof should record shared coordinator live proof.'
Assert-True ([bool]$pairScopedConfigProof.Summary.SameRepoPairIsolationFixtureProven) 'pair-scoped config proof should record same-repo isolation fixture proof.'
Assert-True ([bool]$pairScopedConfigProof.Summary.SameRepoParallelLiveProven) 'pair-scoped config proof should record same-repo parallel live proof.'
Assert-True ([bool]$pairScopedConfigProof.Summary.PairsUseDistinctBookkeepingRoots) 'pair-scoped config proof should record distinct bookkeeping roots.'
Assert-True ([bool]$pairScopedConfigProof.Summary.PairScopedRouterMutexesDistinct) 'pair-scoped config proof should record distinct router mutexes.'
Assert-True (@($pairScopedConfigProof.GeneratedConfigs).Count -eq 2) 'pair-scoped config proof should contain two generated configs.'
$pairScopedConfigs = @($pairScopedConfigProof.GeneratedConfigs)
$pairScopedDistinctRoots = @($pairScopedConfigs | ForEach-Object { [string]$_.BookkeepingRoot } | Sort-Object -Unique)
$pairScopedDistinctMutexes = @($pairScopedConfigs | ForEach-Object { [string]$_.RouterMutexName } | Sort-Object -Unique)
Assert-True ($pairScopedDistinctRoots.Count -eq 2) 'pair-scoped config proof should record two distinct bookkeeping roots.'
Assert-True ($pairScopedDistinctMutexes.Count -eq 2) 'pair-scoped config proof should record two distinct router mutexes.'
foreach ($item in @($pairScopedConfigs)) {
    Assert-True (Test-Path -LiteralPath ([string]$item.OutputConfigPath) -PathType Leaf) ("pair-scoped config path should exist: {0}" -f [string]$item.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$item.BookkeepingRoot) -PathType Container) ("pair-scoped bookkeeping root should exist: {0}" -f [string]$item.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$item.PairRunRootBase) -PathType Container) ("pair-scoped run root base should exist: {0}" -f [string]$item.PairId)
}

$pairScopedLiveMatrix = @($pairScopedConfigProof.LiveMatrix)
Assert-True ($pairScopedLiveMatrix.Count -eq 2) 'pair-scoped config proof should contain two live matrix entries.'
$pairScopedOneRoundtripPairs = @($pairScopedLiveMatrix | Where-Object { [string]$_.Scenario -eq '1-roundtrip' })
Assert-True ($pairScopedOneRoundtripPairs.Count -eq 2) 'pair-scoped config proof should record both pair one-roundtrip live entries.'
foreach ($entry in @($pairScopedOneRoundtripPairs)) {
    Assert-True ([bool]$entry.LiveProven) ("pair-scoped live entry should be proven: {0}" -f [string]$entry.PairId)
    Assert-True ([string]$entry.Status -eq 'passed') ("pair-scoped live entry should be passed: {0}" -f [string]$entry.PairId)
    Assert-True ([string]$entry.WatcherStatus -eq 'stopped') ("pair-scoped live entry watcher should stop cleanly: {0}" -f [string]$entry.PairId)
    Assert-True ([string]$entry.WatcherReason -eq 'pair-roundtrip-limit-reached') ("pair-scoped live entry should stop on pair limit: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.PairMaxRoundtripCount -eq 1) ("pair-scoped live entry should record one-roundtrip target: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.RoundtripCount -ge 1) ("pair-scoped live entry should record roundtrip count: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.DonePresentCount -eq 2) ("pair-scoped live entry should record two done files: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ErrorPresentCount -eq 0) ("pair-scoped live entry should record no errors: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.ConfigPath) -PathType Leaf) ("pair-scoped live config path should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.BookkeepingRoot) -PathType Container) ("pair-scoped live bookkeeping root should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.RunRoot) -PathType Container) ("pair-scoped live run root should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.WatcherStatusPath) -PathType Leaf) ("pair-scoped live watcher status path should exist: {0}" -f [string]$entry.PairId)
}

$pairScopedParallelMatrix = @($pairScopedConfigProof.ParallelLiveMatrix)
Assert-True ($pairScopedParallelMatrix.Count -ge 1) 'pair-scoped config proof should contain parallel live matrix entries.'
$parallelOneRoundtrip = @($pairScopedParallelMatrix | Where-Object { [string]$_.Scenario -eq 'parallel-1-roundtrip' } | Select-Object -First 1)[0]
$parallelThreeRoundtrip = @($pairScopedParallelMatrix | Where-Object { [string]$_.Scenario -eq 'parallel-3-roundtrip' } | Select-Object -First 1)[0]
Assert-True ($null -ne $parallelOneRoundtrip) 'pair-scoped config proof should contain parallel one-roundtrip entry.'
Assert-True ($null -ne $parallelThreeRoundtrip) 'pair-scoped config proof should contain parallel three-roundtrip entry.'
Assert-True ([bool]$parallelOneRoundtrip.LiveProven) 'pair-scoped parallel one-roundtrip entry should be proven.'
Assert-True ([string]$parallelOneRoundtrip.Status -eq 'passed') 'pair-scoped parallel one-roundtrip entry should be passed.'
Assert-True ([bool]$parallelThreeRoundtrip.LiveProven) 'pair-scoped parallel three-roundtrip entry should be proven.'
Assert-True ([string]$parallelThreeRoundtrip.Status -eq 'passed') 'pair-scoped parallel three-roundtrip entry should be passed.'
Assert-True (@($parallelOneRoundtrip.PairRuns).Count -eq 2) 'pair-scoped parallel one-roundtrip entry should contain two pair runs.'
Assert-True (@($parallelThreeRoundtrip.PairRuns).Count -eq 2) 'pair-scoped parallel three-roundtrip entry should contain two pair runs.'
foreach ($entry in @($parallelOneRoundtrip.PairRuns)) {
    Assert-True ([string]$entry.WatcherStatus -eq 'stopped') ("pair-scoped parallel run watcher should stop cleanly: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.DonePresentCount -eq 2) ("pair-scoped parallel run should record two done files: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ErrorPresentCount -eq 0) ("pair-scoped parallel run should record no errors: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.ConfigPath) -PathType Leaf) ("pair-scoped parallel config path should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.BookkeepingRoot) -PathType Container) ("pair-scoped parallel bookkeeping root should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.RunRoot) -PathType Container) ("pair-scoped parallel run root should exist: {0}" -f [string]$entry.PairId)
}
foreach ($entry in @($parallelThreeRoundtrip.PairRuns)) {
    Assert-True ([string]$entry.WatcherStatus -eq 'stopped') ("pair-scoped parallel three-roundtrip watcher should stop cleanly: {0}" -f [string]$entry.PairId)
    Assert-True ([string]$entry.WatcherReason -eq 'pair-roundtrip-limit-reached') ("pair-scoped parallel three-roundtrip should stop on pair limit: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.RoundtripCount -ge 3) ("pair-scoped parallel three-roundtrip should record roundtrip count: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.DonePresentCount -eq 2) ("pair-scoped parallel three-roundtrip should record two done files: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ErrorPresentCount -eq 0) ("pair-scoped parallel three-roundtrip should record no errors: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ForwardedStateCount -ge 6) ("pair-scoped parallel three-roundtrip should record forwarded state count: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.ConfigPath) -PathType Leaf) ("pair-scoped parallel three-roundtrip config path should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.BookkeepingRoot) -PathType Container) ("pair-scoped parallel three-roundtrip bookkeeping root should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.RunRoot) -PathType Container) ("pair-scoped parallel three-roundtrip run root should exist: {0}" -f [string]$entry.PairId)
}

$sameRepoParallelMatrix = @($pairScopedConfigProof.SameRepoParallelLiveMatrix)
Assert-True ($sameRepoParallelMatrix.Count -ge 1) 'pair-scoped config proof should contain same-repo parallel live matrix entries.'
$sameRepoParallelOneRoundtrip = @($sameRepoParallelMatrix | Where-Object { [string]$_.Scenario -eq 'same-repo-parallel-1-roundtrip' } | Select-Object -First 1)[0]
Assert-True ($null -ne $sameRepoParallelOneRoundtrip) 'pair-scoped config proof should contain same-repo one-roundtrip entry.'
Assert-True ([bool]$sameRepoParallelOneRoundtrip.LiveProven) 'same-repo parallel one-roundtrip entry should be proven.'
Assert-True ([string]$sameRepoParallelOneRoundtrip.Status -eq 'passed') 'same-repo parallel one-roundtrip entry should be passed.'
Assert-True (Test-Path -LiteralPath ([string]$sameRepoParallelOneRoundtrip.SharedWorkRepoRoot) -PathType Container) 'same-repo shared work repo root should exist.'
Assert-True (@($sameRepoParallelOneRoundtrip.PairRuns).Count -eq 2) 'same-repo parallel one-roundtrip entry should contain two pair runs.'
$sameRepoWorkRoots = @($sameRepoParallelOneRoundtrip.PairRuns | ForEach-Object { [string]$_.WorkRepoRoot } | Sort-Object -Unique)
$sameRepoBookkeepingRoots = @($sameRepoParallelOneRoundtrip.PairRuns | ForEach-Object { [string]$_.BookkeepingRoot } | Sort-Object -Unique)
$sameRepoRunRoots = @($sameRepoParallelOneRoundtrip.PairRuns | ForEach-Object { [string]$_.RunRoot } | Sort-Object -Unique)
Assert-True ($sameRepoWorkRoots.Count -eq 1) 'same-repo parallel one-roundtrip entry should record one shared work repo root.'
Assert-True ([string]$sameRepoWorkRoots[0] -eq [string]$sameRepoParallelOneRoundtrip.SharedWorkRepoRoot) 'same-repo parallel one-roundtrip entry should keep pair work roots equal to the shared work repo root.'
Assert-True ($sameRepoBookkeepingRoots.Count -eq 2) 'same-repo parallel one-roundtrip entry should keep pair-scoped bookkeeping roots distinct.'
Assert-True ($sameRepoRunRoots.Count -eq 2) 'same-repo parallel one-roundtrip entry should keep pair-scoped run roots distinct.'
foreach ($entry in @($sameRepoParallelOneRoundtrip.PairRuns)) {
    Assert-True ([string]$entry.WatcherStatus -eq 'stopped') ("same-repo parallel watcher should stop cleanly: {0}" -f [string]$entry.PairId)
    Assert-True ([string]$entry.WatcherReason -eq 'pair-roundtrip-limit-reached') ("same-repo parallel run should stop on pair limit: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.RoundtripCount -ge 1) ("same-repo parallel run should record roundtrip count: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.DonePresentCount -eq 2) ("same-repo parallel run should record two done files: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ErrorPresentCount -eq 0) ("same-repo parallel run should record no errors: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ForwardedStateCount -ge 2) ("same-repo parallel run should record forwarded state count: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.ConfigPath) -PathType Leaf) ("same-repo parallel config path should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.BookkeepingRoot) -PathType Container) ("same-repo parallel bookkeeping root should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.RunRoot) -PathType Container) ("same-repo parallel run root should exist: {0}" -f [string]$entry.PairId)
}

$pairScopedSharedCoordinatorMatrix = @($pairScopedConfigProof.SharedCoordinatorLiveMatrix)
Assert-True ($pairScopedSharedCoordinatorMatrix.Count -ge 1) 'pair-scoped config proof should contain shared coordinator live matrix entries.'
$sharedCoordinatorOneRoundtrip = @($pairScopedSharedCoordinatorMatrix | Where-Object { [string]$_.Scenario -eq 'shared-coordinator-parallel-1-roundtrip' } | Select-Object -First 1)[0]
$sharedCoordinatorThreeRoundtrip = @($pairScopedSharedCoordinatorMatrix | Where-Object { [string]$_.Scenario -eq 'shared-coordinator-parallel-3-roundtrip' } | Select-Object -First 1)[0]
Assert-True ($null -ne $sharedCoordinatorOneRoundtrip) 'pair-scoped config proof should contain shared coordinator one-roundtrip entry.'
Assert-True ($null -ne $sharedCoordinatorThreeRoundtrip) 'pair-scoped config proof should contain shared coordinator three-roundtrip entry.'
Assert-True ([bool]$sharedCoordinatorOneRoundtrip.LiveProven) 'shared coordinator one-roundtrip entry should be proven.'
Assert-True ([string]$sharedCoordinatorOneRoundtrip.Status -eq 'passed') 'shared coordinator one-roundtrip entry should be passed.'
Assert-True ([bool]$sharedCoordinatorThreeRoundtrip.LiveProven) 'shared coordinator three-roundtrip entry should be proven.'
Assert-True ([string]$sharedCoordinatorThreeRoundtrip.Status -eq 'passed') 'shared coordinator three-roundtrip entry should be passed.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorOneRoundtrip.CoordinatorWorkRepoRoot) -PathType Container) 'shared coordinator work repo root should exist.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorOneRoundtrip.CoordinatorRunRoot) -PathType Container) 'shared coordinator run root should exist.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorOneRoundtrip.CoordinatorManifestPath) -PathType Leaf) 'shared coordinator manifest path should exist.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorOneRoundtrip.CoordinatorWatcherStatusPath) -PathType Leaf) 'shared coordinator watcher status path should exist.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorOneRoundtrip.CoordinatorPairStatePath) -PathType Leaf) 'shared coordinator pair state path should exist.'
Assert-True (@($sharedCoordinatorOneRoundtrip.PairRuns).Count -eq 2) 'shared coordinator one-roundtrip entry should contain two pair runs.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorThreeRoundtrip.CoordinatorWorkRepoRoot) -PathType Container) 'shared coordinator three-roundtrip work repo root should exist.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorThreeRoundtrip.CoordinatorRunRoot) -PathType Container) 'shared coordinator three-roundtrip run root should exist.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorThreeRoundtrip.CoordinatorManifestPath) -PathType Leaf) 'shared coordinator three-roundtrip manifest path should exist.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorThreeRoundtrip.CoordinatorWatcherStatusPath) -PathType Leaf) 'shared coordinator three-roundtrip watcher status path should exist.'
Assert-True (Test-Path -LiteralPath ([string]$sharedCoordinatorThreeRoundtrip.CoordinatorPairStatePath) -PathType Leaf) 'shared coordinator three-roundtrip pair state path should exist.'
Assert-True ([string]$sharedCoordinatorThreeRoundtrip.CoordinatorWatcherStatus -eq 'stopped') 'shared coordinator three-roundtrip watcher should stop cleanly.'
Assert-True ([string]$sharedCoordinatorThreeRoundtrip.CoordinatorWatcherReason -eq 'pair-scoped-shared-coordinator-limit-reached') 'shared coordinator three-roundtrip should stop on shared pair limit.'
Assert-True ([int]$sharedCoordinatorThreeRoundtrip.CoordinatorDonePresentCount -eq 4) 'shared coordinator three-roundtrip should record four done files.'
Assert-True ([int]$sharedCoordinatorThreeRoundtrip.CoordinatorErrorPresentCount -eq 0) 'shared coordinator three-roundtrip should record no errors.'
Assert-True ([int]$sharedCoordinatorThreeRoundtrip.CoordinatorForwardedStateCount -ge 12) 'shared coordinator three-roundtrip should record forwarded state count.'
Assert-True (@($sharedCoordinatorThreeRoundtrip.PairRuns).Count -eq 2) 'shared coordinator three-roundtrip entry should contain two pair runs.'
foreach ($entry in @($sharedCoordinatorOneRoundtrip.PairRuns)) {
    Assert-True ([string]$entry.WatcherStatus -eq 'stopped') ("shared coordinator pair run watcher should stop cleanly: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.DonePresentCount -eq 2) ("shared coordinator pair run should record two done files: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ErrorPresentCount -eq 0) ("shared coordinator pair run should record no errors: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.ConfigPath) -PathType Leaf) ("shared coordinator pair config path should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.BookkeepingRoot) -PathType Container) ("shared coordinator pair bookkeeping root should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.RunRoot) -PathType Container) ("shared coordinator pair run root should exist: {0}" -f [string]$entry.PairId)
}
foreach ($entry in @($sharedCoordinatorThreeRoundtrip.PairRuns)) {
    Assert-True ([string]$entry.WatcherStatus -eq 'stopped') ("shared coordinator three-roundtrip pair run watcher should stop cleanly: {0}" -f [string]$entry.PairId)
    Assert-True ([string]$entry.WatcherReason -eq 'pair-roundtrip-limit-reached') ("shared coordinator three-roundtrip pair run should stop on pair limit: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.RoundtripCount -ge 3) ("shared coordinator three-roundtrip pair run should record roundtrip count: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.DonePresentCount -eq 2) ("shared coordinator three-roundtrip pair run should record two done files: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ErrorPresentCount -eq 0) ("shared coordinator three-roundtrip pair run should record no errors: {0}" -f [string]$entry.PairId)
    Assert-True ([int]$entry.ForwardedStateCount -ge 6) ("shared coordinator three-roundtrip pair run should record forwarded state count: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.ConfigPath) -PathType Leaf) ("shared coordinator three-roundtrip pair config path should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.BookkeepingRoot) -PathType Container) ("shared coordinator three-roundtrip pair bookkeeping root should exist: {0}" -f [string]$entry.PairId)
    Assert-True (Test-Path -LiteralPath ([string]$entry.RunRoot) -PathType Container) ("shared coordinator three-roundtrip pair run root should exist: {0}" -f [string]$entry.PairId)
}

Write-Host 'review proof artifacts contract ok'
