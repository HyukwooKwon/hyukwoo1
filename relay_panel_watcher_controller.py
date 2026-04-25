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
        default_request = self.default_start_request(config_path="", run_root="")
        return "기본 " + self.describe_start_request(default_request)

    def configured_start_request(
        self,
        paired_status: dict | None,
        *,
        config_path: str,
        run_root: str,
    ) -> WatcherStartRequest | None:
        watcher = ((paired_status or {}).get("Watcher", {}) or {})
        if not bool(watcher.get("StatusExists", False)):
            return None
        return WatcherStartRequest(
            config_path=config_path,
            run_root=run_root,
            use_headless_dispatch=True,
            max_forward_count=int(watcher.get("ConfiguredMaxForwardCount", 0) or 0),
            run_duration_sec=int(watcher.get("ConfiguredRunDurationSec", 0) or 0),
            pair_max_roundtrip_count=int(watcher.get("ConfiguredMaxRoundtripCount", 0) or 0),
        )

    def describe_start_request(self, request: WatcherStartRequest) -> str:
        forward_limit = (
            "forward 제한 없음"
            if request.max_forward_count <= 0
            else f"forward {request.max_forward_count}회(watcher 전체 합계)"
        )
        run_duration = (
            "run 제한 없음"
            if request.run_duration_sec <= 0
            else f"run {request.run_duration_sec}초"
        )
        pair_roundtrip_limit = (
            "pair 왕복 제한 없음"
            if request.pair_max_roundtrip_count <= 0
            else f"pair별 왕복 {request.pair_max_roundtrip_count}회"
        )
        dispatch_mode = "headless dispatch" if request.use_headless_dispatch else "direct dispatch"
        return f"watch 시작 preset: {forward_limit} / {run_duration} / {pair_roundtrip_limit} / {dispatch_mode}"

    def continuous_watch_guidance(self, configured_forward_limit: int | None = None) -> str:
        effective_limit = DEFAULT_WATCHER_MAX_FORWARD_COUNT if configured_forward_limit is None else configured_forward_limit
        if effective_limit <= 0:
            return "현재 기본 watch 시작에는 forward 횟수 제한이 없습니다."
        return (
            f"현재 watcher는 watcher 전체 기준으로 {effective_limit}회 forward 후 멈춥니다. "
            "이 값은 pair별 왕복 제한이 아닙니다. 계속 왕복이 필요하면 MaxForwardCount를 0 또는 더 큰 값으로 별도 실행하세요."
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
    def _configured_pair_roundtrip_limit(paired_status: dict | None) -> int:
        return int(((paired_status or {}).get("Watcher", {}) or {}).get("ConfiguredMaxRoundtripCount", 0) or 0)

    @classmethod
    def _pair_policy_roundtrip_limits(cls, paired_status: dict | None) -> dict[str, int]:
        limits: dict[str, int] = {}
        for row in (((paired_status or {}).get("Pairs", []) or [])):
            if not isinstance(row, dict):
                continue
            pair_id = str(row.get("PairId", "") or "")
            if not pair_id:
                continue
            limit = int(row.get("ConfiguredMaxRoundtripCount", 0) or 0)
            if limit <= 0:
                limit = int(row.get("PolicyPairMaxRoundtripCount", 0) or 0)
            if limit > 0:
                limits[pair_id] = limit
        return limits

    @classmethod
    def _effective_pair_roundtrip_limit(cls, paired_status: dict | None) -> int:
        configured_limit = cls._configured_pair_roundtrip_limit(paired_status)
        if configured_limit > 0:
            return configured_limit
        pair_limits = set(cls._pair_policy_roundtrip_limits(paired_status).values())
        if len(pair_limits) == 1:
            return next(iter(pair_limits))
        return 0

    @staticmethod
    def _configured_forward_limit(paired_status: dict | None) -> int:
        value = int(((paired_status or {}).get("Watcher", {}) or {}).get("ConfiguredMaxForwardCount", 0) or 0)
        return value if value > 0 else DEFAULT_WATCHER_MAX_FORWARD_COUNT

    @staticmethod
    def _configured_run_duration_sec(paired_status: dict | None) -> int:
        value = int(((paired_status or {}).get("Watcher", {}) or {}).get("ConfiguredRunDurationSec", 0) or 0)
        return value if value > 0 else DEFAULT_WATCHER_RUN_DURATION_SEC

    @staticmethod
    def _is_pair_roundtrip_limit_stop(status) -> bool:
        return status.status_reason == "pair-roundtrip-limit-reached"

    def _is_expected_forward_limit_stop(self, status, paired_status: dict | None) -> bool:
        if status.status_reason == "max-forward-count-reached":
            return True
        if status.stop_category != "expected-limit":
            return False
        if self._is_pair_roundtrip_limit_stop(status):
            return False
        return self._configured_pair_roundtrip_limit(paired_status) <= 0

    def audit_log_path(self) -> str:
        return str(self.audit_logger.log_path)

    def stop_eligibility(self, paired_status: dict | None, run_root: str):
        return self.watcher_service.get_stop_eligibility(paired_status, run_root)

    def pause_eligibility(self, paired_status: dict | None, run_root: str):
        return self.watcher_service.get_pause_eligibility(paired_status, run_root)

    def resume_eligibility(self, paired_status: dict | None, run_root: str):
        return self.watcher_service.get_resume_eligibility(paired_status, run_root)

    def start_eligibility(self, paired_status: dict | None, run_root: str) -> WatcherStartEligibility:
        return self.watcher_service.get_start_eligibility(paired_status, run_root)

    def runtime_hint(self, paired_status: dict | None, run_root: str) -> str:
        status = self.runtime_status(paired_status, run_root)
        configured_forward_limit = self._configured_forward_limit(paired_status)
        configured_run_duration_sec = self._configured_run_duration_sec(paired_status)
        parts = [f"watch={status.state}"]
        if status.status_reason:
            parts.append("reason=" + status.status_reason)
        elif status.stop_category:
            parts.append("reason=" + status.stop_category)
        if status.stop_category:
            parts.append("stopCategory=" + status.stop_category)
        if self._is_pair_roundtrip_limit_stop(status):
            configured_limit = self._effective_pair_roundtrip_limit(paired_status)
            if configured_limit > 0:
                parts.append("pair_roundtrip_limit=" + str(configured_limit))
        elif self._is_expected_forward_limit_stop(status, paired_status) and configured_forward_limit > 0:
            parts.append("forward_limit=" + str(configured_forward_limit))
        if status.status_reason == "run-duration-reached" and configured_run_duration_sec > 0:
            parts.append("run_limit_sec=" + str(configured_run_duration_sec))
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
        configured_forward_limit = self._configured_forward_limit(paired_status)
        configured_run_duration_sec = self._configured_run_duration_sec(paired_status)

        if self._is_pair_roundtrip_limit_stop(status):
            configured_limit = self._effective_pair_roundtrip_limit(paired_status)
            detail = (
                f"현재 watcher는 각 pair가 {configured_limit}왕복에 도달해 정지했습니다. "
                "계속하려면 PairMaxRoundtripCount를 늘리거나 0으로 다시 시작하세요."
                if configured_limit > 0
                else "현재 watcher는 pair별 왕복 한도에 도달해 정지했습니다. 계속하려면 roundtrip limit 또는 pair policy limit을 조정해 다시 시작하세요."
            )
            return WatcherRecommendation("start_watcher", "watch 다시 시작", detail)
        if self._is_expected_forward_limit_stop(status, paired_status):
            return WatcherRecommendation("start_watcher", "watch 다시 시작", self.continuous_watch_guidance(configured_forward_limit))
        if status.status_reason == "run-duration-reached":
            return WatcherRecommendation(
                "start_watcher",
                "watch 다시 시작",
                (
                    f"현재 watcher는 run {configured_run_duration_sec}초 후 멈춥니다. "
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
        if status.state == "paused":
            return WatcherRecommendation("resume_watcher", "watch 재개", "paused 상태입니다. 재개하면 누적된 다음 동작이 이어집니다.")
        if "pending_forward_exists" in stop_eligibility.reason_codes:
            return WatcherRecommendation("focus_ready_to_forward_artifact", "전달 가능 target 보기", "결과 탭에서 다음 전달 가능 target을 먼저 확인하세요.")
        if start_eligibility.allowed and status.state == "stopped":
            return WatcherRecommendation("start_watcher", "watch 시작", "현재 watcher 시작 조건을 만족합니다.")
        if status.state in {"running", "starting", "pause_requested", "resume_requested", "stop_requested", "stopping"}:
            return WatcherRecommendation("run_paired_status", "Pair 상태 보기", "paired status를 다시 확인해 최신 상태를 보세요.")
        return None

    def diagnostics(self, paired_status: dict | None, run_root: str) -> WatcherDiagnostics:
        status = self.runtime_status(paired_status, run_root)
        start_eligibility = self.start_eligibility(paired_status, run_root)
        eligibility = self.stop_eligibility(paired_status, run_root)
        pause_eligibility = self.pause_eligibility(paired_status, run_root)
        resume_eligibility = self.resume_eligibility(paired_status, run_root)
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
            f"PauseAllowed: {'예' if pause_eligibility.allowed else '아니오'}",
            f"PauseMessage: {pause_eligibility.message or '(없음)'}",
            f"ResumeAllowed: {'예' if resume_eligibility.allowed else '아니오'}",
            f"ResumeMessage: {resume_eligibility.message or '(없음)'}",
            f"RecommendedAction: {recommendation.label if recommendation else '(없음)'}",
            f"RecommendedActionKey: {recommendation.action_key if recommendation else '(없음)'}",
        ]
        configured_request = self.configured_start_request(
            paired_status,
            config_path="",
            run_root=run_root,
        )
        lines.append(
            "CurrentWatcherPreset: "
            + (
                self.describe_start_request(configured_request)
                if configured_request is not None
                else "(watcher status 파일 없음)"
            )
        )
        configured_limit = int(((paired_status or {}).get("Watcher", {}) or {}).get("ConfiguredMaxForwardCount", 0) or 0)
        if configured_limit > 0:
            lines.append(
                f"ConfiguredMaxForwardSemantics: watcher 전체 forward 합계 {configured_limit}회 기준이며 pair별 왕복 한도가 아닙니다."
            )
        configured_run_duration_sec = int(((paired_status or {}).get("Watcher", {}) or {}).get("ConfiguredRunDurationSec", 0) or 0)
        if configured_run_duration_sec > 0:
            lines.append(f"ConfiguredRunDurationSec: {configured_run_duration_sec}초")
        configured_roundtrip_limit = self._effective_pair_roundtrip_limit(paired_status)
        if configured_roundtrip_limit > 0:
            lines.append(f"ConfiguredPairRoundtripLimit: pair별 왕복 {configured_roundtrip_limit}회 기준입니다.")
        if self._is_pair_roundtrip_limit_stop(status):
            if configured_roundtrip_limit > 0:
                lines.append(
                    f"StatusInterpretation: watcher가 pair별 왕복 {configured_roundtrip_limit}회 한도에 도달해 정지했습니다."
                )
            else:
                lines.append("StatusInterpretation: watcher가 pair별 왕복 한도에 도달해 정지했습니다.")
        elif self._is_expected_forward_limit_stop(status, paired_status):
            lines.append("StatusInterpretation: 기본 watch 시작 preset의 forward 한도에 도달해 정지했습니다.")
            lines.append("ContinuousWatchGuidance: " + self.continuous_watch_guidance(self._configured_forward_limit(paired_status)))
        elif status.status_reason == "run-duration-reached":
            lines.append(
                "StatusInterpretation: 현재 watcher의 run duration 한도에 도달해 정지했습니다."
            )
        elif status.state == "paused":
            lines.append("StatusInterpretation: watcher가 paused 상태이며 visible worker는 paused run의 head queued command를 claim하지 않습니다.")
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
        if pause_eligibility.reason_codes:
            lines.append("PauseBlockReasons: " + ", ".join(pause_eligibility.reason_codes))
        if resume_eligibility.reason_codes:
            lines.append("ResumeBlockReasons: " + ", ".join(resume_eligibility.reason_codes))
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
        request: WatcherStartRequest | None = None,
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

        effective_request = request or self.default_start_request(config_path=config_path, run_root=run_root)
        result = self.watcher_service.start_detached(command_service, effective_request)
        self._record_audit(
            action="start",
            result=result,
            extra={
                "ConfigPath": config_path,
                "ClearStaleFirst": clear_stale_first,
                "Notes": list(notes),
                "MaxForwardCount": effective_request.max_forward_count,
                "RunDurationSec": effective_request.run_duration_sec,
                "PairMaxRoundtripCount": effective_request.pair_max_roundtrip_count,
                "UseHeadlessDispatch": effective_request.use_headless_dispatch,
            },
        )
        return result, notes

    def request_stop(self, paired_status: dict | None, run_root: str) -> WatcherControlResult:
        result = self.watcher_service.request_stop(paired_status, run_root)
        self._record_audit(action="stop", result=result)
        return result

    def request_pause(self, paired_status: dict | None, run_root: str) -> WatcherControlResult:
        result = self.watcher_service.request_pause(paired_status, run_root)
        self._record_audit(action="pause", result=result)
        return result

    def request_resume(self, paired_status: dict | None, run_root: str) -> WatcherControlResult:
        result = self.watcher_service.request_resume(paired_status, run_root)
        self._record_audit(action="resume", result=result)
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
        request: WatcherStartRequest | None = None,
    ) -> WatcherControlResult:
        effective_request = request or self.default_start_request(config_path=config_path, run_root=run_root)
        result = self.watcher_service.restart(
            command_service,
            status_loader,
            paired_status,
            effective_request,
            poll_interval_sec=poll_interval_sec,
        )
        self._record_audit(
            action="restart",
            result=result,
            extra={
                "ConfigPath": config_path,
                "MaxForwardCount": effective_request.max_forward_count,
                "RunDurationSec": effective_request.run_duration_sec,
                "PairMaxRoundtripCount": effective_request.pair_max_roundtrip_count,
                "UseHeadlessDispatch": effective_request.use_headless_dispatch,
            },
        )
        return result
