from __future__ import annotations
from .names import Hook, HookFn


class HookRegistry:
    """The instance is the decorator: @hook(Hook.PRE_COMMIT)."""
    def __init__(self) -> None:
        self._handlers: dict[Hook, HookFn] = {}

    def __call__(self, h: Hook):
        def decorate(fn: HookFn) -> HookFn:
            if h in self._handlers:
                raise RuntimeError(f"hook {h} already handled by {self._handlers[h].__name__}; "
                                   "only one handler per hook is allowed")
            self._handlers[h] = fn
            return fn
        return decorate

    def handler_for(self, h: Hook) -> HookFn | None:
        return self._handlers.get(h)


hook = HookRegistry()
