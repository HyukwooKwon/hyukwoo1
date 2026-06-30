from __future__ import annotations

import ctypes
import json
import os
import re
import time
from pathlib import Path


TARGET_AUTOLOOP_SMOKE_MIN_CYCLES = 2


def target_autoloop_smoke_cycle_satisfied(cycle_count: object) -> bool:
    return _target_autoloop_int_value(cycle_count) >= TARGET_AUTOLOOP_SMOKE_MIN_CYCLES


def target_autoloop_smoke_cycle_summary(cycle_count: object, max_cycle_count: object) -> str:
    normalized_cycle_count = _target_autoloop_int_value(cycle_count)
    normalized_max_cycle_count = _target_autoloop_int_value(max_cycle_count)
    max_label = str(normalized_max_cycle_count) if normalized_max_cycle_count > 0 else "unbounded"
    if normalized_cycle_count >= TARGET_AUTOLOOP_SMOKE_MIN_CYCLES:
        return f"smoke satisfied({TARGET_AUTOLOOP_SMOKE_MIN_CYCLES}-cycle), max={max_label}"
    return f"smoke pending({normalized_cycle_count}/{TARGET_AUTOLOOP_SMOKE_MIN_CYCLES}), max={max_label}"


def _read_json_payload_with_retry(
    path: Path,
    *,
    retry_count: int = 2,
    retry_delay_sec: float = 0.05,
) -> tuple[object | None, str]:
    last_error = ""
    attempts = max(0, int(retry_count)) + 1
    for attempt in range(attempts):
        try:
            return json.loads(path.read_text(encoding="utf-8")), ""
        except Exception as exc:
            last_error = str(exc)
            if attempt + 1 < attempts:
                time.sleep(max(0.0, float(retry_delay_sec)))
    return None, last_error


def read_json_dict_if_present(path_value: object) -> dict[str, object]:
    normalized_path = str(path_value or "").strip()
    if not normalized_path:
        return {}
    path = Path(normalized_path)
    if not path.exists() or not path.is_file():
        return {}
    payload, _error = _read_json_payload_with_retry(path)
    if payload is None:
        return {}
    return payload if isinstance(payload, dict) else {}


def read_json_list_if_present(path_value: object) -> list[object]:
    normalized_path = str(path_value or "").strip()
    if not normalized_path:
        return []
    path = Path(normalized_path)
    if not path.exists() or not path.is_file():
        return []
    payload, _error = _read_json_payload_with_retry(path)
    if payload is None:
        return []
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        return [payload]
    return []


def read_json_dict_with_error(
    path_value: object,
    *,
    missing_error: str = "",
    not_dict_error: str = "json-payload-not-dict",
) -> tuple[dict[str, object], str]:
    normalized_path = str(path_value or "").strip()
    if not normalized_path:
        return {}, missing_error
    path = Path(normalized_path)
    if not path.exists() or not path.is_file():
        return {}, missing_error
    payload, error = _read_json_payload_with_retry(path)
    if payload is None:
        return {}, error
    if isinstance(payload, dict):
        return payload, ""
    return {}, not_dict_error


def target_autoloop_run_paths(run_root: object) -> dict[str, Path]:
    run_root_path = Path(str(run_root or "").strip())
    state_root = run_root_path / ".state"
    return {
        "run_root": run_root_path,
        "manifest_path": run_root_path / "manifest.json",
        "state_path": state_root / "target-state.json",
        "status_path": state_root / "target-autoloop-status.json",
        "control_path": state_root / "target-autoloop-control.json",
        "watcher_stdout_log_path": state_root / "target-autoloop-watcher.stdout.log",
        "watcher_stderr_log_path": state_root / "target-autoloop-watcher.stderr.log",
        "smoke_receipt_path": state_root / "target-autoloop-live-smoke-result.json",
    }


def target_autoloop_status_counts(status_payload: dict[str, object]) -> dict[str, object]:
    counts = status_payload.get("Counts", {}) if isinstance(status_payload, dict) else {}
    return counts if isinstance(counts, dict) else {}


def target_autoloop_status_targets(status_payload: dict[str, object]) -> list[object]:
    targets = status_payload.get("Targets", []) if isinstance(status_payload, dict) else []
    return targets if isinstance(targets, list) else []


def target_autoloop_state_targets(state_payload: dict[str, object]) -> list[dict[str, object]]:
    targets_object = state_payload.get("Targets", {}) if isinstance(state_payload, dict) else {}
    if not isinstance(targets_object, dict):
        return []
    rows: list[dict[str, object]] = []
    for target_id in sorted(str(key or "").strip() for key in targets_object if str(key or "").strip()):
        entry = targets_object.get(target_id)
        if not isinstance(entry, dict):
            continue
        row = dict(entry)
        cycle_count = _target_autoloop_int_value(row.get("CycleCount", 0))
        max_cycle_count = _target_autoloop_int_value(row.get("MaxCycleCount", 0))
        row["TargetId"] = target_id
        row["CycleCount"] = cycle_count
        row["MaxCycleCount"] = max_cycle_count
        row["RemainingCycleCount"] = max(max_cycle_count - cycle_count, 0) if max_cycle_count > 0 else None
        row["SmokeCycleMinCount"] = TARGET_AUTOLOOP_SMOKE_MIN_CYCLES
        row["SmokeCycleSatisfied"] = target_autoloop_smoke_cycle_satisfied(cycle_count)
        row["SmokeCycleSummary"] = target_autoloop_smoke_cycle_summary(cycle_count, max_cycle_count)
        rows.append(row)
    return rows


def target_autoloop_counts_from_targets(targets: list[object]) -> dict[str, object]:
    rows = [row for row in targets if isinstance(row, dict)]

    def phase_is(row: dict[str, object], phase: str) -> bool:
        return str(row.get("Phase", "") or "").strip() == phase

    return {
        "TotalTargets": len(rows),
        "EnabledTargets": sum(1 for row in rows if bool(row.get("Enabled", False))),
        "DispatchDelayTargets": sum(1 for row in rows if phase_is(row, "dispatch-delay")),
        "QueuedTargets": sum(1 for row in rows if phase_is(row, "queued")),
        "WaitingOutputTargets": sum(1 for row in rows if phase_is(row, "waiting-output")),
        "FailedTargets": sum(1 for row in rows if phase_is(row, "failed")),
        "LimitReachedTargets": sum(1 for row in rows if phase_is(row, "limit-reached")),
    }


