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
            ProcessedPath = '__PROCESSED_TARGET01_PATH__'
            TargetFolder = (Join-Path $RunRoot 'pair01\target01')
        },
        [pscustomobject]@{
            PairId = 'pair01'
            RoleName = 'bottom'
            TargetId = 'target05'
            PartnerTargetId = 'target01'
            LatestState = 'handoff-wait'
            SourceOutboxState = 'empty'
            SeedSendState = ''
            SubmitState = ''
            ManualAttentionRequired = $false
            SummaryPresent = $false
            ZipCount = 0
            DonePresent = $false
            ResultPresent = $false
            FailureCount = 0
            ForwardedAt = ''
            SourceOutboxUpdatedAt = ''
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

    foreach ($path in @(
            $stateRoot,
            $messagesRoot,
            $target01Folder,
            $target05Folder,
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
    '{"WorkRepoRoot":"C:\\dev\\python\\relay-workrepo-visible-smoke"}' | Set-Content -LiteralPath $request01Path -Encoding UTF8
    '{"WorkRepoRoot":"C:\\dev\\python\\relay-workrepo-visible-smoke"}' | Set-Content -LiteralPath $request05Path -Encoding UTF8

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

    'partner summary ok' | Set-Content -LiteralPath (Join-Path $target05Outbox 'summary.txt') -Encoding UTF8
    'partner review zip placeholder' | Set-Content -LiteralPath (Join-Path $target05Outbox 'review.zip') -Encoding UTF8
    '{"SchemaVersion":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $target05Outbox 'publish.ready.json') -Encoding UTF8

    $manifest = [pscustomobject]@{
        Targets = @(
            [pscustomobject]@{
                TargetId = 'target05'
                RoleName = 'bottom'
                MessagePath = (Join-Path $messagesRoot 'target05.txt')
                RequestPath = $request05Path
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = ''
                SourceSummaryPath = (Join-Path $target05Outbox 'summary.txt')
                SourceReviewZipPath = (Join-Path $target05Outbox 'review.zip')
                PublishReadyPath = (Join-Path $target05Outbox 'publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $contractRoot 'target05')
                ContractReferenceTimeUtc = '2026-04-27T07:33:55Z'
                InitialRoleMode = 'handoff_wait'
            },
            [pscustomobject]@{
                TargetId = 'target01'
                RoleName = 'top'
                MessagePath = (Join-Path $messagesRoot 'target01.txt')
                RequestPath = $request01Path
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = 'C:\dev\python\relay-workrepo-visible-smoke\reviewfile\seed_review_input_latest.zip'
                SourceSummaryPath = (Join-Path $target01Outbox 'summary.txt')
                SourceReviewZipPath = (Join-Path $target01Outbox 'review.zip')
                PublishReadyPath = (Join-Path $target01Outbox 'publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $contractRoot 'target01')
                ContractReferenceTimeUtc = '2026-04-27T07:33:55Z'
                InitialRoleMode = 'seed'
            }
        )
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runRoot 'manifest.json') -Encoding UTF8

    'prepare ok' | Set-Content -LiteralPath (Join-Path $logsRoot 'typed-window-prepare\target01\latest.log') -Encoding UTF8
    'ahk ok' | Set-Content -LiteralPath (Join-Path $logsRoot 'ahk-debug\target01\send.log') -Encoding UTF8
    'router running' | Set-Content -LiteralPath (Join-Path $logsRoot 'router.log') -Encoding UTF8
    $processedTarget01Path = Join-Path $processedRoot 'target01__message.ready.txt'
    'processed payload envelope' | Set-Content -LiteralPath $processedTarget01Path -Encoding UTF8
    '검토 결과 파일이 있으면 먼저 확인하고 최소 smoke 산출물을 만드세요.' | Set-Content -LiteralPath ($processedTarget01Path + '.payload.txt') -Encoding UTF8
    $stubStatusText = Get-Content -LiteralPath $stubStatusPath -Raw -Encoding UTF8
    $stubStatusText = $stubStatusText.Replace('__PROCESSED_TARGET01_PATH__', $processedTarget01Path)
    Set-Content -LiteralPath $stubStatusPath -Value $stubStatusText -Encoding UTF8

    $configPath = Join-Path $tempRoot 'settings.psd1'
    @"
@{
    LogsRoot = '$logsRoot'
    RuntimeRoot = '$runtimeRoot'
    InboxRoot = '$inboxRoot'
    ProcessedRoot = '$processedRoot'
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
    Assert-True ((@($important.RecentEvents | Where-Object { [string]$_.EventClass -eq 'contract-artifact' -or [string]$_.EventClass -eq 'source-outbox' })).Count -gt 0) 'important summary should classify event types in JSON.'
    Assert-True ([string]@($important.Targets)[0].TargetId -eq 'target01') 'important summary should prioritize incomplete target ahead of already-ready targets.'

    $target01 = @($important.Targets | Where-Object { [string]$_.TargetId -eq 'target01' })[0]
    Assert-True ([string]$target01.MessagePath -eq (Join-Path $messagesRoot 'target01.txt')) 'target01 message path should be surfaced.'
    Assert-True ([string]$target01.ProcessedPath -eq $processedTarget01Path) 'target01 processed path should be surfaced.'
    Assert-True ([string]$target01.ProcessedPayloadSnapshotPath -eq ($processedTarget01Path + '.payload.txt')) 'target01 processed payload snapshot path should be surfaced.'
    Assert-True ([bool]$target01.ProcessedPayloadSnapshot.Exists) 'target01 processed payload snapshot should be surfaced as an existing file.'
    Assert-True ([string]$target01.MessagePreview -match 'paired-exchange-seed') 'target01 message preview should include actual payload lines.'
    Assert-True ([string]$target01.ProcessedPayloadSnapshotPreview -match '최소 smoke 산출물을 만드세요') 'target01 processed payload snapshot preview should include the exact sent payload text.'
    Assert-True (-not [bool]$target01.SourceSummary.Exists) 'missing summary should be reflected in important summary.'
    Assert-True (-not [bool]$target01.ContractArtifactsReady) 'target01 contract readiness should be false when files are missing.'
    Assert-True (@($target01.MissingContractFiles).Count -eq 3) 'target01 missing contract files should be enumerated.'
    Assert-True ([string]$target01.LatestPrepareLogPath -eq (Join-Path $logsRoot 'typed-window-prepare\target01\latest.log')) 'latest prepare log path should be surfaced.'

    $importantText = Get-Content -LiteralPath $summary.ImportantSummary.TextPath -Raw -Encoding UTF8
    Assert-True ($importantText -match '\[important-summary\]') 'text summary should include important-summary header.'
    Assert-True ($importantText -match '\[freshness\]') 'text summary should include freshness section.'
    Assert-True ($importantText -match '\[operator-focus\]') 'text summary should include operator-focus section.'
    Assert-True ($importantText -match '\[recent-events\]') 'text summary should include recent-events section.'
    Assert-True ($importantText -match 'CurrentBottleneck: seed payload was not observed') 'text summary should include interpreted bottleneck.'
    Assert-True ($importantText -match 'NewestObservedSignalAt: ') 'text summary should include newest observed signal timestamp.'
    Assert-True ($importantText -match 'NewestProgressSignalAt: ') 'text summary should include newest progress signal timestamp.'
    Assert-True ($importantText -match 'ProgressStale: ') 'text summary should include progress staleness.'
    Assert-True ($importantText -match 'request\.json prepared|prepare log updated|AHK log updated') 'text summary should include recent event lines.'
    Assert-True ($importantText -match 'ContractPathMode: external-workrepo') 'text summary should include contract mode.'
    Assert-True ($importantText -match 'ContractArtifactsReady: False') 'text summary should include target contract readiness.'
    Assert-True ($importantText -match 'ProcessedPayloadSnapshotPath: ') 'text summary should include processed payload snapshot path.'
    Assert-True ($importantText -match 'ProcessedPayloadSnapshotPreview:') 'text summary should include processed payload snapshot preview.'
    Assert-True ($importantText -match 'summary.txt: exists=False') 'text summary should show missing output files clearly.'

    Write-Host 'show-paired-run-summary important summary ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
