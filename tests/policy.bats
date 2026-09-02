#!/usr/bin/env bats
# The build-your-own-kit loop: what was refused, what was opened, what got
# written down, and what refuses to destroy the difference.
#
# The parts that talk to sbx are exercised through the mock, which replays canned
# JSON. What is genuinely tested here is Draugr's own reasoning on top of it: the
# three-way split between a kit's rules, ad-hoc rules and the machine-wide
# defaults, and the YAML edit that ends the loop.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-$(basename "$REPO")" DR_MOCK_STATE=running
    dr_fake_sbx_root
    dr_load_common
    DR_REPO=$REPO
    DRAUGR_SANDBOX=$DR_MOCK_NAME

    # The helpers are called in-process here, so nothing has run the config
    # cascade for them. dr-kit and dr-policy get this from their own dr_context.
    DRAUGR_KIT=.draugr/kit
}

teardown() { dr_test_teardown; }

# A kit whose allow list is whatever the caller names.
make_kit_with() {
    mkdir -p "$REPO/.draugr/kit"
    {
        printf 'schemaVersion: "2"\nkind: mixin\nname: k\ncaps:\n  network:\n'
        if [ $# -eq 0 ]; then
            printf '    allow: []\n'
        else
            printf '    allow:\n'
            printf '      - %s\n' "$@"
        fi
        printf '    deny:\n      - telemetry.bad.example\npublishedPorts:\n  - container: 5173\n'
    } > "$REPO/.draugr/kit/spec.yaml"
}

# --- reading a kit's allow list ------------------------------------------------

@test "dr_kit_allow_list: reads the hosts a kit declares" {
    make_kit_with one.example.com two.example.com
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [[ "$output" == *"one.example.com"* ]]
    [[ "$output" == *"two.example.com"* ]]
}

@test "dr_kit_allow_list: does not wander into deny or publishedPorts" {
    # The trap a bare "every - line" grep would fall into, and the reason this
    # is scoped to the allow: key rather than to the file.
    make_kit_with one.example.com
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [[ "$output" != *"telemetry.bad.example"* ]]
    [[ "$output" != *"5173"* ]]
}

@test "dr_kit_allow_list: an empty list reads as nothing, not as a blank entry" {
    make_kit_with
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [ -z "$output" ]
}

@test "dr_kit_allow_list: a kit with no spec is not an error" {
    mkdir -p "$REPO/.draugr/kit"
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "dr_kit_allow_list: strips a trailing comment from an entry" {
    mkdir -p "$REPO/.draugr/kit"
    printf 'caps:\n  network:\n    allow:\n      - one.example.com   # why we need it\n' \
        > "$REPO/.draugr/kit/spec.yaml"
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [ "$output" = "one.example.com" ]
}

# --- what was refused, and what was opened ------------------------------------

@test "dr_policy_denied: names the hosts, without the port" {
    # The log records host:443; neither `sbx policy allow network` nor a kit's
    # allow list takes a port, so carrying it through would only be a trap.
    export DR_MOCK_DENIED="a.example.com b.example.com"
    run dr_policy_denied
    [[ "$output" == *"a.example.com"* ]]
    [[ "$output" != *":443"* ]]
}

@test "dr_policy_denied: nothing refused is empty, not an error" {
    run dr_policy_denied
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "dr_policy_adhoc: reports hosts opened by hand" {
    export DR_MOCK_ADHOC="opened.example.com"
    run dr_policy_adhoc
    [ "$output" = "opened.example.com" ]
}

@test "dr_policy_adhoc: a kit's own rule is not an ad-hoc one" {
    # Both are scoped to the sandbox and both appear in the same table. Getting
    # this wrong would have dr-kit adopt copy the kit's rules back into itself.
    export DR_MOCK_ADHOC="opened.example.com" DR_MOCK_KITHOST="fromkit.example.com"
    run dr_policy_adhoc
    [[ "$output" == *"opened.example.com"* ]]
    [[ "$output" != *"fromkit.example.com"* ]]
}

@test "dr_policy_unadopted: a host already in the kit is not unadopted" {
    make_kit_with opened.example.com
    export DR_MOCK_ADHOC="opened.example.com"
    run dr_policy_unadopted
    [ -z "$output" ]
}

@test "dr_policy_unadopted: a host the kit lacks is" {
    make_kit_with something.else.example
    export DR_MOCK_ADHOC="opened.example.com"
    run dr_policy_unadopted
    [ "$output" = "opened.example.com" ]
}

@test "dr_policy_unadopted: with no kit at all, everything is unadopted" {
    # There is nowhere for it to have been written down, so nothing has been.
    export DR_MOCK_ADHOC="opened.example.com"
    run dr_policy_unadopted
    [ "$output" = "opened.example.com" ]
}

# --- dr-policy --denied --------------------------------------------------------

@test "dr-policy --denied: lists what was refused, and how to open it" {
    export DR_MOCK_DENIED="blocked.example.com"
    run dr-policy --denied
    [ "$status" -eq 0 ]
    [[ "$output" == *"blocked.example.com"* ]]
    [[ "$output" == *"dr-policy --allow blocked.example.com"* ]]
    [[ "$output" == *"dr-kit adopt"* ]]
}

@test "dr-policy --denied: an empty log says the daemon may have restarted" {
    # The failure mode worth naming: "nothing refused" and "the record was lost"
    # look identical, and only one of them means the build is fine.
    run dr-policy --denied
    [ "$status" -eq 0 ]
    [[ "$output" == *"restarting it clears this"* ]]
}

# --- dr-kit adopt --------------------------------------------------------------

@test "dr-kit adopt: writes an opened host into the kit" {
    make_kit_with
    export DR_MOCK_ADHOC="opened.example.com"
    run dr-kit adopt -y
    [ "$status" -eq 0 ]
    grep -q "^      - opened.example.com$" "$REPO/.draugr/kit/spec.yaml"
}

@test "dr-kit adopt: turns 'allow: []' into a real list" {
    make_kit_with
    export DR_MOCK_ADHOC="opened.example.com"
    dr-kit adopt -y >/dev/null 2>&1
    # Both cannot be true at once, and sbx would reject the file if they were.
    ! grep -q 'allow: \[\]' "$REPO/.draugr/kit/spec.yaml"
}

@test "dr-kit adopt: keeps the entries that were already there" {
    make_kit_with existing.example.com
    export DR_MOCK_ADHOC="opened.example.com"
    dr-kit adopt -y >/dev/null 2>&1
    grep -q "existing.example.com" "$REPO/.draugr/kit/spec.yaml"
    grep -q "opened.example.com" "$REPO/.draugr/kit/spec.yaml"
}

@test "dr-kit adopt: leaves deny and publishedPorts alone" {
    make_kit_with existing.example.com
    export DR_MOCK_ADHOC="opened.example.com"
    dr-kit adopt -y >/dev/null 2>&1
    grep -q "telemetry.bad.example" "$REPO/.draugr/kit/spec.yaml"
    grep -q "container: 5173" "$REPO/.draugr/kit/spec.yaml"
    # And the new host landed under allow:, not somewhere that happened to parse.
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [[ "$output" == *"opened.example.com"* ]]
}

@test "dr-kit adopt: running it twice adds nothing the second time" {
    make_kit_with
    export DR_MOCK_ADHOC="opened.example.com"
    dr-kit adopt -y >/dev/null 2>&1
    run dr-kit adopt -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to adopt"* ]]
    [ "$(grep -c 'opened.example.com' "$REPO/.draugr/kit/spec.yaml")" -eq 1 ]
}

@test "dr-kit adopt: a kit with no allow: key is reported, not guessed at" {
    # Refusing beats writing the block somewhere that happens to parse: a kit
    # edited by a guess is worse than one you were asked to edit yourself.
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\nkind: mixin\nname: k\n' > "$REPO/.draugr/kit/spec.yaml"
    before=$(cat "$REPO/.draugr/kit/spec.yaml")
    export DR_MOCK_ADHOC="opened.example.com"
    run dr-kit adopt -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not find caps.network.allow"* ]]
    [ "$(cat "$REPO/.draugr/kit/spec.yaml")" = "$before" ]
}

@test "dr-kit adopt: without a kit of its own, says where to start" {
    export DR_MOCK_ADHOC="opened.example.com"
    run dr-kit adopt -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"dr-init"* ]]
}

# --- the guards ----------------------------------------------------------------
#
# A rule scoped to a sandbox does not outlive it, so both of the commands that
# destroy a mound have to refuse while the list is only in the daemon. Measured
# against real sbx: after `sbx rm`, looking the rule up by id gives "policy or
# rule not found".

@test "dr-rm: refuses while a host is open and not in the kit" {
    export DR_MOCK_ADHOC="opened.example.com"
    run dr-rm -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"opened.example.com"* ]]
    [[ "$output" == *"dr-kit adopt"* ]]
    # And it got nowhere near destroying anything.
    ! grep -q "^rm " "$DR_MOCK_LOG"
}

