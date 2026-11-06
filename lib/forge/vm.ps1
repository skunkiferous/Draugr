# vm.ps1 - start the forge's VM, stop it, or bring its tunnel up.
#
# ==> RUN BY bin/dr-forge, ON THE WINDOWS SIDE. Not meant to be typed. <==
#
# WHY A THIRD POWERSHELL FILE, rather than more modes in guest.ps1. The three hold different
# authority, and keeping them apart is what makes that legible:
#
#   probe.ps1   reads, and changes nothing. Safe to run while a layer is being built.
#   guest.ps1   reaches INTO the guest over ssh, with the admin key.
#   vm.ps1      drives the VM's LIFECYCLE through AppSandbox's API, with the daemon's token.
#
# That last one is the control plane docs/FORGE.md keeps out of the mound on purpose: this file
# can start and stop a VM, and nothing in a sandbox may do that. It is reached only from
# bin/dr-forge, host-side, which is where the token already is.
#
# WHAT IT DELIBERATELY CANNOT DO: start the daemon. That needs elevation, and a UAC prompt
# sprung by a command someone ran for another reason is not a thing to do to anyone. A daemon
# that is down is reported with the one command that fixes it, and nothing is attempted.
#
#   -Mode start     start the VM if stopped, then wait until a command RUNS in the guest
#   -Mode stop      ask the daemon for a graceful shutdown, then pull the plug if it outlasts it
#   -Mode tunnel    start the supervisor if the forward does not carry, then wait until it does
#   -Mode screen    put the guest's desktop in front of a human, and do not wait for them
param(
    [string]$Mode         = '',
    [string]$Vm           = '',
    [string]$AdminKey     = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    # Draugr's OWN supervisor, beside this file. It used to be handed in by the caller, which
    # meant reading it out of the gateway project - a file this repository does not ship, so
    # `up` broke on a gateway checked out elsewhere and complained about someone else's
    # directory layout. Overridable, because a by-hand run may want a different one.
    # The tunnel key's PUBLIC half is installed by -Mode keys, for the same reason the admin
    # key is: the daemon's rewrite at every VM start takes out both. Same default as
    # provision.ps1's -TunnelKey, because they are the same key and a second default that
    # could disagree is worse than a repeated one.
    [string]$TunnelKey    = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519",
    [string]$TunnelScript = (Join-Path $PSScriptRoot 'tunnel.ps1'),
    [string]$ScreenScript = (Join-Path $PSScriptRoot 'screen.ps1'),
    [int]   $ForwardPort  = 18022,
    [int]   $ScreenPort   = 15900,
    [int]   $TimeoutSec   = 300,
    [int]   $GraceSec     = 120
)

# NOT [Parameter(Mandatory)], and not for style: a [Parameter()] attribute anywhere in a param
# block makes the script cmdlet-bound, and $PSScriptRoot is then EMPTY while the defaults above
# are evaluated - which would quietly turn the supervisor's path into a bare "tunnel.ps1"
# resolved against whatever directory this happened to be run from. That cost an evening in
# forge-engine-layer.ps1. Validated by hand instead.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# The exit codes bin/dr-forge reads. Documented here because the caller branches on them and a
# number invented at the throw site is a number nobody can look up.
#
#   10  no daemon, or a daemon that answers nothing
#   11  the VM: unknown to the daemon, or it did not reach the wanted state in time
#   12  the forward: not carrying, or held for another VM
#   13  the admin key is not where it should be
#   14  the tunnel supervisor script was not found
#    2  this script was called wrongly
function Fail([int]$Code, [string]$Msg) {
    [Console]::Error.WriteLine("forge-vm: $Msg")
    exit $Code
}
function Say([string]$Msg) { Write-Host $Msg }

if (-not $Vm)   { Fail 2 '-Vm is required' }
if (-not $Mode) { Fail 2 '-Mode is required: start, stop, keys, tunnel or screen' }

# --- the daemon ---------------------------------------------------------------------------
# BY EFFECT, NOT BY THE FILE. A host.json with nothing behind it is the signature of a daemon
# that died rather than exited, and the file alone would have us dial a port no one holds.
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) {
    Fail 10 'the AppSandbox daemon is not running (no host.json).'
}
$h = Get-Content $hostJson -Raw | ConvertFrom-Json
function Asb([string]$Method, [string]$Path) {
    $a = @{ Uri = "$($h.endpoint)/v1$Path"; TimeoutSec = 30; Method = $Method
            Headers = @{ Authorization = "Bearer $($h.token)" } }
    if ($Method -eq 'POST') { $a.Body = '{}'; $a.ContentType = 'application/json' }
    Invoke-RestMethod @a
}
try { $null = Asb GET '/version' } catch {
    Fail 10 'host.json is there but nothing answers - the last daemon died rather than exited.'
}

