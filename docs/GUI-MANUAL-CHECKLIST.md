# Relay Operator Panel GUI Manual Checklist

## 목적

정적 테스트와 별도로, 운영자가 실제 클릭 흐름에서 바로 체감하는 UI/UX 회귀를 빠르게 확인하기 위한 수동 체크리스트다.

## 사전 조건

- `relay_operator_panel.py`가 실행된다.
- 기본 config와 preview row가 정상 로드된다.
- `홈`, `8창 보드`, `Pair 설정`, `8 Cell Autoloop`, `문구 편집`, `결과 / 산출물` 탭이 보인다.

## 핵심 시나리오

### 1. 보드에서 편집기로 문맥 전환

1. `8창 보드` 탭에서 아무 target 셀을 클릭한다.
2. `문구 편집` 탭으로 자동 전환되는지 확인한다.
3. `Pair`, `Target`, 편집 scope가 선택 target 기준으로 바뀌는지 확인한다.
4. 편집 문맥 상단의 `현재 편집 중` / `적용 범위`가 선택 target 기준으로 갱신되는지 확인한다.
5. 편집기 우측 compact 탭 `현재`, `적용`, `Initial`, `Handoff`, `전달문`, `경로`와 상단 `오른쪽 탭 안내`가 선택한 target 기준으로 함께 갱신되는지 확인한다.

### 2. preview freshness 가드

1. 블록 하나를 수정하되 아직 `미리보기 갱신`은 누르지 않는다.
2. 상단 상태 문구에 preview stale 경고가 보이는지 확인한다.
3. `저장 + 새로고침`을 누른다.
4. 저장 확인창에 `preview freshness: stale` 문구와 영향 요약이 함께 나오는지 확인한다.
5. 저장을 취소한 뒤 `미리보기 갱신`을 누른다.
6. 다시 저장하면 `preview freshness: 최신`으로 바뀌는지 확인한다.

### 3. 블록 검색 / changed only / reorder 잠금

1. 검색창에 일부 텍스트를 입력한다.
2. 블록 목록이 필터링되고 `블록 표시: n/m` 상태가 맞게 바뀌는지 확인한다.
3. `changed only`를 켠다.
4. 변경된 블록만 남고 앞에 `*` 표시가 붙는지 확인한다.
5. 필터가 켜진 상태에서 위/아래 이동 또는 드래그를 시도한다.
6. reorder 차단 경고가 뜨는지 확인한다.
7. `필터 해제` 후 같은 동작이 정상 동작하는지 확인한다.

### 4. 영향 요약

1. pair/target/fixed suffix 중 서로 다른 scope를 2개 이상 수정한다.
2. `영향 요약` 버튼을 누른다.
3. 변경 항목 수, 영향 pair 수, 영향 target 수, preview 문맥이 기대와 맞는지 확인한다.
4. `Diff` 탭에 영향 요약과 diff가 함께 보이는지 확인한다.

### 5. 백업 히스토리 / diff

1. 설정을 한 번 저장한다.
2. `백업` 탭에서 최신 백업이 리스트에 보이는지 확인한다.
3. 백업을 선택했을 때 경로, 수정 시각, 크기가 표시되는지 확인한다.
4. `현재 저장본과 diff`를 눌러 diff 탭으로 이동하는지 확인한다.
5. `현재 편집본과 diff`도 동일하게 동작하는지 확인한다.
6. `백업 경로 복사`가 정상 동작하는지 확인한다.

### 6. 저장 / 롤백

1. 블록 추가 또는 순서 변경 후 저장한다.
2. 저장 후 preview와 editor 상태가 초기화되고 최신 config 기준으로 다시 로드되는지 확인한다.
3. `마지막 백업 롤백`을 눌러 바로 이전 상태로 복원되는지 확인한다.
4. 롤백 후 preview, diff, backup 목록이 일관되게 갱신되는지 확인한다.

### 7. 패널 재실행 후 기존 8창 재사용

1. 기존 8창을 유지한 채 패널을 다시 실행한다.
2. 홈 단계가 자동 완료가 아니라 현재 세션 기준 대기/이전 세션으로 보이는지 확인한다.
3. 보드 탭 `기존 8창 재사용`을 누른다.
4. 성공 시 output에 `현재 세션 승격`, `binding 현재시각 갱신 완료`, `attach 재실행 완료`가 함께 보이는지 확인한다.
5. 성공 직후 `붙이기`, `입력 점검`, `Pair 실행 준비`가 current-session 기준으로 정상 승격되는지 확인한다.

