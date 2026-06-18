# Last checkpoint

Branch: feat/sync-multi-repo-engine

## Last node DONE LOCALLY (not yet pushed/CI-verified — orchestrator pushes + verifies)
- **Node 8** — per-repo hook dispatch via runner repo-identity. Extended the Python runner
  (`githooks-runner/dotfiles_githooks/`):
  - NEW `dispatch.py`:
    - `identify_repo()` -> `(repo_name, root)` via `git rev-parse --absolute-git-dir`
      (basename = repo; root = git-dir/../.. since git-dir == `<root>/bare-repos/<repo>`).
      Can't determine -> log warning + return None (caller returns 0, never crashes git).
    - `dispatch_per_repo_hooks(hook, argv)` -> runs `<root>/hooks/_shared/<hook>` THEN
      `<root>/hooks/<repo>/<hook>` if present + runnable; passes args + inherited stdin;
      returns the FIRST non-zero rc (blocks the git op), else 0.
    - `_is_runnable`: POSIX => must be executable (mirrors git silently skipping non-exec
      hooks); Windows => any present file (no reliable exec bit).
    - `_invoke`: POSIX => run script directly (shebang picks interpreter); Windows => via `sh`.
  - `cli.py` wired: default hook handling FIRST (keeps `names.py` stdin-drain for STDIN hooks),
    then `_dispatch` to per-repo hooks; unknown hook names still dispatch; dispatch exceptions
    caught -> return 0.
- Tests: NEW `tests/test_hooks.{sh,ps1}` (greppable GOOD/BAD banners) — fire REAL git commits
  through `core.hooksPath` (not the dotfiles dispatcher), so the runner runs exactly as git
  invokes it (Windows leg = Git-for-Windows sh.exe = L1.10/L4.4). Cases: L1.7, L1.8, L1.9,
  L1.10, L5.4, L5.4b, L5.6, L5.block; L5.5 named-SKIP.
- Harness: `wire_hooks`/`Wire-HooksPath`, `write_hook`/`Write-Hook` (LF + shebang + chmod +x on
  POSIX), `mk_repo_hookable`/`Mk-RepoHookable`, `commit_in`/`Commit-In`, `Tree-Names`.
- CI: `unit.yml` now installs uv (`astral-sh/setup-uv@v5`) + `uv sync --locked --project
  githooks-runner` so the hook tests RUN on all 3 OS legs instead of failing-on-missing-uv.
  `run.{sh,ps1}` auto-discover `test_hooks.*`, so no per-test wiring needed.
- Local results: `bash tests/run.sh bash` -> 190 PASS / 0 FAIL / 3 SKIP (hooks 16/16);
  `pwsh tests/run.ps1` -> 187 PASS / 0 FAIL / 3 SKIP (hooks 16/16). The 3 skips: L5.4b
  (Windows: no executable bit — runs for real on ubuntu/macos), L5.5 (cannot safely unset uv
  from PATH on the shared runner), and the pre-existing L5.17-autotick.
- INFERRED identity assumption (L1.10/L4.4) verified locally on the Windows host: in-hook
  `git rev-parse --absolute-git-dir` returns the absolute bare git-dir; basename == repo name.
  Orchestrator's CI confirms macOS bash+zsh AND the Windows sh.exe leg.

## Next node (UNBLOCKED)
- **Node 9** — timer payload swap + multi-repo + jitter. The single installed OS unit/task/loop
  (keep all backends + their singleton names) gets its payload swapped to `dotfiles -tick`
  (loops `bare-repos/*`). Add `[timer] interval` (default 60) + `jitter` (±0-15s). Gate L3.*
  (install/enable/status/logs/uninstall singleton, fire-calls-tick, one-timer-many-repos,
  reboot/logon survival, Linux baked PATH, Windows non-admin VBS loop, jitter present).

## Do NOT
- re-run a completed node; push to master; weaken tests; `git add -A` unscoped across $HOME;
  make the runner depend on DOTFILES_ROOT (hooks run under plain git, no dispatcher env —
  derive root from git-dir/../..); ship a per-repo hook test script with CRLF or no shebang;
  treat a repo-identity failure as a hard error (return 0, never crash the user's git op).
