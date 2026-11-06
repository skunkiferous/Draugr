#!/usr/bin/env bats
#
# forge-api.bats - the forge's control plane, EXECUTED rather than grepped.
#
# WHY THIS FILE EXISTS. forge.bats asserts that the scripts CONTAIN things: 64 of its
# assertions are a grep for a string in a file. Those catch a verb being renamed and nothing
# else - `rollback` could discard the wrong branch, `base` could forget to stop the VM, and
# every one of them would still pass. The scripts reach AppSandbox over about ten HTTP
# endpoints and nothing else, so tests/appsandbox_mock.py is enough to run them for real.
#
# WHAT THAT BUYS, concretely: the mock logs every request, so a test can assert the ORDER of
# the calls a script actually made. The order is forced by the API in two places - a branch is
# created by STARTING, and a branch is deletable only while stopped - and no grep can see it.
#
# WHY IT SKIPS. These run the real scripts under the real Windows PowerShell, because that is
# where they run in production: `pwsh` on Linux has different path semantics and none of the
# Windows surface. The suite skips where powershell.exe, python3 or a Windows-visible scratch
# directory is missing, which is every machine that is not the forge's own host.
#
# WHAT IT CANNOT COVER. Only the daemon-facing half. The guest scripts - reduce-churn.ps1,
# install-shot.ps1, harden-sshd.ps1 - touch scheduled tasks, the registry, Defender and sshd,
# and no mock makes those exist. They stay verifiable only against a real guest.

load helper