### 8. 부분 재사용(pair 기준) 확인

1. 예를 들어 `pair01`만 남기고 나머지 pair 창을 닫은 상태에서 패널을 연다.
2. 보드 탭 `열린 pair 재사용`을 누른다.
3. output에 `ReusedPairs: 1`, `ReusedTargets: 2/2 (cfg 8)`, `ActivePairs: pair01`가 보이는지 확인한다.
4. 홈/보드 카드의 attach, visibility 값이 `2/2` 기준으로 보이는지 확인한다.
5. 현재 선택 pair가 inactive였으면 첫 active pair로 자동 이동하는지 확인한다.

### 9. 기존 8창 재사용 실패 이유 노출

1. 일부 창을 닫거나 binding과 맞지 않게 만든 상태에서 패널을 연다.
2. 보드 탭 `기존 8창 재사용`을 누른다.
3. 첫 에러 문구, `마지막 결과`, output 영역에 실패 이유 요약이 일관되게 보이는지 확인한다.
4. 실패 후에는 `8창 열기`로 다시 시작하는 운영 경로가 혼동 없이 이해되는지 확인한다.

### 9-1. 8 Cell Autoloop 선택 target 흐름 확인

1. `8 Cell Autoloop` 탭 상단에 `공식 8창 재사용 확인 -> 실행할 target 선택 -> Enabled + publish-ready 켜기 -> 선택 target RunRoot 준비 -> 독립셀 감지 시작 -> 시작문 복사` 순서가 고정 표시되는지 확인한다.
2. target 카드에서 실행할 target만 `선택`하고, 기본 버튼 영역에 `선택 target만 새 RunRoot`, `선택 target publish-ready 켜고 RunRoot 준비`, `독립셀 감지 시작/재시작`이 먼저 보이는지 확인한다.
3. `전체 enabled target 새 RunRoot`는 `고급/전체 실행` 영역에 있고, 누르면 포함 target 목록 확인창이 먼저 뜨는지 확인한다.
4. 상단 큰 배지에 `감지 상태`, `마지막 sweep`, `포함 target`, `queue / waiting-output / failed`가 한 줄로 보이는지 확인한다.
5. RunRoot 준비, publish-ready 재검사, 시작문 복사, pause/resume/stop 버튼 아래에 각각 가능/차단 사유가 보이는지 확인한다.
6. target 카드의 `{targetXX} 시작문 복사` 버튼으로 선택 target과 복사 대상이 같은 카드에서 이어지는지 확인한다.
7. RunRoot 준비 완료 output에 `이번 RunRoot 포함 target`, `publish-ready`, `감지 시작 가능`, `SourceOutbox`, `QueueRoot` 요약이 표시되는지 확인한다.
8. 독립셀 감지기가 이미 `running`/fresh heartbeat 상태일 때 `독립셀 감지 시작/재시작`을 다시 눌러도 실패로 보이지 않고 `Result: already-running`, `Idempotent: True`, `ActiveConfirmed: True`가 표시되는지 확인한다.
9. `WatcherMutexHeld: True`가 보이면 기동 중 mutex 충돌 상태로 해석하고, `ActiveConfirmed: True`가 같이 붙은 경우만 이미 active로 판정한다. `ActiveConfirmed: False`이면 heartbeat 확인 대기 또는 stderr/status 확인 대상으로 본다.
10. 선택 target 카드에서 runtime 배지가 `targetXX 3번째 진행 중 / 2/5 완료 / 남은 3`처럼 현재 시도 번호, 완료/최대 cycle, 남은 횟수를 현재 RunRoot 기준으로 즉시 보여주는지 확인한다.
11. 선택 target 카드에서 `MaxCycleCount 도달`, `산출물 준비됨/누락` 상태가 현재 RunRoot 기준으로 즉시 읽히는지 확인한다.
12. 각 target 카드 runtime 영역의 `요약:` 줄이 현재 진행, 추가 가능 여부, 산출물 준비 수, ready 재검사 가능 여부를 compact 상태에서도 보여주는지 확인한다.
13. `카드 상세 펼치기/접기` 토글이 `추가 상태`, `산출물 상태`, `ready 재검사 상태`, `실효값 상세`를 한 번에 접고 펼치는지 확인하고, 패널 재시작 후 마지막 토글 상태가 복원되는지 확인한다.
14. 선택 target의 산출물 영역에서 `source-outbox 열기`, `summary.txt 열기`, `review.zip 열기`, `publish.ready.json 열기` 버튼이 실제 선택 target 경로를 가리키는지 확인한다.
15. MaxCycleCount 도달 후 같은 RunRoot를 이어갈 때 각 target 카드 안에 추가 횟수 입력칸, `targetXX 추가 N회`, `targetXX 추가 N회+감지` 버튼이 보이고, limit에 도달한 카드만 활성화되는지 확인한다.
16. 각 target 카드의 `추가 상태` 행이 limit 도달 target에는 `권장 - targetXX 추가 N회+감지`와 증가 전/후 max cycle을 표시하고, 진행 중인 target에는 현재 cycle/남은 횟수와 비활성 사유를 표시하는지 확인한다.
17. 상단 공통 버튼은 `선택 target 추가 N회 이어가기`, `선택 target 추가 N회+감지 시작`처럼 선택 target 기준임이 문구로 구분되는지 확인한다.
18. 카드별 추가 진행 후 output에 해당 target의 증가 전/후 MaxCycleCount와 남은 cycle이 표시되는지 확인한다.
19. target01 카드에는 3회, target02 카드에는 7회처럼 서로 다른 추가 횟수를 넣었을 때 각 카드 버튼 라벨과 실행 output이 해당 값을 따르는지 확인한다.
20. 각 target 카드의 `outbox`, `summary`, `zip`, `ready` 버튼이 해당 target의 source-outbox / summary.txt / review.zip / publish.ready.json 경로만 여는지 확인한다.
21. 각 산출물 버튼 hover 설명이 target id, 파일/폴더 종류, 비활성 의미를 보여주는지 확인한다.
22. 각 target 카드의 `산출물 상태` 행이 `summary=파일 없음`, `review.zip=있음`, `publish.ready=파일 없음`처럼 버튼 비활성 사유를 파일별로 보여주는지 확인한다.
23. 각 target 카드의 `targetXX ready 재검사` 버튼이 publish-ready trigger가 켜진 target에서만 활성화되고, 실행 output/status에 해당 target id가 표시되는지 확인한다.
24. 각 target 카드의 `ready 재검사 상태` 행이 `가능`, `publish-ready trigger가 꺼져 있습니다`, `manifest target이 없습니다`, `RunRoot가 필요합니다` 같은 버튼 비활성 사유를 target별로 보여주는지 확인한다.
25. 전역 `전체 publish.ready 1회 재검사`는 전체 sweep이고, 카드별 `targetXX ready 재검사`는 `-Targets targetXX` scope임이 문구로 구분되는지 확인한다.
26. `일시정지`, `재개`, `정지` 버튼은 `전체 감지기 일시정지`, `전체 감지기 재개`, `전체 감지기 정지`처럼 target별 제어가 아님이 보이는지 확인한다.
27. `targetXX 추가 N회+감지`가 watcher start 단계에서 실패했을 때는 `부분 완료` 안내가 표시되고, “추가 N회를 다시 누르지 말고 `독립셀 감지 시작/재시작`만 다시 시도”해야 한다는 문구가 보이는지 확인한다.
28. 완전히 새로 시작할 경우에는 `선택 target만 새 RunRoot`를 누른 뒤 초기 시작문을 다시 submit해야 한다는 안내가 `추가 N회` 흐름과 분리되어 보이는지 확인한다.

