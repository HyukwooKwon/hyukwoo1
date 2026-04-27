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
