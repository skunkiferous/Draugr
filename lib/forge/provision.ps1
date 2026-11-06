# lib/forge/provision.ps1 - build a forge base image from a fresh Windows 11 guest, in one go.
#
# ==> NOT MEANT TO BE TYPED. bin/dr-layer provision is the front end. <==
#
# Adopted from a hand-written predecessor, which is where every
# measurement in these comments was made. docs/FORGE.md, "Stage two: dr-layer provision".
#
# WHY THE HOST, and not in the guest or the mound. The guest has no network adapter at all:
# until the host has started the gateway mound and the ssh tunnel, the guest cannot reach
# anything, so it cannot be the thing that sets itself up - not as a preference, but in
# principle. Three of the five links are host-side too (the AppSandbox daemon, the mound, the
# tunnel). So the host drives, and reaches into the guest over ssh for the guest's half.
#
# It is IDEMPOTENT throughout. Every phase checks what is already true and reports rather than
# redoing it, so it is safe to re-run after a failure, after a reboot, or just to see where a
# guest stands. -VerifyOnly changes nothing at all.
#
# IT CAN ALSO MAKE THE GUEST. Pass -IsoPath and phase 0 creates the VM and installs Windows in
# it, unattended, with the network already None and an ssh key already in place. Without
# -IsoPath nothing is ever created.
#
# WHAT IT CANNOT DO, and will tell you to do instead:
#   - install AppSandbox itself, turn on the VirtualMachinePlatform Windows feature (that one
#     needs a reboot), or produce a Windows 11 ISO. Those three are the whole of what is left
#     to a human before the first run.
#   - set an EXISTING VM's network to None. It reports the setting and refuses to go on if it
#     is wrong, because provisioning a guest that still has its own way out would bake a hole
#     into the base image. The API can change it (`edit`, while stopped) but this script will
#     not: opening a forge to a network stays something you did, never something a script did
#     on your behalf.
#   - sign in to anything. The Epic account, the engine and Visual Studio are deliberately NOT
#     part of a base (docs/FORGE.md, "What is a layer, not the base").
#
# EVERY PHASE IS HERE NOW, and exactly one of them is off unless asked for: -NetFxSource
# names the `.NET Framework 3.5` payload, which is a file a human has to take out of a
# Windows ISO because no route from this guest can fetch it. See that parameter.
#
# EXIT CODES:
#   0   done, or done with warnings
#   1   a phase failed; the summary says which
#   2   a precondition or an argument is wrong, and nothing was built
#   4   the guest base is incomplete, so the run stopped rather than building on it
#   5   the guest has no way out, so nothing below could install
#
# A guest script that never arrived throws rather than returning a code: see
# Invoke-GuestScript, and the two defects measured in its header.

