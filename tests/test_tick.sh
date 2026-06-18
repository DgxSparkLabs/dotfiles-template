#!/usr/bin/env bash
# Node 4 generic tick, single-writer path (bash/zsh): L1.1-L1.6, L2.1.
# The tick add->commit->pushes a repo's OWN territory, gated by <repo>.tick (default OFF),
# add flag from <repo>.add. We assert against the fake origin (advanced? which files?).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
. "$HERE/harness.sh"
. "$REPO/dotfiles.sh"

new_env

# ---------------------------------------------------------------------------
# L1.1 edit a tracked file in an enabled repo -> after -tick it is committed AND pushed.
_t_start L1.1 GOOD
mk_repo_with_origin nvim main
dotfiles -config nvim.tick on
before="$(origin_tip nvim refs/heads/main)"
printf 'set number\n' > "$HOME/.config/nvim/seed"
dotfiles -tick nvim; rc=$?
after="$(origin_tip nvim refs/heads/main)"
assert_rc L1.1 "$rc" 0
if [ "$before" != "$after" ]; then _pass; else _fail "L1.1 origin did not advance"; fi
# the pushed tip's tree actually contains the edited path, and its blob holds the new content.
# (Avoid the <rev>:<path> colon syntax: Git-for-Windows mangles the colon into a Windows path.)
assert_contains L1.1 "$(git --git-dir="$(origin_dir nvim)" ls-tree -r --name-only refs/heads/main)" ".config/nvim/seed"
blob="$(git --git-dir="$(origin_dir nvim)" ls-tree -r refs/heads/main -- .config/nvim/seed | awk '{print $3}')"
assert_contains L1.1 "$(git --git-dir="$(origin_dir nvim)" cat-file -p "$blob")" "set number"

# ---------------------------------------------------------------------------
# L1.2 scoped-add never crosses repos: A enabled, B enabled with a disjoint owned dir;
# modify a B-owned file; tick A; A's new commit must NOT include the B file.
_t_start L1.2 GOOD
new_env
mk_repo_with_origin alpha main      # owns .config/alpha
mk_repo_with_origin beta  main      # owns .config/beta
dotfiles -config alpha.tick on
dotfiles -config alpha.add all      # even with -A, scoping must keep beta out
dotfiles -config beta.tick on
printf 'edit-a\n' > "$HOME/.config/alpha/seed"
printf 'edit-b\n' > "$HOME/.config/beta/seed"          # a B-owned change sitting in the work-tree
dotfiles -tick alpha
names="$(git --git-dir="$(origin_dir alpha)" show --name-only --pretty=format: refs/heads/main)"
assert_contains     L1.2 "$names" ".config/alpha/seed"
assert_not_contains L1.2 "$names" ".config/beta/seed"

# ---------------------------------------------------------------------------
# L1.3 tick-off safety: a repo with tick UNSET -> -tick makes NO commit, origin unchanged.
_t_start L1.3 GOOD
new_env
mk_repo_with_origin solo main       # tick left UNSET (default OFF)
before="$(origin_tip solo refs/heads/main)"
printf 'changed\n' > "$HOME/.config/solo/seed"
dotfiles -tick solo; rc=$?
after="$(origin_tip solo refs/heads/main)"
assert_rc L1.3 "$rc" 0
assert_eq L1.3 "$after" "$before"   # origin must be byte-identical (no push)

# ---------------------------------------------------------------------------
# L1.4 enable then sync: turn tick on -> -tick now advances origin.
_t_start L1.4 GOOD
before="$(origin_tip solo refs/heads/main)"
dotfiles -config solo.tick on
dotfiles -tick solo
after="$(origin_tip solo refs/heads/main)"
if [ "$after" != "$before" ]; then _pass; else _fail "L1.4 origin did not advance after enabling tick"; fi

# ---------------------------------------------------------------------------
# L1.5 add=tracked ignores a NEW untracked file (default add).
_t_start L1.5 GOOD
new_env
mk_repo_with_origin trk main
dotfiles -config trk.tick on        # add defaults to tracked (-u)
printf 'brand new\n' > "$HOME/.config/trk/newfile"   # untracked, under the repo's dir
dotfiles -tick trk
names="$(git --git-dir="$(origin_dir trk)" show --name-only --pretty=format: refs/heads/main 2>/dev/null)"
# Nothing tracked changed -> ideally no new commit at all; but in any case newfile must be ABSENT.
assert_not_contains L1.5 "$names" ".config/trk/newfile"
# And the untracked file is NOT tracked by the repo:
assert_not_contains L1.5 "$(git --git-dir="$DOTFILES_ROOT/bare-repos/trk" --work-tree="$HOME" ls-files)" ".config/trk/newfile"

# ---------------------------------------------------------------------------
# L1.6 add=all stages a NEW untracked file under the repo's tracked dir.
_t_start L1.6 GOOD
new_env
mk_repo_with_origin allr main
dotfiles -config allr.tick on
dotfiles -config allr.add all
printf 'grab me\n' > "$HOME/.config/allr/newfile"    # untracked, under repo-owned .config/allr
dotfiles -tick allr
names="$(git --git-dir="$(origin_dir allr)" show --name-only --pretty=format: refs/heads/main)"
assert_contains L1.6 "$names" ".config/allr/newfile"

# ---------------------------------------------------------------------------
# L2.1 two machines, different files: machine2 is a second bare repo + same HOME-relative work-tree
# cloned from the SAME origin. M1 edits f1 & ticks (push); M2 fetches + fast-forwards to receive f1.
# NOTE: full bidirectional merge is node 5; this proves the origin round-trips via push + a
# manual fetch/reset on the second machine (non-overlapping propagation only).
_t_start L2.1 GOOD
new_env
mk_repo_with_origin proj main
dotfiles -config proj.tick on
# "machine 2": a second bare repo over a second work-tree, both pointing at proj's origin.
M2HOME="$WORK/home2"; M2GD="$WORK/m2/proj.git"
mkdir -p "$M2HOME" "$WORK/m2"
git clone -q --bare "$(origin_dir proj)" "$M2GD"
git --git-dir="$M2GD" --work-tree="$M2HOME" checkout -q -f main
# machine1 edits f1 and ticks -> pushed to origin
printf 'from-m1\n' > "$HOME/.config/proj/seed"
dotfiles -tick proj
# machine2 fetches + fast-forwards (non-overlapping: it only had the seed). A bare clone maps
# origin's heads onto its OWN refs/heads, so we reset to FETCH_HEAD (not refs/remotes/origin/*).
git --git-dir="$M2GD" --work-tree="$M2HOME" fetch -q origin main
git --git-dir="$M2GD" --work-tree="$M2HOME" reset -q --hard FETCH_HEAD
assert_contains L2.1 "$(cat "$M2HOME/.config/proj/seed")" "from-m1"

_summary
