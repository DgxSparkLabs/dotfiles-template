# dotfiles-template

Manage dotfiles across machines using a bare git repository. No symlinks, no extra tools — just git.

The trick: a bare repo stored at `~/.dotfiles` with `$HOME` as its work-tree, accessed via a short alias.

> `**<placeholder>**` — anything in angle brackets is something you must replace with your own value before running the command.

> ⚠️ **Never track secret files.** With auto-commit enabled, any tracked file is pushed within 60 seconds of being modified. The included `.gitignore` blocks the most common ones (`.ssh/id_`*, `.netrc`, `.aws/credentials`, `.env`*, `*.pem`, `*.key`) defensively. Audit before running `dotfiles add` on anything new.

---

## The `dotfiles` command

Add one of these to your shell profile and use `dotfiles` everywhere you'd use `git`:

**Bash / Zsh** (`~/.bashrc` or `~/.zshrc`):

```bash
alias dotfiles='git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
```

**PowerShell** (`$PROFILE`):

```powershell
function dotfiles { git --git-dir="$HOME/.dotfiles/" --work-tree="$HOME" @args }
```

---

## Using this template (no fork required)

You don't need to fork on GitHub. Clone directly, set up your own repo, then bring it down to your machine as a bare repo.

### 1. Create your own GitHub repo from this template

```bash
# Clone this template
git clone https://github.com/DgxSparkLabs/dotfiles-template.git dotfiles
cd dotfiles

# Point it at your own repo
git remote remove origin
git remote add origin https://github.com/<YOU>/dotfiles.git
git push -u origin master
```

Or if you prefer a fresh history (no template commits):

```bash
git clone https://github.com/DgxSparkLabs/dotfiles-template.git dotfiles
cd dotfiles
rm -rf .git
git init
git add .
git commit -m "Initial dotfiles setup"
git branch -M master    # pin to master regardless of your git default
git remote add origin https://github.com/<YOU>/dotfiles.git
git push -u origin master
```

> **Why not fork?** Forks stay linked to the upstream repo on GitHub, which can clutter your profile and creates an implicit relationship you probably don't want for personal dotfiles.

### 2. Set up the bare repo on this machine

```bash
git clone --bare git@github.com:<YOU>/dotfiles.git $HOME/.dotfiles
dotfiles config --local status.showUntrackedFiles no

# Populate $HOME with master's tracked files
dotfiles checkout master -- .gitignore .dotfiles/
dotfiles add -u . && dotfiles commit -m "Init dotfiles"
```

Verify the work-tree is fully in sync:

```bash
dotfiles status
```

### 3. Create this machine's branch

This template uses **one branch per machine**. `master` is the **system baseline** — the template's portable defaults (the `.gitignore`, the git-hook stubs, the auto-commit timer, the wrapper definitions). It is **not** a shared bucket for your personal content; nothing you add on a machine branch is meant to travel back into `master`.

