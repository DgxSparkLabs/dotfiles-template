#!/usr/bin/env bash
# Node 5 never-block reconcile + surfaced resolution (bash/zsh): L2.2-L2.13.
# Two/three machines share ONE fake origin; ticks must reconcile divergence WITHOUT ever
# blocking, surface true clashes (newest committer-date wins, loser pinned + logged), and
# keep loser state LOCAL. Commit dates are pinned (GIT_*_DATE) for deterministic newest-wins.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
. "$HERE/harness.sh"
. "$REPO/dotfiles.sh"

# Pin a stable identity so committer == author and dates are honored.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test

# Helper: tick machine 1 (the new_env HOME/ROOT) for a repo, dates pinned by caller.
tick1() { ( dotfiles -config "$1.tick" on >/dev/null 2>&1; dotfiles -tick "$1" ); }

# ===========================================================================
# L2.2 same file, DIFFERENT lines -> auto-merge; BOTH edits survive, no markers.
_t_start L2.2 GOOD
new_env; reg_machine1
mk_repo_with_origin doc main
# seed a multi-line file owned by the repo, push it as the shared base.
printf 'l1\nl2\nl3\nl4\nl5\n' > "$HOME/.config/doc/file"
dotfiles doc add -- .config/doc/file >/dev/null 2>&1
dotfiles doc commit -q -m "doc: base" >/dev/null 2>&1
dotfiles doc push -q origin main >/dev/null 2>&1
mk_machine 2 doc main
# M1 edits line1; M2 edits line5 (disjoint lines of the same file).
sed -i 's/^l1$/M1L1/' "$HOME/.config/doc/file"
GIT_AUTHOR_DATE="2021-01-01T00:00:00" GIT_COMMITTER_DATE="2021-01-01T00:00:00" tick1 doc
write_machine 2 .config/doc/file "$(printf 'l1\nl2\nl3\nl4\nM2L5\n')"
GIT_AUTHOR_DATE="2021-02-01T00:00:00" GIT_COMMITTER_DATE="2021-02-01T00:00:00" tick_machine 2 doc
pull_machine 1 doc main
merged="$(read_machine 1 .config/doc/file)"
assert_contains     L2.2 "$merged" "M1L1"
assert_contains     L2.2 "$merged" "M2L5"
assert_not_contains L2.2 "$merged" "<<<<<<<"

# ===========================================================================
# L2.3 same LINE clash -> never blocks; newest committer-date wins; loser ref exists.
# M1 sets line5=X (older); M2 sets line5=Y (newer). Newest (M2, Y) must win.
_t_start L2.3 BAD
new_env; reg_machine1
mk_repo_with_origin clash main
printf 'top\nMID\nbot\n' > "$HOME/.config/clash/file"
dotfiles clash add -- .config/clash/file >/dev/null 2>&1
dotfiles clash commit -q -m base >/dev/null 2>&1
dotfiles clash push -q origin main >/dev/null 2>&1
mk_machine 2 clash main
# M1: MID->X older date, push.
sed -i 's/^MID$/X/' "$HOME/.config/clash/file"
GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" tick1 clash
# M2: MID->Y newer date; tick must fetch X, clash on the same line, never block, Y wins.
write_machine 2 .config/clash/file "$(printf 'top\nY\nbot\n')"
GIT_AUTHOR_DATE="2022-01-01T00:00:00" GIT_COMMITTER_DATE="2022-01-01T00:00:00" tick_machine 2 clash; rc=$?
assert_rc L2.3 "$rc" 0                       # never blocks
m2gd="$(mroot 2)/bare-repos/clash"
won="$(read_machine 2 .config/clash/file)"
assert_contains     L2.3 "$won" "Y"          # newest wins
assert_not_contains L2.3 "$won" "<<<<<<<"
# a loser ref was pinned on M2 (the resolving machine).
loser_ref="$(git --git-dir="$m2gd" for-each-ref --format='%(refname)' refs/sync-losers 2>/dev/null | head -n1)"
if [ -n "$loser_ref" ]; then _pass; else _fail "L2.3 no loser ref pinned"; fi

