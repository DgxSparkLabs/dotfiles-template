#!/usr/bin/env bash
# Node 10 — migration + bootstrap (bash/zsh). Greppable GOOD/BAD banners.
#
# L1.14  — legacy single-repo layout (bare repo AT <fakeHOME>/.dotfiles tracking $HOME work-tree
#          files + a hooksPath) -> run migrate.sh -> assert: bare-repos/machine is a valid git-dir;
#          ALL work-tree files in $HOME are byte-identical; the old top-level git metadata is gone;
#          `dotfiles machine status` clean; a hook fires for the migrated repo; `-ls` shows machine.
# L5.25  — partial migration (git-dir moved but core.hooksPath unset) -> `dotfiles -doctor` reports
#          the inconsistency + the remaining step (hooksPath fix).
# Bootstrap — idempotent profile-append (running twice does NOT duplicate the source line) and the
#          expected layout is produced from empty using LOCAL bare origins (no network).
#
# Fake HOME + fake DOTFILES_ROOT via new_env — NEVER touches the real ~/.dotfiles or profile.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
. "$HERE/harness.sh"
. "$REPO/dotfiles.sh"

# Build a LEGACY single-repo layout: a BARE git-dir directly at $DOTFILES_ROOT (= the fake
# ~/.dotfiles) tracking a couple of $HOME work-tree files, with a (now-bogus) core.hooksPath set.
# Mirrors the old template's on-disk shape. Echoes the two tracked relpaths (space separated).
mk_legacy_layout() {
  local gd="$DOTFILES_ROOT"           # legacy: the bare git-dir IS ~/.dotfiles itself
  # bare-repos/ was pre-created by new_env; remove it so $ROOT looks like a pure legacy bare dir.
  rm -rf "$gd/bare-repos"
  git init --bare -q "$gd"
  git --git-dir="$gd" --work-tree="$HOME" symbolic-ref HEAD refs/heads/main
  git --git-dir="$gd" config user.email "t@example.test"
  git --git-dir="$gd" config user.name  "t"
  # A legacy hooksPath that no longer exists after the engine split (the partial-migration trap).
  git --git-dir="$gd" config core.hooksPath "$gd/.dotfiles/githooks"
  # NB: do NOT track a file named .gitconfig in the fixture — git ops run with --work-tree=$HOME,
  # so git would read $HOME/.gitconfig as the global config and choke on non-git-config content,
  # breaking the legacy-detect rev-parse. Use innocuous names instead.
  mkdir -p "$HOME/.config/app"
  printf 'profile line\n'  > "$HOME/.bashrc.tracked"
  printf 'app config v1\n' > "$HOME/.config/app/conf"
  git --git-dir="$gd" --work-tree="$HOME" add -- .bashrc.tracked .config/app/conf
  git --git-dir="$gd" --work-tree="$HOME" commit -q -m "legacy: track machine config"
}

# ===========================================================================================
# L1.14 — full migration of a legacy single-repo layout.
_t_start L1.14 GOOD
new_env
mk_legacy_layout
# Snapshot work-tree files BEFORE migration (must be byte-identical after).
gc_before="$(cat "$HOME/.bashrc.tracked")"
app_before="$(cat "$HOME/.config/app/conf")"
# The engine the migration points common/ at = THIS checkout (so the hook runner is real). We
# pre-place it at common/ so migrate.sh skips the network clone (no --engine needed).
mkdir -p "$DOTFILES_ROOT"
ln -s "$REPO" "$DOTFILES_ROOT/common" 2>/dev/null || cp -r "$REPO" "$DOTFILES_ROOT/common"

# Run the migration (no live timer on CI: DOTFILES_TIMER_LIVE unset -> install writes files only).
DOTFILES_ROOT="$DOTFILES_ROOT" DOTFILES_COMMON="$DOTFILES_ROOT/common" DOTFILES_PROFILE="$HOME/.bashrc" \
  bash "$REPO/migrate.sh" >/dev/null 2>&1
mrc=$?
assert_rc L1.14-rc "$mrc" 0

