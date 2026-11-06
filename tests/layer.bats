#!/usr/bin/env bats
# dr-layer: the front end to the forge's disk layers. docs/FORGE.md, "The layer mechanism as
# a command".
#
# WHAT IS TESTED HERE, AND WHAT CANNOT BE. lib/forge/layer.ps1 edits vms.cfg and drives the
# VHD cmdlets - neither exists off Windows, and both are the kind of thing a mock would only
# pretend to do. So this file tests the half that is bash: the verbs, the flags, which
# PowerShell parameter each one becomes, and what dr-layer does with the codes that come
# back. The PowerShell half is the gateway's measured forge-layer.ps1, adopted rather than
# rewritten, and it is verified by running it (its `list` is read-only).
#
# THE OPPOSITE GATE IS THE POINT OF THE FIRST TEST. Every other forge command is inert unless
# DRAUGR_FORGE names a VM. dr-layer cannot be: it CREATES the thing that key would name.

load helper

setup() {
    dr_test_setup
    export WSL_DISTRO_NAME=Test
    # Deliberately NOT set: dr-layer must work without it. A test that needs it says so.
    unset DRAUGR_FORGE || :
    cd "$DR_TMP" || return 1
}

teardown() { dr_test_teardown; }

# The argv the mock recorded, which is how every "what did it send" assertion is made.
sent() { grep '^powershell ' "$DR_MOCK_LOG" | tail -1; }

# --- the gate, which is the opposite of dr-forge's -----------------------------------------

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

# Every verb the help lists has to be dispatchable: an "unknown action" about one the docs
# promise would send someone looking for their own typo. provision is the one that was a
# refusal until stage two landed, so it is the one worth naming here.
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

# Caught in bash, before anything crosses to Windows: with the daemon up, layer.ps1 would
# answer "AppSandbox is running" to a command that was never going to work anyway.
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

# A size that is not a number would arrive as 0 and be read as "inherit the parent's
# capacity" - a silent wrong answer where a refusal belongs.
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

# layer.ps1 accepts them all and uses each where it means something, so a misaimed flag would
# be taken in silence - and `drop x --force` would read as "I forced it" while forcing nothing.
@test "dr-layer: a flag aimed at the wrong verb is refused" {
    run dr-layer drop layer-1 --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"--force belongs to dr-layer thaw"* ]]

    run dr-layer freeze layer-1 --no-register
    [ "$status" -eq 1 ]
    [[ "$output" == *"--no-register belongs to dr-layer thaw"* ]]

    run dr-layer adopt layer-0 --parent layer-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"--parent belongs to dr-layer new"* ]]

    run dr-layer list --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"--dry-run belongs"* ]]
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

# An unset key must pass NO -Root at all. layer.ps1 reports a default differently from a
# choice, and forwarding C:\ForgeLayers as an argument would make it call the default a
# decision somebody made - twice over, since its elevation relaunch forwards what it was given.
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

# A REFUSAL IS NOT A FAILURE, and the codes are how a front end tells them apart: 3 is the
# daemon being up, 20 is a guard doing its job. Both are relayed unchanged, with a line saying
# which it was - and 20 above all, because a guard that stopped a drop must not read as a bug.
@test "dr-layer: the daemon being up is relayed as 3, and said out loud" {
    DR_MOCK_LAYER_RC=3 run dr-layer freeze layer-1
    [ "$status" -eq 3 ]
    [[ "$output" == *"AppSandbox is up"* ]]
}

@test "dr-layer: a guard refusing is relayed as 20, and nothing claims success" {
    DR_MOCK_LAYER_RC=20 run dr-layer drop layer-1
    [ "$status" -eq 20 ]
    [[ "$output" == *"refused by a guard"* ]]
    [[ "$output" == *"nothing was changed"* ]]
}

