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
- visible pair 자동화의 정식 경로는 `visible worker queue -> Invoke-CodexExecTurn -> source-outbox publish -> watcher handoff` 입니다.
- `router/AHK typed REPL`은 manual smoke 또는 fallback 전용입니다.
- shared `bottest-live-visible`에서 창 종료/재실행/정리는 제목 기준 broad close로 처리하지 않습니다.
- 창 정리는 `runtime/window-bindings/bottest-live-visible.json` 에 기록된 binding-managed 8개 HWND만 대상으로 합니다.
- 기존 8창이 살아 있으면 wrapper는 새 창을 더 띄우지 않고 재사용하거나, 명시적 replace 절차에서만 binding-managed 8개만 닫습니다.
