from __future__ import annotations

from dataclasses import dataclass

from relay_panel_models import AppContext, DashboardRawBundle
from relay_panel_services import StatusService


@dataclass(frozen=True)
class RuntimeRefreshResult:
    relay_status: dict
    visibility_status: dict


@dataclass(frozen=True)
class PairedRefreshResult:
    paired_status: dict | None
    paired_status_error: str


@dataclass(frozen=True)
class QuickRefreshResult:
    runtime: RuntimeRefreshResult
    paired: PairedRefreshResult


class PanelRefreshController:
    def __init__(self, status_service: StatusService) -> None:
        self.status_service = status_service

    def refresh_runtime(self, context: AppContext) -> RuntimeRefreshResult:
        relay_payload, visibility_payload = self.status_service.refresh_runtime_status(context)
        return RuntimeRefreshResult(
            relay_status=relay_payload,
            visibility_status=visibility_payload,
        )

    def refresh_paired(self, context: AppContext, *, run_root: str | None = None) -> PairedRefreshResult:
        paired_payload, paired_error = self.status_service.refresh_paired_status(context, run_root=run_root)
        return PairedRefreshResult(
            paired_status=paired_payload,
            paired_status_error=paired_error,
        )

    def refresh_quick(self, context: AppContext) -> QuickRefreshResult:
        return QuickRefreshResult(
            runtime=self.refresh_runtime(context),
            paired=self.refresh_paired(context, run_root=context.run_root),
        )

    def refresh_full(self, context: AppContext) -> DashboardRawBundle:
        return self.status_service.load_dashboard_bundle(context)