@test "dr-layer: an absence is relayed as 21" {
    DR_MOCK_LAYER_RC=21 run dr-layer freeze nosuchlayer
    [ "$status" -eq 21 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "dr-layer: a declined UAC prompt is relayed as 24" {
    DR_MOCK_LAYER_RC=24 run dr-layer new layer-2 --parent layer-1
    [ "$status" -eq 24 ]
    [[ "$output" == *"elevation was declined"* ]]
}

# The output must survive whatever the code was: a refusal explains itself in the PowerShell's
# own words, and swallowing them would leave only the one-line summary.
@test "dr-layer: the script's output is relayed even when it refuses" {
    DR_MOCK_LAYER_RC=20 run dr-layer drop layer-1
    [[ "$output" == *"mock layer.ps1: drop"* ]]
}

# --- the help, which is the only documentation at the terminal -----------------------------

@test "dr-layer --help: names the verbs and the elevation trap" {
    run dr-layer --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"dr-layer new"* ]]
    [[ "$output" == *"DO NOT RUN THIS FROM AN ELEVATED SHELL"* ]]
}

# --- provision, which is a different verb's vocabulary --------------------------------------

# It used to refuse as "not built yet". The test that it no longer does is the cheapest guard
# against the wiring being half done - a verb that reaches the wrong script would still exit 0.
@test "dr-layer provision: reaches provision.ps1, not layer.ps1" {
    run dr-layer provision base --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *"provision.ps1"* ]]
    [[ "$(sent)" != *"layer.ps1"* ]]
    [[ "$(sent)" == *"-Vm base"* ]]
}

# -Mode is layer.ps1's vocabulary and provision has none: a stray -Mode would be a parameter
# it does not declare, which PowerShell refuses by name.
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

# An EMPTY --timezone means "leave the guest's clock alone", which is a real answer - so it
# has to be forwarded rather than treated as absent. The guest otherwise inherits Windows'
# unattended default, Pacific, in every layer built on it.
@test "dr-layer provision: an empty --timezone is still forwarded" {
    run dr-layer provision base --timezone '' --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *"-TimeZone"* ]]
}

# ALL FOURTEEN AT ONCE, which is the point: the mapping is a case statement, and a case
# statement is exactly where one phase quietly falls through to nothing. A -Skip that never
# arrives reads to the caller as "I turned that off" while the phase runs anyway - an hour
# of installing, in the case of the components.
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
# It exists because naming two phases cost twelve --skip- flags, and that list is a COPY of the
# phase table living in somebody else's repository: add a fifteenth phase and every copy starts
# running it on a finished layer. docs/FORGE.md, "Naming the phases you want".

@test "dr-layer provision --only: everything but the named phases is skipped" {
    run dr-layer provision base --only cleanup,manifest
    [ "$status" -eq 0 ]
    local sentline sw
    sentline=$(sent)
    # The two asked for are precisely the two that must NOT be skipped.
    [[ "$sentline" != *"-SkipCleanup"* ]]
    [[ "$sentline" != *"-SkipManifest"* ]]
    # grep -w, not a substring match: `-SkipTunnel` is a prefix of `-SkipTunnelKey`, so a
    # plain *"-SkipTunnel"* is satisfied by the WRONG switch being present.
    for sw in -SkipGuestBase -SkipOnline -SkipTunnelKey -SkipGateway -SkipTunnel -SkipMsys2               -SkipTools -SkipAutomation -SkipShot -SkipScreen -SkipVault -SkipVsCode; do
        printf '%s' "$sentline" | grep -qw -- "$sw" || { echo "not skipped: $sw"; return 1; }
    done
}

# THE INVERSION IS DERIVED, NOT TRANSCRIBED, and this is the test that says so. A hand-written
# map from --only to -Skip* would satisfy the test above and fail this one the day a phase is
# added to _DR_LAYER_PHASES and not to the map - which is the exact drift --only exists to end.
# The list comes from the program's own refusal, so the test has no second copy of it either.
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

# Two switches for one decision can disagree, and a run honouring both would be obeying
# neither - the same ground --skip-netfx is refused on.
@test "dr-layer provision --only: refused alongside --skip-" {
    run dr-layer provision base --only cleanup --skip-vault
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot both be given"* ]]
    [[ "$(sent)" != *"provision.ps1"* ]]
}

