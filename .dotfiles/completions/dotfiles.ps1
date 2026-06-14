# PowerShell completion for the dotfiles wrappers.
#
# Dot-source this from your $PROFILE (after defining the wrapper functions):
#     . "$HOME\.dotfiles\completions\dotfiles.ps1"
#
# Provides argument completers for:
#   - dotfiles        -> delegates to git's native completion
#   - dotfiles-timer  -> static verbs + flags
#   - dotfiles-update -> --auto
#   - dotfiles-doctor -> --skip-network
#
# Prereq for `dotfiles`: git's PowerShell completion (posh-git, or the
# Register-ArgumentCompleter shipped with recent Git for Windows) must be
# importable so that `git`'s completer is registered. If it is not present, the
# `dotfiles` completer falls back to filesystem completion (no-op); the
# timer/update/doctor completers still work.

# ── dotfiles -> git ──────────────────────────────────────────────────────────
# Delegate `dotfiles <tab>` to whatever completer git itself has registered.
Register-ArgumentCompleter -Native -CommandName dotfiles -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    # Rebuild the command line as if the user had typed `git ...` and ask the
    # registered `git` completer (posh-git / Git for Windows) to complete it.
    # $commandAst is just the wrapper invocation; the full buffer text comes from
    # the AST's root extent so the cursor offset stays meaningful.
    $line = $commandAst.Extent.StartScriptPosition.Line
    if (-not $line) { $line = $commandAst.ToString() }

    # Swap the leading wrapper name for `git` so git's own completer matches.
    $gitLine = $line -replace '^(\s*)dotfiles\b', '${1}git'
    $gitCursor = $cursorPosition - ($line.Length - $gitLine.Length)

    # Clamp into [0, length] — CompleteInput rejects out-of-range cursor indexes.
    if ($gitCursor -lt 0) { $gitCursor = 0 }
    if ($gitCursor -gt $gitLine.Length) { $gitCursor = $gitLine.Length }

    try {
        $results = [System.Management.Automation.CommandCompletion]::CompleteInput(
            $gitLine, $gitCursor, $null
        )
        foreach ($match in $results.CompletionMatches) {
            $match
        }
    } catch {
        # git completion unavailable -> no-op (PowerShell falls back to default).
    }
}

# ── dotfiles-timer ───────────────────────────────────────────────────────────
Register-ArgumentCompleter -CommandName dotfiles-timer -ParameterName Action -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    @(
        'install', 'reinstall', 'enable', 'disable', 'start', 'stop',
        'status', 'logs', 'uninstall', 'remove'
    ) |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(
                $_, $_, 'ParameterValue', $_
            )
        }
}

# Native fallback so `dotfiles-timer <tab>` works even when the function param
# binding isn't in play (e.g. wrapper defined as an alias to the .ps1).
Register-ArgumentCompleter -Native -CommandName dotfiles-timer -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $tokens = @($commandAst.CommandElements)
    $verbs = @(
        'install', 'reinstall', 'enable', 'disable', 'start', 'stop',
        'status', 'logs', 'uninstall', 'remove'
    )
    $flags = @('--all', '-A', '-AddAll')

    # tokens[0] is the command itself; a verb is expected as the first argument.
    if ($tokens.Count -le 1 -or ($tokens.Count -eq 2 -and $wordToComplete)) {
        $candidates = $verbs
    } else {
        $candidates = $flags
    }
    $candidates |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(
                $_, $_, 'ParameterValue', $_
            )
        }
}

# ── dotfiles-update ──────────────────────────────────────────────────────────
Register-ArgumentCompleter -Native -CommandName dotfiles-update -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    @('--auto') |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(
                $_, $_, 'ParameterValue', 'Run non-interactively'
            )
        }
}

# ── dotfiles-doctor ──────────────────────────────────────────────────────────
Register-ArgumentCompleter -Native -CommandName dotfiles-doctor -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    @('--skip-network') |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(
                $_, $_, 'ParameterValue', 'Skip network checks'
            )
        }
}
