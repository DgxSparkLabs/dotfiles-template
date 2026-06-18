# Last checkpoint

Branch: feat/sync-multi-repo-engine

## Last node DONE (local green; NOT yet pushed/CI-verified — orchestrator pushes + verifies)
- **Node 7** — `-doctor` in BOTH dispatchers (behavior-identical), replacing the exit-3 stub.
  Output per plan "F. Expected command outputs" / "G. Doctor — error cases":
  - `engine:` line — branch + (up to date | N commit(s) behind <upstream> | no upstream |
    NOT a git repo). Behind-detection: `git -C "$DOTFILES_COMMON" rev-list --count HEAD..@{u}`
    guarded (no upstream -> skip silently).
  - `repos:` block — per repo: name, branch | `detached` | `none`, upstream | `(none)`,
    `tick:on/off`, `add:tracked/all`, `hooks:wired/MISSING`. Iterates discovered repos; a
    corrupt/non-git dir under bare-repos/ is noted + counted as an ERROR.
  - `ownership:` — overlap = a path in >1 repo's `git ls-files`. Clean -> "N paths across M
    repos, no overlaps". Overlap -> "OVERLAP" + the path + "tracked by: <a>, <b>" + fix
    `dotfiles <2nd-owner> rm --cached <path>` (THE load-bearing exclusive-ownership invariant).
  - `warnings:` block — each line carries an actionable `fix ->` (or `info ->` for tick-off):
    no upstream (L0.15 -> `push -u origin <branch>`), detached/none HEAD (L0.16 ->
    `checkout <branch>`), hooksPath unset (L0.17 -> `config core.hooksPath ...`), hooksPath set
    but target dir MISSING (L5.6 / L5.25 partial migration -> re-point at engine githooks),
    tick off (L0.18 -> INFO `-config <repo>.tick on`), tick ON + hooksPath unset (L5.24 ->
    louder warn), engine behind (L0.19 -> `dotfiles --update`), engine not a git repo (L5.26 ->
    ERROR).
  - Final summary: `all checks passed` (exit 0) OR `K error(s), W warning(s)` (exit 1).
  - Exit code nonzero ONLY when at least one ERROR (overlap / corrupt-or-non-git repo /
    engine-not-git). Warnings + info -> exit 0.
- Helper added: `__df_hooks_target` (= `$DOTFILES_COMMON/githooks`), both shells.
- DISPATCHER CHANGE (both shells, for testability): `DOTFILES_COMMON` is now env-overridable
  (`$env:DOTFILES_COMMON` / exported); default still resolves from the script's own path. The zsh
  heavy-verb re-exec forwards `DOTFILES_COMMON` through the env. PS doctor tests reset
  `$env:DOTFILES_COMMON = $null` right after the engine-behind / engine-not-git Invoke-DF calls.
- Tests: `tests/test_doctor.{sh,ps1}` — L0.13, L0.14, L0.15, L0.16, L0.17, L0.18, L0.19, L5.6,
  L5.24, L5.25, L5.26. Each greppable banner tagged GOOD/BAD. Built the overlap fixture by
  tracking the SAME path in two repos. Engine-behind fixture: a fake engine repo reset 1 commit
  behind its origin/main, with DOTFILES_COMMON pointed at it for that test only.
- Local results: `bash tests/run.sh bash` -> 174 PASS / 0 FAIL / 1 SKIP (doctor 43/43);
  `pwsh tests/run.ps1` -> 171 PASS / 0 FAIL / 1 SKIP (doctor 43/43). The single SKIP is the
  pre-existing `L5.17-autotick` (git-config forbids spaces in section names — not a node-7 issue).

## Next node (UNBLOCKED)
- **Node 8** — hook runner per-repo dispatch. The runner under `githooks-runner/` identifies the
  firing repo via `git rev-parse --absolute-git-dir` -> basename, then runs
  `~/.dotfiles/hooks/_shared/<hook>` then `~/.dotfiles/hooks/<repo>/<hook>`. Gate L1.7-L1.10
  (per-repo hook fires, isolation, _shared for all, identity), L5.4-L5.6 (missing dirs / uv),
  L4.4 (sh.exe identity under Git-for-Windows).

## Do NOT
- re-run a completed node; push to master; weaken tests; `git add -A` unscoped across $HOME;
  push refs/sync-losers/* or state/*/conflicts.log to any synced branch (LOCAL only);
  tighten -doctor to fail on warnings (exit nonzero is ERROR-only); hardcode `<dir>/MERGE_HEAD`.
