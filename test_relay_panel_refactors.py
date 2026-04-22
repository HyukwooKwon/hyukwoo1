from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
import hashlib
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from relay_panel_audit import (
    WATCHER_AUDIT_LOCK_STALE_AFTER_SEC,
    WATCHER_AUDIT_MAX_ARCHIVES,
    WATCHER_AUDIT_MAX_BYTES,
    WATCHER_AUDIT_REQUIRED_FIELDS,
    WATCHER_AUDIT_RETENTION_DAYS,
    WatcherAuditLogger,
)
from relay_panel_artifact_controller import ArtifactTabController
from relay_panel_artifacts import ArtifactQuery, ArtifactService, TargetArtifactState
from relay_panel_contract import (
    WATCHER_BRIDGE_DERIVED_FIELDS,
    WATCHER_BRIDGE_ISO_TIMESTAMP_FIELDS,
    load_watcher_contract_fields,
)
from relay_panel_home_controller import HomeController
from relay_panel_message_config import MessageConfigService
from relay_panel_models import AppContext, DashboardRawBundle, PairSummaryModel
from relay_panel_pair_controller import PairController
from relay_panel_refresh_controller import PanelRefreshController, RuntimeRefreshResult
from relay_panel_services import (
    POWERSHELL_REQUIRED_MESSAGE,
    CommandService,
    PowerShellError,
    StatusService,
)
from relay_panel_state import DashboardAggregator
from relay_panel_watcher_controller import WatcherController
from relay_panel_watchers import WATCHER_BRIDGE_REQUIRED_FIELDS, WatcherService, WatcherStartRequest
from relay_operator_panel import ARTIFACT_SOURCE_MEMORY_SCHEMA_VERSION, RelayOperatorPanel


def make_artifact_state(
    *,
    pair_id: str = "pair01",
    target_id: str = "target01",
    latest_state: str = "ready-to-forward",
    target_folder: str = "",
    review_folder: str = "",
    blocker_reason: str = "",
    recommended_action: str = "",
    source_outbox_contract_latest_state: str = "",
    source_outbox_next_action: str = "",
    dispatch_state: str = "",
    dispatch_updated_at: str = "",
) -> TargetArtifactState:
    return TargetArtifactState(
        pair_id=pair_id,
        role_name="top",
        target_id=target_id,
        partner_target_id="target99",
        latest_state=latest_state,
        summary_present=latest_state != "summary-missing",
        done_present=False,
        error_present=latest_state == "error-present",
        zip_count=1 if latest_state != "no-zip" else 0,
        failure_count=0,
        target_folder=target_folder,
        review_folder=review_folder,
        latest_modified_at="2026-04-05T18:00:00",
        blocker_reason=blocker_reason,
        recommended_action=recommended_action,
        source_outbox_contract_latest_state=source_outbox_contract_latest_state,
        source_outbox_next_action=source_outbox_next_action,
        dispatch_state=dispatch_state,
        dispatch_updated_at=dispatch_updated_at,
        notes=[],
    )


def make_watcher_bridge_payload(**watcher_overrides: object) -> dict[str, object]:
    watcher = {
        "Status": "running",
        "MutexName": "Global\\RelayPairWatcher_test",
        "StatusFileState": "running",
        "StatusFileUpdatedAt": "2026-04-23T01:11:56.5837403+09:00",
        "HeartbeatAt": "2026-04-23T01:11:57.0000000+09:00",
        "HeartbeatAgeSeconds": 1.25,
        "StatusSequence": 3,
        "ProcessStartedAt": "2026-04-23T01:11:00.0000000+09:00",
        "StatusReason": "heartbeat",
        "StopCategory": "",
        "ForwardedCount": 0,
        "ConfiguredMaxForwardCount": 2,
        "StatusRequestId": "",
        "StatusAction": "",
        "LastHandledRequestId": "",
        "LastHandledAction": "",
        "LastHandledResult": "",
        "LastHandledAt": "",
        "StatusExists": True,
        "StatusParseError": "",
        "StatusLastWriteAt": "2026-04-23T01:11:56.6000000+09:00",
        "StatusAgeSeconds": 1.0,
        "StatusPath": "C:\\runs\\current\\.state\\watcher-status.json",
        "ControlExists": False,
        "ControlParseError": "",
        "ControlLastWriteAt": "",
        "ControlRequestedAt": "",
        "ControlAgeSeconds": None,
        "ControlPendingAction": "",
        "ControlPendingRequestId": "",
        "ControlPath": "C:\\runs\\current\\.state\\watcher-control.json",
    }
    watcher.update(watcher_overrides)
    return {"Watcher": watcher, "Counts": {}}


def require_pwsh_or_skip() -> str:
    pwsh = shutil.which("pwsh.exe") or shutil.which("pwsh")
    if not pwsh:
        raise unittest.SkipTest(POWERSHELL_REQUIRED_MESSAGE)
    return pwsh


class RecordingStatusService(StatusService):
    def __init__(self) -> None:
        self.calls: list[object] = []

    def load_effective_config(self, context: AppContext) -> dict:
        self.calls.append(("effective", context.run_root))
        return {"RunContext": {"SelectedRunRoot": context.run_root}}

    def load_relay_status(self, context: AppContext) -> dict:
        self.calls.append(("relay", context.run_root))
        return {"kind": "relay"}

    def load_visibility_status(self, context: AppContext) -> dict:
        self.calls.append(("visibility", context.run_root))
        return {"kind": "visibility"}

    def load_paired_status(self, context: AppContext, run_root: str | None = None) -> tuple[dict | None, str]:
        self.calls.append(("paired", run_root if run_root is not None else context.run_root))
        return {"kind": "paired"}, ""

    def load_dashboard_bundle(self, context: AppContext) -> DashboardRawBundle:
        self.calls.append(("bundle", context.run_root))
        return DashboardRawBundle(
            effective_data={"RunContext": {"SelectedRunRoot": context.run_root}},
            relay_status={"kind": "relay"},
            visibility_status={"kind": "visibility"},
            paired_status={"kind": "paired"},
            paired_status_error="",
        )


class RecordingCommandService:
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


class VarStub:
    def __init__(self, value: str = "") -> None:
        self.value = value

    def get(self) -> str:
        return self.value

    def set(self, value: str) -> None:
        self.value = value


class ButtonStub:
    def __init__(self) -> None:
        self.state = ""

    def configure(self, **kwargs) -> None:
        if "state" in kwargs:
            self.state = kwargs["state"]


