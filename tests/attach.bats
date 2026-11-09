#!/usr/bin/env bats
# How Draugr gets a terminal inside the mound, and why it is ssh.
#
# In short: `sbx run` and `sbx exec` reach the sandbox through sbx.exe, a
# Windows binary under WSL interop. Ctrl-Z suspends that relay, not something in
# the sandbox. The session then stops responding, and dies with "inspect exec:
# context deadline exceeded". Over ssh, the far end is a real pty with its own
# job control. Thus Ctrl-Z stops the agent, and gives you the shell of the
# mound. Tests on sbx 0.37.1 showed both.
#
# tests/mocks/ssh records the remote command, and does not connect. Thus these
# tests assert the string that reaches the shell of the mound.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    SANDBOX="draugr-$(basename "$REPO")"
    export DR_MOCK_NAME="$SANDBOX"

    # These tests are about the attach, so nothing else can use the transport.
    # git also fetches over ssh://. With the mock first on PATH, an auto-sync
    # puts its own lines in the same log.
    export DRAUGR_AUTO_SYNC=false DRAUGR_MEM_SYNC=off
}

teardown() { dr_test_teardown; }

calls() { grep "^$1 " "$DR_MOCK_LOG" || true; }

# The rcfile as the bash of the mound sees it: decoded from the remote command,
# not trusted from the side that wrote it. head -1, because the attach is always
# the first connection of a session.
decode_rc() {
    calls ssh | head -1 | sed 's/.*printf %s //; s/ | base64.*//' | base64 -d
}

# dr-go does not attach without a terminal, so these go through a pty.
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
    # Bash quotes it here, and bash unquotes it there. Each other pair is a
    # guess.
    out=$(dr_shquote claude --model "two words")
    [ "$(bash -c "printf '[%s]' $out")" = "[claude][--model][two words]" ]
}

@test "dr_attach_rc: the agent starts from PROMPT_COMMAND, not from the rcfile" {
    dr_load_common
    out=$(dr_attach_rc claude)
    # Directly from the rcfile, it hangs. While bash still runs its startup
    # files, job control is not on yet. Thus the first Ctrl-Z suspends something
    # that nothing can resume. A painful test showed this.
    [[ "$out" == *"PROMPT_COMMAND="* ]]
    [[ "$out" != *$'\nclaude'* ]]
}

@test "dr_attach_rc: 148 is what keeps suspending apart from exiting" {
    dr_load_common
    out=$(dr_attach_rc claude)
    # 128 + SIGTSTP. Without the guard, a suspended job continues the rest of
    # its command list. Thus the exit at the end also runs on Ctrl-Z, and the
    # session ends at the moment that you ask for a shell.
    [[ "$out" == *"-eq 148"* ]]
    [[ "$out" == *"|| exit"* ]]
}

@test "dr_attach_rc: the mound's own bashrc still runs" {
    dr_load_common
    [[ "$(dr_attach_rc claude)" == *". ~/.bashrc"* ]]
}

@test "dr_attach_rc: a PROMPT_COMMAND of yours is put back, not eaten" {
    dr_load_common
    # It fires once. After that, you have the same shell as without it.
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
    # base64, because the string goes through ssh into a remote shell. Without
    # it, each layer needs its own round of quotes.
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
    # Without -t, there is no remote pty, because a remote command was given. An
    # agent with no terminal has nothing to draw on.
    go_pty
    [[ "$(calls ssh)" == "ssh -t "* ]]
}

@test "dr-go: lands in the clone, not in the mound's home directory" {
    go_pty
    # ssh logs you into ~/workspace, which is empty. The work is at the mirrored
    # path, and the URL of dr-sync points to the same place.
    [[ "$(decode_rc)" != "" ]]
    [[ "$(calls ssh)" == *"cd /c/"* ]]
}

@test "dr-go: says how to get the shell" {
    DR_MOCK_STATE=running run script -qec "dr-go" /dev/null
    [[ "$output" == *"Ctrl-Z"* ]]
}

@test "dr-go: DRAUGR_AGENT=shell attaches with no rcfile at all" {
    # There is no agent to start, so PROMPT_COMMAND has nothing to do.
    export DRAUGR_AGENT=shell
    go_pty
    [[ "$(calls ssh)" == *"exec bash -i"* ]]
    [[ "$(calls ssh)" != *"base64"* ]]
}

@test "dr-go: an agent argument is quoted, not pasted into a shell line" {
    # The rcfile is shell. Thus, without a guard, an argument with a
    # metacharacter stops being an argument. dr_shquote is the guard, and this
    # case proves that it is there.
    export DRAUGR_AGENT_ARGS='--flag;whoami'
    go_pty
    [[ "$(decode_rc)" == *'--flag\;whoami'* ]]
    [[ "$(decode_rc)" != *'; whoami'* ]]
}

