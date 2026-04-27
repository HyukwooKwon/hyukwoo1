# Operations Acceptance

이 문서는 현재 relay 운영 보조 범위의 종료선을 짧게 고정하는 메모입니다.

적용 일자:

- `2026-03-31`
- `2026-04-25`
- `2026-04-26`

현재 이 범위에서 완료로 보는 항목:

- `show-effective-config.ps1`를 SSOT 출력기로 사용
- `relay_operator_panel.py`는 artifact check/submit 운영 보조 UI까지 포함
- preview snapshot과 evidence snapshot 역할 분리
- `Decision=none|review|block` 해석 고정
- 1회성 문구 큐의 등록 / 조회 / preview 반영 / cancel / expired cleanup 완료
- headless 실제 실행 성공 시 applicable 1회성 문구 자동 `consumed` 처리
- 수동 `consume-one-time-message.ps1`는 예외 정리 절차로만 사용
- pair별 활성/비활성 상태는 정적 config 수정이 아니라 `runtime\pair-activation\bottest-live-visible.json` 런타임 상태 파일로 관리
- `disable-pair.ps1`, `enable-pair.ps1`로만 pair on/off를 바꾸고, 실행기와 panel은 같은 상태를 읽어 차단/표시
- pair on/off 기본 조회기는 `show-pair-activation-status.ps1`로 고정
- `launch-relay-operator-panel.cmd`, `open-relay-operator-panel.vbs`는 Windows에서 panel 프로세스 기동까지 확인
- target-local `check-artifact.*`, `submit-artifact.*` wrapper 자동 생성 확인
- panel 결과 / 산출물 탭에서 target-local wrapper 우선 실행, legacy fallback 경고, recent submit 재확인, submit 중복 방지 확인
- `_tmp\artifact-source-memory.json`의 source path persistence, 원자 저장, 깨진 JSON 복구, warning badge 표시 확인
- 외부 repo packaging zip은 source artifact일 뿐이고, panel/wrapper/import submit 전에는 watcher가 target contract를 아직 못 본다는 운영 해석 고정
- `run-preset-headless-pair-drill.ps1`, `launch-preset-headless-pair-drill.cmd`, `open-preset-headless-pair-drill.vbs`는 preset pair 단일 왕복 공통 경로로 사용
- `run-pair01~04-headless-drill.ps1`, `launch-run-pair01~04-headless-drill.cmd`, `open-run-pair01~04-headless-drill.vbs` shortcut은 위 공통 preset 경로에 pair id만 고정하고, 각 pair 한 쌍 실제 왕복 성공까지 확인
- shared visible active acceptance + passive confirm + `-RequireVisibleReceipt` closeout이 같은 RunRoot에서 `overall=success`로 닫힘
- clean preflight recheck가 최신 receipt를 `preflight-passed`로 덮어써도, `show-paired-run-summary.ps1`와 `Confirm-SharedVisiblePairAcceptance.ps1`는 `PhaseHistory`의 마지막 성공 acceptance를 우선 판정함
- shared lane final closeout clean 기준은 `visible\Cleanup-VisibleWorkerQueue.ps1 -AsJson`의 `Summary.ProtectedRunCount=0`으로 고정

현재 운영 원칙:

