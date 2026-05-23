from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Mapping, Sequence


TARGET_AUTOLOOP_POLICY_SELECTION_SCHEMA_VERSION = 1


def target_autoloop_policy_default_selection_path(snapshot_dir: Path) -> Path:
    return snapshot_dir / "target-autoloop-policy-selection.json"


def target_autoloop_policy_selection_scope_slug(value: str, fallback: str) -> str:
    normalized = str(value or "").strip().lower()
    if not normalized:
        return fallback
    digest = hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:10]
    return f"{fallback}-{digest}"


def target_autoloop_policy_scoped_selection_path(
    *,
    snapshot_dir: Path,
    config_path: str,
    run_root: str,
) -> Path:
    config_slug = target_autoloop_policy_selection_scope_slug(config_path, "config")
    run_root_slug = target_autoloop_policy_selection_scope_slug(run_root, "runroot")
    return snapshot_dir / "target-autoloop-policy-selection" / f"{config_slug}__{run_root_slug}.json"


def target_autoloop_policy_target_ids_hash(target_ids: Sequence[str]) -> str:
    normalized_target_ids = [str(item or "").strip() for item in target_ids if str(item or "").strip()]
    digest = hashlib.sha1("\n".join(normalized_target_ids).encode("utf-8")).hexdigest()
    return digest[:12]


def build_target_autoloop_policy_selection_payload(
    *,
    target_ids: Sequence[str],
    selected_target_ids: Sequence[str],
    config_path: str,
    run_root: str,
    filter_mode: str,
    updated_at: str,
) -> dict[str, object]:
    normalized_target_ids = [str(item or "").strip() for item in target_ids if str(item or "").strip()]
    selected_set = {str(item or "").strip() for item in selected_target_ids if str(item or "").strip()}
    ordered_selected_target_ids = [target_id for target_id in normalized_target_ids if target_id in selected_set]
    return {
        "SchemaVersion": TARGET_AUTOLOOP_POLICY_SELECTION_SCHEMA_VERSION,
        "ConfigPath": str(config_path or "").strip(),
        "RunRoot": str(run_root or "").strip(),
        "TargetIdsHash": target_autoloop_policy_target_ids_hash(normalized_target_ids),
        "FilterMode": str(filter_mode or "").strip() or "all",
        "SelectedTargetIds": ordered_selected_target_ids,
        "UpdatedAt": str(updated_at or "").strip(),
    }


def build_target_autoloop_policy_selection_snapshot_summary_text(status: Mapping[str, object]) -> str:
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
            "[target-autoloop selection snapshot summary]",
            "currentPath=" + str(status.get("CurrentPath", "") or ""),
            "loadedPath=" + (str(status.get("LoadedPath", "") or "") or "(none)"),
            "loadedExists=" + str(bool(status.get("LoadedExists", False))),
            "currentFilter=" + (str(current_payload.get("FilterMode", "") or "").strip() or "all"),
            "currentSelectedCount=" + str(len(current_selected_target_ids)),
            "currentSelectedTargets=" + (", ".join(current_selected_target_ids) if current_selected_target_ids else "(none)"),
            "savedFilter=" + (str(status.get("SavedFilterMode", "") or "").strip() or "(none)"),
            "savedSelectedCount=" + str(len(saved_selected_target_ids)),
            "savedSelectedTargets=" + (", ".join(saved_selected_target_ids) if saved_selected_target_ids else "(none)"),
            "savedUpdatedAt=" + (str(status.get("SavedUpdatedAt", "") or "").strip() or "(none)"),
            "savedSchemaVersion=" + (str(status.get("SavedSchemaVersion", "") or "").strip() or "(none)"),
            "loadError=" + (str(status.get("LoadError", "") or "").strip() or "(none)"),
        ]
    )