param(
    [string]$Vm = 'UE5-Test',
    # ---- phase 0, and ONLY phase 0. No -IsoPath, no VM creation. There is deliberately no
    # default: nothing can bring a VM into existence by accident.
    [string]$IsoPath,
    # Sizing. Three of these are editable afterwards on a STOPPED VM - `edit` takes ramMb,
    # cpuCores, gpuMode and networkMode - so they are cheap to get wrong.
    [int]$Ram = 8192,               # for the BUILD. A working forge wants ~48 GB; edit it later.
    [int]$Cores = 8,
    # ---- -DiskGb IS THE ONE NUMBER YOU CANNOT TAKE BACK, and it binds every layer above it.
    #
    #   * THIS disk can never be resized. `edit` does not accept hddGb and no route anywhere
    #     resizes a VM's own disk. Undersizing it costs a full reinstall.
    #   * A CHILD inherits this capacity and can only ever be GROWN, never shrunk - so this
    #     number is a FLOOR for every layer built on top, not a ceiling. (Read from the
    #     source: vhdx_grow refuses a smaller size with E_INVALIDARG and enlarges a larger
    #     one with ResizeVirtualDisk; create-from-template does exactly that to its child
    #     and leaves the parent alone.)
    #   * AppSandbox's OWN snapshots and branches take no size argument at all, so those
    #     children are stuck with precisely what they inherit.
    #
    # So: every descendant of this disk starts at least this large, and nothing anywhere
    # ever shrinks. The VHDX is dynamically expanding (the core passes
    # CREATE_VIRTUAL_DISK_FLAG_NONE), so the file only holds what was really written and a
    # generous number costs nothing until it is used.
    # 512 leaves room for UE5 (100+ GB), a project, a warm DDC and the layer deltas.
    [int]$DiskGb = 512,
    [int]$GpuMode = 1,              # 0 none, 1 paravirtual (what a forge is for), 2 try all
    # WHERE THE DISK GOES. Empty means the daemon's own default, which is normally
    # %ProgramData%\AppSandbox. The VM's folder is <DiskDir>\<Vm> and the disk is
    # disk.vhdx inside it. Put it on your FASTEST volume, not your biggest: reads walk the
    # layer chain, so every parent is on the hot path.
    #
    # DO NOT POINT THIS AT YOUR LAYER STORE WHEN BUILDING A BASE. It looks like the tidy
    # thing to do and it is the wrong shape: the whole folder is deleted with the VM, and a
    # base's last step is deleting the VM - so the one directory you must not aim a VM at is
    # the one holding your read-only layers. Build the base in the DEFAULT directory, which
    # is plainly disposable, and move the finished disk out; on one volume that is a rename,
    # not a 20 GB copy. layer.ps1's header beside this file has the sequence.
    #
    # Raised by a user, who read the delete warning, drew the right conclusion,
    # and pointed out that the advice above it contradicted itself. -DiskDir is for choosing
    # the volume a VM's own disk lives on; it is not how a layer store gets filled.
    [string]$DiskDir = '',
    # The guest inherits the HOST's timezone unless told otherwise. Windows' unattended
    # default is Pacific, which puts every local timestamp in the guest hours away from the
    # clock of whoever is reading it, in every layer built on this one, until somebody
    # fixes it. (Children CAN fix it - a frozen parent does not prevent that, because the
    # guest writes to the top layer - but getting it right once here beats getting it
    # wrong everywhere.) '' leaves the guest alone; 'UTC' is the other defensible answer.
    [string]$TimeZone = (Get-TimeZone).Id,
    [string]$AdminUser = 'forge',
    # Both passwords are ASKED FOR, with a generated default, and kept in files beside the
    # ssh keys - never in your head and never in the repository. Pass them here to answer
    # the prompts in advance; -Yes takes the generated value without asking.
    [string]$AdminPass = '',
    [string]$AdminPassFile = "$env:USERPROFILE\.ssh\draugr_forge.pass",
    [int]$TimeoutMin = 90,          # a Windows install from a cold ISO, with headroom
    [switch]$Yes,                   # skip the single confirmation before a VM is created
    [string]$AdminKey = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [string]$TunnelKey = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519",
    [string]$Proxy = '127.0.0.1:3128',
    # The SECOND password, and it is VNC's. Eight characters because that is the protocol's
    # auth key, not a policy - see the credentials block for why it cannot be the Windows
    # one. Asked for only when the screen phase will actually run.
    [string]$VncPass = '',
    [string]$VncPassFile = "$env:USERPROFILE\.ssh\draugr_vnc.pass",
    # Your own MSI instead of the pinned TightVNC build. This is the supported road to
    # UltraVNC, whose download cannot be scripted at all - lib/forge/screen-access.ps1's
    # header has the measurement and the comparison.
    [string]$VncMsi,
    # THE HOST'S VIEWER IS NOT INSTALLED BY DEFAULT, and that is a deliberate difference from
    # the script this was adopted from. Installing it elevates, and an hour-long unattended
    # run must not stop to raise a UAC prompt - the whole point of asking every question up
    # front. lib/forge/screen.ps1 copes without one: it leaves the forward up and says that
    # any viewer pointed at it will do. docs/FORGE.md, "2b's own five decisions".
    [switch]$InstallViewer,
    # 8765 inside the guest because lib/forge/tunnel.ps1 forwards host 18765 to exactly that
    # port. DELIBERATELY NOT a dr-layer flag: moving the server would move it away from the
    # tunnel that reaches it. Passed to the automation phase AND to the manifest so the two
    # cannot drift apart silently.
    [int]$McpPort = 8765,
    # What the server's console window does on the autologon desktop. Not cosmetic-only: the
    # agent's own window list and every screenshot it takes include that window.
    # install-automation.ps1's Set-McpWindow explains what each choice costs.
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
    # ---- .NET FRAMEWORK 3.5, AND THE ONE PHASE THAT IS OFF UNLESS ASKED FOR.
    #
    # NOT A -SkipNetFx, which is what the script this was adopted from had. The difference is
    # not taste: NetFx3 is a Feature on Demand, so its payload is NOT on the installed system
    # and Windows fetches it from Windows Update - which install-guest-base turns off, and
    # which a guest with no adapter could not reach regardless. The payload exists in one
    # place, \sources\sxs on a Windows ISO, and it MUST match the guest's build or DISM
    # fails 0x800f081f and blames the source.
    #
    # So the precondition is a file only a person can produce, and a phase that fails on
    # every fresh machine teaches a reader to ignore the red row. This parameter is therefore
    # the switch AND the precondition at once: giving it turns the phase on, and its value is
    # what makes the phase possible. There is no second flag that could disagree with it.
    #
    # It is a HOST path. The cab is pushed into the guest over ssh rather than fetched from
    # the vault, which is what lets the check happen in the preconditions block instead of
    # after phase 11 - and lets this work on a gateway that serves no vault at all.
    # install-netfx3.ps1 keeps its vault route for anyone running it by hand.
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
# Scripts are COPIED and run with -File, never piped into `powershell -Command -`: that
# form executes stdin line by line as if typed, so a multi-line block is read as
# incomplete and the rest is silently swallowed, exit code 0 and no output. Measured
#, after three scripts "succeeded" that way.
function Copy-ToGuest([string[]]$Paths, [string]$Dest = 'C:/Windows/Temp/') {
    Invoke-Native { & scp.exe -q -i $AdminKey -P $script:sshPort -o IdentitiesOnly=yes `
        -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm @Paths `
        "$($script:guestUser)@127.0.0.1:$Dest" 2>&1 } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "scp to the guest failed ($LASTEXITCODE)" }
}
# NOT named $Args: that is a PowerShell automatic variable, and a parameter of that name
# silently receives nothing. Measured on the first run of this script, where -VerifyOnly
# never reached the guest and a read-only run changed a setting.
function Invoke-GuestScript([string]$Name, [string[]]$ScriptArgs = @()) {
    $remote = "C:\Windows\Temp\$Name"
    # ============================ TWO MEASURED DEFECTS, BOTH CLOSED HERE ================
    # MEASURED, on the first run of this script that ever reached the guest.
    # Every guest-side phase failed and every one of them reported `ok`.
    #
    # 1. PLAIN DOUBLE QUOTES AROUND THE PATH LOSE THEIR BACKSLASHES, and only when this
    #    script is launched the way bin/dr-layer launches it. `-File "C:\Windows\Temp\x.ps1"`
    #    arrived in the guest as `C:WindowsTempx.ps1`. The same three forms, probed against
    #    the same guest:
    #
    #                        from Windows PowerShell | from WSL bash -> powershell.exe
    #      -File "$remote"              intact       |   C:WindowsTempx.ps1   <- eaten
    #      -File \"$remote\"            intact       |   intact
    #      -File $remote                intact       |   intact
    #
    #    THAT CONTEXT IS WHY IT SURVIVED ADOPTION. The script this came from was typed in a
    #    Windows PowerShell, where the bug does not exist; bin/dr-layer runs it from bash in
    #    WSL, where it does. A comment here used to say the plain quotes were safe "because
    #    that path has no space for the quoting to matter to" - true about spaces, and the
    #    wrong conclusion. Nothing is quoted below, and the path has no space to need it.
    #
    # 2. `powershell -File <missing>` EXITS ZERO. It writes "The argument '...' to the -File
    #    parameter does not exist" to stderr and returns 0, so a path that never resolved is
    #    indistinguishable from a phase that worked. That is what turned defect 1 from a
    #    visible failure into fourteen green rows. Genuine codes DO propagate - a guest
    #    script exiting 4 arrives as 4, measured through this exact pipeline - so the gap was
    #    only ever this one case.
    #
    #    So the guest's own cmd.exe decides, and absence gets a code of its own. 127 is the
    #    shell convention for "not found" and no guest script here uses it.
    # ====================================================================================
    $cmd = "if exist $remote " +
           "(powershell -NoProfile -ExecutionPolicy Bypass -File $remote $($ScriptArgs -join ' ')) " +
           "else (exit /b 127)"
    # The guest's output is written to the console, NOT returned. `$rc = Invoke-GuestScript`
    # would otherwise capture every line the guest printed into $rc, with the exit code as
    # the last element of an array of text - so the guest appeared to run silently and the
    # phase was judged on a string. Measured the hard way on the first run of this script.
    Invoke-Native { & ssh.exe -n -i $AdminKey -p $script:sshPort -o IdentitiesOnly=yes `
        -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
        "$($script:guestUser)@127.0.0.1" $cmd 2>&1 } | ForEach-Object { Write-Host "  $_" }
    $rc = $LASTEXITCODE
    # THROWN, not returned, and not reported as a phase failure either. Copy-ToGuest already
    # throws when scp fails, so 127 means scp said it succeeded and the file is still not
    # there - a defect in THIS script, not a condition of the guest. Returning it would put
    # one more code into fourteen call sites that each judge $rc differently, and the one
    # thing this must never do again is let "it never ran" read as a result.
    if ($rc -eq 127) {
        throw ("$Name never ran: it is not at $remote in the guest, although the copy " +
               'reported success. Nothing below this point has been verified.')
    }
    return $rc
}
# An argument VALUE WITH A SPACE in it needs backslash-escaped quotes, not plain ones.
# Invoke-GuestScript's command string crosses four parsers - this shell, PowerShell's
# native-argument quoting, ssh's argument joining, and the guest's cmd.exe - and plain
# double quotes are consumed on the way. MEASURED against a live guest, passing
# the value "W. Europe Standard Time":
#
#   -TimeZone "W. Europe Standard Time"     arrived as -TimeZone W.   + 3 loose words
#   -TimeZone 'W. Europe Standard Time'     the same
#   -TimeZone \"W. Europe Standard Time\"   arrived intact
#   -TimeZone ""W. Europe Standard Time""   arrived intact
#
# HOW IT FAILED IS THE LESSON, not that it failed: the loose words bound to the next
# parameters BY POSITION, so "Standard" landed on [int]$CursorSize and the guest complained
# about a parameter nobody had passed. A quoting bug does not announce itself as one.
#
# AND THAT TABLE WAS READ TOO NARROWLY ONCE. It says plain quotes are consumed, and a
# comment here concluded that -File "$remote" was still safe because the path has no space
# in it. The quotes are not merely consumed when launched from WSL - they take the path's
# BACKSLASHES with them. Invoke-GuestScript above has the measurement and the three forms.
# Quote a value because the quoting is measured to survive, never because the value looks
# harmless.
function Format-GuestArg([string]$Name, [string]$Value) {
    if ($Value -match '\s') { "$Name \`"$Value\`"" } else { "$Name $Value" }
}
# Anything inline goes as ONE base64 blob. A PowerShell snippet written as a quoted
# argument has to survive this shell, ssh's argument joining and the guest's default shell,
# and nested quotes do not: -EncodedCommand has no such edge.
function Invoke-GuestPs([string]$Ps) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Ps))
    Invoke-Native { & ssh.exe -n -i $AdminKey -p $script:sshPort -o IdentitiesOnly=yes -o BatchMode=yes `
        -o StrictHostKeyChecking=accept-new -o HostKeyAlias=draugr-$Vm `
        "$($script:guestUser)@127.0.0.1" `
        "powershell -NoProfile -EncodedCommand $b64" 2>&1 }
}
# After a phase that REBOOTS the guest. "Back" means sshd answers a command, not that the
# port accepts a connection: sshd listens again several seconds before it can run a script,
# so a connect-only probe hands the next phase a guest that refuses it.
#
# MEASURED: install-vault-access.ps1 restarts the guest so srv2/srvnet let go of
# port 445, and the two phases after it ran straight into the shutdown - cleanup died after
# printing its own banner, the manifest got "Connection closed by remote host", and both
# were reported as FAILED with nothing actually wrong with either of them.
function Wait-GuestBack([int]$TimeoutSec = 300) {
    # The guest is still up for a few seconds after a reboot is requested, and a probe that
    # succeeds against a guest on its way down is worse than no probe at all.
    Start-Sleep 20
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        # A distinctive token, not 'ok'. What comes back while the guest is down is ssh's own
        # failure text, and matching anything that could occur inside an error message would
        # declare the guest up in the middle of its reboot.
        if ((Invoke-GuestPs 'Write-Output "GUEST-IS-BACK"') -match 'GUEST-IS-BACK') {
            Note ("the guest is back after {0:n0}s" -f $sw.Elapsed.TotalSeconds)
            return $true
        }
        Start-Sleep 5
    }
    Warn ("the guest did not answer ssh within {0}s of the reboot - the phases below will" -f $TimeoutSec)
    Warn '  fail against a guest that is not up, which is a symptom and not the cause.'
    return $false
}
function Invoke-Native([scriptblock]$Block) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block } finally { $ErrorActionPreference = $old }
}

# Test-SandboxdReachable - can the shell THIS script runs in talk to a sandboxd?
#
# $true reachable, $false not, $null cannot tell (sbx.exe is not on the host PATH).
#
# MEASURED, because all three properties matter:
#   - `sbx daemon status` EXITS 0 either way, so the text is the only signal.
#   - reachable prints "Status: running" and "(connected)"; unreachable prints
#     "Status: stopped" and "(not connected)" - on the very same live daemon, from an
#     unelevated shell. "stopped" here means "not reachable from here", not "not running".
#   - it STARTS NOTHING: the sbx.exe pid list is identical before and after. That is the
#     property this probe lives or dies by, since a probe that spawned the daemon would
#     commit the exact mistake the caller is trying to avoid.
function Test-SandboxdReachable {
    if (-not (Get-Command sbx.exe -ErrorAction SilentlyContinue)) { return $null }
    # 2>&1 on a native command needs the EAP guard: under 'Stop' a line of native stderr
    # arrives as a terminating ErrorRecord and takes the script with it.
    $out = Invoke-Native { & sbx.exe daemon status 2>&1 }
    return [bool](($out -join "`n") -match '(?m)^\s*Status:\s*running')
}

