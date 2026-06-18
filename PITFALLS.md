# PITFALLS

Traps hit during implementation. Read before editing the dispatcher/harness.

- **PowerShell `$HOME` is read-only.** `$HOME = ...` throws "Cannot overwrite variable HOME".
  Use `Set-Variable -Name HOME -Value … -Force`. (Tests isolate HOME via the child runner `_invoke.ps1`.)
- **Don't build child-pwsh commands by string-interpolating args.** Zero args leaked an empty-string
  argument (`dotfiles ''` → "no such repo: "). Invoke via `pwsh -NoProfile -File _invoke.ps1 @args`
  so arg boundaries (including none) are preserved.
- **Dispatcher must be source-then-call portable.** zsh chokes on bash-only `${BASH_SOURCE[0]}` unless
  guarded by `[ -n "${BASH_VERSION:-}" ]` first (short-circuit). Tests do `. dotfiles.sh; dotfiles …`.
- **Hook stubs / `*.sh` MUST stay LF** even on Windows (Git-Bash/sh.exe runs them) — enforced in
  `.gitattributes`. A CRLF stub fails cryptically under `sh.exe`.
- **Stderr from `[Console]::Error.WriteLine` is real process stderr**, not the PS error stream — so
  `2>&1` inside the same PS session won't capture it; the child-process `2> file` redirection does.
- **`git config --default`** (used for safe defaults) needs git ≥ 2.18 (fine on CI runners).
- **`-doctor`/`-show`/`-resolve` are stubs (exit 3)** until their build nodes — don't treat
  exit 3 as a bug; it's "not implemented yet". (`-tick` is implemented as of node 4.)
- **PowerShell: an `if`-expression returning a one-element array slice UNROLLS to a scalar.**
  `$rest = if (...) { $args[1..1] } else { @() }` made `$rest` the STRING `'nvim'`, and splatting a
  scalar string (`@rest`) explodes it CHAR-BY-CHAR → `dotfiles -tick nvim` became `tick_one n`.
  `@(...)` around the slice did NOT help (the `if`-expression still unrolled). Fix: cast the whole
  assignment: `[object[]] $rest = if (...) {...} else {@()}`. (Bit node 4's `-tick <repo>` routing.)
- **bash `set -u` + multi-assignment `local` that references an earlier var in the SAME statement
  fails.** `local repo="$1" gd="/x/$repo"` → "repo: unbound variable" under `set -uo pipefail`
  (the harness sets it). Split into separate `local` lines.
- **Git-for-Windows mangles the `<rev>:<path>` colon into a Windows path.**
  `git show "refs/heads/main:.config/nvim/seed"` becomes `refs\heads\main;.config\...` and fails.
  `MSYS_NO_PATHCONV=1` "fixes" the colon but then breaks the MSYS `/tmp/...` `--git-dir` path. In
  tests, avoid `rev:path` entirely: use `git ls-tree -r --name-only <rev>` for presence and
  `git ls-tree -r <rev> -- <path>` + `git cat-file -p <blob>` for content.
- **A bare clone maps the origin's heads onto its OWN `refs/heads/*`, not `refs/remotes/origin/*`.**
  After `fetch origin <branch>` reset to `FETCH_HEAD`, not `origin/<branch>` (which won't exist).
