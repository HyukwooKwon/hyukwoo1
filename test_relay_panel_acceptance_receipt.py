from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from relay_panel_acceptance_receipt import (
    acceptance_receipt_path_for_run_root,
    acceptance_receipt_summary_indicates_success,
    empty_acceptance_receipt_summary,
    empty_acceptance_relay_issue_fields,
    format_acceptance_phase_history_lines,
    format_acceptance_receipt_detail_lines,
    format_acceptance_receipt_section_lines,
    format_acceptance_relay_issue_detail_parts,
    load_acceptance_receipt_summary_from_path,
    load_acceptance_receipt_summary_from_run_root,
    resolve_acceptance_receipt_workflow_flags,
    summarize_acceptance_receipt_payload,
    summarize_acceptance_relay_issue_fields,
    visible_confirm_payload_passed,
    visible_receipt_confirm_payload_passed,
)


class AcceptanceReceiptRelayIssueTests(unittest.TestCase):
    def test_acceptance_receipt_path_for_run_root_uses_state_receipt_file(self) -> None:
        self.assertEqual(
            r"C:\runs\current\.state\live-acceptance-result.json",
            acceptance_receipt_path_for_run_root(r"C:\runs\current"),
        )

    def test_empty_acceptance_receipt_summary_includes_receipt_and_relay_defaults(self) -> None:
        summary = empty_acceptance_receipt_summary(path="C:\\runs\\a\\.state\\receipt.json", exists=True, parse_error="bad-json")

        self.assertEqual("C:\\runs\\a\\.state\\receipt.json", summary["Path"])
        self.assertEqual("true", summary["Exists"])
        self.assertEqual("bad-json", summary["ParseError"])
        self.assertEqual("", summary["Stage"])
        self.assertEqual("false", summary["HasSuccessHistory"])
        self.assertEqual("", summary["RelayIssueSummary"])
        self.assertEqual("", summary["VisibleProofGrade"])

    def test_summarize_acceptance_receipt_payload_tracks_history_and_fallbacks(self) -> None:
        summary = summarize_acceptance_receipt_payload(
            {
                "Stage": "shared-confirm",
                "PreflightPassed": True,
                "ActiveAttempted": True,
                "PostCleanupDone": False,
                "CleanPreflightPassed": False,
                "LastUpdatedAt": "2026-05-10T12:00:00+09:00",
                "GeneratedAt": "2026-05-10T12:00:01+09:00",
                "BlockedBy": "foreign-queued-command",
                "BlockedTargetId": "target01",
                "BlockedRunRoot": "C:\\runs\\foreign",
                "BlockedPath": "C:\\runtime\\queue\\target01\\processing\\command.json",
                "BlockedDetail": "queued command from target05",
                "Outcome": {},
                "PhaseHistory": [
                    {"Stage": "preflight-only", "AcceptanceState": "preflight-passed"},
                    {"Stage": "active-acceptance", "AcceptanceState": "pending"},
                    {"Stage": "shared-confirm", "AcceptanceState": "roundtrip-confirmed"},
                ],
            },
            path="C:\\runs\\a\\.state\\receipt.json",
            exists=True,
            parse_error="",
            last_write_at="2026-05-10T12:00:02+09:00",
            fallback_acceptance_state="pending",
            fallback_acceptance_reason="awaiting receipt",
        )

        self.assertEqual("2026-05-10T12:00:02+09:00", summary["LastWriteAt"])
        self.assertEqual("2026-05-10T12:00:00+09:00", summary["LastUpdatedAt"])
        self.assertEqual("2026-05-10T12:00:01+09:00", summary["GeneratedAt"])
        self.assertEqual("pending", summary["AcceptanceState"])
        self.assertEqual("awaiting receipt", summary["AcceptanceReason"])
        self.assertEqual("foreign-queued-command", summary["BlockedBy"])
        self.assertEqual("3", summary["PhaseHistoryCount"])
        self.assertEqual(
            "preflight-only:preflight-passed -> active-acceptance:pending -> shared-confirm:roundtrip-confirmed",
            summary["PhaseHistoryTail"],
        )
        self.assertEqual("true", summary["HasSuccessHistory"])
        self.assertEqual("true", summary["HasActiveHistory"])
        self.assertEqual("roundtrip-confirmed", summary["LastSuccessAcceptanceState"])
        self.assertEqual("true", summary["PreflightPassed"])
        self.assertEqual("true", summary["ActiveAttempted"])
        self.assertEqual("false", summary["PostCleanupDone"])
        self.assertEqual("false", summary["CleanPreflightPassed"])

    def test_summarize_acceptance_receipt_payload_surfaces_visible_proof_grade(self) -> None:
        summary = summarize_acceptance_receipt_payload(
            {
                "Stage": "typed-window-bootstrap-failed",
                "RecoveryAttemptCount": 1,
                "LastRecoveryAction": "focus-recovery-retry",
                "LastRecoveryResult": "manual_attention_required",
                "LastRecoveryTargetId": "target01",
                "LastRecoveryReason": "visible-bootstrap-focus-steal",
                "VisibleProofGrade": "focus-steal-blocked",
                "VisibleProofGradeReason": "visible-bootstrap-focus-steal",
                "Outcome": {
                    "AcceptanceState": "manual_attention_required",
                    "AcceptanceReason": "visible-bootstrap-focus-steal",
                },
            },
            path="C:\\runs\\a\\.state\\receipt.json",
        )
        lines = format_acceptance_receipt_section_lines(summary, include_history=True)
        text = "\n".join(lines)

        self.assertEqual("focus-steal-blocked", summary["VisibleProofGrade"])
        self.assertIn("visibleProofGrade=focus-steal-blocked", text)
        self.assertIn("recovery=1 action=focus-recovery-retry result=manual_attention_required target=target01", text)

    def test_summarize_acceptance_receipt_payload_surfaces_preflight_active_window(self) -> None:
        summary = summarize_acceptance_receipt_payload(
            {
                "Stage": "completed",
                "PreflightPassed": True,
                "Preflight": {
                    "ActiveWindowSnapshot": "title=BlueStacks App Player process=HD-Player.exe",
                    "ActiveWindowSummary": "title=BlueStacks App Player process=HD-Player.exe",
                    "ActiveWindowIsOfficialTarget": False,
                    "ActiveWindowTargetId": "",
                },
                "Outcome": {
                    "AcceptanceState": "preflight-passed",
                    "AcceptanceReason": "typed-window visibility passed",
                },
            },
            path="C:\\runs\\a\\.state\\receipt.json",
        )
        lines = format_acceptance_receipt_section_lines(summary, include_history=True)
        text = "\n".join(lines)

        self.assertEqual("title=BlueStacks App Player process=HD-Player.exe", summary["ActiveWindowSummary"])
        self.assertEqual("false", summary["ActiveWindowIsOfficialTarget"])
        self.assertIn("ActiveWindow: title=BlueStacks App Player process=HD-Player.exe", text)
        self.assertIn("ActiveWindowOfficialTarget: false", text)

    def test_summarize_acceptance_relay_issue_fields_preserves_zero_counts(self) -> None:
        summary = summarize_acceptance_relay_issue_fields(
            {
                "RelayFolderMismatchCount": 1,
                "RelayFolderMissingCount": 0,
                "RelayFolderConfigMissingCount": 0,
                "RelayIssueSummary": "relay-folder-mismatch:1",
                "Source": "current-receipt",
            }
        )

        self.assertEqual("1", summary["RelayFolderMismatchCount"])
        self.assertEqual("0", summary["RelayFolderMissingCount"])
        self.assertEqual("0", summary["RelayFolderConfigMissingCount"])
        self.assertEqual("relay-folder-mismatch:1", summary["RelayIssueSummary"])
        self.assertEqual("current-receipt", summary["RelayIssuesSource"])

    def test_format_acceptance_relay_issue_detail_parts_uses_canonical_text(self) -> None:
        detail_parts = format_acceptance_relay_issue_detail_parts(
            {
                **empty_acceptance_relay_issue_fields(),
                "RelayFolderMismatchCount": "1",
                "RelayFolderMissingCount": "0",
                "RelayFolderConfigMissingCount": "0",
                "RelayIssueSummary": "relay-folder-mismatch:1",
                "RelayIssuesSource": "current-receipt",
            }
        )

        self.assertEqual(
            [
                "relay=relay-folder-mismatch:1",
                "relayMismatch=1 relayMissing=0 relayConfigMissing=0",
                "relaySource=current-receipt",
            ],
            detail_parts,
        )

    def test_format_acceptance_receipt_detail_lines_uses_canonical_receipt_section_text(self) -> None:
        lines = format_acceptance_receipt_detail_lines(
            {
                "BlockedBy": "foreign-queued-command",
                "BlockedTargetId": "target01",
                "BlockedRunRoot": r"C:\runs\foreign",
                "BlockedPath": r"C:\runtime\queue\target01\processing\command.json",
                "BlockedDetail": "queued command from target05",
                "PhaseHistoryCount": "3",
                "PhaseHistoryTail": "a -> b -> c",
                "RelayFolderMismatchCount": "1",
                "RelayFolderMissingCount": "0",
                "RelayFolderConfigMissingCount": "0",
                "RelayIssueSummary": "relay-folder-mismatch:1",
                "RelayIssuesSource": "current-receipt",
            },
            include_blocked_target=True,
            include_blocked_run_root=True,
            include_blocked_path=True,
            include_history=True,
            relay_prefix="Receipt",
        )

        self.assertEqual(
            [
                "BlockedBy: foreign-queued-command",
                "BlockedTargetId: target01",
                r"BlockedRunRoot: C:\runs\foreign",
                r"BlockedPath: C:\runtime\queue\target01\processing\command.json",
                "BlockedDetail: queued command from target05",
                "Receipt relay=relay-folder-mismatch:1",
                "Receipt relayMismatch=1 relayMissing=0 relayConfigMissing=0",
                "Receipt relaySource=current-receipt",
                "PhaseHistoryCount: 3",
                "PhaseHistoryTail: a -> b -> c",
            ],
            lines,
        )

    def test_format_acceptance_receipt_section_lines_renders_header_and_detail_lines(self) -> None:
        lines = format_acceptance_receipt_section_lines(
            {
                "Path": r"C:\runs\a\.state\receipt.json",
                "Stage": "preflight-blocked",
                "AcceptanceState": "error",
                "AcceptanceReason": "preflight blocked",
                "LastUpdatedAt": "2026-05-10T13:50:00+09:00",
                "BlockedBy": "foreign-queued-command",
                "BlockedTargetId": "target01",
                "BlockedRunRoot": r"C:\runs\foreign",
                "BlockedPath": r"C:\runtime\queue\target01\processing\command.json",
                "BlockedDetail": "queued command from target05",
                "PhaseHistoryCount": "3",
                "PhaseHistoryTail": "a -> b -> c",
                "RelayFolderMismatchCount": "1",
                "RelayFolderMissingCount": "0",
                "RelayFolderConfigMissingCount": "0",
                "RelayIssueSummary": "relay-folder-mismatch:1",
                "RelayIssuesSource": "current-receipt",
            },
            path_label="ReceiptPath",
            state_label="AcceptanceState",
            include_path=True,
            include_stage=True,
            include_reason=True,
            include_last_updated=True,
            include_blocked_target=True,
            include_blocked_run_root=True,
            include_blocked_path=True,
            include_history=True,
            relay_prefix="Receipt",
        )

        self.assertEqual(
            [
                r"ReceiptPath: C:\runs\a\.state\receipt.json",
                "Stage: preflight-blocked",
                "AcceptanceState: error",
                "AcceptanceReason: preflight blocked",
                "LastUpdatedAt: 2026-05-10T13:50:00+09:00",
                "BlockedBy: foreign-queued-command",
                "BlockedTargetId: target01",
                r"BlockedRunRoot: C:\runs\foreign",
                r"BlockedPath: C:\runtime\queue\target01\processing\command.json",
                "BlockedDetail: queued command from target05",
                "Receipt relay=relay-folder-mismatch:1",
                "Receipt relayMismatch=1 relayMissing=0 relayConfigMissing=0",
                "Receipt relaySource=current-receipt",
                "PhaseHistoryCount: 3",
                "PhaseHistoryTail: a -> b -> c",
            ],
            lines,
        )

    def test_format_acceptance_phase_history_lines_renders_recent_entries(self) -> None:
        lines = format_acceptance_phase_history_lines(
            [
                {"RecordedAt": "2026-05-10T13:19:00+09:00", "Stage": "preflight-only", "AcceptanceState": "preflight-passed"},
                {"RecordedAt": "2026-05-10T13:20:00+09:00", "Stage": "active-acceptance", "AcceptanceState": "pending"},
                {"RecordedAt": "2026-05-10T13:21:00+09:00", "Stage": "shared-confirm", "AcceptanceState": "roundtrip-confirmed", "BlockedBy": ""},
            ],
            header_label="RecentPhases:",
            max_entries=2,
        )

        self.assertEqual(
            [
                "RecentPhases:",
                "- 2026-05-10T13:20:00+09:00 stage=active-acceptance state=pending blocked=(none)",
                "- 2026-05-10T13:21:00+09:00 stage=shared-confirm state=roundtrip-confirmed blocked=(none)",
            ],
            lines,
        )

    def test_load_acceptance_receipt_summary_from_path_uses_fallback_when_path_missing(self) -> None:
        summary = load_acceptance_receipt_summary_from_path(
            "",
            exists=True,
            parse_error="missing-path",
            fallback_acceptance_state="pending",
            fallback_acceptance_reason="awaiting receipt",
        )

        self.assertEqual("true", summary["Exists"])
        self.assertEqual("missing-path", summary["ParseError"])
        self.assertEqual("pending", summary["AcceptanceState"])
        self.assertEqual("awaiting receipt", summary["AcceptanceReason"])

    def test_load_acceptance_receipt_summary_from_run_root_reads_receipt_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            state_root = run_root / ".state"
            state_root.mkdir(parents=True, exist_ok=True)
            (state_root / "live-acceptance-result.json").write_text(
                json.dumps(
                    {
                        "Stage": "preflight-blocked",
                        "LastUpdatedAt": "2026-05-10T14:00:00+09:00",
                        "BlockedBy": "foreign-queued-command",
                        "BlockedTargetId": "target01",
                        "Outcome": {
                            "AcceptanceState": "error",
                            "AcceptanceReason": "preflight blocked",
                        },
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            summary = load_acceptance_receipt_summary_from_run_root(str(run_root))

        self.assertEqual("true", summary["Exists"])
        self.assertEqual("preflight-blocked", summary["Stage"])
        self.assertEqual("error", summary["AcceptanceState"])
        self.assertEqual("preflight blocked", summary["AcceptanceReason"])
        self.assertEqual("foreign-queued-command", summary["BlockedBy"])

    def test_acceptance_receipt_summary_indicates_success_from_history(self) -> None:
        self.assertTrue(
            acceptance_receipt_summary_indicates_success(
                {
                    "AcceptanceState": "preflight-passed",
                    "HasSuccessHistory": "true",
                    "LastSuccessAcceptanceState": "roundtrip-confirmed",
                }
            )
        )

    def test_visible_confirm_payload_passed_accepts_legacy_passed_overall(self) -> None:
        self.assertTrue(visible_confirm_payload_passed({"Overall": "passed", "Checks": []}))

    def test_visible_confirm_payload_passed_accepts_required_checks_when_overall_missing(self) -> None:
        self.assertTrue(
            visible_confirm_payload_passed(
                {
                    "Overall": "",
                    "Checks": [
                        {"Name": "run-summary-readable", "Required": True, "Passed": True},
                        {"Name": "visible-receipt-roundtrip", "Required": True, "Passed": True},
                    ],
                }
            )
        )

    def test_visible_confirm_payload_passed_prefers_canonical_confirm_flag(self) -> None:
        self.assertTrue(visible_confirm_payload_passed({"ConfirmPassed": True, "Overall": "failing", "Checks": []}))
        self.assertFalse(visible_confirm_payload_passed({"ConfirmPassed": False, "Overall": "success", "Checks": []}))

    def test_visible_receipt_confirm_payload_passed_prefers_canonical_receipt_flag(self) -> None:
        self.assertTrue(
            visible_receipt_confirm_payload_passed(
                {"ReceiptConfirmPassed": True, "ConfirmPassed": False, "Overall": "failing", "Checks": []}
            )
        )
        self.assertFalse(
            visible_receipt_confirm_payload_passed(
                {"ReceiptConfirmPassed": False, "ConfirmPassed": True, "Overall": "success", "Checks": []}
            )
        )

    def test_resolve_acceptance_receipt_workflow_flags_prefers_canonical_fields(self) -> None:
        flags = resolve_acceptance_receipt_workflow_flags(
            {
                "AcceptanceState": "preflight-passed",
                "HasSuccessHistory": "false",
                "HasActiveHistory": "false",
                "PreflightPassed": "true",
                "ActiveAttempted": "true",
                "PostCleanupDone": "false",
                "CleanPreflightPassed": "false",
            }
        )

        self.assertEqual(
            {
                "PreflightPassed": True,
                "ActiveAttempted": True,
                "PostCleanupDone": False,
                "CleanPreflightPassed": False,
            },
            flags,
        )

    def test_resolve_acceptance_receipt_workflow_flags_falls_back_for_clean_recheck(self) -> None:
        flags = resolve_acceptance_receipt_workflow_flags(
            {
                "Stage": "completed",
                "AcceptanceState": "preflight-passed",
                "HasSuccessHistory": "true",
                "HasActiveHistory": "true",
                "PhaseHistoryTail": "post-cleanup:roundtrip-confirmed -> completed:preflight-passed",
            }
        )

        self.assertTrue(flags["PreflightPassed"])
        self.assertTrue(flags["ActiveAttempted"])
        self.assertTrue(flags["PostCleanupDone"])
        self.assertTrue(flags["CleanPreflightPassed"])

    def test_resolve_acceptance_receipt_workflow_flags_does_not_infer_post_cleanup_from_success_history_alone(
        self,
    ) -> None:
        flags = resolve_acceptance_receipt_workflow_flags(
            {
                "Stage": "completed",
                "AcceptanceState": "preflight-passed",
                "HasSuccessHistory": "true",
                "HasActiveHistory": "true",
                "PhaseHistoryTail": "visible-worker-preflight:preflight-passed -> completed:preflight-passed",
            }
        )

        self.assertTrue(flags["PreflightPassed"])
        self.assertTrue(flags["ActiveAttempted"])
        self.assertFalse(flags["PostCleanupDone"])
        self.assertTrue(flags["CleanPreflightPassed"])


if __name__ == "__main__":
    unittest.main()
