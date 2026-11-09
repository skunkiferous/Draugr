#!/usr/bin/env bats
# Configuration layers, the source of each value, and trust on first use.

load helper

setup()    { dr_test_setup; dr_load_common; }
teardown() { dr_test_teardown; }

@test "defaults apply when nothing else exists" {
    dr_load_config
    [ "$DRAUGR_AGENT" = claude ]
    [ "$DRAUGR_REMOTE" = draugr ]
    [ "$DRAUGR_CLONE" = true ]
    [ "${DR_ORIGIN[DRAUGR_AGENT]}" = "built-in default" ]
}

@test "user config beats defaults" {
    printf 'DRAUGR_AGENT=codex\n' > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_AGENT" = codex ]
    [[ "${DR_ORIGIN[DRAUGR_AGENT]}" == *"/config" ]]
}

@test "project config beats user config" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=codex\n'  > "$DRAUGR_CONFIG_HOME/config"
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.conf"
    dr_load_config "$repo"
    [ "$DRAUGR_AGENT" = gemini ]
    [[ "${DR_ORIGIN[DRAUGR_AGENT]}" == *".draugr.conf" ]]
}

@test "project-local beats project config" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n'   > "$repo/.draugr.conf"
    printf 'DRAUGR_AGENT=opencode\n' > "$repo/.draugr.local.conf"
    dr_trust_add "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.local.conf"
    dr_load_config "$repo"
    [ "$DRAUGR_AGENT" = opencode ]
    [[ "${DR_ORIGIN[DRAUGR_AGENT]}" == *".draugr.local.conf" ]]
}

@test "environment beats every config file" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.conf"
    DRAUGR_AGENT=droid
    dr_load_config "$repo"
    [ "$DRAUGR_AGENT" = droid ]
    [ "${DR_ORIGIN[DRAUGR_AGENT]}" = environment ]
}

@test "a flag beats the environment" {
    DRAUGR_AGENT=droid
    dr_load_config
    dr_config_set_flag DRAUGR_AGENT kiro
    [ "$DRAUGR_AGENT" = kiro ]
    [ "${DR_ORIGIN[DRAUGR_AGENT]}" = "command-line flag" ]
}

@test "untouched keys keep their default origin when another key is set" {
    printf 'DRAUGR_AGENT=codex\n' > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "${DR_ORIGIN[DRAUGR_REMOTE]}" = "built-in default" ]
}

@test "branch defaults to the checked-out branch, not literally main" {
    repo=$(dr_make_repo)
    git -C "$repo" checkout -qb feature/x
    dr_load_config "$repo"
    [ "$DRAUGR_BRANCH" = feature/x ]
    [[ "${DR_ORIGIN[DRAUGR_BRANCH]}" == detected* ]]
}

@test "sandbox name is derived when unset" {
    repo=$(dr_make_repo myproject)
    dr_load_config "$repo"
    [ "$DRAUGR_SANDBOX" = draugr-myproject ]
}

@test "an untrusted project config is NOT sourced" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    # not trusted, on purpose
    dr_load_config "$repo" 2>/dev/null
    [ "$DRAUGR_AGENT" = claude ]
}

@test "trusting a config makes it take effect" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    run dr_trust_is_trusted "$repo/.draugr.conf"
    [ "$status" -ne 0 ]
    dr_trust_add "$repo/.draugr.conf"
    run dr_trust_is_trusted "$repo/.draugr.conf"
    [ "$status" -eq 0 ]
}

@test "editing a trusted config revokes trust" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.conf"
    printf 'DRAUGR_AGENT=gemini\nDRAUGR_CLONE=false\n' > "$repo/.draugr.conf"
    run dr_trust_is_trusted "$repo/.draugr.conf"
    [ "$status" -ne 0 ]
}

# --- reporting a layer that was skipped ---------------------------------------
#
# A refused configuration is the one failure that looks like nothing happened.
# The table shows built-in defaults, the same as for an empty file. A person who
# runs dr-config wants to know why something does not work. Thus the refusal
# must stay visible until the end of the output.

@test "DR_UNTRUSTED names the layer that was skipped" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr_load_config "$repo" 2>/dev/null
    [ "${#DR_UNTRUSTED[@]}" -eq 1 ]
    [ "${DR_UNTRUSTED[0]}" = "$repo/.draugr.conf" ]
}

@test "DR_UNTRUSTED is empty when every layer is trusted" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.conf"
    dr_load_config "$repo"
    [ "${#DR_UNTRUSTED[@]}" -eq 0 ]
}

@test "DR_UNTRUSTED does not accumulate across loads" {
    # Each load resets it, and does not append to it. Thus a second
    # dr_load_config in the same process cannot report the same file twice.
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr_load_config "$repo" 2>/dev/null
    dr_load_config "$repo" 2>/dev/null
    [ "${#DR_UNTRUSTED[@]}" -eq 1 ]
}