def _file_mtime_ns(path: Path) -> int:
    try:
        stat = path.stat()
    except OSError:
        return 0
    return int(getattr(stat, "st_mtime_ns", int(stat.st_mtime * 1_000_000_000)))


def target_autoloop_manifest_targets(manifest_payload: dict[str, object]) -> list[object]:
    targets = manifest_payload.get("Targets", []) if isinstance(manifest_payload, dict) else []
    return targets if isinstance(targets, list) else []


def _target_autoloop_manifest_sidecar_status_path(manifest_row: dict[str, object]) -> str:
    status_path = str(manifest_row.get("TargetStatusPath", "") or "").strip()
    if status_path:
        return status_path
    state_root = str(manifest_row.get("TargetStateRoot", "") or "").strip()
    if state_root:
        return str(Path(state_root) / "target-autoloop-status.json")
    target_root = str(manifest_row.get("TargetRoot", "") or "").strip()
    if target_root:
        return str(Path(target_root) / ".state" / "target-autoloop-status.json")
    return ""


def target_autoloop_sidecar_status_targets(
    manifest_targets: list[object],
    *,
    global_status_path: object = "",
) -> list[dict[str, object]]:
    global_mtime_ns = _file_mtime_ns(Path(str(global_status_path or ""))) if str(global_status_path or "").strip() else 0
    rows: list[dict[str, object]] = []
    for manifest_row in manifest_targets:
        if not isinstance(manifest_row, dict):
            continue
        target_id = str(manifest_row.get("TargetId", "") or "").strip()
        if not target_id:
            continue
        sidecar_path_text = _target_autoloop_manifest_sidecar_status_path(manifest_row)
        if not sidecar_path_text:
            continue
        sidecar_path = Path(sidecar_path_text)
        sidecar_mtime_ns = _file_mtime_ns(sidecar_path)
        if sidecar_mtime_ns <= 0:
            continue
        if global_mtime_ns > 0 and sidecar_mtime_ns < global_mtime_ns:
            continue
        payload = read_json_dict_if_present(sidecar_path)
        if str(payload.get("SidecarKind", "") or "") != "target-status":
            continue
        sidecar_target_id = str(payload.get("TargetId", "") or "").strip()
        if sidecar_target_id and sidecar_target_id != target_id:
            continue
        target_row = payload.get("Target", {})
        row = dict(target_row) if isinstance(target_row, dict) else {}
        row["TargetId"] = target_id
        for key in (
            "TargetStatePath",
            "TargetStatusPath",
            "TargetControlPath",
            "TargetEventsPath",
            "TargetWatcherMutexName",
        ):
            value = str(payload.get(key, "") or manifest_row.get(key, "") or "").strip()
            if value:
                row[key] = value
        row["TargetStatusSidecarPath"] = str(sidecar_path)
        row["TargetStatusSidecarMtimeNs"] = sidecar_mtime_ns
        row["TargetStatusSidecarLoaded"] = True
        rows.append(row)
    return rows


def target_autoloop_merge_status_targets(
    status_targets: list[object],
    sidecar_targets: list[dict[str, object]],
) -> list[object]:
    if not sidecar_targets:
        return status_targets
    sidecar_by_target_id = {
        str(row.get("TargetId", "") or "").strip(): row
        for row in sidecar_targets
        if str(row.get("TargetId", "") or "").strip()
    }
    merged: list[object] = []
    seen: set[str] = set()
    for row in status_targets:
        if not isinstance(row, dict):
            merged.append(row)
            continue
        target_id = str(row.get("TargetId", "") or "").strip()
        if target_id and target_id in sidecar_by_target_id:
            merged.append({**row, **sidecar_by_target_id[target_id]})
            seen.add(target_id)
        else:
            merged.append(row)
            if target_id:
                seen.add(target_id)
    for target_id, row in sidecar_by_target_id.items():
        if target_id not in seen:
            merged.append(row)
    return merged


def target_autoloop_manifest_enabled_publish_ready_counts(manifest_targets: list[object]) -> tuple[int, int]:
    manifest_enabled_count = 0
    manifest_publish_ready_count = 0
    for manifest_row in manifest_targets:
        if not isinstance(manifest_row, dict):
            continue
        if bool(manifest_row.get("Enabled", False)):
            manifest_enabled_count += 1
            raw_trigger_kinds = manifest_row.get("TriggerKinds", []) or []
            if isinstance(raw_trigger_kinds, str):
                trigger_values = [raw_trigger_kinds]
            elif isinstance(raw_trigger_kinds, (list, tuple, set)):
                trigger_values = list(raw_trigger_kinds)
            else:
                trigger_values = []
            trigger_kinds = {str(trigger_kind or "").strip().lower() for trigger_kind in trigger_values}
            if "publish-ready" in trigger_kinds:
                manifest_publish_ready_count += 1
    return manifest_enabled_count, manifest_publish_ready_count


def _target_autoloop_trigger_kinds(row: dict[str, object]) -> set[str]:
    raw_trigger_kinds = row.get("TriggerKinds", []) or []
    if isinstance(raw_trigger_kinds, str):
        trigger_values = [raw_trigger_kinds]
    elif isinstance(raw_trigger_kinds, (list, tuple, set)):
        trigger_values = list(raw_trigger_kinds)
    else:
        trigger_values = []
    return {str(trigger_kind or "").strip().lower() for trigger_kind in trigger_values}


def _target_autoloop_status_target_map(status_targets: list[object]) -> dict[str, dict[str, object]]:
    rows: dict[str, dict[str, object]] = {}
    for row in status_targets:
        if not isinstance(row, dict):
            continue
        target_id = str(row.get("TargetId", "") or "").strip()
        if target_id:
            rows[target_id] = row
    return rows


def _target_autoloop_int_value(value: object) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _normalized_path_text(value: object) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    return os.path.normcase(os.path.normpath(os.path.abspath(text)))


def _retry_pending_scope_match(
    ready_path: Path,
    delivery: dict[str, object],
    *,
    scope_run_roots: set[str],
) -> bool:
    if not scope_run_roots:
        return True
    delivery_run_root = _normalized_path_text(delivery.get("RunRoot", ""))
    if delivery_run_root and delivery_run_root in scope_run_roots:
        return True
    try:
        payload_text = ready_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        payload_text = ""
    normalized_payload = payload_text.replace("/", "\\").casefold()
    return any(scope_root and scope_root in normalized_payload for scope_root in scope_run_roots)


