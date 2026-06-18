#!/usr/bin/env bash
# dotfiles — one command for every bare repo under ~/.dotfiles/bare-repos/.
#
# Grammar (uniform): the first token decides.
#   dotfiles <repo> <git args...>   bare token  -> git passthrough on that repo (any repo name legal)
#   dotfiles -<verb> [args...]      dashed token-> management verb (one OR two dashes: -ls == --ls)
#   dotfiles                        no args     -> list repos (== -ls)
#
# Sourced from the shell profile; also runnable directly (bash) for tests.
# Override DOTFILES_ROOT to point at a different ~/.dotfiles (the test harness does this).

# Engine dir = where THIS script lives (…/.dotfiles/common). Robust under symlinks and tests.
if [ -n "${BASH_SOURCE:-}" ]; then
  DOTFILES_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  DOTFILES_COMMON="$(cd "$(dirname "$0")" && pwd)"
fi
# Root holding bare-repos/, config, hooks/, state/ = parent of common/ by default.
DOTFILES_ROOT="${DOTFILES_ROOT:-$(dirname "$DOTFILES_COMMON")}"

__df_debug() { [ -n "${DOTFILES_DEBUG:-}" ] && printf '[dotfiles] %s\n' "$*" >&2; return 0; }

__df_repos_dir() { printf '%s/bare-repos' "$DOTFILES_ROOT"; }
__df_config_file() { printf '%s/config' "$DOTFILES_ROOT"; }

# True only if $1 is a real git dir (bare repo). Guards discovery against stray folders (L5.13).
__df_is_repo() {
  [ -d "$1" ] || return 1
  git --git-dir="$1" rev-parse --git-dir >/dev/null 2>&1
}

__df_ls() {
  local base d name; base="$(__df_repos_dir)"
  [ -d "$base" ] || return 0
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if __df_is_repo "$d"; then
      printf '%s\n' "$name"
    else
      __df_debug "skip non-repo under bare-repos/: $name"
    fi
  done
}

__df_help() {
  cat <<'EOF'
dotfiles <repo> <git args...>   run git on that bare repo (work-tree = $HOME)
dotfiles -ls                    list repos        (== --ls; every verb takes one or two dashes)
dotfiles -config <repo>.<key> [value]   read/write engine settings (~/.dotfiles/config)
dotfiles -tick [<repo>]         run the sync tick now (all repos, or one)
dotfiles -doctor                health + overlap check across repos
dotfiles -show                  list recorded sync conflicts
dotfiles -resolve <path>        recover the losing side of a conflict
dotfiles -timer <install|...>   manage the single auto-tick timer
dotfiles -update                upgrade the engine (git pull in ~/.dotfiles/common)
EOF
}

# Engine settings live in ~/.dotfiles/config (git-config syntax), OUTSIDE every bare repo.
__df_config() { git config -f "$(__df_config_file)" "$@"; }

# Raw reader: echo the value for <section>.<key>, or the empty string if unset.
# Distinguishes "unset" (rc 1) from "config file malformed" (rc>=2). On a malformed
# config it warns to stderr and behaves as if the key were unset (BAD-path safe refuse).
# Echoes nothing and returns: 0=found, 1=unset/empty, 2=malformed.
__df_raw() {
  local dotted="$1" cf out rc
  cf="$(__df_config_file)"
  out="$(git config -f "$cf" --get "$dotted" 2>/dev/null)"; rc=$?
  if [ "$rc" -ge 2 ]; then
    # rc>=2 from `git config` = the file could not be parsed (malformed).
    printf 'dotfiles: config malformed at %s; using default for %s\n' "$cf" "$dotted" >&2
    return 2
  fi
  [ "$rc" -eq 0 ] && printf '%s' "$out"
  return "$rc"
}

# tick: bool with safe default OFF. Unparseable (e.g. "maybe") -> default + warning.
# Echoes "true" or "false". Usage: __df_setting_tick <repo>
__df_setting_tick() {
  local repo="$1" raw rc def=false
  raw="$(__df_raw "${repo}.tick")"; rc=$?
  [ "$rc" -ne 0 ] && { printf '%s' "$def"; return 0; }   # unset or malformed -> default off
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    true|yes|on|1)   printf 'true' ;;
    false|no|off|0)  printf 'false' ;;
    *) printf 'dotfiles: invalid bool for %s.tick=%s; using default %s\n' "$repo" "$raw" "$def" >&2
       printf '%s' "$def" ;;
  esac
}

