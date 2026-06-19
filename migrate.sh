#!/usr/bin/env bash
# migrate.sh — migrate an EXISTING single-repo dotfiles user to the container layout (bash/zsh).
#
# Node 10. The legacy layout (old single-repo template) was a BARE git-dir AT ~/.dotfiles
# (HEAD/objects/refs directly under ~/.dotfiles) plus helper files under ~/.dotfiles/.dotfiles/.
# The new layout separates concerns:
#     ~/.dotfiles/common/                 ENGINE (this repo / your fork) — the mechanism
#     ~/.dotfiles/bare-repos/machine/     the legacy bare git-dir, RELOCATED here
#     ~/.dotfiles/hooks/  config  state/  per-repo data, beside (never inside) the bare repos
# Work-tree files in $HOME NEVER move — only the git metadata relocates and the engine splits out.
# The container layout is a deliberate one-time breaking change.
#
# Steps, in SAFE order (each idempotent; re-runnable; aborts clearly if state is ambiguous):
#   a. detect the legacy layout (bare repo metadata directly under ~/.dotfiles).
#   b. STOP the OLD timer FIRST (it baked the old GIT_DIR; a stale committer must not write to a
#      git-dir we are about to empty).
#   c. move the legacy bare git-dir contents into ~/.dotfiles/bare-repos/machine/.
#   d. ensure the engine is at ~/.dotfiles/common (clone from --engine/$DOTFILES_ENGINE_URL if absent).
#   e. set the machine repo's core.hooksPath -> the engine githooks (and status.showUntrackedFiles=no).
#   f. replace the old dotfiles/dotfiles-timer aliases in the profile with the sourced dispatcher.
#   g. install the new single timer (`dotfiles -timer install`). Tick stays OFF until you enable it.
#
# Usage:
#   bash migrate.sh [--engine <url>] [--root <dir>]
#   DOTFILES_ENGINE_URL=<url> bash migrate.sh
# Re-running after a completed migration is a safe no-op.

set -uo pipefail

ENGINE_URL="${DOTFILES_ENGINE_URL:-}"
ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"

while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE_URL="$2"; shift 2 ;;
    --root)   ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) printf 'migrate: unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

COMMON="$ROOT/common"
REPOS="$ROOT/bare-repos"
MACHINE_GD="$REPOS/machine"
HOOKS_TARGET="$COMMON/githooks"

_say()  { printf 'migrate: %s\n' "$*"; }
_warn() { printf 'migrate: %s\n' "$*" >&2; }
_abort(){ printf 'migrate: ABORT: %s\n' "$*" >&2; exit 1; }

# --- a. detect the legacy layout -----------------------------------------------------------
# Legacy = a bare git-dir whose metadata sits DIRECTLY under $ROOT (HEAD + objects/ + refs/),
# i.e. `git --git-dir=$ROOT rev-parse` works AND $ROOT/HEAD exists. The NEW layout has no such
# metadata at $ROOT (its repos live under bare-repos/<name>).
legacy_present=0
if [ -f "$ROOT/HEAD" ] && [ -d "$ROOT/objects" ] && git --git-dir="$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  legacy_present=1
fi

already_migrated=0
if [ -d "$MACHINE_GD" ] && git --git-dir="$MACHINE_GD" rev-parse --git-dir >/dev/null 2>&1; then
  already_migrated=1
fi

if [ "$legacy_present" -eq 0 ] && [ "$already_migrated" -eq 1 ]; then
  _say "already migrated: machine repo is at $MACHINE_GD and no legacy git-dir at $ROOT"
  # Still ensure hooksPath + engine + timer are correct (idempotent finish).
elif [ "$legacy_present" -eq 0 ] && [ "$already_migrated" -eq 0 ]; then
  _abort "no legacy layout found at $ROOT (no bare git-dir there) and no machine repo to finish.
        If this is a fresh machine, run bootstrap.sh instead."
elif [ "$legacy_present" -eq 1 ] && [ "$already_migrated" -eq 1 ]; then
  _abort "ambiguous state: a legacy git-dir AND a migrated machine repo both exist.
        Resolve by hand: inspect $ROOT (legacy) vs $MACHINE_GD (new), then remove the stale one."
else
  _say "legacy single-repo layout detected at $ROOT"
fi

# --- b. STOP the OLD timer FIRST (before moving the git-dir) --------------------------------
# The legacy timer baked the old GIT_DIR=$ROOT into its payload; if it fires after we empty
# $ROOT it would write to a dead git-dir. Stop every legacy mechanism we can find, best-effort.
_say "stopping any legacy timer (before relocating the git-dir)"
# 1. Legacy systemd user timer (same singleton name kept across versions).
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now dotfiles-git-commit.timer  >/dev/null 2>&1 || true
  systemctl --user disable --now dotfiles-git-commit.service >/dev/null 2>&1 || true
fi
# 2. Legacy launchd agent (macOS), if a plist with the legacy label is loaded.
if command -v launchctl >/dev/null 2>&1; then
  launchctl remove dotfiles-git-commit >/dev/null 2>&1 || true
fi
# 3. If the new engine is already present, its uninstall is the cleanest stop.
if [ -f "$COMMON/timer/dotfiles-timer.sh" ]; then
  DOTFILES_ROOT="$ROOT" DOTFILES_COMMON="$COMMON" bash "$COMMON/timer/dotfiles-timer.sh" uninstall >/dev/null 2>&1 || true
fi

