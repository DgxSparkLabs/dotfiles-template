#!/usr/bin/env bash
# Shared test harness (bash/zsh): greppable PASS/FAIL/SKIP banners + assertions + fake env.
# Source me from a test_*.sh. Final `_summary` returns nonzero if any assertion failed.
set -uo pipefail

_PASS=0; _FAIL=0; _SKIP=0; CURRENT_TEST="?"

_t_start() { CURRENT_TEST="$1"; printf '=== %s %s START ===\n' "$1" "${2:-GOOD}"; }
_pass()    { _PASS=$((_PASS+1)); printf '=== %s RESULT=PASS ===\n' "$CURRENT_TEST"; }
_fail()    { _FAIL=$((_FAIL+1)); printf '=== %s RESULT=FAIL (%s) ===\n' "$CURRENT_TEST" "$1"; }
_skip()    { _SKIP=$((_SKIP+1)); printf '=== %s RESULT=SKIP (%s) ===\n' "$CURRENT_TEST" "$1"; }
_summary() { printf '=== SUMMARY pass=%d fail=%d skip=%d ===\n' "$_PASS" "$_FAIL" "$_SKIP"; [ "$_FAIL" -eq 0 ]; }

# Portable in-place sed. GNU sed accepts `sed -i 's/.../.../' file`, but BSD/macOS sed
# treats the token after -i as a mandatory backup suffix, so `sed -i 's/.../.../' file`
# misparses on macOS (bash 3.2 leg): the substitution silently never happens, the divergent
# commit is never made, and the empty/unchanged merge later feeds empty revisions to
# `git log`/`update-ref` (the macOS-only "fatal: Needed a single revision" failures in
# L2.2/L2.3/L2.4/L2.5/L2.12/L2.13). Rewrite via a temp file to avoid the -i suffix divergence
# entirely. Usage: sed_inplace <sed-script> <file>
sed_inplace() {
  local _script="$1" _file="$2" _tmp
  _tmp="$(mktemp)"
  sed "$_script" "$_file" > "$_tmp" && cat "$_tmp" > "$_file"
  rm -f "$_tmp"
}

assert_eq()           { if [ "$2" = "$3" ]; then _pass; else _fail "$1: expected [$3] got [$2]"; fi; }
assert_contains()     { case "$2" in *"$3"*) _pass;; *) _fail "$1: [$2] lacks [$3]";; esac; }
assert_not_contains() { case "$2" in *"$3"*) _fail "$1: [$2] unexpectedly has [$3]";; *) _pass;; esac; }
assert_rc()           { if [ "$2" -eq "$3" ]; then _pass; else _fail "$1: expected rc $3 got $2"; fi; }

# Isolated fake environment: a throwaway HOME + DOTFILES_ROOT under a temp dir.
new_env() {
  WORK="$(mktemp -d)"
  export HOME="$WORK/home"
  export DOTFILES_ROOT="$WORK/dot"
  mkdir -p "$HOME" "$DOTFILES_ROOT/bare-repos"
  git config --global user.email "t@example.test" >/dev/null 2>&1 || true
  git config --global user.name  "t"               >/dev/null 2>&1 || true
}
mk_repo() { git init --bare -q "$DOTFILES_ROOT/bare-repos/$1"; }

# mk_repo_with_origin <name> [branch]
#   Build a repo wired to a fake "origin" bare repo on local disk, with an upstream-tracking
#   branch and one initial commit that seeds a repo-OWNED file ($HOME/.config/<name>/seed).
#   Layout:  $WORK/origins/<name>.git  (fake remote)  <-  bare-repos/<name>  ->  $HOME work-tree.
#   POSIX/Git-Bash safe. Used by node 4 (tick) and node 5 (merge).
mk_repo_with_origin() {
  local name="$1" branch="${2:-main}"
  local origin="$WORK/origins/$name.git" gd="$DOTFILES_ROOT/bare-repos/$name" seed=".config/$name/seed"
  mkdir -p "$WORK/origins"
  git init --bare -q "$origin"
  git init --bare -q "$gd"
  git --git-dir="$gd" --work-tree="$HOME" symbolic-ref HEAD "refs/heads/$branch"
  git --git-dir="$gd" remote add origin "$origin"
  mkdir -p "$HOME/.config/$name"
  printf 'seed\n' > "$HOME/$seed"
  git --git-dir="$gd" --work-tree="$HOME" add -- "$seed"
  git --git-dir="$gd" --work-tree="$HOME" commit -q -m "$name: seed"
  git --git-dir="$gd" --work-tree="$HOME" push -q -u origin "$branch"
}

