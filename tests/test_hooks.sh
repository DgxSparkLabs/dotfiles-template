#!/usr/bin/env bash
# Node 8 per-repo hook dispatch (bash/zsh): L1.7-L1.10, L5.4, L5.6, L4.4 (sh.exe identity leg).
# A bare repo's core.hooksPath -> the engine's shared stubs -> the Python runner
# (dotfiles_githooks). The runner identifies the firing repo via
# `git rev-parse --absolute-git-dir` (basename) and runs:
#     <root>/hooks/_shared/<hook>   (ALL repos)   then
#     <root>/hooks/<repo>/<hook>    (THIS repo only)
# passing through args + stdin; a non-zero per-repo hook exit blocks the git op.
# These tests fire REAL commits (no dotfiles dispatcher) so they exercise the runner exactly
# as git would, on every OS (bash leg on linux/mac/win-gitbash; the win-gitbash leg is the
# INFERRED `sh.exe` identity assumption L1.10/L4.4).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
REPO_UNDER_TEST="$REPO"            # used by harness wire_hooks
. "$HERE/harness.sh"

# uv must be available (the runner is invoked via `uv run`). It is on CI (validate-githooks)
# and locally. If absent, the hook stub fails loud; we still need it to run the GOOD-path tests.
if ! command -v uv >/dev/null 2>&1; then
  _t_start L1.7 GOOD; _fail "uv not on PATH (hook runner cannot run)"; _summary; exit $?
fi

new_env
# Marker dir shared across tests; hooks inherit our env, so export the paths they write to.
MARK="$WORK/marks"; mkdir -p "$MARK"

# ---------------------------------------------------------------------------
# L1.7 per-repo hook fires: hooks/nvim/pre-commit writes a marker -> a commit in nvim runs it.
_t_start L1.7 GOOD
mk_repo_hookable nvim main
export DF_MARK="$MARK/nvim_pre.txt"; rm -f "$DF_MARK"
write_hook nvim pre-commit 'echo fired > "$DF_MARK"'
commit_in nvim .config/nvim/init.lua "set number"; rc=$?
assert_rc L1.7 "$rc" 0
assert_eq L1.7 "$(cat "$DF_MARK" 2>/dev/null)" "fired"

# ---------------------------------------------------------------------------
# L1.8 isolation: a commit in a DIFFERENT repo does NOT run nvim's hook (marker absent).
_t_start L1.8 GOOD
mk_repo_hookable machine main
rm -f "$MARK/nvim_pre.txt"                          # clear nvim's marker from L1.7
export DF_MARK="$MARK/nvim_pre.txt"
commit_in machine .config/machine/cfg "host=x"; rc=$?
assert_rc L1.8 "$rc" 0
# nvim's per-repo hook must NOT have run for a machine commit.
if [ ! -f "$MARK/nvim_pre.txt" ]; then _pass; else _fail "L1.8 nvim hook ran on a machine commit"; fi

# ---------------------------------------------------------------------------
# L1.9 _shared fires for ALL repos: hooks/_shared/pre-commit -> appends repo name; commit in
# BOTH nvim and machine each append a line (so it ran for both).
_t_start L1.9 GOOD
export DF_SHARED="$MARK/shared.log"; rm -f "$DF_SHARED"
write_hook _shared pre-commit 'echo "shared:$(basename "$(git rev-parse --absolute-git-dir)")" >> "$DF_SHARED"'
commit_in nvim    .config/nvim/a.lua    "a"; rc1=$?
commit_in machine .config/machine/b.cfg "b"; rc2=$?
assert_rc L1.9 "$rc1" 0
assert_rc L1.9 "$rc2" 0
log="$(cat "$DF_SHARED" 2>/dev/null)"
assert_contains L1.9 "$log" "shared:nvim"
assert_contains L1.9 "$log" "shared:machine"

# ---------------------------------------------------------------------------
# L1.10 / L4.4 identity: a hook records `git rev-parse --absolute-git-dir` basename; it must
# equal the firing repo name. This is the INFERRED assumption and MUST pass on Git-for-Windows
# sh.exe (this file runs under bash on the win-gitbash CI leg too).
_t_start L1.10 GOOD
export DF_ID="$MARK/id.txt"; rm -f "$DF_ID"
write_hook nvim post-commit 'basename "$(git rev-parse --absolute-git-dir)" > "$DF_ID"'
commit_in nvim .config/nvim/id.lua "x"; rc=$?
assert_rc L1.10 "$rc" 0
assert_eq L1.10 "$(cat "$DF_ID" 2>/dev/null)" "nvim"

