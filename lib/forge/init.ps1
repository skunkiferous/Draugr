# init.ps1 - make a REGISTERED forge VM usable by Draugr.
#
# ==> RUN BY bin/dr-forge, ON THE WINDOWS SIDE. Not meant to be typed. <==
#
# WHY THERE IS ANYTHING TO DO AFTER A VM EXISTS. A VM created on a frozen layer boots, but
# three things it needs live in its OWN writable disk rather than in the layer underneath, so
# every VM built on the same parent needs them applied again:
#
#   its computer name            inherited from the base image, so every VM says "layer-0"
#   its sshd's password setting   Windows OpenSSH accepts passwords by DEFAULT
#   its authorised keys          the tunnel key's permitopen, and the WSL-side key
#
# Doing that from memory is how one gets missed. MEASURED the hard way: each
# of the three was found by its symptom rather than by being remembered - a VM calling itself
# `layer-0`, a guest offering passwords to a sandbox that could reach it, and a forward the
# tunnel key was not permitted to open.
#
# ONE VERB, because none of these is ever wanted alone. A VM with keys but no name is the
# trap; one with a name but no authorised WSL key cannot be reached by dr-sync at
# all; one with both but no screen server breaks `dr-forge screen`.
#
# IT IS IDEMPOTENT. Every phase checks what is already true and says so, and a re-run against a
# VM that is already set up changes nothing. That is also how it is tested.
#
# WHAT IT DOES NOT DO:
#   - create the VM. It makes an existing one usable; creating one is the layer mechanism's job
#     (docs/FORGE.md, "The layer mechanism as a command: dr-layer").
#   - start the AppSandbox daemon. That needs elevation, which puts it on the far side of the
#     line Draugr draws; it says what to run instead.
#   - write the ssh_config alias. That is `dr-setup --forge`, one `Host *.forge` block for every
#     VM, because the forwarded port is pinned (docs/FORGE.md, "The pinned port has a price").
#
# EXIT CODES, so bin/dr-forge can say something useful rather than echoing a transcript:
#   0 everything applied   2 misuse   10 no daemon   11 no such VM, or sshd never answered
#   13 a guest phase failed hard
param(
    [string]$Vm          = '',
    [string]$AdminKey    = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [string]$TunnelKey   = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519",
    [string]$WslPubKey   = '',
    [int]   $ForwardPort = 18022,
    # A RANGE, not a size. The floor is what Windows itself chose when left to manage it -
    # MEASURED inside ue-427-test: 512 MB allocated, peak usage 71 MB - so pinning
    # it there adds nothing and takes nothing away. The ceiling is the part that earns its
    # place, bounding what a differencing child can ever be charged. 0 means "the VM's own
    # RAM", read from the daemon rather than guessed. WMI needs both numbers, which is the only
    # reason a floor is named at all.
    [int]   $PageFileInitialMb = 512,
    [int]   $PageFileMaxMb     = 0,
    # A FILE of guest paths, one per line, to exclude from Defender. A path rather than a list
    # argument because the paths contain spaces and this value crosses four parsers.
    [string]$NoScanFile        = '',
    [switch]$NoTune,
    [switch]$Restart,
    [int]   $TimeoutSec  = 300
)

# No [Parameter()] attribute anywhere above, and not for style: one makes this script
# cmdlet-bound, and $PSScriptRoot is then EMPTY while the defaults are evaluated - so
# $AdminKey would silently become a bare filename. That cost an evening elsewhere in this
# family of scripts. Validated by hand instead.
if (-not $Vm) { Write-Host 'init.ps1: -Vm is required' -ForegroundColor Red; exit 2 }

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$guestDir = Join-Path $PSScriptRoot 'guest'

function Phase([string]$n, [string]$s) { Write-Host ("  {0,-22} {1}" -f $n, $s) }
function Note([string]$m)  { Write-Host "      $m" -ForegroundColor DarkGray }
function Warn([string]$m)  { Write-Host "      $m" -ForegroundColor Yellow }
function Die([int]$code, [string]$m, [string]$fix) {
    Write-Host "dr-forge init: $m" -ForegroundColor Red
    if ($fix) { Write-Host "  $fix" }
    exit $code
}

Write-Host ''
Write-Host "dr-forge init: $Vm"

