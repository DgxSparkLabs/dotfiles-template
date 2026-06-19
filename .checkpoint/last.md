# Last checkpoint

Branch: feat/sync-multi-repo-engine

## MOST RECENT: Node 11 CI FIX (windows leg RED -> Git-Bash-safe tar paths; committed, NOT pushed)
First CI run of the chained `interop` workflow: seed (ubuntu) PASSED, win (windows) FAILED, mac+verify
skipped. Windows tar error:
  `tar: D\:\a\\dotfiles-template\\dotfiles-template/_interop: Cannot open: No such file or directory`
  `tar: Error is not recoverable: exiting now` (exit 2)
ROOT CAUSE: `INTEROP_WORK: ${{ github.workspace }}/_interop` is a Windows drive-letter path on the
windows runner; the pack/unpack steps run under `shell: bash` (Git-for-Windows MSYS bash) and MSYS
`tar` cannot open a `D:\…` `-C` target (mangles the drive colon as a remote host + the backslashes).
`mkdir -p` did NOT help.
FIX (`.github/workflows/interop.yml` ONLY — all 6 pack/unpack steps, every leg, identical so behavior
never diverges): each step resolves an MSYS-safe dir first:
  `WORK="$INTEROP_WORK"; command -v cygpath >/dev/null 2>&1 && WORK="$(cygpath -u "$INTEROP_WORK")"`
then `mkdir -p "$WORK"` before extract and `tar -C "$WORK" … origin.git` (relative members + `-C`,
never an absolute Windows member). cygpath exists only under Git-for-Windows -> no-op on ubuntu/macos;
`D:\a\…` -> `/d/a/…` on windows. interop_step.sh UNCHANGED (invokes no tar; its git/printf/mkdir/file
ops accept native Windows paths). Repro'd the exact error locally under Git-Bash with a Windows-form
path; cygpath conversion makes mkdir+unpack+repack succeed and the bare repo's symbolic HEAD survives.
Suites green: `bash tests/run.sh bash` rc=0, `pwsh tests/run.ps1` rc=0. PITFALLS entry added.
Orchestrator re-runs the chained interop workflow on CI.

## PRIOR checkpoint below (Node 11 initial) ====================================================

## Last node DONE (committed locally; NOT yet pushed/CI-verified — orchestrator pushes + watches the new `interop` workflow across the chained OS legs)
- **Node 11** — cross-OS interop chain (L4.1-L4.6). Proves the SAME engine + SAME repo round-trips
  across ubuntu/windows/macos through one shared origin. This is the only layer that proves
  "mixing linux/windows/mac"; its real value runs ONLY on CI.
  - NEW `.github/workflows/interop.yml` — CHAINED 4 jobs (`needs:` sequenced):
    seed (ubuntu) -> win (windows) -> mac (macos) -> verify (ubuntu). The bare `origin` travels
    leg-to-leg as a TAR artifact (UNIQUE name per leg: origin-after-{seed,win,mac};
    upload-artifact@v4 is immutable). Each leg: checkout, install uv (mirrors unit.yml), unpack
    prior origin, run an OS-appropriate `tests/interop_step.sh` step, re-pack + upload.
  - NEW `tests/interop_step.sh` — ONE bash script for EVERY leg (Git-Bash on windows = the hooks'
    sh.exe surface; a pwsh port would test a different code path -> prove nothing about sameness).
    Subcommands: seed / leg <os> / verify / clash <os> <line> <date> / verify-clash <expected> /
    hookid <os>. The leg drives the REAL `dotfiles -tick` (engine under test) to commit+reconcile
    +push. Reads blobs via ls-tree+cat-file (never the GfW `<rev>:<path>` colon).
  - NEW `tests/interop_step.ps1` — thin wrapper: locates Git-for-Windows bash (PREFERS
    Program Files\Git over the WSL System32 stub) and delegates. CI uses `shell: bash` directly.
  - L4 mapping: L4.1 round-trip no spurious churn + a `.gitattributes` CONTROL (`legacy/raw.txt
    -text` stays CRLF while `* text=auto` text.conf is LF -> attribute is load-bearing, L4.1-control);
    L4.2 CRLF-on-Windows stored LF; L4.3 exec 100755 stable across the round-trip (read from the
    TREE; seeded on the ubuntu leg); L4.4 hook identity == `interop` via rev-parse
    --absolute-git-dir under sh.exe (windows leg, reuses node 8); L4.5 cross-OS same-line clash
    newest-committer-date wins regardless of push order (divergent parents forced by rewinding each
    clash leg to the seed commit; pinned dates); L4.6 nested path = ONE forward-slash entry.
  - unit.yml UNCHANGED (matrix intact). interop_step.* are NOT test_* so run.* never auto-run them.
- Local (Windows host): full chain in exact workflow order -> verify 5/0/1 (the 1 SKIP is L4.3, a
  NAMED Windows-seed-only skip: core.fileMode=false can't seed an exec bit; real assert runs on the
  CI ubuntu legs), verify-clash L4.5 PASS, hookid L4.4 PASS, reverse-clash PASS (date-not-push
  proof). Existing suites unbroken: `bash tests/run.sh bash` rc=0, `pwsh tests/run.ps1` rc=0.

## New pitfalls recorded (PITFALLS.md)
- Git-Bash `grep $'\r'` falsely reports no-CR on a CRLF stream -> count 0x0d via `od` (has_cr()).
- exec bit (L4.3) can only be seeded where core.fileMode is true (ubuntu, not Git-for-Windows);
  read mode from the TREE; Windows leg must not rewrite the file's content; local SKIP on Windows.
- `.gitattributes` added in the same commit DOES apply; `-text` opt-out file is the load-bearing
  control proving normalization is the attribute, not luck.
- cross-OS interop is ONE bash script on all legs, not a pwsh port; wrapper must avoid the WSL bash.
- a real same-line CLASH needs divergent parents (rewind to seed) not a fast-forward; pin dates.
- pass the bare origin between jobs as a TAR (preserves modes + symbolic HEAD); set origin HEAD
  symref in seed; upload-artifact@v4 names are immutable -> unique per leg.

## Next node (UNBLOCKED)
- **Node 12** — README full rewrite (layout, dispatcher grammar incl. `-x`==`--x`, per-repo config
  & hooks, framing paragraph, migration, Syncthing caveat, same-line-loss warning).

## Do NOT
- re-run a completed node; push to master; weaken tests; `git add -A` unscoped across $HOME.
- port interop_step.sh to a parallel pwsh implementation (defeats the cross-OS-sameness proof).
- assert L4.3 file mode read from the working tree (platform core.fileMode-dependent) — read the TREE.
- detect CR with `grep $'\r'` under Git-Bash (false no-match) — count 0x0d bytes via od.
- expect a naive sequential leg edit to create a clash (it fast-forwards) — rewind to the seed commit.
- reuse one artifact name across legs (upload-artifact@v4 is immutable) — unique name per leg.
