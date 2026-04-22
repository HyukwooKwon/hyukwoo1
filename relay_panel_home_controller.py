from __future__ import annotations

from collections.abc import Callable


class HomeController:
    def build_overall_detail(
        self,
        *,
        base_detail: str,
        paired_status_error: str,
        watcher_hint: str,
    ) -> str:
        if paired_status_error:
            return "{0} / pair-status={1}".format(base_detail, paired_status_error)
        return "{0} / {1}".format(base_detail, watcher_hint)

    def dispatch_action(
        self,
        action_key: str,
        *,
        handlers: dict[str, Callable[[], None]],
        command_text: str = "",
        copy_callback: Callable[[str], None] | None = None,
        unknown_callback: Callable[[str], None] | None = None,
    ) -> bool:
        handler = handlers.get(action_key)
        if handler is not None:
            handler()
            return True
        if action_key == "copy_command" and copy_callback is not None:
            copy_callback(command_text)
            return True
        if unknown_callback is not None:
            unknown_callback(action_key)
        return False
