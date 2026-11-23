#!/usr/bin/env bats
# The shared receive path: the four questions every channel asks before bytes
# that came out of a mound are allowed to stay on this host.
#
# Hardening 1 of the security review asks for one quarantine shared by the data
# pull, the memory export and the Codex plugin build. Draugr shares every step
# that DECIDES, and leaves each channel its own transfer, so these tests are
# about the decisions and need no mound, no sbx and no network.

load helper

setup()    { dr_test_setup; dr_load_common; }
teardown() { dr_test_teardown; }

# A tree with `n` files of `size` bytes each, at $DR_TMP/<name>.
mktree() {
    local name=$1 n=$2 size=$3 i
    mkdir -p "$DR_TMP/$name/sub"
    for i in $(seq 1 "$n"); do
        head -c "$size" /dev/zero > "$DR_TMP/$name/sub/f$i"
    done
    printf '%s' "$DR_TMP/$name"
}

# --- dr_size_bytes ----------------------------------------------------------

@test "dr_size_bytes: a bare number is bytes" {
    run dr_size_bytes 262144
    [ "$status" -eq 0 ]
    [ "$output" = 262144 ]
}

# One test for the four suffixes, because a missing multiplier is the same bug
# four times and a reader wants to see the table.
@test "dr_size_bytes: K, M, G and T multiply, in either case" {
    [ "$(dr_size_bytes 1K)" = 1024 ]
    [ "$(dr_size_bytes 1m)" = 1048576 ]
    [ "$(dr_size_bytes 8G)" = 8589934592 ]
    [ "$(dr_size_bytes 2t)" = 2199023255552 ]
}

# A typo in a limit must not read as "no limit", which is what a parser that
# guesses would do with 8GB.
@test "dr_size_bytes: anything that is not a size is a refusal" {
    local bad
    for bad in 8GB eight '' '-1' '8 G' 1.5G 10X; do
        run dr_size_bytes "$bad"
        [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

# --- dr_incoming_validate_tree ----------------------------------------------

@test "dr_incoming_validate_tree: a plain tree of files and directories passes" {
    mktree plain 2 16 > /dev/null
    run dr_incoming_validate_tree "$DR_TMP/plain"
    [ "$status" -eq 0 ]
}

# The entry is named, because "somewhere in this tree" sends you to look at
# every file in it.
@test "dr_incoming_validate_tree: a link in the tree is refused, and named" {
    mktree linked 1 16 > /dev/null
    ln -s /etc/passwd "$DR_TMP/linked/sub/escape"
    run dr_incoming_validate_tree "$DR_TMP/linked"
    [ "$status" -eq 1 ]
    [[ "$output" == *"link or a special file"* ]]
    [[ "$output" == *"escape"* ]]
}

@test "dr_incoming_validate_tree: a fifo is refused too" {
    mktree fifo 1 16 > /dev/null
    mkfifo "$DR_TMP/fifo/sub/pipe"
    run dr_incoming_validate_tree "$DR_TMP/fifo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"link or a special file"* ]]
}

# A backslash is one component on a Windows destination and part of a name
# here, and the hash-list protocol cannot carry a control character.
@test "dr_incoming_validate_tree: a backslash or a control character in a name is refused" {
    mktree odd 1 16 > /dev/null
    touch "$DR_TMP/odd/sub/we\\ird"
    run dr_incoming_validate_tree "$DR_TMP/odd"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unsafe file name"* ]]
}

@test "dr_incoming_validate_tree: the tree itself may not be a link" {
    mktree real 1 16 > /dev/null
    ln -s "$DR_TMP/real" "$DR_TMP/pointer"
    run dr_incoming_validate_tree "$DR_TMP/pointer"
    [ "$status" -eq 1 ]
}

# --- dr_incoming_within_limits ----------------------------------------------

@test "dr_incoming_within_limits: a tree under both limits passes" {
    mktree small 3 100 > /dev/null
    DRAUGR_INCOMING_MAX_FILES=10 DRAUGR_INCOMING_MAX_SIZE=1K \
        run dr_incoming_within_limits "$DR_TMP/small"
    [ "$status" -eq 0 ]
}

@test "dr_incoming_within_limits: too many files is a refusal that names the key" {
    mktree many 6 10 > /dev/null
    DRAUGR_INCOMING_MAX_FILES=5 DRAUGR_INCOMING_MAX_SIZE=1G \
        run dr_incoming_within_limits "$DR_TMP/many"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DRAUGR_INCOMING_MAX_FILES is 5"* ]]
    [[ "$output" == *"6 files"* ]]
}

# The message gives the value as written AND in bytes: the surprise is usually
# in the difference between the two.
@test "dr_incoming_within_limits: too many bytes is a refusal that names the key" {
    mktree big 4 1024 > /dev/null
    DRAUGR_INCOMING_MAX_FILES=100 DRAUGR_INCOMING_MAX_SIZE=2K \
        run dr_incoming_within_limits "$DR_TMP/big"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DRAUGR_INCOMING_MAX_SIZE is 2K (2048)"* ]]
    [[ "$output" == *"4096 bytes"* ]]
}

# Turning a limit off is a decision the user is allowed to make, and it has to
# work for both of them at once.
@test "dr_incoming_within_limits: empty and 0 mean no limit" {
    mktree nolimit 6 1024 > /dev/null
    DRAUGR_INCOMING_MAX_FILES= DRAUGR_INCOMING_MAX_SIZE= \
        run dr_incoming_within_limits "$DR_TMP/nolimit"
    [ "$status" -eq 0 ]
    DRAUGR_INCOMING_MAX_FILES=0 DRAUGR_INCOMING_MAX_SIZE=0 \
        run dr_incoming_within_limits "$DR_TMP/nolimit"
    [ "$status" -eq 0 ]
}

# The dangerous reading of a bad value is "no limit", so it is the one the
# test pins.
@test "dr_incoming_within_limits: a size that cannot be read is a refusal" {
    mktree typo 1 10 > /dev/null
    DRAUGR_INCOMING_MAX_SIZE=8GB run dr_incoming_within_limits "$DR_TMP/typo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a size"* ]]
}