@test "dr-layer provision --only: a name that is not a phase names the alternatives" {
    run dr-layer provision base --only cleanup,nonsense
    [ "$status" -ne 0 ]
    [[ "$output" == *"--only nonsense is not a phase"* ]]
    [[ "$output" == *"cleanup"* ]]
    # netfx is off unless --netfx names its payload, so asking for it here is a second switch
    # for a decision that flag already makes - refused with that reason, not silently ignored.
    run dr-layer provision base --only cleanup,netfx
    [ "$status" -ne 0 ]
    [[ "$output" == *"off unless asked for"* ]]
    # An empty name is a typo, not a request for nothing.
    run dr-layer provision base --only 'cleanup,,manifest'
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty name"* ]]
}

@test "dr-layer provision --only: belongs to provision alone" {
    run dr-layer new child --parent base --only cleanup
    [ "$status" -ne 0 ]
    [[ "$output" == *"--only belongs to dr-layer provision"* ]]
}

# The counterpart of the test above, and the cheaper half: a phase name the front end
# accepts but does not map would pass that test's siblings and silently drop this one.
@test "dr-layer provision: a component --skip is no longer refused" {
    run dr-layer provision base --skip-msys2 --skip-screen --skip-vault
    [ "$status" -eq 0 ]
    [[ "$output" != *"stage 2b"* ]]
}

# The phase list is wrapped across three lines in the source, so it reaches this message
# through `tr -s`. A list that still carried the newlines would print as three broken lines.
# (The membership test matches either way - the indentation supplies the leading space - so
# this assertion is about the message, which is the half a person reads.)
@test "dr-layer provision: an invented --skip is refused and the phases listed" {
    run dr-layer provision base --skip-nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a phase"* ]]
    [[ "$output" == *"guest-base"* ]]
    [[ "$output" == *"vscode"* ]]
    # One line, not three: the names are space-separated after the collapse.
    [[ "$output" == *"tunnel msys2 tools automation shot screen vault vscode cleanup"* ]]
}

# Every phase in the list must be a name the mapping knows. Checked as a loop rather than
# by eye: the list and the case statement are 90 lines apart, and the failure mode is a
# phase that is accepted and then dropped.
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

# --- the two flags the component phases brought with them -----------------------------

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

# The default is the half worth testing: installing the host's viewer elevates, so a run
# that did it without being asked would raise a UAC prompt an hour in.
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
    [[ "$output" == *"--vnc-msi belongs to dr-layer provision"* ]]
    run dr-layer drop layer-1 --install-viewer
    [ "$status" -eq 1 ]
    [[ "$output" == *"--install-viewer belongs to dr-layer provision"* ]]
}

@test "dr-layer provision: a layer flag is refused on it" {
    run dr-layer provision base --parent layer-0
    [ "$status" -eq 1 ]
    [[ "$output" == *"--parent belongs to dr-layer new"* ]]
}

@test "dr-layer: a provision flag is refused on the layer verbs" {
    run dr-layer freeze layer-1 --iso /x.iso
    [ "$status" -eq 1 ]
    [[ "$output" == *"--iso belongs to dr-layer provision"* ]]
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
# A path into the gateway checkout is the one failure that would pass every test above:
# dr-layer would send the right arguments to a script that then reaches for C:\Code, works
# perfectly on this machine, and fails on every other one. 2a's port had exactly that bug
# in a comment; these assertions are why 2b's does not.

@test "stage 2b: every file it adopted is here" {
    local f
    for f in lib/forge/screen-access.ps1 lib/forge/vault-access.ps1 \
             lib/forge/guest/install-msys2.ps1 lib/forge/guest/install-base-tools.ps1 \
             lib/forge/guest/install-automation.ps1 lib/forge/guest/install-screen-server.ps1 \
             lib/forge/guest/install-vscode.ps1 lib/forge/guest/mount-vault.ps1; do
        [ -f "$DR_ROOT/$f" ] || { printf 'missing: %s\n' "$f" >&2; return 1; }
    done
}

# TWO PATTERNS, because there are two different things here and one of them is wanted.
#
# A PATH is always a bug: draugr-gateway/ or draugr-gateway\ (the sibling checkout),
# windows\ or ..\guest (its directory layout, which Draugr does not share), C:\Code (this
# machine). Any of those works here and nowhere else - 2b's port found one of each, in
# lib/forge/layer.ps1 and lib/forge/guest.ps1.
#
# A MENTION is attribution, and it is deliberate: provision.ps1's header says which gateway
# file each measurement came from, because a measurement without a provenance is a claim.
# So a bare mention is only a bug where a USER reads it - in code and in strings, not in a
# comment. That is what caught guest.ps1 telling someone to "see draugr-gateway" for a key
# Draugr generates itself.
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
        # Everything but comment lines. A line whose first non-blank character is # is a
        # comment; anything else that says draugr-gateway can reach a reader.
        # ^[0-9]*: and not :[0-9]*: - grep given ONE file prints "line:text", with no
        # filename, so a pattern expecting the three-field form matches nothing and every
        # comment is reported as user-visible. Measured by this test failing on a comment.
        hits=$(grep -n 'draugr-gateway' "$f" | grep -v '^[0-9]*: *#' || :)
        [ -z "$hits" ] || { printf 'user-visible in %s:\n%s\n' "$f" "$hits" >&2; return 1; }
    done
}

