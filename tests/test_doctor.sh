#!/usr/bin/env bash
# Node 7 -doctor: health + the load-bearing exclusive-ownership invariant (bash/zsh).
# Every problem the doctor reports must print an ACTIONABLE fix line; the exit code is
# nonzero ONLY when at least one ERROR exists (overlap, or a corrupt/non-git repo).
# Cases: L0.13 clean, L0.14 overlap, L0.15 no-upstream, L0.16 detached HEAD,
# L0.17 hooksPath unset, L0.18 tick off info, L0.19 engine behind, L5.6 hooksPath target
# missing, L5.24 tick-on+hooksPath-unset, L5.25 partial migration, L5.26 engine not a git repo.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
. "$HERE/harness.sh"
. "$REPO/dotfiles.sh"

# Wire a repo's core.hooksPath to the engine's real githooks dir (so hooks read as "wired").
wire_hooks() { git --git-dir="$(bare_dir "$1")" config core.hooksPath "$REPO/githooks"; }

new_env

# ---------------------------------------------------------------------------
# L0.13 clean disjoint repos, hooks wired, upstream set, tick on -> all checks passed, exit 0.
_t_start L0.13 GOOD
mk_repo_with_origin nvim main
mk_repo_with_origin machine main
wire_hooks nvim
wire_hooks machine
dotfiles -config nvim.tick on
dotfiles -config machine.tick on
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L0.13 "$rc" 0
assert_contains L0.13 "$out" "all checks passed"
assert_contains L0.13 "$out" "no overlaps"
assert_contains L0.13 "$out" "hooks:wired"
assert_not_contains L0.13 "$out" "error(s)"          # clean -> no error summary line

# ---------------------------------------------------------------------------
# L0.14 two repos tracking ONE path -> ERROR + the path + `rm --cached` fix + nonzero exit.
_t_start L0.14 BAD
new_env
mk_repo_with_origin nvim main
mk_repo_with_origin machine main
printf 'shared\n' > "$HOME/.config/shared.cfg"
dotfiles nvim    add -- .config/shared.cfg
dotfiles nvim    commit -q -m "nvim: shared"
dotfiles machine add -- .config/shared.cfg
dotfiles machine commit -q -m "machine: shared"
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L0.14 "$rc" 1                                  # an ERROR -> nonzero exit
assert_contains L0.14 "$out" "OVERLAP"
assert_contains L0.14 "$out" ".config/shared.cfg"        # the offending path is named
assert_contains L0.14 "$out" "tracked by: machine, nvim" # both owners listed
assert_contains L0.14 "$out" "rm --cached .config/shared.cfg"   # the fix
assert_contains L0.14 "$out" "error(s)"                  # final summary

# ---------------------------------------------------------------------------
# L0.15 repo with no upstream -> warning + `push -u` fix; not an error (exit 0).
_t_start L0.15 BAD
new_env
gd="$(bare_dir noups)"
git init --bare -q "$gd"
git --git-dir="$gd" --work-tree="$HOME" symbolic-ref HEAD refs/heads/main
mkdir -p "$HOME/.config/noups"
printf 'seed\n' > "$HOME/.config/noups/seed"
git --git-dir="$gd" --work-tree="$HOME" add -- .config/noups/seed
git --git-dir="$gd" --work-tree="$HOME" commit -q -m "noups: seed"   # committed; NO upstream
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L0.15 "$rc" 0                                  # no upstream is a warning, not an error
assert_contains L0.15 "$out" "upstream (none)"
assert_contains L0.15 "$out" "no upstream for 'main'"
assert_contains L0.15 "$out" "push -u origin main"

# ---------------------------------------------------------------------------
# L0.16 detached HEAD -> warning + checkout fix; exit 0.
_t_start L0.16 BAD
new_env
mk_repo_with_origin det main
sha="$(git --git-dir="$(bare_dir det)" rev-parse HEAD)"
git --git-dir="$(bare_dir det)" --work-tree="$HOME" checkout -q --detach "$sha"
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L0.16 "$rc" 0
assert_contains L0.16 "$out" "branch detached"
assert_contains L0.16 "$out" "detached HEAD (no branch)"
assert_contains L0.16 "$out" "checkout <branch>"

# ---------------------------------------------------------------------------
# L0.17 core.hooksPath unset -> warning + config fix; hooks:MISSING; exit 0.
_t_start L0.17 BAD
new_env
mk_repo_with_origin nohooks main
# (deliberately do NOT wire hooks)
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L0.17 "$rc" 0
assert_contains L0.17 "$out" "hooks:MISSING"
assert_contains L0.17 "$out" "core.hooksPath not set"
assert_contains L0.17 "$out" 'config core.hooksPath'

