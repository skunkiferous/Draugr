#!/usr/bin/env bats
# dr-mem: the project-key translation, and the move of memory across the
# boundary.
#
# The key rules are pure string functions. Their tests use literal strings, so
# they run in all places. All else runs against a real directory tree that acts
# as the disk of the mound (see dr_mound_memory_dir). Thus the paths of dr-mem
# must be correct, or the files are not found.

load helper

setup() {
    dr_test_setup
    dr_load_common
    # Never the real store of the developer.
    export DRAUGR_MEM_STORE="$DR_TMP/memstore"
}

teardown() { dr_test_teardown; }

# --- the three keys, the full reason for this command ------------------------

@test "mem key: the README's own example, all three sides" {
    [ "$(dr_mem_key 'C:\src\myproject')" = 'c--src-myproject' ]
    [ "$(dr_mem_key '/mnt/c/src/myproject')" = '-mnt-c-src-myproject' ]
    [ "$(dr_mem_key '/c/src/myproject')" = '-c-src-myproject' ]
}

@test "mem key: measured against this machine's real directories" {
    # Not made up. C:\Code\claude really is filed as c--Code-claude on the host,
    # and as -c-Code-claude in its mound.
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
    DRAUGR_AGENT=claude
    run dr_mem_store_dir /mnt/c/src/myproject
    [ "$output" = "/tmp/store/c--src-myproject/claude" ]
    # Each tool reads a leading "-" as an option.
    [[ "$output" != *"/-"* ]]
}

@test "mem store: two agents on one repo do not share a corner" {
    DRAUGR_MEM_STORE=/tmp/store
    local a b
    a=$(DRAUGR_AGENT=claude dr_mem_store_dir /mnt/c/src/myproject)
    b=$(DRAUGR_AGENT=codex  dr_mem_store_dir /mnt/c/src/myproject)
    [ "$a" != "$b" ]
    # Repo first, so that all about one project stays in one place.
    [ "$(dirname "$a")" = "$(dirname "$b")" ]
}

@test "mem store: a pre-0.2.0 store is moved under claude, not under today's agent" {
    export DRAUGR_MEM_STORE="$DR_TMP/oldstore"
    local old
    old="$DRAUGR_MEM_STORE/$(dr_mem_key_win /mnt/c/src/myproject)"
    mkdir -p "$old/memory"
    printf 'from before the split\n' > "$old/memory/a.md"
    printf 'repo:    /mnt/c/src/myproject\n' > "$old/.draugr-export"

    # A migration while configured for codex must NOT file the memories of
    # Claude there.
    DRAUGR_AGENT=codex dr_mem_store_migrate /mnt/c/src/myproject

    [ -f "$old/claude/memory/a.md" ]
    [ -f "$old/claude/.draugr-export" ]
    [ ! -e "$old/memory" ]
    [ ! -d "$old/codex" ]
}

@test "mem store: migration is a no-op the second time" {
    export DRAUGR_MEM_STORE="$DR_TMP/oldstore"
    local old
    old="$DRAUGR_MEM_STORE/$(dr_mem_key_win /mnt/c/src/myproject)"
    mkdir -p "$old/memory"
    printf 'first\n' > "$old/memory/a.md"
    dr_mem_store_migrate /mnt/c/src/myproject

    # A later export writes memory/ under claude/. A second run of the migration
    # must not move it back up one level.
    printf 'second\n' > "$old/claude/memory/b.md"
    dr_mem_store_migrate /mnt/c/src/myproject
    [ -f "$old/claude/memory/b.md" ]
    [ ! -e "$old/memory" ]
}

@test "mem: the mound path is the agent's home, not yours" {
    run dr_mem_mound_dir /mnt/c/src/myproject
    [ "$output" = "/home/agent/.claude/projects/-c-src-myproject" ]
}

# --- the move ------------------------------------------------------------------

# A repo on a Windows drive, with a stand-in mound filesystem behind it. Prints
# the memory directory of the mound. The repo path goes into $REPO.
setup_mound() {
    REPO=$(dr_make_win_repo) || return 1
    cd "$REPO" || return 1
    # Sets DR_MEMDIR and DR_MOCK_MOUND. A call in $(…) loses the export.
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
    [[ "$output" == *"Nothing to export"* ]]
}

@test "dr-mem export: memory lands in the store under the host key" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'the build is cmake, not make\n' > "$MEMDIR/build.md"

    run dr-mem export
    [ "$status" -eq 0 ]

    store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/build.md" ]
    grep -q "cmake" "$store/memory/build.md"
    # The marker lets a later import trust this, with no question.
    grep -qxF "repo:    $REPO" "$store/.draugr-export"
}

# THE PATH THAT ACTUALLY SHIPS HAS A SPACE IN IT. Staging moved out of the
# repository and its default is %LOCALAPPDATA%\Draugr\stage, which on a normal
# Windows account sits under `C:\Users\<first last>\…`. Every fixture path in
# this suite is space-free, so without this test the one route that every user
# takes would be the untested one, and `sbx cp` gets that path as an argument.
@test "dr-mem export: a staging root with a space in it still exports" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'the build is cmake, not make\n' > "$MEMDIR/build.md"
    # dr_make_win_repo exports DR_WIN_TMP from a subshell, so it never arrives
    # here. The parent of the repo is that same directory.
    DRAUGR_STAGE_ROOT="$(dirname "$REPO")/stage root"
    export DRAUGR_STAGE_ROOT

    run dr-mem export
    [ "$status" -eq 0 ]
    store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/build.md" ]
    grep -q "cmake" "$store/memory/build.md"
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

    store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/b.md" ]
    [ ! -f "$store/memory/a.md" ]
    # One mv gets it back.
    [ -f "$store/memory.previous/a.md" ]
}

