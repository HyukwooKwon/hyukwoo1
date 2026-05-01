# Agent Policy

## Shared Visible Lane

- `bottest-live-visible` shared lane에서는 공식 운영 8창만 사용합니다.
- 공식 창은 `BotTestLive-Window-01` 부터 `BotTestLive-Window-08` 까지입니다.
- shared lane active visible 테스트는 기본적으로 기존 8창 재사용을 우선합니다.
- 기존 창 상태가 나쁘면 공식 운영 창만 재기동합니다.

## Forbidden Ad-Hoc Windows

- shared lane에서는 아래 임시 창 패턴을 금지합니다.
- `BotTestLive-Fresh-*`
- `BotTestLive-Surrogate-*`
- `BotTestLive-Candidate-*`

## Required Behavior

- shared lane active visible acceptance 전에는 `cleanup -> preflight-only -> active acceptance -> post-cleanup` 순서를 지킵니다.
- shared `bottest-live-visible` 실테스트는 반드시 **사용자가 보고 있는 셀창 안에서 직접 실행되는 경로**만 사용합니다.
- shared `bottest-live-visible`의 정식 실행 경로는 `typed-window -> router/AHK -> source-outbox publish -> watcher handoff` 입니다.
- 외부 repo 감지는 “폴더 안에 파일이 있기만 하면 성공” 방식이 아니라, 이번 run/pair/target에 확정된 `summary.txt + review.zip + publish.ready.json` strict contract path만 감시합니다.
- 외부 contract path는 모두 explicit path여야 하고, 선택한 `WorkRepoRoot` 내부에 있어야 합니다. target 간 contract path가 충돌하면 시작 즉시 실패해야 합니다.
- target request에 `WorkRepoRoot`가 있으면 headless Codex 실행은 `targetFolder` 대신 그 `WorkRepoRoot`를 실제 process working directory와 `codex -C` 기준으로 사용해야 합니다.
- 다만 현재 multi-pair external runroot/bookkeeping은 아직 selected pair들이 하나의 shared external bookkeeping root를 쓴다는 가정이 남아 있으므로, 서로 다른 repo를 pair별로 완전 혼합하는 구조는 2단계 작업으로 취급합니다.
- 현재 1단계 mixed pair 지원은 `pair별 target/work/request/runroot + pair별 explicit contract path + pair별 actual Codex cwd` 까지입니다. 여러 pair가 서로 다른 repo를 쓰더라도 top-level coordinator `RunRoot`와 bookkeeping roots는 하나의 shared external coordinator root를 써도 됩니다.
- `2026-04-27` 기준 headless mixed pair live proof는 `pair01 -> repo-a`, `pair02 -> repo-b`, shared coordinator repo 조합으로 `1 roundtrip`과 `3 roundtrip`까지 통과했습니다. 다만 bookkeeping root를 pair별로 완전 분리하는 2단계는 아직 아닙니다.
- `2026-04-28` 기준 pair-scoped externalized config writer도 추가되어 `pair01 -> repo-a`, `pair02 -> repo-b`처럼 각 pair repo 아래 `.relay-config / .relay-bookkeeping / .relay-runs`를 별도 경로로 생성할 수 있습니다.
- 같은 날짜 기준 stage2 live proof도 pair별로 `1 roundtrip`씩 완료했습니다. `pair01 -> repo-a` 와 `pair02 -> repo-b`는 각자 자기 pair-scoped config와 pair-scoped bookkeeping roots에서 `pair-roundtrip-limit-reached`로 clean stop까지 통과했습니다.
- 같은 날짜 기준 pair-scoped config 두 개를 병렬로 동시에 태우는 stage2 parallel live proof도 `1 roundtrip`까지 통과했습니다. 즉 `pair01 -> repo-a`, `pair02 -> repo-b`를 서로 다른 pair-scoped bookkeeping roots에서 동시 실행해도 둘 다 clean stop까지 확인했습니다.
- 같은 날짜 기준 shared coordinator root 아래 aggregate manifest/state를 남기는 stage2 shared-orchestrator live proof도 `1 roundtrip`까지 통과했습니다. 이 경로는 coordinator repo에 aggregate `manifest.json`, `.state\\watcher-status.json`, `.state\\pair-state.json` 을 남기고, 실제 pair 작업/contract/bookkeeping은 각 pair repo 아래에 유지합니다.
- 같은 날짜 기준 pair-scoped stage2의 `3 roundtrip` proof도 닫혔습니다. pair-scoped 병렬 run은 `pair01`, `pair02` 둘 다 `ForwardedCount=6`, `RoundtripCount=3`, `DonePresentCount=2`, `ErrorPresentCount=0`으로 clean stop했고, shared coordinator aggregate run도 `ForwardedCount=12`, `DonePresentCount=4`, `ErrorPresentCount=0`, `pair-scoped-shared-coordinator-limit-reached`로 expected stop까지 확인했습니다.
- pair-scoped parallel wrapper는 coordinator root가 있을 때 `.state\\wrapper-status.json`도 같이 남깁니다. 상위 셸 timeout이나 panel wrapper timeout이 나더라도, 이 파일에서 child pair run root와 현재 wrapper 단계부터 먼저 읽으면 됩니다.
- 상위 wrapper가 먼저 timeout으로 끊겼다면 `tests\\Resolve-ParallelPairScopedWrapperStatus.ps1 -CoordinatorRunRoot <...> -AsJson` 로 child pair run 상태를 다시 읽어 `wrapper-status.json` 을 reconcile 해야 합니다. 이 스크립트는 pair별 `WatcherState`, `RoundtripCount`, `CurrentPhase`, `LastHeartbeatAt`, `FinalResult`, `CompletionSource` 를 다시 기록하고, 모든 child run이 clean stop이면 coordinator aggregate manifest/state도 복구합니다.
- 다만 이 shared-orchestrator stage2는 aggregate coordinator state를 쓰는 방식이고, pair별 watcher를 단일 shared watcher 하나로 통합한 구조는 아직 아닙니다.
- watcher 제어 의미는 현재 `pause/resume` 과 `stop/restart` 로 나뉩니다. `pause/resume` 은 queued/pending 상태를 유지한 채 다음 동작만 잠시 멈추고 이어가는 뜻이고, `stop` 은 현재 watcher 종료입니다. stop 뒤에는 resume이 아니라 restart가 필요합니다. watcher 제어 전용 hotkey는 아직 없습니다.
- 운영 패널의 `설정 / 문구` 탭에는 `4 Pair 설정 / 실효 경로` 카드가 있으며, 여기서 pair별 `DefaultSeedWorkRepoRoot`, `DefaultSeedTargetId`, `DefaultPairMaxRoundtripCount`, `UseExternalWorkRepoRunRoot`, `UseExternalWorkRepoContractPaths` 를 바로 수정하고 `실효값` preview로 repo/runroot/source-outbox/publish-ready 경로를 먼저 확인해야 합니다.
- 상단 `RunRoot Override` 입력칸은 pair 정책 자체가 아니라 실행 컨텍스트 override입니다. 비워두면 pair 정책 기준 selected/new RunRoot를 사용하고, 값이 있으면 그 경로가 우선합니다.
- 같은 카드에서 `Repo 선택`, `Repo 열기`, `설정 복제`, `요약`, `route matrix 복사`, `route JSON 저장`까지 바로 수행할 수 있고, `ROUTE OK` / `SHARED REPO OK` / `ROUTE CHECK` 배지로 현재 pair route 상태를 먼저 읽도록 유지합니다.
- 각 pair 카드의 `병렬 drill` 체크와 상단 `선택 pair 병렬 실테스트` 버튼은 체크된 pair들만 `tests\\Run-ParallelPairScopedHeadlessDrill.ps1` 경로로 실행하는 thin wrapper입니다. `coordinator repo` 입력값 아래 shared coordinator runroot를 만들고, 완료 시 panel RunRoot를 그 coordinator runroot로 맞춰 runtime 배지와 wrapper-status를 바로 읽어야 합니다.
- pair 카드에서는 `PAIR POLICY` / `GLOBAL DEFAULT` 배지로 repo source를, `RUNROOT AUTO` / `RUNROOT SELECTED MIRROR` / `RUNROOT OVERRIDE ACTIVE` 배지로 현재 runroot 입력 의미를 먼저 확인합니다.
- 상단 `RunRoot Override` 상태 텍스트는 `AUTO` / `SELECTED MIRROR` / `OVERRIDE ACTIVE` / `STALE` 로 읽습니다.
- `전체 실효값` 버튼은 4 pair의 effective repo/runroot/source-outbox/publish-ready preview를 한 번에 갱신하는 운영 helper로 유지합니다.
- 같은 pair 카드에서는 `RUNNING` / `WAITING` / `DONE` / `ERROR` / `STOPPED` runtime 배지도 함께 표시합니다. 값은 현재 RunRoot의 `.state\\wrapper-status.json` 을 우선 읽고, 없으면 기존 paired status로 fallback 해서 pair별 진행률을 보여줍니다.
- `설정 / 문구` 탭의 `초기 실행 준비 / Seed Kickoff Composer` 는 영구 pair 정책과 분리된 1회성 kickoff 입력 helper입니다. 사용자는 `Pair`, `SeedTarget`, `입력 파일`, `작업 설명`만 입력하고, panel이 현재 pair의 실효 경로를 읽어 `summary.txt / review.zip / publish.ready.json` 절대경로와 helper 경로를 자동 합성해 보여줘야 합니다.
- Composer 상단에는 `붙여넣기 대상`, `시작 가능 여부`, `빠른 시작`을 고정으로 보여주고, 세부 블록은 기본 접힘 상태를 유지합니다.
- Composer의 `수동 시작문 복사`는 target 전달문만 복사하고, operator 확인용 설명 블록은 화면 미리보기에만 남깁니다.
- `경로만 복사`, `시작 순서 복사`, `helper 명령 복사`는 복사용 helper이고, `초기 입력 큐잉`은 `Initial/Handoff` 영구 설정을 건드리지 않고 one-time queue에만 등록해야 합니다.
- queue에는 작업 설명 블록만 저장하고, 경로/파일 계약/helper 안내는 seed/handoff scaffold가 별도로 자동 추가된다는 의미를 panel 상태 문구와 문서에서 같이 유지합니다.
- 권장 운영 순서는 `pair 설정 저장 + 새로고침 -> 실효값 확인 -> 수동 시작문 복사 또는 초기 입력 큐잉` 으로 고정합니다.
- `visible worker queue -> Invoke-CodexExecTurn` 경로는 shared real test에서 금지하고 maintenance/diagnostic 전용으로만 둡니다.
- typed-window 경로에서는 `send_complete`, `processed ready`, `submit_complete`만으로 성공 판정하지 않습니다.
- typed-window 입력은 shared lane에서 `paste + submit guard + attempt당 1회 최종 submit`를 기본 계약으로 사용하고, 입력 완료 전 submit dispatch나 같은 attempt 안 다중 submit을 허용하지 않습니다.
- shared typed-window active run에서는 payload attempt 중간에 inline `/new` prepare submit을 허용하지 않습니다. `/new`는 bootstrap/recovery 단계에서만 허용하고, seed/handoff payload attempt는 항상 `전체 payload 1회 paste -> 마지막 1회 submit` 으로 끝나야 합니다.
- shared typed-window 실테스트는 대상 창 title에 `VISIBLE targetXX SENDING/RUNNING` 비콘이 실제로 보여야 하고, 이 가시 비콘 없이 artifact/log만으로 `보이는 셀창 실행 성공`이라고 판정하지 않습니다.
- shared typed-window 실테스트에서는 submit 직전 포커스를 다른 앱이 뺏으면 조용히 refocus해서 진행하지 말고 즉시 실패로 닫습니다.
- shared typed-window 실테스트에서는 submit 직후 이전 활성 창으로 자동 복귀하지 않고, 대상 셀창을 잠시 전경에 유지해 사용자가 실제 전송 대상을 눈으로 확인할 수 있어야 합니다.
- typed-window seed/handoff submit 뒤에는 `10초 no-progress probe`를 수행하고, 진행 신호가 없으면 `1회만` 재전송합니다.
- 위 probe 뒤에도 진행 신호가 없으면 `typed-window-submit-unconfirmed` 계열 실패로 닫고, 무한 재시도나 수동 broad retry는 금지합니다.
- shared `bottest-live-visible`의 `WorkRepoRoot` / `ReviewInputPath`는 반드시 `hyukwoo1` 자동화 레포 외부 경로여야 합니다.
- `C:\dev\python\hyukwoo\hyukwoo1` 또는 그 하위 경로를 seed work repo / review input으로 사용하면 즉시 실패해야 합니다.
- shared `bottest-live-visible`의 `RunRoot`도 반드시 현재 작업 중인 external `WorkRepoRoot` 아래에 있어야 합니다. `RunRoot`가 `hyukwoo1` 자동화 레포 아래이거나, 선택한 `WorkRepoRoot` 밖이면 즉시 실패해야 합니다.
- shared visible lane에서 “외부 repo 사용”은 `WorkRepoRoot`만 외부인 상태를 뜻하지 않습니다. `primary source-outbox contract(summary.txt / review.zip / publish.ready.json)` 도 반드시 현재 작업 중인 외부 repo root 아래에 생성되고 감지되어야 합니다.
- 작업 repo가 바뀌면 감지 경로도 같이 바뀌어야 하며, watcher는 repo 전체를 재귀 감시하지 않고 이번 run/pair/target에 대해 manifest/request에 기록된 explicit contract path만 strict 검증합니다.
- acceptance smoke 기본 work repo는 `C:\dev\python\relay-workrepo-visible-smoke` 를 사용합니다.
- acceptance smoke 기본 runroot base는 `C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible` 입니다.
- 외부 repo 산출물 감지가 필요하면 `WorkRepoRoot`를 바꾸고, contract publish 경로는 그 repo 안의 `.relay-contract\...` 아래로 확정해서 사용합니다. repo 전체 재귀 감시는 허용하지 않습니다.
- shared visible lane의 현재 구현 기준은 `primary contract externalized + external runroot` 입니다. `summary.txt / review.zip / publish.ready.json` 과 `RunRoot` 는 외부 repo 기준이어야 하지만, import copy / receipt bookkeeping까지 전부 외부 repo로 옮긴 `full externalized`는 아직 2단계 작업입니다.
- shared visible lane receipt/manifest에는 현재 외부화 수준을 숨기지 말고 그대로 남겨야 합니다. 최소 `PrimaryContractExternalized`, `ExternalRunRootUsed`, `BookkeepingExternalized`, `FullExternalized`, `InternalResidualRoots` 를 기록해 무엇이 아직 automation repo bookkeeping으로 남는지 바로 읽히게 합니다.
- external mode에서 `InboxRoot`, `ProcessedRoot`, `RuntimeRoot`, `LogsRoot` 가 여전히 `hyukwoo1`를 가리키면 real run을 시작하지 말고 `automation-repo-bookkeeping-roots-disallowed` 로 즉시 실패시킵니다. live proof보다 먼저 residual bookkeeping roots를 external `WorkRepoRoot` 기준으로 맞추는 것이 우선입니다.
- shared `bottest-live-visible`에서 창 종료/재실행/정리는 제목 기준 broad close로 처리하지 않습니다.
- 창 정리는 `runtime/window-bindings/bottest-live-visible.json` 에 기록된 binding-managed 8개 HWND만 대상으로 합니다.
- 기존 8창이 살아 있으면 wrapper는 새 창을 더 띄우지 않고 재사용하거나, 명시적 replace 절차에서만 binding-managed 8개만 닫습니다.
