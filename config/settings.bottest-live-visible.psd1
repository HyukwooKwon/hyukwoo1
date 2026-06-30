@{
    VisibleExecutionFailOnFocusSteal = $true
    DefaultEnterCount = 1
    ActivateSettleMs = 250
    PreexistingHandlingMode = 'ignore-archive'
    SendTimeoutMs = 5000
    SubmitGuardMs = 2500
    WindowLaunch = @{
        DirectStartAllowed = $false
        ReplaceExistingAllowEnvVar = 'RELAY_ALLOW_REPLACE_EXISTING_BOTTEST_LIVE_VISIBLE'
        LauncherMode = 'wrapper'
        AllowReplaceExisting = $false
        DirectStartAllowEnvVar = 'RELAY_ALLOW_DIRECT_START_TARGETS_BOTTEST_LIVE_VISIBLE'
        ReuseMode = 'attach-only'
    }
    MinUserIdleBeforeSendMs = 1000
    RouterStatePath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\router-state.json'
    EnterDelayMs = 900
    RequireUserIdleBeforeSend = $true
    SweepIntervalMs = 2000
    UserIdleWaitPollMs = 250
    WindowLookupRetryDelayMs = 750
    LaneName = 'bottest-live-visible'
    LauncherWrapperPath = 'C:\Users\USER\s_8windows_left_monitor_codex_visible.py'
    MaxPayloadBytes = 12000
    InboxRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox'
    VisibleExecutionPreHoldMs = 1500
    FailedRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\failed'
    RequirePairTransportMetadata = $true
    TextSettleMs = 2200
    LogsRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\logs'
    MaxPayloadChars = 4000
    TextSettleMaxMs = 9000
    RequireReadyDeliveryMetadata = $true
    WindowLookupRetryCount = 1
    RetryDelayMs = 1000
    VisibleExecutionRestorePreviousActive = $false
    UserIdleWaitTimeoutMs = 15000
    IdleSleepMs = 250
    IgnoredRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\ignored'
    RuntimeMapPath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\target-runtime.json'
    RuntimeRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime'
    WindowTitlePrefix = 'BotTestLive-Window'
    RetryPendingRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\retry-pending'
    MaxRetryCount = 1
    SubmitRetryIntervalMs = 1800
    AhkExePath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    PairTest = @{
        RunRootBase = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible'
        DefaultSeedReviewInputPath = 'C:\dev\python\relay-workrepo-visible-smoke\reviewfile\seed_review_input_latest.zip'
        ExternalWorkRepoRunRootRelativeRoot = '.relay-runs\bottest-live-visible'
        ReviewZipPattern = 'review_{TargetId}_{yyyyMMdd_HHmmss}_{Guid}.zip'
        SummaryZipMaxSkewSeconds = 2
        DefaultPairMaxRoundtripCount = 0
        PairOverrides = @{
            pair01 = @{
                HandoffExtraBlocks = @(
                    '이번 승인 테스트는 pair01 한 쌍(target01 ↔ target05)만 사용합니다.'
                    '반드시 현재 run의 pair01 폴더만 기준으로 이어서 작업하세요.'
                )
                InitialExtraBlocks = @()
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
        }
        DefaultPublishContractMode = 'strict'
        DefaultSeedReviewInputFilter = '*.zip'
        UseExternalWorkRepoRunRoot = $true
        RequireExternalRunRoot = $true
        UseExternalWorkRepoContractPaths = $true
        TypedWindow = @{
            SubmitProbeSeconds = 10
            SubmitRetryLimit = 1
            ProgressCpuDeltaThresholdSeconds = 0.05
            SubmitProbePollMs = 1000
        }
        VisibleWorker = @{
            PollIntervalMs = 500
            Enabled = $true
            AcceptanceSeedSoftTimeoutSeconds = 120
            QueueRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\visible-worker\queue'
            StatusRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\visible-worker\status'
            DispatchTimeoutSeconds = 1860
            PreflightTimeoutSeconds = 180
            DispatchRunningStaleSeconds = 30
            WorkerReadyFreshnessSeconds = 30
            IdleExitSeconds = 90
            LogRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\visible-worker\logs'
            DispatchAcceptedStaleSeconds = 15
            CommandTimeoutSeconds = 1860
        }
        SmokeSeedTaskText = '현재 run은 acceptance smoke 테스트입니다.

실제 프로젝트 전반을 깊게 수정하려 하지 말고, 현재 run 계약만 만족하는 최소 산출물만 만드세요.

summary.txt 에는 간단한 smoke 결과 2~4줄만 적고, review.zip 에는 smoke-note.txt 1개만 포함해도 됩니다.

상대가 handoff를 받더라도 같은 원칙으로 최소 산출물만 이어서 생성하세요.'
        MessageFolderName = 'messages'
        TargetOverrides = @{
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
            target01 = @{
                HandoffExtraBlocks = @(
                    'target01은 target05가 넘긴 결과를 다시 이어받아 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용과 현재 프로젝트 파일을 함께 검토해 더 개선할 부분이 있는지 검토하세요.'
                )
            }
            target02 = @{
                HandoffExtraBlocks = @(
                    'target02는 target06이 넘긴 결과를 다시 이어받아 pair02 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용과 현재 프로젝트 파일을 함께 검토해 더 개선할 부분이 있는지 검토하세요.'
                )
            }
        }
        DefaultRecoveryPolicy = 'manual-review'
        AllowedWindowVisibilityMethods = @(
            'hwnd'
        )
        DefaultPauseAllowed = $true
        ReviewFolderName = 'reviewfile'
        DefaultWatcherRunDurationSec = 900
        DefaultSeedReviewInputSearchRelativePath = 'reviewfile'
        DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
        ExternalWorkRepoContractRelativeRoot = '.relay-contract\bottest-live-visible'
        DefaultWatcherMaxForwardCount = 0
        ExecutionPathMode = 'typed-window'
        AcceptanceProfile = 'smoke'
        PairPolicies = @{
            pair01 = @{
                DefaultSeedTargetId = 'target01'
                UseExternalWorkRepoRunRoot = $true
                RequireExternalRunRoot = $true
                DefaultSeedReviewInputPath = 'C:\dev\python\relay-workrepo-visible-smoke\reviewfile\seed_review_input_latest.zip'
                PauseAllowed = $true
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                UseExternalWorkRepoContractPaths = $true
                PublishContractMode = 'strict'
                RecoveryPolicy = 'manual-review'
                DefaultPairMaxRoundtripCount = 3
            }
            pair02 = @{
                DefaultSeedTargetId = 'target02'
                RequireExternalRunRoot = $true
                UseExternalWorkRepoRunRoot = $true
                RecoveryPolicy = 'manual-review'
                PauseAllowed = $true
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                UseExternalWorkRepoContractPaths = $true
                PublishContractMode = 'strict'
                DefaultPairMaxRoundtripCount = 3
            }
            pair03 = @{
                DefaultSeedTargetId = 'target03'
                RequireExternalRunRoot = $true
                UseExternalWorkRepoRunRoot = $true
                RecoveryPolicy = 'manual-review'
                PauseAllowed = $true
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                UseExternalWorkRepoContractPaths = $true
                PublishContractMode = 'strict'
                DefaultPairMaxRoundtripCount = 3
            }
            pair04 = @{
                DefaultSeedTargetId = 'target04'
                RequireExternalRunRoot = $true
                UseExternalWorkRepoRunRoot = $true
                RecoveryPolicy = 'manual-review'
                PauseAllowed = $true
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                UseExternalWorkRepoContractPaths = $true
                PublishContractMode = 'strict'
                DefaultPairMaxRoundtripCount = 3
            }
        }
        ForbiddenArtifactRegexes = @(
            '이렇게 계획개선해봤어'
            '더 개선해야될 부분이 있어\??'
            '이런부분도 참고해봐'
        )
        RunRootPattern = 'run_{yyyyMMdd_HHmmss}'
        MessageTemplates = @{
            Initial = @{
                SuffixBlocks = @()
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
            }
            Handoff = @{
                SuffixBlocks = @(
                    '작업 후 내 폴더의 summary 파일을 갱신하고 review zip을 새로 생성하세요.'
                )
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
            }
        }
        ForbiddenArtifactLiterals = @(
            '여기에 고정문구 입력'
        )
        RequireUserVisibleCellExecution = $true
        SummaryFileName = 'summary.txt'
        RoleOverrides = @{
            bottom = @{
                HandoffExtraBlocks = @(
                    '당신은 하단 창입니다. 상단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.'
                )
                InitialExtraBlocks = @()
            }
            top = @{
                HandoffExtraBlocks = @(
                    '당신은 상단 창입니다. 하단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.'
                )
                InitialExtraBlocks = @()
            }
        }
        RequireExternalSeedWorkRepo = $true
        SeedOutboxStartTimeoutSeconds = 600
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
        HeadlessExec = @{
            MutexScope = 'pair'
            ErrorFileName = 'error.json'
            OutputLastMessageFileName = 'codex-last-message.txt'
            DoneFileName = 'done.json'
            MaxRunSeconds = 1800
            CodexExecutable = 'codex'
            RequestFileName = 'request.json'
            Enabled = $true
            ResultFileName = 'result.json'
            Arguments = @(
                'exec'
                '--skip-git-repo-check'
                '--dangerously-bypass-approvals-and-sandbox'
            )
            PromptFileName = 'headless-prompt.txt'
        }
        DefaultSeedReviewInputRequireSingleCandidate = $false
    }
    ShellPath = 'pwsh.exe'
    PairActivation = @{
        StatePath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\pair-activation\bottest-live-visible.json'
        DefaultEnabled = $true
    }
    WindowLookupTimeoutMs = 12000
    IgnorePreexistingReadyFiles = $true
    TextSettlePerKbMs = 350
    AhkScriptPath = 'C:\dev\python\hyukwoo\hyukwoo1\sender\SendToWindow.ahk'
    RouterMutexName = 'Global\RelayRouter_hyukwoo1_bottest_live_visible'
    Root = 'C:\dev\python\hyukwoo\hyukwoo1'
    ResolverShellPath = 'pwsh.exe'
    DefaultFixedSuffix = $null
    BindingProfilePath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\runtime\window-bindings\bottest-live-visible.json'
    ProcessedRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\processed'
    TerminalInputMode = 'paste'
    Targets = @(
        @{
            EnterCount = 1
            Id = 'target01'
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target01'
            WindowTitle = 'BotTestLive-Window-01'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target02'
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target02'
            WindowTitle = 'BotTestLive-Window-02'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target03'
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target03'
            WindowTitle = 'BotTestLive-Window-03'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target04'
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target04'
            WindowTitle = 'BotTestLive-Window-04'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target05'
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target05'
            WindowTitle = 'BotTestLive-Window-05'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target06'
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target06'
            WindowTitle = 'BotTestLive-Window-06'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target07'
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target07'
            WindowTitle = 'BotTestLive-Window-07'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target08'
            Folder = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\inbox\target08'
            WindowTitle = 'BotTestLive-Window-08'
            FixedSuffix = $null
        }
    )
    RouterLogPath = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\logs\router.log'
    VisibleExecutionPostHoldMs = 1500
    PostSubmitDelayMs = 900
    SubmitRetryModes = @(
        'enter'
    )
    TargetAutoloop = @{
        PollIntervalMs = 1000
        MaxConcurrentSubmits = 1
        RunRootBase = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible\target-autoloop'
        RunMode = 'target-autoloop'
        RequireTargetMetadata = $true
        DispatchQueuedCommandsInline = $true
        DefaultMaxCycleCount = 10
        ExternalPathPolicy = 'strict'
        QueueRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\target-autoloop\queue'
        StatusRoot = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-bookkeeping\bottest-live-visible\target-autoloop\status'
        AllowRecursiveWatch = $false
        RequireExplicitContractPath = $true
        Enabled = $true
        DefaultPublishReadyDispatchMaxDelaySeconds = 30
        DefaultPublishReadyDispatchMinDelaySeconds = 15
        MaxConcurrentTargets = 8
        DefaultCooldownSeconds = 5
        Targets = @(
            @{
                ContractPath = $null
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                MaxCycleCount = 10
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                CooldownSeconds = 5
                Enabled = $true
                TargetId = 'target01'
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해 멈추지말고 다음단계들까지 모두 이어서 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오. 모든 작업이 완료되었으면 아래파일들을 절대 생성하지마시오 진행해야할 작업이 남아있을경우에만 파일생성을 진행하시오'
            }
            @{
                ContractPath = $null
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                MaxCycleCount = 10
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                CooldownSeconds = 5
                Enabled = $true
                TargetId = 'target02'
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해 멈추지말고 다음단계들까지 모두 이어서 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오. 모든 작업이 완료되었으면 아래파일들을 절대 생성하지마시오 진행해야할 작업이 남아있을경우에만 파일생성을 진행하시오'
            }
            @{
                ContractPath = $null
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                MaxCycleCount = 10
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                CooldownSeconds = 5
                Enabled = $true
                TargetId = 'target03'
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해 멈추지말고 다음단계들까지 모두 이어서 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오. 모든 작업이 완료되었으면 아래파일들을 절대 생성하지마시오 진행해야할 작업이 남아있을경우에만 파일생성을 진행하시오'
            }
            @{
                ContractPath = $null
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                MaxCycleCount = 10
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                CooldownSeconds = 5
                Enabled = $true
                TargetId = 'target04'
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해 멈추지말고 다음단계들까지 모두 이어서 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오. 모든 작업이 완료되었으면 아래파일들을 절대 생성하지마시오 진행해야할 작업이 남아있을경우에만 파일생성을 진행하시오'
            }
            @{
                ContractPath = $null
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                MaxCycleCount = 10
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                CooldownSeconds = 5
                Enabled = $true
                TargetId = 'target05'
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해 멈추지말고 다음단계들까지 모두 이어서 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오. 모든 작업이 완료되었으면 아래파일들을 절대 생성하지마시오 진행해야할 작업이 남아있을경우에만 파일생성을 진행하시오'
            }
            @{
                ContractPath = $null
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                MaxCycleCount = 10
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                CooldownSeconds = 5
                Enabled = $true
                TargetId = 'target06'
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해 멈추지말고 다음단계들까지 모두 이어서 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오. 모든 작업이 완료되었으면 아래파일들을 절대 생성하지마시오 진행해야할 작업이 남아있을경우에만 파일생성을 진행하시오'
            }
            @{
                ContractPath = $null
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                MaxCycleCount = 10
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                CooldownSeconds = 5
                Enabled = $true
                TargetId = 'target07'
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해 멈추지말고 다음단계들까지 모두 이어서 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오. 모든 작업이 완료되었으면 아래파일들을 절대 생성하지마시오 진행해야할 작업이 남아있을경우에만 파일생성을 진행하시오'
            }
            @{
                ContractPath = $null
                TriggerKinds = @(
                    'input-file'
                    'publish-ready'
                )
                MaxCycleCount = 10
                InboxPath = $null
                WorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                CooldownSeconds = 5
                Enabled = $true
                TargetId = 'target08'
                FixedSuffix = '다른작업자가 작업한건 롤백이나 원복하지말고 다음코드개선 작업 진행해 멈추지말고 다음단계들까지 모두 이어서 진행해
그 이후에는 다음에 진행할 작업이 남아있으면 요약하고 아래파일생성하고 다음에 진행할 작업이 없으면 파일생성하지마시오. 모든 작업이 완료되었으면 아래파일들을 절대 생성하지마시오 진행해야할 작업이 남아있을경우에만 파일생성을 진행하시오'
            }
        )
        MutexScope = 'target'
    }
    VisibleExecutionBeaconEnabled = $true
}
