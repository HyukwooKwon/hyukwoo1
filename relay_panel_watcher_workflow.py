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


class WatcherControlFailure(Exception):
    def __init__(self, panel_update: WatcherPanelUpdate, message: str) -> None:
        super().__init__(message)
        self.panel_update = panel_update


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
        *,
        action_label: str = "watcher 시작",
    ) -> WatcherPanelUpdate:
        diagnostics = self._diagnostics(context)
        return WatcherPanelUpdate(
            ok=False,
            output_text=diagnostics.details,
            operator_state=f"{action_label} 차단",
            operator_hint=eligibility.message,
            last_result=self._failure_last_result(f"{action_label} 차단", eligibility.reason_codes, eligibility.state),
        )

    def start(
        self,
        context: WatcherActionContextSnapshot,
        *,
        clear_stale_first: bool = False,
        request: WatcherStartRequest | None = None,
        action_label: str = "watcher 시작",
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
            lines = [f"{action_label} 준비"]
            if notes:
                lines.extend(notes)
            lines.extend(["", result.message, "", diagnostics.details])
            return WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines),
                operator_state=f"{action_label} 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result(f"{action_label} 실패", result.reason_codes, result.state),
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
            operator_state=f"{action_label} 요청",
            operator_hint="수 초 뒤 paired status와 결과 탭을 빠르게 다시 읽습니다. 입력한 시작 preset 기준으로 running 상태를 확인하세요.",
            last_result=f"마지막 결과: {action_label} 요청",
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
        return "watcher 종료 전 확인이 필요한 상태가 있습니다.\n\n{0}\n\n일시중지가 아니라 종료 요청을 기록할까요?".format(warning_text)

    @staticmethod
    def restart_confirmation_text(warning_codes: list[str]) -> str:
        warning_text = "\n".join("- {0}".format(code) for code in warning_codes)
        return "재시작 전 확인이 필요한 상태가 있습니다.\n\n{0}\n\nwatcher 종료 확인 후 재시작을 진행할까요?".format(warning_text)

    def request_stop(self, context: WatcherActionContextSnapshot) -> WatcherPanelUpdate:
        result = self.watcher_controller.request_stop(context.paired_status, context.run_root)
        lines = [
            "watcher 종료 요청",
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
                operator_state="watcher 종료 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watcher 종료 실패", result.reason_codes, result.state),
            )
        return WatcherPanelUpdate(
            ok=True,
            output_text="\n".join(lines),
            operator_state="watcher 종료 요청",
            operator_hint="control file을 기록했습니다. 수 초 뒤 stopped 상태를 확인합니다.",
            last_result="마지막 결과: watcher 종료 요청",
        )

    def request_stop_and_wait(
        self,
        context: WatcherActionContextSnapshot,
        app_context: AppContext,
        *,
        poll_interval_sec: float = 1.0,
        timeout_sec: float = 20.0,
    ) -> WatcherPanelUpdate:
        result = self.watcher_controller.request_stop(context.paired_status, context.run_root)
        request_lines = [
            "watcher 종료 요청",
            "RunRoot: {0}".format(context.run_root),
            "상태: {0}".format(result.state),
            "메시지: {0}".format(result.message),
        ]
        if result.request_id:
            request_lines.append("RequestId: {0}".format(result.request_id))
        if result.warning_codes:
            request_lines.append("Warnings: " + ", ".join(result.warning_codes))
        if result.reason_codes:
            request_lines.append("Reasons: " + ", ".join(result.reason_codes))
        if not result.ok:
            diagnostics = self._diagnostics(context)
            panel_update = WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(request_lines + ["", diagnostics.details]),
                operator_state="watcher 종료 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watcher 종료 실패", result.reason_codes, result.state),
            )
            raise WatcherControlFailure(panel_update, result.message)

        def status_loader(target_run_root: str):
            return self.status_service.refresh_paired_status(app_context, run_root=target_run_root)

        wait_result = self.watcher_controller.wait_for_stopped(
            status_loader,
            context.run_root,
            request_id=result.request_id,
            timeout_sec=timeout_sec,
            poll_interval_sec=poll_interval_sec,
        )
        if not wait_result.ok:
            diagnostics = self._diagnostics(context)
            lines = list(request_lines)
            lines.extend(
                [
                    "",
                    "watcher 종료 확인",
                    "상태: {0}".format(wait_result.state),
                    "메시지: {0}".format(wait_result.message),
                ]
            )
            if wait_result.reason_codes:
                lines.append("Reasons: " + ", ".join(wait_result.reason_codes))
            panel_update = WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines + ["", diagnostics.details]),
                operator_state="watcher 종료 실패",
                operator_hint=wait_result.message,
                last_result=self._failure_last_result("watcher 종료 실패", wait_result.reason_codes, wait_result.state),
            )
            raise WatcherControlFailure(panel_update, wait_result.message)

        lines = list(request_lines)
        lines.extend(
            [
                "",
                "watcher 종료 확인",
                "상태: {0}".format(wait_result.state),
                "메시지: {0}".format(wait_result.message),
            ]
        )
        return WatcherPanelUpdate(
            ok=True,
            output_text="\n".join(lines),
            operator_state="watcher 종료 확인",
            operator_hint="stopped 상태와 request ack를 확인했습니다.",
            last_result="마지막 결과: watcher 종료 확인",
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

    def request_pause_and_wait(
        self,
        context: WatcherActionContextSnapshot,
        app_context: AppContext,
        *,
        poll_interval_sec: float = 1.0,
        timeout_sec: float = 15.0,
    ) -> WatcherPanelUpdate:
        result = self.watcher_controller.request_pause(context.paired_status, context.run_root)
        request_lines = [
            "watch pause 요청",
            "RunRoot: {0}".format(context.run_root),
            "상태: {0}".format(result.state),
            "메시지: {0}".format(result.message),
        ]
        if result.request_id:
            request_lines.append("RequestId: {0}".format(result.request_id))
        if result.reason_codes:
            request_lines.append("Reasons: " + ", ".join(result.reason_codes))
        if not result.ok:
            diagnostics = self._diagnostics(context)
            panel_update = WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(request_lines + ["", diagnostics.details]),
                operator_state="watch pause 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watch pause 실패", result.reason_codes, result.state),
            )
            raise WatcherControlFailure(panel_update, result.message)

        def status_loader(target_run_root: str):
            return self.status_service.refresh_paired_status(app_context, run_root=target_run_root)

        wait_result = self.watcher_controller.wait_for_paused(
            status_loader,
            context.run_root,
            request_id=result.request_id,
            timeout_sec=timeout_sec,
            poll_interval_sec=poll_interval_sec,
        )
        if not wait_result.ok:
            diagnostics = self._diagnostics(context)
            lines = list(request_lines)
            lines.extend(
                [
                    "",
                    "watch pause 확인",
                    "상태: {0}".format(wait_result.state),
                    "메시지: {0}".format(wait_result.message),
                ]
            )
            if wait_result.reason_codes:
                lines.append("Reasons: " + ", ".join(wait_result.reason_codes))
            panel_update = WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines + ["", diagnostics.details]),
                operator_state="watch pause 실패",
                operator_hint=wait_result.message,
                last_result=self._failure_last_result("watch pause 실패", wait_result.reason_codes, wait_result.state),
            )
            raise WatcherControlFailure(panel_update, wait_result.message)

        lines = list(request_lines)
        lines.extend(
            [
                "",
                "watch pause 확인",
                "상태: {0}".format(wait_result.state),
                "메시지: {0}".format(wait_result.message),
            ]
        )
        return WatcherPanelUpdate(
            ok=True,
            output_text="\n".join(lines),
            operator_state="watch pause 확인",
            operator_hint="paused 상태와 request ack를 확인했습니다.",
            last_result="마지막 결과: watch pause 확인",
        )

    def request_resume_and_wait(
        self,
        context: WatcherActionContextSnapshot,
        app_context: AppContext,
        *,
        poll_interval_sec: float = 1.0,
        timeout_sec: float = 15.0,
    ) -> WatcherPanelUpdate:
        result = self.watcher_controller.request_resume(context.paired_status, context.run_root)
        request_lines = [
            "watch resume 요청",
            "RunRoot: {0}".format(context.run_root),
            "상태: {0}".format(result.state),
            "메시지: {0}".format(result.message),
        ]
        if result.request_id:
            request_lines.append("RequestId: {0}".format(result.request_id))
        if result.reason_codes:
            request_lines.append("Reasons: " + ", ".join(result.reason_codes))
        if not result.ok:
            diagnostics = self._diagnostics(context)
            panel_update = WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(request_lines + ["", diagnostics.details]),
                operator_state="watch resume 실패",
                operator_hint=result.message,
                last_result=self._failure_last_result("watch resume 실패", result.reason_codes, result.state),
            )
            raise WatcherControlFailure(panel_update, result.message)

        def status_loader(target_run_root: str):
            return self.status_service.refresh_paired_status(app_context, run_root=target_run_root)

        wait_result = self.watcher_controller.wait_for_resumed(
            status_loader,
            context.run_root,
            request_id=result.request_id,
            timeout_sec=timeout_sec,
            poll_interval_sec=poll_interval_sec,
        )
        if not wait_result.ok:
            diagnostics = self._diagnostics(context)
            lines = list(request_lines)
            lines.extend(
                [
                    "",
                    "watch resume 확인",
                    "상태: {0}".format(wait_result.state),
                    "메시지: {0}".format(wait_result.message),
                ]
            )
            if wait_result.reason_codes:
                lines.append("Reasons: " + ", ".join(wait_result.reason_codes))
            panel_update = WatcherPanelUpdate(
                ok=False,
                output_text="\n".join(lines + ["", diagnostics.details]),
                operator_state="watch resume 실패",
                operator_hint=wait_result.message,
                last_result=self._failure_last_result("watch resume 실패", wait_result.reason_codes, wait_result.state),
            )
            raise WatcherControlFailure(panel_update, wait_result.message)

        lines = list(request_lines)
        lines.extend(
            [
                "",
                "watch resume 확인",
                "상태: {0}".format(wait_result.state),
                "메시지: {0}".format(wait_result.message),
            ]
        )
        return WatcherPanelUpdate(
            ok=True,
            output_text="\n".join(lines),
            operator_state="watch resume 확인",
            operator_hint="running 상태 복귀와 request ack를 확인했습니다.",
            last_result="마지막 결과: watch resume 확인",
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
