@{
    SweepIntervalMs = 2000
    ResolverShellPath = 'pwsh.exe'
    RouterStatePath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\router-state.json'
    RuntimeRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime'
    PairActivation = @{
        DefaultEnabled = $true
        StatePath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\pair-activation\bottest-live-visible.json'
    }
    MaxRetryCount = 1
    RouterMutexName = 'Global\RelayRouter_hyukwoo1_bottest_live_visible'
    LogsRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\logs'
    AhkScriptPath = 'C:\dev\python\hyukwoo\hyukwoo1\sender\SendToWindow.ahk'
    VisibleExecutionRestorePreviousActive = $false
    SubmitGuardMs = 2500
    MaxPayloadBytes = 12000
    SubmitRetryModes = @(
        'enter'
    )
    WindowLookupRetryDelayMs = 750
    WindowLookupRetryCount = 1
    BindingProfilePath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\window-bindings\bottest-live-visible.json'
    PostSubmitDelayMs = 900
    RetryPendingRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\retry-pending'
    IgnoredRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\ignored'
    AhkExePath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    RuntimeMapPath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\target-runtime.json'
    LauncherWrapperPath = 'C:\Users\USER\s_8windows_left_monitor_codex_visible.py'
    VisibleExecutionBeaconEnabled = $true
    TextSettlePerKbMs = 350
    WindowLookupTimeoutMs = 12000
    InboxRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox'
    TargetAutoloop = @{
        RunRootBase = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible\target-autoloop'
        QueueRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\target-autoloop\queue'
        MaxConcurrentTargets = 8
        DefaultPublishReadyDispatchMaxDelaySeconds = 30
        PollIntervalMs = 1000
        Targets = @(
            @{
                CooldownSeconds = 5
                MaxCycleCount = 10
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오'
                TargetId = 'target01'
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                ContractPath = $null
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                Enabled = $true
            }
            @{
                CooldownSeconds = 5
                MaxCycleCount = 10
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오'
                TargetId = 'target02'
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                ContractPath = $null
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                Enabled = $true
            }
            @{
                CooldownSeconds = 5
                MaxCycleCount = 10
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오'
                TargetId = 'target03'
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                ContractPath = $null
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                Enabled = $true
            }
            @{
                CooldownSeconds = 5
                MaxCycleCount = 10
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오'
                TargetId = 'target04'
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                ContractPath = $null
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                Enabled = $true
            }
            @{
                CooldownSeconds = 5
                MaxCycleCount = 10
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오'
                TargetId = 'target05'
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                ContractPath = $null
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                Enabled = $true
            }
            @{
                CooldownSeconds = 5
                MaxCycleCount = 10
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오'
                TargetId = 'target06'
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                ContractPath = $null
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                Enabled = $true
            }
            @{
                CooldownSeconds = 5
                MaxCycleCount = 10
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오'
                TargetId = 'target07'
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                ContractPath = $null
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                Enabled = $true
            }
            @{
                CooldownSeconds = 5
                MaxCycleCount = 10
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오'
                TargetId = 'target08'
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                ContractPath = $null
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                Enabled = $true
            }
        )
        RunMode = 'target-autoloop'
        Enabled = $true
        ExternalPathPolicy = 'strict'
        RequireExplicitContractPath = $true
        DefaultPublishReadyDispatchMinDelaySeconds = 15
        DefaultMaxCycleCount = 10
        RequireTargetMetadata = $true
        MaxConcurrentSubmits = 1
        DispatchQueuedCommandsInline = $true
        DefaultCooldownSeconds = 5
        StatusRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\target-autoloop\status'
        MutexScope = 'target'
        AllowRecursiveWatch = $false
    }
    EnterDelayMs = 900
    PairTest = @{
        SeedOutboxStartTimeoutSeconds = 600
        UseExternalWorkRepoRunRoot = $true
        PairPolicies = @{
            pair04 = @{
                UseExternalWorkRepoContractPaths = $true
                RequireExternalRunRoot = $true
                UseExternalWorkRepoRunRoot = $true
                PublishContractMode = 'strict'
                DefaultSeedTargetId = 'target04'
                RecoveryPolicy = 'manual-review'
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                PauseAllowed = $true
                DefaultPairMaxRoundtripCount = 3
            }
            pair01 = @{
                UseExternalWorkRepoContractPaths = $true
                RequireExternalRunRoot = $true
                UseExternalWorkRepoRunRoot = $true
                PublishContractMode = 'strict'
                DefaultSeedTargetId = 'target01'
                DefaultSeedReviewInputPath = 'C:\dev\python\relay-workrepo-visible-smoke\reviewfile\seed_review_input_latest.zip'
                RecoveryPolicy = 'manual-review'
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                PauseAllowed = $true
                DefaultPairMaxRoundtripCount = 3
            }
            pair03 = @{
                UseExternalWorkRepoContractPaths = $true
                RequireExternalRunRoot = $true
                UseExternalWorkRepoRunRoot = $true
                PublishContractMode = 'strict'
                DefaultSeedTargetId = 'target03'
                RecoveryPolicy = 'manual-review'
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                PauseAllowed = $true
                DefaultPairMaxRoundtripCount = 3
            }
            pair02 = @{
                UseExternalWorkRepoContractPaths = $true
                RequireExternalRunRoot = $true
                UseExternalWorkRepoRunRoot = $true
                PublishContractMode = 'strict'
                DefaultSeedTargetId = 'target02'
                RecoveryPolicy = 'manual-review'
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                PauseAllowed = $true
                DefaultPairMaxRoundtripCount = 3
            }
        }
        VisibleWorker = @{
            QueueRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\visible-worker\queue'
            PreflightTimeoutSeconds = 180
            WorkerReadyFreshnessSeconds = 30
            DispatchRunningStaleSeconds = 30
            DispatchAcceptedStaleSeconds = 15
            IdleExitSeconds = 90
            DispatchTimeoutSeconds = 1860
            CommandTimeoutSeconds = 1860
            Enabled = $true
            PollIntervalMs = 500
            StatusRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\visible-worker\status'
            AcceptanceSeedSoftTimeoutSeconds = 120
            LogRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\visible-worker\logs'
        }
        SmokeSeedTaskText = '현재 run은 acceptance smoke 테스트입니다.

실제 프로젝트 전반을 깊게 수정하려 하지 말고, 현재 run 계약만 만족하는 최소 산출물만 만드세요.

summary.txt 에는 간단한 smoke 결과 2~4줄만 적고, review.zip 에는 smoke-note.txt 1개만 포함해도 됩니다.

상대가 handoff를 받더라도 같은 원칙으로 최소 산출물만 이어서 생성하세요.'
        ReviewZipPattern = 'review_{TargetId}_{yyyyMMdd_HHmmss}_{Guid}.zip'
        TargetOverrides = @{
            target02 = @{
                HandoffExtraBlocks = @(
                    'target02는 target06이 넘긴 결과를 다시 이어받아 pair02 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용과 현재 프로젝트 파일을 함께 검토해 더 개선할 부분이 있는지 검토하세요.'
                )
            }
            target05 = @{
                HandoffExtraBlocks = @(
                    'target05는 target01이 만든 산출물을 이어받아 중간 왕복을 수행합니다.'
                )
                InitialExtraBlocks = @(
                    '검토파일  참고해서 우리 프로젝트에 맞는 부분만 선별적으로 검토해서 적용해야 될 부분이 있는지 검토해봐

          ////그리고 더 좋은 방법은 없을지 추가적인 개선포인트가 있는지 코드나기능이 복잡해지지않는선에서 검토해봐 그리고 지금 다른사람이 다른쪽 작업하고있으니까 다른파일도 수

  정해도 되는데 니가 건드린파일말고 절대제거하거나 롤백이나, restore이나 원복하지마 //'
                )
            }
            target08 = @{
                HandoffExtraBlocks = @(
                    'target08은 target04가 만든 산출물을 이어받아 pair04 중간 왕복을 수행합니다.'
                )
                InitialExtraBlocks = @(
                    '검토파일  참고해서 우리 프로젝트에 맞는 부분만 선별적으로 검토해서 적용해야 될 부분이 있는지 검토해봐

          ////그리고 더 좋은 방법은 없을지 추가적인 개선포인트가 있는지 코드나기능이 복잡해지지않는선에서 검토해봐 그리고 지금 다른사람이 다른쪽 작업하고있으니까 다른파일도 수

  정해도 되는데 니가 건드린파일말고 절대제거하거나 롤백이나, restore이나 원복하지마 //'
                )
            }
            target04 = @{
                HandoffExtraBlocks = @(
                    'target04는 target08이 넘긴 결과를 다시 이어받아 pair04 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용과 현재 프로젝트 파일을 함께 검토해 더 개선할 부분이 있는지 검토하세요.'
                )
            }
            target03 = @{
                HandoffExtraBlocks = @(
                    'target03은 target07이 넘긴 결과를 다시 이어받아 pair03 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용과 현재 프로젝트 파일을 함께 검토해 더 개선할 부분이 있는지 검토하세요.'
                )
            }
            target06 = @{
                HandoffExtraBlocks = @(
                    'target06은 target02가 만든 산출물을 이어받아 pair02 중간 왕복을 수행합니다.'
                )
                InitialExtraBlocks = @(
                    '검토파일  참고해서 우리 프로젝트에 맞는 부분만 선별적으로 검토해서 적용해야 될 부분이 있는지 검토해봐

          ////그리고 더 좋은 방법은 없을지 추가적인 개선포인트가 있는지 코드나기능이 복잡해지지않는선에서 검토해봐 그리고 지금 다른사람이 다른쪽 작업하고있으니까 다른파일도 수

  정해도 되는데 니가 건드린파일말고 절대제거하거나 롤백이나, restore이나 원복하지마 //'
                )
            }
            target01 = @{
                HandoffExtraBlocks = @(
                    'target01은 target05가 넘긴 결과를 다시 이어받아 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용과 현재 프로젝트 파일을 함께 검토해 더 개선할 부분이 있는지 검토하세요.'
                )
            }
            target07 = @{
                HandoffExtraBlocks = @(
                    'target07은 target03이 만든 산출물을 이어받아 pair03 중간 왕복을 수행합니다.'
                )
                InitialExtraBlocks = @(
                    '검토파일  참고해서 우리 프로젝트에 맞는 부분만 선별적으로 검토해서 적용해야 될 부분이 있는지 검토해봐

          ////그리고 더 좋은 방법은 없을지 추가적인 개선포인트가 있는지 코드나기능이 복잡해지지않는선에서 검토해봐 그리고 지금 다른사람이 다른쪽 작업하고있으니까 다른파일도 수

  정해도 되는데 니가 건드린파일말고 절대제거하거나 롤백이나, restore이나 원복하지마 //'
                )
            }
        }
        ForbiddenArtifactLiterals = @(
            '여기에 고정문구 입력'
        )
        AllowedWindowVisibilityMethods = @(
            'hwnd'
        )
        MessageFolderName = 'messages'
        ExecutionPathMode = 'typed-window'
        TypedWindow = @{
            ProgressCpuDeltaThresholdSeconds = 0.05
            SubmitProbeSeconds = 10
            SubmitProbePollMs = 1000
            SubmitRetryLimit = 1
        }
        MessageTemplates = @{
            Handoff = @{
                SlotOrder = @(
                    'global-prefix'
                    'pair-extra'
                    'role-extra'
                    'target-extra'
                    'one-time-prefix'
                    'body'
                    'one-time-suffix'
                    'global-suffix'
                )
                PrefixBlocks = @(
                    '상대 창에서 새 결과물이 생성되었습니다.'
                    '아래 폴더와 파일을 확인하고 다음 작업을 이어가세요.'
                )
                SuffixBlocks = @(
                    '작업 후 내 폴더의 summary 파일을 갱신하고 review zip을 새로 생성하세요.'
                )
            }
            Initial = @{
                SlotOrder = @(
                    'global-prefix'
                    'pair-extra'
                    'role-extra'
                    'target-extra'
                    'one-time-prefix'
                    'body'
                    'one-time-suffix'
                    'global-suffix'
                )
                PrefixBlocks = @()
                SuffixBlocks = @()
            }
        }
        ExternalWorkRepoRunRootRelativeRoot = '.relay-runs\bottest-live-visible'
        DefaultPairMaxRoundtripCount = 0
        DefaultSeedReviewInputFilter = '*.zip'
        DefaultSeedReviewInputPath = 'C:\dev\python\relay-workrepo-visible-smoke\reviewfile\seed_review_input_latest.zip'
        DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
        RunRootPattern = 'run_{yyyyMMdd_HHmmss}'
        PairDefinitions = @(
            @{
                TopTargetId = 'target01'
                PairId = 'pair01'
                SeedTargetId = 'target01'
                BottomTargetId = 'target05'
            }
            @{
                TopTargetId = 'target02'
                PairId = 'pair02'
                SeedTargetId = 'target02'
                BottomTargetId = 'target06'
            }
            @{
                TopTargetId = 'target03'
                PairId = 'pair03'
                SeedTargetId = 'target03'
                BottomTargetId = 'target07'
            }
            @{
                TopTargetId = 'target04'
                PairId = 'pair04'
                SeedTargetId = 'target04'
                BottomTargetId = 'target08'
            }
        )
        UseExternalWorkRepoContractPaths = $true
        RequireExternalRunRoot = $true
        AcceptanceProfile = 'smoke'
        ForbiddenArtifactRegexes = @(
            '이렇게 계획개선해봤어'
            '더 개선해야될 부분이 있어\??'
            '이런부분도 참고해봐'
        )
        RunRootBase = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible'
        ReviewFolderName = 'reviewfile'
        DefaultSeedReviewInputRequireSingleCandidate = $false
        ExternalWorkRepoContractRelativeRoot = '.relay-contract\bottest-live-visible'
        DefaultPauseAllowed = $true
        RequireExternalSeedWorkRepo = $true
        SummaryZipMaxSkewSeconds = 2
        PairOverrides = @{
            pair04 = @{
                HandoffExtraBlocks = @(
                    '이번 실행은 pair04 한 쌍(target04 ↔ target08)만 기준으로 진행합니다.'
                    '반드시 현재 run의 pair04 폴더만 기준으로 이어서 작업하세요.'
                )
                InitialExtraBlocks = @(
                    '이번 실행은 pair04 한 쌍(target04 ↔ target08)만 기준으로 진행합니다.'
                    '실행 순서는 target04 -> target08 -> target04 한 번 왕복으로 고정합니다.'
                )
            }
            pair01 = @{
                HandoffExtraBlocks = @(
                    '이번 승인 테스트는 pair01 한 쌍(target01 ↔ target05)만 사용합니다.'
                    '반드시 현재 run의 pair01 폴더만 기준으로 이어서 작업하세요.'
                )
                InitialExtraBlocks = @()
            }
            pair03 = @{
                HandoffExtraBlocks = @(
                    '이번 실행은 pair03 한 쌍(target03 ↔ target07)만 기준으로 진행합니다.'
                    '반드시 현재 run의 pair03 폴더만 기준으로 이어서 작업하세요.'
                )
                InitialExtraBlocks = @(
                    '이번 실행은 pair03 한 쌍(target03 ↔ target07)만 기준으로 진행합니다.'
                    '실행 순서는 target03 -> target07 -> target03 한 번 왕복으로 고정합니다.'
                )
            }
            pair02 = @{
                HandoffExtraBlocks = @(
                    '이번 실행은 pair02 한 쌍(target02 ↔ target06)만 기준으로 진행합니다.'
                    '반드시 현재 run의 pair02 폴더만 기준으로 이어서 작업하세요.'
                )
                InitialExtraBlocks = @(
                    '이번 실행은 pair02 한 쌍(target02 ↔ target06)만 기준으로 진행합니다.'
                    '실행 순서는 target02 -> target06 -> target02 한 번 왕복으로 고정합니다.'
                )
            }
        }
        HeadlessExec = @{
            MutexScope = 'pair'
            DoneFileName = 'done.json'
            CodexExecutable = 'codex'
            Arguments = @(
                'exec'
                '--skip-git-repo-check'
                '--dangerously-bypass-approvals-and-sandbox'
            )
            ErrorFileName = 'error.json'
            RequestFileName = 'request.json'
            MaxRunSeconds = 1800
            ResultFileName = 'result.json'
            OutputLastMessageFileName = 'codex-last-message.txt'
            PromptFileName = 'headless-prompt.txt'
            Enabled = $true
        }
        RequireUserVisibleCellExecution = $true
        DefaultPublishContractMode = 'strict'
        DefaultWatcherMaxForwardCount = 0
        RoleOverrides = @{
            top = @{
                HandoffExtraBlocks = @(
                    '당신은 상단 창입니다. 하단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.'
                )
                InitialExtraBlocks = @()
            }
            bottom = @{
                HandoffExtraBlocks = @(
                    '당신은 하단 창입니다. 상단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.'
                )
                InitialExtraBlocks = @()
            }
        }
        DefaultRecoveryPolicy = 'manual-review'
        SummaryFileName = 'summary.txt'
        DefaultSeedReviewInputSearchRelativePath = 'reviewfile'
        DefaultWatcherRunDurationSec = 900
    }
    IgnorePreexistingReadyFiles = $true
    VisibleExecutionFailOnFocusSteal = $true
    SendTimeoutMs = 5000
    WindowTitlePrefix = 'BotTestLive-Window'
    IdleSleepMs = 250
    LaneName = 'bottest-live-visible'
    RequirePairTransportMetadata = $true
    VisibleExecutionPreHoldMs = 1500
    TextSettleMaxMs = 9000
    VisibleExecutionPostHoldMs = 1500
    FailedRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\failed'
    SubmitRetryIntervalMs = 1800
    TextSettleMs = 2200
    RouterLogPath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\logs\router.log'
    RetryDelayMs = 1000
    RequireReadyDeliveryMetadata = $true
    WindowLaunch = @{
        AllowReplaceExisting = $false
        ReplaceExistingAllowEnvVar = 'RELAY_ALLOW_REPLACE_EXISTING_BOTTEST_LIVE_VISIBLE'
        DirectStartAllowEnvVar = 'RELAY_ALLOW_DIRECT_START_TARGETS_BOTTEST_LIVE_VISIBLE'
        ReuseMode = 'attach-only'
        DirectStartAllowed = $false
        LauncherMode = 'wrapper'
    }
    Root = 'C:\dev\python\hyukwoo\hyukwoo1'
    MaxPayloadChars = 4000
    ActivateSettleMs = 250
    Targets = @(
        @{
            EnterCount = 1
            WindowTitle = 'BotTestLive-Window-01'
            Id = 'target01'
            FixedSuffix = $null
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target01'
        }
        @{
            EnterCount = 1
            WindowTitle = 'BotTestLive-Window-02'
            Id = 'target02'
            FixedSuffix = $null
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target02'
        }
        @{
            EnterCount = 1
            WindowTitle = 'BotTestLive-Window-03'
            Id = 'target03'
            FixedSuffix = $null
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target03'
        }
        @{
            EnterCount = 1
            WindowTitle = 'BotTestLive-Window-04'
            Id = 'target04'
            FixedSuffix = $null
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target04'
        }
        @{
            EnterCount = 1
            WindowTitle = 'BotTestLive-Window-05'
            Id = 'target05'
            FixedSuffix = $null
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target05'
        }
        @{
            EnterCount = 1
            WindowTitle = 'BotTestLive-Window-06'
            Id = 'target06'
            FixedSuffix = $null
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target06'
        }
        @{
            EnterCount = 1
            WindowTitle = 'BotTestLive-Window-07'
            Id = 'target07'
            FixedSuffix = $null
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target07'
        }
        @{
            EnterCount = 1
            WindowTitle = 'BotTestLive-Window-08'
            Id = 'target08'
            FixedSuffix = $null
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target08'
        }
    )
    ProcessedRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\processed'
    DefaultFixedSuffix = $null
    DefaultEnterCount = 1
    PreexistingHandlingMode = 'ignore-archive'
    TerminalInputMode = 'paste'
    ShellPath = 'pwsh.exe'
}
