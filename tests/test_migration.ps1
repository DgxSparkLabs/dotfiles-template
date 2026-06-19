# Node 10 — migration + bootstrap (PowerShell). Mirror of test_migration.sh. GOOD/BAD banners.
#
# L1.14  — legacy single-repo layout -> migrate.ps1 -> bare-repos/machine valid; work-tree files
#          byte-identical; old top-level metadata gone; `dotfiles machine status` clean; a hook
#          fires; `-ls` shows machine.
# L5.25  — partial migration (git-dir moved, core.hooksPath unset) -> -doctor reports hooks:MISSING
#          + the remaining step.
# Bootstrap — idempotent profile append (twice != duplicate) + expected layout from empty using
#          LOCAL bare origins (no network).
# Fake HOME + fake DOTFILES_ROOT via New-Env — NEVER touches the real ~/.dotfiles or $PROFILE.

$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. (Join-Path $here 'harness.ps1')
$global:Dispatcher = Join-Path $repo 'dotfiles.ps1'
$global:RepoUnderTest = $repo

function Is-GitDir2($dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return $false }
  git --git-dir="$dir" rev-parse --git-dir 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

# Build a LEGACY single-repo layout: a BARE git-dir directly at $env:DOTFILES_ROOT tracking a
# couple of $HOME work-tree files, with a (now-bogus) core.hooksPath. NB: never track a file
# named .gitconfig (git would read it as global config under --work-tree=$HOME).
function Mk-LegacyLayout {
  $gd = $env:DOTFILES_ROOT
  Remove-Item -LiteralPath (Join-Path $gd 'bare-repos') -Recurse -Force -ErrorAction SilentlyContinue
  git init --bare -q $gd
  git --git-dir="$gd" --work-tree="$env:HOME" symbolic-ref HEAD refs/heads/main
  git --git-dir="$gd" config user.email "t@example.test"
  git --git-dir="$gd" config user.name  "t"
  git --git-dir="$gd" config core.hooksPath (Join-Path (Join-Path $gd '.dotfiles') 'githooks')
  New-Item -ItemType Directory -Force -Path (Join-Path $env:HOME '.config/app') | Out-Null
  Set-Content -LiteralPath (Join-Path $env:HOME '.bashrc.tracked') -Value "profile line`n" -NoNewline
  Set-Content -LiteralPath (Join-Path $env:HOME '.config/app/conf') -Value "app config v1`n" -NoNewline
  git --git-dir="$gd" --work-tree="$env:HOME" add -- .bashrc.tracked .config/app/conf
  git --git-dir="$gd" --work-tree="$env:HOME" commit -q -m "legacy: track machine config"
}

# ===========================================================================================
# L1.14 — full migration of a legacy single-repo layout.
T-Start L1.14 GOOD
New-Env
Mk-LegacyLayout
$gcBefore  = Get-Content -Raw -LiteralPath (Join-Path $env:HOME '.bashrc.tracked')
$appBefore = Get-Content -Raw -LiteralPath (Join-Path $env:HOME '.config/app/conf')
# Engine = THIS checkout, copied to common/ so migrate.ps1 skips the network clone.
$common = Join-Path $env:DOTFILES_ROOT 'common'
Copy-Item -Path $repo -Destination $common -Recurse -Force

$env:DOTFILES_COMMON = $common
$env:DOTFILES_PROFILE = Join-Path $env:HOME 'profile.ps1'
& pwsh -NoProfile -File (Join-Path $repo 'migrate.ps1') *> $null
$mrc = $LASTEXITCODE
Assert-Rc L1.14-rc $mrc 0

$machineGd = Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') 'machine'
if (Is-GitDir2 $machineGd) { T-Pass } else { T-Fail "L1.14: bare-repos/machine is not a valid git-dir" }