@test "dr-mem import: files arrive under the MOUND's key, not the host's" {
    setup_mound || skip "no writable Windows drive path"
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store/memory"
    printf 'remember this\n' > "$store/memory/note.md"

    run dr-mem import --yes
    [ "$status" -eq 0 ]

    # The full purpose: written to -c-…, where the agent looks.
    [ -f "$MEMDIR/note.md" ]
    grep -q "remember this" "$MEMDIR/note.md"
}

@test "dr-mem import: warns that memory is instructions" {
    setup_mound || skip "no writable Windows drive path"
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store/memory"
    printf 'x\n' > "$store/memory/note.md"

    run dr-mem import --yes
    [[ "$output" == *"instructions"* ]]
}

@test "dr-mem import: a store Draugr did not write has to be confirmed" {
    setup_mound || skip "no writable Windows drive path"
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store/memory"
    printf 'do something surprising\n' > "$store/memory/note.md"
    # No .draugr-export marker. This can belong to anybody.

    # No terminal and no --yes, so dr_confirm refuses, and does not assume.
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

    # Still no terminal, and still no --yes. This must never prompt.
    run dr-mem import
    [ "$status" -eq 0 ]
    [ -f "$MEMDIR/note.md" ]
}

@test "dr-mem import --if-empty: declines to overwrite what the agent wrote" {
    setup_mound || skip "no writable Windows drive path"
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store/memory" "$MEMDIR"
    printf 'the old copy\n' > "$store/memory/note.md"
    printf 'what the agent learned since\n' > "$MEMDIR/fresh.md"

    run dr-mem import --if-empty --yes
    [ "$status" -eq 0 ]
    # No change. This test makes DRAUGR_MEM_SYNC=auto safe on dr-up.
    [ -f "$MEMDIR/fresh.md" ]
    [ ! -f "$MEMDIR/note.md" ]
}

@test "dr-mem import --if-empty: fills a mound that has nothing" {
    setup_mound || skip "no writable Windows drive path"
    store=$(dr_mem_store_dir "$REPO")
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
    store=$(dr_mem_store_dir "$REPO")
    printf 'stale\n' > "$store/memory/only-store.md"

    run dr-mem diff
    [ "$status" -eq 1 ]
    [[ "$output" == *"only in mound: only-mound.md"* ]]
    [[ "$output" == *"only in store: only-store.md"* ]]
    [[ "$output" == *"changed:"*"changes.md"* ]]
    # Present on both sides, and identical, so it is not a difference.
    [[ "$output" != *"both.md"* ]]
}

# --- the test that dr-rm depends on ------------------------------------------

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
    store=$(dr_mem_store_dir "$REPO")
    printf 'extra\n' > "$store/memory/b.md"

    # dr-rm destroys the mound, not the store, so the extra file is not
    # important.
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
    # The memory question is the second one. Without this, dr-rm refuses at the
    # first, over commits it cannot ask about, and this test proves nothing.
    dr_mound_answers
    mkdir -p "$MEMDIR"
    printf 'unexported\n' > "$MEMDIR/a.md"

    run dr-rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not export"* ]]
    [[ "$output" == *"dr-mem export"* ]]
}

@test "dr-rm: proceeds once the memory is in the store" {
    setup_mound || skip "no writable Windows drive path"
    dr_mound_answers
    mkdir -p "$MEMDIR"
    printf 'exported\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1

    run dr-rm --yes
    [ "$status" -eq 0 ]
}

# --- what the three DRAUGR_MEM_SYNC values really do -------------------------

@test "mem sync manual: no automatic transfer, but dr-rm still refuses" {
    setup_mound || skip "no writable Windows drive path"
    dr_mound_answers
    mkdir -p "$MEMDIR"
    printf 'unexported\n' > "$MEMDIR/a.md"

    DRAUGR_MEM_SYNC=manual run dr-rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not export"* ]]
}

@test "mem sync off: dr-rm does not refuse over memory you said you do not keep" {
    setup_mound || skip "no writable Windows drive path"
    dr_mound_answers
    mkdir -p "$MEMDIR"
    printf 'unexported\n' > "$MEMDIR/a.md"

    DRAUGR_MEM_SYNC=off run dr-rm --yes
    [ "$status" -eq 0 ]
}

# A MOUND THAT CANNOT ANSWER IS NOT AN EMPTY MOUND. The memory of the agent
# lives only in the disk image, so this is the one question whose answer cannot
# be reconstructed afterwards. Status 2 used to print a warning and then ask
# whether to destroy it anyway. DR_MOCK_FAIL=exec fails exactly the call that
# lists the memory, and nothing else in dr-rm's chain uses it.
@test "dr-rm: a mound that cannot say what memory it holds is not destroyed" {
    setup_mound || skip "no writable Windows drive path"
    dr_mound_answers
    mkdir -p "$MEMDIR"
    printf 'unexported\n' > "$MEMDIR/a.md"

    DR_MOCK_FAIL=exec run dr-rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"look for memory"* ]]
    [[ "$output" == *"--force"* ]]
    [ -z "$(grep '^rm ' "$DR_MOCK_LOG" || true)" ]
}

