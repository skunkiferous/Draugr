#!/usr/bin/env bats
#
# forge-api.bats: the control plane of the forge, EXECUTED, not grepped.
#
# WHY THIS FILE EXISTS. forge.bats asserts that the scripts CONTAIN things. 64
# of its assertions are a grep for a string in a file. Those catch only a
# renamed verb. `rollback` can discard the wrong branch, `base` can forget to
# stop the VM, and each of them still passes. The scripts reach AppSandbox only
# over about ten HTTP endpoints. Thus tests/appsandbox_mock.py is enough to
# really run them.
#
# WHAT THAT GIVES: the mock logs each request, so a test can assert the ORDER of
# the real calls of a script. The API forces the order in two places. A START
# creates a branch, and a branch can be deleted only while stopped. No grep can
# see that.
#
# WHY IT SKIPS. These run the real scripts under the real Windows PowerShell,
# because they run there in production. `pwsh` on Linux has different path
# semantics, and none of the Windows surface. The suite skips if powershell.exe,
# python3, or a Windows-visible scratch directory is missing. That is each
# machine that is not the own host of the forge.
#
# WHAT IT CANNOT COVER. Only the half that talks to the daemon. The guest
# scripts (reduce-churn.ps1, install-shot.ps1, harden-sshd.ps1) touch scheduled
# tasks, the registry, Defender, and sshd. No mock makes those exist. Only a
# real guest can test them.

load helper

