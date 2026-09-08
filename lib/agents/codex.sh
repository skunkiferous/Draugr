# shellcheck shell=bash
#
# lib/agents/codex.sh - what Draugr knows about OpenAI's Codex CLI.
#
# shellcheck disable=SC2016
# Single-quoted "$1" appears throughout and is deliberate: those strings are
# scripts for the MOUND's shell, and the whole point is that the host does not
# expand them. See dr_mound_sh in lib/common.sh for how the arguments get there.
#
# Measured against the image sbx ships (codex-cli 0.146.0, `sbx create codex`),
# not read off a blog. Where a claim below matters it says how it was checked.
#
# Codex's memory is a different shape from Claude Code's in three ways, and each
# one is a trap for code written with only the other in mind:
#
#   1. It is NOT per project. Everything lives under $CODEX_HOME - the image sets
#      CODEX_HOME=/home/agent/.codex explicitly - with no directory named after
#      the workspace. There is nothing to translate, which is the whole of
#      lib/agents/claude.sh. Draugr gets away with treating it as this repo's
#      memory only because one mound holds one repository.
#   2. It is half markdown and half SQLite. The generated memories are readable
#      files under memories/; the session history that `codex resume` reads is in
#      state_*.sqlite beside them.
#   3. It is OFF by default, and deliberately so in the EEA, the UK and
#      Switzerland - it builds a behavioural profile, which is regulated. Codex
#      generates nothing at all until `[features] memories = true` is in
#      config.toml. dr-mem import turns it on, because importing memory is an
#      explicit request to have some; nothing else in Draugr does.

# --- the module interface ---------------------------------------------------

dr_agent_mem_supported() { return 0; }
dr_agent_mem_label()     { printf 'Codex'; }

# $CODEX_HOME inside the mound. Everything below hangs off this one directory,
# and dr-mem takes the parent of dr_agent_mem_dir for the paths it creates - so
# spelling memories/ here is what puts the transfer in .codex/ rather than in
# some directory of its own.
_dr_codex_home() { printf '%s/.codex' "$DR_MOUND_HOME"; }

dr_agent_mem_dir()    { printf '%s/memories' "$(_dr_codex_home)"; }
dr_agent_mem_survey() { _dr_codex_home; }

# The databases worth carrying, as shell globs against $CODEX_HOME.
#
# The numeric suffix is a schema version - state_5, memories_1 - so these are
# globbed rather than named: it moves, and a hard-coded 5 would silently stop
# matching. logs_*.sqlite is deliberately absent. It is diagnostics, it was
# 7 MB on the machine this was written on, and nothing reads it back.
_DR_CODEX_DBS='state_*.sqlite memories_*.sqlite goals_*.sqlite queue_*.sqlite'

# dr_agent_mem_quiesce - is it safe to copy the databases right now?
#
# SQLite in WAL mode is two files that have to agree, so copying while something
# writes can produce a pair that does not. There is no sqlite3 in the image to
# take a proper .backup with - checked - so the only safe copy is one made while
# nothing is writing, and the only honest test of that is whether the agent is
# running at all.
#
# Three answers, not two: 0 quiet, 1 running, 2 could not tell. "Could not tell"
# must not be read as "safe", which is why the missing-pgrep case is its own exit
# code rather than falling through to success. (pgrep is present in the image;
# this is for the day it is not.)
dr_agent_mem_quiesce() {
    dr_mound_sh 'command -v pgrep >/dev/null 2>&1 || exit 2
                 pgrep -x codex >/dev/null 2>&1 && exit 1
                 exit 0'
}

# dr_agent_mem_present <repo> - anything worth exporting?
#
# Either half counts. A mound where Codex ran once but generated no memories
# still holds session history, and losing that to dr-rm is a real loss.
dr_agent_mem_present() {
    dr_mound_sh 'test -d "$1/memories" && exit 0
                 for db in "$1"/state_*.sqlite; do [ -f "$db" ] && exit 0; done
                 exit 1' "$(_dr_codex_home)"
}