# ================================================================= preconditions
Say 'preconditions'

$asbDir = Join-Path $env:ProgramData 'AppSandbox'
$hostJson = Join-Path $asbDir 'host.json'
if (-not (Test-Path $asbDir)) {
    Fail "AppSandbox is not installed on this host ($asbDir is missing)."
    Fail 'Install AppSandbox, enable the VirtualMachinePlatform Windows feature (it needs'
    Fail '  a reboot), start the daemon elevated, then re-run with -IsoPath.'
    exit 2
}
if (-not (Test-Path $hostJson)) {
    Fail "No headless daemon: $hostJson is absent."
    Fail 'Start it elevated, which is the one step no Draugr command can take:'
    Fail '    Start-Process AppSandbox.exe -ArgumentList ''--headless'' -Verb RunAs'
    exit 2
}
$hj = Get-Content $hostJson -Raw | ConvertFrom-Json
$api = "$($hj.endpoint)/v1"
$hdr = @{ Authorization = "Bearer $($hj.token)" }
Note "AppSandbox $($hj.version), API $api"

# NOTHING HERE STARTS A DAEMON OR A MOUND, and that is the rule rather than an accident.
#
# WHOEVER STARTS sandboxd DECIDES WHO MAY USE IT. Integrity runs ONE WAY: an elevated client
# can use a daemon an ordinary shell started, but not the reverse. So a dr-* command run
# elevated with no sandboxd up starts an ELEVATED one, post-up's keeper pins it for the whole
# life of the mound, and every later command from an ordinary terminal then fails in the worst
# available way.
#
# MEASURED, in the script this was adopted from, which did start the mound itself:
# sandboxd pid 3700, started 11:07:51 by exactly that path, still serving at 20:32 and
# answering /daemon/health 200 - while an unelevated `dr-up` reported "Status: stopped", tried
# to start its own, found the lock held, and said "previous sandboxd (PID 3700) did not exit
# within 10s" about a process it was not permitted to see (its command line reads as DENIED
# from medium integrity, where explorer.exe's reads fine). Nothing looked broken, and nothing
# was. It cost an evening.
#
# WHAT CHANGED HERE. bin/dr-layer brings the gateway up through dr-dep, in the ordinary shell
# you typed in, before this script runs; this script only ever talks to the daemon over HTTP,
# which needs no elevation at all - the token is in host.json and every other dr-* command
# does the same. So there is nothing for this script to start, and no -AllowElevatedGateway to
# overrule it with. What is left is worth reporting rather than assuming: if no sandboxd is
# reachable, the gateway cannot be up, and nothing below can download anything.
if (-not $SkipGateway -and -not $VerifyOnly) {
    $sbxUp = Test-SandboxdReachable
    if ($null -eq $sbxUp) {
        Note 'sbx.exe is not on the host PATH; cannot check whether a sandboxd is reachable'
    } elseif ($sbxUp) {
        Note 'sandboxd is reachable, so the gateway mound can be up'
    } else {
        Warn 'no sandboxd is reachable from here, so the gateway mound cannot be up - and the'
        Warn '  guest has no other way out. From an ORDINARY (not elevated) WSL terminal, in'
        Warn '  the project that names this forge:'
        Warn '    dr-forge up        # the gateway, the VM and the tunnel, in order'
        Warn '  If sbx says "running" in an elevated shell and "stopped" in an ordinary one,'
        Warn '  an elevated daemon is already up: take the mound down with dr-stop and bring'
        Warn '  it back up unelevated.'
    }
}

# ---- the .NET 3.5 payload, checked HERE because here is before the hour.
# A folder or the cab itself. Resolved now so every later use is an absolute path, and
# refused now so a typo costs a second rather than a Windows install.
if ($NetFxSource) {
    if (-not (Test-Path $NetFxSource)) {
        Fail "-NetFxSource does not exist: $NetFxSource"
        Fail '  It is a path on THIS host - a folder holding the NetFx3 cab, or the cab.'
        exit 2
    }
    $NetFxSource = (Resolve-Path $NetFxSource).Path
    # Globbed rather than named: the cab carries a build-specific suffix and a locale, so one
    # hardcoded spelling becomes "not found" after the next Windows release.
    #
    # A FILE IS CHECKED AGAINST THE SAME PATTERN AS A FOLDER'S CONTENTS, and that is not
    # pedantry: taken on trust, the wrong file would be pushed in, the guest script would
    # glob for *netfx3*.cab beside it, find none, and exit 2 - which the phase below reports
    # as "the cab did not arrive in the guest". It arrived. It is not a cab. One wrong word
    # in a summary sends someone to debug scp.
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
            Fail '  The name must match *netfx3*.cab - it is checked here rather than in the'
            Fail '  guest, where a wrong file reads as a file that never arrived.'
        } else {
            Fail "no *netfx3*.cab in $NetFxSource"
        }
        Fail '  Take it from the Windows ISO the guest was installed from - a cab from a'
        Fail '  different build fails with 0x800f081f, which reads as a missing file:'
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
# The alphabet drops the glyphs that get read wrongly off a screen - l, I, 1, O, 0 - because
# the VNC password in particular is retyped by a human into a viewer prompt.
function New-Secret([int]$Length) {
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join (0..($Length - 1) | ForEach-Object { $alphabet[$bytes[$_] % $alphabet.Length] })
}
# Precedence: what you passed on the command line, then what is already on disk - so a
# re-run never silently invents a new password for an account that already has one - then
# a fresh one offered as the default of a prompt.
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
    # VNC's auth key is EIGHT BYTES. TightVNC takes a longer password, truncates it to 8
    # and says nothing - so you walk away believing in a password that was never set. Do
    # the same truncation out loud, and write the truncated value back, so the file and
    # the server always agree about what the password actually is.
    if ($MaxLength -and $pw.Length -gt $MaxLength) {
        Warn "that $What is longer than $MaxLength characters, which the VNC protocol cannot carry."
        $pw = $pw.Substring(0, $MaxLength)
        Warn "  truncated to '$pw' - that is the real password, and it is what gets saved."
        $fromFile = $false
    }
    if ($fromFile) { return $pw }
    $dir = Split-Path $File -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($File, $pw)
    # Same treatment as a private key: this account only, inheritance off.
    icacls $File /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    Note "$What saved to $File"
    return $pw
}

# Draugr's commands are bash, so they run in WSL. They may be on the PATH there (install.sh
# links them into ~/.local/bin) or not, so resolve it once instead of assuming: an
# unqualified `dr-up` that is not found looks identical to a gateway that failed.
#
# RESOLVED HERE, ABOVE PHASE 0, because it can set $SkipGateway - and whether anything will
# bring the mound up is exactly what the create decision below needs to know.
# NOTHING HERE LOOKS FOR DRAUGR IN WSL ANY MORE, and the absence is deliberate. The script
# this was adopted from had to find dr-up - on the PATH, or "beside the gateway repo" - because
# its phase 4 ran it. Phase 4 now verifies instead (see there), and bin/dr-layer brings the
# gateway up through dr-dep before this script is called, so there is nothing to resolve and
# no guess to get wrong.

# ================================================================= credentials, up front
# Every question a human has to answer is asked HERE, in one place, before anything slow
# begins - so an hour-long Windows install can never stop half way to ask something.
#
# BOTH PASSWORDS ARE FOR THE HUMAN. The agent needs NEITHER of them: it authenticates with
# an ssh key, and that session already lands elevated with a full token (measured - it
# writes System32, reads HKLM and controls services without ever being prompted). It does
# not even need to be told the user name, because ssh_info() reports it. adminPass is used
# in exactly one place in this whole repository - the create body below - and never again.
# What these are for is the day autologon breaks or the desktop locks and you are looking
# at a login prompt, where ssh is no help. Keep them for that.
#
# THE TWO ARE DELIBERATELY NOT THE SAME, and it is not caution for its own sake:
#
#   - VNC's auth takes an EIGHT-BYTE key. TightVNC truncates anything longer without a
#     word, so "the same password" would silently become "the first 8 characters of it",
#     which is the worst of both worlds: not actually shared, and capping the Windows
#     account at 8 characters if you made them match by hand.
#   - TightVNC stores it in HKLM\SOFTWARE\TightVNC\Server as 8 bytes of DES under the
#     fixed, published VNC key (MEASURED in the guest: 8-byte Byte[], readable
#     by Administrators and SYSTEM). That is plaintext with extra steps.
#   - The ssh sessions this script uses are ELEVATED, so the agent can read that value
#     whenever it likes. Sharing the secret would hand the agent the Windows account.
#
# The Windows password is separately recoverable inside the guest anyway - AppSandbox's
# autologon writes it to Winlogon\DefaultPassword as a cleartext string (measured) - so
# sharing turns one recoverable secret into two, and buys nothing: neither is ever typed
# from memory, both live in files on the host.
$existingVm = $null
try {
    $existingVm = (Invoke-RestMethod -Uri "$api/vms" -Headers $hdr -TimeoutSec 15).vms |
                  Where-Object { $_.name -eq $Vm }
} catch { }

