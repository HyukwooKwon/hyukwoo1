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
$sourcePath = Join-Path $root 'show-paired-run-summary.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('show-paired-run-summary-important-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $scriptCopyPath = Join-Path $tempRoot 'show-paired-run-summary.ps1'
    Copy-Item -LiteralPath $sourcePath -Destination $scriptCopyPath -Force

    $stubStatusPath = Join-Path $tempRoot 'show-paired-exchange-status.ps1'
    @'
param(
    [string]$ConfigPath,
    [string]$RunRoot,
    [int]$RecentFailureCount,
    [switch]$AsJson
)

$payload = [pscustomobject]@{
    RunRoot = $RunRoot
    AcceptanceReceipt = [pscustomobject]@{
        Path = (Join-Path $RunRoot '.state\live-acceptance-result.json')
        AcceptanceState = 'error'
        AcceptanceReason = 'seed-timeout'
    }
    Watcher = [pscustomobject]@{
        Status = 'running'
        StatusReason = 'await-seed-output'
        LastHandledResult = 'seed-pending'
        HeartbeatAt = '2026-04-27T07:40:00+09:00'
        StatusPath = (Join-Path $RunRoot '.state\watcher-status.json')
    }
    Counts = [pscustomobject]@{
        MessageFiles = 2
        ForwardedCount = 0
        SummaryPresentCount = 0
        ZipPresentCount = 0
        DonePresentCount = 0
        FailureLineCount = 1
        ManualAttentionCount = 0
        SubmitUnconfirmedCount = 1
        TargetUnresponsiveCount = 0
        ReadyToForwardCount = 0
    }
    Targets = @(
        [pscustomobject]@{
            PairId = 'pair01'
            RoleName = 'top'
            TargetId = 'target01'
            PartnerTargetId = 'target05'
            LatestState = 'seed-send-timeout'
            SourceOutboxState = 'empty'
            SeedSendState = 'timeout'
            SubmitState = 'unconfirmed'
            ManualAttentionRequired = $false
            SummaryPresent = $false
            ZipCount = 0
            DonePresent = $false
            ResultPresent = $false
            FailureCount = 1
            ForwardedAt = ''
            SourceOutboxUpdatedAt = ''
            SummaryModifiedAt = ''
            LatestZipModifiedAt = ''
            DoneModifiedAt = ''
            ResultModifiedAt = ''
            ProcessedPath = '__PROCESSED_TARGET01_PATH__'
            TargetFolder = (Join-Path $RunRoot 'pair01\target01')
        },
        [pscustomobject]@{
            PairId = 'pair01'
            RoleName = 'bottom'
            TargetId = 'target05'
            PartnerTargetId = 'target01'
            LatestState = 'source-summary-forbidden-literal'
            SourceOutboxState = 'source-summary-forbidden-literal'
            SeedSendState = ''
            SubmitState = ''
            ManualAttentionRequired = $false
            SummaryPresent = $false
            ZipCount = 0
            DonePresent = $false
            ResultPresent = $false
            FailureCount = 0
            ForwardedAt = '2026-04-27T07:40:05+09:00'
            SourceOutboxUpdatedAt = '2026-04-27T07:40:03+09:00'
            SummaryPath = '__TARGET05_IMPORTED_SUMMARY_PATH__'
            LatestZipPath = '__TARGET05_IMPORTED_REVIEW_PATH__'
            SummaryModifiedAt = '2026-04-27T07:40:06+09:00'
            LatestZipModifiedAt = '2026-04-27T07:40:07+09:00'
            DoneModifiedAt = '2026-04-27T07:40:08+09:00'
            ResultModifiedAt = '2026-04-27T07:40:09+09:00'
            TargetFolder = (Join-Path $RunRoot 'pair01\target05')
        }
    )
}

