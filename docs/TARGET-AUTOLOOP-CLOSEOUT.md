# Target Autoloop Closeout

## Scope Freeze

`target-autoloop` closeout 단계에서는 새 기능 추가를 중지한다.

허용 변경:
- selection/copy/export/status helper 분리
- 작은 UI primitive 정리
- 버튼 섹션 분리
- disabled/guard/warning 보강
- 회귀 테스트 추가
- 운영 문서 갱신

금지 변경:
- Pair watcher와 독립셀 감지기 공통 state machine 도입
- pair roundtrip/top-bottom 의미와 target queue/cycle/trigger 의미 공통화
- live acceptance 직전 대형 UI framework/base class 도입
- 기존 PowerShell 계약 field 이름 변경

## Operator Flow

### 기본 운영 순서

1. `Config에서 다시 읽기`
2. `실효 경로 새로고침`
3. `target 설정 저장 + 새로고침`
4. `matrix 복사` 또는 `matrix JSON 저장`
5. `Seed Composer`에서 시작문 복사 또는 초기 입력 큐잉
6. status/proof/route doctor로 결과 확인

### Selection Snapshot 순서

1. `snapshot 상태`
2. `snapshot 요약 복사` 또는 `현재 selection JSON 복사`
3. 필요 시 `selection JSON 저장`
4. 다른 세션에서는 `selection import 미리보기`
5. 차단 사유가 없을 때만 `위험 적용` 영역의 `selection import 적용`

### Selected Dirty 저장 순서

1. `dirty 선택` 또는 `attention+dirty 선택`
2. 필요 target만 `선택`
3. `selected dirty 요약`
4. 결과 확인 후 `위험 적용` 영역의 `selected dirty 저장`

## Import Preview 차단 해석

- `schema mismatch`: 다른 schema 버전 snapshot이라 적용 금지
- `config path mismatch`: 다른 config 기준 snapshot이라 적용 금지
- `run root mismatch`: 다른 run root 기준 snapshot이라 적용 금지
- `target ids hash mismatch`: target 구성 자체가 달라 적용 금지
- `unknown targets=...`: 현재 카드에 없는 target은 무시되고 warning만 남음

## Pair와 같은 부분 / 다른 부분

같은 부분:
- 정책 카드 편집
- 실효 경로 preview
- matrix copy/save
- selection snapshot 공유/복원 UX
- seed composer 운영 흐름

다른 부분:
- pair는 `top/bottom`, `roundtrip`, `parallel coordinator` 의미를 가진다
- target-autoloop는 `enabled`, `trigger kinds`, `max cycle`, `queue/input/publish-ready` 의미를 가진다
- Pair watcher와 독립셀 감지기 state machine은 공통화하지 않는다

## Start Watcher Idempotency

- 독립셀 감지기가 이미 `running` 또는 `paused`이고 heartbeat가 fresh이면 start 요청은 중복 launch가 아니라 idempotent 성공이다.
- 이 경우 `Start-TargetAutoloopWatcher.ps1 -Detached -AsJson`는 `Ok=true`, `Result=already-running`, `Idempotent=true`, `ActiveConfirmed=true`, `ReasonCodes=watcher_already_active`를 반환한다.
- mutex가 잡혀 있지만 fresh heartbeat가 아직 확인되지 않은 경우는 `WatcherMutexHeld=true`, `ActiveConfirmed=false`로 구분한다. 패널은 이 상태에서 짧게 heartbeat를 기다리고, 확인되지 않으면 status/stderr 확인 대상으로 남긴다.

## Cycle Limit Extension

MaxCycleCount에 도달한 뒤에는 같은 RunRoot를 이어갈지, 새 RunRoot로 다시 시작할지를 먼저 구분한다.

같은 RunRoot 이어가기:
- 선택 target이 `MaxCycleCount` 도달 상태인지 확인한다.
- target별 카드 안의 추가 횟수 입력칸에 값을 넣고 `targetXX 추가 N회`를 누르면 현재 RunRoot에서 해당 target의 manifest/state/control/status가 같은 증가량으로 갱신된다.
- 곧바로 감지도 재개해야 하면 같은 카드의 `targetXX 추가 N회+감지`를 사용한다.
- 카드의 `추가 상태` 행은 limit 도달 target에서는 `권장 - targetXX 추가 N회+감지`와 증가 전/후 max cycle을 보여주고, 아직 진행 중인 target에서는 현재 cycle/남은 횟수와 비활성 사유를 보여준다.
- 상단 공통 버튼은 `선택 target 추가 N회...` 의미이므로, 여러 독립셀의 진행 상태나 추가 횟수가 섞인 상황에서는 카드별 버튼을 우선 사용한다.
- helper는 `.state\target-autoloop-cycle-extensions.json`에 확장 이력을 남기며, output에는 선택 target progress와 `source-outbox`, `summary.txt`, `review.zip`, `publish.ready.json` 경로가 함께 보여야 한다.

