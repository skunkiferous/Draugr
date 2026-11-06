# tunnel.ps1 - hold the SSH tunnel that gives the forge VM its only way out.
#
# ==> STARTED BY lib/forge/vm.ps1 -Mode tunnel, ON THE WINDOWS SIDE. Long-lived. <==
#
# WHY THIS LIVES IN DRAUGR. `dr-forge up` starts the mound, the VM and this tunnel, so this is
# code `up` REQUIRES - and anything dr-forge requires belongs in this repository. It was
# previously read out of the gateway project, which made Draugr depend on a file it does not
# ship: a gateway checked out somewhere else, or renamed, broke `up` with a message about
# someone else's directory layout. Only the AppSandbox daemon is left on the far side of that
# line, because starting it needs elevation.
#
# WHAT IT FORWARDS, and why each one:
#
#   -R guest 3128 -> host 18888   the guest's proxy. Its proxy settings point at its own
#                                 127.0.0.1:3128, and the far end is the gateway mound's
#                                 published port. This is the VM's ONLY way out.
#   -R guest 445  -> host 18445   the vault, read-only. It has to be 445 in the guest: that is
#                                 the only port the Windows SMB client will dial, which is why
#                                 the guest's own LanmanServer is disabled.
#   -L host 18765 -> guest 8765   the UIA MCP server, for driving the guest's UI.
#   -L host 18000 -> guest 8000   UE's in-editor MCP plugin, when an editor is running. It
#                                 costs nothing while none is: -L dials the target only when
#                                 something connects to the local port.
#   -L host 18022 -> guest 22     THE MOVING PORT, PINNED. The guest's own sshd, so Draugr's
#                                 ordinary git and data commands can reach the VM - the code
#                                 and the data live in the VM, not in a mound.
#
# THE RELAY PORT MOVES, and 18022 is the answer to it. Measured twice: vms.cfg
# said 57351 while the guest was on 54501, and the API answered 57351 then 57589 minutes apart.
# A port like that cannot appear in an sbx policy rule without going stale. This loop re-reads
# it on every reconnect, which makes it the one place that can hold a port still: 18022 never
# changes, so the gateway mound needs exactly one rule, `localhost:18022`, for ever. See
# docs/FORGE.md, "The channel".
#
# THE PORT COMES FROM THE DAEMON, NOT FROM vms.cfg. The gateway's version parsed that file,
# and it is both undocumented and measured wrong - the 54501 case above. sshInfo is the
# authority, and asking it also makes the daemon's absence visible: a logon task can start this
# before AppSandbox is up, and "waiting for the daemon" is the truthful thing to do then rather
# than dialling a port out of a file nobody is serving.
#
# IT IS SILENT, and writes to a log instead. It may run from a logon task with no one watching,
# so console output has nowhere useful to go: before it went to a PowerShell window
# that appeared on the desktop at every boot, filling with "Connection refused" because the VM
# was not started yet. Both halves of that were wrong - the window should not exist, and a VM
# that is merely switched off is not an error.
param(
    [string]$Vm       = '',
    [string]$User     = 'forge',
    [string]$Key      = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519",
    [string]$LogFile  = "$env:LOCALAPPDATA\Draugr\forge-tunnel.log",
    [int]   $MaxLogKb = 512
)

# No [Parameter()] attribute anywhere above, and not for style: one makes this script
# cmdlet-bound, and $PSScriptRoot is then EMPTY while the defaults are evaluated. Validated
# by hand instead - which is also why -Vm is checked rather than declared Mandatory, since a
# Mandatory parameter would PROMPT, and prompting in a logon task hangs for ever.
if (-not $Vm) { [Console]::Error.WriteLine('forge-tunnel: -Vm is required'); exit 2 }

$dir = Split-Path $LogFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

function Write-Log([string]$msg) {
    # Keep one previous log and cap the current one: a reconnect loop left running for weeks
    # should not quietly fill a disk that the VM also lives on.
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt ($MaxLogKb * 1KB))) {
        Move-Item $LogFile "$LogFile.1" -Force
    }
    Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg)
}

