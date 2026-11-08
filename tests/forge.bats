#!/usr/bin/env bats
# dr-forge: the opt-in gate, the liveness chain, and the three verbs that reach
# into the guest.
#
# ALL TESTS HERE RUN WITHOUT WINDOWS. dr-forge reaches the Windows side only
# through powershell.exe. Tests showed this limit, and the full bridge is built
# on it. Thus tests/mocks/powershell.exe can drive all of it, also the base64
# that crosses five parsers.
#
# setup sets WSL_DISTRO_NAME, so that dr_forge_win_path has an answer on a
# machine with no Windows drive. That is not a test backdoor. dr_path_win_kit
# makes that \\wsl.localhost spelling for a checkout on the own ext4 of WSL, and
# the mock accepts each spelling of the script path. paths.bats unit-tests the
# path translation against literal strings.

load helper

setup() {
    dr_test_setup
    export WSL_DISTRO_NAME=Test
    export DRAUGR_FORGE=mock-vm
    # An ssh_config alias for the forge. Links 9 and 10 of doctor need it.
    # Without one, there is no route from WSL to the VM, so a healthy chain must
    # include it. Tests about its absence unset this.
    export DR_MOCK_SSH_ALIAS=host.docker.internal:18022
    # Outside all git repositories, so that no project configuration applies,
    # unless a test makes one.
    cd "$DR_TMP" || return 1
}

teardown() { dr_test_teardown; }

# A probe answer with one or two facts changed. If each test writes the full
# set, a test asserts facts that are not important to it.
#
# AN OVERRIDDEN KEY IS REMOVED FROM THE TEMPLATE, and not only followed by a new
# value. dr-forge reads these into an associative array, where the last value
# wins. But dr_forge_far_end_running matches a WHOLE LINE. Thus a file with both
# vm_running=yes and vm_running=no answers "yes" to it. That gave a false pass
# here. A test asserted that the VM was absent, and saw it reported as present.
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

# The fault that this guards against cost an evening. The key WAS set, in
# .draugr.conf, but dr-forge reported it as unset. Thus the reader looks at
# their own spelling, not at the trust.
@test "dr-forge: an untrusted project config is named, not reported as an empty key" {
    local repo
    repo=$(dr_make_repo forgerepo)
    printf 'DRAUGR_FORGE=from-the-conf\n' > "$repo/.draugr.conf"
    cd "$repo"
    run env -u DRAUGR_FORGE dr-forge
    [ "$status" -eq 1 ]
    [[ "$output" == *"not trusted"* ]]
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
    [[ "$output" == *"each link on the host side is healthy"* ]]
}

# REGRESSION. doctor called a working forge broken, because the scheduled task
# was registered for a layer that did not exist now. But the live supervisor
# served this VM, and the egress of the guest worked. The pin of the task is a
# registration. Only the process that holds the forwards decides whether traffic
# flows.
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
    [[ "$output" == *"need a fix"* ]]
}

# REGRESSION. A supervisor that the logon task started runs in session 0, where
# its command line reads back empty. Thus the pin is unknown, not wrong. A fail
# of link 7 for that reported a working forge as broken, while links 8, 9, and
# 10 passed in the same run. probe.ps1 falls back to the claim file. If that is
# also missing, unknown must still pass here, and the effect tests stay the last
# guard.
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
    [[ "$output" == *"nothing holds the tunnel forwards"* ]]
    [[ "$output" == *"no way out"* ]]
}

@test "dr-forge status: a second supervisor in another session is reported" {
    probe_with 'fwd_vm=mock-vm' 'tunnel_vm=mock-vm' 'tunnel_mutex=other-session'
    run dr-forge status
    [ "$status" -eq 0 ]
    [[ "$output" == *"second supervisor"* ]]
}

# The git and data loops address the VM through an ssh_config alias, because
# nothing in WSL can connect to it directly. With no alias, dr-sync fails at
# "could not resolve hostname", three links from the cause. Thus it is a counted
# link, not an advisory.
@test "dr-forge doctor: a missing ssh alias is a failing link" {
    unset DR_MOCK_SSH_ALIAS
    run dr-forge doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing resolves mock-vm.forge"* ]]
}

# "Define an ssh alias" is not an action. Before, this printed the full Host
# block for the reader to paste. Now one `Host *.forge` block serves all VMs.
# Thus the answer is a command that Draugr owns. Nothing ever maintained a
# pasted block.
@test "dr-forge doctor: a missing alias is answered with a command, not a block" {
    unset DR_MOCK_SSH_ALIAS
    run dr-forge doctor
    [[ "$output" == *"dr-setup --forge"* ]]
    # Nothing to copy by hand. The lines of the old block must be gone.
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

# A TEST SHOWED THIS, and the old advice sent the reader to the two links that
# already passed. The forward was bound and answered, but the guest refused each
# channel over it. sshd binds the permitopen of the tunnel key when the
# supervisor authenticates, and the list became wider after that. No port test
# can see that. Only the log of the supervisor can.
@test "dr-forge doctor --deep: a bound-but-dead chain points at the supervisor log" {
    export DR_MOCK_SSH_CHAIN=no
    run dr-forge doctor --deep
    [ "$status" -ne 0 ]
    [[ "$output" == *"10 WSL reaches the VM"* ]]
    [[ "$output" == *"administratively prohibited"* ]]
    [[ "$output" == *"forge-tunnel.log"* ]]
    [[ "$output" != *"check links 6 and 7"* ]]
}

# 18022 IS PINNED. Thus the alias of each VM goes to it, and the VM of the
# SUPERVISOR answers. A TEST SHOWED THIS. A doctor run for a stopped
# 'ue-427-test' reported "ok 10 WSL reaches the VM", but ran its command in
# 'test'. Link 10 is the only effect test in this direction. Thus a pass there
# certified the wrong guest.
@test "dr-forge doctor --deep: link 10 cannot pass for a VM that is not running" {
    probe_with 'vm_running=no' 'vm_state=stopped'
    run dr-forge doctor --deep
    [[ "$output" == *"10 WSL reaches the VM"* ]]
    [[ "$output" == *"does not run, so what answers on 18022 is another VM"* ]]
    # Not reported as reached, in any wording.
    [[ "$output" != *"ok   10"* ]]
}

@test "dr-forge doctor --deep: link 10 cannot pass when the forward serves another VM" {
    probe_with 'fwd_vm=some-other-vm'
    run dr-forge doctor --deep
    [[ "$output" == *"The 18022 forward serves 'some-other-vm'"* ]]
    [[ "$output" != *"ok   10"* ]]
}

# The dangerous half of the same fact. dr-sync and dr-data go through that
# alias, so they write into the other guest. Do not find a silent write to the
# wrong guest later.
@test "dr-forge doctor: a forward serving another VM warns that git and data point at it" {
    probe_with 'fwd_vm=some-other-vm'
    run dr-forge doctor --deep
    [[ "$output" == *"now serves 'some-other-vm'"* ]]
    [[ "$output" == *"WRONG VM"* ]]
    [[ "$output" == *dr-data* ]]
}

# The other half. If a link above it really failed, the general advice is still
# correct. The specific diagnosis applies only when the forward is really up.
@test "dr-forge doctor --deep: with the supervisor down, link 10 keeps the general advice" {
    export DR_MOCK_SSH_CHAIN=no
    probe_with 'port_18765=down'
    run dr-forge doctor --deep
    [ "$status" -ne 0 ]
    [[ "$output" == *"Look at links 6 and 7"* ]]
    [[ "$output" != *"administratively prohibited"* ]]
}

# Each VM on the layer stack inherits the name of the base image. Thus the guest
# calls itself layer-0, whatever vms.cfg says. Not a failure, because nothing
# breaks. But with more than one VM, the output must say it.
@test "dr-forge status --deep: a guest name that differs from the VM is reported" {
    probe_with 'guest_name=layer-0' 'fwd_vm=mock-vm' 'tunnel_vm=mock-vm' 'ssh_exec=yes' 'guest_egress=yes'
    run dr-forge status --deep
    [ "$status" -eq 0 ]
    [[ "$output" == *"layer-0"* ]]
    [[ "$output" == *"the VM is mock-vm"* ]]
}

# The advice must work with DRAUGR ALONE. Before, it said to push a script from
# the gateway project, which this repository does not ship. To follow it, you
# needed that checkout, in a specific layout, beside this one. exec and a reboot
# need neither.
@test "dr-forge doctor --deep: and says how to rename it, with Draugr commands only" {
    probe_with 'guest_name=layer-0' 'fwd_vm=mock-vm' 'tunnel_vm=mock-vm' 'ssh_exec=yes' 'guest_egress=yes'
    run dr-forge doctor --deep
    [[ "$output" == *"calls itself 'layer-0'"* ]]
    [[ "$output" == *"dr-forge exec Rename-Computer"* ]]
    [[ "$output" == *"dr-forge down"* ]]
    [[ "$output" != *set-computer-name.ps1* ]]
}

# Windows reports COMPUTERNAME in UPPER CASE (a test showed a guest that
# answered LAYER-0). Thus a renamed guest says UE-427-TEST, and a literal
# comparison complains about a name that is already correct. Advice that you
# cannot follow is worse than no advice.
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

# The encoding is the full mechanism. base64 is the one form that none of the
# five parsers between here and the guest can damage. Decoded here, not trusted.
@test "dr-forge exec: the command crosses as UTF-16LE base64" {
    run dr-forge exec Get-ChildItem 'C:\ForgeAssets'
    [ "$status" -eq 0 ]
    local b64 decoded
    b64=$(sed -n 's/.*-Encoded \([A-Za-z0-9+/=]*\).*/\1/p' "$DR_MOCK_LOG")
    [ -n "$b64" ]
    decoded=$(printf '%s' "$b64" | base64 -d | iconv -f UTF-16LE -t UTF-8)
    [[ "$decoded" == *"Get-ChildItem C:\\ForgeAssets"* ]]
}

# A command that fails must not come back as a success. `powershell
# -EncodedCommand` exits 0 for a failed cmdlet. Thus the wrapper reads both
# signals of the guest.
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

# REGRESSION of a full class: a refusal that reports success is worse than no
# test.
@test "dr-forge exec: a non-zero guest code is passed out, not flattened to 0" {
    export DR_MOCK_GUEST_RC=7
    run dr-forge exec 'exit 7'
    [ "$status" -eq 7 ]
}

# One crossing of the WSL boundary, not two. guest.ps1 finds the VM and the port
# itself.
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
    [[ "$output" == *"takes two paths"* ]]
}

