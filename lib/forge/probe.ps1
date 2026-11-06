# probe.ps1 - report the forge's liveness chain, one fact per line, changing nothing.
#
# ==> RUN BY bin/dr-forge, ON THE WINDOWS SIDE. Not meant to be typed. <==
#
# WHY THERE IS A POWERSHELL FILE IN A BASH PROJECT AT ALL. dr-forge runs in WSL, and from
# there AppSandbox is unreachable: its API binds the WINDOWS loopback, and inside WSL2
# 127.0.0.1 is WSL's own. MEASURED - host.json is readable over /mnt/c, so the
# token and port are in hand, and neither 127.0.0.1:8787 nor the Windows host IP
# (172.19.192.1) accepts a connection. Only a process on the Windows side can dial it, and
# `powershell.exe` is reachable from WSL. The guest's ssh relay port is on the same loopback,
# so guest commands have to cross the same way.
#
# WHY A FILE RATHER THAN powershell.exe -Command "...". A command string from bash crosses
# four parsers - bash, WSL's argv translation, PowerShell's own, and whatever the guest runs -
# and every quote and backslash loses a layer somewhere. draugr-gateway learned this the
# expensive way and settled on -File for exactly this reason. So: a file, and key=value out.
#
# OUTPUT IS key=value, one per line, for `read` on the bash side. Values never contain a
# newline; a missing fact is an absent line rather than an empty one, so bash can tell "not
# checked" from "checked and empty".
#
# EVERY LINK IS CHECKED BY ITS EFFECT, NOT BY ITS EXISTENCE. That rule is the whole point of
# this file (docs/FORGE.md, learned): a tunnel supervisor process running is not a
# forward working, and a forward open on the host is not anything answering inside the guest.
# Every link looked healthy except the one that mattered, and the symptom
# surfaced three links away as Unreal reporting no internet. So the proxy is checked by
# asking THE GUEST whether it can fetch a page, and nothing here trusts a process list.
#
# IT IS READ-ONLY, deliberately and completely. It starts nothing, stops nothing, and writes
# nothing - so it is safe to run while a layer is being built, which is when you most want to
# look. -Deep adds the two checks that reach into the guest over ssh; without it the probe
# stays on the host side and takes about a second.
param(
    [Parameter(Position = 0)][string]$Vm = '',
    [switch]$Deep,
    [string]$AdminKey = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [int]$TimeoutSec = 15
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# One writer, so a value with an "=" in it cannot be mistaken for two fields: everything
# after the first "=" is the value, and the bash side splits on the first one only.
function Emit([string]$k, $v) { Write-Output ("{0}={1}" -f $k, ($v -replace '[\r\n]+', ' ')) }

Emit 'vm' $Vm

# --- link 1: the AppSandbox daemon -------------------------------------------------------
# By effect: a host.json with nothing behind it means the last daemon DIED rather than
# exited, and the file alone would report a healthy daemon that is not there.
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
$daemon = $null
if (Test-Path $hostJson) {
    try {
        $h = Get-Content $hostJson -Raw | ConvertFrom-Json
        $v = Invoke-RestMethod -Uri "$($h.endpoint)/v1/version" -TimeoutSec 5 `
                -Headers @{ Authorization = "Bearer $($h.token)" }
        $daemon = $h
        Emit 'daemon' 'up'
        Emit 'daemon_version' "$($v.product) $($v.version)"
        Emit 'daemon_endpoint' $h.endpoint
    } catch {
        Emit 'daemon' 'stale'   # the file is there, the socket is not
    }
} else {
    Emit 'daemon' 'down'
}

function Asb([string]$Path) {
    Invoke-RestMethod -Uri "$($daemon.endpoint)/v1$Path" -TimeoutSec $TimeoutSec `
        -Headers @{ Authorization = "Bearer $($daemon.token)" }
}

# --- link 2: the VM ----------------------------------------------------------------------
# agentOnline is AppSandbox's own guest agent. It is reported because it is the only thing
# that says the guest has finished booting - but it says NOTHING about sshd, which is why
# link 3 exists separately.
$st = $null
if ($daemon -and $Vm) {
    # THE LIST COMES FIRST, and that order is the whole point of it. Asked afterwards it only
    # named the alternatives in a refusal; asked here it also tells "there is no such VM"
    # apart from "the daemon would not answer", which are different faults with different
    # fixes. MEASURED, straight after the first real `dr-layer adopt`: the VM the
    # config named had just become a layer, and status reported it as "unknown".
    $known = $null
    try { $known = @((Asb '/vms').vms | ForEach-Object { $_.name }) } catch { }
    if ($null -ne $known) { Emit 'vms_known' ($known -join ' ') }
    try {
        $st = Asb "/vms/$Vm"
        Emit 'vm_state' $st.state
        Emit 'vm_running' $(if ($st.running) { 'yes' } else { 'no' })
        Emit 'vm_agent' $(if ($st.agentOnline) { 'yes' } else { 'no' })
        Emit 'vm_gpu' $st.gpuMode
        Emit 'vm_network' $st.networkMode
    } catch {
        # NOT REGISTERED IS NOT THE SAME FACT AS "cannot tell". `adopt` and `drop` remove a
        # VM block, so a name that worked an hour ago can simply stop existing - and
        # "unknown" reads as a daemon that would not answer, which sends the reader to look
        # at the daemon. Only claimed when the daemon DID answer the list and this name was
        # not in it; a list that could not be read leaves the old word standing.
        if (($null -ne $known) -and ($known -notcontains $Vm)) { Emit 'vm_state' 'unregistered' }
        else { Emit 'vm_state' 'unknown' }
    }
}

# --- link 3: ssh into the guest ----------------------------------------------------------
# THE PORT IS RE-READ AND NEVER CACHED. MEASURED, twice in one day: vms.cfg said
# 57351 while the guest was on 54501, and the API itself answered 57351 the moment
# agentOnline went true and 57589 a few minutes later. sshState is 2 in both cases, so no
# field tells you a port is final. A command coming back is the only proof.
$sshPort = 0
if ($daemon -and $Vm -and $st -and $st.running) {
    try {
        $si = Asb "/vms/$Vm/sshInfo"
        if ($si.port) { $sshPort = [int]$si.port; Emit 'ssh_port' $sshPort }
        if ($si.user) { Emit 'ssh_user' $si.user }
        $listening = [bool](Get-NetTCPConnection -LocalPort $sshPort -State Listen -EA SilentlyContinue)
        Emit 'ssh_listening' $(if ($listening) { 'yes' } else { 'no' })
    } catch { }
}

# --- links 4 and 5: the mound's ports ----------------------------------------------------
# WHO BINDS WHAT, because conflating them sends you to the wrong place to look:
#   18888         published by the MOUND. Down = the gateway is not running.
#   18445         published by the mound TOO, but only by a gateway that serves a vault -
#                 so down has two readings, and dr-forge doctor judges link 6 on 18888
#                 alone for that reason. A gateway generated with no --vault does not
#                 publish it at all (lib/forge/common.sh says why it must not).
#   18765, 18000  bound by the tunnel supervisor's -L. Down = the supervisor is not.
# The supervisor's -R forwards live INSIDE the guest and cannot be seen from here at all,
# which is what makes the guest-side proxy check below the only real test of the tunnel.
foreach ($p in 18888, 18445, 18765, 18000) {
    $up = [bool](Get-NetTCPConnection -LocalPort $p -State Listen -EA SilentlyContinue)
    Emit "port_$p" $(if ($up) { 'up' } else { 'down' })
}

# The supervisor is pinned to ONE VM at registration and never re-reads it, so one left over
# from a previous layer holds the ports this one needs while logging "waiting for the VM"
# for ever. Reporting which VM it names is how that becomes a five-second diagnosis.
$task = Get-ScheduledTask -TaskName 'Draugr forge tunnel' -EA SilentlyContinue
if ($task) {
    $arg = ($task.Actions | Select-Object -First 1).Arguments
    Emit 'tunnel_task' $task.State
    if ($arg -match '-Vm\s+(\S+)') { Emit 'tunnel_vm' $Matches[1] }
} else {
    Emit 'tunnel_task' 'absent'
}

# THE TASK'S PIN IS A REGISTRATION, NOT A RUNNING SUPERVISOR, and conflating the two reported
# a working forge as broken. MEASURED: the task was registered -Vm layer-2-ue426
# while the live supervisor served ue-427-test, held both forwards, and the guest's egress
# worked. Reporting only the task was an EXISTENCE check presented as an effect check - the
# one thing the header of this file forbids. So the forward is traced back to whoever holds
# it: ssh.exe owns the listener, and its PARENT is the supervisor that knows which VM it
# serves.
# THE CLAIM IS EMITTED WHETHER OR NOT ANYTHING HOLDS A PORT, and that is the gap this had:
# every fact below is gated on a port holder, so a supervisor BETWEEN RECONNECTS - which holds
# none - was reported as nothing at all, and `dr-forge doctor` said "no way out" for a forge
# that was merely waiting. Found. docs/FORGE.md.
#
# It is a separate fact from fwd_vm on purpose: fwd_vm answers "who carries", sup_vm answers
# "who claims". Conflating them is what made a wait look like a break.
$supClaim = Join-Path $env:LOCALAPPDATA 'Draugr\forge-tunnel.claim'
if (Test-Path $supClaim) {
    $scl = @(Get-Content $supClaim -ErrorAction SilentlyContinue)
    if ($scl.Count -ge 2) {
        $scPid = 0
        if ([int]::TryParse($scl[0].Trim(), [ref]$scPid)) {
            # A recycled pid would read as a live supervisor, so the process has to be a
            # PowerShell as well as present - the same guard tunnel.ps1's own reader uses.
            $scp = Get-Process -Id $scPid -ErrorAction SilentlyContinue
            if ($scp -and @('powershell', 'pwsh') -contains $scp.ProcessName) {
                Emit 'sup_pid' $scPid
                Emit 'sup_vm' $scl[1].Trim()
            }
        }
    }
}

$fwd = Get-NetTCPConnection -LocalPort 18765 -State Listen -EA SilentlyContinue | Select-Object -First 1
if ($fwd) {
    Emit 'fwd_pid' $fwd.OwningProcess
    $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($fwd.OwningProcess)" -EA SilentlyContinue
    if ($owner) {
        Emit 'fwd_proc' $owner.Name
        $sup = Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.ParentProcessId)" -EA SilentlyContinue
        # An unreadable command line is reported as such and never as a match: a process this
        # query cannot read is not evidence that THIS VM is served. It is also the normal case
        # for the logon task's supervisor, which runs in session 0 - see tunnel_mutex below.
        if ($sup -and $sup.CommandLine -match '-Vm\s+"?([^\s"]+)') { Emit 'fwd_vm' $Matches[1] }
        elseif ($sup) {
            # THE CLAIM FILE ANSWERS WHAT THE COMMAND LINE CANNOT. A supervisor started by the
            # logon task runs in SESSION 0, and Win32_Process hands an interactive session an
            # empty CommandLine for it. MEASURED: after a reboot this reported
            # "serving unreadable" about a tunnel that links 8, 9 and 10 simultaneously proved
            # was carrying for this very VM - a working forge called broken, which is the one
            # thing this file exists to avoid.
            #
            # vm-tunnel.ps1 writes pid and VM beside its log for exactly this gap. It is trusted
            # only when its pid IS the process holding the forward: a claim left by a supervisor
            # that has since died says nothing about who holds it now.
            $claim = Join-Path $env:LOCALAPPDATA 'Draugr\forge-tunnel.claim'
            $named = ''
            if (Test-Path $claim) {
                $cl = @(Get-Content $claim -ErrorAction SilentlyContinue)
                if ($cl.Count -ge 2 -and ([int]($cl[0].Trim())) -eq $sup.ProcessId) { $named = $cl[1].Trim() }
            }
            if ($named) { Emit 'fwd_vm' $named; Emit 'fwd_vm_from' 'claim' }
            else { Emit 'fwd_vm' 'unreadable' }
        }
    }
}

# IS A SECOND SUPERVISOR RUNNING? vm-tunnel.ps1 guards against that with a Global mutex, and
# MEASURED the guard does not hold across sessions: opening
# 'Global\Draugr.forge.tunnel' from an interactive session answers "Access to the path is
# denied" while the logon task's supervisor, which created it in session 0, is alive. A
# token's default DACL grants its own LOGON SID, and logon SIDs are per-session, so the same
# user cannot open the object from another session. vm-tunnel.ps1 reads that denial as "guard
# unavailable" and runs anyway, after which two supervisors share the forwards by
# SO_REUSEADDR and take turns answering.
#
# THE DENIAL IS THE USEFUL PART. A mutex exists only while a handle is held, so being refused
# is POSITIVE evidence of a second supervisor rather than a check that failed. Opening creates
# nothing and ownership is never taken, so this stays read-only like the rest of the file.
try {
    $m = [Threading.Mutex]::OpenExisting('Global\Draugr.forge.tunnel')
    $m.Dispose()
    Emit 'tunnel_mutex' 'visible'
} catch {
    # A .NET static that throws arrives WRAPPED in a MethodInvocationException, so the real
    # type is the inner one and `catch [UnauthorizedAccessException]` would not fire here.
    $e = $_.Exception
    if ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [UnauthorizedAccessException]) { Emit 'tunnel_mutex' 'other-session' }
    else { Emit 'tunnel_mutex' 'absent' }
}

