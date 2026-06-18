# Last checkpoint

Branch: feat/sync-multi-repo-engine

## Last node DONE (local green; NOT yet pushed/CI-verified — orchestrator pushes + verifies CI)
- **Node 9** — single timer fans out via `dotfiles -tick` + interval/jitter.
  - SWAPPED both backends' generated payload from the legacy baked single-repo add/commit/push to
    a call to the dispatcher's fan-out tick (loops `bare-repos/*`):
    - `timer/dotfiles-timer.sh` -> systemd user timer; generates `$DOTFILES_ROOT/.dotfiles-tick.sh`
      ending `exec bash "$DOTFILES_COMMON/dotfiles.sh" -tick`. Unit keeps the install-time PATH
      injection (so `uv` resolves) + now exports DOTFILES_COMMON/DOTFILES_ROOT.
      `OnUnitActiveSec=${interval}s`, `RandomizedDelaySec=${jitter}s`, per-fire `RANDOM%(jitter+1)`
      sleep baked into the payload.
    - `timer/dotfiles-timer.ps1` -> admin Task Scheduler task OR non-admin VBS-in-Startup
      (windowless) + detached pwsh loop. Generates `$DOTFILES_ROOT/.dotfiles-tick.ps1`
      (`. <dispatcher>; dotfiles -tick`, per-fire `Get-Random` jitter sleep) + a loop script that
      sleeps `interval`. Singleton task name `dotfiles-git-commit` kept.
  - Kept ALL backends + singleton names + every subcommand (install/reinstall/enable/disable/
    start/stop/status/logs/uninstall); reinstall idempotent.
  - Added `__df_setting_timer_jitter` (default 15) to BOTH dispatchers; interval reader existed.
  - NEW `tests/test_timer.{sh,ps1}` gating L3.1, L3.4, L3.9, L3.11, L3.12 (Linux PATH),
    L3.13 (Win non-admin VBS+loop windowless), L3.14, + install/uninstall/enable/disable/status/
    logs. Assert generated FILE CONTENT where the OS manager can't run; prove fire-calls-tick by
    calling `dotfiles -tick` DIRECTLY (2 enabled repos advance, 1 disabled does not). Live-manager
    bits are NAMED SKIPs.
  - CI: FOLDED into `unit.yml` (auto-discovered). `validate-timer.yml` -> manual-only SUPERSEDED.
- Local results: `bash tests/run.sh bash` 199 PASS / 0 FAIL / 6 SKIP (timer 9/0/3);
  `pwsh tests/run.ps1` 196 PASS / 0 FAIL / 4 SKIP (timer 9/0/1). No existing suite regressed.

## Node 9 CI FIX (this commit — first CI run was RED on ubuntu+macOS)
- `timer/dotfiles-timer.sh`: removed `sed -i` payload substitution (BSD/macOS sed misparse left
  `@TIMER_JITTER@` literal -> L3.11/L3.11b "got [0]"). Payload now baked via unquoted heredoc header
  + quoted body. Artifacts written BEFORE best-effort `systemctl` registration.
- `tests/test_timer.sh`: `have_systemd()` strengthened (requires `list-unit-files` ok AND
  `is-system-running` ∈ running/degraded) — GH ubuntu's fake `systemd --user` no longer fools it,
  so L3.1/L3.14/L3.x live-manager asserts NAMED-SKIP instead of failing.
- `.github/workflows/unit.yml`: removed the `XDG_RUNTIME_DIR` step (it only made the weak probe lie).
- `timer/dotfiles-timer.ps1`: `Install-Admin`/`Install-User` wrap registration + `Start-Process` in
  try/catch (artifacts already written) so a non-interactive runner can't abort the file-install.
- REAL asserts on all legs: L3.4/L3.11/L3.11b (artifact content), L3.12 (unit PATH), L3.13 (Win VBS+
  loop), L3.9/L3.4-disabled (direct `dotfiles -tick`). Re-verified local 199/0/6 + 196/0/4, 0 FAIL.

## Next node (UNBLOCKED)
- **Node 10** — migration + bootstrap.{sh,ps1}. Relocate the legacy single `~/.dotfiles` bare repo
  into `bare-repos/machine/` (work-tree files never move; only the git-dir relocates), split the
  engine into `common/`, uninstall the OLD timer before the move (no stale committer), re-home the
  dispatcher + `core.hooksPath`. Gate L1.14 (migration), L5.25 (partial migration -> -doctor flags
  the remaining step). After 2 + 9 (both done).

## Do NOT
- re-run a completed node; push to master; weaken tests; `git add -A` unscoped across $HOME.
- point the timer's DOTFILES_COMMON at a fake/temp root in tests (it sources the dispatcher from
  there — use the real engine checkout for COMMON, a temp dir for ROOT).
- assert generated pwsh-here-string content with fixed-space `-like` (aligned blocks have extra
  spaces — use `-match '...\s+=\s+...'`).
- compare `origin_tip <repo>` without an explicit ref (bare origin HEAD is unset -> "HEAD").