setup() {
    dr_test_setup
    # THE REAL powershell.exe, NOT THE MOCK. helper.bash puts tests/mocks first on PATH, so a
    # bare `powershell.exe` here is the stub the rest of the suite uses - which answers every
    # call cheerfully and makes all ten of these fail identically. Resolved once, with the
    # mocks directory stripped from anywhere in PATH, the way the dr-setup tests reach real ssh.
    local clean=${PATH//"$DR_ROOT/tests/mocks:"/}
    DR_REAL_PS=$(PATH="$clean" command -v powershell.exe 2>/dev/null) || true
    [ -n "$DR_REAL_PS" ] || skip "no real powershell.exe - not a Windows host"
    [ "$DR_REAL_PS" != "$DR_ROOT/tests/mocks/powershell.exe" ] || skip "only the mock is on PATH"
    command -v python3 >/dev/null 2>&1 || skip "no python3 to run the mock daemon"
    dr_win_root >/dev/null 2>&1 || skip "no Windows-visible scratch directory"
}

teardown() {
    api_stop
    dr_test_teardown
}

# --- the harness -------------------------------------------------------------------------

# /mnt/c/x -> C:\x. The scripts are Windows programs and every path handed to them has to be
# one; DR_TMP is under /tmp, which Windows cannot see at all, hence DR_WIN_TMP.
api_winpath() {
    local p=$1 drive rest
    p=${p#/mnt/}
    drive=${p%%/*}
    rest=${p#*/}
    printf '%s:\\%s' "$(printf '%s' "$drive" | tr 'a-z' 'A-Z')" "$(printf '%s' "$rest" | tr '/' '\\')"
}

# Start the mock with a given state. $1 is the VMs object; anything after that is passed to
# the mock, which is how a test asks for --ignore-shutdown.
# WHERE THE WINDOWS-VISIBLE TEMP TREE WILL BE, computed rather than remembered. A test that
# has to seed the mock's state with a path under it needs that path BEFORE api_start runs,
# because the mock reads state.json exactly once, at startup - see the note there.
api_win_tmp() { printf '%s/draugr-test.%s' "$(dr_win_root)" "${DR_TMP##*/}"; }

api_start() {
    local vms=$1; shift
    DR_WIN_TMP=$(api_win_tmp)
    export DR_WIN_TMP
    mkdir -p "$DR_WIN_TMP/AppSandbox"

    API_TOKEN=mock-token-$$
    API_STATE="$DR_WIN_TMP/state.json"
    API_LOG="$DR_WIN_TMP/calls.log"
    API_MOCK_LOG="$DR_WIN_TMP/mock.log"
    printf '{"token":"%s","vms":%s}\n' "$API_TOKEN" "$vms" > "$API_STATE"

    # A PORT THE MOCK CAN BIND IN WSL IS NOT NECESSARILY ONE WINDOWS CAN REACH, and the
    # scripts dial from Windows. MEASURED, after three of these failed inside the
    # full suite and none failed alone: Hyper-V reserves blocks of the Windows dynamic range
    # (`netsh int ipv4 show excludedportrange protocol=tcp` listed ~1260 ports here, in
    # hundred-wide blocks from 49684 up). Nothing on Windows may bind one, so WSL2's localhost
    # relay never publishes it, while WSL's own loopback serves it perfectly - the mock
    # answered, the call log held the probe and nothing else, and snap.ps1 exited 10, "nothing
    # answers". The exclusions are invisible from inside WSL, so no picker here can avoid them.
    #
    # So the port is DISCARDED, not waited on, when Windows cannot reach it: the failure is
    # immediate (connection refused) and the next port is somewhere else entirely, Linux
    # randomising its ephemeral choices.
    local attempt
    for attempt in 1 2 3 4 5 6; do
        : > "$API_LOG"
        : > "$API_MOCK_LOG"
        API_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')

        # host.json is how every forge script finds the daemon, and it is read from
        # $env:ProgramData - which api_run overrides to point here.
        printf '{"endpoint":"http://127.0.0.1:%s","token":"%s"}\n' "$API_PORT" "$API_TOKEN" \
            > "$DR_WIN_TMP/AppSandbox/host.json"

        # ITS OUTPUT GOES TO A FILE, not into the test's. A daemon whose stderr vanishes into
        # the harness cannot be diagnosed: while this was a mystery, all the failure said was
        # exit 10, with no traceback, no exit status and no way to tell a crash from a kill.
        python3 "$DR_ROOT/tests/appsandbox_mock.py" --port "$API_PORT" --state "$API_STATE" \
            --log "$API_LOG" "$@" > "$API_MOCK_LOG" 2>&1 &
        API_PID=$!

        # Two waits, because they answer different questions and a single one hid the bug for
        # a day. The WSL probe says the mock BOOTED AND BOUND; the Windows probe says the
        # thing under test can actually reach it. Only the second one is the effect that
        # matters, and a fixed sleep in place of either is too short on a loaded machine.
        if api_wait_wsl && api_wait_win; then
            # The probes' own calls are not the script's, and the tests assert on ORDER.
            : > "$API_LOG"
            return 0
        fi
        api_stop
    done
    printf 'api_start: no port reachable from Windows after 6 attempts\n' >&2
    return 1
}

# Reachable from inside WSL: the mock is up and listening.
api_wait_wsl() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        curl -s -m 2 -H "Authorization: Bearer $API_TOKEN" \
            "http://127.0.0.1:$API_PORT/v1/version" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}

# Reachable from Windows, which is where powershell.exe will dial from. curl.exe has shipped in
# System32 since Windows 10 1803; $DR_REAL_PS is the fallback, and it is slow enough that it
# would be a poor first choice (a process launch per probe) rather than wrong.
#
# TWO TRIES, NOT TWENTY, and both measured. A port the relay does publish answers
# from Windows within 40 ms of answering from WSL (12 fresh ports, twice answering Windows-side
# first), so there is nothing to wait for. A RESERVED port refuses in ~2.1 s rather than at
# once - Windows retries the SYN - so every extra try costs two seconds on exactly the path
# that is about to discard the port anyway.
api_wait_win() {
    local i
    for i in 1 2; do
        if [ -x /mnt/c/Windows/System32/curl.exe ]; then
            /mnt/c/Windows/System32/curl.exe -s -m 2 -H "Authorization: Bearer $API_TOKEN" \
                "http://127.0.0.1:$API_PORT/v1/version" >/dev/null 2>&1 && return 0
        else
            "$DR_REAL_PS" -NoProfile -Command \
                "try { \$null = Invoke-RestMethod -Uri 'http://127.0.0.1:$API_PORT/v1/version' \
                       -Headers @{Authorization='Bearer $API_TOKEN'} -TimeoutSec 3; exit 0 } \
                 catch { exit 1 }" >/dev/null 2>&1 && return 0
        fi
        sleep 0.2
    done
    return 1
}

api_stop() {
    [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null
    API_PID=
    return 0
}

# Run one of the real scripts under the real powershell.exe, with ProgramData pointed at the
# temp tree so it finds the mock's host.json.
#
# PARAMETER NAMES MUST NOT BE QUOTED. `& script '-Mode' 'stop'` passes "-Mode" as a positional
# VALUE rather than as a parameter name, and the script then refuses its own arguments - which
# reads as a bug in the script rather than in the harness.
api_run() {
    local script=$1; shift
    local wrapper="$DR_WIN_TMP/run.ps1" a
    {
        printf "\$env:ProgramData = '%s'\n" "$(api_winpath "$DR_WIN_TMP")"
        printf "& '%s'" "$(api_winpath "$DR_ROOT/lib/forge/$script")"
        for a in "$@"; do
            case "$a" in
                -*) printf ' %s' "$a" ;;
                *)  printf " '%s'" "$a" ;;
            esac
        done
        printf '\nexit $LASTEXITCODE\n'
    } > "$wrapper"
    # NOT A PIPE. `powershell | tr` returns TR's status, which is always 0, so every exit code
    # the scripts carefully document would read as success - and the tests asserting 20, 21, 22
    # and 11 would fail while the ones asserting 0 passed, which is exactly what happened.
    local out status=0
    out=$("$DR_REAL_PS" -NoProfile -ExecutionPolicy Bypass \
            -File "$(api_winpath "$wrapper")" 2>&1) || status=$?
    printf '%s\n' "$out" | tr -d '\r'
    return "$status"
}