def _focus_lost_retry_policy(failure_category: object, debug_log_path: object) -> dict[str, str]:
    if str(failure_category or "").strip() != "focus_lost":
        return {"stage": "not-focus-lost", "policy": "not-focus-lost", "hint": ""}
    debug_log_text = str(debug_log_path or "").strip()
    if not debug_log_text:
        return {
            "stage": "unknown",
            "policy": "manual-review",
            "hint": "focus_lost debug log를 찾지 못했습니다. 대상 셀창 상태를 확인한 뒤 current 항목만 재시도하세요.",
        }
    debug_log = Path(debug_log_text)
    if not debug_log.exists() or not debug_log.is_file():
        return {
            "stage": "unknown",
            "policy": "manual-review",
            "hint": "focus_lost debug log를 찾지 못했습니다. 대상 셀창 상태를 확인한 뒤 current 항목만 재시도하세요.",
        }
    try:
        log_text = debug_log.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return {
            "stage": "unknown",
            "policy": "manual-review",
            "hint": "focus_lost debug log를 읽지 못했습니다. 대상 셀창 상태를 확인한 뒤 current 항목만 재시도하세요.",
        }
    pre_input_focus_lost = bool(re.search(r"text_pre_(clear|paste)_focus_stolen_hard_fail", log_text))
    payload_or_submit_started = any(
        marker in log_text
        for marker in (
            "terminal_input_mode",
            "terminal_sendtext",
            "terminal_paste",
            "control_sendtext",
            "submit_precheck",
            "submit_complete",
        )
    )
    if pre_input_focus_lost and not payload_or_submit_started:
        return {
            "stage": "pre-input",
            "policy": "bounded-auto-retry-exhausted",
            "hint": "입력 시작 전 포커스 이탈입니다. router가 안전한 자동 재시도를 이미 소진했으므로, 셀창 포커스/사용자 idle을 확보한 뒤 current 항목만 재시도하세요.",
        }
    if payload_or_submit_started:
        return {
            "stage": "post-input-or-submit",
            "policy": "manual-review-duplicate-risk",
            "hint": "payload 입력 또는 submit 단계 이후 focus_lost입니다. 중복 전송 위험이 있어 자동 재시도하지 않습니다. 셀창에 이미 입력/전송된 내용이 있는지 먼저 확인하세요.",
        }
    return {
        "stage": "unknown",
        "policy": "manual-review",
        "hint": "focus_lost 단계가 불명확합니다. 대상 셀창 상태를 확인한 뒤 current 항목만 재시도하세요.",
    }


def _send_retry_policy(failure_category: object, debug_log_path: object) -> dict[str, str]:
    normalized_category = str(failure_category or "").strip()
    if normalized_category == "focus_lost":
        return _focus_lost_retry_policy(failure_category, debug_log_path)
    if normalized_category == "user_active_hold":
        return {
            "stage": "pre-input-user-active",
            "policy": "bounded-auto-retry-exhausted",
            "hint": "사용자 입력/포커스 활동 때문에 전송을 보류했습니다. 사용자 idle을 확보한 뒤 current 항목만 재시도하세요.",
        }
    if normalized_category == "window_not_found":
        return {
            "stage": "pre-input-window-resolution",
            "policy": "manual-retry-after-window-check",
            "hint": "대상 셀창을 찾지 못했습니다. 공식 8창/binding 상태를 확인한 뒤 current 항목만 재시도하세요.",
        }
    if normalized_category != "send_failed":
        return {"stage": "not-send-failure", "policy": "not-send-failure", "hint": ""}

    debug_log_text = str(debug_log_path or "").strip()
    if not debug_log_text:
        return {
            "stage": "unknown",
            "policy": "manual-review",
            "hint": "send_failed debug log를 찾지 못했습니다. payload 입력 여부가 불명확하므로 셀창 상태를 확인한 뒤 current 항목만 재시도하세요.",
        }
    debug_log = Path(debug_log_text)
    if not debug_log.exists() or not debug_log.is_file():
        return {
            "stage": "unknown",
            "policy": "manual-review",
            "hint": "send_failed debug log를 찾지 못했습니다. payload 입력 여부가 불명확하므로 셀창 상태를 확인한 뒤 current 항목만 재시도하세요.",
        }
    try:
        log_text = debug_log.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return {
            "stage": "unknown",
            "policy": "manual-review",
            "hint": "send_failed debug log를 읽지 못했습니다. payload 입력 여부가 불명확하므로 셀창 상태를 확인한 뒤 current 항목만 재시도하세요.",
        }

    clipboard_input_prep_failed = (
        "terminal_paste_clipwait_failed" in log_text
        or "clipboard_not_ready_for_terminal_paste" in log_text
    )
    unsupported_submit_mode = "unsupported_submit_mode" in log_text
    submit_dispatched = bool(re.search(r"submit_(attempt|after_dispatch|complete)", log_text))
    submit_started = any(
        marker in log_text
        for marker in ("submit_precheck", "submit_guard_begin", "submit_guard_complete")
    )
    payload_input_started = any(
        marker in log_text for marker in ("terminal_sendtext", "terminal_paste", "control_sendtext")
    )
    if clipboard_input_prep_failed and not payload_input_started and not submit_started:
        return {
            "stage": "pre-input",
            "policy": "bounded-auto-retry-exhausted",
            "hint": "clipboard/paste 준비 단계 실패라 payload 입력 전으로 판단했습니다. router가 제한된 자동 재시도를 소진했으므로 current 항목만 재시도하세요.",
        }
    if unsupported_submit_mode:
        return {
            "stage": "submit-config",
            "policy": "manual-review-config-error",
            "hint": "지원하지 않는 submit mode 설정입니다. SubmitRetryModes 설정을 수정한 뒤 current 항목만 재시도하세요.",
        }
    if submit_dispatched:
        return {
            "stage": "post-submit-dispatch",
            "policy": "manual-review-duplicate-risk",
            "hint": "submit dispatch 이후 send_failed입니다. 이미 전송됐을 수 있어 셀창 결과/산출물을 먼저 확인하세요.",
        }
    if submit_started or payload_input_started or "terminal_input_mode" in log_text:
        return {
            "stage": "post-input-or-submit",
            "policy": "manual-review-duplicate-risk",
            "hint": "payload 입력 또는 submit 준비 이후 send_failed입니다. 중복 전송 위험이 있어 셀창 입력 상태를 먼저 확인하세요.",
        }
    return {
        "stage": "unknown",
        "policy": "manual-review",
        "hint": "send_failed 단계가 불명확합니다. 셀창 상태를 확인한 뒤 current 항목만 재시도하세요.",
    }


