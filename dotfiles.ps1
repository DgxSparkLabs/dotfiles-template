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
# $env:DOTFILES_COMMON overrides the engine dir (tests point it at a fake engine for the
# engine-behind / engine-not-a-git-repo doctor cases); $env:DOTFILES_ROOT overrides the root.
$DotfilesCommon = if ($env:DOTFILES_COMMON) { $env:DOTFILES_COMMON } else { Split-Path -Parent $PSCommandPath }
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

# --- Node 5: never-block reconcile + surfaced resolution ------------------------------
# State (loser log) lives under ~/.dotfiles/state/<repo>/ — LOCAL ONLY, never pushed.
function __df_state_dir($repo)  { Join-Path (Join-Path $DotfilesRoot 'state') $repo }
function __df_conflicts_log($repo) { Join-Path (__df_state_dir $repo) 'conflicts.log' }

# Encode an arbitrary repo path into a single git-ref-safe component (refs can't contain
# leading dots, '..', or end in '.lock'; collapsing every non-alphanumeric to '_' avoids all).
function __df_ref_enc($p) { ($p -replace '[^A-Za-z0-9]', '_') }

# Reconcile the local branch with origin's tip, NEVER blocking. Run AFTER the local commit
# and BEFORE push. Returns $true if a push should be attempted, $false to skip this tick.
function __df_reconcile($repo, $gd, $branch) {
  # CRITICAL (cross-OS): work-tree git verbs (merge/checkout/diff/add) must run with the CWD
  # INSIDE the work tree. Git-for-Windows tolerated running them from an unrelated CWD with just
  # --work-tree, but real Linux/macOS git enforces NEED_WORK_TREE: a bare repo's merge/checkout
  # from outside the tree aborts, so the merge never starts, nothing is staged/pinned/logged —
  # exactly the node-5 Linux failures. Run every work-tree verb as `git -C $W`.
  $W = $env:HOME

  # Fetch the upstream branch. Network/remote failure -> skip push (never blocks).
  git -C "$W" --git-dir="$gd" --work-tree="$W" fetch -q origin $branch 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { __df_debug "reconcile: $repo fetch failed -> skip push"; return $false }

  # Capture FULL SHAs of both sides BEFORE merging; never re-resolve a symbolic ref afterwards
  # (FETCH_HEAD/HEAD can be empty/shift post-merge -> empty revs fed to log/update-ref).
  $theirs = (git --git-dir="$gd" rev-parse --verify -q FETCH_HEAD 2>$null | Out-String).Trim()
  if (-not $theirs) { __df_debug "reconcile: $repo no FETCH_HEAD"; return $true }
  $ours = (git --git-dir="$gd" rev-parse --verify -q HEAD 2>$null | Out-String).Trim()
  # HEAD must be a real commit here (the tick committed before reconcile). Empty $ours would
  # corrupt the loser-pin / newest-wins compare -> fail loudly, skip push (work-tree intact).
  if (-not $ours) {
    [Console]::Error.WriteLine("dotfiles: ${repo}: BUG: empty HEAD SHA in reconcile; skipping push (work-tree intact)")
    return $false
  }

  # Already contains origin tip (up to date or ahead) -> no merge needed.
  git --git-dir="$gd" merge-base --is-ancestor $theirs $ours 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { __df_debug "reconcile: $repo already contains origin tip"; return $true }

  # Unrelated histories -> REFUSE (node 6 owns recovery; never force a wrong merge).
  git --git-dir="$gd" merge-base $ours $theirs 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("dotfiles: ${repo}: unrelated histories with origin/${branch}; refusing to merge (manual action needed)")
    return $false
  }

  # Try the merge without committing/fast-forwarding so we resolve clashes ourselves.
  git -C "$W" --git-dir="$gd" --work-tree="$W" merge --no-commit --no-ff $theirs 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    git -C "$W" --git-dir="$gd" --work-tree="$W" commit --no-edit -q 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { git -C "$W" --git-dir="$gd" --work-tree="$W" commit --no-edit -q --allow-empty 2>$null | Out-Null }
    __df_debug "reconcile: $repo clean merge"
    return $true
  }

  # Conflicts: resolve EACH conflicted path, never blocking.
  $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
  $sdir = __df_state_dir $repo
  New-Item -ItemType Directory -Force -Path $sdir | Out-Null
  $logf = __df_conflicts_log $repo
  $epoch = [int][double]::Parse((Get-Date -UFormat %s))

  $conflicted = @(git -C "$W" --git-dir="$gd" --work-tree="$W" diff --name-only --diff-filter=U 2>$null | Where-Object { $_ -ne '' })
  foreach ($path in $conflicted) {
    $stages = @(git -C "$W" --git-dir="$gd" --work-tree="$W" ls-files -u -- "$path" 2>$null)
    $hasOurs   = ($stages | Where-Object { $_ -match '\s2\t' }).Count -gt 0
    $hasTheirs = ($stages | Where-Object { $_ -match '\s3\t' }).Count -gt 0
    $winner = $null; $loserSha = $null

    if ($hasOurs -and $hasTheirs) {
      # Compare against the PINNED pre-merge SHAs, never a re-resolved symbolic ref.
      $od = (git --git-dir="$gd" log -1 --format=%ct $ours   -- "$path" 2>$null | Out-String).Trim(); if (-not $od) { $od = '0' }
      $td = (git --git-dir="$gd" log -1 --format=%ct $theirs -- "$path" 2>$null | Out-String).Trim(); if (-not $td) { $td = '0' }
      if ([long]$td -gt [long]$od) {
        $winner = 'theirs'; $loserSha = $ours
        git -C "$W" --git-dir="$gd" --work-tree="$W" checkout --theirs -- "$path" 2>$null | Out-Null
      } else {
        $winner = 'ours'; $loserSha = $theirs
        git -C "$W" --git-dir="$gd" --work-tree="$W" checkout --ours -- "$path" 2>$null | Out-Null
      }
    } elseif ($hasOurs) {
      # modify/delete: ours edited, theirs deleted -> edit-beats-delete.
      $winner = 'ours'; $loserSha = $theirs
      git -C "$W" --git-dir="$gd" --work-tree="$W" checkout --ours -- "$path" 2>$null | Out-Null
    } else {
      # modify/delete: theirs edited, ours deleted -> edit-beats-delete.
      $winner = 'theirs'; $loserSha = $ours
      git -C "$W" --git-dir="$gd" --work-tree="$W" checkout --theirs -- "$path" 2>$null | Out-Null
    }

    git -C "$W" --git-dir="$gd" --work-tree="$W" add -- "$path" 2>$null | Out-Null
    $enc = __df_ref_enc $path
    # $loserSha is a pinned pre-merge SHA ($ours/$theirs), guaranteed non-empty by the guards
    # above, so update-ref never receives an empty object name.
    if ($loserSha) {
      git --git-dir="$gd" update-ref "refs/sync-losers/$enc/$epoch" $loserSha 2>$null | Out-Null
      __df_debug "reconcile: $repo pinned loser $loserSha for $path"
    }
    $ls = if ($loserSha) { $loserSha } else { 'none' }
    Add-Content -LiteralPath $logf -Value ("{0}`t{1}`twinner={2}`tloser={3}" -f $ts, $path, $winner, $ls)
  }

  # Never leave the tree mid-merge.
  $residual = @(git -C "$W" --git-dir="$gd" --work-tree="$W" diff --name-only --diff-filter=U 2>$null | Where-Object { $_ -ne '' })
  if ($residual.Count -gt 0) { git -C "$W" --git-dir="$gd" --work-tree="$W" add -A 2>$null | Out-Null }

  git -C "$W" --git-dir="$gd" --work-tree="$W" commit --no-edit -q 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { git -C "$W" --git-dir="$gd" --work-tree="$W" commit --no-edit -q --allow-empty 2>$null | Out-Null }
  __df_debug "reconcile: $repo merge resolved + committed"
  return $true
}

