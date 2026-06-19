# Last checkpoint

Branch: feat/sync-multi-repo-engine

## Last node DONE LOCALLY (NOT yet pushed/CI-verified — orchestrator pushes + verifies CI)
- **Node 10** — migration + bootstrap.{sh,ps1}. Fresh-machine setup + legacy->container migration.
  - NEW `bootstrap.{sh,ps1}` (engine root, ship in common/): plan "A. First-run setup" steps 1-4 in
    one run; leaves step 5 (verify + `dotfiles -config machine.tick on`) to the user (tick OFF).
    1) clone engine -> ~/.dotfiles/common; 2) append profile source-guard ONCE (idempotent);
    3) bare-clone machine repo -> bare-repos/machine on per-machine branch (default = hostname),
       set fetch refspec + showUntrackedFiles=no, safe checkout (BACK UP conflicting work-tree files
       to .bak-<ts>), THEN wire core.hooksPath; 4) `dotfiles -timer install`. Idempotent.
  - NEW `migrate.{sh,ps1}` + `dotfiles -migrate` verb (sh re-execs migrate.sh under bash; ps invokes
    migrate.ps1). Safe order: detect legacy (bare git-dir AT $ROOT) -> STOP old timer FIRST -> MOVE
    git metadata $ROOT -> bare-repos/machine (work-tree files never move; skip new-layout dirs + the
    legacy .dotfiles helper subtree) -> ensure engine at common/ -> set core.hooksPath -> strip
    legacy aliases + append new dispatcher guard in profile -> `-timer install`. Aborts on ambiguous
    state. Re-runnable.
  - Doctor (node 7) ALREADY covers L5.25 partial migration (hooks:MISSING + "core.hooksPath not set"
    fix, exit 0) — no doctor change needed.
  - NEW `tests/test_migration.{sh,ps1}`: L1.14 (full migration: machine git-dir valid; ALL work-tree
    files byte-identical; old metadata gone; status clean; per-repo hook fires; -ls shows machine),
    L1.14b (idempotent), L1.14c (abort no-legacy-no-machine), L5.25 (doctor partial-migration warn),
    BOOT-idempotent (double profile-append != duplicate + full layout from empty via LOCAL bare
    origins, no network). Fake HOME + DOTFILES_ROOT; never touches real ~/.dotfiles or profile.
  - DISPATCHER CHANGE (both shells): new `-migrate` verb + help line.
- Local results: `bash tests/run.sh bash` overall rc=0 (test_migration 23/0/0; no file regressed);
  `pwsh tests/run.ps1` overall rc=0 (test_migration 23/0/0). The pre-existing SKIPs persist
  (L5.17-autotick; timer live-manager bits behind DOTFILES_TIMER_LIVE; hooks uv/non-exec).
- Confirmed NO runaway timer loop survives the run (the bootstrap install spawns a non-admin loop on
  Windows; cleaned up — match the loop SCRIPT path `\.dotfiles-tick-loop\.ps1`, not the substring,
  or the inspection command matches itself).

## New pitfalls recorded (PITFALLS.md)
- bootstrap/migrate child pwsh must `Set-Variable HOME $env:HOME -Force` (PS auto $HOME = USERPROFILE).
- wire core.hooksPath AFTER the checkout (a post-checkout hook nonzero rc fails `git checkout`).
- migration fixtures must not track a file named `.gitconfig` (git reads it as global config).
- migration moves only git metadata; legacy `.dotfiles` helper subtree dropped; $HOME files never move.

## Next node (UNBLOCKED)
- **Node 11** — cross-OS interop chain (L4.1-L4.6): .gitattributes normalization (no spurious
  line-ending diffs), file-mode stability, path handling, hook identity under Git-for-Windows sh.exe;
  chained ubuntu->windows->macos->ubuntu jobs passing a bare `origin` artifact between legs.
- Then node 12 (README full rewrite).

## Do NOT
- re-run a completed node; push to master; weaken tests; `git add -A` unscoped across $HOME.
- set core.hooksPath BEFORE a bootstrap checkout (post-checkout hook rc fails the checkout).
- track a `.gitconfig` fixture under --work-tree=$HOME (git parses it as global config -> errors).
- point the timer's DOTFILES_COMMON at a fake/temp root in tests (use the real engine checkout).
- compare `origin_tip <repo>` without an explicit ref (bare origin HEAD unset -> "HEAD").
