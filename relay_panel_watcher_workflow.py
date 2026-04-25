from __future__ import annotations

from dataclasses import dataclass

from relay_panel_models import AppContext
from relay_panel_watcher_controller import WatcherController
from relay_panel_watchers import WatcherControlResult, WatcherStartEligibility, WatcherStopEligibility, WatcherStartRequest


def _reason_code_text(reason_codes: list[str], state: str) -> str:
    return ",".join(reason_codes) or state


@dataclass(frozen=True)
class WatcherActionContextSnapshot:
    config_path: str
    run_root: str
    paired_status: dict | None


@dataclass(frozen=True)
class WatcherPanelUpdate:
    ok: bool
    output_text: str
    operator_state: str = ""
    operator_hint: str = ""
    last_result: str = ""
    command_text: str = ""


@dataclass(frozen=True)
class WatcherRestartRequest:
    context: WatcherActionContextSnapshot
    app_context: AppContext
    poll_interval_sec: float = 1.0
    watcher_request: WatcherStartRequest | None = None


@dataclass(frozen=True)
class WatcherRestartSuccess:
    panel_update: WatcherPanelUpdate


class WatcherRestartFailure(Exception):
    def __init__(self, panel_update: WatcherPanelUpdate, message: str) -> None:
        super().__init__(message)
        self.panel_update = panel_update


