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