def target_autoloop_source_outbox_contract_summary(
    manifest_targets: list[object],
    status_targets: list[object],
) -> dict[str, object]:
    status_by_target = _target_autoloop_status_target_map(status_targets)
    items: list[dict[str, object]] = []
    for manifest_row in manifest_targets:
        if not isinstance(manifest_row, dict):
            continue
        target_id = str(manifest_row.get("TargetId", "") or "").strip()
        if not target_id or not bool(manifest_row.get("Enabled", False)):
            continue
        if "publish-ready" not in _target_autoloop_trigger_kinds(manifest_row):
            continue

        summary_path = str(manifest_row.get("SourceSummaryPath", "") or "").strip()
        review_path = str(manifest_row.get("SourceReviewZipPath", "") or "").strip()
        publish_path = str(manifest_row.get("PublishReadyPath", "") or "").strip()
        summary_exists = bool(summary_path and Path(summary_path).is_file())
        review_exists = bool(review_path and Path(review_path).is_file())
        publish_exists = bool(publish_path and Path(publish_path).is_file())
        marker_payload = read_json_dict_if_present(publish_path)
        marker_target_id = str(marker_payload.get("TargetId", "") or "").strip()
        output_fingerprint = str(marker_payload.get("OutputFingerprint", "") or "").strip()
        publish_valid = bool(
            summary_exists
            and review_exists
            and publish_exists
            and output_fingerprint
            and (not marker_target_id or marker_target_id == target_id)
        )

        status_row = status_by_target.get(target_id, {})
        phase = str(status_row.get("Phase", "") or "").strip()
        next_action = str(status_row.get("NextAction", "") or "").strip()
        cycle_count = _target_autoloop_int_value(status_row.get("CycleCount", 0))
        max_cycle_count = _target_autoloop_int_value(status_row.get("MaxCycleCount", 0))
        last_handled = str(status_row.get("LastHandledOutputFingerprint", "") or "").strip()
        last_dispatch_state = str(status_row.get("LastDispatchState", "") or "").strip()
        limit_reached = phase == "limit-reached" or next_action == "limit-reached" or (
            max_cycle_count > 0 and cycle_count >= max_cycle_count
        )
        ready_unaccepted = bool(publish_valid and output_fingerprint != last_handled)
        router_blocked = last_dispatch_state in {"router-session-not-ready", "router-session-mismatch"}
        items.append(
            {
                "target_id": target_id,
                "phase": phase,
                "next_action": next_action,
                "cycle_count": cycle_count,
                "max_cycle_count": max_cycle_count,
                "limit_reached": limit_reached,
                "ready_unaccepted": ready_unaccepted,
                "router_blocked": router_blocked,
                "last_dispatch_state": last_dispatch_state,
                "current_marker_fingerprint": output_fingerprint,
                "last_handled_output_fingerprint": last_handled,
                "publish_ready_path": publish_path,
                "source_outbox_path": str(manifest_row.get("SourceOutboxPath", "") or "").strip(),
            }
        )

    limit_items = [item for item in items if bool(item.get("limit_reached", False))]
    ready_items = [item for item in items if bool(item.get("ready_unaccepted", False))]
    limit_ready_items = [
        item for item in items if bool(item.get("limit_reached", False)) and bool(item.get("ready_unaccepted", False))
    ]
    router_blocked_items = [item for item in items if bool(item.get("router_blocked", False))]
    latest = (
        (limit_ready_items or ready_items or router_blocked_items or limit_items or [{}])[0]
    )
    return {
        "count": len(items),
        "limit_reached_count": len(limit_items),
        "ready_unaccepted_count": len(ready_items),
        "limit_reached_ready_unaccepted_count": len(limit_ready_items),
        "router_blocked_count": len(router_blocked_items),
        "target_ids": [str(item.get("target_id", "")) for item in items if str(item.get("target_id", ""))],
        "limit_reached_target_ids": [
            str(item.get("target_id", "")) for item in limit_items if str(item.get("target_id", ""))
        ],
        "ready_unaccepted_target_ids": [
            str(item.get("target_id", "")) for item in ready_items if str(item.get("target_id", ""))
        ],
        "limit_reached_ready_unaccepted_target_ids": [
            str(item.get("target_id", "")) for item in limit_ready_items if str(item.get("target_id", ""))
        ],
        "router_blocked_target_ids": [
            str(item.get("target_id", "")) for item in router_blocked_items if str(item.get("target_id", ""))
        ],
        "latest_target_id": str(latest.get("target_id", "") or ""),
        "latest_cycle_count": _target_autoloop_int_value(latest.get("cycle_count", 0)),
        "latest_max_cycle_count": _target_autoloop_int_value(latest.get("max_cycle_count", 0)),
        "latest_last_dispatch_state": str(latest.get("last_dispatch_state", "") or ""),
        "latest_publish_ready_path": str(latest.get("publish_ready_path", "") or ""),
        "items": items,
    }


def _unescape_double_quoted_psd1_value(value: str) -> str:
    replacements = {
        "0": "\0",
        "a": "\a",
        "b": "\b",
        "e": "\x1b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "v": "\v",
        '"': '"',
        "`": "`",
        "$": "$",
    }
    return re.sub(
        r"`(.)",
        lambda match: replacements.get(str(match.group(1) or ""), str(match.group(1) or "")),
        value,
    )


def psd1_string_value(raw_text: str, key: str) -> str:
    match = re.search(
        r"(?m)^\s*"
        + re.escape(str(key or ""))
        + r'''\s*=\s*(?:'((?:''|[^'])*)'|"((?:`.|[^"`])*)")''',
        str(raw_text or ""),
    )
    if not match:
        return ""
    single_quoted_value = match.group(1)
    if single_quoted_value is not None:
        return str(single_quoted_value or "").replace("''", "'").strip()
    return _unescape_double_quoted_psd1_value(str(match.group(2) or "")).strip()


def psd1_bool_value(raw_text: str, key: str, default: bool) -> bool:
    match = re.search(r"(?m)^\s*" + re.escape(str(key or "")) + r"\s*=\s*\$(true|false)\b", str(raw_text or ""), re.IGNORECASE)
    if not match:
        return bool(default)
    return str(match.group(1) or "").lower() == "true"


