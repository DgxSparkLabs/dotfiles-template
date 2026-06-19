# migrate.ps1 — migrate an EXISTING single-repo dotfiles user to the container layout (PowerShell).
#
# Node 10. Mirror of migrate.sh. Legacy layout = a BARE git-dir AT ~/.dotfiles (HEAD/objects/refs
# directly under it) plus helper files under ~/.dotfiles/.dotfiles/. New layout:
#     ~/.dotfiles/common/                 ENGINE (this repo / your fork)
#     ~/.dotfiles/bare-repos/machine/     the legacy bare git-dir, RELOCATED here
#     ~/.dotfiles/hooks/  config  state/  per-repo data, beside (never inside) the bare repos
# Work-tree files in $HOME NEVER move — only the git metadata relocates and the engine splits out.
#
# Safe step order (idempotent; re-runnable; aborts clearly on ambiguous state):
#   a. detect legacy layout    b. STOP old timer FIRST    c. relocate git-dir -> bare-repos/machine
#   d. ensure engine at common/    e. wire core.hooksPath    f. swap profile aliases for the dispatcher
#   g. install the new single timer (tick stays OFF until you enable it)
#
# Usage:  pwsh migrate.ps1 [-Engine <url>] [-Root <dir>]   |   $env:DOTFILES_ENGINE_URL=... ; pwsh migrate.ps1

param(
  [string]$Engine = $env:DOTFILES_ENGINE_URL,
  [string]$Root   = $(if ($env:DOTFILES_ROOT) { $env:DOTFILES_ROOT } else { Join-Path $HOME '.dotfiles' })
)

$ErrorActionPreference = 'Continue'

# Work-tree = $HOME; honor an explicit $env:HOME (test harness / cross-platform). On Windows the
# automatic $HOME defaults to USERPROFILE which may differ — force it to match $env:HOME.
if ($env:HOME) { Set-Variable -Name HOME -Value $env:HOME -Force -ErrorAction SilentlyContinue }

$Common      = Join-Path $Root 'common'
$Repos       = Join-Path $Root 'bare-repos'
$MachineGd   = Join-Path $Repos 'machine'
$HooksTarget = Join-Path $Common 'githooks'

function Say($m)  { Write-Host "migrate: $m" }
function Warn($m) { [Console]::Error.WriteLine("migrate: $m") }
function Abort($m){ [Console]::Error.WriteLine("migrate: ABORT: $m"); exit 1 }

function Is-GitDir($dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return $false }
  git --git-dir="$dir" rev-parse --git-dir 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

# --- a. detect legacy layout ---------------------------------------------------------------
$legacyPresent = $false
if ((Test-Path -LiteralPath (Join-Path $Root 'HEAD')) -and
    (Test-Path -LiteralPath (Join-Path $Root 'objects')) -and
    (Is-GitDir $Root)) {
  $legacyPresent = $true
}
$alreadyMigrated = (Is-GitDir $MachineGd)

if (-not $legacyPresent -and $alreadyMigrated) {
  Say "already migrated: machine repo at $MachineGd and no legacy git-dir at $Root"
} elseif (-not $legacyPresent -and -not $alreadyMigrated) {
  Abort "no legacy layout at $Root and no machine repo to finish. Fresh machine? Run bootstrap.ps1 instead."
} elseif ($legacyPresent -and $alreadyMigrated) {
  Abort "ambiguous: a legacy git-dir AND a migrated machine repo both exist. Resolve by hand (inspect $Root vs $MachineGd)."
} else {
  Say "legacy single-repo layout detected at $Root"
}

