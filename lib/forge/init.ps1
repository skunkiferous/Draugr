# init.ps1: make a REGISTERED forge VM usable for Draugr.
#
# ==> bin/dr-forge RUNS IT, ON THE WINDOWS SIDE. You do not type it. <==
#
# WHY THERE IS WORK AFTER A VM EXISTS. A VM on a frozen layer boots. But it
# needs three things that are on its OWN writable disk, not in the layer below.
# Thus each VM on the same parent needs them again:
#
#   its computer name            from the base image, so each VM says "layer-0"
#   the password value of sshd   Windows OpenSSH accepts passwords by DEFAULT
#   its authorized keys          the permitopen of the tunnel key, and the key of WSL
#
# From memory, you forget one. Tests found this the hard way. Each of the three
# was found by its symptom. A VM called itself `layer-0`. A guest offered
# passwords to a sandbox that was able to reach it. The tunnel key was not able
# to open a forward.
#
# ONE VERB, because nobody wants one of these alone. A VM with keys but no name
# is the trap. dr-sync cannot reach a VM with a name but no authorized WSL key.
# A VM with both but no screen server breaks `dr-forge screen`.
#
# IT IS IDEMPOTENT. Each phase tests what is already true, and says so. A second
# run on a VM that is already set up changes nothing. The tests also use that.
#
# WHAT IT DOES NOT DO:
#   - create the VM. It makes an existing one usable. The layer mechanism creates VMs
#     (docs/FORGE.md, "The layer mechanism as a command: dr-layer").
#   - start the AppSandbox daemon. That needs elevation, and Draugr does not cross that line.
#     It says what to run.
#   - write the ssh_config alias. `dr-setup --forge` does that, with one `Host *.forge` block for
#     all VMs, because the forwarded port is pinned (docs/FORGE.md, "The pinned port has a price").
#
# EXIT CODES, so that bin/dr-forge can say something useful, and does not only
# repeat a log:
#   0 all applied   2 wrong use   10 no daemon   11 no such VM, or sshd never answered
#   13 a guest phase failed badly
param(
    [string]$Vm          = '',
    [string]$AdminKey    = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [string]$TunnelKey   = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519",
    [string]$WslPubKey   = '',
    [int]   $ForwardPort = 18022,
    # A RANGE, not a size. The floor is what Windows selected itself (a TEST
    # inside ue-427-test: 512 MB allocated, peak use 71 MB). Thus a pin there
    # adds nothing and removes nothing. The ceiling is the useful part. It
    # limits the cost for a differencing child. 0 means "the own RAM of the VM",
    # read from the daemon, not guessed. WMI needs both numbers. That is the
    # only reason for a floor.
    [int]   $PageFileInitialMb = 512,
    [int]   $PageFileMaxMb     = 0,
    # A FILE of guest paths, one on each line, that the person declares Defender
    # does not scan. It is CHECKED in the guest, and never applied. A file, not
    # a list argument, because the paths have spaces and this value goes through
    # four parsers.
    [string]$NoScanFile        = '',
    [switch]$NoTune,
    [switch]$Restart,
    [int]   $TimeoutSec  = 300
)

# No [Parameter()] attribute above, and not for style. One makes this script
# cmdlet-bound, and then $PSScriptRoot is EMPTY while PowerShell evaluates the
# defaults. Thus $AdminKey silently becomes a bare file name. That cost an
# evening in another script of this family. The code validates the values
# itself.
if (-not $Vm) { Write-Host 'init.ps1: -Vm is required' -ForegroundColor Red; exit 2 }

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$guestDir = Join-Path $PSScriptRoot 'guest'
# The cmd.exe wrapper that proves a guest script is there, and the test for a
# keys-only sshd. Both were weaker versions of themselves in this file: the run
# was `powershell -File <path>` with no proof, and keys-only was "the offered
# list has no 'password' in it". See guestexec.ps1 and sshauth.ps1.
. (Join-Path $PSScriptRoot 'guestexec.ps1')
. (Join-Path $PSScriptRoot 'sshauth.ps1')

function Phase([string]$n, [string]$s) { Write-Host ("  {0,-22} {1}" -f $n, $s) }

