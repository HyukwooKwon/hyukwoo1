from __future__ import annotations

import unittest

from relay_panel_models import AppContext
from relay_panel_operator_state import ActionContextState, QueryHistoryRecord


class OperatorStateTests(unittest.TestCase):
    def test_action_context_state_converts_to_app_context(self) -> None:
        state = ActionContextState(
            config_path="cfg.psd1",
            run_root="C:\\runs\\current",
            pair_id="pair01",
            target_id="target05",
            source="controls",
        )

        self.assertEqual(
            AppContext(
                config_path="cfg.psd1",
                run_root="C:\\runs\\current",
                pair_id="pair01",
                target_id="target05",
            ),
            state.as_app_context(),
        )

    def test_query_history_record_summary_includes_context_when_present(self) -> None:
        self.assertEqual(
            "10:00:00 마지막 조회: runroot 요약 완료 / run=current / pair=pair01",
            QueryHistoryRecord(
                label="마지막 조회: runroot 요약 완료",
                context="run=current / pair=pair01",
                timestamp="10:00:00",
            ).summary(),
        )


if __name__ == "__main__":
    unittest.main()
