#!/usr/bin/env bats
# DRAUGR_ENV: any environment for the session of the agent.
#
# The general fallback. It is validated, and not passed through, for this
# reason. An agent IGNORES an environment variable that it does not know, and
# does not refuse it. Thus a typo in a name gives a session that looks correct,
# but works as if the value was never written. That is the failure that this key
# must prevent, from the other side. Thus most tests here are about what gets
# refused, and when.

load helper

setup() {
    dr_test_setup
    dr_load_common
    DRAUGR_AGENT=claude
    dr_agent_load
    DRAUGR_ENV=
    DRAUGR_MODEL=
    DRAUGR_MODEL_URL=11435
    DRAUGR_MODEL_FAST=
}

teardown() { dr_test_teardown; }

# --- parsing ------------------------------------------------------------------

@test "dr_env_pairs: empty is silent, not an error" {
    DRAUGR_ENV=
    run dr_env_pairs
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "dr_env_pairs: one pair" {
    DRAUGR_ENV="FOO=bar"
    run dr_env_pairs
    [ "$status" -eq 0 ]
    [ "$output" = "FOO=bar" ]
}

@test "dr_env_pairs: several, in the order written" {
    # The order is important on the far side. If two entries name one variable,
    # the last wins, as in the rest of the configuration cascade.
    DRAUGR_ENV="A=1 B=2 C=3"
    run dr_env_pairs
    [ "${lines[0]}" = "A=1" ]
    [ "${lines[1]}" = "B=2" ]
    [ "${lines[2]}" = "C=3" ]
}

@test "dr_env_pairs: a value may contain = and be empty" {
    DRAUGR_ENV="URL=http://x/?a=b EMPTY="
    run dr_env_pairs
    [ "${lines[0]}" = "URL=http://x/?a=b" ]
    [ "${lines[1]}" = "EMPTY=" ]
}

@test "dr_env_pairs: a glob in a value is not expanded" {
    # read -ra, not an unquoted expansion. See the trap documented at
    # dr_kit_refs, where * becomes a list of the current directory.
    DRAUGR_ENV="PATTERN=*"
    run dr_env_pairs
    [ "$output" = "PATTERN=*" ]
}

# --- what is refused ----------------------------------------------------------

@test "dr_env_pairs: an entry with no = is refused" {
    DRAUGR_ENV="NOEQUALS"
    run dr_env_pairs
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not NAME=value"* ]]
}

@test "dr_env_pairs: a name that is not an identifier is refused" {
    # It cannot be exported. The rcfile then fails to source, and takes the full
    # session with it, not only this variable.
    DRAUGR_ENV="9BAD=x"
    run dr_env_pairs
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a variable name"* ]]

    DRAUGR_ENV="has-hyphen=x"
    run dr_env_pairs
    [ "$status" -ne 0 ]
}

@test "dr_env_pairs: PATH and HOME are refused" {
    # PATH REPLACES, and does not extend. Thus an absolute one drops the
    # directory of the agent binary, and the next dr-go ends in "command not
    # found".
    DRAUGR_ENV="PATH=/usr/bin"
    run dr_env_pairs
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not set PATH"* ]]

    DRAUGR_ENV="HOME=/tmp"
    run dr_env_pairs
    [ "$status" -ne 0 ]
}

@test "dr_env_pairs: a bad entry refuses the whole set, not just itself" {
    # A half-applied environment is worse than none. The session starts with a
    # part of your request, and nothing tells you which part.
    DRAUGR_ENV="GOOD=1 NOEQUALS GOOD2=2"
    run dr_env_pairs
    [ "$status" -ne 0 ]
}

# --- reaching the agent -------------------------------------------------------

@test "dr_attach_rc: exports what DRAUGR_ENV asks for" {
    DRAUGR_ENV="CLAUDE_CODE_DISABLE_1M_CONTEXT=1"
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"export CLAUDE_CODE_DISABLE_1M_CONTEXT=1"* ]]
}

@test "dr_attach_rc: says nothing when DRAUGR_ENV is empty" {
    DRAUGR_ENV=
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" != *"export "* ]]
}

@test "dr_attach_rc: a value with shell metacharacters round-trips" {
    # Quoted with %q here, and read back by a bash there. Without quotes, the
    # semicolon ends the export, and runs the rest as a command.
    DRAUGR_ENV='X=a;rm_-rf_/'
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" != *"export X=a;rm"* ]]
    [[ "$output" == *'export X=a\;rm_-rf_/'* ]]
}

@test "dr_attach_rc: DRAUGR_ENV comes after the model variables" {
    # Thus an explicit value wins. A fallback that the tool can silently
    # override is not a fallback.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_ENV="ZZZ=1"
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    model_line=$(printf '%s\n' "$output" | grep -n "ANTHROPIC_BASE_URL" | cut -d: -f1)
    env_line=$(printf '%s\n' "$output" | grep -n "export ZZZ=" | cut -d: -f1)
    [ "$env_line" -gt "$model_line" ]
}

@test "dr_attach_rc: a collision with a model variable is reported" {
    # It still wins. But two values and a hidden winner can cost an afternoon,
    # so the output says it aloud.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_ENV="ANTHROPIC_BASE_URL=http://elsewhere:1234"
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"and that replaces the value from DRAUGR_MODEL"* ]]
    [[ "$output" == *"export ANTHROPIC_BASE_URL=http://elsewhere:1234"* ]]
}

@test "dr_attach_rc: a malformed DRAUGR_ENV writes no rcfile at all" {
    # Also not the entries before the bad one. A half-applied environment is
    # worse than none, because nothing on the screen says which half arrived.
    DRAUGR_ENV="GOOD=1 NOEQUALS"
    run dr_attach_rc claude
    [ "$status" -ne 0 ]
    [[ "$output" != *"export GOOD=1"* ]]
}

@test "dr_attach_rc: still starts the agent from PROMPT_COMMAND" {
    # The exports must not disturb the job-control setup below them.
    DRAUGR_ENV="FOO=bar"
    run dr_attach_rc claude
    [[ "$output" == *"PROMPT_COMMAND="* ]]
    [[ "$output" == *"148"* ]]
}