# --- b. STOP the OLD timer FIRST -----------------------------------------------------------
Say "stopping any legacy timer (before relocating the git-dir)"
try { Unregister-ScheduledTask -TaskName 'dotfiles-git-commit' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
# Stop any legacy detached loop process referencing the old root.
try {
  Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*dotfiles-tick-loop*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
} catch {}
# If the new engine timer is present, its uninstall is the cleanest stop.
$timerPs = Join-Path (Join-Path $Common 'timer') 'dotfiles-timer.ps1'
if (Test-Path -LiteralPath $timerPs) {
  try { & $timerPs uninstall *> $null } catch {}
}

# --- c. relocate the legacy bare git-dir into bare-repos/machine ---------------------------
New-Item -ItemType Directory -Force -Path $Repos | Out-Null
if ($legacyPresent) {
  if ($alreadyMigrated) { Abort "machine repo already exists at $MachineGd; refusing to overwrite. Remove it first to re-migrate." }
  Say "moving legacy git-dir contents from $Root -> $MachineGd (work-tree files in `$HOME stay put)"
  New-Item -ItemType Directory -Force -Path $MachineGd | Out-Null
  $skip = @('common','bare-repos','hooks','config','state','.dotfiles')
  $moved = 0
  foreach ($item in (Get-ChildItem -LiteralPath $Root -Force)) {
    if ($skip -contains $item.Name) { continue }   # new-layout dirs + legacy helper subtree
    Move-Item -LiteralPath $item.FullName -Destination $MachineGd -Force
    $moved++
  }
  Say "relocated $moved git-dir entr(ies)"
  if (-not (Is-GitDir $MachineGd)) { Abort "relocated $MachineGd is not a valid git-dir; restore from $Root and retry." }
}

# --- d. ensure the engine is at ~/.dotfiles/common -----------------------------------------
if (Test-Path -LiteralPath (Join-Path $Common '.git')) {
  Say "engine already present at $Common"
} elseif ($Engine) {
  Say "cloning engine $Engine -> $Common"
  git clone $Engine $Common
  if ($LASTEXITCODE -ne 0) { Abort "engine clone failed" }
} else {
  Warn "no engine at $Common and no -Engine/`$env:DOTFILES_ENGINE_URL given."
  Warn "  clone your fork there: git clone <engine-url> $Common   (then re-run migrate.ps1)"
}

# --- e. wire the machine repo's core.hooksPath + showUntrackedFiles -------------------------
if (Is-GitDir $MachineGd) {
  git --git-dir="$MachineGd" config core.hooksPath "$HooksTarget"
  git --git-dir="$MachineGd" config status.showUntrackedFiles no
  Say "set machine core.hooksPath -> $HooksTarget"
}

# --- f. swap old aliases in the profile for the sourced dispatcher --------------------------
# PowerShell profile sources the .ps1 dispatcher. Remove any legacy alias / dot-source lines that
# referenced the old helper path, then append the new dot-source guard ONCE.
$profilePath = if ($env:DOTFILES_PROFILE) { $env:DOTFILES_PROFILE } else { $PROFILE }
$guard  = 'if (Test-Path "$HOME\.dotfiles\common\dotfiles.ps1") { . "$HOME\.dotfiles\common\dotfiles.ps1" }'
$marker = '.dotfiles\common\dotfiles.ps1'
if ($profilePath) {
  $pdir = Split-Path -Parent $profilePath
  if ($pdir -and -not (Test-Path -LiteralPath $pdir)) { New-Item -ItemType Directory -Force -Path $pdir | Out-Null }
  if (Test-Path -LiteralPath $profilePath) {
    $lines = Get-Content -LiteralPath $profilePath
    # Drop legacy alias defs (dotfiles / dotfiles-timer / dotfiles-sync) and old-helper dot-sources.
    $kept = $lines | Where-Object {
      ($_ -notmatch '^\s*(Set-Alias|New-Alias)\s+(-Name\s+)?dotfiles(-timer|-sync)?\b') -and
      ($_ -notmatch '\.dotfiles\\\.dotfiles\\')
    }
    Set-Content -LiteralPath $profilePath -Value $kept
    Say "removed legacy dotfiles aliases from $profilePath (if any)"
  } else {
    New-Item -ItemType File -Force -Path $profilePath | Out-Null
  }
  $content = (Get-Content -Raw -LiteralPath $profilePath -ErrorAction SilentlyContinue)
  if ($null -eq $content) { $content = '' }
  if ($content -like "*$marker*") {
    Say "profile already sources the dispatcher ($profilePath)"
  } else {
    Add-Content -LiteralPath $profilePath -Value "`n# dotfiles sync engine (added by migrate)`n$guard"
    Say "added dispatcher source line to $profilePath"
  }
}

# --- g. install the new single timer (tick OFF until you enable it) -------------------------
if (Test-Path -LiteralPath $timerPs) {
  Say "installing the new single auto-tick timer"
  try { & $timerPs install } catch { Warn "timer install reported an issue (files may still be written)" }
}

Write-Host @"

migrate: done. Your machine config now lives at $MachineGd; the engine at $Common.
NEXT STEPS (tick defaults OFF for safety):
  1. Reload your shell:        . `$PROFILE
  2. Verify:                   dotfiles machine status   &&   dotfiles -doctor
  3. THEN enable auto-sync:    dotfiles -config machine.tick on
(Note: the old 'dotfiles update' master->machine flow is re-homed — use 'dotfiles machine merge master'.)
"@
