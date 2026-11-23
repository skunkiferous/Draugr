# shellcheck shell=bash
#
# lib/agents/codex.sh: what Draugr knows about the Codex CLI of OpenAI.
#
# shellcheck disable=SC2016
# "$1" in single quotes occurs in many places, on purpose. Those strings are
# scripts for the shell of the MOUND. The host must not expand them. See
# dr_mound_sh in lib/common.sh for how the arguments get there.
#
# This comes from tests on the image that sbx ships (codex-cli 0.167.2,
# `sbx create codex`), not from a blog. Where a claim below is important, it
# tells how it was tested.
#
# Codex state belongs to a home, not to a project. One repository per mound
# makes exporting that state useful. A host home can span unrelated projects.
# The recovery set includes generated memories, JSONL transcripts on older
# images, and metadata plus paginated transcript databases on this image.
# Restoring that set never enables memory generation or copies configuration.

# --- the module interface ---------------------------------------------------

dr_agent_mem_supported() { return 0; }
dr_agent_mem_label()     { printf 'Codex'; }

# $CODEX_HOME in the mound. All paths below start from this one directory.
# dr-mem uses the parent of dr_agent_mem_dir for the paths that it creates.
# Thus memories/ here puts the transfer in .codex/, and not in a separate
# directory.
_dr_codex_home() { printf '%s' "${DR_CODEX_HOME:-$DR_MOUND_HOME/.codex}"; }

dr_agent_mem_dir()    { printf '%s/memories' "$(_dr_codex_home)"; }
dr_agent_mem_survey() { _dr_codex_home; }

