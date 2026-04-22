@{
    Root                 = 'C:\dev\python\hyukwoo\hyukwoo1'
    LaneName             = 'bottest-live'
    WindowTitlePrefix    = 'BotTest-Window'
    BindingProfilePath   = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\window-bindings\bottest-live.json'
    LauncherWrapperPath  = 'C:\Users\USER\s_8windows_left_monitor_codex.py'
    InboxRoot            = 'C:\dev\python\hyukwoo\hyukwoo1\inbox'
    ProcessedRoot        = 'C:\dev\python\hyukwoo\hyukwoo1\processed'
    FailedRoot           = 'C:\dev\python\hyukwoo\hyukwoo1\failed'
    RetryPendingRoot     = 'C:\dev\python\hyukwoo\hyukwoo1\retry-pending'
    RuntimeRoot          = 'C:\dev\python\hyukwoo\hyukwoo1\runtime'
    RuntimeMapPath       = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\target-runtime.json'
    RouterStatePath      = 'C:\dev\python\hyukwoo\hyukwoo1\runtime\router-state.json'
    RouterMutexName      = 'Global\RelayRouter_hyukwoo1'
    LogsRoot             = 'C:\dev\python\hyukwoo\hyukwoo1\logs'
    RouterLogPath        = 'C:\dev\python\hyukwoo\hyukwoo1\logs\router.log'
    AhkExePath           = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    AhkScriptPath        = 'C:\dev\python\hyukwoo\hyukwoo1\sender\SendToWindow.ahk'
    ShellPath            = 'pwsh.exe'
    ResolverShellPath    = 'pwsh.exe'
    DefaultEnterCount    = 1
    DefaultFixedSuffix   = '여기에 고정문구 입력'
    MaxPayloadChars      = 4000
    MaxPayloadBytes      = 12000
    SweepIntervalMs      = 2000
    IdleSleepMs          = 250
    RetryDelayMs         = 1000
    MaxRetryCount        = 1
    SendTimeoutMs        = 5000
    WindowLookupTimeoutMs = 12000
    WindowLookupRetryCount = 1
    WindowLookupRetryDelayMs = 750
    PairTest             = @{
        RunRootBase       = 'C:\dev\python\hyukwoo\hyukwoo1\pair-test'
        RunRootPattern    = 'run_{yyyyMMdd_HHmmss}'
        SummaryFileName   = 'summary.txt'
        ReviewFolderName  = 'reviewfile'
        MessageFolderName = 'messages'
        ReviewZipPattern  = 'review_{TargetId}_{yyyyMMdd_HHmmss}_{Guid}.zip'
        MessageTemplates  = @{
            Initial = @{
                PrefixBlocks = @(
                    '당신은 paired exchange 테스트용 창입니다.',
                    '아래 규칙과 폴더/파일 계약을 기준으로 작업하세요.'
                )
                SuffixBlocks = @(
                    '이번 턴 완료 조건: summary 파일 갱신 + review zip 1개 이상 생성',
                    '상대에게 직접 경로를 다시 타이핑하지 말고, 전달된 partner folder를 기준으로 이어서 작업하세요.',
                    '추가 검토 메모가 필요하면 내 폴더(target folder)에 매번 새 이름의 txt 파일을 만들고, 그 txt를 새 review zip에 포함하세요. 자동 전달되는 새 파일명은 내 폴더 reviewfile의 새 review zip 이름입니다. summary.txt는 같은 이름으로 갱신합니다.'
                )
            }
            Handoff = @{
                PrefixBlocks = @(
                    '상대 창에서 새 결과물이 생성되었습니다.',
                    '아래 폴더와 파일을 확인하고 다음 작업을 이어가세요.'
                )
                SuffixBlocks = @(
                    '검토 결과는 내 폴더의 summary.txt에 기록하세요. 추가 메모가 필요하면 내 폴더(target folder)에 매번 새 이름의 txt 파일을 만들고, 그 txt를 새 review zip에 포함하세요.',
                    '자동 전달되는 새 파일명은 방금 생성한 review zip 이름입니다. summary.txt는 같은 파일을 갱신합니다.'
                )
            }
        }
        PairOverrides     = @{}
        RoleOverrides     = @{
            top = @{
                InitialExtraBlocks = @(
                    '당신은 상단 창입니다. 생성 결과는 하단 파트너 창으로 전달됩니다.'
                )
                HandoffExtraBlocks = @(
                    '당신은 상단 창입니다. 하단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.'
                )
            }
            bottom = @{
                InitialExtraBlocks = @(
                    '당신은 하단 창입니다. 생성 결과는 상단 파트너 창으로 전달됩니다.'
                )
                HandoffExtraBlocks = @(
                    '당신은 하단 창입니다. 상단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.'
                )
            }
        }
        TargetOverrides   = @{}
    }
    Targets              = @(
        @{ Id='target01'; WindowTitle='BotTest-Window-01'; Folder='C:\dev\python\hyukwoo\hyukwoo1\inbox\target01'; EnterCount=1; FixedSuffix=$null }
        @{ Id='target02'; WindowTitle='BotTest-Window-02'; Folder='C:\dev\python\hyukwoo\hyukwoo1\inbox\target02'; EnterCount=1; FixedSuffix=$null }
        @{ Id='target03'; WindowTitle='BotTest-Window-03'; Folder='C:\dev\python\hyukwoo\hyukwoo1\inbox\target03'; EnterCount=1; FixedSuffix=$null }
        @{ Id='target04'; WindowTitle='BotTest-Window-04'; Folder='C:\dev\python\hyukwoo\hyukwoo1\inbox\target04'; EnterCount=1; FixedSuffix=$null }
        @{ Id='target05'; WindowTitle='BotTest-Window-05'; Folder='C:\dev\python\hyukwoo\hyukwoo1\inbox\target05'; EnterCount=1; FixedSuffix=$null }
        @{ Id='target06'; WindowTitle='BotTest-Window-06'; Folder='C:\dev\python\hyukwoo\hyukwoo1\inbox\target06'; EnterCount=1; FixedSuffix=$null }
        @{ Id='target07'; WindowTitle='BotTest-Window-07'; Folder='C:\dev\python\hyukwoo\hyukwoo1\inbox\target07'; EnterCount=1; FixedSuffix=$null }
        @{ Id='target08'; WindowTitle='BotTest-Window-08'; Folder='C:\dev\python\hyukwoo\hyukwoo1\inbox\target08'; EnterCount=1; FixedSuffix=$null }
    )
}