@test "dr-go: the far side's exit status is dr-go's" {
    # The rcfile ends with `exit $_dr_s`, so ssh returns the status of the
    # agent. dr-go always passed it on, and still does.
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

# --- the session that --continue needs ---------------------------------------
#
# With --continue in DRAUGR_AGENT_ARGS, a new mound has no transcript to
# continue. Claude Code then prints one line and stops, and the attach does not
# happen. The fix for that must not lose a session that WAS there. Thus the
# probe answers in words: a failed call into the mound never means "there is no
# session".

@test "claude session flags: only the arguments that carry no value" {
    dr_load_common
    DRAUGR_AGENT=claude dr_agent_load
    run dr_agent_session_flags
    [ "$status" -eq 0 ]
    [[ "$output" == *"--continue"* ]]
    [[ "$output" == *"-c"* ]]
    # --resume takes an optional session id. If dr-go drops only the flag, the
    # id stays behind as a positional argument, and the agent reads it as a
    # prompt. Thus --resume must NOT be in this list.
    [[ "$output" != *"--resume"* ]] || return 1
}

@test "claude session probe: a project directory with no transcript is none" {
    dr_load_common
    DRAUGR_AGENT=claude dr_agent_load
    dr_mound_memory_dir "$REPO"
    DRAUGR_SANDBOX=$SANDBOX
    # The project directory exists, and holds memory but no session.
    mkdir -p "$DR_MEMDIR"
    run dr_agent_session_present "$REPO"
    [ "$output" = none ]
}

@test "claude session probe: one transcript beside the memory is a session" {
    dr_load_common
    DRAUGR_AGENT=claude dr_agent_load
    dr_mound_memory_dir "$REPO"
    DRAUGR_SANDBOX=$SANDBOX
    mkdir -p "$DR_MEMDIR"
    : > "${DR_MEMDIR%/memory}/4d1e8f02.jsonl"
    run dr_agent_session_present "$REPO"
    [ "$output" = present ]
}

@test "claude session probe: a call that fails cannot say there is no session" {
    dr_load_common
    DRAUGR_AGENT=claude dr_agent_load
    dr_mound_memory_dir "$REPO"
    DRAUGR_SANDBOX=$SANDBOX
    # The tree is empty. Thus code that reads a failed call as an answer says
    # "none" here, and dr-go throws the argument away.
    DR_MOCK_FAIL=exec run dr_agent_session_present "$REPO"
    [ "$output" != none ] || return 1
}

@test "dr-go: a --continue that cannot work is dropped, not sent" {
    export DRAUGR_AGENT_ARGS="--settings /x/s.json --continue"
    dr_mound_memory_dir "$REPO"
    mkdir -p "$DR_MEMDIR"
    go_pty
    # The other arguments still arrive. Only the argument that cannot work is
    # gone.
    [[ "$(decode_rc)" == *"claude --settings /x/s.json;"* ]]
    [[ "$(decode_rc)" != *"--continue"* ]] || return 1
}

@test "dr-go: --continue survives when the mound has a session" {
    export DRAUGR_AGENT_ARGS="--continue"
    dr_mound_memory_dir "$REPO"
    mkdir -p "$DR_MEMDIR"
    : > "${DR_MEMDIR%/memory}/4d1e8f02.jsonl"
    go_pty
    [[ "$(decode_rc)" == *"--continue"* ]]
}

@test "default module: an unmeasured agent declares nothing and answers unknown" {
    # These two answers keep dr-go away from an agent that nobody measured.
    # Each one alone is enough. "unknown" is the important one. If this answer
    # is "none", dr-go throws a correct argument away for each such agent.
    dr_load_common
    DRAUGR_AGENT=gemini dr_agent_load
    run dr_agent_session_flags
    [ -z "$output" ]
    run dr_agent_session_present /mnt/c/src/whatever
    [ "$output" = unknown ]
}

@test "dr-go: a probe that cannot answer leaves --continue alone" {
    # The tree holds no transcript. Thus only the rule "unknown is not none"
    # keeps the argument. dr-up does not exec when the mound already runs.
    # Thus the failure below hits only the probe.
    export DRAUGR_AGENT_ARGS="--continue" DR_MOCK_FAIL=exec
    dr_mound_memory_dir "$REPO"
    mkdir -p "$DR_MEMDIR"
    go_pty
    [[ "$(decode_rc)" == *"--continue"* ]]
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
    # sbx has -u root. ssh does not, and the agent is in the sudo group with no
    # password. Tested on sbx 0.37.1.
    DR_MOCK_STATE=running run dr-shell --root -- id
    [[ "$(calls ssh)" == *"sudo id"* ]]
}

@test "dr-shell --root: interactive keeps the working directory" {
    # sudo -s, not -i. A login shell moves you to /root, and you are root here
    # to fix something in the clone.
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