# The host-side pair keeps no install- prefix: in Draugr that prefix means "runs in the
# guest" and lives in lib/forge/guest/. A file in the wrong place with the right name is
# how the next person copies it to the wrong side.
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
    # And each says where it runs, in its first six lines, because that is the question.
    grep -q 'RUN ON THE WINDOWS HOST' "$DR_ROOT/lib/forge/screen-access.ps1"
    grep -q 'RUN ON THE WINDOWS HOST' "$DR_ROOT/lib/forge/vault-access.ps1"
}

# Every .ps1 invocation a human might copy out of a comment carries the prefix. Without it
# the line fails on a stock Windows, with an execution-policy error that reads as if the
# script were broken.
@test "stage 2b: the .ps1 lines in the new files are copy-pasteable" {
    local f bad
    for f in "$DR_ROOT"/lib/forge/screen-access.ps1 "$DR_ROOT"/lib/forge/vault-access.ps1 \
             "$DR_ROOT"/lib/forge/guest/install-msys2.ps1 \
             "$DR_ROOT"/lib/forge/guest/install-base-tools.ps1 \
             "$DR_ROOT"/lib/forge/guest/install-automation.ps1 \
             "$DR_ROOT"/lib/forge/guest/install-vscode.ps1 \
             "$DR_ROOT"/lib/forge/guest/mount-vault.ps1; do
        # A comment line that runs a .ps1 by path and does NOT carry -ExecutionPolicy Bypass.
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
    # The two host-side ones are CALLED, not copied: they run here and reach in.
    grep -q "Join-Path \$PSScriptRoot 'screen-access.ps1'" "$DR_ROOT/lib/forge/provision.ps1"
    grep -q "Join-Path \$PSScriptRoot 'vault-access.ps1'" "$DR_ROOT/lib/forge/provision.ps1"
    # install-screen-server.ps1 and mount-vault.ps1 are pushed by THOSE two, not by provision.
    grep -q "guest.install-screen-server.ps1" "$DR_ROOT/lib/forge/screen-access.ps1"
    grep -q "guest.mount-vault.ps1" "$DR_ROOT/lib/forge/vault-access.ps1"
}

@test "stage 2b: every phase name provision reports is one dr-layer can skip" {
    local phase
    # Phase '<name>' is how the summary rows are made, so this is the list a person sees.
    while read -r phase; do
        case "$phase" in
            # Not skippable BY DESIGN, each for its own reason:
            #   create     phase 0, which is decided by whether --iso was given at all. A
            #              --skip-create would be a second switch for one question.
            #   egress     the proof that makes everything below it possible.
            #   ssh keys   the host's own half, and it is what generates them.
            #   netfx3     stage 2c's placeholder; --skip-netfx is refused, naming it.
            create|egress|'ssh keys'|netfx3) continue ;;
        esac
        # The front end spells two of them differently from the summary, on purpose.
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

# A UAC prompt an hour into an unattended run is the thing this prevents. The default is
# what matters, so it is asserted from both ends: provision passes -SkipHostViewer unless
# asked, and screen-access still honours that switch.
@test "stage 2b: the host viewer is off unless -InstallViewer" {
    grep -q 'if (-not \$InstallViewer) { \$a.SkipHostViewer = \$true }' \
        "$DR_ROOT/lib/forge/provision.ps1"
    grep -q '\[switch\]\$SkipHostViewer' "$DR_ROOT/lib/forge/screen-access.ps1"
    grep -q 'if (-not \$SkipHostViewer)' "$DR_ROOT/lib/forge/screen-access.ps1"
}

