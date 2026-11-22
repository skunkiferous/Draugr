#!/usr/bin/env bats
# dr-cp: the two paths that it gives to sbx, and the flag that it did not have.
#
# sbx.exe is a Windows binary that WSL runs over interop. Thus the HOST side of
# a copy must use the Windows spelling. It did not, and thus an absolute
# destination reached sbx as a path that nobody typed:
#
#   ERROR: extract to /mnt/c/Code/x: GetFileAttributesEx \mnt\c\Code: The system
#          cannot find the path specified.
#
# No test caught it, because tests/mocks/sbx accepts both spellings. It must,
# because it also acts as the mound side. Thus these tests assert on the argv
# that Draugr BUILT, not on whether the mock accepted it.
#
# The second half pins the spelling that must NOT be translated. Interop already
# resolves a relative destination against the Windows working directory. That is
# why `dr-cp out.log .` in the README always worked. A translation of it fixes
# an unusable spelling, but breaks the documented one.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# A repo on a Windows drive, with a mound that exists. dr-cp calls dr_context
# and dr_sandbox_exists, so both are necessary.
#
# DR_MOCK_MOUND stays UNSET, on purpose. With it, the mock stops its record and
# does a real copy. That is the wrong tool for an assertion on argv. One test at
# the end sets it. It makes sure that the arguments still describe a copy that
# works, not only one that looks right.
setup_mound() {
    REPO=$(dr_make_win_repo) || return 1
    cd "$REPO" || return 1
    export DR_MOCK_STATE=running
    return 0
}

# The argv of the last cp that the mock saw, joined with spaces, as the mock
# records it.
cp_line() { grep '^cp ' "$DR_MOCK_LOG" | tail -1; }

# --- the host side, translated -----------------------------------------------

@test "dr-cp: an absolute host destination is spelled the Windows way" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw /home/agent/seed "$REPO"
    [ "$status" -eq 0 ]

    want=$(dr_path_win "$REPO")
    [[ "$(cp_line)" == *"$want"* ]]
    # The bug, as a test: the WSL spelling must not stay in the argv.
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

    # Ends with a bare dot, and nothing became a drive letter. The README
    # documents this spelling. It must stay after the translation above.
    [[ "$(cp_line)" == *" ." ]]
    [[ "$(cp_line)" != *':\'* ]]
}

@test "dr-cp: a host path off the Windows drives is refused, by name" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw /home/agent/seed /home/nobody/out
    [ "$status" -ne 0 ]
    [[ "$output" == *"not on a Windows drive"* ]]
    # The path as typed, so that the message is about what the reader wrote.
    [[ "$output" == *"/home/nobody/out"* ]]
    # Refused before it reached sbx.
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
    # A silent dereference makes each symlink a copy of its target. That changes
    # what came out of the mound. It stays opt-in.
    [[ "$(cp_line)" != *" -L "* ]]
}

@test "dr-cp: --follow-link is the same flag" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --follow-link --raw /home/agent/seed .
    [ "$status" -eq 0 ]
    [[ "$(cp_line)" == "cp -L "* ]]
}

# --- the mound side, which was already correct, and must stay so ------------

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
    # Before, both real failures came with "check the path exists on the source
    # side". That was wrong in each case, because the path existed both times.
    [[ "$output" == *"privilege"* ]]
    [[ "$output" == *"not found in container"* ]]
    # And it says what that failure LEAVES: measured on sbx 0.53.0, extraction
    # out of a mound stops at the link after writing part of the tree, and
    # which part is not predictable.
    [[ "$output" == *"PART of the tree is on your disk"* ]]
    # It no longer offers -L as the way out. Measured: on a tree that holds a
    # link, -L out of a mound answers 500 and copies nothing at all.
    [[ "$output" != *"-L does help"* ]]
    [[ "$output" == *"-L does not help"* ]]
}

# --- and one that really moves a file ----------------------------------------

@test "dr-cp: the argv it builds describes a copy that works" {
    setup_mound || skip "no writable Windows drive path"

    # With DR_MOCK_MOUND, the mock stops its record, and does the real copy. It
    # translates the Windows spelling back, independently of dr_path_win. Thus a
    # wrong translation fails here, and does not make two matching bugs.
    dr_mound_memory_dir "$REPO"
    mkdir -p "$DR_MOCK_MOUND/home/agent"
    printf 'from the mound\n' > "$DR_MOCK_MOUND/home/agent/out.log"

    run dr-cp --raw /home/agent/out.log "$REPO"
    [ "$status" -eq 0 ]
    [ -f "$REPO/out.log" ]
    [ "$(cat "$REPO/out.log")" = "from the mound" ]
}

# --- a copy IN, and who owns the result -------------------------------------