# WHAT A FAILED PHASE MEANT FOR THE EXIT CODE: nothing. Each phase printed
# `FAILED (<rc>)` into its row and the script ended with `exit 0`, so
# `dr-forge init` answered "'<vm>' is set up. Re-running changes nothing" over a
# run in which the password logins stayed on and the restricted tunnel key never
# arrived. A row in a table that nothing reads is not a result. These are
# collected and decide the exit code at the end of the file.
#
# NOT EVERY PHASE IS IN HERE. The disk-churn phase tunes a disk, and a guest
# that refuses the tuning is still a correct guest - that is also what -NoTune
# exists for. A phase that was SKIPPED because its input was not given (no
# tunnel key, no WSL key) is a declaration by absence, not a failure.
$script:failed = @()
function Add-FailedPhase([string]$n) { $script:failed += $n }
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
# By effect, not by the file. A host.json with nothing behind it means that the
# last daemon DIED, and did not exit. With only the file, the code connects to a
# port that nobody holds.
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) {
    Die 10 'the AppSandbox daemon does not run.' 'start it elevated:  AppSandbox.exe --headless'
}
$h = Get-Content $hostJson -Raw | ConvertFrom-Json
function Asb([string]$Method, [string]$Path) {
    $a = @{ Uri = "$($h.endpoint)/v1$Path"; TimeoutSec = 30; Method = $Method
            Headers = @{ Authorization = "Bearer $($h.token)" } }
    if ($Method -eq 'POST') { $a.Body = '{}'; $a.ContentType = 'application/json' }
    Invoke-RestMethod @a
}
try { $null = Asb GET '/version' } catch {
    Die 10 'host.json is there, but nothing answers. The last daemon died, and did not exit.' `
        'start AppSandbox again, then run this again.'
}
Phase 'daemon' 'up'

# --- the VM ------------------------------------------------------------------------------
# The error lists the registered VMs, because "no such VM" with no list is the
# least useful error. The name is usually a typo, or a layer suffix.
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
# THE CODE READS THE PORT AGAIN AT EACH ATTEMPT. Two tests showed this. vms.cfg
# said 57351 while the guest used 54501. The API answered 57351, and minutes
# later 57589, with sshState 2 all the time. Only a command that comes back
# proves that a port is correct.
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
        'the boot of the guest is possibly not complete, or the admin key is not authorized there yet. Run this again.'
}
Phase 'sshd' "answers on port $script:port"

function Get-SshArgs { @('-i', $AdminKey, '-p', $script:port, '-o', 'IdentitiesOnly=yes',
                      '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
                      '-o', "HostKeyAlias=draugr-$Vm", '-o', 'ConnectTimeout=20') }

# --- the directory this run owns in the guest ---------------------------------------------
# Made HERE, because sshd has just answered a real command and nothing has been
# copied yet. Everything this run puts into the guest goes in here and nowhere
# else, and the last phase removes the whole directory. See guestexec.ps1 for
# why a directory, and why two spellings of its path.
#
# A FAILURE IS FATAL. Without it, each copy below would land in a directory
# that does not exist, and the run would report a list of failures that all
# have one cause.
$script:gdir = New-GuestRunDir
& ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" (Get-GuestMkdirCommand $script:gdir.Win) 2>&1 |
    ForEach-Object { Note $_ }
if ($LASTEXITCODE -ne 0) {
    Die 13 "could not make $($script:gdir.Win) in the guest (ssh $LASTEXITCODE)." `
        'Nothing was copied in, and nothing was changed.'
}
Phase 'guest temp' $script:gdir.Name

