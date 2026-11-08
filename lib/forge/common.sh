# lib/forge/common.sh: the Windows bridge that the forge needs, and nothing
# else.
#
# Only bin/dr-forge sources it. That isolation is on purpose (docs/FORGE.md).
# The forge is the feature of one person, so no core script can depend on it. If
# you delete these two files, the rest of Draugr must stay the same.
#
# WHY A BRIDGE IS NECESSARY. The HTTP API of AppSandbox binds the WINDOWS
# loopback, and inside WSL2, 127.0.0.1 is the loopback of WSL. A TEST SHOWED
# THIS. WSL can read %ProgramData%\AppSandbox\host.json through /mnt/c, so it
# has the token and the port. But neither 127.0.0.1:8787 nor the Windows host
# address (172.19.192.1 here) accepts a connection. The ssh relay port of the
# guest is on the same loopback, so this side cannot connect to guest commands
# either.
#
# Thus each fact about the forge comes from a process on the Windows side. WSL
# can run powershell.exe, so that is the only door, and lib/forge/probe.ps1 goes
# through it. Thus dr-forge is a FRONT END for work on the Windows side, not a
# new implementation of it. The test forced that conclusion. It was not a
# choice.
#
# shellcheck shell=bash

# The directory of this file, so that the code finds probe.ps1 next to it, and
# the caller does not have to say where. readlink -f first, because install.sh
# links bin/dr* into ~/.local/bin, and through a link BASH_SOURCE is the LINK.
# Each bin/dr-* does this for the same reason. DR_ROOT is NOT available here. It
# is a variable of the tests. Only tests/helper.bash sets it, and no
# shipped code.
_dr_forge_lib=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

# The configured VM, or a refusal. This is the gate to turn the forge on. With
# an empty DRAUGR_FORGE, there is no forge. That is correct for almost
# everybody. Then dr-forge must do nothing, and must not guess a VM that it
# finds. CALL THIS DIRECTLY, never as $(dr_forge_require_vm). It is a test, not
# a getter, because of a test result. When it was both, it printed the VM, and
# died when there was none. Each caller wrote `vm=$(...)`, and that runs it in a
# SUBSHELL. Its exit ended only the subshell. The script continued with an empty
# VM and an exit status of 0. A refusal that reports success is worse than no
# test. After it returns, read $DRAUGR_FORGE yourself.
dr_forge_require_vm() {
    if [ -n "${DRAUGR_FORGE:-}" ]; then return 0; fi

    # A CONFIGURATION FILE THAT IS NOT TRUSTED IS NOT A MISSING ONE. If the code
    # says "it is empty" for a skipped layer, the reader looks for a spelling
    # error. A TEST SHOWED THIS. The key was correct in .draugr.conf, and this
    # reported it as unset. .draugr.conf is shell code. Draugr hashes it, and
    # after each edit stops to source it until dr-trust accepts the new
    # contents. Thus the NEW key stopped the read of the file. lib/common.sh
    # warns about exactly this where it declares DR_UNTRUSTED. dr-config always
    # said it, and this code had to learn it.
    if [ "${#DR_UNTRUSTED[@]}" -gt 0 ]; then
        dr_error "DRAUGR_FORGE is unset. But a configuration file was NOT sourced, because it is not trusted:"
        local f
        for f in "${DR_UNTRUSTED[@]}"; do
            printf '  %s%s%s\n' "$_DR_BOLD" "$f" "$_DR_OFF" >&2
        done
        printf '  Draugr sees none of its values, DRAUGR_FORGE included. That is almost\n' >&2
        printf '  surely the cause: an edit of the file removed its trust.\n' >&2
        printf '  Read it, then run:  dr-trust %s\n' "${DR_UNTRUSTED[0]}" >&2
        exit 1
    fi

    # Really unset, and the loader read each layer. The message still names
    # dr-trust, because the reader next edits .draugr.conf. That edit removes
    # its trust, and otherwise brings the reader directly back here.
    dr_die "no forge is configured." \
        "DRAUGR_FORGE names the VM, and it is empty. Thus there is nothing to act on." \
        "Set it in .draugr.conf (or ~/.config/draugr/config) to the name of the VM, for example" \
        "  DRAUGR_FORGE=layer-3-myproject" \
        "Then run dr-trust on that file. After an edit, Draugr stops reading it." \
        "If you do not know what the forge is, you do not need it. See docs/FORGE.md."
}

