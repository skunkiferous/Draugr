#!/usr/bin/env bats
# dr-forge: the opt-in gate, the liveness chain, and the three verbs that reach into the guest.
#
# EVERYTHING HERE RUNS OFF WINDOWS. dr-forge reaches the Windows side only through
# powershell.exe - the measured constraint the whole bridge is built on - so tests/mocks/
# powershell.exe is enough to drive all of it, including the base64 that crosses five parsers.
#
# WSL_DISTRO_NAME is set in setup so dr_forge_win_path has an answer on a machine with no
# Windows drive. That is not a test backdoor: it is the \\wsl.localhost spelling dr_path_win_kit
# exists to produce for a checkout on WSL's own ext4, and the mock accepts any spelling of the
# script path. Path translation itself is unit-tested against literal strings in paths.bats.

load helper

setup() {
    dr_test_setup
    export WSL_DISTRO_NAME=Test
    export DRAUGR_FORGE=mock-vm
    # An ssh_config alias for the forge, which doctor's links 9 and 10 need: without one there
    # is no route from WSL to the VM at all, so a healthy chain has to include it. Tests about
    # its absence unset this.
    export DR_MOCK_SSH_ALIAS=host.docker.internal:18022
    # Out of any git repository, so no project config is in scope unless a test makes one.
    cd "$DR_TMP" || return 1
}

teardown() { dr_test_teardown; }

# A probe answer with one or two facts changed. Writing the whole set each time is how a test
# comes to assert on facts it does not care about.
#
# AN OVERRIDDEN KEY IS REMOVED FROM THE TEMPLATE, not just followed by a new value. dr-forge
# reads these into an associative array, where the last value wins - but dr_forge_far_end_running
# matches a WHOLE LINE, so a file saying both vm_running=yes and vm_running=no answers "yes" to
# it. That cost a false pass here: a test asserting the VM was absent watched it report present.
probe_with() {
    DR_MOCK_PROBE="$DR_TMP/probe.txt"
    export DR_MOCK_PROBE
    local base="$DR_TMP/probe.base" o k
    cat > "$base" <<EOF
vm=mock-vm
daemon=up
daemon_version=AppSandbox 0.1.8
vm_state=online
vm_running=yes
vm_agent=yes
ssh_port=57350
ssh_user=forge
ssh_listening=yes
port_18888=up
port_18445=up
port_18765=up
port_18000=up
tunnel_task=Running
EOF
    cp "$base" "$base.keep"
    for o in "$@"; do
        k=${o%%=*}
        grep -v "^$k=" "$base.keep" > "$base.next" || true
        mv "$base.next" "$base.keep"
    done
    { cat "$base.keep"; printf '%s\n' "$@"; } > "$DR_MOCK_PROBE"
}

# --- the opt-in gate --------------------------------------------------------

@test "dr-forge: with no forge configured it refuses, and exits 1" {
    run env -u DRAUGR_FORGE dr-forge
    [ "$status" -eq 1 ]
    [[ "$output" == *"no forge is configured"* ]]
    [[ "$output" == *DRAUGR_FORGE* ]]
}

# The fault this one guards against cost an evening: the key WAS set, in .draugr.conf, and
# dr-forge reported it unset - so the reader checks their own spelling instead of the trust.
@test "dr-forge: an untrusted project config is named, not reported as an empty key" {
    local repo
    repo=$(dr_make_repo forgerepo)
    printf 'DRAUGR_FORGE=from-the-conf\n' > "$repo/.draugr.conf"
    cd "$repo"
    run env -u DRAUGR_FORGE dr-forge
    [ "$status" -eq 1 ]
    [[ "$output" == *untrusted* ]]
    [[ "$output" == *.draugr.conf* ]]
    [[ "$output" == *dr-trust* ]]
}

# --- status and doctor ------------------------------------------------------

@test "dr-forge status: reports the chain the probe described" {
    run dr-forge status
    [ "$status" -eq 0 ]
    [[ "$output" == *"forge mock-vm"* ]]
    [[ "$output" == *"AppSandbox 0.1.8"* ]]
    [[ "$output" == *"18765=up"* ]]
}

@test "dr-forge doctor: every host-side link healthy exits 0" {
    run dr-forge doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"every host-side link is healthy"* ]]
}

# REGRESSION. doctor called a working forge broken because the scheduled task was
# registered for a layer that no longer existed, while the live supervisor served this VM and
# the guest's egress worked. The task's pin is a registration; only the process holding the
# forwards decides whether traffic flows.
@test "dr-forge doctor: a stale logon task is an advisory, not a failure" {
    probe_with 'tunnel_vm=layer-2-ue426' 'fwd_vm=mock-vm' 'tunnel_mutex=visible'
    run dr-forge doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"logon task is registered for 'layer-2-ue426'"* ]]
    [[ "$output" != *"no way out"* ]]
}

@test "dr-forge doctor: a supervisor holding the forwards for ANOTHER vm is a failure" {
    probe_with 'tunnel_vm=mock-vm' 'fwd_vm=other-vm'
    run dr-forge doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"serving other-vm"* ]]
    [[ "$output" == *"need attention"* ]]
}

# REGRESSION. A supervisor started by the logon task runs in session 0, where its
# command line reads back empty, so the pin is unknown rather than wrong. Failing link 7 on that
# reported a working forge as broken while links 8, 9 and 10 were passing in the same run.
# probe.ps1 falls back to the claim file; when even that is missing, unknown must still pass
# here, and the effect checks remain the backstop.
@test "dr-forge doctor: an unreadable supervisor pin does not fail link 7" {
    probe_with 'fwd_vm=unreadable' 'tunnel_vm=mock-vm'
    run dr-forge doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"serving unreadable"* ]]
}

@test "dr-forge status: nothing holding the forwards IS no way out" {
    probe_with 'port_18765=down' 'port_18000=down'
    run dr-forge status
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing is holding the tunnel forwards"* ]]
    [[ "$output" == *"no way out"* ]]
}

@test "dr-forge status: a second supervisor in another session is reported" {
    probe_with 'fwd_vm=mock-vm' 'tunnel_vm=mock-vm' 'tunnel_mutex=other-session'
    run dr-forge status
    [ "$status" -eq 0 ]
    [[ "$output" == *"second supervisor"* ]]
}

# The git and data loops address the VM through an ssh_config alias, because nothing in WSL can
# dial it directly. No alias means dr-sync fails at "could not resolve hostname", three links
# from the cause - so it is a counted link, not an advisory.
@test "dr-forge doctor: a missing ssh alias is a failing link" {
    unset DR_MOCK_SSH_ALIAS
    run dr-forge doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing resolves mock-vm.forge"* ]]
}

# "Define an ssh alias" is not actionable, and this used to answer it by printing the whole
# Host block for the reader to paste. One `Host *.forge` block now serves every VM, so the
# answer is a command Draugr owns - and a pasted block was never maintained by anything.
@test "dr-forge doctor: a missing alias is answered with a command, not a block" {
    unset DR_MOCK_SSH_ALIAS
    run dr-forge doctor
    [[ "$output" == *"dr-setup --forge"* ]]
    # Nothing to copy by hand: the lines that made up the old block must be gone.
    [[ "$output" != *"HostName host.docker.internal"* ]]
    [[ "$output" != *"IdentitiesOnly"* ]]
    [[ "$output" != *"socat"* ]]
}

@test "dr-forge doctor: with the alias defined, link 9 passes" {
    run dr-forge doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"host.docker.internal:18022 via the mound"* ]]
    [[ "$output" != *"Host mock-vm"* ]]
}

@test "dr-forge doctor --deep: the alias is checked by using it" {
    run dr-forge doctor --deep
    [ "$status" -eq 0 ]
    [[ "$output" == *"10 WSL reaches the VM"* ]]
    [[ "$output" == *"a command ran over the alias"* ]]
}

# MEASURED, and the old advice sent the reader at the two links that were already
# passing. The forward was bound and answering while the guest refused every channel over it,
# because sshd binds the tunnel key's permitopen when the supervisor authenticates and the list
# had been widened afterwards. No port check can see that; only the supervisor's log can.
@test "dr-forge doctor --deep: a bound-but-dead chain points at the supervisor log" {
    export DR_MOCK_SSH_CHAIN=no
    run dr-forge doctor --deep
    [ "$status" -ne 0 ]
    [[ "$output" == *"10 WSL reaches the VM"* ]]
    [[ "$output" == *"administratively prohibited"* ]]
    [[ "$output" == *"forge-tunnel.log"* ]]
    [[ "$output" != *"check links 6 and 7"* ]]
}

# 18022 IS PINNED, so every VM's alias resolves to it and what answers is whichever VM the
# SUPERVISOR serves. MEASURED: a doctor run for a stopped 'ue-427-test' reported
# "ok 10 WSL reaches the VM", having run its command in 'test'. Link 10 is the only effect
# check on this direction, so a pass there was certifying the wrong guest.
@test "dr-forge doctor --deep: link 10 cannot pass for a VM that is not running" {
    probe_with 'vm_running=no' 'vm_state=stopped'
    run dr-forge doctor --deep
    [[ "$output" == *"10 WSL reaches the VM"* ]]
    [[ "$output" == *"is not running, so whatever answers on 18022 is another VM"* ]]
    # Not reported as reached, by any wording.
    [[ "$output" != *"ok   10"* ]]
}

@test "dr-forge doctor --deep: link 10 cannot pass when the forward serves another VM" {
    probe_with 'fwd_vm=some-other-vm'
    run dr-forge doctor --deep
    [[ "$output" == *"the 18022 forward serves 'some-other-vm'"* ]]
    [[ "$output" != *"ok   10"* ]]
}

# The dangerous half of the same fact: dr-sync and dr-data go through that alias, so they would
# write into the other guest. A silent wrong-guest write is not something to discover later.
@test "dr-forge doctor: a forward serving another VM warns that git and data point at it" {
    probe_with 'fwd_vm=some-other-vm'
    run dr-forge doctor --deep
    [[ "$output" == *"currently serves 'some-other-vm'"* ]]
    [[ "$output" == *"WRONG VM"* ]]
    [[ "$output" == *dr-data* ]]
}

# The other half: when a link above it has actually failed, the general advice is still the
# right one - the specific diagnosis only holds when the forward really is up.
@test "dr-forge doctor --deep: with the supervisor down, link 10 keeps the general advice" {
    export DR_MOCK_SSH_CHAIN=no
    probe_with 'port_18765=down'
    run dr-forge doctor --deep
    [ "$status" -ne 0 ]
    [[ "$output" == *"check links 6 and 7"* ]]
    [[ "$output" != *"administratively prohibited"* ]]
}

