from __future__ import annotations
import os, sys
from dataclasses import dataclass
from enum import StrEnum
from typing import Callable, Final


class Hook(StrEnum):
    """Value == on-disk hook filename (== argv[0] the stub passes)."""
    APPLYPATCH_MSG = "applypatch-msg"; PRE_APPLYPATCH = "pre-applypatch"
    POST_APPLYPATCH = "post-applypatch"; PRE_COMMIT = "pre-commit"
    PRE_MERGE_COMMIT = "pre-merge-commit"; PREPARE_COMMIT_MSG = "prepare-commit-msg"
    COMMIT_MSG = "commit-msg"; POST_COMMIT = "post-commit"; PRE_REBASE = "pre-rebase"
    POST_CHECKOUT = "post-checkout"; POST_MERGE = "post-merge"; POST_REWRITE = "post-rewrite"
    PRE_PUSH = "pre-push"; PRE_RECEIVE = "pre-receive"; UPDATE = "update"
    POST_RECEIVE = "post-receive"; POST_UPDATE = "post-update"
    REFERENCE_TRANSACTION = "reference-transaction"; PUSH_TO_CHECKOUT = "push-to-checkout"
    PRE_AUTO_GC = "pre-auto-gc"; SENDEMAIL_VALIDATE = "sendemail-validate"
    POST_INDEX_CHANGE = "post-index-change"; P4_CHANGELIST = "p4-changelist"
    P4_PREPARE_CHANGELIST = "p4-prepare-changelist"; P4_POST_CHANGELIST = "p4-post-changelist"
    P4_PRE_SUBMIT = "p4-pre-submit"


STDIN_HOOK_NAMES: Final[frozenset[Hook]] = frozenset({
    Hook.PRE_PUSH, Hook.PRE_RECEIVE, Hook.POST_RECEIVE, Hook.POST_UPDATE, Hook.REFERENCE_TRANSACTION})


@dataclass
class HookContext:
    hook_name: Hook
    argv: list[str]


HookFn = Callable[[HookContext], int]


def log_hook(hook_name, *, msg: str | None = None) -> None:
    # NEVER use !r/repr — CI greps the literal "[dotfiles_githooks] pre-commit".
    line = f"[dotfiles_githooks] {hook_name}"
    if msg:
        line = f"{line}: {msg}"
    print(line, file=sys.stderr)


def drain_stdin_if_needed(hook_name: Hook) -> None:
    if hook_name not in STDIN_HOOK_NAMES or sys.stdin is None or sys.stdin.isatty():
        return
    try:
        sys.stdin.read()
    except OSError:
        pass


def hook_default(ctx: HookContext) -> int:
    if os.environ.get("DOTFILES_GITHOOKS_VERBOSE"):
        log_hook(ctx.hook_name)
    drain_stdin_if_needed(ctx.hook_name)
    return 0
