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
if [ -n "${BASH_SOURCE:-}" ]; then
  DOTFILES_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  DOTFILES_COMMON="$(cd "$(dirname "$0")" && pwd)"
fi
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

# --- The generic tick (node 4): single-writer add -> commit -> push. ---
# Tick ONE repo. Gated by <repo>.tick (default OFF). Staging is SCOPED to the repo's own
# tracked territory (never `git add -A` across all of $HOME). Push only if an upstream exists.
# Fail-isolated by the caller's loop: a git error here returns nonzero but never aborts the loop.
__df_tick_one() {
  local repo="$1"
  local gd="$DOTFILES_ROOT/bare-repos/$repo"
  local addflag
  if ! __df_is_repo "$gd"; then
    __df_debug "tick: skip non-repo $repo"
    return 0
  fi
  if [ "$(__df_setting_tick "$repo")" != true ]; then
    __df_debug "tick: $repo tick is OFF -> skip"
    return 0
  fi
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

# --- Heavy verbs: -doctor stubbed (node 7); -show/-resolve implemented (node 5). ---
__df_doctor()  { printf 'dotfiles -doctor: not implemented yet (build node 7)\n' >&2; return 3; }

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
      # the whole command via `bash dotfiles.sh <tok> <args>`. The bottom-of-file guard then
      # re-enters dotfiles() UNDER bash (BASH_VERSION set there), where this same `[ -z
      # "${BASH_VERSION:-}" ]` test is FALSE — so the child runs the real body and never
      # re-execs again (no recursion). DOTFILES_ROOT is passed through the env so the child
      # resolves the same root; HOME is already inherited. Lightweight verbs are unaffected.
      case "$verb" in
        tick|show|resolve|doctor)
          if [ -z "${BASH_VERSION:-}" ]; then
            DOTFILES_ROOT="$DOTFILES_ROOT" bash "$DOTFILES_COMMON/dotfiles.sh" "$tok" "$@"
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
