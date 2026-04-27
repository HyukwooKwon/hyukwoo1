# Relay Router

이 프로젝트는 `txt` 파일 기반으로 8개 PowerShell 대상 창에 순차 입력하는 Windows 전용 중계기입니다.

고정 계약:

- 외부 프로그램은 `*.tmp.txt`를 쓴 뒤 `*.ready.txt`로 rename
- 감시는 동시에 하지만 실제 전송은 전역 FIFO 1개로 순차 처리
- AutoHotkey v2가 본문과 `{Enter}`를 분리 전송
- PowerShell 대상 창은 launcher가 직접 띄우고 `PID/HWND/Title`을 `runtime\target-runtime.json`에 기록
- sender는 `HWND -> WindowPid -> ShellPid -> Title` 순서로 창을 찾습니다
- 성공은 `processed`, 창 없음은 `retry-pending`, 파일 이상 또는 재시도 실패는 `failed`로 이동합니다

## 구조

```text
config\settings.psd1
runtime\target-runtime.json
runtime\router-state.json
launcher\Start-Targets.ps1
router\Start-Router.ps1
router\FileQueue.ps1
router\MessageArchive.ps1
router\RuntimeMap.ps1
sender\SendToWindow.ahk
sender\Resolve-SendTarget.ps1
tests\Smoke-Test.ps1
tests\Manual-E2E-AllTargets.ps1
show-relay-status.ps1
```

루트의 [setup-relay.ps1](C:\dev\python\hyukwoo\hyukwoo1\setup-relay.ps1), [start-targets.ps1](C:\dev\python\hyukwoo\hyukwoo1\start-targets.ps1), [router.ps1](C:\dev\python\hyukwoo\hyukwoo1\router.ps1), [show-relay-status.ps1](C:\dev\python\hyukwoo\hyukwoo1\show-relay-status.ps1), [producer-example.ps1](C:\dev\python\hyukwoo\hyukwoo1\producer-example.ps1), [send-to-window.ahk](C:\dev\python\hyukwoo\hyukwoo1\send-to-window.ahk)는 엔트리 파일입니다.

운영 승인/반복 점검 체크리스트는 [OPERATIONS-CHECKLIST.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-CHECKLIST.md)를 기준으로 사용합니다.
`show-effective-config`/evidence 정책 반복 검증은 [OPERATIONS-DRILLS.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-DRILLS.md)를 기준으로 사용합니다.
현재 운영 종료선과 reopen 조건은 [OPERATIONS-ACCEPTANCE.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-ACCEPTANCE.md)에 고정합니다.
8개 창 pair/role/target 운영표는 [TARGET-OPERATIONS-MATRIX.md](C:\dev\python\hyukwoo\hyukwoo1\TARGET-OPERATIONS-MATRIX.md)를 기준으로 봅니다.

## 공식 명령

실사용 기준으로 먼저 기억할 명령은 아래 명령들이면 충분합니다.

- `setup-relay.ps1`
- `ensure-targets.ps1`
- `router.ps1`
- `tests\Manual-E2E-AllTargets.ps1`
- `tests\Start-PairedExchangeTest.ps1`
- `tests\Watch-PairedExchange.ps1`
- `tests\Run-LiveVisiblePairAcceptance.ps1`
- `router\Restart-RouterForConfig.ps1`
- `show-paired-exchange-status.ps1`
- `show-relay-status.ps1`
- `show-effective-config.ps1`
- `save-effective-config-evidence.ps1`
- `check-target-window-visibility.ps1`
- `attach-targets-from-bindings.ps1`
- `check-headless-exec-readiness.ps1`
- `check-paired-exchange-artifact.ps1`
- `import-paired-exchange-artifact.ps1`
- `invoke-codex-exec-turn.ps1`
- `run-headless-pair-drill.ps1`
- `run-preset-headless-pair-drill.ps1`
- `run-pair01-headless-drill.ps1`
- `run-pair02-headless-drill.ps1`
- `run-pair03-headless-drill.ps1`
- `run-pair04-headless-drill.ps1`
- `disable-pair.ps1`
- `enable-pair.ps1`
- `show-pair-activation-status.ps1`
- `cleanup-one-time-message-queue.ps1`
- `consume-one-time-message.ps1`
- `relay_operator_panel.py`
- `launch-relay-operator-panel.cmd`
- `open-relay-operator-panel.vbs`
- `launch-preset-headless-pair-drill.cmd`
- `open-preset-headless-pair-drill.vbs`
- `launch-run-pair01-headless-drill.cmd`
- `open-run-pair01-headless-drill.vbs`
- `launch-run-pair02-headless-drill.cmd`
- `launch-run-pair03-headless-drill.cmd`
- `launch-run-pair04-headless-drill.cmd`
- `open-run-pair02-headless-drill.vbs`
- `open-run-pair03-headless-drill.vbs`
- `open-run-pair04-headless-drill.vbs`

`launcher\Start-Targets.ps1`, `router\Start-Router.ps1`, `router\Requeue-RetryPending.ps1`와 대부분의 `tests\*.ps1`는 내부/보조 명령으로 보면 됩니다. `tests\Manual-E2E-AllTargets.ps1`, `tests\Start-PairedExchangeTest.ps1`, `tests\Watch-PairedExchange.ps1`는 운영 검증용 공식 명령으로 사용합니다.

`run-headless-pair-drill.ps1`는 generic core entrypoint이고, `run-preset-headless-pair-drill.ps1`는 preset shortcut entrypoint입니다. `run-pair01~04-headless-drill.ps1`, `launch-run-pair01~04-headless-drill.cmd`, `open-run-pair01~04-headless-drill.vbs`는 현재 visible preset pair를 빠르게 호출하기 위한 얇은 shortcut wrapper입니다.

`start-targets.ps1`는 새 창 강제 기동이 필요할 때만 쓰는 예외 명령입니다. 운영 기본 루틴에서는 `ensure-targets.ps1`를 먼저 사용합니다.

`attach-targets-from-bindings.ps1`는 title 추론 대신 외부 launcher가 저장한 binding JSON으로 정확한 8개 창을 runtime map에 등록하는 명령입니다. 창이 많거나 동일한 `powershell.exe` 세션이 섞여 있을 때 이 경로가 가장 안전합니다. config에 `BindingProfilePath`가 있으면 `-BindingsPath`를 생략할 수 있습니다.

기존 invisible BotTest 세션과 새 visible 세션이 섞이는 환경이라면, 새 lane은 `BotTestLive-Window-01..08` 제목과 [settings.bottest-live-visible.psd1](C:\dev\python\hyukwoo\hyukwoo1\config\settings.bottest-live-visible.psd1) 기준으로 완전히 분리해서 사용하는 편이 안전합니다.

## 표준 운영 절차

실운영/실검증은 아래 순서로 고정하는 편이 가장 안전합니다.
아래 예시는 현재 운영 lane 기준으로 `.\config\settings.bottest-live-visible.psd1`를 사용합니다.

1. target 준비

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ensure-targets.ps1
```

2. 실제 입력 가능 창 진단

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-target-window-visibility.ps1
```

