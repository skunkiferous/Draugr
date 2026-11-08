#!/usr/bin/env bats
# dr-layer: the front end for the disk layers of the forge. docs/FORGE.md, "The
# layer mechanism as a command".
#
# WHAT IS TESTED HERE, AND WHAT CANNOT BE. lib/forge/layer.ps1 edits vms.cfg,
# and controls the VHD cmdlets. Neither exists without Windows, and a mock only
# pretends to do both. Thus this file tests the bash half: the verbs, the flags,
# the PowerShell parameter for each, and what dr-layer does with the codes that
# come back. The PowerShell half is the tested forge-layer.ps1 of the gateway.
# It was adopted, not rewritten. A run of it tests it (its `list` is read-only).
#
# THE OPPOSITE GATE IS THE PURPOSE OF THE FIRST TEST. Each other forge command
# does nothing unless DRAUGR_FORGE names a VM. dr-layer cannot work so. It
# CREATES what that key names.

load helper

setup() {
    dr_test_setup
    export WSL_DISTRO_NAME=Test
    # NOT set, on purpose. dr-layer must work without it. A test that needs it
    # says so.
    unset DRAUGR_FORGE || :
    cd "$DR_TMP" || return 1
}

teardown() { dr_test_teardown; }

# The argv that the mock recorded. Each "what did it send" assertion uses it.
sent() { grep '^powershell ' "$DR_MOCK_LOG" | tail -1; }

# --- the gate, which is the opposite of the gate of dr-forge -----------------------------

@test "dr-layer: works with no forge configured, unlike every other forge verb" {
    run dr-layer list
    [ "$status" -eq 0 ]
    [[ "$output" != *"no forge is configured"* ]]
}

@test "dr-layer: list is the default action" {
    run dr-layer
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *"-Mode list"* ]]
}

# --- the verbs -----------------------------------------------------------------------------

@test "dr-layer: the name is passed as -Name and the verb as -Mode" {
    run dr-layer freeze layer-1
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *"-Mode freeze"* ]]
    [[ "$(sent)" == *"-Name layer-1"* ]]
}

@test "dr-layer: an unknown verb is refused and names the real ones" {
    run dr-layer frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown action: frobnicate"* ]]
    [[ "$output" == *"list, adopt, new, freeze, thaw, drop"* ]]
}

# Each verb that the help lists must dispatch. An "unknown action" for a verb
# that the docs promise sends somebody to search for their own typo. provision
# was a refusal until stage two arrived, so it is the one to name here.
@test "dr-layer: every verb in the help is dispatched, provision included" {
    local v
    for v in list adopt new freeze thaw drop provision; do
        run dr-layer "$v" x --parent y
        [[ "$output" != *"unknown action"* ]]
    done
}

@test "dr-layer: every verb but list needs a name" {
    local v
    for v in adopt new freeze thaw drop; do
        run dr-layer "$v"
        [ "$status" -eq 1 ]
        [[ "$output" == *"needs the name of a layer"* ]] || [[ "$output" == *"--parent"* ]]
    done
}

@test "dr-layer: two names are refused rather than one being ignored" {
    run dr-layer freeze layer-1 layer-2
    [ "$status" -eq 1 ]
    [[ "$output" == *"one layer name"* ]]
}

# --- new, whose parent has no default ------------------------------------------------------

# Caught in bash, before something crosses to Windows. With the daemon up,
# layer.ps1 answers "AppSandbox is running" to a command that cannot work
# anyway.
@test "dr-layer new: --parent is required, and the answer comes from here" {
    run dr-layer new layer-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs --parent"* ]]
    [ ! -s "$DR_MOCK_LOG" ] || ! grep -q 'layer.ps1' "$DR_MOCK_LOG"
}

@test "dr-layer new: parent and size become -Parent and -DiskGb" {
    run dr-layer new layer-3 --parent layer-2 --disk-gb 768
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *"-Parent layer-2"* ]]
    [[ "$(sent)" == *"-DiskGb 768"* ]]
}

# A size that is not a number arrives as 0, and reads as "inherit the capacity
# of the parent". That is a silent wrong answer where a refusal belongs.
@test "dr-layer new: a non-numeric size is refused, not passed as zero" {
    run dr-layer new layer-3 --parent layer-2 --disk-gb big
    [ "$status" -eq 1 ]
    [[ "$output" == *"number of gigabytes"* ]]
}

@test "dr-layer: a non-numeric ssh port is refused" {
    run dr-layer thaw layer-1 --ssh-port http
    [ "$status" -eq 1 ]
    [[ "$output" == *"port number"* ]]
}

# --- the flags, each belonging to one verb -------------------------------------------------

# layer.ps1 accepts all of them, and uses each where it has a meaning. Thus it
# silently takes a flag on the wrong verb. `drop x --force` reads as "I forced
# it", but forces nothing.
@test "dr-layer: a flag aimed at the wrong verb is refused" {
    run dr-layer drop layer-1 --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"--force is an option of dr-layer thaw"* ]]

    run dr-layer freeze layer-1 --no-register
    [ "$status" -eq 1 ]
    [[ "$output" == *"--no-register is an option of dr-layer thaw"* ]]

    run dr-layer adopt layer-0 --parent layer-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"--parent is an option of dr-layer new"* ]]

    run dr-layer list --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"--dry-run is an option"* ]]
}

@test "dr-layer: each flag becomes its PowerShell switch" {
    run dr-layer freeze layer-1 --unregister
    [[ "$(sent)" == *"-Unregister"* ]]
    run dr-layer thaw layer-1 --no-register --force
    [[ "$(sent)" == *"-NoRegister"* ]]
    [[ "$(sent)" == *"-Force"* ]]
    run dr-layer new layer-2 --parent layer-1 --keep-registered
    [[ "$(sent)" == *"-KeepRegistered"* ]]
    run dr-layer adopt layer-0 --keep-vm-folder
    [[ "$(sent)" == *"-KeepVmFolder"* ]]
    run dr-layer drop layer-3 --dry-run
    [[ "$(sent)" == *"-WhatIfOnly"* ]]
}

