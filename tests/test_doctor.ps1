# Node 7 -doctor: health + the load-bearing exclusive-ownership invariant (PowerShell).
# Every problem the doctor reports must print an ACTIONABLE fix line; the exit code is nonzero
# ONLY when at least one ERROR exists (overlap, or a corrupt/non-git repo). Behavior-identical
# to test_doctor.sh. The dispatcher runs in a CHILD pwsh via Invoke-DF (real exit code captured).
# Cases: L0.13, L0.14, L0.15, L0.16, L0.17, L0.18, L0.19, L5.6, L5.24, L5.25, L5.26.
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. "$here/harness.ps1"
$global:Dispatcher = Join-Path $repo 'dotfiles.ps1'

# Wire a repo's core.hooksPath to the engine's real githooks dir (so hooks read as "wired").
function Wire-Hooks($name) { git --git-dir="$(Bare-Dir $name)" config core.hooksPath "$repo/githooks" }

New-Env

# ---------------------------------------------------------------------------
# L0.13 clean disjoint repos, hooks wired, upstream set, tick on -> all checks passed, exit 0.
T-Start L0.13 GOOD
Mk-RepoWithOrigin nvim main
Mk-RepoWithOrigin machine main
Wire-Hooks nvim
Wire-Hooks machine
git config -f (Join-Path $env:DOTFILES_ROOT 'config') nvim.tick on
git config -f (Join-Path $env:DOTFILES_ROOT 'config') machine.tick on
Invoke-DF -doctor
Assert-Rc L0.13 $global:LastRc 0
Assert-Contains L0.13 $global:LastOut 'all checks passed'
Assert-Contains L0.13 $global:LastOut 'no overlaps'
Assert-Contains L0.13 $global:LastOut 'hooks:wired'
Assert-NotContains L0.13 $global:LastOut 'error(s)'   # clean -> no error summary line

# ---------------------------------------------------------------------------
# L0.14 two repos tracking ONE path -> ERROR + the path + `rm --cached` fix + nonzero exit.
T-Start L0.14 BAD
New-Env
Mk-RepoWithOrigin nvim main
Mk-RepoWithOrigin machine main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/shared.cfg') -Value "shared`n" -NoNewline
git --git-dir="$(Bare-Dir nvim)"    --work-tree="$env:HOME" add -- .config/shared.cfg
git --git-dir="$(Bare-Dir nvim)"    --work-tree="$env:HOME" commit -q -m "nvim: shared"
git --git-dir="$(Bare-Dir machine)" --work-tree="$env:HOME" add -- .config/shared.cfg
git --git-dir="$(Bare-Dir machine)" --work-tree="$env:HOME" commit -q -m "machine: shared"
Invoke-DF -doctor
Assert-Rc L0.14 $global:LastRc 1
Assert-Contains L0.14 $global:LastOut 'OVERLAP'
Assert-Contains L0.14 $global:LastOut '.config/shared.cfg'
Assert-Contains L0.14 $global:LastOut 'tracked by: machine, nvim'
Assert-Contains L0.14 $global:LastOut 'rm --cached .config/shared.cfg'
Assert-Contains L0.14 $global:LastOut 'error(s)'

# ---------------------------------------------------------------------------
# L0.15 repo with no upstream -> warning + `push -u` fix; not an error (exit 0).
T-Start L0.15 BAD
New-Env
$gd = Bare-Dir noups
git init --bare -q $gd
git --git-dir="$gd" --work-tree="$env:HOME" symbolic-ref HEAD refs/heads/main
New-Item -ItemType Directory -Force -Path (Join-Path $env:HOME '.config/noups') | Out-Null
Set-Content -LiteralPath (Join-Path $env:HOME '.config/noups/seed') -Value "seed`n" -NoNewline
git --git-dir="$gd" --work-tree="$env:HOME" add -- .config/noups/seed
git --git-dir="$gd" --work-tree="$env:HOME" commit -q -m "noups: seed"
Invoke-DF -doctor
Assert-Rc L0.15 $global:LastRc 0
Assert-Contains L0.15 $global:LastOut 'upstream (none)'
Assert-Contains L0.15 $global:LastOut "no upstream for 'main'"
Assert-Contains L0.15 $global:LastOut 'push -u origin main'

# ---------------------------------------------------------------------------
# L0.16 detached HEAD -> warning + checkout fix; exit 0.
T-Start L0.16 BAD
New-Env
Mk-RepoWithOrigin det main
$sha = (git --git-dir="$(Bare-Dir det)" rev-parse HEAD | Out-String).Trim()
git --git-dir="$(Bare-Dir det)" --work-tree="$env:HOME" checkout -q --detach $sha
Invoke-DF -doctor
Assert-Rc L0.16 $global:LastRc 0
Assert-Contains L0.16 $global:LastOut 'branch detached'
Assert-Contains L0.16 $global:LastOut 'detached HEAD (no branch)'
Assert-Contains L0.16 $global:LastOut 'checkout <branch>'

