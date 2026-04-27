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

function Get-DescriptorValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Set-StatusStubPayload {
    param(
        [Parameter(Mandatory)][string]$StubScriptPath,
        [Parameter(Mandatory)][string]$PayloadJsonPath,
        [Parameter(Mandatory)]$Payload
    )

    $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PayloadJsonPath -Encoding UTF8
    @"
param(
    [string]`$ConfigPath,
    [string]`$RunRoot,
    [int]`$RecentFailureCount,
    [switch]`$AsJson
)

Get-Content -LiteralPath '$PayloadJsonPath' -Raw -Encoding UTF8
"@ | Set-Content -LiteralPath $StubScriptPath -Encoding UTF8
}

function Invoke-SummaryScenario {
    param(
        [Parameter(Mandatory)][string]$TempRoot,
        [Parameter(Mandatory)][string]$ScriptCopyPath,
        [Parameter(Mandatory)][string]$StubScriptPath,
        [Parameter(Mandatory)][string]$ScenarioName,
        [Parameter(Mandatory)][object[]]$Pairs,
        [Parameter(Mandatory)][object[]]$Targets,
        [string[]]$ReadyTargetIds = @(),
        [string]$Stage = 'in-progress',
        [string]$AcceptanceState = 'running',
        [string]$AcceptanceReason = 'awaiting-next-step',
        [switch]$NoProgressSignals
    )

    $scenarioRoot = Join-Path $TempRoot $ScenarioName
    $runRoot = Join-Path $scenarioRoot 'run'
    $stateRoot = Join-Path $runRoot '.state'
    $messagesRoot = Join-Path $runRoot 'messages'
    $contractRoot = Join-Path $scenarioRoot 'external-repo\.relay-contract\bottest-live-visible'
    $logsRoot = Join-Path $scenarioRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\logs'
    $runtimeRoot = Join-Path $scenarioRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\runtime'
    $inboxRoot = Join-Path $scenarioRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\inbox'
    $processedRoot = Join-Path $scenarioRoot 'external-repo\.relay-bookkeeping\bottest-live-visible\processed'
    foreach ($path in @($stateRoot, $messagesRoot, $logsRoot, $runtimeRoot, $inboxRoot, $processedRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $configPath = Join-Path $scenarioRoot 'settings.psd1'
    @"
@{
    LogsRoot = '$logsRoot'
    RuntimeRoot = '$runtimeRoot'
    InboxRoot = '$inboxRoot'
    ProcessedRoot = '$processedRoot'
}
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

    $receiptPath = Join-Path $stateRoot 'live-acceptance-result.json'
    $seedStatusPath = Join-Path $stateRoot 'seed-send-status.json'
    $pairStatePath = Join-Path $stateRoot 'pair-state.json'
    $watcherStatusPath = Join-Path $stateRoot 'watcher-status.json'
    $manifestPath = Join-Path $runRoot 'manifest.json'
    '{}' | Set-Content -LiteralPath $seedStatusPath -Encoding UTF8
    '{}' | Set-Content -LiteralPath $pairStatePath -Encoding UTF8
    '{}' | Set-Content -LiteralPath $watcherStatusPath -Encoding UTF8

    $nowUtc = (Get-Date).ToUniversalTime()
    $nowIso = $nowUtc.ToString('o')
    $readyLookup = @{}
    foreach ($targetId in @($ReadyTargetIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$targetId)) {
            $readyLookup[[string]$targetId] = $true
        }
    }

    $receipt = [pscustomobject]@{
        Stage = $Stage
        Outcome = [pscustomobject]@{
            AcceptanceState = $AcceptanceState
            AcceptanceReason = $AcceptanceReason
        }
        Seed = [pscustomobject]@{
            FinalState = [string](Get-DescriptorValue -Object ($Targets | Select-Object -First 1) -Name 'SeedSendState' -DefaultValue '')
            SubmitState = [string](Get-DescriptorValue -Object ($Targets | Select-Object -First 1) -Name 'SubmitState' -DefaultValue '')
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
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8

    $manifestTargets = @()
    $statusTargets = @()
    foreach ($target in @($Targets)) {
        $pairId = [string](Get-DescriptorValue -Object $target -Name 'PairId' -DefaultValue '')
        $targetId = [string](Get-DescriptorValue -Object $target -Name 'TargetId' -DefaultValue '')
        $roleName = [string](Get-DescriptorValue -Object $target -Name 'RoleName' -DefaultValue '')
        $partnerTargetId = [string](Get-DescriptorValue -Object $target -Name 'PartnerTargetId' -DefaultValue '')
        $targetFolder = Join-Path $runRoot (Join-Path $pairId $targetId)
        $requestPath = Join-Path $targetFolder 'request.json'
        $messagePath = Join-Path $messagesRoot ($targetId + '.txt')
        $pairContractRoot = Join-Path $contractRoot $pairId
        $targetContractRoot = Join-Path $pairContractRoot $targetId
        $sourceOutboxRoot = Join-Path $targetContractRoot 'source-outbox'
        foreach ($path in @($targetFolder, $sourceOutboxRoot)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }

        "payload for $targetId" | Set-Content -LiteralPath $messagePath -Encoding UTF8
        '{"WorkRepoRoot":"C:\\dev\\python\\relay-workrepo-visible-smoke"}' | Set-Content -LiteralPath $requestPath -Encoding UTF8

        $summaryPath = Join-Path $sourceOutboxRoot 'summary.txt'
        $reviewZipPath = Join-Path $sourceOutboxRoot 'review.zip'
        $publishReadyPath = Join-Path $sourceOutboxRoot 'publish.ready.json'
        $isReady = $readyLookup.ContainsKey($targetId)
        if ($isReady) {
            'summary ready' | Set-Content -LiteralPath $summaryPath -Encoding UTF8
            'review zip ready' | Set-Content -LiteralPath $reviewZipPath -Encoding UTF8
            '{"SchemaVersion":"1.0.0"}' | Set-Content -LiteralPath $publishReadyPath -Encoding UTF8
        }

        $manifestTargets += [pscustomobject]@{
            TargetId = $targetId
            PairId = $pairId
            RoleName = $roleName
            MessagePath = $messagePath
            RequestPath = $requestPath
            WorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
            ReviewInputPath = ''
            SourceSummaryPath = $summaryPath
            SourceReviewZipPath = $reviewZipPath
            PublishReadyPath = $publishReadyPath
            ContractPathMode = 'external-workrepo'
            ContractRootPath = $targetContractRoot
            ContractReferenceTimeUtc = $nowIso
            InitialRoleMode = if ($roleName -eq 'top') { 'seed' } else { 'handoff_wait' }
        }

        $statusTargets += [pscustomobject]@{
            PairId = $pairId
            RoleName = $roleName
            TargetId = $targetId
            PartnerTargetId = $partnerTargetId
            LatestState = [string](Get-DescriptorValue -Object $target -Name 'LatestState' -DefaultValue '')
            SourceOutboxState = [string](Get-DescriptorValue -Object $target -Name 'SourceOutboxState' -DefaultValue '')
            SeedSendState = [string](Get-DescriptorValue -Object $target -Name 'SeedSendState' -DefaultValue '')
            SubmitState = [string](Get-DescriptorValue -Object $target -Name 'SubmitState' -DefaultValue '')
            ManualAttentionRequired = [bool](Get-DescriptorValue -Object $target -Name 'ManualAttentionRequired' -DefaultValue $false)
            SummaryPresent = [bool](Get-DescriptorValue -Object $target -Name 'SummaryPresent' -DefaultValue $isReady)
            ZipCount = [int](Get-DescriptorValue -Object $target -Name 'ZipCount' -DefaultValue $(if ($isReady) { 1 } else { 0 }))
            DonePresent = [bool](Get-DescriptorValue -Object $target -Name 'DonePresent' -DefaultValue $false)
            ResultPresent = [bool](Get-DescriptorValue -Object $target -Name 'ResultPresent' -DefaultValue $false)
            FailureCount = [int](Get-DescriptorValue -Object $target -Name 'FailureCount' -DefaultValue 0)
            ForwardedAt = [string](Get-DescriptorValue -Object $target -Name 'ForwardedAt' -DefaultValue '')
            SourceOutboxUpdatedAt = [string](Get-DescriptorValue -Object $target -Name 'SourceOutboxUpdatedAt' -DefaultValue '')
            TargetFolder = $targetFolder
        }
    }

    $manifest = [pscustomobject]@{ Targets = @($manifestTargets) }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $failureLineCount = @($statusTargets | Measure-Object -Property FailureCount -Sum).Sum
    if ($null -eq $failureLineCount) {
        $failureLineCount = 0
    }
    $submitUnconfirmedCount = @(
        @($statusTargets) |
            Where-Object {
                [string]$_.SubmitState -eq 'unconfirmed' -or
                [string]$_.SourceOutboxState -eq 'submit-unconfirmed' -or
                [string]$_.SeedSendState -in @('submit-unconfirmed', 'timeout')
            }
    ).Count
    $targetUnresponsiveCount = @(
        @($statusTargets) |
            Where-Object {
                [string]$_.SourceOutboxState -eq 'target-unresponsive-after-send' -or
                [string]$_.LatestState -eq 'target-unresponsive-after-send'
            }
    ).Count
    $counts = [pscustomobject]@{
        MessageFiles = @($statusTargets).Count
        ForwardedCount = @(@($statusTargets) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ForwardedAt) }).Count
        SummaryPresentCount = @(@($statusTargets) | Where-Object { [bool]$_.SummaryPresent }).Count
        ZipPresentCount = @(@($statusTargets) | Where-Object { [int]$_.ZipCount -gt 0 }).Count
        DonePresentCount = @(@($statusTargets) | Where-Object { [bool]$_.DonePresent }).Count
        FailureLineCount = [int]$failureLineCount
        ManualAttentionCount = @(@($statusTargets) | Where-Object { [bool]$_.ManualAttentionRequired }).Count
        SubmitUnconfirmedCount = $submitUnconfirmedCount
        TargetUnresponsiveCount = $targetUnresponsiveCount
        ReadyToForwardCount = @(@($statusTargets) | Where-Object { [string]$_.SourceOutboxState -eq 'ready' }).Count
    }

    $statusPayload = [pscustomobject]@{
        RunRoot = $runRoot
        AcceptanceReceipt = [pscustomobject]@{
            Path = $receiptPath
            AcceptanceState = $AcceptanceState
            AcceptanceReason = $AcceptanceReason
            LastWriteAt = if ($NoProgressSignals) { '' } else { $nowIso }
        }
        Watcher = [pscustomobject]@{
            Status = 'running'
            StatusReason = 'summary-regression'
            LastHandledResult = 'summary-regression'
            LastHandledAt = if ($NoProgressSignals) { '' } else { $nowIso }
            HeartbeatAt = $nowIso
            HeartbeatAgeSeconds = 5
            StatusFileUpdatedAt = $nowIso
            StatusPath = $watcherStatusPath
        }
        PairState = [pscustomobject]@{
            LastWriteAt = if ($NoProgressSignals) { '' } else { $nowIso }
        }
        Counts = $counts
        Pairs = @($Pairs)
        Targets = @($statusTargets)
    }

    $payloadJsonPath = Join-Path $scenarioRoot 'status-payload.json'
    Set-StatusStubPayload -StubScriptPath $StubScriptPath -PayloadJsonPath $payloadJsonPath -Payload $statusPayload

    $raw = & $ScriptCopyPath -ConfigPath $configPath -RunRoot $runRoot -AsJson
    return ($raw | ConvertFrom-Json).ImportantSummary.Data
}

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'show-paired-run-summary.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('show-paired-run-summary-priority-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $scriptCopyPath = Join-Path $tempRoot 'show-paired-run-summary.ps1'
    $stubStatusPath = Join-Path $tempRoot 'show-paired-exchange-status.ps1'
    Copy-Item -LiteralPath $sourcePath -Destination $scriptCopyPath -Force

    $noProgressSummary = Invoke-SummaryScenario `
        -TempRoot $tempRoot `
        -ScriptCopyPath $scriptCopyPath `
        -StubScriptPath $stubStatusPath `
        -ScenarioName 'run_no_progress_signal' `
        -Stage 'seed-running' `
        -AcceptanceState 'running' `
        -AcceptanceReason 'await-contract' `
        -NoProgressSignals `
        -Pairs @(
            [pscustomobject]@{
                PairId = 'pair01'
                CurrentPhase = 'seed-running'
                NextAction = 'await-contract'
                NextExpectedHandoff = 'target05'
                RoundtripCount = 0
                ForwardedStateCount = 0
                HandoffReadyCount = 0
                ProgressDetail = 'waiting for next relay progress'
            }
        ) `
        -Targets @(
            [pscustomobject]@{
                PairId = 'pair01'
                RoleName = 'top'
                TargetId = 'target01'
                PartnerTargetId = 'target05'
                LatestState = 'seed-running'
                SourceOutboxState = 'await-contract'
                SeedSendState = 'submitted'
                SubmitState = 'submitted'
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
            }
        )

    Assert-True ([bool]$noProgressSummary.Freshness.ProgressStale) 'progress freshness should go stale when no progress signals exist at all.'
    Assert-True ([string]$noProgressSummary.Freshness.ProgressStaleReason -eq 'no-progress-signal') 'progress staleness reason should lock to no-progress-signal when no progress evidence exists.'
    Assert-True ([string]$noProgressSummary.Freshness.NewestProgressSignalAt -eq '') 'newest progress timestamp should stay empty when no progress evidence exists.'

    $submitPrioritySummary = Invoke-SummaryScenario `
        -TempRoot $tempRoot `
        -ScriptCopyPath $scriptCopyPath `
        -StubScriptPath $stubStatusPath `
        -ScenarioName 'run_submit_priority' `
        -Stage 'submit-unconfirmed' `
        -AcceptanceState 'submit-unconfirmed' `
        -AcceptanceReason 'typed-window-submit-unconfirmed' `
        -Pairs @(
            [pscustomobject]@{
                PairId = 'pair01'
                CurrentPhase = 'seed-running'
                NextAction = 'await-contract'
                NextExpectedHandoff = 'target05'
                RoundtripCount = 0
                ForwardedStateCount = 0
                HandoffReadyCount = 0
                ProgressDetail = 'contract artifacts still missing'
            },
            [pscustomobject]@{
                PairId = 'pair02'
                CurrentPhase = 'seed-submit'
                NextAction = 'confirm-submit'
                NextExpectedHandoff = 'target06'
                RoundtripCount = 0
                ForwardedStateCount = 0
                HandoffReadyCount = 0
                ProgressDetail = 'submit remains unconfirmed'
            }
        ) `
        -Targets @(
            [pscustomobject]@{
                PairId = 'pair01'
                RoleName = 'top'
                TargetId = 'target01'
                PartnerTargetId = 'target05'
                LatestState = 'seed-running'
                SourceOutboxState = 'await-contract'
                SeedSendState = 'submitted'
                SubmitState = 'submitted'
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
            },
            [pscustomobject]@{
                PairId = 'pair02'
                RoleName = 'top'
                TargetId = 'target02'
                PartnerTargetId = 'target06'
                LatestState = 'seed-submit'
                SourceOutboxState = 'submit-unconfirmed'
                SeedSendState = 'submitted'
                SubmitState = 'unconfirmed'
            },
            [pscustomobject]@{
                PairId = 'pair02'
                RoleName = 'bottom'
                TargetId = 'target06'
                PartnerTargetId = 'target02'
                LatestState = 'handoff-wait'
                SourceOutboxState = 'empty'
                SeedSendState = ''
                SubmitState = ''
            }
        )

    Assert-True ([string]$submitPrioritySummary.OperatorFocus.FocusPairId -eq 'pair02') 'submit-unconfirmed pair should outrank simple contract-incomplete pairs.'

    $unresponsivePrioritySummary = Invoke-SummaryScenario `
        -TempRoot $tempRoot `
        -ScriptCopyPath $scriptCopyPath `
        -StubScriptPath $stubStatusPath `
        -ScenarioName 'run_target_unresponsive_priority' `
        -Stage 'target-unresponsive-after-send' `
        -AcceptanceState 'target-unresponsive-after-send' `
        -AcceptanceReason 'target did not progress after submit' `
        -Pairs @(
            [pscustomobject]@{
                PairId = 'pair01'
                CurrentPhase = 'seed-running'
                NextAction = 'await-contract'
                NextExpectedHandoff = 'target05'
                RoundtripCount = 0
                ForwardedStateCount = 0
                HandoffReadyCount = 0
                ProgressDetail = 'contract artifacts still missing'
            },
            [pscustomobject]@{
                PairId = 'pair02'
                CurrentPhase = 'seed-submit'
                NextAction = 'inspect-target'
                NextExpectedHandoff = 'target06'
                RoundtripCount = 0
                ForwardedStateCount = 0
                HandoffReadyCount = 0
                ProgressDetail = 'target stopped responding after send'
            }
        ) `
        -Targets @(
            [pscustomobject]@{
                PairId = 'pair01'
                RoleName = 'top'
                TargetId = 'target01'
                PartnerTargetId = 'target05'
                LatestState = 'seed-running'
                SourceOutboxState = 'await-contract'
                SeedSendState = 'submitted'
                SubmitState = 'submitted'
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
            },
            [pscustomobject]@{
                PairId = 'pair02'
                RoleName = 'top'
                TargetId = 'target02'
                PartnerTargetId = 'target06'
                LatestState = 'target-unresponsive-after-send'
                SourceOutboxState = 'target-unresponsive-after-send'
                SeedSendState = 'submitted'
                SubmitState = 'submitted'
            },
            [pscustomobject]@{
                PairId = 'pair02'
                RoleName = 'bottom'
                TargetId = 'target06'
                PartnerTargetId = 'target02'
                LatestState = 'handoff-wait'
                SourceOutboxState = 'empty'
                SeedSendState = ''
                SubmitState = ''
            }
        )

    Assert-True ([string]$unresponsivePrioritySummary.OperatorFocus.FocusPairId -eq 'pair02') 'target-unresponsive pair should outrank simple contract-incomplete pairs.'

    $contractPrioritySummary = Invoke-SummaryScenario `
        -TempRoot $tempRoot `
        -ScriptCopyPath $scriptCopyPath `
        -StubScriptPath $stubStatusPath `
        -ScenarioName 'run_contract_over_next_action' `
        -Stage 'seed-running' `
        -AcceptanceState 'running' `
        -AcceptanceReason 'await-contract' `
        -ReadyTargetIds @('target02', 'target06') `
        -Pairs @(
            [pscustomobject]@{
                PairId = 'pair01'
                CurrentPhase = 'seed-running'
                NextAction = ''
                NextExpectedHandoff = 'target05'
                RoundtripCount = 0
                ForwardedStateCount = 0
                HandoffReadyCount = 0
                ProgressDetail = 'contract artifacts still missing'
            },
            [pscustomobject]@{
                PairId = 'pair02'
                CurrentPhase = 'handoff-ready'
                NextAction = 'forward-handoff'
                NextExpectedHandoff = 'target06'
                RoundtripCount = 1
                ForwardedStateCount = 1
                HandoffReadyCount = 1
                ProgressDetail = 'next action exists but artifacts are already ready'
            }
        ) `
        -Targets @(
            [pscustomobject]@{
                PairId = 'pair01'
                RoleName = 'top'
                TargetId = 'target01'
                PartnerTargetId = 'target05'
                LatestState = 'seed-running'
                SourceOutboxState = 'await-contract'
                SeedSendState = 'submitted'
                SubmitState = 'submitted'
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
            },
            [pscustomobject]@{
                PairId = 'pair02'
                RoleName = 'top'
                TargetId = 'target02'
                PartnerTargetId = 'target06'
                LatestState = 'handoff-ready'
                SourceOutboxState = 'ready'
                SeedSendState = 'submitted'
                SubmitState = 'submitted'
                SummaryPresent = $true
                ZipCount = 1
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
                SummaryPresent = $true
                ZipCount = 1
            }
        )

    Assert-True ([string]$contractPrioritySummary.OperatorFocus.FocusPairId -eq 'pair01') 'contract-incomplete pair should outrank pairs that only have a next action.'

    Write-Host 'show-paired-run-summary priority regression ok'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
