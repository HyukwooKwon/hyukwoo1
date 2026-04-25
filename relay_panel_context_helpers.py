from __future__ import annotations

import os
from dataclasses import replace
from datetime import datetime
from typing import Mapping, Sequence

from relay_panel_models import AppContext
from relay_panel_operator_state import (
    ActionContextState,
    ArtifactQueryContextState,
    InspectionContextState,
    QueryHistoryRecord,
)


CONTEXT_SOURCE_LABELS = {
    "controls": "상단 실행 선택",
    "home-pair-apply": "홈 Pair 반영",
    "inspection-apply": "inspection 반영",
    "runtime-active-pair": "active pair 동기화",
    "pair01-drill": "pair01 drill 완료",
    "preview-row": "preview row",
    "board-target": "board 선택",
    "manual-inspection": "inspection 수동",
}


def context_source_label(source: str) -> str:
    normalized = str(source or "").strip()
    if not normalized:
        return "(없음)"
    return CONTEXT_SOURCE_LABELS.get(normalized, normalized)


def format_action_context_summary(context: ActionContextState) -> str:
    return "{0}/{1} [{2}]".format(
        context.pair_id or "(pair 없음)",
        context.target_id or "(target 없음)",
        context_source_label(context.source),
    )


def format_artifact_query_context_summary(context: ArtifactQueryContextState) -> str:
    parts: list[str] = []
    run_root = str(context.run_root or "").strip()
    if run_root:
        run_label = os.path.basename(os.path.normpath(run_root)) or run_root
        parts.append(f"artifact-run={run_label}")
    if context.pair_id:
        parts.append(f"artifact-pair={context.pair_id}")
    if context.target_id:
        parts.append(f"artifact-target={context.target_id}")
    if context.path_kind:
        parts.append(f"path={context.path_kind}")
    if context.latest_only:
        parts.append("latest-only")
    if not context.include_missing:
        parts.append("missing-off")
    return " / ".join(parts)


def resolve_inspection_context(
    *,
    selected_row: Mapping[str, object] | None,
    selected_row_index: int | None,
    stored: InspectionContextState,
    fallback_target_id: str = "",
) -> InspectionContextState:
    row = dict(selected_row or {})
    pair_id = str(row.get("PairId", "") or stored.pair_id or "").strip()
    target_id = str(row.get("TargetId", "") or stored.target_id or "").strip()
    if not target_id:
        target_id = str(fallback_target_id or "").strip()
    source = stored.source
    if row:
        source = source or "preview-row"
    if not source and (pair_id or target_id):
        source = "manual-inspection"
    return InspectionContextState(
        pair_id=pair_id,
        target_id=target_id,
        source=source,
        row_index=selected_row_index if row else stored.row_index,
    )


def format_inspection_context_summary(context: InspectionContextState) -> str:
    if not context.pair_id and not context.target_id:
        return "(없음)"
    return "{0}/{1} [{2}]".format(
        context.pair_id or "(pair 없음)",
        context.target_id or "(target 없음)",
        context_source_label(context.source),
    )


def format_query_context_summary(context: AppContext | None) -> str:
    if context is None:
        return ""
    parts: list[str] = []
    run_root = str(context.run_root or "").strip()
    if run_root:
        run_label = os.path.basename(os.path.normpath(run_root)) or run_root
        parts.append(f"run={run_label}")
    if str(context.pair_id or "").strip():
        parts.append(f"pair={context.pair_id}")
    if str(context.target_id or "").strip():
        parts.append(f"target={context.target_id}")
    return " / ".join(parts)


def append_query_history(
    records: Sequence[QueryHistoryRecord],
    *,
    value: str,
    context: str = "",
    timestamp: str | None = None,
    limit: int = 5,
) -> tuple[list[QueryHistoryRecord], list[str]]:
    summary = str(value or "").strip()
    next_records = list(records)
    if not summary:
        return next_records, [item.summary() for item in next_records]
    stamp = str(timestamp or "").strip() or datetime.now().strftime("%H:%M:%S")
    next_records.append(QueryHistoryRecord(label=summary, context=context, timestamp=stamp))
    if len(next_records) > limit:
        next_records = next_records[-limit:]
    return next_records, [item.summary() for item in next_records]
