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

function Assert-Equal {
    param(
        [AllowEmptyString()][string]$Expected,
        [AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0}: expected={1} actual={2}" -f $Message, [string]$Expected, [string]$Actual)
    }
}

function Write-TestConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TmpRoot,
        [Parameter(Mandatory)][string]$InboxTarget04,
        [AllowEmptyString()][string]$WorkRepoRoot = ''
    )

    $workRepoClause = if ([string]::IsNullOrWhiteSpace($WorkRepoRoot)) {
        ''
    }
    else {
        ("; WorkRepoRoot = '{0}'" -f $WorkRepoRoot.Replace("'", "''"))
    }

    $configText = @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target04'; Folder = '$($InboxTarget04.Replace("'", "''"))'; WindowTitle = 'Target04'; FixedSuffix = 'target04 fixed suffix' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$false
        PollIntervalMs = 100
        RunRootBase = '$($TmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target04'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 2$workRepoClause }
        )
    }
}
"@
    $configText | Set-Content -LiteralPath $Path -Encoding UTF8
}

$root = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path $root '_tmp\Test-TargetAutoloopManifestPathAuthority'
$runRoot = Join-Path $tmpRoot 'run_manifest_path_authority'
$configPath = Join-Path $tmpRoot 'settings.test.psd1'
$inboxTarget04 = Join-Path $tmpRoot 'inbox\target04'
$driftWorkRepoRoot = 'C:\dev\python\relay-target-autoloop-manifest-path-authority-drift'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
if (Test-Path -LiteralPath $driftWorkRepoRoot) {
    Remove-Item -LiteralPath $driftWorkRepoRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $inboxTarget04 -Force | Out-Null
New-Item -ItemType Directory -Path $driftWorkRepoRoot -Force | Out-Null

Write-TestConfig -Path $configPath -TmpRoot $tmpRoot -InboxTarget04 $inboxTarget04
$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -RunMode target-autoloop `
    -Targets target04 `
    -AsJson
$start = $startJson | ConvertFrom-Json
$manifest = Get-Content -LiteralPath ([string]$start.ManifestPath) -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestTarget04 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target04' } | Select-Object -First 1)[0]

Write-TestConfig -Path $configPath -TmpRoot $tmpRoot -InboxTarget04 $inboxTarget04 -WorkRepoRoot $driftWorkRepoRoot

$composerJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target04 `
    -TaskText 'manifest path authority drift check' `
    -AsJson | ConvertFrom-Json

Assert-Equal 'manifest' ([string]$composerJson.ResolvedOutputPaths.PathSource) 'seed composer should use manifest as the strict path source.'
Assert-Equal ([string]$manifestTarget04.SourceSummaryPath) ([string]$composerJson.ResolvedOutputPaths.SourceSummaryPath) 'seed composer summary path should come from manifest.'
Assert-Equal ([string]$manifestTarget04.SourceReviewZipPath) ([string]$composerJson.ResolvedOutputPaths.SourceReviewZipPath) 'seed composer review zip path should come from manifest.'
Assert-Equal ([string]$manifestTarget04.PublishReadyPath) ([string]$composerJson.ResolvedOutputPaths.PublishReadyPath) 'seed composer publish-ready path should come from manifest.'
Assert-True ([bool]$composerJson.ContractPathProof.ConfigDriftDetected) 'seed composer should surface config drift when current config paths differ from the existing manifest.'
Assert-True ([bool]$composerJson.ContractPathProof.ResolvedPathsMatchManifest) 'seed composer resolved paths should still match manifest after drift.'
Assert-True ([string]$composerJson.ManualStartText -match [regex]::Escape([string]$manifestTarget04.SourceSummaryPath)) 'manual start text should include the manifest summary path.'
Assert-True (-not ([string]$composerJson.ManualStartText -match [regex]::Escape($driftWorkRepoRoot))) 'manual start text should not include the drift work repo path.'
Assert-True ([string]$composerJson.ContractText -match 'config drift override active') 'contract text should explain the manifest override when config drift exists.'

$zipPayloadPath = Join-Path $tmpRoot 'review-payload.txt'
'manifest path authority review payload' | Set-Content -LiteralPath $zipPayloadPath -Encoding UTF8
New-Item -ItemType Directory -Path (Split-Path -Parent ([string]$manifestTarget04.SourceSummaryPath)) -Force | Out-Null
'manifest path authority summary' | Set-Content -LiteralPath ([string]$manifestTarget04.SourceSummaryPath) -Encoding UTF8
Compress-Archive -LiteralPath $zipPayloadPath -DestinationPath ([string]$manifestTarget04.SourceReviewZipPath) -Force

$publishJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target04 `
    -OutputFingerprint manifest-path-authority-output-001 `
    -Overwrite `
    -AsJson
$publish = $publishJson | ConvertFrom-Json
Assert-Equal ([string]$manifestTarget04.PublishReadyPath) ([string]$publish.PublishReadyPath) 'publish helper should write the manifest publish-ready path after config drift.'

$watchJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Watch-TargetAutoloop.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -Targets target04 `
    -ProcessOnce `
    -AsJson
$watch = $watchJson | ConvertFrom-Json
Assert-True ([int]$watch.QueuedCount -eq 1) 'watcher should queue exactly one command from the manifest publish-ready marker.'

$manifestQueuedCommands = @(Get-ChildItem -LiteralPath ([string]$manifestTarget04.QueueQueuedRoot) -Filter '*.json' -File -ErrorAction SilentlyContinue)
Assert-True ($manifestQueuedCommands.Count -eq 1) 'queued command should be written under the manifest queue root.'

$workerJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'visible\Start-TargetAutoloopWorker.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target04 `
    -ProcessOnce `
    -AsJson
$worker = $workerJson | ConvertFrom-Json
Assert-True ($null -ne $worker.LastResult) 'worker should find the manifest queue command even after config drift.'
Assert-True ([string]$worker.LastResult.CommandPath -eq [string]$manifestQueuedCommands[0].FullName) 'worker should read the command from the manifest queue root.'
Assert-True ([string]$worker.LastResult.State -in @('blocked-by-router-session-not-ready', 'blocked-by-router-session-mismatch', 'blocked-by-controller')) 'worker should stop before real dispatch when runtime/router is not ready.'

$runLeaf = Split-Path -Leaf $runRoot
$driftQueuedRoot = Join-Path (Join-Path (Join-Path (Join-Path $driftWorkRepoRoot '.relay-runs') 'bottest-live-visible') (Join-Path 'target-autoloop' $runLeaf)) (Join-Path '.queue\target-autoloop' (Join-Path 'target04' 'queued'))
$driftQueuedCommands = @(Get-ChildItem -LiteralPath $driftQueuedRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
Assert-True ($driftQueuedCommands.Count -eq 0) 'config drift queue root should remain empty because manifest queue root is authoritative.'

Write-Host ('target autoloop manifest path authority ok: runRoot=' + $runRoot)