# ---------------------------------------------------------------------------
# L0.17 core.hooksPath unset -> warning + config fix; hooks:MISSING; exit 0.
T-Start L0.17 BAD
New-Env
Mk-RepoWithOrigin nohooks main
Invoke-DF -doctor
Assert-Rc L0.17 $global:LastRc 0
Assert-Contains L0.17 $global:LastOut 'hooks:MISSING'
Assert-Contains L0.17 $global:LastOut 'core.hooksPath not set'
Assert-Contains L0.17 $global:LastOut 'config core.hooksPath'

# ---------------------------------------------------------------------------
# L0.18 tick OFF -> INFO line (not a warning/error); exit 0.
T-Start L0.18 GOOD
New-Env
Mk-RepoWithOrigin parked main
Wire-Hooks parked
Invoke-DF -doctor
Assert-Rc L0.18 $global:LastRc 0
Assert-Contains L0.18 $global:LastOut 'tick:off'
Assert-Contains L0.18 $global:LastOut "tick is OFF (won't sync)"
Assert-Contains L0.18 $global:LastOut 'info -> dotfiles -config parked.tick on'

# ---------------------------------------------------------------------------
# L0.19 engine behind its upstream -> suggests `--update`. Build a fake engine repo one commit
# behind its origin; point DOTFILES_COMMON at it for this test only (via the child's env).
T-Start L0.19 BAD
New-Env
$eng = Join-Path $global:WORK 'fakeengine'
$eorigin = Join-Path $global:WORK 'fakeengine_origin.git'
git init -q $eng
Set-Content -LiteralPath (Join-Path $eng 'f') -Value "v1`n" -NoNewline
git -C $eng add f; git -C $eng commit -q -m "v1"
git init --bare -q $eorigin
git -C $eng remote add origin $eorigin
git -C $eng push -q -u origin HEAD:refs/heads/main 2>$null | Out-Null
git -C $eng branch --set-upstream-to=origin/main 2>$null | Out-Null
Set-Content -LiteralPath (Join-Path $eng 'f') -Value "v2`n" -NoNewline
git -C $eng add f; git -C $eng commit -q -m "v2"
git -C $eng push -q origin HEAD:refs/heads/main 2>$null | Out-Null
git -C $eng reset -q --hard HEAD~1
$env:DOTFILES_COMMON = $eng
Invoke-DF -doctor
$env:DOTFILES_COMMON = $null
Assert-Rc L0.19 $global:LastRc 0
Assert-Contains L0.19 $global:LastOut 'behind'
Assert-Contains L0.19 $global:LastOut 'dotfiles --update'

# ---------------------------------------------------------------------------
# L5.6 core.hooksPath set but its target dir is MISSING -> flagged with a fix; hooks:MISSING.
T-Start L5.6 BAD
New-Env
Mk-RepoWithOrigin h6 main
git --git-dir="$(Bare-Dir h6)" config core.hooksPath (Join-Path $global:WORK 'does/not/exist')
Invoke-DF -doctor
Assert-Rc L5.6 $global:LastRc 0
Assert-Contains L5.6 $global:LastOut 'hooks:MISSING'
Assert-Contains L5.6 $global:LastOut 'but that dir is missing'

# ---------------------------------------------------------------------------
# L5.24 tick ON but hooksPath unset -> a louder warning (auto-commits run no hooks).
T-Start L5.24 BAD
New-Env
Mk-RepoWithOrigin t24 main
git config -f (Join-Path $env:DOTFILES_ROOT 'config') t24.tick on
Invoke-DF -doctor
Assert-Rc L5.24 $global:LastRc 0
Assert-Contains L5.24 $global:LastOut 'tick:on'
Assert-Contains L5.24 $global:LastOut 'hooks:MISSING'
Assert-Contains L5.24 $global:LastOut 'tick is ON but core.hooksPath is unset'

# ---------------------------------------------------------------------------
# L5.25 partial migration: git-dir relocated but core.hooksPath still points at the OLD path
# that no longer exists -> doctor detects it and prints the remaining step (current engine dir).
T-Start L5.25 BAD
New-Env
Mk-RepoWithOrigin t25 main
git --git-dir="$(Bare-Dir t25)" config core.hooksPath (Join-Path $env:HOME '.dotfiles-OLD/githooks')
Invoke-DF -doctor
Assert-Rc L5.25 $global:LastRc 0
Assert-Contains L5.25 $global:LastOut 'but that dir is missing'
Assert-Contains L5.25 $global:LastOut 'githooks"'

# ---------------------------------------------------------------------------
# L5.26 engine dir exists but is NOT a git repo -> ERROR (`--update` would fail); doctor notes it.
T-Start L5.26 BAD
New-Env
Mk-RepoWithOrigin r26 main
Wire-Hooks r26
git config -f (Join-Path $env:DOTFILES_ROOT 'config') r26.tick on
$notgit = Join-Path $global:WORK 'notengine'
New-Item -ItemType Directory -Force -Path $notgit | Out-Null
$env:DOTFILES_COMMON = $notgit
Invoke-DF -doctor
$env:DOTFILES_COMMON = $null
Assert-Rc L5.26 $global:LastRc 1
Assert-Contains L5.26 $global:LastOut 'NOT a git repo'
Assert-Contains L5.26 $global:LastOut 'dotfiles --update would fail'

T-Summary
