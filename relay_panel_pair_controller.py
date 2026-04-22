from __future__ import annotations

from relay_panel_artifacts import ArtifactService
from relay_panel_models import PairSummaryModel, PanelStateModel


class PairController:
    def __init__(self, artifact_service: ArtifactService | None = None) -> None:
        self.artifact_service = artifact_service or ArtifactService()

    def selected_summary(self, panel_state: PanelStateModel | None, pair_id: str) -> PairSummaryModel | None:
        if not panel_state or not pair_id:
            return None
        for summary in panel_state.pairs:
            if summary.pair_id == pair_id:
                return summary
        return None

    def build_summary_detail(self, summary: PairSummaryModel | None) -> str:
        if not summary:
            return "선택된 pair 요약이 없습니다."
        reason, action = self._describe_pair_latest_state(summary.latest_state)
        parts = [
            "{0}: {1}".format(summary.pair_id, summary.detail),
            "lane watcher={0}".format(summary.lane_watcher_status),
        ]
        if reason:
            parts.append("차단 이유={0}".format(reason))
        if action:
            parts.append("다음 조치={0}".format(action))
        return " / ".join(parts)

    def top_preview_index(self, preview_rows: list[dict], pair_id: str) -> int | None:
        if not pair_id:
            return None
        for index, row in enumerate(preview_rows):
            if row.get("PairId", "") == pair_id and row.get("RoleName", "") == "top":
                return index
        return None

    def resolve_top_target_for_pair(self, preview_rows: list[dict], pair_id: str) -> str:
        preview_index = self.top_preview_index(preview_rows, pair_id)
        if preview_index is not None:
            target_id = preview_rows[preview_index].get("TargetId", "")
            if target_id:
                return target_id
        fallback_map = {
            "pair01": "target01",
            "pair02": "target02",
            "pair03": "target03",
            "pair04": "target04",
        }
        return fallback_map.get(pair_id, "")

    def _describe_pair_latest_state(self, latest_state: str) -> tuple[str, str]:
        normalized = str(latest_state or "").strip()
        for token in self.artifact_service.STATE_REASON_ACTION_MAP:
            if token in normalized:
                return self.artifact_service.describe_latest_state(token)
        if normalized in {"", "no-run"}:
            return ("아직 생성된 review 산출물이 없습니다.", "review zip 생성 여부 확인")
        return self.artifact_service.describe_latest_state(normalized)