# Resolve the fake-origin path / tip for assertions.
origin_dir() { printf '%s/origins/%s.git' "$WORK" "$1"; }
origin_tip() { git --git-dir="$WORK/origins/$1.git" rev-parse "${2:-HEAD}" 2>/dev/null; }

# --- Multi-machine helpers (node 5: bidirectional merge over a shared origin) ----------
# A "machine" = an isolated HOME + a bare repo cloned from the SAME origin, driven through the
# real dispatcher with that machine's HOME + DOTFILES_ROOT swapped in. machine 1 == the env
# created by new_env + mk_repo_with_origin. mk_machine adds machine N (N>=2).
#
# mk_machine <n> <repo> [branch]
#   Clone <repo>'s origin into a per-machine DOTFILES_ROOT and check out <branch>. Idempotent
#   per (n,repo). Sets globals M<n>_HOME / M<n>_ROOT (also returned via mhome/mroot).
mk_machine() {
  local n="$1" repo="$2" branch="${3:-main}"
  local mhome="$WORK/m$n/home" mroot="$WORK/m$n/dot" gd
  gd="$mroot/bare-repos/$repo"
  mkdir -p "$mhome" "$mroot/bare-repos"
  if [ ! -d "$gd" ]; then
    # Build the second machine the SAME way mk_repo_with_origin builds the first: init --bare +
    # remote add (which installs the standard fetch refspec) + fetch + checkout -B from
    # origin/<branch>. A plain `git clone --bare` would NOT set a fetch refspec, so there'd be
    # no refs/remotes/origin/* and no @{upstream} for the tick to push to.
    git init --bare -q "$gd"
    git --git-dir="$gd" --work-tree="$mhome" symbolic-ref HEAD "refs/heads/$branch"
    git --git-dir="$gd" remote add origin "$(origin_dir "$repo")"
    git --git-dir="$gd" fetch -q origin
    git --git-dir="$gd" --work-tree="$mhome" checkout -q -B "$branch" "origin/$branch"
  fi
  eval "M${n}_HOME=\$mhome; M${n}_ROOT=\$mroot"
}
# Register the new_env environment (its $HOME / $DOTFILES_ROOT) as "machine 1".
reg_machine1() { M1_HOME="$HOME"; M1_ROOT="$DOTFILES_ROOT"; }
mhome() { eval "printf '%s' \"\$M${1}_HOME\""; }
mroot() { eval "printf '%s' \"\$M${1}_ROOT\""; }

# tick_machine <n> <repo> [extra dotfiles args...]
#   Run the real dispatcher's tick for one repo AS machine N (its HOME/ROOT in scope), with
#   the current process's git committer/author date honored (set GIT_*_DATE before calling for
#   deterministic newest-wins). Echoes nothing; side effects land in machine N's repo + origin.
tick_machine() {
  local n="$1" repo="$2"; shift 2
  local mhome mroot; mhome="$(mhome "$n")"; mroot="$(mroot "$n")"
  ( HOME="$mhome" DOTFILES_ROOT="$mroot"
    git config -f "$mroot/config" "$repo.tick" on
    dotfiles -tick "$repo" "$@" )
}

# write_machine <n> <relpath> <content>   — write a file in machine N's HOME work-tree.
write_machine() { local n="$1" rel="$2"; shift 2; mkdir -p "$(dirname "$(mhome "$n")/$rel")"; printf '%s' "$*" > "$(mhome "$n")/$rel"; }
read_machine()  { cat "$(mhome "$1")/$2" 2>/dev/null; }
# pull_machine <n> <repo> [branch] — fast-forward machine N's work-tree from origin (receive side).
pull_machine() {
  local n="$1" repo="$2" branch="${3:-main}" gd
  gd="$(mroot "$n")/bare-repos/$repo"
  git --git-dir="$gd" --work-tree="$(mhome "$n")" fetch -q origin "$branch"
  git --git-dir="$gd" --work-tree="$(mhome "$n")" reset -q --hard FETCH_HEAD
}
