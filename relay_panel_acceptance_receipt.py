from __future__ import annotations

import json
from collections.abc import Mapping
from pathlib import Path

from relay_panel_operator_state import (
    VISIBLE_ACCEPTANCE_ACTIVE_STATES,
    VISIBLE_ACCEPTANCE_SUCCESS_STATES,
)

VISIBLE_ACCEPTANCE_PREFLIGHT_PASSED_STAGES = {
    "visible-worker-ready",
    "typed-window-ready",
    "typed-window-bootstrap",
    "typed-window-bootstrap-failed",
    "typed-window-bootstrapped",
    "watcher-ready",
    "submit-running",
    "seed-finished",
    "publish-checking",
    "publish-checked",
    "seed-pending",
    "acceptance-failed",
    "handoff-checking",
    "closeout-running",
    "closeout-completed",
}


def stringify_optional(raw: object) -> str:
    if raw is None:
        return ""
    text = str(raw)
    return text if text else ""


def optional_bool(raw: object) -> bool | None:
    if isinstance(raw, bool):
        return raw
    text = stringify_optional(raw).strip().lower()
    if text in {"true", "1", "yes"}:
        return True
    if text in {"false", "0", "no"}:
        return False
    return None


def summary_bool(raw: object) -> str:
    value = optional_bool(raw)
    if value is None:
        return ""
    return "true" if value else "false"


def acceptance_receipt_path_for_run_root(run_root: str) -> str:
    normalized = stringify_optional(run_root).strip()
    if not normalized:
        return ""
    return str(Path(normalized) / ".state" / "live-acceptance-result.json")


def empty_acceptance_receipt_summary(
    *,
    path: str = "",
    exists: bool = False,
    parse_error: str = "",
    last_write_at: str = "",
) -> dict[str, str]:
    return {
        "Path": str(path or ""),
        "Exists": "true" if exists else "false",
        "ParseError": str(parse_error or ""),
        "LastWriteAt": str(last_write_at or ""),
        "LastUpdatedAt": "",
        "GeneratedAt": "",
        "Stage": "",
        "AcceptanceState": "",
        "AcceptanceReason": "",
        "BlockedBy": "",
        "BlockedTargetId": "",
        "BlockedRunRoot": "",
        "BlockedPath": "",
        "BlockedDetail": "",
        "PhaseHistoryCount": "",
        "PhaseHistoryTail": "",
        "HasSuccessHistory": "false",
        "HasActiveHistory": "false",
        "LastSuccessAcceptanceState": "",
        "PreflightPassed": "",
        "ActiveAttempted": "",
        "PostCleanupDone": "",
        "CleanPreflightPassed": "",
        "ActiveWindowSummary": "",
        "ActiveWindowSnapshot": "",
        "ActiveWindowIsOfficialTarget": "",
        "ActiveWindowTargetId": "",
        "RecoveryAttemptCount": "",
        "LastRecoveryAttemptId": "",
        "LastRecoveryAction": "",
        "LastRecoveryRequestedAt": "",
        "LastRecoveryCompletedAt": "",
        "LastRecoveryResult": "",
        "LastRecoveryTargetId": "",
        "LastRecoveryReason": "",
        "VisibleProofGrade": "",
        "VisibleProofGradeReason": "",
        "VisibleProofGradeUpdatedAt": "",
        **empty_acceptance_relay_issue_fields(),
    }


def empty_acceptance_relay_issue_fields() -> dict[str, str]:
    return {
        "RelayFolderMismatchCount": "",
        "RelayFolderMissingCount": "",
        "RelayFolderConfigMissingCount": "",
        "RelayIssueSummary": "",
        "RelayIssuesSource": "",
    }


