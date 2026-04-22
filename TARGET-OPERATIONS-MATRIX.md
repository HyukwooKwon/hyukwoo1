# Target Operations Matrix

이 문서는 visible 운영 lane 기준 8개 창의 현재 매핑과 개별 설정 상태를 한 번에 보는 운영표입니다.
현재 기준 config는 [settings.bottest-live-visible.psd1](C:\dev\python\hyukwoo\hyukwoo1\config\settings.bottest-live-visible.psd1)입니다.

## Pair 매핑

- `pair01`: `target01` ↔ `target05`
- `pair02`: `target02` ↔ `target06`
- `pair03`: `target03` ↔ `target07`
- `pair04`: `target04` ↔ `target08`

## 운영표

| PairId | Role | TargetId | WindowTitle | InboxFolder | PairRunFolder Pattern | Initial 전용문구 | Handoff 전용문구 | FixedSuffix | EnterCount | 활성 상태 | 상태 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pair01 | top | target01 | BotTestLive-Window-01 | `inbox\bottest-live-visible\target01` | `pair-test\bottest-live-visible\run_*\pair01\target01` | 있음 | 있음 | 없음 | 1 | 활성 | 검증 완료 |
| pair01 | bottom | target05 | BotTestLive-Window-05 | `inbox\bottest-live-visible\target05` | `pair-test\bottest-live-visible\run_*\pair01\target05` | 있음 | 있음 | 없음 | 1 | 활성 | 검증 완료 |
| pair02 | top | target02 | BotTestLive-Window-02 | `inbox\bottest-live-visible\target02` | `pair-test\bottest-live-visible\run_*\pair02\target02` | 있음 | 있음 | 없음 | 1 | 활성 | 검증 완료 |
| pair02 | bottom | target06 | BotTestLive-Window-06 | `inbox\bottest-live-visible\target06` | `pair-test\bottest-live-visible\run_*\pair02\target06` | 있음 | 있음 | 없음 | 1 | 활성 | 검증 완료 |
| pair03 | top | target03 | BotTestLive-Window-03 | `inbox\bottest-live-visible\target03` | `pair-test\bottest-live-visible\run_*\pair03\target03` | 있음 | 있음 | 없음 | 1 | 활성 | 검증 완료 |
| pair03 | bottom | target07 | BotTestLive-Window-07 | `inbox\bottest-live-visible\target07` | `pair-test\bottest-live-visible\run_*\pair03\target07` | 있음 | 있음 | 없음 | 1 | 활성 | 검증 완료 |
| pair04 | top | target04 | BotTestLive-Window-04 | `inbox\bottest-live-visible\target04` | `pair-test\bottest-live-visible\run_*\pair04\target04` | 있음 | 있음 | 없음 | 1 | 활성 | 검증 완료 |
| pair04 | bottom | target08 | BotTestLive-Window-08 | `inbox\bottest-live-visible\target08` | `pair-test\bottest-live-visible\run_*\pair04\target08` | 있음 | 있음 | 없음 | 1 | 활성 | 검증 완료 |

## 원클릭 실행기

- `pair01`: [open-run-pair01-headless-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-run-pair01-headless-drill.vbs)
- `pair02`: [open-run-pair02-headless-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-run-pair02-headless-drill.vbs)
- `pair03`: [open-run-pair03-headless-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-run-pair03-headless-drill.vbs)
- `pair04`: [open-run-pair04-headless-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-run-pair04-headless-drill.vbs)

## 사용 원칙

- 실제 적용된 문구/경로/queue 상태 확인은 [show-effective-config.ps1](C:\dev\python\hyukwoo\hyukwoo1\show-effective-config.ps1)를 기준으로 봅니다.
- 이 표는 운영자용 요약표이고 source of truth는 아닙니다.
- pair 활성/비활성 런타임 상태는 `runtime\pair-activation\bottest-live-visible.json`을 기준으로 보고, panel과 실행기는 같은 상태를 읽습니다.
- pair별 세부 오버라이드는 `PairOverrides`, `RoleOverrides`, `TargetOverrides`를 기준으로 채웁니다.
- 창별 폴더 실존 여부와 `summary/request/done/error/result`는 panel 또는 `show-effective-config`의 `PathState`로 최종 확인합니다.
- 현재 기준으로 pair01~pair04는 모두 한 번 왕복 성공 실검증까지 완료된 상태입니다.
