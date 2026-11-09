# shellcheck shell=bash
#
# lib/agents/codex.sh: what Draugr knows about the Codex CLI of OpenAI.
#
# shellcheck disable=SC2016
# "$1" in single quotes occurs in many places, on purpose. Those strings are
# scripts for the shell of the MOUND. The host must not expand them. See
# dr_mound_sh in lib/common.sh for how the arguments get there.
#
# This comes from tests on the image that sbx ships (codex-cli 0.146.0,
# `sbx create codex`), not from a blog. Where a claim below is important, it
# tells how it was tested.
#
# The memory of Codex differs from the memory of Claude Code in three ways.
# Each is a trap for code that was written for the other agent:
#
#   1. It is NOT for each project. All of it is under $CODEX_HOME (the image
#      sets CODEX_HOME=/home/agent/.codex), with no directory named after the
#      workspace. There is nothing to translate, and translation is all of
#      lib/agents/claude.sh. Draugr can treat it as the memory of this repo
#      only because one mound holds one repository.
#   2. It is half markdown and half SQLite. The generated memories are files
#      under memories/ that you can read. The session history that
#      `codex resume` reads is in state_*.sqlite next to them.
#   3. It is OFF by default. In the EEA, the UK, and Switzerland, it is off on
#      purpose, because it builds a profile of behavior, and the law controls
#      that. Codex generates nothing until config.toml contains
#      `[features] memories = true`. dr-mem import turns it on, because an
#      import of memory is a clear request for memory. Nothing else in Draugr
#      turns it on.

# --- the module interface ---------------------------------------------------

dr_agent_mem_supported() { return 0; }
dr_agent_mem_label()     { printf 'Codex'; }

# $CODEX_HOME in the mound. All paths below start from this one directory.
# dr-mem uses the parent of dr_agent_mem_dir for the paths that it creates.
# Thus memories/ here puts the transfer in .codex/, and not in a separate
# directory.
_dr_codex_home() { printf '%s/.codex' "$DR_MOUND_HOME"; }

dr_agent_mem_dir()    { printf '%s/memories' "$(_dr_codex_home)"; }
dr_agent_mem_survey() { _dr_codex_home; }

# The databases to copy, as shell globs in $CODEX_HOME.
#
# The number at the end is a schema version (state_5, memories_1). Thus these
# are globs and not names. The number changes, and a fixed 5 stops matching
# with no message. logs_*.sqlite is not in the list, on purpose. It holds
# diagnostics, it was 7 MB on the machine where this was written, and nothing
# reads it back.
_DR_CODEX_DBS='state_*.sqlite memories_*.sqlite goals_*.sqlite queue_*.sqlite'

# dr_agent_mem_quiesce: is it safe to copy the databases now?
#
# SQLite in WAL mode is two files that must agree. A copy while a process
# writes can give a pair that does not agree. The image has no sqlite3 for a
# correct .backup (a test showed this). Thus a copy is safe only when nothing
# writes. The only correct test of that is: does the agent run?
#
# Three answers, not two: 0 quiet, 1 running, 2 unknown. "Unknown" must not
# mean "safe". Thus a missing pgrep has its own exit code, and does not become
# a success. (The image has pgrep. This is for a future image without it.)
dr_agent_mem_quiesce() {
    # `&& exit 1` on its own read EVERY non-zero pgrep as "not running", and
    # pgrep exits 2 or 3 for ITS OWN errors, not only 1 for "no match". So a
    # pgrep that could not answer became the quiet answer, which is the one
    # thing the three-answer contract above forbids. Dispatch on the code.
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
    dr_mound_sh 'test -d "$1/memories" && exit 0
                 for db in "$1"/state_*.sqlite; do [ -f "$db" ] && exit 0; done
                 exit 1' "$(_dr_codex_home)"
}

# dr_agent_mem_list <repo>: the copied files, with hashes, and with the names
# that pack writes.
#
# Two finds, because the two halves need different names. '%p' from `memories`
# gives "memories/MEMORY.md". The top-level loop gives "state_5.sqlite". That
# is exactly the packed tree. Thus these names match the list of the store, and
# neither side knows about the other.
dr_agent_mem_list() {
    dr_mound_sh 'cd "$1" 2>/dev/null || exit 0
                 { [ -d memories ] && find memories -type f -printf "%p\0"
                   for db in '"$_DR_CODEX_DBS"'; do
                       [ -f "$db" ] && printf "%s\0" "$db"
                       [ -f "$db-wal" ] && printf "%s\0" "$db-wal"
                   done
                   :
                 } | sort -z | xargs -0 -r sha256sum' "$(_dr_codex_home)"
}

