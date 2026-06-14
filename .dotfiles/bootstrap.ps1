# bootstrap.ps1 — restore a machine from scratch (run once on a fresh machine).
#
# The `dotfiles` function lives in your profile — which hasn't been restored
# yet. This defines it temporarily, clones your bare repo, then checks out your
# machine's branch (which restores the profile and re-establishes the function).
#
# Parameters (command-line — preferred):
#   -Repo <url>     (required) git remote URL, e.g. git@github.com:<YOU>/dotfiles.git
#   -Branch <name>  (optional) branch to check out. If omitted, the machine name
#                   is auto-detected and you are prompted to confirm it or type
#                   a different branch.
#
# Fallback (only when the parameter is absent):
#   $env:DOTFILES_REPO    git remote URL
#   $env:DOTFILES_BRANCH  branch to check out
#
# Usage:
#   pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git
#   pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git -Branch my-laptop
#
# When no branch is given the script auto-detects this machine's name and asks
# you to confirm it (or type another branch). In a non-interactive context
# (no interactive host, e.g. CI), pass -Branch explicitly — the script errors
# instead of hanging on the prompt.

param(
    [string]$Repo,
    [string]$Branch
)

$ErrorActionPreference = 'Stop'

# ── Repo: parameter wins, env var is the documented fallback ────────────────
if (-not $Repo) { $Repo = $env:DOTFILES_REPO }
if (-not $Repo) {
    Write-Error "bootstrap.ps1: -Repo is required (the git remote URL of your dotfiles repo). e.g. pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git"
    exit 1
}

# Track whether a branch was supplied at all (parameter or env fallback).
$branchProvided = [bool]$Branch
if (-not $Branch -and $env:DOTFILES_BRANCH) {
    $Branch = $env:DOTFILES_BRANCH
    $branchProvided = $true
}

# ── Branch: explicit value, else auto-detect + confirm with the user ────────
function Get-MachineBranch {
    try {
        $product = (Get-WmiObject Win32_BaseBoard -ErrorAction Stop).product
        if ($product) { return $product.Trim() }
    } catch { }
    # Last resort: hostname.
    return $env:COMPUTERNAME
}

if (-not $branchProvided) {
    $detected = Get-MachineBranch
    # Non-interactive guard: never hang waiting on a prompt (e.g. in CI).
    if (-not [Environment]::UserInteractive) {
        Write-Error "bootstrap.ps1: no branch given and the host is non-interactive; cannot prompt. Pass the branch explicitly, e.g. -Branch $detected"
        exit 1
    }
    Write-Host "Detected machine branch: $detected"
    $reply = Read-Host "Press Enter to use it, or type a different branch name"
    if ($reply) { $Branch = $reply } else { $Branch = $detected }
}

Write-Host "bootstrap.ps1: repo=$Repo branch=$Branch"

git clone --bare $Repo "$HOME/.dotfiles"
function dotfiles { git --git-dir="$HOME/.dotfiles/" --work-tree="$HOME" @args }
dotfiles config --local status.showUntrackedFiles no

# Git pathspecs (the `.` below) are CWD-relative. The bare repo's work-tree is
# $HOME, so cd there before checking out — otherwise running bootstrap from any
# subdirectory makes `.` resolve outside the tree ("pathspec '.' did not match").
Set-Location $HOME

# Back up any conflicting OS defaults, then checkout
dotfiles checkout $Branch -- . 2>$null
if ($LASTEXITCODE -ne 0) {
    dotfiles checkout $Branch 2>&1 | Where-Object { $_ -match "^\t" } | ForEach-Object {
        $file = $_.Trim()
        if (Test-Path "$HOME\$file") {
            Move-Item "$HOME\$file" "$HOME\$file.bak" -Force
        }
    }
    dotfiles checkout $Branch -- .
}

. $PROFILE
