# Pair Watcher Recovery Drill

이 문서는 `bottest-live-visible` shared lane 기준 pair watcher 복구 절차를 정리한다.

## 원칙

- shared visible lane에서는 공식 운영 8창만 사용한다.
- 임시 창(`BotTestLive-Fresh-*`, `BotTestLive-Surrogate-*`, `BotTestLive-Candidate-*`)은 사용하지 않는다.
- active visible acceptance 전후 순서는 항상 `cleanup -> preflight-only -> active acceptance -> post-cleanup` 이다.
- 정식 자동 경로는 `visible worker queue -> Invoke-CodexExecTurn -> source-outbox publish -> watcher handoff` 이다.

## 빠른 상태 확인

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Show-PairedExchangeStatus.ps1 `
  -ConfigPath .\config\settings.bottest-live-visible.psd1 `
  -RunRoot "<run_root>" `
  -AsJson
```

우선 확인할 필드:

- `Watcher.Status`
- `Watcher.StatusReason`
- `Watcher.ControlPendingAction`
- `Pairs[*].CurrentPhase`
- `Pairs[*].NextExpectedHandoff`
- `PairState.SchemaStatus`
- `PairState.Warnings`

## 상황별 복구

### 1. 다음 소비만 멈추고 싶을 때

`pause`는 in-flight child를 강제 종료하지 않고, 다음 handoff/claim만 멈춘다.

```powershell
@{
  SchemaVersion = '1.0.0'
  RequestedAt   = (Get-Date).ToString('o')
  RequestedBy   = 'manual-recovery'
  Action        = 'pause'
  RunRoot       = '<run_root>'
  RequestId     = [guid]::NewGuid().ToString()
} | ConvertTo-Json -Depth 4 | Set-Content .\<run_root>\.state\watcher-control.json -Encoding UTF8
```

확인 기준:

- `Watcher.Status = paused`
- `Pairs[*].CurrentPhase = paused` 또는 pair별 기존 phase 유지 + next claim 중지

### 2. pause 뒤 다시 이어갈 때

```powershell
@{
  SchemaVersion = '1.0.0'
  RequestedAt   = (Get-Date).ToString('o')
  RequestedBy   = 'manual-recovery'
  Action        = 'resume'
  RunRoot       = '<run_root>'
  RequestId     = [guid]::NewGuid().ToString()
} | ConvertTo-Json -Depth 4 | Set-Content .\<run_root>\.state\watcher-control.json -Encoding UTF8
```

확인 기준:

- `Watcher.Status = running`
- `Watcher.ControlPendingAction = ''`
- head queued command부터 다시 소진

### 3. watcher를 멈추고 상태만 보존할 때

```powershell
@{
  SchemaVersion = '1.0.0'
  RequestedAt   = (Get-Date).ToString('o')
  RequestedBy   = 'manual-recovery'
  Action        = 'stop'
  RunRoot       = '<run_root>'
  RequestId     = [guid]::NewGuid().ToString()
} | ConvertTo-Json -Depth 4 | Set-Content .\<run_root>\.state\watcher-control.json -Encoding UTF8
```

확인 기준:

- `Watcher.Status = stopped`
- `Watcher.LastHandledAction = stop`
- `Watcher.ControlPendingAction = ''`

### 4. stale control file가 남았을 때

먼저 status를 보고 `Watcher.Status` 가 이미 `stopped` 또는 `running` 인데 `ControlPendingAction` 만 오래 남아 있는지 확인한다.

정리 순서:

1. watcher 프로세스가 실제로 살아 있는지 status/mutex로 확인한다.
2. 이미 처리된 오래된 request라면 `watcher-control.json` 을 삭제한다.
3. 다시 `Show-PairedExchangeStatus.ps1` 로 pending action 이 사라졌는지 확인한다.

### 5. shared visible acceptance를 다시 닫아야 할 때

아래 순서를 유지한다.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-LiveVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot "<run_root>" -PairId pair01 -PreflightOnly -AsJson
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-LiveVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot "<run_root>" -PairId pair01 -AsJson
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Confirm-SharedVisiblePairAcceptance.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot "<run_root>" -AsJson
```

## 운영 팁

- `PairState.SchemaStatus` 가 `legacy-missing` 또는 `unsupported` 면 먼저 상태 파일 형식을 점검한다.
- `Pairs[*].CurrentPhase = manual-attention` 이면 resume보다 산출물/error 상태 확인이 우선이다.
- `Pairs[*].CurrentPhase = limit-reached` 면 start/resume 전에 의도한 roundtrip limit 이 맞는지 먼저 확인한다.

## 자동화 회귀

- `tests\Test-WatcherPauseResumeContract.ps1`
- `tests\Test-WatcherFourPairMixedOperationalContract.ps1`
- `tests\Test-WatcherCrashRecoveryAutomation.ps1`
