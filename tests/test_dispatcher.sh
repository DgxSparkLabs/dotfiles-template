#!/usr/bin/env bash
# Node 2 dispatcher tests (bash/zsh): L0.1-L0.7, L1.12-L1.13, L5.13.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
. "$HERE/harness.sh"
. "$REPO/dotfiles.sh"

new_env
mk_repo machine
mk_repo nvim
mk_repo show              # a repo deliberately named like a management verb

# L0.1 passthrough routing (rev-parse avoids touching $HOME work-tree)
_t_start L0.1 GOOD
out="$(dotfiles machine rev-parse --absolute-git-dir 2>/dev/null)"
assert_contains L0.1 "$out" "bare-repos/machine"

# L0.2 -ls == --ls
_t_start L0.2 GOOD
assert_eq L0.2 "$(dotfiles -ls 2>/dev/null | sort)" "$(dotfiles --ls 2>/dev/null | sort)"

# L0.3 every verb (1 or 2 dashes) dispatches — none is reported "unknown"
_t_start L0.3 GOOD
allout=""
for v in ls config tick doctor show resolve help; do
  allout+="$(dotfiles --"$v" 2>&1; dotfiles -"$v" 2>&1)"
done
assert_not_contains L0.3 "$allout" "unknown command"

# L0.4 unknown verb -> exit 2 + message
_t_start L0.4 BAD
dotfiles -bogus >/dev/null 2>"$WORK/err"; rc=$?
assert_rc L0.4 "$rc" 2
assert_contains L0.4 "$(cat "$WORK/err")" "unknown command"

# L0.5 no such repo -> exit 1 + message
_t_start L0.5 BAD
dotfiles ghost rev-parse >/dev/null 2>"$WORK/err"; rc=$?
assert_rc L0.5 "$rc" 1
assert_contains L0.5 "$(cat "$WORK/err")" "no such repo"

# L0.6 repo named like a verb still routes to the repo
_t_start L0.6 GOOD
out="$(dotfiles show rev-parse --absolute-git-dir 2>/dev/null)"
assert_contains L0.6 "$out" "bare-repos/show"

# L0.7 empty args == -ls
_t_start L0.7 GOOD
assert_eq L0.7 "$(dotfiles 2>/dev/null | sort)" "$(dotfiles -ls 2>/dev/null | sort)"

# L1.12 discovery: a newly dropped bare repo appears
_t_start L1.12 GOOD
mk_repo addedlater
assert_contains L1.12 "$(dotfiles -ls)" "addedlater"

# L1.13 discovery: a removed repo disappears
_t_start L1.13 GOOD
rm -rf "$DOTFILES_ROOT/bare-repos/addedlater"
assert_not_contains L1.13 "$(dotfiles -ls)" "addedlater"

# L5.13 a non-git directory under bare-repos/ is skipped (not listed)
_t_start L5.13 BAD
mkdir -p "$DOTFILES_ROOT/bare-repos/junkdir"
assert_not_contains L5.13 "$(dotfiles -ls)" "junkdir"

_summary
