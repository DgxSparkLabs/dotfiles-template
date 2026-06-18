from __future__ import annotations

import sys

from .dispatch import dispatch_per_repo_hooks
from .names import HookContext, build_dispatch, log_hook


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print("usage: python -m dotfiles_githooks <hook-name> [args...]", file=sys.stderr)
        return 2
    return _run_hook(argv)


def _run_hook(argv: list[str]) -> int:
    hook_name = argv[0]
    rest = argv[1:]
    dispatch = build_dispatch()
    fn = dispatch.get(hook_name)
    if fn is None:
        # Unknown hook name: keep the default (no-op success) AND still dispatch to per-repo
        # hooks so a repo can hook even a hook we don't ship a default for.
        log_hook(hook_name, msg="unknown hook name")
        return _dispatch(hook_name, rest)
    ctx = HookContext(hook_name=hook_name, argv=rest)
    try:
        # Default hook handling first (this drains stdin for STDIN hooks per names.py).
        rc = int(fn(ctx))
    except Exception as e:  # noqa: BLE001 — surface unexpected errors in hooks
        log_hook(hook_name, msg=f"error: {e}")
        return 1
    if rc != 0:
        return rc
    # Then dispatch to per-repo hook scripts (_shared first, then this repo's).
    return _dispatch(hook_name, rest)


def _dispatch(hook_name: str, rest: list[str]) -> int:
    try:
        return dispatch_per_repo_hooks(hook_name, rest)
    except Exception as e:  # noqa: BLE001 — never crash an unrelated git op from dispatch
        log_hook(hook_name, msg=f"dispatch error: {e}")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
