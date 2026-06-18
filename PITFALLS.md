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
- **Git-for-Windows runs work-tree verbs from ANY cwd; real Linux/macOS git does NOT.** `git
  merge` / `checkout` / `diff` / `add` in a bare repo driven by `--git-dir=<bare> --work-tree=$HOME`
  worked on Windows from an unrelated cwd, but on Linux/macOS git enforces NEED_WORK_TREE: the cwd
  must be INSIDE the work tree, else `merge` aborts ("must be run in a work tree"). In node 5 the
  merge then never started -> no conflicts staged -> no loser ref pinned -> no conflicts.log -> the
  per-path `git log -1 --format=%ct <rev>` / `update-ref` later got fed empty/garbage and printed
  `fatal: Needed a single revision` / `Not a valid object name`. (`add`/`commit`/`push` in node 4
  have NO such requirement, which is why node 4 passed CI but node 5 didn't.) FIX: run every
  work-tree verb as `git -C "$HOME" --git-dir=… --work-tree=…` so the cwd is the tree on all OSes.
  (`-resolve`'s blob extraction uses only `--git-dir` object ops — rev-parse/ls-tree/cat-file — so
  it needs no `-C`.) Verified in both `dotfiles.sh` and `dotfiles.ps1` `__df_reconcile`.
- **Capture both merge sides' FULL SHAs BEFORE merging; never re-resolve a symbolic ref after.**
  `ours=$(rev-parse HEAD)` + `theirs=$(rev-parse FETCH_HEAD)` BEFORE `merge --no-commit`, then use
  only those pinned SHAs for the newest-by-`%ct` compare, the loser-pin `update-ref`, and the
  blob extraction. A re-resolved `FETCH_HEAD`/`MERGE_HEAD` can be empty mid-merge and silently
  passes an empty object name to `git log`/`update-ref`. Guard both: empty `FETCH_HEAD` -> skip
  push; empty `HEAD` after the tick's own commit is a BUG -> fail loudly + skip (work-tree intact).
- **A `pre-push` hook is silently SKIPPED on Linux/macOS unless it has the +x bit.** Git-for-Windows
  runs hooks via sh.exe regardless of the mode bit, so a hook written without `chmod +x` "worked" on
  Windows but did NOT fire on Linux — the L2.10 push-exhaust test then saw push succeed (rc=0) and
  failed. In `test_merge.ps1`, after `[IO.File]::WriteAllText(hook, "#!/bin/sh`nexit 1`n")`, do
  `if ($IsLinux -or $IsMacOS) { chmod +x $hook }`. (The bash test already `chmod +x`'d its hook,
  which is why bash L2.10 passed CI.)
- **`sed -i 's/.../.../' file` is GNU-only; BSD/macOS sed misparses it (node-5 macOS-only RED).**
  GNU sed (Linux/CI ubuntu + Git-for-Windows) treats `-i` as "edit in place, no backup". BSD sed
  (macOS, which also ships bash 3.2.57) treats the token *after* `-i` as a MANDATORY backup suffix,
  so `sed -i 's/^MID$/X/' file` consumes the script as the suffix and the file as the program — the
  substitution silently never happens. In `tests/test_merge.sh` that meant M1's divergent edit was
  never made, so the second machine's tick saw no real clash: the merge produced no conflicted
  paths, no loser was pinned, and the newest-wins `git log -1 --format=%ct <rev>` / `update-ref`
  later got fed empty/unchanged revisions -> `fatal: Needed a single revision` / `Not a valid
  object name`. This hit EXACTLY the four `sed -i` call sites and the tests that depend on them:
  L2.2, L2.3 (and L2.4/L2.5 which reuse L2.3's clash), L2.12, L2.13. Everything else (config /
  dispatcher / tick, and the modify/delete L2.7 which uses `printf >`/`git rm`, not sed) passed on
  macOS, which is why the failure looked merge-specific. FIX: a portable `sed_inplace <script>
  <file>` helper in `tests/harness.sh` that rewrites via a temp file (`sed script file > tmp; cat
  tmp > file`), avoiding the `-i` suffix divergence entirely. NOTE for the next agent: the real
  macOS leg is BSD sed, NOT a bash-4 builtin — `dotfiles.sh`'s `__df_reconcile` itself was already
  3.2-clean (no `${var,,}`, `mapfile`, `declare -A`, `${arr[-1]}`, `&>`, or `local -n`); the audit
  came up empty there, so the only macOS-incompat construct was the test harness's `sed -i`.
- **zsh does NOT word-split unquoted `$var` / `$(cmd)` on whitespace by default (bash does) —
  node-5 macOS-*zsh*-only RED.** Our CI runs both `bash tests/run.sh bash` AND `zsh tests/run.sh
  zsh` on macOS; the bash leg (and ubuntu/windows) passed but the zsh leg failed ONLY in
  `test_merge.sh` (L2.3/L2.4[rc128]/L2.5/L2.7/L2.12 — the clash + modify/delete + resolve
  cluster). Root cause: `dotfiles.sh` had two loops that relied on bash word-splitting an
  unquoted expansion of newline-delimited git output — `__df_reconcile`'s per-path conflict loop
  (`for path in $conflicted` with a custom `IFS=$'\n'`) and `__df_resolve`'s ref loop (`for ref
  in $(git for-each-ref ...)`). zsh leaves `SH_WORD_SPLIT` OFF, so each loop iterated ONCE with
  the WHOLE multi-line blob as a single value. The body then fed that garbage to `git ls-files -u
  -- "$path"` / `git log -1 --format=%ct <rev>` / `update-ref <enc>` -> empty/invalid args ->
  `fatal: Needed a single revision` / `Not a valid object name` (same symptom as the earlier
  work-tree-cwd and `sed -i` bugs, different cause). NOTE: this contradicts the `sed -i` entry's
  closing claim that reconcile was fully portable — it was bash-3.2-clean (no bash-4 builtins) but
  NOT zsh-clean; word-splitting is a shell-DIALECT divergence, not a bash-version one. FIX (both
  belt + suspenders, applied to `__df_reconcile` AND `__df_resolve`): (1) `emulate -L sh 2>/dev/null
  || true` as the FIRST line of each function — under zsh this function-LOCALLY switches on
  POSIX-sh word-splitting + array semantics; under bash the builtin is absent so `|| true` makes
  it a no-op. (2) Rewrote each loop as `while IFS= read -r x; do ...; done <<EOF\n$blob\nEOF` so it
  never depends on word-splitting at all (the here-doc keeps the body in the CURRENT shell, unlike
  a pipe, preserving `$logf`/`$best_*` state). Glob `for d in "$base"/*/` loops were NOT affected
  (zsh globs by default). Production behavior on bash is identical. Verify on Windows with `bash
  tests/run.sh bash` + `pwsh -File tests/run.ps1`; CI re-verifies the zsh leg.
- **git-config section names forbid spaces -> a spaced repo name can't key `<repo>.tick`** (node 6
  L5.17). Routing/discovery/passthrough quoting holds fine for a repo dir named `my repo`
  (`dotfiles "my repo" status`, `-ls`, `git add/commit` all work), but `git config -f cfg "my
  repo.tick" on` fails with `error: invalid key: my repo.tick` — git restricts a top-level section
  name to `[A-Za-z0-9-.]`. The per-repo settings schema (`<repo>.<key>`, nodes 3-5) makes the repo
  name the section, so a spaced repo CANNOT be auto-tick-enabled under the current schema. The
  subsection form `[dotfiles "my repo"] tick` (dotted `dotfiles.my repo.tick`) DOES accept spaces,
  but adopting it is a config-schema change spanning nodes 3-5 — out of scope for node 6. Surfaced
  as a NAMED skip `L5.17-autotick` (no silent drop). If a future node wants spaced-name auto-tick,
  migrate the schema to the `dotfiles.<repo>.<key>` subsection form everywhere (readers + writers +
  tests), don't special-case it.
- **The tick lock/recovery must resolve the REAL git-dir, not assume the bare dir IS it** (node 6).
  A "pure" bare repo's metadata IS `bare-repos/<name>/`, but a non-bare repo wrongly placed there
  (L5.15) keeps its metadata in `bare-repos/<name>/.git`. `index.lock`, `MERGE_HEAD`, and the
  `dotfiles-tick.lock` dir live in the REAL git-dir. `__df_gitdir_real` uses `git --git-dir=<dir>
  rev-parse --absolute-git-dir` (git itself returns `<dir>/.git` for a non-bare repo) so recovery +
  locking land in the right place for both. Don't hardcode `<dir>/MERGE_HEAD`.
- **Lock release on EVERY exit path of the tick** (node 6). `__df_tick_one` has many early returns
  (add failed, commit failed, push exhausted, detached HEAD...). Acquiring the lock inline and
  releasing only at the end would leak the lock on any early return, wedging the repo for the stale
  threshold. Fix: split the real work into `__df_tick_one_body`; the wrapper acquires, recovers,
  calls the body, and releases unconditionally — bash captures rc then releases; pwsh uses
  `try { return (body) } finally { release }`. (A leaked lock is only an inconvenience — the next
  tick reclaims it after the threshold — but never-block wants it released promptly.)
- **Backdate planted stale locks by a full day, not by the threshold** (node 6 tests). The stale
  threshold is configurable (`DOTFILES_LOCK_STALE`, default 60s; tests set 1s for L5.23). To make a
  planted `index.lock`/lock-dir unambiguously "stale" regardless of the threshold under test, set
  its mtime to 1 day ago (`touch -d '1 day ago'` / BSD `touch -t`; pwsh `(...).LastWriteTime =
  (Get-Date).AddDays(-1)`). For the LIVE-lock concurrency test (L5.27) do the OPPOSITE: leave the
  lock fresh and keep the default 60s threshold so it reads as live and the second tick skips.
- **PowerShell `-like` is CASE-INSENSITIVE; bash `case`-glob is case-SENSITIVE** (node 7).
  `Assert-NotContains $out 'OVERLAP'` FAILED on the clean doctor output because that output
  contains "no overlaps" and `-like '*OVERLAP*'` matches "overlap" case-insensitively — while the
  IDENTICAL bash assertion (`case "$out" in *OVERLAP*)`) PASSED because bash glob matching is
  case-sensitive. So a shell-parity test can silently diverge purely on case folding. FIX: assert
  on a token that can't collide across case (the clean run was instead checked with
  `not-contains "error(s)"`). When porting an assertion between the two harnesses, remember the
  matchers differ in case sensitivity, not just syntax.
- **`-doctor`/`-show`/`-resolve` are no longer stubs** — as of node 7 ALL heavy verbs are
  implemented; none return exit 3. (Earlier PITFALL entry about "exit 3 = not implemented" is now
  fully obsolete.)
- **`DOTFILES_COMMON` is env-overridable (both shells, node 7).** Default still resolves from the
  script's own location (`BASH_SOURCE`/`$PSCommandPath`), but `$env:DOTFILES_COMMON` /
  exported `DOTFILES_COMMON` wins if set. This is what lets the engine-behind (L0.19) and
  engine-not-a-git-repo (L5.26) doctor tests point the engine at a FAKE dir in a child process
  (PS `Invoke-DF` child inherits the env var; bash test reassigns the var in-process). The zsh
  heavy-verb re-exec forwards `DOTFILES_COMMON` through the env too. If you spawn a child that must
  see the REAL engine, do NOT leak a test's `$env:DOTFILES_COMMON` — the PS doctor tests reset it
  to `$null` immediately after each `Invoke-DF`.
- **Doctor exit policy: nonzero ONLY on an ERROR** (node 7). ERROR = a path tracked by >1 repo
  (overlap), a corrupt/non-git dir under `bare-repos/`, or the engine dir not being a git repo.
  Everything else (no upstream, detached HEAD, hooksPath unset/missing, tick off, engine behind) is
  a warning/info and KEEPS exit 0. Don't "tighten" doctor to fail on warnings — the plan (G) shows
  `--update`-class advice as warnings, and a noisy-but-healthy machine must still script-pass.
- **macOS zsh leg — heavy git verbs re-exec under bash.** zsh word-splitting/array semantics made
  per-construct fixes unreliable (two attempts — `emulate -L sh`, while-read loops — did NOT clear
  the macOS zsh merge failures, and zsh can't be reproduced on the Windows host), so
  tick/show/resolve/doctor now delegate to bash: when the dispatcher is sourced into a non-bash
  shell (`[ -z "${BASH_VERSION:-}" ]`), `dotfiles()` re-execs `bash "$DOTFILES_SELF" "$tok" "$@"`
  (DOTFILES_ROOT + DOTFILES_COMMON passed through the env, HOME inherited) and returns its status.
  [SUPERSEDED detail: this originally re-exec'd `"$DOTFILES_COMMON/dotfiles.sh"`; see the next
  entry for why that broke the doctor engine tests and why DOTFILES_SELF is the fix.] The
  bottom-of-file guard re-enters `dotfiles()` UNDER bash where `BASH_VERSION` is set, so the same
  `[ -z ... ]` test is false in the child -> real body runs once, NO recursion. Lightweight verbs
  (passthrough/-ls/-config/-help/-update/-timer) stay in-shell. The prior `emulate -L sh` /
  while-read changes are kept (harmless hygiene). NOTE: `$DOTFILES_COMMON` resolution depends on
  `$0` under non-bash (BASH_SOURCE is unset there); zsh sets `$0` to the sourced file (works), but
  dash sets `$0` to `dash` (the re-exec then can't find the script unless cwd is the common dir) —
  irrelevant to the macOS zsh target, but don't "fix" the re-exec by reasoning from a dash repro.
- **zsh->bash re-exec must use the REAL script path (DOTFILES_SELF), not
  `$DOTFILES_COMMON/dotfiles.sh` — DOTFILES_COMMON is env-overridable for doctor engine
  inspection.** The macOS zsh leg re-execs heavy verbs under bash. The re-exec originally ran
  `bash "$DOTFILES_COMMON/dotfiles.sh"`, but the doctor engine tests (L0.19 engine-behind, L5.26
  engine-not-git) override `DOTFILES_COMMON` to a FAKE engine dir that has NO dotfiles.sh — so
  the zsh re-exec died with `rc 127` + `bash: <tmp>/fakeengine/dotfiles.sh: No such file or
  directory` (ubuntu runs bash directly and pwsh runs natively, so neither re-execs -> both
  stayed green; only the zsh leg failed). FIX: compute `DOTFILES_SELF` at load from THIS file's
  own location (`${BASH_SOURCE[0]}` under bash, `$0` under a sourced zsh shell) independent of
  (and never overridden by) `DOTFILES_COMMON`, and re-exec `bash "$DOTFILES_SELF" "$tok" "$@"`
  while still FORWARDING `DOTFILES_COMMON`/`DOTFILES_ROOT` through the env so the bash child's
  doctor inspects the same (fake) engine the test set. In normal operation DOTFILES_SELF's dir ==
  DOTFILES_COMMON, so behavior is unchanged; the split only matters when DOTFILES_COMMON is
  overridden. No recursion: the bottom-of-file guard re-enters `dotfiles()` under bash where
  `BASH_VERSION` is set, so the `[ -z "${BASH_VERSION:-}" ]` re-exec test is false -> body runs
  once. (Verified locally with a `dash -c '. "$0"' "$REPO/dotfiles.sh"` repro forcing `$0` to the
  real script with DOTFILES_COMMON -> fake dir: doctor inspected the fake engine and returned the
  right rc, NOT 127.)
