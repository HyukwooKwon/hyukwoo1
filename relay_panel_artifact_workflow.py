from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from relay_panel_artifacts import TargetArtifactState


@dataclass(frozen=True)
class ArtifactActionContextSnapshot:
    state: TargetArtifactState
    config_path: str
    run_root: str
    run_root_is_stale: bool


@dataclass(frozen=True)
class ArtifactSourceSelection:
    summary_path: str
    review_zip_path: str


@dataclass(frozen=True)
class ArtifactCommandPlan:
    command: tuple[str, ...]
    execution_path: str
    used_wrapper: bool
    contract_paths: dict[str, object]


@dataclass(frozen=True)
class ArtifactSubmitPreflight:
    context: ArtifactActionContextSnapshot
    sources: ArtifactSourceSelection
    check_plan: ArtifactCommandPlan
    payload: dict[str, Any]
    preflight_text: str
    requires_overwrite: bool
    latest_state: str
    latest_zip_path: str


@dataclass(frozen=True)
class ArtifactSubmitLaunchRequest:
    preflight: ArtifactSubmitPreflight
    submit_plan: ArtifactCommandPlan


def build_artifact_action_record(
    *,
    action: str,
    status: str,
    context: ArtifactActionContextSnapshot,
    sources: ArtifactSourceSelection,
    plan: ArtifactCommandPlan,
    recorded_at: str,
    requires_overwrite: bool = False,
    latest_state: str = "",
    latest_zip_path: str = "",
    error: str = "",
) -> dict[str, object]:
    record: dict[str, object] = {
        "Action": action,
        "Status": status,
        "RecordedAt": recorded_at,
        "UsedWrapper": plan.used_wrapper,
        "ExecutionPath": plan.execution_path,
        "SummarySourcePath": sources.summary_path,
        "ReviewZipSourcePath": sources.review_zip_path,
        "RunRoot": context.run_root,
        "RunRootIsStale": context.run_root_is_stale,
    }
    if requires_overwrite:
        record["RequiresOverwrite"] = True
    if latest_state:
        record["LatestState"] = latest_state
    if latest_zip_path:
        record["LatestZipPath"] = latest_zip_path
    if error:
        record["Error"] = error
    return record
