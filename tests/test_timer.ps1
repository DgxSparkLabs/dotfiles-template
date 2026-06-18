# test_timer.ps1 — node 9: the single timer fans out via `dotfiles -tick` + interval/jitter.
#
# CI constraint (plan "Known CI constraints & mitigations"): Task Scheduler registration needs an
# admin/interactive session and the non-admin VBS loop needs a logon session — neither is fully
# exercisable on a non-interactive CI runner. So we assert generated FILE CONTENT (the payload +
# loop + VBS launcher) and prove "a fire calls -tick" by calling `dotfiles -tick` DIRECTLY over
# enabled repos. Live Task-Scheduler transitions are RESULT=SKIP with a NAMED reason (no silent skip).

$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent $here
. "$here/harness.ps1"
$global:Dispatcher = Join-Path $repo 'dotfiles.ps1'
$TimerPs1 = Join-Path $repo 'timer/dotfiles-timer.ps1'

# Run the timer script with env pointing at the REAL engine (DOTFILES_COMMON = the checkout, so the
# dispatcher + readers exist) and the test's fake DOTFILES_ROOT (so payload/loop land there and the
# [timer] config is read from there). Returns combined output.
function Invoke-Timer {
  param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $TArgs)
  $savedC = $env:DOTFILES_COMMON
  $env:DOTFILES_COMMON = $repo
  try {
    & pwsh -NoProfile -File $TimerPs1 @TArgs *>&1 | Out-String
  } finally {
    $env:DOTFILES_COMMON = $savedC
  }
}