# ---------------------------------------------------------------------------
# L0.18 tick OFF -> INFO line (not a warning/error); exit 0.
_t_start L0.18 GOOD
new_env
mk_repo_with_origin parked main
wire_hooks parked
# leave tick unset (default OFF)
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L0.18 "$rc" 0
assert_contains L0.18 "$out" "tick:off"
assert_contains L0.18 "$out" "tick is OFF (won't sync)"
assert_contains L0.18 "$out" "info -> dotfiles -config parked.tick on"

# ---------------------------------------------------------------------------
# L0.19 engine behind its upstream -> suggests `--update`.
# Build a fake engine: a normal repo with an origin one commit ahead, and reset HEAD back so
# HEAD..@{u} == 1. Point DOTFILES_COMMON at it for this test only.
_t_start L0.19 BAD
new_env
eng="$WORK/fakeengine"
eorigin="$WORK/fakeengine_origin.git"
git init -q "$eng"
( cd "$eng"
  printf 'v1\n' > f
  git add f; git commit -q -m "v1"
  git init --bare -q "$eorigin"
  git remote add origin "$eorigin"
  git push -q -u origin HEAD:refs/heads/main >/dev/null 2>&1
  git branch --set-upstream-to=origin/main >/dev/null 2>&1
  printf 'v2\n' > f
  git add f; git commit -q -m "v2"
  git push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git reset -q --hard HEAD~1 )   # now local is 1 behind origin/main
saved_common="$DOTFILES_COMMON"; DOTFILES_COMMON="$eng"
out="$(dotfiles -doctor 2>&1)"; rc=$?
DOTFILES_COMMON="$saved_common"
assert_rc L0.19 "$rc" 0                                  # engine-behind is a warning, not an error
assert_contains L0.19 "$out" "behind"
assert_contains L0.19 "$out" "dotfiles --update"

# ---------------------------------------------------------------------------
# L5.6 core.hooksPath set but its target dir is MISSING -> flagged with a fix; hooks:MISSING.
_t_start L5.6 BAD
new_env
mk_repo_with_origin h6 main
git --git-dir="$(bare_dir h6)" config core.hooksPath "$WORK/does/not/exist"
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L5.6 "$rc" 0
assert_contains L5.6 "$out" "hooks:MISSING"
assert_contains L5.6 "$out" "but that dir is missing"

# ---------------------------------------------------------------------------
# L5.24 tick ON but hooksPath unset -> a louder warning (auto-commits run no hooks).
_t_start L5.24 BAD
new_env
mk_repo_with_origin t24 main
dotfiles -config t24.tick on          # tick on, but hooks NOT wired
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L5.24 "$rc" 0
assert_contains L5.24 "$out" "tick:on"
assert_contains L5.24 "$out" "hooks:MISSING"
assert_contains L5.24 "$out" "tick is ON but core.hooksPath is unset"

# ---------------------------------------------------------------------------
# L5.25 partial migration: git-dir relocated but core.hooksPath still points at the OLD
# (pre-migration) path that no longer exists -> doctor detects the inconsistency and prints
# the remaining step (re-point hooksPath at the new engine githooks dir).
_t_start L5.25 BAD
new_env
mk_repo_with_origin t25 main
git --git-dir="$(bare_dir t25)" config core.hooksPath "$HOME/.dotfiles-OLD/githooks"   # stale path
out="$(dotfiles -doctor 2>&1)"; rc=$?
assert_rc L5.25 "$rc" 0
assert_contains L5.25 "$out" "but that dir is missing"
# The printed fix names the CURRENT engine githooks target (the remaining migration step).
assert_contains L5.25 "$out" 'githooks"'

# ---------------------------------------------------------------------------
# L5.26 engine dir exists but is NOT a git repo -> ERROR (`--update` would fail); doctor notes it.
_t_start L5.26 BAD
new_env
mk_repo_with_origin r26 main
wire_hooks r26
dotfiles -config r26.tick on
notgit="$WORK/notengine"; mkdir -p "$notgit"   # a plain dir, no .git
saved_common="$DOTFILES_COMMON"; DOTFILES_COMMON="$notgit"
out="$(dotfiles -doctor 2>&1)"; rc=$?
DOTFILES_COMMON="$saved_common"
assert_rc L5.26 "$rc" 1                                  # engine-not-a-repo is an ERROR
assert_contains L5.26 "$out" "NOT a git repo"
assert_contains L5.26 "$out" "dotfiles --update would fail"

_summary
