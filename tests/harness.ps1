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
