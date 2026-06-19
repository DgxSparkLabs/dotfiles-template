# STATE

Implementing the sync multi-repo engine — plan: `~/.claude/plans/quizzical-juggling-jellyfish.md`.
Branch: `feat/sync-multi-repo-engine`. Build order = the plan's "Build order — task dependency tree".

## Done
- **Node 0 (restructure)** — engine content moved from old in-`$HOME` `.dotfiles/` to repo root
  (the template repo *is* `~/.dotfiles/common`): `githooks-runner/`, `githooks/` (un-hidden),
  `timer/dotfiles-timer.{sh,ps1}`. Rewrote `.gitattributes` (LF for stubs/sh/py + cross-OS
  normalization) and `.gitignore` (normal-repo, not the old `$HOME` whitelist). Hook stubs' relative
  `ROOT` resolution still correct.
- **Node 2 (dispatcher)** — `dotfiles.sh` + `dotfiles.ps1`: passthrough `dotfiles <repo> <git…>`,
  discovery under `bare-repos/` (skips non-git dirs), dash grammar (`-x`==`--x`), `-ls/-help/-config/
  -update/-timer` real; `-tick/-doctor/-show/-resolve` stubbed (return/exit 3, routable).
- **Node 1 (CI harness)** — `tests/` (harness.sh/.ps1, test_dispatcher.sh/.ps1, run.sh/.ps1,
  _invoke.ps1) with greppable `RESULT=PASS|FAIL` banners; `.github/workflows/unit.yml` (ubuntu+macos+
  windows × bash/zsh/pwsh). Old `validate-*.yml` set to `workflow_dispatch` only (reworked in nodes 8/9).
- Local verification on Windows: bash 12/12, pwsh 12/12 (L0.1-L0.7, L1.12-L1.13, L5.13).
- **Node 3 (per-repo config + safe defaults)** — hardened `__df_setting` in both dispatchers and added
  typed readers: `__df_setting_tick` (bool, default OFF; junk→default+warn), `__df_setting_add`
  (only `all`→`-A`, else→`-u` tracked; junk→default+warn), `__df_setting_timer_interval` (int,
  default 60; non-numeric→default+warn), and `__df_raw` (distinguishes unset vs malformed config:
  `git config -f` rc>=2 → safe refuse to default + "config malformed" warning, never crashes).
  `__df_setting` kept as a generic forward-compat reader. New tests `tests/test_config.{sh,ps1}`
  (L0.8-L0.12, L5.8-L5.12). Local: bash 21/21 + 12/12, pwsh 18/18 + 12/12.