try { $st = Asb GET "/vms/$Vm" } catch {
    $known = ''
    try { $known = (@((Asb GET '/vms').vms | ForEach-Object { $_.name }) -join ', ') } catch { }
    Fail 11 "the daemon knows no VM called '$Vm'. Registered: $known"
}

# --- waiting, by effect -------------------------------------------------------------------
# THE RELAY PORT IS RE-READ EVERY ATTEMPT. Measured twice: vms.cfg said 57351
# while the guest was on 54501, and the API answered 57351 then 57589 minutes apart, with
# sshState 2 throughout. A command coming back is the only proof a port is the right one - and
# it is also the only proof the guest is up, since agentOnline goes true before sshd listens.
# $script:lastSshOut - WHAT SSH SAID, kept rather than discarded.
#
# The version this replaces matched ssh's output for a success token and threw the rest away.
# A guest refused the admin key sixty times over five minutes and `dr-forge up`
# reported "the VM did not answer a command within 300 s (state: online)" - which reads as an
# unresponsive guest and sent a reader to look at the guest's disk, chkdsk and the VM state.
# The guest was answering perfectly and saying "Permission denied". A wait that cannot say
# WHY is a wait that misdirects, and this one had the sentence in a variable it dropped.
$script:lastSshOut = ''
function Invoke-GuestEcho([string]$Key, [int]$Port, [string]$User) {
    $out = & ssh.exe -n -i $Key -p $Port -o IdentitiesOnly=yes `
               -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
               -o HostKeyAlias=draugr-$Vm `
               -o ConnectTimeout=10 "$User@127.0.0.1" 'cmd /c echo DRAUGR_OK' 2>&1
    $script:lastSshOut = (@($out) -join ' ').Trim()
    return $script:lastSshOut
}
# Returns @{ Port; User } for the key that worked, or $null. Taking the key as a parameter is
# what lets `start` wait on the DEPLOY key before our own is installed.
function Wait-GuestKey([string]$Key, [int]$Seconds) {
    $t0 = Get-Date
    do {
        try {
            $si = Asb GET "/vms/$Vm/sshInfo"
            if ($si.port -and [int]$si.port -gt 0) {
                if ((Invoke-GuestEcho $Key ([int]$si.port) $si.user) -match 'DRAUGR_OK') {
                    return @{ Port = [int]$si.port; User = $si.user }
                }
            }
        } catch { }
        Start-Sleep -Seconds 5
    } while (((Get-Date) - $t0).TotalSeconds -lt $Seconds)
    return $null
}
function Wait-GuestCommand([int]$Seconds) { return [bool](Wait-GuestKey $AdminKey $Seconds) }

# Wait-GuestAnyKey - the first credential this guest accepts, and which one it was.
#
# WHY NOT JUST THE DEPLOY KEY, which is what the first version of this waited on: a VM created
# by `dr-layer new` from a frozen layer has NO deploy key - New-VmBlock writes neither
# SshDeployKey nor SshPubKey - so that wait could only ever run out. Measured cost: the full
# $TimeoutSec, 300 s by default, on every `dr-forge up` of every engine-layer VM, before
# falling through to an admin key that had been working all along.
#
# ADMIN FIRST, each round. If the admin key answers there is nothing to bootstrap and the
# keys are already where they belong; the deploy key is the fallback for a guest whose file
# the daemon has just rewritten. Both are tried every round rather than one being waited out
# first, because on a cold boot NEITHER answers until sshd is up - and which of them answers
# then is the whole question.
function Wait-GuestAnyKey([int]$Seconds) {
    $asbKey = Join-Path $env:ProgramData 'AppSandbox\ssh\id_appsandbox'
    $t0 = Get-Date
    do {
        foreach ($c in @(@{ Which = 'admin'; Key = $AdminKey }, @{ Which = 'deploy'; Key = $asbKey })) {
            if (-not (Test-Path $c.Key)) { continue }
            try {
                $si = Asb GET "/vms/$Vm/sshInfo"
                if ($si.port -and [int]$si.port -gt 0) {
                    if ((Invoke-GuestEcho $c.Key ([int]$si.port) $si.user) -match 'DRAUGR_OK') {
                        return @{ Port = [int]$si.port; User = $si.user; Key = $c.Key; Which = $c.Which }
                    }
                }
            } catch { }
        }
        Start-Sleep -Seconds 5
    } while (((Get-Date) - $t0).TotalSeconds -lt $Seconds)
    return $null
}

