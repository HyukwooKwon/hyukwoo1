from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from copy import deepcopy
from pathlib import Path
from shutil import which
from typing import Callable

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
    "tests/Extend-TargetAutoloopCycleLimit.ps1": {"config": True, "run_root": True, "target": True},
    "tests/Request-TargetAutoloopControl.ps1": {"config": True, "run_root": True},
    "tests/Show-TargetAutoloopSeedComposer.ps1": {"config": True, "run_root": True, "target": True},
    "tests/Show-TargetAutoloopRouteMatrix.ps1": {"config": True, "run_root": True},
    "tests/Show-TargetAutoloopRouteProofDoctor.ps1": {"config": True, "run_root": True},
    "tests/Start-TargetAutoloopRun.ps1": {"config": True, "run_root": True},
    "tests/Start-TargetAutoloopWatcher.ps1": {"config": True, "run_root": True},
    "tests/Watch-TargetAutoloop.ps1": {"config": True, "run_root": True},
    "disable-pair.ps1": {"config": True, "pair": True},
    "enable-pair.ps1": {"config": True, "pair": True},
    "export-config-json.ps1": {"config": True},
    "import-paired-exchange-artifact.ps1": {"config": True, "run_root": True, "target": True},
    "tests/Invoke-PairedExchangeOneShotSubmit.ps1": {"config": True, "run_root": True, "pair": True, "target": True},
    "refresh-binding-profile-from-existing.ps1": {"config": True, "json_stdout_on_error": True},
    "router/Requeue-RetryPending.ps1": {"config": True},
    "router/Restart-RouterForConfig.ps1": {"config": True},
    "router.ps1": {"config": True},
    "show-effective-config.ps1": {"config": True, "run_root": True, "pair": True, "target": True},
    "show-paired-exchange-status.ps1": {"config": True, "run_root": True},
    "show-paired-run-summary.ps1": {"config": True, "run_root": True},
    "show-relay-status.ps1": {"config": True},
    "tests/Start-PairedExchangeTest.ps1": {"config": True, "run_root": True},
    "tests/Watch-PairedExchange.ps1": {"config": True, "run_root": True},
}
VISIBILITY_STATUS_CACHE_TTL_SECONDS = 8.0


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


def _background_process_kwargs() -> dict[str, object]:
    kwargs: dict[str, object] = {}
    create_no_window = int(getattr(subprocess, "CREATE_NO_WINDOW", 0) or 0)
    if create_no_window:
        kwargs["creationflags"] = create_no_window
    startupinfo_factory = getattr(subprocess, "STARTUPINFO", None)
    startf_use_showwindow = int(getattr(subprocess, "STARTF_USESHOWWINDOW", 0) or 0)
    sw_hide = int(getattr(subprocess, "SW_HIDE", 0) or 0)
    if os.name == "nt" and startupinfo_factory is not None and startf_use_showwindow:
        try:
            startupinfo = startupinfo_factory()
            startupinfo.dwFlags |= startf_use_showwindow
            startupinfo.wShowWindow = sw_hide
            kwargs["startupinfo"] = startupinfo
        except Exception:
            pass
    return kwargs


def _timeout_stream_text(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value or "")


def _terminate_process_tree(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
                **_background_process_kwargs(),
            )
            return
        except Exception:
            pass
    try:
        process.kill()
    except Exception:
        pass


