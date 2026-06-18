#!/usr/bin/env bash
# Node 6 robustness & malformed-state battery (bash/zsh): the L5 BAD-path cases NOT already
# covered by test_config (L5.8-L5.12) or test_dispatcher (L5.13).
# Shared contract for ALL L5 tests: fail-isolated (one bad repo never aborts the others),
# fail-loud (clear message or safe default), never-corrupt ($HOME work-tree unchanged), never-block.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
. "$HERE/harness.sh"
. "$REPO/dotfiles.sh"

new_env

# ---------------------------------------------------------------------------
# L5.1 no ~/.dotfiles/config -> safe defaults (tick off) -> -tick a no-op, no crash, exit 0.
_t_start L5.1 BAD
mk_repo_with_origin r1 main
rm -f "$DOTFILES_ROOT/config"                 # remove the config file entirely
before="$(origin_tip r1 refs/heads/main)"
printf 'changed\n' > "$HOME/.config/r1/seed"
dotfiles -tick; rc=$?
after="$(origin_tip r1 refs/heads/main)"
assert_rc L5.1 "$rc" 0
assert_eq L5.1 "$after" "$before"             # tick defaults OFF -> origin unchanged
assert_contains L5.1 "$(cat "$HOME/.config/r1/seed")" "changed"   # work-tree intact

# ---------------------------------------------------------------------------
# L5.3 no bare-repos/ dir -> -ls empty, -tick a no-op, no crash.
_t_start L5.3 BAD
new_env
rm -rf "$DOTFILES_ROOT/bare-repos"
ls_out="$(dotfiles -ls 2>/dev/null)"; rc=$?
assert_rc L5.3 "$rc" 0
assert_eq L5.3 "$ls_out" ""
dotfiles -tick; rc=$?
assert_rc L5.3 "$rc" 0

# ---------------------------------------------------------------------------
# L5.7 unreachable origin -> that repo skipped, OTHER repos still tick (fail-isolation).
_t_start L5.7 BAD
new_env
mk_repo_with_origin good main
mk_repo_with_origin bad  main
dotfiles -config good.tick on
dotfiles -config bad.tick  on
# Make bad's origin unreachable by pointing it at a non-existent path.
git --git-dir="$(bare_dir bad)" remote set-url origin "$WORK/origins/DOES_NOT_EXIST.git"
gbefore="$(origin_tip good refs/heads/main)"
printf 'g\n' > "$HOME/.config/good/seed"
printf 'b\n' > "$HOME/.config/bad/seed"
dotfiles -tick; rc=$?                          # loop over both; bad errors, good must still push
gafter="$(origin_tip good refs/heads/main)"
# Loop never aborts: good's origin advanced even though bad failed.
if [ "$gafter" != "$gbefore" ]; then _pass; else _fail "L5.7 good repo did not tick despite bad repo failing"; fi
assert_contains L5.7 "$(cat "$HOME/.config/bad/seed")" "b"        # bad's work-tree intact

# ---------------------------------------------------------------------------
# L5.14 corrupted bare repo (missing HEAD/objects) skipped; remaining repos tick (fail-isolation).
_t_start L5.14 BAD
new_env
mk_repo_with_origin alive main
mk_repo_with_origin dead  main
dotfiles -config alive.tick on
dotfiles -config dead.tick  on
corrupt_repo dead                              # remove HEAD + objects
abefore="$(origin_tip alive refs/heads/main)"
printf 'live\n' > "$HOME/.config/alive/seed"
dotfiles -tick; rc=$?
aafter="$(origin_tip alive refs/heads/main)"
if [ "$aafter" != "$abefore" ]; then _pass; else _fail "L5.14 alive repo did not tick despite corrupt sibling"; fi

# ---------------------------------------------------------------------------
# L5.15 a NORMAL (non-bare) repo placed under bare-repos/ -> the tick must not corrupt $HOME.
# A non-bare repo's HEAD/index live in <dir>/.git and its work-tree is <dir>, NOT $HOME. The tick
# must never stage/commit $HOME files through it. We assert $HOME is untouched and no crash.
_t_start L5.15 BAD
new_env
mk_nonbare_under_repos weird
dotfiles -config weird.tick on
printf 'home file\n' > "$HOME/.somefile"       # a $HOME file the tick must NOT grab via 'weird'
dotfiles -tick; rc=$?
assert_rc L5.15 "$rc" 0
# The non-bare repo must not have swept up the $HOME file (its work-tree is its own dir, not $HOME).
assert_not_contains L5.15 "$(git --git-dir="$(bare_dir weird)/.git" --work-tree="$(bare_dir weird)" ls-files 2>/dev/null)" ".somefile"
assert_contains L5.15 "$(cat "$HOME/.somefile")" "home file"     # $HOME intact

