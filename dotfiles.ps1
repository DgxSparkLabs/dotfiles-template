# dotfiles.ps1 — one command for every bare repo under ~/.dotfiles/bare-repos/ (PowerShell).
#
# Grammar (uniform): the first token decides.
#   dotfiles <repo> <git args...>   bare token  -> git passthrough on that repo (any repo name legal)
#   dotfiles -<verb> [args...]      dashed token-> management verb (one OR two dashes: -ls == --ls)
#   dotfiles                        no args     -> list repos (== -ls)
#
# Dot-source from $PROFILE; also dot-sourceable in tests: `. ./dotfiles.ps1; dotfiles -ls`.
# Override $env:DOTFILES_ROOT to point at a different ~/.dotfiles (the test harness does this).

# Engine dir = where THIS script lives (…/.dotfiles/common). Root = its parent by default.
$DotfilesCommon = Split-Path -Parent $PSCommandPath
$DotfilesRoot = if ($env:DOTFILES_ROOT) { $env:DOTFILES_ROOT } else { Split-Path -Parent $DotfilesCommon }

function __df_debug($m) { if ($env:DOTFILES_DEBUG) { [Console]::Error.WriteLine("[dotfiles] $m") } }
function __df_reposdir { Join-Path $DotfilesRoot 'bare-repos' }

# True only if $dir is a real git dir (bare repo). Guards discovery against stray folders (L5.13).
function __df_is_repo($dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return $false }
  git --git-dir="$dir" rev-parse --git-dir 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function __df_ls {
  $base = __df_reposdir
  if (-not (Test-Path -LiteralPath $base)) { return }
  foreach ($d in Get-ChildItem -Directory -LiteralPath $base) {
    if (__df_is_repo $d.FullName) { $d.Name } else { __df_debug "skip non-repo under bare-repos/: $($d.Name)" }
  }
}

function __df_help {
@'
dotfiles <repo> <git args...>   run git on that bare repo (work-tree = $HOME)
dotfiles -ls                    list repos        (== --ls; every verb takes one or two dashes)
dotfiles -config <repo>.<key> [value]   read/write engine settings (~/.dotfiles/config)
dotfiles -tick [<repo>]         run the sync tick now (all repos, or one)
dotfiles -doctor                health + overlap check across repos
dotfiles -show                  list recorded sync conflicts
dotfiles -resolve <path>        recover the losing side of a conflict
dotfiles -timer <install|...>   manage the single auto-tick timer
dotfiles -update                upgrade the engine (git pull in ~/.dotfiles/common)
'@
}

# Engine settings live in ~/.dotfiles/config (git-config syntax), OUTSIDE every bare repo.
function __df_config { git config -f (Join-Path $DotfilesRoot 'config') @args }

# Raw reader: returns the value for <section>.<key>, or $null if unset/malformed.
# Distinguishes unset (git rc 1) from malformed config (git rc >= 2): on malformed it
# warns to real stderr and returns $null (BAD-path safe refuse). Sets $script:RawRc.
function __df_raw($dotted) {
  $cf = Join-Path $DotfilesRoot 'config'
  $out = git config -f "$cf" --get "$dotted" 2>$null
  $script:RawRc = $LASTEXITCODE
  if ($script:RawRc -ge 2) {
    [Console]::Error.WriteLine("dotfiles: config malformed at $cf; using default for $dotted")
    return $null
  }
  if ($script:RawRc -ne 0) { return $null }
  return ($out | Out-String).Trim()
}

# tick: bool with safe default OFF. Unparseable (e.g. "maybe") -> default + warning. Returns 'true'/'false'.
function __df_setting_tick($repo) {
  $def = 'false'
  $raw = __df_raw "$repo.tick"
  if ($null -eq $raw) { return $def }
  switch -regex ($raw.ToLower()) {
    '^(true|yes|on|1)$'  { return 'true' }
    '^(false|no|off|0)$' { return 'false' }
    default {
      [Console]::Error.WriteLine("dotfiles: invalid bool for $repo.tick=$raw; using default $def")
      return $def
    }
  }
}

# add: only "all" -> -A; anything else (incl. junk) -> tracked (-u), warning on junk. Returns '-A'/'-u'.
function __df_setting_add($repo) {
  $raw = __df_raw "$repo.add"
  if ($null -eq $raw) { return '-u' }
  switch -regex ($raw.ToLower()) {
    '^all$'            { return '-A' }
    '^(tracked|-u|)$'  { return '-u' }
    default {
      [Console]::Error.WriteLine("dotfiles: invalid value for $repo.add=$raw; using default tracked")
      return '-u'
    }
  }
}

# [timer] interval: positive integer seconds, default 60. Non-numeric -> default + warning.
function __df_setting_timer_interval {
  $def = 60
  $raw = __df_raw 'timer.interval'
  if ($null -eq $raw) { return $def }
  if ($raw -match '^[0-9]+$') { return [int]$raw }
  [Console]::Error.WriteLine("dotfiles: invalid timer.interval=$raw; using default $def")
  return $def
}

# Generic reader retained for forward-compat callers. Usage: __df_setting <repo> <key> <default>
function __df_setting($repo, $key, $def) {
  $raw = __df_raw "$repo.$key"
  if ($null -eq $raw) { return $def }
  return $raw
}
function __df_update { __df_debug "updating engine at $DotfilesCommon"; git -C $DotfilesCommon pull --ff-only }
function __df_timer  { & (Join-Path $DotfilesCommon 'timer/dotfiles-timer.ps1') @args }

# --- Heavy verbs: implemented in later build-tree nodes (4-8). Stubbed but routable. ---
function __df_tick    { [Console]::Error.WriteLine('dotfiles -tick: not implemented yet (build node 4)');    $global:LASTEXITCODE = 3 }
function __df_doctor  { [Console]::Error.WriteLine('dotfiles -doctor: not implemented yet (build node 7)');  $global:LASTEXITCODE = 3 }
function __df_show    { [Console]::Error.WriteLine('dotfiles -show: not implemented yet (build node 5)');    $global:LASTEXITCODE = 3 }
function __df_resolve { [Console]::Error.WriteLine('dotfiles -resolve: not implemented yet (build node 5)'); $global:LASTEXITCODE = 3 }

function dotfiles {
  if ($args.Count -eq 0) { __df_ls; return }
  $tok  = $args[0]
  $rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

  if ($tok -like '-*') {
    $verb = $tok -replace '^-+', ''                 # strip one OR two leading dashes
    switch ($verb) {
      'h'       { __df_help; return }
      'help'    { __df_help; return }
      'ls'      { __df_ls; return }
      'config'  { __df_config @rest; return }
      'update'  { __df_update @rest; return }
      'timer'   { __df_timer @rest; return }
      'tick'    { __df_tick @rest; return }
      'doctor'  { __df_doctor @rest; return }
      'show'    { __df_show @rest; return }
      'resolve' { __df_resolve @rest; return }
      default   { [Console]::Error.WriteLine("dotfiles: unknown command -$verb (try --help)"); $global:LASTEXITCODE = 2; return }
    }
  }

  # Bare first token => repo name (repo always wins over verb names; a repo may be named "show").
  $repo = $tok
  $gd = Join-Path (__df_reposdir) $repo
  if (-not (__df_is_repo $gd)) {
    [Console]::Error.WriteLine("dotfiles: no such repo: $repo (try --ls)"); $global:LASTEXITCODE = 1; return
  }
  __df_debug "git on repo=$repo"
  git --git-dir="$gd" --work-tree="$HOME" @rest
}
