#!/usr/bin/env bats
# dr-mem: the project-key translation, and moving memory across the boundary.
#
# The key rules are pure string functions and are tested against literal strings,
# so they run anywhere. Everything else runs against a real directory tree
# standing in for the mound's disk (see dr_mound_memory_dir), which means the
# paths dr-mem computes have to be right for the files to be found at all.

load helper

setup() {
    dr_test_setup
    dr_load_common
    # Never the developer's real store.
    export DRAUGR_MEM_STORE="$DR_TMP/memstore"
}

teardown() { dr_test_teardown; }

# --- the three keys, the whole reason this command exists --------------------

@test "mem key: the README's own example, all three sides" {
    [ "$(dr_mem_key 'C:\src\myproject')" = 'c--src-myproject' ]
    [ "$(dr_mem_key '/mnt/c/src/myproject')" = '-mnt-c-src-myproject' ]
    [ "$(dr_mem_key '/c/src/myproject')" = '-c-src-myproject' ]
}

@test "mem key: measured against this machine's real directories" {
    # Not invented: C:\Code\claude really is filed as c--Code-claude on the host
    # and -c-Code-claude inside its mound.
    [ "$(dr_mem_key 'C:\Code\claude')" = 'c--Code-claude' ]
    [ "$(dr_mem_key '/c/Code/claude')" = '-c-Code-claude' ]
}

@test "mem key: the drive letter is lowercased, the rest keeps its case" {
    [ "$(dr_mem_key 'C:\Code\Draugr')" = 'c--Code-Draugr' ]
    [ "$(dr_mem_key 'D:\Code\Draugr')" = 'd--Code-Draugr' ]
}

@test "mem key: all three derived from one WSL repo path" {
    local repo=/mnt/c/src/myproject
    [ "$(dr_mem_key_win   "$repo")" = 'c--src-myproject' ]
    [ "$(dr_mem_key_wsl   "$repo")" = '-mnt-c-src-myproject' ]
    [ "$(dr_mem_key_mound "$repo")" = '-c-src-myproject' ]
}

@test "mem key: the three forms are all different, which is the trap" {
    local repo=/mnt/c/src/myproject a b c
    a=$(dr_mem_key_win "$repo"); b=$(dr_mem_key_wsl "$repo"); c=$(dr_mem_key_mound "$repo")
    [ "$a" != "$b" ]; [ "$b" != "$c" ]; [ "$a" != "$c" ]
}

@test "mem store: named with the host key, so it never starts with a dash" {
    DRAUGR_MEM_STORE=/tmp/store
    run dr_mem_store_dir /mnt/c/src/myproject
    [ "$output" = "/tmp/store/c--src-myproject" ]
    # A leading "-" would be read as an option by anything you typed it at.
    [[ "$output" != *"/-"* ]]
}

@test "mem: the mound path is the agent's home, not yours" {
    run dr_mem_mound_dir /mnt/c/src/myproject
    [ "$output" = "/home/agent/.claude/projects/-c-src-myproject" ]
}

# --- moving it -----------------------------------------------------------------

# A repo on a Windows drive with a stand-in mound filesystem behind it. Prints
# the mound's memory directory; the repo path lands in $REPO.
setup_mound() {
    REPO=$(dr_make_win_repo) || return 1
    cd "$REPO" || return 1
    # Sets DR_MEMDIR and DR_MOCK_MOUND; calling it in $(…) would lose the export.
    dr_mound_memory_dir "$REPO"
    MEMDIR=$DR_MEMDIR
    export DR_MOCK_STATE=running
    mkdir -p "$(dirname "$MEMDIR")"
    return 0
}

@test "dr-mem export: an empty mound is not a failure" {
    setup_mound || skip "no writable Windows drive path"
    run dr-mem export
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to export"* ]]
}

