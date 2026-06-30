from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import relay_panel_target_autoloop_presenter as presenter
import relay_panel_target_autoloop_runtime as runtime


class TargetAutoloopRetryPolicyTests(unittest.TestCase):
    def test_state_targets_override_stale_status_for_retry_current_detection(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            retry_root = tmp_path / "retry-pending"
            retry_root.mkdir()
            run_root = tmp_path / "run"
            old_ready = tmp_path / "inbox" / "target02" / "old.ready.txt"
            current_ready = tmp_path / "inbox" / "target02" / "current.ready.txt"
            current_ready.parent.mkdir(parents=True)

            status_targets = [
                {
                    "TargetId": "target02",
                    "CycleCount": 0,
                    "MaxCycleCount": 5,
                    "Phase": "idle",
                    "LastRouterReadyPath": str(old_ready),
                }
            ]
            state_targets = runtime.target_autoloop_state_targets(
                {
                    "Targets": {
                        "target02": {
                            "Enabled": True,
                            "CycleCount": 7,
                            "MaxCycleCount": 10,
                            "Phase": "queued",
                            "NextAction": "dispatch-command",
                            "LastRouterReadyPath": str(current_ready),
                        }
                    }
                }
            )
            merged_targets = runtime.target_autoloop_merge_status_targets(status_targets, state_targets)
            current_ready_map = {
                str(row.get("TargetId", "") or ""): str(row.get("LastRouterReadyPath", "") or "")
                for row in merged_targets
                if isinstance(row, dict) and str(row.get("LastRouterReadyPath", "") or "")
            }

            retry_file = retry_root / "target02__20260630_000000_000__current.ready.txt"
            retry_file.write_text(f"payload\nRunRoot: {run_root}", encoding="utf-8")
            (retry_file.with_suffix(retry_file.suffix + ".meta.json")).write_text(
                json.dumps(
                    {
                        "FailureCategory": "submit_unconfirmed",
                        "OriginalPath": str(current_ready),
                    }
                ),
                encoding="utf-8",
            )
            (retry_file.with_suffix(retry_file.suffix + ".delivery.json")).write_text(
                json.dumps({"TargetId": "target02", "RunRoot": str(run_root)}),
                encoding="utf-8",
            )

            summary = runtime.target_autoloop_retry_pending_summary(
                str(retry_root),
                target_ids=["target02"],
                scope_run_roots=[str(run_root)],
                current_ready_path_by_target_id=current_ready_map,
            )
            counts = runtime.target_autoloop_counts_from_targets(merged_targets)

        self.assertEqual(7, merged_targets[0]["CycleCount"])
        self.assertEqual(10, merged_targets[0]["MaxCycleCount"])
        self.assertEqual(str(current_ready), merged_targets[0]["LastRouterReadyPath"])
        self.assertEqual(1, summary["current_count"])
        self.assertEqual(0, summary["stale_count"])
        self.assertEqual(1, counts["QueuedTargets"])

    def test_retry_pending_summary_classifies_pre_input_focus_lost(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            retry_root = tmp_path / "retry-pending"
            retry_root.mkdir()
            run_root = tmp_path / "run"
            current_ready = tmp_path / "inbox" / "target01" / "message.ready.txt"
            current_ready.parent.mkdir(parents=True)
            debug_log = tmp_path / "focus-lost.log"
            debug_log.write_text("[test] text_pre_paste_focus_stolen_hard_fail active=Other\n", encoding="utf-8")

            retry_file = retry_root / "target01__20260630_000000_000__message.ready.txt"
            retry_file.write_text(f"payload\nRunRoot: {run_root}", encoding="utf-8")
            (retry_file.with_suffix(retry_file.suffix + ".meta.json")).write_text(
                json.dumps(
                    {
                        "FailureCategory": "focus_lost",
                        "FailureMessage": "AHK exit code: 42",
                        "DebugLogPath": str(debug_log),
                        "OriginalPath": str(current_ready),
                    }
                ),
                encoding="utf-8",
            )
            (retry_file.with_suffix(retry_file.suffix + ".delivery.json")).write_text(
                json.dumps({"TargetId": "target01", "RunRoot": str(run_root)}),
                encoding="utf-8",
            )

            summary = runtime.target_autoloop_retry_pending_summary(
                str(retry_root),
                target_ids=["target01"],
                scope_run_roots=[str(run_root)],
                current_ready_path_by_target_id={"target01": str(current_ready)},
            )

        self.assertEqual(1, summary["current_count"])
        self.assertEqual("pre-input", summary["latest_current_focus_lost_stage"])
        self.assertEqual("bounded-auto-retry-exhausted", summary["latest_current_focus_lost_retry_policy"])
        self.assertIn("입력 시작 전 포커스 이탈", summary["latest_current_operator_retry_hint"])

        detail = presenter.target_autoloop_retry_pending_detail({"retry_pending_summary": summary})
        self.assertIn("focusPolicy=bounded-auto-retry-exhausted", detail)
        self.assertIn("입력 시작 전 포커스 이탈", detail)

    def test_retry_pending_summary_classifies_post_input_focus_lost_as_duplicate_risk(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            retry_root = tmp_path / "retry-pending"
            retry_root.mkdir()
            run_root = tmp_path / "run"
            current_ready = tmp_path / "inbox" / "target01" / "message.ready.txt"
            current_ready.parent.mkdir(parents=True)
            debug_log = tmp_path / "focus-lost.log"
            debug_log.write_text(
                "[test] terminal_input_mode mode=paste\n[test] submit_precheck mode=enter index=1/1\n",
                encoding="utf-8",
            )

            retry_file = retry_root / "target01__20260630_000000_000__message.ready.txt"
            retry_file.write_text(f"payload\nRunRoot: {run_root}", encoding="utf-8")
            (retry_file.with_suffix(retry_file.suffix + ".meta.json")).write_text(
                json.dumps(
                    {
                        "FailureCategory": "focus_lost",
                        "FailureMessage": "AHK exit code: 42",
                        "DebugLogPath": str(debug_log),
                        "OriginalPath": str(current_ready),
                    }
                ),
                encoding="utf-8",
            )
            (retry_file.with_suffix(retry_file.suffix + ".delivery.json")).write_text(
                json.dumps({"TargetId": "target01", "RunRoot": str(run_root)}),
                encoding="utf-8",
            )

            summary = runtime.target_autoloop_retry_pending_summary(
                str(retry_root),
                target_ids=["target01"],
                scope_run_roots=[str(run_root)],
                current_ready_path_by_target_id={"target01": str(current_ready)},
            )

        self.assertEqual("post-input-or-submit", summary["latest_current_focus_lost_stage"])
        self.assertEqual("manual-review-duplicate-risk", summary["latest_current_focus_lost_retry_policy"])
        self.assertIn("중복 전송 위험", summary["latest_current_operator_retry_hint"])

    def test_retry_pending_summary_classifies_post_submit_send_failed_as_duplicate_risk(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            retry_root = tmp_path / "retry-pending"
            retry_root.mkdir()
            run_root = tmp_path / "run"
            current_ready = tmp_path / "inbox" / "target08" / "message.ready.txt"
            current_ready.parent.mkdir(parents=True)
            debug_log = tmp_path / "send-failed.log"
            debug_log.write_text(
                "[test] terminal_input_mode mode=paste\n"
                "[test] terminal_paste bytes=42\n"
                "[test] submit_attempt mode=enter index=1/1\n"
                "[test] submit_after_dispatch mode=enter index=1/1\n"
                "[test] send_exception message=simulated\n",
                encoding="utf-8",
            )

            retry_file = retry_root / "target08__20260630_000000_000__message.ready.txt"
            retry_file.write_text(f"payload\nRunRoot: {run_root}", encoding="utf-8")
            (retry_file.with_suffix(retry_file.suffix + ".meta.json")).write_text(
                json.dumps(
                    {
                        "FailureCategory": "send_failed",
                        "FailureMessage": f"AHK exit code: 40 debugLog={debug_log}",
                        "DebugLogPath": str(debug_log),
                        "OriginalPath": str(current_ready),
                    }
                ),
                encoding="utf-8",
            )
            (retry_file.with_suffix(retry_file.suffix + ".delivery.json")).write_text(
                json.dumps({"TargetId": "target08", "RunRoot": str(run_root)}),
                encoding="utf-8",
            )

            summary = runtime.target_autoloop_retry_pending_summary(
                str(retry_root),
                target_ids=["target08"],
                scope_run_roots=[str(run_root)],
                current_ready_path_by_target_id={"target08": str(current_ready)},
            )

        self.assertEqual("post-submit-dispatch", summary["latest_current_send_stage"])
        self.assertEqual("manual-review-duplicate-risk", summary["latest_current_send_retry_policy"])
        self.assertIn("이미 전송", summary["latest_current_operator_retry_hint"])


if __name__ == "__main__":
    unittest.main()
