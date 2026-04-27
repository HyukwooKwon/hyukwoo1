# Operations Checklist

이 문서는 relay 운영 승인과 반복 점검 때 사용하는 최소 체크리스트입니다.
아래 예시는 현재 visible 운영 lane 기준으로 `.\config\settings.bottest-live-visible.psd1`를 사용합니다.
현재 범위의 종료선과 reopen 조건은 [OPERATIONS-ACCEPTANCE.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-ACCEPTANCE.md)를 따릅니다.
8개 창 운영표와 pair 매핑은 [TARGET-OPERATIONS-MATRIX.md](C:\dev\python\hyukwoo\hyukwoo1\TARGET-OPERATIONS-MATRIX.md)를 기준으로 확인합니다.

## 표준 순서

1. 사전 진단

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ensure-targets.ps1 -DiagnosticOnly
```

통과 기준:
- `matched=8`
- `missing=0`
- `duplicate=0`

2. target 준비

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ensure-targets.ps1
```

통과 기준:
- attach 또는 cleanup 없는 launch 성공
- 기존 장수 PowerShell 세션 종료 `0건`

3. 실제 입력 가능 창 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-target-window-visibility.ps1
```

통과 기준:
- `Injectable: ok=8 fail=0`
- 각 target이 `InjectionMethod`를 하나 이상 가짐

4. relay 상태 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-relay-status.ps1
```

통과 기준:
- runtime target `8/8`
- `LauncherSessionId` single
- `Next Actions`가 안전 경로만 가리킴

4b. pair 활성 상태 빠른 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-pair-activation-status.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

확인 포인트:
- pair01~pair04 활성/비활성 상태
- 비활성 사유와 만료 시각
- 현재 점검/중지 대상 pair만 정확히 막혀 있는지

4a. 적용 설정/문구/폴더 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-effective-config.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01
```

확인 포인트:
- lane / binding / launcher 메타
- pair01 `target01 <-> target05` 폴더/파일 경로
- initial / handoff 최종 문구 preview
- initial / handoff 문구 조합 순서와 출처
- initial / handoff에 걸린 1회성 문구 대기 항목
- 설정 경로와 실제 존재 경로의 차이

필요하면 선택 pair/target 기준 preview 산출물도 저장합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\render-pair-message.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -TargetId target01 -Mode both -WriteOutputs
```

필요하면 1회성 문구 큐를 등록/조회한 뒤 preview에 반영되는지 확인합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\enqueue-one-time-message.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -Role top -TargetId target01 -AppliesTo handoff -Placement one-time-prefix -Text "이번 1회에만 넣을 문구"
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-one-time-message-queue.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01
powershell -NoProfile -ExecutionPolicy Bypass -File .\cancel-one-time-message.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -ItemId <queue-item-id>
powershell -NoProfile -ExecutionPolicy Bypass -File .\cleanup-one-time-message-queue.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -State all
powershell -NoProfile -ExecutionPolicy Bypass -File .\consume-one-time-message.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -ItemId <queue-item-id>
```

확인 포인트:
- `show-one-time-message-queue.ps1 -State queued|cancelled|expired`로 상태별 확인
- 취소 archive는 `runtime\one-time-queue\<lane>\archive\`에 JSON으로 저장
- active queue 정리는 `cleanup-one-time-message-queue.ps1`로 하고, cleanup archive는 같은 `archive` 폴더에 남깁니다.
- headless 실제 실행 성공 후에는 applicable 1회성 문구가 자동으로 `consumed` archive로 이동하고 active queue에서 제거됩니다.
- `consume-one-time-message.ps1`는 preview/live 상태가 꼬였을 때만 쓰는 예외 정리용 수동 명령입니다.

5. router 시작

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\router.ps1
```

6. 전체 수동 승인 E2E

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Manual-E2E-AllTargets.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

통과 기준:
- `summary success=8 failure=0`
- 기존 장수 PowerShell 세션 종료 `0건`

