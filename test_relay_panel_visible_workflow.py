from __future__ import annotations

import unittest

from relay_panel_operator_state import VisibleAcceptanceWorkflowProgress
from relay_panel_acceptance_receipt import format_acceptance_receipt_section_lines
from relay_panel_visible_workflow import (
    VisibleAcceptanceInputs,
    build_visible_acceptance_state,
    empty_acceptance_receipt_summary,
    summarize_acceptance_receipt_payload,
)


class VisibleAcceptanceWorkflowTests(unittest.TestCase):
    def test_build_visible_acceptance_state_requires_cleanup_before_preflight(self) -> None:
        state = build_visible_acceptance_state(
            VisibleAcceptanceInputs(
                config_present=True,
                pair_id="pair01",
                seed_target_id="target01",
                pair_enabled=True,
                pair_scope_allowed=True,
                action_run_root="C:\\runs\\current",
                active_run_root="C:\\runs\\current",
                confirm_run_root="C:\\runs\\current",
                receipt_summary=empty_acceptance_receipt_summary(path="C:\\runs\\current\\.state\\live-acceptance-result.json"),
            )
        )

        self.assertEqual("Visible Workflow: cleanup 필요", state.status_text)
        self.assertEqual("visible_cleanup_apply", state.next_action_key)
        self.assertFalse(state.preflight_enabled)
        self.assertTrue(state.shared_confirm_enabled)

    def test_build_visible_acceptance_state_requests_receipt_confirm_after_active_attempt(self) -> None:
        receipt = summarize_acceptance_receipt_payload(
            {
                "Stage": "active-acceptance",
                "PreflightPassed": True,
                "ActiveAttempted": True,
                "Outcome": {"AcceptanceState": "pending", "AcceptanceReason": "awaiting receipt"},
                "RelayIssues": {
                    "RelayFolderMismatchCount": 1,
                    "RelayFolderMissingCount": 0,
                    "RelayFolderConfigMissingCount": 0,
                    "RelayIssueSummary": "relay-folder-mismatch:1",
                    "Source": "current-receipt",
                },
                "PhaseHistory": [
                    {"Stage": "preflight-only", "AcceptanceState": "preflight-passed"},
                    {"Stage": "active-acceptance", "AcceptanceState": "pending"},
                ],
            },
            path="C:\\runs\\current\\.state\\live-acceptance-result.json",
        )
        state = build_visible_acceptance_state(
            VisibleAcceptanceInputs(
                config_present=True,
                pair_id="pair01",
                seed_target_id="target01",
                pair_enabled=True,
                pair_scope_allowed=True,
                action_run_root="C:\\runs\\current",
                active_run_root="C:\\runs\\current",
                confirm_run_root="C:\\runs\\current",
                receipt_summary=receipt,
                progress=VisibleAcceptanceWorkflowProgress(
                    cleanup_applied=True,
                    preflight_passed=True,
                    active_attempted=True,
                ),
            )
        )

        self.assertEqual("Visible Workflow: receipt confirm 필요", state.status_text)
        self.assertEqual("visible_receipt_confirm", state.next_action_key)
        self.assertTrue(state.receipt_confirm_enabled)
        self.assertTrue(state.post_cleanup_enabled)
        self.assertIn("relay=relay-folder-mismatch:1", state.detail_text)
        self.assertIn("relayMismatch=1 relayMissing=0 relayConfigMissing=0", state.detail_text)
        self.assertIn("relaySource=current-receipt", state.detail_text)

    def test_build_visible_acceptance_state_routes_focus_manual_attention_to_recovery_retry(self) -> None:
        receipt = summarize_acceptance_receipt_payload(
            {
                "Stage": "typed-window-bootstrap-failed",
                "PreflightPassed": True,
                "ActiveAttempted": True,
                "Outcome": {
                    "AcceptanceState": "manual_attention_required",
                    "AcceptanceReason": "typed-window bootstrap failed target=target01 finalState=manual_attention_required reason=visible-bootstrap-focus-steal",
                },
            },
            path="C:\\runs\\current\\.state\\live-acceptance-result.json",
        )
        state = build_visible_acceptance_state(
            VisibleAcceptanceInputs(
                config_present=True,
                pair_id="pair01",
                seed_target_id="target01",
                pair_enabled=True,
                pair_scope_allowed=True,
                action_run_root="C:\\runs\\current",
                active_run_root="C:\\runs\\current",
                confirm_run_root="C:\\runs\\current",
                receipt_summary=receipt,
                progress=VisibleAcceptanceWorkflowProgress(
                    cleanup_applied=True,
                    preflight_passed=True,
                    active_attempted=True,
                ),
                last_result_text="active visible acceptance 실패",
            )
        )

        self.assertEqual("Visible Workflow: manual recovery 필요", state.status_text)
        self.assertEqual("visible_focus_recovery_retry", state.next_action_key)
        self.assertIn("포커스 방해", state.detail_text)

    def test_build_visible_acceptance_state_routes_focus_error_to_recovery_retry(self) -> None:
        receipt = summarize_acceptance_receipt_payload(
            {
                "Stage": "failed",
                "PreflightPassed": True,
                "ActiveAttempted": False,
                "Outcome": {
                    "AcceptanceState": "error",
                    "AcceptanceReason": "typed-window bootstrap failed target=target05 finalState=manual_attention_required reason=visible-bootstrap-focus-steal",
                },
            },
            path="C:\\runs\\current\\.state\\live-acceptance-result.json",
        )
        state = build_visible_acceptance_state(
            VisibleAcceptanceInputs(
                config_present=True,
                pair_id="pair01",
                seed_target_id="target01",
                pair_enabled=True,
                pair_scope_allowed=True,
                action_run_root="C:\\runs\\current",
                active_run_root="C:\\runs\\current",
                confirm_run_root="C:\\runs\\current",
                receipt_summary=receipt,
                progress=VisibleAcceptanceWorkflowProgress(
                    cleanup_applied=True,
                    preflight_passed=True,
                ),
                last_result_text="active visible acceptance 실패",
            )
        )

        self.assertEqual("Visible Workflow: manual recovery 필요", state.status_text)
        self.assertEqual("visible_focus_recovery_retry", state.next_action_key)
        self.assertIn("포커스 방해", state.detail_text)

    def test_build_visible_acceptance_state_routes_preflight_focus_attention_to_continue(self) -> None:
        receipt = summarize_acceptance_receipt_payload(
            {
                "Stage": "completed",
                "PreflightPassed": True,
                "ActiveAttempted": False,
                "Preflight": {
                    "ActiveWindowSummary": "title=BlueStacks App Player process=HD-Player.exe",
                    "ActiveWindowIsOfficialTarget": False,
                    "ActiveWindowTargetId": "",
                },
                "Outcome": {
                    "AcceptanceState": "preflight-passed",
                    "AcceptanceReason": "typed-window visibility passed",
                },
            },
            path="C:\\runs\\current\\.state\\live-acceptance-result.json",
        )
        state = build_visible_acceptance_state(
            VisibleAcceptanceInputs(
                config_present=True,
                pair_id="pair01",
                seed_target_id="target01",
                pair_enabled=True,
                pair_scope_allowed=True,
                action_run_root="C:\\runs\\current",
                active_run_root="C:\\runs\\current",
                confirm_run_root="C:\\runs\\current",
                receipt_summary=receipt,
                progress=VisibleAcceptanceWorkflowProgress(
                    cleanup_applied=True,
                    preflight_passed=True,
                ),
            )
        )

        self.assertEqual("Visible Workflow: focus 확인 필요", state.status_text)
        self.assertEqual("visible_focus_recovery_retry", state.next_action_key)
        self.assertTrue(state.active_enabled)
        self.assertIn("BlueStacks App Player", state.detail_text)

    def test_build_visible_acceptance_state_prefers_canonical_clean_recheck_flags(self) -> None:
        receipt = summarize_acceptance_receipt_payload(
            {
                "Stage": "completed",
                "PreflightPassed": True,
                "ActiveAttempted": True,
                "PostCleanupDone": True,
                "CleanPreflightPassed": True,
                "Outcome": {"AcceptanceState": "preflight-passed", "AcceptanceReason": "clean lane"},
            },
            path="C:\\runs\\current\\.state\\live-acceptance-result.json",
        )
        state = build_visible_acceptance_state(
            VisibleAcceptanceInputs(
                config_present=True,
                pair_id="pair01",
                seed_target_id="target01",
                pair_enabled=True,
                pair_scope_allowed=True,
                action_run_root="C:\\runs\\current",
                active_run_root="C:\\runs\\current",
                confirm_run_root="C:\\runs\\current",
                receipt_summary=receipt,
                progress=VisibleAcceptanceWorkflowProgress(
                    cleanup_applied=True,
                ),
            )
        )

        self.assertTrue(state.preflight_passed)
        self.assertTrue(state.active_attempted)
        self.assertTrue(state.post_cleanup_done)
        self.assertTrue(state.clean_preflight_passed)

    def test_summarize_acceptance_receipt_payload_tracks_success_history(self) -> None:
        summary = summarize_acceptance_receipt_payload(
            {
                "Stage": "shared-confirm",
                "Outcome": {"AcceptanceState": "roundtrip-confirmed", "AcceptanceReason": "ok"},
                "RelayIssues": {
                    "RelayFolderMismatchCount": 1,
                    "RelayFolderMissingCount": 0,
                    "RelayFolderConfigMissingCount": 0,
                    "RelayIssueSummary": "relay-folder-mismatch:1",
                    "Source": "current-receipt",
                },
                "PhaseHistory": [
                    {"Stage": "preflight-only", "AcceptanceState": "preflight-passed"},
                    {"Stage": "active-acceptance", "AcceptanceState": "pending"},
                    {"Stage": "shared-confirm", "AcceptanceState": "roundtrip-confirmed"},
                ],
            },
            path="C:\\runs\\current\\.state\\live-acceptance-result.json",
        )

        self.assertEqual("true", summary["HasSuccessHistory"])
        self.assertEqual("true", summary["HasActiveHistory"])
        self.assertEqual("roundtrip-confirmed", summary["LastSuccessAcceptanceState"])
        self.assertIn("active-acceptance:pending", summary["PhaseHistoryTail"])
        self.assertEqual("1", summary["RelayFolderMismatchCount"])
        self.assertEqual("0", summary["RelayFolderMissingCount"])
        self.assertEqual("0", summary["RelayFolderConfigMissingCount"])
        self.assertEqual("relay-folder-mismatch:1", summary["RelayIssueSummary"])
        self.assertEqual("current-receipt", summary["RelayIssuesSource"])

    def test_acceptance_receipt_summary_surfaces_recovery_attempt_fields(self) -> None:
        summary = summarize_acceptance_receipt_payload(
            {
                "Stage": "typed-window-bootstrap-failed",
                "RecoveryAttemptCount": 2,
                "LastRecoveryAttemptId": "attempt-2",
                "LastRecoveryAction": "focus-recovery-retry",
                "LastRecoveryRequestedAt": "2026-05-15T01:30:00+09:00",
                "LastRecoveryCompletedAt": "2026-05-15T01:31:00+09:00",
                "LastRecoveryResult": "manual_attention_required",
                "LastRecoveryTargetId": "target01",
                "LastRecoveryReason": "visible-bootstrap-focus-steal",
                "Outcome": {
                    "AcceptanceState": "manual_attention_required",
                    "AcceptanceReason": "visible-bootstrap-focus-steal",
                },
            },
            path="C:\\runs\\current\\.state\\live-acceptance-result.json",
        )
        lines = format_acceptance_receipt_section_lines(summary, include_history=True)
        text = "\n".join(lines)

        self.assertEqual("2", summary["RecoveryAttemptCount"])
        self.assertEqual("focus-recovery-retry", summary["LastRecoveryAction"])
        self.assertIn("recovery=2 action=focus-recovery-retry result=manual_attention_required target=target01", text)
        self.assertIn("recoveryReason=visible-bootstrap-focus-steal", text)


if __name__ == "__main__":
    unittest.main()
