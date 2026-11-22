#!/usr/bin/env bats
# dr-doctor: the report that answers "is this machine set up".
#
# These tests are about the shared skills store, and about the LEVEL of each
# line. The store is machine-wide: one directory, mounted into each mound of
# each project, for both agents, holding instructions that an agent loads and
# mostly trusts. Two facts about it belong in this report, and they are not the
# same kind of fact:
#
#   a change nobody reviewed     a warning. Every mound reads it
#   a shipped skill not installed  a NOTE. Draugr never installs them unasked
#
# The second one is why `note` exists. With `soft`, the verdict says
# "Ready, with 1 warning(s)" for ever on a machine whose owner declined an
# optional feature, and that teaches people to ignore the colour.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-$(basename "$REPO")"
    dr_fake_sbx_root          # sets DRAUGR_SBX and DR_SKILLS_DIR, both throwaway
}

teardown() { dr_test_teardown; }

# One skill in the store that Draugr did not ship, as `sbx skills import` or
# another agent leaves it.
foreign_skill() {
    mkdir -p "$DR_SKILLS_DIR/somebody-else"
    printf -- '---\nname: somebody-else\ndescription: not from Draugr\n---\n\nbody\n' \
        > "$DR_SKILLS_DIR/somebody-else/SKILL.md"
}

@test "dr-doctor: an empty store has nothing to review, and says so" {
    run dr-doctor
    [[ "$output" == *"skills store"* ]]
    [[ "$output" == *"empty"* ]]
    [[ "$output" != *"a change is not reviewed"* ]]
}

@test "dr-doctor: a change nobody reviewed is a warning, with both commands" {
    foreign_skill
    run dr-doctor
    [[ "$output" == *"a change is not reviewed"* ]]
    [[ "$output" == *"dr-skills diff"* ]]
    [[ "$output" == *"dr-skills accept"* ]]
    # The level: a warning, because every mound reads the store.
    [[ "$output" == *"! skills store"* ]]
}

@test "dr-doctor: once accepted, the store is a tick and not a warning" {
    foreign_skill
    dr-skills accept -y >/dev/null 2>&1
    run dr-doctor
    [[ "$output" == *"skills store"* ]]
    [[ "$output" == *"reviewed"* ]]
    [[ "$output" != *"a change is not reviewed"* ]]
}

@test "dr-doctor: a shipped skill that is missing is a note, never a warning" {
    run dr-doctor
    [[ "$output" == *"draugr skills"* ]]
    [[ "$output" == *"0 of"* ]]
    [[ "$output" == *"dr-skills install"* ]]
    # This is the whole reason for the third level. A warning here does not
    # go away for somebody who does not want the skills.
    [[ "$output" == *"· draugr skills"* ]]
    [[ "$output" != *"! draugr skills"* ]]
}

@test "dr-doctor --quiet: a note is not a problem, so it is hidden" {
    run dr-doctor --quiet
    [[ "$output" != *"draugr skills"* ]]
}

@test "dr-doctor: with every shipped skill installed, it stops advising" {
    dr-skills install -y >/dev/null 2>&1
    run dr-doctor
    [[ "$output" == *"draugr skills"* ]]
    [[ "$output" != *"dr-skills install"* ]]
    # install re-baselines the store, so that half is quiet too.
    [[ "$output" != *"a change is not reviewed"* ]]
}

@test "dr-doctor: the count follows what the checkout ships, not a fixed number" {
    # A skill added in a later version must show as missing, and not stay
    # invisible because somebody wrote the number in the code.
    local shipped=0 d
    for d in "$DR_ROOT"/share/skills/*/; do [ -d "$d" ] && shipped=$((shipped + 1)); done
    [ "$shipped" -gt 1 ]
    run dr-doctor
    [[ "$output" == *"0 of $shipped in the store"* ]]
}

# --- the trust file, which decides what Draugr will run ---------------------------------
#
# A line in it tells Draugr to SOURCE a .draugr.conf, and to source a file is to
# run it. So "who can write this file" is "who decides what Draugr runs". The
# mode that is supposed to answer that is inert on a Windows drive (measured -
# see the block in tests/config.bats), and the file is written so RARELY that a
# warning at dr-trust time is read once, months before it matters. Hence a
# standing row here.
#
# AND THE LEVEL IS A FAILURE, not a warning and not a note. The two softer
# levels exist for a change nobody reviewed and for a feature you declined; this
# is neither.

@test "dr-doctor: a private trust file is one green row" {
    printf 'deadbeef  /nowhere/.draugr.conf\n' > "$DRAUGR_CONFIG_HOME/trusted"
    chmod 600 "$DRAUGR_CONFIG_HOME/trusted"
    run dr-doctor
    [[ "$output" == *"Trusted state"* ]]
    [[ "$output" == *"private to you"* ]]
    [[ "$output" == *"1 line(s)"* ]]
}

@test "dr-doctor: a trust file that is not private is a failure" {
    printf 'deadbeef  /nowhere/.draugr.conf\n' > "$DRAUGR_CONFIG_HOME/trusted"
    chmod 644 "$DRAUGR_CONFIG_HOME/trusted"
    run dr-doctor
    [[ "$output" == *"644"* ]]
    [[ "$output" == *"SOURCE a .draugr.conf"* ]]
    # The red mark, and not the yellow one or the dot.
    [[ "$output" == *"✗ trust file"* ]]
}

# No trust file is the state of a fresh machine. Nothing is trusted, which is
# the safe end of the scale, so it counts nothing.
@test "dr-doctor: no trust file at all is a note, not a failure" {
    rm -f "$DRAUGR_CONFIG_HOME/trusted"
    run dr-doctor
    [[ "$output" == *"none yet"* ]]
    [[ "$output" != *"✗ trust file"* ]]
}

# dr-doctor REPORTS, and a chmod is a write. A command you run to look at the
# state may not alter the state it is showing you - which is why the question
# and the chmod are two functions.
@test "dr-doctor: reporting on the trust file does not change its mode" {
    printf 'deadbeef  /nowhere/.draugr.conf\n' > "$DRAUGR_CONFIG_HOME/trusted"
    chmod 644 "$DRAUGR_CONFIG_HOME/trusted"
    run dr-doctor
    [ "$(stat -c %a "$DRAUGR_CONFIG_HOME/trusted")" = 644 ]
}
