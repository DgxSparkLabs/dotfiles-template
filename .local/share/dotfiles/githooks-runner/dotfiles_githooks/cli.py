from __future__ import annotations
import importlib, sys
from .names import Hook, HookContext, hook_default, log_hook
from .registry import hook as registry

_USER_MODULE = "dotfiles_githooks.user_hooks"


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print("usage: python -m dotfiles_githooks <hook-name> [args...]", file=sys.stderr)
        return 2
    return _run_hook(argv)


def _load_user_hooks() -> None:
    try:
        importlib.import_module(_USER_MODULE)
    except ModuleNotFoundError as e:
        if e.name != _USER_MODULE:   # a bad import INSIDE user_hooks must surface
            raise


def _run_hook(argv: list[str]) -> int:
    raw = argv[0]
    try:
        h = Hook(raw)
    except ValueError:
        log_hook(raw, msg="unknown hook name")
        return 0
    _load_user_hooks()
    ctx = HookContext(hook_name=h, argv=argv[1:])
    fn = registry.handler_for(h)
    try:
        return int(fn(ctx)) if fn is not None else hook_default(ctx)
    except Exception as e:  # noqa: BLE001
        log_hook(h, msg=f"error: {e}")
        return 1
