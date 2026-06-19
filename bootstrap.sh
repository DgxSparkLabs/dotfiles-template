#!/usr/bin/env bash
# bootstrap.sh — fresh-machine first-run setup for the dotfiles sync engine (bash/zsh).
#
# Node 10. Implements plan "A. First-run setup" in ONE run (steps 1-4); leaves step 5
# (verify + ENABLE the repo, `dotfiles -config machine.tick on`) to the user, deliberately —
# tick defaults OFF so a freshly cloned repo never auto-acts before you have verified it.
#
# What it does (idempotent + safe — never clobbers existing work):
#   1. Clone the ENGINE to ~/.dotfiles/common (from $DOTFILES_ENGINE_URL or --engine <url>).
#   2. Append the profile source-guard line ONCE (~/.bashrc or ~/.zshrc; never double-append).
#   3. Create the per-machine bare repo at ~/.dotfiles/bare-repos/machine from
#      $DOTFILES_MACHINE_URL / --machine <url> on a per-machine branch (default = hostname),
#      wiring core.hooksPath -> the engine githooks and status.showUntrackedFiles=no.
#      On a fresh machine, a tracked file that already exists in $HOME is BACKED UP (…​.bak-<ts>)
#      before checkout, mirroring the classic dotfiles-bootstrap pattern.
#   4. Install the single timer (`dotfiles -timer install`). Tick stays OFF until you enable it.
#
# Usage:
#   DOTFILES_ENGINE_URL=<engine-repo>  DOTFILES_MACHINE_URL=<machine-repo>  bash bootstrap.sh
#   bash bootstrap.sh --engine <url> --machine <url> [--branch <name>] [--root <dir>]
#
# Re-runnable: each step detects "already done" and skips. Use --root to target a non-default
# ~/.dotfiles (the test harness sets DOTFILES_ROOT).

set -uo pipefail

# --- arg / env parsing ---------------------------------------------------------------------
ENGINE_URL="${DOTFILES_ENGINE_URL:-}"
MACHINE_URL="${DOTFILES_MACHINE_URL:-}"
BRANCH="${DOTFILES_MACHINE_BRANCH:-}"
ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"

while [ $# -gt 0 ]; do
  case "$1" in
    --engine)  ENGINE_URL="$2"; shift 2 ;;
    --machine) MACHINE_URL="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --root)    ROOT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    *) printf 'bootstrap: unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

COMMON="$ROOT/common"
REPOS="$ROOT/bare-repos"
MACHINE_GD="$REPOS/machine"
# Engine URL default: a placeholder the user edits if none is supplied. We still proceed for
# steps the URL is not needed for, but warn loudly.
[ -z "$BRANCH" ] && BRANCH="$(hostname 2>/dev/null || printf '%s' "${HOSTNAME:-machine}")"

_say()  { printf 'bootstrap: %s\n' "$*"; }
_warn() { printf 'bootstrap: %s\n' "$*" >&2; }

mkdir -p "$ROOT" "$REPOS"

# --- 1. engine -> ~/.dotfiles/common -------------------------------------------------------
if [ -d "$COMMON/.git" ]; then
  _say "engine already present at $COMMON (skipping clone)"
elif [ -n "$ENGINE_URL" ]; then
  _say "cloning engine $ENGINE_URL -> $COMMON"
  git clone "$ENGINE_URL" "$COMMON" || { _warn "engine clone failed"; exit 1; }
else
  _warn "no engine URL (set DOTFILES_ENGINE_URL or --engine <url>); cannot clone engine"
  _warn "  fork the template, then: bash bootstrap.sh --engine <your-fork-url> --machine <url>"
  exit 1
fi

DISPATCHER="$COMMON/dotfiles.sh"
HOOKS_TARGET="$COMMON/githooks"

# --- 2. profile source-guard (idempotent) --------------------------------------------------
# Match the exact line from plan "Profile setup". Detect the marker substring so reformatting
# the guard never produces a duplicate.
PROFILE_LINE='[ -f "$HOME/.dotfiles/common/dotfiles.sh" ] && . "$HOME/.dotfiles/common/dotfiles.sh"'
PROFILE_MARKER='.dotfiles/common/dotfiles.sh'
# Choose ~/.zshrc under zsh, else ~/.bashrc. Honor DOTFILES_PROFILE override (tests).
if [ -n "${DOTFILES_PROFILE:-}" ]; then
  PROFILE="$DOTFILES_PROFILE"
elif [ -n "${ZSH_VERSION:-}" ]; then
  PROFILE="$HOME/.zshrc"
else
  PROFILE="$HOME/.bashrc"
fi
touch "$PROFILE"
if grep -Fq "$PROFILE_MARKER" "$PROFILE" 2>/dev/null; then
  _say "profile already sources the dispatcher ($PROFILE) (skipping)"
