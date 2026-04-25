# Pair v1 Closeout Criteria

This document freezes the current v1 contract for the `bottest-live-visible` 4pair watcher lane.

## Frozen v1 Structure

Do not widen these semantics during soak validation unless a defect requires it.

- `PairDefinitions` and `PairPolicies` are the config source of truth for pair topology and default policy.
- `pair-state.json` is the persisted pair progress source of truth.
- `CurrentPhase` and `NextExpectedHandoff` use the canonical phase normalization rules already enforced by watcher/status/panel.
- watcher control semantics stay `pause`, `resume`, `stop`.
- watcher roundtrip limit semantics stay `per pair`.
- shared visible execution stays on the official 8 windows only.

## Required Shared Visible Constraints

- Official windows only:
  - `BotTestLive-Window-01`
  - `BotTestLive-Window-02`
  - `BotTestLive-Window-03`
  - `BotTestLive-Window-04`
  - `BotTestLive-Window-05`
  - `BotTestLive-Window-06`
  - `BotTestLive-Window-07`
  - `BotTestLive-Window-08`
- Forbidden ad-hoc windows:
  - `BotTestLive-Fresh-*`
  - `BotTestLive-Surrogate-*`
  - `BotTestLive-Candidate-*`
- Official active visible path:
  - `visible worker queue -> Invoke-CodexExecTurn -> source-outbox publish -> watcher handoff`
- If active visible acceptance is run separately, keep the order:
  - `cleanup -> preflight-only -> active acceptance -> post-cleanup`

## Required v1 Signoff Checks

These are the minimum checks before calling the current design "v1 closed".

1. Contract regression passes.
2. Shared visible 4pair mixed soak wrapper is prepared in plan mode and reviewed.
3. Shared visible mixed soak is run manually on the official 8-window lane.
4. Crash/stale recovery drill is run and matches the documented recovery path.
5. Final pair-state, watcher-status, status receipt, and panel summary agree on the same run root.

## Contract Regression Baseline

These tests lock the current cross-layer contract.

- `tests\Test-WatcherPauseResumeContract.ps1`
- `tests\Test-WatcherPairRoundtripLimit.ps1`
- `tests\Test-WatcherPerPairPolicyRoundtripLimit.ps1`
- `tests\Test-WatcherPolicyRoundtripLimitStop.ps1`
- `tests\Test-WatcherFourPairMixedOperationalContract.ps1`
- `tests\Test-WatcherCrashRecoveryAutomation.ps1`
- `tests\Test-ShowPairedExchangeStatusMixedPairStates.ps1`
- `tests\Test-ShowPairedExchangeStatusPairStatePreference.ps1`
- `tests\Test-ShowPairedExchangeStatusPairPhaseNormalization.ps1`
- `tests\Test-ShowEffectiveConfig.ps1`

## Shared Visible Soak Wrapper

Use `tests\Run-FourPairMixedSoak.ps1` as the operational wrapper for the live soak lane.

Plan only:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-FourPairMixedSoak.ps1 `
  -ConfigPath .\config\settings.bottest-live-visible.psd1 `
  -RunRoot "<run_root>" `
  -AsJson
```

Execute on the official shared visible lane:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-FourPairMixedSoak.ps1 `
  -ConfigPath .\config\settings.bottest-live-visible.psd1 `
  -RunRoot "<run_root>" `
  -Execute `
  -AsJson
```

Execute and run closeout confirmation immediately after the soak:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-FourPairMixedSoak.ps1 `
  -ConfigPath .\config\settings.bottest-live-visible.psd1 `
  -RunRoot "<run_root>" `
  -Execute `
  -AutoCloseoutConfirm `
  -KnownLimitationsReviewed `
  -KnownLimitationsReviewNote "shared visible official 8-window check completed" `
  -AsJson
```

Default soak scenario markers in the wrapper:

- pause request at `+15` minutes
- resume request at `+18` minutes
- one watcher stop/restart at `+30` minutes
- final stop and post-cleanup at soak end

Default numeric thresholds recorded in the wrapper receipt:

- `MinRequiredSoakDurationMinutes = 60`
- `MaxAllowedManualAttentionCount = 4`
- `MaxAllowedWatcherRestartCount = 1`
- `MaxAllowedPauseRequestCount = 1`
- `MaxAllowedResumeRequestCount = 1`
- `MinRequiredSnapshotCount = 3`
- `RequiredFinalWatcherStatus = stopped`

## Required Soak Receipt Checks

The soak receipt is written to:

- `<run_root>\.state\four-pair-soak-receipt.json`

Minimum receipt checks:

- `Execution.Summary.FinalWatcherStatus`
- `Execution.Summary.FinalPairs[*].CurrentPhase`
- `Execution.Summary.FinalPairs[*].RoundtripCount`
- `Execution.Summary.FinalPairs[*].NextExpectedHandoff`
- `Execution.Summary.MaxManualAttentionCount`
- `Execution.Summary.MaxHandoffReadyCount`
- `Execution.Summary.MaxForwardedStateCount`
- `Execution.Summary.PauseRequestCount`
- `Execution.Summary.ResumeRequestCount`
- `Execution.Summary.WatcherRestartCount`
- `Execution.Summary.ThresholdEvaluation`

Recommended post-soak confirmation:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Confirm-FourPairMixedSoakCloseout.ps1 `
  -ConfigPath .\config\settings.bottest-live-visible.psd1 `
  -RunRoot "<run_root>" `
  -AsJson
```

The closeout confirmation writes:

- `<run_root>\.state\four-pair-soak-closeout.json`
- `<run_root>\.state\four-pair-soak-summary.txt`

## Recovery Signoff

Manual recovery steps are documented in:

- [PAIR-WATCHER-RECOVERY-DRILL.md](./PAIR-WATCHER-RECOVERY-DRILL.md)

Automated recovery regression:

- `tests\Test-WatcherCrashRecoveryAutomation.ps1`

## Retention Policy

Soak artifact retention is documented separately:

- [PAIR-SOAK-RETENTION-POLICY.md](./PAIR-SOAK-RETENTION-POLICY.md)

## Known Limitations

These are intentionally fixed for v1 and should not be described as solved by the structural work alone.

- Shared visible long-run stability still depends on real 8-window soak validation.
- Focus loss, AHK input delay, title drift, and per-window input faults are operational risks, not solved by watcher-state structure alone.
- `manual-attention` remains an operator intervention state.
- v1 closeout should not claim a measured soak duration unless the corresponding live receipt exists.
