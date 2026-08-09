#!/usr/bin/env bats
# Config layering, provenance and trust-on-first-use.

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
    # deliberately not trusted
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
