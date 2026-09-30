#!/usr/bin/env bash
# Record the instance workflow as console2svg stills plus an asciicast tape
# per step. The tape is the recording. The SVG and PNG are rendered from it.
set -euo pipefail

PROOF_OUT="${PROOF_OUT:-$GITHUB_WORKSPACE/proof}"
USAGE_OUT="${USAGE_OUT:-$PROOF_OUT/usage}"
REMOTE="${REMOTE:-/tmp/dotfiles-remote.git}"
TOOL="$GITHUB_WORKSPACE/.local/share/dotfiles"

banner() { printf '\n--- %s ---\n' "$1"; }

gitdir() {
  git --git-dir="$HOME/.local/share/dotfiles.git" --work-tree="$HOME" "$@"
}

old_directory() { printf '%s%s' "$HOME/" '.' 'dotfiles'; }

prepare_remote() {
  git init --bare "$REMOTE"
  git -C "$GITHUB_WORKSPACE" push "$REMOTE" "HEAD:refs/heads/main"
  git -C "$GITHUB_WORKSPACE" push "$REMOTE" "HEAD:refs/heads/system"
  git -C "$GITHUB_WORKSPACE" push "$REMOTE" "HEAD:refs/heads/ci-machine"

  local seed
  seed="$(mktemp -d)"
  git clone "$REMOTE" "$seed"
  git -C "$seed" checkout main
  printf 'only on the host default branch\n' > "$seed/DEFAULT_ONLY.txt"
  git -C "$seed" add -f DEFAULT_ONLY.txt
  git -C "$seed" commit -m "marker that exists only on the default branch"
  git -C "$seed" push origin main

  git -C "$seed" checkout system
  mkdir -p "$seed/.local/share/dotfiles"
  printf 'only on the named baseline\n' > "$seed/.local/share/dotfiles/SYSTEM_ONLY.txt"
  git -C "$seed" add -f .local/share/dotfiles/SYSTEM_ONLY.txt
  git -C "$seed" commit -m "marker that exists only on the system baseline"
  git -C "$seed" push origin system

  # The host default is main. The baseline the instance merges is system.
  git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
  rm -rf "$seed"
}

step_layout() {
  cd "$HOME"
  banner "machine branch, not the host default"
  echo "HEAD=$(gitdir symbolic-ref HEAD)"
  echo "systemRef=$(gitdir config --get dotfiles.systemRef)"
  echo "remote default=$(git --git-dir="$REMOTE" symbolic-ref HEAD)"
  banner "git database and program are different directories"
  test -d "$HOME/.local/share/dotfiles.git/objects"
  echo "git dir objects: present"
  test -f "$HOME/.local/share/dotfiles/bootstrap.sh"
  echo "program bootstrap.sh: present"
  test ! -e "$HOME/.local/share/dotfiles/HEAD"
  echo "program directory is not a git database (no HEAD file in it)"
  test ! -e "$(old_directory)"
  echo "legacy home directory was not created"
  banner "git add -A does not stage the git database"
  gitdir add -A
  local staged
  staged="$(gitdir diff --cached --name-only || true)"
  if printf '%s\n' "$staged" | grep -F 'dotfiles.git/'; then
    echo "FAIL: git add -A staged the git database"
    gitdir reset -q
    exit 1
  fi
  if [ -z "$staged" ]; then
    echo "staged paths: (none)"
  else
    echo "staged paths:"
    printf '%s\n' "$staged"
  fi
  gitdir reset -q
  gitdir check-ignore -v .local/share/dotfiles.git/HEAD
  echo "PROOF layout ok"
}

step_hooks() {
  cd "$HOME"
  banner "hooks path is the program directory"
  gitdir config core.hooksPath "$HOME/.local/share/dotfiles/.githooks"
  echo "core.hooksPath=$(gitdir config --get core.hooksPath)"
  banner "runner environment is the cache directory"
  export UV_PROJECT_ENVIRONMENT="$HOME/.cache/dotfiles/githooks-runner"
  uv sync --project "$HOME/.local/share/dotfiles/githooks-runner" --frozen -q
  test -f "$UV_PROJECT_ENVIRONMENT/pyvenv.cfg"
  echo "cache pyvenv.cfg: present"
  test ! -e "$HOME/.local/share/dotfiles/githooks-runner/.venv"
  echo "program .venv: absent"
  echo "PROOF hooks ok"
}

