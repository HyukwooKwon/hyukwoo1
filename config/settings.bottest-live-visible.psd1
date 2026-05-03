@{
    WindowLookupRetryDelayMs = 750
    IgnoredRoot = 'C:\dev\python\hyukwoo\hyukwoo1\ignored\bottest-live-visible'
    MaxPayloadChars = 4000
    RuntimeRoot = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible'
    ActivateSettleMs = 250
    InboxRoot = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible'
    TextSettlePerKbMs = 350
    SubmitRetryModes = @(
        'enter'
    )
    LogsRoot = 'C:\dev\python\hyukwoo\hyukwoo1\logs\bottest-live-visible'
    VisibleExecutionPostHoldMs = 1500
    PreexistingHandlingMode = 'ignore-archive'
    TerminalInputMode = 'paste'
    ShellPath = 'powershell.exe'
    BindingProfilePath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\window-bindings\bottest-live-visible.json'
    RequirePairTransportMetadata = $true
    WindowTitlePrefix = 'BotTestLive-Window'
    AhkScriptPath = 'C:\dev\python\hyukwoo\hyukwoo1\sender\SendToWindow.ahk'
    SweepIntervalMs = 2000
    RetryDelayMs = 1000
    Root = 'C:\dev\python\hyukwoo\hyukwoo1'
    WindowLaunch = @{
        AllowReplaceExisting = $false
        DirectStartAllowEnvVar = 'RELAY_ALLOW_DIRECT_START_TARGETS_BOTTEST_LIVE_VISIBLE'
        LauncherMode = 'wrapper'
        ReplaceExistingAllowEnvVar = 'RELAY_ALLOW_REPLACE_EXISTING_BOTTEST_LIVE_VISIBLE'
        ReuseMode = 'attach-only'
        DirectStartAllowed = $false
    }
    VisibleExecutionPreHoldMs = 1500
    RequireReadyDeliveryMetadata = $true
    TextSettleMaxMs = 9000
    SubmitGuardMs = 2500
    VisibleExecutionFailOnFocusSteal = $true
    Targets = @(
        @{
            EnterCount = 1
            Id = 'target01'
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target01'
            WindowTitle = 'BotTestLive-Window-01'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target02'
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target02'
            WindowTitle = 'BotTestLive-Window-02'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target03'
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target03'
            WindowTitle = 'BotTestLive-Window-03'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target04'
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target04'
            WindowTitle = 'BotTestLive-Window-04'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target05'
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target05'
            WindowTitle = 'BotTestLive-Window-05'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target06'
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target06'
            WindowTitle = 'BotTestLive-Window-06'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target07'
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target07'
            WindowTitle = 'BotTestLive-Window-07'
            FixedSuffix = $null
        }
        @{
            EnterCount = 1
            Id = 'target08'
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target08'
            WindowTitle = 'BotTestLive-Window-08'
            FixedSuffix = $null
        }
    )
    EnterDelayMs = 900
    RouterStatePath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\router-state.json'
    SubmitRetryIntervalMs = 1800
    ResolverShellPath = 'powershell.exe'
    DefaultEnterCount = 1
    VisibleExecutionRestorePreviousActive = $false
    ProcessedRoot = 'C:\dev\python\hyukwoo\hyukwoo1\processed\bottest-live-visible'
    SendTimeoutMs = 5000
    IdleSleepMs = 250
    RetryPendingRoot = 'C:\dev\python\hyukwoo\hyukwoo1\retry-pending\bottest-live-visible'
    FailedRoot = 'C:\dev\python\hyukwoo\hyukwoo1\failed\bottest-live-visible'
    VisibleExecutionBeaconEnabled = $true
    RuntimeMapPath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\target-runtime.json'
    PairTest = @{
        DefaultRecoveryPolicy = 'manual-review'
        ForbiddenArtifactLiterals = @(
            '여기에 고정문구 입력'
        )
        SummaryFileName = 'summary.txt'
        ExecutionPathMode = 'typed-window'
        ReviewFolderName = 'reviewfile'
        SummaryZipMaxSkewSeconds = 2
        PairPolicies = @{
            pair01 = @{
                RequireExternalRunRoot = $true
                PauseAllowed = $true
                PublishContractMode = 'strict'
                RecoveryPolicy = 'manual-review'
                DefaultSeedWorkRepoRoot = 'C:\dev\python\bot-test\gptgpt1-dev'
                UseExternalWorkRepoRunRoot = $true
                DefaultSeedReviewInputPath = 'C:\dev\python\bot-test\gptgpt1-dev\reviewfile\seed_review_input_latest.zip'
                UseExternalWorkRepoContractPaths = $true
                DefaultSeedTargetId = 'target01'
                DefaultPairMaxRoundtripCount = 0
            }
            pair02 = @{
                RequireExternalRunRoot = $true
                PauseAllowed = $true
                PublishContractMode = 'strict'
                RecoveryPolicy = 'manual-review'
                UseExternalWorkRepoRunRoot = $true
                UseExternalWorkRepoContractPaths = $true
                DefaultSeedTargetId = 'target02'
                DefaultSeedWorkRepoRoot = 'C:/dev/python/bot-test/gptgpt1-dev'
                DefaultPairMaxRoundtripCount = 0
            }
            pair04 = @{
                RequireExternalRunRoot = $true
                PauseAllowed = $true
                PublishContractMode = 'strict'
                RecoveryPolicy = 'manual-review'
                UseExternalWorkRepoRunRoot = $true
                UseExternalWorkRepoContractPaths = $true
                DefaultSeedTargetId = 'target04'
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                DefaultPairMaxRoundtripCount = 0
            }
            pair03 = @{
                RequireExternalRunRoot = $true
                PauseAllowed = $true
                PublishContractMode = 'strict'
                RecoveryPolicy = 'manual-review'
                UseExternalWorkRepoRunRoot = $true
                UseExternalWorkRepoContractPaths = $true
                DefaultSeedTargetId = 'target03'
                DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
                DefaultPairMaxRoundtripCount = 0
            }
        }
        RequireExternalRunRoot = $true
        DefaultWatcherRunDurationSec = 900
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
        ExternalWorkRepoRunRootRelativeRoot = '.relay-runs\bottest-live-visible'
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
        UseExternalWorkRepoRunRoot = $true
        MessageFolderName = 'messages'
        RequireUserVisibleCellExecution = $true
        TypedWindow = @{
            SubmitProbePollMs = 1000
            SubmitProbeSeconds = 10
            SubmitRetryLimit = 1
            ProgressCpuDeltaThresholdSeconds = 0.05
        }
        DefaultPairMaxRoundtripCount = 0
        ExternalWorkRepoContractRelativeRoot = '.relay-contract\bottest-live-visible'
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
            pair01 = @{
                HandoffExtraBlocks = @(
                    '이번 승인 테스트는 pair01 한 쌍(target01 ↔ target05)만 사용합니다.'
                    '반드시 현재 run의 pair01 폴더만 기준으로 이어서 작업하세요.'
                )
                InitialExtraBlocks = @()
            }
        }
        HeadlessExec = @{
            DoneFileName = 'done.json'
            Arguments = @(
                'exec'
                '--skip-git-repo-check'
                '--dangerously-bypass-approvals-and-sandbox'
            )
            MutexScope = 'pair'
            ErrorFileName = 'error.json'
            Enabled = $true
            RequestFileName = 'request.json'
            OutputLastMessageFileName = 'codex-last-message.txt'
            CodexExecutable = 'codex'
            ResultFileName = 'result.json'
            MaxRunSeconds = 1800
            PromptFileName = 'headless-prompt.txt'
        }
        PairDefinitions = @(
            @{
                BottomTargetId = 'target05'
                TopTargetId = 'target01'
                PairId = 'pair01'
                SeedTargetId = 'target01'
            }
            @{
                BottomTargetId = 'target06'
                TopTargetId = 'target02'
                PairId = 'pair02'
                SeedTargetId = 'target02'
            }
            @{
                BottomTargetId = 'target07'
                TopTargetId = 'target03'
                PairId = 'pair03'
                SeedTargetId = 'target03'
            }
            @{
                BottomTargetId = 'target08'
                TopTargetId = 'target04'
                PairId = 'pair04'
                SeedTargetId = 'target04'
            }
        )
        ReviewZipPattern = 'review_{TargetId}_{yyyyMMdd_HHmmss}_{Guid}.zip'
        AcceptanceProfile = 'smoke'
        UseExternalWorkRepoContractPaths = $true
        ForbiddenArtifactRegexes = @(
            '이렇게 계획개선해봤어'
            '더 개선해야될 부분이 있어\??'
            '이런부분도 참고해봐'
        )
        DefaultWatcherMaxForwardCount = 0
        TargetOverrides = @{
            target06 = @{
                HandoffExtraBlocks = @(
                    'target06은 target02가 만든 산출물을 이어받아 pair02 중간 왕복을 수행합니다.'
                )
                InitialExtraBlocks = @(
                    'target06은 pair02에서 초기 handoff를 기다리는 하단 target입니다.'
                )
            }
            target03 = @{
                HandoffExtraBlocks = @(
                    'target03은 target07이 넘긴 결과를 다시 이어받아 pair03 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    'target03은 pair03 상단 시작 target입니다.'
                )
            }
            target01 = @{
                HandoffExtraBlocks = @(
                    'target01은 target05가 넘긴 결과를 다시 이어받아 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용과 현재 프로젝트 파일을 함께 검토해 더 개선할 부분이 있는지 검토하세요. 결과는 summary.txt와 review.zip으로 만들고, 마지막에만 publish.ready.json을 생성하세요. summary.txt와 review.zip 생성 전에는 publish.ready.json을 만들지 마세요.'
                )
            }
            target04 = @{
                HandoffExtraBlocks = @(
                    'target04는 target08이 넘긴 결과를 다시 이어받아 pair04 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    'target04는 pair04 상단 시작 target입니다.'
                )
            }
            target08 = @{
                HandoffExtraBlocks = @(
                    'target08은 target04가 만든 산출물을 이어받아 pair04 중간 왕복을 수행합니다.'
                )
                InitialExtraBlocks = @(
                    'target08은 pair04에서 초기 handoff를 기다리는 하단 target입니다.'
                )
            }
            target05 = @{
                HandoffExtraBlocks = @(
                    'target05는 target01이 만든 산출물을 이어받아 중간 왕복을 수행합니다.'
                )
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용이 현재 프로젝트 상태와 맞는지 다시 검토한 뒤 필요한 부분만 선별 적용하세요. 이미 반영된 내용은 반복하지 말고 실제로 필요한 수정만 진행하세요. 어떤 파일을 수정했는지, 왜 수정했는지, 무엇을 유지했고 무엇을 추가 반영했는지, 남은 리스크와 검증 결과를 summary.txt에 정리하세요. 수정이 필요 없으면 no-change와 이유를 summary.txt에 명확히 적으세요. 최종 결과는 summary.txt와 review.zip으로 만들고, 마지막에만 publish.ready.json을 생성하세요. summary.txt와 review.zip 생성 전에는 publish.ready.json을 만들지 마세요. 네가 직접 수정하지 않은 파일은 제거, 롤백, restore, 원복하지 마세요.'
                )
            }
            target07 = @{
                HandoffExtraBlocks = @(
                    'target07은 target03이 만든 산출물을 이어받아 pair03 중간 왕복을 수행합니다.'
                )
                InitialExtraBlocks = @(
                    'target07은 pair03에서 초기 handoff를 기다리는 하단 target입니다.'
                )
            }
            target02 = @{
                HandoffExtraBlocks = @(
                    'target02는 target06이 넘긴 결과를 다시 이어받아 pair02 마지막 왕복을 마무리합니다.'
                )
                InitialExtraBlocks = @(
                    'target02는 pair02 상단 시작 target입니다.'
                )
            }
        }
        DefaultSeedReviewInputRequireSingleCandidate = $false
        SmokeSeedTaskText = '현재 run은 acceptance smoke 테스트입니다.