$willCreate = ($IsoPath -and -not $existingVm -and -not $VerifyOnly)
# Asked ONLY when the screen phase will really install something and there is no password on
# disk already. A prompt for a secret that nothing will set is how a person comes to believe
# a password was configured.
$willScreen = (-not $SkipScreen -and -not $VerifyOnly -and -not (Test-Path $VncPassFile))

if ($willCreate -or $willScreen) {
    Say 'credentials'
    Note 'These are for YOU, not for the agent: it logs in with an ssh key and its session'
    Note 'is already elevated. A password matters on the day autologon breaks or the desktop'
    Note 'locks and you are facing a login prompt, which ssh cannot answer.'
    Note ''
    Note 'They are asked separately because VNC cannot carry the same secret: its auth key is'
    Note 'EIGHT characters, and TightVNC truncates anything longer without a word.'
    Note ''
    Note 'Press Enter to accept the generated value, or type your own.'
}
if ($willCreate) {
    if (-not $Yes) {
        $typedUser = Read-Host "  Windows account name [$AdminUser]"
        if ($typedUser) { $AdminUser = $typedUser }
    }
    # 20 characters: nothing truncates it, and nobody has to type it - autologon replays it.
    $AdminPass = Get-Secret $AdminPass $AdminPassFile 20 'Windows password'
}
if ($willScreen) {
    $VncPass = Get-Secret $VncPass $VncPassFile 8 'VNC password' ' (8 characters max)' 8
}

