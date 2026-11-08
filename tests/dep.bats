#!/usr/bin/env bats
# Run-state dependencies: claims, the optional lock, and the counted stop.
#
# The premise is one rule, and each test here comes from it. A claim counts only
# while its claimant is real: the mound of that repository runs, or the claim is
# younger than DR_DEP_GRACE. Nothing gets cleaned up. Thus a reboot, a crash,
# and a dr-stop all release claims by the same mechanism.
#
# Most tests set the grace to 0. A grace that covers all makes each claim valid,
# and then the suite passes for the wrong reason.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo app) || skip "no writable path under /mnt/<drive> on this machine"
    GW=$(dr_make_win_repo gw) || skip "no writable path under /mnt/<drive> on this machine"

    # The gateway repo is a dependency. Thus it needs its own configuration, and
    # that configuration must be trusted. That is the purpose of dr_dep_trusted.
    printf 'DRAUGR_SANDBOX=gwmound\nDRAUGR_AGENT=shell\n' > "$GW/.draugr.conf"
    printf 'DRAUGR_REQUIRES=%s\n' "$GW" > "$REPO/.draugr.conf"
    git -C "$GW" add -A && git -C "$GW" commit -qm conf
    git -C "$REPO" add -A && git -C "$REPO" commit -qm conf

    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-app" DR_MOCK_NAMES="draugr-app gwmound"
    export DR_MOCK_STATE=running
    export DR_DEP_GRACE=0
    dr_fake_sbx_root
    dr_load_common

    # Both configurations are accepted once, as a person does with dr-trust.
    # Thus the tests exercise the mechanism, not the refusal.
    dr_trust_add "$REPO/.draugr.conf"
    dr_trust_add "$GW/.draugr.conf"
}