# ===========================================================================
# L2.4 loser PINNED: the ref resolves to the X (M1, losing) commit's blob content.
_t_start L2.4 GOOD
git --git-dir="$m2gd" rev-parse --verify "$loser_ref" >/dev/null 2>&1; rc=$?
assert_rc L2.4 "$rc" 0
loser_sha="$(git --git-dir="$m2gd" rev-parse --verify "$loser_ref")"
loser_blob="$(git --git-dir="$m2gd" ls-tree -r "$loser_sha" -- .config/clash/file | awk '{print $3}')"
assert_contains L2.4 "$(git --git-dir="$m2gd" cat-file -p "$loser_blob")" "X"   # loser held X

# ===========================================================================
# L2.5 clash LOGGED: state/<repo>/conflicts.log has a line with path+winner+loser.
_t_start L2.5 GOOD
logf="$(mroot 2)/state/clash/conflicts.log"
if [ -s "$logf" ]; then _pass; else _fail "L2.5 conflicts.log missing/empty"; fi
logtxt="$(cat "$logf" 2>/dev/null)"
assert_contains L2.5 "$logtxt" ".config/clash/file"
assert_contains L2.5 "$logtxt" "winner="
assert_contains L2.5 "$logtxt" "loser="

# ===========================================================================
# L2.6 conflicts.log + loser refs are LOCAL ONLY: absent from origin tree & ls-files.
_t_start L2.6 GOOD
otree="$(git --git-dir="$(origin_dir clash)" ls-tree -r --name-only refs/heads/main 2>/dev/null)"
assert_not_contains L2.6 "$otree" "conflicts.log"
assert_not_contains L2.6 "$otree" "sync-losers"
tracked="$(git --git-dir="$m2gd" --work-tree="$(mhome 2)" ls-files 2>/dev/null)"
assert_not_contains L2.6 "$tracked" "conflicts.log"
# origin has NO sync-losers refs (we only push refs/heads/<branch>).
orefs="$(git --git-dir="$(origin_dir clash)" for-each-ref --format='%(refname)' 2>/dev/null)"
assert_not_contains L2.6 "$orefs" "sync-losers"

# ===========================================================================
# L2.7 modify/delete -> never blocks; edit-beats-delete (file retained); logged.
_t_start L2.7 BAD
new_env; reg_machine1
mk_repo_with_origin md main
printf 'keepme\n' > "$HOME/.config/md/file"
dotfiles md add -- .config/md/file >/dev/null 2>&1
dotfiles md commit -q -m base >/dev/null 2>&1
dotfiles md push -q origin main >/dev/null 2>&1
mk_machine 2 md main
# M1 modifies the file, pushes.
printf 'EDITED\n' > "$HOME/.config/md/file"
GIT_AUTHOR_DATE="2021-01-01T00:00:00" GIT_COMMITTER_DATE="2021-01-01T00:00:00" tick1 md
# M2 deletes the file, then ticks -> modify(M1)/delete(M2): edit wins, file retained.
git --git-dir="$(mroot 2)/bare-repos/md" --work-tree="$(mhome 2)" rm -q -- .config/md/file >/dev/null 2>&1
GIT_AUTHOR_DATE="2022-01-01T00:00:00" GIT_COMMITTER_DATE="2022-01-01T00:00:00" tick_machine 2 md; rc=$?
assert_rc L2.7 "$rc" 0
if [ -f "$(mhome 2)/.config/md/file" ]; then _pass; else _fail "L2.7 edited file not retained (edit-beats-delete)"; fi
assert_contains L2.7 "$(read_machine 2 .config/md/file)" "EDITED"
assert_contains L2.7 "$(cat "$(mroot 2)/state/md/conflicts.log" 2>/dev/null)" ".config/md/file"