# ========================================================= 0. create the VM, if asked to
# ONLY when -IsoPath is given. This is the one irreversible thing in the whole script - it
# eats tens of gigabytes and the better part of an hour - so it sits behind a parameter
# with no default, it refuses to touch a VM that already exists, and it asks once before
# it starts. Everything after it is idempotent, as it always was.
#
# THE WINDOWS INSTALL IS FULLY UNATTENDED, and that is AppSandbox's doing, not ours: the
# core generates an autounattend.xml and patches it into a copy of the ISO (OOBE hidden,
# HideOnlineAccountScreens, BypassNRO so it never demands a network, the TPM check
# bypassed) and stages its guest agent alongside. There is nothing to click, which is why
# "installing Windows is mostly waiting" is a thing a script can wait through.
#
# sshDeployKey IS THE ANSWER TO THE CHICKEN-AND-EGG. The daemon generates an ed25519
# keypair under %ProgramData%\AppSandbox\ssh\ and the guest agent writes the public half
# into administrators_authorized_keys WITH the strict ACL sshd insists on. That is exactly
# the block this script used to print for a human to paste, done by the one thing that is
# already inside the guest. The keys phase below then uses it to install ours.
#
# networkMode is hard-coded to 0 (None) and is NOT a parameter. The design says a forge has
# no way out except the gateway, and a base image is the worst possible place to bake in an
# exception. Same reasoning as the refusal above for an existing VM.
#
# testMode is hard-coded OFF. The README calls it "skip interactive setup where supported",
# which is what it means on Linux; on Windows it does exactly one thing - `bcdedit /set
# testsigning on` - and a base image that loads unsigned drivers is not one we want. The
# interactive setup is already skipped, unconditionally, by the unattend above.
if ($IsoPath) {
    if ($existingVm) {
        Note "'$Vm' exists already - phase 0 does nothing (which is what makes it re-runnable)."
        Phase 'create' 'already there'
    } elseif ($VerifyOnly) {
        Fail "'$Vm' does not exist, and -VerifyOnly will not create it."
        exit 2
    } else {
        Say "create '$Vm', and install Windows in it"

        if (-not (Test-Path $IsoPath)) { Fail "No ISO at $IsoPath"; exit 2 }
        $IsoPath = (Resolve-Path $IsoPath).Path

        # The daemon validates a name exactly as the GUI does. Saying so here costs one
        # `if` and saves a round trip that comes back as a bare 400.
        if ($Vm.Length -gt 15 -or $Vm -notmatch '^[A-Za-z0-9-]+$' -or
            $Vm -match '^-' -or $Vm -match '-$' -or $Vm -match '^[0-9]+$') {
            Fail "'$Vm' is not a valid Windows guest name."
            Fail '  <=15 characters (NetBIOS), letters digits and hyphens only, not all'
            Fail '  digits, and no leading or trailing hyphen.'
            exit 2
        }
        if ($AdminUser.Length -gt 20) { Fail '-AdminUser must be 20 characters or fewer.'; exit 2 }
        if ($Ram % 2) { $Ram-- }        # ramMb must be 2 MB-aligned; the API rejects odd
        if ($Ram -lt 512)  { Fail '-Ram must be at least 512 MB.'; exit 2 }
        if ($DiskGb -lt 1) { Fail '-DiskGb must be at least 1.'; exit 2 }

        # Ask the daemon, do not assume C:. It reports free space for the volume that
        # actually holds the disks (`defaultDiskDirectory`), which is configurable, and it
        # also tells us what the existing VMs have already declared.
        $hostInfo = $null
        try { $hostInfo = Invoke-RestMethod -Uri "$api/host" -Headers $hdr -TimeoutSec 15 } catch { }

        # WHERE THE DATA GOES, said as its own line. "N GB free in X" answers a different
        # question - it says where the free space was measured, not where this VM will live -
        # and where the data lands is the first thing anyone sensibly asks. The daemon builds
        # the VM's folder as <diskDirectory>\<name>, with disk.vhdx inside it.
        $diskRoot = if ($DiskDir) { $DiskDir }
                    elseif ($hostInfo -and $hostInfo.defaultDiskDirectory) { $hostInfo.defaultDiskDirectory }
                    else { "$env:ProgramData\AppSandbox" }
        $vmDir  = Join-Path $diskRoot $Vm
        $vmDisk = Join-Path $vmDir 'disk.vhdx'

        # Free space on the volume that will REALLY hold it. host().freeGb measures the
        # daemon's default directory, which is the wrong volume the moment -DiskDir moves
        # the disk somewhere else.
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
        Note 'network    None (0); ssh on, with the AppSandbox key deployed'
        Write-Host ''
        Note "DISK GOES HERE"
        Note "  $vmDisk"
        Note ("  declared {0} GB, sparse - the file holds only what is actually written{1}" -f `
              $DiskGb, $(if ($free) { ", and $qualifier has $free GB free now" } else { '' }))
        if (-not $DiskDir) { Note '  that is the daemon''s default; -DiskDir puts it elsewhere' }
        Warn "  AppSandbox DELETES $vmDir recursively when this VM is deleted,"
        Warn '  so nothing you want to keep may ever live beside this disk.'
        # WHERE THE DISK LIVES DOES NOT CHANGE THIS, and saying so here is the point: the
        # folder above is just <DiskDir>\<name>, so the warning reads the same under
        # C:\ForgeLayers as under ProgramData. What makes a disk deletable is that a VM
        # POINTS AT IT, not its path - and -DiskDir is about where the layer tooling can see
        # it, not about this. Asked by a user who had moved the disk to C:\ForgeLayers
        # precisely to escape this line, which is a fair reading of it.
        Note '  Moving it elsewhere does not change that: the folder is <DiskDir>\<name>,'
        Note '  so this reads the same wherever the disk lives. What ends the exposure is'
        Note '  having no VM point at it - which is what, for a disk that becomes a frozen'
        Note '  base, dr-layer freeze --unregister does: it drops the VM block and'
        Note '  leaves the file. Until then this disk is deletable with this VM.'
        # The daemon will not CREATE this folder, and it says so only after the confirmation
        # below - so the state of it belongs in the summary, where the decision is made.
        if ($DiskDir -and -not (Test-Path $DiskDir)) {
            Note "  $DiskDir does not exist yet; this run creates it."
            # WHY THIS IS NOT A PROMPT. Naming a folder with -DiskDir IS the request to use
            # it, the confirmation below already covers the whole create, and a second
            # Read-Host would have to honour -Yes - so it could only ever guard interactive
            # runs. What a prompt WOULD catch is a typo, and depth catches that better:
            # New-Item -Force builds an entire missing chain without a word, so
            # -DiskDir C:\Frgoe\Layers succeeds exactly as readily as the path you meant.
            # One new leaf under an existing root is ordinary; a missing PARENT too is not.
            $parentDir = Split-Path $DiskDir -Parent
            if ($parentDir -and -not (Test-Path $parentDir)) {
                Warn "  and so does its parent, $parentDir - check the spelling."
                Warn '  A mistyped -DiskDir is created just as willingly as a correct one,'
                Warn '  and the disk then lives somewhere you did not mean it to.'
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
            Warn '  That is allowed - the VHDX expands dynamically, so the file holds only'
            Warn '  what is actually written - but the host can still run out as it fills.'
        }
        if ($hostInfo -and ($Ram / 1024) -gt ($hostInfo.hostRamMb / 1024 / 2)) {
            Warn "-Ram is more than half this host's RAM; the mound and the host need theirs too."
        }
        Warn 'The disk size is the permanent one: this disk can never be resized, and every'
        Warn '  layer built on top of it starts at least this large. RAM, cores, GPU and'
        Warn '  network can all be changed later on a stopped VM; the disk cannot.'

        # An account with no password, auto-logged-in, is defensible only because this guest
        # has no network of its own and no way in but a key-only ssh on the host loopback.
        # Pass -AdminPass if you would rather have one; nothing else in the design cares.

        # EGRESS, JUDGED NOW RATHER THAN AT PHASE 6. The guest gets no adapter, so every byte
        # it installs comes through the mound's proxy. If nothing will provide that, the run
        # dies at the egress gate - AFTER Windows has finished installing, which is the hour
        # you just spent. Say it here, while the decision is still free.
        #
        # Only the MOUND can be judged now, and only in one direction: a mound that is down
        # is usually fine, because phase 4 runs `dr-up` and that is idempotent. What is NOT
        # fine is a mound that is down with nothing left to start it - which is what
        # -SkipGateway means, including when the resolution above set it because dr-up could
        # not be found in WSL at all. That case is silent today and costs the whole install.
        #
        # The tunnel cannot be judged at all: it forwards into a VM that does not exist yet.
        $moundUp = [bool](Get-NetTCPConnection -LocalPort 18888 -State Listen -EA SilentlyContinue)
        Write-Host ''
        Warn 'The guest will have no way out of its own. Everything from phase 7 down'
        Warn '  installs by downloading, and all of it goes through the mound''s proxy over'
        Warn '  the ssh tunnel. BOTH have to be up by phase 6, or this run stops there with'
        Warn '  a fully installed Windows and nothing on top of it.'
        if ($moundUp) {
            Note '  mound   127.0.0.1:18888 answers'
        } elseif ($SkipGateway) {
            Fail '  mound   127.0.0.1:18888 silent, AND the gateway phase is skipped - so'
            Fail '          nothing in this run will start it. Fix that first.'
        } else {
            Note '  mound   127.0.0.1:18888 silent; phase 4 runs dr-up, which is idempotent'
        }
        Warn '  tunnel  cannot be judged yet: it forwards into a VM that does not exist.'
        Warn '          Phase 5 registers it, and its log is %LOCALAPPDATA%\Draugr\forge-tunnel.log'
        Warn '          - read that first if phase 6 fails, because a registered task that'
        Warn '          never started looks exactly like a working one from here.'

        if (-not $Yes) {
            Write-Host ''
            $answer = Read-Host '  Create this VM and install Windows? It takes 20-60 minutes. [y/N]'
            if ($answer -notmatch '^[Yy]') { Fail 'Nothing was created.'; exit 0 }
        }

        # THE DAEMON VALIDATES diskDirectory AND WILL NOT CREATE IT. MEASURED: a
        # -DiskDir naming a folder that did not exist yet came back
        #   400 invalid_arg "Disk storage location must be an existing accessible folder."
        # It is returned by the create call itself, before the daemon builds anything, so
        # the cost is the prompt and another invocation rather than the install - but it is
        # charged AFTER the 20-60 minute confirmation has been given, which is the wrong
        # side of the decision for a missing mkdir to be discovered on.
        #
        # Created here rather than up in the summary, so declining the prompt still leaves
        # nothing behind - and only when -DiskDir asked for somewhere specific, because an
        # empty one means the daemon's own default, which exists by definition.
        if ($DiskDir -and -not (Test-Path $DiskDir)) {
            try {
                New-Item -ItemType Directory -Force -Path $DiskDir -ErrorAction Stop | Out-Null
                Note "created $DiskDir"
            } catch {
                Fail "could not create $DiskDir"
                Fail "  $($_.Exception.Message)"
                Fail '  The daemon will not create it either, so nothing can be built there.'
                Fail '  Pick a -DiskDir you can write to, or drop it for the default.'
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
        # Empty means "the daemon's default", which is exactly what the GUI sends, so the
        # field is omitted rather than sent blank.
        if ($DiskDir) { $body.diskDirectory = $DiskDir }

        try {
            Invoke-RestMethod -Method Post -Uri "$api/vms" -Headers $hdr `
                -Body ($body | ConvertTo-Json) -ContentType 'application/json' `
                -TimeoutSec 60 | Out-Null
        } catch {
            # A 400 is documented to carry {"error":{"code":"invalid_arg","message":...}}.
            # Windows PowerShell 5.1 does not put that in ErrorDetails, so read the stream;
            # PS7 does, so try it first. MEASURED: probe 400s came back with an
            # EMPTY body, so an empty one is reported as such rather than swallowed.
            $detail = $_.ErrorDetails.Message
            if (-not $detail -and $_.Exception.Response) {
                try {
                    $rs = $_.Exception.Response.GetResponseStream()
                    $detail = (New-Object IO.StreamReader($rs)).ReadToEnd()
                } catch { }
            }
            Fail "The daemon refused the create: $($_.Exception.Message)"
            if ($detail) { Fail "  $detail" } else { Fail '  (it sent no body to say why)' }
            exit 2
        }

        # create() is async AND auto-starts, so the VM walks building -> installing ->
        # booting -> online by itself. Poll `state` rather than listening to the SSE event
        # stream: a poll reads the live state every time, so a dropped connection cannot
        # make it miss a transition. The README says the same.
        Note 'created; now waiting. building -> installing -> booting -> online'
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
            Fail '  It may simply still be installing: re-run WITHOUT --iso to pick it up'
            Fail "  where it is, or raise -TimeoutMin. The daemon's log is $asbDir\headless.log."
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
    Fail '  Pass -IsoPath <a Windows 11 ISO> and this script will create it for you.'
    exit 2
}
if (-not $info.installComplete) {
    Fail "'$Vm' has no finished Windows install yet (state=$($info.state))."
    Fail '  If it says "installing" it is simply still going: wait, and re-run.'
    exit 2
}
if (-not $info.running) {
    if ($VerifyOnly) { Fail "'$Vm' is not running."; exit 2 }
    Note "starting '$Vm'..."
    Invoke-RestMethod -Method Post -Uri "$api/vms/$Vm/start" -Headers $hdr -Body '{}' `
        -ContentType 'application/json' -TimeoutSec 60 | Out-Null
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep 2
        $info = (Invoke-RestMethod -Uri "$api/vms" -Headers $hdr).vms | Where-Object { $_.name -eq $Vm }
        # >= 2, not -eq 2: see Wait-SshReady. A VM that goes straight to 4 would never
        # match an equality test, and this loop would spin its full 180 s for nothing.
        if ($info.sshState -ge 2) { break }
    }
}
Note "'$Vm' state=$($info.state) gpuMode=$($info.gpuMode) ram=$($info.ramMb)MB cpus=$($info.cpuCores)"

# networkMode 0 is None. Anything else and the guest has an adapter of its own, which
# would give it egress the gateway never sees - and this script would then bake that into
# a base image other VMs are built from.
if ($info.networkMode -ne 0) {
    Fail "'$Vm' has networkMode=$($info.networkMode), not None (0)."
    Fail '  Stop the VM and set it to None - in the GUI, or POST /v1/vms/<name>/edit with'
    Fail '  {"networkMode":0}, which the API accepts while it is stopped - then re-run.'
    Fail '  This script will not do it for you: see the header.'
    exit 2
}
Note 'network: None, as the design requires'

# A VM THAT SAYS 'online' IS NOT YET A VM YOU CAN SSH INTO. The daemon reports the guest's
# ssh readiness separately, through sshInfo, and until the guest agent gets there it answers
# port 0 / sshState 0. MEASURED on a fresh create: 'online' was reported, sshInfo
# answered 0/0 one call later, and the run died on `Bad port '0'` - then offered to have the
# key pasted in by hand, for a VM whose key was going to arrive on its own seconds later.
#
# WHY THIS SURVIVED SO LONG: a wait on sshState did exist, but only in the branch that has to
# START a stopped VM. A freshly created VM is auto-started by the daemon, so it is already
# running, that branch never runs, and the only wait there was got skipped - on the one path
# where the guest is least likely to be ready.
#
# sshState: 0 not ready, 2 ready, 4 ready and the deploy key is in. The test is >= 2, because
# a VM can go straight to 4 - which is what every run that worked reported - and the PORT is
# what actually has to be usable, so that is checked too rather than inferred from the state.
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
    # Returned rather than thrown: the caller prints what it is and says what to do, which is
    # more use than an exception naming a REST URL.
    return $last
}

$ssh = Wait-SshReady
if (-not $ssh -or [int]$ssh.port -le 0) {
    Note "ssh: not reachable yet (port=$($ssh.port) sshState=$($ssh.sshState))"
    Fail "'$Vm' is online, but its ssh port is still 0 after waiting."
    Fail '  The guest reports ssh separately from the VM state, so this is the guest still'
    Fail '  coming up rather than anything you did wrong - and nothing below can run without'
    Fail '  it. The VM EXISTS and is fine: just re-run this command, which will pick it up'
    Fail '  where it is (phase 0 does nothing for a VM that is already there).'
    Fail "  If it never becomes ready, the daemon's log is $asbDir\headless.log."
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
    # ssh refuses a private key other users can read, so lock it to this account.
    icacls $k /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    Note "generated $(Split-Path $k -Leaf)"
}
Phase 'ssh keys' 'ok'

