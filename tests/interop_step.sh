#!/usr/bin/env bash
# Node 11 — cross-OS interop step (L4.1-L4.6). ONE bash script, run on every OS leg:
#   - ubuntu / macos:  native bash
#   - windows:         Git-for-Windows bash (the same sh.exe family that runs the hooks),
#                      invoked from the pwsh wrapper interop_step.ps1 OR directly via `shell: bash`.
# Using a single bash implementation (not a parallel pwsh port) is deliberate: the whole point of
# L4 is that the SAME engine + SAME repo round-trips across OSes. A second implementation would
# test the test, not the engine. The win-gitbash bash leg is exactly the environment the dotfiles
# hooks already run under (see test_hooks.sh / PITFALLS "Git-for-Windows sh.exe"), so it is the
# faithful Windows surface to exercise.
#
# Subcommands (each job in interop.yml runs one):
#   seed              create a FRESH bare `origin` + initial content (the ubuntu seed job)
#   leg <os-label>    clone a machine from origin, edit text+nested+exec, `dotfiles -tick` -> push
#   verify            clone origin fresh and run the L4.1-L4.6 assertions over the full history
#
# Shared `origin` travels between jobs as a GitHub Actions artifact (a tar of the bare repo).
# The repo under sync is named `interop`; its branch is `sync` (multi-writer, like an nvim repo).
#
# Greppable banners match the rest of the harness:
#   === <id> <GOOD|BAD> START ===            === <id> RESULT=PASS|FAIL (...) ===
#   === SUMMARY pass=.. fail=.. skip=.. ===
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$(dirname "$HERE")"                 # the checked-out template == ~/.dotfiles/common
REPO=interop
BRANCH=sync

# Work area: all interop state lives under $INTEROP_WORK (a fixed, job-local dir so the artifact
# up/download path is predictable). Default to a temp dir for local dry-runs.
INTEROP_WORK="${INTEROP_WORK:-$(mktemp -d)}"
ORIGIN="$INTEROP_WORK/origin.git"           # the shared bare remote (artifact payload)
export INTEROP_WORK ORIGIN

# --- banners / counters (mirror harness.sh) -------------------------------------------
_PASS=0; _FAIL=0; _SKIP=0; CURRENT="?"
t_start() { CURRENT="$1"; printf '=== %s %s START ===\n' "$1" "${2:-GOOD}"; }
pass()    { _PASS=$((_PASS+1)); printf '=== %s RESULT=PASS ===\n' "$CURRENT"; }
fail()    { _FAIL=$((_FAIL+1)); printf '=== %s RESULT=FAIL (%s) ===\n' "$CURRENT" "$1"; }
skip()    { _SKIP=$((_SKIP+1)); printf '=== %s RESULT=SKIP (%s) ===\n' "$CURRENT" "$1"; }
summary() { printf '=== SUMMARY pass=%d fail=%d skip=%d ===\n' "$_PASS" "$_FAIL" "$_SKIP"; [ "$_FAIL" -eq 0 ]; }

note() { printf '%s\n' "--- interop: $*"; }

# Deterministic git identity via the environment (survives the HOME swap each setup_machine does;
# a `git config --global` would land in whichever HOME is active and get lost when HOME changes).
export GIT_AUTHOR_NAME="interop"  GIT_AUTHOR_EMAIL="interop@example.test"
export GIT_COMMITTER_NAME="interop" GIT_COMMITTER_EMAIL="interop@example.test"
# Allow git to operate on the checkout regardless of ownership (CI checkout dir ownership).
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="safe.directory" GIT_CONFIG_VALUE_0='*'

