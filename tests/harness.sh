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
