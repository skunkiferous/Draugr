#!/usr/bin/env bats
# DRAUGR_KIT as a list, and the library of named kits behind it.
#
# The premise is one measured fact: sbx MERGES kits rather than choosing between
# them. Verified against sbx 0.37.1 - two mixins on one sandbox contributed both
# their install commands and both their network allow rules, merged into a single
# policy. Everything here follows from that, so if it ever stops being true these
# tests are describing the wrong product.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-$(basename "$REPO")" DR_MOCK_STATE=running
    dr_fake_sbx_root
    dr_load_common

    # Isolated per test, so nothing here can reach the real library. $DR_TMP is
    # on WSL's own ext4 - which is where the real default lives too - so this
    # also exercises the UNC spelling a kit outside /mnt/<drive> needs.
    export DRAUGR_KIT_STORE="$DR_TMP/kitstore"
    export WSL_DISTRO_NAME="${WSL_DISTRO_NAME:-Ubuntu}"
    DR_REPO=$REPO
}

teardown() { dr_test_teardown; }

calls() { grep "^$1 " "$DR_MOCK_LOG" || true; }

# A kit is a directory with a spec in it; the contents only matter where a test
# says they do.
make_kit() {
    mkdir -p "$1"
    printf 'schemaVersion: "2"\nkind: mixin\nname: %s\ndisplayName: %s kit\n' \
        "$(basename "$1")" "$(basename "$1")" > "$1/spec.yaml"
}

# --- resolving one entry ------------------------------------------------------

@test "dr_kit_resolve: an absolute path is used as it stands" {
    make_kit "$DR_TMP/elsewhere"
    run dr_kit_resolve "$DR_TMP/elsewhere"
    [ "$status" -eq 0 ]
    [ "$output" = "$DR_TMP/elsewhere" ]
}

@test "dr_kit_resolve: a repo-relative directory resolves inside the repo" {
    make_kit "$REPO/.draugr/kit"
    run dr_kit_resolve ".draugr/kit"
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO/.draugr/kit" ]
}

@test "dr_kit_resolve: a bare name resolves in the kit store" {
    make_kit "$DRAUGR_KIT_STORE/lua"
    run dr_kit_resolve "lua"
    [ "$status" -eq 0 ]
    [ "$output" = "$DRAUGR_KIT_STORE/lua" ]
}

@test "dr_kit_resolve: the repo wins over the library on a name collision" {
    # The more specific answer wins, which is the rule the whole config cascade
    # follows. A repo that happens to contain a directory called lua means its own.
    make_kit "$REPO/lua"
    make_kit "$DRAUGR_KIT_STORE/lua"
    run dr_kit_resolve "lua"
    [ "$output" = "$REPO/lua" ]
}

@test "dr_kit_resolve: an OCI reference passes through untouched" {
    run dr_kit_resolve "ghcr.io/org/kit:v1"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/org/kit:v1" ]
}

@test "dr_kit_resolve: a git reference passes through untouched" {
    run dr_kit_resolve "git+https://host/org/repo.git"
    [ "$status" -eq 0 ]
    [ "$output" = "git+https://host/org/repo.git" ]
}

@test "dr_kit_resolve: a name that exists nowhere fails" {
    # No ":" or "@", so there is nothing to fall back to and guessing would only
    # move the error into sbx where it makes less sense.
    run dr_kit_resolve "nosuchkit"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# --- resolving the list -------------------------------------------------------

@test "dr_kit_refs: resolves every entry, in order" {
    # Order is preserved because sbx applies kits in the order it is given them,
    # so a later entry lands on top of an earlier one.
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT=".draugr/kit lua"
    run dr_kit_refs
    [ "${lines[0]}" = "$REPO/.draugr/kit" ]
    [ "${lines[1]}" = "$DRAUGR_KIT_STORE/lua" ]
}

@test "dr_kit_refs: skips what it cannot resolve but keeps the rest" {
    make_kit "$REPO/.draugr/kit"
    DRAUGR_KIT=".draugr/kit typo"
    run dr_kit_refs
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "$REPO/.draugr/kit" ]
}

@test "dr_kit_refs: fails when nothing at all resolves" {
    DRAUGR_KIT="typo alsotypo"
    run dr_kit_refs
    [ "$status" -ne 0 ]
}

@test "dr_kit_missing: names the entries you wrote, not resolved paths" {
    # A bare entry is searched for in two places, so a resolved path would hide
    # half of where Draugr actually looked.
    make_kit "$REPO/.draugr/kit"
    DRAUGR_KIT=".draugr/kit lua"
    run dr_kit_missing
    [ "$output" = "lua" ]
}