# The vault phase reboots the guest, so it has to ask first - and post-up skips the share
# in TWO cases, which is the whole of this test: no vault directory (no listener on 18445,
# because the generator only publishes it when there is a vault) and no share password on
# the host (published, answering, nothing behind it).
@test "stage 2b: the vault phase checks both ways the share can be absent" {
    grep -q 'LocalPort 18445' "$DR_ROOT/lib/forge/provision.ps1"
    grep -q "Phase 'vault' 'no vault served'" "$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'draugr_vault_smb.pass' "$DR_ROOT/lib/forge/provision.ps1"
    grep -q "Phase 'vault' 'no share password'" "$DR_ROOT/lib/forge/provision.ps1"
}

# AND THE PORT HAS TO MEAN SOMETHING, which is what makes the check above worth making. A
# published port is bound by the publisher, so an unconditional 18445 would answer on a
# gateway with no share and the phase would believe it.
@test "stage 2b: the gateway publishes 18445 only when it serves a vault" {
    grep -q 'DRAUGR_PORTS="@PORTS@"' "$DR_ROOT/share/gateway.example/draugr.conf.in"
    # 18445 must not be a literal in the template any more: that is the bug.
    ! grep -q '18445:445' "$DR_ROOT/share/gateway.example/draugr.conf.in" || return 1
    grep -q "ports=\"\$ports 127.0.0.1:18445:445\"" "$DR_ROOT/lib/forge/common.sh"
}

# The MSI cache must not land inside the repository: a mound can read what is in a checkout,
# and git would have to be told to ignore it.
@test "stage 2b: the pinned MSI is cached outside the repository" {
    grep -q 'CacheDir = "\$env:LOCALAPPDATA' "$DR_ROOT/lib/forge/screen-access.ps1"
    ! grep -q "CacheDir = (Join-Path" "$DR_ROOT/lib/forge/screen-access.ps1"
}

# The guest's own bearer token stays in the guest. install-automation says so where someone
# about to copy it would read it, and that sentence is load-bearing, not decoration.
@test "stage 2b: the automation token is not to be copied into the repository" {
    grep -q 'do not copy it into the repository' "$DR_ROOT/lib/forge/guest/install-automation.ps1"
}

# 8765 is where lib/forge/tunnel.ps1 forwards. A --mcp-port flag would let someone move the
# server away from the tunnel that reaches it, so there deliberately is not one.
@test "stage 2b: the MCP port is not a dr-layer flag" {
    ! grep -q -- '--mcp-port' "$DR_ROOT/bin/dr-layer" || return 1
    grep -q '\[int\]\$McpPort = 8765' "$DR_ROOT/lib/forge/provision.ps1"
    # Passed to BOTH the automation phase and the manifest, so the two cannot drift.
    grep -q -- '-Port \$McpPort' "$DR_ROOT/lib/forge/provision.ps1"
    grep -q -- '-McpPort \$McpPort' "$DR_ROOT/lib/forge/provision.ps1"
}

# Forty identical lines in two files. Both must say so, or the next person changes one.
@test "stage 2b: the duplicated PATH helper says it has a twin" {
    grep -q 'IDENTICAL TO THE COPY IN install-automation.ps1' \
        "$DR_ROOT/lib/forge/guest/install-base-tools.ps1"
    grep -q 'IDENTICAL TO THE COPY IN install-base-tools.ps1' \
        "$DR_ROOT/lib/forge/guest/install-automation.ps1"
    # And they really are identical, bar that one line: a drift here is a guest where one
    # PATH entry lands in a different place from the other.
    local a b
    a=$(sed -n '/^function Add-ToMachinePath/,/^}/p' "$DR_ROOT/lib/forge/guest/install-base-tools.ps1")
    b=$(sed -n '/^function Add-ToMachinePath/,/^}/p' "$DR_ROOT/lib/forge/guest/install-automation.ps1")
    [ -n "$a" ]
    [ "$a" = "$b" ]
}

