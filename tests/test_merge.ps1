# Node 5 never-block reconcile + surfaced resolution (PowerShell): L2.2-L2.13.
# Two/three machines share ONE fake origin; ticks reconcile divergence WITHOUT blocking,
# surface true clashes (newest committer-date wins, loser pinned + logged), keep loser state
# LOCAL. Commit dates are pinned ($env:GIT_*_DATE) for deterministic newest-wins. The tick runs
# in a CHILD pwsh via Invoke-DF (HOME isolated, real exit code captured).
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. "$here/harness.ps1"
$global:Dispatcher = Join-Path $repo 'dotfiles.ps1'

$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.test'
$env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.test'
function Pin($d) { $env:GIT_AUTHOR_DATE = $d; $env:GIT_COMMITTER_DATE = $d }

# Commit a file directly into a machine's repo (helper for seeding shared bases / advancing peers).
function Repo-Commit($n, $repo, $rel, $msg) {
  $gd = MGd $n $repo
  git --git-dir="$gd" --work-tree="$(MHome $n)" add -- $rel 2>$null | Out-Null
  git --git-dir="$gd" --work-tree="$(MHome $n)" commit -q -m $msg 2>$null | Out-Null
}

# ===========================================================================
# L2.2 same file, DIFFERENT lines -> auto-merge; BOTH edits survive, no markers.
T-Start L2.2 GOOD
New-Env; Reg-Machine1
Mk-RepoWithOrigin doc main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/doc/file') -Value "l1`nl2`nl3`nl4`nl5`n" -NoNewline
$gd1 = MGd 1 doc
git --git-dir="$gd1" --work-tree="$env:HOME" add -- .config/doc/file 2>$null | Out-Null
git --git-dir="$gd1" --work-tree="$env:HOME" commit -q -m 'doc: base' 2>$null | Out-Null
git --git-dir="$gd1" --work-tree="$env:HOME" push -q origin main 2>$null | Out-Null
Mk-Machine 2 doc main
# M1 edits line1; M2 edits line5 (disjoint lines).
Set-Content -LiteralPath (Join-Path (MHome 1) '.config/doc/file') -Value "M1L1`nl2`nl3`nl4`nl5`n" -NoNewline
Pin '2021-01-01T00:00:00'; Tick-Machine1 doc
Write-Machine 2 .config/doc/file "l1`nl2`nl3`nl4`nM2L5`n"
Pin '2021-02-01T00:00:00'; Tick-Machine 2 doc
Pull-Machine 1 doc main
$merged = Read-Machine 1 .config/doc/file
Assert-Contains    L2.2 $merged 'M1L1'
Assert-Contains    L2.2 $merged 'M2L5'
Assert-NotContains L2.2 $merged '<<<<<<<'

# ===========================================================================
# L2.3 same LINE clash -> never blocks; newest committer-date wins; loser ref exists.
T-Start L2.3 BAD
New-Env; Reg-Machine1
Mk-RepoWithOrigin clash main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/clash/file') -Value "top`nMID`nbot`n" -NoNewline
$gd1 = MGd 1 clash
git --git-dir="$gd1" --work-tree="$env:HOME" add -- .config/clash/file 2>$null | Out-Null
git --git-dir="$gd1" --work-tree="$env:HOME" commit -q -m base 2>$null | Out-Null
git --git-dir="$gd1" --work-tree="$env:HOME" push -q origin main 2>$null | Out-Null
Mk-Machine 2 clash main
Set-Content -LiteralPath (Join-Path (MHome 1) '.config/clash/file') -Value "top`nX`nbot`n" -NoNewline
Pin '2020-01-01T00:00:00'; Tick-Machine1 clash
Write-Machine 2 .config/clash/file "top`nY`nbot`n"
Pin '2022-01-01T00:00:00'; Tick-Machine 2 clash
Assert-Rc L2.3 $global:LastRc 0                     # never blocks
$m2gd = MGd 2 clash
$won = Read-Machine 2 .config/clash/file
Assert-Contains    L2.3 $won 'Y'                    # newest wins
Assert-NotContains L2.3 $won '<<<<<<<'
$loserRef = (git --git-dir="$m2gd" for-each-ref --format='%(refname)' refs/sync-losers 2>$null | Select-Object -First 1)
if ($loserRef) { T-Pass } else { T-Fail 'L2.3 no loser ref pinned' }

