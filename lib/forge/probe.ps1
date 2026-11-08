# probe.ps1: report the liveness chain of the forge, one fact on each line, and
# change nothing.
#
# ==> bin/dr-forge RUNS IT, ON THE WINDOWS SIDE. You do not type it. <==
#
# WHY A POWERSHELL FILE IN A BASH PROJECT. dr-forge runs in WSL, and from there
# it cannot reach AppSandbox. Its API binds the WINDOWS loopback, and inside
# WSL2, 127.0.0.1 is the loopback of WSL. A TEST SHOWED THIS. WSL can read
# host.json through /mnt/c, so it has the token and the port. But neither
# 127.0.0.1:8787 nor the Windows host IP (172.19.192.1) accepts a connection.
# Only a process on the Windows side can connect, and WSL can run
# `powershell.exe`. The ssh relay port of the guest is on the same loopback, so
# guest commands must go the same way.
#
# WHY A FILE, NOT powershell.exe -Command "...". A command string from bash goes
# through four parsers: bash, the argv translation of WSL, the parser of
# PowerShell, and the shell of the guest. Each quote and backslash loses a layer
# somewhere. draugr-gateway learned this at a high cost, and uses -File for
# exactly this reason. Thus: a file, and key=value as output.
#
# THE OUTPUT IS key=value, one on each line, for `read` on the bash side. Values
# never have a newline. A missing fact is a missing line, not an empty one. Thus
# bash knows the difference between "not tested" and "tested and empty".
#
# EACH LINK IS TESTED BY ITS EFFECT, NOT BY ITS EXISTENCE. That rule is the
# purpose of this file (docs/FORGE.md). A running tunnel supervisor process is
# not a working forward. A forward open on the host does not mean that something
# answers inside the guest. Once, each link looked healthy except the important
# one, and the symptom was three links away: Unreal reported no internet. Thus
# the code tests the proxy with a question to THE GUEST, whether it can fetch a
# page. Nothing here trusts a process list.
#
# IT IS READ-ONLY, completely, on purpose. It starts nothing, stops nothing, and
# writes nothing. Thus it is safe to run during the build of a layer. At that
# time, you most want to look. -Deep adds the two tests that go into the guest
# through ssh. Without it, the probe stays on the host side, and takes about a
# second.
param(
    [Parameter(Position = 0)][string]$Vm = '',
    [switch]$Deep,
    [string]$AdminKey = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [int]$TimeoutSec = 15
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# One writer, so that a value with an "=" cannot look like two fields. All text
# after the first "=" is the value, and the bash side splits only on the first
# one.
function Emit([string]$k, $v) { Write-Output ("{0}={1}" -f $k, ($v -replace '[\r\n]+', ' ')) }

Emit 'vm' $Vm

# --- link 1: the AppSandbox daemon -------------------------------------------------------
# By effect. A host.json with nothing behind it means that the last daemon DIED,
# and did not exit. The file alone reports a healthy daemon that is not there.
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
        Emit 'daemon' 'stale'   # the file is there, but the socket is not
    }
} else {
    Emit 'daemon' 'down'
}

function Asb([string]$Path) {
    Invoke-RestMethod -Uri "$($daemon.endpoint)/v1$Path" -TimeoutSec $TimeoutSec `
        -Headers @{ Authorization = "Bearer $($daemon.token)" }
}

# --- link 2: the VM ----------------------------------------------------------------------
# agentOnline is the own guest agent of AppSandbox. The code reports it, because
# only it says that the boot of the guest is complete. But it says NOTHING about
# sshd. That is why link 3 is separate.
$st = $null
if ($daemon -and $Vm) {
    # THE LIST COMES FIRST, and that order is its purpose. Asked after, it only
    # named the alternatives in a refusal. Asked here, it also tells "there is
    # no such VM" from "the daemon did not answer". Those are different faults,
    # with different fixes. A TEST, directly after the first real `dr-layer
    # adopt`: the VM in the configuration had just become a layer, and status
    # reported it as "unknown".
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
        # NOT REGISTERED IS NOT THE SAME FACT AS "cannot tell". `adopt` and
        # `drop` remove a VM block. Thus a name that worked an hour ago can stop
        # to exist. "unknown" looks like a daemon that did not answer, and sends
        # the reader to the daemon. The code says "unregistered" only after the
        # daemon DID answer the list, without this name in it. If the code did
        # not read the list, the old word stays.
        if (($null -ne $known) -and ($known -notcontains $Vm)) { Emit 'vm_state' 'unregistered' }
        else { Emit 'vm_state' 'unknown' }
    }
}

# --- link 3: ssh into the guest ----------------------------------------------------------
# THE CODE READS THE PORT AGAIN, AND NEVER CACHES IT. TWO TESTS ON ONE DAY:
# vms.cfg said 57351 while the guest used 54501. At the time that agentOnline
# became true, the API answered 57351, and a few minutes later 57589. sshState
# is 2 in both cases, so no field tells you that a port is final. Only a command
# that comes back is proof.
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

