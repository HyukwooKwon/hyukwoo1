from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field

from relay_panel_acceptance_receipt import (
    empty_acceptance_receipt_summary,
    format_acceptance_relay_issue_detail_parts,
    resolve_acceptance_receipt_workflow_flags,
    summarize_acceptance_receipt_payload,
)
from relay_panel_operator_state import (
    VisibleAcceptanceState,
    VisibleAcceptanceWorkflowProgress,
)


@dataclass(frozen=True)
class VisibleAcceptanceInputs:
    config_present: bool
    pair_id: str = ""
    seed_target_id: str = ""
    pair_enabled: bool = True
    pair_scope_allowed: bool = True
    pair_scope_detail: str = ""
    action_run_root: str = ""
    active_run_root: str = ""
    active_run_root_detail: str = ""
    confirm_run_root: str = ""
    confirm_run_root_detail: str = ""
    receipt_summary: Mapping[str, str] = field(default_factory=dict)
    progress: VisibleAcceptanceWorkflowProgress = field(default_factory=VisibleAcceptanceWorkflowProgress)
    busy: bool = False
    last_result_text: str = ""
    disable_reason: str = ""


def visible_workflow_scope_key(*, run_root: str = "", pair_id: str = "") -> str:
    normalized_run_root = str(run_root or "").strip()
    normalized_pair_id = str(pair_id or "").strip()
    return "{0}::{1}".format(normalized_run_root or "(no-run-root)", normalized_pair_id or "(no-pair)")


