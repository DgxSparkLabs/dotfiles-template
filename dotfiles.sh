#!/usr/bin/env bash
# dotfiles — one command for every bare repo under ~/.dotfiles/bare-repos/.
#
# Grammar (uniform): the first token decides.
#   dotfiles <repo> <git args...>   bare token  -> git passthrough on that repo (any repo name legal)
#   dotfiles -<verb> [args...]      dashed token-> management verb (one OR two dashes: -ls == --ls)
#   dotfiles                        no args     -> list repos (== -ls)
#
# Sourced from the shell profile; also runnable directly (bash) for tests.
# Override DOTFILES_ROOT to point at a different ~/.dotfiles (the test harness does this).

# Engine dir = where THIS script lives (…/.dotfiles/common). Robust under symlinks and tests.
# DOTFILES_COMMON can be overridden via the env (tests point it at a fake engine for the
# engine-behind / engine-not-a-git-repo doctor cases).
if [ -n "${DOTFILES_COMMON:-}" ]; then
  :
elif [ -n "${BASH_SOURCE:-}" ]; then
  DOTFILES_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  DOTFILES_COMMON="$(cd "$(dirname "$0")" && pwd)"
fi
# DOTFILES_SELF = absolute path to THIS script file (the REAL dispatcher), computed from the
# script's own location and NEVER from DOTFILES_COMMON (which is env-overridable so the doctor
# engine tests can point it at a FAKE engine dir). The zsh->bash heavy-verb re-exec MUST run
# THIS file, not "$DOTFILES_COMMON/dotfiles.sh" — when a test overrides DOTFILES_COMMON to a
# fake dir with no dotfiles.sh, the latter re-exec dies with rc 127 / "No such file or directory".
# Under bash, $BASH_SOURCE[0] is this file; under a sourced zsh shell, $0 is the sourced file.
# Do NOT let the env override DOTFILES_SELF.
if [ -n "${BASH_SOURCE:-}" ]; then _df_self="${BASH_SOURCE[0]}"; else _df_self="$0"; fi
DOTFILES_SELF="$(cd "$(dirname "$_df_self")" && pwd)/$(basename "$_df_self")"
# Root holding bare-repos/, config, hooks/, state/ = parent of common/ by default.
DOTFILES_ROOT="${DOTFILES_ROOT:-$(dirname "$DOTFILES_COMMON")}"

__df_debug() { [ -n "${DOTFILES_DEBUG:-}" ] && printf '[dotfiles] %s\n' "$*" >&2; return 0; }

__df_repos_dir() { printf '%s/bare-repos' "$DOTFILES_ROOT"; }
__df_config_file() { printf '%s/config' "$DOTFILES_ROOT"; }

# True only if $1 is a real git dir (bare repo). Guards discovery against stray folders (L5.13).
__df_is_repo() {
  [ -d "$1" ] || return 1
  git --git-dir="$1" rev-parse --git-dir >/dev/null 2>&1
}

__df_ls() {
  local base d name; base="$(__df_repos_dir)"
  [ -d "$base" ] || return 0
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if __df_is_repo "$d"; then
      printf '%s\n' "$name"
    else
      __df_debug "skip non-repo under bare-repos/: $name"
    fi
  done
}

__df_help() {
  cat <<'EOF'
dotfiles <repo> <git args...>   run git on that bare repo (work-tree = $HOME)
dotfiles -ls                    list repos        (== --ls; every verb takes one or two dashes)
dotfiles -config <repo>.<key> [value]   read/write engine settings (~/.dotfiles/config)
dotfiles -tick [<repo>]         run the sync tick now (all repos, or one)
dotfiles -doctor                health + overlap check across repos
dotfiles -show                  list recorded sync conflicts
dotfiles -resolve <path>        recover the losing side of a conflict
dotfiles -timer <install|...>   manage the single auto-tick timer
dotfiles -update                upgrade the engine (git pull in ~/.dotfiles/common)
EOF
}

# Engine settings live in ~/.dotfiles/config (git-config syntax), OUTSIDE every bare repo.
__df_config() { git config -f "$(__df_config_file)" "$@"; }

# Raw reader: echo the value for <section>.<key>, or the empty string if unset.
# Distinguishes "unset" (rc 1) from "config file malformed" (rc>=2). On a malformed
# config it warns to stderr and behaves as if the key were unset (BAD-path safe refuse).
# Echoes nothing and returns: 0=found, 1=unset/empty, 2=malformed.
__df_raw() {
  local dotted="$1" cf out rc
  cf="$(__df_config_file)"
  out="$(git config -f "$cf" --get "$dotted" 2>/dev/null)"; rc=$?
  if [ "$rc" -ge 2 ]; then
    # rc>=2 from `git config` = the file could not be parsed (malformed).
    printf 'dotfiles: config malformed at %s; using default for %s\n' "$cf" "$dotted" >&2
    return 2
  fi
  [ "$rc" -eq 0 ] && printf '%s' "$out"
  return "$rc"
}

# tick: bool with safe default OFF. Unparseable (e.g. "maybe") -> default + warning.
# Echoes "true" or "false". Usage: __df_setting_tick <repo>
__df_setting_tick() {
  local repo="$1" raw rc def=false
  raw="$(__df_raw "${repo}.tick")"; rc=$?
  [ "$rc" -ne 0 ] && { printf '%s' "$def"; return 0; }   # unset or malformed -> default off
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    true|yes|on|1)   printf 'true' ;;
    false|no|off|0)  printf 'false' ;;
    *) printf 'dotfiles: invalid bool for %s.tick=%s; using default %s\n' "$repo" "$raw" "$def" >&2
       printf '%s' "$def" ;;
  esac
}

