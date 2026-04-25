from __future__ import annotations

import unittest

from relay_panel_context_helpers import (
    append_query_history,
    context_source_label,
    format_action_context_summary,
    format_artifact_query_context_summary,
    format_inspection_context_summary,
    format_query_context_summary,
    resolve_inspection_context,
)
from relay_panel_models import AppContext
from relay_panel_operator_state import ActionContextState, ArtifactQueryContextState, InspectionContextState


class ContextHelperTests(unittest.TestCase):
    def test_context_source_label_and_summaries_follow_shared_format(self) -> None:
        self.assertEqual("inspection 반영", context_source_label("inspection-apply"))
        self.assertEqual(
            "pair01/target03 [inspection 반영]",
            format_action_context_summary(
                ActionContextState(
                    pair_id="pair01",
                    target_id="target03",
                    source="inspection-apply",
                )
            ),
        )
        self.assertEqual(
            "pair02/target06 [board 선택]",
            format_inspection_context_summary(
                InspectionContextState(
                    pair_id="pair02",
                    target_id="target06",
                    source="board-target",
                )
            ),
        )
        self.assertIn(
            "artifact-run=current",
            format_artifact_query_context_summary(
                ArtifactQueryContextState(
                    run_root="C:\\runs\\current",
                    pair_id="pair03",
                    target_id="target07",
                    path_kind="review_zip",
                    latest_only=True,
                    include_missing=False,
                )
            ),
        )
        self.assertEqual(
            "run=current / pair=pair04 / target=target08",
            format_query_context_summary(
                AppContext(
                    run_root="C:\\runs\\current",
                    pair_id="pair04",
                    target_id="target08",
                )
            ),
        )

    def test_resolve_inspection_context_prefers_selected_row_and_preserves_existing_target(self) -> None:
        resolved = resolve_inspection_context(
            selected_row={"PairId": "pair02"},
            selected_row_index=4,
            stored=InspectionContextState(
                pair_id="pair01",
                target_id="target01",
                source="manual-inspection",
                row_index=1,
            ),
            fallback_target_id="target06",
        )

        self.assertEqual("pair02", resolved.pair_id)
        self.assertEqual("target01", resolved.target_id)
        self.assertEqual("manual-inspection", resolved.source)
        self.assertEqual(4, resolved.row_index)

    def test_resolve_inspection_context_uses_fallback_target_when_target_missing(self) -> None:
        resolved = resolve_inspection_context(
            selected_row={"PairId": "pair02"},
            selected_row_index=2,
            stored=InspectionContextState(
                pair_id="",
                target_id="",
                source="",
                row_index=None,
            ),
            fallback_target_id="target06",
        )

        self.assertEqual("pair02", resolved.pair_id)
        self.assertEqual("target06", resolved.target_id)
        self.assertEqual("preview-row", resolved.source)
        self.assertEqual(2, resolved.row_index)

    def test_append_query_history_trims_to_latest_limit(self) -> None:
        records: list = []
        for index in range(7):
            records, entries = append_query_history(
                records,
                value=f"마지막 조회: query-{index} 완료",
                context=f"pair=pair{index:02d}",
                timestamp=f"10:00:0{index}",
            )

        self.assertEqual(5, len(records))
        self.assertEqual(5, len(entries))
        self.assertEqual("pair=pair06", records[-1].context)
        self.assertIn("query-6", entries[-1])
        self.assertNotIn("query-0", " | ".join(entries))


if __name__ == "__main__":
    unittest.main()
