#!/usr/bin/env pwsh
# dotfiles-timer.ps1: Manage the SINGLE auto-tick timer for the dotfiles sync engine.
#
# Node 9 — the one installed timer no longer bakes a single-repo add/commit/push payload. Its
# payload now calls the dispatcher's fan-out: `dotfiles -tick` loops EVERY repo under
# ~/.dotfiles/bare-repos/ (discovery is the registry — a new repo on disk is ticked next cycle).
# Exactly one task (admin) / one VBS launcher + loop (non-admin) is ever installed.
#
# Auto-detects privilege at install time (singleton names kept):
#   Admin     -> Windows Task Scheduler task 'dotfiles-git-commit' (survives logoff)
#   Non-admin -> Startup-folder VBS launcher (windowless) + detached pwsh while-loop
#
# Cadence + de-sync from ~/.dotfiles/config:
#   [timer] interval (seconds, default 60)   -> task RepetitionInterval / loop sleep
#   [timer] jitter   (+- seconds, default 15)-> per-fire randomized 0..jitter sleep baked into
#                     the payload (so N machines don't push in lockstep). The jitter value is
#                     embedded in the generated artifact so it is testable without a live manager.

param(
    [Parameter(Position=0, Mandatory=$false)]
    [ValidateSet('install','reinstall','enable','disable','start','stop','uninstall','remove','status','logs')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

# Engine layout: this script is <root>\common\timer\dotfiles-timer.ps1.
$TimerDir       = Split-Path -Parent $PSCommandPath
$DotfilesCommon = if ($env:DOTFILES_COMMON) { $env:DOTFILES_COMMON } else { Split-Path -Parent $TimerDir }
$DotfilesRoot   = if ($env:DOTFILES_ROOT)   { $env:DOTFILES_ROOT }   else { Split-Path -Parent $DotfilesCommon }
$Dispatcher     = Join-Path $DotfilesCommon 'dotfiles.ps1'

$TaskName     = "dotfiles-git-commit"        # singleton name kept from the legacy timer
$ScriptPath   = Join-Path $DotfilesRoot '.dotfiles-tick.ps1'        # generated payload
$LoopPath     = Join-Path $DotfilesRoot '.dotfiles-tick-loop.ps1'   # non-admin loop
$LauncherPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\DotfilesAutoCommit.vbs"
$LogPath      = "$env:TEMP\dotfiles-tick.log"
# In user mode the install state is encoded by file presence:
#   $LoopPath exists, $LauncherPath exists  -> installed + enabled
#   $LoopPath exists, $LauncherPath missing -> installed + disabled
#   $LoopPath missing                       -> not installed

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Read [timer] interval/jitter via the dispatcher's own readers (single source of truth).
function Get-TimerSettings {
    $interval = 60
    $jitter   = 15
    if (Test-Path -LiteralPath $Dispatcher) {
        try {
            . $Dispatcher *> $null
            if (Get-Command __df_setting_timer_interval -ErrorAction SilentlyContinue) {
                $interval = [int](__df_setting_timer_interval)
            }
            if (Get-Command __df_setting_timer_jitter -ErrorAction SilentlyContinue) {
                $jitter = [int](__df_setting_timer_jitter)
            }
        } catch { }
    }
    return [pscustomobject]@{ Interval = $interval; Jitter = $jitter }
}

if (-not $Action) {
    $mode = if (Test-IsAdmin) { 'admin (Task Scheduler)' } else { 'user (startup folder + VBS)' }
    Write-Host @"
Usage: pwsh dotfiles-timer.ps1 [install|reinstall|enable|disable|start|stop|status|logs|uninstall|remove]

Detected privilege: $mode

  install     Write the tick payload + register autostart. The payload runs
              \`dotfiles -tick\` over EVERY repo under ~/.dotfiles/bare-repos/.
  reinstall   Uninstall + install (idempotent — always exactly one task/launcher).
  enable      Mark to autostart on next boot/logon (don't necessarily run now).
  disable     Turn off autostart and stop now (keep files).
  start       Run now (idempotent — also enables if disabled).
  stop        Stop running now (transient — auto-resumes on reboot if enabled).
  status      Show install + autostart + running state.
  logs        Show recent activity.
  uninstall   Full removal (alias: remove).

One timer; its tick fans out over all repos via the dispatcher's -tick.
Cadence from ~/.dotfiles/config: [timer] interval (default 60s), jitter (default +-15s).
"@
    exit 1
}

# Generate the payload script: a per-fire random 0..jitter sleep, then `dotfiles -tick` over ALL
# repos. The jitter + interval values are baked into the file so they are inspectable in tests.
function Write-TickScript {
    param([int]$Jitter)
    @"
# dotfiles single-timer payload (node 9). Fans out the sync tick over ALL repos under
# ~/.dotfiles/bare-repos/ via the dispatcher's ``dotfiles -tick`` (discovery is the registry).
# A per-fire random 0..JITTER sleep de-syncs N machines so they don't push in lockstep.
`$env:DOTFILES_COMMON = '$DotfilesCommon'
`$env:DOTFILES_ROOT   = '$DotfilesRoot'
`$jitter = $Jitter
if (`$jitter -gt 0) {
    `$delay = Get-Random -Minimum 0 -Maximum (`$jitter + 1)
    if (`$delay -gt 0) { Start-Sleep -Seconds `$delay }
}
. '$Dispatcher'
dotfiles -tick
"@ | Set-Content -Path $ScriptPath -Encoding UTF8
}

function Write-LoopScript {
    param([int]$Interval)
    @"
# .dotfiles-tick-loop.ps1 — invoked by the VBS launcher at logon (non-admin path).
`$logPath   = '$LogPath'
`$interval  = $Interval
`$maxBytes  = 524288     # 0.5 MB threshold for log rotation
`$keepCount = 5          # archives to keep before pruning oldest

function Invoke-LogRotation([string]`$path) {
    if (-not (Test-Path `$path)) { return }
    if ((Get-Item `$path).Length -le `$maxBytes) { return }
    `$archive = "`$path.`$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item `$path `$archive -Force
    `$dir  = Split-Path `$path -Parent
    `$name = Split-Path `$path -Leaf
    Get-ChildItem -Path `$dir -Filter "`$name.*" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip `$keepCount |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

while (`$true) {
    `$ts = Get-Date -Format 'o'
    try {
        # The tick payload applies per-fire jitter, then runs `dotfiles -tick` over all repos.
        `$output = & '$ScriptPath' 2>&1 | Out-String
        if (`$output.Trim()) {
            Invoke-LogRotation `$logPath
            Add-Content -Path `$logPath -Value "[`$ts] `$(`$output.TrimEnd())"
        }
    } catch {
        Invoke-LogRotation `$logPath
        Add-Content -Path `$logPath -Value "[`$ts] ERROR: `$(`$_.Exception.Message)"
    }
    Start-Sleep -Seconds `$interval
}
"@ | Set-Content -Path $LoopPath -Encoding UTF8
}

function Write-VbsLauncher {
    $pwshExe = (Get-Command pwsh).Source
    # VBS literal-quote rule: doubled "" inside a "..." string yields one " in the output.
    # `0` (WindowStyle Hidden) + WScript host => no console window flash (windowless).
    @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run """$pwshExe"" -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$LoopPath""", 0, False
"@ | Set-Content -Path $LauncherPath -Encoding ASCII
}

function Stop-LoopProcesses {
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$LoopPath*" } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
        }
}

function Install-Admin {
    $s = Get-TimerSettings
    # ON-DISK ARTIFACT FIRST: write the payload before best-effort manager registration so the
    # generated file always exists (content asserts + the next tick depend on it) even if Task
    # Scheduler registration is unavailable (non-interactive / non-admin runner).
    Write-TickScript -Jitter $s.Jitter

    $action        = New-ScheduledTaskAction -Execute 'pwsh' `
                         -Argument "-NonInteractive -WindowStyle Hidden -File `"$ScriptPath`""
    $triggerLogon  = New-ScheduledTaskTrigger -AtLogOn
    $triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) `
                         -RepetitionInterval ([TimeSpan]::FromSeconds($s.Interval)) `
                         -RepetitionDuration ([TimeSpan]::FromDays(365 * 10))
    $settings      = New-ScheduledTaskSettingsSet `
                         -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5)) `
                         -StartWhenAvailable

    # Best-effort: a non-interactive/unprivileged session may not be able to register a task. The
    # payload is already on disk, so warn and return success-for-the-file-install rather than abort.
    try {
        Register-ScheduledTask -TaskName $TaskName `
            -Action $action -Trigger @($triggerLogon, $triggerRepeat) -Settings $settings `
            -RunLevel Limited -Force -ErrorAction Stop | Out-Null
        Write-Host "[admin] Installed Task Scheduler task '$TaskName' (every $($s.Interval)s +-$($s.Jitter)s; payload: dotfiles -tick over all repos)."
    } catch {
        Write-Host "[admin] Note: could not register Task Scheduler task '$TaskName' ($($_.Exception.Message)). Payload written: $ScriptPath"
    }
}

function Install-User {
    $s = Get-TimerSettings
    # ON-DISK ARTIFACTS FIRST (payload + loop + VBS launcher), THEN best-effort process start.
    Write-TickScript -Jitter $s.Jitter
    Write-LoopScript -Interval $s.Interval
    Write-VbsLauncher

    # Best-effort: stop any old loops, then start one immediately so the user doesn't have to log
    # out/in. A headless runner may not be able to spawn wscript — that must not abort the install
    # (the files are already written), so swallow the failure with a warning.
    try {
        Stop-LoopProcesses
        Start-Process wscript.exe -ArgumentList "`"$LauncherPath`"" -WindowStyle Hidden -ErrorAction Stop
    } catch {
        Write-Host "[user] Note: could not start the loop now ($($_.Exception.Message)); it will start on next logon. Files written."
    }

    Write-Host "[user] Installed startup launcher: $LauncherPath"
    Write-Host "       Tick payload: $ScriptPath"
    Write-Host "       Loop script:  $LoopPath"
    Write-Host "       Log file:     $LogPath"
    Write-Host "       Cadence: every $($s.Interval)s +-$($s.Jitter)s; payload runs dotfiles -tick over all repos."
    Write-Host "       Loop started; will resume automatically on each logon."
}

function Uninstall-Admin {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $ScriptPath -Force -ErrorAction SilentlyContinue
    Write-Host "[admin] Removed task '$TaskName'."
}

function Uninstall-User {
    Stop-LoopProcesses
    Remove-Item $LauncherPath -Force -ErrorAction SilentlyContinue
    Remove-Item $LoopPath     -Force -ErrorAction SilentlyContinue
    Remove-Item $ScriptPath   -Force -ErrorAction SilentlyContinue
    Write-Host "[user] Removed startup launcher and stopped running loop."
}

function Enable-Timer {
    if (Test-IsAdmin) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) { Write-Host "Not installed."; return }
        Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Host "[admin] Task enabled (will autostart per its triggers)."
    } else {
        if (-not (Test-Path $LoopPath)) { Write-Host "Not installed."; return }
        if (-not (Test-Path $LauncherPath)) { Write-VbsLauncher }
        Write-Host "[user] VBS launcher re-created in startup folder (runs at next logon)."
    }
}

