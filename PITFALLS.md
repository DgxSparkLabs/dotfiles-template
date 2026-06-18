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
- **`git clone --bare <origin>` sets `remote.origin.url` but NO fetch refspec** (no
  `+refs/heads/*:refs/remotes/origin/*`), so `git fetch origin` fails ("couldn't find remote ref
  HEAD"), there are no `refs/remotes/origin/*`, and the checked-out branch has NO `@{upstream}` —
  so the node-5 tick skips fetch/merge/push entirely. To build a 2nd machine that behaves like the
  1st, mirror `mk_repo_with_origin`: `git init --bare` + `git remote add origin <origin>` (THIS
  installs the standard refspec) + `git fetch origin` + `git checkout -B <branch> origin/<branch>`.
  (Bit the node-5 multi-machine harness; `mk_machine`/`Mk-Machine` now do it the init+remote-add way.)
- **`refs/sync-losers/<path>/<epoch>` — a raw repo path is NOT a valid ref name.** Git rejects ref
  components with a leading dot (`.config`), `..`, or ending `.lock` ("refusing to update ref with
  bad name"). Encode the path to ONE safe component first: collapse every non-`[A-Za-z0-9]` to `_`
  (`__df_ref_enc`). `-resolve` re-encodes the queried path the same way to find the ref.
- **modify/delete conflicts don't show two checkout-able sides.** `git ls-files -u -- <path>`
  reports stage 2 = ours, stage 3 = theirs. A content clash has BOTH; a modify/delete has only ONE
  (the editing side). Branch on which stage exists: both -> newest-committer-date wins; one ->
  edit-beats-delete (checkout the surviving stage's side). `checkout --ours/--theirs` for the
  missing side would error, so never call it unconditionally.
- **Deterministic newest-wins needs committer-date pinned on BOTH sides.** Set
  `GIT_AUTHOR_DATE`+`GIT_COMMITTER_DATE` (the resolver compares `%ct`, the committer date). In
  tests, `VAR=... ( subshell )` is a bash syntax error — `export` the dates (or use a wrapper fn)
  before the tick. The child pwsh in `Invoke-DF` inherits `$env:GIT_*_DATE`, so set them before it.
- **Forcing push-reject EXHAUST deterministically:** don't race the clock injecting commits into
  origin between fetch and push. Install a `pre-push` hook (`#!/usr/bin/env bash\nexit 1`, LF +
  executable) on the pushing repo — it rejects EVERY attempt, so the bounded retry loop exhausts
  predictably. Bare repos fire `$GIT_DIR/hooks/pre-push` on `push` even with `--git-dir`.