7. paired test 준비

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-PairedExchangeTest.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live -SendInitialMessages
```

메모:
- `-RunRoot`를 생략하면 `config\settings.bottest-live-visible.psd1`의 `PairTest.RunRootBase + RunRootPattern` 기준으로 새 run 폴더를 자동 생성합니다.
- 각 pair는 `pairXX\targetYY` 폴더를 만들고 `summary.txt`, `reviewfile`, `messages` 계약을 `PairTest` 설정 기준으로 사용합니다.
- 같은 `RunRoot`에 initial seed만 다시 넣을 때는 `Start-PairedExchangeTest.ps1`를 재실행하지 말고 아래 명령을 사용합니다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Send-InitialPairSeed.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live -TargetId target01
```

- visible lane에서 사용자가 active면 seed 주입은 `retry-pending`으로 보류됩니다. 기본 경로는 `Send-InitialPairSeedWithRetry.ps1` 자동 재시도이며, `manual_attention_required`가 나오기 전까지 수동 재enqueue를 반복하지 않습니다.
- live router가 오래 떠 있어 최신 설정/sidecar 반영이 의심되면 `router\Restart-RouterForConfig.ps1`로 fresh restart 후 진행합니다. `Run-LiveVisiblePairAcceptance.ps1 -ForceFreshRouter`도 같은 경로를 사용합니다.
- live visible acceptance를 한 번에 검증할 때는 `Run-LiveVisiblePairAcceptance.ps1`를 사용합니다. 이 스크립트는 새/기존 RunRoot, live router mutex, watcher 시작, seed helper, 상태 판정을 한 흐름으로 묶습니다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-LiveVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live_acceptance -PairId pair01 -SeedTargetId target01 -AsJson
```

8. paired watcher 시작

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Watch-PairedExchange.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live
```