# --- Node 6: robustness — stale-state recovery + concurrent-tick lock. ----------------
# Contract for every behavior here: fail-isolated, fail-loud, never-corrupt, never-block.

# Resolve a bare repo's REAL git-dir (a pure bare repo IS the git-dir; a non-bare repo placed
# under bare-repos/ has its git-dir at <dir>/.git). Returns $null if it can't be resolved.
function __df_gitdir_real($gd) {
  $real = (git --git-dir="$gd" rev-parse --absolute-git-dir 2>$null | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $real) { return $null }
  return $real
}

# Age in seconds of a file/dir, or a large number if unknown (treated as "old enough").
function __df_file_age($f) {
  if (-not (Test-Path -LiteralPath $f)) { return -1 }
  try {
    $mt = (Get-Item -LiteralPath $f -Force).LastWriteTime
    return [int]((Get-Date) - $mt).TotalSeconds
  } catch { return 999999 }
}

# Recover stale state left by a crashed prior tick, BEFORE acting. Guarded + safe:
#   * leftover MERGE_HEAD -> merge --abort (restores work-tree), fall back to reset/rm.
#   * stale index.lock OLDER than the threshold (default 60s) -> remove. A FRESH lock is LEFT
#     alone (may belong to a live git process); the tick-lock then skips this cycle instead.
function __df_recover_stale($repo, $gd) {
  $rgd = __df_gitdir_real $gd
  if (-not $rgd) { return }
  $thresh = if ($env:DOTFILES_LOCK_STALE) { [int]$env:DOTFILES_LOCK_STALE } else { 60 }
  $W = $env:HOME
  if (Test-Path -LiteralPath (Join-Path $rgd 'MERGE_HEAD')) {
    __df_debug "recover: $repo stale MERGE_HEAD -> merge --abort"
    git -C "$W" --git-dir="$gd" --work-tree="$W" merge --abort 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      git -C "$W" --git-dir="$gd" --work-tree="$W" reset --hard -q HEAD 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) {
        foreach ($f in 'MERGE_HEAD','MERGE_MSG','MERGE_MODE') {
          Remove-Item -LiteralPath (Join-Path $rgd $f) -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }
  $lock = Join-Path $rgd 'index.lock'
  if (Test-Path -LiteralPath $lock) {
    $age = __df_file_age $lock
    if ($age -ge $thresh) {
      __df_debug "recover: $repo stale index.lock (age ${age}s >= ${thresh}s) -> remove"
      Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    } else {
      __df_debug "recover: $repo fresh index.lock (age ${age}s) -> leave (may be live)"
    }
  }
}

# Concurrent-tick lock: serialize ticks on ONE repo so two overlapping -tick runs never corrupt
# the index. Portable mutual exclusion via an atomic directory create. A STALE lock (older than
# the threshold) is reclaimed; a LIVE tick's lock makes us SKIP this cycle (never block).
# Returns $true = acquired, $false = held by a live tick (skip). Sets $script:DfLockDir.
function __df_lock_acquire($repo, $gd) {
  $rgd = __df_gitdir_real $gd
  if (-not $rgd) { return $true }   # can't resolve git-dir -> let the tick fail naturally
  $lockdir = Join-Path $rgd 'dotfiles-tick.lock'
  $thresh = if ($env:DOTFILES_LOCK_STALE) { [int]$env:DOTFILES_LOCK_STALE } else { 60 }
  try {
    New-Item -ItemType Directory -Path $lockdir -ErrorAction Stop | Out-Null
    Set-Content -LiteralPath (Join-Path $lockdir 'pid') -Value "$PID" -ErrorAction SilentlyContinue
    $script:DfLockDir = $lockdir
    return $true
  } catch {
    $age = __df_file_age $lockdir
    if ($age -ge $thresh) {
      __df_debug "lock: $repo reclaiming stale tick-lock (age ${age}s >= ${thresh}s)"
      Remove-Item -LiteralPath $lockdir -Recurse -Force -ErrorAction SilentlyContinue
      try {
        New-Item -ItemType Directory -Path $lockdir -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath (Join-Path $lockdir 'pid') -Value "$PID" -ErrorAction SilentlyContinue
        $script:DfLockDir = $lockdir
        return $true
      } catch { }
    }
    __df_debug "lock: $repo held by a live tick -> skip this cycle (never block)"
    return $false
  }
}
function __df_lock_release {
  if ($script:DfLockDir) { Remove-Item -LiteralPath $script:DfLockDir -Recurse -Force -ErrorAction SilentlyContinue }
  $script:DfLockDir = $null
}

# --- The generic tick (node 4): single-writer add -> commit -> push. ---
# Tick ONE repo. Gated by <repo>.tick (default OFF). Node 6 wraps the real work
# (__df_tick_one_body) with the concurrent-tick lock + stale-state recovery; the lock is ALWAYS
# released on every exit path. Returns $true on success, $false on a git error (caller isolates).
function __df_tick_one($repo) {
  $gd = Join-Path (__df_reposdir) $repo
  if (-not (__df_is_repo $gd)) { __df_debug "tick: skip non-repo $repo"; return $true }
  if ((__df_setting_tick $repo) -ne 'true') { __df_debug "tick: $repo tick is OFF -> skip"; return $true }
  # Serialize on this repo (never block): a live tick holds the lock -> skip this cycle + log.
  if (-not (__df_lock_acquire $repo $gd)) {
    [Console]::Error.WriteLine("dotfiles: ${repo}: a tick is already running for this repo; skipping this cycle")
    return $true
  }
  # Recover stale state from a crashed prior tick BEFORE acting.
  __df_recover_stale $repo $gd
  try {
    return (__df_tick_one_body $repo $gd)
  } finally {
    __df_lock_release
  }
}

# The real per-repo tick work. Caller validated the repo, checked the gate, acquired the lock,
# and recovered stale state. Returns $true on success, $false on a git error.
function __df_tick_one_body($repo, $gd) {
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

  # --- reconcile with origin, then push (bounded retry); never block. ---
  git --git-dir="$gd" --work-tree="$env:HOME" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $branch = (git --git-dir="$gd" symbolic-ref --short -q HEAD 2>$null | Out-String).Trim()
    if (-not $branch) { __df_debug "tick: $repo detached HEAD -> skip push"; return $true }
    $attempt = 0; $max = 3; $pushed = $false
    while ($attempt -lt $max) {
      $attempt++
      if (-not (__df_reconcile $repo $gd $branch)) { __df_debug "tick: $repo reconcile said skip push (attempt $attempt)"; break }
      git --git-dir="$gd" --work-tree="$env:HOME" push -q origin $branch 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { __df_debug "tick: $repo pushed (attempt $attempt)"; $pushed = $true; break }
      __df_debug "tick: $repo push rejected (attempt $attempt) -> re-reconcile"
    }
    if (-not $pushed) {
      __df_debug "tick: $repo push not completed after $attempt attempt(s) -> logged + skipped"
      [Console]::Error.WriteLine("dotfiles: ${repo}: push to origin/${branch} not completed this tick (will retry next tick)")
      return $false
    }
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

# --- Node 7: -doctor — health + the load-bearing exclusive-ownership invariant. -------
# Prints an engine line, a per-repo status line, an ownership (overlap) check, and a
# warnings/info block. EVERY problem prints an ACTIONABLE fix line. Exit policy: nonzero
# ONLY when at least one ERROR exists (a path tracked by >1 repo, or a corrupt/non-git repo
# under bare-repos/). Warnings/info do NOT fail the exit code. Behavior-identical to the bash
# __df_doctor. See plan "F. Expected command outputs" and "G. Doctor — error cases".
function __df_hooks_target { Join-Path $DotfilesCommon 'githooks' }

function __df_doctor {
  $errors = 0; $warnings = 0
  $warnLines = New-Object System.Collections.Generic.List[string]

  # --- engine line -------------------------------------------------------------------
  $ecommon = $DotfilesCommon
  git --git-dir="$ecommon/.git" rev-parse --git-dir 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $ebranch = (git -C "$ecommon" symbolic-ref --short -q HEAD 2>$null | Out-String).Trim()
    if (-not $ebranch) { $ebranch = '(detached)' }
    $eupstream = (git -C "$ecommon" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $eupstream) {
      $behind = (git -C "$ecommon" rev-list --count 'HEAD..@{u}' 2>$null | Out-String).Trim()
      if ($behind -match '^[0-9]+$' -and [int]$behind -gt 0) {
        Write-Output ("engine:  {0}  branch {1}, {2} commit(s) behind {3}" -f $ecommon, $ebranch, $behind, $eupstream)
        $warnLines.Add("  engine: behind upstream by $behind commit(s)   fix -> dotfiles --update")
        $warnings++
      } else {
        Write-Output ("engine:  {0}  branch {1}, up to date" -f $ecommon, $ebranch)
      }
    } else {
      Write-Output ("engine:  {0}  branch {1} (no upstream)" -f $ecommon, $ebranch)
    }
  } else {
    # L5.26: engine dir exists but is NOT a git repo -> `dotfiles --update` would fail. ERROR.
    Write-Output ("engine:  {0}  NOT a git repo" -f $ecommon)
    $warnLines.Add("  engine: $ecommon is not a git repo (dotfiles --update would fail)   fix -> re-clone the engine into it")
    $errors++
  }

  # --- per-repo block + overlap accounting -------------------------------------------
  $base = __df_reposdir
  Write-Output 'repos:'
  $owners = New-Object System.Collections.Generic.List[object]   # @{ Path=...; Repo=... }
  $totalPaths = 0; $repoCount = 0
  if (Test-Path -LiteralPath $base) {
    foreach ($d in Get-ChildItem -Directory -LiteralPath $base | Sort-Object Name) {
      $repo = $d.Name
      $gd = $d.FullName
      if (-not (__df_is_repo $gd)) {
        Write-Output ("  {0,-8} NOT a git repo (skipped)" -f $repo)
        $warnLines.Add("  ${repo}: not a git repo under bare-repos/   fix -> remove $gd or restore the repo")
        $errors++
        continue
      }
      $repoCount++

      $branch = (git --git-dir="$gd" symbolic-ref --short -q HEAD 2>$null | Out-String).Trim()
      if (-not $branch) {
        git --git-dir="$gd" rev-parse --verify -q HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $branch = 'detached' } else { $branch = 'none' }
      }
      $upstream = (git --git-dir="$gd" --work-tree="$env:HOME" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null | Out-String).Trim()
      if ($LASTEXITCODE -ne 0 -or -not $upstream) { $upstream = '(none)' }

      $tickv = if ((__df_setting_tick $repo) -eq 'true') { 'on' } else { 'off' }
      $addv  = if ((__df_setting_add $repo) -eq '-A') { 'all' } else { 'tracked' }

      $hp = (git --git-dir="$gd" config --get core.hooksPath 2>$null | Out-String).Trim()
      $hooks = if ($hp -and (Test-Path -LiteralPath $hp)) { 'wired' } else { 'MISSING' }

      Write-Output ("  {0,-8} branch {1,-8} upstream {2,-16} tick:{3,-3} add:{4,-7} hooks:{5}" -f `
        $repo, $branch, $upstream, $tickv, $addv, $hooks)

      # --- warnings / info per repo (each with a fix) ---
      if ($upstream -eq '(none)' -and $branch -ne 'detached' -and $branch -ne 'none') {
        $warnLines.Add("  ${repo}: no upstream for '$branch'   fix -> dotfiles $repo push -u origin $branch")
        $warnings++
      }
      if ($branch -eq 'detached') {
        $warnLines.Add("  ${repo}: detached HEAD (no branch)   fix -> dotfiles $repo checkout <branch>")
        $warnings++
      } elseif ($branch -eq 'none') {
        $warnLines.Add("  ${repo}: no HEAD branch   fix -> dotfiles $repo checkout <branch>")
        $warnings++
      }
      if (-not $hp) {
        $warnLines.Add("  ${repo}: core.hooksPath not set   fix -> dotfiles $repo config core.hooksPath `"`$HOME/.dotfiles/common/githooks`"")
        $warnings++
        if ($tickv -eq 'on') {
          $warnLines.Add("  ${repo}: tick is ON but core.hooksPath is unset (auto-commits run no hooks)   fix -> dotfiles $repo config core.hooksPath `"`$HOME/.dotfiles/common/githooks`"")
          $warnings++
        }
      } elseif (-not (Test-Path -LiteralPath $hp)) {
        $warnLines.Add(("  {0}: core.hooksPath set to '{1}' but that dir is missing   fix -> dotfiles {0} config core.hooksPath `"{2}`"" -f $repo, $hp, (__df_hooks_target)))
        $warnings++
      }
      if ($tickv -eq 'off') {
        $warnLines.Add("  ${repo}: tick is OFF (won't sync)   info -> dotfiles -config $repo.tick on")
        # info, not a warning -> does NOT bump the warning count or exit code.
      }

      # --- ownership accounting ---
      $lf = git --git-dir="$gd" --work-tree="$env:HOME" ls-files 2>$null
      foreach ($path in @($lf | Where-Object { $_ -ne '' })) {
        $totalPaths++
        $owners.Add([pscustomobject]@{ Path = $path; Repo = $repo })
      }
    }
  }

  # --- overlap pass (THE big one): any path owned by >1 repo is an ERROR. -------------
  $overlaps = $owners | Group-Object Path | Where-Object {
    ($_.Group | Select-Object -ExpandProperty Repo -Unique).Count -gt 1
  }
  $ownLine = 'ownership: '
  if ($overlaps) {
    Write-Output ($ownLine + 'OVERLAP')
    foreach ($o in $overlaps) {
      $repos = ($o.Group | Select-Object -ExpandProperty Repo -Unique | Sort-Object)
      $reposStr = ($repos -join ', ')
      $wrong = $repos[1]   # release the SECOND owner, per plan G
      Write-Output ("  {0}   tracked by: {1}" -f $o.Name, $reposStr)
      Write-Output ("    fix -> dotfiles {0} rm --cached {1}" -f $wrong, $o.Name)
      $errors++
    }
  } else {
    Write-Output ($ownLine + ("{0} paths across {1} repos, no overlaps" -f $totalPaths, $repoCount))
  }

  # --- warnings / info block ---------------------------------------------------------
  if ($warnLines.Count -gt 0) {
    Write-Output 'warnings:'
    foreach ($l in $warnLines) { Write-Output $l }
  }

  # --- final summary + exit code -----------------------------------------------------
  if ($errors -eq 0) {
    Write-Output 'all checks passed'
    $global:LASTEXITCODE = 0
  } else {
    Write-Output ("{0} error(s), {1} warning(s)" -f $errors, $warnings)
    $global:LASTEXITCODE = 1
  }
}

# -show: print each repo's recorded conflicts (state/<repo>/conflicts.log), or "(no conflicts)".
function __df_show {
  $base = __df_reposdir
  if (-not (Test-Path -LiteralPath $base)) { Write-Output '(no conflicts)'; $global:LASTEXITCODE = 0; return }
  foreach ($d in Get-ChildItem -Directory -LiteralPath $base) {
    if (-not (__df_is_repo $d.FullName)) { continue }
    $repo = $d.Name
    $logf = __df_conflicts_log $repo
    if ((Test-Path -LiteralPath $logf) -and ((Get-Item -LiteralPath $logf).Length -gt 0)) {
      foreach ($line in (Get-Content -LiteralPath $logf)) {
        if ($line -ne '') { Write-Output ("{0}:`t{1}" -f $repo, $line) }
      }
    } else {
      Write-Output ("{0}:`t(no conflicts)" -f $repo)
    }
  }
  $global:LASTEXITCODE = 0
}

# -resolve <path>: find the most recent pinned loser for <path>, write its blob beside the
# live file as <path>.loser, print a winner-vs-loser header. Exit 0; exit 1 if none recorded.
function __df_resolve {
  $path = if ($args.Count -ge 1) { $args[0] } else { $null }
  if (-not $path) { [Console]::Error.WriteLine('dotfiles -resolve: usage: dotfiles -resolve <path>'); $global:LASTEXITCODE = 2; return }
  # Normalize to a repo-relative path (strip a leading $HOME or ~/). Compare with forward slashes.
  $homeFwd = ($env:HOME -replace '\\', '/')
  $pFwd = ($path -replace '\\', '/')
  if ($pFwd.StartsWith("$homeFwd/")) { $path = $pFwd.Substring($homeFwd.Length + 1) }
  elseif ($pFwd.StartsWith('~/'))    { $path = $pFwd.Substring(2) }
  else { $path = $pFwd }
  $enc = __df_ref_enc $path

  $base = __df_reposdir
  if (-not (Test-Path -LiteralPath $base)) { [Console]::Error.WriteLine('dotfiles -resolve: no repos'); $global:LASTEXITCODE = 1; return }
  $bestEpoch = -1; $bestRef = $null; $bestRepo = $null; $bestGd = $null
  foreach ($d in Get-ChildItem -Directory -LiteralPath $base) {
    if (-not (__df_is_repo $d.FullName)) { continue }
    $gd = $d.FullName
    foreach ($ref in (git --git-dir="$gd" for-each-ref --format='%(refname)' "refs/sync-losers/$enc" 2>$null)) {
      $epoch = $ref.Substring($ref.LastIndexOf('/') + 1)
      if ($epoch -notmatch '^[0-9]+$') { continue }
      if ([long]$epoch -gt $bestEpoch) { $bestEpoch = [long]$epoch; $bestRef = $ref; $bestRepo = $d.Name; $bestGd = $gd }
    }
  }
  if (-not $bestRef) { [Console]::Error.WriteLine("dotfiles -resolve: no recorded loser for $path"); $global:LASTEXITCODE = 1; return }

  $loserSha = (git --git-dir="$bestGd" rev-parse --verify -q $bestRef 2>$null | Out-String).Trim()
  # Extract the path's blob WITHOUT the <rev>:<path> colon syntax (Git-for-Windows mangles it).
  $blob = (git --git-dir="$bestGd" ls-tree -r $loserSha -- "$path" 2>$null | ForEach-Object { ($_ -split '\s+')[2] } | Select-Object -First 1)
  $out = Join-Path $env:HOME "$path.loser"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
  if ($blob) {
    git --git-dir="$bestGd" cat-file -p $blob 2>$null | Set-Content -LiteralPath $out
  } else {
    Set-Content -LiteralPath $out -Value '' -NoNewline
  }
  Write-Output ("clash in repo {0}   loser={1}" -f $bestRepo, $loserSha)
  Write-Output ("--- winner (current file) ---     --- loser ({0}) ---" -f $loserSha)
  Write-Output ("loser written to: {0}   (merge by hand, then rm it)" -f $out)
  $global:LASTEXITCODE = 0
}

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
