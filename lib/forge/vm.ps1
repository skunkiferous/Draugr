# vm.ps1: start the VM of the forge, stop it, or start its tunnel.
#
# ==> bin/dr-forge RUNS THIS, ON THE WINDOWS SIDE. Do not type it. <==
#
# WHY A THIRD POWERSHELL FILE, and not more modes in guest.ps1? The three have
# different authority. Separate files make that clear:
#
#   probe.ps1   reads, and changes nothing. Safe to run while a layer is being built.
#   guest.ps1   reaches INTO the guest over ssh, with the admin key.
#   vm.ps1      controls the LIFECYCLE of the VM through the AppSandbox API, with the daemon token.
#
# That last one is the control plane that docs/FORGE.md keeps out of the mound
# on purpose. This file can start and stop a VM, and nothing in a sandbox can do
# that. Only bin/dr-forge calls it, on the host, where the token already is.
#
# WHAT IT CANNOT DO, ON PURPOSE: start the daemon. That needs elevation. A UAC
# prompt from a command that somebody ran for another reason is wrong. If the
# daemon is down, the report gives the one command that fixes it, and this
# script tries nothing.
#
#   -Mode start     if stopped, start the VM. Then wait until a command RUNS in the guest
#   -Mode stop      ask the daemon for a clean shutdown. If it takes too long, pull the plug
#   -Mode tunnel    if the forward does not carry, start the supervisor. Then wait until it does
#   -Mode screen    show the desktop of the guest to a person, and do not wait for them
param(
    [string]$Mode         = '',
    [string]$Vm           = '',
    [string]$AdminKey     = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    # The OWN supervisor of Draugr, beside this file. Before, the caller gave
    # it, from the gateway project. This repository does not ship that file.
    # Thus `up` broke on a gateway in another place, and complained about the
    # directory layout of somebody else. You can override it, because a run by
    # hand can want a different one. -Mode keys installs the PUBLIC half of the
    # tunnel key, for the same reason as the admin key. The daemon rewrites the
    # file at each VM start, and removes both. The default is the same as
    # -TunnelKey in provision.ps1, because it is the same key. A second default
    # that can be different is worse than a repeated one.
    [string]$TunnelKey    = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519",
    [string]$TunnelScript = (Join-Path $PSScriptRoot 'tunnel.ps1'),
    [string]$ScreenScript = (Join-Path $PSScriptRoot 'screen.ps1'),
    [int]   $ForwardPort  = 18022,
    [int]   $ScreenPort   = 15900,
    [int]   $TimeoutSec   = 300,
    [int]   $GraceSec     = 120
)

# NOT [Parameter(Mandatory)], and not for style. A [Parameter()] attribute in a
# param block makes the script cmdlet-bound, and then $PSScriptRoot is EMPTY
# while PowerShell evaluates the defaults above. The path of the supervisor then
# silently becomes a bare "tunnel.ps1", found from the current directory. That
# cost an evening in forge-engine-layer.ps1. Thus this script tests the values
# itself.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# The exit codes that bin/dr-forge reads. They are documented here, because the
# caller branches on them. Nobody can look up a number that is made up at the
# throw site.
#
#   10  no daemon, or a daemon that answers nothing
#   11  the VM: unknown to the daemon, or it did not reach the wanted state in time
#   12  the forward: not carrying, or held for another VM
#   13  the admin key is not in its place
#   14  the tunnel supervisor script was not found
#    2  the call to this script was wrong
function Fail([int]$Code, [string]$Msg) {
    [Console]::Error.WriteLine("forge-vm: $Msg")
    exit $Code
}
function Say([string]$Msg) { Write-Host $Msg }

if (-not $Vm)   { Fail 2 '-Vm is required' }
if (-not $Mode) { Fail 2 '-Mode is required: start, stop, keys, tunnel or screen' }

# --- the daemon ---------------------------------------------------------------------------
# BY EFFECT, NOT BY THE FILE. A host.json with nothing behind it is the sign of
# a daemon that died and did not exit. With only the file, this script connects
# to a port that nobody holds.
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
    Fail 10 'host.json exists, but nothing answers. The last daemon died, and did not exit.'
}