# --- the daemon --------------------------------------------------------------------------
# By effect, not by the file: a host.json with nothing behind it means the last daemon DIED
# rather than exited, and the file alone would have us dial a port no one holds.
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) {
    Die 10 'the AppSandbox daemon is not running.' 'start it elevated:  AppSandbox.exe --headless'
}
$h = Get-Content $hostJson -Raw | ConvertFrom-Json
function Asb([string]$Method, [string]$Path) {
    $a = @{ Uri = "$($h.endpoint)/v1$Path"; TimeoutSec = 30; Method = $Method
            Headers = @{ Authorization = "Bearer $($h.token)" } }
    if ($Method -eq 'POST') { $a.Body = '{}'; $a.ContentType = 'application/json' }
    Invoke-RestMethod @a
}
try { $null = Asb GET '/version' } catch {
    Die 10 'host.json is there but nothing answers - the last daemon died rather than exited.' `
        'start AppSandbox again, then re-run this.'
}
Phase 'daemon' 'up'

# --- the VM ------------------------------------------------------------------------------
# Registered VMs are listed on the way out, because "no such VM" with no list is the least
# actionable error this script could produce: the name is usually a typo or a layer suffix.
try { $st = Asb GET "/vms/$Vm" } catch {
    $known = ''
    try { $known = (@((Asb GET '/vms').vms | ForEach-Object { $_.name }) -join ', ') } catch { }
    Die 11 "the daemon knows no VM called '$Vm'." "registered: $known"
}
if ($st.running) { Phase 'vm' 'already running' }
else {
    $null = Asb POST "/vms/$Vm/start"
    Phase 'vm' 'started'
}

# --- sshd --------------------------------------------------------------------------------
# THE PORT IS RE-READ EVERY ATTEMPT. Measured twice: vms.cfg said 57351 while the
# guest was on 54501, and the API itself answered 57351 then 57589 minutes apart, with sshState
# 2 throughout. A command coming back is the only proof a port is the right one.
$script:port = 0
function Wait-Sshd([int]$Seconds) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
        try {
            $si = Asb GET "/vms/$Vm/sshInfo"
            if ($si.port) {
                $script:port = [int]$si.port
                $out = & ssh.exe -n -i $AdminKey -p $script:port -o IdentitiesOnly=yes `
                           -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
                           -o HostKeyAlias=draugr-$Vm `
                           -o ConnectTimeout=10 "forge@127.0.0.1" 'cmd /c echo DRAUGR_OK' 2>&1
                if (($out -join ' ') -match 'DRAUGR_OK') { return $true }
            }
        } catch { }
        Start-Sleep -Seconds 5
    }
    return $false
}
if (-not (Wait-Sshd $TimeoutSec)) {
    Die 11 "sshd did not answer within $TimeoutSec s." `
        'the guest may still be booting, or the admin key is not authorised there yet; re-run this.'
}
Phase 'sshd' "answers on port $script:port"

function Get-SshArgs { @('-i', $AdminKey, '-p', $script:port, '-o', 'IdentitiesOnly=yes',
                      '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
                      '-o', "HostKeyAlias=draugr-$Vm", '-o', 'ConnectTimeout=20') }

# A guest script, copied in and run as a CHILD process with -ExecutionPolicy Bypass -File. Not
# dot-invoked: the guest's own policy is Restricted, so `& script.ps1` inside an already-running
# session is refused with "running scripts is disabled on this system". Measured.
#
# The output is CAPTURED as well as printed, into $script:guestOut, so the caller can tell
# whether the script changed anything: each guest script ends with DRAUGR_CHANGED=0 or =1.
# MEASURED on the first idempotent run: every phase said "written", "authorised", "set (takes
# effect at the next boot)" while the scripts underneath each said "nothing to do", and the run
# finished by advising a reboot for a rename that had not happened. A summary that cannot tell
# those apart is the one defect an idempotent script must not have.
$script:guestOut = ''
function Invoke-GuestScript([string]$Name, [string]$ScriptArgs = '') {
    $script:guestOut = ''
    $local = Join-Path $guestDir $Name
    if (-not (Test-Path $local)) { Warn "missing: $local"; return 1 }
    & scp.exe @(Get-SshArgs | ForEach-Object { if ($_ -eq '-p') { '-P' } else { $_ } }) `
        -- $local "forge@127.0.0.1:C:/Windows/Temp/$Name" 2>&1 | ForEach-Object { Note $_ }
    $out = & ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" `
        "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\$Name $ScriptArgs" 2>&1
    $rc = $LASTEXITCODE
    $script:guestOut = (@($out) | ForEach-Object { "$_" }) -join "`n"
    # The marker is for this script, not for a reader, so it is not echoed back.
    @($out) | Where-Object { "$_" -notmatch 'DRAUGR_CHANGED=' } | ForEach-Object { Note $_ }
    return $rc
}

