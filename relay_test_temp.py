from __future__ import annotations

import os
import shutil
import tempfile
import uuid
from pathlib import Path


_WORKSPACE_TEMP_ROOT = Path("_tmp") / "test-temp"
_ORIGINAL_TEMPORARY_DIRECTORY = tempfile.TemporaryDirectory
_TEMPFILE_CONFIGURED = False


class WorkspaceTemporaryDirectory:
    def __init__(
        self,
        suffix: str | None = None,
        prefix: str | None = None,
        dir: str | os.PathLike[str] | None = None,
        ignore_cleanup_errors: bool = False,
    ) -> None:
        root = Path(dir) if dir is not None else _WORKSPACE_TEMP_ROOT
        root.mkdir(parents=True, exist_ok=True)
        prefix_text = prefix if prefix is not None else "tmp"
        suffix_text = suffix if suffix is not None else ""
        while True:
            candidate = root / f"{prefix_text}{uuid.uuid4().hex[:10]}{suffix_text}"
            if candidate.exists():
                continue
            candidate.mkdir(parents=True, exist_ok=False)
            self.name = str(candidate.resolve())
            break
        self._ignore_cleanup_errors = ignore_cleanup_errors

    def __enter__(self) -> str:
        return self.name

    def __exit__(self, exc_type, exc, tb) -> None:
        self.cleanup()
        return None

    def cleanup(self) -> None:
        shutil.rmtree(self.name, ignore_errors=True)


def configure_workspace_tempfile(root: str | os.PathLike[str] | None = None) -> Path:
    global _TEMPFILE_CONFIGURED
    target_root = Path(root) if root is not None else _WORKSPACE_TEMP_ROOT
    target_root.mkdir(parents=True, exist_ok=True)
    resolved_root = target_root.resolve()
    os.environ["TEMP"] = str(resolved_root)
    os.environ["TMP"] = str(resolved_root)
    tempfile.tempdir = str(resolved_root)
    if not _TEMPFILE_CONFIGURED:
        tempfile.TemporaryDirectory = WorkspaceTemporaryDirectory
        _TEMPFILE_CONFIGURED = True
    return resolved_root


def restore_tempfile_configuration() -> None:
    global _TEMPFILE_CONFIGURED
    tempfile.TemporaryDirectory = _ORIGINAL_TEMPORARY_DIRECTORY
    tempfile.tempdir = None
    _TEMPFILE_CONFIGURED = False


def make_workspace_tempdir(name: str, *, root: str | os.PathLike[str] = "_tmp/unit-visible") -> Path:
    target_root = Path(root)
    target_root.mkdir(parents=True, exist_ok=True)
    target = target_root / name
    if target.exists():
        shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True, exist_ok=True)
    return target