9. paired 상태 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-paired-exchange-status.ps1 -RunRoot .\pair-test\run_live
```

통과 기준:
- `forwarded > 0`
- `failures = 0`
- watcher 상태가 기대와 일치

## 운영 원칙

- panel은 `current-session` 기준으로 단계와 버튼을 제어합니다. 패널을 다시 실행한 직후 이전 세션 8창이 남아 있어도 자동으로 `준비 완료`로 승격하지 않습니다.
- 패널 재실행 후 기존 8창이 정상으로 남아 있으면 보드 탭 `기존 8창 재사용`을 먼저 시도합니다.
- 8창 전체가 아니라 일부 complete pair만 살아 있으면 `열린 pair 재사용`을 사용합니다. 이 모드는 complete pair만 현재 session으로 승격하고, inactive target은 실패가 아니라 `out-of-scope`로 취급합니다.
- `기존 8창 재사용` 성공은 아래 3가지를 뜻합니다.
  - 현재 세션 승격 완료
  - binding 현재시각 갱신 완료
  - attach 재실행 완료
- `열린 pair 재사용` 성공은 아래 4가지를 뜻합니다.
  - complete pair만 현재 세션 승격 완료
  - binding/runtime scope가 active pair 기준으로 축소됨
  - attach/visibility 기대 개수가 `2/2`, `4/4`, `6/6`처럼 session scope 기준으로 바뀜
  - inactive pair는 panel에서 `현재 session 범위 밖`으로 차단됨
- `기존 8창 재사용` 실패 시에는 output/마지막 결과의 실패 요약을 먼저 확인하고, 창 상태가 불완전하면 기존 8창을 종료한 뒤 `8창 열기`로 새로 시작합니다.
- `열린 pair 재사용`은 orphan target 1개만 남은 경우에는 성공하지 않습니다. `target01 + target05`처럼 complete pair여야 합니다.
- 운영 기본 순서는 `재사용 먼저 시도 -> 실패 시 8창 새로 열기`입니다. 자동 재사용이나 패널 시작 시 자동 흡수는 현재 표준 절차가 아닙니다.
- shared `bottest-live-visible` lane에서는 ad-hoc 임시 창을 띄우지 않습니다. `BotTestLive-Fresh-*`, `BotTestLive-Surrogate-*`, `BotTestLive-Candidate-*` 창은 금지하고, 반드시 공식 `BotTestLive-Window-01`~`08` 기존 창을 재사용하거나 그 공식 창만 재기동합니다.
- 기본 진입점은 `ensure-targets.ps1`입니다.
- `attach 됨`과 `실제 입력 가능`은 별도 단계로 취급합니다. `check-target-window-visibility.ps1`를 통과하지 못하면 router/manual E2E를 진행하지 않습니다.
- 기존 invisible BotTest 세션과 새 visible 승인 lane이 함께 있으면 `BotTestLive-Window-*` 제목과 `config\settings.bottest-live-visible.psd1` 기준 lane을 사용합니다.
- `start-targets.ps1 -ReplaceExisting`는 예외 경로입니다.
- `-UnsafeForceKillManagedTargets`는 운영 표준 절차에서 제외합니다.
- pair별 임시 중지는 config를 직접 수정하지 않고 `disable-pair.ps1`, `enable-pair.ps1`만 사용합니다.
- unsafe relaunch 시도는 `logs\unsafe-force-kill.log`에서 확인합니다.
- 문제가 생기면 코드 수정 전에 `show-relay-status.ps1`, `show-paired-run-summary.ps1`, `show-paired-exchange-status.ps1` 순서로 확인합니다.
- initial/handoff 문구는 `config\settings.bottest-live-visible.psd1`의 `PairTest.MessageTemplates`, `PairOverrides`, `RoleOverrides`, `TargetOverrides`로 조정합니다.
- 1회성 문구는 고정문구 설정이 아니라 `runtime\one-time-queue\<lane>\<pair>.queue.json`으로 관리합니다.
- 설정/문구/폴더를 한 화면에서 보고 싶으면 `python .\relay_operator_panel.py`를 사용합니다.
- `relay_operator_panel.py`는 source of truth가 아니라 운영 보조 UI입니다. source of truth는 `show-effective-config.ps1 -AsJson`입니다.
- pair 활성 상태 source of truth는 `runtime\pair-activation\bottest-live-visible.json`이며, panel과 실행기는 같은 상태를 읽습니다.
- pair 활성 상태만 빠르게 확인하려면 `show-pair-activation-status.ps1`를 사용합니다.
- `show-effective-config.ps1`의 warning은 review 신호입니다. 실행 하드 게이트는 `check-target-window-visibility.ps1`, `check-headless-exec-readiness.ps1`입니다.
- live router를 다시 올리기 전 inbox에 예전 `*.ready.txt`가 남아 있으면 삭제하지 말고 `quarantine-stale-ready.ps1`로 `_tmp\ready-quarantine\<lane>\<timestamp>` 아래로 먼저 이동합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\quarantine-stale-ready.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

- 오래된 ready만 선별하려면 `-OlderThanMinutes`를 사용합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\quarantine-stale-ready.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -OlderThanMinutes 10 -AsJson
```

- paired runroot 전체 상태를 빠르게 요약하려면 아래 helper를 먼저 실행합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-paired-run-summary.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_acceptance_smoke_20260418d
```

- 이 출력이 `overall=success`이면 상세 root-cause 분석 없이 다음 운영 단계로 넘어가도 됩니다. `overall=failing` 또는 `overall=in-progress`면 그다음에 `show-paired-exchange-status.ps1`, `router.log`, `ahk-debug` 순서로 내려갑니다.
- headless pair transport closure는 active 입력 없이 아래 재사용 acceptance로 닫습니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-PairTransportClosureAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_yyyyMMdd_HHmmss -ReuseExistingRunRoot -PairId pair01 -InitialTargetId target01 -MaxForwardCount 2 -AsJson
```

- shared `bottest-live-visible` lane의 visible acceptance는 조용한 시점이나 별도 검증 lane에서만 active 실행합니다. shared lane에서 새 입력을 넣기 곤란한 시점에는 아래 passive verifier만 돌려 현재 runroot closure 상태를 판정합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Confirm-SharedVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_yyyyMMdd_HHmmss -PairId pair01 -SeedTargetId target01 -AsJson
```

- 이미 `Run-LiveVisiblePairAcceptance.ps1`가 끝난 runroot라면 receipt까지 포함해 아래처럼 엄격하게 재검증합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Confirm-SharedVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_acceptance_smoke_yyyyMMdd_HHmmss -PairId pair01 -SeedTargetId target01 -RequireVisibleReceipt -AsJson
```