- **Node 4 (generic tick, SINGLE-WRITER)** — `__df_tick` + `__df_tick_one` in both dispatchers,
  replacing the stub. Per repo: gated by `__df_setting_tick` (default OFF -> skip); stage scoped via
  `__df_setting_add` (`-u` tracked, or `-A` SCOPED to the repo's own tracked dirs derived from
  `git ls-files` parent dirs — NEVER `-A` across $HOME, so repos sharing `~/.config` stay isolated);
  commit only if staged (`<repo>: auto <iso-ts> <host>`); push only if an upstream exists (no
  upstream -> log+skip, never fail). `-tick` with no arg loops `bare-repos/*` (reusing `__df_is_repo`
  discovery) with FAIL-ISOLATION (one repo's git error is caught+logged, loop continues); `-tick
  <repo>` ticks one. Harness gained `mk_repo_with_origin`/`Mk-RepoWithOrigin` (fake local origin +
  upstream branch + seed) and `origin_dir/origin_tip` helpers. New tests `tests/test_tick.{sh,ps1}`
  (L1.1-L1.6, L2.1). Local: bash 13/13, pwsh 13/13. Fixed a dispatcher bug: PS `$rest` slice
  unrolled to a scalar string -> `@rest` exploded char-by-char (now `[object[]] $rest`).

- **Node 5 (never-block reconcile + surfaced resolution)** — inserted `__df_reconcile` BETWEEN
  the local commit and push inside `__df_tick_one` (commit-before-merge preserved). Per tick with
  an upstream: derive branch from HEAD (detached -> skip), then a bounded push loop (3): reconcile
  (`fetch origin <branch>`; if behind, `merge --no-commit --no-ff FETCH_HEAD`), then push; on
  non-fast-forward rejection re-reconcile + retry; after the ceiling LOG + skip (never fail the
  tick, never block, work-tree intact). Reconcile resolution: non-overlapping edits auto-merge;
  same-line clash -> newest committer-date wins (compare `log -1 --format=%ct <side> -- <path>`,
  `checkout --ours/--theirs`, ties -> ours), loser pinned to LOCAL `refs/sync-losers/<enc>/<epoch>`
  (path encoded non-alnum->`_` for ref-safety) + appended to `state/<repo>/conflicts.log` (LOCAL,
  outside the work-tree, never pushed); modify/delete -> edit-beats-delete (stage 2/3 detection via
  `ls-files -u`); unrelated histories -> REFUSE (surface + skip, node 6 owns recovery). FETCH_HEAD
  used (bare-clone ref mapping per PITFALLS). Implemented `-show` (per-repo conflicts.log or
  "(no conflicts)", greppable) and `-resolve <path>` (most-recent loser ref across repos -> write
  `<path>.loser` from the loser blob via ls-tree/cat-file, print winner-vs-loser header). Harness
  gained multi-machine helpers (`mk_machine`/`Mk-Machine` build machine N the init+remote-add way
  for a real upstream, `tick_machine`, `write/read/pull_machine`). New `tests/test_merge.{sh,ps1}`
  (L2.2-L2.13). Local: bash full suite 95/95 (merge 49), pwsh full suite 92/92 (merge 49), 0 SKIP.
  Note (PITFALLS): a plain `git clone --bare` sets NO fetch refspec -> no upstream; build the 2nd
  machine with init --bare + remote add + fetch + checkout -B like machine 1. L2.10 forces
  push-exhaust deterministically with a `pre-push` hook that exits 1 (no timing race).

- **Node 6 (robustness invariants)** — added to BOTH dispatchers, behavior-identical:
  (1) **stale-state recovery** `__df_recover_stale` runs per repo BEFORE staging: a leftover
  `MERGE_HEAD` (crash mid-merge) -> `merge --abort` (fall back to `reset --hard HEAD`, then rm of
  MERGE_* files) so the work-tree is clean; a stale `index.lock` OLDER than a threshold
  (`DOTFILES_LOCK_STALE`, default 60s) -> removed; a FRESH lock is LEFT (may be live).
  (2) **concurrent-tick lock** `__df_lock_acquire`/`__df_lock_release` — atomic `mkdir`
  (`New-Item -Directory`) of `<real-git-dir>/dotfiles-tick.lock`; a live tick's lock makes a second
  tick SKIP this cycle + log "already running" (never blocks); a stale lock (> threshold) is
  reclaimed. `__df_tick_one` now wraps the real work (`__df_tick_one_body`) so the lock is ALWAYS
  released on every exit path (bash: capture rc + release; pwsh: try/finally). `__df_gitdir_real`
  resolves the metadata dir (pure bare = the dir; non-bare = `<dir>/.git`) via
  `rev-parse --absolute-git-dir`. Fail-isolation (L5.7/L5.14), detached HEAD (L5.19), no-upstream
  (L5.21), unrelated-histories REFUSE (L5.22) were already correct from nodes 4/5 — Node 6 adds the
  explicit BAD-path tests + asserts work-tree-untouched. New `tests/test_robust.{sh,ps1}` (L5.1,
  L5.3, L5.7, L5.14, L5.15, L5.16, L5.17, L5.19, L5.21, L5.22, L5.23, L5.27). Harness gained
  `corrupt_repo`/`Corrupt-Repo`, `mk_nonbare_under_repos`/`Mk-NonbareUnderRepos`, `plant_stale_merge`,
  `plant_stale_lock`, `plant_live_lock`, `has_tick_lock` (+ PS equivs), `bare_dir`/`Bare-Dir`.
  Local: bash full 131/131 +1 SKIP, pwsh full 128/128 +1 SKIP, 0 FAIL. The single SKIP is
  `L5.17-autotick` (named reason: git-config forbids spaces in section names, so a spaced repo name
  can't key `<repo>.tick` — schema constraint, not a Node 6 bug; the routing/discovery/passthrough
  half of L5.17 fully passes).

- **Node 7 (-doctor)** — replaced the exit-3 stub in BOTH dispatchers (behavior-identical).
  Output per plan "F. Expected command outputs" / "G. Doctor — error cases": an `engine:` line
  (branch + up-to-date / N-behind / no-upstream / NOT-a-git-repo), a `repos:` block (per repo:
  name, branch|detached|none, upstream|(none), tick on/off, add tracked/all, hooks wired/MISSING),
  an `ownership:` overlap check, a `warnings:` block (each line carries a `fix ->` / `info ->`),
  and a final summary (`all checks passed` or `K error(s), W warning(s)`). Checks + fixes:
  (1) **overlap** = a path in >1 repo's `git ls-files` -> ERROR + path + both owners +
  `dotfiles <2nd-owner> rm --cached <path>` (the load-bearing exclusive-ownership invariant);
  (2) no upstream -> `push -u origin <branch>`; (3) detached/none HEAD -> `checkout <branch>`;
  (4) core.hooksPath unset -> `config core.hooksPath ...`; (5) hooksPath set but target dir
  MISSING (L5.6 / L5.25 partial migration) -> re-point at the engine githooks dir; (6) tick OFF
  -> INFO (`-config <repo>.tick on`); (7) tick ON + hooksPath unset (L5.24) -> louder warn;
  (8) engine behind upstream (L0.19, via `git -C <common> rev-list --count HEAD..@{u}`) ->
  `dotfiles --update`; (9) engine dir not a git repo (L5.26) -> ERROR. Exit code is nonzero ONLY
  when an ERROR exists (overlap, corrupt/non-git repo under bare-repos/, engine-not-git);
  warnings/info -> exit 0. A corrupt/non-git dir under bare-repos/ is noted + counted as ERROR.
  Helper added: `__df_hooks_target` (= `$DOTFILES_COMMON/githooks`). DISPATCHER CHANGE (both
  shells): `DOTFILES_COMMON` is now overridable via the env (`$env:DOTFILES_COMMON` / exported)
  so the engine-behind / engine-not-git tests can point it at a fake engine in a child process;
  the zsh re-exec now forwards `DOTFILES_COMMON` too. New tests `tests/test_doctor.{sh,ps1}`
  (L0.13-L0.19, L5.6, L5.24, L5.25, L5.26). Local: bash full 174/174 +1 SKIP, pwsh full 171/171
  +1 SKIP, 0 FAIL (doctor file = 43/43 each). The SKIP is the pre-existing `L5.17-autotick`.

- **Node 8 (per-repo hook dispatch)** — extended the Python runner (`dotfiles_githooks`) with a
  new `dispatch.py`, wired into `cli.py` AFTER the existing default hook handling (which still
  drains stdin for STDIN hooks via `names.py`). Flow: a bare repo's `core.hooksPath` ->
  engine `githooks/<hook>` stub -> `uv run ... -m dotfiles_githooks <hook>` -> runner.
  `identify_repo()` runs `git rev-parse --absolute-git-dir` (git sets the firing repo's git-dir
  in the hook env, resolved robustly regardless of cwd), takes its **basename** as the repo name,
  and derives the dotfiles **root = git-dir/../..** (git-dir lives at `<root>/bare-repos/<repo>`).
  `dispatch_per_repo_hooks()` then runs, if present AND runnable, **`<root>/hooks/_shared/<hook>`
  first, then `<root>/hooks/<repo>/<hook>`**, passing through the original args + inherited stdin;
  the FIRST non-zero per-repo hook exit is returned (so a pre-commit hook BLOCKS the commit).
  Robustness: if the repo can't be identified -> warn to stderr + return 0 (never crash an
  unrelated git op); any dispatch exception is caught + returns 0. Cross-platform invocation:
  on POSIX run the script directly (its `#!/bin/sh` shebang picks the interpreter) and SKIP a
  non-executable hook exactly as git does; on Windows (no reliable exec bit) run any present hook
  via `sh` (the same sh.exe the stub runs under). New tests `tests/test_hooks.{sh,ps1}` fire REAL
  git commits (not the dispatcher) so the runner is exercised exactly as git invokes it — L1.7
  (per-repo fires), L1.8 (isolation: nvim hook doesn't run on a machine commit), L1.9 (_shared
  fires for both repos), L1.10/L4.4 (identity basename == firing repo, incl. the Git-for-Windows
  sh.exe leg), L5.4 (missing hooks/ dirs -> commit succeeds, no crash), L5.4b (non-exec hook
  silently skipped — POSIX-only; SKIP on Windows), L5.6 (hooksPath -> missing dir -> git runs no
  hooks, commit still works), L5.block (non-zero hook blocks the commit). L5.5 (uv-missing) is a
  NAMED SKIP. Harness gained `wire_hooks`/`Wire-HooksPath`, `write_hook`/`Write-Hook` (LF + +x on
  POSIX), `mk_repo_hookable`/`Mk-RepoHookable`, `commit_in`/`Commit-In`, `Tree-Names`. `unit.yml`
  now installs uv + `uv sync --locked --project githooks-runner` so the hook tests RUN on all 3
  OS legs (not skip). Local: bash full 190/190 +3 SKIP, pwsh full 187/187 +3 SKIP, 0 FAIL
  (hooks file 16/16 each). The two NEW skips are L5.4b (Windows: no exec bit) + L5.5 (uv-unset);
  plus the pre-existing L5.17-autotick. Verified the INFERRED identity assumption locally on the
  Windows host (`git rev-parse --absolute-git-dir` inside the hook returns the absolute bare
  git-dir; basename == repo). The validate-githooks.yml workflow is still stale/manual-only
  (old `.dotfiles/` paths) — node 8 covers hook dispatch via `unit.yml`; a dedicated rework of
  validate-githooks is left to a later node if desired.

- **Node 9 (single timer fans out via `dotfiles -tick` + interval/jitter)** — swapped BOTH timer
  backends' generated payload from the legacy baked single-repo `git add/commit/push` to a call to
  the dispatcher's fan-out tick (loops `bare-repos/*`). Kept ALL backends + their singleton names
  (`dotfiles-git-commit` systemd unit/timer; Windows admin Task Scheduler task; Windows non-admin
  VBS-in-Startup + detached pwsh loop) and every subcommand (install/reinstall/enable/disable/
  start/stop/status/logs/uninstall). Paths updated to the engine layout (timer at
  `<root>/common/timer/`, dispatcher at `<root>/common/dotfiles.sh`; payload + units land under
  `$DOTFILES_ROOT`). 
  - **Payload**: `timer/dotfiles-timer.sh` generates `$DOTFILES_ROOT/.dotfiles-tick.sh` whose last
    line is `exec bash "$DOTFILES_COMMON/dotfiles.sh" -tick`; `timer/dotfiles-timer.ps1` generates
    `$DOTFILES_ROOT/.dotfiles-tick.ps1` ending `. <dispatcher>; dotfiles -tick`. The systemd unit
    keeps the install-time PATH injection (`$HOME/.local/bin:$HOME/bin:$HOME/.cargo/bin:$PATH`) so
    hook-driven `uv` resolves, and now also exports `DOTFILES_COMMON`/`DOTFILES_ROOT`.
  - **Interval + jitter**: both timers read `[timer] interval` (default 60) and `[timer] jitter`
    (default 15) by SOURCING the dispatcher and calling its readers — added `__df_setting_timer_jitter`
    to both `dotfiles.sh`/`.ps1` (interval reader already existed). Interval drives the cadence
    (`OnUnitActiveSec=${interval}s`; Task Scheduler `RepetitionInterval`; non-admin loop
    `Start-Sleep`). Jitter is applied TWO ways for de-sync: systemd `RandomizedDelaySec=${jitter}s`,
    AND a per-fire random `0..jitter` sleep baked into the payload (`RANDOM % (jitter+1)` in sh;
    `Get-Random` in pwsh) so the jitter value is present + inspectable in the generated artifact.
  - **Tests**: NEW `tests/test_timer.{sh,ps1}` (greppable GOOD/SKIP). Assert generated FILE CONTENT
    (payload calls `-tick`; jitter baked; interval/jitter from config honored; systemd unit bakes
    PATH incl. `~/.local/bin`; Windows non-admin VBS windowless + loop generated) and prove
    fire-calls-tick by calling `dotfiles -tick` DIRECTLY over 2 enabled repos (both origins advance)
    + a disabled repo (does NOT advance) = L3.9 one-timer-many-repos. install/reinstall idempotency
    asserted via file-presence count (==1 unit pair / ==3 user-mode files) and, where the live
    manager is reachable, the registered unit/task count. Live-manager-only transitions
    (enable/disable/status/logs) are RESULT=SKIP with NAMED reasons ("systemd user session
    unavailable on this runner" / "Task Scheduler needs an admin/interactive session"); the macOS
    /non-Windows pwsh leg SKIPs the whole Windows backend with a named reason.
  - **CI wiring**: FOLDED into `unit.yml` (run.{sh,ps1} auto-discover test_timer.*).
    `validate-timer.yml` rewritten to a manual-only no-op marked SUPERSEDED.
  - Local: `bash tests/run.sh bash` 199/0/6 (timer 9/0/3); `pwsh tests/run.ps1` 196/0/4
    (timer 9/0/1). The timer SKIPs are the live-manager bits (no systemd session under Git-Bash;
    Task Scheduler needs admin) — all NAMED.

- **Node 9 CI FIX (RED on ubuntu+macOS -> green)** — first CI run after node 9 failed:
  L3.1/L3.14/L3.x "expected [1] got [0]" (ubuntu+macOS) and L3.11/L3.11b "got [0]" (ubuntu+macOS).
  Two root causes + fixes (full detail in PITFALLS "install must write artifacts before best-effort
  registration"):
  1. `timer/dotfiles-timer.sh` baked the payload via `sed -i` -> BSD/macOS sed misparsed `-i` (next
     token = backup suffix) so `@TIMER_JITTER@` was never substituted (L3.11/L3.11b). FIX: removed
     `sed` — payload header is now an UNQUOTED heredoc (values baked at write time) + a QUOTED
     heredoc body (runtime refs un-expanded). Artifacts are written BEFORE the best-effort
     `systemctl` registration (already returned 0 on enable-failure).
  2. GH ubuntu has no usable `systemd --user`: `enable` registers nothing yet the old probe
     (`systemctl --user show-environment`) passed, so the live unit-count asserts ran and read 0.
     FIX: `have_systemd()` now requires `systemctl --user list-unit-files` to succeed AND
     `is-system-running` ∈ {running,degraded}; the live-manager asserts (L3.1/L3.14 unit count,
     L3.x enable/disable/status/logs) take a NAMED SKIP otherwise. Removed the `XDG_RUNTIME_DIR`
     step from `unit.yml` (it only made the weak probe lie). REAL (non-skipped) asserts on every
     leg: L3.4/L3.11/L3.11b (artifact content incl. jitter/interval), L3.12 (unit PATH injection),
     L3.13 (Win non-admin VBS+loop), L3.9 + L3.4-disabled (direct `dotfiles -tick` fan-out).
     `dotfiles-timer.ps1` `Install-Admin`/`Install-User` registration/`Start-Process` now wrapped in
     try/catch so a non-interactive runner can't abort the file-install.
  - Local re-verify (Windows, both probes SKIP live bits as on CI): bash 199/0/6 (timer 9/0/3),
    pwsh 196/0/4 (timer 9/0/1), 0 FAIL. Committed (NOT pushed); orchestrator re-verifies CI.

- **Node 9 CI FIX #2 (ubuntu STILL RED -> deterministic opt-in gate)** — CI FIX #1's strengthened
  `have_systemd()` probe STILL passed on GH ubuntu (the fake `systemd --user` answers
  `list-unit-files` AND reports running/degraded) while enabling a user unit registered ZERO findable
  units, so L3.1/L3.14/L3.x ran and failed "expected [1] got [0]" again. FIX (tests only): replaced
  the usability PROBE with a DETERMINISTIC OPT-IN — the live-manager asserts run ONLY when
  `DOTFILES_TIMER_LIVE` ∈ {1,true} (env unset on CI -> always NAMED SKIP). `test_timer.sh` dropped
  `have_systemd()` for `timer_live()` + shared `LIVE_SKIP_REASON`; `test_timer.ps1` added `Timer-Live`
  (= opt-in AND admin) + `$LiveSkipReason`. `unit.yml` UNCHANGED (never sets the var). Asserts are NOT
  deleted — real machine runs them via `DOTFILES_TIMER_LIVE=1 bash tests/run.sh bash`. REAL on every
  leg: L3.4 (payload `-tick` + direct fan-out: 2 enabled advance, disabled untouched), L3.9,
  L3.11/L3.11b (interval+jitter artifact), L3.12 (unit PATH), L3.13 (Win VBS+loop), file-content
  singleton counts. Local re-verify (Windows; live bits SKIP as on CI): bash 199/0/6 (timer 9/0/3),
  pwsh 196/0/4 (timer 9/0/1), 0 FAIL. Committed (NOT pushed); orchestrator re-verifies CI.

- **Node 9 CI FIX #3 (windows RED -> force user-mode for the non-admin file asserts)** — after FIX #2,
  windows went RED: L3.1/L3.14 "expected [3] got [1]". Cause: GH windows runners run ELEVATED, so
  `dotfiles-timer.ps1 install` took the ADMIN Task Scheduler branch (writes only the payload, 1 file),
  but the non-admin file-presence asserts expect the USER backend's 3 files (VBS launcher + loop +
  payload). FIX (test seam, no real assert weakened): `dotfiles-timer.ps1` `Test-IsAdmin` now honors
  `DOTFILES_TIMER_FORCE_USER` ∈ {1,true} -> returns `$false` (forces the user-mode install path
  regardless of real elevation); default behavior (env unset) unchanged. `test_timer.ps1` L3.1/L3.14
  set `$env:DOTFILES_TIMER_FORCE_USER='1'` around install/reinstall (try/finally: uninstall to clean
  up the spawned loop + Startup VBS, then unset the var) so the 3 user-mode artifacts are generated
  deterministically on ANY windows runner. Live Task-Scheduler count/transition asserts stay gated
  behind `DOTFILES_TIMER_LIVE` (FIX #2) — unchanged. Added an end-of-file safety-net that stops any
  detached `*.dotfiles-tick-loop.ps1` pwsh the non-uninstalling install asserts (L3.4/L3.11b/L3.13/
  L3.x) spawn on a non-admin dev host (CI runners are ephemeral; this just keeps the dev box tidy).
  Local re-verify (Windows host; live bits SKIP): `pwsh tests/run.ps1` 9/0/1 timer, 0 FAIL overall;
  `bash tests/run.sh bash` 9/0/3 timer, 0 FAIL overall (unchanged); confirmed NO runaway loop survives.
  Committed (NOT pushed); orchestrator re-verifies CI.

- **Node 10 (migration + bootstrap)** — fresh-machine bootstrap + legacy->container migration.
  - NEW `bootstrap.{sh,ps1}` (engine root; ship in `common/`): plan "A. First-run setup" steps 1-4
    in one run, leaving step 5 (verify + `dotfiles -config machine.tick on`) to the user (tick
    defaults OFF). (1) clone engine -> `~/.dotfiles/common` (`--engine`/$DOTFILES_ENGINE_URL);
    (2) append the profile source-guard ONCE (idempotent marker-substring check; bash/zsh ->
    ~/.bashrc|~/.zshrc, pwsh -> $PROFILE; DOTFILES_PROFILE override for tests); (3) bare-clone the
    machine repo -> `bare-repos/machine` on a per-machine branch (default = hostname), set the
    fetch refspec + status.showUntrackedFiles=no, safe checkout that BACKS UP conflicting work-tree
    files (.bak-<ts>), then wire core.hooksPath; (4) `dotfiles -timer install`. Idempotent +
    re-runnable.
  - NEW `migrate.{sh,ps1}` (engine root) + `dotfiles -migrate` verb (sh re-execs `migrate.sh` under
    bash; ps invokes `migrate.ps1`). Safe step order: (a) detect legacy (bare git-dir AT $ROOT:
    HEAD+objects+refs there); (b) STOP the OLD timer FIRST (systemctl/launchctl by legacy singleton
    name + new-engine uninstall) BEFORE moving the git-dir (stale committer guard); (c) MOVE only the
    git metadata from $ROOT -> `bare-repos/machine/` (skips common/bare-repos/hooks/config/state +
    the legacy `.dotfiles` helper subtree; work-tree files in $HOME never move); (d) ensure engine at
    common/ (clone if missing); (e) set machine core.hooksPath -> engine githooks; (f) strip legacy
    `alias dotfiles*=` / old-helper source lines from the profile + append the new dispatcher guard;
    (g) `dotfiles -timer install`. Aborts clearly on ambiguous state (legacy AND migrated both
    present) or no-legacy-no-machine.
  - Node 7 doctor ALREADY flags the L5.25 partial migration (git-dir moved but core.hooksPath unset
    -> hooks:MISSING + "core.hooksPath not set" fix) — no doctor change needed.
  - NEW `tests/test_migration.{sh,ps1}`: L1.14 (full legacy migration: machine git-dir valid; ALL
    work-tree files byte-identical; old top-level metadata gone; `machine status` clean; per-repo
    hook fires; `-ls` shows machine), L1.14b (idempotent re-run), L1.14c (abort on no-legacy-no-
    machine), L5.25 (partial migration -> doctor warns + remaining step, exit 0), BOOT-idempotent
    (double profile-append != duplicate; full layout from empty via LOCAL bare origins, no network).
    Fake HOME + DOTFILES_ROOT via new_env; NEVER touches real ~/.dotfiles or profile.
  - Local: `bash tests/run.sh bash` overall rc=0 (migration 23/0/0); `pwsh tests/run.ps1` overall
    rc=0 (migration 23/0/0). No suite regressed. Committed (NOT pushed); orchestrator verifies CI.

- **Node 11 (cross-OS interop chain, L4.1-L4.6)** — NEW `.github/workflows/interop.yml`: a
  CHAINED 4-job workflow (`needs:` sequenced) seed (ubuntu) -> win (windows) -> mac (macos) ->
  verify (ubuntu). The SAME bare `origin` repo travels leg-to-leg as a TAR artifact (unique name
  per leg: origin-after-{seed,win,mac}; upload-artifact@v4 is immutable). Each leg checks out the
  engine, installs uv (mirrors unit.yml), unpacks the prior origin, runs an OS-appropriate step,
  re-packs + uploads. NEW `tests/interop_step.sh` — ONE bash script run on every leg (Git-Bash on
  the windows leg = the hooks' sh.exe surface; a pwsh port would test a different path and prove
  nothing about cross-OS sameness). Subcommands: `seed` (fresh origin + initial committed state),
  `leg <os>` (clone machine wired to the engine + shared origin, edit text/nested/exec, run the
  REAL `dotfiles -tick` to commit+reconcile+push), `verify` (fresh clone + L4 asserts), `clash`
  /`verify-clash` (L4.5), `hookid` (L4.4). NEW `tests/interop_step.ps1` — thin wrapper that locates
  Git-for-Windows bash (PREFERS Program Files\Git over the WSL System32 stub) and delegates.
  How each L4.x is asserted (greppable RESULT banners; reads blobs via ls-tree+cat-file, never the
  Git-for-Windows `<rev>:<path>` colon):
  - **L4.1 round-trip** — the covered text.conf accumulates one line per OS; verify asserts all OS
    edits present AND the blob has NO CR (no whole-file line-ending churn). CONTROL: `.gitattributes`
    seeds `* text=auto` PLUS `legacy/raw.txt -text` (opt-out). raw.txt is seeded CRLF and STAYS CRLF
    in the blob while text.conf is LF — the only difference is the `-text` attribute, proving
    normalization is caused by `.gitattributes`, not luck (L4.1-control asserts the CRLF survives;
    if it went LF the attribute would be decorative = FAIL).
  - **L4.2 line endings** — text edited on Windows (CRLF written on purpose) is stored LF in the
    repo blob (covered=LF asserted alongside control=CRLF so LF-storage is provably the
    normalization, not a no-op). CR detected by COUNTING 0x0d bytes via `od` (Git-Bash `grep $'\r'`
    falsely reports no-CR — see PITFALLS).
  - **L4.3 file mode** — exec script seeded 100755 on the ubuntu seed leg; verify reads the TREE
    mode (`ls-tree` first field, platform-independent) and asserts 100755 stable after the Windows
    leg (which never rewrites it) + macOS leg (chmod +x). NAMED SKIP only on a LOCAL Windows
    dry-run (core.fileMode=false there can't seed an exec bit) — runs for real on CI.
  - **L4.4 hook identity under sh.exe** — the windows leg wires core.hooksPath to the engine stubs,
    fires a REAL commit (runner via Git-for-Windows sh.exe), asserts `git rev-parse
    --absolute-git-dir` basename == `interop`. Reuses node 8 dispatch; SKIP (named) if uv absent.
  - **L4.5 cross-OS clash newest-wins** — windows writes the same line @2021 (older), macOS @2022
    (newer) and pushes LAST; verify asserts macOS wins. A real clash is forced by rewinding each
    clash leg's local branch to the seed commit before editing (divergent parents, not a
    fast-forward). Proven date-based not push-order by the reverse case locally (older pushes last
    -> still loses).
  - **L4.6 path handling** — a nested `.config/interop/app/sub/dir/file` edited on each OS yields ONE
    forward-slash entry in `ls-files` (no backslash paths, no duplicates); content from every OS
    survives (L4.6-content).
  - `unit.yml` is UNCHANGED (matrix intact); interop.yml is a separate workflow on push +
    workflow_dispatch. interop_step.{sh,ps1} are NOT `test_*` so run.{sh,ps1} never auto-run them.
  - Local (Windows host) FULL chain in exact workflow order (seed->leg win->hookid win->clash win->
    leg mac->clash mac->verify->verify-clash): verify 5/0/1 (L4.3 the named Windows-seed SKIP),
    verify-clash L4.5 PASS, hookid L4.4 PASS; reverse-clash also PASS (committer-date proof).
    Existing suites UNBROKEN: `bash tests/run.sh bash` overall rc=0 (per-file 21/12/43/16+2skip/49/
    23/36+1skip/13/9+3skip); `pwsh tests/run.ps1` overall rc=0 (18/12/43/16+2/49/23/36+1/13/9+1).
    The true multi-OS chain (esp. L4.3 755 + macOS leg) runs only on CI — authored correct-by-
    construction; orchestrator verifies.

- **Node 11 CI FIX (windows leg RED -> Git-Bash-safe tar paths)** — first CI run of the chained
  `interop` workflow: `seed` (ubuntu) PASSED, `win` (windows) FAILED at the unpack/pack tar steps,
  mac+verify skipped. Error:
  `tar: D\:\a\\dotfiles-template\\dotfiles-template/_interop: Cannot open: No such file or directory`
  + `Error is not recoverable: exiting now` (exit 2). Cause: `INTEROP_WORK` =
  `${{ github.workspace }}/_interop` expands to a Windows drive-letter path on the windows runner;
  the steps run under `shell: bash` (Git-for-Windows MSYS bash) and MSYS `tar` can't open a `D:\…`
  `-C` target (it mangles the drive colon as a remote host + the backslashes). `mkdir -p` did NOT
  help. FIX (YAML only, applied to ALL 6 pack/unpack steps on ALL legs so behavior never diverges):
  each step now resolves an MSYS-safe dir first —
  `WORK="$INTEROP_WORK"; command -v cygpath >/dev/null 2>&1 && WORK="$(cygpath -u "$INTEROP_WORK")"`
  (no-op on ubuntu/macos where cygpath is absent; `D:\a\…` -> `/d/a/…` on windows), then
  `mkdir -p "$WORK"` before extract and `tar -C "$WORK" … origin.git` (relative members + `-C`,
  never an absolute Windows member). interop_step.sh UNCHANGED (it invokes no tar; its git/file ops
  accept native Windows paths). Reproduced the exact error locally under Git-Bash with a Windows-form
  path and confirmed the cygpath conversion makes mkdir+unpack+repack succeed (symbolic HEAD
  survives). Suites still green: `bash tests/run.sh bash` rc=0, `pwsh tests/run.ps1` rc=0. Committed
  (NOT pushed); orchestrator re-verifies the chained interop workflow on CI. PITFALLS entry added
  ("MSYS/Git-Bash tar can't open absolute D:\ drive-colon paths").

- **Node 12 (README rewrite) — DONE locally** — fully rewrote `README.md` for the multi-repo
  engine architecture, matched to shipped behavior (no invented features): one-paragraph
  framing + "when NOT to use this / Syncthing"; on-disk `$HOME` layout + profile source/dot-
  source lines; first-run setup (bootstrap) + adding repos + the verify-then-enable setup
  contract (tick defaults OFF); the `dotfiles` command (grammar: bare token=repo passthrough,
  dashed verb 1-or-2 dashes, repo-wins-over-verb; per-verb table `-ls -config -tick -doctor
  -show -resolve -timer -update -migrate -help`) with representative outputs; per-repo config
  (`~/.dotfiles/config` git-config syntax, defaults table + WHY: tick off / add tracked /
  scoped -A, junk+malformed safe-refuse) + `[timer] interval`/`jitter`; per-repo + `_shared`
  hooks (runner identifies repo via `git rev-parse --absolute-git-dir`, stylua example, uv +
  GfW prereqs); the single timer (one unit fans out via `-tick`, subcommands, 3 backends,
  interval/jitter); managing files (add/remove/move-ownership) + `-doctor` (overlap = load-
  bearing invariant, sample error+fix); migration (`-migrate`: stop old timer → move git-dir
  → wire hooksPath → swap aliases, work-tree never moves); caveats (secret-safety ~60s push,
  same-line-loss newest-wins/recoverable, gc-prune reaps losers); condensed "a day with it".
  HONESTY corrections vs the plan's Appendix F: `-ls` prints one repo per line (not space-
  separated); `-show`/`-resolve` outputs use the ACTUAL code format (tab-separated logline;
  `clash in repo <repo>  loser=<sha>`); `-timer status` documented as NATIVE scheduler output
  (systemctl/schtasks), NOT the plan's invented pretty `timer:/autostart:/running:` block
  which the code does not emit. Also fixed stale `githooks-runner/README.md` (path
  `.githooks/` -> `common/githooks/`, broken `../../README.md` link -> `../README.md`,
  dispatcher invocation form). Tests unbroken: `bash tests/run.sh bash` rc=0 (9/0/3 timer),
  `pwsh tests/run.ps1` rc=0 (9/0/1 timer). Docs node only — NO code/test changes. This is the
  LAST node; GOAL essentially met pending CI. Committed (NOT pushed); orchestrator pushes +
  verifies CI.

## CI status
- Node 12 (README rewrite) committed locally; docs-only, tests rc=0 both shells. Prior:
- Node 11 CI FIX committed locally (Git-Bash-safe tar paths on the windows leg via cygpath -u +
  relative `-C` + mkdir); NOT YET pushed/CI-verified — orchestrator re-runs the chained interop
  workflow. Prior:
- Node 11 committed locally (interop.yml + interop_step.{sh,ps1} + pitfalls); first CI run had the
  windows leg RED (MSYS tar abs-path) — fixed above. The chained interop workflow's true value
  (L4.3 exec-bit seeded on ubuntu, the macOS leg, the real 3-OS round-trip) can ONLY run on CI —
  orchestrator pushes + watches it. Prior:
- Node 10 committed locally (bootstrap + migrate + tests); NOT YET pushed/CI-verified. Prior:
- Node 9 CI FIX #3 committed locally (force user-mode via `DOTFILES_TIMER_FORCE_USER` for the windows
  non-admin file asserts); NOT YET pushed/CI-verified (orchestrator re-verifies). Prior:
- Node 9 CI FIX #2 committed locally (live-manager asserts gated behind `DOTFILES_TIMER_LIVE`
  opt-in; usability probe removed); NOT YET pushed/CI-verified (orchestrator re-verifies). Prior:
- Node 9 CI FIX #1 committed (artifacts-before-registration + strong systemd probe + no
  XDG_RUNTIME_DIR) — strong probe still let ubuntu live asserts run/fail; superseded by FIX #2. Prior:
- Node 9 first CI run RED on ubuntu+macOS (sed -i + weak systemd probe) — now fixed. Prior:
- Node 8 NOT YET pushed/CI-verified (orchestrator pushes + verifies). Prior:
- Node 7 CI-VERIFIED GREEN: run 27791782158, ubuntu+macos+windows ALL success. Prior:
- Node 6 CI-VERIFIED GREEN: run 27789885880, ubuntu+macos+windows ALL success (commit bd5b431). Prior:
- Node 5 CI-verified GREEN (run 27787968200, ubuntu+macos+windows). Prior:
- Branch pushed; `unit` workflow GREEN on ubuntu + macos + windows (run 27781322623).
  bash (linux/mac/win-gitbash), zsh (macos), pwsh (all) all pass. The CI loop is proven.
- (Benign annotation: actions/checkout@v4 Node20 deprecation — bump to @v5 sometime.)

## Next
- **Node 12** README full rewrite (layout, dispatcher grammar incl. `-x`==`--x`, per-repo config &
  hooks, framing paragraph, migration, Syncthing caveat, same-line-loss warning).

## How to run tests
- bash: `bash tests/run.sh bash`  (zsh: `zsh tests/run.sh zsh`)
- pwsh: `./tests/run.ps1`
- CI: push, then `gh run watch <id> --exit-status`, `gh run view <id> --log-failed`.
