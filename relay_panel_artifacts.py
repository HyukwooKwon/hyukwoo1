from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path


@dataclass(frozen=True)
class ArtifactQuery:
    run_root: str
    pair_id: str = ""
    target_id: str = ""
    latest_only: bool = False
    include_missing: bool = True


@dataclass(frozen=True)
class ArtifactFileRef:
    path: str
    exists: bool
    modified_at: str
    size_bytes: int | None
    kind: str
    name: str


@dataclass
class TargetArtifactState:
    pair_id: str
    role_name: str
    target_id: str
    partner_target_id: str
    latest_state: str
    summary_present: bool
    done_present: bool
    error_present: bool
    zip_count: int
    failure_count: int
    target_folder: str
    review_folder: str
    latest_modified_at: str
    blocker_reason: str = ""
    recommended_action: str = ""
    source_outbox_state: str = ""
    source_outbox_reason: str = ""
    source_outbox_contract_latest_state: str = ""
    source_outbox_next_action: str = ""
    dispatch_state: str = ""
    dispatch_updated_at: str = ""
    seed_send_state: str = ""
    submit_state: str = ""
    submit_reason: str = ""
    seed_attempt_count: int = 0
    seed_max_attempts: int = 0
    seed_next_retry_at: str = ""
    seed_retry_reason: str = ""
    manual_attention_required: bool = False
    notes: list[str] = field(default_factory=list)
    summary_file: ArtifactFileRef | None = None
    latest_review_zip: ArtifactFileRef | None = None
    request_file: ArtifactFileRef | None = None
    done_file: ArtifactFileRef | None = None
    error_file: ArtifactFileRef | None = None
    result_file: ArtifactFileRef | None = None


@dataclass
class PairArtifactSummary:
    pair_id: str
    target_count: int
    zip_present_count: int
    error_present_count: int
    ready_to_forward_count: int
    forwarded_count: int
    stale_or_missing_count: int
    latest_modified_at: str


@dataclass
class ArtifactPreviewModel:
    title: str
    summary_text: str
    latest_state: str
    state_label: str
    blocker_reason: str
    recommended_action: str
    latest_zip_name: str
    latest_zip_path: str
    request_path: str
    done_path: str
    error_path: str
    result_path: str
    target_folder: str
    review_folder: str
    source_outbox_contract_latest_state: str
    source_outbox_next_action: str
    dispatch_state: str
    dispatch_updated_at: str
    notes: list[str]