def psd1_int_value(raw_text: str, key: str, default: int) -> int:
    match = re.search(r"(?m)^\s*" + re.escape(str(key or "")) + r"\s*=\s*(-?\d+)\b", str(raw_text or ""))
    if not match:
        return int(default)
    try:
        return int(match.group(1))
    except (TypeError, ValueError):
        return int(default)


def single_quoted_psd1_value(raw_text: str, key: str) -> str:
    return psd1_string_value(raw_text, key)


def router_config_send_settings_from_config_file(config_path: object, *, root: Path) -> dict[str, object]:
    config_path_text = str(config_path or "").strip()
    if not config_path_text:
        return {}
    path = Path(config_path_text)
    if not path.is_absolute():
        path = root / path
    try:
        resolved_path = path.resolve()
    except OSError:
        resolved_path = path
    if not resolved_path.exists() or not resolved_path.is_file():
        return {}
    try:
        raw_text = resolved_path.read_text(encoding="utf-8")
    except Exception:
        return {}
    return {
        "config_path": str(resolved_path),
        "require_user_idle_before_send": psd1_bool_value(raw_text, "RequireUserIdleBeforeSend", False),
        "min_user_idle_before_send_ms": psd1_int_value(raw_text, "MinUserIdleBeforeSendMs", 0),
        "user_idle_wait_timeout_ms": psd1_int_value(raw_text, "UserIdleWaitTimeoutMs", 0),
        "user_idle_wait_poll_ms": psd1_int_value(raw_text, "UserIdleWaitPollMs", 250),
        "submit_guard_ms": psd1_int_value(raw_text, "SubmitGuardMs", 0),
        "visible_execution_fail_on_focus_steal": psd1_bool_value(raw_text, "VisibleExecutionFailOnFocusSteal", False),
        "visible_execution_restore_previous_active": psd1_bool_value(raw_text, "VisibleExecutionRestorePreviousActive", True),
    }


def target_autoloop_router_session_paths_from_config_file(
    config_path: object,
    *,
    root: Path,
) -> dict[str, str]:
    config_path_text = str(config_path or "").strip()
    if not config_path_text:
        return {}
    path = Path(config_path_text)
    if not path.is_absolute():
        path = root / path
    try:
        resolved_path = path.resolve()
    except OSError:
        resolved_path = path
    if not resolved_path.exists() or not resolved_path.is_file():
        return {}
    try:
        raw_text = resolved_path.read_text(encoding="utf-8")
    except Exception:
        return {}
    runtime_map_path = psd1_string_value(raw_text, "RuntimeMapPath")
    router_state_path = psd1_string_value(raw_text, "RouterStatePath")
    router_mutex_name = psd1_string_value(raw_text, "RouterMutexName")
    retry_pending_root = psd1_string_value(raw_text, "RetryPendingRoot")
    result: dict[str, str] = {"config_path": str(resolved_path)}
    if runtime_map_path:
        result["runtime_map_path"] = runtime_map_path
    if router_state_path:
        result["router_state_path"] = router_state_path
    if router_mutex_name:
        result["router_mutex_name"] = router_mutex_name
    if retry_pending_root:
        result["retry_pending_root"] = retry_pending_root
    return result


def target_autoloop_router_session_paths(
    *,
    effective_data: dict[str, object] | None,
    config_path: object,
    root: Path,
) -> dict[str, str]:
    effective = effective_data if isinstance(effective_data, dict) else {}
    config = effective.get("Config", {}) if isinstance(effective.get("Config", {}), dict) else {}
    runtime_map_path = str(config.get("RuntimeMapPath", "") or "").strip()
    router_state_path = str(config.get("RouterStatePath", "") or "").strip()
    router_mutex_name = str(config.get("RouterMutexName", "") or "").strip()
    retry_pending_root = str(config.get("RetryPendingRoot", "") or "").strip()
    source = "effective-data" if (runtime_map_path or router_state_path or router_mutex_name or retry_pending_root) else ""
    file_paths = target_autoloop_router_session_paths_from_config_file(config_path, root=root)
    file_runtime_map_path = str(file_paths.get("runtime_map_path", "") or "").strip()
    file_router_state_path = str(file_paths.get("router_state_path", "") or "").strip()
    file_router_mutex_name = str(file_paths.get("router_mutex_name", "") or "").strip()
    file_retry_pending_root = str(file_paths.get("retry_pending_root", "") or "").strip()
    if file_runtime_map_path or file_router_state_path or file_router_mutex_name or file_retry_pending_root:
        runtime_map_path = file_runtime_map_path or runtime_map_path
        router_state_path = file_router_state_path or router_state_path
        router_mutex_name = file_router_mutex_name or router_mutex_name
        retry_pending_root = file_retry_pending_root or retry_pending_root
        source = "config-file"
    return {
        "runtime_map_path": runtime_map_path,
        "router_state_path": router_state_path,
        "router_mutex_name": router_mutex_name,
        "retry_pending_root": retry_pending_root,
        "source": source,
        "config_path": str(file_paths.get("config_path", "") or ""),
    }


