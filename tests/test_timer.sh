#!/usr/bin/env bash
# test_timer.sh — node 9: the single timer fans out via `dotfiles -tick` + interval/jitter.
#
# CI constraint (plan "Known CI constraints & mitigations"): a systemd USER session may be absent
# on a GH runner (and is absent under Git-Bash on Windows / under macOS bash here). Where the
# service manager can't run, we assert generated FILE CONTENT (the unit + the payload) and prove
# "a fire calls -tick" by calling `dotfiles -tick` DIRECTLY over enabled repos. Live-manager-only
# bits are RESULT=SKIP with a NAMED reason (never a silent skip).

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/harness.sh"
REPO_UNDER_TEST="$(cd "$HERE/.." && pwd)"
DISPATCHER="$REPO_UNDER_TEST/dotfiles.sh"
TIMER_SH="$REPO_UNDER_TEST/timer/dotfiles-timer.sh"

# Source the dispatcher so `dotfiles` is callable in-process (bash). The bottom-of-file guard
# only fires when executed (BASH_SOURCE==$0); sourcing here just defines the functions.
. "$DISPATCHER"

# Is a real systemd user session available? (Linux GH VM yes; containers / Git-Bash / macOS no.)
have_systemd() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

# Run the timer script with the env pointing at the test's fake engine/root. The engine layout
# expects timer at <common>/timer/ and dispatcher at <common>/dotfiles.sh. We point DOTFILES_COMMON
# at the REAL engine checkout (so the dispatcher + readers exist) but DOTFILES_ROOT at the fake root
# (so unit/payload files land under the test's throwaway HOME-side root, and config is read there).
timer() {
  DOTFILES_COMMON="$REPO_UNDER_TEST" DOTFILES_ROOT="$DOTFILES_ROOT" HOME="$HOME" \
    bash "$TIMER_SH" "$@"
}

# Where the generated payload lands (mirrors the timer script's SCRIPT_FILE).
payload_file() { printf '%s/.dotfiles-tick.sh' "$DOTFILES_ROOT"; }
service_file() { printf '%s/.config/systemd/user/dotfiles-git-commit.service' "$HOME"; }
timer_unit()   { printf '%s/.config/systemd/user/dotfiles-git-commit.timer' "$HOME"; }

# ------------------------------------------------------------------------------------------------
# L3.4 / L3.11 — generated payload calls `dotfiles -tick`, with the jitter value baked in.
new_env
timer install >/dev/null 2>&1 || true
_t_start "L3.4-payload-tick" GOOD
pf="$(payload_file)"
if [ -f "$pf" ]; then
  body="$(cat "$pf")"
  assert_contains "L3.4 payload calls dotfiles -tick" "$body" "dotfiles.sh\" -tick"
else
  _fail "L3.4 payload file not generated at $pf"
fi

_t_start "L3.11-jitter-artifact" GOOD
if [ -f "$pf" ]; then
  body="$(cat "$pf")"
  # Default jitter is 15; the payload bakes JITTER=<n> literally.
  assert_contains "L3.11 jitter baked into payload" "$body" "JITTER=15"
else
  _fail "L3.11 payload file not generated at $pf"
fi

# L3.11b — config interval/jitter respected in the generated artifacts.
new_env
git config -f "$DOTFILES_ROOT/config" timer.interval 90 >/dev/null 2>&1
git config -f "$DOTFILES_ROOT/config" timer.jitter 7    >/dev/null 2>&1
timer install >/dev/null 2>&1 || true
_t_start "L3.11b-config-respected" GOOD
pf="$(payload_file)"
sf="$(service_file)"
tf="$(timer_unit)"
ok=1
[ -f "$pf" ] && grep -q 'JITTER=7' "$pf" || ok=0
# The systemd unit content is written regardless of whether the manager could enable it.
if [ -f "$tf" ]; then
  grep -q 'OnUnitActiveSec=90s' "$tf" || ok=0
  grep -q 'RandomizedDelaySec=7s' "$tf" || ok=0
fi
assert_eq "L3.11b interval+jitter in generated artifacts" "$ok" "1"

# ------------------------------------------------------------------------------------------------
# L3.12 — Linux systemd unit embeds the PATH augmentation (so uv resolves under the unit).
new_env
timer install >/dev/null 2>&1 || true
_t_start "L3.12-linux-path-injection" GOOD
sf="$(service_file)"
if [ -f "$sf" ]; then
  body="$(cat "$sf")"
  # The service must bake a PATH that includes the user-local bin dirs (uv install locations).
  ok=1
  printf '%s' "$body" | grep -Eq '^Environment="PATH=' || ok=0
  printf '%s' "$body" | grep -q "$HOME/.local/bin"     || ok=0
  printf '%s' "$body" | grep -q 'ExecStart=.*\.dotfiles-tick\.sh' || ok=0
  assert_eq "L3.12 unit bakes PATH incl. ~/.local/bin + ExecStart payload" "$ok" "1"
else
  _fail "L3.12 service unit not generated at $sf"
fi

