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

# Read one repo setting with a safe default. Usage: __df_setting <repo> <key> <default> [--type=bool]
__df_setting() {
  local repo="$1" key="$2" def="$3"; shift 3
  git config -f "$(__df_config_file)" "$@" --default "$def" "${repo}.${key}" 2>/dev/null \
    || printf '%s' "$def"
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