# Can we get in at all?
$probe = Invoke-GuestPs '$env:COMPUTERNAME'

# Not yet - but a VM created with sshDeployKey already trusts AppSandbox's OWN key, and
# that key is on this host. Use it once to install ours, and the paste-this-block path
# below is left for guests that somebody else made without a deploy key.
if ($LASTEXITCODE -ne 0 -or -not $probe) {
    $asbKey = Join-Path $asbDir 'ssh\id_appsandbox'
    if ((Test-Path $asbKey) -and -not $VerifyOnly) {
        Note 'the admin key is not accepted yet; trying the AppSandbox deploy key'
        # DELEGATED, and it used to be an inline here-string doing the append and the icacls
        # itself. vm.ps1 -Mode keys has to do exactly this on every VM start - the daemon
        # rewrites administrators_authorized_keys and keeps only its own line, measured
        # - so a copy here would be a second implementation of the one thing that
        # must not be subtly different in two places. It installs the tunnel key too, which
        # is wiped by the same rewrite and which phase 3 below then finds already in place.
        & (Join-Path $PSScriptRoot 'vm.ps1') -Mode keys -Vm $Vm -AdminKey $AdminKey `
            -TunnelKey $TunnelKey | ForEach-Object { Note $_ }
        $probe = Invoke-GuestPs '$env:COMPUTERNAME'
    }
}

# Still not? Then a human has to put the first key in, once.
if ($LASTEXITCODE -ne 0 -or -not $probe) {
    Fail 'The admin key does not work against this guest yet, so nothing else can run.'
    if (-not (Test-Path "$AdminKey.pub")) {
        Fail "There is no key at $AdminKey either."
        Fail '  A normal run generates one; -VerifyOnly does not, which is why you are'
        Fail '  seeing this. Re-run without -VerifyOnly, or point -AdminKey at the key'
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
    Write-Host '  Or delete this VM and let -IsoPath make one: a VM created with sshDeployKey' -ForegroundColor Yellow
    Write-Host '  gets a working key from the guest agent, and nothing ever needs pasting.' -ForegroundColor Yellow
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
    if ($rc -ne 0 -and -not $VerifyOnly) { Fail 'the guest base is incomplete; stopping here'; exit 4 }
    if ($HardenSshd -and -not $VerifyOnly) {
        Note 'sshd restart was scheduled in the guest; waiting for it to come back...'
        Start-Sleep 30
        $probe = Invoke-GuestPs '$env:COMPUTERNAME'
        if (-not $probe) { Fail 'the guest did not answer after the sshd restart'; exit 4 }
        Note 'key still works after the restart'
    }
}

# ==================================================== 2b. make Windows believe it is online
# AFTER the guest base, because it needs the loopback adapter that phase installs, and
# BEFORE anything that signs in. Without it the Windows identity stack refuses to issue a
# single request - Visual Studio 2022's sign-in dies with 0x800713AB in a WINDOWS dialog
# rather than its own, and no allowlist entry can help because no request is ever made.
# Six stacked faults, all measured; the script documents each one. It grants no
# egress: a direct connection still returns nothing and the proxy still polices every byte.
if ($SkipOnline) { Phase 'windows online' 'skipped' } else {
    Say 'windows online (NCSI, routing, AppContainer loopback, IPv6)'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-windows-online.ps1'))
    $rc = Invoke-GuestScript 'install-windows-online.ps1' $(if ($VerifyOnly) { @('-VerifyOnly') } else { @() })
    # NOT fatal. Everything that does not sign in through Windows works without it, so a
    # failure here costs the Microsoft-account flows and nothing else - stopping the whole
    # provisioning run over it would be out of proportion.
    # 4 IS NOT A FAILURE OF THE RUN. Everything was applied and only the pair Windows
    # reports is missing, which costs the identity broker and nothing else - so the base is
    # still worth finishing, and the summary says what is true rather than 'ok' or 'FAILED'.
    Phase 'windows online' $(if ($rc -eq 0) { 'ok' }
                             elseif ($rc -eq 4) { 'applied, but not online-looking yet' }
                             else { "FAILED ($rc)" })
    if ($rc -eq 4) {
        Warn 'Windows does not report itself online yet, so sign-in to Epic or Microsoft will'
        Warn '  refuse. Everything else works. NLA re-evaluates on its own clock - re-running'
        Warn '  this phase, or rebooting the guest, is usually all it needs.'
    } elseif ($rc -ne 0) {
        Warn 'Windows will report itself offline; Microsoft-account sign-in will fail'
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
# IT IS VERIFIED HERE, NOT STARTED HERE, which is a change from the script this was adopted
# from. That one ran `dr-up` against a hard-coded gateway directory; Draugr already has the
# answer to "that mound has to be up" - DRAUGR_REQUIRES and dr-dep, which is how dr-forge up
# does it, inheriting trust, the claim, the cycle guard and the warden that stops sbx
# auto-stopping an idle mound. bin/dr-layer does that before this script is called, so by the
# time we are here the only useful question is whether it worked.
#
# And it must not be started from HERE in any case: this script runs elevated, and whoever
# starts sandboxd decides who may use it. The precondition above says what that costs.
if ($SkipGateway) { Phase 'gateway' 'skipped' } else {
    Say 'the gateway mound'
    $moundUp = [bool](Get-NetTCPConnection -LocalPort 18888 -State Listen -EA SilentlyContinue)
    if ($moundUp) {
        Note 'mound   127.0.0.1:18888 answers, so the proxy is reachable from the host'
        Phase 'gateway' 'ok'
    } else {
        Warn 'mound   127.0.0.1:18888 is silent: the gateway is not up.'
        Warn '  dr-layer provision brings it up through DRAUGR_REQUIRES before calling this,'
        Warn '  so if it is down either nothing requires it or its dr-up failed. From the'
        Warn '  project that names this forge:  dr-forge up   (or dr-up in the gateway).'
        Phase 'gateway' 'DOWN'
    }
}

# ============================================================== 5. the tunnel supervisor
if ($SkipTunnel) { Phase 'tunnel' 'skipped' } else {
    Say 'the tunnel supervisor'
    if (-not $VerifyOnly) {
        # DRAUGR'S SUPERVISOR, and not the gateway's install-tunnel-autostart.ps1 - which
        # was both a different file and a LOGON TASK, and keeping host changes to a minimum
        # ruled that out. vm.ps1 -Mode tunnel starts lib/forge/tunnel.ps1, judges the forward
        # by effect first so a healthy tunnel is left alone, and refuses to replace a forward
        # held for another VM. The same correction dr-forge already carries.
        & (Join-Path $PSScriptRoot 'vm.ps1') -Mode tunnel -Vm $Vm -AdminKey $AdminKey |
            ForEach-Object { Note $_ }
    }
    # WAIT for the forwards instead of sampling once. The supervisor has to notice the VM,
    # dial sshd and finish the handshake before -L binds anything, and a flat 5 seconds
    # reported 'down' for a tunnel that came up a moment later. The ceiling stays short: if
    # it is not up in 30 s it is broken, not slow.
    foreach ($i in 1..30) {
        if (Get-NetTCPConnection -LocalPort 18765 -State Listen -EA SilentlyContinue) { break }
        Start-Sleep 1
    }
    # Who binds what, because conflating them sends you to the wrong place to look:
    #   18888, 18445  published by the MOUND (docker). Down = the gateway is not running.
    #   18765, 18000  bound by the tunnel supervisor's -L. Down = the supervisor is not.
    # The supervisor's -R forwards live in the GUEST and cannot be seen from here at all;
    # the egress phase below is what actually proves those.
    $ports = @{}
    foreach ($p in 18888, 18445, 18765, 18000) {
        $ports[$p] = [bool](Get-NetTCPConnection -LocalPort $p -State Listen -EA SilentlyContinue)
    }
    Note ("mound ports:   18888=$(if ($ports[18888]) {'up'} else {'down'}) 18445=$(if ($ports[18445]) {'up'} else {'down'})")
    Note ("tunnel ports:  18765=$(if ($ports[18765]) {'up'} else {'down'}) 18000=$(if ($ports[18000]) {'up'} else {'down'})")
    if (-not ($ports[18888])) {
        Warn 'the gateway mound is not up - run dr-up (phase 4), or drop -SkipGateway'
    }
    if (-not ($ports[18765])) {
        Warn 'the tunnel is not up, and its log is the only diagnosis there is:'
        Warn "  $env:LOCALAPPDATA\Draugr\forge-tunnel.log"
        Warn '  Read the last "supervisor started" line first, and check WHICH VM it names.'
        Warn '  A supervisor left over from another VM is the usual cause: -Vm is fixed at'
        Warn '  launch, so it logs "waiting for the VM" forever while holding the host'
        Warn '  forwards this one needs.'
    }
    Phase 'tunnel' $(if ($ports[18765]) { 'ok' } else { 'FAILED' })
}

# ============================================================== 6. egress, or stop
# Everything below downloads something. Proving egress here, from inside the guest, turns
# a cascade of confusing failures into one clear message - and it is the same request the
# mound's post-up hook makes, from the other end.
Say 'egress from the guest'
Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\preflight.ps1'))
$rc = Invoke-GuestScript 'preflight.ps1'
# 3 is "the probe is broken", which is NOT "no egress" - it means this project cannot
# currently tell, and saying the gateway is down would send someone to fix the wrong thing.
# It still stops the run: nothing below should download an hour of installers on a guess.
Phase 'egress' $(if ($rc -eq 0) { 'ok' } elseif ($rc -eq 3) { 'UNPROVED' } else { 'FAILED' })
if ($rc -eq 3) {
    Fail 'Egress could not be PROVED - which is not the same as the guest having no way out.'
    Fail '  preflight.ps1 said why. It is a defect in this project, not in your gateway.'
    exit 5
}
if ($rc -ne 0) {
    Fail 'The guest has no way out, so nothing below can install. Fix that first:'
    Fail '  the mound (phase 4) and the tunnel (phase 5) both have to be up.'
    exit 5
}

# ============================================================== 7. MSYS2
# FIRST of the components, because the package set after it is installed BY it - pacman is
# what phase 8 runs. The automation phase does NOT depend on it: uv brings its own Python
# and AutoHotkey arrives as a zip.
#
# Its own header has the pinning: the installer is fixed by date and hash, and every
# mirrorlist loses every server but repo.msys2.org before the first sync, so pacman can only
# ever dial the one host the kit allows.
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
# Right after the automation, because it answers the same question from the other side.
# The MCP server lets an agent DRIVE the desktop; this lets any agent with nothing but a
# shell SEE it - including when the MCP server is the thing that is broken, which is
# exactly when looking matters most.
#
# Both exist because session 0 cannot photograph session 1. install-shot.ps1 bridges that
# with an on-demand scheduled task; its header has the full reasoning.
if ($SkipShot) { Phase 'shot' 'skipped' } else {
    Say 'the desktop camera'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-shot.ps1'))
    $rc = Invoke-GuestScript 'install-shot.ps1' $(if ($VerifyOnly) { @('-VerifyOnly') } else { @() })
    Phase 'shot' $(if ($rc -eq 0) { $(if ($VerifyOnly) { 'reported' } else { 'ok' }) } else { "FAILED ($rc)" })
}

# ============================================================== 10. the screen
# The MSI is fetched by lib/forge/screen-access.ps1 from the vendor, against a pinned
# SHA-256, on the HOST - so no allowlist entry is involved: the host has ordinary internet
# and the file is pushed into the guest over ssh. -VncMsi still overrides the pin, which is
# how you would install UltraVNC instead (its own download cannot be scripted; see that
# script's header).
#
# THE HOST'S VIEWER HALF IS LEFT OUT unless -InstallViewer: it elevates, and this run must
# not stop for a UAC prompt. See the parameter.
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
        # -PassFile, explicitly: the credentials block above may have just written the
        # answer there, and relying on two scripts sharing a default is how they drift.
        # -SshPort and -GuestUser likewise - both were resolved from the daemon before
        # phase 0, so the screen installer acts on this run's answer instead of asking
        # again. GuestUser, not User: see that script's own note on the name.
        $a = @{ Vm = $Vm; AdminKey = $AdminKey; PassFile = $VncPassFile
                SshPort = $script:sshPort; GuestUser = $script:guestUser }
        if (-not $InstallViewer) { $a.SkipHostViewer = $true }
        if ($VncMsi) {
            if (-not (Test-Path $VncMsi)) { throw "-VncMsi does not exist: $VncMsi" }
            $a.Msi = $VncMsi
        }
        & (Join-Path $PSScriptRoot 'screen-access.ps1') @a | ForEach-Object { Note $_ }
        # Re-probe rather than read $LASTEXITCODE: PowerShell scripts do not set it, so it
        # would still hold whatever the last NATIVE command left behind.
        $after = Invoke-GuestPs '(Get-Service tvnserver -EA SilentlyContinue).Status'
        Phase 'screen' $(if ($after -match 'Running') { 'ok' } else { 'FAILED' })
        if (-not $InstallViewer) {
            Note 'the host has no viewer from this run. dr-forge screen finds one if you have'
            Note '  it, or says what to point at 127.0.0.1:15900 if you do not.'
        }
    }
}

# ============================================================== 11. the vault (optional)
# Optional by nature: it exists to carry an asset library in from the host, and a guest
# with no library to carry needs none of it.
#
# AND IT ASKS WHETHER THERE IS A VAULT FIRST, which the script this was adopted from did not
# have to: its gateway always served one. Draugr's `dr-forge gateway` generates a mound with
# NO share when no --vault was given, and the post-up hook skips the share step. This phase
# REBOOTS the guest - the guest's own LanmanServer holds port 445 until a restart - so doing
# it for a share nobody serves spends a reboot on nothing.
#
# TWO CONDITIONS, because post-up skips the share in two cases and they look different from
# here:
#   * no vault directory  -> the generated config does not publish 18445 at all, so the
#     host has no listener. (It is gated in the generator for exactly this reason: a
#     published port is bound by the PUBLISHER, so an unconditional one would answer for a
#     service nobody is running and this check would believe it.)
#   * no share password   -> 18445 is published and answers, and there is no Samba behind
#     it. The password file is on THIS side, so it is simply read.
#
# Asked here rather than read from phase 5's port table, which -SkipTunnel leaves unset.
if ($SkipVault) { Phase 'vault' 'skipped' } else {
    Say 'the vault (optional)'
    $drives = Invoke-GuestPs '(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name + "=" + $_.DisplayRoot }) -join ";"'
    # The match is made here rather than in the guest snippet: a -like pattern for a UNC
    # path is all backslashes, and backslashes are what gets eaten on the way over.
    $mounted = ($drives | Where-Object { $_ -match '127\.0\.0\.1' }) -join ' '
    $smbUp = [bool](Get-NetTCPConnection -LocalPort 18445 -State Listen -EA SilentlyContinue)
    $smbPass = "$env:USERPROFILE\.ssh\draugr_vault_smb.pass"
    if ($mounted) { Note "mounted: $mounted"; Phase 'vault' 'ok' }
    elseif ($VerifyOnly) { Note 'not mounted (mount-vault.ps1 runs once per session)'; Phase 'vault' 'not mounted' }
    elseif (-not $smbUp) {
        Note 'the gateway serves no vault: nothing is listening on 127.0.0.1:18445.'
        Note '  Nothing installed, and the guest was NOT rebooted. To serve one, regenerate'
        Note '  the gateway with a vault directory:  dr-forge gateway <dir> --vault <path>'
        Phase 'vault' 'no vault served'
    }
    elseif (-not (Test-Path $smbPass)) {
        # DRAUGR NEVER WRITES THIS FILE, and that is deliberate: it is the one record of a
        # password the guest also stores, and a rebuild that rewrote it would invalidate
        # what the guest has. The hook sets whatever is in it on the share at every
        # recreate; without it the hook serves no share at all and says so in its own log.
        Note "no share password on this host: $smbPass"
        Note '  18445 is published, but the gateway served no share without it - so there is'
        Note '  nothing to mount, and the guest was NOT rebooted. Make one, then dr-up the'
        Note '  gateway again so its post-up hook sets it on the share:'
        Note '    $b = New-Object byte[] 18'
        Note '    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)'
        Note ("    [IO.File]::WriteAllText('{0}', ([Convert]::ToBase64String($b) -replace '[/+=]',''))" -f $smbPass)
        Phase 'vault' 'no share password'
    }
    else {
        Note 'installing the vault key and mount script into the guest...'
        # -User IS MANDATORY THERE, and omitting it did not fail - it stopped and asked.
        # Measured: an unattended run sat at PowerShell's own "Supply values for
        # the following parameters: User:" prompt, in the middle of a phase, where the only
        # thing that could answer was whatever happened to be on stdin. A mandatory parameter
        # left unbound is a hang, not an error.
        & (Join-Path $PSScriptRoot 'vault-access.ps1') `
            -Vm $Vm -User $script:guestUser -AdminKey $AdminKey -SshPort $script:sshPort |
            ForEach-Object { Note $_ }
        # It reboots the guest, and every phase below here needs ssh.
        [void](Wait-GuestBack)
        Note 'run mount-vault.ps1 in the guest once per session to mount it'
        Phase 'vault' 'installed'
    }
}