# --- what the live run found -------------------------------------------------
#
# NONE of these could have been caught by a test. They need a guest, an ssh hop and the
# specific launch context bin/dr-layer uses, and the suite was ALL GREEN, 936 of 936 while
# every guest-side phase was failing and reporting ok. What IS checkable here is that the
# fixes stay fixed - which is the half worth keeping.

# The path must reach the guest unmangled. Plain " quotes lose their backslashes when
# provision.ps1 is launched from WSL (docs/FORGE.md, the technique notes), so there must be
# no quotes around it at all - the path is always C:\Windows\Temp\<name> and needs none.
@test "live 2026-10-26: the remote path is sent unquoted" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'if exist \$remote ' "$ps"
    # The exact form that ate the backslashes must not come back.
    ! grep -q -- '-File `"\$remote`"' "$ps" || return 1
}

# `powershell -File <missing>` exits 0, so absence has to be given a code of its own or a
# script that never ran reads as a phase that worked. That is what produced fourteen green
# rows over fourteen failures.
@test "live 2026-10-26: a guest script that never arrived cannot report success" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'exit /b 127' "$ps"
    # Thrown, not returned: returning it would add a code to fourteen call sites that each
    # judge \$rc differently, and one of them would get it wrong.
    grep -q 'never ran: it is not at' "$ps"
    grep -q 'if (\$rc -eq 127)' "$ps"
}

# The egress proof reported OK against a proxy on port 9. Two things keep it honest: the
# curl whose output format is relied on is named absolutely, and the answer is checked for
# shape before it is believed.
@test "live 2026-10-26: the egress proof names its curl and checks the answer" {
    local pf="$DR_ROOT/lib/forge/guest/preflight.ps1"
    grep -q "Join-Path \$env:SystemRoot 'System32.curl.exe'" "$pf"
    grep -q -- '-notmatch' "$pf"
    grep -q 'THE PROBE IS BROKEN' "$pf"
    # And a broken probe is NOT reported as no egress: different cause, different fix.
    grep -q 'exit 3' "$pf"
    grep -q "Phase 'egress'" "$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'UNPROVED' "$DR_ROOT/lib/forge/provision.ps1"
}

# The PATH decision in one script broke a verification in another. The comment that argues
# for the decision must name the binary it cost.
@test "live 2026-10-26: the PATH block names curl among what it shadows" {
    grep -q 'SHADOWS curl.exe TOO' "$DR_ROOT/lib/forge/guest/install-base-tools.ps1"
}

# A phase that prints what it WANTED, observes something else, and exits 0 is the fourth of
# this shape in the port. MEASURED on a six-minute-old guest: the script read
# IPv4=NoTraffic / LocalAccess, printed "WANTED: IPv4=Internet and InternetAccess" directly
# beneath it, compared the two not at all, and returned success - so the summary said
# "windows online ok" above its own evidence that it had not worked. Eight minutes later the
# same guest, unchanged, read the wanted pair: NLA re-evaluates on its own clock, so the one
# reading taken at the earliest possible moment is the one guaranteed to be pessimistic.
@test "live 2026-10-29: the online fiction is waited for and judged, not just printed" {
    local ws="$DR_ROOT/lib/forge/guest/install-windows-online.ps1"
    # Waited for, the way provision's phase 5 already waits for the tunnel forwards.
    grep -q 'foreach (\$i in 1..90)' "$ws"
    # And JUDGED: a verdict either way, not a WANTED line left for the reader to resolve.
    grep -q 'the fiction holds' "$ws"
    grep -q 'NOT ONLINE-LOOKING' "$ws"
    grep -q 'exit 4' "$ws"
}

# 4 must not abort the run: everything was applied and only the pair Windows REPORTS is
# missing, which costs the identity broker and nothing else. A base worth finishing should
# not be thrown away over it - but it must not be called ok either.
@test "live 2026-10-29: not-online-looking is its own verdict, neither ok nor fatal" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'applied, but not online-looking yet' "$ps"
    grep -q 'elseif (\$rc -eq 4)' "$ps"
    # It carries on: no exit in that branch, unlike the egress guard which does stop.
    run grep -c 'exit 5' "$ps"
    [ "$status" -eq 0 ]
}

# --- what the components run found --------------------------------------------
# Five of seven phases worked first time; two did not, for unrelated reasons, and both were
# defects a guest that already had the thing could never have shown.

