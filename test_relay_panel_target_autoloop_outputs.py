from __future__ import annotations

import unittest

import relay_panel_target_autoloop_outputs as outputs


class TargetAutoloopOutputFormatterTests(unittest.TestCase):
    def test_start_watcher_success_lines_include_launch_and_ready_state(self) -> None:
        lines = outputs.format_start_watcher_success_lines(
            action_title="8 Cell Autoloop 독립셀 감지 시작",
            run_root=r"C:\runs\run_1",
            launch_payload={
                "StatusPath": r"C:\runs\run_1\.state\status.json",
                "ControlPath": r"C:\runs\run_1\.state\control.json",
                "Message": "started",
                "ReasonCodes": ["launch_requested"],
                "Idempotent": False,
                "ActiveConfirmed": True,
                "WatcherMutexHeld": False,
                "PreparedNewRun": False,
                "ExpectedWatcherState": "running",
                "WatcherProcessId": 1234,
                "RestoredTargetIds": ["target01"],
            },
            ready_snapshot={
                "controller_state": "running",
                "watcher_state": "running",
                "process_started_at": "2026-05-25T00:00:00Z",
                "heartbeat_at": "2026-05-25T00:00:01Z",
            },
        )

        self.assertIn("RunRoot: C:\\runs\\run_1", lines)
        self.assertIn("ReasonCodes: launch_requested", lines)
        self.assertIn("Idempotent: False", lines)
        self.assertIn("ActiveConfirmed: True", lines)
        self.assertIn("WatcherProcessId: 1234", lines)
        self.assertIn("ControllerState: running", lines)
        self.assertIn("RestoredTargetIds: target01", lines)

    def test_start_watcher_ack_and_failure_summary_match_panel_labels(self) -> None:
        ready_snapshot = {
            "controller_state": "running",
            "watcher_state": "running",
            "heartbeat_at": "2026-05-25T00:00:01Z",
        }
        self.assertEqual(
            "ack: controller=running / detector=running / scope=- / targets=(none) / heartbeat=2026-05-25T00:00:01Z",
            outputs.format_start_watcher_ack_detail(ready_snapshot),
        )
        self.assertEqual(
            "start failed / runroot=C:\\runs\\run_1 / controller=stopped / detector=stopped / heartbeat=(none)",
            outputs.format_start_watcher_failure_summary(
                run_root=r"C:\runs\run_1",
                failure_snapshot={"controller_state": "stopped", "watcher_state": "stopped"},
            ),
        )

    def test_process_once_summary_classifies_target_rows(self) -> None:
        summary = outputs.summarize_process_once_payload(
            action_title="8 Cell Autoloop publish.ready 1회 재검사",
            run_root=r"C:\runs\run_1",
            payload={
                "RunRoot": r"C:\runs\run_1",
                "Result": "ok",
                "WatcherResult": {
                    "WatcherState": "stopped",
                    "WatcherStopReason": "process-once-complete",
                    "Targets": [
                        {"TargetId": "target01", "Phase": "queued"},
                        {"TargetId": "target02", "Phase": "idle"},
                        {"TargetId": "target03", "Phase": "failed"},
                    ],
                },
            },
        )

        self.assertEqual(["target01"], summary.queued_targets)
        self.assertEqual(["target02"], summary.waiting_targets)
        self.assertEqual(["target03"], summary.failed_targets)
        self.assertEqual("queued=1 / waiting=1 / failed=1", summary.detail)
        self.assertIn("QueuedOrDelayTargets: target01", summary.lines)

    def test_process_once_summary_explains_duplicate_publish_marker(self) -> None:
        summary = outputs.summarize_process_once_payload(
            action_title="8 Cell Autoloop publish.ready 1회 재검사",
            run_root=r"C:\runs\run_1",
            payload={
                "RunRoot": r"C:\runs\run_1",
                "Result": "ok",
                "WatcherResult": {
                    "WatcherState": "stopped",
                    "WatcherStopReason": "process-once-complete",
                    "DuplicateCount": 1,
                    "DuplicateTargetIds": ["target01"],
                    "DuplicateFingerprints": ["fingerprint-001"],
                    "Targets": [{"TargetId": "target01", "Phase": "idle"}],
                },
            },
        )

        self.assertEqual(1, summary.duplicate_count)
        self.assertEqual(["target01"], summary.duplicate_targets)
        self.assertEqual(["fingerprint-001"], summary.duplicate_fingerprints)
        self.assertEqual("queued=0 / waiting=1 / failed=0 / duplicate=1", summary.detail)
        self.assertIn("DuplicateTriggers: 1", summary.lines)
        self.assertIn("DuplicateTargets: target01", summary.lines)
        self.assertIn("DuplicateFingerprints: fingerprint-001", summary.lines)
        self.assertTrue(any("DuplicateMarkerGuidance:" in line for line in summary.lines))

    def test_control_action_success_lines_and_ack_detail(self) -> None:
        lines = outputs.format_control_action_success_lines(
            action_title="8 Cell Autoloop resume 요청",
            run_root=r"C:\runs\run_1",
            request_payload={
                "ControlPath": r"C:\runs\run_1\.state\control.json",
                "Message": "requested",
                "RequestId": "req-1",
                "ReasonCodes": ["accepted"],
            },
            ack_snapshot={
                "controller_state": "running",
                "state": "running",
                "last_handled_request_id": "req-1",
                "last_handled_action": "resume",
                "last_handled_result": "resumed",
            },
        )

        self.assertIn("RequestId: req-1", lines)
        self.assertIn("RequestRecorded: True", lines)
        self.assertIn("AckMatched: True", lines)
        self.assertIn("Reasons: accepted", lines)
        self.assertIn("LastHandledResult: resumed", lines)
        self.assertEqual(
            "ack: controller=running / result=resumed / lastHandled=resume:req-1",
            outputs.format_control_action_ack_detail(
                {
                    "controller_state": "running",
                    "last_handled_result": "resumed",
                    "last_handled_action": "resume",
                    "last_handled_request_id": "req-1",
                }
            ),
        )

    def test_control_action_pending_and_failure_lines_include_ack_contract_fields(self) -> None:
        pending_lines = outputs.format_control_action_pending_lines(
            action_title="8 Cell Autoloop stop 요청",
            action="stop",
            run_root=r"C:\runs\run_1",
            expected_controller_state="stopped",
            control_path=r"C:\runs\run_1\.state\control.json",
        )
        failure_lines = outputs.format_control_action_failure_lines(
            action_title="8 Cell Autoloop stop 요청",
            action="stop",
            run_root=r"C:\runs\run_1",
            formatted_error="target-autoloop stop timeout",
            failure_snapshot={
                "controller_state": "running",
                "state": "running",
                "control_pending_action": "stop",
                "control_pending_request_id": "req-stop-1",
                "last_handled_request_id": "req-pause-1",
                "last_handled_action": "pause",
                "last_handled_result": "paused",
                "status_path": r"C:\runs\run_1\.state\status.json",
                "control_path": r"C:\runs\run_1\.state\control.json",
            },
        )

        self.assertIn("확인 기준: RequestId 생성 -> LastHandledAction=stop -> ControllerState=stopped", pending_lines)
        self.assertIn("ControlPendingAction: stop", failure_lines)
        self.assertIn("ControlPendingRequestId: req-stop-1", failure_lines)
        self.assertIn("LastHandledAction: pause", failure_lines)

    def test_router_restart_success_lines_and_ack_detail(self) -> None:
        lines = outputs.format_router_restart_success_lines(
            action_title="8 Cell Autoloop router 세션 재시작",
            config_path="cfg.psd1",
            run_root=r"C:\runs\run_1",
            restart_payload={
                "MatchedProcessIds": [1001],
                "StoppedProcessIds": [1001],
                "StartedProcessId": 2002,
                "EffectiveRouterPid": 2002,
            },
            after_snapshot={
                "router_session_state": "ok",
                "router_session": {
                    "router_launcher_session_id": "session-1",
                    "runtime_launcher_session_id": "session-1",
                    "path_source": "config-file",
                    "router_state_path": r"C:\runtime\router-state.json",
                    "runtime_map_path": r"C:\runtime\target-runtime.json",
                },
            },
        )

        self.assertIn("MatchedProcessIds: 1001", lines)
        self.assertIn("StoppedProcessIds: 1001", lines)
        self.assertIn("RouterSessionState: ok", lines)
        self.assertIn("RuntimeLauncherSessionId: session-1", lines)
        self.assertEqual(
            "ack: routerSession=ok / pid=2002",
            outputs.format_router_restart_ack_detail(
                router_state="ok",
                restart_payload={"StartedProcessId": 2001, "EffectiveRouterPid": 2002},
            ),
        )

    def test_prepare_runroot_success_lines_and_manifest_summary(self) -> None:
        lines = outputs.format_prepare_runroot_success_lines(
            action_title="8 Cell Autoloop 선택 target만 새 RunRoot 준비",
            prepared_run_root=r"C:\runs\run_1",
            payload={
                "ManifestPath": r"C:\runs\run_1\manifest.json",
                "StatePath": r"C:\runs\run_1\.state",
                "StatusPath": r"C:\runs\run_1\.state\status.json",
                "ControlPath": r"C:\runs\run_1\.state\control.json",
                "TargetIds": ["target04"],
            },
            target_scope_text="선택 target만",
            prepare_config_backup_path=r"C:\cfg.backup.psd1",
        )
        summary_lines = outputs.format_prepare_manifest_summary_lines(
            {
                "manifest_targets": [
                    {
                        "TargetId": "target04",
                        "TriggerKinds": ["input-file", "publish-ready"],
                        "WorkRepoRoot": r"C:\repo",
                        "SourceOutboxPath": r"C:\repo\.relay-contract\summary.txt",
                        "QueueRoot": r"C:\runs\run_1\queue\target04",
                    }
                ]
            },
            start_allowed=True,
            start_detail="",
        )

        self.assertIn("TargetIds: target04", lines)
        self.assertIn("TargetScope: 선택 target만", lines)
        self.assertIn("ConfigAutoFix: TargetAutoloop.Enabled=True 저장 완료 / backup=C:\\cfg.backup.psd1", lines)
        self.assertIn("이번 RunRoot 포함 target: target04", summary_lines)
        self.assertIn("publish-ready: 1/1", summary_lines)
        self.assertIn("WorkRepoRoot:", summary_lines)
        self.assertIn("  target04: C:\\repo", summary_lines)
        self.assertIn("  target04: C:\\repo\\.relay-contract\\summary.txt", summary_lines)


if __name__ == "__main__":
    unittest.main()
