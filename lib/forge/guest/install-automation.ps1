# install-automation.ps1: the GUI automation of the default base image, a UIA
# MCP server and AutoHotkey.
#
# Run this IN THE GUEST through ssh, with the tunnel up. All its downloads come
# from hosts that kits/base allows (**.astral.sh, pypi.org,
# files.pythonhosted.org, github.com, **.autohotkey.com), so it needs no policy
# change.
#
# WHY THESE TWO. An agent that drives a Windows UI has a ladder of doors
# (docs/FORGE.md). The MCP server is the step that reads the real controls of a
# window, by name, with coordinates, not pixels or guesses. AutoHotkey is the
# step below it, for windows that have no tree (Slate, CEF: a test of the Unreal
# Editor and the Epic launcher found 0 elements). There, a path that the agent
# found once replays without a model.
#
# THE SESSION IS THE MAIN PROBLEM. That is why this script installs a scheduled
# task, and does not only start a server. An ssh session arrives in **session
# 0**, which has no desktop. A TEST SHOWED THIS: AutoHotkey started from ssh
# reports "Target window not found" for the active window, WinGetList() returns
# nothing, and UI Automation sees nothing either. The same script, run through
# the MCP server, lists each window. This task starts the server in **session
# 1**, the autologin desktop that a person sees through VNC. `windows-mcp
# install` registers that task. Do not replace it with a plain `serve`.
#
# Traps that tests found, and each one cost time:
#   - When the response has no charset, Invoke-WebRequest -UseBasicParsing gives .Content as
#     a **Byte[]**, and Invoke-Expression refuses a Byte[]. Decode it.
#   - The default host of `windows-mcp auth` is **0.0.0.0**. Always give 127.0.0.1. The guest
#     has no adapter now, but do not leave the bind of all interfaces to a default.
#   - The endpoint is **/mcp**, not /mcp/. The trailing slash answers 307, and a client that
#     does not POST again after a redirect reports a failure.
#   - The auth key goes into the ~/.windows-mcp/config.toml of the guest. It stays in the guest.
#
# Measured cost: uv 41 MB, CPython 3.14 60 MB, the venv of the server 153 MB,
# AutoHotkey 4.3 MB. That is about 260 MB, plus a wheel cache of 151 MB. `uv
# cache prune` frees NOTHING of that cache (a test showed 150.7 MB before and
# after). The environment of the tool still uses each entry, and prune removes
# only unused ones. Thus -CleanCache runs `uv cache clean`, and that is what a
# base image needs. The cache makes downloads faster, and a later install
# fetches again.
#
#   powershell -ExecutionPolicy Bypass -File .\install-automation.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-automation.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File .\install-automation.ps1 -CleanCache
# 8765, not the default of the server, 8000. The built-in Unreal MCP plugin of
# UE 5.8 serves http://127.0.0.1:8000/mcp inside the editor process. With two
# servers on one port, the first to start wins. 8000 stays reserved for the
# editor.
param(
    [int]$Port = 8765,
    [string]$AhkDir = 'C:\Tools\AutoHotkey',
    # PINNED, AND IT MUST BE. uv with no version request installs the NEWEST
    # CPython. The ecosystem always had the least time to build wheels for that
    # one. A TEST on a new guest showed this. Without a pin, uv gave 3.15.2.
    # Then `uv tool install windows-mcp` resolved pyyaml==6.0.3, and found no
    # cp315 wheel. It tried to BUILD it, and stopped on "Microsoft Visual C++
    # 14.0 or greater is required". This guest has no compiler, on purpose. On
    # PyPI that day, pyyaml 6.0.3 had cp313 and cp314 Windows wheels, and no
    # cp315. The comments below record that 3.14.8 works. Thus nothing here
    # changed. 3.15 came out, and that was enough to break it.
    #
    # LOOK AT A PIN AGAIN LATER. Do not forget it. After the dependency tree has
    # wheels for the next version, raise it. It is a parameter, so that you can
    # try that without an edit.
    [string]$PythonVersion = '3.14',
    # What to do with the console window of the server. It is not only for
    # looks. The window list of the agent and each screenshot that it takes
    # include this window. Thus a permanent empty console is noise in the view
    # of the desktop, for the agent and the person.
    #   Normal     keep it on the screen, with a title and a color, so that you know it
    #   Minimized  out of the way. Still with a title, still in the window list
    #   Hidden     no window. See Set-McpWindow for the cost
    [ValidateSet('Normal', 'Minimized', 'Hidden')]
    [string]$McpWindow = 'Minimized',
    [switch]$VerifyOnly,
    [switch]$CleanCache,
    [switch]$ShowKey
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # through ssh, progress records become CLIXML noise

$uvBin = "$env:USERPROFILE\.local\bin"
$uv    = Join-Path $uvBin 'uv.exe'
$wmcp  = Join-Path $uvBin 'windows-mcp.exe'
$cfg   = "$env:USERPROFILE\.windows-mcp\config.toml"

# Set-McpWindow: the title, the color, and the window state of the console of
# the server.
#
# Call it AFTER `windows-mcp install`. With --force, that command rewrites
# start-server.cmd from its own template each time. An edit before it, or a
# manual edit in the guest, is gone at the next provisioning run.
#
# THE WINDOW BELONGS TO CMD, NOT TO PYTHON. That difference cost a wrong fix.
# The first attempt replaced python.exe with pythonw.exe. The idea was that cmd
# does not wait for a GUI-subsystem child, and exits, and its console goes with
# it. That rule is for POWERSHELL, not for cmd. `cmd /c` waits for each child,
# for each subsystem. A test after the change showed this: cmd.exe still ran `/c
# ""...start-server.cmd""`, the window was still on the screen, and two
# pythonw.exe were behind it. A new interpreter changes nothing about the
# console, because the console never belonged to python. Task Scheduler gives it
# to cmd, because cmd is a console program with an InteractiveToken.
#
# Thus the launcher must not be a console program. wscript.exe is GUI-subsystem,
# so the task creates no console for it. The VBScript then starts the .cmd with
# an explicit show-command, and THAT decides whether a window appears. Hidden=0,
# minimized without the focus=7, normal=1. Redirection still works, because cmd
# still does it. Only its window is hidden.
#
# ANOTHER TEST showed that the other half of the first attempt was wrong.
# Windows Terminal 1.18.10301.0 IS installed here (WindowsTerminal.exe and
# OpenConsole.exe -Embedding both run in session 1). An earlier `where wt.exe`
# said the opposite. But that probe ran through ssh in session 0, where the
# app-execution alias does not resolve. That was a false negative, not a missing
# terminal. Thus a show-command at creation, not `start /min`, whose effect
# depends on the terminal that hosts it.
#
# This code cannot see a window. Session 0 has its own window station, so
# MainWindowTitle is empty for each window in session 1. Only a person at the
# VNC screen can say whether this looks correct.
function Set-McpWindow([string]$StartCmd, [string]$Mode, [string]$Title) {
    if (-not (Test-Path $StartCmd)) {
        Write-Host "  no $StartCmd. The window does not change."
        return
    }
    $txt = Get-Content $StartCmd -Raw

    if ($Mode -ne 'Hidden' -and $txt -notmatch '(?m)^title ') {
        # Added once, directly after @echo off. color 1F is bright white ON
        # BLUE. You see it quickly in a VNC window, and nothing else on this
        # desktop is blue.
        $txt = $txt -replace '(?m)^@echo off\r?\n', "@echo off`r`ntitle $Title`r`ncolor 1F`r`n"
        Set-Content $StartCmd $txt -Encoding ASCII
        Write-Host "  window      titled '$Title', blue"
    } else {
        Write-Host '  window      already titled'
    }

    # The show-command that the VBScript gives to WScript.Shell.Run. These are
    # the documented SW_* values: 0 hides, 7 minimizes without the focus, 1
    # shows normally.
    $show = @{ 'Hidden' = 0; 'Minimized' = 7; 'Normal' = 1 }[$Mode]
    $vbs = Join-Path (Split-Path $StartCmd -Parent) 'run-server.vbs'
    # Written again at each run, not created once. Thus a change of -McpWindow
    # really changes something on a guest that already has the file.
    @(
        "' Draugr made this with lib/forge/guest/install-automation.ps1. Do not edit it.",
        "' wscript.exe is GUI-subsystem, so Task Scheduler gives this no console. The",
        "' show-command below decides whether the console of the server is visible.",
        "CreateObject(""WScript.Shell"").Run """"""$StartCmd"""""", $show, False"
    ) | Set-Content $vbs -Encoding ASCII

    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
    # Only for looks, so a failure here warns, and does not stop the
    # provisioning run.
    try {
        Set-ScheduledTask -TaskName 'windows-mcp-server' -Action $act -EA Stop | Out-Null
        Write-Host "  task action $Mode"
    } catch {
        Write-Host "  task action COULD NOT be set to ${Mode}: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-Text([string]$url) {
    $r = Invoke-WebRequest -UseBasicParsing $url
    if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { $r.Content }
}
# Add-ToMachinePath: put a directory on the MACHINE PATH, once, JUST BEFORE
# System32.
#
# Not at the end and not at the start, but at an exact position. MSYS2 ships
# find.exe and sort.exe that hide the Windows ones. That is the PURPOSE, because
# people want the GNU versions. It also ships link.exe, which hides the linker
# of MSVC. That one can cause damage.
#
# A TEST SHOWED THIS, and it is why the start of PATH is safe. With
# C:\msys64\usr\bin FIRST, and then a run of vcvars64.bat, `where link` answers
#   C:\...\MSVC\14.38.33130\bin\Hostx64\x64\link.exe      <- MSVC, first
#   C:\msys64\usr\bin\link.exe
# because vcvars PUTS the toolchain directory at the START. UnrealBuildTool is
# safe in both cases, because it resolves the toolchain with an absolute path.
# The other case is a bare `link` outside a developer prompt, and there nothing
# expects MSVC.
#
# BUT NOT AT THE VERY START, because MSYS2 also ships ssh.exe, scp.exe, and
# ssh-keygen.exe. A TEST SHOWED THIS. At the start, `ssh` resolved to
# C:\msys64\usr\bin\ssh.exe, not to the Windows OpenSSH client. The MSYS2 client
# reads key paths, HOME, and known_hosts with POSIX semantics. All else in this
# project (the host tunnel, the own sshd of the guest, each script here) is
# Windows OpenSSH. One ssh that works differently from the others inside the
# guest is a trap for later.
#
# Thus: insert directly BEFORE the System32 entry. MSYS2 still wins over Windows
# for find and sort. All entries that are on purpose before System32 still win,
# and the OpenSSH directory is there. If System32 is not on PATH, something is
# already very wrong, and the start of PATH is the safe fallback.
#
# Windows builds PATH as MACHINE, then USER. Thus all that this adds also comes
# before the entries of the user, also %USERPROFILE%\.local\bin. MSYS2 ships no
# python.exe, so it cannot hide the interpreter that install-automation.ps1 puts
# there.
#
# THE SAME AS THE COPY IN install-base-tools.ps1, ON PURPOSE. Each guest script
# here goes into the guest alone, and runs alone. A shared helper file makes
# "copy one file, run it" false, and both need this one. If you change one,
# change both.
function Add-ToMachinePath([string]$Dir, [string]$Before = "$env:SystemRoot\system32") {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($cur -split ';' | Where-Object { $_ })
    $norm = $parts | ForEach-Object { $_.TrimEnd('\').ToLower() }
    if ($norm -contains $Dir.TrimEnd('\').ToLower()) {
        Write-Host "  PATH already has $Dir"
        return $false
    }
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

function Get-Mb([string]$p) {
    if (Test-Path $p) {
        [math]::Round((Get-ChildItem $p -Recurse -File -Force -EA SilentlyContinue |
            Measure-Object Length -Sum).Sum / 1MB, 1)
    } else { 0 }
}

if (-not $VerifyOnly) {
    # --- uv: a Python for one program, without a Python for the whole system -----------
    if (Test-Path $uv) {
        Write-Host "uv already present: $(& $uv --version)"
    } else {
        Write-Host 'installing uv...'
        $env:UV_INSTALL_DIR = $uvBin
        Invoke-Expression (Get-Text 'https://astral.sh/uv/install.ps1')
        if (-not (Test-Path $uv)) { throw "uv did not appear at $uv" }
        Write-Host "  $(& $uv --version)"
    }

    # --- a Python that answers to `python` ---------------------------------------------
    # uv installs interpreters under %APPDATA%\uv\python, and by default puts NO
    # entry point on PATH. `uv run python` works, and `python` does not. On a
    # default Windows 11, `python` is not missing, but WORSE than missing. It
    # resolves to the app-execution-alias stub of the Microsoft Store in
    # %LOCALAPPDATA%\Microsoft\WindowsApps. On a guest with no Store, that stub
    # answers "Python was not found; run without arguments to install from the
    # Microsoft Store". That looks like a broken Python, not like no Python.
    #
    # --default writes real python.exe and python3.exe shims into the bin
    # directory of uv, %USERPROFILE%\.local\bin. That is already before
    # WindowsApps on the PATH of the user, so the stub stops winning. A TEST
    # SHOWED THIS: `python -V` -> Python 3.14.8, with sys.executable in
    # %APPDATA%\uv\python. It cost 46 ms, because the interpreter was already on
    # the disk. Only the entry point was missing.
    #
    # EXPERIMENTAL, and said clearly, because this code needs it. uv warns that
    # --default "may change without warning". --preview-features stops the
    # warning, and does not change the behavior. If a future uv removes the
    # flag, the fallback is a shim that calls `uv run python`. That is uglier,
    # but stable.
    #
    # SAFE TO RUN AGAIN. That is two separate problems. (1) On a guest that
    # already has it, uv writes "Python is already installed. Use `uv python
    # install <request>` to install another version." to STDERR. That means
    # NOTHING TO DO. With $ErrorActionPreference = 'Stop' above, and the 2>&1
    # that this call needs for the log of uv, PowerShell 5.1 makes that line a
    # terminating NativeCommandError. Then the whole provisioning run dies at
    # this phase, before the clean-up and the manifest. A TEST on the second run
    # of a complete guest showed this. (2) Also with a guard, a call only to
    # hear "nothing to do" is not idempotence. Thus the code asks the question
    # here first, at low cost.
    #
    # THE QUESTION IS THE VERSION, NOT THE PRESENCE OF THE SHIM. That changed
    # with the pin above. "A python.exe is there" was the correct test while
    # each python was good. When one version is required, a presence test
    # passes on the wrong interpreter. This guest is the proof. The failed run
    # left a 3.15.2 shim. A presence test then lets the next run keep exactly
    # the interpreter that it must replace.
    #
    # -V and a regex, not `-c 'import sys; ...'`. Never give an argument with
    # quotes inside it through PowerShell to a native exe. See docs/FORGE.md.
    $pyShim = Join-Path $uvBin 'python.exe'
    $shimVer = ''
    if (Test-Path $pyShim) {
        if ("$(& $pyShim -V)" -match '(\d+\.\d+)') { $shimVer = $Matches[1] }
    }
    if ($shimVer -eq $PythonVersion) {
        Write-Host "python $shimVer already reachable: $pyShim"
    } else {
        if ($shimVer) {
            Write-Host "python $shimVer is reachable, but the pin is $PythonVersion. Installing that."
        } else {
            Write-Host 'making python reachable as `python`...'
        }
        $eapWas = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $uv python install $PythonVersion --default --preview-features python-install-default 2>&1 |
                ForEach-Object { Write-Host "  $_" }
        } finally { $ErrorActionPreference = $eapWas }
        # This block exists to make the shim, so a missing shim IS a failure.
        # The extra output of uv is not. The code tests the VERSION for the same
        # reason. A shim for the wrong interpreter is what this block must fix.
        # "It exists" reports success on the state that caused the problem.
        if (-not (Test-Path $pyShim)) { throw "uv did not create $pyShim" }
        $after = ''
        if ("$(& $pyShim -V)" -match '(\d+\.\d+)') { $after = $Matches[1] }
        if ($after -ne $PythonVersion) {
            throw "$pyShim reports '$after', not the pinned $PythonVersion"
        }
    }

    # uv and windows-mcp both write UTF-8 to stdout. PowerShell decodes the
    # output of a native program with [Console]::OutputEncoding. On this guest,
    # that is codepage 1252, because install-guest-base sets it. Then an en dash
    # arrives as a wrong accented letter: "Scheduled task installed ù server is
    # starting now." A TEST SHOWED THIS. It breaks nothing. But a provisioning
    # log that shows the output of its own tools as garbage is one more thing
    # that a reader must learn to ignore.
    #
    # Not restored after, on purpose. This is a console attribute of THIS
    # process, which exits at the end of the script. The codepage of the guest
    # is a system configuration, and does not change.
    [Console]::OutputEncoding = [Text.Encoding]::UTF8

    # --- the MCP server: one tool install, on the pinned interpreter ------------------
    # --python, EXPLICITLY. Without it, uv selects an interpreter for the venv
    # of the tool, independently of the shim above. It selects the newest that
    # it can find. That is how this phase built its dependencies against 3.15,
    # while the comments of the file said 3.14. With the name, the venv of the
    # tool and `python` have the same version. Only that gives the pin above a
    # meaning here.
    Write-Host "installing windows-mcp on python $PythonVersion..."
    & $uv tool install --quiet --python $PythonVersion windows-mcp
    if (-not (Test-Path $wmcp)) { throw "windows-mcp did not appear at $wmcp" }

    # --- a bearer token and a loopback binding, then the session-1 task ---------------
    if (Test-Path $cfg) {
        Write-Host "auth config already present: $cfg"
    } else {
        Write-Host 'generating the auth key...'
        & $wmcp auth --transport streamable-http --host 127.0.0.1 --port $Port --force | Out-Null
    }
    # Stop each running server, by its path, BEFORE the install of the task. The
    # own `uninstall` of the tool prints "Stopped the running server", but the
    # server still runs (a test showed this). A server that survives holds
    # append handles on server.log and server.error.log. Then the new
    # start-server.cmd cannot open its redirects, cmd exits 1, and nothing
    # records why. A silent failure, with an old server that still answers on
    # the old port, is the worst result. 'python' and 'pythonw': the second,
    # because the first attempt to hide this window left pythonw.exe running on
    # some guests. A probe that misses it leaves the old server alive, with
    # append handles on the logs. That is the silent failure above.
    Get-Process python, pythonw -EA SilentlyContinue | Where-Object { $_.Path -like '*\uv\tools\windows-mcp\*' } |
        ForEach-Object { Write-Host "  stopping the running server (pid $($_.Id))"; Stop-Process -Id $_.Id -Force }

    Write-Host 'registering the login task...'
    & $wmcp install --transport streamable-http --host 127.0.0.1 --port $Port --force |
        ForEach-Object { "  $_" }

    # Always AFTER the install. See the header of Set-McpWindow. With -McpWindow
    # Minimized or Hidden, the task ends at the exit of cmd. Thus `schtasks
    # /query` reports Ready, not Running. That is expected, not a regression.
    # The server is detached then, and the test below asks the PORT. Only that
    # answer is useful.
    Set-McpWindow -StartCmd "$env:USERPROFILE\.windows-mcp\start-server.cmd" `
                  -Mode $McpWindow -Title 'Draugr: UIA MCP server (leave it running)'

    # --- AutoHotkey v2 from the zip: no installer, no elevation, no file association ---
    $v = (Get-Text 'https://www.autohotkey.com/download/2.0/version.txt').Trim()
    $exe = Join-Path $AhkDir 'AutoHotkey64.exe'
    if ((Test-Path $exe) -and (Get-Item $exe).VersionInfo.ProductVersion -eq $v) {
        Write-Host "AutoHotkey $v already present"
    } else {
        Write-Host "installing AutoHotkey $v..."
        $zip = Join-Path $env:TEMP "AutoHotkey_$v.zip"
        Invoke-WebRequest -UseBasicParsing "https://www.autohotkey.com/download/2.0/AutoHotkey_$v.zip" -OutFile $zip
        New-Item -ItemType Directory -Force -Path $AhkDir | Out-Null
        Expand-Archive -Path $zip -DestinationPath $AhkDir -Force
        Remove-Item $zip -Force
    }

    # AutoHotkey is here to run a .ahk from the command line. In a directory
    # that nothing can find, it is useless. A TEST SHOWED THIS: AutoHotkey64 did
    # not resolve as a command on a finished base image.
    Write-Host ''
    Write-Host 'PATH'
    [void](Add-ToMachinePath $AhkDir)
}

if ($CleanCache) {
    $before = Get-Mb "$env:LOCALAPPDATA\uv\cache"
    & $uv cache clean --quiet
    Write-Host "wheel cache: $before MB -> $(Get-Mb "$env:LOCALAPPDATA\uv\cache") MB"
}

# --- verification: by effect, never by presence --------------------------------------
Write-Host ''
Write-Host '--- verification ---'
$bad = @()

# The state of the task tells little. It starts a detached server, and goes back
# to "Ready". Thus the code reports it, and does not judge it. The listener
# below is the real test. Get-ScheduledTask, NOT `schtasks /query ... 2>$null`.
# With Stop in force, a redirected native stderr line is a terminating error,
# and schtasks writes one for a missing task. Thus this test threw on exactly
# the guest that it must report on. The same defect stopped install-shot.ps1.
# Here, the code never got there, because the install above failed first. This
# file already had the explanation, two hundred lines above, next to the one
# call with a guard. A TEST SHOWED THIS. See docs/FORGE.md.
$state = Get-ScheduledTask -TaskName 'windows-mcp-server' -ErrorAction SilentlyContinue
if ($state) {
    Write-Host "  task        registered (state: $($state.State))"
} else {
    Write-Host '  task        MISSING' -ForegroundColor Red; $bad += 'task'
}

# The listener must be in session 1. In session 0, the server runs, answers,
# and sees nothing. This design exists to prevent exactly that failure, and it
# is silent.
#
# Wait for it. After the task starts, the server takes about 4 s to bind (a test
# showed this). A test directly after `install` reports a failure that is only
# impatience.
$c = $null
for ($i = 0; $i -lt 25; $i++) {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue |
         Where-Object { $_.LocalAddress -eq '127.0.0.1' } | Select-Object -First 1
    if ($c) { break }
    Start-Sleep -Seconds 1
}
if ($c) {
    $sess = (Get-Process -Id $c.OwningProcess -EA SilentlyContinue).SessionId
    if ($sess -ge 1) {
        Write-Host "  listener    127.0.0.1:$Port in session $sess"
    } else {
        Write-Host "  listener    127.0.0.1:$Port in SESSION $sess. UIA sees nothing" -ForegroundColor Red
        $bad += 'session'
    }
} else {
    Write-Host "  listener    NOTHING ON $Port" -ForegroundColor Red; $bad += 'listener'
}

# The server must refuse a request without authentication. With the forward in
# place, only the token protects the desktop from all else that can reach the
# port.
try {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/mcp" `
         -ContentType 'application/json' -Body '{}' -TimeoutSec 10
    Write-Host "  no-token    ANSWERED $($r.StatusCode). The server does not ask for a token" -ForegroundColor Red
    $bad += 'auth'
} catch {
    $code = [int]$_.Exception.Response.StatusCode
    if ($code -eq 401) { Write-Host '  no-token    401, as expected' }
    else { Write-Host "  no-token    $code (expected 401)" -ForegroundColor Yellow }
}

$exe = Join-Path $AhkDir 'AutoHotkey64.exe'
if (Test-Path $exe) {
    Write-Host "  autohotkey  $((Get-Item $exe).VersionInfo.ProductVersion)  ($AhkDir)"
} else {
    Write-Host '  autohotkey  MISSING' -ForegroundColor Red; $bad += 'autohotkey'
}

# REPORTED, NOT JUDGED. A PATH change reaches only new processes, so this
# session can correctly disagree with the machine. A failure of the run for that
# is wrong.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'
$ahkOnPath = $machinePath | Where-Object { $_.TrimEnd('') -ieq $AhkDir.TrimEnd('') }
Write-Host ("  PATH        AutoHotkey {0}" -f $(if ($ahkOnPath) { 'on the machine PATH' }
                                                else { 'NOT on the machine PATH' }))
$pyExe = Join-Path $uvBin 'python.exe'
if (Test-Path $pyExe) {
    # NO 2>&1 HERE. Under Stop, a redirected native stderr line is terminating.
    # Thus a broken interpreter throws inside exactly the block that must report
    # it. Without the redirect, the complaint of python goes to the console, and
    # the test continues. That is the purpose of a test. See
    # tests/lint-native-stderr.sh.
    #
    # THE CODE ALSO JUDGES THE VERSION, and does not only print it. The pin is
    # the reason for this phase (see -PythonVersion). Thus an interpreter that
    # is not the pinned one is a finding, not a detail. A guest from a failed
    # run shows exactly that.
    $pyV = "$(& $pyExe -V)"
    $pyMinor = ''
    if ($pyV -match '(\d+\.\d+)') { $pyMinor = $Matches[1] }
    if ($pyMinor -eq $PythonVersion) {
        Write-Host "  python      $pyV  ($pyExe)"
    } else {
        Write-Host "  python      $pyV  ($pyExe). NOT the pinned $PythonVersion" -ForegroundColor Red
        $bad += 'python version'
    }
} else {
    Write-Host '  python      no python.exe in uv bin. A bare `python` finds the Store stub' -ForegroundColor Yellow
}

Write-Host ("  footprint   uv {0} MB, python {1} MB, venv {2} MB, ahk {3} MB, cache {4} MB" -f `
    (Get-Mb $uvBin), (Get-Mb "$env:APPDATA\uv\python"), (Get-Mb "$env:APPDATA\uv\tools"),
    (Get-Mb $AhkDir), (Get-Mb "$env:LOCALAPPDATA\uv\cache"))

Write-Host ''
if ($ShowKey -and (Test-Path $cfg)) {
    Get-Content $cfg | Where-Object { $_ -match 'auth_key' } | ForEach-Object { "  $_" }
} else {
    Write-Host "The bearer token is in $cfg (-ShowKey prints it). It belongs to this"
    Write-Host 'guest. Do not copy it into the repository.'
}
if ($bad.Count) { Write-Host "FAILED: $($bad -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'automation ready.' -ForegroundColor Green
