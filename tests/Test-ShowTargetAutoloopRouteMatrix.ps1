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
. (Join-Path $root 'tests\TargetAutoloopConfig.ps1')

$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopRouteMatrix'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_route_matrix'
$configPath = Join-Path $tmpRoot 'settings.test.psd1'
$inboxTarget01 = Join-Path $tmpRoot 'inbox\target01'
$inboxTarget02 = Join-Path $tmpRoot 'inbox\target02'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $inboxTarget01 -Force | Out-Null
New-Item -ItemType Directory -Path $inboxTarget02 -Force | Out-Null

$configText = @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($inboxTarget01.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-route-matrix-01' }
        @{ Id = 'target02'; Folder = '$($inboxTarget02.Replace("'", "''"))'; WindowTitle = 'Target02'; FixedSuffix = 'suffix-route-matrix-02' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        PollIntervalMs = 200
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 2 }
            @{ TargetId = 'target02'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 3 }
        )
    }
}
"@
$configText | Set-Content -LiteralPath $configPath -Encoding UTF8

$startJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Start-TargetAutoloopRun.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -RunMode target-autoloop `
    -AsJson
$start = $startJson | ConvertFrom-Json
$config = Resolve-TargetAutoloopConfig -Root $root -ConfigPath $configPath
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$stateDocument = Read-JsonObject -Path ([string]$start.StatePath)
$controlDocument = Read-JsonObject -Path ([string]$start.ControlPath)
$stateDocument.Targets.target01.Phase = 'waiting-output'
$stateDocument.Targets.target01.CycleCount = 1
$stateDocument.Targets.target01.NextAction = 'wait-for-output'
$stateDocument.Targets.target02.Phase = 'idle'
$stateDocument.Targets.target02.CycleCount = 0
$stateDocument.Targets.target02.NextAction = 'wait-for-input'
Write-JsonFileAtomically -Path ([string]$start.StatePath) -Payload $stateDocument

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'route matrix cycle 1 summary'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'route-matrix-note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'route matrix zip payload'
if (Test-Path -LiteralPath $target01.SourceReviewZipPath) {
    Remove-Item -LiteralPath $target01.SourceReviewZipPath -Force
}
Compress-Archive -LiteralPath $zipNotePath -DestinationPath $target01.SourceReviewZipPath -Force
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -CycleId 1 `
    -ParentCycleId 0 `
    -OutputFingerprint output-fingerprint-route-matrix-001 `
    -Overwrite | Out-Null

$statusDocument = New-TargetAutoloopStatusDocument `
    -Config $config `
    -RunRoot $runRoot `
    -StateDocument (Read-JsonObject -Path ([string]$start.StatePath)) `
    -ControlDocument $controlDocument `
    -WatcherState 'running' `
    -ConfiguredRunDurationSec 120
Write-JsonFileAtomically -Path ([string]$start.StatusPath) -Payload $statusDocument