- visible acceptance 성공 run은 watcher가 `manual-stop`으로 끝날 수 있습니다. acceptance 스크립트가 완료 후 stop request를 보내기 때문입니다. 반면 headless drill은 보통 `expected-limit`로 끝납니다. 둘 다 forwarded/done/error 기준이 맞으면 정상으로 봅니다.

- panel에서는 1회성 문구를 수정하지 않고, 현재 preview에 어떤 항목이 걸렸는지만 읽기 전용으로 확인합니다.
- panel에서는 preview snapshot JSON 저장, 선택 row의 문구 JSON/TXT preview 저장, target/review 폴더 열기, summary 경로 복사, 선택된 pair의 headless 단일 왕복 드릴, 결과 / 산출물 탭의 target-local artifact check/submit을 지원합니다.
- panel의 `Snapshots` 탭에서는 `_tmp\effective-config*.json` 최근 20개 저장본의 stale/warnings를 함께 보고, snapshot과 selected run root를 바로 열거나 경로를 복사할 수 있습니다.
- panel 상단 `Operator Status`는 현재 실행 상태와 마지막 결과를 보여주고, 작업 중에는 버튼이 잠깁니다.
- panel은 같은 lane에 대해 한 번에 1개 인스턴스만 사용하는 것을 기본 정책으로 둡니다. `_tmp\artifact-source-memory.json`은 원자 저장이지만, 동시 panel 실행 시 마지막 저장값이 우선합니다.
- Windows에서는 `open-relay-operator-panel.vbs` 더블클릭으로 바로 panel을 열 수 있습니다.
- 런처 체인은 `open-relay-operator-panel.vbs -> launch-relay-operator-panel.cmd -> launch-relay-operator-panel.ps1 -> relay_operator_panel.py`입니다.
- CMD/VBS 경로는 panel 프로세스 기동까지 확인했고, 실제 버튼 클릭과 시각 배치는 운영자가 Windows 데스크톱에서 확인합니다.
- pair01 preset 원클릭은 `open-run-pair01-headless-drill.vbs -> open-preset-headless-pair-drill.vbs -> launch-preset-headless-pair-drill.cmd -> run-preset-headless-pair-drill.ps1 -PairId pair01` 경로로 실제 한 번 왕복 성공까지 확인했습니다.
- pair02~04 shortcut도 같은 공통 preset 경로에 `PairId`만 고정해서 사용합니다.
- 특정 pair를 임시로 막으려면 아래처럼 runtime 상태만 바꿉니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\disable-pair.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair02 -Reason "점검 중"
powershell -NoProfile -ExecutionPolicy Bypass -File .\enable-pair.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair02
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-pair-activation-status.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```
- 운영 증거 snapshot은 `_tmp`가 아니라 `evidence\effective-config`에 저장하고, 기본 명령은 `save-effective-config-evidence.ps1`입니다.
- `EvidencePolicy.Recommended=false`이면 운영 증거 snapshot 기본 저장을 하지 않습니다. 꼭 남겨야 하면 `save-effective-config-evidence.ps1 -Force`를 사용합니다.
- warning/evidence 드릴 시나리오는 [OPERATIONS-DRILLS.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-DRILLS.md)를 기준으로 반복합니다.
- `_tmp\rendered-messages`는 임시 preview 보관소로 보고 최근 7일 또는 최근 50개 수준만 유지합니다.
- `runtime\one-time-queue\<lane>\archive`는 queue 감사 기록으로 보고 최근 30일 기준으로 정리합니다.
- `runtime\pair-activation\<lane>.json`는 현재 운영 상태 파일로 보고 archive하지 않고, 만료/불필요 override만 정리합니다.
- `evidence\effective-config`는 승인/이상 run 근거를 우선 보관하고, 일반 evidence는 최근 90일 기준으로 정리합니다.
- `source-outbox\.published`는 자동 publish 감사 기록으로 보고, 현재 활성 run은 건드리지 않고 종료된 오래된 run만 수동 maintenance 대상으로 정리합니다. 기본 정책은 최근 30일 보관입니다.

## live paired-exchange 기준선

2026-04-18 live 기준선은 아래 순서가 실제 WindowsTerminal 8창에서 끝까지 성공한 상태입니다.

성공 예시 run:
- [run_20260418_073552](C:\dev\python\hyukwoo\hyukwoo1\pair-test\bottest-live-visible\run_20260418_073552)

정상 흐름:
1. `target01` seed 발송
2. `target01`이 `source-outbox\summary.txt`, `review.zip`, `publish.ready.json` 생성
3. watcher가 `handoff_target01_to_target05_*.txt` 생성 후 `target05` ready enqueue
4. `target05`가 `source-outbox\summary.txt`, `review.zip`, `publish.ready.json` 생성
5. watcher가 `handoff_target05_to_target01_*.txt` 생성 후 `target01` return enqueue
6. `target01`이 다시 `source-outbox`를 갱신하고 최종 `publish.ready.json` 생성

정상 확인 포인트:
- `Send-InitialPairSeedWithRetry.ps1` 결과가 `FinalState=publish-detected`
- `router.log`에 `submitModes=enter>ctrl_enter`, `payloadBytes=...`, `textSettleMs=...`
- AHK debug에 `terminal_settle`, `submit_refocus_restored`, `submit_complete`
- `messages\handoff_target01_to_target05_*.txt`, `messages\handoff_target05_to_target01_*.txt` 둘 다 존재
- `processed\bottest-live-visible\target05__*.ready.txt`, `target01__*.ready.txt`가 순서대로 남음
- 최종적으로 `pair01\target01\source-outbox`와 `pair01\target05\source-outbox`에 모두 `summary.txt`, `review.zip`, `publish.ready.json`이 존재

이번 기준선에서 확인된 주의점:
- `PairTest.DefaultSeedWorkRepoRoot`와 review zip 자동 탐색 기본값이 비어 있으면 fresh seed가 실제 작업을 시작하지 못할 수 있습니다.
- submit은 typing 직후가 아니라 payload 크기 기반 settle 이후에 들어가야 하며, BlueStacks 같은 외부 앱이 포커스를 뺏어도 `submit_refocus_restored`가 찍히는지 봐야 합니다.
- handoff 문구는 보내는 쪽이 아니라 **받는 쪽 target 기준** role/target override를 써야 합니다. `target05` handoff에 `당신은 하단 창입니다`, `target05는 ... 중간 왕복`이 들어가야 정상입니다.

## live acceptance smoke 기준선

2026-04-18에는 자동 acceptance smoke도 실제 live 창 기준으로 `completed / roundtrip-confirmed`까지 성공했습니다.

성공 예시 run:
- [run_acceptance_smoke_20260418d](C:\dev\python\hyukwoo\hyukwoo1\pair-test\bottest-live-visible\run_acceptance_smoke_20260418d)

권장 실행 명령:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-LiveVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_acceptance_smoke_yyyyMMdd_HHmmss -PairId pair01 -SeedTargetId target01 -WaitForFirstHandoffSeconds 300 -WaitForRoundtripSeconds 1200 -WaitForWatcherSeconds 30 -WaitForRouterSeconds 20 -SeedWaitForPublishSeconds 240 -AsJson
```