# add: only "all" -> -A; anything else (incl. junk) -> tracked (-u), with a warning on junk.
# Echoes "-A" or "-u". Usage: __df_setting_add <repo>
__df_setting_add() {
  local repo="$1" raw rc
  raw="$(__df_raw "${repo}.add")"; rc=$?
  [ "$rc" -ne 0 ] && { printf '%s' '-u'; return 0; }      # unset or malformed -> tracked
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    all)            printf '%s' '-A' ;;
    tracked|''|-u)  printf '%s' '-u' ;;
    *) printf 'dotfiles: invalid value for %s.add=%s; using default tracked\n' "$repo" "$raw" >&2
       printf '%s' '-u' ;;
  esac
}

# [timer] interval: positive integer seconds, default 60. Non-numeric -> default + warning.
__df_setting_timer_interval() {
  local raw rc def=60
  raw="$(__df_raw 'timer.interval')"; rc=$?
  [ "$rc" -ne 0 ] && { printf '%s' "$def"; return 0; }
  case "$raw" in
    ''|*[!0-9]*) printf 'dotfiles: invalid timer.interval=%s; using default %s\n' "$raw" "$def" >&2
                 printf '%s' "$def" ;;
    *)           printf '%s' "$raw" ;;
  esac
}

# Generic reader retained for forward-compat callers. Usage: __df_setting <repo> <key> <default>
__df_setting() {
  local repo="$1" key="$2" def="$3" raw rc
  raw="$(__df_raw "${repo}.${key}")"; rc=$?
  [ "$rc" -ne 0 ] && { printf '%s' "$def"; return 0; }
  printf '%s' "$raw"
}

__df_update() {
  __df_debug "updating engine at $DOTFILES_COMMON"
  git -C "$DOTFILES_COMMON" pull --ff-only
}

__df_timer() { bash "$DOTFILES_COMMON/timer/dotfiles-timer.sh" "$@"; }

# --- Node 5: never-block reconcile + surfaced resolution ------------------------------
# State (loser log) lives under ~/.dotfiles/state/<repo>/ — LOCAL ONLY, never pushed.
__df_state_dir()  { printf '%s/state/%s' "$DOTFILES_ROOT" "$1"; }
__df_conflicts_log() { printf '%s/conflicts.log' "$(__df_state_dir "$1")"; }

# Encode an arbitrary repo path into a single git-ref-safe component (refs can't contain
# leading dots, '..', or end in '.lock'; collapsing every non-alphanumeric to '_' avoids all).
__df_ref_enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g'; }

