# install-shot.ps1 - let an agent photograph the guest's own desktop, from a shell.
#
# ==> RUN BY lib/forge/init.ps1, IN THE GUEST. Can also be run by hand. <==
#
# THE PROBLEM IS THE SESSION. An agent reaches this machine over ssh, which lands in SESSION 0.
# Session 0 has its own window station and no desktop, so a capture taken there is not a dark
# screenshot - there is nothing to photograph. The desktop a human sees over VNC is session 1,
# and only a process running THERE can capture it. The answer is a scheduled task with an
# interactive principal, which session 0 may START but which RUNS in session 1:
#
#   agent (session 0)  ->  draugr-shot.cmd  ->  schtasks /run  ->  capture.ps1 (session 1)
#                                                                        |
#                       C:\Draugr\shot.png  <----------------------------+
#
# WHY A LAYER-0 COMPONENT AND NOT AN OPTIONAL ONE. The test docs/FORGE.md applies is *would a
# Windows VM built for something else want this?* - and an agent that cannot see the screen is
# the general case, not the Unreal one. Nothing here is engine-specific.
#
# WHY NOT JUST USE THE MCP SERVER, which has a Screenshot tool and already lives in session 1.
# Because that needs an MCP client, a bearer token and a working server - and the moment you
# most want to look at the desktop is usually the moment one of those is broken. This path needs
# a shell and nothing else, which makes it the one that still works on a bad day. The two are
# complements, not rivals.
#
# THE TASK HAS NO TRIGGER. It fires only when something runs it, so it costs nothing at logon
# and cannot photograph the desktop unless asked.
#
#   powershell -ExecutionPolicy Bypass -File .\install-shot.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-shot.ps1 -VerifyOnly
#
# Afterwards, from anywhere including ssh:
#
#   draugr-shot                    writes C:\Draugr\shot.png and prints the path
#   draugr-shot D:\other\path.png  somewhere else
#
# IT ENDS WITH DRAUGR_CHANGED=0 or =1, which is how init tells "installed it" from "it was
# already there" - and the reason this copy is not the gateway's verbatim. A summary that
# cannot tell those apart is the one defect an idempotent script must not have.
param(
    [string]$Dir = 'C:\ProgramData\draugr-shot',
    [string]$Out = 'C:\Draugr\shot.png',
    # Downscaled on the way out: the reader is a model with a pixel budget, not a person with a
    # monitor. 1920 keeps window text legible; 0 disables scaling entirely.
    [int]$MaxWidth = 1920,
    [string]$TaskName = 'draugr-shot',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Each guest script has to run standalone over ssh with nothing imported, so this is copied
# rather than shared. Inserted BEFORE system32 so the directory wins over anything Windows
# ships under the same name.
function Add-ToMachinePath([string]$Dir, [string]$Before = "$env:SystemRoot\system32") {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($cur -split ';' | Where-Object { $_ })
    $norm = $parts | ForEach-Object { $_.TrimEnd('\').ToLower() }
    if ($norm -contains $Dir.TrimEnd('\').ToLower()) { Write-Host "  PATH already has $Dir"; return $false }
    $at = [Array]::IndexOf($norm, $Before.TrimEnd('\').ToLower())
    if ($at -lt 0) { $at = 0 }
    $new = @()
    if ($at -gt 0) { $new += $parts[0..($at - 1)] }
    $new += $Dir
    $new += $parts[$at..($parts.Count - 1)]
    [Environment]::SetEnvironmentVariable('Path', ($new -join ';'), 'Machine')
    Write-Host "  PATH += $Dir (machine, just before $Before)"
    return $true
}

$capture = Join-Path $Dir 'capture.ps1'
$trigger = Join-Path $Dir 'draugr-shot.cmd'

# NO `schtasks /query ... 2>$null` HERE, and this is the whole of the bug this file had.
# $ErrorActionPreference is Stop above; PowerShell 5.1 wraps a REDIRECTED native stderr line
# as a NativeCommandError, and Stop makes it terminating. schtasks writes "ERROR: The system
# cannot find the file specified." to stderr for a task that does not exist - so this
# function, whose entire job is to notice that the task is ABSENT, threw whenever it was,
# which is every first install. The phase reported FAILED (1) with the capture script and
# the trigger already written and no task registered.
#
# MEASURED in the guest, task absent, Stop in force: the schtasks form threw
# (NativeCommandError); Get-ScheduledTask returned $null quietly. Unredirected native stderr
# would have passed through harmlessly - it is the redirection that does it. docs/FORGE.md.
#
# .State carries the same words schtasks printed under "Status:" - Ready, Running, Disabled -
# so every caller below reads what it read before.
function Get-TaskStatus([string]$Name) {
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($t) { return "$($t.State)" }
    return ''
}
function Test-OnPath([string]$D) {
    return [bool](([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') |
        Where-Object { $_.TrimEnd('\') -ieq $D.TrimEnd('\') })
}

if ($VerifyOnly) {
    Write-Host '--- verification ---'
    $bad = @()
    foreach ($f in @($capture, $trigger)) {
        if (Test-Path $f) { Write-Host "  present     $f" }
        else { Write-Host "  MISSING     $f"; $bad += $f }
    }
    $st = Get-TaskStatus $TaskName
    if ($st) { Write-Host "  task        $TaskName ($st)" } else { Write-Host '  task        MISSING'; $bad += 'task' }
    Write-Host ("  on PATH     {0}" -f $(if (Test-OnPath $Dir) { $Dir } else { 'NO' }))
    if (-not (Test-OnPath $Dir)) { $bad += 'PATH' }
    Write-Host 'DRAUGR_CHANGED=0'
    if ($bad.Count) { exit 1 }
    exit 0
}

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $Out -Parent) | Out-Null

# --- the half that runs in session 1 ---------------------------------------------------
# Written from here rather than shipped as its own file: one file to copy into the guest, and
# the thing it installs cannot drift away from the installer that reasons about it.
#
# @' '@ - LITERAL. The inner Add-Type here-string and every $ in the script below must survive
# into the file untouched; an interpolating @" "@ would eat them.
$captureBody = @'
# capture.ps1 - photograph THIS session's desktop. Started by the draugr-shot task, which is
# how a caller in session 0 gets code running in session 1. Do not call it directly from ssh:
# it would succeed and produce nothing useful, because session 0 has no desktop.
# Generated by Draugr's lib/forge/guest/install-shot.ps1 - do not edit.
param([string]$Out = 'C:\Draugr\shot.png', [int]$MaxWidth = 1920)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# DPI awareness BEFORE anything measures. Without it a scaled desktop reports LOGICAL pixels
# and the capture is a blurry crop of the top-left corner - which reads as a broken tool
# rather than as a DPI problem.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DrShot { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[void][DrShot]::SetProcessDPIAware()

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$full = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
$g = [System.Drawing.Graphics]::FromImage($full)
$g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, (New-Object System.Drawing.Size($vs.Width, $vs.Height)))
$g.Dispose()

# Scaled AFTER the capture, never before: CopyFromScreen has to take real pixels or text turns
# to mush on the way down.
$img = $full
if ($MaxWidth -gt 0 -and $full.Width -gt $MaxWidth) {
    $nh = [int][math]::Round($full.Height * ($MaxWidth / $full.Width))
    $small = New-Object System.Drawing.Bitmap($MaxWidth, $nh)
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($full, 0, 0, $MaxWidth, $nh)
    $g2.Dispose()
    $img = $small
}

# Written to a temp name and MOVED into place. The caller polls for the file's existence, so a
# half-written PNG appearing at the final path would be read as a finished one - a race that
# shows up as a corrupt image roughly never, until it matters.
$tmp = "$Out.tmp"
$img.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
if ($img -ne $full) { $img.Dispose() }
$full.Dispose()
Move-Item -LiteralPath $tmp -Destination $Out -Force
'@

# COMPARED BEFORE WRITING, so a re-run that changes nothing can say so. Set-Content would
# rewrite an identical file happily, and then every init would report the camera as installed
# again - which is how a summary starts lying.
$changed = $false
if ((-not (Test-Path $capture)) -or ((Get-Content $capture -Raw) -ne ($captureBody + "`r`n"))) {
    Set-Content -Path $capture -Value $captureBody -Encoding UTF8
    Write-Host "wrote $capture"
    $changed = $true
} else {
    Write-Host "already current: $capture"
}

# --- the half any agent calls ----------------------------------------------------------
# cmd, not PowerShell: it is the lowest common denominator for "run one thing over ssh", and
# an agent that knows nothing about this machine can still call it.
#
# `ping -n 2 127.0.0.1` is the sleep, NOT `timeout /t`. Measured trap: timeout.exe fails with
# "ERROR: Input redirection is not supported" the moment stdin is not a console, which over
# ssh is always.
$triggerBody = @"
@echo off
setlocal
rem draugr-shot - photograph the guest's desktop from any session, including ssh.
rem Generated by Draugr's lib/forge/guest/install-shot.ps1 - do not edit.
set "OUT=%~1"
if "%OUT%"=="" set "OUT=$Out"
if exist "%OUT%" del /q "%OUT%" >nul 2>&1
schtasks /run /tn "$TaskName" >nul 2>&1
if errorlevel 1 (
    echo draugr-shot: could not start the task "$TaskName". Is it registered?
    exit /b 2
)
set /a N=0
:wait
if exist "%OUT%" goto done
set /a N+=1
if %N% GEQ 20 (
    echo draugr-shot: timed out waiting for "%OUT%".
    echo   The task runs in the INTERACTIVE session - if nobody is logged on at the
    echo   console, there is no desktop to photograph and it cannot produce anything.
    exit /b 3
)
ping -n 2 127.0.0.1 >nul
goto wait
:done
echo %OUT%
"@
if ((-not (Test-Path $trigger)) -or ((Get-Content $trigger -Raw) -ne ($triggerBody + "`r`n"))) {
    Set-Content -Path $trigger -Value $triggerBody -Encoding ASCII
    Write-Host "wrote $trigger"
    $changed = $true
} else {
    Write-Host "already current: $trigger"
}

# --- the task: session 0 may start it, session 1 runs it --------------------------------
# LogonType Interactive is the whole mechanism. -WindowStyle Hidden keeps the capture from
# putting a PowerShell window into the very desktop it is photographing, which it otherwise
# would, every single time.
#
# RE-REGISTERED ONLY WHEN ABSENT. -Force would happily replace an identical task, and then a
# run that changed nothing would report a change.
if (-not (Get-TaskStatus $TaskName)) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$capture`" " +
                   "-Out `"$Out`" -MaxWidth $MaxWidth")
    # The principal is named by SID, not by name, for two measured reasons.
    #   1. In an ssh session $env:USERDOMAIN is "WORKGROUP" on a non-domain machine, not the
    #      computer name - so "$env:USERDOMAIN\$env:USERNAME" is WORKGROUP\forge, which does
    #      not resolve. Register-ScheduledTask fails with 0x80070534, "No mapping between
    #      account names and security IDs was done". MEASURED.
    #   2. A SID survives renaming the machine, and the machine SID does not change when the
    #      computer is renamed. A task registered as LAYER-0\forge would stop resolving the
    #      moment this guest is given a less temporary name, and it would fail silently -
    #      which matters here, because lib/forge/init.ps1 renames the guest in the same run.
    # windows-mcp's own task stores a bare SID for the same reason.
    $sid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null
    Write-Host "registered the task '$TaskName' (no trigger: it runs only when asked)"
    $changed = $true
} else {
    Write-Host "task '$TaskName' already registered"
}

if (Add-ToMachinePath $Dir) { $changed = $true }

Write-Host '--- verification ---'
Write-Host "  capture     $capture"
Write-Host "  trigger     $trigger"
$st = Get-TaskStatus $TaskName
Write-Host ("  task        {0}" -f $(if ($st) { "$TaskName ($st)" } else { 'MISSING' }))
Write-Host ("  on PATH     {0}" -f $(if (Test-OnPath $Dir) { $Dir } else { 'NO' }))
Write-Host ''
Write-Host 'Any agent with a shell on this guest can now run:  draugr-shot'
Write-Host 'It prints the path it wrote. Over ssh the PATH change needs a NEW session.'
Write-Host 'It photographs the INTERACTIVE desktop, so it needs someone logged on at the'
Write-Host 'console - which on this guest is the autologin session.'
Write-Host ("DRAUGR_CHANGED={0}" -f $(if ($changed) { 1 } else { 0 }))