# ---------------------------------------------------------------------------
# L5.4 missing hooks/<repo> AND hooks/_shared -> commit succeeds, nothing runs, no crash.
_t_start L5.4 GOOD
new_env; MARK="$WORK/marks"; mkdir -p "$MARK"
mk_repo_hookable solo main
# Deliberately create NO hooks/ tree at all.
[ -d "$DOTFILES_ROOT/hooks" ] && rm -rf "$DOTFILES_ROOT/hooks"
commit_in solo .config/solo/x "y"; rc=$?
assert_rc L5.4 "$rc" 0
# The commit really landed (work-tree file is tracked at HEAD).
assert_contains L5.4 "$(git --git-dir="$(bare_dir solo)" ls-tree -r --name-only HEAD)" ".config/solo/x"

# ---------------------------------------------------------------------------
# L5.4b non-executable per-repo hook is SILENTLY SKIPPED (git's own behavior on Linux/macOS;
# the runner mirrors it). On Windows there's no executable bit, so we SKIP this leg with a named
# reason rather than assert a behavior the OS can't express.
_t_start L5.4b GOOD
if [ "${OS:-}" = "Windows_NT" ] || uname -s 2>/dev/null | grep -qiE 'mingw|msys|cygwin'; then
  _skip "no executable bit on Windows: non-exec skip is a POSIX-only guarantee"
else
  new_env; MARK="$WORK/marks"; mkdir -p "$MARK"
  mk_repo_hookable ne main
  export DF_MARK="$MARK/ne.txt"; rm -f "$DF_MARK"
  mkdir -p "$DOTFILES_ROOT/hooks/ne"
  { printf '#!/bin/sh\n'; printf 'echo ran > "$DF_MARK"\n'; } > "$DOTFILES_ROOT/hooks/ne/pre-commit"
  chmod -x "$DOTFILES_ROOT/hooks/ne/pre-commit"     # NOT executable
  commit_in ne .config/ne/x "z"; rc=$?
  assert_rc L5.4b "$rc" 0
  if [ ! -f "$DF_MARK" ]; then _pass; else _fail "L5.4b non-executable hook ran"; fi
fi

# ---------------------------------------------------------------------------
# L5.6 core.hooksPath set to a MISSING dir -> git runs no hooks (no runner, no crash); commit
# still succeeds. (Pairs with -doctor's "hooksPath target missing" warning, tested in node 7.)
_t_start L5.6 GOOD
new_env; MARK="$WORK/marks"; mkdir -p "$MARK"
mk_repo_hookable miss main
git --git-dir="$(bare_dir miss)" config core.hooksPath "$DOTFILES_ROOT/no-such-hooks-dir"
commit_in miss .config/miss/x "q"; rc=$?
assert_rc L5.6 "$rc" 0
assert_contains L5.6 "$(git --git-dir="$(bare_dir miss)" ls-tree -r --name-only HEAD)" ".config/miss/x"

# ---------------------------------------------------------------------------
# L5.x block: a non-zero per-repo hook BLOCKS the commit (runner surfaces the exit code).
_t_start L5.block BAD
new_env; MARK="$WORK/marks"; mkdir -p "$MARK"
mk_repo_hookable blk main
write_hook blk pre-commit 'echo "no" >&2; exit 3'
commit_in blk .config/blk/x "should-not-commit"; rc=$?
if [ "$rc" -ne 0 ]; then _pass; else _fail "L5.block commit was NOT blocked (rc=$rc)"; fi
# Nothing was committed: HEAD has no commits (unborn) -> ls-tree errors / empty.
tree="$(git --git-dir="$(bare_dir blk)" ls-tree -r --name-only HEAD 2>/dev/null)"
assert_not_contains L5.block "$tree" ".config/blk/x"

# ---------------------------------------------------------------------------
# L5.5 uv-missing: SKIP with a named reason (cannot safely unset uv from PATH on the shared
# runner without breaking the rest of the suite). The stub's fail-loud is covered by manual
# verification + the validate-githooks workflow which depends on uv being present.
_t_start L5.5 GOOD
_skip "cannot safely unset uv from PATH on the shared runner"

_summary