# ===========================================================================
# L2.8 commit-before-merge anti-clobber: an UNCOMMITTED local edit on M1 survives a tick
# even when origin has a (non-overlapping) change waiting. The local edit must be committed
# FIRST (present in history) and never lost to the incoming merge.
_t_start L2.8 GOOD
new_env; reg_machine1
mk_repo_with_origin anti main          # owns .config/anti, seeds .config/anti/seed
mk_machine 2 anti main
# M2 advances origin on a DIFFERENT file (so a merge is pending for M1).
write_machine 2 .config/anti/remote "from-m2"
( cd "$(mhome 2)"; git --git-dir="$(mroot 2)/bare-repos/anti" --work-tree="$(mhome 2)" add -- .config/anti/remote >/dev/null 2>&1 )
GIT_AUTHOR_DATE="2021-01-01T00:00:00" GIT_COMMITTER_DATE="2021-01-01T00:00:00" tick_machine 2 anti
# M1 has an UNCOMMITTED edit to its tracked seed file. add defaults to tracked (-u) so it stages it.
printf 'local-uncommitted-edit\n' > "$HOME/.config/anti/seed"
GIT_AUTHOR_DATE="2021-06-01T00:00:00" GIT_COMMITTER_DATE="2021-06-01T00:00:00" tick1 anti; rc=$?
assert_rc L2.8 "$rc" 0
# The local edit is in M1's history (committed before merge) ...
hist="$(git --git-dir="$DOTFILES_ROOT/bare-repos/anti" --work-tree="$HOME" log --all -p -- .config/anti/seed 2>/dev/null)"
assert_contains L2.8 "$hist" "local-uncommitted-edit"
# ... and still on disk, and the remote file merged in too.
assert_contains L2.8 "$(cat "$HOME/.config/anti/seed")" "local-uncommitted-edit"
if [ -f "$HOME/.config/anti/remote" ]; then _pass; else _fail "L2.8 remote change did not merge in"; fi

# ===========================================================================
# L2.9 push-reject then retry succeeds: a competing commit lands on origin BETWEEN M1's fetch
# and push. We simulate by having M2 push a non-overlapping change, then M1 tick once: the
# bounded retry loop re-fetches/re-merges and the push eventually lands. Final origin has both.
_t_start L2.9 BAD
new_env; reg_machine1
mk_repo_with_origin race main
mk_machine 2 race main
# M2 pushes a change to origin first (origin now ahead of M1).
write_machine 2 .config/race/m2 "m2change"
( git --git-dir="$(mroot 2)/bare-repos/race" --work-tree="$(mhome 2)" add -- .config/race/m2 >/dev/null 2>&1 )
GIT_AUTHOR_DATE="2021-01-01T00:00:00" GIT_COMMITTER_DATE="2021-01-01T00:00:00" tick_machine 2 race
# M1 makes its own change and ticks: first push would be rejected (origin ahead); reconcile+retry wins.
printf 'm1change\n' > "$HOME/.config/race/seed"
GIT_AUTHOR_DATE="2021-02-01T00:00:00" GIT_COMMITTER_DATE="2021-02-01T00:00:00" tick1 race; rc=$?
assert_rc L2.9 "$rc" 0
# Final origin tree has BOTH machines' files.
otree="$(git --git-dir="$(origin_dir race)" ls-tree -r --name-only refs/heads/main 2>/dev/null)"
assert_contains L2.9 "$otree" ".config/race/m2"
assert_contains L2.9 "$otree" ".config/race/seed"

