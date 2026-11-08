#!/usr/bin/env bats
# Access to a service on the HOST from inside a mound, without a fixed address
# that becomes wrong.
#
# The test is not about "can it add a policy rule". sbx does that. It is about
# the records for an address that changes: a late resolve, a search for the
# rules that this command wrote for addresses that the machine does not have
# now, and no change to each rule from another source. A mistake in the last
# part runs `policy rm` on the rule of somebody else. Thus most of these tests
# are about what is NOT touched.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    SANDBOX="draugr-$(basename "$REPO")"
    export DR_MOCK_NAME="$SANDBOX" DR_MOCK_STATE=running
    dr_fake_sbx_root
}

teardown() { dr_test_teardown; }

# The helpers run in-process, so nothing ran the configuration cascade for them.
# The dr-* commands get this from their own dr_context.
load_helpers() {
    dr_load_common
    DRAUGR_SANDBOX=$SANDBOX
}

# --- the address ------------------------------------------------------------

@test "dr_host_ip: reports the address this host would leave from" {
    load_helpers
    run dr_host_ip
    [ "$status" -eq 0 ]
    [ "$output" = "172.19.192.26" ]
}

@test "dr_host_ip: a route with no source address is a failure, not an empty answer" {
    # An empty string that looks like a success becomes ":8080", and goes to sbx
    # as a rule. That rule then matches nothing.
    export DR_MOCK_HOST_IP=
    load_helpers
    run dr_host_ip
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --- which rules are ours ---------------------------------------------------

@test "dr_hostport_rules: finds the rule written for that port" {
    export DR_MOCK_ADHOC="172.19.192.26:11434"
    load_helpers
    run dr_hostport_rules 11434
    [ "$output" = "rule-0" ]
}

@test "dr_hostport_rules: a rule for another port is not ours to remove" {
    export DR_MOCK_ADHOC="172.19.192.26:5432"
    load_helpers
    run dr_hostport_rules 11434
    [ -z "$output" ]
}

@test "dr_hostport_rules: a kit's own rule is never returned" {
    # editable:false tells them apart, the same as in dr_policy_adhoc. A removal
    # of a kit rule here silently undoes what the kit composed.
    export DR_MOCK_KITHOST="172.19.192.26:11434"
    load_helpers
    run dr_hostport_rules 11434
    [ -z "$output" ]
}

@test "dr_hostport_rules: a rule holding several resources is left alone" {
    # This command always writes one resource for each rule. Thus a rule with
    # more than one came from another source. Its removal also removes the
    # other resources.
    export DR_MOCK_MULTI="172.19.192.26:11434 example.com:443"
    load_helpers
    run dr_hostport_rules 11434
    [ -z "$output" ]
}

@test "dr_hostport_rules: a hostname on that port is not an address rule" {
    export DR_MOCK_ADHOC="ollama.example.com:11434"
    load_helpers
    run dr_hostport_rules 11434
    [ -z "$output" ]
}

# --- opening ----------------------------------------------------------------

@test "dr-hostport: opens the port at the address the host has now" {
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"172.19.192.26:11434"* ]]
    grep -q "policy allow network --sandbox $SANDBOX 172.19.192.26:11434" "$DR_MOCK_LOG"
}

@test "dr-hostport: already open at the right address changes nothing" {
    # This runs at each dr-up. A new rule each time changes the machine state
    # without need, and makes the output useless.
    export DR_MOCK_ADHOC="172.19.192.26:11434"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"already open"* ]]
    ! grep -q "policy allow" "$DR_MOCK_LOG" || return 1
    ! grep -q "policy rm" "$DR_MOCK_LOG"
}

@test "dr-hostport: an address from a previous boot is replaced" {
    export DR_MOCK_ADHOC="10.0.0.5:11434"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"replaced 1 old"* ]]
    grep -q "policy rm network --sandbox $SANDBOX --id rule-0" "$DR_MOCK_LOG"
    grep -q "policy allow network --sandbox $SANDBOX 172.19.192.26:11434" "$DR_MOCK_LOG"
}

@test "dr-hostport: the stale rule goes before the new one is added" {
    # After a reboot, the machine can get back an old address. A removal after
    # the add then deletes the new rule. The port stays closed, but the command
    # reports a success.
    export DR_MOCK_ADHOC="172.19.192.26:11434 10.0.0.5:11434"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    rm_line=$(grep -n "policy rm" "$DR_MOCK_LOG" | tail -1 | cut -d: -f1)
    allow_line=$(grep -n "policy allow" "$DR_MOCK_LOG" | tail -1 | cut -d: -f1)
    [ "$rm_line" -lt "$allow_line" ]
}

@test "dr-hostport: a rule for a different port survives the refresh" {
    export DR_MOCK_ADHOC="10.0.0.5:5432"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    ! grep -q "policy rm" "$DR_MOCK_LOG"
}

# --- closing ----------------------------------------------------------------

@test "dr-hostport --close: removes the rule for that port" {
    export DR_MOCK_ADHOC="172.19.192.26:11434"
    run dr-hostport --close 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"closed host port 11434"* ]]
    grep -q "policy rm network --sandbox $SANDBOX --id rule-0" "$DR_MOCK_LOG"
}

@test "dr-hostport --close: nothing to close is not an error" {
    run dr-hostport --close 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"was not open"* ]]
}

# --- refusals ---------------------------------------------------------------

@test "dr-hostport: refuses something that is not a port number" {
    # sbx takes "11434/tcp" as a hostname, matches nothing, and looks exactly
    # like a rule that was never added.
    run dr-hostport 11434/tcp
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a port number"* ]]
    ! grep -q "policy allow" "$DR_MOCK_LOG"
}

