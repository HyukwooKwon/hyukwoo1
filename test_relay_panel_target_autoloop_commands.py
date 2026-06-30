from __future__ import annotations

import unittest

import relay_panel_target_autoloop_commands as commands


class TargetAutoloopCommandPlanTests(unittest.TestCase):
    def test_start_watcher_plan_uses_detached_target_autoloop_mode(self) -> None:
        plan = commands.build_start_watcher_command_plan(run_root=r"C:\runs\run_1")

        self.assertEqual("tests/Start-TargetAutoloopWatcher.ps1", plan.script_name)
        self.assertEqual(r"C:\runs\run_1", plan.run_root_override)
        self.assertEqual(["-RunMode", "target-autoloop", "-Detached", "-AsJson"], plan.extra_args())
        self.assertIn("-Detached", plan.display_command)

    def test_start_watcher_plan_can_scope_to_target(self) -> None:
        plan = commands.build_start_watcher_command_plan(run_root=r"C:\runs\run_1", target_id=" target01 ")

        self.assertEqual("tests/Start-TargetAutoloopWatcher.ps1", plan.script_name)
        self.assertEqual(r"C:\runs\run_1", plan.run_root_override)
        self.assertEqual(
            ["-RunMode", "target-autoloop", "-Targets", "target01", "-Detached", "-AsJson"],
            plan.extra_args(),
        )
        self.assertIn("-Targets target01", plan.display_command)

    def test_start_watcher_plan_can_scope_to_multiple_targets(self) -> None:
        plan = commands.build_start_watcher_command_plan(
            run_root=r"C:\runs\run_1",
            target_ids=["target03", " target02 ", "target03"],
        )

        self.assertEqual("tests/Start-TargetAutoloopWatcher.ps1", plan.script_name)
        self.assertEqual(r"C:\runs\run_1", plan.run_root_override)
        self.assertEqual(
            ["-RunMode", "target-autoloop", "-Targets", "target03", "target02", "-Detached", "-AsJson"],
            plan.extra_args(),
        )
        self.assertIn("-Targets target03,target02", plan.display_command)

    def test_prepare_selected_runroot_plan_includes_targets(self) -> None:
        plan = commands.build_prepare_run_root_command_plan(
            selected_only=True,
            enabled_target_ids=["target02", "", " target03 "],
        )

        self.assertEqual("tests/Start-TargetAutoloopRun.ps1", plan.script_name)
        self.assertEqual("", plan.run_root_override)
        self.assertEqual(
            ["-RunMode", "target-autoloop", "-Targets", "target02,target03", "-AsJson"],
            plan.extra_args(),
        )
        self.assertIn("-Targets target02,target03", plan.display_command)

    def test_process_once_plan_is_not_detached(self) -> None:
        plan = commands.build_process_once_command_plan(run_root=r"C:\runs\run_1")

        self.assertEqual("tests/Start-TargetAutoloopWatcher.ps1", plan.script_name)
        self.assertEqual(r"C:\runs\run_1", plan.run_root_override)
        self.assertEqual(["-RunMode", "target-autoloop", "-ProcessOnce", "-AsJson"], plan.extra_args())
        self.assertNotIn("-Detached", plan.extra_args())

    def test_process_once_plan_can_scope_to_target(self) -> None:
        plan = commands.build_process_once_command_plan(run_root=r"C:\runs\run_1", target_id=" target04 ")

        self.assertEqual("tests/Start-TargetAutoloopWatcher.ps1", plan.script_name)
        self.assertEqual(r"C:\runs\run_1", plan.run_root_override)
        self.assertEqual(
            ["-RunMode", "target-autoloop", "-Targets", "target04", "-ProcessOnce", "-AsJson"],
            plan.extra_args(),
        )
        self.assertIn("-Targets target04", plan.display_command)

    def test_publish_ready_marker_plan_overwrites_target_marker(self) -> None:
        plan = commands.build_publish_ready_marker_command_plan(
            run_root=r"C:\runs\run_1",
            target_id=" target08 ",
        )

        self.assertEqual("tests/Publish-TargetAutoloopArtifact.ps1", plan.script_name)
        self.assertEqual(r"C:\runs\run_1", plan.run_root_override)
        self.assertEqual(["-TargetId", "target08", "-Overwrite", "-AsJson"], plan.extra_args())
        self.assertIn("-TargetId target08", plan.display_command)
        self.assertIn("-Overwrite", plan.display_command)

    def test_extend_cycle_limit_plan_uses_run_root_and_additional_cycles(self) -> None:
        plan = commands.build_extend_cycle_limit_command_plan(
            run_root=r"C:\runs\run_1",
            target_id="target01",
            additional_cycles=3,
        )

        self.assertEqual("tests/Extend-TargetAutoloopCycleLimit.ps1", plan.script_name)
        self.assertEqual(r"C:\runs\run_1", plan.run_root_override)
        self.assertEqual(["-TargetId", "target01", "-AdditionalCycles", "3", "-AsJson"], plan.extra_args())
        self.assertIn("-TargetId target01", plan.display_command)

    def test_control_action_plan_uses_panel_requested_by(self) -> None:
        plan = commands.build_control_action_command_plan(action="resume", run_root=r"C:\runs\run_1")

        self.assertEqual("tests/Request-TargetAutoloopControl.ps1", plan.script_name)
        self.assertEqual(r"C:\runs\run_1", plan.run_root_override)
        self.assertEqual(
            ["-Action", "resume", "-RequestedBy", "relay_operator_panel", "-AsJson"],
            plan.extra_args(),
        )

    def test_router_restart_plan_is_as_json_only(self) -> None:
        plan = commands.build_router_restart_command_plan()

        self.assertEqual("router/Restart-RouterForConfig.ps1", plan.script_name)
        self.assertIsNone(plan.run_root_override)
        self.assertEqual(["-AsJson"], plan.extra_args())


if __name__ == "__main__":
    unittest.main()