else
  {
    printf '\n# dotfiles sync engine (added by bootstrap)\n'
    printf '%s\n' "$PROFILE_LINE"
  } >> "$PROFILE"
  _say "added dispatcher source line to $PROFILE"
fi

# --- 3. per-machine bare repo --------------------------------------------------------------
if [ -d "$MACHINE_GD" ] && git --git-dir="$MACHINE_GD" rev-parse --git-dir >/dev/null 2>&1; then
  _say "machine repo already present at $MACHINE_GD (skipping clone)"
elif [ -n "$MACHINE_URL" ]; then
  _say "cloning machine repo $MACHINE_URL -> $MACHINE_GD (branch $BRANCH)"
  # Bare clone so $HOME is the work-tree. A plain `git clone --bare` sets remote.origin.url but
  # NO fetch refspec; add the standard refspec so @{upstream}/refs/remotes/origin/* exist.
  git clone --bare "$MACHINE_URL" "$MACHINE_GD" || { _warn "machine clone failed"; exit 1; }
  git --git-dir="$MACHINE_GD" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git --git-dir="$MACHINE_GD" config status.showUntrackedFiles no
  git --git-dir="$MACHINE_GD" fetch -q origin || true

  # NB: wire core.hooksPath AFTER the checkout (below) — a post-checkout hook (runner) returning
  # nonzero would otherwise make `git checkout` report failure and trip the conflict-backup path.
  # Safe checkout: back up any conflicting work-tree file before overwriting it (the classic
  # bare-dotfiles bootstrap pattern). Only checkout if the branch exists on the remote.
  if git --git-dir="$MACHINE_GD" rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1; then
    ts="$(date +%Y%m%d%H%M%S 2>/dev/null || printf '0')"
    # First attempt. Key off the EXIT CODE: if git refuses because tracked files already exist in
    # $HOME, it lists the offending paths (one per line, indented) — back each up, then retry once.
    co_out="$(git --git-dir="$MACHINE_GD" --work-tree="$HOME" checkout "$BRANCH" 2>&1)"; co_rc=$?
    if [ "$co_rc" -ne 0 ]; then
      _warn "work-tree files conflict; backing up then retrying checkout"
      printf '%s\n' "$co_out" | grep -E '^[[:space:]]+\S' | sed 's/^[[:space:]]*//' | while IFS= read -r f; do
        if [ -e "$HOME/$f" ]; then
          mkdir -p "$(dirname "$HOME/$f.bak-$ts")"
          mv "$HOME/$f" "$HOME/$f.bak-$ts" && _say "backed up $f -> $f.bak-$ts"
        fi
      done
      git --git-dir="$MACHINE_GD" --work-tree="$HOME" checkout "$BRANCH" >/dev/null 2>&1 \
        || _warn "checkout still failing after backup; resolve manually"
    fi
    git --git-dir="$MACHINE_GD" --work-tree="$HOME" branch --set-upstream-to "origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true
  else
    # Branch does not exist on remote yet: create it from current HEAD (or unborn) so the
    # machine has its own per-machine branch to push later.
    _say "branch $BRANCH not on remote; creating local branch $BRANCH"
    git --git-dir="$MACHINE_GD" --work-tree="$HOME" symbolic-ref HEAD "refs/heads/$BRANCH" 2>/dev/null \
      || git --git-dir="$MACHINE_GD" --work-tree="$HOME" checkout -b "$BRANCH" >/dev/null 2>&1 || true
  fi
  # Wire shared hooks now that the work-tree is in place (see note above).
  git --git-dir="$MACHINE_GD" config core.hooksPath "$HOOKS_TARGET"
else
  _warn "no machine repo URL (set DOTFILES_MACHINE_URL or --machine <url>); skipping machine repo"
  _warn "  create it later: git clone --bare <url> $MACHINE_GD"
fi

# --- 4. install the single timer (tick still OFF until you enable it) -----------------------
if [ -f "$DISPATCHER" ]; then
  _say "installing the single auto-tick timer"
  DOTFILES_ROOT="$ROOT" DOTFILES_COMMON="$COMMON" bash "$COMMON/timer/dotfiles-timer.sh" install || \
    _warn "timer install reported an issue (unit files may still be written)"
fi

# --- next steps (step 5 is deliberately manual) --------------------------------------------
cat <<EOF

bootstrap: setup complete. NEXT STEPS (do these yourself — tick defaults OFF for safety):
  1. Reload your shell:        exec \$SHELL
  2. Verify the machine repo:  dotfiles machine status
  3. Health check:             dotfiles -doctor
  4. THEN enable auto-sync:    dotfiles -config machine.tick on

Until step 4 the timer runs but ticks NOTHING (every repo's tick defaults OFF).
EOF
