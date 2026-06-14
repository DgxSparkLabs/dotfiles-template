# bootstrap.ps1 — restore a machine from scratch (run once on a fresh machine).
#
# The `dotfiles` function lives in your profile — which hasn't been restored
# yet. This defines it temporarily, clones your bare repo, then checks out your
# machine's branch (which restores the profile and re-establishes the function).
#
# Parameters (command-line only — no environment variables):
#   -Repo <url>     (required) git remote URL, e.g. git@github.com:<YOU>/dotfiles.git
#   -Branch <name>  (optional) branch to check out. If omitted, the machine name
#                   is auto-detected and you are prompted to confirm it or type
#                   a different branch.
#   -y / -Yes       (optional) auto-accept the auto-detected branch without
#                   prompting (useful for non-interactive / scripted setup).
#
# Usage:
#   pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git
#   pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git -Branch my-laptop
#   pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git -y
#
# Branch resolution precedence:
#   1. explicit -Branch <name> always wins.
#   2. else with -y/-Yes, auto-accept the auto-detected machine name without
#      prompting (and without the non-interactive error).
#   3. else if the host is interactive, prompt to confirm or override.
#   4. else (no branch, no -Yes, non-interactive) error and exit 1.

param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,
    [string]$Branch,
    [Alias('y')]
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# ── Repo: required, command-line parameter only ─────────────────────────────
if (-not $Repo) {
    Write-Error "bootstrap.ps1: -Repo is required (the git remote URL of your dotfiles repo). e.g. pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git"
    exit 1
}

# Track whether a branch was supplied on the command line.
$branchProvided = [bool]$Branch

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
    if ($Yes) {
        # -y/-Yes: auto-accept the detected name without prompting (and without
        # the non-interactive error below).
        $Branch = $detected
        Write-Host "bootstrap.ps1: -y given, auto-accepting detected branch: $detected"
    }
    elseif (-not [Environment]::UserInteractive) {
        # Non-interactive guard: never hang waiting on a prompt (e.g. in CI).
        Write-Error "bootstrap.ps1: no branch given and the host is non-interactive; cannot prompt. Pass the branch explicitly (-Branch $detected) or use -y to auto-accept it."
        exit 1
    }
    else {
        Write-Host "Detected machine branch: $detected"
        $reply = Read-Host "Press Enter to use it, or type a different branch name"
        if ($reply) { $Branch = $reply } else { $Branch = $detected }
    }
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

# The pathspec checkout above restores the work tree + index from the branch but
# leaves HEAD on the bare clone's default branch. Point HEAD at this machine's
# branch so the daily workflow (commit/push) lands there. The work tree already
# matches the branch, so this does not touch any files and status stays clean.
dotfiles symbolic-ref HEAD "refs/heads/$Branch"