# --- c. relocate the legacy bare git-dir into bare-repos/machine ----------------------------
mkdir -p "$REPOS"
if [ "$legacy_present" -eq 1 ]; then
  if [ "$already_migrated" -eq 1 ]; then
    _abort "machine repo already exists at $MACHINE_GD; refusing to overwrite. Remove it first if you intend to re-migrate."
  fi
  _say "moving legacy git-dir contents from $ROOT -> $MACHINE_GD (work-tree files in \$HOME stay put)"
  mkdir -p "$MACHINE_GD"
  # Move ONLY the git metadata (HEAD, config, objects, refs, etc.) that lives directly under
  # $ROOT. Never touch the new container subdirs (common/, bare-repos/, hooks/, state/) nor the
  # legacy helper subtree ($ROOT/.dotfiles) — those are NOT git metadata.
  moved=0
  for entry in "$ROOT"/* "$ROOT"/.*; do
    base="$(basename "$entry")"
    case "$base" in
      .|..) continue ;;
      common|bare-repos|hooks|config|state) continue ;;   # new-layout dirs, leave alone
      .dotfiles) continue ;;                                # legacy helper subtree — dropped (engine replaces it)
    esac
    [ -e "$entry" ] || continue
    mv "$entry" "$MACHINE_GD/" && moved=$((moved+1))
  done
  _say "relocated $moved git-dir entr(ies)"
  # Sanity: the moved dir must now be a valid git-dir.
  git --git-dir="$MACHINE_GD" rev-parse --git-dir >/dev/null 2>&1 \
    || _abort "relocated $MACHINE_GD is not a valid git-dir; restore from $ROOT and retry."
fi

# --- d. ensure the engine is at ~/.dotfiles/common -----------------------------------------
if [ -d "$COMMON/.git" ]; then
  _say "engine already present at $COMMON"
elif [ -n "$ENGINE_URL" ]; then
  _say "cloning engine $ENGINE_URL -> $COMMON"
  git clone "$ENGINE_URL" "$COMMON" || _abort "engine clone failed"
else
  _warn "no engine at $COMMON and no --engine/\$DOTFILES_ENGINE_URL given."
  _warn "  clone your fork there: git clone <engine-url> $COMMON   (then re-run migrate.sh)"
fi

# --- e. wire the machine repo's core.hooksPath + showUntrackedFiles -------------------------
if git --git-dir="$MACHINE_GD" rev-parse --git-dir >/dev/null 2>&1; then
  git --git-dir="$MACHINE_GD" config core.hooksPath "$HOOKS_TARGET"
  git --git-dir="$MACHINE_GD" config status.showUntrackedFiles no
  _say "set machine core.hooksPath -> $HOOKS_TARGET"
fi

# --- f. replace old aliases in the profile with the sourced dispatcher ----------------------
PROFILE_LINE='[ -f "$HOME/.dotfiles/common/dotfiles.sh" ] && . "$HOME/.dotfiles/common/dotfiles.sh"'
PROFILE_MARKER='.dotfiles/common/dotfiles.sh'
if [ -n "${DOTFILES_PROFILE:-}" ]; then
  PROFILE="$DOTFILES_PROFILE"
elif [ -n "${ZSH_VERSION:-}" ]; then
  PROFILE="$HOME/.zshrc"
else
  PROFILE="$HOME/.bashrc"
fi
if [ -f "$PROFILE" ]; then
  # Strip legacy alias lines: any line defining `alias dotfiles=` / `alias dotfiles-timer=` /
  # `alias dotfiles-sync=` (the old wrappers), and any line that sourced the OLD helper path
  # ($ROOT/.dotfiles/...). Leave everything else untouched. Write via a temp file (portable).
  tmp="$(mktemp)"
  grep -vE "^[[:space:]]*alias[[:space:]]+dotfiles(-timer|-sync)?=" "$PROFILE" \
    | grep -vF '/.dotfiles/.dotfiles/' > "$tmp" 2>/dev/null || cp "$PROFILE" "$tmp"
  cat "$tmp" > "$PROFILE"
  rm -f "$tmp"
  _say "removed legacy dotfiles aliases from $PROFILE (if any)"
fi
touch "$PROFILE"
if grep -Fq "$PROFILE_MARKER" "$PROFILE" 2>/dev/null; then
  _say "profile already sources the dispatcher ($PROFILE)"
else
  {
    printf '\n# dotfiles sync engine (added by migrate)\n'
    printf '%s\n' "$PROFILE_LINE"
  } >> "$PROFILE"
  _say "added dispatcher source line to $PROFILE"
fi

# --- g. install the new single timer (tick OFF until you enable it) -------------------------
if [ -f "$COMMON/timer/dotfiles-timer.sh" ]; then
  _say "installing the new single auto-tick timer"
  DOTFILES_ROOT="$ROOT" DOTFILES_COMMON="$COMMON" bash "$COMMON/timer/dotfiles-timer.sh" install \
    || _warn "timer install reported an issue (unit files may still be written)"
fi

cat <<EOF

migrate: done. Your machine config now lives at $MACHINE_GD; the engine at $COMMON.
NEXT STEPS (tick defaults OFF for safety):
  1. Reload your shell:        exec \$SHELL
  2. Verify:                   dotfiles machine status   &&   dotfiles -doctor
  3. THEN enable auto-sync:    dotfiles -config machine.tick on
(Note: the old \`dotfiles update\` master->machine flow is re-homed — use \`dotfiles machine merge master\`.)
EOF
