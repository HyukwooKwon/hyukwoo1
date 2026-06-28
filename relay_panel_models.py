from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class AppContext:
    config_path: str = ""
    run_root: str = ""
    pair_id: str = ""
    target_id: str = ""


@dataclass
class DashboardRawBundle:
    effective_data: dict
    relay_status: dict
    visibility_status: dict
    paired_status: dict | None = None
    paired_status_error: str = ""
    refresh_timing_steps: list[dict[str, object]] = field(default_factory=list)


@dataclass
class WorkflowState:
    overall: str
    label: str
    detail: str
    windows_ready: bool = False
    attach_ready: bool = False
    visibility_ready: bool = False
    run_root_ready: bool = False
    pair_ready: bool = False
    blocking_reason: str = ""
    next_actions: list[str] = field(default_factory=list)


@dataclass
class StatusCardModel:
    key: str
    title: str
    value: str
    detail: str


@dataclass
class StageModel:
    key: str
    title: str
    status_text: str
    detail: str
    action_key: str
    action_label: str
    enabled: bool = True


@dataclass
class ActionModel:
    label: str
    action_key: str
    detail: str = ""
    command_text: str = ""


@dataclass
class IssueModel:
    title: str
    detail: str
    action_key: str
    action_label: str


@dataclass
class HomeExecutionContextModel:
    badge_text: str
    badge_background: str = "#6B7280"
    badge_foreground: str = "#FFFFFF"
    summary: str = ""
    detail: str = ""
    warning: str = ""
    apply_enabled: bool = False
    run_root_open_enabled: bool = False
    clear_enabled: bool = False


@dataclass
class PrimaryActionRecommendation:
    title: str
    action_key: str
    button_label: str
    detail: str = ""
    command_text: str = ""
    read_only: bool = False
    enabled: bool = True


@dataclass(frozen=True)
class StartRunPreview:
    mode: str
    allowed: bool
    run_root: str
    pair_id: str
    target_ids: tuple[str, ...] = ()
    current_forwarded_count: int | None = None
    current_roundtrip_count: int | None = None
    roundtrip_limit: int | None = None
    will_prepare_runroot: bool = False
    will_prepare_typed_window: bool = False
    blocked_reason: str = ""
    warning: str = ""
    detail: str = ""


@dataclass
class PairSummaryModel:
    pair_id: str
    targets: str
    enabled: bool
    latest_state: str
    zip_count: int
    failure_count: int
    lane_watcher_status: str
    detail: str
    roundtrip_count: int = 0
    forwarded_state_count: int = 0
    handoff_ready_count: int = 0
    current_phase: str = ""
    next_expected_handoff: str = ""
    next_action: str = ""


@dataclass
class PanelStateModel:
    workflow: WorkflowState
    cards: list[StatusCardModel]
    stages: list[StageModel]
    next_actions: list[ActionModel]
    issues: list[IssueModel]
    pairs: list[PairSummaryModel]

    @property
    def overall_state(self) -> str:
        return self.workflow.overall

    @property
    def overall_label(self) -> str:
        return self.workflow.label

    @property
    def overall_detail(self) -> str:
        return self.workflow.detail