class PanelWatcherWorkflowService:
    def __init__(self, watcher_controller: WatcherController, command_service, status_service) -> None:
        self.watcher_controller = watcher_controller
        self.command_service = command_service
        self.status_service = status_service

    def _diagnostics(self, context: WatcherActionContextSnapshot):
        return self.watcher_controller.diagnostics(context.paired_status, context.run_root)

    @staticmethod
    def _failure_last_result(label: str, reason_codes: list[str], state: str) -> str:
        return "마지막 결과: {0} ({1})".format(label, _reason_code_text(reason_codes, state))

    def build_start_blocked_update(
        self,
        context: WatcherActionContextSnapshot,
        eligibility: WatcherStartEligibility,
    ) -> WatcherPanelUpdate:
        diagnostics = self._diagnostics(context)
        return WatcherPanelUpdate(
            ok=False,
            output_text=diagnostics.details,
            operator_state="watch 시작 차단",
            operator_hint=eligibility.message,
            last_result=self._failure_last_result("watch 시작 차단", eligibility.reason_codes, eligibility.state),
        )

    def start(
        self,
        context: WatcherActionContextSnapshot,
        *,
        clear_stale_first: bool = False,
        request: WatcherStartRequest | None = None,
    ) -> WatcherPanelUpdate:
        result, notes = self.watcher_controller.start(
            self.command_service,
            config_path=context.config_path,
            run_root=context.run_root,
            paired_status=context.paired_status,
            clear_stale_first=clear_stale_first,
            request=request,
        )
        if not result.ok:
            diagnostics = self._diagnostics(context)
            lines = ["watch 시작 준비"]
            if notes:
                lines.extend(notes)
            lines.extend(["", result.message, "", diagnostics.details])
            return WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines),
                operator_state="watcher 시작 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watcher 시작 실패", result.reason_codes, result.state),
                command_text=result.command_text,
            )

        start_request = request or self.watcher_controller.default_start_request(
            config_path=context.config_path,
            run_root=context.run_root,
        )
        base_lines = list(notes)
        if base_lines:
            base_lines.append("")
        output_text = (
            "\n".join(base_lines)
            + ("paired watcher를 별도 프로세스로 시작했습니다.\n\n" if base_lines else "paired watcher를 별도 프로세스로 시작했습니다.\n\n")
            + (result.command_text or "(command unavailable)")
            + "\n\n상태: {0}".format(result.message)
            + "\n"
            + self.watcher_controller.describe_start_request(start_request)
        )
        return WatcherPanelUpdate(
            ok=True,
            output_text=output_text,
            operator_state="watcher 시작 요청",
            operator_hint="수 초 뒤 paired status와 결과 탭을 빠르게 다시 읽습니다. 입력한 watch preset 기준으로 running 상태를 확인하세요.",
            last_result="마지막 결과: watcher 시작 요청",
            command_text=result.command_text,
        )

    def build_recover_blocked_update(
        self,
        context: WatcherActionContextSnapshot,
        eligibility: WatcherStartEligibility,
    ) -> WatcherPanelUpdate:
        diagnostics = self._diagnostics(context)
        return WatcherPanelUpdate(
            ok=False,
            output_text=diagnostics.details,
            operator_state="watch stale 정리 차단",
            operator_hint="현재 상태에서는 stale control 정리를 수행할 수 없습니다.",
            last_result=self._failure_last_result("watch stale 정리 차단", eligibility.reason_codes, eligibility.state),
        )

    def recover_stale(self, context: WatcherActionContextSnapshot) -> WatcherPanelUpdate:
        result = self.watcher_controller.recover_start_blockers(context.paired_status, context.run_root)
        lines = [
            "watch stale 정리",
            "RunRoot: {0}".format(context.run_root),
            "상태: {0}".format(result.state),
            "메시지: {0}".format(result.message),
        ]
        if result.reason_codes:
            lines.append("Reasons: " + ", ".join(result.reason_codes))
        if not result.ok:
            diagnostics = self._diagnostics(context)
            return WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines + ["", diagnostics.details]),
                operator_state="watch stale 정리 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watch stale 정리 실패", result.reason_codes, result.state),
            )
        return WatcherPanelUpdate(
            ok=True,
            output_text="\n".join(lines),
            operator_state="watch stale 정리 완료",
            operator_hint=result.message,
            last_result="마지막 결과: watch stale 정리 완료",
        )

    def build_stop_blocked_update(
        self,
        context: WatcherActionContextSnapshot,
        eligibility: WatcherStopEligibility,
        *,
        action_label: str,
    ) -> WatcherPanelUpdate:
        diagnostics = self._diagnostics(context)
        return WatcherPanelUpdate(
            ok=False,
            output_text=diagnostics.details,
            operator_state=action_label,
            operator_hint=eligibility.message,
            last_result=self._failure_last_result(action_label, eligibility.reason_codes, eligibility.state),
        )

    @staticmethod
    def stop_confirmation_text(warning_codes: list[str]) -> str:
        warning_text = "\n".join("- {0}".format(code) for code in warning_codes)
        return "정지 전 확인이 필요한 상태가 있습니다.\n\n{0}\n\n정말 정지 요청을 기록할까요?".format(warning_text)

    @staticmethod
    def restart_confirmation_text(warning_codes: list[str]) -> str:
        warning_text = "\n".join("- {0}".format(code) for code in warning_codes)
        return "재시작 전 확인이 필요한 상태가 있습니다.\n\n{0}\n\n정지 확인 후 재시작을 진행할까요?".format(warning_text)

    def request_stop(self, context: WatcherActionContextSnapshot) -> WatcherPanelUpdate:
        result = self.watcher_controller.request_stop(context.paired_status, context.run_root)
        lines = [
            "watch 정지 요청",
            "RunRoot: {0}".format(context.run_root),
            "상태: {0}".format(result.state),
            "메시지: {0}".format(result.message),
        ]
        if result.request_id:
            lines.append("RequestId: {0}".format(result.request_id))
        if result.warning_codes:
            lines.append("Warnings: " + ", ".join(result.warning_codes))
        if result.reason_codes:
            lines.append("Reasons: " + ", ".join(result.reason_codes))
        if not result.ok:
            diagnostics = self._diagnostics(context)
            return WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines + ["", diagnostics.details]),
                operator_state="watch 정지 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watch 정지 실패", result.reason_codes, result.state),
            )
        return WatcherPanelUpdate(
            ok=True,
            output_text="\n".join(lines),
            operator_state="watch 정지 요청",
            operator_hint="control file을 기록했습니다. 수 초 뒤 stopped 상태를 확인합니다.",
            last_result="마지막 결과: watch 정지 요청",
        )

    def request_pause(self, context: WatcherActionContextSnapshot) -> WatcherPanelUpdate:
        result = self.watcher_controller.request_pause(context.paired_status, context.run_root)
        lines = [
            "watch pause 요청",
            "RunRoot: {0}".format(context.run_root),
            "상태: {0}".format(result.state),
            "메시지: {0}".format(result.message),
        ]
        if result.request_id:
            lines.append("RequestId: {0}".format(result.request_id))
        if result.reason_codes:
            lines.append("Reasons: " + ", ".join(result.reason_codes))
        if not result.ok:
            diagnostics = self._diagnostics(context)
            return WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines + ["", diagnostics.details]),
                operator_state="watch pause 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watch pause 실패", result.reason_codes, result.state),
            )
        return WatcherPanelUpdate(
            ok=True,
            output_text="\n".join(lines),
            operator_state="watch pause 요청",
            operator_hint="control file을 기록했습니다. 수 초 뒤 paused 상태를 확인합니다.",
            last_result="마지막 결과: watch pause 요청",
        )

    def request_resume(self, context: WatcherActionContextSnapshot) -> WatcherPanelUpdate:
        result = self.watcher_controller.request_resume(context.paired_status, context.run_root)
        lines = [
            "watch resume 요청",
            "RunRoot: {0}".format(context.run_root),
            "상태: {0}".format(result.state),
            "메시지: {0}".format(result.message),
        ]
        if result.request_id:
            lines.append("RequestId: {0}".format(result.request_id))
        if result.reason_codes:
            lines.append("Reasons: " + ", ".join(result.reason_codes))
        if not result.ok:
            diagnostics = self._diagnostics(context)
            return WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines + ["", diagnostics.details]),
                operator_state="watch resume 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watch resume 실패", result.reason_codes, result.state),
            )
        return WatcherPanelUpdate(
            ok=True,
            output_text="\n".join(lines),
            operator_state="watch resume 요청",
            operator_hint="control file을 기록했습니다. 수 초 뒤 running 상태 복귀를 확인합니다.",
            last_result="마지막 결과: watch resume 요청",
        )

    def _build_restart_panel_update(self, result: WatcherControlResult) -> WatcherPanelUpdate:
        lines = [
            "watch 재시작 결과",
            "RunRoot: {0}".format(result.run_root),
            "상태: {0}".format(result.state),
            "메시지: {0}".format(result.message),
        ]
        if result.request_id:
            lines.append("RequestId: {0}".format(result.request_id))
        if result.warning_codes:
            lines.append("Warnings: " + ", ".join(result.warning_codes))
        if result.reason_codes:
            lines.append("Reasons: " + ", ".join(result.reason_codes))
        return WatcherPanelUpdate(
            ok=result.ok,
            output_text="\n".join(lines),
            command_text=result.command_text,
        )

    def restart(self, request: WatcherRestartRequest) -> WatcherRestartSuccess:
        def status_loader(target_run_root: str):
            return self.status_service.refresh_paired_status(request.app_context, run_root=target_run_root)

        result = self.watcher_controller.restart(
            self.command_service,
            status_loader,
            config_path=request.context.config_path,
            run_root=request.context.run_root,
            paired_status=request.context.paired_status,
            poll_interval_sec=request.poll_interval_sec,
            request=request.watcher_request,
        )
        panel_update = self._build_restart_panel_update(result)
        if not result.ok:
            raise WatcherRestartFailure(panel_update, result.message)
        return WatcherRestartSuccess(panel_update=panel_update)
