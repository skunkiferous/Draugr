#!/usr/bin/env bats
# Codex context is a recovery set, not a copy of the user's agent home.
load helper

setup() {
    dr_test_setup
    dr_load_common
    REPO=$(dr_make_win_repo) || return 1
    cd "$REPO" || return 1
    export DRAUGR_AGENT=codex DR_MOCK_AGENT=codex DR_MOCK_STATE=running
    export DRAUGR_MEM_STORE="$DR_TMP/store"
    dr_agent_load
    dr_mound_codex_dir
    CODEXDIR=$DR_CODEXDIR
    mkdir -p "$CODEXDIR"
}

teardown() { dr_test_teardown; }

# Capture the transfer itself. A filter at the final destination is too late.
@test "codex import: credentials never reach staging or the transfer" {
    src="$DR_TMP/source"
    mkdir -p "$src/memories"
    printf 'approved context\n' > "$src/memories/MEMORY.md"
    printf 'host-only-marker\n' > "$src/auth.json"
    printf 'host-only-marker\n' > "$src/config.toml"
    export DR_MOCK_CP_CAPTURE="$DR_TMP/transferred"
    run dr-mem import --yes --source "$src"
    [ "$status" -ne 0 ]
    [ ! -e "$DR_MOCK_CP_CAPTURE" ]
    ! grep -q '^cp ' "$DR_MOCK_LOG" || return 1
}

# A symlink to an unrelated host file must fail before the first upload.
@test "codex import: a linked memory cannot cross the boundary" {
    src="$DR_TMP/source"
    mkdir -p "$src/memories"
    printf 'ordinary memory\n' > "$src/memories/safe.md"
    printf 'outside\n' > "$DR_TMP/private"
    ln -s "$DR_TMP/private" "$src/memories/MEMORY.md"
    run dr-mem import --yes --source "$src"
    [ "$status" -ne 0 ]
    ! grep -q '^cp ' "$DR_MOCK_LOG" || return 1
}

# Transcript-only state matters even when memory generation was never enabled.
@test "codex export: transcripts and the newer memory store travel" {
    mkdir -p "$CODEXDIR/sessions/a" "$CODEXDIR/archived_sessions" "$CODEXDIR/memories_v2"
    printf 'conversation\n' > "$CODEXDIR/sessions/a/rollout.jsonl"
    printf 'archived\n' > "$CODEXDIR/archived_sessions/old.jsonl"
    printf 'new memory\n' > "$CODEXDIR/memories_v2/MEMORY.md"
    run dr-mem export
    [ "$status" -eq 0 ]
    store=$(dr_mem_store_dir "$REPO")
    grep -q conversation "$store/memory/sessions/a/rollout.jsonl"
    grep -q archived "$store/memory/archived_sessions/old.jsonl"
    grep -q 'new memory' "$store/memory/memories_v2/MEMORY.md"
}

# A partial export must not rotate away the last complete recovery point.
@test "codex export: an active writer preserves the previous store" {
    mkdir -p "$CODEXDIR/memories"
    printf 'before\n' > "$CODEXDIR/memories/MEMORY.md"
    printf 'database\n' > "$CODEXDIR/state_5.sqlite"
    dr-mem export
    store=$(dr_mem_store_dir "$REPO")
    export DR_MOCK_AGENT_RUNNING=codex
    printf 'after\n' > "$CODEXDIR/memories/MEMORY.md"
    run dr-mem export
    [ "$status" -ne 0 ]
    grep -q before "$store/memory/memories/MEMORY.md"
    [ -f "$store/memory/state_5.sqlite" ]
}

# Replacing a database that a live agent owns can corrupt the session.
@test "codex import: an active writer is refused before upload" {
    src="$DR_TMP/source"
    mkdir -p "$src"
    printf 'database\n' > "$src/state_5.sqlite"
    export DR_MOCK_AGENT_RUNNING=codex
    run dr-mem import --yes --source "$src"
    [ "$status" -ne 0 ]
    ! grep -q '^cp ' "$DR_MOCK_LOG" || return 1
}

# A newer configured agent must not hide the old mound's unexported memory.
@test "agent switch: checks use the installed agent's context" {
    dr_mound_memory_dir "$REPO"
    mkdir -p "$DR_MEMDIR"
    printf 'Claude context\n' > "$DR_MEMDIR/MEMORY.md"
    export DR_MOCK_AGENT=claude
    run dr-mem check
    [ "$status" -eq 1 ]
    run dr-mem export
    [ "$status" -eq 0 ]
    old_store=$(DRAUGR_AGENT=claude dr_mem_store_dir "$REPO")
    grep -q 'Claude context' "$old_store/memory/MEMORY.md"
}

