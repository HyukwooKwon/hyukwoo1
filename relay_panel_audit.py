from __future__ import annotations

import json
import hashlib
import os
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from relay_panel_contract import (
    WATCHER_AUDIT_MAX_ARCHIVES,
    WATCHER_AUDIT_MAX_BYTES,
    WATCHER_AUDIT_REQUIRED_FIELDS,
    WATCHER_AUDIT_RETENTION_DAYS,
)

ROOT = Path(__file__).resolve().parent
WATCHER_AUDIT_LOCK_TIMEOUT_SEC = 2.0
WATCHER_AUDIT_LOCK_RETRY_SEC = 0.05
WATCHER_AUDIT_LOCK_STALE_AFTER_SEC = 10.0


class WatcherAuditLogger:
    def __init__(self, root: Path | None = None) -> None:
        self.root = root or ROOT
        self.log_dir = self.root / "logs"
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.log_path = self.log_dir / "watcher-control-audit.jsonl"
        self.lock_path = self.log_dir / "watcher-control-audit.lock"
        self.fallback_path = self.log_dir / "watcher-control-audit-fallback.log"
        self.log_path.touch(exist_ok=True)
        self.max_bytes = WATCHER_AUDIT_MAX_BYTES
        self.max_archives = WATCHER_AUDIT_MAX_ARCHIVES
        self.retention_days = WATCHER_AUDIT_RETENTION_DAYS
        self.lock_timeout_sec = WATCHER_AUDIT_LOCK_TIMEOUT_SEC
        self.lock_retry_sec = WATCHER_AUDIT_LOCK_RETRY_SEC
        self.lock_stale_after_sec = WATCHER_AUDIT_LOCK_STALE_AFTER_SEC

    def _run_root_hash(self, run_root: str) -> str:
        if not run_root:
            return ""
        return hashlib.sha256(run_root.encode("utf-8")).hexdigest()[:16]

    def _archive_candidates(self) -> list[Path]:
        return sorted(
            self.log_dir.glob("watcher-control-audit.*.jsonl"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )

    def _rotate_if_needed(self) -> None:
        try:
            current_size = self.log_path.stat().st_size
        except FileNotFoundError:
            self.log_path.touch(exist_ok=True)
            return
        if current_size < self.max_bytes:
            return
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        archive_path = self.log_dir / f"watcher-control-audit.{stamp}.jsonl"
        counter = 1
        while archive_path.exists():
            archive_path = self.log_dir / f"watcher-control-audit.{stamp}_{counter}.jsonl"
            counter += 1
        self.log_path.replace(archive_path)
        self.log_path.touch(exist_ok=True)
        self._prune_archives()

    def _prune_archives(self) -> None:
        archives = self._archive_candidates()
        now = datetime.now().timestamp()
        for archive in archives[self.max_archives :]:
            archive.unlink(missing_ok=True)
        for archive in self._archive_candidates():
            age_days = (now - archive.stat().st_mtime) / 86400.0
            if age_days > self.retention_days:
                archive.unlink(missing_ok=True)

    def _lock_is_stale(self) -> bool:
        try:
            age_seconds = time.time() - self.lock_path.stat().st_mtime
        except FileNotFoundError:
            return False
        return age_seconds >= self.lock_stale_after_sec

    def _acquire_lock(self) -> int:
        deadline = time.monotonic() + self.lock_timeout_sec
        while True:
            try:
                fd = os.open(str(self.lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                payload = {
                    "Pid": os.getpid(),
                    "CreatedAt": datetime.now().isoformat(timespec="seconds"),
                }
                os.write(fd, json.dumps(payload, ensure_ascii=False).encode("utf-8"))
                return fd
            except FileExistsError:
                if self._lock_is_stale():
                    self.lock_path.unlink(missing_ok=True)
                    continue
                if time.monotonic() >= deadline:
                    raise TimeoutError("watcher audit lock acquisition timed out")
                time.sleep(self.lock_retry_sec)

    def _release_lock(self, fd: int | None) -> None:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
            self.lock_path.unlink(missing_ok=True)

    def _write_fallback(self, payload: dict[str, Any], error: Exception) -> None:
        failure = {
            "Timestamp": datetime.now().isoformat(timespec="seconds"),
            "Error": str(error),
            "Payload": payload,
        }
        try:
            with self.fallback_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(failure, ensure_ascii=False) + "\n")
        except Exception:
            print(json.dumps(failure, ensure_ascii=False), file=sys.stderr)

    def record(
        self,
        *,
        action: str,
        run_root: str,
        requested_by: str,
        ok: bool,
        state: str,
        message: str,
        request_id: str = "",
        reason_codes: list[str] | None = None,
        warning_codes: list[str] | None = None,
        extra: dict[str, Any] | None = None,
    ) -> Path:
        self._rotate_if_needed()
        self._prune_archives()
        payload: dict[str, Any] = {
            "ActionId": str(uuid.uuid4()),
            "Timestamp": datetime.now().isoformat(timespec="seconds"),
            "Action": action,
            "RunRoot": run_root,
            "RunRootHash": self._run_root_hash(run_root),
            "RequestedBy": requested_by,
            "Ok": bool(ok),
            "State": state,
            "Message": message,
            "RequestId": request_id,
            "ReasonCodes": list(reason_codes or []),
            "WarningCodes": list(warning_codes or []),
        }
        if extra:
            payload["Extra"] = extra
        lock_fd: int | None = None
        try:
            lock_fd = self._acquire_lock()
            self._rotate_if_needed()
            self._prune_archives()
            with self.log_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
        except Exception as exc:
            self._write_fallback(payload, exc)
        finally:
            self._release_lock(lock_fd)
        return self.log_path
