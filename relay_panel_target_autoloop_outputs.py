from __future__ import annotations

from dataclasses import dataclass


def _text(value: object, default: str = "") -> str:
    text = str(value or "").strip()
    return text if text else default


def _list_text(value: object) -> str:
    if not isinstance(value, list):
        return "(none)"
    return ", ".join(str(item) for item in value if str(item)) or "(none)"


def _int_value(value: object, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _string_list(value: object) -> list[str]:
    if isinstance(value, (list, tuple, set)):
        return [str(item).strip() for item in value if str(item).strip()]
    text = str(value or "").strip()
    return [text] if text else []


def format_router_restart_success_lines(
    *,
    action_title: str,
    config_path: str,
    run_root: str,
    restart_payload: dict[str, object],
    after_snapshot: dict[str, object],
) -> list[str]:
    after_router_session = after_snapshot.get("router_session", {})
    if not isinstance(after_router_session, dict):
        after_router_session = {}
    router_state = str(after_snapshot.get("router_session_state", "") or "-")
    return [
        action_title,
        f"ConfigPath: {restart_payload.get('ConfigPath', config_path) or config_path}",
        f"RunRoot: {run_root or '(none)'}",
        f"RouterMutexName: {restart_payload.get('RouterMutexName', '(none)')}",
        f"MatchedProcessIds: {_list_text(restart_payload.get('MatchedProcessIds', []))}",
        f"StoppedProcessIds: {_list_text(restart_payload.get('StoppedProcessIds', []))}",
        f"StartedProcessId: {restart_payload.get('StartedProcessId', '(none)')}",
        f"EffectiveRouterPid: {restart_payload.get('EffectiveRouterPid', '(none)')}",
        f"MutexHeld: {restart_payload.get('MutexHeld', '(unknown)')}",
        f"StdoutLogPath: {restart_payload.get('StdoutLogPath', '(none)')}",
        f"StderrLogPath: {restart_payload.get('StderrLogPath', '(none)')}",
        "",
        "재시작 후 세션 확인",
        f"RouterSessionState: {router_state}",
        f"RouterLauncherSessionId: {after_router_session.get('router_launcher_session_id', '(none)')}",
        f"RuntimeLauncherSessionId: {after_router_session.get('runtime_launcher_session_id', '(none)')}",
        f"RouterPid: {after_router_session.get('router_pid', '(none)')}",
        f"RouterPidExists: {after_router_session.get('router_pid_exists', '(unknown)')}",
        f"RouterMutexName: {after_router_session.get('router_mutex_name', '(none)')}",
        f"RouterMutexHeld: {after_router_session.get('router_mutex_held', '(unknown)')}",
        f"RouterStateAgeSeconds: {after_router_session.get('router_state_age_seconds', '(none)')}",
        f"RouterSessionPathSource: {after_router_session.get('path_source', '(none)')}",
        f"RouterStatePath: {after_router_session.get('router_state_path', '(none)')}",
        f"RuntimeMapPath: {after_router_session.get('runtime_map_path', '(none)')}",
    ]


def format_router_restart_ack_detail(
    *,
    router_state: str,
    restart_payload: dict[str, object],
) -> str:
    return "ack: routerSession={0} / pid={1}".format(
        router_state,
        str(restart_payload.get("EffectiveRouterPid", "") or restart_payload.get("StartedProcessId", "") or "(none)"),
    )


def format_router_restart_failure_lines(
    *,
    action_title: str,
    config_path: str,
    run_root: str,
    formatted_error: str,
) -> list[str]:
    return [
        f"[{action_title}]",
        "router 세션 재시작 실패",
        f"ConfigPath: {config_path}",
        f"RunRoot: {run_root or '(none)'}",
        formatted_error,
    ]


def format_config_auto_fix_label(prepare_config_backup_path: object) -> str:
    backup_path = str(prepare_config_backup_path or "").strip()
    if backup_path:
        return f"TargetAutoloop.Enabled=True 저장 완료 / backup={backup_path}"
    return "필요 없음"


def format_prepare_runroot_success_lines(
    *,
    action_title: str,
    prepared_run_root: str,
    payload: dict[str, object],
    target_scope_text: str,
    prepare_config_backup_path: object,
) -> list[str]:
    target_ids_payload = [
        str(item or "").strip()
        for item in list(payload.get("TargetIds", []) or [])
        if str(item or "").strip()
    ]
    return [
        action_title,
        f"RunRoot: {prepared_run_root}",
        f"ManifestPath: {payload.get('ManifestPath', '') or '(none)'}",
        f"StatePath: {payload.get('StatePath', '') or '(none)'}",
        f"StatusPath: {payload.get('StatusPath', '') or '(none)'}",
        f"ControlPath: {payload.get('ControlPath', '') or '(none)'}",
        f"TargetIds: {', '.join(target_ids_payload) if target_ids_payload else '(none)'}",
        f"TargetScope: {target_scope_text}",
        "ConfigAutoFix: " + format_config_auto_fix_label(prepare_config_backup_path),
        "Next: 독립셀 감지 시작/재시작 -> 초간단 시작문 복사/submit",
    ]


def format_prepare_manifest_summary_lines(
    runtime_snapshot: dict[str, object],
    *,
    start_allowed: bool,
    start_detail: str,
) -> list[str]:
    manifest_targets = runtime_snapshot.get("manifest_targets", [])
    if not isinstance(manifest_targets, list):
        manifest_targets = []
    included_target_ids = []
    publish_ready_count = 0
    work_repo_lines = []
    source_outbox_lines = []
    queue_root_lines = []
    for row in manifest_targets:
        if not isinstance(row, dict):
            continue
        target_id = str(row.get("TargetId", "") or "").strip()
        if not target_id:
            continue
        included_target_ids.append(target_id)
        trigger_values = row.get("TriggerKinds", []) or []
        if isinstance(trigger_values, str):
            trigger_values = [trigger_values]
        elif not isinstance(trigger_values, (list, tuple, set)):
            trigger_values = []
        trigger_kinds = {
            str(trigger_kind or "").strip().lower()
            for trigger_kind in trigger_values
        }
        if "publish-ready" in trigger_kinds:
            publish_ready_count += 1
        work_repo_root = str(row.get("WorkRepoRoot", "") or "").strip()
        source_outbox = str(row.get("SourceOutboxPath", "") or "").strip()
        queue_root = str(row.get("QueueRoot", "") or "").strip()
        if work_repo_root:
            work_repo_lines.append(f"  {target_id}: {work_repo_root}")
        if source_outbox:
            source_outbox_lines.append(f"  {target_id}: {source_outbox}")
        if queue_root:
            queue_root_lines.append(f"  {target_id}: {queue_root}")

    included_text = ",".join(included_target_ids) if included_target_ids else "(none)"
    start_possible_text = "yes" if start_allowed else "no"
    lines = [
        "",
        "[RunRoot manifest 요약]",
        f"이번 RunRoot 포함 target: {included_text}",
        f"publish-ready: {publish_ready_count}/{len(included_target_ids)}",
        f"감지 시작 가능: {start_possible_text}",
    ]
    if not start_allowed and start_detail:
        lines.append(f"감지 시작 차단 사유: {start_detail}")
    lines.append("WorkRepoRoot:")
    lines.extend(work_repo_lines or ["  (none)"])
    lines.append("SourceOutbox:")
    lines.extend(source_outbox_lines or ["  (none)"])
    lines.append("QueueRoot:")
    lines.extend(queue_root_lines or ["  (none)"])
    return lines


def format_start_watcher_success_lines(
    *,
    action_title: str,
    run_root: str,
    launch_payload: dict[str, object],
    ready_snapshot: dict[str, object],
) -> list[str]:
    lines = [
        action_title,
        f"RunRoot: {run_root}",
        f"Result: {launch_payload.get('Result', '') or '(none)'}",
        f"ReasonCodes: {_list_text(launch_payload.get('ReasonCodes', []))}",
        f"Idempotent: {bool(launch_payload.get('Idempotent', False))}",
        f"ActiveConfirmed: {bool(launch_payload.get('ActiveConfirmed', False))}",
        f"WatcherMutexHeld: {bool(launch_payload.get('WatcherMutexHeld', False))}",
        f"StatusPath: {launch_payload.get('StatusPath', '') or ready_snapshot.get('status_path', '')}",
        f"ControlPath: {launch_payload.get('ControlPath', '') or ready_snapshot.get('control_path', '')}",
        f"Message: {launch_payload.get('Message', '') or '(none)'}",
        f"PreparedNewRun: {bool(launch_payload.get('PreparedNewRun', False))}",
        f"ExpectedWatcherState: {launch_payload.get('ExpectedWatcherState', '') or '-'}",
        f"LaunchWatcherTargetScope: {launch_payload.get('WatcherTargetScope', '') or '-'}",
        f"LaunchWatcherTargetIds: {_list_text(launch_payload.get('WatcherTargetIds', []))}",
        f"WatcherProcessId: {launch_payload.get('WatcherProcessId', '(none)')}",
        f"WatcherStdoutLogPath: {launch_payload.get('WatcherStdoutLogPath', '(none)')}",
        f"WatcherStderrLogPath: {launch_payload.get('WatcherStderrLogPath', '(none)')}",
        "",
        f"{action_title} 확인",
        f"ControllerState: {ready_snapshot.get('controller_state', '') or '-'}",
        f"WatcherState: {ready_snapshot.get('watcher_state', '') or '-'}",
        f"WatcherTargetScope: {ready_snapshot.get('watcher_target_scope', '') or '-'}",
        f"WatcherTargetIds: {_list_text(ready_snapshot.get('watcher_target_ids', []))}",
        f"ProcessStartedAt: {ready_snapshot.get('process_started_at', '') or '(none)'}",
        f"HeartbeatAt: {ready_snapshot.get('heartbeat_at', '') or '(none)'}",
    ]
    restored_target_ids = launch_payload.get("RestoredTargetIds", [])
    if isinstance(restored_target_ids, list) and restored_target_ids:
        lines.append("RestoredTargetIds: " + ", ".join(str(item) for item in restored_target_ids))
    reconciled_control_action = str(launch_payload.get("ReconciledControlAction", "") or "").strip()
    if reconciled_control_action:
        lines.append("ReconciledControlAction: " + reconciled_control_action)
        lines.append("ReconciledControlState: " + str(launch_payload.get("ReconciledControlState", "") or "-"))
    prepared_target_ids = launch_payload.get("PreparedTargetIds", [])
    if isinstance(prepared_target_ids, list) and prepared_target_ids:
        lines.append("PreparedTargetIds: " + ", ".join(str(item) for item in prepared_target_ids))
    return lines


def format_start_watcher_ack_detail(ready_snapshot: dict[str, object]) -> str:
    return "ack: controller={0} / detector={1} / scope={2} / targets={3} / heartbeat={4}".format(
        str(ready_snapshot.get("controller_state", "") or "-"),
        str(ready_snapshot.get("watcher_state", "") or "-"),
        str(ready_snapshot.get("watcher_target_scope", "") or "-"),
        _list_text(ready_snapshot.get("watcher_target_ids", [])),
        str(ready_snapshot.get("heartbeat_at", "") or "(none)"),
    )


def format_start_watcher_recent_detail(ready_snapshot: dict[str, object]) -> str:
    return "controller={0} / detector={1} / scope={2} / targets={3} / heartbeat={4}".format(
        str(ready_snapshot.get("controller_state", "") or "-"),
        str(ready_snapshot.get("watcher_state", "") or "-"),
        str(ready_snapshot.get("watcher_target_scope", "") or "-"),
        _list_text(ready_snapshot.get("watcher_target_ids", [])),
        str(ready_snapshot.get("heartbeat_at", "") or "(none)"),
    )


def format_start_watcher_failure_summary(*, run_root: str, failure_snapshot: dict[str, object]) -> str:
    return (
        "start failed / runroot={run_root} / controller={controller} / detector={watcher} / heartbeat={heartbeat}"
    ).format(
        run_root=run_root,
        controller=str(failure_snapshot.get("controller_state", "") or "-"),
        watcher=str(failure_snapshot.get("watcher_state", "") or "-"),
        heartbeat=str(failure_snapshot.get("heartbeat_at", "") or "(none)"),
    )


@dataclass(frozen=True)
class ProcessOnceOutputSummary:
    lines: list[str]
    detail: str
    queued_targets: list[str]
    waiting_targets: list[str]
    failed_targets: list[str]
    duplicate_count: int
    duplicate_targets: list[str]
    duplicate_fingerprints: list[str]


def summarize_process_once_payload(
    *,
    action_title: str,
    run_root: str,
    payload: dict[str, object],
) -> ProcessOnceOutputSummary:
    watcher_result = payload.get("WatcherResult", {})
    if not isinstance(watcher_result, dict):
        watcher_result = {}
    target_rows = watcher_result.get("Targets", [])
    if not isinstance(target_rows, list):
        target_rows = []
    duplicate_count = _int_value(watcher_result.get("DuplicateCount", payload.get("DuplicateCount", 0)))
    duplicate_targets = _string_list(
        watcher_result.get("DuplicateTargetIds", payload.get("DuplicateTargetIds", []))
    )
    duplicate_fingerprints = _string_list(
        watcher_result.get("DuplicateFingerprints", payload.get("DuplicateFingerprints", []))
    )
    queued_targets = []
    waiting_targets = []
    failed_targets = []
    for row in target_rows:
        if not isinstance(row, dict):
            continue
        target_id = str(row.get("TargetId", "") or "").strip()
        phase = str(row.get("Phase", "") or "").strip()
        last_dispatch_state = str(row.get("LastDispatchState", "") or "").strip()
        if phase in {"queued", "dispatch-delay"} or last_dispatch_state in {"queued", "dispatch-delay-waiting"}:
            queued_targets.append(target_id or "-")
        elif phase in {"waiting-output", "idle"}:
            waiting_targets.append(target_id or "-")
        elif phase == "failed":
            failed_targets.append(target_id or "-")

    lines = [
        action_title,
        f"RunRoot: {payload.get('RunRoot', run_root)}",
        f"Result: {payload.get('Result', '') or '(none)'}",
        f"WatcherState: {payload.get('WatcherState', watcher_result.get('WatcherState', '(none)'))}",
        f"WatcherStopReason: {payload.get('WatcherStopReason', watcher_result.get('WatcherStopReason', '(none)'))}",
        f"QueuedOrDelayTargets: {_list_text(queued_targets)}",
        f"WaitingTargets: {_list_text(waiting_targets)}",
        f"FailedTargets: {_list_text(failed_targets)}",
        f"DuplicateTriggers: {duplicate_count}",
        f"StatusPath: {payload.get('StatusPath', '') or '(none)'}",
        f"ControlPath: {payload.get('ControlPath', '') or '(none)'}",
    ]
    if duplicate_targets:
        lines.append(f"DuplicateTargets: {_list_text(duplicate_targets)}")
    if duplicate_fingerprints:
        lines.append(f"DuplicateFingerprints: {_list_text(duplicate_fingerprints)}")
    if duplicate_count > 0:
        lines.append(
            "DuplicateMarkerGuidance: 같은 publish.ready marker fingerprint는 이미 처리되어 "
            "재검사만으로 새 command를 만들지 않습니다. summary/review.zip을 갱신하고 helper로 "
            "새 publish.ready.json(OutputFingerprint)을 생성하세요."
        )
    detail = "queued={0} / waiting={1} / failed={2}".format(
        len(queued_targets),
        len(waiting_targets),
        len(failed_targets),
    )
    if duplicate_count > 0:
        detail = f"{detail} / duplicate={duplicate_count}"
    return ProcessOnceOutputSummary(
        lines=lines,
        detail=detail,
        queued_targets=queued_targets,
        waiting_targets=waiting_targets,
        failed_targets=failed_targets,
        duplicate_count=duplicate_count,
        duplicate_targets=duplicate_targets,
        duplicate_fingerprints=duplicate_fingerprints,
    )


def format_control_action_success_lines(
    *,
    action_title: str,
    run_root: str,
    request_payload: dict[str, object],
    ack_snapshot: dict[str, object],
) -> list[str]:
    if not isinstance(request_payload, dict):
        request_payload = {}
    if not isinstance(ack_snapshot, dict):
        ack_snapshot = {}
    request_id = str(request_payload.get("RequestId", "") or "")
    request_result = str(request_payload.get("Result", "") or "").strip()
    request_recorded = bool(request_id) or request_result.startswith("already-")
    ack_request_id = str(ack_snapshot.get("last_handled_request_id", "") or "")
    ack_matched = str(bool(request_id and ack_request_id == request_id)) if request_id else "(no-request-id)"
    lines = [
        action_title,
        f"RunRoot: {run_root}",
        f"ControlPath: {request_payload.get('ControlPath', '') or ack_snapshot.get('control_path', '')}",
        f"Message: {request_payload.get('Message', '') or '(none)'}",
        f"RequestRecorded: {request_recorded}",
        f"AckMatched: {ack_matched}",
    ]
    if request_id:
        lines.append(f"RequestId: {request_id}")
    reason_codes = request_payload.get("ReasonCodes", [])
    if isinstance(reason_codes, list) and reason_codes:
        lines.append("Reasons: " + ", ".join(str(item) for item in reason_codes))
    lines.extend(
        [
            "",
            f"{action_title} 확인",
            f"ControllerState: {ack_snapshot.get('controller_state', '') or '-'}",
            f"State: {ack_snapshot.get('state', '') or '-'}",
            f"ControlPendingAction: {ack_snapshot.get('control_pending_action', '') or '(none)'}",
            f"LastHandledRequestId: {ack_snapshot.get('last_handled_request_id', '') or '(none)'}",
            f"LastHandledAction: {ack_snapshot.get('last_handled_action', '') or '(none)'}",
            f"LastHandledResult: {ack_snapshot.get('last_handled_result', '') or '(none)'}",
        ]
    )
    return lines


def format_control_action_pending_lines(
    *,
    action_title: str,
    action: str,
    run_root: str,
    expected_controller_state: str,
    control_path: object = "",
) -> list[str]:
    return [
        f"[{action_title}]",
        f"RunRoot: {run_root}",
        f"Action: {action}",
        f"ExpectedControllerState: {expected_controller_state}",
        f"ControlPath: {control_path or '(unknown until request file is read)'}",
        "요청 준비: control 파일 기록 후 controller ack를 기다립니다.",
        f"확인 기준: RequestId 생성 -> LastHandledAction={action} -> ControllerState={expected_controller_state}",
    ]


def format_control_action_failure_lines(
    *,
    action_title: str,
    action: str,
    run_root: str,
    formatted_error: str,
    failure_snapshot: dict[str, object] | None,
) -> list[str]:
    snapshot = failure_snapshot if isinstance(failure_snapshot, dict) else {}
    return [
        f"[{action_title}]",
        f"{action} 요청 실패",
        f"RunRoot: {run_root}",
        f"Error: {formatted_error}",
        f"ControllerState: {snapshot.get('controller_state', '') or '-'}",
        f"State: {snapshot.get('state', '') or '-'}",
        f"ControlPendingAction: {snapshot.get('control_pending_action', '') or '(none)'}",
        f"ControlPendingRequestId: {snapshot.get('control_pending_request_id', '') or '(none)'}",
        f"LastHandledRequestId: {snapshot.get('last_handled_request_id', '') or '(none)'}",
        f"LastHandledAction: {snapshot.get('last_handled_action', '') or '(none)'}",
        f"LastHandledResult: {snapshot.get('last_handled_result', '') or '(none)'}",
        f"StatusPath: {snapshot.get('status_path', '') or '(none)'}",
        f"ControlPath: {snapshot.get('control_path', '') or '(none)'}",
    ]


def format_control_action_ack_detail(ack_snapshot: dict[str, object]) -> str:
    return "ack: controller={0} / result={1} / lastHandled={2}:{3}".format(
        str(ack_snapshot.get("controller_state", "") or "-"),
        str(ack_snapshot.get("last_handled_result", "") or "(none)"),
        str(ack_snapshot.get("last_handled_action", "") or "(none)"),
        str(ack_snapshot.get("last_handled_request_id", "") or "(none)"),
    )