# Read the effective image location once. Attach-only CODEX_HOME overrides
# must also select the same context when dr-mem runs outside that session.
dr_agent_mem_init() {
    local home entry sql pairs layout_rc=0
    local entries=()
    home=$(dr_mound_sh 'printf "%s" "${CODEX_HOME:-/home/agent/.codex}"') || return 1
    pairs=$(dr_env_pairs) || return 1
    if [ -n "$pairs" ]; then mapfile -t entries <<< "$pairs"; fi
    for entry in "${entries[@]}"; do
        case "$entry" in CODEX_HOME=*) home=${entry#*=} ;; esac
    done
    case "$home" in /*) ;; *) dr_error "Codex home is not an absolute path"; return 1 ;; esac
    DR_CODEX_HOME=$home
    # A relocated database requires a different recovery layout. Refuse it
    # instead of exporting an empty default directory as a complete backup.
    sql=$(dr_mound_sh 'printf "%s" "${CODEX_SQLITE_HOME:-}"') || return 1
    for entry in "${entries[@]}"; do
        case "$entry" in CODEX_SQLITE_HOME=*) sql=${entry#*=} ;; esac
    done
    if [ -n "$sql" ] && [ "$sql" != "$home" ]; then
        dr_error "a separate CODEX_SQLITE_HOME is not supported by context transfer"
        return 1
    fi
    # Reject references conservatively, including quoted keys and profiles.
    # This is not a TOML parser. A failed read is also an unknown layout.
    case "${DRAUGR_AGENT_ARGS:-}" in
        *sqlite_home*) dr_error "sqlite_home in Codex arguments is not supported by context transfer"; return 1 ;;
    esac
    dr_mound_sh '[ -e "$1/config.toml" ] || exit 1
        grep -q sqlite_home "$1/config.toml"' "$home" || layout_rc=$?
    case "$layout_rc" in
        0) dr_error "custom sqlite_home needs a measured context transfer layout"; return 1 ;;
        1) return 0 ;;
        *) dr_error "could not inspect Codex configuration for its database location"; return 1 ;;
    esac
}

# dr_agent_mem_quiesce: is it safe to copy the databases now?
#
# The SQLite database and its WAL must agree with each other and the transcripts.
# Require a quiet Codex, then compare hashes before and after the copy. This
# does not lock out an external launcher: do not attach during a transfer.
#
# Three answers, not two: 0 quiet, 1 running, 2 unknown. "Unknown" must not
# mean "safe". Thus a missing pgrep has its own exit code, and does not become
# a success. (The image has pgrep. This is for a future image without it.)
dr_agent_mem_quiesce() {
    # `&& exit 1` alone read EACH non-zero exit of pgrep as "not running". But
    # pgrep exits with 2 or 3 for ITS OWN errors, and with 1 only for "no
    # match". Thus a pgrep that could not answer gave the quiet answer. The
    # three-answer contract above forbids exactly that. The case below reads
    # each exit code.
    dr_mound_sh 'command -v pgrep >/dev/null 2>&1 || exit 2
                 pgrep -x codex >/dev/null 2>&1
                 case $? in
                     0) exit 1 ;;
                     1) exit 0 ;;
                     *) exit 2 ;;
                 esac'
}

# dr_agent_mem_present <repo>: is there data to export?
#
# Each half counts. If Codex ran one time but generated no memories, the
# mound still holds session history. If dr-rm deletes it, that is a real loss.
dr_agent_mem_present() {
    dr_mound_sh "$(_dr_codex_state_script)" present "$(_dr_codex_home)"
}

# dr_agent_mem_list <repo>: the copied files, with hashes, and with the names
# that pack writes.
#
# Names match the packed tree, so comparisons use the same file selection on
# both sides. Failed probes propagate rather than looking like empty state.
dr_agent_mem_list() {
    dr_mound_sh "$(_dr_codex_state_script)" list "$(_dr_codex_home)"
}

# One file selection runs on either side of the boundary. It rejects links
# before any copy and keeps credentials and arbitrary databases out of both.
_dr_codex_state_script() {
    cat <<'SH'
set -eu
action=$1; src=$2; dest=${3:-}
if [ ! -d "$src" ]; then
    [ "$action" = list ] && exit 0
    exit 1
fi
[ ! -L "$src" ] || exit 1
cd "$src"

# These roots are private state in a one-repository mound. They are never a
# license to import the multi-project home of a host or its configuration.
items() {
    for dir in memories memories_v2 sessions archived_sessions; do
        [ ! -e "$dir" ] && [ ! -L "$dir" ] || printf '%s\n' "$dir"
    done
    for db in state_*.sqlite thread_history_*.sqlite memories_*.sqlite goals_*.sqlite queue_*.sqlite; do
        [ ! -e "$db" ] && [ ! -L "$db" ] && continue
        # Validate before emitting a root, not after splitting the list.
        case "$db" in *[!A-Za-z0-9_.-]*) exit 1 ;; esac
        printf '%s\n' "$db"
        [ ! -e "$db-wal" ] && [ ! -L "$db-wal" ] || printf '%s\n' "$db-wal"
    done
    for file in session_index.jsonl history.jsonl; do
        [ ! -e "$file" ] && [ ! -L "$file" ] || printf '%s\n' "$file"
    done
    return 0
}

# Every selected root must have a simple name. Descendants can have spaces,
# but line breaks and escaped hash names cannot enter the comparison protocol.
paths=$(items)
for path in $paths; do
    case "$path" in *[!A-Za-z0-9_.-]*) exit 1 ;; esac
    [ ! -L "$path" ] || exit 1
    bad=$(find "$path" \( -type l -o ! -type f -a ! -type d \) -print -quit)
    [ -z "$bad" ] || exit 1
    bad=$(find "$path" -name '*[[:cntrl:]\\]*' -print -quit)
    [ -z "$bad" ] || exit 1
done

case "$action" in
    present) [ -n "$paths" ] ;;
    list)
        # NUL separates names until sha256sum. Shell word splitting only sees
        # the fixed roots above, never descendant names.
        { for path in $paths; do find "$path" -type f -print0; done; } |
            sort -z | xargs -0 -r sha256sum
        ;;
    pack)
        mkdir -p "$dest"
        for path in $paths; do cp -a "$path" "$dest/"; done
        printf 'format=2\n' > "$dest/.draugr-codex-state"
        ;;
    unpack)
        # A stale WAL belongs to the replaced database, never the new one.
        [ ! -L "$dest" ] || exit 1
        mkdir -p "$dest"
        for path in $paths; do
            case "$path" in
                *.sqlite) rm -f "$dest/$path-wal" "$dest/$path-shm" ;;
                memories|memories_v2|sessions|archived_sessions) rm -rf "$dest/$path" ;;
            esac
            # Replace the directory entry of a file, not the target of a symlink. A
            # sandbox can leave links pointing into another mounted tree.
            case "$path" in
                memories|memories_v2|sessions|archived_sessions) ;;
                *) rm -f "$dest/$path" ;;
            esac
            cp -a "$path" "$dest/"
        done
        ;;
    *) exit 2 ;;
esac
SH
}

# dr_agent_mem_pack <repo> <stage>: collect the files to copy into <stage>.
#
# Publish the whole recovery set or fail without rotating the previous store.
# A successful markdown-only copy cannot stand in for a conversation backup.
#
# THREE ANSWERS, like the probe it is built on: 0 packed, 1 definitely not safe
# to pack, 2 could not find out. This function prints which it was, so the
# caller reports the status and does not guess at a cause of its own. See
# "Pattern: a reporter with three answers" in docs/HACKING.md.
dr_agent_mem_pack() {
    # $1 is the repo, and this agent does not use it. Codex stores nothing under
    # the name of the project. It is in the signature, because all modules
    # share one signature.
    local stage=$2 home before after packed rc=0
    home=$(_dr_codex_home)

    # A full recovery point needs every component from the same quiet agent.
    # Never rotate a complete store away in favor of a successful partial copy.
    dr_agent_mem_quiesce || rc=$?
    if [ "$rc" -ne 0 ]; then
        dr_warn "Codex context was not exported. The previous store is unchanged"
        if [ "$rc" -eq 1 ]; then
            printf '  %scodex runs in %s. Its databases cannot be copied safely%s\n' \
                "$_DR_DIM" "$DRAUGR_SANDBOX" "$_DR_OFF" >&2
            printf '  %swhile it writes them. Leave the agent, then run:  dr-mem export%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
        else
            printf '  %sDraugr could not find out if codex runs. Thus it did not copy%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
            printf '  %sthe databases, because a copy could be incomplete.%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
        fi
        # The answer of the probe, not a flattened 1. "codex is running" and
        # "Draugr could not find out" need different advice, and only this
        # function knows which of the two it printed.
        return "$rc"
    fi

    # The -wal file is half of the current state of the database. Thus it goes
    # with the database, or the copy is old. -shm does not go. It is a
    # shared-memory index that SQLite builds again, and an old one is worse
    # than none.
    # A step that does not answer is "could not find out", not "not safe": the
    # mound is what the caller should then look at, not the agent. That is the
    # whole difference between 1 and 2 below.
    before=$(dr_agent_mem_list) || return 2
    dr_mound_run 'rm -rf "$1"; mkdir -p "$1"' "$stage" || return 2
    dr_mound_run "$(_dr_codex_state_script)" pack "$home" "$stage" || return 2
    # Catch an agent started during the copy. The caller publishes nothing
    # after a failed pack, even if the temporary files already exist.
    dr_agent_mem_quiesce || return $?
    after=$(dr_agent_mem_list) || return 2
    packed=$(dr_mound_sh "$(_dr_codex_state_script)" list "$stage") || return 2
    # A writer that started and stopped between probes still changes hashes.
    # This one IS 1: the probes answered, and what they say is that the context
    # moved. Nothing about the mound is in doubt.
    if [ "$before" != "$after" ] || [ "$before" != "$packed" ]; then
        dr_error "Codex context changed during export. The store is unchanged"
        return 1
    fi
}

# dr_agent_mem_unpack <repo> <stage>: put the packed tree back.
#
# The source was curated before upload. Select again on the target and keep
# its sbx provider, permissions, login, and native feature choices untouched.
dr_agent_mem_unpack() {
    # $1 is the repo. It is not used here, for the reason in pack.
    local stage=$2 home
    home=$(_dr_codex_home)

    # Restore sessions without changing consent to use or generate memories.
    # The answer of the probe, so that "in use" and "could not tell" stay apart.
    dr_agent_mem_import_ready || return $?
    dr_mound_run "$(_dr_codex_state_script)" unpack "$stage" "$home"
}

# Host CODEX_HOME can contain every project and a login. Do not import that
# home, even temporarily. An explicit source must already be curated.
dr_agent_mem_prepare_source() {
    local source=$1 dest=$2 mode=${3:-source}
    if [ "$mode" = host ] || [ -e "$source/auth.json" ] || [ -e "$source/config.toml" ]; then
        dr_error "a whole Codex home is not a project-scoped import"
        dr_warn "Use dr-mem import --source with a curated context export."
        return 1
    fi
    if [ -e "$source/.draugr-codex-state" ] || [ -L "$source/.draugr-codex-state" ]; then
        [ ! -L "$source/.draugr-codex-state" ] || return 1
        grep -qx 'format=2' "$source/.draugr-codex-state" || return 1
    else
        dr_warn "legacy or curated Codex source: conversation completeness is unknown"
    fi
    # Validate and copy through the same allowlist as export. This happens
    # before any bytes enter repository staging or the sandbox.
    sh -c "$(_dr_codex_state_script)" sh pack "$source" "$dest"
}

# A quiet target is required for markdown too: its background memory worker
# can change both files and databases. Unknown is never the quiet answer.
dr_agent_mem_import_ready() { dr_agent_mem_quiesce; }

# The conversation inside the packed tree. These are the names from the file
# selection above that hold what was SAID, and not what the agent learned:
# the sessions, the index that points into them, and the thread database.
# dr-mem expands each one against the store, so a glob is allowed here.
dr_agent_mem_transcript_paths() {
    printf '%s\n' sessions archived_sessions session_index.jsonl \
        history.jsonl 'thread_history_*.sqlite' 'thread_history_*.sqlite-wal'
}

# dr_agent_mem_status_extra <repo>: is the feature on?
#
# Generated memory and saved conversations are separate. Ask the native CLI
# whether generation is enabled, without starting a stopped mound for status.
dr_agent_mem_status_extra() {
    local state
    [ "$(dr_sandbox_state "$DRAUGR_SANDBOX")" = running ] || return 0

    # `codex features list` prints "<name> <stage> <effective>". Thus the last
    # field is the answer. A question to Codex is better than a read of
    # config.toml. config.toml does not show a default that a later version
    # changes.
    printf '\n%sgeneration%s\n' "$_DR_BOLD" "$_DR_OFF"
    state=$(dr_mound_sh 'codex features list 2>/dev/null | awk "\$1 == \"memories\" {print \$NF}"')
    case "$state" in
        true)  printf '  %-6s %son%s: Codex writes memories in this mound\n' \
                   memories "$_DR_GREEN" "$_DR_OFF" ;;
        false) printf '  %-6s %soff%s: memory generation is disabled. Import preserves this choice\n' \
                   memories "$_DR_YELLOW" "$_DR_OFF" ;;
        *)     printf '  %-6s %sunknown%s: does the mound run?\n' \
                   memories "$_DR_DIM" "$_DR_OFF" ;;
    esac
}

# --- the host side ----------------------------------------------------------

# Never scan or hash a global host home just to report project memory status.
dr_agent_mem_host_dir() { return 1; }

# Project selection from multi-project databases has not been established.
dr_agent_mem_host_hint() {
    printf 'Codex host state can span projects. Use dr-mem import --source with a curated export, not a whole CODEX_HOME.'
}

# dr_agent_secret: the name under which sbx stores the credentials of this agent.
#
# `sbx secret set -g openai --oauth` is the ChatGPT sign-in, and it is the one to
# recommend. It uses the rights that a ChatGPT plan already has. An API key has
# a separate bill. In both cases, the credential stays on the host.
dr_agent_secret() {
    [ -z "${DRAUGR_MODEL:-}" ] || return 1
    printf 'openai'
}

# dr_agent_signin: how to get the secret. This flow, unlike the flow of
# Anthropic, can start from the host. `sbx secret set --help` gives
# `sbx secret set -g openai --oauth` as its own example. For anthropic, sbx
# refuses the same flag with "sign in from inside the Claude sandbox". It is
# the same store, with two different ways into it. Thus this hint is in each
# agent module, not in dr-doctor.
dr_agent_signin() {
    printf 'Sign in with a ChatGPT plan:  sbx secret set -g %s --oauth\n' "$1"
    printf 'Or use an API key, which has a separate bill:  echo "$KEY" | sbx secret set -g %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Native Codex plugins use their own backend and published local marketplaces.
# The Claude cache/seed variables below have no Codex equivalent.
# ---------------------------------------------------------------------------
dr_agent_plugin_supported() { return 0; }
dr_agent_plugin_cache_var() { return 1; }
dr_agent_plugin_seed_var()  { return 1; }
dr_agent_plugin_cli()       { return 1; }

# ---------------------------------------------------------------------------
# Native config arguments select the local provider for one invocation.
# ---------------------------------------------------------------------------
dr_agent_model_supported() {
    local version major minor
    version=$(dr_sbx --version 2>/dev/null) || return 1
    if [[ "$version" =~ ([0-9]+)\.([0-9]+)\.[0-9]+ ]]; then
        major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
        if [ "$major" -gt 0 ] || [ "$minor" -ge 53 ]; then return 0; fi
    fi
    # Older sbx can substitute the cloud provider when --model is selected.
    dr_error "Codex local providers require sbx 0.53 or later. Inspect sbx --version"
    return 1
}
dr_agent_model_env()       { return 0; }

# A private provider replaces sandboxd for this invocation only. CLI config
# preserves the rest of the config of sbx and does not read host credentials.
dr_agent_model_args() {
    local url=${1%/} model=$2
    dr_agent_model_supported || return 1
    if [ -n "${DRAUGR_MODEL_FAST:-}" ] && [ "$DRAUGR_MODEL_FAST" != "$model" ]; then
        dr_warn "Codex has no measured fast-tier mapping. This session uses $model"
    fi
    case "$url" in */v1) ;; *) url+=/v1 ;; esac
    printf '%s\n' -c 'model_provider="draugr-local"' \
        -c "model=$(jq -Rn --arg v "$model" '$v')" \
        -c 'model_providers.draugr-local.name="Draugr local model"' \
        -c "model_providers.draugr-local.base_url=$(jq -Rn --arg v "$url" '$v')" \
        -c 'model_providers.draugr-local.wire_api="responses"' \
        -c 'model_providers.draugr-local.requires_openai_auth=false'
}

