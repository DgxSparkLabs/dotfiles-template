"""Per-repo hook dispatch (node 8).

One shared stub set + one runner serves EVERY bare repo. Git invokes the firing repo's
``core.hooksPath`` stub, which execs this runner. The runner:

1. Identifies the firing repo by running ``git rev-parse --absolute-git-dir`` (git sets the
   firing repo's git-dir in the hook environment, so this resolves to the absolute bare
   git-dir regardless of the hook's cwd). The repo name is the git-dir basename.
2. Derives the dotfiles root: the git-dir is ``<root>/bare-repos/<repo>``, so
   ``root = git-dir/../..``.
3. Runs, if present AND runnable, in order:
     a. ``<root>/hooks/_shared/<hookname>``  (ALL repos)
     b. ``<root>/hooks/<repo>/<hookname>``   (THIS repo only)
   passing through the original hook args + stdin. If a per-repo hook exits non-zero, the
   runner returns that non-zero code (so e.g. a pre-commit hook can block the commit).

Robustness: if the repo identity can't be determined, we log a clear warning and return 0
(success) so an unrelated git operation is never crashed by the dispatcher.

Cross-platform invocation: per-repo hook scripts are POSIX ``sh`` scripts. We invoke them
the way git does — by their executable bit + ``#!/bin/sh`` shebang on POSIX, and via the
same ``sh`` interpreter on Windows (Git-for-Windows ships ``sh.exe``; the stub itself runs
under it). To stay portable AND honor L5.4 (a non-executable hook is silently skipped on
Linux/macOS, matching git's own behavior), we:
  - on POSIX: skip a hook that is not marked executable (git would too), and exec it directly
    so its shebang chooses the interpreter;
  - on Windows: there is no reliable executable bit, so we run any present hook file through
    ``sh`` (the same interpreter the stub runs under).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from .names import log_hook


def _verbose() -> bool:
    return bool(os.environ.get("DOTFILES_GITHOOKS_VERBOSE"))


def identify_repo() -> tuple[str, Path] | None:
    """Return (repo_name, dotfiles_root) for the firing repo, or None if undeterminable.

    repo_name = basename of the absolute git-dir; root = git-dir/../.. (git-dir lives at
    ``<root>/bare-repos/<repo>``).
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--absolute-git-dir"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as e:  # git not on PATH, etc.
        log_hook("dispatch", msg=f"cannot run git to identify repo: {e}")
        return None
    if out.returncode != 0:
        log_hook(
            "dispatch",
            msg=(
                "could not determine firing repo via 'git rev-parse --absolute-git-dir' "
                f"(rc={out.returncode}): {out.stderr.strip()}"
            ),
        )
        return None
    git_dir = out.stdout.strip()
    if not git_dir:
        log_hook("dispatch", msg="git rev-parse --absolute-git-dir returned empty output")
        return None
    gd = Path(git_dir)
    repo_name = gd.name
    # git-dir == <root>/bare-repos/<repo>  ->  root = git-dir/../..
    root = gd.parent.parent
    if not repo_name:
        log_hook("dispatch", msg=f"could not derive repo name from git-dir: {git_dir}")
        return None
    return repo_name, root


def _is_runnable(path: Path) -> bool:
    """A hook script we should run. On POSIX, mirror git: only an executable file runs
    (non-executable hooks are silently skipped). On Windows there is no reliable executable
    bit, so any present regular file is runnable (we'll invoke it via ``sh``)."""
    if not path.is_file():
        return False
    if os.name == "nt":
        return True
    return os.access(str(path), os.X_OK)


def _invoke(path: Path, argv: list[str]) -> int:
    """Run one per-repo hook script with the original args + inherited stdin/stdout/stderr.

    On Windows, invoke through ``sh`` (the same interpreter the stub runs under) since there
    is no executable bit and the OS can't run a ``#!/bin/sh`` script directly. On POSIX, exec
    the script directly so its shebang selects the interpreter (exactly as git would)."""
    if os.name == "nt":
        cmd = ["sh", str(path), *argv]
    else:
        cmd = [str(path), *argv]
    if _verbose():
        log_hook("dispatch", msg=f"running {path}")
    try:
        completed = subprocess.run(cmd, check=False)
    except OSError as e:
        log_hook("dispatch", msg=f"failed to run {path}: {e}")
        return 1
    return completed.returncode


def dispatch_per_repo_hooks(hook_name: str, argv: list[str]) -> int:
    """Run _shared then per-repo hook for the firing repo. Returns the first non-zero exit
    code encountered (so a hook can block the git operation), else 0.

    A failure to identify the repo is logged and treated as success (return 0) so we never
    crash an unrelated git operation."""
    ident = identify_repo()
    if ident is None:
        # Can't identify the repo: warn but don't block the user's git op.
        return 0
    repo_name, root = ident
    if _verbose():
        log_hook("dispatch", msg=f"repo={repo_name} root={root} hook={hook_name}")

    hooks_dir = root / "hooks"
    candidates = [
        hooks_dir / "_shared" / hook_name,  # ALL repos
        hooks_dir / repo_name / hook_name,  # THIS repo only
    ]
    for cand in candidates:
        if not _is_runnable(cand):
            if _verbose():
                log_hook("dispatch", msg=f"skip (absent/not-runnable) {cand}")
            continue
        rc = _invoke(cand, argv)
        if rc != 0:
            # A per-repo hook blocked the operation; surface its exit code.
            return rc
    return 0
