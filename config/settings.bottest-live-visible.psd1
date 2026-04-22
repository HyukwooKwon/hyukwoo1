@{
    LaneName = 'bottest-live-visible'
    ResolverShellPath = 'powershell.exe'
    RouterMutexName = 'Global\RelayRouter_hyukwoo1_bottest_live_visible'
    Targets = @(
        @{
            WindowTitle = 'BotTestLive-Window-01'
            EnterCount = 1
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target01'
            Id = 'target01'
            FixedSuffix = $null
        }
        @{
            WindowTitle = 'BotTestLive-Window-02'
            EnterCount = 1
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target02'
            Id = 'target02'
            FixedSuffix = $null
        }
        @{
            WindowTitle = 'BotTestLive-Window-03'
            EnterCount = 1
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target03'
            Id = 'target03'
            FixedSuffix = $null
        }
        @{
            WindowTitle = 'BotTestLive-Window-04'
            EnterCount = 1
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target04'
            Id = 'target04'
            FixedSuffix = $null
        }
        @{
            WindowTitle = 'BotTestLive-Window-05'
            EnterCount = 1
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target05'
            Id = 'target05'
            FixedSuffix = $null
        }
        @{
            WindowTitle = 'BotTestLive-Window-06'
            EnterCount = 1
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target06'
            Id = 'target06'
            FixedSuffix = $null
        }
        @{
            WindowTitle = 'BotTestLive-Window-07'
            EnterCount = 1
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target07'
            Id = 'target07'
            FixedSuffix = $null
        }
        @{
            WindowTitle = 'BotTestLive-Window-08'
            EnterCount = 1
            Folder = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible\target08'
            Id = 'target08'
            FixedSuffix = $null
        }
    )
    PairActivation = @{
        DefaultEnabled = $true
        StatePath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\pair-activation\bottest-live-visible.json'
    }
    DefaultFixedSuffix = '여기에 고정문구 입력'
    SendTimeoutMs = 5000
    WindowLookupRetryCount = 1
    LauncherWrapperPath = 'C:\Users\USER\s_8windows_left_monitor_codex_visible.py'
    RetryDelayMs = 1000
    AhkExePath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    RuntimeRoot = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible'
    RuntimeMapPath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\target-runtime.json'
    SweepIntervalMs = 2000
    AhkScriptPath = 'C:\dev\python\hyukwoo\hyukwoo1\sender\SendToWindow.ahk'
    MaxPayloadChars = 4000
    LogsRoot = 'C:\dev\python\hyukwoo\hyukwoo1\logs\bottest-live-visible'
    InboxRoot = 'C:\dev\python\hyukwoo\hyukwoo1\inbox\bottest-live-visible'
    IgnorePreexistingReadyFiles = $true
    PreexistingHandlingMode = 'ignore-archive'
    RequireReadyDeliveryMetadata = $true
    RequirePairTransportMetadata = $true
    IgnoredRoot = 'C:\dev\python\hyukwoo\hyukwoo1\ignored\bottest-live-visible'
    WindowLookupRetryDelayMs = 750
    BindingProfilePath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\window-bindings\bottest-live-visible.json'
    RetryPendingRoot = 'C:\dev\python\hyukwoo\hyukwoo1\retry-pending\bottest-live-visible'
    RouterStatePath = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\bottest-live-visible\router-state.json'
    IdleSleepMs = 250
    MaxRetryCount = 1
    Root = 'C:\dev\python\hyukwoo\hyukwoo1'
    WindowTitlePrefix = 'BotTestLive-Window'
    MaxPayloadBytes = 12000
    RouterLogPath = 'C:\dev\python\hyukwoo\hyukwoo1\logs\bottest-live-visible\router.log'
    FailedRoot = 'C:\dev\python\hyukwoo\hyukwoo1\failed\bottest-live-visible'
    ShellPath = 'powershell.exe'
    PairTest = @{
        ReviewZipPattern = 'review_{TargetId}_{yyyyMMdd_HHmmss}_{Guid}.zip'
        RunRootPattern = 'run_{yyyyMMdd_HHmmss}'
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
        MessageFolderName = 'messages'
        SummaryFileName = 'summary.txt'
        RoleOverrides = @{
            bottom = @{
                InitialExtraBlocks = @()
                HandoffExtraBlocks = @(
                    '당신은 하단 창입니다. 상단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.'
                )
            }
            top = @{
                InitialExtraBlocks = @()
                HandoffExtraBlocks = @(
                    '당신은 상단 창입니다. 하단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.'
                )
            }
        }
        HeadlessExec = @{
            MutexScope = 'pair'
            ResultFileName = 'result.json'
            CodexExecutable = 'codex'
            Enabled = $true
            RequestFileName = 'request.json'
            Arguments = @(
                'exec'
                '--skip-git-repo-check'
                '--dangerously-bypass-approvals-and-sandbox'
            )
            PromptFileName = 'headless-prompt.txt'
            OutputLastMessageFileName = 'codex-last-message.txt'
            DoneFileName = 'done.json'
            MaxRunSeconds = 900
            ErrorFileName = 'error.json'
        }
        TargetOverrides = @{
            target04 = @{
                InitialExtraBlocks = @(
                    'target04는 pair04 상단 시작 target입니다.'
                )
                HandoffExtraBlocks = @(
                    'target04는 target08이 넘긴 결과를 다시 이어받아 pair04 마지막 왕복을 마무리합니다.'
                )
            }
            target06 = @{
                InitialExtraBlocks = @(
                    'target06은 pair02에서 초기 handoff를 기다리는 하단 target입니다.'
                )
                HandoffExtraBlocks = @(
                    'target06은 target02가 만든 산출물을 이어받아 pair02 중간 왕복을 수행합니다.'
                )
            }
            target07 = @{
                InitialExtraBlocks = @(
                    'target07은 pair03에서 초기 handoff를 기다리는 하단 target입니다.'
                )
                HandoffExtraBlocks = @(
                    'target07은 target03이 만든 산출물을 이어받아 pair03 중간 왕복을 수행합니다.'
                )
            }
            target08 = @{
                InitialExtraBlocks = @(
                    'target08은 pair04에서 초기 handoff를 기다리는 하단 target입니다.'
                )
                HandoffExtraBlocks = @(
                    'target08은 target04가 만든 산출물을 이어받아 pair04 중간 왕복을 수행합니다.'
                )
            }
            target05 = @{
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용이 현재 프로젝트 상태와 맞는지 다시 검토한 뒤 필요한 부분만 선별 적용하세요. 이미 반영된 내용은 반복하지 말고 실제로 필요한 수정만 진행하세요. 어떤 파일을 수정했는지, 왜 수정했는지, 무엇을 유지했고 무엇을 추가 반영했는지, 남은 리스크와 검증 결과를 summary.txt에 정리하세요. 수정이 필요 없으면 no-change와 이유를 summary.txt에 명확히 적으세요. 최종 결과는 summary.txt와 review.zip으로 만들고, 마지막에만 publish.ready.json을 생성하세요. summary.txt와 review.zip 생성 전에는 publish.ready.json을 만들지 마세요. 네가 직접 수정하지 않은 파일은 제거, 롤백, restore, 원복하지 마세요.'
                )
                HandoffExtraBlocks = @(
                    'target05는 target01이 만든 산출물을 이어받아 중간 왕복을 수행합니다.'
                )
            }
            target01 = @{
                InitialExtraBlocks = @(
                    '검토 결과 파일이 있으면 먼저 확인하고, 그 내용과 현재 프로젝트 파일을 함께 검토해 더 개선할 부분이 있는지 검토하세요. 결과는 summary.txt와 review.zip으로 만들고, 마지막에만 publish.ready.json을 생성하세요. summary.txt와 review.zip 생성 전에는 publish.ready.json을 만들지 마세요.'
                )
                HandoffExtraBlocks = @(
                    'target01은 target05가 넘긴 결과를 다시 이어받아 마지막 왕복을 마무리합니다.'
                )
            }
            target02 = @{
                InitialExtraBlocks = @(
                    'target02는 pair02 상단 시작 target입니다.'
                )
                HandoffExtraBlocks = @(
                    'target02는 target06이 넘긴 결과를 다시 이어받아 pair02 마지막 왕복을 마무리합니다.'
                )
            }
            target03 = @{
                InitialExtraBlocks = @(
                    'target03은 pair03 상단 시작 target입니다.'
                )
                HandoffExtraBlocks = @(
                    'target03은 target07이 넘긴 결과를 다시 이어받아 pair03 마지막 왕복을 마무리합니다.'
                )
            }
        }
        RunRootBase = 'C:\dev\python\hyukwoo\hyukwoo1\pair-test\bottest-live-visible'
        PairOverrides = @{
            pair04 = @{
                InitialExtraBlocks = @(
                    '이번 실행은 pair04 한 쌍(target04 ↔ target08)만 기준으로 진행합니다.'
                    '실행 순서는 target04 -> target08 -> target04 한 번 왕복으로 고정합니다.'
                )
                HandoffExtraBlocks = @(
                    '이번 실행은 pair04 한 쌍(target04 ↔ target08)만 기준으로 진행합니다.'
                    '반드시 현재 run의 pair04 폴더만 기준으로 이어서 작업하세요.'
                )
            }
            pair02 = @{
                InitialExtraBlocks = @(
                    '이번 실행은 pair02 한 쌍(target02 ↔ target06)만 기준으로 진행합니다.'
                    '실행 순서는 target02 -> target06 -> target02 한 번 왕복으로 고정합니다.'
                )
                HandoffExtraBlocks = @(
                    '이번 실행은 pair02 한 쌍(target02 ↔ target06)만 기준으로 진행합니다.'
                    '반드시 현재 run의 pair02 폴더만 기준으로 이어서 작업하세요.'
                )
            }
            pair01 = @{
                InitialExtraBlocks = @()
                HandoffExtraBlocks = @(
                    '이번 승인 테스트는 pair01 한 쌍(target01 ↔ target05)만 사용합니다.'
                    '반드시 현재 run의 pair01 폴더만 기준으로 이어서 작업하세요.'
                )
            }
            pair03 = @{
                InitialExtraBlocks = @(
                    '이번 실행은 pair03 한 쌍(target03 ↔ target07)만 기준으로 진행합니다.'
                    '실행 순서는 target03 -> target07 -> target03 한 번 왕복으로 고정합니다.'
                )
                HandoffExtraBlocks = @(
                    '이번 실행은 pair03 한 쌍(target03 ↔ target07)만 기준으로 진행합니다.'
                    '반드시 현재 run의 pair03 폴더만 기준으로 이어서 작업하세요.'
                )
            }
        }
        ReviewFolderName = 'reviewfile'
        SummaryZipMaxSkewSeconds = 2
    }
    ProcessedRoot = 'C:\dev\python\hyukwoo\hyukwoo1\processed\bottest-live-visible'
    WindowLookupTimeoutMs = 12000
    DefaultEnterCount = 1
}
