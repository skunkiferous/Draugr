# lib/forge/common.sh - the Windows bridge the forge needs, and nothing else.
#
# Sourced by bin/dr-forge and by nothing else. That isolation is deliberate (docs/FORGE.md):
# the forge is one person's feature, so no core script may come to depend on it, and
# deleting these two files must leave the rest of Draugr exactly as it was.
#
# WHY A BRIDGE IS UNAVOIDABLE. AppSandbox's HTTP API binds the WINDOWS loopback, and inside
# WSL2 127.0.0.1 is WSL's own. MEASURED: %ProgramData%\AppSandbox\host.json is
# readable over /mnt/c, so the token and port are in hand - and neither 127.0.0.1:8787 nor
# the Windows host address (172.19.192.1 here) accepts a connection. The guest's ssh relay
# port sits on the same loopback, so guest commands cannot be dialled from here either.
#
# So every fact about the forge comes from a process on the Windows side. powershell.exe is
# reachable from WSL, which makes it the only door, and lib/forge/probe.ps1 is what goes
# through it. dr-forge is therefore a FRONT END over Windows-side work, not a reimplementation
# of it - a conclusion forced by the measurement rather than chosen.
#
# shellcheck shell=bash

# This file's own directory, so probe.ps1 beside it can be found without the caller having
# to say where it is. readlink -f first, because install.sh links bin/dr* into ~/.local/bin
# and through a link BASH_SOURCE is the LINK - the same reason every bin/dr-* does this.
# DR_ROOT is NOT available here: that is a test-harness variable, set by tests/helper.bash
# and by nothing in the shipped code.
_dr_forge_lib=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

# The configured VM, or a refusal. This is the opt-in gate: with DRAUGR_FORGE empty there is
# no forge, which is the right answer for almost everyone, and dr-forge must then do nothing
# at all rather than guess at a VM it found lying around.
# CALL THIS DIRECTLY, never as $(dr_forge_require_vm). It is a check, not a getter, for a
# measured reason: when it was both - printing the VM and dying when there was none -
# every caller wrote `vm=$(...)`, which runs it in a SUBSHELL, so its exit ended the
# subshell and left the script running with an empty VM and an exit status of 0. A refusal
# that reports success is worse than no check at all. Read $DRAUGR_FORGE yourself after it
# returns.
dr_forge_require_vm() {
    if [ -n "${DRAUGR_FORGE:-}" ]; then return 0; fi

    # AN UNTRUSTED CONFIG FILE IS NOT AN ABSENT ONE, and saying "it is empty" when a layer was
    # skipped is how a reader ends up checking their own spelling. MEASURED: the key
    # was set correctly in .draugr.conf and this reported it unset, because .draugr.conf is
    # shell code - Draugr hashes it and stops sourcing it after any edit until dr-trust accepts
    # the new contents, so ADDING the key is what stopped the file being read. lib/common.sh
    # warns about precisely this where DR_UNTRUSTED is declared; dr-config has always said it
    # out loud, and this had to learn to.
    if [ "${#DR_UNTRUSTED[@]}" -gt 0 ]; then
        dr_error "DRAUGR_FORGE is unset - but a config file was NOT sourced, because it is untrusted:"
        local f
        for f in "${DR_UNTRUSTED[@]}"; do
            printf '  %s%s%s\n' "$_DR_BOLD" "$f" "$_DR_OFF" >&2
        done
        printf '  Anything set there is invisible, DRAUGR_FORGE included. That is almost\n' >&2
        printf '  certainly why: editing the file is what revoked its trust.\n' >&2
        printf '  Review it, then:  dr-trust %s\n' "${DR_UNTRUSTED[0]}" >&2
        exit 1
    fi

    # Genuinely unset, with every config layer read. The dr-trust line is mentioned anyway,
    # because the next thing this reader does is edit .draugr.conf - and that edit is what
    # revokes its trust, which would otherwise bring them straight back here.
    dr_die "no forge is configured." \
        "DRAUGR_FORGE names the VM, and it is empty - so there is nothing to act on." \
        "Set it in .draugr.conf (or ~/.config/draugr/config) to the VM's name, e.g." \
        "  DRAUGR_FORGE=layer-3-myproject" \
        "then run dr-trust on that file - editing it is what makes Draugr stop reading it." \
        "If you do not know what the forge is, you do not need it: see docs/FORGE.md."
}

