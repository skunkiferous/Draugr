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

# UNKNOWN IS NOT "NOBODY RUNS". A failed `sbx ls` used to arrive as an empty
# running list, so every claim past its grace time looked stale and this loop
# deleted the claims of mounds that were running at that moment. The warden then
# saw an unused resource and stopped it.
@test "prune keeps every claim when it cannot tell which sandboxes run" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    dr_dep_claim gwmound /other/repo other-mound false
    export DR_MOCK_FAIL=ls
    run dr_dep_prune gwmound
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot tell which sandboxes run"* ]]
    [ -f "$(dr_dep_claim_file gwmound "$REPO")" ]
    [ -f "$(dr_dep_claim_file gwmound /other/repo)" ]
}

@test "claims answers unknown, not an empty list, when liveness cannot be read" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    export DR_MOCK_FAIL=ls
    run dr_dep_claims gwmound
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

# An exclusive claim exists to refuse. Through a pipe into `head`, the status of
# dr_dep_claims was replaced by the status of head, so an unknown liveness read as "no other
# claim" and the lock was granted on top of a live one.
@test "an exclusive claim refuses while another holder cannot be ruled out" {
    dr_dep_claim gwmound /other/repo other-mound false
    export DR_MOCK_FAIL=ls
    run dr_dep_claim gwmound "$REPO" draugr-app true
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be established"* ]]
}

# dr-forge asks this before stopping, deleting and rolling back a shared VM.
# The claim has to exist first: with no claim directory at all, dr_dep_claims
# answers a certain "nobody" without probing liveness, which is correct and
# makes this test pass without reaching the code it is about.
@test "dr_dep_report_others: an unknown liveness is reported, not passed over" {
    dr_dep_claim gwmound /other/repo other-mound false
    export DR_MOCK_FAIL=ls
    run dr_dep_report_others gwmound "$REPO" VM
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot tell whether another project uses this VM"* ]]
}