# A path to a file in this repository that a Windows process can open.
#
# Two forms, because you can install Draugr on both sides. A checkout under
# /mnt/<drive> has a plain Windows path. A checkout on the ext4 of WSL has none.
# It reaches Windows only through the \\wsl.localhost redirector. PowerShell
# reads that without problems, so there is no reason to refuse that install.
# dr_path_win is strict on purpose, and fails. That failure is the signal to use
# the second form.
dr_forge_win_path() {
    local p=$1 w
    if w=$(dr_path_win "$p" 2>/dev/null); then printf '%s' "$w"; return 0; fi
    if w=$(dr_path_win_kit "$p" 2>/dev/null); then printf '%s' "$w"; return 0; fi
    dr_die "cannot find a Windows path for $p" \
        "The forge needs one, because AppSandbox is on the Windows side of the boundary."
}

# Facts from the Windows side, into DR_FORGE[].
#
# The code calls probe.ps1 with -File, and it answers in key=value lines. Both
# halves are important. -File, because a -Command string from here goes through
# bash, the argv translation of WSL, and the parser of PowerShell. Each quote
# loses a layer somewhere. draugr-gateway learned that at a high cost, and
# uses -File everywhere. key=value, because bash can read that form without its
# own parser.
#
# $1 = the VM. Give --deep as $2 to add the two tests that go into the guest
# through ssh.
dr_forge_probe() {
    local vm=$1 deep=${2:-} ps args line k v
    ps=$(dr_forge_win_path "$_dr_forge_lib/probe.ps1")

    # The caller declares it, and this code clears it. A second probe in one run
    # must not get the answers of the first. Otherwise a fact that is no longer
    # reported looks current.
    DR_FORGE=()

    args=(-NoProfile -ExecutionPolicy Bypass -File "$ps" "$vm")
    [ "$deep" = "--deep" ] && args+=(-Deep)

    # stderr is discarded, not merged. PowerShell writes progress and warnings
    # there, and the code parses each extra line as a fact. A probe that cannot
    # run gives an empty array, and the caller reports that.
    while IFS= read -r line; do
        case "$line" in
            *=*) k=${line%%=*}; v=${line#*=}; DR_FORGE["$k"]=$v ;;
        esac
    done < <(powershell.exe "${args[@]}" 2>/dev/null | tr -d '\r')

    [ ${#DR_FORGE[@]} -gt 0 ]
}

# Does the VM of the forge run? dr_sandbox_exists asks this question about the
# far end of a mound. This function answers it for a VM. lib/common.sh calls it,
# and loads this file on demand.
#
# INDEPENDENT on purpose. The caller did not declare DR_FORGE, and must not have
# to. Thus this reads the answer of probe.ps1 directly, and does not use
# dr_forge_probe.
#
# A WINDOWS SIDE THAT IS NOT REACHABLE ANSWERS "no", and does not die. This is a
# gate. With no powershell.exe, or no Windows path for this checkout, the
# correct answer is that the far end is not there. The command that asked then
# refuses in its own words. That is better than an internal error from a
# library. dr_forge_win_path is not used, on purpose. It calls dr_die, and a
# gate must be able to answer "no".
dr_forge_far_end_running() {
    local vm=$1 ps line running='' pin=''
    command -v powershell.exe >/dev/null 2>&1 || return 1
    ps=$(dr_path_win "$_dr_forge_lib/probe.ps1" 2>/dev/null) ||
        ps=$(dr_path_win_kit "$_dr_forge_lib/probe.ps1" 2>/dev/null) || return 1
    # Both facts from ONE probe, and the last value wins, as dr_forge_probe
    # reads them into its array. Before, this returned at the first
    # `vm_running=yes` line. That is why probe_with in tests/forge.bats removes
    # a key before it changes it.
    while IFS= read -r line; do
        case "$line" in
            vm_running=*) running=${line#*=} ;;
            fwd_vm=*)     pin=${line#*=} ;;
        esac
    done < <(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" "$vm" 2>/dev/null | tr -d '\r')
    # THE REFUSAL OF EACH CALLER IS THE SAME TWO LINES: "<name> does not exist"
    # and "Create it with: dr-up". For a forge, both are wrong. The VM exists,
    # and dr-up starts a MOUND. A fix at fourteen calls is fourteen places to
    # keep the same. Thus the reason is here, directly above the general line
    # that follows.
    if [ "$running" != yes ]; then
        dr_warn "the forge VM '$vm' does not run, so it cannot be a far end yet."
        dr_info "  Start it with:  dr-forge up   (dr-up starts a mound, and this is a VM)"
        return 1
    fi

    # RUNNING IS NOT ENOUGH. THE FORWARD MUST BE FOR THIS VM. Each command that
    # uses the forge as a far end goes through an ssh alias with HostName
    # host.docker.internal and port 18022, for each VM. A TEST with `ssh -G` on
    # two of them showed this:
    #
    #   test          hostname host.docker.internal  port 18022
    #   ue-427-test   hostname host.docker.internal  port 18022
    #
    # Exactly the same. The name of the VM is only in the `Host` line for the
    # lookup, and the first hop discards it. Thus the VM of the SUPERVISOR
    # answers. 18022 is pinned on purpose. It lets the mound have one stable
    # rule, not one for each VM, and this is the cost. A mound has no such gap.
    # Its route is `sbx ssh proxy %n`, so the name goes to the resolver. That is
    # why nothing here applies to the mound branch.
    #
    # A test on the same day: doctor reported "ok 10 WSL reaches the VM - a
    # command ran over the alias" for a STOPPED 'ue-427-test', because the
    # command ran in 'test'. The same error on this path sends a dr-data push
    # into the wrong guest.
    #
    # A PIN THAT THE CODE CANNOT READ REFUSES HERE. That differs from link 7 of
    # doctor, on purpose. Link 7 treats unknown as a pass, so that it does not
    # warn about a good forge with a session-0 supervisor that it cannot
    # inspect. This gate controls the WRITE OF FILES INTO A VM. A wrong guess
    # there has a cost that you cannot undo. Thus it wants a stated pin, not an
    # assumed one. The own supervisor of Draugr writes the claim file that
    # answers this. Thus "unreadable" means that something is really unknown.
    case "$pin" in
        '')
            dr_warn "'$vm' runs, but nothing holds the 18022 forward."
            dr_info "  That forward is the only route to it, so there is no far end to reach."
            dr_info "  Start it with:  dr-forge up"
            return 1 ;;
        unreadable)
            dr_warn "'$vm' runs, but the code cannot read which VM holds 127.0.0.1:18022."
            dr_info "  A refusal, not a guess. That one port is the route to EACH forge VM, so"
            dr_info "  a wrong guess writes into another guest, and you cannot undo that."
            dr_info "  After a restart, the supervisor says which VM it serves:  dr-forge up"
            return 1 ;;
    esac
    # The comparison ignores case, as the guest-name test in bin/dr-forge does.
    # Windows does not see a difference, and a refusal only for upper or lower
    # case helps nobody.
    if [ "${pin,,}" != "${vm,,}" ]; then
        dr_warn "'$vm' runs, but 127.0.0.1:18022 serves '$pin'."
        dr_info "  Each command for a forge VM goes through that one port, so this side cannot"
        dr_info "  reach '$vm'. A push goes into '$pin'. Each line below that says"
        dr_info "  \"does not exist\" means this, not a missing VM."
        dr_info "  Point the supervisor to it:  DRAUGR_FORGE=$vm dr-forge up"
        return 1
    fi
    return 0
}

# The ssh alias for a forge VM: one name with a suffix for each VM. The one
# `Host *.forge` block that dr-setup writes serves all of them. See
# dr_sandbox_ssh_host in lib/common.sh for why both files write the suffix, and
# do not share it.
dr_forge_alias_host() { printf '%s.forge' "$1"; }

# What ssh uses for the alias of the forge, as "key value" lines.
#
# `ssh -G <host>` prints the configuration that ssh applies, with each Host
# block, Match, and Include resolved, and connects to nothing. Thus it tests the
# effect on the thing that decides where git goes. A grep of one file is weaker,
# because ssh possibly does not read that file.
#
# WITH NO MATCHING BLOCK, ssh still answers. It gives the name back as
# `hostname`, and names no proxy. That is how the code knows "undefined": a bare
# name, and no route through the mound. Without the alias, WSL has no route to
# the VM. Thus a missing alias is a missing link, not a style choice.
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

# Can WSL really connect to the guest through that alias? The whole chain in
# one question: WSL -> the ProxyCommand of the mound -> the pinned port of the
# host -> the sshd of the guest.
dr_forge_alias_works() {
    local vm=$1 out
    command -v ssh >/dev/null 2>&1 || return 1
    # HostKeyAlias, because all guests share the pinned port, and known_hosts
    # keeps one entry for each address. Without it, ssh refuses the second guest
    # with "REMOTE HOST IDENTIFICATION HAS CHANGED", and this looks like a dead
    # alias. See docs/FORGE.md.
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new \
              -o "HostKeyAlias=draugr-$vm" \
              "$(dr_forge_alias_host "$vm")" 'cmd /c echo DRAUGR_WSL_OK' 2>/dev/null) || return 1
    case "$out" in *DRAUGR_WSL_OK*) return 0 ;; esac
    return 1
}

