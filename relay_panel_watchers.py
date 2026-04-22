from __future__ import annotations

import json
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable

from relay_panel_contract import WATCHER_BRIDGE_REQUIRED_FIELDS
from relay_panel_services import CommandService


DEFAULT_WATCHER_MAX_FORWARD_COUNT = 2
DEFAULT_WATCHER_RUN_DURATION_SEC = 900
WATCHER_CONTROL_FILE_NAME = "watcher-control.json"
WATCHER_STATUS_FILE_NAME = "watcher-status.json"
PENDING_STOP_STALE_AFTER_SEC = 15.0
STATUS_STALE_AFTER_SEC = 20.0


@dataclass(frozen=True)
class WatcherStartRequest:
    config_path: str
    run_root: str
    use_headless_dispatch: bool = True
    max_forward_count: int = DEFAULT_WATCHER_MAX_FORWARD_COUNT
    run_duration_sec: int = DEFAULT_WATCHER_RUN_DURATION_SEC


@dataclass(frozen=True)
class WatcherRuntimeStatus:
    run_root: str
    state: str
    mutex_name: str = ""
    last_checked_at: str = ""
    status_updated_at: str = ""
    heartbeat_at: str = ""
    heartbeat_age_seconds: float | None = None
    status_sequence: int = 0
    process_started_at: str = ""
    status_reason: str = ""
    stop_category: str = ""
    status_request_id: str = ""
    status_action: str = ""
    last_handled_request_id: str = ""
    last_handled_action: str = ""
    last_handled_result: str = ""
    last_handled_at: str = ""
    control_exists: bool = False
    control_pending_action: str = ""
    control_pending_request_id: str = ""
    control_requested_at: str = ""
    control_last_write_at: str = ""
    control_age_seconds: float | None = None
    control_parse_error: str = ""
    control_path: str = ""
    status_exists: bool = False
    status_parse_error: str = ""
    status_last_write_at: str = ""
    status_age_seconds: float | None = None
    status_path: str = ""
    reason_codes: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class WatcherStopEligibility:
    allowed: bool
    run_root: str
    state: str
    reason_codes: list[str] = field(default_factory=list)
    warning_codes: list[str] = field(default_factory=list)
    message: str = ""


@dataclass(frozen=True)
class WatcherStartEligibility:
    allowed: bool
    run_root: str
    state: str
    reason_codes: list[str] = field(default_factory=list)
    warning_codes: list[str] = field(default_factory=list)
    message: str = ""
    cleanup_allowed: bool = False
    recommended_action: str = ""


@dataclass(frozen=True)
class WatcherControlResult:
    ok: bool
    action: str
    run_root: str
    state: str
    message: str
    request_id: str = ""
    command_text: str = ""
    reason_codes: list[str] = field(default_factory=list)
    warning_codes: list[str] = field(default_factory=list)


StatusLoader = Callable[[str], tuple[dict | None, str]]