$payload | ConvertTo-Json -Depth 8
'@ | Set-Content -LiteralPath $stubStatusPath -Encoding UTF8

    $runRoot = Join-Path $tempRoot 'run_important'
    $stateRoot = Join-Path $runRoot '.state'
    $messagesRoot = Join-Path $runRoot 'messages'
    $target01Folder = Join-Path $runRoot 'pair01\target01'
    $target05Folder = Join-Path $runRoot 'pair01\target05'
    $contractRoot = Join-Path $tempRoot 'external-repo\.relay-contract\bottest-live-visible\run_important\pair01'
    $target01Outbox = Join-Path $contractRoot 'target01\source-outbox'
    $target05Outbox = Join-Path $contractRoot 'target05\source-outbox'
    $logsRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\logs'
    $runtimeRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\runtime'
    $inboxRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\inbox'
    $processedRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\processed'
    $target05ImportedSummaryPath = Join-Path $target05Folder 'summary.txt'
    $target05ImportedReviewPath = Join-Path $target05Folder 'reviewfile\review_target05_20260427_074007.zip'

    foreach ($path in @(
            $stateRoot,
            $messagesRoot,
            $target01Folder,
            $target05Folder,
            (Join-Path $target05Folder 'reviewfile'),
            $target01Outbox,
            $target05Outbox,
            (Join-Path $logsRoot 'typed-window-prepare\target01'),
            (Join-Path $logsRoot 'typed-window-prepare\target05'),
            (Join-Path $logsRoot 'ahk-debug\target01'),
            (Join-Path $logsRoot 'ahk-debug\target05'),
            $runtimeRoot,
            (Join-Path $inboxRoot 'target01'),
            $processedRoot
        )) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    @'
검토 결과 파일이 있으면 먼저 확인하고 최소 smoke 산출물을 만드세요.
[paired-exchange-seed]
[자동 경로 안내]
'@ | Set-Content -LiteralPath (Join-Path $messagesRoot 'target01.txt') -Encoding UTF8
    @'