자동 acceptance 합격 기준:
- receipt `.state\live-acceptance-result.json`의 `Stage=completed`
- `Outcome.AcceptanceState=roundtrip-confirmed`
- `tests\Show-PairedExchangeStatus.ps1 -AsJson` 기준 `Counts.ForwardedStateCount=2`, `Counts.DonePresentCount=2`, `Counts.ErrorPresentCount=0`
- visible worker run에서는 `Seed.FinalState=submit-unconfirmed`가 남아도, 이후 `summary/review.zip/publish.ready.json`과 `ForwardedStateCount`가 채워지면 성공으로 본다
- `tests\Confirm-SharedVisiblePairAcceptance.ps1 -RequireVisibleReceipt`가 `overall=success`를 반환
- 이 단계는 `2-forward acceptance` 기준입니다. `4-forward closeout`과 같은 의미로 섞지 않습니다.
- clean preflight recheck가 마지막 receipt current state를 `preflight-passed`로 덮어써도, `show-paired-run-summary.ps1`와 confirm 계열은 `PhaseHistory`의 마지막 성공 acceptance를 effective result로 읽어야 합니다.

자동 acceptance 실패 시 우선 확인:
- receipt의 `Stage`, `Outcome.AcceptanceReason`
- `router.log`
- `logs\<lane>\ahk-debug\<target>\*.log`
- runroot 아래 `.state\source-outbox-status.json`

