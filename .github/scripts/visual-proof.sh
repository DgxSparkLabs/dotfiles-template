#!/usr/bin/env bash
# Record the instance workflow as console2svg stills plus an asciicast tape
# per step. The tape is the recording. The SVG and PNG are rendered from it.
set -euo pipefail

PROOF_OUT="${PROOF_OUT:-$GITHUB_WORKSPACE/proof}"
USAGE_OUT="${USAGE_OUT:-$PROOF_OUT/usage}"
REMOTE="${REMOTE:-/tmp/dotfiles-remote.git}"
TOOL="$GITHUB_WORKSPACE/.local/share/dotfiles"

# Replay stdout and stderr slowly enough that a frame can hold each line.
show_log() {
  local log="$1" line
  while IFS= read -r line || [ -n "${line:-}" ]; do
    printf '%s\n' "$line"
    sleep 0.5
  done <"$log"
}

show() {
  local log
  log="$(mktemp)"
  "$@" >"$log" 2>&1
  show_log "$log"
  rm -f "$log"
}

# $1 is the command a reviewer reads. The rest is what runs.
run() {
  local display="$1"
  shift
  printf '$ %s\n' "$display"
  show "$@"
}

# git diff exits 1 when it finds a change. That exit is the change, not a failure.
run_diff() {
  local display="$1" log rc
  shift
  printf '$ %s\n' "$display"
  log="$(mktemp)"
  set +e
  "$@" >"$log" 2>&1
  rc=$?
  set -e
  show_log "$log"
  rm -f "$log"
  if [ "$rc" -gt 1 ]; then
    echo "FAIL: diff failed: $display"
    exit 1
  fi
}

# Same, when the evidence is that the command fails (ignored path, missing file).
run_fail() {
  local display="$1" log rc
  shift
  printf '$ %s\n' "$display"
  log="$(mktemp)"
  set +e
  "$@" >"$log" 2>&1
  rc=$?
  set -e
  show_log "$log"
  rm -f "$log"
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: expected a failing command: $display"
    exit 1
  fi
}

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
  local old rc
  old="$(old_directory)"
  run "git symbolic-ref HEAD" gitdir symbolic-ref HEAD
  run "git config --get dotfiles.systemRef" gitdir config --get dotfiles.systemRef
  run "git --git-dir=$REMOTE symbolic-ref HEAD" git --git-dir="$REMOTE" symbolic-ref HEAD
  run "ls -d ~/.local/share/dotfiles.git/HEAD" ls -d "$HOME/.local/share/dotfiles.git/HEAD"
  run "ls -d ~/.local/share/dotfiles/bootstrap.sh" ls -d "$HOME/.local/share/dotfiles/bootstrap.sh"
  run_fail "ls -d ~/.local/share/dotfiles/HEAD" ls -d "$HOME/.local/share/dotfiles/HEAD"
  run_fail "ls -d $old" ls -d "$old"
  run "git add -A" gitdir add -A
  printf '$ git diff --cached --quiet; echo $?\n'
  set +e
  gitdir diff --cached --quiet
  rc=$?
  set -e
  echo "$rc"
  if [ "$rc" -ne 0 ]; then
    gitdir diff --cached --name-only
    echo "FAIL: git add -A staged paths"
    gitdir reset -q
    exit 1
  fi
  gitdir reset -q
  run "git check-ignore -v .local/share/dotfiles.git/HEAD" \
    gitdir check-ignore -v .local/share/dotfiles.git/HEAD
  echo "PROOF layout ok"
}

step_hooks() {
  cd "$HOME"
  gitdir config core.hooksPath "$HOME/.local/share/dotfiles/.githooks"
  run "git config --get core.hooksPath" gitdir config --get core.hooksPath
  export UV_PROJECT_ENVIRONMENT="$HOME/.cache/dotfiles/githooks-runner"
  run "uv sync --project ~/.local/share/dotfiles/githooks-runner --frozen" \
    uv sync --project "$HOME/.local/share/dotfiles/githooks-runner" --frozen -q
  run "ls -d ~/.cache/dotfiles/githooks-runner/pyvenv.cfg" \
    ls -d "$HOME/.cache/dotfiles/githooks-runner/pyvenv.cfg"
  run_fail "ls -d ~/.local/share/dotfiles/githooks-runner/.venv" \
    ls -d "$HOME/.local/share/dotfiles/githooks-runner/.venv"
  echo "PROOF hooks ok"
}

