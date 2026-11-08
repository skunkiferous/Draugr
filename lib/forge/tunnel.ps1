# tunnel.ps1: hold the SSH tunnel, the only way out of the forge VM.
#
# ==> lib/forge/vm.ps1 -Mode tunnel STARTS IT, ON THE WINDOWS SIDE. It runs a long time. <==
#
# WHY THIS IS IN DRAUGR. `dr-forge up` starts the mound, the VM, and this
# tunnel. Thus `up` REQUIRES this code, and all that dr-forge requires belongs
# in this repository. Before, it came from the gateway project. Then Draugr
# needed a file that it does not ship. A gateway in another place, or with a new
# name, broke `up` with a message about the directory layout of somebody else.
# Only the AppSandbox daemon stays on the other side of that line, because its
# start needs elevation.
#
# WHAT IT FORWARDS, and why:
#
#   -R guest 3128 -> host 18888   the proxy of the guest. Its proxy configuration points at its
#                                 own 127.0.0.1:3128. The far end is the published port of the
#                                 gateway mound. This is the ONLY way out of the VM.
#   -R guest 445  -> host 18445   the vault, read-only. It must be 445 in the guest, because the
#                                 Windows SMB client connects only to that port. That is why
#                                 the LanmanServer of the guest is disabled.
#   -L host 18765 -> guest 8765   the UIA MCP server, to drive the UI of the guest.
#   -L host 18000 -> guest 8000   the in-editor MCP plugin of UE, while an editor runs. With no
#                                 editor, it costs nothing. -L connects to the target only
#                                 when something connects to the local port.
#   -L host 18022 -> guest 22     THE MOVING PORT, PINNED. The sshd of the guest, so that the
#                                 normal git and data commands of Draugr can reach the VM.
#                                 The code and the data are in the VM, not in a mound.
#
# THE RELAY PORT MOVES, and 18022 is the answer. Two tests showed it. vms.cfg
# said 57351, but the guest was on 54501. The API answered 57351, then 57589
# some minutes later. An sbx policy rule with such a port soon becomes wrong.
# This loop reads it again at each reconnect. Thus it is the one place that can
# hold a port fixed. 18022 never changes, so the gateway mound needs one rule,
# `localhost:18022`, forever. See docs/FORGE.md, "The channel".
#
# THE PORT COMES FROM THE DAEMON, NOT FROM vms.cfg. The version of the gateway
# parsed that file. It has no documentation, and a test showed it was wrong (the
# 54501 case above). sshInfo is the authority. A question to it also shows when
# the daemon is absent. A logon task can start this before AppSandbox runs. Then
# "waiting for the daemon" is the true answer. A port from a file that nobody
# serves is not.
#
# IT IS SILENT, and writes to a log. It can run from a logon task that nobody
# watches, so console output has no useful place. Before, it went to a
# PowerShell window on the desktop at each boot. The window filled with
# "Connection refused", because the VM did not run yet. Both parts were wrong.
# The window must not exist, and a VM that is off is not an error.
param(
    [string]$Vm       = '',
    [string]$User     = 'forge',
    [string]$Key      = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519",
    [string]$LogFile  = "$env:LOCALAPPDATA\Draugr\forge-tunnel.log",
    [int]   $MaxLogKb = 512
)

# No [Parameter()] attribute above, and not for style. One makes this script
# cmdlet-bound, and then $PSScriptRoot is EMPTY while PowerShell evaluates the
# defaults. Thus this script tests the values itself. That is also why -Vm is
# tested and not Mandatory. A Mandatory parameter PROMPTS, and a prompt in a
# logon task hangs forever.
if (-not $Vm) { [Console]::Error.WriteLine('forge-tunnel: -Vm is required'); exit 2 }

$dir = Split-Path $LogFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

function Write-Log([string]$msg) {
    # Keep one previous log, and limit the size of the current one. A reconnect
    # loop that runs for weeks must not silently fill the disk of the VM.
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt ($MaxLogKb * 1KB))) {
        Move-Item $LogFile "$LogFile.1" -Force
    }
    Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg)
}