# A guest script, copied in and run as a CHILD process with -ExecutionPolicy
# Bypass -File. Not dot-invoked. The own policy of the guest is Restricted, so
# it refuses `& script.ps1` inside a running session with "running scripts is
# disabled on this system". A test showed this.
#
# The code CAPTURES the output into $script:guestOut, and prints it. Thus the
# caller can tell whether the script changed something. Each guest script ends
# with DRAUGR_CHANGED=0 or =1. A TEST on the first idempotent run: each phase
# said "written", "authorized", "set (applies at the next boot)", but each
# script below said "nothing to do". The run ended with advice to reboot for a
# rename that did not happen. A summary that cannot tell those apart is the one
# defect that an idempotent script must not have.
$script:guestOut = ''
function Invoke-GuestScript([string]$Name, [string]$ScriptArgs = '') {
    $script:guestOut = ''
    $local = Join-Path $guestDir $Name
    if (-not (Test-Path $local)) { Warn "missing: $local"; return 1 }
    $remote = "$($script:gdir.Win)\$Name"
    & scp.exe @(Get-SshArgs | ForEach-Object { if ($_ -eq '-p') { '-P' } else { $_ } }) `
        -- $local "forge@127.0.0.1:$($script:gdir.Scp)/$Name" 2>&1 | ForEach-Object { Note $_ }
    # THE COPY DECIDES WHETHER THE RUN MAY HAPPEN. Its status was discarded,
    # and the line below ran the destination anyway. When the destination was a
    # fixed path shared by every run of every VM, a failed copy left whatever an
    # earlier run had put there — a stale script that runs, succeeds, and
    # reports its result as this phase's. The phase it belongs to may be the one
    # that turns password logins off. The run directory makes that impossible
    # now; this check makes the failure say so at once, and in the right words.
    if ($LASTEXITCODE -ne 0) {
        Warn "the copy of $Name into the guest failed ($LASTEXITCODE), so it was not run"
        return 1
    }
    $out = & ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" (Get-GuestRunCommand $remote $ScriptArgs) 2>&1
    $rc = $LASTEXITCODE
    $script:guestOut = (@($out) | ForEach-Object { "$_" }) -join "`n"
    # The marker is for this script, not for a reader, so the code does not
    # print it.
    @($out) | Where-Object { "$_" -notmatch 'DRAUGR_CHANGED=' } | ForEach-Object { Note $_ }
    # 127 comes from the guest's own cmd.exe, and only when the file is not at
    # $remote although scp reported success. That is a defect of THIS script,
    # not a state of the guest, and nothing below the call was tested. It is
    # fatal, and not one more code for each caller to judge differently.
    if ($rc -eq 127) {
        Die 13 ("$Name never ran: it is not at $remote in the guest, although the copy " +
                'reported success. Nothing after that point was applied.') `
            "Run it again. If it repeats, look in the guest at $($script:gdir.Win):  dr-forge screen"
    }
    return $rc
}

# Did it change something? UNKNOWN COUNTS AS CHANGED. A script that said nothing
# is not a script that did nothing. A claim of "already" with no evidence makes
# a summary lie again.
function Test-Changed([string]$Text) { -not ($Text -match 'DRAUGR_CHANGED=0') }

# A data file, not a script: the guest scripts above read these as an argument.
# Into the run directory, like everything else, so that the argument cannot
# name a file from an earlier run. The caller must still read the status - two
# of these files are PUBLIC KEYS that a script then authorizes.
function Copy-ToGuest([string]$Local, [string]$RemoteName) {
    & scp.exe @(Get-SshArgs | ForEach-Object { if ($_ -eq '-p') { '-P' } else { $_ } }) `
        -- $Local "forge@127.0.0.1:$($script:gdir.Scp)/$RemoteName" 2>&1 | ForEach-Object { Note $_ }
    return $LASTEXITCODE
}

# What the server says that it accepts, asked without a password. Connect with
# pubkey off and BatchMode on, and ssh -v prints the list before it fails.
function Get-Offered {
    $out = & ssh.exe -v @(Get-SshArgs) -o PubkeyAuthentication=no `
               -o PreferredAuthentications=password "forge@127.0.0.1" exit 2>&1
    $l = @($out | Select-String 'Authentications that can continue' | ForEach-Object { $_.Line })
    if ($l) { (($l -join ' ') -replace '.*continue:\s*', '').Trim() } else { '(none offered)' }
}

# WAIT FOR THE EFFECT, NOT FOR THE REQUEST. A TEST on the first run on a really
# new VM: the configuration was rewritten correctly, `sshd -T` agreed, and the
# restart task started. But the next test still said
# "publickey,password,keyboard-interactive". Thus the run warned that the
# restart did not work. Minutes later, the guest was keys-only. Only the measure
# was wrong. The old listener still ran, because the scheduler had not taken the
# task yet. A plain wait for sshd got its answer at once FROM THAT OLD
# LISTENER.
#
# ONLY POSITIVE EVIDENCE. During the restart, the connection is refused, and
# NOTHING is offered. Never read "nothing" as "passwords are off". This phase
# exists to prevent exactly that false green. Thus each round first needs an
# answer of sshd to a real command. Then it needs a list of offers that is not
# empty, and has no password.
$script:offered = '(not measured)'
function Confirm-KeysOnly([int]$Seconds) {
    $t0 = Get-Date
    do {
        if (Wait-Sshd 30) {
            $o = Get-Offered
            if ($o -ne '(none offered)') {
                $script:offered = $o
                # Every method offered must be publickey. `-notmatch
                # 'password'` passed a server that still offered
                # keyboard-interactive. See sshauth.ps1.
                if (Test-KeysOnlyList $o) { return $true }
            }
        }
        Start-Sleep -Seconds 5
    } while (((Get-Date) - $t0).TotalSeconds -lt $Seconds)
    return $false
}

