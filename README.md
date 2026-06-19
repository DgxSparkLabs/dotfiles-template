# dotfiles — a multi-repo sync engine built on plain git

Sync selected files across machines with git and nothing else: no symlinks, no daemon, no
extra sync tool. One command drives every repo; one timer auto-commits and reconciles them
all each minute. Bidirectional, never-blocking (newest edit wins, the loser is recoverable),
and every change is just a git commit with full history.

> **`<placeholder>`** — anything in angle brackets is something you replace with your own
> value before running the command.

---

## How it fits together

`~/.dotfiles` has three parts:

- **`common/`** is the **engine** — one normal git repo (this template, or your fork) that
  you update with `dotfiles -update`.
- **`bare-repos/*`** are **pure git repos**, each owning a different, non-overlapping set of
  files in `$HOME`.
- **`hooks/`, `config`, `state/`** are the engine's **per-repo data**, kept *beside* the
  repos, never *inside* them.

You touch every repo through one command, `dotfiles <repo> <git…>`, and one timer
auto-commits and reconciles them all each minute. A repo written from one machine behaves
like private config; a repo whose branch several machines share behaves like a shared folder
that auto-merges and never blocks (newest edit wins; the loser is recoverable). "Machine"
and "sync" are just words for **how many machines write a repo** — the program treats every
repo identically. A path belongs to **exactly one** repo; `dotfiles -doctor` warns if you
break that.

### When NOT to use this