# dr_agent_mem_list <repo> - the carried set, hashed, named as pack writes them.
#
# Two finds because the two halves need different names: '%p' from `memories`
# gives "memories/MEMORY.md", and '%f' at the top level gives "state_5.sqlite" -
# which is exactly the packed tree, so these line up with the store's own
# listing without either side knowing about the other.
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

# dr_agent_mem_pack <repo> <stage> - assemble the carried set into <stage>.
#
# The markdown goes unconditionally: it is small, it is what you would actually
# read, and copying it is safe whatever the agent is doing. The databases go only
# when nothing is writing them, and their absence is a warning rather than a
# failure - this runs automatically on every detach, and a detach must not fail
# over the difference between "memory" and "memory plus session history".
dr_agent_mem_pack() {
    # $1 is the repo, which this agent has no use for: Codex files nothing under
    # the project's name. It is in the signature because every module shares one.
    local stage=$2 home rc=0
    home=$(_dr_codex_home)

    dr_mound_run 'set -e
                  rm -rf "$1"; mkdir -p "$1"
                  if [ -d "$2/memories" ]; then cp -a "$2/memories" "$1/"; fi' \
                 "$stage" "$home" || return 1

    # Not a failure, and deliberately not fatal - see the note above.
    dr_agent_mem_quiesce || rc=$?
    if [ "$rc" -ne 0 ]; then
        dr_warn "carrying Codex's memories, but not its session history"
        if [ "$rc" -eq 1 ]; then
            printf '  %scodex is running in %s, and its databases cannot be copied%s\n' \
                "$_DR_DIM" "$DRAUGR_SANDBOX" "$_DR_OFF" >&2
            printf '  %ssafely while it writes them. Leave the agent, then:  dr-mem export%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
        else
            printf '  %scould not tell whether codex is running, so the databases were%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
            printf '  %sleft alone rather than copied half-written.%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
        fi
        return 0
    fi

    # The -wal file is half of the database's current state, so it travels with
    # it or the copy is stale. -shm is not: it is a shared-memory index SQLite
    # rebuilds, and a stale one is worse than none.
    dr_mound_run 'set -e
                  cd "$2"
                  for db in '"$_DR_CODEX_DBS"'; do
                      [ -f "$db" ] || continue
                      cp -a "$db" "$1/"
                      if [ -f "$db-wal" ]; then cp -a "$db-wal" "$1/"; fi
                  done' "$stage" "$home"
}

# dr_agent_mem_unpack <repo> <stage> - put the packed tree back.
#
# Selective on purpose: it copies the members it knows and ignores everything
# else in <stage>. That is what makes `dr-mem import --source ~/.codex` safe -
# a real CODEX_HOME also holds config.toml, which sbx wrote to put the agent in
# yolo mode, and overwriting it would quietly re-arm the approval prompts.
dr_agent_mem_unpack() {
    # $1 is the repo, unused here for the reason given in pack.
    local stage=$2 home
    home=$(_dr_codex_home)

    # The -shm beside each replaced database is removed rather than copied: it is
    # a shared-memory index SQLite rebuilds from the other two files, and one left
    # over from the database being overwritten describes something else entirely.
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

    # Memory that is not enabled is memory the agent never reads - so importing
    # without this would look like it worked and change nothing. `codex features
    # enable` edits config.toml in place, leaving sbx's own settings alone;
    # verified against the image.
    dr_mound_run 'codex features enable memories' >/dev/null 2>&1 || dr_warn \
        "could not enable Codex memories - the import is in place but unread" \
        "Turn it on by hand:  dr-shell -- codex features enable memories"
    return 0
}