Assert-Eq L1.14-bashrc  (Get-Content -Raw -LiteralPath (Join-Path $env:HOME '.bashrc.tracked')) $gcBefore
Assert-Eq L1.14-appconf (Get-Content -Raw -LiteralPath (Join-Path $env:HOME '.config/app/conf')) $appBefore

# Old top-level git metadata gone.
if ((Test-Path -LiteralPath (Join-Path $env:DOTFILES_ROOT 'HEAD')) -or
    (Test-Path -LiteralPath (Join-Path $env:DOTFILES_ROOT 'objects'))) {
  T-Fail "L1.14: legacy git metadata still present at root"
} else { T-Pass }

# `dotfiles machine status` clean (stdout only; uv/hook chatter is on stderr).
$st = (git --git-dir="$machineGd" --work-tree="$env:HOME" status --porcelain 2>$null | Out-String).Trim()
Assert-Eq L1.14-clean $st ''

Invoke-DF -ls
Assert-Contains L1.14-ls $global:LastOut 'machine'

# core.hooksPath re-homed to the engine githooks (normalize slashes; Windows git stores '\').
$hp = ((git --git-dir="$machineGd" config --get core.hooksPath 2>$null | Out-String).Trim() -replace '\\', '/')
Assert-Contains L1.14-hookspath $hp 'common/githooks'

# A hook fires for the migrated repo (a _shared pre-commit marker).
$env:DF_MARK = Join-Path $global:WORK 'hookfired.marker'
Write-Hook _shared pre-commit "printf fired > `"$($env:DF_MARK)`""
Add-Content -LiteralPath (Join-Path $env:HOME '.config/app/conf') -Value "new line"
git --git-dir="$machineGd" --work-tree="$env:HOME" add -- .config/app/conf 2>$null | Out-Null
git -C "$env:HOME" --git-dir="$machineGd" --work-tree="$env:HOME" commit -q -m "post-migrate edit" 2>$null | Out-Null
if (Test-Path -LiteralPath $env:DF_MARK) { T-Pass } else { T-Fail "L1.14: per-repo hook did not fire on the migrated repo" }
Remove-Item Env:\DF_MARK -ErrorAction SilentlyContinue

# ===========================================================================================
# L1.14b — migrate is idempotent / re-runnable (second run safe no-op, rc 0).
T-Start L1.14b GOOD
& pwsh -NoProfile -File (Join-Path $repo 'migrate.ps1') *> $null
Assert-Rc L1.14b $LASTEXITCODE 0
Invoke-DF -ls
Assert-Contains L1.14b-ls $global:LastOut 'machine'

# ===========================================================================================
# L1.14c — abort on NO legacy layout AND no machine repo (clear message, nonzero).
T-Start L1.14c BAD
New-Env
Remove-Item -LiteralPath (Join-Path $env:DOTFILES_ROOT 'bare-repos') -Recurse -Force -ErrorAction SilentlyContinue
$env:DOTFILES_COMMON = $null
$errf = Join-Path $global:WORK 'migerr.txt'
& pwsh -NoProfile -File (Join-Path $repo 'migrate.ps1') 2> $errf > $null
$rc = $LASTEXITCODE
$err = (Get-Content -Raw -ErrorAction SilentlyContinue $errf); if ($null -eq $err) { $err = '' }
Assert-Rc L1.14c $rc 1
Assert-Contains L1.14c $err 'no legacy layout'

# ===========================================================================================
# L5.25 — partial migration: git-dir moved but core.hooksPath unset -> -doctor reports
# hooks:MISSING + the remaining step.
T-Start L5.25 BAD
New-Env
$gd = Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') 'machine'
git init --bare -q $gd
git --git-dir="$gd" --work-tree="$env:HOME" symbolic-ref HEAD refs/heads/main
git --git-dir="$gd" config user.email "t@example.test"
git --git-dir="$gd" config user.name  "t"
Set-Content -LiteralPath (Join-Path $env:HOME '.bashrc.tracked') -Value "cfg`n" -NoNewline
git --git-dir="$gd" --work-tree="$env:HOME" add -- .bashrc.tracked
git --git-dir="$gd" --work-tree="$env:HOME" commit -q -m "machine: seed"
$env:DOTFILES_COMMON = $repo
Invoke-DF -doctor
$env:DOTFILES_COMMON = $null
Assert-Contains L5.25-hooks  $global:LastOut 'hooks:MISSING'
Assert-Contains L5.25-fix    $global:LastOut 'core.hooksPath not set'
Assert-Contains L5.25-fixcmd $global:LastOut 'config core.hooksPath'
Assert-Rc       L5.25-rc     $global:LastRc 0

