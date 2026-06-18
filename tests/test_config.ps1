# Node 3 per-repo config + safe defaults (PowerShell): L0.8-L0.12, L5.8-L5.12.
# Reader assertions run __df_setting_* in a CHILD pwsh so warnings written to real process
# stderr ([Console]::Error.WriteLine) are captured via `2> file` (the in-session error stream
# would NOT catch them — see PITFALLS).
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. "$here/harness.ps1"
$global:Dispatcher = Join-Path $repo 'dotfiles.ps1'

New-Env
Mk-Repo nvim
$CFG = Join-Path $env:DOTFILES_ROOT 'config'

# Call a reader function in a child pwsh; sets $global:RVal (stdout) + $global:RErr (stderr).
function Read-Setting {
  param([Parameter(Mandatory)][string] $Call)
  $errf = Join-Path $global:WORK ("rerr_" + [guid]::NewGuid().ToString('N'))
  $script = ". `"$global:Dispatcher`"; $Call"
  $out = & pwsh -NoProfile -Command $script 2> $errf
  $global:RVal = ($out | Out-String).Trim()
  $global:RErr = (Get-Content -Raw -ErrorAction SilentlyContinue $errf)
  if ($null -eq $global:RErr) { $global:RErr = '' }
}

# L0.8 tick default OFF — empty config -> false, no warning.
T-Start L0.8 GOOD
Set-Content -LiteralPath $CFG -Value '' -NoNewline
Read-Setting '__df_setting_tick nvim'
Assert-Eq L0.8 $global:RVal 'false'
Assert-Eq L0.8 $global:RErr.Trim() ''

# L0.9 tick on — set via `dotfiles -config nvim.tick on` -> true.
T-Start L0.9 GOOD
Invoke-DF -config nvim.tick on
Read-Setting '__df_setting_tick nvim'
Assert-Eq L0.9 $global:RVal 'true'

# L0.10 add default tracked — unset -> -u.
T-Start L0.10 GOOD
Set-Content -LiteralPath $CFG -Value '' -NoNewline
Read-Setting '__df_setting_add nvim'
Assert-Eq L0.10 $global:RVal '-u'

# L0.11 add=all -> -A.
T-Start L0.11 GOOD
Invoke-DF -config nvim.add all
Read-Setting '__df_setting_add nvim'
Assert-Eq L0.11 $global:RVal '-A'

# L0.12 -config writes to ~/.dotfiles/config, NOT into the bare repo's config.
T-Start L0.12 GOOD
Set-Content -LiteralPath $CFG -Value '' -NoNewline
Invoke-DF -config nvim.add all
Assert-Contains L0.12 (Get-Content -Raw $CFG) 'all'
$bare = Join-Path (Join-Path (Join-Path $env:DOTFILES_ROOT 'bare-repos') 'nvim') 'config'
$baretext = (Get-Content -Raw -ErrorAction SilentlyContinue $bare); if ($null -eq $baretext) { $baretext = '' }
Assert-NotContains L0.12 $baretext 'add = all'

# L5.8 malformed config -> default, no crash (child rc 0), warning present.
T-Start L5.8 BAD
Set-Content -LiteralPath $CFG -Value 'this is not ini'
Read-Setting '__df_setting_tick nvim; exit 0'
Assert-Eq L5.8 $global:RVal 'false'
Assert-Contains L5.8 $global:RErr 'malformed'

# L5.9 unknown key -> ignored, no error.
T-Start L5.9 GOOD
Set-Content -LiteralPath $CFG -Value '' -NoNewline
Invoke-DF -config nvim.frobnicate 1
Read-Setting '__df_setting_tick nvim'
Assert-Eq L5.9 $global:RVal 'false'
Assert-Eq L5.9 $global:RErr.Trim() ''

# L5.10 invalid value -> safe default + warning (tick + add).
T-Start L5.10 BAD
Set-Content -LiteralPath $CFG -Value '' -NoNewline
Invoke-DF -config nvim.tick maybe
Invoke-DF -config nvim.add sideways
Read-Setting '__df_setting_tick nvim'
Assert-Eq L5.10 $global:RVal 'false'
Assert-Contains L5.10 $global:RErr 'invalid bool'
Read-Setting '__df_setting_add nvim'
Assert-Eq L5.10 $global:RVal '-u'
Assert-Contains L5.10 $global:RErr 'invalid value'

# L5.11 duplicate keys -> deterministic last-wins, no crash.
T-Start L5.11 GOOD
Set-Content -LiteralPath $CFG -Value "[nvim]`n  tick = off`n  tick = on`n"
Read-Setting '__df_setting_tick nvim'
Assert-Eq L5.11 $global:RVal 'true'

# L5.12 [timer] interval=abc -> default 60 + warning.
T-Start L5.12 BAD
Set-Content -LiteralPath $CFG -Value "[timer]`n  interval = abc`n"
Read-Setting '__df_setting_timer_interval'
Assert-Eq L5.12 $global:RVal '60'
Assert-Contains L5.12 $global:RErr 'invalid timer.interval'

T-Summary