- source of truth는 panel이 아니라 `show-effective-config.ps1 -AsJson`
- `_tmp`는 preview/임시 확인용
- `evidence\effective-config`는 운영 증거 저장용
- `_tmp\rendered-messages`는 임시 preview 보관소로 보고 최근 7일 또는 최근 50개 수준만 유지
- `runtime\one-time-queue\<lane>\archive`는 queue 감사 기록으로 보고 최근 30일 기준으로 정리
- `runtime\pair-activation\<lane>.json`는 현재 운영 상태만 유지하고 archive하지 않으며, 만료/불필요 override만 정리
- `evidence\effective-config`는 승인/이상 run 근거를 우선 보관하고, 일반 evidence는 최근 90일 기준으로 정리
- warning은 review 신호이고, 실행 하드 게이트는 `check-target-window-visibility.ps1`, `check-headless-exec-readiness.ps1`
- panel은 설정 저장 UI가 아니라 운영 보조 UI이며, source of truth는 계속 `show-effective-config.ps1 -AsJson`
- panel의 artifact check/submit은 target-local wrapper를 우선 사용하고, legacy fallback submit은 강한 경고 + 추가 승인 경로로만 허용
- 새 RunRoot의 기본 publish 경로는 panel submit이 아니라 `source-outbox -> publish.ready.json -> watcher auto import` 입니다.
- `.published` marker archive는 운영 감사 기록으로 유지하고, 현재 활성 run은 자동 정리하지 않습니다. retention 정리는 종료된 오래된 run에 대해서만 수동 maintenance로 수행합니다.
- panel은 같은 lane에 대해 한 번에 1개 인스턴스만 사용하는 것을 기본 정책으로 둡니다. `_tmp\artifact-source-memory.json`은 원자 저장이지만, 다중 panel 동시 실행 시 마지막 저장값이 우선합니다.
- panel의 실제 클릭/시각 배치와 paired artifact acceptance는 운영자가 Windows 데스크톱에서 확인

현재 acceptance 종료선:

- 새 RunRoot에서 `Start-PairedExchangeTest.ps1` 실행 후 target별 `source-outbox`, `publish.ready.json`, `.published` archive 경로와 recovery wrapper가 함께 생성됨
- `Watch-PairedExchange.ps1` 실행 후 `source-outbox\summary.txt`, `source-outbox\review.zip`, `source-outbox\publish.ready.json` 생성만으로 watcher가 자동 import를 수행하고 다음 단계로 진행
- watcher 실행 호스트는 `powershell.exe`가 아니라 `pwsh`를 공식 경로로 사용한다.
- 성공 후 target contract folder 아래 `summary.txt`, `reviewfile\*.zip`, `done.json`, `result.json`이 자동 생성되고 ready marker는 `.published` 아래로 archive 됨
- 첫 acceptance는 `target01`만 먼저 publish해서 `target01 -> target05` 순서를 확인함
- stale RunRoot 또는 wrapper missing 상황에서 강한 warning badge와 fallback submit 추가 확인이 실제로 보임
- panel 재실행 후 `_tmp\artifact-source-memory.json`의 최근 source path가 다시 복원됨
- 위 절차는 새 RunRoot 기준으로 닫고, 예전 RunRoot는 호환 확인 대상이지 기본 acceptance 대상이 아님
- successful shared visible closeout 기준은 아래 4가지를 함께 만족하는 경우로 고정
  - `show-paired-run-summary.ps1`가 `overall=success acceptance=roundtrip-confirmed stage=completed`
  - `tests\Confirm-SharedVisiblePairAcceptance.ps1 -RequireVisibleReceipt`가 `overall=success`
  - summary/confirm이 latest receipt current state가 아니라 `PhaseHistory`의 마지막 성공 acceptance를 effective result로 읽음
  - final cleanup dry-run에서 `ProtectedRunCount=0`
- current receipt가 clean preflight recheck 때문에 `preflight-passed`여도, `PhaseHistory`에 `roundtrip-confirmed` 또는 `first-handoff-confirmed`가 남아 있으면 그 성공 acceptance를 무효화하지 않음
- baseline success가 이미 닫힌 뒤 shared lane이 foreign active run 때문에 다시 더러워지면, reopen 없이 `foreign run terminal 대기 -> cleanup dry-run/apply -> preflight-only clean pass`만 수행합니다.
- 이때 목적은 새 acceptance 재실행이 아니라 현재 시점 lane clean 복귀 확인입니다.

shared visible typed-window real-test 기준선:

