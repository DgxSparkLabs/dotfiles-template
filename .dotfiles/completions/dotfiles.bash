# shellcheck shell=bash
# Bash completion for the dotfiles wrappers.
#
# Source this from ~/.bashrc (after defining the `dotfiles` alias), e.g.:
#     source "$HOME/.dotfiles/completions/dotfiles.bash"
#
# Provides:
#   - dotfiles        -> full git completion (requires git's bash completion)
#   - dotfiles-timer  -> static verbs + flags
#   - dotfiles-update -> --auto
#   - dotfiles-doctor -> --skip-network
#
# Prereq for `dotfiles`: git's bash-completion script must be loaded so that
# __git_complete / __git_main are defined. If it is not present, the dotfiles
# git completion silently no-ops; the timer/update/doctor completions still work.

# ── dotfiles -> git ──────────────────────────────────────────────────────────
# git ships __git_complete on most distros once its bash completion is sourced.
if declare -F __git_complete >/dev/null 2>&1 && declare -F __git_main >/dev/null 2>&1; then
    __git_complete dotfiles __git_main
fi

# ── dotfiles-timer ───────────────────────────────────────────────────────────
_dotfiles_timer_complete() {
    local cur prev verbs
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    verbs="install reinstall enable disable start stop status logs uninstall remove"

    # First positional argument: complete a verb.
    if [ "$COMP_CWORD" -eq 1 ]; then
        mapfile -t COMPREPLY < <(compgen -W "$verbs" -- "$cur")
        return 0
    fi

    # After install/reinstall, offer the add-all flags.
    case "$prev" in
        install|reinstall)
            mapfile -t COMPREPLY < <(compgen -W "--all -A -AddAll" -- "$cur")
            return 0
            ;;
    esac

    # Allow flags anywhere when the user has started typing one.
    if [[ "$cur" == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--all -A -AddAll" -- "$cur")
        return 0
    fi

    COMPREPLY=()
    return 0
}
complete -F _dotfiles_timer_complete dotfiles-timer

# ── dotfiles-update ──────────────────────────────────────────────────────────
_dotfiles_update_complete() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"
    mapfile -t COMPREPLY < <(compgen -W "--auto" -- "$cur")
    return 0
}
complete -F _dotfiles_update_complete dotfiles-update

# ── dotfiles-doctor ──────────────────────────────────────────────────────────
_dotfiles_doctor_complete() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"
    mapfile -t COMPREPLY < <(compgen -W "--skip-network" -- "$cur")
    return 0
}
complete -F _dotfiles_doctor_complete dotfiles-doctor
