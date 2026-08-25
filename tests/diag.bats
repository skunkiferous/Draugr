#!/usr/bin/env bats
# Reading sandboxd's log, which is how a create failure stops being a dead end.
#
# sbx reports a failed create as `500 Internal Server Error: failed to run
# sandbox container` and nothing more, while its daemon has the failing command,
# its exit code and its captured output. Draugr reads that log - an undocumented
# file with an undocumented shape - so the tests below are as much about what
# happens when the reading FAILS as about what happens when it works: every path
# has to fall back to the advice dr-up printed before any of this existed.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    SANDBOX="draugr-$(basename "$REPO")"
    export DR_MOCK_NAME="$SANDBOX"
    dr_fake_sbx_root
    LOGDIR="$DR_TMP/sbxroot/sandboxes/state/sandboxd"
    LOG="$LOGDIR/daemon.log"
}

teardown() { dr_test_teardown; }

# Append one log entry. `stage` is what sandboxd attaches to a create failure,
# and is what tells such an entry apart from ordinary error noise.
entry() {
    local level=$1 err=$2 stage=${3:-}
    mkdir -p "$LOGDIR"
    if [ -n "$stage" ]; then
        jq -cn --arg l "$level" --arg e "$err" --arg s "$stage" \
            '{time:"t",level:$l,stage:$s,error:$e}' >> "$LOG"
    else
        jq -cn --arg l "$level" --arg e "$err" '{time:"t",level:$l,error:$e}' >> "$LOG"
    fi
}

# --- the helpers ------------------------------------------------------------

@test "dr_sbx_daemon_log: no log is a quiet failure, not an error" {
    dr_load_common
    run dr_sbx_daemon_log
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "dr_sbx_daemon_log: found by walking up from sbx itself" {
    entry ERROR "boom" run_container
    dr_load_common
    run dr_sbx_daemon_log
    [ "$status" -eq 0 ]
    [ "$output" = "$LOG" ]
}

@test "dr_sbx_log_mark: with no log at all, zero" {
    dr_load_common
    run dr_sbx_log_mark
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "dr_sbx_log_mark: counts what is already there" {
    entry ERROR "boom" run_container
    dr_load_common
    run dr_sbx_log_mark
    [ "$output" = "$(wc -c < "$LOG" | tr -d ' ')" ]
}

@test "dr_sbx_log_error: nothing appended since the mark" {
    entry ERROR "boom" run_container
    dr_load_common
    mark=$(dr_sbx_log_mark)
    run dr_sbx_log_error "$mark"
    [ "$status" -eq 1 ]
}

@test "dr_sbx_log_error: an older failure is not reported as this one" {
    entry ERROR "yesterday's failure" run_container
    dr_load_common
    mark=$(dr_sbx_log_mark)
    entry ERROR "today's failure" run_container
    run dr_sbx_log_error "$mark"
    [ "$status" -eq 0 ]
    [ "$output" = "today's failure" ]
}

@test "dr_sbx_log_error: the captured output comes back multi-line" {
    dr_load_common
    mark=$(dr_sbx_log_mark)
    entry ERROR "commands.install[2] (npm ci): exited 1
  -- captured output --
  ENOENT: no such file" run_container
    run dr_sbx_log_error "$mark"
    [ "${lines[0]}" = "commands.install[2] (npm ci): exited 1" ]
    [ "${lines[2]}" = "  ENOENT: no such file" ]
}

@test "dr_sbx_log_error: the entry with a stage wins over ordinary noise" {
    dr_load_common
    mark=$(dr_sbx_log_mark)
    entry ERROR "the real cause" run_container
    entry ERROR "record not found"
    run dr_sbx_log_error "$mark"
    [ "$output" = "the real cause" ]
}

@test "dr_sbx_log_error: INFO entries carrying an error field are ignored" {
    dr_load_common
    mark=$(dr_sbx_log_mark)
    entry ERROR "the real cause" run_container
    entry INFO "http request"
    run dr_sbx_log_error "$mark"
    [ "$output" = "the real cause" ]
}

# The log is being written while it is read, so the last line is routinely half
# there. One torn line must not throw away the entries before it.
@test "dr_sbx_log_error: a torn final line does not lose the good ones" {
    dr_load_common
    mark=$(dr_sbx_log_mark)
    entry ERROR "the real cause" run_container
    printf '{"time":"t","level":"ERR' >> "$LOG"
    run dr_sbx_log_error "$mark"
    [ "$status" -eq 0 ]
    [ "$output" = "the real cause" ]
}

# --- dr-up's use of it ------------------------------------------------------

@test "dr-up: a failed create reports what sandboxd recorded" {
    export DR_MOCK_STATE=absent DR_MOCK_FAIL=create
    export DR_MOCK_DAEMON_ERR="start container: started hook: exited 2
  -- captured output --
  error: File not found"
    run dr-up
    [ "$status" -eq 1 ]
    [[ "$output" == *"sandboxd recorded:"* ]]
    [[ "$output" == *"error: File not found"* ]]
}

@test "dr-up: a failed install command explains when install commands run" {
    export DR_MOCK_STATE=absent DR_MOCK_FAIL=create
    export DR_MOCK_DAEMON_ERR="commands.install[2] (npm ci): exited 1"
    run dr-up
    [ "$status" -eq 1 ]
    [[ "$output" == *"BEFORE your repository is in"* ]]
    [[ "$output" == *"/run/sandbox/source"* ]]
}

# The install explanation is specific and would be misleading anywhere else, so
# a failure that is not about install commands must not attract it.
@test "dr-up: an unrelated failure gets the kit advice, not the install one" {
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\nkind: mixin\nname: k\n' > "$REPO/.draugr/kit/spec.yaml"
    export DR_MOCK_STATE=absent DR_MOCK_FAIL=create
    export DR_MOCK_DAEMON_ERR="compose: kit \"k\" requires base agent \"claude\""
    run dr-up
    [ "$status" -eq 1 ]
    [[ "$output" == *"dr-kit validate"* ]]
    [[ "$output" != *"BEFORE your repository"* ]]
}

# With no log to read, every message must be exactly what it was before this
# feature existed - the whole point of it being best-effort.
@test "dr-up: with no daemon log, the advice is unchanged" {
    export DR_MOCK_STATE=absent DR_MOCK_FAIL=create
    run dr-up
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not create"* ]]
    [[ "$output" != *"sandboxd recorded"* ]]
    [[ "$output" == *"DRAUGR_DEBUG=1"* ]]
}
