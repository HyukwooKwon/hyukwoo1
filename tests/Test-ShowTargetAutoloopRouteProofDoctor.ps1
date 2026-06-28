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

$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopRouteProofDoctor'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_route_proof_doctor'
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
        @{ Id = 'target01'; Folder = '$($inboxTarget01.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = 'suffix-route-proof-01' }
        @{ Id = 'target02'; Folder = '$($inboxTarget02.Replace("'", "''"))'; WindowTitle = 'Target02'; FixedSuffix = 'suffix-route-proof-02' }
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
$target02 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]

$stateDocument = Read-JsonObject -Path ([string]$start.StatePath)
$controlDocument = Read-JsonObject -Path ([string]$start.ControlPath)
$stateDocument.Targets.target01.Phase = 'waiting-output'
$stateDocument.Targets.target01.CycleCount = 1
$stateDocument.Targets.target01.NextAction = 'wait-for-output'
$stateDocument.Targets.target02.Phase = 'idle'
$stateDocument.Targets.target02.CycleCount = 0
$stateDocument.Targets.target02.NextAction = 'wait-for-input'
Write-JsonFileAtomically -Path ([string]$start.StatePath) -Payload $stateDocument

Set-Content -LiteralPath $target01.SourceSummaryPath -Encoding UTF8 -Value 'route proof doctor cycle 1 summary'
$zipNotePath = Join-Path $target01.SourceOutboxPath 'route-proof-note.txt'
Set-Content -LiteralPath $zipNotePath -Encoding UTF8 -Value 'route proof zip payload'
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
    -OutputFingerprint output-fingerprint-route-proof-001 `
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
    -Scenario 'route-proof-doctor' `
    -Result 'passed' `
    -Source 'script-smoke' `
    -ProofLevel 'script-level' `
    -RunRoot $runRoot `
    -TargetId 'target01' `
    -CycleCount 1 `
    -MaxCycleCount 2 `
    -FinalPhase 'waiting-output' `
    -WatcherStopReason '' | Out-Null

$doctorJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteProofDoctor.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$doctorText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteProofDoctor.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

Assert-True ([string]$doctorJson.ProofCloseout.State -eq 'pending-visible-proof') 'doctor json should mark script smoke as pending visible proof.'
Assert-True ([string]$doctorJson.ProofCloseout.Mode -eq 'operational') 'doctor json should mark script smoke closeout mode as operational.'
Assert-True (-not [bool]$doctorJson.ManifestMismatch) 'doctor json should mark matching manifest/config as not mismatched.'
Assert-True ([int]$doctorJson.Counts.ReadyContracts -eq 1) 'doctor json should count one ready contract.'
Assert-True ([int]$doctorJson.Counts.MissingContracts -eq 1) 'doctor json should count one missing contract.'
$doctorTarget01 = @($doctorJson.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$doctorTarget02 = @($doctorJson.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
Assert-True ([string]$doctorTarget01.Contract.State -eq 'ready') 'target01 contract should be ready.'
Assert-True ([bool]$doctorTarget01.InManifest) 'target01 should be marked present in manifest.'
Assert-True ([bool]$doctorTarget01.ManifestEnabled) 'target01 should be marked enabled in manifest.'
Assert-True ([string]$doctorTarget01.Delivery.Watcher -eq 'not-yet-accepted-current-marker') 'target01 proof doctor delivery should show that watcher has not accepted the marker yet.'
Assert-True ([string]$doctorTarget01.DeliveryNextActionCode -eq 'wait-or-restart-watcher') 'target01 proof doctor should expose the watcher accepted next action.'
Assert-True ([string]$doctorTarget01.DeliveryNextActionLabel -eq 'watcher accepted 확인') 'target01 proof doctor should expose a compact watcher accepted label.'
Assert-True ([string]$doctorTarget02.Contract.State -eq 'missing') 'target02 contract should be missing.'
Assert-True ([bool]$doctorTarget02.InManifest) 'target02 should be marked present in manifest.'
Assert-True ([bool]$doctorTarget02.ManifestEnabled) 'target02 should be marked enabled in manifest.'
Assert-True ($doctorText -match 'Manifest: exists=True runMode=target-autoloop targets=target01,target02 enabled=target01,target02 mismatch=False reason=\(none\)') 'doctor text should surface matching manifest summary.'
Assert-True ($doctorText -match 'CloseoutSummary: closeout: pending-visible-proof / mode=operational / reason=proof-passed-script-level / proof=script-level / source=script-smoke') 'doctor text should surface the pending visible proof closeout summary.'
Assert-True ($doctorText -match 'target01 \| waiting-output \| cycle 1/2 \| next=wait-for-output \| contract=ready \| reason=publish-ready-valid') 'doctor text should surface target01 ready contract.'
Assert-True ($doctorText -match 'delivery: artifact=created / watcher=not-yet-accepted-current-marker / router=not-delivered') 'doctor text should surface target01 delivery stage.'
Assert-True ($doctorText -match 'deliveryNext: watcher accepted 확인') 'doctor text should surface the compact delivery next action.'
Assert-True ($doctorText -match 'target02 \| idle \| cycle 0/3 \| next=wait-for-input \| contract=missing \| reason=no-contract-files') 'doctor text should surface target02 missing contract.'

@{
    SchemaVersion = 1
    RunMode = 'target-autoloop'
    RunRoot = $runRoot
    Targets = @($target01)
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$start.ManifestPath) -Encoding UTF8

$doctorSelectedJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteProofDoctor.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$doctorSelectedText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteProofDoctor.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

Assert-True (-not [bool]$doctorSelectedJson.ManifestMismatch) 'doctor json should allow selected-target manifest scope without mismatch.'
Assert-True ([string]$doctorSelectedJson.ManifestScope -eq 'selected-targets') 'doctor json should surface selected-target manifest scope.'
Assert-True ([string]$doctorSelectedJson.ManifestMismatchReason -eq '') 'doctor json should not explain a mismatch for selected-target scope.'
Assert-True ([string]$doctorSelectedJson.OperationalRecommendation -eq '') 'doctor json should not recommend a new RunRoot for selected-target scope.'
Assert-True ($doctorSelectedText -match 'ManifestScope: selected-targets') 'doctor text should surface selected-target manifest scope.'

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

$doctorVisibleJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteProofDoctor.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$doctorVisibleText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteProofDoctor.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

Assert-True ([string]$doctorVisibleJson.ProofCloseout.State -eq 'final-pass') 'doctor json should mark visible-live proof as final-pass.'
Assert-True ([string]$doctorVisibleJson.ProofCloseout.Mode -eq 'final') 'doctor json should mark visible-live proof mode as final.'
Assert-True ([string]$doctorVisibleJson.ProofReceipt.ProofLevel -eq 'visible-live') 'doctor json should surface visible-live proof level when smoke receipt is absent.'
Assert-True ($doctorVisibleText -match 'CloseoutSummary: closeout: final-pass / mode=final / reason=visible-live-passed / proof=visible-live / source=shared-visible-acceptance') 'doctor text should surface the final-pass closeout summary.'

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

$doctorStaleJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteProofDoctor.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -AsJson | ConvertFrom-Json
$doctorStaleText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopRouteProofDoctor.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot

Assert-True ([bool]$doctorStaleJson.ManifestMismatch) 'doctor json should flag stale manifest/config mismatch.'
Assert-True ([string]$doctorStaleJson.ManifestMismatchReason -match 'enabled-targets-differ') 'doctor json should explain enabled target mismatch.'
Assert-True ((@($doctorStaleJson.ManifestReasonCodes) -contains 'enabled-targets-differ') -and (@($doctorStaleJson.BlockingReasonCodes) -contains 'enabled-targets-differ')) 'doctor json should expose stable mismatch reason codes.'
Assert-True ([string]$doctorStaleJson.OperationalRecommendation -match '새 RunRoot') 'doctor json should recommend preparing a new RunRoot.'
$doctorStaleTarget01 = @($doctorStaleJson.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]
$doctorStaleTarget02 = @($doctorStaleJson.Targets | Where-Object { [string]$_.TargetId -eq 'target02' } | Select-Object -First 1)[0]
Assert-True (-not [bool]$doctorStaleTarget01.InManifest) 'target01 should be marked absent from stale manifest.'
Assert-True ([bool]$doctorStaleTarget02.InManifest) 'target02 should be marked present in stale manifest.'
Assert-True (-not [bool]$doctorStaleTarget02.ManifestEnabled) 'target02 should be marked disabled in stale manifest.'
Assert-True ($doctorStaleText -match 'Manifest: exists=True runMode=target-autoloop targets=target02 enabled=\(none\) mismatch=True') 'doctor text should show stale manifest mismatch.'
Assert-True ($doctorStaleText -match 'OperationalRecommendation: 새 RunRoot 준비 후 감지 시작') 'doctor text should show the stale RunRoot recovery action.'

Write-Host 'show target autoloop route proof doctor ok'