@test "dr_kit_repo_dir: picks the project's own kit out of a mixed list" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT="lua .draugr/kit"
    run dr_kit_repo_dir
    [ "$output" = "$REPO/.draugr/kit" ]
}

# --- the digest that drift is built on ----------------------------------------

@test "dr_kit_hash_all: changes when the LIBRARY kit changes" {
    # The case a single-kit hash could not see, and the reason drift detection
    # still matters once kits are shared: another repo edits the library copy and
    # this mound is silently stale.
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT=".draugr/kit lua"
    before=$(dr_kit_hash_all)
    printf 'description: edited elsewhere\n' >> "$DRAUGR_KIT_STORE/lua/spec.yaml"
    [ "$(dr_kit_hash_all)" != "$before" ]
}

@test "dr_kit_hash_all: changes when the PROJECT kit changes" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT=".draugr/kit lua"
    before=$(dr_kit_hash_all)
    printf 'description: edited here\n' >> "$REPO/.draugr/kit/spec.yaml"
    [ "$(dr_kit_hash_all)" != "$before" ]
}

@test "dr_kit_hash_all: order is part of the digest" {
    # The same two kits the other way round can build a different sandbox, so
    # swapping them has to read as drift rather than as no change at all.
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT=".draugr/kit lua"
    one=$(dr_kit_hash_all)
    DRAUGR_KIT="lua .draugr/kit"
    [ "$(dr_kit_hash_all)" != "$one" ]
}

@test "dr_kit_hash_all: a remote reference contributes its name" {
    # All we can honestly do without fetching an OCI image on every dr-up. The
    # point of the test is that changing the reference is still detected.
    DRAUGR_KIT="ghcr.io/org/kit:v1"
    one=$(dr_kit_hash_all)
    DRAUGR_KIT="ghcr.io/org/kit:v2"
    [ "$(dr_kit_hash_all)" != "$one" ]
}

# --- dr-up builds one --kit per entry -----------------------------------------

@test "dr-up: passes every resolved kit as its own --kit" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT=".draugr/kit lua" DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    line=$(calls create)
    [[ "$line" == *"--kit"*"--kit"* ]]
}

@test "dr-up: a directory is spelled the Windows way, a reference is not" {
    make_kit "$REPO/.draugr/kit"
    DRAUGR_KIT=".draugr/kit ghcr.io/org/kit:v1" DR_MOCK_STATE=absent run dr-up
    line=$(calls create)
    [[ "$line" == *':\'* ]]
    [[ "$line" == *"ghcr.io/org/kit:v1"* ]]
}

@test "dr-up: names a missing library kit without stopping" {
    make_kit "$REPO/.draugr/kit"
    DRAUGR_KIT=".draugr/kit lua" DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    [[ "$output" == *"no kit found for 'lua'"* ]]
    # The one that DID resolve still has to reach sbx.
    [[ "$(calls create)" == *"--kit"* ]]
}

# --- the library commands -----------------------------------------------------

@test "dr-kit save: copies the project's kit into the library" {
    make_kit "$REPO/.draugr/kit"
    run dr-kit save lua
    [ "$status" -eq 0 ]
    [ -f "$DRAUGR_KIT_STORE/lua/spec.yaml" ]
}

@test "dr-kit save: it is a copy, not a link" {
    # A library that silently tracked one repo's edits would be a shared mutable
    # dependency nobody asked for.
    make_kit "$REPO/.draugr/kit"
    dr-kit save lua >/dev/null 2>&1
    printf 'description: changed after saving\n' >> "$REPO/.draugr/kit/spec.yaml"
    run grep -c "changed after saving" "$DRAUGR_KIT_STORE/lua/spec.yaml"
    [ "$output" = "0" ]
}

@test "dr-kit save: refuses a name that is not a plain directory name" {
    make_kit "$REPO/.draugr/kit"
    run dr-kit save ../escape
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a usable kit name"* ]]
}

@test "dr-kit save: refuses a name with a slash" {
    make_kit "$REPO/.draugr/kit"
    run dr-kit save lang/lua
    [ "$status" -ne 0 ]
}

@test "dr-kit save: needs a name" {
    make_kit "$REPO/.draugr/kit"
    run dr-kit save
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs a name"* ]]
}

@test "dr-kit save: overwriting is a question, and says who it affects" {
    make_kit "$REPO/.draugr/kit"
    dr-kit save lua >/dev/null 2>&1
    run dr-kit save lua
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
    [[ "$output" == *"Every repo using it"* ]]
}

@test "dr-kit save: --yes overwrites" {
    make_kit "$REPO/.draugr/kit"
    dr-kit save lua >/dev/null 2>&1
    printf 'description: second version\n' >> "$REPO/.draugr/kit/spec.yaml"
    run dr-kit save lua --yes
    [ "$status" -eq 0 ]
    grep -q "second version" "$DRAUGR_KIT_STORE/lua/spec.yaml"
}

@test "dr-kit save: refuses when the project has no kit of its own" {
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT="lua" run dr-kit save copy
    [ "$status" -ne 0 ]
    [[ "$output" == *"no kit of its own"* ]]
}

@test "dr-kit list: an empty library says how to fill it" {
    run dr-kit list
    [ "$status" -eq 0 ]
    [[ "$output" == *"dr-kit save"* ]]
}

@test "dr-kit list: shows saved kits with their displayName" {
    make_kit "$REPO/.draugr/kit"
    dr-kit save lua >/dev/null 2>&1
    run dr-kit list
    [ "$status" -eq 0 ]
    [[ "$output" == *"lua"* ]]
    [[ "$output" == *"kit"* ]]
}

@test "dr-kit drift: a changed library kit is drift for this repo" {
    # The whole reason drift detection survives into a shared library: you did
    # not touch this repo, and its mound is nonetheless out of date.
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    export DRAUGR_KIT=".draugr/kit lua"
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
    printf 'description: edited by another project\n' >> "$DRAUGR_KIT_STORE/lua/spec.yaml"
    run dr-kit drift
    [ "$status" -eq 1 ]
    [[ "$output" == *"has changed"* ]]
}

@test "dr-kit drift: clean when neither kit has moved" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    export DRAUGR_KIT=".draugr/kit lua"
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
    run dr-kit drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"matches"* ]]
}

