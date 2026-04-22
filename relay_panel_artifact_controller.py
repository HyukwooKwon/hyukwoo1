from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from relay_panel_artifacts import ArtifactPreviewModel, ArtifactQuery, ArtifactService, PairArtifactSummary, TargetArtifactState


@dataclass
class ArtifactTabViewState:
    states: list[TargetArtifactState]
    pair_summaries: list[PairArtifactSummary]
    pair_values: list[str]
    target_values: list[str]
    selected_target_id: str
    preview: ArtifactPreviewModel | None
    status_base_text: str
    status_text: str


class ArtifactTabController:
    def __init__(self, artifact_service: ArtifactService) -> None:
        self.artifact_service = artifact_service

    def get_preview(self, states: list[TargetArtifactState], target_id: str) -> ArtifactPreviewModel | None:
        return self.artifact_service.get_preview_model(states, target_id)

    def build_view_state(
        self,
        *,
        effective_data: dict | None,
        paired_status: dict | None,
        query: ArtifactQuery,
        selected_target_id: str,
        watcher_status: str,
        paired_status_error: str,
    ) -> ArtifactTabViewState:
        if not effective_data:
            return ArtifactTabViewState(
                states=[],
                pair_summaries=[],
                pair_values=[""],
                target_values=[""],
                selected_target_id="",
                preview=None,
                status_base_text="결과 / 산출물 데이터를 아직 읽지 못했습니다.",
                status_text="결과 / 산출물 데이터를 아직 읽지 못했습니다.",
            )

        all_states = self.artifact_service.compute_target_artifact_states(effective_data, paired_status)
        pair_values = [""] + sorted({state.pair_id for state in all_states if state.pair_id})
        target_values = [""] + sorted({state.target_id for state in all_states if state.target_id})
        states = self.artifact_service.filter_target_artifact_states(all_states, query)
        pair_summaries = self.artifact_service.build_pair_summaries(states)
        resolved_target_id = self._resolve_selected_target_id(states, selected_target_id)
        preview = self.artifact_service.get_preview_model(states, resolved_target_id) if resolved_target_id else None
        status_base_text = self._build_status_text(
            run_root=query.run_root,
            watcher_status=watcher_status,
            states=states,
            pair_summaries=pair_summaries,
            paired_status_error=paired_status_error,
        )
        status_text = self.decorate_status_text(status_base_text, preview)
        return ArtifactTabViewState(
            states=states,
            pair_summaries=pair_summaries,
            pair_values=pair_values,
            target_values=target_values,
            selected_target_id=resolved_target_id,
            preview=preview,
            status_base_text=status_base_text,
            status_text=status_text,
        )

    def decorate_status_text(self, base_text: str, preview: ArtifactPreviewModel | None) -> str:
        summary_bits = [base_text] if base_text else []
        if preview is not None:
            summary_bits.append("selected={0}".format(preview.title))
            if preview.state_label:
                summary_bits.append("state={0}".format(preview.state_label))
            if preview.blocker_reason:
                summary_bits.append("차단={0}".format(preview.blocker_reason))
            if preview.recommended_action:
                summary_bits.append("다음={0}".format(preview.recommended_action))
            if preview.source_outbox_next_action:
                summary_bits.append("next={0}".format(self.artifact_service.display_next_action(preview.source_outbox_next_action)))
            if preview.dispatch_state:
                summary_bits.append("dispatch={0}".format(self.artifact_service.display_dispatch_state(preview.dispatch_state)))
        return " | ".join(summary_bits) if summary_bits else "(없음)"

    def _resolve_selected_target_id(self, states: list[TargetArtifactState], selected_target_id: str) -> str:
        if selected_target_id and any(state.target_id == selected_target_id for state in states):
            return selected_target_id
        if states:
            return states[0].target_id
        return ""

    def _build_status_text(
        self,
        *,
        run_root: str,
        watcher_status: str,
        states: list[TargetArtifactState],
        pair_summaries: list[PairArtifactSummary],
        paired_status_error: str,
    ) -> str:
        handoff_ready_count = sum(1 for item in states if self.artifact_service.is_handoff_ready(item))
        dispatch_running_count = sum(1 for item in states if item.dispatch_state == "running")
        summary_bits = [
            "run={0}".format(Path(run_root).name or "(none)"),
            "watcher={0}".format(watcher_status),
            "rows={0}".format(len(states)),
            "pairs={0}".format(len(pair_summaries)),
            "ready={0}".format(handoff_ready_count),
            "dispatchRunning={0}".format(dispatch_running_count),
            "errors={0}".format(sum(1 for item in states if item.error_present)),
            "zipTargets={0}".format(sum(1 for item in states if item.zip_count > 0)),
        ]
        if paired_status_error:
            summary_bits.append("pair-status 일부 생략")
        return " | ".join(summary_bits) if summary_bits else "(없음)"