카드별 산출물 확인:
- 각 target 카드의 `outbox`, `summary`, `zip`, `ready` 버튼은 해당 target의 `source-outbox`, `summary.txt`, `review.zip`, `publish.ready.json` 경로를 연다.
- 버튼은 현재 RunRoot의 manifest/status 기준으로 실제 경로가 있을 때만 활성화한다.
- 각 버튼은 hover 설명으로 어떤 target의 어떤 파일/폴더를 여는지와 비활성 의미를 알려줘야 한다.
- 카드의 `산출물 상태` 행은 `source-outbox=있음 / summary=파일 없음 / review.zip=파일 없음 / publish.ready=있음`처럼 파일별 존재 여부와 누락 사유를 보여준다.

카드별 publish-ready 재검사:
- 각 target 카드의 `targetXX ready 재검사`는 `Start-TargetAutoloopWatcher.ps1 -ProcessOnce -Targets targetXX` 경로를 사용한다.
- 카드의 `ready 재검사 상태` 행은 `가능`, `publish-ready trigger가 꺼져 있습니다`, `manifest target이 없습니다`, `RunRoot가 필요합니다` 같은 버튼 활성/비활성 사유를 target별로 보여준다.
- 전역 `전체 publish.ready 1회 재검사`는 현재 RunRoot의 전체 manifest target sweep이고, 카드 버튼은 해당 target만 좁혀 확인하는 운영 버튼이다.
- `일시정지`, `재개`, `정지`는 target별 제어가 아니라 RunRoot의 독립셀 감지기 전체 제어이므로 UI에서는 `전체 감지기 ...` 문구로 구분한다.

카드별 진행률 표시:
- 각 target 카드의 runtime 배지는 `targetXX 3번째 진행 중 / 2/5 완료 / 남은 3`처럼 target id, 현재 시도 번호, 완료/최대 cycle, 남은 횟수를 함께 보여준다.
- route preview와 실제 status refresh는 같은 진행률 포맷을 사용하므로, max count 5 중 몇 번째인지 카드를 따로 열지 않고 확인할 수 있어야 한다.
- runtime 배지 옆 compact 요약은 `진행 / 추가 가능 여부 / 산출물 준비 수와 누락 파일 / ready 재검사 가능 여부`를 한 줄로 보여줘야 한다. 예: `산출물 1/4, 누락 summary/zip/ready`. 상세를 접어도 각 target의 다음 조치를 빠르게 훑을 수 있어야 한다.
- `카드 상세 펼치기/접기` 토글은 `추가 상태`, `산출물 상태`, `ready 재검사 상태`, `실효값 상세`를 한 번에 접거나 펼친다. 기본 compact 상태에서는 runtime 배지와 핵심 버튼만 먼저 보이게 유지하고, 마지막 토글 상태는 `target-autoloop-card-view-preferences.json`에 저장해 다음 패널 시작 때 복원한다.

부분 완료 처리:
- `targetXX 추가 N회+감지` 또는 `선택 target 추가 N회+감지 시작`에서 cycle limit 확장은 성공했지만 watcher start만 실패할 수 있다.
- 이 경우 패널 output이 `부분 완료`로 표시되면 같은 추가 횟수 버튼을 다시 누르지 않는다. 이미 MaxCycleCount가 증가했으므로 status/stderr/control을 확인한 뒤 `독립셀 감지 시작/재시작`만 다시 시도한다.
- 추가 횟수 버튼을 다시 누르는 것은 실제로 더 많은 cycle을 추가하려는 경우에만 허용한다.

새 RunRoot 재시작:
- 기존 run을 이어가는 것이 아니라 완전히 새로 시작하려면 `선택 target만 새 RunRoot`를 사용한다.
- 새 RunRoot에서는 초기 시작문을 다시 submit해야 하며, `publish.ready.json`은 계속 helper가 마지막 단계에서만 생성한다.
- 기존 target01 작업 중에는 live/shared 테스트를 target01에서 돌리지 않는다. 필요한 검증은 별도 승인된 target04 또는 target08 경로에서 수행한다.

## Validation