통과 기준:
- `Injectable: ok=8 fail=0`
- 각 target이 `InjectionMethod`를 하나 이상 가짐

3. router 시작

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\router.ps1
```

4. 전체 수동 승인 E2E

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Manual-E2E-AllTargets.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

5. paired test 준비

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-PairedExchangeTest.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -SendInitialMessages
```

같은 `RunRoot`에서 seed만 다시 넣고 싶으면 `Start-PairedExchangeTest.ps1`를 재실행하지 말고 아래 전용 enqueue 경로를 사용합니다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Send-InitialPairSeed.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible\run_live -TargetId target01
```

visible lane은 사용자가 최근 입력 중이면 seed 주입을 보류하고 `retry-pending`으로 남깁니다. 기본 reseed 경로는 `Send-InitialPairSeedWithRetry.ps1`이며, `PairTest.SeedRetryBackoffMs` / `PairTest.SeedRetryMaxAttempts` 기준으로 자동 재시도하다가 상한을 넘기면 `manual_attention_required`로 종료합니다. 이 상태가 아니면 같은 `RunRoot`에 대해 `Send-InitialPairSeed.ps1`를 반복 호출할 필요가 없습니다.
`Start-PairedExchangeTest.ps1`와 `Run-LiveVisiblePairAcceptance.ps1`는 seed 입력 컨텍스트가 비어 있으면 `PairTest.DefaultSeedWorkRepoRoot`와 review input 자동선택 규칙을 사용합니다. 자동선택은 `DefaultSeedReviewInputSearchRelativePath`, `DefaultSeedReviewInputFilter`, `DefaultSeedReviewInputNameRegex`, `DefaultSeedReviewInputMaxAgeHours`, `DefaultSeedReviewInputRequireSingleCandidate` 기준으로 평가되고, 실제 선택 결과는 `request.json` / `manifest.json`의 `ReviewInputSelection*` 필드에 남습니다. live visible lane에서 `WorkRepoRoot:` / `ReviewInputPath:`가 비어 있으면 먼저 이 기본값과 selection metadata부터 확인하세요.

중요:
- shared `bottest-live-visible`에서 `hyukwoo1`는 자동화 레포일 뿐 실제 작업 repo가 아닙니다.
- `WorkRepoRoot` / `ReviewInputPath`는 반드시 외부 repo 경로여야 하고, `C:\dev\python\hyukwoo\hyukwoo1` 또는 그 하위 경로를 seed 입력 대상으로 사용하면 시작 자체가 실패합니다.
- `RunRoot`도 반드시 현재 작업 중인 external `WorkRepoRoot` 아래에 있어야 합니다. `RunRoot`가 `hyukwoo1` 자동화 레포 아래이거나, 선택한 `WorkRepoRoot` 밖이면 run 준비 단계에서 즉시 실패합니다.
- 기본 smoke 외부 repo는 `C:\dev\python\relay-workrepo-visible-smoke` 와 그 안의 `reviewfile\seed_review_input_latest.zip` 입니다.
- 기본 smoke external runroot base는 `C:\dev\python\relay-workrepo-visible-smoke\.relay-runs\bottest-live-visible` 입니다.
- 외부 repo 감지는 repo 전체를 재귀 감시하지 않고, 그 repo 안의 `.relay-contract\...` 아래에 확정된 `summary.txt + review.zip + publish.ready.json` explicit contract path만 대상으로 합니다.
- 작업 repo가 바뀌면 감지 경로도 같이 바뀌어야 하고, watcher는 항상 request/manifest에 기록된 `SourceOutboxPath` / `SourceSummaryPath` / `SourceReviewZipPath` / `PublishReadyPath` 만 strict 검증합니다.
- `primary contract externalized`와 `full externalized`는 다릅니다.
  - `primary contract externalized`: `summary.txt + review.zip + publish.ready.json` 이 현재 작업 중인 외부 repo root 아래에서 생성/감지되는 상태
  - `full externalized`: 위 primary contract뿐 아니라 `RunRoot`, receipt/status, import된 summary/review/done/result bookkeeping copy까지 외부 repo 기준으로 남는 상태
- shared `bottest-live-visible` 현재 구현 기준은 `primary contract externalized + external runroot`입니다. `WorkRepoRoot`와 `RunRoot`는 외부 repo 기준이어야 하지만, import bookkeeping까지 전부 외부화한 `full externalized`는 아직 2단계입니다.
- 현재 base config의 `InboxRoot / ProcessedRoot / RuntimeRoot / LogsRoot` 가 아직 `hyukwoo1`를 가리키면, shared external mode real run은 `automation-repo-bookkeeping-roots-disallowed` 로 즉시 실패합니다. 즉 external mode live proof를 돌리려면 이 residual bookkeeping roots도 현재 작업 중인 external `WorkRepoRoot` 아래로 옮긴 effective config가 필요합니다.

이 external contract path들은 모두 explicit path로 manifest/request에 기록되고, 선택한 `WorkRepoRoot` 내부에 있어야 합니다. target 간 contract path가 충돌하거나 work repo 밖으로 벗어나면 run 준비 단계에서 즉시 실패합니다.
최신 acceptance receipt(`RunRoot\\.state\\live-acceptance-result.json`)에는 `Contract.ExternalWorkRepoUsed`, `Contract.ExternalContractPathsValidated`, `Contract.PrimaryContractExternalized`, `Contract.ExternalRunRootUsed`, `Contract.BookkeepingExternalized`, `Contract.FullExternalized`, `Contract.InternalResidualRoots`, target별 실제 `ContractRootPath` / `SourceSummaryPath` / `SourceReviewZipPath` / `PublishReadyPath` 도 같이 남아서, 이번 run이 어떤 외부 contract 경로를 기준으로 감지했고 무엇이 아직 내부 repo bookkeeping으로 남는지 바로 확인할 수 있습니다.

live visible acceptance를 한 번에 돌릴 때는 아래 스크립트를 사용합니다. 이 경로는 `run 준비 -> router 확인 -> watcher 확인 -> target01 seed -> 상태 판정`을 한 번에 묶고, 기존 live router가 이미 떠 있으면 mutex 기준으로 재사용합니다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-LiveVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -SeedTargetId target01 -AsJson
```

shared `bottest-live-visible` lane 창 정책:
- 공식 운영 창 `BotTestLive-Window-01`~`BotTestLive-Window-08`만 사용합니다.
- 기본 경로는 기존 8창 재사용입니다.
- 창 상태가 나쁘면 공식 운영 창만 재기동합니다.
- `BotTestLive-Fresh-*`, `BotTestLive-Surrogate-*`, `BotTestLive-Candidate-*` 같은 ad-hoc 테스트 창은 shared lane active acceptance에 사용하지 않습니다.

