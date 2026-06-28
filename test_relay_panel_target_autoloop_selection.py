from __future__ import annotations

import unittest
from pathlib import Path

import relay_panel_target_autoloop_selection as selection


class TargetAutoloopSelectionTests(unittest.TestCase):
    def test_payload_preserves_target_order_and_filters_unknown_selected_targets(self) -> None:
        payload = selection.build_target_autoloop_policy_selection_payload(
            target_ids=["target03", "target01", "", "target02"],
            selected_target_ids=["target99", "target02", "target03"],
            config_path=r"C:\repo\settings.psd1",
            run_root=r"C:\repo\.relay-runs\bottest-live-visible\target-autoloop\run_1",
            filter_mode="dirty",
            updated_at="2026-05-28T01:02:03+09:00",
        )

        self.assertEqual(selection.TARGET_AUTOLOOP_POLICY_SELECTION_SCHEMA_VERSION, payload["SchemaVersion"])
        self.assertEqual(["target03", "target02"], payload["SelectedTargetIds"])
        self.assertEqual("dirty", payload["FilterMode"])
        self.assertEqual(
            selection.target_autoloop_policy_target_ids_hash(["target03", "target01", "target02"]),
            payload["TargetIdsHash"],
        )

    def test_scoped_selection_path_uses_stable_hash_slugs(self) -> None:
        snapshot_dir = Path(r"C:\panel-snapshots")

        path = selection.target_autoloop_policy_scoped_selection_path(
            snapshot_dir=snapshot_dir,
            config_path=r"C:\Repo\settings.psd1",
            run_root=r"C:\Repo\.relay-runs\bottest-live-visible\run_1",
        )

        self.assertEqual(snapshot_dir / "target-autoloop-policy-selection", path.parent)
        self.assertTrue(path.name.startswith("config-"))
        self.assertIn("__runroot-", path.name)
        self.assertTrue(path.name.endswith(".json"))
        self.assertNotIn("settings.psd1", path.name)
        self.assertNotIn("\\", path.name)

    def test_snapshot_summary_text_reports_current_and_saved_state(self) -> None:
        summary = selection.build_target_autoloop_policy_selection_snapshot_summary_text(
            {
                "CurrentPath": r"C:\snapshots\current.json",
                "LoadedPath": r"C:\snapshots\loaded.json",
                "LoadedExists": True,
                "CurrentPayload": {
                    "FilterMode": "attention",
                    "SelectedTargetIds": ["target01", "target04"],
                },
                "SavedFilterMode": "dirty",
                "SavedSelectedTargetIds": ["target02"],
                "SavedUpdatedAt": "2026-05-28T01:02:03+09:00",
                "SavedSchemaVersion": 1,
                "LoadError": "",
            }
        )

        self.assertIn("currentPath=C:\\snapshots\\current.json", summary)
        self.assertIn("loadedExists=True", summary)
        self.assertIn("currentFilter=attention", summary)
        self.assertIn("currentSelectedTargets=target01, target04", summary)
        self.assertIn("savedFilter=dirty", summary)
        self.assertIn("savedSelectedTargets=target02", summary)
        self.assertIn("loadError=(none)", summary)


if __name__ == "__main__":
    unittest.main()