# Build a per-leg dotfiles machine that uses THIS engine + the shared origin.
#   $HOME(leg) = $INTEROP_WORK/home ; $DOTFILES_ROOT = $INTEROP_WORK/dot ; common -> engine.
# Returns with: bare-repos/interop checked out on $BRANCH, upstream set, tick enabled.
setup_machine() {
  local home="$INTEROP_WORK/home" root="$INTEROP_WORK/dot" gd
  gd="$root/bare-repos/$REPO"
  rm -rf "$home" "$root"
  mkdir -p "$home" "$root/bare-repos"
  # common/ points at the engine under test (a symlink would do; copy-free is fine since we only
  # source dotfiles.sh). The dispatcher resolves DOTFILES_COMMON from env, so just export it.
  export HOME="$home" DOTFILES_ROOT="$root" DOTFILES_COMMON="$ENGINE"
  # Clone the machine the same robust way the harness builds a 2nd machine: init --bare + remote
  # add (installs the standard refspec) + fetch + checkout -B (a plain `clone --bare` sets NO
  # fetch refspec, so there'd be no @{upstream} for the tick to push to — see PITFALLS).
  git init --bare -q "$gd"
  git --git-dir="$gd" --work-tree="$home" symbolic-ref HEAD "refs/heads/$BRANCH"
  git --git-dir="$gd" remote add origin "$ORIGIN"
  git --git-dir="$gd" fetch -q origin
  git --git-dir="$gd" --work-tree="$home" checkout -q -B "$BRANCH" "origin/$BRANCH"
  # Enable tick + take untracked files too (so a brand-new nested path on this OS gets committed).
  git config -f "$root/config" "$REPO.tick" on
  git config -f "$root/config" "$REPO.add" all
  # Source the engine so `dotfiles -tick` is the real engine under test.
  # shellcheck disable=SC1090
  . "$ENGINE/dotfiles.sh"
}

# Run the engine tick for the interop repo as the current leg's machine.
run_tick() { dotfiles -tick "$REPO"; }

# Object-only helpers that avoid the Git-for-Windows `<rev>:<path>` colon trap (PITFALLS):
# use ls-tree + cat-file, never `git show <rev>:<path>`.
blob_at() {  # blob_at <gitdir> <rev> <path>  -> file content at that rev (LF/CRLF preserved)
  local gd="$1" rev="$2" path="$3" sha
  sha="$(git --git-dir="$gd" ls-tree -r "$rev" -- "$path" 2>/dev/null | awk '{print $3}')"
  [ -n "$sha" ] && git --git-dir="$gd" cat-file -p "$sha"
}
tree_paths() { git --git-dir="$1" ls-tree -r --name-only "${2:-$BRANCH}"; }

# Robust CR detector. Git-Bash `grep -q $'\r'` (and `grep -P '\r'`) FALSELY report no-match
# because grep treats the stream as text and strips CR before matching — so a CRLF blob looks LF
# to grep. Count 0x0d bytes via `od` instead (byte-exact, identical on linux/macos/git-bash).
# Usage: has_cr <string>  -> rc 0 if the string contains a CR byte, else rc 1.
has_cr() {
  local n
  n="$(printf '%s' "$1" | od -An -tx1 2>/dev/null | tr ' ' '\n' | grep -c '^0d')"
  [ "${n:-0}" -gt 0 ]
}