acceptance를 실행하면 최종 판정은 항상 `RunRoot\.state\live-acceptance-result.json`에도 저장됩니다. 콘솔 출력이 없어도 run root만 열어 `AcceptanceState`, `AcceptanceReason`, retry diagnostics를 다시 확인할 수 있습니다.
최신 receipt에는 `Primitives.Submit`, `Primitives.Publish`, `Primitives.Handoff`가 같이 남아서, 매크로가 어떤 공용 wrapper를 거쳤는지와 마지막 primitive 판단을 바로 추적할 수 있습니다. 각 primitive payload에는 `Evidence`도 같이 남겨서 panel, summary, receipt가 같은 근거 row를 재사용할 수 있게 맞춥니다.
shared `bottest-live-visible`에서 `-RunRoot`를 생략하면 현재 `WorkRepoRoot` 아래 `.relay-runs\bottest-live-visible\run_*` 경로가 자동 생성됩니다. 다른 repo로 바꾸면 이 external runroot도 같이 바뀌어야 합니다.

runroot 전체 상태를 한 번에 요약해서 보려면 아래 helper를 사용합니다. 이 명령은 `show-paired-exchange-status.ps1`와 acceptance receipt를 같이 읽어 한 줄 요약, acceptance 상태, watcher 상태, target별 상태를 함께 보여줍니다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\show-paired-run-summary.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live_acceptance
```

panel을 사용 중이면 홈 탭과 운영 탭의 `runroot 요약` 버튼으로 같은 helper를 바로 실행할 수 있고, 같은 위치의 `important-summary 열기` 버튼으로 방금 생성된 텍스트 요약을 바로 열 수 있습니다.
이 helper는 같은 RunRoot 아래 `.state\important-summary.txt` 와 `.state\important-summary.json` 도 함께 갱신합니다. 이 파일에는 실제 payload 파일(`messages\target01.txt`, `messages\target05.txt`), processed archive 옆의 실제 전송 payload snapshot(`*.payload.txt`), request/contract 경로, `summary.txt / review.zip / publish.ready.json` 생성 여부, receipt/seed/pair/watcher 핵심 상태, 최신 prepare/AHK/router 로그 경로가 같이 들어갑니다. 또 상단 `freshness` 블록에 최신 관측 신호 시각뿐 아니라 `NewestProgressSignalAt`, `ProgressSignalAgeSeconds`, `ProgressStale`까지 같이 적어서 "최근 흔적"과 "실제 relay 진전"을 분리해 읽을 수 있게 했고, `operator-focus` 블록에 `AttentionLevel`, `CurrentBottleneck`, `NextExpectedStep`, `RecommendedAction`를, `recent-events` 블록에 최근 핵심 이벤트 5~8줄을 같이 적어서 운영자가 먼저 봐야 할 병목과 최신성을 한 장에서 판단할 수 있게 맞춥니다. JSON 쪽 recent event는 `EventClass`, `PairId`, `TargetId`, `IsProgressSignal`도 같이 남겨 후속 helper가 텍스트 재파싱 없이 같은 근거를 재사용할 수 있게 맞춥니다.
여기서 `StaleSummary` 는 최근 어떤 관측 신호든 있었는지를 뜻하고, `ProgressStale` 는 실제 relay/orchestration 진전 신호가 최근에 있었는지를 뜻합니다. 따라서 `StaleSummary=false` 이면서 `ProgressStale=true` 인 경우는 "로그와 준비 흔적은 최근에 있었지만 실제 relay 진전은 멈춘 상태"로 읽으면 됩니다.
또 `RunRoot 준비`와 `준비 전체 실행`이 성공하면 output 영역에 같은 `[runroot 요약]` 블록을 한 번 자동으로 붙여 현재 기준선을 바로 확인할 수 있습니다.
또 `고정문구 / 순서 편집` 탭 우측의 `최종 전달문`, `경로 요약` 탭에서 현재 target 기준 완성 preview와 자동 주입 경로를 panel 안에서 바로 확인할 수 있습니다.
패널 재실행 후 complete pair만 남아 있으면 보드 탭 `열린 pair 재사용`으로 partial session을 다시 붙일 수 있습니다. 이 경우 attach/visibility 기대 개수는 전체 8개가 아니라 active pair scope 기준 `2/2`, `4/4`, `6/6`으로 표시됩니다.
summary 계약만 빠르게 다시 확인하려면 아래 wrapper를 사용합니다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-ShowPairedRunSummaryRegression.ps1
```

기존 live router가 오래 떠 있어 최신 설정 반영이 의심되면 아래처럼 fresh restart를 먼저 하거나, acceptance에서 `-ForceFreshRouter`를 같이 사용합니다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\router\Restart-RouterForConfig.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -AsJson
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-LiveVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live_acceptance -PairId pair01 -SeedTargetId target01 -ForceFreshRouter -AsJson
```

설정/폴더/문구 preview 확인:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-effective-config.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01
```

6. paired watcher 시작

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Watch-PairedExchange.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live
```

7. paired 상태 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-paired-exchange-status.ps1 -RunRoot .\pair-test\bottest-live-visible\run_live
```

외부 프로젝트 폴더에서 별도로 만든 review 결과물은 watcher가 자동 탐색하지 않습니다. paired exchange target 계약으로 넣으려면 아래 흐름을 사용합니다.

사전 검증:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-paired-exchange-artifact.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live -TargetId target01 -SummarySourcePath C:\work\summary.md -ReviewZipSourcePath C:\work\review.zip -AsJson
```

가져오기:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\import-paired-exchange-artifact.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_live -TargetId target01 -SummarySourcePath C:\work\summary.md -ReviewZipSourcePath C:\work\review.zip -AsJson
```

현재 target이 이미 `ready-to-forward`, `forwarded`, `error-present` 상태이거나 기존 contract 파일이 있으면 기본 import는 차단됩니다. 이 경우 preflight 결과를 확인한 뒤 명시적으로 `-Overwrite`를 추가해서만 가져올 수 있습니다.

`Start-PairedExchangeTest.ps1`가 새 target을 준비할 때는 각 target 폴더에 아래 wrapper도 같이 생성합니다.

- `check-artifact.ps1`, `check-artifact.cmd`
- `submit-artifact.ps1`, `submit-artifact.cmd`

visible/manual 흐름에서는 직접 paired contract 경로를 복사해서 맞추기보다, 작업 결과 source summary/source zip 경로만 넘겨서 이 wrapper로 검사 후 제출하는 쪽이 안전합니다.
repo 쪽에서 packaging한 zip은 source artifact일 뿐이고, 그 zip을 만들었다고 paired submit이 끝난 것은 아닙니다. paired submit은 panel, target-local wrapper, 또는 `import-paired-exchange-artifact.ps1`가 target folder contract에 `summary.txt`, `reviewfile`, `done.json`, `result.json`을 기록할 때만 완료됩니다.
새 RunRoot에서는 각 target 아래 `source-outbox`도 같이 만들어지고, 기본 흐름은 `source-outbox\summary.txt` + `source-outbox\review.zip` + `source-outbox\publish.ready.json`을 watcher가 감지해서 기존 `Import-PairedExchangeArtifact.ps1`를 자동 호출하는 방식입니다. 기존 `check/submit` wrapper와 panel submit은 legacy RunRoot 복구나 수동 recovery 용도로 유지합니다.
패널의 결과 / 산출물 탭도 새 RunRoot에서는 이 target-local wrapper를 우선 사용하고, 예전 RunRoot처럼 wrapper가 없으면 기존 root `check/import` 스크립트로 fallback 합니다.
`target submit 실행`이 fallback 경로를 타면 panel이 추가 확인을 한 번 더 요구하고, 같은 target에 아주 최근 submit 기록이 있으면 재실행 확인을 먼저 띄웁니다.
panel은 현재 RunRoot가 stale이거나 target-local wrapper가 없을 때 결과 / 산출물 상태줄에 강한 경고 배지를 같이 붙입니다.

