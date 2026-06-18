# Node 6 robustness & malformed-state battery (PowerShell): the L5 BAD-path cases NOT already
# covered by test_config (L5.8-L5.12) or test_dispatcher (L5.13).
# Shared contract for ALL L5 tests: fail-isolated (one bad repo never aborts the others),
# fail-loud (clear message or safe default), never-corrupt ($HOME unchanged), never-block.
# The dispatcher runs in a CHILD pwsh via Invoke-DF (HOME isolated, real exit code captured).
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. "$here/harness.ps1"
$global:Dispatcher = Join-Path $repo 'dotfiles.ps1'

New-Env

# ---------------------------------------------------------------------------
# L5.1 no ~/.dotfiles/config -> safe defaults (tick off) -> -tick no-op, no crash, exit 0.
T-Start L5.1 BAD
Mk-RepoWithOrigin r1 main
Remove-Item -LiteralPath (Join-Path $env:DOTFILES_ROOT 'config') -Force -ErrorAction SilentlyContinue
$before = Origin-Tip r1 refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/r1/seed') -Value "changed`n" -NoNewline
Invoke-DF -tick
$after = Origin-Tip r1 refs/heads/main
Assert-Rc L5.1 $global:LastRc 0
Assert-Eq L5.1 $after $before
Assert-Contains L5.1 ((Get-Content -Raw (Join-Path $env:HOME '.config/r1/seed'))) 'changed'

# ---------------------------------------------------------------------------
# L5.3 no bare-repos/ dir -> -ls empty, -tick no-op, no crash.
T-Start L5.3 BAD
New-Env
Remove-Item -LiteralPath (Join-Path $env:DOTFILES_ROOT 'bare-repos') -Recurse -Force -ErrorAction SilentlyContinue
Invoke-DF -ls
Assert-Rc L5.3 $global:LastRc 0
Assert-Eq L5.3 ($global:LastOut.Trim()) ''
Invoke-DF -tick
Assert-Rc L5.3 $global:LastRc 0

# ---------------------------------------------------------------------------
# L5.7 unreachable origin -> that repo skipped, OTHER repos still tick (fail-isolation).
T-Start L5.7 BAD
New-Env
Mk-RepoWithOrigin good main
Mk-RepoWithOrigin bad  main
Invoke-DF -config good.tick on
Invoke-DF -config bad.tick  on
git --git-dir="$(Bare-Dir bad)" remote set-url origin (Join-Path (Join-Path $global:WORK 'origins') 'DOES_NOT_EXIST.git')
$gbefore = Origin-Tip good refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/good/seed') -Value "g`n" -NoNewline
Set-Content -LiteralPath (Join-Path $env:HOME '.config/bad/seed')  -Value "b`n" -NoNewline
Invoke-DF -tick
$gafter = Origin-Tip good refs/heads/main
if ($gafter -ne $gbefore) { T-Pass } else { T-Fail 'L5.7 good repo did not tick despite bad repo failing' }
Assert-Contains L5.7 ((Get-Content -Raw (Join-Path $env:HOME '.config/bad/seed'))) 'b'

# ---------------------------------------------------------------------------
# L5.14 corrupted bare repo (missing HEAD/objects) skipped; remaining repos tick (fail-isolation).
T-Start L5.14 BAD
New-Env
Mk-RepoWithOrigin alive main
Mk-RepoWithOrigin dead  main
Invoke-DF -config alive.tick on
Invoke-DF -config dead.tick  on
Corrupt-Repo dead
$abefore = Origin-Tip alive refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/alive/seed') -Value "live`n" -NoNewline
Invoke-DF -tick
$aafter = Origin-Tip alive refs/heads/main
if ($aafter -ne $abefore) { T-Pass } else { T-Fail 'L5.14 alive repo did not tick despite corrupt sibling' }

# ---------------------------------------------------------------------------
# L5.15 a NORMAL (non-bare) repo placed under bare-repos/ -> tick must not corrupt $HOME.
T-Start L5.15 BAD
New-Env
Mk-NonbareUnderRepos weird
Invoke-DF -config weird.tick on
Set-Content -LiteralPath (Join-Path $env:HOME '.somefile') -Value "home file`n" -NoNewline
Invoke-DF -tick
Assert-Rc L5.15 $global:LastRc 0
$wt = (git --git-dir="$(Join-Path (Bare-Dir weird) '.git')" --work-tree="$(Bare-Dir weird)" ls-files 2>$null | Out-String)
Assert-NotContains L5.15 $wt '.somefile'
Assert-Contains L5.15 ((Get-Content -Raw (Join-Path $env:HOME '.somefile'))) 'home file'

