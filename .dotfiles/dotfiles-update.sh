#!/usr/bin/env bash
# dotfiles-update.sh: One-way master->machine propagation.
# Fetches origin/master and merges it into the current machine branch.
#
# master holds the system baseline; machines adopt system improvements via this
# one-way update. It is conflict-free in practice because system files (tracked
# on master) don't overlap the user files a machine edits. If a conflict DOES
# appear, the system/user partition was violated: we abort loudly rather than
# leave a half-merged work-tree.
#
# Manual by default. Pass --auto for unattended use (e.g. a scheduled wrapper):
# the merge semantics are identical; --auto only signals intent and is reserved
# for future non-interactive policy. Either way, a conflict aborts with exit 1.

set -u

GIT_DIR="$HOME/.dotfiles"
WORK_TREE="$HOME"

dotgit() {
  git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" "$@"
}

print_usage() {
  cat <<EOF
Usage: $0 [--auto]

Pulls system improvements from origin/master into this machine's branch:
  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE fetch origin master:refs/remotes/origin/master
  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE merge --no-edit origin/master

  (default)  Manual run.
  --auto     Opt-in unattended run (same merge; intended for scheduled wrappers).

On conflict the merge is aborted and the command exits non-zero — your work-tree
is left clean. Resolve by reconciling the system/user file partition.
EOF
}

AUTO=0
for arg in "$@"; do
  case "$arg" in
    --auto)      AUTO=1 ;;
    -h|--help)   print_usage; exit 0 ;;
    *)           echo "dotfiles update: unknown argument: $arg" >&2; print_usage >&2; exit 2 ;;
  esac
done

echo "dotfiles update: fetching origin/master (auto=$AUTO)"
# Explicit refspec updates the refs/remotes/origin/master tracking ref. A bare
# clone (the README setup) starts with NO remote-tracking refs and a refspec-less
# `fetch origin master` only writes FETCH_HEAD — leaving `merge origin/master` to
# fail with "not something we can merge". The refspec makes origin/master real.
if ! dotgit fetch origin "master:refs/remotes/origin/master"; then
  echo "dotfiles update: fetch failed (check SSH agent / network / remote)" >&2
  exit 1
fi

if ! dotgit merge --no-edit origin/master; then
  # Distinguish a real merge conflict (merge started, MERGE_HEAD exists) from a
  # merge that never began (e.g. refused / unrelated histories / bad ref). Only a
  # conflict warrants the loud partition message + `merge --abort`; aborting when
  # no merge is in progress errors "no merge to abort (MERGE_HEAD missing)".
  if ! dotgit rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    echo "dotfiles update: merge could not start (no merge in progress to abort)." >&2
    echo "dotfiles update: see the git error above; nothing was changed." >&2
    exit 1
  fi
  conflicts=$(dotgit diff --name-only --diff-filter=U)
  echo "" >&2
  echo "========================================================================" >&2
  echo "  DOTFILES UPDATE CONFLICT" >&2
  echo "" >&2
  echo "  Merging origin/master hit a conflict. This means a system file on" >&2
  echo "  master overlaps a file this machine has edited — the system/user" >&2
  echo "  partition has been violated." >&2
  echo "" >&2
  echo "  Conflicting files:" >&2
  if [ -n "$conflicts" ]; then
    printf '    %s\n' $conflicts >&2
  else
    echo "    (none reported by --diff-filter=U; see 'dotfiles status')" >&2
  fi
  echo "" >&2
  echo "  Aborting the merge — your work-tree is left clean (no partial merge)." >&2
  echo "========================================================================" >&2
  echo "" >&2
  dotgit merge --abort
  exit 1
fi

echo "dotfiles update: merged origin/master cleanly."