@test "dr-hostport: refuses a port outside the range" {
    run dr-hostport 70000
    [ "$status" -ne 0 ]
    [[ "$output" == *"out of range"* ]]
}

@test "dr-hostport: says so when this host has no address to offer" {
    export DR_MOCK_HOST_IP=
    run dr-hostport 11434
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not find the address of this host"* ]]
    ! grep -q "policy allow" "$DR_MOCK_LOG"
}

# --- the loopback trap ------------------------------------------------------

@test "dr-hostport: warns when the service is bound to loopback only" {
    # The rule is still added, because a correct restart of the service can
    # come soon. But in the mound, 127.0.0.1 is the mound. Thus this fails in
    # the same way as a policy denial.
    export DR_MOCK_LISTEN="127.0.0.1:11434"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"listens only on loopback"* ]]
    grep -q "policy allow network" "$DR_MOCK_LOG"
}

@test "dr-hostport: no warning when it is bound to every interface" {
    export DR_MOCK_LISTEN="*:11434"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" != *"loopback only"* ]]
}

@test "dr-hostport: nothing listening yet is not worth a warning" {
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" != *"loopback only"* ]]
}

# --- listing ----------------------------------------------------------------

@test "dr-hostport: with nothing open, says so and names the config key" {
    run dr-hostport
    [ "$status" -eq 0 ]
    [[ "$output" == *"no host ports"* ]]
    [[ "$output" == *"DRAUGR_HOST_PORTS"* ]]
}

@test "dr-hostport: a rule for a former address is listed as stale" {
    # A reboot leaves this state. Without this, it looks the same as a working
    # rule.
    export DR_MOCK_ADHOC="10.0.0.5:11434"
    run dr-hostport
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.5:11434"* ]]
    [[ "$output" == *"old. This host is now"* ]]
}

@test "dr-hostport: a current rule is not called stale" {
    export DR_MOCK_ADHOC="172.19.192.26:11434"
    run dr-hostport
    [ "$status" -eq 0 ]
    [[ "$output" == *"172.19.192.26:11434"* ]]
    [[ "$output" != *"stale"* ]]
}

@test "dr-hostport: listing changes nothing" {
    export DR_MOCK_ADHOC="10.0.0.5:11434"
    run dr-hostport
    ! grep -q "policy allow" "$DR_MOCK_LOG" || return 1
    ! grep -q "policy rm" "$DR_MOCK_LOG"
}

# --- dr-up applies it -------------------------------------------------------

@test "dr-up: DRAUGR_HOST_PORTS is applied on every start" {
    # Not only on the create. The address is true only for this boot. Thus the
    # important up is the first one after a reboot, when the mound already
    # exists, and nothing is created.
    export DRAUGR_HOST_PORTS=11434
    run dr-up
    [ "$status" -eq 0 ]
    grep -q "policy allow network --sandbox $SANDBOX 172.19.192.26:11434" "$DR_MOCK_LOG"
}

@test "dr-up: several host ports are all applied" {
    export DRAUGR_HOST_PORTS="11434 5432"
    run dr-up
    [ "$status" -eq 0 ]
    grep -q "policy allow network --sandbox $SANDBOX 172.19.192.26:11434" "$DR_MOCK_LOG"
    grep -q "policy allow network --sandbox $SANDBOX 172.19.192.26:5432" "$DR_MOCK_LOG"
}

@test "dr-up: with none declared, no policy call is made at all" {
    run dr-up
    [ "$status" -eq 0 ]
    ! grep -q "policy allow" "$DR_MOCK_LOG"
}

# --- tell the mound where this host is ---------------------------------------
#
# The mound cannot find this alone. It has no `ip` command, and
# host.docker.internal is its own gateway. Thus dr-hostport writes it in. These
# tests assert the command line that Draugr built. That part must be correct.
# The mock keeps no filesystem for this.

@test "dr-hostport: tells the mound this host address" {
    run dr-hostport 11435
    [ "$status" -eq 0 ]
    grep -q "DRAUGR_HOST_ADDR=172.19.192.26" "$DR_MOCK_LOG"
    grep -q "HOME/.draugr/host.env" "$DR_MOCK_LOG"
}

@test "dr-hostport: the file lists what is open, not what was asked for" {
    # A second port that this run did not touch still belongs in the file. The
    # numbers are sorted, so that the content does not change between runs.
    export DR_MOCK_ADHOC="172.19.192.26:11435 172.19.192.26:5432"
    run dr-hostport 11435
    [ "$status" -eq 0 ]
    grep -q 'DRAUGR_HOST_PORTS="5432 11435"' "$DR_MOCK_LOG"
}

@test "dr-hostport: an address from a previous boot is not written in" {
    # Only the rules for the CURRENT address count. Thus an old rule from a
    # reboot cannot add a port that the mound then cannot reach.
    export DR_MOCK_ADHOC="10.0.0.5:9999"
    run dr-hostport 11435
    [ "$status" -eq 0 ]
    ! grep -q "9999" "$DR_MOCK_LOG"
}

@test "dr-hostport: writes nothing into a mound that is not running" {
    # A start of one only to put a file in it makes a --close into a boot.
    export DR_MOCK_STATE=stopped
    run dr-hostport 11435
    [ "$status" -eq 0 ]
    ! grep -q "DRAUGR_HOST_ADDR" "$DR_MOCK_LOG"
}

@test "dr-up: the host address reaches the mound" {
    export DRAUGR_HOST_PORTS=11435
    run dr-up
    [ "$status" -eq 0 ]
    grep -q "DRAUGR_HOST_ADDR=172.19.192.26" "$DR_MOCK_LOG"
}
