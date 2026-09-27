"""EXAMPLE handlers. ACTIVATE: cp user_hooks.example.py user_hooks.py; edit; commit it (TRACKED).
This *.example.py is never imported. One handler/hook; return non-zero to abort a pre-* hook.
Your handlers live here, never in the runner's system files."""
from __future__ import annotations
import subprocess
from dotfiles_githooks.names import Hook, HookContext
from dotfiles_githooks.registry import hook


@hook(Hook.PRE_COMMIT)
def regenerate_and_stage(ctx: HookContext) -> int:
    subprocess.run(["my-regen-tool"], check=True)     # your regeneration
    subprocess.run(["git", "add", "-A"], check=True)  # your staging choice
    return 0
