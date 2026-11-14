#!/usr/bin/env bats
# dr-skills: the one directory that a sandbox can write to, open to review.
#
# No sandbox is necessary. The store is a normal directory on the host. Thus
# these tests create one, and make sure that new, edited and removed entries are
# all reported. That is the full job, because nothing here judges content.

load helper

setup() {
    dr_test_setup
    dr_load_common
    dr_fake_sbx_root          # sets DRAUGR_SBX and DR_SKILLS_DIR
}

teardown() { dr_test_teardown; }

# A skill is a directory of instructions. Here, only its name and contents
# matter.
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

@test "dr-skills list: a hidden skill directory is not a hiding place" {
    # A test showed this. Claude Code lists a store entry named .hidden-probe in
    # its available skills. Thus a directory that starts with a dot is a live
    # instruction, and must be reported. Codex writes one, .system, on its first
    # run.
    make_skill .system
    run dr-skills list
    [ "$status" -eq 0 ]
    [[ "$output" == *".system"* ]]
    [[ "$output" != *"empty"* ]]
}

@test "dr-skills diff: a hidden skill that appeared is reported as new" {
    make_skill deploy
    dr-skills accept >/dev/null 2>&1

    make_skill .system
    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"new:"*".system"* ]]
}

@test "dr-skills list: states the reach of the store, every time" {
    run dr-skills list
    # The reason for this command: shared, writable from an older mound, and
    # lives longer than the mound.
    [[ "$output" == *"all mounds share it"* ]]
    [[ "$output" == *"read-only; one that an older sbx built mounts it read-write"* ]]
    [[ "$output" == *"stays after dr-rm"* ]]
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
    [[ "$output" == *"the same as at your last accept"* ]]
}

@test "dr-skills diff: a skill that appeared since is reported as new" {
    make_skill deploy
    dr-skills accept >/dev/null 2>&1

    # The important case: a sandbox left something for the next one.
    make_skill exfiltrate
    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"new:"*"exfiltrate"* ]]
    [[ "$output" != *"new:"*"deploy"* ]]
}

@test "dr-skills diff: an edit inside an accepted skill is a change" {
    make_skill deploy "the original instructions"
    dr-skills accept >/dev/null 2>&1

    # Same name, different content. A list of names misses that.
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
    # No terminal and no --yes, so the confirmation refuses, and does not guess.
    run dr-skills import
    [ "$status" -ne 0 ]
    [[ "$output" == *"instructions"* ]]
    [[ "$output" == *"each mound"* ]]
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

    # --dry-run copies nothing, so the new skill must still show as new.
    dr-skills import --dry-run -y >/dev/null 2>&1
    run dr-skills diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"appeared"* ]]
}

# --- install ------------------------------------------------------------------
#
# The own skills of Draugr. `sbx skills import` cannot place them, because it
# scans five fixed host directories and takes no path. Thus this copies into the
# store directly. You must type the verb, for the same reason as for import.

@test "dr-skills install: says what it is about to put in reach of every mound" {
    run dr-skills install
    [ "$status" -ne 0 ]          # no terminal, no --yes: the confirmation refuses
    [[ "$output" == *"shared store"* ]]
    [[ "$output" == *"draugr-kit"* ]]
}

@test "dr-skills install: copies the shipped skill into the store" {
    run dr-skills install -y
    [ "$status" -eq 0 ]
    [ -f "$DR_SKILLS_DIR/draugr-kit/SKILL.md" ]
}

@test "dr-skills install: re-baselines, so diff is about the NEXT change" {
    dr-skills install -y >/dev/null 2>&1
    run dr-skills diff
    [ "$status" -eq 0 ]
}

@test "dr-skills install: replaces rather than merges" {
    # A file removed in a newer version must not stay. sbx applies that rule on
    # import. That is why this is rm -rf then cp, not cp -a on top.
    dr-skills install -y >/dev/null 2>&1
    printf 'stale\n' > "$DR_SKILLS_DIR/draugr-kit/LEFTOVER.md"
    dr-skills install -y >/dev/null 2>&1
    [ ! -f "$DR_SKILLS_DIR/draugr-kit/LEFTOVER.md" ]
}

@test "dr-skills install: the shipped skill is loadable by both agents" {
    # One SKILL.md works for Claude and Codex. A test showed that both list a
    # store skill by name. But they need the frontmatter to read.
    run head -4 "$DR_ROOT/share/skills/draugr-kit/SKILL.md"
    [[ "${lines[0]}" = "---" ]]
    [[ "$output" == *"name: draugr-kit"* ]]
    [[ "$output" == *"description:"* ]]
}

# --- the shipped set, not one skill by name ----------------------------------
#
# Draugr ships several skills now. A test that names only one of them passes
# while a new skill has no frontmatter at all, and an agent then ignores it with
# no message. These two cover the set, whatever it holds.