For **binary or large files**, or for **real-time** propagation, [Syncthing](https://syncthing.net/)
is strictly better. This system trades those away for free version history, no extra daemon,
and reuse of the git toolchain (hooks, branches, diffs, `git log`). Reach for it when your
synced content is text config you'd want history on, not media or live state.

---

## On-disk layout

After setup, `$HOME` looks like this:

```
$HOME/
  .dotfiles/
    common/                         # ENGINE — normal git repo (clone of this template / your fork)
      .git/  dotfiles.sh  dotfiles.ps1  timer/  githooks/  githooks-runner/  bootstrap.*  migrate.*
    bare-repos/
      machine/                      # PURE bare git-dir — owns ~/.gitconfig, ~/.bashrc, ...
        HEAD config objects/ refs/  #   (config holds only git's own keys incl. core.hooksPath)
      nvim/                         # PURE bare git-dir, branch=sync — owns ~/.config/nvim
        HEAD config objects/ refs/  refs/sync-losers/...
      shell/                        # PURE bare git-dir, branch=sync — owns ~/.config/shell
    hooks/
      _shared/<hookname>            # optional: runs for every repo
      nvim/<hookname>               # per-repo hooks (tracked by that repo; travel when it syncs)
    config                          # per-repo settings (git-config syntax), OUTSIDE bare repos
    state/
      nvim/conflicts.log            # LOCAL clash log (never synced)
  .gitconfig  .bashrc  .tmux.conf   # real files (work-tree) — owned by `machine`
  .config/nvim/init.lua ...         # real files (work-tree) — owned by `nvim`
  .config/shell/aliases ...         # real files (work-tree) — owned by `shell`
```

Mental model: `common/` is the tool; `bare-repos/*` are pure git brains; `hooks/`, `config`,
`state/` are the tool's per-repo data kept *beside* the brains, never *inside* them; the
dotfiles themselves are ordinary files in `$HOME`.

### Profile setup

The profile sources the tracked dispatcher with **one line**; all logic lives in the engine.

**Bash / Zsh** — `~/.bashrc` / `~/.zshrc`:

```sh
[ -f "$HOME/.dotfiles/common/dotfiles.sh" ] && . "$HOME/.dotfiles/common/dotfiles.sh"
```

**PowerShell** — `$PROFILE`:

```powershell
if (Test-Path "$HOME\.dotfiles\common\dotfiles.ps1") { . "$HOME\.dotfiles\common\dotfiles.ps1" }
```

`bootstrap.{sh,ps1}` appends this line for you (idempotently).

---

## First-run setup

Brand-new user, no prior dotfiles. `~/.dotfiles/common/bootstrap.sh` (or `bootstrap.ps1`)
runs steps 1–4 in one go and **deliberately leaves step 5 (verify + enable) to you**.

```sh
# 1. Get the engine (the tool). Fork the template first if you want your own copy.
git clone https://github.com/<YOU>/dotfiles.git ~/.dotfiles/common

# 2. Wire the command into your shell, then reload.
#    bash/zsh — append to ~/.bashrc or ~/.zshrc:
echo '[ -f "$HOME/.dotfiles/common/dotfiles.sh" ] && . "$HOME/.dotfiles/common/dotfiles.sh"' >> ~/.bashrc
exec $SHELL
#    PowerShell — append to $PROFILE:
#      if (Test-Path "$HOME\.dotfiles\common\dotfiles.ps1") { . "$HOME\.dotfiles\common\dotfiles.ps1" }
#      . $PROFILE

# 3. Create your first bare repo (your machine config) on a per-machine branch.
mkdir -p ~/.dotfiles/bare-repos
git clone --bare https://github.com/<YOU>/dotfiles-machine.git ~/.dotfiles/bare-repos/machine
dotfiles machine config status.showUntrackedFiles no
dotfiles machine config core.hooksPath "$HOME/.dotfiles/common/githooks"
dotfiles machine checkout -b "$(hostname)" master          # this machine's branch
dotfiles machine push -u origin "$(hostname)"

# 4. Start the one timer (it runs every minute, but ticks ONLY repos you've enabled).
dotfiles -timer install

# 5. VERIFY, then ENABLE this repo (tick defaults OFF for safety — see "the setup contract").
dotfiles machine status        # confirm branch/upstream/contents look right
dotfiles -doctor               # confirm no overlap, hooks wired, upstream set
dotfiles -config machine.tick on   # NOW it auto-syncs
```

### The setup contract (verify, then enable)

`tick` **defaults OFF**. A freshly added or cloned repo does *nothing* — the timer skips it —
until you explicitly enable it:

```
clone/configure a repo → verify (dotfiles <repo> status, dotfiles -doctor) → dotfiles -config <repo>.tick on
```

Enabling is the **last, deliberate step**. This prevents a half-set-up repo from committing,
overwriting local `$HOME` files, or pushing a bad state before you've checked your work.

### Adding more repos

A repo is just a directory under `~/.dotfiles/bare-repos/`. Drop one in and it is discovered
automatically — no reinstall, the one timer ticks it next cycle (once enabled).

```sh
# A SYNC repo: a shared branch every machine writes (this is what makes it "sync").
git clone --bare https://github.com/<YOU>/dotfiles-nvim.git ~/.dotfiles/bare-repos/nvim
dotfiles nvim config status.showUntrackedFiles no
dotfiles nvim config core.hooksPath "$HOME/.dotfiles/common/githooks"
dotfiles nvim checkout sync                      # the single shared branch
dotfiles nvim push -u origin sync
dotfiles nvim status && dotfiles -doctor         # VERIFY before enabling
dotfiles -config nvim.tick on                    # enable (tick defaults OFF)
```

"machine" = sole writer (a per-machine branch). "nvim"/"shell" = a shared `sync` branch every
machine writes. **Same program.** Selective membership = clone a repo only on the machines you
want it; it simply never syncs where it isn't cloned.

---

## The `dotfiles` command

The **first token** decides everything:

| Form | Meaning |
| --- | --- |
| `dotfiles <repo> <git…>` | bare token → run git on that bare repo (work-tree = `$HOME`). Any repo name is legal — a repo named `show` is reachable as `dotfiles show status`. |
| `dotfiles -<verb> [args]` | dashed token → a management verb. **One or two dashes are equivalent** (`-ls` == `--ls`). |
| `dotfiles` | no args → list repos (same as `-ls`). |

A repo name **always wins** over a verb name; verbs are only matched on a dash-prefixed
token. `dotfiles bogus status` → `no such repo` (exit 1); `dotfiles -bogus` → `unknown
command` (exit 2).

### Management verbs

| Verb | Purpose | Example |
| --- | --- | --- |
| `-ls` | List discovered repos. | `dotfiles -ls` |
| `-config <repo>.<key> [value]` | Read/write engine settings in `~/.dotfiles/config`. | `dotfiles -config nvim.add all` |
| `-tick [<repo>]` | Run the sync tick now — all enabled repos, or just one. | `dotfiles -tick nvim` |
| `-doctor` | Health + overlap check across all repos. | `dotfiles -doctor` |
| `-show` | List recorded sync conflicts per repo. | `dotfiles -show` |
| `-resolve <path>` | Recover the losing side of a conflict beside the live file. | `dotfiles -resolve .config/nvim/init.lua` |
| `-timer <subcommand>` | Manage the single auto-tick timer. | `dotfiles -timer install` |
| `-update` | Upgrade the engine (`git pull --ff-only` in `common/`). | `dotfiles -update` |
| `-migrate` | Migrate a legacy single-repo layout to this one. | `dotfiles -migrate` |
| `-help` | Show the built-in help. | `dotfiles -help` |

### Representative outputs

```text
$ dotfiles -ls
machine
nvim
shell

$ dotfiles -doctor
engine:  /home/you/.dotfiles/common  branch main, up to date
repos:
  machine  branch laptop   upstream origin/laptop   tick:on  add:tracked hooks:wired
  nvim     branch sync     upstream origin/sync     tick:on  add:all     hooks:wired
  shell    branch sync     upstream origin/sync     tick:on  add:tracked hooks:wired
ownership: 142 paths across 3 repos, no overlaps
all checks passed

$ dotfiles -show
machine:	(no conflicts)
nvim:	2026-06-18T08:02:11	.config/nvim/init.lua	winner=theirs	loser=a1c2e9f
shell:	(no conflicts)

$ dotfiles -resolve .config/nvim/init.lua
clash in repo nvim   loser=a1c2e9f
--- winner (current file) ---     --- loser (a1c2e9f) ---
loser written to: /home/you/.config/nvim/init.lua.loser   (merge by hand, then rm it)
```

`-timer status` prints the native scheduler's status (systemd `systemctl --user status` on
Linux, `schtasks` / launcher state on Windows), not a custom format — so you read the real
OS view of the timer.

