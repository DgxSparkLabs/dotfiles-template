# Last checkpoint

Branch: feat/sync-multi-repo-engine

## Last node DONE (CI-VERIFIED GREEN: run 27796700977, ubuntu+macos+windows ALL success)
- Node-9 commit chain: ed3a873 impl -> 8b15eca (BSD sed→heredoc bake + best-effort registration)
  -> ec8453a (live-manager asserts gated behind DOTFILES_TIMER_LIVE opt-in; GH systemd probe lies)
  -> 0847c80 (GH windows runs ADMIN → DOTFILES_TIMER_FORCE_USER seam to test non-admin VBS+loop).
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

## Node 9 CI FIX #3 (this commit — windows RED: "expected [3] got [1]")
- After FIX #2 windows went RED: L3.1-install-singleton / L3.14-reinstall-idempotent failed
  "exactly one launcher+loop+payload generated (non-admin) expected [3] got [1]". Cause: GH windows
  runners run ELEVATED, so `dotfiles-timer.ps1 install` took the ADMIN Task Scheduler branch (writes
  ONLY the payload = 1 file) while the non-admin file-presence asserts expect the USER backend's 3
  artifacts (VBS launcher + loop + payload).
- FIX (test seam, NO real assert weakened):
  - `timer/dotfiles-timer.ps1` `Test-IsAdmin`: returns `$false` when
    `DOTFILES_TIMER_FORCE_USER` ∈ {1,true,TRUE,True} -> forces the user-mode install path regardless
    of real elevation. Default (env unset): genuine auto-detect, behavior unchanged.
  - `tests/test_timer.ps1` L3.1/L3.14: set `$env:DOTFILES_TIMER_FORCE_USER='1'` around
    install/reinstall (try/finally: `uninstall` to stop the spawned loop + remove the Startup VBS,
    then unset the var) so the 3 user-mode files are generated deterministically on ANY windows runner.
  - Live Task-Scheduler count/transition asserts stay gated behind `DOTFILES_TIMER_LIVE` (FIX #2).
  - Added an end-of-file safety-net killing any detached `*.dotfiles-tick-loop.ps1` pwsh the
    non-uninstalling install asserts (L3.4/L3.11b/L3.13/L3.x) spawn on a non-admin dev host.
- Local re-verify (Windows host; live bits SKIP as on CI): `pwsh tests/run.ps1` timer 9/0/1, 0 FAIL
  overall; `bash tests/run.sh bash` timer 9/0/3, 0 FAIL overall (unchanged). Confirmed NO runaway
  loop survives the run.

## Node 9 CI FIX #2 (ubuntu STILL RED on the live-manager asserts)
- After CI FIX #1 the strengthened `have_systemd()` probe STILL passed on GH ubuntu (the fake
  `systemd --user` reports running/degraded AND `list-unit-files` succeeds) — but enabling a user
  unit there registers ZERO findable units, so L3.1/L3.14/L3.x ran and failed "expected [1] got [0]".
- FIX (tests only): replaced the usability PROBE with a DETERMINISTIC OPT-IN gate. The LIVE-MANAGER
  asserts now run ONLY when `DOTFILES_TIMER_LIVE` ∈ {1,true} (env unset on CI -> always SKIP).
  - `tests/test_timer.sh`: dropped `have_systemd()`; added `timer_live()` (env check) + a shared
    `LIVE_SKIP_REASON`. L3.1/L3.14 registered-unit count + L3.x enable/disable/status/logs gate on
    `timer_live`; otherwise `_skip` with the named reason. Artifact-content count asserts
    (one .timer + one .service generated) and the direct `dotfiles -tick` fan-out STAY real.
  - `tests/test_timer.ps1`: added `Timer-Live` (= `DOTFILES_TIMER_LIVE` opt-in AND admin session) +
    `$LiveSkipReason`. L3.1/L3.14 registered-task count + L3.x enable/disable gate on `Timer-Live`;
    the non-admin file-presence fallback (launcher+loop+payload count) stays real. Reason named.
  - `unit.yml` UNCHANGED — it does NOT set `DOTFILES_TIMER_LIVE`, so CI skips the live bits.
  - Real on every leg (never skipped): L3.4 (payload calls `-tick` + direct fan-out advances 2
    enabled repos, disabled untouched), L3.9, L3.11/L3.11b (interval+jitter in artifact),
    L3.12 (unit PATH injection), L3.13 (Win non-admin VBS+loop). Run live on a real box with
    `DOTFILES_TIMER_LIVE=1 bash tests/run.sh bash`.
  - Local re-verify (Windows; live bits SKIP as on CI): bash 199/0/6 (timer 9/0/3),
    pwsh 196/0/4 (timer 9/0/1), 0 FAIL.

## Node 9 CI FIX #1 (first CI run was RED on ubuntu+macOS)
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