# add: only "all" -> -A; anything else (incl. junk) -> tracked (-u), with a warning on junk.
# Echoes "-A" or "-u". Usage: __df_setting_add <repo>
__df_setting_add() {
  local repo="$1" raw rc
  raw="$(__df_raw "${repo}.add")"; rc=$?
  [ "$rc" -ne 0 ] && { printf '%s' '-u'; return 0; }      # unset or malformed -> tracked
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    all)            printf '%s' '-A' ;;
    tracked|''|-u)  printf '%s' '-u' ;;
    *) printf 'dotfiles: invalid value for %s.add=%s; using default tracked\n' "$repo" "$raw" >&2
       printf '%s' '-u' ;;
  esac
}

# [timer] interval: positive integer seconds, default 60. Non-numeric -> default + warning.
__df_setting_timer_interval() {
  local raw rc def=60
  raw="$(__df_raw 'timer.interval')"; rc=$?
  [ "$rc" -ne 0 ] && { printf '%s' "$def"; return 0; }
  case "$raw" in
    ''|*[!0-9]*) printf 'dotfiles: invalid timer.interval=%s; using default %s\n' "$raw" "$def" >&2
                 printf '%s' "$def" ;;
    *)           printf '%s' "$raw" ;;
  esac
}

# Generic reader retained for forward-compat callers. Usage: __df_setting <repo> <key> <default>
__df_setting() {
  local repo="$1" key="$2" def="$3" raw rc
  raw="$(__df_raw "${repo}.${key}")"; rc=$?
  [ "$rc" -ne 0 ] && { printf '%s' "$def"; return 0; }
  printf '%s' "$raw"
}

__df_update() {
  __df_debug "updating engine at $DOTFILES_COMMON"
  git -C "$DOTFILES_COMMON" pull --ff-only
}

__df_timer() { bash "$DOTFILES_COMMON/timer/dotfiles-timer.sh" "$@"; }

# --- Heavy verbs: implemented in later build-tree nodes (4-8). Stubbed but routable. ---
__df_tick()    { printf 'dotfiles -tick: not implemented yet (build node 4)\n' >&2; return 3; }
__df_doctor()  { printf 'dotfiles -doctor: not implemented yet (build node 7)\n' >&2; return 3; }
__df_show()    { printf 'dotfiles -show: not implemented yet (build node 5)\n' >&2; return 3; }
__df_resolve() { printf 'dotfiles -resolve: not implemented yet (build node 5)\n' >&2; return 3; }

dotfiles() {
  local root="$DOTFILES_ROOT" tok verb repo
  tok="${1-}"
  case "$tok" in
    '')
      __df_ls; return 0 ;;
    -*)
      verb="${tok#-}"; verb="${verb#-}"          # strip one OR two leading dashes
      shift
      case "$verb" in
        h|help)  __df_help ;;
        ls)      __df_ls ;;
        config)  __df_config "$@" ;;
        update)  __df_update "$@" ;;
        timer)   __df_timer "$@" ;;
        tick)    __df_tick "$@" ;;
        doctor)  __df_doctor "$@" ;;
        show)    __df_show "$@" ;;
        resolve) __df_resolve "$@" ;;
        *) printf 'dotfiles: unknown command -%s (try --help)\n' "$verb" >&2; return 2 ;;
      esac
      return $?
      ;;
  esac
  # Bare first token => repo name. Repo always wins over verb names (a repo may be named "show").
  repo="$tok"; shift
  if ! __df_is_repo "$root/bare-repos/$repo"; then
    printf 'dotfiles: no such repo: %s (try --ls)\n' "$repo" >&2
    return 1
  fi
  __df_debug "git on repo=$repo args=$*"
  git --git-dir="$root/bare-repos/$repo" --work-tree="$HOME" "$@"
}

# Run as a command when executed directly under bash (tests). Harmless when sourced or under zsh.
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  dotfiles "$@"
fi
