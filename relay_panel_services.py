from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from shutil import which

from relay_panel_contract import get_watcher_bridge_contract_errors
from relay_panel_models import AppContext, DashboardRawBundle


ROOT = Path(__file__).resolve().parent
SNAPSHOT_DIR = ROOT / "_tmp"
POWERSHELL = which("pwsh.exe") or which("pwsh") or ""
POWERSHELL_REQUIRED_MESSAGE = (
    "pwsh (PowerShell 7+) is required for relay panel commands; powershell.exe fallback is not supported."
)
PYTHON_CLI = which("py.exe") or which("python.exe") or (sys.executable if Path(sys.executable).name.lower() != "pythonw.exe" else "") or "python"
CONFIG_PRESETS = [
    ROOT / "config" / "settings.bottest-live-visible.psd1",
    ROOT / "config" / "settings.bottest-live.psd1",
    ROOT / "config" / "settings.psd1",
]
SCRIPT_ARGUMENT_POLICY = {
    "attach-targets-from-bindings.ps1": {"config": True},
    "check-paired-exchange-artifact.ps1": {"config": True, "run_root": True, "target": True},
    "check-headless-exec-readiness.ps1": {"config": True, "run_root": True},
    "check-target-window-visibility.ps1": {"config": True, "json_stdout_on_error": True},
    "tests/Confirm-PairedExchangeHandoffPrimitive.ps1": {"config": True, "run_root": True, "pair": True, "target": True},
    "tests/Confirm-PairedExchangePublishPrimitive.ps1": {"config": True, "run_root": True, "pair": True, "target": True},
    "disable-pair.ps1": {"config": True, "pair": True},
    "enable-pair.ps1": {"config": True, "pair": True},
    "export-config-json.ps1": {"config": True},
    "import-paired-exchange-artifact.ps1": {"config": True, "run_root": True, "target": True},
    "tests/Invoke-PairedExchangeOneShotSubmit.ps1": {"config": True, "run_root": True, "pair": True, "target": True},
    "refresh-binding-profile-from-existing.ps1": {"config": True, "json_stdout_on_error": True},
    "router.ps1": {"config": True},
    "show-effective-config.ps1": {"config": True, "run_root": True, "pair": True, "target": True},
    "show-paired-exchange-status.ps1": {"config": True, "run_root": True},
    "show-paired-run-summary.ps1": {"config": True, "run_root": True},
    "show-relay-status.ps1": {"config": True},
    "tests/Start-PairedExchangeTest.ps1": {"config": True, "run_root": True},
    "tests/Watch-PairedExchange.ps1": {"config": True, "run_root": True},
}


class PowerShellError(RuntimeError):
    def __init__(
        self,
        detail: str,
        *,
        returncode: int | None = None,
        stdout: str = "",
        stderr: str = "",
    ) -> None:
        super().__init__(detail)
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def require_powershell_host(host_path: str = "") -> str:
    resolved = str(host_path or "").strip() or POWERSHELL
    if resolved:
        return resolved
    raise PowerShellError(POWERSHELL_REQUIRED_MESSAGE)


def existing_config_presets() -> list[str]:
    return [str(path) for path in CONFIG_PRESETS if path.exists()]


def _normalize_script_name(script_name: str) -> str:
    return script_name.replace("\\", "/")