운영 머신에서는 `start-targets.ps1 -ReplaceExisting`를 일상 복구 절차로 쓰지 않는 편이 안전합니다.

## paired 설정 계약

paired 테스트의 메시지/폴더 계약은 현재 운영 lane 기준 `config\settings.bottest-live-visible.psd1`의 `PairTest` 블록으로 관리합니다.

- `RunRootBase`, `RunRootPattern`
  `Start-PairedExchangeTest.ps1` 실행 시 `-RunRoot`를 생략하면 자동으로 새 run 폴더를 생성합니다.
- `SummaryFileName`, `ReviewFolderName`, `WorkFolderName`, `MessageFolderName`, `ReviewZipPattern`
  각 pair는 `pairXX\targetYY` 폴더를 만들고, summary/review/work/message 경로와 zip 파일명 규칙을 이 설정으로 통일합니다.
- `MessageTemplates.Initial`, `MessageTemplates.Handoff`
  초기 지시문과 handoff 지시문을 분리해서 `PrefixBlocks`, `SuffixBlocks`로 관리합니다.
- `PairOverrides`, `RoleOverrides`, `TargetOverrides`
  `InitialExtraBlocks`, `HandoffExtraBlocks`를 pair/role/target 우선순위로 합쳐서 최종 메시지를 만듭니다.

handoff 메시지에는 아래 정보가 항상 들어갑니다.

- `pair`, `from`, `to`
- `source folder`, `partner folder`
- `summary file`, `summary file name`
- `review zip file`, `review zip name`
- `review folder name`
- `SummaryPath`, `ReviewFolderPath`, `DoneFilePath`, `ResultFilePath`, `WorkFolderPath`
- `SourceOutboxPath`, `SourceSummaryPath`, `SourceReviewZipPath`, `PublishReadyPath`, `PublishedArchivePath`
- `CheckScriptPath`, `SubmitScriptPath`, `CheckCmdPath`, `SubmitCmdPath`

즉 paired 흐름은 이제 고정 문자열 하나가 아니라, 설정 기반 템플릿과 폴더 계약으로 관리합니다.

수동/외부 산출물 처리 규칙은 아래처럼 고정합니다.

- watcher는 현재 RunRoot 아래 각 target folder의 `summary.txt`, `reviewfile\*.zip`, `done.json` 계약만 읽습니다.
- watcher는 같은 루프 안에서 각 target의 `source-outbox\publish.ready.json`도 확인하고, marker가 엄격한 계약 검증을 통과하면 기존 import를 자동 호출해 contract folder로 publish 합니다.
- 일반 프로젝트의 별도 `target` 폴더는 자동 인식하지 않습니다.
- 외부 summary/zip는 먼저 `check-paired-exchange-artifact.ps1`로 검증하고, `import-paired-exchange-artifact.ps1`로 현재 RunRoot target folder에 가져옵니다.
- 외부 repo에서 만든 packaging zip은 source 입력입니다. watcher는 그 zip 자체를 보지 않고, import/submit 뒤 target folder에 기록된 contract 파일만 봅니다.
- `source-outbox` ready marker는 마지막에 생성해야 하며, 최소 `SchemaVersion`, `PairId`, `TargetId`, `SummaryPath`, `ReviewZipPath`, `PublishedAt`, `SummarySizeBytes`, `ReviewZipSizeBytes`를 포함해야 합니다. 선택 해시가 있으면 watcher가 실제 파일과 일치하는지 같이 검증합니다.
- 새 RunRoot를 준비하면 각 target 폴더 안에도 같은 본체를 호출하는 `check-artifact.*`, `submit-artifact.*` wrapper가 자동 생성됩니다.
- 결과 / 산출물 패널의 `target check 실행`, `target submit 실행`은 이 local wrapper를 우선 호출하고, 실행 후 paired status를 다시 읽습니다.
- 패널은 target별 마지막 source summary/zip 경로와 마지막 check/submit 결과를 메모해서 다음 실행과 상세 패널에 재사용합니다.
- 마지막 source summary/zip 경로는 `_tmp/artifact-source-memory.json` 에도 저장돼 panel 재실행 뒤에도 다시 제안됩니다.
- 이 source-memory 파일은 `SchemaVersion` 포함 JSON으로 저장되고, temp 파일 기록 뒤 rename 하는 방식으로 갱신합니다.
- source-memory JSON이 깨졌거나 읽기 실패가 나면 panel은 빈 메모리 상태로 복구하고 결과 / 산출물 상태줄에 warning badge를 표시합니다.
- panel은 같은 lane에 대해 한 번에 1개 인스턴스만 사용하는 것을 기본 운영 정책으로 둡니다. source-memory는 원자 저장되지만, 여러 panel을 동시에 띄우면 마지막 저장값이 우선합니다.
- import 명령은 `summary.txt`, `review zip`, `done.json`, `result.json`을 같이 기록해서 `summary-stale` 같은 시간차 문제를 줄입니다.
- `done.json`과 `result.json`에는 현재 import된 `LatestZipPath`가 기록되며, stale `error.json` 무시는 이 값이 현재 latest zip과 일치할 때만 성공 근거로 인정됩니다.
- `Start-PairedExchangeTest.ps1`가 생성하는 `instructions.txt`, `request.json`, `manifest.json`에는 각 target의 절대 `SummaryPath`, `ReviewFolderPath`, `WorkFolderPath`와 local `check/submit` wrapper 경로가 포함되며, 일반 프로젝트 폴더에만 파일을 만들면 watcher가 인식하지 않는다는 경고도 같이 적어 둡니다.

`show-effective-config.ps1`는 현재 config와 최신 run 문맥을 읽어서 아래를 한 번에 보여줍니다.

- lane / binding / launcher 메타
- 현재 선택된 run root와 다음 run root preview
- pair별 target 매핑
- `summary.txt`, `reviewfile`, `messages`, `request/done/error/result` 경로
- `source-outbox`, `publish.ready.json`, `.published` archive 경로
- pair/role/target override가 반영된 최종 initial/handoff 문구 preview
- initial/handoff 문구가 어떤 순서와 출처로 합쳐졌는지 보여주는 message plan
- 설정된 경로와 실제 존재 여부를 함께 보는 path state
- `PairTest.ExecutionPathMode`, `RequireUserVisibleCellExecution`, `AllowedWindowVisibilityMethods`
- submit sequence(`SubmitRetryModes`, `PrimarySubmitMode`, `FinalSubmitMode`, `SubmitRetryIntervalMs`)
- `SchemaVersion`, `GeneratedAt`, `PairDefinitionSource`, `PairDefinitionSourceDetail`, `PairTopologyStrategy`, `Warnings`, `ConfigHash`
- `WarningDetails`, `WarningSummary`, `RequestedFilters`, `SelectedRunRootIsStale`, `StaleRunThresholdSec`
- `EvidencePolicy`, `OperationalPolicy`