# Did it change anything? UNKNOWN COUNTS AS CHANGED: a script that did not say is not a script
# that did nothing, and claiming "already" on no evidence is how a summary starts lying again.
function Test-Changed([string]$Text) { -not ($Text -match 'DRAUGR_CHANGED=0') }

function Copy-ToGuest([string]$Local, [string]$RemoteName) {
    & scp.exe @(Get-SshArgs | ForEach-Object { if ($_ -eq '-p') { '-P' } else { $_ } }) `
        -- $Local "forge@127.0.0.1:C:/Windows/Temp/$RemoteName" 2>&1 | ForEach-Object { Note $_ }
    return $LASTEXITCODE
}

# What the server says it will accept, asked without needing anyone's password: connect with
# pubkey disabled and BatchMode on, and ssh -v prints the list before failing.
function Get-Offered {
    $out = & ssh.exe -v @(Get-SshArgs) -o PubkeyAuthentication=no `
               -o PreferredAuthentications=password "forge@127.0.0.1" exit 2>&1
    $l = @($out | Select-String 'Authentications that can continue' | ForEach-Object { $_.Line })
    if ($l) { (($l -join ' ') -replace '.*continue:\s*', '').Trim() } else { '(none offered)' }
}

# WAIT FOR THE EFFECT, NOT FOR THE REQUEST. MEASURED on the first run against a
# genuinely fresh VM: the config was rewritten correctly, `sshd -T` agreed, the restart task was
# started - and the check that followed still read "publickey,password,keyboard-interactive", so
# the run warned that the restart had not taken. The guest was keys-only minutes later. Nothing
# was wrong except the measurement: the old listener was still up because the scheduler had not
# picked the task up yet, and a plain wait-for-sshd was satisfied BY THAT OLD LISTENER, instantly.
#
# POSITIVE EVIDENCE ONLY. Mid-restart the connection is refused and NOTHING is offered, and
# "nothing" must never be read as "passwords are off" - that is exactly the false green this
# phase exists to prevent. So each round needs sshd to answer a real command first, and then an
# offer list that is non-empty and has no password in it.
$script:offered = '(not measured)'
function Confirm-KeysOnly([int]$Seconds) {
    $t0 = Get-Date
    do {
        if (Wait-Sshd 30) {
            $o = Get-Offered
            if ($o -ne '(none offered)') {
                $script:offered = $o
                if ($o -notmatch 'password') { return $true }
            }
        }
        Start-Sleep -Seconds 5
    } while (((Get-Date) - $t0).TotalSeconds -lt $Seconds)
    return $false
}

