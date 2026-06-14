#!/usr/bin/env pwsh
# dotfiles-update.ps1: One-way master->machine propagation (pwsh twin of dotfiles-update.sh).
# Fetches origin/master and merges it into the current machine branch.
#
# master holds the system baseline; machines adopt system improvements via this
# one-way update. It is conflict-free in practice because system files (tracked
# on master) don't overlap the user files a machine edits. If a conflict DOES
# appear, the system/user partition was violated: we abort loudly rather than
# leave a half-merged work-tree.
#
# Manual by default. Pass -Auto for unattended use (e.g. a scheduled wrapper):
# the merge semantics are identical; -Auto only signals intent and is reserved
# for future non-interactive policy. Either way, a conflict aborts with exit 1.

param(
    [switch]$Auto,
    [switch]$Help
)

$GitDir   = "$HOME\.dotfiles"
$WorkTree = "$HOME"
$gitArgs  = @('--git-dir', $GitDir, '--work-tree', $WorkTree)

if ($Help) {
    Write-Host @"
Usage: pwsh dotfiles-update.ps1 [-Auto]

Pulls system improvements from origin/master into this machine's branch:
  git --git-dir=$GitDir --work-tree=$WorkTree fetch origin master:refs/remotes/origin/master
  git --git-dir=$GitDir --work-tree=$WorkTree merge --no-edit origin/master

  (default)  Manual run.
  -Auto      Opt-in unattended run (same merge; intended for scheduled wrappers).

On conflict the merge is aborted and the command exits non-zero — your work-tree
is left clean. Resolve by reconciling the system/user file partition.
"@
    exit 0
}

Write-Host "dotfiles update: fetching origin/master (auto=$([int][bool]$Auto))"
# Explicit refspec updates the refs/remotes/origin/master tracking ref. A bare
# clone (the README setup) starts with NO remote-tracking refs and a refspec-less
# `fetch origin master` only writes FETCH_HEAD — leaving `merge origin/master` to
# fail with "not something we can merge". The refspec makes origin/master real.
& git @gitArgs fetch origin "master:refs/remotes/origin/master"
if ($LASTEXITCODE -ne 0) {
    Write-Error "dotfiles update: fetch failed (check SSH agent / network / remote)"
    exit 1
}

& git @gitArgs merge --no-edit origin/master
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
    $msg += "  Merging origin/master hit a conflict. This means a system file on"
    $msg += "  master overlaps a file this machine has edited — the system/user"
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

Write-Host "dotfiles update: merged origin/master cleanly."
