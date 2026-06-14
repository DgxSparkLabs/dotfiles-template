#!/bin/bash
# bootstrap.sh — restore a machine from scratch (run once on a fresh machine).
#
# The `dotfiles` alias lives in your profile — which hasn't been restored yet.
# This defines it temporarily, clones your bare repo, then checks out your
# machine's branch (which restores the profile and re-establishes the alias).
#
# Parameters (environment variables):
#   DOTFILES_REPO    (required) git remote URL, e.g. git@github.com:<YOU>/dotfiles.git
#   DOTFILES_BRANCH  (optional) branch to check out. Defaults to the auto-detected
#                    machine name: the DMI board_name on Linux, or "WSL" under WSL.
#
# Usage:
#   DOTFILES_REPO=git@github.com:<YOU>/dotfiles.git bash bootstrap.sh
#   DOTFILES_REPO=... DOTFILES_BRANCH=my-laptop bash bootstrap.sh

set -eu

# ── Required parameter: fail fast if the remote URL is missing ──────────────
if [ -z "${DOTFILES_REPO:-}" ]; then
  echo "bootstrap.sh: DOTFILES_REPO is required (the git remote URL of your dotfiles repo)." >&2
  echo "  e.g. DOTFILES_REPO=git@github.com:<YOU>/dotfiles.git bash bootstrap.sh" >&2
  exit 1
fi
REPO="$DOTFILES_REPO"

# ── Branch: explicit override, else auto-detect this machine's name ─────────
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
BRANCH="${DOTFILES_BRANCH:-$(detect_branch)}"

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