# --- sshd, off passwords -----------------------------------------------------------------
# FIRST of the guest changes, because it is the security-relevant one: the gateway mound is
# given an sbx rule that can reach this sshd, so a password login here is something a sandbox
# could sit and guess at. Verified from OUTSIDE afterwards - the guest can only report what its
# config file says, and the question is what the running listener accepts.
Phase 'sshd auth' "before: $(Get-Offered)"
$rc = Invoke-GuestScript 'harden-sshd.ps1'
if ($rc -ne 0) { Note "the session was cut ($rc) - expected, since sshd restarts under it" }
if (Confirm-KeysOnly 120) {
    Phase 'sshd auth' "now offers: $script:offered"
} elseif (-not (Wait-Sshd 60)) {
    Die 13 'sshd did not come back after the restart.' `
        'get in over the screen and run:  Start-Service sshd'
} else {
    Warn "still offering: $script:offered, two minutes after the restart was requested"
    Warn 'check C:\ProgramData\ssh\sshd_config in the guest, and whether the task ran:'
    Warn '  Get-ScheduledTaskInfo -TaskName DraugrSshdRestart'
}
# The one-shot task has served its purpose; left behind it is clutter that looks like a job.
# IT IS REMOVED ONLY AFTER THE WAIT ABOVE, and that ordering is load-bearing:
# Start-ScheduledTask returns as soon as the scheduler accepts the request, so unregistering on
# a single immediate check could delete the task before it ever ran - deleting the very restart
# being waited for.
& ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" `
    'powershell -NoProfile -Command "Unregister-ScheduledTask -TaskName DraugrSshdRestart -Confirm:$false -ErrorAction SilentlyContinue"' 2>&1 | Out-Null

# --- the tunnel key's permitopen ---------------------------------------------------------
# The supervisor's -L 127.0.0.1:18022:127.0.0.1:22 is what lets Draugr's git and data commands
# reach this VM, and the restricted tunnel key may only open forwards its permitopen names.
$tunnelKeyChanged = $false
if (-not (Test-Path "$TunnelKey.pub")) {
    Warn "no tunnel public key at $TunnelKey.pub - skipping; the $ForwardPort forward will be refused"
} else {
    $null = Copy-ToGuest "$TunnelKey.pub" 'draugr_tunnel.pub'
    $rc = Invoke-GuestScript 'install-tunnel-key.ps1' '-PubKeyFile C:\Windows\Temp\draugr_tunnel.pub'
    $tunnelKeyChanged = ($rc -eq 0) -and (Test-Changed $script:guestOut)
    Phase 'tunnel key' $(if ($rc -ne 0) { "FAILED ($rc)" }
                         elseif ($tunnelKeyChanged) { 'permitopen set' }
                         else { 'permitopen already set' })
}

# --- the forward the key's options govern -------------------------------------------------
# A LIVE SUPERVISOR DOES NOT SEE THE NEW OPTIONS. sshd binds a key's permitopen at
# authentication time and keeps it for the life of the session, so widening the list leaves an
# already-connected tunnel refusing the newly permitted port - and refusing it QUIETLY, because
# the listener stays bound and the refusal is written only to ssh's own stderr.
#
# MEASURED: `dr-forge doctor --deep` reported 9 of 10 links green and blamed the
# mound, while the supervisor's own log held the answer -
#
#     ssh: channel 7: open failed: administratively prohibited: open failed
#
# Restarting the guest's sshd does NOT clear it either: Windows OpenSSH serves each connection
# from its own sshd.exe, and that session survived three restarts with its stale options intact.
# The supervisor's recovery path is its own loop - end its ssh child and it logs "ssh exited",
# reconnects within ten seconds and re-authenticates against the file as it now is.
function Get-ForwardOwner {
    $c = Get-NetTCPConnection -LocalPort $ForwardPort -State Listen -EA SilentlyContinue |
         Select-Object -First 1
    if (-not $c) { return $null }
    $child = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.OwningProcess)" -EA SilentlyContinue
    if (-not $child) { return $null }
    $sup = Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ParentProcessId)" -EA SilentlyContinue
    $served = ''
    if ($sup -and $sup.CommandLine -match '-Vm\s+"?([^\s"]+)') { $served = $Matches[1] }
    elseif ($sup) {
        # A supervisor started by a logon task runs in session 0 and its command line is not
        # readable from here; it writes its VM into a claim file, trusted only when the pid in
        # it is the process actually holding the forward.
        $claim = Join-Path $env:LOCALAPPDATA 'Draugr\forge-tunnel.claim'
        if (Test-Path $claim) {
            $cl = @(Get-Content $claim -ErrorAction SilentlyContinue)
            if ($cl.Count -ge 2 -and ([int]($cl[0].Trim())) -eq $sup.ProcessId) { $served = $cl[1].Trim() }
        }
    }
    return @{ ChildPid = $child.ProcessId; Vm = $served }
}

if ($tunnelKeyChanged) {
    $own = Get-ForwardOwner
    if (-not $own) {
        Phase 'tunnel forward' 'none up - the new options apply to the next one'
    } elseif ($own.Vm -and ($own.Vm -ne $Vm)) {
        # Ending someone else's tunnel is not this command's business.
        Phase 'tunnel forward' "held for '$($own.Vm)', not '$Vm' - left alone"
    } elseif (-not $own.Vm) {
        Warn "the key's options moved, but which VM holds $ForwardPort cannot be read"
        Warn 'leaving it alone; if git or data cannot reach the guest, run:  dr-forge up'
    } else {
        Stop-Process -Id $own.ChildPid -Force -ErrorAction SilentlyContinue
        Phase 'tunnel forward' 'supervisor nudged, so it re-reads the key options'
    }
}

