#!/usr/bin/env bats
# DRAUGR_ENV: arbitrary environment for the agent's session.
#
# The escape hatch, and the reason it is validated rather than passed through: an
# environment variable an agent does not recognise is IGNORED, not refused. A
# typo'd name therefore produces a session that looks entirely correct and
# behaves as though the setting had never been written - which is the failure
# this key exists to prevent, reached from the other side. So most of what is
# tested here is what gets refused, and when.

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
    # Order matters on the far side: two entries naming one variable resolve to
    # the last, the same way the rest of the config cascade does.
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
    # read -ra rather than an unquoted expansion: the trap documented at
    # dr_kit_refs, where * would become a listing of the current directory.
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
    # It could not be exported at all: the rcfile would fail to source and take
    # the whole session with it, rather than just this variable.
    DRAUGR_ENV="9BAD=x"
    run dr_env_pairs
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a variable name"* ]]

    DRAUGR_ENV="has-hyphen=x"
    run dr_env_pairs
    [ "$status" -ne 0 ]
}

@test "dr_env_pairs: PATH and HOME are refused" {
    # PATH REPLACES rather than extends, so an absolute one drops the directory
    # holding the agent binary and the next dr-go ends in "command not found".
    DRAUGR_ENV="PATH=/usr/bin"
    run dr_env_pairs
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not set PATH"* ]]

    DRAUGR_ENV="HOME=/tmp"
    run dr_env_pairs
    [ "$status" -ne 0 ]
}

@test "dr_env_pairs: a bad entry refuses the whole set, not just itself" {
    # Half-applied environment is worse than none: the session would start with
    # some of what you asked for and no indication which half.
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
    # Quoted with %q here and read back by a bash over there. Unquoted, the
    # semicolon would end the export and run the rest as a command.
    DRAUGR_ENV='X=a;rm_-rf_/'
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" != *"export X=a;rm"* ]]
    [[ "$output" == *'export X=a\;rm_-rf_/'* ]]
}

@test "dr_attach_rc: DRAUGR_ENV comes after the model variables" {
    # So an explicit setting wins. An escape hatch the tool can silently
    # overrule is not an escape hatch.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_ENV="ZZZ=1"
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    model_line=$(printf '%s\n' "$output" | grep -n "ANTHROPIC_BASE_URL" | cut -d: -f1)
    env_line=$(printf '%s\n' "$output" | grep -n "export ZZZ=" | cut -d: -f1)
    [ "$env_line" -gt "$model_line" ]
}

@test "dr_attach_rc: a collision with a model variable is reported" {
    # It still wins - but two settings and an invisible winner is how an
    # afternoon goes missing, so it is said out loud.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_ENV="ANTHROPIC_BASE_URL=http://elsewhere:1234"
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"overriding what DRAUGR_MODEL derived"* ]]
    [[ "$output" == *"export ANTHROPIC_BASE_URL=http://elsewhere:1234"* ]]
}

@test "dr_attach_rc: a malformed DRAUGR_ENV writes no rcfile at all" {
    # Not even the entries before the bad one: a half-applied environment is
    # worse than none, because nothing on screen says which half arrived.
    DRAUGR_ENV="GOOD=1 NOEQUALS"
    run dr_attach_rc claude
    [ "$status" -ne 0 ]
    [[ "$output" != *"export GOOD=1"* ]]
}

@test "dr_attach_rc: still starts the agent from PROMPT_COMMAND" {
    # The exports must not disturb the job-control arrangement they sit above.
    DRAUGR_ENV="FOO=bar"
    run dr_attach_rc claude
    [[ "$output" == *"PROMPT_COMMAND="* ]]
    [[ "$output" == *"148"* ]]
}