# Every VM on the layer stack inherits the base image's name, so the guest calls itself layer-0
# whatever vms.cfg says. Not a failure - nothing breaks - but it needs saying once there is
# more than one VM.
@test "dr-forge status --deep: a guest name that differs from the VM is reported" {
    probe_with 'guest_name=layer-0' 'fwd_vm=mock-vm' 'tunnel_vm=mock-vm' 'ssh_exec=yes' 'guest_egress=yes'
    run dr-forge status --deep
    [ "$status" -eq 0 ]
    [[ "$output" == *"layer-0"* ]]
    [[ "$output" == *"the VM is mock-vm"* ]]
}

# The advice has to be runnable with DRAUGR ALONE. It used to say to push a script out of the
# gateway project, which this repository does not ship - so following it meant having that
# checkout, in a particular layout, beside this one. exec plus a reboot needs neither.
@test "dr-forge doctor --deep: and says how to rename it, with Draugr commands only" {
    probe_with 'guest_name=layer-0' 'fwd_vm=mock-vm' 'tunnel_vm=mock-vm' 'ssh_exec=yes' 'guest_egress=yes'
    run dr-forge doctor --deep
    [[ "$output" == *"calls itself 'layer-0'"* ]]
    [[ "$output" == *"dr-forge exec Rename-Computer"* ]]
    [[ "$output" == *"dr-forge down"* ]]
    [[ "$output" != *set-computer-name.ps1* ]]
}

# Windows reports COMPUTERNAME in UPPER CASE - measured, a guest answering LAYER-0 -
# so a renamed guest says UE-427-TEST and a literal comparison would nag about a name that is
# already correct. Advice that cannot be followed is worse than no advice.
@test "dr-forge status --deep: a guest name matching apart from case is NOT a mismatch" {
    probe_with 'guest_name=MOCK-VM' 'fwd_vm=mock-vm' 'tunnel_vm=mock-vm' 'ssh_exec=yes' 'guest_egress=yes'
    run dr-forge status --deep
    [ "$status" -eq 0 ]
    [[ "$output" == *MOCK-VM* ]]
    [[ "$output" != *"the VM is mock-vm"* ]]
    [[ "$output" != *"calls itself"* ]]
}

# --- exec -------------------------------------------------------------------

@test "dr-forge exec: refuses with no command, and says how it is joined" {
    run dr-forge exec
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a command"* ]]
    [[ "$output" == *"ONE PowerShell command"* ]]
}

# The encoding is the whole mechanism: base64 is the one form none of the five parsers between
# here and the guest can damage. Decoded here rather than trusted.
@test "dr-forge exec: the command crosses as UTF-16LE base64" {
    run dr-forge exec Get-ChildItem 'C:\ForgeAssets'
    [ "$status" -eq 0 ]
    local b64 decoded
    b64=$(sed -n 's/.*-Encoded \([A-Za-z0-9+/=]*\).*/\1/p' "$DR_MOCK_LOG")
    [ -n "$b64" ]
    decoded=$(printf '%s' "$b64" | base64 -d | iconv -f UTF-16LE -t UTF-8)
    [[ "$decoded" == *"Get-ChildItem C:\\ForgeAssets"* ]]
}

# A command that fails must not come back as success. `powershell -EncodedCommand` exits 0 for
# a failing cmdlet, so the wrapper reads both signals the guest has.
@test "dr-forge exec: the wrapper carries the guest's exit code out" {
    run dr-forge exec Get-Date
    [ "$status" -eq 0 ]
    local decoded
    decoded=$(sed -n 's/.*-Encoded \([A-Za-z0-9+/=]*\).*/\1/p' "$DR_MOCK_LOG" |
              base64 -d | iconv -f UTF-16LE -t UTF-8)
    [[ "$decoded" == *'$global:LASTEXITCODE = 0'* ]]
    [[ "$decoded" == *'$ok = $?; $code = $LASTEXITCODE'* ]]
    [[ "$decoded" == *'if ($code) { exit $code }'* ]]
    [[ "$decoded" == *'if (-not $ok) { exit 1 }'* ]]
}

# REGRESSION of a whole class: a refusal that reports success is worse than no check at all.
@test "dr-forge exec: a non-zero guest code is passed out, not flattened to 0" {
    export DR_MOCK_GUEST_RC=7
    run dr-forge exec 'exit 7'
    [ "$status" -eq 7 ]
}

# One crossing of the WSL boundary, not two: guest.ps1 looks the VM and the port up itself.
@test "dr-forge exec: does not run the probe first" {
    run dr-forge exec Get-Date
    [ "$status" -eq 0 ]
    grep -qF -- 'guest.ps1' "$DR_MOCK_LOG"
    ! grep -qF -- 'probe.ps1' "$DR_MOCK_LOG"
}

# --- push and pull ----------------------------------------------------------

@test "dr-forge push: takes exactly two paths" {
    run dr-forge push only-one-path
    [ "$status" -eq 1 ]
    [[ "$output" == *"exactly two paths"* ]]
}

@test "dr-forge push: refuses a local path that is not there" {
    run dr-forge push "$DR_TMP/absent.txt" 'C:\Users\forge\dropped.txt'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nothing to push"* ]]
}

# The local side is respelled for a Windows process; the guest side is already a Windows path
# and must cross untouched. Getting that backwards is the kind of fault that shows up as an
# empty file somewhere unexpected.
@test "dr-forge push: the local path is translated and the guest path is not" {
    printf 'payload\n' > "$DR_TMP/push-me.txt"
    run dr-forge push "$DR_TMP/push-me.txt" 'C:\Users\forge\dropped.txt'
    [ "$status" -eq 0 ]
    grep -qF -- '-Mode push' "$DR_MOCK_LOG"
    grep -qF -- '-Remote C:\Users\forge\dropped.txt' "$DR_MOCK_LOG"
    grep -qF -- 'push-me.txt' "$DR_MOCK_LOG"
    # Translated, so it carries backslashes rather than the /tmp spelling it came in as.
    grep -qE -- '-Local [^ ]*\\push-me.txt' "$DR_MOCK_LOG"
}

# pull's local side is a DESTINATION that need not exist, and dr_path_win resolves real paths -
# so the parent is translated and the basename appended.
@test "dr-forge pull: a destination file that does not exist yet still translates" {
    run dr-forge pull 'C:\Users\forge\out.txt' "$DR_TMP/fetched.txt"
    [ "$status" -eq 0 ]
    grep -qF -- '-Mode pull' "$DR_MOCK_LOG"
    grep -qF -- '-Remote C:\Users\forge\out.txt' "$DR_MOCK_LOG"
    grep -qE -- '-Local [^ ]*\\fetched.txt' "$DR_MOCK_LOG"
}

# REGRESSION: a RELATIVE local path came out as \\wsl.localhost\Ubuntuguest\...,
# with the distro name and the path fused, because dr_path_win_kit relies on the leading "/" to
# separate them. The existence check passed anyway, so the only symptom was the mangled path.
@test "dr-forge push: a relative local path is made absolute before translation" {
    mkdir -p "$DR_TMP/sub"
    printf 'payload\n' > "$DR_TMP/sub/relative.txt"
    cd "$DR_TMP"
    run dr-forge push sub/relative.txt 'C:\Users\forge\dropped.txt'
    [ "$status" -eq 0 ]
    # The fused form would have the distro name immediately followed by "sub".
    ! grep -qE -- '-Local [^ ]*wsl.localhost.[^\\]*sub' "$DR_MOCK_LOG" || return 1
    grep -qE -- '-Local [^ ]*\\sub\\relative.txt' "$DR_MOCK_LOG"
}

@test "dr-forge pull: refuses when the destination directory is missing" {
    run dr-forge pull 'C:\Users\forge\out.txt' "$DR_TMP/nosuchdir/fetched.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a directory"* ]]
}

# --- up and down ------------------------------------------------------------

# The daemon is the one link up cannot fix: starting it needs elevation. So it must refuse and
# hand over the command - and the command has to be a WINDOWS one, not a script from the
# gateway project, which Draugr does not ship and must not send anyone to.
@test "dr-forge up: a daemon that is down is reported, not started" {
    probe_with 'daemon=down'
    run dr-forge up
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs elevation"* ]]
    [[ "$output" == *"AppSandbox.exe --headless"* ]]
}

# NOTHING DRAUGR TELLS YOU TO RUN MAY LIVE IN THE GATEWAY PROJECT. `up` owns everything after
# the daemon, so every script it needs ships here - and a message naming someone else's file
# is the symptom of that line having been crossed.
@test "dr-forge up: no message sends the reader to a gateway script" {
    probe_with 'daemon=down'
    run dr-forge up
    [[ "$output" != *forge-screen* ]]
    [[ "$output" != *forge-layer* ]]
    [[ "$output" != *install-tunnel-autostart* ]]
    [[ "$output" != *vm-tunnel.ps1* ]]
}

# The same rule over doctor, with BOTH advisories firing - the logon task pointing elsewhere
# and the guest's name disagreeing. Those two were where the gateway's filenames survived
# longest, because an advisory reads like prose rather than like an instruction.
@test "dr-forge doctor: no advisory sends the reader to a gateway script" {
    probe_with 'guest_name=layer-0' 'tunnel_vm=some-other-vm' 'fwd_vm=mock-vm' \
        'ssh_exec=yes' 'guest_egress=yes'
    run dr-forge doctor --deep
    # Both advisories have to be present, or this proves nothing about their wording.
    [[ "$output" == *"calls itself 'layer-0'"* ]]
    [[ "$output" == *"registered for 'some-other-vm'"* ]]
    [[ "$output" != *forge-screen* ]]
    [[ "$output" != *forge-layer* ]]
    [[ "$output" != *install-tunnel-autostart* ]]
    [[ "$output" != *set-computer-name* ]]
}

@test "dr-forge up: a chain already up changes nothing and exits 0" {
    run dr-forge up
    [ "$status" -eq 0 ]
    [[ "$output" == *"already published on 18888"* ]]
    [[ "$output" == *"is up"* ]]
}

# The ORDER is the substance of the verb: the tunnel forwards into the mound's published port,
# so a tunnel brought up first has nothing at its far end and the guest gets a proxy that
# refuses everything - which reads as a policy problem and is not one.
#
# AND NO SUPERVISOR PATH IS PASSED. It ships beside vm.ps1, which knows where it is; handing
# one in is what used to make this step go looking in the gateway project.
@test "dr-forge up: the VM comes up before the tunnel, and no script path is handed over" {
    local modes
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    run dr-forge up
    [ "$status" -eq 0 ]
    modes=$(grep -oE '\-Mode [a-z]+' "$DR_MOCK_LOG" | awk '{print $2}' | tr '\n' ' ')
    [ "$modes" = "start tunnel " ]
    ! grep -q -- '-TunnelScript' "$DR_MOCK_LOG"
}

# No second config key for the forge: the gateway is named where Draugr already records "this
# repo needs that one's mound running". A refusal has to name that key and the port that
# identifies the mound, or the reader has nothing to go on.
@test "dr-forge up: a mound that is down with no gateway named says where to name it" {
    probe_with 'port_18888=down'
    run dr-forge up
    [ "$status" -ne 0 ]
    [[ "$output" == *DRAUGR_REQUIRES* ]]
    [[ "$output" == *18888* ]]
}