# ---------------------------------------------------------------------------
# L5.16 unborn branch (no commits yet) first tick with a tracked file -> clean initial commit.
# Realistic first-commit flow: the file is added to the repo (tracked in the index) but no commit
# exists yet (unborn HEAD). The tick must make the initial commit cleanly without crashing.
_t_start L5.16 GOOD
new_env
gd="$(bare_dir unborn)"
mkdir -p "$WORK/origins"
git init --bare -q "$WORK/origins/unborn.git"
git init --bare -q "$gd"
git --git-dir="$gd" --work-tree="$HOME" symbolic-ref HEAD refs/heads/main   # unborn: HEAD set, no commit
git --git-dir="$gd" remote add origin "$WORK/origins/unborn.git"
mkdir -p "$HOME/.config/unborn"
printf 'first\n' > "$HOME/.config/unborn/seed"
dotfiles unborn add -- .config/unborn/seed                                  # track it (still unborn)
dotfiles -config unborn.tick on
dotfiles -tick unborn; rc=$?
assert_rc L5.16 "$rc" 0
# An initial commit now exists on HEAD with the file (no crash on the unborn branch).
assert_contains L5.16 "$(git --git-dir="$gd" --work-tree="$HOME" log --oneline 2>/dev/null)" "unborn: auto"
assert_contains L5.16 "$(git --git-dir="$gd" --work-tree="$HOME" ls-files 2>/dev/null)" ".config/unborn/seed"

# ---------------------------------------------------------------------------
# L5.17 repo dir name with spaces -> routing/discovery/passthrough quoting holds across shells.
# The load-bearing claim is that the dispatcher's word-splitting/quoting survives a space in the
# repo name: -ls lists it intact, and `dotfiles "<name>" <git...>` routes to that exact repo.
_t_start L5.17 GOOD
new_env
mk_repo_with_origin "my repo" main
# -ls lists the spaced name intact (discovery + quoting).
assert_contains L5.17 "$(dotfiles -ls)" "my repo"
# Passthrough routes to the spaced-name repo (its status, not "no such repo").
st="$(dotfiles "my repo" status --short 2>&1)"
assert_not_contains L5.17 "$st" "no such repo"
# Editing + a scoped passthrough commit on the spaced-name repo works (quoting holds end to end).
printf 'spaced\n' > "$HOME/.config/my repo/seed"
dotfiles "my repo" add -- ".config/my repo/seed"; rc=$?
assert_rc L5.17 "$rc" 0
dotfiles "my repo" commit -q -m "spaced: edit"; rc=$?
assert_rc L5.17 "$rc" 0
assert_contains L5.17 "$(git --git-dir="$(bare_dir "my repo")" --work-tree="$HOME" log --oneline)" "spaced: edit"
# NOTE: enabling the auto-tick for a spaced name via `-config "my repo.tick" on` is NOT possible —
# git-config top-level section names forbid spaces ("error: invalid key"). The auto-tick gate keys
# off <repo>.<key>, so a spaced repo can't be auto-ticked under the current schema. Surfaced as a
# named SKIP rather than silently dropped (see PITFALLS.md).
_t_start "L5.17-autotick" BAD
_skip "git-config section names forbid spaces; <repo>.tick gate can't key a spaced repo name (schema constraint, not a Node 6 bug)"

# ---------------------------------------------------------------------------
# L5.19 detached HEAD -> tick refuses to push (no branch to sync), skips, no crash, work-tree intact.
_t_start L5.19 BAD
new_env
mk_repo_with_origin det main
dotfiles -config det.tick on
# Detach HEAD at the current commit.
sha="$(git --git-dir="$(bare_dir det)" rev-parse HEAD)"
git --git-dir="$(bare_dir det)" --work-tree="$HOME" checkout -q --detach "$sha"
before="$(origin_tip det refs/heads/main)"
printf 'detached edit\n' > "$HOME/.config/det/seed"
dotfiles -tick det; rc=$?
after="$(origin_tip det refs/heads/main)"
assert_rc L5.19 "$rc" 0                        # never crashes / blocks
assert_eq L5.19 "$after" "$before"             # nothing pushed (no branch)
assert_contains L5.19 "$(cat "$HOME/.config/det/seed")" "detached edit"   # work-tree intact