@test "dr-forge push: refuses a local path that is not there" {
    run dr-forge push "$DR_TMP/absent.txt" 'C:\Users\forge\dropped.txt'
    [ "$status" -eq 1 ]
    [[ "$output" == *"nothing to push"* ]]
}

# The local side gets a new spelling for a Windows process. The guest side is
# already a Windows path, and must cross with no change. The reverse order makes
# an empty file in an unexpected place.
@test "dr-forge push: the local path is translated and the guest path is not" {
    printf 'payload\n' > "$DR_TMP/push-me.txt"
    run dr-forge push "$DR_TMP/push-me.txt" 'C:\Users\forge\dropped.txt'
    [ "$status" -eq 0 ]
    grep -qF -- '-Mode push' "$DR_MOCK_LOG"
    grep -qF -- '-Remote C:\Users\forge\dropped.txt' "$DR_MOCK_LOG"
    grep -qF -- 'push-me.txt' "$DR_MOCK_LOG"
    # Translated, so it has backslashes, not the /tmp spelling that came in.
    grep -qE -- '-Local [^ ]*\\push-me.txt' "$DR_MOCK_LOG"
}

# The local side of pull is a DESTINATION that can be absent, and dr_path_win
# resolves only real paths. Thus the parent is translated, and the basename
# appended.
@test "dr-forge pull: a destination file that does not exist yet still translates" {
    run dr-forge pull 'C:\Users\forge\out.txt' "$DR_TMP/fetched.txt"
    [ "$status" -eq 0 ]
    grep -qF -- '-Mode pull' "$DR_MOCK_LOG"
    grep -qF -- '-Remote C:\Users\forge\out.txt' "$DR_MOCK_LOG"
    grep -qE -- '-Local [^ ]*\\fetched.txt' "$DR_MOCK_LOG"
}

# REGRESSION: a RELATIVE local path came out as \\wsl.localhost\Ubuntuguest\...,
# with the distro name and the path joined, because dr_path_win_kit uses the
# leading "/" to separate them. The existence test passed anyway, so the only
# symptom was the broken path.
@test "dr-forge push: a relative local path is made absolute before translation" {
    mkdir -p "$DR_TMP/sub"
    printf 'payload\n' > "$DR_TMP/sub/relative.txt"
    cd "$DR_TMP"
    run dr-forge push sub/relative.txt 'C:\Users\forge\dropped.txt'
    [ "$status" -eq 0 ]
    # The joined form has the distro name directly followed by "sub".
    ! grep -qE -- '-Local [^ ]*wsl.localhost.[^\\]*sub' "$DR_MOCK_LOG" || return 1
    grep -qE -- '-Local [^ ]*\\sub\\relative.txt' "$DR_MOCK_LOG"
}

@test "dr-forge pull: refuses when the destination directory is missing" {
    run dr-forge pull 'C:\Users\forge\out.txt' "$DR_TMP/nosuchdir/fetched.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a directory"* ]]
}

# --- up and down ------------------------------------------------------------

# The daemon is the one link that up cannot fix, because its start needs
# elevation. Thus it must refuse, and give the command. The command must be a
# WINDOWS one, not a script from the gateway project. Draugr does not ship that,
# and must not send anybody to it.
@test "dr-forge up: a daemon that is down is reported, not started" {
    probe_with 'daemon=down'
    run dr-forge up
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs elevation"* ]]
    [[ "$output" == *"AppSandbox.exe --headless"* ]]
}

# NO COMMAND THAT DRAUGR TELLS YOU TO RUN CAN BE IN THE GATEWAY PROJECT. `up`
# owns all after the daemon, so each script that it needs ships here. A message
# that names the file of somebody else shows that this line was crossed.
@test "dr-forge up: no message sends the reader to a gateway script" {
    probe_with 'daemon=down'
    run dr-forge up
    [[ "$output" != *forge-screen* ]]
    [[ "$output" != *forge-layer* ]]
    [[ "$output" != *install-tunnel-autostart* ]]
    [[ "$output" != *vm-tunnel.ps1* ]]
}

# The same rule for doctor, with BOTH advisories: the logon task points to
# another place, and the name of the guest is different. The filenames of the
# gateway stayed longest in those two, because an advisory reads like prose, not
# like an instruction.
@test "dr-forge doctor: no advisory sends the reader to a gateway script" {
    probe_with 'guest_name=layer-0' 'tunnel_vm=some-other-vm' 'fwd_vm=mock-vm' \
        'ssh_exec=yes' 'guest_egress=yes'
    run dr-forge doctor --deep
    # Both advisories must be present. If not, this proves nothing about their
    # words.
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
    [[ "$output" == *"runs. The whole chain"* ]]
}

# The ORDER is the core of the verb. The tunnel forwards into the published port
# of the mound. Thus a tunnel that starts first has nothing at its far end, and
# the guest gets a proxy that refuses all. That looks like a policy problem, but
# it is not one.
#
# AND NO SUPERVISOR PATH IS GIVEN. It ships beside vm.ps1, which knows its
# location. Before, a given path made this step search in the gateway project.
@test "dr-forge up: the VM comes up before the tunnel, and no script path is handed over" {
    local modes
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    run dr-forge up
    [ "$status" -eq 0 ]
    modes=$(grep -oE '\-Mode [a-z]+' "$DR_MOCK_LOG" | awk '{print $2}' | tr '\n' ' ')
    [ "$modes" = "start tunnel " ]
    ! grep -q -- '-TunnelScript' "$DR_MOCK_LOG"
}