# =====================================================================================
# seed — the ubuntu seed job: build a fresh shared origin with the initial committed state.
# Establishes the .gitattributes that make the round-trip normalize (the control for L4.1/L4.2).
# =====================================================================================
do_seed() {
  note "seed: building fresh origin at $ORIGIN"
  rm -rf "$ORIGIN"
  git init --bare -q "$ORIGIN"
  # Build the seed machine inline (setup_machine assumes origin ALREADY has $BRANCH; a fresh origin
  # does not, so we can't checkout origin/$BRANCH yet). Wire HOME/ROOT/COMMON the same way.
  local home="$INTEROP_WORK/home" root="$INTEROP_WORK/dot" gd
  gd="$root/bare-repos/$REPO"
  rm -rf "$home" "$root"
  mkdir -p "$home" "$root/bare-repos"
  export HOME="$home" DOTFILES_ROOT="$root" DOTFILES_COMMON="$ENGINE"
  git init --bare -q "$gd"
  git --git-dir="$gd" --work-tree="$home" symbolic-ref HEAD "refs/heads/$BRANCH"
  git --git-dir="$gd" remote add origin "$ORIGIN"

  # --- .gitattributes: the load-bearing normalization, plus a DELIBERATE control opt-out. ---
  # `* text=auto` => text blobs stored LF in the repo regardless of the OS that committed.
  # `legacy/raw.txt -text` => explicitly OPT THIS PATH OUT of normalization (the control): bytes
  #   are stored verbatim, so if a CRLF version is committed it STAYS CRLF in the blob. L4.1/L4.2
  #   assert the covered file is LF AND the control file keeps whatever bytes were written -> proves
  #   the attribute (not luck) is what normalizes the covered file.
  cat > "$home/.gitattributes" <<'EOF'
* text=auto
legacy/raw.txt -text
EOF

  # Text file that WILL be normalized (covered by `* text=auto`).
  mkdir -p "$home/.config/$REPO"
  printf 'line1\nline2\nline3\n' > "$home/.config/$REPO/text.conf"

  # Control file that is OPTED OUT of normalization (`-text`). Seed it with CRLF on purpose.
  mkdir -p "$home/legacy"
  printf 'raw1\r\nraw2\r\n' > "$home/legacy/raw.txt"

  # Nested path (L4.6): a deep forward-slash path that each OS will edit.
  mkdir -p "$home/.config/$REPO/app/sub/dir"
  printf 'nested-seed\n' > "$home/.config/$REPO/app/sub/dir/file"

  # Executable script (L4.3): mode must be stable across the round-trip.
  printf '#!/bin/sh\necho hi\n' > "$home/.config/$REPO/run.sh"
  chmod +x "$home/.config/$REPO/run.sh"

  # Clash base (L4.5): a single-line file that two later legs overwrite with different pinned dates.
  printf 'base\n' > "$home/.config/$REPO/clash.conf"

  git --git-dir="$gd" --work-tree="$home" add -A
  GIT_AUTHOR_DATE='2020-01-01T00:00:00' GIT_COMMITTER_DATE='2020-01-01T00:00:00' \
    git --git-dir="$gd" --work-tree="$home" commit -q -m "$REPO: seed (ubuntu)"
  git --git-dir="$gd" --work-tree="$home" push -q -u origin "$BRANCH"
  # A bare origin's symbolic HEAD is unset by default; set it so a fresh `clone` knows the branch.
  git --git-dir="$ORIGIN" symbolic-ref HEAD "refs/heads/$BRANCH"

  note "seed: origin tree ="; tree_paths "$ORIGIN" | sed 's/^/    /'
  note "seed done"
}

# =====================================================================================
# leg <os-label> — clone the machine, make OS-specific edits, tick (commit + push).
# Each OS edits a DISTINCT line of the nested file (so L4.6 stays a clean fast-forward chain),
# touches the covered text file, and (on POSIX) keeps the exec bit. The os-label is recorded.
# =====================================================================================
do_leg() {
  local os="${1:?leg needs an os-label}"
  note "leg [$os]: clone + edit + tick"
  setup_machine
  local home="$HOME" gd="$DOTFILES_ROOT/bare-repos/$REPO"

  # 1) Append a line to the COVERED text file. On the Windows leg, write CRLF on purpose: the
  #    blob must STILL be stored LF (L4.2 — no CRLF leakage), because `* text=auto` normalizes it.
  if [ "$os" = "windows" ]; then
    printf 'win-edit\r\n' >> "$home/.config/$REPO/text.conf"
  else
    printf '%s-edit\n' "$os" >> "$home/.config/$REPO/text.conf"
  fi

  # 2) Edit the NESTED path (L4.6) — one logical forward-slash path, appended per OS.
  printf '%s-nested\n' "$os" >> "$home/.config/$REPO/app/sub/dir/file"

  # 3) Re-assert the exec bit on POSIX (L4.3). On Windows there is no exec bit to set; the tree
  #    mode is what we assert later, and git preserves the committed 100755 across a content-less
  #    leg as long as nobody rewrites the file. The Windows leg does NOT touch run.sh, so its
  #    committed mode rides through untouched.
  case "$os" in
    windows) : ;;                                   # leave run.sh alone (no exec bit on Windows)
    *) chmod +x "$home/.config/$REPO/run.sh" ;;
  esac

  # Pin dates so the LAST writer is deterministically newest (L4.5 uses this in the clash leg).
  # Order of legs is seed(2020) -> ubuntu? no: chain is seed(ubuntu) -> windows -> macos -> verify.
  # Give each leg a strictly increasing date so newest-wins is unambiguous regardless of push order.
  local d
  case "$os" in
    windows) d='2021-01-01T00:00:00' ;;
    macos)   d='2022-01-01T00:00:00' ;;
    *)       d='2023-01-01T00:00:00' ;;
  esac
  export GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d"

  # Drive the REAL engine tick: stages owned paths (add=all, scoped), commits, reconciles, pushes.
  if run_tick; then note "leg [$os]: tick ok"; else note "leg [$os]: tick returned nonzero (see log)"; fi

  # Show what landed on origin this leg.
  note "leg [$os]: origin tip ="; git --git-dir="$ORIGIN" log --oneline -3 "$BRANCH" | sed 's/^/    /'
  note "leg [$os] done"
}

