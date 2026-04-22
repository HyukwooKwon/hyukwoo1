from __future__ import annotations

import json
import time
import unittest
from datetime import datetime
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from relay_panel_models import AppContext
from relay_panel_services import (
    POWERSHELL,
    POWERSHELL_REQUIRED_MESSAGE,
    CommandService,
    ROOT as APP_ROOT,
    StatusService,
)
from relay_panel_watcher_controller import WatcherController
from relay_panel_watchers import WatcherService


def _default_config_path() -> str:
    return str(APP_ROOT / "config" / "settings.bottest-live-visible.psd1")


def _skip_if_pwsh_unavailable() -> None:
    if not POWERSHELL:
        raise unittest.SkipTest(POWERSHELL_REQUIRED_MESSAGE)


class _RecordingCommandService:
    def __init__(self) -> None:
        self.spawned_commands: list[list[str]] = []

    def build_script_command(
        self,
        script_name: str,
        *,
        config_path: str = "",
        run_root: str = "",
        pair_id: str = "",
        target_id: str = "",
        extra: list[str] | None = None,
    ) -> list[str]:
        command = [script_name]
        if config_path:
            command += ["-ConfigPath", config_path]
        if run_root:
            command += ["-RunRoot", run_root]
        if pair_id:
            command += ["-PairId", pair_id]
        if target_id:
            command += ["-TargetId", target_id]
        if extra:
            command += list(extra)
        return command

    def spawn_detached(self, command: list[str]) -> None:
        self.spawned_commands.append(list(command))


class WatcherControllerPresetSmoke(unittest.TestCase):
    def test_controller_roundtrip_with_real_preset(self) -> None:
        _skip_if_pwsh_unavailable()
        config_path = _default_config_path()
        run_root = APP_ROOT / "pair-test" / "bottest-live-visible" / (
            "run_controller_smoke_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        )

        command_service = CommandService()
        status_service = StatusService(command_service)
        watcher_service = WatcherService()
        watcher_controller = WatcherController(watcher_service)
        context = AppContext(config_path=config_path, run_root=str(run_root), pair_id="pair01", target_id="")

        prepare_command = command_service.build_script_command(
            "tests/Start-PairedExchangeTest.ps1",
            config_path=config_path,
            run_root=str(run_root),
            extra=["-IncludePairId", "pair01"],
        )
        command_service.run(prepare_command)

        paired_status, paired_error = status_service.load_paired_status(context, run_root=str(run_root))
        self.assertEqual("", paired_error)

        start_result, notes = watcher_controller.start(
            command_service,
            config_path=config_path,
            run_root=str(run_root),
            paired_status=paired_status,
        )
        self.assertTrue(start_result.ok, msg=start_result.message)
        self.assertEqual([], notes)

        def status_loader(resolved_run_root: str):
            return status_service.load_paired_status(context, run_root=resolved_run_root)

        running_result = watcher_service.wait_for_running(
            status_loader,
            str(run_root),
            timeout_sec=20.0,
            poll_interval_sec=0.5,
        )
        self.assertTrue(running_result.ok, msg=running_result.message)

        current_status, current_error = status_loader(str(run_root))
        self.assertEqual("", current_error)
        stop_result = watcher_controller.request_stop(current_status, str(run_root))
        self.assertTrue(stop_result.ok, msg=stop_result.message)

        stopped_result = watcher_service.wait_for_stopped(
            status_loader,
            str(run_root),
            request_id=stop_result.request_id,
            timeout_sec=20.0,
            poll_interval_sec=0.5,
        )
        self.assertTrue(stopped_result.ok, msg=stopped_result.message)
        command_service.reap_detached_processes(wait_timeout_sec=5.0)

        audit_log = Path(watcher_controller.audit_log_path())
        deadline = time.time() + 5.0
        while time.time() <= deadline and not audit_log.exists():
            time.sleep(0.1)
        self.assertTrue(audit_log.exists())

    def test_invalid_watcher_bridge_blocks_start_after_real_status_load(self) -> None:
        _skip_if_pwsh_unavailable()
        config_path = _default_config_path()
        run_root = APP_ROOT / "pair-test" / "bottest-live-visible" / (
            "run_controller_invalid_bridge_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        )

        command_service = CommandService()
        status_service = StatusService(command_service)
        watcher_controller = WatcherController(WatcherService())
        context = AppContext(config_path=config_path, run_root=str(run_root), pair_id="pair01", target_id="")

        prepare_command = command_service.build_script_command(
            "tests/Start-PairedExchangeTest.ps1",
            config_path=config_path,
            run_root=str(run_root),
            extra=["-IncludePairId", "pair01"],
        )
        command_service.run(prepare_command)

        state_root = run_root / ".state"
        state_root.mkdir(parents=True, exist_ok=True)
        watcher_status_path = state_root / "watcher-status.json"
        watcher_status_path.write_text(
            json.dumps(
                {
                    "SchemaVersion": "1.0.0",
                    "RunRoot": str(run_root),
                    "State": "stopped",
                    "UpdatedAt": "04/23/2026 01:11:56",
                    "HeartbeatAt": "04/23/2026 01:11:57",
                    "StatusSequence": 1,
                    "ProcessStartedAt": "2026-04-23T01:11:00+09:00",
                    "Reason": "manual-stop",
                    "StopCategory": "manual-stop",
                    "ForwardedCount": 0,
                    "ConfiguredMaxForwardCount": 2,
                    "RequestId": "",
                    "Action": "",
                    "LastHandledRequestId": "",
                    "LastHandledAction": "",
                    "LastHandledResult": "",
                    "LastHandledAt": "",
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

        paired_status, paired_error = status_service.load_paired_status(context, run_root=str(run_root))

        self.assertEqual("", paired_error)
        self.assertIsNotNone(paired_status)
        self.assertIn("watcher bridge contract invalid:", paired_status["Watcher"]["StatusParseError"])
        self.assertIn("StatusFileUpdatedAt", paired_status["Watcher"]["StatusParseError"])
        self.assertIn("HeartbeatAt", paired_status["Watcher"]["StatusParseError"])

        recording_command_service = _RecordingCommandService()
        start_result, notes = watcher_controller.start(
            recording_command_service,
            config_path=config_path,
            run_root=str(run_root),
            paired_status=paired_status,
        )

        self.assertFalse(start_result.ok)
        self.assertIn("status_file_unreadable", start_result.reason_codes)
        self.assertEqual([], notes)
        self.assertEqual([], recording_command_service.spawned_commands)


if __name__ == "__main__":
    unittest.main()
