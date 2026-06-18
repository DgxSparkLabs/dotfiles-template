# Shared test harness (PowerShell): greppable PASS/FAIL/SKIP banners + assertions + fake env.
# Dot-source me from a test_*.ps1. Call T-Summary at the end (it exits nonzero on any failure).

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0; $script:Current = '?'

function T-Start($id, $kind = 'GOOD') { $script:Current = $id; Write-Output "=== $id $kind START ===" }
function T-Pass()  { $script:Pass++; Write-Output "=== $script:Current RESULT=PASS ===" }
function T-Fail($m){ $script:Fail++; Write-Output "=== $script:Current RESULT=FAIL ($m) ===" }
function T-Skip($m){ $script:Skip++; Write-Output "=== $script:Current RESULT=SKIP ($m) ===" }
function T-Summary {
  Write-Output "=== SUMMARY pass=$($script:Pass) fail=$($script:Fail) skip=$($script:Skip) ==="
  if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
}

function Assert-Eq($id, $a, $b)           { if ($a -ceq $b) { T-Pass } else { T-Fail "$id expected [$b] got [$a]" } }
function Assert-Contains($id, $s, $sub)    { if ($s -like "*$sub*") { T-Pass } else { T-Fail "$id [$s] lacks [$sub]" } }
function Assert-NotContains($id, $s, $sub) { if ($s -like "*$sub*") { T-Fail "$id [$s] unexpectedly has [$sub]" } else { T-Pass } }
function Assert-Rc($id, $rc, $exp)         { if ($rc -eq $exp) { T-Pass } else { T-Fail "$id expected rc $exp got $rc" } }

