#!/usr/bin/env bash
# Run every test_*.sh under the chosen POSIX shell (default: bash; pass "zsh" to run under zsh).
# Aggregates: exits nonzero if any test file fails (its `_summary` returned nonzero).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHELL_BIN="${1:-bash}"
rc=0
for t in "$HERE"/test_*.sh; do
  printf '\n##### RUN %s (%s) #####\n' "$(basename "$t")" "$SHELL_BIN"
  "$SHELL_BIN" "$t" || rc=1
done
printf '\n##### run.sh overall rc=%d #####\n' "$rc"
exit "$rc"