# Reconcile the local branch with origin's tip, NEVER blocking. Run AFTER the local commit
# and BEFORE push, inside __df_tick_one. Returns 0 if a push should be attempted, 1 to skip.
# Steps: fetch -> if behind, merge --no-commit --no-ff FETCH_HEAD; auto-merge non-overlapping
# edits; resolve true clashes by newest committer-date (pin+log the loser); edit-beats-delete
# for modify/delete; commit the merge. Unrelated histories -> REFUSE (abort, log, skip: node 6
# owns recovery, but we must never force a wrong merge).
__df_reconcile() {
  # CRITICAL (zsh): zsh does NOT word-split unquoted "$var"/"$(cmd)" on whitespace by default
  # (bash does). The per-path conflict loop below relies on splitting newline-delimited git
  # output, and array/IFS semantics differ between shells. `emulate -L sh` LOCALLY (function
  # scope only) switches zsh to POSIX sh word-splitting + array semantics for this function;
  # under bash it's a no-op (the builtin doesn't exist, so `|| true` swallows the error). This
  # keeps the SAME code correct under bash AND zsh. The loop is ALSO rewritten as a
  # `while IFS= read -r` (belt-and-suspenders) so it never depends on word-splitting at all.
  emulate -L sh 2>/dev/null || true
  local repo="$1" gd="$2" branch="$3"
  local g; # shorthand prefix used inline below

  # CRITICAL (cross-OS): work-tree git verbs (merge/checkout/diff/add) must run with the CWD
  # INSIDE the work tree. Git-for-Windows tolerated running them from an unrelated CWD with just
  # --work-tree, but real Linux/macOS git enforces NEED_WORK_TREE: a bare repo's merge/checkout
  # from outside the tree aborts ("fatal: this operation must be run in a work tree"), so the
  # merge never starts, no conflicts are staged, no loser is pinned, nothing is logged — exactly
  # the node-5 Linux failures. Run every work-tree verb as `git -C "$HOME"` so the CWD is the
  # tree on all OSes. (cd into a subshell would lose the rest of the function's state.)
  local W="$HOME"

  # Fetch the upstream branch. Network/remote failure -> caller skips push (never blocks).
  if ! git -C "$W" --git-dir="$gd" --work-tree="$W" fetch -q origin "$branch" 2>/dev/null; then
    __df_debug "reconcile: $repo fetch failed -> skip push this tick"
    return 1
  fi

  # Nothing fetched (no such ref yet) -> nothing to merge; push will create/seed it.
  # Capture FULL SHAs of both sides BEFORE merging, and NEVER re-resolve a symbolic ref later:
  # MERGE_HEAD/FETCH_HEAD/HEAD can resolve to empty or shift after the merge starts, which fed
  # empty revisions to git log/update-ref ("fatal: Needed a single revision" / "Not a valid
  # object name"). $ours/$theirs below are pinned, non-empty SHAs.
  local theirs
  theirs="$(git --git-dir="$gd" rev-parse --verify -q FETCH_HEAD 2>/dev/null)" || { __df_debug "reconcile: $repo no FETCH_HEAD"; return 0; }
  [ -n "$theirs" ] || { __df_debug "reconcile: $repo empty FETCH_HEAD SHA -> skip push"; return 1; }
  local ours
  ours="$(git --git-dir="$gd" rev-parse --verify -q HEAD 2>/dev/null)"
  # HEAD must be a real commit by this point (the tick committed before reconcile). An empty
  # $ours would silently corrupt the loser-pin / newest-wins compare -> fail loudly, skip push.
  if [ -z "$ours" ]; then
    printf 'dotfiles: %s: BUG: empty HEAD SHA in reconcile; skipping push (work-tree intact)\n' "$repo" >&2
    return 1
  fi

  # Already up to date or strictly ahead (their tip is our ancestor) -> no merge needed.
  if git --git-dir="$gd" merge-base --is-ancestor "$theirs" "$ours" 2>/dev/null; then
    __df_debug "reconcile: $repo already contains origin tip -> no merge"
    return 0
  fi

  # Unrelated histories -> REFUSE (node 6 owns true recovery; never force a wrong merge).
  if ! git --git-dir="$gd" merge-base "$ours" "$theirs" >/dev/null 2>&1; then
    printf 'dotfiles: %s: unrelated histories with origin/%s; refusing to merge (manual action needed)\n' "$repo" "$branch" >&2
    __df_debug "reconcile: $repo unrelated histories -> refuse, skip push"
    return 1
  fi

  # Try the merge without committing or fast-forwarding so we can resolve clashes ourselves.
  if git -C "$W" --git-dir="$gd" --work-tree="$W" merge --no-commit --no-ff "$theirs" >/dev/null 2>&1; then
    # Clean auto-merge (incl. same-file/different-lines). Commit it.
    git -C "$W" --git-dir="$gd" --work-tree="$W" commit --no-edit -q >/dev/null 2>&1 \
      || git -C "$W" --git-dir="$gd" --work-tree="$W" commit --no-edit -q --allow-empty >/dev/null 2>&1
    __df_debug "reconcile: $repo clean merge"
    return 0
  fi

  # Conflicts exist. Resolve EACH conflicted path, never blocking.
  local ts host
  ts="$(date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  host="$(hostname 2>/dev/null || printf '%s' "${HOSTNAME:-unknown}")"
  local sdir; sdir="$(__df_state_dir "$repo")"; mkdir -p "$sdir"
  local logf; logf="$(__df_conflicts_log "$repo")"
  local epoch; epoch="$(date +%s 2>/dev/null || printf '0')"

  # Iterate conflicted paths via `while IFS= read -r` over newline-delimited git output. This
  # NEVER relies on shell word-splitting of an unquoted expansion (which zsh disables by default),
  # so each $path is exactly one repo path even under zsh. A here-doc feeds the captured output so
  # the loop body runs in the CURRENT shell (a pipe would subshell it and lose $logf appends/state).
  local conflicted path
  conflicted="$(git -C "$W" --git-dir="$gd" --work-tree="$W" diff --name-only --diff-filter=U 2>/dev/null)"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    local has_ours has_theirs winner loser_sha enc
    has_ours="$(git -C "$W" --git-dir="$gd" --work-tree="$W" ls-files -u -- "$path" | awk '$3==2{print 1}' | head -n1)"
    has_theirs="$(git -C "$W" --git-dir="$gd" --work-tree="$W" ls-files -u -- "$path" | awk '$3==3{print 1}' | head -n1)"

    if [ -n "$has_ours" ] && [ -n "$has_theirs" ]; then
      # Content conflict: newest committer-date wins (per side's last commit touching the path).
      # Compare against the PINNED pre-merge SHAs ($ours/$theirs), never a re-resolved symbolic ref.
      local od td
      od="$(git --git-dir="$gd" log -1 --format=%ct "$ours"   -- "$path" 2>/dev/null)"; od="${od:-0}"
      td="$(git --git-dir="$gd" log -1 --format=%ct "$theirs" -- "$path" 2>/dev/null)"; td="${td:-0}"
      if [ "$td" -gt "$od" ]; then
        winner=theirs; loser_sha="$ours"
        git -C "$W" --git-dir="$gd" --work-tree="$W" checkout --theirs -- "$path" >/dev/null 2>&1
      else
        # Tie or ours newer -> ours wins (deterministic: committer-date, then ours-on-tie).
        winner=ours;   loser_sha="$theirs"
        git -C "$W" --git-dir="$gd" --work-tree="$W" checkout --ours -- "$path" >/dev/null 2>&1
      fi
    elif [ -n "$has_ours" ]; then
      # modify/delete: ours edited, theirs deleted -> edit-beats-delete (keep ours).
      winner=ours; loser_sha="$theirs"
      git -C "$W" --git-dir="$gd" --work-tree="$W" checkout --ours -- "$path" >/dev/null 2>&1
    else
      # modify/delete: theirs edited, ours deleted -> edit-beats-delete (keep theirs).
      winner=theirs; loser_sha="$ours"
      git -C "$W" --git-dir="$gd" --work-tree="$W" checkout --theirs -- "$path" >/dev/null 2>&1
    fi

    git -C "$W" --git-dir="$gd" --work-tree="$W" add -- "$path" >/dev/null 2>&1
    # Pin the losing side (LOCAL ref) so it is recoverable; record it in the local log. The loser
    # is a pinned pre-merge SHA ($ours or $theirs), guaranteed non-empty by the guards above, so
    # update-ref never receives an empty object name (the prior Linux "Not a valid object name").
    enc="$(__df_ref_enc "$path")"
    if [ -n "$loser_sha" ]; then
      git --git-dir="$gd" update-ref "refs/sync-losers/$enc/$epoch" "$loser_sha" 2>/dev/null \
        && __df_debug "reconcile: $repo pinned loser $loser_sha for $path"
    fi
    printf '%s\t%s\twinner=%s\tloser=%s\n' "$ts" "$path" "$winner" "${loser_sha:-none}" >> "$logf"
  done <<__DF_CONFLICTED__
$conflicted
__DF_CONFLICTED__

  # Any remaining unmerged paths? (Shouldn't be — but never leave the tree mid-merge.)
  if [ -n "$(git -C "$W" --git-dir="$gd" --work-tree="$W" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    __df_debug "reconcile: $repo residual conflicts; staging current work-tree"
    git -C "$W" --git-dir="$gd" --work-tree="$W" add -A >/dev/null 2>&1
  fi

  # Commit the merge (never --edit; never block on an editor).
  git -C "$W" --git-dir="$gd" --work-tree="$W" commit --no-edit -q >/dev/null 2>&1 \
    || git -C "$W" --git-dir="$gd" --work-tree="$W" commit --no-edit -q --allow-empty >/dev/null 2>&1
  __df_debug "reconcile: $repo merge resolved + committed"
  return 0
}

# --- Node 6: robustness — stale-state recovery + concurrent-tick lock. ----------------
# Contract for every behavior here: fail-isolated (one bad repo never aborts the loop over
# the others), fail-loud (clear message or safe default), never-corrupt (work-tree untouched),
# never-block.

# Resolve a bare repo's REAL git-dir (a "pure" bare repo IS the git-dir; a non-bare repo placed
# under bare-repos/ has its git-dir at <dir>/.git). Echo the path git itself uses for metadata.
__df_gitdir_real() {
  local gd="$1" real
  real="$(git --git-dir="$gd" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s' "$real"
}

# Age (in seconds) of a file, or a very large number if it can't be determined (treat unknown
# as "old enough to clear" only where the caller decides; here we just report). Portable across
# GNU/BSD stat; falls back to find -mmin if stat lacks the flags.
__df_file_age() {
  local f="$1" now mtime
  [ -e "$f" ] || { printf '%s' "-1"; return 1; }
  now="$(date +%s 2>/dev/null || printf '0')"
  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"
  if [ -n "$mtime" ] && [ "$mtime" -ge 0 ] 2>/dev/null; then
    printf '%s' "$((now - mtime))"
  else
    printf '%s' "999999"   # unknown mtime -> treat as old
  fi
}

# Recover stale state left by a crashed prior tick, BEFORE acting on the repo. Guarded + safe:
#   * a leftover MERGE_HEAD (crash mid-merge) -> `merge --abort` (work-tree restored), or a hard
#     reset to HEAD as a fallback, so the tree is clean before we stage/commit.
#   * a stale index.lock OLDER than a threshold (default 60s) -> remove it (a crashed tick never
#     cleaned up). A FRESH lock (younger than the threshold) is left alone: it may belong to a
#     live git process; the caller's tick-lock then makes us skip this cycle instead.
# Never deletes a fresh lock. Returns 0 always (recovery is best-effort, never fatal).
__df_recover_stale() {
  local repo="$1" gd="$2" rgd lock age thresh="${DOTFILES_LOCK_STALE:-60}"
  rgd="$(__df_gitdir_real "$gd")" || return 0
  # 1. leftover merge from a crashed tick -> abort it (restores work-tree), fall back to reset.
  if [ -f "$rgd/MERGE_HEAD" ]; then
    __df_debug "recover: $repo stale MERGE_HEAD -> merge --abort"
    git -C "$HOME" --git-dir="$gd" --work-tree="$HOME" merge --abort >/dev/null 2>&1 \
      || git -C "$HOME" --git-dir="$gd" --work-tree="$HOME" reset --hard -q HEAD >/dev/null 2>&1 \
      || rm -f "$rgd/MERGE_HEAD" "$rgd/MERGE_MSG" "$rgd/MERGE_MODE" 2>/dev/null
  fi
  # 2. stale index.lock older than the threshold -> remove (crashed tick never cleaned up).
  lock="$rgd/index.lock"
  if [ -f "$lock" ]; then
    age="$(__df_file_age "$lock")"
    if [ "$age" -ge "$thresh" ] 2>/dev/null; then
      __df_debug "recover: $repo stale index.lock (age ${age}s >= ${thresh}s) -> remove"
      rm -f "$lock" 2>/dev/null
    else
      __df_debug "recover: $repo fresh index.lock (age ${age}s) -> leave (may be live)"
    fi
  fi
  return 0
}

# Concurrent-tick lock: serialize ticks on ONE repo so two overlapping -tick runs never corrupt
# the index. Portable mutual exclusion via `mkdir` (atomic create-or-fail on every OS/filesystem).
# The lock dir lives under the repo's real git-dir. A STALE lock (older than the threshold, e.g.
# from a crashed tick) is reclaimed. If a LIVE tick holds the lock, we DO NOT block — the caller
# skips this repo this cycle and logs it (never-block). Echoes nothing; returns 0 = acquired,
# 1 = held by a live tick (skip this cycle).
__df_lock_acquire() {
  local repo="$1" gd="$2" rgd lockdir age thresh="${DOTFILES_LOCK_STALE:-60}"
  rgd="$(__df_gitdir_real "$gd")" || return 0   # can't resolve git-dir -> let the tick fail naturally
  lockdir="$rgd/dotfiles-tick.lock"
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s' "$$" > "$lockdir/pid" 2>/dev/null
    DF_LOCKDIR="$lockdir"
    return 0
  fi
  # Already locked. Reclaim it if it is stale (older than the threshold); else skip (live tick).
  age="$(__df_file_age "$lockdir")"
  if [ "$age" -ge "$thresh" ] 2>/dev/null; then
    __df_debug "lock: $repo reclaiming stale tick-lock (age ${age}s >= ${thresh}s)"
    rm -rf "$lockdir" 2>/dev/null
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s' "$$" > "$lockdir/pid" 2>/dev/null
      DF_LOCKDIR="$lockdir"
      return 0
    fi
  fi
  __df_debug "lock: $repo held by a live tick -> skip this cycle (never block)"
  return 1
}
__df_lock_release() {
  [ -n "${DF_LOCKDIR:-}" ] && rm -rf "$DF_LOCKDIR" 2>/dev/null
  DF_LOCKDIR=""
  return 0
}

# --- The generic tick (node 4): single-writer add -> commit -> push. ---
# Tick ONE repo. Gated by <repo>.tick (default OFF). Node 6 wraps the real work
# (__df_tick_one_body) with: skip non-repos / tick-off; a concurrent-tick lock (skip this cycle
# if a live tick holds it — never block); and stale-state recovery (abort a leftover merge, clear
# an aged index.lock) BEFORE acting. The lock is ALWAYS released on every exit path of the body.
# Fail-isolated by the caller's loop: a git error here returns nonzero but never aborts the loop.
__df_tick_one() {
  local repo="$1"
  local gd="$DOTFILES_ROOT/bare-repos/$repo"
  if ! __df_is_repo "$gd"; then
    __df_debug "tick: skip non-repo $repo"
    return 0
  fi
  if [ "$(__df_setting_tick "$repo")" != true ]; then
    __df_debug "tick: $repo tick is OFF -> skip"
    return 0
  fi
  # Serialize on this repo (never block): a live tick holds the lock -> skip this cycle + log.
  if ! __df_lock_acquire "$repo" "$gd"; then
    printf 'dotfiles: %s: a tick is already running for this repo; skipping this cycle\n' "$repo" >&2
    return 0
  fi
  # Recover stale state from a crashed prior tick BEFORE acting (abort leftover merge; clear aged lock).
  __df_recover_stale "$repo" "$gd"
  local rc
  __df_tick_one_body "$repo" "$gd"; rc=$?
  __df_lock_release
  return "$rc"
}

# The real per-repo tick work. Caller (__df_tick_one) has already validated the repo, checked the
# tick gate, acquired the lock, and recovered stale state. May return early; the caller releases.
__df_tick_one_body() {
  local repo="$1" gd="$2"
  local addflag
  addflag="$(__df_setting_add "$repo")"      # -A (all) or -u (tracked)

  # --- stage (scoped) ---
  if [ "$addflag" = "-A" ]; then
    # Scope -A to the repo's OWN tracked territory: the set of directories that already
    # contain tracked files (plus root-level tracked files themselves). `git add -A -- <dir>`
    # then picks up a NEW untracked file under a dir this repo owns, but can NEVER reach a
    # sibling repo's dir (e.g. .config/beta when this repo only tracks .config/alpha/*).
    # Deriving from ls-files (full depth) rather than ls-tree (top-level) is what keeps
    # repos sharing a parent dir like ~/.config strictly isolated.
    local files
    files="$(git --git-dir="$gd" --work-tree="$HOME" ls-files 2>/dev/null)"
    if [ -z "$files" ]; then
      # Unborn HEAD / no tracked files: can't scope -A safely -> fall back to tracked-only.
      __df_debug "tick: $repo no tracked files, -A scoping skipped (using -u)"
      git --git-dir="$gd" --work-tree="$HOME" add -u || { __df_debug "tick: $repo add -u failed"; return 1; }
    else
      # Unique owned pathspecs = parent dir of each tracked file ('.' collapses to root-level
      # files, which we list individually instead of '.' to avoid sweeping all of $HOME).
      local scope
      scope="$(printf '%s\n' "$files" | while IFS= read -r f; do
        d="$(dirname "$f")"
        if [ "$d" = "." ]; then printf '%s\n' "$f"; else printf '%s\n' "$d"; fi
      done | sort -u)"
      local oldifs="$IFS"; IFS='
'
      # shellcheck disable=SC2086
      set -- $scope
      IFS="$oldifs"
      git --git-dir="$gd" --work-tree="$HOME" add -A -- "$@" \
        || { __df_debug "tick: $repo add -A (scoped) failed"; return 1; }
    fi
  else
    git --git-dir="$gd" --work-tree="$HOME" add -u || { __df_debug "tick: $repo add -u failed"; return 1; }
  fi

  # --- commit only if something is staged ---
  if git --git-dir="$gd" --work-tree="$HOME" diff --cached --quiet; then
    __df_debug "tick: $repo nothing staged -> no commit"
  else
    local ts host
    ts="$(date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    host="$(hostname 2>/dev/null || printf '%s' "${HOSTNAME:-unknown}")"
    git --git-dir="$gd" --work-tree="$HOME" commit -q -m "$repo: auto $ts $host" \
      || { __df_debug "tick: $repo commit failed"; return 1; }
    __df_debug "tick: $repo committed"
  fi

  # --- reconcile with origin, then push (bounded retry); never block. ---
  # Only repos with an upstream participate in fetch/merge/push.
  if git --git-dir="$gd" --work-tree="$HOME" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    # Derive the branch from HEAD (detached HEAD has no branch to sync -> skip; node 6 surfaces it).
    local branch
    branch="$(git --git-dir="$gd" symbolic-ref --short -q HEAD 2>/dev/null)"
    if [ -z "$branch" ]; then
      __df_debug "tick: $repo detached HEAD -> skip push (no branch to sync)"
      return 0
    fi
    # Bounded push loop: reconcile (fetch+never-block merge) then push; on non-fast-forward
    # rejection, re-reconcile and retry. After the ceiling, LOG + skip (do NOT fail the tick).
    local attempt=0 max=3 pushed=0
    while [ "$attempt" -lt "$max" ]; do
      attempt=$((attempt+1))
      if ! __df_reconcile "$repo" "$gd" "$branch"; then
        __df_debug "tick: $repo reconcile said skip push (attempt $attempt)"
        break
      fi
      if git --git-dir="$gd" --work-tree="$HOME" push -q origin "$branch" 2>/dev/null; then
        __df_debug "tick: $repo pushed (attempt $attempt)"
        pushed=1
        break
      fi
      __df_debug "tick: $repo push rejected (attempt $attempt) -> re-reconcile"
    done
    if [ "$pushed" -ne 1 ]; then
      __df_debug "tick: $repo push not completed after $attempt attempt(s) -> logged + skipped (work-tree intact)"
      printf 'dotfiles: %s: push to origin/%s not completed this tick (will retry next tick)\n' "$repo" "$branch" >&2
      return 1
    fi
  else
    __df_debug "tick: $repo no upstream configured -> skip push"
  fi
  return 0
}