# Isolated fake environment.
function New-Env {
  $w = Join-Path ([System.IO.Path]::GetTempPath()) ("dft_" + [guid]::NewGuid().ToString('N'))
  $env:HOME = Join-Path $w 'home'
  $env:DOTFILES_ROOT = Join-Path $w 'dot'
  New-Item -ItemType Directory -Force -Path $env:HOME, (Join-Path $env:DOTFILES_ROOT 'bare-repos') | Out-Null
  git config --global user.email "t@example.test" 2>$null
  git config --global user.name  "t"               2>$null
  $global:WORK = $w
}
function Mk-Repo($n) { git init --bare -q (Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') $n) }

# Mk-RepoWithOrigin <name> [branch]
#   Build a repo wired to a fake "origin" bare repo on local disk, with an upstream-tracking
#   branch and one initial commit seeding a repo-OWNED file ($HOME/.config/<name>/seed).
#   Used by node 4 (tick) and node 5 (merge).
function Mk-RepoWithOrigin($name, $branch = 'main') {
  $origin = Join-Path (Join-Path $global:WORK 'origins') "$name.git"
  $gd = Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') $name
  $seed = ".config/$name/seed"
  New-Item -ItemType Directory -Force -Path (Join-Path $global:WORK 'origins') | Out-Null
  git init --bare -q $origin
  git init --bare -q $gd
  git --git-dir="$gd" --work-tree="$env:HOME" symbolic-ref HEAD "refs/heads/$branch"
  git --git-dir="$gd" remote add origin $origin
  New-Item -ItemType Directory -Force -Path (Join-Path $env:HOME ".config/$name") | Out-Null
  Set-Content -LiteralPath (Join-Path $env:HOME $seed) -Value "seed`n" -NoNewline
  git --git-dir="$gd" --work-tree="$env:HOME" add -- $seed
  git --git-dir="$gd" --work-tree="$env:HOME" commit -q -m "$name`: seed"
  git --git-dir="$gd" --work-tree="$env:HOME" push -q -u origin $branch 2>$null | Out-Null
}

function Origin-Dir($name) { Join-Path (Join-Path $global:WORK 'origins') "$name.git" }
function Origin-Tip($name, $rev = 'HEAD') {
  $o = Join-Path (Join-Path $global:WORK 'origins') "$name.git"
  (git --git-dir="$o" rev-parse $rev 2>$null | Out-String).Trim()
}

# --- Multi-machine helpers (node 5: bidirectional merge over a shared origin) ----------
# A "machine" = an isolated HOME + a bare repo cloned from the SAME origin, driven through the
# real dispatcher with that machine's HOME + DOTFILES_ROOT swapped in. Machine 1 == the env
# from New-Env + Mk-RepoWithOrigin (register it with Reg-Machine1). Machines N>=2 via Mk-Machine.
$global:MHome = @{}; $global:MRoot = @{}
function Reg-Machine1 { $global:MHome[1] = $env:HOME; $global:MRoot[1] = $env:DOTFILES_ROOT }
function MHome($n) { $global:MHome[[int]$n] }
function MRoot($n) { $global:MRoot[[int]$n] }

# Mk-Machine <n> <repo> [branch] — build machine N's HOME + repo the SAME way Mk-RepoWithOrigin
# builds machine 1 (init --bare + remote add installs the fetch refspec + fetch + checkout -B),
# so the repo has refs/remotes/origin/* and an @{upstream} for the tick to push to. A plain
# `git clone --bare` sets NO fetch refspec, so it would have no upstream.
function Mk-Machine($n, $repo, $branch = 'main') {
  $mhome = Join-Path (Join-Path $global:WORK "m$n") 'home'
  $mroot = Join-Path (Join-Path $global:WORK "m$n") 'dot'
  $gd = Join-Path (Join-Path $mroot 'bare-repos') $repo
  New-Item -ItemType Directory -Force -Path $mhome, (Join-Path $mroot 'bare-repos') | Out-Null
  if (-not (Test-Path -LiteralPath $gd)) {
    git init --bare -q $gd
    git --git-dir="$gd" --work-tree="$mhome" symbolic-ref HEAD "refs/heads/$branch"
    git --git-dir="$gd" remote add origin (Origin-Dir $repo)
    git --git-dir="$gd" fetch -q origin
    git --git-dir="$gd" --work-tree="$mhome" checkout -q -B $branch "origin/$branch"
  }
  $global:MHome[[int]$n] = $mhome; $global:MRoot[[int]$n] = $mroot
}

# Tick-Machine <n> <repo> — run the real dispatcher tick for one repo AS machine N (its
# HOME/ROOT swapped in for the child pwsh). Pin dates via $env:GIT_*_DATE before calling.
function Tick-Machine($n, $repo) {
  $savedHome = $env:HOME; $savedRoot = $env:DOTFILES_ROOT
  $env:HOME = MHome $n; $env:DOTFILES_ROOT = MRoot $n
  git config -f (Join-Path $env:DOTFILES_ROOT 'config') "$repo.tick" on
  Invoke-DF -tick $repo
  $env:HOME = $savedHome; $env:DOTFILES_ROOT = $savedRoot
}

# Tick-Machine1 <repo> — tick machine 1 (the New-Env env already in $env:HOME).
function Tick-Machine1($repo) {
  $env:HOME = MHome 1; $env:DOTFILES_ROOT = MRoot 1
  git config -f (Join-Path $env:DOTFILES_ROOT 'config') "$repo.tick" on
  Invoke-DF -tick $repo
}

function Write-Machine($n, $rel, $content) {
  $p = Join-Path (MHome $n) $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
  Set-Content -LiteralPath $p -Value $content -NoNewline
}
function Read-Machine($n, $rel) { Get-Content -Raw -LiteralPath (Join-Path (MHome $n) $rel) -ErrorAction SilentlyContinue }
function Pull-Machine($n, $repo, $branch = 'main') {
  $gd = Join-Path (Join-Path (MRoot $n) 'bare-repos') $repo
  git --git-dir="$gd" --work-tree="$(MHome $n)" fetch -q origin $branch
  git --git-dir="$gd" --work-tree="$(MHome $n)" reset -q --hard FETCH_HEAD
}
function MGd($n, $repo) { Join-Path (Join-Path (MRoot $n) 'bare-repos') $repo }

# --- Node 6 robustness helpers ---------------------------------------------------------
function Bare-Dir($name) { Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') $name }

# Corrupt an existing bare repo (remove HEAD + objects) so git errors on it; the tick must SKIP
# it (fail-isolation) and still tick the others.
function Corrupt-Repo($name) {
  $gd = Bare-Dir $name
  Remove-Item -LiteralPath (Join-Path $gd 'objects') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $gd 'HEAD') -Force -ErrorAction SilentlyContinue
}

# Place a NORMAL (non-bare) git repo under bare-repos/. It IS a git repo (so __df_is_repo passes)
# but has its own .git + work-tree; the tick must not treat it as a pure bare repo / corrupt $HOME.
function Mk-NonbareUnderRepos($name) {
  $dir = Bare-Dir $name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  git -C "$dir" init -q
  Set-Content -LiteralPath (Join-Path $dir 'file') -Value "inside`n" -NoNewline
  git -C "$dir" add file
  git -C "$dir" commit -q -m "nonbare seed"
}

# Simulate a crash mid-merge: leave a MERGE_HEAD (pointing at a real sha) so recovery must abort.
function Plant-StaleMerge($name) {
  $gd = Bare-Dir $name
  $head = (git --git-dir="$gd" rev-parse HEAD 2>$null | Out-String).Trim()
  Set-Content -LiteralPath (Join-Path $gd 'MERGE_HEAD') -Value "$head`n" -NoNewline
  Set-Content -LiteralPath (Join-Path $gd 'MERGE_MSG')  -Value "crashed merge`n" -NoNewline
}

# Drop an index.lock and backdate its mtime so it is unambiguously stale.
function Plant-StaleLock($name) {
  $gd = Bare-Dir $name
  $lock = Join-Path $gd 'index.lock'
  Set-Content -LiteralPath $lock -Value '' -NoNewline
  (Get-Item -LiteralPath $lock).LastWriteTime = (Get-Date).AddDays(-1)
}

# Create the tick-lock dir as if a LIVE tick holds it (fresh mtime) so a concurrent tick SKIPs.
function Plant-LiveLock($name) {
  $gd = Bare-Dir $name
  $ld = Join-Path $gd 'dotfiles-tick.lock'
  New-Item -ItemType Directory -Force -Path $ld | Out-Null
  Set-Content -LiteralPath (Join-Path $ld 'pid') -Value '999999' -NoNewline
}
function Has-TickLock($name) { Test-Path -LiteralPath (Join-Path (Bare-Dir $name) 'dotfiles-tick.lock') }

# --- Node 8 per-repo hook dispatch helpers --------------------------------------------
# $global:RepoUnderTest = the engine repo (this checkout); its real githooks/ is the shared
# stub set. Each test_*.ps1 sets it before using these.
#
# Wire-HooksPath <name> — point a bare repo's core.hooksPath at the engine's real githooks/.
function Wire-HooksPath($name) {
  git --git-dir="$(Bare-Dir $name)" config core.hooksPath "$global:RepoUnderTest/githooks"
}

# Write-Hook <repo|_shared> <hookname> <body> — install a per-repo (or _shared) hook script
# under $DOTFILES_ROOT/hooks/<scope>/<hookname>. POSIX sh, LF endings, +x on Linux/macOS (git
# silently skips a non-executable hook there). Body is the script AFTER the shebang; we prepend
# `#!/bin/sh`. Always write LF (no CRLF) so sh.exe / sh can run it.
function Write-Hook($scope, $hook, $body) {
  $dir = Join-Path (Join-Path $env:DOTFILES_ROOT 'hooks') $scope
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $path = Join-Path $dir $hook
  $text = "#!/bin/sh`n" + ($body -replace "`r`n", "`n") + "`n"
  [System.IO.File]::WriteAllText($path, $text)        # WriteAllText => no CRLF, no BOM
  if ($IsLinux -or $IsMacOS) { chmod +x $path }
}

# Mk-RepoHookable <name> [branch] — a bare repo with a work-tree HEAD + git identity +
# core.hooksPath wired to the engine stubs. No origin (hook tests don't push).
function Mk-RepoHookable($name, $branch = 'main') {
  $gd = Bare-Dir $name
  git init --bare -q $gd
  git --git-dir="$gd" --work-tree="$env:HOME" symbolic-ref HEAD "refs/heads/$branch"
  git --git-dir="$gd" config user.email "t@example.test"
  git --git-dir="$gd" config user.name  "t"
  Wire-HooksPath $name
}

# Commit-In <repo> <relpath> <content> — stage+commit a work-tree file through the bare repo,
# firing its hooks (core.hooksPath). Sets $global:LastRc to git's exit code (nonzero if a hook
# blocked it). Hooks inherit this process's env, so set any marker-path $env:* before calling.
function Commit-In($repo, $rel, $content) {
  $gd = Bare-Dir $repo
  $p = Join-Path $env:HOME $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
  Set-Content -LiteralPath $p -Value "$content`n" -NoNewline
  git --git-dir="$gd" --work-tree="$env:HOME" add -- $rel
  git -C "$env:HOME" --git-dir="$gd" --work-tree="$env:HOME" commit -q -m "edit $rel" 2>$null
  $global:LastRc = $LASTEXITCODE
}

# Tree-Names <repo> — newline-joined `git ls-tree -r --name-only HEAD` (empty if unborn).
function Tree-Names($repo) {
  (git --git-dir="$(Bare-Dir $repo)" ls-tree -r --name-only HEAD 2>$null | Out-String)
}

# Invoke the dispatcher in a CHILD pwsh (via _invoke.ps1, -File) so arg boundaries — including
# ZERO args — and real stderr + exit code are captured reliably.
# Sets $global:LastOut, $global:LastErr, $global:LastRc.
$global:InvokeScript = Join-Path (Split-Path -Parent $PSCommandPath) '_invoke.ps1'
function Invoke-DF {
  param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $DFArgs)
  $env:DOTFILES_DISPATCHER = $global:Dispatcher
  $errf = Join-Path $global:WORK ("err_" + [guid]::NewGuid().ToString('N'))
  if ($null -eq $DFArgs) { $DFArgs = @() }
  $out = & pwsh -NoProfile -File $global:InvokeScript @DFArgs 2> $errf
  $global:LastOut = ($out | Out-String)
  $global:LastErr = (Get-Content -Raw -ErrorAction SilentlyContinue $errf)
  if ($null -eq $global:LastErr) { $global:LastErr = '' }
  $global:LastRc = $LASTEXITCODE
}
