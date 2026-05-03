from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, simpledialog, ttk

from relay_panel_artifact_controller import ArtifactTabController
from relay_panel_artifact_workflow import (
    ArtifactActionContextSnapshot,
    ArtifactCommandPlan,
    ArtifactSourceSelection,
    ArtifactSubmitLaunchRequest,
    ArtifactSubmitPreflight,
    build_artifact_action_record,
)
from relay_panel_artifacts import ArtifactQuery, ArtifactService, PairArtifactSummary, TargetArtifactState
from relay_panel_context_helpers import (
    append_query_history,
    context_source_label,
    format_action_context_summary,
    format_artifact_query_context_summary,
    format_inspection_context_summary,
    format_query_context_summary,
    resolve_inspection_context,
)
from relay_panel_home_controller import HomeController
from relay_panel_message_config import DEFAULT_SLOT_ORDER, MessageConfigService, SCOPED_SLOT_LABELS
from relay_panel_models import ActionModel, AppContext, DashboardRawBundle, IssueModel, PairSummaryModel, PanelStateModel
from relay_panel_operator_state import (
    ActionContextState,
    ArtifactQueryContextState,
    InspectionContextState,
    QueryHistoryRecord,
    VisibleAcceptanceState,
    VisibleAcceptanceWorkflowProgress,
)
from relay_panel_pair_controller import PairController
from relay_panel_refresh_controller import PanelRefreshController
from relay_panel_runtime_workflow import (
    PanelRuntimeWorkflowService,
    PrepareAllRequest,
    ReuseWindowsRequest,
    RunRootPrepareRequest,
    build_reuse_failure_summary,
    extract_prepared_run_root,
    resolve_run_root_summary_run_root,
)
from relay_panel_services import (
    ROOT,
    SNAPSHOT_DIR,
    CommandService,
    PowerShellError,
    StatusService,
    existing_config_presets,
    run_command,
)
from relay_panel_state import DashboardAggregator
from relay_panel_visible_workflow import (
    VisibleAcceptanceInputs,
    build_visible_acceptance_state,
    empty_acceptance_receipt_summary,
    summarize_acceptance_receipt_payload,
    visible_workflow_scope_key,
)
from relay_panel_watcher_controller import WatcherController
from relay_panel_watcher_workflow import (
    PanelWatcherWorkflowService,
    WatcherActionContextSnapshot,
    WatcherPanelUpdate,
    WatcherRestartFailure,
    WatcherRestartRequest,
)
from relay_panel_watchers import (
    DEFAULT_WATCHER_MAX_FORWARD_COUNT,
    DEFAULT_WATCHER_RUN_DURATION_SEC,
    WatcherStartRequest,
    WatcherService,
)


SNAPSHOT_LIST_LIMIT = 20
ARTIFACT_SOURCE_MEMORY_SCHEMA_VERSION = 1
ARTIFACT_PATH_OPTIONS = [
    ("summary", "summary"),
    ("latest zip", "review_zip"),
    ("request", "request"),
    ("done", "done"),
    ("error", "error"),
    ("result", "result"),
    ("target 폴더", "target_folder"),
    ("review 폴더", "review_folder"),
]
ARTIFACT_PATH_LABEL_TO_KIND = {label: kind for label, kind in ARTIFACT_PATH_OPTIONS}
MESSAGE_SCOPE_OPTIONS = [
    ("글로벌 Prefix", "global-prefix"),
    ("Pair Extra", "pair-extra"),
    ("Role Extra", "role-extra"),
    ("Target Extra", "target-extra"),
    ("One-time Prefix", "one-time-prefix"),
    ("Body", "body"),
    ("One-time Suffix", "one-time-suffix"),
    ("글로벌 Suffix", "global-suffix"),
]
MESSAGE_SCOPE_LABEL_TO_KIND = {label: kind for label, kind in MESSAGE_SCOPE_OPTIONS}
MESSAGE_SCOPE_KIND_TO_LABEL = {kind: label for label, kind in MESSAGE_SCOPE_OPTIONS}
MESSAGE_EDITABLE_SCOPE_KINDS = {
    "global-prefix",
    "pair-extra",
    "role-extra",
    "target-extra",
    "global-suffix",
}
MESSAGE_SCOPE_HELP_TEXT = {
    "one-time-prefix": "One-time Prefix 슬롯은 queue 기반으로 합성됩니다. 오른쪽 One-time preview에서 결과를 확인하세요.",
    "body": "Body 슬롯은 자동 생성 본문입니다. 여기서는 직접 편집하지 않고 preview / MessagePlan에서 확인합니다.",
    "one-time-suffix": "One-time Suffix 슬롯은 queue 기반으로 합성됩니다. 오른쪽 One-time preview에서 결과를 확인하세요.",
}
MESSAGE_FILTER_RESET_POLICY = {
    "slot_change": {"clear_search": True, "clear_changed_only": False},
    "scope_change": {"clear_search": True, "clear_changed_only": False},
    "board_target_change": {"clear_search": True, "clear_changed_only": False},
    "clear_filter": {"clear_search": True, "clear_changed_only": True},
}
BOARD_TARGET_FALLBACK = [f"target{index:02d}" for index in range(1, 9)]
PAIR_ID_OPTIONS = ["pair01", "pair02", "pair03", "pair04"]
RUN_ROOT_CONTEXT_REFRESH_DEBOUNCE_MS = 250
READ_ONLY_DASHBOARD_ACTION_KEYS = {
    "copy_command",
    "run_relay_status",
    "run_paired_status",
    "open_watcher_status",
    "open_watcher_control",
    "open_watcher_audit",
    "focus_ready_to_forward_artifact",
}
STICKY_ACTION_BUTTON_LABELS = {
    "copy_command": "명령 복사",
    "focus_ready_to_forward_artifact": "다음 전달 대상 보기",
    "visible_cleanup_apply": "cleanup 적용",
    "visible_preflight": "입력 전 점검",
    "visible_active_acceptance": "실제 acceptance 실행",
    "visible_post_cleanup": "post-cleanup",
    "visible_clean_preflight": "clean preflight 재점검",
    "visible_confirm": "shared confirm",
    "visible_receipt_confirm": "receipt 확인",
    "watcher_recommended_action": "watch 권장 조치",
}
READ_ONLY_OPS_BUTTON_LABELS = {
    "watch 진단",
    "watch audit 로그",
    "watch status 파일",
    "watch control 파일",
    "릴레이 상태",
    "페어 상태",
    "runroot 요약",
    "important-summary 열기",
    "Headless 준비 확인",
    "적용 설정 JSON",
}
MESSAGE_EDITOR_TAB_METADATA = {
    "context": {
        "label": "현재",
        "title": "현재 문맥",
        "description": "선택한 pair/target 기준 현재 문맥과 입력/출력 경로를 확인합니다.",
    },
    "plan": {
        "label": "적용",
        "title": "적용 source / plan",
        "description": "어떤 source가 어떤 순서로 합성되는지 확인합니다.",
    },
    "initial_preview": {
        "label": "Initial",
        "title": "Initial Preview",
        "description": "현재 편집본 기준 Initial 완성 preview를 보여줍니다.",
    },
    "handoff_preview": {
        "label": "Handoff",
        "title": "Handoff Preview",
        "description": "현재 편집본 기준 Handoff 완성 preview를 보여줍니다.",
    },
    "final_delivery": {
        "label": "전달문",
        "title": "최종 전달문",
        "description": "현재 target 기준 실제 전달 payload 완성본을 확인합니다.",
    },
    "path_summary": {
        "label": "경로",
        "title": "경로 요약",
        "description": "현재 target/partner 경로와 바로가기 액션을 확인합니다.",
    },
    "one_time": {
        "label": "1회성",
        "title": "1회성 문구",
        "description": "queue 기반 1회성 prefix/suffix 결과를 확인합니다.",
    },
    "validation": {
        "label": "검증",
        "title": "저장 전 검증",
        "description": "저장 전 에러/경고를 먼저 확인합니다.",
    },
    "summary": {
        "label": "요약",
        "title": "편집 요약",
        "description": "변경 영향과 현재 편집 상태를 요약해서 보여줍니다.",
    },
    "diff": {
        "label": "Diff",
        "title": "Diff",
        "description": "현재 편집본과 저장본 차이를 확인합니다.",
    },
    "backup": {
        "label": "백업",
        "title": "백업",
        "description": "자동 백업 목록과 diff 비교 지점을 확인합니다.",
    },
}


class RelayOperatorPanel(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("릴레이 운영 패널")
        self.geometry("1500x920")
        self.minsize(1240, 760)
        self.notebook: ttk.Notebook | None = None
        self.artifacts_tab: ttk.Frame | None = None

        self.command_service = CommandService()
        self.status_service = StatusService(self.command_service)
        self.refresh_controller = PanelRefreshController(self.status_service)
        self.runtime_workflow_service = PanelRuntimeWorkflowService(
            self.command_service,
            self.status_service,
            self.refresh_controller,
        )
        self.dashboard_aggregator = DashboardAggregator()
        self.artifact_service = ArtifactService()
        self.artifact_controller = ArtifactTabController(self.artifact_service)
        self.home_controller = HomeController()
        self.pair_controller = PairController(self.artifact_service)
        self.message_config_service = MessageConfigService(self.command_service)
        self.watcher_service = WatcherService()
        self.watcher_controller = WatcherController(self.watcher_service)
        self.watcher_workflow_service = PanelWatcherWorkflowService(
            self.watcher_controller,
            self.command_service,
            self.status_service,
        )
        self.config_path_var = tk.StringVar(value=self._default_config())
        self.run_root_label_var = tk.StringVar(value="RunRoot Override")
        self.run_root_var = tk.StringVar()
        self.run_root_status_var = tk.StringVar(value="AUTO")
        self.run_root_help_var = tk.StringVar(value="비워두면 pair 정책 기준 selected/new RunRoot를 사용합니다.")
        self.pair_id_var = tk.StringVar(value="pair01")
        self.target_id_var = tk.StringVar()
        self.artifact_run_root_filter_var = tk.StringVar(value="")
        self.artifact_pair_filter_var = tk.StringVar(value="")
        self.artifact_target_filter_var = tk.StringVar(value="")
        self.artifact_home_browse_pair_filter_var = tk.BooleanVar(value=False)
        self.artifact_home_browse_toggle_var = tk.StringVar(value="Home Pair만 보기")
        self.artifact_home_browse_target_filter_var = tk.BooleanVar(value=False)
        self.artifact_home_browse_target_toggle_var = tk.StringVar(value="보고 target 따라가기")
        self.artifact_path_kind_var = tk.StringVar(value="summary")
        self.artifact_latest_only_var = tk.BooleanVar(value=False)
        self.artifact_include_missing_var = tk.BooleanVar(value=True)
        self.last_command_var = tk.StringVar(value="")
        self.operator_status_var = tk.StringVar(value="대기 중")
        self.operator_hint_var = tk.StringVar(value="설정을 고른 뒤 미리보기를 불러오고, Pair와 RunRoot를 확인한 다음 현재 lane에 맞는 Visible Acceptance 또는 진단 절차를 선택하세요.")
        self.last_result_var = tk.StringVar(value="마지막 결과: (없음)")
        self.last_query_result_var = tk.StringVar(value="마지막 조회: (없음)")
        self.query_history_var = tk.StringVar(value="최근 조회: (없음)")
        self.mode_banner_var = tk.StringVar(value="MODE: Home")
        self.mode_banner_detail_var = tk.StringVar(value="lane과 runroot를 먼저 확인한 뒤 visible acceptance 또는 진단 절차를 선택합니다.")
        self.simple_mode_var = tk.BooleanVar(value=False)
        self.header_compact_var = tk.BooleanVar(value=True)
        self.result_panel_collapsed_var = tk.BooleanVar(value=False)
        self.result_panel_dock_var = tk.StringVar(value="bottom")
        self.header_toggle_button_var = tk.StringVar(value="세부 펼치기")
        self.result_toggle_button_var = tk.StringVar(value="결과 접기")
        self.result_dock_button_var = tk.StringVar(value="오른쪽 도킹")
        self.result_panel_context_var = tk.StringVar(
            value="현재 탭 본문과 별개로, 작업 출력/조회 결과는 하단 공용 패널에서 확인합니다. 패널이 접혀 있으면 '결과 펼치기'를 누르세요."
        )
        self.result_panel_status_var = tk.StringVar(value="상태: 하단 / 펼침 / 최근 갱신 없음")
        self.home_context_var = tk.StringVar(value="Lane: -")
        self.home_updated_at_var = tk.StringVar(value="마지막 갱신: -")
        self.home_overall_var = tk.StringVar(value="상태: -")
        self.home_overall_detail_var = tk.StringVar(value="안내: 상태를 불러오면 준비 단계와 다음 조치를 여기서 보여줍니다.")
        self.home_pair_detail_var = tk.StringVar(value="Pair 요약을 불러오면 여기서 선택한 pair의 상태를 간단히 보여줍니다.")
        self.pair_focus_badge_var = tk.StringVar(value="STATE 미확인")
        self.pair_focus_summary_var = tk.StringVar(value="현재 실행 Pair 요약을 준비 중입니다.")
        self.pair_focus_detail_var = tk.StringVar(value="phase / next / runroot / handoff 카운트를 여기서 고정 표시합니다.")
        self.sticky_action_context_var = tk.StringVar(value="pair01/(target 없음) [상단 실행 선택]")
        self.sticky_inspection_context_var = tk.StringVar(value="(없음)")
        self.sticky_run_root_context_var = tk.StringVar(value="RunRoot: (없음)")
        self.sticky_runtime_context_var = tk.StringVar(value="대기 중 / watcher=미확인")
        self.sticky_next_step_var = tk.StringVar(value="-")
        self.sticky_next_action_button_var = tk.StringVar(value="다음 단계 실행")
        self.sticky_artifact_browse_var = tk.StringVar(value="")
        self.sticky_result_panel_var = tk.StringVar(value="결과: 하단 / 펼침")
        self.sticky_context_badge_var = tk.StringVar(value="보고 대상 미고정")
        self.artifact_summary_collapsed_var = tk.BooleanVar(value=False)
        self.artifact_details_collapsed_var = tk.BooleanVar(value=True)
        self.artifact_summary_toggle_var = tk.StringVar(value="summary 접기")
        self.artifact_details_toggle_var = tk.StringVar(value="경로 펼치기")
        self.visible_acceptance_status_var = tk.StringVar(value="shared visible 공식 절차 상태를 여기서 확인합니다.")
        self.visible_acceptance_detail_var = tk.StringVar(value="cleanup -> preflight-only -> active acceptance -> post-cleanup -> confirm")
        self.visible_primitive_status_var = tk.StringVar(value="pair primitive 상태를 여기서 확인합니다.")
        self.visible_primitive_detail_var = tk.StringVar(value="preview/apply -> submit -> publish/handoff 확인을 잘라 점검합니다.")
        self.visible_primitive_stage_badge_var = tk.StringVar(value="준비 필요")
        self.visible_primitive_stage_detail_var = tk.StringVar(value="현재 row 기준 다음 단계를 여기서 요약합니다.")
        self.visible_primitive_stage_action_button_var = tk.StringVar(value="권장 단계 실행")
        self.artifact_status_var = tk.StringVar(value="결과 / 산출물 탭에서 현재 RunRoot 기준 상태를 확인할 수 있습니다.")
        self.artifact_status_base_text = "결과 / 산출물 탭에서 현재 RunRoot 기준 상태를 확인할 수 있습니다."
        self.board_status_var = tk.StringVar(value="8창 보드에서 target별 attach / 입력 가능 / pair 매칭을 한눈에 확인할 수 있습니다.")
        self.message_editor_status_var = tk.StringVar(value="설정 편집기에서 고정문구, override 블록, 슬롯 순서를 수정할 수 있습니다.")
        self.message_preview_status_var = tk.StringVar(value="저장 전 편집본 preview는 '미리보기 갱신'으로 다시 계산합니다.")
        self.message_fixed_section_collapsed_var = tk.BooleanVar(value=True)
        self.message_fixed_section_toggle_var = tk.StringVar(value="고정문구 펼치기")
        self.message_block_focus_mode_var = tk.BooleanVar(value=False)
        self.message_block_focus_button_var = tk.StringVar(value="블록 편집 집중")
        self.pair_policy_editor_status_var = tk.StringVar(value="4 pair 설정 카드에서 repo/path 정책 초안을 편집하고, 실효 경로를 pair별로 확인할 수 있습니다.")
        self.pair_policy_parallel_status_var = tk.StringVar(
            value="병렬 실행: pair 간 실행은 병렬, 같은 pair 내부 handoff는 순차입니다. 현재 RunRoot의 wrapper-status 또는 paired status에서 pair별 진행률을 함께 읽습니다."
        )
        self.parallel_coordinator_repo_root_var = tk.StringVar(value=str((ROOT / "_tmp" / "pair-parallel-coordinator").resolve()))
        self.seed_kickoff_status_var = tk.StringVar(
            value="초기 실행 준비: 작업 설명만 입력하면 현재 pair 실효 경로 기준 자동 계약 블록을 합쳐 수동 복붙 시작문으로 쓰거나 1회성 queue로 등록할 수 있습니다."
        )
        self.seed_kickoff_pair_var = tk.StringVar(value="pair01")
        self.seed_kickoff_target_var = tk.StringVar(value="")
        self.seed_kickoff_review_input_var = tk.StringVar(value="")
        self.seed_kickoff_applies_to_var = tk.StringVar(value="initial")
        self.seed_kickoff_placement_var = tk.StringVar(value="one-time-prefix")
        self.seed_kickoff_target_banner_var = tk.StringVar(value="붙여넣기 대상: (미확인)")
        self.seed_kickoff_readiness_var = tk.StringVar(value="준비 상태를 확인하세요.")
        self.seed_kickoff_detail_visible_var = tk.BooleanVar(value=False)
        self.message_block_filter_var = tk.StringVar(value="")
        self._sticky_next_action_key = ""
        self._sticky_next_action_command_text = ""
        self.message_block_changed_only_var = tk.BooleanVar(value=False)
        self.message_block_filter_status_var = tk.StringVar(value="블록 표시: 0/0")
        self.message_block_badges_var = tk.StringVar(value="")
        self.message_block_hint_var = tk.StringVar(value="")
        self.message_template_var = tk.StringVar(value="Initial")
        self.message_template_hint_var = tk.StringVar(value="현재 편집 템플릿: Initial. target-extra는 Initial/Handoff가 각각 따로 저장됩니다.")
        self.message_scope_label_var = tk.StringVar(value="글로벌 Prefix")
        self.message_scope_id_var = tk.StringVar(value="")
        self.message_target_suffix_var = tk.StringVar(value="")
        self.message_editor_tab_title_var = tk.StringVar(value=MESSAGE_EDITOR_TAB_METADATA["context"]["title"])
        self.message_editor_tab_detail_var = tk.StringVar(value=MESSAGE_EDITOR_TAB_METADATA["context"]["description"])
        self.watcher_max_forward_var = tk.StringVar(value=str(DEFAULT_WATCHER_MAX_FORWARD_COUNT))
        self.watcher_run_duration_var = tk.StringVar(value=str(DEFAULT_WATCHER_RUN_DURATION_SEC))
        self.watcher_pair_roundtrip_var = tk.StringVar(value="0")
        self.watcher_quick_start_note_var = tk.StringVar(value="")
        self.watcher_current_note_var = tk.StringVar(value="")
        self.watcher_start_note_var = tk.StringVar(value="")
        self.watcher_control_note_var = tk.StringVar(value=self.watcher_controller.control_semantics_guidance())
        self.artifact_source_memory_path = SNAPSHOT_DIR / "artifact-source-memory.json"
        self.artifact_source_memory_warning = ""

        self.effective_data: dict | None = None
        self.relay_status_data: dict | None = None
        self.visibility_status_data: dict | None = None
        self.paired_status_data: dict | None = None
        self.paired_status_error: str = ""
        self.message_config_doc: dict | None = None
        self.message_config_original: dict | None = None
        self.panel_state: PanelStateModel | None = None
        self.preview_rows: list[dict] = []
        self.artifact_states: list[TargetArtifactState] = []
        self.artifact_pair_summaries: list[PairArtifactSummary] = []
        self.artifact_last_sources_by_target: dict[str, dict[str, str]] = {}
        self.artifact_last_action_by_target: dict[str, dict[str, object]] = {}
        self.artifact_submit_active_targets: set[str] = set()
        self.snapshot_paths: list[Path] = []
        self.snapshot_rows: list[dict] = []
        self.target_board_cells: dict[str, dict[str, object]] = {}
        self.message_block_drag_index: int | None = None
        self.message_slot_drag_index: int | None = None
        self.message_document_version = 0
        self.message_preview_doc_version = -1
        self.message_preview_cached_context_key = ""
        self.message_preview_payload: dict | None = None
        self.message_editor_dirty = False
        self.message_block_visible_indexes: list[int] = []
        self.message_selected_slot_key = "global-prefix"
        self.message_last_rendered_slot_key = ""
        self.message_last_rendered_slot_order: tuple[str, ...] = ()
        self.message_last_rendered_template_name = ""
        self.message_last_rendered_scope_kind = ""
        self.message_last_rendered_scope_id = ""
        self.inspection_pair_id = ""
        self.inspection_target_id = ""
        self.action_context_source = "controls"
        self.inspection_context_source = ""
        self.inspection_context_row_index: int | None = None
        self.result_panel_last_channel = ""
        self.result_panel_last_preview = ""
        self.result_panel_last_updated_at = ""
        self.result_panel_has_unseen_update = False
        self.query_history_entries: list[str] = []
        self.query_history_records: list[QueryHistoryRecord] = []
        self.visible_workflow_progress_by_scope: dict[str, VisibleAcceptanceWorkflowProgress] = {}
        self.message_backup_paths: list[Path] = []
        self.long_task_widgets: list[tk.Widget] = []
        self.read_only_widgets: set[tk.Widget] = set()
        self.message_editor_tab_meta_by_widget: dict[str, dict[str, str]] = {}
        self.home_card_vars: dict[str, dict[str, tk.StringVar]] = {}
        self.home_stage_vars: dict[str, dict[str, tk.StringVar]] = {}
        self.home_stage_buttons: dict[str, ttk.Button] = {}
        self.pair_policy_card_vars: dict[str, dict[str, tk.Variable]] = {}
        self.pair_policy_card_badge_labels: dict[str, tk.Label] = {}
        self.pair_policy_card_repo_source_badge_labels: dict[str, tk.Label] = {}
        self.pair_policy_card_override_badge_labels: dict[str, tk.Label] = {}
        self.pair_policy_card_runtime_badge_labels: dict[str, tk.Label] = {}
        self.pair_policy_card_focus_badge_labels: dict[str, tk.Label] = {}
        self.pair_policy_card_effective_preview_widgets: dict[str, tk.Text] = {}
        self.pair_policy_card_seed_combos: dict[str, ttk.Combobox] = {}
        self.pair_policy_card_parallel_checkbuttons: dict[str, ttk.Checkbutton] = {}
        self.pair_policy_card_summary_buttons: dict[str, ttk.Button] = {}
        self.pair_policy_card_preview_buttons: dict[str, ttk.Button] = {}
        self.pair_policy_card_copy_buttons: dict[str, ttk.Button] = {}
        self.seed_kickoff_target_combo: ttk.Combobox | None = None
        self.seed_kickoff_pair_combo: ttk.Combobox | None = None
        self.seed_kickoff_task_text: tk.Text | None = None
        self.seed_kickoff_contract_text: tk.Text | None = None
        self.seed_kickoff_helper_text: tk.Text | None = None
        self.seed_kickoff_steps_text: tk.Text | None = None
        self.seed_kickoff_simple_text: tk.Text | None = None
        self.seed_kickoff_preview_text: tk.Text | None = None
        self.seed_kickoff_preview_stack_frame: ttk.Frame | None = None
        self.seed_kickoff_preview_detail_frame: ttk.Frame | None = None
        self.seed_kickoff_input_columns_frame: ttk.Frame | None = None
        self.seed_kickoff_detail_column_frame: ttk.Frame | None = None
        self.seed_kickoff_detail_actions_frame: ttk.Frame | None = None
        self.message_editor_left_frame: ttk.Frame | None = None
        self.message_fixed_body_frame: ttk.Frame | None = None
        self.message_fixed_toggle_button: ttk.Button | None = None
        self.message_block_focus_button: ttk.Button | None = None
        self.editor_initial_preview_tab: ttk.Frame | None = None
        self.editor_handoff_preview_tab: ttk.Frame | None = None
        self.pair_policy_clone_source_var = tk.StringVar(value=PAIR_ID_OPTIONS[0])
        self.pair_policy_clone_target_var = tk.StringVar(value=PAIR_ID_OPTIONS[1] if len(PAIR_ID_OPTIONS) > 1 else PAIR_ID_OPTIONS[0])
        for pair_id in PAIR_ID_OPTIONS:
            self.pair_policy_card_vars[pair_id] = {
                "meta_var": tk.StringVar(value=f"{pair_id} / (미구성)"),
                "repo_root_var": tk.StringVar(value=""),
                "seed_target_var": tk.StringVar(value=""),
                "roundtrip_var": tk.StringVar(value="0"),
                "external_run_root_var": tk.BooleanVar(value=False),
                "external_contract_var": tk.BooleanVar(value=False),
                "route_badge_var": tk.StringVar(value="ROUTE 미확인"),
                "repo_source_badge_var": tk.StringVar(value="REPO 미확인"),
                "override_badge_var": tk.StringVar(value="RUNROOT AUTO"),
                "route_state_var": tk.StringVar(value="route: (미확인)"),
                "effective_preview_var": tk.StringVar(value="실효값 미리보기를 실행하면 pair별 repo/runroot/outbox 경로를 여기서 확인합니다."),
                "runtime_badge_var": tk.StringVar(value="STATE 미확인"),
                "runtime_summary_var": tk.StringVar(value="runtime 상태는 현재 RunRoot의 wrapper-status 또는 paired status를 읽으면 표시됩니다."),
                "parallel_selected_var": tk.BooleanVar(value=(pair_id in {"pair01", "pair02"})),
            }
        self._busy = False
        self._mode_banner_label = "MODE: Home"
        self._mode_banner_detail = "lane과 runroot를 먼저 확인한 뒤 visible acceptance 또는 진단 절차를 선택합니다."
        self._last_visible_mode_label = "MODE: Active Visible"
        self._last_visible_mode_detail = "shared visible 공식 절차 기준 preflight / acceptance / cleanup / confirm을 진행합니다."
        self.seed_kickoff_last_preview: dict[str, object] | None = None
        self._artifact_manual_filters_before_browse: tuple[str, str] | None = None
        self.panel_opened_at_utc = self._utc_now_iso()
        self.window_launch_anchor_utc = self.panel_opened_at_utc
        self.run_root_context_refresh_after_id: str | None = None
        self.run_root_var.trace_add("write", self._on_run_root_value_changed)
        self.watcher_max_forward_var.trace_add("write", self._on_watcher_start_option_changed)
        self.watcher_run_duration_var.trace_add("write", self._on_watcher_start_option_changed)
        self.watcher_pair_roundtrip_var.trace_add("write", self._on_watcher_start_option_changed)

        self._load_artifact_source_memory()
        self._build_ui()
        self._refresh_watcher_notes()
        self.load_effective_config()

    def _has_ui_attr(self, name: str) -> bool:
        try:
            object.__getattribute__(self, name)
        except (AttributeError, RecursionError):
            return False
        return True

    def _register_read_only_widget(self, widget: tk.Widget) -> None:
        self.read_only_widgets.add(widget)

    def _widget_is_read_only(self, widget: tk.Widget) -> bool:
        return widget in self.read_only_widgets

    @staticmethod
    def _dashboard_action_is_read_only(action_key: str) -> bool:
        return action_key in READ_ONLY_DASHBOARD_ACTION_KEYS

    def _default_config(self) -> str:
        presets = existing_config_presets()
        if presets:
            return presets[0]
        return str(ROOT / "config" / "settings.psd1")

    def _create_scrollable_tab(
        self,
        notebook: ttk.Notebook,
        *,
        title: str,
        padding: int = 10,
        footer_text: str = "",
    ) -> tuple[ttk.Frame, ttk.Frame]:
        tab_container = ttk.Frame(notebook, padding=0)
        tab_container.columnconfigure(0, weight=1)
        tab_container.rowconfigure(0, weight=1)
        notebook.add(tab_container, text=title)

        canvas = tk.Canvas(tab_container, highlightthickness=0)
        canvas.grid(row=0, column=0, sticky="nsew")
        scrollbar = ttk.Scrollbar(tab_container, orient="vertical", command=canvas.yview)
        scrollbar.grid(row=0, column=1, sticky="ns")
        canvas.configure(yscrollcommand=scrollbar.set)

        body = ttk.Frame(canvas, padding=padding)
        content_parent: ttk.Frame = body
        content: ttk.Frame | None = None
        footer_label: ttk.Label | None = None
        if footer_text:
            body.columnconfigure(0, weight=1)
            body.rowconfigure(0, weight=1)
            content = ttk.Frame(body)
            content.grid(row=0, column=0, sticky="nsew")
            footer_label = ttk.Label(
                body,
                text=footer_text,
                foreground="#6B7280",
                justify="center",
                anchor="center",
            )
            footer_label.grid(row=1, column=0, sticky="ew", pady=(12, 0))
            content_parent = content
        body_window = canvas.create_window((0, 0), window=body, anchor="nw")

        def _sync_scroll_region(_event: object | None = None) -> None:
            try:
                canvas.configure(scrollregion=canvas.bbox("all"))
            except Exception:
                pass

        def _sync_canvas_width(event: object) -> None:
            try:
                width = int(getattr(event, "width", 0) or 0)
            except Exception:
                width = 0
            if width <= 0:
                return
            try:
                canvas.itemconfigure(body_window, width=width)
            except Exception:
                pass

        def _on_mousewheel(event: object) -> str | None:
            try:
                delta = int(getattr(event, "delta", 0) or 0)
            except Exception:
                delta = 0
            if not delta:
                return None
            canvas.yview_scroll(int(-1 * (delta / 120)), "units")
            return "break"

        body.bind("<Configure>", _sync_scroll_region)
        canvas.bind("<Configure>", _sync_canvas_width)
        canvas.bind("<MouseWheel>", _on_mousewheel)
        body.bind("<MouseWheel>", _on_mousewheel)
        if content is not None:
            content.bind("<MouseWheel>", _on_mousewheel)
        if footer_label is not None:
            footer_label.bind("<MouseWheel>", _on_mousewheel)
        return tab_container, content_parent

    def _apply_header_compact_mode(self) -> None:
        frame = self.__dict__.get("header_details_frame")
        var = self.__dict__.get("header_compact_var")
        label_var = self.__dict__.get("header_toggle_button_var")
        if frame is None or var is None or label_var is None or not hasattr(var, "get"):
            return
        compact = bool(var.get())
        try:
            if compact:
                frame.grid_remove()
                label_var.set("세부 펼치기")
            else:
                frame.grid()
                label_var.set("세부 접기")
        except Exception:
            pass

    def toggle_header_compact(self) -> None:
        if not self._has_ui_attr("header_compact_var"):
            return
        self.header_compact_var.set(not bool(self.header_compact_var.get()))
        self._apply_header_compact_mode()
        state_label = "compact" if self.header_compact_var.get() else "expanded"
        self.set_operator_status(
            "헤더 표시 변경",
            f"상단 글로벌 헤더를 {state_label} 모드로 전환했습니다.",
        )
        self._refresh_sticky_context_bar()

    def _result_panel_layout_state(self) -> tuple[bool, bool]:
        dock_mode = "bottom"
        dock_var = self.__dict__.get("result_panel_dock_var")
        if dock_var is not None and hasattr(dock_var, "get"):
            dock_mode = str(dock_var.get() or "bottom").strip().lower()
        dock_right = dock_mode == "right"
        collapsed = False
        collapsed_var = self.__dict__.get("result_panel_collapsed_var")
        if collapsed_var is not None and hasattr(collapsed_var, "get"):
            collapsed = bool(collapsed_var.get())
        return dock_right, collapsed

    def _apply_result_panel_layout(self) -> None:
        frame = self.__dict__.get("result_frame")
        notebook = self.__dict__.get("notebook")
        dock_right, collapsed = self._result_panel_layout_state()
        if frame is None or notebook is None:
            return
        try:
            if dock_right:
                self.rowconfigure(2, weight=0)
                self.columnconfigure(1, weight=0)
                notebook.grid_configure(row=1, column=0, sticky="nsew", padx=(10, 6), pady=(0, 10))
                frame.grid_configure(row=1, column=1, sticky="ns" if collapsed else "nsew", padx=(0, 10), pady=(0, 10))
            else:
                self.rowconfigure(2, weight=0 if collapsed else 1)
                self.columnconfigure(1, weight=0)
                notebook.grid_configure(row=1, column=0, sticky="nsew", padx=10, pady=(0, 10))
                frame.grid_configure(row=2, column=0, sticky="ew" if collapsed else "nsew", padx=10, pady=(0, 10))
        except Exception:
            pass

    def _refresh_result_panel_context(self) -> None:
        frame = self.__dict__.get("result_frame")
        context_var = self.__dict__.get("result_panel_context_var")
        dock_right, collapsed = self._result_panel_layout_state()
        unseen_update = bool(self.__dict__.get("result_panel_has_unseen_update", False))
        location = "오른쪽 공용 패널" if dock_right else "하단 공용 패널"
        if collapsed and unseen_update:
            visibility = "지금은 접혀 있지만 새 결과가 도착했습니다. '새 결과 보기'를 눌러 바로 확인하세요."
        elif collapsed:
            visibility = "지금은 축약 상태라 헤더만 보입니다."
        else:
            visibility = "지금은 펼쳐져 있어 바로 읽을 수 있습니다."
        if context_var is not None and hasattr(context_var, "set"):
            context_var.set(
                f"현재 탭 본문과 별개로, 작업 출력/조회 결과는 {location}에서 확인합니다. {visibility} 결과가 갱신되면 이 패널을 기준으로 확인하세요."
            )
        status_var = self.__dict__.get("result_panel_status_var")
        if status_var is not None and hasattr(status_var, "set"):
            update_hint = " / 새 결과 확인 대기" if unseen_update and collapsed else ""
            status_var.set(
                f"상태: {'오른쪽' if dock_right else '하단'} / {'접힘' if collapsed else '펼침'} / {self._result_panel_latest_summary()}{update_hint}"
            )
        if frame is not None:
            try:
                frame.configure(text=f"{location} / 작업 · 조회 결과")
            except Exception:
                pass

    @staticmethod
    def _result_panel_preview_text(value: str, *, limit: int = 88) -> str:
        text = re.sub(r"\s+", " ", str(value or "")).strip()
        if not text:
            return ""
        if len(text) <= limit:
            return text
        return text[: max(0, limit - 3)].rstrip() + "..."

    def _result_panel_latest_summary(self, *, short: bool = False) -> str:
        channel = str(self.__dict__.get("result_panel_last_channel", "") or "").strip()
        if not channel:
            return "최근 갱신 없음"
        updated_at = str(self.__dict__.get("result_panel_last_updated_at", "") or "").strip() or "(시각 미확인)"
        preview = str(self.__dict__.get("result_panel_last_preview", "") or "").strip()
        if short:
            short_time = updated_at[:5] if len(updated_at) >= 5 else updated_at
            return f"{channel} {short_time}"
        return f"마지막 {channel}: {updated_at}" + (f" / {preview}" if preview else "")

    def _result_panel_badge_spec(self) -> dict[str, str]:
        dock_right, collapsed = self._result_panel_layout_state()
        location = "오른쪽" if dock_right else "하단"
        visibility = "접힘" if collapsed else "펼침"
        latest = self._result_panel_latest_summary(short=True)
        text = f"결과: {location} / {visibility}"
        if latest != "최근 갱신 없음":
            text += f" / {latest}"
        has_update = bool(str(self.__dict__.get("result_panel_last_channel", "") or "").strip())
        unseen_update = bool(self.__dict__.get("result_panel_has_unseen_update", False))
        if not has_update:
            background = "#6B7280"
        elif unseen_update:
            background = "#92400E"
        elif collapsed:
            background = "#6B7280"
        else:
            background = "#1D4ED8"
        return {
            "text": text,
            "background": background,
            "foreground": "#FFFFFF",
        }

    def _mark_result_panel_content_updated(self, channel: str, value: str) -> None:
        self.result_panel_last_channel = str(channel or "").strip()
        self.result_panel_last_preview = self._result_panel_preview_text(value)
        self.result_panel_last_updated_at = datetime.now().astimezone().strftime("%H:%M:%S")
        self._refresh_result_panel_context()
        if self._has_ui_attr("sticky_action_context_var"):
            self._refresh_sticky_context_bar()

    def _apply_result_panel_visibility(self) -> None:
        body = self.__dict__.get("result_body_frame")
        var = self.__dict__.get("result_panel_collapsed_var")
        label_var = self.__dict__.get("result_toggle_button_var")
        if body is None or var is None or label_var is None or not hasattr(var, "get"):
            return
        collapsed = bool(var.get())
        if not collapsed:
            self.result_panel_has_unseen_update = False
        try:
            if collapsed:
                body.grid_remove()
                if bool(self.__dict__.get("result_panel_has_unseen_update", False)):
                    label_var.set("새 결과 보기")
                else:
                    label_var.set("결과 펼치기")
            else:
                body.grid()
                label_var.set("결과 접기")
        except Exception:
            pass
        self._apply_result_panel_layout()
        self._refresh_result_panel_context()

    def toggle_result_panel(self) -> None:
        if not self._has_ui_attr("result_panel_collapsed_var"):
            return
        self.result_panel_collapsed_var.set(not bool(self.result_panel_collapsed_var.get()))
        self._apply_result_panel_visibility()
        state_label = "접기" if self.result_panel_collapsed_var.get() else "펼치기"
        self.set_operator_status("결과 패널 표시 변경", f"하단 결과 패널을 {state_label} 상태로 바꿨습니다.")
        self._refresh_sticky_context_bar()

    def _apply_result_panel_dock_mode(self) -> None:
        dock_var = self.__dict__.get("result_panel_dock_var")
        label_var = self.__dict__.get("result_dock_button_var")
        if dock_var is None or label_var is None or not hasattr(dock_var, "get"):
            return
        dock_mode = str(dock_var.get() or "bottom").strip().lower()
        dock_right = dock_mode == "right"
        try:
            if dock_right:
                label_var.set("하단 도킹")
            else:
                label_var.set("오른쪽 도킹")
        except Exception:
            pass
        self._apply_result_panel_layout()
        self._refresh_result_panel_context()

    def toggle_result_panel_dock(self) -> None:
        if not self._has_ui_attr("result_panel_dock_var"):
            return
        next_mode = "right" if str(self.result_panel_dock_var.get() or "bottom") == "bottom" else "bottom"
        self.result_panel_dock_var.set(next_mode)
        self._apply_result_panel_dock_mode()
        state_label = "오른쪽 도킹" if next_mode == "right" else "하단 도킹"
        self.set_operator_status("결과 패널 배치 변경", f"작업 / 조회 결과 패널을 {state_label} 모드로 전환했습니다.")
        self._refresh_sticky_context_bar()

    def _apply_artifact_section_visibility(self) -> None:
        sections = [
            ("artifact_summary_body_frame", "artifact_summary_collapsed_var", "artifact_summary_toggle_var", "summary 접기", "summary 펼치기"),
            ("artifact_details_body_frame", "artifact_details_collapsed_var", "artifact_details_toggle_var", "경로 접기", "경로 펼치기"),
        ]
        for body_attr, collapsed_attr, label_attr, expanded_label, collapsed_label in sections:
            body = self.__dict__.get(body_attr)
            collapsed_var = self.__dict__.get(collapsed_attr)
            label_var = self.__dict__.get(label_attr)
            if body is None or collapsed_var is None or label_var is None or not hasattr(collapsed_var, "get"):
                continue
            collapsed = bool(collapsed_var.get())
            try:
                if collapsed:
                    body.grid_remove()
                    label_var.set(collapsed_label)
                else:
                    body.grid()
                    label_var.set(expanded_label)
            except Exception:
                pass

    def toggle_artifact_summary_section(self) -> None:
        if not self._has_ui_attr("artifact_summary_collapsed_var"):
            return
        self.artifact_summary_collapsed_var.set(not bool(self.artifact_summary_collapsed_var.get()))
        self._apply_artifact_section_visibility()

    def toggle_artifact_details_section(self) -> None:
        if not self._has_ui_attr("artifact_details_collapsed_var"):
            return
        self.artifact_details_collapsed_var.set(not bool(self.artifact_details_collapsed_var.get()))
        self._apply_artifact_section_visibility()

    def _apply_message_fixed_section_visibility(self) -> None:
        body = self.__dict__.get("message_fixed_body_frame")
        collapsed_var = self.__dict__.get("message_fixed_section_collapsed_var")
        toggle_var = self.__dict__.get("message_fixed_section_toggle_var")
        if collapsed_var is None or toggle_var is None or not hasattr(collapsed_var, "get") or not hasattr(toggle_var, "set"):
            return
        collapsed = bool(collapsed_var.get())
        if body is not None:
            try:
                if collapsed:
                    body.grid_remove()
                    toggle_var.set("고정문구 펼치기")
                else:
                    body.grid()
                    toggle_var.set("고정문구 접기")
            except Exception:
                pass
        editor_left = self.__dict__.get("message_editor_left_frame")
        if editor_left is not None:
            try:
                editor_left.rowconfigure(4, weight=0 if collapsed else 1)
            except Exception:
                pass

    def toggle_message_fixed_section(self) -> None:
        if not self._has_ui_attr("message_fixed_section_collapsed_var"):
            return
        self.message_fixed_section_collapsed_var.set(not bool(self.message_fixed_section_collapsed_var.get()))
        self._apply_message_fixed_section_visibility()

    def _apply_message_block_focus_mode(self) -> None:
        focused = bool(self.message_block_focus_mode_var.get()) if self._has_ui_attr("message_block_focus_mode_var") else False
        if self._has_ui_attr("message_block_focus_button_var"):
            self.message_block_focus_button_var.set("기본 편집 보기" if focused else "블록 편집 집중")
        if self._has_ui_attr("editor_tab"):
            if focused:
                self.editor_tab.columnconfigure(0, weight=3, minsize=620)
                self.editor_tab.columnconfigure(1, weight=2, minsize=560)
            else:
                self.editor_tab.columnconfigure(0, weight=2, minsize=520)
                self.editor_tab.columnconfigure(1, weight=3, minsize=680)
        if self._has_ui_attr("message_editor_left_frame"):
            self.message_editor_left_frame.rowconfigure(2, weight=5 if focused else 3)
        if self._has_ui_attr("message_block_frame"):
            self.message_block_frame.rowconfigure(2, weight=1)
            self.message_block_frame.rowconfigure(3, weight=4 if focused else 2)
        fixed_toggle_button = self.__dict__.get("message_fixed_toggle_button")
        if fixed_toggle_button is not None:
            try:
                fixed_toggle_button.configure(state="disabled" if focused else "normal")
            except Exception:
                pass
        if focused and self._has_ui_attr("message_fixed_section_collapsed_var"):
            self.message_fixed_section_collapsed_var.set(True)
        self._apply_message_fixed_section_visibility()
        if focused and self._has_ui_attr("editor_right_notebook"):
            try:
                template_name = self.message_template_var.get().strip() if self._has_ui_attr("message_template_var") else "Initial"
                target_tab = self.editor_handoff_preview_tab if template_name == "Handoff" else self.editor_initial_preview_tab
                if target_tab is not None:
                    self.editor_right_notebook.select(target_tab)
            except Exception:
                pass

    def toggle_message_block_focus_mode(self) -> None:
        if not self._has_ui_attr("message_block_focus_mode_var"):
            return
        self.message_block_focus_mode_var.set(not bool(self.message_block_focus_mode_var.get()))
        self._apply_message_block_focus_mode()

    def _selected_notebook_tab_id(self) -> str:
        notebook = self.__dict__.get("notebook")
        if notebook is None:
            return ""
        try:
            return str(notebook.select() or "")
        except tk.TclError:
            return ""

    def _current_next_step_summary(self) -> str:
        selected_tab = self._selected_notebook_tab_id()
        if self._has_ui_attr("visible_acceptance_tab") and selected_tab == str(self.visible_acceptance_tab):
            try:
                visible_state = self._build_visible_acceptance_state()
            except Exception:
                visible_state = None
            if visible_state is not None and visible_state.next_step:
                return f"Visible: {visible_state.next_step}"

        if self._has_ui_attr("artifacts_tab") and selected_tab == str(self.artifacts_tab):
            selected_state = self._selected_artifact_state() if self._has_ui_attr("artifact_tree") else None
            if selected_state is not None and getattr(self, "artifact_controller", None) is not None:
                preview = self.artifact_controller.get_preview(self.artifact_states, selected_state.target_id)
                if preview is not None:
                    if preview.recommended_action:
                        return f"Artifact: {preview.recommended_action}"
                    if preview.source_outbox_next_action:
                        next_action = self.artifact_service.display_next_action(preview.source_outbox_next_action)
                        return f"Artifact: {next_action}"

        if self.panel_state and self.panel_state.next_actions:
            return self.panel_state.next_actions[0].label
        if self.panel_state and self.panel_state.issues:
            return self.panel_state.issues[0].action_label
        if self._has_ui_attr("operator_hint_var"):
            hint = self.operator_hint_var.get().strip()
            if hint:
                return hint
        return "-"

    def _artifact_browse_scope_summary(self) -> str:
        if not self._artifact_home_browse_pair_scope_enabled():
            return ""
        pair_id = self._selected_artifact_browse_pair_id() or "(pair 없음)"
        if self._artifact_home_browse_target_scope_enabled():
            target_id = self._selected_artifact_browse_target_id() or "(target 없음)"
            return f"결과 browse={pair_id}@{target_id}"
        return f"결과 browse={pair_id}"

    def _artifact_browse_badge_spec(self) -> dict[str, str]:
        summary = self._artifact_browse_scope_summary()
        if not summary:
            return {"text": "", "background": "#6B7280", "foreground": "#FFFFFF"}
        if self._artifact_home_browse_target_scope_enabled():
            return {"text": summary, "background": "#7C3AED", "foreground": "#FFFFFF"}
        return {"text": summary, "background": "#A855F7", "foreground": "#FFFFFF"}

    def _recommended_action_button_label(self, action_key: str, fallback: str = "") -> str:
        normalized_key = str(action_key or "").strip()
        label = STICKY_ACTION_BUTTON_LABELS.get(normalized_key, "").strip()
        if label:
            return label
        label = self._visible_primitive_button_labels().get(normalized_key, "").strip()
        if label:
            return label
        return str(fallback or normalized_key or "다음 단계 실행").strip()

    def _sticky_action_button_label(self, action_key: str, fallback: str = "") -> str:
        return self._recommended_action_button_label(action_key, fallback)

    def _make_recommended_action_spec(
        self,
        action_key: str,
        *,
        fallback_label: str = "",
        command_text: str = "",
        read_only_action_key: str = "",
        source: str = "",
    ) -> dict[str, object]:
        normalized_key = str(action_key or "").strip()
        return {
            "action_key": normalized_key,
            "label": self._recommended_action_button_label(normalized_key, fallback_label),
            "command_text": str(command_text or ""),
            "read_only": self._dashboard_action_is_read_only(read_only_action_key or normalized_key),
            "source": str(source or ""),
        }

    def _sticky_action_candidates(self) -> list[dict[str, object]]:
        candidates: list[dict[str, object]] = []
        selected_tab = self._selected_notebook_tab_id()
        if self._has_ui_attr("visible_acceptance_tab") and selected_tab == str(self.visible_acceptance_tab):
            try:
                visible_state = self._build_visible_acceptance_state()
            except Exception:
                visible_state = None
            if visible_state is not None and visible_state.next_action_key:
                candidates.append(
                    self._make_recommended_action_spec(
                        visible_state.next_action_key,
                        fallback_label=visible_state.next_step,
                        source="visible_acceptance",
                    )
                )
                return candidates

        if self._has_ui_attr("artifacts_tab") and selected_tab == str(self.artifacts_tab):
            ready_target_exists = any(self.artifact_service.is_handoff_ready(item) for item in self.artifact_states)
            if ready_target_exists:
                candidates.append(
                    self._make_recommended_action_spec(
                        "focus_ready_to_forward_artifact",
                        source="artifacts",
                    )
                )
                return candidates

        if self.panel_state and self.panel_state.next_actions:
            action = self.panel_state.next_actions[0]
            if action.action_key:
                candidates.append(
                    self._make_recommended_action_spec(
                        action.action_key,
                        fallback_label=action.label,
                        command_text=action.command_text,
                        source="home_next_action",
                    )
                )
                return candidates

        recommendation = self._watcher_recommendation() if getattr(self, "watcher_controller", None) is not None else None
        if recommendation is not None and recommendation.action_key:
            candidates.append(
                self._make_recommended_action_spec(
                    "watcher_recommended_action",
                    fallback_label=recommendation.label,
                    read_only_action_key=recommendation.action_key,
                    source="watcher",
                )
            )
            return candidates

        if self.panel_state and self.panel_state.issues:
            issue = self.panel_state.issues[0]
            if issue.action_key:
                candidates.append(
                    self._make_recommended_action_spec(
                        issue.action_key,
                        fallback_label=issue.action_label,
                        source="issue",
                    )
                )
        return candidates

    def _current_sticky_action_spec(self) -> dict[str, object]:
        for candidate in self._sticky_action_candidates():
            if str(candidate.get("action_key", "") or "").strip():
                return candidate

        return {
            "action_key": "",
            "label": "",
            "command_text": "",
            "read_only": False,
            "source": "",
        }

    def _recommended_action_handlers(self) -> dict[str, object]:
        return {
            "watcher_recommended_action": self.apply_watcher_recommended_action,
            "visible_primitive_reuse": self.reuse_existing_windows,
            "visible_primitive_visibility": self.run_visibility_check,
            "visible_primitive_partner": self.select_partner_target_from_context,
            "visible_primitive_preview_refresh": self.refresh_message_editor_preview,
            "visible_primitive_save": self.save_message_editor,
            "visible_primitive_export": self.export_selected_row_messages,
            "visible_primitive_submit": self.run_selected_target_seed_submit,
            "visible_primitive_publish": self.inspect_selected_target_publish_status,
            "visible_primitive_handoff": self.inspect_selected_pair_handoff_status,
        }

    def _run_recommended_action(self, action_key: str, *, command_text: str = "") -> None:
        normalized_key = str(action_key or "").strip()
        if not normalized_key:
            return
        handler = self._recommended_action_handlers().get(normalized_key)
        if handler is not None:
            handler()
            return
        self.handle_dashboard_action(normalized_key, command_text=command_text)

    def run_sticky_recommended_action(self) -> None:
        action_key = str(getattr(self, "_sticky_next_action_key", "") or "").strip()
        command_text = str(getattr(self, "_sticky_next_action_command_text", "") or "")
        if not action_key:
            messagebox.showinfo("실행 항목 없음", "현재 문맥에서 바로 실행할 다음 단계가 없습니다.")
            return
        self._run_recommended_action(action_key, command_text=command_text)

    def _current_context_badge_spec(self) -> dict[str, str | bool]:
        inspection_context = self._selected_inspection_context_state()
        action_context = self._action_context_state()
        if not inspection_context.pair_id and not inspection_context.target_id:
            return {
                "text": "보고 대상 미고정",
                "background": "#6B7280",
                "foreground": "#FFFFFF",
                "apply_enabled": False,
            }
        if self._inspection_context_differs_from_action():
            badge_target = inspection_context.target_id or action_context.target_id or "(target 없음)"
            badge_pair = inspection_context.pair_id or action_context.pair_id or "(pair 없음)"
            return {
                "text": f"문맥 분리: 보고={badge_pair}/{badge_target}",
                "background": "#B45309",
                "foreground": "#FFFFFF",
                "apply_enabled": True,
            }
        return {
            "text": "문맥 일치",
            "background": "#166534",
            "foreground": "#FFFFFF",
            "apply_enabled": False,
        }

    def _refresh_sticky_context_bar(self) -> None:
        if not self._has_ui_attr("sticky_action_context_var"):
            return
        self.sticky_action_context_var.set(self._action_context_summary())
        self.sticky_inspection_context_var.set(self._inspection_context_summary())

        run_root_text = self._current_run_root_display_text()
        run_root_state = self.run_root_status_var.get().strip() if self._has_ui_attr("run_root_status_var") else ""
        if run_root_state:
            self.sticky_run_root_context_var.set(f"{run_root_text} ({run_root_state})")
        else:
            self.sticky_run_root_context_var.set(run_root_text)

        watcher_status = self._watcher_status() if getattr(self, "watcher_controller", None) is not None else "미확인"
        runtime_label = self.panel_state.overall_label if self.panel_state else (self.operator_status_var.get().strip() if self._has_ui_attr("operator_status_var") else "대기 중")
        headless_block_summary = self._shared_visible_typed_window_headless_block_summary()
        runtime_context_text = f"{runtime_label} / watcher={watcher_status or '미확인'}"
        if headless_block_summary:
            runtime_context_text = f"{runtime_context_text} / {headless_block_summary}"
        self.sticky_runtime_context_var.set(runtime_context_text)
        next_step_text = self._current_next_step_summary()
        if headless_block_summary:
            next_step_text = f"{next_step_text} / Visible Acceptance 경로 사용"
        self.sticky_next_step_var.set(next_step_text)
        action_spec = self._current_sticky_action_spec()
        action_key = str(action_spec.get("action_key", "") or "").strip()
        action_label = str(action_spec.get("label", "") or "").strip()
        command_text = str(action_spec.get("command_text", "") or "")
        read_only = bool(action_spec.get("read_only", False))
        self._sticky_next_action_key = action_key
        self._sticky_next_action_command_text = command_text
        self.sticky_next_action_button_var.set(
            f"실행: {action_label}" if action_key and action_label else "다음 단계 실행"
        )
        if self._has_ui_attr("sticky_next_action_button"):
            button_state = "normal" if (action_key and (read_only or not self._busy)) else "disabled"
            self.sticky_next_action_button.configure(state=button_state)
        badge_spec = self._current_context_badge_spec()
        self.sticky_context_badge_var.set(str(badge_spec.get("text", "") or "문맥 확인"))
        if self._has_ui_attr("sticky_context_badge_label"):
            try:
                self.sticky_context_badge_label.configure(
                    text=self.sticky_context_badge_var.get(),
                    bg=str(badge_spec.get("background", "#6B7280")),
                    fg=str(badge_spec.get("foreground", "#FFFFFF")),
                )
            except Exception:
                pass
        browse_badge_spec = self._artifact_browse_badge_spec()
        sticky_browse_var = self.__dict__.get("sticky_artifact_browse_var")
        if sticky_browse_var is not None and hasattr(sticky_browse_var, "set"):
            sticky_browse_var.set(str(browse_badge_spec.get("text", "") or ""))
        sticky_browse_label = self.__dict__.get("sticky_artifact_browse_label")
        if sticky_browse_label is not None:
            try:
                browse_text = str(browse_badge_spec.get("text", "") or "").strip()
                if browse_text:
                    sticky_browse_label.configure(
                        text=browse_text,
                        bg=str(browse_badge_spec.get("background", "#6B7280")),
                        fg=str(browse_badge_spec.get("foreground", "#FFFFFF")),
                    )
                    sticky_browse_label.grid()
                else:
                    sticky_browse_label.configure(text="")
                    sticky_browse_label.grid_remove()
            except Exception:
                pass
        result_badge_spec = self._result_panel_badge_spec()
        sticky_result_var = self.__dict__.get("sticky_result_panel_var")
        if sticky_result_var is not None and hasattr(sticky_result_var, "set"):
            sticky_result_var.set(str(result_badge_spec.get("text", "") or ""))
        sticky_result_label = self.__dict__.get("sticky_result_panel_label")
        if sticky_result_label is not None:
            try:
                sticky_result_label.configure(
                    text=str(result_badge_spec.get("text", "") or ""),
                    bg=str(result_badge_spec.get("background", "#6B7280")),
                    fg=str(result_badge_spec.get("foreground", "#FFFFFF")),
                )
            except Exception:
                pass
        if self._has_ui_attr("sticky_apply_context_button"):
            self.sticky_apply_context_button.configure(
                state="normal" if bool(badge_spec.get("apply_enabled", False)) else "disabled"
            )
        self._apply_home_pair_tree_highlights()
        self._refresh_pair_policy_card_focus_highlights()
        self._refresh_pair_focus_strip()
        self._apply_artifact_tree_highlights()

    @staticmethod
    def _message_editor_tab_meta(tab_key: str) -> dict[str, str]:
        return dict(MESSAGE_EDITOR_TAB_METADATA.get(tab_key, {}))

    def _register_message_editor_tab(self, notebook: ttk.Notebook, tab: ttk.Frame, *, tab_key: str) -> None:
        metadata = self._message_editor_tab_meta(tab_key)
        label = metadata.get("label", tab_key)
        notebook.add(tab, text=label)
        if "message_editor_tab_meta_by_widget" not in self.__dict__:
            self.message_editor_tab_meta_by_widget = {}
        self.message_editor_tab_meta_by_widget[str(tab)] = metadata

    def _message_editor_tab_heading_for_widget(self, widget_id: str) -> tuple[str, str]:
        metadata = self.__dict__.get("message_editor_tab_meta_by_widget", {}).get(widget_id, {})
        title = metadata.get("title") or "탭 안내"
        description = metadata.get("description") or "현재 선택 탭의 상세 정보를 표시합니다."
        return title, description

    def _refresh_message_editor_tab_heading(self) -> None:
        default_title = MESSAGE_EDITOR_TAB_METADATA["context"]["title"]
        default_description = MESSAGE_EDITOR_TAB_METADATA["context"]["description"]
        title = default_title
        description = default_description
        if self._has_ui_attr("editor_right_notebook"):
            try:
                selected_tab = self.editor_right_notebook.select()
            except TypeError:
                selected_tab = ""
            if selected_tab:
                title, description = self._message_editor_tab_heading_for_widget(str(selected_tab))
        if self._has_ui_attr("message_editor_tab_title_var"):
            self.message_editor_tab_title_var.set(title)
        if self._has_ui_attr("message_editor_tab_detail_var"):
            self.message_editor_tab_detail_var.set(description)

    def _on_message_editor_tab_changed(self, _event: object | None = None) -> None:
        self._refresh_message_editor_tab_heading()

    def _on_watcher_start_option_changed(self, *_args) -> None:
        self._refresh_watcher_start_note()

    def _watcher_should_use_headless_dispatch(self) -> bool:
        return not bool(self._shared_visible_typed_window_headless_block_reason())

    def _resolve_watcher_start_config_path(self, *, config_path: str, run_root: str, pair_id: str = "") -> str:
        resolved_config_path = str(config_path or "").strip()
        resolved_run_root = str(run_root or "").strip()
        if resolved_run_root:
            manifest_path = Path(resolved_run_root) / "manifest.json"
            if manifest_path.exists():
                try:
                    manifest_payload = json.loads(manifest_path.read_text(encoding="utf-8"))
                except Exception:
                    manifest_payload = {}
                manifest_config_path = str((manifest_payload or {}).get("ConfigPath", "") or "").strip()
                if manifest_config_path and Path(manifest_config_path).exists():
                    return manifest_config_path

        resolved_pair_id = str(pair_id or "").strip() or self._selected_pair_id()
        if not resolved_pair_id or not resolved_config_path:
            return resolved_config_path
        try:
            return self._resolve_run_prepare_config_path(pair_id=resolved_pair_id, config_path=resolved_config_path)
        except Exception:
            return resolved_config_path

    def _watcher_quick_start_request(self, *, config_path: str, run_root: str) -> WatcherStartRequest:
        effective_config_path = self._resolve_watcher_start_config_path(
            config_path=config_path,
            run_root=run_root,
        )
        return WatcherStartRequest(
            config_path=effective_config_path,
            run_root=run_root,
            use_headless_dispatch=self._watcher_should_use_headless_dispatch(),
            max_forward_count=DEFAULT_WATCHER_MAX_FORWARD_COUNT,
            run_duration_sec=DEFAULT_WATCHER_RUN_DURATION_SEC,
        )

    def _watcher_current_request_from_status(
        self,
        *,
        config_path: str,
        run_root: str,
    ) -> WatcherStartRequest | None:
        return self.watcher_controller.configured_start_request(
            self.paired_status_data,
            config_path=config_path,
            run_root=run_root,
        )

    def _watcher_start_option_int(self, value: str, *, label: str) -> int:
        text = (value or "").strip()
        if not text:
            raise ValueError(f"{label} 값이 비어 있습니다.")
        try:
            parsed = int(text)
        except ValueError as exc:
            raise ValueError(f"{label} 값은 0 이상의 정수여야 합니다.") from exc
        if parsed < 0:
            raise ValueError(f"{label} 값은 0 이상의 정수여야 합니다.")
        return parsed

    def _watcher_start_option_value(self, name: str, *, default: int) -> str:
        if not self._has_ui_attr(name):
            return str(default)
        try:
            variable = object.__getattribute__(self, name)
            return str(variable.get())
        except (AttributeError, RecursionError, tk.TclError):
            return str(default)

    def _build_watcher_start_request_from_controls(
        self,
        *,
        config_path: str,
        run_root: str,
        show_error: bool,
    ) -> WatcherStartRequest | None:
        try:
            max_forward_count = self._watcher_start_option_int(
                self._watcher_start_option_value(
                    "watcher_max_forward_var",
                    default=DEFAULT_WATCHER_MAX_FORWARD_COUNT,
                ),
                label="MaxForwardCount",
            )
            run_duration_sec = self._watcher_start_option_int(
                self._watcher_start_option_value(
                    "watcher_run_duration_var",
                    default=DEFAULT_WATCHER_RUN_DURATION_SEC,
                ),
                label="RunDurationSec",
            )
            pair_max_roundtrip_count = self._watcher_start_option_int(
                self._watcher_start_option_value(
                    "watcher_pair_roundtrip_var",
                    default=0,
                ),
                label="PairMaxRoundtripCount",
            )
        except ValueError as exc:
            if show_error:
                messagebox.showwarning("watch 시작 옵션 오류", str(exc))
            return None

        effective_config_path = self._resolve_watcher_start_config_path(
            config_path=config_path,
            run_root=run_root,
        )
        return WatcherStartRequest(
            config_path=effective_config_path,
            run_root=run_root,
            use_headless_dispatch=self._watcher_should_use_headless_dispatch(),
            max_forward_count=max_forward_count,
            run_duration_sec=run_duration_sec,
            pair_max_roundtrip_count=pair_max_roundtrip_count,
        )

    def _refresh_watcher_start_note(self) -> None:
        request = self._build_watcher_start_request_from_controls(
            config_path="",
            run_root="",
            show_error=False,
        )
        if request is None:
            self.watcher_start_note_var.set("다음 시작값: watch 시작 옵션 오류, 0 이상의 정수만 입력할 수 있습니다. 0은 제한 없음입니다.")
            return
        self.watcher_start_note_var.set(
            "다음 시작값: " + self.watcher_controller.describe_start_request(request) + " | 0은 해당 제한 없음"
        )

    def _refresh_watcher_runtime_note(self) -> None:
        request = self._watcher_current_request_from_status(config_path="", run_root="")
        watcher = ((self.paired_status_data or {}).get("Watcher", {}) or {})
        watcher_status = str(watcher.get("Status", "") or "").strip()
        if request is None:
            suffix = f" | status={watcher_status}" if watcher_status else ""
            self.watcher_current_note_var.set("현재 watcher 값: watcher status 파일 없음" + suffix)
            return
        status_suffix = f" | status={watcher_status}" if watcher_status else ""
        self.watcher_current_note_var.set(
            "현재 watcher 값: " + self.watcher_controller.describe_start_request(request) + status_suffix
        )

    def _refresh_watcher_quick_start_note(self) -> None:
        request = self._watcher_quick_start_request(config_path="", run_root="")
        self.watcher_quick_start_note_var.set(
            "기본 quick start: " + self.watcher_controller.describe_start_request(request)
        )

    def _refresh_watcher_notes(self) -> None:
        self._refresh_watcher_quick_start_note()
        self._refresh_watcher_runtime_note()
        self._refresh_watcher_start_note()

    def reset_watcher_start_options(self) -> None:
        self.watcher_max_forward_var.set(str(DEFAULT_WATCHER_MAX_FORWARD_COUNT))
        self.watcher_run_duration_var.set(str(DEFAULT_WATCHER_RUN_DURATION_SEC))
        self.watcher_pair_roundtrip_var.set("0")

    def load_watcher_start_options_from_status(self, *, show_message: bool = True) -> bool:
        watcher = ((self.paired_status_data or {}).get("Watcher", {}) or {})
        if not watcher:
            if show_message:
                messagebox.showinfo("watch 옵션 불러오기", "현재 paired status에 watcher 정보가 없습니다.")
            return False
        request = self._watcher_current_request_from_status(config_path="", run_root="")
        if request is None:
            if show_message:
                messagebox.showinfo("watch 옵션 불러오기", "현재 watcher status 파일이 없어 옵션을 불러올 수 없습니다.")
            return False
        self.watcher_max_forward_var.set(str(request.max_forward_count))
        self.watcher_run_duration_var.set(str(request.run_duration_sec))
        self.watcher_pair_roundtrip_var.set(str(request.pair_max_roundtrip_count))
        self._refresh_watcher_runtime_note()
        if show_message:
            messagebox.showinfo("watch 옵션 불러오기", "현재 watcher status의 시작 옵션을 입력칸에 반영했습니다.")
        return True

    def _current_context(self) -> AppContext:
        return self._action_context_state().as_app_context()

    def _effective_refresh_context(self) -> AppContext:
        context = self._action_context_state()
        if self._run_root_override_state() != "override-active":
            return ActionContextState(
                config_path=context.config_path,
                run_root="",
                pair_id=context.pair_id,
                target_id=context.target_id,
                source=context.source,
            ).as_app_context()
        return context.as_app_context()

    def _same_run_root_path(self, left: object, right: object) -> bool:
        normalized_left = self._normalized_optional_path(left)
        normalized_right = self._normalized_optional_path(right)
        if not normalized_left or not normalized_right:
            return False
        return normalized_left == normalized_right

    def _action_context_state(self) -> ActionContextState:
        return ActionContextState(
            config_path=self.config_path_var.get().strip(),
            run_root=self._current_run_root_for_actions(),
            pair_id=self._selected_pair_id(),
            target_id=self.target_id_var.get().strip(),
            source=str(self.__dict__.get("action_context_source", "") or "controls"),
        )

    def _set_action_context(
        self,
        *,
        pair_id: str | None = None,
        target_id: str | None = None,
        run_root: str | None = None,
        source: str = "",
    ) -> ActionContextState:
        if pair_id is not None:
            self.pair_id_var.set(str(pair_id or "").strip())
        if target_id is not None:
            self.target_id_var.set(str(target_id or "").strip())
        if run_root is not None and self._has_ui_attr("run_root_var"):
            self.run_root_var.set(str(run_root or "").strip())
        if source:
            self.action_context_source = str(source or "").strip()
        return self._action_context_state()

    def _context_source_label(self, source: str) -> str:
        return context_source_label(source)

    def _action_context_summary(self, context: ActionContextState | None = None) -> str:
        action_context = context or self._action_context_state()
        return format_action_context_summary(action_context)

    def _snapshot_context(
        self,
        *,
        run_root: str | None = None,
        pair_id: str | None = None,
        target_id: str | None = None,
    ) -> AppContext:
        current = self._current_context()
        return AppContext(
            config_path=current.config_path,
            run_root=current.run_root if run_root is None else run_root,
            pair_id=current.pair_id if pair_id is None else pair_id,
            target_id=current.target_id if target_id is None else target_id,
        )

    def _artifact_query_context_state(self) -> ArtifactQueryContextState:
        pair_var = self.__dict__.get("artifact_pair_filter_var", None)
        target_var = self.__dict__.get("artifact_target_filter_var", None)
        path_kind_var = self.__dict__.get("artifact_path_kind_var", None)
        latest_only_var = self.__dict__.get("artifact_latest_only_var", None)
        include_missing_var = self.__dict__.get("artifact_include_missing_var", None)
        path_kind_label = path_kind_var.get() if path_kind_var is not None and hasattr(path_kind_var, "get") else "summary"
        return ArtifactQueryContextState(
            run_root=self._current_run_root_for_artifacts(),
            pair_id=pair_var.get().strip() if pair_var is not None and hasattr(pair_var, "get") else "",
            target_id=target_var.get().strip() if target_var is not None and hasattr(target_var, "get") else "",
            path_kind=ARTIFACT_PATH_LABEL_TO_KIND.get(path_kind_label, path_kind_label),
            latest_only=bool(latest_only_var.get()) if latest_only_var is not None and hasattr(latest_only_var, "get") else False,
            include_missing=bool(include_missing_var.get()) if include_missing_var is not None and hasattr(include_missing_var, "get") else True,
        )

    def _artifact_query_context_summary(self, context: ArtifactQueryContextState | None = None) -> str:
        artifact_context = context or self._artifact_query_context_state()
        return format_artifact_query_context_summary(artifact_context)

    def _selected_preview_row_index(self) -> int | None:
        if not self._has_ui_attr("row_tree"):
            return None
        selection_method = getattr(self.row_tree, "selection", None)
        if selection_method is None:
            return None
        selection = selection_method()
        if not selection:
            return None
        try:
            return int(selection[0])
        except (TypeError, ValueError):
            return None

    def _stored_inspection_context_state(self) -> InspectionContextState:
        row_index = self.__dict__.get("inspection_context_row_index", None)
        if not isinstance(row_index, int):
            row_index = None
        return InspectionContextState(
            pair_id=str(self.__dict__.get("inspection_pair_id", "") or "").strip(),
            target_id=str(self.__dict__.get("inspection_target_id", "") or "").strip(),
            source=str(self.__dict__.get("inspection_context_source", "") or "").strip(),
            row_index=row_index,
        )

    def _selected_inspection_context_state(self) -> InspectionContextState:
        row = self._selected_preview_row() or {}
        row_index = self._selected_preview_row_index()
        stored = self._stored_inspection_context_state()
        fallback_target = ""
        row_pair_id = str(row.get("PairId", "") or stored.pair_id or "").strip()
        pair_controller = self.__dict__.get("pair_controller")
        if row_pair_id and pair_controller is not None:
            fallback_target = pair_controller.resolve_top_target_for_pair(self.preview_rows, row_pair_id)
        return resolve_inspection_context(
            selected_row=row,
            selected_row_index=row_index,
            stored=stored,
            fallback_target_id=fallback_target,
        )

    def _inspection_context_summary(self, context: InspectionContextState | None = None) -> str:
        inspection_context = context or self._selected_inspection_context_state()
        return format_inspection_context_summary(inspection_context)

    def _prepare_run_root_action_context(self, *, ignored_run_root: str = "") -> AppContext:
        current_context = self._snapshot_context()
        normalized_ignored = str(ignored_run_root or "").strip()
        if not normalized_ignored:
            return current_context

        selected_run_root = ""
        if self.effective_data:
            selected_run_root = str(self.effective_data.get("RunContext", {}).get("SelectedRunRoot", "") or "").strip()
        if selected_run_root and os.path.normcase(os.path.normpath(selected_run_root)) == os.path.normcase(
            os.path.normpath(normalized_ignored)
        ):
            selected_run_root = ""

        return ActionContextState(
            config_path=current_context.config_path,
            run_root=selected_run_root,
            pair_id=current_context.pair_id,
            target_id=current_context.target_id,
            source=self._action_context_state().source,
        ).as_app_context()

    def _runtime_workflow(self) -> PanelRuntimeWorkflowService:
        service = self.__dict__.get("runtime_workflow_service")
        if (
            service is None
            or getattr(service, "command_service", None) is not self.command_service
            or getattr(service, "status_service", None) is not self.status_service
            or getattr(service, "refresh_controller", None) is not self.refresh_controller
        ):
            service = PanelRuntimeWorkflowService(
                self.command_service,
                self.status_service,
                self.refresh_controller,
            )
            self.runtime_workflow_service = service
        return service

    def _resolve_run_prepare_config_path(self, *, pair_id: str, config_path: str) -> str:
        resolved_config_path = str(config_path or "").strip()
        if not resolved_config_path:
            return resolved_config_path

        config_file = Path(resolved_config_path)
        if not config_file.exists():
            return resolved_config_path

        try:
            document = self.message_config_service.load_config_document(resolved_config_path)
            effective_policy = self.message_config_service.effective_pair_policy(document, pair_id)
        except Exception:
            return resolved_config_path

        use_external_pair_roots = bool(
            effective_policy.get("UseExternalWorkRepoRunRoot", False)
            or effective_policy.get("UseExternalWorkRepoContractPaths", False)
        )
        pair_work_repo_root = str(effective_policy.get("DefaultSeedWorkRepoRoot", "") or "").strip()
        if not use_external_pair_roots or not pair_work_repo_root:
            return resolved_config_path

        build_helper = getattr(self.command_service, "build_powershell_file_command", None)
        if build_helper is None:
            raise RuntimeError("pair-scoped externalized config helper를 사용할 수 없습니다.")

        helper_command = build_helper(
            str(ROOT / "tests" / "Write-PairExternalizedRelayConfigs.ps1"),
            extra=[
                "-BaseConfigPath",
                resolved_config_path,
                "-PairId",
                pair_id,
                "-AsJson",
            ],
        )
        try:
            if hasattr(self.command_service, "run_json"):
                payload = self.command_service.run_json(helper_command)
            else:
                completed = self.command_service.run(helper_command)
                payload = json.loads(completed.stdout)
        except Exception as exc:
            raise RuntimeError(f"{pair_id} pair-scoped externalized config 생성 실패: {exc}") from exc

        generated_configs = list(payload.get("GeneratedConfigs", []) or [])
        matched_config = next(
            (
                item
                for item in generated_configs
                if str((item or {}).get("PairId", "") or "").strip() == str(pair_id or "").strip()
            ),
            {},
        )
        output_config_path = str((matched_config or {}).get("OutputConfigPath", "") or "").strip()
        if not output_config_path:
            raise RuntimeError(f"{pair_id} externalized config 경로를 확인하지 못했습니다.")
        return output_config_path

    def _path_is_within_root(self, path_value: object, root_value: object) -> bool:
        normalized_path = str(path_value or "").strip()
        normalized_root = str(root_value or "").strip()
        if not normalized_path or not normalized_root:
            return False
        try:
            candidate = os.path.normcase(os.path.abspath(normalized_path))
            root = os.path.normcase(os.path.abspath(normalized_root))
            return os.path.commonpath([candidate, root]) == root
        except Exception:
            return False

    def _resolved_output_paths_from_row(self, row: dict[str, object] | None) -> dict[str, str]:
        normalized_row = dict(row or {})
        output_files = dict(normalized_row.get("OutputFiles", {}) or {})
        return {
            "SourceSummaryPath": str(
                output_files.get("SummaryPath", "")
                or normalized_row.get("SourceSummaryPath", "")
                or ""
            ).strip(),
            "SourceReviewZipPath": str(
                output_files.get("ReviewZipPath", "")
                or normalized_row.get("SourceReviewZipPath", "")
                or ""
            ).strip(),
            "PublishReadyPath": str(
                output_files.get("PublishReadyPath", "")
                or normalized_row.get("PublishReadyPath", "")
                or ""
            ).strip(),
        }

    def _resolved_source_outbox_path_analysis_from_row(self, row: dict[str, object] | None) -> tuple[str, str]:
        normalized_row = dict(row or {})
        direct_path = str(normalized_row.get("SourceOutboxPath", "") or "").strip()
        if direct_path:
            return direct_path, ""
        output_paths = self._resolved_output_paths_from_row(normalized_row)
        parent_paths: list[str] = []
        for key in ("SourceSummaryPath", "SourceReviewZipPath", "PublishReadyPath"):
            path_value = str(output_paths.get(key, "") or "").strip()
            if not path_value:
                continue
            parent_path = str(Path(path_value).parent).strip()
            if parent_path:
                parent_paths.append(parent_path)
        unique_parents = list(dict.fromkeys(parent_paths))
        if len(unique_parents) == 1:
            return unique_parents[0], ""
        if len(unique_parents) > 1:
            return "", "output-files-parent-mismatch"
        return "", ""

    def _resolved_source_outbox_path_from_row(self, row: dict[str, object] | None) -> str:
        resolved_path, _warning = self._resolved_source_outbox_path_analysis_from_row(row)
        return resolved_path

    def _resolved_source_outbox_warning_from_row(self, row: dict[str, object] | None) -> str:
        _resolved_path, warning = self._resolved_source_outbox_path_analysis_from_row(row)
        return warning

    def _path_is_direct_child_within_root(self, path_value: object, root_value: object) -> bool:
        normalized_path = str(path_value or "").strip()
        normalized_root = str(root_value or "").strip()
        if not normalized_path or not normalized_root:
            return False
        if not self._path_is_within_root(normalized_path, normalized_root):
            return False
        try:
            candidate = os.path.abspath(normalized_path)
            root = os.path.abspath(normalized_root)
            relative_path = os.path.relpath(candidate, root)
        except Exception:
            return False
        relative_path = str(relative_path or "").strip()
        if not relative_path or relative_path == ".":
            return False
        segments = [segment for segment in relative_path.split(os.sep) if segment and segment != "."]
        return len(segments) == 1

    def _pair_policy_preview_run_root_base(self, *, pair_id: str, policy: dict[str, object]) -> str:
        pair_work_repo_root = str(policy.get("DefaultSeedWorkRepoRoot", "") or "").strip()
        use_external_pair_roots = bool(
            policy.get("UseExternalWorkRepoRunRoot", False)
            or policy.get("UseExternalWorkRepoContractPaths", False)
        )
        if not use_external_pair_roots or not pair_work_repo_root or not pair_id:
            return ""
        return str(
            Path(pair_work_repo_root)
            / ".relay-runs"
            / "bottest-live-visible"
            / "pairs"
            / pair_id
        )

    def _pair_policy_preview_run_root(self, *, pair_id: str, policy: dict[str, object]) -> str:
        expected_run_root_base = self._pair_policy_preview_run_root_base(
            pair_id=pair_id,
            policy=policy,
        )
        if not expected_run_root_base:
            return self._draft_message_preview_run_root()

        explicit_run_root = str(self.run_root_var.get() or "").strip()
        if (
            explicit_run_root
            and self._path_is_direct_child_within_root(explicit_run_root, expected_run_root_base)
        ):
            return explicit_run_root

        selected_run_root = str((self.effective_data or {}).get("RunContext", {}).get("SelectedRunRoot", "") or "").strip()
        if (
            selected_run_root
            and self._path_is_direct_child_within_root(selected_run_root, expected_run_root_base)
        ):
            return selected_run_root

        return ""

    def _render_pair_policy_effective_preview(
        self,
        *,
        document: dict[str, object],
        config_path: str,
        pair_id: str,
        target_id: str,
        mode: str,
    ) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as temp_dir:
            draft_config_path = Path(temp_dir) / (Path(config_path).name or "settings.preview.psd1")
            serialized = self.message_config_service.serialize_psd1(document).replace("\n", "\r\n")
            draft_config_path.write_text(serialized, encoding="utf-8")
            preview_config_path = self._resolve_run_prepare_config_path(
                pair_id=pair_id,
                config_path=str(draft_config_path),
            )
            preview_document = self.message_config_service.load_config_document(preview_config_path)
            preview_policy = self.message_config_service.effective_pair_policy(preview_document, pair_id)
            preview_run_root = self._pair_policy_preview_run_root(
                pair_id=pair_id,
                policy=preview_policy,
            )
            return self.message_config_service.render_effective_preview(
                preview_document,
                config_path=preview_config_path,
                run_root=preview_run_root,
                pair_id=pair_id,
                target_id=target_id,
                mode=mode,
            )

    def _render_all_pair_policy_effective_previews(
        self,
        *,
        document: dict[str, object],
        config_path: str,
        pair_ids: list[str],
        mode: str,
    ) -> dict[str, object]:
        preview_rows: list[object] = []
        warnings: list[str] = []
        pair_payloads: dict[str, object] = {}
        for current_pair_id in pair_ids:
            payload = self._render_pair_policy_effective_preview(
                document=document,
                config_path=config_path,
                pair_id=current_pair_id,
                target_id="",
                mode=mode,
            )
            pair_payloads[current_pair_id] = payload
            preview_rows.extend(list(payload.get("PreviewRows", []) or []))
            warnings.extend(str(item) for item in list(payload.get("Warnings", []) or []))
        unique_warnings = list(dict.fromkeys(item for item in warnings if item))
        return {
            "PreviewRows": preview_rows,
            "Warnings": unique_warnings,
            "PairPayloads": pair_payloads,
        }

    def _apply_pair_policy_effective_preview_payload(
        self,
        *,
        document: dict[str, object],
        pair_ids: list[str],
        payload: dict[str, object],
    ) -> dict[str, int]:
        warnings = [str(item) for item in list(payload.get("Warnings", []) or [])]
        rows = list(payload.get("PreviewRows", []) or [])
        self.pair_policy_effective_preview_rows = rows
        ok_count = 0
        shared_count = 0
        check_count = 0
        for current_pair_id in pair_ids:
            policy = self.message_config_service.effective_pair_policy(document, current_pair_id)
            self._apply_pair_policy_source_feedback(pair_id=current_pair_id, policy=policy)
            pair_rows = [row for row in rows if str(row.get("PairId", "") or "").strip() == current_pair_id]
            route_snapshot = self._pair_policy_card_preview_route_snapshot(
                rows=pair_rows,
                pair_id=current_pair_id,
                pair_work_repo_root=str(policy.get("DefaultSeedWorkRepoRoot", "") or ""),
                policy=policy,
            )
            self._apply_pair_policy_route_feedback(
                pair_id=current_pair_id,
                route_snapshot=route_snapshot,
                pair_work_repo_root=str(policy.get("DefaultSeedWorkRepoRoot", "") or ""),
            )
            store = self._pair_policy_card_store(current_pair_id)
            store["effective_preview_var"].set(
                self._pair_policy_build_preview_text(
                    pair_id=current_pair_id,
                    policy=policy,
                    route_snapshot=route_snapshot,
                    warnings=warnings,
                )
            )
            self._sync_pair_policy_effective_preview_widget(current_pair_id)
            badge_text = str(store["route_badge_var"].get() or "")
            if badge_text == "ROUTE OK":
                ok_count += 1
            elif badge_text == "SHARED REPO OK":
                shared_count += 1
            else:
                check_count += 1
        return {
            "warnings": len(warnings),
            "ok": ok_count,
            "shared": shared_count,
            "check": check_count,
        }

    def _watcher_workflow(self) -> PanelWatcherWorkflowService:
        service = self.__dict__.get("watcher_workflow_service")
        if (
            service is None
            or getattr(service, "watcher_controller", None) is not self.watcher_controller
            or getattr(service, "command_service", None) is not self.command_service
            or getattr(service, "status_service", None) is not self.status_service
        ):
            service = PanelWatcherWorkflowService(
                self.watcher_controller,
                self.command_service,
                self.status_service,
            )
            self.watcher_workflow_service = service
        return service

    def _utc_now_iso(self) -> str:
        return datetime.now(timezone.utc).isoformat()

    def _on_run_root_value_changed(self, *_args: object) -> None:
        self._update_run_root_controls()
        self._schedule_run_root_context_refresh()

    def _cancel_pending_ui_callbacks(self) -> None:
        pending_after_id = self.__dict__.get("run_root_context_refresh_after_id", None)
        if pending_after_id and "tk" in self.__dict__:
            try:
                self.after_cancel(pending_after_id)
            except tk.TclError:
                pass
        self.run_root_context_refresh_after_id = None

    def _schedule_run_root_context_refresh(self, *, immediate: bool = False) -> None:
        self._cancel_pending_ui_callbacks()

        if immediate or "tk" not in self.__dict__:
            self._apply_run_root_context_refresh()
            return

        self.run_root_context_refresh_after_id = self.after(
            RUN_ROOT_CONTEXT_REFRESH_DEBOUNCE_MS,
            self._flush_run_root_context_refresh,
        )

    def _flush_run_root_context_refresh(self) -> None:
        self.run_root_context_refresh_after_id = None
        self._apply_run_root_context_refresh()

    def _apply_run_root_context_refresh(self) -> None:
        if not self.effective_data:
            return
        self.rebuild_panel_state()
        if self._has_ui_attr("artifact_tree"):
            self.refresh_artifacts_tab()
        self.update_pair_button_states()
        self._refresh_sticky_context_bar()

    def _set_mode_banner(self, label: str, detail: str) -> None:
        self._mode_banner_label = label
        self._mode_banner_detail = detail
        if self._has_ui_attr("mode_banner_var"):
            self.mode_banner_var.set(label)
        if self._has_ui_attr("mode_banner_detail_var"):
            self.mode_banner_detail_var.set(detail)
        self._refresh_sticky_context_bar()

    def _set_visible_mode_banner(self, label: str, detail: str) -> None:
        self._last_visible_mode_label = label
        self._last_visible_mode_detail = detail
        self._set_mode_banner(label, detail)

    def on_notebook_tab_changed(self, _event: object | None = None) -> None:
        notebook = self.__dict__.get("notebook")
        if notebook is None:
            return
        try:
            selected_tab = notebook.select()
        except tk.TclError:
            return

        if self._has_ui_attr("ops_tab") and selected_tab == str(self.ops_tab):
            self._set_mode_banner("MODE: Headless Drill", "headless drill / transport closure / 진단 중심으로 작업합니다.")
            return
        if self._has_ui_attr("visible_acceptance_tab") and selected_tab == str(self.visible_acceptance_tab):
            self._set_mode_banner(self._last_visible_mode_label, self._last_visible_mode_detail)
            return
        if self._has_ui_attr("artifacts_tab") and selected_tab == str(self.artifacts_tab):
            self._set_mode_banner("MODE: Recovery", "artifact / receipt / watcher evidence 검토 및 복구 중심으로 작업합니다.")
            return
        self._refresh_sticky_context_bar()

    def destroy(self) -> None:
        self._cancel_pending_ui_callbacks()
        super().destroy()

    def _run_root_timing_snapshot(self, run_root: str) -> dict[str, object]:
        run_context = (self.effective_data or {}).get("RunContext", {}) or {}
        threshold = int(run_context.get("StaleRunThresholdSec", 1800) or 1800)
        candidate = str(run_root or "").strip()
        snapshot: dict[str, object] = {
            "RunRoot": candidate,
            "ObservedAt": self._utc_now_iso(),
            "LastWriteAt": "",
            "AgeSeconds": None,
            "ThresholdSec": threshold,
        }
        if not candidate:
            return snapshot

        selected_run_root = str(run_context.get("SelectedRunRoot", "") or "").strip()
        normalized_candidate = os.path.normcase(os.path.normpath(candidate))
        normalized_selected = os.path.normcase(os.path.normpath(selected_run_root)) if selected_run_root else ""

        run_root_path = Path(candidate)
        if run_root_path.exists():
            try:
                stat = run_root_path.stat()
            except OSError:
                pass
            else:
                snapshot["LastWriteAt"] = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
                snapshot["AgeSeconds"] = max(0.0, datetime.now(timezone.utc).timestamp() - stat.st_mtime)
                return snapshot

        if selected_run_root and normalized_candidate == normalized_selected:
            snapshot["LastWriteAt"] = str(run_context.get("SelectedRunRootLastWriteAt", "") or "")
            age_seconds = run_context.get("SelectedRunRootAgeSeconds", None)
            try:
                snapshot["AgeSeconds"] = float(age_seconds) if age_seconds not in ("", None) else None
            except (TypeError, ValueError):
                snapshot["AgeSeconds"] = None
        return snapshot

    def _update_run_root_controls(self) -> None:
        if "run_root_label_var" not in self.__dict__ or "run_root_status_var" not in self.__dict__:
            return

        action_run_root = self._current_run_root_for_actions()
        explicit_run_root = self.run_root_var.get().strip()
        override_state = self._run_root_override_state()
        snapshot = self._run_root_timing_snapshot(action_run_root)
        threshold = int(snapshot.get("ThresholdSec", 1800) or 1800)
        age_seconds = snapshot.get("AgeSeconds", None)
        age_text = ""
        if isinstance(age_seconds, (int, float)):
            age_text = "{0:.0f}s/{1}s".format(float(age_seconds), threshold)

        if not action_run_root:
            self.run_root_label_var.set("RunRoot Override")
            self.run_root_status_var.set("AUTO")
            if "run_root_help_var" in self.__dict__:
                self.run_root_help_var.set("비워두면 pair 정책 기준 selected/new RunRoot를 사용합니다.")
            self._refresh_pair_policy_override_badges()
            self._refresh_sticky_context_bar()
            return

        if self._run_root_is_stale(action_run_root):
            self.run_root_label_var.set("RunRoot Override")
            self.run_root_status_var.set("STALE {0}".format(age_text or f"threshold={threshold}s"))
            if "run_root_help_var" in self.__dict__:
                if override_state == "override-active":
                    self.run_root_help_var.set("입력한 runroot가 stale입니다. 새 RunRoot 준비 또는 입력 비우기")
                elif override_state == "mirror-selected":
                    self.run_root_help_var.set("selected runroot가 stale입니다. 새 RunRoot 준비 또는 입력 비우기")
                else:
                    self.run_root_help_var.set("현재 runroot가 stale입니다. 새 RunRoot 준비 또는 입력 비우기")
            self._refresh_pair_policy_override_badges()
            self._refresh_sticky_context_bar()
            return

        if override_state == "override-active":
            self.run_root_label_var.set("RunRoot Override")
            self.run_root_status_var.set("OVERRIDE ACTIVE {0}".format(age_text or "selected"))
            if "run_root_help_var" in self.__dict__:
                self.run_root_help_var.set("입력한 runroot가 pair 정책보다 우선합니다.")
            self._refresh_pair_policy_override_badges()
            self._refresh_sticky_context_bar()
            return

        if override_state == "mirror-selected":
            self.run_root_label_var.set("RunRoot Override")
            self.run_root_status_var.set("SELECTED MIRROR {0}".format(age_text or "selected"))
            if "run_root_help_var" in self.__dict__:
                self.run_root_help_var.set("현재 선택된 runroot를 그대로 보고 있습니다. pair 정책 기준으로 보려면 입력을 비우세요.")
            self._refresh_pair_policy_override_badges()
            self._refresh_sticky_context_bar()
            return

        self.run_root_label_var.set("RunRoot Override")
        self.run_root_status_var.set("AUTO {0}".format(age_text or "latest"))
        if "run_root_help_var" in self.__dict__:
            self.run_root_help_var.set("비워두면 pair 정책 기준 selected/new RunRoot를 사용합니다.")
        self._refresh_pair_policy_override_badges()
        self._refresh_sticky_context_bar()

    def _run_root_override_state(self) -> str:
        explicit_run_root = str(self.run_root_var.get() or "").strip()
        if not explicit_run_root:
            return "auto"
        selected_run_root = str((self.effective_data or {}).get("RunContext", {}).get("SelectedRunRoot", "") or "").strip()
        if self._same_run_root_path(explicit_run_root, selected_run_root):
            return "mirror-selected"
        return "override-active"

    def _panel_runtime_hints(self) -> dict[str, object]:
        run_context = (self.effective_data or {}).get("RunContext", {}) or {}
        action_run_root = self._current_run_root_for_actions()
        action_run_root_uses_override = (self._run_root_override_state() == "override-active")
        action_run_root_snapshot = self._run_root_timing_snapshot(action_run_root)
        wrapper_path = self._launcher_wrapper_path()
        return {
            "PanelOpenedAtUtc": str(self.__dict__.get("panel_opened_at_utc", "") or ""),
            "WindowLaunchAnchorUtc": str(self.__dict__.get("window_launch_anchor_utc", "") or ""),
            "WindowLaunchMode": "wrapper" if wrapper_path else "",
            "WindowReuseMode": "attach-only" if wrapper_path else "",
            "LauncherWrapperPath": wrapper_path,
            "ActionRunRoot": action_run_root,
            "ActionRunRootUsesOverride": action_run_root_uses_override,
            "ActionRunRootIsStale": self._current_run_root_is_stale_for_actions(),
            "ActionRunRootObservedAt": str(action_run_root_snapshot.get("ObservedAt", "") or ""),
            "ActionRunRootLastWriteAt": str(action_run_root_snapshot.get("LastWriteAt", "") or ""),
            "ActionRunRootAgeSeconds": action_run_root_snapshot.get("AgeSeconds", None),
            "ActionRunRootThresholdSec": action_run_root_snapshot.get("ThresholdSec", 1800),
        }

    def _current_run_root_display_text(self) -> str:
        action_run_root = self._current_run_root_for_actions()
        if not action_run_root:
            return "(없음)"
        if self._run_root_override_state() == "override-active":
            return "{0} (override)".format(action_run_root)
        return action_run_root

    def clear_run_root_input(self) -> None:
        if not self.run_root_var.get().strip():
            return
        self.run_root_var.set("")
        self._schedule_run_root_context_refresh(immediate=True)
        self.set_operator_status(
            "RunRoot 입력 비움",
            "explicit RunRoot 입력을 비웠습니다. 이후 동작은 선택된 RunRoot를 다시 사용합니다.",
            "마지막 결과: RunRoot 입력칸 비움",
        )

    def _pair_policy_repo_source_badge_spec(self, policy: dict[str, object]) -> dict[str, str]:
        source = str(policy.get("DefaultSeedWorkRepoRootSource", "") or "unset").strip()
        if source == "pair-policy":
            return {"text": "PAIR POLICY", "background": "#1D4ED8", "foreground": "#FFFFFF"}
        if source == "global-default":
            return {"text": "GLOBAL DEFAULT", "background": "#92400E", "foreground": "#FFFFFF"}
        return {"text": "REPO UNSET", "background": "#6B7280", "foreground": "#FFFFFF"}

    def _run_root_override_badge_spec(self) -> dict[str, str]:
        state = self._run_root_override_state()
        if state == "override-active":
            return {"text": "RUNROOT OVERRIDE ACTIVE", "background": "#B45309", "foreground": "#FFFFFF"}
        if state == "mirror-selected":
            return {"text": "RUNROOT SELECTED MIRROR", "background": "#2563EB", "foreground": "#FFFFFF"}
        return {"text": "RUNROOT AUTO", "background": "#6B7280", "foreground": "#FFFFFF"}

    def _apply_pair_policy_source_feedback(self, *, pair_id: str, policy: dict[str, object]) -> None:
        store = self._pair_policy_card_store(pair_id)
        badge_spec = self._pair_policy_repo_source_badge_spec(policy)
        store["repo_source_badge_var"].set(badge_spec["text"])
        badge_label = self.__dict__.get("pair_policy_card_repo_source_badge_labels", {}).get(pair_id)
        if badge_label is not None:
            try:
                badge_label.configure(
                    text=badge_spec["text"],
                    bg=badge_spec["background"],
                    fg=badge_spec["foreground"],
                )
            except Exception:
                pass

    def _refresh_pair_policy_override_badges(self) -> None:
        badge_spec = self._run_root_override_badge_spec()
        for pair_id, store in self.pair_policy_card_vars.items():
            store["override_badge_var"].set(badge_spec["text"])
            badge_label = self.__dict__.get("pair_policy_card_override_badge_labels", {}).get(pair_id)
            if badge_label is not None:
                try:
                    badge_label.configure(
                        text=badge_spec["text"],
                        bg=badge_spec["background"],
                        fg=badge_spec["foreground"],
                    )
                except Exception:
                    pass

    def _current_parallel_wrapper_status_payload(self) -> dict | None:
        run_root = str(self._current_run_root_for_actions() or "").strip()
        if not run_root:
            return None
        wrapper_status_path = Path(run_root) / ".state" / "wrapper-status.json"
        if not wrapper_status_path.exists():
            return None
        try:
            payload = json.loads(wrapper_status_path.read_text(encoding="utf-8"))
        except Exception:
            return None
        if not isinstance(payload, dict):
            return None
        return payload

    def _parallel_wrapper_pair_run_row(self, pair_id: str, wrapper_payload: dict | None) -> dict | None:
        normalized_pair = str(pair_id or "").strip()
        if not normalized_pair or not isinstance(wrapper_payload, dict):
            return None
        pair_runs = list(wrapper_payload.get("PairRuns", []) or [])
        for row in pair_runs:
            if str((row or {}).get("PairId", "") or "").strip() == normalized_pair:
                return dict(row or {})
        child_rows = list(wrapper_payload.get("ChildProcesses", []) or [])
        for row in child_rows:
            if str((row or {}).get("PairId", "") or "").strip() == normalized_pair:
                return dict(row or {})
        return None

    @staticmethod
    def _pair_runtime_status_badge_spec(snapshot: dict[str, object]) -> dict[str, str]:
        watcher_state = str(snapshot.get("WatcherState", "") or "").strip().lower()
        watcher_reason = str(snapshot.get("WatcherReason", "") or "").strip().lower()
        phase = str(snapshot.get("CurrentPhase", "") or "").strip().lower()
        next_action = str(snapshot.get("NextAction", "") or "").strip().lower()
        final_result = str(snapshot.get("FinalResult", "") or "").strip().lower()
        error_count = int(snapshot.get("ErrorPresentCount", 0) or 0)
        roundtrip_count = int(snapshot.get("RoundtripCount", 0) or 0)

        waiting_phase_markers = ("paused", "waiting", "resume-required")
        waiting_next_markers = ("resume-required", "handoff-ready", "await")
        running_phase_markers = ("partner-running", "seed-running")
        if final_result == "failed" or error_count > 0 or "manual-review" in next_action or "error" in phase:
            return {"text": "ERROR", "background": "#B91C1C", "foreground": "#FFFFFF"}
        if (
            final_result == "success"
            or phase == "limit-reached"
            or next_action == "limit-reached"
            or watcher_reason == "pair-roundtrip-limit-reached"
        ):
            return {"text": "DONE", "background": "#15803D", "foreground": "#FFFFFF"}
        if any(marker in phase for marker in running_phase_markers):
            return {"text": "RUNNING", "background": "#2563EB", "foreground": "#FFFFFF"}
        if any(marker in phase for marker in waiting_phase_markers):
            return {"text": "WAITING", "background": "#CA8A04", "foreground": "#111827"}
        if any(marker in next_action for marker in waiting_next_markers):
            return {"text": "WAITING", "background": "#CA8A04", "foreground": "#111827"}
        if watcher_state in {"pause_requested", "resume_requested", "stop_requested", "stopping"}:
            return {"text": "WAITING", "background": "#CA8A04", "foreground": "#111827"}
        if watcher_state in {"running", "starting"} or roundtrip_count > 0 or phase:
            return {"text": "RUNNING", "background": "#2563EB", "foreground": "#FFFFFF"}
        if watcher_state == "stopped":
            return {"text": "STOPPED", "background": "#6B7280", "foreground": "#FFFFFF"}
        return {"text": "STATE 미확인", "background": "#6B7280", "foreground": "#FFFFFF"}

    def _build_pair_runtime_snapshot(self, pair_id: str) -> dict[str, object]:
        route_snapshot = self._build_pair_route_snapshot(pair_id)
        wrapper_payload = self._current_parallel_wrapper_status_payload()
        wrapper_row = self._parallel_wrapper_pair_run_row(pair_id, wrapper_payload)
        if wrapper_row is not None:
            run_root = str(wrapper_row.get("RunRoot", "") or "").strip() or str(route_snapshot.get("PairRunRoot", "") or "").strip()
            snapshot = {
                "PairId": pair_id,
                "StatusSource": "wrapper-status",
                "RepoRoot": str(wrapper_row.get("WorkRepoRoot", "") or "").strip() or str(route_snapshot.get("PairWorkRepoRoot", "") or "").strip(),
                "RunRoot": run_root,
                "WatcherState": str(wrapper_row.get("WatcherState", "") or "").strip(),
                "WatcherReason": str(wrapper_row.get("WatcherReason", "") or "").strip(),
                "RoundtripCount": int(wrapper_row.get("RoundtripCount", 0) or 0),
                "CurrentPhase": str(wrapper_row.get("CurrentPhase", "") or "").strip(),
                "NextAction": str(wrapper_row.get("NextAction", "") or "").strip(),
                "LastForwardedAt": str(wrapper_row.get("LastForwardedAt", "") or "").strip(),
                "LastHeartbeatAt": str(wrapper_row.get("LastHeartbeatAt", "") or "").strip(),
                "DonePresentCount": int(wrapper_row.get("DonePresentCount", 0) or 0),
                "ErrorPresentCount": int(wrapper_row.get("ErrorPresentCount", 0) or 0),
                "FinalResult": str(wrapper_row.get("FinalResult", "") or "").strip(),
                "CompletionSource": str(wrapper_row.get("CompletionSource", "") or "").strip(),
            }
            snapshot["Badge"] = self._pair_runtime_status_badge_spec(snapshot)
            return snapshot

        pair_status = self._paired_pair_status_row(pair_id)
        if pair_status is not None:
            watcher = dict(((self.paired_status_data or {}).get("Watcher", {}) or {}))
            snapshot = {
                "PairId": pair_id,
                "StatusSource": "paired-status",
                "RepoRoot": str(route_snapshot.get("PairWorkRepoRoot", "") or "").strip(),
                "RunRoot": str(route_snapshot.get("PairRunRoot", "") or "").strip(),
                "WatcherState": str(watcher.get("Status", "") or "").strip(),
                "WatcherReason": str(watcher.get("StatusReason", "") or watcher.get("Reason", "") or "").strip(),
                "RoundtripCount": int(pair_status.get("RoundtripCount", 0) or 0),
                "CurrentPhase": str(pair_status.get("CurrentPhase", "") or "").strip(),
                "NextAction": str(pair_status.get("NextAction", "") or "").strip(),
                "LastForwardedAt": str(pair_status.get("LastForwardedAt", "") or "").strip(),
                "LastHeartbeatAt": str(watcher.get("HeartbeatAt", "") or "").strip(),
                "DonePresentCount": 0,
                "ErrorPresentCount": 0,
                "FinalResult": "",
                "CompletionSource": "",
            }
            snapshot["Badge"] = self._pair_runtime_status_badge_spec(snapshot)
            return snapshot

        snapshot = {
            "PairId": pair_id,
            "StatusSource": "route-only",
            "RepoRoot": str(route_snapshot.get("PairWorkRepoRoot", "") or "").strip(),
            "RunRoot": str(route_snapshot.get("PairRunRoot", "") or "").strip(),
            "WatcherState": "",
            "WatcherReason": "",
            "RoundtripCount": 0,
            "CurrentPhase": "",
            "NextAction": "",
            "LastForwardedAt": "",
            "LastHeartbeatAt": "",
            "DonePresentCount": 0,
            "ErrorPresentCount": 0,
            "FinalResult": "",
            "CompletionSource": "",
        }
        snapshot["Badge"] = self._pair_runtime_status_badge_spec(snapshot)
        return snapshot

    def _pair_runtime_summary_text(self, snapshot: dict[str, object]) -> str:
        run_root = str(snapshot.get("RunRoot", "") or "").strip()
        run_leaf = os.path.basename(os.path.normpath(run_root)) if run_root else "(없음)"
        heartbeat = str(snapshot.get("LastHeartbeatAt", "") or "").strip() or "(없음)"
        forwarded = str(snapshot.get("LastForwardedAt", "") or "").strip() or "(없음)"
        phase = str(snapshot.get("CurrentPhase", "") or "").strip() or "(없음)"
        watcher_state = str(snapshot.get("WatcherState", "") or "").strip() or "(없음)"
        lines = [
            "source={0} / watcher={1} / rt={2}".format(
                snapshot.get("StatusSource", "") or "unknown",
                watcher_state,
                int(snapshot.get("RoundtripCount", 0) or 0),
            ),
            "phase={0} / next={1}".format(
                phase,
                str(snapshot.get("NextAction", "") or "").strip() or "(없음)",
            ),
            "repo={0}".format(str(snapshot.get("RepoRoot", "") or "").strip() or "(없음)"),
            "run={0} / forwarded={1}".format(run_leaf, forwarded),
            "heartbeat={0}".format(heartbeat),
        ]
        final_result = str(snapshot.get("FinalResult", "") or "").strip()
        if final_result:
            lines.append(
                "final={0} / completion={1}".format(
                    final_result,
                    str(snapshot.get("CompletionSource", "") or "").strip() or "(없음)",
                )
            )
        return "\n".join(lines)

    def _refresh_pair_policy_parallel_status_board(self) -> None:
        counts = {
            "RUNNING": 0,
            "WAITING": 0,
            "DONE": 0,
            "ERROR": 0,
            "STOPPED": 0,
            "STATE 미확인": 0,
        }
        source_labels: set[str] = set()
        for pair_id in PAIR_ID_OPTIONS:
            if pair_id not in self.pair_policy_card_vars:
                continue
            snapshot = self._build_pair_runtime_snapshot(pair_id)
            badge_spec = dict(snapshot.get("Badge") or self._pair_runtime_status_badge_spec(snapshot))
            badge_text = str(badge_spec.get("text", "") or "STATE 미확인")
            source_label = str(snapshot.get("StatusSource", "") or "").strip()
            if source_label:
                source_labels.add(source_label)
            if badge_text in counts:
                counts[badge_text] += 1
            store = self._pair_policy_card_store(pair_id)
            store["runtime_badge_var"].set(badge_text)
            store["runtime_summary_var"].set(self._pair_runtime_summary_text(snapshot))
            badge_label = self.__dict__.get("pair_policy_card_runtime_badge_labels", {}).get(pair_id)
            if badge_label is not None:
                try:
                    badge_label.configure(
                        text=badge_text,
                        bg=badge_spec["background"],
                        fg=badge_spec["foreground"],
                    )
                except Exception:
                    pass

        source_text = ", ".join(sorted(source_labels)) if source_labels else "route-only"
        self.pair_policy_parallel_status_var.set(
            "병렬 실행: pair 간 실행은 병렬, 같은 pair 내부 handoff는 순차 / source={0} / RUNNING={1} WAITING={2} DONE={3} ERROR={4} STOPPED={5}".format(
                source_text,
                counts["RUNNING"],
                counts["WAITING"],
                counts["DONE"],
                counts["ERROR"],
                counts["STOPPED"],
            )
        )

    def _stage_by_key(self, stage_key: str):
        if not self.panel_state:
            return None
        return next((stage for stage in self.panel_state.stages if stage.key == stage_key), None)

    def _stage_action_allowed(
        self,
        stage_key: str,
        *,
        expected_action_key: str = "",
        missing_message: str = "홈 상태를 먼저 새로고침하세요.",
        mismatch_message: str = "",
        not_ready_message: str = "현재 준비 단계가 아직 완료되지 않았습니다.",
    ) -> tuple[bool, str]:
        stage = self._stage_by_key(stage_key)
        if stage is None:
            return False, missing_message
        if expected_action_key and stage.action_key != expected_action_key:
            return False, stage.detail or mismatch_message or not_ready_message
        if not stage.enabled:
            return False, stage.detail or not_ready_message
        return True, ""

    def _selected_pair_execution_allowed(self) -> tuple[bool, str]:
        return self._stage_action_allowed(
            "pair_action",
            expected_action_key="run_selected_pair",
            mismatch_message="선택 Pair Headless Drill 전 pair 활성화가 필요합니다.",
        )

    def _selected_parallel_pair_execution_allowed(self, pair_ids: list[str] | None = None) -> tuple[bool, str]:
        allowed, detail = self._stage_action_allowed(
            "pair_action",
            expected_action_key="run_selected_pair",
            mismatch_message="선택 pair 병렬 Headless Drill 전 pair 활성화가 필요합니다.",
        )
        if not allowed:
            return allowed, detail
        target_pair_ids = list(pair_ids or self._selected_parallel_pair_ids())
        if len(target_pair_ids) < 2:
            return False, "병렬 실테스트를 실행하려면 최소 2개 pair를 체크하세요."
        for pair_id in target_pair_ids:
            scope_allowed, scope_detail = self._pair_scope_allowed(pair_id, action_label="선택 pair 병렬 Headless Drill")
            if not scope_allowed:
                return False, scope_detail
        return True, ""

    def _runtime_active_pair_ids(self) -> list[str]:
        runtime = ((self.relay_status_data or {}).get("Runtime", {}) or {})
        raw_value = runtime.get("ActivePairIds", [])
        if isinstance(raw_value, list):
            return [str(item) for item in raw_value if str(item)]
        single = str(raw_value or "").strip()
        return [single] if single else []

    def _pair_scope_allowed(self, pair_id: str, *, action_label: str) -> tuple[bool, str]:
        normalized_pair_id = str(pair_id or "").strip()
        if not normalized_pair_id:
            return False, "PairId 값을 먼저 선택하세요."

        runtime = ((self.relay_status_data or {}).get("Runtime", {}) or {})
        if not bool(runtime.get("PartialReuse", False)):
            return True, ""

        active_pairs = self._runtime_active_pair_ids()
        if not active_pairs:
            return False, f"{action_label} 차단: 현재 partial reuse session의 active pair를 확인하지 못했습니다."
        if normalized_pair_id in active_pairs:
            return True, ""
        return False, "{0} 차단: {1}는 현재 session partial reuse 범위 밖입니다. active={2}".format(
            action_label,
            normalized_pair_id,
            ", ".join(active_pairs),
        )

    def _selected_pair_scope_allowed(self, *, action_label: str) -> tuple[bool, str]:
        return self._pair_scope_allowed(self._selected_pair_id(), action_label=action_label)

    def _apply_active_pair_selection(self, active_pairs: list[str]) -> bool:
        normalized_pairs = [str(item) for item in active_pairs if str(item)]
        if not normalized_pairs:
            return False

        current_pair = self._selected_pair_id()
        if current_pair in normalized_pairs:
            return False

        next_pair = normalized_pairs[0]
        top_target_id = ""
        if "pair_controller" in self.__dict__ and "preview_rows" in self.__dict__:
            top_target_id = self._resolve_top_target_for_pair(next_pair)
        self._set_action_context(
            pair_id=next_pair,
            target_id=top_target_id if top_target_id else self.target_id_var.get().strip(),
            source="runtime-active-pair",
        )
        if "home_pair_tree" in self.__dict__:
            self._sync_home_pair_selection(next_pair)
        if ("_sync_preview_selection_with_pair" in self.__dict__ or "row_tree" in self.__dict__) and self._selected_preview_row() is None:
            self._sync_preview_selection_with_pair(next_pair, target_id=top_target_id)
        return True

    def _coerce_selected_pair_into_runtime_scope(self) -> bool:
        runtime = ((self.relay_status_data or {}).get("Runtime", {}) or {})
        if not bool(runtime.get("PartialReuse", False)):
            return False
        return self._apply_active_pair_selection(self._runtime_active_pair_ids())

    def _attach_action_allowed(self) -> tuple[bool, str]:
        return self._stage_action_allowed(
            "attach_windows",
            expected_action_key="attach_windows",
            mismatch_message="현재 세션 기준 바인딩 attach를 다시 확인하세요.",
            not_ready_message="현재 세션 기준 창 준비 후 붙이기를 다시 시도하세요.",
        )

    def _visibility_action_allowed(self) -> tuple[bool, str]:
        return self._stage_action_allowed(
            "check_visibility",
            expected_action_key="check_visibility",
            mismatch_message="현재 세션 기준 입력 가능 상태를 다시 확인하세요.",
            not_ready_message="현재 세션 기준 attach 완료 후 입력 점검을 다시 시도하세요.",
        )

    def _board_status_text(
        self,
        *,
        items: list[dict[str, str]],
        selected_target: str,
        selected_pair: str,
        action_pair: str = "",
        action_target: str = "",
        inspection_source: str = "",
    ) -> str:
        attached_count = sum(1 for item in items if item["RuntimePresent"] == "예")
        injectable_count = sum(1 for item in items if item["Injectable"] == "예")
        selected_pair_count = sum(1 for item in items if selected_pair and item["PairId"] == selected_pair)
        text = "8창 보드: attached {0}/{1} / injectable {2}/{1} / pair {3}({4}) / 현재 선택 {5} / 회색=미연결, 노랑=입력 불가, 초록=정상".format(
            attached_count,
            len(items),
            injectable_count,
            selected_pair or "(없음)",
            selected_pair_count,
            selected_target or "(없음)",
        )
        if action_pair or action_target:
            text += " / 실행 기준 {0}/{1}".format(
                action_pair or "(pair 없음)",
                action_target or "(target 없음)",
            )
        if inspection_source:
            text += " / inspection source {0}".format(self._context_source_label(inspection_source))
        runtime = (self.relay_status_data or {}).get("Runtime", {}) if self.relay_status_data else {}
        if runtime.get("PartialReuse", False):
            active_pairs = [str(item) for item in (runtime.get("ActivePairIds", []) or []) if str(item)]
            expected_targets = int(runtime.get("ExpectedTargetCount", 0) or 0)
            configured_targets = int(runtime.get("ConfiguredTargetCount", 0) or len(items) or 8)
            text += " / partial scope {0}/{1} active={2}".format(
                expected_targets,
                configured_targets,
                ", ".join(active_pairs) if active_pairs else "(none)",
            )
        attach_allowed, attach_detail = self._attach_action_allowed()
        if not attach_allowed and attach_detail:
            text += " / " + attach_detail
        return text

    def _watch_start_allowed(self) -> tuple[bool, str]:
        pair_allowed, pair_detail = self._selected_pair_execution_allowed()
        if not pair_allowed:
            detail = pair_detail or "현재 세션 준비 단계가 아직 완료되지 않았습니다."
            if self._current_run_root_is_stale_for_actions():
                detail += "\n\n현재 action RunRoot가 stale입니다. 'RunRoot 준비'를 다시 실행하거나 explicit RunRoot 입력을 비우세요."
            return False, detail
        start_eligibility = self._watcher_start_eligibility()
        if start_eligibility.allowed or start_eligibility.cleanup_allowed:
            return True, ""
        return False, start_eligibility.message or "watch 시작 조건을 아직 만족하지 않습니다."

    def refresh_runtime_status_only(self) -> None:
        if not self.effective_data:
            self.load_effective_config()
            return
        runtime_result = self.refresh_controller.refresh_runtime(self._effective_refresh_context())
        self._apply_runtime_refresh_result(runtime_result)

    def _apply_runtime_refresh_result(self, runtime_result) -> None:
        self.relay_status_data = runtime_result.relay_status
        self.visibility_status_data = runtime_result.visibility_status
        self._coerce_selected_pair_into_runtime_scope()
        self.rebuild_panel_state()
        self.render_target_board()
        self.update_pair_button_states()

    def _runtime_refresh_command_preview(self, context: AppContext | None = None) -> str:
        context = context or self._effective_refresh_context()
        relay_command = self.command_service.build_script_command(
            script_name="show-relay-status.ps1",
            config_path=context.config_path,
            run_root=context.run_root,
            pair_id=context.pair_id,
            target_id=context.target_id,
            extra=["-AsJson"],
        )
        visibility_command = self.command_service.build_script_command(
            script_name="check-target-window-visibility.ps1",
            config_path=context.config_path,
            run_root=context.run_root,
            pair_id=context.pair_id,
            target_id=context.target_id,
            extra=["-AsJson"],
        )
        return "runtime-refresh bundle: {0} ; {1}".format(
            subprocess.list2cmdline(relay_command),
            subprocess.list2cmdline(visibility_command),
        )

    def _reuse_windows_command_preview(self, *, pairs_mode: bool = False) -> str:
        context = self._current_context()
        refresh_extra = ["-AsJson"]
        if pairs_mode:
            refresh_extra += ["-ReuseMode", "Pairs"]
        refresh_command = self.command_service.build_script_command(
            script_name="refresh-binding-profile-from-existing.ps1",
            config_path=context.config_path,
            extra=refresh_extra,
        )
        attach_command = self.command_service.build_script_command(
            script_name="attach-targets-from-bindings.ps1",
            config_path=context.config_path,
        )
        relay_command = self.command_service.build_script_command(
            script_name="show-relay-status.ps1",
            config_path=context.config_path,
            run_root=context.run_root,
            pair_id=context.pair_id,
            target_id=context.target_id,
            extra=["-AsJson"],
        )
        visibility_command = self.command_service.build_script_command(
            script_name="check-target-window-visibility.ps1",
            config_path=context.config_path,
            run_root=context.run_root,
            pair_id=context.pair_id,
            target_id=context.target_id,
            extra=["-AsJson"],
        )
        command_label = "reuse-active-pairs bundle" if pairs_mode else "reuse-existing bundle"
        return "{0}: {1} ; {2} ; {3} ; {4}".format(
            command_label,
            subprocess.list2cmdline(refresh_command),
            subprocess.list2cmdline(attach_command),
            subprocess.list2cmdline(relay_command),
            subprocess.list2cmdline(visibility_command),
        )

    def _reuse_existing_windows_command_preview(self) -> str:
        return self._reuse_windows_command_preview(pairs_mode=False)

    def _reuse_active_pairs_command_preview(self) -> str:
        return self._reuse_windows_command_preview(pairs_mode=True)

    def _format_reuse_existing_windows_report(
        self,
        payload: dict,
        *,
        attach_output: str,
        runtime_result=None,
        operation_label: str = "기존 8창 재사용 결과",
    ) -> str:
        expected_targets = int(payload.get("ExpectedTargetCount", 0) or len(payload.get("Targets", []) or []) or 8)
        configured_targets = int(payload.get("ConfiguredTargetCount", 0) or expected_targets)
        reused_targets = int(payload.get("ReusedTargetCount", 0) or 0)
        reused_pairs = int(payload.get("ReusedPairCount", 0) or 0)
        partial_reuse = bool(payload.get("PartialReuse", False))
        active_pairs = [str(item) for item in (payload.get("ActivePairIds", []) or []) if str(item)]
        active_target_ids = {str(item) for item in (payload.get("ActiveTargetIds", []) or []) if str(item)}
        inactive_targets = [str(item) for item in (payload.get("InactiveTargetIds", []) or []) if str(item)]
        orphan_targets = [str(item) for item in (payload.get("OrphanMatchedTargetIds", []) or []) if str(item)]
        target_tokens: list[str] = []
        for row in payload.get("Targets", []) or []:
            target_id = str(row.get("TargetId", "") or "")
            if not target_id:
                continue
            counted_as_reused = bool(
                row.get(
                    "CountedAsReused",
                    target_id in active_target_ids if partial_reuse else row.get("Matched", False),
                )
            )
            if not counted_as_reused:
                continue
            method = str(row.get("MatchMethod", "") or "")
            target_tokens.append("{0}({1})".format(target_id, method or "matched"))

        lines = [
            operation_label,
            str(payload.get("Summary", "") or "기존 8창 재사용 준비 완료"),
            "현재 세션 승격: 완료",
            "binding 현재시각 갱신 완료",
        ]
        if partial_reuse:
            lines.append("ReusedPairs: {0}".format(reused_pairs))
            lines.append("ReusedTargets: {0}/{1} (cfg {2})".format(reused_targets, expected_targets, configured_targets))
            if active_pairs:
                lines.append("ActivePairs: {0}".format(", ".join(active_pairs)))
            if inactive_targets:
                lines.append("InactiveTargets: {0}".format(", ".join(inactive_targets)))
            if orphan_targets:
                lines.append("OrphanTargets: {0}".format(", ".join(orphan_targets)))
        else:
            lines.append("ReusedTargets: {0}/{1}".format(reused_targets, expected_targets))
        bindings_path = str(payload.get("BindingsPath", "") or "")
        if bindings_path:
            lines.append("BindingProfile: {0}".format(bindings_path))
        refreshed_at = str(payload.get("RefreshedAt", "") or "")
        if refreshed_at:
            lines.append("BindingRefreshedAt: {0}".format(refreshed_at))
        if target_tokens:
            lines.append("Targets: {0}".format(", ".join(target_tokens)))
        if attach_output:
            lines.extend(["", "[붙이기]", "attach 재실행 완료", attach_output])
        if runtime_result is not None:
            lines.extend(
                [
                    "",
                    "[입력 점검]",
                    self._format_visibility_status_report(
                        runtime_result.visibility_status,
                        relay_payload=runtime_result.relay_status,
                        include_json=False,
                    ),
                ]
            )
        return "\n".join(lines)

    def _reuse_failure_summary(self, payload: dict) -> str:
        return build_reuse_failure_summary(payload)

    def _apply_reuse_active_pair_selection(self, payload: dict) -> None:
        active_pairs = [str(item) for item in (payload.get("ActivePairIds", []) or []) if str(item)]
        self._apply_active_pair_selection(active_pairs)

    def _format_visibility_status_report(
        self,
        payload: dict,
        *,
        relay_payload: dict | None = None,
        include_json: bool = True,
    ) -> str:
        relay_status = relay_payload or self.relay_status_data or {}
        expected_targets = int(
            payload.get("ExpectedTargetCount")
            or relay_status.get("Runtime", {}).get("ExpectedTargetCount")
            or len(payload.get("Targets", []) or [])
            or 8
        )
        injectable = int(payload.get("InjectableCount", 0) or 0)
        non_injectable = int(payload.get("NonInjectableCount", 0) or 0)
        missing_runtime = int(payload.get("MissingRuntimeCount", 0) or 0)
        runtime_last_write = str(payload.get("RuntimeLastWriteAt", "") or "")
        binding_last_write = str(payload.get("BindingProfileLastWriteAt", "") or "")
        runtime_stale_against_binding = bool(payload.get("RuntimeStaleAgainstBinding", False))
        title_fallback_rejected = int(payload.get("TitleFallbackRejectedCount", 0) or 0)
        failed_targets = [
            "{0}({1})".format(
                str(row.get("TargetId", "") or "?"),
                str(row.get("InjectionReason", "") or "unknown"),
            )
            for row in payload.get("Targets", [])
            if not row.get("Injectable", False)
        ]

        lines = [
            "입력 가능 확인 결과",
            f"Injectable: {injectable}/{expected_targets}",
            f"NonInjectable: {non_injectable}",
            f"MissingRuntime: {missing_runtime}",
        ]
        if binding_last_write or runtime_last_write:
            lines.append(
                "Timestamps: binding={0} runtime={1}".format(
                    binding_last_write or "-",
                    runtime_last_write or "-",
                )
            )
        if runtime_stale_against_binding:
            lines.append("차단: binding보다 오래된 runtime map입니다. 먼저 [붙이기]를 실행하세요.")
        if title_fallback_rejected > 0:
            lines.append("차단: 같은 제목 창이 여러 개라 title fallback은 허용되지 않습니다. hwnd attach가 필요합니다.")
        duplicate_ids = list(payload.get("DuplicateTargetIds", []) or [])
        if duplicate_ids:
            lines.append("DuplicateTargetIds: " + ", ".join(str(item) for item in duplicate_ids))
        runtime_parse_error = str(payload.get("RuntimeParseError", "") or "")
        if runtime_parse_error:
            lines.append("RuntimeParseError: " + runtime_parse_error)
        if failed_targets:
            lines.extend(["", "실패 target:", ", ".join(failed_targets)])

        if include_json:
            lines.extend(["", "JSON", json.dumps(payload, ensure_ascii=False, indent=2)])

        return "\n".join(lines)

    def _visibility_last_result_text(self, payload: dict, *, relay_payload: dict | None = None) -> str:
        relay_status = relay_payload or self.relay_status_data or {}
        expected_targets = int(
            payload.get("ExpectedTargetCount")
            or relay_status.get("Runtime", {}).get("ExpectedTargetCount")
            or len(payload.get("Targets", []) or [])
            or 8
        )
        return "마지막 결과: 입력 가능 {0}/{1} / fail={2} missing={3}".format(
            int(payload.get("InjectableCount", 0) or 0),
            expected_targets,
            int(payload.get("NonInjectableCount", 0) or 0),
            int(payload.get("MissingRuntimeCount", 0) or 0),
        )

    def refresh_paired_status_only(self, *, refresh_artifacts: bool = True) -> None:
        run_root = self._current_run_root_for_actions()
        if not run_root:
            self._apply_paired_status_snapshot(None, "", refresh_artifacts=refresh_artifacts)
            return

        paired_result = self.refresh_controller.refresh_paired(self._current_context(), run_root=run_root)
        self._apply_paired_status_snapshot(
            paired_result.paired_status,
            paired_result.paired_status_error,
            refresh_artifacts=refresh_artifacts,
        )

    def _apply_paired_status_snapshot(
        self,
        paired_payload: dict | None,
        paired_error: str,
        *,
        refresh_artifacts: bool = True,
    ) -> None:
        self.paired_status_data = paired_payload
        self.paired_status_error = paired_error
        self.rebuild_panel_state()
        self.render_target_board()
        if refresh_artifacts:
            self.refresh_artifacts_tab()
        self._refresh_watcher_notes()
        self.update_pair_button_states()

    def _apply_paired_status_snapshot_from_payload(
        self,
        payload: dict | None,
        *,
        refresh_artifacts: bool = True,
    ) -> bool:
        if not isinstance(payload, dict):
            return False
        paired_payload = payload.get("PairedStatusSnapshot", None)
        if not isinstance(paired_payload, dict):
            return False
        self._apply_paired_status_snapshot(
            paired_payload,
            "",
            refresh_artifacts=refresh_artifacts,
        )
        return True

    def refresh_quick_status(self) -> None:
        try:
            quick_result = self.refresh_controller.refresh_quick(self._current_context())
            self.relay_status_data = quick_result.runtime.relay_status
            self.visibility_status_data = quick_result.runtime.visibility_status
            self.paired_status_data = quick_result.paired.paired_status
            self.paired_status_error = quick_result.paired.paired_status_error
            self.rebuild_panel_state()
            self.render_target_board()
            self._refresh_watcher_notes()
            self.update_pair_button_states()
        except Exception as exc:
            messagebox.showerror("빠른 새로고침 실패", str(exc))
            self.set_operator_status("빠른 새로고침 실패", "부분 상태 갱신에 실패했습니다.", f"마지막 결과: 실패 ({exc})")
            return

        result_text = "마지막 결과: 빠른 새로고침 완료"
        if self.paired_status_error:
            result_text += " / pair-status 일부 생략"
        detail = "relay/visibility/paired 상태만 다시 읽었습니다. 결과 탭 산출물은 건드리지 않았습니다."
        self.set_query_text("\n".join(["빠른 새로고침 완료", detail, result_text]))
        self.set_query_result(
            result_text.replace("마지막 결과", "마지막 조회"),
            context=self._query_context_summary(),
        )
        if self._busy:
            return
        self.set_operator_status("빠른 새로고침 완료", detail, result_text)

    def refresh_artifacts_status(self) -> None:
        try:
            self.refresh_paired_status_only()
        except Exception as exc:
            messagebox.showerror("결과 새로고침 실패", str(exc))
            self.set_operator_status("결과 새로고침 실패", "paired status와 산출물 갱신에 실패했습니다.", f"마지막 결과: 실패 ({exc})")
            return

        result_text = "마지막 결과: 결과 / 산출물 새로고침 완료"
        if self.paired_status_error:
            result_text += " / pair-status 일부 생략"
        detail = "현재 RunRoot 기준 paired status와 산출물을 다시 읽었습니다."
        self.set_query_text("\n".join(["결과 / 산출물 새로고침 완료", detail, result_text]))
        self.set_query_result(
            result_text.replace("마지막 결과", "마지막 조회"),
            context=self._artifact_query_context_summary(),
        )
        if self._busy:
            return
        self.set_operator_status("결과 새로고침 완료", detail, result_text)

    def toggle_simple_mode(self) -> None:
        if self.notebook is None:
            return
        if self.simple_mode_var.get():
            if self._has_ui_attr("ops_tab"):
                self.notebook.hide(self.ops_tab)
            if self._has_ui_attr("snapshots_tab"):
                self.notebook.hide(self.snapshots_tab)
            if self._has_ui_attr("result_panel_collapsed_var"):
                self.result_panel_has_unseen_update = False
                self.result_panel_collapsed_var.set(True)
                self._apply_result_panel_visibility()
            self.set_operator_status("간단 모드", "홈, 8창 보드, 설정 편집, 산출물 중심으로 단순화했습니다. 결과 패널은 기본 축약 상태지만 새 결과가 들어오면 자동으로 다시 펼칩니다.")
        else:
            if self._has_ui_attr("ops_tab"):
                self.notebook.add(self.ops_tab, text="Headless Drill / 진단")
            if self._has_ui_attr("snapshots_tab"):
                self.notebook.add(self.snapshots_tab, text="스냅샷")
            self.set_operator_status("전체 모드", "고급 진단 탭까지 다시 표시했습니다. 하단 결과 패널은 필요할 때 직접 펼칠 수 있습니다.")
        self._refresh_sticky_context_bar()

    def load_message_editor_document(self) -> None:
        config_path = self.config_path_var.get().strip()
        if not config_path:
            self.message_editor_status_var.set("ConfigPath가 없어 설정 편집기를 불러오지 못했습니다.")
            return
        try:
            document = self.message_config_service.load_config_document(config_path)
        except Exception as exc:
            self.message_editor_status_var.set(f"설정 편집기 로드 실패: {exc}")
            return
        self.message_config_doc = document
        self.message_config_original = self.message_config_service.clone_document(document)
        target_ids = self.message_config_service.target_ids(document)
        if not self.message_target_suffix_var.get().strip() and target_ids:
            self.message_target_suffix_var.set(target_ids[0])
        self.message_selected_slot_key = self._message_slot_key_for_scope()
        self._reset_message_preview_cache(
            "설정을 다시 불러왔습니다. 필요하면 '미리보기 갱신'으로 현재 문맥 기준 preview/source plan을 다시 계산할 수 있습니다.",
            dirty=False,
        )
        self.render_message_editor()
        self.refresh_pair_policy_editor()

    def _pair_policy_known_pair_ids(
        self,
        *,
        document: dict | None = None,
        effective_payload: dict | None = None,
    ) -> list[str]:
        pair_ids: list[str] = []
        if document:
            pair_ids.extend(
                [
                    str(item.get("PairId", "") or "").strip()
                    for item in self.message_config_service.pair_definitions(document)
                    if str(item.get("PairId", "") or "").strip()
                ]
            )
        for item in (effective_payload or self.effective_data or {}).get("OverviewPairs", []) or []:
            pair_id = str(item.get("PairId", "") or "").strip()
            if pair_id:
                pair_ids.append(pair_id)
        ordered: list[str] = []
        seen: set[str] = set()
        for pair_id in pair_ids + list(PAIR_ID_OPTIONS):
            if not pair_id or pair_id in seen:
                continue
            seen.add(pair_id)
            ordered.append(pair_id)
        return ordered

    def _pair_policy_card_store(self, pair_id: str) -> dict[str, object]:
        store = self.pair_policy_card_vars.get(str(pair_id or "").strip())
        if store is None:
            raise KeyError(f"Unknown pair policy card: {pair_id}")
        return store

    def _sync_pair_policy_effective_preview_widget(self, pair_id: str) -> None:
        store = self.pair_policy_card_vars.get(str(pair_id or "").strip())
        if store is None:
            return
        widget = getattr(self, "pair_policy_card_effective_preview_widgets", {}).get(str(pair_id or "").strip())
        if widget is None:
            return
        try:
            self.set_text(widget, str(store["effective_preview_var"].get() or ""))
        except Exception:
            pass

    def _pair_policy_action_pair_ids(self, document: dict | None = None) -> list[str]:
        effective_document = document if isinstance(document, dict) else None
        if effective_document is None:
            cached_document = getattr(self, "message_config_doc", None)
            effective_document = cached_document if isinstance(cached_document, dict) else None
        if effective_document is None:
            return []
        pair_ids = [
            str(item.get("PairId", "") or "").strip()
            for item in self.message_config_service.pair_definitions(effective_document)
            if str(item.get("PairId", "") or "").strip()
        ]
        return list(dict.fromkeys(pair_ids))

    def _pair_policy_configured_pair_ids(self, document: dict) -> list[str]:
        pair_ids = [
            str(item.get("PairId", "") or "").strip()
            for item in self.message_config_service.pair_definitions(document)
            if str(item.get("PairId", "") or "").strip()
        ]
        if pair_ids:
            return list(dict.fromkeys(pair_ids))
        return self._pair_policy_known_pair_ids(document=document)

    def _configure_optional_widget(self, widget: object | None, **kwargs: object) -> None:
        if widget is None:
            return
        try:
            widget.configure(**kwargs)
        except Exception:
            pass

    def _set_pair_policy_card_action_enabled(self, pair_id: str, *, enabled: bool) -> None:
        state = "normal" if enabled else "disabled"
        if not enabled:
            store = self.pair_policy_card_vars.get(pair_id)
            if store is not None:
                try:
                    store["parallel_selected_var"].set(False)
                except Exception:
                    pass
        for attr_name in [
            "pair_policy_card_parallel_checkbuttons",
            "pair_policy_card_summary_buttons",
            "pair_policy_card_preview_buttons",
            "pair_policy_card_copy_buttons",
        ]:
            widget = getattr(self, attr_name, {}).get(pair_id)
            self._configure_optional_widget(widget, state=state)

    def _pair_policy_route_rows(self) -> list[dict[str, object]]:
        route_rows = list(self.__dict__.get("pair_policy_effective_preview_rows", []) or [])
        if route_rows:
            return route_rows
        return list(self.preview_rows or [])

    def _pair_policy_preview_run_root_hint(self, *, pair_id: str, policy: dict[str, object]) -> dict[str, str]:
        expected_run_root_base = self._pair_policy_preview_run_root_base(
            pair_id=pair_id,
            policy=policy,
        )
        if not expected_run_root_base:
            return {}

        explicit_run_root = str(self.run_root_var.get() or "").strip()
        if explicit_run_root:
            if self._path_is_direct_child_within_root(explicit_run_root, expected_run_root_base):
                return {
                    "RunRootPreviewReason": "runroot-override-under-pair-base",
                    "ExpectedRunRootBase": expected_run_root_base,
                }
            return {
                "RunRootPreviewReason": "runroot-override-outside-pair-base",
                "ExpectedRunRootBase": expected_run_root_base,
            }

        selected_run_root = str((self.effective_data or {}).get("RunContext", {}).get("SelectedRunRoot", "") or "").strip()
        if selected_run_root:
            if self._path_is_direct_child_within_root(selected_run_root, expected_run_root_base):
                return {
                    "RunRootPreviewReason": "selected-runroot-under-pair-base",
                    "ExpectedRunRootBase": expected_run_root_base,
                }
            return {
                "RunRootPreviewReason": "selected-runroot-outside-pair-base",
                "ExpectedRunRootBase": expected_run_root_base,
            }

        return {
            "RunRootPreviewReason": "pair-runroot-not-materialized",
            "ExpectedRunRootBase": expected_run_root_base,
        }

    def _pair_policy_editor_all_repo_hints(self) -> dict[str, str]:
        result: dict[str, str] = {}
        pair_ids = self._pair_policy_action_pair_ids()
        for pair_id in pair_ids:
            store = self.pair_policy_card_vars.get(pair_id)
            if not store:
                continue
            result[pair_id] = str(store["repo_root_var"].get() or "").strip()
        return result

    def _pair_policy_card_policy_from_store(self, pair_id: str) -> dict[str, object]:
        store = self._pair_policy_card_store(pair_id)
        return {
            "PairId": pair_id,
            "DefaultSeedWorkRepoRoot": str(store["repo_root_var"].get() or "").strip(),
            "DefaultSeedTargetId": str(store["seed_target_var"].get() or "").strip(),
            "UseExternalWorkRepoRunRoot": bool(store["external_run_root_var"].get()),
            "UseExternalWorkRepoContractPaths": bool(store["external_contract_var"].get()),
        }

    def _pair_policy_build_preview_text(
        self,
        *,
        pair_id: str,
        policy: dict[str, object],
        route_snapshot: dict[str, object],
        warnings: list[str] | None = None,
    ) -> str:
        pair_run_root = str(route_snapshot.get("PairRunRoot", "") or "").strip()
        run_root_preview_hint = {}
        if not pair_run_root:
            run_root_preview_hint = self._pair_policy_preview_run_root_hint(
                pair_id=pair_id,
                policy=policy,
            )
        run_root_preview_reason = str(
            route_snapshot.get("RunRootPreviewReason", "")
            or run_root_preview_hint.get("RunRootPreviewReason", "")
            or ""
        ).strip()
        expected_run_root_base = str(
            route_snapshot.get("ExpectedRunRootBase", "")
            or run_root_preview_hint.get("ExpectedRunRootBase", "")
            or ""
        ).strip()
        run_root_display = pair_run_root or (
            "(새 runroot 준비 전)"
            if run_root_preview_reason == "pair-runroot-not-materialized"
            else "(미리보기 없음)"
        )
        lines = [
            "pair={0} / seed={1} / repo={2} / repo-source={3}".format(
                pair_id,
                policy.get("DefaultSeedTargetId", "") or "(없음)",
                policy.get("DefaultSeedWorkRepoRoot", "") or "(없음)",
                policy.get("DefaultSeedWorkRepoRootSource", "") or "unset",
            ),
            f"runroot-input={self._run_root_override_state()}",
            f"runroot={run_root_display}",
            f"route={route_snapshot.get('RouteState', '') or '(미확인)'} / same-repo={route_snapshot.get('TargetsShareWorkRepoRoot', False)} / outbox-distinct={route_snapshot.get('TargetOutboxesDistinct', False)} / shared-with-other-pairs={route_snapshot.get('SharesWorkRepoRootWithOtherPairs', False)}",
            f"top outbox={route_snapshot.get('TopSourceOutboxPath', '') or '(없음)'}",
            f"bottom outbox={route_snapshot.get('BottomSourceOutboxPath', '') or '(없음)'}",
            f"top publish={route_snapshot.get('TopPublishReadyPath', '') or '(없음)'}",
            f"bottom publish={route_snapshot.get('BottomPublishReadyPath', '') or '(없음)'}",
        ]
        if run_root_preview_reason:
            lines.append(f"runroot-preview-reason={run_root_preview_reason}")
        if expected_run_root_base:
            lines.append(f"expected-runroot-base={expected_run_root_base}")
        route_warning_items = [str(item).strip() for item in list(route_snapshot.get("Warnings", []) or []) if str(item).strip()]
        warning_items = [str(item).strip() for item in (warnings or []) if str(item).strip()]
        warning_items.extend(route_warning_items)
        if warning_items:
            lines.append("warnings=" + "; ".join(warning_items[:3]))
        return "\n".join(lines)

    def _pair_policy_route_label(self, *, route_snapshot: dict[str, object], pair_work_repo_root: str) -> str:
        route_state = str(route_snapshot.get("RouteState", "") or "saved-config-only")
        pair_run_root = str(route_snapshot.get("PairRunRoot", "") or "")
        repo_share_note = " / 다른 pair와 repo 공유" if bool(route_snapshot.get("SharesWorkRepoRootWithOtherPairs", False)) else ""
        return "route={0}{1} / repo={2} / runroot={3}".format(
            route_state,
            repo_share_note,
            pair_work_repo_root or "(없음)",
            pair_run_root or "(미리보기 없음)",
        )

    def _pair_policy_route_badge_spec(self, *, route_snapshot: dict[str, object], pair_work_repo_root: str) -> dict[str, str]:
        route_state = str(route_snapshot.get("RouteState", "") or "").strip()
        has_repo_root = bool(str(pair_work_repo_root or "").strip())
        shares_repo = bool(route_snapshot.get("SharesWorkRepoRootWithOtherPairs", False))
        if route_state in {"", "saved-config-only"}:
            return {"text": "ROUTE 미확인", "background": "#6B7280", "foreground": "#FFFFFF"}
        if route_state == "preview-missing":
            return {"text": "ROUTE 미리보기 없음", "background": "#6B7280", "foreground": "#FFFFFF"}
        if route_state == "(미구성)" or not has_repo_root:
            return {"text": "ROUTE 미구성", "background": "#6B7280", "foreground": "#FFFFFF"}
        if route_state == "aligned":
            if shares_repo:
                return {"text": "SHARED REPO OK", "background": "#CA8A04", "foreground": "#111827"}
            return {"text": "ROUTE OK", "background": "#15803D", "foreground": "#FFFFFF"}
        return {"text": "ROUTE CHECK", "background": "#B91C1C", "foreground": "#FFFFFF"}

    def _apply_pair_policy_route_feedback(
        self,
        *,
        pair_id: str,
        route_snapshot: dict[str, object],
        pair_work_repo_root: str,
    ) -> None:
        store = self._pair_policy_card_store(pair_id)
        store["route_state_var"].set(
            self._pair_policy_route_label(
                route_snapshot=route_snapshot,
                pair_work_repo_root=pair_work_repo_root,
            )
        )
        badge_spec = self._pair_policy_route_badge_spec(
            route_snapshot=route_snapshot,
            pair_work_repo_root=pair_work_repo_root,
        )
        store["route_badge_var"].set(badge_spec["text"])
        badge_label = self.__dict__.get("pair_policy_card_badge_labels", {}).get(pair_id)
        if badge_label is not None:
            try:
                badge_label.configure(
                    text=badge_spec["text"],
                    bg=badge_spec["background"],
                    fg=badge_spec["foreground"],
                )
            except Exception:
                pass

    def _pair_policy_card_preview_route_snapshot(
        self,
        *,
        rows: list[dict],
        pair_id: str,
        pair_work_repo_root: str,
        policy: dict[str, object] | None = None,
    ) -> dict[str, object]:
        normalized_other_repo_hints = self._pair_policy_editor_all_repo_hints()
        normalized_other_repo_hints[pair_id] = pair_work_repo_root
        normalized_pair_repo = self._normalized_optional_path(pair_work_repo_root)
        shares_repo_with_other_pairs = False
        if normalized_pair_repo:
            for other_pair_id, other_repo in normalized_other_repo_hints.items():
                if other_pair_id == pair_id:
                    continue
                if self._normalized_optional_path(other_repo) == normalized_pair_repo:
                    shares_repo_with_other_pairs = True
                    break
        pair_rows = [row for row in rows if str(row.get("PairId", "") or "").strip() == str(pair_id or "").strip()]
        if not pair_rows:
            return {
                "PairId": pair_id,
                "PairWorkRepoRoot": pair_work_repo_root,
                "PairRunRoot": "",
                "TopSourceOutboxPath": "",
                "BottomSourceOutboxPath": "",
                "TopPublishReadyPath": "",
                "BottomPublishReadyPath": "",
                "TargetsShareWorkRepoRoot": True,
                "TargetsSharePairRunRoot": False,
                "TargetOutboxesDistinct": False,
                "SharesWorkRepoRootWithOtherPairs": shares_repo_with_other_pairs,
                "RouteState": "preview-missing",
                **(
                    self._pair_policy_preview_run_root_hint(pair_id=pair_id, policy=policy or {})
                    if policy
                    else {}
                ),
            }
        top_row = next((row for row in pair_rows if str(row.get("RoleName", "") or "").strip() == "top"), pair_rows[0])
        bottom_row = next((row for row in pair_rows if str(row.get("RoleName", "") or "").strip() == "bottom"), next((row for row in pair_rows if row is not top_row), {}))
        pair_run_root_values: list[str] = []
        for row in pair_rows:
            pair_run_root = str(row.get("PairRunRoot", "") or "").strip()
            if not pair_run_root:
                target_folder = str(row.get("PairTargetFolder", "") or "").strip()
                if target_folder:
                    pair_run_root = os.path.dirname(target_folder)
            if pair_run_root:
                pair_run_root_values.append(pair_run_root)
        unique_pair_run_roots = list(dict.fromkeys(pair_run_root_values))
        outbox_analysis = [self._resolved_source_outbox_path_analysis_from_row(row) for row in pair_rows]
        source_outboxes = [path_value for path_value, _warning in outbox_analysis if path_value]
        top_output_paths = self._resolved_output_paths_from_row(top_row)
        bottom_output_paths = self._resolved_output_paths_from_row(bottom_row)
        top_outbox_path, top_outbox_warning = self._resolved_source_outbox_path_analysis_from_row(top_row)
        bottom_outbox_path, bottom_outbox_warning = self._resolved_source_outbox_path_analysis_from_row(bottom_row)
        route_warnings = []
        if top_outbox_warning:
            route_warnings.append(f"top:{top_outbox_warning}")
        if bottom_outbox_warning:
            route_warnings.append(f"bottom:{bottom_outbox_warning}")
        run_root_hint = {}
        if not (len(unique_pair_run_roots) == 1 and len(unique_pair_run_roots) > 0) and policy:
            run_root_hint = self._pair_policy_preview_run_root_hint(pair_id=pair_id, policy=policy)
        return {
            "PairId": str(pair_id or "").strip(),
            "PairWorkRepoRoot": pair_work_repo_root,
            "PairRunRoot": unique_pair_run_roots[0] if len(unique_pair_run_roots) == 1 else "",
            "TopSourceOutboxPath": top_outbox_path,
            "BottomSourceOutboxPath": bottom_outbox_path,
            "TopPublishReadyPath": str(top_output_paths.get("PublishReadyPath", "") or "").strip(),
            "BottomPublishReadyPath": str(bottom_output_paths.get("PublishReadyPath", "") or "").strip(),
            "TopSourceOutboxWarning": top_outbox_warning,
            "BottomSourceOutboxWarning": bottom_outbox_warning,
            "Warnings": route_warnings,
            "TargetsShareWorkRepoRoot": True,
            "TargetsSharePairRunRoot": len(unique_pair_run_roots) == 1 and len(unique_pair_run_roots) > 0,
            "TargetOutboxesDistinct": len(source_outboxes) == len(pair_rows) and len(set(source_outboxes)) == len(source_outboxes),
            "SharesWorkRepoRootWithOtherPairs": shares_repo_with_other_pairs,
            "RouteState": self._pair_route_state(
                targets_share_work_repo_root=True,
                targets_share_pair_run_root=(len(unique_pair_run_roots) == 1 and len(unique_pair_run_roots) > 0),
                target_outboxes_distinct=(len(source_outboxes) == len(pair_rows) and len(set(source_outboxes)) == len(source_outboxes)),
            ),
            **run_root_hint,
        }

    def _collect_pair_route_matrix(self) -> list[dict[str, object]]:
        route_rows = self._pair_policy_route_rows()
        matrix: list[dict[str, object]] = []
        for pair_id in PAIR_ID_OPTIONS:
            store = self._pair_policy_card_store(pair_id)
            pair_work_repo_root = str(store["repo_root_var"].get() or "").strip()
            policy = self._pair_policy_card_policy_from_store(pair_id)
            route_snapshot = self._pair_policy_card_preview_route_snapshot(
                rows=route_rows,
                pair_id=pair_id,
                pair_work_repo_root=pair_work_repo_root,
                policy=policy,
            )
            badge_spec = self._pair_policy_route_badge_spec(
                route_snapshot=route_snapshot,
                pair_work_repo_root=pair_work_repo_root,
            )
            matrix.append(
                {
                    "PairId": pair_id,
                    "Meta": str(store["meta_var"].get() or "").strip(),
                    "PairWorkRepoRoot": pair_work_repo_root,
                    "DefaultSeedTargetId": str(store["seed_target_var"].get() or "").strip(),
                    "DefaultPairMaxRoundtripCount": str(store["roundtrip_var"].get() or "").strip(),
                    "UseExternalWorkRepoRunRoot": bool(store["external_run_root_var"].get()),
                    "UseExternalWorkRepoContractPaths": bool(store["external_contract_var"].get()),
                    "RouteBadge": badge_spec["text"],
                    "RouteStateLabel": str(store["route_state_var"].get() or "").strip(),
                    "RouteSnapshot": route_snapshot,
                }
            )
        return matrix

    def _pair_route_matrix_payload(self) -> dict[str, object]:
        return {
            "GeneratedAt": self._utc_now_iso(),
            "ConfigPath": self.config_path_var.get().strip(),
            "PairRouteMatrix": self._collect_pair_route_matrix(),
        }

    def _pair_route_matrix_text(self, payload: dict[str, object]) -> str:
        lines = [
            "[pair-route-matrix]",
            f"config={payload.get('ConfigPath', '') or '(없음)'}",
        ]
        for item in list(payload.get("PairRouteMatrix", []) or []):
            snapshot = dict(item.get("RouteSnapshot") or {})
            run_root_preview_reason = str(snapshot.get("RunRootPreviewReason", "") or "").strip()
            expected_run_root_base = str(snapshot.get("ExpectedRunRootBase", "") or "").strip()
            run_root_display = str(snapshot.get("PairRunRoot", "") or "").strip()
            if not run_root_display:
                run_root_display = (
                    "(새 runroot 준비 전)"
                    if run_root_preview_reason == "pair-runroot-not-materialized"
                    else "(미리보기 없음)"
                )
            lines.extend(
                [
                    "",
                    f"{item.get('PairId', '') or '(pair)'} / {item.get('RouteBadge', '') or '(badge)'}",
                    f"meta={item.get('Meta', '') or '(없음)'}",
                    f"repo={item.get('PairWorkRepoRoot', '') or '(없음)'}",
                    f"route={snapshot.get('RouteState', '') or '(미확인)'}",
                    f"runroot={run_root_display}",
                    f"shared-with-other-pairs={snapshot.get('SharesWorkRepoRootWithOtherPairs', False)}",
                    f"top-outbox={snapshot.get('TopSourceOutboxPath', '') or '(없음)'}",
                    f"bottom-outbox={snapshot.get('BottomSourceOutboxPath', '') or '(없음)'}",
                    f"top-publish={snapshot.get('TopPublishReadyPath', '') or '(없음)'}",
                    f"bottom-publish={snapshot.get('BottomPublishReadyPath', '') or '(없음)'}",
                ]
            )
            if run_root_preview_reason:
                lines.append(f"runroot-preview-reason={run_root_preview_reason}")
            if expected_run_root_base:
                lines.append(f"expected-runroot-base={expected_run_root_base}")
        return "\n".join(lines)

    def browse_pair_policy_repo_root(self, pair_id: str) -> None:
        store = self._pair_policy_card_store(pair_id)
        current_repo_root = str(store["repo_root_var"].get() or "").strip()
        initialdir = current_repo_root or str(ROOT)
        selected = filedialog.askdirectory(
            title=f"{pair_id} RepoRoot 선택",
            initialdir=initialdir,
            mustexist=False,
        )
        if not selected:
            return
        store["repo_root_var"].set(selected)
        self.pair_policy_editor_status_var.set(
            f"{pair_id} RepoRoot 선택 완료: {selected} / 저장 전 '실효값'으로 경로를 확인하세요."
        )

    def open_pair_policy_repo_root(self, pair_id: str) -> None:
        store = self._pair_policy_card_store(pair_id)
        repo_root = str(store["repo_root_var"].get() or "").strip()
        self._open_path(repo_root, kind=f"{pair_id} RepoRoot")

    def browse_parallel_coordinator_repo_root(self) -> None:
        current_repo_root = self.parallel_coordinator_repo_root_var.get().strip()
        initialdir = current_repo_root or str(ROOT)
        selected = filedialog.askdirectory(
            title="병렬 drill coordinator repo 선택",
            initialdir=initialdir,
            mustexist=False,
        )
        if not selected:
            return
        self.parallel_coordinator_repo_root_var.set(selected)
        self.pair_policy_editor_status_var.set(
            f"병렬 coordinator repo 선택 완료: {selected}"
        )

    def open_parallel_coordinator_repo_root(self) -> None:
        repo_root = self.parallel_coordinator_repo_root_var.get().strip()
        self._open_path(repo_root, kind="병렬 drill coordinator repo")

    def _selected_parallel_pair_ids(self) -> list[str]:
        selected_pair_ids: list[str] = []
        pair_ids = self._pair_policy_action_pair_ids()
        for pair_id in pair_ids:
            store = self.pair_policy_card_vars.get(pair_id)
            if store is None:
                continue
            selected_var = store.get("parallel_selected_var")
            try:
                selected = bool(selected_var.get()) if selected_var is not None else False
            except Exception:
                selected = False
            if selected:
                selected_pair_ids.append(pair_id)
        return selected_pair_ids

    def _pair_policy_allowed_seed_target_ids(self, pair_id: str) -> list[str]:
        config_path = self.config_path_var.get().strip()
        if not config_path:
            return []
        try:
            document = self.message_config_service.load_config_document(config_path)
            policy = self.message_config_service.effective_pair_policy(document, pair_id)
        except Exception:
            return []
        result: list[str] = []
        for item in [
            str(policy.get("TopTargetId", "") or "").strip(),
            str(policy.get("BottomTargetId", "") or "").strip(),
        ]:
            if item and item not in result:
                result.append(item)
        return result

    def clone_pair_policy_card_settings(self) -> None:
        source_pair_id = self.pair_policy_clone_source_var.get().strip()
        target_pair_id = self.pair_policy_clone_target_var.get().strip()
        if not source_pair_id or not target_pair_id:
            messagebox.showwarning("pair 선택 필요", "복제할 source/target pair를 먼저 선택하세요.")
            return
        if source_pair_id == target_pair_id:
            messagebox.showwarning("pair 선택 오류", "source pair와 target pair는 달라야 합니다.")
            return
        source_store = self._pair_policy_card_store(source_pair_id)
        target_store = self._pair_policy_card_store(target_pair_id)
        target_allowed_seed_ids = self._pair_policy_allowed_seed_target_ids(target_pair_id)
        source_seed_target_id = str(source_store["seed_target_var"].get() or "").strip()
        current_target_seed_target_id = str(target_store["seed_target_var"].get() or "").strip()

        target_store["repo_root_var"].set(str(source_store["repo_root_var"].get() or "").strip())
        target_store["roundtrip_var"].set(str(source_store["roundtrip_var"].get() or "").strip())
        target_store["external_run_root_var"].set(bool(source_store["external_run_root_var"].get()))
        target_store["external_contract_var"].set(bool(source_store["external_contract_var"].get()))

        if source_seed_target_id and source_seed_target_id in target_allowed_seed_ids:
            target_store["seed_target_var"].set(source_seed_target_id)
        elif current_target_seed_target_id and current_target_seed_target_id in target_allowed_seed_ids:
            target_store["seed_target_var"].set(current_target_seed_target_id)
        elif target_allowed_seed_ids:
            target_store["seed_target_var"].set(target_allowed_seed_ids[0])

        self.pair_policy_editor_status_var.set(
            f"{source_pair_id} 설정을 {target_pair_id} 카드에 복제했습니다. 저장 전 '실효값'으로 pair별 경로를 확인하세요."
        )

    def open_pair_policy_pair_summary(self, pair_id: str) -> None:
        store = self._pair_policy_card_store(pair_id)
        route_snapshot = self._pair_policy_card_preview_route_snapshot(
            rows=self._pair_policy_route_rows(),
            pair_id=pair_id,
            pair_work_repo_root=str(store["repo_root_var"].get() or "").strip(),
            policy=self._pair_policy_card_policy_from_store(pair_id),
        )
        pair_run_root = str(route_snapshot.get("PairRunRoot", "") or "").strip()
        if not pair_run_root:
            messagebox.showwarning("pair runroot 없음", f"{pair_id} pair runroot를 아직 확인하지 못했습니다. 먼저 '실효값' 또는 runroot 요약을 확인하세요.")
            return
        path_value = str(Path(pair_run_root) / ".state" / "important-summary.txt")
        if not Path(path_value).exists():
            messagebox.showwarning(
                "important-summary 없음",
                f"{pair_id} pair runroot 아래 important-summary.txt가 없습니다. 먼저 해당 run 요약을 생성하세요.\n{path_value}",
            )
            return
        self._open_path(path_value, kind=f"{pair_id} important-summary.txt")
        self.set_text(self.output_text, f"{pair_id} important-summary 열기:\n{path_value}")

    def _apply_pair_policy_card_values_to_document(self, document: dict, pair_id: str) -> dict[str, object]:
        store = self._pair_policy_card_store(pair_id)
        roundtrip_text = str(store["roundtrip_var"].get() or "").strip() or "0"
        try:
            roundtrip_count = int(roundtrip_text)
        except ValueError as exc:
            raise ValueError(f"{pair_id} roundtrip 값은 정수여야 합니다.") from exc
        if roundtrip_count < 0:
            raise ValueError(f"{pair_id} roundtrip 값은 0 이상이어야 합니다.")
        policy = self.message_config_service.effective_pair_policy(document, pair_id)
        allowed_seed_target_ids = [
            item
            for item in [
                str(policy.get("TopTargetId", "") or "").strip(),
                str(policy.get("BottomTargetId", "") or "").strip(),
            ]
            if item
        ]
        seed_target_id = str(store["seed_target_var"].get() or "").strip()
        if seed_target_id and allowed_seed_target_ids and seed_target_id not in allowed_seed_target_ids:
            raise ValueError(f"{pair_id} seed target는 {', '.join(allowed_seed_target_ids)} 중 하나여야 합니다.")
        self.message_config_service.set_pair_policy_values(
            document,
            pair_id,
            default_seed_work_repo_root=str(store["repo_root_var"].get() or "").strip(),
            default_seed_target_id=seed_target_id or (allowed_seed_target_ids[0] if allowed_seed_target_ids else ""),
            use_external_work_repo_run_root=bool(store["external_run_root_var"].get()),
            use_external_work_repo_contract_paths=bool(store["external_contract_var"].get()),
            default_pair_max_roundtrip_count=roundtrip_count,
        )
        return self.message_config_service.effective_pair_policy(document, pair_id)

    def refresh_pair_policy_editor(self) -> None:
        config_path = self.config_path_var.get().strip()
        if not config_path:
            self.pair_policy_editor_status_var.set("ConfigPath가 없어 pair 설정 카드를 불러오지 못했습니다.")
            return
        auto_preview_requested = bool(self.__dict__.pop("_pair_policy_refresh_auto_preview", False))
        self.pair_policy_effective_preview_rows = []
        try:
            document = self.message_config_service.load_config_document(config_path)
        except Exception as exc:
            self.pair_policy_editor_status_var.set(f"pair 설정 카드 로드 실패: {exc}")
            return
        active_pair_ids = self._pair_policy_action_pair_ids(document)
        for pair_id in PAIR_ID_OPTIONS:
            store = self.pair_policy_card_vars[pair_id]
            if pair_id not in active_pair_ids:
                store["meta_var"].set(f"{pair_id} / (미구성)")
                store["repo_root_var"].set("")
                store["seed_target_var"].set("")
                store["roundtrip_var"].set("0")
                store["external_run_root_var"].set(False)
                store["external_contract_var"].set(False)
                store["repo_source_badge_var"].set("REPO UNSET")
                self._apply_pair_policy_route_feedback(
                    pair_id=pair_id,
                    route_snapshot={"RouteState": "(미구성)"},
                    pair_work_repo_root="",
                )
                store["effective_preview_var"].set("PairDefinitions에 없는 pair입니다.")
                self._sync_pair_policy_effective_preview_widget(pair_id)
                if pair_id in self.pair_policy_card_seed_combos:
                    self.pair_policy_card_seed_combos[pair_id].configure(values=[], state="disabled")
                self._set_pair_policy_card_action_enabled(pair_id, enabled=False)
                continue
            self._set_pair_policy_card_action_enabled(pair_id, enabled=True)
            policy = self.message_config_service.effective_pair_policy(document, pair_id)
            self._apply_pair_policy_source_feedback(pair_id=pair_id, policy=policy)
            seed_values = [
                item
                for item in [
                    str(policy.get("TopTargetId", "") or "").strip(),
                    str(policy.get("BottomTargetId", "") or "").strip(),
                ]
                if item
            ]
            store["meta_var"].set(
                "{0} / top={1} / bottom={2}".format(
                    pair_id,
                    policy.get("TopTargetId", "") or "-",
                    policy.get("BottomTargetId", "") or "-",
                )
            )
            store["repo_root_var"].set(str(policy.get("DefaultSeedWorkRepoRoot", "") or ""))
            store["seed_target_var"].set(str(policy.get("DefaultSeedTargetId", "") or (seed_values[0] if seed_values else "")))
            store["roundtrip_var"].set(str(policy.get("DefaultPairMaxRoundtripCount", 0) or 0))
            store["external_run_root_var"].set(bool(policy.get("UseExternalWorkRepoRunRoot", False)))
            store["external_contract_var"].set(bool(policy.get("UseExternalWorkRepoContractPaths", False)))
            if pair_id in self.pair_policy_card_seed_combos:
                self.pair_policy_card_seed_combos[pair_id].configure(values=seed_values, state="readonly" if seed_values else "disabled")
            route_snapshot = self._build_pair_route_snapshot(pair_id)
            self._apply_pair_policy_route_feedback(
                pair_id=pair_id,
                route_snapshot=route_snapshot,
                pair_work_repo_root=str(policy.get("DefaultSeedWorkRepoRoot", "") or ""),
            )
            store["effective_preview_var"].set(
                self._pair_policy_build_preview_text(
                    pair_id=pair_id,
                    policy=policy,
                    route_snapshot=route_snapshot,
                    warnings=[],
                )
            )
            self._sync_pair_policy_effective_preview_widget(pair_id)
        status_message = "4 pair 설정 카드를 현재 config 기준으로 동기화했습니다. 저장 전 '실효값'으로 pair별 경로를 바로 확인하세요."
        if auto_preview_requested and len(active_pair_ids) > 1:
            try:
                payload = self._render_all_pair_policy_effective_previews(
                    document=document,
                    config_path=config_path,
                    pair_ids=active_pair_ids,
                    mode="both",
                )
                summary = self._apply_pair_policy_effective_preview_payload(
                    document=document,
                    pair_ids=active_pair_ids,
                    payload=payload,
                )
                status_message = (
                    "4 pair 설정 카드를 현재 config 기준으로 동기화했습니다. "
                    "pair별 실효값 자동 갱신 완료 / active={0} / ok={1} / shared={2} / check={3} / warnings={4}".format(
                        len(active_pair_ids),
                        summary["ok"],
                        summary["shared"],
                        summary["check"],
                        summary["warnings"],
                    )
                )
            except Exception as exc:
                status_message = (
                    "4 pair 설정 카드를 현재 config 기준으로 동기화했습니다. "
                    f"pair별 실효값 자동 갱신 실패: {exc}"
                )
        self.pair_policy_editor_status_var.set(status_message)
        self._refresh_pair_policy_override_badges()
        self._refresh_pair_policy_parallel_status_board()
        self.refresh_seed_kickoff_composer()

    def preview_pair_policy_effective(self, pair_id: str) -> None:
        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("ConfigPath 없음", "ConfigPath를 먼저 확인하세요.")
            return
        try:
            document = self.message_config_service.load_config_document(config_path)
            configured_pair_ids = self._pair_policy_action_pair_ids(document)
            for current_pair_id in configured_pair_ids:
                self._apply_pair_policy_card_values_to_document(document, current_pair_id)
        except Exception as exc:
            messagebox.showwarning("pair 설정 검증 실패", str(exc))
            self.pair_policy_editor_status_var.set(f"pair 설정 검증 실패: {exc}")
            return
        if pair_id not in configured_pair_ids:
            self._apply_pair_policy_route_feedback(
                pair_id=pair_id,
                route_snapshot={"RouteState": "(미구성)"},
                pair_work_repo_root="",
            )
            store = self._pair_policy_card_store(pair_id)
            store["effective_preview_var"].set("PairDefinitions에 없는 pair입니다.")
            self._sync_pair_policy_effective_preview_widget(pair_id)
            self.pair_policy_editor_status_var.set(f"{pair_id}는 PairDefinitions에 없는 pair입니다.")
            return
        try:
            payload = self._render_pair_policy_effective_preview(
                document=document,
                config_path=config_path,
                pair_id=pair_id,
                target_id="",
                mode="both",
            )
        except Exception as exc:
            messagebox.showerror("실효값 미리보기 실패", str(exc))
            self.pair_policy_editor_status_var.set(f"pair 실효값 미리보기 실패: {exc}")
            return
        policy = self.message_config_service.effective_pair_policy(document, pair_id)
        self._apply_pair_policy_source_feedback(pair_id=pair_id, policy=policy)
        rows = [row for row in list(payload.get("PreviewRows", []) or []) if str(row.get("PairId", "") or "").strip() == pair_id]
        route_snapshot = self._pair_policy_card_preview_route_snapshot(
            rows=rows,
            pair_id=pair_id,
            pair_work_repo_root=str(policy.get("DefaultSeedWorkRepoRoot", "") or ""),
            policy=policy,
        )
        warnings = [str(item) for item in list(payload.get("Warnings", []) or [])]
        store = self._pair_policy_card_store(pair_id)
        self._apply_pair_policy_route_feedback(
            pair_id=pair_id,
            route_snapshot=route_snapshot,
            pair_work_repo_root=str(policy.get("DefaultSeedWorkRepoRoot", "") or ""),
        )
        store["effective_preview_var"].set(
            self._pair_policy_build_preview_text(
                pair_id=pair_id,
                policy=policy,
                route_snapshot=route_snapshot,
                warnings=warnings,
            )
            )
        self._sync_pair_policy_effective_preview_widget(pair_id)
        self.pair_policy_editor_status_var.set(f"{pair_id} 실효값 미리보기 갱신 완료 / warnings={len(warnings)}")
        self._refresh_pair_policy_parallel_status_board()
        self.refresh_seed_kickoff_composer()

    def preview_all_pair_policy_effective(self) -> None:
        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("ConfigPath 없음", "ConfigPath를 먼저 확인하세요.")
            return
        try:
            document = self.message_config_service.load_config_document(config_path)
            active_pair_ids = self._pair_policy_action_pair_ids(document)
            for current_pair_id in active_pair_ids:
                self._apply_pair_policy_card_values_to_document(document, current_pair_id)
        except Exception as exc:
            messagebox.showwarning("pair 설정 검증 실패", str(exc))
            self.pair_policy_editor_status_var.set(f"pair 설정 검증 실패: {exc}")
            return
        if not active_pair_ids:
            self.pair_policy_editor_status_var.set("전체 pair 실효값 미리보기 실패: 구성된 pair가 없습니다.")
            return
        try:
            payload = self._render_all_pair_policy_effective_previews(
                document=document,
                config_path=config_path,
                pair_ids=active_pair_ids,
                mode="both",
            )
        except Exception as exc:
            messagebox.showerror("전체 실효값 미리보기 실패", str(exc))
            self.pair_policy_editor_status_var.set(f"전체 pair 실효값 미리보기 실패: {exc}")
            return
        summary = self._apply_pair_policy_effective_preview_payload(
            document=document,
            pair_ids=active_pair_ids,
            payload=payload,
        )
        self.pair_policy_editor_status_var.set(
            "전체 pair 실효값 갱신 완료 / active={0} / ok={1} / shared={2} / check={3} / warnings={4}".format(
                len(active_pair_ids),
                summary["ok"],
                summary["shared"],
                summary["check"],
                summary["warnings"],
            )
        )
        self._refresh_pair_policy_parallel_status_board()
        self.refresh_seed_kickoff_composer()

    def copy_pair_route_matrix(self) -> None:
        payload = self._pair_route_matrix_payload()
        text = self._pair_route_matrix_text(payload)
        self._copy_to_clipboard(text)
        self.set_text(self.output_text, f"pair route matrix 복사 완료:\n\n{text}")
        self.pair_policy_editor_status_var.set("pair route matrix를 클립보드로 복사했습니다.")

    def copy_pair_policy_effective_preview(self, pair_id: str) -> None:
        store = self._pair_policy_card_store(pair_id)
        text = str(store["effective_preview_var"].get() or "").strip()
        if not text:
            messagebox.showwarning("실효값 없음", f"{pair_id} 실효값이 아직 없습니다. 먼저 '실효값' 또는 '전체 실효값'을 실행하세요.")
            return
        self._copy_to_clipboard(text)
        self.set_text(self.output_text, f"{pair_id} 실효값 복사 완료:\n\n{text}")
        self.pair_policy_editor_status_var.set(f"{pair_id} 실효값을 클립보드로 복사했습니다.")

    def save_pair_route_matrix_json(self) -> None:
        payload = self._pair_route_matrix_payload()
        initialdir = ROOT / "_tmp"
        initialdir.mkdir(exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        selected = filedialog.asksaveasfilename(
            title="pair route matrix JSON 저장",
            initialdir=str(initialdir),
            initialfile=f"pair-route-matrix.{timestamp}.json",
            defaultextension=".json",
            filetypes=[("JSON", "*.json"), ("All files", "*.*")],
        )
        if not selected:
            return
        Path(selected).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        self.set_text(self.output_text, f"pair route matrix JSON 저장 완료:\n{selected}")
        self.pair_policy_editor_status_var.set(f"pair route matrix JSON 저장 완료: {selected}")
        messagebox.showinfo("저장 완료", selected)

    def _pair_policy_route_affecting_fingerprint(self, policy: dict[str, object]) -> tuple[object, ...]:
        normalized_policy = dict(policy or {})
        return (
            str(normalized_policy.get("DefaultSeedWorkRepoRoot", "") or "").strip(),
            str(normalized_policy.get("DefaultSeedTargetId", "") or "").strip(),
            bool(normalized_policy.get("UseExternalWorkRepoRunRoot", False)),
            bool(normalized_policy.get("UseExternalWorkRepoContractPaths", False)),
        )

    def save_pair_policy_editor(self) -> None:
        if self._message_editor_has_unsaved_changes():
            messagebox.showwarning("저장 차단", "Initial/Handoff 문구 편집에 미저장 변경이 있습니다. 먼저 저장하거나 취소한 뒤 pair 설정을 저장하세요.")
            self.pair_policy_editor_status_var.set("pair 설정 저장 차단: 문구 편집 미저장 변경이 있습니다.")
            return
        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("ConfigPath 없음", "ConfigPath를 먼저 확인하세요.")
            return
        try:
            document = self.message_config_service.load_config_document(config_path)
            known_pair_ids = self._pair_policy_action_pair_ids(document)
            previous_repo_roots = {
                pair_id: str(self.message_config_service.effective_pair_policy(document, pair_id).get("DefaultSeedWorkRepoRoot", "") or "").strip()
                for pair_id in known_pair_ids
            }
            previous_route_fingerprints = {
                pair_id: self._pair_policy_route_affecting_fingerprint(
                    self.message_config_service.effective_pair_policy(document, pair_id)
                )
                for pair_id in known_pair_ids
            }
            for pair_id in known_pair_ids:
                self._apply_pair_policy_card_values_to_document(document, pair_id)
            changed_repo_pairs = [
                pair_id
                for pair_id in known_pair_ids
                if str(self.message_config_service.effective_pair_policy(document, pair_id).get("DefaultSeedWorkRepoRoot", "") or "").strip()
                != previous_repo_roots.get(pair_id, "")
            ]
            changed_route_pairs = [
                pair_id
                for pair_id in known_pair_ids
                if self._pair_policy_route_affecting_fingerprint(
                    self.message_config_service.effective_pair_policy(document, pair_id)
                )
                != previous_route_fingerprints.get(pair_id, ())
            ]
            backup_path = self.message_config_service.save_document(config_path, document)
        except Exception as exc:
            messagebox.showerror("pair 설정 저장 실패", str(exc))
            self.pair_policy_editor_status_var.set(f"pair 설정 저장 실패: {exc}")
            return
        cleared_run_root = False
        if changed_route_pairs and self.run_root_var.get().strip():
            self.run_root_var.set("")
            cleared_run_root = True
        status_message = f"pair 설정 저장 완료 / 백업: {backup_path}"
        if changed_repo_pairs:
            status_message += " / repo 변경: " + ", ".join(changed_repo_pairs)
        elif changed_route_pairs:
            status_message += " / route 변경: " + ", ".join(changed_route_pairs)
        if cleared_run_root:
            status_message += " / old RunRoot override 자동 비움"
        self.load_message_editor_document()
        self.load_effective_config()
        preview_status_message = str(self.pair_policy_editor_status_var.get() or "").strip()
        applied_lines: list[str] = []
        for pair_id in changed_route_pairs or known_pair_ids[:1]:
            policy = self.message_config_service.effective_pair_policy(self.message_config_doc or {}, pair_id)
            route_snapshot = self._pair_policy_card_preview_route_snapshot(
                rows=self._pair_policy_route_rows(),
                pair_id=pair_id,
                pair_work_repo_root=str(policy.get("DefaultSeedWorkRepoRoot", "") or ""),
                policy=policy,
            )
            applied_lines.append(
                "- {pair}: repo-source={source} / repo={repo} / next-runroot={runroot} / top-outbox={outbox}".format(
                    pair=pair_id,
                    source=policy.get("DefaultSeedWorkRepoRootSource", "") or "unset",
                    repo=policy.get("DefaultSeedWorkRepoRoot", "") or "(없음)",
                    runroot=route_snapshot.get("PairRunRoot", "") or "(미리보기 없음)",
                    outbox=route_snapshot.get("TopSourceOutboxPath", "") or "(없음)",
                )
            )
        if preview_status_message and preview_status_message != status_message:
            status_message += "\n" + preview_status_message
        if applied_lines:
            status_message += "\n적용 확인:\n" + "\n".join(applied_lines)
        self.pair_policy_editor_status_var.set(status_message)

    def _pair_policy_card_matches_loaded_policy(self, pair_id: str) -> bool:
        document = self.message_config_doc or {}
        if not isinstance(document, dict) or not document:
            return False
        try:
            policy = self.message_config_service.effective_pair_policy(document, pair_id)
        except Exception:
            return False
        store = self._pair_policy_card_store(pair_id)
        expected_repo_root = str(policy.get("DefaultSeedWorkRepoRoot", "") or "").strip()
        expected_seed_target = str(policy.get("DefaultSeedTargetId", "") or "").strip()
        expected_roundtrip = str(int(policy.get("DefaultPairMaxRoundtripCount", 0) or 0))
        return (
            str(store["repo_root_var"].get() or "").strip() == expected_repo_root
            and str(store["seed_target_var"].get() or "").strip() == expected_seed_target
            and str(store["roundtrip_var"].get() or "").strip() == expected_roundtrip
            and bool(store["external_run_root_var"].get()) == bool(policy.get("UseExternalWorkRepoRunRoot", False))
            and bool(store["external_contract_var"].get()) == bool(policy.get("UseExternalWorkRepoContractPaths", False))
        )

    def _seed_kickoff_known_pair_ids(self, document: dict | None = None) -> list[str]:
        active = self._pair_policy_action_pair_ids(document)
        return [pair_id for pair_id in PAIR_ID_OPTIONS if pair_id in active]

    def _seed_kickoff_target_ids(self, document: dict, pair_id: str) -> list[str]:
        pair_definition = self.message_config_service.pair_definition_map(document).get(pair_id, {})
        return [
            item
            for item in [
                str(pair_definition.get("TopTargetId", "") or "").strip(),
                str(pair_definition.get("BottomTargetId", "") or "").strip(),
            ]
            if item
        ]

    def _seed_kickoff_task_text_value(self) -> str:
        widget = getattr(self, "seed_kickoff_task_text", None)
        if widget is None:
            return ""
        try:
            return str(widget.get("1.0", "end-1c") or "").strip()
        except Exception:
            return ""

    def _seed_kickoff_role_for_target(self, document: dict, pair_id: str, target_id: str) -> str:
        pair_definition = self.message_config_service.pair_definition_map(document).get(pair_id, {})
        top_target_id = str(pair_definition.get("TopTargetId", "") or "").strip()
        bottom_target_id = str(pair_definition.get("BottomTargetId", "") or "").strip()
        normalized_target_id = str(target_id or "").strip()
        if normalized_target_id and normalized_target_id == top_target_id:
            return "top"
        if normalized_target_id and normalized_target_id == bottom_target_id:
            return "bottom"
        return ""

    def _seed_kickoff_queue_text(self, *, task_text: str, review_input_path: str) -> str:
        lines: list[str] = []
        if task_text:
            lines.extend(["[초기 실행 작업 설명]", task_text])
        if review_input_path:
            if lines:
                lines.append("")
            lines.extend(
                [
                    "[추가 입력 파일]",
                    "- 아래 파일을 먼저 확인하고 작업에 반영하세요.",
                    review_input_path,
                ]
            )
        return "\n".join(lines).strip()

    def _seed_kickoff_contract_block(
        self,
        *,
        pair_id: str,
        target_id: str,
        role_name: str,
        work_repo_root: str,
        next_run_root_preview: str,
        pair_run_root: str,
        pair_target_folder: str,
        source_summary_path: str,
        source_review_zip_path: str,
        publish_ready_path: str,
        publish_helper_command: str,
        review_input_path: str,
    ) -> str:
        lines = [
            "[자동 계약 / 경로]",
            f"- pair: {pair_id}",
            f"- target: {target_id or '(없음)'}",
            f"- role: {role_name or '(미확인)'}",
            f"- work repo: {work_repo_root or '(없음)'}",
            f"- next runroot preview: {next_run_root_preview or '(없음)'}",
            f"- pair runroot: {pair_run_root or '(없음)'}",
            f"- 내 작업 폴더: {pair_target_folder or '(없음)'}",
        ]
        if review_input_path:
            lines.append(f"- 입력 파일: {review_input_path}")
        lines.extend(
            [
                "",
                "[작업자가 직접 만들 파일]",
                f"summary.txt: {source_summary_path or '(없음)'}",
                f"review.zip: {source_review_zip_path or '(없음)'}",
                "",
                "[마지막 단계 / publish helper]",
                f"실행: {publish_helper_command or '(없음)'}",
                f"helper output marker: {publish_ready_path or '(없음)'}",
                "publish.ready.json은 직접 만들지 말고, summary.txt와 review.zip이 준비된 뒤 마지막에 helper를 실행하세요.",
            ]
        )
        return "\n".join(lines)

    def _seed_kickoff_publish_helper_commands(
        self,
        *,
        publish_cmd_path: str,
        publish_script_path: str,
    ) -> dict[str, str]:
        normalized_cmd_path = str(publish_cmd_path or "").strip()
        normalized_script_path = str(publish_script_path or "").strip()
        preferred_command = subprocess.list2cmdline([normalized_cmd_path]) if normalized_cmd_path else ""
        script_command = (
            subprocess.list2cmdline(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    normalized_script_path,
                    "-Overwrite",
                ]
            )
            if normalized_script_path
            else ""
        )
        if not preferred_command:
            preferred_command = script_command
        return {
            "PreferredCommand": preferred_command,
            "ScriptCommand": script_command,
            "PublishCmdPath": normalized_cmd_path,
            "PublishScriptPath": normalized_script_path,
        }

    def _seed_kickoff_helper_block(
        self,
        *,
        publish_ready_path: str,
        publish_helper_command: str,
        publish_script_command: str,
        publish_cmd_path: str,
        publish_script_path: str,
    ) -> str:
        lines = [
            "[publish helper]",
            f"- 권장 실행: {publish_helper_command or '(없음)'}",
            f"- helper output marker: {publish_ready_path or '(없음)'}",
            "- summary.txt와 review.zip 작성이 끝난 뒤 마지막에만 helper를 실행하세요.",
            "- publish.ready.json은 helper가 자동 생성/overwrite합니다.",
        ]
        if publish_script_command and publish_script_command != publish_helper_command:
            lines.append(f"- script 직접 실행: {publish_script_command}")
        if publish_cmd_path:
            lines.append(f"- helper cmd path: {publish_cmd_path}")
        if publish_script_path:
            lines.append(f"- helper script path: {publish_script_path}")
        return "\n".join(lines)

    def _seed_kickoff_full_preview_text(
        self,
        *,
        queue_text: str,
        contract_text: str,
        helper_text: str,
        repo_source: str,
        route_badge: str,
    ) -> str:
        queue_block = queue_text or "(입력된 작업 설명 없음)"
        return "\n".join(
            [
                "[초기 실행 입력 합성 미리보기]",
                f"repo-source={repo_source or 'unset'} / route={route_badge or '(미확인)'}",
                "",
                queue_block,
                "",
                contract_text,
                "",
                helper_text,
                "",
                "[시작 방법]",
                "- 수동 시작: '초간단 시작문 복사'로 전체 문구를 복사해 대상 PowerShell/셀 창에 직접 붙여넣습니다.",
                "- 이후 대상이 summary.txt / review.zip 을 만들고 마지막에 publish helper를 실행하면 watcher가 다음 단계부터 자동 진행합니다.",
                "",
                "[queue 등록 동작]",
                "- '초기 입력 큐잉'은 위 작업 설명 블록만 1회성 queue에 등록합니다.",
                "- 경로/파일 계약/helper 안내는 시스템이 seed/handoff scaffold로 별도 자동 추가합니다.",
            ]
        )

    def _seed_kickoff_manual_start_text(
        self,
        *,
        task_text: str,
        review_input_path: str,
        source_summary_path: str,
        source_review_zip_path: str,
        publish_ready_path: str,
        publish_helper_command: str,
    ) -> str:
        lines: list[str] = []
        normalized_task = str(task_text or "").strip()
        normalized_input = str(review_input_path or "").strip()
        if normalized_task:
            lines.extend(["[작업 내용]", normalized_task, ""])
        if normalized_input:
            lines.extend(["[먼저 확인할 입력 파일]", normalized_input, ""])
        lines.extend(
            [
                "[생성해야 할 파일]",
                f"1. summary.txt -> {source_summary_path or '(없음)'}",
                f"2. review.zip -> {source_review_zip_path or '(없음)'}",
                "",
                "[마지막 단계]",
                f"3. publish helper 실행 -> {publish_helper_command or '(없음)'}",
                f"4. helper output marker -> {publish_ready_path or '(없음)'}",
                "",
                "[규칙]",
                "- summary.txt와 review.zip을 먼저 생성하세요.",
                "- publish.ready.json은 직접 만들지 마세요.",
                "- publish helper는 마지막에만 실행하세요.",
                "- 최종 산출물은 위 경로 외 다른 위치에 두지 마세요.",
            ]
        )
        return "\n".join(lines).strip()

    def _seed_kickoff_detailed_start_text(
        self,
        *,
        task_text: str,
        review_input_path: str,
        source_summary_path: str,
        source_review_zip_path: str,
        publish_ready_path: str,
        publish_helper_command: str,
        publish_script_command: str,
        publish_cmd_path: str,
        publish_script_path: str,
    ) -> str:
        lines: list[str] = []
        normalized_task = str(task_text or "").strip()
        normalized_input = str(review_input_path or "").strip()
        if normalized_task:
            lines.extend(["[작업 내용]", normalized_task, ""])
        if normalized_input:
            lines.extend(["[먼저 확인할 입력 파일]", normalized_input, ""])
        lines.extend(
            [
                "[생성 지시]",
                f"- summary.txt 생성: {source_summary_path or '(없음)'}",
                f"- review.zip 생성: {source_review_zip_path or '(없음)'}",
                "",
                "[마지막 단계]",
                f"- publish helper 실행: {publish_helper_command or '(없음)'}",
                f"- helper output marker: {publish_ready_path or '(없음)'}",
                "",
                "[순서 규칙]",
                "1. summary.txt 먼저 생성",
                "2. review.zip 다음 생성",
                "3. publish helper는 마지막에만 실행",
                "4. publish.ready.json은 helper가 자동 생성",
            ]
        )
        if publish_script_command and publish_script_command != publish_helper_command:
            lines.extend(
                [
                    "",
                    "[script 직접 실행]",
                    f"- {publish_script_command}",
                ]
            )
        if publish_cmd_path or publish_script_path:
            lines.extend(
                [
                    "",
                    "[helper 경로]",
                    f"- cmd path: {publish_cmd_path or '(없음)'}",
                    f"- script path: {publish_script_path or '(없음)'}",
                ]
            )
        return "\n".join(lines).strip()

    def _seed_kickoff_target_banner_text(self, *, pair_id: str, target_id: str) -> str:
        return f"붙여넣기 대상: {pair_id or '(pair 없음)'} / {target_id or '(target 없음)'} 실제 셀 창"

    def _seed_kickoff_resolved_output_paths(self, row: dict[str, object] | None) -> dict[str, str]:
        return self._resolved_output_paths_from_row(row)

    def _seed_kickoff_readiness_text(self, payload: dict[str, object] | None = None) -> str:
        pair_id = str(self.seed_kickoff_pair_var.get() or "").strip() or "(pair 없음)"
        target_id = str(self.seed_kickoff_target_var.get() or "").strip() or "(target 없음)"
        route_badge = ""
        repo_source = ""
        if payload is not None:
            route_badge = str(payload.get("RouteBadge", "") or "").strip()
            repo_source = str((dict(payload.get("Policy", {}) or {})).get("DefaultSeedWorkRepoRootSource", "") or "").strip()
        elif pair_id in self.pair_policy_card_vars:
            store = self._pair_policy_card_store(pair_id)
            route_badge = str(store["route_badge_var"].get() or "").strip()
            repo_source = str(store["repo_source_badge_var"].get() or "").strip()

        if self._message_editor_has_unsaved_changes():
            return "차단: Initial/Handoff 미저장 변경"
        if pair_id in self.pair_policy_card_vars and not self._pair_policy_card_matches_loaded_policy(pair_id):
            return "차단: pair 카드 미저장"
        if not target_id or target_id == "(target 없음)":
            return "차단: SeedTarget 선택 필요"
        if route_badge and route_badge not in {"ROUTE OK", "SHARED REPO OK"}:
            return f"차단: route 비정상 ({route_badge})"
        if payload is not None:
            resolved_paths = dict(payload.get("ResolvedOutputPaths", {}) or {})
            required_paths = [
                str(resolved_paths.get("SourceSummaryPath", "") or "").strip(),
                str(resolved_paths.get("SourceReviewZipPath", "") or "").strip(),
                str(resolved_paths.get("PublishReadyPath", "") or "").strip(),
            ]
            if any(not item for item in required_paths):
                return "차단: 경로 계산 실패"
        task_text = self._seed_kickoff_task_text_value()
        review_input_path = str(self.seed_kickoff_review_input_var.get() or "").strip()
        if not task_text and not review_input_path:
            return "차단: 작업 설명 또는 입력 파일 필요"
        readiness_tail = []
        if repo_source:
            readiness_tail.append(f"repo={repo_source}")
        if route_badge:
            readiness_tail.append(f"route={route_badge}")
        tail = f" ({' / '.join(readiness_tail)})" if readiness_tail else ""
        return f"준비됨: 시작문 복사 또는 초기 입력 큐잉 가능{tail}"

    def _apply_seed_kickoff_detail_visibility(self) -> None:
        visible = bool(self.seed_kickoff_detail_visible_var.get())
        input_columns = self.__dict__.get("seed_kickoff_input_columns_frame")
        detail_column = self.__dict__.get("seed_kickoff_detail_column_frame")
        preview_stack = self.__dict__.get("seed_kickoff_preview_stack_frame")
        preview_detail = self.__dict__.get("seed_kickoff_preview_detail_frame")
        detail_actions = self.__dict__.get("seed_kickoff_detail_actions_frame")
        if input_columns is not None:
            try:
                input_columns.columnconfigure(1, weight=1 if visible else 0)
            except Exception:
                pass
        if detail_column is not None:
            if visible:
                detail_column.grid()
            else:
                detail_column.grid_remove()
        if preview_stack is not None:
            if visible:
                preview_stack.grid()
            else:
                preview_stack.grid_remove()
        if preview_detail is not None:
            if visible:
                preview_detail.grid()
            else:
                preview_detail.grid_remove()
        if detail_actions is not None:
            if visible:
                detail_actions.grid()
            else:
                detail_actions.grid_remove()

    def _sync_seed_kickoff_with_action_context(self) -> None:
        if not self._has_ui_attr("seed_kickoff_pair_var"):
            return
        pair_id = self._selected_pair_id()
        if not pair_id:
            return
        target_id = self.target_id_var.get().strip() or self._resolve_top_target_for_pair(pair_id)
        self.seed_kickoff_pair_var.set(pair_id)
        if target_id:
            self.seed_kickoff_target_var.set(target_id)
        self.refresh_seed_kickoff_composer()

    def _artifact_home_browse_pair_scope_enabled(self) -> bool:
        browse_var = self.__dict__.get("artifact_home_browse_pair_filter_var")
        return bool(browse_var is not None and hasattr(browse_var, "get") and browse_var.get())

    def _artifact_home_browse_target_scope_enabled(self) -> bool:
        browse_var = self.__dict__.get("artifact_home_browse_target_filter_var")
        return bool(browse_var is not None and hasattr(browse_var, "get") and browse_var.get())

    def _selected_artifact_browse_pair_id(self) -> str:
        home_pair = self._selected_home_pair_selection() if self._has_ui_attr("home_pair_tree") else ""
        if home_pair:
            return home_pair
        return self._selected_pair_id()

    def _selected_artifact_browse_target_id(self) -> str:
        browse_pair = self._selected_artifact_browse_pair_id()
        if not browse_pair:
            return ""
        inspection_target = self._selected_inspection_target_id()
        if inspection_target:
            preview_row = self._preview_row_for_target(inspection_target)
            if preview_row is not None and str(preview_row.get("PairId", "") or "").strip() == browse_pair:
                return inspection_target
        action_target = self.target_id_var.get().strip()
        if action_target:
            preview_row = self._preview_row_for_target(action_target)
            if preview_row is not None and str(preview_row.get("PairId", "") or "").strip() == browse_pair:
                return action_target
        selected_state = self._selected_artifact_state() if self._has_ui_attr("artifact_tree") else None
        if selected_state is not None and str(selected_state.pair_id or "").strip() == browse_pair:
            return str(selected_state.target_id or "").strip()
        return self._resolve_top_target_for_pair(browse_pair)

    def _update_artifact_home_browse_toggle_label(self) -> None:
        label_var = self.__dict__.get("artifact_home_browse_toggle_var")
        if label_var is None or not hasattr(label_var, "set"):
            return
        if self._artifact_home_browse_pair_scope_enabled():
            pair_id = self._selected_artifact_browse_pair_id() or "(미선택)"
            label_var.set(f"Home Pair 고정 해제 ({pair_id})")
        else:
            label_var.set("Home Pair만 보기")
        target_label_var = self.__dict__.get("artifact_home_browse_target_toggle_var")
        if target_label_var is None or not hasattr(target_label_var, "set"):
            return
        if self._artifact_home_browse_target_scope_enabled():
            target_id = self._selected_artifact_browse_target_id() or "(target 없음)"
            target_label_var.set(f"target 고정 해제 ({target_id})")
        else:
            target_label_var.set("보고 target 따라가기")

    def _sync_artifact_filters_with_home_pair_selection(self, *, refresh: bool = True) -> None:
        if not self._has_ui_attr("artifact_pair_filter_var"):
            return
        pair_id = self._selected_artifact_browse_pair_id()
        self.artifact_pair_filter_var.set(pair_id)
        target_id = self._selected_artifact_browse_target_id() if self._artifact_home_browse_target_scope_enabled() else ""
        self.artifact_target_filter_var.set(target_id)
        self._update_artifact_home_browse_toggle_label()
        if refresh and self._has_ui_attr("artifact_tree"):
            self.refresh_artifacts_tab()

    def _disable_artifact_home_browse_pair_scope(self, *, restore_saved_filters: bool = False) -> None:
        browse_var = self.__dict__.get("artifact_home_browse_pair_filter_var")
        if browse_var is not None and hasattr(browse_var, "set"):
            browse_var.set(False)
        target_browse_var = self.__dict__.get("artifact_home_browse_target_filter_var")
        if target_browse_var is not None and hasattr(target_browse_var, "set"):
            target_browse_var.set(False)
        if restore_saved_filters and self._has_ui_attr("artifact_pair_filter_var"):
            saved_filters = self.__dict__.get("_artifact_manual_filters_before_browse")
            if isinstance(saved_filters, tuple) and len(saved_filters) == 2:
                self.artifact_pair_filter_var.set(str(saved_filters[0] or ""))
                self.artifact_target_filter_var.set(str(saved_filters[1] or ""))
        self.__dict__["_artifact_manual_filters_before_browse"] = None
        self._update_artifact_home_browse_toggle_label()

    def _sync_artifact_filters_with_action_context(self, *, include_target: bool = True, refresh: bool = True) -> None:
        if not self._has_ui_attr("artifact_pair_filter_var"):
            return
        if self._artifact_home_browse_pair_scope_enabled():
            self._sync_artifact_filters_with_home_pair_selection(refresh=refresh)
            return
        self.artifact_pair_filter_var.set(self._selected_pair_id())
        target_id = self.target_id_var.get().strip() if include_target else ""
        self.artifact_target_filter_var.set(target_id)
        if refresh and self._has_ui_attr("artifact_tree"):
            self.refresh_artifacts_tab()

    def _sync_pair_scoped_views_with_action_context(self, *, refresh_artifacts: bool = True) -> None:
        self._sync_seed_kickoff_with_action_context()
        self._sync_artifact_filters_with_action_context(include_target=True, refresh=refresh_artifacts)

    def sync_artifact_filters_to_action_context(self) -> None:
        self._disable_artifact_home_browse_pair_scope(restore_saved_filters=False)
        self._sync_artifact_filters_with_action_context(include_target=True, refresh=True)
        self.set_query_result(
            "마지막 조회: 현재 실행 Pair/Target 기준으로 결과 필터를 맞췄습니다.",
            context=self._artifact_query_context_summary(),
        )

    def toggle_artifact_home_target_scope(self) -> None:
        if not self._has_ui_attr("artifact_pair_filter_var"):
            return
        target_browse_var = self.__dict__.get("artifact_home_browse_target_filter_var")
        if target_browse_var is None or not hasattr(target_browse_var, "set") or not hasattr(target_browse_var, "get"):
            return
        if bool(target_browse_var.get()):
            target_browse_var.set(False)
            self._sync_artifact_filters_with_home_pair_selection(refresh=True)
            self.set_query_result(
                "마지막 조회: browse target 고정을 해제했습니다.",
                context=self._artifact_query_context_summary(),
            )
            return
        if not self._artifact_home_browse_pair_scope_enabled():
            self.__dict__["_artifact_manual_filters_before_browse"] = (
                self.artifact_pair_filter_var.get().strip(),
                self.artifact_target_filter_var.get().strip(),
            )
            browse_var = self.__dict__.get("artifact_home_browse_pair_filter_var")
            if browse_var is not None and hasattr(browse_var, "set"):
                browse_var.set(True)
        target_browse_var.set(True)
        self._sync_artifact_filters_with_home_pair_selection(refresh=True)
        self.set_query_result(
            "마지막 조회: Home Pair와 현재 보고 target 기준으로 결과 필터를 맞췄습니다.",
            context=self._artifact_query_context_summary(),
        )

    def toggle_artifact_home_pair_scope(self) -> None:
        if not self._has_ui_attr("artifact_pair_filter_var"):
            return
        browse_var = self.__dict__.get("artifact_home_browse_pair_filter_var")
        if browse_var is None or not hasattr(browse_var, "set") or not hasattr(browse_var, "get"):
            return
        if bool(browse_var.get()):
            self._disable_artifact_home_browse_pair_scope(restore_saved_filters=True)
            if self._has_ui_attr("artifact_tree"):
                self.refresh_artifacts_tab()
            self.set_query_result(
                "마지막 조회: Home Pair 고정 결과 필터를 해제했습니다.",
                context=self._artifact_query_context_summary(),
            )
            return
        self.__dict__["_artifact_manual_filters_before_browse"] = (
            self.artifact_pair_filter_var.get().strip(),
            self.artifact_target_filter_var.get().strip(),
        )
        browse_var.set(True)
        self._sync_artifact_filters_with_home_pair_selection(refresh=True)
        self.set_query_result(
            "마지막 조회: Home에서 보고 있는 Pair 기준으로 결과 필터를 고정했습니다.",
            context=self._artifact_query_context_summary(),
        )

    def clear_artifact_filters(self) -> None:
        if not self._has_ui_attr("artifact_pair_filter_var"):
            return
        self._disable_artifact_home_browse_pair_scope(restore_saved_filters=False)
        self.artifact_pair_filter_var.set("")
        self.artifact_target_filter_var.set("")
        if self._has_ui_attr("artifact_tree"):
            self.refresh_artifacts_tab()

    def _apply_artifact_tree_highlights(self) -> None:
        tree = self.__dict__.get("artifact_tree")
        if tree is None:
            return
        get_children = getattr(tree, "get_children", None)
        item_method = getattr(tree, "item", None)
        tag_configure_method = getattr(tree, "tag_configure", None)
        if get_children is None or item_method is None:
            return
        action_pair = self._selected_pair_id()
        action_target = self.target_id_var.get().strip()
        inspection_target = self._selected_inspection_target_id()
        browse_pair = self._selected_home_pair_selection() if self._has_ui_attr("home_pair_tree") else ""
        if callable(tag_configure_method):
            try:
                tag_configure_method("artifact_action_pair", background="#DCFCE7", foreground="#111827")
                tag_configure_method("artifact_action_target", background="#DBEAFE", foreground="#111827")
                tag_configure_method("artifact_inspection_target", background="#FEF3C7", foreground="#111827")
                tag_configure_method("artifact_browse_pair", background="#F3E8FF", foreground="#111827")
            except Exception:
                pass
        target_to_pair = {state.target_id: state.pair_id for state in list(self.__dict__.get("artifact_states", []) or [])}
        for item_id in get_children():
            iid = str(item_id)
            tags: list[str] = []
            row_pair = target_to_pair.get(iid, "")
            if iid == action_target:
                tags.append("artifact_action_target")
            elif inspection_target and iid == inspection_target:
                tags.append("artifact_inspection_target")
            elif browse_pair and browse_pair != action_pair and row_pair == browse_pair:
                tags.append("artifact_browse_pair")
            elif action_pair and row_pair == action_pair:
                tags.append("artifact_action_pair")
            try:
                item_method(iid, tags=tuple(tags))
            except Exception:
                pass

    @staticmethod
    def _highlighted_button_text(base_text: str, *, active: bool) -> str:
        text = str(base_text or "").strip()
        if not text:
            return text
        return f"권장: {text}" if active else text

    def _refresh_visible_next_action_highlights(self, visible_state: VisibleAcceptanceState | None = None) -> None:
        state = visible_state
        if state is None:
            try:
                state = self._build_visible_acceptance_state()
            except Exception:
                state = None
        next_action_key = str(getattr(state, "next_action_key", "") or "").strip() if state is not None else ""
        visible_button_specs = {
            "visible_cleanup_dry": ("visible_cleanup_dry_button", "cleanup 미리보기"),
            "visible_cleanup_apply": ("visible_cleanup_apply_button", "cleanup 적용"),
            "visible_preflight": ("visible_preflight_button", "입력 전 점검"),
            "visible_post_cleanup": ("visible_post_cleanup_button", "post-cleanup"),
            "visible_clean_preflight": ("visible_clean_preflight_button", "clean preflight 재확인"),
            "visible_active_acceptance": ("visible_active_acceptance_button", "실제 acceptance 실행"),
            "visible_confirm": ("visible_confirm_button", "shared confirm"),
            "visible_receipt_confirm": ("visible_receipt_confirm_button", "receipt 확인"),
        }
        for action_key, (attr_name, base_text) in visible_button_specs.items():
            button = self.__dict__.get(attr_name)
            if button is None:
                continue
            try:
                button.configure(text=self._highlighted_button_text(base_text, active=(action_key == next_action_key)))
            except Exception:
                pass

    @staticmethod
    def _visible_primitive_button_labels() -> dict[str, str]:
        return {
            "visible_primitive_reuse": "공식 8창 재사용",
            "visible_primitive_visibility": "typed-window 입력 점검",
            "visible_primitive_partner": "상대 target 선택",
            "visible_primitive_preview_refresh": "편집본 preview 갱신",
            "visible_primitive_save": "고정문구 저장 + 새로고침",
            "visible_primitive_export": "선택 target preview 저장",
            "visible_primitive_submit": "선택 target 1회 submit",
            "visible_primitive_publish": "publish 확인",
            "visible_primitive_handoff": "handoff 확인",
        }

    @staticmethod
    def _visible_primitive_button_attr_names() -> dict[str, str]:
        return {
            "visible_primitive_reuse": "visible_primitive_reuse_button",
            "visible_primitive_visibility": "visible_primitive_visibility_button",
            "visible_primitive_partner": "visible_primitive_partner_button",
            "visible_primitive_preview_refresh": "visible_primitive_preview_refresh_button",
            "visible_primitive_save": "visible_primitive_save_button",
            "visible_primitive_export": "visible_primitive_export_button",
            "visible_primitive_submit": "visible_primitive_submit_button",
            "visible_primitive_publish": "visible_primitive_publish_button",
            "visible_primitive_handoff": "visible_primitive_handoff_button",
        }

    @staticmethod
    def _visible_primitive_stage_style(stage_key: str) -> dict[str, str]:
        normalized = str(stage_key or "").strip()
        styles = {
            "config_required": {"background": "#B45309", "foreground": "#FFFFFF"},
            "target_required": {"background": "#B45309", "foreground": "#FFFFFF"},
            "visibility_check": {"background": "#B91C1C", "foreground": "#FFFFFF"},
            "preview_prepare": {"background": "#0F766E", "foreground": "#FFFFFF"},
            "partner_switch": {"background": "#7C3AED", "foreground": "#FFFFFF"},
            "handoff_check": {"background": "#15803D", "foreground": "#FFFFFF"},
            "publish_check": {"background": "#2563EB", "foreground": "#FFFFFF"},
            "submit_once": {"background": "#1D4ED8", "foreground": "#FFFFFF"},
            "partner_review": {"background": "#92400E", "foreground": "#FFFFFF"},
            "scope_blocked": {"background": "#B45309", "foreground": "#FFFFFF"},
            "run_root_prepare": {"background": "#B45309", "foreground": "#FFFFFF"},
            "confirm_root_prepare": {"background": "#B45309", "foreground": "#FFFFFF"},
            "submit_ready": {"background": "#1D4ED8", "foreground": "#FFFFFF"},
            "default": {"background": "#6B7280", "foreground": "#FFFFFF"},
        }
        return dict(styles.get(normalized, styles["default"]))

    def _refresh_visible_primitive_next_action_highlights(self, *, next_action_key: str = "") -> None:
        labels = self._visible_primitive_button_labels()
        button_specs = self._visible_primitive_button_attr_names()
        normalized_next_action = str(next_action_key or "").strip()
        self.__dict__["_visible_primitive_next_action_key"] = normalized_next_action
        for action_key, attr_name in button_specs.items():
            button = self.__dict__.get(attr_name)
            if button is None:
                continue
            try:
                button.configure(
                    text=self._highlighted_button_text(
                        labels.get(action_key, ""),
                        active=(action_key == normalized_next_action),
                    )
                )
            except Exception:
                pass

    def _set_visible_primitive_stage(
        self,
        *,
        badge_text: str,
        detail_text: str,
        action_key: str = "",
        stage_key: str = "",
        background: str = "#6B7280",
        foreground: str = "#FFFFFF",
    ) -> None:
        rendered_detail = str(detail_text or "").strip()
        action_label = self._recommended_action_button_label(str(action_key or "").strip(), "")
        if action_label:
            rendered_detail = " / ".join(part for part in [rendered_detail, f"지금 버튼: {action_label}"] if part)
        badge_var = self.__dict__.get("visible_primitive_stage_badge_var")
        if badge_var is not None and hasattr(badge_var, "set"):
            badge_var.set(str(badge_text or ""))
        detail_var = self.__dict__.get("visible_primitive_stage_detail_var")
        if detail_var is not None and hasattr(detail_var, "set"):
            detail_var.set(rendered_detail)
        action_button_var = self.__dict__.get("visible_primitive_stage_action_button_var")
        if action_button_var is not None and hasattr(action_button_var, "set"):
            action_button_var.set(f"실행: {action_label}" if action_label else "권장 단계 실행")
        action_button = self.__dict__.get("visible_primitive_stage_action_button")
        if action_button is not None:
            action_attr = self._visible_primitive_button_attr_names().get(str(action_key or "").strip(), "")
            action_widget = self.__dict__.get(action_attr) if action_attr else None
            button_state = "disabled"
            if action_key and not bool(getattr(self, "_busy", False)):
                button_state = "normal"
                if action_widget is not None and hasattr(action_widget, "cget"):
                    try:
                        widget_state = str(action_widget.cget("state") or "").strip().lower()
                        if widget_state == "disabled":
                            button_state = "disabled"
                    except Exception:
                        pass
            try:
                action_button.configure(state=button_state)
            except Exception:
                pass
        style = self._visible_primitive_stage_style(stage_key)
        badge_label = self.__dict__.get("visible_primitive_stage_badge_label")
        if badge_label is not None:
            try:
                badge_label.configure(
                    text=str(badge_text or ""),
                    bg=str(style.get("background", background or "#6B7280")),
                    fg=str(style.get("foreground", foreground or "#FFFFFF")),
                )
            except Exception:
                pass

    def run_visible_primitive_stage_action(self) -> None:
        action_key = str(self.__dict__.get("_visible_primitive_next_action_key", "") or "").strip()
        self._run_recommended_action(action_key)

    @staticmethod
    def _normalize_visible_primitive_stage_detail(detail: str, *, category: str = "") -> str:
        text = " ".join(str(detail or "").strip().split())
        if not text:
            return ""
        normalized_category = str(category or "").strip().lower()
        lowered = text.lower()
        if normalized_category == "visibility":
            if "no-visible-window" in lowered:
                return "공식 8창을 찾지 못했습니다. 창 재사용 후 입력 점검을 다시 실행하세요."
            if "submit-unconfirmed" in lowered:
                return "submit 뒤 진행 신호가 확인되지 않았습니다. typed-window 상태와 publish 확인을 다시 보세요."
            if "focus" in lowered and ("stolen" in lowered or "lost" in lowered):
                return "포커스가 유지되지 않았습니다. 대상 창을 다시 전면에 두고 입력 점검을 다시 하세요."
            if "typed-window" in lowered or "inject" in lowered:
                return "typed-window 입력 가능 여부와 submit guard를 먼저 다시 확인하세요."
            return f"입력 점검 차단: {text}"
        if normalized_category == "scope":
            if "partial reuse" in lowered:
                return "현재 세션 재사용 범위 밖 pair입니다. 실행 pair나 창 구성을 다시 맞추세요."
            if "비활성" in text or "disabled" in lowered:
                return "이 pair는 비활성 상태입니다. 홈에서 pair 상태를 먼저 확인하세요."
            if "stale" in lowered:
                return "현재 실행 문맥이 오래된 runroot를 가리킬 수 있습니다. 새 RunRoot를 다시 준비하세요."
            return f"실행 범위 확인: {text}"
        if normalized_category == "run_root":
            if "stale" in lowered:
                return "현재 RunRoot가 오래됐습니다. 새 RunRoot를 준비하거나 override 입력을 비우세요."
            if "없" in text or "필요" in text:
                return "현재 pair 기준 RunRoot를 먼저 준비한 뒤 submit 또는 확인으로 넘어가세요."
            return f"RunRoot 확인: {text}"
        return text

    def _refresh_pair_policy_card_focus_highlights(self) -> None:
        selected_pair = self._selected_pair_id()
        for pair_id, badge_label in self.__dict__.get("pair_policy_card_focus_badge_labels", {}).items():
            if badge_label is None:
                continue
            try:
                if pair_id == selected_pair:
                    badge_label.configure(text="현재 실행 Pair", bg="#1D4ED8", fg="#FFFFFF")
                    badge_label.grid()
                else:
                    badge_label.configure(text="")
                    badge_label.grid_remove()
            except Exception:
                pass

    def _apply_home_pair_tree_highlights(self) -> None:
        tree = self.__dict__.get("home_pair_tree")
        if tree is None:
            return
        self._update_artifact_home_browse_toggle_label()
        get_children = getattr(tree, "get_children", None)
        item_method = getattr(tree, "item", None)
        tag_configure_method = getattr(tree, "tag_configure", None)
        if get_children is None or item_method is None:
            return
        action_pair = self._selected_pair_id()
        browse_pair = self._selected_home_pair_selection() if self._has_ui_attr("home_pair_tree") else ""
        if callable(tag_configure_method):
            try:
                tag_configure_method("home_action_pair", background="#DBEAFE", foreground="#111827")
                tag_configure_method("home_browse_pair", background="#F3E8FF", foreground="#111827")
            except Exception:
                pass
        for item_id in get_children():
            iid = str(item_id)
            tags: list[str] = []
            if action_pair and iid == action_pair:
                tags.append("home_action_pair")
            elif browse_pair and iid == browse_pair:
                tags.append("home_browse_pair")
            try:
                item_method(iid, tags=tuple(tags))
            except Exception:
                pass

    def _seed_kickoff_start_steps_text(
        self,
        *,
        pair_id: str,
        target_id: str,
        repo_source: str,
        route_badge: str,
        source_summary_path: str,
        source_review_zip_path: str,
        publish_ready_path: str,
        publish_helper_command: str,
    ) -> str:
        return "\n".join(
            [
                "[권장 시작 순서]",
                f"1. pair={pair_id} / target={target_id} 설정을 저장하고 repo-source={repo_source or 'unset'} / route={route_badge or '(미확인)'} 상태를 확인합니다.",
                "2. '실효값' 또는 '미리보기'로 현재 repo/runroot/source-outbox 경로가 기대값과 일치하는지 확인합니다.",
                "3. '초간단 시작문 복사'로 전체 문구를 복사해 대상 PowerShell/셀 창에 직접 붙여넣습니다.",
                "4. 대상은 아래 2파일을 같은 run 계약 경로에 생성해야 합니다.",
                f"   - summary.txt: {source_summary_path or '(없음)'}",
                f"   - review.zip: {source_review_zip_path or '(없음)'}",
                f"5. 마지막에는 publish helper만 실행합니다: {publish_helper_command or '(없음)'}",
                f"   - helper output marker: {publish_ready_path or '(없음)'}",
                "6. 순서는 summary.txt -> review.zip -> publish helper 입니다.",
                "7. helper가 marker를 생성하면 watcher가 다음 단계부터 자동으로 handoff를 진행합니다.",
            ]
        )

    def _seed_kickoff_preview_payload(self) -> dict[str, object]:
        config_path = self.config_path_var.get().strip()
        if not config_path:
            raise ValueError("ConfigPath를 먼저 확인하세요.")
        document = self.message_config_service.load_config_document(config_path)
        known_pair_ids = self._seed_kickoff_known_pair_ids(document)
        if not known_pair_ids:
            raise ValueError("구성된 pair가 없어 초기 실행 준비를 만들 수 없습니다.")
        for current_pair_id in known_pair_ids:
            self._apply_pair_policy_card_values_to_document(document, current_pair_id)

        requested_pair_id = str(self.seed_kickoff_pair_var.get() or "").strip()
        pair_id = requested_pair_id if requested_pair_id in known_pair_ids else (self._selected_pair_id() if self._selected_pair_id() in known_pair_ids else known_pair_ids[0])
        policy = self.message_config_service.effective_pair_policy(document, pair_id)
        allowed_target_ids = self._seed_kickoff_target_ids(document, pair_id)
        requested_target_id = str(self.seed_kickoff_target_var.get() or "").strip()
        default_target_id = str(policy.get("DefaultSeedTargetId", "") or "").strip()
        target_id = requested_target_id if requested_target_id in allowed_target_ids else (default_target_id if default_target_id in allowed_target_ids else (allowed_target_ids[0] if allowed_target_ids else ""))
        if not target_id:
            raise ValueError(f"{pair_id}의 seed target을 결정하지 못했습니다.")

        payload = self._render_pair_policy_effective_preview(
            document=document,
            config_path=config_path,
            pair_id=pair_id,
            target_id=target_id,
            mode="initial",
        )
        preview_rows = [
            row
            for row in list(payload.get("PreviewRows", []) or [])
            if str(row.get("PairId", "") or "").strip() == pair_id
        ]
        if not preview_rows:
            raise ValueError(f"{pair_id} preview row를 찾지 못했습니다.")
        row = next(
            (
                item
                for item in preview_rows
                if str(item.get("TargetId", "") or "").strip() == target_id
            ),
            preview_rows[0],
        )
        target_id = str(row.get("TargetId", "") or target_id).strip()
        role_name = str(row.get("RoleName", "") or self._seed_kickoff_role_for_target(document, pair_id, target_id)).strip()
        work_repo_root = str(policy.get("DefaultSeedWorkRepoRoot", "") or row.get("WorkRepoRoot", "") or "").strip()
        route_snapshot = self._pair_policy_card_preview_route_snapshot(
            rows=preview_rows,
            pair_id=pair_id,
            pair_work_repo_root=work_repo_root,
            policy=policy,
        )
        route_badge = self._pair_policy_route_badge_spec(
            route_snapshot=route_snapshot,
            pair_work_repo_root=work_repo_root,
        )["text"]
        pair_target_folder = str(
            row.get("OwnTargetFolder", "")
            or row.get("PairTargetFolder", "")
            or ""
        ).strip()
        resolved_output_paths = self._seed_kickoff_resolved_output_paths(row)
        source_summary_path = str(resolved_output_paths.get("SourceSummaryPath", "") or "").strip()
        source_review_zip_path = str(resolved_output_paths.get("SourceReviewZipPath", "") or "").strip()
        publish_ready_path = str(resolved_output_paths.get("PublishReadyPath", "") or "").strip()
        publish_script_path = str(row.get("PublishScriptPath", "") or (str(Path(pair_target_folder) / self._pair_test_file_name("PublishScriptFileName", "publish-artifact.ps1")) if pair_target_folder else "")).strip()
        publish_cmd_path = str(row.get("PublishCmdPath", "") or (str(Path(pair_target_folder) / self._pair_test_file_name("PublishCmdFileName", "publish-artifact.cmd")) if pair_target_folder else "")).strip()
        helper_commands = self._seed_kickoff_publish_helper_commands(
            publish_cmd_path=publish_cmd_path,
            publish_script_path=publish_script_path,
        )
        publish_helper_command = str(helper_commands.get("PreferredCommand", "") or "").strip()
        publish_script_command = str(helper_commands.get("ScriptCommand", "") or "").strip()
        review_input_path = str(self.seed_kickoff_review_input_var.get() or "").strip()
        task_text = self._seed_kickoff_task_text_value()
        queue_text = self._seed_kickoff_queue_text(task_text=task_text, review_input_path=review_input_path)
        contract_text = self._seed_kickoff_contract_block(
            pair_id=pair_id,
            target_id=target_id,
            role_name=role_name,
            work_repo_root=work_repo_root,
            next_run_root_preview=str(((payload.get("RunContext", {}) or {}).get("NextRunRootPreview", "") or "")).strip(),
            pair_run_root=str(row.get("PairRunRoot", "") or "").strip(),
            pair_target_folder=pair_target_folder,
            source_summary_path=source_summary_path,
            source_review_zip_path=source_review_zip_path,
            publish_ready_path=publish_ready_path,
            publish_helper_command=publish_helper_command,
            review_input_path=review_input_path,
        )
        helper_text = self._seed_kickoff_helper_block(
            publish_ready_path=publish_ready_path,
            publish_helper_command=publish_helper_command,
            publish_script_command=publish_script_command,
            publish_cmd_path=publish_cmd_path,
            publish_script_path=publish_script_path,
        )
        full_preview_text = self._seed_kickoff_full_preview_text(
            queue_text=queue_text,
            contract_text=contract_text,
            helper_text=helper_text,
            repo_source=str(policy.get("DefaultSeedWorkRepoRootSource", "") or "unset"),
            route_badge=route_badge,
        )
        manual_start_text = self._seed_kickoff_manual_start_text(
            task_text=task_text,
            review_input_path=review_input_path,
            source_summary_path=source_summary_path,
            source_review_zip_path=source_review_zip_path,
            publish_ready_path=publish_ready_path,
            publish_helper_command=publish_helper_command,
        )
        detailed_start_text = self._seed_kickoff_detailed_start_text(
            task_text=task_text,
            review_input_path=review_input_path,
            source_summary_path=source_summary_path,
            source_review_zip_path=source_review_zip_path,
            publish_ready_path=publish_ready_path,
            publish_helper_command=publish_helper_command,
            publish_script_command=publish_script_command,
            publish_cmd_path=publish_cmd_path,
            publish_script_path=publish_script_path,
        )
        start_steps_text = self._seed_kickoff_start_steps_text(
            pair_id=pair_id,
            target_id=target_id,
            repo_source=str(policy.get("DefaultSeedWorkRepoRootSource", "") or "unset"),
            route_badge=route_badge,
            source_summary_path=source_summary_path,
            source_review_zip_path=source_review_zip_path,
            publish_ready_path=publish_ready_path,
            publish_helper_command=publish_helper_command,
        )
        return {
            "ConfigPath": config_path,
            "PairId": pair_id,
            "TargetId": target_id,
            "RoleName": role_name,
            "Policy": policy,
            "RouteSnapshot": route_snapshot,
            "RouteBadge": route_badge,
            "PreviewPayload": payload,
            "PreviewRow": row,
            "ResolvedOutputPaths": resolved_output_paths,
            "ReviewInputPath": review_input_path,
            "QueueText": queue_text,
            "ContractText": contract_text,
            "HelperText": helper_text,
            "StartStepsText": start_steps_text,
            "FullPreviewText": full_preview_text,
            "ManualStartText": manual_start_text,
            "DetailedStartText": detailed_start_text,
            "PublishHelperCommand": publish_helper_command,
            "PublishHelperScriptCommand": publish_script_command,
            "Warnings": [str(item) for item in list(payload.get("Warnings", []) or [])],
        }

    def refresh_seed_kickoff_composer(self) -> None:
        document = self.message_config_doc or {}
        known_pair_ids = self._seed_kickoff_known_pair_ids(document)
        if not known_pair_ids:
            pair_combo = getattr(self, "seed_kickoff_pair_combo", None)
            if pair_combo is not None:
                pair_combo.configure(values=[], state="disabled")
            target_combo = getattr(self, "seed_kickoff_target_combo", None)
            if target_combo is not None:
                target_combo.configure(values=[], state="disabled")
            self.seed_kickoff_status_var.set("초기 실행 준비: 구성된 pair가 없어 사용할 수 없습니다.")
            self.seed_kickoff_target_banner_var.set("붙여넣기 대상: (미확인)")
            self.seed_kickoff_readiness_var.set("차단: 구성된 pair 없음")
            self.seed_kickoff_last_preview = None
            return
        current_pair_id = str(self.seed_kickoff_pair_var.get() or "").strip()
        if current_pair_id not in known_pair_ids:
            current_pair_id = self._selected_pair_id() if self._selected_pair_id() in known_pair_ids else known_pair_ids[0]
            self.seed_kickoff_pair_var.set(current_pair_id)
        pair_target_ids = self._seed_kickoff_target_ids(document, current_pair_id)
        effective_policy = self.message_config_service.effective_pair_policy(document, current_pair_id)
        current_target_id = str(self.seed_kickoff_target_var.get() or "").strip()
        if current_target_id not in pair_target_ids:
            current_target_id = str(effective_policy.get("DefaultSeedTargetId", "") or "").strip()
            if current_target_id not in pair_target_ids:
                current_target_id = pair_target_ids[0] if pair_target_ids else ""
            self.seed_kickoff_target_var.set(current_target_id)
        pair_combo = getattr(self, "seed_kickoff_pair_combo", None)
        if pair_combo is not None:
            pair_combo.configure(values=known_pair_ids, state="readonly" if known_pair_ids else "disabled")
        target_combo = getattr(self, "seed_kickoff_target_combo", None)
        if target_combo is not None:
            target_combo.configure(values=pair_target_ids, state="readonly" if pair_target_ids else "disabled")
        store = self._pair_policy_card_store(current_pair_id)
        self.seed_kickoff_status_var.set(
            "초기 실행 준비: pair={pair} / target={target} / repo-source={repo_source} / route={route} / 수동 복붙 또는 queue 시작 가능".format(
                pair=current_pair_id,
                target=current_target_id or "(없음)",
                repo_source=str(store["repo_source_badge_var"].get() or "REPO 미확인"),
                route=str(store["route_badge_var"].get() or "ROUTE 미확인"),
            )
        )
        self.seed_kickoff_target_banner_var.set(
            self._seed_kickoff_target_banner_text(pair_id=current_pair_id, target_id=current_target_id)
        )
        self.seed_kickoff_readiness_var.set(self._seed_kickoff_readiness_text())
        self._apply_seed_kickoff_detail_visibility()

    def browse_seed_kickoff_review_input(self) -> None:
        initialdir = str(ROOT / "reviewfile")
        selected = filedialog.askopenfilename(
            title="초기 실행 입력 파일 선택",
            initialdir=initialdir,
            filetypes=[("All files", "*.*")],
        )
        if not selected:
            return
        self.seed_kickoff_review_input_var.set(selected)
        self.seed_kickoff_status_var.set(f"초기 실행 입력 파일 선택: {selected}")

    def open_seed_kickoff_review_input(self) -> None:
        path_value = str(self.seed_kickoff_review_input_var.get() or "").strip()
        if not path_value:
            messagebox.showwarning("입력 파일 없음", "먼저 입력 파일을 선택하세요.")
            return
        self._open_path(path_value, kind="초기 실행 입력 파일")

    def preview_seed_kickoff_message(self) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("초기 실행 미리보기 실패", str(exc))
            self.seed_kickoff_status_var.set(f"초기 실행 미리보기 실패: {exc}")
            return
        self.seed_kickoff_last_preview = payload
        contract_widget = getattr(self, "seed_kickoff_contract_text", None)
        helper_widget = getattr(self, "seed_kickoff_helper_text", None)
        steps_widget = getattr(self, "seed_kickoff_steps_text", None)
        simple_widget = getattr(self, "seed_kickoff_simple_text", None)
        preview_widget = getattr(self, "seed_kickoff_preview_text", None)
        if contract_widget is not None:
            self.set_text(contract_widget, str(payload.get("ContractText", "") or ""))
        if helper_widget is not None:
            self.set_text(helper_widget, str(payload.get("HelperText", "") or ""))
        if steps_widget is not None:
            self.set_text(steps_widget, str(payload.get("StartStepsText", "") or ""))
        if simple_widget is not None:
            self.set_text(simple_widget, str(payload.get("ManualStartText", "") or ""))
        if preview_widget is not None:
            self.set_text(preview_widget, str(payload.get("FullPreviewText", "") or ""))
        policy = dict(payload.get("Policy", {}) or {})
        self.seed_kickoff_target_banner_var.set(
            self._seed_kickoff_target_banner_text(
                pair_id=str(payload.get("PairId", "") or ""),
                target_id=str(payload.get("TargetId", "") or ""),
            )
        )
        self.seed_kickoff_readiness_var.set(self._seed_kickoff_readiness_text(payload))
        self.seed_kickoff_status_var.set(
            "{pair} 초기 실행 미리보기 갱신 / target={target} / repo-source={repo_source} / route={route} / warnings={warnings}".format(
                pair=payload.get("PairId", ""),
                target=payload.get("TargetId", ""),
                repo_source=policy.get("DefaultSeedWorkRepoRootSource", "") or "unset",
                route=payload.get("RouteBadge", "") or "(미확인)",
                warnings=len(list(payload.get("Warnings", []) or [])),
            )
        )
        self._apply_seed_kickoff_detail_visibility()

    def copy_seed_kickoff_full_text(self) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("복사 실패", str(exc))
            return
        self.seed_kickoff_last_preview = payload
        self._copy_to_clipboard(str(payload.get("ManualStartText", "") or ""))
        self.seed_kickoff_target_banner_var.set(
            self._seed_kickoff_target_banner_text(
                pair_id=str(payload.get("PairId", "") or ""),
                target_id=str(payload.get("TargetId", "") or ""),
            )
        )
        self.seed_kickoff_readiness_var.set(self._seed_kickoff_readiness_text(payload))
        self.seed_kickoff_status_var.set("초간단 시작문을 클립보드로 복사했습니다. 대상 PowerShell/셀 창에 직접 붙여넣으세요.")
        pair_id = str(payload.get("PairId", "") or "").strip() or "(pair 없음)"
        target_id = str(payload.get("TargetId", "") or "").strip() or "(target 없음)"
        self.set_text(
            self.output_text,
            "\n".join(
                [
                    "초간단 시작문 복사 완료",
                    f"대상: {pair_id} / {target_id} 실제 셀 창",
                    "다음: 해당 창에 붙여넣고 summary.txt -> review.zip -> publish helper 실행 순서로 진행하세요.",
                ]
            ),
        )

    def copy_seed_kickoff_detailed_text(self) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("복사 실패", str(exc))
            return
        self.seed_kickoff_last_preview = payload
        self._copy_to_clipboard(str(payload.get("DetailedStartText", "") or ""))
        pair_id = str(payload.get("PairId", "") or "").strip() or "(pair 없음)"
        target_id = str(payload.get("TargetId", "") or "").strip() or "(target 없음)"
        self.seed_kickoff_target_banner_var.set(
            self._seed_kickoff_target_banner_text(
                pair_id=pair_id,
                target_id=target_id,
            )
        )
        self.seed_kickoff_readiness_var.set(self._seed_kickoff_readiness_text(payload))
        self.seed_kickoff_status_var.set("상세 시작문을 클립보드로 복사했습니다. 필요한 경우에만 상세형을 사용하세요.")
        self.set_text(
            self.output_text,
            "\n".join(
                [
                    "상세 시작문 복사 완료",
                    f"대상: {pair_id} / {target_id} 실제 셀 창",
                    "다음: 상세 설명이 필요할 때만 이 문구를 붙여넣으세요.",
                ]
            ),
        )

    def copy_seed_kickoff_path_block(self) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("복사 실패", str(exc))
            return
        self.seed_kickoff_last_preview = payload
        self._copy_to_clipboard(str(payload.get("ContractText", "") or ""))
        self.seed_kickoff_status_var.set("초기 실행 경로/계약 블록을 클립보드로 복사했습니다.")
        self.set_text(self.output_text, "초기 실행 경로/계약 블록 복사 완료:\n\n" + str(payload.get("ContractText", "") or ""))

    def _copy_seed_kickoff_single_path(self, field_name: str, label: str) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("복사 실패", str(exc))
            return
        self.seed_kickoff_last_preview = payload
        resolved_paths = dict(payload.get("ResolvedOutputPaths", {}) or {})
        path_value = str(resolved_paths.get(field_name, "") or "").strip()
        if not path_value:
            messagebox.showwarning("복사 실패", f"{label} 경로를 계산하지 못했습니다.")
            return
        self._copy_to_clipboard(path_value)
        self.seed_kickoff_status_var.set(f"{label} 경로를 클립보드로 복사했습니다.")
        self.set_text(self.output_text, f"{label} 경로 복사 완료:\n{path_value}")

    def copy_seed_kickoff_summary_path(self) -> None:
        self._copy_seed_kickoff_single_path("SourceSummaryPath", "summary.txt")

    def copy_seed_kickoff_review_zip_path(self) -> None:
        self._copy_seed_kickoff_single_path("SourceReviewZipPath", "review.zip")

    def copy_seed_kickoff_publish_ready_path(self) -> None:
        self._copy_seed_kickoff_single_path("PublishReadyPath", "publish.ready.json")

    def copy_seed_kickoff_publish_helper_command(self) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("복사 실패", str(exc))
            return
        self.seed_kickoff_last_preview = payload
        command_value = str(payload.get("PublishHelperCommand", "") or "").strip()
        if not command_value:
            messagebox.showwarning("복사 실패", "publish helper 명령을 계산하지 못했습니다.")
            return
        self._copy_to_clipboard(command_value)
        self.seed_kickoff_status_var.set("publish helper 명령을 클립보드로 복사했습니다.")
        self.set_text(self.output_text, f"publish helper 명령 복사 완료:\n{command_value}")

    def copy_seed_kickoff_start_steps(self) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("복사 실패", str(exc))
            return
        self.seed_kickoff_last_preview = payload
        self._copy_to_clipboard(str(payload.get("StartStepsText", "") or ""))
        self.seed_kickoff_status_var.set("초기 실행 시작 순서를 클립보드로 복사했습니다.")
        self.set_text(self.output_text, "초기 실행 시작 순서 복사 완료:\n\n" + str(payload.get("StartStepsText", "") or ""))

    def copy_seed_kickoff_helper_block(self) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("복사 실패", str(exc))
            return
        self.seed_kickoff_last_preview = payload
        self._copy_to_clipboard(str(payload.get("HelperText", "") or ""))
        self.seed_kickoff_status_var.set("초기 실행 helper 블록을 클립보드로 복사했습니다.")
        self.set_text(self.output_text, "초기 실행 helper 블록 복사 완료:\n\n" + str(payload.get("HelperText", "") or ""))

    def _seed_kickoff_enqueue_allowed(self, payload: dict[str, object]) -> tuple[bool, str]:
        pair_id = str(payload.get("PairId", "") or "").strip()
        route_badge = str(payload.get("RouteBadge", "") or "").strip()
        resolved_paths = dict(payload.get("ResolvedOutputPaths", {}) or {})
        if self._message_editor_has_unsaved_changes():
            return False, "Initial/Handoff 문구 편집에 미저장 변경이 있습니다. 먼저 저장하거나 취소하세요."
        if not pair_id or not self._pair_policy_card_matches_loaded_policy(pair_id):
            return False, "현재 pair 카드에 미저장 설정이 있습니다. 먼저 'pair 설정 저장 + 새로고침'을 완료하세요."
        if route_badge not in {"ROUTE OK", "SHARED REPO OK"}:
            return False, f"{pair_id} route 상태가 아직 안전하지 않습니다. 현재 배지: {route_badge or '(미확인)'}"
        required_paths = [
            str(resolved_paths.get("SourceSummaryPath", "") or "").strip(),
            str(resolved_paths.get("SourceReviewZipPath", "") or "").strip(),
            str(resolved_paths.get("PublishReadyPath", "") or "").strip(),
        ]
        if any(not item for item in required_paths):
            return False, "summary/review/publish 경로를 아직 확인하지 못했습니다. 먼저 '실효값' 또는 초기 실행 미리보기를 다시 확인하세요."
        if not str(payload.get("QueueText", "") or "").strip():
            return False, "작업 설명 또는 입력 파일 경로가 비어 있습니다."
        return True, ""

    def enqueue_seed_kickoff_message(self) -> None:
        try:
            payload = self._seed_kickoff_preview_payload()
        except Exception as exc:
            messagebox.showwarning("초기 입력 큐잉 실패", str(exc))
            self.seed_kickoff_status_var.set(f"초기 입력 큐잉 실패: {exc}")
            return
        allowed, detail = self._seed_kickoff_enqueue_allowed(payload)
        if not allowed:
            messagebox.showwarning("초기 입력 큐잉 차단", detail)
            self.seed_kickoff_status_var.set(f"초기 입력 큐잉 차단: {detail}")
            return
        pair_id = str(payload.get("PairId", "") or "").strip()
        target_id = str(payload.get("TargetId", "") or "").strip()
        role_name = str(payload.get("RoleName", "") or "").strip()
        applies_to = str(self.seed_kickoff_applies_to_var.get() or "initial").strip() or "initial"
        placement = str(self.seed_kickoff_placement_var.get() or "one-time-prefix").strip() or "one-time-prefix"
        command = self.command_service.build_powershell_file_command(
            str(ROOT / "tests" / "Enqueue-OneTimeMessage.ps1"),
            extra=[
                "-ConfigPath",
                self.config_path_var.get().strip(),
                "-PairId",
                pair_id,
                "-TargetId",
                target_id,
                "-Role",
                role_name,
                "-AppliesTo",
                applies_to,
                "-Placement",
                placement,
                "-Text",
                str(payload.get("QueueText", "") or ""),
                "-AsJson",
            ],
        )
        try:
            result = self.command_service.run_json(command)
        except Exception as exc:
            messagebox.showerror("초기 입력 큐잉 실패", str(exc))
            self.seed_kickoff_status_var.set(f"초기 입력 큐잉 실패: {exc}")
            return
        self.seed_kickoff_last_preview = payload
        queue_path = str(result.get("QueuePath", "") or "").strip()
        item_id = str(((result.get("Item", {}) or {}).get("Id", "")) or "").strip()
        self.seed_kickoff_status_var.set(
            "{pair}/{target} 초기 입력 queue 등록 완료 / applies-to={applies_to} / placement={placement}".format(
                pair=pair_id,
                target=target_id,
                applies_to=applies_to,
                placement=placement,
            )
        )
        self.set_text(
            self.output_text,
            "초기 입력 큐잉 완료\n"
            f"pair={pair_id}\n"
            f"target={target_id}\n"
            f"role={role_name or '(none)'}\n"
            f"queue={queue_path or '(none)'}\n"
            f"item={item_id or '(none)'}\n\n"
            + str(payload.get("QueueText", "") or ""),
        )
        messagebox.showinfo("초기 입력 큐잉 완료", queue_path or item_id or f"{pair_id}/{target_id}")

    def _reset_message_preview_cache(self, status_message: str, *, bump_revision: bool = True, dirty: bool = True) -> None:
        if bump_revision:
            self.message_document_version += 1
        self.message_editor_dirty = dirty
        self.message_preview_payload = None
        self.message_preview_doc_version = -1
        self.message_preview_cached_context_key = ""
        self.message_preview_status_var.set(status_message)

    def _draft_message_preview_run_root(self) -> str:
        run_context = (self.effective_data or {}).get("RunContext", {}) or {}
        preview_run_root = str(run_context.get("NextRunRootPreview", "") or "")
        if preview_run_root:
            return preview_run_root
        current_run_root = self._current_run_root_for_actions()
        if current_run_root:
            return current_run_root + "_editor_preview"
        return str(ROOT / "_tmp" / "message-editor-preview")

    def _message_preview_context(self) -> tuple[str, str, str]:
        row = self._editor_context_row()
        pair_id = str((row or {}).get("PairId", "") or self._selected_pair_id() or "")
        target_id = str((row or {}).get("TargetId", "") or self.target_id_var.get().strip() or "")
        if not target_id and pair_id:
            target_id = self.pair_controller.resolve_top_target_for_pair(self.preview_rows, pair_id)
        return self._draft_message_preview_run_root(), pair_id, target_id

    def _message_preview_context_signature(self) -> str:
        run_root, pair_id, target_id = self._message_preview_context()
        return "|".join([run_root, pair_id, target_id])

    def _message_preview_row_from_payload(self, payload: dict | None) -> dict | None:
        if not payload:
            return None
        _run_root, pair_id, target_id = self._message_preview_context()
        rows = list(payload.get("PreviewRows", []) or [])
        if target_id:
            for row in rows:
                if str(row.get("TargetId", "") or "") == target_id:
                    return row
        if pair_id:
            for row in rows:
                if str(row.get("PairId", "") or "") == pair_id and str(row.get("RoleName", "") or "") == "top":
                    return row
            for row in rows:
                if str(row.get("PairId", "") or "") == pair_id:
                    return row
        return rows[0] if rows else None

    def _message_preview_banner(self, source_kind: str) -> str:
        if source_kind == "draft":
            warning_count = len((self.message_preview_payload or {}).get("Warnings", []) or [])
            return "[preview source] 편집본 임시 preview{0}".format(
                "" if warning_count == 0 else f" / warnings={warning_count}"
            )
        if not self.message_editor_dirty:
            return "[preview source] 저장된 effective config 기준 preview"
        return "[preview source] 저장된 effective config 기준 preview / 편집본 변경 후 '미리보기 갱신' 필요"

    def _editor_preview_row_and_source(self) -> tuple[dict | None, str, dict]:
        current_signature = self._message_preview_context_signature()
        if (
            self.message_preview_payload
            and self.message_preview_doc_version == self.message_document_version
            and self.message_preview_cached_context_key == current_signature
        ):
            row = self._message_preview_row_from_payload(self.message_preview_payload)
            if row is not None:
                return row, "draft", self.message_preview_payload
        row = self._editor_context_row()
        return row, "saved", self.effective_data or {}

    def _message_preview_warning_text(self, payload: dict | None) -> str:
        warnings = list((payload or {}).get("Warnings", []) or [])
        return "; ".join(str(item) for item in warnings[:3]) if warnings else "(없음)"

    def _message_editor_has_unsaved_changes(self) -> bool:
        if not self.message_config_doc or not self.message_config_original:
            return False
        return (
            self.message_config_service.snapshot_text(self.message_config_doc)
            != self.message_config_service.snapshot_text(self.message_config_original)
        )

    def _message_preview_is_fresh(self) -> bool:
        if not self._message_editor_has_unsaved_changes():
            return True
        return bool(
            self.message_preview_payload
            and self.message_preview_doc_version == self.message_document_version
            and self.message_preview_cached_context_key == self._message_preview_context_signature()
        )

    def _message_editor_save_allowed(self) -> tuple[bool, str]:
        if not self.message_config_doc:
            return False, "설정 문서를 먼저 불러오세요."
        if self._message_editor_has_unsaved_changes() and not self._message_preview_is_fresh():
            return False, "편집본 preview가 stale입니다. '미리보기 갱신' 후 저장하세요."
        return True, ""

    def _refresh_message_editor_action_buttons(self) -> None:
        if not self._has_ui_attr("message_save_button"):
            return
        save_allowed, _detail = self._message_editor_save_allowed()
        self.message_save_button.configure(state="normal" if save_allowed else "disabled")

    def _message_impact_summary(self) -> dict[str, object]:
        document = self.message_config_doc or {}
        original_document = self.message_config_original or document
        change_entries = self.message_config_service.collect_change_entries(original_document, document)
        preview_rows = list(self.preview_rows)
        all_pairs = sorted({str(row.get("PairId", "") or "") for row in preview_rows if str(row.get("PairId", "") or "")}) or self.message_config_service.pair_ids(document)
        all_targets = sorted({str(row.get("TargetId", "") or "") for row in preview_rows if str(row.get("TargetId", "") or "")}) or self.message_config_service.target_ids(document)
        pair_to_targets: dict[str, set[str]] = {}
        role_to_targets: dict[str, set[str]] = {}
        target_to_pair: dict[str, str] = {}
        for row in preview_rows:
            pair_id = str(row.get("PairId", "") or "")
            role_name = str(row.get("RoleName", "") or "")
            target_id = str(row.get("TargetId", "") or "")
            if pair_id and target_id:
                pair_to_targets.setdefault(pair_id, set()).add(target_id)
                target_to_pair[target_id] = pair_id
            if role_name and target_id:
                role_to_targets.setdefault(role_name, set()).add(target_id)

        affected_pairs: set[str] = set()
        affected_targets: set[str] = set()
        change_labels: list[str] = []
        changed_templates: set[str] = set()
        global_change = False

        for entry in change_entries:
            label = str(entry.get("label", "") or "")
            if label:
                change_labels.append(label)
            template_name = str(entry.get("template_name", "") or "")
            if template_name:
                changed_templates.add(template_name)
            change_type = str(entry.get("change_type", "") or "")
            scope_kind = str(entry.get("scope_kind", "") or "")
            scope_id = str(entry.get("scope_id", "") or "")

            if change_type in {"slot_order", "default_fixed_suffix"} or scope_kind in {"global-prefix", "global-suffix"}:
                global_change = True
                continue
            if scope_kind == "pair-extra" and scope_id:
                affected_pairs.add(scope_id)
                affected_targets.update(pair_to_targets.get(scope_id, set()))
                continue
            if scope_kind == "role-extra" and scope_id:
                affected_targets.update(role_to_targets.get(scope_id, set()) or set(all_targets))
                continue
            if scope_kind in {"target-extra", "target-fixed-suffix"} and scope_id:
                affected_targets.add(scope_id)
                pair_id = target_to_pair.get(scope_id, "")
                if pair_id:
                    affected_pairs.add(pair_id)

        if global_change:
            affected_pairs.update(all_pairs)
            affected_targets.update(all_targets)

        if not affected_targets and any(entry.get("scope_kind") == "role-extra" for entry in change_entries):
            affected_targets.update(all_targets)
        if not affected_pairs and affected_targets:
            for target_id in affected_targets:
                pair_id = target_to_pair.get(target_id, "")
                if pair_id:
                    affected_pairs.add(pair_id)

        run_root, pair_id, target_id = self._message_preview_context()
        return {
            "entries": change_entries,
            "changed_templates": sorted(changed_templates),
            "change_labels": change_labels,
            "affected_pairs": sorted(item for item in affected_pairs if item),
            "affected_targets": sorted(item for item in affected_targets if item),
            "preview_is_fresh": self._message_preview_is_fresh(),
            "preview_context": {
                "run_root": run_root,
                "pair_id": pair_id,
                "target_id": target_id,
            },
        }

    def _message_impact_summary_text(self, impact: dict[str, object] | None = None) -> str:
        summary = impact or self._message_impact_summary()
        entries = list(summary.get("entries", []) or [])
        templates = list(summary.get("changed_templates", []) or [])
        affected_pairs = list(summary.get("affected_pairs", []) or [])
        affected_targets = list(summary.get("affected_targets", []) or [])
        preview_context = dict(summary.get("preview_context", {}) or {})
        freshness = "최신" if summary.get("preview_is_fresh") else "stale"
        lines = [
            "저장 영향 요약",
            f"- 변경 항목 수: {len(entries)}",
            f"- 영향 메시지 종류: {', '.join(templates) or '(없음)'}",
            f"- 영향 pair 수: {len(affected_pairs)}",
            f"- 영향 target 수: {len(affected_targets)}",
            f"- preview freshness: {freshness}",
            f"- preview 문맥: pair={preview_context.get('pair_id', '') or '(없음)'} / target={preview_context.get('target_id', '') or '(없음)'} / run={Path(str(preview_context.get('run_root', '') or '')).name or preview_context.get('run_root', '') or '(없음)'}",
            "",
            "변경 항목:",
        ]
        labels = list(summary.get("change_labels", []) or [])
        if labels:
            lines.extend(f"- {label}" for label in labels[:10])
            if len(labels) > 10:
                lines.append(f"- ... 외 {len(labels) - 10}건")
        else:
            lines.append("- (없음)")
        return "\n".join(lines)

    def _editor_plan_text(self) -> str:
        row, source_kind, payload = self._editor_preview_row_and_source()
        if not row:
            return "(선택된 pair/target preview 없음)"
        initial_payload = row.get("Initial", {}) or {}
        handoff_payload = row.get("Handoff", {}) or {}
        lines = [
            self._message_preview_banner(source_kind),
            f"GeneratedAt: {payload.get('GeneratedAt', '') or '(없음)'}",
            f"Warnings: {self._message_preview_warning_text(payload)}",
            "",
            "[Initial]",
            "AppliedSources: " + (", ".join(initial_payload.get("AppliedSources", [])) or "(없음)"),
            self.format_message_plan(initial_payload.get("MessagePlan")),
            "",
            "[Handoff]",
            "AppliedSources: " + (", ".join(handoff_payload.get("AppliedSources", [])) or "(없음)"),
            self.format_message_plan(handoff_payload.get("MessagePlan")),
        ]
        return "\n".join(lines)

    def _message_scope_kind(self) -> str:
        return MESSAGE_SCOPE_LABEL_TO_KIND.get(self.message_scope_label_var.get().strip(), "global-prefix")

    def _message_slot_key_for_scope(self) -> str:
        scope_kind = self._message_scope_kind()
        return scope_kind if scope_kind in MESSAGE_SCOPE_KIND_TO_LABEL else "global-prefix"

    def _selected_message_slot_key(self, slot_order: list[str] | None = None) -> str | None:
        order = list(slot_order or [])
        if not order:
            if self.message_config_doc:
                template_name = self.message_template_var.get().strip() or "Initial"
                order = self.message_config_service.get_slot_order(self.message_config_doc, template_name)
            else:
                order = list(DEFAULT_SLOT_ORDER)
        preferred = str(self.message_selected_slot_key or "").strip()
        if preferred in order:
            return preferred
        if self._has_ui_attr("message_slot_order_list"):
            selection = self.message_slot_order_list.curselection()
            if selection:
                selected_index = int(selection[0])
                if 0 <= selected_index < len(order):
                    return order[selected_index]
        scope_slot = self._message_slot_key_for_scope()
        if scope_slot in order:
            return scope_slot
        return order[0] if order else None

    def _message_slot_editor_context(self, slot_key: str | None = None) -> tuple[bool, str, str, str]:
        resolved_slot = str(slot_key or self.message_selected_slot_key or self._message_slot_key_for_scope()).strip() or "global-prefix"
        if resolved_slot in {"global-prefix", "global-suffix"}:
            return True, resolved_slot, "", ""
        if resolved_slot not in MESSAGE_EDITABLE_SCOPE_KINDS:
            return False, resolved_slot, "", MESSAGE_SCOPE_HELP_TEXT.get(resolved_slot, f"{resolved_slot} 슬롯은 여기서 직접 편집하지 않습니다.")

        document = self.message_config_doc or {}
        explicit_scope_id = self.message_scope_id_var.get().strip()

        if resolved_slot == "pair-extra":
            pair_ids = self.message_config_service.pair_ids(document)
            scope_id = explicit_scope_id if explicit_scope_id in pair_ids else self._message_scope_id_from_context("pair-extra", document)
            help_text = "" if scope_id else "현재 pair 문맥이 없어 Pair Extra 슬롯을 바로 편집할 수 없습니다."
            return True, resolved_slot, scope_id, help_text
        if resolved_slot == "role-extra":
            role_ids = self.message_config_service.role_ids(document)
            scope_id = explicit_scope_id if explicit_scope_id in role_ids else self._message_scope_id_from_context("role-extra", document)
            help_text = "" if scope_id else "현재 role 문맥이 없어 Role Extra 슬롯을 바로 편집할 수 없습니다."
            return True, resolved_slot, scope_id, help_text
        if resolved_slot == "target-extra":
            target_ids = self.message_config_service.target_ids(document)
            scope_id = explicit_scope_id if explicit_scope_id in target_ids else self._message_scope_id_from_context("target-extra", document)
            help_text = "" if scope_id else "현재 target 문맥이 없어 Target Extra 슬롯을 바로 편집할 수 없습니다."
            return True, resolved_slot, scope_id, help_text
        return False, resolved_slot, "", MESSAGE_SCOPE_HELP_TEXT.get(resolved_slot, f"{resolved_slot} 슬롯은 여기서 직접 편집하지 않습니다.")

    def _message_scope_id_values(self) -> list[str]:
        return self._message_scope_id_values_for_kind(self._message_scope_kind(), self.message_config_doc or {})

    def _message_scope_id_values_for_kind(self, scope_kind: str, document: dict | None = None) -> list[str]:
        document = document or {}
        if scope_kind == "pair-extra":
            return self.message_config_service.pair_ids(document)
        if scope_kind == "role-extra":
            return self.message_config_service.role_ids(document)
        if scope_kind == "target-extra":
            return self.message_config_service.target_ids(document)
        return [""]

    def _message_scope_id_from_context(self, scope_kind: str, document: dict | None = None) -> str:
        document = document or {}
        preview_row = self._editor_context_row() or {}
        current_pair_id = self._selected_inspection_pair_id()
        current_role_name = str(preview_row.get("RoleName", "") or "")
        current_target_id = self._selected_inspection_target_id() or str(preview_row.get("TargetId", "") or "")
        scope_id_values = self._message_scope_id_values_for_kind(scope_kind, document)
        if scope_kind == "pair-extra" and current_pair_id in scope_id_values:
            return current_pair_id
        if scope_kind == "role-extra" and current_role_name in scope_id_values:
            return current_role_name
        if scope_kind == "target-extra" and current_target_id in scope_id_values:
            return current_target_id
        return scope_id_values[0] if scope_id_values and scope_id_values != [""] else ""

    def _sync_message_scope_id_from_context(self) -> None:
        scope_id_var = self.__dict__.get("message_scope_id_var")
        if scope_id_var is None or not hasattr(scope_id_var, "set"):
            return
        slot_key = str(self.__dict__.get("message_selected_slot_key", "") or "").strip()
        if slot_key in MESSAGE_EDITABLE_SCOPE_KINDS:
            scope_kind = slot_key
        else:
            scope_label_var = self.__dict__.get("message_scope_label_var")
            scope_label = scope_label_var.get().strip() if scope_label_var is not None and hasattr(scope_label_var, "get") else ""
            scope_kind = MESSAGE_SCOPE_LABEL_TO_KIND.get(scope_label, "global-prefix")
        if scope_kind in MESSAGE_EDITABLE_SCOPE_KINDS:
            scope_id_var.set(self._message_scope_id_from_context(scope_kind, self.message_config_doc or {}))
        else:
            scope_id_var.set("")

    def _current_message_scope(self) -> tuple[str, str, str]:
        return (
            self.message_template_var.get().strip() or "Initial",
            self._message_scope_kind(),
            self.message_scope_id_var.get().strip(),
        )

    def _active_message_block_scope(self, *, warn: bool = False) -> tuple[str, str, str] | None:
        template_name = self.message_template_var.get().strip() or "Initial"
        slot_key = self._selected_message_slot_key()
        editable, scope_kind, scope_id, help_text = self._message_slot_editor_context(slot_key)
        if not editable or scope_kind not in MESSAGE_EDITABLE_SCOPE_KINDS:
            if warn:
                messagebox.showwarning("편집 불가", help_text or "현재 선택한 슬롯은 여기서 직접 편집하지 않습니다.")
            return None
        if scope_kind in {"pair-extra", "role-extra", "target-extra"} and not scope_id:
            if warn:
                messagebox.showwarning("대상 없음", help_text or "현재 문맥에 맞는 대상 ID가 없어 이 슬롯을 편집할 수 없습니다.")
            return None
        return template_name, scope_kind, scope_id

    def _apply_message_filter_reset_policy(self, reason: str) -> None:
        policy = MESSAGE_FILTER_RESET_POLICY.get(reason, {})
        if policy.get("clear_search") and self.message_block_filter_var.get().strip():
            self.message_block_filter_var.set("")
        if policy.get("clear_changed_only") and self.message_block_changed_only_var.get():
            self.message_block_changed_only_var.set(False)

    def _prepare_message_slot_selection(self, slot_key: str, *, reason: str | None = None) -> None:
        previous_slot_key = str(getattr(self, "message_selected_slot_key", "") or "").strip()
        if reason and previous_slot_key and previous_slot_key != slot_key:
            self._apply_message_filter_reset_policy(reason)
        self.message_selected_slot_key = slot_key

    def _message_block_insert_index(self, block_count: int, selected_index: int | None) -> int:
        if selected_index is None:
            return block_count
        return min(selected_index + 1, block_count)

    def _message_block_action_states(
        self,
        *,
        slot_editable: bool,
        has_blocks: bool,
        has_selection: bool,
        filter_active: bool | None = None,
    ) -> dict[str, bool]:
        active_filter = self._message_block_filter_active() if filter_active is None else bool(filter_active)
        reorder_enabled = slot_editable and has_selection and not active_filter
        return {
            "filter_widgets": slot_editable,
            "clear_filter": active_filter,
            "listbox": slot_editable,
            "editor": slot_editable,
            "add": slot_editable,
            "update": slot_editable and has_selection,
            "clear": slot_editable and has_blocks,
            "duplicate": slot_editable and has_selection,
            "revert": slot_editable and has_selection,
            "delete": slot_editable and has_selection,
            "move_up": reorder_enabled,
            "move_down": reorder_enabled,
        }

    def _apply_message_block_action_states(self, states: dict[str, bool]) -> None:
        widget_specs = (
            ("filter_widgets", ("message_block_filter_entry", "message_block_changed_only_check")),
            ("clear_filter", ("message_block_clear_filter_button",)),
            ("listbox", ("message_blocks_list",)),
            ("add", ("message_add_block_button",)),
            ("update", ("message_update_block_button",)),
            ("clear", ("message_clear_blocks_button",)),
            ("duplicate", ("message_duplicate_block_button",)),
            ("revert", ("message_revert_block_button",)),
            ("delete", ("message_delete_block_button",)),
            ("move_up", ("message_move_block_up_button",)),
            ("move_down", ("message_move_block_down_button",)),
        )
        for state_key, widget_names in widget_specs:
            state = "normal" if states.get(state_key, False) else "disabled"
            for widget_name in widget_names:
                widget = getattr(self, widget_name, None)
                if widget is not None:
                    widget.configure(state=state)

    def _set_message_block_editor_text(self, value: str, *, editable: bool) -> None:
        self.message_block_text.configure(state="normal")
        self.message_block_text.delete("1.0", "end")
        if value:
            self.message_block_text.insert("1.0", value)
        if not editable:
            self.message_block_text.configure(state="disabled")

    def _apply_editor_context_for_target(self, *, pair_id: str = "", role_name: str = "", target_id: str = "") -> None:
        document = self.message_config_doc or {}
        pair_ids = set(self.message_config_service.pair_ids(document))
        role_ids = set(self.message_config_service.role_ids(document))
        target_ids = set(self.message_config_service.target_ids(document))

        if target_id and target_id in target_ids:
            self.message_scope_label_var.set(MESSAGE_SCOPE_KIND_TO_LABEL["target-extra"])
            self.message_scope_id_var.set(target_id)
            self.message_selected_slot_key = "target-extra"
            self.message_editor_status_var.set(f"보드 선택 문맥 반영: Target Extra / {target_id}")
            return
        if role_name and role_name in role_ids:
            self.message_scope_label_var.set(MESSAGE_SCOPE_KIND_TO_LABEL["role-extra"])
            self.message_scope_id_var.set(role_name)
            self.message_selected_slot_key = "role-extra"
            self.message_editor_status_var.set(f"보드 선택 문맥 반영: Role Extra / {role_name}")
            return
        if pair_id and pair_id in pair_ids:
            self.message_scope_label_var.set(MESSAGE_SCOPE_KIND_TO_LABEL["pair-extra"])
            self.message_scope_id_var.set(pair_id)
            self.message_selected_slot_key = "pair-extra"
            self.message_editor_status_var.set(f"보드 선택 문맥 반영: Pair Extra / {pair_id}")
            return
        self.message_scope_label_var.set(MESSAGE_SCOPE_KIND_TO_LABEL["global-prefix"])
        self.message_scope_id_var.set("")
        self.message_selected_slot_key = "global-prefix"
        self.message_editor_status_var.set("보드 선택 문맥 반영: 글로벌 Prefix")

    def _editor_context_row(self) -> dict | None:
        target_id = self._selected_inspection_target_id() or self.target_id_var.get().strip()
        pair_id = self._selected_inspection_pair_id() or self.pair_id_var.get().strip()
        if target_id:
            for row in self.preview_rows:
                if row.get("TargetId", "") == target_id:
                    return row
        if pair_id:
            for row in self.preview_rows:
                if row.get("PairId", "") == pair_id and row.get("RoleName", "") == "top":
                    return row
            for row in self.preview_rows:
                if row.get("PairId", "") == pair_id:
                    return row
        return self.preview_rows[0] if self.preview_rows else None

    def _current_message_blocks(self) -> list[str]:
        if not self.message_config_doc:
            return []
        template_name, scope_kind, scope_id = self._current_message_scope()
        if scope_kind not in MESSAGE_EDITABLE_SCOPE_KINDS:
            return []
        return self.message_config_service.get_blocks(self.message_config_doc, scope_kind, scope_id, template_name)

    def _current_original_message_blocks(self) -> list[str]:
        if not self.message_config_original:
            return []
        template_name, scope_kind, scope_id = self._current_message_scope()
        if scope_kind not in MESSAGE_EDITABLE_SCOPE_KINDS:
            return []
        return self.message_config_service.get_blocks(self.message_config_original, scope_kind, scope_id, template_name)

    def _message_block_filter_text(self) -> str:
        return self.message_block_filter_var.get().strip().lower()

    def _message_block_filter_active(self) -> bool:
        return bool(self._message_block_filter_text()) or bool(self.message_block_changed_only_var.get())

    def _filtered_message_blocks(self, blocks: list[str], original_blocks: list[str]) -> list[tuple[int, str, bool]]:
        filter_text = self._message_block_filter_text()
        changed_only = bool(self.message_block_changed_only_var.get())
        visible: list[tuple[int, str, bool]] = []
        for index, block in enumerate(blocks):
            block_text = str(block)
            changed = index >= len(original_blocks) or original_blocks[index] != block_text
            if filter_text and filter_text not in block_text.lower():
                continue
            if changed_only and not changed:
                continue
            visible.append((index, block_text, changed))
        return visible

    def _select_message_block_actual_index(self, actual_index: int | None) -> None:
        if actual_index is None or actual_index not in self.message_block_visible_indexes:
            return
        visible_index = self.message_block_visible_indexes.index(actual_index)
        self.message_blocks_list.selection_clear(0, "end")
        self.message_blocks_list.selection_set(visible_index)
        self.message_blocks_list.see(visible_index)

    def _selected_message_block_index(self) -> int | None:
        selection = self.message_blocks_list.curselection()
        if not selection:
            return None
        visible_index = int(selection[0])
        if visible_index < 0 or visible_index >= len(self.message_block_visible_indexes):
            return None
        return self.message_block_visible_indexes[visible_index]

    def _selected_message_slot_index(self) -> int | None:
        selection = self.message_slot_order_list.curselection()
        if not selection:
            return None
        return int(selection[0])

    def _format_message_validation_lines(self, issues: list[dict[str, str]]) -> str:
        if not issues:
            return "검증 결과: 차단/경고 항목 없음"
        lines = []
        for item in issues:
            lines.append("[{0}] {1}: {2}".format(item.get("severity", "info"), item.get("code", ""), item.get("message", "")))
        return "\n".join(lines)

    def _message_diff_summary_text(self) -> str:
        if not self.message_config_doc:
            return "(변경 없음)"
        summary = self.message_config_service.diff_summary(self.message_config_original or self.message_config_doc, self.message_config_doc)
        return "\n".join(
            [
                "변경 요약:",
                f"- slot 순서 변경: {summary['slot_order_changes']}",
                f"- 블록 scope 변경: {summary['block_scope_changes']}",
                f"- 추가 블록: {summary['added_blocks']}",
                f"- 삭제 블록: {summary['removed_blocks']}",
                f"- 수정 블록: {summary['updated_blocks']}",
                f"- 고정문구 변경: {summary['fixed_suffix_changes']}",
            ]
        )

    def _editor_preview_text(self, message_key: str) -> str:
        row, source_kind, _payload = self._editor_preview_row_and_source()
        if not row:
            return "(선택된 preview row 없음)"
        payload = row.get(message_key, {}) or {}
        preview = str(payload.get("Preview", "") or "")
        if preview:
            return self._message_preview_banner(source_kind) + "\n\n" + preview
        return self._message_preview_banner(source_kind) + "\n\n(preview 없음)"

    def _editor_final_delivery_text(self) -> str:
        row, source_kind, payload = self._editor_preview_row_and_source()
        if not row:
            return "(선택된 pair/target preview 없음)"
        initial_preview = str((row.get("Initial", {}) or {}).get("Preview", "") or "(preview 없음)")
        handoff_preview = str((row.get("Handoff", {}) or {}).get("Preview", "") or "(preview 없음)")
        lines = [
            self._message_preview_banner(source_kind),
            f"GeneratedAt: {payload.get('GeneratedAt', '') or '(없음)'}",
            f"Warnings: {self._message_preview_warning_text(payload)}",
            "",
            "[Initial 최종 전달문]",
            initial_preview,
            "",
            "[Handoff 최종 전달문]",
            handoff_preview,
        ]
        return "\n".join(lines)

    def _editor_path_summary_text(self) -> str:
        row, source_kind, payload = self._editor_preview_row_and_source()
        if not row:
            return "(선택된 pair/target preview 없음)"
        review_input_files = row.get("ReviewInputFiles", {}) or {}
        resolved_output_paths = self._resolved_output_paths_from_row(row)
        own_target_folder = row.get("OwnTargetFolder", "") or row.get("PairTargetFolder", "") or ""
        partner_target_folder = row.get("PartnerTargetFolder", "") or row.get("PartnerFolder", "") or ""
        partner_summary_path = review_input_files.get("PartnerSummaryPath", "") or ""
        partner_review_zip_path = review_input_files.get("PartnerReviewZipPath", "") or ""
        available_review_inputs = list(review_input_files.get("AvailablePaths", []) or [])
        external_review_input = review_input_files.get("ExternalReviewInputPath", "") or ""
        lines = [
            self._message_preview_banner(source_kind),
            f"GeneratedAt: {payload.get('GeneratedAt', '') or '(없음)'}",
            f"Warnings: {self._message_preview_warning_text(payload)}",
            "",
            "현재 대상",
            f"- Pair: {row.get('PairId', '')}",
            f"- Role: {row.get('RoleName', '')}",
            f"- Target: {row.get('TargetId', '')}",
            f"- Partner: {row.get('PartnerTargetId', '')}",
            "",
            "작업 폴더",
            f"- 내 작업 폴더: {own_target_folder or '(없음)'}",
            f"- 상대 작업 폴더: {partner_target_folder or '(없음)'}",
            "",
            "검토 입력 후보 경로",
            f"- summary.txt: {partner_summary_path or '(없음)'}",
            f"- review.zip: {partner_review_zip_path or '(없음)'}",
        ]
        if external_review_input:
            lines.append(f"- external review input: {external_review_input}")
        lines.extend(["", "현재 존재하는 검토 입력 파일"])
        if available_review_inputs:
            lines.extend(f"- {path}" for path in available_review_inputs)
        else:
            lines.append("- (현재 존재하는 검토 입력 파일 없음)")
        lines.extend(
            [
                "",
                "생성 출력 경로",
                f"- summary.txt: {resolved_output_paths.get('SourceSummaryPath', '') or '(없음)'}",
                f"- review.zip: {resolved_output_paths.get('SourceReviewZipPath', '') or '(없음)'}",
                f"- helper output marker: {resolved_output_paths.get('PublishReadyPath', '') or '(없음)'}",
                "",
                "보조 경로",
                f"- request.json: {row.get('RequestPath', '') or '(없음)'}",
                f"- instructions.txt: {row.get('InitialInstructionPath', '') or '(없음)'}",
                f"- initial message: {row.get('InitialMessagePath', '') or '(없음)'}",
                f"- handoff pattern: {row.get('HandoffMessagePattern', '') or '(없음)'}",
            ]
        )
        return "\n".join(lines)

    def _editor_context_text(self) -> str:
        row, source_kind, payload = self._editor_preview_row_and_source()
        if not row:
            return "(선택된 pair/target preview 없음)"
        review_input_files = row.get("ReviewInputFiles", {}) or {}
        resolved_output_paths = self._resolved_output_paths_from_row(row)
        available_review_inputs = list(review_input_files.get("AvailablePaths", []) or [])
        external_review_input = review_input_files.get("ExternalReviewInputPath", "") or ""
        lines = [
            self._message_preview_banner(source_kind),
            f"GeneratedAt: {payload.get('GeneratedAt', '') or '(없음)'}",
            f"Warnings: {self._message_preview_warning_text(payload)}",
            "",
            "현재 문맥",
            f"- Pair: {row.get('PairId', '')}",
            f"- Role: {row.get('RoleName', '')}",
            f"- Target: {row.get('TargetId', '')}",
            f"- Partner: {row.get('PartnerTargetId', '')}",
            f"- 창 제목: {row.get('WindowTitle', '') or '(없음)'}",
            f"- Inbox: {row.get('InboxFolder', '') or '(없음)'}",
            f"- 내 작업 폴더: {row.get('OwnTargetFolder', '') or row.get('PairTargetFolder', '') or '(없음)'}",
            f"- 상대 작업 폴더: {row.get('PartnerTargetFolder', '') or row.get('PartnerFolder', '') or '(없음)'}",
            f"- Review 폴더: {row.get('ReviewFolderPath', '') or '(없음)'}",
            f"- Summary: {row.get('SummaryPath', '') or '(없음)'}",
            "",
            "검토 입력 경로",
        ]
        if available_review_inputs:
            lines.extend(f"- {path}" for path in available_review_inputs)
        else:
            lines.append("- (현재 존재하는 검토 입력 파일 없음)")
        if external_review_input and external_review_input not in available_review_inputs:
            lines.append(f"- external review input: {external_review_input}")
        lines.extend(
            [
                "",
                "생성 출력 경로",
                f"- summary.txt: {resolved_output_paths.get('SourceSummaryPath', '') or '(없음)'}",
                f"- review.zip: {resolved_output_paths.get('SourceReviewZipPath', '') or '(없음)'}",
                f"- helper output marker: {resolved_output_paths.get('PublishReadyPath', '') or '(없음)'}",
            ]
        )
        return "\n".join(lines)

    def _editor_one_time_text(self) -> str:
        row, source_kind, _payload = self._editor_preview_row_and_source()
        if not row:
            return "(선택된 preview row 없음)"
        lines = [
            self._message_preview_banner(source_kind),
            "",
            "[Initial]",
            self.format_one_time_items(row.get("Initial", {}).get("PendingOneTimeItems", [])),
            "",
            "[Handoff]",
            self.format_one_time_items(row.get("Handoff", {}).get("PendingOneTimeItems", [])),
        ]
        return "\n".join(lines)

    def _message_block_filter_label(self) -> str:
        filter_label = "changed-only" if self.message_block_changed_only_var.get() else "all"
        search_text = self.message_block_filter_var.get().strip()
        if search_text:
            filter_label += f" / search='{search_text}'"
        return filter_label

    def _message_block_badges_text(self, *, slot_key: str, slot_editable: bool) -> str:
        badges: list[str] = []
        if not slot_editable:
            slot_label = SCOPED_SLOT_LABELS.get(slot_key, slot_key or "(없음)")
            badges.append(f"preview-only:{slot_label}")
        if self.message_block_changed_only_var.get():
            badges.append("changed only")
        search_text = self.message_block_filter_var.get().strip()
        if search_text:
            badges.append(f"search='{search_text}'")
        if not badges:
            return ""
        return "상태 배지: " + "  ".join(f"[{badge}]" for badge in badges)

    def _apply_message_block_aux_state(
        self,
        *,
        badges_text: str,
        hint_text: str,
        show_add_cta: bool,
        show_clear_filter_cta: bool,
    ) -> None:
        self.message_block_badges_var.set(badges_text)
        self.message_block_hint_var.set(hint_text)
        aux_frame = getattr(self, "message_block_aux_frame", None)
        add_button = getattr(self, "message_empty_add_button", None)
        clear_button = getattr(self, "message_empty_clear_filter_button", None)
        if add_button is not None:
            if show_add_cta:
                add_button.grid()
            else:
                add_button.grid_remove()
        if clear_button is not None:
            if show_clear_filter_cta:
                clear_button.grid()
            else:
                clear_button.grid_remove()
        if aux_frame is not None:
            if badges_text or hint_text or show_add_cta or show_clear_filter_cta:
                aux_frame.grid()
            else:
                aux_frame.grid_remove()

    def _apply_empty_message_editor_state(self) -> None:
        self._apply_message_block_action_states(
            self._message_block_action_states(slot_editable=False, has_blocks=False, has_selection=False)
        )
        self._apply_message_block_aux_state(
            badges_text="",
            hint_text="",
            show_add_cta=False,
            show_clear_filter_cta=False,
        )
        self.message_scope_id_var.set("")
        self.message_scope_id_combo.configure(values=[""], state="disabled")
        self.target_fixed_combo.configure(values=[])
        self.message_blocks_list.delete(0, "end")
        self.message_block_visible_indexes = []
        self.message_slot_order_list.delete(0, "end")
        self.message_last_rendered_slot_order = ()
        self.message_block_filter_status_var.set("블록 표시: 0/0")
        self._set_message_block_editor_text("", editable=True)
        self.default_fixed_text.delete("1.0", "end")
        self.target_fixed_text.delete("1.0", "end")
        self.set_text(self.message_summary_text, "(설정 문서를 불러오지 못했습니다.)")
        self.set_text(self.message_initial_preview_text, "")
        self.set_text(self.message_handoff_preview_text, "")
        self.set_text(self.message_final_delivery_text, "")
        self.set_text(self.message_path_summary_text, "")
        self.set_text(self.message_context_text, "")
        self.set_text(self.message_plan_text, "")
        self.set_text(self.message_validation_text, "")
        self.set_text(self.message_one_time_preview_text, "")
        self.set_text(self.message_diff_text, "")
        self.set_text(self.message_backup_text, "")
        self._refresh_message_editor_action_buttons()

    def _build_message_editor_view_state(
        self,
        document: dict,
        *,
        selected_block_index: int | None = None,
        include_side_panels: bool = True,
    ) -> dict[str, object]:
        template_name = self.message_template_var.get().strip() or "Initial"
        slot_order = self.message_config_service.get_slot_order(document, template_name)
        selected_slot_key = self._selected_message_slot_key(slot_order)
        if selected_slot_key:
            self._prepare_message_slot_selection(selected_slot_key)
        else:
            self._prepare_message_slot_selection(self._message_slot_key_for_scope())
            selected_slot_key = self.message_selected_slot_key
        if selected_slot_key != getattr(self, "message_last_rendered_slot_key", ""):
            selected_block_index = None

        slot_editable, slot_scope_kind, slot_scope_id, slot_help_text = self._message_slot_editor_context(selected_slot_key)
        scope_label = MESSAGE_SCOPE_KIND_TO_LABEL.get(slot_scope_kind, MESSAGE_SCOPE_KIND_TO_LABEL["global-prefix"])
        scope_id = slot_scope_id if slot_editable and slot_scope_kind in MESSAGE_EDITABLE_SCOPE_KINDS else ""
        scope_id_values = self._message_scope_id_values_for_kind(slot_scope_kind, document)
        filter_active = self._message_block_filter_active()
        slot_label = SCOPED_SLOT_LABELS.get(selected_slot_key or "", selected_slot_key or "")
        filter_badges_text = self._message_block_badges_text(slot_key=selected_slot_key or "", slot_editable=slot_editable)
        block_hint_text = ""
        show_add_cta = False
        show_clear_filter_cta = False
        if not scope_id_values or scope_id_values == [""]:
            scope_id = ""
            scope_id_combo_state = "disabled"
        else:
            scope_id_combo_state = "readonly"
            if scope_id not in scope_id_values:
                scope_id = scope_id_values[0]

        target_ids = self.message_config_service.target_ids(document)
        selected_target_suffix_id = self.message_target_suffix_var.get().strip()
        if not target_ids:
            selected_target_suffix_id = ""
        elif selected_target_suffix_id not in target_ids:
            selected_target_suffix_id = target_ids[0]

        scope_kind = slot_scope_kind
        filter_label = self._message_block_filter_label()
        blocks: list[str] = []
        block_items: list[str] = []
        block_visible_indexes: list[int] = []
        selected_block_actual_index: int | None = None
        block_editor_text = ""
        block_text_editable = False
        if slot_editable and scope_kind in MESSAGE_EDITABLE_SCOPE_KINDS:
            blocks = self.message_config_service.get_blocks(document, scope_kind, scope_id, template_name)
            original_document = self.message_config_original or document
            original_blocks = self.message_config_service.get_blocks(original_document, scope_kind, scope_id, template_name)
            filtered_blocks = self._filtered_message_blocks(blocks, original_blocks)
            block_visible_indexes = [actual_index for actual_index, _block, _changed in filtered_blocks]
            for actual_index, block, changed in filtered_blocks:
                preview = re.sub(r"\s+", " ", str(block)).strip()
                if len(preview) > 90:
                    preview = preview[:87] + "..."
                marker = "* " if changed else "  "
                block_items.append(f"{marker}{actual_index + 1}. {preview}")

            block_status_text = f"블록 표시: {len(filtered_blocks)}/{len(blocks)} ({filter_label})"
            if filtered_blocks:
                if selected_block_index is None or selected_block_index not in block_visible_indexes:
                    selected_block_index = block_visible_indexes[0]
                selected_block_actual_index = selected_block_index
                block_editor_text = blocks[selected_block_index]
                block_text_editable = True
            else:
                if slot_help_text:
                    block_status_text += f" / {slot_help_text}"
                    block_hint_text = slot_help_text
                elif blocks and self._message_block_filter_active():
                    block_status_text += " / 검색 또는 changed-only 필터 때문에 표시되는 블록이 없습니다."
                    block_hint_text = "필터 때문에 현재 표시되는 블록이 없습니다. 필터를 해제하면 기존 블록을 다시 볼 수 있습니다."
                else:
                    block_status_text += f" / 현재 {slot_label} 슬롯에는 블록이 없습니다. 아래에 내용을 입력하고 새 블록 추가를 누르세요."
                    block_hint_text = f"현재 {slot_label} 슬롯이 비어 있습니다. 아래 입력 내용을 바로 새 블록으로 추가할 수 있습니다."
                show_add_cta = not blocks
                show_clear_filter_cta = filter_active
            action_states = self._message_block_action_states(
                slot_editable=True,
                has_blocks=bool(blocks),
                has_selection=bool(block_visible_indexes),
                filter_active=filter_active,
            )
        else:
            help_text = slot_help_text or "이 슬롯은 여기서 직접 편집하지 않습니다."
            block_status_text = f"블록 표시: slot={selected_slot_key or '(없음)'} / preview-only / {help_text}"
            block_editor_text = help_text
            block_hint_text = f"잠금됨: {help_text}"
            show_clear_filter_cta = filter_active
            action_states = self._message_block_action_states(
                slot_editable=False,
                has_blocks=False,
                has_selection=False,
                filter_active=filter_active,
            )

        block_text_editable = bool(action_states.get("editor"))

        preview_status_text = None
        if include_side_panels:
            if (
                self.message_preview_payload
                and self.message_preview_doc_version == self.message_document_version
                and self.message_preview_cached_context_key != self._message_preview_context_signature()
            ):
                preview_status_text = "선택된 pair/target/run root가 바뀌어 preview가 이전 문맥 기준입니다. '미리보기 갱신'으로 현재 문맥을 다시 계산하세요."
            if self._message_editor_has_unsaved_changes() and not self._message_preview_is_fresh():
                preview_status_text = "현재 preview가 최신 편집본 기준이 아닙니다. 저장 전 '미리보기 갱신' 또는 영향 요약 확인이 필요합니다."

        validation_lines = self.message_config_service.validate_document(
            document,
            template_name=template_name,
            scope_kind=scope_kind,
            scope_id=scope_id,
        )
        template_help_suffix = "target-extra는 Initial/Handoff가 서로 별도 저장됩니다."
        current_scope_label = MESSAGE_SCOPE_KIND_TO_LABEL.get(scope_kind, scope_kind)
        current_scope_target = scope_id or "global"
        template_hint_text = (
            f"현재 편집 템플릿: {template_name}. "
            f"현재 범위: {current_scope_label} / {current_scope_target}. "
            f"{template_help_suffix}"
        )
        scope_frame_text = f"편집 문맥 / {template_name}"
        block_frame_text = f"블록 편집 / {template_name} / {current_scope_label}"
        editor_status_text = (
            f"{template_name} / {MESSAGE_SCOPE_KIND_TO_LABEL.get(scope_kind, scope_kind)} / {scope_id or 'global'} 편집 중"
            if slot_editable and scope_kind in MESSAGE_EDITABLE_SCOPE_KINDS
            else f"{template_name} / {SCOPED_SLOT_LABELS.get(selected_slot_key or '', selected_slot_key or '')} / preview-only"
        )

        summary_text = None
        diff_text = None
        initial_preview_text = None
        handoff_preview_text = None
        final_delivery_text = None
        path_summary_text = None
        context_text = None
        plan_text = None
        one_time_preview_text = None
        if include_side_panels:
            summary_text = self.message_config_service.snapshot_text(document)
            diff_text = self._message_diff_summary_text() + "\n\n" + self.message_config_service.diff_text(self.message_config_original or document, document)
            initial_preview_text = self._editor_preview_text("Initial")
            handoff_preview_text = self._editor_preview_text("Handoff")
            final_delivery_text = self._editor_final_delivery_text()
            path_summary_text = self._editor_path_summary_text()
            context_text = self._editor_context_text()
            plan_text = self._editor_plan_text()
            one_time_preview_text = self._editor_one_time_text()

        return {
            "include_side_panels": include_side_panels,
            "template_name": template_name,
            "slot_order": slot_order,
            "selected_slot_key": selected_slot_key or "",
            "scope_label": scope_label,
            "scope_kind": scope_kind,
            "scope_id": scope_id,
            "scope_id_values": scope_id_values,
            "scope_id_combo_state": scope_id_combo_state,
            "target_ids": target_ids,
            "selected_target_suffix_id": selected_target_suffix_id,
            "default_fixed_text": self.message_config_service.get_default_fixed_suffix(document),
            "target_fixed_text": self.message_config_service.get_target_fixed_suffix(document, selected_target_suffix_id) if selected_target_suffix_id else "",
            "block_items": block_items,
            "block_visible_indexes": block_visible_indexes,
            "selected_block_actual_index": selected_block_actual_index,
            "block_status_text": block_status_text,
            "filter_badges_text": filter_badges_text,
            "block_hint_text": block_hint_text,
            "show_add_cta": show_add_cta,
            "show_clear_filter_cta": show_clear_filter_cta,
            "block_editor_text": block_editor_text,
            "block_text_editable": block_text_editable,
            "action_states": action_states,
            "summary_text": summary_text,
            "diff_text": diff_text,
            "initial_preview_text": initial_preview_text,
            "handoff_preview_text": handoff_preview_text,
            "final_delivery_text": final_delivery_text,
            "path_summary_text": path_summary_text,
            "context_text": context_text,
            "plan_text": plan_text,
            "one_time_preview_text": one_time_preview_text,
            "validation_text": self._format_message_validation_lines(validation_lines),
            "preview_status_text": preview_status_text,
            "editor_status_text": editor_status_text,
            "template_hint_text": template_hint_text,
            "scope_frame_text": scope_frame_text,
            "block_frame_text": block_frame_text,
        }

    def _apply_message_editor_view_state(self, state: dict[str, object]) -> None:
        self.message_scope_label_var.set(str(state["scope_label"]))
        self.message_scope_id_var.set(str(state["scope_id"]))
        self.message_template_hint_var.set(str(state["template_hint_text"]))
        self.message_scope_id_combo.configure(values=list(state["scope_id_values"]), state=str(state["scope_id_combo_state"]))
        self.target_fixed_combo.configure(values=list(state["target_ids"]))
        self.message_target_suffix_var.set(str(state["selected_target_suffix_id"]))
        if hasattr(self, "message_editor_scope_frame"):
            self.message_editor_scope_frame.configure(text=str(state["scope_frame_text"]))
        if hasattr(self, "message_block_frame"):
            self.message_block_frame.configure(text=str(state["block_frame_text"]))

        self.message_blocks_list.delete(0, "end")
        self.message_block_visible_indexes = list(state["block_visible_indexes"])
        for item in list(state["block_items"]):
            self.message_blocks_list.insert("end", item)
        self.message_block_filter_status_var.set(str(state["block_status_text"]))
        self._apply_message_block_aux_state(
            badges_text=str(state["filter_badges_text"]),
            hint_text=str(state["block_hint_text"]),
            show_add_cta=bool(state["show_add_cta"]),
            show_clear_filter_cta=bool(state["show_clear_filter_cta"]),
        )
        selected_block_actual_index = state["selected_block_actual_index"]
        if selected_block_actual_index is None:
            self.message_blocks_list.selection_clear(0, "end")
        else:
            self._select_message_block_actual_index(int(selected_block_actual_index))
        self._set_message_block_editor_text(str(state["block_editor_text"]), editable=bool(state["block_text_editable"]))
        self._apply_message_block_action_states(dict(state["action_states"]))

        slot_order = list(state["slot_order"])
        slot_order_signature = tuple(slot_order)
        if slot_order_signature != getattr(self, "message_last_rendered_slot_order", ()):
            self.message_slot_order_list.delete(0, "end")
            for slot in slot_order:
                self.message_slot_order_list.insert("end", f"{slot}  ({SCOPED_SLOT_LABELS.get(slot, slot)})")
        selected_slot_key = str(state["selected_slot_key"])
        self.message_slot_order_list.selection_clear(0, "end")
        if selected_slot_key and selected_slot_key in slot_order:
            self.message_slot_order_list.selection_set(slot_order.index(selected_slot_key))
        elif slot_order:
            self.message_slot_order_list.selection_set(0)

        self.default_fixed_text.delete("1.0", "end")
        self.default_fixed_text.insert("1.0", str(state["default_fixed_text"]))
        self.target_fixed_text.delete("1.0", "end")
        if state["selected_target_suffix_id"]:
            self.target_fixed_text.insert("1.0", str(state["target_fixed_text"]))

        if bool(state.get("include_side_panels", True)):
            preview_status_text = state["preview_status_text"]
            if preview_status_text:
                self.message_preview_status_var.set(str(preview_status_text))

            self.set_text(self.message_summary_text, str(state["summary_text"]))
            self.set_text(self.message_diff_text, str(state["diff_text"]))
            self.refresh_message_backup_list()
            self.set_text(self.message_initial_preview_text, str(state["initial_preview_text"]))
            self.set_text(self.message_handoff_preview_text, str(state["handoff_preview_text"]))
            self.set_text(self.message_final_delivery_text, str(state["final_delivery_text"]))
            self.set_text(self.message_path_summary_text, str(state["path_summary_text"]))
            self.set_text(self.message_context_text, str(state["context_text"]))
            self.set_text(self.message_plan_text, str(state["plan_text"]))
            self.set_text(self.message_one_time_preview_text, str(state["one_time_preview_text"]))
        self.set_text(self.message_validation_text, str(state["validation_text"]))
        self.message_editor_status_var.set(str(state["editor_status_text"]))

        self.message_last_rendered_slot_key = selected_slot_key
        self.message_last_rendered_slot_order = slot_order_signature
        self.message_last_rendered_template_name = str(state["template_name"])
        self.message_last_rendered_scope_kind = str(state["scope_kind"])
        self.message_last_rendered_scope_id = str(state["scope_id"])
        self._refresh_message_editor_action_buttons()

    def render_message_editor(self, *, include_side_panels: bool = True) -> None:
        document = self.message_config_doc
        if not document:
            self._apply_empty_message_editor_state()
            return
        state = self._build_message_editor_view_state(
            document,
            selected_block_index=self._selected_message_block_index(),
            include_side_panels=include_side_panels,
        )
        self._apply_message_editor_view_state(state)

    def on_message_editor_scope_changed(self, _event: object | None = None) -> None:
        template_name = self.message_template_var.get().strip() or "Initial"
        scope_kind = self._message_scope_kind()
        scope_id = self.message_scope_id_var.get().strip()
        if (
            template_name != getattr(self, "message_last_rendered_template_name", "")
            or scope_kind != getattr(self, "message_last_rendered_scope_kind", "")
            or scope_id != getattr(self, "message_last_rendered_scope_id", "")
        ):
            self._apply_message_filter_reset_policy("scope_change")
        self.message_selected_slot_key = self._message_slot_key_for_scope()
        self.render_message_editor(include_side_panels=False)

    def set_message_template(self, template_name: str) -> None:
        normalized = str(template_name or "").strip()
        if normalized not in {"Initial", "Handoff"}:
            normalized = "Initial"
        self.message_template_var.set(normalized)
        self.on_message_editor_scope_changed()
        if self._has_ui_attr("message_block_focus_mode_var") and bool(self.message_block_focus_mode_var.get()):
            self._apply_message_block_focus_mode()

    def on_message_slot_selected(self, _event: object | None = None) -> None:
        template_name = self.message_template_var.get().strip() or "Initial"
        slot_order = self.message_config_service.get_slot_order(self.message_config_doc or {}, template_name)
        slot_key = None
        if self._has_ui_attr("message_slot_order_list"):
            selection = self.message_slot_order_list.curselection()
            if selection:
                selected_index = int(selection[0])
                if 0 <= selected_index < len(slot_order):
                    slot_key = slot_order[selected_index]
        if not slot_key:
            slot_key = self._selected_message_slot_key(slot_order)
        if not slot_key:
            return
        self._prepare_message_slot_selection(slot_key, reason="slot_change")
        editable, scope_kind, scope_id, _help_text = self._message_slot_editor_context(slot_key)
        self.message_scope_label_var.set(MESSAGE_SCOPE_KIND_TO_LABEL.get(scope_kind, MESSAGE_SCOPE_KIND_TO_LABEL["global-prefix"]))
        self.message_scope_id_var.set(scope_id if editable and scope_kind in MESSAGE_EDITABLE_SCOPE_KINDS else "")
        self.render_message_editor(include_side_panels=False)

    def on_message_block_filter_changed(self, _event: object | None = None) -> None:
        self.render_message_editor(include_side_panels=False)

    def clear_message_block_filter(self) -> None:
        self._apply_message_filter_reset_policy("clear_filter")
        self.render_message_editor(include_side_panels=False)

    def _ensure_message_block_reorder_allowed(self) -> bool:
        if self._active_message_block_scope(warn=True) is None:
            return False
        if not self._message_block_filter_active():
            return True
        messagebox.showwarning("정렬 제한", "검색/changed-only 필터가 켜져 있을 때는 블록 순서를 바꿀 수 없습니다. 필터를 먼저 해제하세요.")
        return False

    def show_message_impact_summary(self) -> str:
        impact_text = self._message_impact_summary_text()
        diff_body = self.message_config_service.diff_text(self.message_config_original or self.message_config_doc or {}, self.message_config_doc or {})
        self.set_text(
            self.message_diff_text,
            impact_text + "\n\n" + self._message_diff_summary_text() + "\n\n" + diff_body,
        )
        if self._has_ui_attr("editor_diff_tab"):
            self.editor_right_notebook.select(self.editor_diff_tab)
        return impact_text

    def refresh_message_editor_preview(self) -> None:
        if not self.message_config_doc:
            messagebox.showwarning("설정 없음", "먼저 설정 문서를 불러오세요.")
            return
        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 경로 없음", "ConfigPath를 먼저 확인하세요.")
            return
        run_root, pair_id, target_id = self._message_preview_context()
        if not pair_id:
            messagebox.showwarning("Pair 없음", "preview를 계산할 pair 문맥을 먼저 선택하세요.")
            return
        if not target_id:
            messagebox.showwarning("Target 없음", "preview를 계산할 target 문맥을 먼저 선택하세요.")
            return
        try:
            payload = self.message_config_service.render_effective_preview(
                self.message_config_doc,
                config_path=config_path,
                run_root=run_root,
                pair_id=pair_id,
                target_id=target_id,
                mode="both",
            )
        except Exception as exc:
            messagebox.showerror("미리보기 갱신 실패", str(exc))
            self.message_preview_status_var.set(f"미리보기 갱신 실패: {exc}")
            return
        self.message_preview_payload = payload
        self.message_preview_doc_version = self.message_document_version
        self.message_preview_cached_context_key = self._message_preview_context_signature()
        self.message_editor_dirty = self._message_editor_has_unsaved_changes()
        warning_count = len(payload.get("Warnings", []) or [])
        self.message_preview_status_var.set(
            f"편집본 preview 갱신 완료 / pair={pair_id} / target={target_id} / run={Path(run_root).name or run_root or '(없음)'} / warnings={warning_count}"
        )
        self.render_message_editor()

    def on_message_block_selected(self, _event: object | None = None) -> None:
        actual_index = self._selected_message_block_index()
        active_scope = self._active_message_block_scope()
        if actual_index is None or not self.message_config_doc or active_scope is None:
            return
        template_name, scope_kind, scope_id = active_scope
        blocks = self.message_config_service.get_blocks(
            self.message_config_doc,
            scope_kind,
            scope_id,
            template_name,
        )
        if actual_index < len(blocks):
            self._set_message_block_editor_text(blocks[actual_index], editable=True)

    def _message_block_text_value(self) -> str:
        return self.message_block_text.get("1.0", "end").strip()

    def add_message_block(self) -> None:
        if not self.message_config_doc:
            return
        active_scope = self._active_message_block_scope(warn=True)
        if active_scope is None:
            return
        value = self._message_block_text_value()
        if not value:
            messagebox.showwarning("블록 없음", "추가할 블록 내용을 입력하세요.")
            return
        template_name, scope_kind, scope_id = active_scope
        blocks = self.message_config_service.get_blocks(self.message_config_doc, scope_kind, scope_id, template_name)
        actual_index = self._selected_message_block_index()
        insert_at = self._message_block_insert_index(len(blocks), actual_index)
        blocks.insert(insert_at, value)
        self.message_config_service.set_blocks(self.message_config_doc, scope_kind, scope_id, template_name, blocks)
        self._reset_message_preview_cache("블록을 추가했습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()
        self._select_message_block_actual_index(insert_at)
        self.on_message_block_selected()

    def duplicate_message_block(self) -> None:
        if not self.message_config_doc:
            return
        active_scope = self._active_message_block_scope(warn=True)
        if active_scope is None:
            return
        actual_index = self._selected_message_block_index()
        if actual_index is None:
            messagebox.showwarning("선택 필요", "복제할 블록을 먼저 선택하세요.")
            return
        template_name, scope_kind, scope_id = active_scope
        self.message_config_service.clone_block(self.message_config_doc, scope_kind, scope_id, template_name, actual_index)
        self._reset_message_preview_cache("블록을 복제했습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()
        self._select_message_block_actual_index(actual_index + 1)
        self.on_message_block_selected()

    def revert_selected_message_block(self) -> None:
        if not self.message_config_doc or not self.message_config_original:
            return
        active_scope = self._active_message_block_scope(warn=True)
        if active_scope is None:
            return
        actual_index = self._selected_message_block_index()
        if actual_index is None:
            messagebox.showwarning("선택 필요", "원복할 블록을 먼저 선택하세요.")
            return
        template_name, scope_kind, scope_id = active_scope
        try:
            self.message_config_service.revert_block(
                self.message_config_doc,
                self.message_config_original,
                scope_kind,
                scope_id,
                template_name,
                actual_index,
            )
        except Exception as exc:
            messagebox.showerror("블록 원복 실패", str(exc))
            return
        self._reset_message_preview_cache("선택 블록을 원복했습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()
        self._select_message_block_actual_index(actual_index)
        self.on_message_block_selected()

    def update_message_block(self) -> None:
        if not self.message_config_doc:
            return
        active_scope = self._active_message_block_scope(warn=True)
        if active_scope is None:
            return
        actual_index = self._selected_message_block_index()
        if actual_index is None:
            messagebox.showwarning("선택 필요", "반영할 블록을 먼저 선택하세요.")
            return
        value = self._message_block_text_value()
        if not value:
            messagebox.showwarning("블록 없음", "블록 내용을 입력하세요.")
            return
        template_name, scope_kind, scope_id = active_scope
        blocks = self.message_config_service.get_blocks(self.message_config_doc, scope_kind, scope_id, template_name)
        blocks[actual_index] = value
        self.message_config_service.set_blocks(self.message_config_doc, scope_kind, scope_id, template_name, blocks)
        self._reset_message_preview_cache("선택 블록을 반영했습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()
        self._select_message_block_actual_index(actual_index)

    def _move_message_block_to(self, source_index: int, target_index: int) -> None:
        if not self.message_config_doc:
            return
        active_scope = self._active_message_block_scope()
        if active_scope is None:
            return
        template_name, scope_kind, scope_id = active_scope
        blocks = self.message_config_service.get_blocks(self.message_config_doc, scope_kind, scope_id, template_name)
        if source_index < 0 or source_index >= len(blocks) or target_index < 0 or target_index >= len(blocks):
            return
        if source_index == target_index:
            return
        item = blocks.pop(source_index)
        blocks.insert(target_index, item)
        self.message_config_service.set_blocks(self.message_config_doc, scope_kind, scope_id, template_name, blocks)
        self._reset_message_preview_cache("블록 순서를 바꿨습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()
        self._select_message_block_actual_index(target_index)
        self.on_message_block_selected()

    def move_message_block(self, delta: int) -> None:
        if not self.message_config_doc:
            return
        if not self._ensure_message_block_reorder_allowed():
            return
        actual_index = self._selected_message_block_index()
        if actual_index is None:
            return
        self._move_message_block_to(actual_index, actual_index + delta)

    def remove_message_block(self) -> None:
        if not self.message_config_doc:
            return
        active_scope = self._active_message_block_scope(warn=True)
        if active_scope is None:
            return
        actual_index = self._selected_message_block_index()
        if actual_index is None:
            return
        template_name, scope_kind, scope_id = active_scope
        blocks = self.message_config_service.get_blocks(self.message_config_doc, scope_kind, scope_id, template_name)
        del blocks[actual_index]
        self.message_config_service.set_blocks(self.message_config_doc, scope_kind, scope_id, template_name, blocks)
        self._reset_message_preview_cache("선택 블록을 삭제했습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()

    def clear_message_blocks(self) -> None:
        if not self.message_config_doc:
            return
        active_scope = self._active_message_block_scope(warn=True)
        if active_scope is None:
            return
        template_name, scope_kind, scope_id = active_scope
        self.message_config_service.set_blocks(self.message_config_doc, scope_kind, scope_id, template_name, [])
        self._reset_message_preview_cache("현재 scope 블록을 비웠습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()

    def _move_message_slot_to(self, source_index: int, target_index: int) -> None:
        if not self.message_config_doc:
            return
        template_name = self.message_template_var.get().strip() or "Initial"
        slot_order = self.message_config_service.get_slot_order(self.message_config_doc, template_name)
        if source_index < 0 or source_index >= len(slot_order) or target_index < 0 or target_index >= len(slot_order):
            return
        if source_index == target_index:
            return
        item = slot_order.pop(source_index)
        slot_order.insert(target_index, item)
        self.message_selected_slot_key = item
        self.message_config_service.set_slot_order(self.message_config_doc, template_name, slot_order)
        self._reset_message_preview_cache("Slot 순서를 바꿨습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()
        self.message_slot_order_list.selection_set(target_index)

    def move_message_slot_order(self, delta: int) -> None:
        if not self.message_config_doc:
            return
        selection = self.message_slot_order_list.curselection()
        if not selection:
            return
        self._move_message_slot_to(selection[0], selection[0] + delta)

    def reset_message_slot_order(self) -> None:
        if not self.message_config_doc:
            return
        self.message_config_service.set_slot_order(self.message_config_doc, self.message_template_var.get().strip() or "Initial", list(DEFAULT_SLOT_ORDER))
        self._reset_message_preview_cache("Slot 순서를 기본값으로 복원했습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()

    def apply_default_fixed_suffix(self) -> None:
        if not self.message_config_doc:
            return
        self.message_config_service.set_default_fixed_suffix(self.message_config_doc, self.default_fixed_text.get("1.0", "end"))
        self._reset_message_preview_cache("기본 고정문구를 반영했습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()

    def on_target_fixed_selection_changed(self, _event: object | None = None) -> None:
        if not self.message_config_doc:
            return
        target_id = self.message_target_suffix_var.get().strip()
        self.target_fixed_text.delete("1.0", "end")
        if target_id:
            self.target_fixed_text.insert("1.0", self.message_config_service.get_target_fixed_suffix(self.message_config_doc, target_id))

    def apply_target_fixed_suffix(self) -> None:
        if not self.message_config_doc:
            return
        target_id = self.message_target_suffix_var.get().strip()
        if not target_id:
            messagebox.showwarning("Target 필요", "Target 고정문구를 적용할 대상을 선택하세요.")
            return
        self.message_config_service.set_target_fixed_suffix(self.message_config_doc, target_id, self.target_fixed_text.get("1.0", "end"))
        self._reset_message_preview_cache("Target 고정문구를 반영했습니다. 편집본 preview를 다시 계산하려면 '미리보기 갱신'을 누르세요.")
        self.render_message_editor()

    def validate_message_editor(self, *, show_dialog: bool = True) -> list[dict[str, str]]:
        if not self.message_config_doc:
            return []
        template_name, scope_kind, scope_id = self._current_message_scope()
        issues = self.message_config_service.validate_document(
            self.message_config_doc,
            template_name=template_name,
            scope_kind=scope_kind,
            scope_id=scope_id,
        )
        self.set_text(self.message_validation_text, self._format_message_validation_lines(issues))
        if self._has_ui_attr("editor_validation_tab"):
            self.editor_right_notebook.select(self.editor_validation_tab)
        if show_dialog:
            error_count = sum(1 for item in issues if item.get("severity") == "error")
            warning_count = sum(1 for item in issues if item.get("severity") == "warning")
            messagebox.showinfo("저장 전 검증", f"error={error_count}, warning={warning_count}, total={len(issues)}")
        return issues

    def copy_current_message_preview(self) -> None:
        initial_preview = self._editor_preview_text("Initial")
        handoff_preview = self._editor_preview_text("Handoff")
        payload = "[Initial]\n{0}\n\n[Handoff]\n{1}".format(initial_preview, handoff_preview)
        self._copy_to_clipboard(payload)
        self.message_editor_status_var.set("현재 문맥 preview를 클립보드에 복사했습니다.")

    def copy_current_final_delivery_preview(self) -> None:
        self._copy_to_clipboard(self._editor_final_delivery_text())
        self.message_editor_status_var.set("현재 target 최종 전달문을 클립보드에 복사했습니다.")

    def copy_current_path_summary(self) -> None:
        self._copy_to_clipboard(self._editor_path_summary_text())
        self.message_editor_status_var.set("현재 target 경로 요약을 클립보드에 복사했습니다.")

    def _editor_row_folder_path(self, kind: str) -> str:
        row, _source_kind, _payload = self._editor_preview_row_and_source()
        if not row:
            return ""
        if kind == "own":
            return str(row.get("OwnTargetFolder", "") or row.get("PairTargetFolder", "") or "")
        if kind == "partner":
            return str(row.get("PartnerTargetFolder", "") or row.get("PartnerFolder", "") or "")
        return ""

    def _open_editor_row_folder(self, kind: str, label: str) -> None:
        path_value = self._editor_row_folder_path(kind)
        if not path_value:
            messagebox.showwarning("경로 없음", f"{label} 경로를 찾지 못했습니다.")
            return
        try:
            os.startfile(path_value)
        except FileNotFoundError:
            messagebox.showwarning("경로 없음", path_value)
            return
        self.set_text(self.output_text, f"{label} 열기:\n{path_value}")

    def open_current_message_target_folder(self) -> None:
        self._open_editor_row_folder("own", "내 작업 폴더")

    def open_current_message_partner_folder(self) -> None:
        self._open_editor_row_folder("partner", "상대 작업 폴더")

    def on_message_block_press(self, event: tk.Event) -> None:
        if not self._ensure_message_block_reorder_allowed():
            self.message_block_drag_index = None
            return
        visible_index = self.message_blocks_list.nearest(event.y)
        if visible_index < 0 or visible_index >= len(self.message_block_visible_indexes):
            self.message_block_drag_index = None
            return
        self.message_block_drag_index = self.message_block_visible_indexes[visible_index]

    def on_message_block_drag(self, event: tk.Event) -> None:
        if self.message_block_drag_index is None:
            return
        visible_index = self.message_blocks_list.nearest(event.y)
        if visible_index < 0 or visible_index >= len(self.message_block_visible_indexes):
            return
        target_index = self.message_block_visible_indexes[visible_index]
        if target_index != self.message_block_drag_index:
            self._move_message_block_to(self.message_block_drag_index, target_index)
            self.message_block_drag_index = target_index

    def on_message_block_release(self, _event: tk.Event) -> None:
        self.message_block_drag_index = None

    def on_message_slot_press(self, event: tk.Event) -> None:
        self.message_slot_drag_index = self.message_slot_order_list.nearest(event.y)

    def on_message_slot_drag(self, event: tk.Event) -> None:
        if self.message_slot_drag_index is None:
            return
        target_index = self.message_slot_order_list.nearest(event.y)
        if target_index != self.message_slot_drag_index:
            self._move_message_slot_to(self.message_slot_drag_index, target_index)
            self.message_slot_drag_index = target_index

    def on_message_slot_release(self, _event: tk.Event) -> None:
        self.message_slot_drag_index = None
        self.on_message_slot_selected()

    def show_message_editor_diff(self) -> None:
        if not self.message_config_doc:
            return
        self.set_text(
            self.message_diff_text,
            self._message_diff_summary_text()
            + "\n\n"
            + self.message_config_service.diff_text(self.message_config_original or self.message_config_doc, self.message_config_doc),
        )
        if self._has_ui_attr("editor_diff_tab"):
            self.editor_right_notebook.select(self.editor_diff_tab)

    def _selected_message_backup_path(self) -> Path | None:
        if not self._has_ui_attr("message_backup_list"):
            return None
        selection = self.message_backup_list.curselection()
        if not selection:
            return None
        index = int(selection[0])
        if index < 0 or index >= len(self.message_backup_paths):
            return None
        return self.message_backup_paths[index]

    def refresh_message_backup_list(self) -> None:
        if not self._has_ui_attr("message_backup_list"):
            return
        selected_path = str(self._selected_message_backup_path() or "")
        backups = self.message_config_service.list_backups(self.config_path_var.get().strip())
        self.message_backup_paths = backups[:24]
        self.message_backup_list.delete(0, "end")
        for path in self.message_backup_paths:
            modified = datetime.fromtimestamp(path.stat().st_mtime).strftime("%m-%d %H:%M:%S")
            self.message_backup_list.insert("end", f"{modified}  {path.name}")
        if self.message_backup_paths:
            select_index = 0
            if selected_path:
                for index, path in enumerate(self.message_backup_paths):
                    if str(path) == selected_path:
                        select_index = index
                        break
            self.message_backup_list.selection_set(select_index)
            self._render_message_backup_detail(self.message_backup_paths[select_index], include_diff_summary=False)
        else:
            self.set_text(self.message_backup_text, "최근 백업:\n(없음)")

    def _render_message_backup_detail(self, path: Path, *, include_diff_summary: bool) -> None:
        stat = path.stat()
        lines = [
            "선택 백업",
            f"- 파일: {path.name}",
            f"- 경로: {path}",
            f"- 수정 시각: {datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S')}",
            f"- 크기: {stat.st_size:,} bytes",
        ]
        if include_diff_summary:
            try:
                backup_document = self.message_config_service.load_config_document(str(path))
            except Exception as exc:
                lines.extend(["", f"백업 로드 실패: {exc}"])
                self.set_text(self.message_backup_text, "\n".join(lines))
                return
            compare_document = self.message_config_original or self.message_config_doc or backup_document
            summary = self.message_config_service.diff_summary(backup_document, compare_document)
            lines.extend(
                [
                    "",
                    "현재 저장본 대비 요약:",
                    f"- slot 순서 변경: {summary['slot_order_changes']}",
                    f"- 블록 scope 변경: {summary['block_scope_changes']}",
                    f"- 추가 블록: {summary['added_blocks']}",
                    f"- 삭제 블록: {summary['removed_blocks']}",
                    f"- 수정 블록: {summary['updated_blocks']}",
                    f"- 고정문구 변경: {summary['fixed_suffix_changes']}",
                ]
            )
        self.set_text(self.message_backup_text, "\n".join(lines))

    def on_message_backup_selected(self, _event: object | None = None) -> None:
        path = self._selected_message_backup_path()
        if path is None:
            self.set_text(self.message_backup_text, "최근 백업:\n(선택 없음)")
            return
        self._render_message_backup_detail(path, include_diff_summary=True)

    def show_selected_backup_diff(self, *, compare_to: str) -> None:
        path = self._selected_message_backup_path()
        if path is None:
            messagebox.showwarning("선택 필요", "비교할 백업을 먼저 선택하세요.")
            return
        try:
            backup_document = self.message_config_service.load_config_document(str(path))
        except Exception as exc:
            messagebox.showerror("백업 로드 실패", str(exc))
            return
        if compare_to == "current":
            compare_document = self.message_config_doc or backup_document
            compare_label = "현재 편집본"
        else:
            compare_document = self.message_config_original or self.message_config_doc or backup_document
            compare_label = "현재 저장본"
        summary = self.message_config_service.diff_summary(backup_document, compare_document)
        diff_text = self.message_config_service.diff_text(backup_document, compare_document)
        header = "\n".join(
            [
                f"백업 diff: {path.name} -> {compare_label}",
                f"- slot 순서 변경: {summary['slot_order_changes']}",
                f"- 블록 scope 변경: {summary['block_scope_changes']}",
                f"- 추가 블록: {summary['added_blocks']}",
                f"- 삭제 블록: {summary['removed_blocks']}",
                f"- 수정 블록: {summary['updated_blocks']}",
                f"- 고정문구 변경: {summary['fixed_suffix_changes']}",
            ]
        )
        self.set_text(self.message_diff_text, header + "\n\n" + diff_text)
        if self._has_ui_attr("editor_diff_tab"):
            self.editor_right_notebook.select(self.editor_diff_tab)

    def copy_selected_message_backup_path(self) -> None:
        path = self._selected_message_backup_path()
        if path is None:
            messagebox.showwarning("선택 필요", "경로를 복사할 백업을 먼저 선택하세요.")
            return
        self._copy_to_clipboard(str(path))
        self.message_editor_status_var.set(f"백업 경로 복사 완료: {path.name}")

    def _confirm_message_editor_save(self, issues: list[dict[str, str]]) -> bool:
        impact = self._message_impact_summary()
        impact_text = self._message_impact_summary_text(impact)
        summary_text = self._message_diff_summary_text()
        warning_count = sum(1 for item in issues if item.get("severity") == "warning")
        fresh_text = "최신" if impact.get("preview_is_fresh") else "stale"
        message_lines = [
            impact_text,
            "",
            summary_text,
            "",
            f"검증 warning: {warning_count}",
            f"preview freshness: {fresh_text}",
        ]
        if not impact.get("preview_is_fresh"):
            message_lines.append("현재 preview가 최신 편집본 기준으로 갱신되지 않았습니다. 그대로 저장할지 다시 확인하세요.")
        return messagebox.askyesno("저장 영향 확인", "\n".join(message_lines), parent=self)

    def reset_message_editor_changes(self) -> None:
        if not self.message_config_original:
            return
        self.message_config_doc = self.message_config_service.clone_document(self.message_config_original)
        self._reset_message_preview_cache(
            "편집 초안을 마지막 저장 상태로 되돌렸습니다. 저장된 effective config 기준 preview로 다시 표시합니다.",
            dirty=False,
        )
        self.render_message_editor()

    def save_message_editor(self) -> None:
        if not self.message_config_doc:
            messagebox.showwarning("설정 없음", "먼저 설정 문서를 불러오세요.")
            return
        save_allowed, save_detail = self._message_editor_save_allowed()
        if not save_allowed:
            messagebox.showwarning("저장 대기", save_detail)
            self._refresh_message_editor_action_buttons()
            return
        issues = self.validate_message_editor(show_dialog=False)
        blocking = [item for item in issues if item.get("severity") == "error"]
        warnings = [item for item in issues if item.get("severity") == "warning"]
        if blocking:
            messagebox.showwarning("저장 차단", "error 항목이 있어 저장할 수 없습니다. 검증 탭을 먼저 확인하세요.")
            return
        if not self._confirm_message_editor_save(issues):
            return
        config_path = self.config_path_var.get().strip()
        try:
            backup_path = self.message_config_service.save_document(config_path, self.message_config_doc)
        except Exception as exc:
            messagebox.showerror("설정 저장 실패", str(exc))
            self.message_editor_status_var.set(f"설정 저장 실패: {exc}")
            return
        self.message_editor_status_var.set(f"저장 완료 / 백업: {backup_path}")
        self.load_message_editor_document()
        self.load_effective_config()

    def rollback_message_editor(self) -> None:
        config_path = self.config_path_var.get().strip()
        if not config_path:
            return
        confirmed = messagebox.askyesno("롤백 확인", "마지막 설정 백업으로 롤백할까요? 현재 설정은 pre-rollback 백업으로 한 번 더 저장됩니다.", parent=self)
        if not confirmed:
            return
        try:
            backup_path = self.message_config_service.rollback_last_backup(config_path)
        except Exception as exc:
            messagebox.showerror("롤백 실패", str(exc))
            self.message_editor_status_var.set(f"롤백 실패: {exc}")
            return
        self.message_editor_status_var.set(f"롤백 완료 / 복원: {backup_path}")
        self.load_message_editor_document()
        self.load_effective_config()

    def _target_board_items(self) -> list[dict[str, str]]:
        target_ids = self.message_config_service.target_ids(self.message_config_doc or {}) or BOARD_TARGET_FALLBACK
        relay_map = {str(item.get("TargetId", "")): item for item in (self.relay_status_data or {}).get("Targets", [])}
        visibility_map = {str(item.get("TargetId", "")): item for item in (self.visibility_status_data or {}).get("Targets", [])}
        preview_map = {str(item.get("TargetId", "")): item for item in self.preview_rows}
        items: list[dict[str, str]] = []
        for target_id in target_ids:
            runtime = relay_map.get(target_id, {})
            visibility = visibility_map.get(target_id, {})
            preview_row = preview_map.get(target_id, {})
            target_status = self._paired_target_status_row(target_id)
            runtime_title = str(visibility.get("RuntimeTitle", "") or "")
            pair_id = str(preview_row.get("PairId", "") or "")
            role_name = str(preview_row.get("RoleName", "") or "")
            partner_target_id = str(preview_row.get("PartnerTargetId", "") or "")
            if not pair_id or not role_name:
                match = re.search(r"(pair\d{2})-(top|bottom)", runtime_title)
                pair_id = pair_id or (match.group(1) if match else "")
                role_name = role_name or (match.group(2) if match else "")
            if not partner_target_id and pair_id:
                for candidate in self.preview_rows:
                    if str(candidate.get("PairId", "") or "") != pair_id:
                        continue
                    candidate_target = str(candidate.get("TargetId", "") or "")
                    if candidate_target and candidate_target != target_id:
                        partner_target_id = candidate_target
                        break
            items.append(
                {
                    "TargetId": target_id,
                    "PairId": pair_id,
                    "RoleName": role_name,
                    "PartnerTargetId": partner_target_id,
                    "RuntimePresent": "예" if visibility.get("RuntimePresent", False) else "아니오",
                    "Injectable": "예" if visibility.get("Injectable", False) else "아니오",
                    "RuntimeTitle": runtime_title,
                    "RegistrationMode": str(visibility.get("RegistrationMode", "") or runtime.get("RegistrationMode", "")),
                    "Hwnd": str(visibility.get("RuntimeHwnd", "") or runtime.get("Hwnd", "")),
                    "ShellPid": str(visibility.get("RuntimeShellPid", "") or runtime.get("ShellPid", "")),
                    "WindowTitle": str((self.message_config_service.target_map(self.message_config_doc or {}).get(target_id, {}) or {}).get("WindowTitle", "")),
                    "SourceOutboxSummary": self._source_outbox_preview_summary(preview_row, target_status=target_status),
                }
            )
        return items

    def render_target_board(self) -> None:
        if not self._has_ui_attr("board_grid"):
            return
        items = self._target_board_items()
        selected_target = self._selected_inspection_target_id()
        selected_pair = self._selected_inspection_pair_id()
        action_pair = self._selected_pair_id()
        action_target = self.target_id_var.get().strip()
        self.board_status_var.set(
            self._board_status_text(
                items=items,
                selected_target=selected_target,
                selected_pair=selected_pair,
                action_pair=action_pair,
                action_target=action_target,
                inspection_source=self._selected_inspection_context_state().source,
            )
        )
        self.update_pair_button_states()

        for child in self.board_grid.winfo_children():
            child.destroy()
        self.target_board_cells.clear()

        for index, item in enumerate(items):
            row = index // 4
            column = index % 4
            is_selected = item["TargetId"] == selected_target
            is_selected_pair = bool(selected_pair) and item["PairId"] == selected_pair
            if item["RuntimePresent"] != "예":
                background = "#e5e7eb"
            elif item["Injectable"] == "예":
                background = "#dcfce7"
            else:
                background = "#fde68a"
            border = "#2563eb" if is_selected else ("#0f766e" if is_selected_pair else "#94a3b8")
            thickness = 4 if is_selected else (3 if is_selected_pair else 2)
            frame = tk.Frame(self.board_grid, bg=background, bd=1, relief="solid", highlightthickness=thickness, highlightbackground=border)
            frame.grid(row=row, column=column, sticky="nsew", padx=8, pady=8)
            title = f"{item['TargetId']}  {item['PairId'] or '-'} {item['RoleName'] or ''}".strip()
            labels = [
                tk.Label(frame, text=title, bg=background, anchor="w", font=("Segoe UI", 11, "bold")),
                tk.Label(frame, text=f"partner={item['PartnerTargetId'] or '-'} / attach={item['RuntimePresent']} / injectable={item['Injectable']}", bg=background, anchor="w"),
                tk.Label(frame, text=f"outbox={item['SourceOutboxSummary']}", bg=background, anchor="w", justify="left", wraplength=280),
                tk.Label(frame, text=f"mode={item['RegistrationMode'] or '-'} / hwnd={item['Hwnd'] or '-'}", bg=background, anchor="w"),
                tk.Label(frame, text=f"shell={item['ShellPid'] or '-'}", bg=background, anchor="w"),
                tk.Label(frame, text=item["WindowTitle"] or item["RuntimeTitle"] or "(window title 없음)", bg=background, anchor="w", justify="left", wraplength=280),
            ]
            for label_index, label in enumerate(labels):
                label.grid(row=label_index, column=0, sticky="ew", padx=10, pady=(8 if label_index == 0 else 0, 4))
                label.bind("<Button-1>", lambda _event, target=item["TargetId"], pair=item["PairId"]: self.select_target_from_board(target, pair))
            frame.bind("<Button-1>", lambda _event, target=item["TargetId"], pair=item["PairId"]: self.select_target_from_board(target, pair))
            self.target_board_cells[item["TargetId"]] = {"frame": frame, "item": item}

    def select_target_from_board(self, target_id: str, pair_id: str = "") -> None:
        self._set_inspection_context(
            pair_id=pair_id or self._stored_inspection_context_state().pair_id,
            target_id=target_id,
            source="board-target",
        )
        role_name = ""
        matched = False
        for index, row in enumerate(self.preview_rows):
            if row.get("TargetId", "") == target_id:
                role_name = str(row.get("RoleName", "") or "")
                self._set_inspection_context(
                    pair_id=pair_id or str(row.get("PairId", "") or "") or self._stored_inspection_context_state().pair_id,
                    target_id=target_id,
                    source="board-target",
                    row_index=index,
                )
                self._apply_message_filter_reset_policy("board_target_change")
                self._apply_editor_context_for_target(
                    pair_id=pair_id or str(row.get("PairId", "") or "") or self._selected_pair_id(),
                    role_name=role_name,
                    target_id=target_id,
                )
                self.row_tree.selection_set(str(index))
                self.on_row_selected(source="board-target")
                matched = True
                break
        if not matched:
            if not self._stored_inspection_context_state().pair_id:
                self._set_inspection_context(pair_id=pair_id or self._selected_pair_id(), target_id=target_id, source="board-target")
            for row in self.preview_rows:
                if row.get("TargetId", "") == target_id:
                    role_name = str(row.get("RoleName", "") or "")
                    break
            self._apply_message_filter_reset_policy("board_target_change")
            self._apply_editor_context_for_target(
                pair_id=self._stored_inspection_context_state().pair_id or self._selected_pair_id(),
                role_name=role_name,
                target_id=target_id,
            )
            self._sync_message_scope_id_from_context()
            self.render_target_board()
            self.render_message_editor()
            if self._artifact_home_browse_target_scope_enabled():
                self._sync_artifact_filters_with_home_pair_selection(refresh=self._has_ui_attr("artifact_tree"))
            self.update_pair_button_states()
            self.rebuild_panel_state()

    def _build_ui(self) -> None:
        self.columnconfigure(0, weight=1)
        self.columnconfigure(1, weight=0)
        self.rowconfigure(1, weight=3)
        self.rowconfigure(2, weight=1)

        controls = ttk.Frame(self, padding=10)
        controls.grid(row=0, column=0, sticky="ew")
        controls.columnconfigure(1, weight=1)
        controls.columnconfigure(5, weight=0)
        controls.columnconfigure(6, weight=0)
        controls.columnconfigure(7, weight=0)

        ttk.Label(controls, text="설정").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.config_combo = ttk.Combobox(
            controls,
            textvariable=self.config_path_var,
            values=existing_config_presets(),
        )
        self.config_combo.grid(row=0, column=1, columnspan=3, sticky="ew")
        ttk.Button(controls, text="찾아보기", command=self.browse_config).grid(row=0, column=4, padx=(8, 0))
        ttk.Button(controls, text="빠른 새로고침", command=self.refresh_quick_status).grid(row=0, column=5, sticky="e", padx=(8, 0))
        ttk.Button(controls, text="전체 새로고침", command=self.load_effective_config).grid(row=0, column=6, sticky="e", padx=(8, 0))
        ttk.Checkbutton(controls, text="간단 모드", variable=self.simple_mode_var, command=self.toggle_simple_mode).grid(row=0, column=7, sticky="e", padx=(8, 0))
        ttk.Button(controls, textvariable=self.header_toggle_button_var, command=self.toggle_header_compact).grid(row=0, column=8, sticky="e", padx=(8, 0))

        ttk.Label(controls, textvariable=self.run_root_label_var).grid(row=1, column=0, sticky="w", padx=(0, 8), pady=(8, 0))
        ttk.Entry(controls, textvariable=self.run_root_var).grid(row=1, column=1, sticky="ew", pady=(8, 0))
        ttk.Label(controls, textvariable=self.run_root_status_var).grid(row=1, column=2, sticky="w", padx=(8, 0), pady=(8, 0))
        ttk.Button(controls, text="입력 비우기", command=self.clear_run_root_input).grid(row=1, column=3, sticky="ew", padx=(8, 0), pady=(8, 0))
        ttk.Label(controls, text="Pair").grid(row=1, column=4, sticky="e", padx=(8, 8), pady=(8, 0))
        ttk.Combobox(controls, textvariable=self.pair_id_var, values=["", "pair01", "pair02", "pair03", "pair04"], width=12).grid(row=1, column=5, sticky="ew", pady=(8, 0))
        ttk.Label(controls, text="대상").grid(row=1, column=6, sticky="e", padx=(12, 8), pady=(8, 0))
        ttk.Combobox(controls, textvariable=self.target_id_var, values=["", "target01", "target02", "target03", "target04", "target05", "target06", "target07", "target08"], width=12).grid(row=1, column=7, sticky="ew", pady=(8, 0))

        context_frame = ttk.LabelFrame(controls, text="현재 실행 문맥", padding=8)
        context_frame.grid(row=2, column=0, columnspan=9, sticky="ew", pady=(10, 0))
        for index in range(5):
            context_frame.columnconfigure(index, weight=1)
        ttk.Label(context_frame, text="실행 대상", font=("Segoe UI", 9, "bold")).grid(row=0, column=0, sticky="w")
        ttk.Label(context_frame, text="보고 있는 대상", font=("Segoe UI", 9, "bold")).grid(row=0, column=1, sticky="w", padx=(8, 0))
        ttk.Label(context_frame, text="RunRoot", font=("Segoe UI", 9, "bold")).grid(row=0, column=2, sticky="w", padx=(8, 0))
        ttk.Label(context_frame, text="watcher / runtime", font=("Segoe UI", 9, "bold")).grid(row=0, column=3, sticky="w", padx=(8, 0))
        ttk.Label(context_frame, text="다음 해야 할 일", font=("Segoe UI", 9, "bold")).grid(row=0, column=4, sticky="w", padx=(8, 0))
        ttk.Label(context_frame, textvariable=self.sticky_action_context_var, wraplength=220, justify="left").grid(row=1, column=0, sticky="w")
        ttk.Label(context_frame, textvariable=self.sticky_inspection_context_var, wraplength=220, justify="left").grid(row=1, column=1, sticky="w", padx=(8, 0))
        ttk.Label(context_frame, textvariable=self.sticky_run_root_context_var, wraplength=260, justify="left").grid(row=1, column=2, sticky="w", padx=(8, 0))
        ttk.Label(context_frame, textvariable=self.sticky_runtime_context_var, wraplength=260, justify="left").grid(row=1, column=3, sticky="w", padx=(8, 0))
        ttk.Label(context_frame, textvariable=self.sticky_next_step_var, wraplength=260, justify="left").grid(row=1, column=4, sticky="w", padx=(8, 0))
        sticky_context_badge_label = tk.Label(
            context_frame,
            textvariable=self.sticky_context_badge_var,
            bg="#6B7280",
            fg="#FFFFFF",
            padx=8,
            pady=3,
        )
        sticky_context_badge_label.grid(row=2, column=0, sticky="w", pady=(8, 0))
        self.sticky_context_badge_label = sticky_context_badge_label
        sticky_artifact_browse_label = tk.Label(
            context_frame,
            textvariable=self.sticky_artifact_browse_var,
            bg="#A855F7",
            fg="#FFFFFF",
            padx=8,
            pady=3,
        )
        sticky_artifact_browse_label.grid(row=2, column=2, sticky="w", padx=(8, 0), pady=(8, 0))
        sticky_artifact_browse_label.grid_remove()
        self.sticky_artifact_browse_label = sticky_artifact_browse_label
        sticky_result_panel_label = tk.Label(
            context_frame,
            textvariable=self.sticky_result_panel_var,
            bg="#6B7280",
            fg="#FFFFFF",
            padx=8,
            pady=3,
        )
        sticky_result_panel_label.grid(row=2, column=3, sticky="w", padx=(8, 0), pady=(8, 0))
        self.sticky_result_panel_label = sticky_result_panel_label
        sticky_apply_context_button = ttk.Button(
            context_frame,
            text="보고 대상 실행 기준 반영",
            command=self.apply_selected_inspection_context,
        )
        sticky_apply_context_button.grid(row=2, column=1, sticky="w", padx=(8, 0), pady=(8, 0))
        self.sticky_apply_context_button = sticky_apply_context_button
        sticky_next_action_button = ttk.Button(
            context_frame,
            textvariable=self.sticky_next_action_button_var,
            command=self.run_sticky_recommended_action,
        )
        sticky_next_action_button.grid(row=2, column=4, sticky="w", padx=(8, 0), pady=(8, 0))
        self.sticky_next_action_button = sticky_next_action_button

        pair_focus_frame = ttk.LabelFrame(controls, text="현재 실행 Pair", padding=8)
        pair_focus_frame.grid(row=3, column=0, columnspan=9, sticky="ew", pady=(10, 0))
        pair_focus_frame.columnconfigure(1, weight=1)
        pair_focus_badge_label = tk.Label(
            pair_focus_frame,
            textvariable=self.pair_focus_badge_var,
            bg="#6B7280",
            fg="#FFFFFF",
            padx=8,
            pady=3,
        )
        pair_focus_badge_label.grid(row=0, column=0, sticky="w")
        self.pair_focus_badge_label = pair_focus_badge_label
        ttk.Label(pair_focus_frame, textvariable=self.pair_focus_summary_var, font=("Segoe UI", 9, "bold")).grid(row=0, column=1, sticky="w", padx=(8, 0))
        ttk.Label(pair_focus_frame, textvariable=self.pair_focus_detail_var, wraplength=1180, justify="left").grid(row=1, column=0, columnspan=2, sticky="w", pady=(6, 0))

        header_details_frame = ttk.Frame(controls)
        header_details_frame.grid(row=4, column=0, columnspan=9, sticky="ew", pady=(10, 0))
        header_details_frame.columnconfigure(0, weight=1)
        self.header_details_frame = header_details_frame

        ttk.Label(header_details_frame, textvariable=self.run_root_help_var, wraplength=1180, justify="left").grid(row=0, column=0, sticky="w")

        last_command_row = ttk.Frame(header_details_frame)
        last_command_row.grid(row=1, column=0, sticky="ew", pady=(8, 0))
        last_command_row.columnconfigure(1, weight=1)
        ttk.Label(last_command_row, text="마지막 명령").grid(row=0, column=0, sticky="w", padx=(0, 8))
        ttk.Entry(last_command_row, textvariable=self.last_command_var, state="readonly").grid(row=0, column=1, sticky="ew")
        ttk.Button(last_command_row, text="명령 복사", command=self.copy_last_command).grid(row=0, column=2, sticky="e", padx=(8, 0))

        status_frame = ttk.LabelFrame(header_details_frame, text="운영 상태", padding=8)
        status_frame.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        status_frame.columnconfigure(1, weight=1)
        ttk.Label(status_frame, text="MODE").grid(row=0, column=0, sticky="w", padx=(0, 8))
        ttk.Label(status_frame, textvariable=self.mode_banner_var, font=("Segoe UI", 10, "bold")).grid(row=0, column=1, sticky="w")
        ttk.Label(status_frame, textvariable=self.mode_banner_detail_var, wraplength=1100, justify="left").grid(row=1, column=1, sticky="w", pady=(6, 0))
        ttk.Label(status_frame, text="상태").grid(row=2, column=0, sticky="w", padx=(0, 8), pady=(6, 0))
        ttk.Label(status_frame, textvariable=self.operator_status_var).grid(row=2, column=1, sticky="w", pady=(6, 0))
        ttk.Label(status_frame, text="안내").grid(row=3, column=0, sticky="nw", padx=(0, 8), pady=(6, 0))
        ttk.Label(status_frame, textvariable=self.operator_hint_var, wraplength=1100, justify="left").grid(row=3, column=1, sticky="w", pady=(6, 0))
        ttk.Label(status_frame, textvariable=self.last_result_var, wraplength=1100, justify="left").grid(row=4, column=0, columnspan=2, sticky="w", pady=(6, 0))
        ttk.Label(status_frame, textvariable=self.last_query_result_var, wraplength=1100, justify="left").grid(row=5, column=0, columnspan=2, sticky="w", pady=(6, 0))

        notebook = ttk.Notebook(self)
        notebook.grid(row=1, column=0, sticky="nsew", padx=10, pady=(0, 10))
        notebook.bind("<<NotebookTabChanged>>", self.on_notebook_tab_changed)
        self.notebook = notebook

        result_frame = ttk.LabelFrame(self, text="하단 공용 패널 / 작업 · 조회 결과", padding=8)
        result_frame.grid(row=2, column=0, sticky="nsew", padx=10, pady=(0, 10))
        result_frame.columnconfigure(0, weight=1)
        result_frame.rowconfigure(1, weight=1)
        self.result_frame = result_frame
        result_header = ttk.Frame(result_frame)
        result_header.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        result_header.columnconfigure(0, weight=1)
        ttk.Label(
            result_header,
            textvariable=self.result_panel_context_var,
            justify="left",
            wraplength=980,
        ).grid(row=0, column=0, sticky="w")
        result_header_actions = ttk.Frame(result_header)
        result_header_actions.grid(row=0, column=1, rowspan=2, sticky="ne")
        ttk.Button(result_header_actions, textvariable=self.result_toggle_button_var, command=self.toggle_result_panel).grid(row=0, column=0, sticky="e")
        ttk.Button(result_header_actions, textvariable=self.result_dock_button_var, command=self.toggle_result_panel_dock).grid(row=0, column=1, sticky="e", padx=(8, 0))
        ttk.Label(
            result_header,
            textvariable=self.query_history_var,
            wraplength=980,
            justify="left",
        ).grid(row=1, column=0, sticky="w", pady=(6, 0))
        ttk.Label(
            result_header,
            textvariable=self.result_panel_status_var,
            wraplength=980,
            justify="left",
        ).grid(row=2, column=0, sticky="w", pady=(6, 0))
        result_body_frame = ttk.Frame(result_frame)
        result_body_frame.grid(row=1, column=0, sticky="nsew")
        result_body_frame.columnconfigure(0, weight=1)
        result_body_frame.rowconfigure(0, weight=1)
        self.result_body_frame = result_body_frame
        self.result_notebook = ttk.Notebook(result_body_frame)
        self.result_notebook.grid(row=0, column=0, sticky="nsew")
        self.ops_result_notebook = self.result_notebook
        action_output_tab = ttk.Frame(self.result_notebook, padding=6)
        action_output_tab.columnconfigure(0, weight=1)
        action_output_tab.rowconfigure(0, weight=1)
        self.result_notebook.add(action_output_tab, text="작업 출력")
        self.output_text = scrolledtext.ScrolledText(action_output_tab, wrap="word")
        self.output_text.grid(row=0, column=0, sticky="nsew")
        self.query_output_tab = ttk.Frame(self.result_notebook, padding=6)
        self.query_output_tab.columnconfigure(0, weight=1)
        self.query_output_tab.rowconfigure(0, weight=1)
        self.result_notebook.add(self.query_output_tab, text="조회 결과")
        self.query_output_text = scrolledtext.ScrolledText(self.query_output_tab, wrap="word")
        self.query_output_text.grid(row=0, column=0, sticky="nsew")

        home_tab_container, home_tab = self._create_scrollable_tab(notebook, title="홈")
        self.home_tab = home_tab_container
        home_tab.columnconfigure(0, weight=1)
        home_tab.rowconfigure(4, weight=1)

        home_header = ttk.LabelFrame(home_tab, text="현재 문맥", padding=8)
        home_header.grid(row=0, column=0, sticky="ew")
        home_header.columnconfigure(0, weight=1)
        home_header.columnconfigure(1, weight=1)
        ttk.Label(home_header, textvariable=self.home_context_var, justify="left").grid(row=0, column=0, sticky="w")
        ttk.Label(home_header, textvariable=self.home_updated_at_var, justify="left").grid(row=0, column=1, sticky="e")
        ttk.Label(home_header, textvariable=self.home_overall_var, font=("Segoe UI", 11, "bold")).grid(row=1, column=0, sticky="w", pady=(6, 0))
        ttk.Label(home_header, textvariable=self.home_overall_detail_var, wraplength=1200, justify="left").grid(row=2, column=0, columnspan=2, sticky="w", pady=(4, 0))

        cards_frame = ttk.Frame(home_tab)
        cards_frame.grid(row=1, column=0, sticky="ew", pady=(10, 0))
        cards_per_row = 4
        for column in range(cards_per_row):
            cards_frame.columnconfigure(column, weight=1)
        for idx, key_title in enumerate(
            [
                ("windows", "세션 창 준비"),
                ("attach", "Attach 상태"),
                ("visibility", "입력 가능"),
                ("router", "라우터"),
                ("runroot", "RunRoot"),
                ("warning", "경고"),
                ("acceptance", "Visible Receipt"),
            ]
        ):
            key, title = key_title
            card_row = idx // cards_per_row
            card_column = idx % cards_per_row
            frame = ttk.LabelFrame(cards_frame, text=title, padding=8)
            frame.grid(
                row=card_row,
                column=card_column,
                sticky="nsew",
                padx=(0, 8) if card_column < cards_per_row - 1 else (0, 0),
                pady=(0, 8) if card_row == 0 else (0, 0),
            )
            value_var = tk.StringVar(value="-")
            detail_var = tk.StringVar(value="-")
            ttk.Label(frame, textvariable=value_var, font=("Segoe UI", 12, "bold")).grid(row=0, column=0, sticky="w")
            ttk.Label(frame, textvariable=detail_var, wraplength=240, justify="left").grid(row=1, column=0, sticky="w", pady=(4, 0))
            self.home_card_vars[key] = {"value": value_var, "detail": detail_var}

        stage_frame = ttk.LabelFrame(home_tab, text="단계 진행판", padding=8)
        stage_frame.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        stage_frame.columnconfigure(1, weight=1)
        for row_index, (key, title, button_label) in enumerate(
            [
                ("launch_windows", "1. 세션 창 준비", "8창 열기"),
                ("attach_windows", "2. 바인딩 attach", "붙이기"),
                ("check_visibility", "3. 입력 가능 확인", "입력 점검"),
                ("prepare_run_root", "4. RunRoot 준비", "run 준비"),
                ("pair_action", "5. Headless Drill 준비", "선택 Pair Headless Drill"),
            ]
        ):
            status_var = tk.StringVar(value="상태: -")
            detail_var = tk.StringVar(value="-")
            ttk.Label(stage_frame, text=title).grid(row=row_index, column=0, sticky="nw", padx=(0, 12), pady=(0, 8))
            info_frame = ttk.Frame(stage_frame)
            info_frame.grid(row=row_index, column=1, sticky="ew", pady=(0, 8))
            info_frame.columnconfigure(0, weight=1)
            ttk.Label(info_frame, textvariable=status_var, font=("Segoe UI", 10, "bold")).grid(row=0, column=0, sticky="w")
            ttk.Label(info_frame, textvariable=detail_var, wraplength=720, justify="left").grid(row=1, column=0, sticky="w")
            button = ttk.Button(stage_frame, text=button_label, command=lambda action_key=key: self.handle_dashboard_action(action_key))
            button.grid(row=row_index, column=2, sticky="e", pady=(0, 8))
            self.long_task_widgets.append(button)
            self.home_stage_vars[key] = {"status": status_var, "detail": detail_var}
            self.home_stage_buttons[key] = button

        home_info = ttk.Frame(home_tab)
        home_info.grid(row=3, column=0, sticky="nsew", pady=(10, 0))
        home_info.columnconfigure(0, weight=1)
        home_info.columnconfigure(1, weight=1)

        self.home_next_actions_frame = ttk.LabelFrame(home_info, text="다음 해야 할 일", padding=8)
        self.home_next_actions_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        self.home_next_actions_frame.columnconfigure(0, weight=1)

        self.home_issue_frame = ttk.LabelFrame(home_info, text="복구 / 점검", padding=8)
        self.home_issue_frame.grid(row=0, column=1, sticky="nsew")
        self.home_issue_frame.columnconfigure(0, weight=1)

        pair_frame = ttk.LabelFrame(home_tab, text="Pair 요약", padding=8)
        pair_frame.grid(row=4, column=0, sticky="nsew", pady=(10, 0))
        pair_frame.columnconfigure(0, weight=1)
        pair_frame.rowconfigure(0, weight=1)

        self.home_pair_tree = ttk.Treeview(
            pair_frame,
            columns=("pair", "targets", "enabled", "latest", "phase", "rt", "next", "zip", "fail"),
            show="headings",
            height=6,
        )
        for column, heading, width in (
            ("pair", "Pair", 90),
            ("targets", "Targets", 180),
            ("enabled", "활성", 70),
            ("latest", "상태", 180),
            ("phase", "단계", 150),
            ("rt", "왕복", 70),
            ("next", "다음", 150),
            ("zip", "Zip", 70),
            ("fail", "Fail", 70),
        ):
            self.home_pair_tree.heading(column, text=heading)
            self.home_pair_tree.column(column, width=width, stretch=(column in {"targets", "latest", "phase", "next"}))
        self.home_pair_tree.grid(row=0, column=0, sticky="nsew")
        self.home_pair_tree.bind("<<TreeviewSelect>>", self.on_home_pair_selected)

        pair_actions = ttk.Frame(pair_frame)
        pair_actions.grid(row=1, column=0, sticky="ew", pady=(8, 0))
        for column in range(3):
            pair_actions.columnconfigure(column, weight=1)

        home_action_groups = [
            (
                "지금 시작",
                [
                    ("선택 Pair로 맞추기", self.apply_selected_home_pair, "home_apply_pair_button"),
                    ("선택 Pair 실행", self.run_selected_pair_drill, "home_run_pair_button"),
                    ("watch 시작", self.start_watcher_detached, "home_start_watch_button"),
                    ("창/Attach/입력/RunRoot 준비", self.run_prepare_all, "home_prepare_all_button"),
                ],
            ),
            (
                "상태 확인",
                [
                    ("pair 상태", self.run_paired_status, "home_pair_status_button"),
                    ("runroot 요약", self.run_paired_summary, "home_pair_summary_button"),
                    ("요약 리포트 열기", self.open_important_summary_text, "home_open_important_summary_button"),
                ],
            ),
            (
                "복구 / 재사용",
                [
                    ("pair 활성화", self.enable_selected_pair, "home_enable_pair_button"),
                    ("pair 비활성화", self.disable_selected_pair, "home_disable_pair_button"),
                    ("공식 8창 재사용", self.reuse_existing_windows, "home_reuse_windows_button"),
                    ("열린 pair 재사용", self.reuse_active_pairs, "home_reuse_pairs_button"),
                ],
            ),
        ]
        read_only_home_labels = {"pair 상태", "runroot 요약", "요약 리포트 열기"}
        for column, (title, specs) in enumerate(home_action_groups):
            group = ttk.LabelFrame(pair_actions, text=title, padding=8)
            group.grid(row=0, column=column, sticky="nsew", padx=(0, 8) if column < 2 else (0, 0))
            for idx, (label, callback, attr_name) in enumerate(specs):
                button = ttk.Button(group, text=label, command=callback)
                button.grid(row=idx // 2, column=idx % 2, sticky="ew", padx=(0, 8) if idx % 2 == 0 else (0, 0), pady=(0, 8))
                self.long_task_widgets.append(button)
                if label in read_only_home_labels:
                    self._register_read_only_widget(button)
                setattr(self, attr_name, button)
        ttk.Label(pair_frame, textvariable=self.home_pair_detail_var, wraplength=1200, justify="left").grid(row=2, column=0, sticky="w", pady=(8, 0))

        preview_tab_container, preview_tab = self._create_scrollable_tab(
            notebook,
            title="설정 / 문구",
            footer_text="--- 화면 끝 ---",
        )
        self.preview_tab = preview_tab_container
        preview_tab.columnconfigure(0, weight=1)
        preview_tab.columnconfigure(1, weight=2)
        preview_tab.rowconfigure(5, weight=1)

        self.summary_text = tk.Text(preview_tab, height=10, wrap="word")
        self.summary_text.grid(row=0, column=0, columnspan=2, sticky="nsew")
        self.summary_text.configure(state="disabled")

        start_guide_frame = ttk.LabelFrame(preview_tab, text="시작하기", padding=8)
        start_guide_frame.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        start_guide_frame.columnconfigure(0, weight=1)
        for row_index, guide_text in enumerate(
            [
                "1. pair 설정 저장: 카드 값을 정리한 뒤 저장해서 현재 정책을 먼저 확정합니다.",
                "2. 경로 확인: 선택 pair 또는 전체 경로 확인으로 repo / runroot / contract 경로를 확인합니다.",
                "3. 초간단 시작문 복사: Kickoff Composer에서 실제 target 창에 붙여넣을 시작문만 복사합니다.",
                "4. target 창 붙여넣기: 사용자가 보는 공식 창에 직접 붙여넣고 진행합니다.",
            ]
        ):
            ttk.Label(start_guide_frame, text=guide_text, justify="left", wraplength=1180).grid(row=row_index, column=0, sticky="w", pady=(0, 4) if row_index < 3 else (0, 0))

        pair_policy_frame = ttk.LabelFrame(preview_tab, text="4 Pair 설정 / 실효 경로", padding=8)
        pair_policy_frame.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        for column in range(2):
            pair_policy_frame.columnconfigure(column, weight=1)
        pair_policy_frame.rowconfigure(1, weight=1)
        pair_policy_frame.rowconfigure(2, weight=1)
        pair_policy_actions = ttk.Frame(pair_policy_frame)
        pair_policy_actions.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 8))
        pair_policy_actions.columnconfigure(0, weight=1)
        ttk.Label(pair_policy_actions, textvariable=self.pair_policy_editor_status_var, wraplength=1180, justify="left").grid(row=0, column=0, sticky="w")
        ttk.Button(pair_policy_actions, text="Config에서 다시 읽기", command=self.refresh_pair_policy_editor).grid(row=0, column=1, padx=(12, 8))
        ttk.Button(pair_policy_actions, text="전체 경로 확인", command=self.preview_all_pair_policy_effective).grid(row=0, column=2, padx=(0, 8))
        ttk.Button(pair_policy_actions, text="pair 설정 저장 + 새로고침", command=self.save_pair_policy_editor).grid(row=0, column=3, padx=(0, 8))
        ttk.Button(pair_policy_actions, text="pair 경로 상태 복사", command=self.copy_pair_route_matrix).grid(row=0, column=4, padx=(0, 8))
        ttk.Button(pair_policy_actions, text="pair 경로 JSON 저장", command=self.save_pair_route_matrix_json).grid(row=0, column=5)
        ttk.Label(pair_policy_actions, text="복제").grid(row=1, column=0, sticky="w", pady=(8, 0))
        clone_controls = ttk.Frame(pair_policy_actions)
        clone_controls.grid(row=1, column=1, columnspan=4, sticky="w", pady=(8, 0))
        ttk.Combobox(clone_controls, textvariable=self.pair_policy_clone_source_var, values=PAIR_ID_OPTIONS, state="readonly", width=10).grid(row=0, column=0)
        ttk.Label(clone_controls, text="→").grid(row=0, column=1, padx=6)
        ttk.Combobox(clone_controls, textvariable=self.pair_policy_clone_target_var, values=PAIR_ID_OPTIONS, state="readonly", width=10).grid(row=0, column=2)
        ttk.Button(clone_controls, text="설정 복제", command=self.clone_pair_policy_card_settings).grid(row=0, column=3, padx=(8, 0))
        ttk.Label(pair_policy_actions, text="병렬 drill").grid(row=2, column=0, sticky="w", pady=(8, 0))
        parallel_controls = ttk.Frame(pair_policy_actions)
        parallel_controls.grid(row=2, column=1, columnspan=5, sticky="ew", pady=(8, 0))
        parallel_controls.columnconfigure(1, weight=1)
        parallel_drill_button = ttk.Button(parallel_controls, text="선택 pair 병렬 실테스트", command=self.run_selected_parallel_pair_drill)
        parallel_drill_button.grid(row=0, column=0, sticky="w")
        self.long_task_widgets.append(parallel_drill_button)
        self.parallel_pair_drill_button = parallel_drill_button
        ttk.Label(parallel_controls, text="coordinator repo").grid(row=0, column=1, sticky="e", padx=(12, 6))
        ttk.Entry(parallel_controls, textvariable=self.parallel_coordinator_repo_root_var).grid(row=0, column=2, sticky="ew")
        ttk.Button(parallel_controls, text="선택", command=self.browse_parallel_coordinator_repo_root).grid(row=0, column=3, padx=(6, 0))
        ttk.Button(parallel_controls, text="열기", command=self.open_parallel_coordinator_repo_root).grid(row=0, column=4, padx=(4, 0))
        ttk.Label(
            pair_policy_actions,
            textvariable=self.pair_policy_parallel_status_var,
            wraplength=1180,
            justify="left",
        ).grid(row=3, column=0, columnspan=6, sticky="w", pady=(8, 0))

        for index, pair_id in enumerate(PAIR_ID_OPTIONS):
            card_vars = self.pair_policy_card_vars[pair_id]
            card_row = 1 + (index // 2)
            card_column = index % 2
            card = ttk.LabelFrame(pair_policy_frame, text=pair_id, padding=6)
            card.grid(
                row=card_row,
                column=card_column,
                sticky="nsew",
                padx=(0, 8) if card_column == 0 else (0, 0),
                pady=(0, 8) if card_row == 1 else (0, 0),
            )
            card.columnconfigure(1, weight=1)
            card.rowconfigure(12, weight=1)
            ttk.Label(card, textvariable=card_vars["meta_var"], wraplength=420, justify="left").grid(row=0, column=0, columnspan=2, sticky="w")
            badge_row = ttk.Frame(card)
            badge_row.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(8, 0))
            source_badge_label = tk.Label(
                badge_row,
                textvariable=card_vars["repo_source_badge_var"],
                bg="#6B7280",
                fg="#FFFFFF",
                padx=6,
                pady=2,
            )
            source_badge_label.grid(row=0, column=0, sticky="w")
            self.pair_policy_card_repo_source_badge_labels[pair_id] = source_badge_label
            override_badge_label = tk.Label(
                badge_row,
                textvariable=card_vars["override_badge_var"],
                bg="#6B7280",
                fg="#FFFFFF",
                padx=6,
                pady=2,
            )
            override_badge_label.grid(row=0, column=1, sticky="w", padx=(6, 0))
            self.pair_policy_card_override_badge_labels[pair_id] = override_badge_label
            parallel_checkbutton = ttk.Checkbutton(badge_row, text="병렬 drill", variable=card_vars["parallel_selected_var"])
            parallel_checkbutton.grid(row=0, column=2, sticky="w", padx=(8, 0))
            self.pair_policy_card_parallel_checkbuttons[pair_id] = parallel_checkbutton
            focus_badge_label = tk.Label(
                badge_row,
                text="",
                bg="#1D4ED8",
                fg="#FFFFFF",
                padx=6,
                pady=2,
            )
            focus_badge_label.grid(row=0, column=3, sticky="w", padx=(6, 0))
            focus_badge_label.grid_remove()
            self.pair_policy_card_focus_badge_labels[pair_id] = focus_badge_label
            ttk.Label(card, text="RepoRoot").grid(row=2, column=0, sticky="w", pady=(8, 0))
            repo_row = ttk.Frame(card)
            repo_row.grid(row=2, column=1, sticky="ew", pady=(8, 0))
            repo_row.columnconfigure(0, weight=1)
            ttk.Entry(repo_row, textvariable=card_vars["repo_root_var"]).grid(row=0, column=0, sticky="ew")
            ttk.Button(repo_row, text="선택", width=6, command=lambda current_pair_id=pair_id: self.browse_pair_policy_repo_root(current_pair_id)).grid(row=0, column=1, padx=(6, 0))
            ttk.Button(repo_row, text="열기", width=6, command=lambda current_pair_id=pair_id: self.open_pair_policy_repo_root(current_pair_id)).grid(row=0, column=2, padx=(4, 0))
            ttk.Label(card, text="SeedTarget").grid(row=3, column=0, sticky="w", pady=(6, 0))
            seed_combo = ttk.Combobox(card, textvariable=card_vars["seed_target_var"], values=[], state="disabled", width=12)
            seed_combo.grid(row=3, column=1, sticky="ew", pady=(6, 0))
            self.pair_policy_card_seed_combos[pair_id] = seed_combo
            ttk.Label(card, text="Roundtrip").grid(row=4, column=0, sticky="w", pady=(6, 0))
            ttk.Entry(card, textvariable=card_vars["roundtrip_var"], width=10).grid(row=4, column=1, sticky="ew", pady=(6, 0))
            ttk.Checkbutton(card, text="external runroot", variable=card_vars["external_run_root_var"]).grid(row=5, column=0, columnspan=2, sticky="w", pady=(6, 0))
            ttk.Checkbutton(card, text="external contract", variable=card_vars["external_contract_var"]).grid(row=6, column=0, columnspan=2, sticky="w", pady=(2, 0))
            badge_label = tk.Label(
                card,
                textvariable=card_vars["route_badge_var"],
                bg="#6B7280",
                fg="#FFFFFF",
                padx=8,
                pady=2,
            )
            badge_label.grid(row=7, column=0, columnspan=2, sticky="w", pady=(8, 0))
            self.pair_policy_card_badge_labels[pair_id] = badge_label
            ttk.Label(card, textvariable=card_vars["route_state_var"], wraplength=420, justify="left").grid(row=8, column=0, columnspan=2, sticky="w", pady=(6, 0))
            runtime_badge_label = tk.Label(
                card,
                textvariable=card_vars["runtime_badge_var"],
                bg="#6B7280",
                fg="#FFFFFF",
                padx=8,
                pady=2,
            )
            runtime_badge_label.grid(row=9, column=0, columnspan=2, sticky="w", pady=(6, 0))
            self.pair_policy_card_runtime_badge_labels[pair_id] = runtime_badge_label
            ttk.Label(card, textvariable=card_vars["runtime_summary_var"], wraplength=420, justify="left").grid(row=10, column=0, columnspan=2, sticky="w", pady=(6, 0))
            ttk.Label(card, text="실효값 상세").grid(row=11, column=0, columnspan=2, sticky="w", pady=(6, 0))
            effective_preview_text = scrolledtext.ScrolledText(card, height=8, wrap="char")
            effective_preview_text.grid(row=12, column=0, columnspan=2, sticky="nsew", pady=(4, 0))
            self.pair_policy_card_effective_preview_widgets[pair_id] = effective_preview_text
            self.set_text(effective_preview_text, str(card_vars["effective_preview_var"].get() or ""))
            card_actions = ttk.Frame(card)
            card_actions.grid(row=13, column=0, columnspan=2, sticky="ew", pady=(8, 0))
            card_actions.columnconfigure(0, weight=1)
            summary_button = ttk.Button(card_actions, text="요약 보기", command=lambda current_pair_id=pair_id: self.open_pair_policy_pair_summary(current_pair_id))
            summary_button.grid(row=0, column=0, sticky="w")
            self.pair_policy_card_summary_buttons[pair_id] = summary_button
            preview_button = ttk.Button(card_actions, text="경로 확인", command=lambda current_pair_id=pair_id: self.preview_pair_policy_effective(current_pair_id))
            preview_button.grid(row=0, column=1, sticky="e")
            self.pair_policy_card_preview_buttons[pair_id] = preview_button
            copy_button = ttk.Button(card_actions, text="경로 확인 복사", command=lambda current_pair_id=pair_id: self.copy_pair_policy_effective_preview(current_pair_id))
            copy_button.grid(row=0, column=2, sticky="e", padx=(8, 0))
            self.pair_policy_card_copy_buttons[pair_id] = copy_button

        seed_kickoff_frame = ttk.LabelFrame(preview_tab, text="초기 실행 준비 / Seed Kickoff Composer", padding=8)
        seed_kickoff_frame.grid(row=3, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        seed_kickoff_frame.columnconfigure(0, weight=1)
        seed_kickoff_frame.columnconfigure(1, weight=1)
        ttk.Label(
            seed_kickoff_frame,
            textvariable=self.seed_kickoff_status_var,
            wraplength=1180,
            justify="left",
        ).grid(row=0, column=0, columnspan=2, sticky="w")

        kickoff_controls = ttk.Frame(seed_kickoff_frame)
        kickoff_controls.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(8, 0))
        kickoff_controls.columnconfigure(3, weight=1)
        kickoff_controls.columnconfigure(7, weight=1)
        ttk.Label(kickoff_controls, text="Pair").grid(row=0, column=0, sticky="w")
        self.seed_kickoff_pair_combo = ttk.Combobox(
            kickoff_controls,
            textvariable=self.seed_kickoff_pair_var,
            values=PAIR_ID_OPTIONS,
            state="readonly",
            width=10,
        )
        self.seed_kickoff_pair_combo.grid(row=0, column=1, sticky="w", padx=(6, 12))
        self.seed_kickoff_pair_combo.bind("<<ComboboxSelected>>", lambda _event: self.refresh_seed_kickoff_composer())
        ttk.Label(kickoff_controls, text="SeedTarget").grid(row=0, column=2, sticky="e")
        self.seed_kickoff_target_combo = ttk.Combobox(
            kickoff_controls,
            textvariable=self.seed_kickoff_target_var,
            values=[],
            state="disabled",
            width=14,
        )
        self.seed_kickoff_target_combo.grid(row=0, column=3, sticky="ew", padx=(6, 12))
        ttk.Label(kickoff_controls, text="적용").grid(row=0, column=4, sticky="e")
        ttk.Combobox(
            kickoff_controls,
            textvariable=self.seed_kickoff_applies_to_var,
            values=["initial", "handoff", "both"],
            state="readonly",
            width=12,
        ).grid(row=0, column=5, sticky="w", padx=(6, 12))
        ttk.Label(kickoff_controls, text="배치").grid(row=0, column=6, sticky="e")
        ttk.Combobox(
            kickoff_controls,
            textvariable=self.seed_kickoff_placement_var,
            values=["one-time-prefix", "one-time-suffix"],
            state="readonly",
            width=16,
        ).grid(row=0, column=7, sticky="ew", padx=(6, 0))

        kickoff_input_row = ttk.Frame(seed_kickoff_frame)
        kickoff_input_row.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(8, 0))
        kickoff_input_row.columnconfigure(1, weight=1)
        ttk.Label(kickoff_input_row, text="입력 파일").grid(row=0, column=0, sticky="w")
        ttk.Entry(kickoff_input_row, textvariable=self.seed_kickoff_review_input_var).grid(row=0, column=1, sticky="ew", padx=(6, 6))
        ttk.Button(kickoff_input_row, text="선택", command=self.browse_seed_kickoff_review_input).grid(row=0, column=2, padx=(0, 4))
        ttk.Button(kickoff_input_row, text="열기", command=self.open_seed_kickoff_review_input).grid(row=0, column=3)

        kickoff_badges = ttk.Frame(seed_kickoff_frame)
        kickoff_badges.grid(row=3, column=0, columnspan=2, sticky="ew", pady=(8, 0))
        kickoff_badges.columnconfigure(0, weight=1)
        ttk.Label(kickoff_badges, textvariable=self.seed_kickoff_target_banner_var, wraplength=1180, justify="left").grid(row=0, column=0, sticky="w")
        ttk.Label(kickoff_badges, textvariable=self.seed_kickoff_readiness_var, wraplength=1180, justify="left").grid(row=1, column=0, sticky="w", pady=(4, 0))

        kickoff_quick_actions = ttk.Frame(seed_kickoff_frame)
        kickoff_quick_actions.grid(row=4, column=0, columnspan=2, sticky="ew", pady=(8, 0))
        ttk.Label(kickoff_quick_actions, text="빠른 시작").grid(row=0, column=0, sticky="w", padx=(0, 8))
        ttk.Button(kickoff_quick_actions, text="현재 Pair/Target 반영", command=self._sync_seed_kickoff_with_action_context).grid(row=0, column=1, padx=(0, 8))
        ttk.Button(kickoff_quick_actions, text="미리보기", command=self.preview_seed_kickoff_message).grid(row=0, column=2, padx=(0, 8))
        ttk.Button(kickoff_quick_actions, text="초간단 시작문 복사", command=self.copy_seed_kickoff_full_text).grid(row=0, column=3, padx=(0, 8))
        ttk.Button(kickoff_quick_actions, text="상세 시작문 복사", command=self.copy_seed_kickoff_detailed_text).grid(row=0, column=4, padx=(0, 8))
        ttk.Button(kickoff_quick_actions, text="초기 입력 큐잉", command=self.enqueue_seed_kickoff_message).grid(row=0, column=5, padx=(0, 8))
        ttk.Checkbutton(
            kickoff_quick_actions,
            text="세부 블록 표시",
            variable=self.seed_kickoff_detail_visible_var,
            command=self._apply_seed_kickoff_detail_visibility,
        ).grid(row=0, column=6, padx=(12, 0))

        simple_preview_frame = ttk.LabelFrame(seed_kickoff_frame, text="초간단 시작문 미리보기", padding=6)
        simple_preview_frame.grid(row=5, column=0, columnspan=2, sticky="nsew", pady=(10, 0))
        simple_preview_frame.columnconfigure(0, weight=1)
        self.seed_kickoff_simple_text = scrolledtext.ScrolledText(simple_preview_frame, height=8, wrap="word")
        self.seed_kickoff_simple_text.grid(row=0, column=0, sticky="nsew")

        input_columns = ttk.Frame(seed_kickoff_frame)
        self.seed_kickoff_input_columns_frame = input_columns
        input_columns.grid(row=6, column=0, columnspan=2, sticky="nsew", pady=(10, 0))
        input_columns.columnconfigure(0, weight=1)
        input_columns.columnconfigure(1, weight=1)
        ttk.Label(input_columns, text="작업 설명 (사용자 직접 입력)").grid(row=0, column=0, sticky="w")
        self.seed_kickoff_task_text = scrolledtext.ScrolledText(input_columns, height=8, wrap="word")
        self.seed_kickoff_task_text.grid(row=1, column=0, sticky="nsew", padx=(0, 10))

        detail_column = ttk.Frame(input_columns)
        self.seed_kickoff_detail_column_frame = detail_column
        detail_column.grid(row=0, column=1, rowspan=2, sticky="nsew")
        detail_column.columnconfigure(0, weight=1)
        ttk.Label(detail_column, text="자동 계약 / helper / 최종 미리보기").grid(row=0, column=0, sticky="w")

        preview_stack = ttk.Frame(detail_column)
        self.seed_kickoff_preview_stack_frame = preview_stack
        preview_stack.grid(row=1, column=0, sticky="nsew")
        preview_stack.columnconfigure(0, weight=1)
        ttk.Label(preview_stack, text="자동 계약 블록").grid(row=0, column=0, sticky="w")
        self.seed_kickoff_contract_text = scrolledtext.ScrolledText(preview_stack, height=7, wrap="word")
        self.seed_kickoff_contract_text.grid(row=1, column=0, sticky="nsew")
        ttk.Label(preview_stack, text="helper 블록").grid(row=2, column=0, sticky="w", pady=(8, 0))
        self.seed_kickoff_helper_text = scrolledtext.ScrolledText(preview_stack, height=5, wrap="word")
        self.seed_kickoff_helper_text.grid(row=3, column=0, sticky="nsew")
        ttk.Label(preview_stack, text="권장 시작 순서").grid(row=4, column=0, sticky="w", pady=(8, 0))
        self.seed_kickoff_steps_text = scrolledtext.ScrolledText(preview_stack, height=7, wrap="word")
        self.seed_kickoff_steps_text.grid(row=5, column=0, sticky="nsew")

        preview_detail_frame = ttk.Frame(seed_kickoff_frame)
        self.seed_kickoff_preview_detail_frame = preview_detail_frame
        preview_detail_frame.grid(row=7, column=0, columnspan=2, sticky="nsew", pady=(10, 0))
        preview_detail_frame.columnconfigure(0, weight=1)
        ttk.Label(preview_detail_frame, text="운영자 확인용 미리보기").grid(row=0, column=0, sticky="w")
        ttk.Label(
            preview_detail_frame,
            text="주의: 아래 미리보기에는 operator 확인용 안내가 포함됩니다. 실제 target 전달문은 '초간단 시작문 복사'가 필요한 전달문만 복사합니다.",
            foreground="#555555",
            wraplength=900,
            justify="left",
        ).grid(row=1, column=0, sticky="w", pady=(2, 0))
        self.seed_kickoff_preview_text = scrolledtext.ScrolledText(preview_detail_frame, height=10, wrap="word")
        self.seed_kickoff_preview_text.grid(row=2, column=0, sticky="nsew")

        kickoff_actions = ttk.Frame(seed_kickoff_frame)
        self.seed_kickoff_detail_actions_frame = kickoff_actions
        kickoff_actions.grid(row=8, column=0, columnspan=2, sticky="ew", pady=(8, 0))
        ttk.Button(kickoff_actions, text="미리보기", command=self.preview_seed_kickoff_message).grid(row=0, column=0, padx=(0, 8))
        ttk.Button(kickoff_actions, text="초간단 시작문 복사", command=self.copy_seed_kickoff_full_text).grid(row=0, column=1, padx=(0, 8))
        ttk.Button(kickoff_actions, text="상세 시작문 복사", command=self.copy_seed_kickoff_detailed_text).grid(row=0, column=2, padx=(0, 8))
        ttk.Button(kickoff_actions, text="summary 경로 복사", command=self.copy_seed_kickoff_summary_path).grid(row=0, column=3, padx=(0, 8))
        ttk.Button(kickoff_actions, text="review.zip 경로 복사", command=self.copy_seed_kickoff_review_zip_path).grid(row=0, column=4, padx=(0, 8))
        ttk.Button(kickoff_actions, text="publish helper 복사", command=self.copy_seed_kickoff_publish_helper_command).grid(row=0, column=5, padx=(0, 8))
        ttk.Button(kickoff_actions, text="계약 경로 복사", command=self.copy_seed_kickoff_path_block).grid(row=0, column=6, padx=(0, 8))
        ttk.Button(kickoff_actions, text="시작 순서 복사", command=self.copy_seed_kickoff_start_steps).grid(row=0, column=7, padx=(0, 8))
        ttk.Button(kickoff_actions, text="helper 명령 복사", command=self.copy_seed_kickoff_helper_block).grid(row=0, column=8, padx=(0, 8))
        ttk.Button(kickoff_actions, text="초기 입력 큐잉", command=self.enqueue_seed_kickoff_message).grid(row=0, column=9)
        self._apply_seed_kickoff_detail_visibility()

        preview_actions = ttk.Frame(preview_tab)
        preview_actions.grid(row=4, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        for idx, (label, callback) in enumerate(
            [
                ("선택 row 실행 기준 반영", self.apply_selected_inspection_context),
                ("미리보기 JSON 저장", self.save_effective_json),
                ("선택 행 문구 JSON/TXT 저장", self.export_selected_row_messages),
                ("대상 폴더 열기", self.open_selected_target_folder),
                ("검토 폴더 열기", self.open_selected_review_folder),
                ("summary 경로 복사", self.copy_selected_summary_path),
            ]
        ):
            button = ttk.Button(preview_actions, text=label, command=callback)
            button.grid(row=0, column=idx, padx=(0, 8))
            if label == "선택 row 실행 기준 반영":
                self.preview_apply_context_button = button

        self.row_tree = ttk.Treeview(
            preview_tab,
            columns=("pair", "role", "target", "partner", "outbox"),
            show="headings",
            height=16,
        )
        for column, heading, width in (
            ("pair", "Pair", 100),
            ("role", "역할", 90),
            ("target", "대상", 110),
            ("partner", "상대", 110),
            ("outbox", "Outbox/Repair", 260),
        ):
            self.row_tree.heading(column, text=heading)
            self.row_tree.column(column, width=width, stretch=False)
        self.row_tree.grid(row=5, column=0, sticky="nsew", pady=(10, 0), padx=(0, 10))
        self.row_tree.bind("<<TreeviewSelect>>", self.on_row_selected)

        right_side = ttk.Notebook(preview_tab)
        right_side.grid(row=5, column=1, sticky="nsew", pady=(10, 0))

        details_tab = ttk.Frame(right_side, padding=6)
        details_tab.columnconfigure(0, weight=1)
        details_tab.rowconfigure(0, weight=1)
        right_side.add(details_tab, text="경로 / 메타")
        self.details_text = scrolledtext.ScrolledText(details_tab, wrap="word")
        self.details_text.grid(row=0, column=0, sticky="nsew")

        plan_tab = ttk.Frame(right_side, padding=6)
        plan_tab.columnconfigure(0, weight=1)
        plan_tab.rowconfigure(0, weight=1)
        right_side.add(plan_tab, text="문구 구성")
        self.plan_text = scrolledtext.ScrolledText(plan_tab, wrap="word")
        self.plan_text.grid(row=0, column=0, sticky="nsew")

        one_time_tab = ttk.Frame(right_side, padding=6)
        one_time_tab.columnconfigure(0, weight=1)
        one_time_tab.rowconfigure(0, weight=1)
        right_side.add(one_time_tab, text="1회성 문구")
        self.one_time_text = scrolledtext.ScrolledText(one_time_tab, wrap="word")
        self.one_time_text.grid(row=0, column=0, sticky="nsew")

        initial_tab = ttk.Frame(right_side, padding=6)
        initial_tab.columnconfigure(0, weight=1)
        initial_tab.rowconfigure(0, weight=1)
        right_side.add(initial_tab, text="초기 문구")
        self.initial_text = scrolledtext.ScrolledText(initial_tab, wrap="word")
        self.initial_text.grid(row=0, column=0, sticky="nsew")

        handoff_tab = ttk.Frame(right_side, padding=6)
        handoff_tab.columnconfigure(0, weight=1)
        handoff_tab.rowconfigure(0, weight=1)
        right_side.add(handoff_tab, text="전달 문구")
        self.handoff_text = scrolledtext.ScrolledText(handoff_tab, wrap="word")
        self.handoff_text.grid(row=0, column=0, sticky="nsew")

        board_tab = ttk.Frame(notebook, padding=10)
        board_tab.columnconfigure(0, weight=1)
        board_tab.rowconfigure(1, weight=1)
        notebook.add(board_tab, text="8창 보드")
        self.board_tab = board_tab

        board_header = ttk.LabelFrame(board_tab, text="현재 매칭 / 입력 가능", padding=8)
        board_header.grid(row=0, column=0, sticky="ew")
        board_header.columnconfigure(0, weight=1)
        ttk.Label(board_header, textvariable=self.board_status_var, wraplength=1200, justify="left").grid(row=0, column=0, sticky="ew")
        board_actions = ttk.Frame(board_header)
        board_actions.grid(row=1, column=0, sticky="w", pady=(8, 0))
        self.board_quick_refresh_button = ttk.Button(board_actions, text="빠른 새로고침", command=self.refresh_quick_status)
        self.board_quick_refresh_button.grid(row=0, column=0, padx=(0, 8))
        self.long_task_widgets.append(self.board_quick_refresh_button)
        self._register_read_only_widget(self.board_quick_refresh_button)
        self.board_attach_button = ttk.Button(board_actions, text="붙이기", command=self.attach_windows_from_bindings)
        self.board_attach_button.grid(row=0, column=1, padx=(0, 8))
        self.long_task_widgets.append(self.board_attach_button)
        self.board_reuse_button = ttk.Button(board_actions, text="기존 8창 재사용", command=self.reuse_existing_windows)
        self.board_reuse_button.grid(row=0, column=2, padx=(0, 8))
        self.long_task_widgets.append(self.board_reuse_button)
        self.board_reuse_pairs_button = ttk.Button(board_actions, text="열린 pair 재사용", command=self.reuse_active_pairs)
        self.board_reuse_pairs_button.grid(row=0, column=3, padx=(0, 8))
        self.long_task_widgets.append(self.board_reuse_pairs_button)
        self.board_visibility_button = ttk.Button(board_actions, text="입력 점검", command=self.run_visibility_check)
        self.board_visibility_button.grid(row=0, column=4)
        self.long_task_widgets.append(self.board_visibility_button)
        self.board_apply_context_button = ttk.Button(board_actions, text="선택 target 반영", command=self.apply_selected_inspection_context)
        self.board_apply_context_button.grid(row=0, column=5, padx=(8, 0))

        board_grid = tk.Frame(board_tab, bg="#f3f4f6")
        board_grid.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
        self.board_grid = board_grid
        for row in range(2):
            board_grid.rowconfigure(row, weight=1)
        for column in range(4):
            board_grid.columnconfigure(column, weight=1)

        editor_tab = ttk.Frame(notebook, padding=10)
        editor_tab.columnconfigure(0, weight=2, minsize=520)
        editor_tab.columnconfigure(1, weight=3, minsize=680)
        editor_tab.rowconfigure(1, weight=1)
        notebook.add(editor_tab, text="Initial/Handoff 문구 편집")
        self.editor_tab = editor_tab

        editor_actions = ttk.LabelFrame(editor_tab, text="설정 편집", padding=8)
        editor_actions.grid(row=0, column=0, columnspan=2, sticky="ew")
        editor_actions.columnconfigure(9, weight=1)
        ttk.Button(editor_actions, text="설정 다시 불러오기", command=self.load_message_editor_document).grid(row=0, column=0, padx=(0, 8))
        ttk.Button(editor_actions, text="변경 취소", command=self.reset_message_editor_changes).grid(row=0, column=1, padx=(0, 8))
        ttk.Button(editor_actions, text="미리보기 갱신", command=self.refresh_message_editor_preview).grid(row=0, column=2, padx=(0, 8))
        ttk.Button(editor_actions, text="저장 전 검증", command=self.validate_message_editor).grid(row=0, column=3, padx=(0, 8))
        ttk.Button(editor_actions, text="영향 요약", command=self.show_message_impact_summary).grid(row=0, column=4, padx=(0, 8))
        ttk.Button(editor_actions, text="Diff 보기", command=self.show_message_editor_diff).grid(row=0, column=5, padx=(0, 8))
        ttk.Button(editor_actions, text="현재 preview 복사", command=self.copy_current_message_preview).grid(row=0, column=6, padx=(0, 8))
        self.message_save_button = ttk.Button(editor_actions, text="저장 + 새로고침", command=self.save_message_editor)
        self.message_save_button.grid(row=0, column=7, padx=(0, 8))
        ttk.Button(editor_actions, text="마지막 백업 롤백", command=self.rollback_message_editor).grid(row=0, column=8, padx=(0, 8))
        ttk.Label(editor_actions, textvariable=self.message_editor_status_var, wraplength=520, justify="left").grid(row=0, column=9, sticky="w")
        ttk.Label(editor_actions, textvariable=self.message_preview_status_var, wraplength=1180, justify="left").grid(row=1, column=0, columnspan=10, sticky="w", pady=(8, 0))

        editor_left = ttk.Frame(editor_tab)
        editor_left.grid(row=1, column=0, sticky="nsew", padx=(0, 10))
        editor_left.columnconfigure(0, weight=1)
        editor_left.rowconfigure(2, weight=3)
        editor_left.rowconfigure(4, weight=1)
        self.message_editor_left_frame = editor_left

        editor_scope = ttk.LabelFrame(editor_left, text="편집 문맥 / Initial", padding=8)
        editor_scope.grid(row=0, column=0, sticky="ew")
        self.message_editor_scope_frame = editor_scope
        ttk.Label(editor_scope, text="메시지 종류").grid(row=0, column=0, sticky="w")
        self.message_template_combo = ttk.Combobox(editor_scope, textvariable=self.message_template_var, values=["Initial", "Handoff"], state="readonly", width=14)
        self.message_template_combo.grid(row=0, column=1, sticky="w", padx=(8, 16))
        ttk.Button(editor_scope, text="Initial 편집", command=lambda: self.set_message_template("Initial")).grid(row=0, column=2, sticky="w", padx=(0, 6))
        ttk.Button(editor_scope, text="Handoff 편집", command=lambda: self.set_message_template("Handoff")).grid(row=0, column=3, sticky="w", padx=(0, 16))
        ttk.Label(editor_scope, text="연동 범위").grid(row=0, column=4, sticky="w")
        self.message_scope_combo = ttk.Combobox(editor_scope, textvariable=self.message_scope_label_var, values=[label for label, _kind in MESSAGE_SCOPE_OPTIONS], state="readonly", width=16)
        self.message_scope_combo.grid(row=0, column=5, sticky="w", padx=(8, 16))
        ttk.Label(editor_scope, text="대상 ID").grid(row=0, column=6, sticky="w")
        self.message_scope_id_combo = ttk.Combobox(editor_scope, textvariable=self.message_scope_id_var, values=[""], state="readonly", width=16)
        self.message_scope_id_combo.grid(row=0, column=7, sticky="w", padx=(8, 0))
        ttk.Label(
            editor_scope,
            textvariable=self.message_template_hint_var,
            wraplength=700,
            justify="left",
        ).grid(row=1, column=0, columnspan=8, sticky="w", pady=(8, 0))

        slot_order_frame = ttk.LabelFrame(editor_left, text="Slot 순서", padding=8)
        slot_order_frame.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
        slot_order_frame.columnconfigure(0, weight=1)
        slot_order_frame.rowconfigure(0, weight=1)
        self.message_slot_order_list = tk.Listbox(slot_order_frame, height=8, exportselection=False)
        self.message_slot_order_list.grid(row=0, column=0, sticky="nsew")
        slot_order_buttons = ttk.Frame(slot_order_frame)
        slot_order_buttons.grid(row=0, column=1, sticky="ns", padx=(8, 0))
        ttk.Button(slot_order_buttons, text="위", command=lambda: self.move_message_slot_order(-1)).grid(row=0, column=0, pady=(0, 6))
        ttk.Button(slot_order_buttons, text="아래", command=lambda: self.move_message_slot_order(1)).grid(row=1, column=0, pady=(0, 6))
        ttk.Button(slot_order_buttons, text="기본값", command=self.reset_message_slot_order).grid(row=2, column=0)
        ttk.Label(slot_order_frame, text="마우스로 끌어 순서를 바꿀 수 있습니다.", justify="left").grid(row=1, column=0, columnspan=2, sticky="w", pady=(8, 0))

        block_frame = ttk.LabelFrame(editor_left, text="블록 편집 / Initial / 글로벌 Prefix", padding=8)
        block_frame.grid(row=2, column=0, sticky="nsew", pady=(10, 0))
        self.message_block_frame = block_frame
        block_frame.columnconfigure(0, weight=1)
        block_frame.rowconfigure(2, weight=1)
        block_frame.rowconfigure(3, weight=2)
        block_filter_row = ttk.Frame(block_frame)
        block_filter_row.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 8))
        block_filter_row.columnconfigure(1, weight=1)
        ttk.Label(block_filter_row, text="검색").grid(row=0, column=0, sticky="w")
        self.message_block_filter_entry = ttk.Entry(block_filter_row, textvariable=self.message_block_filter_var)
        self.message_block_filter_entry.grid(row=0, column=1, sticky="ew", padx=(8, 8))
        self.message_block_changed_only_check = ttk.Checkbutton(block_filter_row, text="changed only", variable=self.message_block_changed_only_var, command=self.on_message_block_filter_changed)
        self.message_block_changed_only_check.grid(row=0, column=2, sticky="w", padx=(0, 8))
        self.message_block_clear_filter_button = ttk.Button(block_filter_row, text="필터 해제", command=self.clear_message_block_filter)
        self.message_block_clear_filter_button.grid(row=0, column=3, sticky="e")
        self.message_block_focus_button = ttk.Button(
            block_filter_row,
            textvariable=self.message_block_focus_button_var,
            command=self.toggle_message_block_focus_mode,
        )
        self.message_block_focus_button.grid(row=0, column=4, sticky="e", padx=(8, 0))
        ttk.Label(block_filter_row, textvariable=self.message_block_filter_status_var, justify="left").grid(row=1, column=0, columnspan=5, sticky="w", pady=(6, 0))
        self.message_block_aux_frame = ttk.Frame(block_frame)
        self.message_block_aux_frame.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(0, 8))
        self.message_block_aux_frame.columnconfigure(0, weight=1)
        ttk.Label(self.message_block_aux_frame, textvariable=self.message_block_badges_var, justify="left").grid(row=0, column=0, columnspan=3, sticky="w")
        ttk.Label(self.message_block_aux_frame, textvariable=self.message_block_hint_var, justify="left").grid(row=1, column=0, sticky="w", pady=(4, 0))
        self.message_empty_add_button = ttk.Button(self.message_block_aux_frame, text="여기서 새 블록 추가", command=self.add_message_block)
        self.message_empty_add_button.grid(row=1, column=1, sticky="e", padx=(8, 0), pady=(4, 0))
        self.message_empty_clear_filter_button = ttk.Button(self.message_block_aux_frame, text="필터 해제", command=self.clear_message_block_filter)
        self.message_empty_clear_filter_button.grid(row=1, column=2, sticky="e", padx=(8, 0), pady=(4, 0))
        self.message_empty_add_button.grid_remove()
        self.message_empty_clear_filter_button.grid_remove()
        self.message_block_aux_frame.grid_remove()
        self.message_blocks_list = tk.Listbox(block_frame, height=8, exportselection=False)
        self.message_blocks_list.grid(row=2, column=0, sticky="nsew")
        block_buttons = ttk.Frame(block_frame)
        block_buttons.grid(row=2, column=1, sticky="ns", padx=(8, 0))
        self.message_move_block_up_button = ttk.Button(block_buttons, text="위", command=lambda: self.move_message_block(-1))
        self.message_move_block_up_button.grid(row=0, column=0, pady=(0, 6))
        self.message_move_block_down_button = ttk.Button(block_buttons, text="아래", command=lambda: self.move_message_block(1))
        self.message_move_block_down_button.grid(row=1, column=0, pady=(0, 6))
        self.message_duplicate_block_button = ttk.Button(block_buttons, text="복제", command=self.duplicate_message_block)
        self.message_duplicate_block_button.grid(row=2, column=0, pady=(0, 6))
        self.message_revert_block_button = ttk.Button(block_buttons, text="원복", command=self.revert_selected_message_block)
        self.message_revert_block_button.grid(row=3, column=0, pady=(0, 6))
        self.message_delete_block_button = ttk.Button(block_buttons, text="삭제", command=self.remove_message_block)
        self.message_delete_block_button.grid(row=4, column=0, pady=(0, 6))
        self.message_clear_blocks_button = ttk.Button(block_buttons, text="비우기", command=self.clear_message_blocks)
        self.message_clear_blocks_button.grid(row=5, column=0)
        self.message_block_text = scrolledtext.ScrolledText(block_frame, wrap="word", height=10)
        self.message_block_text.grid(row=3, column=0, columnspan=2, sticky="nsew", pady=(8, 0))
        block_edit_buttons = ttk.Frame(block_frame)
        block_edit_buttons.grid(row=4, column=0, columnspan=2, sticky="e", pady=(8, 0))
        self.message_add_block_button = ttk.Button(block_edit_buttons, text="새 블록 추가", command=self.add_message_block)
        self.message_add_block_button.grid(row=0, column=0, padx=(0, 8))
        self.message_update_block_button = ttk.Button(block_edit_buttons, text="선택 블록 반영", command=self.update_message_block)
        self.message_update_block_button.grid(row=0, column=1)
        ttk.Label(block_frame, text="검색/changed-only 필터 중에는 순서 이동이 잠깁니다. 필터를 끄면 드래그/위아래 이동이 가능합니다.", justify="left").grid(row=5, column=0, columnspan=2, sticky="w", pady=(8, 0))

        fixed_frame = ttk.LabelFrame(editor_left, text="고정문구", padding=8)
        fixed_frame.grid(row=4, column=0, sticky="nsew", pady=(10, 0))
        fixed_frame.columnconfigure(0, weight=1)
        fixed_frame.rowconfigure(1, weight=1)
        fixed_header = ttk.Frame(fixed_frame)
        fixed_header.grid(row=0, column=0, sticky="ew")
        fixed_header.columnconfigure(0, weight=1)
        ttk.Label(
            fixed_header,
            text="블록 본문 편집에 집중할 때는 고정문구 영역을 접어둘 수 있습니다.",
            wraplength=460,
            justify="left",
        ).grid(row=0, column=0, sticky="w")
        fixed_toggle_button = ttk.Button(
            fixed_header,
            textvariable=self.message_fixed_section_toggle_var,
            command=self.toggle_message_fixed_section,
        )
        fixed_toggle_button.grid(row=0, column=1, sticky="e", padx=(8, 0))
        self.message_fixed_toggle_button = fixed_toggle_button
        fixed_body = ttk.Frame(fixed_frame)
        self.message_fixed_body_frame = fixed_body
        fixed_body.grid(row=1, column=0, sticky="nsew", pady=(8, 0))
        fixed_body.columnconfigure(1, weight=1)
        fixed_body.columnconfigure(3, weight=1)
        fixed_body.rowconfigure(1, weight=1)
        fixed_body.rowconfigure(3, weight=1)
        ttk.Label(fixed_body, text="기본 고정문구").grid(row=0, column=0, sticky="w")
        self.default_fixed_text = scrolledtext.ScrolledText(fixed_body, wrap="word", height=5)
        self.default_fixed_text.grid(row=1, column=0, columnspan=2, sticky="nsew", pady=(6, 0), padx=(0, 10))
        ttk.Button(fixed_body, text="기본 고정문구 반영", command=self.apply_default_fixed_suffix).grid(row=2, column=0, sticky="w", pady=(8, 0))
        ttk.Label(fixed_body, text="Target 고정문구 대상").grid(row=0, column=2, sticky="w")
        self.target_fixed_combo = ttk.Combobox(fixed_body, textvariable=self.message_target_suffix_var, values=[""], state="readonly", width=16)
        self.target_fixed_combo.grid(row=0, column=3, sticky="w", padx=(8, 0))
        self.target_fixed_text = scrolledtext.ScrolledText(fixed_body, wrap="word", height=5)
        self.target_fixed_text.grid(row=1, column=2, columnspan=2, sticky="nsew", pady=(6, 0))
        ttk.Button(fixed_body, text="Target 고정문구 반영", command=self.apply_target_fixed_suffix).grid(row=2, column=2, sticky="w", pady=(8, 0))
        ttk.Label(fixed_body, text="아래 Target 고정문구 대상은 상단 대상/slot 편집 문맥과 별도입니다.", justify="left").grid(row=3, column=2, columnspan=2, sticky="w", pady=(8, 0))

        editor_right_frame = ttk.Frame(editor_tab)
        editor_right_frame.grid(row=1, column=1, sticky="nsew")
        editor_right_frame.columnconfigure(0, weight=1)
        editor_right_frame.rowconfigure(1, weight=1)
        editor_right_header = ttk.LabelFrame(editor_right_frame, text="오른쪽 탭 안내", padding=8)
        editor_right_header.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        editor_right_header.columnconfigure(0, weight=1)
        ttk.Label(
            editor_right_header,
            textvariable=self.message_editor_tab_title_var,
            font=("Segoe UI", 10, "bold"),
        ).grid(row=0, column=0, sticky="w")
        ttk.Label(
            editor_right_header,
            textvariable=self.message_editor_tab_detail_var,
            wraplength=760,
            justify="left",
        ).grid(row=1, column=0, sticky="w", pady=(4, 0))
        editor_right_style = ttk.Style(self)
        editor_right_style.configure("EditorTabs.TNotebook.Tab", padding=(8, 4))
        editor_right = ttk.Notebook(editor_right_frame, style="EditorTabs.TNotebook")
        editor_right.grid(row=1, column=0, sticky="nsew")
        editor_right.bind("<<NotebookTabChanged>>", self._on_message_editor_tab_changed)
        self.editor_right_notebook = editor_right

        editor_context_tab = ttk.Frame(editor_right, padding=6)
        editor_context_tab.columnconfigure(0, weight=1)
        editor_context_tab.rowconfigure(0, weight=1)
        self._register_message_editor_tab(editor_right, editor_context_tab, tab_key="context")
        self.message_context_text = scrolledtext.ScrolledText(editor_context_tab, wrap="word")
        self.message_context_text.grid(row=0, column=0, sticky="nsew")

        editor_plan_tab = ttk.Frame(editor_right, padding=6)
        editor_plan_tab.columnconfigure(0, weight=1)
        editor_plan_tab.rowconfigure(0, weight=1)
        self._register_message_editor_tab(editor_right, editor_plan_tab, tab_key="plan")
        self.message_plan_text = scrolledtext.ScrolledText(editor_plan_tab, wrap="word")
        self.message_plan_text.grid(row=0, column=0, sticky="nsew")

        editor_initial_preview_tab = ttk.Frame(editor_right, padding=6)
        editor_initial_preview_tab.columnconfigure(0, weight=1)
        editor_initial_preview_tab.rowconfigure(0, weight=1)
        self._register_message_editor_tab(editor_right, editor_initial_preview_tab, tab_key="initial_preview")
        self.editor_initial_preview_tab = editor_initial_preview_tab
        self.message_initial_preview_text = scrolledtext.ScrolledText(editor_initial_preview_tab, wrap="word")
        self.message_initial_preview_text.grid(row=0, column=0, sticky="nsew")

        editor_handoff_preview_tab = ttk.Frame(editor_right, padding=6)
        editor_handoff_preview_tab.columnconfigure(0, weight=1)
        editor_handoff_preview_tab.rowconfigure(0, weight=1)
        self._register_message_editor_tab(editor_right, editor_handoff_preview_tab, tab_key="handoff_preview")
        self.editor_handoff_preview_tab = editor_handoff_preview_tab
        self.message_handoff_preview_text = scrolledtext.ScrolledText(editor_handoff_preview_tab, wrap="word")
        self.message_handoff_preview_text.grid(row=0, column=0, sticky="nsew")

        editor_final_delivery_tab = ttk.Frame(editor_right, padding=6)
        editor_final_delivery_tab.columnconfigure(0, weight=1)
        editor_final_delivery_tab.rowconfigure(1, weight=1)
        self._register_message_editor_tab(editor_right, editor_final_delivery_tab, tab_key="final_delivery")
        final_delivery_actions = ttk.Frame(editor_final_delivery_tab)
        final_delivery_actions.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        ttk.Button(final_delivery_actions, text="완성본 복사", command=self.copy_current_final_delivery_preview).grid(row=0, column=0, padx=(0, 8))
        self.message_final_delivery_text = scrolledtext.ScrolledText(editor_final_delivery_tab, wrap="word")
        self.message_final_delivery_text.grid(row=1, column=0, sticky="nsew")

        editor_path_summary_tab = ttk.Frame(editor_right, padding=6)
        editor_path_summary_tab.columnconfigure(0, weight=1)
        editor_path_summary_tab.rowconfigure(1, weight=1)
        self._register_message_editor_tab(editor_right, editor_path_summary_tab, tab_key="path_summary")
        path_summary_actions = ttk.Frame(editor_path_summary_tab)
        path_summary_actions.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        ttk.Button(path_summary_actions, text="경로 요약 복사", command=self.copy_current_path_summary).grid(row=0, column=0, padx=(0, 8))
        ttk.Button(path_summary_actions, text="내 폴더 열기", command=self.open_current_message_target_folder).grid(row=0, column=1, padx=(0, 8))
        ttk.Button(path_summary_actions, text="상대 폴더 열기", command=self.open_current_message_partner_folder).grid(row=0, column=2)
        self.message_path_summary_text = scrolledtext.ScrolledText(editor_path_summary_tab, wrap="word")
        self.message_path_summary_text.grid(row=1, column=0, sticky="nsew")

        editor_one_time_tab = ttk.Frame(editor_right, padding=6)
        editor_one_time_tab.columnconfigure(0, weight=1)
        editor_one_time_tab.rowconfigure(0, weight=1)
        self._register_message_editor_tab(editor_right, editor_one_time_tab, tab_key="one_time")
        self.message_one_time_preview_text = scrolledtext.ScrolledText(editor_one_time_tab, wrap="word")
        self.message_one_time_preview_text.grid(row=0, column=0, sticky="nsew")

        self.editor_validation_tab = ttk.Frame(editor_right, padding=6)
        self.editor_validation_tab.columnconfigure(0, weight=1)
        self.editor_validation_tab.rowconfigure(0, weight=1)
        self._register_message_editor_tab(editor_right, self.editor_validation_tab, tab_key="validation")
        self.message_validation_text = scrolledtext.ScrolledText(self.editor_validation_tab, wrap="word")
        self.message_validation_text.grid(row=0, column=0, sticky="nsew")

        editor_summary_tab = ttk.Frame(editor_right, padding=6)
        editor_summary_tab.columnconfigure(0, weight=1)
        editor_summary_tab.rowconfigure(0, weight=1)
        self._register_message_editor_tab(editor_right, editor_summary_tab, tab_key="summary")
        self.message_summary_text = scrolledtext.ScrolledText(editor_summary_tab, wrap="word")
        self.message_summary_text.grid(row=0, column=0, sticky="nsew")

        self.editor_diff_tab = ttk.Frame(editor_right, padding=6)
        self.editor_diff_tab.columnconfigure(0, weight=1)
        self.editor_diff_tab.rowconfigure(0, weight=1)
        self._register_message_editor_tab(editor_right, self.editor_diff_tab, tab_key="diff")
        self.message_diff_text = scrolledtext.ScrolledText(self.editor_diff_tab, wrap="none")
        self.message_diff_text.grid(row=0, column=0, sticky="nsew")

        editor_backup_tab = ttk.Frame(editor_right, padding=6)
        editor_backup_tab.columnconfigure(0, weight=1)
        editor_backup_tab.rowconfigure(2, weight=1)
        self._register_message_editor_tab(editor_right, editor_backup_tab, tab_key="backup")
        backup_action_row = ttk.Frame(editor_backup_tab)
        backup_action_row.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        ttk.Button(backup_action_row, text="백업 새로고침", command=self.refresh_message_backup_list).grid(row=0, column=0, padx=(0, 8))
        ttk.Button(backup_action_row, text="현재 편집본과 diff", command=lambda: self.show_selected_backup_diff(compare_to="current")).grid(row=0, column=1, padx=(0, 8))
        ttk.Button(backup_action_row, text="현재 저장본과 diff", command=lambda: self.show_selected_backup_diff(compare_to="saved")).grid(row=0, column=2, padx=(0, 8))
        ttk.Button(backup_action_row, text="백업 경로 복사", command=self.copy_selected_message_backup_path).grid(row=0, column=3)
        self.message_backup_list = tk.Listbox(editor_backup_tab, height=7, exportselection=False)
        self.message_backup_list.grid(row=1, column=0, sticky="nsew", pady=(0, 8))
        self.message_backup_text = scrolledtext.ScrolledText(editor_backup_tab, wrap="word")
        self.message_backup_text.grid(row=2, column=0, sticky="nsew")
        self._refresh_message_editor_tab_heading()

        artifacts_tab_container, artifacts_tab = self._create_scrollable_tab(
            notebook,
            title="결과 / 산출물",
            footer_text="--- 화면 끝 ---",
        )
        artifacts_tab.columnconfigure(0, weight=3)
        artifacts_tab.columnconfigure(1, weight=2)
        artifacts_tab.rowconfigure(2, weight=1)
        self.artifacts_tab = artifacts_tab_container

        artifact_filters = ttk.LabelFrame(artifacts_tab, text="필터", padding=8)
        artifact_filters.grid(row=0, column=0, columnspan=2, sticky="ew")
        artifact_filters.columnconfigure(1, weight=1)
        artifact_filters.columnconfigure(3, weight=1)
        artifact_filters.columnconfigure(5, weight=1)

        ttk.Label(artifact_filters, text="RunRoot").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.artifact_run_root_entry = ttk.Entry(artifact_filters, textvariable=self.artifact_run_root_filter_var)
        self.artifact_run_root_entry.grid(row=0, column=1, sticky="ew")
        ttk.Label(artifact_filters, text="Pair 필터").grid(row=0, column=2, sticky="e", padx=(12, 8))
        self.artifact_pair_combo = ttk.Combobox(artifact_filters, textvariable=self.artifact_pair_filter_var, values=[""])
        self.artifact_pair_combo.grid(row=0, column=3, sticky="ew")
        ttk.Label(artifact_filters, text="Target 필터").grid(row=0, column=4, sticky="e", padx=(12, 8))
        self.artifact_target_combo = ttk.Combobox(artifact_filters, textvariable=self.artifact_target_filter_var, values=[""])
        self.artifact_target_combo.grid(row=0, column=5, sticky="ew")
        ttk.Button(artifact_filters, text="결과 새로고침", command=self.refresh_artifacts_status).grid(row=0, column=6, padx=(12, 0))

        ttk.Checkbutton(
            artifact_filters,
            text="산출물 있는 target만",
            variable=self.artifact_latest_only_var,
            command=self.refresh_artifacts_tab,
        ).grid(row=1, column=1, sticky="w", pady=(8, 0))
        ttk.Checkbutton(
            artifact_filters,
            text="문제 / 누락 포함",
            variable=self.artifact_include_missing_var,
            command=self.refresh_artifacts_tab,
        ).grid(row=1, column=3, sticky="w", pady=(8, 0))
        artifact_scope_actions = ttk.Frame(artifact_filters)
        artifact_scope_actions.grid(row=2, column=0, columnspan=5, sticky="w", pady=(8, 0))
        ttk.Button(artifact_scope_actions, text="현재 실행 Pair/Target 반영", command=self.sync_artifact_filters_to_action_context).grid(row=0, column=0, padx=(0, 8))
        ttk.Button(
            artifact_scope_actions,
            textvariable=self.artifact_home_browse_toggle_var,
            command=self.toggle_artifact_home_pair_scope,
        ).grid(row=0, column=1, padx=(0, 8))
        ttk.Button(
            artifact_scope_actions,
            textvariable=self.artifact_home_browse_target_toggle_var,
            command=self.toggle_artifact_home_target_scope,
        ).grid(row=0, column=2, padx=(0, 8))
        ttk.Button(artifact_scope_actions, text="필터 지우기", command=self.clear_artifact_filters).grid(row=0, column=3)
        ttk.Label(artifact_filters, textvariable=self.artifact_status_var, wraplength=820, justify="left").grid(
            row=1,
            column=5,
            columnspan=2,
            sticky="e",
            pady=(8, 0),
        )

        self.artifact_tree = ttk.Treeview(
            artifacts_tab,
            columns=("pair", "target", "role", "state", "summary", "zip", "error", "fail", "modified"),
            show="headings",
            height=16,
        )
        for column, heading, width in (
            ("pair", "Pair", 80),
            ("target", "Target", 90),
            ("role", "역할", 70),
            ("state", "상태", 170),
            ("summary", "Summary", 80),
            ("zip", "Zip", 60),
            ("error", "Error", 60),
            ("fail", "Fail", 60),
            ("modified", "최근 수정", 170),
        ):
            self.artifact_tree.heading(column, text=heading)
            self.artifact_tree.column(column, width=width, stretch=(column in {"state", "modified"}))
        self.artifact_tree.grid(row=2, column=0, sticky="nsew", pady=(10, 0), padx=(0, 10))
        self.artifact_tree.bind("<<TreeviewSelect>>", self.on_artifact_row_selected)

        artifact_right = ttk.Frame(artifacts_tab)
        artifact_right.grid(row=2, column=1, sticky="nsew", pady=(10, 0))
        artifact_right.columnconfigure(0, weight=1)
        artifact_right.rowconfigure(1, weight=1)
        artifact_right.rowconfigure(2, weight=1)

        artifact_actions = ttk.LabelFrame(artifact_right, text="상태 확인 / 열기", padding=8)
        artifact_actions.grid(row=0, column=0, sticky="ew")
        for column in range(3):
            artifact_actions.columnconfigure(column, weight=1)
        artifact_action_groups = [
            (
                "상태 확인",
                [
                    ("summary 열기", "summary"),
                    ("latest zip 열기", "review_zip"),
                    ("error 열기", "error"),
                    ("result 열기", "result"),
                ],
            ),
            (
                "작업 실행",
                [
                    ("watch 시작", "watch_start"),
                    ("target check 실행", "artifact_check"),
                    ("target submit 실행", "artifact_import"),
                ],
            ),
            (
                "경로 / 폴더",
                [
                    ("request 열기", "request"),
                    ("done 열기", "done"),
                    ("target 폴더", "target_folder"),
                    ("review 폴더", "review_folder"),
                ],
            ),
        ]
        for column, (title, specs) in enumerate(artifact_action_groups):
            group = ttk.LabelFrame(artifact_actions, text=title, padding=8)
            group.grid(row=0, column=column, sticky="nsew", padx=(0, 8) if column < 2 else (0, 0))
            for idx, (label, kind) in enumerate(specs):
                if kind == "watch_start":
                    command = self.start_watcher_detached
                elif kind == "artifact_check":
                    command = self.check_selected_external_artifact
                elif kind == "artifact_import":
                    command = self.import_selected_external_artifact
                else:
                    command = (lambda kind=kind: self.open_selected_artifact_path(kind))
                button = ttk.Button(group, text=label, command=command)
                button.grid(row=idx // 2, column=idx % 2, padx=(0, 8) if idx % 2 == 0 else (0, 0), pady=(0, 6), sticky="ew")
                if kind in {"watch_start", "artifact_check", "artifact_import"}:
                    self.long_task_widgets.append(button)
                    if kind == "watch_start":
                        self.artifact_watch_button = button

        copy_row = ttk.Frame(artifact_actions)
        copy_row.grid(row=1, column=0, columnspan=3, sticky="ew", pady=(8, 0))
        copy_row.columnconfigure(0, weight=1)
        ttk.Combobox(
            copy_row,
            textvariable=self.artifact_path_kind_var,
            values=[label for label, _kind in ARTIFACT_PATH_OPTIONS],
            width=18,
            state="readonly",
        ).grid(row=0, column=0, sticky="w")
        ttk.Button(copy_row, text="선택 경로 복사", command=self.copy_selected_artifact_path).grid(row=0, column=1, padx=(8, 0))

        artifact_summary_frame = ttk.LabelFrame(artifact_right, text="summary 미리보기", padding=6)
        artifact_summary_frame.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
        artifact_summary_frame.columnconfigure(0, weight=1)
        artifact_summary_frame.rowconfigure(1, weight=1)
        artifact_summary_header = ttk.Frame(artifact_summary_frame)
        artifact_summary_header.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        artifact_summary_header.columnconfigure(0, weight=1)
        ttk.Label(artifact_summary_header, text="핵심 summary만 먼저 보고, 경로/상태는 아래에서 필요할 때 펼칩니다.").grid(row=0, column=0, sticky="w")
        ttk.Button(artifact_summary_header, textvariable=self.artifact_summary_toggle_var, command=self.toggle_artifact_summary_section).grid(row=0, column=1, sticky="e")
        artifact_summary_body_frame = ttk.Frame(artifact_summary_frame)
        artifact_summary_body_frame.grid(row=1, column=0, sticky="nsew")
        artifact_summary_body_frame.columnconfigure(0, weight=1)
        artifact_summary_body_frame.rowconfigure(0, weight=1)
        self.artifact_summary_body_frame = artifact_summary_body_frame
        self.artifact_summary_text = scrolledtext.ScrolledText(artifact_summary_body_frame, wrap="word")
        self.artifact_summary_text.grid(row=0, column=0, sticky="nsew")

        artifact_details_frame = ttk.LabelFrame(artifact_right, text="경로 / 상태", padding=6)
        artifact_details_frame.grid(row=2, column=0, sticky="nsew", pady=(10, 0))
        artifact_details_frame.columnconfigure(0, weight=1)
        artifact_details_frame.rowconfigure(1, weight=1)
        artifact_details_header = ttk.Frame(artifact_details_frame)
        artifact_details_header.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        artifact_details_header.columnconfigure(0, weight=1)
        ttk.Label(artifact_details_header, text="RunRoot 차이, contract 경로, wrapper 경로는 필요할 때만 펼칩니다.").grid(row=0, column=0, sticky="w")
        ttk.Button(artifact_details_header, textvariable=self.artifact_details_toggle_var, command=self.toggle_artifact_details_section).grid(row=0, column=1, sticky="e")
        artifact_details_body_frame = ttk.Frame(artifact_details_frame)
        artifact_details_body_frame.grid(row=1, column=0, sticky="nsew")
        artifact_details_body_frame.columnconfigure(0, weight=1)
        artifact_details_body_frame.rowconfigure(0, weight=1)
        self.artifact_details_body_frame = artifact_details_body_frame
        self.artifact_details_text = scrolledtext.ScrolledText(artifact_details_body_frame, wrap="word")
        self.artifact_details_text.grid(row=0, column=0, sticky="nsew")

        visible_tab_container, visible_tab = self._create_scrollable_tab(
            notebook,
            title="Visible Acceptance",
            footer_text="--- 화면 끝 ---",
        )
        visible_tab.columnconfigure(0, weight=1)
        visible_tab.rowconfigure(3, weight=1)
        self.visible_acceptance_tab = visible_tab_container

        visible_header = ttk.LabelFrame(visible_tab, text="shared visible 공식 절차", padding=8)
        visible_header.grid(row=0, column=0, sticky="ew")
        visible_header.columnconfigure(0, weight=1)
        ttk.Label(visible_header, textvariable=self.visible_acceptance_status_var, font=("Segoe UI", 10, "bold")).grid(row=0, column=0, sticky="w")
        ttk.Label(visible_header, textvariable=self.visible_acceptance_detail_var, wraplength=1200, justify="left").grid(row=1, column=0, sticky="w", pady=(6, 0))
        ttk.Label(
            visible_header,
            text="Headless Drill과 분리된 운영 절차입니다. active를 못 돌리는 시점이면 confirm만 사용합니다.",
            wraplength=1200,
            justify="left",
        ).grid(row=2, column=0, sticky="w", pady=(6, 0))

        visible_actions = ttk.Frame(visible_tab)
        visible_actions.grid(row=1, column=0, sticky="ew", pady=(10, 0))
        visible_actions.columnconfigure(0, weight=1)
        visible_actions.columnconfigure(1, weight=1)

        visible_gate_frame = ttk.LabelFrame(visible_actions, text="지금 시작 / 게이트", padding=8)
        visible_gate_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        for column in range(3):
            visible_gate_frame.columnconfigure(column, weight=1)
        for idx, (label, callback, attr_name) in enumerate(
            [
                ("cleanup 미리보기", self.run_visible_queue_cleanup_dry_run, "visible_cleanup_dry_button"),
                ("cleanup 적용", self.run_visible_queue_cleanup_apply, "visible_cleanup_apply_button"),
                ("입력 전 점검", self.run_visible_acceptance_preflight, "visible_preflight_button"),
                ("post-cleanup", self.run_visible_post_cleanup, "visible_post_cleanup_button"),
                ("clean preflight 재확인", self.run_visible_clean_preflight_recheck, "visible_clean_preflight_button"),
            ]
        ):
            button = ttk.Button(visible_gate_frame, text=label, command=callback)
            button.grid(row=idx // 3, column=idx % 3, padx=(0, 8), pady=(0, 8), sticky="ew")
            self.long_task_widgets.append(button)
            setattr(self, attr_name, button)

        visible_exec_frame = ttk.LabelFrame(visible_actions, text="상태 확인 / 판정", padding=8)
        visible_exec_frame.grid(row=0, column=1, sticky="nsew")
        for idx, (label, callback, attr_name) in enumerate(
            [
                ("실제 acceptance 실행", self.run_active_visible_acceptance, "visible_active_acceptance_button"),
                ("shared confirm", self.run_shared_visible_confirm, "visible_confirm_button"),
                ("receipt 확인", self.run_visible_receipt_confirm, "visible_receipt_confirm_button"),
            ]
        ):
            button = ttk.Button(visible_exec_frame, text=label, command=callback)
            button.grid(row=0, column=idx, padx=(0, 8))
            self.long_task_widgets.append(button)
            setattr(self, attr_name, button)
        ttk.Label(
            visible_exec_frame,
            text="confirm은 pair disable 상태에서도 기존 RunRoot / receipt 재검증 용도로 유지됩니다.",
            wraplength=520,
            justify="left",
        ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(8, 0))

        visible_primitive_frame = ttk.LabelFrame(visible_tab, text="복구 / 수동 단계", padding=8)
        visible_primitive_frame.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        visible_primitive_frame.columnconfigure(0, weight=1)
        visible_primitive_frame.columnconfigure(1, weight=1)
        visible_primitive_frame.columnconfigure(2, weight=1)
        ttk.Label(
            visible_primitive_frame,
            textvariable=self.visible_primitive_status_var,
            font=("Segoe UI", 10, "bold"),
        ).grid(row=0, column=0, columnspan=3, sticky="w")
        ttk.Label(
            visible_primitive_frame,
            textvariable=self.visible_primitive_detail_var,
            wraplength=1200,
            justify="left",
        ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(6, 0))
        primitive_stage_row = ttk.Frame(visible_primitive_frame)
        primitive_stage_row.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(6, 0))
        primitive_stage_badge_label = tk.Label(
            primitive_stage_row,
            textvariable=self.visible_primitive_stage_badge_var,
            bg="#6B7280",
            fg="#FFFFFF",
            padx=8,
            pady=2,
        )
        primitive_stage_badge_label.grid(row=0, column=0, sticky="w")
        self.visible_primitive_stage_badge_label = primitive_stage_badge_label
        ttk.Label(
            primitive_stage_row,
            textvariable=self.visible_primitive_stage_detail_var,
            wraplength=1020,
            justify="left",
        ).grid(row=0, column=1, sticky="w", padx=(8, 0))
        primitive_stage_action_button = ttk.Button(
            primitive_stage_row,
            textvariable=self.visible_primitive_stage_action_button_var,
            command=self.run_visible_primitive_stage_action,
        )
        primitive_stage_action_button.grid(row=0, column=2, sticky="e", padx=(12, 0))
        self.visible_primitive_stage_action_button = primitive_stage_action_button

        primitive_action_groups = [
            (
                "문맥 준비",
                "공식 창 재사용, 입력 가능 여부, 상대 target 문맥부터 맞춥니다.",
                [
                    ("공식 8창 재사용", self.reuse_existing_windows, "visible_primitive_reuse_button"),
                    ("typed-window 입력 점검", self.run_visibility_check, "visible_primitive_visibility_button"),
                    ("상대 target 선택", self.select_partner_target_from_context, "visible_primitive_partner_button"),
                ],
            ),
            (
                "문구 / preview",
                "현재 편집본을 다시 계산하거나 저장한 뒤 선택 target preview를 따로 남깁니다.",
                [
                    ("편집본 preview 갱신", self.refresh_message_editor_preview, "visible_primitive_preview_refresh_button"),
                    ("고정문구 저장 + 새로고침", self.save_message_editor, "visible_primitive_save_button"),
                    ("선택 target preview 저장", self.export_selected_row_messages, "visible_primitive_export_button"),
                ],
            ),
            (
                "수동 submit / 확인",
                "실제 1회 submit 뒤 publish 상태와 handoff 결과를 순서대로 확인합니다.",
                [
                    ("선택 target 1회 submit", self.run_selected_target_seed_submit, "visible_primitive_submit_button"),
                    ("publish 확인", self.inspect_selected_target_publish_status, "visible_primitive_publish_button"),
                    ("handoff 확인", self.inspect_selected_pair_handoff_status, "visible_primitive_handoff_button"),
                ],
            ),
        ]
        for column, (title, description, specs) in enumerate(primitive_action_groups):
            group = ttk.LabelFrame(visible_primitive_frame, text=title, padding=8)
            group.grid(row=3, column=column, sticky="nsew", padx=(0, 8) if column < 2 else (0, 0), pady=(8, 0))
            group.columnconfigure(0, weight=1)
            ttk.Label(group, text=description, wraplength=340, justify="left").grid(row=0, column=0, sticky="w", pady=(0, 8))
            for row_index, (label, callback, attr_name) in enumerate(specs, start=1):
                button = ttk.Button(group, text=label, command=callback)
                button.grid(row=row_index, column=0, sticky="ew", pady=(0, 8) if row_index < len(specs) else (0, 0))
                self.long_task_widgets.append(button)
                setattr(self, attr_name, button)
        ttk.Label(
            visible_primitive_frame,
            text="매크로를 대체하지 않습니다. 현재 선택 pair/target 기준으로 preview/apply -> submit -> publish/handoff를 잘라 디버깅하는 보조 버튼입니다.",
            wraplength=1200,
            justify="left",
        ).grid(row=4, column=0, columnspan=3, sticky="w", pady=(8, 0))

        visible_result_frame = ttk.LabelFrame(visible_tab, text="결과 / receipt 요약", padding=6)
        visible_result_frame.grid(row=3, column=0, sticky="nsew", pady=(10, 0))
        visible_result_frame.columnconfigure(0, weight=1)
        visible_result_frame.rowconfigure(1, weight=1)
        visible_receipt_actions = ttk.Frame(visible_result_frame)
        visible_receipt_actions.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        self.visible_receipt_open_button = ttk.Button(visible_receipt_actions, text="receipt 열기", command=self.open_visible_receipt_path)
        self.visible_receipt_open_button.grid(row=0, column=0, padx=(0, 8))
        self.visible_receipt_copy_button = ttk.Button(visible_receipt_actions, text="receipt 경로 복사", command=self.copy_visible_receipt_path)
        self.visible_receipt_copy_button.grid(row=0, column=1, padx=(0, 8))
        self.visible_acceptance_text = scrolledtext.ScrolledText(visible_result_frame, wrap="word")
        self.visible_acceptance_text.grid(row=1, column=0, sticky="nsew")

        ops_tab_container, ops_tab = self._create_scrollable_tab(
            notebook,
            title="Headless Drill / 진단",
            footer_text="--- 화면 끝 ---",
        )
        ops_tab.columnconfigure(0, weight=1)
        ops_tab.rowconfigure(2, weight=1)
        self.ops_tab = ops_tab_container

        ops_action_groups = ttk.Frame(ops_tab)
        ops_action_groups.grid(row=0, column=0, sticky="ew")
        for column in range(3):
            ops_action_groups.columnconfigure(column, weight=1)
        grouped_ops_buttons = [
            (
                "지금 시작",
                [
                    ("pair01 preset 실행", self.run_fixed_pair01_drill, "fixed_pair01_button"),
                    ("선택 Pair 실행", self.run_selected_pair_drill, "selected_pair_button"),
                    ("watch 시작", self.start_watcher_detached, "ops_quick_start_watch_button"),
                    ("watch 시작(입력값)", self.start_watcher_with_options, "ops_start_watch_button"),
                    ("창 입력 가능 확인", self.run_visibility_check, ""),
                    ("Headless 준비 확인", self.run_headless_readiness, ""),
                ],
            ),
            (
                "상태 확인",
                [
                    ("릴레이 상태", self.run_relay_status, ""),
                    ("페어 상태", self.run_paired_status, ""),
                    ("runroot 요약", self.run_paired_summary, ""),
                    ("요약 리포트 열기", self.open_important_summary_text, ""),
                    ("적용 설정 JSON", self.run_effective_json, ""),
                ],
            ),
            (
                "복구 / 제어",
                [
                    ("watch 일시중지", self.request_pause_watcher, "ops_pause_watch_button"),
                    ("watch 재개", self.request_resume_watcher, "ops_resume_watch_button"),
                    ("watch 정지 요청", self.request_stop_watcher, "ops_stop_watch_button"),
                    ("watch 재시작", self.restart_watcher, "ops_restart_watch_button"),
                    ("watch stale 정리", self.recover_stale_watcher_state, "ops_recover_watch_button"),
                    ("watch 진단", self.show_watcher_diagnostics, ""),
                    ("watch 권장 조치", self.apply_watcher_recommended_action, ""),
                    ("watch audit 로그", self.open_watcher_audit_log, ""),
                    ("watch status 파일", self.open_watcher_status_file, ""),
                    ("watch control 파일", self.open_watcher_control_file, ""),
                ],
            ),
        ]
        read_only_ops_labels = {"릴레이 상태", "페어 상태", "runroot 요약", "요약 리포트 열기", "Headless 준비 확인", "적용 설정 JSON", "watch 진단", "watch audit 로그", "watch status 파일", "watch control 파일"}
        for column, (title, specs) in enumerate(grouped_ops_buttons):
            group = ttk.LabelFrame(ops_action_groups, text=title, padding=8)
            group.grid(row=0, column=column, sticky="nsew", padx=(0, 8) if column < 2 else (0, 0))
            for idx, (label, callback, attr_name) in enumerate(specs):
                button = ttk.Button(group, text=label, command=callback)
                button.grid(row=idx // 2, column=idx % 2, sticky="ew", padx=(0, 8) if idx % 2 == 0 else (0, 0), pady=(0, 8))
                self.long_task_widgets.append(button)
                if label in read_only_ops_labels:
                    self._register_read_only_widget(button)
                if attr_name:
                    setattr(self, attr_name, button)

        watcher_options_frame = ttk.LabelFrame(ops_tab, text="watch 시작 / 재시작 입력값", padding=8)
        watcher_options_frame.grid(row=1, column=0, sticky="ew", pady=(10, 0))
        for column in range(8):
            watcher_options_frame.columnconfigure(column, weight=0)
        watcher_options_frame.columnconfigure(7, weight=1)

        ttk.Label(watcher_options_frame, text="MaxForwardCount").grid(row=0, column=0, sticky="w")
        ttk.Entry(watcher_options_frame, textvariable=self.watcher_max_forward_var, width=8).grid(row=0, column=1, sticky="w", padx=(6, 12))
        ttk.Label(watcher_options_frame, text="RunDurationSec").grid(row=0, column=2, sticky="w")
        ttk.Entry(watcher_options_frame, textvariable=self.watcher_run_duration_var, width=8).grid(row=0, column=3, sticky="w", padx=(6, 12))
        ttk.Label(watcher_options_frame, text="PairMaxRoundtripCount").grid(row=0, column=4, sticky="w")
        ttk.Entry(watcher_options_frame, textvariable=self.watcher_pair_roundtrip_var, width=8).grid(row=0, column=5, sticky="w", padx=(6, 12))
        self.ops_reset_watch_options_button = ttk.Button(
            watcher_options_frame,
            text="watch preset 기본값",
            command=self.reset_watcher_start_options,
        )
        self.ops_reset_watch_options_button.grid(row=0, column=6, sticky="w")
        self.ops_load_watch_options_button = ttk.Button(
            watcher_options_frame,
            text="현재 watcher 값 반영",
            command=self.load_watcher_start_options_from_status,
        )
        self.ops_load_watch_options_button.grid(row=0, column=7, sticky="w", padx=(8, 0))
        ttk.Label(
            watcher_options_frame,
            textvariable=self.watcher_quick_start_note_var,
            wraplength=920,
            justify="left",
        ).grid(row=1, column=0, columnspan=8, sticky="w", pady=(8, 0))
        ttk.Label(
            watcher_options_frame,
            textvariable=self.watcher_current_note_var,
            wraplength=920,
            justify="left",
        ).grid(row=2, column=0, columnspan=8, sticky="w", pady=(6, 0))
        ttk.Label(
            watcher_options_frame,
            textvariable=self.watcher_start_note_var,
            wraplength=920,
            justify="left",
        ).grid(row=3, column=0, columnspan=8, sticky="w", pady=(6, 0))
        ttk.Label(
            watcher_options_frame,
            textvariable=self.watcher_control_note_var,
            wraplength=920,
            justify="left",
        ).grid(row=4, column=0, columnspan=8, sticky="w", pady=(6, 0))

        for child in controls.winfo_children():
            if isinstance(child, ttk.Combobox):
                child.bind("<<ComboboxSelected>>", self.on_pair_or_target_changed)

        self.artifact_pair_combo.bind("<<ComboboxSelected>>", self.refresh_artifacts_tab)
        self.artifact_target_combo.bind("<<ComboboxSelected>>", self.refresh_artifacts_tab)
        self.artifact_run_root_entry.bind("<Return>", self.refresh_artifacts_tab)

        ttk.Label(
            ops_tab,
            text="작업 출력과 조회 결과는 하단 공용 패널에서 확인합니다.",
            justify="left",
        ).grid(row=2, column=0, sticky="w", pady=(10, 0))

        snapshots_tab = ttk.Frame(notebook, padding=10)
        snapshots_tab.columnconfigure(0, weight=1)
        snapshots_tab.columnconfigure(1, weight=2)
        snapshots_tab.rowconfigure(1, weight=1)
        notebook.add(snapshots_tab, text="스냅샷")
        self.snapshots_tab = snapshots_tab

        snapshot_actions = ttk.Frame(snapshots_tab)
        snapshot_actions.grid(row=0, column=0, columnspan=2, sticky="ew")
        for idx, (label, callback) in enumerate(
            [
                ("스냅샷 새로고침", self.refresh_snapshot_list),
                ("스냅샷 열기", self.open_selected_snapshot),
                ("스냅샷 경로 복사", self.copy_selected_snapshot_path),
                ("RunRoot 열기", self.open_selected_snapshot_run_root),
                ("RunRoot 경로 복사", self.copy_selected_snapshot_run_root_path),
                ("스냅샷 JSON 보기", self.view_selected_snapshot_json),
            ]
        ):
            ttk.Button(snapshot_actions, text=label, command=callback).grid(row=0, column=idx, padx=(0, 8))

        self.snapshot_tree = ttk.Treeview(
            snapshots_tab,
            columns=("name", "modified", "size", "stale", "warnings"),
            show="headings",
            height=18,
        )
        for column, heading, width in (
            ("name", "파일", 280),
            ("modified", "수정시각", 190),
            ("size", "크기", 90),
            ("stale", "오래됨", 70),
            ("warnings", "경고수", 80),
        ):
            self.snapshot_tree.heading(column, text=heading)
            self.snapshot_tree.column(column, width=width, stretch=(column == "name"))
        self.snapshot_tree.grid(row=1, column=0, sticky="nsew", pady=(10, 0), padx=(0, 10))
        self.snapshot_tree.bind("<<TreeviewSelect>>", self.on_snapshot_selected)

        self.snapshot_text = scrolledtext.ScrolledText(snapshots_tab, wrap="word")
        self.snapshot_text.grid(row=1, column=1, sticky="nsew", pady=(10, 0))

        self.message_template_combo.bind("<<ComboboxSelected>>", self.on_message_editor_scope_changed)
        self.message_scope_combo.bind("<<ComboboxSelected>>", self.on_message_editor_scope_changed)
        self.message_scope_id_combo.bind("<<ComboboxSelected>>", self.on_message_editor_scope_changed)
        self.target_fixed_combo.bind("<<ComboboxSelected>>", self.on_target_fixed_selection_changed)
        self.message_block_filter_entry.bind("<KeyRelease>", self.on_message_block_filter_changed)
        self.message_blocks_list.bind("<<ListboxSelect>>", self.on_message_block_selected)
        self.message_blocks_list.bind("<ButtonPress-1>", self.on_message_block_press)
        self.message_blocks_list.bind("<B1-Motion>", self.on_message_block_drag)
        self.message_blocks_list.bind("<ButtonRelease-1>", self.on_message_block_release)
        self.message_backup_list.bind("<<ListboxSelect>>", self.on_message_backup_selected)
        self.message_slot_order_list.bind("<<ListboxSelect>>", self.on_message_slot_selected)
        self.message_slot_order_list.bind("<ButtonPress-1>", self.on_message_slot_press)
        self.message_slot_order_list.bind("<B1-Motion>", self.on_message_slot_drag)
        self.message_slot_order_list.bind("<ButtonRelease-1>", self.on_message_slot_release)
        self._apply_header_compact_mode()
        self._apply_result_panel_dock_mode()
        self._apply_result_panel_visibility()
        self._apply_artifact_section_visibility()
        self._apply_message_fixed_section_visibility()
        self._apply_message_block_focus_mode()
        self._refresh_sticky_context_bar()

    def browse_config(self) -> None:
        selected = filedialog.askopenfilename(
            title="PowerShell 설정 파일 선택",
            initialdir=str(ROOT / "config"),
            filetypes=[("PowerShell Data File", "*.psd1"), ("All files", "*.*")],
        )
        if selected:
            self.config_path_var.set(selected)

    def copy_last_command(self) -> None:
        command = self.last_command_var.get()
        if not command:
            return
        self.clipboard_clear()
        self.clipboard_append(command)

    def set_operator_status(self, state: str, hint: str = "", last_result: str = "") -> None:
        self.operator_status_var.set(state)
        if hint:
            self.operator_hint_var.set(hint)
        if last_result:
            self.last_result_var.set(last_result)
        self._refresh_sticky_context_bar()

    def _apply_watcher_panel_update(self, update: WatcherPanelUpdate) -> None:
        if update.command_text:
            self.last_command_var.set(update.command_text)
        self.set_text(self.output_text, update.output_text)
        if update.operator_state or update.operator_hint or update.last_result:
            self.set_operator_status(update.operator_state, update.operator_hint, update.last_result)

    def set_busy(self, state: str, hint: str) -> None:
        self._busy = True
        for widget in self.long_task_widgets:
            if self._widget_is_read_only(widget):
                continue
            widget.configure(state="disabled")
        self.set_operator_status(state, hint)
        if self.panel_state:
            self.render_home_dashboard()

    def set_idle(self, state: str = "대기 중", hint: str = "", last_result: str = "") -> None:
        self._busy = False
        for widget in self.long_task_widgets:
            widget.configure(state="normal")
        self.set_operator_status(state, hint, last_result)
        self.update_pair_button_states()
        if self.panel_state:
            self.render_home_dashboard()

    def run_background_task(
        self,
        *,
        state: str,
        hint: str,
        worker,
        on_success,
        success_state: str,
        success_hint: str,
        failure_state: str,
        failure_hint: str,
        on_failure=None,
    ) -> None:
        if self._busy:
            messagebox.showwarning("작업 중", "다른 작업이 실행 중입니다. 현재 작업이 끝난 뒤 다시 시도하세요.")
            return

        self.set_busy(state, hint)

        def runner() -> None:
            try:
                result = worker()
            except Exception as exc:
                self.after(0, lambda exc=exc: self._handle_background_failure(exc, failure_state, failure_hint, on_failure))
                return

            self.after(
                0,
                lambda result=result: self._handle_background_success(
                    result,
                    on_success,
                    success_state,
                    success_hint,
                    failure_state,
                    failure_hint,
                ),
            )

        threading.Thread(target=runner, daemon=True).start()

    def run_read_only_background_task(
        self,
        *,
        label: str,
        worker,
        on_success,
        on_failure=None,
    ) -> None:
        def runner() -> None:
            try:
                result = worker()
            except Exception as exc:
                self.after(0, lambda exc=exc: self._handle_read_only_background_failure(exc, label, on_failure))
                return
            self.after(0, lambda result=result: self._handle_read_only_background_success(result, label, on_success))

        threading.Thread(target=runner, daemon=True).start()

    def _handle_background_failure(self, exc: Exception, state: str, hint: str, on_failure=None) -> None:
        rendered_exc = exc
        output_text = self._format_background_exception(exc)
        if on_failure is not None:
            try:
                replacement = on_failure(exc)
                if isinstance(replacement, str) and replacement.strip():
                    output_text = replacement
            except Exception as callback_exc:
                rendered_exc = callback_exc
                output_text = (
                    self._format_background_exception(callback_exc)
                    + "\n\nOriginal Background Error:\n"
                    + self._format_background_exception(exc)
                )
        self.set_text(self.output_text, output_text)
        self.set_idle(state, hint, f"마지막 결과: 실패 ({rendered_exc})")

    def _handle_read_only_background_failure(self, exc: Exception, label: str, on_failure=None) -> None:
        rendered_exc = exc
        output_text = self._format_background_exception(exc)
        if on_failure is not None:
            try:
                replacement = on_failure(exc)
                if isinstance(replacement, str) and replacement.strip():
                    output_text = replacement
            except Exception as callback_exc:
                rendered_exc = callback_exc
                output_text = (
                    self._format_background_exception(callback_exc)
                    + "\n\nOriginal Background Error:\n"
                    + self._format_background_exception(exc)
                )
        self.set_query_text(output_text)
        self.set_query_result(
            f"마지막 조회: {label} 실패 ({rendered_exc})",
            context=self._query_context_summary(),
        )

    def _handle_background_follow_up_failure(self, exc: Exception, state: str, hint: str) -> None:
        self.set_text(self.output_text, self._format_background_exception(exc))
        self.set_idle(state, hint, f"마지막 결과: 실패 ({exc})")

    def _format_background_exception(self, exc: Exception) -> str:
        if not isinstance(exc, PowerShellError):
            return str(exc)

        lines = [str(exc)]
        if exc.returncode is not None:
            lines.append(f"ReturnCode: {exc.returncode}")

        stdout = exc.stdout.strip()
        stderr = exc.stderr.strip()
        if stdout:
            lines.extend(["", "STDOUT:", stdout])
        if stderr:
            lines.extend(["", "STDERR:", stderr])
        return "\n".join(lines)

    def _handle_read_only_background_success(self, result, label: str, on_success) -> None:
        try:
            on_success(result)
        except Exception as exc:
            self.set_query_text(self._format_background_exception(exc))
            self.set_query_result(
                f"마지막 조회: {label} 실패 ({exc})",
                context=self._query_context_summary(),
            )

    def _handle_background_success(
        self,
        result,
        on_success,
        state: str,
        hint: str,
        failure_state: str,
        failure_hint: str,
    ) -> None:
        idle_state = state
        idle_hint = hint
        last_result = ""
        follow_up = None
        success = False
        try:
            follow_up = on_success(result)
            success = True
        except Exception as exc:
            idle_state = failure_state
            idle_hint = failure_hint
            last_result = f"마지막 결과: 실패 ({exc})"
            self.set_text(self.output_text, self._format_background_exception(exc))
        finally:
            self.set_idle(idle_state, idle_hint, last_result)

        if success and callable(follow_up):
            try:
                follow_up()
            except Exception as exc:
                self._handle_background_follow_up_failure(exc, failure_state, failure_hint)

    def _selected_preview_row(self) -> dict | None:
        if not self._has_ui_attr("row_tree"):
            return None
        selection_method = getattr(self.row_tree, "selection", None)
        if selection_method is None:
            return None
        selection = selection_method()
        if not selection:
            return None
        return self.preview_rows[int(selection[0])]

    def _selected_inspection_context(self) -> tuple[str, str]:
        inspection_context = self._selected_inspection_context_state()
        return inspection_context.pair_id, inspection_context.target_id

    def _set_inspection_context(
        self,
        *,
        pair_id: str = "",
        target_id: str = "",
        source: str = "",
        row_index: int | None = None,
    ) -> InspectionContextState:
        self.inspection_pair_id = str(pair_id or "").strip()
        self.inspection_target_id = str(target_id or "").strip()
        self.inspection_context_source = str(source or "").strip()
        self.inspection_context_row_index = row_index if isinstance(row_index, int) else None
        return self._stored_inspection_context_state()

    def _selected_inspection_pair_id(self) -> str:
        inspection_context = self._selected_inspection_context_state()
        if inspection_context.pair_id:
            return inspection_context.pair_id
        return self._selected_pair_id()

    def _selected_inspection_target_id(self) -> str:
        return self._selected_inspection_context_state().target_id

    def _inspection_context_differs_from_action(self) -> bool:
        inspection_context = self._selected_inspection_context_state()
        action_context = self._action_context_state()
        return bool(
            (inspection_context.pair_id and inspection_context.pair_id != action_context.pair_id)
            or (inspection_context.target_id and inspection_context.target_id != action_context.target_id)
        )

    def _copy_to_clipboard(self, value: str) -> None:
        self.clipboard_clear()
        self.clipboard_append(value)

    def get_pair_activation_state(self, pair_id: str) -> dict | None:
        if not self.effective_data or not pair_id:
            return None
        for item in self.effective_data.get("PairActivationSummary", []):
            if item.get("PairId", "") == pair_id:
                return item
        return None

    def _shared_visible_typed_window_headless_block_reason(self) -> str:
        effective = self.effective_data or {}
        config = (effective.get("Config", {}) or {})
        pair_test = (effective.get("PairTest", {}) or {})
        lane_name = str(config.get("LaneName", "") or "").strip()
        execution_path_mode = str(pair_test.get("ExecutionPathMode", "") or "").strip()
        require_visible_cell_execution = bool(pair_test.get("RequireUserVisibleCellExecution", False))
        if (
            lane_name == "bottest-live-visible"
            and execution_path_mode == "typed-window"
            and require_visible_cell_execution
        ):
            return (
                "shared visible typed-window lane에서는 Headless Drill을 사용할 수 없습니다.\n"
                "Visible Acceptance 절차를 사용하세요.\n"
                "진단용 headless가 꼭 필요하면 shell wrapper에서 "
                "-AllowHeadlessDispatchInTypedWindowLane 를 명시한 경로만 사용해야 합니다."
            )
        return ""

    def _shared_visible_typed_window_headless_block_summary(self) -> str:
        if not self._shared_visible_typed_window_headless_block_reason():
            return ""
        return "headless=차단(shared visible typed-window)"

    def _watcher_status(self) -> str:
        status = self._watcher_runtime_status()
        parts = [status.state]
        if getattr(status, "stop_category", ""):
            if str(status.stop_category) == "expected-limit":
                parts.append("정상 제한 종료")
            else:
                parts.append(str(status.stop_category))
        elif status.status_reason:
            parts.append(str(status.status_reason))
        return "/".join(part for part in parts if part)

    def _watcher_runtime_status(self):
        return self.watcher_controller.runtime_status(self.paired_status_data, self._current_run_root_for_actions())

    def _watcher_start_eligibility(self):
        return self.watcher_controller.start_eligibility(self.paired_status_data, self._current_run_root_for_actions())

    def _watcher_stop_eligibility(self):
        return self.watcher_controller.stop_eligibility(self.paired_status_data, self._current_run_root_for_actions())

    def _watcher_runtime_hint(self) -> str:
        return self.watcher_controller.runtime_hint(self.paired_status_data, self._current_run_root_for_actions())

    def _watcher_recommendation(self):
        return self.watcher_controller.recommended_action(self.paired_status_data, self._current_run_root_for_actions())

    def update_pair_button_states(self) -> None:
        if self._busy:
            return

        headless_block_reason = self._shared_visible_typed_window_headless_block_reason()
        headless_allowed = not bool(headless_block_reason)
        pair01_state = self.get_pair_activation_state("pair01")
        if self._has_ui_attr("fixed_pair01_button"):
            enabled = bool((pair01_state or {}).get("EffectiveEnabled", True)) and headless_allowed
            self.fixed_pair01_button.configure(state="normal" if enabled else "disabled")
            self.fixed_pair01_button.configure(text="pair01 preset 실행" if headless_allowed else "pair01 preset 실행 (shared visible 차단)")

        selected_pair = self.pair_id_var.get().strip()
        selected_state = self.get_pair_activation_state(selected_pair) if selected_pair else None
        home_pair_id = self._selected_home_pair_id() if self._has_ui_attr("home_pair_tree") else selected_pair
        home_selected_state = self.get_pair_activation_state(home_pair_id) if home_pair_id else None
        if self._has_ui_attr("selected_pair_button"):
            enabled, _detail = self._selected_pair_execution_allowed()
            enabled = enabled and headless_allowed
            self.selected_pair_button.configure(state="normal" if enabled else "disabled")
            self.selected_pair_button.configure(text="선택 Pair 실행" if headless_allowed else "선택 Pair 실행 (shared visible 차단)")

        if self._has_ui_attr("home_run_pair_button"):
            enabled, _detail = self._selected_pair_execution_allowed()
            enabled = enabled and headless_allowed
            self.home_run_pair_button.configure(state="normal" if enabled else "disabled")
            self.home_run_pair_button.configure(text="선택 Pair 실행" if headless_allowed else "선택 Pair 실행 (shared visible 차단)")

        if self._has_ui_attr("parallel_pair_drill_button"):
            enabled, _detail = self._selected_parallel_pair_execution_allowed()
            enabled = enabled and headless_allowed
            self.parallel_pair_drill_button.configure(state="normal" if enabled else "disabled")
            self.parallel_pair_drill_button.configure(text="선택 pair 병렬 실테스트" if headless_allowed else "선택 pair 병렬 실테스트 (shared visible 차단)")

        if self._has_ui_attr("home_apply_pair_button"):
            enabled = bool(home_pair_id) and home_pair_id != selected_pair
            self.home_apply_pair_button.configure(state="normal" if enabled else "disabled")

        if self._has_ui_attr("home_enable_pair_button"):
            enabled = bool(home_pair_id) and not bool((home_selected_state or {}).get("EffectiveEnabled", True))
            self.home_enable_pair_button.configure(state="normal" if enabled else "disabled")

        if self._has_ui_attr("home_disable_pair_button"):
            enabled = bool(home_pair_id) and bool((home_selected_state or {}).get("EffectiveEnabled", True))
            self.home_disable_pair_button.configure(state="normal" if enabled else "disabled")

        inspection_apply_enabled = self._inspection_context_differs_from_action()
        if self._has_ui_attr("preview_apply_context_button"):
            self.preview_apply_context_button.configure(state="normal" if inspection_apply_enabled else "disabled")
        if self._has_ui_attr("board_apply_context_button"):
            self.board_apply_context_button.configure(state="normal" if inspection_apply_enabled else "disabled")

        start_eligibility = self._watcher_start_eligibility()
        stop_eligibility = self._watcher_stop_eligibility()
        watch_start_allowed, _detail = self._watch_start_allowed()
        if self._has_ui_attr("home_start_watch_button"):
            self.home_start_watch_button.configure(state="normal" if watch_start_allowed else "disabled")
        if self._has_ui_attr("artifact_watch_button"):
            self.artifact_watch_button.configure(state="normal" if watch_start_allowed else "disabled")
        if self._has_ui_attr("ops_start_watch_button"):
            self.ops_start_watch_button.configure(state="normal" if watch_start_allowed else "disabled")
        if self._has_ui_attr("ops_quick_start_watch_button"):
            self.ops_quick_start_watch_button.configure(state="normal" if watch_start_allowed else "disabled")
        if self._has_ui_attr("ops_stop_watch_button"):
            self.ops_stop_watch_button.configure(state="normal" if stop_eligibility.allowed else "disabled")
        if self._has_ui_attr("ops_restart_watch_button"):
            restart_enabled = bool(self._current_run_root_for_actions()) and stop_eligibility.allowed and bool(self.config_path_var.get().strip())
            self.ops_restart_watch_button.configure(state="normal" if restart_enabled else "disabled")
        if self._has_ui_attr("ops_recover_watch_button"):
            self.ops_recover_watch_button.configure(state="normal" if start_eligibility.cleanup_allowed else "disabled")
        if self._has_ui_attr("ops_load_watch_options_button"):
            watcher = ((self.paired_status_data or {}).get("Watcher", {}) or {})
            self.ops_load_watch_options_button.configure(state="normal" if watcher else "disabled")
        if self._has_ui_attr("board_attach_button"):
            attach_allowed, _detail = self._attach_action_allowed()
            self.board_attach_button.configure(state="normal" if attach_allowed else "disabled")
        if self._has_ui_attr("board_visibility_button"):
            visibility_allowed, _detail = self._visibility_action_allowed()
            self.board_visibility_button.configure(state="normal" if visibility_allowed else "disabled")

        visible_state = self._refresh_visible_acceptance_summary()
        config_present = visible_state.config_present
        if self._has_ui_attr("visible_cleanup_dry_button"):
            self.visible_cleanup_dry_button.configure(state="normal" if config_present else "disabled")
        if self._has_ui_attr("visible_cleanup_apply_button"):
            self.visible_cleanup_apply_button.configure(state="normal" if config_present else "disabled")
        if self._has_ui_attr("visible_preflight_button"):
            self.visible_preflight_button.configure(state="normal" if visible_state.preflight_enabled else "disabled")
        if self._has_ui_attr("visible_active_acceptance_button"):
            self.visible_active_acceptance_button.configure(state="normal" if visible_state.active_enabled else "disabled")
        if self._has_ui_attr("visible_post_cleanup_button"):
            self.visible_post_cleanup_button.configure(state="normal" if visible_state.post_cleanup_enabled else "disabled")
        if self._has_ui_attr("visible_clean_preflight_button"):
            self.visible_clean_preflight_button.configure(state="normal" if visible_state.clean_preflight_enabled else "disabled")
        if self._has_ui_attr("visible_confirm_button"):
            self.visible_confirm_button.configure(state="normal" if visible_state.shared_confirm_enabled else "disabled")
        if self._has_ui_attr("visible_receipt_confirm_button"):
            self.visible_receipt_confirm_button.configure(state="normal" if visible_state.receipt_confirm_enabled else "disabled")
        receipt_path = visible_state.receipt_path.strip() or self._current_visible_receipt_path().strip()
        if self._has_ui_attr("visible_receipt_open_button"):
            self.visible_receipt_open_button.configure(state="normal" if (bool(receipt_path) and Path(receipt_path).exists()) else "disabled")
        if self._has_ui_attr("visible_receipt_copy_button"):
            self.visible_receipt_copy_button.configure(state="normal" if bool(receipt_path) else "disabled")
        self._refresh_visible_next_action_highlights(visible_state)

        primitive_row = self._resolve_visible_primitive_row()
        primitive_pair_id = str((primitive_row or {}).get("PairId", "") or self._selected_pair_id() or "").strip()
        primitive_target_id = str((primitive_row or {}).get("TargetId", "") or self.target_id_var.get().strip() or "").strip()
        primitive_partner_target_id = str((primitive_row or {}).get("PartnerTargetId", "") or "").strip()
        primitive_scope_allowed, primitive_scope_detail = self._pair_scope_allowed(
            primitive_pair_id,
            action_label="pair primitive",
        )
        primitive_active_run_root, primitive_active_run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label="pair primitive submit",
            allow_stale=False,
        )
        primitive_confirm_run_root, primitive_confirm_run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label="pair primitive 확인",
            allow_stale=True,
        )
        primitive_visibility_row = self._visibility_target_status_row(primitive_target_id) if primitive_target_id else None
        primitive_injectable = primitive_visibility_row is None or bool(primitive_visibility_row.get("Injectable", False))
        primitive_context_ready = bool(primitive_row and primitive_pair_id and primitive_target_id)
        primitive_message_ready = primitive_context_ready and self.__dict__.get("message_config_doc") is not None
        primitive_target_status = self._paired_target_status_row(primitive_target_id) if primitive_target_id else None
        primitive_pair_status = self._paired_pair_status_row(primitive_pair_id) if primitive_pair_id else None
        submit_enabled = False
        publish_enabled = False
        handoff_enabled = False
        if self._has_ui_attr("visible_primitive_reuse_button"):
            self.visible_primitive_reuse_button.configure(state="normal" if config_present else "disabled")
        if self._has_ui_attr("visible_primitive_visibility_button"):
            self.visible_primitive_visibility_button.configure(state="normal" if config_present else "disabled")
        if self._has_ui_attr("visible_primitive_preview_refresh_button"):
            self.visible_primitive_preview_refresh_button.configure(state="normal" if primitive_message_ready else "disabled")
        if self._has_ui_attr("visible_primitive_save_button"):
            self.visible_primitive_save_button.configure(state="normal" if primitive_message_ready else "disabled")
        if self._has_ui_attr("visible_primitive_export_button"):
            self.visible_primitive_export_button.configure(state="normal" if (primitive_context_ready and config_present) else "disabled")
        if self._has_ui_attr("visible_primitive_submit_button"):
            submit_enabled = (
                config_present
                and primitive_context_ready
                and primitive_scope_allowed
                and bool(primitive_active_run_root)
                and primitive_injectable
            )
            self.visible_primitive_submit_button.configure(state="normal" if submit_enabled else "disabled")
        if self._has_ui_attr("visible_primitive_publish_button"):
            publish_enabled = config_present and primitive_context_ready and bool(primitive_confirm_run_root)
            self.visible_primitive_publish_button.configure(state="normal" if publish_enabled else "disabled")
        if self._has_ui_attr("visible_primitive_partner_button"):
            self.visible_primitive_partner_button.configure(state="normal" if bool(primitive_partner_target_id) else "disabled")
        if self._has_ui_attr("visible_primitive_handoff_button"):
            handoff_enabled = config_present and bool(primitive_pair_id) and bool(primitive_confirm_run_root)
            self.visible_primitive_handoff_button.configure(state="normal" if handoff_enabled else "disabled")
        primitive_submit_state = str((primitive_target_status or {}).get("SubmitState", "") or "").strip().lower()
        primitive_latest_state = str((primitive_target_status or {}).get("LatestState", "") or "").strip().lower()
        primitive_outbox_action = str((primitive_target_status or {}).get("SourceOutboxNextAction", "") or "").strip().lower()
        primitive_pair_next_action = str((primitive_pair_status or {}).get("NextAction", "") or "").strip().lower()
        primitive_handoff_ready_count = int((primitive_pair_status or {}).get("HandoffReadyCount", 0) or 0)
        handoff_transition_states = {"ready-to-forward", "forwarded", "duplicate-skipped"}
        handoff_transition_actions = {"handoff-ready", "already-forwarded", "duplicate-skipped"}
        publish_progress_markers = {
            "submitted",
            "unconfirmed",
            "confirmed",
            "typed-window-submit-unconfirmed",
            "typed-window-stalled-after-submit",
        }
        primitive_next_action_key = ""
        primitive_stage_key = "default"
        primitive_stage_badge = "문맥 준비"
        primitive_stage_detail = "현재 preview row, pair/target, RunRoot 기준을 먼저 맞춥니다."
        primitive_stage_background = "#6B7280"
        primitive_partner_transition_needed = bool(
            primitive_partner_target_id
            and primitive_pair_next_action == "await-partner-output"
            and primitive_target_id != primitive_partner_target_id
            and (
                primitive_latest_state in handoff_transition_states
                or primitive_outbox_action in handoff_transition_actions
                or primitive_submit_state in publish_progress_markers
            )
        )
        primitive_handoff_ready_now = bool(
            handoff_enabled
            and (
                primitive_latest_state in handoff_transition_states
                or primitive_outbox_action in handoff_transition_actions
                or primitive_pair_next_action == "handoff-ready"
                or primitive_handoff_ready_count > 0
            )
        )
        primitive_publish_check_needed = bool(
            publish_enabled
            and (
                primitive_submit_state in publish_progress_markers
                or (
                    primitive_latest_state
                    and primitive_latest_state not in {"no-zip", "missing", "none", "(없음)"}
                )
                or (
                    primitive_outbox_action
                    and primitive_outbox_action not in {"no-zip", "missing", "none", "(없음)"}
                )
            )
        )
        if not config_present:
            primitive_stage_key = "config_required"
            primitive_stage_badge = "Config 필요"
            primitive_stage_detail = "Visible primitive는 ConfigPath가 있어야 현재 pair/target 메시지와 contract 경로를 계산할 수 있습니다."
            primitive_stage_background = "#B45309"
        elif not primitive_context_ready:
            primitive_stage_key = "target_required"
            primitive_stage_badge = "대상 선택"
            primitive_stage_detail = "preview row 또는 pair/target 문맥이 비어 있습니다. 현재 점검할 target을 먼저 고르세요."
            primitive_stage_background = "#B45309"
        if config_present and primitive_context_ready:
            if primitive_visibility_row is None or not primitive_injectable:
                primitive_next_action_key = "visible_primitive_visibility"
                primitive_stage_key = "visibility_check"
                primitive_stage_badge = "입력 점검"
                primitive_stage_detail = self._normalize_visible_primitive_stage_detail(
                    str(primitive_visibility_row.get("InjectionReason", "") or "").strip()
                    if primitive_visibility_row is not None and not primitive_injectable
                    else "typed-window 입력 가능 여부와 submit guard를 먼저 확인해야 합니다."
                ,
                    category="visibility",
                ) or "typed-window 입력 가능 여부와 submit guard를 먼저 확인해야 합니다."
                primitive_stage_background = "#B45309" if primitive_injectable else "#B91C1C"
            elif not primitive_message_ready:
                primitive_next_action_key = "visible_primitive_preview_refresh"
                primitive_stage_key = "preview_prepare"
                primitive_stage_badge = "preview 준비"
                primitive_stage_detail = "현재 target 편집본을 다시 계산하거나 저장해서 submit 전에 실제 payload를 먼저 확인하세요."
                primitive_stage_background = "#0F766E"
            elif primitive_partner_transition_needed:
                primitive_next_action_key = "visible_primitive_partner"
                primitive_stage_key = "partner_switch"
                primitive_stage_badge = "partner 전환"
                primitive_stage_detail = (
                    f"{primitive_partner_target_id} 쪽으로 시점을 옮겨 다음 응답 대상을 확인합니다."
                )
                primitive_stage_background = "#7C3AED"
            elif primitive_handoff_ready_now:
                primitive_next_action_key = "visible_primitive_handoff"
                primitive_stage_key = "handoff_check"
                primitive_stage_badge = "handoff 확인"
                primitive_stage_detail = "source-outbox와 pair 상태가 다음 전달 준비로 넘어갔는지 확인합니다."
                primitive_stage_background = "#15803D"
            elif primitive_publish_check_needed:
                primitive_next_action_key = "visible_primitive_publish"
                primitive_stage_key = "publish_check"
                primitive_stage_badge = "publish 확인"
                primitive_stage_detail = "submit 뒤 publish.ready / source-outbox 상태를 먼저 확인합니다."
                primitive_stage_background = "#2563EB"
            elif submit_enabled:
                primitive_next_action_key = "visible_primitive_submit"
                primitive_stage_key = "submit_once"
                primitive_stage_badge = "1회 submit"
                primitive_stage_detail = "현재 공식 창에 payload를 1회 전송하고 진행 신호가 생기는지 확인합니다."
                primitive_stage_background = "#1D4ED8"
            elif bool(primitive_partner_target_id):
                primitive_next_action_key = "visible_primitive_partner"
                primitive_stage_key = "partner_review"
                primitive_stage_badge = "partner 확인"
                primitive_stage_detail = f"필요하면 {primitive_partner_target_id} 쪽 문맥으로 전환해 상대 target 상태를 확인합니다."
                primitive_stage_background = "#92400E"
            elif not primitive_scope_allowed and primitive_scope_detail:
                primitive_stage_key = "scope_blocked"
                primitive_stage_badge = "실행 대기"
                primitive_stage_detail = self._normalize_visible_primitive_stage_detail(
                    primitive_scope_detail,
                    category="scope",
                )
                primitive_stage_background = "#B45309"
            elif not primitive_active_run_root and primitive_active_run_root_detail:
                primitive_stage_key = "run_root_prepare"
                primitive_stage_badge = "RunRoot 준비"
                primitive_stage_detail = self._normalize_visible_primitive_stage_detail(
                    primitive_active_run_root_detail,
                    category="run_root",
                )
                primitive_stage_background = "#B45309"
            elif not primitive_confirm_run_root and primitive_confirm_run_root_detail:
                primitive_stage_key = "confirm_root_prepare"
                primitive_stage_badge = "확인 경로 준비"
                primitive_stage_detail = self._normalize_visible_primitive_stage_detail(
                    primitive_confirm_run_root_detail,
                    category="run_root",
                )
                primitive_stage_background = "#B45309"
            else:
                primitive_stage_key = "submit_ready"
                primitive_stage_badge = "submit 준비"
                primitive_stage_detail = "문맥과 편집본은 준비됐습니다. RunRoot와 pair scope를 확인한 뒤 실제 submit으로 넘어갑니다."
                primitive_stage_background = "#1D4ED8"
        self._set_visible_primitive_stage(
            badge_text=primitive_stage_badge,
            detail_text=primitive_stage_detail,
            action_key=primitive_next_action_key,
            stage_key=primitive_stage_key,
            background=primitive_stage_background,
        )
        self._refresh_visible_primitive_next_action_highlights(next_action_key=primitive_next_action_key)
        self._refresh_visible_primitive_summary()
        self._refresh_sticky_context_bar()

    def on_pair_or_target_changed(self, _event: object | None = None) -> None:
        self.action_context_source = "controls"
        selected_pair = self._selected_pair_id()
        selected_target = self.target_id_var.get().strip()
        preview_synced = False
        if self.preview_rows and self._selected_preview_row() is None:
            preview_synced = self._sync_preview_selection_with_pair(selected_pair, target_id=selected_target)
        if preview_synced:
            self._sync_message_scope_id_from_context()
            self._sync_home_pair_selection(selected_pair)
            self._sync_pair_scoped_views_with_action_context(refresh_artifacts=True)
            self.update_pair_button_states()
            self.rebuild_panel_state()
            return
        self._sync_message_scope_id_from_context()
        self._sync_home_pair_selection(self._selected_pair_id())
        self._sync_pair_scoped_views_with_action_context(refresh_artifacts=True)
        self.render_target_board()
        self.render_message_editor()
        self.update_pair_button_states()
        self.rebuild_panel_state()

    def save_effective_json(self) -> None:
        if not self.effective_data:
            messagebox.showwarning("데이터 없음", "먼저 적용 설정 미리보기를 불러오세요.")
            return

        pair_token = self.pair_id_var.get().strip() or "all"
        generated_at = self.effective_data.get("GeneratedAt", "")
        if generated_at:
            try:
                timestamp = datetime.fromisoformat(generated_at.replace("Z", "+00:00")).strftime("%Y%m%d_%H%M%S")
            except ValueError:
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        else:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

        initialdir = ROOT / "_tmp"
        initialdir.mkdir(exist_ok=True)
        default_name = f"effective-config.preview.{pair_token}.{timestamp}.json"
        selected = filedialog.asksaveasfilename(
            title="적용 설정 미리보기 JSON 저장",
            initialdir=str(initialdir),
            initialfile=default_name,
            defaultextension=".json",
            filetypes=[("JSON", "*.json"), ("All files", "*.*")],
        )
        if not selected:
            return

        Path(selected).write_text(json.dumps(self.effective_data, ensure_ascii=False, indent=2), encoding="utf-8")
        self.set_text(self.output_text, f"미리보기 스냅샷 JSON 저장 완료:\n{selected}")
        self.refresh_snapshot_list()
        messagebox.showinfo("저장 완료", selected)

    def _open_path(self, path_value: str, *, kind: str) -> None:
        if not path_value:
            messagebox.showwarning("선택 필요", f"{kind} 경로를 먼저 선택하세요.")
            return
        if not Path(path_value).exists():
            messagebox.showwarning("경로 없음", f"{kind} 경로가 존재하지 않습니다.\n{path_value}")
            return
        os.startfile(path_value)

    def open_selected_target_folder(self) -> None:
        row = self._selected_preview_row()
        if not row:
            messagebox.showwarning("선택 필요", "row를 먼저 선택하세요.")
            return
        self._open_path(row.get("PairTargetFolder", ""), kind="대상 폴더")

    def open_selected_review_folder(self) -> None:
        row = self._selected_preview_row()
        if not row:
            messagebox.showwarning("선택 필요", "row를 먼저 선택하세요.")
            return
        self._open_path(row.get("ReviewFolderPath", ""), kind="검토 폴더")

    def copy_selected_summary_path(self) -> None:
        row = self._selected_preview_row()
        if not row:
            messagebox.showwarning("선택 필요", "row를 먼저 선택하세요.")
            return
        summary_path = row.get("SummaryPath", "")
        if not summary_path:
            messagebox.showwarning("summary 경로 없음", "선택된 row에 summary path가 없습니다.")
            return
        self._copy_to_clipboard(summary_path)
        self.set_text(self.output_text, f"summary 경로 복사 완료:\n{summary_path}")

    def _current_run_root_for_actions(self) -> str:
        explicit = self.run_root_var.get().strip()
        if explicit:
            return explicit
        if self.effective_data:
            return self.effective_data.get("RunContext", {}).get("SelectedRunRoot", "") or ""
        return ""

    def _current_run_root_for_artifacts(self) -> str:
        explicit = self.artifact_run_root_filter_var.get().strip()
        if explicit:
            return explicit
        return self._current_run_root_for_actions()

    def _artifact_run_root_uses_override(self) -> bool:
        explicit = self.artifact_run_root_filter_var.get().strip()
        action_run_root = self._current_run_root_for_actions().strip()
        return bool(explicit and os.path.normcase(os.path.normpath(explicit)) != os.path.normcase(os.path.normpath(action_run_root or explicit)))

    def _current_artifact_run_root_is_stale(self) -> bool:
        return self._run_root_is_stale(self._current_run_root_for_artifacts())

    def export_selected_row_messages(self) -> None:
        row = self._selected_preview_row() or self._resolve_visible_primitive_row()
        if not row:
            messagebox.showwarning("선택 필요", "row를 먼저 선택하세요.")
            return

        config_path = self.config_path_var.get().strip()
        pair_id = row.get("PairId", "")
        target_id = row.get("TargetId", "")
        run_root = self._current_run_root_for_actions()
        if not config_path:
            messagebox.showwarning("설정 필요", "Config를 먼저 선택하세요.")
            return
        if not pair_id or not target_id:
            messagebox.showwarning("선택 정보 부족", "선택된 row의 pair/target 정보를 읽지 못했습니다.")
            return

        command = self.command_service.build_powershell_file_command(
            str(ROOT / "render-pair-message.ps1"),
            extra=[
                "-ConfigPath",
                config_path,
                "-PairId",
                pair_id,
                "-TargetId",
                target_id,
                "-Mode",
                "both",
                "-WriteOutputs",
                "-AsJson",
            ],
        )
        if run_root:
            command += ["-RunRoot", run_root]

        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return run_command(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            output_root = payload.get("OutputRoot", "")
            lines = [
                "선택 행 문구 JSON/TXT 저장 완료",
                f"Pair: {payload.get('PairId', '')}",
                f"대상: {payload.get('TargetId', '')}",
                f"RunRoot: {payload.get('RunRoot', '')}",
                f"출력 폴더: {output_root}",
                "",
            ]
            for item in payload.get("Messages", []):
                paths = item.get("OutputPaths", {})
                lines += [
                    f"[{item.get('MessageType', '')}]",
                    f"- envelope.json: {paths.get('EnvelopeJson', '')}",
                    f"- rendered.txt: {paths.get('RenderedText', '')}",
                    "",
                ]
            self.set_text(self.output_text, "\n".join(lines).rstrip())
            self.last_result_var.set(
                "마지막 결과: pair={0} target={1} 문구 JSON/TXT 저장".format(
                    payload.get("PairId", ""),
                    payload.get("TargetId", ""),
                )
            )
            if output_root and Path(output_root).exists():
                os.startfile(output_root)

        self.run_background_task(
            state="문구 JSON/TXT 저장 중",
            hint=f"{pair_id}/{target_id} 기준 문구 JSON/TXT preview를 저장 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="문구 JSON/TXT 저장 완료",
            success_hint="출력 폴더가 열렸습니다. preview 산출물을 바로 확인할 수 있습니다.",
            failure_state="문구 JSON/TXT 저장 실패",
            failure_hint="출력 영역의 오류와 마지막 명령을 확인하세요.",
        )

    def _resolve_visible_primitive_row(self) -> dict | None:
        row = self._editor_context_row()
        if row:
            return row
        row = self._selected_preview_row()
        if row:
            return row
        target_id = self._selected_inspection_target_id() or self.target_id_var.get().strip()
        if target_id:
            row = self._preview_row_for_target(target_id)
            if row:
                return row
        pair_id = self._selected_pair_id()
        if pair_id:
            for candidate in self.preview_rows:
                if str(candidate.get("PairId", "") or "").strip() == pair_id and str(candidate.get("RoleName", "") or "").strip() == "top":
                    return candidate
            for candidate in self.preview_rows:
                if str(candidate.get("PairId", "") or "").strip() == pair_id:
                    return candidate
        return None

    def _require_visible_primitive_row(self, *, action_label: str) -> dict | None:
        row = self._resolve_visible_primitive_row()
        if row is not None:
            return row
        messagebox.showwarning("대상 선택 필요", f"{action_label} 전에 preview row나 target을 먼저 선택하세요.")
        return None

    def _paired_target_status_row(self, target_id: str) -> dict | None:
        normalized_target = str(target_id or "").strip()
        if not normalized_target:
            return None
        rows = (self.paired_status_data or {}).get("Targets", []) or []
        for row in rows:
            if str(row.get("TargetId", "") or "").strip() == normalized_target:
                return row
        return None

    @staticmethod
    def _row_or_target_status_value(row: dict, target_status: dict | None, key: str, default: object = "") -> object:
        if target_status is not None and key in target_status:
            return target_status.get(key, default)
        return row.get(key, default)

    def _source_outbox_preview_summary(self, row: dict, *, target_status: dict | None = None) -> str:
        state = str(self._row_or_target_status_value(row, target_status, "SourceOutboxState", "") or "").strip()
        action = str(self._row_or_target_status_value(row, target_status, "SourceOutboxNextAction", "") or "").strip()
        original_reason = str(self._row_or_target_status_value(row, target_status, "SourceOutboxOriginalReadyReason", "") or "").strip()
        final_reason = str(self._row_or_target_status_value(row, target_status, "SourceOutboxFinalReadyReason", "") or "").strip()
        repair_attempted = bool(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairAttempted", False))
        repair_succeeded = bool(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairSucceeded", False))
        repair_source_context = str(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairSourceContext", "") or "").strip()
        repair_message = str(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairMessage", "") or "").strip()

        parts: list[str] = []
        if state:
            parts.append(state)
        if action and action != state:
            parts.append(f"next={action}")
        if repair_attempted:
            repair_text = "repair=ok" if repair_succeeded else "repair=fail"
            if original_reason:
                repair_text += f"({original_reason})"
            parts.append(repair_text)
        elif original_reason:
            if final_reason and final_reason != original_reason:
                parts.append(f"reason={original_reason}->{final_reason}")
            else:
                parts.append(f"reason={original_reason}")
        elif repair_message:
            parts.append("repair=check")
        elif repair_source_context:
            parts.append(f"repair={repair_source_context}")
        return " / ".join(parts) if parts else "-"

    def _source_outbox_detail_lines(self, row: dict, *, target_status: dict | None = None) -> list[str]:
        state = str(self._row_or_target_status_value(row, target_status, "SourceOutboxState", "") or "").strip()
        action = str(self._row_or_target_status_value(row, target_status, "SourceOutboxNextAction", "") or "").strip()
        original_reason = str(self._row_or_target_status_value(row, target_status, "SourceOutboxOriginalReadyReason", "") or "").strip()
        final_reason = str(self._row_or_target_status_value(row, target_status, "SourceOutboxFinalReadyReason", "") or "").strip()
        repair_attempted = bool(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairAttempted", False))
        repair_succeeded = bool(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairSucceeded", False))
        repair_completed_at = str(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairCompletedAt", "") or "").strip()
        repair_source_context = str(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairSourceContext", "") or "").strip()
        repair_message = str(self._row_or_target_status_value(row, target_status, "SourceOutboxRepairMessage", "") or "").strip()
        if not any(
            [
                state,
                action,
                original_reason,
                final_reason,
                repair_attempted,
                repair_succeeded,
                repair_completed_at,
                repair_source_context,
                repair_message,
            ]
        ):
            return []

        return [
            "[paired source outbox status]",
            f"state: {state or '(없음)'}",
            f"next action: {action or '(없음)'}",
            f"original ready reason: {original_reason or '(없음)'}",
            f"final ready reason: {final_reason or '(없음)'}",
            f"repair attempted/succeeded: {repair_attempted} / {repair_succeeded}",
            f"repair source context: {repair_source_context or '(없음)'}",
            f"repair completed at: {repair_completed_at or '(없음)'}",
            f"repair message: {repair_message or '(없음)'}",
        ]

    def _paired_pair_status_row(self, pair_id: str) -> dict | None:
        normalized_pair = str(pair_id or "").strip()
        if not normalized_pair:
            return None
        rows = (self.paired_status_data or {}).get("Pairs", []) or []
        for row in rows:
            if str(row.get("PairId", "") or "").strip() == normalized_pair:
                return row
        return None

    def _visibility_target_status_row(self, target_id: str) -> dict | None:
        normalized_target = str(target_id or "").strip()
        if not normalized_target:
            return None
        rows = (self.visibility_status_data or {}).get("Targets", []) or []
        for row in rows:
            if str(row.get("TargetId", "") or "").strip() == normalized_target:
                return row
        return None

    def _paired_acceptance_receipt(self) -> dict:
        return dict(((self.paired_status_data or {}).get("AcceptanceReceipt", {}) or {}))

    def _refresh_visible_primitive_summary(self) -> None:
        if not self._has_ui_attr("visible_primitive_status_var"):
            return

        config_present = bool(self.config_path_var.get().strip())
        row = self._resolve_visible_primitive_row()
        pair_id = str((row or {}).get("PairId", "") or self._selected_pair_id() or "").strip()
        target_id = str((row or {}).get("TargetId", "") or self.target_id_var.get().strip() or "").strip()
        partner_target_id = str((row or {}).get("PartnerTargetId", "") or "").strip()
        run_root = self._current_run_root_for_actions().strip()
        scope_allowed, scope_detail = self._pair_scope_allowed(pair_id, action_label="pair primitive")
        visibility_row = self._visibility_target_status_row(target_id)
        target_status = self._paired_target_status_row(target_id)
        pair_status = self._paired_pair_status_row(pair_id)

        if pair_id and target_id:
            status_text = f"Primitive: {pair_id}/{target_id}"
            if partner_target_id:
                status_text += f" -> {partner_target_id}"
        elif pair_id:
            status_text = f"Primitive: {pair_id} / target 선택 필요"
        else:
            status_text = "Primitive: pair / target 선택 필요"

        detail_parts: list[str] = []
        if not config_present:
            detail_parts.append("ConfigPath 필요")
        if row is None:
            detail_parts.append("preview row 미선택")
        if not scope_allowed and scope_detail:
            detail_parts.append(scope_detail)
        if run_root:
            run_root_name = os.path.basename(os.path.normpath(run_root)) or run_root
            stale_text = " (stale)" if self._run_root_is_stale(run_root) else ""
            detail_parts.append(f"runRoot={run_root_name}{stale_text}")
        else:
            detail_parts.append("runRoot 미선택")
        if visibility_row:
            injectable = bool(visibility_row.get("Injectable", False))
            method = str(visibility_row.get("InjectionMethod", "") or "").strip()
            reason = str(visibility_row.get("InjectionReason", "") or "").strip()
            visibility_text = "visible=ok" if injectable else "visible=blocked"
            if method:
                visibility_text += f"({method})"
            if reason and not injectable:
                visibility_text += f" {reason}"
            detail_parts.append(visibility_text)
        else:
            detail_parts.append("입력 점검 미반영")
        if target_status:
            submit_state = str(target_status.get("SubmitState", "") or "").strip() or "(없음)"
            outbox_state = str(target_status.get("SourceOutboxState", "") or "").strip()
            outbox_action = str(target_status.get("SourceOutboxNextAction", "") or "").strip()
            latest_state = str(target_status.get("LatestState", "") or "").strip()
            detail_parts.append(f"submit={submit_state}")
            if outbox_state or outbox_action:
                outbox_text = outbox_state or "(없음)"
                if outbox_action:
                    outbox_text += f"/{outbox_action}"
                detail_parts.append(f"outbox={outbox_text}")
            if latest_state:
                detail_parts.append(f"latest={latest_state}")
        else:
            detail_parts.append("paired status 미로딩")
        if pair_status:
            phase = str(pair_status.get("CurrentPhase", "") or "").strip() or "(phase 없음)"
            next_action = str(pair_status.get("NextAction", "") or "").strip()
            handoff_ready = int(pair_status.get("HandoffReadyCount", 0) or 0)
            forwarded = int(pair_status.get("ForwardedStateCount", 0) or 0)
            pair_text = f"pair={phase}"
            if next_action:
                pair_text += f" / next={next_action}"
            if handoff_ready or forwarded:
                pair_text += f" / handoff={handoff_ready} forwarded={forwarded}"
            detail_parts.append(pair_text)

        self.visible_primitive_status_var.set(status_text)
        self.visible_primitive_detail_var.set(" / ".join(part for part in detail_parts if part))

    def _format_visible_primitive_target_report(
        self,
        *,
        title: str,
        row: dict,
        target_status: dict | None = None,
        pair_status: dict | None = None,
        visibility_row: dict | None = None,
        payload: dict | None = None,
    ) -> str:
        lines = [
            title,
            f"Pair: {row.get('PairId', '')}",
            f"Target: {row.get('TargetId', '')}",
            f"Partner: {row.get('PartnerTargetId', '') or '(없음)'}",
            f"RunRoot: {self._current_run_root_for_actions() or '(없음)'}",
        ]
        if payload:
            lines.extend(
                [
                    f"Primitive: {payload.get('PrimitiveName', '') or '(없음)'}",
                    f"PrimitiveState: {payload.get('PrimitiveState', '') or '(없음)'}",
                    f"PrimitiveReason: {payload.get('PrimitiveReason', '') or '(없음)'}",
                    f"NextPrimitiveAction: {payload.get('NextPrimitiveAction', '') or '(없음)'}",
                    f"PrimitiveSummary: {payload.get('SummaryLine', '') or '(없음)'}",
                ]
            )
        if visibility_row:
            lines.extend(
                [
                    f"TypedWindowInjectable: {bool(visibility_row.get('Injectable', False))}",
                    f"TypedWindowMethod: {visibility_row.get('InjectionMethod', '') or '(없음)'}",
                    f"TypedWindowReason: {visibility_row.get('InjectionReason', '') or '(없음)'}",
                ]
            )
        if payload:
            lines.extend(
                [
                    f"FinalState: {payload.get('FinalState', '') or '(없음)'}",
                    f"SubmitState: {payload.get('SubmitState', '') or '(없음)'}",
                    f"ExecutionPathMode: {payload.get('ExecutionPathMode', '') or '(없음)'}",
                    f"SubmitRetrySequence: {payload.get('SubmitRetrySequenceSummary', '') or '(없음)'}",
                    f"PrimarySubmitMode: {payload.get('PrimarySubmitMode', '') or '(없음)'}",
                    f"FinalSubmitMode: {payload.get('FinalSubmitMode', '') or '(없음)'}",
                    f"SubmitRetryIntervalMs: {payload.get('SubmitRetryIntervalMs', '') or '(없음)'}",
                    f"OutboxPublished: {bool(payload.get('OutboxPublished', False))}",
                ]
            )
        if target_status:
            lines.extend(
                [
                    f"Paired SubmitState: {target_status.get('SubmitState', '') or '(없음)'}",
                    f"Paired SubmitReason: {target_status.get('SubmitReason', '') or '(없음)'}",
                    f"Paired TypedWindowState: {target_status.get('TypedWindowExecutionState', '') or '(없음)'}",
                    f"Paired SourceOutboxState: {target_status.get('SourceOutboxState', '') or '(없음)'}",
                    f"Paired SourceOutboxNextAction: {target_status.get('SourceOutboxNextAction', '') or '(없음)'}",
                    f"Paired LatestState: {target_status.get('LatestState', '') or '(없음)'}",
                    f"Paired SubmitModes: {target_status.get('SeedSubmitRetrySequenceSummary', '') or '(없음)'}",
                ]
            )
        if pair_status:
            lines.extend(
                [
                    f"Pair CurrentPhase: {pair_status.get('CurrentPhase', '') or '(없음)'}",
                    f"Pair NextExpectedHandoff: {pair_status.get('NextExpectedHandoff', '') or '(없음)'}",
                    f"Pair NextAction: {pair_status.get('NextAction', '') or '(없음)'}",
                    f"Pair HandoffReadyCount: {pair_status.get('HandoffReadyCount', 0) or 0}",
                    f"Pair ForwardedStateCount: {pair_status.get('ForwardedStateCount', 0) or 0}",
                ]
            )
        watcher = ((self.paired_status_data or {}).get("Watcher", {}) or {})
        if watcher:
            lines.append(f"WatcherStatus: {watcher.get('Status', '') or '(없음)'}")
        receipt = self._paired_acceptance_receipt()
        if receipt:
            lines.append(f"AcceptanceReceiptState: {receipt.get('AcceptanceState', '') or '(없음)'}")
            if receipt.get("BlockedBy", ""):
                lines.extend(
                    [
                        f"BlockedBy: {receipt.get('BlockedBy', '')}",
                        f"BlockedTargetId: {receipt.get('BlockedTargetId', '') or '(없음)'}",
                        f"BlockedDetail: {receipt.get('BlockedDetail', '') or '(없음)'}",
                    ]
                )
        if self.paired_status_error:
            lines.append(f"PairedStatusError: {self.paired_status_error}")
        if payload:
            lines.extend(["", "JSON", json.dumps(payload, ensure_ascii=False, indent=2)])
        return "\n".join(lines)

    def _format_visible_primitive_handoff_report(
        self,
        *,
        title: str,
        row: dict,
        current_target_status: dict | None,
        partner_target_status: dict | None,
        pair_status: dict | None,
        payload: dict | None = None,
    ) -> str:
        lines = [
            title,
            f"Pair: {row.get('PairId', '')}",
            f"CurrentTarget: {row.get('TargetId', '')}",
            f"PartnerTarget: {row.get('PartnerTargetId', '') or '(없음)'}",
            f"RunRoot: {self._current_run_root_for_actions() or '(없음)'}",
        ]
        if payload:
            lines.extend(
                [
                    f"Primitive: {payload.get('PrimitiveName', '') or '(없음)'}",
                    f"PrimitiveState: {payload.get('PrimitiveState', '') or '(없음)'}",
                    f"PrimitiveReason: {payload.get('PrimitiveReason', '') or '(없음)'}",
                    f"NextPrimitiveAction: {payload.get('NextPrimitiveAction', '') or '(없음)'}",
                    f"PrimitiveSummary: {payload.get('SummaryLine', '') or '(없음)'}",
                ]
            )
        if pair_status:
            lines.extend(
                [
                    f"Pair CurrentPhase: {pair_status.get('CurrentPhase', '') or '(없음)'}",
                    f"Pair NextExpectedHandoff: {pair_status.get('NextExpectedHandoff', '') or '(없음)'}",
                    f"Pair NextAction: {pair_status.get('NextAction', '') or '(없음)'}",
                    f"Pair LatestStateSummary: {pair_status.get('LatestStateSummary', '') or '(없음)'}",
                    f"Pair HandoffReadyCount: {pair_status.get('HandoffReadyCount', 0) or 0}",
                    f"Pair ForwardedStateCount: {pair_status.get('ForwardedStateCount', 0) or 0}",
                ]
            )
        for label, status in [("Current", current_target_status), ("Partner", partner_target_status)]:
            if not status:
                lines.append(f"{label} TargetState: (없음)")
                continue
            lines.extend(
                [
                    f"{label} SubmitState: {status.get('SubmitState', '') or '(없음)'}",
                    f"{label} SourceOutboxState: {status.get('SourceOutboxState', '') or '(없음)'}",
                    f"{label} SourceOutboxNextAction: {status.get('SourceOutboxNextAction', '') or '(없음)'}",
                    f"{label} LatestState: {status.get('LatestState', '') or '(없음)'}",
                    f"{label} TypedWindowState: {status.get('TypedWindowExecutionState', '') or '(없음)'}",
                ]
            )
        watcher = ((self.paired_status_data or {}).get("Watcher", {}) or {})
        if watcher:
            lines.extend(
                [
                    f"WatcherStatus: {watcher.get('Status', '') or '(없음)'}",
                    f"WatcherForwardedCount: {watcher.get('ForwardedCount', '') or '(없음)'}",
                ]
            )
        receipt = self._paired_acceptance_receipt()
        if receipt:
            lines.append(f"AcceptanceReceiptState: {receipt.get('AcceptanceState', '') or '(없음)'}")
            if receipt.get("BlockedBy", ""):
                lines.extend(
                    [
                        f"BlockedBy: {receipt.get('BlockedBy', '')}",
                        f"BlockedTargetId: {receipt.get('BlockedTargetId', '') or '(없음)'}",
                        f"BlockedDetail: {receipt.get('BlockedDetail', '') or '(없음)'}",
                    ]
                )
        if self.paired_status_error:
            lines.append(f"PairedStatusError: {self.paired_status_error}")
        if payload:
            lines.extend(["", "JSON", json.dumps(payload, ensure_ascii=False, indent=2)])
        return "\n".join(lines)

    def select_partner_target_from_context(self) -> None:
        row = self._require_visible_primitive_row(action_label="상대 target 선택")
        if row is None:
            return
        partner_target_id = str(row.get("PartnerTargetId", "") or "").strip()
        if not partner_target_id:
            messagebox.showwarning("상대 target 없음", "선택된 row에 PartnerTargetId가 없습니다.")
            return
        pair_id = str(row.get("PairId", "") or self._selected_pair_id() or "").strip()
        current_target_id = str(row.get("TargetId", "") or "").strip()
        self.select_target_from_board(partner_target_id, pair_id)
        lines = [
            "상대 target 선택 완료",
            f"Pair: {pair_id}",
            f"CurrentTarget: {current_target_id or '(없음)'}",
            f"PartnerTarget: {partner_target_id}",
        ]
        self._set_visible_acceptance_output("\n".join(lines))
        self.last_result_var.set(f"마지막 결과: pair={pair_id} partner={partner_target_id} 선택")

    def run_selected_target_seed_submit(self) -> None:
        row = self._require_visible_primitive_row(action_label="선택 target 1회 submit")
        if row is None:
            return

        pair_id = str(row.get("PairId", "") or self._selected_pair_id() or "").strip()
        target_id = str(row.get("TargetId", "") or self.target_id_var.get().strip() or "").strip()
        if not target_id:
            messagebox.showwarning("Target 필요", "선택된 row의 target을 해석하지 못했습니다.")
            return

        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "선택 target 1회 submit에는 ConfigPath가 필요합니다.")
            return

        pair_scope_allowed, pair_scope_detail = self._pair_scope_allowed(pair_id, action_label="선택 target 1회 submit")
        if not pair_scope_allowed:
            messagebox.showwarning("선택 target 1회 submit 대기", pair_scope_detail)
            return

        run_root, run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label="선택 target 1회 submit",
            allow_stale=False,
        )
        if not run_root:
            messagebox.showwarning("RunRoot 필요", run_root_detail)
            return

        visibility_row = self._visibility_target_status_row(target_id)
        if visibility_row and not bool(visibility_row.get("Injectable", False)):
            reason = str(visibility_row.get("InjectionReason", "") or "").strip()
            detail = reason or "typed-window 입력 점검이 아직 통과하지 않았습니다."
            messagebox.showwarning("typed-window 점검 필요", detail)
            return

        self._set_action_context(pair_id=pair_id, target_id=target_id, run_root=run_root, source="visible-primitive-submit")
        command = self.command_service.build_script_command(
            "tests/Invoke-PairedExchangeOneShotSubmit.ps1",
            config_path=config_path,
            run_root=run_root,
            pair_id=pair_id,
            target_id=target_id,
            extra=["-AsJson"],
        )
        self.last_command_var.set(subprocess.list2cmdline(command))
        context = self._snapshot_context(run_root=run_root, pair_id=pair_id, target_id=target_id)

        def worker() -> dict:
            return self.status_service.run_json_script(
                "tests/Invoke-PairedExchangeOneShotSubmit.ps1",
                context,
                extra=["-AsJson"],
                run_root_override=run_root,
                pair_id_override=pair_id,
                target_id_override=target_id,
            )

        def on_success(payload: dict) -> None:
            resolved_run_root = str(payload.get("RunRoot", "") or run_root).strip()
            if resolved_run_root:
                self.run_root_var.set(resolved_run_root)
            if not self._apply_paired_status_snapshot_from_payload(payload, refresh_artifacts=True):
                self.refresh_paired_status_only(refresh_artifacts=True)
            target_status = payload.get("PairedTargetStatus", None) if isinstance(payload.get("PairedTargetStatus", None), dict) else self._paired_target_status_row(target_id)
            pair_status = payload.get("PairStatus", None) if isinstance(payload.get("PairStatus", None), dict) else self._paired_pair_status_row(pair_id)
            self._set_visible_acceptance_output(
                self._format_visible_primitive_target_report(
                    title="선택 target 1회 submit 완료",
                    row=row,
                    target_status=target_status,
                    pair_status=pair_status,
                    visibility_row=visibility_row,
                    payload=payload,
                )
            )
            self.last_result_var.set(
                "마지막 결과: pair={0} target={1} submit={2}".format(
                    pair_id,
                    target_id,
                    payload.get("SubmitState", "") or payload.get("FinalState", "") or "(없음)",
                )
            )

        def on_failure(exc: Exception) -> str:
            self.refresh_paired_status_only(refresh_artifacts=False)
            lines = [
                self._format_background_exception(exc),
                "",
                f"Pair: {pair_id}",
                f"Target: {target_id}",
                f"RunRoot: {run_root}",
            ]
            if visibility_row:
                lines.append(f"TypedWindowReason: {visibility_row.get('InjectionReason', '') or '(없음)'}")
            return "\n".join(lines)

        self.run_background_task(
            state="선택 target 1회 submit 실행 중",
            hint=f"{pair_id}/{target_id} 기준으로 typed-window submit을 한 번 실행합니다.",
            worker=worker,
            on_success=on_success,
            success_state="선택 target 1회 submit 완료",
            success_hint="paired status와 visible primitive 요약을 갱신했습니다.",
            failure_state="선택 target 1회 submit 실패",
            failure_hint="typed-window 점검 상태와 마지막 명령, paired status를 확인하세요.",
            on_failure=on_failure,
        )

    def inspect_selected_target_publish_status(self) -> None:
        row = self._require_visible_primitive_row(action_label="publish 확인")
        if row is None:
            return

        pair_id = str(row.get("PairId", "") or self._selected_pair_id() or "").strip()
        target_id = str(row.get("TargetId", "") or self.target_id_var.get().strip() or "").strip()
        if not target_id:
            messagebox.showwarning("Target 필요", "publish 확인 대상 target을 해석하지 못했습니다.")
            return

        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "publish 확인에는 ConfigPath가 필요합니다.")
            return

        run_root, run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label="publish 확인",
            allow_stale=True,
        )
        if not run_root:
            messagebox.showwarning("RunRoot 필요", run_root_detail)
            return

        self._set_action_context(pair_id=pair_id, target_id=target_id, run_root=run_root, source="visible-primitive-publish")
        context = self._snapshot_context(run_root=run_root, pair_id=pair_id, target_id=target_id)
        command = self.command_service.build_script_command(
            "tests/Confirm-PairedExchangePublishPrimitive.ps1",
            config_path=config_path,
            run_root=run_root,
            pair_id=pair_id,
            target_id=target_id,
            extra=["-AsJson"],
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> dict:
            return self.status_service.run_json_script(
                "tests/Confirm-PairedExchangePublishPrimitive.ps1",
                context,
                extra=["-AsJson"],
                run_root_override=run_root,
                pair_id_override=pair_id,
                target_id_override=target_id,
            )

        def on_success(payload: dict) -> None:
            if not self._apply_paired_status_snapshot_from_payload(payload, refresh_artifacts=True):
                self.refresh_paired_status_only(refresh_artifacts=True)
            visibility_row = self._visibility_target_status_row(target_id)
            target_status = payload.get("PairedTargetStatus", None) if isinstance(payload.get("PairedTargetStatus", None), dict) else self._paired_target_status_row(target_id)
            pair_status = payload.get("PairStatus", None) if isinstance(payload.get("PairStatus", None), dict) else self._paired_pair_status_row(pair_id)
            self._set_visible_acceptance_output(
                self._format_visible_primitive_target_report(
                    title="publish 확인",
                    row=row,
                    target_status=target_status,
                    pair_status=pair_status,
                    visibility_row=visibility_row,
                    payload=payload,
                )
            )
            self.last_result_var.set(
                "마지막 결과: pair={0} target={1} publish={2}".format(
                    pair_id,
                    target_id,
                    payload.get("PrimitiveState", "") or "(없음)",
                )
            )

        self.run_background_task(
            state="publish 확인 중",
            hint=f"{pair_id}/{target_id} 기준 publish primitive를 실행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="publish 확인 완료",
            success_hint="source-outbox / latest-state / 다음 조치를 primitive wrapper 기준으로 요약했습니다.",
            failure_state="publish 확인 실패",
            failure_hint="paired status 로드 오류와 마지막 명령을 확인하세요.",
        )

    def inspect_selected_pair_handoff_status(self) -> None:
        row = self._require_visible_primitive_row(action_label="handoff 확인")
        if row is None:
            return

        pair_id = str(row.get("PairId", "") or self._selected_pair_id() or "").strip()
        target_id = str(row.get("TargetId", "") or self.target_id_var.get().strip() or "").strip()
        partner_target_id = str(row.get("PartnerTargetId", "") or "").strip()
        if not target_id:
            messagebox.showwarning("Target 필요", "handoff 확인 대상 target을 해석하지 못했습니다.")
            return
        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "handoff 확인에는 ConfigPath가 필요합니다.")
            return

        run_root, run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label="handoff 확인",
            allow_stale=True,
        )
        if not run_root:
            messagebox.showwarning("RunRoot 필요", run_root_detail)
            return

        self._set_action_context(pair_id=pair_id, target_id=target_id, run_root=run_root, source="visible-primitive-handoff")
        context = self._snapshot_context(run_root=run_root, pair_id=pair_id, target_id=target_id)
        command = self.command_service.build_script_command(
            "tests/Confirm-PairedExchangeHandoffPrimitive.ps1",
            config_path=config_path,
            run_root=run_root,
            pair_id=pair_id,
            target_id=target_id,
            extra=["-AsJson"],
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> dict:
            return self.status_service.run_json_script(
                "tests/Confirm-PairedExchangeHandoffPrimitive.ps1",
                context,
                extra=["-AsJson"],
                run_root_override=run_root,
                pair_id_override=pair_id,
                target_id_override=target_id,
            )

        def on_success(payload: dict) -> None:
            if not self._apply_paired_status_snapshot_from_payload(payload, refresh_artifacts=True):
                self.refresh_paired_status_only(refresh_artifacts=True)
            current_target_status = (
                payload.get("PairedTargetStatus", None)
                if isinstance(payload.get("PairedTargetStatus", None), dict)
                else self._paired_target_status_row(target_id)
            )
            partner_target_status = (
                payload.get("PairedPartnerStatus", None)
                if isinstance(payload.get("PairedPartnerStatus", None), dict)
                else self._paired_target_status_row(partner_target_id)
            )
            pair_status = (
                payload.get("PairStatus", None)
                if isinstance(payload.get("PairStatus", None), dict)
                else self._paired_pair_status_row(pair_id)
            )
            self._set_visible_acceptance_output(
                self._format_visible_primitive_handoff_report(
                    title="handoff 확인",
                    row=row,
                    current_target_status=current_target_status,
                    partner_target_status=partner_target_status,
                    pair_status=pair_status,
                    payload=payload,
                )
            )
            self.last_result_var.set(
                "마지막 결과: pair={0} target={1} handoff={2}".format(
                    pair_id,
                    target_id,
                    payload.get("PrimitiveState", "") or "(없음)",
                )
            )

        def on_failure(exc: Exception) -> str:
            self.refresh_paired_status_only(refresh_artifacts=False)
            lines = [
                self._format_background_exception(exc),
                "",
                f"Pair: {pair_id}",
                f"Target: {target_id}",
                f"Partner: {partner_target_id or '(없음)'}",
                f"RunRoot: {run_root}",
            ]
            return "\n".join(lines)

        self.run_background_task(
            state="handoff 확인 중",
            hint=f"{pair_id}/{target_id} 기준 handoff primitive를 실행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="handoff 확인 완료",
            success_hint="pair handoff 단계와 현재/상대 target 상태를 wrapper 기준으로 요약했습니다.",
            failure_state="handoff 확인 실패",
            failure_hint="paired status 로드 오류와 마지막 명령을 확인하세요.",
            on_failure=on_failure,
        )

    def _selected_pair_id(self) -> str:
        return self.pair_id_var.get().strip() or "pair01"

    def _selected_home_pair_selection(self) -> str:
        selection = self.home_pair_tree.selection()
        if selection:
            return selection[0]
        return ""

    def _selected_home_pair_id(self) -> str:
        selection = self._selected_home_pair_selection()
        if selection:
            return selection
        return self._selected_pair_id()

    def _selected_pair_summary(self) -> PairSummaryModel | None:
        return self.pair_controller.selected_summary(self.panel_state, self._selected_home_pair_id())

    def _home_pair_detail_text(self, summary: PairSummaryModel | None) -> str:
        detail = self.pair_controller.build_summary_detail(summary)
        if summary and summary.pair_id != self._selected_pair_id():
            detail += " / 실행 기준은 현재 선택 Pair를 유지합니다. 이 Pair로 실행하려면 '선택 Pair 반영'을 누르세요. 결과 탭에서는 이 Pair를 보조 강조합니다."
        return detail

    def _action_pair_summary(self) -> PairSummaryModel | None:
        if not self.panel_state:
            return None
        selected_pair = self._selected_pair_id()
        return next((summary for summary in self.panel_state.pairs if summary.pair_id == selected_pair), None)

    def _refresh_pair_focus_strip(self) -> None:
        if not self._has_ui_attr("pair_focus_summary_var"):
            return
        pair_id = self._selected_pair_id()
        summary = self._action_pair_summary()
        snapshot = self._build_pair_runtime_snapshot(pair_id) if pair_id else {}
        badge_spec = dict(snapshot.get("Badge") or self._pair_runtime_status_badge_spec(snapshot or {"PairId": pair_id}))
        targets = summary.targets if summary else "(targets 미확인)"
        latest_state = summary.latest_state if summary and summary.latest_state else "(상태 미확인)"
        run_root = str(snapshot.get("RunRoot", "") or "").strip()
        run_leaf = os.path.basename(os.path.normpath(run_root)) if run_root else "(runroot 없음)"
        self.pair_focus_badge_var.set(str(badge_spec.get("text", "") or "STATE 미확인"))
        self.pair_focus_summary_var.set(f"{pair_id} / {targets} / latest={latest_state}")
        detail_parts = [
            "phase={0}".format(str(snapshot.get("CurrentPhase", "") or summary.current_phase if summary else "").strip() or "(없음)"),
            "next={0}".format(str(snapshot.get("NextAction", "") or summary.next_action if summary else "").strip() or "(없음)"),
            "rt={0}".format(int(snapshot.get("RoundtripCount", 0) or (summary.roundtrip_count if summary else 0))),
            "handoff={0}".format(int(summary.handoff_ready_count if summary else 0)),
            "zip={0}".format(int(summary.zip_count if summary else 0)),
            "fail={0}".format(int(summary.failure_count if summary else 0)),
            "run={0}".format(run_leaf),
        ]
        self.pair_focus_detail_var.set(" / ".join(detail_parts))
        if self._has_ui_attr("pair_focus_badge_label"):
            try:
                self.pair_focus_badge_label.configure(
                    text=self.pair_focus_badge_var.get(),
                    bg=str(badge_spec.get("background", "#6B7280")),
                    fg=str(badge_spec.get("foreground", "#FFFFFF")),
                )
            except Exception:
                pass

    def _launcher_wrapper_path(self) -> str:
        if self.effective_data:
            return self.effective_data.get("Config", {}).get("LauncherWrapperPath", "") or ""
        return ""

    def _sync_preview_selection_with_pair(self, pair_id: str, *, target_id: str = "") -> bool:
        preview_index = None
        if target_id:
            for index, row in enumerate(self.preview_rows):
                if row.get("TargetId", "") == target_id and ((not pair_id) or row.get("PairId", "") == pair_id):
                    preview_index = index
                    break
            if preview_index is None:
                for index, row in enumerate(self.preview_rows):
                    if row.get("TargetId", "") == target_id:
                        preview_index = index
                        break
        if preview_index is None:
            preview_index = self.pair_controller.top_preview_index(self.preview_rows, pair_id)
        if preview_index is not None:
            iid = str(preview_index)
            self.row_tree.selection_set(iid)
            self.row_tree.see(iid)
            self.on_row_selected()
            return True
        return False

    def _sync_home_pair_selection(self, pair_id: str) -> None:
        if not pair_id:
            return
        if pair_id in self.home_pair_tree.get_children():
            self.home_pair_tree.selection_set(pair_id)
            self.home_pair_tree.see(pair_id)

    def _extract_prepared_run_root(self, text: str) -> str:
        return extract_prepared_run_root(text)

    def _render_action_frame(self, frame: ttk.LabelFrame, actions: list[ActionModel]) -> None:
        for child in frame.winfo_children():
            child.destroy()

        if not actions:
            ttk.Label(frame, text="(없음)", justify="left").grid(row=0, column=0, sticky="w")
            return

        for idx, action in enumerate(actions):
            row = ttk.Frame(frame)
            row.grid(row=idx, column=0, sticky="ew", pady=(0, 6))
            row.columnconfigure(0, weight=1)
            detail = action.detail or action.command_text or "-"
            ttk.Label(row, text=action.label, font=("Segoe UI", 9, "bold")).grid(row=0, column=0, sticky="w")
            ttk.Label(row, text=detail, wraplength=520, justify="left").grid(row=1, column=0, sticky="w")
            button = ttk.Button(
                row,
                text=action.label,
                command=lambda action_key=action.action_key, command_text=action.command_text: self.handle_dashboard_action(action_key, command_text=command_text),
            )
            button.grid(row=0, column=1, rowspan=2, sticky="e", padx=(8, 0))
            if self._busy and not self._dashboard_action_is_read_only(action.action_key):
                button.configure(state="disabled")

    def _render_issue_frame(self, frame: ttk.LabelFrame, issues: list[IssueModel]) -> None:
        for child in frame.winfo_children():
            child.destroy()

        if not issues:
            ttk.Label(frame, text="현재 즉시 복구가 필요한 항목은 없습니다.", justify="left").grid(row=0, column=0, sticky="w")
            return

        for idx, issue in enumerate(issues):
            row = ttk.Frame(frame)
            row.grid(row=idx, column=0, sticky="ew", pady=(0, 6))
            row.columnconfigure(0, weight=1)
            ttk.Label(row, text=issue.title, font=("Segoe UI", 9, "bold")).grid(row=0, column=0, sticky="w")
            ttk.Label(row, text=issue.detail, wraplength=520, justify="left").grid(row=1, column=0, sticky="w")
            button = ttk.Button(row, text=issue.action_label, command=lambda action_key=issue.action_key: self.handle_dashboard_action(action_key))
            button.grid(row=0, column=1, rowspan=2, sticky="e", padx=(8, 0))
            if self._busy and not self._dashboard_action_is_read_only(issue.action_key):
                button.configure(state="disabled")

    def render_home_dashboard(self) -> None:
        if not self.panel_state or not self.effective_data:
            return

        config = self.effective_data.get("Config", {})
        run_context = self.effective_data.get("RunContext", {})
        self.home_context_var.set(
            "Lane: {lane} | Config: {config_path} | RunRoot: {run_root} | 실행: {action_context} | inspection: {inspection_context}".format(
                lane=config.get("LaneName", "") or "(none)",
                config_path=config.get("ConfigPath", "") or self.config_path_var.get().strip() or "(none)",
                run_root=self._current_run_root_display_text(),
                action_context=self._action_context_summary(),
                inspection_context=self._inspection_context_summary(),
            )
        )
        self.home_updated_at_var.set("마지막 갱신: {0}".format(self.effective_data.get("GeneratedAt", "-")))
        detail = self.panel_state.overall_detail
        if self.paired_status_error:
            detail = self.home_controller.build_overall_detail(
                base_detail=detail,
                paired_status_error=self.paired_status_error,
                watcher_hint=self._watcher_runtime_hint(),
            )
        else:
            detail = self.home_controller.build_overall_detail(
                base_detail=detail,
                paired_status_error="",
                watcher_hint=self._watcher_runtime_hint(),
            )
        if self.panel_state.issues:
            primary_issue = self.panel_state.issues[0]
            detail = "{0} / 우선 조치: {1} -> {2}".format(detail, primary_issue.title, primary_issue.action_label)
        self.home_overall_var.set("상태: {0}".format(self.panel_state.overall_label))
        self.home_overall_detail_var.set(detail)

        for card in self.panel_state.cards:
            vars_by_key = self.home_card_vars.get(card.key)
            if not vars_by_key:
                continue
            vars_by_key["value"].set(card.value)
            vars_by_key["detail"].set(card.detail)
        self._refresh_visible_acceptance_summary()
        next_action_key = str(self.panel_state.next_actions[0].action_key if self.panel_state.next_actions else "").strip()

        for stage in self.panel_state.stages:
            vars_by_key = self.home_stage_vars.get(stage.key)
            button = self.home_stage_buttons.get(stage.key)
            if vars_by_key:
                vars_by_key["status"].set("상태: {0}".format(stage.status_text))
                vars_by_key["detail"].set(stage.detail)
            if button:
                button.configure(
                    text=self._highlighted_button_text(stage.action_label, active=(stage.action_key == next_action_key)),
                    state="disabled" if self._busy or not stage.enabled else "normal",
                )

        self._render_action_frame(self.home_next_actions_frame, self.panel_state.next_actions)
        self._render_issue_frame(self.home_issue_frame, self.panel_state.issues)
        self.render_home_pair_summaries()

    def render_home_pair_summaries(self) -> None:
        current_pair = self._selected_pair_id()
        selected_home_pair = self._selected_home_pair_selection() or current_pair
        for item in self.home_pair_tree.get_children():
            self.home_pair_tree.delete(item)

        if not self.panel_state:
            self.home_pair_detail_var.set("Pair 요약 데이터가 없습니다.")
            return

        for summary in self.panel_state.pairs:
            self.home_pair_tree.insert(
                "",
                "end",
                iid=summary.pair_id,
                values=(
                    summary.pair_id,
                    summary.targets,
                    "예" if summary.enabled else "아니오",
                    summary.latest_state,
                    summary.current_phase or "-",
                    summary.roundtrip_count,
                    summary.next_expected_handoff or summary.next_action or "-",
                    summary.zip_count,
                    summary.failure_count,
                ),
            )

        self._sync_home_pair_selection(selected_home_pair)
        self._apply_home_pair_tree_highlights()
        summary = self._selected_pair_summary()
        if summary:
            self.home_pair_detail_var.set(self._home_pair_detail_text(summary))

    def _artifact_query(self) -> ArtifactQuery:
        query_context = self._artifact_query_context_state()
        return ArtifactQuery(
            run_root=query_context.run_root,
            pair_id=query_context.pair_id,
            target_id=query_context.target_id,
            latest_only=query_context.latest_only,
            include_missing=query_context.include_missing,
        )

    def _selected_artifact_state(self) -> TargetArtifactState | None:
        selection = self.artifact_tree.selection()
        if not selection:
            return None
        target_id = selection[0]
        for state in self.artifact_states:
            if state.target_id == target_id:
                return state
        return None

    def _populate_artifact_filter_values(self, states: list[TargetArtifactState]) -> None:
        pair_values = [""] + sorted({state.pair_id for state in states if state.pair_id})
        target_values = [""] + sorted({state.target_id for state in states if state.target_id})
        self.artifact_pair_combo.configure(values=pair_values)
        self.artifact_target_combo.configure(values=target_values)
        if self.artifact_pair_filter_var.get().strip() and self.artifact_pair_filter_var.get().strip() not in pair_values:
            self.artifact_pair_filter_var.set("")
        if self.artifact_target_filter_var.get().strip() and self.artifact_target_filter_var.get().strip() not in target_values:
            self.artifact_target_filter_var.set("")

    def refresh_artifacts_tab(self, _event: object | None = None) -> None:
        if self._artifact_home_browse_pair_scope_enabled():
            self._sync_artifact_filters_with_home_pair_selection(refresh=False)
        current_state = self._selected_artifact_state()
        selected_target = current_state.target_id if current_state else ""
        if not self.effective_data:
            self.artifact_states = []
            self.artifact_pair_summaries = []
            for item in self.artifact_tree.get_children():
                self.artifact_tree.delete(item)
            self.artifact_status_base_text = "결과 / 산출물 데이터를 아직 읽지 못했습니다."
            self.artifact_status_var.set(self.artifact_status_base_text)
            self.set_text(self.artifact_summary_text, "")
            self.set_text(self.artifact_details_text, "")
            self._refresh_sticky_context_bar()
            return

        query = self._artifact_query()
        tab_state = self.artifact_controller.build_view_state(
            effective_data=self.effective_data,
            paired_status=self.paired_status_data,
            query=query,
            selected_target_id=selected_target,
            watcher_status=self._watcher_status(),
            paired_status_error=self.paired_status_error,
        )
        self.artifact_pair_combo.configure(values=tab_state.pair_values)
        self.artifact_target_combo.configure(values=tab_state.target_values)
        self.artifact_states = tab_state.states
        self.artifact_pair_summaries = tab_state.pair_summaries

        for item in self.artifact_tree.get_children():
            self.artifact_tree.delete(item)
        for state in tab_state.states:
            self.artifact_tree.insert(
                "",
                "end",
                iid=state.target_id,
                values=(
                    state.pair_id,
                    state.target_id,
                    state.role_name,
                    self.artifact_service.format_target_state_label(state),
                    "예" if state.summary_present else "아니오",
                    state.zip_count,
                    "예" if state.error_present else "아니오",
                    state.failure_count,
                    state.latest_modified_at or "-",
                ),
            )
        self.artifact_status_base_text = tab_state.status_base_text
        self._apply_artifact_status_text(base_text=self.artifact_status_base_text, preview=tab_state.preview)

        if tab_state.selected_target_id and tab_state.selected_target_id in self.artifact_tree.get_children():
            self.artifact_tree.selection_set(tab_state.selected_target_id)
        elif self.artifact_tree.get_children():
            self.artifact_tree.selection_set(self.artifact_tree.get_children()[0])

        self.on_artifact_row_selected()
        self._refresh_sticky_context_bar()

    def on_artifact_row_selected(self, _event: object | None = None) -> None:
        state = self._selected_artifact_state()
        if state is None:
            self._apply_artifact_status_text(base_text=self.artifact_status_base_text)
            self.set_text(self.artifact_summary_text, "")
            self.set_text(self.artifact_details_text, "")
            self._refresh_sticky_context_bar()
            return

        preview = self.artifact_controller.get_preview(self.artifact_states, state.target_id)
        if preview is None:
            self._apply_artifact_status_text(base_text=self.artifact_status_base_text)
            self.set_text(self.artifact_summary_text, "")
            self.set_text(self.artifact_details_text, "")
            self._refresh_sticky_context_bar()
            return

        contract_paths = self._resolve_artifact_contract_paths(state)
        self._apply_artifact_status_text(
            base_text=self.artifact_status_base_text,
            preview=preview,
            state=state,
            contract_paths=contract_paths,
        )
        self.set_text(self.artifact_summary_text, preview.summary_text)
        artifact_run_root = self._current_run_root_for_artifacts()
        action_run_root = self._current_run_root_for_actions()
        detail_lines = [
            f"조회 RunRoot: {artifact_run_root or '(없음)'}",
            f"조회 RunRoot override: {self._artifact_run_root_uses_override()}",
            f"조회 RunRoot stale 여부: {self._current_artifact_run_root_is_stale()}",
            f"실행 RunRoot: {action_run_root or '(없음)'}",
            f"실행 RunRoot stale 여부: {self._current_run_root_is_stale_for_actions()}",
            "",
            f"제목: {preview.title}",
            f"계약 상태(LatestState): {preview.latest_state}",
            f"표시 상태: {preview.state_label or '(없음)'}",
            f"차단 이유: {preview.blocker_reason or '(없음)'}",
            f"다음 조치: {preview.recommended_action or '(없음)'}",
            f"source-outbox 계약 상태: {self.artifact_service.display_latest_state(preview.source_outbox_contract_latest_state) or '(없음)'}",
            f"source-outbox 다음 동작: {self.artifact_service.display_next_action(preview.source_outbox_next_action) or '(없음)'}",
            f"후속 실행 상태: {self.artifact_service.display_dispatch_state(preview.dispatch_state) or '(없음)'}",
            f"후속 실행 갱신 시각: {preview.dispatch_updated_at or '(없음)'}",
            f"latest zip: {preview.latest_zip_name or '(없음)'}",
            f"latest zip 경로: {preview.latest_zip_path or '(없음)'}",
            f"target 폴더: {preview.target_folder or '(없음)'}",
            f"review 폴더: {preview.review_folder or '(없음)'}",
            f"work 폴더: {contract_paths.get('WorkFolderPath', '') or '(없음)'}",
            f"source outbox: {contract_paths.get('SourceOutboxPath', '') or '(없음)'}",
            f"source outbox 진단: {contract_paths.get('SourceOutboxPathWarning', '') or '(없음)'}",
            f"source summary: {contract_paths.get('SourceSummaryPath', '') or '(없음)'}",
            f"source review zip: {contract_paths.get('SourceReviewZipPath', '') or '(없음)'}",
            f"publish ready: {contract_paths.get('PublishReadyPath', '') or '(없음)'}",
            f"published archive: {contract_paths.get('PublishedArchivePath', '') or '(없음)'}",
            f"request 경로: {preview.request_path or '(없음)'}",
            f"done 경로: {preview.done_path or '(없음)'}",
            f"error 경로: {preview.error_path or '(없음)'}",
            f"result 경로: {preview.result_path or '(없음)'}",
            f"check wrapper: {contract_paths.get('CheckScriptPath', '') or '(없음)'}",
            f"submit wrapper: {contract_paths.get('SubmitScriptPath', '') or '(없음)'}",
            f"check cmd: {contract_paths.get('CheckCmdPath', '') or '(없음)'}",
            f"submit cmd: {contract_paths.get('SubmitCmdPath', '') or '(없음)'}",
            f"wrapper 경로 출처: {contract_paths.get('Source', '') or '(없음)'}",
            f"check wrapper 존재: {contract_paths.get('CheckScriptPathExists', False)}",
            f"submit wrapper 존재: {contract_paths.get('SubmitScriptPathExists', False)}",
            f"source memory warning: {self.artifact_source_memory_warning or '(없음)'}",
            f"상태 배지: {' '.join(self._artifact_warning_badges(state=state, contract_paths=contract_paths)) or '(없음)'}",
            "",
            "최근 source 경로:",
        ]
        remembered_sources = self._artifact_last_sources(state.target_id)
        if remembered_sources:
            detail_lines.extend(
                [
                    f"- SummarySourcePath: {remembered_sources.get('SummarySourcePath', '(없음)')}",
                    f"- ReviewZipSourcePath: {remembered_sources.get('ReviewZipSourcePath', '(없음)')}",
                    f"- RecordedAt: {remembered_sources.get('RecordedAt', '(없음)')}",
                ]
            )
        else:
            detail_lines.append("- (없음)")
        detail_lines.extend(
            [
                "",
            ]
        )
        detail_lines.extend(self._artifact_last_action_summary_lines(state.target_id))
        detail_lines.extend(
            [
                "",
            "메모:",
            ]
        )
        if preview.notes:
            detail_lines.extend([f"- {item}" for item in preview.notes])
        else:
            detail_lines.append("- (없음)")
        self.set_text(self.artifact_details_text, "\n".join(detail_lines))
        self._refresh_sticky_context_bar()

    def open_selected_artifact_path(self, kind: str) -> None:
        state = self._selected_artifact_state()
        if state is None:
            messagebox.showwarning("선택 필요", "target row를 먼저 선택하세요.")
            return
        path_value = self.artifact_service.resolve_artifact_path(state, kind)
        if not path_value:
            messagebox.showwarning("경로 없음", f"{kind} 경로를 찾지 못했습니다.")
            return
        try:
            self.artifact_service.open_path(path_value)
        except FileNotFoundError:
            messagebox.showwarning("경로 없음", path_value)
            return
        self.set_text(self.output_text, f"{kind} 열기:\n{path_value}")

    def copy_selected_artifact_path(self) -> None:
        state = self._selected_artifact_state()
        if state is None:
            messagebox.showwarning("선택 필요", "target row를 먼저 선택하세요.")
            return
        label = self.artifact_path_kind_var.get().strip() or "summary"
        kind = ARTIFACT_PATH_LABEL_TO_KIND.get(label, "summary")
        path_value = self.artifact_service.resolve_artifact_path(state, kind)
        if not path_value:
            messagebox.showwarning("경로 없음", f"{kind} 경로를 찾지 못했습니다.")
            return
        self._copy_to_clipboard(path_value)
        self.set_text(self.output_text, f"{kind} 경로 복사 완료:\n{path_value}")

    def _preview_row_for_target(self, target_id: str) -> dict | None:
        normalized = str(target_id or "").strip()
        if not normalized:
            return None
        for row in self.preview_rows:
            if str(row.get("TargetId", "") or "").strip() == normalized:
                return row
        return None

    def _safe_read_json_file(self, path_value: str) -> dict:
        path_text = str(path_value or "").strip()
        if not path_text:
            return {}
        try:
            raw = Path(path_text).read_text(encoding="utf-8-sig")
        except OSError:
            return {}
        if not raw.strip():
            return {}
        try:
            payload = json.loads(raw)
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    def _pair_test_file_name(self, key: str, default: str) -> str:
        pair_test = (self.effective_data or {}).get("PairTest", {}) or {}
        value = str(pair_test.get(key, "") or "").strip()
        return value or default

    def _artifact_last_sources(self, target_id: str) -> dict[str, str]:
        return dict(self.artifact_last_sources_by_target.get(str(target_id or "").strip(), {}) or {})

    def _load_artifact_source_memory(self) -> None:
        self.artifact_source_memory_warning = ""
        try:
            if not self.artifact_source_memory_path.exists():
                self.artifact_last_sources_by_target = {}
                return
            raw = self.artifact_source_memory_path.read_text(encoding="utf-8")
        except OSError as exc:
            self.artifact_last_sources_by_target = {}
            self.artifact_source_memory_warning = f"source-memory read failed: {exc}"
            return
        if not raw.strip():
            self.artifact_last_sources_by_target = {}
            return
        try:
            payload = json.loads(raw)
        except Exception as exc:
            self.artifact_last_sources_by_target = {}
            self.artifact_source_memory_warning = (
                f"source-memory parse failed; memory cache reset ({self.artifact_source_memory_path.name}): {exc}"
            )
            return
        if not isinstance(payload, dict):
            self.artifact_last_sources_by_target = {}
            self.artifact_source_memory_warning = (
                f"source-memory payload is not an object; memory cache reset ({self.artifact_source_memory_path.name})"
            )
            return

        schema_version = payload.get("SchemaVersion", None)
        if schema_version not in (None, ARTIFACT_SOURCE_MEMORY_SCHEMA_VERSION):
            self.artifact_last_sources_by_target = {}
            self.artifact_source_memory_warning = (
                "source-memory schema version is unsupported; memory cache reset "
                f"({self.artifact_source_memory_path.name}, version={schema_version})"
            )
            return

        targets_payload = payload.get("Targets", payload)
        if not isinstance(targets_payload, dict):
            self.artifact_last_sources_by_target = {}
            self.artifact_source_memory_warning = (
                f"source-memory targets payload is invalid; memory cache reset ({self.artifact_source_memory_path.name})"
            )
            return

        remembered: dict[str, dict[str, str]] = {}
        for target_id, item in targets_payload.items():
            normalized_target = str(target_id or "").strip()
            if not normalized_target or not isinstance(item, dict):
                continue
            summary_path = str(item.get("SummarySourcePath", "") or "").strip()
            review_zip_path = str(item.get("ReviewZipSourcePath", "") or "").strip()
            recorded_at = str(item.get("RecordedAt", "") or "").strip()
            if not summary_path and not review_zip_path:
                continue
            remembered[normalized_target] = {
                "SummarySourcePath": summary_path,
                "ReviewZipSourcePath": review_zip_path,
                "RecordedAt": recorded_at,
            }
        self.artifact_last_sources_by_target = remembered

    def _save_artifact_source_memory(self) -> None:
        temp_path: Path | None = None
        try:
            self.artifact_source_memory_path.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "SchemaVersion": ARTIFACT_SOURCE_MEMORY_SCHEMA_VERSION,
                "SavedAt": datetime.now().isoformat(timespec="seconds"),
                "Targets": {
                    target_id: {
                        "SummarySourcePath": str(item.get("SummarySourcePath", "") or "").strip(),
                        "ReviewZipSourcePath": str(item.get("ReviewZipSourcePath", "") or "").strip(),
                        "RecordedAt": str(item.get("RecordedAt", "") or "").strip(),
                    }
                    for target_id, item in self.artifact_last_sources_by_target.items()
                    if str(target_id or "").strip()
                },
            }
            temp_path = self.artifact_source_memory_path.with_name(
                self.artifact_source_memory_path.name
                + f".{os.getpid()}.{threading.get_ident()}.tmp"
            )
            temp_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            os.replace(temp_path, self.artifact_source_memory_path)
            self.artifact_source_memory_warning = ""
        except Exception as exc:
            self.artifact_source_memory_warning = f"source-memory save failed: {exc}"
        finally:
            if temp_path is not None and temp_path.exists():
                try:
                    temp_path.unlink()
                except OSError:
                    pass

    def _remember_artifact_sources(self, target_id: str, summary_path: str, review_zip_path: str) -> None:
        normalized_target = str(target_id or "").strip()
        if not normalized_target:
            return
        self.artifact_last_sources_by_target[normalized_target] = {
            "SummarySourcePath": str(summary_path or "").strip(),
            "ReviewZipSourcePath": str(review_zip_path or "").strip(),
            "RecordedAt": datetime.now().isoformat(timespec="seconds"),
        }
        self._save_artifact_source_memory()

    def _remember_artifact_action_result(self, target_id: str, payload: dict[str, object]) -> None:
        normalized_target = str(target_id or "").strip()
        if not normalized_target:
            return
        self.artifact_last_action_by_target[normalized_target] = dict(payload)

    def _artifact_last_action_summary_lines(self, target_id: str) -> list[str]:
        record = dict(self.artifact_last_action_by_target.get(str(target_id or "").strip(), {}) or {})
        if not record:
            return ["마지막 panel 실행: (없음)"]

        lines = [
            "마지막 panel 실행:",
            "- Action: {0}".format(record.get("Action", "(없음)")),
            "- Status: {0}".format(record.get("Status", "(없음)")),
            "- At: {0}".format(record.get("RecordedAt", "(없음)")),
            "- UsedWrapper: {0}".format(record.get("UsedWrapper", False)),
            "- ExecutionPath: {0}".format(record.get("ExecutionPath", "(없음)")),
            "- RequiresOverwrite: {0}".format(record.get("RequiresOverwrite", False)),
            "- 계약 LatestState: {0}".format(record.get("LatestState", "(없음)")),
            "- LatestZipPath: {0}".format(record.get("LatestZipPath", "(없음)")),
        ]
        summary_source_path = str(record.get("SummarySourcePath", "") or "").strip()
        review_zip_source_path = str(record.get("ReviewZipSourcePath", "") or "").strip()
        if summary_source_path:
            lines.append("- SummarySourcePath: {0}".format(summary_source_path))
        if review_zip_source_path:
            lines.append("- ReviewZipSourcePath: {0}".format(review_zip_source_path))
        error_text = str(record.get("Error", "") or "").strip()
        if error_text:
            lines.append("- Error: {0}".format(error_text))
        return lines

    def _begin_submit_action(self, target_id: str) -> bool:
        normalized_target = str(target_id or "").strip()
        if not normalized_target:
            return True
        if normalized_target in self.artifact_submit_active_targets:
            return False
        self.artifact_submit_active_targets.add(normalized_target)
        return True

    def _finish_submit_action(self, target_id: str) -> None:
        normalized_target = str(target_id or "").strip()
        if not normalized_target:
            return
        self.artifact_submit_active_targets.discard(normalized_target)

    def _confirm_recent_submit_repeat(self, target_id: str) -> bool:
        record = dict(self.artifact_last_action_by_target.get(str(target_id or "").strip(), {}) or {})
        if str(record.get("Action", "") or "").strip() != "submit":
            return True
        if str(record.get("Status", "") or "").strip() not in {"success", "running"}:
            return True
        recorded_at_text = str(record.get("RecordedAt", "") or "").strip()
        if not recorded_at_text:
            return True
        try:
            recorded_at = datetime.fromisoformat(recorded_at_text)
        except ValueError:
            return True
        age_seconds = (datetime.now() - recorded_at).total_seconds()
        if age_seconds > 15:
            return True
        return messagebox.askyesno(
            "submit 재실행 확인",
            (
                f"{target_id} 에 대해 {age_seconds:.1f}초 전에 submit 실행 기록이 있습니다.\n"
                "연속 재실행은 중복 제출일 수 있습니다. 계속할까요?"
            ),
            parent=self,
        )

    def _current_run_root_is_stale_for_actions(self) -> bool:
        return self._run_root_is_stale(self._current_run_root_for_actions())

    def _run_root_is_stale(self, run_root: str) -> bool:
        candidate = str(run_root or "").strip()
        if not candidate:
            return False

        run_context = (self.effective_data or {}).get("RunContext", {}) or {}
        selected_run_root = str(run_context.get("SelectedRunRoot", "") or "").strip()
        if selected_run_root and self._same_run_root_path(candidate, selected_run_root):
            return bool(run_context.get("SelectedRunRootIsStale", False))

        threshold = int(run_context.get("StaleRunThresholdSec", 1800) or 1800)
        run_root_path = Path(candidate)
        if not run_root_path.exists():
            return False

        try:
            age_seconds = max(0.0, datetime.now().timestamp() - run_root_path.stat().st_mtime)
        except OSError:
            return False
        return age_seconds >= threshold

    def _prepare_run_root_override_to_ignore(self) -> str:
        requested_run_root = self.run_root_var.get().strip()
        if not requested_run_root:
            return ""
        if self._run_root_is_stale(requested_run_root):
            return requested_run_root
        return ""

    def _format_run_root_prepare_output(
        self,
        *,
        output: str,
        ignored_run_root: str = "",
        prepared_run_root: str = "",
    ) -> str:
        lines: list[str] = []
        if ignored_run_root:
            lines.extend(
                [
                    "오래된 RunRoot 입력 무시 후 새 RunRoot 생성",
                    f"IgnoredRunRoot: {ignored_run_root}",
                    "",
                ]
            )
        lines.append(output)
        if prepared_run_root:
            lines.extend(
                [
                    "",
                    f"ActionRunRoot: {prepared_run_root}",
                    "RunRoot 입력칸 갱신 완료",
                ]
            )
        return "\n".join(lines)

    def _run_root_prepare_last_result(self, *, ignored_run_root: str = "", prepared_run_root: str = "") -> str:
        if prepared_run_root:
            if ignored_run_root:
                return "마지막 결과: stale RunRoot 입력 무시 후 새 RunRoot 준비 및 입력칸 갱신 완료"
            return "마지막 결과: 새 RunRoot 준비 및 입력칸 갱신 완료"
        if ignored_run_root:
            return "마지막 결과: stale RunRoot 입력 무시 후 RunRoot 준비 완료"
        return "마지막 결과: RunRoot 준비 완료"

    @staticmethod
    def _resolve_run_root_summary_run_root(*candidates: str) -> str:
        return resolve_run_root_summary_run_root(*candidates)

    def _run_root_summary_text_for(self, *, run_root: str, config_path: str) -> str:
        return self._runtime_workflow().load_run_root_summary_text(
            run_root=str(run_root or "").strip(),
            config_path=config_path,
        )

    def _run_root_summary_text(self, run_root: str = "", *, config_path: str = "") -> str:
        summary_run_root = self._resolve_run_root_summary_run_root(
            run_root,
            self._current_run_root_for_actions(),
        )
        summary_config_path = str(config_path or self.config_path_var.get().strip())
        return self._run_root_summary_text_for(
            run_root=summary_run_root,
            config_path=summary_config_path,
        )

    def _requested_run_root_for_prepare(self) -> str:
        if self._run_root_override_state() != "override-active":
            return ""
        if self._prepare_run_root_override_to_ignore():
            return ""
        return self.run_root_var.get().strip()

    def _artifact_warning_badges(
        self,
        state: TargetArtifactState | None = None,
        contract_paths: dict[str, object] | None = None,
    ) -> list[str]:
        badges: list[str] = []
        if str(getattr(self, "artifact_source_memory_warning", "") or "").strip():
            badges.append("[SOURCE MEMORY WARNING]")
        if self._artifact_run_root_uses_override():
            badges.append("[ARTIFACT RUNROOT OVERRIDE]")
        if self._current_artifact_run_root_is_stale():
            badges.append("[ARTIFACT RUNROOT STALE]")
        if state is not None:
            resolved_contract = contract_paths or self._resolve_artifact_contract_paths(state)
            if not bool(resolved_contract.get("CheckScriptPathExists", False)):
                badges.append("[LEGACY CHECK FALLBACK RISK]")
            if not bool(resolved_contract.get("SubmitScriptPathExists", False)):
                badges.append("[LEGACY SUBMIT FALLBACK RISK]")
            if str(resolved_contract.get("SourceOutboxPathWarning", "") or "").strip():
                badges.append("[OUTPUTFILES PARENT MISMATCH]")
        return badges

    def _apply_artifact_status_text(
        self,
        *,
        base_text: str,
        preview=None,
        state: TargetArtifactState | None = None,
        contract_paths: dict[str, object] | None = None,
    ) -> None:
        status_text = self.artifact_controller.decorate_status_text(base_text, preview)
        artifact_run_root = self._current_run_root_for_artifacts()
        action_run_root = self._current_run_root_for_actions()
        if artifact_run_root or action_run_root:
            status_prefix = "조회={0} | 실행={1}".format(
                Path(artifact_run_root).name if artifact_run_root else "(없음)",
                Path(action_run_root).name if action_run_root else "(없음)",
            )
            if artifact_run_root != action_run_root:
                status_prefix += " | 컨텍스트 분리"
            status_text = " | ".join(part for part in [status_prefix, status_text] if part)
        badges = self._artifact_warning_badges(state=state, contract_paths=contract_paths)
        if badges:
            status_text = " ".join(badges + [status_text])
        self.artifact_status_var.set(status_text)

    def _resolve_artifact_contract_paths(self, state: TargetArtifactState) -> dict[str, object]:
        preview_row = self._preview_row_for_target(state.target_id) or {}
        request_path = self.artifact_service.resolve_artifact_path(state, "request") or str(preview_row.get("RequestPath", "") or "")
        request_payload = self._safe_read_json_file(request_path)
        request_output_paths = self._resolved_output_paths_from_row(request_payload)
        preview_output_paths = self._resolved_output_paths_from_row(preview_row)
        request_outbox_path, request_outbox_warning = self._resolved_source_outbox_path_analysis_from_row(request_payload)
        preview_outbox_path, preview_outbox_warning = self._resolved_source_outbox_path_analysis_from_row(preview_row)
        target_folder = str(
            request_payload.get("TargetFolder", "")
            or preview_row.get("PairTargetFolder", "")
            or state.target_folder
            or ""
        ).strip()

        def resolve_contract_path(request_key: str, row_key: str, fallback_name: str) -> str:
            direct = str(request_payload.get(request_key, "") or preview_row.get(row_key, "") or "").strip()
            if direct:
                return direct
            if target_folder and fallback_name:
                return str(Path(target_folder) / fallback_name)
            return ""

        resolved = {
            "TargetFolder": target_folder,
            "RequestPath": request_path,
            "WorkFolderPath": resolve_contract_path(
                "WorkFolderPath",
                "WorkFolderPath",
                self._pair_test_file_name("WorkFolderName", "work"),
            ),
            "CheckScriptPath": resolve_contract_path(
                "CheckScriptPath",
                "CheckScriptPath",
                self._pair_test_file_name("CheckScriptFileName", "check-artifact.ps1"),
            ),
            "SubmitScriptPath": resolve_contract_path(
                "SubmitScriptPath",
                "SubmitScriptPath",
                self._pair_test_file_name("SubmitScriptFileName", "submit-artifact.ps1"),
            ),
            "CheckCmdPath": resolve_contract_path(
                "CheckCmdPath",
                "CheckCmdPath",
                self._pair_test_file_name("CheckCmdFileName", "check-artifact.cmd"),
            ),
            "SubmitCmdPath": resolve_contract_path(
                "SubmitCmdPath",
                "SubmitCmdPath",
                self._pair_test_file_name("SubmitCmdFileName", "submit-artifact.cmd"),
            ),
            "Source": "request" if request_payload else ("preview" if preview_row else "fallback"),
        }
        request_has_authoritative_contract = any(
            str(request_payload.get(field_name, "") or "").strip()
            for field_name in (
                "SourceOutboxPath",
                "SourceSummaryPath",
                "SourceReviewZipPath",
                "PublishReadyPath",
            )
        )
        if request_has_authoritative_contract:
            source_outbox_warning = str(request_outbox_warning or "").strip()
        else:
            source_outbox_warning = str(request_outbox_warning or preview_outbox_warning or "").strip()
        source_outbox_path = str(
            request_payload.get("SourceOutboxPath", "")
            or request_outbox_path
            or preview_outbox_path
            or ""
        ).strip()
        if not source_outbox_path and target_folder and not source_outbox_warning:
            source_outbox_path = str(
                Path(target_folder)
                / self._pair_test_file_name("SourceOutboxFolderName", "source-outbox")
            )
        resolved["SourceOutboxPath"] = source_outbox_path
        resolved["SourceOutboxPathWarning"] = source_outbox_warning
        resolved["SourceSummaryPath"] = str(
            request_output_paths.get("SourceSummaryPath", "")
            or preview_output_paths.get("SourceSummaryPath", "")
            or (str(Path(source_outbox_path) / self._pair_test_file_name("SourceSummaryFileName", "summary.txt")) if source_outbox_path else "")
        ).strip()
        resolved["SourceReviewZipPath"] = str(
            request_output_paths.get("SourceReviewZipPath", "")
            or preview_output_paths.get("SourceReviewZipPath", "")
            or (str(Path(source_outbox_path) / self._pair_test_file_name("SourceReviewZipFileName", "review.zip")) if source_outbox_path else "")
        ).strip()
        resolved["PublishReadyPath"] = str(
            request_output_paths.get("PublishReadyPath", "")
            or preview_output_paths.get("PublishReadyPath", "")
            or (str(Path(source_outbox_path) / self._pair_test_file_name("PublishReadyFileName", "publish.ready.json")) if source_outbox_path else "")
        ).strip()
        resolved["PublishedArchivePath"] = str(
            request_payload.get("PublishedArchivePath", "")
            or preview_row.get("PublishedArchivePath", "")
            or (str(Path(source_outbox_path) / self._pair_test_file_name("PublishedArchiveFolderName", ".published")) if source_outbox_path else "")
        ).strip()

        for key in (
            "WorkFolderPath",
            "SourceOutboxPath",
            "SourceSummaryPath",
            "SourceReviewZipPath",
            "PublishReadyPath",
            "PublishedArchivePath",
            "CheckScriptPath",
            "SubmitScriptPath",
            "CheckCmdPath",
            "SubmitCmdPath",
        ):
            path_value = str(resolved.get(key, "") or "").strip()
            resolved[key + "Exists"] = bool(path_value and Path(path_value).exists())
        return resolved

    def _build_artifact_action_command(
        self,
        *,
        state: TargetArtifactState,
        config_path: str,
        run_root: str,
        wrapper_key: str,
        fallback_script_name: str,
        extra: list[str],
    ) -> ArtifactCommandPlan:
        contract_paths = self._resolve_artifact_contract_paths(state)
        wrapper_path = str(contract_paths.get(wrapper_key, "") or "").strip()
        if wrapper_path and Path(wrapper_path).exists():
            return ArtifactCommandPlan(
                command=tuple(self.command_service.build_powershell_file_command(wrapper_path, extra=extra)),
                execution_path=wrapper_path,
                used_wrapper=True,
                contract_paths=contract_paths,
            )

        command = self.command_service.build_script_command(
            fallback_script_name,
            config_path=config_path,
            run_root=run_root,
            target_id=state.target_id,
            extra=extra,
        )
        return ArtifactCommandPlan(
            command=tuple(command),
            execution_path=str(ROOT / fallback_script_name),
            used_wrapper=False,
            contract_paths=contract_paths,
        )

    def _selected_artifact_action_context(self) -> ArtifactActionContextSnapshot | None:
        state = self._selected_artifact_state()
        if state is None:
            messagebox.showwarning("선택 필요", "target row를 먼저 선택하세요.")
            return None

        run_root = self._current_run_root_for_actions()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "artifact 검증/가져오기에는 RunRoot가 필요합니다.")
            return None

        artifact_run_root = self._current_run_root_for_artifacts()
        if artifact_run_root:
            normalized_artifact = os.path.normcase(os.path.normpath(artifact_run_root))
            normalized_action = os.path.normcase(os.path.normpath(run_root))
            if normalized_artifact != normalized_action:
                confirmed = messagebox.askyesno(
                    "Artifact 실행 RunRoot 확인",
                    "\n".join(
                        [
                            "현재 결과 / 산출물 탭은 action RunRoot와 다른 RunRoot를 조회 중입니다.",
                            "",
                            f"조회 RunRoot: {artifact_run_root}",
                            f"실행 RunRoot: {run_root}",
                            "",
                            "artifact check/submit은 실행 RunRoot 기준 target folder 계약에 기록됩니다.",
                            "계속할까요?",
                        ]
                    ),
                    parent=self,
                )
                if not confirmed:
                    return None

        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "artifact 검증/가져오기에는 ConfigPath가 필요합니다.")
            return None

        return ArtifactActionContextSnapshot(
            state=state,
            config_path=config_path,
            run_root=run_root,
            run_root_is_stale=self._run_root_is_stale(run_root),
        )

    def _record_artifact_action_result(
        self,
        *,
        action: str,
        status: str,
        context: ArtifactActionContextSnapshot,
        sources: ArtifactSourceSelection,
        plan: ArtifactCommandPlan,
        requires_overwrite: bool = False,
        latest_state: str = "",
        latest_zip_path: str = "",
        error: str = "",
    ) -> None:
        self._remember_artifact_action_result(
            context.state.target_id,
            build_artifact_action_record(
                action=action,
                status=status,
                context=context,
                sources=sources,
                plan=plan,
                recorded_at=datetime.now().isoformat(timespec="seconds"),
                requires_overwrite=requires_overwrite,
                latest_state=latest_state,
                latest_zip_path=latest_zip_path,
                error=error,
            ),
        )

    def _prompt_external_artifact_sources(self, state: TargetArtifactState) -> tuple[str, str] | None:
        contract_paths = self._resolve_artifact_contract_paths(state)
        remembered = self._artifact_last_sources(state.target_id)
        remembered_summary_path = str(remembered.get("SummarySourcePath", "") or "").strip()
        remembered_review_zip_path = str(remembered.get("ReviewZipSourcePath", "") or "").strip()
        if (
            remembered_summary_path
            and remembered_review_zip_path
            and Path(remembered_summary_path).exists()
            and Path(remembered_review_zip_path).exists()
        ):
            reuse_confirmed = messagebox.askyesno(
                "최근 source 재사용",
                "\n".join(
                    [
                        f"{state.target_id} 에 마지막으로 사용한 source 경로가 있습니다.",
                        "",
                        f"source summary: {remembered_summary_path}",
                        f"source zip: {remembered_review_zip_path}",
                        "",
                        "이 경로를 그대로 다시 사용할까요?",
                    ]
                ),
                parent=self,
            )
            if reuse_confirmed:
                return remembered_summary_path, remembered_review_zip_path

        initial_dir = str(contract_paths.get("WorkFolderPath", "") or "").strip()
        if not initial_dir:
            initial_dir = str(Path(state.target_folder).parent) if state.target_folder else str(ROOT)
        initial_file = ""
        if remembered_summary_path:
            remembered_summary = Path(remembered_summary_path)
            if remembered_summary.parent.exists():
                initial_dir = str(remembered_summary.parent)
            initial_file = remembered_summary.name
        summary_path = filedialog.askopenfilename(
            title=f"{state.target_id} source summary 파일 선택",
            initialdir=initial_dir,
            initialfile=initial_file,
            filetypes=[("Text/Markdown", "*.txt *.md"), ("All files", "*.*")],
        )
        if not summary_path:
            return None

        zip_initial_dir = str(Path(summary_path).resolve().parent)
        zip_initial_file = ""
        if remembered_review_zip_path:
            remembered_review_zip = Path(remembered_review_zip_path)
            if remembered_review_zip.parent.exists():
                zip_initial_dir = str(remembered_review_zip.parent)
            zip_initial_file = remembered_review_zip.name
        review_zip_path = filedialog.askopenfilename(
            title=f"{state.target_id} source review zip 선택 (paired submit 아님)",
            initialdir=zip_initial_dir,
            initialfile=zip_initial_file,
            filetypes=[("ZIP", "*.zip"), ("All files", "*.*")],
        )
        if not review_zip_path:
            return None

        return summary_path, review_zip_path

    def _format_external_artifact_preflight(self, payload: dict) -> str:
        validation = payload.get("Validation", {}) or {}
        preflight = payload.get("Preflight", {}) or {}
        lines = [
            "외부 artifact preflight",
            "이 summary/source zip은 입력 source입니다. paired submit 자체는 target-local wrapper 또는 import가 target folder contract에 기록할 때 완료됩니다.",
        ]
        summary_lines = [str(item) for item in (preflight.get("SummaryLines", []) or []) if str(item).strip()]
        if summary_lines:
            lines.extend(summary_lines)
        else:
            lines.append("(preflight summary 없음)")
        lines.extend(
            [
                "",
                "Issues: " + (", ".join(str(item) for item in (validation.get("Issues", []) or [])) or "(none)"),
                "Warnings: " + (", ".join(str(item) for item in (validation.get("Warnings", []) or [])) or "(none)"),
            ]
        )
        return "\n".join(lines)

    def check_selected_external_artifact(self) -> None:
        context = self._selected_artifact_action_context()
        if context is None:
            return
        selected_sources = self._prompt_external_artifact_sources(context.state)
        if selected_sources is None:
            return
        sources = ArtifactSourceSelection(*selected_sources)
        self._remember_artifact_sources(context.state.target_id, sources.summary_path, sources.review_zip_path)

        plan = self._build_artifact_action_command(
            state=context.state,
            config_path=context.config_path,
            run_root=context.run_root,
            wrapper_key="CheckScriptPath",
            fallback_script_name="check-paired-exchange-artifact.ps1",
            extra=[
                "-SummarySourcePath",
                sources.summary_path,
                "-ReviewZipSourcePath",
                sources.review_zip_path,
                "-AsJson",
            ],
        )
        self._record_artifact_action_result(
            action="check",
            status="running",
            context=context,
            sources=sources,
            plan=plan,
        )
        self.last_command_var.set(subprocess.list2cmdline(list(plan.command)))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(list(plan.command))

        def on_failure(exc: Exception) -> None:
            self._record_artifact_action_result(
                action="check",
                status="failed",
                context=context,
                sources=sources,
                plan=plan,
                error=str(exc),
            )

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            preflight_text = self._format_external_artifact_preflight(payload)
            validation = payload.get("Validation", {}) or {}
            preflight = payload.get("Preflight", {}) or {}
            current_target = payload.get("PreImportStatus", {}) or {}
            latest_state = str(preflight.get("CurrentLatestState", "") or current_target.get("LatestState", "") or "")
            latest_zip_path = str(preflight.get("DestinationZipPath", "") or "")
            self._record_artifact_action_result(
                action="check",
                status="success",
                context=context,
                sources=sources,
                plan=plan,
                requires_overwrite=bool(validation.get("RequiresOverwrite", False)),
                latest_state=latest_state,
                latest_zip_path=latest_zip_path,
            )
            header_lines = [
                "artifact check 실행",
                f"실행 경로: {plan.execution_path}",
                f"target-local wrapper 사용: {'예' if plan.used_wrapper else '아니오 (root fallback)'}",
                f"wrapper 경로 출처: {plan.contract_paths.get('Source', '') or '(없음)'}",
            ]
            if not plan.used_wrapper:
                header_lines.append("LEGACY FALLBACK WARNING: target-local wrapper 없이 root fallback check를 사용했습니다.")
            if context.run_root_is_stale:
                header_lines.append("주의: 현재 선택된 RunRoot가 stale 표시입니다. 새 wrapper가 없는 예전 run일 수 있습니다.")
            self.set_text(
                self.output_text,
                "\n".join(header_lines) + "\n\n" + preflight_text + "\n\nJSON\n" + json.dumps(payload, ensure_ascii=False, indent=2),
            )
            self.on_artifact_row_selected()

        self.run_background_task(
            state="artifact check 실행 중",
            hint=f"{context.state.target_id} target-local check wrapper 또는 fallback 검증을 수행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="artifact check 실행 완료",
            success_hint="검증 결과 JSON과 실행 경로를 출력했습니다.",
            failure_state="artifact check 실행 실패",
            failure_hint="선택한 summary/zip 경로, target wrapper 경로, RunRoot 계약을 확인하세요.",
            on_failure=on_failure,
        )

    def import_selected_external_artifact(self) -> None:
        context = self._selected_artifact_action_context()
        if context is None:
            return
        selected_sources = self._prompt_external_artifact_sources(context.state)
        if selected_sources is None:
            return
        sources = ArtifactSourceSelection(*selected_sources)
        self._remember_artifact_sources(context.state.target_id, sources.summary_path, sources.review_zip_path)
        if not self._confirm_recent_submit_repeat(context.state.target_id):
            return

        check_plan = self._build_artifact_action_command(
            state=context.state,
            config_path=context.config_path,
            run_root=context.run_root,
            wrapper_key="CheckScriptPath",
            fallback_script_name="check-paired-exchange-artifact.ps1",
            extra=[
                "-SummarySourcePath",
                sources.summary_path,
                "-ReviewZipSourcePath",
                sources.review_zip_path,
                "-AsJson",
            ],
        )
        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(list(check_plan.command))

        def on_failure(exc: Exception) -> None:
            self._record_artifact_action_result(
                action="submit-preflight",
                status="failed",
                context=context,
                sources=sources,
                plan=check_plan,
                error=str(exc),
            )

        def on_success(completed: subprocess.CompletedProcess[str]):
            check_payload = json.loads(completed.stdout)
            preflight_text = self._format_external_artifact_preflight(check_payload)
            validation = check_payload.get("Validation", {}) or {}
            preflight = check_payload.get("Preflight", {}) or {}
            current_target = check_payload.get("PreImportStatus", {}) or {}
            requires_overwrite = bool(validation.get("RequiresOverwrite", False))
            latest_state = str(preflight.get("CurrentLatestState", "") or current_target.get("LatestState", "") or "")
            latest_zip_path = str(preflight.get("DestinationZipPath", "") or "")
            preflight_header_lines = [
                "artifact submit 사전검사",
                f"check 실행 경로: {check_plan.execution_path}",
                f"target-local wrapper 사용: {'예' if check_plan.used_wrapper else '아니오 (root fallback)'}",
                f"wrapper 경로 출처: {check_plan.contract_paths.get('Source', '') or '(없음)'}",
            ]
            if not check_plan.used_wrapper:
                preflight_header_lines.append("LEGACY FALLBACK WARNING: target-local wrapper 없이 root fallback check를 사용했습니다.")
            if context.run_root_is_stale:
                preflight_header_lines.append("주의: 현재 선택된 RunRoot가 stale 표시입니다. 새 wrapper가 없는 예전 run일 수 있습니다.")
            self.set_text(
                self.output_text,
                "\n".join(preflight_header_lines) + "\n\n" + preflight_text + "\n\nJSON\n" + json.dumps(check_payload, ensure_ascii=False, indent=2),
            )

            if not bool(validation.get("Ok", False)):
                self._record_artifact_action_result(
                    action="submit-preflight",
                    status="blocked",
                    context=context,
                    sources=sources,
                    plan=check_plan,
                    requires_overwrite=requires_overwrite,
                    latest_state=latest_state,
                    latest_zip_path=latest_zip_path,
                )
                messagebox.showwarning("외부 artifact import 차단", "입력 artifact 검증에 실패했습니다. output 영역의 preflight 결과를 먼저 확인하세요.", parent=self)
                return None

            self._record_artifact_action_result(
                action="submit-preflight",
                status="success",
                context=context,
                sources=sources,
                plan=check_plan,
                requires_overwrite=requires_overwrite,
                latest_state=latest_state,
                latest_zip_path=latest_zip_path,
            )

            confirm_lines = [
                f"target: {context.state.target_id}",
                f"source summary: {sources.summary_path}",
                f"source zip: {sources.review_zip_path}",
                f"check 실행 경로: {check_plan.execution_path}",
                f"wrapper 사용: {'예' if check_plan.used_wrapper else '아니오 (root fallback)'}",
                "",
                preflight_text,
                "",
                "현재 RunRoot target folder 계약으로 summary.txt, review zip, done.json, result.json을 기록할까요?",
            ]
            if context.run_root_is_stale:
                confirm_lines.append("주의: 선택된 RunRoot가 stale 표시입니다. 새 RunRoot로 다시 준비한 wrapper가 아닐 수 있습니다.")
            if requires_overwrite:
                confirm_lines.append("이 import는 기존 contract 파일 또는 현재 성공 상태를 덮어씁니다. 계속하려면 overwrite를 명시적으로 승인해야 합니다.")

            confirmed = messagebox.askyesno(
                "외부 artifact import" if not requires_overwrite else "외부 artifact import (overwrite)",
                "\n".join(confirm_lines),
                parent=self,
            )
            if not confirmed:
                self._record_artifact_action_result(
                    action="submit-preflight",
                    status="cancelled",
                    context=context,
                    sources=sources,
                    plan=check_plan,
                    requires_overwrite=requires_overwrite,
                    latest_state=latest_state,
                    latest_zip_path=latest_zip_path,
                )
                return None

            extra = [
                "-SummarySourcePath",
                sources.summary_path,
                "-ReviewZipSourcePath",
                sources.review_zip_path,
                "-AsJson",
            ]
            if requires_overwrite:
                extra.append("-Overwrite")

            submit_plan = self._build_artifact_action_command(
                state=context.state,
                config_path=context.config_path,
                run_root=context.run_root,
                wrapper_key="SubmitScriptPath",
                fallback_script_name="import-paired-exchange-artifact.ps1",
                extra=extra,
            )
            if not submit_plan.used_wrapper:
                fallback_confirmed = messagebox.askyesno(
                    "legacy fallback submit 확인",
                    "\n".join(
                        [
                            f"{context.state.target_id} submit이 target-local wrapper 없이 legacy fallback 경로로 실행됩니다.",
                            f"실행 경로: {submit_plan.execution_path}",
                            f"wrapper 경로 출처: {submit_plan.contract_paths.get('Source', '') or '(없음)'}",
                            "이 경로는 예전 RunRoot 호환용입니다. 새 RunRoot를 다시 준비하지 않았다면 혼선 가능성이 큽니다.",
                            "",
                            "정말 fallback submit을 계속할까요?",
                        ]
                    ),
                    parent=self,
                )
                if not fallback_confirmed:
                    self._record_artifact_action_result(
                        action="submit-preflight",
                        status="cancelled",
                        context=context,
                        sources=sources,
                        plan=check_plan,
                        requires_overwrite=requires_overwrite,
                        latest_state=latest_state,
                        latest_zip_path=latest_zip_path,
                    )
                    return None

            if not self._begin_submit_action(context.state.target_id):
                self._record_artifact_action_result(
                    action="submit-preflight",
                    status="blocked",
                    context=context,
                    sources=sources,
                    plan=check_plan,
                    requires_overwrite=requires_overwrite,
                    latest_state=latest_state,
                    latest_zip_path=latest_zip_path,
                )
                messagebox.showwarning("submit 진행 중", f"{context.state.target_id} submit이 이미 진행 중입니다.", parent=self)
                return None

            launch_request = ArtifactSubmitLaunchRequest(
                preflight=ArtifactSubmitPreflight(
                    context=context,
                    sources=sources,
                    check_plan=check_plan,
                    payload=check_payload,
                    preflight_text=preflight_text,
                    requires_overwrite=requires_overwrite,
                    latest_state=latest_state,
                    latest_zip_path=latest_zip_path,
                ),
                submit_plan=submit_plan,
            )
            return lambda request=launch_request: self._execute_artifact_submit(request)

        self.run_background_task(
            state="artifact submit 사전검사 중",
            hint=f"{context.state.target_id} submit 전 target-local check wrapper 또는 fallback 검증을 수행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="artifact submit 사전검사 완료",
            success_hint="preflight 결과를 확인한 뒤 submit을 이어서 실행할 수 있습니다.",
            failure_state="artifact submit 사전검사 실패",
            failure_hint="summary/zip 경로, target wrapper 경로, RunRoot target 계약을 확인하세요.",
            on_failure=on_failure,
        )

    def _execute_artifact_submit(self, request: ArtifactSubmitLaunchRequest) -> None:
        context = request.preflight.context
        sources = request.preflight.sources
        submit_plan = request.submit_plan
        requires_overwrite = request.preflight.requires_overwrite
        self._record_artifact_action_result(
            action="submit",
            status="running",
            context=context,
            sources=sources,
            plan=submit_plan,
            requires_overwrite=requires_overwrite,
            latest_state=request.preflight.latest_state,
            latest_zip_path=request.preflight.latest_zip_path,
        )
        self.last_command_var.set(subprocess.list2cmdline(list(submit_plan.command)))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(list(submit_plan.command))

        def on_failure(exc: Exception) -> None:
            self._record_artifact_action_result(
                action="submit",
                status="failed",
                context=context,
                sources=sources,
                plan=submit_plan,
                requires_overwrite=requires_overwrite,
                latest_state=request.preflight.latest_state,
                latest_zip_path=request.preflight.latest_zip_path,
                error=str(exc),
            )
            self._finish_submit_action(context.state.target_id)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            try:
                payload = json.loads(completed.stdout)
                preflight_text = self._format_external_artifact_preflight(payload)
                post_import_status = payload.get("PostImportStatus", {}) or {}
                contract = payload.get("Contract", {}) or {}
                latest_state = str(post_import_status.get("LatestState", "") or "")
                latest_zip_path = str(contract.get("DestinationZipPath", "") or contract.get("LatestZipPath", "") or "")
                self._record_artifact_action_result(
                    action="submit",
                    status="success",
                    context=context,
                    sources=sources,
                    plan=submit_plan,
                    requires_overwrite=requires_overwrite,
                    latest_state=latest_state,
                    latest_zip_path=latest_zip_path,
                )
                header_lines = [
                    "artifact submit 실행",
                    f"submit 실행 경로: {submit_plan.execution_path}",
                    f"target-local wrapper 사용: {'예' if submit_plan.used_wrapper else '아니오 (root fallback)'}",
                    f"wrapper 경로 출처: {submit_plan.contract_paths.get('Source', '') or '(없음)'}",
                ]
                if not submit_plan.used_wrapper:
                    header_lines.append("LEGACY FALLBACK WARNING: target-local wrapper 없이 root fallback submit을 사용했습니다.")
                if context.run_root_is_stale:
                    header_lines.append("주의: 현재 선택된 RunRoot가 stale 표시입니다. 새 RunRoot로 다시 준비한 wrapper가 아닐 수 있습니다.")
                header_lines.extend(
                    [
                        f"RequiresOverwrite: {requires_overwrite}",
                        f"계약 LatestState: {latest_state or '(없음)'}",
                        f"LatestZipPath: {latest_zip_path or '(없음)'}",
                    ]
                )
                self.set_text(
                    self.output_text,
                    "\n".join(header_lines) + "\n\n" + preflight_text + "\n\nJSON\n" + json.dumps(payload, ensure_ascii=False, indent=2),
                )
                self.refresh_paired_status_only()
                self.on_artifact_row_selected()
            finally:
                self._finish_submit_action(context.state.target_id)

        self.run_background_task(
            state="artifact submit 실행 중",
            hint=f"{context.state.target_id} target-local submit wrapper 또는 fallback import를 실행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="artifact submit 실행 완료",
            success_hint="paired status와 결과 탭을 새 산출물 기준으로 다시 읽었습니다.",
            failure_state="artifact submit 실행 실패",
            failure_hint="summary/zip 경로, target wrapper 경로, RunRoot target 계약을 확인하세요.",
            on_failure=on_failure,
        )

    def on_home_pair_selected(self, _event: object | None = None) -> None:
        summary = self._selected_pair_summary()
        self._apply_home_pair_tree_highlights()
        if self._artifact_home_browse_pair_scope_enabled():
            self._sync_artifact_filters_with_home_pair_selection(refresh=self._has_ui_attr("artifact_tree"))
        self._apply_artifact_tree_highlights()
        if not summary:
            self.home_pair_detail_var.set(self._home_pair_detail_text(summary))
            return
        self.home_pair_detail_var.set(self._home_pair_detail_text(summary))
        self.update_pair_button_states()

    def apply_selected_home_pair(self) -> None:
        pair_id = self._selected_home_pair_id()
        top_target_id = self._resolve_top_target_for_pair(pair_id)
        self._set_action_context(
            pair_id=pair_id,
            target_id=top_target_id if top_target_id else self.target_id_var.get().strip(),
            source="home-pair-apply",
        )
        self._sync_home_pair_selection(pair_id)
        self._sync_pair_scoped_views_with_action_context(refresh_artifacts=True)
        self.render_target_board()
        self.update_pair_button_states()
        self.rebuild_panel_state()
        self.set_text(self.output_text, f"선택 Pair 반영 완료:\n{pair_id}")

    def apply_selected_inspection_context(self) -> None:
        inspection_context = self._selected_inspection_context_state()
        pair_id = inspection_context.pair_id
        target_id = inspection_context.target_id
        if not pair_id and not target_id:
            messagebox.showwarning("선택 필요", "반영할 preview row 또는 board target을 먼저 선택하세요.")
            return
        resolved_target = target_id
        if target_id:
            resolved_target = target_id
        elif pair_id:
            resolved_target = self._resolve_top_target_for_pair(pair_id)
        self._set_action_context(
            pair_id=pair_id if pair_id else None,
            target_id=resolved_target if resolved_target else None,
            source="inspection-apply",
        )
        self._sync_home_pair_selection(self._selected_pair_id())
        self._sync_pair_scoped_views_with_action_context(refresh_artifacts=True)
        self.render_target_board()
        self.update_pair_button_states()
        self.rebuild_panel_state()
        self.set_text(
            self.output_text,
            "inspection 실행 기준 반영 완료:\nPair={0}\nTarget={1}".format(
                self._selected_pair_id(),
                self.target_id_var.get().strip() or "(없음)",
            ),
        )

    def rebuild_panel_state(self) -> None:
        if not self.effective_data or not self.relay_status_data or not self.visibility_status_data:
            return
        effective_data = dict(self.effective_data)
        effective_data["PanelRuntimeHints"] = self._panel_runtime_hints()
        bundle = DashboardRawBundle(
            effective_data=effective_data,
            relay_status=self.relay_status_data,
            visibility_status=self.visibility_status_data,
            paired_status=self.paired_status_data,
            paired_status_error=self.paired_status_error,
        )
        self.panel_state = self.dashboard_aggregator.build_panel_state(
            bundle=bundle,
            selected_pair=self._selected_pair_id(),
        )
        self.render_home_dashboard()
        self._refresh_sticky_context_bar()

    def run_script(
        self,
        script_name: str,
        *,
        extra: list[str] | None = None,
        run_root_override: str | None = None,
        pair_id_override: str | None = None,
        target_id_override: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        context = self._current_context()
        command = self.command_service.build_script_command(
            script_name=script_name,
            config_path=context.config_path,
            run_root=context.run_root if run_root_override is None else run_root_override,
            pair_id=context.pair_id if pair_id_override is None else pair_id_override,
            target_id=context.target_id if target_id_override is None else target_id_override,
            extra=extra,
        )
        self.last_command_var.set(subprocess.list2cmdline(command))
        return self.status_service.run_script(
            script_name,
            context,
            extra=extra,
            run_root_override=run_root_override,
            pair_id_override=pair_id_override,
            target_id_override=target_id_override,
        )

    def run_json_script(
        self,
        script_name: str,
        *,
        extra: list[str] | None = None,
        run_root_override: str | None = None,
        pair_id_override: str | None = None,
        target_id_override: str | None = None,
    ) -> dict:
        context = self._current_context()
        command = self.command_service.build_script_command(
            script_name=script_name,
            config_path=context.config_path,
            run_root=context.run_root if run_root_override is None else run_root_override,
            pair_id=context.pair_id if pair_id_override is None else pair_id_override,
            target_id=context.target_id if target_id_override is None else target_id_override,
            extra=extra,
        )
        self.last_command_var.set(subprocess.list2cmdline(command))
        return self.status_service.run_json_script(
            script_name,
            context,
            extra=extra,
            run_root_override=run_root_override,
            pair_id_override=pair_id_override,
            target_id_override=target_id_override,
        )

    def load_effective_config(self) -> None:
        prior_override_state = self._run_root_override_state()
        try:
            bundle = self.refresh_controller.refresh_full(self._effective_refresh_context())
        except Exception as exc:
            messagebox.showerror("불러오기 실패", str(exc))
            self.set_operator_status("불러오기 실패", "상태 JSON 수집에 실패했습니다.", f"마지막 결과: 실패 ({exc})")
            return

        effective_payload = bundle.effective_data
        relay_payload = bundle.relay_status
        visibility_payload = bundle.visibility_status
        paired_payload = bundle.paired_status
        paired_error = bundle.paired_status_error
        selected_run_root = effective_payload.get("RunContext", {}).get("SelectedRunRoot", "") or ""

        self.effective_data = effective_payload
        self.relay_status_data = relay_payload
        self.visibility_status_data = visibility_payload
        self.paired_status_data = paired_payload
        self.paired_status_error = paired_error
        self.preview_rows = list(effective_payload.get("PreviewRows", []))

        if prior_override_state != "override-active":
            run_root_source = effective_payload.get("RunContext", {}).get("SelectedRunRootSource", "") or ""
            if selected_run_root and run_root_source != "next-preview":
                self.run_root_var.set(selected_run_root)
            else:
                self.run_root_var.set("")
        self._update_run_root_controls()

        self.render_summary(effective_payload)
        self.render_rows(self.preview_rows)
        self.__dict__["_pair_policy_refresh_auto_preview"] = True
        self.refresh_pair_policy_editor()
        self._coerce_selected_pair_into_runtime_scope()
        self._sync_message_scope_id_from_context()
        self._refresh_watcher_notes()
        if self.message_config_doc is None:
            self.load_message_editor_document()
        else:
            self.render_message_editor()
        self.render_target_board()
        self.rebuild_panel_state()
        self.refresh_artifacts_tab()

        selected_target = self._selected_inspection_target_id() or self.target_id_var.get().strip()
        selected_pair = self._selected_inspection_pair_id() or self._selected_pair_id()
        if self.preview_rows and not self._sync_preview_selection_with_pair(selected_pair, target_id=selected_target):
            first = self.row_tree.get_children()[0]
            self.row_tree.selection_set(first)
            self.on_row_selected()
        elif not self.preview_rows:
            self._set_inspection_context(source="")
            self.clear_details()

        self.refresh_snapshot_list()
        self.update_pair_button_states()
        result_text = "마지막 결과: 전체 새로고침 완료"
        if paired_error:
            result_text += " / pair-status 일부 생략"
        self.set_operator_status("전체 상태 불러옴", "홈 탭에서 준비 단계와 pair 요약을 바로 확인할 수 있습니다.", result_text)

    def render_summary(self, payload: dict) -> None:
        config = payload.get("Config", {})
        run_context = payload.get("RunContext", {})
        pair_test = payload.get("PairTest", {})
        dispatch = payload.get("Dispatch", {})
        run_root_override = str(self.run_root_var.get() or "").strip()
        run_root_override_state = self._run_root_override_state()
        allowed_window_visibility_methods = pair_test.get("AllowedWindowVisibilityMethods", []) or []
        submit_retry_modes = dispatch.get("SubmitRetryModes", []) or pair_test.get("SubmitRetryModes", []) or []
        lines = [
            "읽기 전용 보기 도구입니다. source of truth는 show-effective-config.ps1 JSON 출력입니다.",
            f"스키마 버전: {payload.get('SchemaVersion', '')}",
            f"생성 시각: {payload.get('GeneratedAt', '')}",
            f"Lane: {config.get('LaneName', '')}",
            f"설정 경로: {config.get('ConfigPath', '')}",
            f"설정 해시: {config.get('ConfigHash', '')}",
            f"창 제목 prefix: {config.get('WindowTitlePrefix', '')}",
            f"바인딩 프로필: {config.get('BindingProfilePath', '')}",
            f"런처 래퍼: {config.get('LauncherWrapperPath', '')}",
            f"선택된 RunRoot: {run_context.get('SelectedRunRoot', '')} ({run_context.get('SelectedRunRootSource', '')})",
            f"선택된 RunRoot 마지막 수정: {run_context.get('SelectedRunRootLastWriteAt', '')}",
            f"선택된 RunRoot 경과 초: {run_context.get('SelectedRunRootAgeSeconds', '')}",
            f"선택된 RunRoot stale 여부: {run_context.get('SelectedRunRootIsStale', False)}",
            f"stale 기준 초: {run_context.get('StaleRunThresholdSec', '')}",
            f"최신 existing run: {run_context.get('LatestExistingRunRoot', '')}",
            f"다음 RunRoot 미리보기: {run_context.get('NextRunRootPreview', '')}",
            f"패널 RunRoot Override 입력: {run_root_override or '(비어 있음)'}",
            f"패널 RunRoot Override 상태: {run_root_override_state}",
            f"manifest 경로: {run_context.get('ManifestPath', '')}",
            f"Pair 정의 출처: {payload.get('PairDefinitionSource', '')}",
            f"Pair 정의 출처 상세: {payload.get('PairDefinitionSourceDetail', '')}",
            f"Pair topology 전략: {payload.get('PairTopologyStrategy', '')}",
            f"기본 Pair Id: {pair_test.get('DefaultPairId', '')}",
            f"최고 경고 심각도: {payload.get('WarningSummary', {}).get('HighestSeverity', '')}",
            f"최고 경고 판단: {payload.get('WarningSummary', {}).get('HighestDecision', '')}",
            f"최고 경고 코드: {payload.get('WarningSummary', {}).get('HighestCode', '')}",
            f"운영 증거 저장 권장: {payload.get('EvidencePolicy', {}).get('Recommended', False)}",
            f"운영 증거 저장 루트: {payload.get('EvidencePolicy', {}).get('EvidenceSnapshotRoot', '')}",
            "",
            f"summary 파일명: {pair_test.get('SummaryFileName', '')}",
            f"검토 폴더명: {pair_test.get('ReviewFolderName', '')}",
            f"메시지 폴더명: {pair_test.get('MessageFolderName', '')}",
            f"검토 zip 패턴: {pair_test.get('ReviewZipPattern', '')}",
            f"실행 경로: {pair_test.get('ExecutionPathMode', '')}",
            f"visible cell 실행 강제: {pair_test.get('RequireUserVisibleCellExecution', False)}",
            f"허용 visibility 방법: {', '.join(str(item) for item in allowed_window_visibility_methods) or '(없음)'}",
            f"submit sequence: {dispatch.get('SubmitRetrySequenceSummary', '') or ' -> '.join(str(item) for item in submit_retry_modes) or '(없음)'}",
            f"submit primary/final: {dispatch.get('PrimarySubmitMode', '') or '(없음)'} / {dispatch.get('FinalSubmitMode', '') or '(없음)'}",
            f"submit retry interval ms: {dispatch.get('SubmitRetryIntervalMs', '')}",
            f"Headless 사용 가능: {pair_test.get('HeadlessExec', {}).get('Enabled', False)}",
            f"Headless Codex 실행파일: {pair_test.get('HeadlessExec', {}).get('CodexExecutable', '')}",
            f"미리보기 스냅샷 루트: {payload.get('EvidencePolicy', {}).get('TemporarySnapshotRoot', '')}",
        ]
        lines.append("")
        lines.append("Pair 활성 상태:")
        for item in payload.get("PairActivationSummary", []):
            lines.append(
                "- {pair}: {state} / enabled={enabled} / reason={reason}".format(
                    pair=item.get("PairId", ""),
                    state=item.get("State", ""),
                    enabled=item.get("EffectiveEnabled", False),
                    reason=item.get("DisableReason", "") or "(none)",
                )
            )
        lines.append("")
        lines.append("Pair repo/path 정책:")
        for pair in payload.get("OverviewPairs", []):
            policy = pair.get("Policy", {}) or {}
            lines.append(
                "- {pair}: seed={seed} / repo={repo} / repo-source={source} / external-runroot={runroot} / external-contract={contract}".format(
                    pair=pair.get("PairId", "") or "",
                    seed=pair.get("SeedTargetId", "") or "(없음)",
                    repo=policy.get("DefaultSeedWorkRepoRoot", "") or "(없음)",
                    source=policy.get("DefaultSeedWorkRepoRootSource", "") or "unset",
                    runroot=policy.get("UseExternalWorkRepoRunRoot", False),
                    contract=policy.get("UseExternalWorkRepoContractPaths", False),
                )
            )
        warnings = payload.get("Warnings", [])
        warning_details = payload.get("WarningDetails", [])
        requested_filters = payload.get("RequestedFilters", {})
        lines.append("")
        lines.append(f"요청 Pair 필터: {', '.join(requested_filters.get('PairIds', [])) or '(none)'}")
        lines.append(f"요청 대상 필터: {requested_filters.get('TargetId', '') or '(none)'}")
        lines.append(f"요청 모드: {requested_filters.get('Mode', '')}")
        lines.append("패널 저장 정책: 미리보기 스냅샷만 저장합니다. 운영 증거 저장은 save-effective-config-evidence.ps1를 사용하세요.")
        lines.append("")
        lines.append("경고:")
        if warning_details:
            lines.extend([f"- [{item.get('Severity', 'info')}] {item.get('Code', '')}: {item.get('Message', '')}" for item in warning_details])
        elif warnings:
            lines.extend([f"- {item}" for item in warnings])
        else:
            lines.append("(없음)")
        self.set_text(self.summary_text, "\n".join(lines))

    def render_rows(self, rows: list[dict]) -> None:
        for item in self.row_tree.get_children():
            self.row_tree.delete(item)
        for index, row in enumerate(rows):
            target_status = self._paired_target_status_row(str(row.get("TargetId", "") or ""))
            self.row_tree.insert(
                "",
                "end",
                iid=str(index),
                values=(
                    row.get("PairId", ""),
                    row.get("RoleName", ""),
                    row.get("TargetId", ""),
                    row.get("PartnerTargetId", ""),
                    self._source_outbox_preview_summary(row, target_status=target_status),
                ),
            )

    def _normalized_optional_path(self, value: object) -> str:
        text = str(value or "").strip()
        if not text:
            return ""
        try:
            return os.path.normcase(os.path.normpath(text))
        except Exception:
            return text.casefold()

    def _pair_route_state(
        self,
        *,
        targets_share_work_repo_root: bool,
        targets_share_pair_run_root: bool,
        target_outboxes_distinct: bool,
    ) -> str:
        if not targets_share_work_repo_root:
            return "mismatched-workrepo"
        if not targets_share_pair_run_root:
            return "mismatched-pair-runroot"
        if not target_outboxes_distinct:
            return "outbox-collision-risk"
        return "aligned"

    def _build_pair_route_snapshot(self, pair_id: str) -> dict[str, object]:
        pair_rows = [
            row
            for row in self._pair_policy_route_rows()
            if str(row.get("PairId", "") or "").strip() == str(pair_id or "").strip()
        ]
        if not pair_rows:
            return {}

        top_row = next((row for row in pair_rows if str(row.get("RoleName", "") or "").strip() == "top"), pair_rows[0])
        bottom_row = next(
            (row for row in pair_rows if str(row.get("RoleName", "") or "").strip() == "bottom"),
            next((row for row in pair_rows if row is not top_row), {}),
        )

        def unique_non_empty(values: list[str]) -> list[str]:
            result: list[str] = []
            seen: set[str] = set()
            for item in values:
                text = str(item or "").strip()
                if not text:
                    continue
                key = self._normalized_optional_path(text) or text.casefold()
                if key in seen:
                    continue
                seen.add(key)
                result.append(text)
            return result

        work_repo_values = [str(row.get("WorkRepoRoot", "") or "").strip() for row in pair_rows]
        pair_run_root_values = []
        for row in pair_rows:
            pair_run_root = str(row.get("PairRunRoot", "") or "").strip()
            if not pair_run_root:
                target_folder = str(row.get("PairTargetFolder", "") or "").strip()
                if target_folder:
                    pair_run_root = os.path.dirname(target_folder)
            pair_run_root_values.append(pair_run_root)
        outbox_values = [str(row.get("SourceOutboxPath", "") or "").strip() for row in pair_rows]

        work_repo_roots = unique_non_empty(work_repo_values)
        pair_run_roots = unique_non_empty(pair_run_root_values)
        source_outboxes = unique_non_empty(outbox_values)

        pair_work_repo_root = work_repo_roots[0] if len(work_repo_roots) == 1 else ""
        pair_run_root = pair_run_roots[0] if len(pair_run_roots) == 1 else ""
        targets_share_work_repo_root = len(work_repo_roots) == 1
        targets_share_pair_run_root = len(pair_run_roots) == 1
        target_outboxes_distinct = len(source_outboxes) == len(pair_rows)

        shares_work_repo_root_with_other_pairs = False
        if pair_work_repo_root:
            normalized_repo = self._normalized_optional_path(pair_work_repo_root)
            for other_row in self.preview_rows:
                other_pair_id = str(other_row.get("PairId", "") or "").strip()
                if not other_pair_id or other_pair_id == pair_id:
                    continue
                other_repo = str(other_row.get("WorkRepoRoot", "") or "").strip()
                if other_repo and self._normalized_optional_path(other_repo) == normalized_repo:
                    shares_work_repo_root_with_other_pairs = True
                    break

        return {
            "PairId": str(pair_id or "").strip(),
            "TopTargetId": str(top_row.get("TargetId", "") or "").strip(),
            "BottomTargetId": str(bottom_row.get("TargetId", "") or "").strip(),
            "PairWorkRepoRoot": pair_work_repo_root,
            "PairRunRoot": pair_run_root,
            "TopSourceOutboxPath": str(top_row.get("SourceOutboxPath", "") or "").strip(),
            "BottomSourceOutboxPath": str(bottom_row.get("SourceOutboxPath", "") or "").strip(),
            "TopPublishReadyPath": str(top_row.get("PublishReadyPath", "") or "").strip(),
            "BottomPublishReadyPath": str(bottom_row.get("PublishReadyPath", "") or "").strip(),
            "TargetsShareWorkRepoRoot": targets_share_work_repo_root,
            "TargetsSharePairRunRoot": targets_share_pair_run_root,
            "TargetOutboxesDistinct": target_outboxes_distinct,
            "SharesWorkRepoRootWithOtherPairs": shares_work_repo_root_with_other_pairs,
            "RouteState": self._pair_route_state(
                targets_share_work_repo_root=targets_share_work_repo_root,
                targets_share_pair_run_root=targets_share_pair_run_root,
                target_outboxes_distinct=target_outboxes_distinct,
            ),
        }

    def on_row_selected(self, _event: object | None = None, *, source: str = "preview-row") -> None:
        selection = self.row_tree.selection()
        if not selection:
            self.clear_details()
            self._refresh_sticky_context_bar()
            return
        row = self.preview_rows[int(selection[0])]
        self._set_inspection_context(
            pair_id=str(row.get("PairId", "") or ""),
            target_id=str(row.get("TargetId", "") or ""),
            source=source,
            row_index=int(selection[0]),
        )
        self._sync_message_scope_id_from_context()
        self.render_target_board()
        self.render_message_editor()
        inspection_context = self._selected_inspection_context_state()
        activation = row.get("PairActivation", {}) or {}
        action_pair = self._selected_pair_id()
        action_target = self.target_id_var.get().strip()
        allowed_window_visibility_methods = row.get("AllowedWindowVisibilityMethods", []) or []
        submit_retry_modes = row.get("SubmitRetryModes", []) or []
        pair_route = self._build_pair_route_snapshot(str(row.get("PairId", "") or ""))
        target_status = self._paired_target_status_row(str(row.get("TargetId", "") or ""))
        source_outbox_detail_lines = self._source_outbox_detail_lines(row, target_status=target_status)
        details_lines = [
            f"inspection source: {self._context_source_label(inspection_context.source)}",
            f"Pair: {row.get('PairId', '')}",
            f"역할: {row.get('RoleName', '')}",
            f"대상: {row.get('TargetId', '')}",
            f"상대: {row.get('PartnerTargetId', '')}",
            f"Pair 활성 상태: {activation.get('State', '')}",
            f"Pair 활성 여부: {activation.get('EffectiveEnabled', False)}",
            f"비활성 사유: {activation.get('DisableReason', '') or '(none)'}",
            f"비활성 만료시각: {activation.get('DisabledUntil', '') or '(none)'}",
            f"창 제목: {row.get('WindowTitle', '')}",
            f"Inbox 폴더: {row.get('InboxFolder', '')}",
            f"실행 경로: {row.get('ExecutionPathMode', '')}",
            f"visible cell 실행 강제: {row.get('UserVisibleCellExecutionRequired', False)}",
            f"허용 visibility 방법: {', '.join(str(item) for item in allowed_window_visibility_methods) or '(없음)'}",
            f"submit sequence: {row.get('SubmitRetrySequenceSummary', '') or ' -> '.join(str(item) for item in submit_retry_modes) or '(없음)'}",
            f"submit primary/final: {row.get('PrimarySubmitMode', '') or '(없음)'} / {row.get('FinalSubmitMode', '') or '(없음)'}",
            f"submit retry interval ms: {row.get('SubmitRetryIntervalMs', '')}",
            f"Pair 대상 폴더: {row.get('PairTargetFolder', '')}",
            f"상대 폴더: {row.get('PartnerFolder', '')}",
            f"summary 경로: {row.get('SummaryPath', '')}",
            f"검토 폴더: {row.get('ReviewFolderPath', '')}",
            f"source outbox: {row.get('SourceOutboxPath', '')}",
            f"source summary: {row.get('SourceSummaryPath', '')}",
            f"source review zip: {row.get('SourceReviewZipPath', '')}",
            f"publish ready: {row.get('PublishReadyPath', '')}",
            f"published archive: {row.get('PublishedArchivePath', '')}",
        ]
        if source_outbox_detail_lines:
            details_lines.extend([""] + source_outbox_detail_lines)
        details_lines.extend(
            [
                "",
                "[pair route snapshot]",
                f"route state: {pair_route.get('RouteState', '') or '(없음)'}",
                f"same pair work repo root: {pair_route.get('PairWorkRepoRoot', '') or '(없음)'}",
                f"same pair run root: {pair_route.get('PairRunRoot', '') or '(없음)'}",
                f"same pair targets share repo root: {pair_route.get('TargetsShareWorkRepoRoot', False)}",
                f"same pair targets share pair run root: {pair_route.get('TargetsSharePairRunRoot', False)}",
                f"same pair target outboxes distinct: {pair_route.get('TargetOutboxesDistinct', False)}",
                f"other pairs share this repo root: {pair_route.get('SharesWorkRepoRootWithOtherPairs', False)}",
                f"top source outbox: {pair_route.get('TopSourceOutboxPath', '') or '(없음)'}",
                f"bottom source outbox: {pair_route.get('BottomSourceOutboxPath', '') or '(없음)'}",
                f"top publish ready: {pair_route.get('TopPublishReadyPath', '') or '(없음)'}",
                f"bottom publish ready: {pair_route.get('BottomPublishReadyPath', '') or '(없음)'}",
                f"검토 zip 미리보기: {row.get('ReviewZipPreviewPath', '')}",
                f"초기 지시문 경로: {row.get('InitialInstructionPath', '')}",
                f"초기 메시지 경로: {row.get('InitialMessagePath', '')}",
                f"전달 메시지 패턴: {row.get('HandoffMessagePattern', '')}",
                f"request 경로: {row.get('RequestPath', '')}",
                f"prompt 경로: {row.get('PromptPath', '')}",
                f"done 경로: {row.get('DonePath', '')}",
                f"error 경로: {row.get('ErrorPath', '')}",
                f"result 경로: {row.get('ResultPath', '')}",
                f"work 폴더: {row.get('WorkFolderPath', '')}",
                f"check wrapper: {row.get('CheckScriptPath', '')}",
                f"submit wrapper: {row.get('SubmitScriptPath', '')}",
                f"check cmd: {row.get('CheckCmdPath', '')}",
                f"submit cmd: {row.get('SubmitCmdPath', '')}",
                "",
                "경로 존재 상태:",
                f"- Inbox 폴더: {self.format_path_state(row.get('PathState', {}).get('InboxFolder'))}",
                f"- Pair 대상 폴더: {self.format_path_state(row.get('PathState', {}).get('PairTargetFolder'))}",
                f"- 상대 폴더: {self.format_path_state(row.get('PathState', {}).get('PartnerFolder'))}",
                f"- summary: {self.format_path_state(row.get('PathState', {}).get('Summary'))}",
                f"- 검토 폴더: {self.format_path_state(row.get('PathState', {}).get('ReviewFolder'))}",
                f"- work 폴더: {self.format_path_state(row.get('PathState', {}).get('WorkFolder'))}",
                f"- source outbox: {self.format_path_state(row.get('PathState', {}).get('SourceOutbox'))}",
                f"- source summary: {self.format_path_state(row.get('PathState', {}).get('SourceSummary'))}",
                f"- source review zip: {self.format_path_state(row.get('PathState', {}).get('SourceReviewZip'))}",
                f"- publish ready: {self.format_path_state(row.get('PathState', {}).get('PublishReady'))}",
                f"- published archive: {self.format_path_state(row.get('PathState', {}).get('PublishedArchive'))}",
                f"- 초기 지시문: {self.format_path_state(row.get('PathState', {}).get('InitialInstruction'))}",
                f"- 초기 메시지: {self.format_path_state(row.get('PathState', {}).get('InitialMessage'))}",
                f"- request: {self.format_path_state(row.get('PathState', {}).get('Request'))}",
                f"- prompt: {self.format_path_state(row.get('PathState', {}).get('Prompt'))}",
                f"- done: {self.format_path_state(row.get('PathState', {}).get('Done'))}",
                f"- error: {self.format_path_state(row.get('PathState', {}).get('Error'))}",
                f"- result: {self.format_path_state(row.get('PathState', {}).get('Result'))}",
                f"- check wrapper: {self.format_path_state(row.get('PathState', {}).get('CheckScript'))}",
                f"- submit wrapper: {self.format_path_state(row.get('PathState', {}).get('SubmitScript'))}",
                f"- check cmd: {self.format_path_state(row.get('PathState', {}).get('CheckCmd'))}",
                f"- submit cmd: {self.format_path_state(row.get('PathState', {}).get('SubmitCmd'))}",
                "",
                "초기 override 출처: " + ", ".join(row.get("Initial", {}).get("AppliedSources", [])),
                "전달 override 출처: " + ", ".join(row.get("Handoff", {}).get("AppliedSources", [])),
            ]
        )
        if self._inspection_context_differs_from_action():
            details_lines = [
                "inspection 선택만 바뀌었습니다. 현재 실행 Pair/Target은 유지 중입니다.",
                f"실행 Pair: {action_pair or '(없음)'}",
                f"실행 Target: {action_target or '(없음)'}",
                "이 row로 실행하려면 '선택 row 실행 기준 반영' 또는 '선택 target 반영'을 누르세요.",
                "",
            ] + details_lines
        self.set_text(self.details_text, "\n".join(details_lines))
        self.set_text(self.initial_text, row.get("Initial", {}).get("Preview", ""))
        self.set_text(self.handoff_text, row.get("Handoff", {}).get("Preview", ""))
        plan_lines = [
            "초기 문구 조합 순서:",
            self.format_message_plan(row.get("Initial", {}).get("MessagePlan")),
            "",
            "전달 문구 조합 순서:",
            self.format_message_plan(row.get("Handoff", {}).get("MessagePlan")),
        ]
        self.set_text(self.plan_text, "\n".join(plan_lines))
        one_time_lines = [
            f"큐 경로: {row.get('OneTimeQueue', {}).get('QueuePath', '')}",
            "",
            "초기 문구 대기 항목:",
            self.format_one_time_items(row.get("Initial", {}).get("PendingOneTimeItems", [])),
            "",
            "전달 문구 대기 항목:",
            self.format_one_time_items(row.get("Handoff", {}).get("PendingOneTimeItems", [])),
        ]
        self.set_text(self.one_time_text, "\n".join(one_time_lines))
        if self._artifact_home_browse_target_scope_enabled():
            self._sync_artifact_filters_with_home_pair_selection(refresh=self._has_ui_attr("artifact_tree"))
        self._refresh_sticky_context_bar()

    def clear_details(self) -> None:
        self.set_text(self.details_text, "")
        self.set_text(self.initial_text, "")
        self.set_text(self.handoff_text, "")
        self.set_text(self.plan_text, "")
        self.set_text(self.one_time_text, "")
        self._refresh_sticky_context_bar()

    def format_path_state(self, state: dict | None) -> str:
        if not state:
            return "(없음)"
        exists = "있음" if state.get("Exists", False) else "없음"
        last_write = state.get("LastWriteAt", "") or "-"
        return f"{exists} / 마지막 수정: {last_write}"

    def format_message_plan(self, plan: dict | None) -> str:
        if not plan:
            return "(없음)"

        lines: list[str] = []
        for item in plan.get("Blocks", []):
            order = item.get("Order", "")
            slot = item.get("Slot", "")
            source_kind = item.get("SourceKind", "")
            source_id = item.get("SourceId", "")
            text = item.get("Text", "")
            preview = text.strip().replace("\r", " ").replace("\n", " ")
            if len(preview) > 80:
                preview = preview[:77] + "..."
            lines.append(f"{order}. [{slot}] {source_kind}/{source_id} :: {preview}")
        return "\n".join(lines) if lines else "(없음)"

    def format_one_time_items(self, items: list[dict] | None) -> str:
        if not items:
            return "(없음)"

        lines: list[str] = []
        for item in items:
            scope = item.get("Scope", {}) or {}
            lines.append(
                "- {id} / {placement} / state={state} / applies_to={applies} / role={role} / target={target}\n  {text}".format(
                    id=item.get("Id", ""),
                    placement=item.get("Placement", ""),
                    state=item.get("State", ""),
                    applies=scope.get("AppliesTo", ""),
                    role=scope.get("Role") or "(all)",
                    target=scope.get("TargetId") or "(all)",
                    text=item.get("Text", ""),
                )
            )
        return "\n".join(lines)

    def _load_snapshot_row(self, path: Path) -> dict:
        stat = path.stat()
        modified = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
        row = {
            "Path": path,
            "Name": path.name,
            "Modified": modified,
            "SizeText": f"{stat.st_size:,}",
            "Lane": "",
            "GeneratedAt": "",
            "SelectedRunRoot": "",
            "SelectedRunRootSource": "",
            "SelectedRunRootIsStale": False,
            "WarningCount": 0,
            "WarningLines": [],
            "LoadError": "",
        }
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            run_context = payload.get("RunContext", {})
            config = payload.get("Config", {})
            warning_details = payload.get("WarningDetails", [])
            warning_lines = []
            for item in warning_details:
                warning_lines.append(f"- [{item.get('Severity', 'info')}] {item.get('Code', '')}: {item.get('Message', '')}")
            if not warning_lines:
                warning_lines = [f"- {item}" for item in payload.get("Warnings", [])]

            row.update(
                {
                    "Lane": config.get("LaneName", ""),
                    "GeneratedAt": payload.get("GeneratedAt", ""),
                    "SelectedRunRoot": run_context.get("SelectedRunRoot", ""),
                    "SelectedRunRootSource": run_context.get("SelectedRunRootSource", ""),
                    "SelectedRunRootIsStale": bool(run_context.get("SelectedRunRootIsStale", False)),
                    "WarningCount": len(warning_details) if warning_details else len(payload.get("Warnings", [])),
                    "WarningLines": warning_lines,
                }
            )
        except Exception as exc:
            row["LoadError"] = str(exc)
        return row

    def refresh_snapshot_list(self) -> None:
        SNAPSHOT_DIR.mkdir(exist_ok=True)
        self.snapshot_paths = sorted(
            SNAPSHOT_DIR.glob("effective-config*.json"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )[:SNAPSHOT_LIST_LIMIT]
        self.snapshot_rows = [self._load_snapshot_row(path) for path in self.snapshot_paths]
        for item in self.snapshot_tree.get_children():
            self.snapshot_tree.delete(item)
        for index, row in enumerate(self.snapshot_rows):
            self.snapshot_tree.insert(
                "",
                "end",
                iid=str(index),
                values=(
                    row["Name"],
                    row["Modified"],
                    row["SizeText"],
                    "예" if row["SelectedRunRootIsStale"] else "아니오",
                    row["WarningCount"],
                ),
            )

        if self.snapshot_rows:
            first = self.snapshot_tree.get_children()[0]
            self.snapshot_tree.selection_set(first)
            self.on_snapshot_selected()
        else:
            self.set_text(self.snapshot_text, "(적용 설정 스냅샷 없음)")

    def _selected_snapshot_index(self) -> int | None:
        selection = self.snapshot_tree.selection()
        if not selection:
            return None
        return int(selection[0])

    def _selected_snapshot_path(self) -> Path | None:
        index = self._selected_snapshot_index()
        if index is None:
            return None
        return self.snapshot_paths[index]

    def on_snapshot_selected(self, _event: object | None = None) -> None:
        index = self._selected_snapshot_index()
        if index is None:
            self.set_text(self.snapshot_text, "")
            return
        row = self.snapshot_rows[index]
        lines = [
            f"경로: {row['Path']}",
            f"수정시각: {row['Modified']}",
            f"크기: {row['SizeText']}",
            f"Lane: {row['Lane'] or '(unknown)'}",
            f"생성 시각: {row['GeneratedAt'] or '(unknown)'}",
            f"선택된 RunRoot: {row['SelectedRunRoot'] or '(none)'}",
            f"RunRoot 출처: {row['SelectedRunRootSource'] or '(none)'}",
            f"선택된 RunRoot stale 여부: {row['SelectedRunRootIsStale']}",
            f"경고수: {row['WarningCount']}",
        ]
        if row["LoadError"]:
            lines += ["", f"불러오기 오류: {row['LoadError']}"]
        elif row["WarningLines"]:
            lines += ["", "경고 상세:"] + row["WarningLines"]
        self.set_text(self.snapshot_text, "\n".join(lines))

    def open_selected_snapshot(self) -> None:
        path = self._selected_snapshot_path()
        if path is None:
            messagebox.showwarning("선택 필요", "snapshot을 먼저 선택하세요.")
            return
        os.startfile(path)

    def copy_selected_snapshot_path(self) -> None:
        path = self._selected_snapshot_path()
        if path is None:
            messagebox.showwarning("선택 필요", "snapshot을 먼저 선택하세요.")
            return
        self._copy_to_clipboard(str(path))
        self.set_text(self.output_text, f"snapshot 경로 복사 완료:\n{path}")

    def open_selected_snapshot_run_root(self) -> None:
        index = self._selected_snapshot_index()
        if index is None:
            messagebox.showwarning("선택 필요", "snapshot을 먼저 선택하세요.")
            return
        run_root = self.snapshot_rows[index].get("SelectedRunRoot", "")
        self._open_path(run_root, kind="snapshot RunRoot")

    def copy_selected_snapshot_run_root_path(self) -> None:
        index = self._selected_snapshot_index()
        if index is None:
            messagebox.showwarning("선택 필요", "snapshot을 먼저 선택하세요.")
            return
        run_root = self.snapshot_rows[index].get("SelectedRunRoot", "")
        if not run_root:
            messagebox.showwarning("RunRoot 없음", "선택된 snapshot에 run root가 없습니다.")
            return
        self._copy_to_clipboard(run_root)
        self.set_text(self.output_text, f"snapshot RunRoot 경로 복사 완료:\n{run_root}")

    def view_selected_snapshot_json(self) -> None:
        path = self._selected_snapshot_path()
        if path is None:
            messagebox.showwarning("선택 필요", "snapshot을 먼저 선택하세요.")
            return
        self.set_text(self.snapshot_text, path.read_text(encoding="utf-8"))

    def handle_dashboard_action(self, action_key: str, *, command_text: str = "") -> None:
        handlers = {
            "launch_windows": self.launch_windows,
            "attach_windows": self.attach_windows_from_bindings,
            "check_visibility": self.run_visibility_check,
            "prepare_run_root": self.prepare_run_root,
            "run_selected_pair": self.run_selected_pair_drill,
            "enable_pair": self.enable_selected_pair,
            "run_relay_status": self.run_relay_status,
            "run_paired_status": self.run_paired_status,
            "refresh_quick": self.refresh_quick_status,
            "start_watcher": self.start_watcher_detached,
            "pause_watcher": self.request_pause_watcher,
            "resume_watcher": self.request_resume_watcher,
            "stop_watcher": self.request_stop_watcher,
            "restart_watcher": self.restart_watcher,
            "recover_stale_watcher": self.recover_stale_watcher_state,
            "open_watcher_status": self.open_watcher_status_file,
            "open_watcher_control": self.open_watcher_control_file,
            "open_watcher_audit": self.open_watcher_audit_log,
            "focus_ready_to_forward_artifact": self.focus_ready_to_forward_artifact,
            "start_router": self.start_router_detached,
            "visible_cleanup_apply": self.run_visible_queue_cleanup_apply,
            "visible_preflight": self.run_visible_acceptance_preflight,
            "visible_active_acceptance": self.run_active_visible_acceptance,
            "visible_post_cleanup": self.run_visible_post_cleanup,
            "visible_clean_preflight": self.run_visible_clean_preflight_recheck,
            "visible_confirm": self.run_shared_visible_confirm,
            "visible_receipt_confirm": self.run_visible_receipt_confirm,
        }
        handled = self.home_controller.dispatch_action(
            action_key,
            handlers=handlers,
            command_text=command_text,
            copy_callback=self._copy_dashboard_command,
            unknown_callback=lambda unknown: self.set_text(self.output_text, f"알 수 없는 dashboard action:\n{unknown}"),
        )
        if handled and action_key == "copy_command" and command_text:
            self.set_text(self.output_text, f"다음 명령 복사 완료:\n{command_text}")

    def _copy_dashboard_command(self, command_text: str) -> None:
        if command_text:
            self._copy_to_clipboard(command_text)

    def focus_ready_to_forward_artifact(self) -> None:
        self.refresh_artifacts_tab()
        target_state = next((item for item in self.artifact_states if self.artifact_service.is_handoff_ready(item)), None)
        if target_state is None:
            messagebox.showinfo("전달 가능 target 없음", "현재 결과 탭에서 다음 전달 가능 target을 찾지 못했습니다.")
            return
        if self.notebook is not None and self.artifacts_tab is not None:
            self.notebook.select(self.artifacts_tab)
        self.artifact_tree.selection_set(target_state.target_id)
        self.artifact_tree.see(target_state.target_id)
        self.on_artifact_row_selected()
        self.set_operator_status(
            "전달 가능 target 선택",
            f"{target_state.target_id} / {target_state.pair_id} 다음 전달 가능 상태를 결과 탭에서 선택했습니다.",
            "마지막 결과: 다음 전달 가능 target 선택",
        )
        self.set_text(
            self.output_text,
            "다음 전달 가능 target 선택:\nPair={0}\nTarget={1}\nRole={2}".format(
                target_state.pair_id,
                target_state.target_id,
                target_state.role_name,
            ),
        )

    def launch_windows(self) -> None:
        wrapper_path = self._launcher_wrapper_path()
        if not wrapper_path:
            messagebox.showwarning("런처 없음", "현재 설정에서 LauncherWrapperPath를 찾지 못했습니다.")
            return
        if not Path(wrapper_path).exists():
            messagebox.showwarning("런처 없음", f"Launcher wrapper 경로가 없습니다.\n{wrapper_path}")
            return

        command = self.command_service.build_python_command(wrapper_path)
        launch_anchor_utc = self._utc_now_iso()
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            output = completed.stdout.strip() or f"visible launcher 실행 완료\n{wrapper_path}"
            self.window_launch_anchor_utc = launch_anchor_utc
            self.set_text(self.output_text, "[8창 열기 / wrapper]\n" + output)
            self.load_effective_config()

        self.run_background_task(
            state="8창 기동 중",
            hint="visible launcher를 실행해 왼쪽 화면 8창을 준비 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="8창 기동 완료",
            success_hint="binding profile과 홈 상태를 다시 불러왔습니다.",
            failure_state="8창 기동 실패",
            failure_hint="launcher wrapper 경로와 출력 로그를 확인하세요.",
        )

    def attach_windows_from_bindings(self) -> None:
        attach_allowed, attach_detail = self._attach_action_allowed()
        if not attach_allowed:
            messagebox.showwarning("붙이기 대기", attach_detail)
            return

        current_context = self._effective_refresh_context()
        command = self.command_service.build_script_command(
            "attach-targets-from-bindings.ps1",
            config_path=self.config_path_var.get().strip(),
        )
        self.last_command_var.set(
            "attach bundle: {0} ; {1}".format(
                subprocess.list2cmdline(command),
                self._runtime_refresh_command_preview(current_context),
            )
        )

        def worker() -> tuple[subprocess.CompletedProcess[str], object]:
            completed = self.command_service.run(command)
            runtime_result = self.refresh_controller.refresh_runtime(current_context)
            return completed, runtime_result

        def on_success(result: tuple[subprocess.CompletedProcess[str], object]) -> None:
            completed, runtime_result = result
            self._apply_runtime_refresh_result(runtime_result)
            self.set_text(
                self.output_text,
                "\n".join(
                    [
                        "[붙이기]",
                        completed.stdout.strip() or "binding attach 완료",
                        "",
                        "[입력 점검]",
                        self._format_visibility_status_report(
                            runtime_result.visibility_status,
                            relay_payload=runtime_result.relay_status,
                            include_json=False,
                        ),
                    ]
                ).strip(),
            )
            self.last_result_var.set(
                "마지막 결과: 바인딩 attach 완료 / {0}".format(
                    self._visibility_last_result_text(
                        runtime_result.visibility_status,
                        relay_payload=runtime_result.relay_status,
                    ).replace("마지막 결과: ", "", 1)
                )
            )
            self.load_effective_config()

        self.run_background_task(
            state="바인딩 attach 중",
            hint="binding profile 기준으로 runtime map을 다시 붙이고 있습니다.",
            worker=worker,
            on_success=on_success,
            success_state="바인딩 attach 완료",
            success_hint="attach 뒤 runtime/입력 점검까지 다시 읽어 홈 카드와 단계 진행판을 갱신했습니다.",
            failure_state="바인딩 attach 실패",
            failure_hint="binding profile과 runtime map 상태를 확인하세요.",
        )

    def _reuse_windows(self, *, pairs_mode: bool = False) -> None:
        config_path = self.config_path_var.get().strip()
        if not config_path:
            title = "열린 pair 재사용" if pairs_mode else "기존 8창 재사용"
            messagebox.showwarning("설정 필요", f"{title}을(를) 하려면 ConfigPath가 필요합니다.")
            return

        reuse_anchor_utc = self._utc_now_iso()
        self.last_command_var.set(
            self._reuse_active_pairs_command_preview() if pairs_mode else self._reuse_existing_windows_command_preview()
        )
        operation_label = "열린 pair 재사용 결과" if pairs_mode else "기존 8창 재사용 결과"
        success_label = "열린 pair 재사용 성공 / 현재 세션 승격" if pairs_mode else "기존 8창 재사용 성공 / 현재 세션 승격"
        state_label = "열린 pair 재사용 중" if pairs_mode else "기존 8창 재사용 중"
        success_state = "열린 pair 재사용 완료" if pairs_mode else "기존 8창 재사용 완료"
        success_hint = (
            "binding refresh, attach 재실행, 입력 점검 결과를 활성 pair 기준 현재 세션으로 반영했습니다."
            if pairs_mode
            else "binding refresh, attach 재실행, 입력 점검 결과를 현재 세션 기준으로 반영했습니다."
        )
        failure_state = "열린 pair 재사용 실패" if pairs_mode else "기존 8창 재사용 실패"
        failure_hint = "재사용 실패 사유와 출력 JSON을 확인하세요."
        current_context = self._snapshot_context()
        workflow = self._runtime_workflow()

        def worker():
            return workflow.run_reuse(
                ReuseWindowsRequest(
                    context=current_context,
                    config_path=config_path,
                    reuse_anchor_utc=reuse_anchor_utc,
                    pairs_mode=pairs_mode,
                )
            )

        def on_success(result) -> None:
            self.window_launch_anchor_utc = str(result.reuse_anchor_utc or self.window_launch_anchor_utc)
            runtime_result = result.runtime_result
            if runtime_result is not None:
                self._apply_runtime_refresh_result(runtime_result)
            reuse_payload = result.reuse_payload
            if pairs_mode:
                self._apply_reuse_active_pair_selection(reuse_payload)
            self.set_text(
                self.output_text,
                self._format_reuse_existing_windows_report(
                    reuse_payload,
                    attach_output=str(result.attach_output or ""),
                    runtime_result=runtime_result,
                    operation_label=operation_label,
                ),
            )
            self.load_effective_config()
            self.last_result_var.set("마지막 결과: {0}".format(success_label))

        self.run_background_task(
            state=state_label,
            hint=(
                "현재 떠 있는 8창을 검증한 뒤 binding을 현재 세션 기준으로 갱신하고 있습니다."
                if not pairs_mode
                else "현재 떠 있는 창 중 완전한 pair만 검증해 binding을 현재 세션 기준으로 갱신하고 있습니다."
            ),
            worker=worker,
            on_success=on_success,
            success_state=success_state,
            success_hint=success_hint,
            failure_state=failure_state,
            failure_hint=failure_hint,
        )

    def reuse_existing_windows(self) -> None:
        self._reuse_windows(pairs_mode=False)

    def reuse_active_pairs(self) -> None:
        self._reuse_windows(pairs_mode=True)

    def prepare_run_root(self) -> None:
        pair_id = self._selected_pair_id()
        config_path = self.config_path_var.get().strip()
        try:
            prepare_config_path = self._resolve_run_prepare_config_path(pair_id=pair_id, config_path=config_path)
        except Exception as exc:
            messagebox.showerror("RunRoot 준비 실패", str(exc))
            self.set_text(self.output_text, str(exc))
            self.last_result_var.set(f"마지막 결과: 실패 ({exc})")
            return
        workflow = self._runtime_workflow()
        scope_allowed, scope_detail = self._selected_pair_scope_allowed(action_label="run 준비")
        if not scope_allowed:
            messagebox.showwarning("RunRoot 준비 대기", scope_detail)
            return
        ignored_run_root = self._prepare_run_root_override_to_ignore()
        requested_run_root = self._requested_run_root_for_prepare()
        current_context = self._prepare_run_root_action_context(ignored_run_root=ignored_run_root)
        command = self.command_service.build_script_command(
            "tests/Start-PairedExchangeTest.ps1",
            config_path=prepare_config_path,
            run_root=requested_run_root,
            extra=["-IncludePairId", pair_id],
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker():
            return workflow.prepare_run_root(
                RunRootPrepareRequest(
                    config_path=config_path,
                    pair_id=pair_id,
                    requested_run_root=requested_run_root,
                    summary_fallback_run_root=current_context.run_root,
                    prepare_config_path=prepare_config_path,
                )
            )

        def on_success(result) -> None:
            prepared_run_root = result.prepared_run_root
            if prepared_run_root:
                self.run_root_var.set(prepared_run_root)
            summary_text = result.summary_text
            self.set_text(
                self.output_text,
                (
                    self._format_run_root_prepare_output(
                        output=result.output,
                        ignored_run_root=ignored_run_root,
                        prepared_run_root=prepared_run_root,
                    )
                    + (f"\n\n{summary_text}" if summary_text else "")
                ),
            )
            self.load_effective_config()
            self.last_result_var.set(
                self._run_root_prepare_last_result(
                    ignored_run_root=ignored_run_root,
                    prepared_run_root=prepared_run_root,
                )
            )

        self.run_background_task(
            state="RunRoot 준비 중",
            hint=f"{pair_id} 기준 실행 루트와 request 계약을 준비 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="RunRoot 준비 완료",
            success_hint="선택된 run root를 홈 탭과 상단 입력란에 반영했습니다.",
            failure_state="RunRoot 준비 실패",
            failure_hint="manifest 준비 출력과 config를 확인하세요.",
        )

    def run_prepare_all(self) -> None:
        wrapper_path = self._launcher_wrapper_path()
        config_path = self.config_path_var.get().strip()
        pair_id = self._selected_pair_id()
        try:
            prepare_config_path = self._resolve_run_prepare_config_path(pair_id=pair_id, config_path=config_path)
        except Exception as exc:
            messagebox.showerror("창/Attach/입력/RunRoot 준비 실패", str(exc))
            self.set_text(self.output_text, str(exc))
            self.last_result_var.set(f"마지막 결과: 실패 ({exc})")
            return
        scope_allowed, scope_detail = self._selected_pair_scope_allowed(action_label="창/Attach/입력/RunRoot 준비")
        if not scope_allowed:
            messagebox.showwarning("창/Attach/입력/RunRoot 준비 대기", scope_detail)
            return
        ignored_run_root = self._prepare_run_root_override_to_ignore()
        explicit_run_root = self._requested_run_root_for_prepare()
        current_context = self._prepare_run_root_action_context(ignored_run_root=ignored_run_root)
        stage_map = {stage.key: stage for stage in (self.panel_state.stages if self.panel_state else [])}
        workflow = self._runtime_workflow()

        def worker():
            return workflow.run_prepare_all(
                PrepareAllRequest(
                    context=current_context,
                    config_path=config_path,
                    pair_id=pair_id,
                    explicit_run_root=explicit_run_root,
                    prepare_config_path=prepare_config_path,
                    wrapper_path=wrapper_path,
                    launch_windows_needed=bool(stage_map.get("launch_windows") and stage_map["launch_windows"].status_text != "완료"),
                    attach_windows_needed=bool(stage_map.get("attach_windows") and stage_map["attach_windows"].status_text != "완료"),
                )
            )

        def on_success(result) -> None:
            prepared_run_root = result.run_root_result.prepared_run_root
            runtime_result = result.runtime_result
            launch_anchor_utc = result.window_launch_anchor_utc
            if launch_anchor_utc:
                self.window_launch_anchor_utc = launch_anchor_utc
            if runtime_result is not None:
                self._apply_runtime_refresh_result(runtime_result)
            if prepared_run_root:
                self.run_root_var.set(prepared_run_root)
            lines: list[str] = []
            if result.launcher_output:
                launch_label = "[8창 열기 / {0}]".format(result.window_launch_mode or "wrapper")
                lines.extend([launch_label, result.launcher_output, ""])
                if result.wrapper_path:
                    lines.extend(["WrapperPath: " + result.wrapper_path, ""])
            if result.attach_output:
                attach_label = "[붙이기 / {0}]".format(result.window_reuse_mode or "attach-only")
                lines.extend([attach_label, result.attach_output, ""])
            lines.extend(
                [
                    "[입력 점검]",
                    self._format_visibility_status_report(
                        runtime_result.visibility_status,
                        relay_payload=runtime_result.relay_status,
                        include_json=False,
                    ),
                    "",
                    "[run 준비]",
                    self._format_run_root_prepare_output(
                        output=result.run_root_result.output,
                        ignored_run_root=ignored_run_root,
                        prepared_run_root=prepared_run_root,
                    ),
                ]
            )
            if result.run_root_result.summary_text:
                lines.extend(["", result.run_root_result.summary_text])
            self.last_result_var.set(
                self._run_root_prepare_last_result(
                    ignored_run_root=ignored_run_root,
                    prepared_run_root=prepared_run_root,
                )
            )
            self.set_text(self.output_text, "\n".join(lines).strip() or "창/Attach/입력/RunRoot 준비 완료")
            self.load_effective_config()

        self.run_background_task(
            state="창/Attach/입력/RunRoot 준비 중",
            hint="창 준비, attach, 입력 점검, run 준비를 순서대로 실행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="창/Attach/입력/RunRoot 준비 완료",
            success_hint="홈 단계 진행판과 pair 요약을 갱신했습니다.",
            failure_state="창/Attach/입력/RunRoot 준비 실패",
            failure_hint="실패한 단계의 출력과 마지막 명령을 확인하세요.",
        )

    def _set_visible_acceptance_output(self, text: str) -> None:
        if self._has_ui_attr("visible_acceptance_text"):
            self.set_text(self.visible_acceptance_text, text)
        self.set_text(self.output_text, text)

    def _selected_seed_target_for_visible_acceptance(self) -> str:
        return self._resolve_top_target_for_pair(self._selected_pair_id())

    def _resolve_manifest_run_root_for_visible_acceptance(
        self,
        *,
        action_label: str,
        allow_stale: bool = False,
    ) -> tuple[str, str]:
        run_root = self._current_run_root_for_actions().strip()
        if not run_root:
            return "", f"{action_label} 전에 RunRoot 준비가 필요합니다."
        if not allow_stale and self._run_root_is_stale(run_root):
            return "", f"{action_label} 전에 stale이 아닌 RunRoot를 다시 준비하세요."
        manifest_path = Path(run_root) / "manifest.json"
        if not manifest_path.exists():
            return "", f"{action_label} 전에 'run 준비'를 먼저 실행해 manifest.json이 있는 RunRoot를 준비하세요."
        return run_root, ""

    def _acceptance_receipt_summary_from_run_root(self, run_root: str) -> dict[str, str]:
        run_root = str(run_root or "").strip()
        if not run_root:
            return empty_acceptance_receipt_summary()
        path = Path(run_root) / ".state" / "live-acceptance-result.json"
        if not path.exists():
            return empty_acceptance_receipt_summary(path=str(path))
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            return empty_acceptance_receipt_summary(path=str(path), exists=True, parse_error=str(exc))
        if not isinstance(payload, dict):
            return empty_acceptance_receipt_summary(path=str(path), exists=True, parse_error="receipt payload must be an object")
        return summarize_acceptance_receipt_payload(payload, path=str(path))

    def _visible_workflow_scope_key(self, *, run_root: str = "", pair_id: str = "") -> str:
        return visible_workflow_scope_key(run_root=run_root, pair_id=pair_id)

    def _visible_workflow_progress(self, *, scope_key: str) -> VisibleAcceptanceWorkflowProgress:
        progress_map = self.__dict__.setdefault("visible_workflow_progress_by_scope", {})
        progress = progress_map.get(scope_key)
        if progress is None:
            progress = VisibleAcceptanceWorkflowProgress()
            progress_map[scope_key] = progress
        return progress

    def _record_visible_workflow_progress(self, *, scope_key: str, action: str, **changes: bool) -> VisibleAcceptanceWorkflowProgress:
        progress = self._visible_workflow_progress(scope_key=scope_key)
        for key, value in changes.items():
            if hasattr(progress, key):
                setattr(progress, key, bool(value))
        progress.last_action = action
        progress.last_updated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        return progress

    def _build_visible_acceptance_state(self, *, ignore_pair_scope: bool = False) -> VisibleAcceptanceState:
        config_present = bool(self.config_path_var.get().strip())
        pair_id = self._selected_pair_id()
        seed_target_id = self._selected_seed_target_for_visible_acceptance() if pair_id else ""
        selected_state = self.get_pair_activation_state(pair_id) if pair_id else None
        pair_enabled = bool((selected_state or {}).get("EffectiveEnabled", True))
        if ignore_pair_scope:
            pair_scope_allowed, pair_scope_detail = True, ""
        else:
            pair_scope_allowed, pair_scope_detail = self._selected_pair_scope_allowed(action_label="visible acceptance")
        action_run_root = self._current_run_root_for_actions().strip()
        active_run_root, active_run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label="visible preflight-only",
            allow_stale=False,
        )
        confirm_run_root, confirm_run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label="shared visible confirm",
            allow_stale=True,
        )
        scope_run_root = confirm_run_root or action_run_root or active_run_root
        scope_key = self._visible_workflow_scope_key(run_root=scope_run_root, pair_id=pair_id)
        progress = self._visible_workflow_progress(scope_key=scope_key)
        receipt = self._acceptance_receipt_summary_from_run_root(scope_run_root) if scope_run_root else empty_acceptance_receipt_summary()
        return build_visible_acceptance_state(
            VisibleAcceptanceInputs(
                config_present=config_present,
                pair_id=pair_id,
                seed_target_id=seed_target_id,
                pair_enabled=pair_enabled,
                pair_scope_allowed=pair_scope_allowed,
                pair_scope_detail=pair_scope_detail,
                action_run_root=action_run_root,
                active_run_root=active_run_root,
                active_run_root_detail=active_run_root_detail,
                confirm_run_root=confirm_run_root,
                confirm_run_root_detail=confirm_run_root_detail,
                receipt_summary=receipt,
                progress=progress,
                busy=self._busy,
                last_result_text=self.last_result_var.get() if self._has_ui_attr("last_result_var") else "",
                disable_reason=str((selected_state or {}).get("DisableReason", "") or ""),
            )
        )

    def _refresh_visible_acceptance_summary(self) -> VisibleAcceptanceState:
        state = self._build_visible_acceptance_state()
        if self._has_ui_attr("visible_acceptance_status_var"):
            self.visible_acceptance_status_var.set(state.status_text)
        if self._has_ui_attr("visible_acceptance_detail_var"):
            self.visible_acceptance_detail_var.set(state.detail_text)
        return state

    def _require_visible_acceptance_step(self, action_key: str) -> VisibleAcceptanceState | None:
        state = self._build_visible_acceptance_state(
            ignore_pair_scope=action_key in {"visible_confirm", "visible_receipt_confirm"}
        )
        allowed = True
        detail = ""
        if action_key == "visible_cleanup_dry":
            allowed = state.config_present
            detail = "visible cleanup에는 ConfigPath가 필요합니다."
        elif action_key == "visible_cleanup_apply":
            allowed = state.config_present
            detail = "visible cleanup에는 ConfigPath가 필요합니다."
        elif action_key == "visible_preflight":
            allowed = state.preflight_enabled
            detail = state.detail_text
        elif action_key == "visible_active_acceptance":
            allowed = state.active_enabled
            detail = state.detail_text
        elif action_key == "visible_post_cleanup":
            allowed = state.post_cleanup_enabled
            detail = state.detail_text
        elif action_key == "visible_clean_preflight":
            allowed = state.clean_preflight_enabled
            detail = state.detail_text
        elif action_key == "visible_confirm":
            allowed = state.shared_confirm_enabled
            detail = state.detail_text
        elif action_key == "visible_receipt_confirm":
            allowed = state.receipt_confirm_enabled
            detail = state.detail_text
        if not allowed:
            messagebox.showwarning("Visible Acceptance 대기", detail or "현재 단계에서는 이 작업을 실행할 수 없습니다.")
            return None
        return state

    def _current_visible_receipt_path(self) -> str:
        receipt = ((self.paired_status_data or {}).get("AcceptanceReceipt", {}) or {})
        path = str(receipt.get("Path", "") or "").strip()
        if path:
            return path
        run_root = self._current_run_root_for_actions().strip()
        if not run_root:
            return ""
        return str(Path(run_root) / ".state" / "live-acceptance-result.json")

    def open_visible_receipt_path(self) -> None:
        path = self._current_visible_receipt_path()
        if not path:
            messagebox.showwarning("receipt 경로 없음", "현재 RunRoot / paired status 기준 visible receipt 경로를 찾지 못했습니다.")
            return
        self._open_path(path, kind="visible receipt")

    def copy_visible_receipt_path(self) -> None:
        path = self._current_visible_receipt_path()
        if not path:
            messagebox.showwarning("receipt 경로 없음", "현재 RunRoot / paired status 기준 visible receipt 경로를 찾지 못했습니다.")
            return
        self._copy_to_clipboard(path)
        self.set_text(self.output_text, f"visible receipt 경로 복사 완료:\n{path}")

    def _format_visible_cleanup_report(self, payload: dict, *, apply: bool, title: str) -> str:
        summary = payload.get("Summary", {}) or {}
        protected_items: list[str] = []
        for row in payload.get("Targets", []) or []:
            for item in row.get("Items", []) or []:
                if str(item.get("Action", "") or "") != "keep-protected-run":
                    continue
                protected_items.append(
                    "{target} {bucket} runRoot={run_root} cmd={command_id}".format(
                        target=str(item.get("TargetId", "") or "(unknown)"),
                        bucket=str(item.get("Bucket", "") or "(bucket)"),
                        run_root=str(item.get("RunRoot", "") or "(none)"),
                        command_id=str(item.get("CommandId", "") or "(none)"),
                    )
                )
        lines = [
            title,
            f"Mode: {'apply' if apply else 'dry-run'}",
            f"KeepRunRoot: {payload.get('KeepRunRoot', '') or '(none)'}",
            "Foreign={0} Invalid={1} Stale={2} ProtectedRun={3} KeptSameRun={4}".format(
                int(summary.get("ForeignCount", 0) or 0),
                int(summary.get("InvalidCount", 0) or 0),
                int(summary.get("StaleCount", 0) or 0),
                int(summary.get("ProtectedRunCount", 0) or 0),
                int(summary.get("KeptSameRunCount", 0) or 0),
            ),
            "ArchivedForeign={0} ArchivedInvalid={1} ReclaimedStale={2} ReleasedRunningState={3}".format(
                int(summary.get("ForeignArchivedCount", 0) or 0),
                int(summary.get("InvalidMetadataArchivedCount", 0) or 0),
                int(summary.get("StaleProcessingReclaimedCount", 0) or 0),
                int(summary.get("ReleasedRunningStateCount", 0) or 0),
            ),
        ]
        if protected_items:
            lines.extend(["", "Protected runs", *["- " + item for item in protected_items[:6]]])
        lines.extend(["", "JSON", json.dumps(payload, ensure_ascii=False, indent=2)])
        return "\n".join(lines)

    def _format_live_acceptance_report(self, payload: dict, *, title: str) -> str:
        outcome = payload.get("Outcome", {}) or {}
        preflight = payload.get("Preflight", {}) or {}
        watcher = payload.get("Watcher", {}) or {}
        seed = payload.get("Seed", {}) or {}
        blocked_by = str(payload.get("BlockedBy", "") or preflight.get("BlockedBy", "") or "")
        blocked_target = str(payload.get("BlockedTargetId", "") or preflight.get("BlockedTargetId", "") or "")
        blocked_run_root = str(payload.get("BlockedRunRoot", "") or preflight.get("BlockedRunRoot", "") or "")
        blocked_path = str(payload.get("BlockedPath", "") or preflight.get("BlockedPath", "") or "")
        blocked_detail = str(payload.get("BlockedDetail", "") or preflight.get("BlockedDetail", "") or "")
        allowed_window_visibility_methods = payload.get("AllowedWindowVisibilityMethods", []) or []
        lines = [
            title,
            f"RunRoot: {payload.get('RunRoot', '')}",
            f"Pair: {payload.get('PairId', '')}",
            f"SeedTarget: {payload.get('SeedTargetId', '')}",
            f"ExecutionPathMode: {payload.get('ExecutionPathMode', '') or '(없음)'}",
            f"UserVisibleCellExecutionRequired: {payload.get('UserVisibleCellExecutionRequired', False)}",
            f"AllowedWindowVisibilityMethods: {', '.join(str(item) for item in allowed_window_visibility_methods) or '(없음)'}",
            f"SubmitRetrySequence: {payload.get('SubmitRetrySequenceSummary', '') or '(없음)'}",
            f"SubmitPrimaryMode: {payload.get('PrimarySubmitMode', '') or '(없음)'}",
            f"SubmitFinalMode: {payload.get('FinalSubmitMode', '') or '(없음)'}",
            f"SubmitRetryIntervalMs: {payload.get('SubmitRetryIntervalMs', '') or '(없음)'}",
            f"Stage: {payload.get('Stage', '')}",
            f"AcceptanceState: {outcome.get('AcceptanceState', '') or '(없음)'}",
            f"AcceptanceReason: {outcome.get('AcceptanceReason', '') or '(없음)'}",
            f"ReceiptPath: {payload.get('ReceiptPath', '') or '(없음)'}",
            f"LastUpdatedAt: {payload.get('LastUpdatedAt', '') or '(없음)'}",
        ]
        if blocked_by:
            lines.extend(
                [
                    f"BlockedBy: {blocked_by}",
                    f"BlockedTargetId: {blocked_target or '(없음)'}",
                    f"BlockedRunRoot: {blocked_run_root or '(없음)'}",
                    f"BlockedPath: {blocked_path or '(없음)'}",
                    f"BlockedDetail: {blocked_detail or '(없음)'}",
                ]
            )
        phase_history = payload.get("PhaseHistory", [])
        if isinstance(phase_history, list) and phase_history:
            lines.append("PhaseHistoryCount: {0}".format(len(phase_history)))
            lines.append("RecentPhases:")
            for entry in phase_history[-5:]:
                if not isinstance(entry, dict):
                    continue
                lines.append(
                    "- {recorded} stage={stage} state={state} blocked={blocked}".format(
                        recorded=str(entry.get("RecordedAt", "") or "(time)"),
                        stage=str(entry.get("Stage", "") or "(none)"),
                        state=str(entry.get("AcceptanceState", "") or "(none)"),
                        blocked=str(entry.get("BlockedBy", "") or "(none)"),
                    )
                )
        if seed:
            lines.extend(
                [
                    f"SeedFinalState: {seed.get('FinalState', '') or '(없음)'}",
                    f"SeedSubmitState: {seed.get('SubmitState', '') or '(없음)'}",
                    f"SeedExecutionPathMode: {seed.get('ExecutionPathMode', '') or '(없음)'}",
                    f"SeedSubmitRetrySequence: {seed.get('SubmitRetrySequenceSummary', '') or '(없음)'}",
                    f"SeedPrimarySubmitMode: {seed.get('PrimarySubmitMode', '') or '(없음)'}",
                    f"SeedFinalSubmitMode: {seed.get('FinalSubmitMode', '') or '(없음)'}",
                    f"SeedSubmitRetryIntervalMs: {seed.get('SubmitRetryIntervalMs', '') or '(없음)'}",
                    f"SeedOutboxPublished: {bool(seed.get('OutboxPublished', False))}",
                ]
            )
        if watcher:
            lines.append(f"WatcherStatus: {watcher.get('Status', '') or '(없음)'}")
        lines.extend(["", "JSON", json.dumps(payload, ensure_ascii=False, indent=2)])
        return "\n".join(lines)

    def _format_visible_confirm_report(self, payload: dict, *, title: str) -> str:
        checks = payload.get("Checks", []) or []
        failed_required = [
            "{0}: {1}".format(str(item.get("Name", "") or "(unknown)"), str(item.get("Summary", "") or ""))
            for item in checks
            if bool(item.get("Required", False)) and not bool(item.get("Passed", False))
        ]
        lines = [
            title,
            f"Overall: {payload.get('Overall', '')}",
            f"Mode: {payload.get('Mode', '')}",
            f"RunRoot: {payload.get('RunRoot', '')}",
            f"Pair: {payload.get('PairId', '')}",
            f"SeedTarget: {payload.get('SeedTargetId', '')}",
            f"Summary: {payload.get('SummaryLine', '') or '(없음)'}",
        ]
        if failed_required:
            lines.extend(["", "실패한 required checks:"])
            lines.extend("- " + item for item in failed_required)
        else:
            lines.extend(["", "RequiredChecks: 모두 통과"])
        lines.extend(["", "JSON", json.dumps(payload, ensure_ascii=False, indent=2)])
        return "\n".join(lines)

    def _format_live_acceptance_failure_output(self, exc: Exception, *, run_root: str) -> str:
        lines = [self._format_background_exception(exc)]
        if run_root:
            receipt = self._acceptance_receipt_summary_from_run_root(run_root)
            if receipt.get("Exists", "") == "true":
                lines.extend(
                    [
                        "",
                        "Receipt",
                        f"Path: {receipt.get('Path', '')}",
                        f"Stage: {receipt.get('Stage', '') or '(없음)'}",
                        f"AcceptanceState: {receipt.get('AcceptanceState', '') or '(없음)'}",
                        f"AcceptanceReason: {receipt.get('AcceptanceReason', '') or '(없음)'}",
                        f"LastUpdatedAt: {receipt.get('LastUpdatedAt', '') or '(없음)'}",
                    ]
                )
                if receipt.get("BlockedBy", ""):
                    lines.extend(
                        [
                            f"BlockedBy: {receipt.get('BlockedBy', '')}",
                            f"BlockedTargetId: {receipt.get('BlockedTargetId', '') or '(없음)'}",
                            f"BlockedRunRoot: {receipt.get('BlockedRunRoot', '') or '(없음)'}",
                            f"BlockedPath: {receipt.get('BlockedPath', '') or '(없음)'}",
                            f"BlockedDetail: {receipt.get('BlockedDetail', '') or '(없음)'}",
                        ]
                    )
                if receipt.get("PhaseHistoryCount", ""):
                    lines.append(f"PhaseHistoryCount: {receipt.get('PhaseHistoryCount', '')}")
                if receipt.get("PhaseHistoryTail", ""):
                    lines.append(f"PhaseHistoryTail: {receipt.get('PhaseHistoryTail', '')}")
            else:
                lines.extend(["", "Receipt", f"Path: {receipt.get('Path', '')}", "receipt 파일을 찾지 못했습니다."])
        return "\n".join(lines)

    def _run_visible_cleanup(
        self,
        *,
        apply: bool,
        title: str,
        state_prefix: str,
        mode_label: str,
        mode_detail: str,
    ) -> None:
        action_key = "visible_post_cleanup" if title == "post-cleanup" else ("visible_cleanup_apply" if apply else "visible_cleanup_dry")
        visible_state = self._require_visible_acceptance_step(action_key)
        if visible_state is None:
            return
        self._set_visible_mode_banner(mode_label, mode_detail)
        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "visible cleanup에는 ConfigPath가 필요합니다.")
            return

        extra = ["-AsJson"]
        keep_run_root = self._current_run_root_for_actions().strip()
        if keep_run_root and Path(keep_run_root).exists():
            extra = ["-KeepRunRoot", keep_run_root] + extra
        if apply:
            extra = ["-Apply"] + extra
        command = self.command_service.build_script_command(
            "visible/Cleanup-VisibleWorkerQueue.ps1",
            config_path=config_path,
            extra=extra,
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> object:
            payload = json.loads(completed.stdout)
            if title == "post-cleanup":
                self._record_visible_workflow_progress(
                    scope_key=visible_state.scope_key,
                    action=action_key,
                    post_cleanup_done=True,
                )
            elif apply:
                self._record_visible_workflow_progress(
                    scope_key=visible_state.scope_key,
                    action=action_key,
                    cleanup_applied=True,
                    preflight_passed=False,
                    active_attempted=False,
                    post_cleanup_done=False,
                    clean_preflight_passed=False,
                    shared_confirm_passed=False,
                    receipt_confirm_passed=False,
                )
            self._set_visible_acceptance_output(self._format_visible_cleanup_report(payload, apply=apply, title=title))
            return self.refresh_quick_status

        self.run_background_task(
            state=f"{state_prefix} 실행 중",
            hint="shared visible lane queue / worker 상태를 정리하는 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state=f"{state_prefix} 완료",
            success_hint="queue/worker 상태와 홈 카드를 다시 읽었습니다.",
            failure_state=f"{state_prefix} 실패",
            failure_hint="visible worker queue 상태와 마지막 명령을 확인하세요.",
        )

    def run_visible_queue_cleanup_dry_run(self) -> None:
        self._run_visible_cleanup(
            apply=False,
            title="visible worker queue cleanup",
            state_prefix="visible cleanup dry-run",
            mode_label="MODE: Active Visible",
            mode_detail="shared visible lane 진입 전 queue / worker 상태를 점검합니다.",
        )

    def run_visible_queue_cleanup_apply(self) -> None:
        self._run_visible_cleanup(
            apply=True,
            title="visible worker queue cleanup",
            state_prefix="visible cleanup apply",
            mode_label="MODE: Active Visible",
            mode_detail="shared visible lane 진입 전 queue / worker 상태를 정리합니다.",
        )

    def run_visible_post_cleanup(self) -> None:
        self._run_visible_cleanup(
            apply=True,
            title="post-cleanup",
            state_prefix="post-cleanup",
            mode_label="MODE: Recovery",
            mode_detail="active visible acceptance 이후 queue / worker 상태를 닫는 정리 단계입니다.",
        )

    def _run_visible_acceptance(
        self,
        *,
        preflight_only: bool,
        title: str,
        mode_label: str,
        mode_detail: str,
        require_enabled_pair: bool,
        allow_stale_run_root: bool,
    ) -> None:
        action_key = "visible_preflight" if preflight_only else "visible_active_acceptance"
        if title == "clean preflight recheck":
            action_key = "visible_clean_preflight"
        visible_state = self._require_visible_acceptance_step(action_key)
        if visible_state is None:
            return
        self._set_visible_mode_banner(mode_label, mode_detail)
        pair_scope_allowed, pair_scope_detail = self._selected_pair_scope_allowed(
            action_label=title
        )
        if not pair_scope_allowed:
            messagebox.showwarning("visible acceptance 대기", pair_scope_detail)
            return

        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "visible acceptance에는 ConfigPath가 필요합니다.")
            return

        pair_id = self._selected_pair_id()
        if require_enabled_pair:
            activation = self.get_pair_activation_state(pair_id)
            if activation and not bool(activation.get("EffectiveEnabled", True)):
                messagebox.showwarning("Pair 비활성", f"{pair_id}는 현재 비활성 상태입니다.\n사유: {activation.get('DisableReason', '') or '(none)'}")
                return
        seed_target_id = self._selected_seed_target_for_visible_acceptance()
        if not seed_target_id:
            messagebox.showwarning("SeedTarget 필요", "선택한 pair의 top target을 해석하지 못했습니다.")
            return

        run_root, run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label=title,
            allow_stale=allow_stale_run_root,
        )
        if not run_root:
            messagebox.showwarning("RunRoot 필요", run_root_detail)
            return

        extra = [
            "-RunRoot",
            run_root,
            "-PairId",
            pair_id,
            "-SeedTargetId",
            seed_target_id,
            "-ReuseExistingRunRoot",
            "-AsJson",
        ]
        if preflight_only:
            extra.append("-PreflightOnly")
        command = self.command_service.build_script_command(
            "tests/Run-LiveVisiblePairAcceptance.ps1",
            config_path=config_path,
            extra=extra,
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> object:
            payload = json.loads(completed.stdout)
            resolved_run_root = str(payload.get("RunRoot", "") or run_root)
            if resolved_run_root:
                self.run_root_var.set(resolved_run_root)
            outcome = payload.get("Outcome", {}) if isinstance(payload.get("Outcome", {}), dict) else {}
            acceptance_state = str(outcome.get("AcceptanceState", "") or "")
            if preflight_only and title == "clean preflight recheck":
                self._record_visible_workflow_progress(
                    scope_key=visible_state.scope_key,
                    action=action_key,
                    post_cleanup_done=True,
                    clean_preflight_passed=acceptance_state == "preflight-passed",
                )
            elif preflight_only:
                self._record_visible_workflow_progress(
                    scope_key=visible_state.scope_key,
                    action=action_key,
                    cleanup_applied=True,
                    preflight_passed=acceptance_state == "preflight-passed",
                    active_attempted=False,
                    post_cleanup_done=False,
                    clean_preflight_passed=False,
                    shared_confirm_passed=False,
                    receipt_confirm_passed=False,
                )
            else:
                self._record_visible_workflow_progress(
                    scope_key=visible_state.scope_key,
                    action=action_key,
                    cleanup_applied=True,
                    preflight_passed=True,
                    active_attempted=True,
                    post_cleanup_done=False,
                    clean_preflight_passed=False,
                    shared_confirm_passed=False,
                    receipt_confirm_passed=False,
                )
            self._set_visible_acceptance_output(
                self._format_live_acceptance_report(
                    payload,
                    title=title,
                )
            )
            return self.refresh_paired_status_only

        def on_failure(exc: Exception) -> str:
            self.refresh_paired_status_only(refresh_artifacts=False)
            text = self._format_live_acceptance_failure_output(exc, run_root=run_root)
            if self._has_ui_attr("visible_acceptance_text"):
                self.set_text(self.visible_acceptance_text, text)
            return text

        state_label = f"{title} 실행 중"
        success_label = f"{title} 완료"
        failure_label = f"{title} 실패"
        self.run_background_task(
            state=state_label,
            hint="shared visible 공식 acceptance receipt를 갱신하는 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state=success_label,
            success_hint="receipt와 paired status를 다시 읽었습니다.",
            failure_state=failure_label,
            failure_hint="receipt 경로와 blocked detail을 확인하세요.",
            on_failure=on_failure,
        )

    def run_visible_acceptance_preflight(self) -> None:
        self._run_visible_acceptance(
            preflight_only=True,
            title="visible preflight-only",
            mode_label="MODE: Active Visible",
            mode_detail="shared visible 공식 절차의 preflight-only 게이트를 실행합니다.",
            require_enabled_pair=True,
            allow_stale_run_root=False,
        )

    def run_active_visible_acceptance(self) -> None:
        self._run_visible_acceptance(
            preflight_only=False,
            title="active visible acceptance",
            mode_label="MODE: Active Visible",
            mode_detail="shared visible 공식 창 기준 active acceptance를 실행합니다.",
            require_enabled_pair=True,
            allow_stale_run_root=False,
        )

    def run_visible_clean_preflight_recheck(self) -> None:
        self._run_visible_acceptance(
            preflight_only=True,
            title="clean preflight recheck",
            mode_label="MODE: Passive Confirm",
            mode_detail="post-cleanup 이후 clean preflight 재확인으로 lane이 닫혔는지 검증합니다.",
            require_enabled_pair=False,
            allow_stale_run_root=True,
        )

    def _run_shared_visible_confirm(self, *, require_visible_receipt: bool) -> None:
        action_key = "visible_receipt_confirm" if require_visible_receipt else "visible_confirm"
        visible_state = self._require_visible_acceptance_step(action_key)
        if visible_state is None:
            return
        self._set_visible_mode_banner(
            "MODE: Passive Confirm",
            "기존 RunRoot / receipt 기준으로 shared visible closure를 재검증합니다.",
        )

        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "visible confirm에는 ConfigPath가 필요합니다.")
            return

        pair_id = self._selected_pair_id()
        seed_target_id = self._selected_seed_target_for_visible_acceptance()
        if not seed_target_id:
            messagebox.showwarning("SeedTarget 필요", "선택한 pair의 top target을 해석하지 못했습니다.")
            return

        run_root, run_root_detail = self._resolve_manifest_run_root_for_visible_acceptance(
            action_label="receipt confirm" if require_visible_receipt else "shared visible confirm",
            allow_stale=True,
        )
        if not run_root:
            messagebox.showwarning("RunRoot 필요", run_root_detail)
            return

        extra = [
            "-RunRoot",
            run_root,
            "-PairId",
            pair_id,
            "-SeedTargetId",
            seed_target_id,
            "-AsJson",
        ]
        if require_visible_receipt:
            extra.append("-RequireVisibleReceipt")
        command = self.command_service.build_script_command(
            "tests/Confirm-SharedVisiblePairAcceptance.ps1",
            config_path=config_path,
            extra=extra,
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> object:
            payload = json.loads(completed.stdout)
            overall = str(payload.get("Overall", "") or "")
            self._record_visible_workflow_progress(
                scope_key=visible_state.scope_key,
                action=action_key,
                shared_confirm_passed=(not require_visible_receipt and overall == "success"),
                receipt_confirm_passed=(require_visible_receipt and overall == "success"),
            )
            self._set_visible_acceptance_output(
                self._format_visible_confirm_report(
                    payload,
                    title="receipt confirm" if require_visible_receipt else "shared visible confirm",
                )
            )
            return self.refresh_paired_status_only

        self.run_background_task(
            state="receipt confirm 실행 중" if require_visible_receipt else "shared visible confirm 실행 중",
            hint="현재 RunRoot의 visible receipt / closure 상태를 재검증하는 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="receipt confirm 완료" if require_visible_receipt else "shared visible confirm 완료",
            success_hint="paired status와 receipt 카드를 다시 읽었습니다.",
            failure_state="receipt confirm 실패" if require_visible_receipt else "shared visible confirm 실패",
            failure_hint="confirm JSON과 acceptance receipt 상태를 확인하세요.",
        )

    def run_shared_visible_confirm(self) -> None:
        self._run_shared_visible_confirm(require_visible_receipt=False)

    def run_visible_receipt_confirm(self) -> None:
        self._run_shared_visible_confirm(require_visible_receipt=True)

    def start_router_detached(self) -> None:
        command = self.command_service.build_script_command(
            "router.ps1",
            config_path=self.config_path_var.get().strip(),
        )
        self.last_command_var.set(subprocess.list2cmdline(command))
        self.command_service.spawn_detached(command)
        self.set_text(self.output_text, "router.ps1를 별도 프로세스로 시작했습니다.\n\n" + subprocess.list2cmdline(command))
        self.set_operator_status("라우터 시작 요청", "수 초 뒤 빠른 새로고침으로 router/runtime 상태를 다시 확인합니다.", "마지막 결과: router 시작 요청")
        self.after(1500, self.refresh_runtime_status_only)

    def _start_watcher_detached(self, *, request: WatcherStartRequest | None = None, action_title: str = "watch 시작") -> None:
        run_root = self._current_run_root_for_actions()
        config_path = self._resolve_watcher_start_config_path(
            config_path=self.config_path_var.get().strip(),
            run_root=run_root,
        )
        current_paired_status = self.paired_status_data
        workflow = self._watcher_workflow()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watcher를 시작하려면 RunRoot가 먼저 준비돼야 합니다.")
            return
        if not config_path:
            messagebox.showwarning("설정 필요", "watcher를 시작하려면 ConfigPath가 필요합니다.")
            return
        effective_request = request
        if effective_request is not None and (not effective_request.run_root or not effective_request.config_path):
            effective_request = WatcherStartRequest(
                config_path=config_path,
                run_root=run_root,
                use_headless_dispatch=effective_request.use_headless_dispatch,
                max_forward_count=effective_request.max_forward_count,
                run_duration_sec=effective_request.run_duration_sec,
                pair_max_roundtrip_count=effective_request.pair_max_roundtrip_count,
            )
        watch_start_allowed, watch_start_detail = self._watch_start_allowed()
        if not watch_start_allowed:
            messagebox.showwarning(f"{action_title} 대기", watch_start_detail)
            return
        start_eligibility = self.watcher_controller.start_eligibility(current_paired_status, run_root)
        action_context = WatcherActionContextSnapshot(
            config_path=config_path,
            run_root=run_root,
            paired_status=current_paired_status,
        )
        clear_stale_first = False
        if not start_eligibility.allowed and start_eligibility.cleanup_allowed:
            confirmed = messagebox.askyesno(
                "watch stale 정리",
                start_eligibility.message + "\n\n안전 정리 후 바로 watch 시작을 진행할까요?",
                parent=self,
            )
            if not confirmed:
                self.set_text(self.output_text, workflow.build_start_blocked_update(action_context, start_eligibility).output_text)
                return
            clear_stale_first = True
        elif not start_eligibility.allowed:
            panel_update = workflow.build_start_blocked_update(action_context, start_eligibility)
            message = start_eligibility.message
            if start_eligibility.recommended_action:
                message += f"\n권장 조치: {start_eligibility.recommended_action}"
            messagebox.showwarning(f"{action_title} 차단", message)
            self._apply_watcher_panel_update(panel_update)
            return

        panel_update = workflow.start(
            action_context,
            clear_stale_first=clear_stale_first,
            request=effective_request,
        )
        if not panel_update.ok:
            messagebox.showerror(f"{action_title} 실패", panel_update.operator_hint)
            self._apply_watcher_panel_update(panel_update)
            return
        self._apply_watcher_panel_update(panel_update)
        self.after(1500, self.refresh_paired_status_only)

    def start_watcher_detached(self) -> None:
        run_root = self._current_run_root_for_actions()
        config_path = self.config_path_var.get().strip()
        request = self._watcher_quick_start_request(config_path=config_path, run_root=run_root)
        self._start_watcher_detached(request=request, action_title="watch 시작(기본)")

    def start_watcher_with_options(self) -> None:
        run_root = self._current_run_root_for_actions()
        config_path = self._resolve_watcher_start_config_path(
            config_path=self.config_path_var.get().strip(),
            run_root=run_root,
        )
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch 시작(입력값)에는 RunRoot가 필요합니다.")
            return
        if not config_path:
            messagebox.showwarning("설정 필요", "watch 시작(입력값)에는 ConfigPath가 필요합니다.")
            return
        request = self._build_watcher_start_request_from_controls(
            config_path=config_path,
            run_root=run_root,
            show_error=True,
        )
        if request is None:
            return
        self._start_watcher_detached(request=request, action_title="watch 시작(입력값)")

    def recover_stale_watcher_state(self) -> None:
        run_root = self._current_run_root_for_actions()
        current_paired_status = self.paired_status_data
        workflow = self._watcher_workflow()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch stale 정리에는 RunRoot가 필요합니다.")
            return

        eligibility = self.watcher_controller.start_eligibility(current_paired_status, run_root)
        action_context = WatcherActionContextSnapshot(
            config_path=self.config_path_var.get().strip(),
            run_root=run_root,
            paired_status=current_paired_status,
        )
        if not eligibility.cleanup_allowed:
            messagebox.showwarning("정리 불가", "현재 상태에서는 안전하게 정리할 stale watcher control이 없습니다.")
            self._apply_watcher_panel_update(workflow.build_recover_blocked_update(action_context, eligibility))
            return

        confirmed = messagebox.askyesno(
            "watch stale 정리",
            "오래된 watcher stop/control 흔적을 정리합니다.\nwatcher가 stopped 상태일 때만 안전합니다.\n\n정리할까요?",
            parent=self,
        )
        if not confirmed:
            return

        panel_update = workflow.recover_stale(action_context)
        if not panel_update.ok:
            messagebox.showwarning("정리 실패", panel_update.operator_hint)
            self._apply_watcher_panel_update(panel_update)
            return

        self._apply_watcher_panel_update(panel_update)
        self.after(300, self.refresh_paired_status_only)

    def request_stop_watcher(self) -> None:
        run_root = self._current_run_root_for_actions()
        current_paired_status = self.paired_status_data
        workflow = self._watcher_workflow()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch 정지 요청에는 RunRoot가 필요합니다.")
            return

        eligibility = self.watcher_controller.stop_eligibility(current_paired_status, run_root)
        action_context = WatcherActionContextSnapshot(
            config_path=self.config_path_var.get().strip(),
            run_root=run_root,
            paired_status=current_paired_status,
        )
        if not eligibility.allowed:
            messagebox.showwarning("watch 정지 차단", eligibility.message)
            self._apply_watcher_panel_update(
                workflow.build_stop_blocked_update(
                    action_context,
                    eligibility,
                    action_label="watch 정지 차단",
                )
            )
            return

        if eligibility.warning_codes:
            confirmed = messagebox.askyesno(
                "watch 정지 확인",
                workflow.stop_confirmation_text(eligibility.warning_codes),
                parent=self,
            )
            if not confirmed:
                return

        panel_update = workflow.request_stop(action_context)
        if not panel_update.ok:
            messagebox.showwarning("watch 정지 실패", panel_update.operator_hint)
            self._apply_watcher_panel_update(panel_update)
            return

        self._apply_watcher_panel_update(panel_update)
        self.after(1500, self.refresh_paired_status_only)

    def request_pause_watcher(self) -> None:
        run_root = self._current_run_root_for_actions()
        current_paired_status = self.paired_status_data
        workflow = self._watcher_workflow()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch pause 요청에는 RunRoot가 필요합니다.")
            return

        eligibility = self.watcher_controller.pause_eligibility(current_paired_status, run_root)
        action_context = WatcherActionContextSnapshot(
            config_path=self.config_path_var.get().strip(),
            run_root=run_root,
            paired_status=current_paired_status,
        )
        if not eligibility.allowed:
            messagebox.showwarning("watch pause 차단", eligibility.message)
            self._apply_watcher_panel_update(
                workflow.build_stop_blocked_update(
                    action_context,
                    eligibility,
                    action_label="watch pause 차단",
                )
            )
            return

        panel_update = workflow.request_pause(action_context)
        if not panel_update.ok:
            messagebox.showwarning("watch pause 실패", panel_update.operator_hint)
            self._apply_watcher_panel_update(panel_update)
            return

        self._apply_watcher_panel_update(panel_update)
        self.after(1500, self.refresh_paired_status_only)

    def request_resume_watcher(self) -> None:
        run_root = self._current_run_root_for_actions()
        current_paired_status = self.paired_status_data
        workflow = self._watcher_workflow()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch resume 요청에는 RunRoot가 필요합니다.")
            return

        eligibility = self.watcher_controller.resume_eligibility(current_paired_status, run_root)
        action_context = WatcherActionContextSnapshot(
            config_path=self.config_path_var.get().strip(),
            run_root=run_root,
            paired_status=current_paired_status,
        )
        if not eligibility.allowed:
            messagebox.showwarning("watch resume 차단", eligibility.message)
            self._apply_watcher_panel_update(
                workflow.build_stop_blocked_update(
                    action_context,
                    eligibility,
                    action_label="watch resume 차단",
                )
            )
            return

        panel_update = workflow.request_resume(action_context)
        if not panel_update.ok:
            messagebox.showwarning("watch resume 실패", panel_update.operator_hint)
            self._apply_watcher_panel_update(panel_update)
            return

        self._apply_watcher_panel_update(panel_update)
        self.after(1500, self.refresh_paired_status_only)

    def restart_watcher(self) -> None:
        run_root = self._current_run_root_for_actions()
        config_path = self._resolve_watcher_start_config_path(
            config_path=self.config_path_var.get().strip(),
            run_root=run_root,
        )
        current_paired_status = self.paired_status_data
        workflow = self._watcher_workflow()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch 재시작에는 RunRoot가 필요합니다.")
            return
        if not config_path:
            messagebox.showwarning("설정 필요", "watch 재시작에는 ConfigPath가 필요합니다.")
            return
        restart_request = self._build_watcher_start_request_from_controls(
            config_path=config_path,
            run_root=run_root,
            show_error=True,
        )
        if restart_request is None:
            return

        eligibility = self.watcher_controller.stop_eligibility(current_paired_status, run_root)
        action_context = WatcherActionContextSnapshot(
            config_path=config_path,
            run_root=run_root,
            paired_status=current_paired_status,
        )
        if not eligibility.allowed:
            messagebox.showwarning("watch 재시작 차단", eligibility.message)
            self._apply_watcher_panel_update(
                workflow.build_stop_blocked_update(
                    action_context,
                    eligibility,
                    action_label="watch 재시작 차단",
                )
            )
            return

        if eligibility.warning_codes:
            confirmed = messagebox.askyesno(
                "watch 재시작 확인",
                workflow.restart_confirmation_text(eligibility.warning_codes),
                parent=self,
            )
            if not confirmed:
                return

        current_context = self._snapshot_context(run_root=run_root)

        def worker():
            return workflow.restart(
                WatcherRestartRequest(
                    context=action_context,
                    app_context=current_context,
                    poll_interval_sec=1.0,
                    watcher_request=restart_request,
                )
            )

        def on_success(result) -> object:
            self._apply_watcher_panel_update(result.panel_update)
            return self.refresh_paired_status_only

        def on_failure(exc: Exception) -> str | None:
            if isinstance(exc, WatcherRestartFailure):
                if exc.panel_update.command_text:
                    self.last_command_var.set(exc.panel_update.command_text)
                return exc.panel_update.output_text
            return None

        self.run_background_task(
            state="watch 재시작 중",
            hint="정지 요청, stopped 확인, start 요청, running 확인을 순서대로 진행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="watch 재시작 완료",
            success_hint="paired status와 결과 탭을 새 상태로 다시 읽었습니다.",
            failure_state="watch 재시작 실패",
            failure_hint="watch 상태, control file, 마지막 명령을 확인하세요.",
            on_failure=on_failure,
        )

    def show_watcher_diagnostics(self) -> None:
        diagnostics = self.watcher_controller.diagnostics(self.paired_status_data, self._current_run_root_for_actions())
        recommendation = self._watcher_recommendation()
        text = diagnostics.details
        if recommendation:
            text += "\n\n권장 조치:\n- {0} ({1})".format(recommendation.label, recommendation.detail or recommendation.action_key)
        self.set_text(self.output_text, text)
        self.set_operator_status("watch 진단 표시", diagnostics.hint, "마지막 결과: watch 진단 표시")

    def apply_watcher_recommended_action(self) -> None:
        recommendation = self._watcher_recommendation()
        if recommendation is None:
            messagebox.showinfo("권장 조치 없음", "현재 watcher 진단 기준 권장 조치가 없습니다.")
            return
        if recommendation.action_key == "start_watcher":
            run_root = self._current_run_root_for_actions()
            config_path = self.config_path_var.get().strip()
            request = self._watcher_current_request_from_status(
                config_path=config_path,
                run_root=run_root,
            )
            if request is not None:
                self.load_watcher_start_options_from_status(show_message=False)
                self._start_watcher_detached(request=request, action_title="watch 다시 시작(현재값)")
                return
            self.start_watcher_detached()
            return
        self.handle_dashboard_action(recommendation.action_key)

    def open_watcher_status_file(self) -> None:
        status = self._watcher_runtime_status()
        self._open_path(status.status_path, kind="watch status 파일")

    def open_watcher_audit_log(self) -> None:
        self._open_path(self.watcher_controller.audit_log_path(), kind="watch audit 로그")

    def open_watcher_control_file(self) -> None:
        status = self._watcher_runtime_status()
        self._open_path(status.control_path, kind="watch control 파일")

    def enable_selected_pair(self) -> None:
        pair_id = self._selected_home_pair_id()
        command = self.command_service.build_script_command(
            "enable-pair.ps1",
            config_path=self.config_path_var.get().strip(),
            pair_id=pair_id,
            extra=["-AsJson"],
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            self.set_text(self.output_text, json.dumps(payload, ensure_ascii=False, indent=2))
            self.load_effective_config()

        self.run_background_task(
            state="pair 활성화 중",
            hint=f"{pair_id} 활성 상태를 runtime state 파일에 반영 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="pair 활성화 완료",
            success_hint="홈 카드와 pair 요약을 새 상태로 갱신했습니다.",
            failure_state="pair 활성화 실패",
            failure_hint="pair activation 상태 파일과 출력 JSON을 확인하세요.",
        )

    def disable_selected_pair(self) -> None:
        pair_id = self._selected_home_pair_id()
        reason = simpledialog.askstring("pair 비활성화", f"{pair_id} 비활성 사유를 입력하세요.", parent=self)
        if reason is None:
            return

        command = self.command_service.build_script_command(
            "disable-pair.ps1",
            config_path=self.config_path_var.get().strip(),
            pair_id=pair_id,
            extra=["-Reason", reason, "-AsJson"],
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            self.set_text(self.output_text, json.dumps(payload, ensure_ascii=False, indent=2))
            self.load_effective_config()

        self.run_background_task(
            state="pair 비활성화 중",
            hint=f"{pair_id} 비활성 상태를 runtime state 파일에 반영 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="pair 비활성화 완료",
            success_hint="홈 카드와 pair 요약을 새 상태로 갱신했습니다.",
            failure_state="pair 비활성화 실패",
            failure_hint="pair activation 상태 파일과 출력 JSON을 확인하세요.",
        )

    def set_text(self, widget: tk.Text, value: str) -> None:
        result_channel = ""
        if widget is self.__dict__.get("output_text"):
            result_channel = "작업 출력"
        elif widget is self.__dict__.get("query_output_text"):
            result_channel = "조회 결과"
        if self._has_ui_attr("result_panel_collapsed_var") and result_channel:
            collapsed = bool(self.result_panel_collapsed_var.get())
            simple_mode = bool(self.simple_mode_var.get()) if self._has_ui_attr("simple_mode_var") else False
            if collapsed and simple_mode:
                self.result_panel_has_unseen_update = False
                self.result_panel_collapsed_var.set(False)
                self._apply_result_panel_visibility()
            elif collapsed:
                self.result_panel_has_unseen_update = True
                self._apply_result_panel_visibility()
            else:
                self.result_panel_has_unseen_update = False
        widget.configure(state="normal")
        widget.delete("1.0", "end")
        widget.insert("1.0", value)
        widget.configure(state="disabled")
        if result_channel:
            self._mark_result_panel_content_updated(result_channel, value)

    def set_query_text(self, value: str) -> None:
        if self._has_ui_attr("query_output_text"):
            self.set_text(self.query_output_text, value)
            if self._has_ui_attr("result_notebook") and self._has_ui_attr("query_output_tab"):
                try:
                    self.result_notebook.select(self.query_output_tab)
                except Exception:
                    pass
            return
        if self._has_ui_attr("output_text"):
            self.set_text(self.output_text, value)

    def _query_context_summary(self, context: AppContext | None = None) -> str:
        query_context = context
        if query_context is None:
            try:
                query_context = self._snapshot_context()
            except Exception:
                query_context = None
        return format_query_context_summary(query_context)

    def _append_query_history(self, value: str, *, context: str = "") -> None:
        current_records = self.__dict__.setdefault("query_history_records", [])
        if not isinstance(current_records, list):
            current_records = []
        next_records, entries = append_query_history(
            current_records,
            value=value,
            context=context,
        )
        self.query_history_records = next_records
        summary_entries = entries
        entries = self.__dict__.setdefault("query_history_entries", [])
        entries.clear()
        entries.extend(summary_entries)
        if self._has_ui_attr("query_history_var"):
            self.query_history_var.set("최근 조회: " + " | ".join(entries))

    def set_query_result(self, value: str, *, context: str = "") -> None:
        if self._has_ui_attr("last_query_result_var"):
            self.last_query_result_var.set(value)
        self._append_query_history(value, context=context)

    def run_relay_status(self) -> None:
        self.run_to_output("show-relay-status.ps1", allow_when_busy=True)

    def _resolve_top_target_for_pair(self, pair_id: str) -> str:
        return self.pair_controller.resolve_top_target_for_pair(self.preview_rows, pair_id)

    def run_selected_pair_drill(self) -> None:
        block_reason = self._shared_visible_typed_window_headless_block_reason()
        if block_reason:
            messagebox.showwarning("Headless Drill 차단", block_reason)
            return
        self._set_mode_banner("MODE: Headless Drill", "headless drill / transport closure / 진단 중심으로 작업합니다.")
        pair_id = self.pair_id_var.get().strip()
        if not pair_id:
            messagebox.showwarning("PairId 필요", "PairId 값을 먼저 선택하세요.")
            return
        scope_allowed, scope_detail = self._selected_pair_scope_allowed(action_label="선택 Pair Headless Drill")
        if not scope_allowed:
            messagebox.showwarning("Headless Drill 대기", scope_detail)
            return
        allowed, detail = self._selected_pair_execution_allowed()
        if not allowed:
            messagebox.showwarning("Headless Drill 대기", detail)
            return
        activation = self.get_pair_activation_state(pair_id)
        if activation and not activation.get("EffectiveEnabled", True):
            messagebox.showwarning("Pair 비활성", f"{pair_id}는 현재 비활성 상태입니다.\n사유: {activation.get('DisableReason', '') or '(none)'}")
            return

        initial_target_id = self._resolve_top_target_for_pair(pair_id)
        if not initial_target_id:
            messagebox.showerror("대상 해석 실패", f"{pair_id}의 top target을 찾지 못했습니다.")
            return

        config_path = self.config_path_var.get().strip()
        drill_request = self._watcher_quick_start_request(
            config_path=config_path,
            run_root=self._current_run_root_for_actions(),
        )

        command = self.command_service.build_powershell_file_command(
            str(ROOT / "run-headless-pair-drill.ps1"),
            extra=[
                "-ConfigPath",
                config_path,
                "-PairId",
                pair_id,
                "-InitialTargetId",
                initial_target_id,
                "-MaxForwardCount",
                str(drill_request.max_forward_count),
                "-RunDurationSec",
                str(drill_request.run_duration_sec),
                "-AsJson",
            ],
        )
        if self.run_root_var.get().strip():
            command += ["-RunRoot", self.run_root_var.get().strip()]

        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return run_command(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            self.run_root_var.set(payload.get("RunRoot", ""))
            observed = payload.get("ObservedCounts", {})
            lines = [
                "선택 Pair Headless Drill 완료",
                f"Pair: {payload.get('PairId', '')}",
                f"초기 대상: {payload.get('InitialTargetId', '')}",
                f"RunRoot: {payload.get('RunRoot', '')}",
                f"forward 제한: {payload.get('MaxForwardCount', '') or '없음'}",
                f"run 제한(초): {payload.get('RunDurationSec', '') or '없음'}",
                f"done 개수: {observed.get('DonePresentCount', '')}",
                f"error 개수: {observed.get('ErrorPresentCount', '')}",
                f"forwarded 개수: {observed.get('ForwardedStateCount', '')}",
                f"watcher 상태: {observed.get('WatcherStatus', '')}",
                "",
                "시작 명령:",
                payload.get("Commands", {}).get("Start", ""),
                "",
                "감시 명령:",
                payload.get("Commands", {}).get("Watch", ""),
            ]
            max_forward_count = int(payload.get("MaxForwardCount", 0) or 0)
            if max_forward_count > 0:
                lines.extend(
                    [
                        "",
                        "이 드릴은 watcher 기본 quick start와 같은 forward/run 기준을 사용합니다.",
                        f"연속 무제한 왕복이 아니라 forward {max_forward_count}회까지만 확인합니다.",
                    ]
                )
            self.set_text(self.output_text, "\n".join(lines))
            self.load_effective_config()

            self.last_result_var.set(
                "마지막 결과: pair={0} done={1} error={2} forwarded={3}".format(
                    payload.get("PairId", ""),
                    observed.get("DonePresentCount", ""),
                    observed.get("ErrorPresentCount", ""),
                    observed.get("ForwardedStateCount", ""),
                )
            )

        self.set_text(self.output_text, f"선택 Pair Headless Drill 실행 중...\npair={pair_id}\ninitial={initial_target_id}")
        self.run_background_task(
            state="Headless Drill 실행 중",
            hint=f"{pair_id} 한 쌍을 headless로 실행 중입니다. 완료될 때까지 버튼이 잠깁니다.",
            worker=worker,
            on_success=on_success,
            success_state="Headless Drill 완료",
            success_hint="RunRoot가 자동 반영됐습니다. 페어 상태나 폴더 열기로 결과를 확인하세요.",
            failure_state="Headless Drill 실패",
            failure_hint="출력 영역과 마지막 명령을 확인한 뒤 다시 시도하세요.",
        )

    def run_selected_parallel_pair_drill(self) -> None:
        block_reason = self._shared_visible_typed_window_headless_block_reason()
        if block_reason:
            messagebox.showwarning("Headless Drill 차단", block_reason)
            return
        self._set_mode_banner("MODE: Parallel Headless Drill", "선택 pair들은 병렬, 같은 pair 내부 handoff는 순차로 검사합니다.")
        selected_pair_ids = self._selected_parallel_pair_ids()
        parallel_allowed, parallel_detail = self._selected_parallel_pair_execution_allowed(selected_pair_ids)
        if not parallel_allowed:
            messagebox.showwarning("병렬 Drill 대기", parallel_detail)
            return
        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "Config를 먼저 선택하세요.")
            return
        request = self._build_watcher_start_request_from_controls(
            config_path=config_path,
            run_root=self._current_run_root_for_actions(),
            show_error=True,
        )
        if request is None:
            return

        disabled_pairs: list[str] = []
        for pair_id in selected_pair_ids:
            activation = self.get_pair_activation_state(pair_id)
            if activation and not bool(activation.get("EffectiveEnabled", True)):
                disabled_pairs.append(
                    "{0}({1})".format(pair_id, activation.get("DisableReason", "") or "disabled")
                )
        if disabled_pairs:
            messagebox.showwarning(
                "Pair 비활성",
                "선택된 pair 중 비활성 상태가 있습니다.\n" + "\n".join(disabled_pairs),
            )
            return

        coordinator_repo_root = self.parallel_coordinator_repo_root_var.get().strip() or str((ROOT / "_tmp" / "pair-parallel-coordinator").resolve())
        extra = [
            "-BaseConfigPath",
            config_path,
            "-CoordinatorWorkRepoRoot",
            coordinator_repo_root,
            "-PairMaxRoundtripCount",
            str(request.pair_max_roundtrip_count),
            "-RunDurationSec",
            str(request.run_duration_sec),
        ]
        for pair_id in selected_pair_ids:
            extra.extend(["-PairId", pair_id])
        extra.append("-AsJson")

        command = self.command_service.build_powershell_file_command(
            str(ROOT / "tests" / "Run-ParallelPairScopedHeadlessDrill.ps1"),
            extra=extra,
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return run_command(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            coordinator_run_root = str(payload.get("CoordinatorRunRoot", "") or "").strip()
            if coordinator_run_root:
                self.run_root_var.set(coordinator_run_root)
                self._set_action_context(
                    pair_id=selected_pair_ids[0],
                    run_root=coordinator_run_root,
                    source="parallel-pair-drill",
                )
            if selected_pair_ids:
                self.pair_id_var.set(selected_pair_ids[0])
                self._sync_preview_selection_with_pair(selected_pair_ids[0])
            lines = [
                "선택 pair 병렬 Headless Drill 완료",
                f"Pairs: {', '.join(selected_pair_ids)}",
                f"Coordinator Repo: {payload.get('CoordinatorWorkRepoRoot', '')}",
                f"Coordinator RunRoot: {coordinator_run_root or '(none)'}",
                f"PairMaxRoundtripCount: {payload.get('PairMaxRoundtripCount', '')}",
                f"RunDurationSec: {payload.get('RunDurationSec', '')}",
                "",
            ]
            for row in payload.get("PairRuns", []):
                lines.extend(
                    [
                        "[{0}] watcher={1} done={2} error={3} forwarded={4}".format(
                            row.get("PairId", ""),
                            row.get("WatcherStatus", ""),
                            row.get("DonePresentCount", ""),
                            row.get("ErrorPresentCount", ""),
                            row.get("ForwardedStateCount", ""),
                        ),
                        "repo={0}".format(row.get("WorkRepoRoot", "")),
                        "run={0}".format(row.get("RunRoot", "")),
                        "",
                    ]
                )
            wrapper_status_path = str(payload.get("CoordinatorWrapperStatusPath", "") or "").strip()
            if wrapper_status_path:
                lines.extend(["wrapper-status:", wrapper_status_path])
            self.set_text(self.output_text, "\n".join(lines).rstrip())
            self.refresh_pair_policy_editor()
            self.load_effective_config()
            self.last_result_var.set(
                "마지막 결과: parallel drill pairs={0} coordinator={1}".format(
                    ",".join(selected_pair_ids),
                    coordinator_run_root or "(none)",
                )
            )

        pair_summary = ", ".join(selected_pair_ids)
        self.set_text(
            self.output_text,
            "선택 pair 병렬 Headless Drill 실행 중...\n"
            f"pairs={pair_summary}\n"
            f"coordinator={coordinator_repo_root}",
        )
        self.run_background_task(
            state="병렬 Headless Drill 실행 중",
            hint=f"{pair_summary} pair를 병렬로 실행 중입니다. 같은 pair 내부 handoff만 순차입니다.",
            worker=worker,
            on_success=on_success,
            success_state="병렬 Headless Drill 완료",
            success_hint="Coordinator RunRoot가 현재 컨텍스트로 반영됐습니다. pair 병렬 상태판과 important-summary를 확인하세요.",
            failure_state="병렬 Headless Drill 실패",
            failure_hint="출력 영역과 wrapper-status, 마지막 명령을 확인한 뒤 다시 시도하세요.",
        )

    def run_fixed_pair01_drill(self) -> None:
        block_reason = self._shared_visible_typed_window_headless_block_reason()
        if block_reason:
            messagebox.showwarning("Headless Drill 차단", block_reason)
            return
        self._set_mode_banner("MODE: Headless Drill", "pair01 preset shortcut 기준 headless drill을 실행합니다.")
        activation = self.get_pair_activation_state("pair01")
        if activation and not activation.get("EffectiveEnabled", True):
            messagebox.showwarning("Pair 비활성", f"pair01은 현재 비활성 상태입니다.\n사유: {activation.get('DisableReason', '') or '(none)'}")
            return

        config_path = str(ROOT / "config" / "settings.bottest-live-visible.psd1")
        command = self.command_service.build_powershell_file_command(
            str(ROOT / "run-preset-headless-pair-drill.ps1"),
            extra=["-PairId", "pair01", "-AsJson"],
        )

        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return run_command(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            drill = payload.get("Drill", {})
            observed = drill.get("ObservedCounts", {})
            self.config_path_var.set(config_path)
            self._set_action_context(pair_id="pair01", run_root=payload.get("RunRoot", ""), source="pair01-preset-drill")
            lines = [
                "pair01 Preset Drill 완료",
                f"Config: {payload.get('ConfigPath', '')}",
                f"RunRoot: {payload.get('RunRoot', '')}",
                f"done 개수: {observed.get('DonePresentCount', '')}",
                f"error 개수: {observed.get('ErrorPresentCount', '')}",
                f"forwarded 개수: {observed.get('ForwardedStateCount', '')}",
                "",
                "preview 저장:",
            ]
            for item in payload.get("RenderedMessages", []):
                lines.append(f"- {item.get('TargetId', '')}: {item.get('OutputRoot', '')}")
            self.set_text(self.output_text, "\n".join(lines))
            self.load_effective_config()
            self.last_result_var.set(
                "마지막 결과: pair01 done={0} error={1} forwarded={2}".format(
                    observed.get("DonePresentCount", ""),
                    observed.get("ErrorPresentCount", ""),
                    observed.get("ForwardedStateCount", ""),
                )
            )

        self.set_text(self.output_text, "pair01 Preset Drill 실행 중...")
        self.run_background_task(
            state="pair01 Preset Drill 실행 중",
            hint="preset shortcut이 generic preset runner를 통해 pair01 한 번 왕복 드릴을 실행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="pair01 Preset Drill 완료",
            success_hint="RunRoot와 preview 출력이 자동 반영됐습니다.",
            failure_state="pair01 Preset Drill 실패",
            failure_hint="출력 영역과 마지막 명령을 확인하세요.",
        )

    def run_paired_status(self) -> None:
        self.run_to_output("show-paired-exchange-status.ps1", allow_when_busy=True)

    def run_paired_summary(self) -> None:
        self.run_to_output("show-paired-run-summary.ps1", allow_when_busy=True)

    def _important_summary_path(self, file_name: str = "important-summary.txt") -> str:
        run_root = self._current_run_root_for_actions()
        if not run_root:
            return ""
        return str(Path(run_root) / ".state" / file_name)

    def open_important_summary_text(self) -> None:
        path_value = self._important_summary_path()
        if not path_value:
            messagebox.showwarning("RunRoot 필요", "RunRoot 값을 먼저 입력하거나 선택하세요.")
            return
        if not Path(path_value).exists():
            messagebox.showwarning(
                "important-summary 없음",
                "먼저 runroot 요약을 실행해 important-summary.txt를 생성하세요.\n" + path_value,
            )
            return
        self._open_path(path_value, kind="important-summary.txt")
        self.set_text(self.output_text, f"important-summary 열기:\n{path_value}")

    def run_visibility_check(self) -> None:
        current_context = self._effective_refresh_context()
        self.last_command_var.set(self._runtime_refresh_command_preview(current_context))

        def worker():
            return self.refresh_controller.refresh_runtime(current_context)

        def on_success(runtime_result) -> None:
            self._apply_runtime_refresh_result(runtime_result)
            self.set_text(
                self.output_text,
                self._format_visibility_status_report(
                    runtime_result.visibility_status,
                    relay_payload=runtime_result.relay_status,
                    include_json=True,
                ),
            )
            self.last_result_var.set(
                self._visibility_last_result_text(
                    runtime_result.visibility_status,
                    relay_payload=runtime_result.relay_status,
                )
            )

        self.run_background_task(
            state="입력 점검 실행 중",
            hint="runtime map과 실제 입력 가능 상태를 다시 확인하는 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="입력 점검 완료",
            success_hint="입력 가능 상태와 8창 보드를 갱신했습니다.",
            failure_state="입력 점검 실패",
            failure_hint="출력 영역의 오류와 마지막 명령을 확인하세요.",
        )

    def run_headless_readiness(self) -> None:
        self.run_to_output(
            "check-headless-exec-readiness.ps1",
            require_run_root=True,
            allow_when_busy=True,
        )

    def run_effective_json(self) -> None:
        self.run_to_output(
            "show-effective-config.ps1",
            extra=["-AsJson"],
            require_pair=False,
            allow_when_busy=True,
        )

    def run_to_output(
        self,
        script_name: str,
        *,
        extra: list[str] | None = None,
        require_run_root: bool = False,
        require_pair: bool = False,
        refresh_after: bool = False,
        refresh_scope: str = "",
        allow_when_busy: bool = False,
    ) -> None:
        current_context = self._snapshot_context()
        if require_run_root and not current_context.run_root:
            messagebox.showwarning("RunRoot 필요", "RunRoot 값을 먼저 입력하세요.")
            return
        if require_pair and not current_context.pair_id:
            messagebox.showwarning("PairId 필요", "PairId 값을 먼저 입력하세요.")
            return

        def worker() -> subprocess.CompletedProcess[str]:
            return self.status_service.run_script(
                script_name,
                current_context,
                extra=extra,
                run_root_override=current_context.run_root,
                pair_id_override=current_context.pair_id,
                target_id_override=current_context.target_id,
            )

        preview_command = self.command_service.build_script_command(
            script_name=script_name,
            config_path=current_context.config_path,
            run_root=current_context.run_root,
            pair_id=current_context.pair_id,
            target_id=current_context.target_id,
            extra=extra,
        )
        self.last_command_var.set(subprocess.list2cmdline(preview_command))

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            output = completed.stdout.strip()
            if completed.stderr.strip():
                output += ("\n\nSTDERR:\n" + completed.stderr.strip())
            if allow_when_busy:
                self.set_query_text(output or "(no output)")
                self.set_query_result(
                    f"마지막 조회: {script_name} 완료",
                    context=self._query_context_summary(current_context),
                )
            else:
                self.set_text(self.output_text, output or "(no output)")
                self.last_result_var.set(f"마지막 결과: {script_name} 실행 완료")
            if refresh_after:
                if refresh_scope == "runtime":
                    self.refresh_runtime_status_only()
                elif refresh_scope == "paired":
                    self.refresh_paired_status_only()
                else:
                    self.load_effective_config()

        if allow_when_busy:
            self.set_query_result(
                f"마지막 조회: {script_name} 시작",
                context=self._query_context_summary(current_context),
            )
            self.run_read_only_background_task(
                label=script_name,
                worker=worker,
                on_success=on_success,
            )
            return

        self.run_background_task(
            state=f"{script_name} 실행 중",
            hint=f"{script_name} 실행 중입니다. 완료될 때까지 버튼이 잠깁니다.",
            worker=worker,
            on_success=on_success,
            success_state="명령 실행 완료",
            success_hint="출력 영역에서 결과를 확인하세요.",
            failure_state="명령 실행 실패",
            failure_hint="출력 영역의 오류와 마지막 명령을 확인하세요.",
        )


def main() -> None:
    panel = RelayOperatorPanel()
    panel.mainloop()


if __name__ == "__main__":
    main()