# Refused is not silent, and the two are fixed in different places. Read off the last thing
# ssh said rather than guessed from a timeout.
function Get-SshVerdict {
    if ($script:lastSshOut -match 'Permission denied|publickey') {
        return 'refused the key'
    }
    if ($script:lastSshOut -match 'Connection refused|Connection closed|timed out|No route') {
        return 'did not accept a connection'
    }
    if (-not $script:lastSshOut) { return 'said nothing at all' }
    return 'answered with something unexpected'
}

# Install-GuestKeys - put our keys back, because the daemon takes them out.
#
# MEASURED: AppSandbox rewrites C:\ProgramData\ssh\administrators_authorized_keys
# at every VM start and keeps ONLY its own deploy key - 93 bytes, one line, seven seconds
# after boot, verified by restoring three keys and doing one stop/start. So a VM that has just
# started trusts the deploy key and nothing else, and EVERY path that starts one has to put
# ours back or the next thing to touch ssh fails with "Permission denied".
#
# It hid for a month because `dr-layer provision` runs its keys phase on every invocation and
# repaired this each time. `dr-forge up` was the first path that started a VM without a
# provision behind it.
#
# IT ALSO MEANS KEYS IN A FROZEN LAYER BUY NOTHING: the file is rewritten on the way up, so
# every boot of every layer needs this bootstrap, and a base image does not need working keys
# baked into it.
#
# The deploy key is the only one guaranteed to work here, so it is the bootstrap. A guest
# created without sshDeployKey has none, and for that one provision prints a block to paste.
function Install-GuestKeys([int]$Port, [string]$User, [string]$Via) {
    # THE CALLER SAYS WHICH CREDENTIAL TO USE, because it is the one that just proved it
    # works. This used to hard-code the deploy key, which a layer-built guest does not trust -
    # so on those it failed twice over and the caller had already wasted $TimeoutSec finding
    # out. Whichever key got us in can install the rest.
    if (-not $Via -or -not (Test-Path $Via)) {
        Say "  no usable credential for '$Vm', so there is no way in to install our keys."
        Say '  A guest with neither our admin key nor an AppSandbox deploy key needs its'
        Say '  first key put in by hand; dr-layer provision prints the block for that.'
        return $false
    }
    $asbKey = $Via
    $ok = $true
    foreach ($j in @(
        @{ What = 'admin';  Script = 'authorize-key.ps1';      Pub = "$AdminKey.pub" },
        @{ What = 'tunnel'; Script = 'install-tunnel-key.ps1'; Pub = "$TunnelKey.pub" })) {

        if (-not (Test-Path $j.Pub)) {
            Say "  no $($j.Pub) - the $($j.What) key cannot be installed"
            $ok = $false
            continue
        }
        $src  = Join-Path $PSScriptRoot "guest\$($j.Script)"
        $leaf = Split-Path $j.Pub -Leaf
        & scp.exe -q -i $asbKey -P $Port -o IdentitiesOnly=yes -o BatchMode=yes `
            -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
            $src $j.Pub "$User@127.0.0.1:C:/Windows/Temp/"
        if ($LASTEXITCODE -ne 0) {
            Say "  could not copy the $($j.What) key installer into the guest (scp $LASTEXITCODE)"
            $ok = $false
            continue
        }
        # UNQUOTED REMOTE PATHS, and that is measured rather than careless: plain double
        # quotes around a Windows path lose their backslashes when the script is launched
        # from WSL, which bin/dr-forge does. `if exist` is provision's guard for the other
        # half of it - `powershell -File <missing>` exits 0, so a copy that silently failed
        # would read as a script that ran and did nothing. docs/FORGE.md.
        $remote = "C:\Windows\Temp\$($j.Script)"
        $pubAt  = "C:\Windows\Temp\$leaf"
        $cmd = "if exist $remote " +
               "(powershell -NoProfile -ExecutionPolicy Bypass -File $remote -PubKeyFile $pubAt) " +
               "else (exit /b 127)"
        $out = & ssh.exe -n -i $asbKey -p $Port -o IdentitiesOnly=yes -o BatchMode=yes `
                   -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
                   "$User@127.0.0.1" $cmd 2>&1
        $rc = $LASTEXITCODE
        @($out) | ForEach-Object { Say "    $_" }
        if ($rc -eq 127) {
            Say "  the $($j.What) key installer never ran: it is not at $remote in the guest."
            $ok = $false
        } elseif ($rc -ne 0) {
            Say "  the $($j.What) key installer failed ($rc)"
            $ok = $false
        }
        # The public key is not scaffolding worth leaving in Temp; the installer has read it.
        & ssh.exe -n -i $asbKey -p $Port -o IdentitiesOnly=yes -o BatchMode=yes `
            -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
            "$User@127.0.0.1" `
            "del /q $pubAt" 2>&1 | Out-Null
    }
    return $ok
}