# --- links 4 and 5: the ports of the mound ----------------------------------------------
# WHO BINDS WHAT, because a mix-up sends you to the wrong place:
#   18888         the MOUND publishes it. Down = the gateway does not run.
#   18445         the mound ALSO publishes it, but only a gateway that serves a vault. Thus
#                 down has two meanings, and for that reason dr-forge doctor judges link 6
#                 only on 18888. A gateway generated with no --vault does not publish it
#                 (lib/forge/common.sh says why it must not).
#   18765, 18000  the -L of the tunnel supervisor binds them. Down = the supervisor does not run.
# The -R forwards of the supervisor are INSIDE the guest, and this side cannot
# see them. Thus the proxy test on the guest side below is the only real test of
# the tunnel.
foreach ($p in 18888, 18445, 18765, 18000) {
    $up = [bool](Get-NetTCPConnection -LocalPort $p -State Listen -EA SilentlyContinue)
    Emit "port_$p" $(if ($up) { 'up' } else { 'down' })
}

# The supervisor is pinned to ONE VM at registration, and never reads it again.
# Thus an old one from a previous layer holds the ports that this one needs, and
# logs "waiting for the VM" forever. With the name of its VM in the report, that
# is a diagnosis of five seconds.
$task = Get-ScheduledTask -TaskName 'Draugr forge tunnel' -EA SilentlyContinue
if ($task) {
    $arg = ($task.Actions | Select-Object -First 1).Arguments
    Emit 'tunnel_task' $task.State
    if ($arg -match '-Vm\s+(\S+)') { Emit 'tunnel_vm' $Matches[1] }
} else {
    Emit 'tunnel_task' 'absent'
}

