#!/usr/bin/env bats
# DRAUGR_KIT as a list, and the library of named kits behind it.
#
# The premise is one fact from a test: sbx MERGES kits, and does not choose one.
# A test on sbx 0.37.1 showed that two mixins on one sandbox gave both their
# install commands and both their network allow rules, merged into one policy.
# All here follows from that. If it stops being true, these tests describe the
# wrong product.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-$(basename "$REPO")" DR_MOCK_STATE=running
    dr_fake_sbx_root
    dr_load_common

    # Separate for each test, so that nothing here can reach the real library.
    # $DR_TMP is on the own ext4 of WSL, where the real default also is. Thus
    # this also exercises the UNC spelling that a kit outside /mnt/<drive>
    # needs.
    export DRAUGR_KIT_STORE="$DR_TMP/kitstore"
    export WSL_DISTRO_NAME="${WSL_DISTRO_NAME:-Ubuntu}"
    DR_REPO=$REPO
}

teardown() { dr_test_teardown; }

calls() { grep "^$1 " "$DR_MOCK_LOG" || true; }

# A kit is a directory with a spec in it. The contents are important only where
# a test says so.
make_kit() {
    mkdir -p "$1"
    printf 'schemaVersion: "2"\nkind: mixin\nname: %s\ndisplayName: %s kit\n' \
        "$(basename "$1")" "$(basename "$1")" > "$1/spec.yaml"
}

# --- the resolve of one entry -----------------------------------------------

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
    # The more specific answer wins. The full configuration cascade uses that
    # rule. A repo with a directory called lua means its own.
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
    # No ":" or "@", so there is no fallback. A guess only moves the error into
    # sbx, where it is harder to understand.
    run dr_kit_resolve "nosuchkit"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# --- the resolve of the list -----------------------------------------------

@test "dr_kit_refs: resolves every entry, in order" {
    # The order stays, because sbx applies kits in the given order. Thus a later
    # entry goes on top of an earlier one.
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
    # The search for a bare entry is in two places. Thus a resolved path hides
    # half of the places where Draugr really looked.
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

# --- the digest for drift detection ------------------------------------------

@test "dr_kit_hash_all: changes when the LIBRARY kit changes" {
    # The case that a hash of one kit cannot see. It is the reason why drift
    # detection is still important with shared kits. Another repo edits the
    # library copy, and this mound is silently old.
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
    # The same two kits in the reverse order can build a different sandbox. Thus
    # a swap must read as drift, not as no change.
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    DRAUGR_KIT=".draugr/kit lua"
    one=$(dr_kit_hash_all)
    DRAUGR_KIT="lua .draugr/kit"
    [ "$(dr_kit_hash_all)" != "$one" ]
}

@test "dr_kit_hash_all: a remote reference contributes its name" {
    # Without a fetch of an OCI image at each dr-up, we cannot do more. The test
    # makes sure that a change of the reference is still detected.
    DRAUGR_KIT="ghcr.io/org/kit:v1"
    one=$(dr_kit_hash_all)
    DRAUGR_KIT="ghcr.io/org/kit:v2"
    [ "$(dr_kit_hash_all)" != "$one" ]
}

# --- dr-up builds one --kit for each entry -----------------------------------

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
    # The one that DID resolve must still reach sbx.
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
    # A library that silently follows the edits of one repo is a shared, mutable
    # dependency that nobody asked for.
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
    [[ "$output" == *"Each repo that uses it"* ]]
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
    [[ "$output" == *"no own kit"* ]]
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
    # The full reason for drift detection in a shared library. You did not touch
    # this repo, but its mound is old.
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    export DRAUGR_KIT=".draugr/kit lua"
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
    printf 'description: edited by another project\n' >> "$DRAUGR_KIT_STORE/lua/spec.yaml"
    run dr-kit drift
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed after"* ]]
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
    [[ "$output" == *"Only its NAME is compared"* ]]
}

