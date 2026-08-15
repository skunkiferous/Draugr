#!/usr/bin/env bats
# dr-skills: the one directory a sandbox can write to, treated as reviewable.
#
# No sandbox is needed. The store is an ordinary directory on the host, so these
# tests create one and check that appearances, edits and removals are all
# reported - which is the whole job, since nothing here judges content.

load helper

setup() {
    dr_test_setup
    dr_load_common
    dr_fake_sbx_root          # sets DRAUGR_SBX and DR_SKILLS_DIR
}

teardown() { dr_test_teardown; }

# A skill is a directory of instructions; only its name and contents matter here.
make_skill() {
    local name=$1 body=${2:-do the thing}
    mkdir -p "$DR_SKILLS_DIR/$name"
    printf '%s\n' "$body" > "$DR_SKILLS_DIR/$name/SKILL.md"
}

# --- list ---------------------------------------------------------------------

@test "dr-skills list: an empty store says so" {
    run dr-skills list
    [ "$status" -eq 0 ]
    [[ "$output" == *"empty"* ]]
}

@test "dr-skills list: names what is in the store" {
    make_skill deploy
    make_skill review
    run dr-skills list
    [ "$status" -eq 0 ]
    [[ "$output" == *"deploy"* ]]
    [[ "$output" == *"review"* ]]
}

@test "dr-skills list: states the reach of the store, every time" {
    run dr-skills list
    # The reason this command exists: read-write, shared, and outlives the mound.
    [[ "$output" == *"read-write into every mound"* ]]
    [[ "$output" == *"survives dr-rm"* ]]
}

# --- diff ---------------------------------------------------------------------

@test "dr-skills diff: never accepted is not the same as unchanged" {
    make_skill deploy
    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"never accepted"* ]]
    [[ "$output" == *"deploy"* ]]
}

@test "dr-skills diff: an empty store with no baseline is quiet" {
    run dr-skills diff
    [ "$status" -eq 0 ]
}

@test "dr-skills accept: makes diff quiet" {
    make_skill deploy
    dr-skills accept >/dev/null 2>&1
    run dr-skills diff
    [ "$status" -eq 0 ]
    [[ "$output" == *"as you last accepted"* ]]
}

@test "dr-skills diff: a skill that appeared since is reported as new" {
    make_skill deploy
    dr-skills accept >/dev/null 2>&1

    # The case that matters: a sandbox left something behind for the next one.
    make_skill exfiltrate
    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"new:"*"exfiltrate"* ]]
    [[ "$output" != *"new:"*"deploy"* ]]
}

@test "dr-skills diff: an edit inside an accepted skill is a change" {
    make_skill deploy "the original instructions"
    dr-skills accept >/dev/null 2>&1

    # Same name, different content - which a listing of names would miss.
    printf 'something else entirely\n' > "$DR_SKILLS_DIR/deploy/SKILL.md"
    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed:"*"deploy"* ]]
}

@test "dr-skills diff: a new file inside an accepted skill is a change" {
    make_skill deploy
    dr-skills accept >/dev/null 2>&1

    printf 'extra\n' > "$DR_SKILLS_DIR/deploy/EXTRA.md"
    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed:"*"deploy"* ]]
}

@test "dr-skills diff: a skill that disappeared is reported too" {
    make_skill deploy
    dr-skills accept >/dev/null 2>&1
    rm -rf "$DR_SKILLS_DIR/deploy"

    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"gone:"*"deploy"* ]]
}

@test "dr-skills accept: records the state, not just the names" {
    make_skill deploy "first"
    dr-skills accept >/dev/null 2>&1
    printf 'second\n' > "$DR_SKILLS_DIR/deploy/SKILL.md"
    dr-skills accept >/dev/null 2>&1

    run dr-skills diff
    [ "$status" -eq 0 ]
}

# --- import -------------------------------------------------------------------

@test "dr-skills import: says what it means before doing it" {
    # No terminal and no --yes, so the confirmation refuses rather than assuming.
    run dr-skills import
    [ "$status" -ne 0 ]
    [[ "$output" == *"instructions"* ]]
    [[ "$output" == *"every mound"* ]]
}

@test "dr-skills import: hands the flags to sbx" {
    run dr-skills import --dry-run -y
    [ "$status" -eq 0 ]
    grep -q "skills import --dry-run" "$DR_MOCK_LOG"
}

@test "dr-skills import: a dry run does not re-baseline" {
    make_skill deploy
    dr-skills accept >/dev/null 2>&1
    make_skill appeared

    # --dry-run copies nothing, so the skill that appeared must still be news.
    dr-skills import --dry-run -y >/dev/null 2>&1
    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"appeared"* ]]
}