# THE PIN OF THE TASK IS A REGISTRATION, NOT A RUNNING SUPERVISOR. A mix-up of
# the two reported a working forge as broken. A TEST SHOWED THIS: the task was
# registered -Vm layer-2-ue426, while the live supervisor served ue-427-test,
# held both forwards, and the egress of the guest worked. A report of only the
# task was an EXISTENCE test shown as an effect test. The header of this file
# forbids exactly that. Thus the code traces the forward back to its holder.
# ssh.exe owns the listener, and its PARENT is the supervisor, which knows its
# VM. THE CODE ALWAYS GIVES THE CLAIM, ALSO WITH NO HOLDER OF A PORT. That was
# the gap. A port holder is the condition for each fact below. Thus a supervisor
# BETWEEN RECONNECTS, which holds none, was reported as nothing, and `dr-forge
# doctor` said "no way out" for a forge that only waited. See docs/FORGE.md.
#
# It is a separate fact from fwd_vm, on purpose. fwd_vm answers "who carries",
# and sup_vm answers "who claims". A mix-up of them made a wait look like a
# break.
$supClaim = Join-Path $env:LOCALAPPDATA 'Draugr\forge-tunnel.claim'
if (Test-Path $supClaim) {
    $scl = @(Get-Content $supClaim -ErrorAction SilentlyContinue)
    if ($scl.Count -ge 2) {
        $scPid = 0
        if ([int]::TryParse($scl[0].Trim(), [ref]$scPid)) {
            # A reused pid looks like a live supervisor. Thus the process must
            # be present AND be a PowerShell. The own reader of tunnel.ps1 uses
            # the same guard.
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
        # An unreadable command line is reported as unreadable, never as a
        # match. A process that this query cannot read is no evidence that THIS
        # VM is served. It is also the normal case for the supervisor of the
        # logon task, which runs in session 0. See tunnel_mutex below.
        if ($sup -and $sup.CommandLine -match '-Vm\s+"?([^\s"]+)') { Emit 'fwd_vm' $Matches[1] }
        elseif ($sup) {
            # THE CLAIM FILE ANSWERS WHAT THE COMMAND LINE CANNOT. A supervisor
            # from the logon task runs in SESSION 0, and Win32_Process gives an
            # interactive session an empty CommandLine for it. A TEST SHOWED
            # THIS. After a reboot, this reported "serving unreadable" for a
            # tunnel. At the same time, links 8, 9, and 10 proved that it
            # carried traffic for this VM. That is a working forge called
            # broken, and this file exists to prevent exactly that.
            #
            # vm-tunnel.ps1 writes the pid and the VM next to its log, for
            # exactly this gap. The code trusts it only for a pid that IS the
            # process that holds the forward. A claim from a supervisor that
            # died since says nothing about the current holder.
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

# DOES A SECOND SUPERVISOR RUN? vm-tunnel.ps1 guards against that with a Global
# mutex. A TEST SHOWED that the guard does not work across sessions. From an
# interactive session, an open of 'Global\Draugr.forge.tunnel' answers "Access
# to the path is denied", while the supervisor of the logon task, which created
# it in session 0, is alive. The default DACL of a token allows its own LOGON SID,
# and each session has its own logon SID. Thus the same user cannot open the
# object from another session. vm-tunnel.ps1 reads that denial as "guard
# unavailable", and runs anyway. Then two supervisors share the forwards through
# SO_REUSEADDR, and answer in turn.
#
# THE DENIAL IS THE USEFUL PART. A mutex exists only while somebody holds a
# handle. Thus a refusal is POSITIVE evidence of a second supervisor, not a
# failed test. The open creates nothing, and never takes ownership. Thus this
# stays read-only, as the rest of the file.
try {
    $m = [Threading.Mutex]::OpenExisting('Global\Draugr.forge.tunnel')
    $m.Dispose()
    Emit 'tunnel_mutex' 'visible'
} catch {
    # A .NET static that throws arrives WRAPPED in a MethodInvocationException.
    # Thus the real type is the inner one, and `catch
    # [UnauthorizedAccessException]` does not work here.
    $e = $_.Exception
    if ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [UnauthorizedAccessException]) { Emit 'tunnel_mutex' 'other-session' }
    else { Emit 'tunnel_mutex' 'absent' }
}

# --- the deep checks: inside the guest ---------------------------------------------------
# Skipped unless you ask, because each one costs an ssh round trip. The view
# from the host side usually shows the problem.
if ($Deep -and $sshPort -and (Test-Path $AdminKey)) {
    $user = if ($si -and $si.user) { $si.user } else { 'forge' }
    $sshArgs = @('-n', '-i', $AdminKey, '-p', $sshPort, '-o', 'IdentitiesOnly=yes',
                 '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
                 # Because of the alias, the note in this file about the
                 # changing relay port is no longer a problem. ssh keeps the key
                 # for the VM. See docs/FORGE.md.
                 '-o', "HostKeyAlias=draugr-$Vm",
                 '-o', "ConnectTimeout=$TimeoutSec", "$user@127.0.0.1")

    # EAP guard. Under 'Stop', the stderr of a native command, redirected by
    # 2>&1, arrives as a terminating ErrorRecord. Thus one information line from
    # ssh ends this probe.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # link 3, by effect: a command that RUNS. sshd listens seconds before it
        # can run something. Thus a test of only the connection passes on a
        # guest that refuses work.
        $out = & ssh.exe @sshArgs 'cmd /c echo DRAUGR_OK' 2>&1
        Emit 'ssh_exec' $(if (($out -join ' ') -match 'DRAUGR_OK') { 'yes' } else { 'no' })
        if (($out -join ' ') -notmatch 'DRAUGR_OK') { Emit 'ssh_error' (($out | Select-Object -Last 1) -join ' ') }

        # link 4, by effect, and this is the important one: ask THE GUEST
        # whether the proxy answers. A forward open on the host proves nothing
        # about the far end. That is the failure, in one line.
        if (($out -join ' ') -match 'DRAUGR_OK') {
            # @' '@ is LITERAL. Each $ below is for the PowerShell of the GUEST.
            # An interpolating here-string expands them here.
            $guestPs = @'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
# Reported on the connection that is already open, so that it costs no round
# trip of its own. Each VM on the layer stack inherits the computer name of the
# base image. Thus a guest calls itself layer-0, while vms.cfg calls it
# something else. You cannot see that from inside the guest. It causes
# problems only with several VMs.
"DRAUGR_NAME=$env:COMPUTERNAME"
try {
    $r = Invoke-WebRequest -Uri 'https://www.unrealengine.com/' -Proxy 'http://127.0.0.1:3128' `
             -UseBasicParsing -TimeoutSec 20
    "DRAUGR_CODE=$([int]$r.StatusCode)"
} catch {
    # 4xx and 5xx arrive as exceptions. The code is still the answer that we
    # want, because 403 means that the request REACHED the site. Thus it comes
    # from the response. No response is the only real failure, and that is 000.
    $resp = $_.Exception.Response
    if ($resp) { "DRAUGR_CODE=$([int]$resp.StatusCode)" } else { "DRAUGR_CODE=000" }
}
'@
            $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guestPs))
            $reply = & ssh.exe @sshArgs "powershell -NoProfile -EncodedCommand $b64" 2>&1
            # Matched by its tag, not by position, for the CLIXML reason in the
            # header note.
            $code = ''
            foreach ($l in @($reply)) {
                if ("$l" -match 'DRAUGR_CODE=(\d+)') { $code = $Matches[1] }
                if ("$l" -match 'DRAUGR_NAME=(\S+)') { Emit 'guest_name' $Matches[1] }
            }
            Emit 'guest_proxy_code' $(if ($code) { $code } else { '000' })
            # 000 = nothing answered (no tunnel, or no tinyproxy behind it). 500
            # = tinyproxy answered and refused. The gateway runs, and its policy
            # said no. Each other code, also 403, means that the request reached
            # the site.
            Emit 'guest_egress' $(if ($code -eq '000' -or $code -eq '500' -or -not $code) { 'no' } else { 'yes' })
            # 403 is a PASS, and that is not a typo. It means that the request
            # reached the site. Only 000 (nothing answered) and 500 (tinyproxy
            # refused) are failures.
        }
    } finally { $ErrorActionPreference = $old }
}