class StatusServiceScopeTests(unittest.TestCase):
    def test_refresh_runtime_status_keeps_scope_to_runtime_sources(self) -> None:
        service = RecordingStatusService()
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\a")

        relay_payload, visibility_payload = service.refresh_runtime_status(context)

        self.assertEqual({"kind": "relay"}, relay_payload)
        self.assertEqual({"kind": "visibility"}, visibility_payload)
        self.assertEqual(
            [("relay", "C:\\runs\\a"), ("visibility", "C:\\runs\\a")],
            service.calls,
        )

    def test_refresh_paired_status_reads_only_paired_source(self) -> None:
        service = RecordingStatusService()
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\a")

        payload, error = service.refresh_paired_status(context, run_root="C:\\runs\\b")

        self.assertEqual({"kind": "paired"}, payload)
        self.assertEqual("", error)
        self.assertEqual([("paired", "C:\\runs\\b")], service.calls)

    def test_refresh_controller_quick_scope_keeps_full_reload_out(self) -> None:
        service = RecordingStatusService()
        controller = PanelRefreshController(service)
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\quick")

        result = controller.refresh_quick(context)

        self.assertEqual({"kind": "relay"}, result.runtime.relay_status)
        self.assertEqual({"kind": "visibility"}, result.runtime.visibility_status)
        self.assertEqual({"kind": "paired"}, result.paired.paired_status)
        self.assertEqual(
            [("relay", "C:\\runs\\quick"), ("visibility", "C:\\runs\\quick"), ("paired", "C:\\runs\\quick")],
            service.calls,
        )

    def test_refresh_controller_full_scope_uses_bundle_loader(self) -> None:
        service = RecordingStatusService()
        controller = PanelRefreshController(service)
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\full")

        bundle = controller.refresh_full(context)

        self.assertEqual("C:\\runs\\full", bundle.effective_data["RunContext"]["SelectedRunRoot"])
        self.assertEqual([("bundle", "C:\\runs\\full")], service.calls)

    def test_load_visibility_status_accepts_json_stdout_from_nonzero_exit(self) -> None:
        visibility_payload = {
            "InjectableCount": 0,
            "NonInjectableCount": 8,
            "MissingRuntimeCount": 0,
            "Targets": [{"TargetId": "target01", "Injectable": False, "InjectionReason": "no-visible-window"}],
        }

        class CommandServiceStub:
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
                return [script_name, *(extra or [])]

            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                if command[0] != "check-target-window-visibility.ps1":
                    raise AssertionError(command)
                raise PowerShellError(
                    "visibility failed",
                    returncode=1,
                    stdout=json.dumps(visibility_payload),
                    stderr="",
                )

        service = StatusService(CommandServiceStub())
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\full")

        payload = service.load_visibility_status(context)

        self.assertEqual(visibility_payload, payload)

    def test_run_json_script_accepts_refresh_binding_profile_json_stdout_on_error(self) -> None:
        reuse_payload = {
            "Success": False,
            "Summary": "기존 8창 재사용 실패",
            "FailureReasons": ["window-missing:target01:no-visible-window"],
        }

        class CommandServiceStub:
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
                return [script_name, *(extra or [])]

            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                if command[0] != "refresh-binding-profile-from-existing.ps1":
                    raise AssertionError(command)
                raise PowerShellError(
                    "reuse failed",
                    returncode=1,
                    stdout=json.dumps(reuse_payload),
                    stderr="",
                )

        service = StatusService(CommandServiceStub())
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\full")

        payload = service.run_json_script("refresh-binding-profile-from-existing.ps1", context, extra=["-AsJson"])

        self.assertEqual(reuse_payload, payload)

    def test_load_dashboard_bundle_keeps_visibility_payload_when_check_reports_blockers(self) -> None:
        effective_payload = {"RunContext": {"SelectedRunRoot": "C:\\runs\\selected"}}
        relay_payload = {"Runtime": {"ExpectedTargetCount": 8}}
        visibility_payload = {
            "InjectableCount": 0,
            "NonInjectableCount": 8,
            "MissingRuntimeCount": 0,
            "Targets": [{"TargetId": "target01", "Injectable": False, "InjectionReason": "no-visible-window"}],
        }
        paired_payload = make_watcher_bridge_payload(Status="stopped", StatusFileState="stopped", StatusReason="completed")

        class CommandServiceStub:
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
                return [script_name, run_root, *(extra or [])]

            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                script_name = command[0]
                if script_name == "show-effective-config.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout=json.dumps(effective_payload), stderr="")
                if script_name == "show-relay-status.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout=json.dumps(relay_payload), stderr="")
                if script_name == "check-target-window-visibility.ps1":
                    raise PowerShellError(
                        "visibility failed",
                        returncode=1,
                        stdout=json.dumps(visibility_payload),
                        stderr="",
                    )
                if script_name == "show-paired-exchange-status.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout=json.dumps(paired_payload), stderr="")
                raise AssertionError(command)

        service = StatusService(CommandServiceStub())
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\requested")

        bundle = service.load_dashboard_bundle(context)

        self.assertEqual(effective_payload, bundle.effective_data)
        self.assertEqual(relay_payload, bundle.relay_status)
        self.assertEqual(visibility_payload, bundle.visibility_status)
        self.assertEqual(paired_payload, bundle.paired_status)
        self.assertEqual("", bundle.paired_status_error)

    def test_load_paired_status_keeps_valid_watcher_bridge_clean(self) -> None:
        paired_payload = make_watcher_bridge_payload()

        class CommandServiceStub:
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
                return [script_name, run_root, *(extra or [])]

            def run_json(self, command: list[str], *, allow_json_stdout_on_error: bool = False) -> dict:
                if command[0] != "show-paired-exchange-status.ps1":
                    raise AssertionError(command)
                return paired_payload

        service = StatusService(CommandServiceStub())
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\current")

        payload, error = service.load_paired_status(context)

        self.assertEqual("", error)
        self.assertEqual("", payload["Watcher"]["StatusParseError"])

    def test_load_paired_status_annotates_invalid_watcher_bridge_and_blocks_watcher_control(self) -> None:
        paired_payload = make_watcher_bridge_payload(
            StatusFileUpdatedAt="04/23/2026 01:11:56",
        )
        del paired_payload["Watcher"]["StatusPath"]

        class CommandServiceStub:
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
                return [script_name, run_root, *(extra or [])]

            def run_json(self, command: list[str], *, allow_json_stdout_on_error: bool = False) -> dict:
                if command[0] != "show-paired-exchange-status.ps1":
                    raise AssertionError(command)
                return paired_payload

        service = StatusService(CommandServiceStub())
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\current")

        payload, error = service.load_paired_status(context)

        self.assertEqual("", error)
        self.assertIsNotNone(payload)
        self.assertIn("watcher bridge contract invalid:", payload["Watcher"]["StatusParseError"])
        self.assertIn("watcher bridge missing fields: StatusPath", payload["Watcher"]["StatusParseError"])
        self.assertIn(
            "watcher bridge invalid ISO timestamps: StatusFileUpdatedAt",
            payload["Watcher"]["StatusParseError"],
        )

        eligibility = WatcherService().get_start_eligibility(payload, run_root="C:\\runs\\current")

        self.assertFalse(eligibility.allowed)
        self.assertIn("status_file_unreadable", eligibility.reason_codes)

    def test_load_visibility_status_raises_when_nonzero_exit_stdout_is_invalid_json(self) -> None:
        class CommandServiceStub(CommandService):
            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                raise PowerShellError(
                    "visibility failed",
                    returncode=1,
                    stdout="{ invalid json",
                    stderr="",
                )

        service = StatusService(CommandServiceStub())
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\full")

        with self.assertRaises(PowerShellError):
            service.load_visibility_status(context)

    def test_run_json_script_keeps_non_policy_scripts_as_hard_failures(self) -> None:
        class CommandServiceStub(CommandService):
            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                raise PowerShellError(
                    "relay failed",
                    returncode=1,
                    stdout=json.dumps({"kind": "relay"}),
                    stderr="",
                )

        service = StatusService(CommandServiceStub())
        context = AppContext(config_path="cfg.psd1", run_root="C:\\runs\\full")

        with self.assertRaises(PowerShellError):
            service.run_json_script("show-relay-status.ps1", context, extra=["-AsJson"])

    def test_command_service_requires_pwsh_host_for_script_and_file_commands(self) -> None:
        with mock.patch("relay_panel_services.POWERSHELL", ""):
            service = CommandService()

            with self.assertRaises(PowerShellError) as script_error:
                service.build_script_command("show-relay-status.ps1", config_path="cfg.psd1")
            self.assertEqual(POWERSHELL_REQUIRED_MESSAGE, str(script_error.exception))

            with self.assertRaises(PowerShellError) as file_error:
                service.build_powershell_file_command("C:\\scripts\\wrapper.ps1")
            self.assertEqual(POWERSHELL_REQUIRED_MESSAGE, str(file_error.exception))

    def test_show_relay_status_uses_partial_binding_scope_for_expected_targets(self) -> None:
        repo_root = Path(__file__).resolve().parent
        powershell_exe = require_pwsh_or_skip()

        with tempfile.TemporaryDirectory() as tmp:
            tmp_root = Path(tmp)
            runtime_map_path = tmp_root / "runtime-map.json"
            router_state_path = tmp_root / "router-state.json"
            binding_profile_path = tmp_root / "bindings.json"
            logs_root = tmp_root / "logs"
            processed_root = tmp_root / "processed"
            failed_root = tmp_root / "failed"
            retry_pending_root = tmp_root / "retry"
            for path in (logs_root, processed_root, failed_root, retry_pending_root):
                path.mkdir(parents=True, exist_ok=True)

            target_specs = [
                ("target01", "pair01"),
                ("target05", "pair01"),
                ("target03", "pair03"),
                ("target07", "pair03"),
            ]
            target_entries: list[str] = []
            configured_targets: list[dict[str, str]] = []
            for target_id, pair_id in target_specs:
                target_folder = tmp_root / "inbox" / target_id
                target_folder.mkdir(parents=True, exist_ok=True)
                folder_literal = str(target_folder).replace("'", "''")
                target_entries.append("        @{ Id = '%s'; Folder = '%s' }" % (target_id, folder_literal))
                configured_targets.append(
                    {
                        "target_id": target_id,
                        "pair_id": pair_id,
                        "role_name": "top" if target_id.endswith("01") or target_id.endswith("03") else "bottom",
                    }
                )

            runtime_map_path.write_text(
                json.dumps(
                    [
                        {
                            "TargetId": "target01",
                            "WindowPid": 101,
                            "ShellPid": 201,
                            "Hwnd": "0x101",
                            "ResolvedBy": "binding-file",
                            "RegistrationMode": "attached",
                            "LauncherSessionId": "session-a",
                        },
                        {
                            "TargetId": "target05",
                            "WindowPid": 105,
                            "ShellPid": 205,
                            "Hwnd": "0x105",
                            "ResolvedBy": "binding-file",
                            "RegistrationMode": "attached",
                            "LauncherSessionId": "session-a",
                        },
                    ],
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )
            router_state_path.write_text("{}", encoding="utf-8")
            binding_profile_path.write_text(
                json.dumps(
                    {
                        "reuse_mode": "pairs",
                        "partial_reuse": True,
                        "configured_target_count": 4,
                        "active_expected_target_count": 2,
                        "active_pair_ids": ["pair01"],
                        "active_target_ids": ["target01", "target05"],
                        "inactive_target_ids": ["target03", "target07"],
                        "configured_targets": configured_targets,
                        "windows": [
                            {"target_id": "target01", "pair_id": "pair01"},
                            {"target_id": "target05", "pair_id": "pair01"},
                        ],
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )

            tmp_root_literal = str(tmp_root).replace("'", "''")
            runtime_map_literal = str(runtime_map_path).replace("'", "''")
            router_state_literal = str(router_state_path).replace("'", "''")
            binding_profile_literal = str(binding_profile_path).replace("'", "''")
            logs_root_literal = str(logs_root).replace("'", "''")
            processed_root_literal = str(processed_root).replace("'", "''")
            failed_root_literal = str(failed_root).replace("'", "''")
            retry_pending_root_literal = str(retry_pending_root).replace("'", "''")
            config_path = tmp_root / "settings.partial-scope.psd1"
            config_path.write_text(
                "\n".join(
                    [
                        "@{",
                        f"    Root = '{tmp_root_literal}'",
                        f"    RuntimeMapPath = '{runtime_map_literal}'",
                        f"    RouterStatePath = '{router_state_literal}'",
                        f"    BindingProfilePath = '{binding_profile_literal}'",
                        f"    LogsRoot = '{logs_root_literal}'",
                        f"    ProcessedRoot = '{processed_root_literal}'",
                        f"    FailedRoot = '{failed_root_literal}'",
                        f"    RetryPendingRoot = '{retry_pending_root_literal}'",
                        "    Targets = @(",
                        *target_entries,
                        "    )",
                        "}",
                    ]
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    powershell_exe,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(repo_root / "show-relay-status.ps1"),
                    "-ConfigPath",
                    str(config_path),
                    "-AsJson",
                ],
                cwd=repo_root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr or result.stdout)
            payload = json.loads(result.stdout)
            self.assertEqual(2, payload["Runtime"]["ExpectedTargetCount"])
            self.assertEqual(4, payload["Runtime"]["ConfiguredTargetCount"])
            self.assertEqual(["pair01"], payload["Runtime"]["ActivePairIds"])
            self.assertEqual(["target03", "target07"], payload["Runtime"]["InactiveTargetIds"])
            target_rows = {row["TargetId"]: row for row in payload["Targets"]}
            self.assertEqual("ready", target_rows["target01"]["RuntimeStatus"])
            self.assertEqual("out-of-scope", target_rows["target03"]["RuntimeStatus"])


class HomeControllerTests(unittest.TestCase):
    def test_build_overall_detail_prefers_pair_status_error(self) -> None:
        controller = HomeController()

        detail = controller.build_overall_detail(
            base_detail="ready",
            paired_status_error="pair failed",
            watcher_hint="watch=running",
        )

        self.assertEqual("ready / pair-status=pair failed", detail)

    def test_dispatch_action_handles_copy_command(self) -> None:
        controller = HomeController()
        copied: list[str] = []

        handled = controller.dispatch_action(
            "copy_command",
            handlers={},
            command_text="powershell test",
            copy_callback=copied.append,
        )

        self.assertTrue(handled)
        self.assertEqual(["powershell test"], copied)


class PairControllerTests(unittest.TestCase):
    def test_build_summary_detail_includes_actionable_latest_state_hint(self) -> None:
        controller = PairController()

        detail = controller.build_summary_detail(
            PairSummaryModel(
                pair_id="pair01",
                targets="target01 ↔ target05",
                enabled=True,
                latest_state="summary-stale",
                zip_count=1,
                failure_count=0,
                lane_watcher_status="running",
                detail="state=summary-stale zip=1 fail=0",
            )
        )

        self.assertIn("차단 이유=summary.txt가 최신 zip보다 오래됐습니다.", detail)
        self.assertIn("다음 조치=summary 갱신 확인", detail)

    def test_resolve_top_target_for_pair_prefers_preview_rows(self) -> None:
        controller = PairController()

        target_id = controller.resolve_top_target_for_pair(
            [
                {"PairId": "pair01", "RoleName": "bottom", "TargetId": "target05"},
                {"PairId": "pair01", "RoleName": "top", "TargetId": "target01"},
            ],
            "pair01",
        )

        self.assertEqual("target01", target_id)

    def test_resolve_top_target_for_pair_uses_fallback(self) -> None:
        controller = PairController()

        target_id = controller.resolve_top_target_for_pair([], "pair03")

        self.assertEqual("target03", target_id)


class ArtifactServiceTests(unittest.TestCase):
    def test_compute_target_artifact_states_sets_blocker_reason_and_action(self) -> None:
        service = ArtifactService()
        effective_data = {
            "PreviewRows": [
                {
                    "PairId": "pair01",
                    "RoleName": "top",
                    "TargetId": "target01",
                    "PartnerTargetId": "target05",
                    "PairTargetFolder": "C:\\runs\\current\\pair01\\target01",
                    "ReviewFolderPath": "C:\\runs\\current\\pair01\\target01\\reviewfile",
                }
            ]
        }
        paired_status = {
            "Targets": [
                {
                    "PairId": "pair01",
                    "RoleName": "top",
                    "TargetId": "target01",
                    "PartnerTargetId": "target05",
                    "LatestState": "summary-stale",
                    "ZipCount": 1,
                    "FailureCount": 0,
                    "TargetFolder": "C:\\runs\\current\\pair01\\target01",
                }
            ]
        }

        states = service.compute_target_artifact_states(effective_data, paired_status)

        self.assertEqual(1, len(states))
        self.assertEqual("summary.txt가 최신 zip보다 오래됐습니다.", states[0].blocker_reason)
        self.assertEqual("summary 갱신 확인", states[0].recommended_action)

    def test_filter_target_artifact_states_applies_run_root_in_memory(self) -> None:
        service = ArtifactService()
        states = [
            make_artifact_state(
                target_id="target01",
                target_folder="C:\\runs\\current\\pair01\\target01",
                review_folder="C:\\runs\\current\\pair01\\target01\\reviewfile",
            ),
            make_artifact_state(
                target_id="target02",
                target_folder="C:\\runs\\other\\pair01\\target02",
                review_folder="C:\\runs\\other\\pair01\\target02\\reviewfile",
            ),
        ]

        filtered = service.filter_target_artifact_states(
            states,
            ArtifactQuery(run_root="C:\\runs\\current"),
        )

        self.assertEqual(["target01"], [item.target_id for item in filtered])

    def test_filter_target_artifact_states_can_hide_problem_rows(self) -> None:
        service = ArtifactService()
        states = [
            make_artifact_state(target_id="target01", latest_state="ready-to-forward"),
            make_artifact_state(target_id="target02", latest_state="summary-missing"),
        ]

        filtered = service.filter_target_artifact_states(
            states,
            ArtifactQuery(run_root="", include_missing=False),
        )

        self.assertEqual(["target01"], [item.target_id for item in filtered])

    def test_compute_target_artifact_states_surfaces_source_outbox_and_dispatch_fields(self) -> None:
        service = ArtifactService()
        effective_data = {
            "PreviewRows": [
                {
                    "PairId": "pair01",
                    "RoleName": "top",
                    "TargetId": "target01",
                    "PartnerTargetId": "target05",
                    "PairTargetFolder": "C:\\runs\\current\\pair01\\target01",
                    "ReviewFolderPath": "C:\\runs\\current\\pair01\\target01\\reviewfile",
                }
            ]
        }
        paired_status = {
            "Targets": [
                {
                    "PairId": "pair01",
                    "RoleName": "top",
                    "TargetId": "target01",
                    "PartnerTargetId": "target05",
                    "LatestState": "ready-to-forward",
                    "SourceOutboxContractLatestState": "ready-to-forward",
                    "SourceOutboxNextAction": "handoff-ready",
                    "DispatchState": "running",
                    "DispatchUpdatedAt": "2026-04-22T15:15:00",
                    "ZipCount": 1,
                    "FailureCount": 0,
                    "TargetFolder": "C:\\runs\\current\\pair01\\target01",
                }
            ]
        }

        states = service.compute_target_artifact_states(effective_data, paired_status)

        self.assertEqual(1, len(states))
        self.assertEqual("ready-to-forward", states[0].source_outbox_contract_latest_state)
        self.assertEqual("handoff-ready", states[0].source_outbox_next_action)
        self.assertEqual("running", states[0].dispatch_state)
        self.assertEqual("2026-04-22T15:15:00", states[0].dispatch_updated_at)
        self.assertEqual("다음 전달 가능 / 후속 실행 중", service.format_target_state_label(states[0]))
        self.assertTrue(any("source-outbox 다음 동작: 다음 전달 가능" in note for note in states[0].notes))
        self.assertTrue(any("후속 실행 상태: 후속 실행 중" in note for note in states[0].notes))


class ArtifactControllerTests(unittest.TestCase):
    def test_build_view_state_resolves_selected_target_and_status_text(self) -> None:
        controller = ArtifactTabController(ArtifactService())
        effective_data = {
            "PreviewRows": [
                {
                    "PairId": "pair01",
                    "RoleName": "top",
                    "TargetId": "target01",
                    "PartnerTargetId": "target05",
                    "PairTargetFolder": "C:\\runs\\current\\pair01\\target01",
                    "ReviewFolderPath": "C:\\runs\\current\\pair01\\target01\\reviewfile",
                }
            ]
        }
        paired_status = {
            "Targets": [
                {
                    "PairId": "pair01",
                    "RoleName": "top",
                    "TargetId": "target01",
                    "PartnerTargetId": "target05",
                    "LatestState": "ready-to-forward",
                    "ZipCount": 1,
                    "FailureCount": 0,
                    "TargetFolder": "C:\\runs\\current\\pair01\\target01",
                }
            ]
        }

        view_state = controller.build_view_state(
            effective_data=effective_data,
            paired_status=paired_status,
            query=ArtifactQuery(run_root="C:\\runs\\current"),
            selected_target_id="target01",
            watcher_status="running",
            paired_status_error="",
        )

        self.assertEqual("target01", view_state.selected_target_id)
        self.assertEqual(["", "pair01"], view_state.pair_values)
        self.assertIn("watcher=running", view_state.status_text)
        self.assertIn("차단=최신 zip이 다음 전달 가능 상태입니다.", view_state.status_text)
        self.assertIn("다음=전달 가능 target 확인", view_state.status_text)
        self.assertEqual(1, len(view_state.states))

    def test_decorate_status_text_uses_current_preview_selection(self) -> None:
        controller = ArtifactTabController(ArtifactService())
        preview = controller.get_preview(
            [
                make_artifact_state(
                    target_id="target02",
                    latest_state="summary-missing",
                    target_folder="C:\\runs\\current\\pair01\\target02",
                    review_folder="C:\\runs\\current\\pair01\\target02\\reviewfile",
                    blocker_reason="summary 파일이 최신 zip 기준으로 없습니다.",
                    recommended_action="summary 갱신 확인",
                )
            ],
            "target02",
        )

        text = controller.decorate_status_text("run=current | watcher=running", preview)

        self.assertIn("selected=pair01 / target02 (top)", text)
        self.assertIn("차단=summary 파일이 최신 zip 기준으로 없습니다.", text)
        self.assertIn("다음=summary 갱신 확인", text)

    def test_build_view_state_reports_handoff_ready_and_dispatch_running(self) -> None:
        controller = ArtifactTabController(ArtifactService())
        effective_data = {
            "PreviewRows": [
                {
                    "PairId": "pair01",
                    "RoleName": "top",
                    "TargetId": "target01",
                    "PartnerTargetId": "target05",
                    "PairTargetFolder": "C:\\runs\\current\\pair01\\target01",
                    "ReviewFolderPath": "C:\\runs\\current\\pair01\\target01\\reviewfile",
                }
            ]
        }
        paired_status = {
            "Targets": [
                {
                    "PairId": "pair01",
                    "RoleName": "top",
                    "TargetId": "target01",
                    "PartnerTargetId": "target05",
                    "LatestState": "ready-to-forward",
                    "SourceOutboxNextAction": "handoff-ready",
                    "DispatchState": "running",
                    "ZipCount": 1,
                    "FailureCount": 0,
                    "TargetFolder": "C:\\runs\\current\\pair01\\target01",
                }
            ]
        }

        view_state = controller.build_view_state(
            effective_data=effective_data,
            paired_status=paired_status,
            query=ArtifactQuery(run_root="C:\\runs\\current"),
            selected_target_id="target01",
            watcher_status="stopped/expected-limit",
            paired_status_error="",
        )

        self.assertIn("watcher=stopped/expected-limit", view_state.status_text)
        self.assertIn("ready=1", view_state.status_text)
        self.assertIn("dispatchRunning=1", view_state.status_text)
        self.assertIn("next=다음 전달 가능", view_state.status_text)
        self.assertIn("dispatch=후속 실행 중", view_state.status_text)


class WatcherAuditTests(unittest.TestCase):
    def test_audit_logger_appends_json_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            logger = WatcherAuditLogger(Path(tmp))

            log_path = logger.record(
                action="start",
                run_root="C:\\runs\\current",
                requested_by="panel",
                ok=True,
                state="starting",
                message="started",
                request_id="req-1",
                reason_codes=["verify_running_required"],
            )

            self.assertTrue(log_path.exists())
            payload = json.loads(log_path.read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual("start", payload["Action"])
            self.assertEqual("req-1", payload["RequestId"])
            self.assertEqual("panel", payload["RequestedBy"])
            self.assertTrue(payload["ActionId"])
            self.assertTrue(payload["RunRootHash"])

    def test_audit_logger_rotates_and_prunes_archives(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            logger = WatcherAuditLogger(Path(tmp))
            logger.max_bytes = 1
            logger.max_archives = 1
            logger.retention_days = 1

            logger.record(
                action="start",
                run_root="C:\\runs\\a",
                requested_by="panel",
                ok=True,
                state="starting",
                message="one",
            )
            logger.record(
                action="stop",
                run_root="C:\\runs\\a",
                requested_by="panel",
                ok=True,
                state="stop_requested",
                message="two",
            )

            archives = sorted((Path(tmp) / "logs").glob("watcher-control-audit.*.jsonl"))
            self.assertGreaterEqual(len(archives), 1)

            old_archive = (Path(tmp) / "logs" / "watcher-control-audit.20000101_000000.jsonl")
            old_archive.write_text("{}", encoding="utf-8")
            old_time = 946684800
            os.utime(old_archive, (old_time, old_time))

            logger.record(
                action="restart",
                run_root="C:\\runs\\a",
                requested_by="panel",
                ok=True,
                state="running",
                message="three",
            )

            self.assertFalse(old_archive.exists())

    def test_audit_logger_breaks_stale_lock_and_records(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            logger = WatcherAuditLogger(Path(tmp))
            logger.lock_path.write_text("{}", encoding="utf-8")
            old_time = time.time() - (WATCHER_AUDIT_LOCK_STALE_AFTER_SEC + 5.0)
            os.utime(logger.lock_path, (old_time, old_time))

            logger.record(
                action="start",
                run_root="C:\\runs\\stale",
                requested_by="panel",
                ok=True,
                state="starting",
                message="stale lock recovered",
            )

            lines = logger.log_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(1, len(lines))
            self.assertFalse(logger.lock_path.exists())


class WatcherContractDriftGuardTests(unittest.TestCase):
    def test_contract_field_ssot_matches_python_constants(self) -> None:
        field_spec = load_watcher_contract_fields()

        self.assertEqual(list(WATCHER_BRIDGE_REQUIRED_FIELDS), field_spec["WatcherBridgeRequiredFields"])
        self.assertEqual(list(WATCHER_BRIDGE_ISO_TIMESTAMP_FIELDS), field_spec["WatcherBridgeIsoTimestampFields"])
        self.assertEqual(list(WATCHER_BRIDGE_DERIVED_FIELDS), field_spec["WatcherBridgeDerivedFields"])
        self.assertEqual(list(WATCHER_AUDIT_REQUIRED_FIELDS), field_spec["WatcherAuditRequiredFields"])
        self.assertEqual(WATCHER_AUDIT_MAX_BYTES, field_spec["WatcherAuditPolicy"]["MaxBytes"])
        self.assertEqual(WATCHER_AUDIT_MAX_ARCHIVES, field_spec["WatcherAuditPolicy"]["MaxArchives"])
        self.assertEqual(WATCHER_AUDIT_RETENTION_DAYS, field_spec["WatcherAuditPolicy"]["RetentionDays"])

    def test_contract_markdown_mentions_ssot_fields(self) -> None:
        markdown = Path("docs/WATCHER-CONTROL-CONTRACT.md").read_text(encoding="utf-8")
        field_spec = load_watcher_contract_fields()

        for field_name in field_spec["WatcherBridgeRequiredFields"]:
            self.assertIn(field_name, markdown)
        for field_name in field_spec["WatcherBridgeIsoTimestampFields"]:
            self.assertIn(field_name, markdown)
        for field_name in field_spec["WatcherBridgeDerivedFields"]:
            self.assertIn(field_name, markdown)
        for field_name in field_spec["WatcherAuditRequiredFields"]:
            self.assertIn(field_name, markdown)

    def test_contract_loader_reads_same_file_path_used_by_tests(self) -> None:
        raw_spec = json.loads(Path("docs/WATCHER-CONTRACT-FIELDS.json").read_text(encoding="utf-8"))
        self.assertEqual(raw_spec, load_watcher_contract_fields())

    def test_contract_markdown_mentions_scope_boundary_and_pwsh_host_contract(self) -> None:
        markdown = Path("docs/WATCHER-CONTROL-CONTRACT.md").read_text(encoding="utf-8")

        self.assertIn("`Watcher.*` 브리지 필드 전용", markdown)
        self.assertIn("paired status 전체 ISO 필드 계약은 별도 SSOT", markdown)
        self.assertIn("pwsh", markdown)
        self.assertIn("PowerShell 7+", markdown)


class PairedExchangePromptTextTests(unittest.TestCase):
    def test_handoff_defaults_keep_summary_contract_and_explicit_review_instruction(self) -> None:
        expected_suffix = "최종 결과는 내 SourceOutboxPath 아래의 summary.txt 와 review.zip 으로만 정리하고, 마지막에 publish.ready.json 을 생성하세요."
        expected_step = "3. 최종 결과만 내 SourceOutboxPath 아래의 summary.txt 와 review.zip 으로 생성합니다."
        expected_publish_step = "4. summary.txt 와 review.zip 작성이 끝난 뒤 마지막에 publish.ready.json 을 생성합니다."
        expected_publish_guard = "직접 target contract 경로에 복사하거나 별도 submit 명령을 다시 실행하지 마세요."

        for path_str in [
            "tests/PairedExchangeConfig.ps1",
        ]:
            text = Path(path_str).read_text(encoding="utf-8")
            self.assertIn(expected_suffix, text, path_str)
            self.assertIn(expected_publish_guard, text, path_str)

        for path_str in [
            "tests/Watch-PairedExchange.ps1",
            "tests/Show-EffectiveConfig.ps1",
        ]:
            text = Path(path_str).read_text(encoding="utf-8")
            self.assertIn(expected_step, text, path_str)
            self.assertIn(expected_publish_step, text, path_str)
            self.assertIn("5. 직접 target contract 경로에 복사하거나 별도 submit 명령을 다시 실행하지 마세요.", text, path_str)

    def test_initial_defaults_explain_review_zip_is_auto_forward_artifact(self) -> None:
        expected_outbox_note = "최종 source 산출물은 '$SourceOutboxPath' 아래의 '$sourceSummaryFileName' 와 '$sourceReviewZipFileName' 으로만 정리합니다."
        expected_ready_note = "publish 완료 신호는 '$PublishReadyPath' 파일입니다."
        expected_publish_note = "직접 paired contract 경로(SummaryPath / ReviewFolderPath / Done/Result)에 복사하지 마세요."

        start_text = Path("tests/Start-PairedExchangeTest.ps1").read_text(encoding="utf-8")
        self.assertIn(expected_outbox_note, start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn(expected_ready_note, start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn(expected_publish_note, start_text, "tests/Start-PairedExchangeTest.ps1")

        show_effective_text = Path("tests/Show-EffectiveConfig.ps1").read_text(encoding="utf-8")
        self.assertIn("Source Outbox Path:", show_effective_text, "tests/Show-EffectiveConfig.ps1")
        self.assertIn("Publish Ready Path:", show_effective_text, "tests/Show-EffectiveConfig.ps1")
        self.assertIn("Published Archive Path:", show_effective_text, "tests/Show-EffectiveConfig.ps1")

        for path_str in [
            "tests/PairedExchangeConfig.ps1",
        ]:
            text = Path(path_str).read_text(encoding="utf-8")
            self.assertIn("추가 검토 메모가 필요하면 내 폴더(target folder)에 매번 새 이름의 txt 파일을 만들고, 그 txt를 새 review zip에 포함하세요.", text, path_str)
            self.assertIn("자동 전달되는 새 파일명은 내 폴더 reviewfile의 새 review zip 이름입니다.", text, path_str)

    def test_prompt_and_request_contracts_include_absolute_review_and_output_paths(self) -> None:
        start_text = Path("tests/Start-PairedExchangeTest.ps1").read_text(encoding="utf-8")
        self.assertIn("[자동 경로 안내]", start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn("먼저 확인할 파일:", start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn("먼저 확인할 검토 입력 파일 없음.", start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn("AvailablePaths", start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn("내가 생성할 파일:", start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn("OwnTargetFolder", start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn("PartnerTargetFolder", start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn("ReviewInputFiles", start_text, "tests/Start-PairedExchangeTest.ps1")
        self.assertIn("OutputFiles", start_text, "tests/Start-PairedExchangeTest.ps1")

        show_effective_text = Path("tests/Show-EffectiveConfig.ps1").read_text(encoding="utf-8")
        self.assertIn("[자동 경로 안내]", show_effective_text, "tests/Show-EffectiveConfig.ps1")
        self.assertIn("먼저 확인할 파일:", show_effective_text, "tests/Show-EffectiveConfig.ps1")
        self.assertIn("먼저 확인할 검토 입력 파일 없음.", show_effective_text, "tests/Show-EffectiveConfig.ps1")
        self.assertIn("AvailablePaths", show_effective_text, "tests/Show-EffectiveConfig.ps1")
        self.assertIn("내가 생성할 파일:", show_effective_text, "tests/Show-EffectiveConfig.ps1")

        watch_text = Path("tests/Watch-PairedExchange.ps1").read_text(encoding="utf-8")
        self.assertIn("[자동 경로 안내]", watch_text, "tests/Watch-PairedExchange.ps1")
        self.assertIn("먼저 확인할 파일:", watch_text, "tests/Watch-PairedExchange.ps1")
        self.assertIn("먼저 확인할 검토 입력 파일 없음.", watch_text, "tests/Watch-PairedExchange.ps1")
        self.assertIn("내가 생성할 파일:", watch_text, "tests/Watch-PairedExchange.ps1")

    def test_show_effective_config_handles_handoff_preview_zip_pattern_in_real_runroot(self) -> None:
        repo_root = Path(__file__).resolve().parent
        config_path = repo_root / "config" / "settings.bottest-live-visible.psd1"
        powershell_exe = require_pwsh_or_skip()

        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp) / "run_real_preview"
            start_command = [
                powershell_exe,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(repo_root / "tests" / "Start-PairedExchangeTest.ps1"),
                "-ConfigPath",
                str(config_path),
                "-RunRoot",
                str(run_root),
                "-IncludePairId",
                "pair01",
            ]
            start_result = subprocess.run(
                start_command,
                cwd=repo_root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            self.assertEqual(0, start_result.returncode, start_result.stderr or start_result.stdout)

            show_command = [
                powershell_exe,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(repo_root / "tests" / "Show-EffectiveConfig.ps1"),
                "-ConfigPath",
                str(config_path),
                "-RunRoot",
                str(run_root),
                "-TargetId",
                "target01",
                "-AsJson",
            ]
            show_result = subprocess.run(
                show_command,
                cwd=repo_root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            self.assertEqual(0, show_result.returncode, show_result.stderr or show_result.stdout)
            payload = json.loads(show_result.stdout)
            self.assertTrue(payload["PreviewRows"], show_result.stdout)
            row = payload["PreviewRows"][0]
            self.assertIn("<yyyyMMdd_HHmmss>", row["ReviewZipPreviewPath"])
            self.assertIn(
                "먼저 확인할 검토 입력 파일 없음.",
                row["Handoff"]["Preview"],
            )

    def test_watch_handoff_uses_recipient_role_and_target_overrides(self) -> None:
        repo_root = Path(__file__).resolve().parent
        source_config = repo_root / "config" / "settings.bottest-live-visible.psd1"
        powershell_exe = require_pwsh_or_skip()

        with tempfile.TemporaryDirectory() as tmp:
            tmp_root = Path(tmp)
            config_path = tmp_root / "settings.handoff-recipient.psd1"
            config_text = source_config.read_text(encoding="utf-8")
            inbox_root = tmp_root / "inbox"
            for target_id in ("target01", "target05"):
                target_folder = str((inbox_root / target_id).resolve())
                config_text = config_text.replace(
                    f"Folder = 'C:\\dev\\python\\hyukwoo\\hyukwoo1\\inbox\\bottest-live-visible\\{target_id}'",
                    f"Folder = '{target_folder}'",
                )
            config_path.write_text(config_text, encoding="utf-8")

            run_root = tmp_root / "run_handoff_recipient"
            start_command = [
                powershell_exe,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(repo_root / "tests" / "Start-PairedExchangeTest.ps1"),
                "-ConfigPath",
                str(config_path),
                "-RunRoot",
                str(run_root),
                "-IncludePairId",
                "pair01",
                "-SeedTargetId",
                "target01",
            ]
            start_result = subprocess.run(
                start_command,
                cwd=repo_root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            self.assertEqual(0, start_result.returncode, start_result.stderr or start_result.stdout)

            source_outbox = run_root / "pair01" / "target01" / "source-outbox"
            summary_path = source_outbox / "summary.txt"
            review_zip_path = source_outbox / "review.zip"
            publish_ready_path = source_outbox / "publish.ready.json"

            summary_path.write_text("target01 summary", encoding="utf-8")
            with zipfile.ZipFile(review_zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zip_file:
                zip_file.writestr("note.txt", "target01 review zip")

            publish_ready_path.write_text(
                json.dumps(
                    {
                        "SchemaVersion": 1,
                        "PairId": "pair01",
                        "TargetId": "target01",
                        "SummaryPath": str(summary_path),
                        "ReviewZipPath": str(review_zip_path),
                        "PublishedAt": datetime.now(timezone.utc).isoformat(),
                        "SummarySizeBytes": summary_path.stat().st_size,
                        "ReviewZipSizeBytes": review_zip_path.stat().st_size,
                        "SummarySha256": hashlib.sha256(summary_path.read_bytes()).hexdigest(),
                        "ReviewZipSha256": hashlib.sha256(review_zip_path.read_bytes()).hexdigest(),
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )

            watch_command = [
                powershell_exe,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(repo_root / "tests" / "Watch-PairedExchange.ps1"),
                "-ConfigPath",
                str(config_path),
                "-RunRoot",
                str(run_root),
                "-RunDurationSec",
                "5",
            ]
            watch_result = subprocess.run(
                watch_command,
                cwd=repo_root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            self.assertEqual(0, watch_result.returncode, watch_result.stderr or watch_result.stdout)

            handoff_files = sorted((run_root / "messages").glob("handoff_target01_to_target05_*.txt"))
            self.assertTrue(handoff_files, watch_result.stdout)
            handoff_text = handoff_files[-1].read_text(encoding="utf-8")

            self.assertIn("당신은 하단 창입니다. 상단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.", handoff_text)
            self.assertIn("target05는 target01이 만든 산출물을 이어받아 중간 왕복을 수행합니다.", handoff_text)
            self.assertNotIn("당신은 상단 창입니다. 하단 파트너가 보낸 결과를 이어받아 다음 작업을 진행하세요.", handoff_text)
            self.assertNotIn("target01은 target05가 넘긴 결과를 다시 이어받아 마지막 왕복을 마무리합니다.", handoff_text)

    def test_send_initial_pair_seed_returns_ready_path_for_long_target_folder(self) -> None:
        repo_root = Path(__file__).resolve().parent
        powershell_exe = require_pwsh_or_skip()

        with tempfile.TemporaryDirectory() as tmp:
            tmp_root = Path(tmp)
            inbox_root = tmp_root / "very" / "long" / "nested" / "inbox" / "path" / "for" / "seed" / "target01"
            inbox_root.mkdir(parents=True)
            inbox_literal = str(inbox_root).replace("'", "''")
            run_root = tmp_root / ("run_" + ("preview_" * 12))
            message_root = run_root / "messages"
            message_root.mkdir(parents=True)
            message_path = message_root / "target01.txt"
            message_path.write_text("seed message", encoding="utf-8")

            manifest_path = run_root / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "Targets": [
                            {
                                "TargetId": "target01",
                                "MessagePath": str(message_path),
                                "SeedEnabled": True,
                                "InitialRoleMode": "seed",
                            }
                        ],
                        "SeedTargetIds": ["target01"],
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )

            config_path = tmp_root / "settings.test.psd1"
            config_path.write_text(
                "\n".join(
                    [
                        "@{",
                        "    Targets = @(",
                        f"        @{{ Id = 'target01'; Folder = '{inbox_literal}' }}",
                        "    )",
                        "}",
                    ]
                ),
                encoding="utf-8",
            )

            command = [
                powershell_exe,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(repo_root / "tests" / "Send-InitialPairSeed.ps1"),
                "-ConfigPath",
                str(config_path),
                "-RunRoot",
                str(run_root),
                "-TargetId",
                "target01",
                "-AsJson",
            ]
            result = subprocess.run(
                command,
                cwd=repo_root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr or result.stdout)

            payload = json.loads(result.stdout)
            ready_path = payload["Results"][0]["ReadyPath"]
            producer_output = payload["Results"][0]["ProducerOutput"]
            self.assertTrue(ready_path, producer_output)
            self.assertTrue(Path(ready_path).is_file(), ready_path)
            self.assertIn("created ready file:", producer_output)


class MessageConfigServiceTests(unittest.TestCase):
    def test_snapshot_and_diff_capture_slot_order_and_suffixes(self) -> None:
        service = MessageConfigService(CommandService())
        document = {
            "DefaultFixedSuffix": "기본 문구",
            "PairTest": {
                "MessageTemplates": {
                    "Initial": {
                        "SlotOrder": ["global-prefix", "body", "global-suffix"],
                        "PrefixBlocks": ["a"],
                        "SuffixBlocks": ["b"],
                    },
                    "Handoff": {
                        "PrefixBlocks": ["c"],
                        "SuffixBlocks": ["d"],
                    },
                },
                "PairOverrides": {"pair01": {"InitialExtraBlocks": ["p1"]}},
                "RoleOverrides": {},
                "TargetOverrides": {},
            },
            "Targets": [{"Id": "target01", "FixedSuffix": "개별"}],
        }

        original = service.clone_document(document)
        service.set_slot_order(document, "Initial", ["body", "global-prefix"])
        service.set_target_fixed_suffix(document, "target01", "새 문구")
        diff_text = service.diff_text(original, document)

        self.assertIn('"SlotOrder"', diff_text)
        self.assertIn('"새 문구"', diff_text)

    def test_save_and_rollback_restore_previous_config(self) -> None:
        service = MessageConfigService(CommandService())
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "settings.test.psd1"
            config_path.write_text(
                "@{\n"
                "    DefaultFixedSuffix = '원본'\n"
                "    PairTest = @{\n"
                "        MessageTemplates = @{\n"
                "            Initial = @{ PrefixBlocks = @('a'); SuffixBlocks = @('b') }\n"
                "            Handoff = @{ PrefixBlocks = @('c'); SuffixBlocks = @('d') }\n"
                "        }\n"
                "        PairOverrides = @{}\n"
                "        RoleOverrides = @{}\n"
                "        TargetOverrides = @{}\n"
                "    }\n"
                "    Targets = @(\n"
                "        @{ Id = 'target01'; FixedSuffix = $null }\n"
                "    )\n"
                "}\n",
                encoding="utf-8",
            )
            document = service.load_config_document(str(config_path))
            service.set_default_fixed_suffix(document, "변경")
            backup_path = service.save_document(str(config_path), document)
            self.assertTrue(backup_path.exists())
            self.assertIn("변경", config_path.read_text(encoding="utf-8"))

            restored = service.rollback_last_backup(str(config_path))
            self.assertTrue(restored.exists())
            self.assertIn("원본", config_path.read_text(encoding="utf-8"))

    def test_slot_order_save_flows_into_show_effective_config(self) -> None:
        service = MessageConfigService(CommandService())
        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            source_config = Path("config/settings.bottest-live-visible.psd1")
            config_path = temp_root / "settings.slot-order.psd1"
            shutil.copy2(source_config, config_path)

            document = service.load_config_document(str(config_path))
            service.set_slot_order(
                document,
                "Initial",
                ["body", "global-prefix", "pair-extra", "role-extra", "target-extra", "one-time-prefix", "one-time-suffix", "global-suffix"],
            )
            service.save_document(str(config_path), document)

            command_service = CommandService()
            run_root = temp_root / "pair-test" / ("run_slot_order_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f"))
            prepare = command_service.build_script_command(
                "tests/Start-PairedExchangeTest.ps1",
                config_path=str(config_path),
                run_root=str(run_root),
                extra=["-IncludePairId", "pair01"],
            )
            command_service.run(prepare)

            preview = command_service.run_json(
                command_service.build_script_command(
                    "show-effective-config.ps1",
                    config_path=str(config_path),
                    run_root=str(run_root),
                    pair_id="pair01",
                    target_id="target01",
                    extra=["-Mode", "initial", "-AsJson"],
                )
            )
            row = preview["PreviewRows"][0]
            self.assertEqual("body", row["Initial"]["SlotOrder"][0])
            self.assertEqual("body", row["Initial"]["MessagePlan"]["Order"][0])
            self.assertTrue(str(row["Initial"]["Preview"]).startswith("[paired-exchange]"))

    def test_render_effective_preview_can_use_unsaved_document(self) -> None:
        service = MessageConfigService(CommandService())
        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            source_config = Path("config/settings.bottest-live-visible.psd1")
            config_path = temp_root / "settings.preview-edit.psd1"
            shutil.copy2(source_config, config_path)

            document = service.load_config_document(str(config_path))
            edited_blocks = service.get_blocks(document, "pair-extra", "pair01", "Initial")
            edited_blocks.append("임시 preview 전용 문구")
            service.set_blocks(document, "pair-extra", "pair01", "Initial", edited_blocks)
            run_root = temp_root / "pair-test" / "draft_preview_run"

            preview = service.render_effective_preview(
                document,
                config_path=str(config_path),
                run_root=str(run_root),
                pair_id="pair01",
                target_id="target01",
                mode="initial",
            )

            row = preview["PreviewRows"][0]
            self.assertIn("임시 preview 전용 문구", row["Initial"]["Preview"])
            self.assertNotIn("임시 preview 전용 문구", config_path.read_text(encoding="utf-8"))

    def test_validate_document_reports_duplicate_blocks(self) -> None:
        service = MessageConfigService(CommandService())
        document = {
            "DefaultFixedSuffix": "",
            "PairTest": {
                "MessageTemplates": {
                    "Initial": {
                        "SlotOrder": list(service.get_slot_order({"PairTest": {"MessageTemplates": {"Initial": {}}}}, "Initial")),
                        "PrefixBlocks": ["same", "same"],
                        "SuffixBlocks": [],
                    },
                    "Handoff": {
                        "PrefixBlocks": [],
                        "SuffixBlocks": [],
                    },
                },
                "PairOverrides": {},
                "RoleOverrides": {},
                "TargetOverrides": {},
            },
            "Targets": [{"Id": "target01"}],
        }

        issues = service.validate_document(document, template_name="Initial", scope_kind="global-prefix", scope_id="")

        self.assertTrue(any(item["code"] == "duplicate_blocks" for item in issues))

    def test_diff_summary_counts_block_and_suffix_changes(self) -> None:
        service = MessageConfigService(CommandService())
        original = {
            "DefaultFixedSuffix": "a",
            "PairTest": {
                "MessageTemplates": {
                    "Initial": {"PrefixBlocks": ["p1"], "SuffixBlocks": ["s1"], "SlotOrder": list(service.get_slot_order({"PairTest": {"MessageTemplates": {"Initial": {}}}}, "Initial"))},
                    "Handoff": {"PrefixBlocks": [], "SuffixBlocks": []},
                },
                "PairOverrides": {},
                "RoleOverrides": {},
                "TargetOverrides": {},
            },
            "Targets": [{"Id": "target01", "FixedSuffix": ""}],
        }
        edited = service.clone_document(original)
        service.set_blocks(edited, "global-prefix", "", "Initial", ["p1", "p2"])
        service.set_target_fixed_suffix(edited, "target01", "new")
        service.set_slot_order(edited, "Initial", ["body", "global-prefix"])

        summary = service.diff_summary(original, edited)

        self.assertGreaterEqual(summary["slot_order_changes"], 1)
        self.assertGreaterEqual(summary["block_scope_changes"], 1)
        self.assertGreaterEqual(summary["added_blocks"], 1)
        self.assertGreaterEqual(summary["fixed_suffix_changes"], 1)

    def test_collect_change_entries_includes_scope_slot_and_suffix_changes(self) -> None:
        service = MessageConfigService(CommandService())
        original = {
            "DefaultFixedSuffix": "기본",
            "PairTest": {
                "MessageTemplates": {
                    "Initial": {
                        "PrefixBlocks": ["p1"],
                        "SuffixBlocks": ["s1"],
                        "SlotOrder": list(service.get_slot_order({"PairTest": {"MessageTemplates": {"Initial": {}}}}, "Initial")),
                    },
                    "Handoff": {"PrefixBlocks": [], "SuffixBlocks": []},
                },
                "PairOverrides": {"pair01": {"InitialExtraBlocks": ["pair-a"]}},
                "RoleOverrides": {},
                "TargetOverrides": {},
            },
            "Targets": [{"Id": "target01", "FixedSuffix": ""}],
        }
        edited = service.clone_document(original)
        service.set_slot_order(edited, "Initial", ["body", "global-prefix"])
        service.set_blocks(edited, "pair-extra", "pair01", "Initial", ["pair-a", "pair-b"])
        service.set_default_fixed_suffix(edited, "변경")
        service.set_target_fixed_suffix(edited, "target01", "개별")

        entries = service.collect_change_entries(original, edited)
        labels = {entry["label"] for entry in entries}
        change_types = {entry["change_type"] for entry in entries}

        self.assertIn("Initial SlotOrder", labels)
        self.assertIn("Initial / Pair Extra:pair01", labels)
        self.assertIn("기본 고정문구", labels)
        self.assertIn("Target 고정문구:target01", labels)
        self.assertIn("slot_order", change_types)
        self.assertIn("blocks", change_types)
        self.assertIn("default_fixed_suffix", change_types)
        self.assertIn("target_fixed_suffix", change_types)

    def test_validation_scope_keys_prefers_direct_scope_lookup(self) -> None:
        service = MessageConfigService(CommandService())
        document = {
            "PairTest": {
                "MessageTemplates": {
                    "Initial": {},
                    "Handoff": {},
                },
                "PairOverrides": {"pair01": {"InitialExtraBlocks": ["pair block"]}},
                "RoleOverrides": {"top": {"InitialExtraBlocks": ["role block"]}},
                "TargetOverrides": {"target01": {"InitialExtraBlocks": ["target block"]}},
            },
            "Targets": [{"Id": "target01"}],
        }

        self.assertEqual(
            [("target-extra", "target01")],
            service._validation_scope_keys(document, scope_kind="target-extra", scope_id="target01"),
        )
        self.assertEqual(
            [("global-prefix", "")],
            service._validation_scope_keys(document, scope_kind="global-prefix", scope_id=""),
        )


class RelayOperatorPanelRuntimeCommandTests(unittest.TestCase):
    def _make_panel(self) -> RelayOperatorPanel:
        panel = RelayOperatorPanel.__new__(RelayOperatorPanel)
        panel.command_service = CommandService()
        panel.status_service = StatusService(panel.command_service)
        panel.refresh_controller = None
        panel.effective_data = {
            "RunContext": {
                "SelectedRunRoot": "C:\\runs\\current",
            }
        }
        panel.relay_status_data = None
        panel.visibility_status_data = None
        panel.paired_status_data = None
        panel.paired_status_error = ""
        panel.panel_state = None
        panel.output_text = object()
        panel.long_task_widgets = []
        panel._busy = False
        panel.config_path_var = VarStub("cfg.psd1")
        panel.run_root_var = VarStub("")
        panel.pair_id_var = VarStub("pair01")
        panel.target_id_var = VarStub("")
        panel.last_command_var = VarStub("")
        panel.last_result_var = VarStub("")
        panel.operator_status_var = VarStub("")
        panel.operator_hint_var = VarStub("")
        panel.preview_rows = []
        panel.pair_controller = PairController()
        panel.set_text = lambda _widget, value: setattr(panel, "_captured_output", value)
        panel.render_home_dashboard = lambda: None
        panel.rebuild_panel_state = lambda: setattr(panel, "_rebuild_called", True)
        panel.render_target_board = lambda: setattr(panel, "_render_called", True)
        panel.update_pair_button_states = lambda: setattr(panel, "_buttons_called", True)
        panel.load_effective_config = lambda: setattr(panel, "_load_effective_config_called", True)
        panel.run_background_task = lambda **kwargs: kwargs["on_success"](kwargs["worker"]())
        return panel

    def test_run_visibility_check_soft_handles_visibility_blockers(self) -> None:
        panel = self._make_panel()
        relay_payload = {"Runtime": {"ExpectedTargetCount": 8}}
        visibility_payload = {
            "ExpectedTargetCount": 8,
            "InjectableCount": 0,
            "NonInjectableCount": 8,
            "MissingRuntimeCount": 0,
            "Targets": [{"TargetId": "target01", "Injectable": False, "InjectionReason": "no-visible-window"}],
        }
        panel.refresh_controller = SimpleNamespace(
            refresh_runtime=lambda _context: RuntimeRefreshResult(
                relay_status=relay_payload,
                visibility_status=visibility_payload,
            )
        )

        panel.run_visibility_check()

        self.assertEqual(relay_payload, panel.relay_status_data)
        self.assertEqual(visibility_payload, panel.visibility_status_data)
        self.assertIn("Injectable: 0/8", panel._captured_output)
        self.assertIn("target01(no-visible-window)", panel._captured_output)
        self.assertIn('"NonInjectableCount": 8', panel._captured_output)
        self.assertIn("입력 가능 0/8", panel.last_result_var.get())
        self.assertIn("runtime-refresh bundle:", panel.last_command_var.get())
        self.assertIn("show-relay-status.ps1", panel.last_command_var.get())
        self.assertIn("check-target-window-visibility.ps1", panel.last_command_var.get())

    def test_run_paired_summary_routes_to_summary_script(self) -> None:
        panel = self._make_panel()
        captured: dict[str, object] = {}
        panel.run_to_output = lambda script_name, **kwargs: captured.update(
            {
                "script_name": script_name,
                "kwargs": kwargs,
            }
        )

        panel.run_paired_summary()

        self.assertEqual("show-paired-run-summary.ps1", captured.get("script_name"))
        self.assertEqual({}, captured.get("kwargs"))

    def test_run_prepare_all_continues_past_visibility_blockers(self) -> None:
        panel = self._make_panel()
        panel.panel_state = SimpleNamespace(
            stages=[
                SimpleNamespace(key="launch_windows", status_text="이전 세션"),
                SimpleNamespace(key="attach_windows", status_text="완료"),
            ]
        )
        panel._launcher_wrapper_path = lambda: "visible_launcher.py"
        relay_payload = {"Runtime": {"ExpectedTargetCount": 8}}
        visibility_payload = {
            "ExpectedTargetCount": 8,
            "InjectableCount": 0,
            "NonInjectableCount": 8,
            "MissingRuntimeCount": 0,
            "Targets": [{"TargetId": "target01", "Injectable": False, "InjectionReason": "no-visible-window"}],
        }
        panel.refresh_controller = SimpleNamespace(
            refresh_runtime=lambda _context: RuntimeRefreshResult(
                relay_status=relay_payload,
                visibility_status=visibility_payload,
            )
        )

        class CommandServiceStub:
            def __init__(self) -> None:
                self.commands: list[list[str]] = []

            def build_python_command(self, script_path: str) -> list[str]:
                return ["python", script_path]

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
                return [script_name]

            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                self.commands.append(list(command))
                if command[0] == "python":
                    return subprocess.CompletedProcess(command, 0, stdout="visible launcher done", stderr="")
                if command[0] == "attach-targets-from-bindings.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout="attach done", stderr="")
                if command[0] == "tests/Start-PairedExchangeTest.ps1":
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        stdout="prepared pair test root: C:\\runs\\prepared",
                        stderr="",
                    )
                if command[0] == "show-paired-run-summary.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout="prepared overall=success", stderr="")
                raise AssertionError(command)

        panel.command_service = CommandServiceStub()

        panel.run_prepare_all()

        self.assertEqual(
            [
                ["python", "visible_launcher.py"],
                ["attach-targets-from-bindings.ps1"],
                ["tests/Start-PairedExchangeTest.ps1"],
                ["show-paired-run-summary.ps1"],
            ],
            panel.command_service.commands,
        )
        self.assertEqual("C:\\runs\\prepared", panel.run_root_var.get())
        self.assertEqual(relay_payload, panel.relay_status_data)
        self.assertEqual(visibility_payload, panel.visibility_status_data)
        self.assertTrue(getattr(panel, "_load_effective_config_called", False))
        self.assertIn("[입력 점검]", panel._captured_output)
        self.assertIn("Injectable: 0/8", panel._captured_output)
        self.assertIn("[run 준비]", panel._captured_output)
        self.assertIn("[runroot 요약]", panel._captured_output)
        self.assertIn("prepared overall=success", panel._captured_output)

    def test_prepare_run_root_ignores_stale_selected_run_root_when_requesting_new_run(self) -> None:
        panel = self._make_panel()
        panel.effective_data = {
            "RunContext": {
                "SelectedRunRoot": "C:\\runs\\old",
                "SelectedRunRootIsStale": True,
            }
        }
        panel.run_root_var.set("C:\\runs\\old")

        class CommandServiceStub:
            def __init__(self) -> None:
                self.commands: list[list[str]] = []

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

            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                self.commands.append(list(command))
                if command[0] == "show-paired-run-summary.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout="fresh overall=success", stderr="")
                if command[0] != "tests/Start-PairedExchangeTest.ps1":
                    raise AssertionError(command)
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="prepared pair test root: C:\\runs\\fresh",
                    stderr="",
                )

        panel.command_service = CommandServiceStub()

        panel.prepare_run_root()

        self.assertEqual(
            [
                ["tests/Start-PairedExchangeTest.ps1", "-ConfigPath", "cfg.psd1", "-IncludePairId", "pair01"],
                ["show-paired-run-summary.ps1", "-ConfigPath", "cfg.psd1", "-RunRoot", "C:\\runs\\fresh"],
            ],
            panel.command_service.commands,
        )
        self.assertEqual("C:\\runs\\fresh", panel.run_root_var.get())
        self.assertNotIn("-RunRoot", panel.last_command_var.get())
        self.assertIn("오래된 explicit RunRoot 무시 후 새 RunRoot 생성", panel._captured_output)
        self.assertIn("ActionRunRoot: C:\\runs\\fresh", panel._captured_output)
        self.assertIn("RunRoot 입력칸 갱신 완료", panel._captured_output)
        self.assertIn("[runroot 요약]", panel._captured_output)
        self.assertIn("fresh overall=success", panel._captured_output)
        self.assertIn("입력칸 갱신 완료", panel.last_result_var.get())

    def test_run_prepare_all_ignores_stale_selected_run_root_for_run_prepare_step(self) -> None:
        panel = self._make_panel()
        panel.effective_data = {
            "RunContext": {
                "SelectedRunRoot": "C:\\runs\\old",
                "SelectedRunRootIsStale": True,
            }
        }
        panel.run_root_var.set("C:\\runs\\old")
        panel.panel_state = SimpleNamespace(
            stages=[
                SimpleNamespace(key="launch_windows", status_text="완료"),
                SimpleNamespace(key="attach_windows", status_text="완료"),
            ]
        )
        panel.refresh_controller = SimpleNamespace(
            refresh_runtime=lambda _context: RuntimeRefreshResult(
                relay_status={"Runtime": {"ExpectedTargetCount": 8}},
                visibility_status={
                    "ExpectedTargetCount": 8,
                    "InjectableCount": 8,
                    "NonInjectableCount": 0,
                    "MissingRuntimeCount": 0,
                    "Targets": [],
                },
            )
        )

        class CommandServiceStub:
            def __init__(self) -> None:
                self.commands: list[list[str]] = []

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

            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                self.commands.append(list(command))
                if command[0] == "show-paired-run-summary.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout="fresh-prepared overall=success", stderr="")
                if command[0] != "tests/Start-PairedExchangeTest.ps1":
                    raise AssertionError(command)
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="prepared pair test root: C:\\runs\\fresh-prepared",
                    stderr="",
                )

        panel.command_service = CommandServiceStub()

        panel.run_prepare_all()

        self.assertEqual(
            [
                ["tests/Start-PairedExchangeTest.ps1", "-ConfigPath", "cfg.psd1", "-IncludePairId", "pair01"],
                ["show-paired-run-summary.ps1", "-ConfigPath", "cfg.psd1", "-RunRoot", "C:\\runs\\fresh-prepared"],
            ],
            panel.command_service.commands,
        )
        self.assertEqual("C:\\runs\\fresh-prepared", panel.run_root_var.get())
        self.assertNotIn("-RunRoot", panel.last_command_var.get())
        self.assertIn("[run 준비]", panel._captured_output)
        self.assertIn("오래된 explicit RunRoot 무시 후 새 RunRoot 생성", panel._captured_output)
        self.assertIn("ActionRunRoot: C:\\runs\\fresh-prepared", panel._captured_output)
        self.assertIn("RunRoot 입력칸 갱신 완료", panel._captured_output)
        self.assertIn("[runroot 요약]", panel._captured_output)
        self.assertIn("fresh-prepared overall=success", panel._captured_output)
        self.assertIn("입력칸 갱신 완료", panel.last_result_var.get())

    def test_current_run_root_marks_explicit_existing_stale_override_as_stale(self) -> None:
        panel = self._make_panel()
        panel._current_run_root_is_stale_for_actions = RelayOperatorPanel._current_run_root_is_stale_for_actions.__get__(panel, RelayOperatorPanel)
        panel._run_root_is_stale = RelayOperatorPanel._run_root_is_stale.__get__(panel, RelayOperatorPanel)
        panel.effective_data = {
            "RunContext": {
                "SelectedRunRoot": "C:\\runs\\current",
                "SelectedRunRootIsStale": False,
                "StaleRunThresholdSec": 10,
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            old_timestamp = time.time() - 7200
            os.utime(tmp, (old_timestamp, old_timestamp))
            panel.run_root_var.set(tmp)

            self.assertTrue(panel._current_run_root_is_stale_for_actions())

    def test_prepare_run_root_ignores_explicit_existing_stale_override(self) -> None:
        panel = self._make_panel()
        panel.prepare_run_root = RelayOperatorPanel.prepare_run_root.__get__(panel, RelayOperatorPanel)
        panel._requested_run_root_for_prepare = RelayOperatorPanel._requested_run_root_for_prepare.__get__(panel, RelayOperatorPanel)
        panel._prepare_run_root_override_to_ignore = RelayOperatorPanel._prepare_run_root_override_to_ignore.__get__(panel, RelayOperatorPanel)
        panel._run_root_is_stale = RelayOperatorPanel._run_root_is_stale.__get__(panel, RelayOperatorPanel)
        panel.effective_data = {
            "RunContext": {
                "SelectedRunRoot": "C:\\runs\\current",
                "SelectedRunRootIsStale": False,
                "StaleRunThresholdSec": 10,
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            old_timestamp = time.time() - 7200
            os.utime(tmp, (old_timestamp, old_timestamp))
            panel.run_root_var.set(tmp)

            class CommandServiceStub:
                def __init__(self) -> None:
                    self.commands: list[list[str]] = []

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

                def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    self.commands.append(list(command))
                    if command[0] == "show-paired-run-summary.ps1":
                        return subprocess.CompletedProcess(command, 0, stdout="fresh-explicit overall=success", stderr="")
                    if command[0] != "tests/Start-PairedExchangeTest.ps1":
                        raise AssertionError(command)
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        stdout="prepared pair test root: C:\\runs\\fresh-explicit",
                        stderr="",
                    )

            panel.command_service = CommandServiceStub()

            panel.prepare_run_root()

            self.assertEqual(
                [
                    ["tests/Start-PairedExchangeTest.ps1", "-ConfigPath", "cfg.psd1", "-IncludePairId", "pair01"],
                    ["show-paired-run-summary.ps1", "-ConfigPath", "cfg.psd1", "-RunRoot", "C:\\runs\\fresh-explicit"],
                ],
                panel.command_service.commands,
            )
            self.assertEqual("C:\\runs\\fresh-explicit", panel.run_root_var.get())
            self.assertIn("IgnoredRunRoot: " + tmp, panel._captured_output)
            self.assertIn("ActionRunRoot: C:\\runs\\fresh-explicit", panel._captured_output)
            self.assertIn("RunRoot 입력칸 갱신 완료", panel._captured_output)
            self.assertIn("[runroot 요약]", panel._captured_output)
            self.assertIn("fresh-explicit overall=success", panel._captured_output)

    def test_reuse_existing_windows_refreshes_bindings_then_attaches_and_refreshes_runtime(self) -> None:
        panel = self._make_panel()
        relay_payload = {"Runtime": {"ExpectedTargetCount": 8}}
        visibility_payload = {
            "ExpectedTargetCount": 8,
            "InjectableCount": 8,
            "NonInjectableCount": 0,
            "MissingRuntimeCount": 0,
            "Targets": [{"TargetId": "target01", "Injectable": True, "InjectionReason": ""}],
        }
        panel.refresh_controller = SimpleNamespace(
            refresh_runtime=lambda _context: RuntimeRefreshResult(
                relay_status=relay_payload,
                visibility_status=visibility_payload,
            )
        )
        reuse_payload = {
            "Success": True,
            "Summary": "기존 8창 재사용 준비 완료",
            "ExpectedTargetCount": 8,
            "ReusedTargetCount": 8,
            "BindingsPath": "C:\\runtime\\bindings.json",
            "RefreshedAt": "2026-04-18T10:15:00+09:00",
            "Targets": [
                {"TargetId": "target01", "Matched": True, "MatchMethod": "hwnd"},
                {"TargetId": "target02", "Matched": True, "MatchMethod": "title"},
            ],
        }

        class StatusServiceStub:
            def __init__(self) -> None:
                self.calls: list[tuple[str, list[str] | None]] = []

            def run_json_script(self, script_name: str, context: AppContext, **kwargs) -> dict:
                self.calls.append((script_name, kwargs.get("extra")))
                self.context = context
                return reuse_payload

        class CommandServiceStub:
            def __init__(self) -> None:
                self.commands: list[list[str]] = []

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

            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                self.commands.append(list(command))
                if command[0] == "attach-targets-from-bindings.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout="attach done", stderr="")
                raise AssertionError(command)

        panel.status_service = StatusServiceStub()
        panel.command_service = CommandServiceStub()

        panel.reuse_existing_windows()

        self.assertEqual(
            [("refresh-binding-profile-from-existing.ps1", ["-AsJson"])],
            panel.status_service.calls,
        )
        self.assertEqual(
            [["attach-targets-from-bindings.ps1", "-ConfigPath", "cfg.psd1"]],
            panel.command_service.commands,
        )
        self.assertEqual(relay_payload, panel.relay_status_data)
        self.assertEqual(visibility_payload, panel.visibility_status_data)
        self.assertIn("reuse-existing bundle:", panel.last_command_var.get())
        self.assertIn("refresh-binding-profile-from-existing.ps1", panel.last_command_var.get())
        self.assertIn("attach-targets-from-bindings.ps1", panel.last_command_var.get())
        self.assertIn("기존 8창 재사용 결과", panel._captured_output)
        self.assertIn("현재 세션 승격: 완료", panel._captured_output)
        self.assertIn("binding 현재시각 갱신 완료", panel._captured_output)
        self.assertIn("ReusedTargets: 8/8", panel._captured_output)
        self.assertIn("target01(hwnd)", panel._captured_output)
        self.assertIn("[붙이기]", panel._captured_output)
        self.assertIn("attach 재실행 완료", panel._captured_output)
        self.assertIn("attach done", panel._captured_output)
        self.assertIn("[입력 점검]", panel._captured_output)
        self.assertTrue(getattr(panel, "_load_effective_config_called", False))
        self.assertTrue(bool(getattr(panel, "window_launch_anchor_utc", "")))
        self.assertIn("현재 세션 승격", panel.last_result_var.get())

    def test_reuse_active_pairs_refreshes_only_complete_pairs_and_reselects_active_pair(self) -> None:
        panel = self._make_panel()
        panel.pair_id_var = VarStub("pair03")
        panel._sync_preview_selection_with_pair = lambda pair_id, target_id="": setattr(panel, "_synced_pair", (pair_id, target_id)) or True
        relay_payload = {"Runtime": {"ExpectedTargetCount": 2, "ConfiguredTargetCount": 8, "ActivePairIds": ["pair01"], "PartialReuse": True}}
        visibility_payload = {
            "ExpectedTargetCount": 2,
            "ConfiguredTargetCount": 8,
            "InjectableCount": 2,
            "NonInjectableCount": 0,
            "MissingRuntimeCount": 0,
            "Targets": [{"TargetId": "target01", "Injectable": True, "InjectionReason": ""}],
        }
        panel.refresh_controller = SimpleNamespace(
            refresh_runtime=lambda _context: RuntimeRefreshResult(
                relay_status=relay_payload,
                visibility_status=visibility_payload,
            )
        )
        reuse_payload = {
            "Success": True,
            "Summary": "열린 pair 재사용 준비 완료",
            "PartialReuse": True,
            "ExpectedTargetCount": 2,
            "ConfiguredTargetCount": 8,
            "ReusedPairCount": 1,
            "ReusedTargetCount": 2,
            "BindingsPath": "C:\\runtime\\bindings.json",
            "RefreshedAt": "2026-04-20T03:30:00+09:00",
            "ActivePairIds": ["pair01"],
            "InactiveTargetIds": ["target02", "target03", "target04", "target06", "target07", "target08"],
            "Targets": [
                {"TargetId": "target01", "Matched": True, "MatchMethod": "hwnd"},
                {"TargetId": "target05", "Matched": True, "MatchMethod": "hwnd"},
            ],
        }

        class StatusServiceStub:
            def __init__(self) -> None:
                self.calls: list[tuple[str, list[str] | None]] = []

            def run_json_script(self, script_name: str, context: AppContext, **kwargs) -> dict:
                self.calls.append((script_name, kwargs.get("extra")))
                return reuse_payload

        class CommandServiceStub:
            def __init__(self) -> None:
                self.commands: list[list[str]] = []

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

            def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                self.commands.append(list(command))
                if command[0] == "attach-targets-from-bindings.ps1":
                    return subprocess.CompletedProcess(command, 0, stdout="attach done", stderr="")
                raise AssertionError(command)

        panel.status_service = StatusServiceStub()
        panel.command_service = CommandServiceStub()

        panel.reuse_active_pairs()

        self.assertEqual(
            [("refresh-binding-profile-from-existing.ps1", ["-AsJson", "-ReuseMode", "Pairs"])],
            panel.status_service.calls,
        )
        self.assertEqual(
            [["attach-targets-from-bindings.ps1", "-ConfigPath", "cfg.psd1"]],
            panel.command_service.commands,
        )
        self.assertEqual("pair01", panel.pair_id_var.get())
        self.assertEqual(("pair01", "target01"), panel.__dict__.get("_synced_pair"))
        self.assertIn("reuse-active-pairs bundle:", panel.last_command_var.get())
        self.assertIn("열린 pair 재사용 결과", panel._captured_output)
        self.assertIn("ReusedPairs: 1", panel._captured_output)
        self.assertIn("ReusedTargets: 2/2 (cfg 8)", panel._captured_output)
        self.assertIn("ActivePairs: pair01", panel._captured_output)
        self.assertIn("InactiveTargets: target02, target03, target04, target06, target07, target08", panel._captured_output)
        self.assertIn("열린 pair 재사용 성공", panel.last_result_var.get())

    def test_reuse_active_pairs_report_includes_only_counted_reused_targets(self) -> None:
        panel = self._make_panel()

        report = panel._format_reuse_existing_windows_report(
            {
                "Summary": "열린 pair 재사용 준비 완료",
                "PartialReuse": True,
                "ExpectedTargetCount": 2,
                "ConfiguredTargetCount": 8,
                "ReusedPairCount": 1,
                "ReusedTargetCount": 2,
                "ActivePairIds": ["pair01"],
                "ActiveTargetIds": ["target01", "target05"],
                "InactiveTargetIds": ["target03", "target07"],
                "OrphanMatchedTargetIds": ["target03"],
                "Targets": [
                    {"TargetId": "target01", "Matched": True, "CountedAsReused": True, "MatchMethod": "hwnd"},
                    {"TargetId": "target05", "Matched": True, "CountedAsReused": True, "MatchMethod": "title"},
                    {"TargetId": "target03", "Matched": True, "CountedAsReused": False, "MatchMethod": "hwnd"},
                ],
            },
            attach_output="",
            runtime_result=None,
            operation_label="열린 pair 재사용 결과",
        )

        self.assertIn("target01(hwnd)", report)
        self.assertIn("target05(title)", report)
        self.assertNotIn("target03(hwnd)", report)
        self.assertIn("OrphanTargets: target03", report)

    def test_apply_runtime_refresh_result_reselects_first_active_pair_for_partial_scope(self) -> None:
        panel = self._make_panel()
        panel._apply_runtime_refresh_result = RelayOperatorPanel._apply_runtime_refresh_result.__get__(panel, RelayOperatorPanel)
        panel.preview_rows = [{"PairId": "pair01", "RoleName": "top", "TargetId": "target01"}]
        panel.pair_id_var.set("pair03")

        runtime_result = RuntimeRefreshResult(
            relay_status={"Runtime": {"PartialReuse": True, "ActivePairIds": ["pair01"], "ExpectedTargetCount": 2}},
            visibility_status={"ExpectedTargetCount": 2},
        )

        panel._apply_runtime_refresh_result(runtime_result)

        self.assertEqual("pair01", panel.pair_id_var.get())
        self.assertEqual("target01", panel.target_id_var.get())
        self.assertEqual(runtime_result.relay_status, panel.relay_status_data)
        self.assertEqual(runtime_result.visibility_status, panel.visibility_status_data)

    def test_prepare_run_root_blocks_selected_pair_out_of_partial_scope(self) -> None:
        panel = self._make_panel()
        panel.prepare_run_root = RelayOperatorPanel.prepare_run_root.__get__(panel, RelayOperatorPanel)
        panel.relay_status_data = {"Runtime": {"PartialReuse": True, "ActivePairIds": ["pair01"]}}
        panel.pair_id_var.set("pair03")
        warnings: list[tuple[str, str]] = []

        with mock.patch("relay_operator_panel.messagebox.showwarning", side_effect=lambda title, message: warnings.append((title, message))):
            panel.prepare_run_root()

        self.assertEqual(
            [("RunRoot 준비 대기", "run 준비 차단: pair03는 현재 session partial reuse 범위 밖입니다. active=pair01")],
            warnings,
        )
        self.assertEqual("", panel.last_command_var.get())

    def test_run_prepare_all_blocks_selected_pair_out_of_partial_scope(self) -> None:
        panel = self._make_panel()
        panel.run_prepare_all = RelayOperatorPanel.run_prepare_all.__get__(panel, RelayOperatorPanel)
        panel.relay_status_data = {"Runtime": {"PartialReuse": True, "ActivePairIds": ["pair01"]}}
        panel.pair_id_var.set("pair03")
        warnings: list[tuple[str, str]] = []

        with mock.patch("relay_operator_panel.messagebox.showwarning", side_effect=lambda title, message: warnings.append((title, message))):
            panel.run_prepare_all()

        self.assertEqual(
            [("준비 전체 실행 대기", "준비 전체 실행 차단: pair03는 현재 session partial reuse 범위 밖입니다. active=pair01")],
            warnings,
        )
        self.assertEqual("", panel.last_command_var.get())

    def test_reuse_failure_summary_includes_failure_reasons(self) -> None:
        panel = self._make_panel()

        summary = panel._reuse_failure_summary(
            {
                "Summary": "기존 8창 재사용 실패",
                "FailureReasons": [
                    "window-missing:target01:no-visible-window",
                    "shell-missing:target02:50112",
                ],
            }
        )

        self.assertIn("기존 8창 재사용 실패", summary)
        self.assertIn("window-missing:target01:no-visible-window", summary)
        self.assertIn("shell-missing:target02:50112", summary)

    def test_attach_windows_from_bindings_blocks_when_stage_is_not_ready(self) -> None:
        panel = self._make_panel()
        panel.attach_windows_from_bindings = RelayOperatorPanel.attach_windows_from_bindings.__get__(panel, RelayOperatorPanel)
        panel.panel_state = SimpleNamespace(
            stages=[
                SimpleNamespace(
                    key="attach_windows",
                    action_key="attach_windows",
                    enabled=False,
                    detail="붙이기 비활성: 이전 세션 창 기록만 있습니다. 현재 세션 기준 8개 창 다시 준비 필요",
                ),
            ]
        )
        warnings: list[tuple[str, str]] = []

        with mock.patch("relay_operator_panel.messagebox.showwarning", side_effect=lambda title, message: warnings.append((title, message))):
            panel.attach_windows_from_bindings()

        self.assertEqual(
            [("붙이기 대기", "붙이기 비활성: 이전 세션 창 기록만 있습니다. 현재 세션 기준 8개 창 다시 준비 필요")],
            warnings,
        )
        self.assertEqual("", panel.last_command_var.get())

    def test_format_background_exception_includes_returncode_stdout_and_stderr(self) -> None:
        panel = self._make_panel()

        text = panel._format_background_exception(
            PowerShellError(
                "script failed",
                returncode=1,
                stdout="stdout detail",
                stderr="stderr detail",
            )
        )

        self.assertIn("script failed", text)
        self.assertIn("ReturnCode: 1", text)
        self.assertIn("STDOUT:", text)
        self.assertIn("stdout detail", text)
        self.assertIn("STDERR:", text)
        self.assertIn("stderr detail", text)

    def test_rebuild_panel_state_passes_panel_runtime_hints_to_aggregator(self) -> None:
        panel = self._make_panel()
        panel.rebuild_panel_state = RelayOperatorPanel.rebuild_panel_state.__get__(panel, RelayOperatorPanel)
        panel.panel_opened_at_utc = "2026-04-17T12:00:00+00:00"
        panel.window_launch_anchor_utc = "2026-04-17T12:03:00+00:00"
        panel.relay_status_data = {"Runtime": {"ExpectedTargetCount": 8}}
        panel.visibility_status_data = {"ExpectedTargetCount": 8}
        captured: dict[str, str] = {}

        def build_panel_state(*, bundle, selected_pair):
            captured.update(bundle.effective_data.get("PanelRuntimeHints", {}))
            return SimpleNamespace(
                cards=[],
                stages=[],
                next_actions=[],
                issues=[],
                pairs=[],
                overall_detail="",
                overall_label="",
            )

        panel.dashboard_aggregator = SimpleNamespace(build_panel_state=build_panel_state)
        panel.rebuild_panel_state()

        self.assertEqual("2026-04-17T12:00:00+00:00", captured["PanelOpenedAtUtc"])
        self.assertEqual("2026-04-17T12:03:00+00:00", captured["WindowLaunchAnchorUtc"])
        self.assertEqual("C:\\runs\\current", captured["ActionRunRoot"])
        self.assertFalse(captured["ActionRunRootUsesOverride"])
        self.assertFalse(captured["ActionRunRootIsStale"])

    def test_on_run_root_value_changed_debounces_context_refresh_in_ui(self) -> None:
        panel = self._make_panel()
        panel._on_run_root_value_changed = RelayOperatorPanel._on_run_root_value_changed.__get__(panel, RelayOperatorPanel)
        panel._cancel_pending_ui_callbacks = RelayOperatorPanel._cancel_pending_ui_callbacks.__get__(panel, RelayOperatorPanel)
        panel._schedule_run_root_context_refresh = RelayOperatorPanel._schedule_run_root_context_refresh.__get__(panel, RelayOperatorPanel)
        panel._flush_run_root_context_refresh = RelayOperatorPanel._flush_run_root_context_refresh.__get__(panel, RelayOperatorPanel)
        updates: list[str] = []
        scheduled: list[tuple[int, object]] = []
        cancelled: list[str] = []
        panel.tk = object()
        panel.run_root_context_refresh_after_id = "pending-1"
        panel._update_run_root_controls = lambda: updates.append("controls")
        panel._apply_run_root_context_refresh = lambda: updates.append("refresh")
        panel.after_cancel = lambda after_id: cancelled.append(after_id)
        panel.after = lambda delay, callback: scheduled.append((delay, callback)) or "pending-2"

        panel._on_run_root_value_changed()

        self.assertEqual(["controls"], updates)
        self.assertEqual(["pending-1"], cancelled)
        self.assertEqual(1, len(scheduled))
        self.assertEqual(250, scheduled[0][0])
        self.assertEqual("pending-2", panel.run_root_context_refresh_after_id)

        callback = scheduled[0][1]
        callback()

        self.assertEqual(["controls", "refresh"], updates)
        self.assertIsNone(panel.run_root_context_refresh_after_id)

    def test_cancel_pending_ui_callbacks_clears_run_root_refresh_after_id(self) -> None:
        panel = self._make_panel()
        panel._cancel_pending_ui_callbacks = RelayOperatorPanel._cancel_pending_ui_callbacks.__get__(panel, RelayOperatorPanel)
        cancelled: list[str] = []
        panel.tk = object()
        panel.run_root_context_refresh_after_id = "pending-1"
        panel.after_cancel = lambda after_id: cancelled.append(after_id)

        panel._cancel_pending_ui_callbacks()

        self.assertEqual(["pending-1"], cancelled)
        self.assertIsNone(panel.run_root_context_refresh_after_id)

    def test_destroy_cancels_pending_ui_callbacks_before_base_destroy(self) -> None:
        panel = self._make_panel()
        panel.destroy = RelayOperatorPanel.destroy.__get__(panel, RelayOperatorPanel)
        calls: list[str] = []
        panel._cancel_pending_ui_callbacks = lambda: calls.append("cancel")

        with mock.patch("relay_operator_panel.tk.Tk.destroy", side_effect=lambda *args, **kwargs: calls.append("destroy")):
            panel.destroy()

        self.assertEqual(["cancel", "destroy"], calls)

    def test_clear_run_root_input_rebuilds_panel_and_artifacts_immediately(self) -> None:
        panel = self._make_panel()
        panel.clear_run_root_input = RelayOperatorPanel.clear_run_root_input.__get__(panel, RelayOperatorPanel)
        panel._cancel_pending_ui_callbacks = RelayOperatorPanel._cancel_pending_ui_callbacks.__get__(panel, RelayOperatorPanel)
        panel._schedule_run_root_context_refresh = RelayOperatorPanel._schedule_run_root_context_refresh.__get__(panel, RelayOperatorPanel)
        panel._apply_run_root_context_refresh = RelayOperatorPanel._apply_run_root_context_refresh.__get__(panel, RelayOperatorPanel)
        panel._has_ui_attr = RelayOperatorPanel._has_ui_attr.__get__(panel, RelayOperatorPanel)
        panel.run_root_var = VarStub("C:\\runs\\override")
        panel.effective_data = {"RunContext": {"SelectedRunRoot": "C:\\runs\\current"}}
        panel.relay_status_data = {"Runtime": {"ExpectedTargetCount": 8}}
        panel.visibility_status_data = {"ExpectedTargetCount": 8}
        panel.artifact_tree = object()
        refresh_calls: list[str] = []
        panel.rebuild_panel_state = lambda: refresh_calls.append("rebuild")
        panel.refresh_artifacts_tab = lambda: refresh_calls.append("artifacts")
        panel.update_pair_button_states = lambda: refresh_calls.append("buttons")

        panel.clear_run_root_input()

        self.assertEqual("", panel.run_root_var.get())
        self.assertEqual(["rebuild", "artifacts", "buttons"], refresh_calls)
        self.assertIn("RunRoot 입력 비움", panel.operator_status_var.get())

    def test_update_pair_button_states_uses_pair_stage_gating(self) -> None:
        panel = self._make_panel()
        panel.update_pair_button_states = RelayOperatorPanel.update_pair_button_states.__get__(panel, RelayOperatorPanel)
        panel.panel_state = SimpleNamespace(
            stages=[
                SimpleNamespace(key="pair_action", action_key="run_selected_pair", enabled=False, detail="run root 준비 후 실행 가능합니다."),
            ]
        )
        panel.selected_pair_button = ButtonStub()
        panel.home_run_pair_button = ButtonStub()
        panel.home_enable_pair_button = ButtonStub()
        panel.home_disable_pair_button = ButtonStub()
        panel.fixed_pair01_button = ButtonStub()
        panel.home_start_watch_button = ButtonStub()
        panel.artifact_watch_button = ButtonStub()
        panel.ops_stop_watch_button = ButtonStub()
        panel.ops_restart_watch_button = ButtonStub()
        panel.ops_recover_watch_button = ButtonStub()
        panel.board_attach_button = ButtonStub()
        panel._watcher_start_eligibility = lambda: SimpleNamespace(allowed=True, cleanup_allowed=False, message="")
        panel._watcher_stop_eligibility = lambda: SimpleNamespace(allowed=False)
        panel.update_pair_button_states()

        self.assertEqual("disabled", panel.selected_pair_button.state)
        self.assertEqual("disabled", panel.home_run_pair_button.state)
        self.assertEqual("disabled", panel.home_start_watch_button.state)
        self.assertEqual("disabled", panel.artifact_watch_button.state)

    def test_update_pair_button_states_disables_board_attach_when_attach_stage_is_blocked(self) -> None:
        panel = self._make_panel()
        panel.update_pair_button_states = RelayOperatorPanel.update_pair_button_states.__get__(panel, RelayOperatorPanel)
        panel.panel_state = SimpleNamespace(
            stages=[
                SimpleNamespace(
                    key="attach_windows",
                    action_key="attach_windows",
                    enabled=False,
                    detail="붙이기 비활성: 이전 세션 창 기록만 있습니다. 현재 세션 기준 8개 창 다시 준비 필요",
                ),
            ]
        )
        panel.selected_pair_button = ButtonStub()
        panel.home_run_pair_button = ButtonStub()
        panel.home_enable_pair_button = ButtonStub()
        panel.home_disable_pair_button = ButtonStub()
        panel.fixed_pair01_button = ButtonStub()
        panel.home_start_watch_button = ButtonStub()
        panel.artifact_watch_button = ButtonStub()
        panel.ops_stop_watch_button = ButtonStub()
        panel.ops_restart_watch_button = ButtonStub()
        panel.ops_recover_watch_button = ButtonStub()
        panel.board_attach_button = ButtonStub()
        panel._watcher_start_eligibility = lambda: SimpleNamespace(allowed=True, cleanup_allowed=False, message="")
        panel._watcher_stop_eligibility = lambda: SimpleNamespace(allowed=False)

        panel.update_pair_button_states()

        self.assertEqual("disabled", panel.board_attach_button.state)

    def test_start_watcher_detached_blocks_when_pair_stage_is_not_ready(self) -> None:
        panel = self._make_panel()
        panel.start_watcher_detached = RelayOperatorPanel.start_watcher_detached.__get__(panel, RelayOperatorPanel)
        panel.panel_state = SimpleNamespace(
            stages=[
                SimpleNamespace(key="pair_action", action_key="run_selected_pair", enabled=False, detail="대기: 현재 세션 RunRoot 준비 후 Pair 실행을 준비합니다."),
            ]
        )
        panel._watcher_start_eligibility = lambda: SimpleNamespace(allowed=True, cleanup_allowed=False, message="", recommended_action="")
        warnings: list[tuple[str, str]] = []

        with mock.patch("relay_operator_panel.messagebox.showwarning", side_effect=lambda title, message: warnings.append((title, message))):
            panel.start_watcher_detached()

        self.assertEqual(
            [("watch 시작 대기", "대기: 현재 세션 RunRoot 준비 후 Pair 실행을 준비합니다.")],
            warnings,
        )

    def test_watch_start_allowed_appends_stale_run_root_guidance(self) -> None:
        panel = self._make_panel()
        panel._watch_start_allowed = RelayOperatorPanel._watch_start_allowed.__get__(panel, RelayOperatorPanel)
        panel._selected_pair_execution_allowed = lambda: (False, "대기: 현재 세션 RunRoot 준비 후 Pair 실행을 준비합니다.")
        panel._current_run_root_is_stale_for_actions = lambda: True

        allowed, detail = panel._watch_start_allowed()

        self.assertFalse(allowed)
        self.assertIn("현재 action RunRoot가 stale입니다.", detail)
        self.assertIn("explicit RunRoot 입력을 비우세요.", detail)

    def test_board_status_text_includes_attach_wait_reason(self) -> None:
        panel = self._make_panel()
        panel.panel_state = SimpleNamespace(
            stages=[
                SimpleNamespace(
                    key="attach_windows",
                    action_key="attach_windows",
                    enabled=False,
                    detail="붙이기 비활성: 이전 세션 창 기록만 있습니다. 현재 세션 기준 8개 창 다시 준비 필요",
                ),
            ]
        )

        text = panel._board_status_text(
            items=[
                {"RuntimePresent": "예", "Injectable": "예", "PairId": "pair01"},
                {"RuntimePresent": "아니오", "Injectable": "아니오", "PairId": "pair02"},
            ],
            selected_target="target01",
            selected_pair="pair01",
        )

        self.assertIn("attached 1/2", text)
        self.assertIn("injectable 1/2", text)
        self.assertIn("현재 선택 target01", text)
        self.assertIn("붙이기 비활성: 이전 세션 창 기록만 있습니다.", text)


class RelayOperatorPanelMessageSlotTests(unittest.TestCase):
    def _make_panel(self) -> RelayOperatorPanel:
        panel = RelayOperatorPanel.__new__(RelayOperatorPanel)
        panel.message_config_service = MessageConfigService(CommandService())
        panel.message_config_doc = {
            "PairTest": {
                "MessageTemplates": {
                    "Initial": {},
                    "Handoff": {},
                },
                "PairOverrides": {"pair01": {"InitialExtraBlocks": ["pair block"]}},
                "RoleOverrides": {"top": {"InitialExtraBlocks": ["role block"]}},
                "TargetOverrides": {"target01": {"InitialExtraBlocks": ["target block"]}},
            },
            "Targets": [{"Id": "target01"}],
        }
        panel.preview_rows = [
            {"PairId": "pair01", "RoleName": "top", "TargetId": "target01"},
        ]
        panel.pair_id_var = VarStub("pair01")
        panel.target_id_var = VarStub("target01")
        panel.message_template_var = VarStub("Initial")
        panel.message_scope_label_var = VarStub("글로벌 Prefix")
        panel.message_scope_id_var = VarStub("")
        panel.message_editor_status_var = VarStub("")
        panel.message_block_filter_var = VarStub("")
        panel.message_block_changed_only_var = VarStub(False)
        panel.message_target_suffix_var = VarStub("target01")
        panel.message_selected_slot_key = "global-prefix"
        panel.message_last_rendered_slot_key = ""
        panel.message_last_rendered_slot_order = ()
        panel.message_last_rendered_template_name = ""
        panel.message_last_rendered_scope_kind = ""
        panel.message_last_rendered_scope_id = ""
        panel.message_config_original = panel.message_config_service.clone_document(panel.message_config_doc)
        panel.message_preview_payload = None
        panel.message_document_version = 0
        panel.message_preview_doc_version = -1
        panel.message_preview_cached_context_key = ""
        panel._editor_preview_text = lambda _key: "(preview)"
        panel._editor_final_delivery_text = lambda: "(final-delivery)"
        panel._editor_path_summary_text = lambda: "(path-summary)"
        panel._editor_context_text = lambda: "(context)"
        panel._editor_plan_text = lambda: "(plan)"
        panel._editor_one_time_text = lambda: "(one-time)"
        panel._message_editor_has_unsaved_changes = lambda: False
        panel._message_preview_is_fresh = lambda: True
        return panel

    def test_message_slot_editor_context_resolves_target_slot_to_current_target(self) -> None:
        panel = self._make_panel()

        editable, scope_kind, scope_id, help_text = panel._message_slot_editor_context("target-extra")

        self.assertTrue(editable)
        self.assertEqual("target-extra", scope_kind)
        self.assertEqual("target01", scope_id)
        self.assertEqual("", help_text)

    def test_message_slot_editor_context_prefers_explicit_target_scope_id(self) -> None:
        panel = self._make_panel()
        panel.message_config_doc["PairTest"]["TargetOverrides"]["target05"] = {"InitialExtraBlocks": ["bottom block"]}
        panel.message_config_doc["Targets"].append({"Id": "target05"})
        panel.message_scope_id_var.set("target05")

        editable, scope_kind, scope_id, help_text = panel._message_slot_editor_context("target-extra")

        self.assertTrue(editable)
        self.assertEqual("target-extra", scope_kind)
        self.assertEqual("target05", scope_id)
        self.assertEqual("", help_text)

    def test_message_slot_editor_context_marks_body_as_preview_only(self) -> None:
        panel = self._make_panel()

        editable, scope_kind, scope_id, help_text = panel._message_slot_editor_context("body")

        self.assertFalse(editable)
        self.assertEqual("body", scope_kind)
        self.assertEqual("", scope_id)
        self.assertIn("자동 생성 본문", help_text)

    def test_active_message_block_scope_returns_none_for_preview_only_slot(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "body"

        self.assertIsNone(panel._active_message_block_scope())

    def test_active_message_block_scope_uses_slot_selected_target_scope(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "target-extra"

        self.assertEqual(("Initial", "target-extra", "target01"), panel._active_message_block_scope())

    def test_prepare_message_slot_selection_clears_only_search_filter_on_slot_change(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "global-prefix"
        panel.message_block_filter_var.set("role")
        panel.message_block_changed_only_var.set(True)

        panel._prepare_message_slot_selection("target-extra", reason="slot_change")

        self.assertEqual("target-extra", panel.message_selected_slot_key)
        self.assertEqual("", panel.message_block_filter_var.get())
        self.assertTrue(panel.message_block_changed_only_var.get())

    def test_apply_message_filter_reset_policy_for_board_change_keeps_changed_only(self) -> None:
        panel = self._make_panel()
        panel.message_block_filter_var.set("target")
        panel.message_block_changed_only_var.set(True)

        panel._apply_message_filter_reset_policy("board_target_change")

        self.assertEqual("", panel.message_block_filter_var.get())
        self.assertTrue(panel.message_block_changed_only_var.get())

    def test_message_block_insert_index_prefers_selected_block_plus_one(self) -> None:
        panel = self._make_panel()

        self.assertEqual(3, panel._message_block_insert_index(3, None))
        self.assertEqual(2, panel._message_block_insert_index(3, 1))
        self.assertEqual(3, panel._message_block_insert_index(3, 9))

    def test_build_message_editor_view_state_splits_calculation_from_widget_apply(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "target-extra"

        state = panel._build_message_editor_view_state(panel.message_config_doc, selected_block_index=None)

        self.assertEqual("target-extra", state["selected_slot_key"])
        self.assertEqual("target-extra", state["scope_kind"])
        self.assertEqual("target01", state["scope_id"])
        self.assertEqual(["  1. target block"], state["block_items"])
        self.assertEqual(0, state["selected_block_actual_index"])
        self.assertTrue(state["block_text_editable"])

    def test_build_message_editor_view_state_marks_body_as_preview_only(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "body"

        state = panel._build_message_editor_view_state(panel.message_config_doc, selected_block_index=None)

        self.assertEqual("body", state["selected_slot_key"])
        self.assertEqual("body", state["scope_kind"])
        self.assertEqual([], state["block_items"])
        self.assertFalse(state["block_text_editable"])
        self.assertIn("preview-only", state["editor_status_text"])

    def test_build_message_editor_view_state_keeps_editor_writable_for_empty_editable_slot(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "global-prefix"

        state = panel._build_message_editor_view_state(panel.message_config_doc, selected_block_index=None)

        self.assertEqual("global-prefix", state["selected_slot_key"])
        self.assertEqual([], state["block_items"])
        self.assertTrue(state["block_text_editable"])
        self.assertTrue(state["action_states"]["add"])
        self.assertFalse(state["action_states"]["update"])
        self.assertTrue(state["show_add_cta"])
        self.assertFalse(state["show_clear_filter_cta"])
        self.assertIn("비어 있습니다", state["block_hint_text"])

    def test_message_block_action_states_disable_all_edit_actions_for_preview_only(self) -> None:
        panel = self._make_panel()

        states = panel._message_block_action_states(slot_editable=False, has_blocks=False, has_selection=False)

        self.assertFalse(states["filter_widgets"])
        self.assertFalse(states["clear_filter"])
        self.assertFalse(states["listbox"])
        self.assertFalse(states["editor"])
        self.assertFalse(states["add"])
        self.assertFalse(states["update"])
        self.assertFalse(states["clear"])
        self.assertFalse(states["duplicate"])
        self.assertFalse(states["revert"])
        self.assertFalse(states["delete"])
        self.assertFalse(states["move_up"])
        self.assertFalse(states["move_down"])

    def test_message_block_action_states_keep_add_enabled_for_empty_editable_slot(self) -> None:
        panel = self._make_panel()

        states = panel._message_block_action_states(slot_editable=True, has_blocks=False, has_selection=False)

        self.assertTrue(states["filter_widgets"])
        self.assertFalse(states["clear_filter"])
        self.assertTrue(states["listbox"])
        self.assertTrue(states["editor"])
        self.assertTrue(states["add"])
        self.assertFalse(states["update"])
        self.assertFalse(states["clear"])
        self.assertFalse(states["duplicate"])
        self.assertFalse(states["revert"])
        self.assertFalse(states["delete"])
        self.assertFalse(states["move_up"])
        self.assertFalse(states["move_down"])

    def test_message_block_action_states_keep_clear_filter_for_preview_only_when_filter_active(self) -> None:
        panel = self._make_panel()
        panel.message_block_filter_var.set("role")

        states = panel._message_block_action_states(slot_editable=False, has_blocks=False, has_selection=False)

        self.assertFalse(states["filter_widgets"])
        self.assertTrue(states["clear_filter"])

    def test_build_message_editor_view_state_surfaces_filter_badges_and_clear_cta(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "target-extra"
        panel.message_block_filter_var.set("missing")

        state = panel._build_message_editor_view_state(panel.message_config_doc, selected_block_index=None)

        self.assertEqual([], state["block_items"])
        self.assertFalse(state["show_add_cta"])
        self.assertTrue(state["show_clear_filter_cta"])
        self.assertIn("search='missing'", state["filter_badges_text"])
        self.assertIn("필터 때문에 현재 표시되는 블록이 없습니다", state["block_hint_text"])

    def test_build_message_editor_view_state_surfaces_preview_only_lock_badge(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "body"
        panel.message_block_changed_only_var.set(True)

        state = panel._build_message_editor_view_state(panel.message_config_doc, selected_block_index=None)

        self.assertIn("preview-only:Body", state["filter_badges_text"])
        self.assertIn("changed only", state["filter_badges_text"])
        self.assertTrue(state["show_clear_filter_cta"])
        self.assertIn("잠금됨:", state["block_hint_text"])

    def test_build_message_editor_view_state_can_skip_heavy_side_panels(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "target-extra"

        state = panel._build_message_editor_view_state(
            panel.message_config_doc,
            selected_block_index=None,
            include_side_panels=False,
        )

        self.assertFalse(state["include_side_panels"])
        self.assertIsNone(state["summary_text"])
        self.assertIsNone(state["diff_text"])
        self.assertIsNone(state["initial_preview_text"])
        self.assertIsNone(state["handoff_preview_text"])
        self.assertIsNone(state["final_delivery_text"])
        self.assertIsNone(state["path_summary_text"])
        self.assertIsNone(state["context_text"])
        self.assertIsNone(state["plan_text"])
        self.assertIsNone(state["one_time_preview_text"])
        self.assertIn("검증 결과", state["validation_text"])

    def test_build_message_editor_view_state_includes_final_delivery_and_path_summary(self) -> None:
        panel = self._make_panel()
        panel.message_selected_slot_key = "target-extra"

        state = panel._build_message_editor_view_state(panel.message_config_doc, selected_block_index=None)

        self.assertEqual("(final-delivery)", state["final_delivery_text"])
        self.assertEqual("(path-summary)", state["path_summary_text"])

    def test_editor_final_delivery_text_combines_initial_and_handoff_previews(self) -> None:
        panel = self._make_panel()
        panel._editor_final_delivery_text = RelayOperatorPanel._editor_final_delivery_text.__get__(panel, RelayOperatorPanel)
        row = {
            "Initial": {"Preview": "initial preview body"},
            "Handoff": {"Preview": "handoff preview body"},
        }
        panel.message_editor_dirty = False
        panel._editor_preview_row_and_source = lambda: (row, "saved", {"GeneratedAt": "2026-04-20T12:00:00+09:00", "Warnings": []})

        text = panel._editor_final_delivery_text()

        self.assertIn("[Initial 최종 전달문]", text)
        self.assertIn("initial preview body", text)
        self.assertIn("[Handoff 최종 전달문]", text)
        self.assertIn("handoff preview body", text)

    def test_editor_path_summary_text_includes_candidate_and_output_paths(self) -> None:
        panel = self._make_panel()
        panel._editor_path_summary_text = RelayOperatorPanel._editor_path_summary_text.__get__(panel, RelayOperatorPanel)
        row = {
            "PairId": "pair01",
            "RoleName": "bottom",
            "TargetId": "target05",
            "PartnerTargetId": "target01",
            "OwnTargetFolder": "C:\\runs\\pair01\\target05",
            "PartnerTargetFolder": "C:\\runs\\pair01\\target01",
            "RequestPath": "C:\\runs\\pair01\\target05\\request.json",
            "InitialInstructionPath": "C:\\runs\\pair01\\target05\\instructions.txt",
            "InitialMessagePath": "C:\\runs\\pair01\\messages\\target05.txt",
            "HandoffMessagePattern": "C:\\runs\\pair01\\messages\\handoff_target01_to_target05_<yyyyMMdd_HHmmss_fff>.txt",
            "ReviewInputFiles": {
                "PartnerSummaryPath": "C:\\runs\\pair01\\target01\\source-outbox\\summary.txt",
                "PartnerReviewZipPath": "C:\\runs\\pair01\\target01\\source-outbox\\review.zip",
                "AvailablePaths": [
                    "C:\\runs\\pair01\\target01\\source-outbox\\summary.txt",
                ],
                "ExternalReviewInputPath": "C:\\runs\\pair01\\target05\\review-input\\manual.txt",
            },
            "OutputFiles": {
                "SummaryPath": "C:\\runs\\pair01\\target05\\source-outbox\\summary.txt",
                "ReviewZipPath": "C:\\runs\\pair01\\target05\\source-outbox\\review.zip",
                "PublishReadyPath": "C:\\runs\\pair01\\target05\\source-outbox\\publish.ready.json",
            },
        }
        panel.message_editor_dirty = False
        panel._editor_preview_row_and_source = lambda: (row, "saved", {"GeneratedAt": "", "Warnings": []})

        text = panel._editor_path_summary_text()

        self.assertIn("내 작업 폴더: C:\\runs\\pair01\\target05", text)
        self.assertIn("상대 작업 폴더: C:\\runs\\pair01\\target01", text)
        self.assertIn("summary.txt: C:\\runs\\pair01\\target01\\source-outbox\\summary.txt", text)
        self.assertIn("review.zip: C:\\runs\\pair01\\target01\\source-outbox\\review.zip", text)
        self.assertIn("- C:\\runs\\pair01\\target01\\source-outbox\\summary.txt", text)
        self.assertIn("external review input: C:\\runs\\pair01\\target05\\review-input\\manual.txt", text)
        self.assertIn("publish.ready.json: C:\\runs\\pair01\\target05\\source-outbox\\publish.ready.json", text)

    def test_copy_current_final_delivery_preview_routes_to_clipboard(self) -> None:
        panel = self._make_panel()
        copied: list[str] = []
        panel._editor_final_delivery_text = lambda: "final delivery"
        panel._copy_to_clipboard = copied.append

        panel.copy_current_final_delivery_preview()

        self.assertEqual(["final delivery"], copied)
        self.assertIn("최종 전달문", panel.message_editor_status_var.get())

    def test_editor_context_text_includes_review_input_and_output_paths(self) -> None:
        panel = self._make_panel()
        panel._editor_context_text = RelayOperatorPanel._editor_context_text.__get__(panel, RelayOperatorPanel)
        row = {
            "PairId": "pair01",
            "RoleName": "top",
            "TargetId": "target01",
            "PartnerTargetId": "target05",
            "WindowTitle": "BotTestLive-Window-01",
            "InboxFolder": "C:\\inbox\\target01",
            "OwnTargetFolder": "C:\\runs\\pair01\\target01",
            "PartnerTargetFolder": "C:\\runs\\pair01\\target05",
            "ReviewFolderPath": "C:\\runs\\pair01\\target01\\reviewfile",
            "SummaryPath": "C:\\runs\\pair01\\target01\\summary.txt",
            "ReviewInputFiles": {
                "PartnerSummaryPath": "C:\\runs\\pair01\\target05\\source-outbox\\summary.txt",
                "PartnerReviewZipPath": "C:\\runs\\pair01\\target05\\source-outbox\\review.zip",
                "AvailablePaths": [
                    "C:\\runs\\pair01\\target05\\source-outbox\\summary.txt",
                    "C:\\runs\\pair01\\target05\\source-outbox\\review.zip",
                ],
            },
            "OutputFiles": {
                "SummaryPath": "C:\\runs\\pair01\\target01\\source-outbox\\summary.txt",
                "ReviewZipPath": "C:\\runs\\pair01\\target01\\source-outbox\\review.zip",
                "PublishReadyPath": "C:\\runs\\pair01\\target01\\source-outbox\\publish.ready.json",
            },
        }
        panel.message_editor_dirty = False
        panel._editor_preview_row_and_source = lambda: (row, "saved", {"GeneratedAt": "", "Warnings": []})

        text = panel._editor_context_text()

        self.assertIn("내 작업 폴더: C:\\runs\\pair01\\target01", text)
        self.assertIn("상대 작업 폴더: C:\\runs\\pair01\\target05", text)
        self.assertIn("- C:\\runs\\pair01\\target05\\source-outbox\\summary.txt", text)
        self.assertIn("- C:\\runs\\pair01\\target05\\source-outbox\\review.zip", text)
        self.assertIn("review.zip: C:\\runs\\pair01\\target01\\source-outbox\\review.zip", text)
        self.assertIn("publish.ready.json: C:\\runs\\pair01\\target01\\source-outbox\\publish.ready.json", text)

    def test_editor_context_text_marks_missing_review_inputs_when_available_paths_empty(self) -> None:
        panel = self._make_panel()
        panel._editor_context_text = RelayOperatorPanel._editor_context_text.__get__(panel, RelayOperatorPanel)
        row = {
            "PairId": "pair01",
            "RoleName": "top",
            "TargetId": "target01",
            "PartnerTargetId": "target05",
            "ReviewInputFiles": {
                "AvailablePaths": [],
                "ExternalReviewInputPath": "C:\\runs\\pair01\\target01\\review-input\\manual-note.txt",
            },
            "OutputFiles": {
                "SummaryPath": "C:\\runs\\pair01\\target01\\source-outbox\\summary.txt",
                "ReviewZipPath": "C:\\runs\\pair01\\target01\\source-outbox\\review.zip",
                "PublishReadyPath": "C:\\runs\\pair01\\target01\\source-outbox\\publish.ready.json",
            },
        }
        panel.message_editor_dirty = False
        panel._editor_preview_row_and_source = lambda: (row, "saved", {"GeneratedAt": "", "Warnings": []})

        text = panel._editor_context_text()

        self.assertIn("(현재 존재하는 검토 입력 파일 없음)", text)
        self.assertIn("external review input: C:\\runs\\pair01\\target01\\review-input\\manual-note.txt", text)

    def test_on_message_slot_selected_uses_lightweight_render(self) -> None:
        panel = self._make_panel()
        calls: list[bool] = []
        class SlotListStub:
            def curselection(self) -> tuple[int, ...]:
                return (3,)

        panel.message_slot_order_list = SlotListStub()
        panel.render_message_editor = lambda *, include_side_panels=True: calls.append(include_side_panels)

        panel.on_message_slot_selected()

        self.assertEqual([False], calls)
        self.assertEqual("target-extra", panel.message_selected_slot_key)
        self.assertEqual("Target Extra", panel.message_scope_label_var.get())
        self.assertEqual("target01", panel.message_scope_id_var.get())

    def test_sync_preview_selection_with_pair_prefers_explicit_target(self) -> None:
        panel = self._make_panel()
        panel.preview_rows = [
            {"PairId": "pair01", "RoleName": "top", "TargetId": "target01"},
            {"PairId": "pair01", "RoleName": "bottom", "TargetId": "target05"},
        ]

        class RowTreeStub:
            def __init__(self) -> None:
                self.selected: str | None = None

            def selection_set(self, iid: str) -> None:
                self.selected = iid

            def see(self, iid: str) -> None:
                self.selected = iid

        panel.row_tree = RowTreeStub()
        selected_rows: list[str] = []
        panel.on_row_selected = lambda _event=None: selected_rows.append(panel.preview_rows[int(panel.row_tree.selected)]["TargetId"])

        result = panel._sync_preview_selection_with_pair("pair01", target_id="target05")

        self.assertTrue(result)
        self.assertEqual("1", panel.row_tree.selected)
        self.assertEqual(["target05"], selected_rows)

    def test_on_pair_or_target_changed_syncs_target_extra_scope_id_to_selected_target(self) -> None:
        panel = self._make_panel()
        panel.message_config_doc["PairTest"]["TargetOverrides"]["target05"] = {"InitialExtraBlocks": ["bottom block"]}
        panel.message_config_doc["Targets"].append({"Id": "target05"})
        panel.preview_rows = [
            {"PairId": "pair01", "RoleName": "top", "TargetId": "target01"},
            {"PairId": "pair01", "RoleName": "bottom", "TargetId": "target05"},
        ]
        panel.target_id_var.set("target05")
        panel.message_selected_slot_key = "target-extra"
        panel.message_scope_label_var.set("Target Extra")
        panel.message_scope_id_var.set("target01")

        class RowTreeStub:
            def selection_set(self, _iid: str) -> None:
                return None

            def see(self, _iid: str) -> None:
                return None

        panel.row_tree = RowTreeStub()
        panel.on_row_selected = lambda _event=None: None
        panel.render_target_board = lambda: None
        panel.render_message_editor = lambda *, include_side_panels=True: None
        panel.update_pair_button_states = lambda: None
        panel.rebuild_panel_state = lambda: None
        panel._sync_home_pair_selection = lambda _pair_id: None

        panel.on_pair_or_target_changed()

        self.assertEqual("target05", panel.message_scope_id_var.get())

    def test_load_effective_config_keeps_explicit_target_selection_on_refresh(self) -> None:
        panel = RelayOperatorPanel.__new__(RelayOperatorPanel)
        preview_rows = [
            {"PairId": "pair01", "RoleName": "top", "TargetId": "target01"},
            {"PairId": "pair01", "RoleName": "bottom", "TargetId": "target05"},
        ]

        class RefreshControllerStub:
            def refresh_full(self, _context):
                return DashboardRawBundle(
                    effective_data={
                        "RunContext": {"SelectedRunRoot": "C:\\runs\\current", "SelectedRunRootSource": "explicit"},
                        "PreviewRows": preview_rows,
                    },
                    relay_status={},
                    visibility_status={},
                    paired_status={},
                    paired_status_error="",
                )

        class RowTreeStub:
            def __init__(self) -> None:
                self.selected: str | None = None

            def selection_set(self, iid: str) -> None:
                self.selected = iid

            def see(self, iid: str) -> None:
                self.selected = iid

            def get_children(self):
                return ("0", "1")

        panel.refresh_controller = RefreshControllerStub()
        panel._current_context = lambda: AppContext(config_path="cfg.psd1", run_root="C:\\runs\\current")
        panel.run_root_var = VarStub("")
        panel.pair_id_var = VarStub("pair01")
        panel.target_id_var = VarStub("target05")
        panel.message_config_doc = {}
        panel.effective_data = None
        panel.relay_status_data = None
        panel.visibility_status_data = None
        panel.paired_status_data = None
        panel.paired_status_error = ""
        panel.preview_rows = []
        panel.row_tree = RowTreeStub()
        panel.render_summary = lambda _payload: None
        panel.render_rows = lambda rows: None
        panel.render_message_editor = lambda: None
        panel.render_target_board = lambda: None
        panel.rebuild_panel_state = lambda: None
        panel.refresh_artifacts_tab = lambda: None
        panel.refresh_snapshot_list = lambda: None
        panel.update_pair_button_states = lambda: None
        panel.clear_details = lambda: None
        panel.set_operator_status = lambda *args, **kwargs: None
        selected_rows: list[str] = []
        panel.on_row_selected = lambda _event=None: selected_rows.append(preview_rows[int(panel.row_tree.selected)]["TargetId"])

        panel.load_effective_config()

        self.assertEqual("C:\\runs\\current", panel.run_root_var.get())
        self.assertEqual("1", panel.row_tree.selected)
        self.assertEqual(["target05"], selected_rows)


class DashboardAggregatorTests(unittest.TestCase):
    def test_binding_window_count_prefers_scoped_target_count_from_status(self) -> None:
        aggregator = DashboardAggregator()

        self.assertEqual(
            2,
            aggregator._binding_window_count(
                {
                    "Runtime": {
                        "BindingScopedTargetCount": 2,
                        "BindingScopedWindowCount": 8,
                    }
                }
            ),
        )

    def test_build_panel_state_prioritizes_ready_to_forward_before_watcher_restart(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {"BindingProfilePath": str(binding_profile)},
                        "Runtime": {"Exists": True, "UniqueTargetCount": 8, "AttachedCount": 8, "LaunchedCount": 8},
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "stopped"},
                        "Counts": {"ReadyToForwardCount": 1},
                        "Targets": [{"PairId": "pair01", "TargetId": "target01", "LatestState": "ready-to-forward", "ZipCount": 1, "FailureCount": 0}],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        self.assertGreaterEqual(len(state.issues), 2)
        self.assertEqual("다음 전달 가능 target 존재", state.issues[0].title)
        self.assertEqual("focus_ready_to_forward_artifact", state.issues[0].action_key)
        self.assertEqual("watcher 중지", state.issues[1].title)

    def test_build_panel_state_marks_expected_limit_stop_for_restart(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {"BindingProfilePath": str(binding_profile)},
                        "Runtime": {"Exists": True, "UniqueTargetCount": 8, "AttachedCount": 8, "LaunchedCount": 8},
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "stopped", "StopCategory": "expected-limit"},
                        "Counts": {"HandoffReadyCount": 0, "ReadyToForwardCount": 0},
                        "Targets": [{"PairId": "pair01", "TargetId": "target01", "LatestState": "forwarded", "ZipCount": 1, "FailureCount": 0}],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        self.assertTrue(any(issue.title == "watcher 정상 제한 종료" for issue in state.issues))

    def test_build_panel_state_surfaces_ignored_launcher_session_mismatch(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {"BindingProfilePath": str(binding_profile)},
                        "Runtime": {"Exists": True, "UniqueTargetCount": 8, "AttachedCount": 8, "LaunchedCount": 8},
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "Counts": {"Ignored": 2},
                        "IgnoredReasonCounts": [
                            {"Code": "launcher-session-mismatch", "Label": "런처 세션 불일치", "Count": 2},
                        ],
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "running"},
                        "Counts": {"HandoffReadyCount": 0, "ReadyToForwardCount": 0},
                        "Targets": [{"PairId": "pair01", "TargetId": "target01", "LatestState": "forwarded", "ZipCount": 1, "FailureCount": 0}],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        router_card = next(card for card in state.cards if card.key == "router")
        self.assertIn("ignored=2", router_card.detail)
        self.assertIn("런처 세션 불일치 2", router_card.detail)
        self.assertTrue(any(issue.title == "다른 세션 ready 무시됨" for issue in state.issues))

    def test_build_panel_state_surfaces_ignored_pair_metadata_contract_violation(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {"BindingProfilePath": str(binding_profile)},
                        "Runtime": {"Exists": True, "UniqueTargetCount": 8, "AttachedCount": 8, "LaunchedCount": 8},
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "Counts": {"Ignored": 1},
                        "IgnoredReasonCounts": [
                            {"Code": "paired-metadata-missing-fields", "Label": "pair 메타 필수값 누락", "Count": 1},
                        ],
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "running"},
                        "Counts": {"HandoffReadyCount": 0, "ReadyToForwardCount": 0},
                        "Targets": [{"PairId": "pair01", "TargetId": "target01", "LatestState": "forwarded", "ZipCount": 1, "FailureCount": 0}],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        router_card = next(card for card in state.cards if card.key == "router")
        self.assertIn("ignored=1", router_card.detail)
        self.assertIn("pair 메타 필수값 누락 1", router_card.detail)
        self.assertTrue(any(issue.title == "relay 메타 오류로 ready 무시됨" for issue in state.issues))

    def test_build_panel_state_marks_launch_stage_as_previous_session_when_binding_predates_panel_open(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )
            binding_last_write = datetime(2026, 4, 17, 12, 0, tzinfo=timezone.utc).isoformat()
            panel_opened_at = (datetime(2026, 4, 17, 12, 0, tzinfo=timezone.utc) + timedelta(minutes=5)).isoformat()

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PanelRuntimeHints": {
                            "PanelOpenedAtUtc": panel_opened_at,
                            "WindowLaunchAnchorUtc": panel_opened_at,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {
                            "BindingProfilePath": str(binding_profile),
                            "BindingProfileExists": True,
                            "BindingProfileLastWriteAt": binding_last_write,
                        },
                        "Runtime": {"Exists": True, "UniqueTargetCount": 8, "AttachedCount": 8, "LaunchedCount": 8},
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "stopped"},
                        "Counts": {},
                        "Targets": [],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        self.assertFalse(state.workflow.windows_ready)
        self.assertEqual("현재 세션 창 준비 필요", state.overall_label)
        self.assertEqual("이전 세션", state.stages[0].status_text)
        self.assertIn("이전 세션 binding 8/8", state.stages[0].detail)
        self.assertEqual("이전 세션 창 기록", state.issues[0].title)
        self.assertFalse(state.stages[1].enabled)
        self.assertEqual("대기", state.stages[1].status_text)
        self.assertIn("붙이기 비활성: 이전 세션 창 기록만 있습니다.", state.stages[1].detail)
        self.assertIn(binding_last_write, state.stages[1].detail)
        self.assertIn(panel_opened_at, state.stages[1].detail)
        self.assertFalse(state.stages[2].enabled)
        self.assertEqual("대기", state.stages[2].status_text)
        self.assertFalse(state.stages[3].enabled)
        self.assertEqual("대기", state.stages[3].status_text)
        self.assertFalse(state.stages[4].enabled)
        self.assertEqual("대기", state.stages[4].status_text)

    def test_build_panel_state_accepts_binding_prepared_in_current_session(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )
            panel_opened_at = datetime(2026, 4, 17, 12, 0, tzinfo=timezone.utc)
            binding_last_write = (panel_opened_at + timedelta(minutes=1)).isoformat()

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PanelRuntimeHints": {
                            "PanelOpenedAtUtc": panel_opened_at.isoformat(),
                            "WindowLaunchAnchorUtc": panel_opened_at.isoformat(),
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {
                            "BindingProfilePath": str(binding_profile),
                            "BindingProfileExists": True,
                            "BindingProfileLastWriteAt": binding_last_write,
                        },
                        "Runtime": {"Exists": True, "UniqueTargetCount": 8, "AttachedCount": 8, "LaunchedCount": 8},
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "running"},
                        "Counts": {},
                        "Targets": [],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        self.assertTrue(state.workflow.windows_ready)
        self.assertEqual("완료", state.stages[0].status_text)
        self.assertIn("현재 세션 binding 8/8", state.stages[0].detail)
        self.assertEqual("세션 창 준비", state.cards[0].title)
        self.assertIn("현재 세션", state.cards[0].detail)

    def test_build_panel_state_uses_partial_pair_scope_counts_and_blocks_out_of_scope_pair(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps(
                    {
                        "partial_reuse": True,
                        "active_target_ids": ["target01", "target05"],
                        "active_pair_ids": ["pair01"],
                        "windows": [{"targetId": "target01"}, {"targetId": "target05"}],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            panel_opened_at = datetime(2026, 4, 17, 12, 0, tzinfo=timezone.utc)
            binding_last_write = (panel_opened_at + timedelta(minutes=1)).isoformat()

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PanelRuntimeHints": {
                            "PanelOpenedAtUtc": panel_opened_at.isoformat(),
                            "WindowLaunchAnchorUtc": panel_opened_at.isoformat(),
                            "ActionRunRoot": "C:\\runs\\current",
                            "ActionRunRootUsesOverride": False,
                            "ActionRunRootIsStale": False,
                        },
                        "PairActivationSummary": [
                            {"PairId": "pair01", "EffectiveEnabled": True},
                            {"PairId": "pair03", "EffectiveEnabled": True},
                        ],
                        "OverviewPairs": [
                            {"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"},
                            {"PairId": "pair03", "TopTargetId": "target03", "BottomTargetId": "target07"},
                        ],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {
                            "BindingProfilePath": str(binding_profile),
                            "BindingProfileExists": True,
                            "BindingProfileLastWriteAt": binding_last_write,
                        },
                        "Runtime": {
                            "Exists": True,
                            "PartialReuse": True,
                            "ConfiguredTargetCount": 8,
                            "ExpectedTargetCount": 2,
                            "ActivePairIds": ["pair01"],
                            "ActiveTargetIds": ["target01", "target05"],
                            "InactiveTargetIds": ["target02", "target03", "target04", "target06", "target07", "target08"],
                            "UniqueTargetCount": 2,
                            "AttachedCount": 2,
                            "LaunchedCount": 0,
                            "LauncherSessionIds": ["session-a"],
                            "HasSingleLauncherSession": True,
                        },
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "ExpectedTargetCount": 2,
                        "ConfiguredTargetCount": 8,
                        "InjectableCount": 2,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "stopped"},
                        "Counts": {},
                        "Targets": [],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair03",
            )

        self.assertTrue(state.workflow.windows_ready)
        self.assertTrue(state.workflow.attach_ready)
        self.assertTrue(state.workflow.visibility_ready)
        self.assertFalse(state.workflow.pair_ready)
        self.assertEqual("현재 session 범위 밖", state.overall_label)
        self.assertEqual("2/2", state.cards[0].value)
        self.assertEqual("2/2", state.cards[1].value)
        self.assertEqual("2/2", state.cards[2].value)
        self.assertEqual("차단", state.stages[4].status_text)
        self.assertFalse(state.stages[4].enabled)
        self.assertIn("active=pair01", state.stages[4].detail)
        self.assertEqual("현재 session 범위 밖 pair", state.issues[0].title)

    def test_build_panel_state_counts_binding_windows_in_current_scope_when_binding_file_contains_extra_windows(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps(
                    {
                        "partial_reuse": True,
                        "active_target_ids": ["target01", "target05"],
                        "active_pair_ids": ["pair01"],
                        "windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            panel_opened_at = datetime(2026, 4, 17, 12, 0, tzinfo=timezone.utc)
            binding_last_write = (panel_opened_at + timedelta(minutes=1)).isoformat()

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PanelRuntimeHints": {
                            "PanelOpenedAtUtc": panel_opened_at.isoformat(),
                            "WindowLaunchAnchorUtc": panel_opened_at.isoformat(),
                            "ActionRunRoot": "C:\\runs\\current",
                            "ActionRunRootUsesOverride": False,
                            "ActionRunRootIsStale": False,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {
                            "BindingProfilePath": str(binding_profile),
                            "BindingProfileExists": True,
                            "BindingProfileLastWriteAt": binding_last_write,
                        },
                        "Runtime": {
                            "Exists": True,
                            "PartialReuse": True,
                            "ConfiguredTargetCount": 8,
                            "ExpectedTargetCount": 2,
                            "ActivePairIds": ["pair01"],
                            "ActiveTargetIds": ["target01", "target05"],
                            "InactiveTargetIds": ["target02", "target03", "target04", "target06", "target07", "target08"],
                            "UniqueTargetCount": 2,
                            "AttachedCount": 2,
                            "LaunchedCount": 0,
                            "LauncherSessionIds": ["session-a"],
                            "HasSingleLauncherSession": True,
                        },
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "ExpectedTargetCount": 2,
                        "ConfiguredTargetCount": 8,
                        "InjectableCount": 2,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "stopped"},
                        "Counts": {},
                        "Targets": [],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        self.assertEqual("2/2", state.cards[0].value)
        self.assertIn("현재 세션 binding 2/2", state.stages[0].detail)
        self.assertTrue(state.workflow.windows_ready)

    def test_build_panel_state_blocks_attach_when_runtime_sessions_are_mixed(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )
            panel_opened_at = datetime(2026, 4, 17, 12, 0, tzinfo=timezone.utc)
            binding_last_write = (panel_opened_at + timedelta(minutes=1)).isoformat()

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\current",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": False,
                        },
                        "PanelRuntimeHints": {
                            "PanelOpenedAtUtc": panel_opened_at.isoformat(),
                            "WindowLaunchAnchorUtc": panel_opened_at.isoformat(),
                            "ActionRunRoot": "C:\\runs\\current",
                            "ActionRunRootUsesOverride": False,
                            "ActionRunRootIsStale": False,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {
                            "BindingProfilePath": str(binding_profile),
                            "BindingProfileExists": True,
                            "BindingProfileLastWriteAt": binding_last_write,
                        },
                        "Runtime": {
                            "Exists": True,
                            "UniqueTargetCount": 8,
                            "AttachedCount": 8,
                            "LaunchedCount": 0,
                            "LauncherSessionIds": ["session-a", "session-b"],
                            "HasSingleLauncherSession": False,
                        },
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "stopped"},
                        "Counts": {},
                        "Targets": [],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        self.assertFalse(state.workflow.attach_ready)
        self.assertEqual("필요", state.stages[1].status_text)
        self.assertIn("session=mixed", state.stages[1].detail)
        self.assertFalse(state.stages[2].enabled)
        self.assertEqual("대상 창 연결 안 됨", state.issues[0].title)

    def test_build_panel_state_uses_action_run_root_override_for_display_and_readiness(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )
            panel_opened_at = datetime(2026, 4, 17, 12, 0, tzinfo=timezone.utc)
            binding_last_write = (panel_opened_at + timedelta(minutes=1)).isoformat()

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "",
                            "SelectedRunRootSource": "next-preview",
                            "SelectedRunRootIsStale": False,
                            "NextRunRootPreview": "C:\\runs\\preview-next",
                        },
                        "PanelRuntimeHints": {
                            "PanelOpenedAtUtc": panel_opened_at.isoformat(),
                            "WindowLaunchAnchorUtc": panel_opened_at.isoformat(),
                            "ActionRunRoot": "D:\\manual-runroot",
                            "ActionRunRootUsesOverride": True,
                            "ActionRunRootIsStale": False,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {
                            "BindingProfilePath": str(binding_profile),
                            "BindingProfileExists": True,
                            "BindingProfileLastWriteAt": binding_last_write,
                        },
                        "Runtime": {"Exists": True, "UniqueTargetCount": 8, "AttachedCount": 8, "LaunchedCount": 0},
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "stopped"},
                        "Counts": {},
                        "Targets": [],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        self.assertEqual("override", state.cards[4].value)
        self.assertIn("실행 기준 override: D:\\manual-runroot", state.cards[4].detail)
        self.assertEqual("완료", state.stages[3].status_text)
        self.assertIn("D:\\manual-runroot", state.stages[3].detail)

    def test_build_panel_state_surfaces_stale_run_root_timing_details(self) -> None:
        aggregator = DashboardAggregator()
        with tempfile.TemporaryDirectory() as tmp:
            binding_profile = Path(tmp) / "bindings.json"
            binding_profile.write_text(
                json.dumps({"windows": [{"targetId": f"target{index:02d}"} for index in range(1, 9)]}, ensure_ascii=False),
                encoding="utf-8",
            )
            panel_opened_at = datetime(2026, 4, 17, 12, 0, tzinfo=timezone.utc)
            binding_last_write = (panel_opened_at + timedelta(minutes=1)).isoformat()
            observed_at = (panel_opened_at + timedelta(hours=1)).isoformat()

            state = aggregator.build_panel_state(
                bundle=DashboardRawBundle(
                    effective_data={
                        "RunContext": {
                            "SelectedRunRoot": "C:\\runs\\stale",
                            "SelectedRunRootSource": "explicit",
                            "SelectedRunRootIsStale": True,
                            "SelectedRunRootLastWriteAt": "2026-04-17T10:00:00+00:00",
                            "SelectedRunRootAgeSeconds": 3600,
                            "StaleRunThresholdSec": 1800,
                        },
                        "PanelRuntimeHints": {
                            "PanelOpenedAtUtc": panel_opened_at.isoformat(),
                            "WindowLaunchAnchorUtc": panel_opened_at.isoformat(),
                            "ActionRunRoot": "C:\\runs\\stale",
                            "ActionRunRootUsesOverride": False,
                            "ActionRunRootIsStale": True,
                            "ActionRunRootObservedAt": observed_at,
                            "ActionRunRootLastWriteAt": "2026-04-17T10:00:00+00:00",
                            "ActionRunRootAgeSeconds": 3600,
                            "ActionRunRootThresholdSec": 1800,
                        },
                        "PairActivationSummary": [{"PairId": "pair01", "EffectiveEnabled": True}],
                        "OverviewPairs": [{"PairId": "pair01", "TopTargetId": "target01", "BottomTargetId": "target05"}],
                        "WarningSummary": {},
                    },
                    relay_status={
                        "Lane": {
                            "BindingProfilePath": str(binding_profile),
                            "BindingProfileExists": True,
                            "BindingProfileLastWriteAt": binding_last_write,
                        },
                        "Runtime": {"Exists": True, "UniqueTargetCount": 8, "AttachedCount": 8, "LaunchedCount": 0},
                        "Router": {"Status": "running", "PendingQueueCount": 0, "QueueCount": 0},
                        "NextActions": [],
                    },
                    visibility_status={
                        "InjectableCount": 8,
                        "NonInjectableCount": 0,
                        "MissingRuntimeCount": 0,
                        "Targets": [],
                    },
                    paired_status={
                        "Watcher": {"Status": "stopped"},
                        "Counts": {},
                        "Targets": [],
                    },
                    paired_status_error="",
                ),
                selected_pair="pair01",
            )

        self.assertEqual("오래된 RunRoot", state.overall_label)
        self.assertEqual("주의", state.stages[3].status_text)
        self.assertIn("last_write=2026-04-17T10:00:00+00:00", state.stages[3].detail)
        self.assertIn("now=2026-04-17T13:00:00+00:00", state.stages[3].detail)
        self.assertIn("age=3600s", state.stages[3].detail)
        self.assertIn("threshold=1800s", state.stages[3].detail)


class WatcherServiceTests(unittest.TestCase):
    def test_get_runtime_status_requires_run_root_for_trustworthy_state(self) -> None:
        service = WatcherService()

        status = service.get_runtime_status({"Watcher": {"Status": "running"}}, run_root="")

        self.assertEqual("unknown", status.state)
        self.assertIn("runroot_missing", status.reason_codes)

    def test_get_stop_eligibility_blocks_pending_forward_exists(self) -> None:
        service = WatcherService()
        paired_status = {
            "Watcher": {"Status": "running"},
            "Counts": {
                "ReadyToForwardCount": 1,
                "FailureLineCount": 2,
                "NoZipCount": 1,
            },
        }

        eligibility = service.get_stop_eligibility(paired_status, run_root="C:\\runs\\current")

        self.assertFalse(eligibility.allowed)
        self.assertEqual("running", eligibility.state)
        self.assertIn("pending_forward_exists", eligibility.reason_codes)

    def test_get_stop_eligibility_blocks_handoff_ready_count_without_legacy_ready_count(self) -> None:
        service = WatcherService()
        paired_status = {
            "Watcher": {"Status": "running"},
            "Counts": {
                "HandoffReadyCount": 1,
                "ReadyToForwardCount": 0,
            },
        }

        eligibility = service.get_stop_eligibility(paired_status, run_root="C:\\runs\\current")

        self.assertFalse(eligibility.allowed)
        self.assertIn("pending_forward_exists", eligibility.reason_codes)
        self.assertIn("다음 전달 가능", eligibility.message)

    def test_get_stop_eligibility_keeps_noncritical_states_as_warnings(self) -> None:
        service = WatcherService()
        paired_status = {
            "Watcher": {"Status": "running"},
            "Counts": {
                "ReadyToForwardCount": 0,
                "FailureLineCount": 2,
                "NoZipCount": 1,
            },
        }

        eligibility = service.get_stop_eligibility(paired_status, run_root="C:\\runs\\current")

        self.assertTrue(eligibility.allowed)
        self.assertEqual("running", eligibility.state)
        self.assertIn("recent_failure_present", eligibility.warning_codes)
        self.assertIn("incomplete_artifacts_present", eligibility.warning_codes)

    def test_get_runtime_status_reports_unreadable_control_and_status_files(self) -> None:
        service = WatcherService()
        status = service.get_runtime_status(
            {
                "Watcher": {
                    "Status": "stopped",
                    "ControlParseError": "bad json",
                    "StatusParseError": "bad status json",
                }
            },
            run_root="C:\\runs\\current",
        )

        self.assertIn("control_file_unreadable", status.reason_codes)
        self.assertIn("status_file_unreadable", status.reason_codes)

    def test_get_runtime_status_reports_stale_pending_stop(self) -> None:
        service = WatcherService()
        status = service.get_runtime_status(
            {
                "Watcher": {
                    "Status": "running",
                    "ControlPendingAction": "stop",
                    "ControlAgeSeconds": 99,
                }
            },
            run_root="C:\\runs\\current",
        )

        self.assertEqual("stop_requested", status.state)
        self.assertIn("stop_requested_timeout", status.reason_codes)

    def test_get_runtime_status_uses_heartbeat_freshness(self) -> None:
        service = WatcherService()
        status = service.get_runtime_status(
            {
                "Watcher": {
                    "Status": "running",
                    "HeartbeatAt": "2026-04-05T21:00:00+09:00",
                    "HeartbeatAgeSeconds": 25,
                    "StatusSequence": 7,
                    "ProcessStartedAt": "2026-04-05T20:59:00+09:00",
                }
            },
            run_root="C:\\runs\\current",
        )

        self.assertEqual("2026-04-05T21:00:00+09:00", status.heartbeat_at)
        self.assertEqual(25, status.heartbeat_age_seconds)
        self.assertEqual(7, status.status_sequence)
        self.assertIn("status_file_stale", status.reason_codes)

    def test_get_start_eligibility_blocks_unreadable_status_file(self) -> None:
        service = WatcherService()

        eligibility = service.get_start_eligibility(
            {
                "Watcher": {
                    "Status": "stopped",
                    "StatusParseError": "bad json",
                    "StatusPath": "C:\\runs\\current\\.state\\watcher-status.json",
                }
            },
            run_root="C:\\runs\\current",
        )

        self.assertFalse(eligibility.allowed)
        self.assertIn("status_file_unreadable", eligibility.reason_codes)
        self.assertEqual("watch status 파일 확인", eligibility.recommended_action)
        self.assertIn("watcher-status.json", eligibility.message)
        self.assertIn("bad json", eligibility.message)

    def test_get_stop_eligibility_surfaces_unreadable_file_details(self) -> None:
        service = WatcherService()

        eligibility = service.get_stop_eligibility(
            {
                "Watcher": {
                    "Status": "running",
                    "ControlParseError": "bad control json",
                    "ControlPath": "C:\\runs\\current\\.state\\watcher-control.json",
                }
            },
            run_root="C:\\runs\\current",
        )

        self.assertFalse(eligibility.allowed)
        self.assertIn("control_file_unreadable", eligibility.reason_codes)
        self.assertIn("watcher-control.json", eligibility.message)
        self.assertIn("bad control json", eligibility.message)

    def test_get_start_eligibility_marks_stale_pending_stop_as_recoverable(self) -> None:
        service = WatcherService()

        eligibility = service.get_start_eligibility(
            {
                "Watcher": {
                    "Status": "stopped",
                    "ControlPendingAction": "stop",
                    "ControlAgeSeconds": 99,
                }
            },
            run_root="C:\\runs\\current",
        )

        self.assertFalse(eligibility.allowed)
        self.assertTrue(eligibility.cleanup_allowed)
        self.assertIn("stop_requested_timeout", eligibility.reason_codes)

    def test_recover_stale_start_blockers_clears_stale_stop_request(self) -> None:
        service = WatcherService()

        with tempfile.TemporaryDirectory() as tmp:
            control_path = Path(tmp) / ".state" / "watcher-control.json"
            control_path.parent.mkdir(parents=True, exist_ok=True)
            control_path.write_text(
                json.dumps(
                    {
                        "SchemaVersion": "1.0.0",
                        "Action": "stop",
                        "RunRoot": tmp,
                        "RequestId": "stale-req",
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )

            result = service.recover_stale_start_blockers(
                tmp,
                {
                    "Watcher": {
                        "Status": "stopped",
                        "ControlPath": str(control_path),
                        "ControlPendingAction": "stop",
                        "ControlAgeSeconds": 99,
                    }
                },
            )

            self.assertTrue(result.ok)
            self.assertFalse(control_path.exists())

    def test_request_stop_writes_control_file(self) -> None:
        service = WatcherService()
        paired_status = {"Watcher": {"Status": "running"}, "Counts": {}}

        with tempfile.TemporaryDirectory() as tmp:
            result = service.request_stop(paired_status, tmp)

            self.assertTrue(result.ok)
            self.assertEqual("stop_requested", result.state)
            control_path = Path(tmp) / ".state" / "watcher-control.json"
            self.assertTrue(control_path.exists())
            payload = json.loads(control_path.read_text(encoding="utf-8"))
            self.assertEqual("stop", payload["Action"])
            self.assertEqual(tmp, payload["RunRoot"])
            self.assertEqual(result.request_id, payload["RequestId"])

    def test_request_stop_blocks_stale_control_file_when_watcher_is_stopped(self) -> None:
        service = WatcherService()
        paired_status = {
            "Watcher": {
                "Status": "stopped",
                "ControlPath": "",
            },
            "Counts": {},
        }

        with tempfile.TemporaryDirectory() as tmp:
            control_path = Path(tmp) / ".state" / "watcher-control.json"
            control_path.parent.mkdir(parents=True, exist_ok=True)
            control_path.write_text(
                json.dumps(
                    {
                        "SchemaVersion": "1.0.0",
                        "Action": "stop",
                        "RunRoot": tmp,
                        "RequestId": "stale-req",
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )
            paired_status["Watcher"]["ControlPath"] = str(control_path)

            result = service.request_stop(paired_status, tmp)

            self.assertFalse(result.ok)
            self.assertEqual("stopped", result.state)
            self.assertIn("stale_control_file", result.reason_codes)

    def test_clear_stale_control_file_requires_stopped_state(self) -> None:
        service = WatcherService()
        with tempfile.TemporaryDirectory() as tmp:
            control_path = Path(tmp) / ".state" / "watcher-control.json"
            control_path.parent.mkdir(parents=True, exist_ok=True)
            control_path.write_text("{}", encoding="utf-8")

            blocked = service.clear_stale_control_file(
                tmp,
                {"Watcher": {"Status": "running", "ControlPath": str(control_path)}},
            )
            self.assertFalse(blocked.ok)

            cleared = service.clear_stale_control_file(
                tmp,
                {"Watcher": {"Status": "stopped", "ControlPath": str(control_path)}},
            )
            self.assertTrue(cleared.ok)
            self.assertFalse(control_path.exists())

    def test_wait_for_stopped_requires_ack_and_control_clear(self) -> None:
        service = WatcherService()
        with tempfile.TemporaryDirectory() as tmp:
            control_path = Path(tmp) / ".state" / "watcher-control.json"
            control_path.parent.mkdir(parents=True, exist_ok=True)
            control_path.write_text("{}", encoding="utf-8")
            statuses = [
                {
                    "Watcher": {
                        "Status": "stopped",
                        "ControlPath": str(control_path),
                        "ControlPendingAction": "stop",
                    }
                },
                {
                    "Watcher": {
                        "Status": "stopped",
                        "ControlPath": str(control_path),
                        "LastHandledRequestId": "req-1",
                        "LastHandledAction": "stop",
                        "LastHandledResult": "stopped",
                    }
                },
            ]
            index = {"value": 0}

            def status_loader(run_root: str):
                current = statuses[index["value"]]
                if index["value"] == 0:
                    control_path.unlink(missing_ok=True)
                index["value"] = min(index["value"] + 1, len(statuses) - 1)
                return current, ""

            result = service.wait_for_stopped(
                status_loader,
                tmp,
                request_id="req-1",
                timeout_sec=0.1,
                poll_interval_sec=0.0,
            )

            self.assertTrue(result.ok)
            self.assertEqual("stopped", result.state)

    def test_wait_for_stopped_fails_without_request_ack(self) -> None:
        service = WatcherService()

        with tempfile.TemporaryDirectory() as tmp:
            control_path = Path(tmp) / ".state" / "watcher-control.json"
            control_path.parent.mkdir(parents=True, exist_ok=True)
            control_path.write_text("{}", encoding="utf-8")

            def status_loader(run_root: str):
                control_path.unlink(missing_ok=True)
                return {
                    "Watcher": {
                        "Status": "stopped",
                        "ControlPath": str(control_path),
                        "LastHandledRequestId": "",
                        "LastHandledAction": "",
                        "LastHandledResult": "",
                    }
                }, ""

            result = service.wait_for_stopped(
                status_loader,
                tmp,
                request_id="req-1",
                timeout_sec=0.01,
                poll_interval_sec=0.0,
            )

            self.assertFalse(result.ok)
            self.assertIn("request_ack_missing", result.reason_codes)

    def test_restart_waits_for_stopped_before_starting(self) -> None:
        service = WatcherService()
        command_service = RecordingCommandService()
        ack_request_id = {"value": ""}
        loader_calls: list[str] = []

        def status_loader(run_root: str):
            loader_calls.append(run_root)
            control_path = Path(run_root) / ".state" / "watcher-control.json"
            if control_path.exists():
                payload = json.loads(control_path.read_text(encoding="utf-8"))
                ack_request_id["value"] = payload["RequestId"]
                control_path.unlink(missing_ok=True)
                return {
                    "Watcher": {
                        "Status": "stopped",
                        "ControlPath": str(control_path),
                        "LastHandledRequestId": ack_request_id["value"],
                        "LastHandledAction": "stop",
                        "LastHandledResult": "stopped",
                    }
                }, ""
            return {
                "Watcher": {
                    "Status": "running",
                    "ControlPath": str(control_path),
                    "LastHandledRequestId": ack_request_id["value"],
                    "LastHandledAction": "stop",
                    "LastHandledResult": "stopped",
                }
            }, ""

        with tempfile.TemporaryDirectory() as tmp:
            request = WatcherStartRequest(config_path="cfg.psd1", run_root=tmp)
            result = service.restart(
                command_service,
                status_loader,
                {"Watcher": {"Status": "running"}, "Counts": {}},
                request,
                stop_timeout_sec=1.0,
                running_timeout_sec=1.0,
                poll_interval_sec=0.0,
            )

            self.assertTrue(result.ok)
            self.assertEqual("running", result.state)
            self.assertEqual(1, len(command_service.spawned_commands))
            self.assertGreaterEqual(len(loader_calls), 2)
            control_path = Path(tmp) / ".state" / "watcher-control.json"
            self.assertFalse(control_path.exists())

    def test_restart_is_blocked_when_ready_to_forward_exists(self) -> None:
        service = WatcherService()
        command_service = RecordingCommandService()

        result = service.restart(
            command_service,
            lambda run_root: ({"Watcher": {"Status": "running"}}, ""),
            {
                "Watcher": {"Status": "running"},
                "Counts": {"ReadyToForwardCount": 1},
            },
            WatcherStartRequest(config_path="cfg.psd1", run_root="C:\\runs\\current"),
            poll_interval_sec=0.0,
        )

        self.assertFalse(result.ok)
        self.assertIn("pending_forward_exists", result.reason_codes)
        self.assertEqual([], command_service.spawned_commands)


class WatcherControllerTests(unittest.TestCase):
    def test_diagnostics_includes_parse_errors_and_paths(self) -> None:
        controller = WatcherController(WatcherService())
        diagnostics = controller.diagnostics(
            {
                "Watcher": {
                    "Status": "stopped",
                    "ControlPath": "C:\\runs\\current\\.state\\watcher-control.json",
                    "StatusPath": "C:\\runs\\current\\.state\\watcher-status.json",
                    "ControlParseError": "bad control",
                    "StatusParseError": "bad status",
                }
            },
            "C:\\runs\\current",
        )

        self.assertIn("ControlParseError: bad control", diagnostics.details)
        self.assertIn("StatusParseError: bad status", diagnostics.details)
        self.assertIn("AuditLogPath:", diagnostics.details)
        self.assertIn("StartPresetMaxForwardCount: 2", diagnostics.details)
        self.assertIn("StartPresetRunDurationSec: 900", diagnostics.details)
        self.assertIn("HeartbeatAt:", diagnostics.details)
        self.assertIn("StartAllowed: 아니오", diagnostics.details)
        self.assertIn("watch=stopped", diagnostics.hint)

    def test_recommended_action_points_to_status_file_for_unreadable_status(self) -> None:
        controller = WatcherController(WatcherService())

        recommendation = controller.recommended_action(
            {
                "Watcher": {
                    "Status": "stopped",
                    "StatusParseError": "bad status",
                }
            },
            "C:\\runs\\current",
        )

        self.assertIsNotNone(recommendation)
        self.assertEqual("open_watcher_status", recommendation.action_key)

    def test_recommended_action_points_to_ready_target_when_pending_forward_exists(self) -> None:
        controller = WatcherController(WatcherService())

        recommendation = controller.recommended_action(
            {
                "Watcher": {"Status": "running"},
                "Counts": {"ReadyToForwardCount": 1},
            },
            "C:\\runs\\current",
        )

        self.assertIsNotNone(recommendation)
        self.assertEqual("focus_ready_to_forward_artifact", recommendation.action_key)

    def test_recommended_action_explains_forward_limit_stop(self) -> None:
        controller = WatcherController(WatcherService())

        recommendation = controller.recommended_action(
            {
                "Watcher": {
                    "Status": "stopped",
                    "StatusReason": "max-forward-count-reached",
                }
            },
            "C:\\runs\\current",
        )

        self.assertIsNotNone(recommendation)
        self.assertEqual("start_watcher", recommendation.action_key)
        self.assertIn("2회 forward", recommendation.detail)

    def test_recommended_action_explains_forward_limit_stop_from_stop_category(self) -> None:
        controller = WatcherController(WatcherService())

        recommendation = controller.recommended_action(
            {
                "Watcher": {
                    "Status": "stopped",
                    "StopCategory": "expected-limit",
                }
            },
            "C:\\runs\\current",
        )

        self.assertIsNotNone(recommendation)
        self.assertEqual("start_watcher", recommendation.action_key)
        self.assertIn("2회 forward", recommendation.detail)

    def test_diagnostics_interprets_forward_limit_stop(self) -> None:
        controller = WatcherController(WatcherService())

        diagnostics = controller.diagnostics(
            {
                "Watcher": {
                    "Status": "stopped",
                    "StatusReason": "max-forward-count-reached",
                }
            },
            "C:\\runs\\current",
        )

        self.assertIn("StatusInterpretation: 기본 watch 시작 preset의 forward 한도에 도달해 정지했습니다.", diagnostics.details)
        self.assertIn("ContinuousWatchGuidance:", diagnostics.details)
        self.assertIn("forward_limit=2", diagnostics.hint)

    def test_start_blocks_unreadable_status_file(self) -> None:
        controller = WatcherController(WatcherService())
        command_service = RecordingCommandService()

        result, notes = controller.start(
            command_service,
            config_path="cfg.psd1",
            run_root="C:\\runs\\current",
            paired_status={
                "Watcher": {
                    "Status": "stopped",
                    "StatusParseError": "bad status",
                }
            },
        )

        self.assertFalse(result.ok)
        self.assertIn("status_file_unreadable", result.reason_codes)
        self.assertEqual([], notes)
        self.assertEqual([], command_service.spawned_commands)

    def test_start_can_clear_stale_pending_stop_before_spawn(self) -> None:
        controller = WatcherController(WatcherService())
        command_service = RecordingCommandService()

        with tempfile.TemporaryDirectory() as tmp:
            control_path = Path(tmp) / ".state" / "watcher-control.json"
            control_path.parent.mkdir(parents=True, exist_ok=True)
            control_path.write_text(
                json.dumps(
                    {
                        "SchemaVersion": "1.0.0",
                        "Action": "stop",
                        "RunRoot": tmp,
                        "RequestId": "stale-req",
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )

            result, notes = controller.start(
                command_service,
                config_path="cfg.psd1",
                run_root=tmp,
                paired_status={
                    "Watcher": {
                        "Status": "stopped",
                        "ControlPath": str(control_path),
                        "ControlPendingAction": "stop",
                        "ControlAgeSeconds": 99,
                    }
                },
                clear_stale_first=True,
            )

            self.assertTrue(result.ok)
            self.assertEqual("starting", result.state)
            self.assertEqual(1, len(command_service.spawned_commands))
            self.assertTrue(any("정리했습니다" in note for note in notes))
            self.assertFalse(control_path.exists())


class RelayOperatorPanelArtifactHardeningTests(unittest.TestCase):
    def _make_panel(self, memory_path: Path) -> RelayOperatorPanel:
        panel = RelayOperatorPanel.__new__(RelayOperatorPanel)
        panel.artifact_source_memory_path = memory_path
        panel.artifact_source_memory_warning = ""
        panel.artifact_last_sources_by_target = {}
        panel.artifact_last_action_by_target = {}
        panel.artifact_submit_active_targets = set()
        panel.run_root_var = VarStub("")
        panel.effective_data = {
            "RunContext": {
                "SelectedRunRoot": "C:\\runs\\current",
                "SelectedRunRootIsStale": False,
            }
        }
        return panel

    def test_source_memory_roundtrip_writes_schema_versioned_payload(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            memory_path = Path(tmp) / "artifact-source-memory.json"
            panel = self._make_panel(memory_path)
            panel.artifact_last_sources_by_target = {
                "target01": {
                    "SummarySourcePath": "C:\\work\\summary.txt",
                    "ReviewZipSourcePath": "C:\\work\\review.zip",
                    "RecordedAt": "2026-04-11T07:20:00",
                }
            }

            panel._save_artifact_source_memory()

            payload = json.loads(memory_path.read_text(encoding="utf-8"))
            self.assertEqual(ARTIFACT_SOURCE_MEMORY_SCHEMA_VERSION, payload["SchemaVersion"])
            self.assertIn("SavedAt", payload)
            self.assertEqual("C:\\work\\summary.txt", payload["Targets"]["target01"]["SummarySourcePath"])
            self.assertEqual("", panel.artifact_source_memory_warning)

            reloaded_panel = self._make_panel(memory_path)
            reloaded_panel._load_artifact_source_memory()

            self.assertEqual(panel.artifact_last_sources_by_target, reloaded_panel.artifact_last_sources_by_target)
            self.assertEqual("", reloaded_panel.artifact_source_memory_warning)

    def test_source_memory_invalid_json_resets_cache_and_sets_warning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            memory_path = Path(tmp) / "artifact-source-memory.json"
            memory_path.write_text("{ invalid json", encoding="utf-8")
            panel = self._make_panel(memory_path)
            panel.artifact_last_sources_by_target = {
                "target01": {
                    "SummarySourcePath": "C:\\stale\\summary.txt",
                    "ReviewZipSourcePath": "",
                    "RecordedAt": "2026-04-11T07:20:00",
                }
            }

            panel._load_artifact_source_memory()

            self.assertEqual({}, panel.artifact_last_sources_by_target)
            self.assertIn("parse failed", panel.artifact_source_memory_warning)
            self.assertIn("artifact-source-memory.json", panel.artifact_source_memory_warning)

    def test_artifact_warning_badges_include_memory_stale_and_fallback_risks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            panel = self._make_panel(Path(tmp) / "artifact-source-memory.json")
            panel.artifact_source_memory_warning = "broken json recovered"
            panel.effective_data = {
                "RunContext": {
                    "SelectedRunRoot": "C:\\runs\\current",
                    "SelectedRunRootIsStale": True,
                }
            }

            badges = panel._artifact_warning_badges(
                state=make_artifact_state(),
                contract_paths={
                    "CheckScriptPathExists": False,
                    "SubmitScriptPathExists": False,
                },
            )

            self.assertIn("[SOURCE MEMORY WARNING]", badges)
            self.assertIn("[STALE RUNROOT WARNING]", badges)
            self.assertIn("[LEGACY CHECK FALLBACK RISK]", badges)
            self.assertIn("[LEGACY SUBMIT FALLBACK RISK]", badges)

    def test_confirm_recent_submit_repeat_prompts_for_recent_submit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            panel = self._make_panel(Path(tmp) / "artifact-source-memory.json")
            panel.artifact_last_action_by_target = {
                "target01": {
                    "Action": "submit",
                    "Status": "success",
                    "RecordedAt": datetime.now().isoformat(timespec="seconds"),
                }
            }

            with mock.patch("relay_operator_panel.messagebox.askyesno", return_value=False) as ask:
                allowed = panel._confirm_recent_submit_repeat("target01")

            self.assertFalse(allowed)
            ask.assert_called_once()
            self.assertEqual("submit 재실행 확인", ask.call_args.args[0])

    def test_import_selected_external_artifact_requires_extra_confirmation_for_fallback_submit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            panel = self._make_panel(Path(tmp) / "artifact-source-memory.json")
            state = make_artifact_state(
                target_id="target01",
                target_folder="C:\\runs\\current\\pair01\\target01",
                review_folder="C:\\runs\\current\\pair01\\target01\\reviewfile",
            )
            panel.output_text = object()
            panel.last_command_var = VarStub("")
            panel.set_text = lambda *_args, **_kwargs: None
            panel.refresh_paired_status_only = lambda *args, **kwargs: None
            panel.on_artifact_row_selected = lambda *args, **kwargs: None
            panel._selected_artifact_action_context = lambda: (state, "cfg.psd1", "C:\\runs\\current")
            panel._prompt_external_artifact_sources = lambda _state: ("C:\\work\\summary.txt", "C:\\work\\review.zip")
            panel._remember_artifact_sources = lambda *_args, **_kwargs: None
            panel._remember_artifact_action_result = lambda *_args, **_kwargs: None
            panel._confirm_recent_submit_repeat = lambda _target_id: True
            panel._begin_submit_action = lambda _target_id: True
            panel._finish_submit_action = lambda _target_id: None
            panel._current_run_root_is_stale_for_actions = lambda: False

            class CommandServiceStub:
                def run_json(self, _command: list[str]) -> dict:
                    return {
                        "Validation": {"Ok": True, "RequiresOverwrite": False},
                        "Preflight": {
                            "SummaryLines": ["ready"],
                            "DestinationZipPath": "C:\\runs\\current\\pair01\\target01\\reviewfile\\review.zip",
                        },
                        "PreImportStatus": {"LatestState": "no-zip"},
                    }

            panel.command_service = CommandServiceStub()

            def build_action_command(*, wrapper_key: str, **_kwargs):
                if wrapper_key == "CheckScriptPath":
                    return (
                        ["check-script"],
                        "C:\\legacy\\check-paired-exchange-artifact.ps1",
                        False,
                        {"Source": "fallback"},
                    )
                return (
                    ["submit-script"],
                    "C:\\legacy\\import-paired-exchange-artifact.ps1",
                    False,
                    {"Source": "fallback"},
                )

            panel._build_artifact_action_command = build_action_command
            background_called = {"value": False}
            panel.run_background_task = lambda **_kwargs: background_called.__setitem__("value", True)

            with mock.patch(
                "relay_operator_panel.messagebox.askyesno",
                side_effect=[True, False],
            ) as ask, mock.patch("relay_operator_panel.messagebox.showwarning"):
                panel.import_selected_external_artifact()

            self.assertFalse(background_called["value"])
            self.assertEqual(
                ["외부 artifact import", "legacy fallback submit 확인"],
                [call.args[0] for call in ask.call_args_list],
            )

    def test_focus_ready_to_forward_artifact_prefers_handoff_ready_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            panel = self._make_panel(Path(tmp) / "artifact-source-memory.json")
            panel.artifact_service = ArtifactService()
            panel.artifact_states = [
                make_artifact_state(target_id="target01", latest_state="forwarded"),
                make_artifact_state(target_id="target05", latest_state="no-zip", source_outbox_next_action="handoff-ready"),
            ]

            class TreeStub:
                def __init__(self) -> None:
                    self.selected: str | None = None

                def selection_set(self, iid: str) -> None:
                    self.selected = iid

                def see(self, iid: str) -> None:
                    self.selected = iid

            class NotebookStub:
                def __init__(self) -> None:
                    self.selected_tab = None

                def select(self, tab) -> None:
                    self.selected_tab = tab

            panel.artifact_tree = TreeStub()
            panel.notebook = NotebookStub()
            panel.artifacts_tab = object()
            panel.output_text = object()
            panel.refresh_artifacts_tab = lambda: None
            panel.on_artifact_row_selected = lambda *_args, **_kwargs: None
            status_updates: list[tuple[str, str, str]] = []
            output_updates: list[str] = []
            panel.set_operator_status = lambda state, hint="", last_result="": status_updates.append((state, hint, last_result))
            panel.set_text = lambda _widget, text: output_updates.append(text)

            panel.focus_ready_to_forward_artifact()

            self.assertEqual("target05", panel.artifact_tree.selected)
            self.assertIs(panel.artifacts_tab, panel.notebook.selected_tab)
            self.assertTrue(any("다음 전달 가능 상태" in hint for _state, hint, _last in status_updates))
            self.assertTrue(any("다음 전달 가능 target 선택" in text for text in output_updates))

    def test_format_external_artifact_preflight_clarifies_source_vs_submit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            panel = self._make_panel(Path(tmp) / "artifact-source-memory.json")

            text = panel._format_external_artifact_preflight(
                {
                    "Validation": {"Issues": [], "Warnings": []},
                    "Preflight": {"SummaryLines": ["Target: target01", "Current LatestState: no-zip"]},
                }
            )

            self.assertIn("source zip은 입력 source", text)
            self.assertIn("target folder contract", text)
            self.assertIn("Target: target01", text)


if __name__ == "__main__":
    unittest.main()