### 10. live pair01 왕복 기준선 확인

1. `새 RunRoot 준비` 후 `target01` seed를 발송한다.
2. `target01` `source-outbox`에 `summary.txt`, `review.zip`, `publish.ready.json`이 순서대로 생기는지 확인한다.
3. Pair watcher 실행 후 `messages\handoff_target01_to_target05_*.txt`가 생기고, 그 본문에 `당신은 하단 창입니다.`, `target05는 target01이 만든 산출물을 이어받아 중간 왕복을 수행합니다.`가 보이는지 확인한다.
4. `target05` `source-outbox`에도 같은 3개 파일이 생기는지 확인한다.
5. Pair watcher를 한 번 더 실행해 `messages\handoff_target05_to_target01_*.txt`가 생기고, `target01` `source-outbox`가 다시 갱신되는지 확인한다.

### 11. live acceptance smoke 결과 확인

1. shared `bottest-live-visible` lane에서 active acceptance를 돌릴 때는 먼저 조용한 시점인지 확인한다. 이미 다른 입력 흐름이 돌고 있으면 active acceptance를 새로 시작하지 않는다.
2. active acceptance를 실제로 돌릴 수 있는 시점이면 먼저 `visible\Cleanup-VisibleWorkerQueue.ps1` dry-run과 actual apply를 실행하고, 이어서 `tests\Run-LiveVisiblePairAcceptance.ps1 -PreflightOnly`가 clean pass인지 확인한다. cleanup에서 여러 target을 지정할 때는 `-TargetId target04,target08`처럼 쉼표로 묶어 넘기고, `-TargetId target04 target08` 공백형은 쓰지 않는다.
3. clean pass가 확인되면 CLI에서 `tests\Run-LiveVisiblePairAcceptance.ps1`를 새 RunRoot로 실행한다.
4. 실행 후에는 `tests\Confirm-SharedVisiblePairAcceptance.ps1 -RequireVisibleReceipt`로 같은 RunRoot를 재검증한다.
5. `.state\live-acceptance-result.json`의 `Stage=completed`, `Outcome.AcceptanceState=roundtrip-confirmed`를 확인한다.
6. `tests\Show-PairedExchangeStatus.ps1 -AsJson` 기준 `Counts.ForwardedStateCount=2`, `Counts.DonePresentCount=2`, `Counts.ErrorPresentCount=0`인지 확인한다.
7. visible worker run에서는 `Seed.FinalState=submit-unconfirmed`가 남아도, 최종 `summary/review.zip/publish.ready.json`과 `ForwardedStateCount`가 채워졌으면 성공으로 본다.
8. 여기까지는 `2-forward acceptance`다. `4-forward closeout`과 혼동하지 않는다.
9. 실패 시에는 receipt의 `Outcome.AcceptanceReason`부터 보고, 이어서 `worker status`, `.state\source-outbox-status.json`, `headless-dispatch stderr` 순으로 확인한다.
10. active acceptance가 끝나면 다시 cleanup apply 후 `-PreflightOnly` clean pass로 lane이 비었는지 재확인한다.
11. active acceptance를 새로 돌릴 수 없는 shared 시점이면, 기존 successful RunRoot에 대해서는 `tests\Confirm-SharedVisiblePairAcceptance.ps1`만 실행해서 passive 판정만 확인한다. 이 경우 visible acceptance 완료로 간주하지 않고 `shared visible deferred`로 기록한다.
12. shared lane active acceptance에서는 공식 `BotTestLive-Window-01`~`08`만 사용한다. `Fresh-*`, `Surrogate-*`, `Candidate-*` 같은 ad-hoc 임시 창이 보이면 먼저 정리하고 시작한다.
13. clean preflight recheck 뒤 latest receipt current state가 `preflight-passed`로 보이더라도, runroot summary와 receipt-required confirm은 `PhaseHistory`의 마지막 성공 acceptance를 읽어 계속 `overall=success`를 유지해야 한다.