Write-TargetAutoloopSmokeReceipt `
    -Path ([string]$start.SmokeReceiptPath) `
    -Scenario 'route-matrix' `
    -Result 'passed' `
    -Source 'script-smoke' `
    -ProofLevel 'script-level' `
    -RunRoot $runRoot `
    -TargetId 'target01' `
    -CycleCount 1 `
    -MaxCycleCount 2 `
    -FinalPhase 'waiting-output' `
    -WatcherStopReason '' | Out-Null

$matrixJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$matrixText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

Assert-True ([string]$matrixJson.RunRootMode -eq 'selected') 'route matrix json should preserve selected run root mode.'
Assert-True (-not [bool]$matrixJson.ManifestMismatch) 'route matrix json should mark matching manifest/config as not mismatched.'
Assert-True ([string]$matrixJson.ProofCloseout.State -eq 'pending-visible-proof') 'route matrix json should mark script smoke as pending visible proof.'
Assert-True ([int]$matrixJson.Counts.RouteReadyTargets -eq 1) 'route matrix json should count one route ready target.'
Assert-True ([int]$matrixJson.Counts.RouteEmptyTargets -eq 1) 'route matrix json should count one route empty target.'
$matrixTarget01 = @($matrixJson.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$matrixTarget02 = @($matrixJson.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
Assert-True ([string]$matrixTarget01.RouteBadge -eq 'ROUTE READY') 'target01 route badge should be ROUTE READY.'
Assert-True ([bool]$matrixTarget01.InManifest) 'target01 should be marked present in manifest.'
Assert-True ([bool]$matrixTarget01.ManifestEnabled) 'target01 should be marked enabled in manifest.'
Assert-True ([string]$matrixTarget01.TargetStatusPath -match [regex]::Escape('target01\.state\target-autoloop-status.json')) 'target01 route matrix should expose target-scoped status path.'
Assert-True ([string]$matrixTarget01.TargetControlPath -match [regex]::Escape('target01\.state\target-autoloop-control.json')) 'target01 route matrix should expose target-scoped control path.'
Assert-True ([string]$matrixTarget01.TargetWatcherMutexName -match '^Global\\RelayTargetAutoloopTarget_[0-9a-f]+$') 'target01 route matrix should expose target-scoped watcher mutex preview.'
Assert-True ([string]$matrixTarget01.Delivery.Watcher -eq 'not-yet-accepted-current-marker') 'target01 route matrix delivery should show that watcher has not accepted the marker yet.'
Assert-True ([string]$matrixTarget01.DeliveryNextActionCode -eq 'wait-or-restart-watcher') 'target01 route matrix should expose the watcher accepted next action.'
Assert-True ([string]$matrixTarget01.DeliveryNextActionLabel -eq 'watcher accepted 확인') 'target01 route matrix should expose a compact watcher accepted label.'
Assert-True ([string]$matrixTarget02.RouteBadge -eq 'ROUTE EMPTY') 'target02 route badge should be ROUTE EMPTY.'
Assert-True ([bool]$matrixTarget02.InManifest) 'target02 should be marked present in manifest.'
Assert-True ([bool]$matrixTarget02.ManifestEnabled) 'target02 should be marked enabled in manifest.'
Assert-True ($matrixText -match 'Manifest: exists=True runMode=target-autoloop targets=target01,target02 enabled=target01,target02 mismatch=False reason=\(none\)') 'route matrix text should show matching manifest/config summary.'
Assert-True ($matrixText -match 'Counts: total=2 enabled=2 routeReady=1 routeCheck=0 routeEmpty=1 disabled=0 contractReady=1 partial=0 invalid=0 missing=1') 'route matrix text should include the compact counts summary.'
Assert-True ($matrixText -match 'target01 \| enabled \| ROUTE READY \| contract=ready \| cycle 1/2 \| phase=waiting-output \| next=wait-for-output \| triggers=input-file,publish-ready') 'route matrix text should surface target01 as route ready.'
Assert-True ($matrixText -match 'delivery: artifact=created / watcher=not-yet-accepted-current-marker / router=not-delivered') 'route matrix text should surface target01 delivery stage.'
Assert-True ($matrixText -match 'deliveryNext: watcher accepted 확인') 'route matrix text should surface the compact delivery next action.'
Assert-True ($matrixText -match 'targetState: status=.*target01.*target-autoloop-status\.json control=.*target01.*target-autoloop-control\.json mutex=Global\\RelayTargetAutoloopTarget_') 'route matrix text should include target-scoped sidecar paths.'
Assert-True ($matrixText -match 'target02 \| enabled \| ROUTE EMPTY \| contract=missing \| cycle 0/3 \| phase=idle \| next=wait-for-input \| triggers=input-file,publish-ready') 'route matrix text should surface target02 as route empty.'
Assert-True ($matrixText -match [regex]::Escape([string]$target01.SourceSummaryPath)) 'route matrix text should include target01 summary path.'
Assert-True ($matrixText -match 'CloseoutSummary: closeout: pending-visible-proof / mode=operational / reason=proof-passed-script-level / proof=script-level / source=script-smoke') 'route matrix text should surface pending visible proof closeout.'

$stateWithRecordedReady = Read-JsonObject -Path ([string]$start.StatePath)
$stateWithRecordedReady.Targets.target01.LastHandledOutputFingerprint = 'output-fingerprint-route-matrix-001'
$stateWithRecordedReady.Targets.target01.LastDispatchState = ''
$stateWithRecordedReady.Targets.target01.LastRouterReadyPath = Join-Path $inboxTarget01 'already-processed.ready.txt'
Write-JsonFileAtomically -Path ([string]$start.StatePath) -Payload $stateWithRecordedReady
$statusWithRecordedReady = New-TargetAutoloopStatusDocument `
    -Config $config `
    -RunRoot $runRoot `
    -StateDocument $stateWithRecordedReady `
    -ControlDocument $controlDocument `
    -WatcherState 'running' `
    -ConfiguredRunDurationSec 120
Write-JsonFileAtomically -Path ([string]$start.StatusPath) -Payload $statusWithRecordedReady

$matrixRecordedReadyJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$matrixRecordedReadyTarget01 = @($matrixRecordedReadyJson.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$matrixRecordedReadyTarget01.Delivery.Watcher -eq 'accepted-current-marker') 'route matrix should show accepted marker when state handled fingerprint matches.'
Assert-True ([string]$matrixRecordedReadyTarget01.Delivery.Router -eq 'ready-file-created') 'route matrix should treat LastRouterReadyPath as router delivery evidence.'
Assert-True ([string]$matrixRecordedReadyTarget01.DeliveryNextActionCode -eq 'check-cell-processing') 'route matrix should guide to cell processing after recorded router delivery.'

Remove-Item -LiteralPath ([string]$start.SmokeReceiptPath) -Force
$stateRoot = Split-Path -Parent ([string]$start.SmokeReceiptPath)
@{
    GeneratedAt = '2026-05-13T13:10:00+09:00'
    LastUpdatedAt = '2026-05-13T13:11:00+09:00'
    Stage = 'post-cleanup'
    SeedTargetId = 'target01'
    Outcome = @{
        AcceptanceState = 'preflight-passed'
        AcceptanceReason = 'typed-window-preflight-passed'
    }
    PhaseHistory = @(
        @{
            Stage = 'closeout-completed'
            AcceptanceState = 'roundtrip-confirmed'
        },
        @{
            Stage = 'post-cleanup'
            AcceptanceState = 'preflight-passed'
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'live-acceptance-result.json') -Encoding UTF8

$matrixVisibleJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$matrixVisibleText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

Assert-True ([string]$matrixVisibleJson.ProofCloseout.State -eq 'final-pass') 'route matrix json should mark visible-live proof as final-pass.'
Assert-True ([string]$matrixVisibleJson.ProofCloseout.Mode -eq 'final') 'route matrix json should mark visible-live proof mode as final.'
Assert-True ([string]$matrixVisibleJson.ProofReceipt.ProofLevel -eq 'visible-live') 'route matrix json should surface visible-live proof when smoke receipt is absent.'
Assert-True ($matrixVisibleText -match 'CloseoutSummary: closeout: final-pass / mode=final / reason=visible-live-passed / proof=visible-live / source=shared-visible-acceptance') 'route matrix text should surface final-pass closeout.'

@{
    SchemaVersion = 1
    RunMode = 'target-autoloop'
    RunRoot = $runRoot
    Targets = @(
        @{
            TargetId = 'target02'
            Enabled = $false
            TriggerKinds = @('input-file')
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([string]$start.ManifestPath) -Encoding UTF8

$matrixStaleJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$matrixStaleText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

Assert-True ([bool]$matrixStaleJson.ManifestMismatch) 'route matrix json should flag stale manifest/config mismatch.'
Assert-True ([string]$matrixStaleJson.ManifestMismatchReason -match 'enabled-targets-differ') 'route matrix json should explain enabled target mismatch.'
Assert-True ((@($matrixStaleJson.ManifestReasonCodes) -contains 'enabled-targets-differ') -and (@($matrixStaleJson.BlockingReasonCodes) -contains 'enabled-targets-differ')) 'route matrix json should expose stable mismatch reason codes.'
$matrixStaleTarget01 = @($matrixStaleJson.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$matrixStaleTarget02 = @($matrixStaleJson.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
Assert-True (-not [bool]$matrixStaleTarget01.InManifest) 'target01 should be marked absent from stale manifest.'
Assert-True ([string]$matrixStaleTarget01.RouteScope -eq 'outside-current-manifest') 'target01 should be marked outside the current manifest scope.'
Assert-True ([string]$matrixStaleTarget01.RouteScopeReason -eq 'target-not-in-current-run-manifest') 'target01 route scope should explain the out-of-scope reason.'
Assert-True ([string]$matrixStaleTarget01.RouteBadge -eq 'ROUTE OUT') 'out-of-scope target01 should not be shown as an active route problem.'
Assert-True ([bool]$matrixStaleTarget02.InManifest) 'target02 should be marked present in stale manifest.'
Assert-True (-not [bool]$matrixStaleTarget02.ManifestEnabled) 'target02 should be marked disabled in stale manifest.'
Assert-True ($matrixStaleText -match 'Manifest: exists=True runMode=target-autoloop targets=target02 enabled=\(none\) mismatch=True') 'route matrix text should show stale manifest mismatch.'
Assert-True ($matrixStaleText -match 'target01 \| enabled \| ROUTE OUT \| contract=ready') 'route matrix text should show out-of-scope ready contracts as ROUTE OUT.'
Assert-True ($matrixStaleText -match 'manifest: inManifest=False manifestEnabled=False routeScope=outside-current-manifest reason=target-not-in-current-run-manifest') 'route matrix text should explain route scope for out-of-scope targets.'

Remove-Item -LiteralPath $target01.PublishReadyPath -Force
$matrixStalePartialJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$matrixStalePartialTarget01 = @($matrixStalePartialJson.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
Assert-True ([string]$matrixStalePartialTarget01.ContractState -eq 'partial') 'out-of-scope target01 should still report the actual partial contract state.'
Assert-True ([string]$matrixStalePartialTarget01.ContractReason -eq 'summary-review-without-marker') 'out-of-scope partial contract should keep the marker-missing reason.'
Assert-True ([string]$matrixStalePartialTarget01.RouteBadge -eq 'ROUTE OUT') 'out-of-scope partial contract should not be shown as ROUTE CHECK.'
Assert-True ([int]$matrixStalePartialJson.Counts.RouteCheckTargets -eq 0) 'out-of-scope partial contracts should not increase active route check count.'
Assert-True ([int]$matrixStalePartialJson.Counts.RouteOutOfScopeTargets -eq 1) 'out-of-scope partial contract should increase route out count.'

Remove-Item -LiteralPath ([string]$start.ManifestPath) -Force
$matrixMissingManifestJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteMatrix.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$matrixMissingManifestTarget01 = @($matrixMissingManifestJson.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$matrixMissingManifestTarget02 = @($matrixMissingManifestJson.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
Assert-True ([string]$matrixMissingManifestTarget01.RouteScope -eq 'manifest-missing') 'manifest-missing runroot should mark target01 route scope.'
Assert-True ([string]$matrixMissingManifestTarget01.RouteScopeReason -eq 'runroot-manifest-missing') 'manifest-missing route scope should explain missing manifest.'
Assert-True ([string]$matrixMissingManifestTarget01.ContractState -eq 'partial') 'manifest-missing target01 should keep actual partial contract state.'
Assert-True ([string]$matrixMissingManifestTarget01.RouteBadge -eq 'ROUTE OUT') 'manifest-missing partial contract should not be shown as ROUTE CHECK.'
Assert-True ([string]$matrixMissingManifestTarget02.ContractState -eq 'missing') 'manifest-missing empty target02 should keep missing contract state.'
Assert-True ([string]$matrixMissingManifestTarget02.RouteBadge -eq 'ROUTE EMPTY') 'manifest-missing empty target should remain ROUTE EMPTY.'

Write-Host 'show target autoloop route matrix ok'