# The tunnel is the step that fails with everything above it healthy - a forward can be bound
# and dead - so the code vm.ps1 gave up with is named rather than swallowed.
@test "dr-forge up: a tunnel that will not carry fails, naming the code" {
    export DR_MOCK_VM_RC_TUNNEL=12
    run dr-forge up
    [ "$status" -ne 0 ]
    [[ "$output" == *"not carrying"* ]]
    [[ "$output" == *12* ]]
}

# Which mound is the gateway is a DECLARED fact, readable while everything is down - which is
# when it has to be read. The host side of the pair is what counts: a mound that happens to
# serve 18888 internally is not publishing it.
@test "dr_forge_publishes_proxy: judged on the host side of DRAUGR_PORTS" {
    dr_load_common
    # shellcheck source=../lib/forge/common.sh
    . "$DR_ROOT/lib/forge/common.sh"

    DRAUGR_PORTS="127.0.0.1:18888:8888 127.0.0.1:18445:445"
    dr_forge_publishes_proxy
    DRAUGR_PORTS="18888:8888"
    dr_forge_publishes_proxy

    DRAUGR_PORTS="127.0.0.1:18445:445"
    ! dr_forge_publishes_proxy || return 1
    DRAUGR_PORTS=""
    ! dr_forge_publishes_proxy || return 1
    # The MOUND side, not the host side: this publishes 19999, and must not match.
    DRAUGR_PORTS="127.0.0.1:19999:18888"
    ! dr_forge_publishes_proxy
}

# `up` has to work from ANY directory, not only from the gateway project. It used to go looking
# there for the supervisor, so a forge that was entirely healthy was refused from anywhere else.
@test "dr-forge up: outside any repository, a chain already up still succeeds" {
    run dr-forge up
    [ "$status" -eq 0 ]
    [[ "$output" == *"is up"* ]]
}

# Code 14 now means the supervisor is missing from lib/forge - a BROKEN INSTALL, not a
# configuration problem - so it must not be dressed up as one.
@test "dr-forge up: a missing supervisor is reported as a broken install" {
    export DR_MOCK_VM_RC_TUNNEL=14
    run dr-forge up
    [ "$status" -ne 0 ]
    [[ "$output" == *"broken installation"* ]]
    [[ "$output" == *"lib/forge/tunnel.ps1"* ]]
    [[ "$output" != *DRAUGR_REQUIRES* ]]
}

# --screen is the LAST step, after the guest has a way out: a desktop is what a human wants
# once the thing works. Nothing follows it, which is also why it need not block.
@test "dr-forge up --screen: the screen comes after the tunnel" {
    local modes
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    run dr-forge up --screen
    [ "$status" -eq 0 ]
    modes=$(grep -oE '\-Mode [a-z]+' "$DR_MOCK_LOG" | awk '{print $2}' | tr '\n' ' ')
    [ "$modes" = "start tunnel screen " ]
    [[ "$output" == *"screen"* ]]
}

@test "dr-forge up: without --screen nothing opens a screen" {
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    run dr-forge up
    [ "$status" -eq 0 ]
    ! grep -q -- '-Mode screen' "$DR_MOCK_LOG"
}

# A viewer that will not open must not make `up` report failure: everything it was ASKED for is
# already up by then, and failing the command would misdescribe the forge's state.
@test "dr-forge up --screen: a screen that will not open does not fail the whole command" {
    export DR_MOCK_VM_RC_SCREEN=12
    run dr-forge up --screen
    [ "$status" -eq 0 ]
    [[ "$output" == *"the forge itself is up"* ]]
    [[ "$output" == *"is up"* ]]
}

# The same step on its own, so looking at the desktop does not re-run the chain.
@test "dr-forge screen: shows the desktop without bringing anything else up" {
    local modes
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    run dr-forge screen
    [ "$status" -eq 0 ]
    modes=$(grep -oE '\-Mode [a-z]+' "$DR_MOCK_LOG" | awk '{print $2}' | tr '\n' ' ')
    [ "$modes" = "screen " ]
}

# Here it IS the whole command, so a failure is the command's failure.
@test "dr-forge screen: a screen that will not open is a failure of its own" {
    export DR_MOCK_VM_RC_SCREEN=12
    run dr-forge screen
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not open"* ]]
}

@test "dr-forge screen: a stopped VM says to use up --screen instead" {
    probe_with 'vm_running=no' 'vm_state=stopped'
    run dr-forge screen
    [ "$status" -ne 0 ]
    [[ "$output" == *"no desktop yet"* ]]
    [[ "$output" == *"dr-forge up --screen"* ]]
}

@test "dr-forge screen: with the daemon down it says what starts it" {
    probe_with 'daemon=down'
    run dr-forge screen
    [ "$status" -ne 0 ]
    [[ "$output" == *"AppSandbox.exe --headless"* ]]
}

# --screen is up's flag alone. On an already-up forge the action is the right answer, so the
# refusal says so rather than just rejecting the word.
@test "dr-forge screen --screen: refused, and names the action instead" {
    run dr-forge screen --screen
    [ "$status" -ne 0 ]
    [[ "$output" == *"belongs to dr-forge up"* ]]
    [[ "$output" == *"dr-forge screen"* ]]
}

@test "dr-forge down --screen: refused too" {
    run dr-forge down --screen
    [ "$status" -ne 0 ]
    [[ "$output" == *"belongs to dr-forge up"* ]]
}

@test "dr-forge up: --deep is not one of its flags" {
    run dr-forge up --deep
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected argument"* ]]
}

# Both of these are a REACHED STATE, not a failure. A down that exits non-zero because the VM
# was already off cannot be used by anything that checks its code.
@test "dr-forge down: a daemon that is down is success" {
    probe_with 'daemon=down'
    run dr-forge down
    [ "$status" -eq 0 ]
    [[ "$output" == *"not running"* ]]
}

@test "dr-forge down: a VM already stopped is success" {
    probe_with 'vm_running=no' 'vm_state=stopped'
    run dr-forge down
    [ "$status" -eq 0 ]
    [[ "$output" == *already* ]]
}

# ONE call, not two. `down` used to run `shutdown /s /t 0` in the guest over ssh and then let
# vm.ps1 wait it out, because the API was believed to offer only a force stop. It offers a
# graceful ACPI power-off as well, so vm.ps1 asks the daemon for that itself - which also works
# on a guest whose sshd has stopped answering, where the ssh step could not.
@test "dr-forge down: the daemon is asked, with no ssh step before it" {
    local order
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    run dr-forge down
    [ "$status" -eq 0 ]
    order=$(grep -oE '\-Mode [a-z]+' "$DR_MOCK_LOG" | awk '{print $2}' | tr '\n' ' ')
    [ "$order" = "stop " ]
}

@test "dr-forge down: a VM that will not stop fails, naming the code" {
    export DR_MOCK_VM_RC_STOP=11
    run dr-forge down
    [ "$status" -ne 0 ]
    [[ "$output" == *"still running"* ]]
    [[ "$output" == *11* ]]
}

# --- base and rollback: the one baseline ------------------------------------
#
# ONE BASELINE IS A BUG'S DOING, not a simplification, and these tests pin the behaviour that
# follows from it: base refuses a second snapshot, rollback goes to the first, and both say
# which of those they are doing. docs/FORGE.md, "Backup and rollback".

snap_facts() {
    DR_MOCK_SNAP_FACTS="$DR_TMP/snapfacts.txt"
    export DR_MOCK_SNAP_FACTS
    printf '%s\n' "$@" > "$DR_MOCK_SNAP_FACTS"
}

@test "dr-forge base: no daemon is refused, naming the elevated command" {
    probe_with 'daemon=down'
    run dr-forge base
    [ "$status" -ne 0 ]
    [[ "$output" == *"AppSandbox.exe --headless"* ]]
}

# The refusal has to explain itself: "one baseline per VM" reads as a choice someone made,
# and it is a bug being worked around. Both ways forward are named because neither is obvious.
@test "dr-forge base: a second baseline is refused, and the refusal says why" {
    probe_with
    snap_facts 'running=no' 'baseline=yes' 'baseline_index=0' \
        'baseline_name=draugr-base-20261021-2100' 'branches=1' 'snapshots=1' \
        'current_snap=0' 'current_branch=0'
    run dr-forge base
    [ "$status" -ne 0 ]
    [[ "$output" == *"already has a baseline"* ]]
    [[ "$output" == *"draugr-base-20261021-2100"* ]]
    [[ "$output" == *"dr-forge rollback"* ]]
}

# A snapshot needs the guest stopped, so base stops it - and a verb that stops a VM says so
# before it does, which is the same courtesy down extends.
@test "dr-forge base: says it stops the VM, and that up is how it comes back" {
    probe_with 'vm_running=yes'
    run dr-forge base
    [ "$status" -eq 0 ]
    [[ "$output" == *"shut down first"* ]]
    [[ "$output" == *"dr-forge up"* ]]
}

# A baseline taken from a guest whose power was cut is a crash-consistent image of the one
# disk you least want to guess about. Code 22 is snap.ps1 refusing to force it.
@test "dr-forge base: a guest that will not shut down gets no baseline" {
    probe_with 'vm_running=yes'
    export DR_MOCK_SNAP_RC=22
    run dr-forge base
    [ "$status" -ne 0 ]
    [[ "$output" == *"power was cut"* ]]
}

@test "dr-forge rollback: no baseline is refused, naming the verb that makes one" {
    probe_with
    snap_facts 'running=no' 'baseline=no' 'snapshots=0' 'current_snap=-1' 'current_branch=-1'
    run dr-forge rollback --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"no baseline"* ]]
    [[ "$output" == *"dr-forge base"* ]]
}

# What is about to be destroyed is shown in the terms the decision is made in, and the cache
# is named because losing it is the part that costs an afternoon rather than a minute.
@test "dr-forge rollback: shows the baseline and what goes, before asking" {
    probe_with
    snap_facts 'running=yes' 'baseline=yes' 'baseline_index=0' \
        'baseline_name=draugr-base-20261021-2100' 'branches=2' 'snapshots=1' \
        'current_snap=0' 'current_branch=1'
    run dr-forge rollback --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"draugr-base-20261021-2100"* ]]
    [[ "$output" == *discarded* ]]
    [[ "$output" == *cache* ]]
}

# dr-forge never takes a second snapshot, so a tree holding two was made elsewhere - and the
# bug means the newer one is not what its name suggests. Saying so beats rolling back silently.
@test "dr-forge rollback: a second snapshot is reported rather than ignored" {
    probe_with
    snap_facts 'running=no' 'baseline=yes' 'baseline_index=0' 'baseline_name=first' \
        'branches=1' 'snapshots=2' 'current_snap=1' 'current_branch=0' 'extra_snapshots=yes'
    run dr-forge rollback --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"more than one snapshot"* ]]
    [[ "$output" == *"goes to that one"* ]]
}