# THE GUARD THAT COULD NOT SEE ABSENCE. install-shot.ps1 registered its task "only when
# absent" and asked schtasks, whose stderr line for a missing task became a terminating
# NativeCommandError under Stop. MEASURED in the guest: the schtasks form threw, the cmdlet
# returned $null. The fix is not a guard but a better question.
@test "live 2026-10-29: the task is looked up with a cmdlet, not redirected schtasks" {
    local sh="$DR_ROOT/lib/forge/guest/install-shot.ps1"
    local au="$DR_ROOT/lib/forge/guest/install-automation.ps1"
    grep -q 'Get-ScheduledTask -TaskName \$Name' "$sh"
    grep -q "Get-ScheduledTask -TaskName 'windows-mcp-server'" "$au"
    # And the form that threw is gone from both, which is the half a positive grep misses.
    #
    # COMMENTS STRIPPED FIRST, and that is not fussiness. Both fixes carry a comment naming
    # the form they removed - that is the point of the comment - so a plain grep for it
    # matches the explanation and fails on a file that is correct. This suite has now been
    # bitten by its own prose three times; a negative grep over source has to read code.
    run bash -c "grep -h 'schtasks /query' '$sh' '$au' | grep -vE '^[[:space:]]*#'"
    [ -z "$output" ]
}

# The rule, as a check, because three files had each learned it privately and the fourth
# then made the same mistake. A linter nobody runs is not a rule, so its wiring is asserted
# too: the shared list in lint-comments.sh and the CI step.
@test "live 2026-10-29: the native-stderr rule is a check, and it is wired in" {
    [ -x "$DR_ROOT/tests/lint-native-stderr.sh" ]
    grep -q 'lint-native-stderr.sh' "$DR_ROOT/tests/lint-comments.sh"
    grep -q 'lint-native-stderr.sh' "$DR_ROOT/.github/workflows/ci.yml"
    # It passes on this tree, and that is worth asserting rather than assuming: the whole
    # point of adding it was that five sites did not.
    run "$DR_ROOT/tests/lint-native-stderr.sh"
    [ "$status" -eq 0 ]
}

# AN UNPINNED INTERPRETER IS A BUILD THAT BREAKS ON SOMEONE ELSE'S SCHEDULE. uv took 3.15.2,
# pyyaml had no cp315 wheel, and the install tried to compile it in a guest with no compiler.
@test "live 2026-10-29: CPython is pinned, and the pin reaches both installs" {
    local au="$DR_ROOT/lib/forge/guest/install-automation.ps1"
    grep -q "\[string\]\$PythonVersion = '3.14'" "$au"
    # The interpreter, and the tool's own venv - which picks its own unless told, and that
    # is what actually built against 3.15.
    grep -q 'uv python install \$PythonVersion --default' "$au"
    grep -q 'uv tool install --quiet --python \$PythonVersion windows-mcp' "$au"
}

# Presence was the honest test while any python would do. With a pin it is a test that
# passes on the wrong interpreter - and the failed run left a 3.15.2 shim behind, so this
# is the exact state the re-run had to not accept.
@test "live 2026-10-29: the shim is checked by version, not by existing" {
    local au="$DR_ROOT/lib/forge/guest/install-automation.ps1"
    grep -q 'if (\$shimVer -eq \$PythonVersion)' "$au"
    # After installing, too: the throw is what makes it a check rather than a hope.
    grep -q "not the pinned \$PythonVersion" "$au"
}

