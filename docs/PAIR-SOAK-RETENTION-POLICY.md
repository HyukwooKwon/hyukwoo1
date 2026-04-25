# Pair Soak Retention Policy

This document fixes the minimum retention and cleanup expectations for `bottest-live-visible` shared visible soak runs.

## Scope

Applies to:

- `<run_root>\.state`
- visible worker logs
- archived ready markers
- soak receipts and closeout records
- failure logs created during shared visible soak runs

## Keep By Default

Keep these artifacts for the latest completed soak runs:

- `four-pair-soak-receipt.json`
- `four-pair-soak-closeout.json`
- `four-pair-soak-summary.txt`
- `watcher-status.json`
- `pair-state.json`
- watcher stdout/stderr logs created by the soak wrapper
- handoff failure logs when present

## Minimum Retention Guidance

Until a stricter ops policy is adopted, use these minimums:

- keep the latest `5` completed soak run roots
- keep the latest `20` watcher/visible-worker log files per shared visible lane
- keep failure logs for any failed soak run until the failure is reviewed
- keep the latest successful closeout record that was used to declare v1 status

## Cleanup Order

For shared visible lane cleanup, keep this order:

1. verify the run root is not the currently active shared visible run
2. keep receipt and closeout evidence for retained runs
3. clean queue/process leftovers with `visible\Cleanup-VisibleWorkerQueue.ps1`
4. archive or remove logs older than the current retention window
5. remove stale preview-only run roots that never produced a manifest-backed run

## Do Not Delete Before Review

Do not remove these before checking the corresponding receipt/closeout result:

- `handoff-failures.log`
- `four-pair-soak-receipt.json`
- `four-pair-soak-closeout.json`
- `four-pair-soak-summary.txt`
- `watcher-status.json`
- `pair-state.json`

## Related Commands

Plan the next soak:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-FourPairMixedSoak.ps1 -AsJson
```

Confirm closeout after a soak:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Confirm-FourPairMixedSoakCloseout.ps1 -RunRoot "<run_root>" -AsJson
```

Clean the shared visible worker lane:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\visible\Cleanup-VisibleWorkerQueue.ps1 `
  -ConfigPath .\config\settings.bottest-live-visible.psd1 `
  -TargetId target01,target02,target03,target04,target05,target06,target07,target08 `
  -KeepRunRoot "<run_root>" `
  -Apply `
  -AsJson
```