class ArtifactService:
    PROBLEM_STATES = {"summary-missing", "summary-stale", "done-stale", "no-zip", "error-present"}
    STATE_REASON_ACTION_MAP = {
        "error-present": ("error marker가 존재합니다.", "error 파일 확인"),
        "summary-missing": ("summary 파일이 최신 zip 기준으로 없습니다.", "summary 갱신 확인"),
        "summary-stale": ("summary.txt가 최신 zip보다 오래됐습니다.", "summary 갱신 확인"),
        "done-stale": ("done.json 완료 시각이 최신 zip보다 오래됐습니다.", "headless 완료 시각 확인"),
        "ready-to-forward": ("최신 zip이 다음 전달 가능 상태입니다.", "전달 가능 target 확인"),
        "forwarded": ("최신 zip은 이미 전달 완료 상태입니다.", "전달 반영 확인"),
        "no-zip": ("review zip이 아직 없습니다.", "review zip 생성 대기"),
        "done-present": ("done marker만 있고 전달 준비는 미확정입니다.", "done.json / Pair 상태 확인"),
        "artifacts-only": ("paired status 없이 산출물만 확인했습니다.", "Pair 상태 새로고침"),
    }
    STATE_DISPLAY_MAP = {
        "error-present": "error 존재",
        "summary-missing": "summary 없음",
        "summary-stale": "summary 갱신 필요",
        "done-stale": "done 갱신 필요",
        "ready-to-forward": "다음 전달 가능",
        "forwarded": "전달 완료",
        "no-zip": "zip 없음",
        "done-present": "done만 존재",
        "artifacts-only": "산출물만 확인",
    }
    NEXT_ACTION_DISPLAY_MAP = {
        "handoff-ready": "다음 전달 가능",
        "duplicate-skipped": "중복 생략",
    }
    DISPATCH_DISPLAY_MAP = {
        "running": "후속 실행 중",
        "failed": "후속 실행 실패",
        "completed": "후속 실행 완료",
    }
    PATH_KIND_MAP = {
        "summary": "summary_file",
        "review_zip": "latest_review_zip",
        "request": "request_file",
        "done": "done_file",
        "error": "error_file",
        "result": "result_file",
        "target_folder": "target_folder",
        "review_folder": "review_folder",
    }

    def compute_target_artifact_states(
        self,
        effective_config: dict | None,
        paired_status: dict | None,
    ) -> list[TargetArtifactState]:
        effective_index = self._index_effective_rows(effective_config)
        paired_index = self._index_paired_targets(paired_status)
        target_ids = sorted(set(effective_index.keys()) | set(paired_index.keys()))
        pair_test = (paired_status or {}).get("PairTest", {}) or {}

        states: list[TargetArtifactState] = []
        for target_id in target_ids:
            effective_row = effective_index.get(target_id)
            paired_row = paired_index.get(target_id)
            state = self._merge_target_row(effective_row, paired_row, pair_test)
            states.append(state)

        return sorted(
            states,
            key=lambda item: (item.latest_modified_at or "", item.pair_id, item.target_id),
            reverse=True,
        )

    def filter_target_artifact_states(
        self,
        states: list[TargetArtifactState],
        query: ArtifactQuery,
    ) -> list[TargetArtifactState]:
        filtered: list[TargetArtifactState] = []
        for state in states:
            if query.run_root and not self._matches_run_root(state, query.run_root):
                continue
            if query.pair_id and state.pair_id != query.pair_id:
                continue
            if query.target_id and state.target_id != query.target_id:
                continue
            if query.latest_only and not self._has_material_artifact(state):
                continue
            if not query.include_missing and state.latest_state in self.PROBLEM_STATES:
                continue
            filtered.append(state)
        return filtered

    def build_target_artifact_states(
        self,
        effective_config: dict | None,
        paired_status: dict | None,
        query: ArtifactQuery,
    ) -> list[TargetArtifactState]:
        return self.filter_target_artifact_states(
            self.compute_target_artifact_states(effective_config, paired_status),
            query,
        )

    def build_pair_summaries(self, target_states: list[TargetArtifactState]) -> list[PairArtifactSummary]:
        pair_map: dict[str, list[TargetArtifactState]] = {}
        for state in target_states:
            pair_map.setdefault(state.pair_id, []).append(state)

        summaries: list[PairArtifactSummary] = []
        for pair_id, states in sorted(pair_map.items()):
            summaries.append(
                PairArtifactSummary(
                    pair_id=pair_id,
                    target_count=len(states),
                    zip_present_count=sum(1 for item in states if item.zip_count > 0),
                    error_present_count=sum(1 for item in states if item.error_present),
                    ready_to_forward_count=sum(1 for item in states if self.is_handoff_ready(item)),
                    forwarded_count=sum(1 for item in states if item.latest_state == "forwarded"),
                    stale_or_missing_count=sum(1 for item in states if item.latest_state in self.PROBLEM_STATES),
                    latest_modified_at=max((item.latest_modified_at for item in states), default=""),
                )
            )
        return summaries

    def get_preview_model(
        self,
        target_states: list[TargetArtifactState],
        target_id: str,
    ) -> ArtifactPreviewModel | None:
        state = next((item for item in target_states if item.target_id == target_id), None)
        if state is None:
            return None

        summary_path = state.summary_file.path if state.summary_file else ""
        zip_ref = state.latest_review_zip
        return ArtifactPreviewModel(
            title="{0} / {1} ({2})".format(state.pair_id, state.target_id, state.role_name or "unknown"),
            summary_text=self.read_summary_text(summary_path),
            latest_state=state.latest_state,
            state_label=self.format_target_state_label(state),
            blocker_reason=state.blocker_reason,
            recommended_action=state.recommended_action,
            latest_zip_name=zip_ref.name if zip_ref else "",
            latest_zip_path=zip_ref.path if zip_ref else "",
            request_path=self.resolve_artifact_path(state, "request"),
            done_path=self.resolve_artifact_path(state, "done"),
            error_path=self.resolve_artifact_path(state, "error"),
            result_path=self.resolve_artifact_path(state, "result"),
            target_folder=state.target_folder,
            review_folder=state.review_folder,
            source_outbox_contract_latest_state=state.source_outbox_contract_latest_state,
            source_outbox_next_action=state.source_outbox_next_action,
            dispatch_state=state.dispatch_state,
            dispatch_updated_at=state.dispatch_updated_at,
            notes=list(state.notes),
        )

    def read_summary_text(self, path: str, max_chars: int = 12000) -> str:
        return self._safe_read_text(path, max_chars)

    def resolve_artifact_path(self, state: TargetArtifactState, kind: str) -> str:
        target = self.PATH_KIND_MAP.get(kind, "")
        if not target:
            return ""
        if target in {"target_folder", "review_folder"}:
            return str(getattr(state, target, "") or "")
        file_ref = getattr(state, target, None)
        if file_ref is None:
            return ""
        return file_ref.path

    def open_path(self, path: str) -> None:
        if not path:
            raise FileNotFoundError("경로가 비어 있습니다.")
        if not Path(path).exists():
            raise FileNotFoundError(path)
        os.startfile(path)

    def describe_latest_state(self, latest_state: str) -> tuple[str, str]:
        normalized = str(latest_state or "").strip()
        if not normalized:
            return ("최신 상태를 아직 해석하지 못했습니다.", "Pair 상태 새로고침")
        return self.STATE_REASON_ACTION_MAP.get(
            normalized,
            ("계약 상태 추가 확인이 필요합니다.", "결과 탭 상태 확인"),
        )

    def describe_dispatch_state(self, dispatch_state: str) -> tuple[str, str]:
        normalized = str(dispatch_state or "").strip()
        if normalized == "running":
            return ("후속 headless 실행이 진행 중입니다.", "후속 실행 완료 대기")
        if normalized == "failed":
            return ("후속 headless 실행이 실패했습니다.", "dispatch stderr / error.json 확인")
        if normalized == "completed":
            return ("후속 headless 실행이 완료되었습니다.", "")
        return ("", "")

    def display_latest_state(self, latest_state: str) -> str:
        normalized = str(latest_state or "").strip()
        if not normalized:
            return ""
        return self.STATE_DISPLAY_MAP.get(normalized, normalized)

    def display_next_action(self, next_action: str) -> str:
        normalized = str(next_action or "").strip()
        if not normalized:
            return ""
        return self.NEXT_ACTION_DISPLAY_MAP.get(normalized, normalized)

    def display_dispatch_state(self, dispatch_state: str) -> str:
        normalized = str(dispatch_state or "").strip()
        if not normalized:
            return ""
        return self.DISPATCH_DISPLAY_MAP.get(normalized, normalized)

    def is_handoff_ready(self, state: TargetArtifactState) -> bool:
        next_action = str(state.source_outbox_next_action or "").strip()
        if next_action:
            return next_action == "handoff-ready"
        return str(state.latest_state or "").strip() == "ready-to-forward"

    def format_target_state_label(self, state: TargetArtifactState) -> str:
        parts: list[str] = []
        latest_state = str(state.latest_state or "").strip()
        next_action = str(state.source_outbox_next_action or "").strip()
        dispatch_state = str(state.dispatch_state or "").strip()
        if latest_state:
            parts.append(self.display_latest_state(latest_state))
        if next_action and next_action not in parts:
            next_action_label = self.display_next_action(next_action)
            if next_action_label not in parts:
                parts.append(next_action_label)
        if dispatch_state in {"running", "failed"}:
            parts.append(self.display_dispatch_state(dispatch_state))
        return " / ".join(parts) if parts else "(unknown)"

    def _index_effective_rows(self, effective_config: dict | None) -> dict[str, dict]:
        rows = (effective_config or {}).get("PreviewRows", []) or []
        row_map: dict[str, dict] = {}
        for row in rows:
            target_id = str(row.get("TargetId", "") or "")
            if target_id:
                row_map[target_id] = row
        return row_map

    def _index_paired_targets(self, paired_status: dict | None) -> dict[str, dict]:
        rows = (paired_status or {}).get("Targets", []) or []
        row_map: dict[str, dict] = {}
        for row in rows:
            target_id = str(row.get("TargetId", "") or "")
            if target_id:
                row_map[target_id] = row
        return row_map

    def _merge_target_row(self, effective_row: dict | None, paired_row: dict | None, pair_test: dict) -> TargetArtifactState:
        pair_id = self._coalesce(paired_row, "PairId", effective_row, "PairId")
        role_name = self._coalesce(paired_row, "RoleName", effective_row, "RoleName")
        target_id = self._coalesce(paired_row, "TargetId", effective_row, "TargetId")
        partner_target_id = self._coalesce(paired_row, "PartnerTargetId", effective_row, "PartnerTargetId")
        target_folder = self._coalesce(effective_row, "PairTargetFolder", paired_row, "TargetFolder")
        review_folder = self._coalesce(effective_row, "ReviewFolderPath")
        if not review_folder and target_folder:
            review_folder_name = str(pair_test.get("ReviewFolderName", "") or "reviewfile")
            review_folder = str(Path(target_folder) / review_folder_name)

        summary_path = self._coalesce(effective_row, "SummaryPath")
        request_path = self._coalesce(effective_row, "RequestPath")
        done_path = self._coalesce(effective_row, "DonePath")
        error_path = self._coalesce(effective_row, "ErrorPath")
        result_path = self._coalesce(effective_row, "ResultPath")
        if target_folder:
            if not summary_path:
                summary_path = str(Path(target_folder) / str(pair_test.get("SummaryFileName", "") or "summary.txt"))
            if not request_path:
                request_path = str(Path(target_folder) / str(pair_test.get("RequestFileName", "") or "request.json"))
            if not done_path:
                done_path = str(Path(target_folder) / str(pair_test.get("DoneFileName", "") or "done.json"))
            if not error_path:
                error_path = str(Path(target_folder) / str(pair_test.get("ErrorFileName", "") or "error.json"))
            if not result_path:
                result_path = str(Path(target_folder) / "result.json")

        summary_ref = self._build_file_ref(summary_path, "summary")
        request_ref = self._build_file_ref(request_path, "request")
        done_ref = self._build_file_ref(done_path, "done")
        error_ref = self._build_file_ref(error_path, "error")
        result_ref = self._build_file_ref(result_path, "result")
        zip_files = self._list_zip_refs(review_folder)
        latest_zip_ref = self._select_latest_zip(zip_files, str((paired_row or {}).get("LatestZipName", "") or ""))

        summary_present = bool((paired_row or {}).get("SummaryPresent", False)) if paired_row else False
        done_present = bool((paired_row or {}).get("DonePresent", False)) if paired_row else False
        error_present = bool((paired_row or {}).get("ErrorPresent", False)) if paired_row else False
        summary_present = summary_present or bool(summary_ref and summary_ref.exists)
        done_present = done_present or bool(done_ref and done_ref.exists)
        error_present = error_present or bool(error_ref and error_ref.exists)
        zip_count = int((paired_row or {}).get("ZipCount", 0) or 0)
        if not zip_count:
            zip_count = len(zip_files)
        failure_count = int((paired_row or {}).get("FailureCount", 0) or 0)
        latest_state = str((paired_row or {}).get("LatestState", "") or "").strip()
        if not latest_state:
            latest_state = self._infer_latest_state(summary_ref, done_ref, error_ref, latest_zip_ref, result_ref)
        source_outbox_contract_latest_state = str(
            (paired_row or {}).get("SourceOutboxContractLatestState", "")
            or (paired_row or {}).get("ContractLatestState", "")
            or ""
        ).strip()
        source_outbox_next_action = str(
            (paired_row or {}).get("SourceOutboxNextAction", "")
            or (paired_row or {}).get("NextAction", "")
            or ""
        ).strip()
        dispatch_state = str((paired_row or {}).get("DispatchState", "") or "").strip()
        dispatch_updated_at = str((paired_row or {}).get("DispatchUpdatedAt", "") or "").strip()
        blocker_reason, recommended_action = self.describe_latest_state(latest_state)
        if dispatch_state in {"running", "failed"} and latest_state in {"", "no-zip", "artifacts-only", "done-present"}:
            dispatch_reason, dispatch_action = self.describe_dispatch_state(dispatch_state)
            if dispatch_reason:
                blocker_reason = dispatch_reason
            if dispatch_action:
                recommended_action = dispatch_action

        state = TargetArtifactState(
            pair_id=pair_id,
            role_name=role_name,
            target_id=target_id,
            partner_target_id=partner_target_id,
            latest_state=latest_state,
            summary_present=summary_present,
            done_present=done_present,
            error_present=error_present,
            zip_count=zip_count,
            failure_count=failure_count,
            target_folder=target_folder,
            review_folder=review_folder,
            latest_modified_at=self._latest_modified_at(summary_ref, latest_zip_ref, done_ref, error_ref, result_ref, request_ref),
            blocker_reason=blocker_reason,
            recommended_action=recommended_action,
            source_outbox_state=str((paired_row or {}).get("SourceOutboxState", "") or "").strip(),
            source_outbox_reason=str((paired_row or {}).get("SourceOutboxReason", "") or "").strip(),
            source_outbox_contract_latest_state=source_outbox_contract_latest_state,
            source_outbox_next_action=source_outbox_next_action,
            dispatch_state=dispatch_state,
            dispatch_updated_at=dispatch_updated_at,
            seed_send_state=str((paired_row or {}).get("SeedSendState", "") or "").strip(),
            submit_state=str((paired_row or {}).get("SubmitState", "") or "").strip(),
            submit_reason=str((paired_row or {}).get("SubmitReason", "") or "").strip(),
            seed_attempt_count=int((paired_row or {}).get("SeedAttemptCount", 0) or 0),
            seed_max_attempts=int((paired_row or {}).get("SeedMaxAttempts", 0) or 0),
            seed_next_retry_at=str((paired_row or {}).get("SeedNextRetryAt", "") or "").strip(),
            seed_retry_reason=str((paired_row or {}).get("SeedRetryReason", "") or "").strip(),
            manual_attention_required=bool((paired_row or {}).get("ManualAttentionRequired", False)),
            summary_file=summary_ref,
            latest_review_zip=latest_zip_ref,
            request_file=request_ref,
            done_file=done_ref,
            error_file=error_ref,
            result_file=result_ref,
        )
        state.notes = self._collect_notes(state, paired_row is not None)
        if bool((paired_row or {}).get("ErrorSuperseded", False)):
            state.notes.append("error.json 파일은 남아 있지만 더 최신 성공 근거(done/result)가 있어 차단 상태로 보지 않습니다.")
        return state

    def _build_file_ref(self, path: str, kind: str) -> ArtifactFileRef | None:
        if not path:
            return None
        target = Path(path)
        exists = target.exists()
        modified_at = ""
        size_bytes: int | None = None
        if exists:
            stat = target.stat()
            modified_at = self._format_timestamp(stat.st_mtime)
            size_bytes = None if target.is_dir() else int(stat.st_size)
        return ArtifactFileRef(
            path=str(target),
            exists=exists,
            modified_at=modified_at,
            size_bytes=size_bytes,
            kind=kind,
            name=target.name,
        )

    def _list_zip_refs(self, folder: str) -> list[ArtifactFileRef]:
        if not folder:
            return []
        root = Path(folder)
        if not root.exists() or not root.is_dir():
            return []
        zip_paths = sorted(root.glob("*.zip"), key=lambda path: (path.stat().st_mtime, path.name), reverse=True)
        refs: list[ArtifactFileRef] = []
        for path in zip_paths:
            ref = self._build_file_ref(str(path), "review_zip")
            if ref is not None:
                refs.append(ref)
        return refs

    def _select_latest_zip(self, zip_refs: list[ArtifactFileRef], hint_name: str) -> ArtifactFileRef | None:
        if not zip_refs:
            return None
        if hint_name:
            for item in zip_refs:
                if item.name == hint_name:
                    return item
        return zip_refs[0]

    def _infer_latest_state(
        self,
        summary_ref: ArtifactFileRef | None,
        done_ref: ArtifactFileRef | None,
        error_ref: ArtifactFileRef | None,
        latest_zip_ref: ArtifactFileRef | None,
        result_ref: ArtifactFileRef | None,
    ) -> str:
        if error_ref and error_ref.exists and not self._is_error_superseded(error_ref, done_ref, latest_zip_ref, result_ref):
            return "error-present"
        if latest_zip_ref is None:
            return "no-zip"
        if summary_ref is None or not summary_ref.exists:
            return "summary-missing"
        if done_ref and done_ref.exists:
            return "done-present"
        return "artifacts-only"

    def _is_error_superseded(
        self,
        error_ref: ArtifactFileRef | None,
        done_ref: ArtifactFileRef | None,
        latest_zip_ref: ArtifactFileRef | None,
        result_ref: ArtifactFileRef | None,
    ) -> bool:
        if error_ref is None or not error_ref.exists or latest_zip_ref is None or not latest_zip_ref.exists:
            return False

        success_markers: list[ArtifactFileRef] = []
        latest_zip_path = str(Path(latest_zip_ref.path).resolve()).lower()
        for ref in (done_ref, result_ref):
            if not ref or not ref.exists or not ref.modified_at:
                continue
            payload = self._read_json_dict(ref.path)
            if self._has_success_evidence(payload, latest_zip_path):
                success_markers.append(ref)

        if not success_markers:
            return False

        latest_success = max((ref.modified_at for ref in success_markers), default="")
        return bool(latest_success and error_ref.modified_at and latest_success > error_ref.modified_at)

    def _read_json_dict(self, path: str) -> dict:
        if not path:
            return {}
        target = Path(path)
        if not target.exists() or not target.is_file():
            return {}
        try:
            payload = json.loads(target.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    def _has_success_evidence(self, payload: dict, latest_zip_path: str) -> bool:
        if not payload:
            return False
        document_zip = str(payload.get("LatestZipPath", "") or "").strip()
        if not document_zip or not latest_zip_path:
            return False
        try:
            return str(Path(document_zip).resolve()).lower() == latest_zip_path
        except Exception:
            return document_zip.lower() == latest_zip_path

    def _latest_modified_at(self, *file_refs: ArtifactFileRef | None) -> str:
        values = [item.modified_at for item in file_refs if item and item.modified_at]
        return max(values, default="")

    def _collect_notes(self, state: TargetArtifactState, paired_status_available: bool) -> list[str]:
        notes: list[str] = []
        if state.manual_attention_required:
            notes.append("수동 확인 필요: retry 상한 도달")
        elif state.source_outbox_state == "seed-retry-pending":
            notes.append("자동 재시도 대기 중: seed retry-pending")

        if state.blocker_reason:
            notes.append(state.blocker_reason)
        if state.recommended_action:
            notes.append("다음 조치: {0}".format(state.recommended_action))

        if not state.review_folder:
            notes.append("review folder 경로가 비어 있습니다.")
        elif not Path(state.review_folder).exists():
            notes.append("review folder가 존재하지 않습니다.")

        if not state.target_folder:
            notes.append("target folder 경로가 비어 있습니다.")
        elif not Path(state.target_folder).exists():
            notes.append("target folder가 존재하지 않습니다.")

        if state.result_file is None or not state.result_file.exists:
            notes.append("result file이 아직 생성되지 않았습니다.")

        if state.source_outbox_state:
            notes.append("source-outbox 상태: {0}".format(state.source_outbox_state))
            if state.source_outbox_reason:
                notes.append("source-outbox 사유: {0}".format(state.source_outbox_reason))
        if state.source_outbox_contract_latest_state:
            notes.append(
                "source-outbox contract 상태: {0}".format(
                    self.display_latest_state(state.source_outbox_contract_latest_state)
                )
            )
        if state.source_outbox_next_action:
            notes.append("source-outbox 다음 동작: {0}".format(self.display_next_action(state.source_outbox_next_action)))
        if state.dispatch_state:
            notes.append("후속 실행 상태: {0}".format(self.display_dispatch_state(state.dispatch_state)))
            if state.dispatch_updated_at:
                notes.append("후속 실행 갱신 시각: {0}".format(state.dispatch_updated_at))
        if state.seed_send_state:
            notes.append("seed 상태: {0}".format(state.seed_send_state))
        if state.seed_attempt_count > 0:
            if state.seed_max_attempts > 0:
                notes.append("seed 시도 횟수: {0}/{1}".format(state.seed_attempt_count, state.seed_max_attempts))
            else:
                notes.append("seed 시도 횟수: {0}".format(state.seed_attempt_count))
        if state.seed_retry_reason:
            notes.append("seed 재시도 사유: {0}".format(state.seed_retry_reason))
        if state.seed_next_retry_at:
            notes.append("다음 seed 재시도: {0}".format(state.seed_next_retry_at))
        if state.submit_state:
            notes.append("submit 상태: {0}".format(state.submit_state))
            if state.submit_reason:
                notes.append("submit 사유: {0}".format(state.submit_reason))

        if not paired_status_available:
            notes.append("paired status를 읽지 못해 일부 상태는 파일시스템 기준으로 보정했습니다.")

        return notes

    def _safe_read_text(self, path: str, max_chars: int) -> str:
        if not path:
            return "(summary 경로 없음)"
        target = Path(path)
        if not target.exists():
            return "(summary 파일 없음)"
        text = target.read_text(encoding="utf-8", errors="replace")
        if len(text) <= max_chars:
            return text
        return text[:max_chars] + "\n\n...(truncated)"

    def _has_material_artifact(self, state: TargetArtifactState) -> bool:
        return any(
            [
                state.summary_file and state.summary_file.exists,
                state.latest_review_zip and state.latest_review_zip.exists,
                state.request_file and state.request_file.exists,
                state.done_file and state.done_file.exists,
                state.error_file and state.error_file.exists,
                state.result_file and state.result_file.exists,
            ]
        )

    def _coalesce(self, first: dict | None, first_key: str, second: dict | None = None, second_key: str | None = None) -> str:
        second_key = second_key or first_key
        first_value = str((first or {}).get(first_key, "") or "").strip()
        if first_value:
            return first_value
        return str((second or {}).get(second_key, "") or "").strip()

    def _format_timestamp(self, timestamp: float) -> str:
        return datetime.fromtimestamp(timestamp).isoformat(timespec="seconds")

    def _matches_run_root(self, state: TargetArtifactState, run_root: str) -> bool:
        if not run_root:
            return True
        try:
            run_root_path = Path(run_root).resolve()
        except Exception:
            return True

        candidates = [
            state.target_folder,
            state.review_folder,
            state.summary_file.path if state.summary_file else "",
            state.request_file.path if state.request_file else "",
            state.done_file.path if state.done_file else "",
            state.error_file.path if state.error_file else "",
            state.result_file.path if state.result_file else "",
            state.latest_review_zip.path if state.latest_review_zip else "",
        ]
        for candidate in candidates:
            if not candidate:
                continue
            try:
                candidate_path = Path(candidate).resolve()
            except Exception:
                continue
            if candidate_path == run_root_path or run_root_path in candidate_path.parents:
                return True
        return False