def _load_json_payload(raw: str) -> dict | None:
    raw = raw.strip()
    if not raw:
        return None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def build_command(
    script_name: str,
    config_path: str = "",
    run_root: str = "",
    pair_id: str = "",
    target_id: str = "",
    extra: list[str] | None = None,
) -> list[str]:
    command = [
        require_powershell_host(),
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(ROOT / script_name),
    ]
    if config_path:
        command += ["-ConfigPath", config_path]
    if run_root:
        command += ["-RunRoot", run_root]
    if pair_id:
        command += ["-PairId", pair_id]
    if target_id:
        command += ["-TargetId", target_id]
    if extra:
        command += extra
    return command


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit={completed.returncode}"
        raise PowerShellError(
            detail,
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
    return completed


class CommandService:
    def __init__(self) -> None:
        self.powershell = POWERSHELL
        self.python_cli = PYTHON_CLI
        self._detached_processes: list[subprocess.Popen[str]] = []

    def script_policy(self, script_name: str) -> dict[str, object]:
        normalized = _normalize_script_name(script_name)
        return SCRIPT_ARGUMENT_POLICY.get(normalized, {"config": True})

    def script_allows_json_stdout_on_error(self, script_name: str) -> bool:
        return bool(self.script_policy(script_name).get("json_stdout_on_error", False))

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
        normalized = _normalize_script_name(script_name)
        policy = self.script_policy(normalized)
        return build_command(
            script_name=normalized,
            config_path=config_path if policy.get("config") else "",
            run_root=run_root if policy.get("run_root") else "",
            pair_id=pair_id if policy.get("pair") else "",
            target_id=target_id if policy.get("target") else "",
            extra=extra,
        )

    def build_python_command(self, script_path: str) -> list[str]:
        launcher = self.python_cli
        if Path(launcher).stem.lower() == "py":
            return [launcher, "-3", script_path]
        return [launcher, script_path]

    def build_powershell_file_command(self, script_path: str, extra: list[str] | None = None) -> list[str]:
        command = [
            require_powershell_host(self.powershell),
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script_path,
        ]
        if extra:
            command.extend(extra)
        return command

    def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        return run_command(command)

    def run_json(self, command: list[str], *, allow_json_stdout_on_error: bool = False) -> dict:
        try:
            completed = self.run(command)
        except PowerShellError as exc:
            if allow_json_stdout_on_error:
                payload = _load_json_payload(exc.stdout)
                if payload is not None:
                    return payload
            raise
        return json.loads(completed.stdout)

    def spawn_detached(self, command: list[str]) -> None:
        self.reap_detached_processes()
        process = subprocess.Popen(command, cwd=ROOT)
        self._detached_processes.append(process)

    def reap_detached_processes(self, *, wait_timeout_sec: float = 0.0) -> None:
        remaining: list[subprocess.Popen[str]] = []
        for process in self._detached_processes:
            try:
                if wait_timeout_sec > 0:
                    process.wait(timeout=wait_timeout_sec)
                else:
                    process.poll()
            except subprocess.TimeoutExpired:
                remaining.append(process)
                continue
            if process.returncode is None:
                remaining.append(process)
        self._detached_processes = remaining


class StatusService:
    def __init__(self, command_service: CommandService) -> None:
        self.command_service = command_service

    def _annotate_watcher_bridge_contract_errors(self, payload: dict | None) -> dict | None:
        if not isinstance(payload, dict):
            return payload

        errors = get_watcher_bridge_contract_errors(payload)
        if not errors:
            return payload

        normalized_payload = dict(payload)
        watcher_raw = normalized_payload.get("Watcher", {})
        watcher = dict(watcher_raw) if isinstance(watcher_raw, dict) else {}
        contract_error = "watcher bridge contract invalid: {0}".format(" | ".join(errors))
        existing_error = str(watcher.get("StatusParseError", "") or "").strip()
        watcher["StatusParseError"] = (
            contract_error
            if not existing_error
            else "{0} | {1}".format(existing_error, contract_error)
        )
        normalized_payload["Watcher"] = watcher
        return normalized_payload

    def run_script(
        self,
        script_name: str,
        context: AppContext,
        *,
        extra: list[str] | None = None,
        run_root_override: str | None = None,
        pair_id_override: str | None = None,
        target_id_override: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = self.command_service.build_script_command(
            script_name=script_name,
            config_path=context.config_path,
            run_root=context.run_root if run_root_override is None else run_root_override,
            pair_id=context.pair_id if pair_id_override is None else pair_id_override,
            target_id=context.target_id if target_id_override is None else target_id_override,
            extra=extra,
        )
        return self.command_service.run(command)

    def run_json_script(
        self,
        script_name: str,
        context: AppContext,
        *,
        extra: list[str] | None = None,
        run_root_override: str | None = None,
        pair_id_override: str | None = None,
        target_id_override: str | None = None,
        allow_json_stdout_on_error: bool | None = None,
    ) -> dict:
        command = self.command_service.build_script_command(
            script_name=script_name,
            config_path=context.config_path,
            run_root=context.run_root if run_root_override is None else run_root_override,
            pair_id=context.pair_id if pair_id_override is None else pair_id_override,
            target_id=context.target_id if target_id_override is None else target_id_override,
            extra=extra,
        )
        resolved_allow = (
            (
                self.command_service.script_allows_json_stdout_on_error(script_name)
                if hasattr(self.command_service, "script_allows_json_stdout_on_error")
                else bool(
                    SCRIPT_ARGUMENT_POLICY.get(_normalize_script_name(script_name), {"config": True}).get(
                        "json_stdout_on_error",
                        False,
                    )
                )
            )
            if allow_json_stdout_on_error is None
            else allow_json_stdout_on_error
        )
        if hasattr(self.command_service, "run_json"):
            return self.command_service.run_json(
                command,
                allow_json_stdout_on_error=resolved_allow,
            )

        try:
            completed = self.command_service.run(command)
        except PowerShellError as exc:
            if resolved_allow:
                payload = _load_json_payload(exc.stdout)
                if payload is not None:
                    return payload
            raise
        return json.loads(completed.stdout)

    def try_load_paired_status(self, context: AppContext, run_root: str) -> tuple[dict | None, str]:
        try:
            payload = self.run_json_script(
                "show-paired-exchange-status.ps1",
                context,
                extra=["-AsJson"],
                run_root_override=run_root,
            )
            payload = self._annotate_watcher_bridge_contract_errors(payload)
            return payload, ""
        except Exception as exc:
            return None, str(exc)

    def load_effective_config(self, context: AppContext) -> dict:
        return self.run_json_script(
            "show-effective-config.ps1",
            context,
            extra=["-AsJson"],
            pair_id_override="",
            target_id_override="",
        )

    def load_relay_status(self, context: AppContext) -> dict:
        return self.run_json_script("show-relay-status.ps1", context, extra=["-AsJson"])

    def load_visibility_status(self, context: AppContext) -> dict:
        return self.run_json_script("check-target-window-visibility.ps1", context, extra=["-AsJson"])

    def load_paired_status(self, context: AppContext, run_root: str | None = None) -> tuple[dict | None, str]:
        resolved_run_root = run_root if run_root is not None else context.run_root
        return self.try_load_paired_status(context, resolved_run_root)

    def refresh_runtime_status(self, context: AppContext) -> tuple[dict, dict]:
        relay_payload = self.load_relay_status(context)
        visibility_payload = self.load_visibility_status(context)
        return relay_payload, visibility_payload

    def refresh_paired_status(self, context: AppContext, run_root: str | None = None) -> tuple[dict | None, str]:
        return self.load_paired_status(context, run_root=run_root)

    def load_dashboard_bundle(self, context: AppContext) -> DashboardRawBundle:
        effective_payload = self.load_effective_config(context)
        relay_payload = self.load_relay_status(context)
        visibility_payload = self.load_visibility_status(context)

        selected_run_root = effective_payload.get("RunContext", {}).get("SelectedRunRoot", "") or context.run_root
        paired_payload, paired_error = self.load_paired_status(context, selected_run_root)

        return DashboardRawBundle(
            effective_data=effective_payload,
            relay_status=relay_payload,
            visibility_status=visibility_payload,
            paired_status=paired_payload,
            paired_status_error=paired_error,
        )