# --- dr_incoming_dest_ok ----------------------------------------------------

@test "dr_incoming_dest_ok: a destination inside the root passes" {
    mkdir -p "$DR_TMP/root/corner"
    run dr_incoming_dest_ok "$DR_TMP/root" "$DR_TMP/root/corner/memory"
    [ "$status" -eq 0 ]
}

@test "dr_incoming_dest_ok: a root that is a link is refused" {
    mkdir -p "$DR_TMP/elsewhere/corner"
    ln -s "$DR_TMP/elsewhere" "$DR_TMP/rootlink"
    run dr_incoming_dest_ok "$DR_TMP/rootlink" "$DR_TMP/rootlink/corner/memory"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a directory of its own"* ]]
}

# The rename publishes into whatever the link names, and the receipt afterwards
# still prints the path that was asked for.
@test "dr_incoming_dest_ok: a link on the way down is refused" {
    mkdir -p "$DR_TMP/root" "$DR_TMP/outside"
    ln -s "$DR_TMP/outside" "$DR_TMP/root/corner"
    run dr_incoming_dest_ok "$DR_TMP/root" "$DR_TMP/root/corner/memory"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is a link, or is absent"* ]]
}

# Moving a link aside leaves the tree it pointed at exactly where it was, so
# the publication would not replace what the user thinks it replaces.
@test "dr_incoming_dest_ok: a destination that exists as a link is refused" {
    mkdir -p "$DR_TMP/root/corner" "$DR_TMP/outside"
    ln -s "$DR_TMP/outside" "$DR_TMP/root/corner/memory"
    run dr_incoming_dest_ok "$DR_TMP/root" "$DR_TMP/root/corner/memory"
    [ "$status" -eq 1 ]
    [[ "$output" == *"link or not a directory"* ]]
}

@test "dr_incoming_dest_ok: a destination outside the root is refused" {
    mkdir -p "$DR_TMP/root" "$DR_TMP/outside"
    run dr_incoming_dest_ok "$DR_TMP/root" "$DR_TMP/outside/memory"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not inside"* ]]
}