# No second configuration key for the forge. The gateway is named where Draugr
# already records "this repo needs the mound of that one to run". A refusal must
# name that key and the port that identifies the mound. If not, the reader has
# no information.
@test "dr-forge up: a mound that is down with no gateway named says where to name it" {
    probe_with 'port_18888=down'
    run dr-forge up
    [ "$status" -ne 0 ]
    [[ "$output" == *DRAUGR_REQUIRES* ]]
    [[ "$output" == *18888* ]]
}

# The tunnel is the step that fails while all above it is healthy. A forward can
# be bound and dead. Thus the output names the exit code of vm.ps1, and does not
# hide it.
@test "dr-forge up: a tunnel that will not carry fails, naming the code" {
    export DR_MOCK_VM_RC_TUNNEL=12
    run dr-forge up
    [ "$status" -ne 0 ]
    [[ "$output" == *"carries no traffic"* ]]
    [[ "$output" == *12* ]]
}

# The gateway mound is a DECLARED fact. It can be read while all is down, and it
# must be read then. The host side of the pair counts. A mound that serves 18888
# internally does not publish it.
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
    # The MOUND side, not the host side. This publishes 19999, and must not
    # match.
    DRAUGR_PORTS="127.0.0.1:19999:18888"
    ! dr_forge_publishes_proxy
}

# `up` must work from EACH directory, not only from the gateway project. Before,
# it searched there for the supervisor. Thus from all other places, it refused a
# forge that was fully healthy.
@test "dr-forge up: outside any repository, a chain already up still succeeds" {
    run dr-forge up
    [ "$status" -eq 0 ]
    [[ "$output" == *"runs. The whole chain"* ]]
}

# Code 14 now means that the supervisor is missing from lib/forge. That is a
# BROKEN INSTALL, not a configuration problem, so it must not look like one.
@test "dr-forge up: a missing supervisor is reported as a broken install" {
    export DR_MOCK_VM_RC_TUNNEL=14
    run dr-forge up
    [ "$status" -ne 0 ]
    [[ "$output" == *"installation is broken"* ]]
    [[ "$output" == *"lib/forge/tunnel.ps1"* ]]
    [[ "$output" != *DRAUGR_REQUIRES* ]]
}

# --screen is the LAST step, after the guest has a way out. A person wants a
# desktop after the rest works. Nothing comes after it, so it does not need to
# block.
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

# A viewer that does not open must not make `up` report a failure. At that time,
# all that it was ASKED for is already up. A failed command then gives a wrong
# state of the forge.
@test "dr-forge up --screen: a screen that will not open does not fail the whole command" {
    export DR_MOCK_VM_RC_SCREEN=12
    run dr-forge up --screen
    [ "$status" -eq 0 ]
    [[ "$output" == *"The forge runs"* ]]
    [[ "$output" == *"runs. The whole chain"* ]]
}

# The same step alone, so that a look at the desktop does not run the chain
# again.
@test "dr-forge screen: shows the desktop without bringing anything else up" {
    local modes
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    run dr-forge screen
    [ "$status" -eq 0 ]
    modes=$(grep -oE '\-Mode [a-z]+' "$DR_MOCK_LOG" | awk '{print $2}' | tr '\n' ' ')
    [ "$modes" = "screen " ]
}

# Here it IS the full command, so a failure is the failure of the command.
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

# --screen is a flag of up only. On a forge that is already up, the action is
# the right answer. Thus the refusal says so, and does not only refuse the word.
@test "dr-forge screen --screen: refused, and names the action instead" {
    run dr-forge screen --screen
    [ "$status" -ne 0 ]
    [[ "$output" == *"is an option of dr-forge up"* ]]
    [[ "$output" == *"dr-forge screen"* ]]
}

@test "dr-forge down --screen: refused too" {
    run dr-forge down --screen
    [ "$status" -ne 0 ]
    [[ "$output" == *"is an option of dr-forge up"* ]]
}

@test "dr-forge up: --deep is not one of its flags" {
    run dr-forge up --deep
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected argument"* ]]
}

# Both of these are a REACHED STATE, not a failure. If down exits non-zero
# because the VM was already off, no code that tests its exit code can use it.
@test "dr-forge down: a daemon that is down is success" {
    probe_with 'daemon=down'
    run dr-forge down
    [ "$status" -eq 0 ]
    [[ "$output" == *"does not run"* ]]
}

@test "dr-forge down: a VM already stopped is success" {
    probe_with 'vm_running=no' 'vm_state=stopped'
    run dr-forge down
    [ "$status" -eq 0 ]
    [[ "$output" == *already* ]]
}

# ONE call, not two. Before, `down` ran `shutdown /s /t 0` in the guest over
# ssh, and vm.ps1 only waited. The belief was that the API gave only a force
# stop. It also gives a clean ACPI power-off. Thus vm.ps1 asks the daemon for
# that itself. That also works on a guest whose sshd does not answer, where the
# ssh step failed.
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
    [[ "$output" == *"still runs"* ]]
    [[ "$output" == *11* ]]
}

# --- base and rollback: the one baseline ------------------------------------
#
# ONE BASELINE COMES FROM A BUG, not from a simplification. These tests pin the
# behavior that follows. base refuses a second snapshot, rollback goes to the
# first, and both say which one they do. docs/FORGE.md, "Backup and rollback".

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

# The refusal must explain itself. "One baseline per VM" looks like a choice,
# but it is a workaround for a bug. The message names both ways forward,
# because neither is obvious.
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

# A snapshot needs a stopped guest, so base stops it. A verb that stops a VM
# says so first, as down does.
@test "dr-forge base: says it stops the VM, and that up is how it comes back" {
    probe_with 'vm_running=yes'
    run dr-forge base
    [ "$status" -eq 0 ]
    [[ "$output" == *"shuts down first"* ]]
    [[ "$output" == *"dr-forge up"* ]]
}

# A baseline from a guest that lost power is a crash-consistent image of the
# most important disk. Code 22 is the refusal of snap.ps1 to force it.
@test "dr-forge base: a guest that will not shut down gets no baseline" {
    probe_with 'vm_running=yes'
    export DR_MOCK_SNAP_RC=22
    run dr-forge base
    [ "$status" -ne 0 ]
    [[ "$output" == *"after a power cut"* ]]
}

@test "dr-forge rollback: no baseline is refused, naming the verb that makes one" {
    probe_with
    snap_facts 'running=no' 'baseline=no' 'snapshots=0' 'current_snap=-1' 'current_branch=-1'
    run dr-forge rollback --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"no baseline"* ]]
    [[ "$output" == *"dr-forge base"* ]]
}

# The output shows what the action destroys, in the terms of the decision. It
# names the cache, because a loss of it costs an afternoon, not a minute.
@test "dr-forge rollback: shows the baseline and what goes, before asking" {
    probe_with
    snap_facts 'running=yes' 'baseline=yes' 'baseline_index=0' \
        'baseline_name=draugr-base-20261021-2100' 'branches=2' 'snapshots=1' \
        'current_snap=0' 'current_branch=1'
    run dr-forge rollback --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"draugr-base-20261021-2100"* ]]
    [[ "$output" == *"goes, and the cache too"* ]]
    [[ "$output" == *cache* ]]
}

# dr-forge never takes a second snapshot. Thus a tree with two came from
# another tool. Because of the bug, the newer one is not what its name says. A
# message is better than a silent rollback.
@test "dr-forge rollback: a second snapshot is reported rather than ignored" {
    probe_with
    snap_facts 'running=no' 'baseline=yes' 'baseline_index=0' 'baseline_name=first' \
        'branches=1' 'snapshots=2' 'current_snap=1' 'current_branch=0' 'extra_snapshots=yes'
    run dr-forge rollback --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"more than one snapshot"* ]]
    [[ "$output" == *"goes to it"* ]]
}

# 501 means that the host does not have the feature. That is a different answer
# from a failed call. On a macOS host, it is the only answer for snapshots. It
# comes from the FIRST read. That is why this is the status code, not the code
# of the action.
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