# --- sshd, off passwords -----------------------------------------------------------------
# FIRST of the guest changes, because it is about security. The gateway mound
# gets an sbx rule that can reach this sshd. Thus a sandbox can try to guess a
# password login here. Tested from OUTSIDE after that. The guest can only report
# what its configuration file says, and the question is what the running
# listener accepts.
Phase 'sshd auth' "before: $(Get-Offered)"
$rc = Invoke-GuestScript 'harden-sshd.ps1'
if ($rc -ne 0) { Note "the session was cut ($rc). That is expected, because sshd restarts below it" }
if (Confirm-KeysOnly 120) {
    Phase 'sshd auth' "now offers: $script:offered"
} elseif (-not (Wait-Sshd 60)) {
    Die 13 'sshd did not come back after the restart.' `
        'get in through the screen, and run:  Start-Service sshd'
} else {
    # THE PHASE THAT MATTERS MOST, and it only warned. A sandbox with the
    # gateway rule can reach this sshd, so a guest that still offers a password
    # method is the one outcome that must not end in a success.
    Warn "still offering: $script:offered, two minutes after the restart request"
    Warn 'look at C:\ProgramData\ssh\sshd_config in the guest, and whether the task ran:'
    Warn '  Get-ScheduledTaskInfo -TaskName DraugrSshdRestart'
    Add-FailedPhase 'sshd auth (a password method is still offered)'
}
# The one-shot task did its job. If it stays, it is clutter that looks like a
# job. THE CODE REMOVES IT ONLY AFTER THE WAIT ABOVE, and that order is
# necessary. Start-ScheduledTask returns at once after the scheduler accepts the
# request. Thus a removal after one quick test can delete the task before it
# ran, and that deletes the restart that the code waits for.
& ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" `
    'powershell -NoProfile -Command "Unregister-ScheduledTask -TaskName DraugrSshdRestart -Confirm:$false -ErrorAction SilentlyContinue"' 2>&1 | Out-Null

# --- the permitopen of the tunnel key -----------------------------------------------------
# The -L 127.0.0.1:18022:127.0.0.1:22 of the supervisor lets the git and data
# commands of Draugr reach this VM. The restricted tunnel key can open only the
# forwards that its permitopen names.
$tunnelKeyChanged = $false
if (-not (Test-Path "$TunnelKey.pub")) {
    Warn "no tunnel public key at $TunnelKey.pub. Skipped. The $ForwardPort forward is refused"
} else {
    # A STALE PUBLIC KEY IS WORSE THAN NO KEY. The destination used to be the
    # fixed C:\Windows\Temp\draugr_tunnel.pub and the status of this copy was
    # discarded (`$null =`), so a failed copy left the .pub of an earlier run —
    # or of another VM — in place, and the line below authorized THAT key with
    # the permitopen, then reported 'permitopen set'. The 127 wrapper cannot see
    # this one: a data file is not run, it is read as an argument. Hence both
    # halves: the run directory, which is empty until this run fills it, and
    # this check.
    $crc = Copy-ToGuest "$TunnelKey.pub" 'draugr_tunnel.pub'
    if ($crc -ne 0) {
        Warn "the copy of $TunnelKey.pub into the guest failed ($crc)"
        Warn 'no key was authorized, because the file at the destination can be an older one'
        Phase 'tunnel key' "FAILED (the copy, $crc)"
        Add-FailedPhase 'tunnel key'
    } else {
        $rc = Invoke-GuestScript 'install-tunnel-key.ps1' "-PubKeyFile $($script:gdir.Win)\draugr_tunnel.pub"
        $tunnelKeyChanged = ($rc -eq 0) -and (Test-Changed $script:guestOut)
        Phase 'tunnel key' $(if ($rc -ne 0) { "FAILED ($rc)" }
                             elseif ($tunnelKeyChanged) { 'permitopen set' }
                             else { 'permitopen already set' })
        if ($rc -ne 0) { Add-FailedPhase 'tunnel key' }
    }
}

# --- the forward that the options of the key control ------------------------------------
# A LIVE SUPERVISOR DOES NOT SEE THE NEW OPTIONS. sshd binds the permitopen of a
# key at authentication, and keeps it for the life of the session. Thus a larger
# list leaves a connected tunnel that refuses the newly allowed port. It refuses
# QUIETLY, because the listener stays bound, and the refusal goes only to the
# own stderr of ssh.
#
# A TEST SHOWED THIS. `dr-forge doctor --deep` reported 9 of 10 links green, and
# blamed the mound, while the log of the supervisor had the answer:
#
#     ssh: channel 7: open failed: administratively prohibited: open failed
#
# A restart of the sshd of the guest does NOT clear it either. Windows OpenSSH
# serves each connection from its own sshd.exe, and that session survived three
# restarts with its old options. The recovery path of the supervisor is its own
# loop. End its ssh child, and it logs "ssh exited", connects again within ten
# seconds, and authenticates against the current file.
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
        # A supervisor from a logon task runs in session 0, and this code cannot
        # read its command line. It writes its VM into a claim file. The code
        # trusts that file only for a pid that is the process that holds the
        # forward.
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
        Phase 'tunnel forward' 'none runs. The new options apply to the next one'
    } elseif ($own.Vm -and ($own.Vm -ne $Vm)) {
        # This command does not end the tunnel of somebody else.
        Phase 'tunnel forward' "held for '$($own.Vm)', not '$Vm'. Not changed"
    } elseif (-not $own.Vm) {
        Warn "the options of the key changed, but the code cannot read which VM holds $ForwardPort"
        Warn 'not changed. If git or data cannot reach the guest, run:  dr-forge up'
    } else {
        Stop-Process -Id $own.ChildPid -Force -ErrorAction SilentlyContinue
        Phase 'tunnel forward' 'supervisor restarted, so that it reads the key options again'
    }
}