빠른 운영 요약은 아래 helper로 바로 봅니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-paired-run-summary.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_acceptance_smoke_20260418d
```

이 helper는 한 줄 요약과 함께 `acceptance`, `watcher`, `counts`, `target01/target05` 상태를 같은 기준으로 묶어 보여줍니다.

shared lane에서 active acceptance를 새로 돌릴 수 없는 시점이면:
- `Run-LiveVisiblePairAcceptance.ps1`는 실행하지 않습니다.
- `Confirm-SharedVisiblePairAcceptance.ps1` 결과만 근거로 `shared visible deferred` 상태를 기록합니다.
- 이 상태에서는 headless closure와 isolated smoke만 닫힌 것으로 판단하고, visible receipt 완료로 오해하지 않습니다.

visible pair 자동화 정식 경로:
- `visible worker queue -> Invoke-CodexExecTurn -> source-outbox publish -> watcher handoff`
- `router/AHK typed REPL`은 manual smoke / fallback 전용으로만 사용합니다.

shared lane 표준 절차:
1. `visible\Cleanup-VisibleWorkerQueue.ps1` dry-run
2. 같은 cleanup actual apply
3. `tests\Run-LiveVisiblePairAcceptance.ps1 -PreflightOnly`
4. `tests\Run-LiveVisiblePairAcceptance.ps1` active acceptance
5. cleanup apply
6. `tests\Run-LiveVisiblePairAcceptance.ps1 -PreflightOnly` clean pass 재확인

2026-04-25 successful shared visible closeout 기준선:
- example run root: [run_shared_visible_closeout_20260425_021309](C:\dev\python\hyukwoo\hyukwoo1\pair-test\bottest-live-visible\run_shared_visible_closeout_20260425_021309)
- final summary: `overall=success acceptance=roundtrip-confirmed stage=completed`
- `tests\Confirm-SharedVisiblePairAcceptance.ps1 -RequireVisibleReceipt`도 같은 RunRoot에서 `overall=success`
- final lane check는 `visible\Cleanup-VisibleWorkerQueue.ps1 -AsJson` 기준 `Summary.ProtectedRunCount=0`

baseline recheck 명령:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-paired-run-summary.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_shared_visible_closeout_20260425_021309
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Confirm-SharedVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_shared_visible_closeout_20260425_021309 -PairId pair01 -SeedTargetId target01 -RequireVisibleReceipt -AsJson
powershell -NoProfile -ExecutionPolicy Bypass -File .\visible\Cleanup-VisibleWorkerQueue.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -AsJson
```

운영 해석 고정:
- `show-paired-run-summary.ps1`와 confirm 계열의 effective acceptance는 latest current receipt가 아니라 `PhaseHistory`의 마지막 성공 acceptance를 우선합니다.
- clean preflight recheck는 shared lane이 clean으로 돌아왔는지 확인하는 단계이지, 직전 성공 acceptance를 무효화하는 단계가 아닙니다.
- reopen은 success closeout 재현 실패, `PhaseHistory` precedence 붕괴, `ProtectedRunCount=0`인데 confirm 실패, foreign protected run 반복 병목 때만 검토합니다.