@test "dr-mem export: memory lands in the store under the host key" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'the build is cmake, not make\n' > "$MEMDIR/build.md"

    run dr-mem export
    [ "$status" -eq 0 ]

    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    [ -f "$store/memory/build.md" ]
    grep -q "cmake" "$store/memory/build.md"
    # The marker is what makes a later import trust this without asking.
    grep -qxF "repo:    $REPO" "$store/.draugr-export"
}

@test "dr-mem export: the copy it replaces is kept, not deleted" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'first\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1

    rm -f "$MEMDIR/a.md"
    printf 'second\n' > "$MEMDIR/b.md"
    run dr-mem export
    [ "$status" -eq 0 ]

    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    [ -f "$store/memory/b.md" ]
    [ ! -f "$store/memory/a.md" ]
    # One mv away from getting it back.
    [ -f "$store/memory.previous/a.md" ]
}

@test "dr-mem import: files arrive under the MOUND's key, not the host's" {
    setup_mound || skip "no writable Windows drive path"
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    mkdir -p "$store/memory"
    printf 'remember this\n' > "$store/memory/note.md"

    run dr-mem import --yes
    [ "$status" -eq 0 ]

    # The whole point: written to -c-…, which is where the agent will look.
    [ -f "$MEMDIR/note.md" ]
    grep -q "remember this" "$MEMDIR/note.md"
}

@test "dr-mem import: warns that memory is instructions" {
    setup_mound || skip "no writable Windows drive path"
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    mkdir -p "$store/memory"
    printf 'x\n' > "$store/memory/note.md"

    run dr-mem import --yes
    [[ "$output" == *"instructions"* ]]
}

@test "dr-mem import: a store Draugr did not write has to be confirmed" {
    setup_mound || skip "no writable Windows drive path"
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    mkdir -p "$store/memory"
    printf 'do something surprising\n' > "$store/memory/note.md"
    # No .draugr-export marker: this could be anyone's.

    # No terminal and no --yes, so dr_confirm refuses rather than assuming.
    run dr-mem import
    [ "$status" -ne 0 ]
    [ ! -f "$MEMDIR/note.md" ]
}

@test "dr-mem import: its own export is trusted without a prompt" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'mine\n' > "$MEMDIR/note.md"
    dr-mem export >/dev/null 2>&1
    rm -rf "$MEMDIR"

    # Still no terminal and still no --yes: this must not prompt at all.
    run dr-mem import
    [ "$status" -eq 0 ]
    [ -f "$MEMDIR/note.md" ]
}

@test "dr-mem import --if-empty: declines to overwrite what the agent wrote" {
    setup_mound || skip "no writable Windows drive path"
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    mkdir -p "$store/memory" "$MEMDIR"
    printf 'the old copy\n' > "$store/memory/note.md"
    printf 'what the agent learned since\n' > "$MEMDIR/fresh.md"

    run dr-mem import --if-empty --yes
    [ "$status" -eq 0 ]
    # Untouched: this is the check that makes DRAUGR_MEM_SYNC=auto safe on dr-up.
    [ -f "$MEMDIR/fresh.md" ]
    [ ! -f "$MEMDIR/note.md" ]
}

@test "dr-mem import --if-empty: fills a mound that has nothing" {
    setup_mound || skip "no writable Windows drive path"
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    mkdir -p "$store/memory"
    printf 'restored\n' > "$store/memory/note.md"

    run dr-mem import --if-empty --yes
    [ "$status" -eq 0 ]
    [ -f "$MEMDIR/note.md" ]
}

@test "dr-mem diff: silent when both sides agree" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'same\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1

    run dr-mem diff
    [ "$status" -eq 0 ]
    [[ "$output" == *"same memory"* ]]
}

