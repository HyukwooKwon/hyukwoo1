from __future__ import annotations

import re
from pathlib import Path


def target_autoloop_compact_text(value: object, *, max_chars: int = 120) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    if len(text) > max_chars:
        return text[: max_chars - 3] + "..."
    return text


def target_autoloop_run_root_is_pair_scoped(run_root: str | Path) -> bool:
    run_root_text = str(run_root or "").strip()
    if not run_root_text:
        return False
    try:
        path = Path(run_root_text)
    except Exception:
        return False
    if not path.name.lower().startswith("run_"):
        return False
    parts = [str(part).lower() for part in path.parts]
    for index, part in enumerate(parts[:-1]):
        if part == "pairs" and index + 1 < len(parts) - 1:
            return parts[index + 1].startswith("pair")
    return False


def target_autoloop_run_root_is_canonical(run_root: str | Path) -> bool:
    run_root_text = str(run_root or "").strip()
    if not run_root_text:
        return False
    try:
        path = Path(run_root_text)
    except Exception:
        return False
    parts = [str(part).lower() for part in path.parts]
    return (
        path.name.lower().startswith("run_")
        and path.parent.name.lower() == "target-autoloop"
        and "bottest-live-visible" in parts
    )


def target_autoloop_pair_runroot_block_detail(run_root: str | Path) -> str:
    return (
        "현재 RunRoot가 Pair RunRoot입니다. "
        f"runRoot={str(run_root or '').strip() or '(none)'}. "
        "Pair RunRoot에서는 독립셀 감지를 시작하지 않습니다. "
        "상단 RunRoot Override를 비우고 8 Cell Autoloop 탭에서 새 RunRoot를 준비하세요. "
        "정상 독립셀 RunRoot는 ...\\bottest-live-visible\\target-autoloop\\run_... 형태입니다."
    )


def target_autoloop_noncanonical_runroot_block_detail(run_root: str | Path) -> str:
    return (
        "현재 RunRoot가 8 Cell Autoloop 전용 위치가 아닙니다. "
        f"runRoot={str(run_root or '').strip() or '(none)'}. "
        "독립셀 감지는 ...\\bottest-live-visible\\target-autoloop\\run_... 형태의 RunRoot에서만 시작합니다. "
        "상단 RunRoot Override를 비우고 8 Cell Autoloop 탭에서 새 RunRoot를 준비하세요."
    )


def target_autoloop_router_session_mismatch_message(snapshot: dict[str, object]) -> str:
    return (
        "router/runtime LauncherSessionId가 달라 autoloop ready 파일이 router에서 ignored 됩니다. "
        "공식 8창 재사용/attach 후 router를 현재 세션으로 다시 시작한 뒤 감지를 재시작하세요. "
        f"router={snapshot.get('router_launcher_session_id', '') or '-'} "
        f"runtime={snapshot.get('runtime_launcher_session_id', '') or '-'}"
    )


def target_autoloop_router_session_not_ready_message(snapshot: dict[str, object]) -> str:
    if not isinstance(snapshot, dict):
        snapshot = {}
    router_session = snapshot.get("router_session", {})
    if not isinstance(router_session, dict):
        router_session = snapshot
    if bool(snapshot.get("router_session_mismatch", False) or router_session.get("mismatch", False)):
        return target_autoloop_router_session_mismatch_message(router_session)
    state = str(snapshot.get("router_session_state", "") or router_session.get("state", "") or "").strip()
    return (
        "router/runtime 세션이 아직 감지 시작 조건을 만족하지 않습니다. "
        "8 Cell Autoloop 탭에서 [8창 재사용+router 동기화]를 실행한 뒤 감지를 시작하세요. "
        f"state={state or '-'} "
        f"router={router_session.get('router_launcher_session_id', '') or '-'} "
        f"runtime={router_session.get('runtime_launcher_session_id', '') or '-'} "
        f"routerPid={router_session.get('router_pid', '') or '-'} "
        f"pidLive={router_session.get('router_pid_exists', '-') if 'router_pid_exists' in router_session else '-'} "
        f"mutexHeld={router_session.get('router_mutex_held', '-') if 'router_mutex_held' in router_session else '-'}"
    )


def target_autoloop_router_session_ready(snapshot: dict[str, object]) -> bool:
    if not isinstance(snapshot, dict):
        return False
    if bool(snapshot.get("router_session_mismatch", False)):
        return False
    if str(snapshot.get("router_session_state", "") or "").strip() != "ok":
        return False
    router_session = snapshot.get("router_session", {})
    if not isinstance(router_session, dict):
        return False
    router_session_id = str(router_session.get("router_launcher_session_id", "") or "").strip()
    runtime_session_id = str(router_session.get("runtime_launcher_session_id", "") or "").strip()
    return bool(router_session_id and runtime_session_id and router_session_id == runtime_session_id)


def target_autoloop_retry_pending_detail(snapshot: dict[str, object] | None) -> str:
    retry_pending_summary = (snapshot or {}).get("retry_pending_summary", {})
    if not isinstance(retry_pending_summary, dict):
        retry_pending_summary = {}
    count = int(retry_pending_summary.get("count", 0) or 0)
    current_count = int(retry_pending_summary.get("current_count", count) or 0)
    stale_count = int(retry_pending_summary.get("stale_count", 0) or 0)
    target_ids = retry_pending_summary.get("target_ids", [])
    if not isinstance(target_ids, list):
        target_ids = []
    current_target_ids = retry_pending_summary.get("current_target_ids", [])
    if not isinstance(current_target_ids, list):
        current_target_ids = []
    display_target_ids = current_target_ids if current_count > 0 else target_ids
    target_text = target_autoloop_join_target_ids(
        [str(target_id or "").strip() for target_id in display_target_ids if str(target_id or "").strip()]
    )
    detail = (
        f"router retry-pending에 target-autoloop ready 파일 {count}개가 있습니다. "
        f"current={current_count}, stale={stale_count}. "
        "현재 전송과 연결된 current 항목만 재큐잉 대상입니다. "
        f"targets={target_text}"
    )
    if stale_count > 0:
        detail += " stale 항목은 이전 LastRouterReadyPath와 맞지 않아 자동 재큐잉 대상에서 제외해야 합니다."
    latest_failure = str(
        retry_pending_summary.get("latest_current_failure_category", "")
        or retry_pending_summary.get("latest_failure_category", "")
        or ""
    ).strip()
    latest_message = target_autoloop_compact_text(
        retry_pending_summary.get("latest_current_failure_message", "")
        or retry_pending_summary.get("latest_failure_message", ""),
        max_chars=120,
    )
    latest_debug_log = str(
        retry_pending_summary.get("latest_current_debug_log_path", "")
        or retry_pending_summary.get("latest_debug_log_path", "")
        or ""
    ).strip()
    latest_focus_policy = str(
        retry_pending_summary.get("latest_current_focus_lost_retry_policy", "")
        or retry_pending_summary.get("latest_stale_focus_lost_retry_policy", "")
        or ""
    ).strip()
    latest_send_policy = str(
        retry_pending_summary.get("latest_current_send_retry_policy", "")
        or retry_pending_summary.get("latest_stale_send_retry_policy", "")
        or ""
    ).strip()
    latest_send_stage = str(
        retry_pending_summary.get("latest_current_send_stage", "")
        or retry_pending_summary.get("latest_stale_send_stage", "")
        or ""
    ).strip()
    latest_focus_hint = target_autoloop_compact_text(
        retry_pending_summary.get("latest_current_operator_retry_hint", "")
        or retry_pending_summary.get("latest_stale_operator_retry_hint", ""),
        max_chars=140,
    )
    if latest_failure:
        detail += f" latestFailure={latest_failure}"
    if latest_message:
        detail += f" latestMessage={latest_message}"
    if latest_debug_log:
        detail += f" debugLog={latest_debug_log}"
    if latest_send_policy and latest_send_policy != "not-send-failure":
        detail += f" retryPolicy={latest_send_policy}"
    if latest_send_stage and latest_send_stage != "not-send-failure":
        detail += f" retryStage={latest_send_stage}"
    if latest_focus_policy and latest_focus_policy != "not-focus-lost":
        detail += f" focusPolicy={latest_focus_policy}"
    if latest_focus_hint:
        detail += f" hint={latest_focus_hint}"
    return detail


