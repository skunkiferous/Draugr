# install-automation.ps1 - the default base image's GUI automation: a UIA MCP server
# and AutoHotkey.
#
# Run this IN THE GUEST over ssh, with the tunnel up. Everything it downloads comes from
# hosts kits/base allows (**.astral.sh, pypi.org, files.pythonhosted.org, github.com,
# **.autohotkey.com), so it needs no policy change of its own.
#
# WHY THESE TWO. An agent driving a Windows UI has a ladder of doors (docs/FORGE.md):
# the MCP server is the rung that reads a window's actual controls, by name, with
# coordinates - not pixels, not guesses. AutoHotkey is the rung below it, for windows
# that have no tree at all (Slate, CEF: the Unreal Editor and the Epic launcher measure
# 0 elements), where a path found once is replayed without a model in the loop.
#
# THE SESSION IS THE WHOLE PROBLEM, and it is why this script installs a scheduled task
# rather than just starting a server. An ssh session lands in **session 0**, which has
# no desktop: measured, AutoHotkey launched from ssh reports "Target window
# not found" for the active window and WinGetList() returns nothing at all, and UI
# Automation is equally blind. The same script, run through the MCP server - which this
# task starts in **session 1**, the autologin desktop a human sees over VNC - enumerates
# every window. `windows-mcp install` registers that task itself; do not replace it with
# a plain `serve`.
#
# Measured traps, each of which cost time:
#   - Invoke-WebRequest -UseBasicParsing hands back .Content as a **Byte[]** when the
#     response carries no charset, and Invoke-Expression refuses a Byte[]. Decode it.
#   - `windows-mcp auth` defaults to **host 0.0.0.0**. Always pass 127.0.0.1: the guest
#     has no adapter today, but a server that would bind every interface is not something
#     to leave to a default.
#   - the endpoint is **/mcp**, not /mcp/ - the trailing slash answers 307, which a client
#     that does not re-POST on redirect reports as a failure.
#   - the auth key lands in the guest's ~/.windows-mcp/config.toml. It stays in the guest.
#
# Measured cost: uv 41 MB, CPython 3.14 60 MB, the server's venv 153 MB,
# AutoHotkey 4.3 MB - about 260 MB, plus a 151 MB wheel cache. `uv cache prune` reclaims
# NOTHING of that cache (measured: 150.7 MB before and after), because every entry is
# still referenced by the tool's own environment - prune only drops unused ones. So
# -CleanCache runs `uv cache clean`, which is what a base image wants: the cache is a
# download accelerator, and a later install simply fetches again.
#
#   powershell -ExecutionPolicy Bypass -File .\install-automation.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-automation.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File .\install-automation.ps1 -CleanCache
# 8765, not the server's own default of 8000: UE 5.8's built-in Unreal MCP plugin serves
# http://127.0.0.1:8000/mcp inside the editor process, and two servers on one port is a
# fight decided by whoever started first. 8000 stays reserved for the editor.
param(
    [int]$Port = 8765,
    [string]$AhkDir = 'C:\Tools\AutoHotkey',
    # PINNED, AND IT HAS TO BE. uv with no version request installs the NEWEST CPython,
    # which is always the one the ecosystem has had least time to build wheels for.
    # MEASURED, on a guest built from nothing: unpinned gave 3.15.2, and
    # `uv tool install windows-mcp` then resolved pyyaml==6.0.3, found no cp315 wheel,
    # tried to BUILD it, and stopped on "Microsoft Visual C++ 14.0 or greater is required"
    # - in a guest whose whole point is that it has no compiler. PyPI the same day: pyyaml
    # 6.0.3 ships cp313 and cp314 Windows wheels and no cp315. The comments further down
    # record 3.14.8 working, so nothing here changed: 3.15 shipped, and that
    # was enough to break it.
    #
    # A PIN IS A THING TO REVISIT, not a thing to forget. Raise it once the dependency tree
    # has wheels for the next one; it is a parameter so that can be tried without an edit.
    [string]$PythonVersion = '3.14',
    # What to do about the server's console window. It is not cosmetic-only: the agent's
    # own window list and every screenshot it takes include this window, so a permanent
    # empty console is noise in the agent's view of the desktop as well as the human's.
    #   Normal     leave it on screen, but titled and coloured so it is identifiable
    #   Minimized  out of the way; still titled, still enumerable
    #   Hidden     no window at all - see Set-McpWindow for what that costs
    [ValidateSet('Normal', 'Minimized', 'Hidden')]
    [string]$McpWindow = 'Minimized',
    [switch]$VerifyOnly,
    [switch]$CleanCache,
    [switch]$ShowKey
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # progress records become CLIXML noise over ssh

$uvBin = "$env:USERPROFILE\.local\bin"
$uv    = Join-Path $uvBin 'uv.exe'
$wmcp  = Join-Path $uvBin 'windows-mcp.exe'
$cfg   = "$env:USERPROFILE\.windows-mcp\config.toml"

# Set-McpWindow - title, colour and window state for the server's console.
#
# MUST be called AFTER `windows-mcp install`, which rewrites start-server.cmd from its own
# template every time --force is passed. An edit applied before it, or by hand in the
# guest, is simply gone on the next provisioning run.
#
# THE WINDOW IS CMD'S, NOT PYTHON'S, and that distinction cost a wrong fix.
# The first attempt swapped python.exe for pythonw.exe, reasoning that cmd would not wait
# for a GUI-subsystem child and would exit, taking its console with it. That rule is
# POWERSHELL'S, not cmd's: `cmd /c` waits for any child whatever its subsystem. Measured
# after the change - cmd.exe still running `/c ""...start-server.cmd""`, window still on
# screen, two pythonw.exe behind it. Swapping the interpreter changes nothing about the
# console, because the console was never python's to begin with: Task Scheduler gives it
# to cmd, for being a console program with an InteractiveToken.
#
# So the launcher must not be a console program at all. wscript.exe is GUI-subsystem, so
# the task creates no console for it; the VBScript then starts the .cmd with an explicit
# show-command, and THAT is what decides whether a window appears. Hidden=0, minimised
# without stealing focus=7, normal=1. Redirection still works because cmd still performs
# it - only its window is suppressed.
#
# ALSO MEASURED, and it invalidated the other half of the first attempt: Windows Terminal
# 1.18.10301.0 IS installed here (WindowsTerminal.exe and OpenConsole.exe -Embedding are
# both running in session 1). An earlier `where wt.exe` said otherwise, but that probe ran
# over ssh in session 0 where the app-execution alias does not resolve - a false negative,
# not an absent terminal. Hence a show-command passed at creation rather than `start /min`,
# whose handling depends on which terminal is hosting.
#
# A window cannot be observed from here: session 0 has its own window station, so
# MainWindowTitle comes back empty for everything in session 1. Whether this looks right
# is a question only someone at the VNC screen can answer.
function Set-McpWindow([string]$StartCmd, [string]$Mode, [string]$Title) {
    if (-not (Test-Path $StartCmd)) {
        Write-Host "  no $StartCmd - leaving the window alone"
        return
    }
    $txt = Get-Content $StartCmd -Raw

    if ($Mode -ne 'Hidden' -and $txt -notmatch '(?m)^title ') {
        # Injected once, straight after @echo off. colour 1F is bright white ON BLUE:
        # distinctive enough to recognise at a glance in a VNC window, and nothing else
        # on this desktop is blue.
        $txt = $txt -replace '(?m)^@echo off\r?\n', "@echo off`r`ntitle $Title`r`ncolor 1F`r`n"
        Set-Content $StartCmd $txt -Encoding ASCII
        Write-Host "  window      titled '$Title', blue"
    } else {
        Write-Host '  window      already titled'
    }

    # The show-command the VBScript passes to WScript.Shell.Run. These are the documented
    # SW_* values: 0 hides, 7 minimises without taking focus, 1 shows normally.
    $show = @{ 'Hidden' = 0; 'Minimized' = 7; 'Normal' = 1 }[$Mode]
    $vbs = Join-Path (Split-Path $StartCmd -Parent) 'run-server.vbs'
    # Rewritten every run rather than created once, so that changing -McpWindow actually
    # changes something on a guest that already has the file.
    @(
        "' Generated by Draugr's lib/forge/guest/install-automation.ps1 - do not edit.",
        "' wscript.exe is GUI-subsystem, so Task Scheduler gives this no console; the",
        "' show-command below decides whether the server's own console is visible.",
        "CreateObject(""WScript.Shell"").Run """"""$StartCmd"""""", $show, False"
    ) | Set-Content $vbs -Encoding ASCII

    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
    # Cosmetic, so a failure here warns rather than taking the provisioning run with it.
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
# Add-ToMachinePath - put a directory on the MACHINE PATH, once, JUST BEFORE System32.
#
# Not appended and not prepended: positioned. MSYS2 ships find.exe and sort.exe that
# shadow the Windows ones, which is the POINT - the GNU versions are what anyone wants -
# and link.exe, which shadows MSVC's linker and is the one that could hurt.
#
# MEASURED, which is why prepending is safe: with C:\msys64\usr\bin placed
# FIRST and then vcvars64.bat run, `where link` answers
#   C:\...\MSVC\14.38.33130\bin\Hostx64\x64\link.exe      <- MSVC, first
#   C:\msys64\usr\bin\link.exe
# because vcvars PREPENDS the toolchain directory itself. UnrealBuildTool is safe either
# way: it resolves the toolchain by absolute path. The residual case is a bare `link`
# outside a developer prompt, where nothing should expect MSVC anyway.
#
# BUT NOT AT THE VERY FRONT, because MSYS2 also ships ssh.exe, scp.exe and ssh-keygen.exe.
# MEASURED: prepending made `ssh` resolve to C:\msys64\usr\bin\ssh.exe instead
# of the Windows OpenSSH client, and MSYS2's client reads key paths, HOME and known_hosts
# with POSIX semantics. Everything else in this project - the host tunnel, the guest's own
# sshd, every script here - is Windows OpenSSH, and one ssh behaving differently from the
# others inside the guest is a trap laid for later.
#
# So: insert immediately BEFORE the System32 entry. MSYS2 still outranks Windows for find
# and sort, and anything deliberately placed ahead of System32 - which is where the
# OpenSSH directory sits - keeps winning. If System32 is not on PATH at all, something is
# already very wrong, and prepending is the harmless fallback.
#
# Windows composes PATH as MACHINE then USER, so anything added here also precedes the
# per-user entries - including %USERPROFILE%\.local\bin. MSYS2 ships no python.exe, so it
# cannot shadow the interpreter install-automation.ps1 puts there.
#
# IDENTICAL TO THE COPY IN install-base-tools.ps1, DELIBERATELY. Every guest script here
# is copied into the guest alone and run alone, so a shared helper file would make "copy
# one file, run it" false - and this one is needed by both. Change one, change both.
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
    # --- uv: a Python for one program, without a system-wide Python -------------------
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
    # uv installs interpreters under %APPDATA%\uv\python and, by default, leaves NO entry
    # point anywhere on PATH. `uv run python` works; `python` does not - and on a stock
    # Windows 11 `python` is not absent but WORSE than absent: it resolves to the Microsoft
    # Store app-execution-alias stub in %LOCALAPPDATA%\Microsoft\WindowsApps, which on a
    # guest with no Store answers "Python was not found; run without arguments to install
    # from the Microsoft Store". That reads as a broken Python rather than as no Python.
    #
    # --default writes real python.exe / python3.exe shims into uv's bin directory, which
    # is %USERPROFILE%\.local\bin - already ahead of WindowsApps on the user PATH, so the
    # stub stops winning. MEASURED: `python -V` -> Python 3.14.8, with
    # sys.executable pointing into %APPDATA%\uv\python. It cost 46 ms, because the
    # interpreter was already on disk; only the entry point was missing.
    #
    # EXPERIMENTAL, and said out loud because it is load-bearing: uv warns that --default
    # "may change without warning". --preview-features silences the warning without
    # changing the behaviour. If a future uv drops the flag, the fallback is a shim that
    # calls `uv run python`, which is uglier but stable.
    #
    # RE-RUN SAFETY, and it is two separate problems. (1) On a guest that already has it,
    # uv writes "Python is already installed. Use `uv python install <request>` to install
    # another version." to STDERR - which is uv reporting NOTHING TO DO. With
    # $ErrorActionPreference = 'Stop' above and the 2>&1 this call needs to log uv's
    # output, PowerShell 5.1 turns that line into a terminating NativeCommandError and the
    # whole provisioning run dies at this phase, before cleanup and the manifest.
    # MEASURED on the second run of an already-complete guest. (2) Even guarded,
    # shelling out to be told there is nothing to do is not idempotence, so the question is
    # asked here first and cheaply.
    #
    # THE QUESTION IS THE VERSION, NOT THE SHIM'S PRESENCE, and that changed when the pin
    # above arrived. "A python.exe is there" was the honest test while any python would do;
    # once one version is required, presence is a test that passes on the wrong interpreter.
    # This guest is the proof: the run that failed left a 3.15.2 shim behind, so a presence
    # test would have let the re-run keep exactly the interpreter it was meant to replace.
    #
    # -V and a regex, not `-c 'import sys; ...'`: an argument carrying embedded quotes is
    # the one thing not to hand through PowerShell to a native exe. docs/FORGE.md.
    $pyShim = Join-Path $uvBin 'python.exe'
    $shimVer = ''
    if (Test-Path $pyShim) {
        if ("$(& $pyShim -V)" -match '(\d+\.\d+)') { $shimVer = $Matches[1] }
    }
    if ($shimVer -eq $PythonVersion) {
        Write-Host "python $shimVer already reachable: $pyShim"
    } else {
        if ($shimVer) {
            Write-Host "python $shimVer is reachable, but $PythonVersion is the pin - installing that"
        } else {
            Write-Host 'making python reachable as `python`...'
        }
        $eapWas = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $uv python install $PythonVersion --default --preview-features python-install-default 2>&1 |
                ForEach-Object { Write-Host "  $_" }
        } finally { $ErrorActionPreference = $eapWas }
        # The shim is the thing this block exists to produce, so its absence IS a failure -
        # unlike uv's chatter, which is not. The VERSION is checked for the same reason: a
        # shim pointing at the wrong interpreter is what this block was just asked to fix,
        # and "it exists" would report success on the state that got us here.
        if (-not (Test-Path $pyShim)) { throw "uv did not create $pyShim" }
        $after = ''
        if ("$(& $pyShim -V)" -match '(\d+\.\d+)') { $after = $Matches[1] }
        if ($after -ne $PythonVersion) {
            throw "$pyShim reports '$after', not the pinned $PythonVersion"
        }
    }

    # uv and windows-mcp both write UTF-8 to stdout, and PowerShell decodes a native
    # program's output with [Console]::OutputEncoding - which on this guest is codepage
    # 1252, because install-guest-base sets it. An en dash then arrives as a stray
    # accented letter: "Scheduled task installed ù server is starting now." MEASURED
    #. Nothing is broken by it, but a provisioning log that renders its own
    # tools' output as rubbish is one more thing a reader has to learn to ignore.
    #
    # Not restored afterwards, deliberately: this is a console attribute of THIS
    # process, which exits at the end of the script. The guest's own codepage is a
    # system setting and is untouched.
    [Console]::OutputEncoding = [Text.Encoding]::UTF8

    # --- the MCP server: one tool install, on the pinned interpreter ------------------
    # --python, EXPLICITLY. Without it uv chooses an interpreter for the tool's own venv
    # independently of the shim installed above, and what it chooses is the newest it can
    # find - which is how this phase came to build its dependencies against 3.15 while the
    # file's own comments said 3.14. Naming it keeps the tool's venv and `python` the same
    # vintage, which is also the only way the pin above means anything here.
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
    # Stop any server already running, by its path, BEFORE installing the task. The tool's
    # own `uninstall` prints "Stopped the running server" and leaves it alive (measured
    #), and a surviving server holds append handles on server.log and
    # server.error.log - so the new start-server.cmd cannot open its redirects, cmd exits
    # 1, and nothing is written anywhere saying why. A silent failure with a stale server
    # still answering on the old port is the worst shape this can take.
    # 'python', 'pythonw' - the second because the first attempt at hiding this window
    # left some guests running pythonw.exe, and a probe that misses it leaves the old
    # server alive holding append handles on the logs, which is the silent failure the
    # comment above is about.
    Get-Process python, pythonw -EA SilentlyContinue | Where-Object { $_.Path -like '*\uv\tools\windows-mcp\*' } |
        ForEach-Object { Write-Host "  stopping the running server (pid $($_.Id))"; Stop-Process -Id $_.Id -Force }

    Write-Host 'registering the login task...'
    & $wmcp install --transport streamable-http --host 127.0.0.1 --port $Port --force |
        ForEach-Object { "  $_" }

    # AFTER the install, always - see Set-McpWindow's header. With -McpWindow Minimized or
    # Hidden the task completes as soon as cmd exits, so `schtasks /query` reports Ready
    # rather than Running. That is the expected shape, not a regression: the server is
    # detached by then, and the verification below asks the PORT, which is the only
    # answer that was ever worth having.
    Set-McpWindow -StartCmd "$env:USERPROFILE\.windows-mcp\start-server.cmd" `
                  -Mode $McpWindow -Title 'Draugr - UIA MCP server (leave running)'

    # --- AutoHotkey v2 from the zip: no installer, no elevation, no file association --
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

    # The whole point of AutoHotkey here is running a .ahk from the command line, so a
    # directory nothing can find makes it ornamental. MEASURED: AutoHotkey64
    # did not resolve as a command on a finished base image.
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

# The task's own state says little - it launches a detached server and goes back to
# "Ready" - so it is reported, not judged. The listener below is the real test.
# Get-ScheduledTask, NOT `schtasks /query ... 2>$null`. With Stop in force a redirected
# native stderr line is a terminating error, and schtasks writes one for a task that is not
# there - so this verification would have thrown on precisely the guest it exists to report
# on. The same defect killed install-shot.ps1 outright; here it was simply never reached,
# because the install above it failed first. This file already carried the explanation, two
# hundred lines up, next to the one call it had guarded. MEASURED. docs/FORGE.md.
$state = Get-ScheduledTask -TaskName 'windows-mcp-server' -ErrorAction SilentlyContinue
if ($state) {
    Write-Host "  task        registered (state: $($state.State))"
} else {
    Write-Host '  task        MISSING' -ForegroundColor Red; $bad += 'task'
}

# The listener must be in session 1. Started in session 0 the server runs, answers, and
# sees nothing - the exact failure this design exists to avoid, and it is silent.
#
# Wait for it: the server takes about 4 s to bind after the task starts (measured), so
# checking immediately after `install` reports a failure that is only impatience.
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
        Write-Host "  listener    127.0.0.1:$Port in SESSION $sess - UIA will be blind" -ForegroundColor Red
        $bad += 'session'
    }
} else {
    Write-Host "  listener    NOTHING ON $Port" -ForegroundColor Red; $bad += 'listener'
}

# An unauthenticated request must be refused: with the forward in place, the token is
# what stands between the desktop and anything else that can reach the port.
try {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/mcp" `
         -ContentType 'application/json' -Body '{}' -TimeoutSec 10
    Write-Host "  no-token    ANSWERED $($r.StatusCode) - the server is not asking for a token" -ForegroundColor Red
    $bad += 'auth'
} catch {
    $code = [int]$_.Exception.Response.StatusCode
    if ($code -eq 401) { Write-Host '  no-token    401, as it should be' }
    else { Write-Host "  no-token    $code (expected 401)" -ForegroundColor Yellow }
}

$exe = Join-Path $AhkDir 'AutoHotkey64.exe'
if (Test-Path $exe) {
    Write-Host "  autohotkey  $((Get-Item $exe).VersionInfo.ProductVersion)  ($AhkDir)"
} else {
    Write-Host '  autohotkey  MISSING' -ForegroundColor Red; $bad += 'autohotkey'
}

# REPORTED, NOT JUDGED. A PATH change reaches new processes only, so this session can
# legitimately disagree with the machine - failing the run over that would be wrong.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'
$ahkOnPath = $machinePath | Where-Object { $_.TrimEnd('') -ieq $AhkDir.TrimEnd('') }
Write-Host ("  PATH        AutoHotkey {0}" -f $(if ($ahkOnPath) { 'on the machine PATH' }
                                                else { 'NOT on the machine PATH' }))
$pyExe = Join-Path $uvBin 'python.exe'
if (Test-Path $pyExe) {
    # NO 2>&1 HERE. Under Stop a redirected native stderr line is terminating, so a broken
    # interpreter would have thrown inside the very block whose job is to report that it is
    # broken. Unredirected, python's own complaint reaches the console and the verification
    # carries on - which is what a verification is for. tests/lint-native-stderr.sh.
    #
    # AND THE VERSION IS JUDGED, not just printed: the pin is why this phase installs at all
    # (see -PythonVersion), so an interpreter that is not the pinned one is a finding and not
    # a detail. A guest left over from a failed run is exactly where this shows up.
    $pyV = "$(& $pyExe -V)"
    $pyMinor = ''
    if ($pyV -match '(\d+\.\d+)') { $pyMinor = $Matches[1] }
    if ($pyMinor -eq $PythonVersion) {
        Write-Host "  python      $pyV  ($pyExe)"
    } else {
        Write-Host "  python      $pyV  ($pyExe) - NOT the pinned $PythonVersion" -ForegroundColor Red
        $bad += 'python version'
    }
} else {
    Write-Host '  python      no python.exe in uv bin - bare `python` hits the Store stub' -ForegroundColor Yellow
}

Write-Host ("  footprint   uv {0} MB, python {1} MB, venv {2} MB, ahk {3} MB, cache {4} MB" -f `
    (Get-Mb $uvBin), (Get-Mb "$env:APPDATA\uv\python"), (Get-Mb "$env:APPDATA\uv\tools"),
    (Get-Mb $AhkDir), (Get-Mb "$env:LOCALAPPDATA\uv\cache"))

Write-Host ''
if ($ShowKey -and (Test-Path $cfg)) {
    Get-Content $cfg | Where-Object { $_ -match 'auth_key' } | ForEach-Object { "  $_" }
} else {
    Write-Host "The bearer token is in $cfg (-ShowKey prints it). It belongs to this"
    Write-Host 'guest; do not copy it into the repository.'
}
if ($bad.Count) { Write-Host "FAILED: $($bad -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'automation ready.' -ForegroundColor Green