@test "dr-up --recreate: the same mound is not rebuilt over either" {
    setup_mound || skip "no writable Windows drive path"
    dr_mound_answers
    mkdir -p "$MEMDIR"
    printf 'unexported\n' > "$MEMDIR/a.md"

    DR_MOCK_FAIL=exec run dr-up --recreate --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"look for memory"* ]]
    [ -z "$(grep '^rm ' "$DR_MOCK_LOG" || true)" ]
    [ -z "$(grep '^create ' "$DR_MOCK_LOG" || true)" ]
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
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store/memory"
    printf 'restored\n' > "$store/memory/note.md"

    DRAUGR_MEM_SYNC=auto run dr-up
    [ "$status" -eq 0 ]
    [ -f "$MEMDIR/note.md" ]
}

@test "mem sync off: dr-up imports nothing" {
    setup_mound || skip "no writable Windows drive path"
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store/memory"
    printf 'restored\n' > "$store/memory/note.md"

    DRAUGR_MEM_SYNC=off run dr-up
    [ "$status" -eq 0 ]
    [ ! -f "$MEMDIR/note.md" ]
}

# --- listings always have the own shape of sha256sum --------------------------

@test "dr-mem: a stray line from the mound is not mistaken for a file" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'real\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1

    # Whatever else appears on stdout, only 64-hex-plus-name lines are files.
    # Without the filter, this reports memory that does not exist. Then dr-rm
    # refuses forever to destroy the mound because of it.
    run dr-mem check
    [ "$status" -eq 0 ]
}

# --- Codex: a very different shape ---------------------------------------------
#
# Two halves that travel together, and are compared together: markdown under
# memories/, and the SQLite of the session history. The store holds the packed
# tree, so these assert on it directly. If pack, unpack, and list ever disagree
# about a name, one of these fails.

setup_codex() {
    REPO=$(dr_make_win_repo) || return 1
    cd "$REPO" || return 1
    export DRAUGR_AGENT=codex
    # The dr-* commands load the module again at the end of dr_load_config. A
    # test shell that changed the agent by hand must do the same. If not, it
    # continues to ask the module of Claude Code where Codex put things.
    dr_agent_load
    dr_mound_codex_dir
    CODEXDIR=$DR_CODEXDIR
    export DR_MOCK_STATE=running
    mkdir -p "$CODEXDIR"
    return 0
}

# All that a real CODEX_HOME holds, also the parts that must NOT travel.
seed_codex() {
    mkdir -p "$CODEXDIR/memories/rollout_summaries"
    printf 'the build is cmake\n'        > "$CODEXDIR/memories/MEMORY.md"
    printf 'summary\n'                   > "$CODEXDIR/memories/memory_summary.md"
    printf 'one session\n'               > "$CODEXDIR/memories/rollout_summaries/s1.md"
    printf 'threads\n'                   > "$CODEXDIR/state_5.sqlite"
    printf 'wal\n'                       > "$CODEXDIR/state_5.sqlite-wal"
    printf 'shm\n'                       > "$CODEXDIR/state_5.sqlite-shm"
    printf 'jobs\n'                      > "$CODEXDIR/memories_1.sqlite"
    printf 'noise\n'                     > "$CODEXDIR/logs_2.sqlite"
    printf 'yolo\n'                      > "$CODEXDIR/config.toml"
    printf 'id\n'                        > "$CODEXDIR/installation_id"
}

@test "codex: memory is not filed under the project key" {
    setup_codex || skip "no writable Windows drive path"
    run dr_agent_mem_dir "$REPO"
    # No key in it. That full mechanism belongs only to Claude Code.
    [ "$output" = "/home/agent/.codex/memories" ]
}

@test "codex export: the markdown and the databases both travel" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex

    run dr-mem export
    [ "$status" -eq 0 ]

    store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/memories/MEMORY.md" ]
    [ -f "$store/memory/memories/rollout_summaries/s1.md" ]
    [ -f "$store/memory/state_5.sqlite" ]
    [ -f "$store/memory/state_5.sqlite-wal" ]
    [ -f "$store/memory/memories_1.sqlite" ]
}

@test "codex export: logs, config and the shm file stay behind" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex

    run dr-mem export
    [ "$status" -eq 0 ]

    store=$(dr_mem_store_dir "$REPO")
    # config.toml is the yolo-mode configuration of sbx. If it travels, an
    # import can overwrite it, and silently turn the approval prompts on again.
    [ ! -e "$store/memory/config.toml" ]
    [ ! -e "$store/memory/installation_id" ]
    # Diagnostics, 7 MB of them on a real machine.
    [ ! -e "$store/memory/logs_2.sqlite" ]
    # SQLite builds -shm again. An old one is worse than none.
    [ ! -e "$store/memory/state_5.sqlite-shm" ]
}

@test "codex export: session history alone is worth exporting" {
    setup_codex || skip "no writable Windows drive path"
    # No memories/, because the feature was never on. But Codex ran, so there
    # are threads to lose.
    printf 'threads\n' > "$CODEXDIR/state_5.sqlite"

    run dr-mem export
    [ "$status" -eq 0 ]
    [[ "$output" != *"nothing to export"* ]]
    store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/state_5.sqlite" ]
}

@test "codex export: an untouched CODEX_HOME is nothing to export" {
    setup_codex || skip "no writable Windows drive path"
    printf 'yolo\n' > "$CODEXDIR/config.toml"

    run dr-mem export
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to export"* ]]
}