운영 의미는 아래처럼 고정합니다.

- `show-effective-config.ps1`의 warning은 실행 차단기가 아니라 `review` 신호입니다.
- 실제 하드 게이트는 `check-target-window-visibility.ps1`, `check-headless-exec-readiness.ps1` 같은 별도 검증 명령입니다.
- `EvidencePolicy.Recommended=true`일 때만 운영 증거 snapshot 저장을 기본 권장합니다.
- `_tmp\effective-config*.json`은 ad-hoc preview snapshot이고, 운영 증거 저장소는 `evidence\effective-config`입니다.

`relay_operator_panel.py`는 위 정보를 작은 Tkinter 운영 패널로 묶어 보여줍니다. 현재는 읽기/확인 중심 UI이며 source of truth는 `show-effective-config.ps1 -AsJson`입니다. 아래를 한 화면에서 확인할 수 있습니다.

- config / lane / binding / launcher 메타
- 최신 run root와 pair별 target 매핑
- initial / handoff preview
- relay status / paired status / visibility / headless readiness 명령 결과
- stale run / fallback pair 정의 / manifest 없음 같은 warning 상세
- 선택 row의 문구 조합 순서와 출처를 보는 `문구 구성` 탭
- 선택 row 기준 1회성 문구 대기 항목을 보는 `1회성 문구` 탭
- 선택 row 경로의 실제 존재 여부를 함께 보는 경로 상태
- 현재 effective config preview JSON 저장
- 선택 row 기준 `envelope.json` / `rendered.txt` preview 저장
- 선택된 pair의 headless 단일 왕복 드릴 실행
- 선택한 row의 target/review 폴더 열기와 summary 경로 복사
- `_tmp\effective-config*.json` 최근 20개 스냅샷의 stale/warnings 메타 조회, snapshot/run root 열기, 경로 복사, JSON 본문 확인
- typed-window 실테스트 기준선과 submit sequence 요약 표시
- 실행 중 `Operator Status`와 마지막 결과 요약 표시
- 실행 중 버튼 잠금으로 중복 클릭 방지

현재 panel은 운영 보조 UI로 유지합니다. 기존 `cleanup -> preflight-only -> active acceptance -> post-cleanup` 매크로 버튼은 공식 경로로 남기고, 앞으로 추가하는 분리 버튼은 pair01 기준 primitive 검증/디버깅용으로만 확장합니다. panel이 별도 상태를 만들지 않고 `show-effective-config.ps1 -AsJson`, receipt, status JSON을 그대로 읽는 구조를 유지합니다.

primitive helper도 같은 원칙으로 둡니다. `tests\Invoke-PairedExchangeOneShotSubmit.ps1`는 `Send-InitialPairSeedWithRetry.ps1 + show-paired-exchange-status.ps1`를 묶은 one-shot submit wrapper이고, `tests\Confirm-PairedExchangePublishPrimitive.ps1`와 `tests\Confirm-PairedExchangeHandoffPrimitive.ps1`는 target/pair 기준 publish, handoff 단계를 읽기 전용으로 판정하는 wrapper입니다. 셋 다 panel 전용 로직이 아니라 pair01 분리 단계와 이후 매크로 오케스트레이터가 같이 재사용할 공용 helper로만 유지합니다. 내부 row 판정과 acceptance reason 선택은 `tests\PairedExchangeConfig.ps1`의 shared helper를 같이 써서, panel과 macro의 publish/handoff/outcome 판단이 따로 벌어지지 않게 유지합니다.

운영 acceptance는 새 RunRoot 기준으로 닫습니다. 기본 acceptance 경로는 `source-outbox\summary.txt` + `source-outbox\review.zip` + `source-outbox\publish.ready.json` 생성 후 watcher가 자동 import 하고 다음 pair로 진행하는 흐름입니다. panel artifact check/submit 경로는 새 구조의 기본 흐름이 아니라 recovery/legacy 확인 경로로만 봅니다.
예전 RunRoot가 wrapper 생성 이전 계약으로 준비된 경우에는 panel local wrapper를 기대하지 말고, root `check-paired-exchange-artifact.ps1` / `import-paired-exchange-artifact.ps1`로 직접 복구합니다. repo에서 만든 packaging zip은 source artifact일 뿐이므로, 이 복구 submit을 하기 전에는 watcher가 다음 단계로 움직이지 않습니다.

운영 보관 기준은 짧게 아래로 고정합니다.

- `_tmp\rendered-messages`: 임시 preview 보관소, 최근 7일 또는 최근 50개 수준 유지
- `runtime\one-time-queue\<lane>\archive`: queue 감사 기록, 최근 30일 기준 정리
- `runtime\pair-activation\<lane>.json`: 현재 운영 상태 파일, 주기적 archive 대상이 아니라 현재값만 유지하고 만료/불필요 override만 정리
- `evidence\effective-config`: 승인/이상 run 근거 우선 보관, 일반 evidence는 최근 90일 기준 정리

panel에서 `Run Selected Pair Drill`을 누르면 현재 config/pair 기준으로 `run-headless-pair-drill.ps1`를 호출해 한 쌍만 자동 왕복합니다. 기본 동작은 `top target -> partner -> top target` 한 번 왕복이며, 성공 후 `RunRoot`가 panel에 자동 반영됩니다.

pair01만 바로 돌리려면 panel의 `pair01 Preset Drill` 버튼을 사용합니다. 이 버튼은 `run-preset-headless-pair-drill.ps1 -PairId pair01` preset shortcut을 호출하고, 현재 visible lane preset 기준으로 `target01 -> target05 -> target01` 한 번 왕복을 실행하며 preview 산출물도 같이 저장합니다.

Windows 더블클릭 preset 원클릭 실행:

- generic open wrapper: [open-preset-headless-pair-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-preset-headless-pair-drill.vbs)
- generic launch wrapper: [launch-preset-headless-pair-drill.cmd](C:\dev\python\hyukwoo\hyukwoo1\launch-preset-headless-pair-drill.cmd)
- generic preset runner: [run-preset-headless-pair-drill.ps1](C:\dev\python\hyukwoo\hyukwoo1\run-preset-headless-pair-drill.ps1)

pair01 shortcut은 아래처럼 위 공통 preset 경로에 위임합니다.

- [open-run-pair01-headless-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-run-pair01-headless-drill.vbs)
- 내부 shortcut 래퍼: [launch-run-pair01-headless-drill.cmd](C:\dev\python\hyukwoo\hyukwoo1\launch-run-pair01-headless-drill.cmd)
- preset shortcut runner: [run-pair01-headless-drill.ps1](C:\dev\python\hyukwoo\hyukwoo1\run-pair01-headless-drill.ps1)

