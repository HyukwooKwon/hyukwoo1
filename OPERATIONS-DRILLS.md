# Operations Drills

이 문서는 `show-effective-config`, preview snapshot, evidence snapshot 정책을 반복 검증할 때 쓰는 표준 드릴 절차입니다.

범위:

- `show-effective-config.ps1`
- `save-effective-config-evidence.ps1`
- `_tmp\effective-config*.json`
- `evidence\effective-config\*.json`

이 문서의 목적은 새 기능 추가가 아니라 **운영 판단 기준 고정**입니다.

## 해석 규칙

### Decision

- `none`
  정상 상태입니다. preview 확인 후 운영 절차를 계속 진행합니다.
- `review`
  즉시 차단은 아니지만 사람이 확인해야 하는 상태입니다. preview snapshot은 가능하고, evidence snapshot은 기본 차단입니다.
- `block`
  현재는 기본적으로 나오지 않지만, 추후 추가되면 운영 절차를 중단해야 합니다.

### EvidencePolicy

- `EvidencePolicy.Recommended=true`
  운영 증거 snapshot 기본 저장 가능 상태입니다.
- `EvidencePolicy.Recommended=false`
  운영 증거 snapshot 기본 저장 금지 상태입니다. 필요한 경우에만 `-Force`를 사용합니다.

### Snapshot 역할

- `_tmp\effective-config*.json`
  ad-hoc preview snapshot입니다. 확인용 임시 산출물이며 운영 증거 저장소가 아닙니다.
- `evidence\effective-config\*.json`
  운영 증거 snapshot입니다. 절차 기록과 회수 대상은 이 경로를 기준으로 봅니다.

## 기본값

- 기본 stale threshold는 `1800`초입니다.
- 전역 기본값을 우선 사용하고, 다른 threshold를 쓸 때는 실행 명령에 명시합니다.
- `check-target-window-visibility.ps1`, `check-headless-exec-readiness.ps1`는 warning과 별도의 하드 게이트입니다.

## 드릴 1. 정상 explicit run

목표:

- manifest-backed explicit run에서 `Decision=none`
- `EvidencePolicy.Recommended=true`
- evidence snapshot 기본 저장 가능

명령:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-effective-config.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_contract_evidence_20260330_183840_414 -PairId pair01
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\save-effective-config-evidence.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_contract_evidence_20260330_183840_414 -PairId pair01
```

판정:

- `PairDefinitionSource=manifest`
- `ManifestExists=True`
- `SelectedRunRootIsStale=False`
- `WarningSummary.HighestDecision=none`
- `EvidencePolicy.Recommended=True`

## 드릴 2. preview fallback run

목표:

- manifest 없는 preview run에서 `review`
- evidence snapshot 기본 저장 차단

명령:

```powershell
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$run = Join-Path '.\_tmp' ('drill_preview_' + $stamp)
New-Item -ItemType Directory -Path $run -Force | Out-Null
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-effective-config.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot $run -PairId pair01
```

판정:

- `PairDefinitionSource=fallback`
- `ManifestExists=False`
- `WarningSummary.HighestDecision=review`
- `WarningSummary.OrderedCodes`에 `manifest-missing`, `pair-definition-fallback` 포함
- `EvidencePolicy.Recommended=False`

## 드릴 3. stale 강제

목표:

- 정상 run도 stale threshold를 강제로 낮추면 `runroot-stale`로 바뀌는지 확인

명령:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\show-effective-config.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_contract_evidence_20260330_183840_414 -PairId pair01 -StaleRunThresholdSec 0
```

판정:

- `SelectedRunRootIsStale=True`
- `WarningSummary.HighestCode=runroot-stale`
- `EvidencePolicy.Recommended=False`

## 드릴 4. warned state evidence 기본 차단

목표:

- warned state에서는 `save-effective-config-evidence.ps1`가 기본 차단되는지 확인