# =====================================================================================
# verify — fresh clone of origin; run L4.1-L4.6 over the accumulated cross-OS history.
# =====================================================================================
do_verify() {
  note "verify: fresh clone of origin"
  local v="$INTEROP_WORK/verify"
  rm -rf "$v"
  git clone -q --branch "$BRANCH" "file://$ORIGIN" "$v"
  local gd="$v/.git"
  note "verify: ls-files ="; git -C "$v" ls-files | sed 's/^/    /'
  note "verify: log ="; git -C "$v" log --oneline | sed 's/^/    /'

  # -------- L4.6 path handling: forward-slash paths only; ONE logical nested path. --------
  t_start L4.6 GOOD
  local files; files="$(git -C "$v" ls-files)"
  if printf '%s\n' "$files" | grep -q '\\'; then
    fail "ls-files contains a backslash path: $(printf '%s\n' "$files" | grep '\\')"
  else
    # exactly one entry for the nested file, spelled with forward slashes.
    local nested; nested="$(printf '%s\n' "$files" | grep -c '^\.config/'"$REPO"'/app/sub/dir/file$')"
    if [ "$nested" -eq 1 ]; then pass; else fail "expected 1 nested entry, got $nested"; fi
  fi

  # -------- L4.1 round-trip: only intended edits; covered text file is LF (no churn). --------
  # The covered file accumulated one line per OS. Assert: (a) all OS edits present, (b) the blob
  # has NO carriage returns despite the Windows leg writing CRLF (proves normalization, not churn).
  t_start L4.1 GOOD
  local covered; covered="$(blob_at "$gd" "$BRANCH" ".config/$REPO/text.conf")"
  local ok=1
  case "$covered" in *win-edit*) : ;; *) ok=0; note "L4.1 missing win-edit";; esac
  case "$covered" in *macos-edit*) : ;; *) ok=0; note "L4.1 missing macos-edit";; esac
  case "$covered" in *line1*) : ;; *) ok=0; note "L4.1 missing seed line1";; esac
  if [ "$ok" -ne 1 ]; then
    fail "covered text.conf missing an expected OS edit"
  elif has_cr "$covered"; then
    fail "covered text.conf blob contains CR (line-ending churn / CRLF leak)"
  else
    pass
  fi

  # -------- L4.1 CONTROL: the OPTED-OUT file keeps its raw CRLF bytes (attribute is load-bearing). --------
  # If `.gitattributes` were decorative, the covered file would ALSO be raw; instead the covered
  # file is LF and this control file is CRLF — the ONLY difference is the `-text` attribute. So the
  # control proves normalization is caused by the attribute, not by the platform/luck.
  t_start L4.1-control GOOD
  local raw; raw="$(blob_at "$gd" "$BRANCH" "legacy/raw.txt")"
  if has_cr "$raw"; then
    pass    # control retained CRLF (opted OUT of normalization) -> attribute is load-bearing
  else
    fail "control legacy/raw.txt lost its CR — normalization is NOT actually governed by .gitattributes"
  fi

  # -------- L4.2 line endings: the covered text blob is LF in the repo (re-assert explicitly). --------
  # `cat -A`-style: a normalized blob must have NO ^M. We already know the bytes from L4.1; assert
  # against the raw blob bytes here as the dedicated L4.2 check (covered=LF, control=CRLF side-by-side).
  t_start L4.2 GOOD
  if has_cr "$covered"; then
    fail "covered blob has CRLF (L4.2)"
  elif has_cr "$raw"; then
    pass    # covered=LF AND control=CRLF: LF storage is the normalization, not a no-op
  else
    fail "control blob is also LF — cannot distinguish normalization from a no-op"
  fi

  # -------- L4.3 file mode stable: the exec script is 100755 in the tree across the round-trip. --------
  # Read the tree mode directly (independent of any platform's working-tree core.fileMode quirk):
  # `ls-tree` reports the mode stored in the commit. Seeded 100755 on ubuntu; it must remain 100755
  # after passing through the Windows leg (which never rewrote it) and the macOS leg (chmod +x).
  t_start L4.3 GOOD
  local mode; mode="$(git -C "$v" ls-tree "$BRANCH" -- ".config/$REPO/run.sh" | awk '{print $1}')"
  if [ "$mode" = "100755" ]; then
    pass
  elif [ "$mode" = "100644" ] && { [ "${OS:-}" = "Windows_NT" ] || uname -s 2>/dev/null | grep -qiE 'mingw|msys|cygwin'; }; then
    # NAMED SKIP (local Windows dry-run only): when the SEED leg runs under Git-for-Windows, git's
    # core.fileMode is false, so the exec bit can't be recorded at all (the seed stores 100644) and
    # there is no 755 to keep stable. On CI the seed leg runs on UBUNTU (fileMode true) -> 100755 is
    # recorded and this asserts for real across the windows+macos round-trip. The exec-bit semantics
    # genuinely differ on Windows (PITFALLS / plan "exec-bit semantics differ on Windows").
    skip "seed ran under Git-for-Windows (core.fileMode=false): no exec bit to record; real assert runs on the CI ubuntu seed leg"
  else
    # Seeded 755 (CI) but the round-trip flipped it -> a real, catchable mode flip-flop.
    fail "exec script tree mode = $mode (expected 100755 stable across OS round-trip)"
  fi

  # -------- L4.6 nested content: every OS's nested edit survived as one logical path. --------
  t_start L4.6-content GOOD
  local nestedc; nestedc="$(blob_at "$gd" "$BRANCH" ".config/$REPO/app/sub/dir/file")"
  local nok=1
  case "$nestedc" in *windows-nested*) : ;; *) nok=0;; esac
  case "$nestedc" in *macos-nested*) : ;; *) nok=0;; esac
  case "$nestedc" in *nested-seed*) : ;; *) nok=0;; esac
  if [ "$nok" -eq 1 ]; then pass; else fail "nested file lost an OS edit: [$nestedc]"; fi

  summary
}

