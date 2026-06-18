# Node 2 dispatcher tests (PowerShell): L0.1-L0.7, L1.12-L1.13, L5.13.
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. "$here/harness.ps1"
$global:Dispatcher = Join-Path $repo 'dotfiles.ps1'

New-Env
Mk-Repo machine
Mk-Repo nvim
Mk-Repo show               # a repo deliberately named like a management verb

# L0.1 passthrough routing
T-Start L0.1 GOOD
Invoke-DF machine rev-parse --absolute-git-dir
Assert-Contains L0.1 $global:LastOut "bare-repos/machine"

# L0.2 -ls == --ls
T-Start L0.2 GOOD
Invoke-DF -ls;  $a = ($global:LastOut -split "`n" | Sort-Object) -join "`n"
Invoke-DF --ls; $b = ($global:LastOut -split "`n" | Sort-Object) -join "`n"
Assert-Eq L0.2 $a $b

# L0.3 every verb dispatches — none reported "unknown"
T-Start L0.3 GOOD
$all = ''
foreach ($v in 'ls','config','tick','doctor','show','resolve','help') {
  Invoke-DF "--$v";  $all += $global:LastOut + $global:LastErr
  Invoke-DF "-$v";   $all += $global:LastOut + $global:LastErr
}
Assert-NotContains L0.3 $all "unknown command"

# L0.4 unknown verb -> exit 2 + message
T-Start L0.4 BAD
Invoke-DF -bogus
Assert-Rc L0.4 $global:LastRc 2
Assert-Contains L0.4 $global:LastErr "unknown command"

# L0.5 no such repo -> exit 1 + message
T-Start L0.5 BAD
Invoke-DF ghost rev-parse
Assert-Rc L0.5 $global:LastRc 1
Assert-Contains L0.5 $global:LastErr "no such repo"

# L0.6 repo named like a verb still routes to the repo
T-Start L0.6 GOOD
Invoke-DF show rev-parse --absolute-git-dir
Assert-Contains L0.6 $global:LastOut "bare-repos/show"

# L0.7 empty args == -ls
T-Start L0.7 GOOD
Invoke-DF;     $e = ($global:LastOut -split "`n" | Sort-Object) -join "`n"
Invoke-DF -ls; $l = ($global:LastOut -split "`n" | Sort-Object) -join "`n"
Assert-Eq L0.7 $e $l

# L1.12 discovery add
T-Start L1.12 GOOD
Mk-Repo addedlater
Invoke-DF -ls
Assert-Contains L1.12 $global:LastOut "addedlater"

# L1.13 discovery remove
T-Start L1.13 GOOD
Remove-Item -Recurse -Force (Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') 'addedlater')
Invoke-DF -ls
Assert-NotContains L1.13 $global:LastOut "addedlater"

# L5.13 non-git dir under bare-repos/ is skipped
T-Start L5.13 BAD
New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') 'junkdir') | Out-Null
Invoke-DF -ls
Assert-NotContains L5.13 $global:LastOut "junkdir"

T-Summary