# ===========================================================================
# L2.10 push-reject EXHAUST -> tick logs + skips + does not block; work-tree intact; next
# tick recovers. We force exhaustion by keeping origin moving past the retry budget via a
# wrapper `git` shim that pushes a fresh competing commit to origin on every push attempt.
_t_start L2.10 BAD
new_env; reg_machine1
mk_repo_with_origin ex main
gd_ex="$DOTFILES_ROOT/bare-repos/ex"
# Force EVERY push attempt to fail, simulating an origin that keeps moving past the retry
# budget (peer pushes faster than we can reconcile). A `pre-push` hook that exits nonzero
# rejects each attempt deterministically (no timing/race flakiness). The reconcile loop
# re-fetches/re-merges and retries to the ceiling, then the tick must LOG + SKIP (never block),
# leaving the work-tree intact. Removing the hook lets the NEXT tick recover.
mkdir -p "$gd_ex/hooks"
printf '#!/usr/bin/env bash\nexit 1\n' > "$gd_ex/hooks/pre-push"
chmod +x "$gd_ex/hooks/pre-push"
printf 'm1-exhaust\n' > "$HOME/.config/ex/seed"
dotfiles -config ex.tick on >/dev/null 2>&1
out="$(dotfiles -tick ex 2>&1)"; rc=$?
# Tick returns nonzero (push skipped) but DID NOT block (it returned) and logged a reason.
if [ "$rc" -ne 0 ]; then _pass; else _fail "L2.10 expected nonzero (push skipped), got $rc"; fi
assert_contains L2.10 "$out" "not completed this tick"
# Work-tree edit intact (never clobbered).
assert_contains L2.10 "$(cat "$HOME/.config/ex/seed")" "m1-exhaust"
# Next tick recovers: remove the rejecting hook so origin stops moving -> a normal tick pushes.
rm -f "$gd_ex/hooks/pre-push"
dotfiles -tick ex; rc2=$?
assert_rc L2.10 "$rc2" 0
assert_contains L2.10 "$(git --git-dir="$(origin_dir ex)" ls-tree -r --name-only refs/heads/main)" ".config/ex/seed"

# ===========================================================================
# L2.11 three machines converge to the same tree (disjoint files).
_t_start L2.11 GOOD
new_env; reg_machine1
mk_repo_with_origin tri main
mk_machine 2 tri main
mk_machine 3 tri main
write_machine 1 .config/tri/a "AAA"   # M1 owns seed already; add a file under its dir
( git --git-dir="$DOTFILES_ROOT/bare-repos/tri" --work-tree="$HOME" add -- .config/tri/a >/dev/null 2>&1 )
GIT_AUTHOR_DATE="2021-01-01T00:00:00" GIT_COMMITTER_DATE="2021-01-01T00:00:00" tick1 tri
write_machine 2 .config/tri/b "BBB"
( git --git-dir="$(mroot 2)/bare-repos/tri" --work-tree="$(mhome 2)" add -- .config/tri/b >/dev/null 2>&1 )
GIT_AUTHOR_DATE="2021-01-02T00:00:00" GIT_COMMITTER_DATE="2021-01-02T00:00:00" tick_machine 2 tri
write_machine 3 .config/tri/c "CCC"
( git --git-dir="$(mroot 3)/bare-repos/tri" --work-tree="$(mhome 3)" add -- .config/tri/c >/dev/null 2>&1 )
GIT_AUTHOR_DATE="2021-01-03T00:00:00" GIT_COMMITTER_DATE="2021-01-03T00:00:00" tick_machine 3 tri
# Second round so everyone converges.
GIT_AUTHOR_DATE="2021-01-04T00:00:00" GIT_COMMITTER_DATE="2021-01-04T00:00:00" tick1 tri
GIT_AUTHOR_DATE="2021-01-05T00:00:00" GIT_COMMITTER_DATE="2021-01-05T00:00:00" tick_machine 2 tri
GIT_AUTHOR_DATE="2021-01-06T00:00:00" GIT_COMMITTER_DATE="2021-01-06T00:00:00" tick_machine 3 tri
GIT_AUTHOR_DATE="2021-01-07T00:00:00" GIT_COMMITTER_DATE="2021-01-07T00:00:00" tick1 tri
pull_machine 2 tri main
pull_machine 3 tri main
t1="$(git --git-dir="$DOTFILES_ROOT/bare-repos/tri" rev-parse 'HEAD^{tree}' 2>/dev/null)"
t2="$(git --git-dir="$(mroot 2)/bare-repos/tri" rev-parse 'FETCH_HEAD^{tree}' 2>/dev/null)"
t3="$(git --git-dir="$(mroot 3)/bare-repos/tri" rev-parse 'FETCH_HEAD^{tree}' 2>/dev/null)"
# All three machines see all three files.
for m in 1 2 3; do
  f="$(git --git-dir="$( [ $m = 1 ] && echo "$DOTFILES_ROOT" || mroot $m )/bare-repos/tri" ls-tree -r --name-only "$( [ $m = 1 ] && echo HEAD || echo FETCH_HEAD )" 2>/dev/null)"
  assert_contains L2.11 "$f" ".config/tri/a"
  assert_contains L2.11 "$f" ".config/tri/b"
  assert_contains L2.11 "$f" ".config/tri/c"
