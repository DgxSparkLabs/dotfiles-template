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

## CI status
- Node 7 NOT YET pushed/CI-verified (orchestrator pushes + verifies). Prior:
- Node 6 CI-VERIFIED GREEN: run 27789885880, ubuntu+macos+windows ALL success (commit bd5b431). Prior:
- Node 5 CI-verified GREEN (run 27787968200, ubuntu+macos+windows). Prior:
- Branch pushed; `unit` workflow GREEN on ubuntu + macos + windows (run 27781322623).
  bash (linux/mac/win-gitbash), zsh (macos), pwsh (all) all pass. The CI loop is proven.
- (Benign annotation: actions/checkout@v4 Node20 deprecation — bump to @v5 sometime.)

## Next
- **Node 8** hook runner per-repo dispatch: runner identifies the firing repo via
  `git rev-parse --absolute-git-dir` -> basename, runs `hooks/_shared/<hook>` then
  `hooks/<repo>/<hook>`. Gate L1.7-L1.10, L5.4-L5.6, L4.4 (sh.exe identity).
- Then nodes 9 (timer) → 10 (migration/bootstrap) → 11 (interop) → 12 (README).

## How to run tests
- bash: `bash tests/run.sh bash`  (zsh: `zsh tests/run.sh zsh`)
- pwsh: `./tests/run.ps1`
- CI: push, then `gh run watch <id> --exit-status`, `gh run view <id> --log-failed`.