```powershell
Set-Location C:\dev\python\hyukwoo\hyukwoo1
python -m py_compile relay_operator_panel.py relay_panel_target_autoloop_selection.py relay_panel_clipboard_reports.py relay_panel_policy_ui_specs.py relay_panel_message_config.py relay_panel_services.py relay_panel_target_autoloop_runtime.py relay_panel_target_autoloop_outputs.py
python -c "import relay_panel_target_autoloop_selection, relay_panel_clipboard_reports, relay_panel_policy_ui_specs, relay_panel_target_autoloop_runtime, relay_panel_target_autoloop_outputs; print('helper imports ok')"
python -m unittest test_relay_panel_refactors.RelayOperatorPanelWatcherOptionTests test_relay_panel_refactors.RelayOperatorPanelMessageSlotTests test_relay_panel_refactors.RelayOperatorPanelMessageEditorTabTests
python -m unittest test_relay_panel_target_autoloop_runtime test_relay_panel_target_autoloop_outputs
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ShowTargetAutoloopRouteMatrix.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ShowTargetAutoloopSeedComposer.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StartTargetAutoloopWatcher.ps1
```

## Proof Level

target-autoloop closeout은 script smoke, independent operational proof, shared visible final acceptance를 섞지 않는다.

| Level | 성공 기준 | Final visible 여부 |
| --- | --- | --- |
| `script-smoke` | `py_compile`, helper import, unit/PowerShell route/seed 검증 통과 | 아님 |
| `independent-target-autoloop-operational` | 8 target 설정, selection, seed composer, matrix/status/control 운영 경로 확인 | `TypedWindowDispatch=false`이면 아님 |
| `shared-visible-final` | 공식 8창, typed-window visible beacon, external strict contract path, source-outbox publish, Pair watcher handoff, receipt/important-summary 확인 | 맞음 |

상태 라벨:

```text
Independent 8-cell target-autoloop operational closeout: PASS
Review zip completeness: PASS
Shared visible final acceptance: PENDING
Reason: typed-window official live path proof not yet captured
```

## Button Status Text

`Config에서 다시 읽기`와 `실효 경로 새로고침`은 버튼을 유지하되 완료 문구를 분리한다.

- `Config에서 다시 읽기`: config 문서를 다시 로드하고 8 target 카드 값을 저장본 기준으로 동기화한다.
- `실효 경로 새로고침`: 저장된 config와 현재 RunRoot 기준 route/runtime preview를 다시 계산한다.

현재 구현은 route refresh 때도 저장된 config 기준으로 카드를 다시 동기화한다. 저장 전 카드 편집값을 보존해야 하는 동작 변경은 closeout 이후 별도 작업으로 분리한다.

## Target Scope

target-autoloop closeout UI는 shared visible lane의 공식 8창 운영을 기준으로 한다.

공식 target:
- `target01`
- `target02`
- `target03`
- `target04`
- `target05`
- `target06`
- `target07`
- `target08`

`target09` 이상 동적 카드 생성은 이번 closeout 범위가 아니다. config에 공식 8 target 밖의 항목이 필요해지면 closeout 이후 별도 확장 작업으로 처리한다.

## Review Artifact Checklist

review zip은 repo 상대경로를 보존해야 한다.

필수 포함 파일:
- `relay_operator_panel.py`
- `relay_panel_target_autoloop_selection.py`
- `relay_panel_clipboard_reports.py`
- `relay_panel_policy_ui_specs.py`
- `test_relay_panel_refactors.py`
- `docs/TARGET-AUTOLOOP-CLOSEOUT.md`

검증 예시:

```powershell
Set-Location C:\dev\python\hyukwoo\hyukwoo1
$zip = (Get-ChildItem reviewfile\*.zip | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$entries = [System.IO.Compression.ZipFile]::OpenRead($zip).Entries.FullName
@(
  'relay_operator_panel.py',
  'relay_panel_target_autoloop_selection.py',
  'relay_panel_clipboard_reports.py',
  'relay_panel_policy_ui_specs.py',
  'test_relay_panel_refactors.py',
  'docs/TARGET-AUTOLOOP-CLOSEOUT.md'
) | ForEach-Object {
  if ($entries -notcontains $_) { "MISSING: $_" } else { "OK: $_" }
}
```

## No More Refactor

최종 signoff 전에는 새 구조 변경을 더 넣지 않는다.

허용:
- 문서 오타 수정
- review zip 누락 수정
- 검증 명령 보강
- live signoff 중 드러난 작은 guard fix

금지:
- UI 구조 재배치 추가
- 새 helper 분리 추가
- Pair watcher/queue/roundtrip 의미 변경
- PowerShell 계약 field 이름 변경

## Final Signoff Rule

shared visible lane signoff는 모든 정리와 회귀가 녹색인 뒤 마지막에만 진행한다.

순서:
- `cleanup`
- `preflight-only`
- `active acceptance`
- `post-cleanup`

공식 8창만 사용하고, typed-window visible beacon + external strict contract path가 모두 확인된 경우만 성공으로 판정한다.
