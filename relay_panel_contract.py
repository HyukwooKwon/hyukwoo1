from __future__ import annotations

import json
from datetime import datetime
from functools import lru_cache
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
WATCHER_CONTRACT_FIELDS_PATH = ROOT / "docs" / "WATCHER-CONTRACT-FIELDS.json"


@lru_cache(maxsize=1)
def load_watcher_contract_fields() -> dict[str, Any]:
    try:
        raw = WATCHER_CONTRACT_FIELDS_PATH.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise RuntimeError(f"watcher contract fields file not found: {WATCHER_CONTRACT_FIELDS_PATH}") from exc
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"watcher contract fields file is invalid JSON: {WATCHER_CONTRACT_FIELDS_PATH}") from exc
    return payload


def _tuple_field(name: str) -> tuple[str, ...]:
    value = load_watcher_contract_fields().get(name, [])
    return tuple(str(item) for item in value)


def _is_iso_timestamp(value: object) -> bool:
    if not isinstance(value, str):
        return False
    candidate = value.strip()
    if not candidate:
        return False
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        datetime.fromisoformat(candidate)
    except ValueError:
        return False
    return True


def get_watcher_bridge_contract_errors(payload: dict[str, Any] | None) -> list[str]:
    watcher = ((payload or {}).get("Watcher", {}) or {})
    if not isinstance(watcher, dict):
        return ["watcher bridge object missing"]

    errors: list[str] = []
    missing_fields = [field for field in WATCHER_BRIDGE_REQUIRED_FIELDS if field not in watcher]
    if missing_fields:
        errors.append("watcher bridge missing fields: {0}".format(", ".join(missing_fields)))

    invalid_iso_fields = [
        field
        for field in WATCHER_BRIDGE_ISO_TIMESTAMP_FIELDS
        if watcher.get(field) not in (None, "") and not _is_iso_timestamp(watcher.get(field))
    ]
    if invalid_iso_fields:
        errors.append("watcher bridge invalid ISO timestamps: {0}".format(", ".join(invalid_iso_fields)))

    return errors


WATCHER_BRIDGE_REQUIRED_FIELDS = _tuple_field("WatcherBridgeRequiredFields")
WATCHER_BRIDGE_ISO_TIMESTAMP_FIELDS = _tuple_field("WatcherBridgeIsoTimestampFields")
WATCHER_BRIDGE_DERIVED_FIELDS = _tuple_field("WatcherBridgeDerivedFields")
WATCHER_AUDIT_REQUIRED_FIELDS = _tuple_field("WatcherAuditRequiredFields")
WATCHER_AUDIT_POLICY = dict(load_watcher_contract_fields().get("WatcherAuditPolicy", {}))
WATCHER_AUDIT_MAX_BYTES = int(WATCHER_AUDIT_POLICY.get("MaxBytes", 524288))
WATCHER_AUDIT_MAX_ARCHIVES = int(WATCHER_AUDIT_POLICY.get("MaxArchives", 5))
WATCHER_AUDIT_RETENTION_DAYS = int(WATCHER_AUDIT_POLICY.get("RetentionDays", 14))