step_timer_where() {
  cd "$HOME"
  run "ls -d ~/.local/state/dotfiles/auto-commit.sh" \
    ls -d "$HOME/.local/state/dotfiles/auto-commit.sh"
  run "grep ExecStart ~/.config/systemd/user/dotfiles-git-commit.service" \
    grep -F ExecStart "$HOME/.config/systemd/user/dotfiles-git-commit.service"
  run_fail "ls -d ~/.local/share/dotfiles.git/auto-commit.sh" \
    ls -d "$HOME/.local/share/dotfiles.git/auto-commit.sh"
  run_fail "ls -d ~/.local/share/dotfiles/auto-commit.sh" \
    ls -d "$HOME/.local/share/dotfiles/auto-commit.sh"
  echo "PROOF timer-where ok"
}

step_uninstall() {
  cd "$HOME"
  run "dotfiles-timer uninstall" bash "$TOOL/dotfiles-timer.sh" uninstall
  run_fail "ls -d ~/.config/systemd/user/dotfiles-git-commit.service" \
    ls -d "$HOME/.config/systemd/user/dotfiles-git-commit.service"
  run_fail "ls -d ~/.local/state/dotfiles/auto-commit.sh" \
    ls -d "$HOME/.local/state/dotfiles/auto-commit.sh"
  run "ls -d ~/.local/share/dotfiles.git/HEAD" \
    ls -d "$HOME/.local/share/dotfiles.git/HEAD"
  run "ls -d ~/.local/share/dotfiles/dotfiles-timer.sh" \
    ls -d "$HOME/.local/share/dotfiles/dotfiles-timer.sh"
  echo "PROOF uninstall ok"
}

story_new_machine() {
  cd "$HOME"
  run "bash bootstrap.sh --repo $REMOTE --branch ci-machine --system-ref system" \
    bash "$TOOL/bootstrap.sh" --repo "$REMOTE" --branch ci-machine --system-ref system
  run "git symbolic-ref HEAD" gitdir symbolic-ref HEAD
  run "git config --get dotfiles.systemRef" gitdir config --get dotfiles.systemRef
  run "git --git-dir=$REMOTE symbolic-ref HEAD" \
    git --git-dir="$REMOTE" symbolic-ref HEAD
}

story_track_bashrc() {
  cd "$HOME"
  printf 'alias ll="ls -la"\n' > .bashrc
  run "git check-ignore -v .bashrc" gitdir check-ignore -v .bashrc
  run_fail "git add .bashrc" gitdir add .bashrc
  run "git add -f .bashrc" gitdir add -f .bashrc
  run "git commit -m 'Add bashrc'" gitdir commit -m "Add bashrc"
  run "git status -sb" gitdir status -sb
  run "git log -1 --oneline" gitdir log -1 --oneline
}

story_edit_tomorrow() {
  cd "$HOME"
  printf '\n# prefer vim\nexport EDITOR=vim\n' >> .bashrc
  run_diff "git diff -- .bashrc" gitdir diff -- .bashrc
  grep -F 'export EDITOR=vim' < <(gitdir diff -- .bashrc || true) >/dev/null
  run "git add -u ." gitdir add -u .
  run "git commit -m 'Set EDITOR'" gitdir commit -m "Set EDITOR"
  run "git status -sb" gitdir status -sb
  run "git log -1 --oneline" gitdir log -1 --oneline
}

story_doctor() {
  cd "$HOME"
  run "dotfiles-doctor --skip-network" bash "$TOOL/dotfiles-doctor.sh" --skip-network
}

story_inherit() {
  cd "$HOME"
  run "git --git-dir=$REMOTE show refs/heads/main:DEFAULT_ONLY.txt" \
    git --git-dir="$REMOTE" show refs/heads/main:DEFAULT_ONLY.txt
  run "git --git-dir=$REMOTE show refs/heads/system:.local/share/dotfiles/SYSTEM_ONLY.txt" \
    git --git-dir="$REMOTE" show refs/heads/system:.local/share/dotfiles/SYSTEM_ONLY.txt
  run_fail "git --git-dir=$REMOTE cat-file -e refs/heads/main:.local/share/dotfiles/SYSTEM_ONLY.txt" \
    git --git-dir="$REMOTE" cat-file -e refs/heads/main:.local/share/dotfiles/SYSTEM_ONLY.txt
  run_fail "git --git-dir=$REMOTE cat-file -e refs/heads/system:DEFAULT_ONLY.txt" \
    git --git-dir="$REMOTE" cat-file -e refs/heads/system:DEFAULT_ONLY.txt
  run "dotfiles-update" bash "$TOOL/dotfiles-update.sh"
  run "cat .local/share/dotfiles/SYSTEM_ONLY.txt" \
    cat "$HOME/.local/share/dotfiles/SYSTEM_ONLY.txt"
  run_fail "ls -d DEFAULT_ONLY.txt" ls -d "$HOME/DEFAULT_ONLY.txt"
  run "git status -sb" gitdir status -sb
  run "git log -1 --format=%s" gitdir log -1 --format=%s
}

