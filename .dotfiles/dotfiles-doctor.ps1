#!/usr/bin/env pwsh
# dotfiles-doctor.ps1: Setup health-check for the bare-repo dotfiles system.
#
# Pure pwsh — deliberately NOT run through the uv runner, so that a broken uv
# install is still diagnosable. Each check prints PASS / FAIL / INFO with an
# actionable fix hint. Exits non-zero if any *hard* check FAILs.
#
# Network/SSH reachability is gated behind -SkipNetwork (offline machines or a
# locked SSH agent would otherwise false-FAIL).

param(
    [switch]$SkipNetwork,
    [switch]$Help
)

$GitDir    = if ($env:DOTFILES_GIT_DIR)   { $env:DOTFILES_GIT_DIR }   else { "$HOME\.dotfiles" }
$WorkTree  = if ($env:DOTFILES_WORK_TREE) { $env:DOTFILES_WORK_TREE } else { "$HOME" }
$HooksPath = "$GitDir\.githooks"
$RunnerDir = "$GitDir\githooks-runner"
$TimerPs1  = "$GitDir\dotfiles-timer.ps1"

if ($Help) {
    Write-Host @"
Usage: pwsh dotfiles-doctor.ps1 [-SkipNetwork]

Runs setup health-checks for the dotfiles bare repo at:
  $GitDir  (work-tree: $WorkTree)

  -SkipNetwork   Omit network/SSH push-reachability checks (offline / locked agent).

Prints PASS/FAIL/INFO per check with a fix hint; exits non-zero on any hard FAIL.
"@
    exit 0
}

function Invoke-Dotfiles {
    & git --git-dir="$GitDir" --work-tree="$WorkTree" @args
}

$script:HardFails = 0

function Write-Pass([string]$msg) { Write-Host "  PASS  $msg" }
function Write-Info([string]$msg) { Write-Host "  INFO  $msg" }
function Write-Fail([string]$msg, [string]$fix) {
    Write-Host "  FAIL  $msg"
    if ($fix) { Write-Host "        fix: $fix" }
    $script:HardFails++
}

Write-Host "dotfiles doctor — checking setup at $GitDir"
Write-Host ""

# 1. uv on PATH ─────────────────────────────────────────────────────────────
$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
    Write-Pass "uv on PATH ($($uv.Source))"
} else {
    Write-Fail "uv not found on PATH" `
        "install uv (https://docs.astral.sh/uv/) and ensure it is on PATH where Git runs hooks"
}

# 2. core.hooksPath ─────────────────────────────────────────────────────────
$hooksCfg = (Invoke-Dotfiles config --get core.hooksPath 2>$null)
# git on Windows returns forward-slash or back-slash depending on how it was set; normalize for compare.
$normCfg = if ($hooksCfg) { $hooksCfg.Replace('/', '\') } else { $hooksCfg }
$normExp = $HooksPath.Replace('/', '\')
if ($normCfg -eq $normExp) {
    Write-Pass "core.hooksPath = $hooksCfg"
} else {
    $shown = if ($hooksCfg) { $hooksCfg } else { '<unset>' }
    Write-Fail "core.hooksPath is '$shown' (expected $HooksPath)" `
        "git --git-dir `"$GitDir`" config core.hooksPath `"$HooksPath`""
}

# 3. status.showUntrackedFiles ──────────────────────────────────────────────
$sutCfg = (Invoke-Dotfiles config --get status.showUntrackedFiles 2>$null)
if ($sutCfg -eq 'no') {
    Write-Pass "status.showUntrackedFiles = no"
} else {
    $shown = if ($sutCfg) { $sutCfg } else { '<unset>' }
    Write-Fail "status.showUntrackedFiles is '$shown' (expected no)" `
        "git --git-dir `"$GitDir`" config status.showUntrackedFiles no"
}