# sbx cp writes into the mound as root:root, but the agent is uid 1000. Thus
# dr-cp runs chown after each --to. That chown ran as the AGENT, who cannot
# chown a tree that root owns. Thus it always failed, and showed the warning for
# the rare case. It left the unwritable tree that it must prevent:
#
#   dr-cp: copied, but could not chown /home/agent/rehydrate to the agent
#   drwxr-xr-x 4 root root  /home/agent/rehydrate/seed
#
# -u root is the full fix, and its POSITION is half of it. sbx takes exec flags
# before the sandbox name. If a later edit moves it after the name, the shell
# accepts it, and sbx ignores it.
@test "dr-cp: --to chowns the result to the agent, as root" {
    setup_mound || skip "no writable Windows drive path"
    printf 'notes\n' > "$REPO/notes.md"

    run dr-cp --to "$REPO/notes.md" /home/agent/notes.md
    [ "$status" -eq 0 ]

    line=$(grep '^exec ' "$DR_MOCK_LOG" | tail -1)
    [[ "$line" == *"chown -R 1000:1000 /home/agent/notes.md"* ]]
    [[ "$line" == "exec -u root "* ]]
}

# The other direction owns nothing in the mound, so it must not use root. sbx
# cp writes the host side as the user who ran dr-cp, and that is correct.
@test "dr-cp: a copy OUT of the mound chowns nothing" {
    setup_mound || skip "no writable Windows drive path"

    run dr-cp --raw /home/agent/seed .
    [ "$status" -eq 0 ]
    # Not "no exec at all" any more: a copy OUT asks the mound whether the tree
    # holds a link, because such a copy FAILS after writing part of the tree
    # here. What must not happen is a chown.
    ! grep -q 'chown' "$DR_MOCK_LOG" || return 1
    grep -q '^exec .*-type l' "$DR_MOCK_LOG"
}

# --- the copy that leaves a link out, measured on sbx 0.53.0 ----------------
#
# Measured in a disposable sandbox, with the link first in the walk, last in
# the walk, and inside a subdirectory: a copy INTO the mound leaves the link
# out, every other file arrives, and sbx exits 0. Out of the mound the same
# tree FAILS with status 1 after writing an unpredictable part of it. So the
# moment to say something is before the copy, and the two directions need
# different sentences. These tests hold the host-tree half, where Draugr can
# see the links itself without asking anybody.

@test "dr-cp --to: a link in the host tree is named before the copy" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$REPO/tree"
    printf 'real
' > "$REPO/tree/a.txt"
    ln -s a.txt "$REPO/tree/b.txt"

    run dr-cp --to tree/ /tmp/dest
    [ "$status" -eq 0 ]
    [[ "$output" == *"holds a link"* ]]
    # Measured on sbx 0.53.0, in a disposable sandbox, with the link first in
    # the walk, last in the walk and inside a subdirectory: the link is left
    # out and EVERY other file arrives, and sbx exits 0. The old text said the
    # copy stops at the link and drops everything after it, which is what the
    # OTHER direction does - where the status is 1, not 0.
    [[ "$output" == *"leaves it out of the copy"* ]]
    [[ "$output" == *"Everything else arrives"* ]]
    [[ "$output" == *"-L does not help"* ]]
}

@test "dr-cp --to: a tree with no link says nothing about links" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$REPO/tree"
    printf 'real
' > "$REPO/tree/a.txt"

    run dr-cp --to tree/ /tmp/dest
    [ "$status" -eq 0 ]
    [[ "$output" != *"holds a link"* ]]
}

# --- --verify: the two sides, compared --------------------------------------
#
# Measured on sbx 0.53.0: a copy INTO the mound leaves a link out, keeps every
# other file, and exits 0. The only trace is a line on stderr that dr-cp does
# not read. --verify is Draugr asking both sides instead, and it is a flag
# rather than the default because two listings are two more conversations with
# the mound.
#
# These tests set DR_MOCK_MOUND, because a comparison of two trees needs two
# trees. The argv tests above leave it unset on purpose.
setup_real_mound() {
    setup_mound || return 1
    dr_mound_memory_dir "$REPO"          # sets DR_MOCK_MOUND
    mkdir -p "$DR_MOCK_MOUND/tmp"
    return 0
}

@test "dr-cp --verify: a complete copy into the mound says so" {
    setup_real_mound || skip "no writable Windows drive path"
    mkdir -p "$REPO/tree/sub"
    printf 'a\n' > "$REPO/tree/a.txt"
    printf 's\n' > "$REPO/tree/sub/s.txt"

    run dr-cp --to --verify tree /tmp/dest
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified: 3 entr(ies) on both sides"* ]]
}

@test "dr-cp --verify: an entry that did not arrive is named, and fails" {
    setup_real_mound || skip "no writable Windows drive path"
    mkdir -p "$REPO/tree"
    printf 'a\n' > "$REPO/tree/a.txt"
    printf 'b\n' > "$REPO/tree/b.txt"

    # The mock copies a link without trouble, so a link is the wrong way to
    # reproduce what sbx does with one. DR_MOCK_CP_TRUNCATE is: a copy that
    # exits 0 with one entry missing.
    DR_MOCK_CP_TRUNCATE=b.txt run dr-cp --to --verify tree /tmp/dest
    [ "$status" -ne 0 ]
    [[ "$output" == *"the copy is incomplete"* ]]
    [[ "$output" == *"missing"* ]]
    [[ "$output" == *"b.txt"* ]]
    # The entry that DID arrive is still there, and the message says so.
    # /tmp/dest did not exist, so the copy BECOMES /tmp/dest - measured, and
    # the rule the --verify code resolves the destination with.
    [ -f "$DR_MOCK_MOUND/tmp/dest/a.txt" ]
    [[ "$output" == *"did arrive ARE at the destination"* ]]
}