function Test-Running {
    try { return [bool](Asb GET "/vms/$Vm").running } catch { return $false }
}

function Wait-Stopped([int]$Seconds) {
    $t0 = Get-Date
    do {
        if (-not (Test-Running)) { return $true }
        Start-Sleep -Seconds 5
    } while (((Get-Date) - $t0).TotalSeconds -lt $Seconds)
    return $false
}

# A BOUND PORT IS NOT A WORKING FORWARD, and that distinction cost a full diagnosis on
#: the supervisor's listener was up and owned by the right supervisor while the
# guest refused every channel over it, because sshd binds the tunnel key's permitopen at
# AUTHENTICATION time and the list had been widened since. Every port-based check passed and
# doctor blamed the mound. So the forward is judged by a command coming back through it.
# The user is asked for rather than assumed: it is the guest account the daemon reports, and
# 'forge' is only this machine's answer.
# THIS IS THE CHECK THAT LIED, and HostKeyAlias is why it no longer does.
#
# $ForwardPort is pinned - 18022, so the mound carries one rule instead of one per VM - which
# means every guest ever served presents a different host key at the same address. known_hosts
# keeps one entry per address and accept-new refuses a CHANGED key, correctly. So from the
# second guest onwards this function returned $false for a forward that was working perfectly.
#
# MEASURED: rc=255 and "REMOTE HOST IDENTIFICATION HAS CHANGED" through 18022,
# rc=0 for the same guest on its relay port, rc=0 through 18022 with the alias - and the key
# recorded under the alias was byte-identical to the one the relay port had already learnt.
# Meanwhile the supervisor's own log showed it connected and holding the forwards throughout,
# so `dr-forge up` spent its full 300 s reporting the far end dead because its own check could
# not get past a host key. docs/FORGE.md.
function Test-Forward([string]$User = 'forge') {
    $out = & ssh.exe -n -i $AdminKey -p $ForwardPort -o IdentitiesOnly=yes -o BatchMode=yes `
               -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
               -o ConnectTimeout=10 `
               "$User@127.0.0.1" 'cmd /c echo DRAUGR_FWD_OK' 2>&1
    return ((@($out) -join ' ') -match 'DRAUGR_FWD_OK')
}

# Which VM the process holding the forward is serving, or '' when that cannot be read. Same
# two-step as lib/forge/probe.ps1: the forward is held by an ssh.exe whose PARENT is the
# supervisor, and a supervisor started by the logon task runs in session 0 where its command
# line is not readable - so it writes a claim file, trusted only when the pid in it is the
# process actually holding the forward.
# Get-SupervisorClaim - who claims this host's forwards, WITHOUT asking who holds a port.
#
# This is the gap Get-ForwardOwner had: it began at the port and returned $null when nothing
# held it, so the claim was read only when a holder already existed. A supervisor between
# reconnects - its ssh exited, the next attempt up to ten seconds away - holds no port, and was
# therefore invisible. vm.ps1 then started a second supervisor, which read the same claim, saw
# the incumbent and exited; the stalled incumbent recovered on its own clock and `up` reported
# "the forward never carried". Found. docs/FORGE.md.
#
# The same guards as tunnel.ps1's own Read-Claim, for the same reasons: $null means "cannot
# tell" - absent, unreadable, malformed, or naming a pid that has gone or is not a PowerShell.
# That last one is a RECYCLED pid, which would otherwise read as a live holder and could
# silence the one supervisor this host needs.
function Get-SupervisorClaim {
    try {
        $claim = Join-Path $env:LOCALAPPDATA 'Draugr\forge-tunnel.claim'
        if (-not (Test-Path $claim)) { return $null }
        $l = @(Get-Content $claim -ErrorAction Stop)
        if ($l.Count -lt 2) { return $null }
        $claimPid = 0
        if (-not [int]::TryParse($l[0].Trim(), [ref]$claimPid)) { return $null }
        $p = Get-Process -Id $claimPid -ErrorAction SilentlyContinue
        if (-not $p -or @('powershell', 'pwsh') -notcontains $p.ProcessName) { return $null }
        return @{ SupervisorPid = $claimPid; Vm = $l[1].Trim() }
    } catch { return $null }
}