# dr_agent_mem_pack <repo> <stage>: collect the files to copy into <stage>.
#
# The markdown always goes. It is small, it is what you read, and its copy is
# safe while the agent works. The databases go only when nothing writes them.
# If they are missing, that is a warning and not a failure. This runs at each
# detach, and a detach must not fail because of the difference between
# "memory" and "memory and session history".
dr_agent_mem_pack() {
    # $1 is the repo, and this agent does not use it. Codex stores nothing under
    # the name of the project. It is in the signature, because all modules
    # share one signature.
    local stage=$2 home rc=0
    home=$(_dr_codex_home)

    dr_mound_run 'set -e
                  rm -rf "$1"; mkdir -p "$1"
                  if [ -d "$2/memories" ]; then cp -a "$2/memories" "$1/"; fi' \
                 "$stage" "$home" || return 1

    # Not a failure, and not fatal, on purpose. See the note above.
    dr_agent_mem_quiesce || rc=$?
    if [ "$rc" -ne 0 ]; then
        dr_warn "copying the memories of Codex, but not its session history"
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
        return 0
    fi

    # The -wal file is half of the current state of the database. Thus it goes
    # with the database, or the copy is old. -shm does not go. It is a
    # shared-memory index that SQLite builds again, and an old one is worse
    # than none.
    dr_mound_run 'set -e
                  cd "$2"
                  for db in '"$_DR_CODEX_DBS"'; do
                      [ -f "$db" ] || continue
                      cp -a "$db" "$1/"
                      if [ -f "$db-wal" ]; then cp -a "$db-wal" "$1/"; fi
                  done' "$stage" "$home"
}

# dr_agent_mem_unpack <repo> <stage>: put the packed tree back.
#
# It selects files, on purpose. It copies the files that it knows, and ignores
# all other files in <stage>. That makes `dr-mem import --source ~/.codex`
# safe. A real CODEX_HOME also holds config.toml, which sbx wrote to put the
# agent in yolo mode. If the import overwrites it, the approval prompts come
# back, with no message.
dr_agent_mem_unpack() {
    # $1 is the repo. It is not used here, for the reason in pack.
    local stage=$2 home
    home=$(_dr_codex_home)

    # The code removes the -shm next to each replaced database, and does not
    # copy it. It is a shared-memory index that SQLite builds from the other
    # two files. An old -shm from the overwritten database describes a
    # different database.
    dr_mound_run 'set -e
                  mkdir -p "$2"
                  if [ -d "$1/memories" ]; then
                      rm -rf "$2/memories"
                      cp -a "$1/memories" "$2/"
                  fi
                  cd "$1"
                  for f in *.sqlite *.sqlite-wal; do
                      [ -f "$f" ] || continue
                      case "$f" in logs_*) continue ;; esac
                      cp -a "$f" "$2/"
                      rm -f "$2/${f%-wal}-shm"
                  done' "$stage" "$home" || return 1

    # The agent never reads memory that is not turned on. Without this step,
    # an import looks as if it worked, but changes nothing. `codex features
    # enable` changes config.toml in place, and does not touch the values of
    # sbx. A test on the image showed this.
    dr_mound_run 'codex features enable memories' >/dev/null 2>&1 || dr_warn \
        "could not turn on the memories of Codex. The import is in place, but Codex does not read it" \
        "Turn it on by hand:  dr-shell -- codex features enable memories"
    return 0
}

# dr_agent_mem_status_extra <repo>: is the feature on?
#
# For Codex, this is the first question, and nothing else asks it. With
# memories off, all lines below always report zero files. Nothing on the
# screen tells that the agent will never write any. The code asks only a mound
# that exists. A status command must not start a stopped mound to answer.
dr_agent_mem_status_extra() {
    local state
    dr_sandbox_exists "$DRAUGR_SANDBOX" || return 0

    # `codex features list` prints "<name> <stage> <effective>". Thus the last
    # field is the answer. A question to Codex is better than a read of
    # config.toml. config.toml does not show a default that a later version
    # changes.
    printf '\n%sgeneration%s\n' "$_DR_BOLD" "$_DR_OFF"
    state=$(dr_mound_sh 'codex features list 2>/dev/null | awk "\$1 == \"memories\" {print \$NF}"')
    case "$state" in
        true)  printf '  %-6s %son%s: Codex writes memories in this mound\n' \
                   memories "$_DR_GREEN" "$_DR_OFF" ;;
        false) printf '  %-6s %soff%s: Codex writes none. dr-mem import turns it on\n' \
                   memories "$_DR_YELLOW" "$_DR_OFF" ;;
        *)     printf '  %-6s %sunknown%s: does the mound run?\n' \
                   memories "$_DR_DIM" "$_DR_OFF" ;;
    esac
}