# =====================================================================================
# clash <os-label> — L4.5 helper: write a CONFLICTING same-line edit with a pinned date, then tick.
# Two legs call this with different dates; verify_clash asserts newest-wins regardless of push order.
# =====================================================================================
do_clash() {
  local os="${1:?clash needs an os-label}" line="${2:?clash needs a line value}" date="${3:?clash needs a date}"
  note "clash [$os]: same-line edit '$line' @ $date"
  setup_machine
  local home="$HOME" gd="$DOTFILES_ROOT/bare-repos/$REPO"
  # To create a REAL same-line clash across OS legs (not a fast-forward), this leg's commit must be
  # parented on the SEED commit of clash.conf, NOT on whatever the previous leg pushed. We rewind
  # the LOCAL branch to the seed commit (the first commit touching clash.conf) before editing, so
  # when the engine tick reconciles, origin (the other OS's clash edit) and this commit diverge on
  # the same line -> the engine's never-block resolver picks the newest committer-date.
  local seedrev
  seedrev="$(git --git-dir="$gd" rev-list --max-parents=0 "$BRANCH" 2>/dev/null | tail -n1)"
  if [ -n "$seedrev" ]; then
    git --git-dir="$gd" --work-tree="$home" reset -q --hard "$seedrev"
  fi
  # Overwrite the SAME line.
  printf '%s\n' "$line" > "$home/.config/$REPO/clash.conf"
  export GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date"
  run_tick || note "clash [$os]: tick nonzero"
  note "clash [$os]: origin clash.conf now ="; blob_at "$ORIGIN" "$BRANCH" ".config/$REPO/clash.conf" | sed 's/^/    /'
  note "clash [$os] done"
}