### 11-1. visible pair 정식 경로

1. visible pair 자동화의 정식 경로는 `visible worker queue -> Invoke-CodexExecTurn -> source-outbox publish -> Pair watcher handoff` 입니다.
2. `router/AHK typed REPL` 경로는 manual smoke / fallback 전용으로만 사용합니다.

### 11-2. 연속 왕복 확인

1. `target01` seed 1건만 넣고, CLI에서 `tests\Run-LiveVisiblePairAcceptance.ps1 -WatcherMaxForwardCount 4 -KeepWatcherRunning`으로 실행한다.
2. acceptance receipt가 `roundtrip-confirmed`를 반환한 뒤에도 Pair watcher는 계속 돌 수 있으므로, `tests\Show-PairedExchangeStatus.ps1 -AsJson`로 `Counts.ForwardedStateCount=4`를 확인한다.
3. 연속 왕복 성공 기준은 `Counts.ForwardedStateCount=4`, `Counts.DonePresentCount=2`, `Counts.ErrorPresentCount=0` 이다.
4. receipt에서는 `Outcome`가 acceptance 결과, `Closeout`가 연속 왕복 결과를 따로 보여준다.
5. 확인 후에는 cleanup apply와 `-PreflightOnly`로 lane clean pass를 다시 남긴다.

### 12. runroot summary helper 빠른 점검