# --- where layers live ---------------------------------------------------------------------

# An unset key must give NO -Root. layer.ps1 reports a default differently from
# a choice. An argument C:\ForgeLayers makes it call the default a decision of
# somebody. That happens twice, because its elevation relaunch forwards what it
# got.
@test "dr-layer: with no root configured, -Root is not passed" {
    run dr-layer list
    [ "$status" -eq 0 ]
    [[ "$(sent)" != *"-Root"* ]]
}

@test "dr-layer: DRAUGR_FORGE_LAYERS becomes -Root" {
    DRAUGR_FORGE_LAYERS='D:\ForgeLayers' run dr-layer list
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *'-Root D:\ForgeLayers'* ]]
}

@test "dr-layer: --root wins over the key" {
    DRAUGR_FORGE_LAYERS='D:\ForgeLayers' run dr-layer list --root 'E:\Other'
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *'-Root E:\Other'* ]]
    [[ "$(sent)" != *'D:\ForgeLayers'* ]]
}

@test "dr-layer: --root with no path is refused" {
    run dr-layer list --root
    [ "$status" -eq 1 ]
    [[ "$output" == *"--root needs a path"* ]]
}

# --- the codes layer.ps1 documents ---------------------------------------------------------

# A REFUSAL IS NOT A FAILURE, and a front end tells them apart by the codes. 3
# means that the daemon is up. 20 means that a guard did its job. Both pass on
# with no change, with a line that says which. Most of all 20, because a guard
# that stopped a drop must not look like a bug.
@test "dr-layer: the daemon being up is relayed as 3, and said out loud" {
    DR_MOCK_LAYER_RC=3 run dr-layer freeze layer-1
    [ "$status" -eq 3 ]
    [[ "$output" == *"AppSandbox runs"* ]]
}

@test "dr-layer: a guard refusing is relayed as 20, and nothing claims success" {
    DR_MOCK_LAYER_RC=20 run dr-layer drop layer-1
    [ "$status" -eq 20 ]
    [[ "$output" == *"a guard refused"* ]]
    [[ "$output" == *"Nothing changed"* ]]
}

@test "dr-layer: an absence is relayed as 21" {
    DR_MOCK_LAYER_RC=21 run dr-layer freeze nosuchlayer
    [ "$status" -eq 21 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "dr-layer: a declined UAC prompt is relayed as 24" {
    DR_MOCK_LAYER_RC=24 run dr-layer new layer-2 --parent layer-1
    [ "$status" -eq 24 ]
    [[ "$output" == *"elevation was refused"* ]]
}

# The output must stay, whatever the code. A refusal explains itself in the own
# words of the PowerShell. Without them, only the one-line summary is left.
@test "dr-layer: the script's output is relayed even when it refuses" {
    DR_MOCK_LAYER_RC=20 run dr-layer drop layer-1
    [[ "$output" == *"mock layer.ps1: drop"* ]]
}

# --- the help, the only documentation at the terminal ------------------------------------

@test "dr-layer --help: names the verbs and the elevation trap" {
    run dr-layer --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"dr-layer new"* ]]
    [[ "$output" == *"DO NOT RUN THIS FROM AN ELEVATED SHELL"* ]]
}

# --- provision, with the vocabulary of a different verb -----------------------------------

# Before, it refused with "not built yet". A test that it does not do that now
# is the cheapest guard against half-done wiring. A verb that reaches the wrong
# script still exits 0.
@test "dr-layer provision: reaches provision.ps1, not layer.ps1" {
    run dr-layer provision base --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *"provision.ps1"* ]]
    [[ "$(sent)" != *"layer.ps1"* ]]
    [[ "$(sent)" == *"-Vm base"* ]]
}

# -Mode belongs to layer.ps1, and provision has none. A stray -Mode is a
# parameter that it does not declare, and PowerShell refuses it by name.
@test "dr-layer provision: sends no -Mode" {
    run dr-layer provision base --skip-gateway
    [[ "$(sent)" != *"-Mode"* ]]
}

@test "dr-layer provision: the ISO becomes a Windows path" {
    run dr-layer provision base --iso /mnt/d/iso/Win11.iso --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *'-IsoPath D:\iso\Win11.iso'* ]]
}

@test "dr-layer provision: the sizing flags map one for one" {
    run dr-layer provision base --ram 16384 --cores 12 --disk-gb 768 --gpu-mode 1 --skip-gateway
    [[ "$(sent)" == *"-Ram 16384"* ]]
    [[ "$(sent)" == *"-Cores 12"* ]]
    [[ "$(sent)" == *"-DiskGb 768"* ]]
    [[ "$(sent)" == *"-GpuMode 1"* ]]
}

@test "dr-layer provision: --verify-only, --harden-sshd and -y map to their switches" {
    run dr-layer provision base --verify-only
    [[ "$(sent)" == *"-VerifyOnly"* ]]
    run dr-layer provision base --harden-sshd -y --skip-gateway
    [[ "$(sent)" == *"-HardenSshd"* ]]
    [[ "$(sent)" == *"-Yes"* ]]
}

# An EMPTY --timezone means "do not touch the clock of the guest". That is a
# real answer, so it must be forwarded, not taken as absent. If not, the guest
# inherits the unattended default of Windows, Pacific, in each layer built on
# it.
@test "dr-layer provision: an empty --timezone is still forwarded" {
    run dr-layer provision base --timezone '' --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *"-TimeZone"* ]]
}