# ============================================================== 11b. Visual Studio Code
# AFTER the vault, and that ordering is the whole point: the installer is 233 MB, the guest's
# only way out is the proxy over the ssh tunnel, and phase 11 is what puts the share
# credential in the guest. Run this before the vault and every build downloads it again.
#
# The script falls back to downloading if the vault has no copy, so a guest built without
# -SkipVault still ends up with VS Code either way - it just costs more.
#
# NOT an Unreal thing, which is why it is here rather than in a layer: it is the editor any
# Windows VM would want. The "Unreal Angelscript" extension is the opposite - per-project,
# one line in the VM that needs it - and install-vscode.ps1 says so rather than installing it.
if ($SkipVsCode) { Phase 'vscode' 'skipped' } else {
    Say 'Visual Studio Code'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-vscode.ps1'))
    $rc = Invoke-GuestScript 'install-vscode.ps1' $(if ($VerifyOnly) { @('-VerifyOnly') } else { @() })
    Phase 'vscode' $(if ($rc -eq 0) { $(if ($VerifyOnly) { 'reported' } else { 'ok' }) } else { "FAILED ($rc)" })
}

# ============================================================== 11c. .NET Framework 3.5
# LAST of the components, and the only one that is off unless asked for - see -NetFxSource for
# why the payload is a human's job. It belongs in the base rather than an engine layer:
# installing UE 4.27 raised Windows' own prompt for it (measured), and every engine
# version above this disk would hit that separately.
#
# NOT AFTER THE VAULT FOR THE VAULT'S SAKE, unlike VS Code: the cab comes from the host, so
# this phase does not care whether phase 11 ran. It is here because it is the last thing that
# installs anything, and because a reader looking for "what else went in" reads downwards.
#
# A FAILURE HERE IS REPORTED, NOT FATAL. An otherwise finished base should not be thrown away
# over a 68 MB cab that can be enabled later with one command in the guest.
if (-not $NetFxSource) {
    # Said rather than silently absent: a base with no NetFx3 is the normal case, and the
    # summary is where someone finds out why Windows asked them for it later.
    Phase 'netfx3' 'not requested'
} else {
    Say '.NET Framework 3.5'
    $sxs = 'C:/Windows/Temp/draugr-sxs'
    Invoke-GuestPs "New-Item -ItemType Directory -Force -Path '$($sxs -replace '/','\')' | Out-Null" | Out-Null
    # The cab, then the script. Pushed in the same way the screen installer pushes its MSI:
    # the host has ordinary internet and a file a person put there, and the guest has neither.
    Copy-ToGuest @($netFxCab.FullName) "$sxs/"
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\install-netfx3.ps1'))
    $a = @("-Source $($sxs -replace '/','\')")
    if ($VerifyOnly) { $a += '-VerifyOnly' }
    $rc = Invoke-GuestScript 'install-netfx3.ps1' $a
    # Exit 2 is the script's "no payload where I was told to look", which after the
    # precondition above can only mean the copy did not arrive - worth distinguishing from a
    # DISM failure, because the two are fixed in different places.
    Phase 'netfx3' $(if ($rc -eq 0) { $(if ($VerifyOnly) { 'reported' } else { 'ok' }) }
                     elseif ($rc -eq 2) { 'the cab did not arrive in the guest' }
                     else { "FAILED ($rc)" })
    Invoke-GuestPs "Remove-Item '$($sxs -replace '/','\')' -Recurse -Force -EA SilentlyContinue" | Out-Null
}

