# Node 8 per-repo hook dispatch (PowerShell): L1.7-L1.10, L5.4, L5.6, L4.4.
# A bare repo's core.hooksPath -> the engine's shared stubs -> the Python runner
# (dotfiles_githooks), which identifies the firing repo via
# `git rev-parse --absolute-git-dir` (basename) and runs:
#     <root>/hooks/_shared/<hook>   (ALL repos)   then
#     <root>/hooks/<repo>/<hook>    (THIS repo only)
# These tests fire REAL commits (git, not the dotfiles dispatcher) so the runner is exercised
# exactly as git invokes it. On Windows this is the Git-for-Windows sh.exe leg (L1.10/L4.4).
# Behavior-identical to test_hooks.sh.
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. "$here/harness.ps1"
$global:RepoUnderTest = $repo

# uv must be available (the stub invokes `uv run`). It is on CI + locally.
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
  T-Start L1.7 GOOD; T-Fail "uv not on PATH (hook runner cannot run)"; T-Summary
}

New-Env
$mark = Join-Path $global:WORK 'marks'; New-Item -ItemType Directory -Force -Path $mark | Out-Null

# ---------------------------------------------------------------------------
# L1.7 per-repo hook fires: hooks/nvim/pre-commit writes a marker -> a commit in nvim runs it.
T-Start L1.7 GOOD
Mk-RepoHookable nvim main
$env:DF_MARK = Join-Path $mark 'nvim_pre.txt'; Remove-Item -LiteralPath $env:DF_MARK -ErrorAction SilentlyContinue
Write-Hook nvim pre-commit 'echo fired > "$DF_MARK"'
Commit-In nvim .config/nvim/init.lua "set number"
Assert-Rc L1.7 $global:LastRc 0
$m = (Get-Content -Raw -LiteralPath $env:DF_MARK -ErrorAction SilentlyContinue)
Assert-Contains L1.7 $m 'fired'

# ---------------------------------------------------------------------------
# L1.8 isolation: a commit in a DIFFERENT repo does NOT run nvim's hook (marker absent).
T-Start L1.8 GOOD
Mk-RepoHookable machine main
Remove-Item -LiteralPath (Join-Path $mark 'nvim_pre.txt') -ErrorAction SilentlyContinue
$env:DF_MARK = Join-Path $mark 'nvim_pre.txt'
Commit-In machine .config/machine/cfg "host=x"
Assert-Rc L1.8 $global:LastRc 0
if (-not (Test-Path -LiteralPath (Join-Path $mark 'nvim_pre.txt'))) { T-Pass } else { T-Fail "L1.8 nvim hook ran on a machine commit" }

# ---------------------------------------------------------------------------
# L1.9 _shared fires for ALL repos: append repo name; a commit in BOTH nvim and machine each
# append a line (so it ran for both).
T-Start L1.9 GOOD
$env:DF_SHARED = Join-Path $mark 'shared.log'; Remove-Item -LiteralPath $env:DF_SHARED -ErrorAction SilentlyContinue
Write-Hook _shared pre-commit 'echo "shared:$(basename "$(git rev-parse --absolute-git-dir)")" >> "$DF_SHARED"'
Commit-In nvim    .config/nvim/a.lua    "a"; $r1 = $global:LastRc
Commit-In machine .config/machine/b.cfg "b"; $r2 = $global:LastRc
Assert-Rc L1.9 $r1 0
Assert-Rc L1.9 $r2 0
$log = (Get-Content -Raw -LiteralPath $env:DF_SHARED -ErrorAction SilentlyContinue)
Assert-Contains L1.9 $log 'shared:nvim'
Assert-Contains L1.9 $log 'shared:machine'

# ---------------------------------------------------------------------------
# L1.10 / L4.4 identity: hook records `git rev-parse --absolute-git-dir` basename; must equal the
# firing repo name. INFERRED assumption; this is the Git-for-Windows sh.exe leg on Windows.
T-Start L1.10 GOOD
$env:DF_ID = Join-Path $mark 'id.txt'; Remove-Item -LiteralPath $env:DF_ID -ErrorAction SilentlyContinue
Write-Hook nvim post-commit 'basename "$(git rev-parse --absolute-git-dir)" > "$DF_ID"'
Commit-In nvim .config/nvim/id.lua "x"
Assert-Rc L1.10 $global:LastRc 0
$id = (Get-Content -Raw -LiteralPath $env:DF_ID -ErrorAction SilentlyContinue)
if ($null -ne $id) { $id = $id.Trim() }
Assert-Eq L1.10 $id 'nvim'