# A claim held by THIS repo is not "another project", so there is nothing to
# report and nothing to ask. The probe succeeds here, so this exercises the
# filter rather than the early return above.
@test "dr_dep_report_others: a certain nobody is silent, so no question is asked" {
    dr_dep_claim gwmound "$REPO" draugr-app false
    run dr_dep_report_others gwmound "$REPO" VM
    [ "$status" -eq 1 ]
    [ -z "$output" ]
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

# --- the lock on the claims ---------------------------------------------------
#
# A claim used to be read-then-write with nothing in between. Two dr-ups started
# together both read the directory before either had written, both saw no owner,
# and both took an exclusive resource. The prune, the test for a holder and the
# write now happen under one lock.
#
# These tests are about the section being HELD, not about luck. Each puts a lock
# in place by hand and makes the outcome depend on whether the claimant respects
# it, so none of them depends on two processes interleaving a certain way.

@test "a claimant waits for the lock, and sees the claim that appeared under it" {
    export DR_MOCK_NAMES="draugr-app other-mound"
    local dir
    dir=$(dr_dep_dir gwmound)
    mkdir -p "$dir/.lock"
    printf '999999\n' > "$dir/.lock/owner"

    # The holder publishes its claim and only then gives the lock back. A
    # claimant that walks past the lock writes its own claim before this
    # happens, and then two of them hold an exclusive resource.
    (
        sleep 1
        printf 'key=gwmound\nrepo=/other/repo\nsandbox=other-mound\nsince=earlier\nsince_epoch=%s\n' \
            "$(date +%s)" > "$(dr_dep_claim_file gwmound /other/repo)"
        rm -rf "$dir/.lock"
    ) &

    DR_DEP_LOCK_WAIT=10 run dr_dep_claim gwmound "$REPO" draugr-app true
    wait
    [ "$status" -ne 0 ]
    [[ "$output" == *"/other/repo"* ]]
    [[ "$output" == *exclusive* ]]
    [ ! -f "$(dr_dep_claim_file gwmound "$REPO")" ]
}

# A SHARED claim takes the lock too. Its write is what an exclusive claimant
# tests against, so a write that skipped the lock can still land beside a
# holder that had just checked and found nothing.
@test "a lock that is never given back refuses the claim, and names it" {
    local dir
    dir=$(dr_dep_dir gwmound)
    mkdir -p "$dir/.lock"
    printf '999999\n' > "$dir/.lock/owner"
    DR_DEP_LOCK_WAIT=0 run dr_dep_claim gwmound "$REPO" draugr-app false
    [ "$status" -ne 0 ]
    [[ "$output" == *"$dir/.lock"* ]]
    [ ! -f "$(dr_dep_claim_file gwmound "$REPO")" ]
}

@test "an abandoned lock is broken once it is old enough" {
    local dir
    dir=$(dr_dep_dir gwmound)
    mkdir -p "$dir/.lock"
    printf '999999\n' > "$dir/.lock/owner"
    touch -d "@$(( $(date +%s) - 1000 ))" "$dir/.lock"
    DR_DEP_LOCK_WAIT=0 DR_DEP_LOCK_STALE=60 run dr_dep_claim gwmound "$REPO" draugr-app true
    [ "$status" -eq 0 ]
    [ -f "$(dr_dep_claim_file gwmound "$REPO")" ]
    [ ! -d "$dir/.lock" ]
}

@test "a lock of unreadable age is left alone, not broken" {
    local dir
    dir=$(dr_dep_dir gwmound)
    mkdir -p "$dir/.lock"
    printf '999999\n' > "$dir/.lock/owner"
    touch -d "@$(( $(date +%s) - 1000 ))" "$dir/.lock"
    # The lock is old enough to break. The only thing that keeps it is that its
    # age cannot be read, and an age that cannot be read is not an age past the
    # limit: breaking on it puts two claimants in the section at once.
    # shellcheck disable=SC2317  # called from _dr_dep_lock_age, not from here
    stat() { return 1; }
    DR_DEP_LOCK_WAIT=0 DR_DEP_LOCK_STALE=60 run dr_dep_claim gwmound "$REPO" draugr-app true
    [ "$status" -ne 0 ]
    [ -d "$dir/.lock" ]
}

@test "the lock is given back, whether the claim was written or refused" {
    export DR_MOCK_NAMES="draugr-app other-mound"
    local dir
    dir=$(dr_dep_dir gwmound)
    dr_dep_claim gwmound "$REPO" draugr-app true
    [ ! -d "$dir/.lock" ]
    run dr_dep_claim gwmound /other/repo other-mound true
    [ "$status" -ne 0 ]
    [ ! -d "$dir/.lock" ]
}

# One answer from sbx, used by the prune AND by the test for a holder. Two
# calls meant two moments, and a mound can stop between them, so the prune kept a
# claim that the test then read as stale. It is also what keeps the lock cheap,
# because nothing held under it waits on a daemon.
@test "a claim asks sbx once, and judges both of its steps with that answer" {
    : > "$DR_MOCK_LOG"
    dr_dep_claim gwmound "$REPO" draugr-app true
    [ "$(calls ls | grep -c .)" -eq 1 ]
}

@test "a lock that belongs to another process is not removed by this one" {
    local dir
    dir=$(dr_dep_dir gwmound)
    mkdir -p "$dir/.lock"
    printf '999999\n' > "$dir/.lock/owner"
    _dr_dep_unlock "$dir"
    [ -d "$dir/.lock" ]
}

# The end-to-end form of the same rule, with two real processes. The mock sbx
# holds each one at its `ls` until the test opens the gate, so both enter the
# claim at the same moment instead of at whatever moment the scheduler picks.
@test "two claimants released together: exactly one takes the exclusive resource" {
    export DR_MOCK_NAMES="draugr-app other-mound"
    cat > "$DR_TMP/claimant" <<EOS
#!/usr/bin/env bash
set -euo pipefail
. "$DR_ROOT/lib/common.sh"
dr_dep_claim gwmound "\$1" "\$2" true
EOS
    chmod +x "$DR_TMP/claimant"

    export DR_MOCK_LS_BARRIER="$DR_TMP/barrier"
    : > "$DR_TMP/barrier.arrived"
    local a b i ok=0
    "$DR_TMP/claimant" "$REPO" draugr-app > "$DR_TMP/a.out" 2>&1 &
    a=$!
    "$DR_TMP/claimant" /other/repo other-mound > "$DR_TMP/b.out" 2>&1 &
    b=$!

    i=0
    while [ "$(grep -c . "$DR_TMP/barrier.arrived" || true)" -lt 2 ] && [ "$i" -lt 200 ]; do
        i=$((i + 1))
        sleep 0.05
    done
    [ "$(grep -c . "$DR_TMP/barrier.arrived" || true)" -ge 2 ]
    : > "$DR_TMP/barrier.go"

    if wait "$a"; then ok=$((ok + 1)); fi
    if wait "$b"; then ok=$((ok + 1)); fi
    [ "$ok" -eq 1 ]
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

# The one outcome this loop must never produce: stopping a resource that another
# project is using, because one query failed. Before, the failure arrived as an
# empty claim list, which read as "nobody uses it" and started the idle clock.
@test "warden: stops nothing while it cannot tell who uses the resource" {
    export DR_MOCK_FAIL=ls
    run dr-dep warden gwmound --sandbox gwmound --linger 0s --once
    [[ "$output" == *"cannot tell who uses"* ]]
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
