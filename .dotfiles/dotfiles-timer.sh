#!/usr/bin/env bash
# dotfiles-timer.sh: Manage a per-user timer that auto-commits dotfiles changes.
# Linux: systemd user timer. macOS: launchd user agent (LaunchAgents plist).

GIT_DIR="$HOME/.dotfiles"
WORK_TREE="$HOME"
SERVICE_NAME="dotfiles-git-commit"
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
TIMER_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.timer"
SCRIPT_FILE="$GIT_DIR/.auto-commit.sh"
TIMER_UNIT="${SERVICE_NAME}.timer"
SERVICE_UNIT="${SERVICE_NAME}.service"

# ── macOS launchd paths ────────────────────────────────────────────────────
PLIST_LABEL="$SERVICE_NAME"
PLIST_FILE="$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"
LAUNCHD_LOG_DIR="$HOME/Library/Logs/${SERVICE_NAME}"
LAUNCHD_OUT_LOG="$LAUNCHD_LOG_DIR/stdout.log"
LAUNCHD_ERR_LOG="$LAUNCHD_LOG_DIR/stderr.log"

print_usage() {
  cat <<EOF
Usage: $0 [install|reinstall|enable|disable|start|stop|status|logs|uninstall|remove]

  install [--all|-A]   Write unit files, enable autostart. Default auto-commit uses 'git add -u'.
                       With --all or -A, embeds 'git add -A' (stages new files under the work tree).
  reinstall [--all|-A] Uninstall + install (same flags as install).

  enable     Mark to autostart on next boot (don't necessarily run now).
  disable    Turn off autostart and stop now (keep unit files).
  start      Run now (idempotent — also enables if disabled).
  stop       Stop running now (transient — auto-resumes on reboot if enabled).
  status     Show timer and service status.
  logs       Show recent service logs.
  uninstall  Full removal (alias: remove).

Commits tracked dotfiles changes every minute using:
  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE

Backend: systemd user timer on Linux, launchd user agent on macOS (Darwin).

Default auto-commit uses 'git add -u' (tracked changes only). Use install --all for 'git add -A'.
EOF
}

# Generate the portable $SCRIPT_FILE (.auto-commit.sh). Shared by every backend
# (systemd on Linux, launchd on macOS) — do NOT fork this per platform.
generate_autocommit_script() {
    GIT_ADD_SPEC="-u"
    if [ "${ADD_ALL_FLAG:-0}" -eq 1 ]; then
      GIT_ADD_SPEC="-A"
    fi

    # Quoted heredoc: an unquoted EOF would run $((…)) and $(git …) while *installing*, corrupting the script.
    cat > "$SCRIPT_FILE" <<'AUTOSCRIPT'
#!/bin/bash
# Subject: chore(dotfiles): add/mod/del/ren with paths; body: grouped lists (names, not only counts).
GDIR='@DOTFILES_GIT_DIR@'
WTREE='@DOTFILES_WORK_TREE@'
git --git-dir="$GDIR" --work-tree="$WTREE" add @GIT_ADD_SPEC@
if ! git --git-dir="$GDIR" --work-tree="$WTREE" diff --quiet --cached; then
  ts=$(date --iso-8601=seconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

  paths_added=$(git --git-dir="$GDIR" --work-tree="$WTREE" diff --cached --diff-filter=A --name-only)
  paths_modified=$(git --git-dir="$GDIR" --work-tree="$WTREE" diff --cached --diff-filter=M --name-only)
  paths_deleted=$(git --git-dir="$GDIR" --work-tree="$WTREE" diff --cached --diff-filter=D --name-only)

  sbj_parts=()
  while IFS= read -r f; do [ -z "$f" ] || sbj_parts+=("add ${f}"); done <<< "$paths_added"
  while IFS= read -r f; do [ -z "$f" ] || sbj_parts+=("mod ${f}"); done <<< "$paths_modified"
  while IFS= read -r f; do [ -z "$f" ] || sbj_parts+=("del ${f}"); done <<< "$paths_deleted"
  while IFS=$'\t' read -r _st oldp newp; do
    [ -n "$oldp" ] && [ -n "$newp" ] || continue
    sbj_parts+=("ren ${oldp} -> ${newp}")
  done < <(git --git-dir="$GDIR" --work-tree="$WTREE" diff --cached --name-status --diff-filter=R)

  detail=""
  if [ ${#sbj_parts[@]} -gt 0 ]; then
    detail=$(printf '%s; ' "${sbj_parts[@]}")
    detail=${detail%; }
  else
    detail="changes"
  fi
  subject_core="chore(dotfiles): ${detail}"
  max_len=160
  if [ ${#subject_core} -gt $max_len ]; then
    name_lines=$(git --git-dir="$GDIR" --work-tree="$WTREE" diff --cached --name-only)
    ntotal=$(printf '%s\n' "$name_lines" | sed '/^$/d' | wc -l | tr -d ' ')
    preview=$(printf '%s\n' "$name_lines" | sed '/^$/d' | head -n 3 | paste -sd ', ' -)
    subject_core="chore(dotfiles): ${ntotal} paths (${preview}, …)"
    if [ ${#subject_core} -gt $max_len ]; then
      subject_core="chore(dotfiles): ${ntotal} paths (see message body)"
    fi
  fi
  subject="${subject_core} at ${ts}"

  body=""
  append_section() {
    local title="$1"
    local lines="$2"
    local nonempty
    nonempty=$(printf '%s\n' "$lines" | sed '/^$/d')
    [ -z "$nonempty" ] && return 0
    body+="${title}"$'\n'
    body+=$(printf '%s\n' "$nonempty" | sed 's/^/  /')$'\n'$'\n'
  }
  append_section "Added:" "$paths_added"
  append_section "Modified:" "$paths_modified"
  append_section "Deleted:" "$paths_deleted"
  ren_body=""
  while IFS=$'\t' read -r _st oldp newp; do
    [ -n "$oldp" ] && [ -n "$newp" ] || continue
    ren_body+="  ${oldp} -> ${newp}"$'\n'
  done < <(git --git-dir="$GDIR" --work-tree="$WTREE" diff --cached --name-status --diff-filter=R)
  if [ -n "$ren_body" ]; then
    body+="Renamed:"$'\n'
    body+="$ren_body"$'\n'
  fi

  if [ -n "$(printf '%s' "$body" | sed '/^$/d')" ]; then
    msg=$(printf '%s\n\n%s' "$subject" "$body")
    git --git-dir="$GDIR" --work-tree="$WTREE" commit -m "$msg"
  else
    git --git-dir="$GDIR" --work-tree="$WTREE" commit -m "$subject"
  fi
fi
git --git-dir="$GDIR" --work-tree="$WTREE" push || {
  echo "auto-commit: push failed (check SSH agent / network)" >&2
  exit 1
}
AUTOSCRIPT
    # sed -i portability: GNU sed wants `-i`, BSD/macOS sed wants `-i ''`.
    # Use a temp file + mv to sidestep the difference entirely.
    sed "s|@DOTFILES_GIT_DIR@|$GIT_DIR|g;s|@DOTFILES_WORK_TREE@|$WORK_TREE|g;s|@GIT_ADD_SPEC@|$GIT_ADD_SPEC|g" \
        "$SCRIPT_FILE" > "$SCRIPT_FILE.tmp" && mv "$SCRIPT_FILE.tmp" "$SCRIPT_FILE"
    chmod +x "$SCRIPT_FILE"
}

# ── Linux: systemd user timer ───────────────────────────────────────────────
install_timer_systemd() {
    mkdir -p "$HOME/.config/systemd/user"
    generate_autocommit_script

    # Capture install-time shell PATH and prepend well-known user-local bin dirs
    # so hook stubs (e.g. uv-driven pre-push) work under systemd's sanitized PATH.
    # Common uv install locations: $HOME/.local/bin (official installer),
    # $HOME/.cargo/bin (cargo install), $HOME/bin (manual).
    TIMER_PATH="$HOME/.local/bin:$HOME/bin:$HOME/.cargo/bin:$PATH"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Auto-commit tracked dotfiles changes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=SSH_AUTH_SOCK=%t/keyring/ssh
Environment="PATH=$TIMER_PATH"
ExecStart=$SCRIPT_FILE
EOF

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Timer for dotfiles auto-commit

[Timer]
OnBootSec=10s
OnUnitActiveSec=1min
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user disable --now "$TIMER_UNIT" "$SERVICE_UNIT" >/dev/null 2>&1 || true

    if ! systemctl --user enable "$TIMER_UNIT"; then
        echo "Error: failed to enable $TIMER_UNIT. Check: journalctl --user -xe"
        exit 1
    fi
    if ! systemctl --user start "$TIMER_UNIT"; then
        echo "Error: failed to start $TIMER_UNIT. Check: journalctl --user -xe"
        exit 1
    fi

    echo "Installed $TIMER_UNIT (commits every minute, git-dir: $GIT_DIR, auto-commit: git add $GIT_ADD_SPEC)"
}

disable_timer_systemd() {
    systemctl --user stop "$TIMER_UNIT" "$SERVICE_UNIT" 2>/dev/null || true
    systemctl --user disable "$TIMER_UNIT" "$SERVICE_UNIT" 2>/dev/null || true
    echo "Disabled $TIMER_UNIT."
}

remove_timer_systemd() {
    disable_timer_systemd
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_FILE"
    systemctl --user daemon-reload
    echo "Removed $TIMER_UNIT unit files."
}

# ── macOS: launchd user agent ───────────────────────────────────────────────
# The GUI launchd domain a LaunchAgent runs in. Headless CI runners often have
# no aqua/GUI session, so `bootstrap` fails there — callers soft-skip that case.
launchd_domain() { echo "gui/$(id -u)"; }

install_timer_launchd() {
    mkdir -p "$HOME/Library/LaunchAgents" "$LAUNCHD_LOG_DIR"
    generate_autocommit_script

    # launchd hands jobs a minimal environment (cf. systemd). Carry the same
    # PATH as the Linux unit (commit 1cdd9c6) so uv-driven hooks resolve, plus
    # SSH_AUTH_SOCK so `git push` over SSH can reach the agent.
    TIMER_PATH="$HOME/.local/bin:$HOME/bin:$HOME/.cargo/bin:$PATH"

    cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_FILE}</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${TIMER_PATH}</string>
        <key>SSH_AUTH_SOCK</key>
        <string>${SSH_AUTH_SOCK:-}</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${LAUNCHD_OUT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_ERR_LOG}</string>
</dict>
</plist>
EOF

    # Replace any prior instance, then load. bootstrap needs a GUI session;
    # if there is none (headless CI), report it without hard-failing install.
    launchctl bootout "$(launchd_domain)/$PLIST_LABEL" 2>/dev/null || true
    if launchctl bootstrap "$(launchd_domain)" "$PLIST_FILE"; then
        launchctl enable "$(launchd_domain)/$PLIST_LABEL" 2>/dev/null || true
        echo "Installed $PLIST_LABEL (commits every minute, git-dir: $GIT_DIR, auto-commit: git add $GIT_ADD_SPEC)"
    else
        echo "Wrote $PLIST_FILE but could not bootstrap into $(launchd_domain) (no GUI session?)."
        echo "Load it from a logged-in session with: launchctl bootstrap $(launchd_domain) $PLIST_FILE"
    fi
}

disable_timer_launchd() {
    launchctl bootout "$(launchd_domain)/$PLIST_LABEL" 2>/dev/null || true
    echo "Disabled $PLIST_LABEL."
}

remove_timer_launchd() {
    disable_timer_launchd
    rm -f "$PLIST_FILE" "$SCRIPT_FILE"
    echo "Removed $PLIST_LABEL agent files."
}

ACTION="${1:-}"
ADD_ALL_FLAG=0
# Scan all args so reinstall/install still pick up --all|-A if $2 is not exactly that (CI wrappers, etc.).
for _df_arg in "$@"; do
  case "$_df_arg" in
    --all|-A) ADD_ALL_FLAG=1 ;;
  esac
done

case "$(uname -s)" in
  Darwin)
    DOMAIN="$(launchd_domain)"
    case "$ACTION" in
        install)          install_timer_launchd ;;
        reinstall)        remove_timer_launchd; install_timer_launchd ;;
        enable)           launchctl enable "$DOMAIN/$PLIST_LABEL" ;;
        disable)          disable_timer_launchd ;;
        start)            launchctl kickstart -k "$DOMAIN/$PLIST_LABEL" ;;
        stop)             launchctl bootout "$DOMAIN/$PLIST_LABEL" 2>/dev/null || true ;;
        uninstall|remove) remove_timer_launchd ;;
        status)
            launchctl print "$DOMAIN/$PLIST_LABEL"
            ;;
        logs)
            tail -n 50 "$LAUNCHD_OUT_LOG" "$LAUNCHD_ERR_LOG" 2>/dev/null \
              || echo "No logs yet at $LAUNCHD_LOG_DIR"
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
    ;;
  *)
    case "$ACTION" in
        install)          install_timer_systemd ;;
        reinstall)        remove_timer_systemd; install_timer_systemd ;;
        enable)           systemctl --user enable "$TIMER_UNIT" ;;
        disable)          systemctl --user disable --now "$TIMER_UNIT" 2>/dev/null || true ;;
        start)            systemctl --user enable --now "$TIMER_UNIT" ;;
        stop)             systemctl --user stop "$TIMER_UNIT" ;;
        uninstall|remove) remove_timer_systemd ;;
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
    ;;
esac