# THE ENDPOINTS COME FROM THE SOURCE, NOT A GUESS. This stops them from a return
# to a guess. `DELETE /vms/<n>` cost a failed dr-forge rm and a 405. The
# snapshot calls come from the client and the example that AppSandbox ships at
# C:\AppSandbox\headless-api\.
@test "lib/forge/snap.ps1: the snapshot endpoints are the documented ones" {
    grep -q 'Asb POST "/vms/\$Vm/snapshots" @{ name = \$Name }' "$DR_ROOT/lib/forge/snap.ps1"
    grep -q 'Asb POST "/vms/\$Vm/start" @{ snapIndex' "$DR_ROOT/lib/forge/snap.ps1"
    grep -q 'branchName = \$branch' "$DR_ROOT/lib/forge/snap.ps1"
    grep -q 'Asb DELETE "/vms/\$Vm/snapshots/\$curSnap/branches/\$curBranch"' \
        "$DR_ROOT/lib/forge/snap.ps1"
}

# THE BASELINE IS NEVER DELETED. Upstream refuses snap_delete(name, -2), because
# a delete of the base disk IS a delete of the VM. dr-forge deletes a VM through
# rm. Thus only BRANCHES are dropped here. A bare snapshot delete in this file
# is a different feature.
@test "lib/forge/snap.ps1: only branches are deleted, never the baseline" {
    local total branches
    # grep -c exits 1 on a count of zero. Under `set -e`, that ends the test,
    # and does not fail the assertion. Thus both counts ignore the exit code.
    total=$(grep -c 'Asb DELETE' "$DR_ROOT/lib/forge/snap.ps1" || true)
    branches=$(grep -c 'Asb DELETE "/vms/\$Vm/snapshots/\$curSnap/branches/' \
        "$DR_ROOT/lib/forge/snap.ps1" || true)
    [ "$total" -gt 0 ]
    [ "$total" = "$branches" ]
}

# THE API FORCES THE ORDER. It is not a choice. A BOOT from a snapshot creates a
# branch, so the new one cannot exist while the VM is stopped. A branch can be
# deleted only while it is stopped. Discard, then start, is the only order that
# works.
@test "lib/forge/snap.ps1: the old branch is discarded before the new one is started" {
    local discard branch
    discard=$(grep -n "phase=discarding" "$DR_ROOT/lib/forge/snap.ps1" | head -1 | cut -d: -f1)
    branch=$(grep -n "phase=branching" "$DR_ROOT/lib/forge/snap.ps1" | head -1 | cut -d: -f1)
    [ -n "$discard" ]
    [ -n "$branch" ]
    [ "$discard" -lt "$branch" ]
}

# The difference is on purpose. It is the full difference between the stops of
# the two verbs.
@test "lib/forge/snap.ps1: base may not pull the plug, rollback may" {
    grep -q 'Stop-Vm \$false' "$DR_ROOT/lib/forge/snap.ps1"
    grep -q 'Stop-Vm \$true' "$DR_ROOT/lib/forge/snap.ps1"
}

# @($null).Count is 1. Thus an empty tree with no filter reads as one snapshot.
# Then base refuses to take the missing baseline. The filter makes the count
# correct.
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
# These exercise lib/common.sh, not bin/dr-forge. There, the twelve commands
# that depend on dr_sandbox_exists meet the forge.

# THE CONSTRAINT, AS A TEST. Draugr must work on a machine with no AppSandbox.
# Thus the no-forge path must not even look at the Windows side. This fails if
# something calls powershell.exe.
@test "dr_sandbox_exists: with no forge configured, the Windows side is never touched" {
    dr_load_common
    export DRAUGR_FORGE=
    : > "$DR_MOCK_LOG"
    run dr_sandbox_exists some-mound
    ! grep -q '^powershell ' "$DR_MOCK_LOG" || return 1
    # And it did ask sbx, so the old path really ran, and was not skipped. The
    # sbx mock logs its bare argv, with no command name in front. Only the ssh
    # and powershell mocks add a prefix, so that calls() can tell the three
    # apart in one log.
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
    # The own refusal of each caller says "does not exist. Create it with:
    # dr-up". For a VM, both halves are wrong. Thus the real reason must be said
    # here.
    [[ "$output" == *"does not run"* ]]
    [[ "$output" == *"dr-forge up"* ]]
}

# RUNNING IS NOT ENOUGH. A test showed that `ssh -G` resolves the alias of each
# forge VM to host.docker.internal:18022, byte for byte the same. Thus the first
# hop drops the name, and the VM of the supervisor answers. A gate that passes
# only on "running" sends a dr-data push into the guest that is on that port.
@test "dr_sandbox_exists: a forge whose forward serves another VM is not a far end" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    probe_with 'fwd_vm=some-other-vm'
    run dr_sandbox_exists mock-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"serves 'some-other-vm'"* ]]
    [[ "$output" == *"A push goes into 'some-other-vm'"* ]]
}

# UNKNOWN REFUSES HERE, unlike link 7 of doctor, which takes it as a pass. Link
# 7 avoids a complaint about a forge that is fine. This gate controls file
# writes into a VM, where a wrong guess cannot be undone.
@test "dr_sandbox_exists: a pin that cannot be read refuses rather than guessing" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    probe_with 'fwd_vm=unreadable'
    run dr_sandbox_exists mock-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read which VM"* ]]
}

@test "dr_sandbox_exists: a forward serving this VM is a far end, whatever the case" {
    dr_load_common
    export DRAUGR_FORGE=mock-vm
    probe_with 'fwd_vm=MOCK-VM'
    run dr_sandbox_exists mock-vm
    [ "$status" -eq 0 ]
}

# Nothing above applies to a mound. Its route is `sbx ssh proxy %n`, so the name
# goes to the resolver. Thus "it exists" and "that is what I reach" cannot be
# different.
@test "dr_sandbox_exists: a mound is judged on its name alone, with no pin to match" {
    dr_load_common
    export DRAUGR_FORGE=
    : > "$DR_MOCK_LOG"
    run dr_sandbox_exists some-mound
    grep -q '^ls --json' "$DR_MOCK_LOG"
    ! grep -q 'fwd_vm' "$DR_MOCK_LOG"
}

# You must be able to delete lib/forge/. Without it, a configured forge reads as
# absent, and says so. It does not break the rest of Draugr.
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

# The name of the VM plus .forge is the ssh_config alias. The mound path stays
# the same. A test in the guest showed that git resolves /c/... to C:\...
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

# One host for all three callers. If dr-sync reaches the VM, but dr-data reaches
# the mound, a day can pass before somebody sees it. Thus they share this, and
# the test says so.
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
    # The two spellings must mean the same machine.
    [ "$(dr_sandbox_ssh_host)" = 'ue-427-test.forge' ]
    [ "$(dr_sandbox_url)" = 'ssh://ue-427-test.forge/c/Code/MyGame' ]
}

# --- init ------------------------------------------------------------------

# The daemon is the one step that init cannot do. Thus it must be the first
# refusal, not a failure some minutes later. It names the Windows command, never
# a gateway script.
@test "dr-forge init: no daemon is refused, naming the elevated command" {
    probe_with 'daemon=down'
    run dr-forge init
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs elevation"* ]]
    [[ "$output" == *"AppSandbox.exe --headless"* ]]
}

# The VM is named, and the WSL public key goes as a PATH. Its text has spaces,
# and an unquoted argument with a space already caused a silent failure here.
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

# Without that key, the alias resolves, and then cannot log in. That is a
# confusing place to learn it. The rest of init is still useful, so this warns,
# and does not refuse.
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
    [[ "$output" == *"is an option of dr-forge init"* ]]
}

# Each exit code of init.ps1 must give its own advice. If not, the reader gets
# only a number. 11 is the usual one: a guest that still boots, or the wrong VM.
# Hibernation and the pagefile are guest configuration. Draugr does not need
# them, so you can refuse them. But they are ON by default. A differencing child
# that grows by tens of GiB for files that nobody reads is a cost of the layer
# mechanism itself.
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