# 501 is the host saying it does not have the feature at all, which is a different answer from
# a call that failed - and on a macOS host it is the only answer snapshots ever give. It comes
# back from the FIRST read, which is why this is the status code rather than the acting one.
@test "dr-forge rollback: 501 is reported as the host lacking snapshots" {
    probe_with
    export DR_MOCK_SNAP_STATUS_RC=24
    run dr-forge rollback --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not do snapshots"* ]]
}

@test "dr-forge base and rollback: no message sends the reader to a gateway script" {
    probe_with
    run dr-forge base
    [[ "$output" != *forge-layer* ]]
    [[ "$output" != *draugr-gateway* ]]
    snap_facts 'running=no' 'baseline=yes' 'baseline_index=0' 'baseline_name=b' \
        'branches=1' 'snapshots=1' 'current_snap=0' 'current_branch=0'
    run dr-forge rollback --yes
    [[ "$output" != *forge-layer* ]]
    [[ "$output" != *draugr-gateway* ]]
}

# THE ENDPOINTS WERE READ, NOT GUESSED, and this is what stops them drifting back to a guess.
# `DELETE /vms/<n>` cost a failed dr-forge rm and a 405; the snapshot calls come
# from the client and worked example AppSandbox ships at C:\AppSandbox\headless-api\.
@test "lib/forge/snap.ps1: the snapshot endpoints are the documented ones" {
    grep -q 'Asb POST "/vms/\$Vm/snapshots" @{ name = \$Name }' "$DR_ROOT/lib/forge/snap.ps1"
    grep -q 'Asb POST "/vms/\$Vm/start" @{ snapIndex' "$DR_ROOT/lib/forge/snap.ps1"
    grep -q 'branchName = \$branch' "$DR_ROOT/lib/forge/snap.ps1"
    grep -q 'Asb DELETE "/vms/\$Vm/snapshots/\$curSnap/branches/\$curBranch"' \
        "$DR_ROOT/lib/forge/snap.ps1"
}

# THE BASELINE IS NEVER DELETED. snap_delete(name, -2) is refused upstream because deleting the
# base disk IS deleting the VM, and dr-forge deletes a VM through rm - so only BRANCHES are
# dropped here. A bare snapshot delete appearing in this file would be a different feature.
@test "lib/forge/snap.ps1: only branches are deleted, never the baseline" {
    local total branches
    # grep -c exits 1 on a count of zero, which under `set -e` would end the test rather than
    # fail the assertion - so both counts are taken with the exit code neutralised.
    total=$(grep -c 'Asb DELETE' "$DR_ROOT/lib/forge/snap.ps1" || true)
    branches=$(grep -c 'Asb DELETE "/vms/\$Vm/snapshots/\$curSnap/branches/' \
        "$DR_ROOT/lib/forge/snap.ps1" || true)
    [ "$total" -gt 0 ]
    [ "$total" = "$branches" ]
}

# THE ORDER IS FORCED BY THE API, not chosen: a branch is created by BOOTING from a snapshot,
# so the new one cannot exist while the VM is stopped, and a branch is only deletable while it
# is stopped. Discard then start is the only sequence that works.
@test "lib/forge/snap.ps1: the old branch is discarded before the new one is started" {
    local discard branch
    discard=$(grep -n "phase=discarding" "$DR_ROOT/lib/forge/snap.ps1" | head -1 | cut -d: -f1)
    branch=$(grep -n "phase=branching" "$DR_ROOT/lib/forge/snap.ps1" | head -1 | cut -d: -f1)
    [ -n "$discard" ]
    [ -n "$branch" ]
    [ "$discard" -lt "$branch" ]
}

# The asymmetry is deliberate and it is the whole difference between the two verbs' stops.
@test "lib/forge/snap.ps1: base may not pull the plug, rollback may" {
    grep -q 'Stop-Vm \$false' "$DR_ROOT/lib/forge/snap.ps1"
    grep -q 'Stop-Vm \$true' "$DR_ROOT/lib/forge/snap.ps1"
}

# @($null).Count is 1, so an unfiltered empty tree reads as one snapshot - which would make
# base refuse to take the baseline that is not there. The filter is what makes the count true.
@test "lib/forge/snap.ps1: an empty snapshot list counts as zero, not one" {
    grep -q 'Where-Object { \$null -ne \$_ }' "$DR_ROOT/lib/forge/snap.ps1"
}

@test "dr-forge: an unknown action is a typo, not a roadmap" {
    run dr-forge frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown action"* ]]
    [[ "$output" == *"exec, push, pull"* ]]
}

# --- the far end: the VM, where a mound would be ----------------------------
#
# These exercise lib/common.sh rather than bin/dr-forge, because that is where the twelve
# commands that gate on dr_sandbox_exists meet the forge.

# THE CONSTRAINT, MADE EXECUTABLE: Draugr has to work on a machine with no AppSandbox, so the
# no-forge path must not so much as look at the Windows side. This fails if powershell.exe is
# invoked at all.
@test "dr_sandbox_exists: with no forge configured, the Windows side is never touched" {
    dr_load_common
    export DRAUGR_FORGE=
    : > "$DR_MOCK_LOG"
    run dr_sandbox_exists some-mound
    ! grep -q '^powershell ' "$DR_MOCK_LOG" || return 1
    # And it did ask sbx, so the old path really ran rather than being skipped. The sbx mock
    # logs its argv bare, with no command name in front - only the ssh and powershell mocks
    # prefix theirs, so that calls() can tell the three apart in one log.
    grep -q '^ls --json' "$DR_MOCK_LOG"
}

@test "dr_sandbox_exists: a name that is not the forge still goes to sbx" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    : > "$DR_MOCK_LOG"
    run dr_sandbox_exists a-different-mound
    ! grep -q '^powershell ' "$DR_MOCK_LOG"
}

@test "dr_sandbox_exists: the forge's own name is answered by the probe" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    run dr_sandbox_exists mock-vm
    [ "$status" -eq 0 ]
    grep -q 'probe.ps1' "$DR_MOCK_LOG"
}

@test "dr_sandbox_exists: a forge whose VM is not running is absent" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    probe_with 'vm_running=no'
    run dr_sandbox_exists mock-vm
    [ "$status" -ne 0 ]
    # Every caller's own refusal says "does not exist. Create it with: dr-up", and for a VM
    # both halves are wrong - so the real reason has to be said here.
    [[ "$output" == *"is not running"* ]]
    [[ "$output" == *"dr-forge up"* ]]
}

# RUNNING IS NOT ENOUGH. Measured: `ssh -G` resolves every forge VM's alias to
# host.docker.internal:18022, byte-identical, so the name is dropped at the first hop and what
# answers is whichever VM the supervisor serves. A gate that passes on "running" alone sends a
# dr-data push into whichever guest happens to be on that port.
@test "dr_sandbox_exists: a forge whose forward serves another VM is not a far end" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    probe_with 'fwd_vm=some-other-vm'
    run dr_sandbox_exists mock-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"serves 'some-other-vm'"* ]]
    [[ "$output" == *"would land in 'some-other-vm'"* ]]
}

# UNKNOWN REFUSES HERE, unlike doctor's link 7 which treats it as a pass. Link 7 is avoiding a
# nag about a forge that is fine; this gate governs writing files into a VM, where guessing
# wrong does not undo.
@test "dr_sandbox_exists: a pin that cannot be read refuses rather than guessing" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    probe_with 'fwd_vm=unreadable'
    run dr_sandbox_exists mock-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be read"* ]]
}

@test "dr_sandbox_exists: a forward serving this VM is a far end, whatever the case" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    probe_with 'fwd_vm=MOCK-VM'
    run dr_sandbox_exists mock-vm
    [ "$status" -eq 0 ]
}

# Nothing above applies to a mound: its route is `sbx ssh proxy %n`, so the name travels to the
# resolver and "it exists" cannot disagree with "that is what I will reach".
@test "dr_sandbox_exists: a mound is judged on its name alone, with no pin to match" {
    dr_load_common
    export DRAUGR_FORGE=
    : > "$DR_MOCK_LOG"
    run dr_sandbox_exists some-mound
    grep -q '^ls --json' "$DR_MOCK_LOG"
    ! grep -q 'fwd_vm' "$DR_MOCK_LOG"
}

# lib/forge/ has to stay deletable: with it gone, a configured forge reads as absent and says
# so, rather than taking the rest of Draugr down with it.
@test "dr_sandbox_exists: a configured forge with lib/forge removed is absent, with a reason" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    DRAUGR_ROOT="$DR_TMP/no-forge-here"
    mkdir -p "$DRAUGR_ROOT"
    run dr_sandbox_exists mock-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"is missing"* ]]
}

@test "dr_sandbox_url: a mound far end is unchanged" {
    dr_load_common
    export DRAUGR_FORGE=
    export DRAUGR_SANDBOX=mymound
    export DR_REPO=/mnt/c/Code/MyGame
    [ "$(dr_sandbox_url)" = 'ssh://mymound.sbx/c/Code/MyGame' ]
}

# The VM's name plus .forge is the ssh_config alias, and the mound path carries over untouched
# - measured in the guest, where git resolves /c/... to C:\...
@test "dr_sandbox_url: the forge far end keeps the path and changes only the host" {
    dr_load_common
    export DRAUGR_FORGE=ue-427-test
    export DRAUGR_SANDBOX=ue-427-test
    export DR_REPO=/mnt/c/Code/MyGame
    [ "$(dr_sandbox_url)" = 'ssh://ue-427-test.forge/c/Code/MyGame' ]
}

@test "dr_sandbox_url: a forge configured but NOT the far end stays with the mound" {
    dr_load_common
    export DRAUGR_FORGE=ue-427-test
    export DRAUGR_SANDBOX=mymound
    export DR_REPO=/mnt/c/Code/MyGame
    [ "$(dr_sandbox_url)" = 'ssh://mymound.sbx/c/Code/MyGame' ]
}

# One host for all three callers. dr-sync reaching the VM while dr-data reached the mound is
# the kind of split that takes a day to see, so they share this and the test says so.
@test "dr_sandbox_ssh_host: a mound is <name>.sbx, a forge VM is <name>.forge" {
    dr_load_common
    export DRAUGR_SANDBOX=mymound
    export DRAUGR_FORGE=
    [ "$(dr_sandbox_ssh_host)" = 'mymound.sbx' ]
    export DRAUGR_FORGE=ue-427-test
    export DRAUGR_SANDBOX=ue-427-test
    [ "$(dr_sandbox_ssh_host)" = 'ue-427-test.forge' ]
}

