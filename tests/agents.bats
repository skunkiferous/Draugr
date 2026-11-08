#!/usr/bin/env bats
# The agent modules: lib/agents/<agent>.sh, and how one gets chosen.
#
# The first test here is the most important. A second module that is sourced
# defines again only its own functions. If a module misses one, the answer of
# the PREVIOUS agent stays. dr-mem then copies the memory of Claude into a Codex
# mound, and nothing on the screen says so. lib/agents/default.sh is the
# specification. Each other module must define all that it defines.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# The interface, read from default.sh, not listed here. Thus a new function in
# the spec is automatically required of each module. Matches "name() {" at the
# start of a line, because all of them use that form.
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
            # One subshell for each module. In one shell, an earlier module can
            # fill the gap of a later one. That is the exact bug.
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
    # A sed that silently matches nothing makes each module pass.
    [ "$(interface | wc -l)" -ge 5 ]
}

@test "agents: an agent with no module gets the default" {
    # Exported, not only a prefix on dr_agent_load. The label comes from
    # $DRAUGR_AGENT at CALL time, so the value must stay after the load. That
    # is how a real command works. The configuration cascade sets it, and all
    # later code reads it.
    export DRAUGR_AGENT=gemini
    dr_agent_load
    # The answer of the default. It is the honest one for an agent with no
    # tests.
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

    # The case that can fail silently: no old Claude path.
    DRAUGR_AGENT=nosuchagent dr_agent_load
    run dr_agent_mem_dir /mnt/c/src/myproject
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "agents: the memory directory's parent is what dr-mem creates" {
    DRAUGR_AGENT=claude dr_agent_load
    # dr-mem gets the parent with dirname, and does not ask for it separately.
    # Thus the two cannot be different. This writes down that assumption.
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
    # dr-skills and dr-setup never call dr_load_config. Thus the functions must
    # exist as soon as common.sh is sourced. dr_load_common just did that, and
    # nothing else.
    declare -F dr_agent_mem_supported >/dev/null
}

@test "agents: the config cascade decides which module, not the environment alone" {
    local repo
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr-trust --yes "$repo/.draugr.conf" >/dev/null 2>&1

    # dr_load_config sources the project configuration, then loads the module
    # again. Thus the answer must be the configured agent, not the default.
    dr_load_config "$repo"
    run dr_agent_mem_label
    [ "$output" = gemini ]
}

# --- what dr-mem does with an agent it does not know -------------------------

# dr-mem goes through dr_context, which requires a repo under /mnt/<drive>.
# Thus these need a real Windows path, not the plain temp dir of dr_make_repo.
@test "dr-mem: refuses rather than copying into a place nobody reads" {
    local repo
    repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    export DRAUGR_AGENT=gemini
    run dr-mem status
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not know where gemini keeps its memory"* ]]
    # It names the agents that it knows, so that you can act on the message.
    [[ "$output" == *claude* ]]
}

@test "dr-mem check: an unknown agent means nothing to lose, not a failure" {
    local repo
    repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    # dr-rm calls this before it destroys a mound. A failure here makes "I do
    # not know this agent" into a permanent refusal to remove its mound.
    export DRAUGR_AGENT=gemini
    run dr-mem check
    [ "$status" -eq 0 ]
}

# --- signing in, which is not the same command for every agent ---------------
#
# `sbx secret set -g anthropic --oauth` is the obvious spelling, and sbx refuses
# it: "anthropic OAuth cannot be started from `sbx secret set`; sign in from
# inside the Claude sandbox". The same flag for openai is the documented example
# of sbx. Before, dr-doctor printed one fixed line for both. Thus it was wrong
# for the agent that Draugr was built for.

@test "signin: Claude Code does not recommend the flow sbx refuses" {
    DRAUGR_AGENT=claude dr_agent_load
    run dr_agent_signin "$(dr_agent_secret)"
    [ "$status" -eq 0 ]
    # The refused command, in the spelling that sbx refuses.
    [[ "$output" != *"set -g anthropic --oauth"* ]]
    # What really works: sign in inside a mound.
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
    # No --oauth for an agent with no tests. sbx supports it for some services,
    # and refuses it for others. Thus a guess brings the bug back.
    DRAUGR_AGENT=gemini dr_agent_load
    run dr_agent_signin google
    [ "$status" -eq 0 ]
    [[ "$output" != *"--oauth"* ]]
    [[ "$output" == *"sbx secret set"* ]]
}

@test "signin: every module says something, and dr-doctor can use it" {
    # dr-doctor gives the output to mapfile, and expands it into soft(). Thus an
    # empty answer prints a heading with no advice under it.
    local a
    for a in claude codex gemini; do
        DRAUGR_AGENT=$a dr_agent_load
        [ -n "$(dr_agent_signin somesvc)" ] || { printf 'no hint for %s\n' "$a" >&2; return 1; }
    done
}