# The paths go as a FILE, one on each line. The value is Windows paths separated
# by semicolons, and they often have spaces. The route to the guest crosses four
# parsers. As an argument, --screen silently failed in vm.ps1.
@test "dr-forge init: Defender exclusions are passed as a file, not an argument" {
    export DR_MOCK_LOG="$DR_TMP/calls.log"
    export DRAUGR_FORGE_NOSCAN='C:\UE_4.27;D:\work\My Game'
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    grep -q -- '-NoScanFile' "$DR_MOCK_LOG"
    # Two paths, and the one with a space stayed one entry.
    [[ "$output" == *"exclusions to apply: 2"* ]]
}

# "*" is a different act from a narrower scan, so the output says it before the
# action.
@test "dr-forge init: NOSCAN=* warns that Defender is disabled, not narrowed" {
    export DRAUGR_FORGE_NOSCAN='*'
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    [[ "$output" == *"will be DISABLED"* ]]
    [[ "$output" == *"Not smaller: off"* ]]
    [[ "$output" != *"exclusions to apply"* ]]
}

# A "*" with paths beside it is a mistake. Name it, but do not refuse. When
# nothing is scanned, nothing is left to exclude.
@test "dr-forge init: NOSCAN=* alongside paths says the paths are moot" {
    export DRAUGR_FORGE_NOSCAN='*;C:\UE4'
    probe_with
    run dr-forge init
    [ "$status" -eq 0 ]
    [[ "$output" == *"will be DISABLED"* ]]
    [[ "$output" == *"nothing more to exclude"* ]]
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
    [[ "$output" == *"is an option of dr-forge init"* ]]
}

@test "dr-forge init: the guest never answering is explained, not numbered" {
    export DR_MOCK_INIT_RC=11
    probe_with
    run dr-forge init
    [ "$status" -ne 0 ]
    [[ "$output" == *"never answered on ssh"* ]]
    [[ "$output" == *"dr-forge screen"* ]]
}

# The same rule as the up and doctor guards: the messages of init must not send
# the reader into the directory of another project. It is the verb that replaced
# a gateway script, so it most likely names one. A TEST on the first forge built
# after rm showed this. Windows OpenSSH quotes the command that it sends again.
# Thus the remote cmd gets a double quote at the end, and `echo` prints its
# argument literally, with the junk. The name of the guest came back as `TEST"`,
# and init reported a rename that worked as a failure. `hostname` ignores the
# stray argument, so it answers cleanly. The DRAUGR_* round trips in other
# places are safe, because they MATCH a marker substring, and do not capture a
# value. Each read of a value needs this form.
@test "lib/forge/init.ps1: the post-reboot name is read with hostname, not echo" {
    grep -q 'cmd /c hostname' "$DR_ROOT/lib/forge/init.ps1"
    # CODE ONLY, not prose. `[^#]*` cannot cross the `#` of a comment. Thus the
    # paragraph in init.ps1 that explains why this form is wrong does not count
    # as a use. The first version of this test grepped the full file, and failed
    # on its own explanation.
    run grep -c '^[^#]*echo %COMPUTERNAME%' "$DR_ROOT/lib/forge/init.ps1"
    [ "$output" = 0 ]
}

# --- the desktop camera -----------------------------------------------------
#
# An agent cannot look at a screen. Thus a screenshot that it can pull back is
# the only test of something visual. Before, the capture half was only in the
# gateway project. Thus a forge built in another place had no camera, but
# docs/FORGE.md said that layer-0 had one.

@test "lib/forge/guest/install-shot.ps1: Draugr ships its own copy" {
    [ -f "$DR_ROOT/lib/forge/guest/install-shot.ps1" ]
    # The generated files must name THIS copy as their origin. A guest file that
    # pointed to the path of another project sent the last reader to the wrong
    # repository.
    run grep -c 'draugr-gateway' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    [ "$output" = 0 ]
    grep -q "Draugr made this with lib/forge/guest/install-shot.ps1" "$DR_ROOT/lib/forge/guest/install-shot.ps1"
}

# DRAUGR_CHANGED is the full reason why this is not an exact copy of the file of
# the gateway. init reports "installed" or "already installed" from it. A script
# that cannot tell those apart makes the summary lie at each new run.
@test "lib/forge/guest/install-shot.ps1: reports whether it changed anything" {
    grep -q 'DRAUGR_CHANGED=0' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    grep -q 'DRAUGR_CHANGED={0}' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    # Idempotence must be real, not only a claim. The bodies are compared before
    # the write, and the task is registered only when absent. -Force on either
    # reports a change at each run.
    grep -q 'already current' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
    grep -q 'already registered' "$DR_ROOT/lib/forge/guest/install-shot.ps1"
}

@test "lib/forge/init.ps1: installs the desktop camera, and says which it did" {
    grep -q "Invoke-GuestScript 'install-shot.ps1'" "$DR_ROOT/lib/forge/init.ps1"
    grep -q "Phase 'desktop camera'" "$DR_ROOT/lib/forge/init.ps1"
    grep -q 'already installed' "$DR_ROOT/lib/forge/init.ps1"
}

# The task runs in session 1 with an interactive principal. ssh goes to session
# 0, which has no desktop. Register it by SID, not by name. Over ssh,
# $env:USERDOMAIN is WORKGROUP. Thus "$env:USERDOMAIN\$env:USERNAME" does not
# resolve, and the registration fails with 0x80070534.
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

# A file of inspect facts, so that a test can describe the folder that rm sees.
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

# The output shows the area of the delete, in units for the decision, before the
# question.
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

# A VM whose folder holds a frozen layer does NOT get a confirmation question. A
# question about something unsafe invites a yes. --yes must not pass this
# either.
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

# An unknown VM is a typo, not a failed delete. A message that says so is better
# than a daemon error.
@test "dr-forge rm: an unknown VM says there is nothing to delete" {
    probe_with
    export DR_MOCK_RM_RC=11
    run dr-forge rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"knows no VM called"* ]]
}

# All forge VMs share one known_hosts entry, because the port is pinned. If it
# stays, the NEXT VM looks like a man-in-the-middle, not like a new machine.
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

# Nothing here rewrites a configuration file. The VM of a project is a declared
# choice, and the replacement does not exist yet. Thus it says so, and does not
# guess.
@test "dr-forge rm: warns that DRAUGR_FORGE still names the deleted VM" {
    probe_with
    run dr-forge rm --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRAUGR_FORGE still names"* ]]
}

# THE MOCK CANNOT CATCH A WRONG ENDPOINT, so this pins the tested one. The
# daemon answers DELETE /vms/<name> with 405 and no Allow header, and a
# sub-route probe with 404. Thus neither the error nor a probe shows the correct
# call. It came from the client that AppSandbox ships. This test prevents a
# second failed dr-forge rm.
@test "lib/forge/rm.ps1: deletes through POST /delete, the verb that was verified" {
    grep -q 'vms/$Vm/delete" -Method POST' "$DR_ROOT/lib/forge/rm.ps1"
    # And not the guess that got 405.
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

# --- the keys that the daemon removes at each start -------------------------
# A TEST SHOWED that AppSandbox rewrites administrators_authorized_keys when it
# starts a VM, and keeps only its own deploy key. Thus `dr-forge up` on a
# stopped VM (each VM after a host reboot) did not get in, and reported a 300 s
# timeout.

# THE ORDER IS THE FIX. A wait for the admin key before its install uses the
# full timeout on a refusal. That is exactly what happened. Line numbers,
# because nothing else can say "before". Comments are excluded, because the
# comments here quote both names.
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

# The bootstrap waits for the credential that the guest accepts, admin first.
# The first version waited only for the deploy key. That wait never ends on a VM
# built from a layer, because New-VmBlock gives those no deploy key. The cost is
# the full timeout at each start.
@test "live 2026-10-31: the bootstrap waits for any credential, admin first" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    # ANCHORED on the opening paren. Without the anchor, it matched a mutation
    # that renamed the function to Wait-GuestAnyKeyXX. That is the prefix slip
    # of rule 12 in docs/HACKING.md, again in the next test after that rule.
    grep -qE 'function Wait-GuestAnyKey\(' "$vm"
    # The list for each round tries admin before deploy. Thus a healthy guest
    # costs nothing. Both on one line, so that you can read their order.
    grep -qF "@{ Which = 'admin'; Key = \$AdminKey }, @{ Which = 'deploy'" "$vm"
    # And no caller waits only for the deploy key now.
    run bash -c "grep -vE '^[[:space:]]*#' '$vm' | grep -F \"Wait-GuestKey (Join-Path\""
    [ -z "$output" ]
    # And you can reach it alone, so that a repair of a guest needs no
    # provision run.
    grep -q "^'keys' {" "$vm"
    grep -q 'start, stop, keys, tunnel, screen' "$vm"
}