# --- dr-kit apply ---------------------------------------------------------------
#
# A test on sbx 0.37.1 with a throwaway mound showed this, and each test below
# follows from it. `sbx kit add` refuses a kit whose name the sandbox already
# has. An add of a new one writes a new rule, and does NOT delete the old one.
# Thus an edit that narrows a kit leaves the wider rule in force. Thus apply
# does exactly one thing: it adds kits to the end of the list. It refuses the
# rest.
#
# The old test counted `kit add` calls. It passed for a long time, but the argv
# that it counted was wrong: the kit first, then a --sandbox flag that sbx does
# not have. These tests assert the argv itself.

# A mound built from the current list, so that the stamp records its source.
# Each apply starts from that state.
build_mound() {
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
}

@test "dr-kit apply: nothing to do when the kits match what the mound was built with" {
    make_kit "$REPO/.draugr/kit"
    export DRAUGR_KIT=".draugr/kit"
    build_mound
    : > "$DR_MOCK_LOG"
    run dr-kit apply --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to apply"* ]]
    [ -z "$(calls kit)" ]
}

@test "dr-kit apply: a kit added at the end is added, sandbox first" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    export DRAUGR_KIT=".draugr/kit"
    build_mound
    : > "$DR_MOCK_LOG"
    export DRAUGR_KIT=".draugr/kit lua"
    run dr-kit apply --yes
    [ "$status" -eq 0 ]
    # Exactly one call, only for the new kit, and in the order of sbx: SANDBOX
    # REF.
    [ "$(calls kit | grep -c "^kit add ")" -eq 1 ]
    [[ "$(calls kit)" == "kit add $DR_MOCK_NAME "* ]]
    [[ "$(calls kit)" == *lua* ]]
    [[ "$(calls kit)" != *--sandbox* ]]
}

@test "dr-kit apply: records the added kit, so a second apply has nothing to do" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    export DRAUGR_KIT=".draugr/kit"
    build_mound
    export DRAUGR_KIT=".draugr/kit lua"
    dr-kit apply --yes >/dev/null 2>&1
    run dr-kit apply --yes
    [[ "$output" == *"nothing to apply"* ]]
    run dr-kit drift
    [ "$status" -eq 0 ]
}

@test "dr-kit apply: an EDITED kit is refused, and names dr-up --recreate" {
    make_kit "$REPO/.draugr/kit"
    export DRAUGR_KIT=".draugr/kit"
    build_mound
    : > "$DR_MOCK_LOG"
    printf 'description: narrowed\n' >> "$REPO/.draugr/kit/spec.yaml"
    run dr-kit apply --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"changed after"* ]]
    [[ "$output" == *"dr-up --recreate"* ]]
    [ -z "$(calls kit)" ]
}

@test "dr-kit apply: a REMOVED kit is refused - sbx has no way to take one out" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    export DRAUGR_KIT=".draugr/kit lua"
    build_mound
    export DRAUGR_KIT=".draugr/kit"
    run dr-kit apply --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"dr-up --recreate"* ]]
}

@test "dr-kit apply: a kit inserted in the MIDDLE is refused, not appended out of order" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    make_kit "$DRAUGR_KIT_STORE/web"
    export DRAUGR_KIT=".draugr/kit web"
    build_mound
    export DRAUGR_KIT=".draugr/kit lua web"
    run dr-kit apply --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"no longer starts with"* ]]
}

@test "dr-kit apply: a new kit named like one the mound has is refused before sbx sees it" {
    make_kit "$REPO/.draugr/kit"
    mkdir -p "$DRAUGR_KIT_STORE/other"
    # The same name: as the project kit, in a different directory.
    printf 'schemaVersion: "2"\nkind: mixin\nname: kit\ndisplayName: clash\n' \
        > "$DRAUGR_KIT_STORE/other/spec.yaml"
    export DRAUGR_KIT=".draugr/kit"
    build_mound
    : > "$DR_MOCK_LOG"
    export DRAUGR_KIT=".draugr/kit other"
    run dr-kit apply --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *'named "kit"'* ]]
    [ -z "$(calls kit)" ]
}

