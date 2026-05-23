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
- pair watcher와 target-autoloop watcher 공통 state machine 도입
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
- 두 watcher/state machine은 공통화하지 않는다

## Validation

```powershell
Set-Location C:\dev\python\hyukwoo\hyukwoo1
python -m py_compile relay_operator_panel.py relay_panel_target_autoloop_selection.py relay_panel_clipboard_reports.py relay_panel_policy_ui_specs.py relay_panel_message_config.py relay_panel_services.py
python -c "import relay_panel_target_autoloop_selection, relay_panel_clipboard_reports, relay_panel_policy_ui_specs; print('helper imports ok')"
python -m unittest test_relay_panel_refactors.RelayOperatorPanelWatcherOptionTests test_relay_panel_refactors.RelayOperatorPanelMessageSlotTests test_relay_panel_refactors.RelayOperatorPanelMessageEditorTabTests
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ShowTargetAutoloopRouteMatrix.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ShowTargetAutoloopSeedComposer.ps1
```

## Proof Level

target-autoloop closeout은 script smoke, independent operational proof, shared visible final acceptance를 섞지 않는다.

| Level | 성공 기준 | Final visible 여부 |
| --- | --- | --- |
| `script-smoke` | `py_compile`, helper import, unit/PowerShell route/seed 검증 통과 | 아님 |
| `independent-target-autoloop-operational` | 8 target 설정, selection, seed composer, matrix/status/control 운영 경로 확인 | `TypedWindowDispatch=false`이면 아님 |
| `shared-visible-final` | 공식 8창, typed-window visible beacon, external strict contract path, source-outbox publish, watcher handoff, receipt/important-summary 확인 | 맞음 |

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
- watcher/queue/roundtrip 의미 변경
- PowerShell 계약 field 이름 변경

## Final Signoff Rule

shared visible lane signoff는 모든 정리와 회귀가 녹색인 뒤 마지막에만 진행한다.

순서:
- `cleanup`
- `preflight-only`
- `active acceptance`
- `post-cleanup`

공식 8창만 사용하고, typed-window visible beacon + external strict contract path가 모두 확인된 경우만 성공으로 판정한다.