# A TIMEOUT IS A SHAPE OF FAILURE, NOT A CAUSE. The old message said timeout for
# a refused key, and sent a reader to the disk of the guest. Now the last output
# of ssh is kept and reported.
@test "live 2026-10-31: a refusal is reported as a refusal, not as a timeout" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    grep -q 'lastSshOut' "$vm"
    grep -q 'refused the key' "$vm"
    grep -q 'did not accept a connection' "$vm"
    grep -q 'said nothing at all' "$vm"
    # THE MESSAGE THAT A READER SEES, not only that the function is in the file.
    # The first version was a grep for Get-SshVerdict in all places. A mutation
    # that removed it from this message PASSED, because the definition of the
    # function still matched. A test that the fix exists does not prove that
    # something uses the fix.
    run bash -c "grep -n 'Fail 11' '$vm' | grep -vE '^[0-9]+:[[:space:]]*#'"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q 'Get-SshVerdict'
    grep -q 'Last reply:' "$vm"
}

# ONE PLACE FOR append-plus-icacls. provision had it inline, and the start path
# needed the same. guest/authorize-key.ps1 did exactly this from before both.
# Somebody saw that only after a third copy was written, and then deleted. Thus
# this asserts that the EXISTING script is used, not only that an installer
# exists.
@test "live 2026-10-31: the admin key has one installer, and provision delegates to it" {
    local ak="$DR_ROOT/lib/forge/guest/authorize-key.ps1"
    [ -f "$ak" ]
    grep -q 'administrators_authorized_keys' "$ak"
    grep -q 'S-1-5-32-544' "$ak"
    # vm.ps1 uses it, and does not keep its own.
    grep -q "Script = 'authorize-key.ps1'" "$DR_ROOT/lib/forge/vm.ps1"
    [ ! -f "$DR_ROOT/lib/forge/guest/install-admin-key.ps1" ]
    # provision does not build that file itself now: no Add-Content to it
    # outside a comment.
    run bash -c "grep -n 'administrators_authorized_keys' '$DR_ROOT/lib/forge/provision.ps1' |
                 grep -vE '^[0-9]+:[[:space:]]*#' | grep -E 'Add-Content|New-Item|icacls'"
    [ -z "$output" ]
    grep -q "vm.ps1') -Mode keys" "$DR_ROOT/lib/forge/provision.ps1"
}

# sshd ignores a half-written key, and an ignored line looks exactly like a key
# that was never installed. Thus the shape is tested before the append.
@test "live 2026-10-31: the admin key installer refuses something that is not a key" {
    local ak="$DR_ROOT/lib/forge/guest/authorize-key.ps1"
    grep -q 'does not look like a public key' "$ak"
    grep -q 'exit 1' "$ak"
}

# The supervisor tries again on its own clock. Thus the tunnel path must also
# make sure of the key. The log of the supervisor showed a reconnect in the gap
# between a VM start and the key install, and a refusal. AFTER the early exit,
# because a tunnel that carries needs none of it. BEFORE the start or reset of
# the supervisor, because both need the key.
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

# --- the lifecycle of the daemon as a command ------------------------------
# layer.ps1 printed six lines to paste into an elevated PowerShell, and a
# seventh to undo it. The request was one command. Also, the elevation was
# wrong. The headless API controls the RUN of the daemon, not calls to it. Thus
# only the --headless relaunch needs a prompt.

@test "live 2026-10-31: the daemon script has the four modes and refuses others" {
    local d="$DR_ROOT/lib/forge/daemon.ps1"
    [ -f "$d" ]
    grep -qF "validModes = @('status', 'stop', 'start', 'restart')" "$d"
    grep -qF 'Fail 2 "unknown -Mode' "$d"
}