do_verify_clash() {
  local expected="${1:?expected winning value}"
  t_start L4.5 GOOD
  local v="$INTEROP_WORK/verify-clash"; rm -rf "$v"
  git clone -q --branch "$BRANCH" "file://$ORIGIN" "$v"
  local got; got="$(blob_at "$v/.git" "$BRANCH" ".config/$REPO/clash.conf")"
  got="$(printf '%s' "$got" | tr -d '\r')"
  if [ "$got" = "$expected" ]; then pass; else fail "newest-wins: expected [$expected] got [$got]"; fi
  summary
}

# =====================================================================================
# hookid — L4.4: on THIS OS leg, wire the bare repo's core.hooksPath to the engine's shared stubs,
# fire a REAL git commit (exactly as git invokes hooks, via sh.exe on Windows), and assert the
# runner resolves the firing repo's identity to `interop` via `git rev-parse --absolute-git-dir`.
# Reuses node 8's hook dispatch. Requires uv (the stub execs `uv run -m dotfiles_githooks`).
# =====================================================================================
do_hookid() {
  local os="${1:-this-os}"
  t_start L4.4 GOOD
  if ! command -v uv >/dev/null 2>&1; then
    skip "uv not on PATH (hook runner cannot run) on the $os leg"
    summary; return
  fi
  setup_machine
  local home="$HOME" root="$DOTFILES_ROOT" gd="$DOTFILES_ROOT/bare-repos/$REPO"
  # Wire the shared stubs (core.hooksPath -> engine githooks). The stub execs the runner which
  # identifies the repo via `git rev-parse --absolute-git-dir` (basename) under whatever shell git
  # uses for hooks — on Windows that is Git-for-Windows sh.exe (the INFERRED assumption L4.4).
  git --git-dir="$gd" config core.hooksPath "$ENGINE/githooks"
  # Install a post-commit hook for THIS repo that records the resolved identity basename.
  local idfile="$INTEROP_WORK/hookid.txt"; rm -f "$idfile"
  mkdir -p "$root/hooks/$REPO"
  { printf '#!/bin/sh\n'; printf 'basename "$(git rev-parse --absolute-git-dir)" > "%s"\n' "$idfile"; } > "$root/hooks/$REPO/post-commit"
  chmod +x "$root/hooks/$REPO/post-commit" 2>/dev/null || true
  # Make a real commit (not via the dispatcher) so the runner runs exactly as git invokes it.
  printf 'hook-%s\n' "$os" > "$home/.config/$REPO/hooktest"
  git --git-dir="$gd" --work-tree="$home" add -- ".config/$REPO/hooktest"
  git -C "$home" --git-dir="$gd" --work-tree="$home" commit -q -m "$REPO: hookid $os"
  local id; id="$(cat "$idfile" 2>/dev/null)"
  if [ "$id" = "$REPO" ]; then pass; else fail "hook identity = [$id], expected [$REPO] (rev-parse --absolute-git-dir basename under $os)"; fi
  summary
}

# --- dispatch -------------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  seed)         do_seed ;;
  leg)          do_leg "$@" ;;
  verify)       do_verify ;;
  clash)        do_clash "$@" ;;
  verify-clash) do_verify_clash "$@" ;;
  hookid)       do_hookid "$@" ;;
  *) printf 'usage: interop_step.sh {seed|leg <os>|verify|clash <os> <line> <date>|verify-clash <expected>|hookid <os>}\n' >&2; exit 2 ;;
esac
