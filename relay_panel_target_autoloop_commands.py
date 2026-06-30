from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TargetAutoloopCommandPlan:
    script_name: str
    run_root_override: str | None
    extra: tuple[str, ...]
    display_command: str

    def extra_args(self) -> list[str]:
        return list(self.extra)


def build_start_watcher_command_plan(
    *,
    run_root: str,
    target_id: str = "",
    target_ids: list[str] | tuple[str, ...] | None = None,
) -> TargetAutoloopCommandPlan:
    normalized_target_ids = [
        str(item or "").strip()
        for item in (list(target_ids or []) if target_ids is not None else [target_id])
        if str(item or "").strip()
    ]
    normalized_target_ids = list(dict.fromkeys(normalized_target_ids))
    extra = ["-RunMode", "target-autoloop"]
    display_target_part = ""
    if normalized_target_ids:
        extra += ["-Targets"]
        extra += normalized_target_ids
        display_target_part = " -Targets " + ",".join(normalized_target_ids)
    extra += ["-Detached", "-AsJson"]
    return TargetAutoloopCommandPlan(
        script_name="tests/Start-TargetAutoloopWatcher.ps1",
        run_root_override=str(run_root or ""),
        extra=tuple(extra),
        display_command=f"Start-TargetAutoloopWatcher.ps1 -RunMode target-autoloop{display_target_part} -Detached -AsJson",
    )


def build_process_once_command_plan(*, run_root: str, target_id: str = "") -> TargetAutoloopCommandPlan:
    normalized_target_id = str(target_id or "").strip()
    extra = ["-RunMode", "target-autoloop"]
    display_target_part = ""
    if normalized_target_id:
        extra += ["-Targets", normalized_target_id]
        display_target_part = f" -Targets {normalized_target_id}"
    extra += ["-ProcessOnce", "-AsJson"]
    return TargetAutoloopCommandPlan(
        script_name="tests/Start-TargetAutoloopWatcher.ps1",
        run_root_override=str(run_root or ""),
        extra=tuple(extra),
        display_command=f"Start-TargetAutoloopWatcher.ps1 -RunMode target-autoloop{display_target_part} -ProcessOnce -AsJson",
    )


def build_publish_ready_marker_command_plan(*, run_root: str, target_id: str) -> TargetAutoloopCommandPlan:
    normalized_target_id = str(target_id or "").strip()
    return TargetAutoloopCommandPlan(
        script_name="tests/Publish-TargetAutoloopArtifact.ps1",
        run_root_override=str(run_root or ""),
        extra=("-TargetId", normalized_target_id, "-Overwrite", "-AsJson"),
        display_command=(
            "Publish-TargetAutoloopArtifact.ps1 "
            f"-TargetId {normalized_target_id} -Overwrite -AsJson"
        ),
    )


def build_extend_cycle_limit_command_plan(
    *,
    run_root: str,
    target_id: str,
    additional_cycles: int,
) -> TargetAutoloopCommandPlan:
    normalized_target_id = str(target_id or "").strip()
    normalized_additional_cycles = max(1, int(additional_cycles or 1))
    return TargetAutoloopCommandPlan(
        script_name="tests/Extend-TargetAutoloopCycleLimit.ps1",
        run_root_override=str(run_root or ""),
        extra=("-TargetId", normalized_target_id, "-AdditionalCycles", str(normalized_additional_cycles), "-AsJson"),
        display_command=(
            "Extend-TargetAutoloopCycleLimit.ps1 "
            f"-TargetId {normalized_target_id} -AdditionalCycles {normalized_additional_cycles} -AsJson"
        ),
    )


def build_prepare_run_root_command_plan(
    *,
    selected_only: bool,
    enabled_target_ids: list[str],
) -> TargetAutoloopCommandPlan:
    extra: list[str] = ["-RunMode", "target-autoloop"]
    normalized_target_ids = [
        str(target_id or "").strip()
        for target_id in list(enabled_target_ids or [])
        if str(target_id or "").strip()
    ]
    if selected_only:
        extra += ["-Targets", ",".join(normalized_target_ids)]
    extra += ["-AsJson"]
    target_part = " -Targets " + ",".join(normalized_target_ids) if selected_only else ""
    return TargetAutoloopCommandPlan(
        script_name="tests/Start-TargetAutoloopRun.ps1",
        run_root_override="",
        extra=tuple(extra),
        display_command=f"Start-TargetAutoloopRun.ps1 -RunMode target-autoloop{target_part} -AsJson",
    )


def build_router_restart_command_plan() -> TargetAutoloopCommandPlan:
    return TargetAutoloopCommandPlan(
        script_name="router/Restart-RouterForConfig.ps1",
        run_root_override=None,
        extra=("-AsJson",),
        display_command="Restart-RouterForConfig.ps1 -AsJson",
    )


def build_requeue_retry_pending_command_plan(
    *,
    target_ids: list[str],
    retry_paths: list[str] | None = None,
) -> TargetAutoloopCommandPlan:
    normalized_target_ids = [
        str(target_id or "").strip()
        for target_id in list(target_ids or [])
        if str(target_id or "").strip()
    ]
    normalized_retry_paths = [
        str(retry_path or "").strip()
        for retry_path in list(retry_paths or [])
        if str(retry_path or "").strip()
    ]
    extra: list[str] = []
    if len(normalized_target_ids) == 1:
        extra += ["-TargetId", normalized_target_ids[0]]
    if normalized_retry_paths:
        extra += ["-RetryPath", *normalized_retry_paths]
    display_parts: list[str] = []
    if len(normalized_target_ids) == 1:
        display_parts.append(f"-TargetId {normalized_target_ids[0]}")
    if normalized_retry_paths:
        display_parts.append(f"-RetryPath ({len(normalized_retry_paths)} current)")
    display_suffix = " " + " ".join(display_parts) if display_parts else ""
    return TargetAutoloopCommandPlan(
        script_name="router/Requeue-RetryPending.ps1",
        run_root_override=None,
        extra=tuple(extra),
        display_command=f"Requeue-RetryPending.ps1{display_suffix}",
    )


def build_control_action_command_plan(
    *,
    action: str,
    requested_by: str = "relay_operator_panel",
    run_root: str,
) -> TargetAutoloopCommandPlan:
    normalized_action = str(action or "").strip()
    return TargetAutoloopCommandPlan(
        script_name="tests/Request-TargetAutoloopControl.ps1",
        run_root_override=str(run_root or ""),
        extra=("-Action", normalized_action, "-RequestedBy", str(requested_by or "").strip(), "-AsJson"),
        display_command=f"Request-TargetAutoloopControl.ps1 -Action {normalized_action} -RequestedBy {str(requested_by or '').strip()} -AsJson",
    )