# ============================================================== 12. cleanup
# Before the manifest, so the manifest describes the cleaned guest rather than the
# scaffolding. Skipped entirely under -VerifyOnly, where -WhatIfOnly reports instead.
if ($SkipCleanup) { Phase 'cleanup' 'skipped' } else {
    Say 'cleanup'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\cleanup.ps1'))
    $rc = Invoke-GuestScript 'cleanup.ps1' $(if ($VerifyOnly) { @('-WhatIfOnly') } else { @() })
    Phase 'cleanup' $(if ($rc -eq 0) { $(if ($VerifyOnly) { 'reported' } else { 'ok' }) } else { "FAILED ($rc)" })
}

# ============================================================== 13. the manifest
# Last, and it runs even under -VerifyOnly: reading the machine changes nothing, and a
# refreshed manifest is the most useful thing a verify run can leave behind.
if ($SkipManifest) { Phase 'manifest' 'skipped' } else {
    Say 'the manifest'
    Copy-ToGuest @((Join-Path $PSScriptRoot 'guest\write-manifest.ps1'))
    # -McpPort passed rather than left to the default the two files share: the manifest
    # reports whether that port has a listener, and a manifest checking a different port
    # from the one the automation phase installed would report a healthy guest as broken.
    $rc = Invoke-GuestScript 'write-manifest.ps1' @("-McpPort $McpPort", '-Print')
    Phase 'manifest' $(if ($rc -eq 0) { 'ok' } else { "FAILED ($rc)" })
}

# ============================================================== what is left to a human
Say 'summary'
# GetEnumerator(), not .Keys: on a dictionary, member access resolves an ENTRY of that name
# before the .NET property, so a phase called "keys" made $done.Keys return that phase's
# value and the whole table collapsed to one row. Measured, and it looked like a formatting
# bug rather than a name collision.
$rows = @($script:done.GetEnumerator())
$w = ($rows | ForEach-Object { $_.Key.Length } | Measure-Object -Maximum).Maximum
foreach ($r in $rows) {
    $c = if ($r.Value -eq 'ok') { 'Green' } elseif ($r.Value -match 'FAIL|missing') { 'Red' } else { 'Yellow' }
    Write-Host ("  {0,-$w}  {1}" -f $r.Key, $r.Value) -ForegroundColor $c
}

Write-Host ''
$secrets = @()
if (Test-Path $AdminPassFile) { $secrets += "  Windows password  $AdminPassFile" }
# Named even when this run did not write it: draugr_vnc.pass is often the only record of a
# guest's VNC password - the guest keeps its copy in the registry, not in a file - and
# nothing in Draugr ever deletes or rewrites it.
if (Test-Path $VncPassFile)   { $secrets += "  VNC password      $VncPassFile" }
if ($secrets) {
    Write-Host 'Passwords - yours, not the agent''s; it uses the ssh key and needs neither:' -ForegroundColor Cyan
    $secrets | ForEach-Object { Write-Host $_ }
    Write-Host ''
}
# THE STRAY SECOND DESKTOP IS A HUMAN STEP, ON PURPOSE - and that is a decision, not a gap.
# It appears on SOME boots, so it cannot be fixed once; the remedy needs an interactive
# session, which this script's ssh (session 0) cannot reach; and the on-demand
# scheduled-task trick that reaches session 1 on older guests does not fire on the layer
# VMs at all (measured). Automating it means a logon-triggered task doing
# QueryDisplayConfig/SetDisplayConfig with an explicit path array - perfectly possible, but
# untestable on demand because the fault only appears on some boots. Until that is built,
# telling the person what to click costs twenty seconds and never misleads them.
#
# Said only when there is a screen to see it on, which is this stage's doing: before 2b
# nothing installed a VNC server, so advice about what the desktop looks like had nowhere
# to land. Background and the measurements: docs/FORGE.md, the stray-second-desktop bullet.
if (-not $SkipScreen) {
    Write-Host 'If the screen shows two desktops side by side (a stray taskbar to the right of' -ForegroundColor Cyan
    Write-Host 'the real one), fix it ONCE in the guest and every layer above inherits it:' -ForegroundColor Cyan
    Write-Host '  1. In the guest, open Settings -> System -> Display  (or run:  ms-settings:display )'
    Write-Host '  2. Click Identify. Each screen shows a big number, so you can tell which is which.'
    Write-Host '  3. In the dropdown beside the display diagram, choose "Show only on N", where N is'
    Write-Host '     the number that appeared on the LARGER screen - the 1920x1080 one, not the'
    Write-Host '     1024x768 stray. The numbering is not fixed, so read it rather than assume it.'
    Write-Host '  Do NOT use Win+P: the projection presets it applies are inert on a machine with no'
    Write-Host '  internal panel (measured). It must be the Settings dropdown.'
    Write-Host '  It is saved per monitor-set under HKLM\SYSTEM\...\GraphicsDrivers\Configuration, so'
    Write-Host '  it survives restarts and is carried into any layer frozen afterwards.'
    Write-Host ''
}
Write-Host 'Still yours, and deliberately so:' -ForegroundColor Cyan
if (-not $NetFxSource) {
    Write-Host '  - .NET Framework 3.5, which is OFF because its payload is a file only you can'
    Write-Host '    produce: \sources\sxs\*netfx3*.cab from the ISO this guest was installed'
    Write-Host '    from. Unreal asks Windows for it, Windows asks you, and this guest can reach'
    Write-Host '    no Windows Update - so pass --netfx <path> to that cab and re-run.'
}
Write-Host '  - the host''s VNC viewer, unless you passed -InstallViewer: installing it'
Write-Host '    elevates, and this run does not raise prompts half way through.'
Write-Host '  - turning this disk into a frozen layer-0, which is dr-layer adopt (and its'
Write-Host '    header has the order, because the order is the whole difficulty).'
Write-Host '  - the Epic account, the engine versions and Visual Studio are LAYERS, not the base:'
Write-Host '    they are account- and vintage-bound, so they go in a disk above this one.'
if (-not $HardenSshd) {
    Write-Host '  - -HardenSshd turns off password authentication in the guest, if you want that.'
}
$failed = @($rows | Where-Object { $_.Value -match 'FAIL' })
if ($failed.Count) { exit 1 }