# ===========================================================================
# L2.4 loser PINNED: the ref resolves to the X (losing) commit; its blob held X.
T-Start L2.4 GOOD
git --git-dir="$m2gd" rev-parse --verify -q $loserRef 2>$null | Out-Null
Assert-Rc L2.4 $LASTEXITCODE 0
$loserSha = (git --git-dir="$m2gd" rev-parse --verify $loserRef 2>$null | Out-String).Trim()
$loserBlob = (git --git-dir="$m2gd" ls-tree -r $loserSha -- .config/clash/file 2>$null | ForEach-Object { ($_ -split '\s+')[2] } | Select-Object -First 1)
Assert-Contains L2.4 ((git --git-dir="$m2gd" cat-file -p $loserBlob) | Out-String) 'X'

# ===========================================================================
# L2.5 clash LOGGED: state/<repo>/conflicts.log has path+winner+loser.
T-Start L2.5 GOOD
$logf = Join-Path (MRoot 2) 'state/clash/conflicts.log'
if ((Test-Path -LiteralPath $logf) -and ((Get-Item -LiteralPath $logf).Length -gt 0)) { T-Pass } else { T-Fail 'L2.5 conflicts.log missing/empty' }
$logtxt = (Get-Content -Raw -LiteralPath $logf -ErrorAction SilentlyContinue)
Assert-Contains L2.5 $logtxt '.config/clash/file'
Assert-Contains L2.5 $logtxt 'winner='
Assert-Contains L2.5 $logtxt 'loser='

# ===========================================================================
# L2.6 conflicts.log + loser refs are LOCAL ONLY: absent from origin tree & ls-files.
T-Start L2.6 GOOD
$otree = (git --git-dir="$(Origin-Dir clash)" ls-tree -r --name-only refs/heads/main 2>$null | Out-String)
Assert-NotContains L2.6 $otree 'conflicts.log'
Assert-NotContains L2.6 $otree 'sync-losers'
$tracked = (git --git-dir="$m2gd" --work-tree="$(MHome 2)" ls-files 2>$null | Out-String)
Assert-NotContains L2.6 $tracked 'conflicts.log'
$orefs = (git --git-dir="$(Origin-Dir clash)" for-each-ref --format='%(refname)' 2>$null | Out-String)
Assert-NotContains L2.6 $orefs 'sync-losers'

# ===========================================================================
# L2.7 modify/delete -> never blocks; edit-beats-delete (file retained); logged.
T-Start L2.7 BAD
New-Env; Reg-Machine1
Mk-RepoWithOrigin md main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/md/file') -Value "keepme`n" -NoNewline
$gd1 = MGd 1 md
git --git-dir="$gd1" --work-tree="$env:HOME" add -- .config/md/file 2>$null | Out-Null
git --git-dir="$gd1" --work-tree="$env:HOME" commit -q -m base 2>$null | Out-Null
git --git-dir="$gd1" --work-tree="$env:HOME" push -q origin main 2>$null | Out-Null
Mk-Machine 2 md main
Set-Content -LiteralPath (Join-Path (MHome 1) '.config/md/file') -Value "EDITED`n" -NoNewline
Pin '2021-01-01T00:00:00'; Tick-Machine1 md
git --git-dir="$(MGd 2 md)" --work-tree="$(MHome 2)" rm -q -- .config/md/file 2>$null | Out-Null
Pin '2022-01-01T00:00:00'; Tick-Machine 2 md
Assert-Rc L2.7 $global:LastRc 0
if (Test-Path -LiteralPath (Join-Path (MHome 2) '.config/md/file')) { T-Pass } else { T-Fail 'L2.7 edited file not retained' }
Assert-Contains L2.7 (Read-Machine 2 .config/md/file) 'EDITED'
Assert-Contains L2.7 (Get-Content -Raw -LiteralPath (Join-Path (MRoot 2) 'state/md/conflicts.log') -ErrorAction SilentlyContinue) '.config/md/file'

# ===========================================================================
# L2.8 commit-before-merge anti-clobber: an UNCOMMITTED local edit on M1 survives a tick even
# when origin has a (non-overlapping) change waiting. The local edit is committed FIRST.
T-Start L2.8 GOOD
New-Env; Reg-Machine1
Mk-RepoWithOrigin anti main
Mk-Machine 2 anti main
Write-Machine 2 .config/anti/remote 'from-m2'
git --git-dir="$(MGd 2 anti)" --work-tree="$(MHome 2)" add -- .config/anti/remote 2>$null | Out-Null
Pin '2021-01-01T00:00:00'; Tick-Machine 2 anti
Set-Content -LiteralPath (Join-Path (MHome 1) '.config/anti/seed') -Value "local-uncommitted-edit`n" -NoNewline
Pin '2021-06-01T00:00:00'; Tick-Machine1 anti
Assert-Rc L2.8 $global:LastRc 0
$hist = (git --git-dir="$(MGd 1 anti)" --work-tree="$(MHome 1)" log --all -p -- .config/anti/seed 2>$null | Out-String)
Assert-Contains L2.8 $hist 'local-uncommitted-edit'
Assert-Contains L2.8 (Get-Content -Raw -LiteralPath (Join-Path (MHome 1) '.config/anti/seed')) 'local-uncommitted-edit'
if (Test-Path -LiteralPath (Join-Path (MHome 1) '.config/anti/remote')) { T-Pass } else { T-Fail 'L2.8 remote change did not merge in' }

