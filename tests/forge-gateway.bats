#!/usr/bin/env bats
# dr-forge gateway: the generator, EXECUTED. docs/FORGE.md, "The gateway, generated".
#
# These run anywhere, with zero skips. The generator is bash that writes files and converts
# paths, and the paths are converted by hand rather than by wslpath (lib/common.sh says why),
# so nothing here needs a Windows drive, powershell.exe or a daemon - which is the whole
# reason this file is separate from forge-api.bats and its skips.
#
# WHAT THEY ARE FOR. The interesting half of this verb is its refusals, and every one of them
# was wrong at least once while it was written: it overwrote a hand edit, it printed
# "overwrittenyes", and it generated a config and four kit files INTO DRAUGR'S OWN CHECKOUT
# because the guard only looked for a .draugr.conf that a tool's repository does not have.
# A grep of the source would have passed all three.

load helper

setup() {
    dr_test_setup
    export DRAUGR_FORGE=mock-vm
    # Out of any repository, so only what a test sets is in scope. HOME is already $DR_TMP's
    # (helper.bash), which is what keeps the trust assertions off the real trust file.
    cd "$DR_TMP" || return 1
    GW="$DR_TMP/gw"
    VAULT='D:\VaultHolder'
    SCRATCH='D:\ForgeScratch'
}

teardown() { dr_test_teardown; }

trusted() { cat "$DR_TMP/config/trusted" 2>/dev/null; }

# --- generating -----------------------------------------------------------------------------

@test "gateway: writes the six files into a new directory" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -f "$GW/.draugr.conf" ]
    [ -f "$GW/README.md" ]
    [ -f "$GW/.draugr/kit/spec.yaml" ]
    [ -f "$GW/.draugr/hooks/post-up" ]
    [ -f "$GW/kits/base/spec.yaml" ]
    [ -f "$GW/kits/unreal/spec.yaml" ]
}

# dr_hook is `[ -x "$hook" ] || return 0`, so a mode-644 hook is skipped IN SILENCE: no
# keeper, no tinyproxy, no vault share, and no message either - the mound would just stop
# answering 30 s later. share/ cannot carry the bit (git records all six template files
# 100644), so generation has to set it.
#
# THIS TEST CAN SEE THAT AND A REAL GATEWAY CANNOT, which is why it is worth having: DR_TMP is
# WSL's own /tmp, on ext4, where modes mean something. A gateway generated onto a Windows drive
# sits on drvfs, which reports 777 for everything - so the missing chmod would be invisible
# there and would bite only on a checkout living on ext4, which Draugr supports.
@test "gateway: the hook arrives executable, or dr_hook would skip it in silence" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -x "$GW/.draugr/hooks/post-up" ]
}

# What makes a mound THE gateway is this key, and dr-forge reads it to decide whether the
# gateway is the current repository - a question it has to answer while everything is down.
@test "gateway: the generated config publishes 18888 and is data-only" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '127.0.0.1:18888:8888' "$GW/.draugr.conf"
    grep -q 'DRAUGR_ON_MISSING_REPO=create-data-only' "$GW/.draugr.conf"
    grep -q "DRAUGR_FORGE=mock-vm" "$GW/.draugr.conf"
    # No .gitignore from the template: create-data-only writes that file itself,
    # unconditionally, and a copy here would be clobbered by the first dr-up.
    [ ! -f "$GW/.gitignore" ]
}

# A GENERATED GATEWAY MUST NOT STOP ITSELF, and nothing else can assert it: the gateway's own
# directory is ignored whole (.gitignore is `*`), so a value only in the generated copy is lost
# at the next regeneration, silently. docs/FORGE.md, "Two mounds, two policies": the gateway
# must be up whenever the VM is - and the VM is on the host, not a mound, so dr-dep has no
# claimant to count and the 10m default stops the gateway under a running VM. Measured
# against a UE 4.10 download, which lost its proxy 16 minutes in.
@test "gateway: the generated config never idle-stops the gateway" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '^DRAUGR_LINGER=off$' "$GW/.draugr.conf"
}

# A mount lands at the mirrored path, so the host spelling and the mound spelling are both
# needed and they are not the same string. Windows spelling in, both out.
@test "gateway: a Windows path becomes the host mount and the mound path" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q 'DRAUGR_MOUNTS="/mnt/d/VaultHolder:ro /mnt/d/ForgeScratch"' "$GW/.draugr.conf"
    grep -q '^vault_path=/d/VaultHolder$' "$GW/.draugr/hooks/post-up"
    grep -q '^scratch_path=/d/ForgeScratch$' "$GW/.draugr/hooks/post-up"
}