# --- the WSL key, which the ssh_config alias uses ----------------------------------------
# A SEPARATE key, not the admin key of this script. ssh refuses a key from
# /mnt/c, where Windows files look world-readable. You can also revoke a second
# credential, and not touch the first. dr-setup --forge makes it. This phase
# authorizes it. Without it, the alias resolves, and then cannot log in.
if (-not $WslPubKey) {
    Warn 'no WSL public key given. dr-sync and dr-data cannot log in'
    Warn 'make one, and write the alias, with:  dr-setup --forge'
} elseif (-not (Test-Path $WslPubKey)) {
    Warn "no WSL public key at $WslPubKey. Skipped"
    Warn 'make one with:  dr-setup --forge'
} else {
    # The same as the tunnel key above, and for the same reason: this phase
    # AUTHORIZES the file at a fixed destination, so a copy whose status
    # nobody read can hand an older key to authorize-key.ps1.
    $crc = Copy-ToGuest $WslPubKey 'draugr_forge_wsl.pub'
    if ($crc -ne 0) {
        Warn "the copy of $WslPubKey into the guest failed ($crc)"
        Warn 'no key was authorized, because the file at the destination can be an older one'
        Phase 'wsl key' "FAILED (the copy, $crc)"
        Add-FailedPhase 'wsl key'
    } else {
        $rc = Invoke-GuestScript 'authorize-key.ps1' "-PubKeyFile $($script:gdir.Win)\draugr_forge_wsl.pub"
        Phase 'wsl key' $(if ($rc -ne 0) { "FAILED ($rc)" }
                          elseif (Test-Changed $script:guestOut) { 'authorized in the guest' }
                          else { 'already authorized' })
        if ($rc -ne 0) { Add-FailedPhase 'wsl key' }
    }
}