# ===========================================================================
# L2.9 push-reject then retry succeeds: a competing commit lands on origin before M1's push;
# the bounded retry re-reconciles and eventually pushes. Final origin has both files.
T-Start L2.9 BAD
New-Env; Reg-Machine1
Mk-RepoWithOrigin race main
Mk-Machine 2 race main
Write-Machine 2 .config/race/m2 'm2change'
git --git-dir="$(MGd 2 race)" --work-tree="$(MHome 2)" add -- .config/race/m2 2>$null | Out-Null
Pin '2021-01-01T00:00:00'; Tick-Machine 2 race
Set-Content -LiteralPath (Join-Path (MHome 1) '.config/race/seed') -Value "m1change`n" -NoNewline
Pin '2021-02-01T00:00:00'; Tick-Machine1 race
Assert-Rc L2.9 $global:LastRc 0
$otree = (git --git-dir="$(Origin-Dir race)" ls-tree -r --name-only refs/heads/main 2>$null | Out-String)
Assert-Contains L2.9 $otree '.config/race/m2'
Assert-Contains L2.9 $otree '.config/race/seed'

# ===========================================================================
# L2.10 push-reject EXHAUST -> tick logs + skips + does not block; work-tree intact; next tick
# recovers. A pre-push hook that exits nonzero rejects every attempt deterministically.
T-Start L2.10 BAD
New-Env; Reg-Machine1
Mk-RepoWithOrigin ex main
$gdEx = MGd 1 ex
New-Item -ItemType Directory -Force -Path (Join-Path $gdEx 'hooks') | Out-Null
# Force EVERY push to be rejected deterministically via a pre-push hook that exits nonzero. The
# hook MUST be (a) LF-only, (b) a POSIX shell (`#!/bin/sh`), and (c) EXECUTABLE on Linux/macOS —
# git silently SKIPS a non-executable hook there, so without the +x bit the push would succeed
# and this test would wrongly see rc=0 (the original L2.10 Linux failure). On Windows the bit is
# irrelevant (Git-for-Windows runs hooks via sh.exe), so chmod is a no-op/absent there.
$prePush = Join-Path $gdEx 'hooks/pre-push'
[System.IO.File]::WriteAllText($prePush, "#!/bin/sh`nexit 1`n")
if ($IsLinux -or $IsMacOS) { chmod +x $prePush }
Set-Content -LiteralPath (Join-Path (MHome 1) '.config/ex/seed') -Value "m1-exhaust`n" -NoNewline
Pin '2021-01-01T00:00:00'; Tick-Machine1 ex
# Tick returns nonzero (push skipped) but DID NOT block, and logged a reason on stderr.
if ($global:LastRc -ne 0) { T-Pass } else { T-Fail "L2.10 expected nonzero (push skipped), got $($global:LastRc)" }
Assert-Contains L2.10 $global:LastErr 'not completed this tick'
Assert-Contains L2.10 (Get-Content -Raw -LiteralPath (Join-Path (MHome 1) '.config/ex/seed')) 'm1-exhaust'
# Next tick recovers: remove the rejecting hook -> a normal tick pushes cleanly.
Remove-Item -LiteralPath (Join-Path $gdEx 'hooks/pre-push') -Force
Pin '2021-01-02T00:00:00'; Tick-Machine1 ex
Assert-Rc L2.10 $global:LastRc 0
Assert-Contains L2.10 (git --git-dir="$(Origin-Dir ex)" ls-tree -r --name-only refs/heads/main | Out-String) '.config/ex/seed'