# dr_agent_mem_status_extra <repo> - is the feature even on?
#
# The question worth answering first for Codex, and the one nothing else asks:
# with memories off, everything below reports zero files for ever and there is
# nothing on screen to say the agent was never going to write any. Only asked of
# a mound that already exists, since asking creates nothing and a status command
# must not start a stopped mound to answer.
dr_agent_mem_status_extra() {
    local state
    dr_sandbox_exists "$DRAUGR_SANDBOX" || return 0

    # `codex features list` prints "<name> <stage> <effective>", so the last
    # field is the answer - and asking Codex beats reading config.toml, which
    # would miss a default that changes under us in a later version.
    printf '\n%sgeneration%s\n' "$_DR_BOLD" "$_DR_OFF"
    state=$(dr_mound_sh 'codex features list 2>/dev/null | awk "\$1 == \"memories\" {print \$NF}"')
    case "$state" in
        true)  printf '  %-6s %son%s - Codex writes memories in this mound\n' \
                   memories "$_DR_GREEN" "$_DR_OFF" ;;
        false) printf '  %-6s %soff%s - Codex writes none. dr-mem import turns it on\n' \
                   memories "$_DR_YELLOW" "$_DR_OFF" ;;
        *)     printf '  %-6s %scould not be read%s - is the mound running?\n' \
                   memories "$_DR_DIM" "$_DR_OFF" ;;
    esac
}

# --- the host side ----------------------------------------------------------

# dr_agent_mem_host_dir <repo> - a host install's CODEX_HOME, for --from-host.
#
# NOT per repo, unlike Claude Code's: this is everything that install remembers,
# about every project. dr-mem confirms an unfamiliar source before importing it,
# which is the right prompt to be answering here.
#
# Windows first, for the same reason as claude.sh: on a WSL host $HOME is ext4
# and usually has no agent install, while the Windows profile normally does.
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

# The hint names the directory AND the reason it is empty, because "off by
# default" is overwhelmingly the answer: a Codex install with no memories/ has
# usually never had the feature turned on, rather than never been used.
dr_agent_mem_host_hint() {
    printf 'Looked for a memories/ directory in ~/.codex. Codex writes none until %s' \
           '`[features] memories = true` is in its config.'
}

# dr_agent_secret - the name sbx stores this agent's credentials under.
#
# `sbx secret set -g openai --oauth` is the ChatGPT sign-in, and the one worth
# recommending: it uses the entitlement a ChatGPT plan already carries, where an
# API key bills separately. Either way the credential stays on the host.
dr_agent_secret() { printf 'openai'; }

# dr_agent_signin - and unlike Anthropic's, this flow really can be started from
# the host. `sbx secret set --help` gives `sbx secret set -g openai --oauth` as
# its own worked example, where the same flag against anthropic is refused with
# "sign in from inside the Claude sandbox". Same store, two different routes into
# it, which is why this hint lives per agent rather than in dr-doctor.
dr_agent_signin() {
    printf 'Sign in with a ChatGPT plan:  sbx secret set -g %s --oauth\n' "$1"
    printf 'Or an API key, which bills separately:  echo "$KEY" | sbx secret set -g %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Plugins - not measured, so not offered.
#
# Codex has its own extension story and it is not Claude Code's: no
# .claude-plugin manifest, no marketplace catalogue, and no measured variable
# that redirects a library the way CLAUDE_CODE_PLUGIN_CACHE_DIR does. dr-plugin
# builds a directory that gets mounted into every mound on the machine, so a
# guess here would put third-party code somewhere nothing reviewed it.
#
# Whoever measures it wants docs/CLAUDE_PLUGINS.md as the shape to fill in: a
# writable build library, a read-only one for sessions, and a CLI with verbs for
# add, install, update and uninstall. If Codex has no equivalent of the second,
# option 4 does not apply to it at all and that is the finding.
# ---------------------------------------------------------------------------
dr_agent_plugin_supported() { return 1; }
dr_agent_plugin_cache_var() { return 1; }
dr_agent_plugin_seed_var()  { return 1; }
dr_agent_plugin_cli()       { return 1; }

# ---------------------------------------------------------------------------
# Pointing Codex at another endpoint - not measured, so not offered.
#
# Codex takes its provider from `model_provider` in the mound's config.toml,
# which sbx writes at creation, rather than from the environment - so this is
# not the same shape as Claude Code's two variables and guessing at it would be
# the failure DRAUGR_MODEL must not have: an agent still calling its cloud while
# you believed otherwise. Saying so refuses the setting instead.
#
# Whoever measures it should start at the model trap in the CHANGELOG: sbx sets
# model_provider and no model, which is already one surprise in this file.
# ---------------------------------------------------------------------------
dr_agent_model_supported() { return 1; }
dr_agent_model_env()       { return 1; }
