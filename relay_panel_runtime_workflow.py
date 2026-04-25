from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from relay_panel_models import AppContext
from relay_panel_refresh_controller import RuntimeRefreshResult
from relay_panel_services import PowerShellError


def build_reuse_failure_summary(payload: dict[str, Any]) -> str:
    summary = str(payload.get("Summary", "") or "기존 8창 재사용 실패").strip()
    reasons = payload.get("FailureReasons", []) or []
    reason_tokens = [str(item).strip() for item in reasons if str(item).strip()]
    if not reason_tokens:
        reason_tokens = [str(item).strip() for item in (payload.get("SoftFindings", []) or []) if str(item).strip()]
    if not reason_tokens:
        for row in payload.get("Targets", []) or []:
            if row.get("Matched", True):
                continue
            target_id = str(row.get("TargetId", "") or "?")
            reason = str(row.get("Reason", "") or "unknown")
            reason_tokens.append("{0}:{1}".format(target_id, reason))
    if not reason_tokens:
        return summary
    return "{0}: {1}".format(summary, ", ".join(reason_tokens[:4]))


def extract_prepared_run_root(text: str) -> str:
    match = re.search(r"prepared pair test root:\s*(.+)", text, flags=re.IGNORECASE)
    if match:
        return match.group(1).strip()
    return ""


def resolve_run_root_summary_run_root(*candidates: str) -> str:
    for candidate in candidates:
        normalized = str(candidate or "").strip()
        if normalized:
            return normalized
    return ""


@dataclass(frozen=True)
class ReuseWindowsRequest:
    context: AppContext
    config_path: str
    reuse_anchor_utc: str
    pairs_mode: bool = False


@dataclass(frozen=True)
class ReuseWindowsResult:
    reuse_payload: dict[str, Any]
    attach_output: str
    runtime_result: RuntimeRefreshResult
    reuse_anchor_utc: str
    window_reuse_mode: str
    wrapper_path: str


@dataclass(frozen=True)
class RunRootPrepareRequest:
    config_path: str
    pair_id: str
    requested_run_root: str
    summary_fallback_run_root: str


@dataclass(frozen=True)
class RunRootPrepareResult:
    output: str
    prepared_run_root: str
    summary_run_root: str
    summary_text: str


@dataclass(frozen=True)
class PrepareAllRequest:
    context: AppContext
    config_path: str
    pair_id: str
    explicit_run_root: str
    wrapper_path: str
    launch_windows_needed: bool
    attach_windows_needed: bool


@dataclass(frozen=True)
class PrepareAllResult:
    runtime_result: RuntimeRefreshResult
    run_root_result: RunRootPrepareResult
    window_launch_anchor_utc: str
    launcher_output: str
    attach_output: str
    window_launch_mode: str
    window_reuse_mode: str
    wrapper_path: str


class PanelRuntimeWorkflowService:
    def __init__(self, command_service, status_service, refresh_controller) -> None:
        self.command_service = command_service
        self.status_service = status_service
        self.refresh_controller = refresh_controller

    def run_reuse(self, request: ReuseWindowsRequest) -> ReuseWindowsResult:
        refresh_extra = ["-AsJson"]
        if request.pairs_mode:
            refresh_extra += ["-ReuseMode", "Pairs"]
        reuse_payload = self.status_service.run_json_script(
            "refresh-binding-profile-from-existing.ps1",
            request.context,
            extra=refresh_extra,
        )
        if not reuse_payload.get("Success", False):
            raise PowerShellError(
                build_reuse_failure_summary(reuse_payload),
                returncode=1,
                stdout=json.dumps(reuse_payload, ensure_ascii=False, indent=2),
                stderr="",
            )

        attach_command = self.command_service.build_script_command(
            "attach-targets-from-bindings.ps1",
            config_path=request.config_path,
        )
        attach_completed = self.command_service.run(attach_command)
        runtime_result = self.refresh_controller.refresh_runtime(request.context)
        return ReuseWindowsResult(
            reuse_payload=reuse_payload,
            attach_output=attach_completed.stdout.strip() or "binding attach 완료",
            runtime_result=runtime_result,
            reuse_anchor_utc=request.reuse_anchor_utc,
            window_reuse_mode="attach-only",
            wrapper_path="",
        )

    def load_run_root_summary_text(self, *, run_root: str, config_path: str) -> str:
        summary_run_root = str(run_root or "").strip()
        if not summary_run_root:
            return ""
        command = self.command_service.build_script_command(
            "show-paired-run-summary.ps1",
            config_path=config_path,
            run_root=summary_run_root,
        )
        try:
            completed = self.command_service.run(command)
        except Exception as exc:
            return f"[runroot 요약]\n요약 불러오기 실패: {exc}"
        output = completed.stdout.strip() or "(no output)"
        if completed.stderr.strip():
            output += "\n\nSTDERR:\n" + completed.stderr.strip()
        return "[runroot 요약]\n" + output

    def prepare_run_root(self, request: RunRootPrepareRequest) -> RunRootPrepareResult:
        command = self.command_service.build_script_command(
            "tests/Start-PairedExchangeTest.ps1",
            config_path=request.config_path,
            run_root=request.requested_run_root,
            extra=["-IncludePairId", request.pair_id],
        )
        completed = self.command_service.run(command)
        output = completed.stdout.strip() or "run root 준비 완료"
        prepared_run_root = extract_prepared_run_root(completed.stdout)
        summary_run_root = resolve_run_root_summary_run_root(
            prepared_run_root,
            request.requested_run_root,
            request.summary_fallback_run_root,
        )
        return RunRootPrepareResult(
            output=output,
            prepared_run_root=prepared_run_root,
            summary_run_root=summary_run_root,
            summary_text=self.load_run_root_summary_text(
                run_root=summary_run_root,
                config_path=request.config_path,
            ),
        )

    def run_prepare_all(self, request: PrepareAllRequest) -> PrepareAllResult:
        window_launch_anchor_utc = ""
        launcher_output = ""
        attach_output = ""

        if request.launch_windows_needed:
            if not request.wrapper_path:
                raise PowerShellError("LauncherWrapperPath를 찾지 못했습니다.")
            window_launch_anchor_utc = datetime.now(timezone.utc).isoformat()
            completed = self.command_service.run(self.command_service.build_python_command(request.wrapper_path))
            launcher_output = completed.stdout.strip() or "visible launcher 실행 완료"

        if launcher_output or request.attach_windows_needed:
            attach_command = self.command_service.build_script_command(
                "attach-targets-from-bindings.ps1",
                config_path=request.config_path,
            )
            completed = self.command_service.run(attach_command)
            attach_output = completed.stdout.strip() or "binding attach 완료"

        runtime_result = self.refresh_controller.refresh_runtime(request.context)
        run_root_result = self.prepare_run_root(
            RunRootPrepareRequest(
                config_path=request.config_path,
                pair_id=request.pair_id,
                requested_run_root=request.explicit_run_root,
                summary_fallback_run_root=request.context.run_root,
            )
        )
        return PrepareAllResult(
            runtime_result=runtime_result,
            run_root_result=run_root_result,
            window_launch_anchor_utc=window_launch_anchor_utc,
            launcher_output=launcher_output,
            attach_output=attach_output,
            window_launch_mode="wrapper" if request.launch_windows_needed and request.wrapper_path else "",
            window_reuse_mode="attach-only" if (launcher_output or request.attach_windows_needed) else "",
            wrapper_path=request.wrapper_path,
        )