# The daemon, read again each time. If AppSandbox restarts, its endpoint and
# bearer token both change. A supervisor with the old pair then waits forever at
# a door that moved.
function Get-RelayPort([string]$Name) {
    $hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
    if (-not (Test-Path $hostJson)) { return 0 }
    try {
        $h = Get-Content $hostJson -Raw | ConvertFrom-Json
        $si = Invoke-RestMethod -Uri "$($h.endpoint)/v1/vms/$Name/sshInfo" -TimeoutSec 15 `
                  -Headers @{ Authorization = "Bearer $($h.token)" }
        if ($si.port) { return [int]$si.port }
    } catch { }
    return 0
}

# Does something listen? The port number alone says nothing. sshInfo reports one
# for a VM that is only registered. A connect first, and a read of the error
# after, gave a screen full of refusals. A question first costs one connect(),
# and keeps a stopped VM quiet.
function Test-Listening([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        if (-not $c.ConnectAsync('127.0.0.1', $Port).Wait(1500)) { return $false }
        return $c.Connected
    } catch { return $false } finally { $c.Dispose() }
}

# One supervisor at a time. Two can easily happen. A retry loop on a 10 s timer
# races each thing that restarts it. Windows does not complain. ssh sets
# SO_REUSEADDR, so a SECOND process that binds 127.0.0.1:18000 SUCCEEDS
# silently, and the two answer in turn. A test showed this, with two identical
# supervisors on the same forward.
#
# EACH FAILURE HERE HAS EXPLICIT HANDLING, because the silent ones let two run.
# This script does not set $ErrorActionPreference = 'Stop'. Thus a .NET method
# that throws in an `if` condition is a NON-terminating error. PowerShell leaves
# the `if`, and CONTINUES. Here, that means a fall into the loop as if it got
# the mutex. A TEST SHOWED THIS: pid 15272 logged "supervisor started" while pid
# 19500 was alive and held it. Then the two took turns.
#
# A TEST SHOWED THE MECHANISM, and it is not an integrity mismatch. A logon task
# runs its supervisor in SESSION 0, and creates this mutex there. The default
# DACL of a token grants its own LOGON SID, which is different in each session.
# Thus an interactive run of this script, as the same user, gets DENIED when it
# opens the object: "Access to the path 'Global\Draugr.forge.tunnel' is denied".
# A test from session 2 on the live session-0 supervisor showed this. A
# catch-all reads that as "no guard available", and runs anyway. That is how two
# supervisors held one forward, the one state that this mutex must prevent.
#
# TWO HALVES, AND THE SECOND IS NECESSARY. An explicit DACL that grants the SID
# of this user lets each session of the user open the object. But then "held by
# someone else" is only a $false from WaitOne. To stop on that is WRONG. -Vm is
# fixed at the start and never read again. Thus a supervisor for another VM can
# never serve this one. A stop for it leaves the guest with no way out. Thus the
# holder must say WHICH VM it serves. The only channel across sessions is a
# file, because the command line of a session-0 process reads back empty. Hence
# the claim file, beside the log, in the LOCALAPPDATA that both sessions share.
# That is also why both supervisors always wrote one log.
#
# THE NAMES AND PATHS ARE THE SAME AS IN THE GATEWAY VERSION, on purpose: the
# same mutex, the same claim file, the same log. lib/forge/probe.ps1 and
# lib/forge/vm.ps1 both read that claim to find who holds the forward. This one
# must also see a supervisor that still runs from the old copy. A new name for
# one of them hides the two from each other. That is the two-supervisor state
# above.
$ClaimFile = Join-Path $dir 'forge-tunnel.claim'

function Write-Claim {
    # pid first, because a reader must make sure that the holder is still alive.
    # A supervisor that is killed never deletes this.
    try {
        Set-Content -Path $ClaimFile -Encoding ASCII -Force -ErrorAction Stop `
            -Value @("$PID", $Vm, (Get-Date -Format 's'))
    } catch {
        # Not a reason to fail. The claim helps the NEXT supervisor, not this
        # one. But say it. If not, its absence later looks like a holder that
        # never wrote one.
        Write-Log "could not write the claim file ($($_.Exception.GetType().Name)). Another supervisor cannot learn which VM this one serves"
    }
}

function Read-Claim {
    # $null means "cannot tell": absent, unreadable, malformed, or the name of a
    # process that is gone or is not a PowerShell. For the caller, those are one
    # answer. The last guards against a RECYCLED PID. Without it, that PID looks
    # like a live holder, and can stop the one supervisor that this host needs.
    try {
        if (-not (Test-Path $ClaimFile)) { return $null }
        $l = @(Get-Content $ClaimFile -ErrorAction Stop)
        if ($l.Count -lt 2) { return $null }
        $claimPid = 0
        if (-not [int]::TryParse($l[0].Trim(), [ref]$claimPid)) { return $null }
        $p = Get-Process -Id $claimPid -ErrorAction SilentlyContinue
        if (-not $p -or @('powershell', 'pwsh') -notcontains $p.ProcessName) { return $null }
        return [pscustomobject]@{ ClaimPid = $claimPid; Vm = $l[1].Trim() }
    } catch { return $null }
}