# ===========================================================================
# L2.11 three machines converge to the same set of files (disjoint edits).
T-Start L2.11 GOOD
New-Env; Reg-Machine1
Mk-RepoWithOrigin tri main
Mk-Machine 2 tri main
Mk-Machine 3 tri main
Write-Machine 1 .config/tri/a 'AAA'
git --git-dir="$(MGd 1 tri)" --work-tree="$(MHome 1)" add -- .config/tri/a 2>$null | Out-Null
Pin '2021-01-01T00:00:00'; Tick-Machine1 tri
Write-Machine 2 .config/tri/b 'BBB'
git --git-dir="$(MGd 2 tri)" --work-tree="$(MHome 2)" add -- .config/tri/b 2>$null | Out-Null
Pin '2021-01-02T00:00:00'; Tick-Machine 2 tri
Write-Machine 3 .config/tri/c 'CCC'
git --git-dir="$(MGd 3 tri)" --work-tree="$(MHome 3)" add -- .config/tri/c 2>$null | Out-Null
Pin '2021-01-03T00:00:00'; Tick-Machine 3 tri
# Second round so everyone converges.
Pin '2021-01-04T00:00:00'; Tick-Machine1 tri
Pin '2021-01-05T00:00:00'; Tick-Machine 2 tri
Pin '2021-01-06T00:00:00'; Tick-Machine 3 tri
Pin '2021-01-07T00:00:00'; Tick-Machine1 tri
foreach ($m in 1, 2, 3) {
  $rev = if ($m -eq 1) { 'HEAD' } else { 'FETCH_HEAD' }
  if ($m -ne 1) { Pull-Machine $m tri main }
  $files = (git --git-dir="$(MGd $m tri)" ls-tree -r --name-only $rev 2>$null | Out-String)
  Assert-Contains L2.11 $files '.config/tri/a'
  Assert-Contains L2.11 $files '.config/tri/b'
  Assert-Contains L2.11 $files '.config/tri/c'
}

# ===========================================================================
# L2.12 -resolve writes <path>.loser with the losing content (run as machine 2; loser held X).
T-Start L2.12 GOOD
New-Env; Reg-Machine1
Mk-RepoWithOrigin rec main
Set-Content -LiteralPath (Join-Path $env:HOME '.config/rec/file') -Value "a`nMID`nb`n" -NoNewline
$gd1 = MGd 1 rec
git --git-dir="$gd1" --work-tree="$env:HOME" add -- .config/rec/file 2>$null | Out-Null
git --git-dir="$gd1" --work-tree="$env:HOME" commit -q -m base 2>$null | Out-Null
git --git-dir="$gd1" --work-tree="$env:HOME" push -q origin main 2>$null | Out-Null
Mk-Machine 2 rec main
Set-Content -LiteralPath (Join-Path (MHome 1) '.config/rec/file') -Value "a`nX`nb`n" -NoNewline
Pin '2020-01-01T00:00:00'; Tick-Machine1 rec
Write-Machine 2 .config/rec/file "a`nY`nb`n"
Pin '2022-01-01T00:00:00'; Tick-Machine 2 rec
# Resolve as machine 2 (where the loser was pinned).
$env:HOME = MHome 2; $env:DOTFILES_ROOT = MRoot 2
Invoke-DF -resolve .config/rec/file
Assert-Rc L2.12 $global:LastRc 0
Assert-Contains L2.12 $global:LastOut 'loser written to:'
$loserFile = Join-Path (MHome 2) '.config/rec/file.loser'
if (Test-Path -LiteralPath $loserFile) { T-Pass } else { T-Fail 'L2.12 .loser file not written' }
Assert-Contains L2.12 (Get-Content -Raw -LiteralPath $loserFile -ErrorAction SilentlyContinue) 'X'

# ===========================================================================
# L2.13 deterministic newest: SAME clash run twice with dates SWAPPED -> winner FLIPS.
T-Start L2.13 GOOD
function Run-Clash($m1date, $m2date) {
  New-Env; Reg-Machine1
  Mk-RepoWithOrigin det main
  Set-Content -LiteralPath (Join-Path $env:HOME '.config/det/file') -Value "a`nMID`nb`n" -NoNewline
  $g = MGd 1 det
  git --git-dir="$g" --work-tree="$env:HOME" add -- .config/det/file 2>$null | Out-Null
  git --git-dir="$g" --work-tree="$env:HOME" commit -q -m base 2>$null | Out-Null
  git --git-dir="$g" --work-tree="$env:HOME" push -q origin main 2>$null | Out-Null
  Mk-Machine 2 det main
  Set-Content -LiteralPath (Join-Path (MHome 1) '.config/det/file') -Value "a`nX`nb`n" -NoNewline
  Pin $m1date; Tick-Machine1 det
  Write-Machine 2 .config/det/file "a`nY`nb`n"
  Pin $m2date; Tick-Machine 2 det
  return (Read-Machine 2 .config/det/file)
}
$w1 = Run-Clash '2020-01-01T00:00:00' '2022-01-01T00:00:00'   # M2(Y) newer -> Y wins
$w2 = Run-Clash '2022-01-01T00:00:00' '2020-01-01T00:00:00'   # M1(X) newer -> X wins
Assert-Contains L2.13 $w1 'Y'
Assert-Contains L2.13 $w2 'X'
if ($w1 -ne $w2) { T-Pass } else { T-Fail 'L2.13 winner did not flip with swapped dates' }

T-Summary
