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

## CI status
- Branch pushed; `unit` workflow GREEN on ubuntu + macos + windows (run 27781322623).
  bash (linux/mac/win-gitbash), zsh (macos), pwsh (all) all pass. The CI loop is proven.
- (Benign annotation: actions/checkout@v4 Node20 deprecation — bump to @v5 sometime.)

## Next
- **Node 5** never-block merge + surfaced resolution: fetch→merge (newest-wins by committer-date,
  loser pinned to `refs/sync-losers/*` + `state/<repo>/conflicts.log`), modify/delete fallback,
  `-show`/`-resolve`. The node-4 tick is single-writer only (no fetch/merge yet); node 5 adds the
  multi-writer reconcile between step "commit" and "push" in `__df_tick_one`.
- Then nodes 6 (robustness) → 7 (doctor) → 8 (hooks) → 9 (timer) → 10 (migration/bootstrap)
  → 11 (interop) → 12 (README).

## How to run tests
- bash: `bash tests/run.sh bash`  (zsh: `zsh tests/run.sh zsh`)
- pwsh: `./tests/run.ps1`
- CI: push, then `gh run watch <id> --exit-status`, `gh run view <id> --log-failed`.