def target_autoloop_router_inbox_ready_detail(snapshot: dict[str, object] | None) -> str:
    router_inbox_summary = (snapshot or {}).get("router_inbox_ready_summary", {})
    if not isinstance(router_inbox_summary, dict):
        router_inbox_summary = {}
    count = int(router_inbox_summary.get("count", 0) or 0)
    target_ids = router_inbox_summary.get("target_ids", [])
    if not isinstance(target_ids, list):
        target_ids = []
    target_text = target_autoloop_join_target_ids(
        [str(target_id or "").strip() for target_id in target_ids if str(target_id or "").strip()]
    )
    latest_target = str(router_inbox_summary.get("latest_target_id", "") or "").strip()
    latest_session = str(router_inbox_summary.get("latest_launcher_session_id", "") or "").strip()
    latest_created_at = str(router_inbox_summary.get("latest_created_at", "") or "").strip()
    latest_path = str(router_inbox_summary.get("latest_path", "") or "").strip()
    detail = (
        f"router inbox에 아직 처리되지 않은 ready 파일 {count}개가 남아 있습니다. "
        "router가 실행 중이면 곧 processed로 이동해야 하고, router 재시작 전부터 있던 파일이면 preexisting ready로 ignored 될 수 있습니다. "
        "같은 산출물 재검사만 반복하지 말고 router 상태와 새 output/새 ready 생성 필요 여부를 확인하세요. "
        f"targets={target_text}"
    )
    if latest_target:
        detail += f" latestTarget={latest_target}"
    if latest_session:
        detail += f" latestSession={latest_session}"
    if latest_created_at:
        detail += f" latestCreatedAt={latest_created_at}"
    if latest_path:
        detail += f" latestPath={latest_path}"
    return detail


def target_autoloop_manifest_enabled_count(runtime_snapshot: dict[str, object] | None) -> int:
    if not isinstance(runtime_snapshot, dict):
        return 0
    return int(runtime_snapshot.get("manifest_enabled_count", 0) or 0)


def target_autoloop_manifest_target_ids(runtime_snapshot: dict[str, object] | None) -> list[str]:
    if not isinstance(runtime_snapshot, dict):
        return []
    manifest_targets = runtime_snapshot.get("manifest_targets", [])
    if not isinstance(manifest_targets, list):
        return []
    target_ids: list[str] = []
    for row in manifest_targets:
        if not isinstance(row, dict):
            continue
        target_id = str(row.get("TargetId", "") or "").strip()
        if target_id and target_id not in target_ids:
            target_ids.append(target_id)
    return target_ids