$mutex = $null
$held  = $false
try {
    # Only the four-argument constructor takes a security descriptor. It applies
    # it ONLY when it creates the object. An existing mutex keeps its first
    # DACL. Thus a mutex from a supervisor older than this one stays closed, and
    # goes to the UnauthorizedAccessException branch.
    $sec = New-Object Security.AccessControl.MutexSecurity
    $sec.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.AccessControl.MutexRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow)))
    $createdNew = $false
    $mutex = New-Object Threading.Mutex($false, 'Global\Draugr.forge.tunnel', [ref]$createdNew, $sec)
    $held  = $mutex.WaitOne(0)
} catch [Threading.AbandonedMutexException] {
    # The previous supervisor was killed, not asked to stop. This one HAS the
    # ownership, because the exception comes after the hand-over. Thus this is a
    # note, not a failure.
    $held = $true
    Write-Log 'the previous supervisor was killed. Taking over the forwards'
} catch {
    # THE REAL TYPE IS THE INNER ONE. If a .NET constructor throws, the error
    # comes in a MethodInvocationException. Thus a `catch
    # [UnauthorizedAccessException]` clause above never fires. That is why an
    # earlier version reported only the name of the wrapper.
    $e = $_.Exception
    if ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [UnauthorizedAccessException]) {
        # The object EXISTS, and this session cannot open it, so somebody HOLDS
        # it. A mutex lives only while a process holds a handle. That is
        # information, not a failed test. The VM that they serve must still come
        # from the claim file.
        Write-Log 'the tunnel mutex exists, but this session cannot open it (it is older than the explicit DACL, or was created elevated)'
    } else {
        Write-Log "WARNING the single-supervisor guard is not available ($($e.GetType().Name)). Continuing without it"
    }
}

# NO MUTEX IS NOT A REASON TO STOP. The VM that the holder serves is the reason.
if (-not $held) {
    $claim = Read-Claim
    if ($claim -and $claim.Vm -eq $Vm) {
        Write-Log "another supervisor (pid $($claim.ClaimPid)) already serves vm '$Vm'. Exiting"
        return
    }
    if ($claim) {
        Write-Log "the holder (pid $($claim.ClaimPid)) serves vm '$($claim.Vm)', not '$Vm', and can never serve it. Continuing, so that the guest has a way out"
        Write-Log "  both hold forwards now. Only one can own each listener. If you want this VM served, end pid $($claim.ClaimPid)."
    } else {
        Write-Log "a supervisor holds the forwards, but did not say which VM it serves (no usable claim). Continuing. This one wants vm '$Vm'"
    }
}

# The supervisor that REACHES THE LOOP writes it, holder or not. The claim
# answers "who serves what", not "who owns the mutex". That is the question of
# the next supervisor.
Write-Claim

Write-Log "supervisor started (pid $PID, vm '$Vm', user '$User')"
$waiting = ''
while ($true) {
    $port = Get-RelayPort $Vm
    if ($port -and (Test-Listening $port)) {
        $waiting = ''
        Write-Log "connecting to 127.0.0.1:$port"
        # If a forward is refused, the output of ssh is the only diagnosis. Thus
        # it goes to the log, not to a console that nobody watches. The
        # "administratively prohibited" came from that log. No port test saw it.
        & ssh.exe -N -i $Key -p $port -o IdentitiesOnly=yes -o BatchMode=yes `
            -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
            -o ExitOnForwardFailure=yes `
            -o ServerAliveInterval=15 -o ServerAliveCountMax=3 `
            -R 127.0.0.1:3128:127.0.0.1:18888 `
            -R 127.0.0.1:445:127.0.0.1:18445 `
            -L 127.0.0.1:18765:127.0.0.1:8765 `
            -L 127.0.0.1:18000:127.0.0.1:8000 `
            -L 127.0.0.1:18022:127.0.0.1:22 "$User@127.0.0.1" 2>&1 |
            ForEach-Object { Write-Log "  ssh: $_" }
        Write-Log "ssh exited ($LASTEXITCODE)"
    } else {
        # Said once for each idle PERIOD, not once for each attempt. If not, a
        # VM that is off for the night writes 8,640 identical lines before
        # breakfast. The two reasons are different, because "no daemon" and "VM
        # switched off" need different fixes.
        $why = if ($port) { 'vm' } else { 'daemon' }
        if ($waiting -ne $why) {
            if ($port) { Write-Log 'waiting for the VM (nothing listening on its ssh port)' }
            else { Write-Log 'waiting for the AppSandbox daemon (no host.json, or it answers nothing)' }
            $waiting = $why
        }
    }
    Start-Sleep -Seconds 10
}