@test "dr-data: its rsync target uses the same host as the git URL" {
    dr_load_common
    export DRAUGR_FORGE=ue-427-test
    export DRAUGR_SANDBOX=ue-427-test
    export DR_REPO=/mnt/c/Code/MyGame
    # The two spellings must agree about which machine they mean.
    [ "$(dr_sandbox_ssh_host)" = 'ue-427-test.forge' ]
    [ "$(dr_sandbox_url)" = 'ssh://ue-427-test.forge/c/Code/MyGame' ]
}

# --- init ------------------------------------------------------------------

# The daemon is the one step init cannot take, so it has to be the first refusal rather than a
# failure minutes in. It names the Windows command, never a gateway script.
@test "dr-forge init: no daemon is refused, naming the elevated command" {
    probe_with 'daemon=down'
    run dr-forge init
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs elevation"* ]]
    [[ "$output" == *"AppSandbox.exe --headless"* ]]
}

# The VM is named, and the WSL public key is handed over as a PATH: its text contains spaces,
# and an unquoted argument carrying one has already cost a silent failure here once.
@test "dr-forge init: names the VM and passes the WSL key as a path" {
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    mkdir -p "$HOME/.ssh"
    printf 'ssh-ed25519 AAAATEST draugr-forge-wsl\n' > "$HOME/.ssh/draugr_forge_ed25519.pub"
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    grep -q 'init.ps1' "$DR_MOCK_LOG"
    grep -q -- '-Vm mock-vm' "$DR_MOCK_LOG"
    grep -q -- '-WslPubKey' "$DR_MOCK_LOG"
}

# Without that key the alias resolves and then cannot log in, which is a confusing place to
# find out. Everything else init does is still worth doing, so this warns rather than refuses.
@test "dr-forge init: a missing WSL key warns and names dr-setup, without failing" {
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    [[ "$output" == *"dr-setup --forge"* ]]
    [[ "$output" == *"cannot log in"* ]]
}

@test "dr-forge init --restart: passed through, and refused on other actions" {
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    probe_with
    run dr-forge init --restart
    [ "$status" -eq 0 ]
    grep -q -- '-Restart' "$DR_MOCK_LOG"
    run dr-forge up --restart
    [ "$status" -ne 0 ]
    [[ "$output" == *"belongs to dr-forge init"* ]]
}

# Each code init.ps1 can exit with has to produce advice of its own, or the reader gets a
# number. 11 is the one that happens - a guest still booting, or the wrong VM named.
# Hibernation and the pagefile are guest settings rather than anything Draugr needs to work, so
# they can be declined - but they are ON by default, because a differencing child that grows by
# tens of GiB for files nobody reads is a cost of the layer mechanism itself.
@test "dr-forge init: tunes disk churn by default, and --no-tune declines it" {
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    run grep -c -- '-NoTune' "$DR_MOCK_LOG"
    [ "$output" = 0 ]

    : > "$DR_MOCK_LOG"
    run dr-forge init --no-tune
    [ "$status" -eq 0 ]
    grep -q -- '-NoTune' "$DR_MOCK_LOG"
}

# The paths travel as a FILE, one per line, because the value is semicolon-separated Windows
# paths - spaces in them by nature - and the route to the guest crosses four parsers. An
# argument is how --screen failed silently in vm.ps1.
@test "dr-forge init: Defender exclusions are passed as a file, not an argument" {
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    export DRAUGR_FORGE_NOSCAN='C:\UE_4.27;D:\work\My Game'
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    grep -q -- '-NoScanFile' "$DR_MOCK_LOG"
    # Two paths, and the one with a space survived as one entry.
    [[ "$output" == *"exclusions to apply: 2"* ]]
}

# "*" is a different act from narrowing a scan, so it is announced before anything happens.
@test "dr-forge init: NOSCAN=* warns that Defender is disabled, not narrowed" {
    export DRAUGR_FORGE_NOSCAN='*'
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    [[ "$output" == *"will be DISABLED"* ]]
    [[ "$output" == *"Not narrowed - off"* ]]
    [[ "$output" != *"exclusions to apply"* ]]
}

# A "*" with paths beside it is a mistake worth naming rather than refusing over: nothing is
# left to exclude once nothing is scanned.
@test "dr-forge init: NOSCAN=* alongside paths says the paths are moot" {
    export DRAUGR_FORGE_NOSCAN='*;C:\UE4'
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    [[ "$output" == *"will be DISABLED"* ]]
    [[ "$output" == *"nothing left to exclude"* ]]
}

@test "dr-forge init: no exclusion list is passed when the key is empty" {
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    export DRAUGR_FORGE_NOSCAN=
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    run grep -c -- '-NoScanFile' "$DR_MOCK_LOG"
    [ "$output" = 0 ]
}

@test "dr-forge init: --no-tune is refused on other actions" {
    probe_with
    run dr-forge up --no-tune
    [ "$status" -ne 0 ]
    [[ "$output" == *"belongs to dr-forge init"* ]]
}

@test "dr-forge init: the guest never answering is explained, not numbered" {
    export DR_MOCK_INIT_RC=11
    probe_with
    run dr-forge init
    [ "$status" -ne 0 ]
    [[ "$output" == *"never answered on ssh"* ]]
    [[ "$output" == *"dr-forge screen"* ]]
}

# The same rule the up and doctor guards enforce: init's messages must not send the reader into
# another project's directory. It is the verb that replaced a gateway script, so it is the one
# most likely to name one.
# MEASURED, on the first forge built after rm: Windows OpenSSH re-quotes the command
# it sends, so the remote cmd receives a trailing double quote - and `echo` prints its argument
# literally, junk and all. The guest came back named `TEST"` and init reported a rename that had
# worked as one that had not. `hostname` ignores the stray argument, so it answers cleanly.
# The DRAUGR_* round trips elsewhere are immune because they MATCH a marker substring rather
# than capture a value; anything that reads a value back needs this form.
@test "lib/forge/init.ps1: the post-reboot name is read with hostname, not echo" {
    grep -q 'cmd /c hostname' "$DR_ROOT/lib/forge/init.ps1"
    # CODE ONLY, not prose: `[^#]*` cannot span the `#` of a comment, so the paragraph in
    # init.ps1 that explains why this form is wrong does not count as using it. The first
    # version of this test grepped the whole file and failed on its own explanation.
    run grep -c '^[^#]*echo %COMPUTERNAME%' "$DR_ROOT/lib/forge/init.ps1"
    [ "$output" = 0 ]
}

# --- the desktop camera -----------------------------------------------------
#
# An agent cannot look at a screen, so a screenshot it can pull back is the only way anything
# visual gets checked. The capture half used to live only in the gateway project, which meant a
# forge built anywhere else had no camera at all while docs/FORGE.md claimed layer-0 carried one.

@test "lib/forge/guest/install-shot.ps1: Draugr ships its own copy" {
    [ -f "$DR_ROOT/lib/forge/guest/install-shot.ps1" ]
    # The generated files must name THIS copy as their origin: a guest file pointing at another
    # project's path is how the last reader went looking in the wrong repository.
    run grep -c 'draugr-gateway' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    [ "$output" = 0 ]
    grep -q "Draugr's lib/forge/guest/install-shot.ps1" "$DR_ROOT/lib/forge/guest/install-shot.ps1"
}

# DRAUGR_CHANGED is the whole reason this is not the gateway's file verbatim: init reports
# "installed" or "already installed" from it, and a script that cannot tell those apart makes
# the summary lie on every re-run.
@test "lib/forge/guest/install-shot.ps1: reports whether it changed anything" {
    grep -q 'DRAUGR_CHANGED=0' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    grep -q 'DRAUGR_CHANGED={0}' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    # Idempotence has to be real, not claimed: the bodies are compared before being written and
    # the task is only registered when absent. -Force on either would report a change every run.
    grep -q 'already current' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    grep -q 'already registered' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
}

@test "lib/forge/init.ps1: installs the desktop camera, and says which it did" {
    grep -q "Invoke-GuestScript 'install-shot.ps1'" "$DR_ROOT/lib/forge/init.ps1"
    grep -q "Phase 'desktop camera'" "$DR_ROOT/lib/forge/init.ps1"
    grep -q 'already installed' "$DR_ROOT/lib/forge/init.ps1"
}

# The task runs in session 1 with an interactive principal; ssh lands in session 0, which has no
# desktop. Register it by SID rather than by name: over ssh $env:USERDOMAIN is WORKGROUP, so
# "$env:USERDOMAIN\$env:USERNAME" does not resolve and registration fails with 0x80070534.
@test "lib/forge/guest/install-shot.ps1: the task is interactive and named by SID" {
    grep -q 'LogonType Interactive' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    grep -q 'GetCurrent()).User.Value' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    run grep -c 'UserId "\$env:USERDOMAIN' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    [ "$output" = 0 ]
}

@test "dr-forge init: no message sends the reader to a gateway script" {
    export DR_MOCK_INIT_RC=13
    probe_with
    run dr-forge init
    [[ "$output" != *forge-vm-setup* ]]
    [[ "$output" != *forge-layer* ]]
    [[ "$output" != *forge-screen* ]]
    [[ "$output" != *draugr-gateway* ]]
}

# --- rm --------------------------------------------------------------------

# A file of inspect facts, so a test can describe the folder rm is looking at.
rm_facts() {
    DR_MOCK_RM_FACTS="$DR_TMP/rmfacts.txt"
    export DR_MOCK_RM_FACTS
    printf '%s\n' "$@" > "$DR_MOCK_RM_FACTS"
}

@test "dr-forge rm: no daemon is refused, naming the elevated command" {
    probe_with 'daemon=down'
    run dr-forge rm
    [ "$status" -ne 0 ]
    [[ "$output" == *"AppSandbox.exe --headless"* ]]
}

# The blast radius is shown in units a decision can be made in, before the question is asked.
@test "dr-forge rm: shows the folder, its size and its contents before asking" {
    probe_with
    rm_facts 'folder=C:\ForgeLayers\mock-vm' 'exists=yes' 'bytes=33279705088' \
        'entry=disk.vhdx' 'entry=snapshots\' 'running=no' 'safe=yes'
    run dr-forge rm --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"C:\ForgeLayers\mock-vm"* ]]
    [[ "$output" == *"31.0 GiB"* ]]
    [[ "$output" == *"disk.vhdx"* ]]
}

# A VM whose folder holds a frozen layer is NOT offered for confirmation: being asked to
# confirm something unsafe invites saying yes to it. --yes must not get past this either.
@test "dr-forge rm: a frozen layer in the folder is refused, not confirmed" {
    probe_with
    rm_facts 'folder=C:\ForgeLayers' 'exists=yes' 'bytes=99' \
        'unsafe=a frozen layer is inside it: C:\ForgeLayers\layer-2-ue427\disk.vhdx' \
        'running=no' 'safe=no'
    run dr-forge rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to delete"* ]]
    [[ "$output" == *"layer-2-ue427"* ]]
    [[ "$output" == *RECURSIVELY* ]]
}