# bare-repos/machine is a valid git-dir.
if git --git-dir="$DOTFILES_ROOT/bare-repos/machine" rev-parse --git-dir >/dev/null 2>&1; then
  _pass; else _fail "L1.14: bare-repos/machine is not a valid git-dir"; fi

# ALL work-tree files in $HOME are byte-identical (unchanged).
assert_eq L1.14-bashrc  "$(cat "$HOME/.bashrc.tracked")" "$gc_before"
assert_eq L1.14-appconf "$(cat "$HOME/.config/app/conf")" "$app_before"

# The old top-level git metadata is gone (no HEAD/objects directly under $ROOT).
if [ -f "$DOTFILES_ROOT/HEAD" ] || [ -d "$DOTFILES_ROOT/objects" ]; then
  _fail "L1.14: legacy git metadata still present at \$ROOT"; else _pass; fi

# `dotfiles machine status` is clean (showUntrackedFiles=no; files all tracked/unchanged).
# Capture STDOUT only (hook/uv build chatter goes to stderr) and assert no porcelain change lines.
out="$(dotfiles machine status --porcelain 2>/dev/null)"
assert_eq L1.14-clean "$(printf '%s' "$out" | tr -d '[:space:]')" ""

# `dotfiles -ls` shows machine.
assert_contains L1.14-ls "$(dotfiles -ls 2>/dev/null)" "machine"

# core.hooksPath now points at the engine githooks (re-homed by migration). Compare on the
# trailing common/githooks suffix — Git-for-Windows may report C:/... vs the MSYS /tmp/... form.
hp="$(git --git-dir="$DOTFILES_ROOT/bare-repos/machine" config --get core.hooksPath 2>/dev/null)"
assert_contains L1.14-hookspath "$hp" "common/githooks"

# A hook fires for the migrated repo: install a _shared pre-commit marker, commit, assert marker.
REPO_UNDER_TEST="$DOTFILES_ROOT/common"
export DF_MARK="$WORK/hookfired.marker"
write_hook _shared pre-commit "printf fired > \"$DF_MARK\""
printf 'new line\n' >> "$HOME/.config/app/conf"
git --git-dir="$DOTFILES_ROOT/bare-repos/machine" --work-tree="$HOME" add -- .config/app/conf >/dev/null 2>&1
git -C "$HOME" --git-dir="$DOTFILES_ROOT/bare-repos/machine" --work-tree="$HOME" commit -q -m "post-migrate edit" >/dev/null 2>&1
if [ -f "$DF_MARK" ]; then _pass; else _fail "L1.14: per-repo hook did not fire on the migrated repo"; fi
unset DF_MARK

# ===========================================================================================
# L1.14b — migrate is idempotent / re-runnable (a second run is a safe no-op, rc 0).
_t_start L1.14b GOOD
DOTFILES_ROOT="$DOTFILES_ROOT" DOTFILES_COMMON="$DOTFILES_ROOT/common" DOTFILES_PROFILE="$HOME/.bashrc" \
  bash "$REPO/migrate.sh" >/dev/null 2>&1
assert_rc L1.14b "$?" 0
# Still a valid git-dir, still one entry.
assert_contains L1.14b-ls "$(dotfiles -ls 2>&1)" "machine"

# ===========================================================================================
# L1.14c — abort on NO legacy layout AND no machine repo (clear message, nonzero).
_t_start L1.14c BAD
new_env
rm -rf "$DOTFILES_ROOT/bare-repos"   # truly empty root, no legacy git-dir
out="$(DOTFILES_ROOT="$DOTFILES_ROOT" bash "$REPO/migrate.sh" 2>&1)"; rc=$?
assert_rc L1.14c "$rc" 1
assert_contains L1.14c "$out" "no legacy layout"