# Strict: nothing here may ever replace the root it is confined to.
@test "dr_incoming_dest_ok: the root itself is not a destination" {
    mkdir -p "$DR_TMP/root"
    run dr_incoming_dest_ok "$DR_TMP/root" "$DR_TMP/root"
    [ "$status" -eq 1 ]
}

# --- dr_incoming_publish ----------------------------------------------------

@test "dr_incoming_publish: the staged tree lands, and the old copy is kept" {
    mkdir -p "$DR_TMP/stage/seed" "$DR_TMP/store/seed"
    printf 'new\n' > "$DR_TMP/stage/seed/f"
    printf 'old\n' > "$DR_TMP/store/seed/f"
    run dr_incoming_publish "$DR_TMP/stage/seed" "$DR_TMP/store/seed" "$DR_TMP/store/seed.old"
    [ "$status" -eq 0 ]
    [ "$(cat "$DR_TMP/store/seed/f")" = new ]
    [ "$(cat "$DR_TMP/store/seed.old/f")" = old ]
    [ ! -e "$DR_TMP/stage/seed" ]
}

# A kept copy is REPLACED, not merged: a file from two exports ago must not
# come back inside the one you think is the previous one.
@test "dr_incoming_publish: an older kept copy is replaced, not merged" {
    mkdir -p "$DR_TMP/stage/seed" "$DR_TMP/store/seed" "$DR_TMP/store/seed.old"
    printf 'new\n' > "$DR_TMP/stage/seed/f"
    printf 'old\n' > "$DR_TMP/store/seed/f"
    printf 'ancient\n' > "$DR_TMP/store/seed.old/gone"
    run dr_incoming_publish "$DR_TMP/stage/seed" "$DR_TMP/store/seed" "$DR_TMP/store/seed.old"
    [ "$status" -eq 0 ]
    [ ! -e "$DR_TMP/store/seed.old/gone" ]
    [ "$(cat "$DR_TMP/store/seed.old/f")" = old ]
}

@test "dr_incoming_publish: with no name to keep it under, the old copy goes" {
    mkdir -p "$DR_TMP/stage/seed" "$DR_TMP/store/seed"
    printf 'new\n' > "$DR_TMP/stage/seed/f"
    printf 'old\n' > "$DR_TMP/store/seed/f"
    run dr_incoming_publish "$DR_TMP/stage/seed" "$DR_TMP/store/seed"
    [ "$status" -eq 0 ]
    [ "$(cat "$DR_TMP/store/seed/f")" = new ]
    [ ! -e "$DR_TMP/store/seed.old" ]
}

# The destination must survive a publication that had nothing to publish. This
# is the case where a caller's transfer failed and its status was discarded.
@test "dr_incoming_publish: no staged tree leaves the destination alone" {
    mkdir -p "$DR_TMP/store/seed"
    printf 'old\n' > "$DR_TMP/store/seed/f"
    run dr_incoming_publish "$DR_TMP/stage/seed" "$DR_TMP/store/seed" "$DR_TMP/store/seed.old"
    [ "$status" -eq 1 ]
    [ "$(cat "$DR_TMP/store/seed/f")" = old ]
    [ ! -e "$DR_TMP/store/seed.old" ]
    [[ "$output" == *"no staged tree"* ]]
}

@test "dr_incoming_publish: a staged tree that is a link is not published" {
    mkdir -p "$DR_TMP/outside" "$DR_TMP/store"
    ln -s "$DR_TMP/outside" "$DR_TMP/stagelink"
    run dr_incoming_publish "$DR_TMP/stagelink" "$DR_TMP/store/seed"
    [ "$status" -eq 1 ]
    [ ! -e "$DR_TMP/store/seed" ]
}

# The count is read the same way the size is. A value that is not a number
# reaches `[ "$files" -gt "$maxf" ]`, which answers 2 and takes no branch - and
# a function that then returns 0 has turned a typo into "no limit".
@test "dr_incoming_within_limits: a file count that is not a number is a refusal" {
    mktree typo2 1 10 > /dev/null
    DRAUGR_INCOMING_MAX_FILES=lots run dr_incoming_within_limits "$DR_TMP/typo2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a number"* ]]
}