def target_autoloop_retry_pending_summary(
    retry_pending_root: object,
    *,
    target_ids: list[str] | tuple[str, ...] | set[str] | None = None,
    scope_run_roots: list[str] | tuple[str, ...] | set[str] | None = None,
    current_ready_path_by_target_id: dict[str, object] | None = None,
) -> dict[str, object]:
    root_text = str(retry_pending_root or "").strip()
    allowed_targets = {
        str(target_id or "").strip()
        for target_id in (target_ids or [])
        if str(target_id or "").strip()
    }
    normalized_scope_roots = {
        _normalized_path_text(scope_run_root)
        for scope_run_root in (scope_run_roots or [])
        if _normalized_path_text(scope_run_root)
    }
    current_ready_paths = {
        str(target_id or "").strip(): str(path_value or "").strip()
        for target_id, path_value in (current_ready_path_by_target_id or {}).items()
        if str(target_id or "").strip() and str(path_value or "").strip()
    }
    items: list[dict[str, object]] = []
    ignored_out_of_scope_count = 0
    root_path = Path(root_text) if root_text else None
    if root_path is not None and root_path.exists() and root_path.is_dir():
        def retry_pending_sort_key(path: Path) -> tuple[int, str]:
            try:
                return (int(path.stat().st_mtime_ns), path.name)
            except OSError:
                return (0, path.name)

        for ready_path in sorted(root_path.glob("*.ready.txt"), key=retry_pending_sort_key):
            segments = ready_path.name.split("__", 2)
            if len(segments) < 3:
                continue
            target_id = segments[0]
            if allowed_targets and target_id not in allowed_targets:
                continue
            metadata = read_json_dict_if_present(str(ready_path) + ".meta.json")
            delivery = read_json_dict_if_present(str(ready_path) + ".delivery.json")
            if not _retry_pending_scope_match(ready_path, delivery, scope_run_roots=normalized_scope_roots):
                ignored_out_of_scope_count += 1
                continue
            try:
                last_write_time = ready_path.stat().st_mtime
            except OSError:
                last_write_time = 0.0
            original_path = str(metadata.get("OriginalPath", "") or "").strip()
            current_ready_path = current_ready_paths.get(target_id, "")
            is_current_for_target = True
            stale_reason = ""
            if current_ready_path:
                if not original_path:
                    is_current_for_target = False
                    stale_reason = "missing-original-path"
                elif _normalized_path_text(original_path) != _normalized_path_text(current_ready_path):
                    is_current_for_target = False
                    stale_reason = "not-current-last-router-ready-path"
            failure_category = str(metadata.get("FailureCategory", "") or "").strip()
            debug_log_path = str(metadata.get("DebugLogPath", "") or "").strip()
            focus_policy = _focus_lost_retry_policy(failure_category, debug_log_path)
            send_policy = _send_retry_policy(failure_category, debug_log_path)
            focus_stage = str(metadata.get("FocusLostStage", "") or "").strip() or focus_policy["stage"]
            focus_retry_policy = (
                str(metadata.get("FocusLostRetryPolicy", "") or "").strip()
                or focus_policy["policy"]
            )
            focus_fallback_stage = focus_stage if failure_category == "focus_lost" else send_policy["stage"]
            focus_fallback_policy = focus_retry_policy if failure_category == "focus_lost" else send_policy["policy"]
            send_stage = str(metadata.get("SendStage", "") or "").strip() or focus_fallback_stage
            send_retry_policy = str(metadata.get("SendRetryPolicy", "") or "").strip() or focus_fallback_policy
            operator_retry_hint = (
                str(metadata.get("OperatorRetryHint", "") or "").strip()
                or send_policy["hint"]
                or focus_policy["hint"]
            )
            items.append(
                {
                    "target_id": target_id,
                    "path": str(ready_path),
                    "last_write_time": last_write_time,
                    "run_root": str(delivery.get("RunRoot", "") or "").strip(),
                    "original_path": original_path,
                    "current_router_ready_path": current_ready_path,
                    "is_current_for_target": is_current_for_target,
                    "stale_reason": stale_reason,
                    "failure_category": failure_category,
                    "failure_message": str(metadata.get("FailureMessage", "") or "").strip(),
                    "debug_log_path": debug_log_path,
                    "send_stage": send_stage,
                    "send_retry_policy": send_retry_policy,
                    "focus_lost_stage": focus_stage,
                    "focus_lost_retry_policy": focus_retry_policy,
                    "operator_retry_hint": operator_retry_hint,
                }
            )
    target_id_values: list[str] = []
    for item in items:
        target_id = str(item.get("target_id", "") or "").strip()
        if target_id and target_id not in target_id_values:
            target_id_values.append(target_id)
    latest = max(items, key=lambda item: float(item.get("last_write_time", 0.0) or 0.0), default={})
    current_items = [item for item in items if bool(item.get("is_current_for_target", True))]
    stale_items = [item for item in items if not bool(item.get("is_current_for_target", True))]
    current_target_id_values: list[str] = []
    for item in current_items:
        target_id = str(item.get("target_id", "") or "").strip()
        if target_id and target_id not in current_target_id_values:
            current_target_id_values.append(target_id)
    stale_target_id_values: list[str] = []
    for item in stale_items:
        target_id = str(item.get("target_id", "") or "").strip()
        if target_id and target_id not in stale_target_id_values:
            stale_target_id_values.append(target_id)
    latest_current = max(current_items, key=lambda item: float(item.get("last_write_time", 0.0) or 0.0), default={})
    latest_stale = max(stale_items, key=lambda item: float(item.get("last_write_time", 0.0) or 0.0), default={})
    return {
        "root": root_text,
        "count": len(items),
        "target_ids": target_id_values,
        "current_count": len(current_items),
        "current_target_ids": current_target_id_values,
        "stale_count": len(stale_items),
        "stale_target_ids": stale_target_id_values,
        "latest_path": str(latest.get("path", "") or ""),
        "latest_target_id": str(latest.get("target_id", "") or ""),
        "latest_failure_category": str(latest.get("failure_category", "") or ""),
        "latest_failure_message": str(latest.get("failure_message", "") or ""),
        "latest_debug_log_path": str(latest.get("debug_log_path", "") or ""),
        "latest_current_path": str(latest_current.get("path", "") or ""),
        "latest_current_target_id": str(latest_current.get("target_id", "") or ""),
        "latest_current_failure_category": str(latest_current.get("failure_category", "") or ""),
        "latest_current_failure_message": str(latest_current.get("failure_message", "") or ""),
        "latest_current_debug_log_path": str(latest_current.get("debug_log_path", "") or ""),
        "latest_current_send_stage": str(latest_current.get("send_stage", "") or ""),
        "latest_current_send_retry_policy": str(latest_current.get("send_retry_policy", "") or ""),
        "latest_current_focus_lost_stage": str(latest_current.get("focus_lost_stage", "") or ""),
        "latest_current_focus_lost_retry_policy": str(latest_current.get("focus_lost_retry_policy", "") or ""),
        "latest_current_operator_retry_hint": str(latest_current.get("operator_retry_hint", "") or ""),
        "latest_stale_path": str(latest_stale.get("path", "") or ""),
        "latest_stale_target_id": str(latest_stale.get("target_id", "") or ""),
        "latest_stale_reason": str(latest_stale.get("stale_reason", "") or ""),
        "latest_stale_send_stage": str(latest_stale.get("send_stage", "") or ""),
        "latest_stale_send_retry_policy": str(latest_stale.get("send_retry_policy", "") or ""),
        "latest_stale_focus_lost_stage": str(latest_stale.get("focus_lost_stage", "") or ""),
        "latest_stale_focus_lost_retry_policy": str(latest_stale.get("focus_lost_retry_policy", "") or ""),
        "latest_stale_operator_retry_hint": str(latest_stale.get("operator_retry_hint", "") or ""),
        "ignored_out_of_scope_count": ignored_out_of_scope_count,
        "items": items,
        "current_items": current_items,
        "stale_items": stale_items,
    }