# --- the writes that a layered VM pays for two times ------------------------------------
# A differencing child grows by each block that was ever WRITTEN, and never
# gives one back. The block is 2 MB. Thus a change of 4 KB to a file in the
# parent costs 2 MB, and small scattered writes become very much larger. A TEST
# inside ue-427-test: a child of 31.0 GiB over a parent of 21.6 GiB. But all
# that was written since the creation of the VM was only 6.63 GiB in 3,907
# files. The difference was amplification, not one file.
#
# Thus this targets what writes OFTEN and in SCATTERED PLACES. Scheduled defrag
# rewrites the volume for an order that the guest cannot change. SysMain traces
# program starts that a build VM does not make. System Restore is a rollback
# mechanism inside a VM that already has one. It also handles the
# pagefile and hibernation. Tests found that neither was a problem. See
# reduce-churn.ps1.
#
# IT IS A FIX FOR EACH VM, ON PURPOSE. These can be in a base image. But then
# each VM that already exists on a layer needs a rebuild of the whole chain to
# get them. Here they apply to each VM, on each layer, at each time. That is the
# difference between a fix and a migration.
#
# It stops the growth, and frees nothing. Blocks already in the child stay until
# the chain is flattened, or the VM is built again.
$churnReboot = $false
if ($NoTune) {
    Phase 'disk churn' 'skipped (-NoTune)'
} else {
    # The default ceiling is the own RAM of the VM, from the daemon, not
    # guessed.
    $pfMax = $PageFileMaxMb
    if ($pfMax -le 0) {
        $pfMax = 8192
        try { if ($st.ramMb) { $pfMax = [int]$st.ramMb } } catch { }
    }
    if ($pfMax -lt $PageFileInitialMb) { $pfMax = $PageFileInitialMb }
    # Copied in with a fixed name, so that the argument on the guest side needs
    # no quotes.
    $churnArgs = "-PageFileInitialMb $PageFileInitialMb -PageFileMaxMb $pfMax"
    if ($NoScanFile) {
        if (Test-Path -LiteralPath $NoScanFile) {
            # The third fixed destination. This one is only READ, so a stale
            # file means a report about the wrong paths rather than a wrong
            # key - but a report about the wrong paths is the thing this
            # declaration exists to prevent. Without the file, the guest
            # script says that nothing was declared.
            $crc = Copy-ToGuest $NoScanFile 'draugr_noscan.txt'
            if ($crc -ne 0) {
                Warn "the copy of $NoScanFile into the guest failed ($crc)"
                Warn 'the Defender check is skipped: an older list would report the wrong paths'
            } else {
                $churnArgs += " -NoScanFile $($script:gdir.Win)\draugr_noscan.txt"
            }
        } else {
            Warn "no Defender list at $NoScanFile. That check is skipped"
        }
    }
    $rc = Invoke-GuestScript 'reduce-churn.ps1' $churnArgs
    $churnReboot = ($rc -eq 0) -and ($script:guestOut -match 'DRAUGR_REBOOT=1')
    # Invoke-GuestScript prints the lines of the guest script above this. There
    # are five items now, too many for one line. A summary that repeats them
    # starts to disagree with the detail above it.
    Phase 'disk churn' $(if ($rc -ne 0) { "FAILED ($rc)" }
                         elseif (Test-Changed $script:guestOut) { 'applied. Detail above' }
                         else { 'already tuned' })
}

# --- the desktop camera --------------------------------------------------------------------
# A LAYER-0 COMPONENT, APPLIED FOR EACH VM, for exactly the reason of the churn
# phase. The specification says that layer-0 always has it (docs/FORGE.md,
# "Layer-0's contents are judged per item"). But a VM on a layer that is older
# than it has no camera otherwise. A rebuild of a frozen chain to add one is a
# migration, not a fix.
#
# NOT OPTIONAL, different from the churn phase. An agent cannot look at a
# screen. A screenshot that it can get is the only way to test something
# visual, also its own work. This installs the general mechanism. Nothing in it
# is for one engine.
#
# It registers a task with an INTERACTIVE principal. Thus it takes a picture of
# what the autologin session has on the screen. That is its purpose, not a
# surprise, and it is written where a person who decides about the forge sees
# it: docs/SECURITY.md, "The forge, if you turn it on".
$rc = Invoke-GuestScript 'install-shot.ps1'
Phase 'desktop camera' $(if ($rc -ne 0) { "FAILED ($rc)" }
                         elseif (Test-Changed $script:guestOut) { 'installed. Run draugr-shot in the guest' }
                         else { 'already installed' })
# Required, for the reason in the comment above: without it an agent has no way
# at all to see what it did to a screen.
if ($rc -ne 0) { Add-FailedPhase 'desktop camera' }