setup() {
    dr_test_setup
    # THE REAL powershell.exe, NOT THE MOCK. helper.bash puts tests/mocks first
    # on PATH. Thus a bare `powershell.exe` here is the stub of the rest of the
    # suite. It answers each call with a success, and makes all ten of these
    # fail the same way. Found once, with the mocks directory removed from PATH,
    # as the dr-setup tests reach the real ssh.
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

# /mnt/c/x -> C:\x. The scripts are Windows programs, and each path that they
# get must be a Windows path. DR_TMP is under /tmp, which Windows cannot see.
# Thus DR_WIN_TMP.
api_winpath() {
    local p=$1 drive rest
    p=${p#/mnt/}
    drive=${p%%/*}
    rest=${p#*/}
    printf '%s:\\%s' "$(printf '%s' "$drive" | tr 'a-z' 'A-Z')" "$(printf '%s' "$rest" | tr '/' '\\')"
}

# Start the mock with a given state. $1 is the VMs object. The rest goes to the
# mock. That is how a test asks for --ignore-shutdown. THE LOCATION OF THE
# WINDOWS-VISIBLE TEMP TREE, computed, not remembered. A test that puts a path
# under it into the state of the mock needs that path BEFORE api_start runs. The
# mock reads state.json exactly once, at startup (see the note there).
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

    # WINDOWS CANNOT ALWAYS REACH A PORT THAT THE MOCK CAN BIND IN WSL, and the
    # scripts connect from Windows. A TEST SHOWED THIS, after three of these
    # failed in the full suite, and none failed alone. Hyper-V reserves blocks
    # of the Windows dynamic range (`netsh int ipv4 show excludedportrange
    # protocol=tcp` listed ~1260 ports here, in blocks of a hundred from 49684
    # up). Nothing on Windows can bind one. Thus the localhost relay of WSL2
    # never publishes it, but the own loopback of WSL serves it correctly. The
    # mock answered, the call log held only the probe, and snap.ps1 exited 10,
    # "nothing answers". WSL cannot see the exclusions, so no picker here can
    # avoid them.
    #
    # Thus, if Windows cannot reach the port, this DISCARDS it, and does not
    # wait. The failure is immediate (connection refused). Linux picks random
    # ephemeral ports, so the next port is in a different place.
    local attempt
    for attempt in 1 2 3 4 5 6; do
        : > "$API_LOG"
        : > "$API_MOCK_LOG"
        API_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')

        # Each forge script finds the daemon through host.json. It is read from
        # $env:ProgramData, and api_run overrides that to point here.
        printf '{"endpoint":"http://127.0.0.1:%s","token":"%s"}\n' "$API_PORT" "$API_TOKEN" \
            > "$DR_WIN_TMP/AppSandbox/host.json"

        # ITS OUTPUT GOES TO A FILE, not into the output of the test. Nobody can
        # diagnose a daemon whose stderr is lost in the harness. While this was
        # a mystery, the failure said only exit 10. It gave no traceback, no
        # exit status, and no way to tell a crash from a kill.
        python3 "$DR_ROOT/tests/appsandbox_mock.py" --port "$API_PORT" --state "$API_STATE" \
            --log "$API_LOG" "$@" > "$API_MOCK_LOG" 2>&1 &
        API_PID=$!

        # Two waits, because they answer different questions, and one wait hid
        # the bug for a day. The WSL probe says that the mock STARTED AND BOUND.
        # The Windows probe says that the code under test can really reach it.
        # Only the second is the important effect. A fixed sleep for either is
        # too short on a busy machine.
        if api_wait_wsl && api_wait_win; then
            # The calls of the probes do not belong to the script, and the tests
            # assert ORDER.
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

# Reachable from Windows, where powershell.exe connects from. curl.exe is in
# System32 since Windows 10 1803. $DR_REAL_PS is the fallback. It is not wrong,
# but it is slow (a process start for each probe), so it is a bad first choice.
#
# TWO TRIES, NOT TWENTY, and tests showed both numbers. A port that the relay
# publishes answers from Windows in 40 ms after WSL (12 new ports, and twice
# Windows answered first). Thus there is nothing to wait for. A RESERVED port
# refuses in ~2.1 s, not at once, because Windows sends the SYN again. Thus each
# extra try costs two seconds, on the path that discards the port anyway.
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

# Run one of the real scripts under the real powershell.exe, with ProgramData
# pointed at the temp tree, so that it finds the host.json of the mock.
#
# DO NOT QUOTE PARAMETER NAMES. `& script '-Mode' 'stop'` gives "-Mode" as a
# positional VALUE, not as a parameter name. The script then refuses its own
# arguments. That looks like a bug in the script, not in the harness.
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
    # NOT A PIPE. `powershell | tr` returns the status of TR, which is always 0.
    # Thus each exit code that the scripts document reads as success. Then the
    # tests that assert 20, 21, 22, and 11 fail, and the ones that assert 0
    # pass. That is exactly what happened.
    local out status=0
    out=$("$DR_REAL_PS" -NoProfile -ExecutionPolicy Bypass \
            -File "$(api_winpath "$wrapper")" 2>&1) || status=$?
    printf '%s\n' "$out" | tr -d '\r'
    return "$status"
}

# The calls of a script, as "METHOD /path" lines. That is the purpose of the
# mock.
api_calls() { cat "$API_LOG"; }
api_state() { cat "$API_STATE"; }

# The exit-code assertion, WITH THE EVIDENCE. A bare `[ "$status" -eq 22 ]`
# prints only the assertion. Three of these failed in the full suite, but passed
# when the file ran alone. That left a ten-minute run, a line number, and no
# exit code, no script output, and no call log. With this, one run found the
# port exclusions: the words of the script, the calls that the mock got, and a
# live daemon. It prints only on the failed path. Thus you can diagnose the next
# such failure from the run that caught it.
api_is() {
    local want=$1
    [ "$status" -eq "$want" ] && return 0
    local alive=no
    kill -0 "${API_PID:-0}" 2>/dev/null && alive=yes
    printf 'expected exit %s, got %s\n--- script output ---\n%s\n--- calls ---\n%s\n' \
        "$want" "$status" "$output" "$(api_calls)" >&2
    printf -- '--- mock still running: %s ---\n%s\n' \
        "$alive" "$(cat "${API_MOCK_LOG:-/dev/null}" 2>/dev/null)" >&2
    # Reachability from WINDOWS, tested again at the moment of failure. From
    # here, two failures look the same, and this tells them apart. One is a port
    # that Windows cannot reach (rc 7, and api_start must discard it).
    # The other is a request that arrived, and got an answer that the script
    # refused.
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

# `down` now asks /shutdown itself, and does not wait for one that the caller
# sent. forge.bats tests the mode ORDER in dr-forge. This tests the HTTP.
@test "vm.ps1 stop: asks for a graceful shutdown and does not pull the plug" {
    api_start "$RUNNING_VM"
    run api_run vm.ps1 -Mode stop -Vm test -GraceSec 20
    api_is 0
    [[ "$(api_calls)" == *"POST /v1/vms/test/shutdown"* ]]
    # The plug must NOT be used, because the guest went down cleanly.
    run grep -c 'POST /v1/vms/test/stop' "$API_LOG"
    [ "$output" = 0 ]
}

# The fallback exists only for a guest that does not go down. --ignore-shutdown
# accepts the clean call, and does nothing. That is the real case that this is
# for.
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
    # The snapshot must come AFTER the shutdown. The daemon answers 409 to a
    # snapshot of a running VM. Thus a caller with the wrong order fails on the
    # real daemon.
    local order
    order=$(grep -oE 'POST /v1/vms/test/(shutdown|snapshots)' "$API_LOG" | sed 's|.*/||' | tr '\n' ' ')
    [[ "$order" == "shutdown snapshots "* ]]
    [[ "$(api_state)" == *draugr-base-* ]]
}

# ONE BASELINE. The AppSandbox bug affects the second snapshot. Thus the refusal
# is the feature, and it must refuse WITHOUT a change to the VM.
@test "snap.ps1 base: refuses a second baseline and leaves the VM alone" {
    api_start "$BASED_VM"
    run api_run snap.ps1 -Mode base -Vm test -GraceSec 20
    api_is 20
    run grep -c 'POST /v1/vms/test/snapshots' "$API_LOG"
    [ "$output" = 0 ]
    run grep -c 'POST /v1/vms/test/shutdown' "$API_LOG"
    [ "$output" = 0 ]
}

# A baseline from a guest that lost power is a crash-consistent image of the
# most important disk. Thus base stops, and does not force it.
@test "snap.ps1 base: will not force a guest down to take a baseline" {
    api_start "$RUNNING_VM" --ignore-shutdown
    run api_run snap.ps1 -Mode base -Vm test -GraceSec 6
    api_is 22
    run grep -c 'POST /v1/vms/test/stop' "$API_LOG"
    [ "$output" = 0 ]
    run grep -c 'POST /v1/vms/test/snapshots' "$API_LOG"
    [ "$output" = 0 ]
}

# THE API FORCES THE ORDER, and this test proves that the script obeys it. A
# START creates a branch, and a branch can be deleted only while the VM is
# stopped. Thus the old branch must go BEFORE the new one exists. The reverse
# order deadlocks on the real daemon, and no grep in forge.bats can see the
# difference.
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
    # And the baseline stays. rollback returns TO it, and never deletes it.
    [[ "$(api_state)" == *draugr-base-x* ]]
}

