# Last checkpoint

Branch: feat/sync-multi-repo-engine

## Last node DONE (local green; CI not yet run for this node)
- **Node 4** — generic tick, SINGLE-WRITER path. `__df_tick`/`__df_tick_one` in both
  dispatchers (stub replaced). Gated by `__df_setting_tick` (default OFF). Stage scoped
  via `__df_setting_add`: `-u` tracked, or `-A` scoped to the repo's OWN tracked dirs
  (derived from `git ls-files` parent dirs) so it NEVER stages across $HOME / sibling repos.
  Commit only if staged; push only if upstream exists (else log+skip, never fail).
  `-tick` (no arg) loops `bare-repos/*` with fail-isolation; `-tick <repo>` ticks one.
  Harness: `mk_repo_with_origin`/`Mk-RepoWithOrigin` + `origin_dir`/`origin_tip` helpers.
  Tests: tests/test_tick.{sh,ps1} (L1.1-L1.6, L2.1). Local: bash 13/13 + full suite 46/46,
  pwsh 13/13 + full suite 43/43. No SKIPs.
- Dispatcher fix (PS): `[object[]] $rest = if (...)` — a one-element slice was unrolling to a
  scalar string and `@rest` exploded it char-by-char (recorded in PITFALLS).

## Next node (UNBLOCKED)
- **Node 5** — never-block merge + surfaced resolution. Insert fetch→merge (newest-wins by
  committer-date, loser pinned to refs/sync-losers/* + state/<repo>/conflicts.log) plus a
  modify/delete tree-conflict fallback BETWEEN commit and push inside `__df_tick_one`; then
  implement `-show`/`-resolve` (currently exit-3 stubs). Gate: L2.2-L2.13, L5.* merge cases.

## Do NOT
- re-run a completed node; push to master; weaken tests; `git add -A` unscoped across $HOME.