# `dotfiles -tick [<repo>]`: tick one repo, or loop every repo under bare-repos/.
# Fail-isolation: a git error in one repo is caught + logged; the loop continues.
__df_tick() {
  if [ -n "${1:-}" ]; then
    __df_tick_one "$1"
    return $?
  fi
  local base d name rc=0; base="$(__df_repos_dir)"
  [ -d "$base" ] || return 0
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    __df_is_repo "$d" || { __df_debug "tick: skip non-repo under bare-repos/: $name"; continue; }
    __df_tick_one "$name" || { rc=1; __df_debug "tick: $name errored (isolated, continuing)"; }
  done
  return "$rc"
}

# --- Node 7: -doctor — health + the load-bearing exclusive-ownership invariant. -------
# Prints an engine line, a per-repo status line, an ownership (overlap) check, and a
# warnings/info block. EVERY problem prints an ACTIONABLE fix line. Exit policy: nonzero
# ONLY when at least one ERROR exists (a path tracked by >1 repo, or a corrupt/non-git repo
# under bare-repos/). Warnings (no upstream / detached HEAD / hooksPath unset/missing) and
# info (tick off) do NOT fail the exit code. See plan "F. Expected command outputs" and
# "G. Doctor — error cases".
#
# The shared hooks dir every repo's core.hooksPath should point at.
__df_hooks_target() { printf '%s/githooks' "$DOTFILES_COMMON"; }