@test "snap.ps1 rollback: refuses when there is no baseline, and changes nothing" {
    api_start "$ONE_VM"
    run api_run snap.ps1 -Mode rollback -Vm test -GraceSec 20
    api_is 21
    run grep -c 'POST /v1/vms/test/start' "$API_LOG"
    [ "$output" = 0 ]
}

# COUNTS. A bug was here. `return @($x)` unrolls an array with one element. Thus
# one snapshot with one branch reported branches= and snapshots= EMPTY, not 1.
# The grep tests did not see it. This reads the numbers that the script really
# printed.
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

# --- rm.ps1: the tested delete verb -------------------------------------------------------

# `DELETE /vms/<name>` answered 405, and cost a failed dr-forge rm. This runs
# the real call against a server that implements only the correct one.
@test "rm.ps1 delete: removes the VM through POST /delete" {
    # THE STORE GETS ITS DATA BEFORE THE SERVER STARTS. That is the full fix.
    # The mock loads state.json once, and keeps it in memory. Thus the patch
    # that this test applied LATER never reached it. rm.ps1 got the
    # `C:\ForgeLayers` of the fixture, and searched the real layer store of the
    # developer. It passed only because that folder existed, with a disk in it.
    # It failed when somebody cleaned the machine. That is the only reason that
    # anyone saw it. A test that reads the real disk does not test its claim.
    local store win vms
    store="$(api_win_tmp)/ForgeLayers"
    # rm.ps1 proves the folder with a disk in it, so the shape must be real.
    mkdir -p "$store/test"
    printf 'not a real disk\n' > "$store/test/disk.vhdx"
    win=$(api_winpath "$store")
    # Built with json.dumps, not with a substitution into the fixture. The value
    # is a Windows path. Without this, each backslash in it needs two escapes.
    vms=$(python3 -c 'import json, sys; print(json.dumps({"test": {"running": False, "diskDirectory": sys.argv[1], "ramMb": 8192, "snapshots": [], "current": {"snapIndex": -1, "branchIndex": -1}}}))' "$win")
    api_start "$vms"
    run api_run rm.ps1 -Mode delete -Vm test
    api_is 0
    [[ "$output" == *phase=gone* ]]
    [[ "$(api_calls)" == *"POST /v1/vms/test/delete"* ]]
    # The script must never try the route that does not exist.
    run grep -cE '^DELETE /v1/vms/test$' "$API_LOG"
    [ "$output" = 0 ]
}