def run_command(command: list[str], *, timeout_sec: float | None = None) -> subprocess.CompletedProcess[str]:
    timeout_value = float(timeout_sec) if timeout_sec is not None and float(timeout_sec) > 0 else None
    if timeout_value is not None:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            **_background_process_kwargs(),
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout_value)
        except subprocess.TimeoutExpired as exc:
            _terminate_process_tree(process)
            try:
                stdout, stderr = process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                stdout = _timeout_stream_text(exc.stdout)
                stderr = _timeout_stream_text(exc.stderr)
            timeout_label = f"{timeout_value:g}"
            raise PowerShellError(
                f"command timed out after {timeout_label}s: {subprocess.list2cmdline(command)}",
                returncode=None,
                stdout=_timeout_stream_text(stdout),
                stderr=_timeout_stream_text(stderr),
            ) from exc
        completed = subprocess.CompletedProcess(command, process.returncode, stdout=stdout, stderr=stderr)
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or f"exit={completed.returncode}"
            raise PowerShellError(
                detail,
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
            )
        return completed

    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=timeout_value,
            **_background_process_kwargs(),
        )
    except subprocess.TimeoutExpired as exc:
        timeout_label = f"{timeout_value:g}" if timeout_value is not None else "unknown"
        raise PowerShellError(
            f"command timed out after {timeout_label}s: {subprocess.list2cmdline(command)}",
            returncode=None,
            stdout=_timeout_stream_text(exc.stdout),
            stderr=_timeout_stream_text(exc.stderr),
        ) from exc
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

    def run(self, command: list[str], *, timeout_sec: float | None = None) -> subprocess.CompletedProcess[str]:
        return run_command(command, timeout_sec=timeout_sec)

    def run_json(
        self,
        command: list[str],
        *,
        allow_json_stdout_on_error: bool = False,
        timeout_sec: float | None = None,
    ) -> dict:
        try:
            if timeout_sec is None:
                completed = self.run(command)
            else:
                completed = self.run(command, timeout_sec=timeout_sec)
        except PowerShellError as exc:
            if allow_json_stdout_on_error:
                payload = _load_json_payload(exc.stdout)
                if payload is not None:
                    return payload
            raise
        return json.loads(completed.stdout)

    def spawn_detached(self, command: list[str]) -> None:
        self.reap_detached_processes()
        process = subprocess.Popen(command, cwd=ROOT, **_background_process_kwargs())
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
    def __init__(
        self,
        command_service: CommandService,
        *,
        visibility_cache_ttl_seconds: float = VISIBILITY_STATUS_CACHE_TTL_SECONDS,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self.command_service = command_service
        self._visibility_cache_ttl_seconds = max(0.0, float(visibility_cache_ttl_seconds))
        self._visibility_cache_clock = clock or time.monotonic
        self._visibility_cache: tuple[tuple[str, str, str, str], float, dict] | None = None

    @staticmethod
    def _visibility_cache_key(context: AppContext) -> tuple[str, str, str, str]:
        return (
            str(context.config_path or ""),
            str(context.run_root or ""),
            str(context.pair_id or ""),
            str(context.target_id or ""),
        )

    def invalidate_visibility_cache(self) -> None:
        self._visibility_cache = None

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
        timeout_sec: float | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = self.command_service.build_script_command(
            script_name=script_name,
            config_path=context.config_path,
            run_root=context.run_root if run_root_override is None else run_root_override,
            pair_id=context.pair_id if pair_id_override is None else pair_id_override,
            target_id=context.target_id if target_id_override is None else target_id_override,
            extra=extra,
        )
        if timeout_sec is None:
            return self.command_service.run(command)
        return self.command_service.run(command, timeout_sec=timeout_sec)

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
        timeout_sec: float | None = None,
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
            if timeout_sec is None:
                return self.command_service.run_json(
                    command,
                    allow_json_stdout_on_error=resolved_allow,
                )
            return self.command_service.run_json(
                command,
                allow_json_stdout_on_error=resolved_allow,
                timeout_sec=timeout_sec,
            )

        try:
            if timeout_sec is None:
                completed = self.command_service.run(command)
            else:
                completed = self.command_service.run(command, timeout_sec=timeout_sec)
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

    def load_visibility_status(self, context: AppContext, *, force_refresh: bool = False) -> dict:
        cache_key = self._visibility_cache_key(context)
        now = self._visibility_cache_clock()
        cache_entry = self._visibility_cache
        if (
            not force_refresh
            and self._visibility_cache_ttl_seconds > 0
            and cache_entry is not None
            and cache_entry[0] == cache_key
        ):
            age_seconds = now - cache_entry[1]
            if 0 <= age_seconds <= self._visibility_cache_ttl_seconds:
                return deepcopy(cache_entry[2])

        payload = self.run_json_script("check-target-window-visibility.ps1", context, extra=["-AsJson"])
        if self._visibility_cache_ttl_seconds > 0:
            self._visibility_cache = (cache_key, now, deepcopy(payload))
        return payload

    def load_paired_status(self, context: AppContext, run_root: str | None = None) -> tuple[dict | None, str]:
        resolved_run_root = run_root if run_root is not None else context.run_root
        return self.try_load_paired_status(context, resolved_run_root)

    @staticmethod
    def _run_timed_dashboard_step(steps: list[dict[str, object]], label: str, callback):
        started_at = time.monotonic()
        try:
            return callback()
        finally:
            steps.append(
                {
                    "label": str(label or "dashboard").strip() or "dashboard",
                    "elapsed_seconds": max(0.0, time.monotonic() - started_at),
                }
            )

    def refresh_runtime_status(self, context: AppContext) -> tuple[dict, dict]:
        relay_payload = self.load_relay_status(context)
        visibility_payload = self.load_visibility_status(context)
        return relay_payload, visibility_payload

    def refresh_paired_status(self, context: AppContext, run_root: str | None = None) -> tuple[dict | None, str]:
        return self.load_paired_status(context, run_root=run_root)

    def load_dashboard_bundle(self, context: AppContext) -> DashboardRawBundle:
        steps: list[dict[str, object]] = []
        effective_payload = self._run_timed_dashboard_step(
            steps,
            "effective config",
            lambda: self.load_effective_config(context),
        )
        relay_payload = self._run_timed_dashboard_step(
            steps,
            "relay status",
            lambda: self.load_relay_status(context),
        )
        visibility_payload = self._run_timed_dashboard_step(
            steps,
            "visibility",
            lambda: self.load_visibility_status(context),
        )

        selected_run_root = effective_payload.get("RunContext", {}).get("SelectedRunRoot", "") or context.run_root
        paired_payload, paired_error = self._run_timed_dashboard_step(
            steps,
            "paired status",
            lambda: self.load_paired_status(context, selected_run_root),
        )

        return DashboardRawBundle(
            effective_data=effective_payload,
            relay_status=relay_payload,
            visibility_status=visibility_payload,
            paired_status=paired_payload,
            paired_status_error=paired_error,
            refresh_timing_steps=steps,
        )