@test "dr-rm: --force destroys it anyway, having said so" {
    export DR_MOCK_ADHOC="opened.example.com"
    run dr-rm --force -y
    [ "$status" -eq 0 ]
    grep -q "^rm " "$DR_MOCK_LOG"
}

@test "dr-rm: says nothing once the kit declares them" {
    make_kit_with opened.example.com
    export DR_MOCK_ADHOC="opened.example.com" DRAUGR_KIT=.draugr/kit
    run dr-rm -y
    [ "$status" -eq 0 ]
    [[ "$output" != *"dr-kit adopt"* ]]
}

@test "dr-up --recreate: refuses BEFORE removing the mound" {
    # The cruellest possible moment to lose them: recreating is exactly what you
    # do once the build finally works.
    export DR_MOCK_ADHOC="opened.example.com" DR_MOCK_STATE=running
    run dr-up --recreate -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"opened.example.com"* ]]
    [ -z "$(grep '^rm ' "$DR_MOCK_LOG" || true)" ]
    [ -z "$(grep '^create ' "$DR_MOCK_LOG" || true)" ]
}

@test "dr-up --recreate: proceeds once they are adopted" {
    make_kit_with opened.example.com
    export DR_MOCK_ADHOC="opened.example.com" DR_MOCK_STATE=running DRAUGR_KIT=.draugr/kit
    run dr-up --recreate -y
    [ "$status" -eq 0 ]
    grep -q "^create " "$DR_MOCK_LOG"
}

