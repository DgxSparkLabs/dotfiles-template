# Node 11 — cross-OS interop step (PowerShell entry point).
#
# DESIGN NOTE (why this is a thin wrapper, not a parallel port):
# L4 proves the SAME engine + SAME repo round-trips across ubuntu/windows/macos through one shared
# origin. The faithful Windows surface for that is Git-for-Windows `bash` (sh.exe) — the very shell
# the dotfiles hooks already run under (see tests/test_hooks.* and PITFALLS "Git-for-Windows
# sh.exe"). A second, independent PowerShell implementation of the edit+tick+assert logic would test
# a different code path than the other two legs and so would NOT prove cross-OS sameness — it would
# test the test. Therefore the single source of truth is tests/interop_step.sh, and the Windows leg
# runs it via Git-Bash. This wrapper exists so a pwsh-driven CI step (or a local
# `pwsh tests/interop_step.ps1 leg windows`) can invoke the same script uniformly.
#
# Usage: pwsh tests/interop_step.ps1 <seed|leg <os>|verify|clash <os> <line> <date>|verify-clash <expected>>
# Honors $env:INTEROP_WORK (the job-local work dir shared with the bash legs).

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$script = Join-Path $here 'interop_step.sh'

# Locate Git-for-Windows bash (sh.exe family — the same surface the hooks run under). PREFER the
# standard Git install locations over a bare `bash` on PATH: on a default Windows box `bash` on PATH
# is often the WSL stub (System32\bash.exe), which would run a Linux distro (or error if none is
# installed) instead of Git-Bash. On GH windows runners Git is at $env:ProgramFiles\Git.
$bash = $null
$candidates = @(
  "$env:ProgramFiles\Git\bin\bash.exe",
  "$env:ProgramFiles\Git\usr\bin\bash.exe",
  "${env:ProgramFiles(x86)}\Git\bin\bash.exe"
)
foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $bash = $c; break } }
if (-not $bash) {
  # Last resort: a `bash` on PATH that is NOT the WSL System32 stub.
  $onPath = (Get-Command bash -ErrorAction SilentlyContinue)?.Source
  if ($onPath -and $onPath -notmatch '\\System32\\') { $bash = $onPath }
}
if (-not $bash) { Write-Error 'interop_step.ps1: no Git-for-Windows bash.exe found (looked in Program Files\Git and PATH, excluding the WSL stub)'; exit 2 }

& $bash $script @args
exit $LASTEXITCODE
