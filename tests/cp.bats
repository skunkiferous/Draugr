#!/usr/bin/env bats
# dr-cp: the two paths it hands to sbx, and the flag it used not to have.
#
# sbx.exe is a Windows binary that WSL runs over interop, so the HOST side of a
# copy has to be spelled the way Windows spells it. It was not, and an absolute
# destination therefore reached sbx as a path nobody typed:
#
#   ERROR: extract to /mnt/c/Code/x: GetFileAttributesEx \mnt\c\Code: The system
#          cannot find the path specified.
#
# Nothing caught it because tests/mocks/sbx accepts both spellings - it has to,
# since it also stands in for the mound side. So these assert on the argv Draugr
# BUILT rather than on whether the mock was happy with it.
#
# The second half pins the spelling that must NOT be translated. A relative
# destination is already resolved by interop against the Windows working
# directory, which is why `dr-cp out.log .` in the README has always worked, and
# translating it would fix an unusable spelling by breaking the documented one.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# A repo on a Windows drive with a mound that exists. dr-cp calls dr_context and
# dr_sandbox_exists, so neither is optional.
#
# DR_MOCK_MOUND is deliberately left UNSET: with it, the mock stops recording and
# performs a real copy, which is the wrong instrument for asserting on argv. One
# test at the end sets it, to check the arguments still describe a copy that
# works rather than one that merely looks right.
setup_mound() {
    REPO=$(dr_make_win_repo) || return 1
    cd "$REPO" || return 1
    export DR_MOCK_STATE=running
    return 0
}

# The argv of the last cp the mock saw, space joined as the mock records it.
cp_line() { grep '^cp ' "$DR_MOCK_LOG" | tail -1; }

# --- the host side, translated -----------------------------------------------

@test "dr-cp: an absolute host destination is spelled the Windows way" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw /home/agent/seed "$REPO"
    [ "$status" -eq 0 ]

    want=$(dr_path_win "$REPO")
    [[ "$(cp_line)" == *"$want"* ]]
    # The bug, stated as a test: the WSL spelling must not survive into the argv.
    [[ "$(cp_line)" != *"$REPO"* ]]
}

@test "dr-cp: --to spells the host SOURCE the Windows way too" {
    setup_mound || skip "no writable Windows drive path"
    printf 'notes\n' > "$REPO/notes.md"

    run dr-cp --to "$REPO/notes.md" docs/
    [ "$status" -eq 0 ]

    want=$(dr_path_win "$REPO/notes.md")
    [[ "$(cp_line)" == *"$want"* ]]
    [[ "$(cp_line)" != *"$REPO/notes.md"* ]]
}

@test "dr-cp: a relative destination is passed through untouched" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw /home/agent/seed .
    [ "$status" -eq 0 ]

    # Ends with a bare dot, and nothing was turned into a drive letter. This is
    # the spelling the README documents; it must survive the translation above.
    [[ "$(cp_line)" == *" ." ]]
    [[ "$(cp_line)" != *':\'* ]]
}

@test "dr-cp: a host path off the Windows drives is refused, by name" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw /home/agent/seed /home/nobody/out
    [ "$status" -ne 0 ]
    [[ "$output" == *"not on a Windows drive"* ]]
    # The path as typed, so the message is about something the reader wrote.
    [[ "$output" == *"/home/nobody/out"* ]]
    # Refused before sbx was troubled with it.
    [ -z "$(cp_line)" ]
}

@test "dr-cp: a missing host source is still reported as typed, not translated" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --to "$REPO/absent.md" docs/
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such file on the host"* ]]
    [[ "$output" == *"$REPO/absent.md"* ]]
}

# --- -L, which sbx has and dr-cp did not -------------------------------------

@test "dr-cp: -L reaches sbx" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp -L --raw /home/agent/seed .
    [ "$status" -eq 0 ]
    [[ "$(cp_line)" == "cp -L "* ]]
}