# ---------------------------------------------------------------------------
# L5.21 branch with no upstream -> commit locally, push skipped (logged), no crash.
_t_start L5.21 BAD
new_env
gd="$(bare_dir noups)"
git init --bare -q "$gd"
git --git-dir="$gd" --work-tree="$HOME" symbolic-ref HEAD refs/heads/main
mkdir -p "$HOME/.config/noups"
printf 'seed\n' > "$HOME/.config/noups/seed"
git --git-dir="$gd" --work-tree="$HOME" add -- .config/noups/seed
git --git-dir="$gd" --work-tree="$HOME" commit -q -m "noups: seed"    # committed, but NO origin/upstream
dotfiles -config noups.tick on
printf 'local only\n' > "$HOME/.config/noups/seed"
n_before="$(git --git-dir="$gd" rev-parse HEAD)"
dotfiles -tick noups; rc=$?
n_after="$(git --git-dir="$gd" rev-parse HEAD)"
assert_rc L5.21 "$rc" 0                         # no upstream -> not an error
if [ "$n_after" != "$n_before" ]; then _pass; else _fail "L5.21 local commit not made without upstream"; fi

# ---------------------------------------------------------------------------
# L5.22 unrelated histories -> reconcile REFUSES (never forces a wrong merge); work-tree untouched.
_t_start L5.22 BAD
new_env
mk_repo_with_origin unrel main
dotfiles -config unrel.tick on
# Rewrite origin's branch to an UNRELATED root commit (no shared ancestor with the local repo).
orig="$(origin_dir unrel)"
tmpwt="$WORK/unrel_wt"; mkdir -p "$tmpwt"
git --git-dir="$orig" --work-tree="$tmpwt" 2>/dev/null checkout -q --orphan other 2>/dev/null || true
# Build the unrelated history in a scratch normal repo, then push --force to origin's main.
scratch="$WORK/scratch"; git init -q "$scratch"
printf 'alien\n' > "$scratch/alien"
git -C "$scratch" add alien
git -C "$scratch" commit -q -m "alien root"
git -C "$scratch" push -q --force "$orig" HEAD:refs/heads/main
# Local makes its own divergent commit, then ticks: fetch sees an unrelated origin/main.
printf 'mine\n' > "$HOME/.config/unrel/seed"
dotfiles -tick unrel 2>"$WORK/unrel.err"; rc=$?
assert_rc L5.22 "$rc" 1                          # push not completed this tick -> nonzero, but...
# ...it REFUSED to merge (loud message), did not force, and the work-tree is intact.
assert_contains L5.22 "$(cat "$WORK/unrel.err")" "unrelated histories"
assert_contains L5.22 "$(cat "$HOME/.config/unrel/seed")" "mine"

# ---------------------------------------------------------------------------
# L5.23 stale MERGE_HEAD AND stale index.lock from a crashed prior tick -> recovered, tick proceeds.
_t_start L5.23 BAD
new_env
mk_repo_with_origin crash main
dotfiles -config crash.tick on
plant_stale_merge crash                          # leftover merge from a crash
plant_stale_lock  crash                          # leftover index.lock, backdated 1 day (stale)
before="$(origin_tip crash refs/heads/main)"
printf 'after crash\n' > "$HOME/.config/crash/seed"
DOTFILES_LOCK_STALE=1 dotfiles -tick crash; rc=$?
after="$(origin_tip crash refs/heads/main)"
assert_rc L5.23 "$rc" 0
# Recovery cleared the stale state and the tick committed + pushed normally.
if [ "$after" != "$before" ]; then _pass; else _fail "L5.23 tick did not proceed after stale-state recovery"; fi
[ ! -f "$(bare_dir crash)/MERGE_HEAD" ] && _pass || _fail "L5.23 stale MERGE_HEAD not cleared"
[ ! -f "$(bare_dir crash)/index.lock" ] && _pass || _fail "L5.23 stale index.lock not cleared"

# ---------------------------------------------------------------------------
# L5.27 concurrent tick on one repo -> the second is serialized/skips, no index corruption.
# Simulate a LIVE tick already in progress by planting a FRESH tick-lock; a new tick must SKIP
# this cycle (never block), leave the lock alone, and not commit/push.
_t_start L5.27 BAD
new_env
mk_repo_with_origin conc main
dotfiles -config conc.tick on
plant_live_lock conc                             # fresh lock = a live tick holds it
before="$(origin_tip conc refs/heads/main)"
printf 'racing\n' > "$HOME/.config/conc/seed"
dotfiles -tick conc 2>"$WORK/conc.err"; rc=$?
after="$(origin_tip conc refs/heads/main)"
assert_rc L5.27 "$rc" 0                           # never blocks / errors
assert_eq L5.27 "$after" "$before"                # no second writer touched the index/origin
assert_contains L5.27 "$(cat "$WORK/conc.err")" "already running"
has_tick_lock conc && _pass || _fail "L5.27 live lock was wrongly removed by the skipping tick"

_summary
