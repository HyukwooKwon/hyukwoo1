from __future__ import annotations

import json
import os
import re
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, simpledialog, ttk

from relay_panel_artifact_controller import ArtifactTabController
from relay_panel_artifacts import ArtifactQuery, ArtifactService, PairArtifactSummary, TargetArtifactState
from relay_panel_home_controller import HomeController
from relay_panel_message_config import DEFAULT_SLOT_ORDER, MessageConfigService, SCOPED_SLOT_LABELS
from relay_panel_models import ActionModel, AppContext, DashboardRawBundle, IssueModel, PairSummaryModel, PanelStateModel
from relay_panel_pair_controller import PairController
from relay_panel_refresh_controller import PanelRefreshController
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
from relay_panel_watcher_controller import WatcherController
from relay_panel_watchers import (
    WatcherControlResult,
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
RUN_ROOT_CONTEXT_REFRESH_DEBOUNCE_MS = 250


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
        self.dashboard_aggregator = DashboardAggregator()
        self.artifact_service = ArtifactService()
        self.artifact_controller = ArtifactTabController(self.artifact_service)
        self.home_controller = HomeController()
        self.pair_controller = PairController(self.artifact_service)
        self.message_config_service = MessageConfigService(self.command_service)
        self.watcher_service = WatcherService()
        self.watcher_controller = WatcherController(self.watcher_service)
        self.config_path_var = tk.StringVar(value=self._default_config())
        self.run_root_label_var = tk.StringVar(value="RunRoot")
        self.run_root_var = tk.StringVar()
        self.run_root_status_var = tk.StringVar(value="selected")
        self.pair_id_var = tk.StringVar(value="pair01")
        self.target_id_var = tk.StringVar()
        self.artifact_pair_filter_var = tk.StringVar(value="")
        self.artifact_target_filter_var = tk.StringVar(value="")
        self.artifact_path_kind_var = tk.StringVar(value="summary")
        self.artifact_latest_only_var = tk.BooleanVar(value=False)
        self.artifact_include_missing_var = tk.BooleanVar(value=True)
        self.last_command_var = tk.StringVar(value="")
        self.operator_status_var = tk.StringVar(value="대기 중")
        self.operator_hint_var = tk.StringVar(value="설정을 고른 뒤 미리보기를 불러오고, Pair를 선택한 다음 선택된 Pair 드릴 실행을 누르세요.")
        self.last_result_var = tk.StringVar(value="마지막 결과: (없음)")
        self.simple_mode_var = tk.BooleanVar(value=False)
        self.home_context_var = tk.StringVar(value="Lane: -")
        self.home_updated_at_var = tk.StringVar(value="마지막 갱신: -")
        self.home_overall_var = tk.StringVar(value="상태: -")
        self.home_overall_detail_var = tk.StringVar(value="안내: 상태를 불러오면 준비 단계와 다음 조치를 여기서 보여줍니다.")
        self.home_pair_detail_var = tk.StringVar(value="Pair 요약을 불러오면 여기서 선택한 pair의 상태를 간단히 보여줍니다.")
        self.artifact_status_var = tk.StringVar(value="결과 / 산출물 탭에서 현재 RunRoot 기준 상태를 확인할 수 있습니다.")
        self.artifact_status_base_text = "결과 / 산출물 탭에서 현재 RunRoot 기준 상태를 확인할 수 있습니다."
        self.board_status_var = tk.StringVar(value="8창 보드에서 target별 attach / 입력 가능 / pair 매칭을 한눈에 확인할 수 있습니다.")
        self.message_editor_status_var = tk.StringVar(value="설정 편집기에서 고정문구, override 블록, 슬롯 순서를 수정할 수 있습니다.")
        self.message_preview_status_var = tk.StringVar(value="저장 전 편집본 preview는 '미리보기 갱신'으로 다시 계산합니다.")
        self.message_block_filter_var = tk.StringVar(value="")
        self.message_block_changed_only_var = tk.BooleanVar(value=False)
        self.message_block_filter_status_var = tk.StringVar(value="블록 표시: 0/0")
        self.message_block_badges_var = tk.StringVar(value="")
        self.message_block_hint_var = tk.StringVar(value="")
        self.message_template_var = tk.StringVar(value="Initial")
        self.message_scope_label_var = tk.StringVar(value="글로벌 Prefix")
        self.message_scope_id_var = tk.StringVar(value="")
        self.message_target_suffix_var = tk.StringVar(value="")
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
        self.message_backup_paths: list[Path] = []
        self.long_task_widgets: list[tk.Widget] = []
        self.home_card_vars: dict[str, dict[str, tk.StringVar]] = {}
        self.home_stage_vars: dict[str, dict[str, tk.StringVar]] = {}
        self.home_stage_buttons: dict[str, ttk.Button] = {}
        self._busy = False
        self.panel_opened_at_utc = self._utc_now_iso()
        self.window_launch_anchor_utc = self.panel_opened_at_utc
        self.run_root_context_refresh_after_id: str | None = None
        self.run_root_var.trace_add("write", self._on_run_root_value_changed)

        self._load_artifact_source_memory()
        self._build_ui()
        self.load_effective_config()

    def _has_ui_attr(self, name: str) -> bool:
        try:
            object.__getattribute__(self, name)
        except (AttributeError, RecursionError):
            return False
        return True

    def _default_config(self) -> str:
        presets = existing_config_presets()
        if presets:
            return presets[0]
        return str(ROOT / "config" / "settings.psd1")

    def _current_context(self) -> AppContext:
        return AppContext(
            config_path=self.config_path_var.get().strip(),
            run_root=self._current_run_root_for_actions(),
            pair_id=self._selected_pair_id(),
            target_id=self.target_id_var.get().strip(),
        )

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
        snapshot = self._run_root_timing_snapshot(action_run_root)
        threshold = int(snapshot.get("ThresholdSec", 1800) or 1800)
        age_seconds = snapshot.get("AgeSeconds", None)
        age_text = ""
        if isinstance(age_seconds, (int, float)):
            age_text = "{0:.0f}s/{1}s".format(float(age_seconds), threshold)

        if not action_run_root:
            self.run_root_label_var.set("RunRoot")
            self.run_root_status_var.set("없음")
            return

        if self._run_root_is_stale(action_run_root):
            self.run_root_label_var.set("RunRoot [stale]")
            self.run_root_status_var.set("stale {0}".format(age_text or f"threshold={threshold}s"))
            return

        if explicit_run_root:
            self.run_root_label_var.set("RunRoot [override]")
            self.run_root_status_var.set("override {0}".format(age_text or "selected"))
            return

        self.run_root_label_var.set("RunRoot")
        self.run_root_status_var.set("selected {0}".format(age_text or "latest"))

    def _panel_runtime_hints(self) -> dict[str, object]:
        run_context = (self.effective_data or {}).get("RunContext", {}) or {}
        selected_run_root = str(run_context.get("SelectedRunRoot", "") or "").strip()
        action_run_root = self._current_run_root_for_actions()
        explicit_run_root = self.run_root_var.get().strip()
        action_run_root_uses_override = bool(explicit_run_root and explicit_run_root != selected_run_root)
        action_run_root_snapshot = self._run_root_timing_snapshot(action_run_root)
        return {
            "PanelOpenedAtUtc": str(self.__dict__.get("panel_opened_at_utc", "") or ""),
            "WindowLaunchAnchorUtc": str(self.__dict__.get("window_launch_anchor_utc", "") or ""),
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
        run_context = (self.effective_data or {}).get("RunContext", {}) or {}
        selected_run_root = str(run_context.get("SelectedRunRoot", "") or "").strip()
        explicit_run_root = self.run_root_var.get().strip()
        if explicit_run_root and explicit_run_root != selected_run_root:
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
            mismatch_message="선택 Pair 실행 전 pair 활성화가 필요합니다.",
        )

    def _runtime_active_pair_ids(self) -> list[str]:
        runtime = ((self.relay_status_data or {}).get("Runtime", {}) or {})
        raw_value = runtime.get("ActivePairIds", [])
        if isinstance(raw_value, list):
            return [str(item) for item in raw_value if str(item)]
        single = str(raw_value or "").strip()
        return [single] if single else []

    def _selected_pair_scope_allowed(self, *, action_label: str) -> tuple[bool, str]:
        pair_id = self._selected_pair_id()
        if not pair_id:
            return False, "PairId 값을 먼저 선택하세요."

        runtime = ((self.relay_status_data or {}).get("Runtime", {}) or {})
        if not bool(runtime.get("PartialReuse", False)):
            return True, ""

        active_pairs = self._runtime_active_pair_ids()
        if not active_pairs:
            return False, f"{action_label} 차단: 현재 partial reuse session의 active pair를 확인하지 못했습니다."
        if pair_id in active_pairs:
            return True, ""
        return False, "{0} 차단: {1}는 현재 session partial reuse 범위 밖입니다. active={2}".format(
            action_label,
            pair_id,
            ", ".join(active_pairs),
        )

    def _apply_active_pair_selection(self, active_pairs: list[str]) -> bool:
        normalized_pairs = [str(item) for item in active_pairs if str(item)]
        if not normalized_pairs:
            return False

        current_pair = self._selected_pair_id()
        if current_pair in normalized_pairs:
            return False

        next_pair = normalized_pairs[0]
        self.pair_id_var.set(next_pair)
        top_target_id = ""
        if "pair_controller" in self.__dict__ and "preview_rows" in self.__dict__:
            top_target_id = self._resolve_top_target_for_pair(next_pair)
        if top_target_id:
            self.target_id_var.set(top_target_id)
        if "home_pair_tree" in self.__dict__:
            self._sync_home_pair_selection(next_pair)
        if "_sync_preview_selection_with_pair" in self.__dict__ or "row_tree" in self.__dict__:
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

    def _board_status_text(self, *, items: list[dict[str, str]], selected_target: str, selected_pair: str) -> str:
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
        runtime_result = self.refresh_controller.refresh_runtime(self._current_context())
        self._apply_runtime_refresh_result(runtime_result)

    def _apply_runtime_refresh_result(self, runtime_result) -> None:
        self.relay_status_data = runtime_result.relay_status
        self.visibility_status_data = runtime_result.visibility_status
        self._coerce_selected_pair_into_runtime_scope()
        self.rebuild_panel_state()
        self.render_target_board()
        self.update_pair_button_states()

    def _runtime_refresh_command_preview(self) -> str:
        context = self._current_context()
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
            self.paired_status_data = None
            self.paired_status_error = ""
            self.rebuild_panel_state()
            self.render_target_board()
            if refresh_artifacts:
                self.refresh_artifacts_tab()
            self.update_pair_button_states()
            return

        paired_result = self.refresh_controller.refresh_paired(self._current_context(), run_root=run_root)
        self.paired_status_data = paired_result.paired_status
        self.paired_status_error = paired_result.paired_status_error
        self.rebuild_panel_state()
        self.render_target_board()
        if refresh_artifacts:
            self.refresh_artifacts_tab()
        self.update_pair_button_states()

    def refresh_quick_status(self) -> None:
        try:
            quick_result = self.refresh_controller.refresh_quick(self._current_context())
            self.relay_status_data = quick_result.runtime.relay_status
            self.visibility_status_data = quick_result.runtime.visibility_status
            self.paired_status_data = quick_result.paired.paired_status
            self.paired_status_error = quick_result.paired.paired_status_error
            self.rebuild_panel_state()
            self.render_target_board()
            self.update_pair_button_states()
        except Exception as exc:
            messagebox.showerror("빠른 새로고침 실패", str(exc))
            self.set_operator_status("빠른 새로고침 실패", "부분 상태 갱신에 실패했습니다.", f"마지막 결과: 실패 ({exc})")
            return

        result_text = "마지막 결과: 빠른 새로고침 완료"
        if self.paired_status_error:
            result_text += " / pair-status 일부 생략"
        self.set_operator_status("빠른 새로고침 완료", "relay/visibility/paired 상태만 다시 읽었습니다. 결과 탭 산출물은 건드리지 않았습니다.", result_text)

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
        self.set_operator_status("결과 새로고침 완료", "현재 RunRoot 기준 paired status와 산출물을 다시 읽었습니다.", result_text)

    def toggle_simple_mode(self) -> None:
        if self.notebook is None:
            return
        if self.simple_mode_var.get():
            if self._has_ui_attr("ops_tab"):
                self.notebook.hide(self.ops_tab)
            if self._has_ui_attr("snapshots_tab"):
                self.notebook.hide(self.snapshots_tab)
            self.set_operator_status("간단 모드", "홈, 8창 보드, 설정 편집, 산출물 중심으로 단순화했습니다.")
        else:
            if self._has_ui_attr("ops_tab"):
                self.notebook.add(self.ops_tab, text="원문 / 진단")
            if self._has_ui_attr("snapshots_tab"):
                self.notebook.add(self.snapshots_tab, text="스냅샷")
            self.set_operator_status("전체 모드", "고급 진단 탭까지 다시 표시했습니다.")

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
        current_pair_id = self.pair_id_var.get().strip() or self._selected_pair_id()
        current_role_name = str(preview_row.get("RoleName", "") or "")
        current_target_id = self.target_id_var.get().strip() or str(preview_row.get("TargetId", "") or "")
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
        target_id = self.target_id_var.get().strip()
        pair_id = self.pair_id_var.get().strip()
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
        output_files = row.get("OutputFiles", {}) or {}
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
                f"- summary.txt: {output_files.get('SummaryPath', '') or row.get('SourceSummaryPath', '') or '(없음)'}",
                f"- review.zip: {output_files.get('ReviewZipPath', '') or row.get('SourceReviewZipPath', '') or '(없음)'}",
                f"- publish.ready.json: {output_files.get('PublishReadyPath', '') or row.get('PublishReadyPath', '') or '(없음)'}",
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
        output_files = row.get("OutputFiles", {}) or {}
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
                f"- summary.txt: {output_files.get('SummaryPath', '') or row.get('SourceSummaryPath', '') or '(없음)'}",
                f"- review.zip: {output_files.get('ReviewZipPath', '') or row.get('SourceReviewZipPath', '') or '(없음)'}",
                f"- publish.ready.json: {output_files.get('PublishReadyPath', '') or row.get('PublishReadyPath', '') or '(없음)'}",
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
        }

    def _apply_message_editor_view_state(self, state: dict[str, object]) -> None:
        self.message_scope_label_var.set(str(state["scope_label"]))
        self.message_scope_id_var.set(str(state["scope_id"]))
        self.message_scope_id_combo.configure(values=list(state["scope_id_values"]), state=str(state["scope_id_combo_state"]))
        self.target_fixed_combo.configure(values=list(state["target_ids"]))
        self.message_target_suffix_var.set(str(state["selected_target_suffix_id"]))

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
                }
            )
        return items

    def render_target_board(self) -> None:
        if not self._has_ui_attr("board_grid"):
            return
        items = self._target_board_items()
        selected_target = self.target_id_var.get().strip()
        selected_pair = self._selected_pair_id()
        self.board_status_var.set(
            self._board_status_text(items=items, selected_target=selected_target, selected_pair=selected_pair)
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
        self.target_id_var.set(target_id)
        if pair_id:
            self.pair_id_var.set(pair_id)
        role_name = ""
        matched = False
        for index, row in enumerate(self.preview_rows):
            if row.get("TargetId", "") == target_id:
                role_name = str(row.get("RoleName", "") or "")
                self.row_tree.selection_set(str(index))
                self.on_row_selected()
                matched = True
                break
        if not matched:
            self._sync_preview_selection_with_pair(self._selected_pair_id())
            self.render_message_editor()
            for row in self.preview_rows:
                if row.get("TargetId", "") == target_id:
                    role_name = str(row.get("RoleName", "") or "")
                    break
        self._apply_message_filter_reset_policy("board_target_change")
        self._apply_editor_context_for_target(pair_id=pair_id or self._selected_pair_id(), role_name=role_name, target_id=target_id)
        self.render_message_editor()
        if self.notebook is not None and self._has_ui_attr("editor_tab"):
            self.notebook.select(self.editor_tab)
        self.rebuild_panel_state()

    def _build_ui(self) -> None:
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)

        controls = ttk.Frame(self, padding=10)
        controls.grid(row=0, column=0, sticky="ew")
        controls.columnconfigure(1, weight=1)
        controls.columnconfigure(5, weight=0)
        controls.columnconfigure(6, weight=0)

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

        ttk.Label(controls, textvariable=self.run_root_label_var).grid(row=1, column=0, sticky="w", padx=(0, 8), pady=(8, 0))
        ttk.Entry(controls, textvariable=self.run_root_var).grid(row=1, column=1, sticky="ew", pady=(8, 0))
        ttk.Label(controls, textvariable=self.run_root_status_var).grid(row=1, column=2, sticky="w", padx=(8, 0), pady=(8, 0))
        ttk.Button(controls, text="입력 비우기", command=self.clear_run_root_input).grid(row=1, column=3, sticky="ew", padx=(8, 0), pady=(8, 0))
        ttk.Label(controls, text="Pair").grid(row=1, column=4, sticky="e", padx=(8, 8), pady=(8, 0))
        ttk.Combobox(controls, textvariable=self.pair_id_var, values=["", "pair01", "pair02", "pair03", "pair04"], width=12).grid(row=1, column=5, sticky="ew", pady=(8, 0))
        ttk.Label(controls, text="대상").grid(row=1, column=6, sticky="e", padx=(12, 8), pady=(8, 0))
        ttk.Combobox(controls, textvariable=self.target_id_var, values=["", "target01", "target02", "target03", "target04", "target05", "target06", "target07", "target08"], width=12).grid(row=1, column=7, sticky="ew", pady=(8, 0))

        ttk.Label(controls, text="마지막 명령").grid(row=2, column=0, sticky="w", padx=(0, 8), pady=(8, 0))
        ttk.Entry(controls, textvariable=self.last_command_var, state="readonly").grid(row=2, column=1, columnspan=5, sticky="ew", pady=(8, 0))
        ttk.Button(controls, text="명령 복사", command=self.copy_last_command).grid(row=2, column=6, sticky="ew", pady=(8, 0), padx=(8, 0))

        status_frame = ttk.LabelFrame(controls, text="운영 상태", padding=8)
        status_frame.grid(row=3, column=0, columnspan=7, sticky="ew", pady=(10, 0))
        status_frame.columnconfigure(1, weight=1)
        ttk.Label(status_frame, text="상태").grid(row=0, column=0, sticky="w", padx=(0, 8))
        ttk.Label(status_frame, textvariable=self.operator_status_var).grid(row=0, column=1, sticky="w")
        ttk.Label(status_frame, text="안내").grid(row=1, column=0, sticky="nw", padx=(0, 8), pady=(6, 0))
        ttk.Label(status_frame, textvariable=self.operator_hint_var, wraplength=1100, justify="left").grid(row=1, column=1, sticky="w", pady=(6, 0))
        ttk.Label(status_frame, textvariable=self.last_result_var, wraplength=1100, justify="left").grid(row=2, column=0, columnspan=2, sticky="w", pady=(6, 0))

        notebook = ttk.Notebook(self)
        notebook.grid(row=1, column=0, sticky="nsew", padx=10, pady=(0, 10))
        self.notebook = notebook

        home_tab = ttk.Frame(notebook, padding=10)
        home_tab.columnconfigure(0, weight=1)
        home_tab.rowconfigure(4, weight=1)
        notebook.add(home_tab, text="홈")

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
        for idx, key_title in enumerate(
            [
                ("windows", "세션 창 준비"),
                ("attach", "Attach 상태"),
                ("visibility", "입력 가능"),
                ("router", "라우터"),
                ("runroot", "RunRoot"),
                ("warning", "경고"),
            ]
        ):
            key, title = key_title
            cards_frame.columnconfigure(idx, weight=1)
            frame = ttk.LabelFrame(cards_frame, text=title, padding=8)
            frame.grid(row=0, column=idx, sticky="nsew", padx=(0, 8) if idx < 5 else (0, 0))
            value_var = tk.StringVar(value="-")
            detail_var = tk.StringVar(value="-")
            ttk.Label(frame, textvariable=value_var, font=("Segoe UI", 12, "bold")).grid(row=0, column=0, sticky="w")
            ttk.Label(frame, textvariable=detail_var, wraplength=180, justify="left").grid(row=1, column=0, sticky="w", pady=(4, 0))
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
                ("pair_action", "5. Pair 실행 준비", "선택 Pair 실행"),
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
            columns=("pair", "targets", "enabled", "latest", "zip", "fail"),
            show="headings",
            height=6,
        )
        for column, heading, width in (
            ("pair", "Pair", 90),
            ("targets", "Targets", 180),
            ("enabled", "활성", 70),
            ("latest", "상태", 200),
            ("zip", "Zip", 70),
            ("fail", "Fail", 70),
        ):
            self.home_pair_tree.heading(column, text=heading)
            self.home_pair_tree.column(column, width=width, stretch=(column in {"targets", "latest"}))
        self.home_pair_tree.grid(row=0, column=0, sticky="nsew")
        self.home_pair_tree.bind("<<TreeviewSelect>>", self.on_home_pair_selected)

        pair_actions = ttk.Frame(pair_frame)
        pair_actions.grid(row=1, column=0, sticky="ew", pady=(8, 0))
        for idx, (label, callback, attr_name) in enumerate(
            [
                ("선택 Pair 반영", self.apply_selected_home_pair, "home_apply_pair_button"),
                ("선택 Pair 실행", self.run_selected_pair_drill, "home_run_pair_button"),
                ("pair 활성화", self.enable_selected_pair, "home_enable_pair_button"),
                ("pair 비활성화", self.disable_selected_pair, "home_disable_pair_button"),
                ("watch 시작", self.start_watcher_detached, "home_start_watch_button"),
                ("Pair 상태 보기", self.run_paired_status, "home_pair_status_button"),
                ("runroot 요약", self.run_paired_summary, "home_pair_summary_button"),
                ("준비 전체 실행", self.run_prepare_all, "home_prepare_all_button"),
                ("기존 8창 재사용", self.reuse_existing_windows, "home_reuse_windows_button"),
                ("열린 pair 재사용", self.reuse_active_pairs, "home_reuse_pairs_button"),
            ]
        ):
            button = ttk.Button(pair_actions, text=label, command=callback)
            button.grid(row=0, column=idx, padx=(0, 8))
            self.long_task_widgets.append(button)
            setattr(self, attr_name, button)
        ttk.Label(pair_frame, textvariable=self.home_pair_detail_var, wraplength=1200, justify="left").grid(row=2, column=0, sticky="w", pady=(8, 0))

        preview_tab = ttk.Frame(notebook, padding=10)
        preview_tab.columnconfigure(0, weight=1)
        preview_tab.columnconfigure(1, weight=2)
        preview_tab.rowconfigure(1, weight=1)
        preview_tab.rowconfigure(2, weight=1)
        notebook.add(preview_tab, text="설정 / 문구")

        self.summary_text = tk.Text(preview_tab, height=10, wrap="word")
        self.summary_text.grid(row=0, column=0, columnspan=2, sticky="nsew")
        self.summary_text.configure(state="disabled")

        preview_actions = ttk.Frame(preview_tab)
        preview_actions.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        for idx, (label, callback) in enumerate(
            [
                ("미리보기 JSON 저장", self.save_effective_json),
                ("선택 행 문구 JSON/TXT 저장", self.export_selected_row_messages),
                ("대상 폴더 열기", self.open_selected_target_folder),
                ("검토 폴더 열기", self.open_selected_review_folder),
                ("summary 경로 복사", self.copy_selected_summary_path),
            ]
        ):
            ttk.Button(preview_actions, text=label, command=callback).grid(row=0, column=idx, padx=(0, 8))

        self.row_tree = ttk.Treeview(
            preview_tab,
            columns=("pair", "role", "target", "partner"),
            show="headings",
            height=16,
        )
        for column, heading, width in (
            ("pair", "Pair", 100),
            ("role", "역할", 90),
            ("target", "대상", 110),
            ("partner", "상대", 110),
        ):
            self.row_tree.heading(column, text=heading)
            self.row_tree.column(column, width=width, stretch=False)
        self.row_tree.grid(row=2, column=0, rowspan=2, sticky="nsew", pady=(10, 0), padx=(0, 10))
        self.row_tree.bind("<<TreeviewSelect>>", self.on_row_selected)

        right_side = ttk.Notebook(preview_tab)
        right_side.grid(row=2, column=1, rowspan=2, sticky="nsew", pady=(10, 0))

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

        board_grid = tk.Frame(board_tab, bg="#f3f4f6")
        board_grid.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
        self.board_grid = board_grid
        for row in range(2):
            board_grid.rowconfigure(row, weight=1)
        for column in range(4):
            board_grid.columnconfigure(column, weight=1)

        editor_tab = ttk.Frame(notebook, padding=10)
        editor_tab.columnconfigure(0, weight=2)
        editor_tab.columnconfigure(1, weight=3)
        editor_tab.rowconfigure(1, weight=1)
        notebook.add(editor_tab, text="고정문구 / 순서 편집")
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
        ttk.Button(editor_actions, text="저장 + 새로고침", command=self.save_message_editor).grid(row=0, column=7, padx=(0, 8))
        ttk.Button(editor_actions, text="마지막 백업 롤백", command=self.rollback_message_editor).grid(row=0, column=8, padx=(0, 8))
        ttk.Label(editor_actions, textvariable=self.message_editor_status_var, wraplength=520, justify="left").grid(row=0, column=9, sticky="w")
        ttk.Label(editor_actions, textvariable=self.message_preview_status_var, wraplength=1180, justify="left").grid(row=1, column=0, columnspan=10, sticky="w", pady=(8, 0))

        editor_left = ttk.Frame(editor_tab)
        editor_left.grid(row=1, column=0, sticky="nsew", padx=(0, 10))
        editor_left.columnconfigure(0, weight=1)
        editor_left.rowconfigure(2, weight=1)
        editor_left.rowconfigure(4, weight=1)

        editor_scope = ttk.LabelFrame(editor_left, text="편집 문맥", padding=8)
        editor_scope.grid(row=0, column=0, sticky="ew")
        ttk.Label(editor_scope, text="메시지 종류").grid(row=0, column=0, sticky="w")
        self.message_template_combo = ttk.Combobox(editor_scope, textvariable=self.message_template_var, values=["Initial", "Handoff"], state="readonly", width=12)
        self.message_template_combo.grid(row=0, column=1, sticky="w", padx=(8, 16))
        ttk.Label(editor_scope, text="연동 범위").grid(row=0, column=2, sticky="w")
        self.message_scope_combo = ttk.Combobox(editor_scope, textvariable=self.message_scope_label_var, values=[label for label, _kind in MESSAGE_SCOPE_OPTIONS], state="readonly", width=16)
        self.message_scope_combo.grid(row=0, column=3, sticky="w", padx=(8, 16))
        ttk.Label(editor_scope, text="대상 ID").grid(row=0, column=4, sticky="w")
        self.message_scope_id_combo = ttk.Combobox(editor_scope, textvariable=self.message_scope_id_var, values=[""], state="readonly", width=16)
        self.message_scope_id_combo.grid(row=0, column=5, sticky="w", padx=(8, 0))

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

        block_frame = ttk.LabelFrame(editor_left, text="블록 편집", padding=8)
        block_frame.grid(row=2, column=0, sticky="nsew", pady=(10, 0))
        block_frame.columnconfigure(0, weight=1)
        block_frame.rowconfigure(2, weight=1)
        block_frame.rowconfigure(3, weight=1)
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
        ttk.Label(block_filter_row, textvariable=self.message_block_filter_status_var, justify="left").grid(row=1, column=0, columnspan=4, sticky="w", pady=(6, 0))
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
        self.message_block_text = scrolledtext.ScrolledText(block_frame, wrap="word", height=6)
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
        fixed_frame.columnconfigure(1, weight=1)
        fixed_frame.columnconfigure(3, weight=1)
        fixed_frame.rowconfigure(1, weight=1)
        fixed_frame.rowconfigure(3, weight=1)
        ttk.Label(fixed_frame, text="기본 고정문구").grid(row=0, column=0, sticky="w")
        self.default_fixed_text = scrolledtext.ScrolledText(fixed_frame, wrap="word", height=4)
        self.default_fixed_text.grid(row=1, column=0, columnspan=2, sticky="nsew", pady=(6, 0), padx=(0, 10))
        ttk.Button(fixed_frame, text="기본 고정문구 반영", command=self.apply_default_fixed_suffix).grid(row=2, column=0, sticky="w", pady=(8, 0))
        ttk.Label(fixed_frame, text="Target 고정문구 대상").grid(row=0, column=2, sticky="w")
        self.target_fixed_combo = ttk.Combobox(fixed_frame, textvariable=self.message_target_suffix_var, values=[""], state="readonly", width=16)
        self.target_fixed_combo.grid(row=0, column=3, sticky="w", padx=(8, 0))
        self.target_fixed_text = scrolledtext.ScrolledText(fixed_frame, wrap="word", height=4)
        self.target_fixed_text.grid(row=1, column=2, columnspan=2, sticky="nsew", pady=(6, 0))
        ttk.Button(fixed_frame, text="Target 고정문구 반영", command=self.apply_target_fixed_suffix).grid(row=2, column=2, sticky="w", pady=(8, 0))
        ttk.Label(fixed_frame, text="아래 Target 고정문구 대상은 상단 대상/slot 편집 문맥과 별도입니다.", justify="left").grid(row=3, column=2, columnspan=2, sticky="w", pady=(8, 0))

        editor_right = ttk.Notebook(editor_tab)
        editor_right.grid(row=1, column=1, sticky="nsew")
        self.editor_right_notebook = editor_right

        editor_context_tab = ttk.Frame(editor_right, padding=6)
        editor_context_tab.columnconfigure(0, weight=1)
        editor_context_tab.rowconfigure(0, weight=1)
        editor_right.add(editor_context_tab, text="현재 문맥")
        self.message_context_text = scrolledtext.ScrolledText(editor_context_tab, wrap="word")
        self.message_context_text.grid(row=0, column=0, sticky="nsew")

        editor_plan_tab = ttk.Frame(editor_right, padding=6)
        editor_plan_tab.columnconfigure(0, weight=1)
        editor_plan_tab.rowconfigure(0, weight=1)
        editor_right.add(editor_plan_tab, text="적용 source / plan")
        self.message_plan_text = scrolledtext.ScrolledText(editor_plan_tab, wrap="word")
        self.message_plan_text.grid(row=0, column=0, sticky="nsew")

        editor_initial_preview_tab = ttk.Frame(editor_right, padding=6)
        editor_initial_preview_tab.columnconfigure(0, weight=1)
        editor_initial_preview_tab.rowconfigure(0, weight=1)
        editor_right.add(editor_initial_preview_tab, text="Initial Preview")
        self.message_initial_preview_text = scrolledtext.ScrolledText(editor_initial_preview_tab, wrap="word")
        self.message_initial_preview_text.grid(row=0, column=0, sticky="nsew")

        editor_handoff_preview_tab = ttk.Frame(editor_right, padding=6)
        editor_handoff_preview_tab.columnconfigure(0, weight=1)
        editor_handoff_preview_tab.rowconfigure(0, weight=1)
        editor_right.add(editor_handoff_preview_tab, text="Handoff Preview")
        self.message_handoff_preview_text = scrolledtext.ScrolledText(editor_handoff_preview_tab, wrap="word")
        self.message_handoff_preview_text.grid(row=0, column=0, sticky="nsew")

        editor_final_delivery_tab = ttk.Frame(editor_right, padding=6)
        editor_final_delivery_tab.columnconfigure(0, weight=1)
        editor_final_delivery_tab.rowconfigure(1, weight=1)
        editor_right.add(editor_final_delivery_tab, text="최종 전달문")
        final_delivery_actions = ttk.Frame(editor_final_delivery_tab)
        final_delivery_actions.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        ttk.Button(final_delivery_actions, text="완성본 복사", command=self.copy_current_final_delivery_preview).grid(row=0, column=0, padx=(0, 8))
        self.message_final_delivery_text = scrolledtext.ScrolledText(editor_final_delivery_tab, wrap="word")
        self.message_final_delivery_text.grid(row=1, column=0, sticky="nsew")

        editor_path_summary_tab = ttk.Frame(editor_right, padding=6)
        editor_path_summary_tab.columnconfigure(0, weight=1)
        editor_path_summary_tab.rowconfigure(1, weight=1)
        editor_right.add(editor_path_summary_tab, text="경로 요약")
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
        editor_right.add(editor_one_time_tab, text="1회성 문구")
        self.message_one_time_preview_text = scrolledtext.ScrolledText(editor_one_time_tab, wrap="word")
        self.message_one_time_preview_text.grid(row=0, column=0, sticky="nsew")

        self.editor_validation_tab = ttk.Frame(editor_right, padding=6)
        self.editor_validation_tab.columnconfigure(0, weight=1)
        self.editor_validation_tab.rowconfigure(0, weight=1)
        editor_right.add(self.editor_validation_tab, text="저장 전 검증")
        self.message_validation_text = scrolledtext.ScrolledText(self.editor_validation_tab, wrap="word")
        self.message_validation_text.grid(row=0, column=0, sticky="nsew")

        editor_summary_tab = ttk.Frame(editor_right, padding=6)
        editor_summary_tab.columnconfigure(0, weight=1)
        editor_summary_tab.rowconfigure(0, weight=1)
        editor_right.add(editor_summary_tab, text="편집 요약")
        self.message_summary_text = scrolledtext.ScrolledText(editor_summary_tab, wrap="word")
        self.message_summary_text.grid(row=0, column=0, sticky="nsew")

        self.editor_diff_tab = ttk.Frame(editor_right, padding=6)
        self.editor_diff_tab.columnconfigure(0, weight=1)
        self.editor_diff_tab.rowconfigure(0, weight=1)
        editor_right.add(self.editor_diff_tab, text="Diff")
        self.message_diff_text = scrolledtext.ScrolledText(self.editor_diff_tab, wrap="none")
        self.message_diff_text.grid(row=0, column=0, sticky="nsew")

        editor_backup_tab = ttk.Frame(editor_right, padding=6)
        editor_backup_tab.columnconfigure(0, weight=1)
        editor_backup_tab.rowconfigure(2, weight=1)
        editor_right.add(editor_backup_tab, text="백업")
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

        artifacts_tab = ttk.Frame(notebook, padding=10)
        artifacts_tab.columnconfigure(0, weight=3)
        artifacts_tab.columnconfigure(1, weight=2)
        artifacts_tab.rowconfigure(2, weight=1)
        notebook.add(artifacts_tab, text="결과 / 산출물")
        self.artifacts_tab = artifacts_tab

        artifact_filters = ttk.LabelFrame(artifacts_tab, text="필터", padding=8)
        artifact_filters.grid(row=0, column=0, columnspan=2, sticky="ew")
        artifact_filters.columnconfigure(1, weight=1)
        artifact_filters.columnconfigure(3, weight=1)
        artifact_filters.columnconfigure(5, weight=1)

        ttk.Label(artifact_filters, text="RunRoot").grid(row=0, column=0, sticky="w", padx=(0, 8))
        ttk.Entry(artifact_filters, textvariable=self.run_root_var).grid(row=0, column=1, sticky="ew")
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

        artifact_actions = ttk.LabelFrame(artifact_right, text="열기 / 복사", padding=8)
        artifact_actions.grid(row=0, column=0, sticky="ew")
        for idx, (label, kind) in enumerate(
            [
                ("summary 열기", "summary"),
                ("latest zip 열기", "review_zip"),
                ("watch 시작", "watch_start"),
                ("target check 실행", "artifact_check"),
                ("target submit 실행", "artifact_import"),
                ("error 열기", "error"),
                ("result 열기", "result"),
                ("request 열기", "request"),
                ("done 열기", "done"),
                ("target 폴더", "target_folder"),
                ("review 폴더", "review_folder"),
            ]
        ):
            if kind == "watch_start":
                command = self.start_watcher_detached
            elif kind == "artifact_check":
                command = self.check_selected_external_artifact
            elif kind == "artifact_import":
                command = self.import_selected_external_artifact
            else:
                command = (lambda kind=kind: self.open_selected_artifact_path(kind))
            button = ttk.Button(
                artifact_actions,
                text=label,
                command=command,
            )
            button.grid(row=idx // 4, column=idx % 4, padx=(0, 8), pady=(0, 6), sticky="ew")
            if kind in {"watch_start", "artifact_check", "artifact_import"}:
                self.long_task_widgets.append(button)
                if kind == "watch_start":
                    self.artifact_watch_button = button

        copy_row = ttk.Frame(artifact_actions)
        copy_row.grid(row=2, column=0, columnspan=4, sticky="ew", pady=(4, 0))
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
        artifact_summary_frame.rowconfigure(0, weight=1)
        self.artifact_summary_text = scrolledtext.ScrolledText(artifact_summary_frame, wrap="word")
        self.artifact_summary_text.grid(row=0, column=0, sticky="nsew")

        artifact_details_frame = ttk.LabelFrame(artifact_right, text="경로 / 상태", padding=6)
        artifact_details_frame.grid(row=2, column=0, sticky="nsew", pady=(10, 0))
        artifact_details_frame.columnconfigure(0, weight=1)
        artifact_details_frame.rowconfigure(0, weight=1)
        self.artifact_details_text = scrolledtext.ScrolledText(artifact_details_frame, wrap="word")
        self.artifact_details_text.grid(row=0, column=0, sticky="nsew")

        ops_tab = ttk.Frame(notebook, padding=10)
        ops_tab.columnconfigure(0, weight=1)
        ops_tab.rowconfigure(1, weight=1)
        notebook.add(ops_tab, text="원문 / 진단")
        self.ops_tab = ops_tab

        button_row = ttk.Frame(ops_tab)
        button_row.grid(row=0, column=0, sticky="ew")
        for idx, (label, callback) in enumerate(
            [
                ("pair01 즉시 실행", self.run_fixed_pair01_drill),
                ("선택된 Pair 드릴 실행", self.run_selected_pair_drill),
                ("watch 정지 요청", self.request_stop_watcher),
                ("watch 재시작", self.restart_watcher),
                ("watch stale 정리", self.recover_stale_watcher_state),
                ("watch 진단", self.show_watcher_diagnostics),
                ("watch 권장 조치", self.apply_watcher_recommended_action),
                ("watch audit 로그", self.open_watcher_audit_log),
                ("watch status 파일", self.open_watcher_status_file),
                ("watch control 파일", self.open_watcher_control_file),
                ("릴레이 상태", self.run_relay_status),
                ("페어 상태", self.run_paired_status),
                ("runroot 요약", self.run_paired_summary),
                ("창 입력 가능 확인", self.run_visibility_check),
                ("Headless 준비 확인", self.run_headless_readiness),
                ("적용 설정 JSON", self.run_effective_json),
            ]
        ):
            button = ttk.Button(button_row, text=label, command=callback)
            button.grid(row=0, column=idx, padx=(0, 8))
            self.long_task_widgets.append(button)
            if label == "pair01 즉시 실행":
                self.fixed_pair01_button = button
            elif label == "선택된 Pair 드릴 실행":
                self.selected_pair_button = button
            elif label == "watch 정지 요청":
                self.ops_stop_watch_button = button
            elif label == "watch 재시작":
                self.ops_restart_watch_button = button
            elif label == "watch stale 정리":
                self.ops_recover_watch_button = button

        for child in controls.winfo_children():
            if isinstance(child, ttk.Combobox):
                child.bind("<<ComboboxSelected>>", self.on_pair_or_target_changed)

        self.artifact_pair_combo.bind("<<ComboboxSelected>>", self.refresh_artifacts_tab)
        self.artifact_target_combo.bind("<<ComboboxSelected>>", self.refresh_artifacts_tab)

        self.output_text = scrolledtext.ScrolledText(ops_tab, wrap="word")
        self.output_text.grid(row=1, column=0, sticky="nsew", pady=(10, 0))

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

    def set_busy(self, state: str, hint: str) -> None:
        self._busy = True
        for widget in self.long_task_widgets:
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
    ) -> None:
        if self._busy:
            messagebox.showwarning("작업 중", "다른 작업이 실행 중입니다. 현재 작업이 끝난 뒤 다시 시도하세요.")
            return

        self.set_busy(state, hint)

        def runner() -> None:
            try:
                result = worker()
            except Exception as exc:
                self.after(0, lambda exc=exc: self._handle_background_failure(exc, failure_state, failure_hint))
                return

            self.after(0, lambda result=result: self._handle_background_success(result, on_success, success_state, success_hint))

        threading.Thread(target=runner, daemon=True).start()

    def _handle_background_failure(self, exc: Exception, state: str, hint: str) -> None:
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

    def _handle_background_success(self, result, on_success, state: str, hint: str) -> None:
        on_success(result)
        self.set_idle(state, hint)

    def _selected_preview_row(self) -> dict | None:
        selection = self.row_tree.selection()
        if not selection:
            return None
        return self.preview_rows[int(selection[0])]

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

        pair01_state = self.get_pair_activation_state("pair01")
        if self._has_ui_attr("fixed_pair01_button"):
            enabled = bool((pair01_state or {}).get("EffectiveEnabled", True))
            self.fixed_pair01_button.configure(state="normal" if enabled else "disabled")

        selected_pair = self.pair_id_var.get().strip()
        selected_state = self.get_pair_activation_state(selected_pair) if selected_pair else None
        if self._has_ui_attr("selected_pair_button"):
            enabled, _detail = self._selected_pair_execution_allowed()
            self.selected_pair_button.configure(state="normal" if enabled else "disabled")

        if self._has_ui_attr("home_run_pair_button"):
            enabled, _detail = self._selected_pair_execution_allowed()
            self.home_run_pair_button.configure(state="normal" if enabled else "disabled")

        if self._has_ui_attr("home_enable_pair_button"):
            enabled = bool(selected_pair) and not bool((selected_state or {}).get("EffectiveEnabled", True))
            self.home_enable_pair_button.configure(state="normal" if enabled else "disabled")

        if self._has_ui_attr("home_disable_pair_button"):
            enabled = bool(selected_pair) and bool((selected_state or {}).get("EffectiveEnabled", True))
            self.home_disable_pair_button.configure(state="normal" if enabled else "disabled")

        start_eligibility = self._watcher_start_eligibility()
        stop_eligibility = self._watcher_stop_eligibility()
        watch_start_allowed, _detail = self._watch_start_allowed()
        if self._has_ui_attr("home_start_watch_button"):
            self.home_start_watch_button.configure(state="normal" if watch_start_allowed else "disabled")
        if self._has_ui_attr("artifact_watch_button"):
            self.artifact_watch_button.configure(state="normal" if watch_start_allowed else "disabled")
        if self._has_ui_attr("ops_stop_watch_button"):
            self.ops_stop_watch_button.configure(state="normal" if stop_eligibility.allowed else "disabled")
        if self._has_ui_attr("ops_restart_watch_button"):
            restart_enabled = bool(self._current_run_root_for_actions()) and stop_eligibility.allowed and bool(self.config_path_var.get().strip())
            self.ops_restart_watch_button.configure(state="normal" if restart_enabled else "disabled")
        if self._has_ui_attr("ops_recover_watch_button"):
            self.ops_recover_watch_button.configure(state="normal" if start_eligibility.cleanup_allowed else "disabled")
        if self._has_ui_attr("board_attach_button"):
            attach_allowed, _detail = self._attach_action_allowed()
            self.board_attach_button.configure(state="normal" if attach_allowed else "disabled")

    def on_pair_or_target_changed(self, _event: object | None = None) -> None:
        selected_pair = self._selected_pair_id()
        selected_target = self.target_id_var.get().strip()
        self._sync_preview_selection_with_pair(selected_pair, target_id=selected_target)
        self._sync_message_scope_id_from_context()
        self._sync_home_pair_selection(self._selected_pair_id())
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

    def export_selected_row_messages(self) -> None:
        row = self._selected_preview_row()
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

    def _selected_pair_id(self) -> str:
        return self.pair_id_var.get().strip() or "pair01"

    def _selected_home_pair_id(self) -> str:
        selection = self.home_pair_tree.selection()
        if selection:
            return selection[0]
        return self._selected_pair_id()

    def _selected_pair_summary(self) -> PairSummaryModel | None:
        return self.pair_controller.selected_summary(self.panel_state, self._selected_home_pair_id())

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
        match = re.search(r"prepared pair test root:\s*(.+)", text, flags=re.IGNORECASE)
        if match:
            return match.group(1).strip()
        return ""

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
            if self._busy:
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
            if self._busy:
                button.configure(state="disabled")

    def render_home_dashboard(self) -> None:
        if not self.panel_state or not self.effective_data:
            return

        config = self.effective_data.get("Config", {})
        run_context = self.effective_data.get("RunContext", {})
        self.home_context_var.set(
            "Lane: {lane} | Config: {config_path} | Pair: {pair} | RunRoot: {run_root}".format(
                lane=config.get("LaneName", "") or "(none)",
                config_path=config.get("ConfigPath", "") or self.config_path_var.get().strip() or "(none)",
                pair=self._selected_pair_id(),
                run_root=self._current_run_root_display_text(),
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

        for stage in self.panel_state.stages:
            vars_by_key = self.home_stage_vars.get(stage.key)
            button = self.home_stage_buttons.get(stage.key)
            if vars_by_key:
                vars_by_key["status"].set("상태: {0}".format(stage.status_text))
                vars_by_key["detail"].set(stage.detail)
            if button:
                button.configure(text=stage.action_label, state="disabled" if self._busy or not stage.enabled else "normal")

        self._render_action_frame(self.home_next_actions_frame, self.panel_state.next_actions)
        self._render_issue_frame(self.home_issue_frame, self.panel_state.issues)
        self.render_home_pair_summaries()

    def render_home_pair_summaries(self) -> None:
        current_pair = self._selected_pair_id()
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
                    summary.zip_count,
                    summary.failure_count,
                ),
            )

        self._sync_home_pair_selection(current_pair)
        summary = self._selected_pair_summary()
        if summary:
            self.home_pair_detail_var.set(self.pair_controller.build_summary_detail(summary))

    def _artifact_query(self) -> ArtifactQuery:
        return ArtifactQuery(
            run_root=self._current_run_root_for_actions(),
            pair_id=self.artifact_pair_filter_var.get().strip(),
            target_id=self.artifact_target_filter_var.get().strip(),
            latest_only=bool(self.artifact_latest_only_var.get()),
            include_missing=bool(self.artifact_include_missing_var.get()),
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

    def on_artifact_row_selected(self, _event: object | None = None) -> None:
        state = self._selected_artifact_state()
        if state is None:
            self._apply_artifact_status_text(base_text=self.artifact_status_base_text)
            self.set_text(self.artifact_summary_text, "")
            self.set_text(self.artifact_details_text, "")
            return
        if state.pair_id:
            self.pair_id_var.set(state.pair_id)
        if state.target_id:
            self.target_id_var.set(state.target_id)
        self.render_target_board()

        preview = self.artifact_controller.get_preview(self.artifact_states, state.target_id)
        if preview is None:
            self._apply_artifact_status_text(base_text=self.artifact_status_base_text)
            self.set_text(self.artifact_summary_text, "")
            self.set_text(self.artifact_details_text, "")
            return

        contract_paths = self._resolve_artifact_contract_paths(state)
        self._apply_artifact_status_text(
            base_text=self.artifact_status_base_text,
            preview=preview,
            state=state,
            contract_paths=contract_paths,
        )
        self.set_text(self.artifact_summary_text, preview.summary_text)
        detail_lines = [
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
            f"선택 RunRoot stale 여부: {self._current_run_root_is_stale_for_actions()}",
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
        if selected_run_root:
            normalized_candidate = os.path.normcase(os.path.normpath(candidate))
            normalized_selected = os.path.normcase(os.path.normpath(selected_run_root))
            if normalized_candidate == normalized_selected:
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
                    "오래된 explicit RunRoot 무시 후 새 RunRoot 생성",
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
                return "마지막 결과: stale explicit RunRoot 무시 후 새 RunRoot 준비 및 입력칸 갱신 완료"
            return "마지막 결과: 새 RunRoot 준비 및 입력칸 갱신 완료"
        if ignored_run_root:
            return "마지막 결과: stale explicit RunRoot 무시 후 RunRoot 준비 완료"
        return "마지막 결과: RunRoot 준비 완료"

    def _run_root_summary_text(self, run_root: str = "") -> str:
        summary_run_root = run_root.strip() or self._current_run_root_for_actions()
        if not summary_run_root:
            return ""
        command = self.command_service.build_script_command(
            "show-paired-run-summary.ps1",
            config_path=self.config_path_var.get().strip(),
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

    def _requested_run_root_for_prepare(self) -> str:
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
        if self._current_run_root_is_stale_for_actions():
            badges.append("[STALE RUNROOT WARNING]")
        if state is not None:
            resolved_contract = contract_paths or self._resolve_artifact_contract_paths(state)
            if not bool(resolved_contract.get("CheckScriptPathExists", False)):
                badges.append("[LEGACY CHECK FALLBACK RISK]")
            if not bool(resolved_contract.get("SubmitScriptPathExists", False)):
                badges.append("[LEGACY SUBMIT FALLBACK RISK]")
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
        badges = self._artifact_warning_badges(state=state, contract_paths=contract_paths)
        if badges:
            status_text = " ".join(badges + [status_text])
        self.artifact_status_var.set(status_text)

    def _resolve_artifact_contract_paths(self, state: TargetArtifactState) -> dict[str, object]:
        preview_row = self._preview_row_for_target(state.target_id) or {}
        request_path = self.artifact_service.resolve_artifact_path(state, "request") or str(preview_row.get("RequestPath", "") or "")
        request_payload = self._safe_read_json_file(request_path)
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
        source_outbox_path = str(
            request_payload.get("SourceOutboxPath", "")
            or preview_row.get("SourceOutboxPath", "")
            or ""
        ).strip()
        if not source_outbox_path and target_folder:
            source_outbox_path = str(
                Path(target_folder)
                / self._pair_test_file_name("SourceOutboxFolderName", "source-outbox")
            )
        resolved["SourceOutboxPath"] = source_outbox_path
        resolved["SourceSummaryPath"] = str(
            request_payload.get("SourceSummaryPath", "")
            or preview_row.get("SourceSummaryPath", "")
            or (str(Path(source_outbox_path) / self._pair_test_file_name("SourceSummaryFileName", "summary.txt")) if source_outbox_path else "")
        ).strip()
        resolved["SourceReviewZipPath"] = str(
            request_payload.get("SourceReviewZipPath", "")
            or preview_row.get("SourceReviewZipPath", "")
            or (str(Path(source_outbox_path) / self._pair_test_file_name("SourceReviewZipFileName", "review.zip")) if source_outbox_path else "")
        ).strip()
        resolved["PublishReadyPath"] = str(
            request_payload.get("PublishReadyPath", "")
            or preview_row.get("PublishReadyPath", "")
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
    ) -> tuple[list[str], str, bool, dict[str, object]]:
        contract_paths = self._resolve_artifact_contract_paths(state)
        wrapper_path = str(contract_paths.get(wrapper_key, "") or "").strip()
        if wrapper_path and Path(wrapper_path).exists():
            return (
                self.command_service.build_powershell_file_command(wrapper_path, extra=extra),
                wrapper_path,
                True,
                contract_paths,
            )

        command = self.command_service.build_script_command(
            fallback_script_name,
            config_path=config_path,
            run_root=run_root,
            target_id=state.target_id,
            extra=extra,
        )
        return (command, str(ROOT / fallback_script_name), False, contract_paths)

    def _selected_artifact_action_context(self) -> tuple[TargetArtifactState, str, str] | None:
        state = self._selected_artifact_state()
        if state is None:
            messagebox.showwarning("선택 필요", "target row를 먼저 선택하세요.")
            return None

        run_root = self._current_run_root_for_actions()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "artifact 검증/가져오기에는 RunRoot가 필요합니다.")
            return None

        config_path = self.config_path_var.get().strip()
        if not config_path:
            messagebox.showwarning("설정 필요", "artifact 검증/가져오기에는 ConfigPath가 필요합니다.")
            return None

        return state, config_path, run_root

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
        state, config_path, run_root = context
        selected_sources = self._prompt_external_artifact_sources(state)
        if selected_sources is None:
            return
        summary_path, review_zip_path = selected_sources
        self._remember_artifact_sources(state.target_id, summary_path, review_zip_path)

        command, execution_path, used_wrapper, contract_paths = self._build_artifact_action_command(
            state=state,
            config_path=config_path,
            run_root=run_root,
            wrapper_key="CheckScriptPath",
            fallback_script_name="check-paired-exchange-artifact.ps1",
            extra=[
                "-SummarySourcePath",
                summary_path,
                "-ReviewZipSourcePath",
                review_zip_path,
                "-AsJson",
            ],
        )
        self._remember_artifact_action_result(
            state.target_id,
            {
                "Action": "check",
                "Status": "running",
                "RecordedAt": datetime.now().isoformat(timespec="seconds"),
                "UsedWrapper": used_wrapper,
                "ExecutionPath": execution_path,
                "SummarySourcePath": summary_path,
                "ReviewZipSourcePath": review_zip_path,
                "RunRoot": run_root,
                "RunRootIsStale": self._current_run_root_is_stale_for_actions(),
            },
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            try:
                return self.command_service.run(command)
            except Exception as exc:
                self._remember_artifact_action_result(
                    state.target_id,
                    {
                        "Action": "check",
                        "Status": "failed",
                        "RecordedAt": datetime.now().isoformat(timespec="seconds"),
                        "UsedWrapper": used_wrapper,
                        "ExecutionPath": execution_path,
                        "SummarySourcePath": summary_path,
                        "ReviewZipSourcePath": review_zip_path,
                        "RunRoot": run_root,
                        "RunRootIsStale": self._current_run_root_is_stale_for_actions(),
                        "Error": str(exc),
                    },
                )
                raise

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            preflight_text = self._format_external_artifact_preflight(payload)
            validation = payload.get("Validation", {}) or {}
            preflight = payload.get("Preflight", {}) or {}
            current_target = payload.get("PreImportStatus", {}) or {}
            self._remember_artifact_action_result(
                state.target_id,
                {
                    "Action": "check",
                    "Status": "success",
                    "RecordedAt": datetime.now().isoformat(timespec="seconds"),
                    "UsedWrapper": used_wrapper,
                    "ExecutionPath": execution_path,
                    "SummarySourcePath": summary_path,
                    "ReviewZipSourcePath": review_zip_path,
                    "RunRoot": run_root,
                    "RunRootIsStale": self._current_run_root_is_stale_for_actions(),
                    "RequiresOverwrite": bool(validation.get("RequiresOverwrite", False)),
                    "LatestState": str(preflight.get("CurrentLatestState", "") or current_target.get("LatestState", "") or ""),
                    "LatestZipPath": str(preflight.get("DestinationZipPath", "") or ""),
                },
            )
            header_lines = [
                "artifact check 실행",
                f"실행 경로: {execution_path}",
                f"target-local wrapper 사용: {'예' if used_wrapper else '아니오 (root fallback)'}",
                f"wrapper 경로 출처: {contract_paths.get('Source', '') or '(없음)'}",
            ]
            if not used_wrapper:
                header_lines.append("LEGACY FALLBACK WARNING: target-local wrapper 없이 root fallback check를 사용했습니다.")
            if self._current_run_root_is_stale_for_actions():
                header_lines.append("주의: 현재 선택된 RunRoot가 stale 표시입니다. 새 wrapper가 없는 예전 run일 수 있습니다.")
            self.set_text(
                self.output_text,
                "\n".join(header_lines) + "\n\n" + preflight_text + "\n\nJSON\n" + json.dumps(payload, ensure_ascii=False, indent=2),
            )
            self.on_artifact_row_selected()

        self.run_background_task(
            state="artifact check 실행 중",
            hint=f"{state.target_id} target-local check wrapper 또는 fallback 검증을 수행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="artifact check 실행 완료",
            success_hint="검증 결과 JSON과 실행 경로를 출력했습니다.",
            failure_state="artifact check 실행 실패",
            failure_hint="선택한 summary/zip 경로, target wrapper 경로, RunRoot 계약을 확인하세요.",
        )

    def import_selected_external_artifact(self) -> None:
        context = self._selected_artifact_action_context()
        if context is None:
            return
        state, config_path, run_root = context
        selected_sources = self._prompt_external_artifact_sources(state)
        if selected_sources is None:
            return
        summary_path, review_zip_path = selected_sources
        self._remember_artifact_sources(state.target_id, summary_path, review_zip_path)
        if not self._confirm_recent_submit_repeat(state.target_id):
            return

        check_command, check_execution_path, check_used_wrapper, contract_paths = self._build_artifact_action_command(
            state=state,
            config_path=config_path,
            run_root=run_root,
            wrapper_key="CheckScriptPath",
            fallback_script_name="check-paired-exchange-artifact.ps1",
            extra=[
                "-SummarySourcePath",
                summary_path,
                "-ReviewZipSourcePath",
                review_zip_path,
                "-AsJson",
            ],
        )
        try:
            check_payload = self.command_service.run_json(check_command)
        except Exception as exc:
            self.set_text(self.output_text, str(exc))
            messagebox.showwarning("외부 artifact 검증 실패", "선택한 summary/zip 경로와 target 계약을 먼저 확인하세요.", parent=self)
            return

        preflight_text = self._format_external_artifact_preflight(check_payload)
        preflight_header_lines = [
            "artifact submit 사전검사",
            f"check 실행 경로: {check_execution_path}",
            f"target-local wrapper 사용: {'예' if check_used_wrapper else '아니오 (root fallback)'}",
            f"wrapper 경로 출처: {contract_paths.get('Source', '') or '(없음)'}",
        ]
        if not check_used_wrapper:
            preflight_header_lines.append("LEGACY FALLBACK WARNING: target-local wrapper 없이 root fallback check를 사용했습니다.")
        if self._current_run_root_is_stale_for_actions():
            preflight_header_lines.append("주의: 현재 선택된 RunRoot가 stale 표시입니다. 새 wrapper가 없는 예전 run일 수 있습니다.")
        self.set_text(
            self.output_text,
            "\n".join(preflight_header_lines) + "\n\n" + preflight_text + "\n\nJSON\n" + json.dumps(check_payload, ensure_ascii=False, indent=2),
        )

        validation = check_payload.get("Validation", {}) or {}
        if not bool(validation.get("Ok", False)):
            messagebox.showwarning("외부 artifact import 차단", "입력 artifact 검증에 실패했습니다. output 영역의 preflight 결과를 먼저 확인하세요.", parent=self)
            return

        requires_overwrite = bool(validation.get("RequiresOverwrite", False))
        confirm_lines = [
            f"target: {state.target_id}",
            f"source summary: {summary_path}",
            f"source zip: {review_zip_path}",
            f"check 실행 경로: {check_execution_path}",
            f"wrapper 사용: {'예' if check_used_wrapper else '아니오 (root fallback)'}",
            "",
            preflight_text,
            "",
            "현재 RunRoot target folder 계약으로 summary.txt, review zip, done.json, result.json을 기록할까요?",
        ]
        if self._current_run_root_is_stale_for_actions():
            confirm_lines.append("주의: 선택된 RunRoot가 stale 표시입니다. 새 RunRoot로 다시 준비한 wrapper가 아닐 수 있습니다.")
        if requires_overwrite:
            confirm_lines.append("이 import는 기존 contract 파일 또는 현재 성공 상태를 덮어씁니다. 계속하려면 overwrite를 명시적으로 승인해야 합니다.")

        confirmed = messagebox.askyesno(
            "외부 artifact import" if not requires_overwrite else "외부 artifact import (overwrite)",
            "\n".join(confirm_lines),
            parent=self,
        )
        if not confirmed:
            return

        extra = [
            "-SummarySourcePath", summary_path,
            "-ReviewZipSourcePath", review_zip_path,
            "-AsJson",
        ]
        if requires_overwrite:
            extra.append("-Overwrite")

        command, submit_execution_path, submit_used_wrapper, submit_contract_paths = self._build_artifact_action_command(
            state=state,
            config_path=config_path,
            run_root=run_root,
            wrapper_key="SubmitScriptPath",
            fallback_script_name="import-paired-exchange-artifact.ps1",
            extra=extra,
        )
        if not submit_used_wrapper:
            fallback_confirmed = messagebox.askyesno(
                "legacy fallback submit 확인",
                "\n".join(
                    [
                        f"{state.target_id} submit이 target-local wrapper 없이 legacy fallback 경로로 실행됩니다.",
                        f"실행 경로: {submit_execution_path}",
                        f"wrapper 경로 출처: {submit_contract_paths.get('Source', '') or '(없음)'}",
                        "이 경로는 예전 RunRoot 호환용입니다. 새 RunRoot를 다시 준비하지 않았다면 혼선 가능성이 큽니다.",
                        "",
                        "정말 fallback submit을 계속할까요?",
                    ]
                ),
                parent=self,
            )
            if not fallback_confirmed:
                return

        if not self._begin_submit_action(state.target_id):
            messagebox.showwarning("submit 진행 중", f"{state.target_id} submit이 이미 진행 중입니다.", parent=self)
            return

        self._remember_artifact_action_result(
            state.target_id,
            {
                "Action": "submit",
                "Status": "running",
                "RecordedAt": datetime.now().isoformat(timespec="seconds"),
                "UsedWrapper": submit_used_wrapper,
                "ExecutionPath": submit_execution_path,
                "SummarySourcePath": summary_path,
                "ReviewZipSourcePath": review_zip_path,
                "RunRoot": run_root,
                "RunRootIsStale": self._current_run_root_is_stale_for_actions(),
                "RequiresOverwrite": requires_overwrite,
                "LatestState": str((check_payload.get("PreImportStatus", {}) or {}).get("LatestState", "") or ""),
                "LatestZipPath": str((check_payload.get("Preflight", {}) or {}).get("DestinationZipPath", "") or ""),
            },
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            try:
                return self.command_service.run(command)
            except Exception as exc:
                self._remember_artifact_action_result(
                    state.target_id,
                    {
                        "Action": "submit",
                        "Status": "failed",
                        "RecordedAt": datetime.now().isoformat(timespec="seconds"),
                        "UsedWrapper": submit_used_wrapper,
                        "ExecutionPath": submit_execution_path,
                        "SummarySourcePath": summary_path,
                        "ReviewZipSourcePath": review_zip_path,
                        "RunRoot": run_root,
                        "RunRootIsStale": self._current_run_root_is_stale_for_actions(),
                        "RequiresOverwrite": requires_overwrite,
                        "LatestState": str((check_payload.get("PreImportStatus", {}) or {}).get("LatestState", "") or ""),
                        "LatestZipPath": str((check_payload.get("Preflight", {}) or {}).get("DestinationZipPath", "") or ""),
                        "Error": str(exc),
                    },
                )
                self._finish_submit_action(state.target_id)
                raise

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            try:
                payload = json.loads(completed.stdout)
                preflight_text = self._format_external_artifact_preflight(payload)
                post_import_status = payload.get("PostImportStatus", {}) or {}
                contract = payload.get("Contract", {}) or {}
                self._remember_artifact_action_result(
                    state.target_id,
                    {
                        "Action": "submit",
                        "Status": "success",
                        "RecordedAt": datetime.now().isoformat(timespec="seconds"),
                        "UsedWrapper": submit_used_wrapper,
                        "ExecutionPath": submit_execution_path,
                        "SummarySourcePath": summary_path,
                        "ReviewZipSourcePath": review_zip_path,
                        "RunRoot": run_root,
                        "RunRootIsStale": self._current_run_root_is_stale_for_actions(),
                        "RequiresOverwrite": requires_overwrite,
                        "LatestState": str(post_import_status.get("LatestState", "") or ""),
                        "LatestZipPath": str(contract.get("DestinationZipPath", "") or contract.get("LatestZipPath", "") or ""),
                    },
                )
                header_lines = [
                    "artifact submit 실행",
                    f"submit 실행 경로: {submit_execution_path}",
                    f"target-local wrapper 사용: {'예' if submit_used_wrapper else '아니오 (root fallback)'}",
                    f"wrapper 경로 출처: {submit_contract_paths.get('Source', '') or '(없음)'}",
                ]
                if not submit_used_wrapper:
                    header_lines.append("LEGACY FALLBACK WARNING: target-local wrapper 없이 root fallback submit을 사용했습니다.")
                if self._current_run_root_is_stale_for_actions():
                    header_lines.append("주의: 현재 선택된 RunRoot가 stale 표시입니다. 새 RunRoot로 다시 준비한 wrapper가 아닐 수 있습니다.")
                header_lines.extend(
                    [
                        f"RequiresOverwrite: {requires_overwrite}",
                        f"계약 LatestState: {post_import_status.get('LatestState', '') or '(없음)'}",
                        f"LatestZipPath: {contract.get('DestinationZipPath', '') or contract.get('LatestZipPath', '') or '(없음)'}",
                    ]
                )
                self.set_text(
                    self.output_text,
                    "\n".join(header_lines) + "\n\n" + preflight_text + "\n\nJSON\n" + json.dumps(payload, ensure_ascii=False, indent=2),
                )
                self.refresh_paired_status_only()
                self.on_artifact_row_selected()
            finally:
                self._finish_submit_action(state.target_id)

        self.run_background_task(
            state="artifact submit 실행 중",
            hint=f"{state.target_id} target-local submit wrapper 또는 fallback import를 실행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="artifact submit 실행 완료",
            success_hint="paired status와 결과 탭을 새 산출물 기준으로 다시 읽었습니다.",
            failure_state="artifact submit 실행 실패",
            failure_hint="summary/zip 경로, target wrapper 경로, RunRoot target 계약을 확인하세요.",
        )

    def on_home_pair_selected(self, _event: object | None = None) -> None:
        summary = self._selected_pair_summary()
        if not summary:
            self.home_pair_detail_var.set(self.pair_controller.build_summary_detail(summary))
            return
        if self.pair_id_var.get().strip() != summary.pair_id:
            self.pair_id_var.set(summary.pair_id)
            self.update_pair_button_states()
            self.rebuild_panel_state()
        self.home_pair_detail_var.set(self.pair_controller.build_summary_detail(summary))

    def apply_selected_home_pair(self) -> None:
        pair_id = self._selected_home_pair_id()
        self.pair_id_var.set(pair_id)
        self._sync_preview_selection_with_pair(pair_id)
        self.update_pair_button_states()
        self.rebuild_panel_state()
        self.set_text(self.output_text, f"선택 Pair 반영 완료:\n{pair_id}")

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
        try:
            bundle = self.refresh_controller.refresh_full(self._current_context())
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

        if not self.run_root_var.get().strip():
            run_root_source = effective_payload.get("RunContext", {}).get("SelectedRunRootSource", "") or ""
            if selected_run_root and run_root_source != "next-preview":
                self.run_root_var.set(selected_run_root)
        self._update_run_root_controls()

        self.render_summary(effective_payload)
        self.render_rows(self.preview_rows)
        self._coerce_selected_pair_into_runtime_scope()
        self._sync_message_scope_id_from_context()
        if self.message_config_doc is None:
            self.load_message_editor_document()
        else:
            self.render_message_editor()
        self.render_target_board()
        self.rebuild_panel_state()
        self.refresh_artifacts_tab()

        selected_target = self.target_id_var.get().strip()
        if self.preview_rows and not self._sync_preview_selection_with_pair(self._selected_pair_id(), target_id=selected_target):
            first = self.row_tree.get_children()[0]
            self.row_tree.selection_set(first)
            self.on_row_selected()
        elif not self.preview_rows:
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
            f"manifest 경로: {run_context.get('ManifestPath', '')}",
            f"Pair 정의 출처: {payload.get('PairDefinitionSource', '')}",
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
            self.row_tree.insert(
                "",
                "end",
                iid=str(index),
                values=(
                    row.get("PairId", ""),
                    row.get("RoleName", ""),
                    row.get("TargetId", ""),
                    row.get("PartnerTargetId", ""),
                ),
            )

    def on_row_selected(self, _event: object | None = None) -> None:
        selection = self.row_tree.selection()
        if not selection:
            self.clear_details()
            return
        row = self.preview_rows[int(selection[0])]
        if row.get("PairId", ""):
            self.pair_id_var.set(row.get("PairId", ""))
        if row.get("TargetId", ""):
            self.target_id_var.set(row.get("TargetId", ""))
        self._sync_message_scope_id_from_context()
        self.render_target_board()
        self.render_message_editor()
        activation = row.get("PairActivation", {}) or {}
        details_lines = [
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
            f"Pair 대상 폴더: {row.get('PairTargetFolder', '')}",
            f"상대 폴더: {row.get('PartnerFolder', '')}",
            f"summary 경로: {row.get('SummaryPath', '')}",
            f"검토 폴더: {row.get('ReviewFolderPath', '')}",
            f"source outbox: {row.get('SourceOutboxPath', '')}",
            f"source summary: {row.get('SourceSummaryPath', '')}",
            f"source review zip: {row.get('SourceReviewZipPath', '')}",
            f"publish ready: {row.get('PublishReadyPath', '')}",
            f"published archive: {row.get('PublishedArchivePath', '')}",
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

    def clear_details(self) -> None:
        self.set_text(self.details_text, "")
        self.set_text(self.initial_text, "")
        self.set_text(self.handoff_text, "")
        self.set_text(self.plan_text, "")
        self.set_text(self.one_time_text, "")

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
            "run_paired_status": self.run_paired_status,
            "refresh_quick": self.refresh_quick_status,
            "start_watcher": self.start_watcher_detached,
            "stop_watcher": self.request_stop_watcher,
            "restart_watcher": self.restart_watcher,
            "recover_stale_watcher": self.recover_stale_watcher_state,
            "open_watcher_status": self.open_watcher_status_file,
            "open_watcher_control": self.open_watcher_control_file,
            "open_watcher_audit": self.open_watcher_audit_log,
            "focus_ready_to_forward_artifact": self.focus_ready_to_forward_artifact,
            "start_router": self.start_router_detached,
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
            self.set_text(self.output_text, output)
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

        command = self.command_service.build_script_command(
            "attach-targets-from-bindings.ps1",
            config_path=self.config_path_var.get().strip(),
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            self.set_text(self.output_text, completed.stdout.strip() or "binding attach 완료")
            self.load_effective_config()

        self.run_background_task(
            state="바인딩 attach 중",
            hint="binding profile 기준으로 runtime map을 다시 붙이고 있습니다.",
            worker=worker,
            on_success=on_success,
            success_state="바인딩 attach 완료",
            success_hint="홈 카드와 단계 진행판을 갱신했습니다.",
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

        def worker() -> dict:
            context = self._current_context()
            refresh_extra = ["-AsJson"]
            if pairs_mode:
                refresh_extra += ["-ReuseMode", "Pairs"]
            reuse_payload = self.status_service.run_json_script(
                "refresh-binding-profile-from-existing.ps1",
                context,
                extra=refresh_extra,
            )
            if not reuse_payload.get("Success", False):
                raise PowerShellError(
                    self._reuse_failure_summary(reuse_payload),
                    returncode=1,
                    stdout=json.dumps(reuse_payload, ensure_ascii=False, indent=2),
                    stderr="",
                )

            attach_command = self.command_service.build_script_command(
                "attach-targets-from-bindings.ps1",
                config_path=config_path,
            )
            attach_completed = self.command_service.run(attach_command)
            runtime_result = self.refresh_controller.refresh_runtime(context)
            return {
                "reuse_payload": reuse_payload,
                "attach_output": attach_completed.stdout.strip() or "binding attach 완료",
                "runtime_result": runtime_result,
                "reuse_anchor_utc": reuse_anchor_utc,
            }

        def on_success(result: dict) -> None:
            self.window_launch_anchor_utc = str(result.get("reuse_anchor_utc", "") or self.window_launch_anchor_utc)
            runtime_result = result.get("runtime_result")
            if runtime_result is not None:
                self._apply_runtime_refresh_result(runtime_result)
            reuse_payload = result.get("reuse_payload", {})
            if pairs_mode:
                self._apply_reuse_active_pair_selection(reuse_payload)
            self.set_text(
                self.output_text,
                self._format_reuse_existing_windows_report(
                    reuse_payload,
                    attach_output=str(result.get("attach_output", "") or ""),
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
        scope_allowed, scope_detail = self._selected_pair_scope_allowed(action_label="run 준비")
        if not scope_allowed:
            messagebox.showwarning("RunRoot 준비 대기", scope_detail)
            return
        ignored_run_root = self._prepare_run_root_override_to_ignore()
        requested_run_root = self._requested_run_root_for_prepare()
        command = self.command_service.build_script_command(
            "tests/Start-PairedExchangeTest.ps1",
            config_path=self.config_path_var.get().strip(),
            run_root=requested_run_root,
            extra=["-IncludePairId", pair_id],
        )
        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return self.command_service.run(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            output = completed.stdout.strip() or "run root 준비 완료"
            prepared_run_root = self._extract_prepared_run_root(output)
            if prepared_run_root:
                self.run_root_var.set(prepared_run_root)
            summary_text = self._run_root_summary_text(prepared_run_root)
            self.set_text(
                self.output_text,
                (
                    self._format_run_root_prepare_output(
                        output=output,
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
        scope_allowed, scope_detail = self._selected_pair_scope_allowed(action_label="준비 전체 실행")
        if not scope_allowed:
            messagebox.showwarning("준비 전체 실행 대기", scope_detail)
            return
        ignored_run_root = self._prepare_run_root_override_to_ignore()
        explicit_run_root = self._requested_run_root_for_prepare()

        def worker() -> dict:
            lines: list[str] = []
            prepared_run_root = ""
            runtime_result = None
            window_launch_anchor_utc = ""
            launched_windows = False
            stages = {stage.key: stage for stage in (self.panel_state.stages if self.panel_state else [])}

            if stages.get("launch_windows") and stages["launch_windows"].status_text != "완료":
                if not wrapper_path:
                    raise PowerShellError("LauncherWrapperPath를 찾지 못했습니다.")
                window_launch_anchor_utc = self._utc_now_iso()
                completed = self.command_service.run(self.command_service.build_python_command(wrapper_path))
                launched_windows = True
                lines.append("[8창 열기]")
                lines.append(completed.stdout.strip() or "visible launcher 실행 완료")
                lines.append("")

            if launched_windows or (stages.get("attach_windows") and stages["attach_windows"].status_text != "완료"):
                attach_command = self.command_service.build_script_command(
                    "attach-targets-from-bindings.ps1",
                    config_path=config_path,
                )
                completed = self.command_service.run(attach_command)
                lines.append("[붙이기]")
                lines.append(completed.stdout.strip() or "binding attach 완료")
                lines.append("")

            runtime_result = self.refresh_controller.refresh_runtime(self._current_context())
            lines.append("[입력 점검]")
            lines.append(
                self._format_visibility_status_report(
                    runtime_result.visibility_status,
                    relay_payload=runtime_result.relay_status,
                    include_json=False,
                )
            )
            lines.append("")

            runroot_command = self.command_service.build_script_command(
                "tests/Start-PairedExchangeTest.ps1",
                config_path=config_path,
                run_root=explicit_run_root,
                extra=["-IncludePairId", pair_id],
            )
            completed = self.command_service.run(runroot_command)
            prepared_run_root = self._extract_prepared_run_root(completed.stdout)
            lines.append("[run 준비]")
            lines.append(
                self._format_run_root_prepare_output(
                    output=completed.stdout.strip() or "run root 준비 완료",
                    ignored_run_root=ignored_run_root,
                    prepared_run_root=prepared_run_root,
                )
            )
            summary_text = self._run_root_summary_text(prepared_run_root)
            if summary_text:
                lines.append("")
                lines.append(summary_text)
            lines.append("")

            return {
                "output": "\n".join(lines).strip(),
                "run_root": prepared_run_root,
                "runtime_result": runtime_result,
                "window_launch_anchor_utc": window_launch_anchor_utc,
            }

        def on_success(result: dict) -> None:
            prepared_run_root = result.get("run_root", "")
            runtime_result = result.get("runtime_result")
            launch_anchor_utc = result.get("window_launch_anchor_utc", "")
            if launch_anchor_utc:
                self.window_launch_anchor_utc = launch_anchor_utc
            if runtime_result is not None:
                self._apply_runtime_refresh_result(runtime_result)
            if prepared_run_root:
                self.run_root_var.set(prepared_run_root)
            self.last_result_var.set(
                self._run_root_prepare_last_result(
                    ignored_run_root=ignored_run_root,
                    prepared_run_root=prepared_run_root,
                )
            )
            self.set_text(self.output_text, result.get("output", "준비 전체 실행 완료"))
            self.load_effective_config()

        self.run_background_task(
            state="준비 전체 실행 중",
            hint="창 준비, attach, 입력 점검, run 준비를 순서대로 실행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="준비 전체 실행 완료",
            success_hint="홈 단계 진행판과 pair 요약을 갱신했습니다.",
            failure_state="준비 전체 실행 실패",
            failure_hint="실패한 단계의 출력과 마지막 명령을 확인하세요.",
        )

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

    def start_watcher_detached(self) -> None:
        run_root = self._current_run_root_for_actions()
        config_path = self.config_path_var.get().strip()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watcher를 시작하려면 RunRoot가 먼저 준비돼야 합니다.")
            return
        if not config_path:
            messagebox.showwarning("설정 필요", "watcher를 시작하려면 ConfigPath가 필요합니다.")
            return
        watch_start_allowed, watch_start_detail = self._watch_start_allowed()
        if not watch_start_allowed:
            messagebox.showwarning("watch 시작 대기", watch_start_detail)
            return
        start_eligibility = self._watcher_start_eligibility()
        clear_stale_first = False
        if not start_eligibility.allowed and start_eligibility.cleanup_allowed:
            confirmed = messagebox.askyesno(
                "watch stale 정리",
                start_eligibility.message + "\n\n안전 정리 후 바로 watch 시작을 진행할까요?",
                parent=self,
            )
            if not confirmed:
                diagnostics = self.watcher_controller.diagnostics(self.paired_status_data, run_root)
                self.set_text(self.output_text, diagnostics.details)
                return
            clear_stale_first = True
        elif not start_eligibility.allowed:
            message = start_eligibility.message
            if start_eligibility.recommended_action:
                message += f"\n권장 조치: {start_eligibility.recommended_action}"
            messagebox.showwarning("watch 시작 차단", message)
            self.set_operator_status(
                "watch 시작 차단",
                start_eligibility.message,
                f"마지막 결과: watch 시작 차단 ({','.join(start_eligibility.reason_codes) or start_eligibility.state})",
            )
            self.set_text(self.output_text, self.watcher_controller.diagnostics(self.paired_status_data, run_root).details)
            return

        result, notes = self.watcher_controller.start(
            self.command_service,
            config_path=config_path,
            run_root=run_root,
            paired_status=self.paired_status_data,
            clear_stale_first=clear_stale_first,
        )
        if not result.ok:
            messagebox.showerror("watcher 시작 실패", result.message)
            self.set_operator_status("watcher 시작 실패", result.message, f"마지막 결과: watcher 시작 실패 ({','.join(result.reason_codes) or result.state})")
            diagnostics = self.watcher_controller.diagnostics(self.paired_status_data, run_root)
            text_lines = ["watch 시작 준비"]
            if notes:
                text_lines.extend(notes)
            text_lines.extend(["", result.message, "", diagnostics.details])
            self.set_text(self.output_text, "\n".join(text_lines))
            return
        if result.command_text:
            self.last_command_var.set(result.command_text)
        base_lines = []
        if notes:
            base_lines.extend(notes)
            base_lines.append("")
        self.set_text(
            self.output_text,
            (
                "\n".join(base_lines)
                + ("paired watcher를 별도 프로세스로 시작했습니다.\n\n" if base_lines else "paired watcher를 별도 프로세스로 시작했습니다.\n\n")
                + (result.command_text or "(command unavailable)")
                + "\n\n상태: {0}".format(result.message)
                + "\n"
                + self.watcher_controller.start_preset_note()
            ),
        )
        self.set_operator_status(
            "watcher 시작 요청",
            "수 초 뒤 paired status와 결과 탭을 빠르게 다시 읽습니다. 기본 watch 시작은 제한된 forward/run preset을 사용합니다.",
            "마지막 결과: watcher 시작 요청",
        )
        self.after(1500, self.refresh_paired_status_only)

    def recover_stale_watcher_state(self) -> None:
        run_root = self._current_run_root_for_actions()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch stale 정리에는 RunRoot가 필요합니다.")
            return

        eligibility = self._watcher_start_eligibility()
        if not eligibility.cleanup_allowed:
            diagnostics = self.watcher_controller.diagnostics(self.paired_status_data, run_root)
            messagebox.showwarning("정리 불가", "현재 상태에서는 안전하게 정리할 stale watcher control이 없습니다.")
            self.set_operator_status(
                "watch stale 정리 차단",
                "현재 상태에서는 stale control 정리를 수행할 수 없습니다.",
                f"마지막 결과: watch stale 정리 차단 ({','.join(eligibility.reason_codes) or eligibility.state})",
            )
            self.set_text(self.output_text, diagnostics.details)
            return

        confirmed = messagebox.askyesno(
            "watch stale 정리",
            "오래된 watcher stop/control 흔적을 정리합니다.\nwatcher가 stopped 상태일 때만 안전합니다.\n\n정리할까요?",
            parent=self,
        )
        if not confirmed:
            return

        result = self.watcher_controller.recover_start_blockers(self.paired_status_data, run_root)
        lines = [
            "watch stale 정리",
            f"RunRoot: {run_root}",
            f"상태: {result.state}",
            f"메시지: {result.message}",
        ]
        if result.reason_codes:
            lines.append("Reasons: " + ", ".join(result.reason_codes))
        self.set_text(self.output_text, "\n".join(lines))
        if not result.ok:
            messagebox.showwarning("정리 실패", result.message)
            self.set_operator_status(
                "watch stale 정리 실패",
                result.message,
                f"마지막 결과: watch stale 정리 실패 ({','.join(result.reason_codes) or result.state})",
            )
            diagnostics = self.watcher_controller.diagnostics(self.paired_status_data, run_root)
            self.set_text(self.output_text, "\n".join(lines + ["", diagnostics.details]))
            return

        self.set_operator_status("watch stale 정리 완료", result.message, "마지막 결과: watch stale 정리 완료")
        self.after(300, self.refresh_paired_status_only)

    def request_stop_watcher(self) -> None:
        run_root = self._current_run_root_for_actions()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch 정지 요청에는 RunRoot가 필요합니다.")
            return

        eligibility = self._watcher_stop_eligibility()
        if not eligibility.allowed:
            messagebox.showwarning("watch 정지 차단", eligibility.message)
            self.set_operator_status("watch 정지 차단", eligibility.message, f"마지막 결과: watch 정지 차단 ({','.join(eligibility.reason_codes) or eligibility.state})")
            self.set_text(self.output_text, self.watcher_controller.diagnostics(self.paired_status_data, run_root).details)
            return

        if eligibility.warning_codes:
            warning_text = "\n".join(f"- {code}" for code in eligibility.warning_codes)
            confirmed = messagebox.askyesno(
                "watch 정지 확인",
                "정지 전 확인이 필요한 상태가 있습니다.\n\n{0}\n\n정말 정지 요청을 기록할까요?".format(warning_text),
                parent=self,
            )
            if not confirmed:
                return

        result = self.watcher_controller.request_stop(self.paired_status_data, run_root)
        lines = [
            "watch 정지 요청",
            f"RunRoot: {run_root}",
            f"상태: {result.state}",
            f"메시지: {result.message}",
        ]
        if result.request_id:
            lines.append(f"RequestId: {result.request_id}")
        if result.warning_codes:
            lines.append("Warnings: " + ", ".join(result.warning_codes))
        if result.reason_codes:
            lines.append("Reasons: " + ", ".join(result.reason_codes))
        self.set_text(self.output_text, "\n".join(lines))

        if not result.ok:
            messagebox.showwarning("watch 정지 실패", result.message)
            self.set_operator_status("watch 정지 실패", result.message, f"마지막 결과: watch 정지 실패 ({','.join(result.reason_codes) or result.state})")
            self.set_text(self.output_text, "\n".join(lines + ["", self.watcher_controller.diagnostics(self.paired_status_data, run_root).details]))
            return

        self.set_operator_status("watch 정지 요청", "control file을 기록했습니다. 수 초 뒤 stopped 상태를 확인합니다.", "마지막 결과: watch 정지 요청")
        self.after(1500, self.refresh_paired_status_only)

    def restart_watcher(self) -> None:
        run_root = self._current_run_root_for_actions()
        config_path = self.config_path_var.get().strip()
        if not run_root:
            messagebox.showwarning("RunRoot 필요", "watch 재시작에는 RunRoot가 필요합니다.")
            return
        if not config_path:
            messagebox.showwarning("설정 필요", "watch 재시작에는 ConfigPath가 필요합니다.")
            return

        eligibility = self._watcher_stop_eligibility()
        if not eligibility.allowed:
            messagebox.showwarning("watch 재시작 차단", eligibility.message)
            self.set_operator_status("watch 재시작 차단", eligibility.message, f"마지막 결과: watch 재시작 차단 ({','.join(eligibility.reason_codes) or eligibility.state})")
            self.set_text(self.output_text, self.watcher_controller.diagnostics(self.paired_status_data, run_root).details)
            return

        if eligibility.warning_codes:
            warning_text = "\n".join(f"- {code}" for code in eligibility.warning_codes)
            confirmed = messagebox.askyesno(
                "watch 재시작 확인",
                "재시작 전 확인이 필요한 상태가 있습니다.\n\n{0}\n\n정지 확인 후 재시작을 진행할까요?".format(warning_text),
                parent=self,
            )
            if not confirmed:
                return

        current_context = self._current_context()
        current_paired_status = self.paired_status_data

        def status_loader(target_run_root: str):
            return self.status_service.refresh_paired_status(current_context, run_root=target_run_root)

        def worker() -> WatcherControlResult:
            return self.watcher_controller.restart(
                self.command_service,
                status_loader,
                config_path=config_path,
                run_root=run_root,
                paired_status=current_paired_status,
                poll_interval_sec=1.0,
            )

        def on_success(result: WatcherControlResult) -> None:
            if result.command_text:
                self.last_command_var.set(result.command_text)
            lines = [
                "watch 재시작 결과",
                f"RunRoot: {result.run_root}",
                f"상태: {result.state}",
                f"메시지: {result.message}",
            ]
            if result.request_id:
                lines.append(f"RequestId: {result.request_id}")
            if result.warning_codes:
                lines.append("Warnings: " + ", ".join(result.warning_codes))
            self.set_text(self.output_text, "\n".join(lines))
            self.refresh_paired_status_only()

        self.run_background_task(
            state="watch 재시작 중",
            hint="정지 요청, stopped 확인, start 요청, running 확인을 순서대로 진행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="watch 재시작 완료",
            success_hint="paired status와 결과 탭을 새 상태로 다시 읽었습니다.",
            failure_state="watch 재시작 실패",
            failure_hint="watch 상태, control file, 마지막 명령을 확인하세요.",
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
        widget.configure(state="normal")
        widget.delete("1.0", "end")
        widget.insert("1.0", value)
        widget.configure(state="disabled")

    def run_relay_status(self) -> None:
        self.run_to_output("show-relay-status.ps1")

    def _resolve_top_target_for_pair(self, pair_id: str) -> str:
        return self.pair_controller.resolve_top_target_for_pair(self.preview_rows, pair_id)

    def run_selected_pair_drill(self) -> None:
        pair_id = self.pair_id_var.get().strip()
        if not pair_id:
            messagebox.showwarning("PairId 필요", "PairId 값을 먼저 선택하세요.")
            return
        scope_allowed, scope_detail = self._selected_pair_scope_allowed(action_label="선택 Pair 실행")
        if not scope_allowed:
            messagebox.showwarning("Pair 실행 대기", scope_detail)
            return
        allowed, detail = self._selected_pair_execution_allowed()
        if not allowed:
            messagebox.showwarning("Pair 실행 대기", detail)
            return
        activation = self.get_pair_activation_state(pair_id)
        if activation and not activation.get("EffectiveEnabled", True):
            messagebox.showwarning("Pair 비활성", f"{pair_id}는 현재 비활성 상태입니다.\n사유: {activation.get('DisableReason', '') or '(none)'}")
            return

        initial_target_id = self._resolve_top_target_for_pair(pair_id)
        if not initial_target_id:
            messagebox.showerror("대상 해석 실패", f"{pair_id}의 top target을 찾지 못했습니다.")
            return

        command = self.command_service.build_powershell_file_command(
            str(ROOT / "run-headless-pair-drill.ps1"),
            extra=[
                "-ConfigPath",
                self.config_path_var.get().strip(),
                "-PairId",
                pair_id,
                "-InitialTargetId",
                initial_target_id,
                "-MaxForwardCount",
                "2",
                "-RunDurationSec",
                "900",
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
                "선택된 Pair 드릴 실행 완료",
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
                        f"이 드릴은 연속 무제한 왕복이 아니라 forward {max_forward_count}회까지만 확인합니다.",
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

        self.set_text(self.output_text, f"선택된 Pair 드릴 실행 중...\npair={pair_id}\ninitial={initial_target_id}")
        self.run_background_task(
            state="Pair 드릴 실행 중",
            hint=f"{pair_id} 한 쌍을 headless로 실행 중입니다. 완료될 때까지 버튼이 잠깁니다.",
            worker=worker,
            on_success=on_success,
            success_state="Pair 드릴 완료",
            success_hint="RunRoot가 자동 반영됐습니다. 페어 상태나 폴더 열기로 결과를 확인하세요.",
            failure_state="Pair 드릴 실패",
            failure_hint="출력 영역과 마지막 명령을 확인한 뒤 다시 시도하세요.",
        )

    def run_fixed_pair01_drill(self) -> None:
        activation = self.get_pair_activation_state("pair01")
        if activation and not activation.get("EffectiveEnabled", True):
            messagebox.showwarning("Pair 비활성", f"pair01은 현재 비활성 상태입니다.\n사유: {activation.get('DisableReason', '') or '(none)'}")
            return

        config_path = str(ROOT / "config" / "settings.bottest-live-visible.psd1")
        command = self.command_service.build_powershell_file_command(
            str(ROOT / "run-pair01-headless-drill.ps1"),
            extra=["-AsJson"],
        )

        self.last_command_var.set(subprocess.list2cmdline(command))

        def worker() -> subprocess.CompletedProcess[str]:
            return run_command(command)

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            payload = json.loads(completed.stdout)
            drill = payload.get("Drill", {})
            observed = drill.get("ObservedCounts", {})
            self.config_path_var.set(config_path)
            self.pair_id_var.set("pair01")
            self.run_root_var.set(payload.get("RunRoot", ""))
            lines = [
                "pair01 즉시 실행 완료",
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

        self.set_text(self.output_text, "pair01 전용 headless 승인 드릴 실행 중...")
        self.run_background_task(
            state="pair01 즉시 실행 중",
            hint="고정된 visible config와 pair01 설정으로 한 번 왕복 드릴을 실행 중입니다.",
            worker=worker,
            on_success=on_success,
            success_state="pair01 즉시 실행 완료",
            success_hint="RunRoot와 preview 출력이 자동 반영됐습니다.",
            failure_state="pair01 즉시 실행 실패",
            failure_hint="출력 영역과 마지막 명령을 확인하세요.",
        )

    def run_paired_status(self) -> None:
        self.run_to_output("show-paired-exchange-status.ps1")

    def run_paired_summary(self) -> None:
        self.run_to_output("show-paired-run-summary.ps1")

    def run_visibility_check(self) -> None:
        self.last_command_var.set(self._runtime_refresh_command_preview())

        def worker():
            return self.refresh_controller.refresh_runtime(self._current_context())

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
        self.run_to_output("check-headless-exec-readiness.ps1", require_run_root=True)

    def run_effective_json(self) -> None:
        self.run_to_output("show-effective-config.ps1", extra=["-AsJson"], require_pair=False)

    def run_to_output(
        self,
        script_name: str,
        *,
        extra: list[str] | None = None,
        require_run_root: bool = False,
        require_pair: bool = False,
        refresh_after: bool = False,
        refresh_scope: str = "",
    ) -> None:
        if require_run_root and not self.run_root_var.get().strip():
            messagebox.showwarning("RunRoot 필요", "RunRoot 값을 먼저 입력하세요.")
            return
        if require_pair and not self.pair_id_var.get().strip():
            messagebox.showwarning("PairId 필요", "PairId 값을 먼저 입력하세요.")
            return

        def worker() -> subprocess.CompletedProcess[str]:
            return self.run_script(
                script_name,
                extra=extra,
                run_root_override=self._current_run_root_for_actions(),
                pair_id_override=self._selected_pair_id(),
                target_id_override=self.target_id_var.get().strip(),
            )

        preview_command = self.command_service.build_script_command(
            script_name=script_name,
            config_path=self.config_path_var.get().strip(),
            run_root=self._current_run_root_for_actions(),
            pair_id=self._selected_pair_id(),
            target_id=self.target_id_var.get().strip(),
            extra=extra,
        )
        self.last_command_var.set(subprocess.list2cmdline(preview_command))

        def on_success(completed: subprocess.CompletedProcess[str]) -> None:
            output = completed.stdout.strip()
            if completed.stderr.strip():
                output += ("\n\nSTDERR:\n" + completed.stderr.strip())
            self.set_text(self.output_text, output or "(no output)")
            self.last_result_var.set(f"마지막 결과: {script_name} 실행 완료")
            if refresh_after:
                if refresh_scope == "runtime":
                    self.refresh_runtime_status_only()
                elif refresh_scope == "paired":
                    self.refresh_paired_status_only()
                else:
                    self.load_effective_config()

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
