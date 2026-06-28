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

$tmpRoot = Join-Path $root '_tmp\Test-ShowTargetAutoloopSeedComposer'
$runRoot = Join-Path $tmpRoot 'run_target_autoloop_seed_composer'
$configPath = Join-Path $tmpRoot 'settings.test.psd1'
$inboxTarget01 = Join-Path $tmpRoot 'inbox\target01'
$inboxTarget02 = Join-Path $tmpRoot 'inbox\target02'
$externalInputRoot = 'C:\dev\python\relay-target-autoloop-seed-input-smoke'
$referenceInputPath = Join-Path $externalInputRoot 'reference-input.md'
$automationRepoMissingInputPath = Join-Path $tmpRoot 'missing-input.md'

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $inboxTarget01 -Force | Out-Null
New-Item -ItemType Directory -Path $inboxTarget02 -Force | Out-Null
New-Item -ItemType Directory -Path $externalInputRoot -Force | Out-Null
'reference input for target-autoloop seed composer' | Set-Content -LiteralPath $referenceInputPath -Encoding UTF8

$configText = @"
@{
    LaneName = 'bottest-live-visible'
    Targets = @(
        @{ Id = 'target01'; Folder = '$($inboxTarget01.Replace("'", "''"))'; WindowTitle = 'Target01'; FixedSuffix = '항상 마지막에 helper를 실행하세요.' }
        @{ Id = 'target02'; Folder = '$($inboxTarget02.Replace("'", "''"))'; WindowTitle = 'Target02'; FixedSuffix = '공유 target02 문구' }
    )
    TargetAutoloop = @{
        Enabled = `$true
        RunMode = 'target-autoloop'
        DispatchQueuedCommandsInline = `$true
        PollIntervalMs = 200
        RunRootBase = '$($tmpRoot.Replace("'", "''"))'
        Targets = @(
            @{ TargetId = 'target01'; Enabled = `$true; TriggerKinds = @('input-file', 'publish-ready'); MaxCycleCount = 2 }
            @{ TargetId = 'target02'; Enabled = `$true; FixedSuffix = ''; TriggerKinds = @('input-file'); MaxCycleCount = 3 }
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
$manifest = Get-Content -LiteralPath $start.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target01 = @($manifest.Targets | Where-Object { [string]$_.TargetId -eq 'target01' } | Select-Object -First 1)[0]

$composerJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -TaskText '다음 cycle 작업을 준비하고 결과를 요약하세요.' `
    -ReferenceInputPath $referenceInputPath `
    -AsJson | ConvertFrom-Json
$composerText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -TaskText '다음 cycle 작업을 준비하고 결과를 요약하세요.' `
    -ReferenceInputPath $referenceInputPath
$composerCheckJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -TaskText '누락된 입력 파일 경고를 확인하세요.' `
    -ReferenceInputPath $automationRepoMissingInputPath `
    -AsJson | ConvertFrom-Json
$composerCheckText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -TaskText '누락된 입력 파일 경고를 확인하세요.' `
    -ReferenceInputPath $automationRepoMissingInputPath
$composerExplicitNoneJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target02 `
    -TaskText 'Autoloop 전용 고정문구 없음 모드를 확인하세요.' `
    -AsJson | ConvertFrom-Json
$noStatusRunRoot = Join-Path $tmpRoot 'run_without_status_rows'
$composerNoStatusJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $noStatusRunRoot `
    -TargetId target02 `
    -TaskText 'status 파일 없이도 시작문을 계산하세요.' `
    -AsJson | ConvertFrom-Json

Assert-True ([string]$composerJson.TargetId -eq 'target01') 'seed composer should preserve selected target.'
Assert-True ([string]$composerJson.RunRootMode -eq 'selected') 'seed composer should preserve selected run root mode.'
Assert-True ([string]$composerJson.RouteBadge -eq 'ROUTE EMPTY') 'seed composer should mark an empty contract path as ROUTE EMPTY before artifacts exist.'
Assert-True (@($composerJson.AvailableTargetIds).Count -eq 2) 'seed composer should list available target ids.'
Assert-True ([string]$composerJson.ResolvedOutputPaths.SourceSummaryPath -eq [string]$target01.SourceSummaryPath) 'seed composer should expose target01 summary path.'
Assert-True ([string]$composerJson.ResolvedOutputPaths.PublishReadyPath -eq [string]$target01.PublishReadyPath) 'seed composer should expose target01 publish marker path.'
Assert-True ([string]$composerJson.ResolvedOutputPaths.PathSource -eq 'manifest') 'seed composer should use manifest paths for an existing RunRoot.'
Assert-True ([string]$composerJson.ContractPathProof.StrictPathSource -eq 'manifest') 'seed composer should expose manifest as the strict path source.'
Assert-True (-not [bool]$composerJson.ContractPathProof.ConfigDriftDetected) 'seed composer should not report config drift when config and manifest paths match.'
Assert-True ([string]$composerJson.ContractText -match 'strict path proof') 'seed composer contract text should include strict path proof.'
Assert-True ([string]$composerJson.ManualStartText -match [regex]::Escape([string]$target01.SourceSummaryPath)) 'manual start text should include summary path.'
Assert-True ([string]$composerJson.ManualStartText -match [regex]::Escape([string]$target01.SourceReviewZipPath)) 'manual start text should include review.zip path.'
Assert-True ([string]$composerJson.InputBadge -eq 'INPUT READY') 'existing external reference input should be marked INPUT READY.'
Assert-True ([string]$composerJson.InputSummary -match '추가 입력 파일:') 'seed composer should expose input summary.'
Assert-True ([string]$composerJson.InputSummary -match 'present / external') 'input summary should surface existence and external scope.'
Assert-True ([string]$composerJson.InputSummary -match [regex]::Escape($referenceInputPath)) 'input summary should include the reference input path.'
Assert-True ([string]$composerJson.InputRecommendation.Action -eq 'open-input') 'existing external input should recommend opening the file.'
Assert-True ([string]$composerJson.InputRecommendation.Label -eq '입력 파일 열기') 'ready input should expose the open-input label.'
Assert-True ([string]$composerJson.SeedRuntimeSummary -eq 'runtime: pendingInput=0 / claimed=0 / queued=0 / processing=0') 'seed composer should expose the initial runtime summary.'
Assert-True ([string]$composerJson.OperationalState -eq 'warning') 'not-configured router session should be surfaced as an operational warning.'
Assert-True ([string]$composerJson.OperationalReason -eq 'router-session-not-ready') 'not-configured router warning should expose a router-session-not-ready reason.'
Assert-True ([string]$composerJson.OperationalNotice -match 'router/runtime') 'not-configured router warning should explain the router/runtime session issue.'
Assert-True ([bool]$composerJson.QueueAllowed) 'ready external input should allow target-autoloop seed queueing.'
Assert-True ([string]$composerJson.QueueSummary -match 'queue: ready') 'queue summary should surface the ready state.'
Assert-True ([string]$composerJson.QueuePromptText -match '\[작업 내용\]') 'queue prompt text should keep the operator task block.'
Assert-True ([string]$composerJson.QueuePromptText -match [regex]::Escape($referenceInputPath)) 'queue prompt text should keep the operator reference input path.'
Assert-True (-not ([string]$composerJson.QueuePromptText -match [regex]::Escape([string]$target01.SourceSummaryPath))) 'queue prompt text should omit generated contract paths because watcher appends them.'
Assert-True (-not ([string]$composerJson.QueuePromptText -match 'publish helper 실행')) 'queue prompt text should omit publish helper instructions because watcher appends scaffold separately.'
Assert-True (-not ([string]$composerJson.QueuePromptText -match '항상 마지막에 helper를 실행하세요')) 'queue prompt text should omit fixed suffix because watcher appends it automatically.'
Assert-True ([string]$composerJson.ManualStartText -match '항상 마지막에 helper를 실행하세요') 'manual start text should include fixed suffix guidance.'
Assert-True ([string]$composerJson.ManualStartText -match '(?s)\[고정문구 / 항상 포함\].*\[작업 내용\]') 'manual start text should place the fixed suffix before task details.'
Assert-True ([string]$composerExplicitNoneJson.FixedSuffix -eq '') 'explicit empty TargetAutoloop FixedSuffix should resolve to no fixed suffix.'
Assert-True (-not ([string]$composerExplicitNoneJson.ManualStartText -match '공유 target02 문구')) 'explicit empty TargetAutoloop FixedSuffix should block shared target fallback.'
Assert-True (-not [bool]$composerExplicitNoneJson.PublishReadyTriggerEnabled) 'seed composer should surface when publish-ready trigger is disabled.'
Assert-True ([string]$composerExplicitNoneJson.Readiness -match 'publish-ready') 'seed composer should warn when publish-ready trigger is disabled.'
Assert-True (-not [bool]$composerExplicitNoneJson.QueueAllowed) 'publish-ready disabled target should not allow target-autoloop seed queueing.'
Assert-True ([string]$composerExplicitNoneJson.QueueBlockedReason -match 'publish-ready') 'publish-ready disabled queue block should explain the missing trigger.'
Assert-True ([string]$composerNoStatusJson.TargetId -eq 'target02') 'seed composer should preserve selected target even before status rows exist.'
Assert-True ([string]$composerNoStatusJson.ManualStartText -match 'status 파일 없이도 시작문을 계산하세요') 'seed composer should render manual start text before status rows exist.'
Assert-True ([int]$composerNoStatusJson.CycleCount -eq 0) 'seed composer should default cycle count when status rows are absent.'
Assert-True ([string]$composerJson.PublishHelperCommand -match '^pwsh ') 'seed composer publish helper command should use pwsh.'
Assert-True ([string]$composerJson.PublishHelperCommand -match 'Publish-TargetAutoloopArtifact.ps1') 'seed composer should expose publish helper command.'
Assert-True ([string]$composerJson.DeliveryNextAction -match 'summary\.txt|publish\.ready\.json|watcher|router') 'seed composer should expose a delivery next action.'
Assert-True ([string]$composerJson.DeliveryNextActionCode) 'seed composer should expose a delivery next action code.'
Assert-True ([string]$composerJson.DeliveryNextActionLabel) 'seed composer should expose a delivery next action label.'
Assert-True ($composerText -match '\[8 Cell Autoloop Seed Composer\]') 'text mode should render the full preview header.'
Assert-True ($composerText -match 'input=INPUT READY') 'text mode should surface the input badge near the header.'
Assert-True ($composerText -match '\[다음 확인\]') 'text mode should show a delivery next action line.'
Assert-True ($composerText -match [regex]::Escape([string]$composerJson.DeliveryNextActionLabel)) 'text mode should include the compact delivery next action label.'
Assert-True ($composerText -match '추가 입력 파일:') 'text mode should surface input summary near the header.'
Assert-True ($composerText -match 'runtime: pendingInput=0 / claimed=0 / queued=0 / processing=0') 'text mode should surface the runtime summary near the header.'
Assert-True ($composerText -match '\[권장 입력 조치\] 입력 파일 열기') 'text mode should include the input recommendation line.'
Assert-True ($composerText -match [regex]::Escape([string]$target01.PublishReadyPath)) 'text mode should include publish.ready path.'
Assert-True ([string]$composerCheckJson.InputBadge -eq 'INPUT CHECK') 'missing automation-repo input should be marked INPUT CHECK.'
Assert-True ([string]$composerCheckJson.InputCheckReason -eq 'missing+automation-repo') 'missing automation-repo input should surface both check reasons.'
Assert-True ([string]$composerCheckJson.InputWarning -match 'automation repo') 'check warning should mention the automation repo restriction.'
Assert-True ([string]$composerCheckJson.InputRecommendation.Action -eq 'browse-external-input') 'automation-repo input should recommend reselecting an external file.'
Assert-True ([string]$composerCheckJson.InputRecommendation.Label -eq '외부 repo 파일 다시 선택') 'check recommendation label should guide the operator to an external file.'
Assert-True (-not [bool]$composerCheckJson.QueueAllowed) 'INPUT CHECK should block target-autoloop seed queueing.'
Assert-True ([string]$composerCheckJson.QueueBlockedReason -match 'automation repo') 'queue blocked reason should reuse the input warning.'
Assert-True ($composerCheckText -match 'input=INPUT CHECK') 'text mode should surface INPUT CHECK badge near the header.'
Assert-True ($composerCheckText -match 'inputReason=missing\+automation-repo') 'text mode should surface the detailed input check reason.'
Assert-True ($composerCheckText -match '\[입력 파일 확인 필요\]') 'text mode should include an explicit input warning line.'
Assert-True ($composerCheckText -match '\[권장 입력 조치\] 외부 repo 파일 다시 선택') 'check text mode should include the input recommendation line.'

$zipPayloadPath = Join-Path $tmpRoot 'review-payload.txt'
'review zip payload for dispatch delay composer check' | Set-Content -LiteralPath $zipPayloadPath -Encoding UTF8
New-Item -ItemType Directory -Path (Split-Path -Parent ([string]$target01.SourceSummaryPath)) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent ([string]$target01.SourceReviewZipPath)) -Force | Out-Null
'summary for dispatch delay composer check' | Set-Content -LiteralPath ([string]$target01.SourceSummaryPath) -Encoding UTF8
Compress-Archive -LiteralPath $zipPayloadPath -DestinationPath ([string]$target01.SourceReviewZipPath) -Force
$publishDelay = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Publish-TargetAutoloopArtifact.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -OutputFingerprint output-fingerprint-seed-composer-delay-001 `
    -Overwrite `
    -AsJson | ConvertFrom-Json
$state = Get-Content -LiteralPath ([string]$start.StatePath) -Raw -Encoding UTF8 | ConvertFrom-Json
$state.Targets.target01.Phase = 'dispatch-delay'
$state.Targets.target01.NextAction = 'wait-dispatch-delay'
$state.Targets.target01.LastHandledOutputFingerprint = [string]$publishDelay.Marker.OutputFingerprint
$state.Targets.target01.LastDispatchState = 'dispatch-delay-waiting'
$state.Targets.target01.PendingDispatchDelaySeconds = 30
$state.Targets.target01.PendingDispatchEligibleAt = '2030-01-01T00:00:00.0000000+00:00'
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$start.StatePath) -Encoding UTF8
$composerDelayJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -TaskText 'dispatch delay 대기 상태를 확인하세요.' `
    -AsJson | ConvertFrom-Json
Assert-True ([string]$composerDelayJson.DeliveryNextActionCode -eq 'wait-dispatch-delay') 'dispatch-delay state should surface a dispatch delay next action code.'
Assert-True ([string]$composerDelayJson.DeliveryNextActionLabel -eq 'dispatch delay 확인') 'dispatch-delay state should expose a compact delay label.'
Assert-True ([string]$composerDelayJson.Delivery.Router -eq 'dispatch-delay-waiting') 'dispatch-delay state should not be described as a router delivery failure.'
Assert-True ([string]$composerDelayJson.DeliveryNextAction -match 'eligibleAt') 'dispatch-delay action should include the eligible-at hint.'

$state = Get-Content -LiteralPath ([string]$start.StatePath) -Raw -Encoding UTF8 | ConvertFrom-Json
$state.Targets.target01.Phase = 'limit-reached'
$state.Targets.target01.CycleCount = 2
$state.Targets.target01.MaxCycleCount = 2
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$start.StatePath) -Encoding UTF8
$composerLimitJson = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -TaskText '이미 cycle limit에 도달한 상태를 확인하세요.' `
    -AsJson | ConvertFrom-Json
$composerLimitText = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Show-TargetAutoloopSeedComposer.ps1') `
    -ConfigPath $configPath `
    -RunRoot $runRoot `
    -TargetId target01 `
    -TaskText '이미 cycle limit에 도달한 상태를 확인하세요.'
Assert-True ([string]$composerLimitJson.OperationalState -eq 'blocked') 'limit-reached target should surface an operational block.'
Assert-True ([string]$composerLimitJson.OperationalReason -eq 'max-cycle-reached') 'limit-reached target should expose a max-cycle reason.'
Assert-True ([bool]$composerLimitJson.OperationalBlocksQueue) 'limit-reached target should block queue registration.'
Assert-True (-not [bool]$composerLimitJson.QueueAllowed) 'limit-reached target should not allow queueing.'
Assert-True ([string]$composerLimitJson.QueueBlockedReason -match 'MaxCycleCount') 'limit-reached queue block should explain MaxCycleCount.'
Assert-True ([string]$composerLimitJson.Readiness -match 'MaxCycleCount') 'limit-reached readiness should explain MaxCycleCount.'
Assert-True ($composerLimitText -match '\[시작 가능 여부\].*MaxCycleCount') 'text mode should show the limit-reached start warning.'

Write-Host 'show target autoloop seed composer ok'