# The daemon, re-read every time: if AppSandbox restarts, its endpoint and bearer token both
# change, and a supervisor holding the old pair would wait for ever on a door that moved.
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

# Is anything actually listening? The port number alone says nothing - sshInfo reports one for
# a VM that is merely registered. Dialling first and reading the error afterwards is what
# produced a screenful of refusals; asking first costs one connect() and keeps a stopped VM
# quiet.
function Test-Listening([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        if (-not $c.ConnectAsync('127.0.0.1', $Port).Wait(1500)) { return $false }
        return $c.Connected
    } catch { return $false } finally { $c.Dispose() }
}

# One supervisor at a time. Two are easy to end up with - a retry loop on a 10 s timer races
# anything that restarts it - and Windows does not complain: ssh sets SO_REUSEADDR, so a
# SECOND process binding 127.0.0.1:18000 SUCCEEDS silently and the two take turns answering.
# Measured, with two identical supervisors both holding the same forward.
#
# EVERY FAILURE HERE IS HANDLED EXPLICITLY, because the silent ones are what let two run. This
# script does not set $ErrorActionPreference = 'Stop', so a .NET method that throws inside an
# `if` condition is a NON-terminating error: the `if` is abandoned and execution CONTINUES -
# and continuing here means falling into the loop as though the mutex had been granted.
# MEASURED: pid 15272 logged "supervisor started" while pid 19500 was alive and
# holding, and the two then took turns.
#
# THE MECHANISM IS MEASURED, and it is not an integrity mismatch.: a logon task runs
# its supervisor in SESSION 0, which is where it creates this mutex, and a token's default DACL
# grants its own LOGON SID - which is per-session. So an interactive run of this same script,
# as the same user, is DENIED when it opens the object: "Access to the path
# 'Global\Draugr.forge.tunnel' is denied", verified from session 2 against the live session-0
# supervisor. A catch-all reads that as "no guard available" and runs anyway, which is how two
# supervisors came to hold one forward - the one state this mutex exists to prevent.
#
# TWO HALVES, AND THE SECOND IS NOT OPTIONAL. An explicit DACL granting this user's own SID
# makes the object openable from any session they run in. But then "held by someone else" is a
# plain $false from WaitOne, and standing down on that is WRONG: -Vm is baked in at launch and
# never re-read, so a supervisor for another VM can never come to serve this one, and standing
# down for it leaves the guest with no way out. So the holder has to say WHICH VM it serves,
# and the only channel that crosses sessions is a file: a session-0 process's command line
# reads back empty. Hence the claim file, beside the log, in the LOCALAPPDATA both sessions
# share - which is also why both supervisors have always written one log.
#
# THE NAMES AND PATHS ARE DELIBERATELY UNCHANGED from the gateway's version: the same mutex,
# the same claim file, the same log. lib/forge/probe.ps1 and lib/forge/vm.ps1 both read that
# claim to work out who holds the forward, and a supervisor still running from the old copy has
# to be visible to this one. Renaming any of them would make the two invisible to each other,
# which is precisely the two-supervisor state above.
$ClaimFile = Join-Path $dir 'forge-tunnel.claim'