# ===========================================================================================
# Bootstrap — idempotent profile append: appending twice does NOT duplicate the source line.
T-Start BOOT-idempotent GOOD
New-Env
$origins = Join-Path $global:WORK 'origins'
New-Item -ItemType Directory -Force -Path $origins | Out-Null
$engineOrigin = Join-Path $origins 'engine.git'
git clone -q --bare (Join-Path $repo '.git') $engineOrigin 2>$null
if (-not (Test-Path -LiteralPath $engineOrigin)) {
  T-Skip 'could not create local engine origin from repo .git'
} else {
  $machineOrigin = Join-Path $origins 'machine.git'
  git init --bare -q $machineOrigin
  $seedwt = Join-Path $global:WORK 'seedwt'
  New-Item -ItemType Directory -Force -Path $seedwt | Out-Null
  git -C "$seedwt" init -q
  git -C "$seedwt" config user.email t@example.test; git -C "$seedwt" config user.name t
  Set-Content -LiteralPath (Join-Path $seedwt '.bashrc.tracked') -Value "machine gitconfig`n" -NoNewline
  git -C "$seedwt" add .bashrc.tracked; git -C "$seedwt" commit -q -m seed
  git -C "$seedwt" branch -M main
  git -C "$seedwt" push -q $machineOrigin main

  $profilePath = Join-Path $env:HOME 'profile.ps1'
  Set-Content -LiteralPath $profilePath -Value '' -NoNewline
  $env:DOTFILES_PROFILE = $profilePath
  $env:DOTFILES_ENGINE_URL = $engineOrigin
  $env:DOTFILES_MACHINE_URL = $machineOrigin
  $env:DOTFILES_MACHINE_BRANCH = 'main'
  $env:DOTFILES_COMMON = $null
  & pwsh -NoProfile -File (Join-Path $repo 'bootstrap.ps1') *> $null
  $brc1 = $LASTEXITCODE
  & pwsh -NoProfile -File (Join-Path $repo 'bootstrap.ps1') *> $null
  $brc2 = $LASTEXITCODE
  Assert-Rc BOOT-rc1 $brc1 0
  Assert-Rc BOOT-rc2 $brc2 0
  $cnt = @(Get-Content -LiteralPath $profilePath | Where-Object { $_ -like '*.dotfiles\common\dotfiles.ps1*' }).Count
  Assert-Eq BOOT-profile-once $cnt 1
  if (Test-Path -LiteralPath (Join-Path (Join-Path $env:DOTFILES_ROOT 'common') 'dotfiles.ps1')) { T-Pass } else { T-Fail "BOOT: engine common/ missing" }
  $mgd = Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') 'machine'
  if (Is-GitDir2 $mgd) { T-Pass } else { T-Fail "BOOT: machine repo not a valid git-dir" }
  $wt = Get-Content -Raw -LiteralPath (Join-Path $env:HOME '.bashrc.tracked') -ErrorAction SilentlyContinue
  Assert-Contains BOOT-worktree $wt 'machine gitconfig'
  $env:DOTFILES_ENGINE_URL = $null; $env:DOTFILES_MACHINE_URL = $null; $env:DOTFILES_MACHINE_BRANCH = $null
}

T-Summary