@test "share/skills: each shipped skill has frontmatter that names its directory" {
    local d name bad=0
    for d in "$DR_ROOT"/share/skills/*/; do
        name=${d%/}; name=${name##*/}
        if [ ! -f "$d/SKILL.md" ]; then
            printf 'no SKILL.md in %s\n' "$name"
            bad=1
            continue
        fi
        # The first line must open the frontmatter, and the name must be the
        # directory: that is how both agents find a skill in the store.
        if [ "$(head -1 "$d/SKILL.md")" != "---" ]; then
            printf '%s does not open with ---\n' "$name"
            bad=1
        fi
        if ! head -6 "$d/SKILL.md" | grep -q "^name: $name\$"; then
            printf '%s has no matching name: line\n' "$name"
            bad=1
        fi
        if ! head -6 "$d/SKILL.md" | grep -q '^description: '; then
            printf '%s has no description\n' "$name"
            bad=1
        fi
    done
    [ "$bad" -eq 0 ]
}

@test "dr-skills install: names every shipped skill before the question" {
    local d name count=0
    for d in "$DR_ROOT"/share/skills/*/; do count=$((count + 1)); done
    [ "$count" -gt 1 ]            # the test is worthless with only one

    run dr-skills install
    [ "$status" -ne 0 ]           # no terminal and no --yes: it must refuse
    # Each name, so the operator reads the whole list before they accept it.
    for d in "$DR_ROOT"/share/skills/*/; do
        name=${d%/}; name=${name##*/}
        [[ "$output" == *"$name"* ]]
    done
    [[ "$output" == *"$count skill(s)"* ]]
}

# --- the skills your plugins ship ---------------------------------------------
#
# The skills of a plugin load from the plugin, never from this store. Thus they
# never show in the section above. Without this section, dr-skills reported one
# skill on a machine whose plugin library held fifteen.

# A plugin library with one installed plugin that has one skill. NOT on a
# Windows drive, on purpose. dr-skills only reads the directory. It never mounts
# it, as dr-plugin does.
fake_plugin_lib() {
    local dir
    export DRAUGR_PLUGIN_STORE="$DR_TMP/plugins"
    dir="$DRAUGR_PLUGIN_STORE/seed/cache/mkt-a/plug-a/1.0.0/skills/writing-plans"
    mkdir -p "$dir"
    printf -- '---\nname: writing-plans\n---\n' > "$dir/SKILL.md"
    printf '{"version": 2, "plugins": {"plug-a@mkt-a": [{"version": "1.0.0"}]}}\n' \
        > "$DRAUGR_PLUGIN_STORE/seed/installed_plugins.json"
}

@test "dr-skills list: names the skills your plugins ship, under their own heading" {
    fake_plugin_lib
    run dr-skills list
    [ "$status" -eq 0 ]
    [[ "$output" == *"also in plugins that you already have"* ]]
    [[ "$output" == *"writing-plans"* ]]
    # The plugin also, because its install makes the skill available.
    [[ "$output" == *"plug-a@mkt-a"* ]]

    # The condition is the full purpose. These are not available as a store
    # entry is. A claim that they are misleads in the other direction.
    [[ "$output" == *"INSTALLED in that mound"* ]]
}

@test "dr-skills list: a plugin's skill is not counted as being in the store" {
    fake_plugin_lib
    make_skill deploy
    run dr-skills list
    [ "$status" -eq 0 ]
    [[ "$output" == *"deploy"* ]]
    # Once, under the plugin heading, not also in the own contents of the store.
    [ "$(printf '%s\n' "$output" | grep -c 'writing-plans')" -eq 1 ]
}

@test "dr-skills list: reads the library named in your config, not just the environment" {
    fake_plugin_lib
    # THE REAL FAILURE for this guard. The two tests above cannot see it,
    # because they export the variable. DRAUGR_PLUGIN_STORE is usually in a
    # configuration FILE. dr-skills loads no repository. Without a load of the
    # machine configuration, it used built-in defaults. The store read as
    # empty, and the section never showed, for any number of plugin skills.
    printf 'DRAUGR_PLUGIN_STORE="%s"\n' "$DRAUGR_PLUGIN_STORE" \
        > "$DRAUGR_CONFIG_HOME/config"
    unset DRAUGR_PLUGIN_STORE

    run dr-skills list
    [ "$status" -eq 0 ]
    [[ "$output" == *"also in plugins that you already have"* ]]
    [[ "$output" == *"writing-plans"* ]]
}

@test "dr-skills list: silent about plugins when no library is configured" {
    unset DRAUGR_PLUGIN_STORE
    make_skill deploy
    run dr-skills list
    [ "$status" -eq 0 ]
    [[ "$output" == *"deploy"* ]]

    # An empty heading on a machine with no library is worse than no heading.
    # Mutation testing showed this: dr-skills guards this TWICE, and one guard
    # is enough. Thus this fails only when both are removed, never when one is.
    # Know this before you "simplify" either of them.
    [[ "$output" != *"also shipped by plugins"* ]]
}
