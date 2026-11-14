#!/usr/bin/env bats
# The test harness itself, and the one part of it that only a mound exercises.
#
# Each mound command refuses a repo that is not under /mnt/<letter>/, so a test
# of one needs a repo on such a path. A mound has no /mnt at all. The drives of
# Windows are at /c in there, so the search in dr_win_root finds nothing, and
# the whole mound half of the suite skips in the one place where an agent is
# most likely to run it. dr_win_root_make is what removes that.
#
# These tests drive it from the outside, because this machine never reaches it:
# /mnt/c/Temp exists here, and the search answers first. Without them, the code
# that makes the mound half of the suite real is itself untested.

load helper

setup() { dr_test_setup; }
teardown() { dr_test_teardown; }

# Elevation without elevating. dr_win_root_make runs `sudo -n <command>`, and a
# function of that name shadows the binary for the rest of this shell. The
# callers use a command substitution, which is a subshell, and a subshell sees
# the function too. Thus the real mkdir and the real chmod run, as this user,
# inside $DR_TMP. The shift drops the -n.
fake_sudo() { sudo() { shift; "$@"; }; }

@test "harness: dr_pty gives the command a terminal on each descriptor" {
    # dr-go and dr-shell test for one and refuse without it. A helper that gives
    # no pty makes every attach test fail on the harness, and name the code.
    run dr_pty 'test -t 0 && test -t 1 && test -t 2 && echo three'
    [ "$status" -eq 0 ]
    [[ "$output" == *three* ]]
}

@test "harness: dr_pty answers with the status of the command" {
    # One attach test asserts an exact 7, which is the status that the far side
    # of the ssh gave. A helper that loses it leaves that test unable to fail.
    run dr_pty 'exit 7'
    [ "$status" -eq 7 ]
}

@test "harness: dr_pty keeps both streams of the command" {
    # The tests that read the output of dr-go read its warnings as well as its
    # own lines. `script` put both on the pty, and so does this.
    run dr_pty 'printf "on stdout\n"; printf "on stderr\n" >&2'
    [[ "$output" == *"on stdout"* ]]
    [[ "$output" == *"on stderr"* ]]
}

@test "harness: dr_pty reports a death by signal as a shell does" {
    # 128 plus the signal, which is what a caller comparing statuses expects.
    # A signal reported as 0 is a session that died and looks like a success.
    run dr_pty 'kill -TERM $$'
    [ "$status" -eq 143 ]
}

@test "harness: pty_run.py on its own says how to call it" {
    run python3 "$DR_ROOT/tests/pty_run.py"
    [ "$status" -eq 2 ]
    [[ "$output" == *usage* ]]
}

@test "harness: outside a sandbox it makes nothing, whatever sudo allows" {
    fake_sudo
    unset IS_SANDBOX
    run dr_win_root_make "$DR_TMP/mnt/c/Temp"
    [ "$status" -ne 0 ]
    # The whole point of the guard. A test run on a real machine must never
    # create /mnt, however much permission it happens to hold.
    [ ! -d "$DR_TMP/mnt" ]
}

@test "harness: in a sandbox it makes the root, writable, and prints it" {
    fake_sudo
    export IS_SANDBOX=1
    run dr_win_root_make "$DR_TMP/mnt/c/Temp"
    [ "$status" -eq 0 ]
    [ "$output" = "$DR_TMP/mnt/c/Temp" ]
    [ -d "$output" ]
    [ -w "$output" ]
}

@test "harness: elevation that fails prints no root, so the caller still skips" {
    # A mound answers `sudo -n` without a password. Any other place can refuse,
    # and a refusal must read as "no root", not as a path that is not there.
    sudo() { return 1; }
    export IS_SANDBOX=1
    run dr_win_root_make "$DR_TMP/mnt/c/Temp"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "harness: a sudo that does nothing leaves no root, and says so" {
    # The half-made case. An elevation that answers 0 and creates nothing must
    # not read as a root, or a hundred tests run against a path that is not
    # there, and every failure then names the wrong thing.
    sudo() { return 0; }
    export IS_SANDBOX=1
    run dr_win_root_make "$DR_TMP/mnt/c/Temp"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "harness: it asks for the mode as well as the directory" {
    # Assert on the argv, as the rest of the suite does with the sbx mock. root
    # makes the directory and the tests write in it as the agent, so the mode is
    # half of the job. The host cannot observe it any other way: the fake sudo
    # creates the directory as this user, who can write in it either way.
    export IS_SANDBOX=1
    sudo() { shift; printf '%s\n' "$*" >> "$DR_TMP/sudo.log"; "$@"; }
    run dr_win_root_make "$DR_TMP/mnt/c/Temp"
    [ "$status" -eq 0 ]
    grep -qxF "mkdir -p $DR_TMP/mnt/c/Temp" "$DR_TMP/sudo.log"
    grep -qxF "chmod 1777 $DR_TMP/mnt/c/Temp" "$DR_TMP/sudo.log"
}

@test "harness: dr_win_root asks for a root when the search finds none" {
    # The candidates are a list, and not two literals inside the loop, so that
    # this test can point them at nothing. That is the only way to reach the
    # fallback from a machine that has a real /mnt/c.
    DR_WIN_ROOT_CANDIDATES=("$DR_TMP/nowhere")
    dr_win_root_make() { printf '%s' "$DR_TMP/made"; }
    run dr_win_root
    [ "$status" -eq 0 ]
    [ "$output" = "$DR_TMP/made" ]
}

@test "harness: a root that the search finds is used, and nothing is made" {
    # The maker is the last resort. A machine that already has a writable root
    # must keep using it, or every run of the suite calls sudo for nothing.
    mkdir -p "$DR_TMP/found"
    DR_WIN_ROOT_CANDIDATES=("$DR_TMP/found")
    dr_win_root_make() { printf '%s' "$DR_TMP/made"; }
    run dr_win_root
    [ "$status" -eq 0 ]
    [ "$output" = "$DR_TMP/found" ]
}

@test "harness: an explicit override replaces the search, and can be nothing" {
    # The documented contract of DRAUGR_TEST_WINROOT. Tests of the skip path
    # point it at a directory that is not there, and the fallback must not
    # quietly rescue them.
    export DRAUGR_TEST_WINROOT="$DR_TMP/not-here"
    dr_win_root_make() { printf '%s' "$DR_TMP/made"; }
    run dr_win_root
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
