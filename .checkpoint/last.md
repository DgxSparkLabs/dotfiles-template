# Last checkpoint

Branch: feat/sync-multi-repo-engine

## Last node DONE (local green; NOT yet CI-verified — orchestrator pushes + verifies)
- **Node 6** — robustness invariants in BOTH dispatchers (behavior-identical):
  - **Stale-state recovery** (`__df_recover_stale`, per repo, BEFORE staging): leftover MERGE_HEAD
    -> `merge --abort` (fallback `reset --hard HEAD`, then rm MERGE_*); stale `index.lock` older
    than `DOTFILES_LOCK_STALE` (default 60s) -> removed; a FRESH lock is LEFT (may be live).
  - **Concurrent-tick lock** (`__df_lock_acquire`/`__df_lock_release`): atomic `mkdir` /
    `New-Item -Directory` of `<real-git-dir>/dotfiles-tick.lock`. Live lock -> SKIP this cycle + log
    "already running" (NEVER blocks). Stale lock (> threshold) -> reclaimed. `__df_tick_one` now
    wraps `__df_tick_one_body` so the lock releases on EVERY exit path (bash: rc capture + release;
    pwsh: try/finally). `__df_gitdir_real` resolves the metadata dir for pure-bare AND non-bare.
  - Fail-isolation (loop continues past a corrupt/unreachable repo), detached-HEAD skip, no-upstream
    local-commit-only, unrelated-histories REFUSE were already correct (nodes 4/5); node 6 adds the
    explicit BAD-path tests + work-tree-untouched asserts.
- Tests: `tests/test_robust.{sh,ps1}` — L5.1, L5.3, L5.7, L5.14, L5.15, L5.16, L5.17, L5.19, L5.21,
  L5.22, L5.23, L5.27. (Already elsewhere: L5.8-L5.12 test_config, L5.13 test_dispatcher.)
  Harness gained `corrupt_repo`/`Corrupt-Repo`, `mk_nonbare_under_repos`/`Mk-NonbareUnderRepos`,
  `plant_stale_merge`/`Plant-StaleMerge`, `plant_stale_lock`/`Plant-StaleLock`,
  `plant_live_lock`/`Plant-LiveLock`, `has_tick_lock`/`Has-TickLock`, `bare_dir`/`Bare-Dir`.
- Local results: `bash tests/run.sh bash` -> 131 PASS / 0 FAIL / 1 SKIP; `pwsh tests/run.ps1` ->
  128 PASS / 0 FAIL / 1 SKIP. The SKIP is `L5.17-autotick` — NAMED reason: git-config forbids
  spaces in section names, so a spaced repo name can't key `<repo>.tick` (schema constraint, not a
  node-6 bug); the routing/discovery/passthrough half of L5.17 fully passes.

## Next node (UNBLOCKED)
- **Node 7** — `-doctor` (still the exit-3 stub). ls-files intersection across repos
  (overlap=error + `rm --cached` fix), no-upstream / detached / hooksPath-unset / tick-off /
  engine-behind checks each printing a fix (plan "G. Doctor — error cases"). Gate L0.13-L0.19;
  doctor-detection cases L5.6/L5.24/L5.25/L5.26.

## Do NOT
- re-run a completed node; push to master; weaken tests; `git add -A` unscoped across $HOME;
  push `refs/sync-losers/*` or `state/*/conflicts.log` to any synced branch (LOCAL only);
  hardcode `<dir>/MERGE_HEAD` — resolve the real git-dir (non-bare repos keep it in `<dir>/.git`).
