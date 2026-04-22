# Watcher Control Contract

이 문서는 paired watcher 제어에서 Python 패널과 PowerShell 스크립트가 공유하는 운영 계약을 고정한다.

## 범위

- control file: `RunRoot\.state\watcher-control.json`
- status file: `RunRoot\.state\watcher-status.json`
- producer:
  - Python: start eligibility, stop/restart/recover 요청
  - PowerShell watcher: control 소비, status/ack 기록
- consumer:
  - Python panel / services / controllers
  - `tests\Show-PairedExchangeStatus.ps1`

## Scope Boundary

- 현재 SSOT는 `Watcher.*` 브리지 필드 전용이다.
- `Manifest.*`, target row의 `Dispatch*`, `SourceOutbox*`, `Seed*` 시간값은 이 문서의 watcher bridge 계약 범위에 포함되지 않는다.
- paired status 전체 ISO 필드 계약은 별도 SSOT로 분리해서 다룬다.

## Host Contract

- watcher control/status/bridge 계약은 `pwsh` 기준 PowerShell 7+ 환경만 공식 지원한다.
- Windows PowerShell 5.1 에서는 JSON timestamp 해석 차이 때문에 동일한 시간값 보존 계약을 보장하지 않는다.
- `tests\Watch-PairedExchange.ps1` 는 이미 `pwsh` 실행을 강제하며, watcher bridge 관련 검증도 이 기준을 따른다.

## Control File Schema

파일: `watcher-control.json`

필드:

- `SchemaVersion`: 현재 `"1.0.0"`
- `RequestedAt`: ISO timestamp
- `RequestedBy`: 요청 주체. 기본 `relay_operator_panel`
- `Action`: 현재 `stop`
- `RunRoot`: 대상 run root
- `RequestId`: 제어 요청 고유 식별자

의미:

- watcher loop는 control file을 polling 하다가 `Action=stop`을 읽으면 먼저 `accepted` ack를 남긴다.
- control file은 watcher가 소비한 뒤 지워야 한다.

## Status File Schema

파일: `watcher-status.json`

핵심 필드:

- `State`: `running | stop_requested | stopping | stopped`
- `Reason`: 상태 전이 사유
- `UpdatedAt`: status write timestamp
- `HeartbeatAt`: watcher loop 기준 최신 heartbeat timestamp
- `StatusSequence`: status write sequence number
- `ProcessStartedAt`: watcher process start timestamp
- `RequestId`: 현재 처리 중이거나 마지막으로 반영한 request id
- `Action`: 현재 처리 중이거나 마지막으로 반영한 action
- `LastHandledRequestId`
- `LastHandledAction`
- `LastHandledResult`
- `LastHandledAt`

의미:

- `LastHandled*` 는 watcher가 실제로 소비한 control 요청의 ack 계약이다.
- stop 요청을 읽은 직후:
  - `LastHandledRequestId = request_id`
  - `LastHandledAction = stop`
  - `LastHandledResult = accepted`
- 실제 종료 직전 최종 기록:
  - `LastHandledRequestId = request_id`
  - `LastHandledAction = stop`
  - `LastHandledResult = stopped`

## Paired Status JSON Bridge

`tests\Show-PairedExchangeStatus.ps1 -AsJson` 는 watcher contract를 Python 쪽으로 브리지한다.

노출 필드:

- `Watcher.Status`
- `Watcher.MutexName`
- `Watcher.StatusFileState`
- `Watcher.StatusFileUpdatedAt`
- `Watcher.HeartbeatAt`
- `Watcher.HeartbeatAgeSeconds`
- `Watcher.StatusSequence`
- `Watcher.ProcessStartedAt`
- `Watcher.StatusReason`
- `Watcher.StopCategory`
- `Watcher.ForwardedCount`
- `Watcher.ConfiguredMaxForwardCount`
- `Watcher.StatusRequestId`
- `Watcher.StatusAction`
- `Watcher.LastHandledRequestId`
- `Watcher.LastHandledAction`
- `Watcher.LastHandledResult`
- `Watcher.LastHandledAt`
- `Watcher.StatusExists`
- `Watcher.StatusParseError`
- `Watcher.StatusLastWriteAt`
- `Watcher.StatusAgeSeconds`
- `Watcher.StatusPath`
- `Watcher.ControlExists`
- `Watcher.ControlParseError`
- `Watcher.ControlLastWriteAt`
- `Watcher.ControlRequestedAt`
- `Watcher.ControlAgeSeconds`
- `Watcher.ControlPendingAction`
- `Watcher.ControlPendingRequestId`
- `Watcher.ControlPath`

SSOT field list:

- [WATCHER-CONTRACT-FIELDS.json](/C:/dev/python/hyukwoo/hyukwoo1/docs/WATCHER-CONTRACT-FIELDS.json)

추가 SSOT 분류:

- `WatcherBridgeRequiredFields`: bridge가 항상 노출해야 하는 필드 목록
- `WatcherBridgeIsoTimestampFields`: 값이 존재할 때 반드시 ISO 8601 문자열이어야 하는 필드 목록
- `WatcherBridgeDerivedFields`: bridge가 watcher 원본 상태에서 계산하거나 보강해서 제공하는 필드 목록

Timestamp 형식 계약:

- `Watcher.StatusFileUpdatedAt`
- `Watcher.HeartbeatAt`
- `Watcher.ProcessStartedAt`
- `Watcher.LastHandledAt`
- `Watcher.StatusLastWriteAt`
- `Watcher.ControlLastWriteAt`
- `Watcher.ControlRequestedAt`

위 필드는 값이 비어 있지 않다면 locale string 이 아니라 Python `datetime.fromisoformat()` 으로 파싱 가능한 ISO 문자열이어야 한다.

Python panel은 status/control 원본 파일을 직접 해석하지 않고, 우선 이 JSON bridge를 기준으로 판정한다.
Python watcher/audit 코드도 런타임에 `WATCHER-CONTRACT-FIELDS.json` 을 직접 읽어 필수 필드와 audit 정책을 맞춘다.
Python `StatusService` 는 bridge 로드 직후 watcher required field / ISO timestamp 계약을 검사하고, 위반 시 `Watcher.StatusParseError` 로 승격해 watcher 제어를 fail-fast 시킨다.

## Lifecycle

### Start

허용 조건:

- `RunRoot` 존재
- watcher 상태가 `running` 아님
- `control_file_unreadable`, `status_file_unreadable`, `status_file_stale`, `stop_requested_timeout`, `stale_control_file`, `control_pending_action_exists` 가 없음

예외:

- `stopped + stale_control_file`
- `stopped + stop_requested_timeout`

위 두 경우는 안전 정리 후 start 허용 가능

### Stop

허용 조건:

- watcher 상태가 `running`
- `ReadyToForwardCount == 0`
- stale/unreadable/timeout blocker 없음

경고만 남기는 조건:

- `FailureLineCount > 0`
- `NoZipCount > 0`

### Restart

순서:

1. stop eligibility 통과
2. stop request 기록
3. `wait_for_stopped`
4. start detached
5. `wait_for_running`

`wait_for_stopped` 성공 조건:

- watcher 상태가 `stopped`
- control file cleared
- `LastHandledRequestId == request_id`
- `LastHandledAction == stop`
- `LastHandledResult == stopped`

`wait_for_running` 성공 조건:

- watcher 상태가 `running`
- control file cleared
- 이전 stop request ack 안정 유지

### Recover Stale

허용 조건:

- watcher 상태가 `stopped`
- start eligibility가 `cleanup_allowed=True`

현재 recover는 stale watcher control 정리만 수행한다.

## Reason Codes

차단 계열:

- `runroot_missing`
- `paired_status_missing`
- `watcher_unknown`
- `watcher_already_running`
- `control_pending_action_exists`
- `control_file_unreadable`
- `status_file_unreadable`
- `status_file_stale`
- `stale_control_file`
- `stop_requested_timeout`
- `pending_forward_exists`

경고 계열:

- `recent_failure_present`
- `incomplete_artifacts_present`

후속 결과 계열:

- `request_ack_missing`
- `request_ack_unstable`
- `control_not_cleared`
- `stop_timeout`
- `start_timeout`

## Audit Log

파일: `logs\watcher-control-audit.jsonl`

기록 단위:

- `start`
- `stop`
- `restart`
- `recover_start_blockers`

필드:

- `ActionId`
- `Timestamp`
- `Action`
- `RunRoot`
- `RunRootHash`
- `RequestedBy`
- `Ok`
- `State`
- `Message`
- `RequestId`
- `ReasonCodes`
- `WarningCodes`
- `Extra`

정책:

- rotation: `MaxBytes = 524288`
- archive count keep: `MaxArchives = 5`
- retention: `RetentionDays = 14`
- append lock: stale-after `10s`, retry timeout `2s`, retry interval `50ms`

## Recovery Guidance

- `stale_control_file`: watcher가 stopped일 때 stale 정리 후 start 가능
- `stop_requested_timeout`: 오래된 pending stop. watcher가 stopped면 stale 정리 후 재시도
- `control_file_unreadable`: 자동 정리 금지. control file 원문 확인 필요
- `status_file_unreadable`: 자동 정리 금지. status file 원문 확인 필요
- `status_file_stale`: quick/full refresh 후 재판정
- `pending_forward_exists`: 결과 탭에서 ready-to-forward target 확인 후 stop/restart 재시도

## Freshness Rules

- active watcher freshness는 우선 `HeartbeatAt` 기준으로 본다.
- `HeartbeatAt` 이 없으면 `UpdatedAt` 을 fallback 으로 사용한다.
- Python panel은 active 상태에서 freshness age가 `STATUS_STALE_AFTER_SEC` 이상이면 `status_file_stale` 로 차단한다.
- `StatusSequence` 는 watcher status가 실제로 갱신되고 있는지 추적하는 보조 신호다.