- `2026-04-26`부터 shared `bottest-live-visible` 실테스트는 visible-worker가 아니라 `typed-window` 경로만 허용한다.
- 의미:
  - 사용자가 실제로 보고 있는 셀창 안에서 prompt가 실행되어야 한다.
  - `visible-worker`는 hidden/background 실행이므로 shared real-test 경로로 간주하지 않는다.
  - `visible-worker` 관련 closeout/evidence는 historical baseline으로만 유지한다.
  - typed-window에서 `send_complete`, `processed ready`, `AHK submit_complete` 는 성공 증거가 아니다.
  - typed-window 입력은 `paste + submit guard + attempt당 1회 최종 submit` 를 기본 계약으로 사용하고, payload 입력 완료 전 submit dispatch나 같은 attempt 안 다중 submit을 정상 경로로 보지 않는다.
  - shared typed-window active run에서는 payload attempt 중간에 inline `/new` prepare submit을 허용하지 않는다. `/new`는 bootstrap/recovery 단계에서만 허용하고, seed/handoff payload attempt는 항상 `전체 payload 1회 paste -> 마지막 1회 submit` 으로 끝나야 한다.
  - shared typed-window 실테스트에서는 대상 창 title에 `VISIBLE targetXX SENDING/RUNNING` 비콘이 실제로 보여야 하고, 이 가시 비콘 없이 artifact/log만으로 `사용자가 보는 셀창 실행 성공`이라고 판정하지 않는다.
  - shared typed-window 실테스트에서는 submit 직전 다른 앱이 포커스를 가져가면 조용히 refocus해서 계속하지 않고 즉시 실패 처리한다.
  - shared typed-window 실테스트에서는 submit 직후 이전 활성 창으로 자동 복귀하지 않고, 대상 셀창을 잠시 전경에 유지해 운영자가 실제 전송 대상을 눈으로 확인할 수 있어야 한다.
  - typed-window seed/handoff 직후에는 `10초 no-progress probe` 를 수행하고, 진행 신호가 없으면 `1회만` 자동 재전송한다.
  - 재전송 뒤에도 진행 신호가 없으면 `typed-window-submit-unconfirmed` 또는 동등한 typed-window 상태로 즉시 실패 처리한다.

visible worker closeout 기준선 (historical only):

- `2026-04-25` 기준 shared official visible-worker closeout baseline run은 `run_closeout_20260425_r4`
- 경로:
  - `pair-test\bottest-live-visible\run_closeout_20260425_r4`
- baseline evidence 보관 경로:
  - `evidence\visible_worker_closeout_r4`
- shared `bottest-live-visible`의 창 제어 SSOT:
  - launch = `LauncherWrapperPath` wrapper only
  - reuse = attach-only
  - `launcher\Start-Targets.ps1`, `launcher\Ensure-Targets.ps1` direct path는 maintenance 전용이며 운영 경로가 아님
  - 창 종료/재실행/정리는 binding-managed 8개 HWND만 대상으로 한다
  - 제목(`gptgpt1-dev`, `BotTestLive-Window-*`) 기준 broad close는 shared lane에서 금지한다
  - sanctioned close/reset 경로는 `launcher\Close-BoundVisibleWindows.ps1` 또는 wrapper의 explicit replace-only 경로다
- shared active real-test 실행 SSOT:
  - `PairTest.ExecutionPathMode=typed-window`
  - `PairTest.RequireUserVisibleCellExecution=$true`
  - active acceptance는 사용자가 보는 셀창 실행이 아니면 시작 자체를 실패로 본다
- maintenance 예외 절차는 운영 acceptance 본문과 분리한다:
  - 운영 acceptance에서는 `Start-Targets.ps1`, `Ensure-Targets.ps1`, `Refresh-Targets.ps1`를 직접 실행하지 않는다
  - 복구가 필요하면 먼저 `Cleanup-VisibleWorkerQueue.ps1` / `-PreflightOnly` / `Confirm-SharedVisiblePairAcceptance.ps1` 로 상태를 진단한다
  - direct launcher가 꼭 필요하면 별도 maintenance 단계에서만 수행하고, shared acceptance evidence와 섞어 해석하지 않는다
- historical visible-worker baseline 성공 조건:
  - `target01` 단일 seed로 시작
  - 당시 기준 `PairTest.ExecutionPathMode=visible-worker`
  - 공식 `BotTestLive-Window-01` / `05` 재사용
  - watcher `Reason=max-forward-count-reached`
  - watcher `StopCategory=expected-limit`
  - `ForwardedCount=4`
  - `DonePresentCount=2`
  - `ErrorPresentCount=0`
  - post-cleanup `-ReuseExistingRunRoot -PreflightOnly` clean pass