명령:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\save-effective-config-evidence.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_contract_evidence_20260330_183840_414 -PairId pair01 -StaleRunThresholdSec 0
```

판정:

- non-zero 종료
- 오류 메시지에 `effective config evidence save is not recommended` 포함

## 드릴 5. warned state evidence 예외 저장

목표:

- warned state도 `-Force`일 때만 예외 저장되는지 확인

명령:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\save-effective-config-evidence.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot .\pair-test\bottest-live-visible\run_contract_evidence_20260330_183840_414 -PairId pair01 -StaleRunThresholdSec 0 -Force
```

판정:

- 저장 성공
- `Recommended=False`
- `ForceUsed=True`
- `ReasonCodes`에 `runroot-stale` 포함

## 드릴 6. preview / evidence 역할 분리

목표:

- preview snapshot과 evidence snapshot이 위치와 의미로 분리되는지 확인

명령:

```powershell
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
.\show-effective-config.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -PairId pair01 -AsJson | Set-Content -LiteralPath ('.\_tmp\effective-config.preview.pair01.' + $stamp + '.json') -Encoding utf8
Get-ChildItem .\_tmp -Filter 'effective-config*.json'
Get-ChildItem .\evidence\effective-config -Filter '*.json'
```

판정:

- preview 저장은 `_tmp`
- evidence 저장은 `evidence\effective-config`
- 두 경로를 같은 의미로 취급하지 않음

## 드릴 7. 실패 시 consume 금지

목표:

- headless 실제 실행이 실패하면 1회성 문구가 `consumed`로 가지 않는지 확인

명령:

```powershell
$config = '.\config\settings.bottest-live-visible.psd1'
$pairId = 'pair01'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$run = ".\pair-test\bottest-live-visible\run_pair01_failure_consume_$stamp"
.\cleanup-one-time-message-queue.ps1 -ConfigPath $config -PairId $pairId -State all | Out-Null
$item = .\enqueue-one-time-message.ps1 -ConfigPath $config -PairId $pairId -Role top -TargetId target01 -AppliesTo initial -Placement one-time-prefix -Text "[one-time failure drill $stamp]" -AsJson | ConvertFrom-Json
$oldPath = $env:PATH
$env:PATH = 'C:\Windows\System32;C:\Windows'
try {
    .\tests\Start-PairedExchangeTest.ps1 -ConfigPath $config -RunRoot $run -IncludePairId $pairId -InitialTargetId target01 -SendInitialMessages -UseHeadlessDispatch
}
catch {
    $_.Exception.Message
}
finally {
    $env:PATH = $oldPath
}
.\show-one-time-message-queue.ps1 -ConfigPath $config -PairId $pairId
.\cancel-one-time-message.ps1 -ConfigPath $config -PairId $pairId -ItemId $item.Item.Id
.\cleanup-one-time-message-queue.ps1 -ConfigPath $config -PairId $pairId -State all
```

판정:

참고:
- 이미 준비된 `RunRoot`에서 initial seed만 다시 보내야 할 때는 `Start-PairedExchangeTest.ps1`를 다시 실행하지 않고 `tests\Send-InitialPairSeed.ps1 -RunRoot <existing run> -TargetId target01` 경로를 사용합니다.

- initial headless 실행이 실패
- queue 항목이 active queue에 그대로 남음
- 새 `pair01.consumed.*.json`가 생기지 않음
- 정리 후 queue는 다시 비어 있음

## 드릴 8. Windows 런처 기동 확인

목표:

- `.cmd`와 `.vbs` 진입점이 panel 프로세스를 실제로 띄우는지 확인

명령:

```powershell
cmd /c .\launch-relay-operator-panel.cmd
wscript.exe //nologo .\open-relay-operator-panel.vbs
```

판정:

- 새 `relay_operator_panel.py` 프로세스가 생성됨
- 더블클릭/VBS 경로와 CMD 경로 모두 동일하게 panel을 띄움
- 실제 버튼 클릭과 시각 확인은 운영자가 Windows 데스크톱에서 별도 점검

## 드릴 9. source-outbox auto-publish acceptance

목표:

- 새 RunRoot에서 `source-outbox` 계약 경로가 실제로 생성되는지 확인
- `summary.txt + review.zip + publish.ready.json` 생성만으로 watcher auto import가 다음 단계까지 이어지는지 확인
- 첫 acceptance는 `target01`만 먼저 publish해서 `target01 -> target05` 순서를 확인

