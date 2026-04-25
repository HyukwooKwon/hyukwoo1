from __future__ import annotations

import unittest

from relay_panel_operator_state import VisibleAcceptanceWorkflowProgress
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
                "Outcome": {"AcceptanceState": "pending", "AcceptanceReason": "awaiting receipt"},
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

    def test_summarize_acceptance_receipt_payload_tracks_success_history(self) -> None:
        summary = summarize_acceptance_receipt_payload(
            {
                "Stage": "shared-confirm",
                "Outcome": {"AcceptanceState": "roundtrip-confirmed", "AcceptanceReason": "ok"},
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


if __name__ == "__main__":
    unittest.main()
