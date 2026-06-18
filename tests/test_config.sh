#!/usr/bin/env bash
# Node 3 per-repo config + safe defaults (bash/zsh): L0.8-L0.12, L5.8-L5.12.
# Reader assertions dot-source the dispatcher and call __df_setting_* directly in-process,
# capturing stdout (the value) and stderr (warnings) separately.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
. "$HERE/harness.sh"
. "$REPO/dotfiles.sh"

new_env
mk_repo nvim
CFG="$(__df_config_file)"

# L0.8 tick default OFF — config has no [nvim] -> reader yields false, no warning.
_t_start L0.8 GOOD
: > "$CFG"                                   # empty config: key unset
val="$(__df_setting_tick nvim 2>"$WORK/err")"
assert_eq L0.8 "$val" "false"
assert_eq L0.8 "$(cat "$WORK/err")" ""

# L0.9 tick on — set via `dotfiles -config nvim.tick on` -> reader yields true.
_t_start L0.9 GOOD
dotfiles -config nvim.tick on
val="$(__df_setting_tick nvim 2>/dev/null)"
assert_eq L0.9 "$val" "true"

# L0.10 add default tracked — unset -> -u.
_t_start L0.10 GOOD
: > "$CFG"
val="$(__df_setting_add nvim 2>/dev/null)"
assert_eq L0.10 "$val" "-u"

# L0.11 add=all — set -> -A.
_t_start L0.11 GOOD
dotfiles -config nvim.add all
val="$(__df_setting_add nvim 2>/dev/null)"
assert_eq L0.11 "$val" "-A"

# L0.12 -config writes to ~/.dotfiles/config, NOT into the bare repo's config.
_t_start L0.12 GOOD
: > "$CFG"
dotfiles -config nvim.add all
assert_contains L0.12 "$(cat "$CFG")" "all"               # the engine config has the key
barecfg="$DOTFILES_ROOT/bare-repos/nvim/config"
assert_not_contains L0.12 "$(cat "$barecfg" 2>/dev/null)" "add = all"   # bare repo untouched

# L5.8 malformed config -> reader returns default, does not crash (rc 0), warns.
_t_start L5.8 BAD
printf 'this is not ini\n' > "$CFG"
val="$(__df_setting_tick nvim 2>"$WORK/err")"; rc=$?
assert_rc L5.8 "$rc" 0
assert_eq L5.8 "$val" "false"
assert_contains L5.8 "$(cat "$WORK/err")" "malformed"

# L5.9 unknown key -> ignored, no error (forward-compat).
_t_start L5.9 GOOD
: > "$CFG"
dotfiles -config nvim.frobnicate 1
val="$(__df_setting_tick nvim 2>"$WORK/err")"; rc=$?
assert_rc L5.9 "$rc" 0
assert_eq L5.9 "$val" "false"
assert_eq L5.9 "$(cat "$WORK/err")" ""

# L5.10 invalid value -> fall back to safe default + warning (tick + add).
_t_start L5.10 BAD
: > "$CFG"
dotfiles -config nvim.tick maybe
dotfiles -config nvim.add sideways
tval="$(__df_setting_tick nvim 2>"$WORK/terr")"
aval="$(__df_setting_add  nvim 2>"$WORK/aerr")"
assert_eq L5.10 "$tval" "false"
assert_contains L5.10 "$(cat "$WORK/terr")" "invalid bool"
assert_eq L5.10 "$aval" "-u"
assert_contains L5.10 "$(cat "$WORK/aerr")" "invalid value"

# L5.11 duplicate keys -> deterministic (git last-wins), no crash.
_t_start L5.11 GOOD
printf '[nvim]\n  tick = off\n  tick = on\n' > "$CFG"
val="$(__df_setting_tick nvim 2>/dev/null)"; rc=$?
assert_rc L5.11 "$rc" 0
assert_eq L5.11 "$val" "true"               # last-wins: on

# L5.12 [timer] interval=abc -> fall back to 60 + warning.
_t_start L5.12 BAD
printf '[timer]\n  interval = abc\n' > "$CFG"
val="$(__df_setting_timer_interval 2>"$WORK/err")"
assert_eq L5.12 "$val" "60"
assert_contains L5.12 "$(cat "$WORK/err")" "invalid timer.interval"

_summary