---

## Per-repo configuration

Settings live in a single file, `~/.dotfiles/config`, in **git-config syntax** (sections =
repos), read via `git config -f`. It is **per-machine** (never pushed). Read or write it with
`dotfiles -config <repo>.<key> [value]`:

```sh
dotfiles -config nvim.add all          # nvim grabs new untracked files too (git add -A, scoped)
dotfiles -config machine.add tracked   # machine: tracked paths only (default)
dotfiles -config archive.tick off      # park a repo: keep it, stop auto-ticking
dotfiles -config nvim.tick on          # include in the tick
```

The file itself:

```ini
[machine]
  tick = on               ; explicitly enabled AFTER setup was verified
  add  = tracked          ; -> git add -u
[nvim]
  tick = on
  add  = all              ; -> git add -A, scoped to nvim's own tracked dirs
[timer]
  interval = 60           ; seconds between ticks
  jitter   = 15           ; +- random seconds, to de-sync N machines' pushes
```

### Defaults are safe-by-default

A brand-new repo does nothing until you opt in:

| key | default | why this default (the mistake it prevents) |
| --- | --- | --- |
| `tick` | **off** | A freshly added/cloned repo is NOT auto-ticked. Until you verify its branch, upstream, ownership and contents and run `dotfiles -config <repo>.tick on`, the timer never commits/merges/pushes it — so it can't overwrite local `$HOME` files or push a half-set-up state before you've checked in your work. |
| `add` | **tracked** (`-u`) | Auto-stage only already-tracked paths. Never sweeps up NEW untracked files (a common way secrets / huge build artifacts get committed). Opt into `all` (`-A`) per repo, deliberately. Even `add = all` is **scoped** to the directories that repo already owns — it can never reach into another repo's territory under a shared parent like `~/.config`. |

Junk values (`tick = maybe`, `add = foo`) fall back to the safe default with a warning; a
malformed config file is refused safely (defaults used), never crashing the tick.

Engine-level timer settings live under `[timer]`: `interval` (seconds, default 60) and
`jitter` (± seconds, default 15).

---

## Hooks (per-repo + shared)

Each bare repo's git `config` sets `core.hooksPath = ~/.dotfiles/common/githooks` — a single
set of shared stubs. Git tells the stub which repo is firing, so one stub set serves every
repo. The runner identifies the repo via `git rev-parse --absolute-git-dir` (basename) and
runs, if present:

1. `~/.dotfiles/hooks/_shared/<hook>` — for **every** repo.
2. `~/.dotfiles/hooks/<repo>/<hook>` — for **that** repo only.

```
dotfiles nvim commit
 └▶ git --git-dir=~/.dotfiles/bare-repos/nvim --work-tree=$HOME commit
     └▶ core.hooksPath = ~/.dotfiles/common/githooks  →  runs stub pre-commit
         └▶ stub: uv run --project ~/.dotfiles/common/githooks-runner -m dotfiles_githooks pre-commit
             └▶ runner: repo = basename(git rev-parse --absolute-git-dir) → "nvim"
                 ├▶ run ~/.dotfiles/hooks/_shared/pre-commit   (if present; all repos)
                 └▶ run ~/.dotfiles/hooks/nvim/pre-commit      (if present; this repo)
```

`hooks/<repo>/` is tracked content of that repo's work-tree, so **hooks travel when the repo
syncs**. Nothing hook-related is stored inside the bare git-dir — only git's native
`core.hooksPath` key.

