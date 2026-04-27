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

    if (-not [bool]$Condition) {
        throw $Message
    }
}

$encoding = [System.Text.UTF8Encoding]::new($false)
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'config\settings.bottest-live-visible.psd1'
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$originalConfig = Import-PowerShellDataFile -Path $resolvedConfigPath
$originalWorkRepoRoot = [string]$originalConfig.PairTest.DefaultSeedWorkRepoRoot
$testWorkRepoRoot = Join-Path $originalWorkRepoRoot '__codex-tests\handoff-primitive'
$runtimeRoot = Join-Path $testWorkRepoRoot 'runtime'
$logsRoot = Join-Path $testWorkRepoRoot 'logs'
$inboxRoot = Join-Path $testWorkRepoRoot 'inbox'
$retryPendingRoot = Join-Path $testWorkRepoRoot 'retry-pending'
$failedRoot = Join-Path $testWorkRepoRoot 'failed'
$processedRoot = Join-Path $testWorkRepoRoot 'processed'
$configCopyPath = Join-Path $testWorkRepoRoot 'settings.handoff-primitive.psd1'
New-Item -ItemType Directory -Path $testWorkRepoRoot -Force | Out-Null
$configText = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8
$configText = $configText.Replace($originalWorkRepoRoot, $testWorkRepoRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible', $runtimeRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\logs\bottest-live-visible', $logsRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible', $inboxRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\retry-pending\bottest-live-visible', $retryPendingRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\failed\bottest-live-visible', $failedRoot)
$configText = $configText.Replace('C:\dev\python\hyukwoo\hyukwoo1\processed\bottest-live-visible', $processedRoot)
[System.IO.File]::WriteAllText($configCopyPath, $configText, $encoding)
$resolvedConfigPath = $configCopyPath
$config = Import-PowerShellDataFile -Path $resolvedConfigPath
$seedReviewInputPath = [string]$config.PairTest.DefaultSeedReviewInputPath
if (-not [string]::IsNullOrWhiteSpace($seedReviewInputPath)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $seedReviewInputPath) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $seedReviewInputPath)) {
        [System.IO.File]::WriteAllText($seedReviewInputPath, 'handoff primitive review input', $encoding)
    }
}
$pairRunRootBase = [string]$config.PairTest.RunRootBase
$runRoot = Join-Path $pairRunRootBase ('run_handoff_primitive_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$stateRoot = Join-Path $runRoot '.state'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

& (Join-Path $root 'tests\Start-PairedExchangeTest.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -IncludePairId pair01 `
    -SeedTargetId target01 | Out-Null

$manifestPath = Join-Path $runRoot 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ($null -ne $target01) 'manifest should include target01.'

$targetFolder = [string]$target01.TargetFolder
$reviewFolder = [string]$target01.ReviewFolderPath
$summaryPath = [string]$target01.SummaryPath
$donePath = Join-Path $targetFolder ([string]$manifest.PairTest.HeadlessExec.DoneFileName)

New-Item -ItemType Directory -Path $reviewFolder -Force | Out-Null
$payloadPath = Join-Path $reviewFolder 'target01-payload.txt'
$zipPath = Join-Path $reviewFolder 'target01-review.zip'
Set-Content -LiteralPath $payloadPath -Value 'handoff primitive payload' -Encoding UTF8
Compress-Archive -LiteralPath $payloadPath -DestinationPath $zipPath -Force
Remove-Item -LiteralPath $payloadPath -Force
Set-Content -LiteralPath $summaryPath -Value 'handoff primitive summary' -Encoding UTF8
Set-Content -LiteralPath $donePath -Value 'done' -Encoding UTF8

$zipInfo = Get-Item -LiteralPath $zipPath
$fingerprint = '{0}|{1}|{2}|{3}' -f `
    'target01', `
    $zipInfo.FullName.ToLowerInvariant(), `
    [int64]$zipInfo.Length, `
    [int64]$zipInfo.LastWriteTimeUtc.Ticks
$forwardedPath = Join-Path $stateRoot 'forwarded.json'
@{ $fingerprint = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $forwardedPath -Encoding UTF8

$resultRaw = & (Join-Path $root 'tests\Confirm-PairedExchangeHandoffPrimitive.ps1') `
    -ConfigPath $resolvedConfigPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -AsJson
$result = $resultRaw | ConvertFrom-Json

Assert-True ([string]$result.PrimitiveName -eq 'handoff-confirm') 'wrapper should mark handoff-confirm primitive name.'
Assert-True ([string]$result.PairId -eq 'pair01') 'wrapper should resolve pair01 from target01.'
Assert-True ([string]$result.TargetId -eq 'target01') 'wrapper should preserve selected target.'
Assert-True ([string]$result.PartnerTargetId -eq 'target05') 'wrapper should resolve partner target.'
Assert-True ([bool]$result.PrimitiveSuccess) 'wrapper should treat forwarded current target as observable handoff progress.'
Assert-True ([bool]$result.PrimitiveAccepted) 'wrapper should treat forwarded current target as accepted handoff.'
Assert-True ([string]$result.PrimitiveState -eq 'accepted') 'wrapper should classify forwarded current target as accepted.'
Assert-True ([string]$result.NextPrimitiveAction -eq 'artifact-check-needed') 'wrapper should inherit pair next action when partner artifacts are still missing.'
Assert-True ([bool]$result.CurrentAccepted) 'wrapper should flag current target as accepted.'
Assert-True ([bool]$result.CurrentReady) 'wrapper should flag forwarded current target as ready.'
Assert-True (-not [bool]$result.PartnerProgressObserved) 'wrapper should keep partner progress false when target05 has no artifacts yet.'
Assert-True ([bool]$result.Evidence.CurrentAccepted) 'wrapper should surface accepted flag in compact evidence.'
Assert-True ([string]$result.Evidence.Target.LatestState -eq 'forwarded') 'wrapper should include target evidence row.'
Assert-True ([int]$result.PairForwardedStateCount -eq 1) 'wrapper should surface pair forwarded count.'
Assert-True ([string]$result.PairedTargetStatus.LatestState -eq 'forwarded') 'wrapper should attach current target latest state.'
Assert-True ([string]$result.PairedStatusSnapshot.PairTest.ExecutionPathMode -eq 'typed-window') 'wrapper should attach paired status snapshot.'

Write-Host ('confirm paired exchange handoff primitive ok: runRoot=' + $runRoot)
