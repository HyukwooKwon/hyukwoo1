from __future__ import annotations

import json
import os
import unittest
from pathlib import Path
from unittest import mock

import relay_panel_target_autoloop_runtime as runtime
from relay_test_temp import configure_workspace_tempfile, make_workspace_tempdir, restore_tempfile_configuration


def setUpModule() -> None:
    configure_workspace_tempfile()


def tearDownModule() -> None:
    restore_tempfile_configuration()


class TargetAutoloopRuntimeTests(unittest.TestCase):
    def test_single_quoted_psd1_value_unescapes_quotes(self) -> None:
        raw = "@{\n RuntimeMapPath = 'C:\\root\\it''s\\target-runtime.json'\n}"

        self.assertEqual(
            "C:\\root\\it's\\target-runtime.json",
            runtime.single_quoted_psd1_value(raw, "RuntimeMapPath"),
        )

    def test_psd1_string_value_reads_double_quoted_values(self) -> None:
        raw = '@{\n RetryPendingRoot = "C:\\runtime\\retry-`"pending"\n}'

        self.assertEqual(
            'C:\\runtime\\retry-"pending',
            runtime.psd1_string_value(raw, "RetryPendingRoot"),
        )

    def test_read_json_dict_with_error_preserves_missing_policy(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-json-error"))
        missing_path = root / "missing.json"
        list_path = root / "list.json"
        list_path.write_text(json.dumps([{"not": "dict"}]), encoding="utf-8")

        payload, error = runtime.read_json_dict_with_error(missing_path, missing_error="missing")
        self.assertEqual({}, payload)
        self.assertEqual("missing", error)

        payload, error = runtime.read_json_dict_with_error(
            list_path,
            missing_error="missing",
            not_dict_error="payload-not-dict",
        )
        self.assertEqual({}, payload)
        self.assertEqual("payload-not-dict", error)

    def test_read_json_dict_with_error_retries_transient_read_errors(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-json-retry"))
        status_path = root / "status.json"
        status_path.write_text(json.dumps({"WatcherState": "running"}), encoding="utf-8")
        original_read_text = Path.read_text
        calls = {"count": 0}

        def flaky_read_text(path: Path, *args, **kwargs):
            if Path(path) == status_path and calls["count"] == 0:
                calls["count"] += 1
                raise PermissionError("temporarily locked")
            return original_read_text(path, *args, **kwargs)

        with mock.patch.object(Path, "read_text", flaky_read_text):
            payload, error = runtime.read_json_dict_with_error(status_path, missing_error="missing")

        self.assertEqual({"WatcherState": "running"}, payload)
        self.assertEqual("", error)
        self.assertEqual(1, calls["count"])

    def test_target_autoloop_run_paths_uses_state_file_names(self) -> None:
        run_root = Path(r"C:\work\.relay-runs\bottest-live-visible\target-autoloop\run_1")

        paths = runtime.target_autoloop_run_paths(str(run_root))

        self.assertEqual(run_root / "manifest.json", paths["manifest_path"])
        self.assertEqual(run_root / ".state" / "target-autoloop-status.json", paths["status_path"])
        self.assertEqual(run_root / ".state" / "target-autoloop-control.json", paths["control_path"])
        self.assertEqual(
            run_root / ".state" / "target-autoloop-watcher.stdout.log",
            paths["watcher_stdout_log_path"],
        )
        self.assertEqual(
            run_root / ".state" / "target-autoloop-watcher.stderr.log",
            paths["watcher_stderr_log_path"],
        )
        self.assertEqual(
            run_root / ".state" / "target-autoloop-live-smoke-result.json",
            paths["smoke_receipt_path"],
        )

    def test_manifest_enabled_publish_ready_counts_normalizes_trigger_kinds(self) -> None:
        manifest_targets: list[object] = [
            {"TargetId": "target01", "Enabled": True, "TriggerKinds": ["input-file", "publish-ready"]},
            {"TargetId": "target02", "Enabled": True, "TriggerKinds": " publish-ready "},
            {"TargetId": "target03", "Enabled": True, "TriggerKinds": ["PUBLISH-READY"]},
            {"TargetId": "target04", "Enabled": True, "TriggerKinds": ["input-file"]},
            {"TargetId": "target05", "Enabled": False, "TriggerKinds": ["publish-ready"]},
            "not-a-target",
        ]

        enabled_count, publish_ready_count = runtime.target_autoloop_manifest_enabled_publish_ready_counts(
            manifest_targets
        )

        self.assertEqual(4, enabled_count)
        self.assertEqual(3, publish_ready_count)

    def test_status_targets_and_counts_ignore_wrong_shapes(self) -> None:
        self.assertEqual({}, runtime.target_autoloop_status_counts({"Counts": []}))
        self.assertEqual([], runtime.target_autoloop_status_targets({"Targets": {}}))
        self.assertEqual([], runtime.target_autoloop_manifest_targets({"Targets": {}}))

        self.assertEqual({"Queued": 2}, runtime.target_autoloop_status_counts({"Counts": {"Queued": 2}}))
        self.assertEqual(
            [{"TargetId": "target01"}],
            runtime.target_autoloop_status_targets({"Targets": [{"TargetId": "target01"}]}),
        )
        self.assertEqual(
            [{"TargetId": "target01"}],
            runtime.target_autoloop_manifest_targets({"Targets": [{"TargetId": "target01"}]}),
        )

    def test_router_session_paths_prefers_config_file_over_effective_data(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-paths"))
        config_path = root / "settings.psd1"
        config_path.write_text(
            "\n".join(
                [
                    "@{",
                    r"  RuntimeMapPath = 'C:\runtime\from-file\target-runtime.json'",
                    r"  RouterStatePath = 'C:\runtime\from-file\router-state.json'",
                    r"  IgnoredRoot = 'C:\runtime\from-file\ignored'",
                    r'  RetryPendingRoot = "C:\runtime\from-file\retry-pending"',
                    "}",
                ]
            ),
            encoding="utf-8",
        )

        paths = runtime.target_autoloop_router_session_paths(
            effective_data={
                "Config": {
                    "RuntimeMapPath": r"C:\runtime\from-effective\target-runtime.json",
                    "RouterStatePath": r"C:\runtime\from-effective\router-state.json",
                    "RetryPendingRoot": r"C:\runtime\from-effective\retry-pending",
                }
            },
            config_path=str(config_path.resolve()),
            root=root,
        )

        self.assertEqual(r"C:\runtime\from-file\target-runtime.json", paths["runtime_map_path"])
        self.assertEqual(r"C:\runtime\from-file\router-state.json", paths["router_state_path"])
        self.assertEqual(r"C:\runtime\from-file\ignored", paths["ignored_root"])
        self.assertEqual(r"C:\runtime\from-file\retry-pending", paths["retry_pending_root"])
        self.assertEqual("config-file", paths["source"])
        self.assertEqual(str(config_path.resolve()), paths["config_path"])

    def test_recent_ignored_summary_reads_archive_reason_and_filters_target(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-ignored"))
        ignored_root = root / "ignored"
        ignored_root.mkdir()
        target07_ready = ignored_root / "target07__20260702_120000_000__message.ready.txt"
        target07_ready.write_text("payload", encoding="utf-8")
        Path(str(target07_ready) + ".archive.json").write_text(
            json.dumps(
                {
                    "ArchiveReasonCode": "metadata-missing",
                    "ArchiveReasonDetail": "delivery metadata missing",
                    "TargetId": "target07",
                    "LauncherSessionId": "session-current",
                }
            ),
            encoding="utf-8",
        )
        target08_ready = ignored_root / "target08__20260702_120001_000__message.ready.txt"
        target08_ready.write_text("payload", encoding="utf-8")
        Path(str(target08_ready) + ".archive.json").write_text(
            json.dumps({"ArchiveReasonCode": "launcher-session-mismatch", "TargetId": "target08"}),
            encoding="utf-8",
        )
        os.utime(target07_ready, (1000, 1000))
        os.utime(target08_ready, (2000, 2000))

        summary = runtime.target_autoloop_recent_ignored_summary(
            str(ignored_root),
            target_ids=["target07"],
            max_items=5,
        )

        self.assertEqual(1, summary["count"])
        self.assertEqual(["target07"], summary["target_ids"])
        self.assertEqual(str(target07_ready), summary["latest_path"])
        self.assertEqual("target07", summary["latest_target_id"])
        self.assertEqual("metadata-missing", summary["latest_reason_code"])
        self.assertEqual("delivery metadata missing", summary["latest_reason_detail"])
        self.assertEqual(1, summary["ignored_target_filtered_count"])
        self.assertEqual([{"reason_code": "metadata-missing", "count": 1}], summary["reason_counts"])

    def test_router_session_snapshot_reports_ok_for_matching_session(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-ok"))
        runtime_map_path = root / "target-runtime.json"
        router_state_path = root / "router-state.json"
        runtime_map_path.write_text(
            json.dumps([{"TargetId": "target01", "LauncherSessionId": "session-1"}]),
            encoding="utf-8",
        )
        router_state_path.write_text(
            json.dumps(
                {
                    "Status": "running",
                    "LauncherSessionId": "session-1",
                    "RouterPid": os.getpid(),
                    "IgnoredRoot": str(root / "ignored-from-state"),
                }
            ),
            encoding="utf-8",
        )

        snapshot = runtime.target_autoloop_router_session_snapshot(
            {
                "runtime_map_path": str(runtime_map_path),
                "router_state_path": str(router_state_path),
                "source": "test",
                "config_path": str(root / "settings.psd1"),
            }
        )

        self.assertEqual("ok", snapshot["state"])
        self.assertFalse(snapshot["mismatch"])
        self.assertTrue(runtime.target_autoloop_router_session_paths_ready(snapshot))
        self.assertEqual("session-1", snapshot["runtime_launcher_session_id"])
        self.assertEqual("session-1", snapshot["router_launcher_session_id"])
        self.assertEqual(str(os.getpid()), snapshot["router_pid"])
        self.assertEqual(str(root / "ignored-from-state"), snapshot["ignored_root"])
        self.assertTrue(snapshot["router_pid_exists"])

    def test_router_session_snapshot_rejects_dead_matching_router_pid(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-dead-pid"))
        runtime_map_path = root / "target-runtime.json"
        router_state_path = root / "router-state.json"
        runtime_map_path.write_text(
            json.dumps([{"TargetId": "target01", "LauncherSessionId": "session-1"}]),
            encoding="utf-8",
        )
        router_state_path.write_text(
            json.dumps({"Status": "running", "LauncherSessionId": "session-1", "RouterPid": 2147483647}),
            encoding="utf-8",
        )

        snapshot = runtime.target_autoloop_router_session_snapshot(
            {
                "runtime_map_path": str(runtime_map_path),
                "router_state_path": str(router_state_path),
            }
        )

        self.assertEqual("router-pid-not-running", snapshot["state"])
        self.assertFalse(snapshot["mismatch"])
        self.assertFalse(snapshot["router_pid_exists"])
        self.assertFalse(runtime.target_autoloop_router_session_paths_ready(snapshot))

    def test_router_session_snapshot_reports_mismatch_before_dead_pid(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-mismatch"))
        runtime_map_path = root / "target-runtime.json"
        router_state_path = root / "router-state.json"
        runtime_map_path.write_text(json.dumps([{"LauncherSessionId": "runtime-new"}]), encoding="utf-8")
        router_state_path.write_text(
            json.dumps({"Status": "running", "LauncherSessionId": "router-old", "RouterPid": 2147483647}),
            encoding="utf-8",
        )

        snapshot = runtime.target_autoloop_router_session_snapshot(
            {"runtime_map_path": str(runtime_map_path), "router_state_path": str(router_state_path)}
        )

        self.assertEqual("mismatch", snapshot["state"])
        self.assertTrue(snapshot["mismatch"])
        self.assertFalse(snapshot["router_pid_exists"])
        self.assertFalse(runtime.target_autoloop_router_session_paths_ready(snapshot))
        self.assertIn("runtime-new", runtime.target_autoloop_router_session_paths_not_ready_message(snapshot))
        self.assertIn("router-old", runtime.target_autoloop_router_session_paths_not_ready_message(snapshot))

    def test_router_session_snapshot_reports_ambiguous_runtime_sessions(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-ambiguous"))
        runtime_map_path = root / "target-runtime.json"
        router_state_path = root / "router-state.json"
        runtime_map_path.write_text(
            json.dumps(
                [
                    {"TargetId": "target01", "LauncherSessionId": "session-a"},
                    {"TargetId": "target02", "LauncherSessionId": "session-b"},
                ]
            ),
            encoding="utf-8",
        )
        router_state_path.write_text(
            json.dumps({"Status": "running", "LauncherSessionId": "session-a"}),
            encoding="utf-8",
        )

        snapshot = runtime.target_autoloop_router_session_snapshot(
            {"runtime_map_path": str(runtime_map_path), "router_state_path": str(router_state_path)}
        )

        self.assertEqual("runtime-session-ambiguous", snapshot["state"])
        self.assertEqual(["session-a", "session-b"], snapshot["runtime_launcher_session_ids"])
        self.assertFalse(runtime.target_autoloop_router_session_paths_ready(snapshot))

    def test_router_inbox_ready_summary_counts_manifest_global_folder(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-router-inbox-ready"))
        inbox = root / "router-inbox" / "target01"
        inbox.mkdir(parents=True, exist_ok=True)
        ready_path = inbox / "message_20260618_180000_000__stale.ready.txt"
        ready_path.write_text("payload", encoding="utf-8")
        Path(str(ready_path) + ".delivery.json").write_text(
            json.dumps(
                {
                    "CreatedAt": "2026-06-18T18:00:00.0000000+09:00",
                    "TargetId": "target01",
                    "MessageType": "generic",
                    "LauncherSessionId": "session-current",
                }
            ),
            encoding="utf-8",
        )

        summary = runtime.target_autoloop_router_inbox_ready_summary(
            [{"TargetId": "target01", "GlobalFolder": str(inbox)}],
            target_ids=["target01"],
        )

        self.assertEqual(1, summary["count"])
        self.assertEqual(["target01"], summary["target_ids"])
        self.assertEqual(str(ready_path), summary["latest_path"])
        self.assertEqual("target01", summary["latest_target_id"])
        self.assertEqual("session-current", summary["latest_launcher_session_id"])
        self.assertEqual("2026-06-18T18:00:00.0000000+09:00", summary["latest_created_at"])

    def test_source_outbox_contract_summary_detects_limit_reached_unaccepted_marker(self) -> None:
        root = Path(make_workspace_tempdir("target-autoloop-runtime-source-outbox"))
        outbox = root / "external-work" / "targets" / "target01" / "source-outbox"
        outbox.mkdir(parents=True, exist_ok=True)
        summary_path = outbox / "summary.txt"
        review_path = outbox / "review.zip"
        publish_path = outbox / "publish.ready.json"
        summary_path.write_text("summary", encoding="utf-8")
        review_path.write_bytes(b"zip")
        publish_path.write_text(
            json.dumps({"TargetId": "target01", "OutputFingerprint": "current-marker"}),
            encoding="utf-8",
        )

        summary = runtime.target_autoloop_source_outbox_contract_summary(
            [
                {
                    "TargetId": "target01",
                    "Enabled": True,
                    "TriggerKinds": ["publish-ready"],
                    "SourceOutboxPath": str(outbox),
                    "SourceSummaryPath": str(summary_path),
                    "SourceReviewZipPath": str(review_path),
                    "PublishReadyPath": str(publish_path),
                },
                {
                    "TargetId": "target02",
                    "Enabled": True,
                    "TriggerKinds": ["publish-ready"],
                    "SourceSummaryPath": str(root / "missing-summary.txt"),
                    "SourceReviewZipPath": str(root / "missing-review.zip"),
                    "PublishReadyPath": str(root / "missing-publish.ready.json"),
                },
            ],
            [
                {
                    "TargetId": "target01",
                    "Phase": "limit-reached",
                    "NextAction": "limit-reached",
                    "CycleCount": 5,
                    "MaxCycleCount": 5,
                    "LastHandledOutputFingerprint": "previous-marker",
                    "LastDispatchState": "router-session-not-ready",
                },
                {
                    "TargetId": "target02",
                    "Phase": "idle",
                    "NextAction": "wait-for-output",
                    "CycleCount": 0,
                    "MaxCycleCount": 5,
                },
            ],
        )

        self.assertEqual(2, summary["count"])
        self.assertEqual(1, summary["limit_reached_count"])
        self.assertEqual(1, summary["ready_unaccepted_count"])
        self.assertEqual(1, summary["limit_reached_ready_unaccepted_count"])
        self.assertEqual(1, summary["router_blocked_count"])
        self.assertEqual(["target01"], summary["limit_reached_ready_unaccepted_target_ids"])
        self.assertEqual("target01", summary["latest_target_id"])
        self.assertEqual("router-session-not-ready", summary["latest_last_dispatch_state"])


if __name__ == "__main__":
    unittest.main()
