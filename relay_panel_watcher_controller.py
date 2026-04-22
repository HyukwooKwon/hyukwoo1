from __future__ import annotations

from dataclasses import dataclass

from relay_panel_audit import WatcherAuditLogger
from relay_panel_services import CommandService
from relay_panel_watchers import (
    DEFAULT_WATCHER_MAX_FORWARD_COUNT,
    DEFAULT_WATCHER_RUN_DURATION_SEC,
    StatusLoader,
    WatcherControlResult,
    WatcherStartEligibility,
    WatcherService,
    WatcherStartRequest,
)


@dataclass(frozen=True)
class WatcherDiagnostics:
    hint: str
    details: str


@dataclass(frozen=True)
class WatcherRecommendation:
    action_key: str
    label: str
    detail: str = ""


class WatcherController:
    def __init__(self, watcher_service: WatcherService, audit_logger: WatcherAuditLogger | None = None) -> None:
        self.watcher_service = watcher_service
        self.audit_logger = audit_logger or WatcherAuditLogger()

    def start_preset_note(self) -> str:
        forward_limit = (
            "forward 제한 없음"
            if DEFAULT_WATCHER_MAX_FORWARD_COUNT <= 0
            else f"forward {DEFAULT_WATCHER_MAX_FORWARD_COUNT}회"
        )
        run_duration = (
            "run 제한 없음"
            if DEFAULT_WATCHER_RUN_DURATION_SEC <= 0
            else f"run {DEFAULT_WATCHER_RUN_DURATION_SEC}초"
        )
        return f"기본 watch 시작 preset: {forward_limit} / {run_duration}"

    def continuous_watch_guidance(self) -> str:
        if DEFAULT_WATCHER_MAX_FORWARD_COUNT <= 0:
            return "현재 기본 watch 시작에는 forward 횟수 제한이 없습니다."
        return (
            f"기본 watch 시작은 {DEFAULT_WATCHER_MAX_FORWARD_COUNT}회 forward 후 멈춥니다. "
            "계속 왕복이 필요하면 MaxForwardCount를 0 또는 더 큰 값으로 별도 실행하세요."
        )

    def _record_audit(
        self,
        *,
        action: str,
        result: WatcherControlResult,
        requested_by: str = "relay_operator_panel",
        extra: dict | None = None,
    ) -> None:
        self.audit_logger.record(
            action=action,
            run_root=result.run_root,
            requested_by=requested_by,
            ok=result.ok,
            state=result.state,
            message=result.message,
            request_id=result.request_id,
            reason_codes=list(result.reason_codes),
            warning_codes=list(result.warning_codes),
            extra=extra,
        )

    def runtime_status(self, paired_status: dict | None, run_root: str):
        return self.watcher_service.get_runtime_status(paired_status, run_root)

    @staticmethod
    def _is_expected_limit_stop(status) -> bool:
        return status.status_reason == "max-forward-count-reached" or status.stop_category == "expected-limit"

    def audit_log_path(self) -> str:
        return str(self.audit_logger.log_path)

    def stop_eligibility(self, paired_status: dict | None, run_root: str):
        return self.watcher_service.get_stop_eligibility(paired_status, run_root)

    def start_eligibility(self, paired_status: dict | None, run_root: str) -> WatcherStartEligibility:
        return self.watcher_service.get_start_eligibility(paired_status, run_root)

    def runtime_hint(self, paired_status: dict | None, run_root: str) -> str:
        status = self.runtime_status(paired_status, run_root)
        parts = [f"watch={status.state}"]
        if status.status_reason:
            parts.append("reason=" + status.status_reason)
        elif status.stop_category:
            parts.append("reason=" + status.stop_category)
        if status.stop_category:
            parts.append("stopCategory=" + status.stop_category)
        if self._is_expected_limit_stop(status) and DEFAULT_WATCHER_MAX_FORWARD_COUNT > 0:
            parts.append("forward_limit=" + str(DEFAULT_WATCHER_MAX_FORWARD_COUNT))
        if status.status_reason == "run-duration-reached" and DEFAULT_WATCHER_RUN_DURATION_SEC > 0:
            parts.append("run_limit_sec=" + str(DEFAULT_WATCHER_RUN_DURATION_SEC))
        if status.status_sequence:
            parts.append("seq=" + str(status.status_sequence))
        if status.control_pending_action:
            parts.append("control=" + status.control_pending_action)
        if status.last_handled_request_id:
            parts.append("ack=" + status.last_handled_request_id)
        if status.reason_codes:
            parts.append("reasons=" + ",".join(status.reason_codes))
        return " / ".join(parts)

    def recommended_action(self, paired_status: dict | None, run_root: str) -> WatcherRecommendation | None:
        status = self.runtime_status(paired_status, run_root)
        start_eligibility = self.start_eligibility(paired_status, run_root)
        stop_eligibility = self.stop_eligibility(paired_status, run_root)

        if self._is_expected_limit_stop(status):
            return WatcherRecommendation("start_watcher", "watch 다시 시작", self.continuous_watch_guidance())
        if status.status_reason == "run-duration-reached":
            return WatcherRecommendation(
                "start_watcher",
                "watch 다시 시작",
                (
                    f"기본 watch 시작은 run {DEFAULT_WATCHER_RUN_DURATION_SEC}초 후 멈춥니다. "
                    "더 오래 돌리려면 RunDurationSec 값을 늘려 실행하세요."
                ),
            )
        if start_eligibility.cleanup_allowed:
            return WatcherRecommendation("recover_stale_watcher", "watch stale 정리", start_eligibility.message)
        if "control_file_unreadable" in status.reason_codes:
            return WatcherRecommendation("open_watcher_control", "watch control 파일", "control file 원문을 먼저 확인하세요.")
        if "status_file_unreadable" in status.reason_codes:
            return WatcherRecommendation("open_watcher_status", "watch status 파일", "status file 원문을 먼저 확인하세요.")
        if "status_file_stale" in status.reason_codes or "paired_status_missing" in status.reason_codes or "watcher_unknown" in status.reason_codes:
            return WatcherRecommendation("refresh_quick", "빠른 새로고침", "watch 상태 freshness를 먼저 다시 확인하세요.")
        if "pending_forward_exists" in stop_eligibility.reason_codes:
            return WatcherRecommendation("focus_ready_to_forward_artifact", "전달 가능 target 보기", "결과 탭에서 다음 전달 가능 target을 먼저 확인하세요.")
        if start_eligibility.allowed and status.state == "stopped":
            return WatcherRecommendation("start_watcher", "watch 시작", "현재 watcher 시작 조건을 만족합니다.")
        if status.state in {"running", "starting", "stop_requested", "stopping"}:
            return WatcherRecommendation("run_paired_status", "Pair 상태 보기", "paired status를 다시 확인해 최신 상태를 보세요.")
        return None

    def diagnostics(self, paired_status: dict | None, run_root: str) -> WatcherDiagnostics:
        status = self.runtime_status(paired_status, run_root)
        start_eligibility = self.start_eligibility(paired_status, run_root)
        eligibility = self.stop_eligibility(paired_status, run_root)
        recommendation = self.recommended_action(paired_status, run_root)
        counts = ((paired_status or {}).get("Counts", {}) or {})
        lines = [
            "watch 진단",
            f"RunRoot: {run_root or '(없음)'}",
            f"상태: {status.state}",
            f"Mutex: {status.mutex_name or '(없음)'}",
            f"StatusPath: {status.status_path or '(없음)'}",
            f"ControlPath: {status.control_path or '(없음)'}",
            f"StatusUpdatedAt: {status.status_updated_at or '(없음)'}",
            f"StatusAgeSeconds: {status.status_age_seconds if status.status_age_seconds is not None else '(없음)'}",
            f"HeartbeatAt: {status.heartbeat_at or '(없음)'}",
            f"HeartbeatAgeSeconds: {status.heartbeat_age_seconds if status.heartbeat_age_seconds is not None else '(없음)'}",
            f"StatusSequence: {status.status_sequence if status.status_sequence else '(없음)'}",
            f"ProcessStartedAt: {status.process_started_at or '(없음)'}",
            f"StatusReason: {status.status_reason or '(없음)'}",
            f"StopCategory: {status.stop_category or '(없음)'}",
            f"StatusParseError: {status.status_parse_error or '(없음)'}",
            f"ControlRequestedAt: {status.control_requested_at or '(없음)'}",
            f"ControlAgeSeconds: {status.control_age_seconds if status.control_age_seconds is not None else '(없음)'}",
            f"ControlPendingAction: {status.control_pending_action or '(없음)'}",
            f"ControlParseError: {status.control_parse_error or '(없음)'}",
            f"LastHandledRequestId: {status.last_handled_request_id or '(없음)'}",
            f"LastHandledAction: {status.last_handled_action or '(없음)'}",
            f"LastHandledResult: {status.last_handled_result or '(없음)'}",
            f"LastHandledAt: {status.last_handled_at or '(없음)'}",
            f"AuditLogPath: {self.audit_log_path()}",
            f"StartPresetMaxForwardCount: {DEFAULT_WATCHER_MAX_FORWARD_COUNT}",
            f"StartPresetRunDurationSec: {DEFAULT_WATCHER_RUN_DURATION_SEC}",
            f"StartPresetNote: {self.start_preset_note()}",
            f"StartAllowed: {'예' if start_eligibility.allowed else '아니오'}",
            f"StartMessage: {start_eligibility.message or '(없음)'}",
            f"StartCleanupAllowed: {'예' if start_eligibility.cleanup_allowed else '아니오'}",
            f"StartRecommendedAction: {start_eligibility.recommended_action or '(없음)'}",
            f"StopAllowed: {'예' if eligibility.allowed else '아니오'}",
            f"StopMessage: {eligibility.message or '(없음)'}",
            f"RecommendedAction: {recommendation.label if recommendation else '(없음)'}",
            f"RecommendedActionKey: {recommendation.action_key if recommendation else '(없음)'}",
        ]
        if self._is_expected_limit_stop(status):
            lines.append("StatusInterpretation: 기본 watch 시작 preset의 forward 한도에 도달해 정지했습니다.")
            lines.append("ContinuousWatchGuidance: " + self.continuous_watch_guidance())
        elif status.status_reason == "run-duration-reached":
            lines.append(
                "StatusInterpretation: 기본 watch 시작 preset의 run duration 한도에 도달해 정지했습니다."
            )
        if status.reason_codes:
            lines.append("StatusReasonCodes: " + ", ".join(status.reason_codes))
        if start_eligibility.reason_codes:
            lines.append("StartBlockReasons: " + ", ".join(start_eligibility.reason_codes))
        if start_eligibility.warning_codes:
            lines.append("StartWarnings: " + ", ".join(start_eligibility.warning_codes))
        if eligibility.reason_codes:
            lines.append("StopBlockReasons: " + ", ".join(eligibility.reason_codes))
        if eligibility.warning_codes:
            lines.append("StopWarnings: " + ", ".join(eligibility.warning_codes))
        if any(int(counts.get(name, 0) or 0) > 0 for name in ("NoZipCount", "SummaryStaleCount", "DoneStaleCount")):
            lines.append(
                "ArtifactImportGuidance: 외부 프로젝트 폴더 산출물은 자동 인식하지 않습니다. "
                "새 RunRoot라면 target-local check-artifact / submit-artifact wrapper를 먼저 사용하고, "
                "wrapper가 없으면 check-paired-exchange-artifact.ps1 또는 import-paired-exchange-artifact.ps1로 "
                "현재 RunRoot target folder 계약에 맞춰 검증/가져오세요."
            )
        return WatcherDiagnostics(
            hint=self.runtime_hint(paired_status, run_root),
            details="\n".join(lines),
        )

    def default_start_request(self, *, config_path: str, run_root: str) -> WatcherStartRequest:
        return WatcherStartRequest(
            config_path=config_path,
            run_root=run_root,
            use_headless_dispatch=True,
            max_forward_count=DEFAULT_WATCHER_MAX_FORWARD_COUNT,
            run_duration_sec=DEFAULT_WATCHER_RUN_DURATION_SEC,
        )

    def start(
        self,
        command_service: CommandService,
        *,
        config_path: str,
        run_root: str,
        paired_status: dict | None,
        clear_stale_first: bool = False,
    ) -> tuple[WatcherControlResult, list[str]]:
        notes: list[str] = []
        eligibility = self.start_eligibility(paired_status, run_root)
        recoverable_codes = {"stale_control_file", "stop_requested_timeout", "control_pending_action_exists"}
        if not eligibility.allowed:
            if not (clear_stale_first and eligibility.cleanup_allowed):
                blocked_result = WatcherControlResult(
                        ok=False,
                        action="start",
                        run_root=run_root,
                        state=eligibility.state,
                        message=eligibility.message,
                        reason_codes=list(eligibility.reason_codes),
                        warning_codes=list(eligibility.warning_codes),
                )
                self._record_audit(action="start", result=blocked_result, extra={"Mode": "eligibility_block"})
                return blocked_result, notes
            clear_result = self.watcher_service.recover_stale_start_blockers(run_root, paired_status)
            notes.append(clear_result.message)
            self._record_audit(
                action="recover_start_blockers",
                result=clear_result,
                extra={"Mode": "pre_start_cleanup"},
            )
            if not clear_result.ok:
                return clear_result, notes
            remaining_blockers = [code for code in eligibility.reason_codes if code not in recoverable_codes]
            if remaining_blockers:
                blocked_result = WatcherControlResult(
                        ok=False,
                        action="start",
                        run_root=run_root,
                        state=eligibility.state,
                        message="stale watcher control을 정리했지만 시작 차단 사유가 남아 있습니다.",
                        reason_codes=remaining_blockers,
                        warning_codes=list(eligibility.warning_codes),
                )
                self._record_audit(
                    action="start",
                    result=blocked_result,
                    extra={"Mode": "post_cleanup_block"},
                )
                return blocked_result, notes

        request = self.default_start_request(config_path=config_path, run_root=run_root)
        result = self.watcher_service.start_detached(command_service, request)
        self._record_audit(
            action="start",
            result=result,
            extra={"ConfigPath": config_path, "ClearStaleFirst": clear_stale_first, "Notes": list(notes)},
        )
        return result, notes

    def request_stop(self, paired_status: dict | None, run_root: str) -> WatcherControlResult:
        result = self.watcher_service.request_stop(paired_status, run_root)
        self._record_audit(action="stop", result=result)
        return result

    def recover_start_blockers(self, paired_status: dict | None, run_root: str) -> WatcherControlResult:
        result = self.watcher_service.recover_stale_start_blockers(run_root, paired_status)
        self._record_audit(action="recover_start_blockers", result=result)
        return result

    def restart(
        self,
        command_service: CommandService,
        status_loader: StatusLoader,
        *,
        config_path: str,
        run_root: str,
        paired_status: dict | None,
        poll_interval_sec: float = 1.0,
    ) -> WatcherControlResult:
        request = self.default_start_request(config_path=config_path, run_root=run_root)
        result = self.watcher_service.restart(
            command_service,
            status_loader,
            paired_status,
            request,
            poll_interval_sec=poll_interval_sec,
        )
        self._record_audit(
            action="restart",
            result=result,
            extra={"ConfigPath": config_path},
        )
        return result