# An unknown VM is a typo, not a failure to delete - and saying so beats a daemon error.
@test "dr-forge rm: an unknown VM says there is nothing to delete" {
    probe_with
    export DR_MOCK_RM_RC=11
    run dr-forge rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"knows no VM called"* ]]
}

# Every forge VM shares one known_hosts entry, because the port is pinned. Left behind, it
# makes the NEXT VM look like a man-in-the-middle rather than a new machine.
@test "dr-forge rm: clears the shared forge host key" {
    probe_with
    mkdir -p "$HOME/.ssh"
    printf '[host.docker.internal]:18022 ssh-ed25519 AAAATEST\n' \
        > "$HOME/.ssh/draugr_forge_known_hosts"
    run dr-forge rm --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"host key"* ]]
    run grep -c 'AAAATEST' "$HOME/.ssh/draugr_forge_known_hosts"
    [ "$output" = 0 ]
}

# Nothing here rewrites a config file: which VM a project uses is a declared choice, and the
# replacement does not exist yet. So it says so instead of guessing.
@test "dr-forge rm: warns that DRAUGR_FORGE still names the deleted VM" {
    probe_with
    run dr-forge rm --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRAUGR_FORGE still names"* ]]
}

# THE MOCK CANNOT CATCH A WRONG ENDPOINT, so the verified one is pinned here. The daemon
# answers DELETE /vms/<name> with 405 and no Allow header, and a sub-route probe with 404, so
# neither the error nor a probe reveals the right call - it came from the client AppSandbox
# ships. A failed dr-forge rm is what this test exists to prevent repeating.
@test "lib/forge/rm.ps1: deletes through POST /delete, the verb that was verified" {
    grep -q 'vms/$Vm/delete" -Method POST' "$DR_ROOT/lib/forge/rm.ps1"
    # And not the guess that answered 405.
    run grep -c 'Uri "$($h.endpoint)/v1/vms/$Vm" -Method DELETE' "$DR_ROOT/lib/forge/rm.ps1"
    [ "$output" = 0 ]
}

@test "dr-forge rm: no message sends the reader to a gateway script" {
    probe_with
    run dr-forge rm --yes
    [[ "$output" != *forge-destroy* ]]
    [[ "$output" != *forge-layer* ]]
    [[ "$output" != *draugr-gateway* ]]
}

# --- the keys the daemon removes at every start -----------------------------
# MEASURED: AppSandbox rewrites administrators_authorized_keys when it brings a VM
# up and keeps only its own deploy key. So `dr-forge up` on a stopped VM - which is every VM
# after a host reboot - could not get in, and said so as a 300 s timeout.

# THE ORDER IS THE FIX. Waiting on the admin key before installing it burns the whole timeout
# watching a refusal, which is exactly what happened. Line numbers, because nothing else can
# say "before", and comments excluded because the comments here quote both names.
@test "live 2026-10-31: start installs the keys before it waits on one" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    local install_at wait_at
    install_at=$(grep -nE 'Install-GuestKeys \$boot\.Port' "$vm" |
                 grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    wait_at=$(grep -nE 'Wait-GuestCommand \$TimeoutSec' "$vm" |
              grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    [ -n "$install_at" ]
    [ -n "$wait_at" ]
    [ "$install_at" -lt "$wait_at" ]
}

# The bootstrap waits for WHICHEVER credential the guest accepts, admin first. Waiting on the
# deploy key alone - which the first version did - is a dead wait on any VM built from a layer,
# because New-VmBlock gives those no deploy key: the full timeout, every single start.
@test "live 2026-10-31: the bootstrap waits for any credential, admin first" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    # ANCHORED on the opening paren. Unanchored it matched a mutation that renamed the
    # function to Wait-GuestAnyKeyXX - the same prefix slip rule 12 in docs/HACKING.md was
    # written for, reproduced in the next test written after it.
    grep -qE 'function Wait-GuestAnyKey\(' "$vm"
    # Admin is tried before deploy in the per-round list, which is what makes a healthy guest
    # cost nothing. Both on one line, so their order is readable as written.
    grep -qF "@{ Which = 'admin'; Key = \$AdminKey }, @{ Which = 'deploy'" "$vm"
    # And no caller waits on the deploy key alone any more.
    run bash -c "grep -vE '^[[:space:]]*#' '$vm' | grep -F \"Wait-GuestKey (Join-Path\""
    [ -z "$output" ]
    # And it is reachable on its own, so a guest can be repaired without a provision run.
    grep -q "^'keys' {" "$vm"
    grep -q 'start, stop, keys, tunnel, screen' "$vm"
}

# A TIMEOUT IS A SHAPE OF FAILURE, NOT A CAUSE. The old message named a timeout for a refused
# key and sent a reader to the guest's disk. ssh's own last word is now kept and reported.
@test "live 2026-10-31: a refusal is reported as a refusal, not as a timeout" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    grep -q 'lastSshOut' "$vm"
    grep -q 'refused the key' "$vm"
    grep -q 'did not accept a connection' "$vm"
    grep -q 'said nothing at all' "$vm"
    # THE MESSAGE A READER SEES, not merely that the function exists somewhere in the file.
    # This was first written as a grep for Get-SshVerdict anywhere, and a mutation that took
    # it out of this very message PASSED: the function's own definition still matched. An
    # assertion that the fix exists is not an assertion that the fix is used.
    run bash -c "grep -n 'Fail 11' '$vm' | grep -vE '^[0-9]+:[[:space:]]*#'"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q 'Get-SshVerdict'
    grep -q 'Last reply:' "$vm"
}

# ONE HOME FOR append-plus-icacls. provision carried it inline, the start path needed the
# same thing, and guest/authorize-key.ps1 had done exactly this since before either - which
# was found only after a third copy had been written and had to be deleted again. So this
# asserts the EXISTING script is the one used, not that some installer exists.
@test "live 2026-10-31: the admin key has one installer, and provision delegates to it" {
    local ak="$DR_ROOT/lib/forge/guest/authorize-key.ps1"
    [ -f "$ak" ]
    grep -q 'administrators_authorized_keys' "$ak"
    grep -q 'S-1-5-32-544' "$ak"
    # vm.ps1 uses it rather than carrying its own.
    grep -q "Script = 'authorize-key.ps1'" "$DR_ROOT/lib/forge/vm.ps1"
    [ ! -f "$DR_ROOT/lib/forge/guest/install-admin-key.ps1" ]
    # provision no longer builds that file itself: no Add-Content to it outside a comment.
    run bash -c "grep -n 'administrators_authorized_keys' '$DR_ROOT/lib/forge/provision.ps1' |
                 grep -vE '^[0-9]+:[[:space:]]*#' | grep -E 'Add-Content|New-Item|icacls'"
    [ -z "$output" ]
    grep -q "vm.ps1') -Mode keys" "$DR_ROOT/lib/forge/provision.ps1"
}

# A half-written key is a line sshd ignores, and an ignored line looks exactly like a key
# that was never installed. So the shape is checked before anything is appended.
@test "live 2026-10-31: the admin key installer refuses something that is not a key" {
    local ak="$DR_ROOT/lib/forge/guest/authorize-key.ps1"
    grep -q 'does not look like a public key' "$ak"
    grep -q 'exit 1' "$ak"
}