# --- the WSL key, which is what the ssh_config alias uses ---------------------------------
# A SEPARATE key from this script's admin one: ssh refuses a key read off /mnt/c, where Windows
# files present as world-readable, and a second credential can be revoked without touching the
# first. dr-setup --forge mints it; authorising it is this phase, and without it the alias
# resolves perfectly and then cannot log in.
if (-not $WslPubKey) {
    Warn 'no WSL public key was passed - dr-sync and dr-data will not be able to log in'
    Warn 'mint one and write the alias with:  dr-setup --forge'
} elseif (-not (Test-Path $WslPubKey)) {
    Warn "no WSL public key at $WslPubKey - skipping"
    Warn 'mint one with:  dr-setup --forge'
} else {
    $null = Copy-ToGuest $WslPubKey 'draugr_forge_wsl.pub'
    $rc = Invoke-GuestScript 'authorize-key.ps1' '-PubKeyFile C:\Windows\Temp\draugr_forge_wsl.pub'
    Phase 'wsl key' $(if ($rc -ne 0) { "FAILED ($rc)" }
                      elseif (Test-Changed $script:guestOut) { 'authorised in the guest' }
                      else { 'already authorised' })
}

# --- the two files a layered VM pays twice for -------------------------------------------
# A differencing child grows by every block ever WRITTEN and never gives one back, and the
# block is 2 MB - so a 4 KB change to a file living in the parent costs 2 MB, and scattered
# small writes are amplified enormously. MEASURED inside ue-427-test: a 31.0 GiB
# child over a 21.6 GiB parent, while everything written since the VM was created came to only
# 6.63 GiB across 3,907 files. The gap was amplification, not any one file.
#
# So this targets what writes OFTEN and in SCATTERED PLACES: scheduled defrag, which rewrites
# the volume for a contiguity the guest cannot influence; SysMain, which traces launches a
# build VM does not make; and System Restore, which is a rollback mechanism inside a VM that
# already has one. The pagefile and hibernation are handled too, and both turned out to be
# non-problems when measured - see reduce-churn.ps1.
#
# IT IS A PER-VM FIX ON PURPOSE. These could live in a base image, but then every VM already
# built on an existing layer would need the whole chain rebuilt to get them. Here they apply to
# any VM, on any layer, at any time - which is the difference between a fix and a migration.
#
# It stops the growth and reclaims nothing: blocks already in the child stay until the chain is
# flattened or the VM rebuilt.
$churnReboot = $false
if ($NoTune) {
    Phase 'disk churn' 'skipped (-NoTune)'
} else {
    # The ceiling defaults to the VM's own RAM, from the daemon rather than guessed.
    $pfMax = $PageFileMaxMb
    if ($pfMax -le 0) {
        $pfMax = 8192
        try { if ($st.ramMb) { $pfMax = [int]$st.ramMb } } catch { }
    }
    if ($pfMax -lt $PageFileInitialMb) { $pfMax = $PageFileInitialMb }
    # Copied in under a fixed name, so the guest-side argument needs no quoting either.
    $churnArgs = "-PageFileInitialMb $PageFileInitialMb -PageFileMaxMb $pfMax"
    if ($NoScanFile) {
        if (Test-Path -LiteralPath $NoScanFile) {
            $null = Copy-ToGuest $NoScanFile 'draugr_noscan.txt'
            $churnArgs += ' -NoScanFile C:\Windows\Temp\draugr_noscan.txt'
        } else {
            Warn "no Defender exclusion list at $NoScanFile - skipping that step"
        }
    }
    $rc = Invoke-GuestScript 'reduce-churn.ps1' $churnArgs
    $churnReboot = ($rc -eq 0) -and ($script:guestOut -match 'DRAUGR_REBOOT=1')
    # The guest script's own lines are printed above this by Invoke-GuestScript, and there are
    # five items now - too many to restate on one line, and restating them is how a summary
    # starts disagreeing with the detail it sits under.
    Phase 'disk churn' $(if ($rc -ne 0) { "FAILED ($rc)" }
                         elseif (Test-Changed $script:guestOut) { 'applied - detail above' }
                         else { 'already tuned' })
}

