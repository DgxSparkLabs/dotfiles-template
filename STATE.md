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

## CI status
- Node 5 NOT YET pushed/CI-verified (orchestrator pushes + verifies). Prior:
- Branch pushed; `unit` workflow GREEN on ubuntu + macos + windows (run 27781322623).
  bash (linux/mac/win-gitbash), zsh (macos), pwsh (all) all pass. The CI loop is proven.
- (Benign annotation: actions/checkout@v4 Node20 deprecation — bump to @v5 sometime.)

## Next
- **Node 6** robustness invariants: pre-step-1 stale-state recovery (abort leftover merge, clear
  aged `index.lock` with pid guard), discovery validates each bare-repos/* is a real git-dir,
  malformed-config / unrelated-histories safe REFUSE (node 5 already REFUSEs unrelated histories
  in reconcile; node 6 adds the full L5 battery + index.lock/MERGE_HEAD recovery + concurrent-tick
  lock). Gate: L5.* robustness cases.
- Then nodes 7 (doctor) → 8 (hooks) → 9 (timer) → 10 (migration/bootstrap) → 11 (interop)
  → 12 (README).

## How to run tests
- bash: `bash tests/run.sh bash`  (zsh: `zsh tests/run.sh zsh`)
- pwsh: `./tests/run.ps1`
- CI: push, then `gh run watch <id> --exit-status`, `gh run view <id> --log-failed`.