실제 프로젝트 전반을 깊게 수정하려 하지 말고, 현재 run 계약만 만족하는 최소 산출물만 만드세요.
summary.txt 에는 간단한 smoke 결과 2~4줄만 적고, review.zip 에는 smoke-note.txt 1개만 포함해도 됩니다.
상대가 handoff를 받더라도 같은 원칙으로 최소 산출물만 이어서 생성하세요.'
        DefaultSeedWorkRepoRoot = 'C:\dev\python\relay-workrepo-visible-smoke'
        DefaultPauseAllowed = $true
        RunRootPattern = 'run_{yyyyMMdd_HHmmss}'
        DefaultSeedReviewInputSearchRelativePath = 'reviewfile'
        DefaultPublishContractMode = 'strict'
        AllowedWindowVisibilityMethods = @(
            'hwnd'
        )
        RequireExternalSeedWorkRepo = $true
        DefaultSeedReviewInputPath = 'C:\dev\python\relay-workrepo-visible-smoke\reviewfile\seed_review_input_latest.zip'
        DefaultSeedReviewInputFilter = '*.zip'
        RunRootBase = 'C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible'
        VisibleWorker = @{
            CommandTimeoutSeconds = 1860
            DispatchAcceptedStaleSeconds = 15
            PreflightTimeoutSeconds = 180
            StatusRoot = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\visible-worker\status'
            IdleExitSeconds = 90
            DispatchTimeoutSeconds = 1860
            AcceptanceSeedSoftTimeoutSeconds = 120
            QueueRoot = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\visible-worker\queue'
            PollIntervalMs = 500
            WorkerReadyFreshnessSeconds = 30
            DispatchRunningStaleSeconds = 30
            LogRoot = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\visible-worker\logs'
            Enabled = $true
        }
    }
    RouterLogPath = 'C:\dev\python\hyukwoo\hyukwoo1\logs\bottest-live-visible\router.log'
    TextSettleMs = 2200
    PostSubmitDelayMs = 900
    RouterMutexName = 'Global\RelayRouter_hyukwoo1_bottest_live_visible'
    AhkExePath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    IgnorePreexistingReadyFiles = $true
    MaxPayloadBytes = 12000
    LaneName = 'bottest-live-visible'
    PairActivation = @{
        StatePath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\pair-activation\bottest-live-visible.json'
        DefaultEnabled = $true
    }
    MaxRetryCount = 1
    DefaultFixedSuffix = $null
    WindowLookupRetryCount = 1
    WindowLookupTimeoutMs = 12000
    LauncherWrapperPath = 'C:\Users\USER\s_8windows_left_monitor_codex_visible.py'
}