# The kit registers packages. Apply reviewed enable decisions for this launch
# without replacing any provider, permission, or authentication configuration.
dr_agent_launch_args() {
    local file="${DRAUGR_PLUGIN_STORE:-}/codex/seed/library.json"
    [ -n "${DRAUGR_PLUGIN_STORE:-}" ] && [ -f "$file" ] || return 0
    jq -r '(.plugins[] | "-c", ("plugins."+(.id|tojson)+".enabled="+(.enabled|tostring))),
        ((.removed // [])[] | "-c", ("plugins."+(.|tojson)+".enabled=false"))' "$file"
}

# Codex continues with a subcommand. Keep native selection when database
# contents or current-directory eligibility cannot be established safely.
dr_agent_session_flags()   { return 0; }
dr_agent_session_present() {
    dr_mound_sh 'command -v find >/dev/null 2>&1 || { printf "unknown\n"; exit 0; }
        for dir in sessions archived_sessions threads; do
            if [ -d "$1/$dir" ]; then
                found=$(find "$1/$dir" -type f -print -quit) || exit 1
                if [ -n "$found" ]; then printf "present\n"; exit 0; fi
            fi
        done
        for db in "$1"/state_*.sqlite; do
            if [ -f "$db" ]; then printf "unknown\n"; exit 0; fi
        done
        printf "none\n"' "$(_dr_codex_home)"
}

# Only the ordinary resume-last form can safely become a new session. An ID,
# prompt, changed scope, or unknown option keeps the native request intact.
# shellcheck disable=SC2034  # dr-go reads the prepared array and explanation.
dr_agent_session_prepare() {
    local repo=$1 state arg takes_value=
    shift
    DR_AGENT_SESSION_ARGS=("$@")
    DR_AGENT_SESSION_DROPPED=
    [ "${1:-}" = resume ] && [ "${2:-}" = --last ] || return 0
    shift 2
    for arg in "$@"; do
        if [ -n "$takes_value" ]; then takes_value=; continue; fi
        case "$arg" in
            -m|--model|-c|--config|-p|--profile|-s|--sandbox|-a|--ask-for-approval|--enable|--disable) takes_value=1 ;;
            --model=*|--config=*|--profile=*|--sandbox=*|--ask-for-approval=*) ;;
            --search|--no-alt-screen|--no-daemon|--oss|--dangerously-bypass-approvals-and-sandbox) ;;
            *) return 0 ;;
        esac
    done
    [ -z "$takes_value" ] || return 0
    dr_agent_mem_init || return 0
    state=$(dr_agent_session_present "$repo") || return 0
    if [ "$state" = none ]; then
        DR_AGENT_SESSION_ARGS=("$@")
        DR_AGENT_SESSION_DROPPED='resume --last'
    fi
}
