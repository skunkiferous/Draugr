#!/usr/bin/env bats
# The loop to build your own kit: what was refused, what was opened, what was
# written down, and what refuses to destroy the difference.
#
# The parts that talk to sbx use the mock, which replays fixed JSON. The real
# test here is the logic of Draugr on top of it: the split between kit rules,
# ad-hoc rules and machine defaults, and the YAML edit that ends the loop.

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

    # The helpers run in-process here, so nothing ran the configuration cascade
    # for them. dr-kit and dr-policy get this from their own dr_context.
    DRAUGR_KIT=.draugr/kit
}

teardown() { dr_test_teardown; }

# A kit whose allow list holds the names that the caller gives.
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

# A kit that narrows the defaults, and allows nothing of its own: network: is
# present, allow: is absent. A normal shape, but make_kit_with can never make
# it. That is why `dr-kit adopt` failed on it until the fix.
make_kit_deny_only() {
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\nkind: mixin\nname: k\ncaps:\n  network:\n    deny:\n      - telemetry.bad.example\npublishedPorts:\n  - container: 5173\n' \
        > "$REPO/.draugr/kit/spec.yaml"
}

# --- reading a kit's allow list ------------------------------------------------

@test "dr_kit_allow_list: reads the hosts a kit declares" {
    make_kit_with one.example.com two.example.com
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [[ "$output" == *"one.example.com"* ]]
    [[ "$output" == *"two.example.com"* ]]
}

@test "dr_kit_allow_list: does not wander into deny or publishedPorts" {
    # A bare grep for "each - line" falls into this trap. That is why this reads
    # only the allow: key, not the full file.
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
    # The log records host:443. Neither `sbx policy allow network` nor the allow
    # list of a kit takes a port. Thus a port here is only a trap.
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
    # Both apply to the sandbox, and both are in the same table. If this is
    # wrong, dr-kit adopt copies the rules of the kit back into the kit.
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

@test "dr_policy_unadopted: a host adopted into a SECOND kit is not unadopted" {
    # dr-kit adopt writes into the own kit of the repo. But a host is written
    # down if any kit holds it. When Draugr read only the first kit, a project
    # with several kits got a warning about loss of hosts that a kit held. It
    # offered --force, and that throws away the hosts that nobody adopted. A
    # test on a real gateway with three kits showed this.
    make_kit_with something.else.example
    mkdir -p "$REPO/kits/extra"
    printf 'schemaVersion: "2"\nkind: mixin\nname: extra\ncaps:\n  network:\n    allow:\n      - %s\n' \
        opened.example.com > "$REPO/kits/extra/spec.yaml"
    DRAUGR_KIT=".draugr/kit kits/extra"
    export DR_MOCK_ADHOC="opened.example.com"
    run dr_policy_unadopted
    [ -z "$output" ]
}

@test "dr_policy_unadopted: with no kit at all, everything is unadopted" {
    # There is no place where it was written down, so nothing was.
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
    # An important failure: "nothing refused" and "the record was lost" look the
    # same. Only one of them means that the build is good.
    run dr-policy --denied
    [ "$status" -eq 0 ]
    [[ "$output" == *"a restart clears it"* ]]
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
    # Both cannot be true at the same time. If they are, sbx rejects the file.
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
    # And the new host is under allow:, not in some other place that parses.
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [[ "$output" == *"opened.example.com"* ]]
}

@test "dr-kit adopt: creates allow: when the kit has only deny:" {
    make_kit_deny_only
    export DR_MOCK_ADHOC="opened.example.com"
    run dr-kit adopt -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"created caps.network.allow"* ]]
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [[ "$output" == *"opened.example.com"* ]]
}

@test "dr-kit adopt: creating allow: leaves deny and publishedPorts alone" {
    make_kit_deny_only
    export DR_MOCK_ADHOC="opened.example.com"
    dr-kit adopt -y >/dev/null 2>&1
    grep -q "telemetry.bad.example" "$REPO/.draugr/kit/spec.yaml"
    grep -q "container: 5173" "$REPO/.draugr/kit/spec.yaml"
}