function Disable-Timer {
    if (Test-IsAdmin) {
        Stop-ScheduledTask    -TaskName $TaskName -ErrorAction SilentlyContinue
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        Write-Host "[admin] Task disabled and stopped (files preserved; 'start' or 'enable' to resume)."
    } else {
        Stop-LoopProcesses
        Remove-Item $LauncherPath -Force -ErrorAction SilentlyContinue
        Write-Host "[user] Loop stopped and VBS launcher removed from startup folder (loop+tick scripts kept)."
    }
}

function Start-Timer {
    if (Test-IsAdmin) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) { Write-Host "Not installed. Run 'install' first."; return }
        Enable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        Start-ScheduledTask  -TaskName $TaskName
        Write-Host "[admin] Task enabled and started."
    } else {
        if (-not (Test-Path $LoopPath)) { Write-Host "Not installed. Run 'install' first."; return }
        if (-not (Test-Path $LauncherPath)) { Write-VbsLauncher }
        $running = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$LoopPath*" }
        if ($running) { Write-Host "[user] Loop already running."; return }
        Start-Process wscript.exe -ArgumentList "`"$LauncherPath`"" -WindowStyle Hidden
        Write-Host "[user] Loop started."
    }
}

function Stop-Timer {
    if (Test-IsAdmin) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Host "[admin] Stopped current run (autostart still on; use 'disable' to fully halt)."
    } else {
        Stop-LoopProcesses
        Write-Host "[user] Loop stopped (will resume on next logon if VBS launcher still in startup folder)."
    }
}

function Get-Status {
    $found = $false

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $found = $true
        Write-Host "[admin mode] Task Scheduler task '$TaskName':"
        $task | Format-List TaskName, State
        Get-ScheduledTaskInfo -TaskName $TaskName |
            Format-List LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns
    }

    if (Test-Path $LoopPath) {
        $found = $true
        if (Test-Path $LauncherPath) {
            Write-Host "[user mode] Installed; autostart: ENABLED ($LauncherPath)"
        } else {
            Write-Host "[user mode] Installed; autostart: DISABLED (no VBS in startup folder)"
            Write-Host "Run 'enable' or 'start' to recreate the launcher."
        }
        $procs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$LoopPath*" }
        if ($procs) {
            Write-Host "Loop running (PIDs: $(($procs.ProcessId) -join ', '))"
        } else {
            Write-Host "Loop NOT running."
        }
    }

    if (-not $found) {
        Write-Host "Not installed."
    }
}

function Get-Logs {
    $emitted = $false

    if (Test-Path $LogPath) {
        Write-Host "User-mode log ( $LogPath ):"
        Get-Content $LogPath -Tail 50
        $emitted = $true
    }

    if (Test-IsAdmin) {
        Write-Host ""
        Write-Host "Task Scheduler events for '$TaskName':"
        Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match [regex]::Escape($TaskName) } |
            Select-Object -First 50 | Format-List TimeCreated, Id, Message
        $emitted = $true
    }

    if (-not $emitted) {
        Write-Host "No log file at $LogPath."
        Write-Host ""
        Write-Host "The log captures tick output (commits, pushes, merges) and errors — silent no-op"
        Write-Host "runs (nothing changed) leave no entry. To verify the loop is alive, use:"
        Write-Host "  dotfiles -timer status     # shows running PIDs"
        Write-Host "  dotfiles <repo> log --oneline   # shows commits the tick has made"
    }
}

$isAdmin = Test-IsAdmin

switch ($Action) {
    'install'   { if ($isAdmin) { Install-Admin } else { Install-User } }
    'reinstall' { if ($isAdmin) { Uninstall-Admin; Install-Admin } else { Uninstall-User; Install-User } }
    'enable'    { Enable-Timer }
    'disable'   { Disable-Timer }
    'start'     { Start-Timer }
    'stop'      { Stop-Timer }
    'uninstall' { if ($isAdmin) { Uninstall-Admin } else { Uninstall-User } }
    'remove'    { if ($isAdmin) { Uninstall-Admin } else { Uninstall-User } }
    'status'    { Get-Status }
    'logs'      { Get-Logs }
}