명령:

```powershell
$run = 'C:\dev\python\hyukwoo\hyukwoo1\pair-test\bottest-live-visible\run_source_outbox_acceptance_final'
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-PairedExchangeTest.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot $run -IncludePairId pair01
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Watch-PairedExchange.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot $run
```

```powershell
$outbox = Join-Path $run 'pair01\target01\source-outbox'
$summary = Join-Path $outbox 'summary.txt'
$zip = Join-Path $outbox 'review.zip'
$note = Join-Path $outbox 'note.txt'
$ready = Join-Path $outbox 'publish.ready.json'
'source-outbox acceptance summary' | Set-Content -LiteralPath $summary -Encoding utf8
'source-outbox zip note' | Set-Content -LiteralPath $note -Encoding utf8
Compress-Archive -LiteralPath $note -DestinationPath $zip -Force
$payload = [ordered]@{
    SchemaVersion = '1.0.0'
    PairId = 'pair01'
    TargetId = 'target01'
    SummaryPath = $summary
    ReviewZipPath = $zip
    PublishedAt = (Get-Date).ToString('o')
    SummarySizeBytes = [int64](Get-Item -LiteralPath $summary).Length
    ReviewZipSizeBytes = [int64](Get-Item -LiteralPath $zip).Length
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ready -Encoding utf8
```

판정:

- `pair01\target01`, `pair01\target05` 아래 `source-outbox`, `.published`, `check-artifact.*`, `submit-artifact.*` 존재
- `target01`의 ready marker 생성 후 watcher가 contract folder에 `summary.txt`, `reviewfile\*.zip`, `done.json`, `result.json`을 자동 생성
- `pair01\target01\source-outbox\.published\*.ready.json` archive 생성
- `show-paired-exchange-status.ps1 -AsJson`의 target01 `LatestState`가 `ready-to-forward` 또는 `forwarded`로 진행
- 첫 acceptance에서는 target05를 동시에 publish하지 않고, 자동 handoff 순서를 먼저 확인

## 드릴 10. legacy RunRoot 복구

목표:

- wrapper 생성 이전 RunRoot에서도 현재 source artifact를 paired target contract로 정상 제출할 수 있는지 확인

명령:

```powershell
$run = 'C:\dev\python\hyukwoo\hyukwoo1\pair-test\bottest-live-visible\run_controller_smoke_20260406_130511_324286'
$summary = 'C:\dev\python\bot-test\gptgpt1-dev\_tmp\dist-agent\review\frontend-backend-review-20260412\summary.txt'
$zip = 'C:\dev\python\bot-test\gptgpt1-dev\target\reviewfile\frontend-backend-review-20260412-submit.zip'
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-paired-exchange-artifact.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot $run -TargetId target01 -SummarySourcePath $summary -ReviewZipSourcePath $zip -AsJson
powershell -NoProfile -ExecutionPolicy Bypass -File .\import-paired-exchange-artifact.ps1 -ConfigPath .\config\settings.bottest-live-visible.psd1 -RunRoot $run -TargetId target01 -SummarySourcePath $summary -ReviewZipSourcePath $zip -AsJson
```

판정:

- preflight `Validation.Ok=True`
- `manual-copy-would-be-summary-stale` 경고가 보여도 import 경로는 계속 사용 가능
- import 후 legacy RunRoot target folder 아래 `summary.txt`, `reviewfile\*.zip`, `done.json`, `result.json` 생성
- watcher는 repo packaging zip 자체가 아니라 위 contract 파일들을 보고 다음 단계를 진행

## 종료선

아래가 반복해서 유지되면 이 범위는 종료해도 됩니다.

- 정상 explicit run에서 `Decision=none`
- preview fallback / stale에서 `Decision=review`
- warned state evidence 기본 차단
- `-Force` 예외 저장만 허용
- preview / evidence 저장 경로가 섞이지 않음

이 문서 이후의 우선순위는 기능 추가가 아니라, 위 드릴을 운영 절차에 맞춰 재현 가능하게 유지하는 것입니다.