@test "dr-kit apply: a stamp from before per-kit records refuses rather than guesses" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$DRAUGR_KIT_STORE/lua"
    export DRAUGR_KIT=".draugr/kit"
    build_mound
    # What an older Draugr wrote: only the combined hash.
    head -1 "$REPO/.draugr/kit.applied" > "$REPO/.draugr/kit.stamp.old"
    mv "$REPO/.draugr/kit.stamp.old" "$REPO/.draugr/kit.applied"
    export DRAUGR_KIT=".draugr/kit lua"
    run dr-kit apply --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot tell which kits"* ]]
}

@test "dr-kit drift: still reads a one-line stamp an older Draugr wrote" {
    make_kit "$REPO/.draugr/kit"
    export DRAUGR_KIT=".draugr/kit"
    build_mound
    head -1 "$REPO/.draugr/kit.applied" > "$REPO/.draugr/kit.stamp.old"
    mv "$REPO/.draugr/kit.stamp.old" "$REPO/.draugr/kit.applied"
    run dr-kit drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"matches"* ]]
}

@test "dr_kit_spec_name: reads the name sbx composes by, quoted or not" {
    mkdir -p "$DR_TMP/a" "$DR_TMP/b"
    printf 'schemaVersion: "2"\nname: plain\n' > "$DR_TMP/a/spec.yaml"
    printf 'schemaVersion: "2"\nname: "quoted"  # a comment\n' > "$DR_TMP/b/spec.yaml"
    [ "$(dr_kit_spec_name "$DR_TMP/a")" = plain ]
    [ "$(dr_kit_spec_name "$DR_TMP/b")" = quoted ]
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
# The kit store is machine-level, like the ssh bridge. Thus it belongs to the
# one command that sets up the machine. A first view of an empty directory is
# better than an explanation from dr-kit of what a kit store is.

@test "dr-setup: creates the kit library" {
    [ ! -d "$DRAUGR_KIT_STORE" ]
    run dr-setup
    [ "$status" -eq 0 ]
    [ -d "$DRAUGR_KIT_STORE" ]
    [[ "$output" == *"kit library"* ]]
}

@test "dr-setup: creates it where DRAUGR_KIT_STORE says, not only the default" {
    # A person who moved the store still wants dr-setup to make the right one.
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
    # "Already there" is not news. A setup command that you can safely run again
    # must not announce things that it did not do.
    [[ "$output" != *"created the kit library"* ]]
}

@test "dr-setup --print: changes nothing, including the library" {
    run dr-setup --print
    [ "$status" -eq 0 ]
    [ ! -d "$DRAUGR_KIT_STORE" ]
    # It still says what it does without --print. That is the purpose of
    # --print.
    [[ "$output" == *"$DRAUGR_KIT_STORE"* ]]
}

@test "dr-setup: still writes the ssh block" {
    # The library must not replace the reason for this command.
    run dr-setup
    [ "$status" -eq 0 ]
    grep -q 'Host \*\.sbx' "$HOME/.ssh/config"
}

# --- the kit name sbx will accept ---------------------------------------------
#
# Before, dr-init put the directory name of the repository directly into the
# `name:` field of the kit. sbx requires "lowercase alphanumeric with hyphens,
# 1-64 chars". Thus each project with a capital in it (TabuLua, MyApp) got a kit
# that failed at dr-up, with an sbx error two steps from the cause. Each slug
# below was tested with the real sbx kit validate, not with a read of its error
# text.

@test "dr_kit_slug: lowercases" {
    [ "$(dr_kit_slug TabuLua)" = "tabulua" ]
    [ "$(dr_kit_slug UPPER)" = "upper" ]
}

@test "dr_kit_slug: anything outside the permitted set becomes a hyphen" {
    [ "$(dr_kit_slug my_project)" = "my-project" ]
    [ "$(dr_kit_slug "My App")" = "my-app" ]
    [ "$(dr_kit_slug "Foo.Bar-Baz")" = "foo-bar-baz" ]
}

@test "dr_kit_slug: runs of hyphens collapse" {
    # Without this, "My  App" gives "my--app", which sbx refuses.
    [ "$(dr_kit_slug "My  App")" = "my-app" ]
}

@test "dr_kit_slug: leading and trailing hyphens are trimmed" {
    [ "$(dr_kit_slug ---leading)" = "leading" ]
    [ "$(dr_kit_slug trailing---)" = "trailing" ]
}

@test "dr_kit_slug: leaves an already-valid name alone" {
    [ "$(dr_kit_slug my-project-2)" = "my-project-2" ]
}

@test "dr_kit_slug: caps at 64 characters, without a trailing hyphen" {
    long=$(printf 'a%.0s' $(seq 1 80))
    out=$(dr_kit_slug "$long")
    [ "${#out}" -eq 64 ]
    [ "${out%-}" = "$out" ]
}

@test "dr_kit_slug: a name of pure punctuation falls back rather than emptying" {
    # An empty name fails validation for a second reason, which is more
    # confusing.
    [ "$(dr_kit_slug ____)" = "project" ]
    [ -n "$(dr_kit_slug ...)" ]
}

@test "dr-init: writes a kit name sbx will accept, from a capitalised repo" {
    # The exact case that broke: a repo directory with capitals in it. Beside
    # the repo that setup already made. dr_make_win_repo runs in a command
    # substitution, so its DR_WIN_TMP export never reaches this shell.
    dir="$(dirname "$REPO")/TabuLua"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@e.com
    git -C "$dir" config user.name T
    printf 'x\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm first
    cd "$dir" || return 1

    dr-init >/dev/null 2>&1
    run grep '^name:' "$dir/.draugr/kit/spec.yaml"
    [ "$output" = "name: tabulua" ]
}

@test "dr-init: displayName keeps the original spelling" {
    # Only `name` has rules. The fields for people must use the real spelling of
    # the project. Beside the repo that setup already made. dr_make_win_repo
    # runs in a command substitution, so its DR_WIN_TMP export never reaches
    # this shell.
    dir="$(dirname "$REPO")/TabuLua"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@e.com
    git -C "$dir" config user.name T
    printf 'x\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm first
    cd "$dir" || return 1

    dr-init >/dev/null 2>&1
    run grep '^displayName:' "$dir/.draugr/kit/spec.yaml"
    [[ "$output" == *"TabuLua"* ]]
}

@test "dr-init: with a DRAUGR_KIT list, writes only the first entry" {
    # If not, the full value is one path, and dr-init creates a directory with
    # the literal name ".draugr/kit lua".
    DRAUGR_KIT=".draugr/kit lua" dr-init >/dev/null 2>&1
    [ -f "$REPO/.draugr/kit/spec.yaml" ]
    [ ! -e "$REPO/.draugr/kit lua" ]
}

# --- one kit, several agents ---------------------------------------------------
#
# A test on sbx 0.37.1 showed this, and it is the reason for all of this:
#
#   requires: agent: claude  +  sbx create codex
#     -> 400 Bad Request: kit "x" requires base agent "claude" but was composed
#        with "codex"
#
# But a kit with no `requires:` block validates AND composes with each agent.
# Thus Draugr does not write the field now. It prefers a directory for each
# agent if one exists. If somebody else wrote the field, Draugr tests it itself.

# A kit that pins itself to one agent. sbx then refuses to compose it with each
# other agent.
make_pinned_kit() {
    make_kit "$1"
    printf 'requires:\n  agent: %s\n' "$2" >> "$1/spec.yaml"
}

@test "dr_kit_resolve: a per-agent directory wins over the plain one" {
    make_kit "$REPO/.draugr/kit"
    make_kit "$REPO/.draugr/kit.codex"

    DRAUGR_AGENT=codex run dr_kit_resolve ".draugr/kit"
    [ "$output" = "$REPO/.draugr/kit.codex" ]
}

@test "dr_kit_resolve: without one, the plain directory is still used" {
    make_kit "$REPO/.draugr/kit"

    DRAUGR_AGENT=codex run dr_kit_resolve ".draugr/kit"
    [ "$output" = "$REPO/.draugr/kit" ]
}

@test "dr_kit_resolve: the suffix applies to library kits too" {
    make_kit "$DRAUGR_KIT_STORE/lua"
    make_kit "$DRAUGR_KIT_STORE/lua.codex"

    DRAUGR_AGENT=codex run dr_kit_resolve "lua"
    [ "$output" = "$DRAUGR_KIT_STORE/lua.codex" ]
    DRAUGR_AGENT=claude run dr_kit_resolve "lua"
    [ "$output" = "$DRAUGR_KIT_STORE/lua" ]
}

@test "dr_kit_resolve: an OCI reference gets no agent suffix grafted on" {
    # We must not make up a tag in the registry of somebody else.
    DRAUGR_AGENT=codex run dr_kit_resolve "ghcr.io/org/kit:v1"
    [ "$output" = "ghcr.io/org/kit:v1" ]
}

@test "dr-init: the generated kit does not pin an agent" {
    run dr-init --agent codex
    [ "$status" -eq 0 ]
    # A pin makes a change of agent into an edit of a committed file. Anchored,
    # so that the comment that explains the absence does not count as the field.
    run grep -E '^[[:space:]]*(requires:|agent:)' "$REPO/.draugr/kit/spec.yaml"
    [ "$status" -ne 0 ]

    # And the test that reads it agrees that nothing conflicts.
    export DRAUGR_KIT=.draugr/kit
    DRAUGR_AGENT=gemini run dr_kit_agent_conflicts
    [ -z "$output" ]
}

@test "kit conflicts: a kit pinned to another agent is named before creation" {
    make_pinned_kit "$REPO/.draugr/kit" claude
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=codex

    run dr_kit_agent_conflicts
    [ "$output" = "$REPO/.draugr/kit claude" ]
}

@test "kit conflicts: a kit pinned to THIS agent is not a conflict" {
    make_pinned_kit "$REPO/.draugr/kit" codex
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=codex

    run dr_kit_agent_conflicts
    [ -z "$output" ]
}

@test "kit conflicts: an unpinned kit is not a conflict for anyone" {
    make_kit "$REPO/.draugr/kit"
    export DRAUGR_KIT=.draugr/kit

    DRAUGR_AGENT=codex run dr_kit_agent_conflicts
    [ -z "$output" ]
    DRAUGR_AGENT=gemini run dr_kit_agent_conflicts
    [ -z "$output" ]
}

@test "dr-up: refuses rather than letting sbx fail two steps from the cause" {
    make_pinned_kit "$REPO/.draugr/kit" claude
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=codex DR_MOCK_STATE=absent

    run dr-up
    [ "$status" -ne 0 ]
    [[ "$output" == *'requires agent "claude"'* ]]
    [[ "$output" == *codex* ]]
    # And it never came as far as a try.
    [ -z "$(calls create)" ]
}

@test "dr-up: an unpinned kit creates the mound for any agent" {
    make_kit "$REPO/.draugr/kit"
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=codex DR_MOCK_STATE=absent

    run dr-up
    [ "$status" -eq 0 ]
    [[ "$(calls create)" == *codex* ]]
}

@test "dr-kit validate: warns about a pin sbx's own validate accepts" {
    make_pinned_kit "$REPO/.draugr/kit" claude
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=codex

    run dr-kit validate
    # sbx said yes (the mock always does), and Draugr said "yes, but".
    [[ "$output" == *'requires agent "claude"'* ]]
}

@test "dr-up --recreate: refuses BEFORE destroying the mound it was going to replace" {
    make_pinned_kit "$REPO/.draugr/kit" claude
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=codex DR_MOCK_STATE=running

    run dr-up --recreate --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *'requires agent "claude"'* ]]
    # The full purpose: a working mound is not discarded for a problem that was
    # visible before the first change.
    [ -z "$(calls rm)" ]
    [ -z "$(calls create)" ]
}

