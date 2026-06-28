from __future__ import annotations

from dataclasses import dataclass
import time

from relay_panel_models import AppContext, DashboardRawBundle
from relay_panel_services import StatusService


@dataclass(frozen=True)
class RuntimeRefreshResult:
    relay_status: dict
    visibility_status: dict
    refresh_timing_steps: tuple[dict[str, object], ...] = ()


@dataclass(frozen=True)
class PairedRefreshResult:
    paired_status: dict | None
    paired_status_error: str
    refresh_timing_steps: tuple[dict[str, object], ...] = ()


@dataclass(frozen=True)
class QuickRefreshResult:
    runtime: RuntimeRefreshResult
    paired: PairedRefreshResult
    refresh_timing_steps: tuple[dict[str, object], ...] = ()


class PanelRefreshController:
    def __init__(self, status_service: StatusService) -> None:
        self.status_service = status_service

    @staticmethod
    def _run_timed_step(steps: list[dict[str, object]], label: str, callback):
        started_at = time.monotonic()
        try:
            return callback()
        finally:
            steps.append(
                {
                    "label": str(label or "refresh").strip() or "refresh",
                    "elapsed_seconds": max(0.0, time.monotonic() - started_at),
                }
            )

    def refresh_runtime(
        self,
        context: AppContext,
        *,
        force_visibility_refresh: bool = False,
    ) -> RuntimeRefreshResult:
        steps: list[dict[str, object]] = []
        relay_payload = self._run_timed_step(
            steps,
            "relay status",
            lambda: self.status_service.load_relay_status(context),
        )
        visibility_payload = self._run_timed_step(
            steps,
            "visibility",
            lambda: self.status_service.load_visibility_status(
                context,
                force_refresh=force_visibility_refresh,
            ),
        )
        return RuntimeRefreshResult(
            relay_status=relay_payload,
            visibility_status=visibility_payload,
            refresh_timing_steps=tuple(steps),
        )

    def refresh_paired(self, context: AppContext, *, run_root: str | None = None) -> PairedRefreshResult:
        steps: list[dict[str, object]] = []
        paired_payload, paired_error = self._run_timed_step(
            steps,
            "paired status",
            lambda: self.status_service.load_paired_status(context, run_root=run_root),
        )
        return PairedRefreshResult(
            paired_status=paired_payload,
            paired_status_error=paired_error,
            refresh_timing_steps=tuple(steps),
        )

    def refresh_quick(
        self,
        context: AppContext,
        *,
        runtime_context: AppContext | None = None,
    ) -> QuickRefreshResult:
        runtime = self.refresh_runtime(runtime_context or context)
        paired = self.refresh_paired(context, run_root=context.run_root)
        return QuickRefreshResult(
            runtime=runtime,
            paired=paired,
            refresh_timing_steps=tuple(runtime.refresh_timing_steps) + tuple(paired.refresh_timing_steps),
        )

    def refresh_full(self, context: AppContext) -> DashboardRawBundle:
        steps: list[dict[str, object]] = []
        bundle = self._run_timed_step(
            steps,
            "dashboard bundle",
            lambda: self.status_service.load_dashboard_bundle(context),
        )
        if not getattr(bundle, "refresh_timing_steps", None):
            bundle.refresh_timing_steps = steps
        return bundle