# ---------------------------------------------------------------------------
# L5.16 unborn branch (no commits yet) + a tracked file -> first tick makes the initial commit.
T-Start L5.16 GOOD
New-Env
$gd = Bare-Dir unborn
New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $global:WORK 'origins') '') | Out-Null
git init --bare -q (Join-Path (Join-Path $global:WORK 'origins') 'unborn.git')
git init --bare -q $gd
git --git-dir="$gd" --work-tree="$env:HOME" symbolic-ref HEAD refs/heads/main
git --git-dir="$gd" remote add origin (Join-Path (Join-Path $global:WORK 'origins') 'unborn.git')
New-Item -ItemType Directory -Force -Path (Join-Path $env:HOME '.config/unborn') | Out-Null
Set-Content -LiteralPath (Join-Path $env:HOME '.config/unborn/seed') -Value "first`n" -NoNewline
Invoke-DF unborn add -- .config/unborn/seed
Invoke-DF -config unborn.tick on
Invoke-DF -tick unborn
Assert-Rc L5.16 $global:LastRc 0
Assert-Contains L5.16 (git --git-dir="$gd" --work-tree="$env:HOME" log --oneline 2>$null | Out-String) 'unborn: auto'
Assert-Contains L5.16 (git --git-dir="$gd" --work-tree="$env:HOME" ls-files 2>$null | Out-String) '.config/unborn/seed'

# ---------------------------------------------------------------------------
# L5.17 repo dir name with spaces -> routing/discovery/passthrough quoting holds.
T-Start L5.17 GOOD
New-Env
Mk-RepoWithOrigin 'my repo' main
Invoke-DF -ls
Assert-Contains L5.17 $global:LastOut 'my repo'
Invoke-DF 'my repo' status --short
Assert-NotContains L5.17 $global:LastErr 'no such repo'
Set-Content -LiteralPath (Join-Path $env:HOME '.config/my repo/seed') -Value "spaced`n" -NoNewline
Invoke-DF 'my repo' add -- '.config/my repo/seed'
Assert-Rc L5.17 $global:LastRc 0
Invoke-DF 'my repo' commit -q -m 'spaced: edit'
Assert-Rc L5.17 $global:LastRc 0
Assert-Contains L5.17 (git --git-dir="$(Bare-Dir 'my repo')" --work-tree="$env:HOME" log --oneline | Out-String) 'spaced: edit'
# Auto-tick for a spaced name is impossible (git-config forbids spaces in section names) -> named SKIP.
T-Start 'L5.17-autotick' BAD
T-Skip 'git-config section names forbid spaces; <repo>.tick gate cannot key a spaced repo name (schema constraint, not a Node 6 bug)'

# ---------------------------------------------------------------------------
# L5.19 detached HEAD -> tick refuses to push (no branch), skips, no crash, work-tree intact.
T-Start L5.19 BAD
New-Env
Mk-RepoWithOrigin det main
Invoke-DF -config det.tick on
$sha = (git --git-dir="$(Bare-Dir det)" rev-parse HEAD | Out-String).Trim()
git --git-dir="$(Bare-Dir det)" --work-tree="$env:HOME" checkout -q --detach $sha
$before = Origin-Tip det refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/det/seed') -Value "detached edit`n" -NoNewline
Invoke-DF -tick det
$after = Origin-Tip det refs/heads/main
Assert-Rc L5.19 $global:LastRc 0
Assert-Eq L5.19 $after $before
Assert-Contains L5.19 ((Get-Content -Raw (Join-Path $env:HOME '.config/det/seed'))) 'detached edit'