def summarize_acceptance_receipt_payload(
    payload: Mapping[str, object] | None,
    *,
    path: str = "",
    exists: bool = True,
    parse_error: str = "",
    last_write_at: str = "",
    fallback_acceptance_state: str = "",
    fallback_acceptance_reason: str = "",
) -> dict[str, str]:
    source = payload if isinstance(payload, Mapping) else {}
    outcome = source.get("Outcome", {}) if isinstance(source.get("Outcome", {}), Mapping) else {}
    relay_issues = source.get("RelayIssues", {}) if isinstance(source.get("RelayIssues", {}), Mapping) else {}
    phase_history = source.get("PhaseHistory", [])
    if not isinstance(phase_history, list):
        phase_history = []

    history_tail_entries: list[str] = []
    for entry in phase_history[-4:]:
        if not isinstance(entry, Mapping):
            continue
        stage = stringify_optional(entry.get("Stage", ""))
        state = stringify_optional(entry.get("AcceptanceState", ""))
        if stage and state:
            history_tail_entries.append(f"{stage}:{state}")
        elif stage:
            history_tail_entries.append(stage)
        elif state:
            history_tail_entries.append(state)

    current_state = stringify_optional(outcome.get("AcceptanceState", "")) or stringify_optional(fallback_acceptance_state)
    current_reason = stringify_optional(outcome.get("AcceptanceReason", "")) or stringify_optional(fallback_acceptance_reason)
    preflight = source.get("Preflight", {}) if isinstance(source.get("Preflight", {}), Mapping) else {}
    active_window_snapshot = (
        stringify_optional(source.get("ActiveWindowSnapshot", ""))
        or stringify_optional(preflight.get("ActiveWindowSnapshot", ""))
    )
    active_window_summary = (
        stringify_optional(source.get("ActiveWindowSummary", ""))
        or stringify_optional(preflight.get("ActiveWindowSummary", ""))
        or active_window_snapshot
    )
    active_window_is_official_target = summary_bool(
        source.get("ActiveWindowIsOfficialTarget", preflight.get("ActiveWindowIsOfficialTarget", None))
    )
    active_window_target_id = (
        stringify_optional(source.get("ActiveWindowTargetId", ""))
        or stringify_optional(preflight.get("ActiveWindowTargetId", ""))
    )
    all_states = [stringify_optional(entry.get("AcceptanceState", "")) for entry in phase_history if isinstance(entry, Mapping)]
    all_states = [state for state in all_states if state]
    if current_state:
        all_states.append(current_state)
    success_states = [state for state in all_states if state in VISIBLE_ACCEPTANCE_SUCCESS_STATES]
    active_states = [state for state in all_states if state in VISIBLE_ACCEPTANCE_ACTIVE_STATES]

    return {
        "Path": str(path or ""),
        "Exists": "true" if exists else "false",
        "ParseError": str(parse_error or ""),
        "LastWriteAt": str(last_write_at or ""),
        "LastUpdatedAt": stringify_optional(source.get("LastUpdatedAt", "")),
        "GeneratedAt": stringify_optional(source.get("GeneratedAt", "")),
        "Stage": stringify_optional(source.get("Stage", "")),
        "AcceptanceState": current_state,
        "AcceptanceReason": current_reason,
        "BlockedBy": stringify_optional(source.get("BlockedBy", "")),
        "BlockedTargetId": stringify_optional(source.get("BlockedTargetId", "")),
        "BlockedRunRoot": stringify_optional(source.get("BlockedRunRoot", "")),
        "BlockedPath": stringify_optional(source.get("BlockedPath", "")),
        "BlockedDetail": stringify_optional(source.get("BlockedDetail", "")),
        "PhaseHistoryCount": str(len(phase_history)),
        "PhaseHistoryTail": " -> ".join(history_tail_entries),
        "HasSuccessHistory": "true" if success_states else "false",
        "HasActiveHistory": "true" if active_states else "false",
        "LastSuccessAcceptanceState": success_states[-1] if success_states else "",
        "PreflightPassed": summary_bool(source.get("PreflightPassed", None)),
        "ActiveAttempted": summary_bool(source.get("ActiveAttempted", None)),
        "PostCleanupDone": summary_bool(source.get("PostCleanupDone", None)),
        "CleanPreflightPassed": summary_bool(source.get("CleanPreflightPassed", None)),
        "ActiveWindowSummary": active_window_summary,
        "ActiveWindowSnapshot": active_window_snapshot,
        "ActiveWindowIsOfficialTarget": active_window_is_official_target,
        "ActiveWindowTargetId": active_window_target_id,
        "RecoveryAttemptCount": stringify_optional(source.get("RecoveryAttemptCount", "")),
        "LastRecoveryAttemptId": stringify_optional(source.get("LastRecoveryAttemptId", "")),
        "LastRecoveryAction": stringify_optional(source.get("LastRecoveryAction", "")),
        "LastRecoveryRequestedAt": stringify_optional(source.get("LastRecoveryRequestedAt", "")),
        "LastRecoveryCompletedAt": stringify_optional(source.get("LastRecoveryCompletedAt", "")),
        "LastRecoveryResult": stringify_optional(source.get("LastRecoveryResult", "")),
        "LastRecoveryTargetId": stringify_optional(source.get("LastRecoveryTargetId", "")),
        "LastRecoveryReason": stringify_optional(source.get("LastRecoveryReason", "")),
        "VisibleProofGrade": stringify_optional(source.get("VisibleProofGrade", "")),
        "VisibleProofGradeReason": stringify_optional(source.get("VisibleProofGradeReason", "")),
        "VisibleProofGradeUpdatedAt": stringify_optional(source.get("VisibleProofGradeUpdatedAt", "")),
        **summarize_acceptance_relay_issue_fields(relay_issues),
    }


