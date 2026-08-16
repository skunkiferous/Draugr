#!/usr/bin/env bats
# How Draugr gets a terminal inside the mound, and why it is ssh.
#
# The short version: `sbx run` and `sbx exec` reach the sandbox through sbx.exe,
# a Windows binary running under WSL interop, and Ctrl-Z suspends that relay
# rather than anything in the sandbox. The session then stops responding and
# dies with "inspect exec: context deadline exceeded". Over ssh the far end is a
# real pty doing its own job control, so Ctrl-Z stops the agent and hands you the
# mound's shell. Both measured against sbx 0.37.1.
#
# tests/mocks/ssh records the remote command instead of connecting, so what is
# asserted here is the string that would reach the mound's shell.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    SANDBOX="draugr-$(basename "$REPO")"
    export DR_MOCK_NAME="$SANDBOX"

    # These are about attaching, so nothing else may use the transport. git
    # fetches over ssh:// too, and with the mock first on PATH an auto-sync would
    # land its own lines in the same log.
    export DRAUGR_AUTO_SYNC=false DRAUGR_MEM_SYNC=off
}

teardown() { dr_test_teardown; }

calls() { grep "^$1 " "$DR_MOCK_LOG" || true; }

# The rcfile as the mound's bash will see it: decoded back out of the remote
# command, rather than trusted from the side that wrote it. head -1 because the
# attach is always the first connection of a session.
decode_rc() {
    calls ssh | head -1 | sed 's/.*printf %s //; s/ | base64.*//' | base64 -d
}

# dr-go will not attach without a terminal, so these go through a pty.
go_pty() {
    DR_MOCK_STATE=running script -qec "dr-go $*" /dev/null >/dev/null 2>&1 || true
}

# --- the pieces --------------------------------------------------------------

@test "dr_ssh_host: the Host pattern dr-setup already writes" {
    dr_load_common
    DRAUGR_SANDBOX=draugr-thing
    [ "$(dr_ssh_host)" = "draugr-thing.sbx" ]
}

@test "dr_shquote: an argument with spaces survives the crossing" {
    dr_load_common
    # Quoted by bash here, unquoted by bash there. Any other pairing is a guess.
    out=$(dr_shquote claude --model "two words")
    [ "$(bash -c "printf '[%s]' $out")" = "[claude][--model][two words]" ]
}

@test "dr_attach_rc: the agent starts from PROMPT_COMMAND, not from the rcfile" {
    dr_load_common
    out=$(dr_attach_rc claude)
    # Straight from the rcfile it would hang: bash has not enabled job control
    # while it is still running its startup files, so the first Ctrl-Z would
    # suspend something nothing could resume. Measured, the hard way.
    [[ "$out" == *"PROMPT_COMMAND="* ]]
    [[ "$out" != *$'\nclaude'* ]]
}

@test "dr_attach_rc: 148 is what keeps suspending apart from exiting" {
    dr_load_common
    out=$(dr_attach_rc claude)
    # 128 + SIGTSTP. Without the guard, a suspended job does not abandon the rest
    # of its command list, so the trailing exit would run on Ctrl-Z too and the
    # session would end at the exact moment you asked for a shell.
    [[ "$out" == *"-eq 148"* ]]
    [[ "$out" == *"|| exit"* ]]
}

@test "dr_attach_rc: the mound's own bashrc still runs" {
    dr_load_common
    [[ "$(dr_attach_rc claude)" == *". ~/.bashrc"* ]]
}

@test "dr_attach_rc: a PROMPT_COMMAND of yours is put back, not eaten" {
    dr_load_common
    # It fires once, and the shell you are left with is the one you would have
    # had anyway.
    [[ "$(dr_attach_rc claude)" == *'PROMPT_COMMAND=$_dr_pc'* ]]
}

@test "dr_attach_remote: with no command it is a plain interactive shell" {
    dr_load_common
    out=$(dr_attach_remote /c/Code/thing)
    [ "$out" = "cd /c/Code/thing && exec bash -i" ]
}

@test "dr_attach_remote: with a command it carries an rcfile, base64 encoded" {
    dr_load_common
    out=$(dr_attach_remote /c/Code/thing claude)
    # base64 because the string passes through ssh into a remote shell, and every
    # layer would otherwise want its own round of quoting.
    [[ "$out" == *"base64 -d"* ]]
    [[ "$out" == *"--rcfile"* ]]
    [[ "$out" == *"cd /c/Code/thing"* ]]
}

@test "dr_attach_remote: a directory with a space in it is quoted" {
    dr_load_common
    [[ "$(dr_attach_remote "/c/My Code/thing")" == *"/c/My\\ Code/thing"* ]]
}

@test "dr_attach_check: a typo is refused, and told where it came from" {
    dr_load_common
    dr_load_config
    DRAUGR_ATTACH=shh
    run dr_attach_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRAUGR_ATTACH is 'shh'"* ]]
    [[ "$output" == *"built-in default"* ]]
}

@test "dr_attach_check: both transports are accepted" {
    dr_load_common
    dr_load_config
    for t in ssh sbx; do
        DRAUGR_ATTACH=$t
        run dr_attach_check
        [ "$status" -eq 0 ]
    done
}