def _target_autoloop_int_value(value: object) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def target_autoloop_limit_reached_summary(runtime_snapshot: dict[str, object] | None) -> dict[str, object]:
    snapshot = runtime_snapshot or {}
    rows = snapshot.get("targets", [])
    if not isinstance(rows, list):
        rows = []
    enabled_rows: list[dict[str, object]] = []
    reached_rows: list[dict[str, object]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        if not bool(row.get("Enabled", False)):
            continue
        enabled_rows.append(row)
        phase = str(row.get("Phase", "") or "").strip()
        next_action = str(row.get("NextAction", "") or "").strip()
        cycle_count = _target_autoloop_int_value(row.get("CycleCount", 0))
        max_cycle_count = _target_autoloop_int_value(row.get("MaxCycleCount", 0))
        if phase == "limit-reached" or next_action == "limit-reached" or (
            max_cycle_count > 0 and cycle_count >= max_cycle_count
        ):
            reached_rows.append(row)

    enabled_count = len(enabled_rows)
    reached_count = len(reached_rows)
    reached_target_ids = [
        str(row.get("TargetId", "") or "").strip()
        for row in reached_rows
        if str(row.get("TargetId", "") or "").strip()
    ]
    max_cycle_values = [
        _target_autoloop_int_value(row.get("MaxCycleCount", 0))
        for row in reached_rows
        if _target_autoloop_int_value(row.get("MaxCycleCount", 0)) > 0
    ]
    cycle_values = [_target_autoloop_int_value(row.get("CycleCount", 0)) for row in reached_rows]
    return {
        "enabled_count": enabled_count,
        "reached_count": reached_count,
        "all_reached": enabled_count > 0 and reached_count >= enabled_count,
        "target_ids": reached_target_ids,
        "target_text": target_autoloop_join_target_ids(reached_target_ids),
        "max_cycle_count": max(max_cycle_values, default=0),
        "cycle_count": max(cycle_values, default=0),
    }


def target_autoloop_limit_reached_detail(runtime_snapshot: dict[str, object] | None) -> str:
    summary = target_autoloop_limit_reached_summary(runtime_snapshot)
    target_text = str(summary.get("target_text", "") or "(none)")
    cycle_count = int(summary.get("cycle_count", 0) or 0)
    max_cycle_count = int(summary.get("max_cycle_count", 0) or 0)
    cycle_text = f" cycle={cycle_count}/{max_cycle_count}" if max_cycle_count > 0 else ""
    return (
        "현재 RunRoot의 enabled target이 모두 MaxCycleCount에 도달해 다음 action이 생성되지 않습니다 "
        f"(targets={target_text}{cycle_text}). "
        "같은 RunRoot에서 publish.ready.json만 다시 만들면 watcher가 새 작업을 이어가지 않으므로, "
        "현재 RunRoot를 이어가려면 MaxCycleCount를 추가로 늘리고 감지를 다시 시작하세요. "
        "처음부터 다시 돌릴 때만 새 RunRoot를 준비한 뒤 해당 target의 시작문을 다시 submit하세요."
    )


def target_autoloop_output_block_summary(runtime_snapshot: dict[str, object] | None) -> dict[str, object]:
    snapshot = runtime_snapshot or {}
    summary = snapshot.get("output_block_summary", {})
    return summary if isinstance(summary, dict) else {}


def target_autoloop_limit_ready_output_block_detail(runtime_snapshot: dict[str, object] | None) -> str:
    summary = target_autoloop_output_block_summary(runtime_snapshot)
    target_ids = summary.get("limit_reached_ready_unaccepted_target_ids", [])
    if not isinstance(target_ids, list):
        target_ids = []
    target_text = target_autoloop_join_target_ids(
        [str(target_id or "").strip() for target_id in target_ids if str(target_id or "").strip()]
    )
    cycle_count = _target_autoloop_int_value(summary.get("latest_cycle_count", 0))
    max_cycle_count = _target_autoloop_int_value(summary.get("latest_max_cycle_count", 0))
    dispatch_state = str(summary.get("latest_last_dispatch_state", "") or "").strip()
    publish_ready_path = str(summary.get("latest_publish_ready_path", "") or "").strip()
    cycle_text = f" cycle={cycle_count}/{max_cycle_count}" if max_cycle_count > 0 else ""
    detail = (
        "현재 RunRoot에서 일부 target이 MaxCycleCount에 도달한 뒤 새 publish.ready marker가 생겼지만 watcher accepted로 이어지지 않았습니다 "
        f"(targets={target_text}{cycle_text}). "
        "같은 RunRoot에 summary.txt/review.zip/publish.ready.json만 다시 만들면 다음 action이 생성되지 않습니다. "
        "새 RunRoot를 준비한 뒤 해당 target 시작문을 다시 submit하세요."
    )
    if dispatch_state:
        detail += f" lastDispatch={dispatch_state}"
    if publish_ready_path:
        detail += f" publishReady={publish_ready_path}"
    return detail


def target_autoloop_join_target_ids(target_ids: list[str]) -> str:
    return ",".join(target_ids) if target_ids else "(none)"


def target_autoloop_no_enabled_manifest_detail(
    runtime_snapshot: dict[str, object] | None,
    *,
    card_enabled_count: int,
    card_publish_ready_count: int,
) -> str:
    snapshot = runtime_snapshot or {}
    manifest_target_ids = target_autoloop_manifest_target_ids(snapshot)
    included_text = ",".join(manifest_target_ids) if manifest_target_ids else "(none)"
    card_state = (
        f"현재 카드 설정 enabled={card_enabled_count}, publish-ready={card_publish_ready_count}/{card_enabled_count}"
        if card_enabled_count > 0
        else "현재 카드 설정에도 enabled target이 없습니다"
    )
    return (
        "현재 RunRoot manifest에 enabled target이 없어 독립셀 감지 시작을 막았습니다 "
        f"(포함 target={included_text}, enabled=0). "
        "이 RunRoot는 이전 선택/disabled target 기준으로 준비된 stale run일 가능성이 큽니다. "
        f"{card_state}. 8 Cell Autoloop 탭에서 실행할 target을 enable하고 publish-ready를 켠 뒤 "
        "선택 target만 새 RunRoot 또는 전체 enabled target 새 RunRoot를 다시 준비하세요."
    )


def target_autoloop_start_eligibility(
    runtime_snapshot: dict[str, object] | None,
    *,
    card_enabled_count: int,
    card_publish_ready_count: int,
    watcher_fresh: bool,
) -> tuple[bool, str]:
    snapshot = runtime_snapshot or {}
    run_root_error = str(snapshot.get("run_root_error", "") or "")
    if run_root_error:
        return False, "RunRoot 문맥을 아직 읽지 못했습니다."
    run_root = str(snapshot.get("run_root", "") or "")
    if not run_root:
        return False, "현재 RunRoot가 없어 독립셀 감지 시작을 막았습니다."
    if target_autoloop_run_root_is_pair_scoped(run_root):
        return False, target_autoloop_pair_runroot_block_detail(run_root)
    if not target_autoloop_run_root_is_canonical(run_root):
        return False, target_autoloop_noncanonical_runroot_block_detail(run_root)
    status_error = str(snapshot.get("status_error", "") or "")
    if status_error and status_error != "missing":
        return False, f"target-autoloop 상태 파일을 읽지 못해 독립셀 감지 시작을 막았습니다: {status_error}"
    control_error = str(snapshot.get("control_error", "") or "")
    if control_error:
        return False, f"target-autoloop control 파일을 읽지 못해 독립셀 감지 시작을 막았습니다: {control_error}"
    manifest_error = str(snapshot.get("manifest_error", "") or "")
    if manifest_error and manifest_error != "missing":
        return False, f"target-autoloop manifest를 읽지 못해 독립셀 감지 시작을 막았습니다: {manifest_error}"
    manifest_run_mode = str(snapshot.get("manifest_run_mode", "") or "").strip()
    if bool(snapshot.get("manifest_exists", False)) and manifest_run_mode and manifest_run_mode != "target-autoloop":
        return (
            False,
            (
                "현재 RunRoot는 target-autoloop용 run이 아닙니다 "
                f"(manifest RunMode={manifest_run_mode}). 새 RunRoot를 준비하거나 8 Cell Autoloop run을 다시 준비하세요."
            ),
        )
    manifest_enabled_count = int(snapshot.get("manifest_enabled_count", 0) or 0)
    manifest_publish_ready_count = int(snapshot.get("manifest_publish_ready_count", 0) or 0)
    if bool(snapshot.get("manifest_exists", False)) and manifest_enabled_count <= 0:
        return False, target_autoloop_no_enabled_manifest_detail(
            snapshot,
            card_enabled_count=card_enabled_count,
            card_publish_ready_count=card_publish_ready_count,
        )
    if (
        bool(snapshot.get("manifest_exists", False))
        and manifest_enabled_count > 0
        and manifest_publish_ready_count < manifest_enabled_count
    ):
        return (
            False,
            (
                "현재 RunRoot manifest에 publish-ready 트리거가 꺼진 enabled target이 있습니다 "
                f"(publish-ready={manifest_publish_ready_count}/{manifest_enabled_count}). "
                "산출물(summary.txt/review.zip/publish.ready.json) 생성 후 다음 동작으로 이어지려면 "
                "8 Cell Autoloop 탭에서 publish-ready를 켜고 저장한 뒤 새 RunRoot를 준비하세요."
            ),
        )
    limit_summary = target_autoloop_limit_reached_summary(snapshot)
    if bool(limit_summary.get("all_reached", False)):
        return False, target_autoloop_limit_reached_detail(snapshot)
    router_session = snapshot.get("router_session", {})
    if not isinstance(router_session, dict):
        router_session = {}
    if bool(snapshot.get("router_session_mismatch", False)):
        return False, target_autoloop_router_session_mismatch_message(router_session)
    if not target_autoloop_router_session_ready(snapshot):
        return False, target_autoloop_router_session_not_ready_message(snapshot)
    pending_action = str(snapshot.get("control_pending_action", "") or "").strip()
    if pending_action:
        return False, f"target-autoloop 제어 요청({pending_action})이 처리 중이라 독립셀 감지 시작을 막았습니다."
    watcher_state = str(snapshot.get("watcher_state", "") or "").strip()
    if watcher_fresh:
        watcher_target_ids = snapshot.get("watcher_target_ids", [])
        if isinstance(watcher_target_ids, list):
            watcher_target_text = target_autoloop_join_target_ids(
                [str(target_id or "").strip() for target_id in watcher_target_ids if str(target_id or "").strip()]
            )
        else:
            watcher_target_text = "(unknown)"
        watcher_scope = str(snapshot.get("watcher_target_scope", "") or "").strip() or "unknown"
        return (
            False,
            f"현재 독립셀 감지기가 이미 active 상태입니다: {watcher_state or 'running'} "
            f"/ scope={watcher_scope} / 감지 target={watcher_target_text}",
        )
    return True, ""


def target_autoloop_control_eligibility(
    action: str,
    runtime_snapshot: dict[str, object] | None,
) -> tuple[bool, str]:
    snapshot = runtime_snapshot or {}
    run_root_error = str(snapshot.get("run_root_error", "") or "")
    if run_root_error:
        return False, "RunRoot 문맥을 아직 읽지 못했습니다."
    run_root = str(snapshot.get("run_root", "") or "")
    if not run_root:
        return False, "현재 RunRoot가 없어 target-autoloop 제어를 막았습니다."
    status_error = str(snapshot.get("status_error", "") or "")
    if status_error:
        if status_error == "missing":
            return False, "target-autoloop 상태 파일이 없어 제어를 막았습니다."
        return False, f"target-autoloop 상태 파일을 읽지 못해 제어를 막았습니다: {status_error}"
    control_error = str(snapshot.get("control_error", "") or "")
    if control_error:
        return False, f"target-autoloop control 파일을 읽지 못해 제어를 막았습니다: {control_error}"

    controller_state = str(snapshot.get("controller_state", "") or "")
    pending_action = str(snapshot.get("control_pending_action", "") or "")
    if pending_action:
        if pending_action == action:
            return False, f"이미 target-autoloop {action} 요청이 진행 중입니다."
        return False, f"다른 target-autoloop 제어 요청({pending_action})이 이미 진행 중입니다."
    if action == "pause":
        if controller_state == "paused":
            return False, "현재 target-autoloop이 이미 paused 상태입니다."
        if controller_state == "stopped":
            return False, "stopped 상태에서는 pause가 아니라 restart가 필요합니다."
        if controller_state != "running":
            return False, f"현재 target-autoloop controller 상태가 running이 아닙니다: {controller_state or '-'}"
    elif action == "resume":
        if controller_state == "running":
            return False, "현재 target-autoloop이 이미 running 상태입니다."
        if controller_state == "stopped":
            return False, "stopped 상태에서는 resume이 아니라 restart가 필요합니다."
        if controller_state != "paused":
            return False, f"현재 target-autoloop controller 상태가 paused가 아닙니다: {controller_state or '-'}"
    elif action == "stop":
        if controller_state == "stopped":
            return False, "현재 target-autoloop이 이미 stopped 상태입니다."
    return True, ""


def target_autoloop_watcher_recommendation(
    runtime_snapshot: dict[str, object] | None,
    *,
    watcher_health: str,
) -> str:
    snapshot = runtime_snapshot or {}
    run_root = str(snapshot.get("run_root", "") or "").strip()
    if run_root:
        if target_autoloop_run_root_is_pair_scoped(run_root):
            return target_autoloop_pair_runroot_block_detail(run_root)
        if not target_autoloop_run_root_is_canonical(run_root):
            return target_autoloop_noncanonical_runroot_block_detail(run_root)
    router_session = snapshot.get("router_session", {})
    if not isinstance(router_session, dict):
        router_session = {}
    if bool(snapshot.get("router_session_mismatch", False)):
        return target_autoloop_router_session_mismatch_message(router_session)
    output_block_summary = target_autoloop_output_block_summary(snapshot)
    if int(output_block_summary.get("limit_reached_ready_unaccepted_count", 0) or 0) > 0:
        return target_autoloop_limit_ready_output_block_detail(snapshot)
    if bool(target_autoloop_limit_reached_summary(snapshot).get("all_reached", False)):
        return target_autoloop_limit_reached_detail(snapshot)
    controller_state = str(snapshot.get("controller_state", "") or "").strip()
    watcher_state = str(snapshot.get("watcher_state", "") or "").strip()
    if watcher_health == "active":
        if watcher_state == "paused":
            return "paused 상태입니다. resume 또는 stop을 선택하세요."
        return "독립셀 감지기가 정상 heartbeat를 보내고 있습니다."
    if watcher_health == "stale":
        return "heartbeat가 stale입니다. 독립셀 감지 재시작 후 stderr 로그를 먼저 확인하세요."
    if watcher_health == "stopped":
        if controller_state == "stopped":
            return "controller와 독립셀 감지기가 모두 stopped입니다. 독립셀 감지 재시작이 필요합니다."
        return "독립셀 감지기가 stopped입니다. 독립셀 감지 시작으로 다시 올리세요."
    return "status가 없거나 독립셀 감지기 메타데이터가 비어 있습니다. 독립셀 감지 시작으로 초기화하세요."


def target_autoloop_retry_recommendation_label(label: str, action_key: str) -> str:
    normalized_label = str(label or "").strip()
    normalized_action_key = str(action_key or "").strip()
    if not normalized_label:
        return normalized_label
    if normalized_action_key == "open_stderr_log":
        return "stderr 다시 열기"
    if normalized_label.endswith("요청"):
        return normalized_label[:-2] + "재요청"
    if normalized_label.endswith("재시도") or normalized_label.endswith("재요청"):
        return normalized_label
    return normalized_label + " 재시도"


def target_autoloop_recommendation_detail_sections(
    *,
    base_detail: str,
    latest_outcome: str = "",
    latest_detail: str = "",
) -> list[str]:
    normalized_base_detail = str(base_detail or "").strip()
    normalized_latest_outcome = str(latest_outcome or "").strip().lower()
    normalized_latest_detail = str(latest_detail or "").strip()
    if normalized_latest_outcome not in {"failed", "blocked"}:
        return [normalized_base_detail] if normalized_base_detail else []

    outcome_label = "실패" if normalized_latest_outcome == "failed" else "차단"
    sections = []
    if normalized_latest_detail:
        sections.append(f"이전 {outcome_label}: {normalized_latest_detail}")
    else:
        sections.append(f"이전 {outcome_label}")
    if normalized_base_detail:
        sections.append(f"이번 조치: {normalized_base_detail}")
    return sections


def target_autoloop_retry_reason_badge_spec(recommendation_spec: dict[str, object] | None) -> dict[str, str]:
    if not isinstance(recommendation_spec, dict):
        return {
            "text": "재시도 사유: (없음)",
            "background": "#6B7280",
            "foreground": "#FFFFFF",
        }
    retry_outcome = str(recommendation_spec.get("retry_outcome", "") or "").strip().lower()
    retry_detail = target_autoloop_compact_text(
        recommendation_spec.get("retry_detail", ""),
        max_chars=88,
    )
    if retry_outcome == "failed":
        text = "재시도 사유: 이전 실패"
        if retry_detail:
            text += f" / {retry_detail}"
        return {
            "text": text,
            "background": "#991B1B",
            "foreground": "#FFFFFF",
        }
    if retry_outcome == "blocked":
        text = "재시도 사유: 이전 차단"
        if retry_detail:
            text += f" / {retry_detail}"
        return {
            "text": text,
            "background": "#B45309",
            "foreground": "#FFFFFF",
        }
    return {
        "text": "재시도 사유: (없음)",
        "background": "#6B7280",
        "foreground": "#FFFFFF",
    }


def target_autoloop_recommendation_mode(recommendation_spec: dict[str, object] | None) -> str:
    if not isinstance(recommendation_spec, dict):
        return "none"
    action_key = str(recommendation_spec.get("action_key", "") or "").strip()
    if not action_key:
        return "none"
    return "read-only" if bool(recommendation_spec.get("read_only", False)) else "mutating"


def target_autoloop_recommendation_level(recommendation_spec: dict[str, object] | None) -> str:
    if not isinstance(recommendation_spec, dict):
        return "none"
    action_key = str(recommendation_spec.get("action_key", "") or "").strip()
    if not action_key:
        return "none"
    if bool(recommendation_spec.get("read_only", False)):
        return "safe"
    if action_key in {"stop", "force_restart", "force_stop"}:
        return "danger"
    if action_key in {
        "resume",
        "start_watch",
        "enable_publish_ready",
        "extend_cycle_limit_then_start_watch",
        "fix_publish_ready_prepare_autoloop_runroot",
        "prepare_autoloop_runroot",
        "restart_router_for_autoloop",
        "requeue_retry_pending",
    }:
        return "normal"
    return "normal"


def target_autoloop_prepare_recommendation_from_start_detail(
    start_detail: str,
    *,
    card_enabled_count: int,
    card_publish_ready_count: int,
) -> dict[str, str] | None:
    detail = str(start_detail or "")
    if "MaxCycleCount" in detail or "limit-reached" in detail or "cycle limit" in detail:
        return {
            "label": "새 RunRoot 준비",
            "action_key": "prepare_autoloop_runroot",
            "detail": (
                detail
                + " / 현재 RunRoot를 이어가려면 선택 target에서 추가 진행 횟수를 늘리고, "
                "처음부터 다시 시작하려면 새 RunRoot를 준비하세요."
            ),
        }
    if "Pair RunRoot" in detail or "target-autoloop용 run이 아닙니다" in detail:
        return {
            "label": "새 RunRoot 준비",
            "action_key": "prepare_autoloop_runroot",
            "detail": detail + " / 현재 RunRoot는 Pair run일 수 있으므로 독립셀 전용 RunRoot를 새로 준비해야 합니다.",
        }
    if "enabled target이 없어" in detail:
        if card_enabled_count > 0 and card_publish_ready_count >= card_enabled_count:
            return {
                "label": "새 RunRoot 준비",
                "action_key": "prepare_autoloop_runroot",
                "detail": detail + " / 현재 카드 설정은 실행 가능하므로 새 RunRoot 준비가 필요합니다.",
            }
        return {
            "label": "target enable 후 새 RunRoot 준비",
            "action_key": "",
            "detail": detail,
        }
    if "publish-ready" in detail:
        if card_enabled_count > 0 and card_publish_ready_count >= card_enabled_count:
            return {
                "label": "새 RunRoot 준비",
                "action_key": "prepare_autoloop_runroot",
                "detail": detail + " / 현재 카드 설정은 publish-ready가 켜져 있으므로 새 RunRoot 준비가 필요합니다.",
            }
        return {
            "label": "publish-ready 켜고 새 RunRoot 준비",
            "action_key": "fix_publish_ready_prepare_autoloop_runroot",
            "detail": detail + " / 누르면 enabled target의 publish-ready를 켜고 저장한 뒤 새 RunRoot를 준비합니다.",
        }
    return None


def target_autoloop_recommendation_spec(
    runtime_snapshot: dict[str, object] | None,
    *,
    watcher_health: str,
    watcher_health_detail: str,
    start_allowed: bool,
    start_detail: str,
    resume_allowed: bool,
    card_enabled_count: int,
    card_publish_ready_count: int,
    latest_history: dict[str, object] | None = None,
) -> dict[str, object]:
    snapshot = runtime_snapshot or {}
    watcher_state = str(snapshot.get("watcher_state", "") or "").strip()
    controller_state = str(snapshot.get("controller_state", "") or "").strip()
    stderr_exists = bool(snapshot.get("watcher_stderr_log_exists", False))
    stderr_path = str(snapshot.get("watcher_stderr_log_path", "") or "").strip()

    label = "권장 조치 없음"
    action_key = ""
    detail = target_autoloop_watcher_recommendation(snapshot, watcher_health=watcher_health)
    read_only = False

    prepare_spec = target_autoloop_prepare_recommendation_from_start_detail(
        start_detail,
        card_enabled_count=card_enabled_count,
        card_publish_ready_count=card_publish_ready_count,
    )
    output_block_summary = target_autoloop_output_block_summary(snapshot)
    if prepare_spec is not None:
        label = prepare_spec["label"]
        action_key = prepare_spec["action_key"]
        detail = prepare_spec["detail"]
    elif int(output_block_summary.get("limit_reached_ready_unaccepted_count", 0) or 0) > 0:
        label = "새 RunRoot 준비"
        action_key = "prepare_autoloop_runroot"
        detail = target_autoloop_limit_ready_output_block_detail(snapshot)
    elif bool(snapshot.get("router_config_drift", False)) or bool(
        (snapshot.get("router_session", {}) if isinstance(snapshot.get("router_session", {}), dict) else {}).get("router_config_drift", False)
    ):
        router_session = snapshot.get("router_session", {}) if isinstance(snapshot.get("router_session", {}), dict) else {}
        reasons = router_session.get("router_config_drift_reasons", snapshot.get("router_config_drift_reasons", []))
        if not isinstance(reasons, list):
            reasons = []
        configured_idle_wait = int(router_session.get("configured_user_idle_wait_timeout_ms", 0) or 0)
        router_idle_wait = router_session.get("router_user_idle_wait_timeout_ms", None)
        label = "router 설정 재시작"
        action_key = "restart_router_for_autoloop"
        detail = (
            "현재 router가 config의 전송 안정화 설정과 다르게 실행 중입니다. "
            "router 재시작 후 현재 전송보류 재시도를 진행하세요. "
            f"reasons={','.join(str(reason) for reason in reasons) or '(none)'} "
            f"configuredIdleWait={configured_idle_wait}ms "
            f"routerIdleWait={router_idle_wait if router_idle_wait is not None else '(missing)'}ms"
        )
    elif int(
        (snapshot.get("retry_pending_summary", {}) if isinstance(snapshot.get("retry_pending_summary", {}), dict) else {}).get("count", 0)
        or 0
    ) > 0:
        retry_pending_summary = snapshot.get("retry_pending_summary", {}) if isinstance(snapshot.get("retry_pending_summary", {}), dict) else {}
        current_count = int(retry_pending_summary.get("current_count", retry_pending_summary.get("count", 0)) or 0)
        label = "현재 전송보류 재시도" if current_count > 0 else "stale retry-pending 확인"
        action_key = "requeue_retry_pending" if current_count > 0 else ""
        read_only = current_count <= 0
        detail = target_autoloop_retry_pending_detail(snapshot)
    elif watcher_health == "stale":
        if stderr_exists and stderr_path:
            label = "stderr 우선 열기"
            action_key = "open_stderr_log"
            read_only = True
            detail = (
                f"독립셀 감지기 stale ({watcher_health_detail or 'unknown'}) 상태입니다. "
                "stderr 로그를 먼저 열어 원인을 확인한 뒤 독립셀 감지 재시작을 진행하세요."
            )
        elif start_allowed:
            label = "독립셀 감지 재시작"
            action_key = "start_watch"
            detail = (
                f"독립셀 감지기 stale ({watcher_health_detail or 'unknown'}) 상태입니다. "
                "로그가 없으므로 감지 재시작으로 heartbeat를 다시 세우는 편이 안전합니다."
            )
    elif watcher_health == "stopped":
        if controller_state == "paused" and resume_allowed:
            label = "resume 요청"
            action_key = "resume"
            detail = "controller는 paused이고 watcher는 stopped입니다. resume으로 pause 중 쌓인 target별 queue를 순차 처리하세요."
        elif start_allowed:
            label = "독립셀 감지 재시작" if controller_state == "stopped" else "독립셀 감지 시작"
            action_key = "start_watch"
            detail = (
                "독립셀 감지기가 stopped 상태입니다. "
                + ("controller도 stopped라 감지 재시작이 필요합니다." if controller_state == "stopped" else "독립셀 감지 시작으로 다시 올리세요.")
            )
    elif start_allowed:
        label = "독립셀 감지 시작"
        action_key = "start_watch"
        detail = "RunRoot 준비가 끝났고 독립셀 감지기를 시작할 수 있습니다."
    elif watcher_state == "paused" and resume_allowed:
        label = "resume 요청"
        action_key = "resume"
        detail = "독립셀 감지기가 paused 상태입니다. 감지는 유지되고 submit만 멈춘 상태이므로 resume 요청으로 쌓인 queue를 순차 처리하세요."
    if not action_key and bool(snapshot.get("router_session_mismatch", False)):
        label = "router만 세션 맞추기"
        action_key = "restart_router_for_autoloop"
        detail = target_autoloop_router_session_not_ready_message(snapshot)
    elif not action_key and not target_autoloop_router_session_ready(snapshot):
        label = "8창 재사용+router 동기화"
        action_key = "restart_router_for_autoloop"
        detail = target_autoloop_router_session_not_ready_message(snapshot)

    latest = latest_history or {}
    latest_outcome = str(latest.get("outcome", "") or "").strip().lower()
    latest_action_key = str(latest.get("action_key", "") or "").strip()
    latest_detail = target_autoloop_compact_text(latest.get("detail", ""), max_chars=120)
    detail_sections = [detail] if detail else []
    retry_outcome = ""
    retry_detail = ""
    if action_key and latest_action_key == action_key and latest_outcome in {"failed", "blocked"}:
        label = target_autoloop_retry_recommendation_label(label, action_key)
        detail_sections = target_autoloop_recommendation_detail_sections(
            base_detail=detail,
            latest_outcome=latest_outcome,
            latest_detail=latest_detail,
        )
        detail = " / ".join(section for section in detail_sections if section)
        retry_outcome = latest_outcome
        retry_detail = latest_detail

    return {
        "label": label,
        "action_key": action_key,
        "detail": detail,
        "detail_sections": detail_sections,
        "retry_outcome": retry_outcome,
        "retry_detail": retry_detail,
        "read_only": read_only,
        "watcher_health": watcher_health,
        "watcher_health_detail": watcher_health_detail,
    }


def target_autoloop_detector_included_target_ids(runtime_snapshot: dict[str, object] | None) -> list[str]:
    snapshot = runtime_snapshot or {}
    watcher_target_ids = snapshot.get("watcher_target_ids", [])
    if isinstance(watcher_target_ids, list) and str(snapshot.get("watcher_state", "") or "").strip() in {"running", "paused"}:
        normalized_watcher_target_ids = [
            str(target_id or "").strip()
            for target_id in watcher_target_ids
            if str(target_id or "").strip()
        ]
        if normalized_watcher_target_ids:
            return normalized_watcher_target_ids
    source_rows = snapshot.get("manifest_targets", []) or snapshot.get("targets", []) or []
    if not isinstance(source_rows, list):
        return []
    target_ids: list[str] = []
    for row in source_rows:
        if not isinstance(row, dict):
            continue
        target_id = str(row.get("TargetId", "") or "").strip()
        if target_id and target_id not in target_ids:
            target_ids.append(target_id)
    return target_ids


def target_autoloop_publish_ready_manifest_target_ids(runtime_snapshot: dict[str, object] | None) -> list[str]:
    snapshot = runtime_snapshot or {}
    rows = snapshot.get("manifest_targets", [])
    if not isinstance(rows, list):
        return []
    target_ids: list[str] = []
    for row in rows:
        if not isinstance(row, dict) or not bool(row.get("Enabled", False)):
            continue
        trigger_values = row.get("TriggerKinds", []) or []
        if isinstance(trigger_values, str):
            trigger_values = [trigger_values]
        if not isinstance(trigger_values, (list, tuple, set)):
            trigger_values = []
        trigger_kinds = {
            str(trigger_kind or "").strip().lower()
            for trigger_kind in trigger_values
            if str(trigger_kind or "").strip()
        }
        if "publish-ready" not in trigger_kinds:
            continue
        target_id = str(row.get("TargetId", "") or "").strip()
        if target_id and target_id not in target_ids:
            target_ids.append(target_id)
    return target_ids


def target_autoloop_watcher_missing_publish_ready_target_ids(runtime_snapshot: dict[str, object] | None) -> list[str]:
    snapshot = runtime_snapshot or {}
    watcher_state = str(snapshot.get("watcher_state", "") or "").strip().lower()
    if watcher_state not in {"running", "paused"}:
        return []
    expected_target_ids = target_autoloop_publish_ready_manifest_target_ids(snapshot)
    if not expected_target_ids:
        return []
    active_value = snapshot.get("watcher_target_ids", [])
    active_target_ids = [
        str(target_id or "").strip()
        for target_id in active_value
        if str(target_id or "").strip()
    ] if isinstance(active_value, list) else []
    active_set = set(active_target_ids)
    return [target_id for target_id in expected_target_ids if target_id not in active_set]


def target_autoloop_detector_state_label(
    runtime_snapshot: dict[str, object] | None,
    *,
    watcher_fresh: bool,
    start_allowed: bool,
    start_detail: str,
) -> str:
    snapshot = runtime_snapshot or {}
    if str(snapshot.get("run_root_error", "") or "").strip():
        return "차단"
    run_root = str(snapshot.get("run_root", "") or "").strip()
    if not run_root:
        return "대기"
    if target_autoloop_run_root_is_pair_scoped(run_root):
        return "차단"
    if not target_autoloop_run_root_is_canonical(run_root):
        return "차단"
    status_error = str(snapshot.get("status_error", "") or "").strip()
    control_error = str(snapshot.get("control_error", "") or "").strip()
    if status_error and status_error != "missing":
        return "차단"
    if control_error:
        return "차단"
    if bool(snapshot.get("router_session_mismatch", False)):
        return "차단"
    if not target_autoloop_router_session_ready(snapshot):
        return "차단"
    if int(target_autoloop_output_block_summary(snapshot).get("limit_reached_ready_unaccepted_count", 0) or 0) > 0:
        return "차단"
    if bool(target_autoloop_limit_reached_summary(snapshot).get("all_reached", False)):
        return "차단"
    watcher_state = str(snapshot.get("watcher_state", "") or "").strip()
    controller_state = str(snapshot.get("controller_state", "") or "").strip()
    if watcher_fresh:
        if watcher_state == "paused":
            return "일시정지"
        if watcher_state == "running":
            if target_autoloop_watcher_missing_publish_ready_target_ids(snapshot):
                return "부분감지"
            return "감지중"
    if (
        not start_allowed
        and "이미 active" not in start_detail
        and any(token in start_detail for token in ("publish-ready", "enabled target", "target-autoloop용", "router", "읽지 못", "처리 중"))
    ):
        return "차단"
    if watcher_state == "paused" or controller_state == "paused":
        return "일시정지"
    if watcher_state == "stopped" or controller_state == "stopped":
        return "정지"
    if status_error == "missing":
        return "대기"
    return "대기"


def target_autoloop_detector_badge_spec(
    runtime_snapshot: dict[str, object] | None,
    *,
    detector_state: str,
    sweep_label: str,
    target_ids: list[str],
) -> dict[str, str]:
    snapshot = runtime_snapshot or {}
    counts = snapshot.get("counts", {})
    if not isinstance(counts, dict):
        counts = {}
    target_text = ",".join(target_ids) if target_ids else "-"
    text = (
        "감지 상태: {state} | 마지막 sweep: {sweep} | 감지 target: {targets} | "
        "queue: {queued} / waiting-output: {waiting} / failed: {failed}"
    ).format(
        state=detector_state,
        sweep=sweep_label,
        targets=target_text,
        queued=int(counts.get("QueuedTargets", 0) or 0),
        waiting=int(counts.get("WaitingOutputTargets", 0) or 0),
        failed=int(counts.get("FailedTargets", 0) or 0),
    )
    missing_target_ids = target_autoloop_watcher_missing_publish_ready_target_ids(snapshot)
    if missing_target_ids:
        text += " | 누락 target: " + target_autoloop_join_target_ids(missing_target_ids)
    palette = {
        "감지중": "#15803D",
        "부분감지": "#B45309",
        "일시정지": "#B45309",
        "정지": "#6B7280",
        "준비필요": "#1D4ED8",
        "차단": "#B91C1C",
        "대기": "#6B7280",
    }
    return {
        "text": text,
        "background": palette.get(detector_state, "#6B7280"),
        "foreground": "#FFFFFF",
    }


def target_autoloop_runroot_attention_spec(
    runtime_snapshot: dict[str, object] | None,
    *,
    config_enabled_ids: list[str],
    config_publish_ready_ids: list[str],
    intended_target_ids: list[str],
    latest_valid_sibling_run_root: dict[str, object] | None,
    autoswitch_reject_hint: str,
    start_allowed: bool,
    start_detail: str,
    watcher_health: str,
    watcher_health_detail: str,
) -> dict[str, str]:
    snapshot = runtime_snapshot or {}
    run_root = str(snapshot.get("run_root", "") or "").strip()
    if str(snapshot.get("run_root_error", "") or "").strip() or not run_root:
        return {
            "text": "RunRoot 상태: RunRoot가 아직 없습니다. 8 Cell Autoloop target을 enable한 뒤 새 RunRoot를 준비하세요.",
            "background": "#6B7280",
            "foreground": "#FFFFFF",
        }
    if target_autoloop_run_root_is_pair_scoped(run_root):
        return {
            "text": (
                "현재 RunRoot 종류 불일치: Pair RunRoot가 선택되어 있습니다. "
                "Pair RunRoot에서는 독립셀 감지를 시작할 수 없습니다. "
                "상단 RunRoot Override를 비우고 8 Cell Autoloop 탭에서 새 RunRoot를 준비하세요. "
                f"runRoot={run_root}"
            ),
            "background": "#B91C1C",
            "foreground": "#FFFFFF",
        }
    if not target_autoloop_run_root_is_canonical(run_root):
        return {
            "text": (
                "현재 RunRoot 종류 불일치: 8 Cell Autoloop 전용 RunRoot가 아닙니다. "
                "독립셀 감지는 ...\\bottest-live-visible\\target-autoloop\\run_... 경로에서만 시작합니다. "
                "상단 RunRoot Override를 비우고 8 Cell Autoloop 탭에서 새 RunRoot를 준비하세요. "
                f"runRoot={run_root}"
            ),
            "background": "#B91C1C",
            "foreground": "#FFFFFF",
        }

    manifest_ids = target_autoloop_manifest_target_ids(snapshot)
    manifest_enabled_count = target_autoloop_manifest_enabled_count(snapshot)
    manifest_publish_ready_count = int(snapshot.get("manifest_publish_ready_count", 0) or 0)
    manifest_run_mode = str(snapshot.get("manifest_run_mode", "") or "").strip()
    if bool(snapshot.get("manifest_exists", False)) and manifest_run_mode and manifest_run_mode != "target-autoloop":
        return {
            "text": (
                "현재 RunRoot 종류 불일치: 이 RunRoot는 8 Cell Autoloop용이 아닙니다 "
                f"(manifest RunMode={manifest_run_mode}). "
                "Pair RunRoot에서는 독립셀 감지를 시작할 수 없습니다. "
                "[새 RunRoot 준비 후 감지 시작]으로 독립셀 전용 RunRoot를 먼저 만드세요."
            ),
            "background": "#B91C1C",
            "foreground": "#FFFFFF",
        }

    if bool(snapshot.get("manifest_exists", False)) and manifest_enabled_count <= 0:
        if config_enabled_ids:
            latest = latest_valid_sibling_run_root or {}
            latest_run_root = str(latest.get("run_root", "") or "").strip()
            if latest_run_root and latest_run_root != run_root:
                latest_targets = latest.get("target_ids", [])
                latest_targets_text = (
                    target_autoloop_join_target_ids([str(item) for item in latest_targets])
                    if isinstance(latest_targets, list)
                    else "(unknown)"
                )
                return {
                    "text": (
                        "현재 표시된 RunRoot는 stale입니다: 이 RunRoot manifest에는 enabled target이 없습니다 "
                        f"(manifest target={target_autoloop_join_target_ids(manifest_ids)}). "
                        "같은 target-autoloop 폴더에서 최신 유효 RunRoot를 찾았습니다 "
                        f"(enabled={int(latest.get('enabled_count', 0) or 0)}, "
                        f"publish-ready trigger={int(latest.get('publish_ready_count', 0) or 0)}/{int(latest.get('enabled_count', 0) or 0)}, "
                        f"target={latest_targets_text}, "
                        f"intended={target_autoloop_join_target_ids(intended_target_ids)}). "
                        "[감지 시작]을 누르면 최신 유효 RunRoot로 자동 전환한 뒤 감지를 시작합니다."
                    ),
                    "background": "#1D4ED8",
                    "foreground": "#FFFFFF",
                }
            publish_part = f"카드 publish-ready trigger={len(config_publish_ready_ids)}/{len(config_enabled_ids)}"
            return {
                "text": (
                    "현재 RunRoot 불일치: 이 RunRoot manifest에는 enabled target이 없습니다 "
                    f"(manifest target={target_autoloop_join_target_ids(manifest_ids)}). "
                    f"현재 카드 enabled={target_autoloop_join_target_ids(config_enabled_ids)} / {publish_part}. "
                    f"{autoswitch_reject_hint} "
                    "[새 RunRoot 준비 후 감지 시작]을 누르면 현재 카드 설정 기준으로 새 manifest를 만들고 감지를 시작합니다."
                ),
                "background": "#B91C1C",
                "foreground": "#FFFFFF",
            }
        return {
            "text": (
                "실행 target 없음: 현재 RunRoot manifest와 카드 설정 모두 enabled target이 없습니다. "
                "실행할 target 카드의 Enabled와 publish-ready trigger를 켠 뒤 새 RunRoot를 준비하세요."
            ),
            "background": "#B91C1C",
            "foreground": "#FFFFFF",
        }

    if (
        bool(snapshot.get("manifest_exists", False))
        and manifest_enabled_count > 0
        and manifest_publish_ready_count < manifest_enabled_count
    ):
        return {
            "text": (
                "publish-ready trigger 미완료: 현재 RunRoot manifest의 enabled target 중 일부는 publish-ready trigger가 꺼져 있습니다 "
                f"({manifest_publish_ready_count}/{manifest_enabled_count}). "
                "[publish-ready 켜고 새 RunRoot 준비]를 먼저 실행하세요."
            ),
            "background": "#B45309",
            "foreground": "#FFFFFF",
        }

    limit_summary = target_autoloop_limit_reached_summary(snapshot)
    if bool(limit_summary.get("all_reached", False)):
        return {
            "text": target_autoloop_limit_reached_detail(snapshot),
            "background": "#B45309",
            "foreground": "#FFFFFF",
        }

    output_block_summary = target_autoloop_output_block_summary(snapshot)
    if int(output_block_summary.get("limit_reached_ready_unaccepted_count", 0) or 0) > 0:
        return {
            "text": target_autoloop_limit_ready_output_block_detail(snapshot),
            "background": "#B45309",
            "foreground": "#FFFFFF",
        }

    if bool(snapshot.get("router_session_mismatch", False)):
        router_session = snapshot.get("router_session", {})
        if not isinstance(router_session, dict):
            router_session = {}
        return {
            "text": (
                "ROUTER SESSION 불일치: ready 파일이 router에서 ignored 될 수 있습니다. "
                "[router만 맞추고 감지 시작]을 눌러 현재 공식 8창 세션과 router를 맞추세요. "
                f"router={router_session.get('router_launcher_session_id', '') or '-'} "
                f"runtime={router_session.get('runtime_launcher_session_id', '') or '-'}"
            ),
            "background": "#B45309",
            "foreground": "#FFFFFF",
        }
    if not target_autoloop_router_session_ready(snapshot):
        return {
            "text": target_autoloop_router_session_not_ready_message(snapshot),
            "background": "#B45309",
            "foreground": "#FFFFFF",
        }

    router_inbox_summary = snapshot.get("router_inbox_ready_summary", {})
    if not isinstance(router_inbox_summary, dict):
        router_inbox_summary = {}
    if watcher_health != "active" and int(router_inbox_summary.get("count", 0) or 0) > 0:
        return {
            "text": target_autoloop_router_inbox_ready_detail(snapshot),
            "background": "#B45309",
            "foreground": "#FFFFFF",
        }

    if watcher_health == "active":
        active_target_ids = snapshot.get("watcher_target_ids", [])
        if isinstance(active_target_ids, list):
            active_target_text = target_autoloop_join_target_ids(
                [str(target_id or "").strip() for target_id in active_target_ids if str(target_id or "").strip()]
            )
        else:
            active_target_text = "(unknown)"
        active_scope = str(snapshot.get("watcher_target_scope", "") or "").strip() or "unknown"
        missing_target_ids = target_autoloop_watcher_missing_publish_ready_target_ids(snapshot)
        if missing_target_ids:
            missing_target_text = target_autoloop_join_target_ids(missing_target_ids)
            return {
                "text": (
                    "RunRoot 상태: 부분감지입니다. "
                    f"active watcher가 일부 publish-ready target을 감지하지 않습니다. 누락 target={missing_target_text}, "
                    f"현재 감지 target={active_target_text}, scope={active_scope}, heartbeat={watcher_health_detail or 'fresh'}. "
                    "해당 target 카드의 [포함 감지 재시작]을 실행하세요."
                ),
                "background": "#B45309",
                "foreground": "#FFFFFF",
            }
        return {
            "text": (
                "RunRoot 상태: 감지중입니다. "
                f"manifest enabled={manifest_enabled_count}, publish-ready={manifest_publish_ready_count}/{manifest_enabled_count}, "
                f"heartbeat={watcher_health_detail or 'fresh'}, scope={active_scope}, 감지 target={active_target_text}."
            ),
            "background": "#15803D",
            "foreground": "#FFFFFF",
        }

    if start_allowed:
        return {
            "text": (
                "RunRoot 상태: 감지 시작 가능. "
                f"manifest target={target_autoloop_join_target_ids(manifest_ids)} / "
                f"publish-ready={manifest_publish_ready_count}/{manifest_enabled_count}. "
                "[독립셀 감지 시작]을 누르면 파일 생성 감지를 시작합니다."
            ),
            "background": "#1D4ED8",
            "foreground": "#FFFFFF",
        }

    return {
        "text": "RunRoot 상태: 감지 시작 차단. " + (start_detail or "상태 파일과 manifest를 확인하세요."),
        "background": "#B45309",
        "foreground": "#FFFFFF",
    }


def target_autoloop_start_button_label(
    runtime_snapshot: dict[str, object] | None,
    *,
    watcher_fresh: bool,
    latest_valid_run_root_available: bool,
) -> str:
    snapshot = runtime_snapshot or {}
    manifest_run_mode = str(snapshot.get("manifest_run_mode", "") or "").strip()
    if target_autoloop_run_root_is_pair_scoped(str(snapshot.get("run_root", "") or "")):
        return "새 RunRoot 준비 후 감지 시작"
    if not target_autoloop_run_root_is_canonical(str(snapshot.get("run_root", "") or "")):
        return "새 RunRoot 준비 후 감지 시작"
    if bool(snapshot.get("manifest_exists", False)) and manifest_run_mode and manifest_run_mode != "target-autoloop":
        return "새 RunRoot 준비 후 감지 시작"
    if target_autoloop_manifest_enabled_count(snapshot) == 0 and bool(snapshot.get("manifest_exists", False)):
        if latest_valid_run_root_available:
            return "최신 RunRoot로 전환 후 감지 시작"
        return "새 RunRoot 준비 후 감지 시작"
    if (
        bool(snapshot.get("manifest_exists", False))
        and target_autoloop_manifest_enabled_count(snapshot) > 0
        and int(snapshot.get("manifest_publish_ready_count", 0) or 0) < target_autoloop_manifest_enabled_count(snapshot)
    ):
        return "publish-ready 켜고 새 RunRoot 준비"
    if bool(target_autoloop_limit_reached_summary(snapshot).get("all_reached", False)):
        return "새 RunRoot 준비 후 감지 시작"
    if int(target_autoloop_output_block_summary(snapshot).get("limit_reached_ready_unaccepted_count", 0) or 0) > 0:
        return "새 RunRoot 준비 후 감지 시작"
    if bool(snapshot.get("router_session_mismatch", False)):
        return "router만 맞추고 감지 시작"
    if not target_autoloop_router_session_ready(snapshot):
        return "8창 재사용+router 동기화 후 감지 시작"
    watcher_state = str(snapshot.get("watcher_state", "") or "").strip()
    controller_state = str(snapshot.get("controller_state", "") or "").strip()
    if watcher_fresh and watcher_state == "paused":
        return "독립셀 감지중(일시정지)"
    if watcher_fresh and watcher_state == "running":
        return "독립셀 감지중"
    if controller_state == "stopped":
        return "독립셀 감지 재시작"
    if watcher_state in {"running", "paused"}:
        return "독립셀 감지 재시작(stale)"
    return "독립셀 감지 시작"