# Get-ForwardOwner - who holds the forwards, or failing that who CLAIMS them.
#
# Carrying is a separate question from existing, so the answer says which: a caller that only
# asks "is there an owner" would treat a supervisor between reconnects as a bound-but-dead
# forward and go to kill an ssh child that is not there.
function Get-ForwardOwner {
    $c = Get-NetTCPConnection -LocalPort $ForwardPort -State Listen -EA SilentlyContinue |
         Select-Object -First 1
    if (-not $c) {
        # NO PORT HOLDER IS NOT NOBODY. The claim stands on its own here.
        $cl = Get-SupervisorClaim
        if ($cl) { return @{ ChildPid = 0; Vm = $cl.Vm; SupervisorPid = $cl.SupervisorPid; Bound = $false } }
        return $null
    }
    $child = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.OwningProcess)" -EA SilentlyContinue
    if (-not $child) { return $null }
    $sup = Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ParentProcessId)" -EA SilentlyContinue
    $served = ''
    if ($sup -and $sup.CommandLine -match '-Vm\s+"?([^\s"]+)') { $served = $Matches[1] }
    elseif ($sup) {
        # The claim is trusted here only when its pid IS the process holding the forward: one
        # left by a supervisor that has since died says nothing about who holds it now.
        $cl = Get-SupervisorClaim
        if ($cl -and $cl.SupervisorPid -eq $sup.ProcessId) { $served = $cl.Vm }
    }
    return @{ ChildPid = $child.ProcessId; Vm = $served
              SupervisorPid = $(if ($sup) { $sup.ProcessId } else { 0 }); Bound = $true }
}