@test "dr-kit adopt: writes hosts in the order they were reported" {
    # `for (i in want)` in awk has no fixed order, and this file is committed.
    # Thus a random order gives a false diff on each adopt.
    #
    # Read the FILE, not dr_kit_allow_list. That helper pipes through `sort -u`.
    # A comparison with it passes, whatever the order that adopt wrote.
    make_kit_with
    export DR_MOCK_ADHOC="b.example.com a.example.com"
    expected=$(dr_policy_unadopted)
    dr-kit adopt -y >/dev/null 2>&1
    # Only the allow: block. A bare `sed -n 's/^      - //p'` also finds deny:,
    # whose items have the same indent.
    written=$(awk '/^    allow:/ { f = 1; next }
                   f && /^      - / { sub(/^      - /, ""); print; next }
                   f { exit }' "$REPO/.draugr/kit/spec.yaml")
    [ "$expected" = "$written" ]
}

@test "dr-kit adopt: quotes a wildcard, which YAML reads as an alias when bare" {
    make_kit_with
    export DR_MOCK_ADHOC="**.example.com"
    dr-kit adopt -y >/dev/null 2>&1
    grep -qF '      - "**.example.com"' "$REPO/.draugr/kit/spec.yaml"
}

@test "dr-kit adopt: quotes a wildcard when CREATING the allow: key too" {
    make_kit_deny_only
    export DR_MOCK_ADHOC="**.example.com"
    dr-kit adopt -y >/dev/null 2>&1
    grep -qF '      - "**.example.com"' "$REPO/.draugr/kit/spec.yaml"
    # And it still reads back as the same host, without quotes. Thus a second
    # adopt does not add it again.
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [ "$output" = "**.example.com" ]
}

@test "dr-kit adopt: leaves a plain host unquoted" {
    make_kit_with
    export DR_MOCK_ADHOC="opened.example.com"
    dr-kit adopt -y >/dev/null 2>&1
    grep -qF '      - opened.example.com' "$REPO/.draugr/kit/spec.yaml"
    ! grep -qF '"opened.example.com"' "$REPO/.draugr/kit/spec.yaml"
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

@test "dr-kit adopt: a kit with no network: block is reported, not guessed at" {
    # Still a refusal, and for the same reason. With no caps.network, there is
    # no clear place for the block. A kit edited by a guess is worse than a
    # request to edit it yourself.
    #
    # Note the change: a kit that HAS network: but no allow: is no longer this
    # case. There the location is not a guess, so adopt creates the key, and
    # does not refuse. Refer to "creates allow: when the kit has only deny:".
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\nkind: mixin\nname: k\n' > "$REPO/.draugr/kit/spec.yaml"
    before=$(cat "$REPO/.draugr/kit/spec.yaml")
    export DR_MOCK_ADHOC="opened.example.com"
    run dr-kit adopt -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not find caps.network"* ]]
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
# A rule for a sandbox does not live longer than the sandbox. Thus both commands
# that destroy a mound must refuse while the list is only in the daemon. A test
# on the real sbx showed this. After `sbx rm`, a look-up of the rule by id gives
# "policy or rule not found".

@test "dr-rm: refuses while a host is open and not in the kit" {
    export DR_MOCK_ADHOC="opened.example.com"
    run dr-rm -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"opened.example.com"* ]]
    [[ "$output" == *"dr-kit adopt"* ]]
    # And it did not come near the destruction of anything.
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
    # The worst time to lose them. You recreate the mound exactly when the build
    # works at last.
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
# dr-up writes these on each start, from an address that is valid only for this
# boot. When Draugr read them as ad-hoc hosts, dr-up --recreate refused and gave
# the advice `dr-kit adopt`. That commits 172.19.192.26:11435 to the repository.
# DRAUGR_HOST_PORTS exists to avoid exactly that.

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
    # Only dr-hostport writes bare addresses. A domain on the same port came
    # from dr-policy --allow, and still goes in the kit.
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