# A CHECK PLACED BELOW THE REBOOT THAT MAKES ITS ANSWER TRUE. The ordering is the defect, so
# the ordering is what this asserts - line numbers, because nothing else can say "before".
@test "live 2026-10-29: EnableLinkedConnections is read before the reboot" {
    local va="$DR_ROOT/lib/forge/vault-access.ps1"
    local read_at reboot_at
    # Comments excluded, because the comment explaining this fix QUOTES the reboot command
    # and sits above the read - so the prose alone would report the defect as still present.
    read_at=$(grep -nE 'elcQuery = ' "$va" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    reboot_at=$(grep -nE 'shutdown /r /t 0' "$va" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
    [ -n "$read_at" ]
    [ -n "$reboot_at" ]
    [ "$read_at" -lt "$reboot_at" ]
}

# '' is "could not ask", which is not "not set". Reporting the first as the second sent a
# reader off to fix a setting that was already correct - a check that cannot pass.
@test "live 2026-10-29: an unreadable answer is its own case, not a missing value" {
    local va="$DR_ROOT/lib/forge/vault-access.ps1"
    grep -q 'if (-not \$elc) {' "$va"
    grep -q 'could not be read from the guest' "$va"
    grep -q 'UNKNOWN - not absent' "$va"
    # And the real negative still has its own branch, with the value shown.
    grep -q "elseif (\$elc -ne '1')" "$va"
}

# --- 2c: .NET 3.5, the one phase that is off unless asked for -------------------------------

@test "dr-layer provision: --netfx becomes a Windows path" {
    run dr-layer provision base --netfx /mnt/d/iso/sxs --skip-gateway
    [ "$status" -eq 0 ]
    [[ "$(sent)" == *'-NetFxSource D:\iso\sxs'* ]]
}

# The default is the whole decision: a base with no .NET 3.5 is the normal case, because
# its payload is a cab only a person can take out of an ISO.
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

# ONE FLAG, NOT TWO. --skip-netfx would be a second switch for a decision --netfx already
# makes, and two switches for one decision is a pair that can disagree. The refusal must
# say which flag is the real one, or it just reads as "unsupported".
@test "dr-layer provision: --skip-netfx is refused, naming --netfx as the switch" {
    run dr-layer provision base --skip-netfx
    [ "$status" -eq 1 ]
    [[ "$output" == *"already off"* ]]
    [[ "$output" == *"--netfx"* ]]
}

@test "dr-layer: --netfx is refused on the layer verbs" {
    run dr-layer freeze layer-1 --netfx /x/sxs
    [ "$status" -eq 1 ]
    [[ "$output" == *"--netfx belongs to dr-layer provision"* ]]
}

# netfx must NOT have joined the phase list: being in it would mean --skip-netfx is accepted
# again, which is the shape this stage decided against.
@test "dr-layer provision: netfx is not in the skippable phase list" {
    run dr-layer provision base --skip-nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a phase"* ]]
    [[ "$output" != *"netfx"* ]]
}

# --- 2c in the PowerShell, as far as grep can see it ---------------------------------------

@test "stage 2c: the payload is checked before phase 0, not after phase 11" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    # The check sits in the preconditions, so its line number is below phase 0's heading.
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

# The cab goes in from the HOST, which is what lets the check happen up front at all: the
# guest cannot reach the vault until phase 11 has installed a credential and rebooted it.
@test "stage 2c: the cab is pushed into the guest, not fetched from the vault" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q 'Copy-ToGuest @(\$netFxCab.FullName)' "$ps"
    grep -q -- '-Source \$(\$sxs' "$ps"
    # -Share is the guest script's vault route, and provision must not be using it.
    ! grep -q -- '-Share ' "$ps" || return 1
    # And the guest script still HAS that route, for someone running it by hand.
    grep -q "Share    = '\\\\\\\\127.0.0.1\\\\vault'" \
        "$DR_ROOT/lib/forge/guest/install-netfx3.ps1"
}

@test "stage 2c: a failure is reported rather than thrown away with the base" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    # 'not requested' is the off case, and it is SAID - a silently absent row is how someone
    # comes to wonder why Windows asked them for .NET 3.5 later.
    grep -q "Phase 'netfx3' 'not requested'" "$ps"
    # Exit 2 from the guest script is "no payload where I was told to look", which after the
    # precondition can only mean the copy did not arrive. Distinguished from a DISM failure.
    grep -q 'the cab did not arrive in the guest' "$ps"
}

# A --netfx pointing at the WRONG FILE used to be taken on trust: the file was pushed, the
# guest found no *netfx3*.cab beside it, exited 2, and the summary said "the cab did not
# arrive in the guest" about a file that had arrived. The name is checked on this side now.
@test "stage 2c: a file that is not a cab is refused here, not mistaken for a lost copy" {
    local ps="$DR_ROOT/lib/forge/provision.ps1"
    grep -q "if (\$f.Name -like '\*netfx3\*.cab')" "$ps"
    grep -q 'that is not a NetFx3 cab' "$ps"
}