Example — format Lua before each `nvim` commit:

```sh
mkdir -p ~/.dotfiles/hooks/nvim
cat > ~/.dotfiles/hooks/nvim/pre-commit <<'EOF'
#!/bin/sh
files=$(git diff --cached --name-only --diff-filter=ACM | grep '\.lua$')
[ -n "$files" ] && command -v stylua >/dev/null && stylua $files
EOF
chmod +x ~/.dotfiles/hooks/nvim/pre-commit
dotfiles nvim add ~/.dotfiles/hooks/nvim/pre-commit   # track it → travels with the repo
dotfiles nvim commit -m "nvim: stylua pre-commit hook"
```

**Prerequisites:** [uv](https://docs.astral.sh/uv/) on `PATH` wherever git runs hooks
(the systemd timer unit bakes `~/.local/bin:~/bin:~/.cargo/bin` so `uv` resolves under it).
On Windows, **Git for Windows** provides the `sh.exe` that runs the stubs. Sync the runner
package once: `uv sync --project ~/.dotfiles/common/githooks-runner`.

---

## The single timer

One installed unit/task/loop is ever created, regardless of how many repos you have. Its
payload is a call to `dotfiles -tick`, which **fans out over every enabled repo** under
`bare-repos/` — discovery is the registry, so a new repo on disk is ticked next cycle. Drive
it through `dotfiles -timer`:

```text
dotfiles -timer install      # write files, enable autostart, start now
dotfiles -timer reinstall    # uninstall + install (still exactly one timer)
dotfiles -timer enable       # turn on autostart
dotfiles -timer disable      # turn off autostart and stop (keep files)
dotfiles -timer start        # run now (also enables)
dotfiles -timer stop         # stop now (transient — resumes on reboot if enabled)
dotfiles -timer status       # native scheduler status
dotfiles -timer logs         # recent activity
dotfiles -timer uninstall    # full removal (alias: remove)
```

Backends, one per platform (all singletons, names preserved):

- **Linux** — a systemd **user** timer (`dotfiles-git-commit`), PATH-injected for `uv`.
- **Windows admin shell** — a Task Scheduler task; survives logoff.
- **Windows non-admin shell** — a windowless VBS launcher in Startup that fires a detached
  `pwsh` loop at each logon; logs to `%TEMP%`. No admin, no console flash.

Cadence is `[timer] interval` seconds; `[timer] jitter` adds a per-fire random delay
(plus systemd `RandomizedDelaySec`) so N machines don't push in lockstep.

---

## Managing files

```sh
# ADD a file to a specific repo + branch:
dotfiles nvim add ~/.config/nvim/init.lua
dotfiles nvim commit -m "nvim: add init.lua"
dotfiles nvim push

# REMOVE from a repo (stop tracking, keep the file on disk):
dotfiles nvim rm --cached ~/.config/nvim/old.lua
dotfiles nvim commit -m "nvim: untrack old.lua"

# MOVE a path's ownership (machine → nvim) — keeps exclusivity intact:
dotfiles machine rm --cached ~/.config/nvim/init.lua && dotfiles machine commit -m "release init.lua"
dotfiles nvim    add          ~/.config/nvim/init.lua && dotfiles nvim    commit -m "adopt init.lua"
dotfiles -doctor   # confirm no overlap remains
```

Per-repo ignore patterns live in that repo's `info/exclude`.

### `-doctor` and the exclusive-ownership invariant

**Every path must be tracked by exactly one repo.** Repos share `$HOME` as their work-tree,
so if two repos track the same path, each tick checks out its own version and the file
*flaps* between them. This is the load-bearing invariant; `-doctor` is the smoke detector.

`-doctor` reports an `engine:` line, a per-repo block (branch, upstream, tick, add, hooks),
an `ownership:` overlap check, and a `warnings:`/info block where **every problem prints an
actionable fix**. It exits nonzero only on an **error** (a path in >1 repo, or a corrupt
non-git dir under `bare-repos/`); warnings (no upstream, detached HEAD, hooksPath unset) and
info (tick off) do not change the exit code.

A sample with problems:

```text
$ dotfiles -doctor
engine:  /home/you/.dotfiles/common  branch main, up to date
repos:
  machine  branch laptop   upstream origin/laptop   tick:on  add:tracked hooks:wired
  nvim     branch sync     upstream (none)          tick:on  add:all     hooks:MISSING
  shell    branch detached upstream origin/sync     tick:off add:tracked hooks:wired
ownership: OVERLAP
  .config/nvim/init.lua   tracked by: nvim, machine
    fix -> dotfiles machine rm --cached .config/nvim/init.lua
warnings:
  nvim: no upstream for 'sync'   fix -> dotfiles nvim push -u origin sync
  nvim: core.hooksPath not set   fix -> dotfiles nvim config core.hooksPath "$HOME/.dotfiles/common/githooks"
  nvim: tick is ON but core.hooksPath is unset (auto-commits run no hooks)   fix -> dotfiles nvim config core.hooksPath "$HOME/.dotfiles/common/githooks"
  shell: detached HEAD (no branch)   fix -> dotfiles shell checkout <branch>
  shell: tick is OFF (won't sync)   info -> dotfiles -config shell.tick on
3 error(s), 4 warning(s)
```

---

## Migration (existing single-repo users)

If you used the older single-bare-repo layout (one `~/.dotfiles` bare repo + intermixed
helper files), `dotfiles -migrate` moves you onto this one. **Your work-tree files in `$HOME`
never move** — only the git-dir relocates, and the engine splits out into `common/`.

```sh
dotfiles -migrate
```

It does, in safe order: (1) **stop the old timer first** (the old install baked the old
`GIT_DIR`, so it must not commit during the move); (2) move *only* the old bare repo's git
metadata into `bare-repos/machine/`; (3) ensure the engine is present at `common/`; (4) wire
`machine`'s `core.hooksPath` to the engine's `githooks`; (5) swap the old `dotfiles` /
`dotfiles-timer` aliases for the sourced dispatcher; (6) `dotfiles -timer install`. It aborts
clearly on an ambiguous state (both legacy and migrated layouts present, or neither).

After migrating, `dotfiles machine status` should be clean and `-doctor` green. The old
`dotfiles update` (master→machine propagation) is now plain git: `dotfiles machine merge
master`. `-update` now means **upgrade the engine**.

---

## Caveats — read these

### Never track secret files

> ⚠️ With a repo's `tick` enabled, **any tracked file is committed and pushed within ~60s of
> being modified.** Audit before you `dotfiles <repo> add` anything new. Keep secrets out:
> put patterns (`.ssh/id_*`, `.netrc`, `.aws/credentials`, `.env*`, `*.pem`, `*.key`) in a
> repo's `info/exclude`, and keep `add = tracked` (the default) so a stray new file is never
> auto-staged. `add = all` plus a secret in an owned directory is the dangerous combination.

### Same-line edits: newest wins, loser recoverable

The sync tick **never blocks**. Non-overlapping edits auto-merge. But if two machines edit the
**same line** of the same file before syncing, the engine cannot merge them — so it picks the
**newest edit by committer-date** and the other side **loses**. The loser is not discarded:
it is pinned to a local ref and logged in `state/<repo>/conflicts.log`. List clashes with
`dotfiles -show`; recover a loser beside the live file with `dotfiles -resolve <path>` (writes
`<path>.loser` for you to merge by hand, then delete). A modify-on-one / delete-on-another
clash resolves as **edit-beats-delete** (the file is kept).

### Garbage collection

Pinned losers are real refs and survive a normal `git gc`, but an aggressive
`git gc --prune=now` can still reap them. Resolve clashes you care about promptly.

---

## A day with it (worked example)

1. **Set up the first machine (desktop).** First-run setup → engine + a `machine` repo on
   branch `desktop` + `dotfiles -timer install`; verify, then `dotfiles -config machine.tick on`.
2. **Track machine config.** `dotfiles machine add ~/.gitconfig ~/.bashrc` → `commit` → `push`.
3. **Create a sync repo.** `nvim` on branch `sync`; `dotfiles -config nvim.add all`; enable it.
4. **Add a per-repo hook.** A stylua `pre-commit` for `nvim` only (see Hooks).
5. **Set up a second machine (laptop).** First-run setup, `dotfiles machine checkout laptop`,
   clone the `nvim` repo, install the timer, enable.
6. **Edit — sync happens by itself.** Edit `~/.config/nvim/init.lua` on desktop; within ~60s
   the timer commits + pushes `nvim`; the laptop's next tick fetches + fast-forwards and the
   file appears. Nothing typed.
7. **Inspect.** `dotfiles -ls`, `dotfiles nvim log --oneline -3`, `dotfiles -doctor`.
8. **Hit a clash.** Same line edited on both before sync → never blocks, newest wins;
   `dotfiles -show` lists it, `dotfiles -resolve .config/nvim/init.lua` recovers the loser.
9. **Move ownership / park a repo / upgrade.** `dotfiles machine rm --cached … && dotfiles
   nvim add …` to move a path; `dotfiles -config archive.tick off` to park one;
   `dotfiles -update` to upgrade the engine.