switch ($Mode) {

'start' {
    if (-not (Test-Path $AdminKey)) { Fail 13 "no admin key at $AdminKey" }
    # NO MACHINE MARKER HERE, unlike forge-vm-setup.ps1's DRAUGR_CHANGED: that one exists
    # because its caller has to DECIDE something (whether a reboot is owed). This caller
    # decides nothing - it branches on the exit code - so the words are the whole report and
    # there is one place they are written.
    if ($st.running) {
        Say 'already running'
    } else {
        # No snapshot argument, so no branch is created - starting a VM must not quietly
        # fork its disk.
        $null = Asb POST "/vms/$Vm/start"
        Say 'started'
    }
    # THE KEYS GO BACK IN BEFORE ANYTHING WAITS ON ONE OF THEM, because a VM the daemon has
    # just started trusts only its deploy key - measured. But WHICH credential
    # gets in is not assumed: see Wait-GuestAnyKey for what assuming the deploy key cost a
    # guest that never had one.
    $boot = Wait-GuestAnyKey $TimeoutSec
    if ($boot -and $boot.Which -eq 'admin') {
        # Nothing was wiped, so nothing needs restoring - but the tunnel key may still be
        # missing, and the installer skips whatever is already there, so it is cheap to ask.
        Say 'the admin key already works; checking the tunnel key is in too'
        $null = Install-GuestKeys $boot.Port $boot.User $boot.Key
    } elseif ($boot) {
        Say 'installing the keys the daemon removes at every start'
        if (-not (Install-GuestKeys $boot.Port $boot.User $boot.Key)) {
            Say '  not all keys went in; the admin key check below is what decides'
        }
    } else {
        # Not fatal here: the check below is the one that decides. Said, because a reader who
        # ends up there with a refusal wants to know this step never happened.
        Say ("no credential got into the guest within {0}s - {1}" -f $TimeoutSec, (Get-SshVerdict))
    }
    if (-not (Wait-GuestCommand $TimeoutSec)) {
        # WHAT HAPPENED, not just that time ran out. The previous message named a timeout for
        # what was a refused key, and that is the wrong half of the system to go and look at.
        Fail 11 ("the VM is $((Asb GET "/vms/$Vm").state) and ssh $(Get-SshVerdict), for " +
                 "$TimeoutSec s. Last reply: $script:lastSshOut")
    }
    Say 'a command ran in the guest'
    exit 0
}

'keys' {
    # Exposed as its own mode so provision.ps1 can delegate to it rather than carry a second
    # copy, and so a human can repair a guest by hand without a full provision run.
    if (-not $st.running) { Fail 14 "'$Vm' is not running: there is nothing to install keys into." }
    # Whichever credential works, for the reason Wait-GuestAnyKey gives: a guest built from a
    # layer has no deploy key at all, and this mode is exactly where somebody repairing such a
    # guest by hand would land.
    $boot = Wait-GuestAnyKey $TimeoutSec
    if (-not $boot) {
        Fail 14 ("nothing got into '$Vm' within $TimeoutSec s - neither our admin key nor an " +
                 "AppSandbox deploy key. ssh $(Get-SshVerdict). Last reply: $script:lastSshOut")
    }
    Say "in with the $($boot.Which) key"
    if (Install-GuestKeys $boot.Port $boot.User $boot.Key) { Say 'keys installed'; exit 0 }
    Fail 15 'at least one key did not go in; the lines above say which'
}

'stop' {
    if (-not $st.running) { Say 'already stopped'; exit 0 }

    # GRACEFUL FIRST, AND THE DAEMON HAS A CALL FOR IT. `POST /vms/<name>/shutdown` is a
    # "graceful ACPI power-off" and `POST /vms/<name>/stop` is "force power-off (pull the
    # plug)" - the README's own words, at C:\AppSandbox\headless-api\README.md. The VM passes
    # through a `stopping` state on the way down, which is why the wait below still looks for
    # `running` to go false rather than for a particular state.
    #
    # THIS USED TO BE THE CALLER'S JOB. bin/dr-forge ran `shutdown /s /t 0` in the guest over
    # ssh and this mode only waited it out, on the belief that the API offered nothing but the
    # plug. It offers both, so the ssh step is gone and this mode is self-contained - no longer
    # depending on a caller having fired something first, which was a coupling the comment here
    # had to explain rather than a design. It is also the more robust of the two: ACPI is a
    # hardware event, so it reaches a guest whose sshd has stopped answering.
    Say 'asking the daemon for a graceful shutdown'
    try { $null = Asb POST "/vms/$Vm/shutdown" } catch {
        # Not fatal: a refused graceful shutdown is a reason to fall through to the plug, not
        # a reason to give up and leave the VM running.
        Say "the graceful shutdown was refused: $($_.Exception.Message)"
    }
    Say "waiting up to $GraceSec s for it to power off"
    if (Wait-Stopped $GraceSec) {
        Say 'shut down gracefully'
        exit 0
    }
    Say 'it outlasted the grace period - pulling the plug through the daemon'
    try { $null = Asb POST "/vms/$Vm/stop" } catch {
        Fail 11 "the daemon refused to stop it: $($_.Exception.Message)"
    }
    if (-not (Wait-Stopped $TimeoutSec)) { Fail 11 "it is still running $TimeoutSec s after stop" }
    Say 'stopped through the daemon'
    exit 0
}

'tunnel' {
    if (-not (Test-Path $AdminKey)) { Fail 13 "no admin key at $AdminKey" }

    # Resolved once, up front, because every Test-Forward below needs it and the daemon is the
    # authority on which guest account answers.
    $user = 'forge'
    try { $user = (Asb GET "/vms/$Vm/sshInfo").user } catch { }

    # Judged by effect before anything is started, so a healthy tunnel is left alone. This is
    # also the idempotent path: `dr-forge up` on a forge that is already up changes nothing.
    if (Test-Forward $user) { Say 'already carries'; exit 0 }

    # THE TUNNEL KEY IS WIPED BY EVERY VM START, exactly like the admin key, so everything
    # below this line - which is every path that expects a supervisor to authenticate - has
    # to make sure the key is there first.
    #
    # MEASURED, from %LOCALAPPDATA%\Draugr\forge-tunnel.log: a supervisor that had
    # been running since before the VM was restarted retried on its own ten-second clock,
    # landed in the window between the start and the key install, was told "Permission
    # denied", and backed off. `dr-forge up` reported that as "the forward never carried",
    # which is true and three steps downstream of the cause.
    #
    # BELOW THE EARLY EXIT ABOVE, deliberately: a tunnel that is already carrying needs none
    # of this, and this costs four ssh round trips. It is also why ending a supervisor's ssh
    # child further down is safe - whatever it reconnects with, the key is in place by then.
    # A SHORT WAIT, not $TimeoutSec. The VM is already running by the time anything asks for a
    # tunnel, so a credential that does not answer within half a minute is not going to - and
    # this path must not become a five-minute stall on the way to a forward that may be fine.
    if ($st.running) {
        $tk = Wait-GuestAnyKey 30
        if ($tk) {
            Say "making sure the keys the daemon removes are in the guest (in with the $($tk.Which) key)"
            if (-not (Install-GuestKeys $tk.Port $tk.User $tk.Key)) {
                Say '  not every key went in; the forward check below is what decides'
            }
        } else {
            Say "  no credential got into the guest - ssh $(Get-SshVerdict); carrying on anyway"
        }
    }

    # A FORWARD HELD FOR ANOTHER VM IS NOT OURS TO REPLACE. Starting a second supervisor here
    # would leave it looping on "Address already in use" - ExitOnForwardFailure makes its ssh
    # exit, the loop retries, and the guest never gets a way out. Measured with
    # two supervisors live: whichever holds the port wins, and the other can never take over.
    # So this reports, names the VM in the way, and stops.
    $own = Get-ForwardOwner
    if ($own -and $own.Vm -and ($own.Vm -ne $Vm)) {
        # -Vm is baked into a supervisor at launch and never re-read, so this one can never
        # come to serve the wanted VM. Ending it is the only way through, and that is said as
        # a pid rather than as a command: whatever started it - a logon task, a by-hand run -
        # is not something this script can know.
        Fail 12 ("127.0.0.1:$ForwardPort is held by a supervisor serving '$($own.Vm)', not " +
                 "'$Vm', and it can never come to serve this one. End it first: its ssh child " +
                 "is pid $($own.ChildPid), and whatever started it holds -Vm $($own.Vm) for life.")
    }
    if ($own -and $own.Bound) {
        # Ours, or unreadable, and not carrying. Ending the ssh child is the supervisor's own
        # recovery path - its loop logs "ssh exited" and reconnects within ten seconds,
        # re-authenticating against the authorised keys as they are NOW. That is the fix for a
        # stale permitopen, which is the one failure that leaves a forward bound and dead.
        Say "the forward is bound but does not carry - ending its ssh child (pid $($own.ChildPid))"
        Stop-Process -Id $own.ChildPid -Force -ErrorAction SilentlyContinue
        if (Test-Forward $user) { Say 'it carries again'; exit 0 }
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt 60) {
            Start-Sleep -Seconds 5
            if (Test-Forward $user) { Say 'it carries again'; exit 0 }
        }
    } elseif ($own) {
        # A LIVE SUPERVISOR FOR THIS VM THAT HOLDS NO PORT: it is between reconnects. Starting
        # a second one here is futile and was the defect - the new one reads this same claim,
        # stands down, and leaves this one to recover on its own clock while the caller reports
        # a forward that never carried.
        #
        # It is WAITED FOR, not killed. There is no ssh child to end, so the only other option
        # is killing the supervisor itself - which is refused for the reason the refusal above
        # gives: whatever started it is not something this script can know, and a session-0 one
        # may not be killable without elevation anyway. Its retry interval is ten seconds, so
        # the wait is in those units and generous enough to cover a dial plus a handshake.
        Say ("a supervisor for '$Vm' is alive (pid $($own.SupervisorPid)) but holds no forward - " +
             'it is between reconnects, so this waits for it rather than starting a second')
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
            Start-Sleep -Seconds 5
            if (Test-Forward $user) { Say 'it carries now'; exit 0 }
        }
        # NAMED, because that is the difference between this message and the one it replaces.
        # "the forward never carried" sent a reader to the guest; this sends them to a pid.
        Fail 12 ("the supervisor for '$Vm' (pid $($own.SupervisorPid)) did not bring the forward " +
                 "up within $TimeoutSec s. It holds the claim, so nothing else will take over " +
                 'while it lives. Its log says why: %LOCALAPPDATA%\Draugr\forge-tunnel.log')
    }

    # Code 14 now means a BROKEN INSTALL rather than a caller that forgot an argument: the
    # supervisor ships beside this file, so its absence is lib/forge missing a file.
    if (-not $TunnelScript) { Fail 14 'no tunnel supervisor path (-TunnelScript was set empty)' }
    if (-not (Test-Path $TunnelScript)) {
        Fail 14 "Draugr's tunnel supervisor is missing: $TunnelScript"
    }

    Say "starting the tunnel supervisor for '$Vm' (user $user)"
    # Hidden and detached: the supervisor outlives this script by design, and it must not die
    # with the shell that asked for it.
    # Quoted for the reason spelled out in the screen branch below: this one happens to work
    # because none of its values has a space today, which is exactly how such a fault waits -
    # a checkout under "C:\My Code\" would break it identically.
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$TunnelScript`"",
        '-Vm', "`"$Vm`"", '-User', "`"$user`"") | Out-Null

    $t0 = Get-Date
    do {
        Start-Sleep -Seconds 5
        if (Test-Forward $user) { Say 'the supervisor is up, and the forward carries'; exit 0 }
    } while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec)
    Fail 12 ("the forward never carried. The supervisor's own log is the only diagnosis there " +
             'is: %LOCALAPPDATA%\Draugr\forge-tunnel.log')
}