baseline success 이후 shared lane clean recovery 규칙:
- baseline success run이 이미 있으면, 이후 shared lane이 foreign active run 때문에 다시 더러워져도 active acceptance를 새로 재실행하지 않습니다.
- 먼저 foreign watcher/worker가 terminal state가 될 때까지 기다립니다.
- 그 전에는 foreign active run을 강제로 reclaim/stop 하지 않습니다.
- watcher 종료 후 `visible\Cleanup-VisibleWorkerQueue.ps1 -AsJson`로 `Summary.ProtectedRunCount=0`인지 먼저 확인합니다.
- reclaim 대상이 있을 때만 cleanup apply를 실행하고, 마지막에는 새 recheck RunRoot로 `tests\Run-LiveVisiblePairAcceptance.ps1 -PreflightOnly` clean pass만 다시 남깁니다.
- 이 단계의 목적은 새 acceptance가 아니라 `현재 시점 shared lane clean 복귀 확인`입니다.

shared lane 창 사용 규칙:
- active acceptance는 공식 운영 `BotTestLive-Window-01`~`08`만 사용합니다.
- 가능한 경우 기존 8창을 재사용합니다.
- 창 상태가 나쁘면 공식 운영 창만 재기동합니다.
- `Fresh/Surrogate/Candidate` 같은 ad-hoc 창이 보이면 active acceptance를 시작하지 않습니다.

연속 왕복 확인 절차:
- `target01` seed 1건만 넣고 `-WatcherMaxForwardCount 4 -KeepWatcherRunning`으로 시작합니다.
- 성공 기준은 `Counts.ForwardedStateCount=4`, `Counts.DonePresentCount=2`, `Counts.ErrorPresentCount=0` 입니다.
- `Run-LiveVisiblePairAcceptance.ps1` receipt에서는 `Outcome`가 acceptance 결과, `Closeout`가 연속 왕복 진행/충족 여부를 따로 나타냅니다.
- `ConfiguredMaxForwardCount=4` run은 watcher가 4-forward 도달 후 멈추거나, 확인 후 수동 stop request로 정리합니다.

## source-outbox artifact acceptance

이 절차는 새 RunRoot 기준으로만 닫습니다. 예전 RunRoot는 wrapper/fallback 호환 확인 대상으로만 봅니다.

1. 새 RunRoot 준비

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-PairedExchangeTest.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_panel_acceptance -IncludePairId pair01
```

확인 포인트:
- `pair01\target01`, `pair01\target05` 아래 `check-artifact.*`, `submit-artifact.*` 생성
- `request.json`, `instructions.txt`, `manifest.json`에 `SourceOutboxPath`, `PublishReadyPath`, `.published` archive와 recovery wrapper 경로 포함

2. watcher 시작

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Watch-PairedExchange.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_panel_acceptance
```

3. target01 source-outbox publish 확인

확인 포인트:
- `pair01\target01\source-outbox\summary.txt` 생성
- `pair01\target01\source-outbox\review.zip` 생성
- 마지막에 `pair01\target01\source-outbox\publish.ready.json` 생성
- watcher가 target01 contract folder에 `summary.txt`, `reviewfile\*.zip`, `done.json`, `result.json`을 자동 생성
- `pair01\target01\source-outbox\.published\*.ready.json` archive 생성
- `show-paired-exchange-status.ps1 -AsJson`에서 target01 `LatestState`가 `ready-to-forward` 또는 `forwarded`로 진행
- 첫 acceptance는 target05를 동시에 publish하지 않고, `target01 -> target05` 순서를 먼저 확인

4. panel / recovery 확인

```powershell
python .\relay_operator_panel.py
```

확인 포인트:
- 결과 / 산출물 탭에서 새 RunRoot target row 선택
- `SourceOutboxPath`, `PublishReadyPath`, `.published` 경로가 보임
- `target check 실행`이 target-local wrapper 경로로 표시됨
- panel/wrapper submit은 기본 흐름이 아니라 recovery 경로로만 사용함
- stale RunRoot 또는 wrapper missing 상황에서는 강한 warning badge 표시
- legacy fallback submit은 추가 확인 창이 한 번 더 뜸
- 같은 target 재submit 직후에는 재확인 창이 뜸

