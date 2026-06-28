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


def build_start_watcher_command_plan(*, run_root: str) -> TargetAutoloopCommandPlan:
    return TargetAutoloopCommandPlan(
        script_name="tests/Start-TargetAutoloopWatcher.ps1",
        run_root_override=str(run_root or ""),
        extra=("-RunMode", "target-autoloop", "-Detached", "-AsJson"),
        display_command="Start-TargetAutoloopWatcher.ps1 -RunMode target-autoloop -Detached -AsJson",
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
        extra=("-AdditionalCycles", str(normalized_additional_cycles), "-AsJson"),
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


def build_requeue_retry_pending_command_plan(*, target_ids: list[str]) -> TargetAutoloopCommandPlan:
    normalized_target_ids = [
        str(target_id or "").strip()
        for target_id in list(target_ids or [])
        if str(target_id or "").strip()
    ]
    extra: list[str] = []
    if len(normalized_target_ids) == 1:
        extra += ["-TargetId", normalized_target_ids[0]]
    display_suffix = f" -TargetId {normalized_target_ids[0]}" if len(normalized_target_ids) == 1 else ""
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