# ---------------------------------------------------------------------------
# L5.4 missing hooks/<repo> AND hooks/_shared -> commit succeeds, nothing runs, no crash.
T-Start L5.4 GOOD
New-Env; $mark = Join-Path $global:WORK 'marks'; New-Item -ItemType Directory -Force -Path $mark | Out-Null
Mk-RepoHookable solo main
$h = Join-Path $env:DOTFILES_ROOT 'hooks'
if (Test-Path -LiteralPath $h) { Remove-Item -LiteralPath $h -Recurse -Force }
Commit-In solo .config/solo/x "y"
Assert-Rc L5.4 $global:LastRc 0
Assert-Contains L5.4 (Tree-Names solo) '.config/solo/x'

# ---------------------------------------------------------------------------
# L5.4b non-executable per-repo hook is SILENTLY SKIPPED on Linux/macOS (git's behavior; the
# runner mirrors it). On Windows there is no executable bit -> SKIP with a named reason.
T-Start L5.4b GOOD
if ($IsWindows) {
  T-Skip "no executable bit on Windows: non-exec skip is a POSIX-only guarantee"
} else {
  New-Env; $mark = Join-Path $global:WORK 'marks'; New-Item -ItemType Directory -Force -Path $mark | Out-Null
  Mk-RepoHookable ne main
  $env:DF_MARK = Join-Path $mark 'ne.txt'; Remove-Item -LiteralPath $env:DF_MARK -ErrorAction SilentlyContinue
  $dir = Join-Path (Join-Path $env:DOTFILES_ROOT 'hooks') 'ne'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $dir 'pre-commit'), "#!/bin/sh`necho ran > `"`$DF_MARK`"`n")
  chmod -x (Join-Path $dir 'pre-commit')
  Commit-In ne .config/ne/x "z"
  Assert-Rc L5.4b $global:LastRc 0
  if (-not (Test-Path -LiteralPath $env:DF_MARK)) { T-Pass } else { T-Fail "L5.4b non-executable hook ran" }
}

# ---------------------------------------------------------------------------
# L5.6 core.hooksPath set to a MISSING dir -> git runs no hooks (no crash); commit still works.
T-Start L5.6 GOOD
New-Env; $mark = Join-Path $global:WORK 'marks'; New-Item -ItemType Directory -Force -Path $mark | Out-Null
Mk-RepoHookable miss main
git --git-dir="$(Bare-Dir miss)" config core.hooksPath (Join-Path $env:DOTFILES_ROOT 'no-such-hooks-dir')
Commit-In miss .config/miss/x "q"
Assert-Rc L5.6 $global:LastRc 0
Assert-Contains L5.6 (Tree-Names miss) '.config/miss/x'

# ---------------------------------------------------------------------------
# L5.block a non-zero per-repo hook BLOCKS the commit (runner surfaces the exit code).
T-Start L5.block BAD
New-Env; $mark = Join-Path $global:WORK 'marks'; New-Item -ItemType Directory -Force -Path $mark | Out-Null
Mk-RepoHookable blk main
Write-Hook blk pre-commit 'echo "no" >&2; exit 3'
Commit-In blk .config/blk/x "should-not-commit"
if ($global:LastRc -ne 0) { T-Pass } else { T-Fail "L5.block commit was NOT blocked (rc=$($global:LastRc))" }
Assert-NotContains L5.block (Tree-Names blk) '.config/blk/x'

# ---------------------------------------------------------------------------
# L5.5 uv-missing: SKIP with a named reason (cannot safely unset uv from PATH on the shared
# runner). The stub fail-loud is covered by manual verification + validate-githooks.
T-Start L5.5 GOOD
T-Skip "cannot safely unset uv from PATH on the shared runner"

T-Summary