# --- the deep checks: inside the guest ---------------------------------------------------
# Skipped unless asked, because they cost an ssh round trip each and the host-side picture is
# usually enough to see what is wrong.
if ($Deep -and $sshPort -and (Test-Path $AdminKey)) {
    $user = if ($si -and $si.user) { $si.user } else { 'forge' }
    $sshArgs = @('-n', '-i', $AdminKey, '-p', $sshPort, '-o', 'IdentitiesOnly=yes',
                 '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
                 # The alias is why this file's own note about the relay port moving no longer
                 # has to be an excuse: the key is kept against the VM. docs/FORGE.md.
                 '-o', "HostKeyAlias=draugr-$Vm",
                 '-o', "ConnectTimeout=$TimeoutSec", "$user@127.0.0.1")

    # EAP guard: under 'Stop' a native command's stderr redirected by 2>&1 arrives as a
    # terminating ErrorRecord, so one informational line from ssh would end this probe.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # link 3, by effect: a command that RUNS. sshd listens seconds before it can run
        # anything, so a connect-only test would pass against a guest that refuses work.
        $out = & ssh.exe @sshArgs 'cmd /c echo DRAUGR_OK' 2>&1
        Emit 'ssh_exec' $(if (($out -join ' ') -match 'DRAUGR_OK') { 'yes' } else { 'no' })
        if (($out -join ' ') -notmatch 'DRAUGR_OK') { Emit 'ssh_error' (($out | Select-Object -Last 1) -join ' ') }

        # link 4, by effect, and this is the one that matters: ask THE GUEST whether the
        # proxy answers. A forward open on the host proves nothing about the far end - the
        # failure in one line.
        if (($out -join ' ') -match 'DRAUGR_OK') {
            # @' '@ is LITERAL: every $ below belongs to the GUEST's PowerShell, and an
            # interpolating here-string would expand them here instead.
            $guestPs = @'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
# Reported on the connection that is already open, rather than costing a round trip of its own.
# Every VM built on the layer stack inherits the base image's computer name, so this is how a
# guest comes to call itself layer-0 while vms.cfg calls it something else - invisible from
# inside the guest, and the sort of thing that only bites once there are several VMs.
"DRAUGR_NAME=$env:COMPUTERNAME"
try {
    $r = Invoke-WebRequest -Uri 'https://www.unrealengine.com/' -Proxy 'http://127.0.0.1:3128' `
             -UseBasicParsing -TimeoutSec 20
    "DRAUGR_CODE=$([int]$r.StatusCode)"
} catch {
    # 4xx and 5xx arrive as exceptions. The code is still the answer we want - 403 means the
    # request REACHED the site - so it is read off the response. No response at all is the
    # only real failure, and that is 000.
    $resp = $_.Exception.Response
    if ($resp) { "DRAUGR_CODE=$([int]$resp.StatusCode)" } else { "DRAUGR_CODE=000" }
}
'@
            $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guestPs))
            $reply = & ssh.exe @sshArgs "powershell -NoProfile -EncodedCommand $b64" 2>&1
            # Matched by its tag, not by position, for the CLIXML reason in the header note.
            $code = ''
            foreach ($l in @($reply)) {
                if ("$l" -match 'DRAUGR_CODE=(\d+)') { $code = $Matches[1] }
                if ("$l" -match 'DRAUGR_NAME=(\S+)') { Emit 'guest_name' $Matches[1] }
            }
            Emit 'guest_proxy_code' $(if ($code) { $code } else { '000' })
            # 000 = nothing answered at all (no tunnel, or no tinyproxy behind it).
            # 500 = tinyproxy answered and refused: the gateway is up, its policy said no.
            # anything else, 403 included, means the request reached the site.
            Emit 'guest_egress' $(if ($code -eq '000' -or $code -eq '500' -or -not $code) { 'no' } else { 'yes' })
            # 403 is a PASS and that is not a typo: it means the request reached the site.
            # Only 000 (nothing answered) and 500 (tinyproxy refused) are failures.
        }
    } finally { $ErrorActionPreference = $old }
}