# A spelling of a file in this repository that a Windows process can open.
#
# Two forms, because Draugr can be installed on either side. A checkout under /mnt/<drive>
# has a plain Windows path; one on WSL's own ext4 has none, and reaches Windows only through
# the \\wsl.localhost redirector - which PowerShell reads perfectly well, so there is no
# reason to refuse that install. dr_path_win is strict on purpose and says so by failing,
# which is exactly the signal to fall back.
dr_forge_win_path() {
    local p=$1 w
    if w=$(dr_path_win "$p" 2>/dev/null); then printf '%s' "$w"; return 0; fi
    if w=$(dr_path_win_kit "$p" 2>/dev/null); then printf '%s' "$w"; return 0; fi
    dr_die "cannot work out a Windows spelling for $p" \
        "The forge needs one: AppSandbox lives on the Windows side of the boundary."
}

# Facts from the Windows side, into DR_FORGE[].
#
# probe.ps1 is invoked with -File and answers in key=value lines. Both halves of that matter.
# -File, because a -Command string from here crosses bash, WSL's argv translation and
# PowerShell's own parser, and every quote loses a layer somewhere; draugr-gateway learned
# that expensively and settled on -File throughout. key=value, because it is the one shape
# bash can read without a parser of its own.
#
# $1 = the VM. Pass --deep as $2 to add the two checks that reach into the guest over ssh.
dr_forge_probe() {
    local vm=$1 deep=${2:-} ps args line k v
    ps=$(dr_forge_win_path "$_dr_forge_lib/probe.ps1")

    # Declared by the caller, cleared here: a second probe in one run must not inherit the
    # first one's answers, or a fact that stopped being reported would appear to persist.
    DR_FORGE=()

    args=(-NoProfile -ExecutionPolicy Bypass -File "$ps" "$vm")
    [ "$deep" = "--deep" ] && args+=(-Deep)

    # stderr is dropped rather than merged: PowerShell writes progress and warnings there,
    # and a stray line would be parsed as a fact. A probe that cannot run at all shows up as
    # an empty array, which the caller reports as such.
    while IFS= read -r line; do
        case "$line" in
            *=*) k=${line%%=*}; v=${line#*=}; DR_FORGE["$k"]=$v ;;
        esac
    done < <(powershell.exe "${args[@]}" 2>/dev/null | tr -d '\r')

    [ ${#DR_FORGE[@]} -gt 0 ]
}

# Is the forge's VM running? The far-end liveness question that dr_sandbox_exists asks about a
# mound, answered for a VM. Called from lib/common.sh, which loads this file on demand.
#
# SELF-CONTAINED on purpose: the caller has not declared DR_FORGE and must not have to, so this
# reads probe.ps1's answer directly instead of going through dr_forge_probe.
#
# A WINDOWS SIDE THAT CANNOT BE REACHED ANSWERS "no", rather than dying. This is a gate, and
# the honest answer when there is no powershell.exe - or no Windows spelling for this
# checkout - is that the far end is not there. The command that asked then refuses in its own
# words, which beats a plumbing error raised from inside a library. dr_forge_win_path is
# deliberately not used: it dr_die()s, and a gate must be allowed to answer "no".
dr_forge_far_end_running() {
    local vm=$1 ps line running='' pin=''
    command -v powershell.exe >/dev/null 2>&1 || return 1
    ps=$(dr_path_win "$_dr_forge_lib/probe.ps1" 2>/dev/null) ||
        ps=$(dr_path_win_kit "$_dr_forge_lib/probe.ps1" 2>/dev/null) || return 1
    # Both facts out of ONE probe, last value winning - the way dr_forge_probe reads them into
    # its array. This used to return on the first `vm_running=yes` line it saw, which is why
    # tests/forge.bats's probe_with removes a key before overriding it.
    while IFS= read -r line; do
        case "$line" in
            vm_running=*) running=${line#*=} ;;
            fwd_vm=*)     pin=${line#*=} ;;
        esac
    done < <(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" "$vm" 2>/dev/null | tr -d '\r')
    # EVERY CALLER'S REFUSAL IS THE SAME TWO LINES - "<name> does not exist" and "Create it
    # with: dr-up" - and for a forge both are wrong: the VM exists, and dr-up starts a MOUND.
    # Fixing that at fourteen call sites would be fourteen places to keep in step, so the
    # reason is said here instead, immediately above whatever generic line follows.
    if [ "$running" != yes ]; then
        dr_warn "the forge VM '$vm' is not running, so it cannot be a far end yet."
        dr_info "  Start it with:  dr-forge up   (dr-up starts a mound, and this is a VM)"
        return 1
    fi

    # RUNNING IS NOT ENOUGH: THE FORWARD HAS TO BE THIS VM'S. Everything that treats the forge
    # as a far end reaches it through an ssh alias whose HostName is host.docker.internal and
    # whose port is 18022 - for every VM. MEASURED, `ssh -G` on two of them:
    #
    #   test          hostname host.docker.internal  port 18022
    #   ue-427-test   hostname host.docker.internal  port 18022
    #
    # Byte-identical. The VM's name lives only in the `Host` line used for the lookup and is
    # dropped at the first hop, so what answers is whichever VM the SUPERVISOR serves. 18022 is
    # pinned deliberately - it is what lets the mound carry one stable rule instead of one per
    # VM - and this is the price. A mound has no such gap: its route is `sbx ssh proxy %n`, so
    # the name travels to the resolver, which is why nothing here applies to the mound branch.
    #
    # Measured the same day: doctor reported "ok 10 WSL reaches the VM - a command ran over the
    # alias" for a STOPPED 'ue-427-test', because the command ran in 'test'. The same confusion
    # on this path sends a dr-data push into the wrong guest.
    #
    # AN UNREADABLE PIN REFUSES HERE, and that differs from doctor's link 7 on purpose. Link 7
    # treats unknown as a pass so a session-0 supervisor it cannot inspect does not nag about a
    # forge that is fine. This gate governs WRITING FILES INTO A VM, where the cost of guessing
    # wrong is unrecoverable, so it wants the pin stated rather than assumed. Draugr's own
    # supervisor writes the claim file that answers this, so unreadable means something is
    # genuinely unidentified.
    case "$pin" in
        '')
            dr_warn "'$vm' is running, but nothing is holding the 18022 forward."
            dr_info "  That forward is the only route to it, so there is no far end to reach."
            dr_info "  Bring it up with:  dr-forge up"
            return 1 ;;
        unreadable)
            dr_warn "'$vm' is running, but which VM holds 127.0.0.1:18022 cannot be read."
            dr_info "  Refusing rather than guessing: that one port is the route to EVERY forge"
            dr_info "  VM, so a wrong guess writes into another guest, which does not undo."
            dr_info "  A supervisor restart makes it say which VM it serves:  dr-forge up"
            return 1 ;;
    esac
    # Case-insensitive, like the guest-name check in bin/dr-forge: Windows does not distinguish
    # them, and refusing over capitalisation alone would be a refusal nobody could act on.
    if [ "${pin,,}" != "${vm,,}" ]; then
        dr_warn "'$vm' is running, but 127.0.0.1:18022 serves '$pin'."
        dr_info "  Every command that reaches a forge VM goes through that one port, so '$vm' is"
        dr_info "  not addressable from here - a push would land in '$pin'. Anything below"
        dr_info "  saying it \"does not exist\" means this, not a missing VM."
        dr_info "  Point the supervisor at it:  DRAUGR_FORGE=$vm dr-forge up"
        return 1
    fi
    return 0
}

# The ssh alias that reaches a forge VM: one suffixed name per VM, all of them served by the
# single `Host *.forge` block dr-setup writes. See dr_sandbox_ssh_host in lib/common.sh for why
# the suffix is spelled in both files rather than shared between them.
dr_forge_alias_host() { printf '%s.forge' "$1"; }

# What ssh would use for the forge's alias, as "key value" lines.
#
# `ssh -G <host>` prints the configuration ssh WOULD apply - every Host block, Match and Include
# resolved - and connects to nothing. That makes it an effect check on the thing that actually
# decides where git goes, instead of grepping one file that may not even be the file ssh reads.
#
# WITH NO MATCHING BLOCK ssh still answers, echoing the name back as `hostname` and naming no
# proxy. That is how "undefined" is recognised here: a bare name, and no route through the
# mound. There is no route from WSL to the VM without one, so a missing alias is a missing link
# rather than a style preference.
dr_forge_ssh_alias() {
    local vm=$1 line
    command -v ssh >/dev/null 2>&1 || return 1
    while IFS= read -r line; do
        case "$line" in
            hostname\ *|port\ *|user\ *|proxycommand\ *|proxyjump\ *|identityfile\ *)
                printf '%s\n' "$line" ;;
        esac
    done < <(ssh -G "$(dr_forge_alias_host "$vm")" 2>/dev/null)
}