@test "dr-mem diff: names what each side has that the other does not" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'shared\n' > "$MEMDIR/both.md"
    printf 'old\n'    > "$MEMDIR/changes.md"
    dr-mem export >/dev/null 2>&1

    printf 'new\n' > "$MEMDIR/changes.md"
    printf 'fresh\n' > "$MEMDIR/only-mound.md"
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    printf 'stale\n' > "$store/memory/only-store.md"

    run dr-mem diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"only in mound: only-mound.md"* ]]
    [[ "$output" == *"only in store: only-store.md"* ]]
    [[ "$output" == *"changed:"*"changes.md"* ]]
    # Present on both sides and identical, so it is not a difference.
    [[ "$output" != *"both.md"* ]]
}

# --- the check dr-rm leans on --------------------------------------------------

@test "dr-mem check: an exported mound is safe to destroy" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'a\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1

    run dr-mem check
    [ "$status" -eq 0 ]
}

@test "dr-mem check: unexported memory is not" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'never exported\n' > "$MEMDIR/a.md"

    run dr-mem check
    [ "$status" -eq 1 ]
}

@test "dr-mem check: a store holding MORE is still safe" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'a\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    printf 'extra\n' > "$store/memory/b.md"

    # dr-rm destroys the mound, not the store, so the extra file is irrelevant.
    run dr-mem check
    [ "$status" -eq 0 ]
}

@test "dr-mem check: a changed file counts as unexported" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'before\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1
    printf 'after\n' > "$MEMDIR/a.md"

    run dr-mem check
    [ "$status" -eq 1 ]
}

@test "dr-rm: refuses while the mound holds unexported memory" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'unexported\n' > "$MEMDIR/a.md"

    run dr-rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"not exported"* ]]
    [[ "$output" == *"dr-mem export"* ]]
}

@test "dr-rm: proceeds once the memory is in the store" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'exported\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1

    run dr-rm --yes
    [ "$status" -eq 0 ]
}

# --- what the three DRAUGR_MEM_SYNC values actually do -------------------------

@test "mem sync manual: no automatic transfer, but dr-rm still refuses" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'unexported\n' > "$MEMDIR/a.md"

    DRAUGR_MEM_SYNC=manual run dr-rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"not exported"* ]]
}

@test "mem sync off: dr-rm does not refuse over memory you said you do not keep" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'unexported\n' > "$MEMDIR/a.md"

    DRAUGR_MEM_SYNC=off run dr-rm --yes
    [ "$status" -eq 0 ]
}

@test "mem sync off: dr-status leaves the memory section out" {
    setup_mound || skip "no writable Windows drive path"
    DRAUGR_MEM_SYNC=off run dr-status
    [ "$status" -eq 0 ]
    [[ "$output" != *"nothing exported yet"* ]]
}

@test "mem sync manual: dr-status still reports it" {
    setup_mound || skip "no writable Windows drive path"
    DRAUGR_MEM_SYNC=manual run dr-status
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing exported yet"* ]]
}

@test "mem sync auto: dr-up imports into an empty mound" {
    setup_mound || skip "no writable Windows drive path"
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    mkdir -p "$store/memory"
    printf 'restored\n' > "$store/memory/note.md"

    DRAUGR_MEM_SYNC=auto run dr-up
    [ "$status" -eq 0 ]
    [ -f "$MEMDIR/note.md" ]
}

@test "mem sync off: dr-up imports nothing" {
    setup_mound || skip "no writable Windows drive path"
    store="$DRAUGR_MEM_STORE/$(dr_mem_key_win "$REPO")"
    mkdir -p "$store/memory"
    printf 'restored\n' > "$store/memory/note.md"

    DRAUGR_MEM_SYNC=off run dr-up
    [ "$status" -eq 0 ]
    [ ! -f "$MEMDIR/note.md" ]
}

# --- listings are only ever sha256sum's own shape -------------------------------

@test "dr-mem: a stray line from the mound is not mistaken for a file" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'real\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1

    # Whatever else appears on stdout, only 64-hex-plus-name lines are files.
    # Without the filter this reports memory that does not exist, and dr-rm then
    # refuses to destroy a mound over it - forever.
    run dr-mem check
    [ "$status" -eq 0 ]
}
