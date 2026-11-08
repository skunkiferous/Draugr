# install-shot.ps1: let an agent take a picture of the desktop of the guest,
# from a shell.
#
# ==> lib/forge/init.ps1 RUNS IT, IN THE GUEST. You can also run it yourself. <==
#
# THE PROBLEM IS THE SESSION. An agent connects to this machine through ssh, and
# arrives in SESSION 0. Session 0 has its own window station and no desktop.
# Thus a capture there is not a dark screenshot. There is nothing to take a
# picture of. The desktop that a person sees through VNC is session 1, and only
# a process that runs THERE can capture it. The answer is a scheduled task with
# an interactive principal. Session 0 can START it, but it RUNS in session 1:
#
#   agent (session 0)  ->  draugr-shot.cmd  ->  schtasks /run  ->  capture.ps1 (session 1)
#                                                                        |
#                       C:\Draugr\shot.png  <----------------------------+
#
# WHY A LAYER-0 COMPONENT, AND NOT AN OPTIONAL ONE. The test of docs/FORGE.md is
# *does a Windows VM for a different purpose want this?*. An agent that cannot
# see the screen is the general case, not only the Unreal case. Nothing here is
# for one engine.
#
# WHY NOT ONLY THE MCP SERVER, which has a Screenshot tool and is already in
# session 1. Because that needs an MCP client, a bearer token, and a working
# server. You most want to look at the desktop while one of those is broken.
# This path needs only a shell. Thus it still works on a bad day. The two
# complete each other. They do not compete.
#
# THE TASK HAS NO TRIGGER. It runs only on request, so it costs nothing at
# logon, and it cannot take a picture of the desktop unless somebody asks.
#
#   powershell -ExecutionPolicy Bypass -File .\install-shot.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-shot.ps1 -VerifyOnly
#
# Afterwards, from anywhere including ssh:
#
#   draugr-shot                    writes C:\Draugr\shot.png and prints the path
#   draugr-shot D:\other\path.png  to another place
#
# IT ENDS WITH DRAUGR_CHANGED=0 or =1. With that, init knows "installed it" from
# "it was already there". That is why this copy differs from the copy of the
# gateway. A summary that cannot tell those apart is the one defect that an
# idempotent script must not have.
param(
    [string]$Dir = 'C:\ProgramData\draugr-shot',
    [string]$Out = 'C:\Draugr\shot.png',
    # Made smaller on the way out. The reader is a model with a pixel budget,
    # not a person with a monitor. 1920 keeps the window text readable. 0 turns
    # off the scaling.
    [int]$MaxWidth = 1920,
    [string]$TaskName = 'draugr-shot',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Each guest script must run alone through ssh, with no imports. Thus this is a
# copy, not shared. It goes BEFORE system32, so that the directory wins over
# each file with the same name that Windows ships.
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

# NO `schtasks /query ... 2>$null` HERE. That was the whole bug of this file.
# $ErrorActionPreference is Stop above. PowerShell 5.1 wraps a REDIRECTED native
# stderr line as a NativeCommandError, and Stop makes it terminating. For a task
# that does not exist, schtasks writes "ERROR: The system cannot find the file
# specified." to stderr. This function must find a MISSING task, and it threw
# each time the task was missing, so at each first install. The phase reported
# FAILED (1), with the capture script and the trigger already written, and no
# task registered.
#
# A TEST in the guest, with no task and Stop in force: the schtasks form threw
# (NativeCommandError). Get-ScheduledTask returned $null, quietly. Native stderr
# without a redirect passes through with no damage. The redirect causes it. See
# docs/FORGE.md.
#
# .State has the same words that schtasks printed under "Status:": Ready,
# Running, Disabled. Thus each caller below reads what it read before.
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

# --- the half that runs in session 1 -------------------------------------------------
# Written from here, not shipped as its own file. Thus there is one file to copy
# into the guest, and the installed file cannot become different from the
# installer.
#
# @' '@ is LITERAL. The inner Add-Type here-string and each $ in the script
# below must go into the file without change. An interpolating @" "@ removes
# them.
$captureBody = @'
# capture.ps1: take a picture of the desktop of THIS session. The draugr-shot
# task starts it. That is how a caller in session 0 runs code in session 1. Do
# not call it directly from ssh. It works there, but makes nothing useful,
# because session 0 has no desktop. Draugr made this with
# lib/forge/guest/install-shot.ps1. Do not edit it.
param([string]$Out = 'C:\Draugr\shot.png', [int]$MaxWidth = 1920)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# DPI awareness BEFORE the first measure. Without it, a scaled desktop reports
# LOGICAL pixels, and the capture is a blurry crop of the top-left corner. That
# looks like a broken tool, not like a DPI problem.
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

# Scale AFTER the capture, never before. CopyFromScreen must take real pixels.
# Otherwise the text becomes unreadable in the smaller image.
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

# Written to a temp name, and MOVED into place. The caller polls for the
# existence of the file. Thus it reads a half-written PNG at the final path as a
# finished one. That race almost never gives a damaged image, until the one time
# that it matters.
$tmp = "$Out.tmp"
$img.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
if ($img -ne $full) { $img.Dispose() }
$full.Dispose()
Move-Item -LiteralPath $tmp -Destination $Out -Force
'@

# COMPARED BEFORE THE WRITE, so that a second run that changes nothing can say
# so. Set-Content rewrites an identical file, and then each init reports the
# camera as installed again. That is how a summary starts to lie.
$changed = $false
if ((-not (Test-Path $capture)) -or ((Get-Content $capture -Raw) -ne ($captureBody + "`r`n"))) {
    Set-Content -Path $capture -Value $captureBody -Encoding UTF8
    Write-Host "wrote $capture"
    $changed = $true
} else {
    Write-Host "already current: $capture"
}

# --- the half that each agent calls -------------------------------------------------
# cmd, not PowerShell. It is the simplest common way to "run one thing through
# ssh", and an agent that knows nothing about this machine can still call it.
#
# `ping -n 2 127.0.0.1` is the sleep, NOT `timeout /t`. A test found this trap.
# When stdin is not a console, timeout.exe fails with "ERROR: Input redirection
# is not supported", and through ssh, stdin is never a console.
$triggerBody = @"
@echo off
setlocal
rem draugr-shot: take a picture of the desktop of the guest, from each session, also ssh.
rem Draugr made this with lib/forge/guest/install-shot.ps1. Do not edit it.
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
    echo draugr-shot: timed out while waiting for "%OUT%".
    echo   The task runs in the INTERACTIVE session. If nobody is logged on at the
    echo   console, there is no desktop to take a picture of, and it makes nothing.
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
# LogonType Interactive is the whole mechanism. -WindowStyle Hidden keeps the
# capture from a PowerShell window in exactly the desktop that it takes a
# picture of. Otherwise that happens each time.
#
# REGISTERED AGAIN ONLY FOR A MISSING TASK. -Force replaces an identical task,
# and then a run that changed nothing reports a change.
if (-not (Get-TaskStatus $TaskName)) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$capture`" " +
                   "-Out `"$Out`" -MaxWidth $MaxWidth")
    # The principal has a SID, not a name, for two reasons that tests found.
    #   1. In an ssh session on a machine without a domain, $env:USERDOMAIN is "WORKGROUP",
    #      not the computer name. Thus "$env:USERDOMAIN\$env:USERNAME" is WORKGROUP\forge,
    #      and that does not resolve. Register-ScheduledTask fails with 0x80070534, "No
    #      mapping between account names and security IDs was done". A TEST SHOWED THIS.
    #   2. A SID survives a rename of the machine. The machine SID does not change with the
    #      computer name. A task registered as LAYER-0\forge stops to resolve as soon as this
    #      guest gets a less temporary name, and it fails silently. That is important here,
    #      because lib/forge/init.ps1 renames the guest in the same run.
    # The own task of windows-mcp stores a bare SID for the same reason.
    $sid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null
    Write-Host "registered the task '$TaskName' (no trigger. It runs only on request)"
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
Write-Host 'It prints the path that it wrote. Through ssh, the PATH change needs a NEW session.'
Write-Host 'It takes a picture of the INTERACTIVE desktop, so it needs somebody logged on at'
Write-Host 'the console. On this guest, that is the autologin session.'
Write-Host ("DRAUGR_CHANGED={0}" -f $(if ($changed) { 1 } else { 0 }))
