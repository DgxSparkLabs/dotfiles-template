#!/usr/bin/env bash
# dotfiles-update.sh: One-way system->machine propagation.
# Fetches the named system baseline and merges it into the current machine branch.
#
# `system` (override with git config dotfiles.systemRef) holds the system
# baseline; machines adopt system improvements via this one-way update. It is
# conflict-free in practice because system files (tracked on the system ref)
# don't overlap the user files a machine edits. If a conflict DOES appear, the
# system/user partition was violated: we abort loudly rather than leave a
# half-merged work-tree.
#
# The system ref is a branch name (default: system; git config dotfiles.systemRef).
# Any name `git check-ref-format --branch` accepts is allowed. It is never
# resolved via origin/HEAD, which aliases whatever the host calls default.
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

# Named baseline. Empty / HEAD / origin/HEAD alias the host default, so they
# are not branch names. Any other string git accepts as a branch is allowed.
# Resolved in this shell (not a command-substitution subshell) so a bad ref
# actually exits the script.
SYSTEM_REF="$(dotgit config --get dotfiles.systemRef 2>/dev/null || true)"
SYSTEM_REF="${SYSTEM_REF:-system}"
case "$SYSTEM_REF" in
  ''|HEAD|origin/HEAD)
    echo "dotfiles update: refusing system ref '$SYSTEM_REF' (not a branch name; it aliases the host default)." >&2
    echo "  Set a branch name: git --git-dir=\"$GIT_DIR\" config dotfiles.systemRef system" >&2
    exit 1
    ;;
esac
if ! git check-ref-format --branch "$SYSTEM_REF" >/dev/null 2>&1; then
  echo "dotfiles update: '$SYSTEM_REF' is not a valid branch name." >&2
  echo "  Set one with: git --git-dir=\"$GIT_DIR\" config dotfiles.systemRef <name>" >&2
  exit 1
fi

print_usage() {
  cat <<EOF
Usage: $0 [--auto]

Pulls system improvements from origin/$SYSTEM_REF into this machine's branch:
  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE fetch origin $SYSTEM_REF:refs/remotes/origin/$SYSTEM_REF
  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE merge --no-edit origin/$SYSTEM_REF

  (default)  Manual run.
  --auto     Opt-in unattended run (same merge; intended for scheduled wrappers).

The system ref is whatever \`git config dotfiles.systemRef\` names (default: system).
Any valid branch name is allowed. origin/HEAD is never followed.

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

echo "dotfiles update: fetching origin/$SYSTEM_REF (auto=$AUTO)"
# Explicit refspec updates the refs/remotes/origin/<system> tracking ref. A bare
# clone (the README setup) starts with NO remote-tracking refs and a refspec-less
# `fetch origin system` only writes FETCH_HEAD — leaving `merge origin/system` to
# fail with "not something we can merge". The refspec makes origin/<system> real.
if ! dotgit fetch origin "$SYSTEM_REF:refs/remotes/origin/$SYSTEM_REF"; then
  echo "dotfiles update: fetch failed (check SSH agent / network / remote)" >&2
  exit 1
fi

if ! dotgit merge --no-edit "origin/$SYSTEM_REF"; then
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
  echo "  Merging origin/$SYSTEM_REF hit a conflict. This means a system file on" >&2
  echo "  $SYSTEM_REF overlaps a file this machine has edited — the system/user" >&2
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

echo "dotfiles update: merged origin/$SYSTEM_REF cleanly."