story_walk_away() {
  cd "$HOME"
  local before after log head remote_head
  run "git push -u origin HEAD" gitdir push -u origin HEAD
  run "dotfiles-timer install" bash "$TOOL/dotfiles-timer.sh" install
  # enable --now can run the unit immediately. Stop it so this recording shows
  # the script's own commit and push.
  systemctl --user stop dotfiles-git-commit.timer
  systemctl --user stop dotfiles-git-commit.service || true
  printf '\n# left the desk\n' >> .bashrc
  run_diff "git diff -- .bashrc" gitdir diff -- .bashrc
  grep -F '# left the desk' < <(gitdir diff -- .bashrc || true) >/dev/null
  before="$(git --git-dir="$REMOTE" rev-parse refs/heads/ci-machine)"
  printf '$ bash ~/.local/state/dotfiles/auto-commit.sh\n'
  log="$(mktemp)"
  bash "$HOME/.local/state/dotfiles/auto-commit.sh" >"$log" 2>&1
  if grep -F 'Everything up-to-date' "$log"; then
    echo "FAIL: timer script had nothing new to push"
    exit 1
  fi
  grep -F '.bashrc' "$log" >/dev/null
  show_log "$log"
  rm -f "$log"
  after="$(git --git-dir="$REMOTE" rev-parse refs/heads/ci-machine)"
  if [ "$before" = "$after" ]; then
    echo "FAIL: timer commit was not pushed"
    exit 1
  fi
  printf '$ git rev-parse HEAD\n'
  head="$(gitdir rev-parse HEAD)"
  printf '%s\n' "$head"
  sleep 0.5
  printf '$ git --git-dir=%s rev-parse refs/heads/ci-machine\n' "$REMOTE"
  remote_head="$(git --git-dir="$REMOTE" rev-parse refs/heads/ci-machine)"
  printf '%s\n' "$remote_head"
  sleep 0.5
  if [ "$head" != "$remote_head" ]; then
    echo "FAIL: timer commit was not pushed"
    exit 1
  fi
}

record_movie() {
  local name="$1"
  local expect="$2"
  local height="$3"
  local header="$4"
  local cast="$PROOF_OUT/$name.cast"
  local movie="$USAGE_OUT/$name.svg"
  local png="$PROOF_OUT/$name.png"

  # -v writes an animated SVG. --sleep holds the last screen before the
  # movie repeats. --save-cast keeps the tape.
  console2svg capture \
    -v \
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
  # A readable movie lasts longer than a single dumped frame.
  local last
  last="$(tail -n 1 "$cast" | sed -n 's/^\[\([0-9.][0-9.]*\),.*/\1/p')"
  awk -v t="$last" 'BEGIN { if (t+0 < 2) exit 1 }' || {
    echo "visual-proof: tape $name.cast is shorter than 2s (last=$last)" >&2
    exit 1
  }
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

Read the command, then the lines under it. A sentence we printed is not the proof.

01-new-machine    symbolic-ref of this machine, dotfiles.systemRef, remote HEAD still main
02-layout          ls of the git database HEAD, ls failing in the program directory, ls failing for the legacy path, diff --cached exit 0, check-ignore of the git database
02-track-bashrc    check-ignore matching /*, add rejected, then add -f and the commit
03-edit-tomorrow   diff hunk for the edit, then status -sb still on the machine branch
03-hooks           git config core.hooksPath, ls of the cache pyvenv.cfg, ls failing for a program .venv
04-doctor          one PASS line per hard check
05-inherit-system  show of the file on main and the file on system, update, cat of the system file, ls failing for the main-only file, status -sb
06-walk-away       diff hunk, the timer script's commit and push, rev-parse of HEAD and of the remote branch printing the same hash
07-timer-where     ls of the state-dir script, grep ExecStart, ls failing inside the git dir and the program dir
08-uninstall       ls failing for the unit and the state script, ls succeeding for the git database and the program

usage/ holds the animated day. The stills stay beside their tapes in this directory.
EOF
}

all() {
  mkdir -p "$PROOF_OUT" "$USAGE_OUT"
  git config --global user.email "ci@github-actions"
  git config --global user.name "CI"
  git config --global --add safe.directory '*'
  prepare_remote
  record_movie 01-new-machine 'refs/heads/main' 24 "Set up this laptop"
  record 02-layout 'PROOF layout ok'
  record_movie 02-track-bashrc 'The following paths are ignored' 40 "Track your bashrc"
  record_movie 03-edit-tomorrow 'export EDITOR=vim' 32 "Edit bashrc the next day"
  record 03-hooks 'PROOF hooks ok'
  record_movie 04-doctor 'all hard checks PASSED' 36 "Check this laptop"
  record_movie 05-inherit-system 'No such file' 56 "Inherit the shared baseline"
  record_movie 06-walk-away '# left the desk' 56 "Walk away; the timer commits"
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