# --- a kit named after an agent ----------------------------------------------
#
# sbx composes the own kit of the agent with the kit of the project, and refuses
# two with the same name. A repository in a directory called "claude" did
# exactly that. The failure came from sbx at create time: `duplicate kit name
# "claude"`. Just before, dr-kit validate said that the kit was composable.

make_named_kit() {
    mkdir -p "$1"
    printf 'schemaVersion: "2"\nkind: mixin\nname: %s\ndisplayName: %s\n' "$2" "$2" > "$1/spec.yaml"
}

@test "dr_kit_slug: a name that is the configured agent gets out of its way" {
    DRAUGR_AGENT=claude
    [ "$(dr_kit_slug claude)" = "claude-project" ]
    DRAUGR_AGENT=gemini
    [ "$(dr_kit_slug gemini)" = "gemini-project" ]
}

@test "dr_kit_slug: an agent Draugr has a module for is avoided too" {
    # So that a later change of DRAUGR_AGENT does not make a working kit into
    # one that sbx refuses to compose.
    DRAUGR_AGENT=claude
    [ "$(dr_kit_slug codex)" = "codex-project" ]
}

@test "dr_kit_slug: a name that merely contains an agent name is left alone" {
    DRAUGR_AGENT=claude
    [ "$(dr_kit_slug claude-tools)" = "claude-tools" ]
    [ "$(dr_kit_slug myclaude)" = "myclaude" ]
}