@test "dr-cp: -L is absent unless asked for" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw /home/agent/seed .
    [ "$status" -eq 0 ]
    # Dereferencing silently would turn every symlink into a copy of its target,
    # which is a change to what came out of the mound. It stays opt-in.
    [[ "$(cp_line)" != *" -L "* ]]
}

@test "dr-cp: --follow-link is the same flag" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --follow-link --raw /home/agent/seed .
    [ "$status" -eq 0 ]
    [[ "$(cp_line)" == "cp -L "* ]]
}

# --- the mound side, which was already right and must stay so ----------------

@test "dr-cp: a bare mound path resolves against the clone" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp out.log .
    [ "$status" -eq 0 ]
    [[ "$(cp_line)" == *"$(dr_path_mound "$REPO")/out.log"* ]]
}

@test "dr-cp: --raw takes the mound path literally" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw out.log .
    [ "$status" -eq 0 ]
    [[ "$(cp_line)" == *":out.log "* ]]
    [[ "$(cp_line)" != *"$(dr_path_mound "$REPO")"* ]]
}

# --- what the failure says ---------------------------------------------------

@test "dr-cp: a failed copy names both causes, not just the wrong one" {
    setup_mound || skip "no writable Windows drive path"
    export DR_MOCK_FAIL=cp

    run dr-cp --raw /home/agent/seed .
    [ "$status" -ne 0 ]
    # Both real failures used to arrive under "check the path exists on the
    # source side", which was wrong in each case - the path existed both times.
    [[ "$output" == *"privilege"* ]]
    [[ "$output" == *"dr-cp -L"* ]]
    [[ "$output" == *"not found in container"* ]]
}

# --- and one that actually moves a file --------------------------------------

@test "dr-cp: the argv it builds describes a copy that works" {
    setup_mound || skip "no writable Windows drive path"

    # With DR_MOCK_MOUND the mock stops recording and does the copy for real,
    # translating the Windows spelling back independently of dr_path_win. So a
    # wrong translation fails here rather than producing two matching bugs.
    dr_mound_memory_dir "$REPO"
    mkdir -p "$DR_MOCK_MOUND/home/agent"
    printf 'from the mound\n' > "$DR_MOCK_MOUND/home/agent/out.log"

    run dr-cp --raw /home/agent/out.log "$REPO"
    [ "$status" -eq 0 ]
    [ -f "$REPO/out.log" ]
    [ "$(cat "$REPO/out.log")" = "from the mound" ]
}

# --- copying IN, and who ends up owning it -----------------------------------

# sbx cp writes into the mound as root:root while the agent is uid 1000, so
# dr-cp chowns after every --to. That chown ran as the AGENT, who cannot chown a
# root-owned tree, so it failed every time and surfaced as the warning meant for
# the rare case - leaving exactly the unwritable tree it exists to prevent:
#
#   dr-cp: copied, but could not chown /home/agent/rehydrate to the agent
#   drwxr-xr-x 4 root root  /home/agent/rehydrate/seed
#
# -u root is the whole fix, and its POSITION is half of it: sbx takes exec flags
# before the sandbox name, so a later edit moving it after would be accepted by
# the shell and ignored by sbx.
@test "dr-cp: --to chowns the result to the agent, as root" {
    setup_mound || skip "no writable Windows drive path"
    printf 'notes\n' > "$REPO/notes.md"

    run dr-cp --to "$REPO/notes.md" /home/agent/notes.md
    [ "$status" -eq 0 ]

    line=$(grep '^exec ' "$DR_MOCK_LOG" | tail -1)
    [[ "$line" == *"chown -R 1000:1000 /home/agent/notes.md"* ]]
    [[ "$line" == "exec -u root "* ]]
}

# The other direction owns nothing inside the mound, so it must not reach for
# root - sbx cp writes the host side as whoever ran dr-cp, and that is right.
@test "dr-cp: a copy OUT of the mound chowns nothing" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw /home/agent/seed .
    [ "$status" -eq 0 ]
    ! grep -q '^exec ' "$DR_MOCK_LOG"
}
