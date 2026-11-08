#!/usr/bin/env bats
# dr-forge gateway: the generator, EXECUTED. docs/FORGE.md, "The gateway,
# generated".
#
# These run in all places, with zero skips. The generator is bash that writes
# files and converts paths. It converts the paths by hand, not with wslpath
# (lib/common.sh tells why). Thus nothing here needs a Windows drive,
# powershell.exe, or a daemon. That is the full reason why this file is separate
# from forge-api.bats and its skips.
#
# WHAT THEY ARE FOR. The important half of this verb is its refusals. Each of
# them was wrong once or more during its development. It overwrote a hand edit.
# It printed "overwrittenyes". It generated a configuration and four kit files
# IN THE OWN CHECKOUT OF DRAUGR, because the guard looked only for a
# .draugr.conf, and the repository of a tool does not have one. A grep of the
# source passes all three.

load helper

setup() {
    dr_test_setup
    export DRAUGR_FORGE=mock-vm
    # Outside all repositories, so that only the values of a test apply. HOME
    # already belongs to $DR_TMP (helper.bash). That keeps the trust assertions
    # off the real trust file.
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

# dr_hook is `[ -x "$hook" ] || return 0`. Thus it SILENTLY skips a mode-644
# hook: no keeper, no tinyproxy, no vault share, and no message. The mound only
# stops answering 30 s later. share/ cannot carry the bit (git records all six
# template files as 100644), so generation must set it.
#
# THIS TEST CAN SEE THAT, AND A REAL GATEWAY CANNOT. That is why it is useful.
# DR_TMP is the own /tmp of WSL, on ext4, where modes have a meaning. A gateway
# generated on a Windows drive is on drvfs, which reports 777 for all files.
# There, nobody sees the missing chmod. It fails only on a checkout on ext4,
# which Draugr supports.
@test "gateway: the hook arrives executable, or dr_hook would skip it in silence" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -x "$GW/.draugr/hooks/post-up" ]
}

# This key makes a mound THE gateway. dr-forge reads it to decide whether the
# current repository is the gateway. It must answer that while all is down.
@test "gateway: the generated config publishes 18888 and is data-only" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '127.0.0.1:18888:8888' "$GW/.draugr.conf"
    grep -q 'DRAUGR_ON_MISSING_REPO=create-data-only' "$GW/.draugr.conf"
    grep -q "DRAUGR_FORGE=mock-vm" "$GW/.draugr.conf"
    # No .gitignore from the template. create-data-only always writes that file
    # itself, and the first dr-up overwrites a copy here.
    [ ! -f "$GW/.gitignore" ]
}

# A GENERATED GATEWAY MUST NOT STOP ITSELF, and nothing else can assert it. Git
# ignores the full directory of the gateway (.gitignore is `*`). Thus the next
# generation silently loses a value that is only in the generated copy.
# docs/FORGE.md, "Two mounds, two policies": the gateway must be up whenever the
# VM is. The VM is on the host, not a mound. Thus dr-dep has no claimant to
# count, and the 10m default stops the gateway under a running VM. A test with a
# UE 4.10 download showed this. It lost its proxy after 16 minutes.
@test "gateway: the generated config never idle-stops the gateway" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '^DRAUGR_LINGER=off$' "$GW/.draugr.conf"
}

# A mount goes to the mirrored path. Thus both the host spelling and the mound
# spelling are necessary, and they are different strings. Windows spelling in,
# both out.
@test "gateway: a Windows path becomes the host mount and the mound path" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q 'DRAUGR_MOUNTS="/mnt/d/VaultHolder:ro /mnt/d/ForgeScratch"' "$GW/.draugr.conf"
    grep -q '^vault_path=/d/VaultHolder$' "$GW/.draugr/hooks/post-up"
    grep -q '^scratch_path=/d/ForgeScratch$' "$GW/.draugr/hooks/post-up"
}

# :ro on the vault, and nothing on the scratch, is the only thing that stops a
# guest write to the Fab cache. SECURITY.md makes that promise aloud.
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

# AND IT DOES NOT PUBLISH THE SMB PORT. The other side reads that half. On the
# host, the PUBLISHER binds a published port, not the service behind it. Thus
# 18445 on a gateway with no share is a listener that answers for nothing. The
# vault phase of dr-layer provision reads that listener. It decides from it
# whether to install a share credential and REBOOT the guest. It always
# published the port, until 2b needed the port to have a meaning.
@test "gateway: no vault means no SMB port published" {
    run dr-forge gateway "$GW"
    [ "$status" -eq 0 ]
    grep -q 'DRAUGR_PORTS="127.0.0.1:18888:8888"' "$GW/.draugr.conf"
    # The PORTS LINE, not the whole file. The own comment of the configuration
    # tells when 18445 is published, and why. Thus a grep of the full file
    # matches the prose, and fails on a correct gateway. This assertion found
    # that, at its first chance.
    ! grep '^DRAUGR_PORTS=' "$GW/.draugr.conf" | grep -q 18445 || return 1
    # 18888 is always there. It is the declared fact that identifies the
    # gateway, and dr-forge must answer that question while all is down.
    grep -q '127.0.0.1:18888:8888' "$GW/.draugr.conf"
}