@test "dr-kit drift: a clean report admits it cannot see inside a remote ref" {
    make_kit "$REPO/.draugr/kit"
    export DRAUGR_KIT=".draugr/kit ghcr.io/org/kit:v1"
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
    run dr-kit drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"only its NAME is compared"* ]]
}

@test "dr-kit apply: adds every kit in the list" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT=".draugr/kit lua" run dr-kit apply --yes
    [ "$status" -eq 0 ]
    [ "$(calls kit | grep -c "kit add")" -eq 2 ]
}

@test "dr-kit validate: checks every kit in the list" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT=".draugr/kit lua" run dr-kit validate
    [ "$status" -eq 0 ]
    [ "$(calls kit | grep -c "kit validate")" -eq 2 ]
}

# --- dr-setup creates the library ---------------------------------------------
#
# The kit store is machine-level, like the ssh bridge, so it belongs to the one
# command that sets up the machine. An empty directory is a better first
# encounter than dr-kit having to explain what a kit store is.

@test "dr-setup: creates the kit library" {
    [ ! -d "$DRAUGR_KIT_STORE" ]
    run dr-setup
    [ "$status" -eq 0 ]
    [ -d "$DRAUGR_KIT_STORE" ]
    [[ "$output" == *"kit library"* ]]
}

@test "dr-setup: creates it where DRAUGR_KIT_STORE says, not only the default" {
    # Someone who moved the store still wants dr-setup to make the right one.
    export DRAUGR_KIT_STORE="$DR_TMP/elsewhere/kits"
    run dr-setup
    [ -d "$DR_TMP/elsewhere/kits" ]
}

@test "dr-setup: creates the default library when nothing overrides it" {
    unset DRAUGR_KIT_STORE
    run dr-setup
    [ "$status" -eq 0 ]
    [ -d "$DRAUGR_CONFIG_HOME/kits" ]
}

@test "dr-setup: running it twice is quiet the second time" {
    dr-setup >/dev/null 2>&1
    run dr-setup
    [ "$status" -eq 0 ]
    # Already there is not news, and a setup command you can re-run safely has to
    # stop announcing things it did not do.
    [[ "$output" != *"created the kit library"* ]]
}

@test "dr-setup --print: changes nothing, including the library" {
    run dr-setup --print
    [ "$status" -eq 0 ]
    [ ! -d "$DRAUGR_KIT_STORE" ]
    # It still says what it would have done, which is the point of --print.
    [[ "$output" == *"$DRAUGR_KIT_STORE"* ]]
}

@test "dr-setup: still writes the ssh block" {
    # The library must not have displaced the reason this command exists.
    run dr-setup
    [ "$status" -eq 0 ]
    grep -q 'Host \*\.sbx' "$HOME/.ssh/config"
}