done

# ===========================================================================
# L2.12 -resolve writes <path>.loser with the losing content. Reuse the L2.3-style clash,
# but run -resolve AS machine 2 (where the loser was pinned). Loser held "X".
_t_start L2.12 GOOD
new_env; reg_machine1
mk_repo_with_origin rec main
printf 'a\nMID\nb\n' > "$HOME/.config/rec/file"
dotfiles rec add -- .config/rec/file >/dev/null 2>&1
dotfiles rec commit -q -m base >/dev/null 2>&1
dotfiles rec push -q origin main >/dev/null 2>&1
mk_machine 2 rec main
sed -i 's/^MID$/X/' "$HOME/.config/rec/file"
GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" tick1 rec
write_machine 2 .config/rec/file "$(printf 'a\nY\nb\n')"
GIT_AUTHOR_DATE="2022-01-01T00:00:00" GIT_COMMITTER_DATE="2022-01-01T00:00:00" tick_machine 2 rec
# Resolve as machine 2.
out="$( HOME="$(mhome 2)" DOTFILES_ROOT="$(mroot 2)" bash -c '
  . "'"$REPO"'/dotfiles.sh"; dotfiles -resolve .config/rec/file 2>&1; echo "rc=$?"' )"
rc="$(printf '%s' "$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p' | tail -n1)"
assert_rc L2.12 "${rc:-1}" 0
assert_contains L2.12 "$out" "loser written to:"
loserfile="$(mhome 2)/.config/rec/file.loser"
if [ -f "$loserfile" ]; then _pass; else _fail "L2.12 .loser file not written"; fi
assert_contains L2.12 "$(cat "$loserfile" 2>/dev/null)" "X"   # losing side held X

# ===========================================================================
# L2.13 deterministic newest: SAME clash run twice with dates SWAPPED -> winner FLIPS.
# Proves committer-date drives the decision (not push order, which is identical both times).
_t_start L2.13 GOOD
# Run 1: M1=X older, M2=Y newer -> Y wins (already covered, but assert here freshly).
run_clash() {  # $1=m1date $2=m2date ; echoes the winning content seen on M2
  new_env; reg_machine1
  mk_repo_with_origin det main
  printf 'a\nMID\nb\n' > "$HOME/.config/det/file"
  dotfiles det add -- .config/det/file >/dev/null 2>&1
  dotfiles det commit -q -m base >/dev/null 2>&1
  dotfiles det push -q origin main >/dev/null 2>&1
  mk_machine 2 det main
  sed -i 's/^MID$/X/' "$HOME/.config/det/file"
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" tick1 det
  write_machine 2 .config/det/file "$(printf 'a\nY\nb\n')"
  GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" tick_machine 2 det >/dev/null 2>&1
  read_machine 2 .config/det/file
}
w1="$(run_clash 2020-01-01T00:00:00 2022-01-01T00:00:00)"   # M2(Y) newer -> Y wins
w2="$(run_clash 2022-01-01T00:00:00 2020-01-01T00:00:00)"   # M1(X) newer -> X wins
assert_contains L2.13 "$w1" "Y"
assert_contains L2.13 "$w2" "X"
# And the winner genuinely FLIPPED between the two runs.
if [ "$w1" != "$w2" ]; then _pass; else _fail "L2.13 winner did not flip with swapped dates"; fi

_summary
