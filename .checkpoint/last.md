# Last checkpoint

Branch: feat/sync-multi-repo-engine

## Last node DONE (local green; NOT yet CI-verified — orchestrator pushes + verifies)
- **Node 5** — never-block reconcile + surfaced resolution. `__df_reconcile` inserted BETWEEN the
  local commit and push in `__df_tick_one` (commit-before-merge preserved). With an upstream:
  derive branch from HEAD (detached -> skip), bounded push loop (3): reconcile (fetch origin
  <branch>; if behind, `merge --no-commit --no-ff FETCH_HEAD`) then push; non-ff rejection ->
  re-reconcile + retry; after ceiling LOG + skip (never fail tick, never block, work-tree intact).
  Resolution: non-overlapping auto-merge; same-line clash -> newest committer-date wins (compare
  `log -1 --format=%ct`; ties -> ours), loser pinned to LOCAL `refs/sync-losers/<enc>/<epoch>`
  (path non-alnum->`_`) + appended to `state/<repo>/conflicts.log` (LOCAL, never pushed);
  modify/delete -> edit-beats-delete (ls-files -u stage 2/3); unrelated histories -> REFUSE.
  Implemented `-show` (per-repo conflicts.log, greppable) + `-resolve <path>` (newest loser ref
  across repos -> `<path>.loser` via ls-tree/cat-file + winner/loser header). Both shells kept
  semantically identical. Harness: `mk_machine`/`Mk-Machine` (+ tick/write/read/pull_machine).
  Tests: tests/test_merge.{sh,ps1} (L2.2-L2.13). Local: bash 95/95 (merge 49), pwsh 92/92
  (merge 49), 0 SKIP. Existing dispatcher/config/tick suites still green.

## Next node (UNBLOCKED)
- **Node 6** — robustness invariants. Pre-step-1 stale-state recovery (abort leftover merge; clear
  aged index.lock with pid guard), discovery git-dir validation already partly present
  (`__df_is_repo`); add the full L5 BAD-path battery (L5.1-L5.28): missing config/engine/bare-repos,
  malformed config (already safe-refuses), corrupted/non-git/non-bare repos skipped fail-isolated,
  detached/missing-branch/no-upstream handling, unrelated histories (node 5 already REFUSEs in
  reconcile — add the explicit test + work-tree-untouched assert), index.lock/MERGE_HEAD recovery,
  concurrent-tick lock, read-only paths.

## Do NOT
- re-run a completed node; push to master; weaken tests; `git add -A` unscoped across $HOME;
  push `refs/sync-losers/*` or `state/*/conflicts.log` to any synced branch (LOCAL only).