# The current native CLI keeps transcript content in this separate database.
@test "codex paginated history: transcript database survives a round trip" {
    printf 'native transcript\n' > "$CODEXDIR/thread_history_1.sqlite"
    run dr-mem export
    [ "$status" -eq 0 ]
    store=$(dr_mem_store_dir "$REPO")
    grep -q 'native transcript' "$store/memory/thread_history_1.sqlite"
    rm "$CODEXDIR/thread_history_1.sqlite"
    run dr-mem import
    [ "$status" -eq 0 ]
    grep -q 'native transcript' "$CODEXDIR/thread_history_1.sqlite"
}

# Do not reinterpret a config value as a continuation flag or a prompt.
@test "codex resume: a new mound drops only ordinary resume-last" {
    dr_agent_session_prepare "$REPO" resume --last -m test-model -c 'model_reasoning_effort="high"'
    [ "$DR_AGENT_SESSION_DROPPED" = 'resume --last' ]
    [ "${DR_AGENT_SESSION_ARGS[0]}" = -m ]
    [ "${DR_AGENT_SESSION_ARGS[3]}" = 'model_reasoning_effort="high"' ]
}

# Explicit selection and unknown options belong to the native CLI.
@test "codex resume: explicit sessions and changed scope are preserved" {
    for selection in thread-id --all --include-non-interactive; do
        dr_agent_session_prepare "$REPO" resume --last "$selection"
        [ "${DR_AGENT_SESSION_ARGS[0]}" = resume ] || return 1
        [ -z "$DR_AGENT_SESSION_DROPPED" ] || return 1
    done
}

# A database without its transcript layout is unknown, not proof of absence.
@test "codex resume: an unknown probe never creates a replacement session" {
    printf 'metadata\n' > "$CODEXDIR/state_5.sqlite"
    dr_agent_session_prepare "$REPO" resume --last
    [ "${DR_AGENT_SESSION_ARGS[0]}" = resume ]
    export DR_MOCK_FAIL=exec
    dr_agent_session_prepare "$REPO" resume --last
    [ "${DR_AGENT_SESSION_ARGS[0]}" = resume ]
}

# Use real SQLite and a committed WAL; file-existence placeholders cannot
# detect a snapshot that lost rows or restored a stale shared-memory index.
@test "codex sqlite: committed WAL rows survive export and import" {
    python3 - "$CODEXDIR" <<'PY'
import pathlib, shutil, sqlite3, sys
root = pathlib.Path(sys.argv[1])
db = sqlite3.connect(root / 'work.sqlite')
db.execute('PRAGMA journal_mode=WAL')
db.execute('PRAGMA wal_autocheckpoint=0')
db.execute('CREATE TABLE proof(value TEXT)')
db.execute("INSERT INTO proof VALUES ('committed row')")
db.commit()
for suffix in ('', '-wal'):
    shutil.copyfile(str(root / 'work.sqlite') + suffix,
                    str(root / 'state_5.sqlite') + suffix)
db.close()
PY
    dr-mem export
    rm "$CODEXDIR/state_5.sqlite" "$CODEXDIR/state_5.sqlite-wal"
    printf 'stale index\n' > "$CODEXDIR/state_5.sqlite-shm"
    dr-mem import
    python3 - "$CODEXDIR/state_5.sqlite" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    assert db.execute('PRAGMA integrity_check').fetchone() == ('ok',)
    assert db.execute('SELECT value FROM proof').fetchone() == ('committed row',)
PY
}

# Only the selected Codex library contributes package skills and overrides.
@test "codex plugins: switches and removal apply without replacing native config" {
    export DRAUGR_PLUGIN_STORE="$REPO/plugins"
    seed="$DRAUGR_PLUGIN_STORE/codex/seed"
    mkdir -p "$seed/marketplaces/parity/packages/marker/1/skills/visible"
    printf '%s\n' '{"format":1,"marketplaces":{"parity":"example/marketplace"},"plugins":[{"id":"marker@parity","name":"marker","marketplace":"parity","version":"1","enabled":true}]}' > "$seed/library.json"
    printf '%s\n' '---' 'name: visible' 'description: A fixture.' '---' > "$seed/marketplaces/parity/packages/marker/1/skills/visible/SKILL.md"
    run dr-plugin skills
    [ "$status" -eq 0 ]
    [[ "$output" == *'visible marker@parity 1'* ]]
    dr-plugin disable marker@parity
    run dr_agent_launch_args
    [ "${lines[0]}" = -c ]
    [[ "$output" == *'plugins."marker@parity".enabled=false'* ]]
    dr-plugin enable marker@parity
    dr-plugin remove marker@parity
    run dr_agent_launch_args
    [ "${lines[0]}" = -c ]
    [[ "$output" == *'plugins."marker@parity".enabled=false'* ]]
    [ ! -d "$DRAUGR_PLUGIN_STORE/codex/.lock" ]
}

