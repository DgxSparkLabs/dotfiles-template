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

# --- The generic tick (node 4): single-writer add -> commit -> push. ---
# Tick ONE repo. Gated by <repo>.tick (default OFF). Staging is SCOPED to the repo's own
# tracked territory (never `git add -A` across all of $HOME). Push only if an upstream exists.
# Returns $true on success, $false on a git error (caller's loop isolates the failure).
function __df_tick_one($repo) {
  $gd = Join-Path (__df_reposdir) $repo
  if (-not (__df_is_repo $gd)) { __df_debug "tick: skip non-repo $repo"; return $true }
  if ((__df_setting_tick $repo) -ne 'true') { __df_debug "tick: $repo tick is OFF -> skip"; return $true }
  $addflag = __df_setting_add $repo          # -A (all) or -u (tracked)

  # --- stage (scoped) ---
  if ($addflag -eq '-A') {
    # Scope -A to the repo's OWN tracked territory: the set of directories that already
    # contain tracked files (plus root-level tracked files themselves). `git add -A -- <dir>`
    # then picks up a NEW untracked file under a dir this repo owns, but can NEVER reach a
    # sibling repo's dir (e.g. .config/beta when this repo only tracks .config/alpha/*).
    # Deriving from ls-files (full depth) rather than ls-tree (top-level) is what keeps
    # repos sharing a parent dir like ~/.config strictly isolated.
    $files = git --git-dir="$gd" --work-tree="$HOME" ls-files 2>$null
    $files = @($files | Where-Object { $_ -ne '' })
    if ($files.Count -eq 0) {
      # Unborn HEAD / no tracked files: can't scope -A safely -> fall back to tracked-only.
      __df_debug "tick: $repo no tracked files, -A scoping skipped (using -u)"
      git --git-dir="$gd" --work-tree="$HOME" add -u 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) { __df_debug "tick: $repo add -u failed"; return $false }
    } else {
      # Unique owned pathspecs = parent dir of each tracked file (root-level files listed
      # individually so we never pass '.' which would sweep all of $HOME). git uses forward
      # slashes in ls-files output regardless of OS.
      $scope = @($files | ForEach-Object {
        $d = ($_ -replace '/[^/]*$', '')
        if ($d -eq $_) { $_ } else { $d }
      } | Sort-Object -Unique)
      git --git-dir="$gd" --work-tree="$HOME" add -A -- @scope 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) { __df_debug "tick: $repo add -A (scoped) failed"; return $false }
    }
  } else {
    git --git-dir="$gd" --work-tree="$HOME" add -u 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { __df_debug "tick: $repo add -u failed"; return $false }
  }

  # --- commit only if something is staged ---
  git --git-dir="$gd" --work-tree="$HOME" diff --cached --quiet
  if ($LASTEXITCODE -eq 0) {
    __df_debug "tick: $repo nothing staged -> no commit"
  } else {
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $hostn = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } elseif ($env:HOSTNAME) { $env:HOSTNAME } else { 'unknown' }
    git --git-dir="$gd" --work-tree="$HOME" commit -q -m "$repo`: auto $ts $hostn" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { __df_debug "tick: $repo commit failed"; return $false }
    __df_debug "tick: $repo committed"
  }

  # --- push only if an upstream is configured (never fail the tick if none) ---
  git --git-dir="$gd" --work-tree="$HOME" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    git --git-dir="$gd" --work-tree="$HOME" push -q 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { __df_debug "tick: $repo pushed" }
    else { __df_debug "tick: $repo push failed (skipping; reconcile is node 5)"; return $false }
  } else {
    __df_debug "tick: $repo no upstream configured -> skip push"
  }
  return $true
}

# `dotfiles -tick [<repo>]`: tick one repo, or loop every repo under bare-repos/.
# Fail-isolation: a git error in one repo is caught + logged; the loop continues.
function __df_tick {
  if ($args.Count -ge 1 -and $args[0]) {
    if (__df_tick_one $args[0]) { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 }
    return
  }
  $base = __df_reposdir
  if (-not (Test-Path -LiteralPath $base)) { $global:LASTEXITCODE = 0; return }
  $rc = 0
  foreach ($d in Get-ChildItem -Directory -LiteralPath $base) {
    if (-not (__df_is_repo $d.FullName)) { __df_debug "tick: skip non-repo under bare-repos/: $($d.Name)"; continue }
    if (-not (__df_tick_one $d.Name)) { $rc = 1; __df_debug "tick: $($d.Name) errored (isolated, continuing)" }
  }
  $global:LASTEXITCODE = $rc
}

# --- Heavy verbs: implemented in later build-tree nodes (5-8). Stubbed but routable. ---
function __df_doctor  { [Console]::Error.WriteLine('dotfiles -doctor: not implemented yet (build node 7)');  $global:LASTEXITCODE = 3 }
function __df_show    { [Console]::Error.WriteLine('dotfiles -show: not implemented yet (build node 5)');    $global:LASTEXITCODE = 3 }
function __df_resolve { [Console]::Error.WriteLine('dotfiles -resolve: not implemented yet (build node 5)'); $global:LASTEXITCODE = 3 }

function dotfiles {
  if ($args.Count -eq 0) { __df_ls; return }
  $tok  = $args[0]
  # [object[]] cast FORCES an array. Without it, an `if`-expression returning a one-element slice
  # ($args[1..1]) unrolls to a scalar string, and splatting a scalar string (`@rest`) explodes it
  # CHAR-BY-CHAR (e.g. `-tick nvim` -> n,v,i,m -> "no such repo n"). The cast keeps a lone trailing
  # arg as a one-element array so @rest splats it as a single token. (PITFALL, see PITFALLS.md.)
  [object[]] $rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

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