__df_doctor() {
  emulate -L sh 2>/dev/null || true
  local errors=0 warnings=0
  # Collected lines, emitted after the per-repo block so the layout matches plan F/G.
  local warn_lines="" overlap_lines="" ownership_summary=""

  # --- engine line -------------------------------------------------------------------
  local ecommon="$DOTFILES_COMMON"
  if git --git-dir="$ecommon/.git" rev-parse --git-dir >/dev/null 2>&1; then
    local ebranch eupstream behind
    ebranch="$(git -C "$ecommon" symbolic-ref --short -q HEAD 2>/dev/null)"
    [ -n "$ebranch" ] || ebranch="(detached)"
    if eupstream="$(git -C "$ecommon" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" && [ -n "$eupstream" ]; then
      behind="$(git -C "$ecommon" rev-list --count "HEAD..@{u}" 2>/dev/null)"
      if [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
        printf 'engine:  %s  branch %s, %s commit(s) behind %s\n' "$ecommon" "$ebranch" "$behind" "$eupstream"
        warn_lines="${warn_lines}  engine: behind upstream by $behind commit(s)   fix -> dotfiles --update
"
        warnings=$((warnings+1))
      else
        printf 'engine:  %s  branch %s, up to date\n' "$ecommon" "$ebranch"
      fi
    else
      printf 'engine:  %s  branch %s (no upstream)\n' "$ecommon" "$ebranch"
    fi
  else
    # L5.26: the engine dir exists but is NOT a git repo -> `dotfiles --update` would fail. ERROR.
    printf 'engine:  %s  NOT a git repo\n' "$ecommon"
    warn_lines="${warn_lines}  engine: $ecommon is not a git repo (dotfiles --update would fail)   fix -> re-clone the engine into it
"
    errors=$((errors+1))
  fi

  # --- per-repo block + overlap accounting -------------------------------------------
  local base; base="$(__df_repos_dir)"
  printf 'repos:\n'
  # Accumulate "path\trepo" pairs across all repos for the overlap pass.
  local owners="" total_paths=0 repo_count=0
  if [ -d "$base" ]; then
    local d repo gd
    for d in "$base"/*/; do
      [ -d "$d" ] || continue
      repo="$(basename "$d")"
      gd="$d"
      if ! __df_is_repo "$gd"; then
        # A stray / corrupt dir under bare-repos/ -> note + ERROR (it can't be ticked).
        printf '  %-8s NOT a git repo (skipped)\n' "$repo"
        warn_lines="${warn_lines}  $repo: not a git repo under bare-repos/   fix -> remove $d or restore the repo
"
        errors=$((errors+1))
        continue
      fi
      repo_count=$((repo_count+1))

      # branch / upstream
      local branch upstream tickv addv hooks hp
      branch="$(git --git-dir="$gd" symbolic-ref --short -q HEAD 2>/dev/null)"
      if [ -z "$branch" ]; then
        # Distinguish detached HEAD (a commit) from a truly unborn/missing HEAD.
        if git --git-dir="$gd" rev-parse --verify -q HEAD >/dev/null 2>&1; then
          branch="detached"
        else
          branch="none"
        fi
      fi
      if upstream="$(git --git-dir="$gd" --work-tree="$HOME" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" && [ -n "$upstream" ]; then
        :
      else
        upstream="(none)"
      fi

      # settings
      if [ "$(__df_setting_tick "$repo" 2>/dev/null)" = true ]; then tickv="on"; else tickv="off"; fi
      if [ "$(__df_setting_add "$repo" 2>/dev/null)" = "-A" ]; then addv="all"; else addv="tracked"; fi

      # hooks: core.hooksPath set AND its target dir exists -> wired; else MISSING.
      hp="$(git --git-dir="$gd" config --get core.hooksPath 2>/dev/null)"
      if [ -n "$hp" ] && [ -d "$hp" ]; then
        hooks="wired"
      else
        hooks="MISSING"
      fi

      printf '  %-8s branch %-8s upstream %-16s tick:%-3s add:%-7s hooks:%s\n' \
        "$repo" "$branch" "$upstream" "$tickv" "$addv" "$hooks"

      # --- warnings / info per repo (each with a fix) ---
      if [ "$upstream" = "(none)" ] && [ "$branch" != "detached" ] && [ "$branch" != "none" ]; then
        warn_lines="${warn_lines}  $repo: no upstream for '$branch'   fix -> dotfiles $repo push -u origin $branch
"
        warnings=$((warnings+1))
      fi
      if [ "$branch" = "detached" ]; then
        warn_lines="${warn_lines}  $repo: detached HEAD (no branch)   fix -> dotfiles $repo checkout <branch>
"
        warnings=$((warnings+1))
      elif [ "$branch" = "none" ]; then
        warn_lines="${warn_lines}  $repo: no HEAD branch   fix -> dotfiles $repo checkout <branch>
"
        warnings=$((warnings+1))
      fi
      if [ -z "$hp" ]; then
        warn_lines="${warn_lines}  $repo: core.hooksPath not set   fix -> dotfiles $repo config core.hooksPath \"\$HOME/.dotfiles/common/githooks\"
"
        warnings=$((warnings+1))
        # L5.24: tick is ON but hooks are not wired -> a louder note (auto-commits run no hooks).
        if [ "$tickv" = "on" ]; then
          warn_lines="${warn_lines}  $repo: tick is ON but core.hooksPath is unset (auto-commits run no hooks)   fix -> dotfiles $repo config core.hooksPath \"\$HOME/.dotfiles/common/githooks\"
"
          warnings=$((warnings+1))
        fi
      elif [ ! -d "$hp" ]; then
        # L5.6 / L5.25: hooksPath set but the target dir is missing (partial migration / wrong path).
        warn_lines="${warn_lines}  $repo: core.hooksPath set to '$hp' but that dir is missing   fix -> dotfiles $repo config core.hooksPath \"$(__df_hooks_target)\"
"
        warnings=$((warnings+1))
      fi
      if [ "$tickv" = "off" ]; then
        warn_lines="${warn_lines}  $repo: tick is OFF (won't sync)   info -> dotfiles -config $repo.tick on
"
        # info, not a warning -> does NOT bump the warning count or exit code.
      fi

      # --- ownership accounting: record every tracked path -> repo ---
      local lf path
      lf="$(git --git-dir="$gd" --work-tree="$HOME" ls-files 2>/dev/null)"
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        total_paths=$((total_paths+1))
        owners="${owners}${path}	${repo}
"
      done <<__DF_LSFILES__
$lf
__DF_LSFILES__
    done
  fi

  # --- overlap pass (THE big one): any path owned by >1 repo is an ERROR. -------------
  # Group the path<TAB>repo lines by path; a path with >1 distinct repo overlaps.
  local dup
  dup="$(printf '%s' "$owners" | sort | awk -F'\t' '
    NF>=2 {
      if ($1==prev) { repos = repos ", " $2; n++ }
      else {
        if (n>1) print prev "\t" repos;
        prev=$1; repos=$2; n=1
      }
    }
    END { if (n>1) print prev "\t" repos }
  ')"

  printf 'ownership: '
  if [ -n "$dup" ]; then
    printf 'OVERLAP\n'
    while IFS="	" read -r path repos; do
      [ -n "$path" ] || continue
      # The fix targets the SECOND owner listed (the one to release), per plan G.
      local wrong
      wrong="$(printf '%s' "$repos" | awk -F', ' '{print $2}')"
      printf '  %s   tracked by: %s\n' "$path" "$repos"
      printf '    fix -> dotfiles %s rm --cached %s\n' "$wrong" "$path"
      errors=$((errors+1))
    done <<__DF_DUP__
$dup
__DF_DUP__
  else
    printf '%d paths across %d repos, no overlaps\n' "$total_paths" "$repo_count"
  fi

  # --- warnings / info block ---------------------------------------------------------
  if [ -n "$warn_lines" ]; then
    printf 'warnings:\n'
    printf '%s' "$warn_lines"
  fi

  # --- final summary + exit code -----------------------------------------------------
  if [ "$errors" -eq 0 ]; then
    printf 'all checks passed\n'
    return 0
  fi
  printf '%d error(s), %d warning(s)\n' "$errors" "$warnings"
  return 1
}

# -show: print each repo's recorded conflicts (state/<repo>/conflicts.log), or "(no conflicts)".
# Greppable: one "<repo>:\t<logline>" per clash. LOCAL state only.
__df_show() {
  local base d repo logf any=0
  base="$(__df_repos_dir)"
  [ -d "$base" ] || { printf '(no conflicts)\n'; return 0; }
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    repo="$(basename "$d")"
    __df_is_repo "$d" || continue
    logf="$(__df_conflicts_log "$repo")"
    if [ -s "$logf" ]; then
      any=1
      while IFS= read -r line; do
        [ -n "$line" ] && printf '%s:\t%s\n' "$repo" "$line"
      done < "$logf"
    else
      printf '%s:\t(no conflicts)\n' "$repo"
    fi
  done
  [ "$any" -eq 0 ] && __df_debug "show: no conflicts recorded in any repo"
  return 0
}

# -resolve <path>: find the most recent pinned loser for <path> across repos, write its
# blob beside the live file as <path>.loser, and print a winner-vs-loser header. Exit 0;
# clear message + exit 1 if no loser is recorded for that path.
__df_resolve() {
  # zsh word-splitting compat (see __df_reconcile): the for-each-ref loop below iterates
  # newline-delimited git output; zsh won't word-split it without sh emulation. Function-scoped.
  emulate -L sh 2>/dev/null || true
  local path="$1"
  if [ -z "$path" ]; then
    printf 'dotfiles -resolve: usage: dotfiles -resolve <path>\n' >&2
    return 2
  fi
  # Normalize to a repo-relative path (strip a leading $HOME/ or ~/).
  case "$path" in
    "$HOME"/*) path="${path#"$HOME"/}" ;;
    "~/"*)     path="${path#~/}" ;;
  esac
  local enc; enc="$(__df_ref_enc "$path")"
  local base d repo gd best_repo="" best_gd="" best_ref="" best_epoch=-1 ref epoch
  base="$(__df_repos_dir)"
  [ -d "$base" ] || { printf 'dotfiles -resolve: no repos\n' >&2; return 1; }
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    repo="$(basename "$d")"; gd="$d"
    __df_is_repo "$gd" || continue
    # Most-recent loser = highest epoch suffix under refs/sync-losers/<enc>/. Iterate via
    # `while read` over newline-delimited refs so it never depends on shell word-splitting.
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      epoch="${ref##*/}"
      case "$epoch" in ''|*[!0-9]*) continue ;; esac
      if [ "$epoch" -gt "$best_epoch" ]; then
        best_epoch="$epoch"; best_ref="$ref"; best_repo="$repo"; best_gd="$gd"
      fi
    done <<__DF_LOSER_REFS__