@test "dr-cp --verify: an entry nobody asked for is named too" {
    setup_real_mound || skip "no writable Windows drive path"
    mkdir -p "$REPO/tree"
    printf 'a\n' > "$REPO/tree/a.txt"

    DR_MOCK_CP_PLANT=surprise run dr-cp --to --verify tree /tmp/dest
    [ "$status" -ne 0 ]
    [[ "$output" == *"extra"* ]]
    [[ "$output" == *"surprise"* ]]
}

@test "dr-cp --verify: a copy OUT of the mound is compared the same way" {
    setup_real_mound || skip "no writable Windows drive path"
    mkdir -p "$DR_MOCK_MOUND/home/agent/out/sub"
    printf 'o\n' > "$DR_MOCK_MOUND/home/agent/out/a.log"
    printf 'd\n' > "$DR_MOCK_MOUND/home/agent/out/sub/b.log"
    mkdir -p "$REPO/landing"

    run dr-cp --raw --verify /home/agent/out "$REPO/landing"
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified: 3 entr(ies) on both sides"* ]]
    [ -f "$REPO/landing/out/a.log" ]
    [ -f "$REPO/landing/out/sub/b.log" ]
}

@test "dr-cp --verify: an incomplete copy OUT of the mound fails too" {
    setup_real_mound || skip "no writable Windows drive path"
    mkdir -p "$DR_MOCK_MOUND/home/agent/out"
    printf 'o\n' > "$DR_MOCK_MOUND/home/agent/out/a.log"
    printf 'g\n' > "$DR_MOCK_MOUND/home/agent/out/gone.log"
    mkdir -p "$REPO/landing"

    DR_MOCK_CP_TRUNCATE=gone.log run dr-cp --raw --verify /home/agent/out "$REPO/landing"
    [ "$status" -ne 0 ]
    [[ "$output" == *"the copy is incomplete"* ]]
    [[ "$output" == *"gone.log"* ]]
}

@test "dr-cp: without --verify neither side is listed" {
    # The default path must not pay for the flag. Two listings are two `exec`
    # calls, and this asserts that they do not happen.
    setup_real_mound || skip "no writable Windows drive path"
    mkdir -p "$REPO/tree"
    printf 'a\n' > "$REPO/tree/a.txt"

    # -mindepth, because the listing script reaches the mock's log as several
    # lines: only its first one starts with "exec", and "find" is on a later
    # one. Nothing else in dr-cp uses that flag.
    run dr-cp --to tree /tmp/dest
    [ "$status" -eq 0 ]
    [ "$(grep -c mindepth "$DR_MOCK_LOG" || true)" -eq 0 ]

    : > "$DR_MOCK_LOG"
    run dr-cp --to --verify tree /tmp/dest2
    [ "$status" -eq 0 ]
    [ "$(grep -c mindepth "$DR_MOCK_LOG" || true)" -ge 1 ]
}

# --- and the other direction's warning, which it never had ------------------
#
# Out of the mound a link does not make a partial copy, it makes a FAILED copy
# with part of the tree already on the host. Draugr cannot see that tree from
# here, so it asks - and the answer is a WORD. Any output read as "there is a
# link" would turn an unreachable mound, or a find that printed a diagnostic,
# into a warning about something nobody saw.
@test "dr-cp: a link in the MOUND tree is named before the copy out" {
    setup_real_mound || skip "no writable Windows drive path"
    mkdir -p "$DR_MOCK_MOUND/home/agent/seed"
    printf 'real\n' > "$DR_MOCK_MOUND/home/agent/seed/a.txt"
    ln -s a.txt "$DR_MOCK_MOUND/home/agent/seed/b.txt"
    mkdir -p "$REPO/landing"

    run dr-cp --raw /home/agent/seed "$REPO/landing"
    [[ "$output" == *"holds a link, and Windows will not create it"* ]]
    [[ "$output" == *"PART of the tree here"* ]]
    [[ "$output" == *"500"* ]]
}

@test "dr-cp: a mound tree with no link says nothing about links" {
    setup_real_mound || skip "no writable Windows drive path"
    mkdir -p "$DR_MOCK_MOUND/home/agent/seed"
    printf 'real\n' > "$DR_MOCK_MOUND/home/agent/seed/a.txt"
    mkdir -p "$REPO/landing"

    run dr-cp --raw /home/agent/seed "$REPO/landing"
    [ "$status" -eq 0 ]
    [[ "$output" != *"holds a link"* ]]
}
