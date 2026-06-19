# bootstrap.ps1 — fresh-machine first-run setup for the dotfiles sync engine (PowerShell).
#
# Node 10. Mirror of bootstrap.sh — plan "A. First-run setup" in ONE run (steps 1-4); leaves
# step 5 (verify + ENABLE, `dotfiles -config machine.tick on`) to the user, deliberately:
# tick defaults OFF so a freshly cloned repo never auto-acts before you have verified it.
#
# Idempotent + safe (never clobbers existing work):
#   1. Clone the ENGINE to ~/.dotfiles/common  (from -Engine / $env:DOTFILES_ENGINE_URL).
#   2. Append the $PROFILE dot-source guard ONCE (never double-append).
#   3. Create the per-machine bare repo at ~/.dotfiles/bare-repos/machine from -Machine /
#      $env:DOTFILES_MACHINE_URL on a per-machine branch (default = hostname), wiring
#      core.hooksPath -> the engine githooks and status.showUntrackedFiles=no. A conflicting
#      work-tree file is BACKED UP (.bak-<ts>) before checkout.
#   4. Install the single timer. Tick stays OFF until you enable it.
#
# Usage:
#   $env:DOTFILES_ENGINE_URL=...; $env:DOTFILES_MACHINE_URL=...; pwsh bootstrap.ps1
#   pwsh bootstrap.ps1 -Engine <url> -Machine <url> [-Branch <name>] [-Root <dir>]

param(
  [string]$Engine  = $env:DOTFILES_ENGINE_URL,
  [string]$Machine = $env:DOTFILES_MACHINE_URL,
  [string]$Branch  = $env:DOTFILES_MACHINE_BRANCH,
  [string]$Root    = $(if ($env:DOTFILES_ROOT) { $env:DOTFILES_ROOT } else { Join-Path $HOME '.dotfiles' })
)

$ErrorActionPreference = 'Continue'

# The work-tree is $HOME. Honor an explicit $env:HOME (the test harness + cross-platform users set
# it); on Windows the PS automatic $HOME defaults to USERPROFILE which may differ from $env:HOME.
# Force the automatic $HOME to match so every `--work-tree="$HOME"` below targets the right tree.
if ($env:HOME) { Set-Variable -Name HOME -Value $env:HOME -Force -ErrorAction SilentlyContinue }

$Common    = Join-Path $Root 'common'
$Repos     = Join-Path $Root 'bare-repos'
$MachineGd = Join-Path $Repos 'machine'
if (-not $Branch) { $Branch = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { (hostname) } }

function Say($m)  { Write-Host "bootstrap: $m" }
function Warn($m) { [Console]::Error.WriteLine("bootstrap: $m") }

function Is-GitDir($dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return $false }
  git --git-dir="$dir" rev-parse --git-dir 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

New-Item -ItemType Directory -Force -Path $Root, $Repos | Out-Null

# --- 1. engine -> ~/.dotfiles/common -------------------------------------------------------
if (Test-Path -LiteralPath (Join-Path $Common '.git')) {
  Say "engine already present at $Common (skipping clone)"
} elseif ($Engine) {
  Say "cloning engine $Engine -> $Common"
  git clone $Engine $Common
  if ($LASTEXITCODE -ne 0) { Warn "engine clone failed"; exit 1 }
} else {
  Warn "no engine URL (set DOTFILES_ENGINE_URL or -Engine <url>); cannot clone engine"
  Warn "  fork the template, then: pwsh bootstrap.ps1 -Engine <your-fork-url> -Machine <url>"
  exit 1
}

$HooksTarget = Join-Path $Common 'githooks'