$(git --git-dir="$gd" for-each-ref --format='%(refname)' "refs/sync-losers/$enc" 2>/dev/null)
__DF_LOSER_REFS__
  done
  if [ -z "$best_ref" ]; then
    printf 'dotfiles -resolve: no recorded loser for %s\n' "$path" >&2
    return 1
  fi
  local loser_sha blob
  loser_sha="$(git --git-dir="$best_gd" rev-parse --verify -q "$best_ref" 2>/dev/null)"
  # Extract the path's blob from the loser commit WITHOUT the <rev>:<path> colon syntax
  # (Git-for-Windows mangles the colon). Use ls-tree to find the blob, cat-file to dump it.
  blob="$(git --git-dir="$best_gd" ls-tree -r "$loser_sha" -- "$path" 2>/dev/null | awk '{print $3}' | head -n1)"
  local out="$HOME/$path.loser"
  mkdir -p "$(dirname "$out")"
  if [ -n "$blob" ]; then
    git --git-dir="$best_gd" cat-file -p "$blob" > "$out" 2>/dev/null
  else
    : > "$out"   # loser had no blob (it was the delete side); empty .loser marks that.
  fi
  printf 'clash in repo %s   loser=%s\n' "$best_repo" "$loser_sha"
  printf -- '--- winner (current file) ---     --- loser (%s) ---\n' "$loser_sha"
  printf 'loser written to: %s   (merge by hand, then rm it)\n' "$out"
  return 0
}