@test "codex import: everything lands back where Codex reads it" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex
    dr-mem export >/dev/null 2>&1
    rm -rf "$CODEXDIR/memories" "$CODEXDIR"/*.sqlite "$CODEXDIR"/*.sqlite-wal

    run dr-mem import
    [ "$status" -eq 0 ]
    [ -f "$CODEXDIR/memories/MEMORY.md" ]
    [ -f "$CODEXDIR/state_5.sqlite" ]
    grep -q cmake "$CODEXDIR/memories/MEMORY.md"
}

@test "codex import: a whole agent home is refused before transfer" {
    setup_codex || skip "no writable Windows drive path"
    printf 'yolo\n' > "$CODEXDIR/config.toml"

    # --source points to the full CODEX_HOME of somebody. `dr-mem import
    # --from-host` gives it exactly that.
    src="$DR_TMP/someone-elses-codex"
    mkdir -p "$src/memories"
    printf 'theirs\n'          > "$src/memories/MEMORY.md"
    printf 'approvals on\n'    > "$src/config.toml"

    run dr-mem import --yes --source "$src"
    [ "$status" -ne 0 ]
    [ ! -f "$CODEXDIR/memories/MEMORY.md" ]
    # Refusal happens before the upload, not only before the final copy.
    ! grep -q '^cp ' "$DR_MOCK_LOG" || return 1
    grep -q yolo "$CODEXDIR/config.toml"
}

@test "codex check: unexported session history is not nothing to lose" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex

    run dr-mem check
    [ "$status" -eq 1 ]

    dr-mem export >/dev/null 2>&1
    run dr-mem check
    [ "$status" -eq 0 ]
}

@test "codex: the store is separate from claude's for the same repo" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex
    dr-mem export >/dev/null 2>&1

    # None of that touches the part of Claude in the same repo.
    codex_store=$(dr_mem_store_dir "$REPO")
    claude_store=$(DRAUGR_AGENT=claude dr_mem_store_dir "$REPO")
    [ "$codex_store" != "$claude_store" ]
    [ -f "$codex_store/memory/memories/MEMORY.md" ]
    [ ! -e "$claude_store/memory" ]
}

# The three answers of dr_agent_mem_quiesce had NO test at all. Thus the bug in
# the body stayed: the header states a contract, and the body did not keep it.
# These two tests cover the answers that are not "quiet". Each other codex test
# in this file covers the quiet answer.
@test "dr_agent_mem_quiesce: a running codex is not quiet" {
    setup_codex || skip "no writable Windows drive path"
    export DR_MOCK_AGENT_RUNNING=codex
    run dr_agent_mem_quiesce
    [ "$status" -eq 1 ]
}

@test "dr_agent_mem_quiesce: a pgrep that cannot answer is unknown, not safe" {
    # pgrep exits with 2 and 3 for its own errors, and with 1 for "no match".
    # When the code read each non-zero code as "not running", a probe with no
    # answer gave the SAFE answer. That answer permits a copy of a live WAL
    # pair.
    setup_codex || skip "no writable Windows drive path"
    export DR_MOCK_PGREP_BROKEN=1
    run dr_agent_mem_quiesce
    [ "$status" -eq 2 ]
}


# --- the three answers reaching the person who reads them -------------------
#
# The probe kept its three answers and the caller threw two of them away. These
# tests are about the MESSAGE, not the exit code: both non-zero answers refuse,
# so behaviour alone cannot tell them apart, and a refusal that names the wrong
# cause sends the reader to do the wrong thing.
@test "dr-mem export: a running agent is reported without a guess about the mound" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex
    export DR_MOCK_AGENT_RUNNING=codex

    run dr-mem export
    [ "$status" -ne 0 ]
    # The module's own diagnosis survives.
    [[ "$output" == *"codex runs in"* ]]
    # And nothing is appended that the module did not measure. This line used to
    # arrive directly under "codex runs in <mound>", which can only be true of a
    # mound that answered.
    [[ "$output" != *"Is the mound running?"* ]] || return 1
    # A refusal publishes nothing.
    [ ! -e "$(dr_mem_store_dir "$REPO")/memory" ]
}

@test "dr-mem export: a probe with no answer DOES send you to the mound" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex
    export DR_MOCK_PGREP_BROKEN=1

    run dr-mem export
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not find out"* ]]
    # Here the hint is right: nothing answered, so the mound is what to look at.
    [[ "$output" == *"Is the mound running?"* ]]
    [ ! -e "$(dr_mem_store_dir "$REPO")/memory" ]
}

@test "dr_agent_mem_pack: not quiet is 1, and a probe with no answer is 2" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex

    # The stage path is never used: both runs stop at the first probe.
    export DR_MOCK_AGENT_RUNNING=codex
    run dr_agent_mem_pack "$REPO" /tmp/h2-pack-stage
    [ "$status" -eq 1 ]

    unset DR_MOCK_AGENT_RUNNING
    export DR_MOCK_PGREP_BROKEN=1
    run dr_agent_mem_pack "$REPO" /tmp/h2-pack-stage
    [ "$status" -eq 2 ]
}

@test "dr_agent_mem_pack: a copy step that does not answer is 2, not 1" {
    setup_codex || skip "no writable Windows drive path"
    seed_codex

    # The agent is quiet and the MOUND is what fails. Every failure in pack used
    # to be 1, so this was indistinguishable from a running agent, and the
    # caller's advice was wrong for one of the two whichever it chose.
    #
    # TWO steps, and the filters are chosen with care. The mock matches the whole
    # argv, and the state script travels with EVERY call, so a filter that looks
    # like it names the staging call ('mkdir -p') in fact stops the hash probe
    # before it. A mutation of the staging line then survived a test that passed.
    export DR_MOCK_FAIL_AT='sha256sum'      # in the script, so the FIRST call
    run dr_agent_mem_pack "$REPO" /tmp/h2-pack-stage
    [ "$status" -eq 2 ]

    export DR_MOCK_FAIL_AT='rm -rf "$1"'    # the staging call, and only it
    run dr_agent_mem_pack "$REPO" /tmp/h2-pack-stage
    [ "$status" -eq 2 ]
}

@test "dr-mem import: a running agent is reported as in use" {
    setup_codex || skip "no writable Windows drive path"
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store/memory"
    printf 'remember this\n' > "$store/memory/note.md"
    export DR_MOCK_AGENT_RUNNING=codex

    run dr-mem import --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"in use"* ]]
}

@test "dr-mem import: a probe with no answer is not reported as in use" {
    setup_codex || skip "no writable Windows drive path"
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store/memory"
    printf 'remember this\n' > "$store/memory/note.md"
    export DR_MOCK_PGREP_BROKEN=1

    run dr-mem import --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"dr-mem: Draugr could not find out"* ]]
    # "the context of the agent is in use" as the VERDICT sends the reader to
    # close an agent that may not be running. The honest message contains that
    # phrase too ("could not find out whether the context ... is in use"), so
    # anchor on the headline that dr_die prints rather than on the words.
    [[ "$output" != *"dr-mem: the context of the agent is in use"* ]] || return 1
}

# A source guard, because the `2` branch of the claude module has no injection
# lever: its unknown answer comes from a missing /proc. The shape is what both
# modules must keep, and that can be read.
@test "the agent modules propagate a probe's answer, never a flattened 1" {
    cd "$DR_ROOT" || return 1
    run grep -n -E 'dr_agent_mem_(quiesce|import_ready)[^|]*\|\| return 1' \
        lib/agents/claude.sh lib/agents/codex.sh
    # grep says 1 for "no match", and that is the pass.
    [ "$status" -eq 1 ]
    [ -z "$output" ]

    # And the reported branch of pack must hand the answer out, not a literal.
    # This is the one shape the claude module cannot prove by behaviour here.
    for _f in lib/agents/claude.sh lib/agents/codex.sh; do
        grep -q 'return "\$rc"' "$_f" || return 1
    done
}
# --- the first dr-up of a project that never had a session ------------------

@test "dr-mem import --if-empty: an empty store is not a failure" {
    setup_mound || skip "no writable Windows drive path"
    # No store. DRAUGR_MEM_SYNC=auto runs this at each dr-up. Before, the very
    # first one printed "auto memory import failed" to a person who did nothing
    # wrong.
    run dr-mem import --if-empty --yes
    [ "$status" -eq 0 ]
    [[ "$output" != *"failed"* ]]
    [[ "$output" != *"no memory at"* ]]
}

@test "dr-mem import: asked for explicitly, an empty store still says so" {
    setup_mound || skip "no writable Windows drive path"
    run dr-mem import --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"no memory at"* ]]
}

@test "dr-up: the first one on a new project is quiet about memory" {
    setup_mound || skip "no writable Windows drive path"
    DRAUGR_MEM_SYNC=auto run dr-up
    [ "$status" -eq 0 ]
    [[ "$output" != *"auto memory import failed"* ]]
}

# --- the conversation, and not only the memory ------------------------------
#
# The memory is what the agent learned. The transcript is what was said, and
# --continue reads the newest one. A mound that gets only the memory back has
# forgotten the conversation, and that is the loss these tests are about.
#
# The project directory of the mock mound is the parent of $MEMDIR, which is
# where Claude Code puts both.

# One transcript, with the time set, so that "the newest" has one answer and
# not a race. Each sidecar file goes in the directory of that session.
make_transcript() {
    local uuid=$1 epoch=$2 proj
    proj=$(dirname "$MEMDIR")
    mkdir -p "$proj"
    printf '{"session":"%s"}\n' "$uuid" > "$proj/$uuid.jsonl"
    touch -d "@$epoch" "$proj/$uuid.jsonl"
}

make_sidecar() {
    local uuid=$1 proj
    proj=$(dirname "$MEMDIR")
    mkdir -p "$proj/$uuid/tool-results"
    printf 'a tool result\n' > "$proj/$uuid/tool-results/r1.txt"
}

# A separate process that holds a transcript open, as the agent does while it
# writes. Not an fd of this shell: that one is inherited by the probe itself,
# and then the probe finds its own handle and the test proves nothing.
hold_transcript_open() {
    local uuid=$1 proj
    proj=$(dirname "$MEMDIR")
    rm -f "$DR_TMP/holding"
    setsid sh -c "exec 9>>\"$proj/$uuid.jsonl\"; : > \"$DR_TMP/holding\"; sleep 30" \
        >/dev/null 2>&1 &
    HOLDER=$!
    local i=0
    while [ ! -f "$DR_TMP/holding" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
    [ -f "$DR_TMP/holding" ]
}

release_transcript() {
    [ -n "${HOLDER:-}" ] || return 0
    pkill -P "$HOLDER" 2>/dev/null || :
    kill "$HOLDER" 2>/dev/null || :
    HOLDER=
}

@test "dr-mem export: newest carries the newest transcript and its files" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'learned\n' > "$MEMDIR/a.md"
    make_transcript old 1700000000
    make_transcript new 1800000000
    make_sidecar new

    DRAUGR_MEM_TRANSCRIPTS=newest run dr-mem export
    [ "$status" -eq 0 ]
    local store; store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/a.md" ]
    [ -f "$store/memory/transcripts/new.jsonl" ]
    [ -f "$store/memory/transcripts/new/tool-results/r1.txt" ]
    # The older conversation is not the one that --continue reads.
    [ ! -e "$store/memory/transcripts/old.jsonl" ]
}

@test "dr-mem export: off carries the memory and no conversation" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'learned\n' > "$MEMDIR/a.md"
    make_transcript new 1800000000

    DRAUGR_MEM_TRANSCRIPTS=off run dr-mem export
    [ "$status" -eq 0 ]
    local store; store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/a.md" ]
    [ ! -e "$store/memory/transcripts" ]
}

@test "dr-mem export: all carries every transcript" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    make_transcript old 1700000000
    make_transcript new 1800000000

    DRAUGR_MEM_TRANSCRIPTS=all run dr-mem export
    [ "$status" -eq 0 ]
    local store; store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/transcripts/old.jsonl" ]
    [ -f "$store/memory/transcripts/new.jsonl" ]
}

@test "dr-mem export: names the conversation on the host, and how to delete it" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    make_transcript new 1800000000

    run dr-mem export
    [ "$status" -eq 0 ]
    [[ "$output" == *"the conversation is now on this host"* ]]
    [[ "$output" == *"Delete it again with"* ]]
    [[ "$output" == *"rm -rf"*"transcripts"* ]]
}

@test "dr-mem export: with no transcript it says nothing about deleting one" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'learned\n' > "$MEMDIR/a.md"

    run dr-mem export
    [ "$status" -eq 0 ]
    [[ "$output" != *"Delete it again with"* ]]
}

@test "dr-mem check: a conversation that was never exported is a loss" {
    setup_mound || skip "no writable Windows drive path"
    # No memory at all. The agent wrote nothing down, and you still talked for
    # an hour. Before the transcripts, this mound looked empty and a recreate
    # threw the conversation away without a word.
    make_transcript new 1800000000

    run dr-mem check
    [ "$status" -eq 1 ]
}

@test "dr-up --recreate: refuses while the conversation is not exported" {
    setup_mound || skip "no writable Windows drive path"
    dr_mound_answers
    make_transcript new 1800000000

    run dr-up --recreate --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not export"* ]]
}

@test "dr-up --recreate --force: proceeds anyway" {
    setup_mound || skip "no writable Windows drive path"
    make_transcript new 1800000000

    run dr-up --recreate --force --yes
    [ "$status" -eq 0 ]
}

@test "dr-mem import: the conversation comes back, and a mound-only one lives" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'learned\n' > "$MEMDIR/a.md"
    make_transcript exported 1800000000
    dr-mem export >/dev/null 2>&1

    # A mound that lost its disk: the memory is gone, and another session that
    # the store never saw is there.
    rm -rf "$MEMDIR"
    rm -f "$(dirname "$MEMDIR")/exported.jsonl"
    make_transcript mound-only 1810000000

    run dr-mem import --yes
    [ "$status" -eq 0 ]
    [ -f "$MEMDIR/a.md" ]
    [ -f "$(dirname "$MEMDIR")/exported.jsonl" ]
    # A uuid that this store never held is one conversation, and an import is
    # not a reason to destroy it.
    [ -f "$(dirname "$MEMDIR")/mound-only.jsonl" ]
}

@test "dr-mem export: a writer holding the transcript stops the export" {
    setup_mound || skip "no writable Windows drive path"
    command -v setsid >/dev/null 2>&1 || skip "no setsid"
    mkdir -p "$MEMDIR"
    printf 'first\n' > "$MEMDIR/a.md"
    make_transcript live 1800000000
    dr-mem export >/dev/null 2>&1

    # Now the agent writes again, and the export must not copy a growing file.
    printf 'second\n' > "$MEMDIR/a.md"
    hold_transcript_open live || { release_transcript; skip "could not hold the file open"; }
    run dr-mem export
    release_transcript
    [ "$status" -ne 0 ]
    [[ "$output" == *"was not exported"* ]]
    # The complete copy from before is still the store. A failed export never
    # rotates it away.
    local store; store=$(dr_mem_store_dir "$REPO")
    [ "$(cat "$store/memory/a.md")" = first ]
}

@test "dr_agent_mem_quiesce: quiet with nothing holding the conversation" {
    setup_mound || skip "no writable Windows drive path"
    make_transcript new 1800000000
    DRAUGR_AGENT=claude dr_agent_load
    run dr_agent_mem_quiesce "$REPO"
    [ "$status" -eq 0 ]
}

@test "dr_agent_mem_quiesce: a holder of the transcript is not quiet" {
    setup_mound || skip "no writable Windows drive path"
    command -v setsid >/dev/null 2>&1 || skip "no setsid"
    make_transcript new 1800000000
    DRAUGR_AGENT=claude dr_agent_load
    hold_transcript_open new || { release_transcript; skip "could not hold the file open"; }
    run dr_agent_mem_quiesce "$REPO"
    release_transcript
    [ "$status" -eq 1 ]
}

@test "dr-mem export: a memory entry named transcripts is refused, not packed" {
    setup_mound || skip "no writable Windows drive path"
    # The packed tree puts the memory at the root and the conversation in
    # transcripts/. A memory file of that name makes the tree ambiguous,
    # and unpack reads it as a conversation.
    mkdir -p "$MEMDIR/transcripts"
    printf 'not a conversation\n' > "$MEMDIR/transcripts/x.md"

    run dr-mem export
    [ "$status" -ne 0 ]
}

@test "dr-mem: an unknown DRAUGR_MEM_TRANSCRIPTS is refused, not read as off" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'learned\n' > "$MEMDIR/a.md"

    DRAUGR_MEM_TRANSCRIPTS=newst run dr-mem export
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRAUGR_MEM_TRANSCRIPTS"* ]]
}

@test "agents: an agent that moves nothing names no conversation on the host" {
    DRAUGR_AGENT=nosuchagent dr_agent_load
    run dr_agent_mem_transcript_paths
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "agents: codex names its sessions, so the delete line can reach them" {
    DRAUGR_AGENT=codex dr_agent_load
    run dr_agent_mem_transcript_paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"sessions"* ]]
    [[ "$output" == *"session_index.jsonl"* ]]
}

@test "dr_agent_mem_present: a conversation and no memory is still data" {
    setup_mound || skip "no writable Windows drive path"
    # The contract of this function is "the mound holds something to export".
    # Only dr-mem diff calls it today, and it discards the answer, so this is
    # the only place that holds the contract to its word.
    make_transcript new 1800000000
    DRAUGR_AGENT=claude dr_agent_load
    run dr_agent_mem_present "$REPO"
    [ "$status" -eq 0 ]
}

@test "dr_agent_mem_present: an empty project directory is nothing to export" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$(dirname "$MEMDIR")"
    DRAUGR_AGENT=claude dr_agent_load
    run dr_agent_mem_present "$REPO"
    [ "$status" -eq 1 ]
}

# --- a copy that stops at a link, measured on sbx 0.53 ----------------------
#
# `sbx cp` walks the tree and stops at the first link it meets. It drops
# everything after that point and exits 0. Thus "the export worked" and "the
# store holds the conversation" were two different claims, with nothing
# between them. These three tests are that something.

@test "dr-mem export: a link in the memory is refused before anything moves" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'real\n' > "$MEMDIR/a.md"
    ln -s a.md "$MEMDIR/b.md"

    run dr-mem export
    [ "$status" -ne 0 ]
    local store; store=$(dr_mem_store_dir "$REPO")
    [ ! -e "$store/memory" ]
}

@test "dr-mem export: a link in the conversation is refused too" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'real\n' > "$MEMDIR/a.md"
    make_transcript new 1800000000
    make_sidecar new
    ln -s r1.txt "$(dirname "$MEMDIR")/new/tool-results/r2.txt"

    run dr-mem export
    [ "$status" -ne 0 ]
}

@test "dr-mem export: an entry the mound never declared is refused on the host" {
    # The mound-side refusal above runs with the mound's own find, on a
    # filesystem the agent can write, so it is advisory. This is the same
    # question asked by the side that keeps the answer.
    #
    # A symlink, because that is the entry a hash list cannot see: list_local
    # reads `-type f`, so the link is absent from BOTH sides of the
    # completeness comparison and would travel into the store uncounted.
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'real\n' > "$MEMDIR/a.md"
    printf 'also\n' > "$MEMDIR/b.md"

    DR_MOCK_CP_PLANT=extra.md run dr-mem export
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a plain tree of files"* ]]
    local store; store=$(dr_mem_store_dir "$REPO")
    [ ! -e "$store/memory" ]
    [ ! -e "$store/memory.incoming" ]
}

@test "dr-mem export: a clean copy out is not refused by that check" {
    # The other half: a guard that refuses a normal export protects nothing.
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'real\n' > "$MEMDIR/a.md"
    mkdir -p "$MEMDIR/sub"
    printf 'deep\n' > "$MEMDIR/sub/c.md"

    run dr-mem export
    [ "$status" -eq 0 ]
    local store; store=$(dr_mem_store_dir "$REPO")
    [ -f "$store/memory/a.md" ]
    [ -f "$store/memory/sub/c.md" ]
}

@test "dr-mem export: an incomplete copy out leaves the store as it was" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'first\n' > "$MEMDIR/a.md"
    printf 'also\n'  > "$MEMDIR/b.md"
    dr-mem export >/dev/null 2>&1

    # The mound now holds more, and the copy out loses one file on the way.
    printf 'second\n' > "$MEMDIR/a.md"
    DR_MOCK_CP_TRUNCATE=b.md run dr-mem export
    [ "$status" -ne 0 ]
    [[ "$output" == *"not complete"* ]]
    local store; store=$(dr_mem_store_dir "$REPO")
    # The complete store from before is still there, and not as a leftover.
    [ "$(cat "$store/memory/a.md")" = first ]
    [ -f "$store/memory/b.md" ]
    [ ! -e "$store/memory.incoming" ]
}

# --- the agent itself, found by the path of its executable ------------------
#
# The handle scan above answers "is something writing right now". Between two
# turns the agent holds nothing open, and it is still about to write. Thus the
# stronger question is "does the agent run at all", which is what the Codex
# module asks with pgrep. Here the answer is the PATH of the executable: in a
# mound the agent is ~/.local/share/claude/versions/<version>, measured.
#
# The probe derives that directory from the project path it was given, so in
# these tests it can only match inside the stand-in tree. A Claude Code that
# the person running the suite has installed in WSL cannot make them fail.

# A stand-in for the agent: a real binary at the path the agent has.
# /bin/sleep, because the probe reads the path and never the program.
run_fake_agent() {
    local dir=$DR_MOCK_MOUND/home/agent/.local/share/claude/versions
    mkdir -p "$dir"
    cp /bin/sleep "$dir/9.9.9"
    rm -f "$DR_TMP/agent-up"
    setsid sh -c ": > \"$DR_TMP/agent-up\"; exec \"$dir/9.9.9\" 30" >/dev/null 2>&1 &
    FAKE_AGENT=$!
    local i=0
    while [ ! -f "$DR_TMP/agent-up" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
    [ -f "$DR_TMP/agent-up" ]
}

# The same binary, from a directory that is not the agent's. It must not count.
run_decoy() {
    local dir=$DR_TMP/elsewhere
    mkdir -p "$dir"
    cp /bin/sleep "$dir/9.9.9"
    rm -f "$DR_TMP/decoy-up"
    setsid sh -c ": > \"$DR_TMP/decoy-up\"; exec \"$dir/9.9.9\" 30" >/dev/null 2>&1 &
    DECOY=$!
    local i=0
    while [ ! -f "$DR_TMP/decoy-up" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
    [ -f "$DR_TMP/decoy-up" ]
}

stop_fakes() {
    for p in ${FAKE_AGENT:-} ${DECOY:-}; do
        pkill -P "$p" 2>/dev/null || :
        kill "$p" 2>/dev/null || :
    done
    pkill -f "/.local/share/claude/versions/9.9.9" 2>/dev/null || :
    pkill -f "$DR_TMP/elsewhere/9.9.9" 2>/dev/null || :
    FAKE_AGENT=; DECOY=
}

@test "dr_agent_mem_quiesce: an agent that runs is not quiet, even if it writes nothing" {
    setup_mound || skip "no writable Windows drive path"
    command -v setsid >/dev/null 2>&1 || skip "no setsid"
    make_transcript new 1800000000
    DRAUGR_AGENT=claude dr_agent_load
    run_fake_agent || { stop_fakes; skip "could not start the stand-in"; }
    run dr_agent_mem_quiesce "$REPO"
    stop_fakes
    [ "$status" -eq 1 ]
}

@test "dr_agent_mem_quiesce: a binary of the same name elsewhere is not the agent" {
    setup_mound || skip "no writable Windows drive path"
    command -v setsid >/dev/null 2>&1 || skip "no setsid"
    make_transcript new 1800000000
    DRAUGR_AGENT=claude dr_agent_load
    run_decoy || { stop_fakes; skip "could not start the stand-in"; }
    run dr_agent_mem_quiesce "$REPO"
    stop_fakes
    [ "$status" -eq 0 ]
}

@test "dr-mem export: refuses while the agent runs, and keeps the old store" {
    setup_mound || skip "no writable Windows drive path"
    command -v setsid >/dev/null 2>&1 || skip "no setsid"
    mkdir -p "$MEMDIR"
    printf 'first\n' > "$MEMDIR/a.md"
    dr-mem export >/dev/null 2>&1

    printf 'second\n' > "$MEMDIR/a.md"
    run_fake_agent || { stop_fakes; skip "could not start the stand-in"; }
    run dr-mem export
    stop_fakes
    [ "$status" -ne 0 ]
    [[ "$output" == *"was not exported"* ]]
    local store; store=$(dr_mem_store_dir "$REPO")
    [ "$(cat "$store/memory/a.md")" = first ]
}

# --- the shared receive path, in the memory channel -------------------------
#
# Hardening 1. The export is the channel that takes all four steps, so these
# are about the two that are new to it: how much there may be, and where it
# may land. The exports are EXPORTED variables, because `run` is a function
# and dr-mem is a child process that would never see a prefix assignment.

@test "dr-mem export: more than DRAUGR_INCOMING_MAX_FILES leaves the store alone" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'one\n' > "$MEMDIR/a.md"
    printf 'two\n' > "$MEMDIR/b.md"
    export DRAUGR_INCOMING_MAX_FILES=1
    run dr-mem export
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRAUGR_INCOMING_MAX_FILES is 1"* ]]
    store=$(dr_mem_store_dir "$REPO")
    [ ! -e "$store/memory" ]
}

# THE PROTECTION THAT DID NOT EXIST BEFORE. The store corner is a link, so the
# rename would publish the agent's memory wherever that link points - and the
# receipt would still name the store.
@test "dr-mem export: a link where the store's memory goes is refused" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'the build is cmake\n' > "$MEMDIR/build.md"
    store=$(dr_mem_store_dir "$REPO")
    mkdir -p "$store" "$DR_TMP/outside"
    ln -s "$DR_TMP/outside" "$store/memory"

    run dr-mem export
    [ "$status" -ne 0 ]
    [[ "$output" == *"not the place it names"* ]]
    # Nothing was written through the link, and the link is still a link: a
    # refusal that had quietly replaced it would be its own surprise.
    [ -z "$(ls -A "$DR_TMP/outside")" ]
    [ -L "$store/memory" ]
}

# The same question one level up: the corner is fine and the store itself is
# the link. dr_path_contained resolves both sides, so this is the case a name
# comparison would have called contained.
@test "dr-mem export: a memory store that is itself a link is refused" {
    setup_mound || skip "no writable Windows drive path"
    mkdir -p "$MEMDIR"
    printf 'the build is cmake\n' > "$MEMDIR/build.md"
    mkdir -p "$DR_TMP/realstore"
    ln -s "$DR_TMP/realstore" "$DR_TMP/storelink"
    export DRAUGR_MEM_STORE="$DR_TMP/storelink"

    run dr-mem export
    [ "$status" -ne 0 ]
    [[ "$output" == *"not the place it names"* ]]
}
