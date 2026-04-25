from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from relay_panel_models import (
    ActionModel,
    DashboardRawBundle,
    IssueModel,
    PairSummaryModel,
    PanelStateModel,
    StageModel,
    StatusCardModel,
    WorkflowState,
)


class DashboardAggregator:
    PAIR_PHASE_CANONICAL = {
        "seed-running": "seed-running",
        "partner-running": "partner-running",
        "waiting-partner-handoff": "waiting-partner-handoff",
        "waiting-handoff": "waiting-partner-handoff",
        "waiting-return": "waiting-return",
        "paused": "paused",
        "limit-reached": "limit-reached",
        "manual-attention": "manual-attention",
        "manual-review": "manual-attention",
        "error-blocked": "error-blocked",
        "completed": "completed",
    }
    IGNORED_REASON_LABELS = {
        "metadata-missing": "메타 없음",
        "metadata-missing-fields": "메타 필수값 누락",
        "preexisting-before-router-start": "이전 세션 ready",
        "launcher-session-mismatch": "런처 세션 불일치",
        "paired-metadata-missing-fields": "pair 메타 필수값 누락",
        "metadata-target-mismatch": "target 메타 불일치",
        "metadata-parse-failed": "메타 파싱 실패",
        "message-type-unsupported": "지원하지 않는 message type",
        "archive-metadata-missing": "archive 메타 없음",
        "archive-metadata-parse-failed": "archive 메타 파싱 실패",
        "unknown": "무시 사유 미확인",
    }
    IGNORED_REASON_PRIORITIES = {
        "metadata-missing": 0,
        "metadata-missing-fields": 0,
        "metadata-parse-failed": 0,
        "paired-metadata-missing-fields": 0,
        "metadata-target-mismatch": 1,
        "message-type-unsupported": 1,
        "launcher-session-mismatch": 2,
        "archive-metadata-parse-failed": 3,
        "archive-metadata-missing": 4,
        "preexisting-before-router-start": 10,
        "unknown": 20,
    }

    @staticmethod
    def _string_list(value: object) -> list[str]:
        if not isinstance(value, list):
            return []
        return [str(item) for item in value if str(item)]

    @staticmethod
    def _parse_timestamp(raw: object) -> datetime | None:
        if not isinstance(raw, str):
            return None
        text = raw.strip()
        if not text:
            return None
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)

    @classmethod
    def _timestamp_is_current(cls, raw: str, anchor_raw: str) -> bool:
        if not anchor_raw:
            return True
        timestamp = cls._parse_timestamp(raw)
        anchor = cls._parse_timestamp(anchor_raw)
        if timestamp is None or anchor is None:
            return False
        return timestamp >= anchor

    @staticmethod
    def _number_value(raw: object) -> float | None:
        if raw in ("", None):
            return None
        try:
            return float(raw)
        except (TypeError, ValueError):
            return None

    @classmethod
    def _binding_window_count(cls, relay_status: dict) -> int:
        runtime = relay_status.get("Runtime", {}) if relay_status else {}
        scoped_count = runtime.get("BindingScopedTargetCount", runtime.get("BindingScopedWindowCount"))
        if isinstance(scoped_count, int):
            return max(0, scoped_count)

        lane = relay_status.get("Lane", {}) if relay_status else {}
        binding_path = lane.get("BindingProfilePath", "") or ""
        if not binding_path:
            return 0

        try:
            payload = json.loads(Path(binding_path).read_text(encoding="utf-8"))
        except Exception:
            return 0

        windows = payload.get("windows", [])
        if not isinstance(windows, list):
            return 0

        active_target_ids = set(cls._string_list(runtime.get("ActiveTargetIds", [])))
        scoped_target_ids: set[str] = set()
        fallback_count = 0
        for entry in windows:
            if not isinstance(entry, dict):
                continue

            fallback_count += 1
            target_id = str(entry.get("target_id") or entry.get("TargetId") or entry.get("targetId") or "").strip()
            if not target_id:
                continue
            if active_target_ids and target_id not in active_target_ids:
                continue
            scoped_target_ids.add(target_id)

        if scoped_target_ids:
            return len(scoped_target_ids)
        return fallback_count

    @classmethod
    def _run_root_timing_detail(cls, *, run_context: dict, hints: dict) -> str:
        last_write = str(
            hints.get("ActionRunRootLastWriteAt", "")
            or run_context.get("SelectedRunRootLastWriteAt", "")
            or ""
        )
        observed_at = str(hints.get("ActionRunRootObservedAt", "") or "")
        age_seconds = cls._number_value(
            hints.get("ActionRunRootAgeSeconds", run_context.get("SelectedRunRootAgeSeconds"))
        )
        threshold_seconds = cls._number_value(
            hints.get("ActionRunRootThresholdSec", run_context.get("StaleRunThresholdSec", 1800))
        )

        parts: list[str] = []
        if last_write:
            parts.append(f"last_write={last_write}")
        if observed_at:
            parts.append(f"now={observed_at}")
        if age_seconds is not None:
            parts.append(f"age={age_seconds:.0f}s")
        if threshold_seconds is not None:
            parts.append(f"threshold={threshold_seconds:.0f}s")
        return " / ".join(parts)

    @staticmethod
    def _pair_activation_map(effective_data: dict) -> dict[str, dict]:
        activation_map: dict[str, dict] = {}
        for item in effective_data.get("PairActivationSummary", []):
            pair_id = str(item.get("PairId", ""))
            if pair_id:
                activation_map[pair_id] = item
        return activation_map

    @staticmethod
    def _pair_target_map(paired_status: dict | None) -> dict[str, list[dict]]:
        pair_map: dict[str, list[dict]] = {}
        if not paired_status:
            return pair_map
        for row in paired_status.get("Targets", []):
            pair_id = str(row.get("PairId", ""))
            if not pair_id:
                continue
            pair_map.setdefault(pair_id, []).append(row)
        return pair_map

    @staticmethod
    def _pair_status_map(paired_status: dict | None) -> dict[str, dict]:
        pair_map: dict[str, dict] = {}
        if not paired_status:
            return pair_map
        for row in paired_status.get("Pairs", []):
            pair_id = str(row.get("PairId", ""))
            if pair_id:
                pair_map[pair_id] = row
        return pair_map

    @staticmethod
    def _derive_pair_next_action(
        *,
        latest_states: list[str],
        handoff_ready_count: int,
        dispatch_running_count: int,
        dispatch_failed_count: int,
        failure_count: int,
        zip_count: int,
        error_present_count: int,
    ) -> str:
        if error_present_count > 0 or failure_count > 0:
            return "manual-review"
        if handoff_ready_count > 0:
            return "handoff-ready"
        if dispatch_running_count > 0:
            return "dispatch-running"
        if dispatch_failed_count > 0:
            return "dispatch-failed"
        if zip_count <= 0 or "no-zip" in latest_states:
            return "await-review-zip"
        if any(state in latest_states for state in ("summary-missing", "summary-stale", "done-stale")):
            return "artifact-check-needed"
        if "forwarded" in latest_states:
            return "await-partner-output"
        return ""

    @classmethod
    def _normalize_pair_phase(
        cls,
        raw_phase: object,
        *,
        watcher_status: str = "",
        next_action: str = "",
        reached_roundtrip_limit: bool = False,
    ) -> str:
        normalized = str(raw_phase or "").strip().lower()
        if normalized in cls.PAIR_PHASE_CANONICAL:
            return cls.PAIR_PHASE_CANONICAL[normalized]
        if reached_roundtrip_limit or next_action == "limit-reached":
            return "limit-reached"
        if watcher_status == "paused":
            return "paused"
        if next_action == "manual-review":
            return "manual-attention"
        return ""

    @staticmethod
    def _load_acceptance_receipt_summary(paired_status: dict | None) -> dict[str, str]:
        receipt = ((paired_status or {}).get("AcceptanceReceipt", {}) or {})
        path = str(receipt.get("Path", "") or "").strip()
        payload: dict[str, object] = {}
        parse_error = str(receipt.get("ParseError", "") or "").strip()
        if path:
            try:
                loaded = json.loads(Path(path).read_text(encoding="utf-8"))
            except Exception as exc:
                if not parse_error:
                    parse_error = str(exc)
            else:
                if isinstance(loaded, dict):
                    payload = loaded

        outcome = payload.get("Outcome", {}) if isinstance(payload.get("Outcome", {}), dict) else {}
        phase_history = payload.get("PhaseHistory", [])
        if not isinstance(phase_history, list):
            phase_history = []
        history_tail_entries: list[str] = []
        for entry in phase_history[-4:]:
            if not isinstance(entry, dict):
                continue
            stage = str(entry.get("Stage", "") or "")
            state = str(entry.get("AcceptanceState", "") or "")
            if stage and state:
                history_tail_entries.append(f"{stage}:{state}")
            elif stage:
                history_tail_entries.append(stage)
            elif state:
                history_tail_entries.append(state)
        return {
            "Path": path,
            "ParseError": parse_error,
            "Exists": "true" if bool(receipt.get("Exists", False) or payload) else "false",
            "LastWriteAt": str(receipt.get("LastWriteAt", "") or ""),
            "LastUpdatedAt": str(payload.get("LastUpdatedAt", "") or ""),
            "GeneratedAt": str(payload.get("GeneratedAt", "") or ""),
            "Stage": str(payload.get("Stage", "") or ""),
            "AcceptanceState": str(outcome.get("AcceptanceState", "") or receipt.get("AcceptanceState", "") or ""),
            "AcceptanceReason": str(outcome.get("AcceptanceReason", "") or receipt.get("AcceptanceReason", "") or ""),
            "BlockedBy": str(payload.get("BlockedBy", "") or ""),
            "BlockedTargetId": str(payload.get("BlockedTargetId", "") or ""),
            "BlockedRunRoot": str(payload.get("BlockedRunRoot", "") or ""),
            "BlockedPath": str(payload.get("BlockedPath", "") or ""),
            "BlockedDetail": str(payload.get("BlockedDetail", "") or ""),
            "PhaseHistoryCount": str(len(phase_history)),
            "PhaseHistoryTail": " -> ".join(history_tail_entries),
        }

    @staticmethod
    def _map_next_action(command_text: str) -> ActionModel:
        mapping = [
            ("attach-targets-from-bindings.ps1", "붙이기", "attach_windows"),
            ("check-target-window-visibility.ps1", "입력 점검", "check_visibility"),
            ("ensure-targets.ps1", "대상 준비", "launch_windows"),
            ("router.ps1", "라우터 시작", "start_router"),
        ]
        for token, label, action_key in mapping:
            if token in command_text:
                return ActionModel(label=label, action_key=action_key, command_text=command_text)
        return ActionModel(label="명령 복사", action_key="copy_command", command_text=command_text, detail=command_text)

    @classmethod
    def _ignored_reason_entries(cls, relay_status: dict) -> list[dict[str, object]]:
        raw_entries = relay_status.get("IgnoredReasonCounts", []) if relay_status else []
        if not isinstance(raw_entries, list):
            return []

        entries: list[dict[str, object]] = []
        for row in raw_entries:
            if not isinstance(row, dict):
                continue
            code = str(row.get("Code", "") or "").strip()
            if not code:
                continue
            try:
                count = max(0, int(row.get("Count", 0) or 0))
            except (TypeError, ValueError):
                count = 0
            label = str(row.get("Label", "") or "").strip() or cls.IGNORED_REASON_LABELS.get(code, code)
            entries.append(
                {
                    "Code": code,
                    "Count": count,
                    "Label": label,
                    "Priority": cls.IGNORED_REASON_PRIORITIES.get(code, 50),
                }
            )

        return entries

    @classmethod
    def _primary_ignored_reason(cls, relay_status: dict) -> dict[str, object] | None:
        entries = cls._ignored_reason_entries(relay_status)
        if not entries:
            return None
        return sorted(
            entries,
            key=lambda item: (int(item.get("Priority", 50)), -int(item.get("Count", 0)), str(item.get("Code", ""))),
        )[0]

    @classmethod
    def _launch_window_status(
        cls,
        *,
        effective_data: dict,
        relay_status: dict,
        binding_windows: int,
        expected_targets: int,
    ) -> dict[str, object]:
        lane = relay_status.get("Lane", {}) if relay_status else {}
        runtime = relay_status.get("Runtime", {}) if relay_status else {}
        router = relay_status.get("Router", {}) if relay_status else {}
        hints = effective_data.get("PanelRuntimeHints", {}) if effective_data else {}
        if not isinstance(hints, dict):
            hints = {}

        anchor_raw = str(hints.get("WindowLaunchAnchorUtc", "") or hints.get("PanelOpenedAtUtc", "") or "")
        binding_last_write = str(lane.get("BindingProfileLastWriteAt", "") or "")
        binding_exists = bool(lane.get("BindingProfileExists", False) or lane.get("BindingProfilePath", ""))
        binding_parse_error = str(lane.get("BindingProfileParseError", "") or "")
        binding_count_ok = binding_windows >= expected_targets
        binding_current = cls._timestamp_is_current(binding_last_write, anchor_raw)

        runtime_session_ids = runtime.get("LauncherSessionIds", [])
        if not isinstance(runtime_session_ids, list):
            runtime_session_ids = []
        runtime_session_ids = [str(item) for item in runtime_session_ids if str(item)]
        runtime_session_id = runtime_session_ids[0] if len(runtime_session_ids) == 1 else ""
        router_session_id = str(router.get("LauncherSessionId", "") or "")
        runtime_session_mixed = (
            bool(runtime.get("Exists", False))
            and int(runtime.get("UniqueTargetCount", 0) or 0) > 0
            and len(runtime_session_ids) > 1
        )
        router_session_mismatch = bool(router_session_id and runtime_session_id and router_session_id != runtime_session_id)

        if binding_parse_error:
            reason = "binding_parse_error"
        elif not binding_exists:
            reason = "binding_missing"
        elif not binding_count_ok:
            reason = "binding_incomplete"
        elif not binding_current:
            reason = "binding_stale"
        else:
            reason = ""

        ready = not reason
        if ready:
            stage_status_text = "완료"
        elif reason == "binding_stale":
            stage_status_text = "이전 세션"
        else:
            stage_status_text = "필요"

        binding_scope_label = "현재 세션" if anchor_raw else "binding profile"
        window_count_label = "{0}개 창".format(expected_targets)
        if reason == "binding_parse_error":
            stage_detail = "binding profile parse error"
            workflow_label = "창 준비 안 됨"
            workflow_detail = "binding profile을 해석하지 못해 현재 세션 창 준비 상태를 신뢰할 수 없습니다."
            issue_title = "binding profile 오류"
            issue_detail = "binding profile parse error로 현재 세션 창 준비 상태를 판단할 수 없습니다."
        elif reason == "binding_missing":
            stage_detail = "{0} binding 0/{1}".format(binding_scope_label, expected_targets)
            workflow_label = "현재 세션 창 준비 필요"
            workflow_detail = "현재 세션 기준 binding profile이 없습니다. {0} 준비가 필요합니다.".format(window_count_label)
            issue_title = "현재 세션 창 준비 안 됨"
            issue_detail = "현재 세션 기준 binding profile이 없습니다. {0} 준비가 필요합니다.".format(window_count_label)
        elif reason == "binding_incomplete":
            stage_detail = "{0} binding {1}/{2}".format(binding_scope_label, binding_windows, expected_targets)
            workflow_label = "현재 세션 창 준비 필요"
            workflow_detail = "현재 세션 기준 binding target 수가 부족합니다."
            issue_title = "현재 세션 창 준비 안 됨"
            issue_detail = "현재 세션 기준 binding target 수가 부족합니다. {0} 준비를 다시 확인하세요.".format(window_count_label)
        elif reason == "binding_stale":
            stage_detail = "이전 세션 binding {0}/{1}".format(binding_windows, expected_targets)
            workflow_label = "현재 세션 창 준비 필요"
            workflow_detail = "기록된 binding은 있지만 현재 패널 세션 이후 갱신된 창 준비는 아닙니다."
            issue_title = "이전 세션 창 기록"
            issue_detail = "이전 세션 binding 기록만 남아 있습니다. {0} 준비를 다시 확인하세요.".format(window_count_label)
        else:
            stage_detail = "{0} binding {1}/{2}".format(binding_scope_label, binding_windows, expected_targets)
            workflow_label = "실행 가능"
            workflow_detail = "필수 준비 단계를 통과했습니다."
            issue_title = ""
            issue_detail = ""

        if reason == "binding_parse_error":
            attach_wait_detail = "붙이기 비활성: binding profile parse error로 현재 세션 창 준비 상태를 신뢰할 수 없습니다."
        elif reason == "binding_missing":
            attach_wait_detail = "붙이기 비활성: 현재 세션 기준 binding profile이 없습니다. {0} 준비가 필요합니다.".format(window_count_label)
        elif reason == "binding_incomplete":
            attach_wait_detail = "붙이기 비활성: 현재 세션 기준 binding target 수가 부족합니다. {0} 준비를 다시 확인하세요.".format(window_count_label)
        elif reason == "binding_stale":
            attach_wait_detail = "붙이기 비활성: 이전 세션 창 기록만 있습니다. 현재 세션 기준 {0} 다시 준비 필요".format(window_count_label)
            if binding_last_write and anchor_raw:
                attach_wait_detail += " (binding={0}, panel={1})".format(binding_last_write, anchor_raw)
            elif binding_last_write:
                attach_wait_detail += " (binding={0})".format(binding_last_write)
        else:
            attach_wait_detail = ""

        card_detail = binding_last_write or "binding profile 없음"
        if anchor_raw and card_detail != "binding profile 없음":
            freshness_label = "현재 세션" if binding_current else "이전 세션"
            card_detail = "{0} / {1}".format(freshness_label, card_detail)
        elif anchor_raw:
            card_detail = "현재 세션 기준 binding profile 없음"

        if runtime_session_mixed:
            card_detail = "{0} / runtime session 혼합".format(card_detail)
        elif router_session_mismatch:
            card_detail = "{0} / router session 불일치".format(card_detail)

        return {
            "ready": ready,
            "reason": reason,
            "workflow_label": workflow_label,
            "workflow_detail": workflow_detail,
            "issue_title": issue_title,
            "issue_detail": issue_detail,
            "card_title": "세션 창 준비",
            "card_detail": card_detail,
            "stage_title": "1. 세션 창 준비",
            "stage_status_text": stage_status_text,
            "stage_detail": stage_detail,
            "attach_wait_detail": attach_wait_detail,
        }

    @classmethod
    def _attach_status(
        cls,
        *,
        launch_status: dict[str, object],
        relay_status: dict,
        expected_targets: int,
    ) -> dict[str, object]:
        runtime = relay_status.get("Runtime", {}) if relay_status else {}
        runtime_exists = bool(runtime.get("Exists", False))
        runtime_parse_error = str(runtime.get("ParseError", "") or "")
        runtime_unique = int(runtime.get("UniqueTargetCount", 0) or 0)
        attached_count = int(runtime.get("AttachedCount", 0) or 0)
        launched_count = int(runtime.get("LaunchedCount", 0) or 0)
        missing_target_ids = cls._string_list(runtime.get("MissingTargetIds", []))
        extra_target_ids = cls._string_list(runtime.get("ExtraTargetIds", []))
        duplicate_target_ids = cls._string_list(runtime.get("DuplicateTargetIds", []))
        blank_target_ids = cls._string_list(runtime.get("BlankTargetIds", []))
        launcher_session_ids = cls._string_list(runtime.get("LauncherSessionIds", []))
        has_single_session = bool(runtime.get("HasSingleLauncherSession", len(launcher_session_ids) <= 1))

        enabled = bool(launch_status.get("ready", False))
        session_count = len(launcher_session_ids) if launcher_session_ids else (1 if has_single_session and runtime_unique > 0 else 0)

        if not enabled:
            reason = "waiting_for_launch"
        elif not runtime_exists:
            reason = "runtime_missing"
        elif runtime_parse_error:
            reason = "runtime_parse_error"
        elif missing_target_ids or extra_target_ids or duplicate_target_ids or blank_target_ids:
            reason = "runtime_incomplete"
        elif not has_single_session:
            reason = "runtime_mixed_session"
        elif runtime_unique < expected_targets:
            reason = "runtime_incomplete"
        else:
            reason = ""

        ready = not reason
        if reason == "waiting_for_launch":
            status_text = "대기"
            detail = str(launch_status.get("attach_wait_detail", "")) or "대기: 현재 세션 창 준비 후 attach를 다시 확인합니다."
        elif reason == "runtime_mixed_session":
            status_text = "필요"
            detail = "runtime unique={0}/{1} session=mixed({2})".format(runtime_unique, expected_targets, session_count)
        else:
            status_text = "완료" if ready else "필요"
            detail = "runtime unique={0}/{1} attached={2} launched={3} sessions={4}".format(
                runtime_unique,
                expected_targets,
                attached_count,
                launched_count,
                session_count,
            )

        if reason == "runtime_mixed_session":
            issue_detail = "runtime launcher session이 섞여 있습니다."
        else:
            issue_detail = "runtime map이 완전하지 않거나 세션이 섞였습니다."

        return {
            "ready": ready,
            "enabled": enabled,
            "reason": reason,
            "status_text": status_text,
            "detail": detail,
            "issue_title": "대상 창 연결 안 됨",
            "issue_detail": issue_detail,
        }

    @classmethod
    def _visibility_status(
        cls,
        *,
        attach_status: dict[str, object],
        visibility_status: dict,
        expected_targets: int,
    ) -> dict[str, object]:
        injectable_count = int(visibility_status.get("InjectableCount", 0) or 0)
        non_injectable_count = int(visibility_status.get("NonInjectableCount", 0) or 0)
        missing_runtime_count = int(visibility_status.get("MissingRuntimeCount", 0) or 0)
        duplicate_target_ids = cls._string_list(visibility_status.get("DuplicateTargetIds", []))
        runtime_parse_error = str(visibility_status.get("RuntimeParseError", "") or "")

        enabled = bool(attach_status.get("ready", False))
        if not enabled:
            reason = "waiting_for_attach"
        elif injectable_count < expected_targets or non_injectable_count > 0 or missing_runtime_count > 0 or duplicate_target_ids or runtime_parse_error:
            reason = "visibility_failed"
        else:
            reason = ""

        ready = not reason
        if reason == "waiting_for_attach":
            status_text = "대기"
            detail = "대기: 현재 세션 attach 완료 후 입력 가능 상태를 다시 확인합니다."
        else:
            status_text = "완료" if ready else "필요"
            detail = "Injectable {0}/{1} fail={2} missing={3}".format(
                injectable_count,
                expected_targets,
                non_injectable_count,
                missing_runtime_count,
            )

        return {
            "ready": ready,
            "enabled": enabled,
            "reason": reason,
            "status_text": status_text,
            "detail": detail,
        }

    @classmethod
    def _run_root_status(
        cls,
        *,
        effective_data: dict,
        visibility_stage: dict[str, object],
    ) -> dict[str, object]:
        run_context = effective_data.get("RunContext", {}) if effective_data else {}
        hints = effective_data.get("PanelRuntimeHints", {}) if effective_data else {}
        if not isinstance(hints, dict):
            hints = {}

        selected_run_root = str(run_context.get("SelectedRunRoot", "") or "")
        selected_run_root_source = str(run_context.get("SelectedRunRootSource", "") or "")
        next_run_root_preview = str(run_context.get("NextRunRootPreview", "") or "")
        action_run_root = str(hints.get("ActionRunRoot", "") or selected_run_root or "")
        action_run_root_is_override = bool(hints.get("ActionRunRootUsesOverride", False))
        action_run_root_is_stale = bool(
            hints.get("ActionRunRootIsStale", run_context.get("SelectedRunRootIsStale", False))
        )
        timing_detail = cls._run_root_timing_detail(run_context=run_context, hints=hints)
        enabled = bool(visibility_stage.get("ready", False))
        run_root_missing = (not action_run_root) or (not action_run_root_is_override and selected_run_root_source == "next-preview")
        run_root_ready = (not run_root_missing) and not action_run_root_is_stale

        if action_run_root_is_override and action_run_root:
            detail = "실행 기준 override: {0}".format(action_run_root)
            if selected_run_root and selected_run_root != action_run_root:
                detail += " / selected: {0}".format(selected_run_root)
            value = "stale" if action_run_root_is_stale else "override"
        else:
            detail = action_run_root or (next_run_root_preview or "run root 없음")
            value = "stale" if action_run_root_is_stale else (selected_run_root_source or "없음")

        if timing_detail:
            detail = "{0} / {1}".format(detail, timing_detail)

        if not enabled:
            status_text = "대기"
            stage_detail = "대기: 현재 세션 입력 가능 확인 후 run root를 준비합니다."
        elif action_run_root_is_stale:
            status_text = "주의"
            stage_detail = detail
        elif run_root_missing:
            status_text = "필요"
            stage_detail = detail
        else:
            status_text = "완료"
            stage_detail = detail

        return {
            "ready": run_root_ready,
            "enabled": enabled,
            "missing": run_root_missing,
            "stale": action_run_root_is_stale,
            "status_text": status_text,
            "detail": detail,
            "stage_detail": stage_detail,
            "value": value,
            "action_run_root": action_run_root,
            "uses_override": action_run_root_is_override,
        }

    def _compute_workflow_state(
        self,
        *,
        launch_status: dict[str, object],
        attach_ok: bool,
        visibility_ok: bool,
        run_root_missing: bool,
        run_root_stale: bool,
        run_root_detail: str,
        pair_enabled: bool,
        pair_in_scope: bool,
        paired_status: dict | None,
        next_actions: list[str],
    ) -> WorkflowState:
        paired_counts = (paired_status or {}).get("Counts", {})
        watcher_status = ((paired_status or {}).get("Watcher", {}) or {}).get("Status", "")
        has_recovery_issue = any(
            paired_counts.get(name, 0) > 0
            for name in ("ErrorPresentCount", "SummaryMissingCount", "SummaryStaleCount", "DoneStaleCount")
        )
        has_review_artifacts = paired_counts.get("ZipPresentCount", 0) > 0 or paired_counts.get("DonePresentCount", 0) > 0

        workflow = WorkflowState(
            overall="ready",
            label="실행 가능",
            detail="필수 준비 단계를 통과했습니다.",
            windows_ready=bool(launch_status.get("ready", False)),
            attach_ready=attach_ok,
            visibility_ready=visibility_ok,
            run_root_ready=(not run_root_missing and not run_root_stale),
            pair_ready=pair_enabled,
            next_actions=next_actions,
        )

        if not workflow.windows_ready:
            workflow.overall = "windows_missing"
            workflow.label = str(launch_status.get("workflow_label", "창 준비 안 됨"))
            workflow.detail = str(launch_status.get("workflow_detail", "현재 세션 창 준비가 필요합니다."))
            workflow.blocking_reason = str(launch_status.get("reason", "windows_missing"))
            return workflow
        if not workflow.attach_ready:
            workflow.overall = "attach_required"
            workflow.label = "대상 연결 필요"
            workflow.detail = "runtime map이 완전하지 않거나 세션이 섞여 있습니다."
            workflow.blocking_reason = "attach_required"
            return workflow
        if not workflow.visibility_ready:
            workflow.overall = "visibility_failed"
            workflow.label = "입력 가능 확인 실패"
            workflow.detail = "일부 target이 실제 입력 대상으로 확인되지 않았습니다."
            workflow.blocking_reason = "visibility_failed"
            return workflow
        if run_root_missing:
            workflow.overall = "runroot_missing"
            workflow.label = "RunRoot 준비 필요"
            workflow.detail = run_root_detail or "실행 루트가 아직 준비되지 않았습니다."
            workflow.blocking_reason = "runroot_missing"
            workflow.run_root_ready = False
            return workflow
        if run_root_stale:
            workflow.overall = "runroot_stale"
            workflow.label = "오래된 RunRoot"
            workflow.detail = run_root_detail or "현재 RunRoot는 stale 기준을 초과했습니다."
            workflow.blocking_reason = "runroot_stale"
            workflow.run_root_ready = False
            return workflow
        if not pair_in_scope:
            workflow.overall = "pair_out_of_scope"
            workflow.label = "현재 session 범위 밖"
            workflow.detail = "선택된 pair가 현재 부분 재사용 session 범위 밖에 있습니다."
            workflow.blocking_reason = "pair_out_of_scope"
            workflow.pair_ready = False
            return workflow
        if not workflow.pair_ready:
            workflow.overall = "recovery_needed"
            workflow.label = "Pair 활성 필요"
            workflow.detail = "선택된 pair가 현재 비활성 상태입니다."
            workflow.blocking_reason = "pair_disabled"
            return workflow
        if has_recovery_issue:
            workflow.overall = "recovery_needed"
            workflow.label = "복구 필요"
            workflow.detail = "실행 오류나 stale artifact가 감지됐습니다."
            workflow.blocking_reason = "paired_recovery_needed"
            return workflow
        if watcher_status in {"running", "starting", "stop_requested", "stopping"}:
            workflow.overall = "running"
            workflow.label = "실행 중"
            detail_map = {
                "running": "watcher가 현재 run root 기준으로 동작 중입니다.",
                "starting": "watcher 시작 확인을 기다리는 중입니다.",
                "stop_requested": "watcher 정지 요청이 반영되어 종료를 기다리는 중입니다.",
                "stopping": "watcher가 종료 단계에 있습니다.",
            }
            workflow.detail = detail_map.get(watcher_status, "watcher 상태를 확인 중입니다.")
            return workflow
        if has_review_artifacts:
            workflow.overall = "review_needed"
            workflow.label = "결과 검토 필요"
            workflow.detail = "최근 run 산출물이 존재합니다."
            return workflow
        return workflow

    def build_panel_state(self, *, bundle: DashboardRawBundle, selected_pair: str) -> PanelStateModel:
        effective_data = bundle.effective_data
        relay_status = bundle.relay_status
        visibility_status = bundle.visibility_status
        paired_status = bundle.paired_status

        expected_targets = int(
            visibility_status.get("ExpectedTargetCount")
            or relay_status.get("Runtime", {}).get("ExpectedTargetCount")
            or 8
        )
        binding_windows = self._binding_window_count(relay_status)
        launch_status = self._launch_window_status(
            effective_data=effective_data,
            relay_status=relay_status,
            binding_windows=binding_windows,
            expected_targets=expected_targets,
        )
        runtime = relay_status.get("Runtime", {})
        attach_status = self._attach_status(
            launch_status=launch_status,
            relay_status=relay_status,
            expected_targets=expected_targets,
        )
        visibility_stage = self._visibility_status(
            attach_status=attach_status,
            visibility_status=visibility_status,
            expected_targets=expected_targets,
        )

        run_context = effective_data.get("RunContext", {})
        selected_run_root = str(run_context.get("SelectedRunRoot", "") or "")
        run_root_status = self._run_root_status(
            effective_data=effective_data,
            visibility_stage=visibility_stage,
        )
        run_root_missing = bool(run_root_status.get("missing", False))
        run_root_stale = bool(run_root_status.get("stale", False))

        activation_map = self._pair_activation_map(effective_data)
        pair_activation = activation_map.get(selected_pair, {})
        pair_enabled = bool(pair_activation.get("EffectiveEnabled", True))
        runtime_scope = relay_status.get("Runtime", {}) if relay_status else {}
        partial_reuse = bool(runtime_scope.get("PartialReuse", False))
        active_pair_ids = self._string_list(runtime_scope.get("ActivePairIds", []))
        pair_in_scope = (not partial_reuse) or (not selected_pair) or (selected_pair in active_pair_ids)

        workflow = self._compute_workflow_state(
            launch_status=launch_status,
            attach_ok=bool(attach_status.get("ready", False)),
            visibility_ok=bool(visibility_stage.get("ready", False)),
            run_root_missing=run_root_missing,
            run_root_stale=run_root_stale,
            run_root_detail=str(run_root_status.get("detail", "")),
            pair_enabled=pair_enabled,
            pair_in_scope=pair_in_scope,
            paired_status=paired_status,
            next_actions=list(relay_status.get("NextActions", [])),
        )

        warning_summary = effective_data.get("WarningSummary", {})
        router = relay_status.get("Router", {})
        ignored_total = int((relay_status.get("Counts", {}) or {}).get("Ignored", 0) or 0)
        primary_ignored_reason = self._primary_ignored_reason(relay_status)
        paired_counts = (paired_status or {}).get("Counts", {})
        acceptance_receipt = self._load_acceptance_receipt_summary(paired_status)
        pair_stage_ready = bool(visibility_stage.get("ready", False)) and bool(run_root_status.get("ready", False))
        watcher_status = ((paired_status or {}).get("Watcher", {}) or {}).get("Status", "stopped")
        if not visibility_stage.get("ready", False):
            pair_stage_detail = "대기: 현재 세션 입력 가능 확인 후 Pair 실행을 준비합니다."
        elif not run_root_status.get("ready", False):
            pair_stage_detail = "대기: 현재 세션 RunRoot 준비 후 Pair 실행을 준비합니다."
        elif not pair_in_scope:
            pair_stage_detail = "현재 session partial reuse 범위 밖: {0} / active={1}".format(
                selected_pair or "(pair 없음)",
                ", ".join(active_pair_ids) if active_pair_ids else "(none)",
            )
        elif not pair_enabled:
            pair_stage_detail = pair_activation.get("DisableReason", "") or "선택된 pair가 현재 비활성 상태입니다."
        elif workflow.overall == "recovery_needed":
            pair_stage_detail = "{0} / watcher={1} / 복구 또는 결과 검토 후 실행 가능".format(
                selected_pair or "(pair 없음)",
                watcher_status,
            )
        else:
            pair_stage_detail = "{0} / watcher={1}".format(
                selected_pair or "(pair 없음)",
                watcher_status,
            )
        acceptance_value = "(none)"
        acceptance_detail = "visible receipt 없음"
        if acceptance_receipt.get("ParseError", ""):
            acceptance_value = "parse-error"
            acceptance_detail = str(acceptance_receipt.get("ParseError", "") or "receipt parse error")
        elif acceptance_receipt.get("Exists", "") == "true":
            acceptance_state = str(acceptance_receipt.get("AcceptanceState", "") or "")
            acceptance_stage = str(acceptance_receipt.get("Stage", "") or "")
            blocked_by = str(acceptance_receipt.get("BlockedBy", "") or "")
            blocked_target = str(acceptance_receipt.get("BlockedTargetId", "") or "")
            blocked_run_root = str(acceptance_receipt.get("BlockedRunRoot", "") or "")
            blocked_path = str(acceptance_receipt.get("BlockedPath", "") or "")
            acceptance_reason = str(acceptance_receipt.get("AcceptanceReason", "") or "")
            blocked_detail = str(acceptance_receipt.get("BlockedDetail", "") or "")
            history_count = str(acceptance_receipt.get("PhaseHistoryCount", "") or "")
            history_tail = str(acceptance_receipt.get("PhaseHistoryTail", "") or "")
            acceptance_value = blocked_by or acceptance_state or acceptance_stage or "receipt"
            detail_parts: list[str] = []
            if acceptance_stage:
                detail_parts.append("stage={0}".format(acceptance_stage))
            if blocked_target:
                detail_parts.append("target={0}".format(blocked_target))
            if blocked_run_root:
                detail_parts.append("runRoot={0}".format(blocked_run_root))
            if blocked_path:
                detail_parts.append("path={0}".format(blocked_path))
            if blocked_detail:
                detail_parts.append(blocked_detail)
            elif acceptance_reason:
                detail_parts.append(acceptance_reason)
            if history_count:
                detail_parts.append("history={0}".format(history_count))
            if history_tail:
                detail_parts.append(history_tail)
            elif str(acceptance_receipt.get("LastUpdatedAt", "") or acceptance_receipt.get("LastWriteAt", "") or ""):
                detail_parts.append(
                    "updated={0}".format(
                        str(acceptance_receipt.get("LastUpdatedAt", "") or acceptance_receipt.get("LastWriteAt", "") or "")
                    )
                )
            acceptance_detail = " / ".join(detail_parts) if detail_parts else "receipt 존재"
        cards = [
            StatusCardModel(
                key="windows",
                title=str(launch_status.get("card_title", "세션 창 준비")),
                value=f"{binding_windows}/{expected_targets}",
                detail=str(launch_status.get("card_detail", "")),
            ),
            StatusCardModel(
                key="attach",
                title="Attach 상태",
                value=f"{runtime.get('UniqueTargetCount', 0)}/{expected_targets}",
                detail=str(attach_status.get("detail", "")),
            ),
            StatusCardModel(
                key="visibility",
                title="입력 가능",
                value=f"{visibility_status.get('InjectableCount', 0)}/{expected_targets}",
                detail="fail={0} missing={1}".format(
                    visibility_status.get("NonInjectableCount", 0),
                    visibility_status.get("MissingRuntimeCount", 0),
                ),
            ),
            StatusCardModel(
                key="router",
                title="라우터",
                value=str(router.get("Status", "missing") or "missing"),
                detail=(
                    "pending={0} queue={1}{2}".format(
                        router.get("PendingQueueCount", 0),
                        router.get("QueueCount", 0),
                        (
                            ""
                            if ignored_total <= 0
                            else " ignored={0}{1}".format(
                                ignored_total,
                                (
                                    ""
                                    if primary_ignored_reason is None
                                    else " ({0} {1})".format(
                                        str(primary_ignored_reason.get("Label", "") or primary_ignored_reason.get("Code", "")),
                                        int(primary_ignored_reason.get("Count", 0) or 0),
                                    )
                                ),
                            )
                        ),
                    )
                ),
            ),
            StatusCardModel(
                key="runroot",
                title="RunRoot",
                value=str(run_root_status.get("value", "없음")),
                detail=str(run_root_status.get("detail", "")),
            ),
            StatusCardModel(
                key="warning",
                title="경고",
                value=str(warning_summary.get("HighestCode", "") or "(none)"),
                detail="severity={0} decision={1}".format(
                    warning_summary.get("HighestSeverity", "none"),
                    warning_summary.get("HighestDecision", "none"),
                ),
            ),
            StatusCardModel(
                key="acceptance",
                title="Visible Receipt",
                value=acceptance_value,
                detail=acceptance_detail,
            ),
        ]

        stages = [
            StageModel(
                key="launch_windows",
                title=str(launch_status.get("stage_title", "1. 세션 창 준비")),
                status_text=str(launch_status.get("stage_status_text", "필요")),
                detail=str(launch_status.get("stage_detail", "")),
                action_key="launch_windows",
                action_label="8창 열기",
                enabled=True,
            ),
            StageModel(
                key="attach_windows",
                title="2. 바인딩 attach",
                status_text=str(attach_status.get("status_text", "필요")),
                detail=str(attach_status.get("detail", "")),
                action_key="attach_windows",
                action_label="붙이기",
                enabled=bool(attach_status.get("enabled", False)),
            ),
            StageModel(
                key="check_visibility",
                title="3. 입력 가능 확인",
                status_text=str(visibility_stage.get("status_text", "필요")),
                detail=str(visibility_stage.get("detail", "")),
                action_key="check_visibility",
                action_label="입력 점검",
                enabled=bool(visibility_stage.get("enabled", False)),
            ),
            StageModel(
                key="prepare_run_root",
                title="4. RunRoot 준비",
                status_text=str(run_root_status.get("status_text", "필요")),
                detail=str(run_root_status.get("stage_detail", "")),
                action_key="prepare_run_root",
                action_label="run 준비",
                enabled=bool(run_root_status.get("enabled", False)),
            ),
            StageModel(
                key="pair_action",
                title="5. Headless Drill 준비",
                status_text="차단" if (not pair_enabled or not pair_in_scope) else ("완료" if workflow.overall in {"ready", "running", "review_needed"} else "대기"),
                detail=pair_stage_detail,
                action_key="enable_pair" if not pair_enabled else "run_selected_pair",
                action_label="pair 활성화" if not pair_enabled else "선택 Pair Headless Drill",
                enabled=pair_stage_ready and pair_in_scope,
            ),
        ]

        next_actions = [self._map_next_action(command_text) for command_text in workflow.next_actions[:4]]
        prioritized_issues: list[tuple[int, IssueModel]] = []

        def add_issue(priority: int, title: str, detail: str, action_key: str, action_label: str) -> None:
            prioritized_issues.append((priority, IssueModel(title, detail, action_key, action_label)))

        if not workflow.windows_ready:
            add_issue(
                10,
                str(launch_status.get("issue_title", "현재 세션 창 준비 안 됨")),
                str(launch_status.get("issue_detail", "현재 세션 기준 창 준비를 다시 확인해야 합니다.")),
                "launch_windows",
                "8창 열기",
            )
        if workflow.windows_ready and not workflow.attach_ready:
            add_issue(
                20,
                str(attach_status.get("issue_title", "대상 창 연결 안 됨")),
                str(attach_status.get("issue_detail", "runtime map이 완전하지 않거나 세션이 섞였습니다.")),
                "attach_windows",
                "붙이기",
            )
        if workflow.attach_ready and not workflow.visibility_ready:
            failed_targets = [
                row.get("TargetId", "")
                for row in visibility_status.get("Targets", [])
                if not row.get("Injectable", False)
            ]
            add_issue(
                30,
                "입력 가능 확인 실패",
                "실패 target: {0}".format(", ".join(failed_targets) or "(unknown)"),
                "check_visibility",
                "입력 점검",
            )
        if workflow.visibility_ready and run_root_missing:
            add_issue(40, "RunRoot 준비 안 됨", "현재 실행 루트가 없습니다.", "prepare_run_root", "run 준비")
        elif workflow.visibility_ready and run_root_stale:
            add_issue(50, "오래된 RunRoot", "현재 선택된 run root가 stale 기준을 넘었습니다.", "prepare_run_root", "새 RunRoot 준비")
        if bool(run_root_status.get("ready", False)) and not pair_enabled:
            add_issue(
                60,
                "Pair 비활성 상태",
                pair_activation.get("DisableReason", "") or "선택한 pair가 비활성입니다.",
                "enable_pair",
                "pair 활성화",
            )
        if bool(run_root_status.get("ready", False)) and not pair_in_scope:
            add_issue(
                65,
                "현재 session 범위 밖 pair",
                "활성 pair: {0}".format(", ".join(active_pair_ids) if active_pair_ids else "(none)"),
                "run_paired_status",
                "Pair 상태 보기",
            )
        if ignored_total > 0 and primary_ignored_reason is not None:
            ignored_code = str(primary_ignored_reason.get("Code", "") or "")
            ignored_count = int(primary_ignored_reason.get("Count", 0) or 0)
            ignored_label = str(primary_ignored_reason.get("Label", "") or ignored_code)
            if ignored_code in {"metadata-missing", "metadata-missing-fields", "paired-metadata-missing-fields", "metadata-parse-failed", "metadata-target-mismatch", "message-type-unsupported"}:
                add_issue(
                    66,
                    "relay 메타 오류로 ready 무시됨",
                    "{0} {1}건 포함, ignored 총 {2}건입니다.".format(ignored_label, ignored_count, ignored_total),
                    "run_relay_status",
                    "Relay 상태 보기",
                )
            elif ignored_code == "launcher-session-mismatch":
                add_issue(
                    67,
                    "다른 세션 ready 무시됨",
                    "{0} {1}건 포함, ignored 총 {2}건입니다.".format(ignored_label, ignored_count, ignored_total),
                    "run_relay_status",
                    "Relay 상태 보기",
                )
            elif ignored_code in {"archive-metadata-missing", "archive-metadata-parse-failed"}:
                add_issue(
                    68,
                    "ignored archive 메타 점검 필요",
                    "{0} {1}건이 있습니다. ignored archive 메타를 확인하세요.".format(ignored_label, ignored_count),
                    "run_relay_status",
                    "Relay 상태 보기",
                )
            elif ignored_code == "preexisting-before-router-start":
                add_issue(
                    115,
                    "이전 ready 자동 무시",
                    "{0} {1}건을 무시했습니다. router 시작 전 backlog 분리 동작입니다.".format(ignored_label, ignored_count),
                    "run_relay_status",
                    "Relay 상태 보기",
                )
        if paired_status:
            handoff_ready_count = int(
                paired_counts.get("HandoffReadyCount", paired_counts.get("ReadyToForwardCount", 0)) or 0
            )
            watcher_row = ((paired_status.get("Watcher", {}) or {}))
            watcher_stop_category = str(watcher_row.get("StopCategory", "") or "")
            watcher_status = str(watcher_row.get("Status", "") or "")
            acceptance_state = str(acceptance_receipt.get("AcceptanceState", "") or "")
            blocked_by = str(acceptance_receipt.get("BlockedBy", "") or "")
            blocked_target = str(acceptance_receipt.get("BlockedTargetId", "") or "")
            blocked_run_root = str(acceptance_receipt.get("BlockedRunRoot", "") or "")
            blocked_path = str(acceptance_receipt.get("BlockedPath", "") or "")
            blocked_detail = str(acceptance_receipt.get("BlockedDetail", "") or "")
            acceptance_reason = str(acceptance_receipt.get("AcceptanceReason", "") or "")
            history_tail = str(acceptance_receipt.get("PhaseHistoryTail", "") or "")
            if handoff_ready_count > 0:
                add_issue(
                    70,
                    "다음 전달 가능 target 존재",
                    "다음 전달 가능 target {0}개가 있어 먼저 검토가 필요합니다.".format(handoff_ready_count),
                    "focus_ready_to_forward_artifact",
                    "전달 가능 target 보기",
                )
            if blocked_by:
                detail_parts = [blocked_by]
                if blocked_target:
                    detail_parts.append("target={0}".format(blocked_target))
                if blocked_run_root:
                    detail_parts.append("runRoot={0}".format(blocked_run_root))
                if blocked_path:
                    detail_parts.append("path={0}".format(blocked_path))
                if blocked_detail:
                    detail_parts.append(blocked_detail)
                if history_tail:
                    detail_parts.append(history_tail)
                add_issue(
                    72,
                    "Visible preflight 차단",
                    " / ".join(detail_parts),
                    "visible_preflight",
                    "visible preflight-only",
                )
            elif acceptance_state == "preflight-passed":
                add_issue(
                    73,
                    "Visible preflight 완료",
                    acceptance_reason or "공식 창 기준 preflight-only는 통과했고 active acceptance가 아직 실행되지 않았습니다.",
                    "visible_active_acceptance",
                    "active visible acceptance",
                )
            elif acceptance_state == "error":
                add_issue(
                    74,
                    "Visible acceptance 실패",
                    acceptance_reason or "live acceptance receipt가 error 상태입니다.",
                    "visible_active_acceptance",
                    "active visible acceptance",
                )
            elif acceptance_state == "pending":
                add_issue(
                    75,
                    "Visible acceptance 대기",
                    acceptance_reason or "live acceptance receipt가 pending 상태입니다.",
                    "visible_confirm",
                    "shared visible confirm",
                )
            if paired_counts.get("ErrorPresentCount", 0) > 0:
                add_issue(80, "실행 오류 감지", "error marker가 존재합니다.", "run_paired_status", "Pair 상태 보기")
            elif paired_counts.get("SummaryStaleCount", 0) > 0 or paired_counts.get("SummaryMissingCount", 0) > 0:
                add_issue(90, "summary 점검 필요", "summary missing/stale 상태가 있습니다.", "run_paired_status", "Pair 상태 보기")
            elif watcher_status == "stopped" and selected_run_root:
                if watcher_stop_category == "expected-limit":
                    add_issue(
                        100,
                        "watcher 정상 제한 종료",
                        "forward 한도에 도달해 정지했습니다. 계속 진행하려면 watch를 다시 시작하세요.",
                        "start_watcher",
                        "watch 다시 시작",
                    )
                else:
                    add_issue(100, "watcher 중지", "현재 run root 기준 watcher가 실행 중이 아닙니다.", "start_watcher", "watch 시작")
            elif watcher_status in ("stop_requested", "stopping", "starting"):
                add_issue(110, "watch 제어 진행 중", "watcher 상태 전이를 확인하는 중입니다.", "run_paired_status", "Pair 상태 보기")

        pair_target_map = self._pair_target_map(paired_status)
        pair_status_map = self._pair_status_map(paired_status)
        pair_summaries: list[PairSummaryModel] = []
        for pair in effective_data.get("OverviewPairs", []):
            pair_id = str(pair.get("PairId", ""))
            if not pair_id:
                continue
            rows = pair_target_map.get(pair_id, [])
            pair_status_row = pair_status_map.get(pair_id, {})
            activation = activation_map.get(pair_id, {})
            latest_states = sorted({str(row.get("LatestState", "")) for row in rows if row.get("LatestState", "")})
            zip_count = sum(int(row.get("ZipCount", 0) or 0) for row in rows)
            failure_count = sum(int(row.get("FailureCount", 0) or 0) for row in rows)
            handoff_ready_count = sum(
                1
                for row in rows
                if (
                    str(row.get("SourceOutboxNextAction", "") or "").strip() == "handoff-ready"
                    or (
                        not str(row.get("SourceOutboxNextAction", "") or "").strip()
                        and str(row.get("LatestState", "") or "").strip() == "ready-to-forward"
                    )
                )
            )
            dispatch_running_count = sum(1 for row in rows if str(row.get("DispatchState", "") or "").strip() == "running")
            dispatch_failed_count = sum(1 for row in rows if str(row.get("DispatchState", "") or "").strip() == "failed")
            error_present_count = sum(1 for row in rows if bool(row.get("ErrorPresent", False)))
            current_phase = ""
            next_expected_handoff = ""
            if pair_status_row:
                state_text = str(pair_status_row.get("LatestStateSummary", "") or pair_status_row.get("LatestState", "") or "")
                if not state_text:
                    state_text = ", ".join(latest_states) if latest_states else "no-run"
                roundtrip_count = int(pair_status_row.get("RoundtripCount", 0) or 0)
                forwarded_state_count = int(pair_status_row.get("ForwardedStateCount", 0) or 0)
                handoff_ready_count = int(pair_status_row.get("HandoffReadyCount", handoff_ready_count) or 0)
                next_action = str(pair_status_row.get("NextAction", "") or "")
                current_phase = self._normalize_pair_phase(
                    pair_status_row.get("CurrentPhase", ""),
                    watcher_status=watcher_status,
                    next_action=next_action,
                    reached_roundtrip_limit=bool(pair_status_row.get("ReachedRoundtripLimit", False)),
                )
                next_expected_handoff = str(pair_status_row.get("NextExpectedHandoff", "") or "")
                detail_text = str(pair_status_row.get("ProgressDetail", "") or "").strip()
                if not detail_text:
                    detail_parts = [
                        "상태={0}".format(state_text),
                        "왕복={0}".format(roundtrip_count),
                        "forwardedState={0}".format(forwarded_state_count),
                    ]
                    if current_phase:
                        detail_parts.append("단계={0}".format(current_phase))
                    if next_expected_handoff:
                        detail_parts.append("예정={0}".format(next_expected_handoff))
                    if next_action:
                        detail_parts.append("다음={0}".format(next_action))
                    detail_text = " ".join(detail_parts)
            else:
                state_text = ", ".join(latest_states) if latest_states else "no-run"
                forwarded_state_count = sum(1 for row in rows if str(row.get("LatestState", "") or "").strip() == "forwarded")
                roundtrip_count = forwarded_state_count // 2
                next_action = self._derive_pair_next_action(
                    latest_states=latest_states,
                    handoff_ready_count=handoff_ready_count,
                    dispatch_running_count=dispatch_running_count,
                    dispatch_failed_count=dispatch_failed_count,
                    failure_count=failure_count,
                    zip_count=zip_count,
                    error_present_count=error_present_count,
                )
                current_phase = self._normalize_pair_phase(
                    current_phase,
                    watcher_status=watcher_status,
                    next_action=next_action,
                )
                detail_parts = [
                    "상태={0}".format(state_text),
                    "왕복={0}".format(roundtrip_count),
                    "forwardedState={0}".format(forwarded_state_count),
                    "zip={0}".format(zip_count),
                    "fail={0}".format(failure_count),
                ]
                if current_phase:
                    detail_parts.append("단계={0}".format(current_phase))
                if handoff_ready_count > 0:
                    detail_parts.append("전달가능={0}".format(handoff_ready_count))
                if dispatch_running_count > 0:
                    detail_parts.append("실행중={0}".format(dispatch_running_count))
                if dispatch_failed_count > 0:
                    detail_parts.append("실패={0}".format(dispatch_failed_count))
                if next_action:
                    detail_parts.append("다음={0}".format(next_action))
                detail_text = " ".join(detail_parts)
            pair_summaries.append(
                PairSummaryModel(
                    pair_id=pair_id,
                    targets="{0} ↔ {1}".format(pair.get("TopTargetId", ""), pair.get("BottomTargetId", "")),
                    enabled=bool(activation.get("EffectiveEnabled", True)),
                    latest_state=state_text,
                    zip_count=zip_count,
                    failure_count=failure_count,
                    lane_watcher_status=watcher_status if paired_status else "stopped",
                    detail=detail_text,
                    roundtrip_count=roundtrip_count,
                    forwarded_state_count=forwarded_state_count,
                    handoff_ready_count=handoff_ready_count,
                    current_phase=current_phase,
                    next_expected_handoff=next_expected_handoff,
                    next_action=next_action,
                )
            )

        return PanelStateModel(
            workflow=workflow,
            cards=cards,
            stages=stages,
            next_actions=next_actions,
            issues=[issue for _priority, issue in sorted(prioritized_issues, key=lambda item: item[0])][:4],
            pairs=pair_summaries,
        )