dotfiles() {
  local root="$DOTFILES_ROOT" tok verb repo
  tok="${1-}"
  case "$tok" in
    '')
      __df_ls; return 0 ;;
    -*)
      verb="${tok#-}"; verb="${verb#-}"          # strip one OR two leading dashes
      shift
      # HEAVY verbs run under bash, always. The dispatcher is sourced into the user's
      # INTERACTIVE shell, which may be zsh, and the git-heavy paths (tick/show/resolve/
      # doctor) depend on shell-DIALECT behavior that diverges between bash and zsh:
      # word-splitting of unquoted "$var"/"$(cmd)" (zsh leaves SH_WORD_SPLIT off) and
      # array/IFS semantics. We tried per-construct zsh fixes (emulate -L sh; while-read
      # loops — kept below as good hygiene) but the macOS zsh CI leg kept failing the merge
      # tests with "fatal: Needed a single revision" / "Not a valid object name". Rather than
      # chase every divergence, run these verbs under ONE shell: if we're NOT in bash, re-exec
      # the whole command via `bash "$DOTFILES_SELF" <tok> <args>`. CRITICAL: re-exec the REAL
      # script path (DOTFILES_SELF, computed at load from this file's own location), NOT
      # "$DOTFILES_COMMON/dotfiles.sh" — DOTFILES_COMMON is env-overridable so the doctor engine
      # tests (L0.19 engine-behind, L5.26 engine-not-git) can point it at a FAKE engine dir with
      # no dotfiles.sh; re-execing that path dies with rc 127 / "No such file or directory" on the
      # zsh leg (ubuntu runs bash directly, pwsh runs natively — neither re-execs). The
      # bottom-of-file guard then re-enters dotfiles() UNDER bash (BASH_VERSION set there), where
      # this same `[ -z "${BASH_VERSION:-}" ]` test is FALSE — so the child runs the real body and
      # never re-execs again (no recursion). DOTFILES_ROOT and DOTFILES_COMMON are forwarded
      # through the env so the bash child resolves the same root AND still inspects the (possibly
      # fake) engine dir the test set; HOME is already inherited. Lightweight verbs are unaffected.
      case "$verb" in
        tick|show|resolve|doctor)
          if [ -z "${BASH_VERSION:-}" ]; then
            DOTFILES_ROOT="$DOTFILES_ROOT" DOTFILES_COMMON="$DOTFILES_COMMON" bash "$DOTFILES_SELF" "$tok" "$@"
            return $?
          fi
          ;;
      esac
      case "$verb" in
        h|help)  __df_help ;;
        ls)      __df_ls ;;
        config)  __df_config "$@" ;;
        update)  __df_update "$@" ;;
        timer)   __df_timer "$@" ;;
        tick)    __df_tick "$@" ;;
        doctor)  __df_doctor "$@" ;;
        show)    __df_show "$@" ;;
        resolve) __df_resolve "$@" ;;
        *) printf 'dotfiles: unknown command -%s (try --help)\n' "$verb" >&2; return 2 ;;
      esac
      return $?
      ;;
  esac
  # Bare first token => repo name. Repo always wins over verb names (a repo may be named "show").
  repo="$tok"; shift
  if ! __df_is_repo "$root/bare-repos/$repo"; then
    printf 'dotfiles: no such repo: %s (try --ls)\n' "$repo" >&2
    return 1
  fi
  __df_debug "git on repo=$repo args=$*"
  git --git-dir="$root/bare-repos/$repo" --work-tree="$HOME" "$@"
}

# Run as a command when executed directly under bash (tests). Harmless when sourced or under zsh.
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  dotfiles "$@"
fi
