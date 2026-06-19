# HANDOFF — sync multi-repo engine (M1 complete)

**Status: DONE.** All 13 build-tree nodes implemented and CI-verified GREEN on ubuntu + macOS
(bash AND zsh) + windows. Branch `feat/sync-multi-repo-engine`. Not merged — awaiting your PR review.

Plan: `~/.claude/plans/quizzical-juggling-jellyfish.md`. Progress ledger: `STATE.md`. Traps: `PITFALLS.md`.

## What shipped
A uniform **multi-repo dotfiles engine**: `~/.dotfiles/` = `common/` (the engine, a normal git repo)
+ `bare-repos/<repo>` (pure bare git-dirs, each owning a disjoint slice of `$HOME`) + `hooks/`,
`config`, `state/`. One command, one timer, treats every repo identically; "machine" vs "sync" is
just how many machines write a repo.

- **Node 0** — engine layout restructure (`githooks/`, `githooks-runner/`, `timer/` at repo root;
  `.gitattributes` LF + cross-OS normalization; `.gitignore` normal-repo).
- **Node 2** — `dotfiles.sh`/`dotfiles.ps1` dispatcher: `dotfiles <repo> <git…>` passthrough,
  `bare-repos/` discovery, dash-verb grammar (`-x`==`--x`); heavy verbs re-exec under bash.
- **Node 3** — per-repo config (`~/.dotfiles/config`) + safe defaults: **tick OFF**, add tracked.
- **Node 4** — single-writer tick (scoped add → commit → push).
- **Node 5** — never-block merge: newest-wins, loser refs + `state/<repo>/conflicts.log`,
  modify/delete fallback, `-show`/`-resolve`.
- **Node 6** — robustness: stale `index.lock`/`MERGE_HEAD` recovery, concurrency lock, fail-isolation.
- **Node 7** — `-doctor`: overlap detection (the load-bearing exclusive-ownership guard) + health checks.
- **Node 8** — per-repo + `_shared` hook dispatch via the Python runner (repo identity by
  `git rev-parse --absolute-git-dir`; **verified under Git-for-Windows sh.exe**).
- **Node 9** — one timer fans out via `dotfiles -tick` + `[timer] interval`/`jitter`, all backends.
- **Node 10** — `bootstrap.{sh,ps1}` + legacy→container migration (`dotfiles -migrate`).
- **Node 11** — cross-OS interop chain (`interop.yml`): same repo round-trips ubuntu↔windows↔macos.
- **Node 12** — README rewritten for the new architecture (docs match shipped behavior).

## CI (ground truth)
- `unit` workflow: L0–L3 + L5 across ubuntu/macos(bash+zsh)/windows — GREEN (run 27800532889).
- `interop` workflow: chained seed→win→mac→verify (L4) — GREEN (run 27800532890).
- Named SKIPs only (live OS-scheduler bits gated behind `DOTFILES_TIMER_LIVE`; Windows exec-bit;
  `uv`-unset; spaced-repo-name auto-tick) — all with explicit reasons, none silent.

## How to open the PR
```sh
gh pr create --base master --head feat/sync-multi-repo-engine \
  --title "feat: multi-repo dotfiles sync engine (M1)" --body-file <(echo "see HANDOFF.md / plan")
```
(The orchestrator has opened it; link recorded in the loop's final message.) Review then merge when ready.

## Notes for the reviewer
- This is a **deliberate breaking change** to the template layout (`~/.dotfiles` becomes a container);
  existing users migrate once via `dotfiles -migrate`.
- The engine resolves its own path via `DOTFILES_SELF` (re-exec) — keep that when editing the dispatcher.
- Every cross-OS trap hit during the build is in `PITFALLS.md` — read it before touching shell/CI code.