# ALL FOURTEEN AT ONCE. That is the purpose. The mapping is a case statement,
# and in a case statement, one phase can silently fall through to nothing. For
# the caller, a -Skip that never arrives reads as "I turned that off", but the
# phase runs anyway. For the components, that is an hour of installs.
@test "dr-layer provision: each --skip-X becomes its switch" {
    run dr-layer provision base --skip-guest-base --skip-online --skip-tunnel-key \
        --skip-gateway --skip-tunnel --skip-msys2 --skip-tools --skip-automation \
        --skip-shot --skip-screen --skip-vault --skip-vscode \
        --skip-cleanup --skip-manifest
    [ "$status" -eq 0 ]
    local sentline
    sentline=$(sent)
    [[ "$sentline" == *"-SkipGuestBase"* ]]
    [[ "$sentline" == *"-SkipOnline"* ]]
    [[ "$sentline" == *"-SkipTunnelKey"* ]]
    [[ "$sentline" == *"-SkipGateway"* ]]
    [[ "$sentline" == *"-SkipTunnel"* ]]
    [[ "$sentline" == *"-SkipMsys2"* ]]
    [[ "$sentline" == *"-SkipTools"* ]]
    [[ "$sentline" == *"-SkipAutomation"* ]]
    [[ "$sentline" == *"-SkipShot"* ]]
    [[ "$sentline" == *"-SkipScreen"* ]]
    [[ "$sentline" == *"-SkipVault"* ]]
    [[ "$sentline" == *"-SkipVsCode"* ]]
    [[ "$sentline" == *"-SkipCleanup"* ]]
    [[ "$sentline" == *"-SkipManifest"* ]]
}

# --- --only, which is --skip said the other way round ---------------------------------------
# It exists because a request for two phases cost twelve --skip- flags. That
# list is a COPY of the phase table, in the repository of somebody else. Add a
# fifteenth phase, and each copy starts to run it on a finished layer.
# docs/FORGE.md, "Naming the phases you want".

@test "dr-layer provision --only: everything but the named phases is skipped" {
    run dr-layer provision base --only cleanup,manifest
    [ "$status" -eq 0 ]
    local sentline sw
    sentline=$(sent)
    # The two requested are exactly the two that must NOT be skipped.
    [[ "$sentline" != *"-SkipCleanup"* ]]
    [[ "$sentline" != *"-SkipManifest"* ]]
    # grep -w, not a substring match. `-SkipTunnel` is a prefix of
    # `-SkipTunnelKey`. Thus a plain *"-SkipTunnel"* also matches the WRONG
    # switch.
    for sw in -SkipGuestBase -SkipOnline -SkipTunnelKey -SkipGateway -SkipTunnel -SkipMsys2               -SkipTools -SkipAutomation -SkipShot -SkipScreen -SkipVault -SkipVsCode; do
        printf '%s' "$sentline" | grep -qw -- "$sw" || { echo "not skipped: $sw"; return 1; }
    done
}

# THE INVERSION IS DERIVED, NOT COPIED, and this test says so. A map from --only
# to -Skip* written by hand passes the test above. It fails this one on the day
# that a phase goes into _DR_LAYER_PHASES, but not into the map. --only exists
# to end exactly that drift. The list comes from the own refusal of the program,
# so the test also has no second copy of it.
@test "dr-layer provision --only: the skips are counted off the phase list itself" {
    run dr-layer provision base --only nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"One of: "* ]]
    local list total sentline skipped
    list=${output##*One of: }
    total=$(printf '%s' "$list" | wc -w)
    [ "$total" -gt 2 ]
    run dr-layer provision base --only cleanup,manifest
    [ "$status" -eq 0 ]
    sentline=$(sent)
    skipped=$(printf '%s' "$sentline" | grep -o -- '-Skip[A-Za-z]*' | wc -l)
    [ "$skipped" -eq "$((total - 2))" ] || {
        echo "phases=$total skipped=$skipped (expected $((total - 2)))"; return 1; }
}

# Two switches for one decision can be different. A run that obeys both obeys
# neither. That is also why --skip-netfx is refused.
@test "dr-layer provision --only: refused alongside --skip-" {
    run dr-layer provision base --only cleanup --skip-vault
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot give --only and --skip- together"* ]]
    [[ "$(sent)" != *"provision.ps1"* ]]
}

@test "dr-layer provision --only: a name that is not a phase names the alternatives" {
    run dr-layer provision base --only cleanup,nonsense
    [ "$status" -ne 0 ]
    [[ "$output" == *"--only nonsense is not a phase"* ]]
    [[ "$output" == *"cleanup"* ]]
    # netfx is off unless --netfx names its payload. Thus a request for it here
    # is a second switch for a decision of that flag. Refused with that reason,
    # not silently ignored.
    run dr-layer provision base --only cleanup,netfx
    [ "$status" -ne 0 ]
    [[ "$output" == *"off until you ask for it"* ]]
    # An empty name is a typo, not a request for nothing.
    run dr-layer provision base --only 'cleanup,,manifest'
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty name"* ]]
}

@test "dr-layer provision --only: belongs to provision alone" {
    run dr-layer new child --parent base --only cleanup
    [ "$status" -ne 0 ]
    [[ "$output" == *"--only is an option of dr-layer provision"* ]]
}

# The partner of the test above, and the cheaper half. A phase name that the
# front end accepts, but does not map, passes the tests beside that one, and
# silently fails this one.
@test "dr-layer provision: a component --skip is no longer refused" {
    run dr-layer provision base --skip-msys2 --skip-screen --skip-vault
    [ "$status" -eq 0 ]
    [[ "$output" != *"stage 2b"* ]]
}

# The phase list wraps across three lines in the source, so it reaches this
# message through `tr -s`. A list that still has the newlines prints as three
# broken lines. (The membership test matches in both cases, because the
# indentation gives the leading space. Thus this assertion is about the message,
# the half that a person reads.)
@test "dr-layer provision: an invented --skip is refused and the phases listed" {
    run dr-layer provision base --skip-nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a phase"* ]]
    [[ "$output" == *"guest-base"* ]]
    [[ "$output" == *"vscode"* ]]
    # One line, not three. After the collapse, spaces separate the names.
    [[ "$output" == *"tunnel msys2 tools automation shot screen vault vscode cleanup"* ]]
}