# The calls a script made, as "METHOD /path" lines - the whole point of the mock.
api_calls() { cat "$API_LOG"; }
api_state() { cat "$API_STATE"; }

# The exit-code assertion, WITH THE EVIDENCE ATTACHED. A bare `[ "$status" -eq 22 ]` prints the
# assertion and nothing else, and three of these failed inside the full suite while passing
# when the file ran alone - leaving a ten-minute run, a line number, and no exit code, no
# script output and no call log to work from. Adding this is what found the port exclusions in
# one run: the script's own words, the calls the mock received, and a live daemon. It prints on
# the failing path only, so the next such failure is diagnosable from the run that caught it.
api_is() {
    local want=$1
    [ "$status" -eq "$want" ] && return 0
    local alive=no
    kill -0 "${API_PID:-0}" 2>/dev/null && alive=yes
    printf 'expected exit %s, got %s\n--- script output ---\n%s\n--- calls ---\n%s\n' \
        "$want" "$status" "$output" "$(api_calls)" >&2
    printf -- '--- mock still running: %s ---\n%s\n' \
        "$alive" "$(cat "${API_MOCK_LOG:-/dev/null}" 2>/dev/null)" >&2
    # Reachability from WINDOWS, re-checked at the moment of failure, because that is what
    # distinguishes the two failures that look identical from here: a port Windows cannot
    # reach (rc 7, and api_start is meant to have discarded it) from a request that arrived
    # and was answered with something the script refused.
    local wrc=0
    if [ -x /mnt/c/Windows/System32/curl.exe ]; then
        /mnt/c/Windows/System32/curl.exe -s -m 3 -H "Authorization: Bearer $API_TOKEN" \
            "http://127.0.0.1:$API_PORT/v1/version" >/dev/null 2>&1 || wrc=$?
        printf -- '--- windows curl to port %s: rc=%s ---\n' "$API_PORT" "$wrc" >&2
    fi
    return 1
}

ONE_VM='{"test":{"running":false,"diskDirectory":"C:\\ForgeLayers","ramMb":8192,
         "snapshots":[],"current":{"snapIndex":-1,"branchIndex":-1}}}'