즉 실제 preset 실행 체인은 `open-run-pair01-headless-drill.vbs -> open-preset-headless-pair-drill.vbs -> launch-preset-headless-pair-drill.cmd -> run-preset-headless-pair-drill.ps1 -PairId pair01` 입니다.

나머지 pair도 같은 형식의 원클릭 진입점을 사용합니다.

- `pair02`: [open-run-pair02-headless-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-run-pair02-headless-drill.vbs)
- `pair03`: [open-run-pair03-headless-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-run-pair03-headless-drill.vbs)
- `pair04`: [open-run-pair04-headless-drill.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-run-pair04-headless-drill.vbs)

현재 shared visible preset 데이터에서는 top target이 `target01`, `target02`, `target03`, `target04`, 대응 bottom target이 `target05`, `target06`, `target07`, `target08`으로 해석됩니다. 이 숫자는 preset 데이터이고, core pair resolution은 `PairDefinitions`/`DefaultPairId` 계약을 따릅니다.

pair별 운영 on/off는 정적 config를 직접 수정하지 않고 런타임 상태 파일로 관리합니다.

- 상태 파일: `runtime\pair-activation\bottest-live-visible.json`
- 비활성화: `disable-pair.ps1`
- 재활성화: `enable-pair.ps1`
- 빠른 상태 확인: `show-pair-activation-status.ps1`

실행기와 panel은 모두 같은 상태 파일을 읽고, 비활성 pair는 실행을 차단합니다.
운영자가 pair on/off만 빨리 볼 때는 `show-effective-config.ps1` 대신 `show-pair-activation-status.ps1`를 기본 조회기로 사용합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-pair-activation-status.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

선택 row 기준 최종 문구를 preview 산출물로 저장하려면 아래를 사용합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\render-pair-message.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -TargetId target01 -Mode both -WriteOutputs
```

기본 출력 위치는 `_tmp\rendered-messages\<lane>\<pair>\<target>\<timestamp>`이며, `initial.envelope.json`, `initial.rendered.txt`, `handoff.envelope.json`, `handoff.rendered.txt`를 생성합니다.

1회성 문구 큐는 고정문구와 분리해서 `runtime\one-time-queue\<lane>\<pair>.queue.json`에 저장합니다. 현재는 등록/조회와 preview 반영을 기본으로 하고, headless 실제 실행이 성공하면 해당 항목만 자동으로 `consumed` archive로 정리합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\enqueue-one-time-message.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -Role top -TargetId target01 -AppliesTo handoff -Placement one-time-prefix -Text "이번 1회에만 넣을 문구"
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-one-time-message-queue.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01
powershell -NoProfile -ExecutionPolicy Bypass -File .\cancel-one-time-message.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -ItemId <queue-item-id>
powershell -NoProfile -ExecutionPolicy Bypass -File .\cleanup-one-time-message-queue.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -State all
powershell -NoProfile -ExecutionPolicy Bypass -File .\consume-one-time-message.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -ItemId <queue-item-id>
```

취소된 항목은 queue 파일에서 `State=cancelled`, `Enabled=false`로 남고, archive 기록은 `runtime\one-time-queue\<lane>\archive\` 아래 JSON으로 따로 저장합니다. `show-one-time-message-queue.ps1 -State cancelled|expired`로 상태별 확인이 가능하고, `cleanup-one-time-message-queue.ps1`로 `cancelled/expired` 항목을 active queue에서 제거하면서 cleanup archive를 남길 수 있습니다.

headless 실제 실행이 성공하면 applicable 1회성 문구는 자동으로 `consumed` archive가 생성되고 active queue에서 제거됩니다. `consume-one-time-message.ps1`는 preview/live 상태가 꼬였을 때만 쓰는 예외 정리용 수동 명령입니다.

Windows에서 더블클릭으로 패널 실행:

- [open-relay-operator-panel.vbs](C:\dev\python\hyukwoo\hyukwoo1\open-relay-operator-panel.vbs)
- 내부 래퍼: [launch-relay-operator-panel.cmd](C:\dev\python\hyukwoo\hyukwoo1\launch-relay-operator-panel.cmd)
- 실제 실행 로직: [launch-relay-operator-panel.ps1](C:\dev\python\hyukwoo\hyukwoo1\launch-relay-operator-panel.ps1)

현재 기준으로 CMD/VBS 런처는 Windows에서 panel 프로세스 기동까지 확인했습니다. 실제 버튼 클릭과 화면 배치 확인은 운영자가 데스크톱에서 별도 점검합니다.

운영 증거 snapshot 저장:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\save-effective-config-evidence.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01
```

이 명령은 `EvidencePolicy.Recommended=true`인 상태에서만 기본 저장을 허용합니다. 경고 상태까지 일부러 남기려면 `-Force`를 사용합니다.

정책 드릴은 [OPERATIONS-DRILLS.md](C:\dev\python\hyukwoo\hyukwoo1\OPERATIONS-DRILLS.md)에 고정합니다. 현재 운영 해석은 다음 3줄이면 충분합니다.

- `Decision=none`: 진행
- `Decision=review`: 사람이 확인, evidence 기본 차단
- `Decision=block`: 절차 중단

## 빠른 시작

1. 기본 폴더/상태 파일 생성

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-relay.ps1
```

2. 설정 확인

설정 파일:

```text
C:\dev\python\hyukwoo\hyukwoo1\config\settings.psd1
```

3. 대상 창 확보

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ensure-targets.ps1
```

4. 이미 띄운 대상 창만 attach

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\attach-targets.ps1
```

5. attach 가능 여부만 진단

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ensure-targets.ps1 -DiagnosticOnly
```

6. 대상 창 새로 시작

예외/고급 용도입니다. 운영 기본 루틴은 `ensure-targets.ps1`입니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-targets.ps1
```

7. 라우터 시작

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\router.ps1
```

8. 상태 요약 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-relay-status.ps1
```

9. 실제 입력 가능 창 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-target-window-visibility.ps1
```

10. paired 상태 요약 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-paired-exchange-status.ps1
```

11. 적용 설정/문구/폴더 preview 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-effective-config.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01
```

12. binding 파일로 정확한 8개 창 attach

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\attach-targets-from-bindings.ps1 -ConfigPath .\config\settings.bottest-live.psd1
```

13. 테스트 메시지 생성

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\producer-example.ps1 -TargetId target02 -Text "target02 최소 검증 메시지"
```

14. 운영 패널 UI 실행

```powershell
python .\relay_operator_panel.py
```

Windows 더블클릭 진입:

```text
C:\dev\python\hyukwoo\hyukwoo1\open-relay-operator-panel.vbs
```

