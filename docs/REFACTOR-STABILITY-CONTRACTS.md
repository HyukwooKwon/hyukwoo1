# Refactor Stability Contracts

이 문서는 최근 1차 리팩토링 이후 현재 구조를 어디까지 고정할지 정리한다. 목적은 추가 구조 분해가 아니라, 다음 작업자가 다시 panel 안으로 orchestration을 되돌리거나 launcher/router/executor 계약을 흩뜨리지 않게 하는 데 있다.

## 목적

- panel / workflow / controller 책임 경계를 고정한다.
- launcher window discovery 반환 shape를 고정한다.
- executor 결과 객체 필드를 고정한다.
- router work-item 처리 단계를 고정한다.
- review zip과 receipt 패키징 기준을 고정한다.

## Panel Boundary

### RelayOperatorPanel

- UI state read/write
- button / dialog / tab interaction
- background task 시작과 성공/실패 state 전환
- workflow/controller 결과를 화면 문구로 반영

### Workflow Service

- `relay_panel_artifact_workflow.py`
  - artifact source 선택
  - preflight / submit request 조립
- `relay_panel_runtime_workflow.py`
  - reuse
  - run root prepare
  - prepare all
- `relay_panel_watcher_workflow.py`
  - watcher start / stop / recover / restart orchestration 결과 조립

규칙:

- background worker는 Tk 객체를 직접 읽지 않는다.
- worker에 필요한 값은 panel에서 snapshot으로 고정해 넘긴다.
- workflow service는 UI widget/messagebox를 직접 만지지 않는다.

### Controller / Service

- watcher controller/service는 watcher domain 판단과 PowerShell/bridge 계약 해석을 담당한다.
- panel workflow는 controller가 반환한 결과를 panel update 형태로 조립한다.
- watcher는 현재 계층에서 추가 분해보다 계약 고정이 우선이다.

## Launcher Boundary

공통 helper:

- `launcher/WindowDiscovery.ps1`

반환 기본 shape:

- `Hwnd`
- `ProcessId`
- `Title`
- `ClassName`

옵션 shape:

- `Rect`

규칙:

- hidden window는 제외한다.
- blank title window는 제외한다.
- geometry가 필요한 스크립트만 `Get-VisibleWindows -IncludeRect`를 호출한다.
- launcher 스크립트는 로컬 `Ensure-WindowApiType` / `Get-VisibleWindows` 정의를 다시 두지 않는다.

## Executor Boundary

대상 파일:

- `executor/Invoke-CodexExecTurn.ps1`

프로세스 호출 결과 객체 필드:

- `ExitCode`
- `StdOut`
- `StdErr`
- `TimedOut`
- `Killed`
- `KillReason`
- `DurationMs`

상태/산출물에 반영되는 요약 필드:

- `TimedOut`
- `Killed`
- `KillReason`
- `DurationMs`
- `StdOutChars`
- `StdErrChars`

규칙:

- timeout이어도 가능한 한 `result.json`을 남긴다.
- `error.json`에는 실패 사유뿐 아니라 timeout/kill 관찰값도 남긴다.
- `result.json` / `error.json` 필드 추가는 가능하지만, 기존 필드 의미를 바꾸면 안 된다.

예시:

```json
{
  "ExitCode": 0,
  "TimedOut": false,
  "Killed": false,
  "KillReason": "",
  "DurationMs": 842,
  "StdOutChars": 248,
  "StdErrChars": 31,
  "ContractArtifactsReady": true
}
```

```json
{
  "Reason": "process-timeout",
  "TimedOut": true,
  "Killed": true,
  "KillReason": "timeout",
  "DurationMs": 1007,
  "StdOutChars": 19,
  "StdErrChars": 20
}
```

## Router Boundary

대상 파일:

- `router/Start-Router.ps1`

work-item 단계:

1. queue dequeue
2. preflight / metadata validation
3. payload compose
4. AHK delivery
5. failure category 분류
6. archive / retry disposition

실패 disposition state:

- `retry-pending`
- `ignored`
- `failed`

규칙:

- work-item loop는 category별 세부 로직을 직접 길게 들고 있지 않는다.
- preflight, delivery, disposition은 helper 함수 경계로 유지한다.
- archive state 전이는 `Move-MessageToArchive` 이후 metadata/log까지 같이 끝내야 한다.

## Review Packaging Contract

review zip에는 최소 다음이 들어가야 한다.

- 실제 수정한 source file
- 수정과 직접 연결된 test file
- 필요하면 새 계약 문서
- 실행 receipt

receipt에는 최소 다음이 들어간다.

- 생성 시각
- profile
- zip 파일명
- receipt 파일명
- suite pass/fail count
- 실행한 검증 명령
- 명령별 pass/fail 요약

명령별 필수 필드:

- `label`
- `command`
- `passed`
- `exit_code`
- `duration_ms`

권장 필드:

- `summary`
- `output_tail`
- `error`

권장:

- `create-refactor-closeout-review.ps1`를 closeout SSOT로 사용한다.
- 기본 profile은 baseline이고, 운영 acceptance는 `-IncludePairTransportAcceptance`로만 opt-in 한다.
- review zip 안에 receipt 파일을 같이 넣는다.
- receipt가 없는 zip은 “코드만 있고 검증 증거는 없는 번들”로 취급한다.

예시:

```json
{
  "generated_at": "2026-04-23T08:45:35.3253743+09:00",
  "review_zip": "20260423084442.zip",
  "receipt_file": "20260423084442.receipt.json",
  "profile": "baseline",
  "suite_pass_count": 12,
  "suite_fail_count": 0,
  "commands": [
    {
      "label": "pytest_refactors",
      "passed": true,
      "exit_code": 0,
      "duration_ms": 16520,
      "summary": "160 passed in 16.52s"
    }
  ]
}
```

## Reopen 기준

다음 신호가 보이기 전까지는 구조 리팩토링을 더 깊게 열지 않는다.

- panel 안에 orchestration 코드가 다시 커짐
- workflow 간 중복 조립 로직이 다시 생김
- launcher 반환 shape가 호출부마다 다시 갈라짐
- executor 결과 정보만으로 timeout/kill 원인 분리가 안 됨
- router archive state 전이가 다시 loop 본문에 퍼짐

현재 단계의 우선순위는 추가 분해가 아니라 테스트, 문서, receipt 정합성 유지다.