# Can WSL actually reach the guest over that alias? The whole chain in one question:
# WSL -> the mound's ProxyCommand -> the host's pinned port -> the guest's sshd.
dr_forge_alias_works() {
    local vm=$1 out
    command -v ssh >/dev/null 2>&1 || return 1
    # HostKeyAlias, because the pinned port is shared by every guest ever served and
    # known_hosts keeps one entry per address: without it the second guest is refused with
    # "REMOTE HOST IDENTIFICATION HAS CHANGED" and this reads as a dead alias. docs/FORGE.md.
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new \
              -o "HostKeyAlias=draugr-$vm" \
              "$(dr_forge_alias_host "$vm")" 'cmd /c echo DRAUGR_WSL_OK' 2>/dev/null) || return 1
    case "$out" in *DRAUGR_WSL_OK*) return 0 ;; esac
    return 1
}

# A fact, or a default. Reading a missing key from an associative array under `set -u` is an
# error, so every read goes through here rather than being spelled out at each use.
dr_forge_fact() {
    local k=$1 fallback=${2:-}
    printf '%s' "${DR_FORGE[$k]:-$fallback}"
}

# Run a command inside the guest, and return the GUEST's exit code.
#
# THE COMMAND IS WRAPPED AND BASE64'D HERE, which is the whole reason this is a function and
# not a line at the call site.
#
# The wrapper exists because `powershell -EncodedCommand` exits 0 for a command that plainly
# failed: PowerShell's own exit code is 0 unless something calls `exit` or throws, so a failing
# cmdlet and a missing file both come back as success. Shipping that would repeat the fault
# this project has already had once - a refusal that reports success is worse than no check at
# all - so the wrapper captures BOTH signals the guest has, in the one order that works:
# $LASTEXITCODE for a native command, $? for a cmdlet, each read before anything else can
# overwrite it. $LASTEXITCODE is zeroed first so a stale value from an earlier statement cannot
# be reported as this command's.
#
# The base64 is UTF-16LE because that is what -EncodedCommand expects, and it is what makes
# the whole thing parser-proof: see lib/forge/guest.ps1 for the five parsers it crosses, two
# of which are measured to damage ordinary quoting.
#
# $1 = the VM, then the command and its arguments. They are joined with single spaces and run
# as ONE PowerShell command line - argv is not preserved, and pretending otherwise would be
# a lie about what survives the crossing.
dr_forge_exec() {
    local vm=$1; shift
    local cmd="$*" ps pre post wrapped b64

    command -v iconv >/dev/null 2>&1 || dr_die "iconv is needed to encode the command for the guest."
    command -v base64 >/dev/null 2>&1 || dr_die "base64 is needed to encode the command for the guest."
    ps=$(dr_forge_win_path "$_dr_forge_lib/guest.ps1")

    # Quoted heredocs, so every $ below belongs to the GUEST's PowerShell and bash expands
    # none of it.
    pre=$(cat <<'DR_PS_PRE'
$ProgressPreference = 'SilentlyContinue'
# SilentlyContinue rather than Continue, and the reason is measured: PowerShell SERIALISES its
# error stream as CLIXML whenever stderr is not a console, so a cmdlet error arrives as
# <Objs Version="1.1.0.1">...<S S="Error">Cannot find path ...</S> with _x000D__x000A_ for
# every newline. -OutputFormat Text fixes native stderr but not this. So nothing is written to
# that stream at all: the errors are collected and written below, as text, straight to the
# process's own stderr handle, where nothing reformats them. The cost is ordering - they
# arrive after the output rather than interleaved with it.
$ErrorActionPreference = 'SilentlyContinue'
$global:LASTEXITCODE = 0
$Error.Clear()
DR_PS_PRE
)
    post=$(cat <<'DR_PS_POST'
$ok = $?; $code = $LASTEXITCODE
if ($Error.Count) { for ($i = $Error.Count - 1; $i -ge 0; $i--) { [Console]::Error.WriteLine($Error[$i].ToString()) } }
if ($code) { exit $code }
if (-not $ok) { exit 1 }
exit 0
DR_PS_POST
)
    wrapped=$(printf '%s\n%s\n%s\n' "$pre" "$cmd" "$post")
    # tr, not `base64 -w0`: -w is a GNU extension, and this has to work wherever Draugr does.
    b64=$(printf '%s' "$wrapped" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')

    # stderr is NOT dropped here, unlike dr_forge_probe: this is the guest's own output, and
    # swallowing half of it would make a failing command look like a silent one.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode exec -Vm "$vm" -Encoded "$b64"
}

# Copy a file or directory in or out of the guest, over the same ssh relay.
#
# $1 = the VM, $2 = push or pull, $3 = source, $4 = destination.
#
# ONE PATH IS TRANSLATED AND THE OTHER IS NOT, which is the only subtlety here: the local side
# has to be respelled for a Windows process (dr_forge_win_path), and the guest side is already
# a Windows path and must be passed through untouched.
#
# For pull, the local side is a DESTINATION that need not exist yet, and dr_path_win resolves
# real paths - so its parent is translated and the basename appended afterwards.
dr_forge_copy() {
    local vm=$1 mode=$2 src=$3 dst=$4
    local ps lwin remote dir base
    ps=$(dr_forge_win_path "$_dr_forge_lib/guest.ps1")

    # THE LOCAL PATH IS MADE ABSOLUTE FIRST, and skipping that was a real bug: MEASURED
    #, `dr-forge push guest/install-tunnel-key.ps1 ...` from inside the repo became
    # \\wsl.localhost\Ubuntuguest\install-tunnel-key.ps1 - the distro name and the path run
    # together, because dr_path_win_kit formats \\wsl.localhost\<distro><path> and relies on the
    # path's leading "/" to separate them. A relative path has none. The existence check above
    # passed regardless, since bash resolved it against the CWD, so the only sign was a Windows
    # path with two names fused in the middle of it.
    #
    # Which side is local differs between the two, and each refuses early for its own reason:
    # a source that is not there, or a destination directory that is not.
    if [ "$mode" = push ]; then
        [ -e "$src" ] || dr_die "nothing to push: $src does not exist."
        src=$(readlink -f "$src")
        lwin=$(dr_forge_win_path "$src")
        remote=$dst
    else
        remote=$src
        dir=$(dirname "$dst")
        base=$(basename "$dst")
        [ -d "$dir" ] || dr_die "cannot pull into $dst: $dir is not a directory."
        # Absolute for the same reason as push, and the parent rather than the whole path
        # because the destination file need not exist yet.
        dir=$(readlink -f "$dir")
        lwin="$(dr_forge_win_path "$dir")\\$base"
    fi

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode "$mode" -Vm "$vm" -Local "$lwin" -Remote "$remote"
}

# powershell.exe has to be findable, and when it is not, the reason is almost always that
# this is not a WSL shell at all - so say that rather than "command not found".
dr_forge_require_windows() {
    command -v powershell.exe >/dev/null 2>&1 || dr_die \
        "powershell.exe is not on PATH, so the Windows side cannot be reached." \
        "The forge is an AppSandbox VM on Windows; dr-forge has to run in WSL on that host." \
        "If this IS WSL, check that /mnt/c/Windows/System32 is on PATH (interop enabled)."
}

# vm.ps1: start the VM, stop it, or bring its tunnel up.
#
# $1 = the mode, $2 = the VM, and anything after that is passed through as further arguments.
#
# OUTPUT IS NOT SWALLOWED, unlike dr_forge_probe's. These waits run for minutes, and the
# progress lines are the only account of what is being waited for. The CRs are stripped
# because PowerShell ends every line with one and a stray CR mangles a terminal; the exit code
# survives the pipe because dr-forge runs under `set -o pipefail`, which reports the rightmost
# non-zero status - powershell's, since tr does not fail.
dr_forge_vm() {
    local mode=$1 vm=$2; shift 2
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/vm.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode "$mode" -Vm "$vm" "$@" 2>&1 | tr -d '\r'
}

# daemon.ps1. Separate from dr_forge_vm because it takes no VM: it is the daemon's own
# lifecycle, which is what every dr-layer verb that rewrites vms.cfg needs taken down first.
dr_forge_daemon() {
    local mode=$1
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/daemon.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" -Mode "$mode" 2>&1 | tr -d '\r'
}

# rm.ps1, in whichever of its two modes. Separate from dr_forge_vm for the same reason init is:
# deleting a VM is not a lifecycle transition, and the inspection half has to be callable on its
# own so the caller can show the blast radius before asking anybody to confirm it.
dr_forge_rm_vm() {
    local mode=$1 vm=$2
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/rm.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode "$mode" -Vm "$vm" 2>&1 | tr -d '\r'
}

# init.ps1, called the way dr_forge_vm calls vm.ps1 - see there for why the CRs are stripped
# and how the exit code survives the pipe. A function of its own because init takes no -Mode:
# it has one job, and giving it a mode would invite a second.
dr_forge_init_vm() {
    local vm=$1; shift
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/init.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" -Vm "$vm" "$@" 2>&1 | tr -d '\r'
}

# snap.ps1: the forge's one baseline, and the way back to it. A -Mode function like rm's, and
# for the same reason - a verb that DISCARDS has to be describable before it acts, so the
# read-only mode has to be callable on its own. Why there is only ever one baseline is the
# snapshot bug, explained in snap.ps1's header and docs/FORGE.md, "Backup and rollback".
dr_forge_snap() {
    local mode=$1 vm=$2; shift 2
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/snap.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode "$mode" -Vm "$vm" "$@" 2>&1 | tr -d '\r'
}

# The host port the VM's only way out arrives on. The guest's proxy settings point at its own
# 127.0.0.1:3128, and lib/forge/tunnel.ps1 reverse-forwards that to this port on the host, where
# the gateway mound publishes its proxy. Draugr already hardcoded it in probe.ps1 and in
# doctor's link 6; naming it once is better than a fourth literal.
_DR_FORGE_PROXY_PORT=18888

# Is THIS repository's mound the gateway - the one that publishes the port above?
#
# That is what makes a mound a gateway, and DRAUGR_PORTS is where a repository says it. A
# DECLARED FACT, checked without starting anything, which matters because this is asked
# precisely when the mound is down.
#
# IT USED TO LOOK FOR A SCRIPT INSIDE THE GATEWAY DIRECTORY, and that was wrong twice over: it
# made Draugr depend on another project's directory layout, and the supervisor now lives here
# (lib/forge/tunnel.ps1), so the file is not there to find. Nor does anything need to work out
# WHICH required repository is the gateway any more - `dr-dep up` brings up everything this one
# requires, the gateway among them, so the only question left is whether the gateway is US.
dr_forge_publishes_proxy() {
    local entry
    local -a list
    # Unquoted word splitting is the point: DRAUGR_PORTS is a space-separated list, spelled
    # "[addr:]hostport:moundport" per entry, so the host port is the field before the last.
    read -ra list <<< "${DRAUGR_PORTS:-}"
    for entry in "${list[@]+"${list[@]}"}"; do
        case "$entry" in
            "$_DR_FORGE_PROXY_PORT":*|*:"$_DR_FORGE_PROXY_PORT":*) return 0 ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# The gateway, generated - docs/FORGE.md, "The gateway, generated: dr-forge gateway"
#
# The gateway is nearly all mechanism: tinyproxy with no destination filtering, the keeper
# session, the SMB share, and a deny list that narrows sbx's ~190 machine-wide defaults to
# the hosts the VM's tools were SEEN to use. Only three things in it are personal, and they
# are the arguments below. So it is generated from share/gateway.example/ and regenerated
# when the work changes, rather than kept as a repository anybody maintains.
# ---------------------------------------------------------------------------

# "<path in the template>:<path in the generated gateway>", in the order they are reported.
#
# NO .gitignore, deliberately: the gateway is a data-only repository, and create-data-only
# writes that file itself, unconditionally, as "*" and nothing else. A copy here would be
# clobbered by the first command that created the repository.
_DR_FORGE_GW_FILES=(
    'draugr.conf.in:.draugr.conf'
    'README.md.in:README.md'
    'kit/spec.yaml:.draugr/kit/spec.yaml'
    'hooks/post-up:.draugr/hooks/post-up'
    'kits/base/spec.yaml:kits/base/spec.yaml'
    'kits/unreal/spec.yaml:kits/unreal/spec.yaml'
)

# One host directory, in either spelling, into _dr_gw_wsl and _dr_gw_mound.
#
# NOT a getter, and the reason is the one dr_forge_require_vm carries: a refusal inside
# $(...) ends the subshell and leaves the caller running. So this returns 1 and the caller
# does the dying.
dr_forge_gw_path() {
    local raw=$1
    _dr_gw_wsl=$raw
    # A Windows spelling is accepted because that is how these paths are written everywhere
    # else about the forge - D:\VaultHolder in a note, /mnt/d/VaultHolder in a config.
    case "$raw" in
        [A-Za-z]:[\\/]*|[A-Za-z]:) _dr_gw_wsl=$(dr_path_from_win "$raw") ;;
    esac
    _dr_gw_wsl=${_dr_gw_wsl%/}
    # A mount lands at the MIRRORED path, so this is the whole of the conversion - and it
    # refuses anything that is not on a Windows drive, which DRAUGR_MOUNTS requires anyway.
    _dr_gw_mound=$(dr_path_mound "$_dr_gw_wsl") || return 1
}