# Each phase in the list must be a name that the mapping knows. Tested as a
# loop, not by eye. The list and the case statement are 90 lines apart, and the
# failure is a phase that is accepted, and then dropped.
@test "dr-layer provision: every phase the list accepts also maps to a switch" {
    local phase
    for phase in guest-base online tunnel-key gateway tunnel msys2 tools automation \
                 shot screen vault vscode cleanup manifest; do
        run dr-layer provision base "--skip-$phase"
        [ "$status" -eq 0 ] || {
            printf 'phase %s was refused:\n%s\n' "$phase" "$output" >&2
            return 1
        }
        [[ "$(sent)" == *"-Skip"* ]] || {
            printf 'phase %s sent no -Skip switch: %s\n' "$phase" "$(sent)" >&2
            return 1
        }
    done
}

# --- the two flags that came with the component phases ------------------------------

@test "dr-layer provision: --vnc-msi becomes a Windows path" {
    run dr-layer provision base --vnc-msi /mnt/d/vnc/mine.msi --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *'-VncMsi D:\vnc\mine.msi'* ]]
}

@test "dr-layer provision: --vnc-msi needs a path" {
    run dr-layer provision base --vnc-msi
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs the path to an MSI"* ]]
}

# The default is the half to test. The install of the viewer of the host
# elevates. Thus a run that did it without a request shows a UAC prompt after an
# hour.
@test "dr-layer provision: the host viewer is not installed unless asked" {
    run dr-layer provision base --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" != *"-InstallViewer"* ]]
    run dr-layer provision base --install-viewer --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *"-InstallViewer"* ]]
}

@test "dr-layer: the provision-only flags are refused on the layer verbs" {
    run dr-layer freeze layer-1 --vnc-msi /x.msi
    [ "$status" -eq 1 ]
    [[ "$output" == *"--vnc-msi is an option of dr-layer provision"* ]]
    run dr-layer drop layer-1 --install-viewer
    [ "$status" -eq 1 ]
    [[ "$output" == *"--install-viewer is an option of dr-layer provision"* ]]
}

@test "dr-layer provision: a layer flag is refused on it" {
    run dr-layer provision base --parent layer-0
    [ "$status" -eq 1 ]
    [[ "$output" == *"--parent is an option of dr-layer new"* ]]
}

@test "dr-layer: a provision flag is refused on the layer verbs" {
    run dr-layer freeze layer-1 --iso /x.iso
    [ "$status" -eq 1 ]
    [[ "$output" == *"--iso is an option of dr-layer provision"* ]]
}

@test "dr-layer provision: with no name it says what it needs" {
    run dr-layer provision
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs the name of a layer"* ]]
}

@test "dr-layer provision: the script's exit code is relayed" {
    DR_MOCK_PROVISION_RC=4 run dr-layer provision base --skip-gateway
    [ "$status" -eq 4 ]
}

# --- what the port left behind ------------------------------------------------------------
#
# A path into the gateway checkout is the one failure that passes each test
# above. dr-layer sends the right arguments to a script. That script then uses
# C:\Code. It works on this machine, and fails on each other one. The port of 2a
# had exactly that bug in a comment. These assertions are why the port of 2b
# does not.

@test "stage 2b: every file it adopted is here" {
    local f
    for f in lib/forge/screen-access.ps1 lib/forge/vault-access.ps1 \
             lib/forge/guest/install-msys2.ps1 lib/forge/guest/install-base-tools.ps1 \
             lib/forge/guest/install-automation.ps1 lib/forge/guest/install-screen-server.ps1 \
             lib/forge/guest/install-vscode.ps1 lib/forge/guest/mount-vault.ps1; do
        [ -f "$DR_ROOT/$f" ] || { printf 'missing: %s\n' "$f" >&2; return 1; }
    done
}

