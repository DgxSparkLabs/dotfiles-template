#!/usr/bin/env pwsh
# dotfiles-update.ps1: One-way system->machine propagation (pwsh twin of dotfiles-update.sh).
# Fetches the named system baseline and merges it into the current machine branch.
#
# `system` (override with git config dotfiles.systemRef) holds the system
# baseline; machines adopt system improvements via this one-way update. It is
# conflict-free in practice because system files (tracked on the system ref)
# don't overlap the user files a machine edits. If a conflict DOES appear, the
# system/user partition was violated: we abort loudly rather than leave a
# half-merged work-tree.
#
# The system ref is a branch name (default: system; git config dotfiles.systemRef).
# Any name `git check-ref-format --branch` accepts is allowed. It is never
# resolved via origin/HEAD, which aliases whatever the host calls default.
#
# Manual by default. Pass -Auto for unattended use (e.g. a scheduled wrapper):
# the merge semantics are identical; -Auto only signals intent and is reserved
# for future non-interactive policy. Either way, a conflict aborts with exit 1.

param(
    [switch]$Auto,
    [switch]$Help
)

$GitDir   = "$HOME/.local/share/dotfiles.git"
$WorkTree = "$HOME"
$gitArgs  = @('--git-dir', $GitDir, '--work-tree', $WorkTree)

if ($Help) {
    Write-Host @"
Usage: pwsh dotfiles-update.ps1 [-Auto]

Pulls system improvements from origin/system into this machine's branch:
  git --git-dir=$GitDir --work-tree=$WorkTree fetch origin system:refs/remotes/origin/system
  git --git-dir=$GitDir --work-tree=$WorkTree merge --no-edit origin/system

  (default)  Manual run.
  -Auto      Opt-in unattended run (same merge; intended for scheduled wrappers).

The system ref is whatever ``git config dotfiles.systemRef`` names (default: system).
Any valid branch name is allowed. origin/HEAD is never followed.

On conflict the merge is aborted and the command exits non-zero — your work-tree
is left clean. Resolve by reconciling the system/user file partition.
"@
    exit 0
}

function Resolve-SystemRef {
    $ref = (& git @gitArgs config --get dotfiles.systemRef 2>$null | Out-String).Trim()
    if (-not $ref) { $ref = 'system' }
    if ($ref -eq '' -or $ref -eq 'HEAD' -or $ref -eq 'origin/HEAD') {
        [Console]::Error.WriteLine("dotfiles update: refusing system ref '$ref' (not a branch name; it aliases the host default).")
        [Console]::Error.WriteLine("  Set a branch name: git --git-dir `"$GitDir`" config dotfiles.systemRef system")
        exit 1
    }
    & git check-ref-format --branch $ref *> $null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("dotfiles update: '$ref' is not a valid branch name.")
        [Console]::Error.WriteLine("  Set one with: git --git-dir `"$GitDir`" config dotfiles.systemRef <name>")
        exit 1
    }
    return $ref
}

$SystemRef = Resolve-SystemRef

Write-Host "dotfiles update: fetching origin/$SystemRef (auto=$([int][bool]$Auto))"
# Explicit refspec updates the refs/remotes/origin/<system> tracking ref. A bare
# clone (the README setup) starts with NO remote-tracking refs and a refspec-less
# `fetch origin system` only writes FETCH_HEAD — leaving `merge origin/system` to
# fail with "not something we can merge". The refspec makes origin/<system> real.
& git @gitArgs fetch origin "${SystemRef}:refs/remotes/origin/$SystemRef"
if ($LASTEXITCODE -ne 0) {
    Write-Error "dotfiles update: fetch failed (check SSH agent / network / remote)"
    exit 1
}

& git @gitArgs merge --no-edit "origin/$SystemRef"
if ($LASTEXITCODE -ne 0) {
    # Distinguish a real merge conflict (merge started, MERGE_HEAD exists) from a
    # merge that never began (e.g. refused / unrelated histories / bad ref). Only
    # a conflict warrants the loud partition message + `merge --abort`; aborting
    # when no merge is in progress errors "no merge to abort (MERGE_HEAD missing)".
    & git @gitArgs rev-parse -q --verify MERGE_HEAD *> $null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("dotfiles update: merge could not start (no merge in progress to abort).")
        [Console]::Error.WriteLine("dotfiles update: see the git error above; nothing was changed.")
        exit 1
    }
    $conflicts = @(& git @gitArgs diff --name-only --diff-filter=U | Where-Object { $_ })
    $msg = @()
    $msg += ""
    $msg += "========================================================================"
    $msg += "  DOTFILES UPDATE CONFLICT"
    $msg += ""
    $msg += "  Merging origin/$SystemRef hit a conflict. This means a system file on"
    $msg += "  $SystemRef overlaps a file this machine has edited — the system/user"
    $msg += "  partition has been violated."
    $msg += ""
    $msg += "  Conflicting files:"
    if ($conflicts.Count -gt 0) {
        foreach ($f in $conflicts) { $msg += "    $f" }
    } else {
        $msg += "    (none reported by --diff-filter=U; see 'dotfiles status')"
    }
    $msg += ""
    $msg += "  Aborting the merge — your work-tree is left clean (no partial merge)."
    $msg += "========================================================================"
    $msg += ""
    [Console]::Error.WriteLine(($msg -join "`n"))
    & git @gitArgs merge --abort
    exit 1
}

Write-Host "dotfiles update: merged origin/$SystemRef cleanly."
