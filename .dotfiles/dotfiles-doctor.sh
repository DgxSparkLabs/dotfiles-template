#!/usr/bin/env bash
# dotfiles-doctor.sh: Setup health-check for the bare-repo dotfiles system.
#
# Pure shell — deliberately NOT run through the uv runner, so that a broken uv
# install is still diagnosable. Each check prints PASS / FAIL / INFO with an
# actionable fix hint. Exits non-zero if any *hard* check FAILs.
#
# Network/SSH reachability is gated behind --skip-network (offline machines or a
# locked SSH agent would otherwise false-FAIL).

GIT_DIR="$HOME/.dotfiles"
WORK_TREE="$HOME"

SKIP_NETWORK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --git-dir) shift; GIT_DIR=$1 ;;
    --git-dir=*) GIT_DIR=${1#*=} ;;
    --work-tree) shift; WORK_TREE=$1 ;;
    --work-tree=*) WORK_TREE=${1#*=} ;;
    --skip-network) SKIP_NETWORK=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--git-dir <path>] [--work-tree <path>] [--skip-network]

Runs setup health-checks for the dotfiles bare repo at:
  $GIT_DIR  (work-tree: $WORK_TREE)

  --git-dir <path>     Override the bare-repo git dir (default: \$HOME/.dotfiles).
  --work-tree <path>   Override the work-tree (default: \$HOME).
  --skip-network       Omit network/SSH push-reachability checks (offline / locked agent).

Prints PASS/FAIL/INFO per check with a fix hint; exits non-zero on any hard FAIL.
EOF
      exit 0
      ;;
    *)
      printf 'dotfiles-doctor: unknown argument: %s\n' "$1" >&2
      printf 'Try --help for usage.\n' >&2
      exit 2
      ;;
  esac
  shift
done

HOOKS_PATH="$GIT_DIR/.githooks"
RUNNER_DIR="$GIT_DIR/githooks-runner"
TIMER_SH="$GIT_DIR/dotfiles-timer.sh"

dotfiles() { git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" "$@"; }

HARD_FAILS=0

pass() { printf '  PASS  %s\n' "$1"; }
info() { printf '  INFO  %s\n' "$1"; }
fail() {
  # fail <message> <fix-hint>
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        fix: %s\n' "$2"
  HARD_FAILS=$((HARD_FAILS + 1))
}

echo "dotfiles doctor — checking setup at $GIT_DIR"
echo ""

# 1. uv on PATH ─────────────────────────────────────────────────────────────
if command -v uv >/dev/null 2>&1; then
  pass "uv on PATH ($(command -v uv))"
else
  fail "uv not found on PATH" \
       "install uv (https://docs.astral.sh/uv/) and ensure it is on PATH where Git runs hooks"
fi

# 2. core.hooksPath ─────────────────────────────────────────────────────────
hooks_cfg="$(dotfiles config --get core.hooksPath 2>/dev/null)"
if [ "$hooks_cfg" = "$HOOKS_PATH" ]; then
  pass "core.hooksPath = $hooks_cfg"
else
  fail "core.hooksPath is '${hooks_cfg:-<unset>}' (expected $HOOKS_PATH)" \
       "git --git-dir \"$GIT_DIR\" config core.hooksPath \"$HOOKS_PATH\""
fi

# 3. status.showUntrackedFiles ──────────────────────────────────────────────
sut_cfg="$(dotfiles config --get status.showUntrackedFiles 2>/dev/null)"
if [ "$sut_cfg" = "no" ]; then
  pass "status.showUntrackedFiles = no"
else
  fail "status.showUntrackedFiles is '${sut_cfg:-<unset>}' (expected no)" \
       "git --git-dir \"$GIT_DIR\" config status.showUntrackedFiles no"
fi

# 4. venv synced ────────────────────────────────────────────────────────────
if [ ! -d "$RUNNER_DIR" ]; then
  fail "githooks-runner project not found at $RUNNER_DIR" \
       "ensure .dotfiles/ is checked out into your work-tree"
elif ! command -v uv >/dev/null 2>&1; then
  fail "cannot verify venv sync (uv missing)" \
       "install uv, then: uv sync --project \"$RUNNER_DIR\""
elif uv sync --project "$RUNNER_DIR" --frozen --check >/dev/null 2>&1; then
  pass "githooks-runner venv synced"
else
  fail "githooks-runner venv not synced" \
       "uv sync --project \"$RUNNER_DIR\""
fi

# 5. work-tree clean ────────────────────────────────────────────────────────
if dotfiles rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$(dotfiles status --porcelain 2>/dev/null)" ]; then
    pass "work-tree clean (no tracked changes)"
  else
    fail "work-tree has uncommitted tracked changes" \
         "review with: git --git-dir \"$GIT_DIR\" --work-tree \"$WORK_TREE\" status"
  fi
else
  fail "no git repo at $GIT_DIR" \
       "git clone --bare <your-dotfiles-remote> \"$GIT_DIR\""
fi

# 6. user_hooks (info only) ─────────────────────────────────────────────────
user_hooks_example="$RUNNER_DIR/dotfiles_githooks/user_hooks.example"
user_hooks_active="$RUNNER_DIR/dotfiles_githooks/user_hooks.py"
if [ -f "$user_hooks_example" ]; then
  info "user_hooks.example present ($user_hooks_example)"
else
  info "user_hooks.example not present (optional customization template)"
fi
if [ -f "$user_hooks_active" ]; then
  info "user_hooks.py activated — custom hook logic is in effect"
else
  info "user_hooks.py not activated (copy user_hooks.example to user_hooks.py to enable)"
fi

# 7. timer state (reuse dotfiles-timer status probes) ───────────────────────
if [ -f "$TIMER_SH" ]; then
  timer_unit="dotfiles-git-commit.timer"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-enabled "$timer_unit" >/dev/null 2>&1; then
      info "auto-commit timer enabled ($timer_unit)"
    else
      info "auto-commit timer not enabled (optional: dotfiles-timer install)"
    fi
  else
    info "systemd not available; check timer with: dotfiles-timer status"
  fi
else
  info "dotfiles-timer.sh not found at $TIMER_SH (auto-commit is optional)"
fi

# 8. network / SSH push reachability ────────────────────────────────────────
if [ "$SKIP_NETWORK" -eq 1 ]; then
  info "network/SSH push check skipped (--skip-network)"
else
  if ! dotfiles rev-parse --git-dir >/dev/null 2>&1; then
    fail "cannot check push reachability — no repo at $GIT_DIR" \
         "set up the bare repo first"
  else
    remote="$(dotfiles config --get branch."$(dotfiles symbolic-ref --short HEAD 2>/dev/null)".remote 2>/dev/null)"
    remote="${remote:-origin}"
    if ! dotfiles remote get-url "$remote" >/dev/null 2>&1; then
      fail "no remote '$remote' configured" \
           "git --git-dir \"$GIT_DIR\" remote add origin <your-dotfiles-remote>"
    elif dotfiles ls-remote --heads "$remote" >/dev/null 2>&1; then
      pass "remote '$remote' reachable (push/fetch network + auth OK)"
    else
      fail "remote '$remote' unreachable (network down or SSH agent locked)" \
           "check connectivity / unlock SSH agent, or re-run with --skip-network"
    fi
  fi
fi

echo ""
if [ "$HARD_FAILS" -gt 0 ]; then
  echo "doctor: $HARD_FAILS hard check(s) FAILED — see fix hints above."
  exit 1
fi
echo "doctor: all hard checks PASSED."
exit 0