# TWO PATTERNS, because there are two different things here, and we want one of
# them.
#
# A PATH is always a bug: draugr-gateway/ or draugr-gateway\ (the sibling
# checkout), windows\ or ..\guest (its directory layout, which Draugr does not
# share), C:\Code (this machine). Each of those works only here. The port of 2b
# found one of each, in lib/forge/layer.ps1 and lib/forge/guest.ps1.
#
# A MENTION is attribution, on purpose. The header of provision.ps1 says which
# gateway file each test came from, because a test with no source is only a
# claim. Thus a bare mention is a bug only where a USER reads it: in code and in
# strings, not in a comment. That caught guest.ps1 when it told somebody to "see
# draugr-gateway" for a key that Draugr generates itself.
@test "stage 2b: no file points at the gateway checkout or a one-machine path" {
    local f hits
    for f in "$DR_ROOT"/lib/forge/*.ps1 "$DR_ROOT"/lib/forge/guest/*.ps1; do
        hits=$(grep -n 'draugr-gateway[/\]\|windows\\\|\.\.\\guest\|C:\\Code' "$f" || :)
        [ -z "$hits" ] || { printf 'PATH in %s:\n%s\n' "$f" "$hits" >&2; return 1; }
    done
}

@test "stage 2b: the gateway is named in comments only, never to a user" {
    local f hits
    for f in "$DR_ROOT"/lib/forge/*.ps1 "$DR_ROOT"/lib/forge/guest/*.ps1; do
        # All except comment lines. A line whose first non-blank character is #
        # is a comment. Each other line that says draugr-gateway can reach a
        # reader. ^[0-9]*: and not :[0-9]*:. With ONE file, grep prints
        # "line:text", with no filename. Thus a pattern for the three-field form
        # matches nothing, and each comment is reported as visible to a user.
        # This test showed it, when it failed on a comment.
        hits=$(grep -n 'draugr-gateway' "$f" | grep -v '^[0-9]*: *#' || :)
        [ -z "$hits" ] || { printf 'user-visible in %s:\n%s\n' "$f" "$hits" >&2; return 1; }
    done
}

# The host-side pair has no install- prefix. In Draugr, that prefix means "runs
# in the guest", in lib/forge/guest/. With the right name in the wrong place,
# the next person copies the file to the wrong side.
@test "stage 2b: install- means the guest, and the host pair does not claim it" {
    [ ! -f "$DR_ROOT/lib/forge/install-screen-access.ps1" ]
    [ ! -f "$DR_ROOT/lib/forge/install-vault-access.ps1" ]
    local f
    for f in "$DR_ROOT"/lib/forge/*.ps1; do
        case "$(basename "$f")" in
            install-*) printf 'host-side script with a guest-side name: %s\n' "$f" >&2
                       return 1 ;;
        esac
    done
    # And each says where it runs, in its first six lines, because that is the
    # question.
    grep -q 'RUNS ON THE WINDOWS HOST' "$DR_ROOT/lib/forge/screen-access.ps1"
    grep -q 'RUNS ON THE WINDOWS HOST' "$DR_ROOT/lib/forge/vault-access.ps1"
}

# Each .ps1 call that a person can copy from a comment has the prefix. Without
# it, the line fails on a stock Windows, with an execution-policy error that
# looks like a broken script.
@test "stage 2b: the .ps1 lines in the new files are copy-pasteable" {
    local f bad
    for f in "$DR_ROOT"/lib/forge/screen-access.ps1 "$DR_ROOT"/lib/forge/vault-access.ps1 \
             "$DR_ROOT"/lib/forge/guest/install-msys2.ps1 \
             "$DR_ROOT"/lib/forge/guest/install-base-tools.ps1 \
             "$DR_ROOT"/lib/forge/guest/install-automation.ps1 \
             "$DR_ROOT"/lib/forge/guest/install-vscode.ps1 \
             "$DR_ROOT"/lib/forge/guest/mount-vault.ps1; do
        # A comment line that runs a .ps1 by path, and does NOT have
        # -ExecutionPolicy Bypass.
        bad=$(grep -n '^#.*[^y] \.\\.*\.ps1' "$f" | grep -v 'ExecutionPolicy Bypass' || :)
        [ -z "$bad" ] || { printf '%s:\n%s\n' "$f" "$bad" >&2; return 1; }
    done
}

# --- provision reaches all seven ----------------------------------------------------------

@test "stage 2b: provision copies and runs each component script" {
    local f
    for f in msys2 base-tools automation shot vscode; do
        grep -q "guest.install-$f.ps1" "$DR_ROOT/lib/forge/provision.ps1" ||
            { printf 'provision.ps1 never copies install-%s\n' "$f" >&2; return 1; }
        grep -q "Invoke-GuestScript 'install-$f.ps1'" "$DR_ROOT/lib/forge/provision.ps1" ||
            { printf 'provision.ps1 never runs install-%s\n' "$f" >&2; return 1; }
    done
    # The two host-side ones are CALLED, not copied. They run here, and reach
    # in.
    grep -q "Join-Path \$PSScriptRoot 'screen-access.ps1'" "$DR_ROOT/lib/forge/provision.ps1"
    grep -q "Join-Path \$PSScriptRoot 'vault-access.ps1'" "$DR_ROOT/lib/forge/provision.ps1"
    # THOSE two push install-screen-server.ps1 and mount-vault.ps1, not
    # provision.
    grep -q "guest.install-screen-server.ps1" "$DR_ROOT/lib/forge/screen-access.ps1"
    grep -q "guest.mount-vault.ps1" "$DR_ROOT/lib/forge/vault-access.ps1"
}

@test "stage 2b: every phase name provision reports is one dr-layer can skip" {
    local phase
    # Phase '<name>' makes the summary rows, so this is the list that a person
    # sees.
    while read -r phase; do
        case "$phase" in
            # Cannot be skipped BY DESIGN, each for its own reason:
            #   create     phase 0. Whether --iso was given decides it. A --skip-create
            #              is a second switch for one question.
            #   egress     the proof that makes all below it possible.
            #   ssh keys   the own half of the host. It generates them.
            #   netfx3     the placeholder of stage 2c. --skip-netfx is refused, with its name.
            create|egress|'ssh keys'|netfx3) continue ;;
        esac
        # The front end spells two of them differently from the summary, on
        # purpose.
        case "$phase" in
            'guest base') phase=guest-base ;;
            'windows online') phase=online ;;
            'tunnel key') phase=tunnel-key ;;
            'base tools') phase=tools ;;
        esac
        run dr-layer provision base "--skip-$phase"
        [ "$status" -eq 0 ] || {
            printf 'provision reports phase %s, which dr-layer refuses:\n%s\n' \
                "$phase" "$output" >&2
            return 1
        }
    done < <(grep -o "^ *Phase '[a-z0-9 ]*'" "$DR_ROOT/lib/forge/provision.ps1" |
             sed "s/.*Phase '//; s/'$//" | sort -u)
}

# --- the four decisions, in the code ------------------------------------------------------

# This prevents a UAC prompt after an hour of an unattended run. The default is
# the important part, so it is asserted from both ends. provision gives
# -SkipHostViewer unless asked, and screen-access still obeys that switch.
@test "stage 2b: the host viewer is off unless -InstallViewer" {
    grep -q 'if (-not \$InstallViewer) { \$a.SkipHostViewer = \$true }' \
        "$DR_ROOT/lib/forge/provision.ps1"
    grep -q '\[switch\]\$SkipHostViewer' "$DR_ROOT/lib/forge/screen-access.ps1"
    grep -q 'if (-not \$SkipHostViewer)' "$DR_ROOT/lib/forge/screen-access.ps1"
}

# The vault phase reboots the guest, so it must ask first. post-up skips the
# share in TWO cases, and that is the full test. No vault directory (no listener
# on 18445, because the generator publishes it only with a vault). No share
# password on the host (published, it answers, but nothing is behind it).
@test "stage 2b: the vault phase checks both ways the share can be absent" {
    grep -q 'LocalPort 18445' "$DR_ROOT/lib/forge/provision.ps1"
    grep -q "Phase 'vault' 'no vault served'" "$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'draugr_vault_smb.pass' "$DR_ROOT/lib/forge/provision.ps1"
    grep -q "Phase 'vault' 'no share password'" "$DR_ROOT/lib/forge/provision.ps1"
}

# AND THE PORT MUST HAVE A MEANING. That makes the test above useful. The
# publisher binds a published port. Thus an 18445 that is always there answers
# on a gateway with no share, and the phase believes it.
@test "stage 2b: the gateway publishes 18445 only when it serves a vault" {
    grep -q 'DRAUGR_PORTS="@PORTS@"' "$DR_ROOT/share/gateway.example/draugr.conf.in"
    # 18445 must not be a literal in the template now. That is the bug.
    ! grep -q '18445:445' "$DR_ROOT/share/gateway.example/draugr.conf.in" || return 1
    grep -q "ports=\"\$ports 127.0.0.1:18445:445\"" "$DR_ROOT/lib/forge/common.sh"
}

# The MSI cache must not go into the repository. A mound can read the content
# of a checkout, and git must then ignore it.
@test "stage 2b: the pinned MSI is cached outside the repository" {
    grep -q 'CacheDir = "\$env:LOCALAPPDATA' "$DR_ROOT/lib/forge/screen-access.ps1"
    ! grep -q "CacheDir = (Join-Path" "$DR_ROOT/lib/forge/screen-access.ps1"
}

# The own bearer token of the guest stays in the guest. install-automation says
# so where a person who wants to copy it reads it. That sentence is necessary,
# not decoration.
@test "stage 2b: the automation token is not to be copied into the repository" {
    grep -q 'Do not copy it into the repository' "$DR_ROOT/lib/forge/guest/install-automation.ps1"
}

# lib/forge/tunnel.ps1 forwards to 8765. A --mcp-port flag lets somebody move
# the server away from the tunnel that reaches it. Thus there is none, on
# purpose.
@test "stage 2b: the MCP port is not a dr-layer flag" {
    ! grep -q -- '--mcp-port' "$DR_ROOT/bin/dr-layer" || return 1
    grep -q '\[int\]\$McpPort = 8765' "$DR_ROOT/lib/forge/provision.ps1"
    # Given to BOTH the automation phase and the manifest, so that the two
    # cannot drift.
    grep -q -- '-Port \$McpPort' "$DR_ROOT/lib/forge/provision.ps1"
    grep -q -- '-McpPort \$McpPort' "$DR_ROOT/lib/forge/provision.ps1"
}

# Forty identical lines in two files. Both must say so. If not, the next person
# changes one.
@test "stage 2b: the duplicated PATH helper says it has a twin" {
    grep -q 'THE SAME AS THE COPY IN install-automation.ps1' \
        "$DR_ROOT/lib/forge/guest/install-base-tools.ps1"
    grep -q 'THE SAME AS THE COPY IN install-base-tools.ps1' \
        "$DR_ROOT/lib/forge/guest/install-automation.ps1"
    # And they really are identical, except that one line. A drift here gives a
    # guest where one PATH entry goes to a different place from the other.
    local a b
    a=$(sed -n '/^function Add-ToMachinePath/,/^}/p' "$DR_ROOT/lib/forge/guest/install-base-tools.ps1")
    b=$(sed -n '/^function Add-ToMachinePath/,/^}/p' "$DR_ROOT/lib/forge/guest/install-automation.ps1")
    [ -n "$a" ]
    [ "$a" = "$b" ]
}

# --- what the live run found -------------------------------------------------
#
# NO test was able to catch these. They need a guest, an ssh hop, and the
# specific launch context of bin/dr-layer. The suite was ALL GREEN, 936 of 936,
# while each guest-side phase failed and reported ok. This file CAN test that
# the fixes stay. That is the useful half.

# The path must reach the guest with no damage. Plain " quotes lose their
# backslashes when WSL starts provision.ps1 (docs/FORGE.md, the technique
# notes). Thus there must be no quotes around it. The path is always
# C:\Windows\Temp\<name>, and needs none.
@test "live 2026-10-26: the remote path is sent unquoted" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'if exist \$remote ' "$ps"
    # The exact form that lost the backslashes must not come back.
    ! grep -q -- '-File `"\$remote`"' "$ps" || return 1
}

# `powershell -File <missing>` exits 0. Thus absence needs its own code. If not,
# a script that never ran looks like a phase that worked. That gave fourteen
# green rows for fourteen failures.
@test "live 2026-10-26: a guest script that never arrived cannot report success" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'exit /b 127' "$ps"
    # Thrown, not returned. A return adds a code to fourteen call sites that
    # each judge \$rc differently, and one of them gets it wrong.
    grep -q 'never ran. It is not at' "$ps"
    grep -q 'if (\$rc -eq 127)' "$ps"
}

# The egress proof reported OK for a proxy on port 9. Two things keep it honest.
# The curl, whose output format the code depends on, has an absolute name. The
# shape of the answer is tested before the code believes it.
@test "live 2026-10-26: the egress proof names its curl and checks the answer" {
    local pf="$DR_ROOT/lib/forge/guest/preflight.ps1"
    grep -q "Join-Path \$env:SystemRoot 'System32.curl.exe'" "$pf"
    grep -q -- '-notmatch' "$pf"
    grep -q 'THE PROBE IS BROKEN' "$pf"
    # And a broken probe is NOT reported as no egress. A different cause needs a
    # different fix.
    grep -q 'exit 3' "$pf"
    grep -q "Phase 'egress'" "$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'UNPROVED' "$DR_ROOT/lib/forge/provision.ps1"
}

# The PATH decision in one script broke a test in another. The comment that
# argues for the decision must name the binary that it cost.
@test "live 2026-10-26: the PATH block names curl among what it shadows" {
    grep -q 'IT ALSO HIDES curl.exe' "$DR_ROOT/lib/forge/guest/install-base-tools.ps1"
}

# A phase that prints what it WANTED, sees something else, and exits 0. That is
# the fourth of this shape in the port. A TEST on a guest six minutes old showed
# it. The script read IPv4=NoTraffic / LocalAccess, and printed "WANTED:
# IPv4=Internet and InternetAccess" directly below it. It did not compare the
# two, and returned success. Thus the summary said "windows online ok" above its
# own proof of the failure. Eight minutes later, the same guest, with no change,
# read the wanted pair. NLA evaluates again on its own clock. Thus the one read
# at the earliest moment is always pessimistic.
@test "live 2026-10-29: the online fiction is waited for and judged, not just printed" {
    local ws="$DR_ROOT/lib/forge/guest/install-windows-online.ps1"
    # Waited for, as phase 5 of provision already waits for the tunnel
    # forwards.
    grep -q 'foreach (\$i in 1..90)' "$ws"
    # And JUDGED: a verdict in both cases, not a WANTED line for the reader to
    # resolve.
    grep -q 'the fiction works' "$ws"
    grep -q 'DOES NOT LOOK ONLINE' "$ws"
    grep -q 'exit 4' "$ws"
}

# 4 must not stop the run. All was applied, and only the pair that Windows
# REPORTS is missing. That costs only the identity broker. Do not discard a base
# that is worth a finish. But it must also not be called ok.
@test "live 2026-10-29: not-online-looking is its own verdict, neither ok nor fatal" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'applied, but not online-looking yet' "$ps"
    grep -q 'elseif (\$rc -eq 4)' "$ps"
    # It continues: no exit in that branch, unlike the egress guard, which
    # stops.
    run grep -c 'exit 5' "$ps"
    [ "$status" -eq 0 ]
}

# --- what the components run found -------------------------------------------
# Five of seven phases worked the first time. Two did not, for unrelated
# reasons. A guest that already had the thing can never show either defect.

# THE GUARD THAT DID NOT SEE ABSENCE. install-shot.ps1 registered its task "only
# when absent", and asked schtasks. Under Stop, the stderr line of schtasks for
# a missing task became a terminating NativeCommandError. A TEST in the guest
# showed that the schtasks form threw, and the cmdlet returned $null. The fix is
# not a guard, but a better question.
@test "live 2026-10-29: the task is looked up with a cmdlet, not redirected schtasks" {
    local sh="$DR_ROOT/lib/forge/guest/install-shot.ps1"
    local au="$DR_ROOT/lib/forge/guest/install-automation.ps1"
    grep -q 'Get-ScheduledTask -TaskName \$Name' "$sh"
    grep -q "Get-ScheduledTask -TaskName 'windows-mcp-server'" "$au"
    # And the form that threw is gone from both. A positive grep misses that
    # half.
    #
    # COMMENTS REMOVED FIRST, for a reason. Both fixes have a comment that names
    # the removed form. That is the purpose of the comment. Thus a plain grep
    # for it matches the explanation, and fails on a correct file. The own prose
    # of this suite broke it three times. A negative grep of source must read
    # code.
    run bash -c "grep -h 'schtasks /query' '$sh' '$au' | grep -vE '^[[:space:]]*#'"
    [ -z "$output" ]
}

# The rule, as a test, because three files each learned it alone, and the
# fourth then made the same mistake. A linter that nobody runs is not a rule.
# Thus its wiring is also asserted: the shared list in lint-comments.sh, and the
# CI step.
@test "live 2026-10-29: the native-stderr rule is a check, and it is wired in" {
    [ -x "$DR_ROOT/tests/lint-native-stderr.sh" ]
    grep -q 'lint-native-stderr.sh' "$DR_ROOT/tests/lint-comments.sh"
    grep -q 'lint-native-stderr.sh' "$DR_ROOT/.github/workflows/ci.yml"
    # It passes on this tree. Assert that, and do not assume it. The full reason
    # for it was that five sites did not.
    run "$DR_ROOT/tests/lint-native-stderr.sh"
    [ "$status" -eq 0 ]
}

# AN INTERPRETER WITH NO PIN IS A BUILD THAT BREAKS ON THE SCHEDULE OF SOMEBODY
# ELSE. uv took 3.15.2, pyyaml had no cp315 wheel, and the install tried to
# compile it in a guest with no compiler.
@test "live 2026-10-29: CPython is pinned, and the pin reaches both installs" {
    local au="$DR_ROOT/lib/forge/guest/install-automation.ps1"
    grep -q "\[string\]\$PythonVersion = '3.14'" "$au"
    # The interpreter, and the own venv of the tool. The venv picks its own,
    # unless told. That is what really built against 3.15.
    grep -q 'uv python install \$PythonVersion --default' "$au"
    grep -q 'uv tool install --quiet --python \$PythonVersion windows-mcp' "$au"
}

# Presence was the honest test while each python was enough. With a pin, it is a
# test that passes on the wrong interpreter. The failed run left a 3.15.2 shim.
# Thus this is the exact state that the next run must not accept.
@test "live 2026-10-29: the shim is checked by version, not by existing" {
    local au="$DR_ROOT/lib/forge/guest/install-automation.ps1"
    grep -q 'if (\$shimVer -eq \$PythonVersion)' "$au"
    # Also after the install. The throw makes it a test, not a hope.
    grep -q "not the pinned \$PythonVersion" "$au"
}

# A TEST BELOW THE REBOOT THAT MAKES ITS ANSWER TRUE. The order is the defect,
# so this asserts the order. Line numbers, because nothing else can say
# "before".
@test "live 2026-10-29: EnableLinkedConnections is read before the reboot" {
    local va="$DR_ROOT/lib/forge/vault-access.ps1"
    local read_at reboot_at
    # Comments excluded. The comment that explains this fix QUOTES the reboot
    # command, and is above the read. Thus the prose alone reports the defect as
    # still present.
    read_at=$(grep -nE 'elcQuery = ' "$va" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    reboot_at=$(grep -nE 'shutdown /r /t 0' "$va" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    [ -n "$read_at" ]
    [ -n "$reboot_at" ]
    [ "$read_at" -lt "$reboot_at" ]
}

# '' means "the question did not reach the guest", not "not set". A report of
# the first as the second made a reader fix a value that was already correct. A
# test that cannot pass.
@test "live 2026-10-29: an unreadable answer is its own case, not a missing value" {
    local va="$DR_ROOT/lib/forge/vault-access.ps1"
    grep -q 'if (-not \$elc) {' "$va"
    grep -q 'could not read EnableLinkedConnections from the guest' "$va"
    grep -q 'UNKNOWN, not absent' "$va"
    # And the real negative still has its own branch, which shows the value.
    grep -q "elseif (\$elc -ne '1')" "$va"
}

# --- 2c: .NET 3.5, the one phase that is off unless you ask for it ------------------------

@test "dr-layer provision: --netfx becomes a Windows path" {
    run dr-layer provision base --netfx /mnt/d/iso/sxs --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *'-NetFxSource D:\iso\sxs'* ]]
}

# The default is the full decision. A base with no .NET 3.5 is the normal case,
# because its payload is a cab that only a person can take from an ISO.
@test "dr-layer provision: nothing is sent for .NET 3.5 unless --netfx is given" {
    run dr-layer provision base --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" != *"-NetFxSource"* ]]
    [[ "$(sent)" != *"-SkipNetFx"* ]]
}

@test "dr-layer provision: --netfx needs a path, and says where to find one" {
    run dr-layer provision base --netfx
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a path"* ]]
    [[ "$output" == *"sxs"* ]]
}

# ONE FLAG, NOT TWO. --skip-netfx is a second switch for a decision of --netfx.
# Two switches for one decision can be different. The refusal must say which
# flag is the real one. If not, it reads only as "unsupported".
@test "dr-layer provision: --skip-netfx is refused, naming --netfx as the switch" {
    run dr-layer provision base --skip-netfx
    [ "$status" -eq 1 ]
    [[ "$output" == *"already off"* ]]
    [[ "$output" == *"--netfx"* ]]
}

@test "dr-layer: --netfx is refused on the layer verbs" {
    run dr-layer freeze layer-1 --netfx /x/sxs
    [ "$status" -eq 1 ]
    [[ "$output" == *"--netfx is an option of dr-layer provision"* ]]
}

# netfx must NOT be in the phase list. There, --skip-netfx is accepted again,
# and this stage decided against that shape.
@test "dr-layer provision: netfx is not in the skippable phase list" {
    run dr-layer provision base --skip-nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a phase"* ]]
    [[ "$output" != *"netfx"* ]]
}

# --- 2c in the PowerShell, as far as grep can see it ---------------------------------------

@test "stage 2c: the payload is checked before phase 0, not after phase 11" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    # The test is in the preconditions, so its line number is below the heading
    # of phase 0.
    local check phase0
    check=$(grep -n '^if (\$NetFxSource) {' "$ps" | head -1 | cut -d: -f1)
    phase0=$(grep -n '^# =*.*0\. create the VM' "$ps" | head -1 | cut -d: -f1)
    [ -n "$check" ]
    [ -n "$phase0" ]
    [ "$check" -lt "$phase0" ] || {
        printf 'the -NetFxSource check is at %s, phase 0 at %s - it must come first\n' \
            "$check" "$phase0" >&2
        return 1
    }
}

# The cab goes in from the HOST. Only that lets the test happen at the start.
# The guest cannot reach the vault until phase 11 installs a credential and
# reboots it.
@test "stage 2c: the cab is pushed into the guest, not fetched from the vault" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'Copy-ToGuest @(\$netFxCab.FullName)' "$ps"
    grep -q -- '-Source \$(\$sxs' "$ps"
    # -Share is the vault route of the guest script, and provision must not use
    # it.
    ! grep -q -- '-Share ' "$ps" || return 1
    # And the guest script still HAS that route, for a person who runs it by
    # hand.
    grep -q "Share    = '\\\\\\\\127.0.0.1\\\\vault'" \
        "$DR_ROOT/lib/forge/guest/install-netfx3.ps1"
}

@test "stage 2c: a failure is reported rather than thrown away with the base" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    # 'not requested' is the off case, and the summary SAYS it. With a silently
    # absent row, somebody later asks why Windows wanted .NET 3.5.
    grep -q "Phase 'netfx3' 'not requested'" "$ps"
    # Exit 2 of the guest script is "no payload where I was told to look". After
    # the precondition, that can only mean that the copy did not arrive.
    # Different from a DISM failure.
    grep -q 'the cab did not arrive in the guest' "$ps"
}

# Before, the code trusted a --netfx that pointed at the WRONG FILE. The file
# was pushed, the guest found no *netfx3*.cab beside it, and exited 2. The
# summary said "the cab did not arrive in the guest" about a file that arrived.
# Now this side tests the name.
@test "stage 2c: a file that is not a cab is refused here, not mistaken for a lost copy" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q "if (\$f.Name -like '\*netfx3\*.cab')" "$ps"
    grep -q 'that is not a NetFx3 cab' "$ps"
}
