#!/usr/bin/env bats
# The agent modules: lib/agents/<agent>.sh, and how one gets chosen.
#
# The load-bearing test here is the first one. Sourcing a second module
# redefines only the functions that module happens to define, so a module
# missing one leaves the PREVIOUS agent's answer standing - and dr-mem would
# then copy Claude's memory into a Codex mound with nothing on screen to say so.
# lib/agents/default.sh is treated as the specification: whatever it defines,
# every other module must define too.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# The interface, read out of default.sh rather than listed here, so that adding
# a function to the spec automatically requires it of every module. Matches
# "name() {" at the start of a line, which is how all of them are written.
interface() {
    sed -n 's/^\(dr_agent_[a-z_]*\)() *{.*/\1/p' "$DR_ROOT/lib/agents/default.sh" | sort -u
}

modules() {
    find "$DR_ROOT/lib/agents" -name '*.sh' -type f | sort
}

@test "agents: every module defines every function in the interface" {
    local missing=() module name fn
    for module in $(modules); do
        name=$(basename "$module" .sh)
        for fn in $(interface); do
            # A subshell per module: sourcing them all into one shell would let
            # an earlier module satisfy a later one, which is the exact bug.
            if ! ( . "$module"; declare -F "$fn" >/dev/null ); then
                missing+=("$name: $fn")
            fi
        done
    done
    if [ ${#missing[@]} -gt 0 ]; then
        printf 'agent modules missing interface functions:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "agents: the interface is not empty, so the test above can fail" {
    # A sed that silently matched nothing would make every module pass.
    [ "$(interface | wc -l)" -ge 5 ]
}

@test "agents: an agent with no module gets the default" {
    # Exported rather than prefixed onto dr_agent_load alone: the label is
    # answered at CALL time from $DRAUGR_AGENT, so the setting has to outlive
    # the load - which is how it works in a real command, where the config
    # cascade sets it and everything afterwards reads it.
    export DRAUGR_AGENT=gemini
    dr_agent_load
    # The default's answer, which is the honest one for an agent nobody measured.
    run dr_agent_mem_supported
    [ "$status" -eq 1 ]
    run dr_agent_mem_label
    [ "$output" = gemini ]
}

@test "agents: claude is the default agent, and its layout is known" {
    dr_agent_load
    run dr_agent_mem_supported
    [ "$status" -eq 0 ]
    run dr_agent_mem_label
    [ "$output" = "Claude Code" ]
}

@test "agents: loading a second module replaces the first one's answers" {
    DRAUGR_AGENT=claude dr_agent_load
    run dr_agent_mem_dir /mnt/c/src/myproject
    [ "$output" = "/home/agent/.claude/projects/-c-src-myproject/memory" ]

    # The case that would go wrong silently: no leftover Claude path.
    DRAUGR_AGENT=nosuchagent dr_agent_load
    run dr_agent_mem_dir /mnt/c/src/myproject
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "agents: the memory directory's parent is what dr-mem creates" {
    DRAUGR_AGENT=claude dr_agent_load
    # dr-mem takes the parent with dirname rather than asking for it separately,
    # so the two cannot disagree. This is that assumption, written down.
    local dir
    dir=$(dr_agent_mem_dir /mnt/c/src/myproject)
    [ "$(dirname "$dir")" = "/home/agent/.claude/projects/-c-src-myproject" ]
}

@test "agents: dr_agent_known lists the modules and leaves out the default" {
    run dr_agent_known
    [[ "$output" == *claude* ]]
    [[ "$output" != *default* ]]
}

@test "agents: a module is loaded before any config is read" {
    # dr-skills and dr-setup never call dr_load_config, so the functions have to
    # exist from the moment common.sh is sourced. dr_load_common has just done
    # that and nothing else.
    declare -F dr_agent_mem_supported >/dev/null
}

@test "agents: the config cascade decides which module, not the environment alone" {
    local repo
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr-trust --yes "$repo/.draugr.conf" >/dev/null 2>&1

    # dr_load_config sources the project config and then reloads the module, so
    # the answer must be the config's agent rather than the built-in default.
    dr_load_config "$repo"
    run dr_agent_mem_label
    [ "$output" = gemini ]
}

# --- what dr-mem does with an agent it does not know -------------------------

# dr-mem goes through dr_context, which insists on a repo under /mnt/<drive> -
# so these need a real Windows path rather than dr_make_repo's plain temp dir.
@test "dr-mem: refuses rather than copying into a place nobody reads" {
    local repo
    repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    export DRAUGR_AGENT=gemini
    run dr-mem status
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not know where gemini keeps its memory"* ]]
    # It names the agents it does know, so the message is actionable.
    [[ "$output" == *claude* ]]
}

@test "dr-mem check: an unknown agent means nothing to lose, not a failure" {
    local repo
    repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    # dr-rm calls this before destroying a mound. Failing here would turn "I do
    # not know this agent" into a refusal to ever remove its mound.
    export DRAUGR_AGENT=gemini
    run dr-mem check
    [ "$status" -eq 0 ]
}

# --- signing in, which is not the same command for every agent ---------------
#
# `sbx secret set -g anthropic --oauth` is the obvious spelling and sbx refuses
# it outright: "anthropic OAuth cannot be started from `sbx secret set`; sign in
# from inside the Claude sandbox". The same flag against openai is sbx's own
# documented example. dr-doctor used to print one hardcoded line for both, so it
# was wrong for exactly the agent Draugr was built against.

@test "signin: Claude Code does not recommend the flow sbx refuses" {
    DRAUGR_AGENT=claude dr_agent_load
    run dr_agent_signin "$(dr_agent_secret)"
    [ "$status" -eq 0 ]
    # The refused command, in the spelling sbx rejects.
    [[ "$output" != *"set -g anthropic --oauth"* ]]
    # What actually works: sign in inside a mound.
    [[ "$output" == *"/login"* ]]
    [[ "$output" == *"dr-go"* ]]
}

@test "signin: Codex keeps the --oauth flow, which works for openai" {
    DRAUGR_AGENT=codex dr_agent_load
    run dr_agent_signin "$(dr_agent_secret)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-g openai --oauth"* ]]
}

@test "signin: an unmeasured agent gets advice that cannot be wrong" {
    # No --oauth for an agent nobody has checked: sbx supports it for some
    # services and refuses it for others, so guessing would reproduce the bug.
    DRAUGR_AGENT=gemini dr_agent_load
    run dr_agent_signin google
    [ "$status" -eq 0 ]
    [[ "$output" != *"--oauth"* ]]
    [[ "$output" == *"sbx secret set"* ]]
}

@test "signin: every module says something, and dr-doctor can use it" {
    # dr-doctor feeds the output to mapfile and expands it into soft(), so an
    # empty answer would print a heading with no advice under it.
    local a
    for a in claude codex gemini; do
        DRAUGR_AGENT=$a dr_agent_load
        [ -n "$(dr_agent_signin somesvc)" ] || { printf 'no hint for %s\n' "$a" >&2; return 1; }
    done
}