def target_autoloop_router_inbox_ready_summary(
    manifest_targets: object,
    *,
    target_ids: list[str] | tuple[str, ...] | set[str] | None = None,
) -> dict[str, object]:
    rows = manifest_targets if isinstance(manifest_targets, list) else []
    allowed_targets = {
        str(target_id or "").strip()
        for target_id in (target_ids or [])
        if str(target_id or "").strip()
    }
    items: list[dict[str, object]] = []
    target_folders: list[dict[str, object]] = []

    for row in rows:
        if not isinstance(row, dict):
            continue
        target_id = str(row.get("TargetId", "") or "").strip()
        if not target_id:
            continue
        if allowed_targets and target_id not in allowed_targets:
            continue
        folder_text = str(row.get("GlobalFolder", "") or "").strip()
        if not folder_text:
            continue
        folder_path = Path(folder_text)
        folder_exists = folder_path.exists() and folder_path.is_dir()
        target_folders.append({"target_id": target_id, "folder": folder_text, "exists": folder_exists})
        if not folder_exists:
            continue

        def ready_sort_key(path: Path) -> tuple[int, str]:
            try:
                return (int(path.stat().st_mtime_ns), path.name)
            except OSError:
                return (0, path.name)

        for ready_path in sorted(folder_path.glob("*.ready.txt"), key=ready_sort_key):
            delivery_path = Path(str(ready_path) + ".delivery.json")
            delivery = read_json_dict_if_present(delivery_path)
            try:
                last_write_time = ready_path.stat().st_mtime
            except OSError:
                last_write_time = 0.0
            items.append(
                {
                    "target_id": target_id,
                    "folder": folder_text,
                    "path": str(ready_path),
                    "last_write_time": last_write_time,
                    "delivery_path": str(delivery_path),
                    "delivery_exists": delivery_path.exists() and delivery_path.is_file(),
                    "delivery_target_id": str(delivery.get("TargetId", "") or "").strip(),
                    "launcher_session_id": str(delivery.get("LauncherSessionId", "") or "").strip(),
                    "message_type": str(delivery.get("MessageType", "") or "").strip(),
                    "created_at": str(delivery.get("CreatedAt", "") or "").strip(),
                }
            )

    target_id_values: list[str] = []
    for item in items:
        target_id = str(item.get("target_id", "") or "").strip()
        if target_id and target_id not in target_id_values:
            target_id_values.append(target_id)
    latest = max(items, key=lambda item: float(item.get("last_write_time", 0.0) or 0.0), default={})
    return {
        "count": len(items),
        "target_ids": target_id_values,
        "latest_path": str(latest.get("path", "") or ""),
        "latest_target_id": str(latest.get("target_id", "") or ""),
        "latest_launcher_session_id": str(latest.get("launcher_session_id", "") or ""),
        "latest_message_type": str(latest.get("message_type", "") or ""),
        "latest_created_at": str(latest.get("created_at", "") or ""),
        "latest_last_write_time": float(latest.get("last_write_time", 0.0) or 0.0),
        "target_folders": target_folders,
        "items": items,
    }


def process_exists(process_id: object) -> bool:
    try:
        pid = int(str(process_id or "0").strip())
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if pid == os.getpid():
        return True
    if os.name == "nt":
        try:
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            process_query_limited_information = 0x1000
            handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
            if not handle:
                return False
            kernel32.CloseHandle(handle)
            return True
        except Exception:
            return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def windows_named_mutex_held(name: object) -> bool:
    mutex_name = str(name or "").strip()
    if not mutex_name or os.name != "nt":
        return False
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        synchronize = 0x00100000
        mutex_modify_state = 0x0001
        wait_object_0 = 0x00000000
        wait_abandoned = 0x00000080
        wait_timeout = 0x00000102
        handle = kernel32.OpenMutexW(synchronize | mutex_modify_state, False, mutex_name)
        if not handle:
            return False
        try:
            wait_result = kernel32.WaitForSingleObject(handle, 0)
            if wait_result == wait_timeout:
                return True
            if wait_result in (wait_object_0, wait_abandoned):
                if wait_result == wait_object_0:
                    kernel32.ReleaseMutex(handle)
                return wait_result == wait_abandoned
            return False
        finally:
            kernel32.CloseHandle(handle)
    except Exception:
        return False


def file_age_seconds(path_value: object) -> int:
    path_text = str(path_value or "").strip()
    if not path_text:
        return -1
    path = Path(path_text)
    try:
        return max(0, int(time.time() - path.stat().st_mtime))
    except OSError:
        return -1


