from __future__ import annotations

import ctypes
import json
import os
import re
import time
from pathlib import Path


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


def target_autoloop_manifest_targets(manifest_payload: dict[str, object]) -> list[object]:
    targets = manifest_payload.get("Targets", []) if isinstance(manifest_payload, dict) else []
    return targets if isinstance(targets, list) else []


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


def single_quoted_psd1_value(raw_text: str, key: str) -> str:
    return psd1_string_value(raw_text, key)


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
) -> dict[str, object]:
    root_text = str(retry_pending_root or "").strip()
    allowed_targets = {
        str(target_id or "").strip()
        for target_id in (target_ids or [])
        if str(target_id or "").strip()
    }
    items: list[dict[str, object]] = []
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
            try:
                last_write_time = ready_path.stat().st_mtime
            except OSError:
                last_write_time = 0.0
            items.append(
                {
                    "target_id": target_id,
                    "path": str(ready_path),
                    "last_write_time": last_write_time,
                    "failure_category": str(metadata.get("FailureCategory", "") or "").strip(),
                    "failure_message": str(metadata.get("FailureMessage", "") or "").strip(),
                    "debug_log_path": str(metadata.get("DebugLogPath", "") or "").strip(),
                }
            )
    target_id_values: list[str] = []
    for item in items:
        target_id = str(item.get("target_id", "") or "").strip()
        if target_id and target_id not in target_id_values:
            target_id_values.append(target_id)
    latest = max(items, key=lambda item: float(item.get("last_write_time", 0.0) or 0.0), default={})
    return {
        "root": root_text,
        "count": len(items),
        "target_ids": target_id_values,
        "latest_path": str(latest.get("path", "") or ""),
        "latest_target_id": str(latest.get("target_id", "") or ""),
        "latest_failure_category": str(latest.get("failure_category", "") or ""),
        "latest_failure_message": str(latest.get("failure_message", "") or ""),
        "latest_debug_log_path": str(latest.get("debug_log_path", "") or ""),
        "items": items,
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


def target_autoloop_router_session_snapshot(session_paths: dict[str, str]) -> dict[str, object]:
    runtime_map_path = str(session_paths.get("runtime_map_path", "") or "").strip()
    router_state_path = str(session_paths.get("router_state_path", "") or "").strip()
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
        "path_source": str(session_paths.get("source", "") or ""),
        "config_path": str(session_paths.get("config_path", "") or ""),
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