RUNNING_VM='{"test":{"running":true,"diskDirectory":"C:\\ForgeLayers","ramMb":8192,
             "snapshots":[],"current":{"snapIndex":-1,"branchIndex":-1}}}'
BASED_VM='{"test":{"running":true,"diskDirectory":"C:\\ForgeLayers","ramMb":8192,
           "snapshots":[{"index":0,"name":"draugr-base-x","branchCount":1,
                         "branches":[{"index":0,"name":"Default Branch"}]}],
           "current":{"snapIndex":0,"branchIndex":0}}}'

# --- vm.ps1: down asks the daemon ---------------------------------------------------------

# `down` was changed to ask /shutdown itself instead of waiting out one the
# caller fired. forge.bats checks the mode ORDER in dr-forge; this checks the HTTP.
@test "vm.ps1 stop: asks for a graceful shutdown and does not pull the plug" {
    api_start "$RUNNING_VM"
    run api_run vm.ps1 -Mode stop -Vm test -GraceSec 20
    api_is 0
    [[ "$(api_calls)" == *"POST /v1/vms/test/shutdown"* ]]
    # The plug is what must NOT have been reached for, since the guest went down politely.
    run grep -c 'POST /v1/vms/test/stop' "$API_LOG"
    [ "$output" = 0 ]
}

# The fallback, which only exists for a guest that will not go down. --ignore-shutdown accepts
# the graceful call and does nothing, which is the real-world case this is written for.
@test "vm.ps1 stop: a guest that outlasts the grace period gets the plug, in that order" {
    api_start "$RUNNING_VM" --ignore-shutdown
    run api_run vm.ps1 -Mode stop -Vm test -GraceSec 6
    api_is 0
    local order
    order=$(grep -oE '/v1/vms/test/(shutdown|stop)' "$API_LOG" | sed 's|.*/||' | tr '\n' ' ')
    [[ "$order" == shutdown* ]]
    [[ "$order" == *stop* ]]
}

# --- snap.ps1: the one baseline -----------------------------------------------------------

@test "snap.ps1 base: stops the VM, then snapshots it" {
    api_start "$RUNNING_VM"
    run api_run snap.ps1 -Mode base -Vm test -GraceSec 20
    api_is 0
    [[ "$output" == *phase=based* ]]
    # The snapshot must come AFTER the shutdown: the daemon answers 409 to a snapshot of a
    # running VM, so a caller that got this backwards would fail against the real thing.
    local order
    order=$(grep -oE 'POST /v1/vms/test/(shutdown|snapshots)' "$API_LOG" | sed 's|.*/||' | tr '\n' ' ')
    [[ "$order" == "shutdown snapshots "* ]]
    [[ "$(api_state)" == *draugr-base-* ]]
}

# ONE BASELINE. The second snapshot is the one the AppSandbox bug mishandles, so the refusal is
# the feature - and it must refuse WITHOUT touching the VM.
@test "snap.ps1 base: refuses a second baseline and leaves the VM alone" {
    api_start "$BASED_VM"
    run api_run snap.ps1 -Mode base -Vm test -GraceSec 20
    api_is 20
    run grep -c 'POST /v1/vms/test/snapshots' "$API_LOG"
    [ "$output" = 0 ]
    run grep -c 'POST /v1/vms/test/shutdown' "$API_LOG"
    [ "$output" = 0 ]
}

# A baseline taken from a guest whose power was cut is a crash-consistent image of the one disk
# you least want to guess about, so base gives up rather than force it.
@test "snap.ps1 base: will not force a guest down to take a baseline" {
    api_start "$RUNNING_VM" --ignore-shutdown
    run api_run snap.ps1 -Mode base -Vm test -GraceSec 6
    api_is 22
    run grep -c 'POST /v1/vms/test/stop' "$API_LOG"
    [ "$output" = 0 ]
    run grep -c 'POST /v1/vms/test/snapshots' "$API_LOG"
    [ "$output" = 0 ]
}