@test "dr-config: the refusal is the LAST thing printed" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    cd "$repo"
    run dr-config
    [[ "${lines[${#lines[@]}-1]}" == *"dr-trust"* ]]
    [[ "$output" == *"NOT sourced"* ]]
    [[ "$output" == *"$repo/.draugr.conf"* ]]
}

@test "dr-config: it counts them, and still exits 0" {
    # An ignored configuration is not a failure. Nothing gave an error, and
    # people often pipe dr-config to grep. Thus it must not return non-zero. It
    # is loud, not fatal.
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n'  > "$repo/.draugr.conf"
    printf 'DRAUGR_AGENT=codex\n'   > "$repo/.draugr.local.conf"
    cd "$repo"
    run dr-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 configuration files were NOT sourced"* ]]
}

@test "dr-config: nothing is said when there is nothing to say" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.conf"
    cd "$repo"
    run dr-config
    [[ "$output" != *"NOT sourced"* ]]
}

@test "dr-config --changed: the refusal survives there too" {
    # This is most important with --changed. A refused file makes the view
    # empty. That reads as "you configured nothing", not as "it was ignored".
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    cd "$repo"
    run dr-config --changed
    [[ "$output" == *"NOT sourced"* ]]
}

@test "dr-config --files: an untrusted file is marked as not sourced" {
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT=gemini\n' > "$repo/.draugr.conf"
    cd "$repo"
    run dr-config --files
    [[ "$output" == *"NO: not sourced"* ]]
}

@test "the user's own config needs no trust" {
    printf 'DRAUGR_AGENT=codex\n' > "$DRAUGR_CONFIG_HOME/config"
    run dr_trust_check "$DRAUGR_CONFIG_HOME/config"
    [ "$status" -eq 0 ]
}

@test "re-trusting replaces the old hash rather than accumulating" {
    repo=$(dr_make_repo)
    printf 'A=1\n' > "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.conf"
    printf 'A=2\n' > "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.conf"
    [ "$(grep -c "$repo/.draugr.conf" "$DRAUGR_CONFIG_HOME/trusted")" -eq 1 ]
}

@test "a config can compute values, which is why it is shell" {
    printf 'DRAUGR_PORTS="$(echo 5173:5173)"\n' > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_PORTS" = 5173:5173 ]
}

@test "dr_is_true accepts the usual spellings" {
    for v in true True TRUE yes y 1 on; do
        run dr_is_true "$v"; [ "$status" -eq 0 ]
    done
    for v in false no 0 off ""; do
        run dr_is_true "$v"; [ "$status" -ne 0 ]
    done
}

@test "sandbox state is read from sbx ls --json" {
    DR_MOCK_STATE=running DR_MOCK_NAME=draugr-x run dr_sandbox_state draugr-x
    [ "$output" = running ]
}

@test "an unknown sandbox reports absent" {
    DR_MOCK_STATE=running DR_MOCK_NAME=draugr-x run dr_sandbox_state draugr-other
    [ "$output" = absent ]
}

# --- per-agent agent arguments -----------------------------------------------
#
# DRAUGR_AGENT_ARGS holds the own flags of the AGENT. Thus one machine-wide
# value is wrong as soon as a second agent is used. These tests pin the key that
# fixes that. Most of all, they pin why it must be a key, not advice. A shell
# conditional in the user configuration cannot see DRAUGR_AGENT, because that
# layer is sourced before the project sets it.

@test "agent args: the per-agent key beats the generic one" {
    printf 'DRAUGR_AGENT=claude\nDRAUGR_AGENT_ARGS=generic\nDRAUGR_AGENT_ARGS_CLAUDE=--continue\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_AGENT_ARGS" = "--continue" ]
    [[ "${DR_ORIGIN[DRAUGR_AGENT_ARGS]}" == *"via DRAUGR_AGENT_ARGS_CLAUDE"* ]]
}

@test "agent args: another agent's key is ignored" {
    printf 'DRAUGR_AGENT=codex\nDRAUGR_AGENT_ARGS=generic\nDRAUGR_AGENT_ARGS_CLAUDE=--continue\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_AGENT_ARGS" = generic ]
    [[ "${DR_ORIGIN[DRAUGR_AGENT_ARGS]}" != *"via"* ]]
}