'screen' {
    if (-not (Test-Path $ScreenScript)) { Fail 14 "Draugr's screen holder is missing: $ScreenScript" }
    if (-not $st.running) { Fail 11 "the VM '$Vm' is not running - there is no desktop to show yet." }

    # ALREADY OPEN IS NOT AN ERROR. A second viewer on the same forward is a second window onto
    # one console session, which is confusing rather than useful - and the holder would refuse
    # the port anyway. So this reports and stops, which is what `up --screen` on an already
    # watched forge should do.
    $inUse = $false
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $ScreenPort); $inUse = $true } catch { } finally { $c.Dispose() }
    if ($inUse) { Say "a screen is already open on 127.0.0.1:$ScreenPort"; exit 0 }

    # DETACHED, AND NOT WAITED FOR. The viewer stays open as long as someone is looking, and
    # showing the screen is the LAST thing `up` does - so there is nothing left for it to wait
    # on. What does have to happen afterwards is the forward being torn down when the viewer
    # closes, and screen.ps1 is the process that outlives us to do it.
    Say 'opening the screen'
    # EVERY PATH CARRIES ITS OWN QUOTES. Start-Process -ArgumentList joins an array with spaces
    # and does NOT quote the parts, so a value containing one splits in two and the remainder
    # falls through POSITIONALLY onto the next parameter. MEASURED, with the admin
    # key under "C:\Users\First Last\": "Cannot convert value
    # "Last\.ssh\draugr_admin_ed25519" to type "System.Int32"" - it landed on -GuestPort, the
    # next parameter along, so argument binding failed and screen.ps1's body never ran. The
    # symptom was a screen that never opened and an empty log, which looks like anything but a
    # quoting fault. screen.ps1 carries the same warning about its own ssh call; this is the
    # same trap one level up.
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScreenScript`"",
        '-Vm', "`"$Vm`"", '-AdminKey', "`"$AdminKey`"", '-LocalPort', $ScreenPort) | Out-Null

    # BUT ITS SUCCESS IS STILL CONFIRMED HERE. A detached hidden process has no console, so
    # fire-and-forget would report "opening the screen" whether or not anything opened - and the
    # two failures worth knowing about (no screen server in the guest, no viewer on this host)
    # would be visible only in a log nobody was told to read. So wait for the forward to answer,
    # which is bounded and quick, and leave the viewer itself to the human.
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 40) {
        Start-Sleep -Milliseconds 500
        $c = New-Object Net.Sockets.TcpClient
        try {
            $c.Connect('127.0.0.1', $ScreenPort)
            Say "the viewer is on 127.0.0.1:$ScreenPort; it closes the forward when you close it"
            exit 0
        } catch { } finally { $c.Dispose() }
    }
    Fail 12 ("the screen did not come up within 40 s. What went wrong is in " +
             "%LOCALAPPDATA%\Draugr\forge-screen.log - the usual two are no VNC server in the " +
             'guest, and no viewer installed on this host.')
}

default { Fail 2 "unknown -Mode '$Mode': one of start, stop, keys, tunnel, screen" }

}