15. `show-effective-config` 출력 계약 점검

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-show-effective-config.ps1
```

## BotTest Visible 8창 Lane

기존 invisible `BotTest-Window-*` 세션이 남아 있거나, 실제 입력 가능한 새 visible 8창을 분리해서 승인하고 싶으면 아래 lane을 사용합니다.

운영 SSOT:
- `8창 열기`는 반드시 `LauncherWrapperPath` wrapper만 사용합니다.
- `기존 8창 재사용`은 launch가 아니라 attach-only 재사용입니다.
- `launcher\Start-Targets.ps1`, `launcher\Ensure-Targets.ps1`는 wrapper-managed lane에서 운영 경로가 아니라 maintenance 전용입니다.
- shared `bottest-live-visible` 실테스트는 반드시 **사용자가 보고 있는 셀창 안에서 직접 실행되는 typed-window 경로**만 사용합니다.
- `visible-worker`는 hidden/background 실행이므로 shared real-test 경로로 사용하지 않습니다.
- typed-window에서는 `send_complete` 나 `processed ready` 만으로 성공을 보지 않고, 기본 전송 계약도 `paste + submit guard + attempt당 1회 최종 submit` 으로 고정합니다. 그 뒤 `10초 no-progress probe` 와 `1회만` 허용된 재전송으로 실행 시작을 확인합니다.
- shared typed-window active run에서는 payload attempt 중간에 inline `/new` prepare submit을 허용하지 않습니다. `/new`는 bootstrap/recovery 단계에서만 허용하고, seed/handoff payload attempt는 항상 `전체 payload 1회 paste -> 마지막 1회 submit` 으로 끝나야 합니다.
- shared typed-window 실테스트에서는 대상 창 title에 `VISIBLE targetXX SENDING/RUNNING` 비콘이 실제로 보여야 하며, 이 비콘 없이 artifact/log만으로 `보이는 셀창 실행 성공`이라고 판단하지 않습니다.
- shared typed-window 실테스트에서는 submit 직전 다른 앱이 포커스를 가져가면 조용한 refocus 대신 즉시 실패로 닫습니다.
- shared typed-window 실테스트에서는 submit 직후 이전 활성 창으로 자동 복귀하지 않고, 대상 셀창을 잠시 전경에 유지해 운영자가 실제 전송 창을 눈으로 확인할 수 있어야 합니다.

1. 새 visible Codex 8창 기동

```powershell
python C:\Users\USER\s_8windows_left_monitor_codex_visible.py
```

2. binding 파일 기준 attach

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\attach-targets-from-bindings.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

3. visibility 하드 게이트

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-target-window-visibility.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
```

통과 기준:
- `Injectable: ok=8 fail=0`
- exit code `0`

4. 그 다음에만 relay 승인 절차 진행

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\router.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Manual-E2E-AllTargets.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1

shared 실테스트/acceptance는 위처럼 typed-window 경로를 통해 **실제 셀창에서 보이는 실행**으로만 진행합니다. `visible-worker` 경로는 maintenance/diagnostic 전용입니다.
```

### Internal Maintenance Only

아래 절차는 shared `bottest-live-visible` 운영 경로가 아니라 내부 정비/복구 전용입니다.

- `launcher\Start-Targets.ps1`
- `launcher\Ensure-Targets.ps1`
- `launcher\Refresh-Targets.ps1`

shared wrapper-managed lane에서는 위 스크립트를 운영 절차로 사용하지 않습니다. 운영자는 반드시:

1. UI `8창 열기` 또는 `LauncherWrapperPath` wrapper 실행
2. UI `기존 8창 재사용` 또는 `attach-targets-from-bindings.ps1`

만 사용합니다.

정비가 정말 필요할 때만 별도 maintenance 절차에서 아래 보호 규칙을 따릅니다.

- `start-targets.ps1 -ReplaceExisting`는 `-UnsafeForceKillManagedTargets`를 함께 줬을 때만 동작합니다.
- `start-targets.ps1 -ReplaceExisting -UnsafeForceKillManagedTargets`는 추가로 환경변수 `RELAY_ALLOW_UNSAFE_FORCE_KILL=1` 이 있어야만 동작합니다.
- `start-targets.ps1 -ReplaceExisting` 계열 시도는 `logs\unsafe-force-kill.log`에 JSON line으로 남습니다.
- `start-targets.ps1 -ReplaceExisting -UnsafeForceKillManagedTargets`는 runtime map에 `RegistrationMode='launched'`로 기록되고 `ShellStartTimeUtc`와 `ManagedMarker`가 모두 맞는 managed shell만 정리합니다. attached runtime이나 제목만 같은 기존 창은 죽이지 않고 실패합니다.

## Headless Codex Exec Lane

visible/AHK lane은 수동 검증과 관찰용으로 두고, 자동 실행 실험은 `codex exec` 기반 headless lane으로 별도 준비할 수 있습니다.

1. run root와 request 계약 준비

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-PairedExchangeTest.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01 -IncludePairId pair01
```

2. headless readiness 확인

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-headless-exec-readiness.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01
```

3. 단일 target dry-run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\invoke-codex-exec-turn.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01 -TargetId target01 -DryRun
```

headless lane은 각 target 폴더에 `request.json`, `done.json`, `error.json`, `result.json`, `headless-prompt.txt`, `codex-last-message.txt` 계약을 추가로 사용합니다.

4. pair01 한 쌍 자동 왕복

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-PairedExchangeTest.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01_auto -IncludePairId pair01 -SendInitialMessages -InitialTargetId target01 -UseHeadlessDispatch
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Watch-PairedExchange.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_headless_pair01_auto -UseHeadlessDispatch -MaxForwardCount 2
```

이미 준비된 `RunRoot`에 initial seed만 다시 넣어야 하면 `Start-PairedExchangeTest.ps1`를 다시 돌리지 말고 `tests\Send-InitialPairSeed.ps1`를 사용합니다.

위 조합은 `target01` initial turn을 headless로 먼저 실행한 뒤, watcher가 `target01 -> target05 -> target01` 두 번만 자동 forward 하고 멈춥니다. headless child 실행 로그는 `RunRoot\.state\headless-initial`, `RunRoot\.state\headless-dispatch`에 남습니다.

한 번에 묶은 단일 pair 운영 드릴:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-headless-pair-drill.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01
```

## 이번 보강에서 추가된 점