The flow is **one-way**: `master` → your machine branch, pulled with `dotfiles update`. Your machine branch is where *your* dotfiles live, and they stay there. See [The partition contract](#the-partition-contract-system-vs-user) below for what belongs where.

Pick a short, descriptive name for each machine:


| `<machine-name>`                 | Use for                                        |
| -------------------------------- | ---------------------------------------------- |
| `desktop-home`, `desktop-work`   | Stationary desktops, distinguished by location |
| `laptop-personal`, `laptop-work` | Laptops, distinguished by ownership            |
| `vm-dev`, `wsl-ubuntu`           | Virtual machines and WSL distros               |
| `server-home`, `vps-prod`        | Remote servers                                 |


> Confirm `dotfiles status` is clean from step 2 before proceeding — otherwise any staged deletions follow into the new branch and your first commit there will silently delete those files from master.

```bash
dotfiles checkout -b <machine-name> master
dotfiles push -u origin <machine-name>

# Suggestion for windows
dotfiles checkout -b $((Get-WmiObject -class Win32_BaseBoard).product) master
dotfiles push -u origin $((Get-WmiObject -class Win32_BaseBoard).product)

# Suggestion for linux
dotfiles checkout -b $(cat /sys/class/dmi/id/board_name) master
dotfiles push -u origin $(cat /sys/class/dmi/id/board_name)

# Suggestion for WSL
dotfiles checkout -b WSL master
dotfiles push -u origin WSL
```

### 4. Add your dotfiles

```bash
dotfiles add ~/.bashrc
dotfiles commit -m "Add bashrc"
dotfiles push
```

For the ongoing per-machine workflow, see [Multiple machines](#multiple-machines).

---

## Daily use

You're always on your machine's branch (`<machine-name>`). Routine changes commit and push there:

```bash
dotfiles status
dotfiles add ~/.config/someapp/config
dotfiles commit -m "Add someapp config"
dotfiles push                 # pushes to <machine-name> on origin
```

For changes you want every machine to inherit, see [Multiple machines](#multiple-machines) — those go on `master`.

### Auto-commit (optional)

Automatically stage and push changes on a schedule. By default the generated script runs **`git add -u`** (tracked paths only). **`dotfiles-timer install --all`** (Linux: `--all`/`-A`; Windows: `-AddAll`) embeds **`git add -A`** instead, which also picks up **new untracked** paths under `$HOME`.
For the default `-u` behavior, new dotfiles must still be staged once with `dotfiles add`.

Add a `dotfiles-timer` wrapper to your shell profile (same pattern as the `dotfiles` function above) so the install/uninstall/status commands are identical across all your machines:

**Bash / Zsh** (`~/.bashrc` or `~/.zshrc`):

```bash
alias dotfiles-timer='bash $HOME/.dotfiles/dotfiles-timer.sh'
```

**PowerShell** (`$PROFILE`):

```powershell
function dotfiles-timer { pwsh "$HOME\.dotfiles\dotfiles-timer.ps1" @args }
```

Then on any platform:

```text
dotfiles-timer install      # write files, enable autostart, start now
dotfiles-timer reinstall    # uninstall + install
dotfiles-timer enable       # turn on autostart (don't necessarily run now)
dotfiles-timer disable      # turn off autostart and stop (keep files)
dotfiles-timer start        # run now (idempotent — also enables if disabled)
dotfiles-timer stop         # stop running now (transient — auto-resumes on reboot if enabled)
dotfiles-timer status       # show install + autostart + running state
dotfiles-timer logs         # show recent activity
dotfiles-timer uninstall    # full removal (alias: remove)
```

Behavior per platform:

- **Linux** — installs a systemd user timer that runs every minute.
- **Windows admin shell** — registers a Task Scheduler task. Survives logoff, runs as your user with limited rights.
- **Windows non-admin shell** — drops a hidden VBS launcher in your Startup folder that fires a detached `pwsh` while-loop at each logon. No admin required, no console window flash (the VBS host is windowless). Errors log to `%TEMP%\dotfiles-auto-commit.log`.

The commit script (and the loop script, in Windows user mode) lives inside `~/.dotfiles/`, keeping both out of your work-tree and off `dotfiles status`.

### Git hooks (optional)

Client-side hooks run as **POSIX `#!/bin/sh` stubs** under `~/.dotfiles/.githooks/` (tracked in this repo as **`.dotfiles/.githooks/`**). Each stub executes the same **Python dispatcher** via **`uv run`** — no `pre-commit` framework dependency.

**Prerequisites**

- **[uv](https://docs.astral.sh/uv/)** on `PATH` wherever Git runs hooks (terminal **and** GUI clients often inherit a minimal PATH — if hooks fail to find `uv`, fix PATH or edit the POSIX stubs under `.dotfiles/.githooks/` to invoke a full path to `uv`).
- **Linux / macOS**: normal system `sh`.
- **Windows**: **Git for Windows** (hooks are executed with **`sh.exe`** from Git’s MSYS environment).

The hook launcher scripts under **`.dotfiles/.githooks/`** are **tracked in this repo** (no separate generator step). After your work-tree contains `.dotfiles/`, sync the Python package once:

```bash
uv sync --project ~/.dotfiles/githooks-runner
```

**Point the bare repo at the hooks directory** (required — hooks live outside `$GIT_DIR/hooks`):

```bash
git --git-dir "$HOME/.dotfiles" config core.hooksPath "$HOME/.dotfiles/.githooks"
```

You can also use a path **relative to `$GIT_DIR`** if you prefer; verify with:

```bash
git --git-dir "$HOME/.dotfiles" config --show-origin core.hooksPath
```

**Optional logging**

Set `DOTFILES_GITHOOKS_VERBOSE=1` to print a line to stderr for every hook invocation (default is silent).

### Per-machine git identity (optional)

Keep machine-specific identity — your email, signing key — out of the common config so it can vary per machine while applying to **all** git work. The common/base `~/.gitconfig` ends with a plain `[include]` of an untracked, per-machine `~/.gitconfig.local`; each machine sets its own email there (work email on the work laptop, personal at home).

The repo ships `.dotfiles/gitconfig.example` as the common base. Copy it to `~/.gitconfig`, then create the per-machine `~/.gitconfig.local`:

**Bash / Zsh:**

```bash
cp ~/.dotfiles-worktree-or-clone/.dotfiles/gitconfig.example ~/.gitconfig
# (or, once .dotfiles/ is checked out into $HOME:)
cp ~/.dotfiles/gitconfig.example ~/.gitconfig

printf '[user]\n\temail = <you@example.com>\n' > ~/.gitconfig.local
```

**PowerShell:**

```powershell
Copy-Item "$HOME\.dotfiles\gitconfig.example" "$HOME\.gitconfig"
"[user]`n`temail = <you@example.com>" | Set-Content "$HOME\.gitconfig.local"
```

Then verify it resolves in any repo:

```bash
git config --get user.email      # -> <you@example.com>
```

> The `~/.gitconfig.local` file is **per-machine and untracked** — create it on every machine. If it's missing, git silently skips the include and `user.email` is simply unset, so commits will fail to identify you until you create it.

### Health-check: `dotfiles doctor` (optional)

`dotfiles doctor` runs a battery of setup checks and prints **PASS / FAIL / INFO** with an actionable fix hint for each. It exits non-zero if any hard check fails, so it doubles as a CI/bootstrap gate. It is **pure shell / pwsh** — deliberately *not* run through the `uv` hook runner, so a broken `uv` install is still diagnosable.

Checks performed:

- **uv** is on `PATH`
- `core.hooksPath` == `~/.dotfiles/.githooks`
- `status.showUntrackedFiles` == `no`
- the `githooks-runner` venv is synced
- the work-tree is clean (no uncommitted tracked changes)
- `user_hooks.example` / `user_hooks.py` activation state (INFO only)
- auto-commit timer state (INFO only)
- remote push/fetch reachability — network + SSH auth (skippable)

Add a `dotfiles-doctor` wrapper to your shell profile (same pattern as the other wrappers):

**Bash / Zsh** (`~/.bashrc` or `~/.zshrc`):

```bash
alias dotfiles-doctor='bash $HOME/.dotfiles/dotfiles-doctor.sh'
```

**PowerShell** (`$PROFILE`):

```powershell
function dotfiles-doctor { pwsh "$HOME\.dotfiles\dotfiles-doctor.ps1" @args }
```

Then on any platform:

```text
dotfiles-doctor                  # run all checks
dotfiles-doctor --skip-network   # Bash/Zsh: omit the network/SSH reachability check
dotfiles-doctor -SkipNetwork     # PowerShell: omit the network/SSH reachability check
```

The git dir and work-tree default to `$HOME/.dotfiles` and `$HOME`. Override them with arguments if your setup differs:

```text
dotfiles-doctor --git-dir /path/to/repo --work-tree /path/to/home   # Bash/Zsh
dotfiles-doctor -GitDir C:\path\to\repo -WorkTree C:\path\to\home    # PowerShell
```

Use `--skip-network` / `-SkipNetwork` when offline or when the SSH agent is locked — otherwise the reachability check would false-FAIL.

### Submodules (optional)

> ⚠️ **Known limitation:** submodule operations (`add`, `init`, `update`) don't always compose cleanly with the bare-repo `--git-dir`/`--work-tree` pattern — a long-standing git issue. The instructions below work for many users but may fail on some git versions. If you hit errors, alternatives include committing the files directly or using a tool like `chezmoi` that has first-class submodule support.
>
> Reference (may become stale): [git mailing list discussion, 2012](https://www.spinics.net/lists/git/msg185334.html)

For shell plugins or large tool dotfiless, use submodules instead of copying files:

```bash
dotfiles submodule add https://github.com/zsh-users/zsh-autosuggestions ~/.zsh/zsh-autosuggestions
```

On a new machine after cloning:

```bash
dotfiles submodule init
dotfiles submodule update
```

---

## Managing `.gitignore`

The included `.gitignore` contains:

```
/*
!/.*
```

This ignores everything in `$HOME` except hidden files/dirs (those starting with `.`). This prevents `dotfiles status` from flooding with every file in your home directory.

**To also track a non-hidden directory** (e.g. `~/bin`), add a negation line to `.gitignore`:

```
/*
!/.*
!/bin
```

Then commit the updated `.gitignore`:

```bash
dotfiles add ~/.gitignore
dotfiles commit -m "Unignore ~/bin"
```

> Note: a `.gitignore` placed inside an ignored subdirectory will not be read by git — the negation must always be added to the root `.gitignore`.

---

## Multiple machines

Use **one branch per machine**. `master` is the **system baseline** — template-level defaults, not a shared content branch. Each machine branch is created off `master` once (step 3) and from then on tracks `master` **one-way**: you pull baseline improvements down with `dotfiles update`; you never push your machine's content up into `master`.

```bash
# Pull system-baseline improvements from master onto this machine
dotfiles update
```

`dotfiles update` fast-forwards the system baseline from `master` onto your current machine branch without touching your machine-local content. Confirm the work-tree is clean first (`dotfiles status`, or [`dotfiles doctor`](#health-check-dotfiles-doctor-optional)) — the same precaution called out in [step 3](#3-create-this-machines-branch).

### The partition contract (system vs user)

The whole model rests on a clean split between **system** content (lives on `master`, flows down to every machine) and **user** content (lives only on your machine branch, never travels):

| Concern | Lives in | Owned by | Travels via |
| --- | --- | --- | --- |
| System baseline — `.gitignore`, hook stubs, timer, wrappers | `master` | the template | `dotfiles update` (master → machine, one-way) |
| Your custom git-hook logic | `user_hooks.py` | you | stays on your machine branch |
| Your git identity (name, email, signing key) | `~/.gitconfig.local`, pulled in via `[include]` | you | stays on your machine branch |
| Your dotfiles, app configs, machine tweaks | your machine branch | you | stays on your machine branch |

This is why `master` only ever flows **down**. Custom hook behavior goes in **`user_hooks.py`** (a user extension point the system dispatcher calls — see [Git hooks](#git-hooks-optional)) rather than editing the tracked stubs, so a `dotfiles update` never clobbers it. Identity stays in **`~/.gitconfig.local`**, pulled in by a plain `[include]` directive in the tracked `.gitconfig`, so each machine's identity is local and untracked.

> **Sharing content between machines is deliberately out of scope here.** `master` is *not* the channel for that. Machine-to-machine sharing of *user* content is the planned **`sync`** feature — a separate, opt-in flow — not something you achieve by committing personal files to `master`.

### System updates (`dotfiles-update`)

`dotfiles update` (covered above under [Multiple machines](#multiple-machines)) is the one-way master→machine propagation path: it fetches `origin/master` and merges the latest **system baseline** onto your machine branch in one step. Because you never edit system files, the merge is normally clean. If it *does* conflict (a system file overlaps one you edited), the command prints a loud message, lists the conflicting files, **aborts the merge** (leaving your work-tree clean), and exits non-zero.

It runs manually by default; pass `--auto` (Linux) / `-Auto` (Windows) for unattended use from a scheduled wrapper (same merge semantics).

Add a `dotfiles-update` wrapper to your shell profile (same pattern as `dotfiles-timer`):

**Bash / Zsh** (`~/.bashrc` or `~/.zshrc`):

```bash
alias dotfiles-update='bash $HOME/.dotfiles/dotfiles-update.sh'
```

**PowerShell** (`$PROFILE`):

```powershell
function dotfiles-update { pwsh "$HOME\.dotfiles\dotfiles-update.ps1" @args }
```

Then on any platform:

```text
dotfiles-update            # fetch origin/master + merge into this machine's branch
dotfiles-update --auto     # same, opt-in unattended (Windows: -Auto)
```

### Adding another machine

Repeat [Using this template](#using-this-template-no-fork-required) **steps 2–4** on the new machine, picking a new `<machine-name>` in step 3. Step 1 (creating the GitHub repo) only happens once, on your first machine.

If a branch for this machine already exists on the remote (e.g. you set it up before and are reinstalling), substitute step 3 with:

```bash
dotfiles checkout <machine-name>     # checkout the existing branch instead of creating one
```

For full disaster-recovery automation, see [Restoring a machine from scratch](#restoring-a-machine-from-scratch).

---

## Restoring a machine from scratch

The `dotfiles` alias lives in your profile — which hasn't been restored yet. The tracked bootstrap scripts define it temporarily, clone your bare repo, then check out your machine's branch (which restores the profile). They live in your repo at [`.dotfiles/bootstrap.sh`](.dotfiles/bootstrap.sh) and [`.dotfiles/bootstrap.ps1`](.dotfiles/bootstrap.ps1).

Both take the repo URL and (optionally) the branch as **command-line parameters**:

| Parameter | Required | Default |
| --- | --- | --- |
| repo (`--repo` / `-Repo`) | yes (fails fast if missing) | — |
| branch (`--branch` / `-Branch`) | no | auto-detected machine name, **confirmed interactively** — Linux `/sys/class/dmi/id/board_name`, WSL → `WSL`, Windows `(Get-WmiObject Win32_BaseBoard).product`, else hostname |
| auto-accept (`-y` / `--yes` / `-Yes`) | no | off — when set, auto-accepts the auto-detected branch without prompting |

If you don't pass a branch, the script auto-detects this machine's name and asks you to confirm it (press Enter) or type a different branch before applying. In a non-interactive context (no TTY, e.g. CI) it errors and tells you to pass the branch explicitly, rather than hanging on the prompt. Input comes only from command-line arguments — there are no environment-variable fallbacks.

Branch resolution follows this precedence: an explicit `--branch`/`-Branch` always wins; otherwise with `-y`/`--yes` (`-Yes` on PowerShell) the script auto-accepts the auto-detected machine name **without prompting** (and without the non-interactive error); otherwise on an interactive terminal it prompts; otherwise (no branch, no `-y`, no TTY) it errors and exits. Use `-y` for unattended/scripted setup on a machine whose detected name is already the branch you want — it skips the confirmation while staying argument-only.

On a fresh machine you only have the script (copy it over, or fetch it from your repo's web UI). Run:

**Bash / WSL / Linux:**

```bash
bash bootstrap.sh --repo git@github.com:<YOU>/dotfiles.git
# you'll be asked to confirm the detected branch, or:
bash bootstrap.sh --repo git@github.com:<YOU>/dotfiles.git --branch my-laptop
# auto-accept the detected branch (no prompt):
bash bootstrap.sh --repo git@github.com:<YOU>/dotfiles.git -y
# positional form also works:
bash bootstrap.sh git@github.com:<YOU>/dotfiles.git my-laptop
```

**PowerShell (Windows):**

```powershell
pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git
# you'll be asked to confirm the detected branch, or:
pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git -Branch my-laptop
# auto-accept the detected branch (no prompt):
pwsh bootstrap.ps1 -Repo git@github.com:<YOU>/dotfiles.git -y
```

Conflicting OS-default files are backed up to `*.bak` before checkout, so nothing is lost. After checkout the scripts set `status.showUntrackedFiles no`. Open a new shell (or reload your profile) so the `dotfiles` wrapper is available.

---

## Uninstalling — completely remove this dotfiles system

If you decide to stop using this approach, here's how to clean up everything on a single machine.

### 1. Stop and uninstall the auto-commit timer (if installed)

```bash
dotfiles-timer uninstall    # both Linux and Windows; alias: remove
```

### 2. List what's currently tracked (so you know what'll change)

```bash
dotfiles ls-tree -r HEAD --name-only
```

Save the list somewhere if you want to keep a record of what files were managed.

### 3. Remove the bare repo

**Linux / macOS:**

```bash
rm -rf ~/.dotfiles
```

**Windows (PowerShell):**

```powershell
Remove-Item -Recurse -Force "$HOME\.dotfiles"
```

After this, the `dotfiles` and `dotfiles-timer` wrappers in your shell profile still exist but no longer point at anything functional.

### 4. (Optional) Decide what to do with the tracked files in `$HOME`

The actual content (`.bashrc`, `.gitdotfiles`, etc.) is **plain files in `$HOME`**, not symlinks — removing the bare repo doesn't delete them. Choose:

- **Keep them** — most users want this. The files just stop being version-controlled and otherwise behave normally.
- **Restore OS defaults** — manually delete or replace each file from the list in step 2.

### 5. Remove the wrapper definitions from your shell profile

Edit your shell profile and delete these lines:

**Bash / Zsh** (`~/.bashrc` or `~/.zshrc`):

```bash
alias dotfiles=
alias dotfiles-timer=
```

**PowerShell** (`$PROFILE`):

```powershell
function dotfiles {
function dotfiles-timer {
```

### 6. (Optional) Clean up the auto-commit log

**Windows** only — the user-mode loop writes to `%TEMP%`:

```powershell
Remove-Item "$env:TEMP\dotfiles-auto-commit.log*" -Force -ErrorAction SilentlyContinue
```

Linux uses `journalctl`, which has its own retention; nothing to clean.

### 7. Reload your shell

**Bash / Zsh:**

```bash
exec $SHELL
```

**PowerShell:** open a new terminal, or:

```powershell
. $PROFILE
```

### 8. (Optional) Delete the GitHub repo

This is irreversible — only do it if you want to fully erase the cloud copy across all your machines:

```bash
gh repo delete <YOU>/dotfiles --yes
```

Or via the GitHub UI: **Settings → Danger Zone → Delete this repository**.