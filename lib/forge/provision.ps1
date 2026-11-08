# lib/forge/provision.ps1: build a forge base image from a new Windows 11 guest,
# in one run.
#
# ==> YOU DO NOT TYPE THIS. bin/dr-layer provision is the front end. <==
#
# Adopted from a manually written earlier script. All tests in these comments
# were made with it. See docs/FORGE.md, "Stage two: dr-layer provision".
#
# WHY THE HOST, and not the guest or the mound. The guest has no network
# adapter. Until the host starts the gateway mound and the ssh tunnel, the guest
# can reach nothing. Thus it cannot set itself up. That is a fact of principle,
# not a preference. Three of the five links are also on the host side (the
# AppSandbox daemon, the mound, the tunnel). Thus the host drives, and goes into
# the guest through ssh for the half of the guest.
#
# It is IDEMPOTENT everywhere. Each phase tests what is already true, and
# reports it, and does not do it again. Thus it is safe to run again after a
# failure, after a reboot, or only to see the state of a guest. -VerifyOnly
# changes nothing.
#
# IT CAN ALSO MAKE THE GUEST. Give -IsoPath, and phase 0 creates the VM and
# installs Windows in it, unattended. The network is already None, and an ssh
# key is already in place. Without -IsoPath, it never creates anything.
#
# WHAT IT CANNOT DO, and tells you to do:
#   - install AppSandbox, turn on the VirtualMachinePlatform Windows feature (that one needs a
#     reboot), or make a Windows 11 ISO. These three are all that a person must do before the
#     first run.
#   - set the network of an EXISTING VM to None. It reports the value, and refuses to continue
#     if it is wrong. A provisioned guest that still has its own way out puts a hole into the
#     base image. The API can change it (`edit`, while stopped), but this script does not. You
#     open a forge to a network yourself. A script never does that for you.
#   - sign in to anything. The Epic account, the engine, and Visual Studio are NOT part of a
#     base, on purpose (docs/FORGE.md, "What is a layer, not the base").
#
# EACH PHASE IS HERE NOW, and exactly one is off until you ask for it.
# -NetFxSource names the payload of `.NET Framework 3.5`. A person must take
# that file from a Windows ISO, because no route from this guest can fetch it.
# See that parameter.
#
# EXIT CODES:
#   0   done, or done with warnings
#   1   a phase failed. The summary tells which
#   2   a precondition or an argument is wrong, and nothing was built
#   4   the guest base is not complete, so the run stopped, and did not build on it
#   5   the guest has no way out, so nothing below could install
#
# A guest script that never arrived throws, and does not return a code. See
# Invoke-GuestScript, and the two defects in its header that tests found.