# --- the computer name -------------------------------------------------------------------
# LAST of the guest changes, because it needs a reboot. Here, that is one
# interruption at the end, not one in the middle, shared with the pagefile
# change above.
$rc = Invoke-GuestScript 'set-computer-name.ps1' "-Name $Vm"
# The code must know correctly whether a reboot is NEEDED. This is the only
# change that needs one. If the name was already correct, advice to reboot
# makes somebody restart a VM for nothing.
$nameChanged = ($rc -eq 0) -and (Test-Changed $script:guestOut)
Phase 'computer name' $(if ($rc -ne 0) { "FAILED ($rc)" }
                        elseif ($nameChanged) { 'set. It applies at the next boot' }
                        else { "already $Vm" })
if ($rc -ne 0) { Add-FailedPhase 'computer name' }

# --- the guest's temp copies -------------------------------------------------------------
# THE WHOLE DIRECTORY, AND NO LIST. This was a hand-written list of the eight
# fixed names, and a list is a second place to remember: a file added above and
# forgotten here stayed in the guest, including a public key. Now this run owns
# a directory, so the cleanup is the directory.
#
# Two of the files in it are public keys. They are not secret - that is what a
# .pub is - but they are a record of which credentials were offered to this
# guest, and they have no reason to stay.
#
# NOT fatal, and nothing reads its status: the run is finished here, and a
# leftover directory in Temp is not a failed setup. The next run makes its own.
& ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" `
    (Get-GuestRmdirCommand $script:gdir.Win) 2>&1 | Out-Null

Write-Host ''
# NO REBOOT FOR NOTHING. The code lists the reasons, and does not count them.
# Two changes here can need a reboot, and the others cannot. Thus a run that
# changed only the hibernation flag, which applies at once, must not advise one.
# That is the same difference as the DRAUGR_CHANGED of the guest scripts, one
# level up. Also with -Restart: "I asked for a restart" is no reason to
# interrupt a guest that gets nothing from it.
$rebootFor = @()
if ($churnReboot) { $rebootFor += 'the pagefile size' }
if ($nameChanged) { $rebootFor += 'the computer name' }
if ($rebootFor.Count -eq 0) {
    Write-Host 'Nothing here needs a reboot.'
} elseif ($Restart) {
    # Agreement of the verb, because one item is the usual case. "the pagefile
    # size apply" is the kind of error that makes a reader doubt the rest of the
    # output.
    $takes = if ($rebootFor.Count -eq 1) { 'applies' } else { 'apply' }
    Write-Host "restarting the guest, so that $($rebootFor -join ' and ') $takes..."
    & ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" 'shutdown /r /t 0' 2>&1 | Out-Null
    Start-Sleep -Seconds 15
    if (Wait-Sshd $TimeoutSec) {
        # `hostname`, NOT `echo %COMPUTERNAME%`. The difference is the
        # TRANSPORT, not the guest. Windows OpenSSH quotes the command again.
        # Thus the remote cmd gets a `"` at the end. `echo` prints its argument
        # literally, with the extra quote. A TEST SHOWED THIS: the name came
        # back as `TEST"`, and this phase reported a rename that clearly worked
        # as a failure. A test step must never do that. `hostname` ignores the
        # extra argument.
        #
        # The other `cmd /c echo DRAUGR_*` round trips in lib/forge are safe
        # from this, because they MATCH a marker as a substring, and do not
        # capture a value. Each new code that reads a value back needs this
        # form, not theirs.
        $name = (& ssh.exe -n @(Get-SshArgs) "forge@127.0.0.1" 'cmd /c hostname' 2>&1) -join ''
        Phase 'after reboot' "the guest calls itself $($name.Trim())"
    } else {
        Warn 'the guest did not come back within the timeout. Look at it with:  dr-forge screen'
    }
} else {
    Write-Host "A reboot is needed for: $($rebootFor -join ', '). --restart does it for you."
}

Write-Host ''
# THE ROWS ABOVE DECIDE THE EXIT CODE. See $script:failed near the top. 13 is
# the documented "a guest phase failed badly", which bin/dr-forge already turns
# into a refusal that names the detail above.
if ($script:failed.Count -gt 0) {
    Write-Host ("these phases did not succeed: " + ($script:failed -join ', ')) -ForegroundColor Red
    Write-Host '  Nothing here is destructive, so running it again is safe.'
    exit 13
}
Write-Host 'Test the whole chain from WSL:  dr-forge doctor --deep'
exit 0