@test "dr_kit_reserved_names: covers the configured agent and the modules" {
    DRAUGR_AGENT=gemini run dr_kit_reserved_names
    [[ "$output" == *gemini* ]]
    [[ "$output" == *claude* ]]
    [[ "$output" == *codex* ]]
}

@test "kit name conflicts: a kit named after the agent is reported" {
    make_named_kit "$REPO/.draugr/kit" claude
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=claude

    run dr_kit_name_conflicts
    [ "$output" = "$REPO/.draugr/kit claude" ]
}

@test "kit name conflicts: an ordinary name is not one" {
    make_named_kit "$REPO/.draugr/kit" myproject
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=claude

    run dr_kit_name_conflicts
    [ -z "$output" ]
}

@test "kit name conflicts: an indented name: is not the kit's own" {
    # publishedPorts entries also have a name:. If one of those is read as the
    # name of the kit, it reports a conflict with a port called "claude". Worse,
    # it misses the real name at column 0.
    make_named_kit "$REPO/.draugr/kit" myproject
    printf 'publishedPorts:\n  - container: 5173\n    name: claude\n' >> "$REPO/.draugr/kit/spec.yaml"
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=claude

    run dr_kit_name_conflicts
    [ -z "$output" ]
}

@test "dr-kit validate: says so, instead of calling it composable" {
    make_named_kit "$REPO/.draugr/kit" claude
    export DRAUGR_KIT=.draugr/kit DRAUGR_AGENT=claude

    run dr-kit validate
    [[ "$output" == *'is also the name of an agent'* ]]
    # The claim that sent somebody to dr-up with a kit that was not able to be
    # created.
    [[ "$output" != *"composable with claude"* ]]
}

@test "dr-init: the kit it generates is composable in a directory named claude" {
    # The regression, from end to end. dr-init made the slug from the directory
    # name with no change. Thus C:\Code\claude gave `name: claude`. That is
    # valid, but sbx refused it at create time, as a duplicate of the own kit of
    # the agent.
    local repo
    repo=$(dr_make_win_repo claude) || skip "no writable path under /mnt/<drive>"
    cd "$repo" || return 1
    DR_REPO=$repo

    run dr-init --agent claude
    [ "$status" -eq 0 ]
    run grep -x 'name: claude' "$repo/.draugr/kit/spec.yaml"
    [ "$status" -ne 0 ]
    run grep -x 'name: claude-project' "$repo/.draugr/kit/spec.yaml"
    [ "$status" -eq 0 ]
}