# ------------------------------------------------------------------------------------------------
# L3.1 / L3.14 — install creates exactly ONE unit/timer; reinstall stays idempotent (still one).
new_env
timer install >/dev/null 2>&1 || true
_t_start "L3.1-install-singleton" GOOD
# Count the generated unit pair under the systemd user dir (file-content registry where the
# manager isn't live). Exactly one .timer + one .service named dotfiles-git-commit.
ucount=0
[ -f "$(timer_unit)" ]   && ucount=$((ucount+1))
[ -f "$(service_file)" ] && ucount=$((ucount+1))
if have_systemd; then
  # When a live manager is available, also assert exactly one registered timer unit by that name.
  reg="$(systemctl --user list-unit-files 'dotfiles-git-commit.timer' --no-legend 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "L3.1 exactly one registered timer unit (live manager)" "$reg" "1"
else
  _skip "L3.1 live-manager unit count: systemd user session unavailable on this runner"
fi
assert_eq "L3.1 exactly one .timer + one .service generated" "$ucount" "2"

timer reinstall >/dev/null 2>&1 || true
_t_start "L3.14-reinstall-idempotent" GOOD
ucount=0
[ -f "$(timer_unit)" ]   && ucount=$((ucount+1))
[ -f "$(service_file)" ] && ucount=$((ucount+1))
assert_eq "L3.14 still exactly one .timer + one .service after reinstall" "$ucount" "2"
if have_systemd; then
  reg="$(systemctl --user list-unit-files 'dotfiles-git-commit.timer' --no-legend 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "L3.14 still exactly one registered timer unit after reinstall (live manager)" "$reg" "1"
else
  _skip "L3.14 live-manager re-count: systemd user session unavailable on this runner"
fi

# ------------------------------------------------------------------------------------------------
# L3.4(direct) / L3.9 — calling `dotfiles -tick` advances ALL enabled repos in ONE run; a disabled
# repo does NOT advance. This is the fire-calls-tick proof via the dispatcher's fan-out (the timer
# payload's exec line is asserted above; the actual fan-out behavior is proven here directly).
new_env
mk_repo_with_origin repoA main
mk_repo_with_origin repoB main
mk_repo_with_origin repoC main         # repoC stays DISABLED (tick default off)
git config -f "$DOTFILES_ROOT/config" repoA.tick on >/dev/null 2>&1
git config -f "$DOTFILES_ROOT/config" repoB.tick on >/dev/null 2>&1
# Make a real change in each so a commit is produced.
printf 'a-change\n' >> "$HOME/.config/repoA/seed"
printf 'b-change\n' >> "$HOME/.config/repoB/seed"
printf 'c-change\n' >> "$HOME/.config/repoC/seed"
beforeA="$(origin_tip repoA refs/heads/main)"; beforeB="$(origin_tip repoB refs/heads/main)"; beforeC="$(origin_tip repoC refs/heads/main)"
dotfiles -tick >/dev/null 2>&1
afterA="$(origin_tip repoA refs/heads/main)"; afterB="$(origin_tip repoB refs/heads/main)"; afterC="$(origin_tip repoC refs/heads/main)"

_t_start "L3.9-one-tick-many-repos" GOOD
ok=1
[ "$beforeA" != "$afterA" ] || ok=0      # A advanced
[ "$beforeB" != "$afterB" ] || ok=0      # B advanced
assert_eq "L3.9 one -tick advanced BOTH enabled repos' origins" "$ok" "1"

_t_start "L3.4-disabled-repo-untouched" GOOD
assert_eq "L3.4 disabled repoC origin did NOT advance" "$beforeC" "$afterC"

# ------------------------------------------------------------------------------------------------
# install/enable/disable/status/logs/uninstall — assert the script's own state logic where the
# manager isn't live; SKIP the live-manager transitions with a named reason.
new_env
_t_start "L3.x-state-uninstall" GOOD
timer install >/dev/null 2>&1 || true
had_units=0
[ -f "$(timer_unit)" ] && [ -f "$(service_file)" ] && [ -f "$(payload_file)" ] && had_units=1
timer uninstall >/dev/null 2>&1 || true
gone=1
[ -f "$(timer_unit)" ]   && gone=0
[ -f "$(service_file)" ] && gone=0
[ -f "$(payload_file)" ] && gone=0
ok=$(( had_units == 1 && gone == 1 ? 1 : 0 ))
assert_eq "L3.x install writes the 3 files; uninstall removes them all" "$ok" "1"

_t_start "L3.x-enable-disable-status-logs" GOOD
if have_systemd; then
  timer install >/dev/null 2>&1 || true
  timer enable  >/dev/null 2>&1 || true
  en="$(systemctl --user is-enabled dotfiles-git-commit.timer 2>/dev/null)"
  timer disable >/dev/null 2>&1 || true
  di="$(systemctl --user is-enabled dotfiles-git-commit.timer 2>/dev/null)"
  timer status  >/dev/null 2>&1 || true
  timer logs    >/dev/null 2>&1 || true
  timer uninstall >/dev/null 2>&1 || true
  ok=1
  [ "$en" = "enabled" ] || ok=0
  case "$di" in disabled|static|"") : ;; *) ok=0 ;; esac
  assert_eq "L3.x enable->is-enabled, disable->not-enabled (live manager)" "$ok" "1"
else
  _skip "L3.2/L3.3/L3.6/L3.7 enable/disable/status/logs: systemd user session unavailable on this runner"
fi

_summary
