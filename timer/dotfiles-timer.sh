#!/usr/bin/env bash
# dotfiles-timer.sh: Manage the SINGLE systemd user timer that runs the dotfiles sync tick.
#
# Node 9 — the one installed timer no longer bakes a single-repo add/commit/push payload.
# Its payload now calls the dispatcher's fan-out: `dotfiles -tick` loops EVERY repo under
# ~/.dotfiles/bare-repos/ (discovery is the registry — a new repo on disk is ticked next cycle).
# Exactly one unit/timer is ever installed, regardless of how many repos exist.
#
# Cadence + de-sync:
#   [timer] interval  (seconds, default 60)  -> OnUnitActiveSec
#   [timer] jitter    (+- seconds, default 15) -> systemd RandomizedDelaySec AND a per-fire
#                       randomized 0..jitter sleep baked into the payload script (so N machines
#                       don't push in lockstep). The jitter value is embedded in the generated
#                       artifact so it is testable without a live manager.

# The engine lives at <root>/common/; this script is <root>/common/timer/dotfiles-timer.sh.
TIMER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DOTFILES_COMMON="${DOTFILES_COMMON:-$(cd "$TIMER_DIR/.." && pwd)}"
DOTFILES_ROOT="${DOTFILES_ROOT:-$(cd "$DOTFILES_COMMON/.." && pwd)}"
DISPATCHER="$DOTFILES_COMMON/dotfiles.sh"

SERVICE_NAME="dotfiles-git-commit"        # singleton name kept from the legacy timer
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
TIMER_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.timer"
SCRIPT_FILE="$DOTFILES_ROOT/.dotfiles-tick.sh"   # generated payload (calls dotfiles -tick)
TIMER_UNIT="${SERVICE_NAME}.timer"
SERVICE_UNIT="${SERVICE_NAME}.service"

# Read the [timer] settings via the dispatcher's own readers (single source of truth). Sourcing
# the dispatcher defines __df_setting_timer_interval/jitter; fall back to defaults if unavailable.
__timer_settings() {
  TIMER_INTERVAL=60
  TIMER_JITTER=15
  if [ -f "$DISPATCHER" ]; then
    # shellcheck source=/dev/null
    . "$DISPATCHER" >/dev/null 2>&1 || true
    if command -v __df_setting_timer_interval >/dev/null 2>&1; then
      TIMER_INTERVAL="$(__df_setting_timer_interval 2>/dev/null)"
    fi
    if command -v __df_setting_timer_jitter >/dev/null 2>&1; then
      TIMER_JITTER="$(__df_setting_timer_jitter 2>/dev/null)"
    fi
  fi
  case "$TIMER_INTERVAL" in ''|*[!0-9]*) TIMER_INTERVAL=60 ;; esac
  case "$TIMER_JITTER"   in ''|*[!0-9]*) TIMER_JITTER=15 ;; esac
}