[handoff-wait]
partner handoff 대기
'@ | Set-Content -LiteralPath (Join-Path $messagesRoot 'target05.txt') -Encoding UTF8

    $request01Path = Join-Path $target01Folder 'request.json'
    $request05Path = Join-Path $target05Folder 'request.json'
    '{"WorkRepoRoot":"C:\\dev\\python\\relay-workrepo-visible-smoke","AttemptId":"pair01-target01-attempt-0001","AttemptStartedAt":"2026-04-27T07:39:50+09:00","CreatedAt":"2026-04-27T07:39:50+09:00"}' | Set-Content -LiteralPath $request01Path -Encoding UTF8
    '{"WorkRepoRoot":"C:\\dev\\python\\relay-workrepo-visible-smoke","AttemptId":"pair01-target05-attempt-0001","AttemptStartedAt":"2026-04-27T07:39:50+09:00","CreatedAt":"2026-04-27T07:39:50+09:00"}' | Set-Content -LiteralPath $request05Path -Encoding UTF8

    $receipt = [pscustomobject]@{
        Stage = 'seed-publish-missing'
        Outcome = [pscustomobject]@{
            AcceptanceState = 'error'
            AcceptanceReason = 'seed publish not detected'
        }
        Seed = [pscustomobject]@{
            FinalState = 'timeout'
            SubmitState = 'unconfirmed'
            OutboxPublished = $false
        }
        Contract = [pscustomobject]@{
            PrimaryContractExternalized = $true
            ExternalRunRootUsed = $true
            BookkeepingExternalized = $true
            FullExternalized = $true
            InternalResidualRoots = @()
        }
        PhaseHistory = @()
    }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'live-acceptance-result.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $stateRoot 'seed-send-status.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $stateRoot 'pair-state.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $stateRoot 'watcher-status.json') -Encoding UTF8

    'partner summary ok' + [Environment]::NewLine + '여기에 고정문구 입력' | Set-Content -LiteralPath (Join-Path $target05Outbox 'summary.txt') -Encoding UTF8
    'partner review zip placeholder' | Set-Content -LiteralPath (Join-Path $target05Outbox 'review.zip') -Encoding UTF8
    $target05PublishedDir = Join-Path $target05Outbox '.published'
    New-Item -ItemType Directory -Path $target05PublishedDir -Force | Out-Null
    $target05ArchivedPublishPath = Join-Path $target05PublishedDir 'publish_20260427_074002_target05.ready.json'
    [ordered]@{
        SchemaVersion = '1.0.0'
        PairId = 'pair01'
        TargetId = 'target05'
        AttemptId = 'pair01-target05-attempt-0001'
        AttemptStartedAt = '2026-04-27T07:39:50+09:00'
        PublishSequence = 2
        PublishCycleId = 'pair01-target05-attempt-0001__publish_0002'
        SummaryPath = (Join-Path $target05Outbox 'summary.txt')
        ReviewZipPath = (Join-Path $target05Outbox 'review.zip')
        PublishedAt = '2026-04-27T07:40:02+09:00'
        PublishedBy = 'publish-paired-exchange-artifact.ps1'
        ValidationPassed = $true
        ValidationCompletedAt = '2026-04-27T07:40:02+09:00'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $target05ArchivedPublishPath -Encoding UTF8
    (Get-Item -LiteralPath (Join-Path $target05Outbox 'summary.txt')).LastWriteTime = [datetime]'2026-04-27T07:40:00'
    (Get-Item -LiteralPath (Join-Path $target05Outbox 'review.zip')).LastWriteTime = [datetime]'2026-04-27T07:40:01'
    (Get-Item -LiteralPath $target05ArchivedPublishPath).LastWriteTime = [datetime]'2026-04-27T07:40:02'
    'imported summary copy' | Set-Content -LiteralPath $target05ImportedSummaryPath -Encoding UTF8
    'imported review copy' | Set-Content -LiteralPath $target05ImportedReviewPath -Encoding UTF8
    [ordered]@{
        CompletedAt = '2026-04-27T07:40:07+09:00'
        SummaryPath = $target05ImportedSummaryPath
        LatestZipPath = $target05ImportedReviewPath
        ImportedZipPath = $target05ImportedReviewPath
        SourcePublishReadyPath = $target05ArchivedPublishPath
        SourcePublishedAt = '2026-04-27T07:40:02+09:00'
        SourcePublishAttemptId = 'pair01-target05-attempt-0001'
        SourcePublishSequence = 2
        SourcePublishCycleId = 'pair01-target05-attempt-0001__publish_0002'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $target05Folder 'result.json') -Encoding UTF8

    $manifest = [pscustomobject]@{
        Targets = @(
            [pscustomobject]@{
                TargetId = 'target05'
                RoleName = 'bottom'
                MessagePath = (Join-Path $messagesRoot 'target05.txt')
                RequestPath = $request05Path
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = ''
                SourceOutboxPath = $target05Outbox
                SourceSummaryPath = (Join-Path $target05Outbox 'summary.txt')
                SourceReviewZipPath = (Join-Path $target05Outbox 'review.zip')
                PublishReadyPath = (Join-Path $target05Outbox 'publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $contractRoot 'target05')
                ContractReferenceTimeUtc = '2026-04-27T07:33:55Z'
                PairRunRoot = (Join-Path $runRoot 'pair01')
                AttemptId = 'pair01-target05-attempt-0001'
                AttemptStartedAt = '2026-04-27T07:39:50+09:00'
                InitialRoleMode = 'handoff_wait'
            },
            [pscustomobject]@{
                TargetId = 'target01'
                RoleName = 'top'
                MessagePath = (Join-Path $messagesRoot 'target01.txt')
                RequestPath = $request01Path
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = 'C:\dev\python\relay-workrepo-visible-smoke\reviewfile\seed_review_input_latest.zip'
                SourceOutboxPath = $target01Outbox
                SourceSummaryPath = (Join-Path $target01Outbox 'summary.txt')
                SourceReviewZipPath = (Join-Path $target01Outbox 'review.zip')
                PublishReadyPath = (Join-Path $target01Outbox 'publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $contractRoot 'target01')
                ContractReferenceTimeUtc = '2026-04-27T07:33:55Z'
                PairRunRoot = (Join-Path $runRoot 'pair01')
                AttemptId = 'pair01-target01-attempt-0001'
                AttemptStartedAt = '2026-04-27T07:39:50+09:00'
                InitialRoleMode = 'seed'
            }
        )
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runRoot 'manifest.json') -Encoding UTF8

    'prepare ok' | Set-Content -LiteralPath (Join-Path $logsRoot 'typed-window-prepare\target01\latest.log') -Encoding UTF8
    @'
[20260427073955] send_begin hwnd=111
[20260427073956] terminal_paste bytes=123
[20260427073958] submit_attempt mode=enter index=1/1
[20260427074000] submit_complete
'@ | Set-Content -LiteralPath (Join-Path $logsRoot 'ahk-debug\target01\send.log') -Encoding UTF8
    @'
[20260427074001] send_begin hwnd=222
[20260427074002] terminal_paste bytes=234
[20260427074003] submit_attempt mode=enter index=1/1
[20260427074004] submit_complete
'@ | Set-Content -LiteralPath (Join-Path $logsRoot 'ahk-debug\target05\send.log') -Encoding UTF8
    'router running' | Set-Content -LiteralPath (Join-Path $logsRoot 'router.log') -Encoding UTF8
    $processedTarget01Path = Join-Path $processedRoot 'target01__message.ready.txt'
    'processed payload envelope' | Set-Content -LiteralPath $processedTarget01Path -Encoding UTF8
    '검토 결과 파일이 있으면 먼저 확인하고 최소 smoke 산출물을 만드세요.' | Set-Content -LiteralPath ($processedTarget01Path + '.payload.txt') -Encoding UTF8
    (Get-Item -LiteralPath $processedTarget01Path).LastWriteTime = [datetime]'2026-04-27T07:39:57'
    $stubStatusText = Get-Content -LiteralPath $stubStatusPath -Raw -Encoding UTF8
    $stubStatusText = $stubStatusText.Replace('__PROCESSED_TARGET01_PATH__', $processedTarget01Path)
    $stubStatusText = $stubStatusText.Replace('__TARGET05_IMPORTED_SUMMARY_PATH__', $target05ImportedSummaryPath)
    $stubStatusText = $stubStatusText.Replace('__TARGET05_IMPORTED_REVIEW_PATH__', $target05ImportedReviewPath)
    Set-Content -LiteralPath $stubStatusPath -Value $stubStatusText -Encoding UTF8

    $configPath = Join-Path $tempRoot 'settings.psd1'
@"
@{
    LogsRoot = '$logsRoot'
    RuntimeRoot = '$runtimeRoot'
    InboxRoot = '$inboxRoot'
    ProcessedRoot = '$processedRoot'
    PairTest = @{
        ForbiddenArtifactLiterals = @('여기에 고정문구 입력')
        ForbiddenArtifactRegexes = @('이렇게 계획개선해봤어')
    }
}
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

    $raw = & $scriptCopyPath -ConfigPath $configPath -RunRoot $runRoot -AsJson
    $summary = $raw | ConvertFrom-Json

    Assert-True ([string]$summary.ImportantSummary.TextPath -eq (Join-Path $stateRoot 'important-summary.txt')) 'important summary text path should be written under runRoot\\.state.'
    Assert-True ([string]$summary.ImportantSummary.JsonPath -eq (Join-Path $stateRoot 'important-summary.json')) 'important summary json path should be written under runRoot\\.state.'
    Assert-True (Test-Path -LiteralPath $summary.ImportantSummary.TextPath -PathType Leaf) 'important summary text file should exist.'
    Assert-True (Test-Path -LiteralPath $summary.ImportantSummary.JsonPath -PathType Leaf) 'important summary json file should exist.'

    $important = $summary.ImportantSummary.Data
    Assert-True ([bool]$important.Contract.PrimaryContractExternalized) 'important summary should include externalization contract flags.'
    Assert-True ([string]$important.KeyPaths.RouterLogPath -eq (Join-Path $logsRoot 'router.log')) 'important summary should surface router log path.'
    Assert-True (@($important.Targets).Count -eq 2) 'important summary should surface both targets.'
    Assert-True (@($important.PairRouteMatrix).Count -eq 1) 'important summary should surface pair route matrix.'
    Assert-True ([string]$important.Freshness.GeneratedAt -ne '') 'important summary should surface freshness generated timestamp.'
    Assert-True ([string]$important.Freshness.NewestObservedSignalAt -ne '') 'important summary should surface newest observed signal timestamp.'
    Assert-True ([string]$important.Freshness.NewestProgressSignalAt -ne '') 'important summary should surface newest progress signal timestamp.'
    Assert-True ($null -ne $important.Freshness.ProgressStale) 'important summary should surface progress staleness.'
    Assert-True (@($important.RecentEvents).Count -ge 3) 'important summary should surface recent key events.'
    Assert-True ([string]$important.OperatorFocus.AttentionLevel -eq 'action-required') 'important summary should surface operator attention level.'
    Assert-True ([string]$important.OperatorFocus.CurrentBottleneck -match 'seed payload was not observed') 'important summary should interpret the current bottleneck.'
    Assert-True ([string]$important.OperatorFocus.NextExpectedStep -match 'source-outbox publish') 'important summary should surface the next expected step.'
    Assert-True ((@($important.RecentEvents | Where-Object { [string]$_.Text -match 'request\.json prepared|prepare log updated|AHK log updated' })).Count -gt 0) 'important summary should include recent artifact or log events.'
    Assert-True ((@($important.RecentEvents | Where-Object { [bool]$_.IsProgressSignal })).Count -gt 0) 'important summary should mark progress events separately from supporting signals.'
    Assert-True ((@($important.RecentEvents | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.EventClass) })).Count -gt 0) 'important summary should classify event types in JSON.'
    Assert-True ([string]@($important.Targets)[0].TargetId -eq 'target01') 'important summary should prioritize incomplete target ahead of already-ready targets.'

    $target01 = @($important.Targets | Where-Object { [string]$_.TargetId -eq 'target01' })[0]
    Assert-True ([string]$target01.MessagePath -eq (Join-Path $messagesRoot 'target01.txt')) 'target01 message path should be surfaced.'
    Assert-True ([string]$target01.ProcessedPath -eq $processedTarget01Path) 'target01 processed path should be surfaced.'
    Assert-True ([string]$target01.ProcessedPayloadSnapshotPath -eq ($processedTarget01Path + '.payload.txt')) 'target01 processed payload snapshot path should be surfaced.'
    Assert-True ([string]$target01.AttemptId -eq 'pair01-target01-attempt-0001') 'important summary should surface attempt id.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target01.AttemptStartedAt)) 'important summary should surface attempt start time.'
    Assert-True ([string]$target01.EffectiveWorkingDirectory -eq 'C:\dev\python\relay-workrepo-visible-smoke') 'important summary should surface effective working directory.'
    Assert-True ([string]$target01.PairRunRoot -eq (Join-Path $runRoot 'pair01')) 'important summary should surface pair run root.'
    Assert-True ([string]$target01.CurrentTriggerSourceOutboxPath -eq $target01Outbox) 'important summary should surface trigger source outbox path.'
    Assert-True ([bool]$target01.ProcessedPayloadSnapshot.Exists) 'target01 processed payload snapshot should be surfaced as an existing file.'
    Assert-True ([string]$target01.MessagePreview -match 'paired-exchange-seed') 'target01 message preview should include actual payload lines.'
    Assert-True ([string]$target01.ProcessedPayloadSnapshotPreview -match '최소 smoke 산출물을 만드세요') 'target01 processed payload snapshot preview should include the exact sent payload text.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target01.Timeline.SubmitStartedAt)) 'important summary should surface submit start time from AHK logs.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target01.Timeline.SubmitCompletedAt)) 'important summary should surface submit completion time from AHK logs.'
    Assert-True (-not [bool]$target01.SourceSummary.Exists) 'missing summary should be reflected in important summary.'
    Assert-True (-not [bool]$target01.ContractArtifactsReady) 'target01 contract readiness should be false when files are missing.'
    Assert-True (@($target01.MissingContractFiles).Count -eq 3) 'target01 missing contract files should be enumerated.'
    Assert-True ([string]$target01.LatestPrepareLogPath -eq (Join-Path $logsRoot 'typed-window-prepare\target01\latest.log')) 'latest prepare log path should be surfaced.'

    $target05 = @($important.Targets | Where-Object { [string]$_.TargetId -eq 'target05' })[0]
    Assert-True ([bool]$target05.SourceSummaryContainsForbiddenLiteral) 'important summary should surface forbidden literal contamination in source summary.'
    Assert-True ([bool]$target05.ForwardBlockedByForbiddenLiteral) 'important summary should surface forward blocked by forbidden literal.'
    Assert-True (-not [bool]$target05.PayloadContainsForbiddenLiteral) 'important summary should distinguish clean sent payload from contaminated artifact.'
    Assert-True ([string]$target05.EffectiveWorkingDirectory -eq 'C:\dev\python\relay-workrepo-visible-smoke') 'important summary should surface effective working directory for partner target.'
    Assert-True ([string]$target05.PairRunRoot -eq (Join-Path $runRoot 'pair01')) 'important summary should surface pair run root for partner target.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target05.Timeline.SummaryWrittenAt)) 'important summary should surface source summary write time.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target05.Timeline.ReviewZipWrittenAt)) 'important summary should surface source review zip write time.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target05.Timeline.PublishReadyWrittenAt)) 'important summary should surface publish marker write time.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target05.Timeline.HandoffOpenedAt)) 'important summary should surface handoff open time.'
    Assert-True ([string]$target05.CurrentTriggerSummaryPath -eq (Join-Path $target05Outbox 'summary.txt')) 'important summary should surface trigger summary path.'
    Assert-True ([string]$target05.CurrentTriggerReviewZipPath -eq (Join-Path $target05Outbox 'review.zip')) 'important summary should surface trigger review zip path.'
    Assert-True ([string]$target05.CurrentTriggerPublishReadyPath -eq (Join-Path $target05Outbox 'publish.ready.json')) 'important summary should surface trigger publish path.'
    Assert-True ([string]$target05.CurrentTriggerSourceOutboxPath -eq $target05Outbox) 'important summary should surface trigger outbox path.'
    Assert-True ([string]$target05.CurrentObservedPublishReadyPath -eq $target05ArchivedPublishPath) 'important summary should surface observed archived publish path when live marker has been archived.'
    Assert-True ([string]$target05.CurrentArchivedPublishReadyPath -eq $target05ArchivedPublishPath) 'important summary should surface archived publish path explicitly.'
    Assert-True ([int]$target05.CurrentObservedPublishSequence -eq 2) 'important summary should surface observed publish sequence.'
    Assert-True ([string]$target05.CurrentObservedPublishCycleId -eq 'pair01-target05-attempt-0001__publish_0002') 'important summary should surface observed publish cycle id.'
    Assert-True ([string]$target05.CurrentImportedReviewCopyPath -eq $target05ImportedReviewPath) 'important summary should surface imported review copy path.'
    Assert-True ([int]$target05.CurrentImportedSourcePublishSequence -eq 2) 'important summary should surface imported source publish sequence.'
    Assert-True ([string]$target05.CurrentImportedSourcePublishCycleId -eq 'pair01-target05-attempt-0001__publish_0002') 'important summary should surface imported source publish cycle id.'
    Assert-True (-not [bool]$target05.CurrentArtifactsAheadOfObservedPublish) 'important summary should not report unpublished artifact drift for the clean archived publish fixture.'
    Assert-True ([bool]$target05.TimelineChecks.HandoffOpenedAfterPublish) 'important summary should confirm handoff opens after publish.'
    Assert-True ([bool]$target05.TimelineChecks.ImportedCopyAfterTrigger) 'important summary should not report imported copy before trigger for archived publish scenario.'
    Assert-True ([string]$target05.FirstOrderingViolation -eq '') 'important summary should leave ordering violation empty when ordering is valid.'

    $pairRoute = @($important.PairRouteMatrix | Where-Object { [string]$_.PairId -eq 'pair01' })[0]
    Assert-True ($null -ne $pairRoute) 'important summary should include pair route row for pair01.'
    Assert-True ([string]$pairRoute.PairWorkRepoRoot -eq 'C:\dev\python\relay-workrepo-visible-smoke') 'pair route matrix should surface shared work repo root.'
    Assert-True ([string]$pairRoute.PairRunRoot -eq (Join-Path $runRoot 'pair01')) 'pair route matrix should surface pair run root.'
    Assert-True ([bool]$pairRoute.TargetsShareWorkRepoRoot) 'pair route matrix should confirm same pair shares work repo root.'
    Assert-True ([bool]$pairRoute.TargetsSharePairRunRoot) 'pair route matrix should confirm same pair shares pair run root.'
    Assert-True ([bool]$pairRoute.TargetOutboxesDistinct) 'pair route matrix should confirm target outboxes are distinct.'
    Assert-True (-not [bool]$pairRoute.SharesWorkRepoRootWithOtherPairs) 'pair route matrix should not report cross-pair repo sharing in single pair fixture.'
    Assert-True ([string]$pairRoute.RouteState -eq 'aligned') 'pair route matrix should mark aligned route state.'
    Assert-True ([string]$pairRoute.TopSourceOutboxPath -eq $target01Outbox) 'pair route matrix should surface top outbox path.'
    Assert-True ([string]$pairRoute.BottomSourceOutboxPath -eq $target05Outbox) 'pair route matrix should surface bottom outbox path.'

    $importantText = Get-Content -LiteralPath $summary.ImportantSummary.TextPath -Raw -Encoding UTF8
    Assert-True ($importantText -match '\[important-summary\]') 'text summary should include important-summary header.'
    Assert-True ($importantText -match '\[freshness\]') 'text summary should include freshness section.'
    Assert-True ($importantText -match '\[operator-focus\]') 'text summary should include operator-focus section.'
    Assert-True ($importantText -match '\[recent-events\]') 'text summary should include recent-events section.'
    Assert-True ($importantText -match '\[pair-route-matrix\]') 'text summary should include pair route matrix section.'
    Assert-True ($importantText -match 'CurrentBottleneck: seed payload was not observed') 'text summary should include interpreted bottleneck.'
    Assert-True ($importantText -match 'NewestObservedSignalAt: ') 'text summary should include newest observed signal timestamp.'
    Assert-True ($importantText -match 'NewestProgressSignalAt: ') 'text summary should include newest progress signal timestamp.'
    Assert-True ($importantText -match 'ProgressStale: ') 'text summary should include progress staleness.'
    Assert-True ($importantText -match 'request\.json prepared|prepare log updated|AHK log updated') 'text summary should include recent event lines.'
    Assert-True ($importantText -match 'ContractPathMode: external-workrepo') 'text summary should include contract mode.'
    Assert-True ($importantText -match 'ContractArtifactsReady: False') 'text summary should include target contract readiness.'
    Assert-True ($importantText -match 'PairRunRoot: ') 'text summary should include pair run root.'
    Assert-True ($importantText -match 'CurrentTriggerSourceOutboxPath: ') 'text summary should include trigger source outbox path.'
    Assert-True ($importantText -match 'TargetsShareWorkRepoRoot: True') 'text summary should include pair route alignment state.'
    Assert-True ($importantText -match 'TargetOutboxesDistinct: True') 'text summary should include pair outbox distinct state.'
    Assert-True ($importantText -match 'ProcessedPayloadSnapshotPath: ') 'text summary should include processed payload snapshot path.'
    Assert-True ($importantText -match 'AttemptId: pair01-target01-attempt-0001') 'text summary should include attempt id.'
    Assert-True ($importantText -match 'CurrentTriggerSummaryPath: ') 'text summary should include trigger summary path.'
    Assert-True ($importantText -match 'CurrentImportedReviewCopyPath: ') 'text summary should include imported review copy path.'
    Assert-True ($importantText -match 'CurrentObservedPublishReadyPath: ') 'text summary should include observed publish path.'
    Assert-True ($importantText -match 'CurrentObservedPublishSequence: 2') 'text summary should include observed publish sequence.'
    Assert-True ($importantText -match 'CurrentImportedSourcePublishSequence: 2') 'text summary should include imported source publish sequence.'
    Assert-True ($importantText -match 'Timeline: summaryAt=') 'text summary should include trigger timeline.'
    Assert-True ($importantText -match 'TimelineDispatch: routerProcessedAt=') 'text summary should include dispatch timeline.'
    Assert-True ($importantText -match 'TimelineImport: importedSummaryAt=') 'text summary should include import timeline.'
    Assert-True ($importantText -match 'TimelineChecks: publishAfterArtifacts=') 'text summary should include timeline checks.'
    Assert-True ($importantText -match 'FirstOrderingViolation:') 'text summary should include first ordering violation field.'
    Assert-True ($importantText -match 'ProcessedPayloadSnapshotPreview:') 'text summary should include processed payload snapshot preview.'
    Assert-True ($importantText -match 'summary.txt: exists=False') 'text summary should show missing output files clearly.'
    Assert-True ($importantText -match 'SourceSummaryContainsForbiddenLiteral: True') 'text summary should surface summary contamination state.'
    Assert-True ($importantText -match 'ForwardBlockedByForbiddenLiteral: True') 'text summary should surface handoff block state.'
    Assert-True ($importantText -match 'PayloadContainsForbiddenLiteral: False') 'text summary should distinguish payload from artifact contamination.'

    Write-Host 'show-paired-run-summary important summary ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