5. source-memory 복원 확인

확인 포인트:
- panel에서 source summary/zip 경로를 한 번 입력
- panel 종료 후 재실행
- `_tmp\artifact-source-memory.json`이 남아 있고, 같은 target 선택 시 최근 source 경로가 다시 제안됨

legacy RunRoot 복구가 필요하면:

- 예전 RunRoot는 wrapper 생성 이전 계약일 수 있으므로 panel local wrapper를 기대하지 않습니다.
- repo packaging zip은 source artifact일 뿐입니다.
- 이 경우 root `check-paired-exchange-artifact.ps1` / `import-paired-exchange-artifact.ps1`로 target contract에 직접 submit한 뒤 watcher 상태를 다시 확인합니다.

## warning 해석

- `Decision=none`
  진행 가능 상태입니다.
- `Decision=review`
  사람이 확인해야 하는 상태입니다. evidence snapshot 기본 저장은 하지 않습니다.
- `Decision=block`
  현재는 기본 경로에 없지만, 추가되면 절차를 중단해야 합니다.

## BotTest Visible Lane

1. 새 visible 8창 기동

```powershell
python C:\Users\USER\s_8windows_left_monitor_codex_visible.py
```

2. binding attach

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\attach-targets-from-bindings.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

3. visibility 게이트

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-target-window-visibility.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

통과 기준:
- `Injectable: ok=8 fail=0`
- exit code `0`

4. 그 다음 승인 절차

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\router.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Manual-E2E-AllTargets.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

## Headless Exec 실험 절차

1. pair run 준비

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-PairedExchangeTest.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01 -IncludePairId pair01
```

2. headless readiness

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-headless-exec-readiness.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01
```

통과 기준:
- `Issues: (none)`
- `codex exec --help` 정상
- `request.json` 존재

3. 단일 target dry-run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\invoke-codex-exec-turn.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01 -TargetId target01 -DryRun
```

4. 실제 turn 실행은 pair별 mutex를 유지한 상태에서 한 쌍씩 확장

## Headless pair01 자동 왕복

운영 패널 원클릭:

- `python .\relay_operator_panel.py`
- `Pair=pair01`
- `Run Selected Pair Drill`

pair01 preset 원클릭:

- panel 버튼: `pair01 Preset Drill`
- VBS 더블클릭: `open-run-pair01-headless-drill.vbs`

generic core CLI:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-headless-pair-drill.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01
```

generic preset CLI/VBS:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-preset-headless-pair-drill.ps1 -PairId pair01
cmd /c .\launch-preset-headless-pair-drill.cmd pair01
wscript .\open-preset-headless-pair-drill.vbs pair01
```

pair01 shortcut CLI/VBS:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-pair01-headless-drill.ps1
cmd /c .\launch-run-pair01-headless-drill.cmd
```

1. 초기 target01 실행

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-PairedExchangeTest.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01_auto -IncludePairId pair01 -SendInitialMessages -InitialTargetId target01 -UseHeadlessDispatch
```

2. watcher가 두 번만 자동 forward

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Watch-PairedExchange.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01_auto -UseHeadlessDispatch -MaxForwardCount 2
```

통과 기준:
- initial `target01` 완료
- watcher 로그에 `forwarded target01 -> target05`, `forwarded target05 -> target01`
- `done.json` 두 target 모두 존재
- `error.json` 없음

## Effective Config 계약 점검

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-show-effective-config.ps1
```

통과 기준:
- `SchemaVersion`, `GeneratedAt`, `Warnings`, `ConfigHash` 존재
- `WarningDetails`, `WarningSummary`, `RequestedFilters`, `SelectedRunRootIsStale` 존재
- `EvidencePolicy`, `OperationalPolicy` 존재
- requested / latest-existing / fallback / manifest 경로 검증 통과
- `Mode both|initial|handoff`별 preview 구조 검증 통과