# :ro on the vault and nothing on the scratch is the only thing stopping the guest writing to
# the Fab cache, and SECURITY.md makes that promise out loud.
@test "gateway: the vault is mounted read-only and the scratch is not" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q 'VaultHolder:ro' "$GW/.draugr.conf"
    ! grep -q 'ForgeScratch:ro' "$GW/.draugr.conf"
}

@test "gateway: a gateway without a vault still generates, and serves no share" {
    run dr-forge gateway "$GW"
    [ "$status" -eq 0 ]
    grep -q 'DRAUGR_MOUNTS=""' "$GW/.draugr.conf"
    grep -q '^vault_path=$' "$GW/.draugr/hooks/post-up"
}

# AND IT DOES NOT PUBLISH THE SMB PORT, which is the half that is read from the other side.
# A published port is bound on the host by the PUBLISHER, not by whatever is meant to be
# behind it, so 18445 on a gateway with no share is a listener answering for nothing - and
# dr-layer provision's vault phase reads that listener to decide whether to install a share
# credential and REBOOT the guest. It published it unconditionally until 2b needed it to
# mean something.
@test "gateway: no vault means no SMB port published" {
    run dr-forge gateway "$GW"
    [ "$status" -eq 0 ]
    grep -q 'DRAUGR_PORTS="127.0.0.1:18888:8888"' "$GW/.draugr.conf"
    # The PORTS LINE, not the whole file: the config's own comment explains when 18445
    # is published and why, so a file-wide grep matches the prose and fails on a correct
    # gateway. Found by this very assertion, the first time it was able to fail.
    ! grep '^DRAUGR_PORTS=' "$GW/.draugr.conf" | grep -q 18445 || return 1
    # 18888 is unconditional: it is the declared fact that identifies the gateway, and
    # dr-forge has to answer that question while everything is down.
    grep -q '127.0.0.1:18888:8888' "$GW/.draugr.conf"
}

@test "gateway: a vault means both ports published" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q 'DRAUGR_PORTS="127.0.0.1:18888:8888 127.0.0.1:18445:445"' "$GW/.draugr.conf"
}

# A scratch with no vault gets no port either, and that is not an oversight: post-up's
# whole share block is behind the vault test, so such a gateway serves nothing over SMB.
# The port and the hook have to agree or one of them is lying.
@test "gateway: a scratch without a vault publishes no SMB port, as the hook serves none" {
    run dr-forge gateway "$GW" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    # The PORTS LINE, not the whole file: the config's own comment explains when 18445
    # is published and why, so a file-wide grep matches the prose and fails on a correct
    # gateway. Found by this very assertion, the first time it was able to fail.
    ! grep '^DRAUGR_PORTS=' "$GW/.draugr.conf" | grep -q 18445 || return 1
    grep -q '^vault_path=$' "$GW/.draugr/hooks/post-up"
    # The scratch IS still mounted into the mound - it is only the SMB route that is absent.
    grep -q 'DRAUGR_MOUNTS="/mnt/d/ForgeScratch"' "$GW/.draugr.conf"
}

# A placeholder nobody substituted would ship as "@NAME@" in a config that then half works.
# EVERY FILE ENDS WITH A NEWLINE, and this is checked by reading the last byte rather than
# by diffing, because the defect it guards was invisible in a diff: three files reported
# "2 changed lines" whose two sides were character-for-character the same. A text file that
# stops mid-line is also the thing POSIX tools quietly disagree about - `read` drops the
# last line, `wc -l` undercounts by one, and git reports it on every future diff.
@test "gateway: every generated file ends with a newline" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    local f last
    while read -r f; do
        last=$(tail -c1 "$f" | od -An -c | tr -d ' ')
        [ "$last" = '\n' ] || {
            printf '%s ends with %s, not a newline\n' "${f#"$GW"/}" "$last" >&2
            return 1
        }
    done < <(find "$GW" -type f)
}

@test "gateway: no template placeholder survives into the generated tree" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    run grep -rlo '@[A-Z_][A-Z_]*@' "$GW"
    [ -z "$output" ]
}

# --- re-running -----------------------------------------------------------------------------

@test "gateway: re-running changes nothing and says so" {
    dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already current"* ]]
    [[ "$output" != *"written"* || "$output" == *"0 written"* ]]
}