try { $st = Asb GET "/vms/$Vm" } catch {
    $known = ''
    try { $known = (@((Asb GET '/vms').vms | ForEach-Object { $_.name }) -join ', ') } catch { }
    Fail 11 "the daemon knows no VM called '$Vm'. Registered: $known"
}

# --- waiting, by effect -------------------------------------------------------------------
# EACH ATTEMPT READS THE RELAY PORT AGAIN. Two tests showed why. vms.cfg said
# 57351, but the guest was on 54501. The API answered 57351, then 57589 some
# minutes later, with sshState 2 all the time. Only a command that comes back
# proves that the port is correct. It is also the only proof that the guest
# runs, because agentOnline becomes true before sshd listens.
# $script:lastSshOut: WHAT SSH SAID, kept, not discarded.
#
# The old version searched the ssh output for a success token, and discarded the
# rest. A guest refused the admin key sixty times in five minutes. `dr-forge up`
# reported "the VM did not answer a command within 300 s (state: online)". That
# looks like a guest that does not respond. It sent a reader to the disk of the
# guest, chkdsk, and the VM state. The guest answered correctly, and said
# "Permission denied". A wait that cannot say WHY misdirects, and this one had
# the sentence in a variable that it dropped.
$script:lastSshOut = ''
function Invoke-GuestEcho([string]$Key, [int]$Port, [string]$User) {
    $out = & ssh.exe -n -i $Key -p $Port -o IdentitiesOnly=yes `
               -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
               -o HostKeyAlias=draugr-$Vm `
               -o ConnectTimeout=10 "$User@127.0.0.1" 'cmd /c echo DRAUGR_OK' 2>&1
    $script:lastSshOut = (@($out) -join ' ').Trim()
    return $script:lastSshOut
}
# Returns @{ Port; User } for the key that worked, or $null. The key is a
# parameter, so that `start` can wait for the DEPLOY key before our own key is
# installed.
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

# Wait-GuestAnyKey: the first credential that this guest accepts, and which one
# it was.
#
# WHY NOT ONLY THE DEPLOY KEY, as in the first version? A VM that `dr-layer new`
# creates from a frozen layer has NO deploy key. New-VmBlock writes neither
# SshDeployKey nor SshPubKey. Thus that wait always ran out. A test showed the
# cost: the full $TimeoutSec, 300 s by default, on each `dr-forge up` of each
# engine-layer VM. Then it used the admin key, which worked all the time.
#
# ADMIN FIRST, in each round. If the admin key answers, no bootstrap is
# necessary, and the keys are already in place. The deploy key is the fallback
# for a guest whose file the daemon just rewrote. Each round tries both. It does
# not wait out one first, because on a cold boot NEITHER answers until sshd
# runs. Then the question is which one answers.
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

# Refused is not silent, and you fix the two in different places. This reads the
# last output of ssh. It does not guess from a timeout.
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