# sbx changed the envelope. State and identity must still name the real mound.
@test "sbx array listing: state and agent survive the native envelope" {
    export DR_MOCK_JSON='[{"name":"draugr-testrepo","agent":"codex","status":"running","workspaces":["C:\\Code\\testrepo"]}]'
    [ "$(dr_sandbox_state draugr-testrepo)" = running ]
    [ "$(dr_sandbox_agent draugr-testrepo)" = codex ]
    run dr_sbx_json "notice before JSON
$DR_MOCK_JSON
notice after JSON"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.sandboxes[0].name')" = draugr-testrepo ]
}

# Whitespace in a database root must be refused before shell word splitting.
@test "codex import: a crafted database name cannot select unrelated files" {
    src="$DR_TMP/source"
    mkdir -p "$src"
    printf 'private-marker\n' > "$src/private-note"
    printf 'database\n' > "$src/state_5.sqlite"
    printf 'extra\n' > "$src/.sqlite"
    printf 'crafted\n' > "$src/state_5.sqlite private-note .sqlite"
    export DR_MOCK_CP_CAPTURE="$DR_TMP/transferred"
    run dr-mem import --yes --source "$src"
    [ "$status" -ne 0 ]
    [ ! -e "$DR_MOCK_CP_CAPTURE" ]
}

# Execute the generated shell quoting with a recorder in place of the agent.
# Assertions on argv strings alone miss interpolation and lost config values.
@test "codex provider: the attach shell delivers native arguments literally" {
    dr_sbx() { printf 'sbx version 0.53.0\n'; }
    DRAUGR_MODEL='fixture;$(touch injected)'
    DRAUGR_MODEL_URL=http://127.0.0.1:18761/v1
    DRAUGR_ENV='PARITY_ENV=visible'
    export PROOF="$DR_TMP/argv"
    codex() { printf '%s\n' "$PARITY_ENV" "$@" > "$PROOF"; }
    export -f codex
    dr_attach_rc codex resume --last -c 'model_reasoning_effort="xhigh"' > "$DR_TMP/rc"
    bash -c 'source "$1"; eval "$PROMPT_COMMAND"' bash "$DR_TMP/rc"
    grep -qx 'visible' "$PROOF"
    grep -qx 'model_provider="draugr-local"' "$PROOF"
    grep -qx 'model_providers.draugr-local.base_url="http://127.0.0.1:18761/v1"' "$PROOF"
    grep -qx 'model_providers.draugr-local.requires_openai_auth=false' "$PROOF"
    grep -qxF 'model="fixture;$(touch injected)"' "$PROOF"
    [ ! -e injected ]
}

# The old upstream fallback bug must be refused before generating a provider.
@test "codex provider: versions with the cloud fallback bug are refused" {
    dr_sbx() { printf 'sbx version 0.37.1\n'; }
    run dr_agent_model_args http://local model
    [ "$status" -ne 0 ]
    [[ "$output" == *'require sbx 0.53'* ]]
}

# Unknown target state must never authorize an automatic restore.
@test "codex import: a failed target probe is refused by if-empty" {
    # A link makes only the context listing fail; home discovery still works.
    # The old if-empty expression discarded that failed listing's exit code.
    mkdir -p "$CODEXDIR/memories" "$DR_TMP/source/memories"
    ln -s "$DR_TMP/private" "$CODEXDIR/memories/unsafe"
    printf 'incoming\n' > "$DR_TMP/source/memories/safe.md"
    run dr-mem import --if-empty --yes --source "$DR_TMP/source"
    [ "$status" -ne 0 ]
    ! grep -q '^cp ' "$DR_MOCK_LOG" || return 1
}

# Select context before the transfer; unrelated roots are never uploaded.
@test "codex curated source: only selected context crosses the boundary" {
    src="$DR_TMP/source"
    mkdir -p "$src/memories" "$src/foreign-project"
    printf 'selected\n' > "$src/memories/MEMORY.md"
    printf 'foreign-marker\n' > "$src/foreign-project/notes.md"
    export DR_MOCK_CP_CAPTURE="$DR_TMP/transferred"
    run dr-mem import --yes --source "$src"
    [ "$status" -eq 0 ]
    grep -q selected "$CODEXDIR/memories/MEMORY.md"
    run grep -R foreign-marker "$DR_MOCK_CP_CAPTURE"
    [ "$status" -eq 1 ]
}

# Configuration is native state, never an import side effect.
@test "codex context: import preserves target feature consent and provider" {
    src="$DR_TMP/source"
    mkdir -p "$src/memories"
    printf 'selected\n' > "$src/memories/MEMORY.md"
    printf 'model_provider="sandboxd"\n[features]\nmemories=false\n' > "$CODEXDIR/config.toml"
    cp "$CODEXDIR/config.toml" "$DR_TMP/config-before"
    dr-mem import --yes --source "$src"
    cmp "$DR_TMP/config-before" "$CODEXDIR/config.toml"
}