function Test-IsAdminPwsh {
  $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# DETERMINISTIC GATE for the LIVE Task-Scheduler asserts (L3.1 registered-task count, L3.14 reinstall
# count, L3.x enable->enabled / disable->Disabled). Run ONLY when the operator EXPLICITLY opts in via
# DOTFILES_TIMER_LIVE=1 (or =true) AND the session is actually admin. CI never sets the var, so CI
# always SKIPs the live transitions with a named reason — same deterministic opt-in as the bash leg
# (GH runners report a scheduler "usable" but cannot register a real user task non-interactively).
# The artifact-content + direct `dotfiles -tick` asserts ALWAYS run for real.
$global:LiveSkipReason = "live OS-scheduler registration asserts require DOTFILES_TIMER_LIVE=1 — real systemd/launchd/admin session; GH runners cannot register user units"
function Timer-Live {
  ($env:DOTFILES_TIMER_LIVE -in @('1','true','TRUE','True')) -and (Test-IsAdminPwsh)
}

function PayloadFile  { Join-Path $env:DOTFILES_ROOT '.dotfiles-tick.ps1' }
function LoopFile     { Join-Path $env:DOTFILES_ROOT '.dotfiles-tick-loop.ps1' }
function LauncherFile { "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\DotfilesAutoCommit.vbs" }

# ------------------------------------------------------------------------------------------------
# This whole suite is Windows-specific (Task Scheduler / VBS). On non-Windows the pwsh harness
# still runs but the backend doesn't apply -> SKIP loudly with a named reason.
if (-not $IsWindows) {
  T-Start L3.win SKIP
  T-Skip "Windows timer backend (Task Scheduler / VBS loop): not applicable on $([System.Environment]::OSVersion.Platform) pwsh leg"
  T-Summary
}

# ------------------------------------------------------------------------------------------------
# L3.4 / L3.11 — generated payload calls `dotfiles -tick`, jitter value baked in.
New-Env
$out = Invoke-Timer install
$pf = PayloadFile
T-Start L3.4-payload-tick GOOD
if (Test-Path -LiteralPath $pf) {
  $body = Get-Content -Raw -LiteralPath $pf
  Assert-Contains "L3.4 payload calls dotfiles -tick" $body 'dotfiles -tick'
} else {
  T-Fail "L3.4 payload not generated at $pf"
}

T-Start L3.11-jitter-artifact GOOD
if (Test-Path -LiteralPath $pf) {
  $body = Get-Content -Raw -LiteralPath $pf
  Assert-Contains "L3.11 jitter baked into payload" $body 'jitter = 15'
} else {
  T-Fail "L3.11 payload not generated at $pf"
}

# L3.11b — config interval/jitter respected in the generated artifacts.
New-Env
git config -f (Join-Path $env:DOTFILES_ROOT 'config') timer.interval 90 | Out-Null
git config -f (Join-Path $env:DOTFILES_ROOT 'config') timer.jitter 7    | Out-Null
$out = Invoke-Timer install
T-Start L3.11b-config-respected GOOD
$ok = $true
$pf = PayloadFile
if (Test-Path -LiteralPath $pf) {
  $pb = Get-Content -Raw -LiteralPath $pf
  if ($pb -notlike '*jitter = 7*') { $ok = $false }
} else { $ok = $false }
# Non-admin path writes the loop with the interval; admin path bakes it into the trigger only.
$lf = LoopFile
if (Test-Path -LiteralPath $lf) {
  $lb = Get-Content -Raw -LiteralPath $lf
  if ($lb -notmatch 'interval\s+=\s+90') { $ok = $false }
}
Assert-Eq "L3.11b interval+jitter in generated artifacts" $ok $true

# ------------------------------------------------------------------------------------------------
# L3.13 — Windows non-admin path generates the VBS launcher + loop script, windowless flag present.
# (Only meaningful when NOT admin; when the runner IS admin, the admin task path is taken instead.)
New-Env
$out = Invoke-Timer install
T-Start L3.13-nonadmin-vbs-loop GOOD
if (Test-IsAdminPwsh) {
  T-Skip "L3.13 non-admin VBS+loop: this runner session is elevated (admin Task Scheduler path taken)"
} else {
  $lf = LoopFile
  $vbs = LauncherFile
  $ok = $true
  if (-not (Test-Path -LiteralPath $lf))  { $ok = $false }
  if (-not (Test-Path -LiteralPath $vbs)) { $ok = $false }
  if ($ok) {
    $vbody = Get-Content -Raw -LiteralPath $vbs
    # WScript Run(..., 0, False) => windowless; -WindowStyle Hidden => belt-and-suspenders.
    if ($vbody -notlike '*", 0, False*')          { $ok = $false }
    if ($vbody -notlike '*-WindowStyle Hidden*')  { $ok = $false }
    $lbody = Get-Content -Raw -LiteralPath $lf
    if ($lbody -notlike '*$ScriptPath*' -and $lbody -notlike '*.dotfiles-tick.ps1*') { $ok = $false }
  }
  Assert-Eq "L3.13 VBS launcher + loop generated, windowless flag present" $ok $true
}

# ------------------------------------------------------------------------------------------------
# L3.1 / L3.14 — install creates exactly ONE task/launcher; reinstall stays idempotent (still one).
New-Env
if (Timer-Live) {
  $out = Invoke-Timer install
  T-Start L3.1-install-singleton GOOD
  $tasks = @(Get-ScheduledTask -TaskName 'dotfiles-git-commit' -ErrorAction SilentlyContinue)
  Assert-Eq "L3.1 exactly one registered task (live manager)" $tasks.Count 1

  $out = Invoke-Timer reinstall
  T-Start L3.14-reinstall-idempotent GOOD
  $tasks = @(Get-ScheduledTask -TaskName 'dotfiles-git-commit' -ErrorAction SilentlyContinue)
  Assert-Eq "L3.14 still exactly one task after reinstall (live manager)" $tasks.Count 1
} else {
  # Non-admin registry = file presence: exactly one VBS launcher + one loop + one payload.
  # GH windows runners run ELEVATED (admin), so force the USER backend via the test seam so the
  # user-mode artifacts (VBS launcher + loop + payload) are generated deterministically on ANY
  # windows runner — admin or not. Unset the var afterward. Live Task-Scheduler counts stay gated
  # behind DOTFILES_TIMER_LIVE (see the Timer-Live branch above).
  $env:DOTFILES_TIMER_FORCE_USER = '1'
  try {
    $out = Invoke-Timer install
    T-Start L3.1-install-singleton GOOD
    $n = 0
    if (Test-Path -LiteralPath (LauncherFile)) { $n++ }
    if (Test-Path -LiteralPath (LoopFile))     { $n++ }
    if (Test-Path -LiteralPath (PayloadFile))  { $n++ }
    Assert-Eq "L3.1 exactly one launcher+loop+payload generated (non-admin)" $n 3

    $out = Invoke-Timer reinstall
    T-Start L3.14-reinstall-idempotent GOOD
    $n = 0
    if (Test-Path -LiteralPath (LauncherFile)) { $n++ }
    if (Test-Path -LiteralPath (LoopFile))     { $n++ }
    if (Test-Path -LiteralPath (PayloadFile))  { $n++ }
    Assert-Eq "L3.14 still exactly one launcher+loop+payload after reinstall (non-admin)" $n 3
  } finally {
    # Clean up: uninstall (in forced-user mode) removes the Startup-folder VBS + scripts AND stops
    # any detached pwsh loop the install spawned, so nothing outlives the test. Then unset the seam.
    Invoke-Timer uninstall | Out-Null
    $env:DOTFILES_TIMER_FORCE_USER = $null
  }
}

# ------------------------------------------------------------------------------------------------
# L3.4(direct) / L3.9 — `dotfiles -tick` advances ALL enabled repos in ONE run; disabled repo does
# not. Fire-calls-tick proof via the dispatcher fan-out (the payload's `dotfiles -tick` line is
# asserted above; the fan-out behavior is proven here directly).
New-Env
Mk-RepoWithOrigin repoA main
Mk-RepoWithOrigin repoB main
Mk-RepoWithOrigin repoC main          # repoC stays DISABLED (tick default off)
git config -f (Join-Path $env:DOTFILES_ROOT 'config') repoA.tick on | Out-Null
git config -f (Join-Path $env:DOTFILES_ROOT 'config') repoB.tick on | Out-Null
Add-Content -LiteralPath (Join-Path $env:HOME '.config/repoA/seed') -Value "a-change"
Add-Content -LiteralPath (Join-Path $env:HOME '.config/repoB/seed') -Value "b-change"
Add-Content -LiteralPath (Join-Path $env:HOME '.config/repoC/seed') -Value "c-change"
$bA = Origin-Tip repoA refs/heads/main; $bB = Origin-Tip repoB refs/heads/main; $bC = Origin-Tip repoC refs/heads/main
Invoke-DF -tick
$aA = Origin-Tip repoA refs/heads/main; $aB = Origin-Tip repoB refs/heads/main; $aC = Origin-Tip repoC refs/heads/main

T-Start L3.9-one-tick-many-repos GOOD
$ok = ($bA -ne $aA) -and ($bB -ne $aB)
Assert-Eq "L3.9 one -tick advanced BOTH enabled repos' origins" $ok $true

T-Start L3.4-disabled-repo-untouched GOOD
Assert-Eq "L3.4 disabled repoC origin did NOT advance" $bC $aC

# ------------------------------------------------------------------------------------------------
# install/uninstall state logic (file-presence registry) + live Task-Scheduler bits (SKIP if not admin).
New-Env
T-Start L3.x-state-uninstall GOOD
$out = Invoke-Timer install
$had = (Test-Path -LiteralPath (PayloadFile))
Invoke-Timer uninstall | Out-Null
$gone = -not (Test-Path -LiteralPath (PayloadFile)) `
        -and -not (Test-Path -LiteralPath (LoopFile)) `
        -and -not (Test-Path -LiteralPath (LauncherFile))
Assert-Eq "L3.x install writes payload; uninstall removes the generated files" ($had -and $gone) $true

T-Start L3.x-enable-disable-status-logs GOOD
if (Timer-Live) {
  Invoke-Timer install | Out-Null
  Invoke-Timer enable  | Out-Null
  $t1 = Get-ScheduledTask -TaskName 'dotfiles-git-commit' -ErrorAction SilentlyContinue
  Invoke-Timer disable | Out-Null
  $t2 = Get-ScheduledTask -TaskName 'dotfiles-git-commit' -ErrorAction SilentlyContinue
  Invoke-Timer status | Out-Null
  Invoke-Timer logs   | Out-Null
  Invoke-Timer uninstall | Out-Null
  $ok = ($t1.State -ne 'Disabled') -and ($t2.State -eq 'Disabled')
  Assert-Eq "L3.x enable->enabled, disable->Disabled (live Task Scheduler)" $ok $true
} else {
  T-Skip "L3.2/L3.3/L3.6/L3.7 enable/disable/status/logs: $LiveSkipReason"
}

# ------------------------------------------------------------------------------------------------
# Final safety-net cleanup (PITFALLS "Windows non-admin timer install SPAWNS a detached pwsh loop").
# Several install asserts above (L3.4/L3.11/L3.11b/L3.13/L3.x) intentionally do NOT uninstall, and on
# a non-admin dev host the timer's best-effort `Start-Process wscript` launches a windowless pwsh loop
# pointed at the per-test temp root. Those loops are harmless no-ops over now-deleted roots (and CI
# runners are ephemeral), but we kill any we spawned so NO runaway loop outlives the test on a dev box.
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like '*-File *.dotfiles-tick-loop.ps1*' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }

T-Summary