1. panel 홈 탭 또는 운영 탭의 `runroot 요약` 버튼을 누르거나, CLI에서 `show-paired-run-summary.ps1`를 같은 RunRoot로 실행한다.
2. `RunRoot 준비` 또는 `준비 전체 실행` 직후 output에 `[runroot 요약]` 블록이 자동으로 따라붙는지 확인한다.
3. 첫 줄이 `overall=success acceptance=roundtrip-confirmed stage=completed` 형태인지 확인한다.
4. `Targets:` 아래 `target01(top)`, `target05(bottom)` 둘 다 `outbox=imported`와 `summary=True`, `zip=1` 이상으로 보이는지 확인한다.
5. 같은 RunRoot의 `.state\important-summary.txt` 와 `.state\important-summary.json` 이 함께 생성되는지 확인한다.
6. panel의 `important-summary 열기` 버튼으로 같은 파일이 바로 열리는지 확인한다.
7. `important-summary.txt` 에 현재 payload preview, contract 경로, `summary.txt / review.zip / publish.ready.json` 생성 여부, 최신 prepare/AHK/router 로그 경로가 같이 보이는지 확인한다.
8. 같은 파일 상단 `freshness` 블록에 `NewestObservedSignalAt`, `SignalAgeSeconds`, `StaleSummary`뿐 아니라 `NewestProgressSignalAt`, `ProgressSignalAgeSeconds`, `ProgressStale`도 같이 보여 "최근 흔적"과 "실제 relay 진전"을 구분해서 읽을 수 있는지 확인한다.
즉 `StaleSummary=false` 이고 `ProgressStale=true` 면 "요약은 최신이지만 실제 relay 진전은 오래 멈춘 상태"로 읽는다.
9. 같은 파일 상단 `operator-focus` 블록에 `AttentionLevel`, `CurrentBottleneck`, `NextExpectedStep`, `RecommendedAction`가 보여 현재 병목과 다음 확인 포인트를 먼저 읽을 수 있는지 확인한다.
10. 같은 파일의 `recent-events` 블록에 최근 핵심 이벤트 5~8줄이 보여 방금 어디까지 진행됐는지 빠르게 읽히는지 확인한다. JSON 요약에서는 각 event에 `EventClass`, `PairId`, `TargetId`, `IsProgressSignal`가 같이 남는지도 확인한다.
11. `overall=failing` 또는 `overall=in-progress`면 그다음에만 `show-paired-exchange-status.ps1`와 로그 상세 확인으로 내려간다.

summary 회귀만 한 번에 다시 돌리려면 아래 wrapper를 사용한다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-ShowPairedRunSummaryRegression.ps1
```

### 13. 최종 전달문 / 경로 요약 확인

1. `문구 편집` 탭 우측 `전달문`에서 현재 target 기준 `Initial` / `Handoff` 완성본이 실제 preview와 같은지 확인한다.
2. 같은 위치의 `경로 요약`에서 `내 작업 폴더`, `상대 작업 폴더`, `검토 입력 후보 경로`, `생성 출력 경로`가 기대한 target/pair 기준으로 나오는지 확인한다.
3. 새 RunRoot preview에서는 아직 파일이 없어도 `검토 입력 후보 경로`와 `생성 출력 경로`가 미리 보이는지 확인한다.
4. 필요하면 `완성본 복사`, `경로 요약 복사`, `내 폴더 열기`, `상대 폴더 열기` 버튼이 현재 선택 target 기준으로 동작하는지 확인한다.
5. 왼쪽 고정문구 영역의 안내가 `기본 고정문구`와 `Target 고정문구`의 적용 범위를 구분해서 보여주는지 확인한다.

## 합격 기준

- 편집기와 보드 문맥이 서로 어긋나지 않는다.
- preview stale 상태를 저장 전에 명확히 인지할 수 있다.
- 필터 중 reorder가 차단되고, 필터 해제 후 정상 편집이 가능하다.
- 영향 요약과 backup diff가 실제 변경 범위와 일치한다.
- 저장/롤백 후 UI 상태가 즉시 일관되게 다시 그려진다.
- 패널 재실행 후 기존 8창 재사용 성공/실패 흐름이 운영자에게 직접 읽히는 문구로 설명된다.
- `열린 pair 재사용`에서는 active pair만 `2/2`, `4/4`, `6/6`처럼 session scope 기준으로 보인다.
- live pair01 왕복에서는 `target01 -> target05 -> target01` handoff 파일과 양쪽 `source-outbox` publish가 모두 확인된다.
- live acceptance smoke에서는 receipt 기준으로 `completed / roundtrip-confirmed`가 확인된다.
- clean preflight recheck 뒤에도 runroot summary와 receipt-required confirm이 `PhaseHistory` precedence 덕분에 계속 `overall=success`를 유지한다.
- shared lane에서 active acceptance를 생략한 경우에는 `tests\Confirm-SharedVisiblePairAcceptance.ps1` 결과가 `overall=success`, `mode=passive-runroot-verification`으로만 남고, visible receipt 요구는 deferred로 기록된다.
- runroot summary helper에서도 동일 runroot가 `overall=success`로 요약된다.