# --- the host side ----------------------------------------------------------

# dr_agent_mem_host_dir <repo>: the CODEX_HOME of a host install, for --from-host.
#
# It is NOT for each repo, as with Claude Code. It is all that the install
# remembers, about all projects. dr-mem asks before it imports a source that it
# does not know. That is the correct question here.
#
# Windows first, for the same reason as in claude.sh. On a WSL host, $HOME is
# ext4 and usually has no agent install. The Windows profile usually has one.
dr_agent_mem_host_dir() {
    local userprofile candidate
    if command -v cmd.exe >/dev/null 2>&1; then
        userprofile=$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')
        if [ -n "$userprofile" ] && [ "$userprofile" != '%USERPROFILE%' ]; then
            candidate="$(dr_path_from_win "$userprofile")/.codex"
            [ -d "$candidate/memories" ] && { printf '%s' "$candidate"; return 0; }
        fi
    fi

    candidate="$HOME/.codex"
    [ -d "$candidate/memories" ] && { printf '%s' "$candidate"; return 0; }

    return 1
}

# The hint names the directory AND the reason that it is empty. "Off by
# default" is almost always the answer. A Codex install with no memories/
# usually never had the feature on. It is not that nobody used it.
dr_agent_mem_host_hint() {
    printf 'Looked for a memories/ directory in ~/.codex. Codex writes none until %s' \
           '`[features] memories = true` is in its config.'
}

# dr_agent_secret: the name under which sbx stores the credentials of this agent.
#
# `sbx secret set -g openai --oauth` is the ChatGPT sign-in, and it is the one to
# recommend. It uses the rights that a ChatGPT plan already has. An API key has
# a separate bill. In both cases, the credential stays on the host.
dr_agent_secret() { printf 'openai'; }

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
# Plugins: nobody tested them, so Draugr does not offer them.
#
# Codex has its own extension system, and it is not the system of Claude Code.
# It has no .claude-plugin manifest and no marketplace catalog. Nobody found a
# variable that moves a library, as CLAUDE_CODE_PLUGIN_CACHE_DIR does.
# dr-plugin builds a directory that each mound on the machine mounts. A guess
# here puts third-party code in a place where nobody reviewed it.
#
# If you test it, use docs/CLAUDE_PLUGINS.md as the model to fill in: a
# writable build library, a read-only library for sessions, and a CLI with
# verbs for add, install, update, and uninstall. If Codex has nothing like the
# second item, option 4 does not apply to it, and that is the result.
# ---------------------------------------------------------------------------
dr_agent_plugin_supported() { return 1; }
dr_agent_plugin_cache_var() { return 1; }
dr_agent_plugin_seed_var()  { return 1; }
dr_agent_plugin_cli()       { return 1; }

# ---------------------------------------------------------------------------
# Send Codex to a different endpoint: nobody tested it, so Draugr does not offer it.
#
# Codex takes its provider from `model_provider` in the config.toml of the
# mound, not from the environment. sbx writes that file at creation. Thus it is
# not like the two variables of Claude Code. A guess is the failure that
# DRAUGR_MODEL must not have: an agent that still calls its cloud while you
# think that it does not. Thus the module refuses the value.
#
# If you test it, start with the model trap in the CHANGELOG. sbx sets
# model_provider and no model. That is already one surprise in this file.
# ---------------------------------------------------------------------------
dr_agent_model_supported() { return 1; }
dr_agent_model_env()       { return 1; }

# The session that an argument like --continue needs. Codex continues with a
# SUBCOMMAND, `codex resume --last`, and not with a flag that could sit in
# DRAUGR_AGENT_ARGS. Where it files those sessions is not measured. Thus there
# is no argument to drop and no answer about what the mound holds. A guess here
# would start a new session in place of the one you asked to continue.
dr_agent_session_flags()   { return 0; }
dr_agent_session_present() { printf 'unknown\n'; }