# 4. venv synced ────────────────────────────────────────────────────────────
if (-not (Test-Path $RunnerDir)) {
    Write-Fail "githooks-runner project not found at $RunnerDir" `
        "ensure .dotfiles/ is checked out into your work-tree"
} elseif (-not $uv) {
    Write-Fail "cannot verify venv sync (uv missing)" `
        "install uv, then: uv sync --project `"$RunnerDir`""
} else {
    & uv sync --project "$RunnerDir" --frozen --check *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "githooks-runner venv synced"
    } else {
        Write-Fail "githooks-runner venv not synced" `
            "uv sync --project `"$RunnerDir`""
    }
}

# 5. work-tree clean ────────────────────────────────────────────────────────
Invoke-Dotfiles rev-parse --git-dir *> $null
if ($LASTEXITCODE -eq 0) {
    $porcelain = (Invoke-Dotfiles status --porcelain 2>$null | Out-String).Trim()
    if (-not $porcelain) {
        Write-Pass "work-tree clean (no tracked changes)"
    } else {
        Write-Fail "work-tree has uncommitted tracked changes" `
            "review with: git --git-dir `"$GitDir`" --work-tree `"$WorkTree`" status"
    }
} else {
    Write-Fail "no git repo at $GitDir" `
        "git clone --bare <your-dotfiles-remote> `"$GitDir`""
}

# 6. user_hooks (info only) ─────────────────────────────────────────────────
$userHooksExample = "$RunnerDir\dotfiles_githooks\user_hooks.example"
$userHooksActive  = "$RunnerDir\dotfiles_githooks\user_hooks.py"
if (Test-Path $userHooksExample) {
    Write-Info "user_hooks.example present ($userHooksExample)"
} else {
    Write-Info "user_hooks.example not present (optional customization template)"
}
if (Test-Path $userHooksActive) {
    Write-Info "user_hooks.py activated — custom hook logic is in effect"
} else {
    Write-Info "user_hooks.py not activated (copy user_hooks.example to user_hooks.py to enable)"
}

# 7. timer state (reuse dotfiles-timer status probes) ───────────────────────
if (Test-Path $TimerPs1) {
    $task = Get-ScheduledTask -TaskName 'dotfiles-git-commit' -ErrorAction SilentlyContinue
    if ($task) {
        Write-Info "auto-commit task registered (state: $($task.State))"
    } else {
        # User-mode install state is encoded by presence of the loop script.
        $loopPath = "$GitDir\.auto-commit-loop.ps1"
        if (Test-Path $loopPath) {
            Write-Info "auto-commit loop installed (user mode)"
        } else {
            Write-Info "auto-commit timer not installed (optional: dotfiles-timer install)"
        }
    }
} else {
    Write-Info "dotfiles-timer.ps1 not found at $TimerPs1 (auto-commit is optional)"
}

# 8. network / SSH push reachability ────────────────────────────────────────
if ($SkipNetwork) {
    Write-Info "network/SSH push check skipped (-SkipNetwork)"
} else {
    Invoke-Dotfiles rev-parse --git-dir *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "cannot check push reachability — no repo at $GitDir" `
            "set up the bare repo first"
    } else {
        $branch = (Invoke-Dotfiles symbolic-ref --short HEAD 2>$null | Out-String).Trim()
        $remote = $null
        if ($branch) {
            $remote = (Invoke-Dotfiles config --get "branch.$branch.remote" 2>$null | Out-String).Trim()
        }
        if (-not $remote) { $remote = 'origin' }

        Invoke-Dotfiles remote get-url $remote *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "no remote '$remote' configured" `
                "git --git-dir `"$GitDir`" remote add origin <your-dotfiles-remote>"
        } else {
            Invoke-Dotfiles ls-remote --heads $remote *> $null
            if ($LASTEXITCODE -eq 0) {
                Write-Pass "remote '$remote' reachable (push/fetch network + auth OK)"
            } else {
                Write-Fail "remote '$remote' unreachable (network down or SSH agent locked)" `
                    "check connectivity / unlock SSH agent, or re-run with -SkipNetwork"
            }
        }
    }
}

Write-Host ""
if ($script:HardFails -gt 0) {
    Write-Host "doctor: $($script:HardFails) hard check(s) FAILED — see fix hints above."
    exit 1
}
Write-Host "doctor: all hard checks PASSED."
exit 0