# Install-GuestKeys: put our keys back, because the daemon removes them.
#
# A TEST SHOWED THIS. AppSandbox rewrites
# C:\ProgramData\ssh\administrators_authorized_keys at each VM start, and keeps
# ONLY its own deploy key: 93 bytes, one line, seven seconds after boot. The
# test restored three keys, and did one stop/start. Thus a VM that just started
# trusts only the deploy key. EACH path that starts one must put ours back. If
# not, the next use of ssh fails with "Permission denied".
#
# It was hidden for a month, because `dr-layer provision` runs its keys phase at
# each call, and repaired this each time. `dr-forge up` was the first path that
# started a VM with no provision after it.
#
# IT ALSO MEANS THAT KEYS IN A FROZEN LAYER GIVE NOTHING. The file is rewritten
# at each boot. Thus each boot of each layer needs this bootstrap, and a base
# image does not need working keys in it.
#
# Only the deploy key always works here, so it is the bootstrap. A guest created
# without sshDeployKey has none. For that guest, provision prints a block to
# paste.
function Install-GuestKeys([int]$Port, [string]$User, [string]$Via) {
    # THE CALLER SAYS WHICH CREDENTIAL TO USE, because it just proved that it
    # works. Before, this used only the deploy key, which a guest from a layer
    # does not trust. On those, it failed twice, after the caller already lost
    # $TimeoutSec to find out. The key that got us in can install the rest.
    if (-not $Via -or -not (Test-Path $Via)) {
        Say "  no usable credential for '$Vm', so there is no way in to install our keys."
        Say '  A guest with neither our admin key nor an AppSandbox deploy key needs its'
        Say '  first key by hand. dr-layer provision prints the block for that.'
        return $false
    }
    $asbKey = $Via
    $ok = $true
    foreach ($j in @(
        @{ What = 'admin';  Script = 'authorize-key.ps1';      Pub = "$AdminKey.pub" },
        @{ What = 'tunnel'; Script = 'install-tunnel-key.ps1'; Pub = "$TunnelKey.pub" })) {

        if (-not (Test-Path $j.Pub)) {
            Say "  no $($j.Pub). The $($j.What) key cannot be installed"
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
        # UNQUOTED REMOTE PATHS. A test showed the reason, so this is not
        # careless. Plain double quotes around a Windows path lose their
        # backslashes if WSL starts the script, as bin/dr-forge does. `if exist`
        # is the guard of provision for the other half. `powershell -File
        # <missing>` exits 0, so a copy that silently failed looks like a script
        # that ran and did nothing. docs/FORGE.md.
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
            Say "  the $($j.What) key installer never ran. It is not at $remote in the guest."
            $ok = $false
        } elseif ($rc -ne 0) {
            Say "  the $($j.What) key installer failed ($rc)"
            $ok = $false
        }
        # Do not leave the public key in Temp. The installer already read it.
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

# A BOUND PORT IS NOT A WORKING FORWARD. That difference cost a full diagnosis.
# The listener was up, and the right supervisor owned it. But the guest refused
# each channel over it. sshd binds the permitopen of the tunnel key at
# AUTHENTICATION time, and the list became wider after that. Each port test
# passed, and doctor blamed the mound. Thus a command that comes back through
# the forward is the test. This asks for the user, and does not guess it. It is
# the guest account that the daemon reports. 'forge' is only the answer of this
# machine. THIS IS THE TEST THAT LIED. HostKeyAlias is why it does not lie now.
#
# $ForwardPort is pinned to 18022, so the mound has one rule, not one for each
# VM. Thus each guest shows a different host key at the same address.
# known_hosts keeps one entry for each address, and accept-new correctly refuses
# a CHANGED key. Thus, from the second guest on, this function returned $false
# for a forward that worked correctly.
#
# A TEST SHOWED: rc=255 and "REMOTE HOST IDENTIFICATION HAS CHANGED" through
# 18022, rc=0 for the same guest on its relay port, and rc=0 through 18022 with
# the alias. The key under the alias was the same, byte for byte, as the key
# from the relay port. All the time, the log of the supervisor showed it
# connected, with the forwards. Thus `dr-forge up` used its full 300 s to report
# a dead far end, because its own test failed on a host key. docs/FORGE.md.
function Test-Forward([string]$User = 'forge') {
    $out = & ssh.exe -n -i $AdminKey -p $ForwardPort -o IdentitiesOnly=yes -o BatchMode=yes `
               -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
               -o ConnectTimeout=10 `
               "$User@127.0.0.1" 'cmd /c echo DRAUGR_FWD_OK' 2>&1
    return ((@($out) -join ' ') -match 'DRAUGR_FWD_OK')
}

# The VM that the process with the forward serves, or '' if this cannot read it.
# The same two steps as lib/forge/probe.ps1. An ssh.exe holds the forward, and
# its PARENT is the supervisor. A supervisor from the logon task runs in session
# 0, where nobody can read its command line. Thus it writes a claim file. This
# trusts the file only if its pid is the process that holds the forward.
# Get-SupervisorClaim: who claims the forwards of this host, WITHOUT a question
# about who holds a port.
#
# This was the gap in Get-ForwardOwner. It started at the port, and returned
# $null if nothing held it. Thus it read the claim only if a holder already
# existed. A supervisor between reconnects holds no port: its ssh exited, and
# the next attempt is up to ten seconds away. Thus it was invisible. vm.ps1 then
# started a second supervisor. That one read the same claim, saw the first one,
# and exited. The first one recovered on its own clock, and `up` reported "the
# forward never carried". docs/FORGE.md.
#
# The same guards as the Read-Claim of tunnel.ps1, for the same reasons. $null
# means "cannot tell": absent, unreadable, malformed, or the name of a pid that
# is gone or is not a PowerShell. The last is a RECYCLED pid. Without the guard,
# it looks like a live holder, and can stop the one supervisor that this host
# needs.
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

# Get-ForwardOwner: who holds the forwards, or if nobody, who CLAIMS them.
#
# Whether it carries is a different question from whether it exists, so the
# answer says which. A caller that only asks "is there an owner" takes a
# supervisor between reconnects for a bound but dead forward. Then it tries to
# kill an ssh child that does not exist.
function Get-ForwardOwner {
    $c = Get-NetTCPConnection -LocalPort $ForwardPort -State Listen -EA SilentlyContinue |
         Select-Object -First 1
    if (-not $c) {
        # NO PORT HOLDER DOES NOT MEAN NOBODY. Here, the claim alone is enough.
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
        # Here, this trusts the claim only if its pid IS the process that holds
        # the forward. A claim from a supervisor that died says nothing about
        # who holds it now.
        $cl = Get-SupervisorClaim
        if ($cl -and $cl.SupervisorPid -eq $sup.ProcessId) { $served = $cl.Vm }
    }
    return @{ ChildPid = $child.ProcessId; Vm = $served
              SupervisorPid = $(if ($sup) { $sup.ProcessId } else { 0 }); Bound = $true }
}

switch ($Mode) {

'start' {
    if (-not (Test-Path $AdminKey)) { Fail 13 "no admin key at $AdminKey" }
    # NO MACHINE MARKER HERE, unlike DRAUGR_CHANGED in forge-vm-setup.ps1. That
    # one exists because its caller must DECIDE something (whether a reboot is
    # necessary). This caller decides nothing, and branches on the exit code.
    # Thus the words are the full report, written in one place.
    if ($st.running) {
        Say 'already running'
    } else {
        # No snapshot argument, so no branch is created. A start of a VM must
        # not silently fork its disk.
        $null = Asb POST "/vms/$Vm/start"
        Say 'started'
    }
    # THE KEYS GO BACK IN BEFORE A WAIT FOR ONE OF THEM. A VM that the daemon
    # just started trusts only its deploy key (a test showed this). But
    # this does not guess WHICH credential gets in. Wait-GuestAnyKey tells what
    # a guess of the deploy key cost a guest that never had one.
    $boot = Wait-GuestAnyKey $TimeoutSec
    if ($boot -and $boot.Which -eq 'admin') {
        # Nothing was removed, so nothing needs a restore. But the tunnel key
        # can still be missing. The installer skips all that is already there,
        # so the question is cheap.
        Say 'the admin key already works. Making sure that the tunnel key is in too'
        $null = Install-GuestKeys $boot.Port $boot.User $boot.Key
    } elseif ($boot) {
        Say 'installing the keys that the daemon removes at each start'
        if (-not (Install-GuestKeys $boot.Port $boot.User $boot.Key)) {
            Say '  not all keys went in. The admin key test below decides'
        }
    } else {
        # Not fatal here. The test below decides. Said, because a reader who
        # gets a refusal there wants to know that this step never happened.
        Say ("no credential got into the guest in {0}s. {1}" -f $TimeoutSec, (Get-SshVerdict))
    }
    if (-not (Wait-GuestCommand $TimeoutSec)) {
        # WHAT HAPPENED, not only that time ran out. The previous message said
        # timeout for a refused key. That sends you to the wrong half of the
        # system.
        Fail 11 ("the VM is $((Asb GET "/vms/$Vm").state) and ssh $(Get-SshVerdict), for " +
                 "$TimeoutSec s. Last reply: $script:lastSshOut")
    }
    Say 'a command ran in the guest'
    exit 0
}

'keys' {
    # Its own mode, so that provision.ps1 can delegate to it and not keep a
    # second copy. Also, a person can repair a guest by hand without a full
    # provision run.
    if (-not $st.running) { Fail 14 "'$Vm' does not run. There is nothing to install keys into." }
    # The credential that works, for the reason in Wait-GuestAnyKey. A guest
    # built from a layer has no deploy key. A person who repairs such a guest
    # by hand uses this mode.
    $boot = Wait-GuestAnyKey $TimeoutSec
    if (-not $boot) {
        Fail 14 ("nothing got into '$Vm' in $TimeoutSec s: not our admin key, and not an " +
                 "AppSandbox deploy key. ssh $(Get-SshVerdict). Last reply: $script:lastSshOut")
    }
    Say "in with the $($boot.Which) key"
    if (Install-GuestKeys $boot.Port $boot.User $boot.Key) { Say 'keys installed'; exit 0 }
    Fail 15 'one or more keys did not go in. The lines above say which'
}

'stop' {
    if (-not $st.running) { Say 'already stopped'; exit 0 }

    # A CLEAN STOP FIRST, AND THE DAEMON HAS A CALL FOR IT. `POST
    # /vms/<name>/shutdown` is a "graceful ACPI power-off", and `POST
    # /vms/<name>/stop` is "force power-off (pull the plug)". Those are the
    # words of the README, at C:\AppSandbox\headless-api\README.md. The VM goes
    # through a `stopping` state on the way down. Thus the wait below looks for
    # a false `running`, not for a specific state.
    #
    # BEFORE, THE CALLER DID THIS. bin/dr-forge ran `shutdown /s /t 0` in the
    # guest over ssh, and this mode only waited. The belief was that the API
    # gave only the plug. It gives both, so the ssh step is gone, and this mode
    # is complete alone. It does not need a caller that sent something first.
    # That was a coupling, not a design. It is also the stronger of the two.
    # ACPI is a hardware event, so it reaches a guest whose sshd does not
    # answer.
    Say 'asking the daemon for a clean shutdown'
    try { $null = Asb POST "/vms/$Vm/shutdown" } catch {
        # Not fatal. A refused clean shutdown is a reason to use the plug, not a
        # reason to stop and leave the VM on.
        Say "the daemon refused the clean shutdown: $($_.Exception.Message)"
    }
    Say "waiting up to $GraceSec s for it to power off"
    if (Wait-Stopped $GraceSec) {
        Say 'clean shutdown complete'
        exit 0
    }
    Say 'it did not stop in the grace period. Pulling the plug through the daemon'
    try { $null = Asb POST "/vms/$Vm/stop" } catch {
        Fail 11 "the daemon refused to stop it: $($_.Exception.Message)"
    }
    if (-not (Wait-Stopped $TimeoutSec)) { Fail 11 "it still runs $TimeoutSec s after stop" }
    Say 'stopped through the daemon'
    exit 0
}

'tunnel' {
    if (-not (Test-Path $AdminKey)) { Fail 13 "no admin key at $AdminKey" }

    # Found once, at the start, because each Test-Forward below needs it. The
    # daemon is the authority on which guest account answers.
    $user = 'forge'
    try { $user = (Asb GET "/vms/$Vm/sshInfo").user } catch { }

    # Tested by effect before a start, so that this does not touch a healthy
    # tunnel. This is also the idempotent path (safe to run twice). `dr-forge
    # up` on a forge that already runs changes nothing.
    if (Test-Forward $user) { Say 'already carries'; exit 0 }

    # EACH VM START REMOVES THE TUNNEL KEY, the same as the admin key. Below
    # this line, each path expects a supervisor to authenticate. Thus each must
    # first make sure that the key is there.
    #
    # A TEST SHOWED THIS, in %LOCALAPPDATA%\Draugr\forge-tunnel.log. A
    # supervisor that ran from before the VM restart tried again on its own
    # ten-second clock. It came in the gap between the start and the key
    # install, got "Permission denied", and backed off. `dr-forge up` reported
    # "the forward never carried". That is true, but three steps after the
    # cause.
    #
    # BELOW THE EARLY EXIT ABOVE, on purpose. A tunnel that already carries
    # needs none of this, and this costs four ssh round trips. It is also why
    # the end of the ssh child of a supervisor further down is safe. At its
    # reconnect, the key is already in place. A SHORT WAIT, not $TimeoutSec. The
    # VM already runs when something asks for a tunnel. Thus a credential that
    # does not answer in half a minute does not answer later. This path must
    # not become a stop of five minutes before a forward that can be fine.
    if ($st.running) {
        $tk = Wait-GuestAnyKey 30
        if ($tk) {
            Say "making sure the keys the daemon removes are in the guest (in with the $($tk.Which) key)"
            if (-not (Install-GuestKeys $tk.Port $tk.User $tk.Key)) {
                Say '  not all keys went in. The forward test below decides'
            }
        } else {
            Say "  no credential got into the guest. ssh $(Get-SshVerdict). Continuing anyway"
        }
    }

    # DO NOT REPLACE A FORWARD FOR ANOTHER VM. A second supervisor here loops
    # on "Address already in use". ExitOnForwardFailure makes its ssh exit, the
    # loop tries again, and the guest never gets a way out. A test with two
    # live supervisors showed that the one with the port wins. The other can
    # never take over. Thus this reports, names the VM in the way, and stops.
    $own = Get-ForwardOwner
    if ($own -and $own.Vm -and ($own.Vm -ne $Vm)) {
        # -Vm is fixed in a supervisor at the start, and never read again. Thus
        # this one can never serve the wanted VM. Its end is the only way, and
        # the message gives a pid, not a command. This script cannot know what
        # started it (a logon task, or a run by hand).
        Fail 12 ("a supervisor for '$($own.Vm)', not " +
                 "'$Vm', holds 127.0.0.1:$ForwardPort. It can never serve this one. End it first. Its ssh child " +
                 "is pid $($own.ChildPid), and it keeps -Vm $($own.Vm) for its full life.")
    }
    if ($own -and $own.Bound) {
        # Ours, or unreadable, and it does not carry. The end of the ssh child
        # is the recovery path of the supervisor. Its loop logs "ssh exited",
        # and reconnects in ten seconds. It authenticates again with the
        # authorized keys of NOW. That fixes an old permitopen, the one failure
        # that leaves a forward bound and dead.
        Say "the forward is bound, but does not carry. Ending its ssh child (pid $($own.ChildPid))"
        Stop-Process -Id $own.ChildPid -Force -ErrorAction SilentlyContinue
        if (Test-Forward $user) { Say 'it carries again'; exit 0 }
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt 60) {
            Start-Sleep -Seconds 5
            if (Test-Forward $user) { Say 'it carries again'; exit 0 }
        }
    } elseif ($own) {
        # A LIVE SUPERVISOR FOR THIS VM THAT HOLDS NO PORT. It is between
        # reconnects. A second one here does nothing, and that was the defect.
        # The new one reads the same claim, and stops. The old one recovers on
        # its own clock, while the caller reports a forward that never carried.
        #
        # This WAITS for it, and does not kill it. No ssh child exists to end.
        # The only other choice is to kill the supervisor, and the refusal above
        # gives the reason against that. This script cannot know what started
        # it. Also, a kill of a session-0 one can need elevation. It tries again
        # each ten seconds. Thus the wait uses that unit, and is long enough for
        # a connect and a handshake.
        Say ("a supervisor for '$Vm' is alive (pid $($own.SupervisorPid)), but holds no forward. " +
             'It is between reconnects, so this waits for it, and does not start a second')
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
            Start-Sleep -Seconds 5
            if (Test-Forward $user) { Say 'it carries now'; exit 0 }
        }
        # NAMED, because that is the difference from the old message. "the
        # forward never carried" sent a reader to the guest. This sends them to
        # a pid.
        Fail 12 ("the supervisor for '$Vm' (pid $($own.SupervisorPid)) did not bring the forward " +
                 "up in $TimeoutSec s. It holds the claim, so nothing else takes over " +
                 'while it lives. Its log tells why: %LOCALAPPDATA%\Draugr\forge-tunnel.log')
    }

    # Code 14 now means a BROKEN INSTALL, not a caller that forgot an argument.
    # The supervisor ships beside this file. If it is absent, lib/forge is
    # missing a file.
    if (-not $TunnelScript) { Fail 14 'no tunnel supervisor path (-TunnelScript was set empty)' }
    if (-not (Test-Path $TunnelScript)) {
        Fail 14 "the tunnel supervisor of Draugr is missing: $TunnelScript"
    }

    Say "starting the tunnel supervisor for '$Vm' (user $user)"
    # Hidden and detached. By design, the supervisor stays after this script,
    # and it must not die with the shell that started it. Quoted for the reason
    # in the screen branch below. This one works only because none of its
    # values has a space today. That is how such a fault hides. A checkout
    # under "C:\My Code\" breaks it the same way.
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$TunnelScript`"",
        '-Vm', "`"$Vm`"", '-User', "`"$user`"") | Out-Null

    $t0 = Get-Date
    do {
        Start-Sleep -Seconds 5
        if (Test-Forward $user) { Say 'the supervisor runs, and the forward carries'; exit 0 }
    } while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec)
    Fail 12 ("the forward never carried. The only diagnosis is the log of the " +
             'supervisor: %LOCALAPPDATA%\Draugr\forge-tunnel.log')
}