# A location mismatch cannot satisfy the destruction guard as empty context.
@test "codex context: a separate database home is an unknown loss check" {
    export DRAUGR_ENV=CODEX_SQLITE_HOME=/home/agent/separate
    run dr-mem check
    [ "$status" -eq 2 ]
    [[ "$output" == *'separate CODEX_SQLITE_HOME'* ]]
}

# A quiet mound can still contain a link into another mounted directory.
@test "codex context: target links are replaced without changing their referent" {
    src="$DR_TMP/source"
    mkdir -p "$src"
    printf 'restored\n' > "$src/state_5.sqlite"
    printf 'unrelated\n' > "$DR_TMP/unrelated"
    ln -s "$DR_TMP/unrelated" "$CODEXDIR/state_5.sqlite"
    dr-mem import --yes --source "$src"
    grep -qx unrelated "$DR_TMP/unrelated"
    [ ! -L "$CODEXDIR/state_5.sqlite" ]
    grep -qx restored "$CODEXDIR/state_5.sqlite"
}

# A quoted TOML key still relocates the database. It is never empty context.
@test "codex layout: quoted SQLite configuration is refused" {
    for key in sqlite_home '"sqlite_home"' "'sqlite_home'"; do
        printf '%s="/home/agent/custom"\n' "$key" > "$CODEXDIR/config.toml"
        run dr-mem check
        [ "$status" -eq 2 ] || return 1
    done
}

# Configured invocation overrides must not escape the same layout guard.
@test "codex layout: configured SQLite arguments are refused" {
    export DRAUGR_AGENT_ARGS_CODEX='-c sqlite_home="/home/agent/custom"'
    run dr-mem check
    [ "$status" -eq 2 ]
    [[ "$output" == *'sqlite_home in Codex arguments'* ]]
}

# A failed grep must not look like a successful search with no override.
@test "codex layout: an unreadable configuration probe is unknown" {
    mkdir "$CODEXDIR/config.toml"
    run dr-mem check
    [ "$status" -eq 2 ]
    [[ "$output" == *'could not inspect Codex configuration'* ]]
}

# Global host homes may contain unrelated projects and credentials.
@test "codex host status: global state is not scanned or imported" {
    mkdir -p "$HOME/.codex/memories"
    printf 'private\n' > "$HOME/.codex/auth.json"
    run dr_agent_mem_host_dir "$REPO"
    [ "$status" -eq 1 ]
    run dr-mem import --from-host --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *'curated export'* ]]
    ! grep -q '^cp ' "$DR_MOCK_LOG" || return 1
}

# Current built-in agents require v3 mixins. Test the public init/adopt path,
# including the distinction between install access and runtime permissions.
@test "sbx v3 kits: init and adopt preserve runtime network permissions" {
    export DR_MOCK_VERSION=0.53.0 DR_MOCK_NAME=draugr-testrepo
    dr-init --force
    kit="$REPO/.draugr/kit"
    grep -q '^schemaVersion: "3"' "$kit/spec.yaml"
    export DR_MOCK_ADHOC=opened.example.com
    run dr-kit adopt --yes
    [ "$status" -eq 0 ]
    run dr_kit_allow_list "$kit"
    [ "$output" = opened.example.com ] || { printf 'got: %s\n' "$output"; cat "$kit/spec.yaml"; return 1; }
    run dr-kit adopt --yes
    [ "$status" -eq 0 ]
    [ "$(grep -c 'opened.example.com' "$kit/spec.yaml")" = 1 ]
}

# Without a native identity, the requested agent could be the replacement.
@test "codex loss check: unknown installed agent cannot authorize removal" {
    export DR_MOCK_AGENT=
    run dr-mem check
    [ "$status" -eq 2 ]
    [[ "$output" == *'did not identify the installed agent'* ]]
}

# Install access does not grant runtime access. Keep phase lists separate.
@test "sbx v3 policy: adoption never writes runtime grants into install access" {
    export DR_MOCK_NAME=draugr-testrepo DR_MOCK_ADHOC=opened.example.com
    mkdir -p "$REPO/.draugr/kit"
    cat > "$REPO/.draugr/kit/spec.yaml" <<'YAML'
schemaVersion: "3"
kind: mixin
capabilities:
  - type: com.docker.sandbox/network-policy@1
    config:
      runtime:
        deny: [blocked.example.com]
      install:
        allow:
          - build.example.com
YAML
    dr-kit adopt --yes
    run dr_kit_allow_list "$REPO/.draugr/kit"
    [ "$output" = opened.example.com ]
    grep -q 'build.example.com' "$REPO/.draugr/kit/spec.yaml"
}