def build_visible_acceptance_state(inputs: VisibleAcceptanceInputs) -> VisibleAcceptanceState:
    scope_run_root = inputs.confirm_run_root or inputs.action_run_root or inputs.active_run_root
    scope_key = visible_workflow_scope_key(run_root=scope_run_root, pair_id=inputs.pair_id)
    receipt = dict(inputs.receipt_summary or empty_acceptance_receipt_summary(path=scope_run_root))
    progress = inputs.progress
    receipt_exists = str(receipt.get("Exists", "") or "").lower() == "true"
    receipt_state = str(receipt.get("AcceptanceState", "") or "")
    receipt_reason = str(receipt.get("AcceptanceReason", "") or "")
    receipt_focus_attention = "focus" in receipt_reason.lower()
    active_window_summary = str(receipt.get("ActiveWindowSummary", "") or receipt.get("ActiveWindowSnapshot", "") or "").strip()
    active_window_official_text = str(receipt.get("ActiveWindowIsOfficialTarget", "") or "").strip().lower()
    active_window_needs_attention = bool(
        active_window_summary
        and active_window_official_text == "false"
    )
    has_success_history = str(receipt.get("HasSuccessHistory", "") or "").lower() == "true"
    has_active_history = str(receipt.get("HasActiveHistory", "") or "").lower() == "true"
    workflow_flags = resolve_acceptance_receipt_workflow_flags(receipt)
    cleanup_applied = bool(progress.cleanup_applied)
    preflight_passed = bool(progress.preflight_passed or workflow_flags["PreflightPassed"])
    active_attempted = bool(progress.active_attempted or workflow_flags["ActiveAttempted"] or has_active_history)
    post_cleanup_done = bool(progress.post_cleanup_done or workflow_flags["PostCleanupDone"])
    clean_preflight_passed = bool(progress.clean_preflight_passed or workflow_flags["CleanPreflightPassed"])
    shared_confirm_passed = bool(progress.shared_confirm_passed)
    receipt_confirm_passed = bool(progress.receipt_confirm_passed)

    base_ready = bool(inputs.config_present and inputs.pair_id and inputs.seed_target_id)
    active_scope_ready = bool(base_ready and inputs.pair_scope_allowed and inputs.pair_enabled and inputs.active_run_root)
    confirm_scope_ready = bool(base_ready and inputs.confirm_run_root)
    preflight_enabled = bool(active_scope_ready and cleanup_applied)
    active_enabled = bool(active_scope_ready and preflight_passed)
    post_cleanup_enabled = bool(confirm_scope_ready and active_attempted)
    clean_preflight_enabled = bool(confirm_scope_ready and inputs.pair_scope_allowed and post_cleanup_done)
    shared_confirm_enabled = bool(confirm_scope_ready)
    receipt_confirm_enabled = bool(confirm_scope_ready and receipt_exists and active_attempted)

    status_text = "Visible Workflow: 대기"
    detail_parts: list[str] = []
    next_step = "queue cleanup apply"
    next_action_key = "visible_cleanup_apply"
    if not inputs.config_present:
        status_text = "Visible Workflow: Config 필요"
        detail_parts.append("ConfigPath를 먼저 선택하세요.")
        next_step = "config 선택"
        next_action_key = ""
    elif not inputs.pair_id:
        status_text = "Visible Workflow: Pair 필요"
        detail_parts.append("실행 Pair를 먼저 선택하세요.")
        next_step = "pair 선택"
        next_action_key = ""
    elif not inputs.seed_target_id:
        status_text = "Visible Workflow: SeedTarget 필요"
        detail_parts.append("선택한 pair의 top target을 해석하지 못했습니다.")
        next_step = "seed target 확인"
        next_action_key = ""
    elif not inputs.pair_scope_allowed:
        status_text = "Visible Workflow: pair scope 차단"
        detail_parts.append(inputs.pair_scope_detail or "현재 session 범위 밖 pair입니다.")
        next_step = "shared visible confirm"
        next_action_key = "visible_confirm" if shared_confirm_enabled else ""
    elif not inputs.pair_enabled:
        status_text = "Visible Workflow: Pair 비활성"
        detail_parts.append(inputs.disable_reason or "선택한 pair가 비활성 상태입니다.")
        next_step = "shared visible confirm"
        next_action_key = "visible_confirm" if shared_confirm_enabled else ""
    elif not inputs.active_run_root and not has_success_history:
        status_text = "Visible Workflow: RunRoot 필요"
        detail_parts.append(inputs.active_run_root_detail or "manifest.json이 있는 RunRoot를 먼저 준비하세요.")
        next_step = "run 준비"
        next_action_key = ""
    elif inputs.busy:
        status_text = "Visible Workflow: 작업 실행 중"
        detail_parts.append("현재 background 작업이 끝난 뒤 다음 단계가 갱신됩니다.")
        next_step = progress.last_action or next_step
        next_action_key = ""
    elif "실패" in inputs.last_result_text and receipt_state != "manual_attention_required" and not receipt_focus_attention:
        status_text = "Visible Workflow: 최근 단계 실패"
        detail_parts.append("실패한 단계의 출력과 receipt 상태를 먼저 확인하세요.")
        next_step = progress.last_action or next_step
        next_action_key = ""
    elif str(receipt.get("ParseError", "") or ""):
        status_text = "Visible Workflow: receipt parse-error"
        detail_parts.append(str(receipt.get("ParseError", "") or "receipt parse error"))
        next_step = "shared visible confirm"
        next_action_key = "visible_confirm" if shared_confirm_enabled else ""
    elif str(receipt.get("BlockedBy", "") or ""):
        status_text = "Visible Workflow: preflight blocked"
        detail_parts.append("blockedBy={0}".format(str(receipt.get("BlockedBy", "") or "")))
        if str(receipt.get("BlockedDetail", "") or ""):
            detail_parts.append(str(receipt.get("BlockedDetail", "") or ""))
        next_step = "queue cleanup apply"
        next_action_key = "visible_cleanup_apply"
    elif receipt_state == "manual_attention_required" or (receipt_state == "error" and receipt_focus_attention):
        status_text = "Visible Workflow: manual recovery 필요"
        reason_text = receipt_reason
        if "focus" in reason_text.lower():
            detail_parts.append("포커스 방해가 감지되었습니다. 방해앱은 켜둬도 되지만, recovery card에서 셀창 전환 재시도를 누른 뒤 5~10초 동안 마우스/키보드 조작을 멈추세요.")
            next_step = "focus recovery retry"
            next_action_key = "visible_focus_recovery_retry"
        else:
            detail_parts.append("수동 확인이 필요한 상태입니다. receipt reason과 target 상태를 먼저 확인하세요.")
            next_step = "manual recovery"
            next_action_key = ""
    elif has_success_history and not receipt_confirm_passed and receipt_confirm_enabled:
        status_text = "Visible Workflow: receipt confirm 필요"
        detail_parts.append("기존 successful acceptance history가 있어 receipt-required confirm으로 success를 다시 고정할 수 있습니다.")
        next_step = "receipt confirm"
        next_action_key = "visible_receipt_confirm"
    elif has_success_history and not post_cleanup_done:
        status_text = "Visible Workflow: post-cleanup 필요"
        detail_parts.append("기존 successful acceptance 뒤 queue / worker 정리 단계가 남아 있습니다.")
        next_step = "post-cleanup"
        next_action_key = "visible_post_cleanup"
    elif has_success_history and not clean_preflight_passed:
        status_text = "Visible Workflow: clean preflight recheck 필요"
        detail_parts.append("기존 successful acceptance 뒤 lane clean pass를 다시 남기세요.")
        next_step = "clean preflight recheck"
        next_action_key = "visible_clean_preflight"
    elif has_success_history and not shared_confirm_passed and shared_confirm_enabled:
        status_text = "Visible Workflow: passive confirm 권장"
        detail_parts.append("기존 successful acceptance history 기준 passive closure 검증이 가능합니다.")
        next_step = "shared visible confirm"
        next_action_key = "visible_confirm"
    elif not cleanup_applied:
        status_text = "Visible Workflow: cleanup 필요"
        detail_parts.append("shared lane active acceptance 전 queue cleanup apply를 먼저 남기세요.")
        next_step = "queue cleanup apply"
        next_action_key = "visible_cleanup_apply"
    elif not preflight_passed:
        status_text = "Visible Workflow: preflight 필요"
        detail_parts.append("cleanup 이후 clean preflight-only pass가 필요합니다.")
        next_step = "visible preflight-only"
        next_action_key = "visible_preflight"
    elif not active_attempted:
        if active_window_needs_attention:
            status_text = "Visible Workflow: focus 확인 필요"
            detail_parts.append(
                "preflight-only는 통과했지만 현재 active window가 공식 셀창이 아닙니다: {0}".format(
                    active_window_summary
                )
            )
            detail_parts.append("방해앱은 켜둬도 됩니다. recovery card의 [셀창 전환 후 계속]을 누른 뒤 5~10초 동안 손을 떼고 셀창 비콘/입력을 확인하세요.")
            next_step = "셀창 전환 후 계속"
            next_action_key = "visible_focus_recovery_retry"
        else:
            status_text = "Visible Workflow: active acceptance 필요"
            detail_parts.append("preflight-only 통과 후 active visible acceptance를 실행하세요.")
            next_step = "active visible acceptance"
            next_action_key = "visible_active_acceptance"
    elif not receipt_confirm_passed and receipt_confirm_enabled:
        status_text = "Visible Workflow: receipt confirm 필요"
        detail_parts.append("active acceptance 뒤 receipt-required confirm으로 runroot success를 고정하세요.")
        next_step = "receipt confirm"
        next_action_key = "visible_receipt_confirm"
    elif not post_cleanup_done:
        status_text = "Visible Workflow: post-cleanup 필요"
        detail_parts.append("active acceptance 뒤 queue / worker 상태를 정리하세요.")
        next_step = "post-cleanup"
        next_action_key = "visible_post_cleanup"
    elif not clean_preflight_passed:
        status_text = "Visible Workflow: clean preflight recheck 필요"
        detail_parts.append("post-cleanup 뒤 clean preflight recheck로 lane이 비었는지 다시 확인하세요.")
        next_step = "clean preflight recheck"
        next_action_key = "visible_clean_preflight"
    elif not shared_confirm_passed and shared_confirm_enabled:
        status_text = "Visible Workflow: passive confirm 권장"
        detail_parts.append("receipt / runroot 기준 passive closure 확인이 남았습니다.")
        next_step = "shared visible confirm"
        next_action_key = "visible_confirm"
    else:
        status_text = "Visible Workflow: 완료"
        detail_parts.append("cleanup -> preflight-only -> active acceptance -> post-cleanup 흐름이 현재 세션 기준으로 정리되었습니다.")
        next_step = "완료"
        next_action_key = ""

    if scope_run_root:
        detail_parts.append("runRoot={0}".format(os.path.basename(os.path.normpath(scope_run_root)) or scope_run_root))
    if receipt_state:
        detail_parts.append("receiptState={0}".format(receipt_state))
    if receipt.get("LastSuccessAcceptanceState", ""):
        detail_parts.append("lastSuccess={0}".format(receipt.get("LastSuccessAcceptanceState", "")))
    if receipt.get("Stage", ""):
        detail_parts.append("stage={0}".format(receipt.get("Stage", "")))
    if receipt.get("PhaseHistoryCount", ""):
        detail_parts.append("history={0}".format(receipt.get("PhaseHistoryCount", "")))
    if receipt.get("PhaseHistoryTail", ""):
        detail_parts.append("tail={0}".format(receipt.get("PhaseHistoryTail", "")))
    detail_parts.extend(format_acceptance_relay_issue_detail_parts(receipt))
    if progress.last_action:
        detail_parts.append("lastAction={0}".format(progress.last_action))
    if progress.last_updated_at:
        detail_parts.append("updated={0}".format(progress.last_updated_at))
    detail_parts.append("다음 단계: {0}".format(next_step))

    return VisibleAcceptanceState(
        scope_key=scope_key,
        config_present=inputs.config_present,
        pair_id=inputs.pair_id,
        seed_target_id=inputs.seed_target_id,
        pair_enabled=inputs.pair_enabled,
        pair_scope_allowed=inputs.pair_scope_allowed,
        pair_scope_detail=inputs.pair_scope_detail,
        action_run_root=inputs.action_run_root,
        active_run_root=inputs.active_run_root,
        active_run_root_detail=inputs.active_run_root_detail,
        confirm_run_root=inputs.confirm_run_root,
        confirm_run_root_detail=inputs.confirm_run_root_detail,
        receipt_path=str(receipt.get("Path", "") or ""),
        receipt_exists=receipt_exists,
        receipt_parse_error=str(receipt.get("ParseError", "") or ""),
        receipt_stage=str(receipt.get("Stage", "") or ""),
        receipt_state=receipt_state,
        receipt_reason=str(receipt.get("AcceptanceReason", "") or ""),
        blocked_by=str(receipt.get("BlockedBy", "") or ""),
        blocked_target_id=str(receipt.get("BlockedTargetId", "") or ""),
        blocked_run_root=str(receipt.get("BlockedRunRoot", "") or ""),
        blocked_path=str(receipt.get("BlockedPath", "") or ""),
        blocked_detail=str(receipt.get("BlockedDetail", "") or ""),
        history_count=int(str(receipt.get("PhaseHistoryCount", "") or "0") or 0),
        history_tail=str(receipt.get("PhaseHistoryTail", "") or ""),
        has_success_history=has_success_history,
        has_active_history=has_active_history,
        cleanup_applied=cleanup_applied,
        preflight_passed=preflight_passed,
        active_attempted=active_attempted,
        post_cleanup_done=post_cleanup_done,
        clean_preflight_passed=clean_preflight_passed,
        shared_confirm_passed=shared_confirm_passed,
        receipt_confirm_passed=receipt_confirm_passed,
        status_text=status_text,
        detail_text=" / ".join(part for part in detail_parts if part),
        next_step=next_step,
        next_action_key=next_action_key,
        preflight_enabled=preflight_enabled,
        active_enabled=active_enabled,
        post_cleanup_enabled=post_cleanup_enabled,
        clean_preflight_enabled=clean_preflight_enabled,
        shared_confirm_enabled=shared_confirm_enabled,
        receipt_confirm_enabled=receipt_confirm_enabled,
    )
