#!/usr/bin/env bash
# Record the instance workflow as console2svg stills plus an asciicast tape
# per step. The tape is the recording. The SVG and PNG are rendered from it.
set -euo pipefail

PROOF_OUT="${PROOF_OUT:-$GITHUB_WORKSPACE/proof}"
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

step_bootstrap() {
  banner "bootstrap onto ci-machine, baseline system"
  bash "$TOOL/bootstrap.sh" --repo "$REMOTE" --branch ci-machine --system-ref system
  echo "PROOF bootstrap ok"
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
  echo "program HEAD file: absent"
  test ! -e "$(old_directory)"
  echo "old directory: absent"
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

step_doctor() {
  cd "$HOME"
  banner "doctor"
  bash "$TOOL/dotfiles-doctor.sh" --skip-network
  echo "PROOF doctor ok"
}

step_update() {
  cd "$HOME"
  banner "merge the named baseline, not the host default"
  bash "$TOOL/dotfiles-update.sh"
  echo "HEAD=$(gitdir symbolic-ref HEAD)"
  test -f "$HOME/.local/share/dotfiles/SYSTEM_ONLY.txt"
  echo "SYSTEM_ONLY.txt: present (came from system)"
  test ! -e "$HOME/DEFAULT_ONLY.txt"
  echo "DEFAULT_ONLY.txt: absent (stayed on the default branch)"
  echo "PROOF update ok"
}

step_timer_install() {
  cd "$HOME"
  banner "install the timer"
  bash "$TOOL/dotfiles-timer.sh" install
  echo "PROOF timer-install ok"
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

01-bootstrap     bootstrap.sh checks out ci-machine and records system as the baseline
02-layout        HEAD is ci-machine, remote default is main, git dir and program are split, git add -A does not stage the git dir
03-hooks         core.hooksPath is the program .githooks; the runner venv is under ~/.cache
04-doctor        doctor reports the healthy setup
05-update        dotfiles update merges origin/system; the default-branch-only file stays absent
06-timer-install timer install finishes against the split git dir
07-timer-where   the generated script and unit point at ~/.local/state, not the git dir
08-uninstall     uninstall deletes timer files and leaves the git dir and the program
EOF
}

all() {
  mkdir -p "$PROOF_OUT"
  git config --global user.email "ci@github-actions"
  git config --global user.name "CI"
  git config --global --add safe.directory '*'
  prepare_remote
  record 01-bootstrap 'PROOF bootstrap ok'
  record 02-layout 'PROOF layout ok'
  record 03-hooks 'PROOF hooks ok'
  record 04-doctor 'PROOF doctor ok'
  record 05-update 'PROOF update ok'
  record 06-timer-install 'PROOF timer-install ok'
  record 07-timer-where 'PROOF timer-where ok'
  record 08-uninstall 'PROOF uninstall ok'
  write_index
  echo "visual-proof: wrote $PROOF_OUT"
}

case "${1:-}" in
  all) all ;;
  step)
    case "${2:-}" in
      01-bootstrap) step_bootstrap ;;
      02-layout) step_layout ;;
      03-hooks) step_hooks ;;
      04-doctor) step_doctor ;;
      05-update) step_update ;;
      06-timer-install) step_timer_install ;;
      07-timer-where) step_timer_where ;;
      08-uninstall) step_uninstall ;;
      *) echo "visual-proof: unknown step ${2:-}" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "usage: visual-proof.sh all | visual-proof.sh step <name>" >&2
    exit 2
    ;;
esac