# THE ORDER IS FORCED BY THE API and this is the test that proves the script honours it: a
# branch is created by STARTING, and a branch is deletable only while the VM is stopped, so the
# old branch has to go BEFORE the new one is made. Reversing it would deadlock against the real
# daemon, and no grep in forge.bats can see the difference.
@test "snap.ps1 rollback: discards the old branch before starting the new one" {
    api_start "$BASED_VM"
    run api_run snap.ps1 -Mode rollback -Vm test -GraceSec 20
    api_is 0
    [[ "$output" == *phase=rolled* ]]
    local del start
    del=$(grep -n 'DELETE /v1/vms/test/snapshots/0/branches/0' "$API_LOG" | head -1 | cut -d: -f1)
    start=$(grep -n 'POST /v1/vms/test/start' "$API_LOG" | head -1 | cut -d: -f1)
    [ -n "$del" ]
    [ -n "$start" ]
    [ "$del" -lt "$start" ]
    # And the baseline itself survives: rollback returns TO it, never deletes it.
    [[ "$(api_state)" == *draugr-base-x* ]]
}

@test "snap.ps1 rollback: refuses when there is no baseline, and changes nothing" {
    api_start "$ONE_VM"
    run api_run snap.ps1 -Mode rollback -Vm test -GraceSec 20
    api_is 21
    run grep -c 'POST /v1/vms/test/start' "$API_LOG"
    [ "$output" = 0 ]
}

# COUNTS, which is where tonight's bug lived: `return @($x)` unrolls a single-element array, so
# one snapshot with one branch reported branches= and snapshots= EMPTY rather than 1. The
# grep-based tests could not see it; this reads the numbers the script actually printed.
@test "snap.ps1 status: one snapshot with one branch counts as one, not blank" {
    api_start "$BASED_VM"
    run api_run snap.ps1 -Mode status -Vm test
    api_is 0
    [[ "$output" == *"snapshots=1"* ]]
    [[ "$output" == *"branches=1"* ]]
    [[ "$output" == *"baseline=yes"* ]]
    [[ "$output" == *"current_snap=0"* ]]
}

@test "snap.ps1: an unknown VM is reported as unknown, not as a failed call" {
    api_start "$ONE_VM"
    run api_run snap.ps1 -Mode status -Vm nosuchvm
    api_is 11
}

# --- rm.ps1: the delete verb that was verified --------------------------------------------

# `DELETE /vms/<name>` answered 405 and cost a failed dr-forge rm. This runs the
# real call against a server that only implements the right one.
@test "rm.ps1 delete: removes the VM through POST /delete" {
    # THE STORE IS SEEDED BEFORE THE SERVER STARTS, and that is the whole correction. The
    # mock loads state.json once and keeps it in memory, so the patch this test used to apply
    # AFTERWARDS never reached it: rm.ps1 was served the fixture's `C:\ForgeLayers` and went
    # looking in the developer's real layer store. It passed because that folder happened to
    # exist with a disk in it, and failed the moment the machine was tidied up -,
    # which is the only reason anyone found out. A test that reads the real disk is not
    # testing what it claims to.
    local store win vms
    store="$(api_win_tmp)/ForgeLayers"
    # rm.ps1 confirms the folder by finding a disk in it, so the shape has to be real.
    mkdir -p "$store/test"
    printf 'not a real disk\n' > "$store/test/disk.vhdx"
    win=$(api_winpath "$store")
    # Built with json.dumps rather than by substituting into the fixture: the value is a
    # Windows path, and every backslash in it would otherwise need escaping twice over.
    vms=$(python3 -c 'import json, sys; print(json.dumps({"test": {"running": False, "diskDirectory": sys.argv[1], "ramMb": 8192, "snapshots": [], "current": {"snapIndex": -1, "branchIndex": -1}}}))' "$win")
    api_start "$vms"
    run api_run rm.ps1 -Mode delete -Vm test
    api_is 0
    [[ "$output" == *phase=gone* ]]
    [[ "$(api_calls)" == *"POST /v1/vms/test/delete"* ]]
    # The route that does not exist must not be attempted at all.
    run grep -cE '^DELETE /v1/vms/test$' "$API_LOG"
    [ "$output" = 0 ]
}
