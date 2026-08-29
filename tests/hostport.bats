#!/usr/bin/env bats
# Reaching a service on the HOST from inside a mound, without writing down an
# address that stops being true.
#
# The thing under test is not "can it add a policy rule" - sbx does that. It is
# the bookkeeping around an address that changes: resolving it late, recognising
# the rules this command wrote for addresses the machine no longer has, and
# leaving alone every rule that came from somewhere else. Getting the last part
# wrong means `policy rm` on somebody else's rule, so most of these tests are
# about what is NOT touched.

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

# The helpers are called in-process, so nothing has run the config cascade for
# them. The dr-* commands get this from their own dr_context.
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
    # An empty string that looked like success would be concatenated into ":8080"
    # and handed to sbx as a rule, which would then match nothing.
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
    # editable:false is the discriminator, the same one dr_policy_adhoc uses.
    # Removing a kit rule here would silently undo what the kit composed.
    export DR_MOCK_KITHOST="172.19.192.26:11434"
    load_helpers
    run dr_hostport_rules 11434
    [ -z "$output" ]
}

@test "dr_hostport_rules: a rule holding several resources is left alone" {
    # This command only ever writes one resource per rule, so a rule with more
    # than one came from somewhere else - and removing it would take the other
    # resources with it.
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
    # This runs on every dr-up. Rewriting the rule each time would churn machine
    # state and make the output not worth reading.
    export DR_MOCK_ADHOC="172.19.192.26:11434"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"already open"* ]]
    ! grep -q "policy allow" "$DR_MOCK_LOG"
    ! grep -q "policy rm" "$DR_MOCK_LOG"
}

@test "dr-hostport: an address from a previous boot is replaced" {
    export DR_MOCK_ADHOC="10.0.0.5:11434"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"replaced 1 stale"* ]]
    grep -q "policy rm network --sandbox $SANDBOX --id rule-0" "$DR_MOCK_LOG"
    grep -q "policy allow network --sandbox $SANDBOX 172.19.192.26:11434" "$DR_MOCK_LOG"
}

@test "dr-hostport: the stale rule goes before the new one is added" {
    # After a reboot the machine can be handed back an address it used to have.
    # Removing after adding would then delete the rule just written, leaving the
    # port shut while the command reported success.
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
    # sbx would take "11434/tcp" as a hostname, match nothing, and look exactly
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
    [[ "$output" == *"could not work out this host's address"* ]]
    ! grep -q "policy allow" "$DR_MOCK_LOG"
}

# --- the loopback trap ------------------------------------------------------

@test "dr-hostport: warns when the service is bound to loopback only" {
    # The rule is still added - the service may be restarted correctly in a
    # moment - but from inside the mound 127.0.0.1 is the mound, so this would
    # fail in a way indistinguishable from a policy denial.
    export DR_MOCK_LISTEN="127.0.0.1:11434"
    run dr-hostport 11434
    [ "$status" -eq 0 ]
    [[ "$output" == *"loopback only"* ]]
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
    # This is the state a reboot leaves behind, and it is otherwise
    # indistinguishable from a working rule.
    export DR_MOCK_ADHOC="10.0.0.5:11434"
    run dr-hostport
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.5:11434"* ]]
    [[ "$output" == *"stale"* ]]
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
    ! grep -q "policy allow" "$DR_MOCK_LOG"
    ! grep -q "policy rm" "$DR_MOCK_LOG"
}

# --- dr-up applies it -------------------------------------------------------

@test "dr-up: DRAUGR_HOST_PORTS is applied on every start" {
    # Not only on the create. The address is only true for this boot, so the up
    # that matters is the first one after a reboot - when the mound already
    # exists and nothing is created at all.
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
