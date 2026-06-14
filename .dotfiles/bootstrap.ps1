# bootstrap.ps1 — restore a machine from scratch (run once on a fresh machine).
#
# The `dotfiles` function lives in your profile — which hasn't been restored
# yet. This defines it temporarily, clones your bare repo, then checks out your
# machine's branch (which restores the profile and re-establishes the function).
#
# Parameters (environment variables):
#   DOTFILES_REPO    (required) git remote URL, e.g. git@github.com:<YOU>/dotfiles.git
#   DOTFILES_BRANCH  (optional) branch to check out. Defaults to the auto-detected
#                    machine name: the baseboard product (Win32_BaseBoard.product).
#
# Usage:
#   $env:DOTFILES_REPO = "git@github.com:<YOU>/dotfiles.git"; pwsh bootstrap.ps1
#   $env:DOTFILES_REPO = "..."; $env:DOTFILES_BRANCH = "my-laptop"; pwsh bootstrap.ps1

$ErrorActionPreference = 'Stop'

# ── Required parameter: fail fast if the remote URL is missing ──────────────
if (-not $env:DOTFILES_REPO) {
    Write-Error "bootstrap.ps1: DOTFILES_REPO is required (the git remote URL of your dotfiles repo). e.g. `$env:DOTFILES_REPO = 'git@github.com:<YOU>/dotfiles.git'"
    exit 1
}
$REPO = $env:DOTFILES_REPO

# ── Branch: explicit override, else auto-detect this machine's name ─────────
function Get-MachineBranch {
    try {
        $product = (Get-WmiObject Win32_BaseBoard -ErrorAction Stop).product
        if ($product) { return $product.Trim() }
    } catch { }
    # Last resort: hostname.
    return $env:COMPUTERNAME
}
$BRANCH = if ($env:DOTFILES_BRANCH) { $env:DOTFILES_BRANCH } else { Get-MachineBranch }

Write-Host "bootstrap.ps1: repo=$REPO branch=$BRANCH"

git clone --bare $REPO "$HOME/.dotfiles"
function dotfiles { git --git-dir="$HOME/.dotfiles/" --work-tree="$HOME" @args }
dotfiles config --local status.showUntrackedFiles no

# Git pathspecs (the `.` below) are CWD-relative. The bare repo's work-tree is
# $HOME, so cd there before checking out — otherwise running bootstrap from any
# subdirectory makes `.` resolve outside the tree ("pathspec '.' did not match").
Set-Location $HOME

# Back up any conflicting OS defaults, then checkout
dotfiles checkout $BRANCH -- . 2>$null
if ($LASTEXITCODE -ne 0) {
    dotfiles checkout $BRANCH 2>&1 | Where-Object { $_ -match "^\t" } | ForEach-Object {
        $file = $_.Trim()
        if (Test-Path "$HOME\$file") {
            Move-Item "$HOME\$file" "$HOME\$file.bak" -Force
        }
    }
    dotfiles checkout $BRANCH -- .
}

. $PROFILE
