#!/bin/bash
# bootstrap.sh — restore a machine from scratch (run once on a fresh machine).
#
# The `dotfiles` alias lives in your profile — which hasn't been restored yet.
# This defines it temporarily, clones your bare repo, then checks out your
# machine's branch (which restores the profile and re-establishes the alias).
#
# Parameters (command-line arguments — preferred):
#   --repo <url>      (required) git remote URL, e.g. git@github.com:<YOU>/dotfiles.git
#   --branch <name>   (optional) branch to check out. If omitted, the machine name
#                     is auto-detected and you are prompted to confirm it or type
#                     a different branch.
#   <repo-url> [branch]  positional form, equivalent to the flags above.
#
# Fallback (only used when the matching argument is absent):
#   DOTFILES_REPO    git remote URL
#   DOTFILES_BRANCH  branch to check out
#
# Usage:
#   bash bootstrap.sh --repo git@github.com:<YOU>/dotfiles.git
#   bash bootstrap.sh --repo git@github.com:<YOU>/dotfiles.git --branch my-laptop
#   bash bootstrap.sh git@github.com:<YOU>/dotfiles.git my-laptop
#
# When no branch is given the script auto-detects this machine's name and asks
# you to confirm it (or type another branch). In a non-interactive context
# (no TTY, e.g. CI), pass --branch explicitly — the script errors instead of
# hanging on the prompt.

set -eu

usage() {
  cat >&2 <<'EOF'
Usage: bootstrap.sh --repo <url> [--branch <name>]
       bootstrap.sh <repo-url> [branch]

  --repo <url>     git remote URL of your dotfiles repo (required)
  --branch <name>  branch to check out (optional; you are prompted if omitted)

Falls back to $DOTFILES_REPO / $DOTFILES_BRANCH when the argument is absent.
EOF
}

# ── Parse arguments: flags take precedence, positional as a convenience ─────
REPO=""
BRANCH=""
branch_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   shift; [ $# -gt 0 ] || { echo "bootstrap.sh: --repo needs a value" >&2; usage; exit 1; }; REPO="$1" ;;
    --repo=*) REPO="${1#--repo=}" ;;
    --branch)   shift; [ $# -gt 0 ] || { echo "bootstrap.sh: --branch needs a value" >&2; usage; exit 1; }; BRANCH="$1"; branch_set=1 ;;
    --branch=*) BRANCH="${1#--branch=}"; branch_set=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "bootstrap.sh: unknown option: $1" >&2; usage; exit 1 ;;
    *)
      if [ -z "$REPO" ]; then REPO="$1"
      elif [ "$branch_set" -eq 0 ]; then BRANCH="$1"; branch_set=1
      else echo "bootstrap.sh: unexpected argument: $1" >&2; usage; exit 1
      fi
      ;;
  esac
  shift
done

# Trailing positionals after `--`.
if [ $# -gt 0 ]; then
  if [ -z "$REPO" ]; then REPO="$1"; shift; fi
  if [ $# -gt 0 ] && [ "$branch_set" -eq 0 ]; then BRANCH="$1"; branch_set=1; shift; fi
fi

# ── Repo: argument wins, env var is the documented fallback ─────────────────
if [ -z "$REPO" ]; then REPO="${DOTFILES_REPO:-}"; fi
if [ -z "$REPO" ]; then
  echo "bootstrap.sh: a repo URL is required (the git remote URL of your dotfiles repo)." >&2
  usage
  exit 1
fi

# Branch fallback: env var only when no --branch/positional was given.
if [ "$branch_set" -eq 0 ] && [ -n "${DOTFILES_BRANCH:-}" ]; then
  BRANCH="$DOTFILES_BRANCH"
  branch_set=1
fi

# ── Branch: explicit value, else auto-detect + confirm with the user ────────
detect_branch() {
  # WSL reports a Microsoft kernel; treat the whole WSL world as one branch.
  if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
    echo "WSL"
    return
  fi
  if [ -r /sys/class/dmi/id/board_name ]; then
    cat /sys/class/dmi/id/board_name
    return
  fi
  # Last resort: hostname.
  hostname
}

if [ "$branch_set" -eq 0 ]; then
  detected="$(detect_branch)"
  # Non-interactive guard: never hang waiting on a prompt (e.g. in CI).
  if [ ! -t 0 ]; then
    echo "bootstrap.sh: no branch given and stdin is not a TTY; cannot prompt." >&2
    echo "  Pass the branch explicitly, e.g. --branch $detected" >&2
    exit 1
  fi
  printf 'Detected machine branch: %s\n' "$detected" >&2
  printf 'Press Enter to use it, or type a different branch name: ' >&2
  read -r reply
  if [ -n "$reply" ]; then BRANCH="$reply"; else BRANCH="$detected"; fi
fi

echo "bootstrap.sh: repo=$REPO branch=$BRANCH"

git clone --bare "$REPO" "$HOME/.dotfiles"
# A function, not an alias: aliases are not expanded in non-interactive scripts.
dotfiles() { git --git-dir="$HOME/.dotfiles/" --work-tree="$HOME" "$@"; }
dotfiles config --local status.showUntrackedFiles no

# Git pathspecs (the `.` below) are CWD-relative. The bare repo's work-tree is
# $HOME, so cd there before checking out — otherwise running bootstrap from any
# subdirectory makes `.` resolve outside the tree ("pathspec '.' did not match").
cd "$HOME"

# Back up any conflicting OS defaults, then checkout
dotfiles checkout "$BRANCH" -- . 2>/dev/null || {
  dotfiles checkout "$BRANCH" 2>&1 | grep $'^\t' | while IFS= read -r file; do
    file="${file#$'\t'}"
    [ -e "$HOME/$file" ] && mv "$HOME/$file" "$HOME/$file.bak"
  done
  dotfiles checkout "$BRANCH" -- .
}

exec "${SHELL:-/bin/sh}"