# --- dr-go -------------------------------------------------------------------

@test "dr-go: attaches over ssh by default" {
    go_pty
    [[ "$(calls ssh)" == *"$SANDBOX.sbx"* ]]
    [ -z "$(calls run)" ]
}

@test "dr-go: asks ssh for a terminal" {
    # Without -t there is no remote pty, because a remote command was given - and
    # an agent with no terminal has nothing to draw on.
    go_pty
    [[ "$(calls ssh)" == "ssh -t "* ]]
}

@test "dr-go: lands in the clone, not in the mound's home directory" {
    go_pty
    # ssh logs you into ~/workspace, which is empty. The work is at the mirrored
    # path, and dr-sync's URL points at the same place.
    [[ "$(decode_rc)" != "" ]]
    [[ "$(calls ssh)" == *"cd /c/"* ]]
}

@test "dr-go: says how to get the shell" {
    DR_MOCK_STATE=running run script -qec "dr-go" /dev/null
    [[ "$output" == *"Ctrl-Z"* ]]
}

@test "dr-go: DRAUGR_AGENT=shell attaches with no rcfile at all" {
    # There is no agent to start, so there is nothing for PROMPT_COMMAND to do.
    export DRAUGR_AGENT=shell
    go_pty
    [[ "$(calls ssh)" == *"exec bash -i"* ]]
    [[ "$(calls ssh)" != *"base64"* ]]
}

@test "dr-go: an agent argument is quoted, not pasted into a shell line" {
    # The rcfile is shell, so an argument containing a metacharacter would
    # otherwise stop being an argument. dr_shquote is what stands between the
    # two, and this is the case that would prove it missing.
    export DRAUGR_AGENT_ARGS='--flag;whoami'
    go_pty
    [[ "$(decode_rc)" == *'--flag\;whoami'* ]]
    [[ "$(decode_rc)" != *'; whoami'* ]]
}

@test "dr-go: the far side's exit status is dr-go's" {
    # The rcfile ends with `exit $_dr_s`, so what ssh returns is the agent's own
    # status. dr-go has always propagated it and still does.
    export DR_MOCK_SSH_RC=7
    rc=0
    DR_MOCK_STATE=running script -qec "dr-go" /dev/null >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 7 ]
}

@test "dr-go: a failed connection is not silently a successful session" {
    export DR_MOCK_FAIL=ssh
    rc=0
    DR_MOCK_STATE=running script -qec "dr-go" /dev/null >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}

@test "dr-go: DRAUGR_ATTACH=sbx goes back to sbx run" {
    export DRAUGR_ATTACH=sbx
    go_pty
    [[ "$(calls run)" == *"--name $SANDBOX"* ]]
    [ -z "$(calls ssh)" ]
}

@test "dr-go: an unknown transport refuses before creating anything" {
    export DRAUGR_ATTACH=telnet
    DR_MOCK_STATE=absent run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRAUGR_ATTACH is 'telnet'"* ]]
    [ -z "$(calls create)" ]
}

# --- dr-shell ----------------------------------------------------------------

@test "dr-shell: interactive goes over ssh, with a terminal, in the clone" {
    DR_MOCK_STATE=running script -qec "dr-shell" /dev/null >/dev/null 2>&1 || true
    [[ "$(calls ssh)" == "ssh -t "* ]]
    [[ "$(calls ssh)" == *"cd /c/"* ]]
    [[ "$(calls ssh)" == *"exec bash -i"* ]]
}

@test "dr-shell: one command asks for no terminal, so it stays pipeable" {
    DR_MOCK_STATE=running run dr-shell -- ls -la
    [[ "$(calls ssh)" != "ssh -t "* ]]
    [[ "$(calls ssh)" == *"ls -la"* ]]
}

@test "dr-shell: a command argument with a space is quoted for the far side" {
    DR_MOCK_STATE=running run dr-shell -- grep "two words" file
    [[ "$(calls ssh)" == *'grep two\ words file'* ]]
}

@test "dr-shell --root: sudo, because ssh authenticates as the agent" {
    # sbx has -u root; ssh does not, and the agent is in the sudo group with no
    # password. Verified against sbx 0.37.1.
    DR_MOCK_STATE=running run dr-shell --root -- id
    [[ "$(calls ssh)" == *"sudo id"* ]]
}

@test "dr-shell --root: interactive keeps the working directory" {
    # sudo -s rather than -i: a login shell would move you to /root, and the
    # reason to be root here is to fix something in the clone.
    DR_MOCK_STATE=running script -qec "dr-shell --root" /dev/null >/dev/null 2>&1 || true
    [[ "$(calls ssh)" == *"exec sudo -s"* ]]
    [[ "$(calls ssh)" != *"sudo -i"* ]]
}

@test "dr-shell: DRAUGR_ATTACH=sbx goes back to sbx exec" {
    export DRAUGR_ATTACH=sbx
    DR_MOCK_STATE=running run dr-shell -- ls
    [[ "$(calls exec)" == *"$SANDBOX ls"* ]]
    [ -z "$(calls ssh)" ]
}

@test "dr-shell: a mound that does not exist is still caught first" {
    DR_MOCK_STATE=absent run dr-shell -- ls
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
    [ -z "$(calls ssh)" ]
}
