# Operations Acceptance

이 문서는 현재 relay 운영 보조 범위의 종료선을 짧게 고정하는 메모입니다.

적용 일자:

- `2026-03-31`

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
- `run-pair01-headless-drill.ps1`, `launch-run-pair01-headless-drill.cmd`, `open-run-pair01-headless-drill.vbs`는 pair01 한 쌍 실제 왕복 성공까지 확인
- `run-pair02-headless-drill.ps1`, `run-pair03-headless-drill.ps1`, `run-pair04-headless-drill.ps1`는 각 pair 한 쌍 실제 왕복 성공까지 확인

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

운영 반복 검증 기준 문서:

- [OPERATIONS-CHECKLIST.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-CHECKLIST.md)
- [OPERATIONS-DRILLS.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-DRILLS.md)

한 줄 기준:

- 지금 범위는 기능 추가보다 운영 반복 검증과 문서 기준 유지가 우선입니다.