# Wardens stay after the command that starts them. That is their job. Thus a
# test that starts one must stop it. If not, a suite run leaves one poll loop
# for each test. By pid file, not by a pkill pattern. This kills only the ones
# that THIS test started, and nothing that only looks like them.
teardown() {
    local pidfile pid
    for pidfile in "$DR_RUN_DIR"/*/warden.pid; do
        [ -f "$pidfile" ] || continue
        pid=$(cat "$pidfile" 2>/dev/null) || continue
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    dr_test_teardown
}

calls() { grep "^$1 " "$DR_MOCK_LOG" || true; }

# --- what a repo requires ----------------------------------------------------

@test "dr_dep_requires: an absolute path is itself" {
    DR_REPO=$REPO DRAUGR_REQUIRES=$GW run dr_dep_requires "$REPO"
    [ "$status" -eq 0 ]
    [ "$output" = "$GW" ]
}

@test "dr_dep_requires: a relative path is relative to the repo that asked" {
    mkdir -p "$REPO/sub"
    DR_REPO=$REPO DRAUGR_REQUIRES=sub run dr_dep_requires "$REPO"
    [ "$output" = "$REPO/sub" ]
}

@test "dr_dep_requires: a quoted tilde still means home" {
    mkdir -p "$HOME/dep"
    DR_REPO=$REPO DRAUGR_REQUIRES='~/dep' run dr_dep_requires "$REPO"
    [ "$output" = "$HOME/dep" ]
}

@test "dr_dep_requires: empty means nothing, not one empty entry" {
    DR_REPO=$REPO DRAUGR_REQUIRES= run dr_dep_requires "$REPO"
    [ -z "$output" ]
}

# --- what makes a claim valid -------------------------------------------------

@test "a claim whose sandbox is running counts" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    run dr_dep_claims gwmound
    [[ "$output" == *"$REPO"* ]]
}

@test "a claim whose sandbox is stopped does not count" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    export DR_MOCK_STATES="draugr-app=stopped"
    run dr_dep_claims gwmound
    [ -z "$output" ]
}

@test "a claim younger than the grace counts even with nothing running" {
    DR_DEP_GRACE=300 dr_dep_claim gwmound "$REPO" draugr-app false
    export DR_MOCK_STATE=absent
    DR_DEP_GRACE=300 run dr_dep_claims gwmound
    [[ "$output" == *"$REPO"* ]]
}

@test "prune deletes the claims that no longer count, and keeps the rest" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    dr_dep_claim gwmound /other/repo dead-mound false
    export DR_MOCK_STATES="draugr-app=running"
    dr_dep_prune gwmound
    run dr_dep_claims gwmound
    [[ "$output" == *"$REPO"* ]]
    [[ "$output" != *"/other/repo"* ]]
    [ ! -f "$(dr_dep_claim_file gwmound /other/repo)" ]
}

@test "status reads a claim without deleting the stale ones" {
    dr_dep_claim gwmound /other/repo dead-mound false
    export DR_MOCK_STATES="dead-mound=stopped"
    run dr_dep_claims gwmound
    [ -z "$output" ]
    [ -f "$(dr_dep_claim_file gwmound /other/repo)" ]
}

@test "the claim records the key as given, not as the directory spells it" {
    dr_dep_claim "vm:UE5-Test" "$REPO" draugr-app false
    run cat "$(dr_dep_claim_file "vm:UE5-Test" "$REPO")"
    [[ "$output" == *"key=vm:UE5-Test"* ]]
    [ -d "$DR_RUN_DIR/vm_UE5-Test" ]
}

# --- the lock -----------------------------------------------------------------

@test "a shared resource takes a second claimant" {
    export DR_MOCK_NAMES="draugr-app other-mound"
    dr_dep_claim gwmound "$REPO" draugr-app false
    run dr_dep_claim gwmound /other/repo other-mound false
    [ "$status" -eq 0 ]
    [ "$(dr_dep_claims gwmound | grep -c .)" -eq 2 ]
}

@test "an exclusive resource refuses the second, and names the holder" {
    export DR_MOCK_NAMES="draugr-app other-mound"
    dr_dep_claim gwmound "$REPO" draugr-app true
    run dr_dep_claim gwmound /other/repo other-mound true
    [ "$status" -ne 0 ]
    [[ "$output" == *"$REPO"* ]]
    [[ "$output" == *exclusive* ]]
}

@test "an exclusive claim is re-entrant for the same repository" {
    dr_dep_claim gwmound "$REPO" draugr-app true
    run dr_dep_claim gwmound "$REPO" draugr-app true
    [ "$status" -eq 0 ]
}

@test "an exclusive lock whose holder is gone is taken over, not waited for" {
    dr_dep_claim gwmound /other/repo dead-mound true
    export DR_MOCK_STATES="dead-mound=stopped draugr-app=running"
    run dr_dep_claim gwmound "$REPO" draugr-app true
    [ "$status" -eq 0 ]
    [ "$(dr_dep_claims gwmound | grep -c .)" -eq 1 ]
}

# --- durations ----------------------------------------------------------------

@test "dr_dep_seconds: the three suffixes, and off" {
    [ "$(dr_dep_seconds 30s)" = 30 ]
    [ "$(dr_dep_seconds 10m)" = 600 ]
    [ "$(dr_dep_seconds 1h)" = 3600 ]
    [ -z "$(dr_dep_seconds off)" ]
    [ -z "$(dr_dep_seconds '')" ]
}

@test "dr_dep_seconds: an unreadable duration is fatal, not a guess" {
    run dr_dep_seconds "soon"
    [ "$status" -ne 0 ]
    [[ "$output" == *"30s, 10m, 1h"* ]]
}

# --- dr-dep, the command ------------------------------------------------------

@test "dr-dep status: names the dependency, its mound and its state" {
    run dr-dep
    [ "$status" -eq 0 ]
    [[ "$output" == *gwmound* ]]
    [[ "$output" == *"$GW"* ]]
}

@test "dr-dep status: says so when nothing is required" {
    printf 'DRAUGR_SANDBOX=draugr-app\n' > "$REPO/.draugr.conf"
    dr_trust_add "$REPO/.draugr.conf"
    run dr-dep
    [ "$status" -eq 0 ]
    [[ "$output" == *"requires nothing"* ]]
}

@test "dr-dep up: brings the dependency up and claims it" {
    run dr-dep up
    [ "$status" -eq 0 ]
    [ -n "$(dr_dep_claims gwmound)" ]
}

@test "dr-dep up: refuses a path that is not there, naming the key" {
    printf 'DRAUGR_REQUIRES=%s/nope\n' "$DR_TMP" > "$REPO/.draugr.conf"
    dr_trust_add "$REPO/.draugr.conf"
    run dr-dep up
    [ "$status" -ne 0 ]
    [[ "$output" == *DRAUGR_REQUIRES* ]]
}

@test "dr-dep up: refuses a directory that is not a repository" {
    mkdir -p "$DR_TMP/plain"
    printf 'DRAUGR_REQUIRES=%s/plain\n' "$DR_TMP" > "$REPO/.draugr.conf"
    dr_trust_add "$REPO/.draugr.conf"
    run dr-dep up
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a git repository"* ]]
}

@test "dr-dep up: refuses an untrusted dependency rather than guessing its name" {
    printf 'DRAUGR_SANDBOX=gwmound\n# changed\n' > "$GW/.draugr.conf"
    run dr-dep up
    [ "$status" -ne 0 ]
    [[ "$output" == *"not trusted"* ]]
    [[ "$output" == *dr-trust* ]]
}

@test "dr-dep release: drops this repo's claims and leaves other repos' alone" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    dr_dep_claim gwmound /other/repo other-mound false
    run dr-dep release
    [ "$status" -eq 0 ]
    [ ! -f "$(dr_dep_claim_file gwmound "$REPO")" ]
    [ -f "$(dr_dep_claim_file gwmound /other/repo)" ]
}

@test "dr-dep claim: works on something that is not a mound at all" {
    run dr-dep claim "vm:UE5-Test" --exclusive
    [ "$status" -eq 0 ]
    run dr-dep unclaim "vm:UE5-Test"
    [ "$status" -eq 0 ]
    [ -z "$(dr_dep_claims "vm:UE5-Test")" ]
}

# --- the warden ---------------------------------------------------------------
#
# One tick at a time, with --once. Thus nothing here sleeps, and no test depends
# on wall-clock time.

@test "warden: holds the mound while somebody is using it" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    run dr-dep warden gwmound --sandbox gwmound --linger 1s --once
    [ "$status" -eq 0 ]
    [ -z "$(calls stop)" ]
}

@test "warden: with nobody using it, the first tick starts the clock but stops nothing" {
    run dr-dep warden gwmound --sandbox gwmound --linger 10m --once
    [ "$status" -eq 0 ]
    [ -z "$(calls stop)" ]
}

@test "warden: stops the mound once the linger has passed with no claims" {
    run dr-dep warden gwmound --sandbox gwmound --linger 0s --once
    [ "$status" -eq 0 ]
    [[ "$(calls stop)" == *gwmound* ]]
}

@test "warden: linger off means it never stops anything" {
    run dr-dep warden gwmound --sandbox gwmound --linger off --once
    [ "$status" -eq 0 ]
    [ -z "$(calls stop)" ]
}

@test "warden: a claim cancels a linger that had already started" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    run dr-dep warden gwmound --sandbox gwmound --linger 0s --once
    [ -z "$(calls stop)" ]
}

@test "warden: keeps a session open, or sbx would stop an idle mound in 30 s" {
    run dr-dep warden gwmound --sandbox gwmound --linger off --once
    [[ "$(calls exec)" == *"sleep infinity"* ]]
}

# --- dr-up, dr-stop and dr-rm -------------------------------------------------

@test "dr-up: brings the dependency up before its own mound" {
    run dr-up
    [ "$status" -eq 0 ]
    [ -n "$(dr_dep_claims gwmound)" ]
}

@test "dr-up --skip-deps: starts this mound alone" {
    run dr-up --skip-deps
    [ "$status" -eq 0 ]
    [ -z "$(dr_dep_claims gwmound)" ]
}

@test "dr-up --print: a dry run claims nothing" {
    export DR_MOCK_STATE=absent
    run dr-up --print
    [ "$status" -eq 0 ]
    [ -z "$(dr_dep_claims gwmound)" ]
}

@test "dr-up: refuses when an exclusive dependency is held elsewhere" {
    printf 'DRAUGR_SANDBOX=gwmound\nDRAUGR_EXCLUSIVE=true\n' > "$GW/.draugr.conf"
    dr_trust_add "$GW/.draugr.conf"
    export DR_MOCK_NAMES="draugr-app other-mound gwmound"
    dr_dep_claim gwmound /other/repo other-mound true
    run dr-up
    [ "$status" -ne 0 ]
    [[ "$output" == *"/other/repo"* ]]
}

@test "dr-stop: releases this repo's claims" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    run dr-stop
    [ "$status" -eq 0 ]
    [ -z "$(dr_dep_claims gwmound)" ]
}

@test "dr-up: a cycle is refused rather than recursed into" {
    printf 'DRAUGR_SANDBOX=gwmound\nDRAUGR_AGENT=shell\nDRAUGR_REQUIRES=%s\n' "$REPO" \
        > "$GW/.draugr.conf"
    dr_trust_add "$GW/.draugr.conf"
    run dr-up
    [ "$status" -ne 0 ]
    [[ "$output" == *cycle* ]]
}

# --- the own configuration of the dependency is the authority ---------------

@test "a dependency is started under ITS name, even with ours in the environment" {
    # dr_hook exports each DRAUGR_* before it runs a hook, and they stay
    # exported for the rest of the process. Thus this is a real case.
    DRAUGR_SANDBOX=draugr-app run env DRAUGR_SANDBOX=draugr-app dr-dep up
    [ "$status" -eq 0 ]
    [ -n "$(dr_dep_claims gwmound)" ]
    [ -z "$(dr_dep_claims draugr-app)" ]
}

@test "dr-dep status: an untrusted dependency says so rather than reading as stopped" {
    printf 'DRAUGR_SANDBOX=gwmound\n# edited after it was trusted\n' > "$GW/.draugr.conf"
    run dr-dep
    [ "$status" -eq 0 ]
    [[ "$output" == *UNTRUSTED* ]]
    [[ "$output" == *dr-trust* ]]
}
