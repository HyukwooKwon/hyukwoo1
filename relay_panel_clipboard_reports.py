from __future__ import annotations

import json
from typing import Mapping, Sequence


def format_target_autoloop_selection_export_report(export_path: str, payload: Mapping[str, object]) -> str:
    return "[target-autoloop selection export]\npath={path}\n\n{payload}".format(
        path=export_path,
        payload=json.dumps(dict(payload), ensure_ascii=False, indent=2),
    )


def format_target_autoloop_selection_snapshot_status_report(status: Mapping[str, object]) -> str:
    current_payload = dict(status.get("CurrentPayload", {}) or {})
    current_selected_target_ids = [
        str(item or "").strip()
        for item in list(current_payload.get("SelectedTargetIds", []) or [])
        if str(item or "").strip()
    ]
    saved_selected_target_ids = [
        str(item or "").strip()
        for item in list(status.get("SavedSelectedTargetIds", []) or [])
        if str(item or "").strip()
    ]
    return "\n".join(
        [
            "[target-autoloop selection snapshot status]",
            "currentPath=" + str(status.get("CurrentPath", "") or ""),
            "legacyPath=" + (str(status.get("LegacyPath", "") or "") or "(none)"),
            "loadedPath=" + (str(status.get("LoadedPath", "") or "") or "(none)"),
            "loadedExists=" + str(bool(status.get("LoadedExists", False))),
            "currentFilter=" + (str(current_payload.get("FilterMode", "") or "").strip() or "all"),
            "currentSelectedTargets=" + (", ".join(current_selected_target_ids) if current_selected_target_ids else "(none)"),
            "savedFilter=" + (str(status.get("SavedFilterMode", "") or "").strip() or "(none)"),
            "savedSelectedTargets=" + (", ".join(saved_selected_target_ids) if saved_selected_target_ids else "(none)"),
            "savedUpdatedAt=" + (str(status.get("SavedUpdatedAt", "") or "").strip() or "(none)"),
            "savedSchemaVersion=" + (str(status.get("SavedSchemaVersion", "") or "").strip() or "(none)"),
            "loadError=" + (str(status.get("LoadError", "") or "").strip() or "(none)"),
        ]
    )


def format_target_autoloop_selection_import_preview_report(analysis: Mapping[str, object]) -> str:
    current_selected_target_ids = [
        str(item or "").strip()
        for item in list(analysis.get("current_selected_target_ids", []) or [])
        if str(item or "").strip()
    ]
    known_target_ids = [
        str(item or "").strip()
        for item in list(analysis.get("known_target_ids", []) or [])
        if str(item or "").strip()
    ]
    unknown_target_ids = [
        str(item or "").strip()
        for item in list(analysis.get("unknown_target_ids", []) or [])
        if str(item or "").strip()
    ]
    added_target_ids = [
        str(item or "").strip()
        for item in list(analysis.get("added_target_ids", []) or [])
        if str(item or "").strip()
    ]
    removed_target_ids = [
        str(item or "").strip()
        for item in list(analysis.get("removed_target_ids", []) or [])
        if str(item or "").strip()
    ]
    unchanged_target_ids = [
        str(item or "").strip()
        for item in list(analysis.get("unchanged_target_ids", []) or [])
        if str(item or "").strip()
    ]
    warnings = [
        str(item or "").strip()
        for item in list(analysis.get("warnings", []) or [])
        if str(item or "").strip()
    ]
    return "\n".join(
        [
            "[target-autoloop selection import preview]",
            "path=" + str(analysis.get("path", "") or ""),
            "canApply=" + str(not bool(str(analysis.get("blocking_reason", "") or "").strip())),
            "blockingReason=" + (str(analysis.get("blocking_reason", "") or "").strip() or "(none)"),
            "currentFilter=" + (str(analysis.get("current_filter_mode", "") or "").strip() or "all"),
            "importFilter=" + (str((analysis.get("payload", {}) or {}).get("FilterMode", "") or "").strip() or "(empty)"),
            "resolvedFilter=" + (str(analysis.get("resolved_filter_mode", "") or "").strip() or "all"),
            "currentSelectedTargets=" + (", ".join(current_selected_target_ids) if current_selected_target_ids else "(none)"),
            "knownTargets=" + (", ".join(known_target_ids) if known_target_ids else "(none)"),
            "unknownTargets=" + (", ".join(unknown_target_ids) if unknown_target_ids else "(none)"),
            "addTargets=" + (", ".join(added_target_ids) if added_target_ids else "(none)"),
            "removeTargets=" + (", ".join(removed_target_ids) if removed_target_ids else "(none)"),
            "keepTargets=" + (", ".join(unchanged_target_ids) if unchanged_target_ids else "(none)"),
            "warnings=" + (" / ".join(warnings) if warnings else "(none)"),
        ]
    )


def format_target_autoloop_selection_import_apply_report(
    *,
    preview_path: str,
    filter_mode: str,
    selected_target_ids: Sequence[str],
    added_target_ids: Sequence[str],
    removed_target_ids: Sequence[str],
    unchanged_target_ids: Sequence[str],
    warnings: Sequence[str],
) -> str:
    return "\n".join(
        [
            "[target-autoloop selection import apply]",
            "path=" + str(preview_path or "").strip(),
            "filter=" + (str(filter_mode or "").strip() or "all"),
            "selectedTargets=" + (", ".join([str(item or "").strip() for item in selected_target_ids if str(item or "").strip()]) or "(none)"),
            "addTargets=" + (", ".join([str(item or "").strip() for item in added_target_ids if str(item or "").strip()]) or "(none)"),
            "removeTargets=" + (", ".join([str(item or "").strip() for item in removed_target_ids if str(item or "").strip()]) or "(none)"),
            "keepTargets=" + (", ".join([str(item or "").strip() for item in unchanged_target_ids if str(item or "").strip()]) or "(none)"),
            "warnings=" + (" / ".join([str(item or "").strip() for item in warnings if str(item or "").strip()]) or "(none)"),
        ]
    )


def format_target_autoloop_selection_current_json_report(payload: Mapping[str, object]) -> str:
    return "[target-autoloop current selection JSON]\n" + json.dumps(dict(payload), ensure_ascii=False, indent=2)