param(
    [string]$Vm = 'UE5-Test',
    # ---- phase 0, and ONLY phase 0. No -IsoPath, no VM creation. There is no default, on
    # purpose. Nothing can create a VM by accident.
    [string]$IsoPath,
    # Sizes. You can edit three of these later on a STOPPED VM (`edit` takes
    # ramMb, cpuCores, gpuMode, and networkMode), so a wrong value costs little.
    [int]$Ram = 8192,               # for the BUILD. A working forge wants ~48 GB. Edit it later.
    [int]$Cores = 8,
    # ---- -DiskGb IS THE ONE NUMBER THAT YOU CANNOT TAKE BACK, and it binds each layer above it.
    #
    #   * Nothing can ever resize THIS disk. `edit` does not accept hddGb, and no route resizes
    #     the own disk of a VM. A size that is too small costs a full new install.
    #   * A CHILD inherits this capacity. It can only GROW, never shrink. Thus this number is a
    #     FLOOR for each layer on top, not a ceiling. (From the source: vhdx_grow refuses a
    #     smaller size with E_INVALIDARG, and makes a larger one with ResizeVirtualDisk.
    #     create-from-template does exactly that to its child, and does not touch the parent.)
    #   * The OWN snapshots and branches of AppSandbox take no size argument. Thus those
    #     children keep exactly what they inherit.
    #
    # Thus: each descendant of this disk starts at least this large, and nothing
    # ever shrinks. The VHDX expands dynamically (the core gives
    # CREATE_VIRTUAL_DISK_FLAG_NONE). Thus the file holds only what was really
    # written, and a large number costs nothing until use. 512 leaves space for
    # UE5 (100+ GB), a project, a warm DDC, and the layer deltas.
    [int]$DiskGb = 512,
    [int]$GpuMode = 1,              # 0 none, 1 paravirtual (what a forge is for), 2 try all
    # WHERE THE DISK GOES. Empty means the own default of the daemon, usually
    # %ProgramData%\AppSandbox. The folder of the VM is <DiskDir>\<Vm>, and the
    # disk is disk.vhdx in it. Put it on your FASTEST volume, not your largest.
    # Reads walk the layer chain, so each parent is on the hot path.
    #
    # FOR THE BUILD OF A BASE, DO NOT POINT THIS TO YOUR LAYER STORE. It looks
    # tidy, but it is the wrong layout. The whole folder goes with the delete of
    # the VM, and the last step of a base is the delete of the VM. Thus the one
    # directory where a VM must never point is the one with your read-only
    # layers. Build the base in the DEFAULT directory, which is clearly
    # temporary, and move the finished disk out. On one volume, that is a
    # rename, not a copy of 20 GB. The header of layer.ps1 next to this file has
    # the sequence.
    #
    # A user raised this. The user read the delete warning, came to the correct
    # conclusion, and saw that the advice above it disagreed with itself.
    # -DiskDir selects the volume of the own disk of a VM. It is not the way to
    # fill a layer store.
    [string]$DiskDir = '',
    # The guest inherits the time zone of the HOST, unless you give another. The
    # unattended default of Windows is Pacific. Thus each local time stamp in
    # the guest is hours away from the clock of the reader. That is true in each
    # layer on this one, until somebody fixes it. (Children CAN fix it. A frozen
    # parent does not prevent that, because the guest writes to the top layer.
    # But a correct value once here is better than a wrong one everywhere.) ''
    # does not touch the guest. 'UTC' is the other good answer.
    [string]$TimeZone = (Get-TimeZone).Id,
    [string]$AdminUser = 'forge',
    # The code ASKS for both passwords, with a generated default. It keeps them
    # in files next to the ssh keys, never in your head, and never in the
    # repository. Give them here to answer the questions first. -Yes takes the
    # generated value without a question.
    [string]$AdminPass = '',
    [string]$AdminPassFile = "$env:USERPROFILE\.ssh\draugr_forge.pass",
    [int]$TimeoutMin = 90,          # a Windows install from a cold ISO, with extra time
    [switch]$Yes,                   # skip the one question before the creation of a VM
    [string]$AdminKey = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [string]$TunnelKey = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519",
    [string]$Proxy = '127.0.0.1:3128',
    # The SECOND password, for VNC. Eight characters, because that is the auth
    # key of the protocol, not a policy. See the credentials block for why it
    # cannot be the Windows one. The code asks for it only for a run of the
    # screen phase.
    [string]$VncPass = '',
    [string]$VncPassFile = "$env:USERPROFILE\.ssh\draugr_vnc.pass",
    # Your own MSI, not the pinned TightVNC build. That is the supported way to
    # UltraVNC, whose download no script can do. The header of
    # lib/forge/screen-access.ps1 has the test and the comparison.
    [string]$VncMsi,
    # BY DEFAULT, THE CODE DOES NOT INSTALL THE VIEWER OF THE HOST. That is a
    # deliberate difference from the original script. The install elevates, and
    # an unattended run of an hour must not stop for a UAC question. All
    # questions come first for that reason. lib/forge/screen.ps1 works without
    # one. It leaves the forward up, and says that each viewer that points to it
    # works. See docs/FORGE.md, "2b's own five decisions".
    [switch]$InstallViewer,
    # 8765 inside the guest, because lib/forge/tunnel.ps1 forwards host 18765 to
    # exactly that port. NOT a dr-layer flag, on purpose. A move of the server
    # moves it away from the tunnel that reaches it. The code gives it to the
    # automation phase AND to the manifest, so that the two cannot become
    # different silently.
    [int]$McpPort = 8765,
    # What the console window of the server does on the autologon desktop. Not
    # only for looks. The window list of the agent and each screenshot that it
    # takes include that window. Set-McpWindow in install-automation.ps1
    # explains the cost of each choice.
    [ValidateSet('Normal', 'Minimized', 'Hidden')]
    [string]$McpWindow = 'Minimized',
    [switch]$SkipGuestBase,
    [switch]$SkipOnline,
    [switch]$SkipTunnelKey,
    [switch]$SkipGateway,
    [switch]$SkipTunnel,
    [switch]$SkipMsys2,
    [switch]$SkipTools,
    [switch]$SkipAutomation,
    [switch]$SkipShot,
    [switch]$SkipScreen,
    [switch]$SkipVault,
    [switch]$SkipVsCode,
    # ---- .NET FRAMEWORK 3.5, THE ONE PHASE THAT IS OFF UNTIL YOU ASK FOR IT.
    #
    # NOT A -SkipNetFx, as the original script had. The difference is not taste.
    # NetFx3 is a Feature on Demand. Its payload is NOT on the installed system,
    # and Windows fetches it from Windows Update. install-guest-base turns that
    # off, and a guest with no adapter cannot reach it anyway. The payload
    # exists in one place, \sources\sxs on a Windows ISO. It MUST match the
    # build of the guest, or DISM fails with 0x800f081f and blames the source.
    #
    # Thus the precondition is a file that only a person can make. A phase that
    # fails on each new machine teaches a reader to ignore the red row. Thus
    # this parameter is the switch AND the precondition. With it, the phase is
    # on, and its value makes the phase possible. No second flag exists that can
    # disagree with it.
    #
    # It is a HOST path. The cab goes into the guest through ssh, and does not
    # come from the vault. Thus the test can happen in the preconditions block,
    # not after phase 11, and this works on a gateway that serves no vault.
    # install-netfx3.ps1 keeps its vault route for manual runs.
    [string]$NetFxSource = '',
    [switch]$SkipCleanup,
    [switch]$SkipManifest,
    [switch]$HardenSshd,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:done = [ordered]@{}
function Phase($name, $state) { $script:done[$name] = $state }
function Say($msg)   { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Note($msg)  { Write-Host "  $msg" }
function Warn($msg)  { Write-Host "  $msg" -ForegroundColor Yellow }
function Fail($msg)  { Write-Host "  $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------- guest ssh
# Scripts are COPIED and run with -File, never piped into `powershell -Command
# -`. That form runs stdin one line at a time, as typed text. Thus it reads a
# multi-line block as not complete, and silently loses the rest, with exit code
# 0 and no output. A test showed this, after three scripts "succeeded" that way.
function Copy-ToGuest([string[]]$Paths, [string]$Dest = 'C:/Windows/Temp/') {
    Invoke-Native { & scp.exe -q -i $AdminKey -P $script:sshPort -o IdentitiesOnly=yes `
        -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm @Paths `
        "$($script:guestUser)@127.0.0.1:$Dest" 2>&1 } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "scp to the guest failed ($LASTEXITCODE)" }
}
# NOT named $Args. That is an automatic variable of PowerShell, and a parameter
# with that name silently gets nothing. A test on the first run of this script
# showed this. -VerifyOnly never reached the guest, and a read-only run changed
# a value.
function Invoke-GuestScript([string]$Name, [string[]]$ScriptArgs = @()) {
    $remote = "C:\Windows\Temp\$Name"
    # ============================ TWO DEFECTS FROM TESTS, BOTH FIXED HERE ================
    # A TEST on the first run of this script that reached the
    # guest. Each phase on the guest side failed, and each one reported `ok`.
    #
    # 1. PLAIN DOUBLE QUOTES AROUND THE PATH LOSE THEIR BACKSLASHES, but only
    # when
    #    bin/dr-layer starts this script. `-File "C:\Windows\Temp\x.ps1"` arrived in
    #    the guest as `C:WindowsTempx.ps1`. The same three forms, tested on the same guest:
    #
    #                        from Windows PowerShell | from WSL bash -> powershell.exe
    #      -File "$remote"              intact       |   C:WindowsTempx.ps1   <- eaten
    #      -File \"$remote\"            intact       |   intact
    #      -File $remote                intact       |   intact
    #
    #    THAT CONTEXT IS WHY IT SURVIVED THE ADOPTION. The original script ran in a Windows
    #    PowerShell, where the bug does not exist. bin/dr-layer runs it from bash in WSL,
    #    where it does. A comment here said that plain quotes were safe "because that path has
    #    no space for the quoting to matter to". That was true about spaces, but the
    #    conclusion was wrong. Nothing below has quotes, and the path has no space.
    #
    # 2. `powershell -File <missing>` EXITS ZERO. It writes "The argument '...'
    # to the -File
    #    parameter does not exist" to stderr, and returns 0. Thus a path that never resolved
    #    looks the same as a phase that worked. That made defect 1 into fourteen green rows,
    #    not a visible failure. Real codes DO pass through: a guest script that exits 4
    #    arrives as 4 (a test through this exact pipeline showed this). Thus the gap was only
    #    this one case.
    #
    #    Thus the own cmd.exe of the guest decides, and a missing file gets its own code. 127
    #    is the shell convention for "not found", and no guest script here uses it.
    # ====================================================================================
    $cmd = "if exist $remote " +
           "(powershell -NoProfile -ExecutionPolicy Bypass -File $remote $($ScriptArgs -join ' ')) " +
           "else (exit /b 127)"
    # The output of the guest goes to the console, and is NOT returned.
    # Otherwise `$rc = Invoke-GuestScript` captures each line of the guest into
    # $rc, with the exit code as the last element of an array of text. Thus the
    # guest looked silent, and the code judged the phase on a string. The first
    # run of this script found this the hard way.
    Invoke-Native { & ssh.exe -n -i $AdminKey -p $script:sshPort -o IdentitiesOnly=yes `
        -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
        "$($script:guestUser)@127.0.0.1" $cmd 2>&1 } | ForEach-Object { Write-Host "  $_" }
    $rc = $LASTEXITCODE
    # THROWN, not returned, and not reported as a phase failure. Copy-ToGuest
    # already throws on a failure of scp. Thus 127 means that scp reported
    # success, and the file is still not there. That is a defect of THIS script,
    # not a state of the guest. A return puts one more code into fourteen calls,
    # which each judge $rc differently. This must never again let "it never ran"
    # look like a result.
    if ($rc -eq 127) {
        throw ("$Name never ran. It is not at $remote in the guest, although the copy " +
               'reported success. Nothing below this point was tested.')
    }
    return $rc
}
# An argument VALUE WITH A SPACE needs quotes with backslashes, not plain ones.
# The command string of Invoke-GuestScript goes through four parsers: this
# shell, the native-argument quotes of PowerShell, the argument join of ssh, and
# the cmd.exe of the guest. Plain double quotes are lost on the way. A TEST on a
# live guest, with the value "W. Europe Standard Time":
#
#   -TimeZone "W. Europe Standard Time"     arrived as -TimeZone W.   + 3 loose words
#   -TimeZone 'W. Europe Standard Time'     the same
#   -TimeZone \"W. Europe Standard Time\"   arrived intact
#   -TimeZone ""W. Europe Standard Time""   arrived intact
#
# THE WAY THAT IT FAILED IS THE LESSON. The loose words went to the next
# parameters BY POSITION. Thus "Standard" went to [int]$CursorSize, and the
# guest complained about a parameter that nobody gave. A quote bug does not say
# that it is a quote bug.
#
# ONCE, A READER UNDERSTOOD THAT TABLE TOO NARROWLY. It says that plain quotes
# are lost. A comment here concluded that -File "$remote" was still safe,
# because the path has no space. But from WSL, the quotes are not only lost.
# They take the BACKSLASHES of the path with them. Invoke-GuestScript above has
# the test and the three forms. Quote a value because a test showed that the
# quotes survive, never because the value looks safe.
function Format-GuestArg([string]$Name, [string]$Value) {
    if ($Value -match '\s') { "$Name \`"$Value\`"" } else { "$Name $Value" }
}
# Each inline snippet goes as ONE base64 blob. A PowerShell snippet as a quoted
# argument must survive this shell, the argument join of ssh, and the default
# shell of the guest. Nested quotes do not survive. -EncodedCommand has no
# such problem.
function Invoke-GuestPs([string]$Ps) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Ps))
    Invoke-Native { & ssh.exe -n -i $AdminKey -p $script:sshPort -o IdentitiesOnly=yes -o BatchMode=yes `
        -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
        "$($script:guestUser)@127.0.0.1" `
        "powershell -NoProfile -EncodedCommand $b64" 2>&1 }
}
# After a phase that REBOOTS the guest. "Back" means that sshd answers a
# command, not that the port accepts a connection. sshd listens again several
# seconds before it can run a script. Thus a probe of only the connection gives
# the next phase a guest that refuses it.
#
# A TEST SHOWED THIS. install-vault-access.ps1 restarts the guest, so that
# srv2/srvnet release port 445. The two phases after it ran directly into the
# shutdown. cleanup died after its own banner, the manifest got "Connection
# closed by remote host", and both were reported as FAILED. Nothing was wrong
# with either of them.
function Wait-GuestBack([int]$TimeoutSec = 300) {
    # The guest still runs for a few seconds after the reboot request. A probe
    # that works on a guest that is about to go down is worse than no probe.
    Start-Sleep 20
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        # A special token, not 'ok'. While the guest is down, the own failure
        # text of ssh comes back. A match on text that can be in an error
        # message says that the guest is up, in the middle of its reboot.
        if ((Invoke-GuestPs 'Write-Output "GUEST-IS-BACK"') -match 'GUEST-IS-BACK') {
            Note ("the guest is back after {0:n0}s" -f $sw.Elapsed.TotalSeconds)
            return $true
        }
        Start-Sleep 5
    }
    Warn ("the guest did not answer ssh within {0}s of the reboot. The phases below" -f $TimeoutSec)
    Warn '  fail on a guest that is down. That is a symptom, not the cause.'
    return $false
}
function Invoke-Native([scriptblock]$Block) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block } finally { $ErrorActionPreference = $old }
}

# Test-SandboxdReachable: can the shell of THIS script talk to a sandboxd?
#
# $true reachable, $false not, $null cannot tell (sbx.exe is not on the PATH of
# the host).
#
# TESTED, because all three properties matter:
#   - `sbx daemon status` always EXITS 0, so the text is the only signal.
#   - Reachable prints "Status: running" and "(connected)". Not reachable prints
#     "Status: stopped" and "(not connected)", on the same live daemon, from a shell that
#     is not elevated. "stopped" here means "not reachable from here", not "not running".
#   - It STARTS NOTHING. The sbx.exe pid list is the same before and after. This probe
#     depends on that property. A probe that started the daemon makes exactly the mistake
#     that the caller wants to prevent.
function Test-SandboxdReachable {
    if (-not (Get-Command sbx.exe -ErrorAction SilentlyContinue)) { return $null }
    # 2>&1 on a native command needs the EAP guard. Under 'Stop', a line of
    # native stderr arrives as a terminating ErrorRecord, and stops the script.
    $out = Invoke-Native { & sbx.exe daemon status 2>&1 }
    return [bool](($out -join "`n") -match '(?m)^\s*Status:\s*running')
}

# ================================================================= preconditions
Say 'preconditions'

$asbDir = Join-Path $env:ProgramData 'AppSandbox'
$hostJson = Join-Path $asbDir 'host.json'
if (-not (Test-Path $asbDir)) {
    Fail "AppSandbox is not installed on this host ($asbDir is missing)."
    Fail 'Install AppSandbox, turn on the VirtualMachinePlatform Windows feature (it needs'
    Fail '  a reboot), start the daemon elevated, then run again with -IsoPath.'
    exit 2
}
if (-not (Test-Path $hostJson)) {
    Fail "No headless daemon: $hostJson is missing."
    Fail 'Start it elevated. That is the one step that no Draugr command can do:'
    Fail '    Start-Process AppSandbox.exe -ArgumentList ''--headless'' -Verb RunAs'
    exit 2
}
$hj = Get-Content $hostJson -Raw | ConvertFrom-Json
$api = "$($hj.endpoint)/v1"
$hdr = @{ Authorization = "Bearer $($hj.token)" }
Note "AppSandbox $($hj.version), API $api"

# NOTHING HERE STARTS A DAEMON OR A MOUND. That is the rule, not an accident.
#
# THE PROCESS THAT STARTS sandboxd DECIDES WHO CAN USE IT. Integrity works in
# ONE direction. An elevated client can use a daemon that an ordinary shell
# started, but not the reverse. Thus an elevated dr-* command with no sandboxd
# starts an ELEVATED one. The keeper of post-up pins it for the whole life of
# the mound. Then each later command from an ordinary terminal fails in the
# worst way.
#
# A TEST in the original script, which started the mound itself: sandboxd pid
# 3700, started at 11:07:51 by exactly that path. It still served at 20:32, and
# answered 200 on /daemon/health. At the same time, a `dr-up` that was not
# elevated reported "Status: stopped", tried to start its own, found the lock
# held, and said "previous sandboxd (PID 3700) did not exit within 10s". It said
# that about a process that it was not able to see. From medium integrity, its
# command line reads as DENIED, but the one of explorer.exe reads correctly.
# Nothing looked broken, and nothing was. It cost an evening.
#
# WHAT CHANGED HERE. bin/dr-layer starts the gateway through dr-dep, in your
# ordinary shell, before this script runs. This script only talks to the daemon
# through HTTP, which needs no elevation. The token is in host.json, and each
# other dr-* command does the same. Thus this script has nothing to start, and
# there is no -AllowElevatedGateway to change that. The rest needs a report, not
# an assumption. If no sandboxd is reachable, the gateway cannot run, and
# nothing below can download anything.
if (-not $SkipGateway -and -not $VerifyOnly) {
    $sbxUp = Test-SandboxdReachable
    if ($null -eq $sbxUp) {
        Note 'sbx.exe is not on the PATH of the host. Cannot test whether a sandboxd is reachable'
    } elseif ($sbxUp) {
        Note 'sandboxd is reachable, so the gateway mound can run'
    } else {
        Warn 'no sandboxd is reachable from here, so the gateway mound cannot run, and the'
        Warn '  guest has no other way out. From an ORDINARY (not elevated) WSL terminal, in'
        Warn '  the project that names this forge:'
        Warn '    dr-forge up        # the gateway, the VM, and the tunnel, in order'
        Warn '  If sbx says "running" in an elevated shell and "stopped" in an ordinary one,'
        Warn '  an elevated daemon already runs. Stop the mound with dr-stop, and start it'
        Warn '  again without elevation.'
    }
}

# ---- the .NET 3.5 payload, tested HERE, because here is before the hour.
# A folder, or the cab. Resolved now, so that each later use is an absolute
# path. Refused now, so that a typo costs a second, not a Windows install.
if ($NetFxSource) {
    if (-not (Test-Path $NetFxSource)) {
        Fail "-NetFxSource does not exist: $NetFxSource"
        Fail '  It is a path on THIS host: a folder with the NetFx3 cab, or the cab.'
        exit 2
    }
    $NetFxSource = (Resolve-Path $NetFxSource).Path
    # A glob, not a name. The cab has a suffix for the build and a locale. Thus
    # one fixed name becomes "not found" after the next Windows release.
    #
    # THE CODE TESTS A FILE WITH THE SAME PATTERN AS THE CONTENTS OF A FOLDER,
    # and that is important. Without a test, the wrong file goes in. The guest
    # script then globs for *netfx3*.cab next to it, finds none, and exits 2.
    # The phase below reports that as "the cab did not arrive in the guest". It
    # arrived, but it is not a cab. One wrong word in a summary makes somebody
    # debug scp.
    $netFxCab = if (Test-Path $NetFxSource -PathType Leaf) {
                    $f = Get-Item $NetFxSource
                    if ($f.Name -like '*netfx3*.cab') { $f } else { $null }
                } else {
                    @(Get-ChildItem $NetFxSource -Filter '*netfx3*.cab' -EA SilentlyContinue |
                      Sort-Object Length -Descending)[0]
                }
    if (-not $netFxCab) {
        if (Test-Path $NetFxSource -PathType Leaf) {
            Fail "that is not a NetFx3 cab: $NetFxSource"
            Fail '  The name must match *netfx3*.cab. The test is here, not in the guest,'
            Fail '  where a wrong file looks like a file that never arrived.'
        } else {
            Fail "no *netfx3*.cab in $NetFxSource"
        }
        Fail '  Take it from the Windows ISO of the guest install. A cab from a different'
        Fail '  build fails with 0x800f081f, and that looks like a missing file:'
        if ($IsoPath) {
            Fail "    mount $IsoPath read-only and copy"
        } else {
            Fail '    mount the ISO read-only and copy'
        }
        Fail '    <iso>:\sources\sxs\microsoft-windows-netfx3-ondemand-package~*~amd64~~.cab'
        exit 2
    }
    Note ("NetFx3 payload $($netFxCab.Name) ({0} MB)" -f [math]::Round($netFxCab.Length / 1MB, 1))
}

# ------------------------------------------------------------------- secrets on the host
# The alphabet removes the characters that people read wrongly from a screen:
# l, I, 1, O, 0. A person types the VNC password into a viewer question.
function New-Secret([int]$Length) {
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join (0..($Length - 1) | ForEach-Object { $alphabet[$bytes[$_] % $alphabet.Length] })
}
# Order: the value from the command line, then the value already on the disk,
# then a new one, as the default of a question. Thus a second run never silently
# invents a new password for an account that already has one.
function Get-Secret([string]$Given, [string]$File, [int]$Length, [string]$What,
                    [string]$Hint = '', [int]$MaxLength = 0) {
    $fromFile = $false
    if ($Given) {
        $pw = $Given
    } elseif (Test-Path $File) {
        $pw = (Get-Content $File -Raw).Trim()
        $fromFile = $true
        Note "reusing the $What already in $File"
    } else {
        $pw = New-Secret $Length
        if (-not $Yes) {
            $typed = Read-Host "  $What$Hint [$pw]"
            if ($typed) { $pw = $typed }
        }
    }
    # The auth key of VNC is EIGHT BYTES. TightVNC takes a longer password, cuts
    # it to 8, and says nothing. Thus you believe in a password that was never
    # set. Do the same cut, with a message, and write the cut value back. Thus
    # the file and the server always agree about the real password.
    if ($MaxLength -and $pw.Length -gt $MaxLength) {
        Warn "that $What is longer than $MaxLength characters, and the VNC protocol cannot carry that."
        $pw = $pw.Substring(0, $MaxLength)
        Warn "  cut to '$pw'. That is the real password, and the code saves it."
        $fromFile = $false
    }
    if ($fromFile) { return $pw }
    $dir = Split-Path $File -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($File, $pw)
    # The same treatment as a private key: only this account, inheritance off.
    icacls $File /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    Note "$What saved to $File"
    return $pw
}

# The commands of Draugr are bash, so they run in WSL. They can be on the PATH
# there (install.sh links them into ~/.local/bin), or not. Thus resolve it once,
# and do not assume. A plain `dr-up` that is not found looks the same as a
# gateway that failed.
#
# RESOLVED HERE, ABOVE PHASE 0, because it can set $SkipGateway, and the create
# decision below must know whether something starts the mound. NOTHING HERE
# LOOKS FOR DRAUGR IN WSL NOW, on purpose. The original script had to find dr-up
# (on the PATH, or "beside the gateway repo"), because its phase 4 ran it. Phase
# 4 now only tests (see there), and bin/dr-layer starts the gateway through
# dr-dep before it calls this script. Thus there is nothing to resolve, and no
# guess that can be wrong.

# ================================================================= credentials, up front
# The code asks each question for a person HERE, in one place, before a slow
# step starts. Thus a Windows install of an hour can never stop in the middle
# to ask something.
#
# BOTH PASSWORDS ARE FOR THE PERSON. The agent needs NEITHER of them. It
# authenticates with an ssh key, and that session is already elevated, with a
# full token (a test showed this: it writes System32, reads HKLM, and controls
# services, with no question). It does not even need the user name, because
# ssh_info() reports it. Only one place in this whole repository uses adminPass,
# the create body below. They are for a bad day: autologon breaks, or the
# desktop locks, and you look at a login prompt, where ssh does not help. Keep
# them for that.
#
# THE TWO ARE NOT THE SAME, on purpose, and not only for caution:
#
#   - The auth of VNC takes a key of EIGHT BYTES. TightVNC cuts a longer one with no
#     message. Thus "the same password" silently becomes "its first 8 characters". That is
#     the worst of both. It is not really shared. Also, a manual match limits the Windows
#     account to 8 characters.
#   - TightVNC stores it in HKLM\SOFTWARE\TightVNC\Server as 8 bytes of DES, under the
#     fixed, published VNC key (a TEST in the guest: an 8-byte Byte[], readable by
#     Administrators and SYSTEM). That is plain text with extra steps.
#   - The ssh sessions of this script are ELEVATED, so the agent can read that value at any
#     time. A shared secret gives the agent the Windows account.
#
# The Windows password can be recovered separately inside the guest anyway. The
# autologon of AppSandbox writes it to Winlogon\DefaultPassword as a plain text
# string (a test showed this). Thus a shared secret makes one recoverable secret
# into two, and gives nothing. Nobody types either one from memory, and both are
# in files on the host.
$existingVm = $null
try {
    $existingVm = (Invoke-RestMethod -Uri "$api/vms" -Headers $hdr -TimeoutSec 15).vms |
                  Where-Object { $_.name -eq $Vm }
} catch { }

$willCreate = ($IsoPath -and -not $existingVm -and -not $VerifyOnly)
# Asked ONLY for a screen phase that really installs something, with no password
# on the disk yet. A question for a secret that nothing sets makes a person
# believe that a password was configured.
$willScreen = (-not $SkipScreen -and -not $VerifyOnly -and -not (Test-Path $VncPassFile))

if ($willCreate -or $willScreen) {
    Say 'credentials'
    Note 'These are for YOU, not for the agent. It logs in with an ssh key, and its session'
    Note 'is already elevated. A password matters on the day when autologon breaks, or the'
    Note 'desktop locks, and you see a login prompt, which ssh cannot answer.'
    Note ''
    Note 'The questions are separate, because VNC cannot carry the same secret. Its auth key'
    Note 'is EIGHT characters, and TightVNC cuts a longer one with no message.'
    Note ''
    Note 'Press Enter to accept the generated value, or type your own.'
}
if ($willCreate) {
    if (-not $Yes) {
        $typedUser = Read-Host "  Windows account name [$AdminUser]"
        if ($typedUser) { $AdminUser = $typedUser }
    }
    # 20 characters. Nothing cuts it, and nobody has to type it. Autologon uses
    # it.
    $AdminPass = Get-Secret $AdminPass $AdminPassFile 20 'Windows password'
}
if ($willScreen) {
    $VncPass = Get-Secret $VncPass $VncPassFile 8 'VNC password' ' (8 characters max)' 8
}

# ========================================================= 0. create the VM, if asked to
# ONLY with -IsoPath. This is the one permanent step in the whole script. It
# uses tens of gigabytes and most of an hour. Thus a parameter with no default
# controls it, it refuses to touch an existing VM, and it asks once before it
# starts. All after it is idempotent, as before.
#
# THE WINDOWS INSTALL IS FULLY UNATTENDED, and AppSandbox does that, not us. The
# core generates an autounattend.xml, and patches it into a copy of the ISO. In
# it: OOBE hidden, HideOnlineAccountScreens, BypassNRO (so that it never asks
# for a network), and the TPM test bypassed. It also stages its guest agent with
# it. There is nothing to click. That is why a script can wait through "the
# Windows install is mostly a wait".
#
# sshDeployKey SOLVES THE CHICKEN-AND-EGG PROBLEM. The daemon generates an
# ed25519 key pair under %ProgramData%\AppSandbox\ssh\. The guest agent
# writes the public half into administrators_authorized_keys, WITH the strict
# ACL that sshd needs. This script printed exactly that block before, for a
# person to paste. Now the one thing that is already inside the guest does it.
# The keys phase below then uses it to install ours.
#
# networkMode is fixed to 0 (None), and is NOT a parameter. The design says
# that a forge has no way out except the gateway. A base image is the worst
# place for an exception. The same reason as the refusal above for an existing
# VM.
#
# testMode is fixed OFF. The README calls it "skip interactive setup where
# supported", and that is its meaning on Linux. On Windows, it does exactly one
# thing, `bcdedit /set testsigning on`, and we do not want a base image that
# loads unsigned drivers. The unattend above always skips the interactive setup.
if ($IsoPath) {
    if ($existingVm) {
        Note "'$Vm' already exists. Phase 0 does nothing (thus you can run it again)."
        Phase 'create' 'already there'
    } elseif ($VerifyOnly) {
        Fail "'$Vm' does not exist, and -VerifyOnly does not create it."
        exit 2
    } else {
        Say "create '$Vm', and install Windows in it"

        if (-not (Test-Path $IsoPath)) { Fail "No ISO at $IsoPath"; exit 2 }
        $IsoPath = (Resolve-Path $IsoPath).Path

        # The daemon validates a name exactly as the GUI does. A test here costs
        # one `if`, and saves a round trip that comes back as a plain 400.
        if ($Vm.Length -gt 15 -or $Vm -notmatch '^[A-Za-z0-9-]+$' -or
            $Vm -match '^-' -or $Vm -match '-$' -or $Vm -match '^[0-9]+$') {
            Fail "'$Vm' is not a valid Windows guest name."
            Fail '  <=15 characters (NetBIOS), only letters, digits, and hyphens, not all'
            Fail '  digits, and no hyphen at the start or the end.'
            exit 2
        }
        if ($AdminUser.Length -gt 20) { Fail '-AdminUser must have 20 characters or fewer.'; exit 2 }
        if ($Ram % 2) { $Ram-- }        # ramMb must be a multiple of 2 MB. The API refuses odd values
        if ($Ram -lt 512)  { Fail '-Ram must be at least 512 MB.'; exit 2 }
        if ($DiskGb -lt 1) { Fail '-DiskGb must be at least 1.'; exit 2 }

        # Ask the daemon, and do not assume C:. It reports the free space of the
        # volume that really holds the disks (`defaultDiskDirectory`, which you
        # can configure). It also tells what the existing VMs already declared.
        $hostInfo = $null
        try { $hostInfo = Invoke-RestMethod -Uri "$api/host" -Headers $hdr -TimeoutSec 15 } catch { }

        # WHERE THE DATA GOES, on its own line. "N GB free in X" answers a
        # different question. It says where the code measured the free space,
        # not where this VM lives, and people ask first where the data goes. The
        # daemon builds the folder of the VM as <diskDirectory>\<name>, with
        # disk.vhdx in it.
        $diskRoot = if ($DiskDir) { $DiskDir }
                    elseif ($hostInfo -and $hostInfo.defaultDiskDirectory) { $hostInfo.defaultDiskDirectory }
                    else { "$env:ProgramData\AppSandbox" }
        $vmDir  = Join-Path $diskRoot $Vm
        $vmDisk = Join-Path $vmDir 'disk.vhdx'

        # The free space of the volume that REALLY holds it. host().freeGb
        # measures the default directory of the daemon. That is the wrong volume
        # as soon as -DiskDir moves the disk to another place.
        $free = $null
        $qualifier = try { Split-Path $diskRoot -Qualifier } catch { $null }
        if ($qualifier) {
            $drv = Get-PSDrive ($qualifier -replace ':', '') -ErrorAction SilentlyContinue
            if ($drv) { $free = [int]($drv.Free / 1GB) }
        }
        if ($null -eq $free -and $hostInfo) { $free = [int]$hostInfo.freeGb }

        Note "ISO        $IsoPath"
        Note "guest      $Vm, user '$AdminUser', password in $AdminPassFile"
        Note "sizing     $Ram MB RAM, $Cores cores, $DiskGb GB disk, gpuMode=$GpuMode"
        Note 'network    None (0). ssh on, with the AppSandbox key deployed'
        Write-Host ''
        Note "DISK GOES HERE"
        Note "  $vmDisk"
        Note ("  declared {0} GB, sparse. The file holds only what is really written{1}" -f `
              $DiskGb, $(if ($free) { ", and $qualifier has $free GB free now" } else { '' }))
        if (-not $DiskDir) { Note '  that is the default of the daemon. -DiskDir puts it in another place' }
        Warn "  At the delete of this VM, AppSandbox DELETES $vmDir recursively."
        Warn '  Thus never keep something that you want next to this disk.'
        # THE PLACE OF THE DISK DOES NOT CHANGE THIS, and the code says so here
        # on purpose. The folder above is only <DiskDir>\<name>, so the warning
        # is the same under C:\ForgeLayers as under ProgramData. A disk is
        # deletable because a VM POINTS TO IT, not because of its path. -DiskDir
        # is about where the layer tools can see it, not about this. A user
        # asked, who had moved the disk to C:\ForgeLayers exactly to escape this
        # line. That is a fair reading of it.
        Note '  Another place does not change that. The folder is <DiskDir>\<name>, so this'
        Note '  is the same for each place of the disk. The exposure ends when no VM points'
        Note '  to it. For a disk that becomes a frozen base, dr-layer freeze --unregister'
        Note '  does that. It removes the VM block, and keeps the file. Until then, a delete'
        Note '  of this VM deletes this disk.'
        # The daemon does NOT CREATE this folder, and says so only after the
        # question below. Thus its state belongs in the summary, where the
        # decision happens.
        if ($DiskDir -and -not (Test-Path $DiskDir)) {
            Note "  $DiskDir does not exist yet. This run creates it."
            # WHY THIS IS NOT A QUESTION. A folder named with -DiskDir IS the
            # request to use it. The question below already covers the whole
            # create, and a second Read-Host must obey -Yes. Thus it guards only
            # interactive runs. A question catches a typo, but the depth catches
            # it better. New-Item -Force builds a whole missing chain without a
            # message. Thus -DiskDir C:\Frgoe\Layers works as easily as the path
            # that you meant. One new leaf under an existing root is normal. A
            # missing PARENT is not.
            $parentDir = Split-Path $DiskDir -Parent
            if ($parentDir -and -not (Test-Path $parentDir)) {
                Warn "  and its parent, $parentDir, does not exist either. Look at the spelling."
                Warn '  The code creates a -DiskDir with a typo as easily as a correct one,'
                Warn '  and the disk then lives in a place that you did not want.'
            }
        }
        Write-Host ''
        if ($hostInfo) {
            Note ("host       {0} cores, {1} GB RAM" -f `
                  $hostInfo.hostCores, [math]::Round($hostInfo.hostRamMb / 1024))
            if ($hostInfo.vmHddGb) {
                Note ("already    existing VMs declare {0} GB of disk and {1} MB of RAM" -f `
                      $hostInfo.vmHddGb, $hostInfo.vmRamMb)
            }
        }
        if ($DiskGb -gt $free) {
            Warn "only $free GB free, and the disk is declared at $DiskGb GB."
            Warn '  That is allowed, because the VHDX expands dynamically, and the file holds'
            Warn '  only what is really written. But the host can still become full.'
        }
        if ($hostInfo -and ($Ram / 1024) -gt ($hostInfo.hostRamMb / 1024 / 2)) {
            Warn "-Ram is more than half the RAM of this host. The mound and the host also need RAM."
        }
        Warn 'The disk size is permanent. Nothing can resize this disk, and each layer on'
        Warn '  top of it starts at least this large. You can change RAM, cores, GPU, and'
        Warn '  network later on a stopped VM, but not the disk.'

        # An account with no password and autologon is acceptable only for one
        # reason. This guest has no own network. Its only way in is a key-only
        # ssh on the host loopback. If you want a password, give -AdminPass.
        # Nothing else in the design depends on it.

        # EGRESS, JUDGED NOW, NOT AT PHASE 6. The guest gets no adapter, so each
        # byte that it installs comes through the proxy of the mound. If nothing
        # gives that, the run dies at the egress gate, AFTER the Windows
        # install, the hour that you just used. Say it here, while the decision
        # costs nothing.
        #
        # The code can judge only the MOUND now, and only in one direction. A
        # stopped mound is usually good, because phase 4 runs `dr-up`, and that
        # is idempotent. A stopped mound with nothing to start it is NOT good.
        # -SkipGateway means that. Without dr-up in WSL, the resolution above
        # also sets it. That case is silent, and costs the whole
        # install.
        #
        # The code cannot judge the tunnel at all. It forwards into a VM that
        # does not exist yet.
        $moundUp = [bool](Get-NetTCPConnection -LocalPort 18888 -State Listen -EA SilentlyContinue)
        Write-Host ''
        Warn 'The guest has no own way out. Each phase from 7 installs with downloads,'
        Warn '  and all of them go through the proxy of the mound, over the ssh tunnel. BOTH'
        Warn '  must run by phase 6. Otherwise this run stops there, with a fully installed'
        Warn '  Windows and nothing on top of it.'
        if ($moundUp) {
            Note '  mound   127.0.0.1:18888 answers'
        } elseif ($SkipGateway) {
            Fail '  mound   127.0.0.1:18888 silent, AND the gateway phase is skipped. Thus'
            Fail '          nothing in this run starts it. Fix that first.'
        } else {
            Note '  mound   127.0.0.1:18888 silent. Phase 4 runs dr-up, which is idempotent'
        }
        Warn '  tunnel  cannot be judged yet. It forwards into a VM that does not exist.'
        Warn '          Phase 5 registers it, and its log is %LOCALAPPDATA%\Draugr\forge-tunnel.log.'
        Warn '          If phase 6 fails, read that first. From here, a registered task that'
        Warn '          never started looks exactly like a working one.'

        if (-not $Yes) {
            Write-Host ''
            $answer = Read-Host '  Create this VM and install Windows? It takes 20-60 minutes. [y/N]'
            if ($answer -notmatch '^[Yy]') { Fail 'Nothing was created.'; exit 0 }
        }

        # THE DAEMON VALIDATES diskDirectory, AND DOES NOT CREATE IT. A TEST: a
        # -DiskDir with a folder that did not exist yet came back with
        #   400 invalid_arg "Disk storage location must be an existing accessible folder."
        # The create call returns it, before the daemon builds anything. Thus
        # the cost is the question and another run, not the install. But it
        # comes AFTER the answer to the question about 20-60 minutes. That is
        # the wrong side of the decision to find a missing mkdir.
        #
        # Created here, not in the summary above. Thus a "no" to the question
        # leaves nothing. Only for a -DiskDir with a value, because an empty one
        # means the own default of the daemon, which always exists.
        if ($DiskDir -and -not (Test-Path $DiskDir)) {
            try {
                New-Item -ItemType Directory -Force -Path $DiskDir -ErrorAction Stop | Out-Null
                Note "created $DiskDir"
            } catch {
                Fail "could not create $DiskDir"
                Fail "  $($_.Exception.Message)"
                Fail '  The daemon does not create it either, so nothing can be built there.'
                Fail '  Select a -DiskDir that you can write to, or remove it for the default.'
                exit 2
            }
        }

        $body = @{
            name         = $Vm
            osType       = 'Windows'
            imagePath    = $IsoPath
            ramMb        = $Ram
            hddGb        = $DiskGb
            cpuCores     = $Cores
            gpuMode      = $GpuMode
            networkMode  = 0
            adminUser    = $AdminUser
            testMode     = $false
            sshEnabled   = $true
            sshDeployKey = $true
        }
        if ($AdminPass) { $body.adminPass = $AdminPass }
        # Empty means "the default of the daemon", and the GUI sends exactly
        # that. Thus the code omits the field, and does not send it empty.
        if ($DiskDir) { $body.diskDirectory = $DiskDir }

        try {
            Invoke-RestMethod -Method Post -Uri "$api/vms" -Headers $hdr `
                -Body ($body | ConvertTo-Json) -ContentType 'application/json' `
                -TimeoutSec 60 | Out-Null
        } catch {
            # The documentation says that a 400 has
            # {"error":{"code":"invalid_arg","message":...}}. Windows PowerShell
            # 5.1 does not put that in ErrorDetails, so read the stream. PS7
            # does, so try that first. A TEST: probe 400s came back with an
            # EMPTY body. Thus the code reports an empty one as empty, and does
            # not hide it.
            $detail = $_.ErrorDetails.Message
            if (-not $detail -and $_.Exception.Response) {
                try {
                    $rs = $_.Exception.Response.GetResponseStream()
                    $detail = (New-Object IO.StreamReader($rs)).ReadToEnd()
                } catch { }
            }
            Fail "The daemon refused the create: $($_.Exception.Message)"
            if ($detail) { Fail "  $detail" } else { Fail '  (it sent no body with the reason)' }
            exit 2
        }

        # create() is async AND starts the VM. Thus the VM goes building ->
        # installing -> booting -> online by itself. Poll `state`, and do not
        # listen to the SSE event stream. A poll reads the live state each time,
        # so a lost connection cannot make it miss a step. The README says the
        # same.
        Note 'created. Now waiting. building -> installing -> booting -> online'
        $t0 = Get-Date
        $deadline = $t0.AddMinutes($TimeoutMin)
        $last = ''
        $state = ''
        while ((Get-Date) -lt $deadline) {
            Start-Sleep 5
            $st = $null
            try {
                $st = (Invoke-RestMethod -Uri "$api/vms" -Headers $hdr -TimeoutSec 15).vms |
                      Where-Object { $_.name -eq $Vm }
            } catch { continue }
            if (-not $st) { continue }
            $state = $st.state
            $line = $state
            if ($st.progress) { $line = "$state ($($st.progress)%)" }
            if ($line -ne $last) {
                Note ("{0,6:n0}s  {1}" -f ((Get-Date) - $t0).TotalSeconds, $line)
                $last = $line
            }
            if ($state -eq 'online') { break }
        }
        if ($state -ne 'online') {
            Fail "'$Vm' did not reach 'online' within $TimeoutMin minutes (state=$state)."
            Fail '  It is possibly still installing. Run again WITHOUT --iso to continue from'
            Fail "  its state, or raise -TimeoutMin. The log of the daemon is $asbDir\headless.log."
            exit 2
        }
        Note ("online after {0:n0} minutes" -f ((Get-Date) - $t0).TotalMinutes)
        Phase 'create' 'ok'
    }
}

$vms = (Invoke-RestMethod -Uri "$api/vms" -Headers $hdr -TimeoutSec 15).vms
$info = $vms | Where-Object { $_.name -eq $Vm }
if (-not $info) {
    Fail "No VM named '$Vm'. Present: $(($vms.name) -join ', ')"
    Fail '  Give -IsoPath <a Windows 11 ISO>, and this script creates it for you.'
    exit 2
}
if (-not $info.installComplete) {
    Fail "'$Vm' has no finished Windows install yet (state=$($info.state))."
    Fail '  If it says "installing", it still runs. Wait, and run again.'
    exit 2
}
if (-not $info.running) {
    if ($VerifyOnly) { Fail "'$Vm' does not run."; exit 2 }
    Note "starting '$Vm'..."
    Invoke-RestMethod -Method Post -Uri "$api/vms/$Vm/start" -Headers $hdr -Body '{}' `
        -ContentType 'application/json' -TimeoutSec 60 | Out-Null
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep 2
        $info = (Invoke-RestMethod -Uri "$api/vms" -Headers $hdr).vms | Where-Object { $_.name -eq $Vm }
        # >= 2, not -eq 2. See Wait-SshReady. A VM that goes directly to 4 never
        # matches an equality test, and this loop then waits its full 180 s for
        # nothing.
        if ($info.sshState -ge 2) { break }
    }
}
Note "'$Vm' state=$($info.state) gpuMode=$($info.gpuMode) ram=$($info.ramMb)MB cpus=$($info.cpuCores)"

# networkMode 0 is None. With another value, the guest has its own adapter. That
# gives it egress that the gateway never sees, and this script then puts that
# into a base image for other VMs.
if ($info.networkMode -ne 0) {
    Fail "'$Vm' has networkMode=$($info.networkMode), not None (0)."
    Fail '  Stop the VM, and set it to None: in the GUI, or with POST /v1/vms/<name>/edit and'
    Fail '  {"networkMode":0}, which the API accepts while it is stopped. Then run again.'
    Fail '  This script does not do it for you. See the header.'
    exit 2
}
Note 'network: None, as the design requires'

# A VM THAT SAYS 'online' IS NOT YET A VM THAT YOU CAN SSH INTO. The daemon
# reports the ssh state of the guest separately, through sshInfo. Until the
# guest agent is there, it answers port 0 / sshState 0. A TEST on a new create:
# 'online' was reported, sshInfo answered 0/0 one call later, and the run died
# on `Bad port '0'`. Then it offered a manual paste of the key, for a VM whose
# key arrived by itself seconds later.
#
# WHY THIS SURVIVED SO LONG: a wait on sshState existed, but only in the branch
# that must START a stopped VM. The daemon starts a new VM by itself, so it
# already runs. That branch never runs, and the code skipped the only wait, on
# the one path where the guest is least ready.
#
# sshState: 0 not ready, 2 ready, 4 ready and the deploy key is in. The test is
# >= 2, because a VM can go directly to 4 (each run that worked reported that).
# The PORT must really be usable, so the code also tests it, and does not infer
# it from the state.
function Wait-SshReady([int]$TimeoutSec = 300) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try { $last = Invoke-RestMethod -Uri "$api/vms/$Vm/sshInfo" -Headers $hdr -TimeoutSec 15 }
        catch { $last = $null }
        if ($last -and [int]$last.port -gt 0 -and [int]$last.sshState -ge 2) {
            if ($sw.Elapsed.TotalSeconds -ge 3) {
                Note ("ssh came up {0:n0}s after the VM went online" -f $sw.Elapsed.TotalSeconds)
            }
            return $last
        }
        Start-Sleep 3
    }
    # Returned, not thrown. The caller prints what it is, and says what to do.
    # That is more useful than an exception that names a REST URL.
    return $last
}

$ssh = Wait-SshReady
if (-not $ssh -or [int]$ssh.port -le 0) {
    Note "ssh: not reachable yet (port=$($ssh.port) sshState=$($ssh.sshState))"
    Fail "'$Vm' is online, but its ssh port is still 0 after the wait."
    Fail '  The guest reports ssh separately from the VM state. Thus the guest still starts,'
    Fail '  and you did nothing wrong. Nothing below can run without it. The VM EXISTS and'
    Fail '  is good. Run this command again, and it continues from the current state'
    Fail '  (phase 0 does nothing for a VM that is already there).'
    Fail "  If it never becomes ready, the log of the daemon is $asbDir\headless.log."
    exit 2
}
$script:sshPort = $ssh.port
$script:guestUser = $ssh.user
Note "ssh: $($ssh.user)@127.0.0.1:$($ssh.port) (sshState=$($ssh.sshState))"

# ============================================================== 1. keys on the host
Say 'keys'
foreach ($k in @($AdminKey, $TunnelKey)) {
    if (Test-Path $k) { Note "have $(Split-Path $k -Leaf)"; continue }
    if ($VerifyOnly) { Fail "missing $k"; continue }
    $dir = Split-Path $k -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    & ssh-keygen.exe -q -t ed25519 -N '""' -C (Split-Path $k -Leaf) -f $k
    # ssh refuses a private key that other users can read, so limit it to this
    # account.
    icacls $k /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    Note "generated $(Split-Path $k -Leaf)"
}
Phase 'ssh keys' 'ok'

# Can we get in?
$probe = Invoke-GuestPs '$env:COMPUTERNAME'

# Not yet. But a VM created with sshDeployKey already trusts the OWN key of
# AppSandbox, and that key is on this host. Use it once to install ours. The
# paste-this-block path below stays for guests that somebody else made without a
# deploy key.
if ($LASTEXITCODE -ne 0 -or -not $probe) {
    $asbKey = Join-Path $asbDir 'ssh\id_appsandbox'
    if ((Test-Path $asbKey) -and -not $VerifyOnly) {
        Note 'the guest does not accept the admin key yet. Trying the AppSandbox deploy key'
        # DELEGATED. Before, an inline here-string did the append and the icacls
        # itself. vm.ps1 -Mode keys must do exactly this at each VM start. The
        # daemon rewrites administrators_authorized_keys, and keeps only its own
        # line (a test showed this). Thus a copy here is a second implementation
        # of the one thing that must be exactly the same in both places. It also
        # installs the tunnel key, which the same rewrite removes. Phase 3 below
        # then finds it already in place.
        & (Join-Path $PSScriptRoot 'vm.ps1') -Mode keys -Vm $Vm -AdminKey $AdminKey `
            -TunnelKey $TunnelKey | ForEach-Object { Note $_ }
        $probe = Invoke-GuestPs '$env:COMPUTERNAME'
    }
}

# Still not? Then a person must put the first key in, once.
if ($LASTEXITCODE -ne 0 -or -not $probe) {
    Fail 'The admin key does not work on this guest yet, so nothing else can run.'
    if (-not (Test-Path "$AdminKey.pub")) {
        Fail "There is also no key at $AdminKey."
        Fail '  A normal run generates one, but -VerifyOnly does not. That is why you see'
        Fail '  this. Run again without -VerifyOnly, or point -AdminKey to the key that'
        Fail '  this guest already trusts.'
        exit 3
    }
    Write-Host ''
    Write-Host '  Paste this ONCE into an elevated PowerShell inside the guest:' -ForegroundColor Yellow
    Write-Host ''
    $pub = (Get-Content "$AdminKey.pub" -Raw).Trim()
    Write-Host "    `$f = 'C:\ProgramData\ssh\administrators_authorized_keys'"
    Write-Host "    Add-Content -Path `$f -Encoding ascii -Value '$pub'"
    Write-Host "    icacls `$f /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'"
    Write-Host ''
    Write-Host '  Or delete this VM, and let -IsoPath make one. A VM created with sshDeployKey' -ForegroundColor Yellow
    Write-Host '  gets a working key from the guest agent, and nothing ever needs a paste.' -ForegroundColor Yellow
    exit 3
}
Note "reached the guest: $($probe.Trim())"

# ============================================================== 2. the guest's OS settings
if ($SkipGuestBase) { Phase 'guest base' 'skipped' } else {
    Say 'guest base (proxy, Windows Update, LanmanServer, loopback adapter)'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-guest-base.ps1'))
    $a = @((Format-GuestArg '-Proxy' $Proxy))
    if ($TimeZone) { $a += (Format-GuestArg '-TimeZone' $TimeZone) }
    if ($HardenSshd) { $a += '-HardenSshd' }
    if ($VerifyOnly) { $a += '-VerifyOnly' }
    $rc = Invoke-GuestScript 'install-guest-base.ps1' $a
    Phase 'guest base' $(if ($rc -eq 0) { 'ok' } else { "FAILED ($rc)" })
    if ($rc -ne 0 -and -not $VerifyOnly) { Fail 'the guest base is not complete. Stopping here'; exit 4 }
    if ($HardenSshd -and -not $VerifyOnly) {
        Note 'the guest scheduled a restart of sshd. Waiting until it is back...'
        Start-Sleep 30
        $probe = Invoke-GuestPs '$env:COMPUTERNAME'
        if (-not $probe) { Fail 'the guest did not answer after the sshd restart'; exit 4 }
        Note 'the key still works after the restart'
    }
}

# ==================================================== 2b. make Windows believe it is online
# This runs AFTER the guest base, because it needs the loopback adapter of that
# phase. It runs BEFORE each program that signs in. Without it, the Windows
# identity stack refuses to make one request. The sign-in of Visual Studio 2022
# dies with 0x800713AB in a WINDOWS dialog, not its own. No allowlist entry can
# help, because no request ever happens. Six faults on top of each other, all
# found by tests. The script documents each one. It gives no egress. A direct
# connection still returns nothing, and the proxy still controls each byte.
if ($SkipOnline) { Phase 'windows online' 'skipped' } else {
    Say 'windows online (NCSI, routing, AppContainer loopback, IPv6)'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-windows-online.ps1'))
    $rc = Invoke-GuestScript 'install-windows-online.ps1' $(if ($VerifyOnly) { @('-VerifyOnly') } else { @() })
    # NOT fatal. All that does not sign in through Windows works without it.
    # Thus a failure here costs only the Microsoft-account flows. A stop of the
    # whole provisioning run for that is too much. 4 IS NOT A FAILURE OF THE
    # RUN. All was applied, and only the pair that Windows reports is missing.
    # That costs only the identity broker. Thus the base is still worth a
    # finish, and the summary says what is true, not 'ok' or 'FAILED'.
    Phase 'windows online' $(if ($rc -eq 0) { 'ok' }
                             elseif ($rc -eq 4) { 'applied, but not online-looking yet' }
                             else { "FAILED ($rc)" })
    if ($rc -eq 4) {
        Warn 'Windows does not say that it is online yet, so a sign-in to Epic or Microsoft'
        Warn '  refuses. All else works. NLA evaluates again on its own clock. Usually, a'
        Warn '  second run of this phase, or a reboot of the guest, is enough.'
    } elseif ($rc -ne 0) {
        Warn 'Windows says that it is offline. A Microsoft-account sign-in fails'
    }
}

# ============================================================== 3. the restricted tunnel key
if ($SkipTunnelKey) { Phase 'tunnel key' 'skipped' } elseif ($VerifyOnly) {
    $line = Invoke-GuestPs 'Get-Content (Join-Path $env:ProgramData "ssh\administrators_authorized_keys") | Select-String draugr-tunnel'
    if ($line) { Note 'the tunnel key is installed'; Phase 'tunnel key' 'ok' }
    else { Fail 'no draugr-tunnel line in the guest'; Phase 'tunnel key' 'missing' }
} else {
    Say 'the restricted tunnel key'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-tunnel-key.ps1'), "$TunnelKey.pub")
    $rc = Invoke-GuestScript 'install-tunnel-key.ps1' @("-PubKeyFile C:\Windows\Temp\$(Split-Path "$TunnelKey.pub" -Leaf)")
    Phase 'tunnel key' $(if ($rc -eq 0) { 'ok' } else { "FAILED ($rc)" })
    Invoke-GuestPs "Remove-Item 'C:\Windows\Temp\$(Split-Path "$TunnelKey.pub" -Leaf)' -Force -EA SilentlyContinue" | Out-Null
}

# ============================================================== 4. the gateway mound
# TESTED HERE, NOT STARTED HERE. That is a change from the original script. It
# ran `dr-up` on a fixed gateway directory. Draugr already has the answer to
# "that mound must run": DRAUGR_REQUIRES and dr-dep, as in dr-forge up. They
# bring trust, the claim, the cycle guard, and the warden, which stops sbx from
# a stop of an idle mound. bin/dr-layer does that before it calls this script.
# Thus here, the only useful question is whether it worked.
#
# Also, this script must never start it. This script runs elevated, and the
# process that starts sandboxd decides who can use it. The precondition above
# tells the cost.
if ($SkipGateway) { Phase 'gateway' 'skipped' } else {
    Say 'the gateway mound'
    $moundUp = [bool](Get-NetTCPConnection -LocalPort 18888 -State Listen -EA SilentlyContinue)
    if ($moundUp) {
        Note 'mound   127.0.0.1:18888 answers, so the host can reach the proxy'
        Phase 'gateway' 'ok'
    } else {
        Warn 'mound   127.0.0.1:18888 is silent. The gateway does not run.'
        Warn '  dr-layer provision starts it through DRAUGR_REQUIRES before it calls this.'
        Warn '  Thus, if it is down, nothing requires it, or its dr-up failed. From the'
        Warn '  project that names this forge:  dr-forge up   (or dr-up in the gateway).'
        Phase 'gateway' 'DOWN'
    }
}

# ============================================================== 5. the tunnel supervisor
if ($SkipTunnel) { Phase 'tunnel' 'skipped' } else {
    Say 'the tunnel supervisor'
    if (-not $VerifyOnly) {
        # THE SUPERVISOR OF DRAUGR, not the install-tunnel-autostart.ps1 of the
        # gateway. That was a different file and a LOGON TASK, and the rule of
        # few host changes did not allow it. vm.ps1 -Mode tunnel starts
        # lib/forge/tunnel.ps1. It judges the forward by effect first, so that
        # it does not touch a healthy tunnel. It refuses to replace a forward
        # for another VM. dr-forge already has the same fix.
        & (Join-Path $PSScriptRoot 'vm.ps1') -Mode tunnel -Vm $Vm -AdminKey $AdminKey |
            ForEach-Object { Note $_ }
    }
    # WAIT for the forwards, and do not take one sample. The supervisor must see
    # the VM, connect to sshd, and finish the handshake before -L binds
    # something. A fixed 5 seconds reported 'down' for a tunnel that started a
    # moment later. The limit stays short. A tunnel that is not up in 30 s is
    # broken, not slow.
    foreach ($i in 1..30) {
        if (Get-NetTCPConnection -LocalPort 18765 -State Listen -EA SilentlyContinue) { break }
        Start-Sleep 1
    }
    # Who binds what, because a mix-up sends you to the wrong place:
    #   18888, 18445  the MOUND (docker) publishes them. Down = the gateway does not run.
    #   18765, 18000  the -L of the tunnel supervisor binds them. Down = it does not run.
    # The -R forwards of the supervisor are in the GUEST, and this side cannot
    # see them. The egress phase below proves those.
    $ports = @{}
    foreach ($p in 18888, 18445, 18765, 18000) {
        $ports[$p] = [bool](Get-NetTCPConnection -LocalPort $p -State Listen -EA SilentlyContinue)
    }
    Note ("mound ports:   18888=$(if ($ports[18888]) {'up'} else {'down'}) 18445=$(if ($ports[18445]) {'up'} else {'down'})")
    Note ("tunnel ports:  18765=$(if ($ports[18765]) {'up'} else {'down'}) 18000=$(if ($ports[18000]) {'up'} else {'down'})")
    if (-not ($ports[18888])) {
        Warn 'the gateway mound does not run. Run dr-up (phase 4), or remove -SkipGateway'
    }
    if (-not ($ports[18765])) {
        Warn 'the tunnel does not run, and its log is the only diagnosis:'
        Warn "  $env:LOCALAPPDATA\Draugr\forge-tunnel.log"
        Warn '  Read the last "supervisor started" line first, and look at WHICH VM it names.'
        Warn '  The usual cause is an old supervisor for another VM. -Vm is fixed at the'
        Warn '  start. Thus it logs "waiting for the VM" forever, while it holds the host'
        Warn '  forwards that this one needs.'
    }
    Phase 'tunnel' $(if ($ports[18765]) { 'ok' } else { 'FAILED' })
}

# ============================================================== 6. egress, or stop
# Each step below downloads something. A proof of egress here, from inside the
# guest, makes a chain of confusing failures into one clear message. It is the
# same request as the post-up hook of the mound, from the other end.
Say 'egress from the guest'
Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\preflight.ps1'))
$rc = Invoke-GuestScript 'preflight.ps1'
# 3 means "the probe is broken", NOT "no egress". This project cannot tell now.
# "The gateway is down" sends somebody to fix the wrong thing. It still stops
# the run. Nothing below must download an hour of installers on a guess.
Phase 'egress' $(if ($rc -eq 0) { 'ok' } elseif ($rc -eq 3) { 'UNPROVED' } else { 'FAILED' })
if ($rc -eq 3) {
    Fail 'Egress is NOT PROVED. That is not the same as a guest with no way out.'
    Fail '  preflight.ps1 told the reason. It is a defect of this project, not of your gateway.'
    exit 5
}
if ($rc -ne 0) {
    Fail 'The guest has no way out, so nothing below can install. Fix that first.'
    Fail '  The mound (phase 4) and the tunnel (phase 5) must both run.'
    exit 5
}

# ============================================================== 7. MSYS2
# FIRST of the components, because it installs the package set after it. Phase 8
# runs pacman. The automation phase does NOT need it. uv brings its own Python,
# and AutoHotkey arrives as a zip.
#
# Its own header has the pin. The installer is fixed by date and hash. Before
# the first sync, each mirrorlist loses each server except repo.msys2.org. Thus
# pacman can only connect to the one host that the kit allows.
if ($SkipMsys2) { Phase 'msys2' 'skipped' } else {
    Say 'MSYS2, pinned to one host'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-msys2.ps1'))
    $rc = Invoke-GuestScript 'install-msys2.ps1' $(if ($VerifyOnly) { @('-VerifyOnly') } else { @() })
    Phase 'msys2' $(if ($rc -eq 0) { 'ok' } else { "FAILED ($rc)" })
}

# ============================================================== 8. the package set
if ($SkipTools) { Phase 'base tools' 'skipped' } else {
    Say 'the base package set'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-base-tools.ps1'))
    $rc = Invoke-GuestScript 'install-base-tools.ps1' $(if ($VerifyOnly) { @('-VerifyOnly') } else { @() })
    Phase 'base tools' $(if ($rc -eq 0) { 'ok' } else { "FAILED ($rc)" })
}

# ============================================================== 9. GUI automation
if ($SkipAutomation) { Phase 'automation' 'skipped' } else {
    Say 'GUI automation (UIA MCP server, AutoHotkey)'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-automation.ps1'))
    $a = @("-Port $McpPort", "-McpWindow $McpWindow")
    if ($VerifyOnly) { $a += '-VerifyOnly' }
    $rc = Invoke-GuestScript 'install-automation.ps1' $a
    Phase 'automation' $(if ($rc -eq 0) { 'ok' } else { "FAILED ($rc)" })
}

# ============================================================== 9b. the desktop camera
# Right after the automation, because it answers the same question from the
# other side. The MCP server lets an agent DRIVE the desktop. This lets each
# agent with only a shell SEE it. It also works with a broken MCP server.
# Then a look is most necessary.
#
# Both exist because session 0 cannot take a picture of session 1.
# install-shot.ps1 crosses that gap with an on-demand scheduled task. Its header
# has the full reason.
if ($SkipShot) { Phase 'shot' 'skipped' } else {
    Say 'the desktop camera'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-shot.ps1'))
    $rc = Invoke-GuestScript 'install-shot.ps1' $(if ($VerifyOnly) { @('-VerifyOnly') } else { @() })
    Phase 'shot' $(if ($rc -eq 0) { $(if ($VerifyOnly) { 'reported' } else { 'ok' }) } else { "FAILED ($rc)" })
}

# ============================================================== 10. the screen
# lib/forge/screen-access.ps1 gets the MSI from the vendor on the HOST, and
# compares it to a pinned SHA-256. Thus no allowlist entry is necessary. The
# host has normal internet, and ssh pushes the file into the guest. -VncMsi
# still overrides the pin. Use it to install UltraVNC in place of this. A script
# cannot download UltraVNC, as the header of that script tells.
#
# THE VIEWER HALF ON THE HOST IS NOT INSTALLED, unless -InstallViewer. It
# elevates, and this run must not stop for a UAC prompt. See the parameter.
if ($SkipScreen) { Phase 'screen' 'skipped' } else {
    Say 'the screen (VNC)'
    $running = Invoke-GuestPs '(Get-Service tvnserver -EA SilentlyContinue).Status'
    if ($running -match 'Running') {
        Note 'tvnserver is already running in the guest'
        Phase 'screen' 'ok'
    } elseif ($VerifyOnly) {
        Fail 'no tvnserver in the guest'
        Phase 'screen' 'missing'
    } else {
        # -PassFile, explicitly. The credentials block above can write the
        # answer there just before. If two scripts share a default, they drift
        # apart. The same for -SshPort and -GuestUser. The daemon gave both
        # before phase 0, so the screen installer uses the answer of this run
        # and does not ask again. GuestUser, not User: see the note on the name
        # in that script.
        $a = @{ Vm = $Vm; AdminKey = $AdminKey; PassFile = $VncPassFile
                SshPort = $script:sshPort; GuestUser = $script:guestUser }
        if (-not $InstallViewer) { $a.SkipHostViewer = $true }
        if ($VncMsi) {
            if (-not (Test-Path $VncMsi)) { throw "-VncMsi does not exist: $VncMsi" }
            $a.Msi = $VncMsi
        }
        & (Join-Path $PSScriptRoot 'screen-access.ps1') @a | ForEach-Object { Note $_ }
        # Probe again, and do not read $LASTEXITCODE. PowerShell scripts do not
        # set it, so it still holds the value of the last NATIVE command.
        $after = Invoke-GuestPs '(Get-Service tvnserver -EA SilentlyContinue).Status'
        Phase 'screen' $(if ($after -match 'Running') { 'ok' } else { 'FAILED' })
        if (-not $InstallViewer) {
            Note 'this run gave the host no viewer. If you have one, dr-forge screen finds it.'
            Note '  If you do not, it tells you what to point at 127.0.0.1:15900.'
        }
    }
}

# ============================================================== 11. the vault (optional)
# Optional by nature. It carries an asset library in from the host. A guest
# with no library needs none of it.
#
# AND IT ASKS FIRST WHETHER A VAULT EXISTS. The original script did not have to,
# because its gateway always served one. If no --vault was given, `dr-forge
# gateway` of Draugr generates a mound with NO share, and the post-up hook skips
# the share step. This phase REBOOTS the guest, because the LanmanServer of the
# guest holds port 445 until a restart. A reboot for a share that nobody serves
# is a waste.
#
# TWO CONDITIONS, because post-up skips the share in two cases, and they look
# different from here:
#   * no vault directory  -> the generated configuration does not publish 18445, so the
#     host has no listener. (The generator controls it for this reason. The PUBLISHER
#     binds a published port. Thus a port that is always published answers, also
#     with no service behind it. Then this test believes it.)
#   * no share password   -> 18445 is published and answers, but no Samba is behind
#     it. The password file is on THIS side, so this script reads it.
#
# Asked here, not read from the port table of phase 5, because -SkipTunnel
# leaves that table empty.
if ($SkipVault) { Phase 'vault' 'skipped' } else {
    Say 'the vault (optional)'
    $drives = Invoke-GuestPs '(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name + "=" + $_.DisplayRoot }) -join ";"'
    # The match is here, not in the guest snippet. A -like pattern for a UNC
    # path is all backslashes, and backslashes get lost on the way over.
    $mounted = ($drives | Where-Object { $_ -match '127\.0\.0\.1' }) -join ' '
    $smbUp = [bool](Get-NetTCPConnection -LocalPort 18445 -State Listen -EA SilentlyContinue)
    $smbPass = "$env:USERPROFILE\.ssh\draugr_vault_smb.pass"
    if ($mounted) { Note "mounted: $mounted"; Phase 'vault' 'ok' }
    elseif ($VerifyOnly) { Note 'not mounted (mount-vault.ps1 runs once per session)'; Phase 'vault' 'not mounted' }
    elseif (-not $smbUp) {
        Note 'the gateway serves no vault. Nothing listens on 127.0.0.1:18445.'
        Note '  Nothing installed, and the guest did NOT reboot. To serve one, generate the'
        Note '  gateway again with a vault directory:  dr-forge gateway <dir> --vault <path>'
        Phase 'vault' 'no vault served'
    }
    elseif (-not (Test-Path $smbPass)) {
        # DRAUGR NEVER WRITES THIS FILE, on purpose. It is the one record of a
        # password that the guest also keeps. If a rebuild wrote it again, the
        # copy in the guest becomes wrong. At each recreate, the hook puts its
        # content on the share. Without it, the hook serves no share, and its
        # log tells you so.
        Note "no share password on this host: $smbPass"
        Note '  18445 is published, but without it the gateway serves no share. Thus there is'
        Note '  nothing to mount, and the guest did NOT reboot. Make one. Then run dr-up on the'
        Note '  gateway again, so that its post-up hook puts it on the share:'
        Note '    $b = New-Object byte[] 18'
        Note '    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)'
        Note ("    [IO.File]::WriteAllText('{0}', ([Convert]::ToBase64String($b) -replace '[/+=]',''))" -f $smbPass)
        Phase 'vault' 'no share password'
    }
    else {
        Note 'installing the vault key and the mount script in the guest...'
        # -User IS MANDATORY THERE. Without it, the run did not fail. It stopped
        # and asked. A test showed that an unattended run stopped at the
        # PowerShell prompt "Supply values for the following parameters: User:"
        # in the middle of a phase. Only the content of stdin can answer it. A
        # mandatory parameter with no value is a hang, not an error.
        & (Join-Path $PSScriptRoot 'vault-access.ps1') `
            -Vm $Vm -User $script:guestUser -AdminKey $AdminKey -SshPort $script:sshPort |
            ForEach-Object { Note $_ }
        # It reboots the guest, and each phase below needs ssh.
        [void](Wait-GuestBack)
        Note 'run mount-vault.ps1 in the guest once per session to mount it'
        Phase 'vault' 'installed'
    }
}

# ============================================================== 11b. Visual Studio Code
# AFTER the vault, and that order is the point. The installer is 233 MB. The
# only way out of the guest is the proxy over the ssh tunnel. Phase 11 puts the
# share credential in the guest. If this runs before the vault, each build
# downloads it again.
#
# If the vault has no copy, the script downloads it. Thus a guest built with
# -SkipVault still gets VS Code. It only costs more.
#
# NOT specific to Unreal, so it is here and not in a layer. Each Windows VM
# wants this editor. The "Unreal Angelscript" extension is the opposite. It is
# for one project, one line in the VM that needs it. install-vscode.ps1 tells
# this, and does not install it.
if ($SkipVsCode) { Phase 'vscode' 'skipped' } else {
    Say 'Visual Studio Code'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-vscode.ps1'))
    $rc = Invoke-GuestScript 'install-vscode.ps1' $(if ($VerifyOnly) { @('-VerifyOnly') } else { @() })
    Phase 'vscode' $(if ($rc -eq 0) { $(if ($VerifyOnly) { 'reported' } else { 'ok' }) } else { "FAILED ($rc)" })
}

# ============================================================== 11c. .NET Framework 3.5
# LAST of the components, and the only one that is off unless you ask for it.
# -NetFxSource tells why the payload is the job of a person. It belongs in the
# base, not in an engine layer. A test showed that the install of UE 4.27 made
# Windows ask for it. Each engine version above this disk asks again.
#
# NOT AFTER THE VAULT BECAUSE OF THE VAULT, unlike VS Code. The cab comes from
# the host, so this phase does not need phase 11. It is here because it is the
# last install step. Also, a reader who looks for "what else went in" reads
# down.
#
# A FAILURE HERE IS REPORTED, NOT FATAL. Do not discard a base that is
# otherwise complete for a 68 MB cab. One command in the guest can enable it
# later.
if (-not $NetFxSource) {
    # Said, not silently absent. A base with no NetFx3 is the normal case. The
    # summary is where a person learns why Windows asked for it later.
    Phase 'netfx3' 'not requested'
} else {
    Say '.NET Framework 3.5'
    $sxs = 'C:/Windows/Temp/draugr-sxs'
    Invoke-GuestPs "New-Item -ItemType Directory -Force -Path '$($sxs -replace '/','\')' | Out-Null" | Out-Null
    # The cab, then the script. Pushed the same way as the MSI of the screen
    # installer. The host has normal internet and a file that a person put
    # there. The guest has neither.
    Copy-ToGuest @($netFxCab.FullName) "$sxs/"
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-netfx3.ps1'))
    $a = @("-Source $($sxs -replace '/','\')")
    if ($VerifyOnly) { $a += '-VerifyOnly' }
    $rc = Invoke-GuestScript 'install-netfx3.ps1' $a
    # Exit 2 of the script means "no payload where I was told to look". After
    # the precondition above, that can only mean that the copy did not arrive.
    # It is different from a DISM failure, because you fix the two in different
    # places.
    Phase 'netfx3' $(if ($rc -eq 0) { $(if ($VerifyOnly) { 'reported' } else { 'ok' }) }
                     elseif ($rc -eq 2) { 'the cab did not arrive in the guest' }
                     else { "FAILED ($rc)" })
    Invoke-GuestPs "Remove-Item '$($sxs -replace '/','\')' -Recurse -Force -EA SilentlyContinue" | Out-Null
}

# ============================================================== 12. cleanup
# Before the manifest, so that the manifest describes the clean guest, not the
# scaffolding. With -VerifyOnly, -WhatIfOnly reports in place of a cleanup.
if ($SkipCleanup) { Phase 'cleanup' 'skipped' } else {
    Say 'cleanup'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\cleanup.ps1'))
    $rc = Invoke-GuestScript 'cleanup.ps1' $(if ($VerifyOnly) { @('-WhatIfOnly') } else { @() })
    Phase 'cleanup' $(if ($rc -eq 0) { $(if ($VerifyOnly) { 'reported' } else { 'ok' }) } else { "FAILED ($rc)" })
}

# ============================================================== 13. the manifest
# Last, and it runs also with -VerifyOnly. A read of the machine changes
# nothing, and a new manifest is the most useful result of a verify run.
if ($SkipManifest) { Phase 'manifest' 'skipped' } else {
    Say 'the manifest'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\write-manifest.ps1'))
    # -McpPort is given, not left to the default of the two files. The manifest
    # reports whether that port has a listener. If it tests a different port
    # from the automation phase, it reports a healthy guest as broken.
    $rc = Invoke-GuestScript 'write-manifest.ps1' @("-McpPort $McpPort", '-Print')
    Phase 'manifest' $(if ($rc -eq 0) { 'ok' } else { "FAILED ($rc)" })
}

# ============================================================== what is left to a human
Say 'summary'
# GetEnumerator(), not .Keys. On a dictionary, member access finds an ENTRY of
# that name before the .NET property. A phase called "keys" made $done.Keys
# return the value of that phase, and the table became one row. A test showed
# this. It looked like a format bug, not a name collision.
$rows = @($script:done.GetEnumerator())
$w = ($rows | ForEach-Object { $_.Key.Length } | Measure-Object -Maximum).Maximum
foreach ($r in $rows) {
    $c = if ($r.Value -eq 'ok') { 'Green' } elseif ($r.Value -match 'FAIL|missing') { 'Red' } else { 'Yellow' }
    Write-Host ("  {0,-$w}  {1}" -f $r.Key, $r.Value) -ForegroundColor $c
}

Write-Host ''
$secrets = @()
if (Test-Path $AdminPassFile) { $secrets += "  Windows password  $AdminPassFile" }
# Even if this run did not write it, the summary names it. draugr_vnc.pass is
# often the only record of the VNC password of a guest. The guest keeps its copy
# in the registry, not in a file. Nothing in Draugr deletes or writes it again.
if (Test-Path $VncPassFile)   { $secrets += "  VNC password      $VncPassFile" }
if ($secrets) {
    Write-Host 'Passwords: for you, not the agent. The agent uses the ssh key and needs neither:' -ForegroundColor Cyan
    $secrets | ForEach-Object { Write-Host $_ }
    Write-Host ''
}
# THE STRAY SECOND DESKTOP IS A STEP FOR A PERSON, ON PURPOSE. That is a
# decision, not a gap. It appears on SOME boots, so one fix is not enough. The
# fix needs an interactive session, and the ssh of this script (session 0)
# cannot reach one. On older guests, an on-demand scheduled task reaches session
# 1. A test showed that on the layer VMs, it does not fire. Automation needs a
# task at logon that calls QueryDisplayConfig/SetDisplayConfig with an explicit
# path array. That is possible, but you cannot test it on demand, because the
# fault appears only on some boots. Until somebody builds that, the person gets
# the steps to click. That costs twenty seconds and never misleads.
#
# If no screen exists, this is not said. This stage makes the screen. Before
# 2b, no VNC server was installed, so advice about the desktop had no place to
# go. The background and the tests: docs/FORGE.md, the stray-second-desktop
# bullet.
if (-not $SkipScreen) {
    Write-Host 'If the screen shows two desktops side by side (a stray taskbar to the right of' -ForegroundColor Cyan
    Write-Host 'the real one), fix it ONCE in the guest. Each layer above gets the fix:' -ForegroundColor Cyan
    Write-Host '  1. In the guest, open Settings -> System -> Display  (or run:  ms-settings:display )'
    Write-Host '  2. Click Identify. Each screen shows a big number, so you can tell which is which.'
    Write-Host '  3. In the dropdown beside the display diagram, choose "Show only on N", where N is'
    Write-Host '     the number on the LARGER screen (the 1920x1080 one, not the 1024x768 stray).'
    Write-Host '     The numbers are not fixed, so read them. Do not guess.'
    Write-Host '  Do NOT use Win+P. On a machine with no internal panel, its projection presets do'
    Write-Host '  nothing (a test showed this). It must be the Settings dropdown.'
    Write-Host '  Windows saves it for each monitor set under HKLM\SYSTEM\...\GraphicsDrivers\Configuration.'
    Write-Host '  Thus it stays after a restart, and each layer frozen later gets it.'
    Write-Host ''
}
Write-Host 'Still for you to do, on purpose:' -ForegroundColor Cyan
if (-not $NetFxSource) {
    Write-Host '  - .NET Framework 3.5. It is OFF, because only you can supply its payload:'
    Write-Host '    \sources\sxs\*netfx3*.cab from the ISO that installed this guest. Unreal asks'
    Write-Host '    Windows for it, and Windows asks you. This guest cannot reach Windows Update.'
    Write-Host '    Thus give --netfx <path> to that cab, and run again.'
}
Write-Host '  - the VNC viewer on the host, unless you gave -InstallViewer. Its install'
Write-Host '    elevates, and this run does not show prompts in the middle.'
Write-Host '  - a frozen layer-0 from this disk. That is dr-layer adopt. Its header gives the'
Write-Host '    order, because the order is the difficult part.'
Write-Host '  - the Epic account, the engine versions, and Visual Studio are LAYERS, not the base.'
Write-Host '    They depend on the account and the version, so they go in a disk above this one.'
if (-not $HardenSshd) {
    Write-Host '  - if you want it, -HardenSshd turns off password authentication in the guest.'
}
$failed = @($rows | Where-Object { $_.Value -match 'FAIL' })
if ($failed.Count) { exit 1 }