@test "agent args: a replaced generic value and its origin are kept" {
    # The replacement overwrites the value AND its origin, so without this
    # nothing afterwards can tell a deliberate per-agent value from one that
    # discarded a project setting. Found the hard way: a
    # DRAUGR_AGENT_ARGS_CLAUDE written for the plugin seed disabled --continue
    # in every repo on the machine, and no command said so.
    printf 'DRAUGR_AGENT=claude\nDRAUGR_AGENT_ARGS=--continue\nDRAUGR_AGENT_ARGS_CLAUDE="--settings x"\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_AGENT_ARGS" = "--settings x" ]
    [ "$DR_AGENT_ARGS_REPLACED" = "--continue" ]
    [ "$DR_AGENT_ARGS_REPLACED_BY" = DRAUGR_AGENT_ARGS_CLAUDE ]
    [ -n "$DR_AGENT_ARGS_REPLACED_FROM" ]
}

@test "agent args: with no replacement, nothing is recorded as dropped" {
    # So that dr-doctor stays quiet in the ordinary case. A note on every run
    # would be noise, and the replacement is the documented rule.
    printf 'DRAUGR_AGENT=claude\nDRAUGR_AGENT_ARGS=--continue\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_AGENT_ARGS" = "--continue" ]
    [ -z "$DR_AGENT_ARGS_REPLACED_FROM" ]
    [ -z "$DR_AGENT_ARGS_REPLACED_BY" ]
}

@test "agent args: a per-agent key with no generic one is not a dropped value" {
    # The common case for the plugin seed on a fresh machine. There is nothing
    # to warn about, because nothing was thrown away.
    printf 'DRAUGR_AGENT=claude\nDRAUGR_AGENT_ARGS_CLAUDE="--settings x"\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_AGENT_ARGS" = "--settings x" ]
    [ -z "$DR_AGENT_ARGS_REPLACED" ]
}

@test "agent args: unset falls through, empty does not" {
    # Unset means "nothing to say about codex", so the generic value applies.
    printf 'DRAUGR_AGENT=codex\nDRAUGR_AGENT_ARGS=generic\n' > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_AGENT_ARGS" = generic ]

    # Empty means "nothing FOR codex". That is a decision, and it must win.
    # ${!k+set} exists for this difference. It is also why these keys have no
    # built-in default. With a default, nobody can tell the two apart.
    printf 'DRAUGR_AGENT=codex\nDRAUGR_AGENT_ARGS=generic\nDRAUGR_AGENT_ARGS_CODEX=\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ -z "$DRAUGR_AGENT_ARGS" ]
    [[ "${DR_ORIGIN[DRAUGR_AGENT_ARGS]}" == *"via DRAUGR_AGENT_ARGS_CODEX"* ]]
}

@test "agent args: the agent set by the PROJECT chooses the key" {
    # The purpose of the full feature. The user configuration cannot know which
    # agent is used, because it is sourced first. Thus the choice must happen
    # after all layers. A conditional in that file picks claude here.
    repo=$(dr_make_repo)
    printf 'DRAUGR_AGENT_ARGS_CLAUDE=--continue\nDRAUGR_AGENT_ARGS_CODEX=resume\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    printf 'DRAUGR_AGENT=codex\n' > "$repo/.draugr.conf"
    dr_trust_add "$repo/.draugr.conf"
    dr_load_config "$repo"
    [ "$DRAUGR_AGENT_ARGS" = resume ]
}

@test "agent args: an agent whose name has a hyphen gets a legal key name" {
    [ "$(dr_agent_args_key docker-agent)" = DRAUGR_AGENT_ARGS_DOCKER_AGENT ]
    [ "$(dr_agent_args_key claude)" = DRAUGR_AGENT_ARGS_CLAUDE ]

    printf 'DRAUGR_AGENT=docker-agent\nDRAUGR_AGENT_ARGS=generic\nDRAUGR_AGENT_ARGS_DOCKER_AGENT=x\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    dr_load_config
    [ "$DRAUGR_AGENT_ARGS" = x ]
}

@test "agent args: every agent Draugr knows has a registered key" {
    # dr-config lists DR_KEYS, and the environment override in dr_load_config
    # walks it. If an agent is missing from it, its key silently works only from
    # a configuration file.
    local a k
    for a in "${DR_AGENTS[@]}"; do
        k=$(dr_agent_args_key "$a")
        case " ${DR_KEYS[*]} " in
            *" $k "*) ;;
            *) printf 'not in DR_KEYS: %s\n' "$k" >&2; return 1 ;;
        esac
    done
}

@test "agent args: the environment beats a config file, as for any key" {
    printf 'DRAUGR_AGENT=claude\nDRAUGR_AGENT_ARGS_CLAUDE=--from-file\n' \
        > "$DRAUGR_CONFIG_HOME/config"
    DRAUGR_AGENT_ARGS_CLAUDE=--from-env dr_load_config
    [ "$DRAUGR_AGENT_ARGS" = "--from-env" ]
}