# ---------------------------------------------------------------------------
# L5.21 branch with no upstream -> commit locally, push skipped (logged), no crash.
T-Start L5.21 BAD
New-Env
$gd = Bare-Dir noups
git init --bare -q $gd
git --git-dir="$gd" --work-tree="$env:HOME" symbolic-ref HEAD refs/heads/main
New-Item -ItemType Directory -Force -Path (Join-Path $env:HOME '.config/noups') | Out-Null
Set-Content -LiteralPath (Join-Path $env:HOME '.config/noups/seed') -Value "seed`n" -NoNewline
git --git-dir="$gd" --work-tree="$env:HOME" add -- .config/noups/seed
git --git-dir="$gd" --work-tree="$env:HOME" commit -q -m 'noups: seed'
Invoke-DF -config noups.tick on
Set-Content -LiteralPath (Join-Path $env:HOME '.config/noups/seed') -Value "local only`n" -NoNewline
$nbefore = (git --git-dir="$gd" rev-parse HEAD | Out-String).Trim()
Invoke-DF -tick noups
$nafter = (git --git-dir="$gd" rev-parse HEAD | Out-String).Trim()
Assert-Rc L5.21 $global:LastRc 0
if ($nafter -ne $nbefore) { T-Pass } else { T-Fail 'L5.21 local commit not made without upstream' }

# ---------------------------------------------------------------------------
# L5.22 unrelated histories -> reconcile REFUSES (no forced merge); work-tree untouched.
T-Start L5.22 BAD
New-Env
Mk-RepoWithOrigin unrel main
Invoke-DF -config unrel.tick on
$orig = Origin-Dir unrel
$scratch = Join-Path $global:WORK 'scratch'
git init -q $scratch
Set-Content -LiteralPath (Join-Path $scratch 'alien') -Value "alien`n" -NoNewline
git -C "$scratch" add alien
git -C "$scratch" commit -q -m 'alien root'
git -C "$scratch" push -q --force $orig HEAD:refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/unrel/seed') -Value "mine`n" -NoNewline
Invoke-DF -tick unrel
Assert-Rc L5.22 $global:LastRc 1
Assert-Contains L5.22 $global:LastErr 'unrelated histories'
Assert-Contains L5.22 ((Get-Content -Raw (Join-Path $env:HOME '.config/unrel/seed'))) 'mine'

# ---------------------------------------------------------------------------
# L5.23 stale MERGE_HEAD AND stale index.lock from a crashed prior tick -> recovered, tick proceeds.
T-Start L5.23 BAD
New-Env
Mk-RepoWithOrigin crash main
Invoke-DF -config crash.tick on
Plant-StaleMerge crash
Plant-StaleLock  crash
$before = Origin-Tip crash refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/crash/seed') -Value "after crash`n" -NoNewline
$env:DOTFILES_LOCK_STALE = '1'
Invoke-DF -tick crash
$env:DOTFILES_LOCK_STALE = $null
$after = Origin-Tip crash refs/heads/main
Assert-Rc L5.23 $global:LastRc 0
if ($after -ne $before) { T-Pass } else { T-Fail 'L5.23 tick did not proceed after stale-state recovery' }
if (-not (Test-Path -LiteralPath (Join-Path (Bare-Dir crash) 'MERGE_HEAD'))) { T-Pass } else { T-Fail 'L5.23 stale MERGE_HEAD not cleared' }
if (-not (Test-Path -LiteralPath (Join-Path (Bare-Dir crash) 'index.lock'))) { T-Pass } else { T-Fail 'L5.23 stale index.lock not cleared' }

# ---------------------------------------------------------------------------
# L5.27 concurrent tick on one repo -> the second is serialized/skips, no index corruption.
# A LIVE tick is simulated with a FRESH tick-lock; a new tick must SKIP (never block), leave the
# lock alone, and not commit/push.
T-Start L5.27 BAD
New-Env
Mk-RepoWithOrigin conc main
Invoke-DF -config conc.tick on
Plant-LiveLock conc
$before = Origin-Tip conc refs/heads/main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/conc/seed') -Value "racing`n" -NoNewline
Invoke-DF -tick conc
$after = Origin-Tip conc refs/heads/main
Assert-Rc L5.27 $global:LastRc 0
Assert-Eq L5.27 $after $before
Assert-Contains L5.27 $global:LastErr 'already running'
if (Has-TickLock conc) { T-Pass } else { T-Fail 'L5.27 live lock was wrongly removed by the skipping tick' }

T-Summary