# Render one template file. Substitution is six fixed placeholders, done with bash's own
# ${x//a/b} rather than sed or envsubst: a path holding "&" or "|" breaks a sed replacement,
# and nothing in a template should ever be able to run.
dr_forge_gw_render() {
    local file=$1 sandbox=$2 mounts=$3 vault=$4 scratch=$5 ports=$6 text
    text=$(cat "$file")
    text=${text//@VM@/${DRAUGR_FORGE:-}}
    text=${text//@SANDBOX@/$sandbox}
    text=${text//@MOUNTS@/$mounts}
    text=${text//@VAULT_MOUND@/$vault}
    text=${text//@SCRATCH_MOUND@/$scratch}
    text=${text//@PORTS@/$ports}
    printf '%s\n' "$text"
}

# dr_forge_gateway_new <dir> <vault> <scratch> <force>
#
# Writes the tree and nothing else: it starts no mound, creates no repository and touches no
# password file. Exactly one gateway can run, so generating one while another is up has to be
# safe, and starting it is a separate decision.
dr_forge_gateway_new() {
    local dir=$1 vault=$2 scratch=$3 force=$4
    local tpl="$DRAUGR_SHARE/gateway.example"

    [ -d "$tpl" ] || dr_die "this checkout is missing share/gateway.example/." \
        "That directory is the gateway template, and nothing can be generated without it."

    # The VM's name goes into the generated config, so the ordinary gate applies.
    dr_forge_require_vm

    # Both directories are optional, and a gateway without them still proxies - which is
    # the useful half on a machine that has no vault yet. post-up skips its share step when
    # the path is empty rather than serving a directory that is not there.
    local vault_wsl='' vault_mound='' scratch_wsl='' scratch_mound='' mounts=''
    if [ -n "$vault" ]; then
        dr_forge_gw_path "$vault" || dr_die \
            "--vault must name a directory on a Windows drive: $vault" \
            "A mound can mount only a Windows path, and it lands at the mirrored path:" \
            "/mnt/d/VaultHolder on the host is /d/VaultHolder inside the mound." \
            "Either spelling is fine - /mnt/d/VaultHolder or D:\\VaultHolder."
        vault_wsl=$_dr_gw_wsl vault_mound=$_dr_gw_mound
    fi
    if [ -n "$scratch" ]; then
        dr_forge_gw_path "$scratch" || dr_die \
            "--scratch must name a directory on a Windows drive: $scratch" \
            "See --vault above: /mnt/d/ForgeScratch or D:\\ForgeScratch."
        scratch_wsl=$_dr_gw_wsl scratch_mound=$_dr_gw_mound
    fi

    # :ro on the vault and not on the scratch is the whole point of there being two. The VM
    # must not be able to write to the vault, and the mount is what enforces that - the
    # kernel refuses the write however Samba is configured.
    [ -z "$vault_wsl" ]   || mounts="$vault_wsl:ro"
    [ -z "$scratch_wsl" ] || mounts="${mounts:+$mounts }$scratch_wsl"

    # THE SMB PORT IS PUBLISHED ONLY IF THERE IS A SHARE TO REACH THROUGH IT, and it is
    # gated on the VAULT path exactly as post-up gates the share itself - a scratch with
    # no vault serves nothing, because the hook's whole share block is behind the vault
    # test. Keep the two in step: a port published past an absent share is a listener on
    # the host that answers for nothing, and dr-layer provision's vault phase reads that
    # listener to decide whether to install a credential and reboot the guest.
    #
    # 18888 is unconditional, and the config's own comment says why: it is the declared
    # fact that identifies this repository as the gateway, answerable while all is down.
    local ports='127.0.0.1:18888:8888'
    [ -z "$vault_wsl" ] || ports="$ports 127.0.0.1:18445:445"

    # A NON-EMPTY DIRECTORY THAT IS NOT ALREADY A GATEWAY IS REFUSED, because a mistyped path
    # is what that looks like. A gateway is generated into an empty directory or over a
    # previous gateway, and "its config publishes 18888" is what identifies one.
    #
    # MEASURED while building this, and the reason the test is emptiness rather than the
    # config: the first version only looked at an existing .draugr.conf, so generating into
    # Draugr's OWN checkout - which has none - wrote a config, two kit specs and a hook into
    # it instead of refusing. It kept the README, which is the only reason that was obvious.
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] \
       && ! grep -qs '18888' "$dir/.draugr.conf"; then
        [ -n "$force" ] || dr_die \
            "$dir is not empty, and what is in it is not a gateway." \
            "A gateway is generated into a new directory, or over a previous gateway - and a" \
            "gateway is the mound that publishes 127.0.0.1:18888, which this one's" \
            "$(if [ -f "$dir/.draugr.conf" ]; then echo '.draugr.conf does not'; else echo 'missing .draugr.conf cannot'; fi) do." \
            "So this is probably not the directory you meant. If it is:" \
            "  dr-forge gateway $dir -y"
    fi

    mkdir -p "$dir/.draugr/kit" "$dir/.draugr/hooks" "$dir/kits/base" "$dir/kits/unreal"

    # The mound's name, from the directory, with one collapse: a gateway directory is usually
    # called draugr-gateway-something, and dr_sandbox_name prefixes "draugr-" unconditionally,
    # so the name would come out as draugr-draugr-gateway. Collapsed HERE rather than in
    # dr_sandbox_name, because changing that would rename the mound of every existing project
    # whose folder already begins with "draugr-".
    local sandbox
    sandbox=$(dr_sandbox_name "$(cd "$dir" && pwd)")
    sandbox=${sandbox/#draugr-draugr-/draugr-}

    # One pass, three outcomes per file - written, already current, or kept because it
    # differs - counted as it goes so the summary states what happened rather than what was
    # attempted.
    local entry src rel dst text had='' created=0 current=0
    local -a kept=()
    for entry in "${_DR_FORGE_GW_FILES[@]}"; do
        src="$tpl/${entry%%:*}"
        rel=${entry#*:}
        dst="$dir/$rel"
        [ -f "$src" ] || dr_die "the gateway template is incomplete: ${entry%%:*} is missing." \
            "Looked in $tpl."

        text=$(dr_forge_gw_render "$src" "$sandbox" "$mounts" "$vault_mound" "$scratch_mound" "$ports")

        # A placeholder nobody substituted would ship as "@NAME@" into a config that then
        # half works. The template gaining one is the likely cause, so name it.
        case "$text" in
            *@[A-Z]*[A-Z]@*) dr_die "the template has a placeholder this version cannot fill:" \
                "$(printf '%s' "$text" | grep -o '@[A-Z_][A-Z_]*@' | sort -u | tr '\n' ' ')" \
                "in ${entry%%:*}. share/gateway.example and lib/forge/common.sh disagree." ;;
        esac

        # IDENTICAL IS NOT THE SAME AS ABSENT, and neither is a refusal. Regenerating is the
        # normal case - the allowlist changes with the kind of work, not with the VM - so a
        # file that already says what the template says is left alone silently, and one that
        # does not is kept, because the difference is somebody's edit until they say otherwise.
        if [ -f "$dst" ]; then
            if [ "$text" = "$(cat "$dst")" ]; then
                printf '  %-24s %salready current%s\n' "$rel" "$_DR_DIM" "$_DR_OFF" >&2
                current=$(( current + 1 ))
                continue
            fi
            if [ -z "$force" ]; then
                printf '  %-24s %sdiffers - kept%s\n' "$rel" "$_DR_YELLOW" "$_DR_OFF" >&2
                kept+=("$rel")
                continue
            fi
            had=yes
        fi

        # WITH the newline. $text has none: dr_forge_gw_render ends in printf '%s\n' and
        # the command substitution that captured it stripped every trailing newline, which
        # is what $(...) does. So a bare printf '%s' here wrote six files that each ended
        # mid-line - visible only as diffs whose two sides are identical, and as "\ No
        # newline at end of file" in anything that reports it.
        #
        # The "already current" test above is unaffected either way, which is why this hid:
        # $(cat "$dst") strips the newline too, so a file with one and a file without one
        # both compare equal to $text. Regenerating an existing gateway therefore still
        # says "already current" rather than suddenly reporting a difference.
        printf '%s\n' "$text" > "$dst"
        # Not "${had:+overwritten}${had:-written}": with had=yes that prints BOTH, because
        # :- returns the value of a variable that is set. It read "overwrittenyes".
        if [ -n "$had" ]; then
            printf '  %-24s %s\n' "$rel" overwritten >&2
        else
            printf '  %-24s %s\n' "$rel" written >&2
        fi
        had=''
        created=$(( created + 1 ))

        # The hook must be executable or dr_hook skips it IN SILENCE: no keeper, no proxy,
        # no share, and no message either. share/ cannot carry the bit (every example in it
        # is deliberately non-executable), so it is set here.
        case "$rel" in
            .draugr/hooks/post-up) chmod 755 "$dst" ;;
        esac

        # Trust, for the two files that are read AS CODE - the config is sourced and the hook
        # runs on the host as you. Granted because Draugr wrote them and you asked it to,
        # which is the same ground create-data-only stands on for the config it writes. A
        # file left in place because it differs is NOT trusted here: nobody has read it.
        case "$rel" in
            .draugr.conf|.draugr/hooks/post-up) dr_trust_add "$dst" ;;
        esac
    done

    # Kept files are reported together at the end rather than one by one, because the useful
    # unit is "these are yours, here is how to take the template anyway".
    if [ ${#kept[@]} -gt 0 ]; then
        dr_warn "$created written, $current already current, ${#kept[@]} kept as they are."
        printf '  %sYour edits are in those files, so they were not touched. To see what\n' "$_DR_DIM" >&2
        printf '  would change, diff them against the template; to take the template anyway:%s\n' "$_DR_OFF" >&2
        printf '    dr-forge gateway %s -y\n' "$dir" >&2
        return 3
    fi

    dr_ok "gateway in $dir ($created written, $current already current)"
    printf '  %sNothing was started. The mound comes up with dr-forge up in the game\n' "$_DR_DIM" >&2
    printf '  project, through DRAUGR_REQUIRES, or with dr-up from inside %s.%s\n' "$dir" "$_DR_OFF" >&2
}
