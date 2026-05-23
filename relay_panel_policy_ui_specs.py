from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PolicyActionSpec:
    key: str
    label: str
    group: str = "default"
    read_only: bool = False


def pair_policy_primary_action_specs() -> tuple[PolicyActionSpec, ...]:
    return (
        PolicyActionSpec("reload", "Config에서 다시 읽기"),
        PolicyActionSpec("preview_all", "전체 경로 확인", read_only=True),
        PolicyActionSpec("save", "pair 설정 저장 + 새로고침"),
        PolicyActionSpec("matrix_copy", "pair 경로 상태 복사", read_only=True),
        PolicyActionSpec("matrix_save", "pair 경로 JSON 저장", read_only=True),
    )


def target_autoloop_selection_snapshot_action_specs() -> tuple[PolicyActionSpec, ...]:
    return (
        PolicyActionSpec("snapshot_status", "snapshot 상태", group="share", read_only=True),
        PolicyActionSpec("snapshot_path_copy", "snapshot 경로 복사", group="share", read_only=True),
        PolicyActionSpec("snapshot_summary_copy", "snapshot 요약 복사", group="share", read_only=True),
        PolicyActionSpec("current_json_copy", "현재 selection JSON 복사", group="share", read_only=True),
        PolicyActionSpec("selection_export", "selection JSON 저장", group="share"),
        PolicyActionSpec("selection_import_preview", "selection import 미리보기", group="restore"),
    )


def target_autoloop_danger_action_specs() -> tuple[PolicyActionSpec, ...]:
    return (
        PolicyActionSpec("selected_dirty_save", "selected dirty 저장", group="danger"),
        PolicyActionSpec("selection_import_apply", "selection import 적용", group="danger"),
    )