- launcher가 창을 직접 띄우고 `runtime\target-runtime.json`에 `TargetId/ShellPid/WindowPid/Hwnd/Title`을 기록합니다.
- sender는 `HWND -> WindowPid -> ShellPid -> Title` 순서로 fallback 합니다.
- 라우터는 `retry-pending` 분기와 실패 분류를 추가했습니다.
- payload 길이를 `MaxPayloadChars`와 `MaxPayloadBytes`로 제한합니다.
- `tests\Smoke-Test.ps1`로 최소 검증 루틴을 제공합니다.
- `tests\Manual-E2E-Target01.ps1`와 `tests\Manual-E2E-AllTargets.ps1`로 수동 승인 테스트를 제공합니다.
- launcher는 `WindowLookupRetryCount`, `WindowLookupRetryDelayMs`로 창 확보 재시도를 지원합니다.
- runtime map에는 `ResolvedBy`, `LookupSucceededAt`, `LauncherSessionId`, `LaunchedAt`, `LauncherPid`, `ProcessName`, `WindowClass`, `HostKind`를 기록합니다.
- runtime map에는 `RegistrationMode`, `ShellStartTimeUtc`, `ManagedMarker`를 추가로 기록해 launched/attached 구분과 안전한 cleanup 검증에 사용합니다.
- `ensure-targets.ps1`는 attach를 먼저 시도하고, 실패하면 cleanup 없이 새 target 창을 띄우는 단일 안전 진입점입니다.
- router는 `RouterMutexName` 기반 named mutex로 단일 실행을 보장합니다.
- router는 runtime map target id가 settings target 집합과 정확히 일치하는지 확인하고, 다르면 시작하지 않습니다.
- router는 runtime map의 `LauncherSessionId`가 blank 이거나 여러 값으로 섞여 있으면 시작하지 않습니다.
- router-state는 상태 변화가 있을 때만 다시 기록합니다.
- sender resolver는 runtime map에 blank/duplicate target id가 있으면 전송 전에 실패합니다.
- `check-target-window-visibility.ps1`는 runtime map 기준 창이 실제 top-level visible window로 잡히는지, sender fallback(`Hwnd -> WindowPid -> ShellPid -> Title`) 중 어느 경로로 입력 가능한지 승인 전에 확인합니다.
- `tests\Manual-E2E-AllTargets.ps1`는 전송 전에 runtime map target 집합과 핵심 메타데이터(`ResolvedBy/LookupSucceededAt/HostKind/LauncherSessionId`)를 먼저 검증하고, sender가 쓸 수 있는 locator(`Hwnd/WindowPid/ShellPid/Title`)가 하나 이상 있는지 확인합니다.
- `tests\Start-PairedExchangeTest.ps1`와 `tests\Watch-PairedExchange.ps1`는 `PairTest` 설정을 읽어 run root 자동 생성, target별 폴더 생성, 초기/handoff 메시지 템플릿 조합을 수행합니다.
- watcher 운영 명령은 `powershell.exe`가 아니라 `pwsh`로 고정합니다. acceptance 기준에서도 `powershell.exe -File .\tests\Watch-PairedExchange.ps1 ...`는 공식 경로가 아닙니다.
- Python relay panel도 `pwsh`가 없으면 명령 빌드를 막고 `powershell.exe` fallback으로 내려가지 않습니다.
- `show-paired-exchange-status.ps1`는 `PairTest` 설정 기준으로 summary/review/message 폴더 계약과 최신 run 상태를 함께 보여줍니다.
- 외부 launcher가 `runtime\window-bindings\*.json` 같은 binding 프로필을 남기면 `attach-targets-from-bindings.ps1`로 title 추론 없이 정확한 창 attach가 가능합니다.
- [settings.bottest-live-visible.psd1](C:\dev\python\hyukwoo\hyukwoo1\config\settings.bottest-live-visible.psd1)은 `BotTestLive-Window-*` 제목, 별도 runtime/log/router mutex, 별도 pair-test root를 써서 기존 invisible BotTest 세션과 승인 lane을 분리합니다.
- [s_8windows_left_monitor_codex_visible.py](C:\Users\USER\s_8windows_left_monitor_codex_visible.py)는 `BotTestLive-Window-*` 제목과 `runtime\window-bindings\bottest-live-visible.json` binding 파일로 새 visible Codex 8창을 띄우는 전용 래퍼입니다.
- `show-relay-status.ps1`는 config에 `LaneName`, `WindowTitlePrefix`, `BindingProfilePath`, `LauncherWrapperPath`가 있으면 lane 이름과 binding profile 메타를 같이 보여줍니다.

## 운영 메모

- 가장 안정적인 운영은 Windows Terminal 탭이 아니라 독립 `pwsh.exe` 창입니다.
- 운영 머신에서는 `ensure-targets.ps1`를 기본 진입점으로 사용하고, 이미 창이 떠 있으면 `attach-targets.ps1`를 우선 사용합니다.
- `ensure-targets.ps1 -DiagnosticOnly`는 attach 가능 여부만 진단하고 runtime map은 쓰지 않습니다.
- `ensure-targets.ps1 -DiagnosticOnly`와 `attach-targets.ps1 -DiagnosticOnly`는 missing/duplicate가 있으면 non-zero로 종료합니다.
- `target-runtime.json`이 없거나 8개 target이 모두 없으면 라우터는 실패합니다.
- `target-runtime.json`의 target id는 settings와 완전히 같아야 합니다. 개수만 맞고 id가 다르면 라우터가 실패합니다.
- `target-runtime.json`의 `LauncherSessionId`는 전 target에서 하나로 같아야 합니다. mixed session이나 blank session이면 라우터가 실패합니다.
- 파일명은 `timestamp + GUID` 형식을 사용합니다.
- `FixedSuffix = $null`은 전역 기본값 사용, `FixedSuffix = ''`는 suffix 없음입니다.
- resolver는 설정의 `ResolverShellPath`를 사용하고, 비어 있으면 PowerShell fallback을 탑니다.
- `attach-targets.ps1 -DiagnosticOnly`는 title/HWND/WindowPid/host kind를 확인만 하고 runtime map은 갱신하지 않습니다.
- `check-target-window-visibility.ps1`는 `attach 됨`과 `실제 입력 가능`을 분리해서 봅니다. binding-file attach가 성공해도 visible/input 가능 창이 없으면 이 단계에서 실패해야 합니다.
- 기존 invisible BotTest 세션이 남아 있으면 새 visible 세션은 `BotTestLive-Window-*` 같은 별도 prefix와 별도 config/runtime root로 분리하는 편이 안전합니다.
- `launcher\Refresh-Targets.ps1`와 수동 E2E의 `-StartTargets`는 attach 우선, 실패 시 cleanup 없는 새 launcher 기동으로 동작합니다.
- `router\Requeue-RetryPending.ps1`는 `retry-pending` 파일을 새 파일명으로 바꿔 원래 target inbox로 다시 넣습니다.
- `tests\Manual-E2E-AllTargets.ps1`는 target01~08 전체 수동 승인 테스트입니다.
- `tests\Smoke-Test.ps1 -UseTempRoot`를 사용하면 운영 루트와 분리된 임시 테스트 루트에서 smoke를 돌릴 수 있습니다.
- 기본 mutex 이름은 루트 leaf 기반입니다. 같은 PC에서 leaf가 같은 다른 루트를 함께 쓰면 `RouterMutexName`을 명시적으로 바꾸는 편이 안전합니다.

## 상태 확인

`show-relay-status.ps1`는 아래를 한 화면에 요약합니다.

- router 상태, pid, queue
- runtime map target 상태와 session 상태
- `processed`, `failed`, `retry-pending` 개수와 최근 파일
- 지금 바로 실행할 다음 명령 제안

자동화나 검증용으로 JSON이 필요하면 아래처럼 실행합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-relay-status.ps1 -AsJson
```

## 장애 대응

- mixed `LauncherSessionId`, blank session, target set mismatch가 보이면:
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\ensure-targets.ps1`
- attach할 창이 아직 없으면:
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\start-targets.ps1`
- `retry-pending` 파일이 쌓이면:
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\router\Requeue-RetryPending.ps1`
- 현재 상태를 먼저 한 번에 보고 싶으면:
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\show-relay-status.ps1`

`router\Start-Router.ps1`는 주요 시작 실패에서 `next:` 뒤에 다음 실행 명령을 같이 출력합니다.
