# Node 4 generic tick, single-writer path (PowerShell): L1.1-L1.6, L2.1.
# The tick add->commit->pushes a repo's OWN territory, gated by <repo>.tick (default OFF),
# add flag from <repo>.add. We assert against the fake origin (advanced? which files?).
# `dotfiles -tick` runs in a CHILD pwsh via Invoke-DF (HOME isolated, real exit code captured).
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. "$here/harness.ps1"
$global:Dispatcher = Join-Path $repo 'dotfiles.ps1'

New-Env

# ---------------------------------------------------------------------------
# L1.1 edit a tracked file in an enabled repo -> after -tick it is committed AND pushed.
T-Start L1.1 GOOD
Mk-RepoWithOrigin nvim main
Invoke-DF -config nvim.tick on
$before = Origin-Tip nvim refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/nvim/seed') -Value "set number`n" -NoNewline
Invoke-DF -tick nvim
$after = Origin-Tip nvim refs/heads/main
Assert-Rc L1.1 $global:LastRc 0
if ($before -ne $after) { T-Pass } else { T-Fail 'L1.1 origin did not advance' }
$od = Origin-Dir nvim
$names = (git --git-dir="$od" ls-tree -r --name-only refs/heads/main | Out-String)
Assert-Contains L1.1 $names '.config/nvim/seed'
$blob = (git --git-dir="$od" ls-tree -r refs/heads/main -- .config/nvim/seed | ForEach-Object { ($_ -split '\s+')[2] } | Select-Object -First 1)
Assert-Contains L1.1 ((git --git-dir="$od" cat-file -p $blob) | Out-String) 'set number'

# ---------------------------------------------------------------------------
# L1.2 scoped-add never crosses repos: A,B enabled with disjoint owned dirs; modify a B-owned
# file; tick A; A's new commit must NOT include the B file (even with A.add=all).
T-Start L1.2 GOOD
New-Env
Mk-RepoWithOrigin alpha main
Mk-RepoWithOrigin beta  main
Invoke-DF -config alpha.tick on
Invoke-DF -config alpha.add all
Invoke-DF -config beta.tick on
Set-Content -LiteralPath (Join-Path $env:HOME '.config/alpha/seed') -Value "edit-a`n" -NoNewline
Set-Content -LiteralPath (Join-Path $env:HOME '.config/beta/seed')  -Value "edit-b`n" -NoNewline
Invoke-DF -tick alpha
$names = (git --git-dir="$(Origin-Dir alpha)" show --name-only --pretty=format: refs/heads/main | Out-String)
Assert-Contains    L1.2 $names '.config/alpha/seed'
Assert-NotContains L1.2 $names '.config/beta/seed'

# ---------------------------------------------------------------------------
# L1.3 tick-off safety: repo with tick UNSET -> -tick makes NO commit, origin unchanged.
T-Start L1.3 GOOD
New-Env
Mk-RepoWithOrigin solo main
$before = Origin-Tip solo refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/solo/seed') -Value "changed`n" -NoNewline
Invoke-DF -tick solo
$after = Origin-Tip solo refs/heads/main
Assert-Rc L1.3 $global:LastRc 0
Assert-Eq L1.3 $after $before

# ---------------------------------------------------------------------------
# L1.4 enable then sync: turn tick on -> -tick now advances origin.
T-Start L1.4 GOOD
$before = Origin-Tip solo refs/heads/main
Invoke-DF -config solo.tick on
Invoke-DF -tick solo
$after = Origin-Tip solo refs/heads/main
if ($after -ne $before) { T-Pass } else { T-Fail 'L1.4 origin did not advance after enabling tick' }

# ---------------------------------------------------------------------------
# L1.5 add=tracked ignores a NEW untracked file (default add).
T-Start L1.5 GOOD
New-Env
Mk-RepoWithOrigin trk main
Invoke-DF -config trk.tick on
Set-Content -LiteralPath (Join-Path $env:HOME '.config/trk/newfile') -Value "brand new`n" -NoNewline
Invoke-DF -tick trk
$names = (git --git-dir="$(Origin-Dir trk)" show --name-only --pretty=format: refs/heads/main 2>$null | Out-String)
Assert-NotContains L1.5 $names '.config/trk/newfile'
$tracked = (git --git-dir="$(Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') 'trk')" --work-tree="$env:HOME" ls-files | Out-String)
Assert-NotContains L1.5 $tracked '.config/trk/newfile'

# ---------------------------------------------------------------------------
# L1.6 add=all stages a NEW untracked file under the repo's tracked dir.
T-Start L1.6 GOOD
New-Env
Mk-RepoWithOrigin allr main
Invoke-DF -config allr.tick on
Invoke-DF -config allr.add all
Set-Content -LiteralPath (Join-Path $env:HOME '.config/allr/newfile') -Value "grab me`n" -NoNewline
Invoke-DF -tick allr
$names = (git --git-dir="$(Origin-Dir allr)" show --name-only --pretty=format: refs/heads/main | Out-String)
Assert-Contains L1.6 $names '.config/allr/newfile'

# ---------------------------------------------------------------------------
# L2.1 two machines, different files: machine2 is a second bare repo + work-tree cloned from the
# SAME origin. M1 edits f1 & ticks (push); M2 fetches + fast-forwards to receive f1.
# NOTE: full bidirectional merge is node 5; this proves the origin round-trips via push + a
# manual fetch/reset on the second machine (non-overlapping propagation only).
T-Start L2.1 GOOD
New-Env
Mk-RepoWithOrigin proj main
Invoke-DF -config proj.tick on
$M2HOME = Join-Path $global:WORK 'home2'
$M2GD   = Join-Path (Join-Path $global:WORK 'm2') 'proj.git'
New-Item -ItemType Directory -Force -Path $M2HOME, (Join-Path $global:WORK 'm2') | Out-Null
git clone -q --bare (Origin-Dir proj) $M2GD
git --git-dir="$M2GD" --work-tree="$M2HOME" checkout -q -f main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/proj/seed') -Value "from-m1`n" -NoNewline
Invoke-DF -tick proj
# bare clone maps origin heads onto its OWN refs/heads, so reset to FETCH_HEAD.
git --git-dir="$M2GD" --work-tree="$M2HOME" fetch -q origin main
git --git-dir="$M2GD" --work-tree="$M2HOME" reset -q --hard FETCH_HEAD
Assert-Contains L2.1 ((Get-Content -Raw (Join-Path $M2HOME '.config/proj/seed'))) 'from-m1'

T-Summary