'screen' {
    if (-not (Test-Path $ScreenScript)) { Fail 14 "the screen holder of Draugr is missing: $ScreenScript" }
    if (-not $st.running) { Fail 11 "the VM '$Vm' does not run. There is no desktop to show yet." }

    # ALREADY OPEN IS NOT AN ERROR. A second viewer on the same forward is a
    # second window on one console session. That confuses, and does not help.
    # Also, the holder refuses the port. Thus this reports and stops. That is
    # correct for `up --screen` on a forge that somebody already watches.
    $inUse = $false
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $ScreenPort); $inUse = $true } catch { } finally { $c.Dispose() }
    if ($inUse) { Say "a screen is already open on 127.0.0.1:$ScreenPort"; exit 0 }

    # DETACHED, WITH NO WAIT. The viewer stays open while somebody looks, and
    # the screen is the LAST step of `up`. Thus it has nothing to wait for.
    # After that, when the viewer closes, the forward must close. screen.ps1 is
    # the process that stays after us to do it.
    Say 'opening the screen'
    # EACH PATH HAS ITS OWN QUOTES. Start-Process -ArgumentList joins an array
    # with spaces, and does NOT quote the parts. Thus a value with a space
    # splits in two, and the rest goes POSITIONALLY to the next parameter. A
    # TEST with the admin key under "C:\Users\First Last\" showed: "Cannot
    # convert value "Last\.ssh\draugr_admin_ed25519" to type "System.Int32"".
    # It went to -GuestPort, the next parameter. Thus argument binding failed,
    # and the body of screen.ps1 never ran. The symptom was a screen that never
    # opened, and an empty log. That does not look like a quote fault.
    # screen.ps1 has the same warning about its own ssh call. This is the same
    # trap one level up.
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScreenScript`"",
        '-Vm', "`"$Vm`"", '-AdminKey', "`"$AdminKey`"", '-LocalPort', $ScreenPort) | Out-Null

    # BUT THIS STILL PROVES ITS SUCCESS. A detached, hidden process has no
    # console. Fire-and-forget always reports "opening the screen", also
    # with nothing open. The two important failures (no screen server in the guest, no
    # viewer on this host) then show only in a log that nobody reads. Thus wait
    # for the forward to answer. That is short and has a limit. The person
    # handles the viewer.
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 40) {
        Start-Sleep -Milliseconds 500
        $c = New-Object Net.Sockets.TcpClient
        try {
            $c.Connect('127.0.0.1', $ScreenPort)
            Say "the viewer is on 127.0.0.1:$ScreenPort. When you close it, it closes the forward"
            exit 0
        } catch { } finally { $c.Dispose() }
    }
    Fail 12 ("the screen did not come up in 40 s. The cause is in " +
             "%LOCALAPPDATA%\Draugr\forge-screen.log. The usual two are: no VNC server in the " +
             'guest, and no viewer installed on this host.')
}

default { Fail 2 "unknown -Mode '$Mode'. Use one of start, stop, keys, tunnel, screen" }

}
