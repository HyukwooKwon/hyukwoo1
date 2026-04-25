from __future__ import annotations

from dataclasses import dataclass

from relay_panel_models import AppContext


@dataclass(frozen=True)
class ActionContextState:
    config_path: str = ""
    run_root: str = ""
    pair_id: str = ""
    target_id: str = ""
    source: str = "controls"

    def as_app_context(self) -> AppContext:
        return AppContext(
            config_path=self.config_path,
            run_root=self.run_root,
            pair_id=self.pair_id,
            target_id=self.target_id,
        )


@dataclass(frozen=True)
class InspectionContextState:
    pair_id: str = ""
    target_id: str = ""
    source: str = ""
    row_index: int | None = None


@dataclass(frozen=True)
class ArtifactQueryContextState:
    run_root: str = ""
    pair_id: str = ""
    target_id: str = ""
    path_kind: str = "summary"
    latest_only: bool = False
    include_missing: bool = True


@dataclass(frozen=True)
class QueryHistoryRecord:
    label: str
    context: str = ""
    timestamp: str = ""

    def summary(self) -> str:
        summary = self.label
        if self.context:
            summary = f"{summary} / {self.context}"
        return f"{self.timestamp} {summary}".strip()


VISIBLE_ACCEPTANCE_SUCCESS_STATES = {"roundtrip-confirmed", "first-handoff-confirmed"}
VISIBLE_ACCEPTANCE_ACTIVE_STATES = VISIBLE_ACCEPTANCE_SUCCESS_STATES | {"pending", "error"}


@dataclass
class VisibleAcceptanceWorkflowProgress:
    cleanup_applied: bool = False
    preflight_passed: bool = False
    active_attempted: bool = False
    post_cleanup_done: bool = False
    clean_preflight_passed: bool = False
    shared_confirm_passed: bool = False
    receipt_confirm_passed: bool = False
    last_action: str = ""
    last_updated_at: str = ""


@dataclass(frozen=True)
class VisibleAcceptanceState:
    scope_key: str
    config_present: bool
    pair_id: str
    seed_target_id: str
    pair_enabled: bool
    pair_scope_allowed: bool
    pair_scope_detail: str
    action_run_root: str
    active_run_root: str
    active_run_root_detail: str
    confirm_run_root: str
    confirm_run_root_detail: str
    receipt_path: str
    receipt_exists: bool
    receipt_parse_error: str
    receipt_stage: str
    receipt_state: str
    receipt_reason: str
    blocked_by: str
    blocked_target_id: str
    blocked_run_root: str
    blocked_path: str
    blocked_detail: str
    history_count: int
    history_tail: str
    has_success_history: bool
    has_active_history: bool
    cleanup_applied: bool
    preflight_passed: bool
    active_attempted: bool
    post_cleanup_done: bool
    clean_preflight_passed: bool
    shared_confirm_passed: bool
    receipt_confirm_passed: bool
    status_text: str
    detail_text: str
    next_step: str
    next_action_key: str
    preflight_enabled: bool
    active_enabled: bool
    post_cleanup_enabled: bool
    clean_preflight_enabled: bool
    shared_confirm_enabled: bool
    receipt_confirm_enabled: bool