# THE EDIT IS THE POINT. The allowlist changes with the kind of work, so a gateway is
# regenerated - and a regenerate that silently took back somebody's added host would be worse
# than no command at all. Exit 3 says "the tree is not what the template says" without
# claiming anything failed.
@test "gateway: an edited file is kept, reported, and exits 3" {
    dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    printf '\n# a hand edit\n' >> "$GW/kits/unreal/spec.yaml"
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 3 ]
    [[ "$output" == *"differs - kept"* ]]
    grep -q 'a hand edit' "$GW/kits/unreal/spec.yaml"
}

@test "gateway: -y overwrites the edited file" {
    dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    printf '\n# a hand edit\n' >> "$GW/kits/unreal/spec.yaml"
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"overwritten"* ]]
    # Not "overwrittenyes", which is what ${had:+a}${had:-b} printed: :- returns the VALUE of
    # a variable that is set, so both arms fired.
    [[ "$output" != *"overwrittenyes"* ]]
    ! grep -q 'a hand edit' "$GW/kits/unreal/spec.yaml"
}

# --- refusing -------------------------------------------------------------------------------

# MEASURED while building this: the first guard only looked at an existing .draugr.conf, so
# this exact command wrote a config, a hook and two kit specs into Draugr's own checkout.
@test "gateway: a non-empty directory that is not a gateway is refused, and nothing is written" {
    mkdir -p "$DR_TMP/someproject/bin"
    printf 'x\n' > "$DR_TMP/someproject/bin/thing"
    run dr-forge gateway "$DR_TMP/someproject"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not empty"* ]]
    [ ! -f "$DR_TMP/someproject/.draugr.conf" ]
    [ ! -d "$DR_TMP/someproject/kits" ]
    [ ! -d "$DR_TMP/someproject/.draugr" ]
}

@test "gateway: -y generates into a non-empty directory anyway" {
    mkdir -p "$DR_TMP/someproject"
    printf 'x\n' > "$DR_TMP/someproject/thing"
    run dr-forge gateway "$DR_TMP/someproject" -y
    [ "$status" -eq 0 ]
    [ -f "$DR_TMP/someproject/.draugr.conf" ]
    [ -f "$DR_TMP/someproject/thing" ]
}

# An existing gateway is not "a directory with something else in it", and regenerating one is
# the normal case - so the emptiness guard must not fire on it.
@test "gateway: an existing gateway is recognised by its 18888 and regenerated" {
    dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    [[ "$output" != *"not empty"* ]]
}

@test "gateway: a vault path that is not on a Windows drive is refused" {
    run dr-forge gateway "$GW" --vault /home/nobody/vault
    [ "$status" -eq 1 ]
    [[ "$output" == *"Windows drive"* ]]
    [ ! -f "$GW/.draugr.conf" ]
}

@test "gateway: --vault with no path is refused rather than read as the directory" {
    run dr-forge gateway "$GW" --vault
    [ "$status" -eq 1 ]
    [[ "$output" == *"--vault needs a path"* ]]
}

@test "gateway: two directories are refused" {
    run dr-forge gateway "$GW" "$DR_TMP/other"
    [ "$status" -eq 1 ]
    [[ "$output" == *"one directory"* ]]
}

@test "gateway: with no directory it says what it needs" {
    run dr-forge gateway
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a directory"* ]]
}

# The opt-in gate is the whole reason the forge costs nothing to anyone else, and generating a
# gateway is forge work like any other: the VM's name goes into the config it writes.
@test "gateway: with no forge configured it refuses, and creates no directory" {
    unset DRAUGR_FORGE
    run dr-forge gateway "$GW"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no forge is configured"* ]]
    [ ! -d "$GW" ]
}

# --- trust ----------------------------------------------------------------------------------

# The config is SOURCED and the hook RUNS ON THE HOST as you, so dr-up refuses both until they
# are trusted. Granting it here is the same ground create-data-only stands on for the config
# it writes - and it is granted only for files Draugr actually wrote.
@test "gateway: the config and the hook are trusted, the kit specs are not" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    run trusted
    [[ "$output" == *".draugr.conf"* ]]
    [[ "$output" == *"post-up"* ]]
    [[ "$output" != *"spec.yaml"* ]]
}

# A file kept because it differs has been read by nobody, so nothing may vouch for it.
@test "gateway: a kept hook is not re-trusted" {
    dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    printf '\n# edited by hand\n' >> "$GW/.draugr/hooks/post-up"
    local before
    before=$(trusted | grep -c 'post-up')
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 3 ]
    # Still exactly one entry, and still the OLD hash - the edited file was not vouched for.
    [ "$(trusted | grep -c 'post-up')" = "$before" ]
    run bash -c "cd '$DR_ROOT' && . lib/common.sh && dr_trust_is_trusted '$GW/.draugr/hooks/post-up'"
    [ "$status" -ne 0 ]
}