# The supervisor retries on its own clock, so the tunnel path has to ensure the key too -
# measured from the supervisor's log, where it reconnected into the window between a VM start
# and the key install and was refused. AFTER the early exit, because a carrying tunnel needs
# none of it; BEFORE the supervisor is started or prodded, because both need the key.
@test "live 2026-10-31: the tunnel path ensures the key, after the carrying check" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    local carries_at ensure_at start_at
    carries_at=$(grep -nF "Say 'already carries'" "$vm" |
                 grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    ensure_at=$(grep -nE 'making sure the keys the daemon removes' "$vm" |
                grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    start_at=$(grep -nE 'Start-Supervisor|starting the tunnel supervisor' "$vm" |
               grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    [ -n "$carries_at" ]
    [ -n "$ensure_at" ]
    [ -n "$start_at" ]
    [ "$carries_at" -lt "$ensure_at" ]
    [ "$ensure_at" -lt "$start_at" ]
}

# --- the daemon's lifecycle as a command -----------------------------------
# layer.ps1 printed six lines to paste into an elevated PowerShell, and a seventh to undo it.
# Asked to be one command - and the elevation was wrong anyway: the headless API
# gates RUNNING the daemon, not calling it, so only the --headless relaunch needs a prompt.

@test "live 2026-10-31: the daemon script has the four modes and refuses others" {
    local d="$DR_ROOT/lib/forge/daemon.ps1"
    [ -f "$d" ]
    grep -qF "validModes = @('status', 'stop', 'start', 'restart')" "$d"
    grep -qF 'Fail 2 "unknown -Mode' "$d"
}

# THE POSITION IS THE POINT. This verb has to work when AppSandbox is DOWN - most of what it
# is for - while every action below dr_forge_probe has already died by then on a Windows side
# that did not answer. Line numbers, because "above" is the whole claim.
@test "live 2026-10-31: the daemon verb is handled before anything probes" {
    local f="$DR_ROOT/bin/dr-forge"
    local verb_at probe_at
    verb_at=$(grep -nF '[ "$action" = daemon ]' "$f" |
              grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    # Located by the gating call's ARGUMENTS, not by an `if !` prefix: the probe is
    # conditional now (it does not gate `gateway`), and the other two dr_forge_probe calls
    # in this file pass neither "$deep" nor both arguments.
    probe_at=$(grep -nF 'dr_forge_probe "$vm" "$deep"' "$f" |
               grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    [ -n "$verb_at" ]
    [ -n "$probe_at" ]
    [ "$verb_at" -lt "$probe_at" ]
}

# AND IT DOES NOT GATE `gateway` EITHER, for the same reason one verb along: that one writes a
# directory and starts nothing, so it has to work while the Windows side is unreachable. A
# checkout outside /mnt is exactly that case - probe.ps1 has no Windows spelling there unless
# WSL_DISTRO_NAME is set, so the probe died with "cannot work out a Windows spelling" before
# the generator ran. It took 24 of forge-gateway.bats's 25 tests down on every CI run while
# passing on any machine with WSL, which is why the assertion is on the SOURCE: no test run
# here can see a gate that this machine's environment satisfies.
@test "the probe does not gate gateway, which touches nothing over there" {
    local f="$DR_ROOT/bin/dr-forge"
    local line
    line=$(grep -nF 'dr_forge_probe "$vm" "$deep"' "$f" |
           grep -vE '^[0-9]+:[[:space:]]*#' | head -1)
    [ -n "$line" ]
    [[ "$line" == *'"$action" != gateway'* ]]
}

# A verb absent from the usage header or the README is a verb nobody finds.
@test "live 2026-10-31: the daemon verb is documented where the others are" {
    grep -qF 'dr-forge daemon <verb>' "$DR_ROOT/bin/dr-forge"
    grep -qF 'dr-forge daemon <verb>' "$DR_ROOT/README.md"
    # And the refusal lists it, or the code accepts what the help denies.
    grep -qF 'pull, gateway, daemon' "$DR_ROOT/bin/dr-forge"
}

# FORCE IS NOT OFFERED, and that is a decision rather than an omission: {"force":true}
# terminates the guests, and a terminated guest is a dirty disk - while the verbs this exists
# to serve are the ones that freeze disks.
@test "live 2026-10-31: the daemon stop never forces a running guest" {
    local d="$DR_ROOT/lib/forge/daemon.ps1"
    # THE JSON KEY, not the word. First written as a grep for "force" anywhere outside a
    # comment, which matched the refusal message that EXPLAINS why force is not offered - and
    # would equally have matched a legitimate -Force on some unrelated cmdlet. What must never
    # appear is the API's own `{"force":true}`, which is what terminates a guest.
    # Comments stripped AS WELL, because the header comment quotes `{"force":true}` to say it
    # is never sent. Rule 12 in docs/HACKING.md, broken in the next test written after it.
    run bash -c "grep -vE '^[[:space:]]*#' '$d' | grep -F '\"force\"'"
    [ -z "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$d' | grep -F 'force='"
    [ -z "$output" ]
    # It shuts each VM down gracefully and WAITS, which is what makes force unnecessary.
    grep -qF '/shutdown' "$d"
    grep -qF 'was still running after' "$d"
}

# layer.ps1 points at the command instead of reciting it.
@test "live 2026-10-31: layer.ps1 no longer prints a recipe to paste" {
    local l="$DR_ROOT/lib/forge/layer.ps1"
    grep -qF 'dr-forge daemon stop' "$l"
    grep -qF 'dr-forge daemon start' "$l"
    # The six lines are gone from the code - comments stripped, because the comment that
    # replaced them explains what they were.
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -F 'Invoke-RestMethod -Method Post'"
    [ -z "$output" ]
}

# --- a supervisor is not the same thing as a bound port --------------------
# Get-ForwardOwner began at the port and returned $null when nothing held it, so a supervisor
# BETWEEN RECONNECTS - ssh exited, next attempt up to ten seconds away - was invisible. vm.ps1
# started a second one, which read the same claim, stood down, and left the caller reporting
# "the forward never carried". Reproduced live by ending the ssh child.

@test "live 2026-10-31: a supervisor holding no port is seen, not ignored" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    # ANCHORED on the whole declaration. Unanchored, this matched a mutation that renamed the
    # function to Get-SupervisorClaimXX, because the old name is a prefix of the new one.
    grep -qE 'function Get-SupervisorClaim[[:space:]]*\{' "$vm"
    # Carrying and existing are now separate answers, so a caller can tell them apart.
    grep -qF 'Bound = $false' "$vm"
    grep -qF 'Bound = $true' "$vm"
    # A recycled pid would read as a live supervisor and could silence the real one, so the
    # process has to be a PowerShell as well as present - tunnel.ps1's own guard.
    # -e, because the pattern starts with a dash and grep would read it as an option.
    grep -qF -e '-notcontains $p.ProcessName' "$vm"
}

# Killing an ssh child is only sensible when there IS one. Gating the bound-but-dead path on
# Bound is what keeps the new state out of it.
@test "live 2026-10-31: the two not-carrying states are told apart" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    grep -qF 'if ($own -and $own.Bound) {' "$vm"
    grep -qF 'between reconnects' "$vm"
}

# THE POINT OF THE WHOLE FIX: the waiting branch must end in its own verdict and never fall
# through to launching a rival. Line numbers, because "never reaches" is an ordering claim.
@test "live 2026-10-31: waiting for the incumbent never starts a second supervisor" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    local wait_at fail_at start_at
    wait_at=$(grep -nF 'between reconnects' "$vm" |
              grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    fail_at=$(grep -nF 'did not bring the forward' "$vm" |
              grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    start_at=$(grep -nF 'starting the tunnel supervisor' "$vm" |
               grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    [ -n "$wait_at" ]
    [ -n "$fail_at" ]
    [ -n "$start_at" ]
    [ "$wait_at" -lt "$fail_at" ]
    [ "$fail_at" -lt "$start_at" ]
    # And the verdict NAMES THE PID, which is the whole difference from the message it
    # replaces: "the forward never carried" sent a reader to the guest, this sends them to a
    # process.
    grep -qF 'SupervisorPid)) did not bring the forward' "$vm"
}

# probe had the same gate, so doctor could not report this state either. The claim is emitted
# ABOVE the port lookup, which is the only way it survives having no port holder.
@test "live 2026-10-31: probe reports the claim without a port holder" {
    local pr="$DR_ROOT/lib/forge/probe.ps1"
    local claim_at gate_at
    claim_at=$(grep -nF "Emit 'sup_pid'" "$pr" |
               grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    gate_at=$(grep -nF '$fwd = Get-NetTCPConnection' "$pr" |
              grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    [ -n "$claim_at" ]
    [ -n "$gate_at" ]
    [ "$claim_at" -lt "$gate_at" ]
    grep -qF "Emit 'sup_vm'" "$pr"
}

# A wait is not a break, and doctor used to call it one.
@test "live 2026-10-31: doctor calls a wait a wait" {
    local df="$DR_ROOT/bin/dr-forge" code
    # COMMENTS STRIPPED. The comment explaining this very change also says "between
    # reconnects", so a whole-file grep passed on a file whose actual message had been
    # mutated away. Fifth time in this project that a fix's own prose has satisfied the test
    # written to check the fix - see docs/HACKING.md.
    code=$(grep -vE '^[[:space:]]*#' "$df")
    printf '%s\n' "$code" | grep -qF 'between reconnects'
    printf '%s\n' "$code" | grep -qF 'sup_vm'
    # The warning is still there for the case where nothing claims the forwards at all.
    printf '%s\n' "$code" | grep -qF 'nothing is holding the tunnel forwards'
}

# --- the host key belongs to the VM, not to the port -----------------------
# MEASURED: dialled through the pinned 18022, ssh gave rc=255 and "REMOTE HOST
# IDENTIFICATION HAS CHANGED" because that address had served a previous guest; the same guest
# on its relay port gave rc=0. accept-new accepts an UNKNOWN host and refuses a CHANGED one,
# correctly - so every check through the forward reported the far end dead while it was fine,
# and `dr-forge up` spent 300 s saying so.

# EVERY dial, not just the one that bit. Both addresses Draugr uses are shared: 18022 is
# pinned by design, and the relay port is the daemon's to reassign.
@test "live 2026-10-31: every guest dial keys its host key to the VM" {
    local f bad=''
    for f in "$DR_ROOT"/lib/forge/*.ps1 "$DR_ROOT"/lib/forge/common.sh; do
        # A file that dials at all must carry the alias. Per-file rather than per-line: the
        # calls wrap across backtick and backslash continuations, and joining those correctly
        # is more machinery than the question deserves.
        #
        # COMMENTS STRIPPED, and that was not the first version. Several of these files
        # explain the alias in a comment ABOVE the option, so grepping the whole file passed
        # on a file whose actual option had been deleted - caught by mutation, and the fourth
        # time in this project that a fix's own prose satisfied a test written to check the fix.
        local dials aliases
        dials=$(grep -vE '^[[:space:]]*#' "$f" | grep -c 'StrictHostKeyChecking' || true)
        aliases=$(grep -vE '^[[:space:]]*#' "$f" | grep -c 'HostKeyAlias' || true)
        if [ "$dials" -gt 0 ] && [ "$aliases" -eq 0 ]; then
            bad="$bad $(basename "$f")"
        fi
    done
    [ -z "$bad" ] || { echo "no HostKeyAlias in:$bad"; return 1; }
}

# THE COUNTS MUST MATCH, which is what catches a NEW call site added without the alias - the
# per-file test above would not, since the file already has one elsewhere. Comments are
# excluded because the explanations name both options.
@test "live 2026-10-31: no guest dial is left without the alias" {
    local strict alias
    strict=$(grep -h 'StrictHostKeyChecking' "$DR_ROOT"/lib/forge/*.ps1 "$DR_ROOT"/lib/forge/common.sh |
             grep -vE '^[[:space:]]*#' | grep -c 'StrictHostKeyChecking')
    alias=$(grep -h 'HostKeyAlias' "$DR_ROOT"/lib/forge/*.ps1 "$DR_ROOT"/lib/forge/common.sh |
            grep -vE '^[[:space:]]*#' | grep -c 'HostKeyAlias')
    [ "$strict" -gt 0 ]
    [ "$strict" -eq "$alias" ] || {
        echo "StrictHostKeyChecking appears $strict times, HostKeyAlias $alias"
        return 1
    }
}

# The alias names the VM, so two guests never share an entry. A constant would be the bug
# again with extra steps.
@test "live 2026-10-31: the alias is per-VM, not a constant" {
    # `draugr-[$]` rather than `draugr-\$[Vv]m`: inside a double-quoted bash -c, `$[` is
    # bash's DEPRECATED arithmetic expansion, so that pattern was evaluated rather than
    # matched and excluded nothing. A character class keeps the dollar literal, and no
    # nested quoting layer is needed at all once the pipeline runs here.
    local bad
    bad=$(grep -h 'HostKeyAlias' "$DR_ROOT"/lib/forge/*.ps1 "$DR_ROOT"/lib/forge/common.sh |
          grep -vE '^[[:space:]]*#' | grep -v 'draugr-[$]' || true)
    [ -z "$bad" ] || { echo "not keyed on the VM:$bad"; return 1; }
}

# --- the Host *.forge block ------------------------------------------------

# The suffix is written in lib/common.sh AND lib/forge/common.sh because no core script may
# source the forge library. Nothing but this test stops the two drifting apart, and the symptom
# of drift would be dr-sync reaching a name that nothing resolves.
@test "the .forge suffix is spelled the same in core and in the forge library" {
    dr_load_common
    # shellcheck source=../lib/forge/common.sh
    . "$DR_ROOT/lib/forge/common.sh"
    export DRAUGR_FORGE=somevm
    export DRAUGR_SANDBOX=somevm
    [ "$(dr_sandbox_ssh_host)" = "$(dr_forge_alias_host somevm)" ]
}

# Optional by construction, at the level of a single file: a machine whose owner never asked
# for a forge must not end up with a block mentioning one.
@test "dr-setup: writes no forge block unless it is asked for" {
    run dr-setup
    [ "$status" -eq 0 ]
    run grep -c 'draugr forge (managed)' "$HOME/.ssh/config"
    [ "$output" = 0 ]
}

@test "dr-setup --forge: writes the block and mints the key it names" {
    run dr-setup --forge
    [ "$status" -eq 0 ]
    grep -q '^Host \*\.forge$'          "$HOME/.ssh/config"
    grep -q '^Host \*\.sbx$'            "$HOME/.ssh/config"
    grep -q 'Port 18022'                "$HOME/.ssh/config"
    grep -q 'draugr-gateway.sbx socat'  "$HOME/.ssh/config"
    # An alias naming a key that does not exist fails at connect time, not at write time.
    [ -f "$HOME/.ssh/draugr_forge_ed25519" ]
    [ "$(stat -c %a "$HOME/.ssh/draugr_forge_ed25519")" = 600 ]
}

# Checked through ssh's own parser rather than by grepping the file: a block can be present
# and still not be what ssh applies, which is the failure the old per-VM script warned about
# and could not detect. THE REAL ssh, found with the mock directory stripped off PATH -
# tests/mocks/ssh answers from DR_MOCK_SSH_ALIAS and would cheerfully confirm anything.
@test "dr-setup --forge: ssh itself resolves a VM name onto the pinned port" {
    local real clean
    # The mocks directory removed from WHEREVER it sits in PATH, not just stripped off the
    # front: bats prepends its own bin, so a prefix strip silently left the mock first and the
    # test then asked the mock what ssh resolves. It answered mock-mound, which is how this
    # was caught rather than believed.
    clean=${PATH//"$DR_ROOT/tests/mocks:"/}
    real=$(PATH="$clean" command -v ssh)
    [ -n "$real" ]
    [ "$real" != "$DR_ROOT/tests/mocks/ssh" ]
    run dr-setup --forge
    [ "$status" -eq 0 ]
    run "$real" -F "$HOME/.ssh/config" -G anyvm.forge
    [ "$status" -eq 0 ]
    [[ "$output" == *"hostname host.docker.internal"* ]]
    [[ "$output" == *"port 18022"* ]]
    [[ "$output" == *"proxycommand ssh -o BatchMode=yes draugr-gateway.sbx socat"* ]]
}

# The rewrite strips managed blocks before putting them back, so "not asked for" has to mean
# "leave it alone" rather than "delete it" - otherwise one plain dr-setup silently breaks
# every forge command on the machine.
@test "dr-setup: a plain re-run does not delete the forge block" {
    run dr-setup --forge
    [ "$status" -eq 0 ]
    run dr-setup
    [ "$status" -eq 0 ]
    run grep -c '^Host \*\.forge$' "$HOME/.ssh/config"
    [ "$output" = 1 ]
}

# The gateway mound is the one value in that block, so a rewrite that forgot it would quietly
# repoint the route at a mound that is not serving the forge.
@test "dr-setup --forge-gateway: the mound name survives a later rewrite" {
    run dr-setup --forge-gateway other-mound
    [ "$status" -eq 0 ]
    grep -q 'other-mound.sbx socat' "$HOME/.ssh/config"
    run dr-setup --force
    [ "$status" -eq 0 ]
    grep -q 'other-mound.sbx socat' "$HOME/.ssh/config"
    run grep -c '^Host \*\.forge$' "$HOME/.ssh/config"
    [ "$output" = 1 ]
}

# Asking for the forge on a machine configured before the forge existed must not be answered
# with "already configured" and no block - which is what the early exit did until it learned
# about these two flags.
@test "dr-setup --forge: adds the block to an already-configured machine" {
    run dr-setup
    [ "$status" -eq 0 ]
    run dr-setup --forge
    [ "$status" -eq 0 ]
    grep -q '^Host \*\.forge$' "$HOME/.ssh/config"
}


# --- what a de-registering verb has to say for itself -----------------------
# `dr-layer adopt` ends by removing the VM block for the disk it just froze. Three messages
# were wrong about that, the first time it was run for real: the DRY RUN
# announced the de-registration in the past tense, `dr-forge status` described the resulting
# name as "unknown", and `dr-layer list` presented one root as if it were every root.

@test "live 2026-10-31: adopt's dry run does not claim a de-registration it did not make" {
    local l="$DR_ROOT/lib/forge/layer.ps1"
    # Comments stripped: the comment above the fix uses both wordings to explain itself.
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -cF 'would de-register'"
    [ "$output" = 1 ]
    # BOTH HALVES ARE PINNED, not just the presence of the words. An inverted condition reads
    # perfectly and says the wrong thing on both paths, and a grep for the sentences alone
    # cannot tell the difference - so the "would" wording is asserted to belong to the
    # dry-run branch, and the past tense to its else.
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -A1 -F 'if (\$WhatIfOnly) {' | grep -cF 'would de-register'"
    [ "$output" = 1 ]
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -B1 -F \"de-registered: AppSandbox no longer knows\" | grep -cF '} else {'"
    [ "$output" = 1 ]
}

@test "live 2026-10-31: a VM the daemon does not know is unregistered, not unknown" {
    local p="$DR_ROOT/lib/forge/probe.ps1"
    run bash -c "grep -vE '^[[:space:]]*#' '$p' | grep -cF \"Emit 'vm_state' 'unregistered'\""
    [ "$output" = 1 ]
    # IT IS ONLY CLAIMED WHEN THE LIST WAS READ. Without that guard a daemon that refused
    # every call would report the VM as de-registered, which is a different fault entirely.
    run bash -c "grep -vE '^[[:space:]]*#' '$p' | grep -F 'notcontains \$Vm'"
    [ -n "$output" ]
    # ORDER IS THE POINT: the list has to be fetched BEFORE the per-VM call, or the catch has
    # nothing to judge against. Line numbers are kept, so comment lines are dropped by value.
    local kl sl
    kl=$(grep -n 'known = @((Asb' "$p" | grep -v '^[0-9]*: *#' | head -1 | cut -d: -f1)
    sl=$(grep -n 'st = Asb' "$p" | grep -v '^[0-9]*: *#' | head -1 | cut -d: -f1)
    [ -n "$kl" ]
    [ -n "$sl" ]
    [ "$kl" -lt "$sl" ]
}

@test "live 2026-10-31: status spells out a VM that is not registered" {
    local f="$DR_ROOT/bin/dr-forge"
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F '= unregistered'"
    [ -n "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'not registered - the daemon knows no VM called'"
    [ -n "$output" ]
    # The alternatives go with it, because picking one is the next thing anyone does.
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'known: \$(dr_forge_fact vms_known'"
    [ -n "$output" ]
}

@test "live 2026-10-31: a de-registering verb says DRAUGR_FORGE now names nothing" {
    local f="$DR_ROOT/bin/dr-layer"
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'DRAUGR_FORGE still names'"
    [ -n "$output" ]
    # Gated on the verbs that actually remove a VM block - freeze only with --unregister.
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'adopt|drop) dereg=yes'"
    [ -n "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'freeze)     [ -z \"\$unregister\" ] || dereg=yes'"
    [ -n "$output" ]
    # And never after a dry run, which de-registers nothing.
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F '[ -z \"\$dry_run\" ] && [ -n \"\${DRAUGR_FORGE:-}\" ]'"
    [ -n "$output" ]
}

@test "live 2026-10-31: list admits it shows one root" {
    local l="$DR_ROOT/lib/forge/layer.ps1"
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -F 'this is one root'"
    [ -n "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -F 'dr-layer list --root <path>'"
    [ -n "$output" ]
}

# --- a host key outlives the VM it belongs to ------------------------------
# Every guest dial carries -o HostKeyAlias=draugr-<vm>, which is what stopped a second guest
# on the pinned port looking like a man in the middle. The cost is that the entry is keyed by
# a NAME, so nothing reclaims it when the VM goes - and accept-new then correctly refuses the
# next VM given that name. Measured: three stranded aliases, one of them left by
# `adopt`, which removes a VM block without deleting anything.

@test "live 2026-10-31: the host-key cleaner is one implementation, shared" {
    local h="$DR_ROOT/lib/forge/hostkey.ps1"
    [ -f "$h" ]
    # Dot-sourced by both callers rather than copied: three verbs strand the same entry, and
    # a second copy would be a third place to forget.
    run bash -c "grep -vE '^[[:space:]]*#' '$DR_ROOT/lib/forge/rm.ps1' | grep -F \"PSScriptRoot 'hostkey.ps1'\""
    [ -n "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$DR_ROOT/lib/forge/layer.ps1' | grep -F \"PSScriptRoot 'hostkey.ps1'\""
    [ -n "$output" ]
    # THE NAME IT CLEARS IS THE NAME vm.ps1 WRITES. If either spelling moved alone, the
    # cleaner would go on succeeding while clearing nothing.
    run bash -c "grep -vE '^[[:space:]]*#' '$DR_ROOT/lib/forge/vm.ps1' | grep -cF 'HostKeyAlias=draugr-\$Vm'"
    [ "$output" -ge 1 ]
    run bash -c "grep -vE '^[[:space:]]*#' '$h' | grep -F 'draugr-\$Vm'"
    [ -n "$output" ]
}

@test "live 2026-10-31: every verb that unmakes a VM clears its host key" {
    local l="$DR_ROOT/lib/forge/layer.ps1"
    run bash -c "grep -vE '^[[:space:]]*#' '$DR_ROOT/lib/forge/rm.ps1' | grep -cF 'Clear-ForgeHostKey'"
    [ "$output" = 1 ]
    # Twice in layer.ps1: adopt de-registers, drop removes.
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -cF 'Clear-ForgeHostKey'"
    [ "$output" = 2 ]
    # DROP CLEARS UNCONDITIONALLY, after the directory goes. A layer usually reaches drop with
    # no VM block at all, because adopt already removed it - so keying this off the block
    # would miss the case that was actually measured.
    local rmline clearline
    rmline=$(grep -n 'Remove-Item [$]dir -Recurse -Force' "$l" | head -1 | cut -d: -f1)
    clearline=$(grep -n 'Clear-ForgeHostKey [$]Name' "$l" | tail -1 | cut -d: -f1)
    [ -n "$rmline" ]
    [ -n "$clearline" ]
    [ "$clearline" -gt "$rmline" ]
}

@test "live 2026-10-31: the host-key cleaner survives its own native stderr" {
    local h="$DR_ROOT/lib/forge/hostkey.ps1"
    # layer.ps1 runs under Stop, and ssh-keygen reports what it removed on stderr - so a
    # SUCCESSFUL removal is what would kill the caller. docs/HACKING.md, rule 11.
    run bash -c "grep -vE '^[[:space:]]*#' '$h' | grep -F \"ErrorActionPreference = 'Continue'\""
    [ -n "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$h' | grep -F 'finally { \$ErrorActionPreference = \$eapWas }'"
    [ -n "$output" ]
    # Judged by LINE COUNT, because ssh-keygen -R exits 0 whether or not it found anything -
    # so neither its status nor its text can answer "was there one?".
    run bash -c "grep -vE '^[[:space:]]*#' '$h' | grep -F 'if (\$after -lt \$before)'"
    [ -n "$output" ]
}