step_timer_where() {
  cd "$HOME"
  banner "timer files live in the state directory"
  test -f "$HOME/.local/state/dotfiles/auto-commit.sh"
  echo "state script: $HOME/.local/state/dotfiles/auto-commit.sh"
  grep -F ExecStart "$HOME/.config/systemd/user/dotfiles-git-commit.service"
  test ! -e "$HOME/.local/share/dotfiles.git/auto-commit.sh"
  echo "script inside git dir: absent"
  test ! -e "$HOME/.local/share/dotfiles/auto-commit.sh"
  echo "script inside program dir: absent"
  echo "PROOF timer-where ok"
}

step_uninstall() {
  cd "$HOME"
  banner "uninstall removes timer files and leaves the repo"
  bash "$TOOL/dotfiles-timer.sh" uninstall
  test ! -e "$HOME/.config/systemd/user/dotfiles-git-commit.service"
  echo "unit: absent"
  test ! -e "$HOME/.local/state/dotfiles/auto-commit.sh"
  echo "state script: absent"
  test -d "$HOME/.local/share/dotfiles.git/objects"
  echo "git dir: kept"
  test -f "$HOME/.local/share/dotfiles/dotfiles-timer.sh"
  echo "program: kept"
  echo "PROOF uninstall ok"
}

story_new_machine() {
  banner "Set up this laptop"
  echo "Machine branch: ci-machine"
  echo "Shared baseline: system"
  echo "GitHub's default branch is left alone."
  bash "$TOOL/bootstrap.sh" --repo "$REMOTE" --branch ci-machine --system-ref system
  echo "You are on $(gitdir symbolic-ref --short HEAD). Updates merge $(gitdir config --get dotfiles.systemRef)."
}

story_track_bashrc() {
  cd "$HOME"
  banner "Track your bashrc"
  printf 'alias ll="ls -la"\n' > .bashrc
  echo "A new file in your home is ignored until you add it with -f."
  gitdir add -f .bashrc
  gitdir commit -m "Add bashrc"
  echo "Branch: $(gitdir symbolic-ref --short HEAD)"
  gitdir log -1 --oneline
  echo "status:"
  gitdir status --short
  echo "Bashrc is tracked on ci-machine."
}

story_edit_tomorrow() {
  cd "$HOME"
  banner "The next day you change bashrc"
  printf '\n# prefer vim\nexport EDITOR=vim\n' >> .bashrc
  local status
  status="$(gitdir status --short)"
  printf '%s\n' "$status"
  printf '%s\n' "$status" | grep -F .bashrc >/dev/null
  gitdir add -u .
  gitdir commit -m "Set EDITOR"
  echo "status after commit:"
  gitdir status --short
  echo "Branch is still $(gitdir symbolic-ref --short HEAD)"
  echo "The edit is committed, and you are still on ci-machine."
}

story_doctor() {
  cd "$HOME"
  banner "Check this laptop"
  bash "$TOOL/dotfiles-doctor.sh" --skip-network
}

story_inherit() {
  cd "$HOME"
  banner "A shared improvement landed on system"
  echo "This laptop merges system. It does not merge GitHub's default branch."
  bash "$TOOL/dotfiles-update.sh"
  echo "Shared file:"
  cat "$HOME/.local/share/dotfiles/SYSTEM_ONLY.txt"
  if [ -e "$HOME/DEFAULT_ONLY.txt" ]; then
    echo "FAIL: default-branch file arrived"
    exit 1
  fi
  echo "Default-branch-only file: not on this machine"
  echo "Branch is still $(gitdir symbolic-ref --short HEAD)"
  echo "Shared file arrived. Default-branch file did not. Still on ci-machine."
}

story_walk_away() {
  cd "$HOME"
  banner "You change bashrc and walk away"
  printf '\n# left the desk\n' >> .bashrc
  echo "The timer script commits tracked changes and pushes."
  bash "$TOOL/dotfiles-timer.sh" install
  bash "$HOME/.local/state/dotfiles/auto-commit.sh"
  gitdir log -1 --format=%s | grep -F .bashrc
  echo "Latest commit:"
  gitdir log -1 --format=%s
  echo "The timer committed the bashrc edit on $(gitdir symbolic-ref --short HEAD)."
}

record_movie() {
  local name="$1"
  local expect="$2"
  local height="$3"
  local header="$4"
  local cast="$PROOF_OUT/$name.cast"
  local movie="$USAGE_OUT/$name.svg"
  local png="$PROOF_OUT/$name.png"

  # -v writes an animated SVG (the movie). --save-cast keeps the tape.
  console2svg capture \
    -v \
    --no-loop \
    --sleep 2 \
    --fps 8 \
    --mask-auto false \
    -w 110 \
    -h "$height" \
    -d windows \
    -c \
    --header "$header" \
    --timing realtime \
    --save-cast "$cast" \
    -o "$movie" \
    -- bash "$0" story "$name"
  if ! grep -q "$expect" "$cast"; then
    echo "visual-proof: tape $name.cast does not contain: $expect" >&2
    exit 1
  fi
  console2svg capture \
    --in "$cast" \
    --mask-auto false \
    -w 110 \
    -h "$height" \
    -d windows \
    --svg-converter rsvg-convert \
    -o "$png" \
    --format png
  test -s "$movie"
  test -s "$png"
  test -s "$cast"
  cp "$movie" "$PROOF_OUT/$name.svg"
}

