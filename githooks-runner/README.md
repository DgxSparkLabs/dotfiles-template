# dotfiles-githooks

Python dispatcher for the engine's shared Git hooks under `~/.dotfiles/common/githooks/`.
Each hook is a thin POSIX `#!/bin/sh` stub that runs:

`uv run --project …/githooks-runner -m dotfiles_githooks <hook-name> "$@"`

The dispatcher identifies the firing bare repo (`git rev-parse --absolute-git-dir` → basename)
and runs that repo's per-repo hooks plus any shared hooks — see the main template
[README.md](../README.md) section "Hooks (per-repo + shared)" for setup (`core.hooksPath`,
`uv sync`).