# A fact, or a default. Under `set -u`, a read of a missing key from an
# associative array is an error. Thus each read goes through here.
dr_forge_fact() {
    local k=$1 fallback=${2:-}
    printf '%s' "${DR_FORGE[$k]:-$fallback}"
}

# Run a command inside the guest, and return the exit code of the GUEST.
#
# THE CODE WRAPS THE COMMAND, AND ENCODES IT IN BASE64 HERE. That is the reason
# for a function, and not a line at the call.
#
# The wrapper exists because `powershell -EncodedCommand` exits 0 for a command
# that clearly failed. The exit code of PowerShell is 0 unless something calls
# `exit` or throws. Thus a failed cmdlet and a missing file both return success.
# This project already had that fault once. A refusal that reports success is
# worse than no test. Thus the wrapper captures BOTH signals of the guest, in
# the one order that works: $LASTEXITCODE for a native command, and $? for a
# cmdlet. It reads each one before something else can overwrite it. It sets
# $LASTEXITCODE to zero first, so that an old value from an earlier statement
# cannot look like the value of this command.
#
# The base64 is UTF-16LE, because -EncodedCommand expects that. It also protects
# the command from all parsers. See lib/forge/guest.ps1 for the five parsers on
# the way. Tests showed that two of them damage ordinary quotes.
#
# $1 = the VM, then the command and its arguments. The code joins them with
# single spaces, and runs them as ONE PowerShell command line. argv does not
# stay the same. Any other claim is a lie about what survives the crossing.
dr_forge_exec() {
    local vm=$1; shift
    local cmd="$*" ps pre post wrapped b64

    command -v iconv >/dev/null 2>&1 || dr_die "iconv is needed to encode the command for the guest."
    command -v base64 >/dev/null 2>&1 || dr_die "base64 is needed to encode the command for the guest."
    ps=$(dr_forge_win_path "$_dr_forge_lib/guest.ps1")

    # Quoted heredocs, so that each $ below is for the PowerShell of the GUEST,
    # and bash expands none of them.
    pre=$(cat <<'DR_PS_PRE'
$ProgressPreference = 'SilentlyContinue'
# SilentlyContinue, not Continue, because of a test result. If stderr is
# not a console, PowerShell SERIALIZES its error stream as CLIXML. Thus a
# cmdlet error arrives as <Objs Version="1.1.0.1">...<S S="Error">Cannot find
# path ...</S>, with _x000D__x000A_ for each newline. -OutputFormat Text fixes
# native stderr, but not this. Thus nothing writes to that stream. The code
# collects the errors and writes them below, as text, directly to the stderr
# handle of the process, where nothing changes their format. The cost is the
# order. They arrive after the output, not mixed with it.
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
    # tr, not `base64 -w0`. -w is a GNU extension, and this must work wherever
    # Draugr works.
    b64=$(printf '%s' "$wrapped" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')

    # stderr is NOT discarded here, different from dr_forge_probe. This is the
    # output of the guest. Without half of it, a failed command looks like a
    # silent one.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode exec -Vm "$vm" -Encoded "$b64"
}

# Copy a file or directory into or out of the guest, through the same ssh relay.
#
# $1 = the VM, $2 = push or pull, $3 = source, $4 = destination.
#
# THE CODE TRANSLATES ONE PATH, AND NOT THE OTHER. That is the only detail here.
# The local side needs a new form for a Windows process (dr_forge_win_path). The
# guest side is already a Windows path, and must go without change.
#
# For pull, the local side is a DESTINATION that does not have to exist yet, and
# dr_path_win resolves only real paths. Thus the code translates its parent, and
# adds the basename after that.
dr_forge_copy() {
    local vm=$1 mode=$2 src=$3 dst=$4
    local ps lwin remote dir base
    ps=$(dr_forge_win_path "$_dr_forge_lib/guest.ps1")

    # THE CODE MAKES THE LOCAL PATH ABSOLUTE FIRST. Without that, there was a
    # real bug. A TEST SHOWED THIS. `dr-forge push guest/install-tunnel-key.ps1
    # ...` from inside the repo became
    # \\wsl.localhost\Ubuntuguest\install-tunnel-key.ps1. The distro name and
    # the path were joined, because dr_path_win_kit writes
    # \\wsl.localhost\<distro><path>, and needs the "/" at the start of the path
    # between them. A relative path has none. The test for existence above still
    # passed, because bash resolved it against the CWD. The only sign was a
    # Windows path with two names joined in the middle.
    #
    # The local side differs between the two. Each one refuses early for its own
    # reason: a missing source, or a missing destination directory.
    if [ "$mode" = push ]; then
        [ -e "$src" ] || dr_die "nothing to push: $src does not exist."
        src=$(readlink -f "$src")
        lwin=$(dr_forge_win_path "$src")
        remote=$dst
    else
        remote=$src
        dir=$(dirname "$dst")
        base=$(basename "$dst")
        [ -d "$dir" ] || dr_die "cannot pull into $dst. $dir is not a directory."
        # Absolute, for the same reason as push. The parent, not the whole path,
        # because the destination file does not have to exist yet.
        dir=$(readlink -f "$dir")
        lwin="$(dr_forge_win_path "$dir")\\$base"
    fi

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode "$mode" -Vm "$vm" -Local "$lwin" -Remote "$remote"
}

# The code must find powershell.exe. If it cannot, the reason is almost always
# that this is not a WSL shell. Thus say that, not "command not found".
dr_forge_require_windows() {
    command -v powershell.exe >/dev/null 2>&1 || dr_die \
        "powershell.exe is not on PATH, so the Windows side cannot be reached." \
        "The forge is an AppSandbox VM on Windows. dr-forge must run in WSL on that host." \
        "If this IS WSL, make sure that /mnt/c/Windows/System32 is on PATH (interop on)."
}

# vm.ps1: start the VM, stop it, or start its tunnel.
#
# $1 = the mode, $2 = the VM. The other arguments go to the script without
# change.
#
# THE OUTPUT IS NOT DISCARDED, different from dr_forge_probe. These waits take
# minutes, and only the progress lines tell what the wait is for. The code
# removes the CRs, because PowerShell ends each line with one, and an extra CR
# damages a terminal. The exit code survives the pipe, because dr-forge runs
# under `set -o pipefail`. That reports the rightmost non-zero status, which is
# the status of powershell, because tr does not fail.
dr_forge_vm() {
    local mode=$1 vm=$2; shift 2
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/vm.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode "$mode" -Vm "$vm" "$@" 2>&1 | tr -d '\r'
}

# daemon.ps1. Separate from dr_forge_vm, because it takes no VM. It is the life
# cycle of the daemon. Each dr-layer verb that rewrites vms.cfg needs the daemon
# stopped first.
dr_forge_daemon() {
    local mode=$1
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/daemon.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" -Mode "$mode" 2>&1 | tr -d '\r'
}

# rm.ps1, in one of its two modes. Separate from dr_forge_vm, for the same
# reason as init. The delete of a VM is not a step of the life cycle. The look
# half must be callable alone, so that the caller can show the damage before it
# asks for a confirmation.
dr_forge_rm_vm() {
    local mode=$1 vm=$2
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/rm.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode "$mode" -Vm "$vm" 2>&1 | tr -d '\r'
}

# init.ps1, called as dr_forge_vm calls vm.ps1. See there for why the code
# removes the CRs, and how the exit code survives the pipe. Its own function,
# because init takes no -Mode. It has one job, and a mode invites a second.
dr_forge_init_vm() {
    local vm=$1; shift
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/init.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" -Vm "$vm" "$@" 2>&1 | tr -d '\r'
}

# snap.ps1: the one baseline of the forge, and the way back to it. A -Mode
# function, as for rm, and for the same reason. A verb that DISCARDS must have a
# description before it acts, so the read-only mode must be callable alone. The
# snapshot bug is the reason for only one baseline. The header of snap.ps1 and
# docs/FORGE.md, "Backup and rollback", explain it.
dr_forge_snap() {
    local mode=$1 vm=$2; shift 2
    local ps
    ps=$(dr_forge_win_path "$_dr_forge_lib/snap.ps1")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" \
        -Mode "$mode" -Vm "$vm" "$@" 2>&1 | tr -d '\r'
}

# The host port where the only way out of the VM arrives. The proxy
# configuration of the guest points to its own 127.0.0.1:3128.
# lib/forge/tunnel.ps1 reverse-forwards that to this port on the host, where the
# gateway mound publishes its proxy. Draugr already had it as a fixed value in
# probe.ps1 and in link 6 of doctor. One name is better than a fourth literal.
_DR_FORGE_PROXY_PORT=18888

# Is the mound of THIS repository the gateway, the one that publishes the port
# above?
#
# That port makes a mound a gateway, and a repository declares it in
# DRAUGR_PORTS. A DECLARED FACT, tested without a start. That is important,
# because the code asks this exactly while the mound is down.
#
# BEFORE, IT LOOKED FOR A SCRIPT INSIDE THE GATEWAY DIRECTORY. That was wrong
# two times. Draugr then depended on the directory layout of another project.
# Also, the supervisor is now here (lib/forge/tunnel.ps1), so the file is not
# there. Also, nothing must find WHICH required repository is the gateway now.
# `dr-dep up` starts all requirements of this repository, the gateway too. Thus
# the only question is whether the gateway is US.
dr_forge_publishes_proxy() {
    local entry
    local -a list
    # Unquoted word splitting, on purpose. DRAUGR_PORTS is a list with spaces
    # between entries, and each entry is "[addr:]hostport:moundport". Thus the
    # host port is the field before the last.
    read -ra list <<< "${DRAUGR_PORTS:-}"
    for entry in "${list[@]+"${list[@]}"}"; do
        case "$entry" in
            "$_DR_FORGE_PROXY_PORT":*|*:"$_DR_FORGE_PROXY_PORT":*) return 0 ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# The generated gateway. See docs/FORGE.md, "The gateway, generated: dr-forge
# gateway".
#
# The gateway is almost all mechanism: tinyproxy with no destination filter, the
# keeper session, the SMB share, and a deny list. The deny list makes the ~190
# machine defaults of sbx narrower, to the hosts that the tools of the VM were
# SEEN to use. Only three things in it are personal, and they are the arguments
# below. Thus the code generates it from share/gateway.example/, and generates
# it again after a change of the work. Nobody keeps it as a repository.
# ---------------------------------------------------------------------------

# "<path in the template>:<path in the generated gateway>", in the order of the
# report.
#
# NO .gitignore, on purpose. The gateway is a data-only repository, and
# create-data-only always writes that file itself, as "*" and nothing else. The
# first command that creates the repository overwrites a copy here.
_DR_FORGE_GW_FILES=(
    'draugr.conf.in:.draugr.conf'
    'README.md.in:README.md'
    'kit/spec.yaml:.draugr/kit/spec.yaml'
    'hooks/post-up:.draugr/hooks/post-up'
    'kits/base/spec.yaml:kits/base/spec.yaml'
    'kits/unreal/spec.yaml:kits/unreal/spec.yaml'
)

# One host directory, in each of the two forms, into _dr_gw_wsl and
# _dr_gw_mound.
#
# NOT a getter, for the same reason as dr_forge_require_vm. A refusal inside
# $(...) ends the subshell, and the caller continues. Thus this returns 1, and
# the caller dies.
dr_forge_gw_path() {
    local raw=$1
    _dr_gw_wsl=$raw
    # The code accepts a Windows path, because all other texts about the forge
    # write these paths that way: D:\VaultHolder in a note, /mnt/d/VaultHolder
    # in a configuration.
    case "$raw" in
        [A-Za-z]:[\\/]*|[A-Za-z]:) _dr_gw_wsl=$(dr_path_from_win "$raw") ;;
    esac
    _dr_gw_wsl=${_dr_gw_wsl%/}
    # A mount goes to the MIRRORED path, so this is the whole conversion. It
    # refuses each path that is not on a Windows drive. DRAUGR_MOUNTS requires
    # that too.
    _dr_gw_mound=$(dr_path_mound "$_dr_gw_wsl") || return 1
}

# Render one template file. The substitution is six fixed placeholders, with the
# ${x//a/b} of bash, not sed or envsubst. A path with "&" or "|" breaks a sed
# replacement, and nothing in a template must ever be able to run.
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
# It writes the tree, and nothing else. It starts no mound, creates no
# repository, and touches no password file. Only one gateway can run. Thus a new
# one must be safe while another runs, and its start is a separate decision.
dr_forge_gateway_new() {
    local dir=$1 vault=$2 scratch=$3 force=$4
    local tpl="$DRAUGR_SHARE/gateway.example"

    [ -d "$tpl" ] || dr_die "this checkout is missing share/gateway.example/." \
        "That directory is the gateway template. Without it, the code can generate nothing."

    # The name of the VM goes into the generated configuration, so the usual
    # gate applies.
    dr_forge_require_vm

    # Both directories are optional, and a gateway without them is still a
    # proxy. That is the useful half on a machine that has no vault yet. For an
    # empty path, post-up skips its share step, and does not serve a missing
    # directory.
    local vault_wsl='' vault_mound='' scratch_wsl='' scratch_mound='' mounts=''
    if [ -n "$vault" ]; then
        dr_forge_gw_path "$vault" || dr_die \
            "--vault must name a directory on a Windows drive: $vault" \
            "A mound can mount only a Windows path, and it goes to the mirrored path:" \
            "/mnt/d/VaultHolder on the host is /d/VaultHolder inside the mound." \
            "Both forms work: /mnt/d/VaultHolder or D:\\VaultHolder."
        vault_wsl=$_dr_gw_wsl vault_mound=$_dr_gw_mound
    fi
    if [ -n "$scratch" ]; then
        dr_forge_gw_path "$scratch" || dr_die \
            "--scratch must name a directory on a Windows drive: $scratch" \
            "See --vault above: /mnt/d/ForgeScratch or D:\\ForgeScratch."
        scratch_wsl=$_dr_gw_wsl scratch_mound=$_dr_gw_mound
    fi

    # :ro on the vault and not on the scratch is the reason for two directories.
    # The VM must not be able to write to the vault, and the mount enforces
    # that. The kernel refuses the write, for each Samba configuration.
    [ -z "$vault_wsl" ]   || mounts="$vault_wsl:ro"
    [ -z "$scratch_wsl" ] || mounts="${mounts:+$mounts }$scratch_wsl"

    # THE CODE PUBLISHES THE SMB PORT ONLY FOR A SHARE BEHIND IT. The VAULT
    # path is the condition, exactly as post-up uses it for the share. A scratch
    # with no vault serves nothing, because the whole share block of the hook
    # needs the vault. Keep the two the same. A port with no share behind it is
    # a listener on the host that answers for nothing. The vault phase of
    # dr-layer provision reads that listener, to decide whether to install a
    # credential and reboot the guest.
    #
    # 18888 is always there, and the comment in the configuration says why. It
    # is the declared fact that identifies this repository as the gateway, and
    # you can read it while all is down.
    local ports='127.0.0.1:18888:8888'
    [ -z "$vault_wsl" ] || ports="$ports 127.0.0.1:18445:445"

    # THE CODE REFUSES A DIRECTORY THAT IS NOT EMPTY AND NOT A GATEWAY, because
    # that looks like a typo in the path. A gateway goes into an empty directory
    # or over a previous gateway. "Its configuration publishes 18888" identifies
    # a gateway.
    #
    # A TEST DURING THE BUILD SHOWED THIS, and it is why the test is for an
    # empty directory, not for the configuration. The first version only looked
    # at an existing .draugr.conf. The OWN checkout of Draugr has none. A run
    # on it wrote a configuration, two kit specs, and a hook into it,
    # and did not refuse. It kept the README. Only because of that was the error
    # visible.
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] \
       && ! grep -qs '18888' "$dir/.draugr.conf"; then
        [ -n "$force" ] || dr_die \
            "$dir is not empty, and its contents are not a gateway." \
            "A gateway goes into a new directory, or over a previous gateway. A gateway is" \
            "the mound that publishes 127.0.0.1:18888, and here the" \
            "$(if [ -f "$dir/.draugr.conf" ]; then echo '.draugr.conf does not'; else echo 'missing .draugr.conf cannot'; fi) do that." \
            "Thus this is probably not the directory that you meant. If it is:" \
            "  dr-forge gateway $dir -y"
    fi

    mkdir -p "$dir/.draugr/kit" "$dir/.draugr/hooks" "$dir/kits/base" "$dir/kits/unreal"

    # The name of the mound, from the directory, with one change. A gateway
    # directory usually has the name draugr-gateway-something, and
    # dr_sandbox_name always adds "draugr-" in front. Thus the name becomes
    # draugr-draugr-gateway. The fix is HERE, not in dr_sandbox_name. A change
    # there renames the mound of each existing project whose folder already
    # starts with "draugr-".
    local sandbox
    sandbox=$(dr_sandbox_name "$(cd "$dir" && pwd)")
    sandbox=${sandbox/#draugr-draugr-/draugr-}

    # One pass, with three results for each file: written, already current, or
    # kept because it differs. The code counts them during the pass, so that the
    # summary tells what happened, not what the code tried.
    local entry src rel dst text had='' created=0 current=0
    local -a kept=()
    for entry in "${_DR_FORGE_GW_FILES[@]}"; do
        src="$tpl/${entry%%:*}"
        rel=${entry#*:}
        dst="$dir/$rel"
        [ -f "$src" ] || dr_die "the gateway template is not complete: ${entry%%:*} is missing." \
            "Looked in $tpl."

        text=$(dr_forge_gw_render "$src" "$sandbox" "$mounts" "$vault_mound" "$scratch_mound" "$ports")

        # A placeholder that nobody filled goes as "@NAME@" into a configuration
        # that then works only half. The usual cause is a new placeholder in the
        # template, so name it.
        case "$text" in
            *@[A-Z]*[A-Z]@*) dr_die "the template has a placeholder that this version cannot fill:" \
                "$(printf '%s' "$text" | grep -o '@[A-Z_][A-Z_]*@' | sort -u | tr '\n' ' ')" \
                "in ${entry%%:*}. share/gateway.example and lib/forge/common.sh disagree." ;;
        esac

        # IDENTICAL IS NOT THE SAME AS MISSING, and neither is a refusal. A new
        # generation is the normal case, because the allowlist changes with the
        # kind of work, not with the VM. Thus a file that already matches the
        # template stays, silently. A file that does not match also stays,
        # because the difference is an edit of somebody, until that person says
        # otherwise.
        if [ -f "$dst" ]; then
            if [ "$text" = "$(cat "$dst")" ]; then
                printf '  %-24s %salready current%s\n' "$rel" "$_DR_DIM" "$_DR_OFF" >&2
                current=$(( current + 1 ))
                continue
            fi
            if [ -z "$force" ]; then
                printf '  %-24s %sdiffers, kept%s\n' "$rel" "$_DR_YELLOW" "$_DR_OFF" >&2
                kept+=("$rel")
                continue
            fi
            had=yes
        fi

        # WITH the newline. $text has none. dr_forge_gw_render ends with printf
        # '%s\n', and the command substitution that captured it removed all
        # final newlines. $(...) does that. Thus a plain printf '%s' here wrote
        # six files that each ended in the middle of a line. That was visible
        # only as diffs with two identical sides, and as "\ No newline at end of
        # file" in tools that report it.
        #
        # This does not change the "already current" test above, and that is
        # why the bug hid. $(cat "$dst") also removes the newline. Thus a file
        # with one and a file without one are both equal to $text. A new run on
        # an existing gateway thus still says "already current", and does not
        # suddenly report a difference.
        printf '%s\n' "$text" > "$dst"
        # Not "${had:+overwritten}${had:-written}". With had=yes, that prints
        # BOTH, because :- returns the value of a variable that is set. The
        # output was "overwrittenyes".
        if [ -n "$had" ]; then
            printf '  %-24s %s\n' "$rel" overwritten >&2
        else
            printf '  %-24s %s\n' "$rel" written >&2
        fi
        had=''
        created=$(( created + 1 ))

        # The hook must be executable, or dr_hook skips it SILENTLY: no keeper,
        # no proxy, no share, and no message. share/ cannot hold the bit (each
        # example in it is not executable, on purpose), so the code sets it
        # here.
        case "$rel" in
            .draugr/hooks/post-up) chmod 755 "$dst" ;;
        esac

        # Trust, for the two files that run AS CODE. The configuration is
        # sourced, and the hook runs on the host as you. Draugr gives the trust,
        # because Draugr wrote them, and you asked for it. create-data-only has
        # the same reason for the configuration that it writes. A file that
        # stays because it differs is NOT trusted here, because nobody read it.
        case "$rel" in
            .draugr.conf|.draugr/hooks/post-up) dr_trust_add "$dst" ;;
        esac
    done

    # The report lists kept files together at the end, not one by one. The
    # useful message is "these are yours, and here is how to take the template
    # anyway".
    if [ ${#kept[@]} -gt 0 ]; then
        dr_warn "$created written, $current already current, ${#kept[@]} kept as they are."
        printf '  %sYour edits are in those files, so they did not change. To see the\n' "$_DR_DIM" >&2
        printf '  changes, diff them with the template. To take the template anyway:%s\n' "$_DR_OFF" >&2
        printf '    dr-forge gateway %s -y\n' "$dir" >&2
        return 3
    fi

    dr_ok "gateway in $dir ($created written, $current already current)"
    printf '  %sNothing started. The mound starts with dr-forge up in the game\n' "$_DR_DIM" >&2
    printf '  project, through DRAUGR_REQUIRES, or with dr-up from inside %s.%s\n' "$dir" "$_DR_OFF" >&2
}