def target_autoloop_router_session_snapshot(session_paths: dict[str, str], *, root: Path | None = None) -> dict[str, object]:
    runtime_map_path = str(session_paths.get("runtime_map_path", "") or "").strip()
    router_state_path = str(session_paths.get("router_state_path", "") or "").strip()
    config_path = str(session_paths.get("config_path", "") or "").strip()
    config_root = root if isinstance(root, Path) else Path.cwd()
    runtime_items = read_json_list_if_present(runtime_map_path)
    runtime_session_ids = sorted(
        {
            str(item.get("LauncherSessionId", "") or "").strip()
            for item in runtime_items
            if isinstance(item, dict) and str(item.get("LauncherSessionId", "") or "").strip()
        }
    )
    runtime_launcher_session_id = runtime_session_ids[0] if len(runtime_session_ids) == 1 else ""
    router_state = read_json_dict_if_present(router_state_path)
    router_status = str(router_state.get("Status", "") or "").strip()
    router_launcher_session_id = str(router_state.get("LauncherSessionId", "") or "").strip()
    router_pid = str(router_state.get("RouterPid", "") or "").strip()
    router_pid_exists = process_exists(router_pid)
    configured_send_settings = router_config_send_settings_from_config_file(config_path, root=config_root)
    drift_reasons: list[str] = []
    observed_send_setting_keys = {
        "RequireUserIdleBeforeSend": "require_user_idle_before_send",
        "MinUserIdleBeforeSendMs": "min_user_idle_before_send_ms",
        "UserIdleWaitTimeoutMs": "user_idle_wait_timeout_ms",
        "UserIdleWaitPollMs": "user_idle_wait_poll_ms",
        "SubmitGuardMs": "submit_guard_ms",
        "VisibleExecutionFailOnFocusSteal": "visible_execution_fail_on_focus_steal",
        "VisibleExecutionRestorePreviousActive": "visible_execution_restore_previous_active",
    }
    has_observed_send_settings = any(key in router_state for key in observed_send_setting_keys)
    config_needs_send_state = bool(
        configured_send_settings.get("require_user_idle_before_send", False)
        or int(configured_send_settings.get("min_user_idle_before_send_ms", 0) or 0) > 0
        or int(configured_send_settings.get("user_idle_wait_timeout_ms", 0) or 0) > 0
        or int(configured_send_settings.get("submit_guard_ms", 0) or 0) > 0
        or bool(configured_send_settings.get("visible_execution_fail_on_focus_steal", False))
        or not bool(configured_send_settings.get("visible_execution_restore_previous_active", True))
    )
    if router_status == "running" and config_needs_send_state and not has_observed_send_settings:
        drift_reasons.append("router-state-missing-effective-send-settings")
    elif router_status == "running" and has_observed_send_settings:
        for router_key, config_key in observed_send_setting_keys.items():
            if router_key not in router_state:
                drift_reasons.append(f"missing:{router_key}")
                continue
            configured_value = configured_send_settings.get(config_key)
            observed_value = router_state.get(router_key)
            if isinstance(configured_value, bool):
                if bool(observed_value) != configured_value:
                    drift_reasons.append(f"mismatch:{router_key}:config={configured_value}:router={bool(observed_value)}")
                continue
            try:
                if int(observed_value or 0) != int(configured_value or 0):
                    drift_reasons.append(f"mismatch:{router_key}:config={int(configured_value or 0)}:router={int(observed_value or 0)}")
            except (TypeError, ValueError):
                drift_reasons.append(f"mismatch:{router_key}:config={configured_value}:router={observed_value}")
    router_mutex_name = str(session_paths.get("router_mutex_name", "") or "").strip()
    if not router_mutex_name:
        router_mutex_name = str(router_state.get("RouterMutexName", "") or "").strip()
    router_mutex_held = windows_named_mutex_held(router_mutex_name) if router_mutex_name else False
    state = "not-configured"
    if runtime_map_path or router_state_path:
        state = "insufficient-data"
    if len(runtime_session_ids) > 1:
        state = "runtime-session-ambiguous"
    elif router_status and router_status != "running":
        state = "router-not-running"
    elif (
        router_status == "running"
        and runtime_launcher_session_id
        and router_launcher_session_id
        and runtime_launcher_session_id != router_launcher_session_id
    ):
        state = "mismatch"
    elif router_status == "running" and not router_pid:
        state = "router-pid-missing"
    elif router_status == "running" and not router_pid_exists:
        state = "router-pid-not-running"
    elif router_status == "running" and router_mutex_name and not router_mutex_held:
        state = "router-mutex-not-held"
    elif runtime_launcher_session_id and router_launcher_session_id:
        state = "ok"
    return {
        "state": state,
        "mismatch": state == "mismatch",
        "runtime_map_path": runtime_map_path,
        "runtime_map_exists": bool(runtime_map_path and Path(runtime_map_path).exists()),
        "runtime_launcher_session_ids": runtime_session_ids,
        "runtime_launcher_session_id": runtime_launcher_session_id,
        "router_state_path": router_state_path,
        "router_state_exists": bool(router_state_path and Path(router_state_path).exists()),
        "router_state_age_seconds": file_age_seconds(router_state_path),
        "router_state_updated_at": str(router_state.get("UpdatedAt", "") or "").strip(),
        "router_status": router_status,
        "router_launcher_session_id": router_launcher_session_id,
        "router_pid": router_pid,
        "router_pid_exists": router_pid_exists,
        "router_mutex_name": router_mutex_name,
        "router_mutex_held": router_mutex_held,
        "router_config_drift": bool(drift_reasons),
        "router_config_drift_reasons": drift_reasons,
        "configured_require_user_idle_before_send": bool(configured_send_settings.get("require_user_idle_before_send", False)),
        "configured_min_user_idle_before_send_ms": int(configured_send_settings.get("min_user_idle_before_send_ms", 0) or 0),
        "configured_user_idle_wait_timeout_ms": int(configured_send_settings.get("user_idle_wait_timeout_ms", 0) or 0),
        "configured_user_idle_wait_poll_ms": int(configured_send_settings.get("user_idle_wait_poll_ms", 250) or 250),
        "configured_submit_guard_ms": int(configured_send_settings.get("submit_guard_ms", 0) or 0),
        "configured_visible_execution_fail_on_focus_steal": bool(configured_send_settings.get("visible_execution_fail_on_focus_steal", False)),
        "router_require_user_idle_before_send": router_state.get("RequireUserIdleBeforeSend", None),
        "router_min_user_idle_before_send_ms": router_state.get("MinUserIdleBeforeSendMs", None),
        "router_user_idle_wait_timeout_ms": router_state.get("UserIdleWaitTimeoutMs", None),
        "router_user_idle_wait_poll_ms": router_state.get("UserIdleWaitPollMs", None),
        "router_submit_guard_ms": router_state.get("SubmitGuardMs", None),
        "router_visible_execution_fail_on_focus_steal": router_state.get("VisibleExecutionFailOnFocusSteal", None),
        "path_source": str(session_paths.get("source", "") or ""),
        "config_path": config_path,
    }


def target_autoloop_router_session_paths_ready(session_snapshot: dict[str, object]) -> bool:
    if not isinstance(session_snapshot, dict):
        return False
    if str(session_snapshot.get("state", "") or "").strip() != "ok":
        return False
    router_session_id = str(session_snapshot.get("router_launcher_session_id", "") or "").strip()
    runtime_session_id = str(session_snapshot.get("runtime_launcher_session_id", "") or "").strip()
    return bool(router_session_id and runtime_session_id and router_session_id == runtime_session_id)


def target_autoloop_router_session_paths_not_ready_message(session_snapshot: dict[str, object]) -> str:
    snapshot = session_snapshot if isinstance(session_snapshot, dict) else {}
    return (
        "router sync completed but session mismatch remains: "
        f"state={snapshot.get('state', '') or '-'} "
        f"router={snapshot.get('router_launcher_session_id', '') or '-'} "
        f"runtime={snapshot.get('runtime_launcher_session_id', '') or '-'} "
        f"pathSource={snapshot.get('path_source', '') or '-'} "
        f"routerStatePath={snapshot.get('router_state_path', '') or '-'} "
        f"runtimeMapPath={snapshot.get('runtime_map_path', '') or '-'}"
    )