# --- the desktop camera --------------------------------------------------------------------
# A LAYER-0 COMPONENT, APPLIED PER VM, for exactly the reason the churn phase is: layer-0 is
# specified to carry it unconditionally (docs/FORGE.md, "Layer-0's contents are judged per
# item"), but a VM built on a layer that predates it would otherwise have no camera at all, and
# rebuilding a frozen chain to add one is a migration rather than a fix.
#
# NOT OPTIONAL, unlike the churn phase. An agent cannot look at a screen, so a screenshot it can
# pull back is the only way anything visual gets checked - including its own work. What this
# installs is the generic mechanism; nothing about it is engine-specific.
#
# It registers a task with an INTERACTIVE principal, so it photographs whatever the autologin
# session has on screen. That is the point of it rather than a surprise, and it is written down
# where someone deciding whether to enable the forge will see it: docs/SECURITY.md, "The forge,
# if you turn it on".
$rc = Invoke-GuestScript 'install-shot.ps1'
Phase 'desktop camera' $(if ($rc -ne 0) { "FAILED ($rc)" }
                         elseif (Test-Changed $script:guestOut) { 'installed - run draugr-shot in the guest' }
                         else { 'already installed' })

# --- the computer name -------------------------------------------------------------------
# LAST of the guest changes, because it needs a reboot: doing it here means one disruption at
# the end rather than one in the middle, shared with the pagefile change above.
$rc = Invoke-GuestScript 'set-computer-name.ps1' "-Name $Vm"
# Whether a reboot is OWED is the thing to get right: this is the only change that needs one, so
# advising it when the name was already correct sends someone to restart a VM for nothing.
$nameChanged = ($rc -eq 0) -and (Test-Changed $script:guestOut)
Phase 'computer name' $(if ($rc -ne 0) { "FAILED ($rc)" }
                        elseif ($nameChanged) { 'set - takes effect at the next boot' }
                        else { "already $Vm" })

# --- the guest's temp copies -------------------------------------------------------------
& ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" `
    'powershell -NoProfile -Command "Remove-Item C:\Windows\Temp\harden-sshd.ps1, C:\Windows\Temp\authorize-key.ps1, C:\Windows\Temp\install-tunnel-key.ps1, C:\Windows\Temp\set-computer-name.ps1, C:\Windows\Temp\reduce-churn.ps1, C:\Windows\Temp\draugr_noscan.txt, C:\Windows\Temp\draugr_tunnel.pub, C:\Windows\Temp\draugr_forge_wsl.pub -Force -ErrorAction SilentlyContinue"' 2>&1 | Out-Null

Write-Host ''
# NOTHING IS REBOOTED FOR NOTHING, and the reasons are listed rather than counted: two changes
# here can owe a reboot and the rest cannot, so a run that changed only the hibernation flag -
# which takes effect immediately - must not advise one. That is the same distinction the guest
# scripts' DRAUGR_CHANGED exists for, one level up. Including when -Restart was passed: "I asked
# for a restart" is not a reason to interrupt a guest that gained nothing by it.
$rebootFor = @()
if ($churnReboot) { $rebootFor += 'the pagefile size' }
if ($nameChanged) { $rebootFor += 'the computer name' }
if ($rebootFor.Count -eq 0) {
    Write-Host 'Nothing here needs a reboot.'
} elseif ($Restart) {
    # Agreement, because one item is the common case and "the pagefile size take effect" is
    # the kind of wrong that makes a reader doubt the rest of the output.
    $takes = if ($rebootFor.Count -eq 1) { 'takes' } else { 'take' }
    Write-Host "restarting the guest so $($rebootFor -join ' and ') $takes effect..."
    & ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" 'shutdown /r /t 0' 2>&1 | Out-Null
    Start-Sleep -Seconds 15
    if (Wait-Sshd $TimeoutSec) {
        # `hostname`, NOT `echo %COMPUTERNAME%`, and the difference is the TRANSPORT rather
        # than the guest. Windows OpenSSH re-quotes the command it sends, so the remote cmd
        # receives a trailing `"` - and `echo` prints its argument literally, stray quote and
        # all. MEASURED: the name came back as `TEST"` and this phase reported a
        # rename that had plainly worked as one that had not, which is the one thing a
        # verification step must never do. `hostname` ignores the junk argument.
        #
        # The other `cmd /c echo DRAUGR_*` round trips in lib/forge are safe from this because
        # they MATCH a marker as a substring rather than capture a value. Anything that starts
        # reading a value back needs this form, not theirs.
        $name = (& ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" 'cmd /c hostname' 2>&1) -join ''
        Phase 'after reboot' "the guest calls itself $($name.Trim())"
    } else {
        Warn 'the guest did not come back within the timeout - look at it with:  dr-forge screen'
    }
} else {
    Write-Host "Waiting on a reboot: $($rebootFor -join ', '). --restart does that for you."
}

Write-Host ''
Write-Host 'Verify the whole chain from WSL:  dr-forge doctor --deep'
exit 0