function Write-Claim {
    # pid first, because a reader has to check the holder is still alive: a supervisor that is
    # killed never gets to delete this.
    try {
        Set-Content -Path $ClaimFile -Encoding ASCII -Force -ErrorAction Stop `
            -Value @("$PID", $Vm, (Get-Date -Format 's'))
    } catch {
        # Not worth failing over - the claim helps the NEXT supervisor, not this one - but say
        # it, or its absence later reads as a holder that never wrote one.
        Write-Log "could not write the claim file ($($_.Exception.GetType().Name)); another supervisor will not learn which VM this one serves"
    }
}

function Read-Claim {
    # $null means "cannot tell": absent, unreadable, malformed, or naming a process that has
    # gone or is not a PowerShell at all. Those are one answer to the caller. The last of them
    # guards against a RECYCLED PID, which would otherwise read as a live holder and could
    # silence the one supervisor this host actually needs.
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
    # The four-argument constructor is the only one that takes a security descriptor, and it
    # applies it ONLY when it creates the object: an existing mutex keeps the DACL it was made
    # with, so one from a supervisor predating this stays unopenable and falls to the
    # UnauthorizedAccessException branch.
    $sec = New-Object Security.AccessControl.MutexSecurity
    $sec.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.AccessControl.MutexRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow)))
    $createdNew = $false
    $mutex = New-Object Threading.Mutex($false, 'Global\Draugr.forge.tunnel', [ref]$createdNew, $sec)
    $held  = $mutex.WaitOne(0)
} catch [Threading.AbandonedMutexException] {
    # The predecessor was killed rather than asked to stop. Ownership HAS passed to us - the
    # exception is raised after the hand-over - so this is a note, not a failure.
    $held = $true
    Write-Log 'the previous supervisor was killed; taking over the forwards'
} catch {
    # THE REAL TYPE IS THE INNER ONE. A .NET constructor that throws arrives wrapped in a
    # MethodInvocationException, so a `catch [UnauthorizedAccessException]` clause above would
    # never fire - which is why an earlier version could only ever report the wrapper's name.
    $e = $_.Exception
    if ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [UnauthorizedAccessException]) {
        # The object EXISTS and this session may not open it, so someone IS holding it: a mutex
        # lives only while a handle is held. That is information, not a failed check. Which VM
        # they serve still has to come from the claim file.
        Write-Log 'the tunnel mutex exists but will not open from this session (it predates the explicit DACL, or was created elevated)'
    } else {
        Write-Log "WARNING single-supervisor guard unavailable ($($e.GetType().Name)); continuing without it"
    }
}

# NOT HOLDING IT IS NOT A REASON TO STAND DOWN; which VM the holder serves is the reason.
if (-not $held) {
    $claim = Read-Claim
    if ($claim -and $claim.Vm -eq $Vm) {
        Write-Log "another supervisor (pid $($claim.ClaimPid)) already serves vm '$Vm'; exiting"
        return
    }
    if ($claim) {
        Write-Log "the holder (pid $($claim.ClaimPid)) serves vm '$($claim.Vm)', not '$Vm', and can never come to serve it - continuing rather than leaving the guest with no way out"
        Write-Log "  both hold forwards now. Only one can own each listener, so end pid $($claim.ClaimPid) if this VM is the one you want served."
    } else {
        Write-Log "the forwards are held by a supervisor that has not said which VM it serves (no usable claim) - continuing; this one wants vm '$Vm'"
    }
}

# Written by WHOEVER REACHES THE LOOP, holder or not, because the claim answers "who serves
# what" rather than "who owns the mutex" - and that is the question the next supervisor has.
Write-Claim

Write-Log "supervisor started (pid $PID, vm '$Vm', user '$User')"
$waiting = ''
while ($true) {
    $port = Get-RelayPort $Vm
    if ($port -and (Test-Listening $port)) {
        $waiting = ''
        Write-Log "connecting to 127.0.0.1:$port"
        # ssh's own output is the only diagnosis there is when a forward is refused, so it goes
        # to the log rather than to a console nobody is looking at. That log is where the
        # "administratively prohibited" came from, which no port check could see.
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
        # Said once per idle SPELL, not once per attempt: a VM switched off overnight would
        # otherwise write 8,640 identical lines before breakfast. The two reasons are told
        # apart, because "no daemon" and "VM switched off" need different things done.
        $why = if ($port) { 'vm' } else { 'daemon' }
        if ($waiting -ne $why) {
            if ($port) { Write-Log 'waiting for the VM (nothing listening on its ssh port)' }
            else { Write-Log 'waiting for the AppSandbox daemon (no host.json, or it answers nothing)' }
            $waiting = $why
        }
    }
    Start-Sleep -Seconds 10
}
