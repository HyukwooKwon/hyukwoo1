from __future__ import annotations

import difflib
import json
import shutil
import tempfile
from copy import deepcopy
from datetime import datetime
from pathlib import Path
from typing import Any

from relay_panel_services import ROOT, CommandService


DEFAULT_SLOT_ORDER = [
    "global-prefix",
    "pair-extra",
    "role-extra",
    "target-extra",
    "one-time-prefix",
    "body",
    "one-time-suffix",
    "global-suffix",
]

SCOPED_SLOT_LABELS = {
    "global-prefix": "글로벌 Prefix",
    "pair-extra": "Pair Extra",
    "role-extra": "Role Extra",
    "target-extra": "Target Extra",
    "one-time-prefix": "One-time Prefix",
    "body": "Body",
    "one-time-suffix": "One-time Suffix",
    "global-suffix": "글로벌 Suffix",
}


class MessageConfigService:
    def __init__(self, command_service: CommandService, root: Path | None = None) -> None:
        self.command_service = command_service
        self.root = root or ROOT

    def load_config_document(self, config_path: str) -> dict[str, Any]:
        command = self.command_service.build_script_command(
            "export-config-json.ps1",
            config_path=config_path,
        )
        payload = self.command_service.run_json(command)
        return payload

    def clone_document(self, document: dict[str, Any]) -> dict[str, Any]:
        return deepcopy(document)

    def _pair_test(self, document: dict[str, Any]) -> dict[str, Any]:
        pair_test = document.setdefault("PairTest", {})
        if not isinstance(pair_test, dict):
            raise ValueError("PairTest section is not editable")
        return pair_test

    def _message_templates(self, document: dict[str, Any]) -> dict[str, Any]:
        pair_test = self._pair_test(document)
        templates = pair_test.setdefault("MessageTemplates", {})
        if not isinstance(templates, dict):
            raise ValueError("PairTest.MessageTemplates section is not editable")
        return templates

    def _template_node(self, document: dict[str, Any], template_name: str) -> dict[str, Any]:
        templates = self._message_templates(document)
        node = templates.setdefault(template_name, {})
        if not isinstance(node, dict):
            raise ValueError(f"MessageTemplates.{template_name} section is not editable")
        node.setdefault("PrefixBlocks", [])
        node.setdefault("SuffixBlocks", [])
        node.setdefault("SlotOrder", list(DEFAULT_SLOT_ORDER))
        return node

    def _override_map(self, document: dict[str, Any], scope_kind: str) -> dict[str, Any]:
        pair_test = self._pair_test(document)
        property_name = {
            "pair-extra": "PairOverrides",
            "role-extra": "RoleOverrides",
            "target-extra": "TargetOverrides",
        }.get(scope_kind)
        if not property_name:
            raise ValueError(f"Unsupported override scope: {scope_kind}")
        node = pair_test.setdefault(property_name, {})
        if not isinstance(node, dict):
            raise ValueError(f"{property_name} section is not editable")
        return node

    def pair_ids(self, document: dict[str, Any]) -> list[str]:
        overrides = self._pair_test(document).get("PairOverrides", {}) or {}
        return sorted(str(key) for key in overrides.keys())

    def role_ids(self, document: dict[str, Any]) -> list[str]:
        overrides = self._pair_test(document).get("RoleOverrides", {}) or {}
        return sorted(str(key) for key in overrides.keys())

    def target_ids(self, document: dict[str, Any]) -> list[str]:
        targets = document.get("Targets", []) or []
        target_ids = []
        for item in targets:
            if isinstance(item, dict):
                value = str(item.get("Id", "") or "")
                if value:
                    target_ids.append(value)
        if target_ids:
            return target_ids
        overrides = self._pair_test(document).get("TargetOverrides", {}) or {}
        return sorted(str(key) for key in overrides.keys())

    def target_map(self, document: dict[str, Any]) -> dict[str, dict[str, Any]]:
        result: dict[str, dict[str, Any]] = {}
        for item in document.get("Targets", []) or []:
            if isinstance(item, dict):
                target_id = str(item.get("Id", "") or "")
                if target_id:
                    result[target_id] = item
        return result

    def get_slot_order(self, document: dict[str, Any], template_name: str) -> list[str]:
        node = self._template_node(document, template_name)
        requested = [str(item) for item in node.get("SlotOrder", []) or [] if str(item)]
        ordered: list[str] = []
        seen: set[str] = set()
        for slot in requested + list(DEFAULT_SLOT_ORDER):
            if slot in seen:
                continue
            seen.add(slot)
            ordered.append(slot)
        return ordered

    def set_slot_order(self, document: dict[str, Any], template_name: str, slot_order: list[str]) -> None:
        node = self._template_node(document, template_name)
        normalized: list[str] = []
        seen: set[str] = set()
        for slot in slot_order:
            name = str(slot or "").strip()
            if not name or name in seen:
                continue
            seen.add(name)
            normalized.append(name)
        for slot in DEFAULT_SLOT_ORDER:
            if slot not in seen:
                normalized.append(slot)
        node["SlotOrder"] = normalized

    def get_blocks(self, document: dict[str, Any], scope_kind: str, scope_id: str, template_name: str) -> list[str]:
        if scope_kind == "global-prefix":
            return list(self._template_node(document, template_name).get("PrefixBlocks", []) or [])
        if scope_kind == "global-suffix":
            return list(self._template_node(document, template_name).get("SuffixBlocks", []) or [])

        override_map = self._override_map(document, scope_kind)
        if not scope_id:
            return []
        node = override_map.setdefault(scope_id, {})
        if not isinstance(node, dict):
            raise ValueError(f"{scope_kind}:{scope_id} is not editable")
        property_name = f"{template_name}ExtraBlocks"
        blocks = node.setdefault(property_name, [])
        if not isinstance(blocks, list):
            raise ValueError(f"{scope_kind}:{scope_id}:{property_name} is not editable")
        return list(blocks)

    def set_blocks(self, document: dict[str, Any], scope_kind: str, scope_id: str, template_name: str, blocks: list[str]) -> None:
        normalized = [str(item).strip() for item in blocks if str(item).strip()]
        if scope_kind == "global-prefix":
            self._template_node(document, template_name)["PrefixBlocks"] = normalized
            return
        if scope_kind == "global-suffix":
            self._template_node(document, template_name)["SuffixBlocks"] = normalized
            return

        override_map = self._override_map(document, scope_kind)
        if not scope_id:
            raise ValueError("scope_id is required for override edits")
        node = override_map.setdefault(scope_id, {})
        if not isinstance(node, dict):
            raise ValueError(f"{scope_kind}:{scope_id} is not editable")
        node[f"{template_name}ExtraBlocks"] = normalized

    def get_default_fixed_suffix(self, document: dict[str, Any]) -> str:
        return str(document.get("DefaultFixedSuffix", "") or "")

    def set_default_fixed_suffix(self, document: dict[str, Any], value: str) -> None:
        document["DefaultFixedSuffix"] = value.strip() or None

    def get_target_fixed_suffix(self, document: dict[str, Any], target_id: str) -> str:
        target = self.target_map(document).get(target_id, {})
        return str(target.get("FixedSuffix", "") or "")

    def set_target_fixed_suffix(self, document: dict[str, Any], target_id: str, value: str) -> None:
        target = self.target_map(document).get(target_id)
        if target is None:
            raise ValueError(f"Unknown target: {target_id}")
        stripped = value.strip()
        target["FixedSuffix"] = stripped or None

    def snapshot(self, document: dict[str, Any]) -> dict[str, Any]:
        pair_test = self._pair_test(document)
        targets = self.target_map(document)
        return {
            "DefaultFixedSuffix": self.get_default_fixed_suffix(document),
            "MessageTemplates": {
                "Initial": {
                    "SlotOrder": self.get_slot_order(document, "Initial"),
                    "PrefixBlocks": list(self._template_node(document, "Initial").get("PrefixBlocks", []) or []),
                    "SuffixBlocks": list(self._template_node(document, "Initial").get("SuffixBlocks", []) or []),
                },
                "Handoff": {
                    "SlotOrder": self.get_slot_order(document, "Handoff"),
                    "PrefixBlocks": list(self._template_node(document, "Handoff").get("PrefixBlocks", []) or []),
                    "SuffixBlocks": list(self._template_node(document, "Handoff").get("SuffixBlocks", []) or []),
                },
            },
            "PairOverrides": deepcopy(pair_test.get("PairOverrides", {}) or {}),
            "RoleOverrides": deepcopy(pair_test.get("RoleOverrides", {}) or {}),
            "TargetOverrides": deepcopy(pair_test.get("TargetOverrides", {}) or {}),
            "TargetFixedSuffixes": {
                target_id: str(node.get("FixedSuffix", "") or "")
                for target_id, node in targets.items()
            },
        }

    def snapshot_text(self, document: dict[str, Any]) -> str:
        return json.dumps(self.snapshot(document), ensure_ascii=False, indent=2)

    def diff_summary(self, original_document: dict[str, Any], edited_document: dict[str, Any]) -> dict[str, int]:
        summary = {
            "slot_order_changes": 0,
            "block_scope_changes": 0,
            "added_blocks": 0,
            "removed_blocks": 0,
            "updated_blocks": 0,
            "fixed_suffix_changes": 0,
        }

        for template_name in ("Initial", "Handoff"):
            if self.get_slot_order(original_document, template_name) != self.get_slot_order(edited_document, template_name):
                summary["slot_order_changes"] += 1

            for scope_kind, scope_id in self._all_scope_keys(original_document, edited_document):
                original_blocks = self.get_blocks(original_document, scope_kind, scope_id, template_name)
                edited_blocks = self.get_blocks(edited_document, scope_kind, scope_id, template_name)
                if original_blocks == edited_blocks:
                    continue
                summary["block_scope_changes"] += 1
                summary["added_blocks"] += max(0, len(edited_blocks) - len(original_blocks))
                summary["removed_blocks"] += max(0, len(original_blocks) - len(edited_blocks))
                shared_length = min(len(original_blocks), len(edited_blocks))
                summary["updated_blocks"] += sum(
                    1 for index in range(shared_length) if original_blocks[index] != edited_blocks[index]
                )

        if self.get_default_fixed_suffix(original_document) != self.get_default_fixed_suffix(edited_document):
            summary["fixed_suffix_changes"] += 1

        all_target_ids = sorted(
            set(self.target_ids(original_document)) | set(self.target_ids(edited_document))
        )
        for target_id in all_target_ids:
            if self.get_target_fixed_suffix(original_document, target_id) != self.get_target_fixed_suffix(edited_document, target_id):
                summary["fixed_suffix_changes"] += 1

        return summary

    def diff_text(self, original_document: dict[str, Any], edited_document: dict[str, Any]) -> str:
        original_lines = self.snapshot_text(original_document).splitlines()
        edited_lines = self.snapshot_text(edited_document).splitlines()
        diff_lines = list(
            difflib.unified_diff(
                original_lines,
                edited_lines,
                fromfile="before",
                tofile="after",
                lineterm="",
            )
        )
        return "\n".join(diff_lines) if diff_lines else "(변경 없음)"

    def collect_change_entries(self, original_document: dict[str, Any], edited_document: dict[str, Any]) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []

        for template_name in ("Initial", "Handoff"):
            original_slot_order = self.get_slot_order(original_document, template_name)
            edited_slot_order = self.get_slot_order(edited_document, template_name)
            if original_slot_order != edited_slot_order:
                entries.append(
                    {
                        "template_name": template_name,
                        "change_type": "slot_order",
                        "scope_kind": "slot-order",
                        "scope_id": template_name,
                        "label": f"{template_name} SlotOrder",
                        "before_count": len(original_slot_order),
                        "after_count": len(edited_slot_order),
                    }
                )

            for scope_kind, scope_id in self._all_scope_keys(original_document, edited_document):
                original_blocks = self.get_blocks(original_document, scope_kind, scope_id, template_name)
                edited_blocks = self.get_blocks(edited_document, scope_kind, scope_id, template_name)
                if original_blocks == edited_blocks:
                    continue
                entries.append(
                    {
                        "template_name": template_name,
                        "change_type": "blocks",
                        "scope_kind": scope_kind,
                        "scope_id": scope_id,
                        "label": "{0} / {1}".format(template_name, self.describe_scope(scope_kind, scope_id)),
                        "before_count": len(original_blocks),
                        "after_count": len(edited_blocks),
                    }
                )

        if self.get_default_fixed_suffix(original_document) != self.get_default_fixed_suffix(edited_document):
            entries.append(
                {
                    "template_name": "",
                    "change_type": "default_fixed_suffix",
                    "scope_kind": "default-fixed-suffix",
                    "scope_id": "",
                    "label": "기본 고정문구",
                    "before_count": 1 if self.get_default_fixed_suffix(original_document) else 0,
                    "after_count": 1 if self.get_default_fixed_suffix(edited_document) else 0,
                }
            )

        all_target_ids = sorted(set(self.target_ids(original_document)) | set(self.target_ids(edited_document)))
        for target_id in all_target_ids:
            if self.get_target_fixed_suffix(original_document, target_id) == self.get_target_fixed_suffix(edited_document, target_id):
                continue
            entries.append(
                {
                    "template_name": "",
                    "change_type": "target_fixed_suffix",
                    "scope_kind": "target-fixed-suffix",
                    "scope_id": target_id,
                    "label": f"Target 고정문구:{target_id}",
                    "before_count": 1 if self.get_target_fixed_suffix(original_document, target_id) else 0,
                    "after_count": 1 if self.get_target_fixed_suffix(edited_document, target_id) else 0,
                }
            )

        return entries

    def validate_document(
        self,
        document: dict[str, Any],
        *,
        template_name: str = "",
        scope_kind: str = "",
        scope_id: str = "",
    ) -> list[dict[str, str]]:
        issues: list[dict[str, str]] = []
        template_names = [template_name] if template_name else ["Initial", "Handoff"]

        if scope_kind in {"pair-extra", "role-extra", "target-extra"} and not scope_id:
            issues.append(
                {
                    "severity": "error",
                    "code": "scope_id_required",
                    "message": f"{scope_kind} 블록은 대상 ID가 필요합니다.",
                }
            )

        for current_template in template_names:
            slot_order = self.get_slot_order(document, current_template)
            if "body" not in slot_order:
                issues.append(
                    {
                        "severity": "error",
                        "code": "slot_order_missing_body",
                        "message": f"{current_template} SlotOrder에 body가 없습니다.",
                    }
                )
            if len(slot_order) != len(set(slot_order)):
                issues.append(
                    {
                        "severity": "error",
                        "code": "slot_order_duplicate",
                        "message": f"{current_template} SlotOrder에 중복 slot이 있습니다.",
                    }
                )

            for current_scope_kind, current_scope_id in self._validation_scope_keys(
                document,
                scope_kind=scope_kind,
                scope_id=scope_id,
            ):
                blocks = self.get_blocks(document, current_scope_kind, current_scope_id, current_template)
                scope_label = self.describe_scope(current_scope_kind, current_scope_id)
                if not blocks and current_scope_kind in {"global-prefix", "global-suffix"}:
                    issues.append(
                        {
                            "severity": "info",
                            "code": "scope_empty",
                            "message": f"{current_template} / {scope_label} 블록이 비어 있습니다.",
                        }
                    )
                normalized = [block.strip() for block in blocks if block.strip()]
                if len(normalized) != len(set(normalized)):
                    issues.append(
                        {
                            "severity": "warning",
                            "code": "duplicate_blocks",
                            "message": f"{current_template} / {scope_label} 에 중복 블록이 있습니다.",
                        }
                    )
                for index, block in enumerate(blocks, start=1):
                    length = len(str(block))
                    if length > 2000:
                        issues.append(
                            {
                                "severity": "warning",
                                "code": "block_too_long",
                                "message": f"{current_template} / {scope_label} #{index} 블록 길이가 {length}자로 깁니다.",
                            }
                        )

        default_fixed = self.get_default_fixed_suffix(document)
        if len(default_fixed) > 2000:
            issues.append(
                {
                    "severity": "warning",
                    "code": "default_fixed_suffix_too_long",
                    "message": f"기본 고정문구 길이가 {len(default_fixed)}자로 깁니다.",
                }
            )

        for target_id in self.target_ids(document):
            target_fixed = self.get_target_fixed_suffix(document, target_id)
            if len(target_fixed) > 2000:
                issues.append(
                    {
                        "severity": "warning",
                        "code": "target_fixed_suffix_too_long",
                        "message": f"{target_id} 고정문구 길이가 {len(target_fixed)}자로 깁니다.",
                    }
                )

        return issues

    def describe_scope(self, scope_kind: str, scope_id: str = "") -> str:
        if scope_kind in {"global-prefix", "global-suffix"}:
            return SCOPED_SLOT_LABELS.get(scope_kind, scope_kind)
        return "{0}:{1}".format(SCOPED_SLOT_LABELS.get(scope_kind, scope_kind), scope_id or "(none)")

    def clone_block(self, document: dict[str, Any], scope_kind: str, scope_id: str, template_name: str, index: int) -> list[str]:
        blocks = self.get_blocks(document, scope_kind, scope_id, template_name)
        if index < 0 or index >= len(blocks):
            raise IndexError("block index out of range")
        clone_value = str(blocks[index])
        blocks.insert(index + 1, clone_value)
        self.set_blocks(document, scope_kind, scope_id, template_name, blocks)
        return blocks

    def revert_block(
        self,
        edited_document: dict[str, Any],
        original_document: dict[str, Any],
        scope_kind: str,
        scope_id: str,
        template_name: str,
        index: int,
    ) -> list[str]:
        edited_blocks = self.get_blocks(edited_document, scope_kind, scope_id, template_name)
        original_blocks = self.get_blocks(original_document, scope_kind, scope_id, template_name)
        if index < 0 or index >= len(edited_blocks):
            raise IndexError("block index out of range")
        if index < len(original_blocks):
            edited_blocks[index] = original_blocks[index]
        else:
            del edited_blocks[index]
        self.set_blocks(edited_document, scope_kind, scope_id, template_name, edited_blocks)
        return edited_blocks

    def _all_scope_keys(self, *documents: dict[str, Any]) -> list[tuple[str, str]]:
        keys: set[tuple[str, str]] = {("global-prefix", ""), ("global-suffix", "")}
        for document in documents:
            if not document:
                continue
            for pair_id in self.pair_ids(document):
                keys.add(("pair-extra", pair_id))
            for role_id in self.role_ids(document):
                keys.add(("role-extra", role_id))
            for target_id in self.target_ids(document):
                keys.add(("target-extra", target_id))
        return sorted(keys)

    def _validation_scope_keys(
        self,
        document: dict[str, Any],
        *,
        scope_kind: str = "",
        scope_id: str = "",
    ) -> list[tuple[str, str]]:
        if not scope_kind:
            return self._all_scope_keys(document)
        if scope_kind in {"global-prefix", "global-suffix"}:
            return [(scope_kind, "")]
        if scope_kind == "pair-extra":
            return [(scope_kind, scope_id)] if scope_id else [(scope_kind, pair_id) for pair_id in self.pair_ids(document)]
        if scope_kind == "role-extra":
            return [(scope_kind, scope_id)] if scope_id else [(scope_kind, role_id) for role_id in self.role_ids(document)]
        if scope_kind == "target-extra":
            return [(scope_kind, scope_id)] if scope_id else [(scope_kind, target_id) for target_id in self.target_ids(document)]
        return []

    def backup_dir(self, config_path: str) -> Path:
        config_file = Path(config_path)
        return self.root / "runtime" / "config-editor-backups" / config_file.stem

    def list_backups(self, config_path: str) -> list[Path]:
        return sorted(self.backup_dir(config_path).glob("*.psd1"), key=lambda path: path.stat().st_mtime, reverse=True)

    def _write_backup(self, config_path: str, *, suffix: str) -> Path:
        backup_root = self.backup_dir(config_path)
        backup_root.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_path = backup_root / f"{Path(config_path).stem}.{stamp}.{suffix}.psd1"
        shutil.copy2(config_path, backup_path)
        return backup_path

    def save_document(self, config_path: str, document: dict[str, Any]) -> Path:
        backup_path = self._write_backup(config_path, suffix="pre-save")
        serialized = self.serialize_psd1(document).replace("\n", "\r\n")
        Path(config_path).write_text(serialized, encoding="utf-8")
        return backup_path

    def rollback_last_backup(self, config_path: str) -> Path:
        backups = self.list_backups(config_path)
        if not backups:
            raise FileNotFoundError("rollback backup not found")
        self._write_backup(config_path, suffix="pre-rollback")
        shutil.copy2(backups[0], config_path)
        return backups[0]

    def render_effective_preview(
        self,
        document: dict[str, Any],
        *,
        config_path: str,
        run_root: str = "",
        pair_id: str = "",
        target_id: str = "",
        mode: str = "both",
    ) -> dict[str, Any]:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_config_path = Path(temp_dir) / Path(config_path).name
            serialized = self.serialize_psd1(document).replace("\n", "\r\n")
            temp_config_path.write_text(serialized, encoding="utf-8")
            command = self.command_service.build_script_command(
                "show-effective-config.ps1",
                config_path=str(temp_config_path),
                run_root=run_root,
                pair_id=pair_id,
                target_id=target_id,
                extra=["-Mode", mode, "-AsJson"],
            )
            return self.command_service.run_json(command)

    def serialize_psd1(self, document: dict[str, Any]) -> str:
        return self._serialize_value(document, indent=0)

    def _serialize_key(self, key: str) -> str:
        return key if key.replace("_", "").isalnum() else self._serialize_scalar(str(key))

    def _serialize_scalar(self, value: str) -> str:
        return "'" + value.replace("'", "''") + "'"

    def _serialize_value(self, value: Any, *, indent: int) -> str:
        prefix = " " * indent
        if value is None:
            return prefix + "$null"
        if isinstance(value, bool):
            return prefix + ("$true" if value else "$false")
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return prefix + format(value, "g")
        if isinstance(value, str):
            return prefix + self._serialize_scalar(value)
        if isinstance(value, list):
            if not value:
                return prefix + "@()"
            lines = [prefix + "@("]
            for item in value:
                lines.extend(self._serialize_value(item, indent=indent + 4).splitlines())
            lines.append(prefix + ")")
            return "\n".join(lines)
        if isinstance(value, dict):
            lines = [prefix + "@{"]
            for key, item in value.items():
                rendered = self._serialize_value(item, indent=indent + 4).splitlines()
                first_line = rendered[0].lstrip() if rendered else "$null"
                lines.append(f"{' ' * (indent + 4)}{self._serialize_key(str(key))} = {first_line}")
                if len(rendered) > 1:
                    lines.extend(rendered[1:])
            lines.append(prefix + "}")
            return "\n".join(lines)
        return prefix + self._serialize_scalar(str(value))