# THE POSITION IS THE PURPOSE. This verb must work when AppSandbox is DOWN. That
# is its main use. At that time, each action below dr_forge_probe already died
# on a Windows side that did not answer. Line numbers, because "above" is the
# full claim.
@test "live 2026-10-31: the daemon verb is handled before anything probes" {
    local f="$DR_ROOT/bin/dr-forge"
    local verb_at probe_at
    verb_at=$(grep -nF '[ "$action" = daemon ]' "$f" |
              grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    # Found by the ARGUMENTS of the gate call, not by an `if !` prefix. The
    # probe is conditional now (it does not gate `gateway`). The other two
    # dr_forge_probe calls in this file give neither "$deep" nor both arguments.
    probe_at=$(grep -nF 'dr_forge_probe "$vm" "$deep"' "$f" |
               grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    [ -n "$verb_at" ]
    [ -n "$probe_at" ]
    [ "$verb_at" -lt "$probe_at" ]
}

# AND IT DOES NOT GATE `gateway` EITHER, for the same reason. That verb writes a
# directory, and starts nothing. Thus it must work while nothing can reach the
# Windows side. A checkout outside /mnt is that case. There, probe.ps1 has no
# Windows spelling, unless WSL_DISTRO_NAME is set. Thus the probe died with
# "cannot work out a Windows spelling" before the generator ran. It broke 24 of
# the 25 tests of forge-gateway.bats at each CI run, but passed on each machine
# with WSL. That is why the assertion is on the SOURCE. No test run here can see
# a gate that the environment of this machine satisfies.
@test "the probe does not gate gateway, which touches nothing over there" {
    local f="$DR_ROOT/bin/dr-forge"
    local line
    line=$(grep -nF 'dr_forge_probe "$vm" "$deep"' "$f" |
           grep -vE '^[0-9]+:[[:space:]]*#' | head -1)
    [ -n "$line" ]
    [[ "$line" == *'"$action" != gateway'* ]]
}

# Nobody finds a verb that is absent from the usage header or the README.
@test "live 2026-10-31: the daemon verb is documented where the others are" {
    grep -qF 'dr-forge daemon <verb>' "$DR_ROOT/bin/dr-forge"
    grep -qF 'dr-forge daemon <verb>' "$DR_ROOT/README.md"
    # And the refusal lists it. If not, the code accepts what the help denies.
    grep -qF 'pull, gateway, daemon' "$DR_ROOT/bin/dr-forge"
}

# FORCE IS NOT OFFERED. That is a decision, not an omission. {"force":true}
# terminates the guests, and a terminated guest is a dirty disk. The verbs that
# this serves are the ones that freeze disks.
@test "live 2026-10-31: the daemon stop never forces a running guest" {
    local d="$DR_ROOT/lib/forge/daemon.ps1"
    # THE JSON KEY, not the word. The first version was a grep for "force" in
    # all places outside a comment. It matched the refusal message that EXPLAINS
    # why force is not offered. It also matches a legitimate -Force on an
    # unrelated cmdlet. What must never appear is the own `{"force":true}` of
    # the API, which terminates a guest. Comments are ALSO removed, because the
    # header comment quotes `{"force":true}` to say that it is never sent. Rule
    # 12 in docs/HACKING.md, broken in the next test after it.
    run bash -c "grep -vE '^[[:space:]]*#' '$d' | grep -F '\"force\"'"
    [ -z "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$d' | grep -F 'force='"
    [ -z "$output" ]
    # It shuts each VM down cleanly and WAITS. That makes force unnecessary.
    grep -qF '/shutdown' "$d"
    grep -qF 'still ran after' "$d"
}

# layer.ps1 points to the command, and does not repeat it.
@test "live 2026-10-31: layer.ps1 no longer prints a recipe to paste" {
    local l="$DR_ROOT/lib/forge/layer.ps1"
    grep -qF 'dr-forge daemon stop' "$l"
    grep -qF 'dr-forge daemon start' "$l"
    # The six lines are gone from the code. Comments are removed, because the
    # comment that replaced them explains what they were.
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -F 'Invoke-RestMethod -Method Post'"
    [ -z "$output" ]
}

# --- a supervisor is not the same thing as a bound port --------------------
# Get-ForwardOwner started at the port, and returned $null if nothing held it.
# Thus a supervisor BETWEEN RECONNECTS was invisible: ssh exited, and the next
# attempt was up to ten seconds away. vm.ps1 started a second one. It read the
# same claim, stopped, and the caller reported "the forward never carried". A
# live test reproduced it with the end of the ssh child.

@test "live 2026-10-31: a supervisor holding no port is seen, not ignored" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    # ANCHORED on the full declaration. Without the anchor, this matched a
    # mutation that renamed the function to Get-SupervisorClaimXX, because the
    # old name is a prefix of the new one.
    grep -qE 'function Get-SupervisorClaim[[:space:]]*\{' "$vm"
    # "Carries" and "exists" are now separate answers, so that a caller can tell
    # them apart.
    grep -qF 'Bound = $false' "$vm"
    grep -qF 'Bound = $true' "$vm"
    # A recycled pid looks like a live supervisor, and can stop the real one.
    # Thus the process must be present AND be a PowerShell. That is the own
    # guard of tunnel.ps1. -e, because the pattern starts with a dash, and grep
    # reads that as an option.
    grep -qF -e '-notcontains $p.ProcessName' "$vm"
}

# A kill of an ssh child is useful only if one EXISTS. The bound-but-dead path
# depends on Bound. That keeps the new state out of it.
@test "live 2026-10-31: the two not-carrying states are told apart" {
    local vm="$DR_ROOT/lib/forge/vm.ps1"
    grep -qF 'if ($own -and $own.Bound) {' "$vm"
    grep -qF 'between reconnects' "$vm"
}

# THE PURPOSE OF THE FULL FIX: the wait branch must end in its own verdict, and
# never fall through to the start of a rival. Line numbers, because "never
# reaches" is a claim about order.
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
    # And the verdict NAMES THE PID. That is the full difference from the old
    # message. "the forward never carried" sent a reader to the guest. This
    # sends them to a process.
    grep -qF 'SupervisorPid)) did not bring the forward' "$vm"
}

# probe had the same gate, so doctor also was not able to report this state. The
# claim is printed ABOVE the port lookup. Only that way does it stay with no
# port holder.
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

# A wait is not a break, but doctor once called it one.
@test "live 2026-10-31: doctor calls a wait a wait" {
    local df="$DR_ROOT/bin/dr-forge" code
    # COMMENTS REMOVED. The comment that explains this change also says
    # "between reconnects". Thus a grep of the full file passed on a file whose
    # real message a mutation removed. That is the fifth time in this project
    # that the own prose of a fix passed the test of the fix. See
    # docs/HACKING.md.
    code=$(grep -vE '^[[:space:]]*#' "$df")
    printf '%s\n' "$code" | grep -qF 'between reconnects'
    printf '%s\n' "$code" | grep -qF 'sup_vm'
    # The warning is still there for the case where nothing claims the
    # forwards.
    printf '%s\n' "$code" | grep -qF 'nothing holds the tunnel forwards'
}

# --- the host key belongs to the VM, not to the port -----------------------
# A TEST SHOWED THIS. Through the pinned 18022, ssh gave rc=255 and "REMOTE HOST
# IDENTIFICATION HAS CHANGED", because that address served a previous guest. The
# same guest on its relay port gave rc=0. accept-new correctly accepts an
# UNKNOWN host, and refuses a CHANGED one. Thus each test through the forward
# reported a dead far end, but it was fine. `dr-forge up` used 300 s to say so.

# EACH connection, not only the one that failed. Both addresses of Draugr are
# shared. 18022 is pinned by design, and the daemon can give the relay port
# again.
@test "live 2026-10-31: every guest dial keys its host key to the VM" {
    local f bad=''
    for f in "$DR_ROOT"/lib/forge/*.ps1 "$DR_ROOT"/lib/forge/common.sh; do
        # Each file that connects must have the alias. For each file, not for
        # each line. The calls wrap across backtick and backslash continuations.
        # A correct join of those is too much work for this question.
        #
        # COMMENTS REMOVED. The first version did not remove them. Some of these
        # files explain the alias in a comment ABOVE the option. Thus a grep of
        # the full file passed on a file whose real option was deleted. A
        # mutation caught it. That was the fourth time in this project that the
        # own prose of a fix passed the test of the fix.
        local dials aliases
        dials=$(grep -vE '^[[:space:]]*#' "$f" | grep -c 'StrictHostKeyChecking' || true)
        aliases=$(grep -vE '^[[:space:]]*#' "$f" | grep -c 'HostKeyAlias' || true)
        if [ "$dials" -gt 0 ] && [ "$aliases" -eq 0 ]; then
            bad="$bad $(basename "$f")"
        fi
    done
    [ -z "$bad" ] || { echo "no HostKeyAlias in:$bad"; return 1; }
}

# THE COUNTS MUST MATCH. That catches a NEW call site with no alias. The test
# for each file above does not, because the file already has one in another
# place. Comments are excluded, because the explanations name both options.
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

# The alias names the VM, so two guests never share an entry. A constant is the
# same bug again, with extra steps.
@test "live 2026-10-31: the alias is per-VM, not a constant" {
    # `draugr-[$]`, not `draugr-\$[Vv]m`. In a double-quoted bash -c, `$[` is
    # the DEPRECATED arithmetic expansion of bash. Thus bash evaluated that
    # pattern, and did not match it, and it excluded nothing. A character class
    # keeps the dollar literal. With the pipeline here, no nested quotes are
    # necessary.
    local bad
    bad=$(grep -h 'HostKeyAlias' "$DR_ROOT"/lib/forge/*.ps1 "$DR_ROOT"/lib/forge/common.sh |
          grep -vE '^[[:space:]]*#' | grep -v 'draugr-[$]' || true)
    [ -z "$bad" ] || { echo "not keyed on the VM:$bad"; return 1; }
}

# --- the Host *.forge block ------------------------------------------------

# The suffix is in lib/common.sh AND lib/forge/common.sh, because no core script
# can source the forge library. Only this test keeps the two the same. If they
# drift apart, dr-sync uses a name that nothing resolves.
@test "the .forge suffix is spelled the same in core and in the forge library" {
    dr_load_common
    # shellcheck source=../lib/forge/common.sh
    . "$DR_ROOT/lib/forge/common.sh"
    export DRAUGR_FORGE=somevm
    export DRAUGR_SANDBOX=somevm
    [ "$(dr_sandbox_ssh_host)" = "$(dr_forge_alias_host somevm)" ]
}

# Optional by design, for each file. A machine whose owner never asked for a
# forge must not get a block that mentions one.
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
    # An alias that names a missing key fails at connect time, not at write
    # time.
    [ -f "$HOME/.ssh/draugr_forge_ed25519" ]
    [ "$(stat -c %a "$HOME/.ssh/draugr_forge_ed25519")" = 600 ]
}

# Tested through the own parser of ssh, not with a grep of the file. A block can
# be present, but ssh applies something else. The old script for each VM warned
# about that failure, but was not able to detect it. THE REAL ssh, found with
# the mock directory removed from PATH. tests/mocks/ssh answers from
# DR_MOCK_SSH_ALIAS, and confirms all.
@test "dr-setup --forge: ssh itself resolves a VM name onto the pinned port" {
    local real clean
    # The mocks directory is removed from ITS PLACE in PATH, not only from the
    # front. bats puts its own bin first. Thus a removal of the prefix silently
    # left the mock first. The test then asked the mock what ssh resolves. It
    # answered mock-mound. That is how somebody caught it, and did not believe
    # it.
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

# The rewrite removes managed blocks before it puts them back. Thus "not asked
# for" must mean "do not touch it", not "delete it". If not, one plain dr-setup
# silently breaks each forge command on the machine.
@test "dr-setup: a plain re-run does not delete the forge block" {
    run dr-setup --forge
    [ "$status" -eq 0 ]
    run dr-setup
    [ "$status" -eq 0 ]
    run grep -c '^Host \*\.forge$' "$HOME/.ssh/config"
    [ "$output" = 1 ]
}

# The gateway mound is the one value in that block. A rewrite that forgets it
# silently points the route to a mound that does not serve the forge.
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

# A request for the forge on a machine configured before the forge existed must
# not get "already configured" and no block. The early exit did that, until it
# learned about these two flags.
@test "dr-setup --forge: adds the block to an already-configured machine" {
    run dr-setup
    [ "$status" -eq 0 ]
    run dr-setup --forge
    [ "$status" -eq 0 ]
    grep -q '^Host \*\.forge$' "$HOME/.ssh/config"
}


# --- what a verb that de-registers must say ---------------------------------
# At its end, `dr-layer adopt` removes the VM block for the disk that it just
# froze. At the first real run, three messages were wrong about that. The DRY
# RUN told the de-registration in the past tense. `dr-forge status` described
# the new name as "unknown". `dr-layer list` showed one root as if it were all
# roots.

@test "live 2026-10-31: adopt's dry run does not claim a de-registration it did not make" {
    local l="$DR_ROOT/lib/forge/layer.ps1"
    # Comments removed. The comment above the fix uses both wordings to explain
    # itself.
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -cF 'would remove the registration of'"
    [ "$output" = 1 ]
    # BOTH HALVES ARE PINNED, not only the presence of the words. An inverted
    # condition reads correctly, and says the wrong thing on both paths. A grep
    # for only the sentences cannot tell the difference. Thus the test asserts
    # that the "would" wording is in the dry-run branch, and the past tense in
    # its else.
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -A1 -F 'if (\$WhatIfOnly) {' | grep -cF 'would remove the registration of'"
    [ "$output" = 1 ]
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -B1 -F \"has no registration now: AppSandbox no longer knows\" | grep -cF '} else {'"
    [ "$output" = 1 ]
}

@test "live 2026-10-31: a VM the daemon does not know is unregistered, not unknown" {
    local p="$DR_ROOT/lib/forge/probe.ps1"
    run bash -c "grep -vE '^[[:space:]]*#' '$p' | grep -cF \"Emit 'vm_state' 'unregistered'\""
    [ "$output" = 1 ]
    # IT IS CLAIMED ONLY AFTER A READ OF THE LIST. Without that guard, a daemon
    # that refuses each call reports the VM as de-registered. That is a very
    # different fault.
    run bash -c "grep -vE '^[[:space:]]*#' '$p' | grep -F 'notcontains \$Vm'"
    [ -n "$output" ]
    # ORDER IS THE PURPOSE. The list must come BEFORE the call for each VM. If
    # not, the catch has nothing to compare with. Line numbers stay, so comment
    # lines are dropped by value.
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
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'not registered. The daemon knows no VM called'"
    [ -n "$output" ]
    # The alternatives go with it, because the next step of each person is to
    # pick one.
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'known: \$(dr_forge_fact vms_known'"
    [ -n "$output" ]
}

@test "live 2026-10-31: a de-registering verb says DRAUGR_FORGE now names nothing" {
    local f="$DR_ROOT/bin/dr-layer"
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'DRAUGR_FORGE still names'"
    [ -n "$output" ]
    # Only for the verbs that really remove a VM block: freeze only with
    # --unregister.
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'adopt|drop) dereg=yes'"
    [ -n "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -F 'freeze)     [ -z \"\$unregister\" ] || dereg=yes'"
    [ -n "$output" ]
    # And never after a dry run, because that de-registers nothing.
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

# --- a host key stays after its VM ------------------------------------------
# Each guest connection has -o HostKeyAlias=draugr-<vm>. That stopped a second
# guest on the pinned port from looking like a man in the middle. The cost: the
# key of the entry is a NAME, so nothing removes it when the VM goes. Then
# accept-new correctly refuses the next VM with that name. A test found three
# old aliases. `adopt` left one, because it removes a VM block, and deletes
# nothing.

@test "live 2026-10-31: the host-key cleaner is one implementation, shared" {
    local h="$DR_ROOT/lib/forge/hostkey.ps1"
    [ -f "$h" ]
    # Both callers dot-source it, and do not copy it. Three verbs leave the
    # same entry, and a second copy is a third place to forget.
    run bash -c "grep -vE '^[[:space:]]*#' '$DR_ROOT/lib/forge/rm.ps1' | grep -F \"PSScriptRoot 'hostkey.ps1'\""
    [ -n "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$DR_ROOT/lib/forge/layer.ps1' | grep -F \"PSScriptRoot 'hostkey.ps1'\""
    [ -n "$output" ]
    # IT CLEARS THE NAME THAT vm.ps1 WRITES. If only one spelling changes, the
    # cleaner continues to succeed, but clears nothing.
    run bash -c "grep -vE '^[[:space:]]*#' '$DR_ROOT/lib/forge/vm.ps1' | grep -cF 'HostKeyAlias=draugr-\$Vm'"
    [ "$output" -ge 1 ]
    run bash -c "grep -vE '^[[:space:]]*#' '$h' | grep -F 'draugr-\$Vm'"
    [ -n "$output" ]
}

@test "live 2026-10-31: every verb that unmakes a VM clears its host key" {
    local l="$DR_ROOT/lib/forge/layer.ps1"
    run bash -c "grep -vE '^[[:space:]]*#' '$DR_ROOT/lib/forge/rm.ps1' | grep -cF 'Clear-ForgeHostKey'"
    [ "$output" = 1 ]
    # Twice in layer.ps1: adopt de-registers, and drop removes.
    run bash -c "grep -vE '^[[:space:]]*#' '$l' | grep -cF 'Clear-ForgeHostKey'"
    [ "$output" = 2 ]
    # DROP ALWAYS CLEARS, after the directory goes. A layer usually comes to
    # drop with no VM block, because adopt already removed it. Thus a dependency
    # on the block misses the case of the real test.
    local rmline clearline
    rmline=$(grep -n 'Remove-Item [$]dir -Recurse -Force' "$l" | head -1 | cut -d: -f1)
    clearline=$(grep -n 'Clear-ForgeHostKey [$]Name' "$l" | tail -1 | cut -d: -f1)
    [ -n "$rmline" ]
    [ -n "$clearline" ]
    [ "$clearline" -gt "$rmline" ]
}

@test "live 2026-10-31: the host-key cleaner survives its own native stderr" {
    local h="$DR_ROOT/lib/forge/hostkey.ps1"
    # layer.ps1 runs under Stop, and ssh-keygen reports on stderr what it
    # removed. Thus a SUCCESSFUL removal kills the caller. docs/HACKING.md,
    # rule 11.
    run bash -c "grep -vE '^[[:space:]]*#' '$h' | grep -F \"ErrorActionPreference = 'Continue'\""
    [ -n "$output" ]
    run bash -c "grep -vE '^[[:space:]]*#' '$h' | grep -F 'finally { \$ErrorActionPreference = \$eapWas }'"
    [ -n "$output" ]
    # Judged by LINE COUNT, because ssh-keygen -R always exits 0, also when it
    # finds nothing. Thus neither its status nor its text can answer "was there
    # one?".
    run bash -c "grep -vE '^[[:space:]]*#' '$h' | grep -F 'if (\$after -lt \$before)'"
    [ -n "$output" ]
}