@test "gateway: a vault means both ports published" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q 'DRAUGR_PORTS="127.0.0.1:18888:8888 127.0.0.1:18445:445"' "$GW/.draugr.conf"
}

# A scratch with no vault also gets no port, on purpose. The full share block of
# post-up is behind the vault test, so such a gateway serves nothing over SMB.
# The port and the hook must agree. If not, one of them lies.
@test "gateway: a scratch without a vault publishes no SMB port, as the hook serves none" {
    run dr-forge gateway "$GW" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    # The PORTS LINE, not the whole file. The own comment of the configuration
    # tells when 18445 is published, and why. Thus a grep of the full file
    # matches the prose, and fails on a correct gateway. This assertion found
    # that, at its first chance.
    ! grep '^DRAUGR_PORTS=' "$GW/.draugr.conf" | grep -q 18445 || return 1
    grep -q '^vault_path=$' "$GW/.draugr/hooks/post-up"
    # The scratch IS still mounted into the mound. Only the SMB route is absent.
    grep -q 'DRAUGR_MOUNTS="/mnt/d/ForgeScratch"' "$GW/.draugr.conf"
}

# A placeholder with no substitution ships as "@NAME@" in a configuration that
# then half works. EACH FILE ENDS WITH A NEWLINE. This test reads the last byte,
# and does not diff. A diff did not show the defect that it guards. Three files
# reported "2 changed lines", and the two sides were the same, character for
# character. Also, POSIX tools silently disagree about a text file that stops in
# the middle of a line. `read` drops the last line, `wc -l` counts one too few,
# and git reports it in each future diff.
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

# THE EDIT IS THE PURPOSE. The allowlist changes with the type of work, so a
# gateway gets generated again. A new generation that silently removes an added
# host is worse than no command. Exit 3 says "the tree is not what the template
# says", and does not say that something failed.
@test "gateway: an edited file is kept, reported, and exits 3" {
    dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    printf '\n# a hand edit\n' >> "$GW/kits/unreal/spec.yaml"
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 3 ]
    [[ "$output" == *"differs, kept"* ]]
    grep -q 'a hand edit' "$GW/kits/unreal/spec.yaml"
}

@test "gateway: -y overwrites the edited file" {
    dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    printf '\n# a hand edit\n' >> "$GW/kits/unreal/spec.yaml"
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"overwritten"* ]]
    # Not "overwrittenyes", which ${had:+a}${had:-b} printed. :- returns the
    # VALUE of a variable that is set, so both arms fired.
    [[ "$output" != *"overwrittenyes"* ]]
    ! grep -q 'a hand edit' "$GW/kits/unreal/spec.yaml"
}

# --- refusing -------------------------------------------------------------------------------

# A TEST DURING THE BUILD SHOWED THIS. The first guard looked only for an
# existing .draugr.conf. Thus this exact command wrote a configuration, a hook,
# and two kit specs into the own checkout of Draugr.
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

# An existing gateway is not "a directory with something else in it", and a new
# generation is the normal case. Thus the emptiness guard must not fire on it.
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

# The opt-in gate is the full reason why the forge costs nothing to other users.
# A gateway generation is forge work, as all others. The name of the VM goes
# into its configuration.
@test "gateway: with no forge configured it refuses, and creates no directory" {
    unset DRAUGR_FORGE
    run dr-forge gateway "$GW"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no forge is configured"* ]]
    [ ! -d "$GW" ]
}

# --- trust ----------------------------------------------------------------------------------

# The configuration is SOURCED, and the hook RUNS ON THE HOST as you. Thus dr-up
# refuses both until they are trusted. The trust here has the same basis as
# create-data-only for the configuration that it writes. It applies only to
# files that Draugr really wrote.
@test "gateway: the config and the hook are trusted, the kit specs are not" {
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 0 ]
    run trusted
    [[ "$output" == *".draugr.conf"* ]]
    [[ "$output" == *"post-up"* ]]
    [[ "$output" != *"spec.yaml"* ]]
}

# Nobody read a file that was kept because it differs, so nothing can trust it.
@test "gateway: a kept hook is not re-trusted" {
    dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    printf '\n# edited by hand\n' >> "$GW/.draugr/hooks/post-up"
    local before
    before=$(trusted | grep -c 'post-up')
    run dr-forge gateway "$GW" --vault "$VAULT" --scratch "$SCRATCH"
    [ "$status" -eq 3 ]
    # Still exactly one entry, and still the OLD hash. The edited file got no
    # trust.
    [ "$(trusted | grep -c 'post-up')" = "$before" ]
    run bash -c "cd '$DR_ROOT' && . lib/common.sh && dr_trust_is_trusted '$GW/.draugr/hooks/post-up'"
    [ "$status" -ne 0 ]
}