print_usage() {
  cat <<EOF
Usage: $0 [install|reinstall|enable|disable|start|stop|status|logs|uninstall|remove]

  install     Write unit files + the tick payload, enable autostart. The payload runs
              \`dotfiles -tick\` over EVERY repo under ~/.dotfiles/bare-repos/.
  reinstall   Uninstall + install (idempotent — always exactly one timer).
  enable      Mark to autostart on next boot (don't necessarily run now).
  disable     Turn off autostart and stop now (keep unit files).
  start       Run now (idempotent — also enables if disabled).
  stop        Stop running now (transient — auto-resumes on reboot if enabled).
  status      Show timer and service status.
  logs        Show recent service logs.
  uninstall   Full removal (alias: remove).

One timer; its tick fans out over all repos via:
  bash $DISPATCHER -tick
Cadence from ~/.dotfiles/config: [timer] interval (default 60s), jitter (default +-15s).
EOF
}

install_timer() {
    __timer_settings
    mkdir -p "$HOME/.config/systemd/user"
    mkdir -p "$DOTFILES_ROOT"

    # --- generated payload: call the dispatcher's fan-out tick ------------------------------
    # Quoted heredoc: nothing here is expanded at install time. The @PLACEHOLDER@ tokens are
    # substituted afterward so the values are baked (and inspectable) in the generated file.
    cat > "$SCRIPT_FILE" <<'TICKSCRIPT'
#!/bin/bash
# dotfiles single-timer payload (node 9). Fans out the sync tick over ALL repos under
# ~/.dotfiles/bare-repos/ via the dispatcher's `dotfiles -tick` (discovery is the registry).
# A per-fire random 0..JITTER sleep de-syncs N machines so they don't push in lockstep.
set -u
DOTFILES_COMMON='@DOTFILES_COMMON@'
DOTFILES_ROOT='@DOTFILES_ROOT@'
export DOTFILES_COMMON DOTFILES_ROOT
JITTER=@TIMER_JITTER@

# Per-fire jitter: sleep a random number of whole seconds in [0, JITTER]. RANDOM is bash-native;
# fall back to awk if absent. JITTER=0 disables it.
if [ "$JITTER" -gt 0 ] 2>/dev/null; then
  if [ -n "${RANDOM:-}" ]; then
    delay=$(( RANDOM % (JITTER + 1) ))
  else
    delay=$(awk -v m="$JITTER" 'BEGIN{srand();print int(rand()*(m+1))}')
  fi
  [ "$delay" -gt 0 ] 2>/dev/null && sleep "$delay"
fi

# Run the fan-out tick under bash (heavy verbs re-exec under bash anyway). The dispatcher loops
# every enabled repo, fail-isolated; one repo's error never aborts the others.
exec bash "$DOTFILES_COMMON/dotfiles.sh" -tick
TICKSCRIPT
    sed -i \
      -e "s|@DOTFILES_COMMON@|$DOTFILES_COMMON|g" \
      -e "s|@DOTFILES_ROOT@|$DOTFILES_ROOT|g" \
      -e "s|@TIMER_JITTER@|$TIMER_JITTER|g" \
      "$SCRIPT_FILE"
    chmod +x "$SCRIPT_FILE"

    # Capture install-time shell PATH and prepend well-known user-local bin dirs so hook stubs
    # (e.g. uv-driven pre-commit) resolve under systemd's sanitized PATH. Common uv install
    # locations: $HOME/.local/bin (official installer), $HOME/.cargo/bin (cargo), $HOME/bin.
    TIMER_PATH="$HOME/.local/bin:$HOME/bin:$HOME/.cargo/bin:$PATH"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=dotfiles sync tick (fans out over all bare-repos via dotfiles -tick)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=SSH_AUTH_SOCK=%t/keyring/ssh
Environment="PATH=$TIMER_PATH"
Environment="DOTFILES_COMMON=$DOTFILES_COMMON"
Environment="DOTFILES_ROOT=$DOTFILES_ROOT"
ExecStart=$SCRIPT_FILE
EOF

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Timer for dotfiles sync tick

[Timer]
OnBootSec=10s
OnUnitActiveSec=${TIMER_INTERVAL}s
RandomizedDelaySec=${TIMER_JITTER}s
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user disable --now "$TIMER_UNIT" "$SERVICE_UNIT" >/dev/null 2>&1 || true

    if ! systemctl --user enable "$TIMER_UNIT" 2>/dev/null; then
        echo "Note: could not enable $TIMER_UNIT (no systemd user session?). Unit files written."
        echo "Installed unit files; tick payload: $SCRIPT_FILE (interval ${TIMER_INTERVAL}s, jitter ${TIMER_JITTER}s)"
        return 0
    fi
    systemctl --user start "$TIMER_UNIT" 2>/dev/null || \
        echo "Note: could not start $TIMER_UNIT now (will run per its triggers)."

    echo "Installed $TIMER_UNIT (every ${TIMER_INTERVAL}s +-${TIMER_JITTER}s; payload: dotfiles -tick over all repos)"
}

disable_timer() {
    systemctl --user stop "$TIMER_UNIT" "$SERVICE_UNIT" 2>/dev/null || true
    systemctl --user disable "$TIMER_UNIT" "$SERVICE_UNIT" 2>/dev/null || true
    echo "Disabled $TIMER_UNIT."
}

remove_timer() {
    disable_timer
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "Removed $TIMER_UNIT unit files."
}

ACTION="${1:-}"

case "$ACTION" in
    install)          install_timer ;;
    reinstall)        remove_timer; install_timer ;;
    enable)           systemctl --user enable "$TIMER_UNIT" ;;
    disable)          systemctl --user disable --now "$TIMER_UNIT" 2>/dev/null || true ;;
    start)            systemctl --user enable --now "$TIMER_UNIT" ;;
    stop)             systemctl --user stop "$TIMER_UNIT" ;;
    uninstall|remove) remove_timer ;;
    status)
        systemctl --user status "$TIMER_UNIT"
        echo ""
        systemctl --user status "$SERVICE_UNIT"
        ;;
    logs)
        journalctl --user-unit "$SERVICE_UNIT" --no-pager -n 50
        ;;
    "")
        print_usage
        exit 1
        ;;
    *)
        print_usage
        exit 1
        ;;
esac