# --- 2. profile dot-source guard (idempotent) ----------------------------------------------
$profilePath = if ($env:DOTFILES_PROFILE) { $env:DOTFILES_PROFILE } else { $PROFILE }
$guard  = 'if (Test-Path "$HOME\.dotfiles\common\dotfiles.ps1") { . "$HOME\.dotfiles\common\dotfiles.ps1" }'
$marker = '.dotfiles\common\dotfiles.ps1'
if ($profilePath) {
  $pdir = Split-Path -Parent $profilePath
  if ($pdir -and -not (Test-Path -LiteralPath $pdir)) { New-Item -ItemType Directory -Force -Path $pdir | Out-Null }
  if (-not (Test-Path -LiteralPath $profilePath)) { New-Item -ItemType File -Force -Path $profilePath | Out-Null }
  $content = (Get-Content -Raw -LiteralPath $profilePath -ErrorAction SilentlyContinue)
  if ($null -eq $content) { $content = '' }
  if ($content -like "*$marker*") {
    Say "profile already sources the dispatcher ($profilePath) (skipping)"
  } else {
    Add-Content -LiteralPath $profilePath -Value "`n# dotfiles sync engine (added by bootstrap)`n$guard"
    Say "added dispatcher source line to $profilePath"
  }
}

# --- 3. per-machine bare repo --------------------------------------------------------------
if (Is-GitDir $MachineGd) {
  Say "machine repo already present at $MachineGd (skipping clone)"
} elseif ($Machine) {
  Say "cloning machine repo $Machine -> $MachineGd (branch $Branch)"
  git clone --bare $Machine $MachineGd
  if ($LASTEXITCODE -ne 0) { Warn "machine clone failed"; exit 1 }
  git --git-dir="$MachineGd" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git --git-dir="$MachineGd" config status.showUntrackedFiles no
  git --git-dir="$MachineGd" fetch -q origin 2>$null | Out-Null

  # NB: wire core.hooksPath AFTER the checkout below — a post-checkout hook (runner) returning
  # nonzero would otherwise make `git checkout` report failure and trip the conflict-backup path.
  git --git-dir="$MachineGd" rev-parse --verify -q "origin/$Branch" 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $ts = (Get-Date -Format 'yyyyMMddHHmmss')
    # Attempt the checkout; key off its EXIT CODE. On failure git lists the conflicting work-tree
    # paths (indented) — back each up, then retry once.
    $coOut = git --git-dir="$MachineGd" --work-tree="$HOME" checkout "$Branch" 2>&1
    if ($LASTEXITCODE -ne 0) {
      Warn "work-tree files conflict; backing up then retrying checkout"
      foreach ($line in $coOut) {
        $f = ($line -replace '^\s+', '').Trim()
        if ($f -and (Test-Path -LiteralPath (Join-Path $HOME $f))) {
          $src = Join-Path $HOME $f
          $bak = "$src.bak-$ts"
          New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bak) | Out-Null
          Move-Item -LiteralPath $src -Destination $bak -Force
          Say "backed up $f -> $f.bak-$ts"
        }
      }
      git --git-dir="$MachineGd" --work-tree="$HOME" checkout "$Branch" 2>$null | Out-Null
    }
    git --git-dir="$MachineGd" --work-tree="$HOME" branch --set-upstream-to "origin/$Branch" "$Branch" 2>$null | Out-Null
  } else {
    Say "branch $Branch not on remote; creating local branch $Branch"
    git --git-dir="$MachineGd" --work-tree="$HOME" symbolic-ref HEAD "refs/heads/$Branch" 2>$null | Out-Null
  }
  # Wire shared hooks now that the work-tree is in place (see note above).
  git --git-dir="$MachineGd" config core.hooksPath "$HooksTarget"
} else {
  Warn "no machine repo URL (set DOTFILES_MACHINE_URL or -Machine <url>); skipping machine repo"
  Warn "  create it later: git clone --bare <url> $MachineGd"
}

# --- 4. install the single timer (tick still OFF until you enable it) -----------------------
$timerPs = Join-Path (Join-Path $Common 'timer') 'dotfiles-timer.ps1'
if (Test-Path -LiteralPath $timerPs) {
  Say "installing the single auto-tick timer"
  try { & $timerPs install } catch { Warn "timer install reported an issue (files may still be written)" }
}

Write-Host @"

bootstrap: setup complete. NEXT STEPS (do these yourself — tick defaults OFF for safety):
  1. Reload your shell:        . `$PROFILE
  2. Verify the machine repo:  dotfiles machine status
  3. Health check:             dotfiles -doctor
  4. THEN enable auto-sync:    dotfiles -config machine.tick on

Until step 4 the timer runs but ticks NOTHING (every repo's tick defaults OFF).
"@
