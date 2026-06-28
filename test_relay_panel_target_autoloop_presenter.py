from __future__ import annotations

import unittest

import relay_panel_target_autoloop_presenter as presenter


class TargetAutoloopPresenterTests(unittest.TestCase):
    def _ready_snapshot(self) -> dict[str, object]:
        return {
            "run_root": r"C:\work\.relay-runs\bottest-live-visible\target-autoloop\run_1",
            "run_root_error": "",
            "status_error": "",
            "control_error": "",
            "manifest_exists": True,
            "manifest_error": "",
            "manifest_run_mode": "target-autoloop",
            "manifest_enabled_count": 1,
            "manifest_publish_ready_count": 1,
            "control_pending_action": "",
            "router_session_state": "ok",
            "router_session_mismatch": False,
            "router_session": {
                "router_launcher_session_id": "session-1",
                "runtime_launcher_session_id": "session-1",
            },
            "watcher_state": "stopped",
        }

    def test_canonical_runroot_requires_bottest_target_autoloop_shape(self) -> None:
        self.assertTrue(
            presenter.target_autoloop_run_root_is_canonical(
                r"C:\work\.relay-runs\bottest-live-visible\target-autoloop\run_1"
            )
        )
        self.assertFalse(presenter.target_autoloop_run_root_is_canonical(r"C:\tmp\not-autoloop\run_1"))
        self.assertFalse(
            presenter.target_autoloop_run_root_is_canonical(
                r"C:\work\.relay-runs\bottest-live-visible\run_legacy"
            )
        )
        self.assertFalse(
            presenter.target_autoloop_run_root_is_canonical(
                r"C:\work\.relay-runs\bottest-live-visible\pairs\pair01\run_1"
            )
        )

    def test_start_eligibility_blocks_router_session_non_ok(self) -> None:
        snapshot = self._ready_snapshot()
        snapshot["router_session_state"] = "router-not-running"
        snapshot["router_session"] = {
            "router_launcher_session_id": "",
            "runtime_launcher_session_id": "session-1",
        }

        allowed, detail = presenter.target_autoloop_start_eligibility(
            snapshot,
            card_enabled_count=1,
            card_publish_ready_count=1,
            watcher_fresh=False,
        )

        self.assertFalse(allowed)
        self.assertIn("router-not-running", detail)
        self.assertIn("8창 재사용+router 동기화", detail)

    def test_start_eligibility_allows_ready_router_session(self) -> None:
        allowed, detail = presenter.target_autoloop_start_eligibility(
            self._ready_snapshot(),
            card_enabled_count=1,
            card_publish_ready_count=1,
            watcher_fresh=False,
        )

        self.assertTrue(allowed)
        self.assertEqual("", detail)

    def test_start_eligibility_blocks_all_targets_limit_reached(self) -> None:
        snapshot = self._ready_snapshot()
        snapshot["targets"] = [
            {
                "TargetId": "target01",
                "Enabled": True,
                "Phase": "limit-reached",
                "NextAction": "limit-reached",
                "CycleCount": 5,
                "MaxCycleCount": 5,
            }
        ]

        allowed, detail = presenter.target_autoloop_start_eligibility(
            snapshot,
            card_enabled_count=1,
            card_publish_ready_count=1,
            watcher_fresh=False,
        )
        label = presenter.target_autoloop_start_button_label(
            snapshot,
            watcher_fresh=False,
            latest_valid_run_root_available=False,
        )

        self.assertFalse(allowed)
        self.assertIn("MaxCycleCount", detail)
        self.assertIn("target01", detail)
        self.assertIn("새 RunRoot", detail)
        self.assertEqual("새 RunRoot 준비 후 감지 시작", label)

    def test_runroot_attention_warns_about_router_inbox_ready_files_when_not_active(self) -> None:
        snapshot = self._ready_snapshot()
        snapshot["manifest_targets"] = [{"TargetId": "target01"}]
        snapshot["router_inbox_ready_summary"] = {
            "count": 1,
            "target_ids": ["target01"],
            "latest_target_id": "target01",
            "latest_launcher_session_id": "session-1",
            "latest_created_at": "2026-06-18T18:00:00.0000000+09:00",
            "latest_path": r"C:\work\router-inbox\target01\message.ready.txt",
        }

        spec = presenter.target_autoloop_runroot_attention_spec(
            snapshot,
            config_enabled_ids=["target01"],
            config_publish_ready_ids=["target01"],
            intended_target_ids=["target01"],
            latest_valid_sibling_run_root=None,
            autoswitch_reject_hint="",
            start_allowed=True,
            start_detail="",
            watcher_health="stopped",
            watcher_health_detail="",
        )

        self.assertIn("router inbox", spec["text"])
        self.assertIn("ready 파일 1개", spec["text"])
        self.assertIn("target01", spec["text"])
        self.assertEqual("#B45309", spec["background"])

    def test_recommendation_prioritizes_partial_limit_reached_unaccepted_marker(self) -> None:
        snapshot = self._ready_snapshot()
        snapshot["watcher_state"] = "running"
        snapshot["targets"] = [
            {
                "TargetId": "target01",
                "Enabled": True,
                "Phase": "limit-reached",
                "NextAction": "limit-reached",
                "CycleCount": 5,
                "MaxCycleCount": 5,
            },
            {
                "TargetId": "target02",
                "Enabled": True,
                "Phase": "idle",
                "NextAction": "wait-for-output",
                "CycleCount": 0,
                "MaxCycleCount": 5,
            },
        ]
        snapshot["output_block_summary"] = {
            "limit_reached_ready_unaccepted_count": 1,
            "limit_reached_ready_unaccepted_target_ids": ["target01"],
            "latest_cycle_count": 5,
            "latest_max_cycle_count": 5,
            "latest_last_dispatch_state": "router-session-not-ready",
            "latest_publish_ready_path": r"C:\work\targets\target01\source-outbox\publish.ready.json",
        }

        spec = presenter.target_autoloop_recommendation_spec(
            snapshot,
            watcher_health="active",
            watcher_health_detail="1s",
            start_allowed=False,
            start_detail="현재 독립셀 감지기가 이미 active 상태입니다: running",
            resume_allowed=False,
            card_enabled_count=2,
            card_publish_ready_count=2,
        )
        attention = presenter.target_autoloop_runroot_attention_spec(
            snapshot,
            config_enabled_ids=["target01", "target02"],
            config_publish_ready_ids=["target01", "target02"],
            intended_target_ids=["target01"],
            latest_valid_sibling_run_root=None,
            autoswitch_reject_hint="",
            start_allowed=False,
            start_detail="현재 독립셀 감지기가 이미 active 상태입니다: running",
            watcher_health="active",
            watcher_health_detail="1s",
        )
        label = presenter.target_autoloop_start_button_label(
            snapshot,
            watcher_fresh=True,
            latest_valid_run_root_available=False,
        )
        detector_state = presenter.target_autoloop_detector_state_label(
            snapshot,
            watcher_fresh=True,
            start_allowed=False,
            start_detail="현재 독립셀 감지기가 이미 active 상태입니다: running",
        )

        self.assertEqual("prepare_autoloop_runroot", spec["action_key"])
        self.assertEqual("새 RunRoot 준비", spec["label"])
        self.assertIn("target01", spec["detail"])
        self.assertIn("MaxCycleCount", spec["detail"])
        self.assertIn("publish.ready", spec["detail"])
        self.assertIn("target01", attention["text"])
        self.assertEqual("#B45309", attention["background"])
        self.assertEqual("새 RunRoot 준비 후 감지 시작", label)
        self.assertEqual("차단", detector_state)


if __name__ == "__main__":
    unittest.main()