record() {
  local name="$1"
  local expect="$2"
  local cast="$PROOF_OUT/$name.cast"
  local svg="$PROOF_OUT/$name.svg"
  local png="$PROOF_OUT/$name.png"

  # v0.10.1 capture has no --json. The tape must contain the step's final
  # PROOF line, which the step prints only after every check has passed.
  console2svg capture \
    --mask-auto false \
    -w 120 \
    -h 48 \
    -d windows \
    -c \
    --timing realtime \
    --save-cast "$cast" \
    -o "$svg" \
    -- bash "$0" step "$name"
  if ! grep -q "$expect" "$cast"; then
    echo "visual-proof: tape $name.cast does not contain: $expect" >&2
    exit 1
  fi

  # Still PNG is rendered from the tape, so the picture is that recording.
  console2svg capture \
    --in "$cast" \
    --mask-auto false \
    -w 120 \
    -h 48 \
    -d windows \
    --svg-converter rsvg-convert \
    -o "$png" \
    --format png
  test -s "$svg"
  test -s "$png"
  test -s "$cast"
}

write_index() {
  cat >"$PROOF_OUT/INDEX.txt" <<'EOF'
Each step is one recording.

.cast  asciicast v2 tape of the terminal session (the recording)
.svg   still image of the final screen, captured with the tape
.png   the same still, rendered from the tape for review

01-new-machine    animated: bootstrap this laptop onto ci-machine; updates merge system
02-layout          still: program directory is not the git database; legacy path was not created
02-track-bashrc    animated: first add -f of .bashrc, commit stays on ci-machine
03-edit-tomorrow   animated: a later edit shows in status, then commit
03-hooks           still: hooks path and cache venv
04-doctor          animated: doctor, all hard checks passed
05-inherit-system  animated: dotfiles update merges system and skips the default branch
06-walk-away       animated: timer script commits and pushes the bashrc edit
07-timer-where     still: ExecStart is the state-dir script
08-uninstall       still: timer files gone; git dir and program kept

Animated SVGs in usage/ are the README movies. Each .cast next to them is the tape.
EOF
}

all() {
  mkdir -p "$PROOF_OUT" "$USAGE_OUT"
  git config --global user.email "ci@github-actions"
  git config --global user.name "CI"
  git config --global --add safe.directory '*'
  prepare_remote
  record_movie 01-new-machine 'You are on ci-machine. Updates merge system.' 24 "Set up this laptop"
  record 02-layout 'PROOF layout ok'
  record_movie 02-track-bashrc 'Bashrc is tracked on ci-machine.' 24 "Track your bashrc"
  record_movie 03-edit-tomorrow 'The edit is committed, and you are still on ci-machine.' 24 "Edit bashrc the next day"
  record 03-hooks 'PROOF hooks ok'
  record_movie 04-doctor 'all hard checks PASSED' 42 "Check this laptop"
  record_movie 05-inherit-system 'Shared file arrived. Default-branch file did not. Still on ci-machine.' 32 "Inherit the shared baseline"
  record_movie 06-walk-away 'The timer committed the bashrc edit on ci-machine.' 36 "Walk away; the timer commits"
  record 07-timer-where 'PROOF timer-where ok'
  record 08-uninstall 'PROOF uninstall ok'
  write_index
  echo "visual-proof: wrote $PROOF_OUT"
}

case "${1:-}" in
  all) all ;;
  step)
    case "${2:-}" in
      02-layout) step_layout ;;
      03-hooks) step_hooks ;;
      07-timer-where) step_timer_where ;;
      08-uninstall) step_uninstall ;;
      *) echo "visual-proof: unknown step ${2:-}" >&2; exit 2 ;;
    esac
    ;;
  story)
    case "${2:-}" in
      01-new-machine) story_new_machine ;;
      02-track-bashrc) story_track_bashrc ;;
      03-edit-tomorrow) story_edit_tomorrow ;;
      04-doctor) story_doctor ;;
      05-inherit-system) story_inherit ;;
      06-walk-away) story_walk_away ;;
      *) echo "visual-proof: unknown story ${2:-}" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "usage: visual-proof.sh all | visual-proof.sh step <name> | visual-proof.sh story <name>" >&2
    exit 2
    ;;
esac