def load_acceptance_receipt_summary_from_path(
    path: str,
    *,
    exists: bool = False,
    parse_error: str = "",
    last_write_at: str = "",
    fallback_acceptance_state: str = "",
    fallback_acceptance_reason: str = "",
) -> dict[str, str]:
    normalized_path = stringify_optional(path).strip()

    def _apply_fallback(summary: dict[str, str]) -> dict[str, str]:
        result = dict(summary)
        if fallback_acceptance_state and not stringify_optional(result.get("AcceptanceState", "")):
            result["AcceptanceState"] = stringify_optional(fallback_acceptance_state)
        if fallback_acceptance_reason and not stringify_optional(result.get("AcceptanceReason", "")):
            result["AcceptanceReason"] = stringify_optional(fallback_acceptance_reason)
        return result

    if not normalized_path:
        return _apply_fallback(
            empty_acceptance_receipt_summary(
                path="",
                exists=exists,
                parse_error=parse_error,
                last_write_at=last_write_at,
            )
        )

    receipt_path = Path(normalized_path)
    if not receipt_path.exists():
        return _apply_fallback(
            empty_acceptance_receipt_summary(
                path=str(receipt_path),
                exists=exists,
                parse_error=parse_error,
                last_write_at=last_write_at,
            )
        )

    try:
        payload = json.loads(receipt_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return _apply_fallback(
            empty_acceptance_receipt_summary(
                path=str(receipt_path),
                exists=True,
                parse_error=parse_error or str(exc),
                last_write_at=last_write_at,
            )
        )

    if not isinstance(payload, Mapping):
        return _apply_fallback(
            empty_acceptance_receipt_summary(
                path=str(receipt_path),
                exists=True,
                parse_error=parse_error or "receipt payload must be an object",
                last_write_at=last_write_at,
            )
        )

    return summarize_acceptance_receipt_payload(
        payload,
        path=str(receipt_path),
        exists=True,
        parse_error=parse_error,
        last_write_at=last_write_at,
        fallback_acceptance_state=fallback_acceptance_state,
        fallback_acceptance_reason=fallback_acceptance_reason,
    )


def load_acceptance_receipt_summary_from_run_root(
    run_root: str,
    *,
    fallback_acceptance_state: str = "",
    fallback_acceptance_reason: str = "",
) -> dict[str, str]:
    return load_acceptance_receipt_summary_from_path(
        acceptance_receipt_path_for_run_root(run_root),
        fallback_acceptance_state=fallback_acceptance_state,
        fallback_acceptance_reason=fallback_acceptance_reason,
    )


def acceptance_receipt_summary_indicates_success(receipt_summary: Mapping[str, object] | None) -> bool:
    summary = receipt_summary if isinstance(receipt_summary, Mapping) else {}
    acceptance_state = stringify_optional(summary.get("AcceptanceState", ""))
    last_success_state = stringify_optional(summary.get("LastSuccessAcceptanceState", ""))
    has_success_history = stringify_optional(summary.get("HasSuccessHistory", "")).lower() == "true"
    return bool(
        has_success_history
        or acceptance_state in VISIBLE_ACCEPTANCE_SUCCESS_STATES
        or last_success_state in VISIBLE_ACCEPTANCE_SUCCESS_STATES
    )


def resolve_acceptance_receipt_workflow_flags(receipt_summary: Mapping[str, object] | None) -> dict[str, bool]:
    summary = receipt_summary if isinstance(receipt_summary, Mapping) else {}
    acceptance_state = stringify_optional(summary.get("AcceptanceState", ""))
    stage = stringify_optional(summary.get("Stage", ""))
    phase_history_tail = stringify_optional(summary.get("PhaseHistoryTail", "")).lower()
    has_success_history = stringify_optional(summary.get("HasSuccessHistory", "")).lower() == "true"
    has_active_history = stringify_optional(summary.get("HasActiveHistory", "")).lower() == "true"

    explicit_preflight_passed = optional_bool(summary.get("PreflightPassed", None))
    explicit_active_attempted = optional_bool(summary.get("ActiveAttempted", None))
    explicit_post_cleanup_done = optional_bool(summary.get("PostCleanupDone", None))
    explicit_clean_preflight_passed = optional_bool(summary.get("CleanPreflightPassed", None))

    clean_preflight_passed = (
        explicit_clean_preflight_passed
        if explicit_clean_preflight_passed is not None
        else bool(acceptance_state == "preflight-passed" and has_success_history)
    )
    active_attempted = (
        explicit_active_attempted
        if explicit_active_attempted is not None
        else bool(has_active_history)
    )
    preflight_passed = (
        explicit_preflight_passed
        if explicit_preflight_passed is not None
        else bool(
            acceptance_state == "preflight-passed"
            or active_attempted
            or has_success_history
            or stage in VISIBLE_ACCEPTANCE_PREFLIGHT_PASSED_STAGES
        )
    )
    post_cleanup_history_seen = bool(stage == "post-cleanup" or "post-cleanup" in phase_history_tail)
    post_cleanup_done = (
        explicit_post_cleanup_done
        if explicit_post_cleanup_done is not None
        else bool(post_cleanup_history_seen)
    )

    return {
        "PreflightPassed": bool(preflight_passed),
        "ActiveAttempted": bool(active_attempted),
        "PostCleanupDone": bool(post_cleanup_done),
        "CleanPreflightPassed": bool(clean_preflight_passed),
    }


def visible_confirm_payload_passed(payload: Mapping[str, object] | None) -> bool:
    source = payload if isinstance(payload, Mapping) else {}
    explicit_confirm_passed = optional_bool(source.get("ConfirmPassed", None))
    if explicit_confirm_passed is not None:
        return explicit_confirm_passed

    checks = source.get("Checks", [])
    overall = stringify_optional(source.get("Overall", "")).strip().lower()
    if overall in {"success", "passed", "pass"}:
        return True
    if overall in {"failing", "failed", "error"}:
        return False

    summary = source.get("Summary", {}) if isinstance(source.get("Summary", {}), Mapping) else {}
    summary_overall = stringify_optional(summary.get("OverallState", "")).strip().lower()
    if summary_overall == "success":
        return True

    required_check_present = False
    if isinstance(checks, list):
        for item in checks:
            if not isinstance(item, Mapping):
                continue
            if not bool(item.get("Required", False)):
                continue
            required_check_present = True
            if not bool(item.get("Passed", False)):
                return False
        if required_check_present:
            return True

    return False


def visible_receipt_confirm_payload_passed(payload: Mapping[str, object] | None) -> bool:
    source = payload if isinstance(payload, Mapping) else {}
    explicit_receipt_confirm_passed = optional_bool(source.get("ReceiptConfirmPassed", None))
    if explicit_receipt_confirm_passed is not None:
        return explicit_receipt_confirm_passed
    return visible_confirm_payload_passed(source)


def summarize_acceptance_relay_issue_fields(relay_issues: Mapping[str, object] | None) -> dict[str, str]:
    source = relay_issues if isinstance(relay_issues, Mapping) else {}
    return {
        "RelayFolderMismatchCount": stringify_optional(source.get("RelayFolderMismatchCount", "")),
        "RelayFolderMissingCount": stringify_optional(source.get("RelayFolderMissingCount", "")),
        "RelayFolderConfigMissingCount": stringify_optional(source.get("RelayFolderConfigMissingCount", "")),
        "RelayIssueSummary": stringify_optional(source.get("RelayIssueSummary", "")),
        "RelayIssuesSource": stringify_optional(source.get("RelayIssuesSource", source.get("Source", ""))),
    }


def format_acceptance_relay_issue_detail_parts(receipt_summary: Mapping[str, object] | None) -> list[str]:
    summary = receipt_summary if isinstance(receipt_summary, Mapping) else {}
    relay_issue_summary = stringify_optional(summary.get("RelayIssueSummary", ""))
    relay_source = stringify_optional(summary.get("RelayIssuesSource", summary.get("Source", "")))
    relay_mismatch_count = stringify_optional(summary.get("RelayFolderMismatchCount", ""))
    relay_missing_count = stringify_optional(summary.get("RelayFolderMissingCount", ""))
    relay_config_missing_count = stringify_optional(summary.get("RelayFolderConfigMissingCount", ""))
    detail_parts: list[str] = []
    if relay_issue_summary:
        detail_parts.append("relay={0}".format(relay_issue_summary))
    if relay_mismatch_count or relay_missing_count or relay_config_missing_count:
        detail_parts.append(
            "relayMismatch={0} relayMissing={1} relayConfigMissing={2}".format(
                relay_mismatch_count or "0",
                relay_missing_count or "0",
                relay_config_missing_count or "0",
            )
        )
    if relay_source:
        detail_parts.append("relaySource={0}".format(relay_source))
    return detail_parts


def format_acceptance_recovery_detail_parts(receipt_summary: Mapping[str, object] | None) -> list[str]:
    summary = receipt_summary if isinstance(receipt_summary, Mapping) else {}
    recovery_count = stringify_optional(summary.get("RecoveryAttemptCount", ""))
    recovery_action = stringify_optional(summary.get("LastRecoveryAction", ""))
    recovery_result = stringify_optional(summary.get("LastRecoveryResult", ""))
    recovery_target = stringify_optional(summary.get("LastRecoveryTargetId", ""))
    recovery_reason = stringify_optional(summary.get("LastRecoveryReason", ""))
    proof_grade = stringify_optional(summary.get("VisibleProofGrade", ""))
    proof_reason = stringify_optional(summary.get("VisibleProofGradeReason", ""))
    requested_at = stringify_optional(summary.get("LastRecoveryRequestedAt", ""))
    completed_at = stringify_optional(summary.get("LastRecoveryCompletedAt", ""))
    detail_parts: list[str] = []
    if proof_grade:
        detail_parts.append("visibleProofGrade={0}".format(proof_grade))
    if proof_reason and proof_reason != recovery_reason:
        detail_parts.append("visibleProofReason={0}".format(proof_reason))
    if recovery_count or recovery_action or recovery_result:
        detail_parts.append(
            "recovery={0} action={1} result={2} target={3}".format(
                recovery_count or "0",
                recovery_action or "(none)",
                recovery_result or "(none)",
                recovery_target or "(none)",
            )
        )
    if requested_at or completed_at:
        detail_parts.append(
            "recoveryRequested={0} recoveryCompleted={1}".format(
                requested_at or "(none)",
                completed_at or "(none)",
            )
        )
    if recovery_reason:
        detail_parts.append("recoveryReason={0}".format(recovery_reason))
    return detail_parts


def format_acceptance_receipt_detail_lines(
    receipt_summary: Mapping[str, object] | None,
    *,
    include_blocked_target: bool = True,
    include_blocked_run_root: bool = False,
    include_blocked_path: bool = False,
    include_history: bool = False,
    relay_prefix: str = "",
) -> list[str]:
    summary = receipt_summary if isinstance(receipt_summary, Mapping) else {}
    lines: list[str] = []
    blocked_by = stringify_optional(summary.get("BlockedBy", ""))
    blocked_target = stringify_optional(summary.get("BlockedTargetId", ""))
    blocked_run_root = stringify_optional(summary.get("BlockedRunRoot", ""))
    blocked_path = stringify_optional(summary.get("BlockedPath", ""))
    blocked_detail = stringify_optional(summary.get("BlockedDetail", ""))
    phase_history_count = stringify_optional(summary.get("PhaseHistoryCount", ""))
    phase_history_tail = stringify_optional(summary.get("PhaseHistoryTail", ""))
    active_window_summary = stringify_optional(summary.get("ActiveWindowSummary", ""))
    active_window_official = stringify_optional(summary.get("ActiveWindowIsOfficialTarget", ""))
    active_window_target = stringify_optional(summary.get("ActiveWindowTargetId", ""))
    if blocked_by:
        lines.append("BlockedBy: {0}".format(blocked_by))
        if include_blocked_target:
            lines.append("BlockedTargetId: {0}".format(blocked_target or "(없음)"))
        if include_blocked_run_root:
            lines.append("BlockedRunRoot: {0}".format(blocked_run_root or "(없음)"))
        if include_blocked_path:
            lines.append("BlockedPath: {0}".format(blocked_path or "(없음)"))
        lines.append("BlockedDetail: {0}".format(blocked_detail or "(없음)"))
    relay_lines = format_acceptance_relay_issue_detail_parts(summary)
    if relay_prefix:
        relay_lines = ["{0} {1}".format(relay_prefix, line) for line in relay_lines]
    lines.extend(relay_lines)
    if active_window_summary:
        lines.append("ActiveWindow: {0}".format(active_window_summary))
        if active_window_official:
            lines.append("ActiveWindowOfficialTarget: {0}".format(active_window_official))
        if active_window_target:
            lines.append("ActiveWindowTargetId: {0}".format(active_window_target))
    lines.extend(format_acceptance_recovery_detail_parts(summary))
    if include_history:
        if phase_history_count:
            lines.append("PhaseHistoryCount: {0}".format(phase_history_count))
        if phase_history_tail:
            lines.append("PhaseHistoryTail: {0}".format(phase_history_tail))
    return lines


def format_acceptance_receipt_section_lines(
    receipt_summary: Mapping[str, object] | None,
    *,
    path_label: str = "Path",
    state_label: str = "AcceptanceState",
    include_path: bool = True,
    include_stage: bool = True,
    include_reason: bool = True,
    include_last_updated: bool = True,
    include_blocked_target: bool = True,
    include_blocked_run_root: bool = False,
    include_blocked_path: bool = False,
    include_history: bool = False,
    relay_prefix: str = "",
) -> list[str]:
    summary = receipt_summary if isinstance(receipt_summary, Mapping) else {}
    lines: list[str] = []
    path_value = stringify_optional(summary.get("Path", ""))
    stage_value = stringify_optional(summary.get("Stage", ""))
    state_value = stringify_optional(summary.get("AcceptanceState", ""))
    reason_value = stringify_optional(summary.get("AcceptanceReason", ""))
    updated_value = stringify_optional(summary.get("LastUpdatedAt", ""))
    if include_path:
        lines.append("{0}: {1}".format(path_label, path_value or "(없음)"))
    if include_stage:
        lines.append("Stage: {0}".format(stage_value or "(없음)"))
    lines.append("{0}: {1}".format(state_label, state_value or "(없음)"))
    if include_reason:
        lines.append("AcceptanceReason: {0}".format(reason_value or "(없음)"))
    if include_last_updated:
        lines.append("LastUpdatedAt: {0}".format(updated_value or "(없음)"))
    lines.extend(
        format_acceptance_receipt_detail_lines(
            summary,
            include_blocked_target=include_blocked_target,
            include_blocked_run_root=include_blocked_run_root,
            include_blocked_path=include_blocked_path,
            include_history=include_history,
            relay_prefix=relay_prefix,
        )
    )
    return lines


def format_acceptance_phase_history_lines(
    phase_history: object,
    *,
    header_label: str = "RecentPhases:",
    max_entries: int = 5,
) -> list[str]:
    if not isinstance(phase_history, list) or not phase_history:
        return []
    if max_entries <= 0:
        max_entries = 5
    lines = [header_label]
    for entry in phase_history[-max_entries:]:
        if not isinstance(entry, Mapping):
            continue
        lines.append(
            "- {recorded} stage={stage} state={state} blocked={blocked}".format(
                recorded=stringify_optional(entry.get("RecordedAt", "")) or "(time)",
                stage=stringify_optional(entry.get("Stage", "")) or "(none)",
                state=stringify_optional(entry.get("AcceptanceState", "")) or "(none)",
                blocked=stringify_optional(entry.get("BlockedBy", "")) or "(none)",
            )
        )
    return lines if len(lines) > 1 else []