class WatcherService:
    def _now(self) -> str:
        return datetime.now().isoformat(timespec="seconds")

    def state_root(self, run_root: str) -> Path:
        return Path(run_root) / ".state"

    def control_path(self, run_root: str) -> Path:
        return self.state_root(run_root) / WATCHER_CONTROL_FILE_NAME

    def status_path(self, run_root: str) -> Path:
        return self.state_root(run_root) / WATCHER_STATUS_FILE_NAME

    def _parse_float(self, value: object) -> float | None:
        if value in (None, ""):
            return None
        try:
            return float(value)
        except Exception:
            return None

    @staticmethod
    def _summarize_error(value: str, *, max_length: int = 160) -> str:
        text = str(value or "").strip()
        if not text:
            return ""
        if len(text) <= max_length:
            return text
        return text[: max_length - 3] + "..."

    def _unreadable_file_hints(self, status: WatcherRuntimeStatus) -> list[str]:
        hints: list[str] = []
        if "status_file_unreadable" in status.reason_codes:
            detail = "watch status={0}".format(status.status_path or self.status_path(status.run_root))
            if status.status_parse_error:
                detail += " ({0})".format(self._summarize_error(status.status_parse_error))
            hints.append(detail)
        if "control_file_unreadable" in status.reason_codes:
            detail = "watch control={0}".format(status.control_path or self.control_path(status.run_root))
            if status.control_parse_error:
                detail += " ({0})".format(self._summarize_error(status.control_parse_error))
            hints.append(detail)
        return hints

    def _unreadable_files_message(self, status: WatcherRuntimeStatus, prefix: str) -> str:
        hints = self._unreadable_file_hints(status)
        if not hints:
            return prefix
        return "{0} {1}".format(prefix, " / ".join(hints))

    def get_runtime_status(self, paired_status: dict | None, run_root: str) -> WatcherRuntimeStatus:
        watcher = ((paired_status or {}).get("Watcher", {}) or {})
        state = str(watcher.get("Status", "stopped") or "stopped")
        allowed_states = {"running", "stopped", "starting", "stop_requested", "stopping"}
        reason_codes: list[str] = []
        control_path = str(watcher.get("ControlPath", "") or self.control_path(run_root))
        control_exists = Path(control_path).exists() if control_path else False
        control_pending_action = str(watcher.get("ControlPendingAction", "") or "")
        control_parse_error = str(watcher.get("ControlParseError", "") or "")
        status_parse_error = str(watcher.get("StatusParseError", "") or "")
        control_age_seconds = self._parse_float(watcher.get("ControlAgeSeconds"))
        status_age_seconds = self._parse_float(watcher.get("StatusAgeSeconds"))
        heartbeat_age_seconds = self._parse_float(watcher.get("HeartbeatAgeSeconds"))
        freshness_age_seconds = heartbeat_age_seconds
        if freshness_age_seconds is None:
            freshness_age_seconds = status_age_seconds
        if not run_root:
            state = "unknown"
            reason_codes.append("runroot_missing")
        if paired_status is None:
            reason_codes.append("paired_status_missing")
        if state not in allowed_states:
            state = "unknown"
            reason_codes.append("watcher_unknown")
        if state == "running" and control_pending_action == "stop":
            state = "stop_requested"
        if control_parse_error:
            reason_codes.append("control_file_unreadable")
        if status_parse_error:
            reason_codes.append("status_file_unreadable")
        if control_pending_action == "stop" and control_age_seconds is not None and control_age_seconds >= PENDING_STOP_STALE_AFTER_SEC:
            reason_codes.append("stop_requested_timeout")
        if freshness_age_seconds is not None and state in {"running", "stop_requested", "stopping", "starting"} and freshness_age_seconds >= STATUS_STALE_AFTER_SEC:
            reason_codes.append("status_file_stale")
        if state == "stopped" and control_exists and not control_pending_action:
            reason_codes.append("stale_control_file")
        return WatcherRuntimeStatus(
            run_root=run_root,
            state=state,
            mutex_name=str(watcher.get("MutexName", "") or ""),
            last_checked_at=self._now(),
            status_updated_at=str(watcher.get("StatusFileUpdatedAt", "") or ""),
            heartbeat_at=str(watcher.get("HeartbeatAt", "") or ""),
            heartbeat_age_seconds=heartbeat_age_seconds,
            status_sequence=int(watcher.get("StatusSequence", 0) or 0),
            process_started_at=str(watcher.get("ProcessStartedAt", "") or ""),
            status_reason=str(watcher.get("StatusReason", "") or ""),
            stop_category=str(watcher.get("StopCategory", "") or ""),
            status_request_id=str(watcher.get("StatusRequestId", "") or ""),
            status_action=str(watcher.get("StatusAction", "") or ""),
            last_handled_request_id=str(watcher.get("LastHandledRequestId", "") or ""),
            last_handled_action=str(watcher.get("LastHandledAction", "") or ""),
            last_handled_result=str(watcher.get("LastHandledResult", "") or ""),
            last_handled_at=str(watcher.get("LastHandledAt", "") or ""),
            control_exists=control_exists,
            control_pending_action=control_pending_action,
            control_pending_request_id=str(watcher.get("ControlPendingRequestId", "") or ""),
            control_requested_at=str(watcher.get("ControlRequestedAt", "") or ""),
            control_last_write_at=str(watcher.get("ControlLastWriteAt", "") or ""),
            control_age_seconds=control_age_seconds,
            control_parse_error=control_parse_error,
            control_path=control_path,
            status_exists=bool(watcher.get("StatusExists", False)),
            status_parse_error=status_parse_error,
            status_last_write_at=str(watcher.get("StatusLastWriteAt", "") or ""),
            status_age_seconds=status_age_seconds,
            status_path=str(watcher.get("StatusPath", "") or self.status_path(run_root)),
            reason_codes=reason_codes,
        )

    def get_start_eligibility(self, paired_status: dict | None, run_root: str) -> WatcherStartEligibility:
        status = self.get_runtime_status(paired_status, run_root)
        blocking_codes: list[str] = []
        recommended_action = ""
        cleanup_allowed = False

        if not run_root:
            blocking_codes.append("runroot_missing")
            recommended_action = "run 준비"
        if status.state == "unknown":
            blocking_codes.extend(code for code in status.reason_codes if code not in blocking_codes)
            if not recommended_action:
                recommended_action = "빠른 새로고침"
        if "paired_status_missing" in status.reason_codes and "paired_status_missing" not in blocking_codes:
            blocking_codes.append("paired_status_missing")
            recommended_action = recommended_action or "빠른 새로고침"
        if status.state == "running":
            blocking_codes.append("watcher_already_running")
            recommended_action = recommended_action or "watch 상태 새로고침"
        if status.state in {"starting", "stop_requested", "stopping"}:
            blocking_codes.append("control_pending_action_exists")
            recommended_action = recommended_action or "watch 진단"

        for code in (
            "control_file_unreadable",
            "status_file_unreadable",
            "status_file_stale",
            "stop_requested_timeout",
            "stale_control_file",
        ):
            if code in status.reason_codes and code not in blocking_codes:
                blocking_codes.append(code)

        if status.control_pending_action and "control_pending_action_exists" not in blocking_codes:
            blocking_codes.append("control_pending_action_exists")
            recommended_action = recommended_action or "watch 진단"

        if status.state == "stopped" and any(code in {"stale_control_file", "stop_requested_timeout"} for code in blocking_codes):
            cleanup_allowed = True
            recommended_action = "watch stale 정리"
        elif "status_file_unreadable" in blocking_codes and "control_file_unreadable" in blocking_codes:
            recommended_action = recommended_action or "watch control/status 파일 확인"
        elif "status_file_unreadable" in blocking_codes:
            recommended_action = recommended_action or "watch status 파일 확인"
        elif "control_file_unreadable" in blocking_codes:
            recommended_action = recommended_action or "watch control 파일 확인"
        elif "status_file_stale" in blocking_codes:
            recommended_action = recommended_action or "빠른 새로고침"

        if blocking_codes:
            if cleanup_allowed:
                message = "오래된 watcher stop/control 흔적이 있어 자동 시작을 막았습니다. 안전 정리 후 다시 시작해야 합니다."
            elif "watcher_already_running" in blocking_codes:
                message = "현재 RunRoot 기준 watcher가 이미 실행 중입니다."
            elif "control_file_unreadable" in blocking_codes or "status_file_unreadable" in blocking_codes:
                message = self._unreadable_files_message(
                    status,
                    "watch control/status 파일을 읽지 못해 자동 시작을 막았습니다.",
                )
            elif "status_file_stale" in blocking_codes:
                message = "watch 상태 파일이 오래돼 현재 상태를 신뢰할 수 없어 자동 시작을 막았습니다."
            else:
                message = "현재 watcher 시작 조건을 만족하지 않아 자동 시작을 막았습니다."
            return WatcherStartEligibility(
                allowed=False,
                run_root=run_root,
                state=status.state,
                reason_codes=blocking_codes,
                message=message,
                cleanup_allowed=cleanup_allowed,
                recommended_action=recommended_action,
            )

        return WatcherStartEligibility(
            allowed=True,
            run_root=run_root,
            state=status.state,
            message="현재 watch 시작을 요청할 수 있습니다.",
            recommended_action="watch 시작",
        )

    def get_stop_eligibility(self, paired_status: dict | None, run_root: str) -> WatcherStopEligibility:
        status = self.get_runtime_status(paired_status, run_root)
        if status.state == "unknown":
            return WatcherStopEligibility(
                allowed=False,
                run_root=run_root,
                state=status.state,
                reason_codes=list(status.reason_codes) or ["watcher_unknown"],
                message="현재 상태가 불명확하여 watch 제어를 막았습니다.",
            )
        blocking_reason_codes = {
            "stale_control_file",
            "control_file_unreadable",
            "status_file_unreadable",
            "stop_requested_timeout",
            "status_file_stale",
        }
        if any(code in status.reason_codes for code in blocking_reason_codes):
            return WatcherStopEligibility(
                allowed=False,
                run_root=run_root,
                state=status.state,
                reason_codes=[code for code in status.reason_codes if code in blocking_reason_codes],
                message=(
                    self._unreadable_files_message(
                        status,
                        "stale/unreadable watcher control 또는 status 상태가 있어 watch 제어를 막았습니다.",
                    )
                    if any(code in status.reason_codes for code in {"control_file_unreadable", "status_file_unreadable"})
                    else "stale/unreadable watcher control 또는 status 상태가 있어 watch 제어를 막았습니다."
                ),
            )
        if status.state in {"stop_requested", "stopping", "starting"}:
            return WatcherStopEligibility(
                allowed=False,
                run_root=run_root,
                state=status.state,
                reason_codes=["control_already_in_progress"],
                message="현재 watch 제어가 이미 진행 중입니다.",
            )
        if status.state != "running":
            return WatcherStopEligibility(
                allowed=False,
                run_root=run_root,
                state=status.state,
                reason_codes=["watcher_not_running"],
                message="현재 RunRoot 기준 watcher가 실행 중이 아닙니다.",
            )

        counts = ((paired_status or {}).get("Counts", {}) or {})
        handoff_ready_count = int(counts.get("HandoffReadyCount", counts.get("ReadyToForwardCount", 0)) or 0)
        if handoff_ready_count > 0:
            return WatcherStopEligibility(
                allowed=False,
                run_root=run_root,
                state=status.state,
                reason_codes=["pending_forward_exists"],
                message="다음 전달 가능 대상이 남아 있어 watch 정지를 차단합니다.",
            )
        warning_codes: list[str] = []
        if int(counts.get("FailureLineCount", 0) or 0) > 0:
            warning_codes.append("recent_failure_present")
        if int(counts.get("NoZipCount", 0) or 0) > 0:
            warning_codes.append("incomplete_artifacts_present")
        message = "현재 watch 정지를 요청할 수 있습니다."
        if warning_codes:
            message = "watch 정지 전 확인이 필요한 상태가 있습니다."
        return WatcherStopEligibility(
            allowed=True,
            run_root=run_root,
            state=status.state,
            warning_codes=warning_codes,
            message=message,
        )

    def request_stop(
        self,
        paired_status: dict | None,
        run_root: str,
        *,
        requested_by: str = "relay_operator_panel",
    ) -> WatcherControlResult:
        eligibility = self.get_stop_eligibility(paired_status, run_root)
        if not eligibility.allowed:
            return WatcherControlResult(
                ok=False,
                action="stop",
                run_root=run_root,
                state=eligibility.state,
                message=eligibility.message,
                reason_codes=list(eligibility.reason_codes),
                warning_codes=list(eligibility.warning_codes),
            )

        status = self.get_runtime_status(paired_status, run_root)
        if status.control_pending_action == "stop" or status.state in {"stop_requested", "stopping"}:
            return WatcherControlResult(
                ok=True,
                action="stop",
                run_root=run_root,
                state=status.state,
                message="이미 watch 정지 요청이 진행 중입니다.",
                request_id=status.control_pending_request_id,
                warning_codes=list(eligibility.warning_codes),
            )

        control_path = self.control_path(run_root)
        if control_path.exists():
            try:
                existing = json.loads(control_path.read_text(encoding="utf-8"))
            except Exception:
                existing = {}
            if str(existing.get("Action", "") or "") == "stop":
                existing_age = status.control_age_seconds
                if status.state == "stopped":
                    return WatcherControlResult(
                        ok=False,
                        action="stop",
                        run_root=run_root,
                        state="stale_control_artifact",
                        message="watcher는 stopped인데 stop control file이 남아 있습니다. stale control artifact를 먼저 정리해야 합니다.",
                        request_id=str(existing.get("RequestId", "") or ""),
                        reason_codes=["stale_control_file"],
                    )
                if existing_age is not None and existing_age >= PENDING_STOP_STALE_AFTER_SEC:
                    return WatcherControlResult(
                        ok=False,
                        action="stop",
                        run_root=run_root,
                        state="stale_pending_stop",
                        message="오래된 stop 요청이 남아 있어 새 정지 요청을 막았습니다. stale pending stop을 먼저 정리해야 합니다.",
                        request_id=str(existing.get("RequestId", "") or ""),
                        reason_codes=["stop_requested_timeout"],
                    )
                return WatcherControlResult(
                    ok=True,
                    action="stop",
                    run_root=run_root,
                    state="stop_requested",
                    message="이미 watch 정지 요청 파일이 존재합니다.",
                    request_id=str(existing.get("RequestId", "") or ""),
                    warning_codes=list(eligibility.warning_codes),
                )

        request_id = str(uuid.uuid4())
        payload = {
            "SchemaVersion": "1.0.0",
            "RequestedAt": self._now(),
            "RequestedBy": requested_by,
            "Action": "stop",
            "RunRoot": run_root,
            "RequestId": request_id,
        }
        state_root = self.state_root(run_root)
        state_root.mkdir(parents=True, exist_ok=True)
        control_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        return WatcherControlResult(
            ok=True,
            action="stop",
            run_root=run_root,
            state="stop_requested",
            message="watch 정지 요청 파일을 기록했습니다. 상태가 stopped로 바뀌는지 확인이 필요합니다.",
            request_id=request_id,
            reason_codes=["stop_requested"],
            warning_codes=list(eligibility.warning_codes),
        )

    def clear_stale_control_file(self, run_root: str, paired_status: dict | None) -> WatcherControlResult:
        status = self.get_runtime_status(paired_status, run_root)
        control_path = self.control_path(run_root)
        if not control_path.exists():
            return WatcherControlResult(
                ok=True,
                action="clear_stale_control",
                run_root=run_root,
                state=status.state,
                message="정리할 stale control file이 없습니다.",
            )
        if status.state != "stopped":
            return WatcherControlResult(
                ok=False,
                action="clear_stale_control",
                run_root=run_root,
                state=status.state,
                message="watcher가 stopped 상태가 아니라 stale control file을 정리할 수 없습니다.",
                reason_codes=["watcher_not_stopped"],
            )
        control_path.unlink(missing_ok=True)
        return WatcherControlResult(
            ok=True,
            action="clear_stale_control",
            run_root=run_root,
            state="stopped",
            message="stale control file을 정리했습니다.",
        )

    def recover_stale_start_blockers(self, run_root: str, paired_status: dict | None) -> WatcherControlResult:
        eligibility = self.get_start_eligibility(paired_status, run_root)
        if not eligibility.cleanup_allowed:
            return WatcherControlResult(
                ok=False,
                action="recover_start_blockers",
                run_root=run_root,
                state=eligibility.state,
                message="현재 상태에서는 안전하게 정리할 stale watcher control이 없습니다.",
                reason_codes=list(eligibility.reason_codes) or ["no_safe_cleanup"],
            )
        return self.clear_stale_control_file(run_root, paired_status)

    def build_start_command(
        self,
        command_service: CommandService,
        request: WatcherStartRequest,
    ) -> list[str]:
        extra: list[str] = []
        if request.use_headless_dispatch:
            extra.append("-UseHeadlessDispatch")
        if request.max_forward_count > 0:
            extra += ["-MaxForwardCount", str(request.max_forward_count)]
        if request.run_duration_sec > 0:
            extra += ["-RunDurationSec", str(request.run_duration_sec)]
        return command_service.build_script_command(
            "tests/Watch-PairedExchange.ps1",
            config_path=request.config_path,
            run_root=request.run_root,
            extra=extra,
        )

    def start_detached(
        self,
        command_service: CommandService,
        request: WatcherStartRequest,
    ) -> WatcherControlResult:
        if not request.run_root:
            return WatcherControlResult(
                ok=False,
                action="start",
                run_root=request.run_root,
                state="unknown",
                message="RunRoot가 비어 있어 watch를 시작할 수 없습니다.",
                reason_codes=["runroot_missing"],
            )
        command = self.build_start_command(command_service, request)
        command_service.spawn_detached(command)
        return WatcherControlResult(
            ok=True,
            action="start",
            run_root=request.run_root,
            state="starting",
            message="watch 시작 명령을 별도 프로세스로 요청했습니다.",
            command_text=" ".join(command),
            warning_codes=["verify_running_required"],
        )

    def wait_for_stopped(
        self,
        status_loader: StatusLoader,
        run_root: str,
        *,
        request_id: str = "",
        timeout_sec: float = 20.0,
        poll_interval_sec: float = 1.0,
    ) -> WatcherControlResult:
        deadline = time.monotonic() + timeout_sec
        last_error = ""
        last_status = WatcherRuntimeStatus(run_root=run_root, state="unknown")
        while time.monotonic() <= deadline:
            paired_status, error = status_loader(run_root)
            last_error = error or last_error
            last_status = self.get_runtime_status(paired_status, run_root)
            ack_ok = (not request_id) or (
                last_status.last_handled_request_id == request_id
                and last_status.last_handled_action == "stop"
                and last_status.last_handled_result == "stopped"
            )
            control_cleared = not last_status.control_exists and not last_status.control_pending_action
            if last_status.state == "stopped" and control_cleared and ack_ok:
                return WatcherControlResult(
                    ok=True,
                    action="wait_for_stopped",
                    run_root=run_root,
                    state="stopped",
                    message="watch 중지와 request ack를 확인했습니다.",
                    request_id=request_id,
                )
            time.sleep(max(0.0, poll_interval_sec))
        reason_codes = ["stop_timeout"]
        if last_error:
            reason_codes.append("paired_status_error")
        if request_id and last_status.last_handled_request_id != request_id:
            reason_codes.append("request_ack_missing")
        if last_status.control_exists or last_status.control_pending_action:
            reason_codes.append("control_not_cleared")
        return WatcherControlResult(
            ok=False,
            action="wait_for_stopped",
            run_root=run_root,
            state=last_status.state,
            message="watch stopped + control cleared + request ack 상태를 제한 시간 안에 확인하지 못했습니다.",
            request_id=request_id,
            reason_codes=reason_codes,
        )

    def wait_for_running(
        self,
        status_loader: StatusLoader,
        run_root: str,
        *,
        previous_request_id: str = "",
        timeout_sec: float = 15.0,
        poll_interval_sec: float = 1.0,
    ) -> WatcherControlResult:
        deadline = time.monotonic() + timeout_sec
        last_error = ""
        last_status = WatcherRuntimeStatus(run_root=run_root, state="unknown")
        while time.monotonic() <= deadline:
            paired_status, error = status_loader(run_root)
            last_error = error or last_error
            last_status = self.get_runtime_status(paired_status, run_root)
            ack_stable = (not previous_request_id) or (
                last_status.last_handled_request_id == previous_request_id
                and last_status.last_handled_action == "stop"
                and last_status.last_handled_result == "stopped"
            )
            control_cleared = not last_status.control_exists and not last_status.control_pending_action
            if last_status.state == "running" and control_cleared and ack_stable:
                return WatcherControlResult(
                    ok=True,
                    action="wait_for_running",
                    run_root=run_root,
                    state="running",
                    message="watch 실행 상태를 확인했습니다.",
                    request_id=previous_request_id,
                )
            time.sleep(max(0.0, poll_interval_sec))
        reason_codes = ["start_timeout"]
        if last_error:
            reason_codes.append("paired_status_error")
        if last_status.control_exists or last_status.control_pending_action:
            reason_codes.append("control_not_cleared")
        if previous_request_id and last_status.last_handled_request_id != previous_request_id:
            reason_codes.append("request_ack_unstable")
        return WatcherControlResult(
            ok=False,
            action="wait_for_running",
            run_root=run_root,
            state=last_status.state,
            message="watch running + control cleared 상태를 제한 시간 안에 확인하지 못했습니다.",
            request_id=previous_request_id,
            reason_codes=reason_codes,
        )

    def restart(
        self,
        command_service: CommandService,
        status_loader: StatusLoader,
        paired_status: dict | None,
        request: WatcherStartRequest,
        *,
        requested_by: str = "relay_operator_panel",
        stop_timeout_sec: float = 20.0,
        running_timeout_sec: float = 15.0,
        poll_interval_sec: float = 1.0,
    ) -> WatcherControlResult:
        stop_result = self.request_stop(paired_status, request.run_root, requested_by=requested_by)
        if not stop_result.ok:
            return WatcherControlResult(
                ok=False,
                action="restart",
                run_root=request.run_root,
                state=stop_result.state,
                message=stop_result.message,
                request_id=stop_result.request_id,
                reason_codes=list(stop_result.reason_codes),
                warning_codes=list(stop_result.warning_codes),
            )

        stopped_result = self.wait_for_stopped(
            status_loader,
            request.run_root,
            request_id=stop_result.request_id,
            timeout_sec=stop_timeout_sec,
            poll_interval_sec=poll_interval_sec,
        )
        if not stopped_result.ok:
            return WatcherControlResult(
                ok=False,
                action="restart",
                run_root=request.run_root,
                state=stopped_result.state,
                message=stopped_result.message,
                request_id=stop_result.request_id,
                reason_codes=list(stopped_result.reason_codes),
                warning_codes=list(stop_result.warning_codes),
            )

        start_result = self.start_detached(command_service, request)
        if not start_result.ok:
            return WatcherControlResult(
                ok=False,
                action="restart",
                run_root=request.run_root,
                state=start_result.state,
                message=start_result.message,
                command_text=start_result.command_text,
                reason_codes=list(start_result.reason_codes),
                warning_codes=list(stop_result.warning_codes) + list(start_result.warning_codes),
            )

        running_result = self.wait_for_running(
            status_loader,
            request.run_root,
            previous_request_id=stop_result.request_id,
            timeout_sec=running_timeout_sec,
            poll_interval_sec=poll_interval_sec,
        )
        if not running_result.ok:
            return WatcherControlResult(
                ok=False,
                action="restart",
                run_root=request.run_root,
                state=running_result.state,
                message=running_result.message,
                command_text=start_result.command_text,
                reason_codes=list(running_result.reason_codes),
                warning_codes=list(stop_result.warning_codes) + list(start_result.warning_codes),
            )

        return WatcherControlResult(
            ok=True,
            action="restart",
            run_root=request.run_root,
            state="running",
            message="watch 재시작이 확인됐습니다.",
            request_id=stop_result.request_id,
            command_text=start_result.command_text,
            warning_codes=list(stop_result.warning_codes) + list(start_result.warning_codes),
        )

    def get_status(self, paired_status: dict | None, run_root: str = "") -> str:
        return self.get_runtime_status(paired_status, run_root=run_root).state
