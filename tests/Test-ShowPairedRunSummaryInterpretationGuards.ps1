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

function Set-LastWriteTimeUtc {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][datetime]$UtcTime
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $item.LastWriteTimeUtc = $UtcTime
}

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'show-paired-run-summary.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('show-paired-run-summary-guards-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $scriptCopyPath = Join-Path $tempRoot 'show-paired-run-summary.ps1'
    $stubStatusPath = Join-Path $tempRoot 'show-paired-exchange-status.ps1'
    Copy-Item -LiteralPath $sourcePath -Destination $scriptCopyPath -Force

    $nowUtc = (Get-Date).ToUniversalTime()
    $oldUtc = $nowUtc.AddMinutes(-11)
    $nowIso = $nowUtc.ToString('o')
    $oldIso = $oldUtc.ToString('o')

    $progressRunRoot = Join-Path $tempRoot 'run_progress_stale'
    $progressStateRoot = Join-Path $progressRunRoot '.state'
    $progressMessagesRoot = Join-Path $progressRunRoot 'messages'
    $progressTarget01Folder = Join-Path $progressRunRoot 'pair01\target01'
    $progressTarget05Folder = Join-Path $progressRunRoot 'pair01\target05'
    $progressContractRoot = Join-Path $tempRoot 'external-repo\.relay-contract\bottest-live-visible\run_progress_stale\pair01'
    $progressTarget01Outbox = Join-Path $progressContractRoot 'target01\source-outbox'
    $progressTarget05Outbox = Join-Path $progressContractRoot 'target05\source-outbox'
    $progressLogsRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\logs-progress'
    $progressRuntimeRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\runtime-progress'
    $progressInboxRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\inbox-progress'
    $progressProcessedRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\processed-progress'
    foreach ($path in @(
            $progressStateRoot,
            $progressMessagesRoot,
            $progressTarget01Folder,
            $progressTarget05Folder,
            $progressTarget01Outbox,
            $progressTarget05Outbox,
            (Join-Path $progressLogsRoot 'typed-window-prepare\target01'),
            (Join-Path $progressLogsRoot 'typed-window-prepare\target05'),
            (Join-Path $progressLogsRoot 'ahk-debug\target01'),
            (Join-Path $progressLogsRoot 'ahk-debug\target05'),
            $progressRuntimeRoot,
            $progressInboxRoot,
            $progressProcessedRoot
        )) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $progressMessage01Path = Join-Path $progressMessagesRoot 'target01.txt'
    $progressMessage05Path = Join-Path $progressMessagesRoot 'target05.txt'
    $progressRequest01Path = Join-Path $progressTarget01Folder 'request.json'
    $progressRequest05Path = Join-Path $progressTarget05Folder 'request.json'
    $progressPrepare01Path = Join-Path $progressLogsRoot 'typed-window-prepare\target01\latest.log'
    $progressAhk01Path = Join-Path $progressLogsRoot 'ahk-debug\target01\send.log'
    $progressReceiptPath = Join-Path $progressStateRoot 'live-acceptance-result.json'
    $progressSeedStatusPath = Join-Path $progressStateRoot 'seed-send-status.json'
    $progressPairStatePath = Join-Path $progressStateRoot 'pair-state.json'
    $progressWatcherStatusPath = Join-Path $progressStateRoot 'watcher-status.json'
    $progressManifestPath = Join-Path $progressRunRoot 'manifest.json'
    $progressConfigPath = Join-Path $tempRoot 'settings-progress.psd1'

    'seed payload body' | Set-Content -LiteralPath $progressMessage01Path -Encoding UTF8
    '[handoff-wait]' | Set-Content -LiteralPath $progressMessage05Path -Encoding UTF8
    '{"WorkRepoRoot":"C:\\dev\\python\\relay-workrepo-visible-smoke"}' | Set-Content -LiteralPath $progressRequest01Path -Encoding UTF8
    '{"WorkRepoRoot":"C:\\dev\\python\\relay-workrepo-visible-smoke"}' | Set-Content -LiteralPath $progressRequest05Path -Encoding UTF8
    'prepare refreshed just now' | Set-Content -LiteralPath $progressPrepare01Path -Encoding UTF8
    'ahk refreshed just now' | Set-Content -LiteralPath $progressAhk01Path -Encoding UTF8

    $progressReceipt = [pscustomobject]@{
        Stage = 'seed-running'
        Outcome = [pscustomobject]@{
            AcceptanceState = 'running'
            AcceptanceReason = 'await-contract'
        }
        Seed = [pscustomobject]@{
            FinalState = 'running'
            SubmitState = 'submitted'
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
    $progressReceipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $progressReceiptPath -Encoding UTF8
    '{}' | Set-Content -LiteralPath $progressSeedStatusPath -Encoding UTF8
    '{}' | Set-Content -LiteralPath $progressPairStatePath -Encoding UTF8
    '{}' | Set-Content -LiteralPath $progressWatcherStatusPath -Encoding UTF8

    $progressManifest = [pscustomobject]@{
        Targets = @(
            [pscustomobject]@{
                TargetId = 'target01'
                PairId = 'pair01'
                RoleName = 'top'
                MessagePath = $progressMessage01Path
                RequestPath = $progressRequest01Path
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = ''
                SourceSummaryPath = (Join-Path $progressTarget01Outbox 'summary.txt')
                SourceReviewZipPath = (Join-Path $progressTarget01Outbox 'review.zip')
                PublishReadyPath = (Join-Path $progressTarget01Outbox 'publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $progressContractRoot 'target01')
                ContractReferenceTimeUtc = $oldIso
                InitialRoleMode = 'seed'
            },
            [pscustomobject]@{
                TargetId = 'target05'
                PairId = 'pair01'
                RoleName = 'bottom'
                MessagePath = $progressMessage05Path
                RequestPath = $progressRequest05Path
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = ''
                SourceSummaryPath = (Join-Path $progressTarget05Outbox 'summary.txt')
                SourceReviewZipPath = (Join-Path $progressTarget05Outbox 'review.zip')
                PublishReadyPath = (Join-Path $progressTarget05Outbox 'publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $progressContractRoot 'target05')
                ContractReferenceTimeUtc = $oldIso
                InitialRoleMode = 'handoff_wait'
            }
        )
    }
    $progressManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $progressManifestPath -Encoding UTF8

    Set-LastWriteTimeUtc -Path $progressReceiptPath -UtcTime $oldUtc
    Set-LastWriteTimeUtc -Path $progressPairStatePath -UtcTime $oldUtc
    Set-LastWriteTimeUtc -Path $progressWatcherStatusPath -UtcTime $oldUtc
    Set-LastWriteTimeUtc -Path $progressMessage01Path -UtcTime $nowUtc
    Set-LastWriteTimeUtc -Path $progressRequest01Path -UtcTime $nowUtc
    Set-LastWriteTimeUtc -Path $progressPrepare01Path -UtcTime $nowUtc
    Set-LastWriteTimeUtc -Path $progressAhk01Path -UtcTime $nowUtc

    @"
@{
    LogsRoot = '$progressLogsRoot'
    RuntimeRoot = '$progressRuntimeRoot'
    InboxRoot = '$progressInboxRoot'
    ProcessedRoot = '$progressProcessedRoot'
}
"@ | Set-Content -LiteralPath $progressConfigPath -Encoding UTF8

    @"
param(
    [string]`$ConfigPath,
    [string]`$RunRoot,
    [int]`$RecentFailureCount,
    [switch]`$AsJson
)

`$payload = [pscustomobject]@{
    RunRoot = '$progressRunRoot'
    AcceptanceReceipt = [pscustomobject]@{
        Path = '$progressReceiptPath'
        AcceptanceState = 'running'
        AcceptanceReason = 'await-contract'
        LastWriteAt = '$oldIso'
    }
    Watcher = [pscustomobject]@{
        Status = 'starting'
        StatusReason = 'await-contract'
        LastHandledResult = 'seed-pending'
        LastHandledAt = '$oldIso'
        HeartbeatAt = '$oldIso'
        HeartbeatAgeSeconds = 660
        StatusFileUpdatedAt = '$oldIso'
        StatusPath = '$progressWatcherStatusPath'
    }
    PairState = [pscustomobject]@{
        LastWriteAt = '$oldIso'
    }
    Counts = [pscustomobject]@{
        MessageFiles = 2
        ForwardedCount = 0
        SummaryPresentCount = 0
        ZipPresentCount = 0
        DonePresentCount = 0
        FailureLineCount = 0
        ManualAttentionCount = 0
        SubmitUnconfirmedCount = 0
        TargetUnresponsiveCount = 0
        ReadyToForwardCount = 0
    }
    Pairs = @(
        [pscustomobject]@{
            PairId = 'pair01'
            CurrentPhase = 'seed-running'
            NextAction = 'await-contract'
            NextExpectedHandoff = 'target05'
            RoundtripCount = 0
            ForwardedStateCount = 0
            HandoffReadyCount = 0
            ProgressDetail = 'waiting for source-outbox publish'
        }
    )
    Targets = @(
        [pscustomobject]@{
            PairId = 'pair01'
            RoleName = 'top'
            TargetId = 'target01'
            PartnerTargetId = 'target05'
            LatestState = 'seed-running'
            SourceOutboxState = 'await-contract'
            SeedSendState = 'submitted'
            SubmitState = 'submitted'
            ManualAttentionRequired = `$false
            SummaryPresent = `$false
            ZipCount = 0
            DonePresent = `$false
            ResultPresent = `$false
            FailureCount = 0
            ForwardedAt = ''
            SourceOutboxUpdatedAt = ''
            TargetFolder = '$progressTarget01Folder'
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
            ManualAttentionRequired = `$false
            SummaryPresent = `$false
            ZipCount = 0
            DonePresent = `$false
            ResultPresent = `$false
            FailureCount = 0
            ForwardedAt = ''
            SourceOutboxUpdatedAt = ''
            TargetFolder = '$progressTarget05Folder'
        }
    )
}

`$payload | ConvertTo-Json -Depth 8
"@ | Set-Content -LiteralPath $stubStatusPath -Encoding UTF8

    $progressRaw = & $scriptCopyPath -ConfigPath $progressConfigPath -RunRoot $progressRunRoot -AsJson
    $progressSummary = $progressRaw | ConvertFrom-Json
    $progressImportant = $progressSummary.ImportantSummary.Data
    $progressText = Get-Content -LiteralPath $progressSummary.ImportantSummary.TextPath -Raw -Encoding UTF8

    Assert-True (-not [bool]$progressImportant.Freshness.StaleSummary) 'supporting-signal freshness should stay fresh when recent evidence exists.'
    Assert-True ([bool]$progressImportant.Freshness.ProgressStale) 'progress freshness should go stale when only supporting signals are recent.'
    Assert-True ([string]$progressImportant.Freshness.NewestObservedSignalText -match 'request\.json prepared|prepare log updated|AHK log updated|payload message prepared') 'overall freshness should follow supporting signals.'
    Assert-True ([string]$progressImportant.Freshness.NewestProgressSignalText -match 'acceptance receipt updated|pair-state updated|watcher last handled') 'progress freshness should follow orchestration progress signals only.'
    Assert-True ($progressText -match 'ProgressStale: True') 'text summary should show progress staleness when relay progress is old.'

    $focusRunRoot = Join-Path $tempRoot 'run_focus_priority'
    $focusStateRoot = Join-Path $focusRunRoot '.state'
    $focusMessagesRoot = Join-Path $focusRunRoot 'messages'
    $focusPair01Target01Folder = Join-Path $focusRunRoot 'pair01\target01'
    $focusPair01Target05Folder = Join-Path $focusRunRoot 'pair01\target05'
    $focusPair02Target02Folder = Join-Path $focusRunRoot 'pair02\target02'
    $focusPair02Target06Folder = Join-Path $focusRunRoot 'pair02\target06'
    $focusContractRootPair01 = Join-Path $tempRoot 'external-repo\.relay-contract\bottest-live-visible\run_focus_priority\pair01'
    $focusContractRootPair02 = Join-Path $tempRoot 'external-repo\.relay-contract\bottest-live-visible\run_focus_priority\pair02'
    $focusLogsRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\logs-focus'
    $focusRuntimeRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\runtime-focus'
    $focusInboxRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\inbox-focus'
    $focusProcessedRoot = Join-Path $tempRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\processed-focus'
    foreach ($path in @(
            $focusStateRoot,
            $focusMessagesRoot,
            $focusPair01Target01Folder,
            $focusPair01Target05Folder,
            $focusPair02Target02Folder,
            $focusPair02Target06Folder,
            (Join-Path $focusContractRootPair01 'target01\source-outbox'),
            (Join-Path $focusContractRootPair01 'target05\source-outbox'),
            (Join-Path $focusContractRootPair02 'target02\source-outbox'),
            (Join-Path $focusContractRootPair02 'target06\source-outbox'),
            $focusLogsRoot,
            $focusRuntimeRoot,
            $focusInboxRoot,
            $focusProcessedRoot
        )) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $focusReceiptPath = Join-Path $focusStateRoot 'live-acceptance-result.json'
    $focusWatcherStatusPath = Join-Path $focusStateRoot 'watcher-status.json'
    $focusManifestPath = Join-Path $focusRunRoot 'manifest.json'
    $focusConfigPath = Join-Path $tempRoot 'settings-focus.psd1'
    '{}' | Set-Content -LiteralPath (Join-Path $focusStateRoot 'seed-send-status.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $focusStateRoot 'pair-state.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath $focusWatcherStatusPath -Encoding UTF8

    $focusReceipt = [pscustomobject]@{
        Stage = 'manual-check-required'
        Outcome = [pscustomobject]@{
            AcceptanceState = 'manual_attention_required'
            AcceptanceReason = 'target requires manual review'
        }
        Seed = [pscustomobject]@{
            FinalState = 'submitted'
            SubmitState = 'submitted'
            OutboxPublished = $true
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
    $focusReceipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $focusReceiptPath -Encoding UTF8

    foreach ($targetId in @('target01', 'target05', 'target02', 'target06')) {
        "payload for $targetId" | Set-Content -LiteralPath (Join-Path $focusMessagesRoot ($targetId + '.txt')) -Encoding UTF8
    }
    foreach ($requestPath in @(
            (Join-Path $focusPair01Target01Folder 'request.json'),
            (Join-Path $focusPair01Target05Folder 'request.json'),
            (Join-Path $focusPair02Target02Folder 'request.json'),
            (Join-Path $focusPair02Target06Folder 'request.json')
        )) {
        '{"WorkRepoRoot":"C:\\dev\\python\\relay-workrepo-visible-smoke"}' | Set-Content -LiteralPath $requestPath -Encoding UTF8
    }

    foreach ($artifactPath in @(
            (Join-Path $focusContractRootPair02 'target02\source-outbox\summary.txt'),
            (Join-Path $focusContractRootPair02 'target02\source-outbox\review.zip'),
            (Join-Path $focusContractRootPair02 'target02\source-outbox\publish.ready.json'),
            (Join-Path $focusContractRootPair02 'target06\source-outbox\summary.txt'),
            (Join-Path $focusContractRootPair02 'target06\source-outbox\review.zip'),
            (Join-Path $focusContractRootPair02 'target06\source-outbox\publish.ready.json')
        )) {
        'ready' | Set-Content -LiteralPath $artifactPath -Encoding UTF8
    }

    $focusManifest = [pscustomobject]@{
        Targets = @(
            [pscustomobject]@{
                TargetId = 'target01'
                PairId = 'pair01'
                RoleName = 'top'
                MessagePath = (Join-Path $focusMessagesRoot 'target01.txt')
                RequestPath = (Join-Path $focusPair01Target01Folder 'request.json')
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = ''
                SourceSummaryPath = (Join-Path $focusContractRootPair01 'target01\source-outbox\summary.txt')
                SourceReviewZipPath = (Join-Path $focusContractRootPair01 'target01\source-outbox\review.zip')
                PublishReadyPath = (Join-Path $focusContractRootPair01 'target01\source-outbox\publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $focusContractRootPair01 'target01')
                ContractReferenceTimeUtc = $nowIso
                InitialRoleMode = 'seed'
            },
            [pscustomobject]@{
                TargetId = 'target05'
                PairId = 'pair01'
                RoleName = 'bottom'
                MessagePath = (Join-Path $focusMessagesRoot 'target05.txt')
                RequestPath = (Join-Path $focusPair01Target05Folder 'request.json')
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = ''
                SourceSummaryPath = (Join-Path $focusContractRootPair01 'target05\source-outbox\summary.txt')
                SourceReviewZipPath = (Join-Path $focusContractRootPair01 'target05\source-outbox\review.zip')
                PublishReadyPath = (Join-Path $focusContractRootPair01 'target05\source-outbox\publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $focusContractRootPair01 'target05')
                ContractReferenceTimeUtc = $nowIso
                InitialRoleMode = 'handoff_wait'
            },
            [pscustomobject]@{
                TargetId = 'target02'
                PairId = 'pair02'
                RoleName = 'top'
                MessagePath = (Join-Path $focusMessagesRoot 'target02.txt')
                RequestPath = (Join-Path $focusPair02Target02Folder 'request.json')
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = ''
                SourceSummaryPath = (Join-Path $focusContractRootPair02 'target02\source-outbox\summary.txt')
                SourceReviewZipPath = (Join-Path $focusContractRootPair02 'target02\source-outbox\review.zip')
                PublishReadyPath = (Join-Path $focusContractRootPair02 'target02\source-outbox\publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $focusContractRootPair02 'target02')
                ContractReferenceTimeUtc = $nowIso
                InitialRoleMode = 'seed'
            },
            [pscustomobject]@{
                TargetId = 'target06'
                PairId = 'pair02'
                RoleName = 'bottom'
                MessagePath = (Join-Path $focusMessagesRoot 'target06.txt')
                RequestPath = (Join-Path $focusPair02Target06Folder 'request.json')
                WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                ReviewInputPath = ''
                SourceSummaryPath = (Join-Path $focusContractRootPair02 'target06\source-outbox\summary.txt')
                SourceReviewZipPath = (Join-Path $focusContractRootPair02 'target06\source-outbox\review.zip')
                PublishReadyPath = (Join-Path $focusContractRootPair02 'target06\source-outbox\publish.ready.json')
                ContractPathMode = 'external-workrepo'
                ContractRootPath = (Join-Path $focusContractRootPair02 'target06')
                ContractReferenceTimeUtc = $nowIso
                InitialRoleMode = 'handoff_wait'
            }
        )
    }
    $focusManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $focusManifestPath -Encoding UTF8

    @"
@{
    LogsRoot = '$focusLogsRoot'
    RuntimeRoot = '$focusRuntimeRoot'
    InboxRoot = '$focusInboxRoot'
    ProcessedRoot = '$focusProcessedRoot'
}
"@ | Set-Content -LiteralPath $focusConfigPath -Encoding UTF8

    @"
param(
    [string]`$ConfigPath,
    [string]`$RunRoot,
    [int]`$RecentFailureCount,
    [switch]`$AsJson
)

`$payload = [pscustomobject]@{
    RunRoot = '$focusRunRoot'
    AcceptanceReceipt = [pscustomobject]@{
        Path = '$focusReceiptPath'
        AcceptanceState = 'manual_attention_required'
        AcceptanceReason = 'target requires manual review'
        LastWriteAt = '$nowIso'
    }
    Watcher = [pscustomobject]@{
        Status = 'running'
        StatusReason = 'manual-review'
        LastHandledResult = 'pair02-pending-manual-review'
        LastHandledAt = '$nowIso'
        HeartbeatAt = '$nowIso'
        HeartbeatAgeSeconds = 5
        StatusFileUpdatedAt = '$nowIso'
        StatusPath = '$focusWatcherStatusPath'
    }
    PairState = [pscustomobject]@{
        LastWriteAt = '$nowIso'
    }
    Counts = [pscustomobject]@{
        MessageFiles = 4
        ForwardedCount = 1
        SummaryPresentCount = 2
        ZipPresentCount = 2
        DonePresentCount = 0
        FailureLineCount = 1
        ManualAttentionCount = 1
        SubmitUnconfirmedCount = 0
        TargetUnresponsiveCount = 0
        ReadyToForwardCount = 0
    }
    Pairs = @(
        [pscustomobject]@{
            PairId = 'pair01'
            CurrentPhase = 'seed-running'
            NextAction = 'await-contract'
            NextExpectedHandoff = 'target05'
            RoundtripCount = 0
            ForwardedStateCount = 0
            HandoffReadyCount = 0
            ProgressDetail = 'pair01 is waiting for contract artifacts'
        },
        [pscustomobject]@{
            PairId = 'pair02'
            CurrentPhase = 'manual-review-required'
            NextAction = 'manual-review'
            NextExpectedHandoff = 'target06'
            RoundtripCount = 1
            ForwardedStateCount = 1
            HandoffReadyCount = 0
            ProgressDetail = 'pair02 requires manual operator review'
        }
    )
    Targets = @(
        [pscustomobject]@{
            PairId = 'pair01'
            RoleName = 'top'
            TargetId = 'target01'
            PartnerTargetId = 'target05'
            LatestState = 'seed-running'
            SourceOutboxState = 'await-contract'
            SeedSendState = 'submitted'
            SubmitState = 'submitted'
            ManualAttentionRequired = `$false
            SummaryPresent = `$false
            ZipCount = 0
            DonePresent = `$false
            ResultPresent = `$false
            FailureCount = 0
            ForwardedAt = ''
            SourceOutboxUpdatedAt = ''
            TargetFolder = '$focusPair01Target01Folder'
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
            ManualAttentionRequired = `$false
            SummaryPresent = `$false
            ZipCount = 0
            DonePresent = `$false
            ResultPresent = `$false
            FailureCount = 0
            ForwardedAt = ''
            SourceOutboxUpdatedAt = ''
            TargetFolder = '$focusPair01Target05Folder'
        },
        [pscustomobject]@{
            PairId = 'pair02'
            RoleName = 'top'
            TargetId = 'target02'
            PartnerTargetId = 'target06'
            LatestState = 'manual-attention-required'
            SourceOutboxState = 'ready'
            SeedSendState = 'submitted'
            SubmitState = 'submitted'
            ManualAttentionRequired = `$true
            SummaryPresent = `$true
            ZipCount = 1
            DonePresent = `$false
            ResultPresent = `$false
            FailureCount = 1
            ForwardedAt = '$nowIso'
            SourceOutboxUpdatedAt = '$nowIso'
            TargetFolder = '$focusPair02Target02Folder'
        },
        [pscustomobject]@{
            PairId = 'pair02'
            RoleName = 'bottom'
            TargetId = 'target06'
            PartnerTargetId = 'target02'
            LatestState = 'handoff-wait'
            SourceOutboxState = 'ready'
            SeedSendState = ''
            SubmitState = ''
            ManualAttentionRequired = `$false
            SummaryPresent = `$true
            ZipCount = 1
            DonePresent = `$false
            ResultPresent = `$false
            FailureCount = 0
            ForwardedAt = '$nowIso'
            SourceOutboxUpdatedAt = '$nowIso'
            TargetFolder = '$focusPair02Target06Folder'
        }
    )
}

`$payload | ConvertTo-Json -Depth 8
"@ | Set-Content -LiteralPath $stubStatusPath -Encoding UTF8

    $focusRaw = & $scriptCopyPath -ConfigPath $focusConfigPath -RunRoot $focusRunRoot -AsJson
    $focusSummary = $focusRaw | ConvertFrom-Json
    $focusImportant = $focusSummary.ImportantSummary.Data
    $focusText = Get-Content -LiteralPath $focusSummary.ImportantSummary.TextPath -Raw -Encoding UTF8
    $focusPairs = @($focusImportant.Pairs)
    $focusTargets = @($focusImportant.Targets)
    $focusPairOrder = (($focusPairs | ForEach-Object { [string]$_.PairId }) -join ',')
    $focusTargetOrder = (($focusTargets | ForEach-Object { [string]$_.TargetId }) -join ',')

    Assert-True ([string]$focusImportant.OperatorFocus.FocusPairId -eq 'pair02') 'manual-attention pair should win operator focus priority.'
    Assert-True ($focusPairs.Count -ge 2) 'focus scenario should surface both pair summaries.'
    Assert-True ($focusTargets.Count -ge 4) 'focus scenario should surface all target summaries.'
    Assert-True ([string]$focusPairs[0].PairId -eq 'pair02') ("focused pair should be listed first in pair summaries. actualOrder={0}" -f $focusPairOrder)
    Assert-True ([string]$focusTargets[0].PairId -eq 'pair02') ("focused pair targets should be listed first in target summaries. actualOrder={0}" -f $focusTargetOrder)
    Assert-True ([string]$focusImportant.OperatorFocus.CurrentBottleneck -match 'manual attention') 'manual attention should remain the interpreted bottleneck.'
    Assert-True ($focusText -match 'FocusPair: pair02') 'text summary should show the focused pair explicitly.'

    Write-Host 'show-paired-run-summary interpretation guards ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
