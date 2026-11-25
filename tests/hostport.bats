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

# "closed" IS A SECURITY CLAIM. Before, the counter was raised beside the
# warning whatever sbx answered, so a removal that failed still produced
# "closed host port 11434 ... (1 rule(s))" and exit 0, and the caller believed
# the agent can no longer reach a host service that is still allowed.
#
# DR_MOCK_FAIL_AT, not DR_MOCK_FAIL: the listing must succeed, or the removal is
# never reached and the test passes for the wrong reason.
@test "dr-hostport --close: a removal that fails is not reported as closed" {
    export DR_MOCK_ADHOC="172.19.192.26:11434"
    export DR_MOCK_FAIL_AT="policy rm"
    run dr-hostport --close 11434
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT closed"* ]]
    [[ "$output" != *"closed host port 11434 for"* ]]
}

@test "dr-hostport --close: a rule listing that fails removes nothing" {
    export DR_MOCK_ADHOC="172.19.192.26:11434"
    export DR_MOCK_FAIL_AT="policy ls"
    run dr-hostport --close 11434
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot list the policy rules"* ]]
    [[ "$output" != *"was not open"* ]]
    run grep -c "policy rm" "$DR_MOCK_LOG"
    [ "$status" -ne 0 ]
}

# The refresh path made the same claim: it counted a stale rule as replaced
# before asking sbx to remove it, so "replaced 1 old rule(s)" appeared
# while the old address was still allowed next to the new one.
@test "dr-hostport: an old rule that will not go stops the refresh" {
    export DR_MOCK_ADHOC="10.0.0.5:11434"
    export DR_MOCK_FAIL_AT="policy rm"
    run dr-hostport 11434
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not remove the old rule"* ]]
    [[ "$output" != *"replaced"* ]]
    # And no second rule was added beside the one that stayed.
    run grep -c "policy allow" "$DR_MOCK_LOG"
    [ "$status" -ne 0 ]
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

# --- what a 0.0.0.0 bind inside WSL reaches ---------------------------------
#
# The two reporters behind the dr-doctor lines. Each answers a question about
# the network of somebody, so the test that matters most is the one proving that a
# "could not find out" never arrives as "not on your LAN".
#
# The seam is _dr_wslconfig: these tests source common.sh and then replace it,
# which is why there is no cmd.exe mock. The value set, the default and the
# "unknown values use NAT" rule are from the wsl-config documentation of
# Microsoft. dr_wsl_net_mode holds the mapping and the reasons.

# wslconfig <text>: make that text the .wslconfig of this machine. Call it
# after load_helpers, which defines the function this one replaces.
wslconfig() {
    printf '%s' "$1" > "$DR_TMP/wslconfig"
    eval '_dr_wslconfig() { printf "%s" "'"$DR_TMP"'/wslconfig"; }'
}

@test "dr_wsl_net_mode: no .wslconfig is the documented default, and it is confined" {
    load_helpers
    eval '_dr_wslconfig() { printf "%s" "'"$DR_TMP"'/absent"; }'
    run dr_wsl_net_mode
    [ "$status" -eq 0 ]
    [ "$output" = "default" ]
}

@test "dr_wsl_net_mode: mirrored is 1, and the mode is named" {
    load_helpers
    wslconfig '[wsl2]
networkingMode=mirrored
'
    run dr_wsl_net_mode
    [ "$status" -eq 1 ]
    [ "$output" = "mirrored" ]
}

@test "dr_wsl_net_mode: bridged is 1 too, because that bind is on the LAN as well" {
    load_helpers
    wslconfig '[wsl2]
networkingMode=bridged
'
    run dr_wsl_net_mode
    [ "$status" -eq 1 ]
    [ "$output" = "bridged" ]
}

@test "dr_wsl_net_mode: nat is read whatever the case and the spacing" {
    # The documentation spells one of its own keys two ways and uses both
    # key=value and key = value, so neither can be assumed.
    load_helpers
    wslconfig '[WSL2]
  NetworkingMode   =   NAT
'
    run dr_wsl_net_mode
    [ "$status" -eq 0 ]
    [ "$output" = "nat" ]
}

@test "dr_wsl_net_mode: consomme is 2, not a quiet 0" {
    # WSL falls back to consomme from a failed NAT, so it is probably confined.
    # "Probably" is not a thing to print about the LAN of somebody.
    load_helpers
    wslconfig '[wsl2]
networkingMode=consomme
'
    run dr_wsl_net_mode
    [ "$status" -eq 2 ]
    [ "$output" = "consomme" ]
}

@test "dr_wsl_net_mode: a value WSL does not know is NAT, as its documentation says" {
    # "If the value is nat or an unknown value, NAT network mode is used." The
    # answer is 0, and the printed mode is still what was read, not "nat".
    load_helpers
    wslconfig '[wsl2]
networkingMode=banana
'
    run dr_wsl_net_mode
    [ "$status" -eq 0 ]
    [ "$output" = "banana" ]
}

@test "dr_wsl_net_mode: networkingMode outside [wsl2] is 2, never a silent 0" {
    # The key shipped under [experimental] in WSL 2.0.0 and errors in the wild
    # still name experimental.networkingMode. Ignoring it is the one path that
    # can print a false "not on your LAN".
    load_helpers
    wslconfig '[experimental]
networkingMode=mirrored
'
    run dr_wsl_net_mode
    [ "$status" -eq 2 ]
    [ "$output" = "mirrored" ]
}

@test "dr_wsl_net_mode: a [wsl2] value settles it, whatever another section says" {
    load_helpers
    wslconfig '[experimental]
networkingMode=mirrored
[wsl2]
networkingMode=nat
'
    run dr_wsl_net_mode
    [ "$status" -eq 0 ]
    [ "$output" = "nat" ]
}

@test "dr_wsl_net_mode: CRLF and a UTF-8 BOM do not hide the section" {
    # The file is edited on Windows. Notepad writes both.
    load_helpers
    printf '\xef\xbb\xbf[wsl2]\r\nnetworkingMode=mirrored\r\n' > "$DR_TMP/wslconfig"
    eval '_dr_wslconfig() { printf "%s" "'"$DR_TMP"'/wslconfig"; }'
    run dr_wsl_net_mode
    [ "$status" -eq 1 ]
    [ "$output" = "mirrored" ]
}

@test "dr_wsl_net_mode: a commented-out mode is not a mode" {
    load_helpers
    wslconfig '[wsl2]
# networkingMode=mirrored
; networkingMode=bridged
'
    run dr_wsl_net_mode
    [ "$status" -eq 0 ]
    [ "$output" = "default" ]
}

@test "dr_wsl_net_mode: a profile Draugr cannot resolve is 2, not nat" {
    # This is the CI answer, and the answer on any host without cmd.exe.
    load_helpers
    eval '_dr_wslconfig() { return 1; }'
    run dr_wsl_net_mode
    [ "$status" -eq 2 ]
    [ "$output" = "unknown" ]
}

@test "dr_wsl_portproxy: no rules is 0, and a clean host prints only a newline" {
    load_helpers
    run dr_wsl_portproxy
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "dr_wsl_portproxy: a rule is 1, and the lines are printed for the reader" {
    export DR_MOCK_PORTPROXY=rules
    load_helpers
    run dr_wsl_portproxy
    [ "$status" -eq 1 ]
    [[ "$output" == *"11435"* ]]
    [[ "$output" == *"172.19.192.26"* ]]
}

@test "dr_wsl_portproxy: a netsh that fails is 2, not 'no rules'" {
    export DR_MOCK_PORTPROXY=broken
    load_helpers
    run dr_wsl_portproxy
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "dr_wsl_portproxy: a missing netsh.exe answers 2, held by the source" {
    # There is no lever for "netsh.exe is not on this machine": the mock is on
    # PATH for every test, which is the point of it, so the CI runner and this
    # host must answer the same. The shape is held here instead, as the claude
    # quiesce probe is in tests/mem.bats.
    cd "$DR_ROOT" || return 1
    grep -q 'command -v netsh.exe >/dev/null 2>&1 || return 2' lib/common.sh
}