# ===========================================================================================
# L5.25 — partial migration: git-dir moved into bare-repos/machine but core.hooksPath still unset
# -> `dotfiles -doctor` reports the inconsistency (hooksPath MISSING) + the remaining step (fix).
_t_start L5.25 BAD
new_env
# Build the migrated machine repo by hand WITHOUT setting core.hooksPath (the partial state).
gd="$DOTFILES_ROOT/bare-repos/machine"
git init --bare -q "$gd"
git --git-dir="$gd" --work-tree="$HOME" symbolic-ref HEAD refs/heads/main
git --git-dir="$gd" config user.email "t@example.test"
git --git-dir="$gd" config user.name  "t"
printf 'cfg\n' > "$HOME/.bashrc.tracked"
git --git-dir="$gd" --work-tree="$HOME" add -- .bashrc.tracked
git --git-dir="$gd" --work-tree="$HOME" commit -q -m "machine: seed"
# Point the engine at THIS checkout so doctor's engine line is valid.
out="$(DOTFILES_COMMON="$REPO" dotfiles -doctor 2>&1)"; rc=$?
assert_contains L5.25-hooks  "$out" "hooks:MISSING"
assert_contains L5.25-fix    "$out" "core.hooksPath not set"
assert_contains L5.25-fixcmd "$out" "config core.hooksPath"
# Partial migration is a WARNING (not an error) -> doctor still exits 0 per its policy.
assert_rc L5.25-rc "$rc" 0

# ===========================================================================================
# Bootstrap — idempotent profile-append: appending the source line twice does NOT duplicate it.
_t_start BOOT-idempotent GOOD
new_env
# Local bare origins (no network): an engine origin + a machine origin, mk_repo_with_origin-style.
ENGINE_ORIGIN="$WORK/origins/engine.git"
mkdir -p "$WORK/origins"
# Make the engine origin a clone of THIS checkout's content so common/ has a real dispatcher+timer.
git clone -q --bare "$REPO/.git" "$ENGINE_ORIGIN" 2>/dev/null \
  || { _skip "BOOT-idempotent" "could not create local engine origin from repo .git"; }
if [ -d "$ENGINE_ORIGIN" ]; then
  MACHINE_ORIGIN="$WORK/origins/machine.git"
  git init --bare -q "$MACHINE_ORIGIN"
  # Seed the machine origin with one commit on branch main from a temp work-tree.
  seedwt="$WORK/seedwt"; mkdir -p "$seedwt"
  git -C "$seedwt" init -q
  git -C "$seedwt" config user.email t@example.test; git -C "$seedwt" config user.name t
  printf 'machine gitconfig\n' > "$seedwt/.bashrc.tracked"
  git -C "$seedwt" add .bashrc.tracked; git -C "$seedwt" commit -q -m seed
  git -C "$seedwt" branch -M main
  git -C "$seedwt" push -q "$MACHINE_ORIGIN" main

  PROFILE="$HOME/.bashrc"; : > "$PROFILE"
  run_boot() {
    DOTFILES_ROOT="$DOTFILES_ROOT" DOTFILES_PROFILE="$PROFILE" \
    DOTFILES_ENGINE_URL="$ENGINE_ORIGIN" DOTFILES_MACHINE_URL="$MACHINE_ORIGIN" \
    DOTFILES_MACHINE_BRANCH=main \
      bash "$REPO/bootstrap.sh" >/dev/null 2>&1
  }
  run_boot; brc1=$?
  run_boot; brc2=$?
  assert_rc BOOT-rc1 "$brc1" 0
  assert_rc BOOT-rc2 "$brc2" 0
  # Source line present EXACTLY once after two runs.
  cnt="$(grep -cF '.dotfiles/common/dotfiles.sh' "$PROFILE" 2>/dev/null || printf '0')"
  assert_eq BOOT-profile-once "$cnt" "1"
  # Expected layout produced from empty: engine + machine repo both present, valid.
  if [ -f "$DOTFILES_ROOT/common/dotfiles.sh" ]; then _pass; else _fail "BOOT: engine common/ missing"; fi
  if git --git-dir="$DOTFILES_ROOT/bare-repos/machine" rev-parse --git-dir >/dev/null 2>&1; then
    _pass; else _fail "BOOT: machine repo not a valid git-dir"; fi
  # The tracked work-tree file was checked out.
  assert_contains BOOT-worktree "$(cat "$HOME/.bashrc.tracked" 2>/dev/null)" "machine gitconfig"
fi

_summary