@test "dr-up without --recreate is not guarded: it destroys nothing" {
    export DR_MOCK_ADHOC="opened.example.com" DR_MOCK_STATE=running
    run dr-up
    [ "$status" -eq 0 ]
}

# --- rules DRAUGR_HOST_PORTS owns --------------------------------------------
#
# These are written by dr-up on every start, from an address that is only valid
# for this boot. Treating them as ad-hoc hosts made dr-up --recreate refuse and
# recommend `dr-kit adopt`, which would have committed 172.19.192.26:11435 to the
# repository - the exact thing DRAUGR_HOST_PORTS exists to avoid.

@test "dr_policy_unadopted: a rule dr-hostport wrote is not unadopted" {
    export DR_MOCK_ADHOC="172.19.192.26:11435"
    DRAUGR_HOST_PORTS=11435
    run dr_policy_unadopted
    [ -z "$output" ]
}

@test "dr_policy_unadopted: an address on an undeclared port is still reported" {
    export DR_MOCK_ADHOC="172.19.192.26:5432"
    DRAUGR_HOST_PORTS=11435
    run dr_policy_unadopted
    [ "$output" = "172.19.192.26:5432" ]
}

@test "dr_policy_unadopted: a hostname on a declared port is somebody else's" {
    # Only dr-hostport writes bare addresses. A domain on the same port came from
    # dr-policy --allow and still belongs in the kit.
    export DR_MOCK_ADHOC="ollama.example.com:11435"
    DRAUGR_HOST_PORTS=11435
    run dr_policy_unadopted
    [ "$output" = "ollama.example.com:11435" ]
}

@test "dr_policy_unadopted: with no host ports declared, nothing is exempt" {
    export DR_MOCK_ADHOC="172.19.192.26:11435"
    DRAUGR_HOST_PORTS=
    run dr_policy_unadopted
    [ "$output" = "172.19.192.26:11435" ]
}
