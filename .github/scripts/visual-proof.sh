#!/usr/bin/env bash
# Record the instance workflow as console2svg stills plus an asciicast tape
# per step. The tape is the recording. The SVG and PNG are rendered from it.
set -euo pipefail

PROOF_OUT="${PROOF_OUT:-$GITHUB_WORKSPACE/proof}"
REMOTE="${REMOTE:-/tmp/dotfiles-remote.git}"
TOOL="$GITHUB_WORKSPACE/.local/share/dotfiles"
DOCS="$TOOL/docs/proof"

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

# Two lines before the commands: the question, then the output that means pass.
# Result is printed only after the assertions, so a failed tape has no Result line.
explain() {
  printf '%s\n' "Check: $1"
  sleep 0.5
  printf '%s\n' "Expect: $2"
  sleep 0.5
}

note() {
  printf '%s\n' "$1"
  sleep 0.5
}

pass() {
  printf '%s\n' "Result: PASS. $1"
  sleep 0.5
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

# The command a reader types. Same git dir as gitdir, so the prompt can say
# `dotfiles` and the recording still drives the bare repo.
dotfiles() {
  git --git-dir="$HOME/.local/share/dotfiles.git" --work-tree="$HOME" "$@"
}

old_directory() { printf '%s%s' "$HOME/" '.' 'dotfiles'; }

prepare_remote() {
  git init --bare "$REMOTE"
  git -C "$GITHUB_WORKSPACE" push "$REMOTE" "HEAD:refs/heads/main"
  git -C "$GITHUB_WORKSPACE" push "$REMOTE" "HEAD:refs/heads/system"
  git -C "$GITHUB_WORKSPACE" push "$REMOTE" "HEAD:refs/heads/laptop"

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

typed() {
  printf '$ %s\n' "$1"
  sleep 0.5
}

story_program() {
  cd "$HOME"
  explain \
    "The program directory and the git database are both present, and this machine is on branch laptop." \
    "ls lists dotfiles/ and dotfiles.git/. dotfiles status -sb prints ## laptop."
  run "ls -F ~/.local/share" ls -F "$HOME/.local/share"
  run "ls -F ~/.local/share/dotfiles.git" ls -F "$HOME/.local/share/dotfiles.git"
  run "ls -F ~/.local/share/dotfiles" ls -F "$HOME/.local/share/dotfiles"
  run "dotfiles status -sb" dotfiles status -sb
  dotfiles status -sb | grep -q '## laptop'
  ls -d "$HOME/.local/share/dotfiles" "$HOME/.local/share/dotfiles.git" >/dev/null
  pass "Both directories are listed, and the branch is laptop."
}

story_layout() {
  cd "$HOME"
  local old rc got
  old="$(old_directory)"
  explain \
    "The git database, the program directory, and the host default are separate, and add -A stages nothing." \
    "Branch is laptop, systemRef is system, the remote default is refs/heads/main, the program has no HEAD, the retired directory is absent, and the cached diff status is 0."
  run "dotfiles symbolic-ref HEAD" dotfiles symbolic-ref HEAD
  [ "$(dotfiles symbolic-ref HEAD)" = "refs/heads/laptop" ]
  run "dotfiles config --get dotfiles.systemRef" dotfiles config --get dotfiles.systemRef
  [ "$(dotfiles config --get dotfiles.systemRef)" = "system" ]
  note "The next command reads the temp remote. It must print refs/heads/main. Update merges system, not that default."
  printf '$ %s\n' "git --git-dir=$REMOTE symbolic-ref HEAD"
  got="$(git --git-dir="$REMOTE" symbolic-ref HEAD)"
  printf '%s\n' "$got"
  sleep 0.5
  [ "$got" = "refs/heads/main" ]
  run "ls -d ~/.local/share/dotfiles.git/HEAD" ls -d "$HOME/.local/share/dotfiles.git/HEAD"
  run "ls -d ~/.local/share/dotfiles/bootstrap.sh" ls -d "$HOME/.local/share/dotfiles/bootstrap.sh"
  note "The next command must fail. The program directory is not a git database."
  run_fail "ls -d ~/.local/share/dotfiles/HEAD" ls -d "$HOME/.local/share/dotfiles/HEAD"
  note "The next command must fail. Setup does not create the retired home directory."
  run_fail "ls -d $old" ls -d "$old"
  run "dotfiles add -A" dotfiles add -A
  note "The next status is 0 when that add staged nothing."
  printf '$ %s\n' "dotfiles diff --cached --quiet; echo \$?"
  set +e
  dotfiles diff --cached --quiet
  rc=$?
  set -e
  printf '%s\n' "$rc"
  sleep 0.5
  if [ "$rc" -ne 0 ]; then
    dotfiles diff --cached --name-only
    echo "FAIL: dotfiles add -A staged paths"
    dotfiles reset -q
    exit 1
  fi
  dotfiles reset -q
  run "dotfiles check-ignore -v .local/share/dotfiles.git/HEAD" \
    dotfiles check-ignore -v .local/share/dotfiles.git/HEAD
  pass "The git database is separate from the program, the remote default is main, and add -A staged nothing."
}

story_track() {
  cd "$HOME"
  explain \
    "A new ~/.bashrc is ignored until add -f, then the commit and push stay on branch laptop." \
    "check-ignore prints the ignore rule. add without -f says the path is ignored. status still prints ## laptop."
  typed "printf 'alias ll=\"ls -la\"\\n' > ~/.bashrc"
  printf 'alias ll="ls -la"\n' > .bashrc
  run "ls -l ~/.bashrc" ls -l "$HOME/.bashrc"
  run "cat ~/.bashrc" cat "$HOME/.bashrc"
  run "dotfiles check-ignore -v ~/.bashrc" dotfiles check-ignore -v "$HOME/.bashrc"
  note "The next command must fail. The root ignore hides this file until add -f."
  run_fail "dotfiles add ~/.bashrc" dotfiles add "$HOME/.bashrc"
  run "dotfiles add -f ~/.bashrc" dotfiles add -f "$HOME/.bashrc"
  run "dotfiles commit -m \"Add bashrc\"" dotfiles commit -m "Add bashrc"
  run "dotfiles push -u origin HEAD" dotfiles push -u origin HEAD
  run "dotfiles status -sb" dotfiles status -sb
  dotfiles status -sb | grep -q '## laptop'
  pass "~/.bashrc is tracked on laptop, and the push set its upstream."
}

story_edit() {
  cd "$HOME"
  explain \
    "A later edit of the tracked ~/.bashrc is committed with add -u, and the branch stays laptop." \
    "diff shows export EDITOR=vim. log --stat names .bashrc. status still prints ## laptop."
  typed "printf '\\n# prefer vim\\nexport EDITOR=vim\\n' >> ~/.bashrc"
  printf '\n# prefer vim\nexport EDITOR=vim\n' >> .bashrc
  run "cat ~/.bashrc" cat "$HOME/.bashrc"
  run_diff "dotfiles diff ~/.bashrc" dotfiles diff -- "$HOME/.bashrc"
  grep -F 'export EDITOR=vim' < <(dotfiles diff -- "$HOME/.bashrc" || true) >/dev/null
  run "dotfiles add -u ." dotfiles add -u .
  run "dotfiles commit -m \"Set EDITOR\"" dotfiles commit -m "Set EDITOR"
  run "dotfiles log -1 --stat" dotfiles log -1 --stat
  dotfiles log -1 --stat | grep -q '.bashrc'
  run "dotfiles status -sb" dotfiles status -sb
  dotfiles status -sb | grep -q '## laptop'
  pass "The EDITOR line is committed on laptop."
}

story_hooks() {
  cd "$HOME"
  explain \
    "Hooks point at the program .githooks directory, and the virtualenv is in the cache, not the program tree." \
    "core.hooksPath is the program .githooks path. The cache pyvenv.cfg is listed. A program-tree .venv is absent."
  run "dotfiles config --get core.hooksPath" dotfiles config --get core.hooksPath
  dotfiles config --get core.hooksPath | grep -q '/.local/share/dotfiles/.githooks'
  run "ls -d ~/.cache/dotfiles/githooks-runner/pyvenv.cfg" \
    ls -d "$HOME/.cache/dotfiles/githooks-runner/pyvenv.cfg"
  note "The next command must fail. The virtualenv is not created inside the program tree."
  run_fail "ls -d ~/.local/share/dotfiles/githooks-runner/.venv" \
    ls -d "$HOME/.local/share/dotfiles/githooks-runner/.venv"
  pass "Hooks use the program directory, and the virtualenv is only in the cache."
}

story_doctor() {
  cd "$HOME"
  local log
  explain \
    "dotfiles-doctor passes every hard check when the network check is skipped." \
    "The hooks directory and the cache pyvenv.cfg exist, and doctor prints: all hard checks PASSED."
  run "ls -d ~/.local/share/dotfiles/.githooks" ls -d "$HOME/.local/share/dotfiles/.githooks"
  run "ls -l ~/.cache/dotfiles/githooks-runner/pyvenv.cfg" \
    ls -l "$HOME/.cache/dotfiles/githooks-runner/pyvenv.cfg"
  printf '$ %s\n' "dotfiles-doctor --skip-network"
  log="$(mktemp)"
  bash "$TOOL/dotfiles-doctor.sh" --skip-network >"$log" 2>&1
  show_log "$log"
  grep -q 'all hard checks PASSED' "$log"
  if grep -q '  FAIL  ' "$log"; then
    echo "FAIL: a hard check failed"
    exit 1
  fi
  rm -f "$log"
  pass "Every hard check passed. The network check was skipped."
}

story_update() {
  cd "$HOME"
  explain \
    "dotfiles-update merges branch system onto laptop and does not bring the file that exists only on main." \
    "The update merges origin/system. SYSTEM_ONLY.txt says only on the named baseline. status is ## laptop. ~/DEFAULT_ONLY.txt is missing."
  run "dotfiles-update" bash "$TOOL/dotfiles-update.sh"
  run "ls -l ~/.local/share/dotfiles/SYSTEM_ONLY.txt" \
    ls -l "$HOME/.local/share/dotfiles/SYSTEM_ONLY.txt"
  run "cat ~/.local/share/dotfiles/SYSTEM_ONLY.txt" \
    cat "$HOME/.local/share/dotfiles/SYSTEM_ONLY.txt"
  grep -qx 'only on the named baseline' "$HOME/.local/share/dotfiles/SYSTEM_ONLY.txt"
  run "dotfiles log -1 --stat" dotfiles log -1 --stat
  run "dotfiles status -sb" dotfiles status -sb
  dotfiles status -sb | grep -q '## laptop'
  note "The next command must fail. That file exists only on the host default branch, main."
  run_fail "ls -d ~/DEFAULT_ONLY.txt" ls -d "$HOME/DEFAULT_ONLY.txt"
  if [ -e "$HOME/DEFAULT_ONLY.txt" ]; then
    echo "FAIL: file from the host default branch is in the home directory"
    exit 1
  fi
  pass "laptop merged system, the baseline file is present, and the main-only file is absent."
}

story_timer() {
  cd "$HOME"
  local before after log head remote_head
  explain \
    "The generated timer script commits a tracked ~/.bashrc edit and pushes it on branch laptop." \
    "diff shows # left the desk. The script names .bashrc and does not say Everything up-to-date. log --stat names .bashrc."
  typed "printf '\\n# left the desk\\n' >> ~/.bashrc"
  printf '\n# left the desk\n' >> .bashrc
  run_diff "dotfiles diff ~/.bashrc" dotfiles diff -- "$HOME/.bashrc"
  grep -F '# left the desk' < <(dotfiles diff -- "$HOME/.bashrc" || true) >/dev/null
  run "ls -l ~/.local/state/dotfiles/auto-commit.sh" \
    ls -l "$HOME/.local/state/dotfiles/auto-commit.sh"
  before="$(git --git-dir="$REMOTE" rev-parse refs/heads/laptop)"
  printf '$ %s\n' "bash ~/.local/state/dotfiles/auto-commit.sh"
  log="$(mktemp)"
  bash "$HOME/.local/state/dotfiles/auto-commit.sh" >"$log" 2>&1
  if grep -F 'Everything up-to-date' "$log"; then
    echo "FAIL: timer script had nothing new to push"
    exit 1
  fi
  grep -F '.bashrc' "$log" >/dev/null
  show_log "$log"
  rm -f "$log"
  after="$(git --git-dir="$REMOTE" rev-parse refs/heads/laptop)"
  if [ "$before" = "$after" ]; then
    echo "FAIL: timer commit was not pushed"
    exit 1
  fi
  head="$(dotfiles rev-parse HEAD)"
  remote_head="$(git --git-dir="$REMOTE" rev-parse refs/heads/laptop)"
  if [ "$head" != "$remote_head" ]; then
    echo "FAIL: timer commit was not pushed"
    exit 1
  fi
  run "cat ~/.bashrc" cat "$HOME/.bashrc"
  run "dotfiles log -1 --stat" dotfiles log -1 --stat
  dotfiles log -1 --stat | grep -q '.bashrc'
  run "dotfiles status -sb" dotfiles status -sb
  dotfiles status -sb | grep -q '## laptop'
  pass "The timer script committed the desk line and pushed it on laptop."
}

story_timer_where() {
  cd "$HOME"
  explain \
    "The timer runs the script in the state directory, not a copy in the git database or the program directory." \
    "auto-commit.sh is under ~/.local/state/dotfiles. The unit starts that path. The same name is absent from the git database and the program directory."
  run "ls -d ~/.local/state/dotfiles/auto-commit.sh" \
    ls -d "$HOME/.local/state/dotfiles/auto-commit.sh"
  run "cat ~/.config/systemd/user/dotfiles-git-commit.service" \
    cat "$HOME/.config/systemd/user/dotfiles-git-commit.service"
  grep -q "$HOME/.local/state/dotfiles/auto-commit.sh" \
    "$HOME/.config/systemd/user/dotfiles-git-commit.service"
  note "The next two commands must fail. The generated script is not stored in git."
  run_fail "ls -d ~/.local/share/dotfiles.git/auto-commit.sh" \
    ls -d "$HOME/.local/share/dotfiles.git/auto-commit.sh"
  run_fail "ls -d ~/.local/share/dotfiles/auto-commit.sh" \
    ls -d "$HOME/.local/share/dotfiles/auto-commit.sh"
  pass "The unit starts the state-directory script, and no copy sits in the git database or the program."
}

story_uninstall() {
  cd "$HOME"
  explain \
    "Uninstall removes the timer unit and the generated script, and leaves the git database and the program in place." \
    "After uninstall, the service file and auto-commit.sh are gone. The git database HEAD and dotfiles-timer.sh are still listed."
  run "dotfiles-timer uninstall" bash "$TOOL/dotfiles-timer.sh" uninstall
  note "The next two commands must fail. Those files are what uninstall removes."
  run_fail "ls -d ~/.config/systemd/user/dotfiles-git-commit.service" \
    ls -d "$HOME/.config/systemd/user/dotfiles-git-commit.service"
  run_fail "ls -d ~/.local/state/dotfiles/auto-commit.sh" \
    ls -d "$HOME/.local/state/dotfiles/auto-commit.sh"
  run "ls -d ~/.local/share/dotfiles.git/HEAD" \
    ls -d "$HOME/.local/share/dotfiles.git/HEAD"
  run "ls -d ~/.local/share/dotfiles/dotfiles-timer.sh" \
    ls -d "$HOME/.local/share/dotfiles/dotfiles-timer.sh"
  pass "Uninstall removed the timer and the generated script, and left the repository."
}

record_tape() {
  local name="$1"
  local expect="$2"
  local height="$3"
  local kind="$4"
  local cast="$PROOF_OUT/$name.cast"
  local svg="$PROOF_OUT/$name.svg"
  local png="$PROOF_OUT/$name.png"
  local -a extra=()
  if [ "$kind" = movie ]; then
    extra=(-v --sleep 2 --fps 8)
  fi

  # No -c and no --header. Those paint a permanent first line above Check.
  console2svg capture \
    "${extra[@]}" \
    --mask-auto false \
    -w 120 \
    -h "$height" \
    -d windows \
    --timing realtime \
    --save-cast "$cast" \
    -o "$svg" \
    -- bash "$0" "$kind" "$name"
  if ! grep -q "$expect" "$cast"; then
    echo "visual-proof: tape $name.cast does not contain: $expect" >&2
    exit 1
  fi
  local last
  last="$(tail -n 1 "$cast" | sed -n 's/^\[\([0-9.][0-9.]*\),.*/\1/p')"
  awk -v t="$last" 'BEGIN { if (t+0 < 2) exit 1 }' || {
    echo "visual-proof: tape $name.cast is shorter than 2s (last=$last)" >&2
    exit 1
  }
  console2svg capture \
    --in "$cast" \
    --mask-auto false \
    -w 120 \
    -h "$height" \
    -d windows \
    --svg-converter rsvg-convert \
    -o "$png" \
    --format png
  test -s "$svg"
  test -s "$png"
  test -s "$cast"
}

all() {
  mkdir -p "$PROOF_OUT"
  cp "$DOCS/README.md" "$PROOF_OUT/README.md"
  git config --global user.email "laptop@localhost"
  git config --global user.name "laptop"
  git config --global --add safe.directory '*'
  prepare_remote
  bash "$TOOL/bootstrap.sh" --repo "$REMOTE" --branch laptop --system-ref system
  record_tape program-directory-and-git-database \
    'Result: PASS. Both directories are listed, and the branch is laptop.' 52 movie
  record_tape separate-database-program-and-baseline \
    'Result: PASS. The git database is separate from the program' 64 still
  record_tape track-home-bashrc \
    'Result: PASS. ~/.bashrc is tracked on laptop' 56 movie
  record_tape commit-bashrc-edit \
    'Result: PASS. The EDITOR line is committed on laptop.' 56 movie
  export UV_PROJECT_ENVIRONMENT="$HOME/.cache/dotfiles/githooks-runner"
  dotfiles config core.hooksPath "$HOME/.local/share/dotfiles/.githooks"
  uv sync --project "$HOME/.local/share/dotfiles/githooks-runner" --frozen -q
  record_tape hook-venv-lives-in-cache \
    'Result: PASS. Hooks use the program directory' 32 still
  record_tape doctor-hard-checks \
    'Result: PASS. Every hard check passed.' 40 movie
  record_tape update-merges-system-branch \
    'Result: PASS. laptop merged system' 52 movie
  # install enables the timer immediately. Stop it so the movie's script
  # is the commit on screen, then the later stills still see the unit files.
  bash "$TOOL/dotfiles-timer.sh" install
  systemctl --user stop dotfiles-git-commit.timer
  systemctl --user stop dotfiles-git-commit.service || true
  record_tape timer-script-commits-bashrc \
    'Result: PASS. The timer script committed the desk line' 64 movie
  record_tape timer-script-lives-in-state \
    'Result: PASS. The unit starts the state-directory script' 48 still
  record_tape uninstall-removes-timer-keeps-repo \
    'Result: PASS. Uninstall removed the timer' 36 still
  echo "visual-proof: wrote $PROOF_OUT"
}

case "${1:-}" in
  all) all ;;
  movie)
    case "${2:-}" in
      program-directory-and-git-database) story_program ;;
      track-home-bashrc) story_track ;;
      commit-bashrc-edit) story_edit ;;
      doctor-hard-checks) story_doctor ;;
      update-merges-system-branch) story_update ;;
      timer-script-commits-bashrc) story_timer ;;
      *) echo "visual-proof: unknown movie ${2:-}" >&2; exit 2 ;;
    esac
    ;;
  still)
    case "${2:-}" in
      separate-database-program-and-baseline) story_layout ;;
      hook-venv-lives-in-cache) story_hooks ;;
      timer-script-lives-in-state) story_timer_where ;;
      uninstall-removes-timer-keeps-repo) story_uninstall ;;
      *) echo "visual-proof: unknown still ${2:-}" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "usage: visual-proof.sh all | visual-proof.sh movie <name> | visual-proof.sh still <name>" >&2
    exit 2
    ;;
esac