- 현재 shared real-test 정식 경로는 `typed-window -> router/AHK -> source-outbox -> watcher` 이다.
- 외부 repo 감지는 “아무 파일이 생기면 진행”이 아니라, 이번 run/pair/target에 확정된 `summary.txt + review.zip + publish.ready.json` strict contract path만 대상으로 한다.
- 외부 contract path는 모두 explicit path여야 하고, 선택한 `WorkRepoRoot` 내부에 있어야 한다. target 간 contract path가 충돌하면 run 시작을 허용하지 않는다.
- acceptance receipt에는 `Contract.ExternalWorkRepoUsed`, `Contract.PrimaryContractExternalized`, `Contract.ExternalRunRootUsed`, `Contract.BookkeepingExternalized`, `Contract.FullExternalized`, `Contract.ExternalContractPathsValidated`, `Contract.InternalResidualRoots`, target별 `ContractRootPath` / `SourceSummaryPath` / `SourceReviewZipPath` / `PublishReadyPath` 가 같이 남아야 한다.
- 외부 repo 사용 정책은 아래 두 층을 반드시 구분해서 본다.
  - `primary contract externalized`: `summary.txt`, `review.zip`, `publish.ready.json` 이 현재 작업 중인 외부 repo root 아래 explicit contract path에 생성되고 watcher가 그 경로만 strict 검증하는 상태
  - `full externalized`: 위 primary contract뿐 아니라 `RunRoot`, receipt/status, import된 summary/review/done/result bookkeeping copy도 외부 repo 기준으로 남는 상태
- shared `bottest-live-visible`의 현재 구현 baseline은 `primary contract externalized + external runroot`다. `WorkRepoRoot`와 `RunRoot`는 외부 repo 기준이어야 하지만, import된 summary/review/done/result bookkeeping copy까지 전부 외부화한 `full externalized`는 아직 2단계 작업이다.
- 현재 base config의 `InboxRoot / ProcessedRoot / RuntimeRoot / LogsRoot` 가 아직 `hyukwoo1`를 가리키면 shared external mode active run은 `automation-repo-bookkeeping-roots-disallowed` 로 즉시 실패해야 한다. external mode live proof는 이 residual bookkeeping roots도 현재 작업 중인 external `WorkRepoRoot` 아래로 옮긴 effective config에서만 수행한다.
- `RunRoot`는 반드시 현재 작업 중인 `WorkRepoRoot` 아래 `.relay-runs\bottest-live-visible\...` 경로로 생성되어야 한다. `hyukwoo1` 아래 RunRoot나, 선택한 `WorkRepoRoot` 밖 RunRoot는 hard fail로 막는다.
- 작업 repo가 바뀌면 감지 경로도 같이 바뀌어야 한다. watcher는 repo 전체를 감시하지 않고, 이번 run/pair/target에 대해 request/manifest에 기록된 `SourceOutboxPath`, `SourceSummaryPath`, `SourceReviewZipPath`, `PublishReadyPath` explicit path만 strict 검증한다.
- `summary.txt`, `review.zip`, `publish.ready.json` 는 반드시 현재 작업 중인 그 external root repo 안에서 생성되어야 한다. 다른 repo나 automation repo에서 생성된 동명 파일을 fallback 성공 신호로 취급하지 않는다.
- `visible-worker`는 maintenance/diagnostic 전용이고, shared real-test closeout 근거로 쓰지 않는다.
- typed-window submit confirmation은 `source-outbox 변화`, `done/result/publish.ready 생성`, `Codex child CPU delta` 같은 진행 신호로만 확정한다.
- typed-window 경로에서 무한 재시도는 금지하고, 승인된 자동 복구는 `10초 probe + 1회 재전송` 까지만 허용한다.
- shared `bottest-live-visible`의 `WorkRepoRoot` / `ReviewInputPath`는 반드시 `hyukwoo1` 자동화 레포 외부 경로여야 한다.
- `hyukwoo1`는 automation/runtime/config 레포로만 사용하고, 실제 검토/적용 대상 repo 경로로 사용하지 않는다.
- acceptance smoke 기본 외부 work repo는 `C:\dev\python\relay-workrepo-visible-smoke` 이다.
- acceptance smoke 기본 external runroot base는 `C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible` 이다.
- 외부 repo를 바꿔도 contract publish 경로만 그 repo 안의 `.relay-contract\...` 아래로 확정하면 watcher는 그대로 strict 검증으로 감지할 수 있다. repo 전체 재귀 감시는 운영 경로로 허용하지 않는다.
- split-button rollout 기준선:
  - 범위는 우선 `pair01` 한 쌍으로 고정한다.
  - 기존 `cleanup -> preflight-only -> active acceptance -> post-cleanup` 매크로 버튼은 유지한다.
  - 추가 분리 버튼은 `8창 재사용/attach`, `typed-window 입력 가능 점검`, `선택 target preview/apply`, `선택 target 1회 submit`, `source-outbox publish 확인`, `watcher import/handoff 확인` primitive만 우선 노출한다.
  - `선택 target 1회 submit`, `source-outbox publish 확인`, `watcher import/handoff 확인`은 panel 내부 분기 대신 `tests\Invoke-PairedExchangeOneShotSubmit.ps1`, `tests\Confirm-PairedExchangePublishPrimitive.ps1`, `tests\Confirm-PairedExchangeHandoffPrimitive.ps1` 공용 wrapper를 먼저 타게 유지한다.
  - `tests\Run-LiveVisiblePairAcceptance.ps1`도 같은 wrapper를 순서대로 호출하는 얇은 오케스트레이터로 유지하고, receipt에 `Primitives.*` payload와 `Evidence`를 남긴다.
  - publish/handoff row 판정과 acceptance reason 선택은 `tests\PairedExchangeConfig.ps1`의 shared helper를 같이 써서, wrapper와 macro가 같은 acceptance 기준을 본다.
  - panel은 SSOT가 아니라 launcher/status helper로 유지하고, 상태 판정은 `show-effective-config.ps1 -AsJson`, receipt JSON, state JSON에서 계속 읽는다.
