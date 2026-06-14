#compdef dotfiles dotfiles-timer dotfiles-update dotfiles-doctor
# Zsh completion for the dotfiles wrappers.
#
# Source this from ~/.zshrc (after `compinit` and after defining the aliases):
#     fpath+=("$HOME/.dotfiles/completions")
#     source "$HOME/.dotfiles/completions/dotfiles.zsh"
#
# Provides:
#   - dotfiles        -> full git completion (reuses zsh's _git)
#   - dotfiles-timer  -> static verbs + flags
#   - dotfiles-update -> --auto, --help
#   - dotfiles-doctor -> --git-dir, --work-tree, --skip-network, --help
#
# Prereq for `dotfiles`: zsh's git completion (_git) must be available. If it is
# not, the `dotfiles` completion silently no-ops; the other completions work.

# ── dotfiles -> git ──────────────────────────────────────────────────────────
# Make `dotfiles` complete exactly like `git`.
if (( $+functions[_git] )) || compdef >/dev/null 2>&1; then
    compdef dotfiles=git
fi

# ── dotfiles-timer ───────────────────────────────────────────────────────────
_dotfiles_timer() {
    local -a verbs flags
    verbs=(
        'install:Write unit files, enable autostart'
        'reinstall:Uninstall + install'
        'enable:Mark to autostart on next boot'
        'disable:Turn off autostart and stop'
        'start:Run now (idempotent)'
        'stop:Stop running now (transient)'
        'status:Show install + autostart + running state'
        'logs:Show recent activity'
        'uninstall:Full removal'
        'remove:Full removal (alias of uninstall)'
    )
    flags=(
        '--all[stage new files: git add -A]'
        '-A[stage new files: git add -A]'
    )
    if (( CURRENT == 2 )); then
        _describe -t verbs 'dotfiles-timer verb' verbs
    else
        _values 'flag' $flags
    fi
}
compdef _dotfiles_timer dotfiles-timer

# ── dotfiles-update ──────────────────────────────────────────────────────────
_dotfiles_update() {
    _arguments \
        '--auto[run non-interactively, no prompts]' \
        '(-h --help)'{-h,--help}'[show usage]'
}
compdef _dotfiles_update dotfiles-update

# ── dotfiles-doctor ──────────────────────────────────────────────────────────
_dotfiles_doctor() {
    _arguments \
        '--git-dir[override the bare-repo git dir]:git dir:_files -/' \
        '--work-tree[override the work-tree]:work tree:_files -/' \
        '--skip-network[skip checks that require network access]' \
        '(-h --help)'{-h,--help}'[show usage]'
}
compdef _dotfiles_doctor dotfiles-doctor