- reopen 기준:
  - shared official 재사용 경로에서 `ForwardedStateCount=4` 미달
  - `DonePresentCount=2` 또는 `ErrorPresentCount=0` 불만족
  - post-cleanup `Preflight.CheckState=passed` 불만족
  - timeout 뒤 fresh source-outbox publish가 있었는데 stale error가 다시 남음
  - stale failure가 done/publish-ready/source-outbox success보다 우선 판정됨

현재 범위에서 의도적으로 하지 않는 것:

- 고정문구 자유 편집 UI
- 전체 문구 순서 drag-and-drop 재배열
- panel에서 live 설정 즉시 저장
- preview 시점 consume 처리
- 다중 panel 인스턴스 동시 편집/동기화

이 범위를 다시 열 조건:

- lane/config 구조 변경
- binding/launcher 구조 변경
- headless dispatch 성공 기준 변경
- warning/evidence 정책 변경
- 1회성 문구 큐의 live consume 규칙 변경
- pair activation 상태 파일 경로/해석 규칙 변경
- 같은 shared visible 조건에서 success closeout이 재현되지 않음
- `PhaseHistory` precedence가 깨져 clean preflight recheck 뒤 summary/confirm이 다시 `failing` 또는 `in-progress`로 후퇴함
- final cleanup dry-run에서 `ProtectedRunCount=0`인데도 confirm 계열이 실패함
- foreign protected run blocker가 반복적으로 운영 병목이 되어 구조화된 상태 모델 승격이 필요해짐

운영 반복 검증 기준 문서:

- [OPERATIONS-CHECKLIST.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-CHECKLIST.md)
- [OPERATIONS-DRILLS.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-DRILLS.md)

한 줄 기준:

- 지금 범위는 기능 추가보다 운영 반복 검증과 문서 기준 유지가 우선입니다.
